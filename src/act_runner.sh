#!/usr/bin/env bash
# act_runner.sh - nektos/act integration for dsr
#
# Usage:
#   source act_runner.sh
#   act_run_workflow <repo_path> <workflow> [job] [event]
#
# This module handles running GitHub Actions workflows locally via act,
# collecting artifacts, and returning structured results.

set -uo pipefail

# Configuration (can be overridden)
ACT_ARTIFACTS_DIR="${ACT_ARTIFACTS_DIR:-${DSR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsr}/artifacts}"
ACT_LOGS_DIR="${ACT_LOGS_DIR:-${DSR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsr}/logs/$(date +%Y-%m-%d)/builds}"
ACT_TIMEOUT="${ACT_TIMEOUT:-3600}"  # 1 hour default
ACT_MIN_VERSION="${ACT_MIN_VERSION:-0.2.86}"

# Colors for output (if not disabled)
if [[ -z "${NO_COLOR:-}" && -t 2 ]]; then
    _RED=$'\033[0;31m'
    _GREEN=$'\033[0;32m'
    _YELLOW=$'\033[0;33m'
    _BLUE=$'\033[0;34m'
    _NC=$'\033[0m'
else
    _RED='' _GREEN='' _YELLOW='' _BLUE='' _NC=''
fi

_log_info()  { echo "${_BLUE}[act]${_NC} $*" >&2; }
_log_ok()    { echo "${_GREEN}[act]${_NC} $*" >&2; }
_log_warn()  { echo "${_YELLOW}[act]${_NC} $*" >&2; }
_log_error() { echo "${_RED}[act]${_NC} $*" >&2; }

# Compute SHA256 for a file (portable: sha256sum or shasum -a 256)
_act_sha256() {
    local file="$1"

    if command -v sha256sum &>/dev/null; then
        sha256sum "$file" 2>/dev/null | awk '{print $1}'
        return $?
    fi

    if command -v shasum &>/dev/null; then
        shasum -a 256 "$file" 2>/dev/null | awk '{print $1}'
        return $?
    fi

    return 3
}

# Get file size in bytes (portable)
_act_file_size() {
    local file="$1"
    stat -c %s "$file" 2>/dev/null || stat -f %z "$file" 2>/dev/null || echo 0
}

_act_file_identity() {
    local file="$1"
    local identity=""

    if identity=$(stat -L -c '%d:%i' "$file" 2>/dev/null) && \
       [[ "$identity" =~ ^[0-9]+:[1-9][0-9]*$ ]]; then
        printf 'gnu:%s\n' "$identity"
        return 0
    fi

    # macOS exposes the backing inode through /dev/fd/N, but reports devfs as
    # its device. The evidence path is already constrained to the same private
    # directory, so compare the dereferenced inode and retain explicit path
    # type/symlink checks at every call site.
    if identity=$(stat -L -f '%i' "$file" 2>/dev/null) && \
       [[ "$identity" =~ ^[1-9][0-9]*$ ]]; then
        printf 'bsd:%s\n' "$identity"
        return 0
    fi
    return 4
}

# Collect producer stdout into a newly-created file while holding the original
# destination inode open. The receipt is emitted only after the producer exits
# successfully and the descriptor/path identity, digest, and size remain
# stable. A failed producer may leave evidence in its private target directory,
# but its partial bytes are never returned as an artifact.
_act_collect_stream_exclusive() {
    local destination="$1"
    local mode="$2"
    shift 2

    local receipt producer_status
    receipt=$(
        (
            set -C
            umask 077
            exec 9> "$destination" || exit 4

            local fd_identity_before path_identity_before
            fd_identity_before=$(_act_file_identity /dev/fd/9) || exit 4
            path_identity_before=$(_act_file_identity "$destination") || exit 4
            [[ "$fd_identity_before" == "$path_identity_before" ]] || exit 4

            "$@" >&9 || exit 7
            chmod "$mode" /dev/fd/9 || exit 4

            local fd_identity_after path_identity_after sha_before size_before
            fd_identity_after=$(_act_file_identity /dev/fd/9) || exit 4
            path_identity_after=$(_act_file_identity "$destination") || exit 4
            [[ "$fd_identity_before" == "$fd_identity_after" &&
               "$fd_identity_after" == "$path_identity_after" ]] || exit 4
            sha_before=$(_act_sha256 "$destination") || exit 4
            size_before=$(_act_file_size "$destination") || exit 4
            [[ "$sha_before" =~ ^[a-fA-F0-9]{64}$ && "$size_before" =~ ^[1-9][0-9]*$ ]] || exit 4
            path_identity_after=$(_act_file_identity "$destination") || exit 4
            [[ "$fd_identity_after" == "$path_identity_after" ]] || exit 4

            exec 9>&-

            local path_identity_final sha_final size_final
            [[ -f "$destination" && ! -L "$destination" ]] || exit 4
            path_identity_final=$(_act_file_identity "$destination") || exit 4
            sha_final=$(_act_sha256 "$destination") || exit 4
            size_final=$(_act_file_size "$destination") || exit 4
            [[ "$path_identity_final" == "$fd_identity_after" &&
               "$sha_final" == "$sha_before" && "$size_final" == "$size_before" ]] || exit 4

            jq -nc \
                --arg path "$destination" \
                --arg sha256 "${sha_final,,}" \
                --argjson size_bytes "$size_final" \
                --arg identity "$path_identity_final" \
                '{path: $path, sha256: $sha256, size_bytes: $size_bytes, identity: $identity}'
        )
    )
    producer_status=$?
    [[ $producer_status -eq 0 ]] || return "$producer_status"

    printf '%s\n' "$receipt"
}

_act_stream_local_file() {
    local source_path="$1"
    [[ -f "$source_path" && ! -L "$source_path" ]] || return 7
    cat -- "$source_path"
}

_act_stream_remote_unix_file() {
    local ssh_destination="$1"
    local source_path="$2"
    local quoted_path="'${source_path//\'/\'\\\'\'}'"
    ssh -o ConnectTimeout="$_ACT_SSH_TIMEOUT" \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new \
        "$ssh_destination" "cat -- $quoted_path"
}

_act_stream_remote_windows_file() {
    local ssh_destination="$1"
    local source_path="$2"
    local ps_path="${source_path//\'/\'\'}"
    local ps_command
    ps_command="\$ErrorActionPreference='Stop'; \$input=[IO.File]::OpenRead('${ps_path}'); try { \$output=[Console]::OpenStandardOutput(); \$input.CopyTo(\$output); \$output.Flush() } finally { \$input.Dispose() }"
    ssh -o ConnectTimeout="$_ACT_SSH_TIMEOUT" \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new \
        "$ssh_destination" \
        "powershell -NoProfile -NonInteractive -Command \"${ps_command}\""
}

_act_stream_workspace_tar() {
    local artifact_dir="$1"
    shift
    (cd "$artifact_dir" && tar czf - "$@")
}

_act_stream_workspace_zip() {
    local artifact_dir="$1"
    shift
    (cd "$artifact_dir" && zip -q - "$@")
}

# Infer archive format from filename
_act_archive_format() {
    local name="$1"
    case "$name" in
        *.tar.gz|*.tgz) echo "tar.gz" ;;
        *.tar.xz) echo "tar.xz" ;;
        *.zip) echo "zip" ;;
        *) echo "none" ;;
    esac
}

_act_is_safe_basename() {
    local name="$1"
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ && "$name" != *..* && "${name,,}" != *.sha256 ]]
}

_act_is_uuid() {
    [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

_act_generate_uuid() {
    local uuid="" random_hex=""

    if command -v uuidgen &>/dev/null; then
        uuid=$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]') || uuid=""
        if _act_is_uuid "$uuid"; then
            printf '%s\n' "$uuid"
            return 0
        fi
    fi

    if [[ -r /dev/urandom ]] && command -v od &>/dev/null; then
        random_hex=$(LC_ALL=C od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d '[:space:]') || \
            random_hex=""
    fi
    if [[ ! "$random_hex" =~ ^[0-9a-f]{32}$ ]]; then
        return 3
    fi

    printf '%s-%s-4%s-8%s-%s\n' \
        "${random_hex:0:8}" "${random_hex:8:4}" "${random_hex:13:3}" \
        "${random_hex:17:3}" "${random_hex:20:12}"
}

_act_read_hex_bytes() {
    local file="$1"
    local offset="$2"
    local count="$3"
    local hex

    if [[ ! "$offset" =~ ^[0-9]+$ || ! "$count" =~ ^[1-9][0-9]*$ ]]; then
        return 4
    fi
    if ! hex=$(LC_ALL=C od -An -v -j "$offset" -N "$count" -tx1 "$file" 2>/dev/null | \
        tr -d '[:space:]' | tr '[:upper:]' '[:lower:]'); then
        return 4
    fi
    if [[ ${#hex} -ne $((count * 2)) || ! "$hex" =~ ^[0-9a-f]+$ ]]; then
        return 4
    fi
    printf '%s\n' "$hex"
}

_act_validate_target_binary() {
    local file="$1"
    local target="$2"
    local size header machine pe_offset_hex pe_offset optional_magic

    if [[ ! -f "$file" || -L "$file" ]]; then
        _log_error "Target primary is not a regular non-symlink file: $file"
        return 4
    fi
    size=$(_act_file_size "$file")
    if [[ ! "$size" =~ ^[1-9][0-9]*$ ]]; then
        _log_error "Target primary has no readable bytes: $file"
        return 4
    fi

    case "$target" in
        linux/amd64|linux/arm64)
            if ((size < 64)) || ! header=$(_act_read_hex_bytes "$file" 0 20); then
                _log_error "Target primary is not a complete ELF64 header: $file"
                return 4
            fi
            machine="${header:36:4}"
            if [[ "${header:0:8}" != "7f454c46" || "${header:8:2}" != "02" || \
                  "${header:10:2}" != "01" ]] || \
               { [[ "$target" == "linux/amd64" ]] && [[ "$machine" != "3e00" ]]; } || \
               { [[ "$target" == "linux/arm64" ]] && [[ "$machine" != "b700" ]]; }; then
                _log_error "Target primary ELF format/architecture does not match $target: $file"
                return 4
            fi
            if [[ ! -x "$file" ]]; then
                _log_error "Unix target primary is not executable: $file"
                return 4
            fi
            ;;
        darwin/amd64|darwin/arm64)
            if ((size < 32)) || ! header=$(_act_read_hex_bytes "$file" 0 8); then
                _log_error "Target primary is not a complete Mach-O 64 header: $file"
                return 4
            fi
            machine="${header:8:8}"
            if [[ "${header:0:8}" != "cffaedfe" ]] || \
               { [[ "$target" == "darwin/amd64" ]] && [[ "$machine" != "07000001" ]]; } || \
               { [[ "$target" == "darwin/arm64" ]] && [[ "$machine" != "0c000001" ]]; }; then
                _log_error "Target primary Mach-O format/architecture does not match $target: $file"
                return 4
            fi
            if [[ ! -x "$file" ]]; then
                _log_error "Unix target primary is not executable: $file"
                return 4
            fi
            ;;
        windows/amd64|windows/arm64)
            if ((size < 90)) || [[ "$(_act_read_hex_bytes "$file" 0 2 2>/dev/null || true)" != "4d5a" ]] || \
               ! pe_offset_hex=$(_act_read_hex_bytes "$file" 60 4); then
                _log_error "Target primary is not a complete PE32+ executable: $file"
                return 4
            fi
            pe_offset=$((0x${pe_offset_hex:6:2}${pe_offset_hex:4:2}${pe_offset_hex:2:2}${pe_offset_hex:0:2}))
            if ((pe_offset < 64 || pe_offset + 26 > size)) || \
               [[ "$(_act_read_hex_bytes "$file" "$pe_offset" 4 2>/dev/null || true)" != "50450000" ]] || \
               ! machine=$(_act_read_hex_bytes "$file" "$((pe_offset + 4))" 2) || \
               ! optional_magic=$(_act_read_hex_bytes "$file" "$((pe_offset + 24))" 2) || \
               [[ "$optional_magic" != "0b02" ]] || \
               { [[ "$target" == "windows/amd64" ]] && [[ "$machine" != "6486" ]]; } || \
               { [[ "$target" == "windows/arm64" ]] && [[ "$machine" != "64aa" ]]; }; then
                _log_error "Target primary PE format/architecture does not match $target: $file"
                return 4
            fi
            ;;
        *)
            _log_error "Unsupported strict release target: $target"
            return 4
            ;;
    esac
}

