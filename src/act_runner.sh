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

_act_strict_git() {
    GIT_NO_REPLACE_OBJECTS=1 git "$@"
}

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

            # The producer never reads stdin.  Callers stream inside
            # `while read` loops fed by here-strings and process
            # substitutions; a producer that inherits that stdin (ssh does)
            # drains the loop's remaining lines, so only the first artifact
            # is ever collected.
            "$@" >&9 </dev/null || exit 7
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
    # -n: never forward the caller's stdin.  These streams run inside
    # `while read` collection loops; without -n ssh drains the loop's
    # remaining lines and every artifact after the first is silently lost.
    ssh -n \
        -o ConnectTimeout="$_ACT_SSH_TIMEOUT" \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new \
        "$ssh_destination" "cat -- $quoted_path"
}

_act_stream_remote_windows_file() {
    local host="$1"
    local source_path="$2"
    local ps_path="${source_path//\'/\'\'}"
    local ps_command
    ps_command="\$ErrorActionPreference='Stop'; \$input=[IO.File]::OpenRead('${ps_path}'); \$output=\$null; try { \$output=[Console]::OpenStandardOutput(); \$input.CopyTo(\$output); \$output.Flush() } finally { if (\$null -ne \$output) { \$output.Dispose() }; \$input.Dispose() }"
    # -n for the same reason as the Unix stream: never drain the caller's
    # collection loop through the ssh session's stdin.
    local ssh_destination command
    ssh_destination=$(_act_get_ssh_destination "$host") || return 4
    command=$(_act_windows_encoded_powershell "$ps_command") || return 4
    command=$(_act_windows_storage_command "$host" "$command") || return 4
    ssh -n -o ConnectTimeout="$_ACT_SSH_TIMEOUT" -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new "$ssh_destination" "$command"
}

_act_stream_workspace_tar_gz() {
    local artifact_dir="$1"
    shift
    (
        set -o pipefail
        (cd "$artifact_dir" && COPYFILE_DISABLE=1 tar --no-xattrs -cf - "$@") | gzip -c
    )
}

_act_stream_workspace_tar_xz() {
    local artifact_dir="$1"
    shift
    (
        set -o pipefail
        (cd "$artifact_dir" && COPYFILE_DISABLE=1 tar --no-xattrs -cf - "$@") | xz -c
    )
}

_act_stream_workspace_zip() {
    local artifact_dir="$1"
    shift
    (cd "$artifact_dir" && zip -q - "$@")
}

# Resolve the native workspace archive format from the per-repository build
# contract.  Native collection used to hard-code gzip for every Unix target,
# even when artifact_naming and the strict release contract required tar.xz.
# An explicit format is authoritative; absent one, an archived strict primary
# supplies its compression format before platform defaults. This also covers
# singleton archives, which previously got their format only during staging.
_act_workspace_archive_format() {
    local config_file="$1"
    local platform="$2"
    local target_os="${platform%%/*}"
    local format="" config_json
    local purpose="${3:-${build_purpose:-release}}"

    [[ "$purpose" == release || "$purpose" == diagnostic-native ]] || return 4
    [[ -f "$config_file" && ! -L "$config_file" ]] || return 4
    command -v yq &>/dev/null && command -v jq &>/dev/null || return 3
    config_json=$(yq -o=json -I=0 '.' "$config_file" 2>/dev/null) || return 4
    format=$(jq -ers --arg os "$target_os" --arg target "$platform" --arg purpose "$purpose" '
        def compression:
            if endswith(".tar.gz") or endswith(".tgz") then "tar.gz"
            elif endswith(".tar.xz") then "tar.xz"
            elif endswith(".zip") then "zip" else "" end;
        if length == 1 and (.[0] | type == "object") then .[0]
        else error("expected one repository configuration") end |
        (if .archive_format == null then ""
         elif (.archive_format | type) == "string" then .archive_format
         elif (.archive_format | type) == "object" then
             if .archive_format[$os] == null then "" else .archive_format[$os] end
         else error("archive_format must be a string or OS mapping") end) as $configured |
        (if ($configured | type) != "string" then error("invalid archive format")
         elif $configured == "tgz" then "tar.gz" else $configured end) as $format |
        (if $purpose == "release" then (.release_contract.exact_primary_assets[$target] // "")
         else "" end) as $primary |
        (if ($primary | type) == "string" then ($primary | compression)
         else error("invalid exact primary name") end) as $required |
        if $format != "" and $required != "" and $format != $required
        then error("archive format differs from exact primary contract")
        elif $format != "" then $format
        elif $required != "" then $required
        elif $os == "windows" then "zip" else "tar.gz" end
    ' <<< "$config_json") || return 4
    case "$format" in
        tar.gz|tar.xz|zip) printf '%s\n' "$format" ;;
        *)
            _log_error "Unsupported workspace archive format for $platform: $format"
            return 4
            ;;
    esac
}

# A target override replaces the complete executable list. Use this same
# selection for collection, archive validation and final manifest validation.
# Without a workspace list, an archived release primary is a singleton archive
# inventory. Sending it through the existing collector stages pinned Git
# include_files BEFORE the archive receipt is frozen, rather than packaging a
# bare binary later and silently skipping companions (GH #29). Empty target
# overrides still discard the workspace list, selecting only binary_name for
# archived primaries, just as native collection already does for that case.
# Raw primaries and configurations without a contract remain unchanged.
# Match the naming resolver's existing purpose context. Diagnostic singleton
# builds must not start using release-only archive names or include policies.
_act_workspace_binaries_for_target() {
    local config_file="$1" target="$2" config_json selected binary normalized
    local purpose="${3:-${build_purpose:-release}}"
    [[ "$purpose" == release || "$purpose" == diagnostic-native ]] || return 4
    [[ -f "$config_file" && ! -L "$config_file" ]] || return 4
    config_json=$(yq -o=json -I=0 '.' "$config_file" 2>/dev/null) || return 4
    selected=$(jq -ces --arg target "$target" --arg purpose "$purpose" '
        def names: type == "array" and all(.[];
            type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._+\\-]*$")
            and (contains("\n") | not));
        if length == 1 then .[0] else error("expected one repository configuration") end |
        if type != "object" then error("invalid repository config")
        elif (has("workspace_binaries") and (.workspace_binaries | names | not))
            then error("invalid workspace_binaries")
        elif (has("workspace_binaries_by_target") and
            (.workspace_binaries_by_target |
                (type == "object" and all(.[]; names)) | not))
            then error("invalid workspace_binaries_by_target")
        else (.workspace_binaries_by_target // {}) as $overrides |
            (if ($overrides | has($target)) then $overrides[$target]
             else (.workspace_binaries // []) end) as $binaries |
            if ($binaries | length) > 0 then $binaries
            elif $purpose != "release" then []
            elif .release_contract == null then []
            elif (.release_contract | type) != "object" or
                 (.release_contract.exact_primary_assets | type) != "object"
            then error("invalid release archive contract")
            else .release_contract.exact_primary_assets[$target] as $primary |
                if ($primary | type) != "string" then error("missing exact primary for target")
                elif ($primary | test("\\.(tar\\.gz|tgz|tar\\.xz|zip)$")) then
                    [.binary_name] | if names then . else error("archive requires binary_name") end
                else [] end
            end
        end
    ' <<< "$config_json") || return 4
    local -A seen=()
    local -a binaries=()
    while IFS= read -r binary; do
        [[ -n "$binary" ]] || continue
        _act_is_safe_basename "$binary" || return 4
        normalized="$binary"
        if [[ "$target" == windows/* ]]; then
            normalized="${binary,,}"
            normalized="${normalized%.exe}.exe"
            if [[ "${binary,,}" == *.exe ]]; then
                binary="${binary:0:${#binary}-4}.exe"
            fi
        fi
        [[ -z "${seen[$normalized]:-}" ]] || return 4
        seen["$normalized"]=1
        binaries+=("$binary")
    done < <(jq -r '.[]' <<< "$selected")
    if [[ ${#binaries[@]} -gt 0 ]]; then
        printf '%s\n' "${binaries[@]}"
    fi
}

# Scripts and manifests are separate from native executables and must never
# bypass native architecture validation by being used to declare a binary.
_act_workspace_archive_files_json() {
    local config_file="$1"
    local target="$2"
    [[ -f "$config_file" && ! -L "$config_file" ]] || return 4
    command -v yq &>/dev/null || return 3
    DSR_TARGET_PLATFORM="$target" yq -o=json -I=0 \
        '.workspace_archive_files[strenv(DSR_TARGET_PLATFORM)] // []' \
        "$config_file" 2>/dev/null
}

_act_workspace_additional_artifacts_json() {
    local config_file="$1"
    local target="$2"
    [[ -f "$config_file" && ! -L "$config_file" ]] || return 4
    command -v yq &>/dev/null || return 3
    DSR_TARGET_PLATFORM="$target" yq -o=json -I=0 \
        '.workspace_additional_artifacts[strenv(DSR_TARGET_PLATFORM)] // []' \
        "$config_file" 2>/dev/null
}

# Per-repo flat-archive contract: when a repo's installer enforces an exact
# payload member set (workspace binaries only), its repos.d yaml sets
# `include_extra_files: false` (or `flat_archive: true`) and configured
# include_files are neither staged into nor expected inside release archives.
# Default is "true" (historic behavior: include_files ship inside archives).
_act_include_files_in_archives() {
    local config_file="$1"
    local extra flat

    [[ -n "$config_file" && -f "$config_file" && ! -L "$config_file" ]] || {
        echo "true"
        return 0
    }
    command -v yq &>/dev/null || {
        echo "true"
        return 0
    }
    # NOTE: `.key // ""` would swallow a boolean false (false // "" -> ""),
    # so read the raw value and compare its string form.
    extra=$(yq -r '.include_extra_files' "$config_file" 2>/dev/null)
    flat=$(yq -r '.flat_archive' "$config_file" 2>/dev/null)
    if [[ "$extra" == "false" || "$flat" == "true" ]]; then
        echo "false"
    else
        echo "true"
    fi
}

_act_is_safe_workspace_include_path() {
    local path="$1"
    [[ "$path" =~ ^[A-Za-z0-9][A-Za-z0-9._+/-]*$ ]] || return 1
    [[ "$path" != /* && "$path" != */ ]] || return 1
    case "/$path/" in
        *"//"*|*"/./"*|*"/../"*) return 1 ;;
    esac
}

_act_workspace_include_path_is_symlink_free() {
    local root="$1"
    local relative_path="$2"
    local cursor="$root"
    local remainder="$relative_path"
    local component

    while [[ "$remainder" == */* ]]; do
        component="${remainder%%/*}"
        remainder="${remainder#*/}"
        cursor="$cursor/$component"
        [[ ! -L "$cursor" ]] || return 1
    done
    [[ ! -L "$cursor/$remainder" ]]
}

_act_release_tree_file_metadata() {
    local repo_path="$1"
    local revision="$2"
    local include="$3"
    local tree_entry tree_metadata tree_mode tree_type tree_object tree_path

    tree_entry=$(_act_strict_git -C "$repo_path" ls-tree -r --full-tree "$revision" -- "$include" 2>/dev/null) || return 7
    [[ -n "$tree_entry" && "$tree_entry" != *$'\n'* ]] || return 7
    IFS=$'\t' read -r tree_metadata tree_path <<< "$tree_entry"
    read -r tree_mode tree_type tree_object <<< "$tree_metadata"
    [[ "$tree_path" == "$include" && "$tree_type" == "blob" &&
       "$tree_object" =~ ^[0-9a-f]{40}$ &&
       ( "$tree_mode" == "100644" || "$tree_mode" == "100755" ) ]] || return 7
    printf '%s\t%s\n' "$tree_mode" "$tree_object"
}

_act_stage_git_blob_exclusive() {
    local repo_path="$1"
    local object_id="$2"
    local destination="$3"
    local mode="$4"

    (
        local descriptor_identity path_identity staged_object_id
        set -C
        umask 077
        exec 9> "$destination" || exit 4
        descriptor_identity=$(_act_file_identity /dev/fd/9) || exit 4
        path_identity=$(_act_file_identity "$destination") || exit 4
        [[ "$descriptor_identity" == "$path_identity" ]] || exit 4

        _act_strict_git -C "$repo_path" cat-file blob "$object_id" >&9 2>/dev/null || exit 7
        chmod "$mode" /dev/fd/9 || exit 4
        path_identity=$(_act_file_identity "$destination") || exit 4
        [[ "$descriptor_identity" == "$path_identity" ]] || exit 4
        staged_object_id=$(_act_strict_git -C "$repo_path" hash-object --no-filters "$destination" 2>/dev/null) || exit 4
        [[ "$staged_object_id" == "$object_id" ]] || exit 4
        path_identity=$(_act_file_identity "$destination") || exit 4
        [[ "$descriptor_identity" == "$path_identity" ]] || exit 4
        exec 9>&-

        [[ -f "$destination" && ! -L "$destination" ]] || exit 4
        path_identity=$(_act_file_identity "$destination") || exit 4
        [[ "$descriptor_identity" == "$path_identity" ]] || exit 4
        staged_object_id=$(_act_strict_git -C "$repo_path" hash-object --no-filters "$destination" 2>/dev/null) || exit 4
        [[ "$staged_object_id" == "$object_id" ]] || exit 4
    )
}

# Stage configured companion files beside downloaded workspace binaries so the
# archive stream can package one closed directory. Strict releases read the
# exact blob and mode from their authenticated release commit instead of the
# ambient worktree, whose clean/smudge filters need not preserve committed
# bytes. Paths are deliberately narrow, source symlinks are rejected, and an
# include may never overwrite a downloaded binary or another include.
_act_stage_workspace_include_files() {
    local config_file="$1"
    local source_root="$2"
    local artifact_dir="$3"
    local revision="${4:-}"
    local configured=""

    [[ -f "$config_file" && ! -L "$config_file" ]] || return 7
    [[ -d "$source_root" && ! -L "$source_root" ]] || return 7
    [[ -d "$artifact_dir" && ! -L "$artifact_dir" ]] || return 7
    command -v yq &>/dev/null || return 7
    if [[ "$(_act_include_files_in_archives "$config_file")" == "false" ]]; then
        # Flat-archive repo: extras never enter the archive payload.
        return 0
    fi
    configured=$(yq -r '.include_files // [] | .[]' "$config_file" 2>/dev/null) || return 7
    if [[ -n "$revision" ]]; then
        local resolved_revision
        if [[ ! "$revision" =~ ^[0-9a-f]{40}$ || "$revision" =~ ^0{40}$ ]] || \
           ! resolved_revision=$(_act_strict_git -C "$source_root" rev-parse --verify "${revision}^{commit}" 2>/dev/null) || \
           [[ "$resolved_revision" != "$revision" ]]; then
            _log_error "Workspace include revision is missing or not an exact commit"
            return 7
        fi
    fi

    local include source_path destination parent
    local tree_metadata tree_mode tree_object file_mode
    while IFS= read -r include; do
        [[ -n "$include" ]] || continue
        if ! _act_is_safe_workspace_include_path "$include"; then
            _log_error "Unsafe workspace include path: $include"
            return 7
        fi
        source_path="$source_root/$include"
        destination="$artifact_dir/$include"
        parent=$(dirname "$destination")
        if [[ -z "$revision" ]]; then
            if [[ ! -f "$source_path" ]] ||
               ! _act_workspace_include_path_is_symlink_free "$source_root" "$include"; then
                _log_error "Workspace include is missing or not a regular non-symlink file: $include"
                return 7
            fi
        else
            if ! tree_metadata=$(_act_release_tree_file_metadata \
                "$source_root" "$revision" "$include"); then
                _log_error "Workspace include is not a regular file in release tree: $include"
                return 7
            fi
            IFS=$'\t' read -r tree_mode tree_object <<< "$tree_metadata"
            file_mode=644
            [[ "$tree_mode" == "100755" ]] && file_mode=755
        fi
        if [[ -e "$destination" || -L "$destination" ]]; then
            _log_error "Workspace include collides with an existing archive member: $include"
            return 7
        fi
        if ! mkdir -p "$parent" || [[ ! -d "$parent" || -L "$parent" ]] || \
           ! _act_workspace_include_path_is_symlink_free "$artifact_dir" "$include"; then
            _log_error "Unable to create workspace include parent: $include"
            return 7
        fi
        if [[ -n "$revision" ]]; then
            if ! _act_stage_git_blob_exclusive \
                "$source_root" "$tree_object" "$destination" "$file_mode"; then
                _log_error "Unable to stage exact release-tree workspace include: $include"
                return 7
            fi
        elif ! cp -p "$source_path" "$destination"; then
            _log_error "Unable to stage workspace include: $include"
            return 7
        fi
        printf '%s\n' "$include"
    done <<< "$configured"
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

_act_validate_target_binary_reader() {
    local label="$1"
    local target="$2"
    local size="$3"
    local executable="$4"
    local reader="$5"
    shift 5
    local reader_args=("$@")
    local header machine pe_offset_hex pe_offset optional_magic

    if [[ ! "$size" =~ ^[1-9][0-9]*$ ]]; then
        _log_error "Target primary has no readable bytes: $label"
        return 4
    fi

    case "$target" in
        linux/amd64|linux/arm64)
            if ((size < 64)) || \
               ! header=$("$reader" "${reader_args[@]}" 0 20); then
                _log_error "Target primary is not a complete ELF64 header: $label"
                return 4
            fi
            machine="${header:36:4}"
            if [[ "${header:0:8}" != "7f454c46" || "${header:8:2}" != "02" || \
                  "${header:10:2}" != "01" ]] || \
               { [[ "$target" == "linux/amd64" ]] && [[ "$machine" != "3e00" ]]; } || \
               { [[ "$target" == "linux/arm64" ]] && [[ "$machine" != "b700" ]]; }; then
                _log_error "Target primary ELF format/architecture does not match $target: $label"
                return 4
            fi
            if [[ "$executable" != "true" ]]; then
                _log_error "Unix target primary is not executable: $label"
                return 4
            fi
            ;;
        darwin/amd64|darwin/arm64)
            if ((size < 32)) || \
               ! header=$("$reader" "${reader_args[@]}" 0 8); then
                _log_error "Target primary is not a complete Mach-O 64 header: $label"
                return 4
            fi
            machine="${header:8:8}"
            if [[ "${header:0:8}" != "cffaedfe" ]] || \
               { [[ "$target" == "darwin/amd64" ]] && [[ "$machine" != "07000001" ]]; } || \
               { [[ "$target" == "darwin/arm64" ]] && [[ "$machine" != "0c000001" ]]; }; then
                _log_error "Target primary Mach-O format/architecture does not match $target: $label"
                return 4
            fi
            if [[ "$executable" != "true" ]]; then
                _log_error "Unix target primary is not executable: $label"
                return 4
            fi
            ;;
        windows/amd64|windows/arm64)
            if ((size < 90)) || \
               [[ "$("$reader" "${reader_args[@]}" 0 2 2>/dev/null || true)" != "4d5a" ]] || \
               ! pe_offset_hex=$("$reader" "${reader_args[@]}" 60 4); then
                _log_error "Target primary is not a complete PE32+ executable: $label"
                return 4
            fi
            pe_offset=$((0x${pe_offset_hex:6:2}${pe_offset_hex:4:2}${pe_offset_hex:2:2}${pe_offset_hex:0:2}))
            if ((pe_offset < 64 || pe_offset + 26 > size)) || \
               [[ "$("$reader" "${reader_args[@]}" "$pe_offset" 4 2>/dev/null || true)" != "50450000" ]] || \
               ! machine=$("$reader" "${reader_args[@]}" "$((pe_offset + 4))" 2) || \
               ! optional_magic=$("$reader" "${reader_args[@]}" "$((pe_offset + 24))" 2) || \
               [[ "$optional_magic" != "0b02" ]] || \
               { [[ "$target" == "windows/amd64" ]] && [[ "$machine" != "6486" ]]; } || \
               { [[ "$target" == "windows/arm64" ]] && [[ "$machine" != "64aa" ]]; }; then
                _log_error "Target primary PE format/architecture does not match $target: $label"
                return 4
            fi
            ;;
        *)
            _log_error "Unsupported strict release target: $target"
            return 4
            ;;
    esac
}

_act_validate_target_binary() {
    local file="$1"
    local target="$2"

    if [[ ! -f "$file" || -L "$file" ]]; then
        _log_error "Target primary is not a regular non-symlink file: $file"
        return 4
    fi

    local size executable=false
    size=$(_act_file_size "$file")
    [[ -x "$file" ]] && executable=true
    _act_validate_target_binary_reader \
        "$file" "$target" "$size" "$executable" _act_read_hex_bytes "$file"
}

_act_archive_entry_stream() {
    local archive="$1"
    local format="$2"
    local entry="$3"

    case "$format" in
        tar.gz) tar -xOzf "$archive" "$entry" ;;
        tar.xz) tar -xOJf "$archive" "$entry" ;;
        zip) unzip -p "$archive" "$entry" ;;
        *) return 4 ;;
    esac
}

# Print the ls-style mode field of one named archive member (empty when the
# member is absent).  The whole listing is captured before it is searched:
# piping the reader into a consumer that stops at the first match (awk exit,
# head, grep -q) lets the reader die of SIGPIPE, and pipefail then reports a
# valid archive as unreadable -- a spurious strict-release failure that hit
# roughly three of four slb builds on a GNU tar host.  A genuine reader
# failure (corrupt archive, missing tool) still returns 4.
_act_archive_member_mode() {
    local archive="$1"
    local format="$2"
    local entry="$3"
    local listing tar_reader="tar"
    command -v gtar &>/dev/null && tar_reader="gtar"

    case "$format" in
        tar.gz) listing=$(LC_ALL=C "$tar_reader" -tvzf "$archive" 2>/dev/null) || return 4 ;;
        tar.xz) listing=$(LC_ALL=C "$tar_reader" -tvJf "$archive" 2>/dev/null) || return 4 ;;
        zip) listing=$(LC_ALL=C unzip -Z -l "$archive" 2>/dev/null) || return 4 ;;
        *) return 4 ;;
    esac
    awk -v entry="$entry" '$NF == entry { print $1; exit }' <<< "$listing"
}

_act_validate_workspace_archive_release_tree_includes() {
    local archive="$1"
    local format="$2"
    local config_file="$3"
    local repo_path="$4"
    local revision="$5"
    local resolved_revision configured=""

    [[ -f "$archive" && ! -L "$archive" ]] || return 4
    [[ -f "$config_file" && ! -L "$config_file" ]] || return 4
    [[ -d "$repo_path" && ! -L "$repo_path" ]] || return 4
    command -v yq &>/dev/null || return 4
    if [[ ! "$revision" =~ ^[0-9a-f]{40}$ || "$revision" =~ ^0{40}$ ]] || \
       ! resolved_revision=$(_act_strict_git -C "$repo_path" rev-parse --verify "${revision}^{commit}" 2>/dev/null) || \
       [[ "$resolved_revision" != "$revision" ]]; then
        return 4
    fi
    if [[ "$(_act_include_files_in_archives "$config_file")" == "false" ]]; then
        # Flat-archive repo: no extras are expected inside the archive.
        return 0
    fi
    configured=$(yq -r '.include_files // [] | .[]' "$config_file" 2>/dev/null) || return 4

    local include tree_metadata tree_mode tree_object archived_object mode
    while IFS= read -r include; do
        [[ -n "$include" ]] || continue
        _act_is_safe_workspace_include_path "$include" || return 4
        tree_metadata=$(_act_release_tree_file_metadata \
            "$repo_path" "$revision" "$include") || return 4
        IFS=$'\t' read -r tree_mode tree_object <<< "$tree_metadata"
        archived_object=$(
            _act_archive_entry_stream "$archive" "$format" "$include" |
                _act_strict_git -C "$repo_path" hash-object --stdin 2>/dev/null
        ) || return 4
        [[ "$archived_object" == "$tree_object" ]] || return 4

        mode=$(_act_archive_member_mode "$archive" "$format" "$include") || return 4
        [[ "$mode" == -* ]] || return 4
        if [[ "$tree_mode" == "100755" ]]; then
            [[ "$mode" == *x* ]] || return 4
        else
            [[ "$mode" != *x* ]] || return 4
        fi
    done <<< "$configured"
}

_act_validate_workspace_archive_collection_receipts() {
    local archive="$1"
    local format="$2"
    local target="$3"
    local config_file="$4"
    shift 4

    [[ -f "$archive" && ! -L "$archive" && $# -gt 0 ]] || return 4
    [[ -f "$config_file" && ! -L "$config_file" ]] || return 4
    command -v yq &>/dev/null || return 4
    local -A receipt_expected_members=() receipt_seen_members=()
    local configured="" binary expected_member expected_count=0
    configured=$(_act_workspace_binaries_for_target "$config_file" "$target") || return 4
    while IFS= read -r binary; do
        [[ -n "$binary" ]] || continue
        _act_is_safe_basename "$binary" || return 4
        expected_member="$binary"
        [[ "$target" == windows/* ]] && expected_member="${binary%.exe}.exe"
        [[ -z "${receipt_expected_members[$expected_member]:-}" ]] || return 4
        receipt_expected_members["$expected_member"]=1
        ((expected_count++))
    done <<< "$configured"
    [[ $expected_count -gt 0 && $# -eq $expected_count ]] || return 4

    local receipt path member expected_sha expected_size identity actual_sha actual_size
    for receipt in "$@"; do
        if ! path=$(jq -er '.path | select(type == "string" and length > 0)' <<< "$receipt" 2>/dev/null) || \
           ! expected_sha=$(jq -er '.sha256 | select(type == "string" and test("^[0-9a-f]{64}$"))' <<< "$receipt" 2>/dev/null) || \
           ! expected_size=$(jq -er '.size_bytes | select(type == "number" and . > 0 and floor == .)' <<< "$receipt" 2>/dev/null) || \
           ! identity=$(jq -er '.identity | select(type == "string" and test("^(gnu:[0-9]+:[1-9][0-9]*|bsd:[1-9][0-9]*)$"))' <<< "$receipt" 2>/dev/null); then
            return 4
        fi
        member=$(basename "$path")
        [[ -n "${receipt_expected_members[$member]:-}" ]] || return 4
        [[ -z "${receipt_seen_members[$member]:-}" ]] || return 4
        receipt_seen_members["$member"]=1

        if command -v sha256sum &>/dev/null; then
            actual_sha=$(
                _act_archive_entry_stream "$archive" "$format" "$member" |
                    sha256sum | awk '{print $1}'
            ) || return 4
        elif command -v shasum &>/dev/null; then
            actual_sha=$(
                _act_archive_entry_stream "$archive" "$format" "$member" |
                    shasum -a 256 | awk '{print $1}'
            ) || return 4
        else
            return 3
        fi
        actual_size=$(_act_archive_entry_stream "$archive" "$format" "$member" | \
            wc -c | tr -d '[:space:]') || return 4
        [[ "$actual_sha" == "$expected_sha" && "$actual_size" == "$expected_size" ]] || return 4
    done
    [[ ${#receipt_seen_members[@]} -eq $expected_count ]]
}

_act_read_archive_hex_bytes() {
    local archive="$1"
    local format="$2"
    local entry="$3"
    local offset="$4"
    local count="$5"
    local hex

    if [[ ! "$offset" =~ ^[0-9]+$ || ! "$count" =~ ^[1-9][0-9]*$ ]]; then
        return 4
    fi
    # od stops after COUNT bytes, which may make the archive reader observe a
    # harmless SIGPIPE. Validate the exact byte count below; a separate full
    # stream pass establishes the payload size before this helper is called.
    if ! hex=$(
        set +o pipefail
        _act_archive_entry_stream "$archive" "$format" "$entry" 2>/dev/null | \
            LC_ALL=C od -An -v -j "$offset" -N "$count" -tx1 2>/dev/null | \
            tr -d '[:space:]' | tr '[:upper:]' '[:lower:]'
    ); then
        return 4
    fi
    if [[ ${#hex} -ne $((count * 2)) || ! "$hex" =~ ^[0-9a-f]+$ ]]; then
        return 4
    fi
    printf '%s\n' "$hex"
}

_act_validate_target_archive() {
    local archive="$1"
    local format="$2"
    local expected_entry="$3"
    local target="$4"
    local entries size mode executable=false
    local tar_reader="tar"
    command -v gtar &>/dev/null && tar_reader="gtar"

    case "$format" in
        tar.gz)
            command -v tar &>/dev/null || return 4
            entries=$("$tar_reader" -tzf "$archive" 2>/dev/null) || return 4
            mode=$("$tar_reader" -tvzf "$archive" 2>/dev/null | awk 'NR == 1 { print $1 }') || return 4
            ;;
        tar.xz)
            command -v tar &>/dev/null || return 4
            entries=$("$tar_reader" -tJf "$archive" 2>/dev/null) || return 4
            mode=$("$tar_reader" -tvJf "$archive" 2>/dev/null | awk 'NR == 1 { print $1 }') || return 4
            ;;
        zip)
            command -v unzip &>/dev/null || return 4
            entries=$(unzip -Z1 "$archive" 2>/dev/null) || return 4
            mode=$(_act_archive_member_mode "$archive" "$format" "$expected_entry") || return 4
            ;;
        *)
            _log_error "Unsupported strict release archive format: $format"
            return 4
            ;;
    esac

    if [[ "$entries" != "$expected_entry" ]]; then
        _log_error "Strict release archive must contain exactly $expected_entry: $archive"
        return 4
    fi
    size=$(_act_archive_entry_stream "$archive" "$format" "$expected_entry" 2>/dev/null | \
        wc -c | tr -d '[:space:]') || return 4
    [[ "$mode" == *x* ]] && executable=true
    _act_validate_target_binary_reader \
        "$archive::$expected_entry" "$target" "$size" "$executable" \
        _act_read_archive_hex_bytes "$archive" "$format" "$expected_entry"
}

# Verify the additional macOS application archive as one manifest-bound
# namespace without extracting it or launching any packaged process.  The
# detached component manifest must describe every regular file below the app,
# and every described digest/mode must match the tar stream.  Directories and
# safe relative symlinks are allowed; hard links and special entries are not.
_act_validate_macos_app_archive() {
    local archive="$1"
    local source_revision="$2"
    local version="$3"
    command -v python3 &>/dev/null || return 3
    python3 - "$archive" "$source_revision" "${version#v}" <<'PY'
import hashlib
import json
import os
import posixpath
import stat
import sys
import tarfile

archive, source_revision, version = sys.argv[1:]
maximum_archive_bytes = 8 * 1024 * 1024 * 1024
maximum_members = 100_010
maximum_manifest_bytes = 16 * 1024 * 1024
schema = "ft.atomic_component_manifest.v1"
feature = "application-family-gui-ft-mux-server-pty-guardian-default-features-v1"

flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
fd = os.open(archive, flags)
try:
    before = os.fstat(fd)
    named = os.stat(archive, follow_symlinks=False)
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_nlink != 1
        or before.st_size <= 0
        or before.st_size > maximum_archive_bytes
        or (before.st_dev, before.st_ino) != (named.st_dev, named.st_ino)
    ):
        raise SystemExit("unsafe or oversized macOS app archive")
    identity = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)

    regular = {}
    detached = None
    member_count = 0
    with os.fdopen(os.dup(fd), "rb", closefd=True) as stream:
        with tarfile.open(fileobj=stream, mode="r:xz") as package:
            for member in package:
                member_count += 1
                if member_count > maximum_members:
                    raise SystemExit("macOS app archive exceeds member-count bound")
                name = member.name
                encoded = name.encode("utf-8")
                normalized = posixpath.normpath(name)
                if (
                    not encoded
                    or len(encoded) > 4096
                    or name.startswith("/")
                    or "\\" in name
                    or normalized != name.rstrip("/")
                    or any(part in ("", ".", "..") for part in name.rstrip("/").split("/"))
                ):
                    raise SystemExit(f"unsafe macOS app archive path: {name!r}")
                if name == "FrankenTerm.app.component-manifest.json":
                    if detached is not None or not member.isfile() or member.size > maximum_manifest_bytes:
                        raise SystemExit("invalid detached macOS component manifest entry")
                    handle = package.extractfile(member)
                    if handle is None:
                        raise SystemExit("unreadable detached macOS component manifest")
                    detached = handle.read(maximum_manifest_bytes + 1)
                    if len(detached) != member.size:
                        raise SystemExit("truncated detached macOS component manifest")
                    continue
                if not (name == "FrankenTerm.app" or name.startswith("FrankenTerm.app/")):
                    raise SystemExit(f"unexpected macOS app archive root: {name!r}")
                if member.isdir():
                    continue
                if member.issym():
                    target = member.linkname
                    resolved = posixpath.normpath(posixpath.join(posixpath.dirname(name), target))
                    if target.startswith("/") or not resolved.startswith("FrankenTerm.app/"):
                        raise SystemExit(f"escaping macOS app symlink: {name!r}")
                    continue
                if not member.isfile() or member.islnk():
                    raise SystemExit(f"unsupported macOS app archive member: {name!r}")
                relative = name.removeprefix("FrankenTerm.app/")
                if relative in regular:
                    raise SystemExit(f"duplicate macOS app file: {relative!r}")
                handle = package.extractfile(member)
                if handle is None:
                    raise SystemExit(f"unreadable macOS app file: {relative!r}")
                digest = hashlib.sha256()
                observed = 0
                while True:
                    chunk = handle.read(1024 * 1024)
                    if not chunk:
                        break
                    observed += len(chunk)
                    digest.update(chunk)
                if observed != member.size:
                    raise SystemExit(f"truncated macOS app file: {relative!r}")
                regular[relative] = (digest.hexdigest(), observed, bool(member.mode & 0o111))

    if detached is None:
        raise SystemExit("macOS app archive lacks detached component manifest")
    manifest = json.loads(detached)
    if manifest.get("schema_version") != schema:
        raise SystemExit("unsupported macOS component manifest schema")
    claimed_id = manifest.get("manifest_id")
    unsigned = dict(manifest)
    unsigned.pop("manifest_id", None)
    canonical = json.dumps(unsigned, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode() + b"\n"
    # The producer's canonical JSON has no trailing newline in the hashed
    # payload.  Accept exactly that definition, not ordinary pretty JSON.
    canonical_without_newline = canonical[:-1]
    expected_id = "sha256:" + hashlib.sha256(canonical_without_newline).hexdigest()
    if claimed_id != expected_id:
        raise SystemExit("macOS component manifest identity mismatch")
    identity_value = manifest.get("identity", {})
    if (
        identity_value.get("source_revision") != source_revision
        or identity_value.get("version") != version
        or identity_value.get("target") != "aarch64-apple-darwin"
        or identity_value.get("profile") != "release-interactive"
        or identity_value.get("feature_contract") != feature
    ):
        raise SystemExit("macOS component manifest release identity mismatch")
    files = manifest.get("files")
    if not isinstance(files, list) or len(files) != len(regular):
        raise SystemExit("macOS component manifest inventory count mismatch")
    expected = {}
    components = set()
    for record in files:
        if not isinstance(record, dict) or not isinstance(record.get("path"), str):
            raise SystemExit("invalid macOS component manifest file record")
        path = record["path"]
        if path in expected:
            raise SystemExit("duplicate macOS component manifest path")
        expected[path] = (record.get("sha256"), record.get("bytes"), record.get("executable"))
        component = record.get("component")
        if isinstance(component, str):
            components.add(component)
    if expected != regular:
        raise SystemExit("macOS app bytes do not match detached component manifest")
    if components != {"frankenterm-gui", "ft", "frankenterm-mux-server", "frankenterm-pty-guardian"}:
        raise SystemExit("macOS app manifest lacks the exact four process roles")
    inventory = manifest.get("inventory", {})
    if inventory.get("mode") != "exact" or inventory.get("file_count") != len(regular):
        raise SystemExit("macOS app manifest inventory authority mismatch")

    after = os.fstat(fd)
    renamed = os.stat(archive, follow_symlinks=False)
    if (
        identity != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
        or (after.st_dev, after.st_ino) != (renamed.st_dev, renamed.st_ino)
    ):
        raise SystemExit("macOS app archive changed during manifest verification")
finally:
    os.close(fd)
PY
}

# Windows process-family manifests are produced on the POSIX coordinator.
# Re-read the final ZIP through one held descriptor after collection-receipt
# checks, binding its complete namespace and bytes to that manifest.
_act_validate_frankenterm_windows_archive() {
    local archive="$1" revision="$2" version="$3" build_id="$4"
    python3 - "$archive" "$revision" "${version#v}" "$build_id" <<'PY'
import hashlib
import json
import os
import stat
import sys
import zipfile

path, revision, version, build_id = sys.argv[1:]
manifest_name = "ft-windows-amd64.component-manifest.json"
components = {
    "ft.exe": "ft",
    "frankenterm-gui.exe": "frankenterm-gui",
    "frankenterm-mux-server.exe": "frankenterm-mux-server",
    "frankenterm-pty-guardian.exe": "frankenterm-pty-guardian",
}
expected_names = set(components) | {"verify-components.sh", manifest_name}
def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate Windows manifest object key")
        result[key] = value
    return result
if not getattr(os, "O_NOFOLLOW", 0):
    raise SystemExit("Windows archive verification requires POSIX no-follow authority")
fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
try:
    before = os.fstat(fd)
    def identity(value):
        return (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or not 0 < before.st_size <= 4 * 1024**3:
        raise SystemExit("unsafe Windows family archive")
    regular = {}
    with os.fdopen(os.dup(fd), "rb") as stream, zipfile.ZipFile(stream) as package:
        members = package.infolist()
        # Exact spelling and cardinality also reject case aliases, duplicates,
        # directories, traversal, ADS names and unexpected executable members.
        if len(members) != len(expected_names) or {item.filename for item in members} != expected_names:
            raise SystemExit("Windows family ZIP namespace mismatch")
        total = 0
        for item in members:
            mode = item.external_attr >> 16
            total += item.file_size
            if (not stat.S_ISREG(mode) or item.flag_bits & 1
                or item.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED)
                or not 0 < item.file_size <= 1024**3 or total > 4 * 1024**3):
                raise SystemExit("unsupported Windows family ZIP member")
            if item.filename == manifest_name:
                if item.file_size > 8 * 1024**2:
                    raise SystemExit("oversized Windows family manifest")
                manifest = json.loads(package.read(item), object_pairs_hook=unique_object)
                continue
            digest = hashlib.sha256()
            count = 0
            with package.open(item) as member:
                while chunk := member.read(1024**2):
                    count += len(chunk)
                    if count > item.file_size:
                        raise SystemExit("Windows family member size changed")
                    digest.update(chunk)
            if count != item.file_size:
                raise SystemExit("truncated Windows family member")
            regular[item.filename] = (digest.hexdigest(), count, bool(mode & 0o111))
    unsigned = dict(manifest)
    claimed_id = unsigned.pop("manifest_id", None)
    canonical = json.dumps(unsigned, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
    if claimed_id != "sha256:" + hashlib.sha256(canonical).hexdigest():
        raise SystemExit("Windows family manifest digest mismatch")
    expected_identity = {
        "build_id": build_id, "source_revision": revision, "version": version,
        "target": "x86_64-pc-windows-msvc", "profile": "release-interactive",
        "feature_contract": "application-family-gui-ft-mux-server-pty-guardian-default-features-v1",
    }
    if manifest.get("schema_version") != "ft.atomic_component_manifest.v1" or manifest.get("identity") != expected_identity:
        raise SystemExit("Windows family release identity mismatch")
    records = manifest.get("files", [])
    if len(records) != len(regular) or {record.get("path") for record in records} != set(regular):
        raise SystemExit("Windows family manifest namespace mismatch")
    for record in records:
        name = record["path"]
        if (record.get("sha256"), record.get("bytes"), record.get("executable")) != regular[name]:
            raise SystemExit("Windows family archive bytes differ from verified manifest")
        if name in components and (record.get("component") != components[name] or record.get("kind") != "executable"):
            raise SystemExit("Windows family process role mismatch")
    inventory = manifest.get("inventory", {})
    if inventory.get("mode") != "exact" or inventory.get("file_count") != len(regular):
        raise SystemExit("Windows family inventory is not exact")
    if identity(before) != identity(os.fstat(fd)) or identity(before) != identity(os.stat(path, follow_symlinks=False)):
        raise SystemExit("Windows family archive changed during verification")
finally:
    os.close(fd)
PY
}

# Validate a release archive that was already assembled by the strict native
# workspace collector. Unlike the single-binary archive path above, this form
# must retain every configured workspace binary and companion notice while
# still proving that each executable has the requested target architecture.
_act_validate_workspace_archive() {
    local archive="$1"
    local format="$2"
    local target="$3"
    local config_file="$4"
    local entries="" expected_entries="" configured=""
    local tar_reader="tar"
    command -v gtar &>/dev/null && tar_reader="gtar"

    [[ -f "$config_file" && ! -L "$config_file" ]] || return 4
    command -v yq &>/dev/null || return 4

    case "$format" in
        tar.gz)
            command -v tar &>/dev/null || return 4
            entries=$("$tar_reader" -tzf "$archive" 2>/dev/null) || return 4
            ;;
        tar.xz)
            command -v tar &>/dev/null || return 4
            entries=$("$tar_reader" -tJf "$archive" 2>/dev/null) || return 4
            ;;
        zip)
            command -v unzip &>/dev/null || return 4
            entries=$(unzip -Z1 "$archive" 2>/dev/null) || return 4
            ;;
        *) return 4 ;;
    esac

    local -a binary_members=() expected_members=()
    local -A seen_members=()
    local binary member include
    configured=$(_act_workspace_binaries_for_target "$config_file" "$target") || return 4
    while IFS= read -r binary; do
        [[ -n "$binary" ]] || continue
        _act_is_safe_basename "$binary" || return 4
        member="$binary"
        [[ "$target" == windows/* ]] && member="${binary%.exe}.exe"
        [[ -z "${seen_members[$member]:-}" ]] || return 4
        seen_members["$member"]=1
        binary_members+=("$member")
        expected_members+=("$member")
    done <<< "$configured"
    [[ ${#binary_members[@]} -gt 0 ]] || return 4

    local archive_files_json archive_file_json archive_file executable
    archive_files_json=$(_act_workspace_archive_files_json "$config_file" "$target") || return $?
    if ! jq -e '
        type == "array" and
        all(.[];
            type == "object" and
            (keys | sort) == ["executable", "name"] and
            (.name | type == "string") and
            (.executable | type == "boolean")
        )
    ' <<< "$archive_files_json" >/dev/null 2>&1; then
        return 4
    fi
    while IFS= read -r archive_file_json; do
        [[ -n "$archive_file_json" ]] || continue
        archive_file=$(jq -r '.name' <<< "$archive_file_json") || return 4
        _act_is_safe_basename "$archive_file" || return 4
        [[ -z "${seen_members[$archive_file]:-}" ]] || return 4
        seen_members["$archive_file"]=1
        expected_members+=("$archive_file")
    done < <(jq -c '.[]' <<< "$archive_files_json")

    if [[ "$(_act_include_files_in_archives "$config_file")" == "false" ]]; then
        # Flat-archive repo: the expected member closure is the workspace
        # binaries alone; configured include_files must not appear.
        configured=""
    else
        configured=$(yq -r '.include_files // [] | .[]' "$config_file" 2>/dev/null) || return 4
    fi
    while IFS= read -r include; do
        [[ -n "$include" ]] || continue
        _act_is_safe_workspace_include_path "$include" || return 4
        [[ -z "${seen_members[$include]:-}" ]] || return 4
        seen_members["$include"]=1
        expected_members+=("$include")
    done <<< "$configured"

    expected_entries=$(printf '%s\n' "${expected_members[@]}" | LC_ALL=C sort)
    entries=$(printf '%s\n' "$entries" | LC_ALL=C sort)
    if [[ "$entries" != "$expected_entries" ]]; then
        _log_error "Strict workspace archive members do not match configured closure: $archive"
        return 4
    fi

    local mode size executable=false
    for member in "${expected_members[@]}"; do
        mode=$(_act_archive_member_mode "$archive" "$format" "$member") || return 4
        [[ "$mode" == -* ]] || return 4
        archive_file_json=$(jq -c --arg name "$member" \
            '.[] | select(.name == $name)' <<< "$archive_files_json") || return 4
        if [[ -n "$archive_file_json" ]]; then
            executable=$(jq -r '.executable' <<< "$archive_file_json") || return 4
            if [[ "$executable" == "true" ]]; then
                [[ "$mode" == *x* ]] || return 4
            else
                [[ "$mode" != *x* ]] || return 4
            fi
        fi
    done

    for member in "${binary_members[@]}"; do
        size=$(_act_archive_entry_stream "$archive" "$format" "$member" 2>/dev/null | \
            wc -c | tr -d '[:space:]') || return 4
        executable=false
        mode=$(_act_archive_member_mode "$archive" "$format" "$member") || return 4
        [[ "$mode" == *x* ]] && executable=true
        _act_validate_target_binary_reader \
            "$archive::$member" "$target" "$size" "$executable" \
            _act_read_archive_hex_bytes "$archive" "$format" "$member" || return 4
    done
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
    local source_basename source_is_contract_asset=false source_format
    source_basename=$(basename "$source_path")
    if [[ "$source_basename" == "$expected_name" ]]; then
        source_is_contract_asset=true
    elif [[ "$source_basename" != "$expected_input_name" ]]; then
        _log_error "Release primary input for $target must be named $expected_input_name or $expected_name"
        return 4
    fi
    case "$source_basename" in
        *.sha256|*.sha512|*.minisig|*.sig|*.sbom.*|*.intoto.jsonl)
            _log_error "Release primary candidate is metadata, not a binary/archive: $source_path"
            return 4
            ;;
    esac
    source_format=$(_act_archive_format "$source_basename")
    if $source_is_contract_asset && [[ "$source_format" != "none" ]]; then
        local workspace_binaries
        workspace_binaries=$(_act_workspace_binaries_for_target "$config_file" "$target") || return 4
        if [[ -n "$workspace_binaries" ]]; then
            _act_validate_workspace_archive \
                "$source_path" "$source_format" "$target" "$config_file" || return 4
        else
            _act_validate_target_archive \
                "$source_path" "$source_format" "$expected_input_name" "$target" || return 4
        fi
    elif ! _act_validate_target_binary "$source_path" "$target"; then
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
    local staged_format
    staged_format=$(_act_archive_format "$expected_name")
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
        if $source_is_contract_asset; then
            cat -- "$source_path" >&9 || exit 4
            if [[ -x "$source_path" && "$staged_format" == "none" ]]; then
                chmod 700 /dev/fd/9 || exit 4
            else
                chmod 600 /dev/fd/9 || exit 4
            fi
        else case "$staged_format" in
            none)
                cat -- "$source_path" >&9 || exit 4
                if [[ -x "$source_path" ]]; then
                    chmod 700 /dev/fd/9 || exit 4
                else
                    chmod 600 /dev/fd/9 || exit 4
                fi
                ;;
            tar.gz)
                command -v tar &>/dev/null || exit 4
                (
                    set -o pipefail
                    (cd "$(dirname "$source_path")" && \
                        COPYFILE_DISABLE=1 tar --no-xattrs -cf - \
                            "$(basename "$source_path")") | gzip -c
                ) >&9 || exit 4
                chmod 600 /dev/fd/9 || exit 4
                ;;
            tar.xz)
                command -v tar &>/dev/null || exit 4
                (
                    set -o pipefail
                    (cd "$(dirname "$source_path")" && \
                        COPYFILE_DISABLE=1 tar --no-xattrs -cf - \
                            "$(basename "$source_path")") | xz -c
                ) >&9 || exit 4
                chmod 600 /dev/fd/9 || exit 4
                ;;
            zip)
                command -v zip &>/dev/null || exit 4
                (cd "$(dirname "$source_path")" && \
                    zip -q - "$(basename "$source_path")") >&9 || exit 4
                chmod 600 /dev/fd/9 || exit 4
                ;;
            *) exit 4 ;;
        esac
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
    if $source_is_contract_asset && [[ "$staged_format" != "none" ]]; then
        if [[ -n "${workspace_binaries:-}" ]]; then
            _act_validate_workspace_archive \
                "$staged_path" "$staged_format" "$target" "$config_file" || return 4
        else
            _act_validate_target_archive \
                "$staged_path" "$staged_format" "$expected_input_name" "$target" || return 4
        fi
        if ! cmp -s -- "$source_path" "$staged_path"; then
            _log_error "Staged release archive does not match its collected archive: $staged_path"
            return 4
        fi
    elif [[ "$staged_format" == "none" ]]; then
        if ! _act_validate_target_binary "$staged_path" "$target"; then
            return 4
        fi
    else
        if ! _act_validate_target_archive \
            "$staged_path" "$staged_format" "$expected_input_name" "$target"; then
            return 4
        fi
        if ! _act_archive_entry_stream \
            "$staged_path" "$staged_format" "$expected_input_name" | \
            cmp -s -- "$source_path" -; then
            _log_error "Staged release archive payload does not match its collected binary: $staged_path"
            return 4
        fi
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
            "$source_size_before" == "$source_size_after" ]]; then
        _log_error "Release primary changed while staging for $target"
        return 4
    fi
    if { $source_is_contract_asset || [[ "$staged_format" == "none" ]]; } && \
       ! [[ "$source_sha_before" == "$staged_sha" &&
             "$source_size_before" == "$staged_size" ]]; then
        _log_error "Raw staged release primary does not match its collected binary for $target"
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

# Purpose is persisted authority, not a hint inferred from the selected targets.
# Legacy ordinary builds may omit it; strict builds and every diagnostic require it.
_act_build_purpose_matches() {
    local document="$1" expected="$2" require_purpose="${3:-true}"
    jq -es --arg expected "$expected" --argjson required "$require_purpose" '
        if length != 1 or (.[0] | type) != "object" then false else .[0] |
        if (has("build_purpose") or has("publishable")) then
            .build_purpose == $expected and
            ($expected == "release" or $expected == "diagnostic-native") and
            .publishable == ($expected == "release")
        else ($required | not) and $expected == "release" end end
    ' <<< "$document" >/dev/null 2>&1
}

# Project only the artifact inventory, retaining all other strict validators.
# Additional assets must have unambiguous configured target ownership; observed
# outputs can never determine which family members a diagnostic is required to have.
_act_contract_for_build_purpose() {
    local tool="$1" contract="$2" requested="$3" purpose="$4"
    if ! jq -en --argjson contract "$contract" --argjson requested "$requested" '
        ($requested | type == "array" and length > 0) and
        ($requested | length) == ($requested | unique | length) and
        (($requested - ($contract.exact_primary_assets | keys)) | length) == 0
    ' >/dev/null 2>&1; then
        _log_error "Build targets must be a nonempty unique subset of the strict contract"
        return 4
    fi
    if [[ "$purpose" == "release" ]]; then
        if ! jq -en --argjson contract "$contract" --argjson requested "$requested" \
            '($requested | sort) == ($contract.exact_primary_assets | keys | sort)' >/dev/null; then
            _log_error "Strict release contract requires the complete configured target set"
            return 4
        fi
        printf '%s\n' "$contract"
        return 0
    fi
    [[ "$purpose" == "diagnostic-native" ]] || return 4
    local ownership='{}' target additional
    while IFS= read -r target; do
        if act_platform_uses_act "$tool" "$target"; then
            _log_error "Diagnostic target $target must use the strict native runner"
            return 4
        fi
    done < <(jq -r '.[]' <<< "$requested")
    while IFS= read -r target; do
        additional=$(_act_workspace_additional_artifacts_json "$ACT_REPOS_DIR/$tool.yaml" "$target") || return 4
        if ! jq -e 'type == "array" and all(.[]; type == "string" and length > 0)' \
            <<< "$additional" >/dev/null; then
            _log_error "Diagnostic additional artifact ownership is invalid for $target"
            return 4
        fi
        ownership=$(jq -nc --argjson owners "$ownership" --arg target "$target" \
            --argjson additional "$additional" '$owners + {($target): $additional}') || return 4
    done < <(jq -r '.exact_primary_assets | keys[]' <<< "$contract")
    if ! jq -en --argjson owners "$ownership" --argjson contract "$contract" '
        [$owners[][]] as $owned |
        [($contract.exact_additional_assets // [])[] |
         select((endswith(".sha256") or endswith(".minisig") or
                 . == "SHA256SUMS" or . == "SHA256SUMS.txt" or . == "checksums.txt") | not)] as $expected |
        ($owned | length) == ($owned | unique | length) and
        ($owned | sort) == ($expected | sort)
    ' >/dev/null; then
        _log_error "Diagnostic builds require exact configured ownership of additional assets"
        return 4
    fi
    jq -nc --argjson contract "$contract" --argjson requested "$requested" \
        --argjson owners "$ownership" '
        $contract |
        .exact_primary_assets |= with_entries(select(.key as $key | $requested | index($key))) |
        .exact_additional_assets = [$requested[] as $target | $owners[$target][]]
    '
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
    if ! head_sha=$(_act_strict_git -C "$repo_path" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || \
       [[ ! "$head_sha" =~ ^[0-9a-f]{40}$ ]]; then
        _log_error "Unable to resolve local HEAD for release contract"
        return 4
    fi
    if ! tag_sha=$(_act_strict_git -C "$repo_path" rev-parse --verify "refs/tags/${git_ref}^{commit}" 2>/dev/null) || \
       [[ ! "$tag_sha" =~ ^[0-9a-f]{40}$ ]]; then
        _log_error "Unable to resolve release tag $git_ref"
        return 4
    fi
    if ! [[ "$git_sha" == "$head_sha" && "$git_sha" == "$tag_sha" ]]; then
        _log_error "Release source mismatch: supplied SHA, HEAD, and $git_ref must match"
        return 4
    fi
    if ! source_status=$(_act_strict_git -C "$repo_path" status --porcelain --untracked-files=all 2>/dev/null); then
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
        if ! dependency_head=$(_act_strict_git -C "$dependency_path" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || \
           ! dependency_revision=$(_act_strict_git -C "$dependency_path" rev-parse --verify "${dependency_sha}^{commit}" 2>/dev/null) || \
           [[ "$dependency_head" != "$dependency_sha" || "$dependency_revision" != "$dependency_sha" ]]; then
            _log_error "Pinned release source dependency is not checked out at $dependency_sha: $dependency_path"
            return 4
        fi
        if ! dependency_status=$(_act_strict_git -C "$dependency_path" status --porcelain --untracked-files=all 2>/dev/null); then
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

_act_run_with_timeout() (
    local seconds="$1"
    shift
    local cmd
    cmd=$(_act_timeout_cmd)
    if [[ -n "$cmd" ]]; then
        # GNU timeout creates its own process group. Forward cancellation from
        # the orchestration group into that group before releasing our waiter.
        # --foreground would lose timeout's descendant deadline enforcement.
        local timeout_pid="" cancel_status=0
        _act_timeout_cancel() {
            # A signal may arrive between the background fork and recording $!.
            # Defer forwarding until the exact owned PID is available.
            cancel_status=$1
            [[ -n "$timeout_pid" ]] || return 0
            trap '' INT TERM
            kill -TERM -- "-$timeout_pid" 2>/dev/null ||
                kill -TERM "$timeout_pid" 2>/dev/null || true
            wait "$timeout_pid" 2>/dev/null || true
            exit "$1"
        }
        trap '_act_timeout_cancel 130' INT
        trap '_act_timeout_cancel 143' TERM
        "$cmd" "$seconds" "$@" <&0 &
        timeout_pid=$!
        if (( cancel_status != 0 )); then
            _act_timeout_cancel "$cancel_status"
        fi
        wait "$timeout_pid"
    else
        "$@"
    fi
)

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

# True when dsr runs without a person to answer prompts: CI, the global
# --non-interactive flag (NON_INTERACTIVE / DSR_NON_INTERACTIVE), or no
# terminal on stdin. Mirrors guardrails' is_non_interactive, which this module
# cannot assume is loaded.
_act_session_is_non_interactive() {
    [[ -n "${CI:-}" || "${NON_INTERACTIVE:-}" == "true" || \
       "${DSR_NON_INTERACTIVE:-}" == "true" || ! -t 0 ]]
}

# True when act will not open its interactive first-run image survey: the
# command carries a -P/--platform mapping, or any actrc act reads exists (act
# then uses that file's mappings or its documented defaults — operator policy
# either way). act reads ~/.actrc, $XDG_CONFIG_HOME/act/actrc (else
# ~/.config/act/actrc) and ./.actrc.
# Usage: _act_runner_image_config_present <home> [act argv...]
_act_runner_image_config_present() {
    local home="$1"
    shift
    local arg
    for arg in "$@"; do
        case "$arg" in
            -P|-P?*|--platform|--platform=*) return 0 ;;
        esac
    done
    local config
    for config in "$home/.actrc" "${XDG_CONFIG_HOME:-$home/.config}/act/actrc" "$PWD/.actrc"; do
        [[ -f "$config" ]] && return 0
    done
    return 1
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

    # The isolated home always carries a mapping; the operator's own config
    # may not, and act then opens its first-run image survey, which exits on
    # EOF without a terminal (bd-1d26). Fail before launching it.
    if [[ -z "$isolated_home" ]] && _act_session_is_non_interactive && \
       ! _act_runner_image_config_present "$check_home" "${act_cmd[@]}"; then
        _log_error "act has no runner image mapping: no -P/--platform flag and no actrc (~/.actrc, \${XDG_CONFIG_HOME:-~/.config}/act/actrc, ./.actrc). Non-interactive act would stop at its first-run image survey. Set act_overrides.platform_image in repos.d/<tool>.yaml, or add a line such as '-P ubuntu-latest=catthehacker/ubuntu:full-22.04' to ~/.actrc."
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

# Act's artifact server wraps uploaded files in zip containers. Native builders,
# by contrast, may publish a zip as the final release archive. Only the former
# should be opened during top-level collection; unpacking a native Windows
# archive leaks its internal `*.exe` into the release directory and makes two
# architectures collide on the shared binary name.
# Usage: act_artifact_zip_is_wrapper <method> <path>
act_artifact_zip_is_wrapper() {
    local method="${1:-}"
    local path="${2:-}"

    [[ "$method" == "act" && "$path" == *.zip ]]
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
    ACT_REPO_PUBLICATION_MODE=$(yq -r '.publication_mode // ""' "$config_file")

    export ACT_REPO_NAME ACT_REPO_GITHUB ACT_REPO_LOCAL_PATH ACT_REPO_LANGUAGE ACT_REPO_WORKFLOW ACT_REPO_PUBLICATION_MODE

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
            # A repo pins its build host per platform with
            # cross_compile.<platform>.host or the README's `hosts:` map.
            local override_host
            override_host=$(DSR_PLATFORM="$platform" yq -r '
                .cross_compile[strenv(DSR_PLATFORM)].host // .hosts[strenv(DSR_PLATFORM)] // ""
            ' "$config_file" 2>/dev/null || true)
            if [[ -n "$override_host" && "$override_host" != "null" ]]; then
                printf '%s\n' "$override_host"
                return 0
            fi
        fi
    fi

    local configured_host=""
    if declare -F config_get_host_for_platform &>/dev/null; then
        configured_host=$(config_get_host_for_platform "$platform" 2>/dev/null | tr -d '"' || true)
        # A plain `[[ ... ]] && x=` would leave the whole `if` block returning
        # non-zero on the common path, which bites the moment anything sources
        # this under `set -e`.
        if [[ "$configured_host" == "null" ]]; then
            configured_host=""
        fi
    fi

    # Spread across every host that can build this platform, preferring the one
    # named in platform_mapping. The selector drops hosts that are disabled or
    # failing health checks (5-minute cache) and scores the rest by free build
    # slots, so a second same-platform box absorbs overflow and covers the first
    # one being asleep. Any failure here falls through to the static mapping —
    # a stale health cache must never be able to block a build.
    if [[ "${DSR_DISABLE_HOST_SELECTOR:-0}" != "1" ]] && declare -F selector_choose_host &>/dev/null; then
        local selector_args=(--target "$platform")
        [[ -n "$configured_host" ]] && selector_args+=(--prefer "$configured_host")

        local selected_host
        selected_host=$(selector_choose_host "${selector_args[@]}" 2>/dev/null || true)
        if [[ -n "$selected_host" && "$selected_host" != "null" ]]; then
            printf '%s\n' "$selected_host"
            return 0
        fi
    fi

    if [[ -n "$configured_host" ]]; then
        printf '%s\n' "$configured_host"
        return 0
    fi

    # Last resort. config_get_host_for_platform also returns empty when the
    # mapped host is explicitly `enabled: false`, so re-check before handing
    # back a default the operator deliberately turned off.
    local default_host=""
    case "$platform" in
        linux/amd64|linux/arm64)
            default_host="trj"
            ;;
        darwin/arm64|darwin/amd64)
            default_host="mmini"
            ;;
        windows/amd64|windows/arm64)
            default_host="wlap"
            ;;
        *)
            echo ""
            return 1
            ;;
    esac

    if [[ -f "${DSR_HOSTS_FILE:-}" ]] && command -v yq &>/dev/null; then
        local default_enabled
        default_enabled=$(DSR_HOST="$default_host" yq -r '.hosts[strenv(DSR_HOST)].enabled' "$DSR_HOSTS_FILE" 2>/dev/null || echo null)
        if [[ "$default_enabled" == "false" ]]; then
            echo ""
            return 1
        fi
    fi

    echo "$default_host"
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
# 30 minutes: first-time syncs of repos with multi-GB tracked trees (test
# fixtures etc.) legitimately exceed 5 minutes over WAN links. A too-short
# ceiling kills healthy transfers mid-flight; rsync reports real failures
# (auth, connectivity, disk) far faster than this on its own.
_ACT_SYNC_TIMEOUT="${DSR_SYNC_TIMEOUT:-1800}"

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

_act_windows_storage_config() {
    if ! declare -F config_windows_storage_json >/dev/null; then
        source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"
    fi
    config_windows_storage_json "$1"
}

_act_windows_storage_command() {
    local host="$1" command="$2" storage status=0 initializer decoded executable=powershell
    storage=$(_act_windows_storage_config "$host") || status=$?
    if [[ $status -eq 1 ]]; then printf '%s' "$command"; return 0; fi
    [[ $status -eq 0 ]] || return 4
    # A command substitution cannot import functions into its parent shell.
    if ! declare -F config_windows_storage_session_script >/dev/null; then
        source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"
    fi
    initializer=$(config_windows_storage_session_script "$host") || return 4
    decoded=$(_act_windows_command_script "$command") || return 4
    [[ "$command" == pwsh\ * ]] && executable=pwsh
    _act_windows_encoded_powershell "$initializer"$'\n'"$decoded" "$executable"
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

# Per-host staging root for build snapshots (hosts.yaml `build_root`).
# Used for strict release snapshots and for ordinary Rust isolation roots, so
# a host whose /tmp or /var/tmp is RAM-backed or too small can point builds at
# a disk-backed directory. Prints the root and returns 0 when configured,
# returns 1 when unset, and returns 4 (after logging) when the configured
# value is unsafe: relative, containing `..`, outside the conservative path
# alphabet, or (for the local host) inside $HOME where Cargo would inherit the
# operator's configuration.
_act_get_host_build_root() {
    local host="${1:-}"
    local build_root
    build_root=$(_act_get_host_field "$host" "build_root" || true)
    [[ -n "$build_root" ]] || return 1
    build_root="${build_root%/}"
    if [[ ! "$build_root" =~ ^([A-Za-z]:)?/[A-Za-z0-9_./:+-]+$ || "$build_root" == *..* ]]; then
        _log_error "hosts.yaml build_root for $host must be an absolute path without '..' (got: $build_root)"
        return 4
    fi
    if [[ -n "${HOME:-}" && "$build_root" == "$HOME"/* ]] && _act_is_local_host "$host"; then
        _log_error "hosts.yaml build_root for local host $host must not be inside \$HOME ($HOME): $build_root"
        return 4
    fi
    printf '%s\n' "$build_root"
}

# True when the filesystem holding <dir> is RAM-backed (tmpfs/ramfs). Only
# meaningful where findmnt or GNU stat exist; elsewhere (macOS) it is false.
_act_dir_is_ram_backed() {
    local dir="${1:-}"
    local fstype
    [[ -n "$dir" ]] || return 1
    fstype=$( (findmnt -no FSTYPE -T "$dir" 2>/dev/null || stat -f -c %T "$dir" 2>/dev/null) | head -n 1)
    [[ "$fstype" == tmpfs || "$fstype" == ramfs ]]
}

# POSIX sh snippet (with trailing "; ") that aborts with exit 4 when <dir> is
# on a RAM-backed filesystem. Embedded in remote staging commands so a build
# host never stages a multi-GB source tree into RAM (issue #6: a release wave
# staged under a tmpfs /tmp and wedged the host).
_act_ram_backed_guard_sh() {
    local dir="${1:-}"
    local dir_q="${dir//\'/\'\\\'\'}"
    printf '%s' "_dsr_fstype=\$( (findmnt -no FSTYPE -T '$dir_q' 2>/dev/null || stat -f -c %T '$dir_q' 2>/dev/null) | head -n 1); case \"\$_dsr_fstype\" in tmpfs|ramfs) echo \"[dsr] refusing to stage the build under RAM-backed $dir_q (\$_dsr_fstype); set build_root for this host in hosts.yaml\" >&2; exit 4;; esac; "
}

# Decide whether a Linux Rust target gets the portable glibc floor (issue #9).
# Natively-built linux artifacts inherit the build host's glibc, and the whole
# fleet's glibc rises with OS upgrades, so a "healthy" release can silently
# stop starting on Debian/RHEL/Amazon baselines. Default: route `cargo build`
# through cargo-zigbuild with a versioned glibc target (floor 2.28 ~ RHEL 8),
# matching what linux/arm64 cross-builds already do.
#
# Inactive (rc 1) when:
#   - the platform is not linux/* or the resolved triple is not *-linux-gnu
#     (musl is already portable);
#   - the repo opts out (`linux_glibc_floor: native`, top-level or per
#     platform under cross_compile.<platform>);
#   - the build env carries its own cross toolchain for the triple
#     (CARGO_TARGET_<T>_LINKER or CC_<t>), which owns its own libc baseline;
#   - the build_cmd already drives zigbuild/xwin/cross itself.
# rc 4: invalid floor value. Otherwise prints the floor (e.g. "2.28").
# DSR_LINUX_GLIBC_FLOOR overrides the configured floor.
_act_linux_glibc_floor() {
    local tool_name="$1"
    local platform="$2"
    local config_file="$3"
    local build_env="$4"
    local build_cmd="$5"

    case "$platform" in linux/*) ;; *) return 1 ;; esac
    local triple
    triple=$(act_get_build_env_value "$build_env" "CARGO_BUILD_TARGET" 2>/dev/null || true)
    case "$triple" in *-linux-gnu) ;; *) return 1 ;; esac

    local floor="${DSR_LINUX_GLIBC_FLOOR:-}"
    if [[ -z "$floor" ]]; then
        floor=$(yq -r ".cross_compile.\"$platform\".linux_glibc_floor // .linux_glibc_floor // \"\"" \
            "$config_file" 2>/dev/null)
        [[ "$floor" == "null" ]] && floor=""
    fi
    [[ -n "$floor" ]] || floor="2.28"
    [[ "$floor" == "native" ]] && return 1
    if [[ ! "$floor" =~ ^[0-9]+\.[0-9]+$ ]]; then
        _log_error "Invalid linux_glibc_floor for $tool_name: '$floor' (use MAJOR.MINOR, e.g. \"2.28\", or \"native\")"
        return 4
    fi

    local triple_upper triple_lower
    triple_upper=$(printf '%s' "$triple" | tr '[:lower:]-.' '[:upper:]__')
    triple_lower="${triple//-/_}"
    if act_get_build_env_value "$build_env" "CARGO_TARGET_${triple_upper}_LINKER" &>/dev/null || \
       act_get_build_env_value "$build_env" "CC_${triple_lower}" &>/dev/null; then
        return 1
    fi
    case "$build_cmd" in
        *zigbuild*|*xwin*|*"cross build"*) return 1 ;;
    esac

    printf '%s\n' "$floor"
}

# The floor a collected Linux Rust artifact is held to after the build.
# Where dsr routes `cargo build` through its shim this is the applied floor.
# Where the repo's own build_cmd (zigbuild/cross) or a configured cross
# toolchain owns the libc baseline, dsr applies nothing, but an EXPLICITLY
# configured floor is still a release contract and is enforced on the bytes.
# Prints nothing when no floor applies; rc 4 on an invalid value.
_act_linux_glibc_floor_enforced() {
    local tool_name="$1"
    local platform="$2"
    local config_file="$3"
    local build_env="$4"
    local build_cmd="$5"
    local floor rc=0

    floor=$(_act_linux_glibc_floor "$tool_name" "$platform" "$config_file" \
        "$build_env" "$build_cmd") || rc=$?
    [[ $rc -eq 4 ]] && return 4
    if [[ -n "$floor" ]]; then
        printf '%s\n' "$floor"
        return 0
    fi

    case "$platform" in linux/*) ;; *) return 0 ;; esac
    local triple
    triple=$(act_get_build_env_value "$build_env" "CARGO_BUILD_TARGET" 2>/dev/null || true)
    case "$triple" in *-linux-gnu) ;; *) return 0 ;; esac
    floor="${DSR_LINUX_GLIBC_FLOOR:-}"
    if [[ -z "$floor" ]]; then
        floor=$(yq -r ".cross_compile.\"$platform\".linux_glibc_floor // .linux_glibc_floor // \"\"" \
            "$config_file" 2>/dev/null)
        [[ "$floor" == "null" ]] && floor=""
    fi
    # _act_linux_glibc_floor already rejected malformed values.
    [[ -n "$floor" && "$floor" != "native" ]] || return 0
    printf '%s\n' "$floor"
}

# The cargo shim placed first on PATH by Linux Rust builds (ordinary and
# strict) when the glibc floor is active. `cargo build` becomes `cargo
# zigbuild --target <triple>.<floor>`; every other cargo invocation passes
# through untouched. Requires cargo-zigbuild >= 0.23.0 on the build host —
# older releases hand rustc's aarch64 `--fix-cortex-a53-843419` erratum flag
# to zig unfiltered and the link fails (issue #10).
# Pure POSIX sh; reads DSR_RUST_TARGET / DSR_ZIG_TARGET / DSR_LINUX_GLIBC_FLOOR
# from the environment dsr exports for the build.
_act_zig_cargo_shim_sh() {
    cat <<'DSR_ZIG_SHIM_SCRIPT'
#!/bin/sh
# dsr cargo shim: portable glibc floor for Linux Rust release builds.
set -e
_dsr_shim_dir=${0%/*}
_dsr_clean_path=
_dsr_old_ifs=$IFS
IFS=:
for _dsr_dir in $PATH; do
  case "$_dsr_dir" in
    "$_dsr_shim_dir") ;;
    *) _dsr_clean_path="${_dsr_clean_path:+$_dsr_clean_path:}$_dsr_dir" ;;
  esac
done
IFS=$_dsr_old_ifs
PATH=$_dsr_clean_path
export PATH
_dsr_toolchain=
case "${1:-}" in
  +*) _dsr_toolchain=$1; shift ;;
esac
if [ "${1:-}" != build ] || [ -z "${DSR_ZIG_TARGET:-}" ] || [ -z "${DSR_RUST_TARGET:-}" ]; then
  if [ -n "$_dsr_toolchain" ]; then
    exec cargo "$_dsr_toolchain" "$@"
  fi
  exec cargo "$@"
fi
shift
if ! command -v cargo-zigbuild >/dev/null 2>&1 || ! command -v zig >/dev/null 2>&1; then
  echo "[dsr] portable glibc floor ${DSR_LINUX_GLIBC_FLOOR:-} needs cargo-zigbuild and zig on this build host (cargo install cargo-zigbuild); set linux_glibc_floor: native in the repo config to build against the host glibc instead" >&2
  exit 4
fi
_dsr_zb_version=$(cargo-zigbuild --version 2>/dev/null | awk "{print \$2}")
_dsr_zb_major=${_dsr_zb_version%%.*}
_dsr_zb_rest=${_dsr_zb_version#*.}
_dsr_zb_minor=${_dsr_zb_rest%%.*}
case "${_dsr_zb_major}${_dsr_zb_minor}" in
  *[!0-9]*|"") _dsr_zb_major=0; _dsr_zb_minor=0 ;;
esac
if [ "$_dsr_zb_major" -eq 0 ] && [ "$_dsr_zb_minor" -lt 23 ]; then
  echo "[dsr] cargo-zigbuild ${_dsr_zb_version:-unknown} is too old for reliable cross-linking (aarch64 --fix-cortex-a53-843419 filtering needs >= 0.23.0); run: cargo install cargo-zigbuild" >&2
  exit 4
fi
_dsr_expect_target=0
_dsr_have_target=0
_dsr_count=$#
_dsr_index=0
while [ "$_dsr_index" -lt "$_dsr_count" ]; do
  _dsr_arg=$1
  shift
  _dsr_index=$((_dsr_index + 1))
  if [ "$_dsr_expect_target" -eq 1 ]; then
    _dsr_expect_target=0
    if [ "$_dsr_arg" = "$DSR_RUST_TARGET" ]; then
      _dsr_arg=$DSR_ZIG_TARGET
    fi
    set -- "$@" "$_dsr_arg"
    continue
  fi
  case "$_dsr_arg" in
    --target)
      _dsr_have_target=1
      _dsr_expect_target=1
      set -- "$@" "$_dsr_arg"
      ;;
    --target=*)
      _dsr_have_target=1
      _dsr_value=${_dsr_arg#--target=}
      if [ "$_dsr_value" = "$DSR_RUST_TARGET" ]; then
        _dsr_value=$DSR_ZIG_TARGET
      fi
      set -- "$@" "--target=$_dsr_value"
      ;;
    *)
      set -- "$@" "$_dsr_arg"
      ;;
  esac
done
if [ "$_dsr_have_target" -ne 1 ]; then
  set -- --target "$DSR_ZIG_TARGET" "$@"
fi
if [ -n "$_dsr_toolchain" ]; then
  exec cargo "$_dsr_toolchain" zigbuild "$@"
fi
exec cargo zigbuild "$@"
DSR_ZIG_SHIM_SCRIPT
}

# Remote snippet (with trailing "; ") that materializes the cargo shim in
# <shim_dir> on the build host. Embedded into the staged-build prefix; the
# quoted heredoc delimiter keeps the script byte-exact through ssh/bash -c.
_act_zig_shim_prefix_sh() {
    local shim_dir="${1:-}"
    local shim_dir_q="${shim_dir//\'/\'\\\'\'}"
    printf '%s\n' "mkdir -p '$shim_dir_q'; cat > '$shim_dir_q/cargo' <<'DSR_ZIG_SHIM_EOF'"
    _act_zig_cargo_shim_sh
    printf '%s' "DSR_ZIG_SHIM_EOF
chmod 755 '$shim_dir_q/cargo'; "
}

# Highest NUL-delimited GLIBC_x.y[.z] version-string token in <file>. Version
# needs in an ELF live in .dynstr as exact NUL-terminated tokens, so a NUL to
# newline conversion plus a whole-line match reads them portably (no objdump
# on macOS dispatchers) without matching prose that merely mentions a
# version. Prints nothing for static (musl) or non-glibc binaries.
_act_max_glibc_version() {
    local file="${1:-}"
    [[ -f "$file" ]] || return 1
    LC_ALL=C tr '\0' '\n' < "$file" 2>/dev/null | \
        LC_ALL=C grep -E '^GLIBC_[0-9]+(\.[0-9]+){1,2}$' | \
        sed 's/^GLIBC_//' | \
        awk -F. '{ printf "%d %d %d %s\n", $1, $2, ($3 == "" ? 0 : $3), $0 }' | \
        sort -k1,1n -k2,2n -k3,3n | tail -1 | awk '{ print $4 }'
}

# _act_glibc_version_le <a> <b>: numeric dotted-version comparison, a <= b.
_act_glibc_version_le() {
    local a="${1:-}" b="${2:-}"
    awk -v a="$a" -v b="$b" 'BEGIN {
        n = split(a, x, "."); m = split(b, y, ".")
        len = (n > m) ? n : m
        for (i = 1; i <= len; i++) {
            xv = (i <= n) ? x[i] + 0 : 0
            yv = (i <= m) ? y[i] + 0 : 0
            if (xv < yv) exit 0
            if (xv > yv) exit 1
        }
        exit 0
    }'
}

# Post-collection gate for ordinary native builds: the artifact must actually
# be an executable of the requested platform (issue #7 — the strict release
# path already validates this via _act_stage_contract_primary), and when the
# glibc floor was active it must not need a newer glibc than the floor
# (issue #9 — a floor that silently rises with the build host is exactly the
# defect the floor exists to stop). Only compiled languages are checked.
_act_accept_collected_binary() {
    local path="$1"
    local platform="$2"
    local language="$3"
    local glibc_floor="${4:-}"

    case "$language" in rust|go) ;; *) return 0 ;; esac
    case "$platform" in
        linux/amd64|linux/arm64|darwin/amd64|darwin/arm64|windows/amd64|windows/arm64) ;;
        *) return 0 ;;
    esac

    if ! _act_validate_target_binary "$path" "$platform"; then
        _log_error "Collected artifact is not a $platform executable: $path (the build host produced the wrong architecture; refusing to package it)"
        return 1
    fi

    _act_collected_glibc_within_floor "$path" "$glibc_floor"
}

# A Linux artifact must not need a newer glibc than its floor (issue #9 — a
# floor that silently rises with the build host is exactly the defect the
# floor exists to stop). Shared by ordinary and strict collection. An empty
# floor, or a static/non-glibc binary, always passes.
_act_collected_glibc_within_floor() {
    local path="$1"
    local glibc_floor="${2:-}"
    [[ -n "$glibc_floor" ]] || return 0

    local max_glibc
    max_glibc=$(_act_max_glibc_version "$path" || true)
    if [[ -n "$max_glibc" ]] && ! _act_glibc_version_le "$max_glibc" "$glibc_floor"; then
        _log_error "Collected artifact needs GLIBC_$max_glibc, above the glibc floor $glibc_floor: $path. Refusing to ship a binary that will not start on older distributions. A plain \`cargo build\` is routed through \`cargo zigbuild --target <triple>.$glibc_floor\` automatically; a build_cmd or cross linker that owns its toolchain must honor the floor itself. Set linux_glibc_floor: native in the repo config only to accept the build host's glibc deliberately."
        return 1
    fi
    return 0
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

# Emit the copy operation used for fresh Windows Rust staging directories.
# Copy links themselves, preserve empty directories, and never purge either tree.
# A fresh destination permits only Robocopy's unchanged/copied success statuses;
# extras and mismatches are rejected along with ordinary copy failures.
_act_windows_source_copy_function() {
    cat <<'POWERSHELL'
function Copy-DsrSourceTree {
    param([string]$SourcePath, [string]$DestinationPath)
    & robocopy.exe $SourcePath $DestinationPath /E /COPY:DAT /DCOPY:DAT /R:0 /W:0 /MT:8 /SL /SJ /NFL /NDL /NJH /NJS /NP
    if ($LASTEXITCODE -notin @(0, 1)) {
        throw ("Rust source copy did not produce a clean replica (robocopy exit {0})" -f $LASTEXITCODE)
    }
}
POWERSHELL
}

# Encode a PowerShell script for `-EncodedCommand` (UTF-16LE, base64).
#
# Windows hosts run OpenSSH with PowerShell as the login shell, so a command
# sent as `powershell -Command "..."` is parsed by that outer PowerShell first:
# every `$variable` inside the double quotes is expanded (to nothing) before
# the inner powershell ever sees the script, which is why generated scripts
# failed within seconds with "Missing variable name" parse errors. An encoded
# command has no quoting layer for any shell (bash, ssh, cmd, or PowerShell)
# to disturb, so the script arrives byte-exact.
_act_windows_encoded_powershell() {
    local script="$1" executable="${2:-powershell}" encoded payload compressed wrapper
    case "$executable" in powershell|pwsh) ;; *) return 4 ;; esac
    if ! command -v iconv >/dev/null 2>&1 || ! command -v base64 >/dev/null 2>&1; then
        _log_error "iconv and base64 are required to encode a Windows PowerShell command"
        return 3
    fi
    # Progress records would otherwise reach stderr as CLIXML noise over ssh.
    payload="\$ProgressPreference='SilentlyContinue'; $script"
    encoded=$(printf '%s' "$payload" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\r\n') || return 4
    # Windows shell launchers can truncate commands at 8191 characters. Keep
    # headroom for the executable/options and transport wrapper. Compression
    # preserves the original script bytes, including newlines and UTF-8 text.
    if [[ ${#encoded} -gt 7000 ]]; then
        if ! command -v gzip >/dev/null 2>&1; then
            _log_error "gzip is required to transport a large Windows PowerShell command"
            return 3
        fi
        compressed=$(printf '%s' "$payload" | gzip -n -c | base64 | tr -d '\r\n') || return 4
        wrapper="\$DSRScriptGzip='$compressed'; try { \$DSRScriptMemory=[IO.MemoryStream]::new([Convert]::FromBase64String(\$DSRScriptGzip)); \$DSRScriptReader=[IO.StreamReader]::new([IO.Compression.GZipStream]::new(\$DSRScriptMemory,[IO.Compression.CompressionMode]::Decompress),[Text.Encoding]::UTF8); try { \$DSRScriptText=\$DSRScriptReader.ReadToEnd() } finally { \$DSRScriptReader.Dispose() }; & ([ScriptBlock]::Create(\$DSRScriptText)) } catch { throw }"
        encoded=$(printf '%s' "$wrapper" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\r\n') || return 4
        if [[ ${#encoded} -gt 7000 ]]; then
            # Avoid encoding the already-base64 payload a second time. This
            # fixed expression has no shell expansions: the only substituted
            # value is base64, never source text. Double quotes protect its
            # operators from cmd/Bash; PowerShell has no variables to expand.
            # The reader is process-local and exits with this one-shot host.
            wrapper="& ([ScriptBlock]::Create([IO.StreamReader]::new([IO.Compression.GZipStream]::new([IO.MemoryStream]::new([Convert]::FromBase64String('$compressed')),[IO.Compression.CompressionMode]::Decompress),[Text.Encoding]::UTF8).ReadToEnd()))"
            wrapper="$executable -NoProfile -NonInteractive -Command \"$wrapper\""
            if [[ ${#wrapper} -gt 7000 ]]; then
                _log_error "Windows PowerShell command exceeds the transport limit after compression"
                return 4
            fi
            printf '%s' "$wrapper"
            return 0
        fi
    fi
    printf '%s -NoProfile -NonInteractive -EncodedCommand %s' "$executable" "$encoded"
}

# Run a cmd.exe command line on a Windows host regardless of the OpenSSH login
# shell (cmd.exe or PowerShell). The line travels base64-encoded inside an
# -EncodedCommand PowerShell wrapper that hands it to `cmd.exe /d /s /c`
# verbatim and propagates the exit code, so cmd semantics the callers rely on
# (`&&`, `set "VAR="`, `if not exist`, junction-safe `rmdir /s /q`) survive
# without any shell re-parsing the quotes.
_act_windows_cmd_via_powershell() {
    local cmd_line="$1" b64
    if ! command -v base64 >/dev/null 2>&1; then
        _log_error "base64 is required to wrap a Windows cmd.exe command"
        return 3
    fi
    b64=$(printf '%s' "$cmd_line" | base64 | tr -d '\r\n') || return 4
    _act_windows_encoded_powershell "\$ErrorActionPreference='Stop'; \$c=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${b64}')); \$psi=New-Object System.Diagnostics.ProcessStartInfo; \$psi.FileName=\$env:ComSpec; \$psi.Arguments='/d /s /c \"' + \$c + '\"'; \$psi.UseShellExecute=\$false; \$p=[System.Diagnostics.Process]::Start(\$psi); \$p.WaitForExit(); exit \$p.ExitCode"
}

# The supervisor stays outside its unnamed kill-on-close job. Create the build
# suspended, assign it before any code can spawn children, and only then resume
# it. Closing the supervisor's non-inheritable handle retires all descendants
# without changing the supervisor's own exit code.
_act_windows_build_guard_script() {
    local timeout_sec="${1:-$_ACT_BUILD_TIMEOUT}"
    local script="${2:?Windows build script required}" script_quoted
    if [[ ! "$timeout_sec" =~ ^[1-9][0-9]{0,6}$ ]] || (( timeout_sec > 2147483 )); then
        _log_error "Windows build timeout must be 1..2147483 seconds"
        return 4
    fi
    script_quoted="${script//\'/\'\'}"
    cat <<'POWERSHELL'
$ErrorActionPreference='Stop'
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
public static class DSRNativeBuildGuard {
    [StructLayout(LayoutKind.Sequential)] struct BasicLimits {
        public long ProcessTime, JobTime;
        public uint Flags;
        public UIntPtr MinimumWorkingSet, MaximumWorkingSet;
        public uint ActiveProcesses;
        public UIntPtr Affinity;
        public uint Priority, Scheduling;
    }
    [StructLayout(LayoutKind.Sequential)] struct IoCounters {
        public ulong ReadOperations, WriteOperations, OtherOperations;
        public ulong ReadBytes, WriteBytes, OtherBytes;
    }
    [StructLayout(LayoutKind.Sequential)] struct ExtendedLimits {
        public BasicLimits Basic;
        public IoCounters Io;
        public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
    }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] struct StartupInfo {
        public uint Size;
        public string Reserved, Desktop, Title;
        public uint X, Y, Width, Height, XChars, YChars, Fill, Flags;
        public ushort Show, ReservedCount;
        public IntPtr ReservedBytes, Input, Output, Error;
    }
    [StructLayout(LayoutKind.Sequential)] struct ProcessInfo {
        public IntPtr Process, Thread;
        public uint ProcessId, ThreadId;
    }
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool SetInformationJobObject(IntPtr job, int kind,
        ref ExtendedLimits limits, uint length);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool TerminateJobObject(IntPtr job, uint code);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool TerminateProcess(IntPtr process, uint code);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern uint ResumeThread(IntPtr thread);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetExitCodeProcess(IntPtr process, out uint code);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern IntPtr GetStdHandle(int kind);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool CreateProcess(string application, StringBuilder command,
        IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles,
        uint flags, IntPtr environment, string directory,
        ref StartupInfo startup, out ProcessInfo process);
    static IntPtr InheritableStandardHandle(int kind) {
        IntPtr handle = GetStdHandle(kind);
        if (handle == IntPtr.Zero || handle == new IntPtr(-1) ||
                !SetHandleInformation(handle, 1, 1))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        return handle;
    }
    public static int Run(string command, int seconds) {
        uint milliseconds = checked((uint)seconds * 1000);
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        ProcessInfo process = new ProcessInfo();
        try {
            ExtendedLimits limits = new ExtendedLimits();
            limits.Basic.Flags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            if (!SetInformationJobObject(job, 9, ref limits,
                    (uint)Marshal.SizeOf(typeof(ExtendedLimits))))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            StartupInfo startup = new StartupInfo();
            startup.Size = (uint)Marshal.SizeOf(typeof(StartupInfo));
            startup.Flags = 0x100; // STARTF_USESTDHANDLES
            startup.Input = InheritableStandardHandle(-10);
            startup.Output = InheritableStandardHandle(-11);
            startup.Error = InheritableStandardHandle(-12);
            if (!CreateProcess(null, new StringBuilder(command), IntPtr.Zero,
                    IntPtr.Zero, true, 4, IntPtr.Zero, null, ref startup, out process))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            if (!AssignProcessToJobObject(job, process.Process))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            if (ResumeThread(process.Thread) == UInt32.MaxValue)
                throw new Win32Exception(Marshal.GetLastWin32Error());
            uint waited = WaitForSingleObject(process.Process, milliseconds);
            if (waited == 258) {
                if (!TerminateJobObject(job, 124))
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                if (WaitForSingleObject(process.Process, 60000) != 0)
                    throw new InvalidOperationException("Timed-out build did not terminate");
                return 124;
            }
            if (waited != 0) throw new Win32Exception(Marshal.GetLastWin32Error());
            uint code;
            if (!GetExitCodeProcess(process.Process, out code))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            return unchecked((int)code);
        } finally {
            // This also covers assignment failure: the suspended child must
            // not survive just because it never entered the job.
            if (process.Process != IntPtr.Zero) {
                TerminateProcess(process.Process, 1);
                CloseHandle(process.Process);
            }
            if (process.Thread != IntPtr.Zero) CloseHandle(process.Thread);
            CloseHandle(job);
        }
    }
}
'@
POWERSHELL
    # Keep the original source visible in the staged Defender-scanned file.
    # Encoding is only for the child command-line transport after admission.
    printf '$dsrBuildScript='\''%s'\''\n' "$script_quoted"
    cat <<'POWERSHELL'
$dsrBuildEncoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($dsrBuildScript))
$dsrPowerShell=Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path -LiteralPath $dsrPowerShell -PathType Leaf)) { $dsrPowerShell=Join-Path $PSHOME 'pwsh.exe' }
$dsrBuildCommand='"' + $dsrPowerShell + '" -NoProfile -NonInteractive -EncodedCommand ' + $dsrBuildEncoded
POWERSHELL
    printf 'exit [DSRNativeBuildGuard]::Run($dsrBuildCommand, %s)\n' "$timeout_sec"
}

# Recover only command forms produced above; never evaluate launcher text.
_act_windows_command_script() {
    local command="$1" encoded decoded compressed
    case "$command" in
        powershell\ -NoProfile\ -NonInteractive\ -EncodedCommand\ *|pwsh\ -NoProfile\ -NonInteractive\ -EncodedCommand\ *)
            encoded="${command##*-EncodedCommand }"
            [[ "$encoded" =~ ^[A-Za-z0-9+/=]+$ ]] || return 4
            decoded=$(printf '%s' "$encoded" | base64 -d | iconv -f UTF-16LE -t UTF-8) || return 4
            if [[ "$decoded" != "\$DSRScriptGzip='"* ]]; then
                printf '%s' "$decoded"
                return 0
            fi
            compressed="${decoded#\$DSRScriptGzip=\'}"
            compressed="${compressed%%\'*}"
            ;;
        powershell\ -NoProfile\ -NonInteractive\ -Command\ *|pwsh\ -NoProfile\ -NonInteractive\ -Command\ *)
            [[ "$command" == *'-Command "& ([ScriptBlock]::Create([IO.StreamReader]::new('* ]] || return 4
            compressed="${command#*FromBase64String(\'}"
            compressed="${compressed%%\'*}"
            ;;
        *) return 4 ;;
    esac
    [[ "$compressed" =~ ^[A-Za-z0-9+/=]+$ ]] || return 4
    printf '%s' "$compressed" | base64 -d | gzip -dc
}

# Keep native build code as an inspectable file rather than a compressed
# in-memory launcher. Retain it outside the immutable source tree. Windows
# file sharing pins the verified bytes against writes/deletion during execution.
_act_windows_stage_build_script() {
    local host="$1" source_root="$2" script="$3"
    local destination uuid local_dir local_script remote_dir remote_script digest setup guard
    destination=$(_act_get_ssh_destination "$host") || return 4
    uuid=$(_act_generate_uuid) || return 4
    _act_is_uuid "$uuid" || return 4
    source_root="${source_root//\\//}"
    [[ "$source_root" =~ ^[A-Za-z]:/ && "$source_root" != *"'"* ]] || return 4
    remote_dir="${source_root%/*}/launcher-$uuid"
    remote_script="$remote_dir/build.ps1"
    mkdir -p "$ACT_ARTIFACTS_DIR" || return 4
    local_dir=$(mktemp -d "$ACT_ARTIFACTS_DIR/windows-launcher.XXXXXXXX") || return 4
    local_script="$local_dir/build.ps1"
    (umask 077; printf '%s\n' "$script" > "$local_script") || return 4
    digest=$(_act_sha256 "$local_script") || return 4
    setup="\$ErrorActionPreference='Stop'; \$parent=Get-Item -LiteralPath '${source_root%/*}' -Force; if (-not \$parent.PSIsContainer -or ((\$parent.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'Launcher parent is not a plain directory' }; if (Test-Path -LiteralPath '$remote_dir') { throw 'Launcher destination already exists' }; New-Item -ItemType Directory -Path '$remote_dir' | Out-Null; \$acl=Get-Acl -LiteralPath '$remote_dir'; \$acl.SetAccessRuleProtection(\$true,\$false); \$user=[Security.Principal.WindowsIdentity]::GetCurrent().User; \$rule=[Security.AccessControl.FileSystemAccessRule]::new(\$user,'FullControl','ContainerInherit,ObjectInherit','None','Allow'); \$acl.AddAccessRule(\$rule); Set-Acl -LiteralPath '$remote_dir' -AclObject \$acl"
    setup+="; \$system=[Security.Principal.SecurityIdentifier]::new('S-1-5-18'); \$systemRule=[Security.AccessControl.FileSystemAccessRule]::new(\$system,'FullControl','ContainerInherit,ObjectInherit','None','Allow'); \$acl.AddAccessRule(\$systemRule); Set-Acl -LiteralPath '$remote_dir' -AclObject \$acl"
    _act_ssh_exec "$host" "$(_act_windows_encoded_powershell "$setup" pwsh)" 60 >&2 || return 4
    scp -q -o ConnectTimeout="$_ACT_SSH_TIMEOUT" -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new "$local_script" "$destination:$remote_script" >&2 || return 4
    # A normal custom scan retains Defender policy; no exclusion, policy
    # bypass, or restoration of quarantined content is permitted here.
    guard="\$ErrorActionPreference='Stop'; \$item=Get-Item -LiteralPath '$remote_script' -Force; if (\$item.PSIsContainer -or ((\$item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'Launcher is not a plain file' }; \$scanner=Join-Path \$env:ProgramFiles 'Windows Defender/MpCmdRun.exe'; if (Test-Path -LiteralPath \$scanner) { & \$scanner -Scan -ScanType 3 -File \$item.FullName; if (\$LASTEXITCODE -ne 0) { throw 'Launcher security scan failed' } }; \$held=[IO.File]::Open('$remote_script',[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read); try { \$actual=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(\$held)); if (\$actual -ne '$digest') { throw 'Launcher digest mismatch' }; & '$remote_script'; exit \$LASTEXITCODE } finally { \$held.Dispose() }"
    _log_info "Windows build script retained: $local_script (sha256=$digest), host path $remote_script"
    _act_windows_encoded_powershell "$guard" pwsh
}

# Use a physically shallow output root: MSVC expands NTFS short names while
# resolving nested includes, so a short spelling of a deep root is insufficient.
# The full run UUID and a checked marker bind this directory to one source run.
# Existing output trees are retained; this helper never moves or deletes them.
_act_windows_short_target_directory() {
    local host="$1" path="$2" run_id="$3" platform="$4" script short result
    [[ "$path" =~ ^[A-Za-z]:/[A-Za-z0-9_./+-]+$ && "$path" != *..* ]] || return 4
    _act_is_uuid "$run_id" || return 4
    [[ "$platform" == windows/amd64 || "$platform" == windows/arm64 ]] || return 4
    short="${path:0:2}/d/t/$run_id/${platform#windows/}"
    local storage storage_status=0
    storage=$(_act_windows_storage_config "$host") || storage_status=$?
    [[ $storage_status -eq 0 || $storage_status -eq 1 ]] || return 4
    if [[ $storage_status -eq 0 ]]; then
        [[ "${path:0:1}" == "$(jq -r '.source_drive' <<< "$storage")" ]] || return 4
        short="$(jq -r '.drive' <<< "$storage"):/d/t/$run_id/${platform#windows/}"
    fi
    script="\$ErrorActionPreference='Stop'; \$root='${short:0:2}/'; foreach (\$part in @('d','t','$run_id')) { \$root=Join-Path \$root \$part; if (-not (Test-Path -LiteralPath \$root)) { New-Item -ItemType Directory -Path \$root | Out-Null }; \$item=Get-Item -LiteralPath \$root -Force; if (-not \$item.PSIsContainer -or ((\$item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'Cargo target ancestor is not a plain directory' } }; \$created=\$false; if (-not (Test-Path -LiteralPath '$short')) { New-Item -ItemType Directory -Path '$short' | Out-Null; \$created=\$true }; \$item=Get-Item -LiteralPath '$short' -Force; if (-not \$item.PSIsContainer -or ((\$item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'Cargo target is not a plain directory' }; \$marker=Join-Path \$item.FullName '.dsr-source-target'; if (\$created) { [IO.File]::WriteAllText(\$marker,'$path',[Text.UTF8Encoding]::new(\$false)) }; \$file=Get-Item -LiteralPath \$marker -Force; if (\$file.PSIsContainer -or ((\$file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) -or [IO.File]::ReadAllText(\$marker) -cne '$path') { throw 'Cargo target source identity mismatch' }; \$ancestor=\$item; while (\$null -ne \$ancestor) { foreach (\$name in @('config','config.toml')) { if (Test-Path -LiteralPath (Join-Path \$ancestor.FullName ('.cargo/'+\$name))) { throw 'Cargo target ancestor configuration is forbidden' } }; \$ancestor=\$ancestor.Parent }; Write-Output '$short'"
    if [[ $storage_status -eq 0 ]]; then
        script+="; \$scratch=Join-Path '$short' 'scratch'; if (-not (Test-Path -LiteralPath \$scratch)) { New-Item -ItemType Directory -Path \$scratch | Out-Null }; \$scratchItem=Get-Item -LiteralPath \$scratch -Force; if (-not \$scratchItem.PSIsContainer -or ((\$scratchItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'Build scratch is not a plain directory' }"
    fi
    result=$(_act_ssh_exec "$host" "$(_act_windows_encoded_powershell "$script" pwsh)" 60) || return 4
    result="${result//$'\r'/}"
    [[ "$result" == "$short" ]] || return 4
    printf '%s' "$short"
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

# Ensure a remote directory (and all of its parent components) exists before we
# write into it. rsync does NOT create intermediate parent directories of the
# destination, so syncing to e.g. `release-work/<tool>-<version>/<repo>` fails
# outright when the `<tool>-<version>` parent has not been created yet. The
# local-host and tar-fallback sync paths already `mkdir -p`; this gives the
# remote-rsync path the same guarantee.
# Usage: _act_remote_mkdir <host> <remote_path>
# Returns: 0 on success, 1 on failure
_act_remote_mkdir() {
    local host="$1"
    local remote_path="$2"
    local ssh_destination
    ssh_destination=$(_act_get_ssh_destination "$host") || return 1
    local ssh_opts=(-o "ConnectTimeout=$_ACT_SSH_TIMEOUT" -o StrictHostKeyChecking=accept-new)

    if _act_is_windows_host "$host"; then
        # cmd.exe: `mkdir` creates intermediate dirs; guard with `if not exist`.
        local win_path
        win_path=$(_act_windows_cmd_path "$remote_path")
        ssh "${ssh_opts[@]}" "$ssh_destination" \
            "$(_act_windows_cmd_via_powershell "if not exist \"$win_path\" mkdir \"$win_path\"")" >/dev/null 2>&1
    else
        ssh "${ssh_opts[@]}" "$ssh_destination" \
            "mkdir -p '${remote_path//\'/\'\\\'\'}'" >/dev/null 2>&1
    fi
}

_act_has_rsync() {
    local host="$1"
    local ssh_destination=""
    local probe_cmd='command -v rsync >/dev/null 2>&1'
    if _act_is_windows_host "$host"; then
        probe_cmd=$(_act_windows_cmd_via_powershell 'where rsync >NUL 2>&1') || return 4
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

# Report a failed sync command with its real diagnostics instead of a generic
# one-liner. Distinguishes the timeout wrapper's exit 124 from tool errors and
# forwards the command's captured stdout+stderr to our stderr log stream so
# callers (and the top-level build command) can show the underlying cause.
# Usage: _act_log_sync_failure <label> <exit_code> <output>
_act_log_sync_failure() {
    local label="$1"
    local exit_code="$2"
    local output="$3"

    if [[ "$exit_code" -eq 124 ]]; then
        _log_error "$label timed out after ${_ACT_SYNC_TIMEOUT}s"
    else
        _log_error "$label failed (exit $exit_code)"
    fi
    if [[ -n "$output" ]]; then
        printf '%s\n' "$output" >&2
    fi
}

# Reduce a captured sync transcript to a short single-line error summary
# suitable for embedding in the per-host JSON results (last non-empty lines,
# ANSI color codes stripped).
# Usage: _act_sync_error_summary <output>
_act_sync_error_summary() {
    local output="$1"
    local esc=$'\x1b'
    printf '%s\n' "$output" \
        | sed -e "s/${esc}\[[0-9;]*m//g" \
        | grep -v '^[[:space:]]*$' \
        | tail -n 5 \
        | paste -sd' ' -
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
    # The global git excludes file participates in ignore decisions exactly
    # like the repo .gitignore, so honor it too — machine-wide build dirs
    # (e.g. .codex-target) are often ignored only there, and missing them
    # means shipping tens of GB of build artifacts to every host.
    if $respect_gitignore_excludes; then
        if [[ -f "$local_path/.gitignore" ]]; then
            exclude_args+=("--exclude-from=$local_path/.gitignore")
        fi
        local global_excludes_file
        global_excludes_file=$(git config --path --get core.excludesFile 2>/dev/null || true)
        if [[ -z "$global_excludes_file" ]]; then
            global_excludes_file="${XDG_CONFIG_HOME:-$HOME/.config}/git/ignore"
        fi
        # gitignore negations don't translate to rsync excludes (a bare "!"
        # even resets rsync's rule list), so skip the global file entirely if
        # it uses them rather than mis-applying its patterns.
        if [[ -f "$global_excludes_file" ]] && \
           ! grep -q '^!' "$global_excludes_file" 2>/dev/null; then
            exclude_args+=("--exclude-from=$global_excludes_file")
        fi
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
        local sync_cmd_output sync_cmd_status
        # Equal size and timestamp do not prove equal source bytes (for
        # example, rapid checkouts or restored timestamps). A successful sync
        # must replace those stale files before the host becomes buildable.
        sync_cmd_output=$(_act_run_with_timeout "$_ACT_SYNC_TIMEOUT" rsync -az --checksum --delete \
            "${exclude_args[@]}" \
            "$local_path/" "$remote_path/" 2>&1)
        sync_cmd_status=$?
        if [[ "$sync_cmd_status" -eq 0 ]]; then
            local duration=$(($(date +%s) - start_time))
            _log_ok "Sync completed in ${duration}s (local rsync)"
            return 0
        fi

        _act_log_sync_failure "local rsync" "$sync_cmd_status" "$sync_cmd_output"
        return 1
    fi

    local ssh_destination
    ssh_destination=$(_act_get_ssh_destination "$host") || return 4

    # Check for rsync on remote
    if _act_has_rsync "$host"; then
        # rsync does not create the destination's parent directories, so make
        # sure the full remote path exists first (mirrors the local-host and
        # tar-fallback branches). Without this, a missing per-version parent dir
        # makes the whole sync fail with "No such file or directory".
        if ! _act_remote_mkdir "$host" "$remote_path"; then
            _log_error "failed to create remote directory $remote_path on $host"
            return 1
        fi

        local rsync_remote_path="$remote_path"
        local -a rsync_io_opts=()
        local rsync_transport="ssh -o ConnectTimeout=$_ACT_SSH_TIMEOUT -o StrictHostKeyChecking=accept-new"
        if _act_is_windows_host "$host"; then
            rsync_remote_path=$(_act_windows_rsync_path "$remote_path")
            # Windows OpenSSH plus rsync's non-blocking socket writes fail with
            # "safe_write ... Resource temporarily unavailable (11)" (exit 12)
            # when the transport is a multiplexed ControlMaster channel. Use
            # blocking I/O on a dedicated connection for Windows receivers.
            rsync_io_opts=(--blocking-io)
            rsync_transport+=" -o ControlMaster=no -o ControlPath=none"
        fi

        # Use rsync for efficient sync. Windows receivers still drop the
        # stream intermittently (exit 12, EAGAIN in the Windows rsync port),
        # typically when another ssh session to the host is active; rsync is
        # idempotent, so retry a bounded number of times before giving up.
        local sync_cmd_output sync_cmd_status
        local sync_attempt sync_attempts=1
        if _act_is_windows_host "$host"; then
            sync_attempts=3
        fi
        for (( sync_attempt = 1; sync_attempt <= sync_attempts; sync_attempt++ )); do
            sync_cmd_output=$(_act_run_with_timeout "$_ACT_SYNC_TIMEOUT" rsync -az --checksum --delete \
                "${rsync_io_opts[@]}" \
                "${exclude_args[@]}" \
                -e "$rsync_transport" \
                "$local_path/" "$ssh_destination:$rsync_remote_path/" 2>&1)
            sync_cmd_status=$?
            if [[ "$sync_cmd_status" -ne 12 || "$sync_attempt" -ge "$sync_attempts" ]]; then
                break
            fi
            _log_warn "rsync to $host dropped the stream (exit 12); retrying ($sync_attempt/$sync_attempts)"
            sleep 3
        done
        if [[ "$sync_cmd_status" -eq 0 ]]; then
            local duration=$(($(date +%s) - start_time))
            _log_ok "Sync completed in ${duration}s (rsync)"
            return 0
        else
            _act_log_sync_failure "rsync to $host" "$sync_cmd_status" "$sync_cmd_output"
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

        # Create remote directory and extract. Windows OpenSSH hands the remote
        # command to cmd.exe, so POSIX `%q` escaping is invalid there. Pass one
        # validated cmd command as a single ssh argument instead.
        local mkdir_cmd remote_extract_cmd
        if _act_is_windows_host "$host"; then
            local win_path
            win_path=$(_act_windows_cmd_path "$remote_path")
            if [[ ! "$win_path" =~ ^[A-Za-z]:\\[A-Za-z0-9_.\\-]+$ ]]; then
                _log_error "tar fallback requires a metacharacter-free Windows path: $remote_path"
                return 4
            fi
            if ! _act_remote_mkdir "$host" "$remote_path"; then
                _log_error "failed to create remote directory $remote_path on $host"
                return 1
            fi
            # Invoke bsdtar directly. Wrapping this in `cmd /c` can detach the
            # extractor from OpenSSH's stdin when the destination already
            # exists, making the sender fail with a misleading Write error.
            remote_extract_cmd="tar xzf - -C $remote_path"
        else
            mkdir_cmd="mkdir -p \"$remote_path\" && cd \"$remote_path\""
            remote_extract_cmd="$mkdir_cmd && tar xzf -"
        fi

        local sync_cmd_output sync_cmd_status
        sync_cmd_output=$(
            set -o pipefail
            {
                {
                    if $respect_gitignore_excludes &&
                       git -C "$local_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
                        git -C "$local_path" ls-files --cached --others --exclude-standard -z |
                            COPYFILE_DISABLE=1 tar -czf - -C "$local_path" \
                                "${tar_excludes[@]}" --null -T -
                    else
                        cd "$local_path" &&
                            COPYFILE_DISABLE=1 tar czf - "${tar_excludes[@]}" .
                    fi
                } |
                    _act_run_with_timeout "$_ACT_SYNC_TIMEOUT" ssh \
                        -o ConnectTimeout="$_ACT_SSH_TIMEOUT" \
                        -o StrictHostKeyChecking=accept-new \
                        "$ssh_destination" "$remote_extract_cmd"
            } 2>&1
        )
        sync_cmd_status=$?
        if [[ "$sync_cmd_status" -eq 0 ]]; then
            local duration=$(($(date +%s) - start_time))
            _log_ok "Sync completed in ${duration}s (tar)"
            return 0
        else
            _act_log_sync_failure "tar fallback sync to $host" "$sync_cmd_status" "$sync_cmd_output"
            return 1
        fi
    fi
}

# Fresh source root for a strict release snapshot. Precedence for the root:
# DSR_STRICT_BUILD_ROOT (operator/CI override) > hosts.yaml build_root for the
# host > /var/tmp (POSIX) or <drive>:/Users/Public (Windows). Never /tmp: on
# many Linux hosts it is a RAM-backed tmpfs, and a snapshot plus its Cargo
# target can run to tens of GB.
_act_strict_source_root_path() {
    local configured_path="$1"
    local tool_name="$2"
    local run_id="$3"
    local host="${4:-}"
    local strict_root host_build_root="" host_build_root_rc=0

    if [[ ! "$configured_path" =~ ^[A-Za-z0-9_./:+-]+$ || "$configured_path" == *..* ]] || \
       ! _act_is_safe_basename "$tool_name" || ! _act_is_uuid "$run_id"; then
        return 4
    fi
    if [[ -n "$host" ]]; then
        host_build_root=$(_act_get_host_build_root "$host") || host_build_root_rc=$?
        [[ "$host_build_root_rc" -ne 4 ]] || return 4
    fi
    if [[ -n "${DSR_STRICT_BUILD_ROOT:-}" ]]; then
        strict_root="${DSR_STRICT_BUILD_ROOT%/}"
        if [[ ! "$strict_root" =~ ^([A-Za-z]:)?/[A-Za-z0-9_./:+-]+$ || \
              "$strict_root" == *..* || \
              ( -n "${HOME:-}" && "$strict_root" == "$HOME"/* ) ]]; then
            return 4
        fi
    elif [[ -n "$host_build_root" ]]; then
        strict_root="$host_build_root/.dsr-release-snapshots"
    elif [[ "$configured_path" =~ ^[A-Za-z]:/ ]]; then
        strict_root="${configured_path:0:2}/Users/Public/.dsr-release-snapshots"
    elif [[ "$configured_path" == /* ]]; then
        strict_root="/var/tmp/.dsr-release-snapshots"
    else
        return 4
    fi
    printf '%s/%s-%s/source\n' "$strict_root" "$tool_name" "$run_id"
}

_act_git_archive_sha256() {
    local repo_path="$1"
    local revision="$2"

    if command -v sha256sum &>/dev/null; then
        _act_strict_git -C "$repo_path" archive --format=tar "$revision" 2>/dev/null | sha256sum | awk '{print $1}'
    elif command -v shasum &>/dev/null; then
        _act_strict_git -C "$repo_path" archive --format=tar "$revision" 2>/dev/null | shasum -a 256 | awk '{print $1}'
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
        _act_strict_git -C "$repo_path" archive --format=tar "$revision" >&9 2>/dev/null || exit 4
        chmod 600 /dev/fd/9 || exit 4
        path_inode=$(_act_file_identity "$output_file") || exit 4
        [[ -s /dev/fd/9 && -f "$output_file" && ! -L "$output_file" && \
           "$descriptor_inode" == "$path_inode" ]] || exit 4
        exec 9>&-
    )
}

# A tracked symlink (mode 120000) is representable only when its target is a
# safe relative path that stays inside the repository. Check each component
# before processing '..': a symlink component can change what its parent means.
# Chained links are conservatively refused. The target string is the blob.
_act_strict_symlink_target_is_contained() {
    local root_path="${1%/}"
    local link_path="$2"
    local target="$3"
    local component cursor="$root_path"
    local -a parts=()

    [[ -n "$root_path" && -d "$root_path" && ! -L "$root_path" && \
       "$link_path" != /* && "$link_path" != *..* && \
       -n "$target" && "$target" != /* && \
       "$target" =~ ^[][A-Za-z0-9_./+@~#,=()\ -]+$ ]] || return 1
    if [[ "$link_path" == */* ]]; then
        IFS='/' read -r -a parts <<< "${link_path%/*}"
        for component in "${parts[@]}"; do
            [[ -z "$component" || "$component" == "." ]] && continue
            cursor="$cursor/$component"
            [[ -d "$cursor" && ! -L "$cursor" ]] || return 1
        done
    fi
    IFS='/' read -r -a parts <<< "$target"
    for component in "${parts[@]}"; do
        case "$component" in
            ""|.) ;;
            ..)
                [[ "$cursor" != "$root_path" ]] || return 1
                cursor="${cursor%/*}"
                ;;
            *)
                cursor="$cursor/$component"
                [[ ! -L "$cursor" ]] || return 1
                ;;
        esac
    done
    return 0
}

# The checkout's link must be a symlink whose target equals the committed blob.
_act_strict_symlink_is_representable() {
    local repo_path="$1"
    local path="$2"
    local object_id="$3"
    local committed_target

    [[ -L "$repo_path/$path" ]] || return 1
    committed_target=$(_act_strict_git -C "$repo_path" cat-file blob "$object_id" 2>/dev/null) || return 1
    [[ "$(readlink "$repo_path/$path")" == "$committed_target" ]] || return 1
    _act_strict_symlink_target_is_contained "$repo_path" "$path" "$committed_target"
}

_act_write_tracked_manifest() {
    local repo_path="$1"
    local revision="$2"
    local output_file="$3"
    (
        local metadata path mode object_type object_id descriptor_inode path_inode
        local kind
        set -C
        umask 077
        exec 9> "$output_file" || exit 4
        descriptor_inode=$(_act_file_identity /dev/fd/9) || exit 4
        while IFS=$'\t' read -r metadata path; do
            [[ -n "$metadata" && -n "$path" ]] || continue
            read -r mode object_type object_id <<< "$metadata"
            kind=""
            if [[ "$object_type" == "blob" && ( "$mode" == "100644" || "$mode" == "100755" ) ]]; then
                kind="file"
            elif [[ "$object_type" == "commit" && "$mode" == "160000" ]]; then
                kind="gitlink"
            elif [[ "$object_type" == "blob" && "$mode" == "120000" ]]; then
                kind="symlink"
            fi
            if [[ -z "$kind" || ! "$object_id" =~ ^[0-9a-f]{40}$ || \
                  ! "$path" =~ ^[][A-Za-z0-9_./+@~#,=()\ -]+$ || "$path" == *..* ]] || \
               { [[ "$kind" == "file" ]] && \
                 [[ ! -f "$repo_path/$path" || -L "$repo_path/$path" ]]; } || \
               { [[ "$kind" == "symlink" ]] && \
                 ! _act_strict_symlink_is_representable "$repo_path" "$path" "$object_id"; }; then
                _log_error "Strict release tracked path cannot be represented safely: $path"
                exit 4
            fi
            printf '%s\t%s\t%s\n' "$object_id" "$mode" "$path" >&9 || exit 4
        done < <(_act_strict_git -C "$repo_path" ls-tree -r --full-tree "$revision" 2>/dev/null)
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
           ( "$mode" == "100644" || "$mode" == "100755" || "$mode" == "120000" || \
             "$mode" == "160000" ) && \
           "$relative_path" =~ ^[][A-Za-z0-9_./+@~#,=()\ -]+$ && \
           "$relative_path" != *..* && "$relative_path" != /* ]] || return 4
        if [[ "$mode" == "160000" ]]; then
            expected_objects["d:$relative_path"]=1
        else
            expected_objects["f:$relative_path"]=1
        fi
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
    local object_id mode relative_path parent expected_count actual_count gitlink_contents
    local hashes expected_hashes hash_index link_target link_hash
    local -a hash_paths=() hash_ids=() hash_modes=()

    if [[ ! -d "$root_path" || -L "$root_path" ]] || \
       ! expected_count=$(_act_tracked_manifest_object_count "$manifest_file"); then
        return 4
    fi

    while IFS=$'\t' read -r object_id mode relative_path; do
        [[ "$object_id" =~ ^[0-9a-f]{40}$ && \
           ( "$mode" == "100644" || "$mode" == "100755" || "$mode" == "120000" || \
             "$mode" == "160000" ) && \
           "$relative_path" =~ ^[][A-Za-z0-9_./+@~#,=()\ -]+$ && \
           "$relative_path" != *..* && "$relative_path" != /* ]] || return 4
        if [[ "$mode" == "160000" ]]; then
            if [[ ! -d "$root_path/$relative_path" || -L "$root_path/$relative_path" ]] || \
               ! gitlink_contents=$(find "$root_path/$relative_path" -mindepth 1 -print -quit 2>/dev/null) || \
               [[ -n "$gitlink_contents" ]]; then
                return 4
            fi
        elif [[ "$mode" == "120000" ]]; then
            # The link itself is the tracked object: its target string must
            # hash to the committed blob and stay inside the snapshot.
            [[ -L "$root_path/$relative_path" ]] || return 4
            link_target=$(readlink "$root_path/$relative_path") || return 4
            _act_strict_symlink_target_is_contained "$root_path" "$relative_path" "$link_target" || return 4
            link_hash=$(printf '%s' "$link_target" | git hash-object --no-filters --stdin 2>/dev/null) || return 4
            [[ "$link_hash" == "$object_id" ]] || return 4
        else
            if [[ ! -f "$root_path/$relative_path" || -L "$root_path/$relative_path" ]]; then
                _log_error "Strict source snapshot refused: $relative_path is missing or not a regular file"
                return 4
            fi
            if { [[ "$mode" == "100755" ]] && [[ ! -x "$root_path/$relative_path" ]]; } || \
               { [[ "$mode" == "100644" ]] && [[ -x "$root_path/$relative_path" ]]; }; then
                _act_report_strict_mode_mismatch "$root_path" "$relative_path" "$mode"
                return 4
            fi
            hash_paths+=("$relative_path")
            hash_ids+=("$object_id")
            hash_modes+=("$mode")
        fi
        parent="$relative_path"
        while [[ "$parent" == */* ]]; do
            parent="${parent%/*}"
            if [[ ! -d "$root_path/$parent" || -L "$root_path/$parent" ]]; then
                return 4
            fi
        done
    done < "$manifest_file"

    # The validated relative paths contain no newline, quote or backslash,
    # so stdin-paths passes them literally without shell or Git path quoting.
    # Hash the entire inventory with one Git process; large native releases
    # previously spawned tens of thousands of processes during each capture.
    if [[ ${#hash_paths[@]} -gt 0 ]]; then
        hashes=$(printf '%s\n' "${hash_paths[@]}" | \
            git -C "$root_path" hash-object --no-filters --stdin-paths 2>/dev/null) || return 4
        expected_hashes=$(printf '%s\n' "${hash_ids[@]}") || return 4
        if [[ "$hashes" != "$expected_hashes" ]]; then
            local -a actual_hash_ids=()
            mapfile -t actual_hash_ids <<< "$hashes"
            for ((hash_index=0; hash_index<${#hash_paths[@]}; hash_index++)); do
                if [[ "${actual_hash_ids[hash_index]:-}" != "${hash_ids[hash_index]}" ]]; then
                    _log_error "Strict source snapshot refused: ${hash_paths[hash_index]} content does not match Git blob ${hash_ids[hash_index]}"
                    break
                fi
            done
            return 4
        fi
        # Retain the post-hash mode and ancestor checks as well: a matching
        # byte digest cannot authorize a link or permission change during Git.
        for ((hash_index=0; hash_index<${#hash_paths[@]}; hash_index++)); do
            relative_path="${hash_paths[hash_index]}"
            mode="${hash_modes[hash_index]}"
            [[ -f "$root_path/$relative_path" && ! -L "$root_path/$relative_path" ]] || return 4
            if { [[ "$mode" == "100755" ]] && [[ ! -x "$root_path/$relative_path" ]]; } || \
               { [[ "$mode" == "100644" ]] && [[ -x "$root_path/$relative_path" ]]; }; then
                _act_report_strict_mode_mismatch "$root_path" "$relative_path" "$mode"
                return 4
            fi
            parent="$relative_path"
            while [[ "$parent" == */* ]]; do
                parent="${parent%/*}"
                [[ -d "$root_path/$parent" && ! -L "$root_path/$parent" ]] || return 4
            done
        done
    fi

    actual_count=$(find "$root_path" -mindepth 1 -print 2>/dev/null | wc -l | tr -d '[:space:]')
    if [[ ! "$actual_count" =~ ^[0-9]+$ || "$actual_count" != "$expected_count" ]]; then
        _log_error "Strict source snapshot refused: expected $expected_count filesystem nodes, found ${actual_count:-none} (extra or missing files)"
        return 4
    fi
}

# Explain a tracked file whose executable bit disagrees with its Git mode.
# Filesystems without POSIX modes (ExFAT, FAT, some FUSE/SMB mounts) report
# every file as executable; name the filesystem so the operator can restage.
_act_report_strict_mode_mismatch() {
    local root_path="$1" relative_path="$2" mode="$3"
    local node="$root_path/$relative_path" filesystem="" mount_point="" actual=""
    if [[ "$(uname -s 2>/dev/null)" == "Linux" ]]; then
        filesystem=$(stat -f -c %T "$node" 2>/dev/null) || filesystem=""
    fi
    if [[ -z "$filesystem" ]]; then
        mount_point=$(df -P "$node" 2>/dev/null | awk 'NR == 2 { print $6 }') || mount_point=""
        filesystem=$(mount 2>/dev/null | awk -v mp="$mount_point" \
            '$3 == mp { f = ($4 == "type") ? $5 : $4; gsub(/[(),]/, "", f); print f; exit }') || filesystem=""
    fi
    actual=$(ls -ld "$node" 2>/dev/null | awk '{ print $1 }') || actual=""
    _log_error "Strict source snapshot refused: $relative_path must have Git mode $mode but the extracted file is ${actual:-unreadable} on filesystem ${filesystem:-unknown}; stage strict snapshots on a POSIX-mode-preserving filesystem (set build_root in hosts.yaml)"
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
    if ! head=$(_act_strict_git -C "$repo_path" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || \
       ! resolved=$(_act_strict_git -C "$repo_path" rev-parse --verify "${revision}^{commit}" 2>/dev/null) || \
       [[ "$head" != "$revision" || "$resolved" != "$revision" ]]; then
        _log_error "Strict release checkout is not at its pinned revision: $label"
        return 4
    fi
    if ! status=$(_act_strict_git -C "$repo_path" status --porcelain --untracked-files=all 2>/dev/null) || \
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

# Use the installed cache implementation on the build host without requiring a
# second DSR installation there. The emitted function is POSIX-shell callable;
# its Python subprocess opens/copies cache entries without following links.
_act_unix_cargo_cache_runtime() (
    local module
    module="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cargo_cache.sh"
    [[ -f "$module" && ! -L "$module" ]] || return 3
    # shellcheck source=src/cargo_cache.sh
    source "$module" || return 3
    declare -f _cargo_cache_run
    cat <<'SH'
_dsr_cargo_home_guard() {
    test -d "$1" && test ! -L "$1" || return 4
    for dsr_name in config config.toml credentials credentials.toml; do
        if test -e "$1/$dsr_name" || test -L "$1/$dsr_name"; then
            printf '[dsr] private CARGO_HOME contains configuration: %s\n' "$dsr_name" >&2
            return 4
        fi
    done
}
SH
)

# The canonical home is a retained seed: Cargo never writes to it. Metadata
# and every target attempt receive independent inodes in a fresh home. This
# lets resume verify its seed even after the ambient cache has been removed,
# while normal Cargo unpacking cannot race another target's cache inventory.
_act_unix_private_cargo_home_script() {
    local source_root="$1" suffix="$2"
    [[ "$source_root" =~ ^/[A-Za-z0-9_./+-]+$ && "$source_root" != *..* &&
       "$suffix" =~ ^[A-Za-z0-9][A-Za-z0-9-]+$ ]] || return 4
    printf 'set -e\numask 077\n'
    _act_unix_cargo_cache_runtime || return $?
    cat <<EOF
physical_source_root=\$(cd '$source_root' && pwd -P)
strict_home="\${physical_source_root%/*}/.cargo-home"
dsr_seed_home=\$strict_home
strict_home="\${physical_source_root%/*}/.cargo-home-$suffix"
dsr_seed_pending=false
if test -e "\$dsr_seed_home" || test -L "\$dsr_seed_home"; then
    _dsr_cargo_home_guard "\$dsr_seed_home"
    dsr_seed_summary=\$(_cargo_cache_run verify "\$dsr_seed_home" "\$dsr_seed_home/.dsr-cache-seed.json")
    dsr_private_summary=\$(_cargo_cache_run snapshot "\$dsr_seed_home" "\$strict_home")
    python3 -I - "\$dsr_seed_summary" "\$dsr_private_summary" <<'DSR_PRIVATE_CACHE_COMPARE'
import json, sys
seed, private = (json.loads(value) for value in sys.argv[1:])
if (seed['mode'] != 'private-copy' or private['mode'] != 'private-copy' or
        seed['inventory_sha256'] != private['inventory_sha256']):
    sys.exit('private Cargo cache seed changed during preparation')
DSR_PRIVATE_CACHE_COMPARE
else
    # Do not publish an incomplete seed if offline metadata cannot resolve
    # yet. A later attempt can use repaired ambient downloads without ever
    # replacing an admitted seed or overwriting the failed private attempt.
    ambient_home=\${CARGO_HOME:-\$HOME/.cargo}
    if test ! -e "\$ambient_home" && test ! -L "\$ambient_home"; then ambient_home=; fi
    dsr_private_summary=\$(_cargo_cache_run snapshot "\$ambient_home" "\$strict_home")
    dsr_seed_pending=true
fi
_dsr_cargo_home_guard "\$strict_home"
EOF
}

_act_unix_cargo_metadata_body() {
    local build_cmd="${1-cargo build}" build_env="${2:-}" env_pair env_name
    cat <<'SH'
ancestor=${physical_source_root%/*}
while test "$ancestor" != / && test -n "$ancestor"; do
    for name in config config.toml; do
        test ! -e "$ancestor/.cargo/$name"; test ! -L "$ancestor/.cargo/$name"
    done
    ancestor=${ancestor%/*}; test -n "$ancestor" || ancestor=/
done
for variable in $(env | sed 's/=.*//'); do
    case "$variable" in CARGO_*|RUST*|XWIN_*|DSR_RELEASE_GIT_SHA|DSR_RELEASE_GIT_REF|CC|CXX|CPP|AR|RANLIB|LD|CFLAGS|CXXFLAGS|CPPFLAGS|LDFLAGS) unset "$variable";; esac
done
cd "$physical_source_root"
SH
    # Restore the same configured environment as the native launcher after
    # removing ambient selectors. CARGO_HOME remains this metadata attempt's
    # private copy, including when the caller already has an admitted seed.
    while IFS= read -r env_pair; do
        [[ -n "$env_pair" ]] || continue
        env_name="${env_pair%%=*}"
        [[ "$env_pair" == *=* && "$env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 4
        [[ "$env_name" == CARGO_HOME ]] && continue
        printf 'export "%s"\n' "$env_pair"
    done <<< "$build_env"
    cat <<'SH'
export CARGO_HOME="$strict_home" RCH_DISABLED=1 RCH_CARGO_WRAPPER_BYPASS=1
(
set -C
{
SH
    _act_toolchain_identity_script metadata /dev/null "$build_cmd" || return $?
    cat <<'SH'
} > "$strict_home/.dsr-cargo-metadata.json"
)
_dsr_cargo_home_guard "$strict_home"
if $dsr_seed_pending; then
    _cargo_cache_run snapshot "$strict_home" "$dsr_seed_home" >/dev/null
fi
SH
}

_act_prepare_unix_private_cargo_home() {
    local host="$1" source_root="$2" suffix="$3" command summary metadata_body
    local build_cmd="${4-cargo build}" build_env="${5:-}"
    command=$(_act_unix_private_cargo_home_script "$source_root" "$suffix") || return $?
    # An admitted download seed is reusable across targets, but its earlier
    # metadata result is not compiler authority for a new target/toolchain.
    metadata_body=$(_act_unix_cargo_metadata_body "$build_cmd" "$build_env") || return $?
    command+=$'\n'"$metadata_body"
    command+=$'\n''printf '\''%s\n'\'' "$dsr_private_summary"'
    summary=$(_act_ssh_exec "$host" "$command" "$_ACT_SYNC_TIMEOUT") || return $?
    jq -ce '
        select(type == "object" and .schema_version == 1 and .mode == "private-copy" and
            (.cargo_home | type == "string" and startswith("/")) and
            .receipt_path == (.cargo_home + "/.dsr-cache-seed.json") and
            (.receipt_sha256 | test("^[0-9a-f]{64}$")) and
            (.inventory_sha256 | test("^[0-9a-f]{64}$")))
    ' <<< "$summary"
}

# Ordinary (non-strict) Unix Rust builds stage their source under a fresh,
# unique stage root. Create that root here and give it a private copy of the
# ambient registry and Git download caches, so a cache prune or in-place write
# on the build host cannot reach a running build (issue #15). Cargo may still
# download missing dependencies into the private home. Prints the seed summary.
_act_prepare_unix_nonstrict_cargo_home() {
    local host="$1" isolation_root="$2" stage_root="$3" cargo_home="$4" command summary path
    # Paths are embedded in single quotes below; build roots may contain spaces.
    for path in "$isolation_root" "$stage_root" "$cargo_home"; do
        [[ "$path" == /* && "$path" != *"'"* && "$path" != *..* &&
           "$path" != *$'\n'* && "$path" != *$'\r'* ]] || return 4
    done
    [[ "$stage_root" == "${isolation_root%/}/dsr-build-"* &&
       "$cargo_home" == "$stage_root/"* ]] || return 4
    command=$'set -e\numask 077\n'
    command+=$(_act_unix_cargo_cache_runtime) || return $?
    command+=$'\n'"mkdir -p '$isolation_root'; $(_act_ram_backed_guard_sh "$isolation_root")"
    command+=$'\n'"$(cat <<EOF
dsr_ancestor='${stage_root%/*}'
while test -n "\$dsr_ancestor"; do
    for dsr_name in config config.toml; do
        test ! -e "\$dsr_ancestor/.cargo/\$dsr_name"; test ! -L "\$dsr_ancestor/.cargo/\$dsr_name"
    done
    test "\$dsr_ancestor" = / && break
    dsr_ancestor=\${dsr_ancestor%/*}; test -n "\$dsr_ancestor" || dsr_ancestor=/
done
test ! -e '$stage_root'; test ! -L '$stage_root'
mkdir '$stage_root'; test -d '$stage_root'; test ! -L '$stage_root'
ambient_home=\${CARGO_HOME:-\$HOME/.cargo}
if test ! -e "\$ambient_home" && test ! -L "\$ambient_home"; then ambient_home=; fi
dsr_seed_summary=\$(_cargo_cache_run snapshot "\$ambient_home" '$cargo_home')
_dsr_cargo_home_guard '$cargo_home'
printf '%s\\n' "\$dsr_seed_summary"
EOF
)"
    summary=$(_act_ssh_exec "$host" "$command" "$_ACT_SYNC_TIMEOUT") || return $?
    # The summary names the physical home (symlinked build roots resolve).
    jq -ce --arg name "${cargo_home##*/}" '
        select(type == "object" and .schema_version == 1 and .mode == "private-copy" and
            (.cargo_home | type == "string" and startswith("/") and endswith("/" + $name)) and
            .receipt_path == (.cargo_home + "/.dsr-cache-seed.json") and
            (.receipt_sha256 | test("^[0-9a-f]{64}$")) and
            (.inventory_sha256 | test("^[0-9a-f]{64}$")))
    ' <<< "$summary"
}

# Cargo may legitimately add/unpack dependencies in the private attempt home.
# Preserve its initial receipt, then observe the final inventory; equality to
# the seed is deliberately not required. Linked/special/config-bearing cache
# state, or a changed seed receipt, prevents artifact collection.
_act_finish_unix_private_cargo_home() {
    local host="$1" cargo_home="$2" seed_digest="$3" command summary
    [[ "$cargo_home" =~ ^/[A-Za-z0-9_./+-]+$ && "$cargo_home" != *..* &&
       "$seed_digest" =~ ^[0-9a-f]{64}$ ]] || return 4
    command=$(_act_unix_cargo_cache_runtime) || return $?
    command+=$'\n'"$(cat <<EOF
set -e
_dsr_cargo_home_guard '$cargo_home'
_dsr_verify_cache_seed() {
    python3 -I - '$cargo_home/.dsr-cache-seed.json' '$seed_digest' <<'DSR_PRIVATE_CACHE_SEED'
import hashlib, os, stat, sys
fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
with os.fdopen(fd, 'rb') as stream:
    before = os.fstat(stream.fileno())
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        sys.exit('private Cargo cache seed receipt is not a plain file')
    digest = hashlib.sha256()
    for block in iter(lambda: stream.read(1048576), b''):
        digest.update(block)
    if digest.hexdigest() != sys.argv[2]:
        sys.exit('private Cargo cache seed receipt changed')
    after = os.stat(sys.argv[1], follow_symlinks=False)
    identity = lambda info: (info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns)
    if identity(before) != identity(os.fstat(stream.fileno())) or identity(before) != identity(after):
        sys.exit('private Cargo cache seed receipt changed during verification')
DSR_PRIVATE_CACHE_SEED
}
_dsr_verify_cache_seed
dsr_final_summary=\$(_cargo_cache_run inventory '$cargo_home' '$cargo_home.final.json')
_dsr_cargo_home_guard '$cargo_home'
_dsr_verify_cache_seed
printf '%s\\n' "\$dsr_final_summary"
EOF
)"
    summary=$(_act_ssh_exec "$host" "$command" "$_ACT_SYNC_TIMEOUT") || return $?
    jq -ce --arg home "$cargo_home" '
        select(type == "object" and .schema_version == 1 and .mode == "inventory" and
            .cargo_home == $home and .receipt_path == ($home + ".final.json") and
            (.receipt_sha256 | test("^[0-9a-f]{64}$")) and
            (.inventory_sha256 | test("^[0-9a-f]{64}$")))
    ' <<< "$summary"
}

_act_windows_cache_junction_guard_script() {
    local cargo_home="$1" require_links="${2:-false}"
    [[ "$cargo_home" =~ ^[A-Za-z]:/[A-Za-z0-9_./+-]+$ && "$cargo_home" != *..* &&
       ( "$require_links" == true || "$require_links" == false ) ]] || return 4
    cat <<EOF
\$ErrorActionPreference='Stop';
\$dsrAmbient=if (\$env:CARGO_HOME) { \$env:CARGO_HOME } else { Join-Path \$env:USERPROFILE '.cargo' };
foreach (\$name in @('registry','git')) {
    \$expected=Join-Path \$dsrAmbient \$name; \$link=Join-Path '$cargo_home' \$name;
    if (Test-Path -LiteralPath \$link) {
        \$item=Get-Item -LiteralPath \$link -Force; \$targets=@(\$item.Target);
        if (-not \$item.PSIsContainer -or ((\$item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) -or \$targets.Count -ne 1 -or -not (Test-Path -LiteralPath \$expected -PathType Container)) { throw 'Strict Cargo cache junction authority missing' };
        \$actual=(Resolve-Path -LiteralPath \$targets[0] -ErrorAction Stop).ProviderPath;
        \$wanted=(Resolve-Path -LiteralPath \$expected -ErrorAction Stop).ProviderPath;
        if (-not [StringComparer]::OrdinalIgnoreCase.Equals(\$actual.TrimEnd('\\','/'),\$wanted.TrimEnd('\\','/'))) { throw 'Strict Cargo cache junction target mismatch' };
    } elseif (\$$require_links -and (Test-Path -LiteralPath \$expected -PathType Container)) { throw 'Strict Cargo cache junction absent after metadata' };
};
EOF
}

_act_strict_cargo_metadata_json() {
    local host="$1"
    local source_root="$2"
    local build_cmd="${3-cargo build}" build_env="${4:-}"
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
        metadata_command="$(_act_windows_encoded_powershell "\$ErrorActionPreference='Stop'; \$strict='${win_cargo_home}'; \$ambient=if (\$env:CARGO_HOME) { \$env:CARGO_HOME } else { Join-Path \$env:USERPROFILE '.cargo' }; if (-not (Test-Path -LiteralPath \$strict)) { New-Item -ItemType Directory -Path \$strict | Out-Null }; \$strictItem=Get-Item -LiteralPath \$strict -Force; if (-not \$strictItem.PSIsContainer -or ((\$strictItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'Strict CARGO_HOME is not a plain directory' }; foreach (\$name in @('config','config.toml','credentials','credentials.toml')) { if (Test-Path -LiteralPath (Join-Path \$strict \$name)) { throw 'Strict CARGO_HOME contains ambient configuration' } }; foreach (\$name in @('registry','git')) { \$source=Join-Path \$ambient \$name; \$dest=Join-Path \$strict \$name; if (Test-Path -LiteralPath \$source -PathType Container) { if (-not (Test-Path -LiteralPath \$dest)) { New-Item -ItemType Junction -Path \$dest -Target \$source | Out-Null }; \$destItem=Get-Item -LiteralPath \$dest -Force; if (-not \$destItem.PSIsContainer -or ((\$destItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0)) { throw 'Strict Cargo cache is not an isolated junction' } } elseif (Test-Path -LiteralPath \$dest) { throw 'Strict Cargo cache has no ambient authority' } }; \$ancestor=(Get-Item -LiteralPath '${win_source_root}').Parent; while (\$null -ne \$ancestor) { \$cargoDir=Join-Path \$ancestor.FullName '.cargo'; foreach (\$name in @('config','config.toml')) { if (Test-Path -LiteralPath (Join-Path \$cargoDir \$name)) { throw 'Untracked ancestor Cargo config is forbidden' } }; \$ancestor=\$ancestor.Parent }; Get-ChildItem Env: | Where-Object { \$_.Name -match '^(CARGO_|RUST)' -or \$_.Name -match '^(CC|CXX|CPP|AR|RANLIB|LD|CFLAGS|CXXFLAGS|CPPFLAGS|LDFLAGS)$' } | ForEach-Object { Remove-Item -LiteralPath ('Env:' + \$_.Name) }; \$env:CARGO_HOME=\$strict; Set-Location -LiteralPath '${win_source_root}'; Write-Output ((Get-Location).Path); & cargo metadata --locked --offline --all-features --format-version 1 --manifest-path '${win_manifest_path}'; exit \$LASTEXITCODE")"
    else
        local metadata_attempt metadata_body
        metadata_attempt=$(_act_generate_uuid) || return 3
        metadata_command=$(_act_unix_private_cargo_home_script \
            "$source_root" "metadata-${metadata_attempt//-/}") || return $?
        metadata_body=$(_act_unix_cargo_metadata_body "$build_cmd" "$build_env") || return $?
        metadata_command+=$'\n'"$metadata_body"$'\n''printf '\''%s\n'\'' "$physical_source_root"; test -f "$strict_home/.dsr-cargo-metadata.json"; test ! -L "$strict_home/.dsr-cargo-metadata.json"; cat "$strict_home/.dsr-cargo-metadata.json"'
    fi

    if _act_is_windows_host "$host"; then
        local cache_guard metadata_script
        cache_guard=$(_act_windows_cache_junction_guard_script "$strict_cargo_home") || return 4
        metadata_script=$(_act_windows_command_script "$metadata_command") || return 4
        metadata_command=$(_act_windows_encoded_powershell "$cache_guard"$'\n'"$metadata_script") || return 4
    fi
    if ! metadata_output=$(_act_ssh_exec "$host" "$metadata_command" "$_ACT_SYNC_TIMEOUT") || \
       [[ "$metadata_output" != *$'\n'* ]]; then
        _log_error "Locked offline Cargo metadata failed for strict source root on $host"
        return 4
    fi
    if _act_is_windows_host "$host"; then
        cache_guard=$(_act_windows_cache_junction_guard_script "$strict_cargo_home" true) || return 4
        _act_ssh_exec "$host" "$(_act_windows_encoded_powershell "$cache_guard")" "$_ACT_SYNC_TIMEOUT" >/dev/null || return 4
    fi
    canonical_source_root="${metadata_output%%$'\n'*}"
    canonical_source_root="${canonical_source_root%$'\r'}"
    metadata_json="${metadata_output#*$'\n'}"
    if ! canonical_source_root=$(_act_normalize_cargo_path "$canonical_source_root") || \
       ! jq -e 'type == "object"' <<< "$metadata_json" >/dev/null 2>&1; then
        _log_error "Locked offline Cargo metadata failed for strict source root on $host"
        return 4
    fi
    jq -c --arg source_root "$canonical_source_root" \
        '{source_root: $source_root, metadata: .}' <<< "$metadata_json"
}

_act_validate_strict_cargo_source_closure() {
    local host="$1"
    local source_root="$2"
    local dependency_checkouts_json="$3"
    local build_cmd="${4-cargo build}" build_env="${5:-}"
    local metadata_snapshot_json metadata_source_root metadata_json

    metadata_snapshot_json=$(_act_strict_cargo_metadata_json \
        "$host" "$source_root" "$build_cmd" "$build_env") || return $?
    metadata_source_root=$(jq -r '.source_root' <<< "$metadata_snapshot_json") || return 4
    metadata_json=$(jq -c '.metadata' <<< "$metadata_snapshot_json") || return 4
    _act_validate_cargo_metadata_source_closure \
        "$metadata_source_root" "$dependency_checkouts_json" "$metadata_json"
}

# Source closure is evaluated in each target's compiler context, even when
# several targets share one immutable source root and download seed.
_act_validate_strict_target_cargo_source_closure() {
    local tool="$1" platform="$2" version="$3" host="$4" source_root="$5" dependencies="$6"
    local build_cmd build_env binary_name target_triple
    build_cmd=$(act_get_build_cmd "$tool" "$platform") || return 4
    build_env=$(act_get_build_env "$tool" "$platform") || return 4
    binary_name=$(yq -r '.binary_name // ""' "$ACT_REPOS_DIR/${tool}.yaml") || return 4
    target_triple=$(act_get_build_env_value "$build_env" CARGO_BUILD_TARGET 2>/dev/null || true)
    build_cmd=$(act_substitute_build_cmd_tokens "$build_cmd" "${binary_name:-$tool}" \
        "$version" "${platform%%/*}" "${platform##*/}" "$target_triple") || return 4
    build_env+=$'\n'"CARGO_TARGET_DIR=${source_root%/*}/.cargo-target-${platform//\//-}"
    _act_validate_strict_cargo_source_closure \
        "$host" "$source_root" "$dependencies" "$build_cmd" "$build_env"
}

_act_windows_reparse_guard_script() {
    printf '%s' "function Assert-NoReparseChain { param([System.IO.FileSystemInfo]\$Item); for (\$node=\$Item; \$null -ne \$node; \$node=\$node.Parent) { if ((\$node.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'NTFS ReparsePoint is forbidden in a strict release snapshot' } } }; function Assert-PlainDirectory { param([string]\$Path); \$item=Get-Item -LiteralPath \$Path -Force -ErrorAction Stop; if (-not \$item.PSIsContainer) { throw 'Strict release directory is not a directory' }; Assert-NoReparseChain \$item }; function Assert-PlainFile { param([string]\$Path); \$item=Get-Item -LiteralPath \$Path -Force -ErrorAction Stop; if (\$item.PSIsContainer) { throw 'Strict release file is not a file' }; Assert-NoReparseChain \$item };"
}

_act_windows_source_budget_script() {
    local host="$1" parent="$2" archive_bytes="$3" object_count="$4" storage status=0 budget reserve drive
    storage=$(_act_windows_storage_config "$host") || status=$?
    [[ $status -ne 1 ]] || return 0
    [[ $status -eq 0 && "$parent" =~ ^[A-Za-z]:/[A-Za-z0-9_./+-]+$ && "$parent" != *..* &&
       "$archive_bytes" =~ ^[0-9]{1,12}$ && "$object_count" =~ ^[0-9]{1,9}$ ]] || return 4
    budget=$(jq -r '.source_budget_bytes' <<< "$storage")
    reserve=$(jq -r '.source_reserve_bytes' <<< "$storage")
    drive=$(jq -r '.source_drive' <<< "$storage")
    [[ "${parent:0:1}" == "$drive" ]] || return 4
    # Archives are uncompressed git tar files. Two archive lengths bound the
    # retained archive plus expanded bytes; per-object allocation overhead is
    # additionally charged. Each sibling is admitted against this same parent.
    cat <<EOF
\$dsrIncoming=([long]$archive_bytes * 2)+([long]$object_count * 4096)+16777216;
\$dsrExisting=[long]0;
if (Test-Path -LiteralPath '$parent') {
    foreach (\$entry in Get-ChildItem -LiteralPath '$parent' -Force -Recurse -ErrorAction Stop) {
        if ((\$entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Source budget encountered a reparse point' };
        \$dsrExisting+=4096; if (-not \$entry.PSIsContainer) { \$dsrExisting+=\$entry.Length };
    };
};
\$dsrDisk=Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='${drive}:'";
if ((\$dsrExisting+\$dsrIncoming) -gt [long]$budget -or \$null -eq \$dsrDisk -or \$dsrDisk.FreeSpace -lt ([long]$reserve+\$dsrIncoming)) { throw 'Source archives and sibling allocation exceed split-storage admission' };
EOF
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
               ! mkdir -p "$snapshot_grandparent"; then
                _log_error "Strict release snapshot parent already exists for $label"
                return 4
            fi
            if _act_dir_is_ram_backed "$snapshot_grandparent"; then
                _log_error "Refusing to stage $label under RAM-backed $snapshot_grandparent; set build_root for this host in hosts.yaml"
                return 4
            fi
            if ! mkdir -m 700 "$snapshot_parent"; then
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
        local win_remote_path win_snapshot_parent win_remote_archive reparse_guard
        win_remote_path=$(_act_windows_cmd_path "$remote_path")
        win_snapshot_parent=$(_act_windows_cmd_path "$snapshot_parent")
        win_remote_archive=$(_act_windows_cmd_path "$remote_archive")
        reparse_guard=$(_act_windows_reparse_guard_script)
        local win_snapshot_grandparent parent_setup setup_command verify_command
        win_snapshot_grandparent=$(_act_windows_cmd_path "$snapshot_grandparent")
        if $creates_snapshot_parent; then
            parent_setup="if (Test-Path -LiteralPath '${win_snapshot_parent}') { exit 16 }; New-Item -ItemType Directory -Force -Path '${win_snapshot_grandparent}' | Out-Null; Assert-PlainDirectory '${win_snapshot_grandparent}'; New-Item -ItemType Directory -Path '${win_snapshot_parent}' | Out-Null; Assert-PlainDirectory '${win_snapshot_parent}'"
        else
            parent_setup="Assert-PlainDirectory '${win_snapshot_parent}'"
        fi
        setup_command="$(_act_windows_encoded_powershell "${reparse_guard} ${parent_setup}; if ((Test-Path -LiteralPath '${win_remote_path}') -or (Test-Path -LiteralPath '${win_remote_archive}')) { exit 17 }; New-Item -ItemType Directory -Path '${win_remote_path}' | Out-Null; Assert-PlainDirectory '${win_remote_path}'")"
        local source_budget_script source_archive_bytes setup_script
        source_archive_bytes=$(_act_file_size "$archive_path") || return 4
        source_budget_script=$(_act_windows_source_budget_script "$host" "$snapshot_parent" "$source_archive_bytes" "$expected_object_count") || return 4
        if [[ -n "$source_budget_script" ]]; then
            setup_script=$(_act_windows_command_script "$setup_command") || return 4
            setup_command=$(_act_windows_encoded_powershell "$source_budget_script"$'\n'"$setup_script") || return 4
            setup_command=$(_act_windows_storage_command "$host" "$setup_command") || return 4
        fi
        verify_command="$(_act_windows_encoded_powershell "${reparse_guard} Assert-PlainDirectory '${win_snapshot_parent}'; Assert-PlainDirectory '${win_remote_path}'; Assert-PlainFile '${win_remote_archive}'; & (Join-Path \$env:SystemRoot 'System32\\tar.exe') -xf '${win_remote_archive}' -C '${win_remote_path}'; if (\$LASTEXITCODE -ne 0) { exit 18 }; \$items=@(Get-ChildItem -LiteralPath '${win_remote_path}' -Force -Recurse -ErrorAction Stop); if (\$items.Count -ne ${expected_object_count}) { exit 19 }; foreach (\$item in \$items) { Assert-NoReparseChain \$item }; (Get-FileHash -Algorithm SHA256 -LiteralPath '${win_remote_archive}').Hash.ToLowerInvariant()")"
        # stdin is closed on every transfer command: callers run this inside a
        # `while read` loop over dependency checkouts, and an ssh that inherits
        # the loop's stdin swallows the remaining entries, so only the first
        # dependency reached a Windows host.
        if ! _act_run_with_timeout "$_ACT_SYNC_TIMEOUT" ssh -n \
            -o ConnectTimeout="$_ACT_SSH_TIMEOUT" -o BatchMode=yes \
            -o StrictHostKeyChecking=accept-new "$ssh_destination" "$setup_command" || \
           ! _act_run_with_timeout "$_ACT_SYNC_TIMEOUT" scp \
            -o ConnectTimeout="$_ACT_SSH_TIMEOUT" -o BatchMode=yes \
            -o StrictHostKeyChecking=accept-new "$archive_path" \
            "${ssh_destination}:${remote_archive}" </dev/null || \
           ! remote_digest=$(_act_run_with_timeout "$_ACT_SYNC_TIMEOUT" ssh -n \
            -o ConnectTimeout="$_ACT_SSH_TIMEOUT" -o BatchMode=yes \
            -o StrictHostKeyChecking=accept-new "$ssh_destination" "$verify_command"); then
            _log_error "Strict fresh Windows source sync failed for $label"
            return 4
        fi
    else
        local remote_cmd parent_setup
        if $creates_snapshot_parent; then
            parent_setup="mkdir -p '$snapshot_grandparent'; $(_act_ram_backed_guard_sh "$snapshot_grandparent")test ! -e '$snapshot_parent'; test ! -L '$snapshot_parent'; mkdir '$snapshot_parent'"
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
        local win_remote_manifest manifest_preflight_command manifest_verify_command reparse_guard
        win_remote_manifest=$(_act_windows_cmd_path "$remote_manifest")
        reparse_guard=$(_act_windows_reparse_guard_script)
        manifest_preflight_command="$(_act_windows_encoded_powershell "${reparse_guard} Assert-PlainDirectory '${win_snapshot_parent}'; Assert-PlainDirectory '${win_remote_path}'; Assert-PlainFile '${win_remote_archive}'; if (Test-Path -LiteralPath '${win_remote_manifest}') { exit 20 }")"
        manifest_verify_command="$(_act_windows_encoded_powershell "${reparse_guard} Assert-PlainDirectory '${win_snapshot_parent}'; Assert-PlainDirectory '${win_remote_path}'; Assert-PlainFile '${win_remote_archive}'; Assert-PlainFile '${win_remote_manifest}'; (Get-FileHash -Algorithm SHA256 -LiteralPath '${win_remote_manifest}').Hash.ToLowerInvariant()")"
        # stdin closed for the same reason as the archive transfer above.
        _act_run_with_timeout "$_ACT_SYNC_TIMEOUT" ssh -n \
            -o ConnectTimeout="$_ACT_SSH_TIMEOUT" -o BatchMode=yes \
            -o StrictHostKeyChecking=accept-new "$ssh_destination" \
            "$manifest_preflight_command" || return 4
        _act_run_with_timeout "$_ACT_SYNC_TIMEOUT" scp \
            -o ConnectTimeout="$_ACT_SSH_TIMEOUT" -o BatchMode=yes \
            -o StrictHostKeyChecking=accept-new "$manifest_path" \
            "${ssh_destination}:${remote_manifest}" </dev/null || return 4
        remote_manifest_digest=$(_act_run_with_timeout "$_ACT_SYNC_TIMEOUT" ssh -n \
            -o ConnectTimeout="$_ACT_SSH_TIMEOUT" -o BatchMode=yes \
            -o StrictHostKeyChecking=accept-new "$ssh_destination" \
            "$manifest_verify_command") || return 4
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

    # Admit the extracted checkout before any compiler can use it (issue #20).
    # The local copy was already verified on extraction above. Remote hosts
    # run the same complete verifier the final aggregation uses, so a staging
    # filesystem that cannot hold Git modes is refused now, with the offending
    # path, rather than after every target in the matrix has compiled.
    if ! _act_is_local_host "$host"; then
        local admitted_digests
        if ! admitted_digests=$(_act_run_strict_snapshot_verifier "$host" "$ssh_destination" \
                "$remote_path" "$remote_archive" "$remote_manifest" \
                "$local_manifest_digest" "$expected_object_count" </dev/null) || \
           [[ "$admitted_digests" != "$local_digest $local_manifest_digest" ]]; then
            _log_error "Extracted strict source snapshot failed admission on $host for $label; no target was built"
            return 4
        fi
    fi
}

_act_unix_strict_snapshot_verify_script() {
    local remote_path="$1"
    local remote_archive="$2"
    local remote_manifest="$3"
    local expected_manifest_digest="$4"
    local expected_object_count="$5"

    cat << EOF
set -e
# Refusals name the offending tracked path. Filesystems without POSIX modes
# (ExFAT, FAT, some FUSE/SMB mounts) report every file as executable, which
# otherwise surfaces only after a complete build matrix (issue #20).
dsr_snapshot_refuse() {
    printf '[dsr] strict source snapshot refused: %s\\n' "\$1" >&2
    exit 21
}
dsr_snapshot_mode_refuse() {
    dsr_fs=
    if test "\$(uname -s 2>/dev/null)" = Linux; then
        dsr_fs=\$(stat -f -c %T "\$3" 2>/dev/null) || dsr_fs=
    fi
    if test -z "\$dsr_fs"; then
        dsr_mount=\$(df -P "\$3" 2>/dev/null | awk 'NR == 2 { print \$6 }') || dsr_mount=
        dsr_fs=\$(mount 2>/dev/null | awk -v mp="\$dsr_mount" '\$3 == mp { f = (\$4 == "type") ? \$5 : \$4; gsub(/[(),]/, "", f); print f; exit }') || dsr_fs=
    fi
    dsr_actual=\$(ls -ld "\$3" 2>/dev/null | awk '{ print \$1 }') || dsr_actual=
    dsr_snapshot_refuse "\$1 must have Git mode \$2 but the extracted file is \${dsr_actual:-unreadable} on filesystem \${dsr_fs:-unknown}; stage strict snapshots on a POSIX-mode-preserving filesystem (set build_root in hosts.yaml)"
}
test -d '$remote_path'; test ! -L '$remote_path'
test -f '$remote_archive'; test ! -L '$remote_archive'
test -f '$remote_manifest'; test ! -L '$remote_manifest'
if command -v sha256sum >/dev/null 2>&1; then
    archive_digest=\$(sha256sum '$remote_archive' | awk '{print \$1}')
    manifest_digest=\$(sha256sum '$remote_manifest' | awk '{print \$1}')
else
    archive_digest=\$(shasum -a 256 '$remote_archive' | awk '{print \$1}')
    manifest_digest=\$(shasum -a 256 '$remote_manifest' | awk '{print \$1}')
fi
test "\$manifest_digest" = '$expected_manifest_digest'
# Validate the complete manifest in one process. Per-file grep and Git
# launches made large source snapshots spend most of their time spawning
# processes instead of reading the tracked bytes. Keep the same path alphabet.
LC_ALL=C awk -F '\\t' '
    NF != 3 || length(\$1) != 40 || \$1 ~ /[^0-9a-f]/ ||
    \$2 !~ /^(100644|100755|120000|160000)\$/ ||
    \$3 !~ /^[][A-Za-z0-9_.\/+@~#,=() -]+\$/ ||
    substr(\$3,1,1) == "/" || index(\$3,"..") || seen[\$3]++ { bad=1; exit }
    END { if (bad || NR == 0) exit 21 }
' '$remote_manifest'
tab=\$(printf '\\t')
while IFS="\$tab" read -r object_id mode relative_path || test -n "\$relative_path"; do
    node='$remote_path'/\$relative_path
    parent=\$relative_path
    while test "\${parent#*/}" != "\$parent"; do
        parent=\${parent%/*}
        test -d '$remote_path'/"\$parent"
        test ! -L '$remote_path'/"\$parent"
    done
    if test "\$mode" = 160000; then
        test -d "\$node"
        test ! -L "\$node"
        gitlink_contents=\$(find "\$node" -mindepth 1 -print -quit)
        test -z "\$gitlink_contents"
    elif test "\$mode" = 120000; then
        test -L "\$node"
        target=\$(readlink "\$node")
        test -n "\$target"
        case "\$target" in /*) exit 21;; esac
        printf '%s\\n' "\$target" | grep -Eq '^[][A-Za-z0-9_./+@~#,=() -]+\$'
        cursor='$remote_path'
        link_dir=\${relative_path%/*}
        test "\$link_dir" = "\$relative_path" && link_dir=
        set -f
        old_ifs=\$IFS
        IFS=/
        for component in \$link_dir; do
            case "\$component" in
                ''|.) :;;
                *) cursor="\$cursor/\$component"; test -d "\$cursor"; test ! -L "\$cursor";;
            esac
        done
        for component in \$target; do
            case "\$component" in
                ''|.) :;;
                ..) test "\$cursor" != '$remote_path' || exit 21; cursor=\${cursor%/*};;
                *) cursor="\$cursor/\$component"; test ! -L "\$cursor" || exit 21;;
            esac
        done
        IFS=\$old_ifs
        set +f
        actual=\$(printf '%s' "\$target" | git hash-object --no-filters --stdin)
        test "\$actual" = "\$object_id"
    else
        test -f "\$node" || dsr_snapshot_refuse "\$relative_path is missing or not a regular file"
        test ! -L "\$node" || dsr_snapshot_refuse "\$relative_path is a symbolic link"
        if test "\$mode" = 100755; then
            test -x "\$node" || dsr_snapshot_mode_refuse "\$relative_path" "\$mode" "\$node"
        else
            test ! -x "\$node" || dsr_snapshot_mode_refuse "\$relative_path" "\$mode" "\$node"
        fi
    fi
done < '$remote_manifest'
# The validated alphabet excludes quotes, backslashes and newlines: stdin
# paths are literal and cannot acquire Git's quoted-path interpretation.
# Capture both projections first so a producer error is never masked by Git.
hash_paths=\$(LC_ALL=C awk -F '\\t' '\$2 == "100644" || \$2 == "100755" { print \$3 }' '$remote_manifest')
expected_hashes=\$(LC_ALL=C awk -F '\\t' '\$2 == "100644" || \$2 == "100755" { print \$1 }' '$remote_manifest')
if test -n "\$hash_paths"; then
    hashes=\$(printf '%s\\n' "\$hash_paths" | git -C '$remote_path' hash-object --no-filters --stdin-paths)
    if test "\$hashes" != "\$expected_hashes"; then
        # Failure path only: name the first tracked file whose bytes differ.
        while IFS="\$tab" read -r object_id mode relative_path || test -n "\$relative_path"; do
            case "\$mode" in 100644|100755) :;; *) continue;; esac
            actual=\$(git -C '$remote_path' hash-object --no-filters -- "\$relative_path" 2>/dev/null) || actual=
            test "\$actual" = "\$object_id" || dsr_snapshot_refuse "\$relative_path content does not match Git blob \$object_id"
        done < '$remote_manifest'
        dsr_snapshot_refuse "tracked file contents do not match the source manifest"
    fi
fi
# A matching byte digest cannot authorize a link or executable-mode change
# during the batch. Recheck regular objects and their ancestor chains.
while IFS="\$tab" read -r object_id mode relative_path || test -n "\$relative_path"; do
    case "\$mode" in 100644|100755) :;; *) continue;; esac
    node='$remote_path'/\$relative_path
    test -f "\$node"; test ! -L "\$node"
    if test "\$mode" = 100755; then
        test -x "\$node" || dsr_snapshot_mode_refuse "\$relative_path" "\$mode" "\$node"
    else
        test ! -x "\$node" || dsr_snapshot_mode_refuse "\$relative_path" "\$mode" "\$node"
    fi
    parent=\$relative_path
    while test "\${parent#*/}" != "\$parent"; do
        parent=\${parent%/*}
        test -d '$remote_path'/"\$parent"; test ! -L '$remote_path'/"\$parent"
    done
done < '$remote_manifest'
actual_count=\$(find '$remote_path' -mindepth 1 -print | wc -l | tr -d '[:space:]')
test "\$actual_count" = '$expected_object_count' || dsr_snapshot_refuse "expected $expected_object_count filesystem nodes, found \$actual_count (extra or missing files)"
printf '%s %s\\n' "\$archive_digest" "\$manifest_digest"
EOF
}

_act_windows_strict_snapshot_verify_script() {
    local remote_path="$1" snapshot_parent="$2" remote_archive="$3" remote_manifest="$4"
    local expected_manifest_digest="$5" expected_object_count="$6" reparse_guard
    reparse_guard=$(_act_windows_reparse_guard_script) || return 4
    cat << EOF
\$ErrorActionPreference='Stop'
$reparse_guard
Assert-PlainDirectory '$snapshot_parent'
Assert-PlainDirectory '$remote_path'
Assert-PlainFile '$remote_archive'
Assert-PlainFile '$remote_manifest'
\$manifestHash=(Get-FileHash -Algorithm SHA256 -LiteralPath '$remote_manifest').Hash.ToLowerInvariant()
if (\$manifestHash -ne '$expected_manifest_digest') { exit 19 }
\$paths=[Collections.Generic.List[string]]::new()
\$expected=[Collections.Generic.List[string]]::new()
\$gitlinks=[Collections.Generic.List[string]]::new()
foreach (\$line in Get-Content -LiteralPath '$remote_manifest') {
    \$parts=\$line.Split([char]9,3)
    if ((\$parts.Count -ne 3) -or (\$parts[0] -notmatch '^[0-9a-f]{40}$') -or
        ((\$parts[1] -ne '100644') -and (\$parts[1] -ne '100755') -and (\$parts[1] -ne '160000')) -or
        (\$parts[2] -notmatch '^[A-Za-z0-9_./+@~#,=()\[\] -]+$') -or
        \$parts[2].Contains('..') -or \$parts[2].StartsWith('/')) { exit 21 }
    \$node=Join-Path '$remote_path' \$parts[2]
    if (\$parts[1] -eq '160000') {
        Assert-PlainDirectory \$node
        if (@(Get-ChildItem -LiteralPath \$node -Force -ErrorAction Stop).Count -ne 0) { exit 21 }
        \$gitlinks.Add(\$node)
    } else {
        Assert-PlainFile \$node
        \$paths.Add(\$parts[2])
        \$expected.Add(\$parts[0])
    }
}
# Validated paths are ASCII with no quoting or newline characters. One native
# Git process hashes the ordered inventory without applying ambient filters.
if (\$paths.Count -gt 0) {
    \$hashes=@(\$paths | & git -C '$remote_path' hash-object --no-filters --stdin-paths)
    if ((\$LASTEXITCODE -ne 0) -or (\$hashes.Count -ne \$expected.Count)) { exit 21 }
    for (\$i=0; \$i -lt \$expected.Count; \$i++) {
        if (\$hashes[\$i] -cne \$expected[\$i]) { exit 21 }
        Assert-PlainFile (Join-Path '$remote_path' \$paths[\$i])
    }
}
foreach (\$node in \$gitlinks) {
    Assert-PlainDirectory \$node
    if (@(Get-ChildItem -LiteralPath \$node -Force -ErrorAction Stop).Count -ne 0) { exit 21 }
}
\$items=@(Get-ChildItem -LiteralPath '$remote_path' -Force -Recurse -ErrorAction Stop)
if (\$items.Count -ne $expected_object_count) { exit 20 }
foreach (\$item in \$items) { Assert-NoReparseChain \$item }
\$archiveHash=(Get-FileHash -Algorithm SHA256 -LiteralPath '$remote_archive').Hash.ToLowerInvariant()
Write-Output (\$archiveHash + ' ' + \$manifestHash)
EOF
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
    else
        local verify_output
        verify_output=$(_act_run_strict_snapshot_verifier "$host" "$ssh_destination" \
            "$remote_path" "$remote_archive" "$remote_manifest" \
            "$expected_manifest_digest" "$expected_object_count") || return 4
        read -r actual_digest actual_manifest_digest <<< "$verify_output"
    fi

    if [[ "$actual_digest" != "$expected_digest" || \
          "$actual_manifest_digest" != "$expected_manifest_digest" ]]; then
        _log_error "Strict source snapshot identity changed after transfer: $label"
        return 4
    fi
}

# Run the complete extracted-checkout verifier on a remote Unix or Windows
# host. Prints "<archive sha256> <manifest sha256>" in lowercase. The remote
# verifier's own refusal diagnostics are passed through on stderr.
_act_run_strict_snapshot_verifier() {
    local host="$1" ssh_destination="$2" remote_path="$3" remote_archive="$4"
    local remote_manifest="$5" expected_manifest_digest="$6" expected_object_count="$7"
    local remote_cmd verify_output digests

    if _act_is_windows_host "$host"; then
        local verify_script
        verify_script=$(_act_windows_strict_snapshot_verify_script \
            "$(_act_windows_cmd_path "$remote_path")" \
            "$(_act_windows_cmd_path "${remote_path%/*}")" \
            "$(_act_windows_cmd_path "$remote_archive")" \
            "$(_act_windows_cmd_path "$remote_manifest")" \
            "$expected_manifest_digest" "$expected_object_count") || return 4
        # PowerShell 7 is required here: Windows PowerShell 5 cannot inspect
        # valid tracked paths longer than MAX_PATH, even after native tar has
        # extracted them successfully. Missing pwsh must fail verification.
        remote_cmd=$(_act_windows_encoded_powershell "$verify_script" pwsh) || return 4
    else
        remote_cmd=$(_act_unix_strict_snapshot_verify_script "$remote_path" "$remote_archive" \
            "$remote_manifest" "$expected_manifest_digest" "$expected_object_count") || return 4
    fi
    local verify_status=0
    verify_output=$(_act_run_with_timeout "$_ACT_SYNC_TIMEOUT" ssh \
        -n \
        -o ConnectTimeout="$_ACT_SSH_TIMEOUT" -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new "$ssh_destination" "$remote_cmd") || verify_status=$?
    if [[ $verify_status -eq 124 ]]; then
        # Large trees can exceed the default window (issue #22). Nothing was
        # admitted; resume with a longer bound keeps every other check.
        _log_error "Strict source verification of $remote_path on $host timed out after ${_ACT_SYNC_TIMEOUT}s; raise DSR_SYNC_TIMEOUT and resume"
        return 4
    elif [[ $verify_status -ne 0 ]]; then
        return 4
    fi
    digests=$(printf '%s\n' "$verify_output" | tr -d '\r' | tail -1 | tr '[:upper:]' '[:lower:]')
    [[ "$digests" =~ ^[0-9a-f]{64}\ [0-9a-f]{64}$ ]] || return 4
    printf '%s\n' "$digests"
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
        # stdin closed like the dependency calls below: this runs inside the
        # host `while read` loop, and a transfer that reads stdin would drain
        # it and silently skip verifying every later host.
        if ! _act_verify_strict_checkout_snapshot "$host" "$ACT_REPO_LOCAL_PATH" \
            "$source_revision" "$source_root" "source.tar" "$tool_name" </dev/null; then
            return 4
        fi
        while IFS= read -r dependency; do
            [[ -n "$dependency" ]] || continue
            relative_path=$(jq -r '.relative_path' <<< "$dependency")
            dependency_local=$(jq -r '.local_path' <<< "$dependency")
            dependency_sha=$(jq -r '.git_sha' <<< "$dependency")
            if ! _act_verify_strict_checkout_snapshot "$host" "$dependency_local" "$dependency_sha" \
                "${source_root%/source}/$relative_path" "dependency-${relative_path}.tar" "$relative_path" </dev/null; then
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
        sib_relative=$(yq -r ".sibling_crates[$idx].relative_path // \"\"" "$config_file" 2>/dev/null)
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
            local patch_output
            if patch_output=$(_act_ssh_exec "$host" "$(_act_windows_encoded_powershell "[System.IO.File]::WriteAllText('${toml_path}', [System.IO.File]::ReadAllText('${toml_path}').Replace('${sib_local}','${relative_ref}'))")" 30 2>&1); then
                _log_ok "Patched Cargo.toml on $host: $sib_local → $relative_ref"
            else
                _log_error "Failed to patch Cargo.toml on $host for sibling $sib_relative"
                [[ -n "$patch_output" ]] && printf '%s\n' "$patch_output" >&2
                sync_failed=true
            fi
        else
            # macOS sed requires '' after -i; Linux sed requires no arg after -i
            # Use perl for portable in-place replacement
            local patch_output
            if patch_output=$(_act_ssh_exec "$host" "cd '${remote_path}' && perl -pi -e 's|\\Q${sib_local}\\E|${relative_ref}|g' Cargo.toml" 30 2>&1); then
                _log_ok "Patched Cargo.toml on $host: $sib_local → $relative_ref"
            else
                _log_error "Failed to patch Cargo.toml on $host for sibling $sib_relative"
                [[ -n "$patch_output" ]] && printf '%s\n' "$patch_output" >&2
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
    local target_hosts_json='{}'
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
            if $strict_release; then
                _log_error "No source snapshot host is available for strict target: $target"
                echo '{"status":"error","error":"Missing strict source snapshot host"}'
                return 4
            fi
            continue
        fi
        target_hosts_json=$(jq -c --arg target "$target" --arg host "$host" \
            '.[$target] = $host' <<< "$target_hosts_json") || return 4

        # Refuse a POSIX source root on a Windows host before any host is
        # synced (issue #8): rsync would create or target the wrong location
        # and the build step rejects the path anyway. This is a config error,
        # not a per-host sync failure.
        if [[ "$host" != "act" ]] && _act_is_windows_host "$host"; then
            case "$remote_path" in
                [A-Za-z]:[\\/]*|/[A-Za-z]/*) ;;
                *)
                    _log_error "Windows host $host needs a drive-qualified source root for $tool_name (set host_paths.$host in repos.d/${tool_name}.yaml, e.g. C:/Users/<user>/$tool_name); got: $remote_path"
                    echo '{"status":"error","error":"Windows host requires a drive-qualified host_paths entry"}'
                    return 4
                    ;;
            esac
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
                "$remote_path" "$tool_name" "$strict_run_id" "$host"); then
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
        echo '{"status":"skipped","synced":0,"hosts":[],"source_roots":{},"target_hosts":{}}'
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

    # Per-repo exclude patterns for the MAIN project sync (siblings already
    # support extra_excludes). Applied on top of the defaults and the
    # gitignore-derived excludes.
    local main_sync_excludes=()
    local main_sync_exclude
    while IFS= read -r main_sync_exclude; do
        [[ -z "$main_sync_exclude" ]] && continue
        main_sync_excludes+=("$main_sync_exclude")
    done < <(yq -r '.sync_excludes // [] | .[]' "$config_file" 2>/dev/null || true)

    for i in "${!hosts_to_sync[@]}"; do
        local host="${hosts_to_sync[$i]}"
        local remote_path="${host_paths[$i]}"

        # Capture each host's full sync transcript so failures can report the
        # underlying cause (in the log and in the per-host JSON) instead of a
        # bare "failed" status. The transcript is re-emitted on stderr either
        # way so progress detail is never lost.
        local source_synced=false
        local host_sync_output=""
        if $strict_release; then
            if host_sync_output=$(_act_sync_strict_checkout "$host" "$local_path" "$strict_git_sha" \
                "$remote_path" "source.tar" "$tool_name" 2>&1); then
                source_synced=true
            fi
        elif host_sync_output=$(_act_sync_source "$host" "$local_path" "$remote_path" \
            "${main_sync_excludes[@]}" 2>&1); then
            source_synced=true
        fi
        [[ -n "$host_sync_output" ]] && printf '%s\n' "$host_sync_output" >&2

        if $source_synced; then
            local sync_ok=true

            # Sync sibling crates and patch Cargo.toml paths on REMOTE hosts.
            # Skip when remote_path == local_path (i.e., the build host already
            # has the sibling crates at their absolute paths — no sync/patch needed).
            if $strict_release; then
                local dependency relative_path dependency_local dependency_sha
                local dependency_sync_output dependency_sync_status
                while IFS= read -r dependency; do
                    [[ -n "$dependency" ]] || continue
                    relative_path=$(jq -r '.relative_path' <<< "$dependency")
                    dependency_local=$(jq -r '.local_path' <<< "$dependency")
                    dependency_sha=$(jq -r '.git_sha' <<< "$dependency")
                    dependency_sync_output=$(_act_sync_strict_checkout "$host" "$dependency_local" "$dependency_sha" \
                        "${remote_path%/source}/$relative_path" \
                        "dependency-${relative_path}.tar" "$relative_path" 2>&1 </dev/null)
                    dependency_sync_status=$?
                    [[ -n "$dependency_sync_output" ]] && printf '%s\n' "$dependency_sync_output" >&2
                    if [[ "$dependency_sync_status" -ne 0 ]]; then
                        host_sync_output="$dependency_sync_output"
                        sync_ok=false
                        break
                    fi
                done < <(jq -c '.[]' <<< "$strict_dependency_checkouts")
            elif [[ "$sibling_count" -gt 0 && "$remote_path" != "$local_path" ]]; then
                local sibling_sync_output sibling_sync_status
                sibling_sync_output=$(_act_sync_sibling_crates "$host" "$remote_path" "$config_file" "$sibling_count" 2>&1)
                sibling_sync_status=$?
                [[ -n "$sibling_sync_output" ]] && printf '%s\n' "$sibling_sync_output" >&2
                if [[ "$sibling_sync_status" -ne 0 ]]; then
                    host_sync_output="$sibling_sync_output"
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
                results+=("$(jq -nc --arg host "$host" --arg path "$remote_path" \
                    --arg error "$(_act_sync_error_summary "$host_sync_output")" \
                    '{host: $host, path: $path, status: "failed", error: $error}')")
            fi
        else
            ((failed++))
            results+=("$(jq -nc --arg host "$host" --arg path "$remote_path" \
                --arg error "$(_act_sync_error_summary "$host_sync_output")" \
                '{host: $host, path: $path, status: "failed", error: $error}')")
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
        --argjson target_hosts "$target_hosts_json" \
        '{
            status: $status,
            synced: $synced,
            failed: $failed,
            duration_seconds: $duration,
            hosts: $hosts,
            source_roots: $source_roots,
            target_hosts: $target_hosts
        }'

    if [[ $failed -gt 0 ]]; then
        return 1
    fi
    return 0
}

# Get build command from config
# Usage: act_get_build_cmd <tool_name> [platform]
act_get_build_cmd() {
    local tool_name="$1"
    local platform="${2:-}"
    local config_file="$ACT_REPOS_DIR/${tool_name}.yaml"

    if [[ ! -f "$config_file" ]]; then
        return 4
    fi

    if [[ -n "$platform" ]]; then
        yq -r ".cross_compile.\"$platform\".build_cmd // .build_cmd // \"\"" "$config_file" 2>/dev/null
    else
        yq -r '.build_cmd // ""' "$config_file" 2>/dev/null
    fi
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
# Usage: act_substitute_build_cmd_tokens <build_cmd> <name> <version> <os> <arch> [target_triple]
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
    local target_triple="${6:-}"

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
    if [[ -n "$target_triple" ]] && ! _act_token_is_safe "$target_triple" target_triple; then
        _log_error "act_substitute_build_cmd_tokens: refusing unsafe target triple '$target_triple'"
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

    if [[ -n "$target_triple" ]]; then
        cmd="${cmd//\$\{target_triple\}/$target_triple}"
        cmd="${cmd//\$\{TARGET_TRIPLE\}/$target_triple}"
    fi

    printf '%s' "$cmd"
}

# Get environment variables for a build target
# Usage: act_get_build_env <tool_name> <platform> [selected_target_triple]
# Returns: Newline-separated KEY=VALUE pairs (preserves values with spaces)
act_get_build_env() {
    local tool_name="$1"
    local platform="$2"
    local selected_triple="${3:-}"
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

    # A native matrix worker selects exactly one declared variant. Do not
    # append a second CARGO_BUILD_TARGET: readers and shell exports must see
    # the same value, and a fixed operator target cannot be silently changed.
    if [[ -n "$selected_triple" ]]; then
        local configured_triples configured_target selected_language selected_derive
        configured_triples=$(act_get_configured_target_triples "$tool_name" "$platform") || return 4
        [[ -n "$configured_triples" ]] || configured_triples=$(_act_default_rust_target_triple "$platform") || return 4
        if ! grep -Fxq -- "$selected_triple" <<< "$configured_triples"; then
            _log_error "Native variant $selected_triple is not configured for $tool_name $platform"
            return 4
        fi
        selected_language=$(yq -r '.language // ""' "$config_file") || return 4
        selected_derive=$(yq -r '.derive_cargo_build_target' "$config_file") || return 4
        if [[ "$selected_language" != rust || "$selected_derive" == false ]]; then
            _log_error "Native target variants require Rust with derive_cargo_build_target enabled"
            return 4
        fi
        configured_target=$(DSR_ENV_PLATFORM="$platform" yq -r \
            '.cross_compile[strenv(DSR_ENV_PLATFORM)].env.CARGO_BUILD_TARGET // .env.CARGO_BUILD_TARGET // ""' \
            "$config_file") || return 4
        if [[ -n "$configured_target" && "$configured_target" != "$selected_triple" ]]; then
            _log_error "Configured CARGO_BUILD_TARGET=$configured_target conflicts with native variant $selected_triple; remove the fixed target and use DSR_TARGET_TRIPLE in build_cmd"
            return 4
        fi
        local selected_env="" selected_pair
        while IFS= read -r selected_pair; do
            [[ -z "$selected_pair" ]] && continue
            case "$selected_pair" in
                CARGO_BUILD_TARGET=*|DSR_TARGET_TRIPLE=*) continue ;;
            esac
            [[ -z "$selected_env" ]] || selected_env+=$'\n'
            selected_env+="$selected_pair"
        done <<< "$result"
        [[ -z "$selected_env" ]] || selected_env+=$'\n'
        result="${selected_env}CARGO_BUILD_TARGET=$selected_triple"
    fi

    # Derived build identity (issue #7). Historically the requested platform
    # reached the build only through artifact naming: a platform without an
    # explicit cross_compile env compiled untargeted, wrote to target/release,
    # and on a mismatched host produced the HOST architecture under the
    # requested platform's name — a wrong-arch binary that survives tag,
    # asset, and checksum verification. Deriving CARGO_BUILD_TARGET from
    # target_triples (or the standard triple for the platform) makes every
    # Rust build explicit about its target so cargo's output path and the
    # artifact collector always agree, and DSR_TARGET_* lets build commands
    # branch on the requested platform without parsing CARGO_TARGET_DIR.
    # Opt out per tool with `derive_cargo_build_target: false`.
    if [[ -n "$platform" && "$platform" == */* ]]; then
        local derived_pairs
        derived_pairs="DSR_TARGET_OS=${platform%%/*}"
        derived_pairs+=$'\n'"DSR_TARGET_ARCH=${platform##*/}"
        derived_pairs+=$'\n'"DSR_TARGET_PLATFORM=$platform"
        local env_language derive_opt
        env_language=$(yq -r '.language // ""' "$config_file" 2>/dev/null)
        derive_opt=$(yq -r '.derive_cargo_build_target' "$config_file" 2>/dev/null)
        if [[ "$env_language" == "rust" && "$derive_opt" != "false" ]]; then
            local derived_triple
            derived_triple=$(act_get_build_env_value "$result" "CARGO_BUILD_TARGET" 2>/dev/null || true)
            if [[ -z "$derived_triple" ]]; then
                # A direct singleton call defaults to the primary. Matrix
                # workers supplied their exact declared variant above.
                derived_triple=$(yq -r ".target_triples.\"$platform\" | select(tag == \"!!seq\") // [.] | .[0] // \"\"" \
                    "$config_file" 2>/dev/null)
                [[ "$derived_triple" == "null" ]] && derived_triple=""
                [[ -n "$derived_triple" ]] || \
                    derived_triple=$(_act_default_rust_target_triple "$platform" 2>/dev/null || true)
                if [[ -n "$derived_triple" ]]; then
                    derived_pairs+=$'\n'"CARGO_BUILD_TARGET=$derived_triple"
                fi
            fi
            if [[ -n "$derived_triple" ]]; then
                derived_pairs+=$'\n'"DSR_TARGET_TRIPLE=$derived_triple"
            fi
        fi
        if [[ -n "$result" ]]; then
            result="$result"$'\n'"$derived_pairs"
        else
            result="$derived_pairs"
        fi
    fi

    echo "$result"
}

# Read the runner's build authority directly (standalone native callers need
# not initialize the registry/config module). Keep declaration order: it owns
# primary aliases and the durable native task plan.
act_get_configured_target_triples() {
    local tool_name="$1" platform="$2" document
    document=$(yq -o=json '.' "$ACT_REPOS_DIR/${tool_name}.yaml") || return 4
    jq -r --arg platform "$platform" '
        def triple: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$") and (contains("..") | not);
        .target_triples // {} |
        if type != "object" then error("target_triples must be a mapping")
        else .[$platform] |
            if . == null then empty
            elif triple then .
            elif type == "array" and length > 0 and all(.[]; triple) and length == (unique | length)
            then .[] else error("invalid native target triple list") end
        end
    ' <<< "$document" || return 4
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

# Shared by receipt selection and both native launchers. OpenSSL accepts a
# target-triple prefix; pkg-config accepts target suffixes and HOST_/TARGET_
# prefixes, including selectors for the pkg-config executable itself.
_act_rust_sdk_influence_regex() {
    printf '%s\n' '^(OPENSSL_|.+_OPENSSL_|PKG_CONFIG($|_)|(HOST|TARGET)_PKG_CONFIG($|_)|.+_NO_PKG_CONFIG$|LIBCLANG_PATH$)'
}

_act_windows_rust_sdk_env_cleanup() {
    local sdk_regex
    sdk_regex=$(_act_rust_sdk_influence_regex)
    printf '%s' "\$keys=@(\$psi.EnvironmentVariables.Keys); foreach (\$key in \$keys) { if (\$key -match '${sdk_regex}') { \$psi.EnvironmentVariables.Remove(\$key) } }; "
}

_act_is_rust_build_influence_name() {
    local normalized_name="${1^^}"
    local sdk_regex
    sdk_regex=$(_act_rust_sdk_influence_regex)
    [[ "$normalized_name" =~ $sdk_regex ]] && return 0
    case "$normalized_name" in
        CARGO_*|RUST*|XWIN_*|TEMP|TMP|DSR_RELEASE_GIT_SHA|DSR_RELEASE_GIT_REF|\
        DSR_RUST_TARGET|DSR_ZIG_TARGET|DSR_LINUX_GLIBC_FLOOR|\
        FT_ATOMIC_BUILD_IDENTITY|FT_ATOMIC_BUILD_PROFILE|\
        CC|CXX|CPP|AR|RANLIB|LD|NM|OBJCOPY|STRIP|\
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

# FrankenTerm's native processes embed one canonical family identity at compile
# time. Derive it on the POSIX coordinator, including for Windows, using the
# verifier from the exact release tree. A later manifest cannot seal an already
# compiled development binary.
_act_frankenterm_build_identity() {
    local source_root="$1" revision="$2" version="$3" target="$4" profile="$5"
    local verifier="scripts/atomic-component-manifest.sh"
    if [[ ! "$revision" =~ ^[0-9a-f]{40}$ || "$revision" =~ ^0{40}$ || \
          "$profile" != release-interactive || \
          ! -f "$source_root/$verifier" || -L "$source_root/$verifier" ]] || \
       ! git -C "$source_root" cat-file -e "$revision:$verifier" || \
       ! git -C "$source_root" diff --quiet "$revision" -- "$verifier"; then
        _log_error "FrankenTerm build identity requires the exact release verifier and interactive profile"
        return 4
    fi
    local identity
    identity=$(bash "$source_root/$verifier" derive-build-id \
        --source-revision "$revision" --version "${version#v}" \
        --target "$target" --profile "$profile" \
        --feature-contract application-family-gui-ft-mux-server-pty-guardian-default-features-v1) || return 4
    [[ "$identity" =~ ^[0-9a-f]{64}$ && ! "$identity" =~ ^0{64}$ ]] || return 4
    printf '%s\n' "$identity"
}

_act_finalize_frankenterm_windows_family() {
    local root="$1" source_root="$2" revision="$3" version="$4" profile="$5"
    local target=x86_64-pc-windows-msvc identity verifier_receipt
    identity=$(_act_frankenterm_build_identity \
        "$source_root" "$revision" "$version" "$target" "$profile") || return 4
    verifier_receipt=$(_act_collect_stream_exclusive \
        "$root/verify-components.sh" 700 _act_stream_local_file \
        "$source_root/scripts/atomic-component-manifest.sh") || return 4
    [[ -n "$verifier_receipt" ]] || return 4
    # This verifies PE bytes on the POSIX coordinator. It is deliberately not
    # a claim that the POSIX descriptor-based verifier runs on native Windows.
    bash "$root/verify-components.sh" generate \
        --root "$root" --source-root "$source_root" \
        --output "$root/ft-windows-amd64.component-manifest.json" \
        --build-id "$identity" --source-revision "$revision" \
        --version "${version#v}" --target "$target" --profile "$profile" \
        --feature-contract application-family-gui-ft-mux-server-pty-guardian-default-features-v1 \
        --entry executable:cli:ft.exe:ft \
        --entry executable:gui:frankenterm-gui.exe:frankenterm-gui \
        --entry executable:mux-server:frankenterm-mux-server.exe:frankenterm-mux-server \
        --entry executable:pty-guardian:frankenterm-pty-guardian.exe:frankenterm-pty-guardian \
        --entry verifier:offline-verifier:verify-components.sh \
        --source-match verify-components.sh=scripts/atomic-component-manifest.sh \
        --input font.payload=crates/frankenterm/assets/Pragmasevka_NF.zip.zst >/dev/null || return 4
    bash "$root/verify-components.sh" verify --root "$root" \
        --manifest "$root/ft-windows-amd64.component-manifest.json" >/dev/null
}

# Resolve the remote path to a built binary for SCP retrieval.
# Usage: act_get_remote_artifact_path <language> <remote_path> <build_env> <binary_name> <platform> [build_profile]
act_get_remote_artifact_path() {
    local language="$1"
    local remote_path="${2%/}"
    local build_env="$3"
    local binary_name="$4"
    local platform="$5"
    local build_profile="${6:-release}"
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
                        artifact_base="$cargo_target_dir/$build_profile"
                        ;;
                    *)
                        artifact_base="$remote_path/$cargo_target_dir/$build_profile"
                        ;;
                esac
            else
                artifact_base="$remote_path/target/$build_profile"
            fi

            if [[ -n "$cargo_build_target" ]]; then
                artifact_base="${artifact_base%/$build_profile}/$cargo_build_target/$build_profile"
            fi
            ;;
        go)
            local go_bin=""
            go_bin=$(act_get_build_env_value "$build_env" "GOBIN" 2>/dev/null || true)
            go_bin="${go_bin%/}"
            go_bin="${go_bin%\\}"
            if [[ -n "$go_bin" ]]; then
                case "$go_bin" in
                    /*|[A-Za-z]:/*|[A-Za-z]:\\*)
                        artifact_base="$go_bin"
                        ;;
                    *)
                        artifact_base="$remote_path/$go_bin"
                        ;;
                esac
            else
                artifact_base="$remote_path"
            fi
            ;;
        *)
            artifact_base="$remote_path"
            ;;
    esac

    local remote_artifact_path="$artifact_base/$binary_name"
    if [[ "$platform" == windows/* ]]; then
        remote_artifact_path="${remote_artifact_path//\\//}"
        # The archive inventory already normalizes an explicit .exe suffix.
        # Collection must not turn that selected executable into app.exe.exe.
        remote_artifact_path="${remote_artifact_path%.[eE][xX][eE]}.exe"
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
        rm_cmd=$(_act_windows_cmd_via_powershell "rmdir /s /q \"$win_path\"") || return 4
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

    if _act_is_windows_host "$host"; then
        cmd=$(_act_windows_storage_command "$host" "$cmd") || return 4
    fi

    if _act_is_local_host "$host"; then
        _act_run_with_timeout "$timeout_sec" bash -lc "$cmd"
    else
        local ssh_destination
        ssh_destination=$(_act_get_ssh_destination "$host") || return 4
        _act_run_with_timeout "$timeout_sec" ssh \
            -n \
            -o ConnectTimeout="$_ACT_SSH_TIMEOUT" \
            -o BatchMode=yes \
            -o StrictHostKeyChecking=accept-new \
            "$ssh_destination" "$cmd"
    fi
}

# Emit a host-side wrapper for opt-in intermediate Cargo caching. Final outputs
# remain in the run's fresh target directory; no cached output is collected on
# failure. Python owns the advisory lock through build and output detachment.
_act_strict_cargo_cache_script() {
    local cache_root="$1" cache_contract="$2" command="$3"
    local root_q contract_q command_q selection_script
    printf -v root_q '%q' "$cache_root"
    printf -v contract_q '%q' "$cache_contract"
    printf -v command_q '%q' "$command"
    selection_script=$(_act_toolchain_identity_script context /dev/null "$command") || return $?
    printf 'dsr_cache_context=$(\n%s\n) || exit $?\n' "$selection_script"
    printf 'DSR_CARGO_TOOLCHAIN_CONTEXT="$dsr_cache_context" python3 -I - %s %s %s <<\x27DSR_CARGO_CACHE_PY\x27\n' "$root_q" "$contract_q" "$command_q"
    cat <<'PY'
import fcntl, hashlib, json, os, pathlib, re, shlex, shutil, stat, subprocess, sys, tempfile, tomllib

def require(ok, message):
    if not ok:
        raise RuntimeError('strict Cargo cache: ' + message)

def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as stream:
        for block in iter(lambda: stream.read(1048576), b''):
            h.update(block)
    return h.hexdigest()

def probe(argv):
    return subprocess.check_output(argv, text=True, timeout=30, env=probe_env).strip()

context = json.loads(os.environ.pop('DSR_CARGO_TOOLCHAIN_CONTEXT'))
probe_env = dict(os.environ, **context['environment'])
cargo_argv = context['cargo_argv']
compiler = context['compiler']
selected_identity = context['identity']
managed_variables = {'CARGO_BUILD_BUILD_DIR', 'CARGO_UNSTABLE_CHECKSUM_FRESHNESS', 'CARGO_BUILD_FINGERPRINT'}
require(not managed_variables.intersection(context['assigned_environment']),
        'build_cmd cannot override managed cache custody or freshness settings')

root = pathlib.Path(sys.argv[1])
require(root.is_absolute() and root.resolve() == root, 'root must be a canonical absolute path')
for path in [root, *root.parents]:
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode) and not path.is_symlink(), 'unsafe root ancestor')
    require(info.st_uid in (0, os.getuid()), 'foreign root ancestor')
    require(not info.st_mode & 0o022 or (info.st_uid == 0 and info.st_mode & stat.S_ISVTX), 'writable root ancestor')
info = root.stat()
require(info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700, 'root must be owned mode 0700')
target = pathlib.Path(os.environ['CARGO_TARGET_DIR'])
require(target.is_absolute() and not target.exists() and not target.is_symlink(), 'final target must be fresh')
require(not target.is_relative_to(root) and not root.is_relative_to(target), 'cache and final target must be separate')
require(not root.is_relative_to(pathlib.Path.cwd()) and not pathlib.Path.cwd().is_relative_to(root), 'cache and source must be separate')
require(not any(name in selected_identity['tools'] for name in (
            'rustc_wrapper', 'rustc_workspace_wrapper', 'cargo_build_rustc_wrapper',
            'cargo_build_rustc_workspace_wrapper')),
        'explicit rustc wrappers are unsupported by the cache identity contract')
cargo = probe(cargo_argv + ['-V'])
version = re.match(r'cargo (\d+)\.(\d+)\.(\d+)', cargo)
require(version and tuple(map(int, version.groups())) >= (1, 91, 1), 'Cargo >=1.91.1 with build.build-dir support required')
rustc = probe([compiler, '-vV'])
# Reviewed managed RCH shim v4 and toolchain wrapper v3, identical on the
# native Mac and Linux proof host. A changed script requires renewed review;
# matching a comment or a version response is not executable authority.
rch_shim_hash = '015f36047d1b732ada59b8644f7fde5e327803a11e56d571d2603af25c970ed7'
rch_toolchain_hash = 'd5966567e177ce968f272848ab8e249da3d9bfca40f90237480e1fbe6bd9d2d0'
def compiler_identity(program, tool, version_args, observed):
    selected = shutil.which(program, path=probe_env.get('PATH'))
    require(selected, 'compiler executable missing: ' + tool)
    selected = pathlib.Path(selected).resolve()
    with selected.open('rb') as stream:
        is_wrapper = stream.read(2) == b'#!'
    if is_wrapper:
        require(tool == 'cargo' and digest(selected) in (rch_shim_hash, rch_toolchain_hash),
                'unrecognized selected compiler script: ' + tool)
        require(probe_env.get('RCH_CARGO_WRAPPER_BYPASS') == '1' and
                not probe_env.get('RCH_REAL_CARGO') and not probe_env.get('RCH_SHIM_REAL_CARGO'),
                'RCH cache resolution requires local bypass without executable overrides')
    actual = selected
    if is_wrapper or selected.name == 'rustup':
        rustup = shutil.which('rustup', path=probe_env.get('PATH'))
        require(rustup, 'rustup executable missing')
        rustup = pathlib.Path(rustup).resolve()
        with rustup.open('rb') as stream:
            require(stream.read(2) != b'#!', 'rustup resolver cannot be a script')
        require(is_wrapper or selected == rustup, 'unrecognized rustup launcher')
        actual = pathlib.Path(probe(['rustup', 'which', tool])).resolve()
        require(probe([str(actual), *version_args]) == observed, 'wrapper/toolchain version disagreement: ' + tool)
    toolchain_launcher = {'path': str(actual), 'sha256': digest(actual)}
    with actual.open('rb') as stream:
        is_toolchain_wrapper = stream.read(2) == b'#!'
    if is_toolchain_wrapper and tool == 'cargo':
        # RCH's managed toolchain wrapper has a documented local bypass used
        # by this runner. Bind that wrapper too, then hash its real executable.
        require(probe_env.get('RCH_CARGO_WRAPPER_BYPASS') == '1' and
                digest(actual) == rch_toolchain_hash, 'unsupported toolchain Cargo wrapper')
        actual = (actual.parent / 'cargo-rch-real').resolve()
        require(probe([str(actual), *version_args]) == observed, 'RCH real Cargo version disagreement')
    with actual.open('rb') as stream:
        require(stream.read(2) != b'#!' and actual.name != 'rustup', 'unresolved compiler wrapper: ' + tool)
    return {'selected_path': str(selected), 'selected_sha256': digest(selected),
            'toolchain_launcher': toolchain_launcher,
            'executable_path': str(actual), 'executable_sha256': digest(actual)}
compilers = {'cargo': compiler_identity('cargo', 'cargo', ['-V'], cargo),
             'rustc': compiler_identity(compiler, 'rustc', ['-vV'], rustc)}
require('-nightly' in cargo and '-nightly' in rustc,
        'strict cache requires nightly Cargo/rustc checksum freshness')
require('checksum-freshness' in probe(cargo_argv + ['-Z', 'help']),
        'Cargo checksum-freshness capability unavailable')
os.environ['CARGO_UNSTABLE_CHECKSUM_FRESHNESS'] = 'true'
os.environ['CARGO_BUILD_FINGERPRINT'] = 'content'
probe_env['CARGO_UNSTABLE_CHECKSUM_FRESHNESS'] = 'true'
probe_env['CARGO_BUILD_FINGERPRINT'] = 'content'
# Cargo still timestamps build-script rerun-if-changed inputs in checksum mode.
# Refuse the entire resolved graph rather than accepting stale generated code.
# --frozen prevents this admission probe from modifying the sealed lockfile or
# fetching dependencies. A future broader contract needs separate input proof.
metadata = json.loads(probe(cargo_argv + ['metadata', '--format-version=1', '--frozen', '--all-features']))
require(not any('custom-build' in target['kind']
                for package in metadata['packages'] for target in package['targets']),
        'strict cache does not support build scripts: rerun-if-changed remains timestamp-based')
# Source identity/version are deliberately not cache namespace inputs. Cargo
# fingerprints the newly verified source; the final artifact embeds its identity.
excluded = {'CARGO_HOME', 'CARGO_TARGET_DIR', 'CARGO_BUILD_BUILD_DIR',
            'DSR_RELEASE_GIT_SHA', 'DSR_RELEASE_GIT_REF',
            'FT_ATOMIC_BUILD_IDENTITY', 'FT_ATOMIC_BUILD_PROFILE'}
influences = {k: v for k, v in probe_env.items() if k not in excluded and
              (k.startswith(('CARGO_', 'RUST', 'XWIN_')) or
               re.search(r'(^|_)(CC|CXX|AR|RANLIB|LD|CFLAGS|CXXFLAGS|CPPFLAGS|LDFLAGS|SDKROOT|MACOSX_DEPLOYMENT_TARGET)($|_)', k))}
tools = {}
for name in ('CC', 'CXX', 'AR', 'LD'):
    argv = shlex.split(probe_env.get(name, {'CC': 'cc', 'CXX': 'c++', 'AR': 'ar', 'LD': 'ld'}[name]))
    executable = shutil.which(argv[0], path=probe_env.get('PATH'))
    require(executable, 'missing tool ' + name)
    tools[name] = {'argv': argv, 'path': str(pathlib.Path(executable).resolve()), 'sha256': digest(executable)}
    if sys.platform == 'darwin' and str(pathlib.Path(executable).resolve()) in (
            '/usr/bin/cc', '/usr/bin/c++', '/usr/bin/clang', '/usr/bin/clang++'):
        tool = 'clang++' if name == 'CXX' else 'clang'
        actual = pathlib.Path(probe(['xcrun', '--find', tool])).resolve()
        require(actual != pathlib.Path(executable).resolve(), 'xcrun did not resolve Apple compiler launcher')
        tools[name]['selected_compiler'] = {'path': str(actual), 'sha256': digest(actual)}
sdk = None
if sys.platform == 'darwin':
    sdk_path = pathlib.Path(probe_env.get('SDKROOT') or probe(['xcrun', '--show-sdk-path'])).resolve()
    settings = sdk_path / 'SDKSettings.json'
    require(settings.is_file(), 'SDK settings unavailable')
    sdk = {'path': str(sdk_path), 'settings_sha256': digest(settings),
           'xcode': probe(['xcodebuild', '-version'])}
contract = {'schema': 2, 'source_freshness': 'nightly-content-no-build-scripts-v1',
            'configuration': json.loads(sys.argv[2]), 'cargo': cargo,
            'rustc': rustc, 'compilers': compilers, 'tools': tools, 'sdk': sdk, 'environment': influences}
# Include actual target/linker/plugin bytes without the fresh source cwd: two
# immutable copies of the same project can still reuse eligible intermediates.
contract['toolchain'] = {key: selected_identity[key] for key in ('target_triple', 'linker_variable', 'tools')}
with open('Cargo.toml', 'rb') as manifest:
    contract['profiles'] = tomllib.load(manifest).get('profile', {})
contract['cargo_config'] = {name: digest(name) for name in ('.cargo/config', '.cargo/config.toml')
                            if pathlib.Path(name).is_file()}
key = hashlib.sha256(json.dumps(contract, sort_keys=True).encode()).hexdigest()
namespace = root / key
try:
    namespace.mkdir(mode=0o700)
except FileExistsError:
    pass
info = namespace.lstat()
require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700, 'unsafe namespace')
lock_path = namespace / 'custody.lock'
fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
with os.fdopen(fd, 'r+') as lock:
    info = os.fstat(lock.fileno())
    require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_nlink == 1 and stat.S_IMODE(info.st_mode) == 0o600, 'unsafe lock')
    # Contention is explicit refusal, not an unbounded wait consuming build time.
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    require(os.stat(lock_path, follow_symlinks=False).st_ino == info.st_ino, 'lock identity changed')
    build_dir = namespace / 'build'
    if build_dir.exists() or build_dir.is_symlink():
        info = build_dir.lstat()
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid(), 'unsafe intermediate directory')
    os.environ['CARGO_BUILD_BUILD_DIR'] = str(build_dir)
    print('DSR_CARGO_CACHE namespace=' + key, flush=True)
    # The child shell inherits custody so controller interruption cannot release
    # the lock while its build command is still running.
    code = subprocess.call(['bash', '-e', '-c', sys.argv[3]], pass_fds=(lock.fileno(),))
    if code != 0:
        sys.exit(code if code > 0 else 128 - code)
    require(build_dir.is_dir(), 'Cargo did not create configured intermediate directory')
    info = target.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid(), 'final target must remain a plain owned directory')
    # Cargo can hard-link final executables to intermediates. Sever such links
    # under custody before another run may update the shared cache. These are
    # exclusively this run's files; retained failed copies are never collected.
    def traversal_failed(error):
        raise error
    for directory, dirs, files in os.walk(target, followlinks=False, onerror=traversal_failed):
        for name in dirs + files:
            path = pathlib.Path(directory) / name
            require(not path.is_symlink(), 'symlink in final target')
        for name in files:
            path = pathlib.Path(directory) / name
            info = path.stat()
            require(stat.S_ISREG(info.st_mode), 'nonregular final output')
            if info.st_nlink > 1:
                with tempfile.NamedTemporaryFile(dir=directory, prefix='.dsr-detach-', delete=False) as copy:
                    with path.open('rb') as source:
                        shutil.copyfileobj(source, copy)
                    os.fchmod(copy.fileno(), stat.S_IMODE(info.st_mode))
                    copy.flush()
                    os.fsync(copy.fileno())
                os.replace(copy.name, path)
    receipt = target.parent / (target.name + '.cache-receipt.json')
    with receipt.open('x') as stream:
        json.dump({'namespace': key, 'build_dir': str(build_dir), 'contract': contract,
                   'final_output_policy': 'fresh-run-target-detached-under-custody'}, stream, sort_keys=True)
PY
    printf 'DSR_CARGO_CACHE_PY\n'
}

# Emit a host-side probe of the executables a strict Unix Rust build actually
# uses (bd-10we). It runs inside the build shell, after the build environment
# is exported and the working directory is entered, so PATH shims, rustup
# overrides and configured linkers resolve exactly as they do for the build.
# Mode "record" writes the identity JSON to <output> without clobbering;
# mode "verify" re-probes after the build and fails if any identity changed.
# The reviewed invocation boundary accepts direct Cargo commands with a common
# literal toolchain and target, including the effective CARGO_BUILD_TARGET.
# Unresolved shell selection, conflicting invocations and Cargo --config/-C
# overrides are refused rather than attesting a default that may not run.
# Each tool records the selected executable and, for proven rustup proxies and
# Apple /usr/bin compiler launchers, its dispatch target and content digest.
# Internal metadata mode runs locked/offline metadata with the same selection;
# context mode passes selected executable authority to the intermediate cache.
# Args: mode output_json build_cmd extra_tools(space-separated)
_act_toolchain_identity_script() {
    local mode="$1" output="$2" build_cmd="$3" extra_tools="${4:-}"
    local output_q command_q extra_q python_q=python3
    [[ "$mode" == record || "$mode" == verify || "$mode" == metadata || "$mode" == context || "$mode" == target ]] || return 4
    [[ "$output" == /* && "$output" != *..* ]] || return 4
    printf -v output_q '%q' "$output"
    printf -v command_q '%q' "$build_cmd"
    printf -v extra_q '%q' "$extra_tools"
    # Target-only planning runs on the coordinator without invoking any build
    # tools or reading its Cargo configuration. The configured PATH may be a
    # remote host path, so use the coordinator's absolute Python interpreter.
    if [[ "$mode" == target ]]; then
        python_q=$(command -v python3) || return 4
        printf -v python_q '%q' "$python_q"
    fi
    printf '%s -I - %s %s %s %s <<\x27DSR_TOOLCHAIN_IDENTITY_PY\x27\n' "$python_q" "$mode" "$output_q" "$command_q" "$extra_q"
    cat <<'PY'
import hashlib, json, os, pathlib, re, shlex, shutil, subprocess, sys

mode, output, command, extra = sys.argv[1:5]

def fail(message):
    sys.stderr.write('[dsr] toolchain identity: ' + message + '\n')
    sys.exit(86)

def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as stream:
        for block in iter(lambda: stream.read(1048576), b''):
            h.update(block)
    return h.hexdigest()

def shell_word(raw, variables=()):
    # Read a bounded shell word without evaluating code. Quotes and ordinary
    # escapes are preserved by shlex's non-POSIX lexer. Only explicitly known
    # environment substitutions are admitted, never command substitution,
    # globs, shell parameter operators or a second round of word splitting.
    value, quote, index = '', '', 0
    while index < len(raw):
        char = raw[index]
        if char in "\"'" and (not quote or quote == char):
            quote = '' if quote else char
            index += 1
            continue
        if char == '\\' and quote != "'":
            index += 1
            if index == len(raw):
                fail('unfinished escape in Cargo invocation')
            if quote == '"' and raw[index] not in '$`"\\\n':
                value += '\\'
            if raw[index] != '\n':
                value += raw[index]
            index += 1
            continue
        if char == '$' and quote != "'":
            match = re.match(r'\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))', raw[index:])
            name = (match.group(1) or match.group(2)) if match else None
            if name not in variables or name not in os.environ:
                fail('dynamic Cargo selection is unsupported; use a literal selector or configured CARGO_BUILD_TARGET')
            replacement = os.environ[name]
            if not quote and any(char.isspace() or char in '*?[' for char in replacement):
                fail('Cargo argument expansion would split or glob: ' + name)
            value += replacement
            index += len(match.group(0))
            continue
        if (char == '`' and quote != "'") or (not quote and char in '*?[]{}~'):
            fail('dynamic Cargo argument is unsupported: ' + raw)
        value += char
        index += 1
    if quote:
        fail('unfinished quote in Cargo invocation')
    return value


def influences(name):
    return name in ('PATH', 'DSR_TARGET_TRIPLE') or name.startswith(('CARGO_', 'RUST', 'XWIN_')) or bool(re.search(
        r'(^|_)(CC|CXX|CPP|AR|RANLIB|LD|CFLAGS|CXXFLAGS|CPPFLAGS|LDFLAGS|SDKROOT|MACOSX_DEPLOYMENT_TARGET)($|_)', name))


def cargo_configuration():
    # Cargo searches from cwd towards the filesystem root (and CARGO_HOME).
    # Strict staging has already excluded inherited/private-home config, but
    # tracked .cargo/config{,.toml} remains a legitimate source of selection.
    # Read only the literal selectors we can attest, preserving Cargo's nearer
    # file precedence and config-relative executable paths. Do not approximate
    # cfg expressions, aliases, includes, or configuration-driven env changes.
    paths = []
    for directory in reversed([pathlib.Path.cwd(), *pathlib.Path.cwd().parents]):
        legacy, modern = directory / '.cargo/config', directory / '.cargo/config.toml'
        if legacy.exists() or legacy.is_symlink():
            paths.append(legacy)
        elif modern.exists() or modern.is_symlink():
            paths.append(modern)
    cargo_home = pathlib.Path(os.environ.get('CARGO_HOME', str(pathlib.Path.home() / '.cargo')))
    for name in ('config', 'config.toml'):
        path = cargo_home / name
        if path.exists() or path.is_symlink():
            if path not in paths:
                fail('strict toolchain attestation forbids private-home Cargo configuration')
    config, receipts = {'build': {}, 'target': {}, 'alias': {}}, []
    if not paths:
        return config, receipts
    try:
        import tomllib
    except ImportError:
        fail('Python 3.11+ is required to attest a tracked Cargo configuration file')
    for path in paths:
        if path.is_symlink() or not path.is_file():
            fail('Cargo configuration must be a regular file: ' + str(path))
        raw = path.read_bytes()
        try:
            current = tomllib.loads(raw.decode('utf-8'))
        except (ValueError, UnicodeError) as error:
            fail('invalid Cargo configuration: ' + str(error))
        if 'include' in current:
            fail('Cargo configuration includes require an explicitly attested selection')
        if any(influences(name) for name in current.get('env', {})):
            fail('Cargo configuration changes the compiler environment; use the configured build environment')
        for section in ('build', 'target', 'alias'):
            if section in current and not isinstance(current[section], dict):
                fail('invalid Cargo configuration section: ' + section)
        build = dict(current.get('build', {}))
        for key in ('rustc', 'rustc-wrapper', 'rustc-workspace-wrapper'):
            if key in build:
                if not isinstance(build[key], str):
                    fail('Cargo build.' + key + ' must be a literal executable path')
                if '/' in build[key] and not pathlib.Path(build[key]).is_absolute():
                    build[key] = str((path.parent.parent / build[key]).resolve())
        config['build'].update(build)
        for target, values in current.get('target', {}).items():
            if not isinstance(values, dict):
                fail('invalid Cargo target configuration')
            values = dict(values)
            if target.startswith('cfg(') and ('linker' in values or 'rustflags' in values):
                fail('Cargo cfg-based compiler selection is not statically attested; use an exact target table')
            if 'linker' in values:
                if not isinstance(values['linker'], str):
                    fail('Cargo target linker must be a literal executable path')
                if '/' in values['linker'] and not pathlib.Path(values['linker']).is_absolute():
                    values['linker'] = str((path.parent.parent / values['linker']).resolve())
            config['target'].setdefault(target, {}).update(values)
        config['alias'].update(current.get('alias', {}))
        receipts.append({'path': str(path), 'sha256': hashlib.sha256(raw).hexdigest()})
    return config, receipts


cargo_config, cargo_config_receipts = (({'build': {}, 'target': {}, 'alias': {}}, [])
                                     if mode == 'target' else cargo_configuration())


def joined_shell_lines(text):
    result, quote, index = '', '', 0
    while index < len(text):
        char = text[index]
        if char == '\\' and quote != "'" and index + 1 < len(text):
            if text[index + 1] != '\n':
                result += text[index:index + 2]
            index += 2
            continue
        if char in "\"'" and (not quote or quote == char):
            quote = '' if quote else char
        result += char
        index += 1
    return result


def invocation_selection():
    try:
        lexer = shlex.shlex(joined_shell_lines(command), posix=False, punctuation_chars=';&|()<>\n')
        lexer.whitespace = ' \t\r'
        lexer.whitespace_split = True
        tokens = list(lexer)
    except ValueError as error:
        fail('cannot read Cargo invocation: ' + str(error))
    # Simple foreground command lists are the boundary. Even a stateless
    # marker can mutate the caller through a parameter-assignment/arithmetic
    # expansion, so inspect all words, including redirection operands.
    for raw in tokens:
        quote, index = '', 0
        while index < len(raw):
            char = raw[index]
            if char == '\\' and quote != "'":
                index += 2
                continue
            if char in "\"'" and (not quote or quote == char):
                quote = '' if quote else char
            if char == '$' and quote != "'" and (raw.startswith(('$((', '$['), index) or
                    re.match(r'\$\{[A-Za-z_][A-Za-z0-9_]*(?:\[|:?=)', raw[index:])):
                fail('shell word mutation is outside the attested Cargo invocation')
            index += 1
    statements, current = [], []
    for token in tokens:
        if token and all(char in ';&|()\n' for char in token):
            if token == '&':
                fail('background Cargo commands cannot be bounded by the final identity check')
            if current:
                statements.append(current)
                current = []
            if '(' in token or ')' in token or token == '&':
                statements.append(['__unsupported_shell_context__'])
        else:
            current.append(token)
    if current:
        statements.append(current)

    selections, commands, assigned_environment, context_change = [], [], set(), None
    for words in statements:
        # A redirection can occur anywhere in a simple command: arguments
        # after it still reach Cargo. Remove each operator/operand, preserving
        # subsequent selectors instead of truncating at the first redirection.
        # Here-documents and process substitutions need a full shell parser;
        # refuse them rather than treating their bodies as Cargo invocations.
        arguments, index = [], 0
        while index < len(words):
            token = words[index]
            if token and all(char in '<>&|' for char in token):
                if token not in ('<', '>', '>>', '<>', '>|', '>&', '<&', '&>', '&>>') or \
                        index + 1 == len(words) or \
                        all(char in '<>&|()' for char in words[index + 1]):
                    fail('unsupported shell redirection in the attested Cargo command')
                if arguments and arguments[-1].isdigit():
                    arguments.pop()
                index += 2
                continue
            arguments.append(token)
            index += 1
        words = arguments
        if not words:
            continue
        assignments, cursor = {}, 0
        while cursor < len(words) and re.match(r'^[A-Za-z_][A-Za-z0-9_]*(?:\[[^]]*\])?\+?=', words[cursor]):
            name, value = words[cursor].split('=', 1)
            if name.endswith('+') or '[' in name:
                fail('shell append/array assignments are outside the attested Cargo invocation')
            assignments[name] = value
            cursor += 1
        if cursor == len(words):
            if any(influences(name) for name in assignments):
                context_change = 'shell environment assignment'
            continue
        program = shell_word(words[cursor])
        cursor += 1
        if program == 'command':
            if cursor < len(words) and words[cursor] == '--':
                cursor += 1
            if cursor == len(words):
                continue
            program = shell_word(words[cursor])
            if program in ('-v', '-V'):
                continue  # Command lookup queries do not execute their operands.
            if program.startswith('-'):
                fail('unsupported command wrapper options in the attested Cargo invocation')
            cursor += 1
        if program == 'env':
            while cursor < len(words) and re.match(r'^[A-Za-z_][A-Za-z0-9_]*\+?=', words[cursor]):
                name, value = words[cursor].split('=', 1)
                if name.endswith('+'):
                    fail('shell append assignments are outside the attested Cargo invocation')
                assignments[name] = value
                cursor += 1
            if cursor == len(words):
                continue
            if words[cursor].startswith('-') and any('cargo' in raw for raw in words[cursor:]):
                fail('env options around Cargo are unsupported; configure the build environment')
            program = shell_word(words[cursor])
            cursor += 1
        if program != 'cargo':
            if pathlib.PurePosixPath(program).name == 'cargo' or \
                    (program in ('rustup', 'sh', 'bash', 'zsh', 'dash', 'env', 'exec', 'eval', 'source', '.') and
                     any('cargo' in raw for raw in words[cursor:])):
                fail('wrapped Cargo invocation is unsupported; use a direct cargo command')
            # These builtins/reserved words can alter shell variables, lookup,
            # control flow or invocation scope. Do not infer their effects.
            if program in ('cd', 'pushd', 'popd', 'source', '.', 'eval', 'exec', 'exit', 'return',
                           'export', 'unset', 'set', 'shopt', 'alias', 'unalias',
                           'declare', 'typeset', 'readonly', 'local', 'read', 'readarray',
                           'mapfile', 'getopts', 'let', 'hash', 'enable', 'trap', 'builtin', 'command',
                           'if', 'then', 'elif', 'else', 'fi', 'for', 'while', 'until', 'do', 'done',
                           'case', 'esac', 'select', 'in', 'break', 'continue', 'function', 'functions',
                           'unfunction', 'autoload', 'time', '!', 'coproc',
                           '__unsupported_shell_context__'):
                context_change = program
            if program == 'printf' and cursor < len(words) and shell_word(words[cursor]).startswith('-v'):
                context_change = 'printf -v'
            continue
        if context_change:
            fail('Cargo context changes inside build_cmd (' + context_change +
                 '); configure its environment/cwd outside the command')
        env = dict(os.environ)
        assigned_environment.update(assignments)
        for name, raw in assignments.items():
            if name in ('CARGO_HOME', 'CARGO_TARGET_DIR'):
                fail('build_cmd cannot replace the admitted ' + name)
            env[name] = shell_word(raw)
        argv = [shell_word(raw, ('CARGO_BUILD_TARGET', 'CARGO_TARGET_DIR', 'CARGO_HOME', 'DSR_TARGET_TRIPLE'))
                for raw in words[cursor:]]
        toolchain = env.get('RUSTUP_TOOLCHAIN') or None
        explicit_toolchain = False
        if argv and argv[0].startswith('+'):
            toolchain, argv = argv[0][1:], argv[1:]
            explicit_toolchain = True
            if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', toolchain):
                fail('Cargo +toolchain must be one literal installed toolchain name')
        for arg in argv:
            if arg == '--config' or arg.startswith('--config=') or arg == '-C' or arg.startswith('-C'):
                fail('Cargo --config/-C changes selection outside the attested invocation; use the configured build environment/cwd')
        # Only reviewed Cargo global options can precede the subcommand. Cargo
        # aliases and opaque shell drivers cannot prove which compiler ran.
        cursor = 0
        while cursor < len(argv) and argv[cursor].startswith('-'):
            option = argv[cursor]
            if option in ('-Z', '--color'):
                cursor += 2
            elif option in ('-v', '-vv', '--verbose', '-q', '--quiet', '--locked', '--offline', '--frozen') or \
                    option.startswith(('-Z', '--color=')):
                cursor += 1
            else:
                fail('unsupported Cargo global selector: ' + option)
        if cursor >= len(argv) or not re.fullmatch(r'[a-z][a-z0-9-]*', argv[cursor]):
            fail('a direct Cargo subcommand is required for strict toolchain attestation')
        subcommand = argv[cursor]
        if subcommand in cargo_config['alias']:
            fail('Cargo alias cannot be attested as a direct compiler invocation: ' + subcommand)
        if re.search(r'(?:^|\s)-C\s*linker(?:[=\s]|$)', ' '.join(argv)) or \
                (subcommand == 'rustc' and '--' in argv and
                 any(arg == '--target' or arg.startswith('--target=') for arg in argv[argv.index('--') + 1:])):
            fail('cargo rustc compiler selectors require an explicit target/linker configuration')
        commands.append(subcommand)
        targets, manifests = [], []
        while cursor < len(argv):
            arg = argv[cursor]
            if arg == '--target':
                cursor += 1
                if cursor >= len(argv):
                    fail('Cargo --target requires a literal target')
                targets.append(argv[cursor])
            elif arg.startswith('--target='):
                targets.append(arg.split('=', 1)[1])
            elif arg in ('--manifest-path', '-m'):
                cursor += 1
                if cursor >= len(argv):
                    fail('Cargo --manifest-path requires a literal manifest')
                manifests.append(argv[cursor])
            elif arg.startswith('--manifest-path='):
                manifests.append(arg.split('=', 1)[1])
            elif arg.startswith('-m'):
                manifests.append(arg[2:].removeprefix('='))
            cursor += 1
        if mode in ('metadata', 'context') and any(
                not manifest or pathlib.Path(manifest).resolve() != (pathlib.Path.cwd() / 'Cargo.toml').resolve()
                for manifest in manifests):
            fail('selected Cargo manifest differs from the strict source root; use its root Cargo.toml')
        if len(set(targets)) > 1:
            fail('multiple Cargo targets cannot share one toolchain identity receipt')
        target = targets[0] if targets else env.get('CARGO_BUILD_TARGET', cargo_config['build'].get('target', ''))
        if not isinstance(target, str) or (target and not re.fullmatch(r'[A-Za-z0-9_]+(?:-[A-Za-z0-9_]+)+(?:\.[0-9.]+)?', target)):
            fail('Cargo target must be a literal target triple, not a dynamic or JSON target')
        selection = {'toolchain': toolchain, 'target': target,
                     'environment': {name: value for name, value in env.items() if influences(name)}}
        # An explicit + selector has higher priority than RUSTUP_TOOLCHAIN.
        selection['environment']['RUSTUP_TOOLCHAIN'] = toolchain or ''
        selections.append((selection, env, explicit_toolchain))
    if context_change:
        fail('Cargo context changes inside build_cmd (' + context_change +
             '); configure its environment/cwd outside the command')
    if not selections:
        fail('strict toolchain attestation requires a direct Cargo invocation in build_cmd')
    if any(selection[0] != selections[0][0] for selection in selections[1:]):
        fail('conflicting Cargo toolchain, target or environment selections in build_cmd')
    selection, env, _ = selections[0]
    if selection['toolchain']:
        env['RUSTUP_TOOLCHAIN'] = selection['toolchain']
    return selection, env, any(row[2] for row in selections), sorted(set(commands)), sorted(assigned_environment)


selection, probe_env, explicit_toolchain, cargo_commands, assigned_environment = invocation_selection()

if mode == 'target':
    # This is a selection check, not executable or binary ABI attestation.
    # Never run the command: all task variants are checked before the first
    # worker starts, so a hardcoded primary cannot produce partial releases.
    expected = os.environ.get('DSR_TARGET_TRIPLE', '')
    if not expected or selection['target'] != expected:
        fail('Cargo selects ' + repr(selection['target']) + ' but native task requires ' + repr(expected))
    if any(probe_env.get(name) != os.environ.get(name)
           for name in ('CARGO_BUILD_TARGET', 'DSR_TARGET_TRIPLE')):
        fail('build_cmd cannot override the native task target environment')
    print(expected)
    sys.exit(0)


def run(argv, required=True, timeout=60):
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, env=probe_env)
    except (OSError, subprocess.TimeoutExpired) as error:
        fail('cannot run ' + argv[0] + ': ' + str(error))
    if result.returncode and required:
        fail('toolchain probe failed for ' + argv[0] + ': ' + result.stderr.strip())
    return (result.stdout or result.stderr).strip()

cargo_argv = ['cargo'] + (['+' + selection['toolchain']] if explicit_toolchain else [])
if mode == 'metadata':
    try:
        metadata = json.loads(run(cargo_argv + ['metadata', '--locked', '--offline', '--all-features',
                                   '--format-version=1', '--manifest-path', str(pathlib.Path.cwd() / 'Cargo.toml')],
                                  timeout=300))
    except ValueError as error:
        fail('invalid selected Cargo metadata: ' + str(error))
    json.dump(metadata, sys.stdout, sort_keys=True)
    sys.stdout.write('\n')
    sys.exit(0)

def is_script(path):
    with open(path, 'rb') as stream:
        return stream.read(2) == b'#!'

rustup = shutil.which('rustup', path=probe_env.get('PATH'))
rustup_digest = digest(pathlib.Path(rustup).resolve()) if rustup else None

def identity(name, program, version_args, rustup_tool=None, required=True):
    selected = shutil.which(program, path=probe_env.get('PATH'))
    if not selected:
        if required:
            fail('required executable not found on the build PATH: ' + program)
        return None
    selected = pathlib.Path(selected).absolute()
    resolved_selected = selected.resolve()
    version = run([str(selected), *version_args]) if version_args else ''
    if version_args and version_args[-1] != '-vV':
        version = version.splitlines()[0] if version else ''
    record = {'program': program, 'selected_path': str(selected),
              'selected_sha256': digest(resolved_selected),
              'selected_kind': 'script' if is_script(resolved_selected) else 'executable',
              'version': version}
    actual = None
    proxy = rustup_digest is not None and record['selected_sha256'] == rustup_digest
    if rustup_tool and rustup and proxy:
        which = run([rustup, 'which', rustup_tool])
        if not which or not pathlib.Path(which).is_file():
            fail('rustup did not resolve the selected ' + rustup_tool)
        actual = pathlib.Path(which).resolve()
    if sys.platform == 'darwin' and str(resolved_selected) in (
            '/usr/bin/cc', '/usr/bin/c++', '/usr/bin/clang', '/usr/bin/clang++', '/usr/bin/ld'):
        tool = {'/usr/bin/c++': 'clang++', '/usr/bin/clang++': 'clang++', '/usr/bin/ld': 'ld'}.get(
            str(resolved_selected), 'clang')
        found = run(['xcrun', '--find', tool])
        if found and pathlib.Path(found).is_file():
            actual = pathlib.Path(found).resolve()
    if actual is not None and actual != resolved_selected:
        record['resolved_path'] = str(actual)
        record['resolved_sha256'] = digest(actual)
        record['resolved_kind'] = 'script' if is_script(actual) else 'executable'
    return record

triple = selection['target']
cargo_version_args = (['+' + selection['toolchain']] if explicit_toolchain else []) + ['-vV']
compiler = probe_env.get('RUSTC') or probe_env.get('CARGO_BUILD_RUSTC') or cargo_config['build'].get('rustc') or 'rustc'
tools = {'cargo': identity('cargo', 'cargo', cargo_version_args, 'cargo'),
         'rustc': identity('rustc', compiler, ['-vV'], 'rustc')}
if not triple:
    triple = next((line.split(': ', 1)[1] for line in tools['rustc']['version'].splitlines()
                   if line.startswith('host: ')), '')
    if not triple:
        fail('rustc did not report its default host target')
linker_variable = 'CARGO_TARGET_' + re.sub(r'[^A-Za-z0-9]', '_', triple).upper() + '_LINKER'
configured_linker = cargo_config['target'].get(triple, {}).get('linker', '')
linker = probe_env.get(linker_variable) or configured_linker
rustflags = [value for name, value in probe_env.items() if name.endswith('RUSTFLAGS')]
rustflags += [cargo_config['build'].get('rustflags', []),
              cargo_config['target'].get(triple, {}).get('rustflags', [])]
for flags in rustflags:
    text = ' '.join(flags) if isinstance(flags, list) else flags
    if not isinstance(text, str) or re.search(r'(?:^|\s|\x1f)-C\s*linker(?:[=\s]|$)', text):
        fail('rustflags linker overrides require an explicit target linker configuration')
for wrapper in ('RUSTC_WRAPPER', 'RUSTC_WORKSPACE_WRAPPER',
                'CARGO_BUILD_RUSTC_WRAPPER', 'CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER'):
    if probe_env.get(wrapper):
        tools[wrapper.lower()] = identity(wrapper.lower(), probe_env[wrapper], [])
for key in ('rustc-wrapper', 'rustc-workspace-wrapper'):
    if cargo_config['build'].get(key) and not probe_env.get(key.upper().replace('-', '_')) and \
            not probe_env.get('CARGO_BUILD_' + key.upper().replace('-', '_')):
        tools[key.replace('-', '_')] = identity(key, cargo_config['build'][key], [])
# An explicitly configured linker must exist; the default cc may legitimately
# be absent on hosts that link through cargo-zigbuild.
default_linker = identity('linker', linker or 'cc', ['--version'], required=bool(linker))
if default_linker:
    tools['linker'] = default_linker
# Cargo subcommands named by the build command, and helpers DSR itself routes
# the build through (cargo-zigbuild and zig for the portable glibc floor).
plugins = set(cargo_commands)
plugins.update(name[len('cargo-'):] for name in extra.split() if name.startswith('cargo-'))
for sub in sorted(plugins):
    program = 'cargo-' + sub
    if shutil.which(program, path=probe_env.get('PATH')):
        tools[program] = identity(program, program, ['--version'], program, required=False)
for name in sorted(set(extra.split())):
    if not name.startswith('cargo-') and name not in tools:
        record = identity(name, name, ['version' if name == 'zig' else '--version'], required=False)
        if record:
            tools[name] = record
result = {'schema_version': 1, 'cwd': os.getcwd(), 'target_triple': triple,
          'linker_variable': linker_variable if probe_env.get(linker_variable) else None, 'tools': tools,
          'selection': {'rustup_toolchain': selection['toolchain'],
                        'cargo_commands': cargo_commands,
                        'cargo_config': cargo_config_receipts}}

if mode == 'context':
    # Transfer only selection-induced changes; the cache process already has
    # the configured build environment. This value is neither logged nor
    # retained in a receipt, and the original build keeps its shell scoping.
    json.dump({'identity': result, 'cargo_argv': cargo_argv, 'compiler': compiler,
               'assigned_environment': assigned_environment,
               'environment': {key: value for key, value in probe_env.items()
                               if os.environ.get(key) != value}}, sys.stdout, sort_keys=True)
    sys.stdout.write('\n')
    sys.exit(0)

if mode == 'record':
    try:
        fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    except OSError as error:
        fail('cannot create identity receipt ' + output + ': ' + str(error))
    with os.fdopen(fd, 'w') as stream:
        json.dump(result, stream, sort_keys=True)
        stream.write('\n')
else:
    try:
        with open(output) as stream:
            recorded = json.load(stream)
    except (OSError, ValueError) as error:
        fail('cannot read identity receipt ' + output + ': ' + str(error))
    if recorded != result:
        changed = sorted(name for name in set(recorded.get('tools', {})) | set(tools)
                         if recorded.get('tools', {}).get(name) != tools.get(name))
        fail('build toolchain changed during the build (' + (', '.join(changed) or 'context') +
             '); refusing to collect its artifacts')
PY
    printf 'DSR_TOOLCHAIN_IDENTITY_PY\n'
}

# Validate a matrix command against the exact worker target without executing
# the command or using the coordinator's ambient Rust/Cargo configuration.
_act_validate_native_target_command() {
    local build_cmd="$1" build_env="$2" selected_triple="$3" script pair
    local -a pairs=()
    [[ -n "$selected_triple" ]] || return 4
    while IFS= read -r pair; do
        [[ -z "$pair" ]] && continue
        [[ "$pair" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || return 4
        pairs+=("$pair")
    done <<< "$build_env"
    script=$(_act_toolchain_identity_script target /dev/null "$build_cmd") || return 4
    local actual
    actual=$(env -i "${pairs[@]}" "$BASH" -c "$script") || return 4
    [[ "$actual" == "$selected_triple" ]] || return 4
}

# Run native build on remote host via SSH
# Usage: act_run_native_build <tool_name> <platform> <version> [run_id]
#        [remote_path_override] [release_git_sha] [release_git_ref] [bound_host]
#        [selected_triple] [ordinary_source_root]
# Returns: JSON result with status, exit_code, artifact info
# Remove a per-target build stage root (dsr-build-*) on its host. rm -rf /
# rmdir do not follow the cargo cache symlinks/junctions inside. Honors
# DSR_KEEP_BUILD_STAGES=1 for post-mortems; never fails the build.
_act_remove_build_stage_root() {
    local host="$1"
    local stage_root="${2:-}"

    [[ -n "$stage_root" && "$stage_root" == */dsr-build-* ]] || return 0
    if [[ "${DSR_KEEP_BUILD_STAGES:-0}" == "1" ]]; then
        _log_info "Retaining build stage root $stage_root on $host (DSR_KEEP_BUILD_STAGES=1)"
        return 0
    fi
    local cleanup_ok=true
    if _act_is_windows_host "$host"; then
        local win_cleanup_path
        win_cleanup_path=$(_act_windows_cmd_path "$stage_root")
        _act_ssh_exec "$host" \
            "$(_act_windows_cmd_via_powershell "if exist \"$win_cleanup_path\" rmdir /s /q \"$win_cleanup_path\"")" \
            120 >/dev/null 2>&1 || cleanup_ok=false
    else
        _act_ssh_exec "$host" \
            "rm -rf '${stage_root//\'/\'\\\'\'}'" \
            120 >/dev/null 2>&1 || cleanup_ok=false
    fi
    if ! $cleanup_ok; then
        _log_warn "Could not remove build stage root $stage_root on $host"
    fi
    return 0
}

# Cancellation path for the stage roots above. A cancelled worker TERMs the
# whole build process group, which never reaches the ordinary removals after
# the build command, so each source copy (multi-GB for large repos) would stay
# in /var/tmp or the host's build_root with nothing to reap it. Installed only
# inside the command-substitution subshell that runs act_run_native_build, so
# no caller's traps are replaced. Dispositions are reset (not ignored) first so
# the cleanup's own ssh/timeout children keep normal signal handling.
_act_stage_cleanup_on_signal() {
    local signal_status="$1" stage_root
    trap - INT TERM
    for stage_root in "${_ACT_SIGNAL_STAGE_ROOTS[@]}"; do
        _act_remove_build_stage_root "$_ACT_SIGNAL_STAGE_HOST" "$stage_root" 2>/dev/null
    done
    exit "$signal_status"
}

act_run_native_build() {
    local tool_name="$1"
    local platform="$2"
    local version="$3"
    local run_id="${4:-}"
    local remote_path_override="${5:-}"
    local release_git_sha="${6:-}"
    local release_git_ref="${7:-}"
    local bound_host="${8:-}"
    local selected_triple="${9:-}"
    local ordinary_source_root="${10:-}"

    if [[ -n "$ordinary_source_root" &&
          ( -n "$remote_path_override" || -n "$release_git_sha" || -n "$release_git_ref" || -z "$bound_host" ) ]]; then
        _log_error "Ordinary synchronized source roots cannot replace strict snapshot identity"
        return 4
    fi

    # A strict identity must never degrade to ordinary staging when a source
    # binding is absent. Check before configuration, SSH, or filesystem work.
    if [[ -n "$release_git_sha" || -n "$release_git_ref" ]] && \
       [[ -z "$remote_path_override" || -z "$bound_host" ]]; then
        _log_error "Strict native build requires a bound host and source root"
        jq -nc '{status: "error", exit_code: 4, error: "Missing strict native source binding"}'
        return 4
    fi
    if [[ -n "$release_git_sha" || -n "$release_git_ref" ]]; then
        if ! declare -F host_health_is_ready &>/dev/null || \
           ! host_health_is_ready "$bound_host"; then
            _log_error "Pinned strict build host is not ready: $bound_host"
            jq -nc '{status: "error", exit_code: 4, error: "Pinned strict build host is not ready"}'
            return 4
        fi
    fi

    local host
    host="$bound_host"
    [[ -n "$host" ]] || host=$(act_get_native_host "$platform" "$tool_name")
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
    local local_path build_cmd build_env binary_name build_profile
    local config_file="$ACT_REPOS_DIR/${tool_name}.yaml"

    if [[ ! -f "$config_file" ]]; then
        _log_error "Config not found: $config_file"
        jq -nc --arg config_file "$config_file" \
            '{status: "error", exit_code: 4, error: ("Config not found: " + $config_file)}'
        return 4
    fi

    local_path=$(act_get_local_path "$tool_name")
    build_cmd=$(act_get_build_cmd "$tool_name" "$platform") || return 4
    if ! build_env=$(act_get_build_env "$tool_name" "$platform" "$selected_triple"); then
        jq -nc --arg platform "$platform" --arg triple "$selected_triple" \
            '{platform: $platform, target_triple: $triple, status: "error", exit_code: 4,
              error: "Invalid native target environment"}'
        return 4
    fi
    binary_name=$(yq -r '.binary_name // ""' "$config_file" 2>/dev/null)
    build_profile=$(yq -r '.build_profile // "release"' "$config_file" 2>/dev/null)

    local language
    language=$(yq -r '.language // ""' "$config_file" 2>/dev/null)

    # Portable glibc floor for Linux Rust builds, ordinary AND strict (issue
    # #9: a strict focr release once shipped needing GLIBC_2.39 because this
    # gate skipped strict builds). Decided before any environment is frozen
    # into cache contracts or receipts, applied on the build host through a
    # cargo shim that turns `cargo build` into `cargo zigbuild --target
    # <triple>.<floor>`, and enforced on the collected bytes. The applied
    # floor and the enforced floor differ only when the repo's own build_cmd
    # or cross toolchain owns the libc baseline: dsr then applies nothing but
    # still enforces an explicitly configured floor.
    local native_target_triple="" native_target_slug="${platform//\//-}"
    if [[ "$language" == rust ]]; then
        native_target_triple=$(act_get_build_env_value "$build_env" CARGO_BUILD_TARGET 2>/dev/null || true)
    fi
    [[ -z "$selected_triple" ]] || native_target_slug+="-$selected_triple"
    local rust_glibc_floor="" rust_glibc_floor_enforced="" rust_zig_target="" rust_floor_triple=""
    if [[ "$language" == "rust" && "$platform" == linux/* ]] && \
       ! _act_is_windows_host "$host"; then
        local floor_rc=0
        rust_glibc_floor=$(_act_linux_glibc_floor "$tool_name" "$platform" "$config_file" \
            "$build_env" "$build_cmd") || floor_rc=$?
        if [[ "$floor_rc" -ne 4 ]]; then
            rust_glibc_floor_enforced=$(_act_linux_glibc_floor_enforced "$tool_name" "$platform" \
                "$config_file" "$build_env" "$build_cmd") || floor_rc=$?
        fi
        if [[ "$floor_rc" -eq 4 ]]; then
            jq -nc '{status: "error", exit_code: 4, error: "Invalid linux_glibc_floor configuration"}'
            return 4
        fi
        if [[ -n "$rust_glibc_floor" ]]; then
            rust_floor_triple=$(act_get_build_env_value "$build_env" "CARGO_BUILD_TARGET")
            rust_zig_target="${rust_floor_triple}.${rust_glibc_floor}"
            build_env+=$'\n'"DSR_RUST_TARGET=$rust_floor_triple"
            build_env+=$'\n'"DSR_ZIG_TARGET=$rust_zig_target"
            build_env+=$'\n'"DSR_LINUX_GLIBC_FLOOR=$rust_glibc_floor"
            _log_info "Linux glibc floor $rust_glibc_floor active for $platform (cargo build -> cargo zigbuild --target $rust_zig_target)"
        elif [[ -n "$rust_glibc_floor_enforced" ]]; then
            _log_info "Linux glibc floor $rust_glibc_floor_enforced enforced for $platform (the build command owns its toolchain)"
        fi
    fi

    local strict_cache_root strict_cache_contract=''
    strict_cache_root=$(yq -r '.strict_cargo_cache_root // ""' "$config_file" 2>/dev/null) || return 4
    if [[ -n "$strict_cache_root" ]]; then
        if [[ "$language" != rust || -z "$remote_path_override" ]] || \
           _act_is_windows_host "$host" || \
           [[ ! "$strict_cache_root" =~ ^/[A-Za-z0-9_./+-]+$ || "$strict_cache_root" == *..* ]]; then
            _log_error "strict_cargo_cache_root requires strict Unix Rust and a canonical absolute private directory"
            return 4
        fi
        strict_cache_contract=$(jq -nc --arg tool "$tool_name" --arg platform "$platform" \
            --arg profile "$build_profile" --arg command "$build_cmd" --arg environment "$build_env" \
            '{tool: $tool, platform: $platform, profile: $profile, command: $command,
              configured_environment: ($environment | split("\n") | map(select(
                test("^(CARGO_HOME|CARGO_TARGET_DIR|CARGO_BUILD_BUILD_DIR|DSR_RELEASE_GIT_SHA|DSR_RELEASE_GIT_REF|FT_ATOMIC_BUILD_IDENTITY|FT_ATOMIC_BUILD_PROFILE)=") | not)))}') || return 4
    fi

    # A target whose platform differs from the host's is a cross build even
    # when the scheduler labels it "native for this host" (issue #7). The
    # derived CARGO_BUILD_TARGET plus post-collection architecture validation
    # make a silent wrong-arch artifact impossible; this line makes the
    # situation visible in the build log.
    local build_host_platform
    build_host_platform=$(_act_get_host_platform "$host" 2>/dev/null || true)
    if [[ -n "$build_host_platform" && "$build_host_platform" != "$platform" ]]; then
        _log_info "Target $platform is cross for host $host ($build_host_platform); requiring explicit target output"
    fi

    # Check for workspace_binaries (multi-binary Rust workspaces)
    local workspace_binaries
    workspace_binaries=$(_act_workspace_binaries_for_target "$config_file" "$platform") || return 4

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
    if ! build_cmd=$(act_substitute_build_cmd_tokens "$build_cmd" "${binary_name:-$tool_name}" "$version" "$_act_build_os" "$_act_build_arch" "$native_target_triple"); then
        _log_error "Refusing to build $tool_name: build_cmd token substitution rejected an unsafe value (version=$version platform=$platform)"
        jq -nc --arg tool "$tool_name" --arg version "$version" --arg platform "$platform" \
            '{status: "error", exit_code: 4, error: ("unsafe build_cmd token value for " + $tool + " " + $version + " " + $platform)}'
        return 4
    fi

    if [[ -n "$selected_triple" ]] && \
       ! _act_validate_native_target_command "$build_cmd" "$build_env" "$selected_triple"; then
        _log_error "Build command does not select native variant $selected_triple"
        jq -nc --arg platform "$platform" --arg triple "$selected_triple" \
            '{platform: $platform, target_triple: $triple, status: "error", exit_code: 4,
              error: "Build command conflicts with selected native target variant"}'
        return 4
    fi

    # Determine remote path (check host_paths.<host> first, fallback to local_path)
    local remote_path
    remote_path="${remote_path_override:-$ordinary_source_root}"
    if [[ -z "$remote_path" ]]; then
        remote_path=$(yq -r '.host_paths.'"$host"' // ""' "$config_file" 2>/dev/null)
        if [[ -z "$remote_path" ]]; then
            remote_path="$local_path"
        fi
    fi

    # A Windows build host can never use a POSIX source root (issue #8): the
    # sync layer would target the wrong location and the Rust isolation
    # validator rejects the path mid-build with a config-shaped error nothing
    # upstream explains. Fail before any remote work, naming the fix.
    if _act_is_windows_host "$host"; then
        case "$remote_path" in
            [A-Za-z]:[\\/]*|/[A-Za-z]/*) ;;
            *)
                _log_error "Windows host $host needs a drive-qualified source root for $tool_name (set host_paths.$host in repos.d/${tool_name}.yaml, e.g. C:/Users/<user>/$tool_name); got: $remote_path"
                jq -nc --arg host "$host" --arg path "$remote_path" \
                    '{status: "error", exit_code: 4, error: ("Windows host " + $host + " requires a drive-qualified host_paths entry; got: " + $path)}'
                return 4
                ;;
        esac
    fi

    # A strict source root must remain byte-for-byte equal to its tracked
    # archive after the build. Force Rust outputs beside that root, even when a
    # repo config supplied an in-tree CARGO_TARGET_DIR.
    local strict_native_build=false
    [[ -n "$remote_path_override" ]] && strict_native_build=true
    local strict_rust_build=false
    local strict_private_cargo_cache=false strict_cargo_seed_json='null' strict_toolchain_receipt=""
    local build_influence_env_json='{}'
    local cargo_isolation_json='null'
    local nonstrict_stage_root="" nonstrict_source_root="" nonstrict_cargo_home=""
    local nonstrict_sibling_roots_json='[]'
    local nonstrict_sibling_relatives=()
    if [[ "$language" == "rust" && -n "$remote_path_override" ]]; then
        strict_rust_build=true
        if [[ -n "$release_git_sha" || -n "$release_git_ref" ]]; then
            if [[ ! "$release_git_sha" =~ ^[0-9a-f]{40}$ || \
                  "$release_git_sha" =~ ^0{40}$ || \
                  "$release_git_ref" != "v${version#v}" ]]; then
                _log_error "Invalid strict release identity for native Rust build"
                jq -nc '{status: "error", exit_code: 4, error: "Invalid strict Rust release identity"}'
                return 4
            fi
        fi
        local strict_cargo_target_dir="${remote_path%/*}/.cargo-target-${platform//\//-}"
        if [[ -n "$strict_cache_root" ]]; then
            # A retry also gets a fresh final-output destination. The host
            # wrapper refuses any collision rather than reusing stale output.
            strict_cargo_target_dir+="-$(date +%s)-$$-$RANDOM"
        fi
        local canonical_cargo_target_dir="$strict_cargo_target_dir"
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
        if _act_is_windows_host "$host"; then
            strict_cargo_target_dir=$(_act_windows_short_target_directory "$host" "$canonical_cargo_target_dir" "$run_id" "$platform") || return 4
        fi
        while IFS= read -r env_pair; do
            [[ -z "$env_pair" || "$env_pair" == CARGO_TARGET_DIR=* || \
               ( -n "$strict_cache_root" && "$env_pair" == CARGO_BUILD_BUILD_DIR=* ) || \
               "$env_pair" == CARGO_HOME=* || \
               "$env_pair" == DSR_RELEASE_GIT_SHA=* || \
               "$env_pair" == DSR_RELEASE_GIT_REF=* ]] && continue
            if [[ -n "$strict_build_env" ]]; then
                strict_build_env+=$'\n'
            fi
            strict_build_env+="$env_pair"
        done <<< "$build_env"
        if [[ -n "$strict_build_env" ]]; then
            strict_build_env+=$'\n'
        fi
        strict_build_env+="CARGO_TARGET_DIR=$strict_cargo_target_dir"
        if _act_is_windows_host "$host"; then
            local split_storage_status=0
            _act_windows_storage_config "$host" >/dev/null || split_storage_status=$?
            [[ $split_storage_status -eq 0 || $split_storage_status -eq 1 ]] || return 4
            if [[ $split_storage_status -eq 0 ]]; then
                strict_build_env+=$'\n'"TEMP=$strict_cargo_target_dir/scratch"
                strict_build_env+=$'\n'"TMP=$strict_cargo_target_dir/scratch"
                # Existing cache is admitted by offline metadata. Never grow
                # the system-volume cache by downloading during this lane.
                strict_build_env+=$'\n'"CARGO_NET_OFFLINE=true"
            fi
        fi
        if [[ -n "$release_git_sha" ]]; then
            strict_build_env+=$'\n'"DSR_RELEASE_GIT_SHA=$release_git_sha"
            strict_build_env+=$'\n'"DSR_RELEASE_GIT_REF=$release_git_ref"
        fi
        if [[ "$tool_name" == frankenterm ]]; then
            # The sealed family identity binds the committed Cargo profiles,
            # not environment overrides. Check the merged global/target env
            # before deriving that identity or starting any compiler command.
            local profile_override_name
            while IFS= read -r env_pair; do
                [[ "$env_pair" == *=* ]] || continue
                profile_override_name="${env_pair%%=*}"
                if [[ "${profile_override_name^^}" == CARGO_PROFILE_* ]]; then
                    _log_error "FrankenTerm sealed build forbids profile override $profile_override_name; change committed Cargo.toml instead"
                    jq -nc --arg variable "$profile_override_name" \
                        '{status: "error", exit_code: 4, error: ("FrankenTerm sealed build forbids profile override " + $variable + "; change committed Cargo.toml instead")}'
                    return 4
                fi
            done <<< "$strict_build_env"
            local atomic_target atomic_identity
            atomic_target=$(act_get_build_env_value "$strict_build_env" CARGO_BUILD_TARGET) || return 4
            atomic_identity=$(_act_frankenterm_build_identity \
                "$local_path" "$release_git_sha" "$version" \
                "$atomic_target" "$build_profile") || return 4
            # Last assignment is authoritative in both POSIX and Windows
            # launchers and in the recorded build-influence environment.
            strict_build_env+=$'\n'"FT_ATOMIC_BUILD_IDENTITY=$atomic_identity"
            strict_build_env+=$'\n'"FT_ATOMIC_BUILD_PROFILE=$build_profile"
        fi
        if ! _act_is_windows_host "$host"; then
            local cargo_attempt
            cargo_attempt=$(_act_generate_uuid) || return 3
            if ! strict_cargo_seed_json=$(_act_prepare_unix_private_cargo_home \
                    "$host" "$remote_path" "${platform//\//-}-${cargo_attempt//-/}" \
                    "$build_cmd" "$strict_build_env") || \
               ! strict_cargo_home=$(jq -er '.cargo_home' <<< "$strict_cargo_seed_json"); then
                _log_error "Unable to prepare a private strict Cargo cache on $host"
                jq -nc '{status: "error", exit_code: 4, error: "Strict Cargo cache preparation failed"}'
                return 4
            fi
            strict_private_cargo_cache=true
            # Per-attempt toolchain identity receipt beside the snapshot; the
            # snapshot itself must stay byte-identical.
            strict_toolchain_receipt="${remote_path%/*}/.dsr-toolchain-${platform//\//-}-${cargo_attempt//-/}.json"
        fi
        strict_build_env+=$'\n'"CARGO_HOME=$strict_cargo_home"
        build_env="$strict_build_env"

        local windows_build_receipt=false
        if _act_is_windows_host "$host"; then
            windows_build_receipt=true
        fi
        local influence_entries=() influence_name influence_value receipt_influence_name
        while IFS= read -r env_pair; do
            [[ -n "$env_pair" && "$env_pair" == *=* ]] || continue
            influence_name="${env_pair%%=*}"
            influence_value="${env_pair#*=}"
            if _act_is_rust_build_influence_name "$influence_name"; then
                receipt_influence_name="$influence_name"
                if $windows_build_receipt; then
                    receipt_influence_name="${receipt_influence_name^^}"
                fi
                influence_entries+=("$(jq -nc \
                    --arg key "$receipt_influence_name" --arg value "$influence_value" \
                    '{key: $key, value: $value}')")
            fi
        done <<< "$build_env"
        if [[ ${#influence_entries[@]} -gt 0 ]]; then
            if $windows_build_receipt; then
                build_influence_env_json=$(printf '%s\n' "${influence_entries[@]}" | \
                    jq -cs 'reduce .[] as $entry ({}; .[$entry.key] = $entry.value)
                        | to_entries | sort_by(.key) | from_entries') || return 4
            else
                build_influence_env_json=$(printf '%s\n' "${influence_entries[@]}" | \
                    jq -cs 'sort_by(.key) | from_entries') || return 4
            fi
        fi
        cargo_isolation_json=$(jq -nc \
            --arg cargo_home "$strict_cargo_home" \
            --arg snapshot_target_dir "$canonical_cargo_target_dir" \
            --arg target_dir "$strict_cargo_target_dir" '
                {
                    mode: "strict-release-snapshot",
                    source_boundary: "canonical-fresh-source-root",
                    cargo_home: $cargo_home,
                    target_dir: $target_dir,
                    canonical_target_dir: $target_dir,
                    snapshot_target_dir: $snapshot_target_dir,
                    ancestor_config_policy: "reject",
                    cache_reuse: ["registry", "git"]
                }
            ') || return 4
        if $strict_private_cargo_cache; then
            cargo_isolation_json=$(jq --argjson seed "$strict_cargo_seed_json" \
                '.cache_reuse = [] | .dependency_cache = {mode: "private-copy", seed: $seed}' \
                <<< "$cargo_isolation_json") || return 4
        fi
        if [[ -n "$strict_cache_root" ]]; then
            cargo_isolation_json=$(jq --arg root "$strict_cache_root" \
                '.intermediate_cache = {mode: "host-private-cargo-build-dir-v1", root: $root,
                  custody: "exclusive-build-and-final-output-detachment", final_outputs: "per-run"}' \
                <<< "$cargo_isolation_json") || return 4
        fi
    elif [[ "$language" == "rust" ]]; then
        # Ordinary Rust builds must be just as independent of operator Cargo
        # configuration as strict release builds.  Remove any configured
        # CARGO_HOME (it can contain aliases, patches, source replacement, and
        # target/linker settings) and ensure the target directory is absolute
        # before the source is staged outside the operator's home directory.
        # An absolute target keeps artifact collection deterministic after the
        # working directory moves to the isolated source copy. On Unix hosts the
        # fresh CARGO_HOME holds private dependency-cache copies, prepared by
        # _act_prepare_unix_nonstrict_cargo_home just before the build runs.
        local nonstrict_env="" nonstrict_pair nonstrict_target_dir=""
        local isolation_uuid isolation_suffix isolation_root
        if [[ ! "$tool_name" =~ ^[A-Za-z0-9_.-]+$ || \
              ! "${platform//\//-}" =~ ^[A-Za-z0-9_.-]+$ ]] || \
           ! isolation_uuid=$(_act_generate_uuid); then
            _log_error "Unable to derive a unique Rust isolation path"
            jq -nc '{status: "error", exit_code: 4, error: "Invalid Rust isolation identity"}'
            return 4
        fi
        isolation_suffix="${isolation_uuid//-/}"
        while IFS= read -r nonstrict_pair; do
            [[ -z "$nonstrict_pair" ]] && continue
            case "$nonstrict_pair" in
                CARGO_HOME=*) continue ;;
                CARGO_TARGET_DIR=*)
                    nonstrict_target_dir="${nonstrict_pair#*=}"
                    continue
                    ;;
            esac
            [[ -n "$nonstrict_env" ]] && nonstrict_env+=$'\n'
            nonstrict_env+="$nonstrict_pair"
        done <<< "$build_env"

        if _act_is_windows_host "$host"; then
            case "$nonstrict_target_dir" in
                [A-Za-z]:[\\/]*) ;;
                *) nonstrict_target_dir="${remote_path%/*}/.dsr-cargo-target-${tool_name}-${platform//\//-}" ;;
            esac
            case "$remote_path" in
                # Keep the Windows staging prefix deliberately short. Vendored
                # test fixtures can already approach MAX_PATH before DSR adds
                # its isolation directory, and PowerShell Copy-Item then fails
                # before the compiler starts.
                [A-Za-z]:[\\/]*) isolation_root="${remote_path:0:1}:/d" ;;
                /[A-Za-z]/*) isolation_root="${remote_path:1:1}:/d" ;;
                *)
                    _log_error "Windows Rust source path has no drive-qualified isolation root"
                    jq -nc '{status: "error", exit_code: 4, error: "Invalid Windows Rust source path"}'
                    return 4
                    ;;
            esac
        else
            case "$nonstrict_target_dir" in
                /*) ;;
                *) nonstrict_target_dir="${remote_path%/*}/.dsr-cargo-target-${tool_name}-${platform//\//-}" ;;
            esac
            case "$platform" in
                darwin/*) isolation_root="/private/tmp" ;;
                # /var/tmp, not /tmp: Linux /tmp is commonly a RAM-backed
                # tmpfs, and the staged source copy (workspace + every
                # sibling crate) can run to tens of GB per target.
                *) isolation_root="/var/tmp" ;;
            esac
            local host_build_root="" host_build_root_rc=0
            host_build_root=$(_act_get_host_build_root "$host") || host_build_root_rc=$?
            if [[ "$host_build_root_rc" -eq 4 ]]; then
                jq -nc '{status: "error", exit_code: 4, error: "Invalid hosts.yaml build_root"}'
                return 4
            fi
            if [[ -n "$host_build_root" ]]; then
                isolation_root="$host_build_root"
            fi
        fi
        if [[ -z "$nonstrict_target_dir" || "$nonstrict_target_dir" == *$'\n'* || \
              "$nonstrict_target_dir" == *$'\r'* ]]; then
            _log_error "Unable to derive an isolated Cargo target directory"
            jq -nc '{status: "error", exit_code: 4, error: "Invalid Cargo isolation target directory"}'
            return 4
        fi
        if [[ -n "$selected_triple" ]]; then
            # Even a configured CARGO_TARGET_DIR is a base directory for a
            # matrix. Fresh output per attempt prevents a failed/no-op retry
            # from collecting bytes left by any preceding build.
            nonstrict_target_dir="${nonstrict_target_dir%/}/dsr-${selected_triple}-${isolation_suffix}"
        fi
        [[ -n "$nonstrict_env" ]] && nonstrict_env+=$'\n'
        nonstrict_env+="CARGO_TARGET_DIR=$nonstrict_target_dir"

        if _act_is_windows_host "$host"; then
            # Leave almost the entire MAX_PATH budget to vendored source file
            # names. The directory is still unique and retains the guarded
            # dsr-build-* shape used by cleanup.
            nonstrict_stage_root="${isolation_root%/}/dsr-build-${isolation_suffix:0:12}"
            nonstrict_source_root="$nonstrict_stage_root/s"
            nonstrict_cargo_home="$nonstrict_stage_root/c"
        else
            nonstrict_stage_root="${isolation_root%/}/dsr-build-${tool_name}-${platform//\//-}-${isolation_suffix}"
            nonstrict_source_root="$nonstrict_stage_root/source"
            nonstrict_cargo_home="$nonstrict_stage_root/cargo-home"
        fi
        nonstrict_env+=$'\n'"CARGO_HOME=$nonstrict_cargo_home"
        build_env="$nonstrict_env"

        # `act_sync_sources` places every declared sibling crate beside the
        # primary workspace and rewrites absolute Cargo paths to `../name`.
        # Preserve that layout inside the isolated parent or hermetic staging
        # would break legitimate path dependencies (Agent Mail, beads_rust,
        # and other multi-repo Rust releases rely on this contract).
        local sibling_count sibling_index sibling_relative sibling_local
        local sibling_remote sibling_staged
        local sibling_entries=() sibling_seen=" "
        sibling_count=$(yq -r '.sibling_crates // [] | length' "$config_file" 2>/dev/null || echo 0)
        [[ "$sibling_count" =~ ^[0-9]+$ ]] || sibling_count=0
        for ((sibling_index = 0; sibling_index < sibling_count; sibling_index++)); do
            sibling_relative=$(yq -r ".sibling_crates[$sibling_index].relative_path // \"\"" \
                "$config_file" 2>/dev/null || true)
            if [[ -z "$sibling_relative" ]]; then
                sibling_local=$(yq -r ".sibling_crates[$sibling_index].local_path // \"\"" \
                    "$config_file" 2>/dev/null || true)
                sibling_relative="${sibling_local##*/}"
            fi
            if [[ ! "$sibling_relative" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ || \
                  "$sibling_relative" == *..* || \
                  "$sibling_relative" == "source" || \
                  "$sibling_relative" == "cargo-home" || \
                  "$sibling_seen" == *" $sibling_relative "* ]]; then
                _log_error "Invalid or duplicate isolated sibling crate name: $sibling_relative"
                jq -nc '{status: "error", exit_code: 4, error: "Invalid Rust sibling isolation layout"}'
                return 4
            fi
            sibling_seen+="$sibling_relative "
            sibling_remote="${remote_path%/*}/$sibling_relative"
            sibling_staged="$nonstrict_stage_root/$sibling_relative"
            nonstrict_sibling_relatives+=("$sibling_relative")
            sibling_entries+=("$(jq -nc \
                --arg relative_path "$sibling_relative" \
                --arg original_source_root "$sibling_remote" \
                --arg source_root "$sibling_staged" \
                '{relative_path: $relative_path,
                  original_source_root: $original_source_root,
                  source_root: $source_root}')")
        done
        if [[ ${#sibling_entries[@]} -gt 0 ]]; then
            nonstrict_sibling_roots_json=$(printf '%s\n' "${sibling_entries[@]}" | jq -cs '.') || return 4
        fi

        local nonstrict_entries=() nonstrict_name nonstrict_value
        local nonstrict_windows_receipt=false
        _act_is_windows_host "$host" && nonstrict_windows_receipt=true
        while IFS= read -r nonstrict_pair; do
            [[ -n "$nonstrict_pair" && "$nonstrict_pair" == *=* ]] || continue
            nonstrict_name="${nonstrict_pair%%=*}"
            nonstrict_value="${nonstrict_pair#*=}"
            if _act_is_rust_build_influence_name "$nonstrict_name"; then
                if $nonstrict_windows_receipt; then
                    nonstrict_name="${nonstrict_name^^}"
                fi
                nonstrict_entries+=("$(jq -nc \
                    --arg key "$nonstrict_name" --arg value "$nonstrict_value" \
                    '{key: $key, value: $value}')")
            fi
        done <<< "$build_env"
        if [[ ${#nonstrict_entries[@]} -gt 0 ]]; then
            build_influence_env_json=$(printf '%s\n' "${nonstrict_entries[@]}" | \
                jq -cs 'reduce .[] as $entry ({}; .[$entry.key] = $entry.value)
                    | to_entries | sort_by(.key) | from_entries') || return 4
        fi
        cargo_isolation_json=$(jq -nc \
            --arg original_source_root "$remote_path" \
            --arg stage_root "$nonstrict_stage_root" \
            --arg source_root "$nonstrict_source_root" \
            --arg cargo_home "$nonstrict_cargo_home" \
            --arg target_dir "$nonstrict_target_dir" \
            --argjson windows "$nonstrict_windows_receipt" \
            --argjson sibling_roots "$nonstrict_sibling_roots_json" '
            {
                mode: "ephemeral-staged-source",
                original_source_root: $original_source_root,
                stage_root: $stage_root,
                source_root: $source_root,
                source_boundary: "system-temporary-root-outside-user-home",
                cargo_home: $cargo_home,
                cargo_home_policy: "fresh-config-and-credentials-free",
                target_dir: $target_dir,
                sibling_roots: $sibling_roots,
                ancestor_config_policy: "detect-original-and-reject-staging",
                excluded_cargo_home_entries: ["config", "config.toml", "credentials", "credentials.toml"],
                # Unix homes receive private cache copies before the build
                # (dependency_cache.seed); Windows still links the registry.
                cache_reuse: (if $windows then ["registry"] else [] end)
            }
        ') || return 4
    fi

    # Per-target output stage. Ordinary non-Rust builds run in place, so a
    # build_cmd like `go build -o ntm ./cmd/ntm` writes <source>/ntm for EVERY
    # target; with --parallel, two targets on one host overwrite that file and
    # one collects the other's binary (ntm 1.36.0: an amd64 build was about to
    # ship as linux/arm64). When the orchestrator detects such a shared output
    # (DSR_NATIVE_OUTPUT_STAGE=1), this target builds in its own copy of the
    # source, so every in-tree output path is private to it. Rust needs no
    # stage: its outputs are scoped by target triple and isolated above.
    # Strict non-Rust builds also need a private copy: installers and in-tree
    # outputs must not add files to the immutable release source snapshot.
    # Windows hosts remain serialized by the orchestrator.
    local output_stage_root="" output_stage_source="" output_stage_parent=""
    if [[ "$language" != rust ]] && \
       { [[ "${DSR_NATIVE_OUTPUT_STAGE:-}" == 1 ]] || $strict_native_build; } && \
       ! _act_is_windows_host "$host"; then
        if $strict_native_build; then
            local stage_dependencies
            if ! stage_dependencies=$(_act_release_source_dependency_checkouts_json "$tool_name") || \
               ! jq -e 'type == "array" and length == 0' <<< "$stage_dependencies" >/dev/null; then
                _log_error "Strict non-Rust output staging requires no sibling source dependencies"
                return 4
            fi
        fi
        local output_stage_uuid output_stage_build_root="" output_stage_build_root_rc=0
        output_stage_build_root=$(_act_get_host_build_root "$host") || output_stage_build_root_rc=$?
        if [[ "$output_stage_build_root_rc" -eq 4 ]]; then
            jq -nc '{status: "error", exit_code: 4, error: "Invalid hosts.yaml build_root"}'
            return 4
        fi
        # /var/tmp, not /tmp: it exists on Linux and macOS and is not the
        # RAM-backed tmpfs Linux often mounts at /tmp.
        output_stage_parent="${output_stage_build_root:-/var/tmp}"
        if [[ ! "$tool_name" =~ ^[A-Za-z0-9_.-]+$ || \
              ! "${platform//\//-}" =~ ^[A-Za-z0-9_.-]+$ || \
              "$output_stage_parent" != /* || "$output_stage_parent" == *$'\n'* ]] || \
           ! output_stage_uuid=$(_act_generate_uuid); then
            _log_error "Unable to derive a unique per-target output stage"
            jq -nc '{status: "error", exit_code: 4, error: "Invalid output stage identity"}'
            return 4
        fi
        output_stage_root="${output_stage_parent%/}/dsr-build-${tool_name}-${platform//\//-}-${output_stage_uuid//-/}"
        output_stage_source="$output_stage_root/source"
    fi
    # Where in-tree outputs of this build land (collection reads from here).
    local artifact_source_root="${output_stage_source:-$remote_path}"

    # Prepare log file
    local log_dir log_file
    log_dir="$ACT_LOGS_DIR"
    mkdir -p "$log_dir"
    log_file="$log_dir/${tool_name}-${native_target_slug}-${run_id:-$$}.log"

    _log_info "Building $tool_name for $platform${selected_triple:+ ($selected_triple)} on $host"
    _log_info "Remote path: $remote_path"
    _log_info "Build cmd: $build_cmd"
    _log_info "Log file: $log_file"

    local start_time
    start_time=$(date +%s)

    # Release builds must be reproducible from the DSR repo config, not from
    # whichever Cargo env vars happened to be exported in the operator shell.
    local cargo_env_to_unset=()
    if [[ "$language" == "rust" ]]; then
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
    fi

    # Ordinary Rust builds must not inherit the operator's *global* Cargo
    # configuration. A development `[patch.crates-io]`, alias, source
    # replacement, or target/linker override can otherwise leak into a
    # published binary or break a locked release. Every ordinary Rust build is
    # therefore staged outside the user's home with a fresh CARGO_HOME and an
    # absolute CARGO_TARGET_DIR; configured relative target paths are replaced.
    local nonstrict_rust_isolate=false
    [[ "$language" == "rust" && "$strict_rust_build" == false ]] && \
        nonstrict_rust_isolate=true

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
            env_exports+="$(_act_windows_encoded_powershell "\$ErrorActionPreference='Stop'; \$cargoHome=Get-Item -LiteralPath '${win_strict_cargo_home}' -Force; if (-not \$cargoHome.PSIsContainer -or ((\$cargoHome.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'Strict CARGO_HOME is not isolated' }; foreach (\$name in @('config','config.toml','credentials','credentials.toml')) { if (Test-Path -LiteralPath (Join-Path \$cargoHome.FullName \$name)) { throw 'Strict CARGO_HOME contains configuration' } }; \$ancestor=(Get-Item -LiteralPath '${win_path}').Parent; while (\$null -ne \$ancestor) { \$cargoDir=Join-Path \$ancestor.FullName '.cargo'; foreach (\$name in @('config','config.toml')) { if (Test-Path -LiteralPath (Join-Path \$cargoDir \$name)) { throw 'Untracked ancestor Cargo config is forbidden' } }; \$ancestor=\$ancestor.Parent }") && for /f \"tokens=1 delims==\" %V in ('set CARGO_ 2^>nul') do @set \"%V=\" & for /f \"tokens=1 delims==\" %V in ('set RUST 2^>nul') do @set \"%V=\" & "
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
        remote_cmd=$(_act_windows_cmd_via_powershell "cd /d \"${win_path}\" && ${env_exports}${build_cmd}") || return 4
        if $strict_rust_build; then
            local ps_build_b64 ps_env_assignments env_name env_value env_name_b64 env_value_b64
            ps_env_assignments=$(_act_windows_rust_sdk_env_cleanup)
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
            remote_cmd="$(_act_windows_encoded_powershell "\$ErrorActionPreference='Stop'; \$cargoHome=Get-Item -LiteralPath '${win_strict_cargo_home}' -Force; if (-not \$cargoHome.PSIsContainer -or ((\$cargoHome.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'Strict CARGO_HOME is not isolated' }; foreach (\$name in @('config','config.toml','credentials','credentials.toml')) { if (Test-Path -LiteralPath (Join-Path \$cargoHome.FullName \$name)) { throw 'Strict CARGO_HOME contains configuration' } }; \$ancestor=(Get-Item -LiteralPath '${win_path}').Parent; while (\$null -ne \$ancestor) { \$cargoDir=Join-Path \$ancestor.FullName '.cargo'; foreach (\$name in @('config','config.toml')) { if (Test-Path -LiteralPath (Join-Path \$cargoDir \$name)) { throw 'Untracked ancestor Cargo config is forbidden' } }; \$ancestor=\$ancestor.Parent }; \$psi=New-Object System.Diagnostics.ProcessStartInfo; \$psi.UseShellExecute=\$false; \$keys=@(\$psi.EnvironmentVariables.Keys); foreach (\$key in \$keys) { if ((\$key -match '^(CARGO_|RUST|XWIN_)') -or (\$key -match '^DSR_RELEASE_GIT_(SHA|REF)$') -or (\$key -match '^(CC|CXX|CPP|AR|RANLIB|LD|NM|OBJCOPY|STRIP|CFLAGS|CXXFLAGS|CPPFLAGS|LDFLAGS|BINDGEN_EXTRA_CLANG_ARGS|SDKROOT|MACOSX_DEPLOYMENT_TARGET|IPHONEOS_DEPLOYMENT_TARGET|INCLUDE|LIB|LIBPATH)(_|$)') -or (\$key -match '_(CC|CXX|AR|RANLIB|CFLAGS|CXXFLAGS|LDFLAGS)$')) { \$psi.EnvironmentVariables.Remove(\$key) } }; ${ps_env_assignments}\$psi.FileName=\$env:ComSpec; \$psi.WorkingDirectory='${win_path}'; \$command=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${ps_build_b64}')); \$psi.Arguments='/d /s /c ' + \$command; \$process=[Diagnostics.Process]::Start(\$psi); \$process.WaitForExit(); exit \$process.ExitCode")"
        elif $nonstrict_rust_isolate; then
            local win_stage_root win_source_root win_cargo_home
            win_stage_root=$(_act_windows_cmd_path "$nonstrict_stage_root") || return 4
            win_source_root=$(_act_windows_cmd_path "$nonstrict_source_root") || return 4
            win_cargo_home=$(_act_windows_cmd_path "$nonstrict_cargo_home") || return 4
            local ps_build_b64 ps_env_assignments env_name env_value env_name_b64 env_value_b64
            ps_env_assignments=$(_act_windows_rust_sdk_env_cleanup)
            local ps_sibling_copies="" sibling_win_remote sibling_win_staged
            local ps_copy_function
            ps_copy_function=$(_act_windows_source_copy_function) || return 4
            if ! command -v base64 >/dev/null 2>&1; then
                _log_error "base64 is required to construct an isolated Windows Rust build"
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
            for sibling_relative in "${nonstrict_sibling_relatives[@]}"; do
                sibling_win_remote=$(_act_windows_cmd_path \
                    "${remote_path%/*}/$sibling_relative") || return 4
                sibling_win_staged=$(_act_windows_cmd_path \
                    "$nonstrict_stage_root/$sibling_relative") || return 4
                ps_sibling_copies+="\$sibling=Get-Item -LiteralPath '${sibling_win_remote}' -Force; if (-not \$sibling.PSIsContainer -or ((\$sibling.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'Rust sibling source root must be a plain directory' }; New-Item -ItemType Directory -Path '${sibling_win_staged}' | Out-Null; Copy-DsrSourceTree -SourcePath \$sibling.FullName -DestinationPath '${sibling_win_staged}'; "
            done
            remote_cmd="$(_act_windows_encoded_powershell "\$ErrorActionPreference='Stop'; ${ps_copy_function}; \$source=Get-Item -LiteralPath '${win_path}' -Force; if (-not \$source.PSIsContainer -or ((\$source.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'Rust source root must be a plain directory' }; \$ancestor=\$source.Parent; while (\$null -ne \$ancestor) { \$cargoDir=Join-Path \$ancestor.FullName '.cargo'; foreach (\$name in @('config','config.toml')) { \$candidate=Join-Path \$cargoDir \$name; if (Test-Path -LiteralPath \$candidate) { [Console]::Error.WriteLine('[dsr] excluding inherited Cargo config: ' + \$candidate) } }; \$ancestor=\$ancestor.Parent }; \$root=Split-Path -Parent '${win_stage_root}'; New-Item -ItemType Directory -Path \$root -Force | Out-Null; if (Test-Path -LiteralPath '${win_stage_root}') { throw 'Rust isolation path already exists' }; New-Item -ItemType Directory -Path '${win_stage_root}' | Out-Null; New-Item -ItemType Directory -Path '${win_source_root}' | Out-Null; New-Item -ItemType Directory -Path '${win_cargo_home}' | Out-Null; Copy-DsrSourceTree -SourcePath \$source.FullName -DestinationPath '${win_source_root}'; ${ps_sibling_copies}if (Test-Path -LiteralPath (Join-Path '${win_source_root}' '.git')) { & git -C '${win_source_root}' status --porcelain --untracked-files=no | Out-Null; if (\$LASTEXITCODE -ne 0) { throw 'Unable to refresh staged Git index metadata' } }; foreach (\$name in @('registry')) { \$cache=Join-Path (Join-Path \$env:USERPROFILE '.cargo') \$name; \$link=Join-Path '${win_cargo_home}' \$name; if (Test-Path -LiteralPath \$cache -PathType Container) { New-Item -ItemType Junction -Path \$link -Target \$cache | Out-Null; if (((Get-Item -LiteralPath \$link -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) { throw 'Cargo cache link is not isolated' } } }; foreach (\$name in @('config','config.toml','credentials','credentials.toml')) { if (Test-Path -LiteralPath (Join-Path '${win_cargo_home}' \$name)) { throw 'Ephemeral CARGO_HOME contains configuration' } }; \$ancestor=(Get-Item -LiteralPath '${win_source_root}' -Force).Parent; while (\$null -ne \$ancestor) { \$cargoDir=Join-Path \$ancestor.FullName '.cargo'; foreach (\$name in @('config','config.toml')) { if (Test-Path -LiteralPath (Join-Path \$cargoDir \$name)) { throw 'Staging root inherits Cargo configuration' } }; \$ancestor=\$ancestor.Parent }; \$psi=New-Object System.Diagnostics.ProcessStartInfo; \$psi.UseShellExecute=\$false; \$keys=@(\$psi.EnvironmentVariables.Keys); foreach (\$key in \$keys) { if ((\$key -match '^(CARGO_|RUST|XWIN_)') -or (\$key -match '^(CC|CXX|CPP|AR|RANLIB|LD|NM|OBJCOPY|STRIP|CFLAGS|CXXFLAGS|CPPFLAGS|LDFLAGS|BINDGEN_EXTRA_CLANG_ARGS|SDKROOT|MACOSX_DEPLOYMENT_TARGET|IPHONEOS_DEPLOYMENT_TARGET|INCLUDE|LIB|LIBPATH)(_|$)') -or (\$key -match '_(CC|CXX|AR|RANLIB|CFLAGS|CXXFLAGS|LDFLAGS)$')) { \$psi.EnvironmentVariables.Remove(\$key) } }; ${ps_env_assignments}\$psi.EnvironmentVariables['CARGO_HOME']='${win_cargo_home}'; \$psi.FileName=\$env:ComSpec; \$psi.WorkingDirectory='${win_source_root}'; \$command=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${ps_build_b64}')); \$psi.Arguments='/d /s /c ' + \$command; \$process=[Diagnostics.Process]::Start(\$psi); \$process.WaitForExit(); exit \$process.ExitCode")"
        fi
    else
        # Unix: use bash/zsh compatible syntax
        local env_exports=""
        local env_name
        if $strict_rust_build; then
            env_exports+="test -d '$strict_cargo_home'; test ! -L '$strict_cargo_home'; for name in config config.toml credentials credentials.toml; do test ! -e '$strict_cargo_home'/\$name; test ! -L '$strict_cargo_home'/\$name; done; ancestor='${remote_path%/*}'; while test \"\$ancestor\" != / && test -n \"\$ancestor\"; do for name in config config.toml; do test ! -e \"\$ancestor/.cargo/\$name\"; test ! -L \"\$ancestor/.cargo/\$name\"; done; ancestor=\${ancestor%/*}; test -n \"\$ancestor\" || ancestor=/; done; for variable in \$(env | sed 's/=.*//'); do case \"\$variable\" in CARGO_*|RUST*|XWIN_*|DSR_RELEASE_GIT_SHA|DSR_RELEASE_GIT_REF|CC|CXX|CPP|AR|RANLIB|LD|CFLAGS|CXXFLAGS|CPPFLAGS|LDFLAGS) unset \"\$variable\";; esac; done; "
        fi
        if [[ "$language" == "rust" ]]; then
            local sdk_regex
            sdk_regex=$(_act_rust_sdk_influence_regex)
            # Enumerate on the build host, not the coordinator. Bash's unset
            # silently leaves inherited names containing '-' in the process
            # environment. Reject those unsupported export identifiers before
            # a higher-priority target SDK selector can escape isolation.
            env_exports+="for sdk_variable in \$(env | sed 's/=.*//' | grep -Ei '${sdk_regex}' || true); do if ! printf '%s\\n' \"\$sdk_variable\" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*$'; then printf '[dsr] SDK environment name cannot be isolated by this shell: %s; clear it on the build host and configure an underscore-spelled selector in DSR\\n' \"\$sdk_variable\" >&2; exit 4; fi; unset \"\$sdk_variable\"; done; "
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
        if [[ "$language" == "rust" ]]; then
            # A native target host must compile locally.  Explicitly bypass an
            # installed RCH Cargo hook so it cannot re-offload a snapshot whose
            # path is intentionally outside the canonical project root.
            env_exports+="export RCH_DISABLED=1; export RCH_CARGO_WRAPPER_BYPASS=1; "
        fi

        # A configured TMPDIR that does not exist on the build host breaks
        # compilers in opaque ways (clang: "unable to make temporary file"),
        # so create it before the build runs.
        if [[ "$build_env" == TMPDIR=* || "$build_env" == *$'\n'TMPDIR=* ]]; then
            env_exports+='mkdir -p "$TMPDIR"; '
        fi

        # Default path: build in place under remote_path.
        local rp_q="${remote_path//\'/\'\\\'\'}"
        local cargo_home_prefix="" cd_cmd="cd '$rp_q'"
        if $nonstrict_rust_isolate; then
            local sibling_copy_prefix="" sibling_remote_q
            for sibling_relative in "${nonstrict_sibling_relatives[@]}"; do
                sibling_remote="${remote_path%/*}/$sibling_relative"
                sibling_remote_q="${sibling_remote//\'/\'\\\'\'}"
                sibling_copy_prefix+="test -d '$sibling_remote_q'; test ! -L '$sibling_remote_q'; mkdir '${nonstrict_stage_root}/$sibling_relative'; cp -R '$sibling_remote_q/.' '${nonstrict_stage_root}/$sibling_relative/'; "
            done
            # Always build ordinary Rust sources from a unique system-temp
            # directory.  Cargo searches .cargo/config* in every ancestor of
            # the working directory, so merely changing CARGO_HOME is not an
            # isolation boundary.  /private/tmp (macOS) and /var/tmp (other
            # Unix) are outside the user's home; their own ancestor chain is
            # checked before use.  The stage root and its fresh CARGO_HOME were
            # created by _act_prepare_unix_nonstrict_cargo_home: the home holds
            # private copies of the registry and Git download caches only, and
            # cannot contain aliases, patches, source replacement, credentials,
            # or compiler settings.  Unique directories avoid cross-target
            # races and require no destructive pre-build cleanup.
            local isolation_root_q="${isolation_root//\'/\'\\\'\'}"
            local isolation_root_guard
            isolation_root_guard="mkdir -p '${isolation_root_q}'; $(_act_ram_backed_guard_sh "$isolation_root")"
            cargo_home_prefix="${isolation_root_guard}_dsr_src='$rp_q'; _dsr_ancestor=\${_dsr_src%/*}; test -n \"\$_dsr_ancestor\" || _dsr_ancestor=/; while test -n \"\$_dsr_ancestor\"; do for _dsr_name in config config.toml; do if test -e \"\$_dsr_ancestor/.cargo/\$_dsr_name\" || test -L \"\$_dsr_ancestor/.cargo/\$_dsr_name\"; then printf '[dsr] excluding inherited Cargo config: %s\\n' \"\$_dsr_ancestor/.cargo/\$_dsr_name\" >&2; fi; done; test \"\$_dsr_ancestor\" = / && break; _dsr_ancestor=\${_dsr_ancestor%/*}; test -n \"\$_dsr_ancestor\" || _dsr_ancestor=/; done; _dsr_ancestor='${nonstrict_stage_root%/*}'; while test -n \"\$_dsr_ancestor\"; do for _dsr_name in config config.toml; do test ! -e \"\$_dsr_ancestor/.cargo/\$_dsr_name\"; test ! -L \"\$_dsr_ancestor/.cargo/\$_dsr_name\"; done; test \"\$_dsr_ancestor\" = / && break; _dsr_ancestor=\${_dsr_ancestor%/*}; test -n \"\$_dsr_ancestor\" || _dsr_ancestor=/; done; test -d '${nonstrict_stage_root}'; test ! -L '${nonstrict_stage_root}'; test -d '${nonstrict_cargo_home}'; test ! -L '${nonstrict_cargo_home}'; test ! -e '${nonstrict_source_root}'; test ! -L '${nonstrict_source_root}'; mkdir '${nonstrict_source_root}'; ${sibling_copy_prefix}for _dsr_name in registry git; do if test -e '${nonstrict_cargo_home}'/\"\$_dsr_name\"; then test -d '${nonstrict_cargo_home}'/\"\$_dsr_name\"; test ! -L '${nonstrict_cargo_home}'/\"\$_dsr_name\"; fi; done; for _dsr_name in config config.toml credentials credentials.toml; do test ! -e '${nonstrict_cargo_home}'/\"\$_dsr_name\"; test ! -L '${nonstrict_cargo_home}'/\"\$_dsr_name\"; done; cp -R \"\$_dsr_src/.\" '${nonstrict_source_root}/'; if test -e '${nonstrict_source_root}/.git' || test -L '${nonstrict_source_root}/.git'; then git -C '${nonstrict_source_root}' status --porcelain --untracked-files=no >/dev/null; fi; export CARGO_HOME='${nonstrict_cargo_home}'; "
            cd_cmd="cd '${nonstrict_source_root}'"
        fi
        if [[ -n "$output_stage_root" ]]; then
            # Copy the tree (including .git, which version stamps such as
            # `git rev-parse HEAD` read) into this target's private stage and
            # build there. The index refresh keeps `git describe --dirty`
            # from reporting the copy's new inode metadata as modifications.
            local stage_parent_q="${output_stage_parent//\'/\'\\\'\'}"
            local stage_root_q="${output_stage_root//\'/\'\\\'\'}"
            local stage_source_q="${output_stage_source//\'/\'\\\'\'}"
            cargo_home_prefix="mkdir -p '${stage_parent_q}'; $(_act_ram_backed_guard_sh "$output_stage_parent")test -d '$rp_q'; test ! -e '${stage_root_q}'; test ! -L '${stage_root_q}'; mkdir '${stage_root_q}' '${stage_source_q}'; cp -R '$rp_q/.' '${stage_source_q}/'; if test -e '${stage_source_q}/.git' || test -L '${stage_source_q}/.git'; then git -C '${stage_source_q}' status --porcelain --untracked-files=no >/dev/null; fi; "
            if $strict_native_build; then
                local stage_manifest stage_manifest_digest stage_object_count stage_verification
                stage_manifest="$ACT_ARTIFACTS_DIR/strict-source-verification/stage-${output_stage_uuid}.manifest"
                if [[ -z "$release_git_sha" ]] || \
                   ! mkdir -p "${stage_manifest%/*}" || \
                   ! _act_write_tracked_manifest "$local_path" "$release_git_sha" "$stage_manifest" || \
                   ! stage_manifest_digest=$(_act_sha256 "$stage_manifest") || \
                   ! stage_object_count=$(_act_tracked_manifest_object_count "$stage_manifest") || \
                   ! stage_verification=$(_act_unix_strict_snapshot_verify_script \
                       "$output_stage_source" "${remote_path%/*}/.source.tar" \
                       "${remote_path%/*}/.source.manifest" "$stage_manifest_digest" "$stage_object_count"); then
                    _log_error "Unable to bind private output stage to strict source manifest"
                    return 4
                fi
                # Check every staged input and reject extra files before the
                # command runs; final verification still checks the original.
                cargo_home_prefix+="${stage_verification}"$'\n'
            fi
            cd_cmd="cd '${stage_source_q}'"
            _log_info "Building $platform in private output stage $output_stage_source"
        fi
        # Stage the glibc-floor cargo shim beside the isolated source copy and
        # put it first on PATH, so a plain `cargo build` in the repo's
        # build_cmd is routed through cargo-zigbuild with the versioned
        # target (issue #9). `.dsr-bin` cannot collide with a sibling crate:
        # sibling names may not start with a dot.
        # A strict build must leave its source snapshot byte-identical, so its
        # shim lives in the snapshot parent beside .cargo-home and the
        # per-platform target directories, named per platform so concurrent
        # targets of one snapshot never share (or race on) a shim.
        if [[ -n "$rust_zig_target" ]]; then
            local zig_shim_dir=""
            if $nonstrict_rust_isolate; then
                zig_shim_dir="${nonstrict_stage_root}/.dsr-bin"
            elif $strict_rust_build; then
                zig_shim_dir="${remote_path%/*}/.dsr-bin-${platform//\//-}"
            fi
            if [[ -n "$zig_shim_dir" ]]; then
                cargo_home_prefix+=$(_act_zig_shim_prefix_sh "$zig_shim_dir")
                env_exports+="export PATH='${zig_shim_dir}':\"\$PATH\"; "
            fi
        fi
        local effective_build="$build_cmd"
        if [[ -n "$strict_cache_root" ]]; then
            effective_build=$(_act_strict_cargo_cache_script "$strict_cache_root" "$strict_cache_contract" "$build_cmd") || return 4
        fi
        if [[ -n "$strict_toolchain_receipt" ]]; then
            # Attest the toolchain in the build's own shell, then require the
            # same identities once the build has finished (bd-10we).
            local toolchain_extra="" toolchain_record toolchain_verify
            [[ -n "$rust_zig_target" ]] && toolchain_extra="cargo-zigbuild zig"
            toolchain_record=$(_act_toolchain_identity_script record \
                "$strict_toolchain_receipt" "$build_cmd" "$toolchain_extra") || return 4
            toolchain_verify=$(_act_toolchain_identity_script verify \
                "$strict_toolchain_receipt" "$build_cmd" "$toolchain_extra") || return 4
            # $(...) dropped each heredoc terminator's newline; restore it.
            effective_build="$toolchain_record"$'\n'"$effective_build"$'\n'"$toolchain_verify"$'\n'
        fi
        remote_cmd="set -e; $cargo_home_prefix$cd_cmd; $env_exports$effective_build"
    fi

    local build_transport_timeout="$_ACT_BUILD_TIMEOUT"
    if _act_is_windows_host "$host"; then
        local windows_build_script windows_build_guard
        windows_build_script=$(_act_windows_command_script "$remote_cmd") || return 4
        local windows_storage_status=0 windows_lock_script
        _act_windows_storage_config "$host" >/dev/null || windows_storage_status=$?
        [[ $windows_storage_status -eq 0 || $windows_storage_status -eq 1 ]] || return 4
        if [[ $windows_storage_status -eq 0 ]]; then
            if ! declare -F config_windows_storage_lock_script >/dev/null; then
                source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"
            fi
            windows_lock_script=$(config_windows_storage_lock_script "$host") || return 4
            windows_build_script="$windows_lock_script"$'\n'"$windows_build_script"
        fi
        windows_build_guard=$(_act_windows_build_guard_script "$_ACT_BUILD_TIMEOUT" "$windows_build_script") || return 4
        windows_build_script="$windows_build_guard"
        if $strict_rust_build; then
            remote_cmd=$(_act_windows_stage_build_script "$host" "$remote_path" "$windows_build_script") || return 4
        else
            remote_cmd=$(_act_windows_encoded_powershell "$windows_build_script") || return 4
        fi
        # Let the remote deadline retire its job before killing the transport.
        # This grace is not additional build time and never enables local work.
        build_transport_timeout=$((_ACT_BUILD_TIMEOUT + 60))
    fi

    # A cancelled build still removes its stage roots (see
    # _act_stage_cleanup_on_signal). Only in a subshell: the orchestrator
    # always runs this function inside $(...), and a direct caller's traps
    # must not be replaced.
    if (( BASH_SUBSHELL > 0 )) && [[ -n "$nonstrict_stage_root$output_stage_root" ]]; then
        _ACT_SIGNAL_STAGE_HOST="$host"
        _ACT_SIGNAL_STAGE_ROOTS=("$nonstrict_stage_root" "$output_stage_root")
        trap '_act_stage_cleanup_on_signal 130' INT
        trap '_act_stage_cleanup_on_signal 143' TERM
    fi

    # Ordinary Unix Rust builds: create the stage root with a private copy of
    # the dependency caches before the build command runs (issue #15).
    local exit_code=0
    local nonstrict_private_cargo_cache=false nonstrict_cargo_seed_json="" nonstrict_seed_home=""
    if $nonstrict_rust_isolate && ! _act_is_windows_host "$host"; then
        local nonstrict_prepare_status=0
        nonstrict_cargo_seed_json=$(_act_prepare_unix_nonstrict_cargo_home "$host" \
            "$isolation_root" "$nonstrict_stage_root" "$nonstrict_cargo_home" 2>"$log_file") || \
            nonstrict_prepare_status=$?
        [[ -s "$log_file" ]] && cat "$log_file" >&2
        if [[ $nonstrict_prepare_status -eq 0 ]] && \
           nonstrict_seed_home=$(jq -er '.cargo_home' <<< "$nonstrict_cargo_seed_json") && \
           cargo_isolation_json=$(jq --argjson seed "$nonstrict_cargo_seed_json" \
               '.dependency_cache = {mode: "private-copy", seed: $seed}' <<< "$cargo_isolation_json"); then
            nonstrict_private_cargo_cache=true
        else
            _log_error "Unable to prepare a private Cargo dependency cache on $host (requires Python 3.9+); not building $platform" 2>&1 | tee -a "$log_file" >&2
            exit_code=4
        fi
    fi

    # Execute on remote host
    # Use PIPESTATUS to capture the actual command exit code, not tee's
    if [[ $exit_code -eq 0 ]]; then
        if $nonstrict_private_cargo_cache; then
            _act_ssh_exec "$host" "$remote_cmd" "$build_transport_timeout" 2>&1 | tee -a "$log_file"
        else
            _act_ssh_exec "$host" "$remote_cmd" "$build_transport_timeout" 2>&1 | tee "$log_file"
        fi
        exit_code=${PIPESTATUS[0]}
    fi
    if [[ $exit_code -eq 0 ]] && $nonstrict_private_cargo_cache; then
        local nonstrict_cargo_final_json nonstrict_cargo_seed_digest
        nonstrict_cargo_seed_digest=$(jq -er '.receipt_sha256' <<< "$nonstrict_cargo_seed_json") || exit_code=4
        if [[ $exit_code -eq 0 ]] && \
           nonstrict_cargo_final_json=$(_act_finish_unix_private_cargo_home \
               "$host" "$nonstrict_seed_home" "$nonstrict_cargo_seed_digest"); then
            cargo_isolation_json=$(jq --argjson final "$nonstrict_cargo_final_json" \
                '.dependency_cache.final = $final' <<< "$cargo_isolation_json") || exit_code=4
        else
            _log_error "Private Cargo cache failed final verification; refusing artifact collection"
            exit_code=4
        fi
    fi
    if [[ $exit_code -eq 0 ]] && $strict_private_cargo_cache; then
        local strict_cargo_final_json strict_cargo_seed_digest
        strict_cargo_seed_digest=$(jq -er '.receipt_sha256' <<< "$strict_cargo_seed_json") || exit_code=4
        if [[ $exit_code -eq 0 ]] && \
           strict_cargo_final_json=$(_act_finish_unix_private_cargo_home \
               "$host" "$strict_cargo_home" "$strict_cargo_seed_digest"); then
            cargo_isolation_json=$(jq --argjson final "$strict_cargo_final_json" \
                '.dependency_cache.final = $final' <<< "$cargo_isolation_json") || exit_code=4
        else
            _log_error "Strict private Cargo cache failed final verification; refusing artifact collection"
            exit_code=4
        fi
    fi
    if [[ $exit_code -eq 0 && -n "$strict_toolchain_receipt" ]]; then
        # The build command already re-probed and compared every identity;
        # bind the attested executables into the target's isolation receipt.
        local toolchain_identity_json=""
        if toolchain_identity_json=$(_act_ssh_exec "$host" "cat '$strict_toolchain_receipt'" 30) && \
           toolchain_identity_json=$(jq -ce '
                select(type == "object" and .schema_version == 1 and
                    (.cwd | type == "string" and startswith("/")) and
                    (.tools | type == "object") and
                    (.tools as $tools | all(("cargo", "rustc");
                        $tools[.] | type == "object" and
                        (.selected_path | type == "string" and startswith("/")) and
                        (.selected_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
                        (.version | type == "string" and length > 0))))
            ' <<< "$toolchain_identity_json") && \
           cargo_isolation_json=$(jq --argjson toolchain "$toolchain_identity_json" \
               '.toolchain = $toolchain' <<< "$cargo_isolation_json"); then
            :
        else
            _log_error "Strict toolchain identity receipt missing or invalid; refusing artifact collection"
            exit_code=4
        fi
    fi
    if [[ $exit_code -eq 0 && -n "$strict_cache_root" ]]; then
        local cache_receipt
        if cache_receipt=$(_act_ssh_exec "$host" \
                "cat '${strict_cargo_target_dir}.cache-receipt.json'" 30) && \
           jq -e '.namespace | test("^[0-9a-f]{64}$")' <<< "$cache_receipt" >/dev/null && \
           jq -e '.final_output_policy == "fresh-run-target-detached-under-custody"' \
                <<< "$cache_receipt" >/dev/null; then
            cargo_isolation_json=$(jq --argjson receipt "$cache_receipt" \
                '.intermediate_cache.receipt = $receipt' <<< "$cargo_isolation_json") || exit_code=4
        else
            _log_error "Strict Cargo cache receipt missing or invalid; refusing artifact collection"
            exit_code=4
        fi
    fi

    # The ephemeral stage root (isolated source copy + fresh cargo-home) is
    # never needed once the build command has exited: artifacts are collected
    # from CARGO_TARGET_DIR, which always lives outside it. Remove it on every
    # outcome — success, failure, and especially a timeout kill, which never
    # reaches any in-command cleanup — or multi-GB staging copies accumulate
    # until the temp filesystem fills and later targets die with ENOSPC.
    # An output stage (per-target source copy for in-tree outputs, below)
    # holds the artifacts themselves, so it is removed only after collection.
    _act_remove_build_stage_root "$host" "$nonstrict_stage_root"

    local end_time duration
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    # Determine result
    local status local_artifact_path="" local_artifact_paths=()
    local local_additional_artifact_paths=() additional_artifact_receipts=()
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
        elif [[ -n "$selected_triple" ]]; then
            local variant_artifact_parent="$ACT_ARTIFACTS_DIR/${run_id:-build-$tool_name}/${native_target_slug}"
            if ! mkdir -p "$variant_artifact_parent" || \
               [[ ! -d "$variant_artifact_parent" || -L "$variant_artifact_parent" ]] || \
               ! artifact_dir=$(mktemp -d "$variant_artifact_parent/attempt.XXXXXXXX"); then
                _log_error "Unable to create a fresh artifact directory for native variant $selected_triple"
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
            _act_remove_build_stage_root "$host" "$output_stage_root"
            jq -nc '{status: "error", exit_code: 4, error: "No binaries configured"}'
            return 4
        fi

        # Sanity check: ensure we have binaries to download
        if [[ ${#binaries_to_download[@]} -eq 0 ]]; then
            _log_error "No binaries to download (workspace_binaries may be empty)"
            _act_remove_build_stage_root "$host" "$output_stage_root"
            jq -nc '{status: "error", exit_code: 4, error: "No binaries to download"}'
            return 4
        fi

        local download_failed=false
        for bin in "${binaries_to_download[@]}"; do
            local remote_artifact_path
            remote_artifact_path=$(act_get_remote_artifact_path "$language" "$artifact_source_root" "$build_env" "$bin" "$platform" "$build_profile")

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
                        "$host" "$remote_artifact_path") || collection_receipt=""
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
                                "$host" "$alt_remote_artifact_path") || collection_receipt=""
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
                    if _act_collected_glibc_within_floor "$this_artifact_path" "$rust_glibc_floor_enforced"; then
                        local_artifact_paths+=("$this_artifact_path")
                        strict_collection_receipts+=("$collection_receipt")
                    else
                        echo "Collected artifact exceeds glibc floor $rust_glibc_floor_enforced: $this_artifact_path" >> "$log_file"
                        download_failed=true
                    fi
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
                    if _act_accept_collected_binary "$this_artifact_path" "$platform" "$language" "$rust_glibc_floor_enforced"; then
                        local_artifact_paths+=("$this_artifact_path")
                    else
                        echo "Collected artifact failed $platform validation: $this_artifact_path" >> "$log_file"
                        download_failed=true
                    fi
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
                if _act_accept_collected_binary "$this_artifact_path" "$platform" "$language" "$rust_glibc_floor_enforced"; then
                    local_artifact_paths+=("$this_artifact_path")
                else
                    echo "Collected artifact failed $platform validation: $this_artifact_path" >> "$log_file"
                    download_failed=true
                fi
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
                        if _act_accept_collected_binary "$this_artifact_path" "$platform" "$language" "$rust_glibc_floor_enforced"; then
                            local_artifact_paths+=("$this_artifact_path")
                        else
                            echo "Collected artifact failed $platform validation: $this_artifact_path" >> "$log_file"
                            download_failed=true
                        fi
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

        # Collect configured non-binary package members separately from the
        # architecture-validated executable receipts.  The build command may
        # produce a verifier and detached component manifest beside its native
        # binaries; both must be copied through a fresh held destination inode
        # before they can enter the exact archive closure.
        local workspace_archive_files_json="[]"
        workspace_archive_files_json=$(_act_workspace_archive_files_json \
            "$config_file" "$platform") || download_failed=true
        if ! jq -e '
            type == "array" and
            all(.[];
                type == "object" and
                (keys | sort) == ["executable", "name"] and
                (.name | type == "string") and
                (.executable | type == "boolean")
            )
        ' <<< "$workspace_archive_files_json" >/dev/null 2>&1; then
            _log_error "Invalid workspace_archive_files configuration for $platform"
            download_failed=true
            workspace_archive_files_json='[]'
        fi

        local archive_file_json archive_file archive_file_executable
        local archive_file_remote archive_file_local archive_file_receipt archive_file_mode
        local coordinator_windows_family=false
        if $strict_native_build && ! $download_failed && \
           [[ "$tool_name" == frankenterm && "$platform" == windows/amd64 ]]; then
            if _act_finalize_frankenterm_windows_family \
                "$artifact_dir" "$local_path" "$release_git_sha" "$version" "$build_profile"; then
                coordinator_windows_family=true
            else
                _log_error "Windows application family failed component verification"
                download_failed=true
            fi
        fi
        while IFS= read -r archive_file_json; do
            [[ -n "$archive_file_json" ]] || continue
            archive_file=$(jq -r '.name' <<< "$archive_file_json") || {
                download_failed=true
                continue
            }
            archive_file_executable=$(jq -r '.executable' <<< "$archive_file_json") || {
                download_failed=true
                continue
            }
            if $coordinator_windows_family && \
               [[ "$archive_file" == verify-components.sh || \
                  "$archive_file" == ft-windows-amd64.component-manifest.json ]]; then
                local_artifact_paths+=("$artifact_dir/$archive_file")
                continue
            fi
            if ! _act_is_safe_basename "$archive_file" || \
               [[ -e "$artifact_dir/$archive_file" || -L "$artifact_dir/$archive_file" ]]; then
                _log_error "Unsafe or colliding workspace archive member: $archive_file"
                download_failed=true
                continue
            fi
            archive_file_remote=$(act_get_remote_artifact_path \
                "$language" "$artifact_source_root" "$build_env" "$archive_file" \
                "$platform" "$build_profile")
            archive_file_local="$artifact_dir/$archive_file"
            archive_file_mode=600
            [[ "$archive_file_executable" == "true" ]] && archive_file_mode=700
            archive_file_receipt=""
            if $strict_native_build; then
                if _act_is_local_host "$host"; then
                    archive_file_receipt=$(_act_collect_stream_exclusive \
                        "$archive_file_local" "$archive_file_mode" \
                        _act_stream_local_file "$archive_file_remote") || archive_file_receipt=""
                elif _act_is_windows_host "$host"; then
                    archive_file_receipt=$(_act_collect_stream_exclusive \
                        "$archive_file_local" "$archive_file_mode" \
                        _act_stream_remote_windows_file \
                        "$host" "$archive_file_remote") || archive_file_receipt=""
                else
                    archive_file_receipt=$(_act_collect_stream_exclusive \
                        "$archive_file_local" "$archive_file_mode" \
                        _act_stream_remote_unix_file \
                        "$ssh_destination" "$archive_file_remote") || archive_file_receipt=""
                fi
                if [[ -n "$archive_file_receipt" ]]; then
                    local_artifact_paths+=("$archive_file_local")
                else
                    _log_error "Failed to collect workspace archive member $archive_file from $host"
                    download_failed=true
                fi
            elif _act_is_local_host "$host"; then
                if [[ -f "$archive_file_remote" && ! -L "$archive_file_remote" ]] && \
                   cp "$archive_file_remote" "$archive_file_local" && \
                   chmod "$archive_file_mode" "$archive_file_local"; then
                    local_artifact_paths+=("$archive_file_local")
                else
                    download_failed=true
                fi
            elif scp -o ConnectTimeout="$_ACT_SSH_TIMEOUT" \
                    -o StrictHostKeyChecking=accept-new \
                    "${ssh_destination}:${archive_file_remote}" \
                    "$archive_file_local" >/dev/null 2>&1 && \
                 chmod "$archive_file_mode" "$archive_file_local"; then
                local_artifact_paths+=("$archive_file_local")
            else
                download_failed=true
            fi
        done < <(jq -c '.[]' <<< "$workspace_archive_files_json")

        # Build-produced release assets (currently the manifest-bound macOS app
        # archive) are collected and receipted but never folded into the process
        # archive.  The receipt is carried in the target result so strict
        # manifest generation can require its exact name, bytes, and identity.
        local additional_json="[]" additional_name additional_remote additional_local
        local additional_receipt
        additional_json=$(_act_workspace_additional_artifacts_json \
            "$config_file" "$platform") || download_failed=true
        if ! jq -e 'type == "array" and all(.[]; type == "string")' \
            <<< "$additional_json" >/dev/null 2>&1; then
            _log_error "Invalid workspace_additional_artifacts configuration for $platform"
            download_failed=true
            additional_json='[]'
        fi
        while IFS= read -r additional_name; do
            [[ -n "$additional_name" ]] || continue
            if ! _act_is_safe_basename "$additional_name" || \
               [[ -e "$artifact_dir/$additional_name" || -L "$artifact_dir/$additional_name" ]]; then
                _log_error "Unsafe or colliding additional release artifact: $additional_name"
                download_failed=true
                continue
            fi
            additional_remote=$(act_get_remote_artifact_path \
                "$language" "$artifact_source_root" "$build_env" "$additional_name" \
                "$platform" "$build_profile")
            additional_local="$artifact_dir/$additional_name"
            additional_receipt=""
            if $strict_native_build; then
                if _act_is_local_host "$host"; then
                    additional_receipt=$(_act_collect_stream_exclusive \
                        "$additional_local" 600 _act_stream_local_file \
                        "$additional_remote") || additional_receipt=""
                elif _act_is_windows_host "$host"; then
                    additional_receipt=$(_act_collect_stream_exclusive \
                        "$additional_local" 600 _act_stream_remote_windows_file \
                        "$host" "$additional_remote") || additional_receipt=""
                else
                    additional_receipt=$(_act_collect_stream_exclusive \
                        "$additional_local" 600 _act_stream_remote_unix_file \
                        "$ssh_destination" "$additional_remote") || additional_receipt=""
                fi
                if [[ -n "$additional_receipt" ]]; then
                    local_additional_artifact_paths+=("$additional_local")
                    additional_artifact_receipts+=("$additional_receipt")
                else
                    _log_error "Failed to collect additional release artifact $additional_name from $host"
                    download_failed=true
                fi
            else
                if _act_is_local_host "$host" && \
                   [[ -f "$additional_remote" && ! -L "$additional_remote" ]] && \
                   cp "$additional_remote" "$additional_local" && \
                   chmod 600 "$additional_local"; then
                    local_additional_artifact_paths+=("$additional_local")
                elif ! _act_is_local_host "$host" && \
                     scp -o ConnectTimeout="$_ACT_SSH_TIMEOUT" \
                         -o StrictHostKeyChecking=accept-new \
                         "${ssh_destination}:${additional_remote}" \
                         "$additional_local" >/dev/null 2>&1 && \
                     chmod 600 "$additional_local"; then
                    local_additional_artifact_paths+=("$additional_local")
                else
                    download_failed=true
                fi
            fi
        done < <(jq -r '.[]' <<< "$additional_json")

        # Set final status and artifact path(s)
        # Every remote output has been copied home; a staged build's private
        # source copy is no longer needed by anything below.
        _act_remove_build_stage_root "$host" "$output_stage_root"
        output_stage_root=""

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

            # The repository archive_format contract is authoritative.  The
            # strict native lane must not emit gzip bytes and merely rename
            # them with a .tar.xz primary name downstream.
            local archive_ext=""
            if ! archive_ext=$(_act_workspace_archive_format \
                "$config_file" "$platform"); then
                _log_error "Unable to resolve workspace archive format for $platform"
                status="failed"
                exit_code=7
                local_artifact_path=""
                local_artifact_paths=()
                archive_ext=""
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

            if [[ -n "$archive_ext" ]] && \
               declare -F artifact_naming_generate_dual_for_tool &>/dev/null; then
                local os arch names_json
                os="${platform%/*}"
                arch="${platform#*/}"
                if [[ -n "$selected_triple" ]]; then
                    names_json=$(artifact_naming_generate_dual_for_variant "$tool_name" "$version" "$os" "$arch" \
                        "$archive_ext" "$local_path" "$selected_triple" 2>/dev/null || echo "")
                else
                    names_json=$(artifact_naming_generate_dual_for_tool "$tool_name" "$version" "$os" "$arch" "$archive_ext" "$local_path" 2>/dev/null || echo "")
                fi
                archive_name=$(echo "$names_json" | jq -r '.versioned // empty' 2>/dev/null)
            fi

            if [[ -n "$archive_ext" && -z "$archive_name" ]]; then
                archive_name="${tool_name}-${version_stripped}-${plat_name}.${archive_ext}"
            fi
            local archive_path="$artifact_dir/$archive_name"

            # Get just the filenames for archive creation
            local archive_files=()
            for p in "${local_artifact_paths[@]}"; do
                archive_files+=("$(basename "$p")")
            done

            local staged_workspace_includes=""
            local workspace_include_revision=""
            if [[ -z "$archive_ext" ]]; then
                :
            elif $strict_native_build; then
                if [[ ! "$release_git_sha" =~ ^[0-9a-f]{40}$ || "$release_git_sha" =~ ^0{40}$ ]]; then
                    _log_error "Strict workspace companion-file staging requires an exact release commit"
                    jq -nc --arg platform "$platform" \
                        '{status: "failed", exit_code: 7, error: ("Release commit is missing for workspace companion-file staging on " + $platform)}'
                    return 7
                fi
                workspace_include_revision="$release_git_sha"
            fi
            if ! staged_workspace_includes=$(
                _act_stage_workspace_include_files \
                    "$config_file" "$local_path" "$artifact_dir" "$workspace_include_revision"
            ); then
                _log_error "Failed to stage configured workspace companion files for $platform"
                jq -nc --arg platform "$platform" \
                    '{status: "failed", exit_code: 7, error: ("Workspace companion-file staging failed for " + $platform)}'
                return 7
            fi
            local staged_include
            while IFS= read -r staged_include; do
                [[ -n "$staged_include" ]] && archive_files+=("$staged_include")
            done <<< "$staged_workspace_includes"
            _log_info "Workspace archive members: ${archive_files[*]}"

            # Create the archive
            local archive_output
            if $strict_native_build; then
                local archive_receipt="" archive_mode=700
                [[ "$platform" == windows/* ]] && archive_mode=600
                case "$archive_ext" in
                    zip)
                        if command -v zip &>/dev/null; then
                            archive_receipt=$(_act_collect_stream_exclusive \
                                "$archive_path" "$archive_mode" \
                                _act_stream_workspace_zip "$artifact_dir" \
                                "${archive_files[@]}") || archive_receipt=""
                        fi
                        ;;
                    tar.gz)
                        archive_receipt=$(_act_collect_stream_exclusive \
                            "$archive_path" "$archive_mode" \
                            _act_stream_workspace_tar_gz "$artifact_dir" \
                            "${archive_files[@]}") || archive_receipt=""
                        ;;
                    tar.xz)
                        archive_receipt=$(_act_collect_stream_exclusive \
                            "$archive_path" "$archive_mode" \
                            _act_stream_workspace_tar_xz "$artifact_dir" \
                            "${archive_files[@]}") || archive_receipt=""
                        ;;
                esac
                if [[ -n "$archive_receipt" ]] && \
                   ! _act_validate_workspace_archive_release_tree_includes \
                       "$archive_path" "$archive_ext" "$config_file" \
                       "$local_path" "$release_git_sha"; then
                    _log_error "Strict workspace archive includes do not match release tree for $platform"
                    archive_receipt=""
                fi
                if [[ -n "$archive_receipt" ]] && \
                   ! _act_validate_workspace_archive_collection_receipts \
                       "$archive_path" "$archive_ext" "$platform" "$config_file" \
                       "${strict_collection_receipts[@]}"; then
                    _log_error "Strict workspace archive binaries do not match collection receipts for $platform"
                    archive_receipt=""
                fi
                if [[ -n "$archive_receipt" && "$tool_name" == frankenterm && \
                      "$platform" == windows/amd64 ]] && \
                   ! _act_validate_frankenterm_windows_archive \
                       "$archive_path" "$release_git_sha" "$version" "$atomic_identity"; then
                    _log_error "Windows family ZIP failed final component-manifest verification"
                    archive_receipt=""
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
            elif [[ "$archive_ext" == "tar.gz" ]]; then
                archive_output=$(cd "$artifact_dir" && \
                    COPYFILE_DISABLE=1 tar --no-xattrs -czf "$archive_name" \
                        "${archive_files[@]}" 2>&1)
                if [[ -f "$archive_path" ]]; then
                    _log_ok "Created archive: $archive_path"
                    local_artifact_path="$archive_path"
                    local_artifact_paths=("$archive_path")
                else
                    _log_warn "Failed to create tar.gz archive"
                    _log_warn "tar output: $archive_output"
                    echo "Archive creation failed: $archive_output" >> "$log_file"
                    local_artifact_path=$(IFS=','; echo "${local_artifact_paths[*]}")
                fi
            else
                archive_output=$(cd "$artifact_dir" && \
                    COPYFILE_DISABLE=1 tar --no-xattrs -cJf "$archive_name" \
                        "${archive_files[@]}" 2>&1)
                if [[ -f "$archive_path" ]]; then
                    _log_ok "Created archive: $archive_path"
                    # Update artifact path to point to the archive
                    local_artifact_path="$archive_path"
                    local_artifact_paths=("$archive_path")
                else
                    _log_warn "Failed to create tar.xz archive"
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

    # A failed or timed-out staged build never reached collection.
    _act_remove_build_stage_root "$host" "$output_stage_root"

    # Return JSON result (pointing to LOCAL artifact path)
    # Keep exact paths; the comma-separated scalar is a display surface only.
    local artifact_paths_json="[]"
    if [[ ${#local_artifact_paths[@]} -gt 0 ]]; then
        artifact_paths_json=$(printf '%s\0' "${local_artifact_paths[@]}" | jq -Rsc 'split("\u0000")[:-1]') || return 4
    fi
    local additional_artifacts_json="[]"
    if [[ ${#additional_artifact_receipts[@]} -gt 0 ]]; then
        additional_artifacts_json=$(printf '%s\n' \
            "${additional_artifact_receipts[@]}" | jq -s '.') || return 4
    elif [[ ${#local_additional_artifact_paths[@]} -gt 0 ]]; then
        local additional_path additional_sha additional_size additional_identity
        local additional_records=()
        for additional_path in "${local_additional_artifact_paths[@]}"; do
            additional_sha=$(_act_sha256 "$additional_path") || return 4
            additional_size=$(_act_file_size "$additional_path") || return 4
            additional_identity=$(_act_file_identity "$additional_path") || return 4
            additional_records+=("$(jq -nc \
                --arg path "$additional_path" --arg sha256 "${additional_sha,,}" \
                --argjson size_bytes "$additional_size" \
                --arg identity "$additional_identity" \
                '{path: $path, sha256: $sha256, size_bytes: $size_bytes, identity: $identity}')")
        done
        additional_artifacts_json=$(printf '%s\n' \
            "${additional_records[@]}" | jq -s '.') || return 4
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
        --argjson additional_artifacts "$additional_artifacts_json" \
        --arg target_triple "$native_target_triple" \
        --arg collected_sha256 "$collected_sha256" \
        --argjson collected_size_bytes "$collected_size_bytes" \
        --arg collected_identity "$collected_identity" \
        --argjson build_influence_env "$build_influence_env_json" \
        --argjson cargo_isolation "$cargo_isolation_json" \
        --arg log_file "$log_file" \
        '{
            tool: $tool,
            platform: $platform,
            host: $host,
            method: "native",
            target_triple: (if $target_triple == "" then null else $target_triple end),
            status: $status,
            exit_code: $exit_code,
            duration_seconds: $duration,
            artifact_path: $artifact_path,
            artifact_paths: $artifact_paths,
            additional_artifacts: $additional_artifacts,
            collected_sha256: (if $collected_sha256 == "" then null else $collected_sha256 end),
            collected_size_bytes: (if $collected_size_bytes == 0 then null else $collected_size_bytes end),
            collected_identity: (if $collected_identity == "" then null else $collected_identity end),
            build_influence_env: $build_influence_env,
            cargo_isolation: $cargo_isolation,
            log_file: $log_file
        }'

    return "$exit_code"
}

# Freeze every regular artifact represented by a target result. Receipts cover
# explicit artifact paths and every file below artifact_dir, so a resumed run
# can distinguish verified reusable output from missing, replaced, or mutated
# bytes. A successful target with no artifact bytes is not resumable.
_act_result_artifact_receipts() {
    local result_json="$1"
    local -A seen_paths=()
    local -a artifact_paths=() receipts=()
    local path artifact_dir legacy_paths array_count

    # The array form is authoritative and preserves commas/newlines in valid
    # Unix paths. The scalar form is a legacy comma-separated compatibility
    # surface and is parsed only after the exact array entries.
    array_count=$(jq -er '
        (.artifact_paths // []) |
        if type == "array" then length else error("artifact_paths must be an array") end
    ' <<< "$result_json" 2>/dev/null) || return 4
    while IFS= read -r -d '' path; do
        [[ -n "$path" && -z "${seen_paths[$path]:-}" ]] || continue
        seen_paths["$path"]=1
        artifact_paths+=("$path")
    done < <(jq -j '
        (.artifact_paths // [])[]? |
        select(type == "string" and length > 0) | ., "\u0000"
    ' <<< "$result_json" 2>/dev/null)
    if [[ "$array_count" -eq 0 ]]; then
        legacy_paths=$(jq -r '.artifact_path // empty' <<< "$result_json" 2>/dev/null)
        while IFS= read -r path; do
            [[ -n "$path" && -z "${seen_paths[$path]:-}" ]] || continue
            seen_paths["$path"]=1
            artifact_paths+=("$path")
        done < <(printf '%s\n' "$legacy_paths" | tr ',' '\n')
    fi

    local additional_count
    additional_count=$(jq -er '
        (.additional_artifacts // []) |
        if type == "array" then length
        else error("additional_artifacts must be an array") end
    ' <<< "$result_json" 2>/dev/null) || return 4
    while IFS= read -r -d '' path; do
        [[ -n "$path" && -z "${seen_paths[$path]:-}" ]] || continue
        seen_paths["$path"]=1
        artifact_paths+=("$path")
    done < <(jq -j '
        (.additional_artifacts // [])[]? | .path |
        select(type == "string" and length > 0) | ., "\u0000"
    ' <<< "$result_json" 2>/dev/null)
    if [[ "$additional_count" -gt 0 && \
          ${#artifact_paths[@]} -lt "$additional_count" ]]; then
        return 4
    fi

    artifact_dir=$(jq -r '.artifact_dir // empty' <<< "$result_json" 2>/dev/null)
    if [[ -n "$artifact_dir" ]]; then
        [[ -d "$artifact_dir" && ! -L "$artifact_dir" ]] || return 4
        # Process substitution cannot propagate find's exit status. Preflight
        # traversal explicitly so an unreadable subtree cannot yield a
        # deceptively partial receipt set.
        find "$artifact_dir" -type f ! -type l -print0 >/dev/null 2>&1 || return 4
        while IFS= read -r -d '' path; do
            [[ -z "${seen_paths[$path]:-}" ]] || continue
            seen_paths["$path"]=1
            artifact_paths+=("$path")
        done < <(find "$artifact_dir" -type f ! -type l -print0 2>/dev/null)
    fi

    [[ ${#artifact_paths[@]} -gt 0 ]] || return 4
    for path in "${artifact_paths[@]}"; do
        local sha size identity receipt
        [[ -f "$path" && ! -L "$path" ]] || return 4
        sha=$(_act_sha256 "$path") || return 4
        size=$(_act_file_size "$path") || return 4
        identity=$(_act_file_identity "$path") || return 4
        [[ "$sha" =~ ^[a-fA-F0-9]{64}$ && "$size" =~ ^[0-9]+$ &&
           "$identity" =~ ^(gnu:[0-9]+:[1-9][0-9]*|bsd:[1-9][0-9]*)$ ]] || return 4
        receipt=$(jq -nc --arg path "$path" --arg sha256 "${sha,,}" \
            --argjson size_bytes "$size" --arg identity "$identity" \
            '{path: $path, sha256: $sha256, size_bytes: $size_bytes, identity: $identity}') || return 4
        receipts+=("$receipt")
    done

    printf '%s\n' "${receipts[@]}" | jq -sc 'sort_by(.path)'
}

# Return success only when a persisted result still points at the exact frozen
# artifacts recorded at target completion.
_act_target_result_available() {
    local result_json="$1"
    local purpose="${2:-release}" require_purpose="${3:-false}"
    _act_build_purpose_matches "$result_json" "$purpose" "$require_purpose" || return 1
    jq -e '(.status == "success" or .status == "ok" or .status == "passed")' \
        <<< "$result_json" &>/dev/null || return 1
    local expected actual
    expected=$(jq -ce '
        .resume_artifacts |
        if type == "array" and length > 0 then sort_by(.path)
        else error("missing artifact receipts") end
    ' <<< "$result_json" 2>/dev/null) || return 1
    actual=$(_act_result_artifact_receipts "$result_json" 2>/dev/null) || return 1
    [[ "$actual" == "$expected" ]]
}

# Expand only native Rust variants. Platform identity remains the routing and
# release-contract authority; task identity distinguishes independent attempts.
# Validate the entire matrix before launching its first compiler.
_act_build_task_plan() {
    local tool="$1" version="$2" platforms_json="$3" strict="$4"
    local platform method triples triple key environment command command_template language binary_name
    local plan='[]' config_file="$ACT_REPOS_DIR/${tool}.yaml"
    language=$(yq -r '.language // ""' "$config_file") || return 4
    binary_name=$(yq -r '.binary_name // ""' "$config_file") || return 4
    [[ -n "$binary_name" ]] || binary_name="$tool"
    while IFS= read -r platform; do
        method=native
        if act_platform_uses_act "$tool" "$platform"; then
            method=act
            triples=""
        else
            triples=$(act_get_configured_target_triples "$tool" "$platform") || return 4
        fi
        if [[ "$triples" == *$'\n'* ]]; then
            if [[ "$strict" == true || "$language" != rust ]]; then
                _log_error "Native target variants require an ordinary Rust build: $platform"
                return 4
            fi
            command_template=$(act_get_build_cmd "$tool" "$platform") || return 4
            while IFS= read -r triple; do
                command=$(act_substitute_build_cmd_tokens "$command_template" "$binary_name" "$version" \
                    "${platform%%/*}" "${platform##*/}" "$triple") || return 4
                environment=$(act_get_build_env "$tool" "$platform" "$triple") || return 4
                _act_validate_native_target_command "$command" "$environment" "$triple" || return 4
                key="$platform@$triple"
                plan=$(jq -c --arg key "$key" --arg platform "$platform" \
                    --arg triple "$triple" --arg method "$method" \
                    '. + [{key:$key, platform:$platform, target_triple:$triple, method:$method}]' \
                    <<< "$plan") || return 4
            done <<< "$triples"
        else
            plan=$(jq -c --arg key "$platform" --arg platform "$platform" \
                --arg triple "$triples" --arg method "$method" \
                '. + [{key:$key, platform:$platform, target_triple:$triple, method:$method}]' \
                <<< "$plan") || return 4
        fi
    done < <(jq -r '.[]' <<< "$platforms_json")
    printf '%s\n' "$plan"
}

# Matrix success must originate from the selected native invocation. Never
# manufacture missing or contradictory execution identity from a scheduler row.
_act_matrix_result_matches() {
    local result="$1" platform="$2" triple="$3"
    [[ -z "$triple" ]] && return 0
    jq -e --arg platform "$platform" --arg triple "$triple" '
        .platform == $platform and .target_triple == $triple and .method == "native"
    ' <<< "$result" >/dev/null 2>&1
}

# Execute exactly one target and emit one compact JSON result as the final
# stdout line. Diagnostic/build output is retained on stderr by the worker.
_act_build_orchestration_target() {
    local tool_name="$1"
    local version="$2"
    local run_id="$3"
    local target="$4"
    local strict_release_contract="$5"
    local release_contract_json="$6"
    local source_roots_json="$7"
    local release_git_sha="${8:-}"
    local release_git_ref="${9:-}"
    local bound_host="${10:-}"
    local selected_triple="${11:-}"

    local host="${bound_host:-act-local}" remote_path_override="" ordinary_source_root=""
    if [[ "$strict_release_contract" == "true" ]]; then
        if [[ -z "$bound_host" ]] || ! remote_path_override=$(jq -er --arg host "$bound_host" \
            '.[$host] | strings | select(length > 0)' <<< "$source_roots_json"); then
            _log_error "Missing strict target host/source binding"
            jq -nc '{status: "error", exit_code: 4, error: "Missing strict target host/source binding"}'
            return 4
        fi
    elif [[ -z "$bound_host" ]] && ! act_platform_uses_act "$tool_name" "$target"; then
        host=$(act_get_native_host "$target" "$tool_name")
    fi
    if [[ "$strict_release_contract" != "true" ]] && ! act_platform_uses_act "$tool_name" "$target"; then
        ordinary_source_root=$(jq -r --arg host "$host" '.[$host] // empty' <<< "$source_roots_json") || return 4
    fi
    # Ordinary run provenance is not a strict snapshot identity. Only strict
    # callers may pass these values to the native snapshot boundary.
    if [[ "$strict_release_contract" != "true" ]]; then
        release_git_sha=""
        release_git_ref=""
    fi

    _log_info "--- Building target: $target ---"

    local result exit_code=0 full_output=""
    if act_platform_uses_act "$tool_name" "$target"; then
        if [[ "$strict_release_contract" == "true" ]]; then
            _log_error "Strict target configuration changed to an unbound build method"
            jq -nc '{status: "error", exit_code: 4, error: "Strict release targets must use native builds"}'
            return 4
        fi
        local job workflow local_path extra_flags
        job=$(act_get_job_for_target "$tool_name" "$target")
        workflow="$ACT_REPO_WORKFLOW"
        local_path="$ACT_REPO_LOCAL_PATH"
        extra_flags=$(act_get_flags "$tool_name" "$target")
        _log_info "Method: act (job=$job)"

        local act_args=()
        [[ -n "$extra_flags" ]] && read -ra act_args <<< "$extra_flags"
        full_output=$(act_run_workflow \
            "$local_path" "$workflow" "$job" "push" "$version" \
            "${act_args[@]}" 2>&1) || exit_code=$?
        [[ -n "$full_output" ]] && printf '%s\n' "$full_output" >&2
        result=$(printf '%s\n' "$full_output" | grep '^{.*}$' | tail -1)
        if [[ -z "$result" ]] || ! jq -e '.' <<< "$result" &>/dev/null; then
            local fallback_status="failed"
            [[ "$exit_code" -eq 0 ]] && fallback_status="success"
            result=$(jq -nc --arg status "$fallback_status" --argjson exit_code "$exit_code" \
                '{status: $status, exit_code: $exit_code}')
        fi
        result=$(jq -c --arg target "$target" --arg method "act" --arg host "$host" \
            '. + {platform: $target, method: $method, host: $host}' <<< "$result")
        # A workflow that exits 0 but uploads nothing gives the release no
        # binary; packaging would only warn and the build would still exit 0
        # (bd-1ldf).  A missing count is treated as zero: fail closed.
        if [[ "$exit_code" -eq 0 ]] && jq -e '
               (.status == "success" or .status == "ok" or .status == "passed") and
               ((.artifact_count // 0) | (type != "number" or . < 1))
           ' <<< "$result" >/dev/null 2>&1; then
            _log_error "act job '$job' for $target succeeded but produced no artifacts"
            exit_code=6
            result=$(jq -c '.status = "failed" | .exit_code = 6 |
                .error = "act workflow completed without producing any artifacts"' <<< "$result")
        fi
    else
        _log_info "Method: native (host=$host)"
        full_output=$(act_run_native_build \
            "$tool_name" "$target" "$version" "$run_id" "$remote_path_override" \
            "$release_git_sha" "$release_git_ref" "$host" "$selected_triple" "$ordinary_source_root" 2>&1) || exit_code=$?
        [[ -n "$full_output" ]] && printf '%s\n' "$full_output" >&2
        result=$(printf '%s\n' "$full_output" | grep '^{' | tail -1)
        if [[ -z "$result" ]] || ! jq -e '.' <<< "$result" &>/dev/null; then
            local fallback_status="failed"
            [[ "$exit_code" -eq 0 ]] && fallback_status="success"
            result=$(jq -nc --arg status "$fallback_status" --argjson exit_code "$exit_code" \
                --arg platform "$target" --arg method "native" --arg host "$host" \
                '{status: $status, exit_code: $exit_code, platform: $platform,
                  method: $method, host: $host}')
        fi
    fi

    local result_status
    result_status=$(jq -r '.status // "unknown"' <<< "$result")
    if [[ "$result_status" == success || "$result_status" == ok || "$result_status" == passed ]] && \
       ! _act_matrix_result_matches "$result" "$target" "$selected_triple"; then
        exit_code=4
        result_status=failed
        result=$(jq -c '.status = "failed" | .exit_code = 4 |
            .error = "Native variant result does not match the requested target triple"' <<< "$result") || return 4
    fi
    if [[ "$exit_code" -ne 0 ]] &&
       [[ "$result_status" == "success" || "$result_status" == "ok" ||
          "$result_status" == "passed" ]]; then
        result=$(jq -c --argjson exit_code "$exit_code" '
            .status = "failed" | .exit_code = $exit_code |
            .error = (.error // "Build command exited nonzero despite reporting success")
        ' <<< "$result")
        result_status="failed"
    fi

    if [[ "$strict_release_contract" == "true" ]]; then
        local staged_result
        if [[ "$result_status" == "success" ]]; then
            if staged_result=$(_act_stage_contract_primary \
                "$tool_name" "$version" "$run_id" "$target" \
                "$result" "$release_contract_json"); then
                result="$staged_result"
            else
                exit_code=4
                result=$(jq -c \
                    '.status = "failed" | .exit_code = 4 |
                     .error = "Release primary staging failed"' <<< "$result")
            fi
        fi
    fi

    if ! result=$(jq -c --argjson worker_exit "$exit_code" \
        '.exit_code = (.exit_code // $worker_exit)' <<< "$result"); then
        return 4
    fi
    printf '%s\n' "$result"
    return "$exit_code"
}

# Output files a native target's build writes on its host, one
# "<in-tree|external><TAB><path>" line per binary, so the orchestrator can keep
# --parallel targets from overwriting each other's binaries. A path is
# in-tree when it lies under the build's source root (a per-target source
# copy then makes it private). A trailing .exe is dropped: Go's `-o name`
# never appends it, so windows and unix targets can share one file. Rust
# targets print nothing (Cargo scopes outputs by target triple), as do act
# targets and unreadable configs (the build itself reports those).
_act_native_output_paths() {
    local tool_name="$1" target="$2" host="$3" strict="$4" source_roots_json="$5"
    local config_file="$ACT_REPOS_DIR/${tool_name}.yaml"
    local language remote_path build_env build_profile binaries bin path

    [[ -f "$config_file" ]] || return 0
    act_platform_uses_act "$tool_name" "$target" && return 0
    language=$(yq -r '.language // ""' "$config_file" 2>/dev/null) || return 0
    [[ "$language" == rust ]] && return 0
    if [[ "$strict" == true ]]; then
        remote_path=$(jq -r --arg host "$host" '.[$host] // ""' <<< "$source_roots_json" 2>/dev/null) || return 0
    else
        remote_path=$(jq -r --arg host "$host" '.[$host] // ""' <<< "$source_roots_json" 2>/dev/null) || return 0
        if [[ -z "$remote_path" ]]; then
            remote_path=$(DSR_OUTPUT_HOST="$host" yq -r '.host_paths[strenv(DSR_OUTPUT_HOST)] // ""' \
                "$config_file" 2>/dev/null) || remote_path=""
        fi
        [[ "$remote_path" == null ]] && remote_path=""
        [[ -n "$remote_path" ]] || remote_path=$(act_get_local_path "$tool_name" 2>/dev/null) || return 0
    fi
    remote_path="${remote_path%/}"
    [[ -n "$remote_path" ]] || return 0
    build_env=$(act_get_build_env "$tool_name" "$target" 2>/dev/null) || return 0
    build_profile=$(yq -r '.build_profile // "release"' "$config_file" 2>/dev/null) || return 0
    binaries=$(_act_workspace_binaries_for_target "$config_file" "$target" 2>/dev/null) || return 0
    [[ -n "$binaries" ]] || binaries=$(yq -r '.binary_name // ""' "$config_file" 2>/dev/null) || return 0
    while IFS= read -r bin; do
        [[ -n "$bin" && "$bin" != null ]] || continue
        path=$(act_get_remote_artifact_path "$language" "$remote_path" "$build_env" \
            "$bin" "$target" "$build_profile") || continue
        path="${path%.exe}"
        if [[ "$path" == "$remote_path"/* ]]; then
            printf 'in-tree\t%s\n' "$path"
        else
            printf 'external\t%s\n' "$path"
        fi
    done <<< "$binaries"
}

# Worker wrapper: reserve host capacity and write immutable attempt receipts.
_act_run_target_worker() {
    local tool_name="$1" version="$2" run_id="$3" target="$4"
    local attempt="$5" log_path="$6" result_path="$7"
    local strict_release_contract="$8" release_contract_json="$9"
    local source_roots_json="${10}"
    local release_git_sha="${11:-}"
    local release_git_ref="${12:-}"
    local bound_host="${13:-}"
    local build_purpose="${14:-release}"
    local selected_triple="${15:-}" task_key="${16:-$target}"
    local source_sync_receipt="${17:-}"
    [[ -n "$source_sync_receipt" ]] || source_sync_receipt=null

    local host="${bound_host:-act-local}"
    local slot_task="${task_key//\//-}"
    slot_task="${slot_task//@/-}"
    local slot_id="${run_id}-${slot_task}-attempt-${attempt}"
    local slot_acquired=false

    _act_write_worker_result() {
        local body="$1"
        # Never trust build-command stdout to classify an artifact for publication.
        body=$(jq -c --arg purpose "$build_purpose" --arg task_key "$task_key" \
            --argjson source_sync "$source_sync_receipt" \
            '. + {build_purpose: $purpose, publishable: ($purpose == "release"), task_key:$task_key} |
             if $source_sync == null then . else .source_sync = $source_sync end' \
            <<< "$body") || return 4
        (
            umask 077
            set -o noclobber
            printf '%s\n' "$body" > "$result_path"
        )
    }

    if [[ "$strict_release_contract" == "true" ]] && \
       { [[ -z "$bound_host" ]] || ! jq -e --arg host "$bound_host" \
           '.[$host] | type == "string" and length > 0' <<< "$source_roots_json" >/dev/null; }; then
        _act_write_worker_result '{"status":"failed","exit_code":4,"error":"Missing strict worker source binding"}' || return 4
        return 4
    fi

    if [[ -z "$bound_host" ]] && ! act_platform_uses_act "$tool_name" "$target"; then
        host=$(act_get_native_host "$target" "$tool_name")
    fi

    if [[ "$source_sync_receipt" != null ]] &&
       [[ "$(jq -r '.status' <<< "$source_sync_receipt")" != success ]]; then
        local source_failure
        source_failure=$(jq -nc --arg target "$target" --arg host "$host" \
            --arg triple "$selected_triple" --argjson sync "$source_sync_receipt" \
            '{platform:$target, host:$host, method:"native", status:"failed", exit_code:1,
              stage:"source_sync", target_triple:(if $triple == "" then null else $triple end),
              error:("Source synchronization failed for " + $host + ": " + ($sync.error // "transfer failed"))}') || return 4
        jq -r '.error' <<< "$source_failure" >> "$log_path"
        _act_write_worker_result "$source_failure" || return 4
        return 1
    fi

    # The native runner deliberately names its log with the immutable source
    # run UUID. Scope its existing log-directory setting to this attempt so a
    # retry cannot overwrite the file named by an older result receipt.
    local ACT_LOGS_DIR="$ACT_LOGS_DIR"
    if ! act_platform_uses_act "$tool_name" "$target"; then
        ACT_LOGS_DIR="${log_path%.log}.native"
        if ! (umask 077; mkdir "$ACT_LOGS_DIR"); then
            _act_write_worker_result "$(jq -nc --arg target "$target" --arg host "$host" \
                '{platform:$target,host:$host,status:"failed",exit_code:4,
                  error:"Native attempt log directory already exists or is unavailable"}')" || return 4
            return 4
        fi
    fi

    if declare -F selector_acquire_slot &>/dev/null; then
        # A target whose host is at its concurrency limit queues for a slot
        # rather than failing: its budget is one build timeout (the longest a
        # running peer may legitimately hold the slot), unless the operator
        # set DSR_SELECTOR_WAIT_TIMEOUT. The selector caps budgets at 99999s.
        local slot_wait_budget="${DSR_SELECTOR_WAIT_TIMEOUT:-${_ACT_BUILD_TIMEOUT:-3600}}"
        if [[ "$slot_wait_budget" =~ ^[0-9]+$ ]] && ((${#slot_wait_budget} > 5)); then
            slot_wait_budget=99999
        fi
        local slot_status=0 slot_wait_started=$SECONDS
        DSR_SELECTOR_WAIT_TIMEOUT="$slot_wait_budget" \
            selector_acquire_slot "$host" "$slot_id" --wait || slot_status=$?
        if [[ $slot_status -ne 0 ]]; then
            local slot_failure slot_error
            if [[ $slot_status -eq 2 ]]; then
                slot_error="Host capacity acquisition failed: no build slot on $host after waiting $((SECONDS - slot_wait_started))s (budget ${slot_wait_budget}s; raise hosts.yaml concurrency, move the target to another host, or set DSR_SELECTOR_WAIT_TIMEOUT)"
            else
                slot_error="Host capacity acquisition failed on $host (selector status $slot_status)"
            fi
            slot_failure=$(jq -nc --arg target "$target" --arg host "$host" --arg error "$slot_error" \
                '{platform: $target, host: $host, status: "failed", exit_code: 2,
                  error: $error}')
            _act_write_worker_result "$slot_failure" || return 4
            return 2
        fi
        slot_acquired=true
    fi

    _act_worker_release_slot() {
        if $slot_acquired && declare -F selector_release_slot &>/dev/null; then
            selector_release_slot "$host" "$slot_id" >/dev/null 2>&1 || true
            slot_acquired=false
        fi
    }

    local worker_pid=""
    _act_worker_cancel() {
        # Ignore repeated signals while the first cancellation drains the
        # dedicated build process group and releases the host slot.
        trap '' INT TERM
        if [[ "$worker_pid" =~ ^[1-9][0-9]*$ ]] && kill -0 "$worker_pid" 2>/dev/null; then
            # Job control gives the target and all of its descendants a
            # dedicated process group, so cancellation does not orphan ssh,
            # compilers, or user build commands.
            kill -TERM -- "-$worker_pid" 2>/dev/null || kill -TERM "$worker_pid" 2>/dev/null || true
            wait "$worker_pid" 2>/dev/null || true
        fi
        exit 130
    }
    trap _act_worker_release_slot EXIT
    trap _act_worker_cancel INT TERM

    local worker_status=0 result receipts result_status
    set -m
    _act_build_orchestration_target \
        "$tool_name" "$version" "$run_id" "$target" \
        "$strict_release_contract" "$release_contract_json" "$source_roots_json" \
        "$release_git_sha" "$release_git_ref" "$host" "$selected_triple" \
        >> "$log_path" 2>&1 &
    worker_pid=$!
    # The process group remains distinct after monitor mode is disabled; this
    # avoids interactive-style job-completion notices in coordinator logs.
    set +m
    wait "$worker_pid" || worker_status=$?
    worker_pid=""

    result=$(grep '^{.*}$' "$log_path" | tail -1)
    if [[ -z "$result" ]] || ! jq -e '.' <<< "$result" &>/dev/null; then
        result=$(jq -nc --arg target "$target" --arg host "$host" \
            --argjson exit_code "$worker_status" \
            '{platform: $target, host: $host, status: "failed",
              exit_code: $exit_code, error: "Worker produced no valid result"}')
    fi
    result_status=$(jq -r '.status // "unknown"' <<< "$result")
    if [[ "$result_status" == success || "$result_status" == ok || "$result_status" == passed ]] && \
       ! _act_matrix_result_matches "$result" "$target" "$selected_triple"; then
        worker_status=4
        result_status=failed
        result=$(jq -c '.status = "failed" | .exit_code = 4 |
            .error = "Native worker result does not match the requested target triple"' <<< "$result") || return 4
    fi
    if [[ "$result_status" == "success" || "$result_status" == "ok" ||
          "$result_status" == "passed" ]]; then
        if receipts=$(_act_result_artifact_receipts "$result"); then
            result=$(jq -c --argjson receipts "$receipts" \
                '.resume_artifacts = $receipts' <<< "$result")
        else
            worker_status=4
            result=$(jq -c '
                .status = "failed" | .exit_code = 4 |
                .error = "Successful worker output could not be frozen for resume"
            ' <<< "$result")
        fi
    fi
    if ! _act_write_worker_result "$result"; then
        return 4
    fi
    _act_worker_release_slot
    trap - EXIT INT TERM
    return "$worker_status"
}

# Main orchestration function: coordinate act + SSH builds
# Usage: act_orchestrate_build <tool_name> <version>
#        [--git-sha SHA --git-ref TAG --parallel-jobs N --resume-run-id UUID]
#        [targets...]
# Returns: JSON with aggregated results
# Called only under the existing coordinator lock, after normal resume identity
# checks. Source staging is confined to the explicitly selected replacement host.
_act_relocation_source_inventory() {
    local tool="$1" revision="$2" dependencies records='[]' item path sha label manifest archive_digest manifest_digest
    dependencies=$(_act_release_source_dependency_checkouts_json "$tool") || return 4
    dependencies=$(jq -c --arg path "$ACT_REPO_LOCAL_PATH" --arg sha "$revision" \
        '[{relative_path: "source", local_path: $path, git_sha: $sha}] + .' <<< "$dependencies") || return 4
    while IFS= read -r item; do
        path=$(jq -r '.local_path' <<< "$item")
        sha=$(jq -r '.git_sha' <<< "$item")
        label=$(jq -r '.relative_path' <<< "$item")
        manifest=$(mktemp -d "${DSR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsr}/relocation-manifest.XXXXXXXX") || return 4
        manifest="$manifest/tracked.manifest"
        _act_write_tracked_manifest "$path" "$sha" "$manifest" || return 4
        archive_digest=$(_act_git_archive_sha256 "$path" "$sha") || return 4
        manifest_digest=$(_act_sha256 "$manifest") || return 4
        [[ "$archive_digest" =~ ^[0-9a-f]{64}$ && "$manifest_digest" =~ ^[0-9a-f]{64}$ ]] || return 4
        records=$(jq -c --arg path "$label" --arg sha "$sha" --arg archive "$archive_digest" \
            --arg manifest "$manifest_digest" '. + [{path: $path, git_sha: $sha,
            archive_sha256: $archive, manifest_sha256: $manifest}]' <<< "$records") || return 4
    done < <(jq -c '.[]' <<< "$dependencies")
    printf '%s\n' "$records"
}

_act_relocate_failed_target() {
    local tool="$1" version="$2" run_id="$3" before="$4" request="$5" approval_file="$6"
    local target="${request%%=*}" host="${request#*=}" old_host configured_host host_platform
    local config_file="$ACT_REPOS_DIR/${tool}.yaml" hosts_file="${DSR_CONFIG_DIR:-$HOME/.config/dsr}/hosts.yaml"
    local entry result result_path sync_json roots hosts receipt repo_hash hosts_hash
    local prior_result prior_log result_hash log_hash
    local approval prior_config prior_config_hash prior_json current_json projection
    local source_inventory dependency_checkouts replacement_path replacement_root
    [[ "$request" == *=* && "$target" =~ ^[a-z]+/[a-z0-9]+$ &&
       "$host" =~ ^[A-Za-z0-9_-]+$ ]] || return 4
    old_host=$(jq -er --arg target "$target" '.context.target_hosts[$target] | strings' <<< "$before") || return 4
    [[ "$host" != "$old_host" ]] || return 4
    [[ -f "$approval_file" && ! -L "$approval_file" ]] || return 4
    approval=$(jq -ce --arg target "$target" --arg host "$host" --arg run "$run_id" '
        select(.run_id == $run and .target == $target and .new_host == $host) |
        select(all([.prior_repo_config_sha256,.repo_config_sha256,.hosts_config_sha256][];
                   type == "string" and test("^[0-9a-f]{64}$")))' "$approval_file") || return 4
    prior_config=$(jq -er '.prior_repo_config_path | strings' <<< "$approval") || return 4
    [[ -f "$prior_config" && ! -L "$prior_config" ]] || return 4
    prior_config_hash=$(_act_sha256 "$prior_config") || return 4
    [[ "$prior_config_hash" == "$(jq -r '.prior_repo_config_sha256' <<< "$approval")" ]] || return 4
    prior_json=$(yq -o=json '.' "$prior_config") || return 4
    current_json=$(yq -o=json '.' "$config_file") || return 4
    # Only the failed target's explicit command/environment/routing may differ.
    # Global source/profile/contract and every completed target stay identical.
    projection='del(.cross_compile[$target].host,.cross_compile[$target].build_cmd,.cross_compile[$target].env,.hosts[$target])'
    [[ "$(jq -cS --arg target "$target" "$projection" <<< "$prior_json")" == \
       "$(jq -cS --arg target "$target" "$projection" <<< "$current_json")" ]] || return 4
    jq -e --arg target "$target" '
      .context.build_purpose == "release" and .context.publishable == true and
      .status != "completed" and .status != "cancelled" and
      .target_statuses[$target].status == "failed" and
      all(.target_statuses[]; .status != "running")
    ' <<< "$before" >/dev/null || return 4
    act_platform_uses_act "$tool" "$target" && return 4
    configured_host=$(act_get_native_host "$target" "$tool") || return 4
    [[ "$configured_host" == "$host" ]] || return 4
    host_platform=$(_act_get_host_platform "$host") || return 4
    if [[ "$host_platform" != "$target" ]]; then
        # A native worker executes on its host OS while producing the requested
        # target, just as act_run_native_build does for an initial cross build.
        # Relocation may use that route only when the reviewed target-specific
        # recipe explicitly selects this host and supplies a build command.
        # A platform-mapping fallback alone cannot authorize a cross build.
        if [[ ! "$host_platform" =~ ^[a-z]+/[a-z0-9]+$ ]] ||
           ! jq -e --arg target "$target" --arg host "$host" '
                .cross_compile[$target] as $cross |
                ($cross | type == "object") and $cross.host == $host and
                (($cross.build_cmd // .build_cmd) |
                    type == "string" and test("[^[:space:]]"))
            ' <<< "$current_json" >/dev/null; then
            _log_error "Relocation to $host ($host_platform) requires an explicit cross_compile.$target host and build command"
            return 4
        fi
        _log_info "Relocating $target to configured cross-build host $host ($host_platform)"
    fi
    prior_result=$(jq -er --arg target "$target" '.target_statuses[$target].result_path | strings' <<< "$before") || return 4
    prior_log=$(jq -er --arg target "$target" '.target_statuses[$target].log_path | strings' <<< "$before") || return 4
    [[ -f "$prior_result" && ! -L "$prior_result" && -f "$prior_log" && ! -L "$prior_log" ]] || return 4
    jq -e --arg target "$target" --arg host "$old_host" \
        '.platform == $target and .host == $host and .status == "failed" and .build_purpose == "release" and .publishable == true' \
        "$prior_result" >/dev/null || return 4
    result_hash=$(_act_sha256 "$prior_result") || return 4
    log_hash=$(_act_sha256 "$prior_log") || return 4
    [[ "$result_hash" =~ ^[0-9a-f]{64}$ && "$log_hash" =~ ^[0-9a-f]{64}$ ]] || return 4
    result=$(jq -c --arg target "$target" '.target_statuses[$target].result' <<< "$before") || return 4
    [[ "$(jq -cS 'del(.log_path,.result_path,.attempt)' "$prior_result")" == \
       "$(jq -cS 'del(.log_path,.result_path,.attempt)' <<< "$result")" ]] || return 4
    jq -e --arg sha "$(jq -r '.git_sha' <<< "$before")" --arg ref "$(jq -r '.git_ref' <<< "$before")" \
        '.build_influence_env.DSR_RELEASE_GIT_SHA == $sha and .build_influence_env.DSR_RELEASE_GIT_REF == $ref' \
        "$prior_result" >/dev/null || return 4
    # An unavailable successful artifact is not permission to silently rebuild
    # or relocate it. Preserve all successful receipt identities before staging.
    while IFS= read -r entry; do
        result=$(jq -c '.result // empty' <<< "$entry")
        result_path=$(jq -r '.result_path // empty' <<< "$entry")
        [[ -n "$result" ]] && _act_target_result_available "$result" release true || return 4
        if [[ -n "$result_path" ]]; then
            [[ -f "$result_path" && ! -L "$result_path" ]] || return 4
            [[ "$(jq -cS 'del(.log_path,.result_path,.attempt)' "$result_path")" == \
               "$(jq -cS 'del(.log_path,.result_path,.attempt)' <<< "$result")" ]] || return 4
        fi
    done < <(jq -c '.target_statuses[] | select(.status == "completed")' <<< "$before")
    repo_hash=$(_act_sha256 "$config_file") || return 4
    hosts_hash=$(_act_sha256 "$hosts_file") || return 4
    [[ "$repo_hash" == "$(jq -r '.repo_config_sha256' <<< "$approval")" &&
       "$hosts_hash" == "$(jq -r '.hosts_config_sha256' <<< "$approval")" ]] || return 4
    if ! sync_json=$(act_sync_sources "$tool" --strict-release --run-id "$run_id" \
        --git-sha "$(jq -r '.git_sha' <<< "$before")" -- "$target"); then
        # A previous attempt may have finished immutable staging before a
        # later verification or state write failed. Reuse only the complete
        # canonical snapshot whose archive, manifest and checkout all verify
        # against the pinned source; never merge into a partial destination.
        replacement_path=$(yq -r '.host_paths.'"$host"' // ""' "$config_file") || return 4
        [[ -n "$replacement_path" ]] || replacement_path="$ACT_REPO_LOCAL_PATH"
        replacement_root=$(_act_strict_source_root_path "$replacement_path" "$tool" "$run_id" "$host") || return 4
        roots=$(jq -cn --arg host "$host" --arg root "$replacement_root" '{($host):$root}') || return 4
        _act_verify_strict_source_roots "$tool" "$(jq -r '.git_sha' <<< "$before")" "$roots" || return 4
        sync_json=$(jq -cn --arg target "$target" --arg host "$host" --argjson roots "$roots" \
            '{status:"success",failed:0,reused_verified_snapshot:true,
              target_hosts:{($target):$host},source_roots:$roots}') || return 4
    fi
    jq -e --arg target "$target" --arg host "$host" '
      .status == "success" and .failed == 0 and
      .target_hosts == {($target): $host} and
      (.source_roots | keys) == [$host]
    ' <<< "$sync_json" >/dev/null || return 4
    hosts=$(jq -c --arg target "$target" --arg host "$host" '.context.target_hosts + {($target): $host}' <<< "$before") || return 4
    roots=$(jq -cn --argjson prior "$(jq -c '.context.source_roots' <<< "$before")" \
        --argjson added "$(jq -c '.source_roots' <<< "$sync_json")" --argjson hosts "$hosts" \
        '($prior + $added) | with_entries(select(.key as $key | $hosts | any(. == $key)))') || return 4
    _act_verify_strict_source_roots "$tool" "$(jq -r '.git_sha' <<< "$before")" "$roots" || return 4
    if [[ "$ACT_REPO_LANGUAGE" == "rust" ]]; then
        dependency_checkouts=$(_act_release_source_dependency_checkouts_json "$tool") || return 4
        _act_validate_strict_target_cargo_source_closure "$tool" "$target" "$version" "$host" \
            "$(jq -r --arg host "$host" '.[$host]' <<< "$roots")" \
            "$dependency_checkouts" || return 4
    fi
    source_inventory=$(_act_relocation_source_inventory "$tool" "$(jq -r '.git_sha' <<< "$before")") || return 4
    [[ "$(_act_sha256 "$config_file")" == "$repo_hash" &&
       "$(_act_sha256 "$hosts_file")" == "$hosts_hash" &&
       "$(_act_sha256 "$prior_result")" == "$result_hash" &&
       "$(_act_sha256 "$prior_log")" == "$log_hash" ]] || return 4
    receipt=$(jq -cn --arg target "$target" --arg old "$old_host" --arg new "$host" --arg host_platform "$host_platform" \
        --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg repo_hash "$repo_hash" \
        --arg hosts_hash "$hosts_hash" --arg result_hash "$result_hash" --arg log_hash "$log_hash" \
        --argjson prior "$before" --argjson sync "$sync_json" '
        {target: $target, old_host: $old, new_host: $new, new_host_platform: $host_platform, at: $now,
         git_sha: $prior.git_sha, git_ref: $prior.git_ref,
         prior_target: $prior.target_statuses[$target], prior_context: $prior.context,
         repo_config_sha256: $repo_hash, hosts_config_sha256: $hosts_hash,
         prior_result_sha256: $result_hash, prior_log_sha256: $log_hash,
         verified_source_sync: $sync}') || return 4
    receipt=$(jq -c --argjson approval "$approval" --argjson old "$prior_json" --argjson new "$current_json" \
        --argjson inventory "$source_inventory" \
        --arg target "$target" '. + {approval: $approval,
          verified_source_inventory: $inventory,
          configuration_delta: {prior: $old.cross_compile[$target], replacement: $new.cross_compile[$target],
            prior_host: $old.hosts[$target], replacement_host: $new.hosts[$target]}}' \
        <<< "$receipt") || return 4
    build_state_relocate_failed_target "$tool" "$version" "$run_id" "$before" \
        "$target" "$host" "$roots" "$receipt" || return 4
    build_state_get "$tool" "$version" "$run_id"
}

# Ordinary synchronization selects the hosts and paths a build may use. It is
# not a source-content attestation: a failed transfer must never authorize a
# worker merely because an older checkout is still present at that path.
_act_validate_source_sync_receipt() {
    local receipt="$1" build_tasks="$2"
    jq -sce --argjson tasks "$build_tasks" '
      def text: type == "string" and length > 0 and (test("[[:cntrl:]]") | not);
      def host: type == "string" and test("^[A-Za-z0-9_-]+$");
      select(length == 1) | .[0] |
      . as $receipt |
      ([$tasks[] | select(.method == "native") | .platform] | unique | sort) as $native |
      select(type == "object") |
      select(.target_hosts | type == "object") |
      select((.target_hosts | keys | sort) == $native) |
      select(all(.target_hosts[]; host)) |
      ([.target_hosts[]] | unique | sort) as $expected |
      select(.hosts | type == "array") |
      select(all(.hosts[]; type == "object" and (.host | host) and (.path | text) and
        (.status == "success" or .status == "failed") and
        (if has("error") then .error | type == "string" else true end))) |
      select(([.hosts[].host] | sort) == $expected) |
      select(.source_roots | type == "object") |
      select(all(.source_roots[]; text)) |
      select(.source_roots == ([.hosts[] | select(.status == "success") |
        {key:.host, value:.path}] | from_entries)) |
      ([.hosts[] | select(.status == "success")] | length) as $success |
      ([.hosts[] | select(.status == "failed")] | length) as $failed |
      select(.synced == $success and (.failed // 0) == $failed) |
      select(if ($expected | length) == 0 then .status == "skipped"
        elif $failed == 0 then .status == "success"
        elif $success == 0 then .status == "failed"
        else .status == "partial" end) |
      $receipt
    ' <<< "$receipt"
}

act_orchestrate_build() {
    local tool_name="$1"
    local version="$2"
    shift 2
    local targets_arg=()
    local supplied_git_sha="" supplied_git_ref=""
    local supplied_run_id="" source_roots_json="{}"
    local target_hosts_json='{}'
    local source_sync_json="" source_sync_supplied=false no_source_sync_gate=false
    local parallel_jobs=1 resume_run=false supplied_output_dir=""
    local resume_target_host=""
    local resume_target_host_approval=""
    local build_purpose="release"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --diagnostic-native)
                build_purpose="diagnostic-native"
                shift
                ;;
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
            --target-hosts-json)
                [[ $# -ge 2 ]] || { _log_error "--target-hosts-json requires a value"; return 4; }
                target_hosts_json="$2"
                shift 2
                ;;
            --source-sync-json)
                [[ $# -ge 2 && "$source_sync_supplied" == false ]] || { _log_error "--source-sync-json requires one receipt"; return 4; }
                source_sync_json="$2"
                source_sync_supplied=true
                shift 2
                ;;
            --no-source-sync-gate)
                no_source_sync_gate=true
                shift
                ;;
            --parallel-jobs)
                [[ $# -ge 2 ]] || { _log_error "--parallel-jobs requires a value"; return 4; }
                parallel_jobs="$2"
                shift 2
                ;;
            --resume-run-id)
                [[ $# -ge 2 ]] || { _log_error "--resume-run-id requires a value"; return 4; }
                supplied_run_id="$2"
                resume_run=true
                shift 2
                ;;
            --resume-target-host)
                [[ $# -ge 2 && -z "$resume_target_host" ]] || return 4
                resume_target_host="$2"
                shift 2
                ;;
            --resume-target-host-approval)
                [[ $# -ge 2 && -z "$resume_target_host_approval" ]] || return 4
                resume_target_host_approval="$2"
                shift 2
                ;;
            --output-dir)
                [[ $# -ge 2 ]] || { _log_error "--output-dir requires a value"; return 4; }
                supplied_output_dir="$2"
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

    if [[ ! "$parallel_jobs" =~ ^[1-9][0-9]*$ ]] || \
       [[ "$parallel_jobs" -gt 32 ]]; then
        _log_error "Parallel job count must be an integer from 1 through 32"
        return 4
    fi
    if $resume_run && ! _act_is_uuid "$supplied_run_id"; then
        _log_error "--resume-run-id requires a schema-valid UUID"
        return 4
    fi
    if [[ -n "$resume_target_host" || -n "$resume_target_host_approval" ]]; then
        if ! $resume_run || [[ "$build_purpose" != "release" ||
             -z "$resume_target_host" || -z "$resume_target_host_approval" ]]; then
            return 4
        fi
    fi

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
    if [[ "$build_purpose" == "diagnostic-native" ]] && \
       { ! $strict_release_contract || [[ ${#targets_arg[@]} -eq 0 ]]; }; then
        _log_error "Diagnostic native builds require a strict contract and explicit native targets"
        return 4
    fi

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

    local requested_targets_json
    requested_targets_json=$(for target in $targets; do printf '%s\n' "$target"; done | \
        jq -Rsc 'split("\n") | map(select(length > 0))')
    if ! jq -en --argjson requested "$requested_targets_json" \
        '($requested | length) == ($requested | unique | length)' >/dev/null 2>&1; then
        _log_error "Duplicate build targets are not allowed"
        jq -nc --arg tool "$tool_name" --arg error "Duplicate build targets are not allowed" \
            '{tool: $tool, status: "error", summary: {total: 0, success: 0, failed: 0}, error: $error, targets: []}'
        return 4
    fi

    if $strict_release_contract; then
        if ! _act_contract_for_build_purpose "$tool_name" "$release_contract_json" \
            "$requested_targets_json" "$build_purpose" >/dev/null; then
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

    local build_tasks_json native_matrix_config_sha256=""
    if ! build_tasks_json=$(_act_build_task_plan "$tool_name" "$version" \
        "$requested_targets_json" "$strict_release_contract"); then
        _log_error "Native build task plan is invalid"
        return 4
    fi
    if jq -e 'any(.[]; .key != .platform)' <<< "$build_tasks_json" >/dev/null; then
        native_matrix_config_sha256=$(_act_sha256 "$ACT_REPOS_DIR/${tool_name}.yaml") || return 4
        [[ "$native_matrix_config_sha256" =~ ^[0-9a-f]{64}$ ]] || return 4
    fi

    if $no_source_sync_gate && { $strict_release_contract || $source_sync_supplied; }; then
        _log_error "Source synchronization opt-out cannot accompany a receipt or strict release"
        return 4
    fi
    if $source_sync_supplied; then
        if $strict_release_contract ||
           ! source_sync_json=$(_act_validate_source_sync_receipt "$source_sync_json" "$build_tasks_json"); then
            _log_error "Invalid or incomplete ordinary source synchronization receipt"
            return 4
        fi
        if { [[ "$target_hosts_json" != '{}' ]] &&
             [[ "$(jq -cS . <<< "$target_hosts_json")" != "$(jq -cS '.target_hosts' <<< "$source_sync_json")" ]]; } ||
           { [[ "$source_roots_json" != '{}' ]] &&
             [[ "$(jq -cS . <<< "$source_roots_json")" != "$(jq -cS '.source_roots' <<< "$source_sync_json")" ]]; }; then
            _log_error "Source synchronization receipt conflicts with explicit host or path bindings"
            return 4
        fi
        target_hosts_json=$(jq -c '.target_hosts' <<< "$source_sync_json") || return 4
        source_roots_json=$(jq -c '.source_roots' <<< "$source_sync_json") || return 4
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

        # Source synchronization is the host-selection authority. Re-running
        # the capacity selector here or in workers can select an unsynced host.
        local expected_native_hosts_json actual_source_hosts_json requested_host_targets
        # shellcheck disable=SC2086  # one configured target per word
        requested_host_targets=$(printf '%s\n' $targets | jq -Rsc 'split("\n") | map(select(length > 0)) | sort')
        if ! expected_native_hosts_json=$(jq -ce --argjson targets "$requested_host_targets" '
            if type == "object" and (keys | sort) == $targets and
               all(.[]; type == "string" and test("^[A-Za-z0-9_-]+$"))
            then [.[]] | unique | sort else error("invalid target host bindings") end
        ' <<< "$target_hosts_json"); then
            _log_error "Missing or invalid strict target host bindings"
            jq -nc --arg tool "$tool_name" \
                '{tool: $tool, status: "error", summary: {total: 0, success: 0, failed: 0}, error: "Missing or invalid strict target host bindings", targets: []}'
            return 4
        fi
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
                "$configured_host_path" "$tool_name" "$supplied_run_id" "$source_host"); then
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
            # A failed host need not remain reachable to replace it. The
            # locked transition below verifies the replacement's complete
            # source and Cargo closure before changing state. Still validate
            # this host when any other target retains its source authority.
            if [[ -n "$resume_target_host" ]] && jq -en \
                --argjson hosts "$target_hosts_json" --arg host "$source_host" \
                --arg target "${resume_target_host%%=*}" \
                '[$hosts | to_entries[] | select(.value == $host) | .key] == [$target]' >/dev/null; then
                continue
            fi
            if [[ "$ACT_REPO_LANGUAGE" == "rust" ]]; then
                local metadata_target
                while IFS= read -r metadata_target; do
                    if ! _act_validate_strict_target_cargo_source_closure \
                            "$tool_name" "$metadata_target" "$version" "$source_host" \
                            "$actual_source_root" "$source_dependency_checkouts_json"; then
                        _log_error "Strict Cargo source closure validation failed for $metadata_target on $source_host"
                        jq -nc --arg tool "$tool_name" --arg error "Cargo source closure does not match pinned dependencies" \
                            '{tool: $tool, status: "error", summary: {total: 0, success: 0, failed: 0}, error: $error, targets: []}'
                        return 4
                    fi
                done < <(jq -r --arg host "$source_host" \
                    'to_entries[] | select(.value == $host) | .key' <<< "$target_hosts_json")
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

    # Initialize or reopen build state. Shared JSON is written only by this
    # parent process; workers communicate through immutable result sidecars.
    local run_id requested_run_id="${supplied_run_id:-${DSR_RUN_ID:-}}"
    local lock_acquired_here=false caller_holds_lock=false state_available=false
    [[ "${DSR_BUILD_LOCK_HELD_BY_CALLER:-0}" == "1" ]] && caller_holds_lock=true

    _act_release_orchestration_lock() {
        if $lock_acquired_here; then
            build_lock_release "$tool_name" "$version" >/dev/null 2>&1 || true
            lock_acquired_here=false
        fi
    }

    if ! _act_is_uuid "$requested_run_id"; then
        if $resume_run || ! requested_run_id=$(_act_generate_uuid); then
            _log_error "Unable to obtain a schema-valid build run UUID"
            jq -nc --arg tool "$tool_name" --arg error "Invalid build run UUID" \
                '{tool: $tool, status: "error", summary: {total: 0, success: 0, failed: 0}, error: $error, targets: []}'
            return 4
        fi
    fi
    if [[ "$build_purpose" == "diagnostic-native" ]]; then
        local diagnostic_output="${DSR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsr}/diagnostics/${tool_name}-v${version#v}/$requested_run_id"
        if [[ "$supplied_output_dir" != "$diagnostic_output" ]]; then
            _log_error "Diagnostic orchestration requires its run-bound private output namespace"
            return 4
        fi
    fi

    if command -v build_state_create &>/dev/null; then
        # build_state_create is captured below, so any initialization it did
        # inside that command-substitution subshell would not persist here.
        # Initialize explicitly in the coordinator before resolving paths or
        # attempting state transitions.
        if ! build_state_init; then
            _log_error "Build state initialization failed"
            return 4
        fi
        state_available=true
        if $caller_holds_lock; then
            _log_info "Using caller-owned build lock for $tool_name $version"
        elif ! DSR_RUN_ID="$requested_run_id" build_lock_acquire "$tool_name" "$version"; then
            _log_error "Build already in progress (lock held)"
            jq -nc --arg tool "$tool_name" --arg error "Build already in progress (lock held)" \
                '{tool: $tool, status: "error", summary: {total: 0, success: 0, failed: 0}, error: $error, targets: []}'
            return 2
        else
            lock_acquired_here=true
        fi

        if $resume_run; then
            local resume_state resume_requested_targets_json
            if ! resume_state=$(build_state_get "$tool_name" "$version" "$requested_run_id" 2>/dev/null); then
                _log_error "Resume state not found for run $requested_run_id"
                _act_release_orchestration_lock
                return 4
            fi
            # Once a relocation pins reviewed configuration, an ordinary
            # subsequent retry must not silently run a different command or
            # alter the completed targets' configuration.
            if [[ -z "$resume_target_host" ]] && jq -e '(.relocations // [] | length) > 0' \
                <<< "$resume_state" >/dev/null; then
                if [[ "$(_act_sha256 "$ACT_REPOS_DIR/${tool_name}.yaml")" != \
                      "$(jq -r '.relocations[-1].repo_config_sha256' <<< "$resume_state")" ||
                      "$(_act_sha256 "${DSR_CONFIG_DIR:-$HOME/.config/dsr}/hosts.yaml")" != \
                      "$(jq -r '.relocations[-1].hosts_config_sha256' <<< "$resume_state")" ]]; then
                    _log_error "Configuration changed after the approved relocation"
                    _act_release_orchestration_lock
                    return 4
                fi
            fi
            if ! _act_build_purpose_matches "$(jq -c '.context // {}' <<< "$resume_state")" \
                "$build_purpose" "$strict_release_contract"; then
                _log_error "Resume build purpose is missing or differs from this request"
                _act_release_orchestration_lock
                return 4
            fi
            # Inspect both authorities before admitting any resumed worker.
            # A valid embedded result cannot launder a differently purposed sidecar.
            local resume_entry resume_receipt resume_result_path
            while IFS= read -r resume_entry; do
                resume_receipt=$(jq -c '.result // empty' <<< "$resume_entry")
                if [[ -n "$resume_receipt" ]] && \
                   ! _act_build_purpose_matches "$resume_receipt" "$build_purpose" "$strict_release_contract"; then
                    _log_error "Resume target result has missing or different build purpose"
                    _act_release_orchestration_lock
                    return 4
                fi
                resume_result_path=$(jq -r '.result_path // empty' <<< "$resume_entry")
                if [[ -n "$resume_result_path" && -s "$resume_result_path" ]]; then
                    if ! resume_receipt=$(jq -ce '.' "$resume_result_path") || \
                       ! _act_build_purpose_matches "$resume_receipt" "$build_purpose" "$strict_release_contract"; then
                        _log_error "Resume sidecar has missing or different build purpose"
                        _act_release_orchestration_lock
                        return 4
                    fi
                fi
            done < <(jq -c '.target_statuses[]?' <<< "$resume_state")
            resume_requested_targets_json=$(for target in $targets; do printf '%s\n' "$target"; done | \
                jq -Rsc 'split("\n") | map(select(length > 0))')
            if ! jq -en --argjson state "$resume_state" --arg run_id "$requested_run_id" \
                --argjson requested "$resume_requested_targets_json" \
                '$state.run_id == $run_id and $state.targets == $requested and
                 ($state.status != "completed" and $state.status != "cancelled")' >/dev/null 2>&1; then
                _log_error "Resume state target set or status does not match this request"
                _act_release_orchestration_lock
                return 4
            fi
            if [[ "$(jq -cS '.context.build_tasks // null' <<< "$resume_state")" != \
                  "$(jq -cS . <<< "$build_tasks_json")" ]] || \
               [[ "$(jq -r '.context.native_matrix_config_sha256 // ""' <<< "$resume_state")" != \
                  "$native_matrix_config_sha256" ]]; then
                _log_error "Resume build task plan or native matrix configuration changed"
                _act_release_orchestration_lock
                return 4
            fi
            if [[ -n "$git_sha" && "$(jq -r '.git_sha // empty' <<< "$resume_state")" != "$git_sha" ]] || \
               [[ -n "$git_ref" && "$(jq -r '.git_ref // empty' <<< "$resume_state")" != "$git_ref" ]] || \
               { [[ -n "$supplied_output_dir" ]] && \
                 [[ "$(jq -r '.context.output_dir // empty' <<< "$resume_state")" != "$supplied_output_dir" ]]; }; then
                _log_error "Resume state is bound to different source or output inputs"
                _act_release_orchestration_lock
                return 4
            fi
            if $strict_release_contract && \
               [[ "$(jq -cS '.context.source_roots // {}' <<< "$resume_state")" != \
                  "$(jq -c -S '.' <<< "$source_roots_json")" ]]; then
                _log_error "Resume state source roots do not match the strict snapshot"
                _act_release_orchestration_lock
                return 4
            fi
            if $strict_release_contract && \
               [[ "$(jq -cS '.context.target_hosts // {}' <<< "$resume_state")" != \
                  "$(jq -cS '.' <<< "$target_hosts_json")" ]]; then
                _log_error "Resume target hosts do not match the strict snapshot"
                _act_release_orchestration_lock
                return 4
            fi
            run_id="$requested_run_id"
            if [[ -n "$resume_target_host" ]]; then
                if ! $strict_release_contract ||
                   ! resume_state=$(_act_relocate_failed_target "$tool_name" "$version" \
                        "$run_id" "$resume_state" "$resume_target_host" "$resume_target_host_approval"); then
                    _log_error "Failed-target relocation refused; prior attempts retained"
                    _act_release_orchestration_lock
                    return 4
                fi
                source_roots_json=$(jq -c '.context.source_roots' <<< "$resume_state")
                target_hosts_json=$(jq -c '.context.target_hosts' <<< "$resume_state")
            fi
            if ! $strict_release_contract; then
                if ! $source_sync_supplied; then
                    # A retry uses the original source locations unless a new
                    # complete synchronization receipt selects replacements.
                    if ! target_hosts_json=$(jq -c '.context.target_hosts // {}' <<< "$resume_state") ||
                       ! source_roots_json=$(jq -c '.context.source_roots // {}' <<< "$resume_state"); then
                        _act_release_orchestration_lock
                        return 4
                    fi
                    if ! $no_source_sync_gate; then
                        if ! source_sync_json=$(jq -c '.context.source_sync // null' <<< "$resume_state"); then
                            _act_release_orchestration_lock
                            return 4
                        fi
                        if [[ "$source_sync_json" == null ]]; then
                            source_sync_json=""
                        elif ! source_sync_json=$(_act_validate_source_sync_receipt "$source_sync_json" "$build_tasks_json") ||
                             [[ "$(jq -cS '.target_hosts' <<< "$source_sync_json")" != "$(jq -cS . <<< "$target_hosts_json")" ]] ||
                             [[ "$(jq -cS '.source_roots' <<< "$source_sync_json")" != "$(jq -cS . <<< "$source_roots_json")" ]]; then
                            _log_error "Saved source synchronization receipt or bindings are invalid"
                            _act_release_orchestration_lock
                            return 4
                        fi
                    fi
                fi
                if $source_sync_supplied || $no_source_sync_gate; then
                    if ! build_state_set_source_sync "$tool_name" "$version" "$run_id" \
                        "${source_sync_json:-null}" "$source_roots_json" "$target_hosts_json"; then
                        _log_error "Could not retain resumed source synchronization context"
                        _act_release_orchestration_lock
                        return 4
                    fi
                fi
            fi
        else
            if [[ -n "$resume_target_host" ]]; then
                _act_release_orchestration_lock
                return 4
            fi
            if ! run_id=$(DSR_RUN_ID="$requested_run_id" \
                build_state_create "$tool_name" "$version" "${targets// /,}") || \
               [[ "$run_id" != "$requested_run_id" ]] || ! _act_is_uuid "$run_id" || \
                ! build_state_set_context "$tool_name" "$version" "$run_id" \
                    "$git_sha" "$git_ref" "$source_roots_json" "$supplied_output_dir" "$parallel_jobs" \
                    "$target_hosts_json" "$build_purpose" "$build_tasks_json" "$native_matrix_config_sha256" \
                    "${source_sync_json:-null}"; then
                _log_error "Build state could not retain the run context"
                _act_release_orchestration_lock
                return 4
            fi
        fi
        if ! build_state_update_status "$tool_name" "$version" "running" "$run_id"; then
            _act_release_orchestration_lock
            return 4
        fi
    elif $resume_run; then
        _log_error "Resume requires the build state module"
        return 4
    else
        run_id="$requested_run_id"
    fi

    _log_info "Run ID: $run_id"
    _log_info "Target concurrency: $parallel_jobs"

    local workspace
    if $state_available; then
        if ! workspace=$(build_state_workspace "$tool_name" "$version" "$run_id"); then
            _act_release_orchestration_lock
            return 4
        fi
    else
        workspace="${DSR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsr}/builds/$tool_name/$version/$run_id"
        mkdir -p "$workspace/logs" "$workspace/results"
    fi
    if [[ ! -d "$workspace/logs" || -L "$workspace/logs" || \
          ! -d "$workspace/results" || -L "$workspace/results" ]]; then
        _log_error "Build receipt directories are missing or unsafe"
        _act_release_orchestration_lock
        return 4
    fi

    local results=() success_count=0 fail_count=0 interrupted=false
    local start_time target_index=0
    start_time=$(date +%s)
    local -a worker_pids=() worker_targets=() worker_platforms=() worker_triples=()
    local -a worker_results=() worker_logs=() worker_hosts=() worker_attempts=()
    local -a worker_output_paths=()
    local active_workers=0
    declare -A final_results=() worker_reaped=()

    # Print the first still-running target on <host> that writes any of the
    # output paths in <paths> (lines from _act_native_output_paths).
    _act_active_output_conflict() {
        local conflict_host="$1" conflict_paths="$2" conflict_index path
        [[ -n "$conflict_paths" ]] || return 0
        for ((conflict_index = 0; conflict_index < ${#worker_pids[@]}; conflict_index++)); do
            [[ -z "${worker_reaped[$conflict_index]:-}" ]] || continue
            [[ "${worker_hosts[$conflict_index]}" == "$conflict_host" ]] || continue
            [[ -n "${worker_output_paths[$conflict_index]}" ]] || continue
            while IFS= read -r path; do
                [[ -n "$path" ]] || continue
                if grep -Fxq -- "${path#*$'\t'}" <<< "$(cut -f2- <<< "${worker_output_paths[$conflict_index]}")"; then
                    printf '%s\n' "${worker_targets[$conflict_index]}"
                    return 0
                fi
            done <<< "$conflict_paths"
        done
        return 0
    }

    _act_record_worker_result() {
        local index="$1" worker_status="$2"
        local finished_target="${worker_targets[$index]}"
        local finished_platform="${worker_platforms[$index]}" finished_triple="${worker_triples[$index]}"
        local result_path="${worker_results[$index]}" log_path="${worker_logs[$index]}"
        local host="${worker_hosts[$index]}" attempt="${worker_attempts[$index]}"
        local finished_result status extra
        if [[ -s "$result_path" ]] && finished_result=$(jq -ce '.' "$result_path" 2>/dev/null); then
            if ! _act_build_purpose_matches "$finished_result" "$build_purpose" true; then
                finished_result=$(jq -nc --arg target "$finished_platform" --arg host "$host" \
                    '{platform: $target, host: $host, status: "failed", exit_code: 4,
                      error: "Worker result purpose is missing or inconsistent"}')
            fi
        else
            finished_result=$(jq -nc --arg target "$finished_platform" --arg host "$host" \
                --argjson exit_code "$worker_status" \
                '{platform: $target, host: $host, status: "failed", exit_code: $exit_code,
                  error: "Worker result receipt missing or invalid"}')
        fi
        if [[ "$(jq -r '.status // ""' <<< "$finished_result")" == success ]] && \
           ! _act_matrix_result_matches "$finished_result" "$finished_platform" "$finished_triple"; then
            finished_result=$(jq -c '.status = "failed" | .exit_code = 4 |
                .error = "Completed native result has inconsistent variant identity"' <<< "$finished_result") || return 4
        fi
        finished_result=$(jq -c --arg log_path "$log_path" --arg result_path "$result_path" \
            --argjson attempt "$attempt" \
            --arg purpose "$build_purpose" --arg task_key "$finished_target" \
            '. + {log_path: $log_path, result_path: $result_path, attempt: $attempt,
                  build_purpose: $purpose, publishable: ($purpose == "release"), task_key:$task_key}' \
            <<< "$finished_result")
        final_results["$finished_target"]="$finished_result"
        status=$(jq -r '.status // "unknown"' <<< "$finished_result")

        if $state_available; then
            extra=$(jq -nc --argjson result "$finished_result" --arg host "$host" \
                --arg log_path "$log_path" --arg result_path "$result_path" \
                --argjson attempts "$attempt" \
                '{result: $result, host: $host, log_path: $log_path,
                  result_path: $result_path, attempts: $attempts}')
            if [[ "$status" == "success" ]]; then
                build_state_update_target "$tool_name" "$version" "$finished_target" \
                    "completed" "$extra" "$run_id" || return 4
                build_state_update_host "$tool_name" "$version" "$host" "completed" \
                    "$(jq -c --arg target "$finished_target" '{target: $target, artifact_path, duration_seconds}' \
                        <<< "$finished_result")" "$run_id" || return 4
            else
                build_state_update_target "$tool_name" "$version" "$finished_target" \
                    "failed" "$extra" "$run_id" || return 4
                build_state_update_host "$tool_name" "$version" "$host" "failed" \
                    "$(jq -c --arg target "$finished_target" \
                        '{target: $target, exit_code, error: (.error // .status)}' <<< "$finished_result")" \
                    "$run_id" || return 4
            fi
        fi
        _log_info "Result: $finished_target -> $status (log: $log_path)"
        if [[ "$status" != "success" ]]; then
            tail -20 "$log_path" >&2 || true
        fi
    }

    _act_cancel_parallel_workers() {
        # A second Ctrl-C must not interrupt cleanup after workers have been
        # told to terminate; keep the coordinator alive until they are reaped.
        trap '' INT TERM
        interrupted=true
        local cancel_index cancel_pid
        for ((cancel_index = 0; cancel_index < ${#worker_pids[@]}; cancel_index++)); do
            [[ -z "${worker_reaped[$cancel_index]:-}" ]] || continue
            cancel_pid="${worker_pids[$cancel_index]}"
            kill -TERM "$cancel_pid" 2>/dev/null || true
        done
    }

    # Bash 4.0 lacks wait -n. Poll only the bounded worker set and reap the
    # first completed process, keeping the scheduler work-conserving without
    # sacrificing the project's Bash 4.0 compatibility.
    _act_reap_one_worker() {
        local reap_index reap_pid worker_status running_worker_pids
        while (( active_workers > 0 )); do
            # The shell job table is authoritative here.  kill -0 is not: a
            # completed, unreaped child (or an unrelated process that reused
            # its PID) can still answer kill -0 and strand this loop forever.
            running_worker_pids=$(jobs -pr)
            for ((reap_index = 0; reap_index < ${#worker_pids[@]}; reap_index++)); do
                [[ -z "${worker_reaped[$reap_index]:-}" ]] || continue
                reap_pid="${worker_pids[$reap_index]}"
                if ! grep -Fqx "$reap_pid" <<< "$running_worker_pids"; then
                    worker_status=0
                    wait "$reap_pid" || worker_status=$?
                    worker_reaped["$reap_index"]=1
                    active_workers=$((active_workers - 1))
                    _act_record_worker_result "$reap_index" "$worker_status" || interrupted=true
                    return 0
                fi
            done
            sleep 0.05
        done
        return 1
    }
    trap _act_cancel_parallel_workers INT TERM

    local task_json task_key selected_triple
    while IFS= read -r task_json; do
        target=$(jq -r '.platform' <<< "$task_json")
        task_key=$(jq -r '.key' <<< "$task_json")
        selected_triple=""
        [[ "$task_key" == "$target" ]] || selected_triple=$(jq -r '.target_triple' <<< "$task_json")
        $interrupted && break
        target_index=$((target_index + 1))
        local persisted_entry='{}' persisted_result="" persisted_result_path=""
        local prior_attempts=0 prior_build_attempts=0
        if $state_available; then
            persisted_entry=$(build_state_get "$tool_name" "$version" "$run_id" | \
                jq -c --arg target "$task_key" '.target_statuses[$target] // {}')
            prior_attempts=$(jq -r '.attempts // 0' <<< "$persisted_entry")
            if ! prior_build_attempts=$(jq -er '
                (.attempts // 0) as $all | (.source_sync_failures // 0) as $sync |
                select(($all | type == "number" and floor == . and . >= 0 and . <= 9007199254740991) and
                  ($sync | type == "number" and floor == . and . >= 0 and . <= 9007199254740991) and $sync <= $all) |
                $all - $sync' <<< "$persisted_entry"); then
                _log_error "Invalid source synchronization/build attempt counters for $task_key"
                interrupted=true
                break
            fi
            persisted_result=$(jq -c '.result // empty' <<< "$persisted_entry")
            persisted_result_path=$(jq -r '.result_path // empty' <<< "$persisted_entry")
        fi

        if $resume_run; then
            if [[ -n "$persisted_result" ]] && \
               ! _act_build_purpose_matches "$persisted_result" "$build_purpose" "$strict_release_contract"; then
                _log_error "Resume target result has missing or different build purpose: $target"
                interrupted=true
                break
            fi
            if [[ -n "$persisted_result" ]] && \
               _act_matrix_result_matches "$persisted_result" "$target" "$selected_triple" && \
               [[ "$(jq -r '.task_key // ""' <<< "$persisted_result")" == "$task_key" ]] && \
               _act_target_result_available "$persisted_result" "$build_purpose" "$strict_release_contract"; then
                final_results["$task_key"]=$(jq -c '. + {resume_reused: true}' <<< "$persisted_result")
                _log_info "Resume: reusing completed target $task_key"
                continue
            fi
            if [[ -n "$persisted_result_path" && -s "$persisted_result_path" ]] && \
               persisted_result=$(jq -ce '.' "$persisted_result_path" 2>/dev/null); then
                if ! _act_build_purpose_matches "$persisted_result" "$build_purpose" "$strict_release_contract"; then
                    _log_error "Resume sidecar has missing or different build purpose: $target"
                    interrupted=true
                    break
                fi
            fi
            if [[ -n "$persisted_result_path" && -s "$persisted_result_path" ]] && \
               _act_matrix_result_matches "$persisted_result" "$target" "$selected_triple" && \
               [[ "$(jq -r '.task_key // ""' <<< "$persisted_result")" == "$task_key" ]] && \
               _act_target_result_available "$persisted_result" "$build_purpose" "$strict_release_contract"; then
                final_results["$task_key"]=$(jq -c '. + {resume_reused: true}' <<< "$persisted_result")
                if $state_available; then
                    if ! build_state_update_target "$tool_name" "$version" "$task_key" "completed" \
                        "$(jq -nc --argjson result "${final_results[$task_key]}" \
                            --argjson attempts "$prior_attempts" \
                            '{result: $result, attempts: $attempts, reconciled_from_sidecar: true}')" \
                        "$run_id"; then
                        interrupted=true
                        break
                    fi
                fi
                _log_info "Resume: reconciled completed sidecar for $task_key"
                continue
            fi
            if [[ "$(jq -r '.status // "pending"' <<< "$persisted_entry")" == "failed" && \
                  "$prior_build_attempts" -ge "${BUILD_RETRY_MAX:-3}" ]]; then
                final_results["$task_key"]=$(jq -c \
                    '.result // {platform: "'"$target"'", status: "failed", exit_code: 6,
                     error: "Target retry limit exceeded"}' <<< "$persisted_entry")
                _log_warn "Resume: retry limit exceeded for $target"
                continue
            fi
        fi

        local attempt=$((prior_attempts + 1)) target_slug index_prefix log_path result_path host
        target_slug="${task_key//\//-}"
        printf -v index_prefix '%03d' "$target_index"
        log_path="$workspace/logs/${index_prefix}-${target_slug}.attempt-${attempt}.log"
        result_path="$workspace/results/${index_prefix}-${target_slug}.attempt-${attempt}.json"
        if [[ -e "$log_path" || -L "$log_path" || -e "$result_path" || -L "$result_path" ]]; then
            _log_error "Refusing to overwrite an existing target attempt receipt"
            interrupted=true
            break
        fi
        if ! (umask 077; set -o noclobber; : > "$log_path"); then
            _log_error "Could not create immutable target log receipt: $log_path"
            interrupted=true
            break
        fi
        host="act-local"
        if $strict_release_contract; then
            host=$(jq -er --arg target "$target" '.[$target]' <<< "$target_hosts_json") || return 4
        elif ! act_platform_uses_act "$tool_name" "$target"; then
            # Build where the source was synced. Asking the capacity selector
            # again could pick a busier-now host that was never synced and
            # would compile whatever stale tree it holds.
            host=$(jq -r --arg target "$target" '.[$target] // empty' <<< "$target_hosts_json" 2>/dev/null)
            [[ -n "$host" ]] || host=$(act_get_native_host "$target" "$tool_name")
        fi
        local target_sync_receipt=null
        if [[ -n "$source_sync_json" ]] && ! act_platform_uses_act "$tool_name" "$target"; then
            target_sync_receipt=$(jq -ce --arg host "$host" '.hosts[] | select(.host == $host)' \
                <<< "$source_sync_json") || { interrupted=true; break; }
        fi

        # Two concurrent targets on one host whose builds write the same file
        # (`go build -o ntm` in one source tree) would collect each other's
        # binaries. Give this target a private source copy when that makes
        # the shared path its own; otherwise (strict snapshots, Windows hosts,
        # outputs outside the tree) wait until the conflicting build is done.
        local output_paths="" output_stage=0 output_conflict=""
        if (( parallel_jobs > 1 )) &&
           { [[ "$target_sync_receipt" == null ]] || [[ "$(jq -r '.status' <<< "$target_sync_receipt")" == success ]]; }; then
            output_paths=$(_act_native_output_paths "$tool_name" "$target" "$host" \
                "$strict_release_contract" "$source_roots_json")
            output_conflict=$(_act_active_output_conflict "$host" "$output_paths")
            if [[ -n "$output_conflict" ]]; then
                if ! $strict_release_contract && ! _act_is_windows_host "$host" && \
                   ! grep -q '^external' <<< "$output_paths"; then
                    output_stage=1
                    output_paths=""
                    _log_info "Target $target shares its output path on $host with $output_conflict; building it in a private source copy"
                else
                    _log_info "Target $target shares its output path on $host with $output_conflict; waiting for that build to finish"
                    while [[ -n "$(_act_active_output_conflict "$host" "$output_paths")" ]]; do
                        _act_reap_one_worker || { interrupted=true; break; }
                    done
                    $interrupted && break
                fi
            fi
        fi

        if $state_available; then
            if ! build_state_update_target "$tool_name" "$version" "$task_key" "running" \
                "$(jq -nc --arg host "$host" --arg log_path "$log_path" \
                    --arg result_path "$result_path" --argjson attempts "$attempt" \
                    '{host: $host, log_path: $log_path, result_path: $result_path,
                      attempts: $attempts, result: null}')" "$run_id" || \
               ! build_state_update_host "$tool_name" "$version" "$host" "running" \
                    "$(jq -nc --arg target "$target" '{target: $target}')" "$run_id"; then
                _log_error "Could not persist running state for target $target"
                interrupted=true
                break
            fi
        fi

        DSR_NATIVE_OUTPUT_STAGE="$output_stage" \
        _act_run_target_worker "$tool_name" "$version" "$run_id" "$target" "$attempt" \
            "$log_path" "$result_path" "$strict_release_contract" \
            "$release_contract_json" "$source_roots_json" "$git_sha" "$git_ref" "$host" "$build_purpose" \
            "$selected_triple" "$task_key" "$target_sync_receipt" &
        worker_pids+=("$!")
        worker_output_paths+=("$output_paths")
        worker_targets+=("$task_key")
        worker_platforms+=("$target")
        worker_triples+=("$selected_triple")
        worker_results+=("$result_path")
        worker_logs+=("$log_path")
        worker_hosts+=("$host")
        worker_attempts+=("$attempt")
        active_workers=$((active_workers + 1))

        if (( active_workers >= parallel_jobs )); then
            _act_reap_one_worker || interrupted=true
            $interrupted && break
        fi
    done < <(jq -c '.[]' <<< "$build_tasks_json")

    while (( active_workers > 0 )); do
        _act_reap_one_worker || interrupted=true
    done
    trap - INT TERM

    # Deterministic aggregation follows configured target order, never worker
    # completion order.
    while IFS= read -r task_json; do
        target=$(jq -r '.platform' <<< "$task_json")
        task_key=$(jq -r '.key' <<< "$task_json")
        selected_triple=""
        [[ "$task_key" == "$target" ]] || selected_triple=$(jq -r '.target_triple' <<< "$task_json")
        local ordered_result="${final_results[$task_key]:-}"
        if [[ -z "$ordered_result" && $state_available == true ]]; then
            ordered_result=$(build_state_get "$tool_name" "$version" "$run_id" | \
                jq -c --arg target "$target" --arg task_key "$task_key" \
                    '.target_statuses[$task_key].result // {platform: $target, status: "failed",
                     exit_code: 6, error: "No target result"}')
        fi
        if [[ -z "$ordered_result" ]]; then
            ordered_result=$(jq -nc --arg target "$target" \
                '{platform: $target, status: "failed", exit_code: 6, error: "No target result"}')
        fi
        if [[ "$(jq -r '.status // empty' <<< "$ordered_result")" == "success" ]] && \
           { ! _act_build_purpose_matches "$ordered_result" "$build_purpose" "$strict_release_contract" || \
             ! _act_matrix_result_matches "$ordered_result" "$target" "$selected_triple"; }; then
            ordered_result=$(jq -c '.status = "failed" | .exit_code = 4 |
                .error = "Target purpose failed final aggregation"' <<< "$ordered_result") || return 4
        fi
        ordered_result=$(jq -c --arg purpose "$build_purpose" --arg task_key "$task_key" \
            '. + {build_purpose: $purpose, publishable: ($purpose == "release"), task_key:$task_key}' \
            <<< "$ordered_result") || return 4
        results+=("$ordered_result")
        if [[ "$(jq -r '.status // "unknown"' <<< "$ordered_result")" == "success" ]]; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
    done < <(jq -c '.[]' <<< "$build_tasks_json")

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
    if $interrupted; then
        overall_status="failed"
        overall_exit_code=130
    elif $source_validation_failed; then
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
        local persisted_status="$overall_status"
        [[ "$overall_status" == "success" ]] && persisted_status="targets-complete"
        if ! build_state_update_status "$tool_name" "$version" "$persisted_status" "$run_id"; then
            overall_status="failed"
            overall_exit_code=4
        fi
    fi
    _act_release_orchestration_lock

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
        --arg purpose "$build_purpose" \
        --argjson requested_targets "$requested_targets_json" \
        --argjson source_sync "${source_sync_json:-null}" \
        '{
            tool: $tool,
            build_purpose: $purpose,
            publishable: ($purpose == "release"),
            requested_targets: $requested_targets,
            source_sync: $source_sync,
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

_act_build_environments_json() {
    local result_json="$1"

    jq -ce '
        [
            .targets[]? |
            select((.method // "") | test("^(act|native)$")) |
            {
                target: (.platform // .target // ""),
                host: (.host // ""),
                method: (.method // ""),
                build_influence_env: (.build_influence_env // {}),
                cargo_isolation: (.cargo_isolation // null)
            } + (if .target_triple == null then {} else {target_triple: .target_triple} end)
        ] | sort_by(.target, .target_triple)
        | if all(.[];
            (.target | type == "string" and length > 0) and
            (.host | type == "string") and
            (.method | type == "string" and test("^(act|native)$")) and
            (.target_triple == null or (.target_triple | type == "string" and
                test("^[A-Za-z0-9][A-Za-z0-9._+-]*$") and (contains("..") | not))) and
            (.build_influence_env | type == "object" and all(.[]; type == "string")) and
            (.cargo_isolation == null or (.cargo_isolation | type == "object"))
          ) then . else error("invalid build environment receipt") end
    ' <<< "$result_json"
}

# Native workers know the selected variant independently of the output name.
# Keep that authority at collection and manifest boundaries, including callers
# which supply retained worker results rather than running the scheduler.
_act_native_result_target_triple() {
    local tool="$1" result="$2" platform triple configured
    platform=$(jq -er '.platform | strings | select(length > 0)' <<< "$result") || return 4
    triple=$(jq -er 'if .target_triple != null then
        .target_triple | select(type == "string" and
            test("^[A-Za-z0-9][A-Za-z0-9._+-]*$") and (contains("..") | not))
        else "" end' <<< "$result") || return 4
    configured=$(config_get_target_triples_json "$tool" "$platform") || return 4
    if ! jq -en --arg triple "$triple" --argjson configured "$configured" '
        if $triple == "" then ($configured | length) <= 1
        else ($configured | length) == 0 or ($configured | index($triple)) != null end
    ' >/dev/null; then
        _log_error "Native result has no configured variant identity: $tool $platform ${triple:-<missing>}"
        return 4
    fi
    if [[ -n "$triple" ]] && ! jq -e --arg triple "$triple" '
        [.build_influence_env.CARGO_BUILD_TARGET,
         .build_influence_env.DSR_TARGET_TRIPLE,
         .cargo_isolation.toolchain.target_triple] |
        all(.[]; . == null or . == $triple)
    ' <<< "$result" >/dev/null; then
        _log_error "Native target triple contradicts its build environment: $tool $platform $triple"
        return 4
    fi
    printf '%s\n' "$triple"
}

# A successful native matrix means every configured compiler target produced
# a usable payload. Validate this again at the manifest boundary: callers may
# load retained results directly, and a missing/duplicated worker row must not
# turn a partial build into a publishable release. Workflow jobs retain their
# existing ability to collect the variants that their workflow produced.
# The optional artifact array checks the inventory after file collection.
_act_validate_native_matrix_result_inventory() {
    local tool="$1" result="$2" artifacts="${3:-null}"
    local platforms platform configured rows requested complete=false matrix=false
    [[ "$(jq -r '.status // ""' <<< "$result")" == success ]] && complete=true
    platforms=$(jq -r '
        [(.targets // [])[] | select(.method == "native") | .platform] +
        (.requested_targets // []) | unique | .[]
    ' <<< "$result") || return 4
    while IFS= read -r platform; do
        [[ -n "$platform" ]] || continue
        configured=$(config_get_target_triples_json "$tool" "$platform") || return 4
        [[ "$(jq 'length' <<< "$configured")" -gt 1 ]] || continue
        rows=$(jq -c --arg platform "$platform" '
            [.targets[]? | select(.platform == $platform and .method == "native")]
        ' <<< "$result") || return 4
        if [[ "$(jq 'length' <<< "$rows")" -eq 0 ]]; then
            requested=$(jq -r --arg platform "$platform" '(.requested_targets // []) | index($platform) != null' <<< "$result") || return 4
            [[ "$requested" == true ]] || continue
            act_platform_uses_act "$tool" "$platform" && continue
        fi
        matrix=true
        if ! jq -en --argjson rows "$rows" --argjson configured "$configured" \
            --arg platform "$platform" --argjson complete "$complete" '
                ($rows | map(.target_triple) | unique | length) == ($rows | length) and
                all($rows[];
                    (.target_triple as $triple | $configured | index($triple) != null) and
                    (if has("task_key") then .task_key == ($platform + "@" + .target_triple) else true end)) and
                (if $complete then
                    ($rows | map(.target_triple) | sort) == ($configured | sort) and
                    all($rows[]; .status == "success" or .status == "ok" or .status == "passed")
                 else true end)
            ' >/dev/null; then
            _log_error "Native matrix result is incomplete, duplicated, or inconsistent for $tool $platform"
            return 4
        fi
        if [[ "$artifacts" != null ]] && ! jq -en --argjson rows "$rows" \
            --argjson artifacts "$artifacts" --arg platform "$platform" '
                all($rows[] | select(.status == "success" or .status == "ok" or .status == "passed");
                    .target_triple as $triple |
                    any($artifacts[]; .target == $platform and .target_triple == $triple))
            ' >/dev/null; then
            _log_error "Native matrix payload is missing for $tool $platform"
            return 4
        fi
    done <<< "$platforms"
    if $matrix && $complete && ! jq -e '
        .summary.total == (.targets | length) and .summary.failed == 0 and
        .summary.success == .summary.total and
        all(.targets[]; .status == "success" or .status == "ok" or .status == "passed")
    ' <<< "$result" >/dev/null; then
        _log_error "Native matrix summary does not match its successful worker results"
        return 4
    fi
}

# A retained manifest reaches release without its original worker results.
# Reconcile its saved environment inventory with the same native matrix rules
# before any remote release mutation. These projected rows describe declared
# receipts only; they do not manufacture new execution or artifact evidence.
_act_validate_native_manifest_inventory() {
    local tool="$1" manifest="$2" inventory artifacts native_rows row
    if jq -e '.build_environments == null and .requested_targets == null' \
        <<< "$manifest" >/dev/null; then
        # Legacy native manifests can still declare their artifact variants.
        # A configured act job may emit artifacts for other platforms, so do
        # not infer native execution from artifact platforms in that case.
        local platforms platform configured configured_targets target
        platforms=$(jq -r '[.artifacts[]? | .target | strings] | unique | .[]' \
            <<< "$manifest") || return 4
        while IFS= read -r platform; do
            [[ -n "$platform" ]] || continue
            configured=$(config_get_target_triples_json "$tool" "$platform") || return 4
            [[ "$(jq 'length' <<< "$configured")" -gt 1 ]] || continue
            configured_targets=$(act_get_targets "$tool") || return 4
            for target in $configured_targets; do
                act_platform_uses_act "$tool" "$target" && return 0
            done
            if ! jq -e --arg platform "$platform" --argjson configured "$configured" '
                [.artifacts[] | select(.target == $platform) | .target_triple] as $actual |
                all($configured[]; . as $triple | ($actual | index($triple)) != null) and
                all($actual[]; . as $triple | ($configured | index($triple)) != null)
            ' <<< "$manifest" >/dev/null; then
                _log_error "Legacy manifest lacks the configured native variants for $tool $platform; rebuild its manifest"
                return 4
            fi
        done <<< "$platforms"
        return 0
    fi
    if ! inventory=$(jq -ce '
        (.build_environments // []) as $environments |
        if ($environments | type != "array") or
           (all($environments[];
               type == "object" and (.method | type == "string" and length > 0) and
               (.target | type == "string" and length > 0)) | not) or
           (.requested_targets != null and
               (.requested_targets | type != "array" or
                   (all(.[]; type == "string" and length > 0) | not)))
        then error("invalid retained build inventory")
        else {
            status: (.status // "success"),
            summary: .summary,
            targets: [$environments[] | . + {platform: .target, status: "success"}],
            requested_targets: (
                (if .requested_targets != null then .requested_targets
                 elif any($environments[]; .method != "native") then []
                 else [.artifacts[]? | .target | strings] end) |
                unique | map(. as $platform | select(
                    any($environments[]; .target == $platform and .method != "native") | not))
            )
        } end
    ' <<< "$manifest"); then
        _log_error "Release manifest has an invalid retained native inventory"
        return 4
    fi
    _act_build_environments_json "$inventory" >/dev/null || return 4
    native_rows=$(jq -c '.targets[] | select(.method == "native")' <<< "$inventory") || return 4
    while IFS= read -r row; do
        [[ -n "$row" ]] || continue
        _act_native_result_target_triple "$tool" "$row" >/dev/null || return 4
    done <<< "$native_rows"
    artifacts=$(jq -c '.artifacts' <<< "$manifest") || return 4
    _act_validate_native_matrix_result_inventory "$tool" "$inventory" "$artifacts"
}

# Flat release directories cannot retain two native payloads named `tool`.
# Both cmd_build and manifest generation use this deterministic name; the
# original paths and names remain in the immutable worker receipts.
_act_native_variant_artifact_name() {
    local tool="$1" platform="$2" triple="$3" name="$4"
    local configured variant inferred how base ext="" module_dir
    _act_is_safe_basename "$name" || return 4
    [[ -n "$triple" ]] || { printf '%s\n' "$name"; return 0; }
    if ! declare -F artifact_naming_artifact_variant &>/dev/null; then
        module_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 4
        # shellcheck source=./artifact_naming.sh
        source "$module_dir/artifact_naming.sh" || return 4
    fi
    configured=$(config_get_target_triples_json "$tool" "$platform") || return 4
    variant=$(artifact_naming_artifact_variant "$tool" "${platform%/*}" "${platform#*/}" "$name") || return 4
    IFS=$'\t' read -r inferred how <<< "$variant"
    if [[ "$how" == unknown || ( "$how" != primary && "$inferred" != "$triple" ) ]]; then
        _log_error "Native artifact name contradicts its selected variant: $name ($triple)"
        return 4
    fi
    if [[ "$how" != primary ]] || [[ $(jq 'length' <<< "$configured") -le 1 ]]; then
        printf '%s\n' "$name"
        return 0
    fi
    base="$name"
    case "$name" in
        *.tar.gz) ext=.tar.gz; base="${name%.tar.gz}" ;;
        *.tar.xz) ext=.tar.xz; base="${name%.tar.xz}" ;;
        *.tgz) ext=.tgz; base="${name%.tgz}" ;;
        *.zip) ext=.zip; base="${name%.zip}" ;;
        *.exe) ext=.exe; base="${name%.exe}" ;;
        *.minisig|*.sha256|*.sha512|*.sig)
            ext=".${name##*.}"
            base=$(_act_native_variant_artifact_name "$tool" "$platform" "$triple" "${name%.*}") || return 4
            printf '%s%s\n' "$base" "$ext"
            return 0
            ;;
    esac
    printf '%s-%s%s\n' "$base" "$triple" "$ext"
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

    local build_purpose requested_targets
    build_purpose=$(jq -r '.build_purpose // empty' <<< "$result_json")
    if ! _act_build_purpose_matches "$result_json" "$build_purpose" || \
       ! jq -e --arg purpose "$build_purpose" '
            all(.targets[]; .build_purpose == $purpose and
                .publishable == ($purpose == "release") and
                (if $purpose == "diagnostic-native" then .method == "native" else true end))
        ' <<< "$result_json" >/dev/null; then
        _log_error "Strict manifest requires consistent explicit build purpose on every result"
        return 4
    fi
    if [[ "$build_purpose" == "diagnostic-native" ]]; then
        requested_targets=$(jq -ce '.requested_targets' <<< "$result_json") || {
            _log_error "Diagnostic manifest requires the explicitly requested target set"
            return 4
        }
    else
        requested_targets=$(jq -c '.requested_targets // [.targets[].platform]' <<< "$result_json") || return 4
    fi
    contract_json=$(_act_contract_for_build_purpose "$tool" "$contract_json" \
        "$requested_targets" "$build_purpose") || return 4

    local config_file="$ACT_REPOS_DIR/${tool}.yaml"
    local binary_name workspace_binaries
    if [[ ! -f "$config_file" ]] || \
       ! binary_name=$(yq -r '.binary_name // ""' "$config_file" 2>/dev/null) || \
       ! _act_is_safe_basename "$binary_name"; then
        _log_error "Strict release manifest requires a safe configured binary_name"
        return 4
    fi

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

    local expected_count base_additional_json base_additional_count manifest_artifact_count
    expected_count=$(jq -r '.exact_primary_assets | length' <<< "$contract_json")
    if [[ ! "$expected_count" =~ ^[1-9][0-9]*$ ]]; then
        _log_error "Release contract has no primary assets"
        return 4
    fi
    base_additional_json=$(jq -c '
        [(.exact_additional_assets // [])[] |
         select((endswith(".sha256") or endswith(".minisig") or
                 . == "SHA256SUMS" or . == "SHA256SUMS.txt" or . == "checksums.txt") | not)] | sort
    ' <<< "$contract_json") || return 4
    base_additional_count=$(jq -r 'length' <<< "$base_additional_json") || return 4
    manifest_artifact_count=$((expected_count + base_additional_count))

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
    local target expected_name expected_input_name format
    local target_json artifact_path artifact_dir
    local frozen_sha frozen_size frozen_identity
    while IFS= read -r target; do
        workspace_binaries=$(_act_workspace_binaries_for_target "$config_file" "$target") || return 4
        [[ -n "$target" ]] || continue
        expected_name=$(jq -r --arg target "$target" '.exact_primary_assets[$target]' <<< "$contract_json")
        if ! _act_is_safe_basename "$expected_name"; then
            _log_error "Unsafe release asset basename for $target: $expected_name"
            return 4
        fi
        expected_input_name="$binary_name"
        [[ "$target" == windows/* ]] && expected_input_name="${binary_name%.exe}.exe"
        format=$(_act_archive_format "$expected_name")

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
           [[ "$identity_before" != "$frozen_identity" ]]; then
            return 4
        fi
        if [[ "$format" == "none" ]]; then
            if ! _act_validate_target_binary "$primary_path" "$target"; then
                return 4
            fi
        elif [[ -n "$workspace_binaries" ]]; then
            _act_validate_workspace_archive \
                "$primary_path" "$format" "$target" "$config_file" || return 4
        elif ! _act_validate_target_archive \
                 "$primary_path" "$format" "$expected_input_name" "$target"; then
            return 4
        fi

        local sha size artifact_json
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

    local additional_name additional_matches additional_receipt additional_path
    local additional_sha additional_size additional_identity_before additional_identity_after
    local additional_format additional_json
    while IFS= read -r additional_name; do
        [[ -n "$additional_name" ]] || continue
        _act_is_safe_basename "$additional_name" || return 4
        additional_matches=$(jq -c --arg name "$additional_name" '
            [.targets[].additional_artifacts[]? |
             select((.path | type) == "string" and
                    (.path | split("/") | last) == $name)]
        ' <<< "$result_json") || return 4
        if [[ "$(jq -r 'length' <<< "$additional_matches")" -ne 1 ]]; then
            _log_error "Strict manifest requires one collected additional artifact: $additional_name"
            return 4
        fi
        additional_receipt=$(jq -c '.[0]' <<< "$additional_matches") || return 4
        if ! jq -e '
            (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
            (.size_bytes | type == "number" and . > 0 and floor == .) and
            (.identity | type == "string" and
             test("^(gnu:[0-9]+:[1-9][0-9]*|bsd:[1-9][0-9]*)$"))
        ' <<< "$additional_receipt" >/dev/null 2>&1; then
            return 4
        fi
        additional_path=$(jq -r '.path' <<< "$additional_receipt") || return 4
        [[ -f "$additional_path" && ! -L "$additional_path" &&
           "$(basename "$additional_path")" == "$additional_name" ]] || return 4
        additional_sha=$(jq -r '.sha256' <<< "$additional_receipt") || return 4
        additional_size=$(jq -r '.size_bytes' <<< "$additional_receipt") || return 4
        additional_identity_before=$(_act_file_identity "$additional_path") || return 4
        [[ "$additional_identity_before" == \
           "$(jq -r '.identity' <<< "$additional_receipt")" ]] || return 4
        [[ "$(_act_sha256 "$additional_path")" == "$additional_sha" &&
           "$(_act_file_size "$additional_path")" == "$additional_size" ]] || return 4
        if [[ "$additional_name" == FrankenTerm-*.app.tar.xz ]] && \
           ! _act_validate_macos_app_archive \
                "$additional_path" "$git_sha" "$version"; then
            _log_error "macOS app archive is not bound to its detached component manifest: $additional_name"
            return 4
        fi
        additional_identity_after=$(_act_file_identity "$additional_path") || return 4
        [[ "$additional_identity_after" == "$additional_identity_before" ]] || return 4
        additional_format=$(_act_archive_format "$additional_name")
        [[ "$additional_format" != "none" ]] || additional_format="binary"
        additional_json=$(jq -nc \
            --arg name "$additional_name" --arg sha "$additional_sha" \
            --argjson size "$additional_size" --arg format "$additional_format" '
            {
                name: $name,
                target: "additional",
                sha256: $sha,
                size_bytes: $size,
                archive_format: $format,
                signed: false,
                signature_file: ""
            }
        ') || return 4
        artifacts+=("$additional_json")
    done < <(jq -r '.[]' <<< "$base_additional_json")

    if [[ ${#artifacts[@]} -ne $manifest_artifact_count ]]; then
        _log_error "Manifest artifact count does not match release contract"
        return 4
    fi

    local artifacts_json summary_json build_environments_json
    local manifest_version built_at duration_seconds duration_ms manifest
    artifacts_json=$(printf '%s\n' "${artifacts[@]}" | jq -s '.') || return 4
    summary_json=$(jq -c '.summary' <<< "$result_json") || return 4
    build_environments_json=$(_act_build_environments_json "$result_json") || {
        _log_error "Failed to serialize build environment receipts"
        return 4
    }
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
        --argjson build_environments "$build_environments_json" \
        --argjson artifacts "$artifacts_json" \
        --arg purpose "$build_purpose" \
        --argjson requested_targets "$requested_targets" \
        '{
            schema_version: "1.0.0",
            build_purpose: $purpose,
            publishable: ($purpose == "release"),
            requested_targets: $requested_targets,
            tool: $tool,
            version: $version,
            run_id: $run_id,
            source: {git_sha: $git_sha, git_ref: $git_ref, dependencies: $source_dependencies},
            built_at: $built_at,
            duration_ms: $duration_ms,
            status: $status,
            summary: $summary,
            build_environments: $build_environments,
            artifacts: ($artifacts | map(. + {build_purpose: $purpose,
                         publishable: ($purpose == "release")}))
        }'); then
        _log_error "Failed to serialize release manifest"
        return 4
    fi

    if ! jq -e --argjson contract "$contract_json" \
        --argjson base_additional "$base_additional_json" '
        (.artifacts | length) ==
            (($contract.exact_primary_assets | length) + ($base_additional | length)) and
        ([.artifacts[] | select(.target != "additional") |
          {key: .target, value: .name}] | from_entries) ==
            $contract.exact_primary_assets and
        ([.artifacts[] | select(.target == "additional") | .name] | sort) ==
            $base_additional and
        ([.artifacts[].name] | length) ==
            ([.artifacts[].name] | unique | length)
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

    # Standalone workflow collection must consult the same configuration as
    # dsr build/release before deciding whether this is a strict manifest.
    local manifest_module_dir
    manifest_module_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 3
    if ! declare -F config_get_release_contract_json &>/dev/null; then
        # shellcheck source=./config.sh
        source "$manifest_module_dir/config.sh" || return 3
    fi
    local release_contract_json="null"
    if ! release_contract_json=$(_act_release_contract_json "$tool"); then
        return 4
    fi
    if [[ "$release_contract_json" != "null" ]]; then
        _act_generate_contract_manifest "$result_json" "$output_file" "$release_contract_json"
        return $?
    fi
    config_validate_target_triples "$tool" || return 4
    _act_validate_native_matrix_result_inventory "$tool" "$result_json" || return 4
    if ! declare -F artifact_naming_artifact_variant &>/dev/null; then
        # shellcheck source=./artifact_naming.sh
        source "$manifest_module_dir/artifact_naming.sh" || return 3
    fi
    if ! _act_build_purpose_matches "$result_json" release false || \
       ! jq -e 'all(.targets[];
            if has("build_purpose") or has("publishable")
            then .build_purpose == "release" and .publishable == true
            else true end)' <<< "$result_json" >/dev/null; then
        _log_error "Non-release results cannot be converted to an ordinary release manifest"
        return 4
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
    local -A seen_native_paths=()

    # Map a filename's embedded platform suffix to a canonical "<os>/<arch>"
    # target. Returns empty if no recognizable suffix is present. Used to
    # override the orchestration-step target when matrix workflows produce
    # cross-platform artifacts under a single act job (e.g. release.yml that
    # builds linux/darwin/windows from the "build-release" job).
    #
    # musl variants share the "linux/<arch>" scheduling target; their declared
    # ABI is retained separately as target_triple on each artifact row.
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

    _act_manifest_target_triple() {
        local target="$1" name="$2" variant triple how
        variant=$(artifact_naming_artifact_variant "$tool" "${target%/*}" "${target#*/}" "$name") || return 4
        IFS=$'\t' read -r triple how <<< "$variant"
        if [[ -z "$triple" || "$how" == unknown ]]; then
            _log_error "Artifact has an unconfigured target variant: $name ($target)"
            return 4
        fi
        printf '%s\n' "$triple"
    }

    _act_manifest_add_file() {
        local file="$1"
        local target="$2"
        local declared_triple="${3:-}" native_result="${4:-false}"

        if [[ -z "$file" || ! -f "$file" ]]; then
            [[ "$native_result" != true ]] || return 4
            return 0
        fi
        [[ -z "$target" ]] && return 0

        local name
        name=$(basename "$file")

        case "$name" in
            *.minisig|*.sig|*.sha256|*.sha512|SHA256SUMS*|*.sbom.*|*.intoto.jsonl)
                return 0
                ;;
        esac
        if [[ "$native_result" == true ]]; then
            [[ ! -L "$file" ]] || return 4
            name=$(_act_native_variant_artifact_name "$tool" "$target" "$declared_triple" "$name") || return 4
            if [[ -n "${seen_native_paths[$file]:-}" && \
                  "${seen_native_paths[$file]}" != "$target|$declared_triple" ]]; then
                _log_error "Native artifact path is shared by distinct variants: $file"
                return 4
            fi
            seen_native_paths["$file"]="$target|$declared_triple"
        fi

        # Skip exact-path duplicates AND name-collision duplicates. Without
        # the name dedup the manifest gets one entry per orchestration target
        # iteration when multiple targets share an artifact_dir or when a
        # matrix workflow emits a full set of cross-platform tarballs under
        # one act job — producing duplicate `name` entries with conflicting
        # `target` and `sha256`, which cascades into a corrupt SHA256SUMS.
        for seen in "${seen_paths[@]}"; do
            [[ "$seen" == "$file" ]] && return 0
        done
        if [[ -n "${seen_names[$name]:-}" && "$native_result" != true ]]; then
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
        if [[ -n "${seen_names[$name]:-}" ]]; then
            if [[ "${seen_names[$name]}" != "$sha" ]]; then
                _log_error "Native artifacts have the same release name and different bytes: $name"
                return 4
            fi
            return 0
        fi

        # If the filename embeds a recognizable platform suffix, trust it
        # over the orchestration-step target — the latter is unreliable when
        # matrix workflows produce cross-platform artifacts under a single
        # act job.
        local inferred_target
        inferred_target=$(_act_infer_target_from_name "$name")
        if [[ "$native_result" == true && -n "$inferred_target" && "$inferred_target" != "$target" ]]; then
            _log_error "Native artifact platform contradicts its worker result: $name ($target)"
            return 4
        elif [[ -n "$inferred_target" ]]; then
            target="$inferred_target"
        fi
        local target_triple
        if [[ "$native_result" == true && -n "$declared_triple" ]]; then
            target_triple="$declared_triple"
        else
            target_triple=$(_act_manifest_target_triple "$target" "$name") || return 4
        fi

        local sig_file=""
        local signed=false
        if [[ -f "${file}.minisig" ]]; then
            signed=true
            sig_file="${name}.minisig"
        fi

        local artifact_json
        artifact_json=$(jq -nc \
            --arg name "$name" \
            --arg target "$target" \
            --arg target_triple "$target_triple" \
            --arg sha "$sha" \
            --argjson size "$size" \
            --arg format "$format" \
            --argjson signed "$signed" \
            --arg sig "$sig_file" \
            '{
                name: $name,
                target: $target,
                target_triple: $target_triple,
                sha256: $sha,
                size_bytes: $size,
                archive_format: $format,
                signed: $signed,
                signature_file: $sig
            }')

        artifacts+=("$artifact_json")
        # shellcheck disable=SC2190 # Indexed array; separate functions use an associative array with this name.
        seen_paths+=("$file")
        seen_names["$name"]="$sha"
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
            return $?
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
            local target_triple
            target_triple=$(_act_manifest_target_triple "$entry_target" "$name") || return 4

            local artifact_json
            artifact_json=$(jq -nc \
                --arg name "$name" \
                --arg target "$entry_target" \
                --arg target_triple "$target_triple" \
                --arg sha "$sha" \
                --argjson size "$size" \
                --arg format "$format" \
                '{
                    name: $name,
                    target: $target,
                    target_triple: $target_triple,
                    sha256: $sha,
                    size_bytes: $size,
                    archive_format: $format,
                    signed: false,
                    signature_file: ""
                }')

            artifacts+=("$artifact_json")
            # shellcheck disable=SC2190 # Indexed array; separate functions use an associative array with this name.
            seen_paths+=("$seen_key")
            seen_names["$name"]="$sha"
        done
    }

    while IFS= read -r target_json; do
        [[ -z "$target_json" ]] && continue
        local target method native_result=false declared_triple="" array_count
        target=$(echo "$target_json" | jq -r '.platform // .target // empty' 2>/dev/null)
        method=$(jq -r '.method // empty' <<< "$target_json")
        if [[ "$method" == native ]]; then
            native_result=true
            declared_triple=$(_act_native_result_target_triple "$tool" "$target_json") || return 4
        fi
        local artifact_path
        local artifact_dir
        artifact_dir=$(echo "$target_json" | jq -r '.artifact_dir // empty' 2>/dev/null)
        array_count=$(jq -er '(.artifact_paths // []) |
            if type == "array" and all(.[]; type == "string" and length > 0)
            then length else error("invalid artifact_paths") end' <<< "$target_json") || return 4
        while IFS= read -r -d '' artifact_path; do
            [[ -n "$artifact_path" ]] || continue
            _act_manifest_add_file "$artifact_path" "$target" "$declared_triple" "$native_result" || return $?
        done < <(jq -j --argjson count "$array_count" '
            (if $count > 0 then .artifact_paths[] else
                (.artifact_path // "" | split(",")[]) end) | ., "\u0000"
        ' <<< "$target_json")

        if [[ -n "$artifact_dir" && -d "$artifact_dir" ]]; then
            while IFS= read -r -d '' file; do
                if act_artifact_zip_is_wrapper "$method" "$file"; then
                    _act_manifest_add_zip_entries "$file" "$target" || return $?
                else
                    _act_manifest_add_file "$file" "$target" "$declared_triple" "$native_result" || return $?
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

    _act_validate_native_matrix_result_inventory "$tool" "$result_json" "$artifacts_json" || return 4

    local build_environments_json requested_targets_json
    build_environments_json=$(_act_build_environments_json "$result_json") || {
        _log_error "Failed to serialize build environment receipts"
        return 4
    }
    requested_targets_json=$(jq -c '
        .requested_targets // null |
        if . == null or (type == "array" and all(.[];
            type == "string" and test("^(linux|darwin|windows)/(amd64|arm64|386)$")))
        then . else error("invalid requested build platforms") end
    ' <<< "$result_json") || return 4

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
        --argjson build_environments "$build_environments_json" \
        --argjson requested_targets "$requested_targets_json" \
        --argjson artifacts "$artifacts_json" \
        '{
            schema_version: "1.0.0",
            tool: $tool,
            version: $version,
            run_id: $run_id,
            source: {git_sha: $git_sha, git_ref: $git_ref, dependencies: []},
            build_purpose: "release",
            publishable: true,
            built_at: $built_at,
            duration_ms: $duration_ms,
            status: $status,
            summary: $summary,
            build_environments: $build_environments,
            artifacts: ($artifacts | map(. + {build_purpose: "release", publishable: true}))
        } + (if $requested_targets == null then {} else {requested_targets: $requested_targets} end)') || {
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
export -f _act_result_artifact_receipts _act_target_result_available
export -f _act_build_orchestration_target _act_run_target_worker
export -f act_sync_sources