_act_stage_contract_primary() {
    local tool_name="$1"
    local version="$2"
    local run_id="$3"
    local target="$4"
    local result_json="$5"
    local contract_json="$6"

    local expected_name
    expected_name=$(jq -r --arg target "$target" '.exact_primary_assets[$target] // empty' <<< "$contract_json")
    if ! _act_is_safe_basename "$expected_name"; then
        _log_error "Unsafe or missing release asset basename for $target"
        return 4
    fi

    local config_file="$ACT_REPOS_DIR/${tool_name}.yaml"
    local binary_name expected_input_name
    if [[ ! -f "$config_file" ]] || \
       ! binary_name=$(yq -r '.binary_name // ""' "$config_file" 2>/dev/null) || \
       ! _act_is_safe_basename "$binary_name"; then
        _log_error "Strict release contract requires a safe configured binary_name"
        return 4
    fi
    expected_input_name="$binary_name"
    [[ "$target" == windows/* ]] && expected_input_name="${binary_name%.exe}.exe"

    local candidate_paths=()
    local artifact_path artifact_dir candidate
    artifact_path=$(jq -r '.artifact_path // empty' <<< "$result_json")
    artifact_dir=$(jq -r '.artifact_dir // empty' <<< "$result_json")

    if [[ -n "$artifact_path" ]]; then
        while IFS= read -r candidate; do
            [[ -n "$candidate" ]] && candidate_paths+=("$candidate")
        done < <(printf '%s\n' "$artifact_path" | tr ',' '\n')
    fi
    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] && candidate_paths+=("$candidate")
    done < <(jq -r '.artifact_paths[]? // empty' <<< "$result_json")

    local -A stage_seen_paths=()
    local unique_paths=()
    for candidate in "${candidate_paths[@]}"; do
        [[ -n "${stage_seen_paths[$candidate]:-}" ]] && continue
        stage_seen_paths["$candidate"]=1
        unique_paths+=("$candidate")
    done

    if [[ ${#unique_paths[@]} -eq 0 && -n "$artifact_dir" && -d "$artifact_dir" ]]; then
        while IFS= read -r -d '' candidate; do
            unique_paths+=("$candidate")
        done < <(find "$artifact_dir" -type f ! -type l -name "$expected_input_name" -print0 2>/dev/null)
    fi

    if [[ ${#unique_paths[@]} -ne 1 ]]; then
        _log_error "Release target $target requires one unambiguous primary artifact (found ${#unique_paths[@]})"
        return 4
    fi

    local source_path="${unique_paths[0]}"
    if [[ ! -f "$source_path" || -L "$source_path" ]]; then
        _log_error "Release primary must be a regular non-symlink file: $source_path"
        return 4
    fi
    if [[ "$(basename "$source_path")" != "$expected_input_name" ]]; then
        _log_error "Release primary input for $target must be named $expected_input_name"
        return 4
    fi
    case "$(basename "$source_path")" in
        *.sha256|*.sha512|*.minisig|*.sig|*.sbom.*|*.intoto.jsonl)
            _log_error "Release primary candidate is metadata, not a binary/archive: $source_path"
            return 4
            ;;
    esac
    if ! _act_validate_target_binary "$source_path" "$target"; then
        return 4
    fi

    local collected_sha collected_size collected_identity
    collected_sha=$(jq -r '.collected_sha256 // empty' <<< "$result_json")
    collected_size=$(jq -r '.collected_size_bytes // empty' <<< "$result_json")
    collected_identity=$(jq -r '.collected_identity // empty' <<< "$result_json")
    if [[ ! "$collected_sha" =~ ^[0-9a-f]{64}$ ||
          ! "$collected_size" =~ ^[1-9][0-9]*$ ||
          ! "$collected_identity" =~ ^(gnu:[0-9]+:[1-9][0-9]*|bsd:[1-9][0-9]*)$ ]]; then
        _log_error "Release target $target is missing its frozen native collection receipt"
        return 4
    fi

    local source_sha_before source_size_before source_identity_before
    if ! source_sha_before=$(_act_sha256 "$source_path") ||
       ! source_size_before=$(_act_file_size "$source_path") ||
       ! source_identity_before=$(_act_file_identity "$source_path") ||
       [[ ! "$source_sha_before" =~ ^[a-fA-F0-9]{64}$ ]] ||
       [[ ! "$source_size_before" =~ ^[0-9]+$ ]] ||
       [[ "${source_sha_before,,}" != "$collected_sha" ||
          "$source_size_before" != "$collected_size" ||
          "$source_identity_before" != "$collected_identity" ]]; then
        _log_error "Unable to identify release primary before staging: $source_path"
        return 4
    fi

    local target_slug="${target//\//-}"
    local stage_root="$ACT_ARTIFACTS_DIR/${tool_name}-v${version#v}/$run_id/release-contract"
    local stage_dir
    if ! mkdir -p "$stage_root" || [[ ! -d "$stage_root" || -L "$stage_root" ]]; then
        _log_error "Unable to create private release contract staging root: $stage_root"
        return 4
    fi
    if ! stage_dir=$(mktemp -d "$stage_root/${target_slug}.XXXXXXXX"); then
        _log_error "Unable to create private release contract staging directory for $target"
        return 4
    fi
    if ! chmod 700 "$stage_dir" || [[ ! -d "$stage_dir" || -L "$stage_dir" ]]; then
        _log_error "Release contract staging directory is not private and regular: $stage_dir"
        return 4
    fi
    local staged_path="$stage_dir/$expected_name"
    if [[ -e "$staged_path" || -L "$staged_path" ]]; then
        _log_error "Refusing existing release contract staging destination: $staged_path"
        return 4
    fi
    # Noclobber supplies O_EXCL for destination creation. Keep that inode open
    # while copying so a same-user rename/symlink race cannot redirect bytes to
    # another file between the existence check and the copy.
    if ! (
        set -C
        umask 077
        exec 9> "$staged_path" || exit 4
        cat -- "$source_path" >&9 || exit 4
        if [[ -x "$source_path" ]]; then
            chmod 700 /dev/fd/9 || exit 4
        else
            chmod 600 /dev/fd/9 || exit 4
        fi
        exec 9>&-
    ); then
        _log_error "Unable to stage release primary for $target"
        return 4
    fi
    if [[ ! -f "$staged_path" || -L "$staged_path" ]]; then
        _log_error "Staged release primary is not a regular file: $staged_path"
        return 4
    fi
    if ! _act_validate_target_binary "$staged_path" "$target"; then
        return 4
    fi

    local source_sha_after source_size_after source_identity_after
    local staged_sha staged_size staged_identity_before staged_identity_after
    if ! source_sha_after=$(_act_sha256 "$source_path") ||
       ! source_size_after=$(_act_file_size "$source_path") ||
       ! source_identity_after=$(_act_file_identity "$source_path") ||
       ! staged_identity_before=$(_act_file_identity "$staged_path") ||
       ! staged_sha=$(_act_sha256 "$staged_path") ||
       ! staged_size=$(_act_file_size "$staged_path") ||
       ! staged_identity_after=$(_act_file_identity "$staged_path") ||
       [[ ! "$source_sha_after" =~ ^[a-fA-F0-9]{64}$ ]] ||
       [[ ! "$source_size_after" =~ ^[0-9]+$ ]] ||
       [[ ! "$staged_sha" =~ ^[a-fA-F0-9]{64}$ ]] ||
       [[ ! "$staged_size" =~ ^[0-9]+$ ]] ||
       [[ ! -f "$staged_path" || -L "$staged_path" ]] ||
       [[ "$source_identity_before" != "$source_identity_after" ]] ||
       [[ "$staged_identity_before" != "$staged_identity_after" ]]; then
        _log_error "Unable to identify release primary after staging: $source_path"
        return 4
    fi

    if ! [[ "$source_sha_before" == "$source_sha_after" &&
            "$source_size_before" == "$source_size_after" &&
            "$source_sha_before" == "$staged_sha" &&
            "$source_size_before" == "$staged_size" ]]; then
        _log_error "Release primary changed while staging for $target"
        return 4
    fi

    jq -c \
        --arg path "$staged_path" \
        --arg dir "$stage_dir" \
        --arg staged_sha256 "${staged_sha,,}" \
        --argjson staged_size_bytes "$staged_size" \
        --arg staged_identity "$staged_identity_after" '
        .artifact_path = $path |
        .artifact_paths = [$path] |
        .artifact_dir = $dir |
        .staged_sha256 = $staged_sha256 |
        .staged_size_bytes = $staged_size_bytes |
        .staged_identity = $staged_identity |
        .build_influence_env = (.build_influence_env // {})
    ' <<< "$result_json"
}

_act_release_contract_json() {
    local tool_name="$1"
    local contract="null"

    if ! declare -F config_get_release_contract_json &>/dev/null; then
        printf '%s\n' "$contract"
        return 0
    fi

    if ! contract=$(config_get_release_contract_json "$tool_name"); then
        _log_error "Failed to read release contract for $tool_name"
        return 4
    fi
    [[ -n "$contract" ]] || contract="null"

    if [[ "$contract" != "null" ]]; then
        if ! declare -F config_validate_release_contract &>/dev/null || \
           ! config_validate_release_contract "$tool_name"; then
            _log_error "Invalid release contract for $tool_name"
            return 4
        fi
    fi

    printf '%s\n' "$contract"
}

_act_release_source_dependencies_json() {
    local tool_name="$1"
    local dependencies

    if ! declare -F config_get_release_source_dependencies_json &>/dev/null || \
       ! dependencies=$(config_get_release_source_dependencies_json "$tool_name"); then
        _log_error "Unable to read pinned release source dependencies for $tool_name"
        return 4
    fi
    if ! jq -e '
        type == "array" and
        . == (sort_by(.relative_path)) and
        ([.[].relative_path] | length) == ([.[].relative_path] | unique | length) and
        all(.[];
            (keys | sort) == ["git_sha", "relative_path"] and
            (.relative_path | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._+-]*$") and (contains("..") | not)) and
            (.git_sha | type == "string" and test("^(?!0{40}$)[0-9a-f]{40}$"))
        )
    ' <<< "$dependencies" >/dev/null 2>&1; then
        _log_error "Invalid pinned release source dependency projection for $tool_name"
        return 4
    fi
    printf '%s\n' "$dependencies" | jq -cS .
}

_act_release_source_dependency_checkouts_json() {
    local tool_name="$1"
    local checkouts dependencies

    if ! declare -F _config_get_release_source_dependency_checkouts_json &>/dev/null || \
       ! checkouts=$(_config_get_release_source_dependency_checkouts_json "$tool_name") || \
       ! dependencies=$(_act_release_source_dependencies_json "$tool_name"); then
        _log_error "Unable to read pinned release source checkouts for $tool_name"
        return 4
    fi
    if ! jq -en --argjson checkouts "$checkouts" --argjson dependencies "$dependencies" '
        ($checkouts | type) == "array" and
        $checkouts == ($checkouts | sort_by(.relative_path)) and
        ([$checkouts[].relative_path] | length) == ([$checkouts[].relative_path] | unique | length) and
        all($checkouts[];
            (keys | sort) == ["git_sha", "local_path", "relative_path"] and
            (.local_path | type == "string" and startswith("/") and length > 1) and
            (.relative_path | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._+-]*$") and (contains("..") | not)) and
            (.git_sha | type == "string" and test("^(?!0{40}$)[0-9a-f]{40}$"))
        ) and
        ([$checkouts[] | {git_sha, relative_path}] == $dependencies)
    ' >/dev/null 2>&1; then
        _log_error "Pinned release source checkouts do not match manifest dependencies for $tool_name"
        return 4
    fi
    printf '%s\n' "$checkouts" | jq -cS .
}

_act_validate_contract_source_identity() {
    local version="$1"
    local git_sha="$2"
    local git_ref="$3"
    local tool_name="$4"
    local repo_path="${ACT_REPO_LOCAL_PATH:-}"
    local expected_ref="v${version#v}"

    if [[ ! "$git_sha" =~ ^[0-9a-f]{40}$ || "$git_sha" =~ ^0{40}$ ]]; then
        _log_error "Release contract requires a nonzero 40-hex git SHA"
        return 4
    fi
    if [[ ! "$git_ref" =~ ^v[0-9A-Za-z][0-9A-Za-z._-]*$ || "$git_ref" != "$expected_ref" ]]; then
        _log_error "Release contract requires version tag $expected_ref"
        return 4
    fi
    if [[ -z "$repo_path" ]] || ! command -v git &>/dev/null; then
        _log_error "Release contract source repository is unavailable"
        return 4
    fi

    local head_sha tag_sha source_status
    if ! head_sha=$(git -C "$repo_path" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || \
       [[ ! "$head_sha" =~ ^[0-9a-f]{40}$ ]]; then
        _log_error "Unable to resolve local HEAD for release contract"
        return 4
    fi
    if ! tag_sha=$(git -C "$repo_path" rev-parse --verify "refs/tags/${git_ref}^{commit}" 2>/dev/null) || \
       [[ ! "$tag_sha" =~ ^[0-9a-f]{40}$ ]]; then
        _log_error "Unable to resolve release tag $git_ref"
        return 4
    fi
    if ! [[ "$git_sha" == "$head_sha" && "$git_sha" == "$tag_sha" ]]; then
        _log_error "Release source mismatch: supplied SHA, HEAD, and $git_ref must match"
        return 4
    fi
    if ! source_status=$(git -C "$repo_path" status --porcelain --untracked-files=all 2>/dev/null); then
        _log_error "Unable to inspect release source tree cleanliness"
        return 4
    fi
    if [[ -n "$source_status" ]]; then
        _log_error "Release contract requires a clean source tree, including untracked files"
        return 4
    fi

    local checkouts_json dependency dependency_path dependency_sha dependency_head dependency_revision dependency_status
    if ! checkouts_json=$(_act_release_source_dependency_checkouts_json "$tool_name"); then
        return 4
    fi
    while IFS= read -r dependency; do
        [[ -n "$dependency" ]] || continue
        dependency_path=$(jq -r '.local_path' <<< "$dependency")
        dependency_sha=$(jq -r '.git_sha' <<< "$dependency")
        if [[ ! -d "$dependency_path" ]]; then
            _log_error "Pinned release source dependency is missing: $dependency_path"
            return 4
        fi
        if ! dependency_head=$(git -C "$dependency_path" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || \
           ! dependency_revision=$(git -C "$dependency_path" rev-parse --verify "${dependency_sha}^{commit}" 2>/dev/null) || \
           [[ "$dependency_head" != "$dependency_sha" || "$dependency_revision" != "$dependency_sha" ]]; then
            _log_error "Pinned release source dependency is not checked out at $dependency_sha: $dependency_path"
            return 4
        fi
        if ! dependency_status=$(git -C "$dependency_path" status --porcelain --untracked-files=all 2>/dev/null); then
            _log_error "Unable to inspect release source dependency: $dependency_path"
            return 4
        fi
        if [[ -n "$dependency_status" ]]; then
            _log_error "Pinned release source dependency is dirty: $dependency_path"
            return 4
        fi
    done < <(jq -c '.[]' <<< "$checkouts_json")

    return 0
}

# Timeout helper (supports GNU timeout and coreutils gtimeout)
_ACT_TIMEOUT_CMD=""
_act_timeout_cmd() {
    if [[ -n "$_ACT_TIMEOUT_CMD" ]]; then
        echo "$_ACT_TIMEOUT_CMD"
        return 0
    fi

    if command -v timeout &>/dev/null; then
        _ACT_TIMEOUT_CMD="timeout"
    elif command -v gtimeout &>/dev/null; then
        _ACT_TIMEOUT_CMD="gtimeout"
    else
        _ACT_TIMEOUT_CMD=""
    fi

    echo "$_ACT_TIMEOUT_CMD"
}

_act_run_with_timeout() {
    local seconds="$1"
    shift
    local cmd
    cmd=$(_act_timeout_cmd)
    if [[ -n "$cmd" ]]; then
        "$cmd" "$seconds" "$@"
    else
        "$@"
    fi
}

# Return the first act config file in a home directory that has --bind without
# a matching --user container option.
_act_find_bind_without_user_config() {
    local check_home="${1:-$HOME}"
    local actrc_file

    for actrc_file in "$check_home/.actrc" "$check_home/.config/act/actrc"; do
        [[ -f "$actrc_file" ]] || continue

        local has_bind=false
        local has_user=false
        if command grep -qE '^[[:space:]]*--bind([[:space:]]|$)' "$actrc_file" 2>/dev/null; then
            has_bind=true
        fi
        if command grep -qE -- '--container-options.*--user|--container-options=.*--user' "$actrc_file" 2>/dev/null; then
            has_user=true
        fi

        if $has_bind && ! $has_user; then
            printf '%s\n' "$actrc_file"
            return 0
        fi
    done

    return 1
}

_act_installed_version() {
    act --version 2>/dev/null | sed -nE 's/^act version v?([0-9][0-9.]*).*/\1/p' | head -1
}

_act_version_ge() {
    local actual="${1#v}"
    local minimum="${2#v}"
    local actual_major actual_minor actual_patch minimum_major minimum_minor minimum_patch

    actual="${actual%%[-+]*}"
    minimum="${minimum%%[-+]*}"

    IFS=. read -r actual_major actual_minor actual_patch _ <<< "$actual"
    IFS=. read -r minimum_major minimum_minor minimum_patch _ <<< "$minimum"

    actual_major="${actual_major:-0}"
    actual_minor="${actual_minor:-0}"
    actual_patch="${actual_patch:-0}"
    minimum_major="${minimum_major:-0}"
    minimum_minor="${minimum_minor:-0}"
    minimum_patch="${minimum_patch:-0}"

    [[ "$actual_major$actual_minor$actual_patch$minimum_major$minimum_minor$minimum_patch" =~ ^[0-9]+$ ]] || return 1

    if ((10#$actual_major != 10#$minimum_major)); then
        ((10#$actual_major > 10#$minimum_major))
        return $?
    fi
    if ((10#$actual_minor != 10#$minimum_minor)); then
        ((10#$actual_minor > 10#$minimum_minor))
        return $?
    fi
    ((10#$actual_patch >= 10#$minimum_patch))
}

act_version_is_supported() {
    local version="${1:-}"

    if [[ -z "$version" ]]; then
        version="$(_act_installed_version)"
    fi

    [[ -n "$version" ]] && _act_version_ge "$version" "$ACT_MIN_VERSION"
}

# Check if act and Docker are available.
act_check_prereqs() {
    if ! command -v act &>/dev/null; then
        _log_error "act not found. Install: brew install act (macOS) or go install github.com/nektos/act@latest"
        return 3
    fi

    local act_version
    act_version="$(_act_installed_version)"
    if ! act_version_is_supported "$act_version"; then
        _log_error "act ${act_version:-unknown} is unsupported; install act v${ACT_MIN_VERSION}+ before running local release builds"
        return 3
    fi

    if ! docker info &>/dev/null; then
        _log_error "Docker daemon not running or not accessible"
        return 3
    fi

    return 0
}

# Check if act is available and properly configured
act_check() {
    local check_home="${1:-$HOME}"

    if ! act_check_prereqs; then
        return 3
    fi

    # CRITICAL: Check for UID mismatch configuration
    # catthehacker images run as UID 1001. Without --user flag,
    # files created by act will have wrong ownership!
    local bad_actrc=""
    if bad_actrc=$(_act_find_bind_without_user_config "$check_home"); then
        _log_error "═══════════════════════════════════════════════════════════════════"
        _log_error "CRITICAL: $bad_actrc has --bind but missing --user flag!"
        _log_error ""
        _log_error "Files created by act will have WRONG OWNERSHIP (UID 1001 instead of $(id -u))"
        _log_error "This WILL corrupt your repository with inaccessible files!"
        _log_error ""
        _log_error "FIX: Add this line to the affected act config:"
        _log_error "    --container-options --user=$(id -u):$(id -g)"
        _log_error ""
        _log_error "Or run: dsr doctor --fix"
        _log_error "═══════════════════════════════════════════════════════════════════"
        return 3
    fi

    return 0
}

# List jobs in a workflow
# Usage: act_list_jobs <workflow_file>
# Returns: JSON array of job definitions
act_list_jobs() {
    local workflow="$1"

    if [[ ! -f "$workflow" ]]; then
        _log_error "Workflow file not found: $workflow"
        return 4
    fi

    # Parse workflow YAML to extract job info
    # act -l outputs: Stage  Job ID  Job name  Workflow name  Workflow file  Events
    act -l -W "$workflow" 2>/dev/null | tail -n +2 | while IFS=$'\t' read -r _ job_id _ _ _ _; do
        echo "$job_id"
    done
}

# Get runs-on value for a job
# Usage: act_get_runner <workflow_file> <job_id>
act_get_runner() {
    local workflow="$1"
    local job_id="$2"

    # Parse YAML to get runs-on (simplified, assumes standard format)
    # For complex cases, use yq
    if command -v yq &>/dev/null; then
        yq ".jobs.$job_id.runs-on" "$workflow" 2>/dev/null
    else
        # Fallback: grep-based extraction (handles simple cases)
        awk -v job="$job_id:" '
            $0 ~ "^[[:space:]]*" job { in_job=1 }
            in_job && /runs-on:/ { gsub(/.*runs-on:[ ]*/, ""); gsub(/["\047]/, ""); print; exit }
            in_job && /^[[:space:]]*[a-zA-Z]/ && $0 !~ job { exit }
        ' "$workflow"
    fi
}

# Check if a job can run via act (Linux runner)
# Usage: act_can_run <runs_on_value>
# Returns: 0 if can run, 1 if needs native runner
act_can_run() {
    local runs_on="$1"

    case "$runs_on" in
        ubuntu-*)
            return 0
            ;;
        macos-*|windows-*)
            return 1
            ;;
        self-hosted*)
            # Check for linux label
            if [[ "$runs_on" == *"linux"* ]]; then
                return 0
            fi
            return 1
            ;;
        *)
            _log_warn "Unknown runner: $runs_on, assuming Linux"
            return 0
            ;;
    esac
}

# Detect workflows that reference sibling paths outside the repository root,
# such as `git clone ... ../frankensqlite`. act exposes the parent directory as
# root-owned, so these workflows need special handling.
_act_workflow_needs_writable_parent() {
    local workflow_path="$1"

    [[ -f "$workflow_path" ]] || return 1
    command grep -Eq '\.\./[[:alnum:]_.-]+' "$workflow_path" 2>/dev/null
}

# Prepare an isolated act config that removes bind/user overrides from the
# user's persistent config, then runs the job container as root so workflows
# can create sibling directories outside the repo root.
_act_prepare_isolated_home() {
    local real_home="${HOME:-$PWD}"
    local cache_root="${DSR_CACHE_DIR:-${XDG_CACHE_HOME:-$real_home/.cache}/dsr}/act-homes"
    local run_id
    run_id="$(date +%Y%m%d-%H%M%S)-$$"

    local isolated_home="$cache_root/$run_id"
    local config_dir="$isolated_home/.config/act"
    local actrc="$config_dir/actrc"

    if ! mkdir -p "$config_dir" "$isolated_home/.cache"; then
        _log_error "Failed to prepare isolated act home: $isolated_home"
        return 1
    fi

    local found_platform=false
    local source_file line
    for source_file in "$real_home/.actrc" "$real_home/.config/act/actrc"; do
        [[ -f "$source_file" ]] || continue

        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" =~ ^[[:space:]]*--bind([[:space:]]|$) ]]; then
                continue
            fi
            if [[ "$line" =~ ^[[:space:]]*--artifact-server-path([[:space:]=]|$) ]]; then
                continue
            fi
            if [[ "$line" =~ --container-options ]] && [[ "$line" =~ --user ]]; then
                continue
            fi
            if [[ "$line" =~ ^[[:space:]]*(-P|--platform)[[:space:]]+ubuntu- ]]; then
                found_platform=true
            fi
            printf '%s\n' "$line" >> "$actrc"
        done < "$source_file"
    done

    if ! $found_platform; then
        cat >> "$actrc" <<'EOF'
-P ubuntu-latest=catthehacker/ubuntu:full-22.04
-P ubuntu-22.04=catthehacker/ubuntu:full-22.04
-P ubuntu-20.04=catthehacker/ubuntu:full-20.04
EOF
    fi

    if [[ -f "$real_home/.gitconfig" ]]; then
        ln -s "$real_home/.gitconfig" "$isolated_home/.gitconfig" 2>/dev/null || true
    fi
    if [[ -f "$real_home/.git-credentials" ]]; then
        ln -s "$real_home/.git-credentials" "$isolated_home/.git-credentials" 2>/dev/null || true
    fi
    if [[ -d "$real_home/.config/gh" ]]; then
        ln -s "$real_home/.config/gh" "$isolated_home/.config/gh" 2>/dev/null || true
    fi

    printf '%s\n' '--container-options --user 0:0' >> "$actrc"
    echo "$isolated_home"
}

# Run a workflow via act
# Usage: act_run_workflow <repo_path> <workflow> [job] [event] [version] [extra_args...]
# Returns: exit code (0=success, 1=partial, 6=build failed, 3=dependency error)
# Note: When version is provided, GITHUB_REF/GITHUB_REF_NAME/GITHUB_REF_TYPE are injected
#       to simulate a tag push for release workflows
act_run_workflow() {
    local repo_path="$1"
    local workflow="$2"
    local job="${3:-}"
    local event="${4:-push}"
    local version="${5:-}"
    shift 5 2>/dev/null || true
    local extra_args=("$@")

    local workflow_path="$repo_path/$workflow"
    if [[ ! -f "$workflow_path" ]]; then
        _log_error "Workflow not found: $workflow_path"
        return 4
    fi

    # Create run directories
    local run_id
    run_id="$(date +%Y%m%d-%H%M%S)-$$"
    local artifact_dir="$ACT_ARTIFACTS_DIR/$run_id"
    local log_file="$ACT_LOGS_DIR/$run_id.log"

    if ! mkdir -p "$artifact_dir" "$ACT_LOGS_DIR"; then
        _log_error "Failed to create run directories: $artifact_dir, $ACT_LOGS_DIR"
        return 1
    fi

    # Build act command
    local act_cmd=(
        act
        -W "$workflow"
        --artifact-server-path "$artifact_dir"
    )

    # Add job filter if specified
    if [[ -n "$job" ]]; then
        act_cmd+=(-j "$job")
    fi

    # Add event
    act_cmd+=("$event")

    # Inject tag context for release workflows when version is provided
    # This simulates a tag push so workflows can detect the version
    if [[ -n "$version" ]]; then
        local tag="v${version#v}"  # Ensure v prefix, avoid doubling
        act_cmd+=(--env "GITHUB_REF=refs/tags/$tag")
        act_cmd+=(--env "GITHUB_REF_NAME=$tag")
        act_cmd+=(--env "GITHUB_REF_TYPE=tag")
        _log_info "Injecting tag context: $tag"
    fi

    # Ensure USER is set inside act containers (some workflows rely on it)
    if [[ -n "${USER:-}" ]]; then
        act_cmd+=(--env "USER=$USER")
    else
        local fallback_user
        fallback_user=$(id -un 2>/dev/null || echo "runner")
        act_cmd+=(--env "USER=$fallback_user")
    fi

    # Add any extra arguments
    if [[ ${#extra_args[@]} -gt 0 ]]; then
        act_cmd+=("${extra_args[@]}")
    fi

    local isolated_home=""
    if _act_workflow_needs_writable_parent "$workflow_path"; then
        isolated_home=$(_act_prepare_isolated_home) || return 1
        _log_warn "Workflow writes outside repo root; using isolated act config without --bind"
        _log_info "Isolated act home: $isolated_home"
    fi

    local check_home="${HOME:-}"
    [[ -n "$isolated_home" ]] && check_home="$isolated_home"
    if ! act_check "$check_home"; then
        return 3
    fi

    _log_info "Running: ${act_cmd[*]}"
    _log_info "Artifacts: $artifact_dir"
    _log_info "Log: $log_file"

    local start_time
    start_time=$(date +%s)

    # Run act with timeout
    # Use PIPESTATUS to capture the actual command exit code, not tee's
    local timeout_cmd
    timeout_cmd=$(_act_timeout_cmd)
    if [[ -n "$timeout_cmd" ]]; then
        if [[ -n "$isolated_home" ]]; then
            HOME="$isolated_home" \
            XDG_CONFIG_HOME="$isolated_home/.config" \
            XDG_CACHE_HOME="$isolated_home/.cache" \
            "$timeout_cmd" "$ACT_TIMEOUT" "${act_cmd[@]}" \
                --directory "$repo_path" \
                2>&1 | tee "$log_file"
        else
            "$timeout_cmd" "$ACT_TIMEOUT" "${act_cmd[@]}" \
                --directory "$repo_path" \
                2>&1 | tee "$log_file"
        fi
    else
        _log_warn "timeout command not available; running act without timeout"
        if [[ -n "$isolated_home" ]]; then
            HOME="$isolated_home" \
            XDG_CONFIG_HOME="$isolated_home/.config" \
            XDG_CACHE_HOME="$isolated_home/.cache" \
            "${act_cmd[@]}" \
                --directory "$repo_path" \
                2>&1 | tee "$log_file"
        else
            "${act_cmd[@]}" \
                --directory "$repo_path" \
                2>&1 | tee "$log_file"
        fi
    fi
    local exit_code=${PIPESTATUS[0]}

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    # Output results as JSON (to stdout)
    local artifact_count status
    artifact_count=$(find "$artifact_dir" -type f 2>/dev/null | wc -l)

    if [[ "$exit_code" -eq 0 ]]; then
        _log_ok "Workflow completed successfully in ${duration}s"
        status="success"
    elif [[ "$exit_code" -eq 124 ]]; then
        _log_error "Workflow timed out after ${ACT_TIMEOUT}s"
        status="timeout"
        exit_code=5
    else
        _log_error "Workflow failed with exit code $exit_code"
        status="failed"
        exit_code=6
    fi

    # Return JSON result
    jq -nc \
        --arg run_id "$run_id" \
        --arg workflow "$workflow" \
        --arg job "${job:-all}" \
        --arg status "$status" \
        --argjson exit_code "$exit_code" \
        --argjson duration_seconds "$duration" \
        --arg artifact_dir "$artifact_dir" \
        --argjson artifact_count "$artifact_count" \
        --arg log_file "$log_file" \
        '{
            run_id: $run_id,
            workflow: $workflow,
            job: $job,
            status: $status,
            exit_code: $exit_code,
            duration_seconds: $duration_seconds,
            artifact_dir: $artifact_dir,
            artifact_count: $artifact_count,
            log_file: $log_file
        }'

    return "$exit_code"
}

# Collect artifacts from act run
# Usage: act_collect_artifacts <artifact_dir> <output_dir>
act_collect_artifacts() {
    local artifact_dir="$1"
    local output_dir="$2"

    if [[ ! -d "$artifact_dir" ]]; then
        _log_error "Artifact directory not found: $artifact_dir"
        return 1
    fi

    if ! mkdir -p "$output_dir"; then
        _log_error "Failed to create output directory: $output_dir"
        return 1
    fi

    # act stores artifacts in subdirectories by artifact name
    local count=0
    local failed=0
    while IFS= read -r -d '' artifact; do
        local basename
        basename=$(basename "$artifact")
        if cp "$artifact" "$output_dir/$basename"; then
            _log_info "Collected: $basename"
            ((count++))
        else
            _log_error "Failed to copy artifact: $artifact"
            ((failed++))
        fi
    done < <(find "$artifact_dir" -type f -print0)

    if [[ $failed -gt 0 ]]; then
        _log_error "Failed to collect $failed artifact(s)"
        return 1
    fi

    _log_ok "Collected $count artifacts"
    return 0
}

# Parse workflow to identify platform targets
# Usage: act_analyze_workflow <workflow_file>
# Returns: JSON with platform breakdown
act_analyze_workflow() {
    local workflow="$1"

    if [[ ! -f "$workflow" ]]; then
        _log_error "Workflow not found: $workflow"
        return 4
    fi

    local linux_jobs=()
    local macos_jobs=()
    local windows_jobs=()
    local other_jobs=()

    # Parse workflow to categorize jobs by runner
    while IFS= read -r job_id; do
        local runner
        runner=$(act_get_runner "$workflow" "$job_id")

        case "$runner" in
            ubuntu-*|*linux*)
                linux_jobs+=("$job_id")
                ;;
            macos-*)
                macos_jobs+=("$job_id")
                ;;
            windows-*)
                windows_jobs+=("$job_id")
                ;;
            *)
                other_jobs+=("$job_id")
                ;;
        esac
    done < <(act_list_jobs "$workflow")

    # Helper to convert array to JSON array (handles empty arrays correctly)
    _array_to_json() {
        if [[ $# -eq 0 ]]; then
            echo "[]"
        else
            printf '%s\n' "$@" | jq -R . | jq -s .
        fi
    }

    # Output JSON analysis
    jq -nc \
        --arg workflow "$workflow" \
        --argjson linux_jobs "$(_array_to_json "${linux_jobs[@]+"${linux_jobs[@]}"}")" \
        --argjson macos_jobs "$(_array_to_json "${macos_jobs[@]+"${macos_jobs[@]}"}")" \
        --argjson windows_jobs "$(_array_to_json "${windows_jobs[@]+"${windows_jobs[@]}"}")" \
        --argjson other_jobs "$(_array_to_json "${other_jobs[@]+"${other_jobs[@]}"}")" \
        --argjson act_compatible "${#linux_jobs[@]}" \
        --argjson native_required "$((${#macos_jobs[@]} + ${#windows_jobs[@]}))" \
        '{
            workflow: $workflow,
            linux_jobs: $linux_jobs,
            macos_jobs: $macos_jobs,
            windows_jobs: $windows_jobs,
            other_jobs: $other_jobs,
            act_compatible: $act_compatible,
            native_required: $native_required
        }'
}

# Clean up old act artifacts
# Usage: act_cleanup [days]
act_cleanup() {
    local days="${1:-7}"

    _log_info "Cleaning artifacts older than $days days..."

    find "$ACT_ARTIFACTS_DIR" -type d -mtime +"$days" -exec rm -rf {} + 2>/dev/null || true
    find "$ACT_LOGS_DIR" -type f -mtime +"$days" -delete 2>/dev/null || true

    _log_ok "Cleanup complete"
}

# ============================================================================
# Compatibility Matrix Functions
# ============================================================================

# Configuration directories
ACT_CONFIG_DIR="${DSR_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/dsr}"
ACT_REPOS_DIR="${ACT_CONFIG_DIR}/repos.d"

# Load repo configuration
# Usage: act_load_repo_config <tool_name>
# Returns: Sets global ACT_REPO_* variables
act_load_repo_config() {
    local tool_name="$1"
    local config_file="$ACT_REPOS_DIR/${tool_name}.yaml"

    if [[ ! -f "$config_file" ]]; then
        _log_error "Repo config not found: $config_file"
        return 4
    fi

    # Check for yq
    if ! command -v yq &>/dev/null; then
        _log_error "yq required for config parsing. Install: brew install yq"
        return 3
    fi

    # Load config into variables
    ACT_REPO_NAME=$(yq -r '.tool_name // ""' "$config_file")
    ACT_REPO_GITHUB=$(yq -r '.repo // ""' "$config_file")
    ACT_REPO_LOCAL_PATH=$(yq -r '.local_path // ""' "$config_file")
    ACT_REPO_LANGUAGE=$(yq -r '.language // ""' "$config_file")
    ACT_REPO_WORKFLOW=$(yq -r '.workflow // ".github/workflows/release.yml"' "$config_file")

    export ACT_REPO_NAME ACT_REPO_GITHUB ACT_REPO_LOCAL_PATH ACT_REPO_LANGUAGE ACT_REPO_WORKFLOW

    _log_info "Loaded config for $tool_name: $ACT_REPO_GITHUB"
    return 0
}

# Get act job for a target platform
# Usage: act_get_job_for_target <tool_name> <platform>
# Returns: Job name or empty if native build required
act_get_job_for_target() {
    local tool_name="$1"
    local platform="$2"
    local config_file="$ACT_REPOS_DIR/${tool_name}.yaml"

    if [[ ! -f "$config_file" ]]; then
        _log_error "Repo config not found: $config_file"
        return 4
    fi

    # Use yq to extract the job mapping
    # Format in YAML: act_job_map.linux/amd64: build-linux
    local job
    job=$(yq -r '.act_job_map."'"$platform"'" // ""' "$config_file" 2>/dev/null)

    # Handle null values (native build required)
    if [[ "$job" == "null" || -z "$job" ]]; then
        echo ""
        return 1  # Native build required
    fi

    echo "$job"
    return 0
}

# Check if a platform can be built via act
# Usage: act_platform_uses_act <tool_name> <platform>
# Returns: 0 if act, 1 if native
act_platform_uses_act() {
    local tool_name="$1"
    local platform="$2"

    local job
    job=$(act_get_job_for_target "$tool_name" "$platform")

    if [[ -n "$job" ]]; then
        return 0  # Uses act
    else
        return 1  # Native build
    fi
}

# Get act flags for a tool/platform combination
# Usage: act_get_flags <tool_name> <platform>
# Returns: Array of act flags as space-separated string
act_get_flags() {
    local tool_name="$1"
    local platform="$2"
    local config_file="$ACT_REPOS_DIR/${tool_name}.yaml"

    if [[ ! -f "$config_file" ]]; then
        echo ""
        return 4
    fi

    local flags=()

    # Get platform-specific image override
    local image
    image=$(yq -r '.act_overrides.platform_image // ""' "$config_file" 2>/dev/null)
    if [[ -n "$image" ]]; then
        flags+=("-P ubuntu-latest=$image")
    fi

    # Get secrets file if specified
    local secrets_file
    secrets_file=$(yq -r '.act_overrides.secrets_file // ""' "$config_file" 2>/dev/null)
    if [[ -n "$secrets_file" ]]; then
        flags+=("--secret-file $secrets_file")
    fi

    # Get env file if specified
    local env_file
    env_file=$(yq -r '.act_overrides.env_file // ""' "$config_file" 2>/dev/null)
    if [[ -n "$env_file" ]]; then
        flags+=("--env-file $env_file")
    fi

    # Platform-specific flags
    if [[ "$platform" == "linux/arm64" ]]; then
        # Check for ARM64 specific overrides
        local arm64_flags
        arm64_flags=$(yq -r '.act_overrides.linux_arm64_flags[]? // ""' "$config_file" 2>/dev/null)
        if [[ -n "$arm64_flags" ]]; then
            while IFS= read -r flag; do
                flags+=("$flag")
            done <<< "$arm64_flags"
        fi
    fi

    # Matrix filtering for targeted builds (optional)
    # Example:
    # act_matrix:
    #   "linux/amd64":
    #     os: ubuntu-latest
    #     target: linux/amd64
    local matrix_entries
    matrix_entries=$(yq -r '
        .act_matrix."'"$platform"'" // {} |
        to_entries |
        .[] |
        select(.value != null and .value != "") |
        .key + ":" + (.value | tostring)
    ' "$config_file" 2>/dev/null)
    if [[ -n "$matrix_entries" ]]; then
        while IFS= read -r entry; do
            [[ -n "$entry" ]] && flags+=("--matrix $entry")
        done <<< "$matrix_entries"
    fi

    echo "${flags[*]}"
}

# Get all targets for a tool
# Usage: act_get_targets <tool_name>
# Returns: Space-separated list of platforms
act_get_targets() {
    local tool_name="$1"
    local config_file="$ACT_REPOS_DIR/${tool_name}.yaml"

    if [[ ! -f "$config_file" ]]; then
        echo ""
        return 4
    fi

    yq -r '.targets[]' "$config_file" 2>/dev/null | tr '\n' ' '
}

# Get native host for a platform
# Usage: act_get_native_host <platform> [tool_name]
# Returns: Host name (trj, mmini, wlap) or empty
act_get_native_host() {
    local platform="$1"
    local tool_name="${2:-}"

    if [[ -n "$tool_name" ]]; then
        local config_file="$ACT_REPOS_DIR/${tool_name}.yaml"
        if [[ -f "$config_file" ]]; then
            local override_host
            override_host=$(yq -r ".cross_compile.\"$platform\".host // \"\"" "$config_file" 2>/dev/null || true)
            if [[ -n "$override_host" && "$override_host" != "null" ]]; then
                printf '%s\n' "$override_host"
                return 0
            fi
        fi
    fi

    if declare -F config_get_host_for_platform &>/dev/null; then
        local configured_host
        configured_host=$(config_get_host_for_platform "$platform" 2>/dev/null | tr -d '"' || true)
        if [[ -n "$configured_host" && "$configured_host" != "null" ]]; then
            printf '%s\n' "$configured_host"
            return 0
        fi
    fi

    case "$platform" in
        linux/amd64|linux/arm64)
            echo "trj"
            ;;
        darwin/arm64|darwin/amd64)
            echo "mmini"
            ;;
        windows/amd64|windows/arm64)
            echo "wlap"
            ;;
        *)
            echo ""
            return 1
            ;;
    esac
}

# Get build strategy for a tool/platform
# Usage: act_get_build_strategy <tool_name> <platform>
# Returns: JSON with method, host, job info
act_get_build_strategy() {
    local tool_name="$1"
    local platform="$2"

    local job host method

    if act_platform_uses_act "$tool_name" "$platform"; then
        job=$(act_get_job_for_target "$tool_name" "$platform")
        host="trj"
        method="act"
    else
        job=""
        host=$(act_get_native_host "$platform" "$tool_name")
        method="native"
    fi

    jq -nc \
        --arg tool "$tool_name" \
        --arg platform "$platform" \
        --arg method "$method" \
        --arg host "$host" \
        --arg job "$job" \
        '{
            tool: $tool,
            platform: $platform,
            method: $method,
            host: $host,
            job: $job
        }'
}

# List all configured tools
# Usage: act_list_tools
# Returns: List of tool names
act_list_tools() {
    if [[ ! -d "$ACT_REPOS_DIR" ]]; then
        _log_warn "Repos directory not found: $ACT_REPOS_DIR"
        return 1
    fi

    # Use nullglob to handle empty directory gracefully
    # Save state without eval - shopt -q returns 0 if set, 1 if unset
    local had_nullglob=false
    shopt -q nullglob && had_nullglob=true
    shopt -s nullglob

    for config in "$ACT_REPOS_DIR"/*.yaml; do
        # Skip template files (start with _)
        if [[ ! "$(basename "$config")" =~ ^_ ]]; then
            basename "$config" .yaml
        fi
    done

    # Restore previous nullglob setting without eval
    if $had_nullglob; then
        shopt -s nullglob
    else
        shopt -u nullglob
    fi
}

# Generate full build matrix for a tool
# Usage: act_build_matrix <tool_name>
# Returns: JSON array of build strategies
act_build_matrix() {
    local tool_name="$1"
    local targets strategies=()

    targets=$(act_get_targets "$tool_name")

    for target in $targets; do
        local strategy
        strategy=$(act_get_build_strategy "$tool_name" "$target")
        strategies+=("$strategy")
    done

    if [[ ${#strategies[@]} -eq 0 ]]; then
        echo "[]"
    else
        printf '%s\n' "${strategies[@]}" | jq -s '.'
    fi
}

# ============================================================================
# Hybrid Build Orchestration (act + SSH)
# ============================================================================

# SSH settings for native builds
_ACT_SSH_TIMEOUT="${DSR_SSH_TIMEOUT:-30}"
_ACT_BUILD_TIMEOUT="${DSR_BUILD_TIMEOUT:-3600}"
_ACT_SYNC_TIMEOUT="${DSR_SYNC_TIMEOUT:-300}"  # 5 minutes for sync

# ============================================================================
# Source Code Sync for Remote Native Builds
# ============================================================================

# Default exclude patterns for rsync
_ACT_SYNC_DEFAULT_EXCLUDES=(
    '.git'
    'target'
    'node_modules'
    '.beads'
    '*.log'
    '.DS_Store'
    '__pycache__'
    '*.pyc'
    '.env'
    '.env.local'
)

# Check if rsync is available on remote host
# Usage: _act_has_rsync <host>
# Returns: 0 if rsync available, 1 otherwise
_act_get_host_field() {
    local host="${1:-}"
    local field="${2:-}"

    if [[ -z "$host" || -z "$field" || -z "${DSR_HOSTS_FILE:-}" || ! -f "$DSR_HOSTS_FILE" ]]; then
        return 1
    fi

    local value
    value=$(yq -r ".hosts.$host.$field // \"\"" "$DSR_HOSTS_FILE" 2>/dev/null || true)
    if [[ -z "$value" || "$value" == "null" ]]; then
        return 1
    fi

    printf '%s\n' "$value"
}

_act_get_host_platform() {
    local host="${1:-}"
    local platform
    platform=$(_act_get_host_field "$host" "platform" || true)
    if [[ -n "$platform" ]]; then
        printf '%s\n' "$platform"
        return 0
    fi

    case "$host" in
        trj) echo "linux/amd64" ;;
        mmini) echo "darwin/arm64" ;;
        wlap) echo "windows/amd64" ;;
        *) echo "" ;;
    esac
}

_act_get_host_connection() {
    local host="${1:-}"
    local connection
    connection=$(_act_get_host_field "$host" "connection" || true)
    if [[ -n "$connection" ]]; then
        printf '%s\n' "$connection"
        return 0
    fi

    case "$host" in
        trj) echo "local" ;;
        *) echo "ssh" ;;
    esac
}

_act_get_ssh_destination() {
    local host="${1:-}"
    local destination

    [[ -n "$host" ]] || return 4
    destination=$(_act_get_host_field "$host" "ssh_host" || true)
    [[ -n "$destination" ]] || destination="$host"
    if [[ ! "$destination" =~ ^[A-Za-z0-9_.:@%+-]+$ ]]; then
        _log_error "Unsafe SSH destination configured for logical host $host"
        return 4
    fi
    printf '%s\n' "$destination"
}

_act_is_local_host() {
    local host="${1:-}"
    [[ "$host" == "act" || "$(_act_get_host_connection "$host")" == "local" ]]
}

_act_is_windows_host() {
    local host="${1:-}"
    [[ "$(_act_get_host_platform "$host")" == windows/* ]]
}

_act_windows_cmd_path() {
    local path="${1:-}"
    path="${path//\//\\}"
    printf '%s\n' "$path"
}

_act_windows_rsync_path() {
    local path="${1:-}"
    path="${path//\\//}"

    if [[ "$path" =~ ^([A-Za-z]):/(.*)$ ]]; then
        local drive="${BASH_REMATCH[1],,}"
        local rest="${BASH_REMATCH[2]}"
        printf '/cygdrive/%s/%s\n' "$drive" "$rest"
        return 0
    fi

    if [[ "$path" =~ ^([A-Za-z]):$ ]]; then
        local drive="${BASH_REMATCH[1],,}"
        printf '/cygdrive/%s\n' "$drive"
        return 0
    fi

    printf '%s\n' "$path"
}

_act_has_rsync() {
    local host="$1"
    local ssh_destination=""
    local probe_cmd='command -v rsync >/dev/null 2>&1'
    if _act_is_windows_host "$host"; then
        probe_cmd='where rsync >NUL 2>&1'
    fi

    if _act_is_local_host "$host"; then
        _act_run_with_timeout 10 bash -lc "$probe_cmd" 2>/dev/null
    else
        ssh_destination=$(_act_get_ssh_destination "$host") || return 4
        _act_run_with_timeout 10 ssh -o ConnectTimeout="$_ACT_SSH_TIMEOUT" \
            -o BatchMode=yes \
            -o StrictHostKeyChecking=accept-new \
            "$ssh_destination" "$probe_cmd" 2>/dev/null
    fi
}

# Sync source code to remote host via rsync
# Usage: _act_sync_source <host> <local_path> <remote_path> [extra_excludes...]
# Returns: 0 on success, non-zero on failure
_act_sync_source() {
    local host="$1"
    local local_path="$2"
    local remote_path="$3"
    shift 3
    local respect_gitignore_excludes=true
    local extra_excludes=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-gitignore-excludes)
                respect_gitignore_excludes=false
                ;;
            *)
                extra_excludes+=("$1")
                ;;
        esac
        shift
    done

    if [[ ! -d "$local_path" ]]; then
        _log_error "Local path not found: $local_path"
        return 4
    fi

    # Build exclude args
    local exclude_args=()
    for pattern in "${_ACT_SYNC_DEFAULT_EXCLUDES[@]}"; do
        exclude_args+=("--exclude=$pattern")
    done
    for pattern in "${extra_excludes[@]}"; do
        exclude_args+=("--exclude=$pattern")
    done

    # Respect .gitignore by default for faster remote sync, but allow callers
    # to disable that behavior when ignored files are still required inputs.
    if $respect_gitignore_excludes && [[ -f "$local_path/.gitignore" ]]; then
        exclude_args+=("--exclude-from=$local_path/.gitignore")
    fi

    _log_info "Syncing source to $host:$remote_path"

    local start_time
    start_time=$(date +%s)

    if _act_is_local_host "$host"; then
        if [[ "$remote_path" == "$local_path" ]]; then
            _log_info "Local build host already uses source tree at $local_path; skipping sync"
            return 0
        fi

        mkdir -p "$remote_path"
        if _act_run_with_timeout "$_ACT_SYNC_TIMEOUT" rsync -az --delete \
            "${exclude_args[@]}" \
            "$local_path/" "$remote_path/" 2>&1; then
            local duration=$(($(date +%s) - start_time))
            _log_ok "Sync completed in ${duration}s (local rsync)"
            return 0
        fi

        _log_error "local rsync failed"
        return 1
    fi

    local ssh_destination
    ssh_destination=$(_act_get_ssh_destination "$host") || return 4

    # Check for rsync on remote
    if _act_has_rsync "$host"; then
        local rsync_remote_path="$remote_path"
        if _act_is_windows_host "$host"; then
            rsync_remote_path=$(_act_windows_rsync_path "$remote_path")
        fi

        # Use rsync for efficient sync
        if _act_run_with_timeout "$_ACT_SYNC_TIMEOUT" rsync -az --delete \
            "${exclude_args[@]}" \
            -e "ssh -o ConnectTimeout=$_ACT_SSH_TIMEOUT -o StrictHostKeyChecking=accept-new" \
            "$local_path/" "$ssh_destination:$rsync_remote_path/" 2>&1; then
            local duration=$(($(date +%s) - start_time))
            _log_ok "Sync completed in ${duration}s (rsync)"
            return 0
        else
            _log_error "rsync failed"
            return 1
        fi
    else
        # Fallback: tar + ssh + untar (works everywhere)
        _log_warn "rsync not available on $host, using tar fallback"

        # Build tar exclude args
        local tar_excludes=()
        for pattern in "${_ACT_SYNC_DEFAULT_EXCLUDES[@]}"; do
            tar_excludes+=("--exclude=$pattern")
        done
        for pattern in "${extra_excludes[@]}"; do
            tar_excludes+=("--exclude=$pattern")
        done

        # Create remote directory and extract
        # Windows (wlap) needs different mkdir syntax - use cmd /c with backslashes
        local mkdir_cmd
        if _act_is_windows_host "$host"; then
            # Windows: convert forward slashes to backslashes, use cmd /c
            local win_path
            win_path=$(_act_windows_cmd_path "$remote_path")
            mkdir_cmd="cmd /c \"if not exist \\\"$win_path\\\" mkdir \\\"$win_path\\\"\" && cd /d \"$win_path\""
        else
            mkdir_cmd="mkdir -p \"$remote_path\" && cd \"$remote_path\""
        fi

        local remote_extract_cmd="$mkdir_cmd && tar xzf -"
        local escaped_remote_extract_cmd
        printf -v escaped_remote_extract_cmd '%q' "$remote_extract_cmd"

        if _act_run_with_timeout "$_ACT_SYNC_TIMEOUT" bash -c "
            cd '$local_path' && \
            tar czf - ${tar_excludes[*]} . | \
            ssh -o ConnectTimeout=$_ACT_SSH_TIMEOUT \
                -o StrictHostKeyChecking=accept-new \
                '$ssh_destination' $escaped_remote_extract_cmd
        " 2>&1; then
            local duration=$(($(date +%s) - start_time))
            _log_ok "Sync completed in ${duration}s (tar)"
            return 0
        else
            _log_error "tar fallback sync failed"
            return 1
        fi
    fi
}

_act_strict_source_root_path() {
    local configured_path="$1"
    local tool_name="$2"
    local run_id="$3"
    local strict_root

    if [[ ! "$configured_path" =~ ^[A-Za-z0-9_./:+-]+$ || "$configured_path" == *..* ]] || \
       ! _act_is_safe_basename "$tool_name" || ! _act_is_uuid "$run_id"; then
        return 4
    fi
    if [[ -n "${DSR_STRICT_BUILD_ROOT:-}" ]]; then
        strict_root="${DSR_STRICT_BUILD_ROOT%/}"
        if [[ ! "$strict_root" =~ ^([A-Za-z]:)?/[A-Za-z0-9_./:+-]+$ || \
              "$strict_root" == *..* || \
              ( -n "${HOME:-}" && "$strict_root" == "$HOME"/* ) ]]; then
            return 4
        fi
    elif [[ "$configured_path" =~ ^[A-Za-z]:/ ]]; then
        strict_root="${configured_path:0:2}/Users/Public/.dsr-release-snapshots"
    elif [[ "$configured_path" == /* ]]; then
        strict_root="/tmp/.dsr-release-snapshots"
    else
        return 4
    fi
    printf '%s/%s-%s/source\n' "$strict_root" "$tool_name" "$run_id"
}

_act_git_archive_sha256() {
    local repo_path="$1"
    local revision="$2"

    if command -v sha256sum &>/dev/null; then
        git -C "$repo_path" archive --format=tar "$revision" 2>/dev/null | sha256sum | awk '{print $1}'
    elif command -v shasum &>/dev/null; then
        git -C "$repo_path" archive --format=tar "$revision" 2>/dev/null | shasum -a 256 | awk '{print $1}'
    else
        return 3
    fi
}

_act_write_git_archive_evidence() {
    local repo_path="$1"
    local revision="$2"
    local output_file="$3"

    (
        local descriptor_inode path_inode
        set -C
        umask 077
        exec 9> "$output_file" || exit 4
        descriptor_inode=$(_act_file_identity /dev/fd/9) || exit 4
        git -C "$repo_path" archive --format=tar "$revision" >&9 2>/dev/null || exit 4
        chmod 600 /dev/fd/9 || exit 4
        path_inode=$(_act_file_identity "$output_file") || exit 4
        [[ -s /dev/fd/9 && -f "$output_file" && ! -L "$output_file" && \
           "$descriptor_inode" == "$path_inode" ]] || exit 4
        exec 9>&-
    )
}

_act_write_tracked_manifest() {
    local repo_path="$1"
    local revision="$2"
    local output_file="$3"
    (
        local metadata path mode object_type object_id descriptor_inode path_inode
        set -C
        umask 077
        exec 9> "$output_file" || exit 4
        descriptor_inode=$(_act_file_identity /dev/fd/9) || exit 4
        while IFS=$'\t' read -r metadata path; do
            [[ -n "$metadata" && -n "$path" ]] || continue
            read -r mode object_type object_id <<< "$metadata"
            if [[ "$object_type" != "blob" || \
                  ( "$mode" != "100644" && "$mode" != "100755" ) || \
                  ! "$object_id" =~ ^[0-9a-f]{40}$ || \
                  ! "$path" =~ ^[A-Za-z0-9_./+@-]+$ || "$path" == *..* || \
                  ! -f "$repo_path/$path" || -L "$repo_path/$path" ]]; then
                _log_error "Strict release tracked path cannot be represented safely: $path"
                exit 4
            fi
            printf '%s\t%s\t%s\n' "$object_id" "$mode" "$path" >&9 || exit 4
        done < <(git -C "$repo_path" ls-tree -r --full-tree "$revision" 2>/dev/null)
        chmod 600 /dev/fd/9 || exit 4
        path_inode=$(_act_file_identity "$output_file") || exit 4
        [[ -s /dev/fd/9 && -f "$output_file" && ! -L "$output_file" && \
           "$descriptor_inode" == "$path_inode" ]] || exit 4
        exec 9>&-
    )
}

_act_tracked_manifest_object_count() {
    local manifest_file="$1"
    local object_id mode relative_path parent
    local -A expected_objects=()

    [[ -f "$manifest_file" && ! -L "$manifest_file" ]] || return 4
    while IFS=$'\t' read -r object_id mode relative_path; do
        [[ "$object_id" =~ ^[0-9a-f]{40}$ && \
           ( "$mode" == "100644" || "$mode" == "100755" ) && \
           "$relative_path" =~ ^[A-Za-z0-9_./+@-]+$ && \
           "$relative_path" != *..* && "$relative_path" != /* ]] || return 4
        expected_objects["f:$relative_path"]=1
        parent="$relative_path"
        while [[ "$parent" == */* ]]; do
            parent="${parent%/*}"
            [[ -n "$parent" && "$parent" != "." ]] || return 4
            expected_objects["d:$parent"]=1
        done
    done < "$manifest_file"

    [[ ${#expected_objects[@]} -gt 0 ]] || return 4
    printf '%s\n' "${#expected_objects[@]}"
}

_act_verify_tracked_manifest_local() {
    local root_path="$1"
    local manifest_file="$2"
    local object_id mode relative_path actual_id parent expected_count actual_count

    if [[ ! -d "$root_path" || -L "$root_path" ]] || \
       ! expected_count=$(_act_tracked_manifest_object_count "$manifest_file"); then
        return 4
    fi

    while IFS=$'\t' read -r object_id mode relative_path; do
        [[ "$object_id" =~ ^[0-9a-f]{40}$ && \
           ( "$mode" == "100644" || "$mode" == "100755" ) && \
           "$relative_path" =~ ^[A-Za-z0-9_./+@-]+$ && \
           "$relative_path" != *..* && "$relative_path" != /* ]] || return 4
        if [[ ! -f "$root_path/$relative_path" || -L "$root_path/$relative_path" ]] || \
           ! actual_id=$(git hash-object -- "$root_path/$relative_path" 2>/dev/null) || \
           [[ "$actual_id" != "$object_id" ]] || \
           { [[ "$mode" == "100755" ]] && [[ ! -x "$root_path/$relative_path" ]]; } || \
           { [[ "$mode" == "100644" ]] && [[ -x "$root_path/$relative_path" ]]; }; then
            return 4
        fi
        parent="$relative_path"
        while [[ "$parent" == */* ]]; do
            parent="${parent%/*}"
            if [[ ! -d "$root_path/$parent" || -L "$root_path/$parent" ]]; then
                return 4
            fi
        done
    done < "$manifest_file"

    actual_count=$(find "$root_path" -mindepth 1 -print 2>/dev/null | wc -l | tr -d '[:space:]')
    [[ "$actual_count" =~ ^[0-9]+$ && "$actual_count" == "$expected_count" ]]
}

_act_validate_strict_checkout_at_revision() {
    local repo_path="$1"
    local revision="$2"
    local label="$3"
    local head resolved status

    if [[ ! -d "$repo_path" || ! "$revision" =~ ^[0-9a-f]{40}$ || "$revision" =~ ^0{40}$ ]]; then
        _log_error "Strict release checkout is missing or unpinned: $label"
        return 4
    fi
    if ! head=$(git -C "$repo_path" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || \
       ! resolved=$(git -C "$repo_path" rev-parse --verify "${revision}^{commit}" 2>/dev/null) || \
       [[ "$head" != "$revision" || "$resolved" != "$revision" ]]; then
        _log_error "Strict release checkout is not at its pinned revision: $label"
        return 4
    fi
    if ! status=$(git -C "$repo_path" status --porcelain --untracked-files=all 2>/dev/null) || \
       [[ -n "$status" ]]; then
        _log_error "Strict release checkout is dirty: $label"
        return 4
    fi
}

_act_validate_no_absolute_cargo_paths() {
    local repo_path="$1"
    local match_status=0
    local pattern="path[[:space:]]*=[[:space:]]*['\"](/|[A-Za-z]:[\\/])"

    if ! command -v rg &>/dev/null; then
        _log_error "ripgrep is required to validate strict Cargo path dependencies"
        return 3
    fi
    rg --glob 'Cargo.toml' --quiet "$pattern" "$repo_path" 2>/dev/null || match_status=$?
    if [[ $match_status -eq 0 ]]; then
        _log_error "Strict tag snapshot contains an absolute Cargo path dependency: $repo_path"
        return 4
    fi
    if [[ $match_status -ne 1 ]]; then
        _log_error "Unable to validate Cargo path dependencies: $repo_path"
        return 4
    fi
}

_act_normalize_cargo_path() {
    local raw_path="$1"

    jq -enr --arg raw "$raw_path" '
        def collapse_segments:
            reduce (split("/")[]) as $part ([];
                if $part == "" or $part == "." then .
                elif $part == ".." then
                    if length == 0 then error("path escapes root") else .[:-1] end
                else . + [$part]
                end
            );

        ($raw
            | select(type == "string" and length > 0)
            | gsub("\\\\"; "/")
            | sub("^//\\?/"; "")
            | select(test("^[A-Za-z0-9_./:+@-]+$"))) as $path
        | if ($path | test("^[A-Za-z]:/")) then
            ($path[0:2] | ascii_downcase) as $drive
            | ($path[3:] | collapse_segments) as $parts
            | select(($parts | length) > 0)
            | ($drive + "/" + ($parts | join("/")) | ascii_downcase)
          elif ($path | startswith("/")) then
            ($path[1:] | collapse_segments) as $parts
            | select(($parts | length) > 0)
            | "/" + ($parts | join("/"))
          else
            error("path is not absolute")
          end
    ' 2>/dev/null
}

_act_validate_cargo_metadata_source_closure() {
    local source_root="$1"
    local dependency_checkouts_json="$2"
    local metadata_json="$3"
    local canonical_source_root canonical_workspace_root snapshot_parent

    if ! canonical_source_root=$(_act_normalize_cargo_path "$source_root") || \
       ! jq -e '
            type == "array" and
            all(.[];
                (keys | sort) == ["git_sha", "local_path", "relative_path"] and
                (.relative_path | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._+-]*$") and (contains("..") | not)) and
                (.local_path | type == "string" and length > 1) and
                (.git_sha | type == "string" and test("^(?!0{40}$)[0-9a-f]{40}$"))
            )
        ' <<< "$dependency_checkouts_json" >/dev/null 2>&1 || \
       ! jq -e '
            type == "object" and
            (.workspace_root | type == "string" and length > 0) and
            (.packages | type == "array" and length > 0) and
            all(.packages[];
                (.manifest_path | type == "string" and length > 0) and
                ((.source == null) or (.source | type == "string"))
            )
        ' <<< "$metadata_json" >/dev/null 2>&1; then
        _log_error "Strict Cargo metadata or pinned source roots are invalid"
        return 4
    fi

    canonical_workspace_root=$(_act_normalize_cargo_path \
        "$(jq -r '.workspace_root' <<< "$metadata_json")") || return 4
    if [[ "$canonical_workspace_root" != "$canonical_source_root" ]]; then
        _log_error "Strict Cargo workspace root escaped the fresh source root"
        return 4
    fi

    snapshot_parent="${source_root%/*}"
    local pinned_roots=()
    local dependency relative_path pinned_root existing duplicate
    while IFS= read -r dependency; do
        [[ -n "$dependency" ]] || continue
        relative_path=$(jq -r '.relative_path' <<< "$dependency")
        if ! pinned_root=$(_act_normalize_cargo_path "$snapshot_parent/$relative_path"); then
            _log_error "Pinned Cargo source root is not canonicalizable: $relative_path"
            return 4
        fi
        duplicate=false
        for existing in "${pinned_roots[@]}"; do
            [[ "$existing" == "$pinned_root" ]] && duplicate=true
        done
        if $duplicate; then
            _log_error "Pinned Cargo source roots are not unique after canonicalization"
            return 4
        fi
        pinned_roots+=("$pinned_root")
    done < <(jq -c '.[]' <<< "$dependency_checkouts_json")

    local discovered_roots=()
    local encoded_manifest manifest_path canonical_manifest manifest_name package_root matched_root
    local main_package_count=0 already_discovered
    while IFS= read -r encoded_manifest; do
        [[ -n "$encoded_manifest" ]] || continue
        manifest_path=$(jq -r '.' <<< "$encoded_manifest") || return 4
        canonical_manifest=$(_act_normalize_cargo_path "$manifest_path") || return 4
        manifest_name="${canonical_manifest##*/}"
        if [[ "${manifest_name,,}" != "cargo.toml" ]]; then
            _log_error "Cargo reported a noncanonical local package manifest"
            return 4
        fi
        package_root="${canonical_manifest%/*}"

        if [[ "$package_root" == "$canonical_source_root" || \
              "$package_root" == "$canonical_source_root/"* ]]; then
            ((main_package_count++))
            continue
        fi

        matched_root=""
        for pinned_root in "${pinned_roots[@]}"; do
            if [[ "$package_root" == "$pinned_root" || "$package_root" == "$pinned_root/"* ]]; then
                if [[ -n "$matched_root" && "$matched_root" != "$pinned_root" ]]; then
                    _log_error "Cargo package path matches multiple pinned source roots"
                    return 4
                fi
                matched_root="$pinned_root"
            fi
        done
        if [[ -z "$matched_root" ]]; then
            _log_error "Cargo metadata discovered an unpinned local package root: $package_root"
            return 4
        fi

        already_discovered=false
        for existing in "${discovered_roots[@]}"; do
            [[ "$existing" == "$matched_root" ]] && already_discovered=true
        done
        $already_discovered || discovered_roots+=("$matched_root")
    done < <(jq -c '.packages[] | select(.source == null) | .manifest_path' <<< "$metadata_json")

    if [[ $main_package_count -eq 0 || ${#discovered_roots[@]} -ne ${#pinned_roots[@]} ]]; then
        _log_error "Cargo local package roots do not exactly match the pinned source manifest"
        return 4
    fi
    for pinned_root in "${pinned_roots[@]}"; do
        already_discovered=false
        for existing in "${discovered_roots[@]}"; do
            [[ "$existing" == "$pinned_root" ]] && already_discovered=true
        done
        if ! $already_discovered; then
            _log_error "Pinned source root is absent from the Cargo metadata closure: $pinned_root"
            return 4
        fi
    done
    return 0
}

_act_strict_cargo_metadata_json() {
    local host="$1"
    local source_root="$2"
    local metadata_command metadata_output metadata_json canonical_source_root
    local strict_cargo_home="${source_root%/*}/.cargo-home"

    if [[ ! "$source_root" =~ ^[A-Za-z0-9_./:+-]+$ || "$source_root" == *..* ]]; then
        _log_error "Unsafe strict Cargo source root"
        return 4
    fi
    if _act_is_windows_host "$host"; then
        local win_source_root win_cargo_home win_manifest_path
        win_source_root=$(_act_windows_cmd_path "$source_root")
        win_cargo_home=$(_act_windows_cmd_path "$strict_cargo_home")
        win_manifest_path="${win_source_root}\\Cargo.toml"
        metadata_command="powershell -NoProfile -NonInteractive -Command \"\$ErrorActionPreference='Stop'; \$strict='${win_cargo_home}'; \$ambient=if (\$env:CARGO_HOME) { \$env:CARGO_HOME } else { Join-Path \$env:USERPROFILE '.cargo' }; if (Test-Path -LiteralPath \$strict) { throw 'Strict CARGO_HOME already exists' }; New-Item -ItemType Directory -Path \$strict | Out-Null; \$strictItem=Get-Item -LiteralPath \$strict -Force; if (-not \$strictItem.PSIsContainer -or ((\$strictItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'Strict CARGO_HOME is not a plain directory' }; foreach (\$name in @('config','config.toml','credentials','credentials.toml')) { if (Test-Path -LiteralPath (Join-Path \$strict \$name)) { throw 'Strict CARGO_HOME contains ambient configuration' } }; foreach (\$name in @('registry','git')) { \$source=Join-Path \$ambient \$name; \$dest=Join-Path \$strict \$name; if (Test-Path -LiteralPath \$source -PathType Container) { New-Item -ItemType Junction -Path \$dest -Target \$source | Out-Null; \$destItem=Get-Item -LiteralPath \$dest -Force; if ((\$destItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { throw 'Strict Cargo cache is not an isolated junction' } } }; \$ancestor=(Get-Item -LiteralPath '${win_source_root}').Parent; while (\$null -ne \$ancestor) { \$cargoDir=Join-Path \$ancestor.FullName '.cargo'; foreach (\$name in @('config','config.toml')) { if (Test-Path -LiteralPath (Join-Path \$cargoDir \$name)) { throw 'Untracked ancestor Cargo config is forbidden' } }; \$ancestor=\$ancestor.Parent }; Get-ChildItem Env: | Where-Object { \$_.Name -match '^(CARGO_|RUST)' -or \$_.Name -match '^(CC|CXX|CPP|AR|RANLIB|LD|CFLAGS|CXXFLAGS|CPPFLAGS|LDFLAGS)$' } | ForEach-Object { Remove-Item -LiteralPath (\"Env:\" + \$_.Name) }; \$env:CARGO_HOME=\$strict; Set-Location -LiteralPath '${win_source_root}'; Write-Output ((Get-Location).Path); & cargo metadata --locked --offline --all-features --format-version 1 --manifest-path '${win_manifest_path}'; exit \$LASTEXITCODE\""
    else
        metadata_command="set -e; umask 077; strict_home='$strict_cargo_home'; ambient_home=\${CARGO_HOME:-\$HOME/.cargo}; test ! -e \"\$strict_home\"; test ! -L \"\$strict_home\"; mkdir \"\$strict_home\"; test -d \"\$strict_home\"; test ! -L \"\$strict_home\"; for name in config config.toml credentials credentials.toml; do test ! -e \"\$strict_home/\$name\"; test ! -L \"\$strict_home/\$name\"; done; for name in registry git; do if test -d \"\$ambient_home/\$name\"; then ln -s \"\$ambient_home/\$name\" \"\$strict_home/\$name\"; test -L \"\$strict_home/\$name\"; test \"\$(cd \"\$strict_home/\$name\" && pwd -P)\" = \"\$(cd \"\$ambient_home/\$name\" && pwd -P)\"; fi; done; ancestor='${source_root%/*}'; while test \"\$ancestor\" != / && test -n \"\$ancestor\"; do for name in config config.toml; do test ! -e \"\$ancestor/.cargo/\$name\"; test ! -L \"\$ancestor/.cargo/\$name\"; done; ancestor=\${ancestor%/*}; test -n \"\$ancestor\" || ancestor=/; done; for variable in \$(env | sed 's/=.*//'); do case \"\$variable\" in CARGO_*|RUST*|CC|CXX|CPP|AR|RANLIB|LD|CFLAGS|CXXFLAGS|CPPFLAGS|LDFLAGS) unset \"\$variable\";; esac; done; cd '$source_root'; printf '%s\\n' \"\$(pwd -P)\"; CARGO_HOME=\"\$strict_home\" cargo metadata --locked --offline --all-features --format-version 1 --manifest-path '$source_root/Cargo.toml'"
    fi

    if ! metadata_output=$(_act_ssh_exec "$host" "$metadata_command" "$_ACT_SYNC_TIMEOUT") || \
       [[ "$metadata_output" != *$'\n'* ]]; then
        _log_error "Locked offline Cargo metadata failed for strict source root on $host"
        return 4
    fi
    canonical_source_root="${metadata_output%%$'\n'*}"
    canonical_source_root="${canonical_source_root%$'\r'}"
    metadata_json="${metadata_output#*$'\n'}"
    if ! canonical_source_root=$(_act_normalize_cargo_path "$canonical_source_root") || \
       ! jq -e 'type == "object"' <<< "$metadata_json" >/dev/null 2>&1; then
        _log_error "Locked offline Cargo metadata failed for strict source root on $host"
        return 4
    fi
    jq -nc --arg source_root "$canonical_source_root" --argjson metadata "$metadata_json" \
        '{source_root: $source_root, metadata: $metadata}'
}

_act_validate_strict_cargo_source_closure() {
    local host="$1"
    local source_root="$2"
    local dependency_checkouts_json="$3"
    local metadata_snapshot_json metadata_source_root metadata_json

    metadata_snapshot_json=$(_act_strict_cargo_metadata_json "$host" "$source_root") || return $?
    metadata_source_root=$(jq -r '.source_root' <<< "$metadata_snapshot_json") || return 4
    metadata_json=$(jq -c '.metadata' <<< "$metadata_snapshot_json") || return 4
    _act_validate_cargo_metadata_source_closure \
        "$metadata_source_root" "$dependency_checkouts_json" "$metadata_json"
}

_act_windows_reparse_guard_script() {
    printf '%s' "function Assert-NoReparseChain { param([System.IO.FileSystemInfo]\$Item); for (\$node=\$Item; \$null -ne \$node; \$node=\$node.Parent) { if ((\$node.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'NTFS ReparsePoint is forbidden in a strict release snapshot' } } }; function Assert-PlainDirectory { param([string]\$Path); \$item=Get-Item -LiteralPath \$Path -Force -ErrorAction Stop; if (-not \$item.PSIsContainer) { throw 'Strict release directory is not a directory' }; Assert-NoReparseChain \$item }; function Assert-PlainFile { param([string]\$Path); \$item=Get-Item -LiteralPath \$Path -Force -ErrorAction Stop; if (\$item.PSIsContainer) { throw 'Strict release file is not a file' }; Assert-NoReparseChain \$item };"
}

_act_sync_strict_checkout() {
    local host="$1"
    local local_path="$2"
    local revision="$3"
    local remote_path="$4"
    local archive_name="$5"
    local label="$6"

    if ! _act_validate_strict_checkout_at_revision "$local_path" "$revision" "$label" || \
       ! _act_validate_no_absolute_cargo_paths "$local_path" || \
       [[ ! "$remote_path" =~ ^[A-Za-z0-9_./:+-]+$ || "$remote_path" == *..* ]] || \
       ! _act_is_safe_basename "$archive_name"; then
        return 4
    fi
    local ssh_destination="$host"
    if ! _act_is_local_host "$host"; then
        ssh_destination=$(_act_get_ssh_destination "$host") || return 4
    fi

    local evidence_root="$ACT_ARTIFACTS_DIR/strict-source-archives"
    local evidence_dir archive_path manifest_path local_digest local_manifest_digest expected_object_count
    if ! mkdir -p "$evidence_root" || [[ ! -d "$evidence_root" || -L "$evidence_root" ]] || \
       ! evidence_dir=$(mktemp -d "$evidence_root/archive.XXXXXXXX") || \
       ! chmod 700 "$evidence_dir"; then
        _log_error "Unable to create private strict source archive directory"
        return 4
    fi
    archive_path="$evidence_dir/$archive_name"
    manifest_path="$evidence_dir/${archive_name%.tar}.manifest"
    if ! _act_write_git_archive_evidence "$local_path" "$revision" "$archive_path" || \
       [[ ! -f "$archive_path" || -L "$archive_path" ]] || \
       ! local_digest=$(_act_sha256 "$archive_path") || \
       [[ ! "$local_digest" =~ ^[0-9a-f]{64}$ ]] || \
       ! _act_write_tracked_manifest "$local_path" "$revision" "$manifest_path" || \
       ! local_manifest_digest=$(_act_sha256 "$manifest_path") || \
       [[ ! "$local_manifest_digest" =~ ^[0-9a-f]{64}$ ]] || \
       ! expected_object_count=$(_act_tracked_manifest_object_count "$manifest_path"); then
        _log_error "Unable to create exact tracked-byte archive for $label"
        return 4
    fi
    if ! _act_validate_strict_checkout_at_revision "$local_path" "$revision" "$label"; then
        return 4
    fi

    local snapshot_parent="${remote_path%/*}"
    local snapshot_grandparent="${snapshot_parent%/*}"
    local creates_snapshot_parent=false
    [[ "$archive_name" == "source.tar" ]] && creates_snapshot_parent=true
    local remote_archive="$snapshot_parent/.$archive_name"
    local remote_manifest="$snapshot_parent/.${archive_name%.tar}.manifest"
    local remote_digest=""
    if _act_is_local_host "$host"; then
        if $creates_snapshot_parent; then
            if [[ -e "$snapshot_parent" || -L "$snapshot_parent" ]] || \
               ! mkdir -p "$snapshot_grandparent" || ! mkdir -m 700 "$snapshot_parent"; then
                _log_error "Strict release snapshot parent already exists for $label"
                return 4
            fi
        elif [[ ! -d "$snapshot_parent" || -L "$snapshot_parent" ]]; then
            _log_error "Strict release snapshot parent is unavailable for $label"
            return 4
        fi
        if [[ "$remote_path" == "$local_path" || -e "$remote_path" || -L "$remote_path" || \
              -e "$remote_archive" || -L "$remote_archive" || \
              -e "$remote_manifest" || -L "$remote_manifest" ]] || \
           ! mkdir -m 700 "$remote_path" || \
           ! (set -C; cat "$archive_path" > "$remote_archive") || \
           ! tar -xf "$remote_archive" -C "$remote_path" || \
           ! _act_verify_tracked_manifest_local "$remote_path" "$manifest_path" || \
           ! remote_digest=$(_act_sha256 "$remote_archive"); then
            _log_error "Strict fresh local source sync failed for $label"
            return 4
        fi
    elif _act_is_windows_host "$host"; then
        local win_remote_path win_snapshot_parent win_remote_archive ps_command reparse_guard
        win_remote_path=$(_act_windows_cmd_path "$remote_path")
        win_snapshot_parent=$(_act_windows_cmd_path "$snapshot_parent")
        win_remote_archive=$(_act_windows_cmd_path "$remote_archive")
        reparse_guard=$(_act_windows_reparse_guard_script)
        local win_snapshot_grandparent parent_setup
        win_snapshot_grandparent=$(_act_windows_cmd_path "$snapshot_grandparent")
        if $creates_snapshot_parent; then
            parent_setup="if (Test-Path -LiteralPath '${win_snapshot_parent}') { exit 16 }; New-Item -ItemType Directory -Force -Path '${win_snapshot_grandparent}' | Out-Null; Assert-PlainDirectory '${win_snapshot_grandparent}'; New-Item -ItemType Directory -Path '${win_snapshot_parent}' | Out-Null; Assert-PlainDirectory '${win_snapshot_parent}'"
        else
            parent_setup="Assert-PlainDirectory '${win_snapshot_parent}'"
        fi
        ps_command="powershell -NoProfile -NonInteractive -Command \"${reparse_guard} ${parent_setup}; if ((Test-Path -LiteralPath '${win_remote_path}') -or (Test-Path -LiteralPath '${win_remote_archive}')) { exit 17 }; New-Item -ItemType Directory -Path '${win_remote_path}' | Out-Null; Assert-PlainDirectory '${win_remote_path}'; \$inputStream=[Console]::OpenStandardInput(); \$archive=[IO.File]::Open('${win_remote_archive}',[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None); \$inputStream.CopyTo(\$archive); \$archive.Close(); Assert-PlainFile '${win_remote_archive}'; tar.exe -xf '${win_remote_archive}' -C '${win_remote_path}'; if (\$LASTEXITCODE -ne 0) { exit 18 }; \$items=@(Get-ChildItem -LiteralPath '${win_remote_path}' -Force -Recurse -ErrorAction Stop); if (\$items.Count -ne ${expected_object_count}) { exit 19 }; foreach (\$item in \$items) { Assert-NoReparseChain \$item }; (Get-FileHash -Algorithm SHA256 -LiteralPath '${win_remote_archive}').Hash.ToLowerInvariant()\""
        if ! remote_digest=$(_act_run_with_timeout "$_ACT_SYNC_TIMEOUT" ssh \
            -o ConnectTimeout="$_ACT_SSH_TIMEOUT" -o BatchMode=yes \
            -o StrictHostKeyChecking=accept-new "$ssh_destination" "$ps_command" < "$archive_path"); then
            _log_error "Strict fresh Windows source sync failed for $label"
            return 4
        fi
    else
        local remote_cmd parent_setup
        if $creates_snapshot_parent; then
            parent_setup="mkdir -p '$snapshot_grandparent'; test ! -e '$snapshot_parent'; test ! -L '$snapshot_parent'; mkdir '$snapshot_parent'"
        else
            parent_setup="test -d '$snapshot_parent'; test ! -L '$snapshot_parent'"
        fi
        remote_cmd="set -e; set -C; umask 077; $parent_setup; test ! -e '$remote_path'; test ! -L '$remote_path'; test ! -e '$remote_archive'; test ! -L '$remote_archive'; mkdir '$remote_path'; cat > '$remote_archive'; tar -xf '$remote_archive' -C '$remote_path'; if command -v sha256sum >/dev/null 2>&1; then sha256sum '$remote_archive' | awk '{print \$1}'; else shasum -a 256 '$remote_archive' | awk '{print \$1}'; fi"
        if ! remote_digest=$(_act_run_with_timeout "$_ACT_SYNC_TIMEOUT" ssh \
            -o ConnectTimeout="$_ACT_SSH_TIMEOUT" -o BatchMode=yes \
            -o StrictHostKeyChecking=accept-new "$ssh_destination" "$remote_cmd" < "$archive_path"); then
            _log_error "Strict fresh remote source sync failed for $label"
            return 4
        fi
    fi

    remote_digest=$(printf '%s\n' "$remote_digest" | tr -d '\r' | tail -1 | tr '[:upper:]' '[:lower:]')
    if [[ "$remote_digest" != "$local_digest" ]]; then
        _log_error "Transferred strict source digest mismatch for $label"
        return 4
    fi

    local remote_manifest_digest=""
    if _act_is_local_host "$host"; then
        if ! (set -C; cat "$manifest_path" > "$remote_manifest") || \
           ! remote_manifest_digest=$(_act_sha256 "$remote_manifest"); then
            _log_error "Strict tracked-file manifest transfer failed for $label"
            return 4
        fi
    elif _act_is_windows_host "$host"; then
        local win_remote_manifest manifest_ps_command reparse_guard
        win_remote_manifest=$(_act_windows_cmd_path "$remote_manifest")
        reparse_guard=$(_act_windows_reparse_guard_script)
        manifest_ps_command="powershell -NoProfile -NonInteractive -Command \"${reparse_guard} Assert-PlainDirectory '${win_snapshot_parent}'; Assert-PlainDirectory '${win_remote_path}'; Assert-PlainFile '${win_remote_archive}'; if (Test-Path -LiteralPath '${win_remote_manifest}') { exit 20 }; \$inputStream=[Console]::OpenStandardInput(); \$manifest=[IO.File]::Open('${win_remote_manifest}',[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None); \$inputStream.CopyTo(\$manifest); \$manifest.Close(); Assert-PlainFile '${win_remote_manifest}'; (Get-FileHash -Algorithm SHA256 -LiteralPath '${win_remote_manifest}').Hash.ToLowerInvariant()\""
        remote_manifest_digest=$(_act_run_with_timeout "$_ACT_SYNC_TIMEOUT" ssh \
            -o ConnectTimeout="$_ACT_SSH_TIMEOUT" -o BatchMode=yes \
            -o StrictHostKeyChecking=accept-new "$ssh_destination" "$manifest_ps_command" < "$manifest_path") || return 4
    else
        local manifest_remote_cmd
        manifest_remote_cmd="set -e; set -C; umask 077; test ! -e '$remote_manifest'; test ! -L '$remote_manifest'; cat > '$remote_manifest'; if command -v sha256sum >/dev/null 2>&1; then sha256sum '$remote_manifest' | awk '{print \$1}'; else shasum -a 256 '$remote_manifest' | awk '{print \$1}'; fi"
        remote_manifest_digest=$(_act_run_with_timeout "$_ACT_SYNC_TIMEOUT" ssh \
            -o ConnectTimeout="$_ACT_SSH_TIMEOUT" -o BatchMode=yes \
            -o StrictHostKeyChecking=accept-new "$ssh_destination" "$manifest_remote_cmd" < "$manifest_path") || return 4
    fi
    remote_manifest_digest=$(printf '%s\n' "$remote_manifest_digest" | tr -d '\r' | tail -1 | tr '[:upper:]' '[:lower:]')
    if [[ "$remote_manifest_digest" != "$local_manifest_digest" ]]; then
        _log_error "Transferred tracked-file manifest digest mismatch for $label"
        return 4
    fi
}

_act_verify_strict_checkout_snapshot() {
    local host="$1"
    local local_path="$2"
    local revision="$3"
    local remote_path="$4"
    local archive_name="$5"
    local label="$6"
    local expected_digest expected_manifest_digest actual_digest actual_manifest_digest expected_object_count
    local snapshot_parent remote_archive remote_manifest evidence_root evidence_dir expected_manifest

    if ! _act_validate_strict_checkout_at_revision "$local_path" "$revision" "$label" || \
       ! expected_digest=$(_act_git_archive_sha256 "$local_path" "$revision") || \
       [[ ! "$expected_digest" =~ ^[0-9a-f]{64}$ ]]; then
        return 4
    fi
    local ssh_destination="$host"
    if ! _act_is_local_host "$host"; then
        ssh_destination=$(_act_get_ssh_destination "$host") || return 4
    fi
    evidence_root="$ACT_ARTIFACTS_DIR/strict-source-verification"
    if ! mkdir -p "$evidence_root" || [[ ! -d "$evidence_root" || -L "$evidence_root" ]] || \
       ! evidence_dir=$(mktemp -d "$evidence_root/verify.XXXXXXXX") || ! chmod 700 "$evidence_dir"; then
        return 4
    fi
    expected_manifest="$evidence_dir/${archive_name%.tar}.manifest"
    if ! _act_write_tracked_manifest "$local_path" "$revision" "$expected_manifest" || \
       ! expected_manifest_digest=$(_act_sha256 "$expected_manifest") || \
       [[ ! "$expected_manifest_digest" =~ ^[0-9a-f]{64}$ ]] || \
       ! expected_object_count=$(_act_tracked_manifest_object_count "$expected_manifest"); then
        return 4
    fi
    snapshot_parent="${remote_path%/*}"
    remote_archive="$snapshot_parent/.$archive_name"
    remote_manifest="$snapshot_parent/.${archive_name%.tar}.manifest"

    if _act_is_local_host "$host"; then
        if [[ ! -d "$remote_path" || -L "$remote_path" || \
              ! -f "$remote_archive" || -L "$remote_archive" || \
              ! -f "$remote_manifest" || -L "$remote_manifest" ]] || \
           ! actual_digest=$(_act_sha256 "$remote_archive") || \
           ! actual_manifest_digest=$(_act_sha256 "$remote_manifest") || \
           [[ "$actual_manifest_digest" != "$expected_manifest_digest" ]] || \
           ! _act_verify_tracked_manifest_local "$remote_path" "$remote_manifest"; then
            _log_error "Strict source snapshot changed after build: $label"
            return 4
        fi
    elif _act_is_windows_host "$host"; then
        local win_remote_path win_snapshot_parent win_remote_archive win_remote_manifest ps_command verify_output reparse_guard
        win_remote_path=$(_act_windows_cmd_path "$remote_path")
        win_snapshot_parent=$(_act_windows_cmd_path "$snapshot_parent")
        win_remote_archive=$(_act_windows_cmd_path "$remote_archive")
        win_remote_manifest=$(_act_windows_cmd_path "$remote_manifest")
        reparse_guard=$(_act_windows_reparse_guard_script)
        ps_command="powershell -NoProfile -NonInteractive -Command \"${reparse_guard} Assert-PlainDirectory '${win_snapshot_parent}'; Assert-PlainDirectory '${win_remote_path}'; Assert-PlainFile '${win_remote_archive}'; Assert-PlainFile '${win_remote_manifest}'; \$manifestHash=(Get-FileHash -Algorithm SHA256 -LiteralPath '${win_remote_manifest}').Hash.ToLowerInvariant(); if (\$manifestHash -ne '${expected_manifest_digest}') { exit 19 }; \$items=@(Get-ChildItem -LiteralPath '${win_remote_path}' -Force -Recurse -ErrorAction Stop); if (\$items.Count -ne ${expected_object_count}) { exit 20 }; foreach (\$item in \$items) { Assert-NoReparseChain \$item }; \$ok=\$true; Get-Content -LiteralPath '${win_remote_manifest}' | ForEach-Object { \$parts=\$_.Split([char]9,3); if ((\$parts.Count -ne 3) -or (\$parts[0] -notmatch '^[0-9a-f]{40}$') -or ((\$parts[1] -ne '100644') -and (\$parts[1] -ne '100755')) -or (\$parts[2] -notmatch '^[A-Za-z0-9_./+@-]+$') -or \$parts[2].Contains('..') -or \$parts[2].StartsWith('/')) { \$ok=\$false } else { \$file=Join-Path '${win_remote_path}' \$parts[2]; try { Assert-PlainFile \$file; \$actual=(git hash-object -- \$file).Trim(); if (\$actual -ne \$parts[0]) { \$ok=\$false } } catch { \$ok=\$false } } }; if (-not \$ok) { exit 21 }; \$archiveHash=(Get-FileHash -Algorithm SHA256 -LiteralPath '${win_remote_archive}').Hash.ToLowerInvariant(); Write-Output (\$archiveHash + ' ' + \$manifestHash)\""
        verify_output=$(_act_run_with_timeout "$_ACT_SYNC_TIMEOUT" ssh \
            -o ConnectTimeout="$_ACT_SSH_TIMEOUT" -o BatchMode=yes \
            -o StrictHostKeyChecking=accept-new "$ssh_destination" "$ps_command") || return 4
        read -r actual_digest actual_manifest_digest <<< "$(printf '%s\n' "$verify_output" | tr -d '\r' | tail -1)"
    else
        local remote_cmd verify_output
        remote_cmd="set -e; test -d '$remote_path'; test ! -L '$remote_path'; test -f '$remote_archive'; test ! -L '$remote_archive'; test -f '$remote_manifest'; test ! -L '$remote_manifest'; if command -v sha256sum >/dev/null 2>&1; then archive_digest=\$(sha256sum '$remote_archive' | awk '{print \$1}'); manifest_digest=\$(sha256sum '$remote_manifest' | awk '{print \$1}'); else archive_digest=\$(shasum -a 256 '$remote_archive' | awk '{print \$1}'); manifest_digest=\$(shasum -a 256 '$remote_manifest' | awk '{print \$1}'); fi; test \"\$manifest_digest\" = '$expected_manifest_digest'; tab=\$(printf '\\t'); while IFS=\"\$tab\" read -r object_id mode relative_path; do test -n \"\$relative_path\"; case \"\$object_id:\$mode:\$relative_path\" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]:100644:*|[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]:100755:*) :;; *) exit 21;; esac; case \"\$relative_path\" in /*|*..*|*[!A-Za-z0-9_./+@-]*) exit 21;; esac; file='$remote_path'/\$relative_path; test -f \"\$file\"; test ! -L \"\$file\"; parent=\$relative_path; while test \"\${parent#*/}\" != \"\$parent\"; do parent=\${parent%/*}; test -d '$remote_path'/\$parent; test ! -L '$remote_path'/\$parent; done; actual=\$(git hash-object -- \"\$file\"); test \"\$actual\" = \"\$object_id\"; if test \"\$mode\" = 100755; then test -x \"\$file\"; else test ! -x \"\$file\"; fi; done < '$remote_manifest'; actual_count=\$(find '$remote_path' -mindepth 1 -print | wc -l | tr -d '[:space:]'); test \"\$actual_count\" = '$expected_object_count'; printf '%s %s\\n' \"\$archive_digest\" \"\$manifest_digest\""
        verify_output=$(_act_run_with_timeout "$_ACT_SYNC_TIMEOUT" ssh \
            -o ConnectTimeout="$_ACT_SSH_TIMEOUT" -o BatchMode=yes \
            -o StrictHostKeyChecking=accept-new "$ssh_destination" "$remote_cmd") || return 4
        read -r actual_digest actual_manifest_digest <<< "$(printf '%s\n' "$verify_output" | tr -d '\r' | tail -1)"
    fi

    actual_digest=$(printf '%s' "$actual_digest" | tr '[:upper:]' '[:lower:]')
    actual_manifest_digest=$(printf '%s' "$actual_manifest_digest" | tr '[:upper:]' '[:lower:]')
    if [[ "$actual_digest" != "$expected_digest" || \
          "$actual_manifest_digest" != "$expected_manifest_digest" ]]; then
        _log_error "Strict source snapshot identity changed after transfer: $label"
        return 4
    fi
}

_act_verify_strict_source_roots() {
    local tool_name="$1"
    local source_revision="$2"
    local source_roots_json="$3"
    local dependency_checkouts host source_root dependency relative_path dependency_local dependency_sha

    if ! jq -e 'type == "object" and all(to_entries[]; (.key | type == "string" and length > 0) and (.value | type == "string" and length > 0))' \
        <<< "$source_roots_json" >/dev/null 2>&1 || \
       ! dependency_checkouts=$(_act_release_source_dependency_checkouts_json "$tool_name"); then
        return 4
    fi

    while IFS=$'\t' read -r host source_root; do
        [[ -n "$host" && -n "$source_root" ]] || continue
        if ! _act_verify_strict_checkout_snapshot "$host" "$ACT_REPO_LOCAL_PATH" \
            "$source_revision" "$source_root" "source.tar" "$tool_name"; then
            return 4
        fi
        while IFS= read -r dependency; do
            [[ -n "$dependency" ]] || continue
            relative_path=$(jq -r '.relative_path' <<< "$dependency")
            dependency_local=$(jq -r '.local_path' <<< "$dependency")
            dependency_sha=$(jq -r '.git_sha' <<< "$dependency")
            if ! _act_verify_strict_checkout_snapshot "$host" "$dependency_local" "$dependency_sha" \
                "${source_root%/source}/$relative_path" "dependency-${relative_path}.tar" "$relative_path"; then
                return 4
            fi
        done < <(jq -c '.[]' <<< "$dependency_checkouts")
    done < <(jq -r 'to_entries | sort_by(.key)[] | [.key, .value] | @tsv' <<< "$source_roots_json")
}

# Sync sibling crates and patch Cargo.toml for remote builds
# Usage: _act_sync_sibling_crates <host> <remote_project_path> <config_file> <sibling_count>
# When a Rust project uses [patch.crates-io] with absolute local paths (e.g.,
# path = "/dp/asupersync"), those paths don't exist on remote build hosts.
# This function: (1) syncs each sibling crate to the correct relative location
# on the remote host, (2) rewrites absolute paths in the remote Cargo.toml to
# relative paths (e.g., "../asupersync").
_act_sync_sibling_crates() {
    local host="$1"
    local remote_path="$2"
    local config_file="$3"
    local sibling_count="$4"
    local sync_failed=false

    local remote_parent
    # Compute the parent directory of the remote project path
    if _act_is_windows_host "$host"; then
        # Windows path: C:/Users/jeffr/projects/foo → C:/Users/jeffr/projects
        remote_parent="${remote_path%/*}"
    else
        remote_parent="$(dirname "$remote_path")"
    fi

    local idx
    for idx in $(seq 0 $((sibling_count - 1))); do
        local sib_local sib_relative
        sib_local=$(yq -r ".sibling_crates[$idx].local_path" "$config_file" 2>/dev/null)
        sib_relative=$(yq -r ".sibling_crates[$idx].relative_path // empty" "$config_file" 2>/dev/null)
        [[ -z "$sib_relative" ]] && sib_relative=$(basename "$sib_local")

        if [[ ! -d "$sib_local" ]]; then
            _log_warn "Sibling crate not found locally: $sib_local"
            continue
        fi

        # Sync sibling crate to <parent>/<relative_path> on remote host
        local sib_remote_path="${remote_parent}/${sib_relative}"
        _log_info "Syncing sibling crate to $host:$sib_remote_path"
        local respect_gitignore has_respect_gitignore
        has_respect_gitignore=$(yq -r ".sibling_crates[$idx] | has(\"respect_gitignore\")" "$config_file" 2>/dev/null || echo false)
        if [[ "$has_respect_gitignore" == "true" ]]; then
            respect_gitignore=$(yq -r ".sibling_crates[$idx].respect_gitignore" "$config_file" 2>/dev/null || echo true)
        else
            respect_gitignore=true
        fi

        local sync_args=()
        if [[ "$respect_gitignore" != "true" ]]; then
            sync_args+=(--no-gitignore-excludes)
        fi

        local extra_exclude
        while IFS= read -r extra_exclude; do
            [[ -z "$extra_exclude" ]] && continue
            sync_args+=("$extra_exclude")
        done < <(yq -r ".sibling_crates[$idx].extra_excludes // [] | .[]" "$config_file" 2>/dev/null || true)

        if ! _act_sync_source "$host" "$sib_local" "$sib_remote_path" "${sync_args[@]}"; then
            _log_error "Failed to sync sibling crate: $sib_relative"
            sync_failed=true
            continue
        fi

        # Rewrite absolute path to relative in remote Cargo.toml
        # e.g., path = "/dp/asupersync" → path = "../asupersync"
        # Was previously hardcoded to the literal hostname "wlap" —
        # any other Windows host (winbox, ci-windows, …) silently
        # took the Unix branch and ran perl, which doesn't exist on
        # vanilla Windows.  Use the platform-aware helper instead.
        local relative_ref="../${sib_relative}"
        if _act_is_windows_host "$host"; then
            # Windows: use .NET File API to avoid Set-Content's UTF-16LE default
            # encoding on PowerShell 5.x (which would corrupt Cargo.toml).
            # Avoids PowerShell variables ($p, $t) entirely — eliminates all
            # cross-shell escaping issues (bash → SSH → cmd.exe → PowerShell).
            local win_path="${remote_path//\//\\}"
            local toml_path="${win_path}\\Cargo.toml"
            if _act_ssh_exec "$host" "powershell -Command \"[System.IO.File]::WriteAllText('${toml_path}', [System.IO.File]::ReadAllText('${toml_path}').Replace('${sib_local}','${relative_ref}'))\"" 30 2>/dev/null; then
                _log_ok "Patched Cargo.toml on $host: $sib_local → $relative_ref"
            else
                _log_error "Failed to patch Cargo.toml on $host for sibling $sib_relative"
                sync_failed=true
            fi
        else
            # macOS sed requires '' after -i; Linux sed requires no arg after -i
            # Use perl for portable in-place replacement
            if _act_ssh_exec "$host" "cd '${remote_path}' && perl -pi -e 's|\\Q${sib_local}\\E|${relative_ref}|g' Cargo.toml" 30 2>/dev/null; then
                _log_ok "Patched Cargo.toml on $host: $sib_local → $relative_ref"
            else
                _log_error "Failed to patch Cargo.toml on $host for sibling $sib_relative"
                sync_failed=true
            fi
        fi
    done

    if $sync_failed; then
        return 1
    fi

    return 0
}

# Sync source to all native build hosts for a tool
# Usage: act_sync_sources <tool_name> [--strict-release --run-id UUID --git-sha SHA --] [targets...]
# Returns: JSON with sync results
act_sync_sources() {
    local tool_name="$1"
    shift
    local targets_arg=()
    local strict_release=false
    local strict_run_id=""
    local strict_git_sha=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --strict-release)
                strict_release=true
                shift
                ;;
            --run-id)
                [[ $# -ge 2 ]] || { echo '{"status":"error","error":"--run-id requires a value"}'; return 4; }
                strict_run_id="$2"
                shift 2
                ;;
            --git-sha)
                [[ $# -ge 2 ]] || { echo '{"status":"error","error":"--git-sha requires a value"}'; return 4; }
                strict_git_sha="$2"
                shift 2
                ;;
            --)
                shift
                targets_arg+=("$@")
                break
                ;;
            --*)
                _log_error "Unknown source sync option: $1"
                echo '{"status":"error","error":"Unknown source sync option"}'
                return 4
                ;;
            *)
                targets_arg+=("$1")
                shift
                ;;
        esac
    done

    local config_file="$ACT_REPOS_DIR/${tool_name}.yaml"
    if [[ ! -f "$config_file" ]]; then
        _log_error "Config not found: $config_file"
        echo '{"status":"error","error":"Config not found"}'
        return 4
    fi

    local local_path
    local_path=$(act_get_local_path "$tool_name")
    if [[ -z "$local_path" || ! -d "$local_path" ]]; then
        _log_error "Local path not found: $local_path"
        echo '{"status":"error","error":"Local path not found"}'
        return 4
    fi

    local release_contract_json="null"
    if ! release_contract_json=$(_act_release_contract_json "$tool_name"); then
        echo '{"status":"error","error":"Invalid release contract"}'
        return 4
    fi
    if [[ "$release_contract_json" != "null" ]] && ! $strict_release; then
        _log_error "Strict release tools require fresh tracked-byte source sync"
        echo '{"status":"error","error":"Strict release sync flags required"}'
        return 4
    fi
    local strict_dependency_checkouts="[]"
    if $strict_release; then
        if [[ "$release_contract_json" == "null" ]] || ! _act_is_uuid "$strict_run_id" || \
           [[ ! "$strict_git_sha" =~ ^[0-9a-f]{40}$ || "$strict_git_sha" =~ ^0{40}$ ]] || \
           ! _act_validate_strict_checkout_at_revision "$local_path" "$strict_git_sha" "$tool_name" || \
           ! _act_validate_no_absolute_cargo_paths "$local_path" || \
           ! strict_dependency_checkouts=$(_act_release_source_dependency_checkouts_json "$tool_name"); then
            _log_error "Invalid strict release source sync identity"
            echo '{"status":"error","error":"Invalid strict release source sync identity"}'
            return 4
        fi
        local strict_dependency strict_dependency_path strict_dependency_sha strict_dependency_name
        while IFS= read -r strict_dependency; do
            [[ -n "$strict_dependency" ]] || continue
            strict_dependency_path=$(jq -r '.local_path' <<< "$strict_dependency")
            strict_dependency_sha=$(jq -r '.git_sha' <<< "$strict_dependency")
            strict_dependency_name=$(jq -r '.relative_path' <<< "$strict_dependency")
            if ! _act_validate_strict_checkout_at_revision \
                    "$strict_dependency_path" "$strict_dependency_sha" "$strict_dependency_name" || \
               ! _act_validate_no_absolute_cargo_paths "$strict_dependency_path"; then
                echo '{"status":"error","error":"Invalid pinned strict source dependency"}'
                return 4
            fi
        done < <(jq -c '.[]' <<< "$strict_dependency_checkouts")
    fi

    # Determine targets
    local targets
    if [[ ${#targets_arg[@]} -gt 0 ]]; then
        targets="${targets_arg[*]}"
    else
        targets=$(act_get_targets "$tool_name")
    fi

    if $strict_release; then
        local strict_target
        for strict_target in $targets; do
            if act_platform_uses_act "$tool_name" "$strict_target"; then
                _log_error "Strict release target $strict_target cannot use act"
                echo '{"status":"error","error":"Strict release targets must use native builds"}'
                return 4
            fi
        done
    fi

    # Find each unique build location that needs a source snapshot. Legacy act
    # runs use the working tree; strict act runs receive a local tracked-only root.
    local hosts_to_sync=()
    local host_paths=()
    for target in $targets; do
        local host remote_path
        if act_platform_uses_act "$tool_name" "$target"; then
            $strict_release || continue
            host="act"
            remote_path="$local_path"
        else
            host=$(act_get_native_host "$target" "$tool_name")
            remote_path=$(yq -r '.host_paths.'"$host"' // ""' "$config_file" 2>/dev/null)
            [[ -n "$remote_path" ]] || remote_path="$local_path"
        fi
        if [[ -z "$host" ]]; then
            continue
        fi

        # Skip duplicates
        local already_added=false
        for h in "${hosts_to_sync[@]}"; do
            if [[ "$h" == "$host" ]]; then
                already_added=true
                break
            fi
        done
        if $already_added; then
            continue
        fi

        if $strict_release; then
            if ! remote_path=$(_act_strict_source_root_path \
                "$remote_path" "$tool_name" "$strict_run_id"); then
                _log_error "Could not derive a safe fresh source root for $host"
                echo '{"status":"error","error":"Invalid strict release source root"}'
                return 4
            fi
        fi

        hosts_to_sync+=("$host")
        host_paths+=("$remote_path")
    done

    if [[ ${#hosts_to_sync[@]} -eq 0 ]]; then
        _log_info "No build locations need source sync"
        echo '{"status":"skipped","synced":0,"hosts":[],"source_roots":{}}'
        return 0
    fi

    _log_info "Syncing to ${#hosts_to_sync[@]} host(s): ${hosts_to_sync[*]}"

    local synced=0
    local failed=0
    local results=()
    local source_root_entries=()
    local start_time
    start_time=$(date +%s)

    # Check for sibling crates that need syncing alongside the main project
    local sibling_count=0
    if command -v yq &>/dev/null; then
        sibling_count=$(yq -r '.sibling_crates | length // 0' "$config_file" 2>/dev/null || echo 0)
    fi

    for i in "${!hosts_to_sync[@]}"; do
        local host="${hosts_to_sync[$i]}"
        local remote_path="${host_paths[$i]}"

        local source_synced=false
        if $strict_release; then
            if _act_sync_strict_checkout "$host" "$local_path" "$strict_git_sha" \
                "$remote_path" "source.tar" "$tool_name"; then
                source_synced=true
            fi
        elif _act_sync_source "$host" "$local_path" "$remote_path"; then
            source_synced=true
        fi

        if $source_synced; then
            local sync_ok=true

            # Sync sibling crates and patch Cargo.toml paths on REMOTE hosts.
            # Skip when remote_path == local_path (i.e., the build host already
            # has the sibling crates at their absolute paths — no sync/patch needed).
            if $strict_release; then
                local dependency relative_path dependency_local dependency_sha
                while IFS= read -r dependency; do
                    [[ -n "$dependency" ]] || continue
                    relative_path=$(jq -r '.relative_path' <<< "$dependency")
                    dependency_local=$(jq -r '.local_path' <<< "$dependency")
                    dependency_sha=$(jq -r '.git_sha' <<< "$dependency")
                    if ! _act_sync_strict_checkout "$host" "$dependency_local" "$dependency_sha" \
                        "${remote_path%/source}/$relative_path" \
                        "dependency-${relative_path}.tar" "$relative_path"; then
                        sync_ok=false
                        break
                    fi
                done < <(jq -c '.[]' <<< "$strict_dependency_checkouts")
            elif [[ "$sibling_count" -gt 0 && "$remote_path" != "$local_path" ]]; then
                if ! _act_sync_sibling_crates "$host" "$remote_path" "$config_file" "$sibling_count"; then
                    sync_ok=false
                fi
            fi

            if $sync_ok; then
                ((synced++))
                results+=("{\"host\":\"$host\",\"path\":\"$remote_path\",\"status\":\"success\"}")
                source_root_entries+=("$(jq -nc --arg host "$host" --arg path "$remote_path" \
                    '{key: $host, value: $path}')")
            else
                ((failed++))
                results+=("{\"host\":\"$host\",\"path\":\"$remote_path\",\"status\":\"failed\"}")
            fi
        else
            ((failed++))
            results+=("{\"host\":\"$host\",\"path\":\"$remote_path\",\"status\":\"failed\"}")
        fi
    done

    local total_duration=$(($(date +%s) - start_time))

    # Determine overall status
    local status
    if [[ $failed -eq 0 ]]; then
        status="success"
    elif [[ $synced -gt 0 ]]; then
        status="partial"
    else
        status="failed"
    fi

    # Build results JSON
    local results_json
    local source_roots_json="{}"
    if [[ ${#results[@]} -eq 0 ]]; then
        results_json="[]"
    else
        results_json=$(printf '%s\n' "${results[@]}" | jq -s '.')
    fi
    if [[ ${#source_root_entries[@]} -gt 0 ]]; then
        source_roots_json=$(printf '%s\n' "${source_root_entries[@]}" | jq -cs \
            'sort_by(.key) | from_entries')
    fi

    jq -nc \
        --arg status "$status" \
        --argjson synced "$synced" \
        --argjson failed "$failed" \
        --argjson duration "$total_duration" \
        --argjson hosts "$results_json" \
        --argjson source_roots "$source_roots_json" \
        '{
            status: $status,
            synced: $synced,
            failed: $failed,
            duration_seconds: $duration,
            hosts: $hosts,
            source_roots: $source_roots
        }'

    if [[ $failed -gt 0 ]]; then
        return 1
    fi
    return 0
}

# Get build command from config
# Usage: act_get_build_cmd <tool_name>
act_get_build_cmd() {
    local tool_name="$1"
    local config_file="$ACT_REPOS_DIR/${tool_name}.yaml"

    if [[ ! -f "$config_file" ]]; then
        return 4
    fi

    yq -r '.build_cmd // ""' "$config_file" 2>/dev/null
}

# _act_token_is_safe <value> <kind>
# Returns 0 if the build-token value is safe to splice into a shell command,
# 1 otherwise. <kind> is "version" (allows the extra "+" of semver build
# metadata) or anything else (name/os/arch). An empty value is injection-safe
# and accepted. The allowlists permit only characters that real release tags,
# tool names and Go/Rust os/arch values use — every shell metacharacter
# ($ ( ) ` ; | & < > newline space ' " { } * ? [ ] ~ # ! = / \) is excluded.
_act_token_is_safe() {
    local value="$1"
    local kind="$2"
    [[ -z "$value" ]] && return 0
    case "$kind" in
        version) [[ "$value" =~ ^[A-Za-z0-9._+-]+$ ]] ;;
        *)       [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]] ;;
    esac
}

# Pre-substitute DSR's documented build tokens into a build_cmd.
# Usage: act_substitute_build_cmd_tokens <build_cmd> <name> <version> <os> <arch>
#
# DSR substitutes ${version}/${name}/${os}/${arch} (and their aliases) into
# artifact_naming and install_script_compat, but historically NOT into
# build_cmd — there it relied on the *remote build shell* to expand the tokens.
# That works on POSIX build hosts (bash expands ${version} from an exported env
# var) but FAILS on Windows native build hosts: cmd.exe does not POSIX-expand
# ${version}, so the literal string "${version}" was baked into the ldflag. That
# is exactly how beads_viewer v0.17.0 shipped `version.version=${version}`,
# producing `bv v${version}` and a permanent false "update available" banner
# (beads_viewer#174).
#
# Resolving the tokens here — before the command is embedded into any remote
# shell — makes version injection correct on every host. Only DSR's documented,
# brace-delimited tokens are replaced (matching artifact_naming's token set, and
# stripping a leading "v" from the version exactly as artifact_naming does); any
# other shell construct ($HOME, $PATH, unbraced $VAR, ...) is left untouched for
# the shell, so the behavior of every existing repo whose build_cmd has no DSR
# token is byte-for-byte unchanged.
act_substitute_build_cmd_tokens() {
    local cmd="$1"
    local name="$2"
    local version="$3"
    local os="$4"
    local arch="$5"

    # Defense in depth: the substituted command is later executed by a shell
    # (local bash and/or a remote login shell). version/name/os/arch are
    # operator-controlled (release tags + repo config), but a value containing
    # shell metacharacters ($(...), backticks, ; | & < > newline, quotes, ...)
    # would be interpreted by that shell. Refuse such values and abort the build
    # rather than silently injecting them.
    if ! _act_token_is_safe "$version" version; then
        _log_error "act_substitute_build_cmd_tokens: refusing unsafe version token '$version' (allowed: A-Za-z0-9 . _ + -)"
        return 1
    fi
    if ! _act_token_is_safe "$name" name; then
        _log_error "act_substitute_build_cmd_tokens: refusing unsafe name token '$name' (allowed: A-Za-z0-9 . _ -)"
        return 1
    fi
    if ! _act_token_is_safe "$os" os; then
        _log_error "act_substitute_build_cmd_tokens: refusing unsafe os token '$os' (allowed: A-Za-z0-9 . _ -)"
        return 1
    fi
    if ! _act_token_is_safe "$arch" arch; then
        _log_error "act_substitute_build_cmd_tokens: refusing unsafe arch token '$arch' (allowed: A-Za-z0-9 . _ -)"
        return 1
    fi

    local version_stripped="${version#v}"

    cmd="${cmd//\$\{name\}/$name}"
    cmd="${cmd//\$\{NAME\}/$name}"
    cmd="${cmd//\$\{tool\}/$name}"
    cmd="${cmd//\$\{TOOL\}/$name}"

    cmd="${cmd//\$\{version\}/$version_stripped}"
    cmd="${cmd//\$\{VERSION\}/$version_stripped}"

    cmd="${cmd//\$\{os\}/$os}"
    cmd="${cmd//\$\{OS\}/$os}"
    cmd="${cmd//\$\{goos\}/$os}"
    cmd="${cmd//\$\{GOOS\}/$os}"

    cmd="${cmd//\$\{arch\}/$arch}"
    cmd="${cmd//\$\{ARCH\}/$arch}"
    cmd="${cmd//\$\{goarch\}/$arch}"
    cmd="${cmd//\$\{GOARCH\}/$arch}"

    printf '%s' "$cmd"
}

# Get environment variables for a build target
# Usage: act_get_build_env <tool_name> <platform>
# Returns: Newline-separated KEY=VALUE pairs (preserves values with spaces)
act_get_build_env() {
    local tool_name="$1"
    local platform="$2"
    local config_file="$ACT_REPOS_DIR/${tool_name}.yaml"

    if [[ ! -f "$config_file" ]]; then
        echo ""
        return 4
    fi

    local result=""

    # Get global env vars
    local global_env
    global_env=$(yq -r '.env // {} | to_entries | map(.key + "=" + .value) | .[]' "$config_file" 2>/dev/null)
    [[ -n "$global_env" ]] && result="$global_env"

    # Get platform-specific cross_compile env vars (join with newline to preserve spaces in values)
    local platform_env
    platform_env=$(yq -r ".cross_compile.\"$platform\".env // {} | to_entries | map(.key + \"=\" + .value) | .[]" "$config_file" 2>/dev/null)
    if [[ -n "$platform_env" ]]; then
        if [[ -n "$result" ]]; then
            result="$result"$'\n'"$platform_env"
        else
            result="$platform_env"
        fi
    fi

    echo "$result"
}

# Get a single environment variable value from newline-delimited KEY=VALUE pairs.
# Usage: act_get_build_env_value <build_env> <key>
act_get_build_env_value() {
    local build_env="$1"
    local key="$2"
    local env_pair

    while IFS= read -r env_pair; do
        [[ -z "$env_pair" ]] && continue
        if [[ "$env_pair" == "$key="* ]]; then
            printf '%s\n' "${env_pair#*=}"
            return 0
        fi
    done <<< "$build_env"

    return 1
}

_act_default_rust_target_triple() {
    case "$1" in
        linux/amd64) printf 'x86_64-unknown-linux-gnu\n' ;;
        linux/arm64) printf 'aarch64-unknown-linux-gnu\n' ;;
        darwin/amd64) printf 'x86_64-apple-darwin\n' ;;
        darwin/arm64) printf 'aarch64-apple-darwin\n' ;;
        windows/amd64) printf 'x86_64-pc-windows-msvc\n' ;;
        windows/arm64) printf 'aarch64-pc-windows-msvc\n' ;;
        *) return 4 ;;
    esac
}

_act_is_rust_build_influence_name() {
    case "$1" in
        CARGO_*|RUST*|CC|CXX|CPP|AR|RANLIB|LD|NM|OBJCOPY|STRIP|\
        CFLAGS|CXXFLAGS|CPPFLAGS|LDFLAGS|BINDGEN_EXTRA_CLANG_ARGS|\
        SDKROOT|MACOSX_DEPLOYMENT_TARGET|IPHONEOS_DEPLOYMENT_TARGET|\
        INCLUDE|LIB|LIBPATH|CC_*|CXX_*|AR_*|CFLAGS_*|CXXFLAGS_*|\
        *_CC|*_CXX|*_AR|*_RANLIB|*_CFLAGS|*_CXXFLAGS|*_LDFLAGS)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Resolve the remote path to a built binary for SCP retrieval.
# Usage: act_get_remote_artifact_path <language> <remote_path> <build_env> <binary_name> <platform>
act_get_remote_artifact_path() {
    local language="$1"
    local remote_path="${2%/}"
    local build_env="$3"
    local binary_name="$4"
    local platform="$5"
    local artifact_base=""

    case "$language" in
        rust)
            local cargo_target_dir=""
            local cargo_build_target=""
            cargo_target_dir=$(act_get_build_env_value "$build_env" "CARGO_TARGET_DIR" 2>/dev/null || true)
            cargo_build_target=$(act_get_build_env_value "$build_env" "CARGO_BUILD_TARGET" 2>/dev/null || true)
            cargo_target_dir="${cargo_target_dir%/}"
            cargo_target_dir="${cargo_target_dir%\\}"

            if [[ -n "$cargo_target_dir" ]]; then
                case "$cargo_target_dir" in
                    /*|[A-Za-z]:/*|[A-Za-z]:\\*)
                        artifact_base="$cargo_target_dir/release"
                        ;;
                    *)
                        artifact_base="$remote_path/$cargo_target_dir/release"
                        ;;
                esac
            else
                artifact_base="$remote_path/target/release"
            fi

            if [[ -n "$cargo_build_target" ]]; then
                artifact_base="${artifact_base%/release}/$cargo_build_target/release"
            fi
            ;;
        go)
            artifact_base="$remote_path"
            ;;
        *)
            artifact_base="$remote_path"
            ;;
    esac

    local remote_artifact_path="$artifact_base/$binary_name"
    if [[ "$platform" == windows/* ]]; then
        remote_artifact_path="${remote_artifact_path//\\//}"
        remote_artifact_path+=".exe"
    fi

    printf '%s\n' "$remote_artifact_path"
}

# Get GitHub repo for a tool
# Usage: act_get_repo <tool_name>
act_get_repo() {
    local tool_name="$1"
    local config_file="$ACT_REPOS_DIR/${tool_name}.yaml"

    if [[ ! -f "$config_file" ]]; then
        return 4
    fi

    yq -r '.repo // ""' "$config_file" 2>/dev/null
}

# Get local path for a tool
# Usage: act_get_local_path <tool_name>
act_get_local_path() {
    local tool_name="$1"
    local config_file="$ACT_REPOS_DIR/${tool_name}.yaml"

    if [[ ! -f "$config_file" ]]; then
        return 4
    fi

    yq -r '.local_path // ""' "$config_file" 2>/dev/null
}

# Ensure remote repo is in a valid git state for builds (bd-1tv.9)
# Handles: missing repos, broken .git, dirty working tree
#
# Usage: act_ensure_remote_repo_ready <host> <remote_path> <repo_url> <version>
# Returns: 0 on success, 1 on failure
act_ensure_remote_repo_ready() {
    local host="$1"
    local remote_path="$2"
    local repo_url="$3"
    local version="$4"

    _log_info "Ensuring repo at $host:$remote_path is ready..."

    # Determine if this is a Windows host.  Was previously hardcoded
    # to the literal hostname "wlap"; that broke any other Windows
    # host added later (winbox, ci-windows, etc.) — _act_is_windows_host
    # consults the host's configured platform instead.
    local is_windows=false
    if _act_is_windows_host "$host"; then
        is_windows=true
    fi

    # Build commands for git operations
    local test_dir_cmd test_git_cmd clone_cmd pull_cmd checkout_cmd stash_cmd rm_cmd

    if $is_windows; then
        # Windows: use PowerShell for reliable path handling
        local win_path="${remote_path//\//\\}"
        test_dir_cmd="if exist \"$win_path\" (exit 0) else (exit 1)"
        test_git_cmd="if exist \"$win_path\\.git\" (exit 0) else (exit 1)"
        clone_cmd="git clone \"$repo_url\" \"$win_path\""
        pull_cmd="cd /d \"$win_path\" && git fetch --all --tags && git reset --hard origin/HEAD"
        checkout_cmd="cd /d \"$win_path\" && git checkout \"$version\""
        stash_cmd="cd /d \"$win_path\" && git stash --include-untracked"
        rm_cmd="rmdir /s /q \"$win_path\""
    else
        # Unix
        test_dir_cmd="test -d '$remote_path'"
        test_git_cmd="test -d '$remote_path/.git'"
        clone_cmd="git clone '$repo_url' '$remote_path'"
        pull_cmd="cd '$remote_path' && git fetch --all --tags && git reset --hard origin/HEAD"
        checkout_cmd="cd '$remote_path' && git checkout '$version'"
        stash_cmd="cd '$remote_path' && git stash --include-untracked"
        rm_cmd="rm -rf '$remote_path'"
    fi

    # Step 1: Check if path exists
    if ! _act_ssh_exec "$host" "$test_dir_cmd" 30 &>/dev/null; then
        _log_info "Directory doesn't exist on $host, cloning..."
        if ! _act_ssh_exec "$host" "$clone_cmd" 300; then
            _log_error "Failed to clone repo on $host"
            return 1
        fi
        _log_ok "Cloned repo on $host"
    else
        # Step 2: Check if .git exists
        if ! _act_ssh_exec "$host" "$test_git_cmd" 30 &>/dev/null; then
            _log_warn "Missing .git on $host, re-cloning..."

            # Remove existing directory and clone fresh
            if ! _act_ssh_exec "$host" "$rm_cmd && $clone_cmd" 300; then
                _log_error "Failed to re-clone repo on $host"
                return 1
            fi
            _log_ok "Re-cloned repo on $host"
        else
            # Step 3: Try to update (stash if needed)
            _log_info "Updating repo on $host..."

            # First try a clean pull with reset (handles most dirty tree issues)
            if ! _act_ssh_exec "$host" "$pull_cmd" 120 2>/dev/null; then
                _log_warn "Pull failed on $host, trying stash and pull..."

                # Stash any local changes and try again
                if _act_ssh_exec "$host" "$stash_cmd" 60 2>/dev/null; then
                    if ! _act_ssh_exec "$host" "$pull_cmd" 120; then
                        _log_error "Pull still failed after stash on $host"
                        return 1
                    fi
                else
                    # Last resort: nuke everything and re-clone
                    _log_warn "Stash failed, re-cloning as last resort..."
                    if ! _act_ssh_exec "$host" "$rm_cmd && $clone_cmd" 300; then
                        _log_error "Re-clone failed on $host"
                        return 1
                    fi
                fi
            fi
            _log_ok "Updated repo on $host"
        fi
    fi

    # Step 4: Checkout the target version
    _log_info "Checking out $version on $host..."
    if ! _act_ssh_exec "$host" "$checkout_cmd" 60; then
        _log_error "Failed to checkout $version on $host"
        return 1
    fi

    _log_ok "Repo ready at $host:$remote_path (version: $version)"
    return 0
}

# Ensure repos are ready on all native build hosts for a tool
# Usage: act_ensure_repos_ready <tool_name> <version> [targets...]
# Returns: JSON with readiness results
act_ensure_repos_ready() {
    local tool_name="$1"
    local version="$2"
    shift 2
    local targets_arg=("$@")

    local config_file="$ACT_REPOS_DIR/${tool_name}.yaml"
    if [[ ! -f "$config_file" ]]; then
        _log_error "Config not found: $config_file"
        echo '{"status":"error","error":"Config not found"}'
        return 4
    fi

    local repo_url
    repo_url=$(act_get_repo "$tool_name")
    if [[ -z "$repo_url" ]]; then
        _log_error "No repo URL in config"
        echo '{"status":"error","error":"No repo URL in config"}'
        return 4
    fi

    # Convert repo shorthand to full URL
    if [[ "$repo_url" != https://* && "$repo_url" != git@* ]]; then
        repo_url="https://github.com/${repo_url}.git"
    fi

    # Determine targets
    local targets
    if [[ ${#targets_arg[@]} -gt 0 ]]; then
        targets="${targets_arg[*]}"
    else
        targets=$(act_get_targets "$tool_name")
    fi

    # Find unique native hosts that need repo setup
    local -A hosts_checked=()
    local results=()
    local ready=0 failed=0

    for target in $targets; do
        # Skip targets that use act (no remote repo needed)
        if act_platform_uses_act "$tool_name" "$target"; then
            continue
        fi

        local host
        host=$(act_get_native_host "$target" "$tool_name")
        [[ -z "$host" ]] && continue

        # Skip if already checked this host
        [[ -n "${hosts_checked[$host]:-}" ]] && continue
        hosts_checked[$host]=1

        # Get remote path for this host
        local remote_path
        remote_path=$(yq -r '.host_paths.'"$host"' // ""' "$config_file" 2>/dev/null)
        if [[ -z "$remote_path" ]]; then
            remote_path=$(act_get_local_path "$tool_name")
        fi

        _log_info "Checking $host:$remote_path..."

        if act_ensure_remote_repo_ready "$host" "$remote_path" "$repo_url" "$version"; then
            results+=("{\"host\":\"$host\",\"path\":\"$remote_path\",\"status\":\"ready\"}")
            ((ready++))
        else
            results+=("{\"host\":\"$host\",\"path\":\"$remote_path\",\"status\":\"failed\"}")
            ((failed++))
        fi
    done

    # Build results JSON
    local status
    if [[ $failed -eq 0 ]]; then
        status="success"
    elif [[ $ready -gt 0 ]]; then
        status="partial"
    else
        status="failed"
    fi

    local results_json
    if [[ ${#results[@]} -eq 0 ]]; then
        results_json="[]"
    else
        results_json=$(printf '%s\n' "${results[@]}" | jq -s '.')
    fi

    jq -nc \
        --arg status "$status" \
        --argjson ready "$ready" \
        --argjson failed "$failed" \
        --argjson hosts "$results_json" \
        '{
            status: $status,
            ready: $ready,
            failed: $failed,
            hosts: $hosts
        }'

    [[ $failed -gt 0 ]] && return 1
    return 0
}

# Execute command on remote host via SSH
# Usage: _act_ssh_exec <host> <command> [timeout]
# Returns: Exit code from remote command
_act_ssh_exec() {
    local host="$1"
    local cmd="$2"
    local timeout_sec="${3:-$_ACT_BUILD_TIMEOUT}"

    if _act_is_local_host "$host"; then
        _act_run_with_timeout "$timeout_sec" bash -lc "$cmd"
    else
        local ssh_destination
        ssh_destination=$(_act_get_ssh_destination "$host") || return 4
        _act_run_with_timeout "$timeout_sec" ssh \
            -o ConnectTimeout="$_ACT_SSH_TIMEOUT" \
            -o BatchMode=yes \
            -o StrictHostKeyChecking=accept-new \
            "$ssh_destination" "$cmd"
    fi
}

# Run native build on remote host via SSH
# Usage: act_run_native_build <tool_name> <platform> <version> [run_id] [remote_path_override]
# Returns: JSON result with status, exit_code, artifact info
act_run_native_build() {
    local tool_name="$1"
    local platform="$2"
    local version="$3"
    local run_id="${4:-}"
    local remote_path_override="${5:-}"

    local host
    host=$(act_get_native_host "$platform" "$tool_name")
    if [[ -z "$host" ]]; then
        _log_error "No native host configured for platform: $platform"
        jq -nc --arg platform "$platform" \
            '{status: "error", exit_code: 4, error: ("No native host for " + $platform)}'
        return 4
    fi
    local ssh_destination="$host"
    if ! _act_is_local_host "$host"; then
        ssh_destination=$(_act_get_ssh_destination "$host") || return 4
    fi

    # Get build configuration
    local local_path build_cmd build_env binary_name
    local config_file="$ACT_REPOS_DIR/${tool_name}.yaml"

    if [[ ! -f "$config_file" ]]; then
        _log_error "Config not found: $config_file"
        jq -nc --arg config_file "$config_file" \
            '{status: "error", exit_code: 4, error: ("Config not found: " + $config_file)}'
        return 4
    fi

    local_path=$(act_get_local_path "$tool_name")
    build_cmd=$(act_get_build_cmd "$tool_name")
    build_env=$(act_get_build_env "$tool_name" "$platform")
    binary_name=$(yq -r '.binary_name // ""' "$config_file" 2>/dev/null)

    local language
    language=$(yq -r '.language // ""' "$config_file" 2>/dev/null)

    # Check for workspace_binaries (multi-binary Rust workspaces)
    local workspace_binaries
    workspace_binaries=$(yq -r '.workspace_binaries // [] | .[]' "$config_file" 2>/dev/null)

    if [[ -z "$local_path" || -z "$build_cmd" ]]; then
        _log_error "Missing local_path or build_cmd in config"
        jq -nc '{status: "error", exit_code: 4, error: "Missing required config fields"}'
        return 4
    fi

    # Resolve DSR build tokens (${version} etc.) in build_cmd now, before it is
    # embedded into the (possibly Windows/cmd.exe) remote shell below — cmd.exe
    # does not POSIX-expand ${version}, which is how a literal "${version}" once
    # reached an ldflag (beads_viewer#174). os/arch come from the platform; the
    # name falls back to the tool name when binary_name is unset.
    local _act_build_os="${platform%%/*}"
    local _act_build_arch="${platform##*/}"
    if ! build_cmd=$(act_substitute_build_cmd_tokens "$build_cmd" "${binary_name:-$tool_name}" "$version" "$_act_build_os" "$_act_build_arch"); then
        _log_error "Refusing to build $tool_name: build_cmd token substitution rejected an unsafe value (version=$version platform=$platform)"
        jq -nc --arg tool "$tool_name" --arg version "$version" --arg platform "$platform" \
            '{status: "error", exit_code: 4, error: ("unsafe build_cmd token value for " + $tool + " " + $version + " " + $platform)}'
        return 4
    fi

    # Determine remote path (check host_paths.<host> first, fallback to local_path)
    local remote_path
    remote_path="$remote_path_override"
    if [[ -z "$remote_path" ]]; then
        remote_path=$(yq -r '.host_paths.'"$host"' // ""' "$config_file" 2>/dev/null)
        if [[ -z "$remote_path" ]]; then
            remote_path="$local_path"
        fi
    fi

    # A strict source root must remain byte-for-byte equal to its tracked
    # archive after the build. Force Rust outputs beside that root, even when a
    # repo config supplied an in-tree CARGO_TARGET_DIR.
    local strict_native_build=false
    [[ -n "$remote_path_override" ]] && strict_native_build=true
    local strict_rust_build=false
    local build_influence_env_json='{}'
    if [[ "$language" == "rust" && -n "$remote_path_override" ]]; then
        strict_rust_build=true
        local strict_cargo_target_dir="${remote_path%/*}/.cargo-target-${platform//\//-}"
        local strict_cargo_home="${remote_path%/*}/.cargo-home"
        local strict_build_env="" env_pair
        if [[ ! "$strict_cargo_target_dir" =~ ^[A-Za-z0-9_./:+-]+$ || \
              "$strict_cargo_target_dir" == *..* || \
              ! "$strict_cargo_home" =~ ^[A-Za-z0-9_./:+-]+$ || \
              "$strict_cargo_home" == *..* ]]; then
            _log_error "Unable to derive isolated strict Cargo paths"
            jq -nc '{status: "error", exit_code: 4, error: "Invalid strict Cargo isolation paths"}'
            return 4
        fi
        while IFS= read -r env_pair; do
            [[ -z "$env_pair" || "$env_pair" == CARGO_TARGET_DIR=* || \
               "$env_pair" == CARGO_HOME=* ]] && continue
            if [[ -n "$strict_build_env" ]]; then
                strict_build_env+=$'\n'
            fi
            strict_build_env+="$env_pair"
        done <<< "$build_env"
        if [[ -n "$strict_build_env" ]]; then
            strict_build_env+=$'\n'
        fi
        strict_build_env+="CARGO_TARGET_DIR=$strict_cargo_target_dir"
        strict_build_env+=$'\n'"CARGO_HOME=$strict_cargo_home"
        build_env="$strict_build_env"

        local influence_entries=() influence_name influence_value
        while IFS= read -r env_pair; do
            [[ -n "$env_pair" && "$env_pair" == *=* ]] || continue
            influence_name="${env_pair%%=*}"
            influence_value="${env_pair#*=}"
            if _act_is_rust_build_influence_name "$influence_name"; then
                influence_entries+=("$(jq -nc \
                    --arg key "$influence_name" --arg value "$influence_value" \
                    '{key: $key, value: $value}')")
            fi
        done <<< "$build_env"
        if [[ ${#influence_entries[@]} -gt 0 ]]; then
            build_influence_env_json=$(printf '%s\n' "${influence_entries[@]}" | \
                jq -cs 'sort_by(.key) | from_entries') || return 4
        fi
    fi

    # Prepare log file
    local log_dir log_file
    log_dir="$ACT_LOGS_DIR"
    mkdir -p "$log_dir"
    log_file="$log_dir/${tool_name}-${platform//\//-}-${run_id:-$$}.log"

    _log_info "Building $tool_name for $platform on $host"
    _log_info "Remote path: $remote_path"
    _log_info "Build cmd: $build_cmd"
    _log_info "Log file: $log_file"

    local start_time
    start_time=$(date +%s)

    # Release builds must be reproducible from the DSR repo config, not from
    # whichever Cargo env vars happened to be exported in the operator shell.
    local cargo_env_to_unset=()
    if [[ "$language" == "rust" ]]; then
        if $strict_rust_build; then
            cargo_env_to_unset=(
                CARGO_HOME CARGO_TARGET_DIR CARGO_BUILD_TARGET CARGO_BUILD_JOBS
                CARGO_INCREMENTAL CARGO_ENCODED_RUSTFLAGS
                RUSTC RUSTC_WRAPPER RUSTC_WORKSPACE_WRAPPER RUSTFLAGS
                RUSTDOC RUSTDOCFLAGS RUSTUP_HOME RUSTUP_TOOLCHAIN
                CC CXX CPP AR RANLIB LD NM OBJCOPY STRIP
                CFLAGS CXXFLAGS CPPFLAGS LDFLAGS BINDGEN_EXTRA_CLANG_ARGS
                SDKROOT MACOSX_DEPLOYMENT_TARGET IPHONEOS_DEPLOYMENT_TARGET
                INCLUDE LIB LIBPATH
            )
            local rust_target_triple rust_target_upper rust_target_lower influence_prefix
            rust_target_triple=$(act_get_build_env_value "$build_env" "CARGO_BUILD_TARGET" 2>/dev/null || true)
            [[ -n "$rust_target_triple" ]] || rust_target_triple=$(_act_default_rust_target_triple "$platform")
            rust_target_upper=$(printf '%s' "$rust_target_triple" | tr '[:lower:]-.' '[:upper:]__')
            rust_target_lower=$(printf '%s' "$rust_target_triple" | tr '.-' '__')
            cargo_env_to_unset+=(
                "CARGO_TARGET_${rust_target_upper}_LINKER"
                "CARGO_TARGET_${rust_target_upper}_RUSTFLAGS"
                "CARGO_TARGET_${rust_target_upper}_RUNNER"
            )
            for influence_prefix in CC CXX AR RANLIB CFLAGS CXXFLAGS LDFLAGS; do
                cargo_env_to_unset+=(
                    "${influence_prefix}_${rust_target_lower}"
                    "${influence_prefix}_${rust_target_upper}"
                    "${rust_target_lower}_${influence_prefix}"
                    "${rust_target_upper}_${influence_prefix}"
                )
            done
        elif ! act_get_build_env_value "$build_env" "CARGO_TARGET_DIR" >/dev/null 2>&1; then
            cargo_env_to_unset+=("CARGO_TARGET_DIR")
        fi
        if ! $strict_rust_build && \
           ! act_get_build_env_value "$build_env" "CARGO_BUILD_TARGET" >/dev/null 2>&1; then
            cargo_env_to_unset+=("CARGO_BUILD_TARGET")
        fi
    fi

    # Construct the remote command
    # Shell syntax depends on the build host OS, not only the target platform.
    local remote_cmd
    if _act_is_windows_host "$host"; then
        # Windows: use cmd.exe compatible syntax
        # - Use double quotes for paths
        # - Use 'set' instead of 'export' for env vars
        # - Use '&&' which works in cmd.exe
        # Note: In cmd.exe, 'set VAR=value && ...' includes trailing space in value.
        # Using 'set "VAR=value"' protects the value from the space before &&.
        local win_path="${remote_path//\//\\}"
        local env_exports=""
        local env_name
        if $strict_rust_build; then
            local win_strict_cargo_home
            win_strict_cargo_home=$(_act_windows_cmd_path "$strict_cargo_home")
            env_exports+="powershell -NoProfile -NonInteractive -Command \"\$ErrorActionPreference='Stop'; \$home=Get-Item -LiteralPath '${win_strict_cargo_home}' -Force; if (-not \$home.PSIsContainer -or ((\$home.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'Strict CARGO_HOME is not isolated' }; foreach (\$name in @('config','config.toml','credentials','credentials.toml')) { if (Test-Path -LiteralPath (Join-Path \$home.FullName \$name)) { throw 'Strict CARGO_HOME contains configuration' } }; \$ancestor=(Get-Item -LiteralPath '${win_path}').Parent; while (\$null -ne \$ancestor) { \$cargoDir=Join-Path \$ancestor.FullName '.cargo'; foreach (\$name in @('config','config.toml')) { if (Test-Path -LiteralPath (Join-Path \$cargoDir \$name)) { throw 'Untracked ancestor Cargo config is forbidden' } }; \$ancestor=\$ancestor.Parent }\" && for /f \"tokens=1 delims==\" %V in ('set CARGO_ 2^>nul') do @set \"%V=\" & for /f \"tokens=1 delims==\" %V in ('set RUST 2^>nul') do @set \"%V=\" & "
        fi
        for env_name in "${cargo_env_to_unset[@]}"; do
            env_exports+="set \"$env_name=\" && "
        done
        # build_env is newline-delimited to preserve values with spaces
        while IFS= read -r env_pair; do
            [[ -z "$env_pair" ]] && continue
            env_exports+="set \"$env_pair\" && "
        done <<< "$build_env"
        # Convert forward slashes to backslashes for Windows paths
        remote_cmd="cd /d \"${win_path}\" && ${env_exports}${build_cmd}"
        if $strict_rust_build; then
            local ps_build_b64 ps_env_assignments="" env_name env_value env_name_b64 env_value_b64
            if ! command -v base64 >/dev/null 2>&1; then
                _log_error "base64 is required to construct a strict Windows build"
                return 3
            fi
            ps_build_b64=$(printf '%s' "$build_cmd" | base64 | tr -d '\r\n') || return 4
            while IFS= read -r env_pair; do
                [[ -n "$env_pair" && "$env_pair" == *=* ]] || continue
                env_name="${env_pair%%=*}"
                env_value="${env_pair#*=}"
                [[ "$env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 4
                env_name_b64=$(printf '%s' "$env_name" | base64 | tr -d '\r\n') || return 4
                env_value_b64=$(printf '%s' "$env_value" | base64 | tr -d '\r\n') || return 4
                ps_env_assignments+="\$psi.EnvironmentVariables[[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${env_name_b64}'))]=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${env_value_b64}')); "
            done <<< "$build_env"
            remote_cmd="powershell -NoProfile -NonInteractive -Command \"\$ErrorActionPreference='Stop'; \$home=Get-Item -LiteralPath '${win_strict_cargo_home}' -Force; if (-not \$home.PSIsContainer -or ((\$home.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'Strict CARGO_HOME is not isolated' }; foreach (\$name in @('config','config.toml','credentials','credentials.toml')) { if (Test-Path -LiteralPath (Join-Path \$home.FullName \$name)) { throw 'Strict CARGO_HOME contains configuration' } }; \$ancestor=(Get-Item -LiteralPath '${win_path}').Parent; while (\$null -ne \$ancestor) { \$cargoDir=Join-Path \$ancestor.FullName '.cargo'; foreach (\$name in @('config','config.toml')) { if (Test-Path -LiteralPath (Join-Path \$cargoDir \$name)) { throw 'Untracked ancestor Cargo config is forbidden' } }; \$ancestor=\$ancestor.Parent }; \$psi=New-Object System.Diagnostics.ProcessStartInfo; \$psi.UseShellExecute=\$false; \$keys=@(\$psi.EnvironmentVariables.Keys); foreach (\$key in \$keys) { if ((\$key -match '^(CARGO_|RUST)') -or (\$key -match '^(CC|CXX|CPP|AR|RANLIB|LD|NM|OBJCOPY|STRIP|CFLAGS|CXXFLAGS|CPPFLAGS|LDFLAGS|BINDGEN_EXTRA_CLANG_ARGS|SDKROOT|MACOSX_DEPLOYMENT_TARGET|IPHONEOS_DEPLOYMENT_TARGET|INCLUDE|LIB|LIBPATH)(_|$)') -or (\$key -match '_(CC|CXX|AR|RANLIB|CFLAGS|CXXFLAGS|LDFLAGS)$')) { \$psi.EnvironmentVariables.Remove(\$key) } }; ${ps_env_assignments}\$psi.FileName=\$env:ComSpec; \$psi.WorkingDirectory='${win_path}'; \$command=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${ps_build_b64}')); \$psi.Arguments='/d /s /c ' + \$command; \$process=[Diagnostics.Process]::Start(\$psi); \$process.WaitForExit(); exit \$process.ExitCode\""
        fi
    else
        # Unix: use bash/zsh compatible syntax
        local env_exports=""
        local env_name
        if $strict_rust_build; then
            env_exports+="test -d '$strict_cargo_home'; test ! -L '$strict_cargo_home'; for name in config config.toml credentials credentials.toml; do test ! -e '$strict_cargo_home'/\$name; test ! -L '$strict_cargo_home'/\$name; done; ancestor='${remote_path%/*}'; while test \"\$ancestor\" != / && test -n \"\$ancestor\"; do for name in config config.toml; do test ! -e \"\$ancestor/.cargo/\$name\"; test ! -L \"\$ancestor/.cargo/\$name\"; done; ancestor=\${ancestor%/*}; test -n \"\$ancestor\" || ancestor=/; done; for variable in \$(env | sed 's/=.*//'); do case \"\$variable\" in CARGO_*|RUST*|CC|CXX|CPP|AR|RANLIB|LD|CFLAGS|CXXFLAGS|CPPFLAGS|LDFLAGS) unset \"\$variable\";; esac; done; "
        fi
        for env_name in "${cargo_env_to_unset[@]}"; do
            env_exports+="unset $env_name; "
        done
        # build_env is newline-delimited to preserve values with spaces
        while IFS= read -r env_pair; do
            [[ -z "$env_pair" ]] && continue
            # Quote the env_pair to handle values with spaces (e.g., FOO="bar baz")
            env_exports+="export \"$env_pair\"; "
        done <<< "$build_env"
        remote_cmd="set -e; cd '${remote_path//\'/\'\\\'\'}'; $env_exports$build_cmd"
    fi

    # Execute on remote host
    # Use PIPESTATUS to capture the actual command exit code, not tee's
    _act_ssh_exec "$host" "$remote_cmd" 2>&1 | tee "$log_file"
    local exit_code=${PIPESTATUS[0]}

    local end_time duration
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    # Determine result
    local status local_artifact_path="" local_artifact_paths=()
    local collected_sha256="" collected_size_bytes=0 collected_identity=""
    local strict_collection_receipts=()
    if [[ $exit_code -eq 0 ]]; then
        _log_ok "Build completed on $host in ${duration}s"
        status="success"

        # Use run_id if available to group artifacts; isolate per-target to avoid name collisions
        local artifact_dir
        if $strict_native_build; then
            if ! mkdir -p "$ACT_ARTIFACTS_DIR" || \
               [[ ! -d "$ACT_ARTIFACTS_DIR" || -L "$ACT_ARTIFACTS_DIR" ]] || \
               ! artifact_dir=$(mktemp -d \
                    "$ACT_ARTIFACTS_DIR/${run_id}-${platform//\//-}.XXXXXXXX") || \
               ! chmod 700 "$artifact_dir" || \
               [[ ! -d "$artifact_dir" || -L "$artifact_dir" ]]; then
                _log_error "Unable to create a fresh private artifact collection directory for $platform"
                jq -nc '{status: "error", exit_code: 4, error: "Private strict artifact directory unavailable"}'
                return 4
            fi
        else
            artifact_dir="$ACT_ARTIFACTS_DIR/${run_id:-build-$tool_name-$(date +%s)}/${platform//\//-}"
            mkdir -p "$artifact_dir"
        fi

        # Small delay to ensure files are fully flushed on remote
        sleep 1

        # Determine which binaries to download
        local binaries_to_download=()
        if [[ -n "$workspace_binaries" ]]; then
            # Multi-binary workspace: download each binary
            while IFS= read -r bin; do
                [[ -n "$bin" ]] && binaries_to_download+=("$bin")
            done <<< "$workspace_binaries"
            _log_info "Workspace mode: downloading ${#binaries_to_download[@]} binaries"
        elif [[ -n "$binary_name" ]]; then
            # Single binary mode
            binaries_to_download=("$binary_name")
        else
            _log_error "No binary_name or workspace_binaries configured"
            jq -nc '{status: "error", exit_code: 4, error: "No binaries configured"}'
            return 4
        fi

        # Sanity check: ensure we have binaries to download
        if [[ ${#binaries_to_download[@]} -eq 0 ]]; then
            _log_error "No binaries to download (workspace_binaries may be empty)"
            jq -nc '{status: "error", exit_code: 4, error: "No binaries to download"}'
            return 4
        fi

        local download_failed=false
        for bin in "${binaries_to_download[@]}"; do
            local remote_artifact_path
            remote_artifact_path=$(act_get_remote_artifact_path "$language" "$remote_path" "$build_env" "$bin" "$platform")

            local artifact_filename
            artifact_filename=$(basename "$remote_artifact_path")
            local this_artifact_path="$artifact_dir/$artifact_filename"

            _log_info "Downloading artifact: ${host}:${remote_artifact_path}"
            local scp_output
            if $strict_native_build; then
                local collection_receipt="" collection_mode=700
                [[ "$platform" == windows/* ]] && collection_mode=600
                if _act_is_local_host "$host"; then
                    local copy_src="$remote_artifact_path"
                    if [[ ! -f "$copy_src" && "$copy_src" == *.exe && \
                          -f "${copy_src%.exe}" && ! -L "${copy_src%.exe}" ]]; then
                        copy_src="${copy_src%.exe}"
                        _log_info "Windows artifact lacks .exe suffix; streaming $copy_src"
                    fi
                    if collection_receipt=$(_act_collect_stream_exclusive \
                            "$this_artifact_path" "$collection_mode" \
                            _act_stream_local_file "$copy_src"); then
                        :
                    else
                        collection_receipt=""
                    fi
                elif _act_is_windows_host "$host"; then
                    collection_receipt=$(_act_collect_stream_exclusive \
                        "$this_artifact_path" "$collection_mode" \
                        _act_stream_remote_windows_file \
                        "$ssh_destination" "$remote_artifact_path") || collection_receipt=""
                else
                    collection_receipt=$(_act_collect_stream_exclusive \
                        "$this_artifact_path" "$collection_mode" \
                        _act_stream_remote_unix_file \
                        "$ssh_destination" "$remote_artifact_path") || collection_receipt=""
                fi

                if [[ -z "$collection_receipt" && "$remote_artifact_path" == *.exe ]] && \
                   ! _act_is_local_host "$host"; then
                    local fallback_dir alt_remote_artifact_path="${remote_artifact_path%.exe}"
                    if fallback_dir=$(mktemp -d "$artifact_dir/retry.XXXXXXXX") && \
                       chmod 700 "$fallback_dir" && \
                       [[ -d "$fallback_dir" && ! -L "$fallback_dir" ]]; then
                        this_artifact_path="$fallback_dir/$artifact_filename"
                        if _act_is_windows_host "$host"; then
                            collection_receipt=$(_act_collect_stream_exclusive \
                                "$this_artifact_path" "$collection_mode" \
                                _act_stream_remote_windows_file \
                                "$ssh_destination" "$alt_remote_artifact_path") || collection_receipt=""
                        else
                            collection_receipt=$(_act_collect_stream_exclusive \
                                "$this_artifact_path" "$collection_mode" \
                                _act_stream_remote_unix_file \
                                "$ssh_destination" "$alt_remote_artifact_path") || collection_receipt=""
                        fi
                        [[ -z "$collection_receipt" ]] || \
                            _log_info "Windows artifact lacks .exe suffix; streamed $alt_remote_artifact_path"
                    fi
                fi

                if [[ -n "$collection_receipt" ]] && \
                   jq -e '(.sha256 | test("^[0-9a-f]{64}$")) and
                          (.size_bytes | type == "number" and . > 0) and
                          (.identity | test("^(gnu:[0-9]+:[1-9][0-9]*|bsd:[1-9][0-9]*)$"))' \
                       <<< "$collection_receipt" >/dev/null 2>&1; then
                    _log_ok "Artifact collected through held descriptor: $this_artifact_path"
                    local_artifact_paths+=("$this_artifact_path")
                    strict_collection_receipts+=("$collection_receipt")
                else
                    _log_error "Failed to collect artifact $bin from $host"
                    echo "Strict stream collection failed for $bin: $remote_artifact_path" >> "$log_file"
                    download_failed=true
                fi
            elif _act_is_local_host "$host"; then
                # Local host: no SCP, just cp from the remote_path (which IS
                # the build path locally). Go cross-compiled to a windows
                # target with an explicit `-o <name>` does NOT append .exe,
                # so if the .exe form is missing, fall back to the bare
                # name before declaring failure. Previously this branch
                # neither populated local_artifact_paths on success nor set
                # download_failed on failure, so a successful local cp was
                # silently dropped from the result JSON — every downstream
                # per-target artifact_path lookup came back empty, collection
                # only saw one artifact, and packaging fell through to the
                # generic `_build_find_binary "$output_dir"` path which
                # returned the same (first-collected) binary for every
                # target.
                local copy_src="$remote_artifact_path"
                if [[ ! -f "$copy_src" ]] && [[ "$copy_src" == *.exe ]]; then
                    local alt_src="${copy_src%.exe}"
                    if [[ -f "$alt_src" ]]; then
                        copy_src="$alt_src"
                        _log_info "Windows artifact lacks .exe suffix (Go -o output); using $alt_src"
                    fi
                fi
                if cp "$copy_src" "$this_artifact_path" 2>/dev/null; then
                    _log_ok "Artifact copied (local): $this_artifact_path"
                    if [[ -f "$this_artifact_path" ]]; then
                        local file_size
                        file_size=$(stat -f%z "$this_artifact_path" 2>/dev/null || stat -c%s "$this_artifact_path" 2>/dev/null || echo "unknown")
                        _log_info "Artifact size: $file_size bytes"
                    fi
                    local_artifact_paths+=("$this_artifact_path")
                else
                    _log_error "Failed to copy artifact $bin from local host ($copy_src)"
                    echo "Local cp failed for $bin: $copy_src" >> "$log_file"
                    download_failed=true
                fi
            elif scp_output=$(scp -o ConnectTimeout="$_ACT_SSH_TIMEOUT" \
                   -o StrictHostKeyChecking=accept-new \
                   "${ssh_destination}:${remote_artifact_path}" "$this_artifact_path" 2>&1); then
                _log_ok "Artifact downloaded: $this_artifact_path"
                # Log file size for verification
                if [[ -f "$this_artifact_path" ]]; then
                    local file_size
                    file_size=$(stat -f%z "$this_artifact_path" 2>/dev/null || stat -c%s "$this_artifact_path" 2>/dev/null || echo "unknown")
                    _log_info "Artifact size: $file_size bytes"
                fi
                local_artifact_paths+=("$this_artifact_path")
            else
                # Windows cross-compile fallback (symmetric with the local-host
                # branch above): `go build -o <name> ./cmd/x` does NOT append
                # `.exe` on any GOOS, so when act_get_remote_artifact_path
                # appends .exe unconditionally for windows/* and scp 404s on
                # the .exe form, retry once against the bare name. The local
                # dest keeps its .exe suffix so downstream packaging still
                # produces a conventional Windows bv.exe.
                local fallback_ok=false
                if [[ "$remote_artifact_path" == *.exe ]]; then
                    local alt_remote_artifact_path="${remote_artifact_path%.exe}"
                    local alt_scp_output
                    if alt_scp_output=$(scp -o ConnectTimeout="$_ACT_SSH_TIMEOUT" \
                           -o StrictHostKeyChecking=accept-new \
                           "${ssh_destination}:${alt_remote_artifact_path}" "$this_artifact_path" 2>&1); then
                        _log_ok "Artifact downloaded (fallback, no .exe): $this_artifact_path"
                        if [[ -f "$this_artifact_path" ]]; then
                            local file_size
                            file_size=$(stat -f%z "$this_artifact_path" 2>/dev/null || stat -c%s "$this_artifact_path" 2>/dev/null || echo "unknown")
                            _log_info "Artifact size: $file_size bytes"
                        fi
                        local_artifact_paths+=("$this_artifact_path")
                        fallback_ok=true
                    else
                        # Annotate the log with the fallback attempt for
                        # triageability; the primary error still wins the
                        # top-level "SCP error:" line.
                        echo "SCP fallback (no .exe) also failed for $bin: $alt_scp_output" >> "$log_file"
                    fi
                fi
                if ! $fallback_ok; then
                    _log_error "Failed to download artifact $bin from $host"
                    _log_error "SCP error: $scp_output"
                    echo "SCP failed for $bin: $scp_output" >> "$log_file"
                    download_failed=true
                fi
            fi
        done

        # Set final status and artifact path(s)
        if [[ "$download_failed" == true ]]; then
            if $strict_native_build || [[ ${#local_artifact_paths[@]} -eq 0 ]]; then
                status="failed"
                exit_code=7
            else
                # Partial success - some artifacts downloaded
                status="partial"
                _log_warn "Some artifacts failed to download"
            fi
        fi

        # Package workspace binaries into a single tarball
        if [[ -n "$workspace_binaries" && ${#local_artifact_paths[@]} -gt 0 && "$status" != "failed" ]]; then
            _log_info "Packaging ${#local_artifact_paths[@]} workspace binaries into release tarball..."

            # Determine archive format
            local archive_ext="tar.gz"
            if [[ "$platform" == windows/* ]]; then
                archive_ext="zip"
            fi

            # Parse platform for naming: linux/amd64 -> linux-amd64
            local plat_name="${platform//\//-}"
            # Use version parameter (strip leading 'v' if present)
            local version_stripped="${version#v}"

            # Validate version is not empty
            if [[ -z "$version_stripped" ]]; then
                _log_warn "Version is empty, using 'unknown' for archive name"
                version_stripped="unknown"
            fi

            local archive_name=""
            if ! declare -F artifact_naming_generate_dual_for_tool &>/dev/null; then
                local script_dir
                script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
                # shellcheck source=/dev/null
                source "$script_dir/artifact_naming.sh" 2>/dev/null || true
            fi

            if declare -F artifact_naming_generate_dual_for_tool &>/dev/null; then
                local os arch names_json
                os="${platform%/*}"
                arch="${platform#*/}"
                names_json=$(artifact_naming_generate_dual_for_tool "$tool_name" "$version" "$os" "$arch" "$archive_ext" "$local_path" 2>/dev/null || echo "")
                archive_name=$(echo "$names_json" | jq -r '.versioned // empty' 2>/dev/null)
            fi

            if [[ -z "$archive_name" ]]; then
                archive_name="${tool_name}-${version_stripped}-${plat_name}.${archive_ext}"
            fi
            local archive_path="$artifact_dir/$archive_name"

            # Get just the filenames for archive creation
            local archive_files=()
            for p in "${local_artifact_paths[@]}"; do
                archive_files+=("$(basename "$p")")
            done

            # Create the archive
            local archive_output
            if $strict_native_build; then
                local archive_receipt="" archive_mode=700
                [[ "$platform" == windows/* ]] && archive_mode=600
                if [[ "$archive_ext" == "zip" ]]; then
                    if command -v zip &>/dev/null; then
                        archive_receipt=$(_act_collect_stream_exclusive \
                            "$archive_path" "$archive_mode" \
                            _act_stream_workspace_zip "$artifact_dir" \
                            "${archive_files[@]}") || archive_receipt=""
                    fi
                else
                    archive_receipt=$(_act_collect_stream_exclusive \
                        "$archive_path" "$archive_mode" \
                        _act_stream_workspace_tar "$artifact_dir" \
                        "${archive_files[@]}") || archive_receipt=""
                fi
                if [[ -n "$archive_receipt" ]]; then
                    _log_ok "Created archive through held descriptor: $archive_path"
                    local_artifact_path="$archive_path"
                    local_artifact_paths=("$archive_path")
                    collected_sha256=$(jq -r '.sha256' <<< "$archive_receipt")
                    collected_size_bytes=$(jq -r '.size_bytes' <<< "$archive_receipt")
                    collected_identity=$(jq -r '.identity' <<< "$archive_receipt")
                else
                    _log_error "Strict workspace archive stream failed for $platform"
                    echo "Strict workspace archive creation failed" >> "$log_file"
                    status="failed"
                    exit_code=7
                    local_artifact_path=""
                    local_artifact_paths=()
                fi
            elif [[ "$archive_ext" == "zip" ]]; then
                # Windows: use zip
                if command -v zip &>/dev/null; then
                    archive_output=$(cd "$artifact_dir" && zip "$archive_name" "${archive_files[@]}" 2>&1)
                    if [[ -f "$archive_path" ]]; then
                        _log_ok "Created archive: $archive_path"
                        # Update artifact path to point to the archive
                        local_artifact_path="$archive_path"
                        local_artifact_paths=("$archive_path")
                    else
                        _log_warn "Failed to create zip archive"
                        _log_warn "zip output: $archive_output"
                        echo "Archive creation failed: $archive_output" >> "$log_file"
                        # Fall back to comma-separated paths
                        local_artifact_path=$(IFS=','; echo "${local_artifact_paths[*]}")
                    fi
                else
                    _log_warn "zip not available, skipping archive creation"
                    # Fall back to comma-separated paths
                    local_artifact_path=$(IFS=','; echo "${local_artifact_paths[*]}")
                fi
            else
                # Unix: use tar
                archive_output=$(cd "$artifact_dir" && tar czf "$archive_name" "${archive_files[@]}" 2>&1)
                if [[ -f "$archive_path" ]]; then
                    _log_ok "Created archive: $archive_path"
                    # Update artifact path to point to the archive
                    local_artifact_path="$archive_path"
                    local_artifact_paths=("$archive_path")
                else
                    _log_warn "Failed to create tar archive"
                    _log_warn "tar output: $archive_output"
                    echo "Archive creation failed: $archive_output" >> "$log_file"
                    # Fall back to comma-separated paths
                    local_artifact_path=$(IFS=','; echo "${local_artifact_paths[*]}")
                fi
            fi
        else
            # Join paths with comma for JSON output (single binary or no packaging needed)
            local_artifact_path=$(IFS=','; echo "${local_artifact_paths[*]}")
            if $strict_native_build && [[ ${#strict_collection_receipts[@]} -eq 1 && "$status" == "success" ]]; then
                collected_sha256=$(jq -r '.sha256' <<< "${strict_collection_receipts[0]}")
                collected_size_bytes=$(jq -r '.size_bytes' <<< "${strict_collection_receipts[0]}")
                collected_identity=$(jq -r '.identity' <<< "${strict_collection_receipts[0]}")
            fi
        fi

    elif [[ $exit_code -eq 124 ]]; then
        _log_error "Build timed out on $host after ${_ACT_BUILD_TIMEOUT}s"
        status="timeout"
        exit_code=5
    else
        _log_error "Build failed on $host with exit code $exit_code"
        status="failed"
        exit_code=6
    fi

    # Return JSON result (pointing to LOCAL artifact path)
    # Build artifact_paths array from comma-separated string
    local artifact_paths_json="[]"
    if [[ -n "${local_artifact_path:-}" ]]; then
        artifact_paths_json=$(echo "$local_artifact_path" | tr ',' '\n' | jq -R . | jq -sc .)
    fi

    jq -nc \
        --arg tool "$tool_name" \
        --arg platform "$platform" \
        --arg host "$host" \
        --arg status "$status" \
        --argjson exit_code "$exit_code" \
        --argjson duration "$duration" \
        --arg artifact_path "${local_artifact_path:-}" \
        --argjson artifact_paths "$artifact_paths_json" \
        --arg collected_sha256 "$collected_sha256" \
        --argjson collected_size_bytes "$collected_size_bytes" \
        --arg collected_identity "$collected_identity" \
        --argjson build_influence_env "$build_influence_env_json" \
        --arg log_file "$log_file" \
        '{
            tool: $tool,
            platform: $platform,
            host: $host,
            method: "native",
            status: $status,
            exit_code: $exit_code,
            duration_seconds: $duration,
            artifact_path: $artifact_path,
            artifact_paths: $artifact_paths,
            collected_sha256: (if $collected_sha256 == "" then null else $collected_sha256 end),
            collected_size_bytes: (if $collected_size_bytes == 0 then null else $collected_size_bytes end),
            collected_identity: (if $collected_identity == "" then null else $collected_identity end),
            build_influence_env: $build_influence_env,
            log_file: $log_file
        }'

    return "$exit_code"
}

# Main orchestration function: coordinate act + SSH builds
# Usage: act_orchestrate_build <tool_name> <version> [--git-sha SHA --git-ref TAG] [targets...]
# Returns: JSON with aggregated results
act_orchestrate_build() {
    local tool_name="$1"
    local version="$2"
    shift 2
    local targets_arg=()
    local supplied_git_sha="" supplied_git_ref=""
    local supplied_run_id="" source_roots_json="{}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --git-sha)
                [[ $# -ge 2 ]] || { _log_error "--git-sha requires a value"; return 4; }
                supplied_git_sha="$2"
                shift 2
                ;;
            --git-ref)
                [[ $# -ge 2 ]] || { _log_error "--git-ref requires a value"; return 4; }
                supplied_git_ref="$2"
                shift 2
                ;;
            --run-id)
                [[ $# -ge 2 ]] || { _log_error "--run-id requires a value"; return 4; }
                supplied_run_id="$2"
                shift 2
                ;;
            --source-roots-json)
                [[ $# -ge 2 ]] || { _log_error "--source-roots-json requires a value"; return 4; }
                source_roots_json="$2"
                shift 2
                ;;
            --)
                shift
                targets_arg+=("$@")
                break
                ;;
            --*)
                _log_error "Unknown orchestration option: $1"
                return 4
                ;;
            *)
                targets_arg+=("$1")
                shift
                ;;
        esac
    done

    # Load config
    if ! act_load_repo_config "$tool_name"; then
        _log_error "Failed to load config for $tool_name"
        jq -nc --arg tool "$tool_name" --arg error "Failed to load config" \
            '{tool: $tool, status: "error", summary: {total: 0, success: 0, failed: 0}, error: $error, targets: []}'
        return 4
    fi

    local release_contract_json="null"
    if ! release_contract_json=$(_act_release_contract_json "$tool_name"); then
        jq -nc --arg tool "$tool_name" --arg error "Invalid release contract" \
            '{tool: $tool, status: "error", summary: {total: 0, success: 0, failed: 0}, error: $error, targets: []}'
        return 4
    fi

    local strict_release_contract=false
    [[ "$release_contract_json" != "null" ]] && strict_release_contract=true

    # Get targets (from args or config)
    local targets
    if [[ ${#targets_arg[@]} -gt 0 ]]; then
        targets="${targets_arg[*]}"
    else
        targets=$(act_get_targets "$tool_name")
    fi

    if [[ -z "$targets" ]]; then
        _log_error "No targets configured for $tool_name"
        jq -nc --arg tool "$tool_name" --arg error "No targets configured" \
            '{tool: $tool, status: "error", summary: {total: 0, success: 0, failed: 0}, error: $error, targets: []}'
        return 4
    fi

    if $strict_release_contract; then
        local requested_targets_json requested_target
        requested_targets_json=$(for requested_target in $targets; do printf '%s\n' "$requested_target"; done | \
            jq -Rsc 'split("\n") | map(select(length > 0))')
        if ! jq -en \
            --argjson contract "$release_contract_json" \
            --argjson requested "$requested_targets_json" '
                ($requested | length) == ($requested | unique | length) and
                ($requested | sort) == ($contract.exact_primary_assets | keys | sort)
            ' >/dev/null 2>&1; then
            _log_error "Strict release contract requires the exact configured target set"
            jq -nc --arg tool "$tool_name" --arg error "Release target set does not match contract" \
                '{tool: $tool, status: "error", summary: {total: 0, success: 0, failed: 0}, error: $error, targets: []}'
            return 4
        fi

        local strict_target
        for strict_target in $targets; do
            if act_platform_uses_act "$tool_name" "$strict_target"; then
                _log_error "Strict release target $strict_target cannot use act"
                jq -nc --arg tool "$tool_name" --arg error "Strict release targets must use native builds" \
                    '{tool: $tool, status: "error", summary: {total: 0, success: 0, failed: 0}, error: $error, targets: []}'
                return 4
            fi
        done
    fi

    _log_info "Orchestrating build for $tool_name $version"
    _log_info "Targets: $targets"

    # Bind strict releases to the exact caller-supplied HEAD/tag identity.
    local git_sha="" git_ref="" source_dependencies_json="[]"
    local source_dependency_checkouts_json="[]"
    if $strict_release_contract; then
        if [[ -z "$supplied_git_sha" || -z "$supplied_git_ref" ]] || \
           ! _act_validate_contract_source_identity \
                "$version" "$supplied_git_sha" "$supplied_git_ref" "$tool_name" || \
           ! source_dependencies_json=$(_act_release_source_dependencies_json "$tool_name") || \
           ! source_dependency_checkouts_json=$(_act_release_source_dependency_checkouts_json "$tool_name"); then
            jq -nc --arg tool "$tool_name" --arg error "Invalid or missing release source identity" \
                '{tool: $tool, status: "error", summary: {total: 0, success: 0, failed: 0}, error: $error, targets: []}'
            return 4
        fi
        git_sha="$supplied_git_sha"
        git_ref="$supplied_git_ref"

        local expected_native_hosts_json actual_source_hosts_json target_host
        expected_native_hosts_json=$(for target in $targets; do
            if act_platform_uses_act "$tool_name" "$target"; then
                printf 'act\n'
            else
                target_host=$(act_get_native_host "$target" "$tool_name")
                [[ -n "$target_host" ]] && printf '%s\n' "$target_host"
            fi
        done | jq -Rsc 'split("\n") | map(select(length > 0)) | unique | sort')
        if ! _act_is_uuid "$supplied_run_id" || \
           ! actual_source_hosts_json=$(jq -c 'if type == "object" and all(.[]; type == "string" and length > 0) then keys | sort else error("invalid source roots") end' \
                <<< "$source_roots_json" 2>/dev/null) || \
           ! jq -en --argjson expected "$expected_native_hosts_json" --argjson actual "$actual_source_hosts_json" \
                '$expected == $actual' >/dev/null 2>&1; then
            jq -nc --arg tool "$tool_name" --arg error "Invalid or incomplete strict source roots" \
                '{tool: $tool, status: "error", summary: {total: 0, success: 0, failed: 0}, error: $error, targets: []}'
            return 4
        fi

        local source_host configured_host_path expected_source_root actual_source_root
        while IFS= read -r source_host; do
            [[ -n "$source_host" ]] || continue
            configured_host_path=""
            if [[ "$source_host" != "act" ]]; then
                configured_host_path=$(yq -r '.host_paths.'"$source_host"' // ""' \
                    "$ACT_REPOS_DIR/${tool_name}.yaml" 2>/dev/null)
            fi
            [[ -n "$configured_host_path" ]] || configured_host_path="$ACT_REPO_LOCAL_PATH"
            if ! expected_source_root=$(_act_strict_source_root_path \
                "$configured_host_path" "$tool_name" "$supplied_run_id"); then
                jq -nc --arg tool "$tool_name" --arg error "Invalid canonical strict source root" \
                    '{tool: $tool, status: "error", summary: {total: 0, success: 0, failed: 0}, error: $error, targets: []}'
                return 4
            fi
            actual_source_root=$(jq -r --arg host "$source_host" '.[$host]' <<< "$source_roots_json")
            if [[ "$actual_source_root" != "$expected_source_root" ]]; then
                _log_error "Strict source root for $source_host is not the canonical fresh path"
                jq -nc --arg tool "$tool_name" --arg error "Noncanonical strict source root" \
                    '{tool: $tool, status: "error", summary: {total: 0, success: 0, failed: 0}, error: $error, targets: []}'
                return 4
            fi
            if [[ "$ACT_REPO_LANGUAGE" == "rust" ]] && \
               ! _act_validate_strict_cargo_source_closure \
                    "$source_host" "$actual_source_root" "$source_dependency_checkouts_json"; then
                _log_error "Strict Cargo source closure validation failed on $source_host"
                jq -nc --arg tool "$tool_name" --arg error "Cargo source closure does not match pinned dependencies" \
                    '{tool: $tool, status: "error", summary: {total: 0, success: 0, failed: 0}, error: $error, targets: []}'
                return 4
            fi
        done < <(jq -r '.[]' <<< "$expected_native_hosts_json")
    else
        git_sha="$supplied_git_sha"
        git_ref="$supplied_git_ref"
        if command -v git &>/dev/null && [[ -n "${ACT_REPO_LOCAL_PATH:-}" ]]; then
            [[ -n "$git_sha" ]] || git_sha=$(git -C "$ACT_REPO_LOCAL_PATH" rev-parse HEAD 2>/dev/null || true)
            if [[ -z "$git_ref" ]]; then
                git_ref=$(git -C "$ACT_REPO_LOCAL_PATH" symbolic-ref -q --short HEAD 2>/dev/null || true)
                if [[ -z "$git_ref" || "$git_ref" == "HEAD" ]]; then
                    git_ref=$(git -C "$ACT_REPO_LOCAL_PATH" describe --tags --exact-match 2>/dev/null || true)
                fi
            fi
        fi
        [[ -z "$git_ref" ]] && git_ref="v${version#v}"
    fi

    # Initialize build state (if build_state.sh is sourced)
    local run_id requested_run_id="${supplied_run_id:-${DSR_RUN_ID:-}}"
    local lock_acquired_here=false
    local caller_holds_lock=false
    [[ "${DSR_BUILD_LOCK_HELD_BY_CALLER:-0}" == "1" ]] && caller_holds_lock=true

    if ! _act_is_uuid "$requested_run_id"; then
        if ! requested_run_id=$(_act_generate_uuid); then
            _log_error "Unable to generate a schema-valid build run UUID"
            jq -nc --arg tool "$tool_name" --arg error "Unable to generate build run UUID" \
                '{tool: $tool, status: "error", summary: {total: 0, success: 0, failed: 0}, error: $error, targets: []}'
            return 4
        fi
    fi

    if command -v build_state_create &>/dev/null; then
        if $caller_holds_lock; then
            _log_info "Using caller-owned build lock for $tool_name $version"
        else
            if ! DSR_RUN_ID="$requested_run_id" build_lock_acquire "$tool_name" "$version"; then
                _log_error "Build already in progress (lock held)"
                jq -nc --arg tool "$tool_name" --arg error "Build already in progress (lock held)" \
                    '{tool: $tool, status: "error", summary: {total: 0, success: 0, failed: 0}, error: $error, targets: []}'
                return 2
            fi
            lock_acquired_here=true
        fi
        if ! run_id=$(DSR_RUN_ID="$requested_run_id" \
            build_state_create "$tool_name" "$version" "${targets// /,}") || \
           [[ "$run_id" != "$requested_run_id" ]] || ! _act_is_uuid "$run_id"; then
            _log_error "Build state did not retain the schema-valid run UUID"
            $lock_acquired_here && build_lock_release "$tool_name" "$version"
            jq -nc --arg tool "$tool_name" --arg error "Invalid build state run UUID" \
                '{tool: $tool, status: "error", summary: {total: 0, success: 0, failed: 0}, error: $error, targets: []}'
            return 4
        fi
        build_state_update_status "$tool_name" "$version" "running" "$run_id"
    else
        run_id="$requested_run_id"
    fi

    _log_info "Run ID: $run_id"

    # Track results
    local results=()
    local success_count=0
    local fail_count=0
    local start_time
    start_time=$(date +%s)

    # Process each target
    for target in $targets; do
        _log_info "--- Building target: $target ---"

        # Update host status
        local host
        host=$(act_get_native_host "$target" "$tool_name")
        if command -v build_state_update_host &>/dev/null; then
            build_state_update_host "$tool_name" "$version" "$host" "running" '{"target":"'"$target"'"}' "$run_id"
        fi

        # Determine build method
        local result exit_code=0
        if act_platform_uses_act "$tool_name" "$target"; then
            # Run via act
            local job workflow local_path extra_flags
            job=$(act_get_job_for_target "$tool_name" "$target")
            workflow="$ACT_REPO_WORKFLOW"
            local_path="$ACT_REPO_LOCAL_PATH"
            if $strict_release_contract; then
                local_path=$(jq -r '.act // empty' <<< "$source_roots_json")
            fi
            extra_flags=$(act_get_flags "$tool_name" "$target")

            _log_info "Method: act (job=$job)"

            # Collect extra args
            local act_args=()
            [[ -n "$extra_flags" ]] && read -ra act_args <<< "$extra_flags"

            # Run act workflow with version for tag context injection
            local full_output
            full_output=$(act_run_workflow "$local_path" "$workflow" "$job" "push" "$version" "${act_args[@]}" 2>&1) || exit_code=$?

            # Extract JSON from mixed output (act logs + JSON at end)
            # jq -nc outputs single-line compact JSON, so match lines that start with { and end with }
            result=$(echo "$full_output" | grep '^{.*}$' | tail -1)

            # Fallback if no JSON found
            if [[ -z "$result" ]] || ! echo "$result" | jq -e '.' &>/dev/null; then
                _log_warn "Could not parse JSON from act output, creating status from exit code"
                local fallback_status="failed"
                [[ "$exit_code" -eq 0 ]] && fallback_status="success"
                result=$(jq -nc --arg status "$fallback_status" --argjson exit_code "$exit_code" \
                    '{status: $status, exit_code: $exit_code}')
            fi

            # Wrap in consistent format
            result=$(echo "$result" | jq --arg target "$target" --arg method "act" \
                '. + {platform: $target, method: $method}' 2>/dev/null || echo "$result")
        else
            # Run via SSH (native build)
            _log_info "Method: native (host=$host)"
            local full_native_output remote_path_override=""
            if $strict_release_contract; then
                remote_path_override=$(jq -r --arg host "$host" '.[$host] // empty' <<< "$source_roots_json")
            fi
            full_native_output=$(act_run_native_build \
                "$tool_name" "$target" "$version" "$run_id" "$remote_path_override") || exit_code=$?
            # Extract JSON from output (native build includes build output + JSON at end)
            result=$(echo "$full_native_output" | grep '^{' | tail -1)
            if [[ -z "$result" ]] || ! echo "$result" | jq -e '.' &>/dev/null; then
                _log_warn "Could not parse JSON from native build output"
                local fallback_status="failed"
                [[ "$exit_code" -eq 0 ]] && fallback_status="success"
                result=$(jq -nc --arg status "$fallback_status" --argjson exit_code "$exit_code" \
                    --arg platform "$target" --arg method "native" \
                    '{status: $status, exit_code: $exit_code, platform: $platform, method: $method}')
            fi
        fi

        if $strict_release_contract; then
            local result_status staged_result
            result_status=$(jq -r '.status // "unknown"' <<< "$result")
            if [[ "$result_status" == "success" ]]; then
                if staged_result=$(_act_stage_contract_primary \
                    "$tool_name" "$version" "$run_id" "$target" "$result" "$release_contract_json"); then
                    result="$staged_result"
                else
                    exit_code=4
                    result=$(jq -c \
                        '.status = "failed" | .exit_code = 4 | .error = "Release primary staging failed"' \
                        <<< "$result")
                fi
            fi
        fi

        # Update result tracking
        results+=("$result")

        local status
        status=$(echo "$result" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")

        if [[ "$status" == "success" ]]; then
            ((success_count++))
            if command -v build_state_update_host &>/dev/null; then
                build_state_update_host "$tool_name" "$version" "$host" "completed" \
                    "$(echo "$result" | jq -c '{artifact_path, duration_seconds}' 2>/dev/null || echo '{}')" "$run_id"
            fi
        else
            ((fail_count++))
            if command -v build_state_update_host &>/dev/null; then
                build_state_update_host "$tool_name" "$version" "$host" "failed" \
                    "$(echo "$result" | jq -c '{exit_code, error: .error // .status}' 2>/dev/null || echo '{}')" "$run_id"
            fi
        fi

        _log_info "Result: $status (exit_code=$exit_code)"
    done

    local end_time total_duration
    end_time=$(date +%s)
    total_duration=$((end_time - start_time))

    local source_validation_failed=false
    if $strict_release_contract && \
       ! _act_validate_contract_source_identity \
            "$version" "$git_sha" "$git_ref" "$tool_name"; then
        source_validation_failed=true
    fi
    if $strict_release_contract && ! $source_validation_failed && \
       ! _act_verify_strict_source_roots \
            "$tool_name" "$git_sha" "$source_roots_json"; then
        source_validation_failed=true
    fi

    # Determine overall status
    local overall_status overall_exit_code
    if $source_validation_failed; then
        overall_status="failed"
        overall_exit_code=4
    elif [[ $fail_count -eq 0 ]]; then
        overall_status="success"
        overall_exit_code=0
    elif [[ $success_count -gt 0 ]]; then
        overall_status="partial"
        overall_exit_code=1
    else
        overall_status="failed"
        overall_exit_code=6
    fi

    # Update build state
    if command -v build_state_update_status &>/dev/null; then
        build_state_update_status "$tool_name" "$version" "$overall_status" "$run_id"
        if $lock_acquired_here; then
            build_lock_release "$tool_name" "$version"
        fi
    fi

    _log_info "=== Build orchestration complete ==="
    _log_info "Status: $overall_status (success=$success_count, failed=$fail_count)"
    _log_info "Duration: ${total_duration}s"

    # Return aggregated JSON result
    local results_json
    if [[ ${#results[@]} -eq 0 ]]; then
        results_json="[]"
    else
        results_json=$(printf '%s\n' "${results[@]}" | jq -s '.' 2>/dev/null || echo '[]')
    fi

    jq -nc \
        --arg tool "$tool_name" \
        --arg version "$version" \
        --arg run_id "$run_id" \
        --arg git_sha "$git_sha" \
        --arg git_ref "$git_ref" \
        --argjson source_dependencies "$source_dependencies_json" \
        --arg status "$overall_status" \
        --argjson exit_code "$overall_exit_code" \
        --argjson duration "$total_duration" \
        --argjson total "$((success_count + fail_count))" \
        --argjson success "$success_count" \
        --argjson failed "$fail_count" \
        --argjson targets "$results_json" \
        '{
            tool: $tool,
            version: $version,
            run_id: $run_id,
            git_sha: $git_sha,
            git_ref: $git_ref,
            source_dependencies: $source_dependencies,
            status: $status,
            exit_code: $exit_code,
            duration_seconds: $duration,
            summary: {
                total: $total,
                success: $success,
                failed: $failed
            },
            targets: $targets
        }'

    return "$overall_exit_code"
}

_act_generate_contract_manifest() {
    local result_json="$1"
    local output_file="$2"
    local contract_json="$3"

    if ! jq -e 'type == "object"' <<< "$result_json" >/dev/null 2>&1; then
        _log_error "Cannot generate manifest from invalid orchestration JSON"
        return 4
    fi

    local tool version run_id git_sha git_ref status
    tool=$(jq -r '.tool // empty' <<< "$result_json")
    version=$(jq -r '.version // empty' <<< "$result_json")
    run_id=$(jq -r '.run_id // empty' <<< "$result_json")
    git_sha=$(jq -r '.git_sha // empty' <<< "$result_json")
    git_ref=$(jq -r '.git_ref // empty' <<< "$result_json")
    status=$(jq -r '.status // empty' <<< "$result_json")

    local source_dependencies_json
    if ! _act_is_uuid "$run_id"; then
        _log_error "Strict release manifest requires a schema-valid run UUID"
        return 4
    fi
    if ! _act_validate_contract_source_identity "$version" "$git_sha" "$git_ref" "$tool"; then
        _log_error "Manifest source identity is not bound to HEAD and $git_ref"
        return 4
    fi
    if ! source_dependencies_json=$(_act_release_source_dependencies_json "$tool") || \
       ! jq -e --argjson dependencies "$source_dependencies_json" \
            '.source_dependencies == $dependencies' <<< "$result_json" >/dev/null 2>&1; then
        _log_error "Manifest source dependencies do not match the orchestrated pinned checkouts"
        return 4
    fi

    local expected_count
    expected_count=$(jq -r '.exact_primary_assets | length' <<< "$contract_json")
    if [[ ! "$expected_count" =~ ^[1-9][0-9]*$ ]]; then
        _log_error "Release contract has no primary assets"
        return 4
    fi

    if ! jq -e --argjson contract "$contract_json" '
        ($contract.exact_primary_assets | keys) as $expected_targets |
        .status == "success" and
        (.summary | type == "object") and
        .summary.total == ($expected_targets | length) and
        .summary.success == ($expected_targets | length) and
        .summary.failed == 0 and
        (.targets | type == "array") and
        (.targets | length) == ($expected_targets | length) and
        ([.targets[].platform] | length) == ([.targets[].platform] | unique | length) and
        ([.targets[].platform] | sort) == ($expected_targets | sort) and
        all(.targets[];
            .status == "success" and
            (.staged_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
            (.staged_size_bytes | type == "number" and . > 0 and floor == .) and
            (.staged_identity | type == "string" and test("^(gnu:[0-9]+:[1-9][0-9]*|bsd:[1-9][0-9]*)$"))
        )
    ' <<< "$result_json" >/dev/null 2>&1; then
        _log_error "Release contract requires exact N/N successful target results"
        return 4
    fi

    if ! jq -e '
        .checksum_sidecar == "sha256" and
        (.exact_primary_assets | type == "object") and
        ([.exact_primary_assets[]] | length) == ([.exact_primary_assets[]] | unique | length)
    ' <<< "$contract_json" >/dev/null 2>&1; then
        _log_error "Release contract primary asset mapping is invalid"
        return 4
    fi

    local artifacts=()
    local target expected_name target_json artifact_path artifact_dir
    local frozen_sha frozen_size frozen_identity
    while IFS= read -r target; do
        [[ -n "$target" ]] || continue
        expected_name=$(jq -r --arg target "$target" '.exact_primary_assets[$target]' <<< "$contract_json")
        if ! _act_is_safe_basename "$expected_name"; then
            _log_error "Unsafe release asset basename for $target: $expected_name"
            return 4
        fi

        target_json=$(jq -c --arg target "$target" '.targets[] | select(.platform == $target)' <<< "$result_json")
        artifact_path=$(jq -r '.artifact_path // empty' <<< "$target_json")
        artifact_dir=$(jq -r '.artifact_dir // empty' <<< "$target_json")
        frozen_sha=$(jq -r '.staged_sha256 // empty' <<< "$target_json")
        frozen_size=$(jq -r '.staged_size_bytes // empty' <<< "$target_json")
        frozen_identity=$(jq -r '.staged_identity // empty' <<< "$target_json")
        if [[ ! "$frozen_sha" =~ ^[0-9a-f]{64}$ || \
              ! "$frozen_size" =~ ^[1-9][0-9]*$ || \
              ! "$frozen_identity" =~ ^(gnu:[0-9]+:[1-9][0-9]*|bsd:[1-9][0-9]*)$ ]]; then
            _log_error "Release target $target is missing its frozen staged identity"
            return 4
        fi

        local candidate_paths=()
        local candidate
        if [[ -n "$artifact_path" ]]; then
            while IFS= read -r candidate; do
                [[ -n "$candidate" ]] && candidate_paths+=("$candidate")
            done < <(printf '%s\n' "$artifact_path" | tr ',' '\n')
        fi
        while IFS= read -r candidate; do
            [[ -n "$candidate" ]] && candidate_paths+=("$candidate")
        done < <(jq -r '.artifact_paths[]? // empty' <<< "$target_json")

        if [[ ${#candidate_paths[@]} -eq 0 && -n "$artifact_dir" ]]; then
            if [[ ! -d "$artifact_dir" ]]; then
                _log_error "Artifact directory for $target does not exist: $artifact_dir"
                return 4
            fi
            while IFS= read -r -d '' candidate; do
                candidate_paths+=("$candidate")
            done < <(find "$artifact_dir" \( -type f -o -type l \) -name "$expected_name" -print0 2>/dev/null)
        fi

        local -A seen_candidate_paths=()
        local primary_path=""
        local primary_count=0
        local sidecar_count=0
        local candidate_name configured_target
        for candidate in "${candidate_paths[@]}"; do
            [[ -n "${seen_candidate_paths[$candidate]:-}" ]] && continue
            seen_candidate_paths["$candidate"]=1

            if [[ -L "$candidate" ]]; then
                _log_error "Release artifact must not be a symlink: $candidate"
                return 4
            fi
            if [[ ! -f "$candidate" ]]; then
                _log_error "Release artifact is missing or not a regular file: $candidate"
                return 4
            fi

            candidate_name=$(basename "$candidate")
            if [[ "$candidate_name" == "$expected_name" ]]; then
                primary_path="$candidate"
                ((primary_count++))
            elif [[ "$candidate_name" == "${expected_name}.sha256" ]]; then
                ((sidecar_count++))
            else
                configured_target=$(jq -r --arg name "$candidate_name" '
                    .exact_primary_assets | to_entries[] | select(.value == $name) | .key
                ' <<< "$contract_json")
                if [[ -n "$configured_target" ]]; then
                    _log_error "Release artifact $candidate_name belongs to $configured_target, not $target"
                else
                    _log_error "Unexpected release artifact for $target: $candidate_name"
                fi
                return 4
            fi
        done

        if [[ $primary_count -ne 1 ]]; then
            _log_error "Release target $target requires exactly one $expected_name (found $primary_count)"
            return 4
        fi
        if [[ $sidecar_count -gt 1 ]]; then
            _log_error "Release target $target has duplicate checksum sidecars for $expected_name"
            return 4
        fi

        local identity_before identity_after
        if ! identity_before=$(_act_file_identity "$primary_path") || \
           [[ "$identity_before" != "$frozen_identity" ]] || \
           ! _act_validate_target_binary "$primary_path" "$target"; then
            return 4
        fi

        local sha size format artifact_json
        if ! sha=$(_act_sha256 "$primary_path") || [[ ! "$sha" =~ ^[a-f0-9]{64}$ ]]; then
            _log_error "Unable to compute SHA256 for release artifact: $primary_path"
            return 4
        fi
        size=$(_act_file_size "$primary_path")
        if [[ ! "$size" =~ ^[1-9][0-9]*$ ]]; then
            _log_error "Unable to determine release artifact size: $primary_path"
            return 4
        fi
        if ! identity_after=$(_act_file_identity "$primary_path") || \
           [[ ! -f "$primary_path" || -L "$primary_path" ]] || \
           [[ "$identity_after" != "$identity_before" ]] || \
           [[ "$identity_after" != "$frozen_identity" ]] || \
           [[ "$sha" != "$frozen_sha" || "$size" != "$frozen_size" ]]; then
            _log_error "Release artifact changed after strict staging: $primary_path"
            return 4
        fi
        format=$(_act_archive_format "$expected_name")
        [[ "$format" == "none" ]] && format="binary"

        if ! artifact_json=$(jq -nc \
            --arg name "$expected_name" \
            --arg target "$target" \
            --arg sha "$sha" \
            --argjson size "$size" \
            --arg format "$format" \
            '{
                name: $name,
                target: $target,
                sha256: $sha,
                size_bytes: $size,
                archive_format: $format,
                signed: false,
                signature_file: ""
            }'); then
            _log_error "Failed to serialize release artifact metadata for $target"
            return 4
        fi
        artifacts+=("$artifact_json")
    done < <(jq -r '.exact_primary_assets | keys[]' <<< "$contract_json")

    if [[ ${#artifacts[@]} -ne $expected_count ]]; then
        _log_error "Manifest artifact count does not match release contract"
        return 4
    fi

    local artifacts_json summary_json manifest_version built_at duration_seconds duration_ms manifest
    artifacts_json=$(printf '%s\n' "${artifacts[@]}" | jq -s '.') || return 4
    summary_json=$(jq -c '.summary' <<< "$result_json") || return 4
    manifest_version="v${version#v}"
    built_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    duration_seconds=$(jq -r '.duration_seconds // 0' <<< "$result_json")
    [[ "$duration_seconds" =~ ^[0-9]+$ ]] || duration_seconds=0
    duration_ms=$((duration_seconds * 1000))

    if ! manifest=$(jq -nc \
        --arg tool "$tool" \
        --arg version "$manifest_version" \
        --arg run_id "$run_id" \
        --arg git_sha "$git_sha" \
        --arg git_ref "$git_ref" \
        --argjson source_dependencies "$source_dependencies_json" \
        --arg built_at "$built_at" \
        --argjson duration_ms "$duration_ms" \
        --arg status "$status" \
        --argjson summary "$summary_json" \
        --argjson artifacts "$artifacts_json" \
        '{
            schema_version: "1.0.0",
            tool: $tool,
            version: $version,
            run_id: $run_id,
            source: {git_sha: $git_sha, git_ref: $git_ref, dependencies: $source_dependencies},
            built_at: $built_at,
            duration_ms: $duration_ms,
            status: $status,
            summary: $summary,
            artifacts: $artifacts
        }'); then
        _log_error "Failed to serialize release manifest"
        return 4
    fi

    if ! jq -e --argjson contract "$contract_json" '
        (.artifacts | length) == ($contract.exact_primary_assets | length) and
        all(.artifacts[]; $contract.exact_primary_assets[.target] == .name) and
        ([.artifacts[].target] | length) == ([.artifacts[].target] | unique | length)
    ' <<< "$manifest" >/dev/null 2>&1; then
        _log_error "Final manifest does not match the release contract"
        return 4
    fi

    if [[ -n "$output_file" ]]; then
        if [[ -e "$output_file" || -L "$output_file" ]] || \
           ! (umask 077; set -o noclobber; printf '%s\n' "$manifest" > "$output_file") || \
           [[ ! -f "$output_file" || -L "$output_file" ]]; then
            _log_error "Failed to create strict manifest without clobbering: $output_file"
            return 4
        fi
        _log_info "Manifest written to: $output_file"
    else
        printf '%s\n' "$manifest"
    fi
}

# Generate build manifest from orchestration results
# Usage: act_generate_manifest <orchestration_result_json> <output_file>
act_generate_manifest() {
    local result_json="$1"
    local output_file="$2"

    if ! jq -e 'type == "object"' <<< "$result_json" >/dev/null 2>&1; then
        _log_error "Cannot generate manifest from invalid orchestration JSON"
        return 4
    fi

    local tool version run_id status
    tool=$(jq -r '.tool // empty' <<< "$result_json")
    version=$(jq -r '.version // empty' <<< "$result_json")
    run_id=$(jq -r '.run_id // empty' <<< "$result_json")
    status=$(jq -r '.status // empty' <<< "$result_json")

    local release_contract_json="null"
    if ! release_contract_json=$(_act_release_contract_json "$tool"); then
        return 4
    fi
    if [[ "$release_contract_json" != "null" ]]; then
        _act_generate_contract_manifest "$result_json" "$output_file" "$release_contract_json"
        return $?
    fi
    if ! _act_is_uuid "$run_id"; then
        _log_error "Manifest requires a schema-valid run UUID"
        return 4
    fi

    local manifest_version
    manifest_version="v${version#v}"

    local git_sha git_ref
    git_sha=$(jq -r '.git_sha // empty' <<< "$result_json" 2>/dev/null)
    git_ref=$(jq -r '.git_ref // empty' <<< "$result_json" 2>/dev/null)

    if [[ -z "$git_sha" || "$git_sha" == "null" ]]; then
        if command -v git &>/dev/null && [[ -n "${ACT_REPO_LOCAL_PATH:-}" && -d "$ACT_REPO_LOCAL_PATH/.git" ]]; then
            git_sha=$(git -C "$ACT_REPO_LOCAL_PATH" rev-parse HEAD 2>/dev/null || true)
        fi
    fi
    if [[ ! "$git_sha" =~ ^[0-9a-f]{40}$ || "$git_sha" =~ ^0{40}$ ]]; then
        _log_error "Manifest requires a nonzero 40-hex git SHA"
        return 4
    fi

    if [[ -z "$git_ref" || "$git_ref" == "null" ]]; then
        if command -v git &>/dev/null && [[ -n "${ACT_REPO_LOCAL_PATH:-}" && -d "$ACT_REPO_LOCAL_PATH/.git" ]]; then
            git_ref=$(git -C "$ACT_REPO_LOCAL_PATH" symbolic-ref -q --short HEAD 2>/dev/null || true)
            if [[ -z "$git_ref" || "$git_ref" == "HEAD" ]]; then
                git_ref=$(git -C "$ACT_REPO_LOCAL_PATH" describe --tags --exact-match 2>/dev/null || true)
            fi
        fi
    fi
    [[ -z "$git_ref" || "$git_ref" == "null" ]] && git_ref="$manifest_version"

    local summary_json
    if ! summary_json=$(jq -ce '
        .summary |
        select(type == "object") |
        select((.total | type) == "number") |
        select((.success | type) == "number") |
        select((.failed | type) == "number")
    ' <<< "$result_json"); then
        _log_error "Manifest requires orchestration summary counts"
        return 4
    fi
    if [[ ! "$status" =~ ^(success|partial|failed)$ ]]; then
        _log_error "Manifest has invalid orchestration status: $status"
        return 4
    fi

    local built_at
    built_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    local duration_seconds duration_ms
    duration_seconds=$(echo "$result_json" | jq -r '.duration_seconds // 0' 2>/dev/null || echo 0)
    [[ "$duration_seconds" =~ ^[0-9]+$ ]] || duration_seconds=0
    duration_ms=$((duration_seconds * 1000))

    local artifacts=()
    local seen_paths=()
    local -A seen_names=()

    # Map a filename's embedded platform suffix to a canonical "<os>/<arch>"
    # target. Returns empty if no recognizable suffix is present. Used to
    # override the orchestration-step target when matrix workflows produce
    # cross-platform artifacts under a single act job (e.g. release.yml that
    # builds linux/darwin/windows from the "build-release" job).
    #
    # musl variants are mapped to plain "linux/<arch>" — the libc choice is a
    # filename detail (e.g. linux_musl_amd64), not a separate dsr target.
    _act_infer_target_from_name() {
        local nm="$1"
        local os="" arch=""
        case "$nm" in
            *darwin*)        os="darwin" ;;
            *linux*)         os="linux" ;;
            *windows*|*.exe) os="windows" ;;
        esac
        case "$nm" in
            *_aarch64*|*-aarch64*|*_arm64*|*-arm64*) arch="arm64" ;;
            *_x86_64*|*-x86_64*|*_amd64*|*-amd64*)   arch="amd64" ;;
        esac
        [[ -n "$os" && -n "$arch" ]] && printf '%s/%s\n' "$os" "$arch"
    }

    _act_manifest_add_file() {
        local file="$1"
        local target="$2"

        [[ -z "$file" || ! -f "$file" ]] && return 0
        [[ -z "$target" ]] && return 0

        local name
        name=$(basename "$file")

        case "$name" in
            *.minisig|*.sig|*.sha256|*.sha512|SHA256SUMS*|*.sbom.*|*.intoto.jsonl)
                return 0
                ;;
        esac

        # Skip exact-path duplicates AND name-collision duplicates. Without
        # the name dedup the manifest gets one entry per orchestration target
        # iteration when multiple targets share an artifact_dir or when a
        # matrix workflow emits a full set of cross-platform tarballs under
        # one act job — producing duplicate `name` entries with conflicting
        # `target` and `sha256`, which cascades into a corrupt SHA256SUMS.
        for seen in "${seen_paths[@]}"; do
            [[ "$seen" == "$file" ]] && return 0
        done
        if [[ -n "${seen_names[$name]:-}" ]]; then
            return 0
        fi

        local sha size format
        sha=$(_act_sha256 "$file" 2>/dev/null || echo "")
        size=$(_act_file_size "$file")
        format=$(_act_archive_format "$name")

        if [[ -z "$sha" ]]; then
            _log_warn "Unable to compute SHA256 for artifact: $file"
            return 0
        fi
        if [[ -z "$size" || "$size" -le 0 ]]; then
            _log_warn "Unable to determine size for artifact: $file"
            return 0
        fi

        # If the filename embeds a recognizable platform suffix, trust it
        # over the orchestration-step target — the latter is unreliable when
        # matrix workflows produce cross-platform artifacts under a single
        # act job.
        local inferred_target
        inferred_target=$(_act_infer_target_from_name "$name")
        if [[ -n "$inferred_target" ]]; then
            target="$inferred_target"
        fi

        local sig_file=""
        local signed=false
        if [[ -f "${file}.minisig" ]]; then
            signed=true
            sig_file=$(basename "${file}.minisig")
        fi

        local artifact_json
        artifact_json=$(jq -nc \
            --arg name "$name" \
            --arg target "$target" \
            --arg sha "$sha" \
            --argjson size "$size" \
            --arg format "$format" \
            --argjson signed "$signed" \
            --arg sig "$sig_file" \
            '{
                name: $name,
                target: $target,
                sha256: $sha,
                size_bytes: $size,
                archive_format: $format,
                signed: $signed,
                signature_file: $sig
            }')

        artifacts+=("$artifact_json")
        seen_paths+=("$file")
        seen_names["$name"]=1
    }

    _act_sha256_zip_entry() {
        local zip_file="$1"
        local entry="$2"

        if command -v sha256sum &>/dev/null; then
            unzip -p "$zip_file" "$entry" 2>/dev/null | sha256sum | awk '{print $1}'
            return 0
        fi

        if command -v shasum &>/dev/null; then
            unzip -p "$zip_file" "$entry" 2>/dev/null | shasum -a 256 | awk '{print $1}'
            return 0
        fi

        return 3
    }

    _act_zip_entry_size() {
        local zip_file="$1"
        local entry="$2"
        unzip -p "$zip_file" "$entry" 2>/dev/null | wc -c | tr -d ' '
    }

    _act_manifest_add_zip_entries() {
        local zip_file="$1"
        local target="$2"
        local version_tag="$manifest_version"
        local version_stripped="${manifest_version#v}"

        if ! command -v unzip &>/dev/null; then
            _log_warn "unzip not available; treating $zip_file as artifact"
            _act_manifest_add_file "$zip_file" "$target"
            return 0
        fi

        local entries
        entries=$(unzip -Z1 "$zip_file" 2>/dev/null)
        if [[ -z "$entries" ]]; then
            _log_warn "No entries found in zip artifact: $zip_file"
            return 0
        fi

        local -a matched_entries=()
        while IFS= read -r entry; do
            [[ -z "$entry" || "$entry" == */ ]] && continue
            if [[ "$entry" == *"$version_tag"* || "$entry" == *"$version_stripped"* ]]; then
                matched_entries+=("$entry")
            fi
        done <<< "$entries"

        local -a use_entries=()
        if [[ ${#matched_entries[@]} -gt 0 ]]; then
            use_entries=("${matched_entries[@]}")
        else
            while IFS= read -r entry; do
                [[ -z "$entry" || "$entry" == */ ]] && continue
                use_entries+=("$entry")
            done <<< "$entries"
        fi

        local entry
        for entry in "${use_entries[@]}"; do
            local name
            name=$(basename "$entry")

            case "$name" in
                *.minisig|*.sig|*.sha256|*.sha512|SHA256SUMS*|*.sbom.*|*.intoto.jsonl)
                    continue
                    ;;
            esac

            local seen_key="${zip_file}::${entry}"
            for seen in "${seen_paths[@]}"; do
                [[ "$seen" == "$seen_key" ]] && continue 2
            done
            # Same name-collision dedup as the on-disk path. Without it a
            # matrix workflow whose zip artifact bundles every platform
            # would emit one manifest entry per orchestration target.
            if [[ -n "${seen_names[$name]:-}" ]]; then
                continue
            fi

            local sha size format
            sha=$(_act_sha256_zip_entry "$zip_file" "$entry" 2>/dev/null || echo "")
            size=$(_act_zip_entry_size "$zip_file" "$entry")
            format=$(_act_archive_format "$name")

            if [[ -z "$sha" ]]; then
                _log_warn "Unable to compute SHA256 for artifact: $zip_file::$entry"
                continue
            fi
            if [[ -z "$size" || "$size" -le 0 ]]; then
                _log_warn "Unable to determine size for artifact: $zip_file::$entry"
                continue
            fi

            # Filename-derived target overrides the orchestration target
            # (matrix workflow under one act job ⇒ unreliable per-target).
            local entry_target="$target"
            local inferred_target
            inferred_target=$(_act_infer_target_from_name "$name")
            if [[ -n "$inferred_target" ]]; then
                entry_target="$inferred_target"
            fi

            local artifact_json
            artifact_json=$(jq -nc \
                --arg name "$name" \
                --arg target "$entry_target" \
                --arg sha "$sha" \
                --argjson size "$size" \
                --arg format "$format" \
                '{
                    name: $name,
                    target: $target,
                    sha256: $sha,
                    size_bytes: $size,
                    archive_format: $format,
                    signed: false,
                    signature_file: ""
                }')

            artifacts+=("$artifact_json")
            seen_paths+=("$seen_key")
            seen_names["$name"]=1
        done
    }

    while IFS= read -r target_json; do
        [[ -z "$target_json" ]] && continue
        local target
        target=$(echo "$target_json" | jq -r '.platform // .target // empty' 2>/dev/null)
        local artifact_path
        artifact_path=$(echo "$target_json" | jq -r '.artifact_path // empty' 2>/dev/null)
        local artifact_dir
        artifact_dir=$(echo "$target_json" | jq -r '.artifact_dir // empty' 2>/dev/null)

        if [[ -n "$artifact_path" && -f "$artifact_path" ]]; then
            _act_manifest_add_file "$artifact_path" "$target"
        fi

        if [[ -n "$artifact_dir" && -d "$artifact_dir" ]]; then
            while IFS= read -r -d '' file; do
                if [[ "$file" == *.zip ]]; then
                    _act_manifest_add_zip_entries "$file" "$target"
                else
                    _act_manifest_add_file "$file" "$target"
                fi
            done < <(find "$artifact_dir" -type f -print0 2>/dev/null)
        fi
    done < <(echo "$result_json" | jq -c '.targets[]?' 2>/dev/null || true)

    local artifacts_json="[]"
    if [[ ${#artifacts[@]} -gt 0 ]]; then
        if ! artifacts_json=$(printf '%s\n' "${artifacts[@]}" | jq -s '.'); then
            _log_error "Failed to serialize manifest artifacts"
            return 4
        fi
    fi

    local manifest
    manifest=$(jq -nc \
        --arg tool "$tool" \
        --arg version "$manifest_version" \
        --arg run_id "$run_id" \
        --arg git_sha "$git_sha" \
        --arg git_ref "$git_ref" \
        --arg built_at "$built_at" \
        --arg status "$status" \
        --argjson duration_ms "$duration_ms" \
        --argjson summary "$summary_json" \
        --argjson artifacts "$artifacts_json" \
        '{
            schema_version: "1.0.0",
            tool: $tool,
            version: $version,
            run_id: $run_id,
            source: {git_sha: $git_sha, git_ref: $git_ref, dependencies: []},
            built_at: $built_at,
            duration_ms: $duration_ms,
            status: $status,
            summary: $summary,
            artifacts: $artifacts
        }') || {
            _log_error "Failed to serialize manifest"
            return 4
        }

    if [[ -n "$output_file" ]]; then
        if ! printf '%s\n' "$manifest" > "$output_file"; then
            _log_error "Failed to write manifest: $output_file"
            return 4
        fi
        _log_info "Manifest written to: $output_file"
    else
        printf '%s\n' "$manifest"
    fi
}

# Export functions for use by other scripts
export -f act_check_prereqs act_check act_version_is_supported act_list_jobs act_get_runner act_can_run
export -f act_run_workflow act_collect_artifacts act_analyze_workflow act_cleanup
export -f act_load_repo_config act_get_job_for_target act_platform_uses_act
export -f act_get_flags act_get_targets act_get_native_host act_get_build_strategy
export -f act_list_tools act_build_matrix
export -f act_get_build_cmd act_substitute_build_cmd_tokens act_get_build_env act_get_repo act_get_local_path
export -f act_get_build_env_value act_get_remote_artifact_path
export -f act_run_native_build act_orchestrate_build act_generate_manifest
export -f act_sync_sources
