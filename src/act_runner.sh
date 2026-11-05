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

# Reload the authoritative policy even if a caller inherited exported helpers.
# shellcheck source=src/guardrails.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/guardrails.sh" || { return 3 2>/dev/null || exit 3; }
# shellcheck source=src/platforms.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/platforms.sh" || { return 3 2>/dev/null || exit 3; }

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

# Collection modes belong to private evidence, not published archive members.
# Normalize fresh copies behind a private directory at the archive boundary;
# the original collection receipts and exclusive output descriptor stay intact.
_act_stream_workspace_archive() {
    local format="$1" artifact_dir="$2"
    shift 2
    if ! declare -F packaging_stream_archive &>/dev/null; then
        local module_dir
        module_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 3
        # shellcheck source=SCRIPTDIR/packaging.sh
        source "$module_dir/packaging.sh" || return 3
    fi
    packaging_stream_archive "$format" "$artifact_dir" "$artifact_dir" "$@"
}

_act_stream_workspace_tar_gz() {
    _act_stream_workspace_archive tar.gz "$@"
}

_act_stream_workspace_tar_xz() {
    _act_stream_workspace_archive tar.xz "$@"
}

_act_stream_workspace_zip() {
    _act_stream_workspace_archive zip "$@"
}

# Inspect fresh archive headers before accepting their collection receipt.
# Prebuilt archives retain their byte authority and use the existing validators.
_act_validate_release_archive_metadata() {
    local archive="$1" format="$2"
    if ! declare -F _pkg_archive_inspect &>/dev/null; then
        local module_dir
        module_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 3
        # shellcheck source=SCRIPTDIR/packaging.sh
        source "$module_dir/packaging.sh" || return 3
    fi
    _pkg_archive_inspect normalized "$archive" "$format"
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
    local selected_triple="${4:-${_ACT_STRICT_TARGET_TRIPLE:-}}"

    [[ "$purpose" == release || "$purpose" == diagnostic-native ]] || return 4
    [[ -f "$config_file" && ! -L "$config_file" ]] || return 4
    command -v yq &>/dev/null && command -v jq &>/dev/null || return 3
    config_json=$(yq -o=json -I=0 '.' "$config_file" 2>/dev/null) || return 4
    format=$(jq -ers --arg os "$target_os" --arg target "$platform" --arg purpose "$purpose" \
        --arg triple "$selected_triple" '
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
        (if $purpose != "release" or .release_contract == null then ""
         else .release_contract.exact_primary_assets as $assets |
             if ($assets | type) != "object" then error("invalid release archive contract")
             elif ($assets | has($target)) then $assets[$target]
             elif $triple != "" and ($assets | has($target + "@" + $triple))
             then $assets[$target + "@" + $triple]
             else error("missing selected exact primary") end
         end) as $primary |
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
    local selected_triple="${4:-${_ACT_STRICT_TARGET_TRIPLE:-}}"
    [[ "$purpose" == release || "$purpose" == diagnostic-native ]] || return 4
    [[ -f "$config_file" && ! -L "$config_file" ]] || return 4
    config_json=$(yq -o=json -I=0 '.' "$config_file" 2>/dev/null) || return 4
    selected=$(jq -ces --arg target "$target" --arg purpose "$purpose" \
        --arg triple "$selected_triple" '
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
            else .release_contract.exact_primary_assets as $assets |
                (if ($assets | has($target)) then $assets[$target]
                 elif $triple != "" then $assets[$target + "@" + $triple]
                 else null end) as $primary |
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
    local target="${2:-}" raw normalized module_dir act_jobs
    [[ -f "$config_file" && ! -L "$config_file" ]] || return 4
    command -v yq &>/dev/null || return 3
    if ! declare -F config_normalize_additional_artifacts_json &>/dev/null; then
        module_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 3
        # shellcheck source=SCRIPTDIR/config.sh
        source "$module_dir/config.sh" || return 3
    fi
    raw=$(DSR_TARGET_PLATFORM="$target" _config_read_single_mapping_json "$config_file") || return 4
    act_jobs=$(jq -c '.act_job_map' <<< "$raw") || return 4
    raw=$(jq -c '.workspace_additional_artifacts' <<< "$raw") || return 4
    normalized=$(config_normalize_additional_artifacts_json "$raw" \
        "workspace_additional_artifacts in $config_file" "$act_jobs") || return 4
    if [[ -z "$target" ]]; then
        printf '%s\n' "$normalized"
    else
        jq -c --arg target "$target" '.[$target] // []' <<< "$normalized"
    fi
}

# Admit only the bytes named in a collection receipt. Format checks run between
# digest/size/identity checks so a validator cannot silently admit replacement
# bytes, including changes that retain the same inode. The declared format comes
# from the normalized repository configuration, never from a worker receipt.
_act_validate_additional_artifact() {
    local file="$1" target="$2" format="$3"
    local expected_sha="$4" expected_size="$5" expected_identity="$6"
    local module_dir validation_status=0
    if [[ ! "$expected_sha" =~ ^[0-9a-f]{64}$ ||
          ! "$expected_size" =~ ^[1-9][0-9]*$ ||
          ! "$expected_identity" =~ ^(gnu:[0-9]+:[1-9][0-9]*|bsd:[1-9][0-9]*)$ ]] ||
       [[ ! -f "$file" || -L "$file" ]] ||
       [[ "$(_act_file_identity "$file")" != "$expected_identity" ||
          "$(_act_sha256 "$file")" != "$expected_sha" ||
          "$(_act_file_size "$file")" != "$expected_size" ]]; then
        _log_error "Additional artifact differs from its collection receipt: $file"
        return 4
    fi
    case "$format" in
        file) ;;
        binary)
            _act_validate_target_binary "$file" "$target" || validation_status=$?
            ;;
        zip|tar.gz|tar.xz)
            if ! declare -F packaging_validate_archive &>/dev/null; then
                module_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 3
                # shellcheck source=SCRIPTDIR/packaging.sh
                source "$module_dir/packaging.sh" || return 3
            fi
            packaging_validate_archive "$file" "$format" || validation_status=$?
            ;;
        json|msi)
            if ! declare -F artifact_format_validate_json &>/dev/null ||
               ! declare -F artifact_format_validate_msi &>/dev/null; then
                module_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 3
                # shellcheck source=SCRIPTDIR/artifact_formats.sh
                source "$module_dir/artifact_formats.sh" || return 3
            fi
            "artifact_format_validate_${format}" "$file" "$expected_sha" "$expected_size" || validation_status=$?
            ;;
        *) validation_status=4 ;;
    esac
    if [[ "$validation_status" -ne 0 ]]; then
        _log_error "Additional artifact $(basename "$file") does not satisfy declared format $format for $target"
        return "$validation_status"
    fi
    if [[ ! -f "$file" || -L "$file" ]] ||
       [[ "$(_act_file_identity "$file")" != "$expected_identity" ||
          "$(_act_sha256 "$file")" != "$expected_sha" ||
          "$(_act_file_size "$file")" != "$expected_size" ]]; then
        _log_error "Additional artifact changed during format validation: $file"
        return 4
    fi
}

# Opted-in workflow producers must own one physical target and one unambiguous
# release naming family. Resolve the whole configuration before any job starts;
# a selected subset cannot hide a second owner of the same job or asset name.
_act_workflow_payload_plans_json() {
    local tool="$1" version="$2" config_file="$ACT_REPOS_DIR/$1.yaml"
    local configured document enabled module_dir target job owners triples triple format names binaries binary repo_path
    local primary compat outputs plan plans='{}' primary_owners='[]' all_names='{}'
    configured=$(_act_workspace_additional_artifacts_json "$config_file") || return 4
    document=$(_config_read_single_mapping_json "$config_file") || return 4
    enabled=$(jq -c --argjson configured "$configured" '
        . as $doc | [$configured | to_entries[] | select(.value | length > 0) |
        .key as $target | $doc.act_job_map[$target] as $job |
        select(($job | type) == "string" and $job != "" and $job != "null") | $target]
    ' <<< "$document") || return 4
    [[ "$enabled" != '[]' ]] || { printf '{}\n'; return 0; }
    repo_path=$(act_get_local_path "$tool") || return 4
    if ! jq -e --argjson enabled "$enabled" '
        (.targets | type == "array") and (($enabled - .targets) | length == 0)
    ' <<< "$document" >/dev/null; then
        _log_error "Workflow additional artifacts require their owners in the configured targets: $enabled"
        return 4
    fi
    if ! declare -F artifact_naming_generate_dual_for_tool &>/dev/null; then
        module_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 3
        # shellcheck source=SCRIPTDIR/artifact_naming.sh
        source "$module_dir/artifact_naming.sh" || return 3
    fi
    while IFS= read -r target; do
        job=$(jq -r --arg target "$target" '.act_job_map[$target]' <<< "$document") || return 4
        owners=$(jq -c --arg job "$job" '. as $doc | [.targets[] | select($doc.act_job_map[.] == $job)]' \
            <<< "$document") || return 4
        if [[ "$(jq length <<< "$owners")" != 1 ]]; then
            _log_error "Workflow job '$job' for $target has ambiguous target owners $owners; use a distinct job per typed companion producer"
            return 4
        fi
        triples=$(config_get_target_triples_json "$tool" "$target") || return 4
        if [[ "$(jq length <<< "$triples")" -gt 1 ]]; then
            _log_error "Workflow job '$job' for $target declares multiple target triples; typed companion producers require one target variant"
            return 4
        fi
    done < <(jq -r '.[]' <<< "$enabled")

    # Include unselected and native targets when checking release-name owners.
    while IFS= read -r target; do
        format=$(jq -r --arg os "${target%/*}" '
            if (.archive_format | type) == "object" then .archive_format[$os] // ""
            elif (.archive_format | type) == "string" then .archive_format else "" end
        ' <<< "$document") || return 4
        if [[ "$format" == binary && "$target" == windows/* ]]; then
            format=exe
        elif [[ "$format" == none || "$format" == binary ]]; then
            format=none
        else
            format=$(_act_workspace_archive_format "$config_file" "$target") || return 4
        fi
        triples=$(config_get_target_triples_json "$tool" "$target") || return 4
        [[ "$triples" != '[]' ]] || triples='[""]'
        while IFS= read -r triple; do
            names=$(artifact_naming_generate_dual_for_tool "$tool" "$version" "${target%/*}" "${target#*/}" \
                "$format" "$repo_path" release "$triple") || return 4
            primary_owners=$(jq -c --arg target "$target" --argjson names "$names" \
                '. + ([$names.versioned, $names.compat] | unique | map({target:$target,name:.}))' \
                <<< "$primary_owners") || return 4
            all_names=$(jq -c --arg target "$target" --argjson names "$names" \
                '. + {($target):$names}' <<< "$all_names") || return 4
        done < <(jq -r '.[]' <<< "$triples")
    done < <(jq -r '.targets[]' <<< "$document")
    if ! jq -en --argjson primary "$primary_owners" --argjson additional "$configured" '
        [$additional[][] | .name | ascii_downcase] as $names |
        all($primary[]; (.name | ascii_downcase) as $name | ($names | index($name)) == null)
    ' >/dev/null; then
        _log_error "Workflow additional artifact name collides with a configured primary or installer alias"
        return 4
    fi
    while IFS= read -r target; do
        job=$(jq -r --arg target "$target" '.act_job_map[$target]' <<< "$document") || return 4
        names=$(jq -c --arg target "$target" '.[$target]' <<< "$all_names") || return 4
        if ! jq -en --arg target "$target" --argjson owners "$primary_owners" --argjson names "$names" '
            [$names.versioned, $names.compat] | map(ascii_downcase) as $own |
            all($owners[] | select(.target != $target); (.name | ascii_downcase) as $name |
                ($own | index($name)) == null)
        ' >/dev/null; then
            _log_error "Workflow job '$job' for $target has ambiguous primary names; include the platform in artifact_naming and install_script_compat"
            return 4
        fi
        format=$(_act_workspace_archive_format "$config_file" "$target") || return 4
        primary=$(jq -r '.versioned' <<< "$names") || return 4
        compat=$(jq -r '.compat' <<< "$names") || return 4
        if [[ "$primary" != "$compat" && "${primary,,}" == "${compat,,}" ]]; then
            _log_error "Workflow job '$job' for $target has primary names that differ only by case"
            return 4
        fi
        binaries=$(_act_workspace_binaries_for_target "$config_file" "$target") || return 4
        [[ -n "$binaries" ]] || binaries=$(jq -r --arg tool "$tool" '.binary_name // $tool' <<< "$document") || return 4
        local -a members=()
        while IFS= read -r binary; do
            _act_is_safe_basename "$binary" || return 4
            if [[ "$target" == windows/* ]]; then
                [[ "${binary,,}" != *.exe ]] || binary="${binary:0:${#binary}-4}"
                binary="${binary}.exe"
            fi
            members+=("$binary")
        done <<< "$binaries"
        binaries=$(printf '%s\n' "${members[@]}" | jq -Rsc 'split("\n")[:-1]') || return 4
        outputs=$(jq -cn --arg primary "$primary" --arg compat "$compat" --arg format "$format" \
            --argjson companions "$(jq -c --arg target "$target" '.[$target]' <<< "$configured")" '
            ([$primary,$compat] | unique | map({key:.,value:{role:"primary",format:$format,required:(. == $primary)}}) |
             from_entries) as $primaries |
            $primaries + ($primaries | to_entries | map({key:(.key + ".sha256"),value:{role:"checksum",format:"file",required:false}}) | from_entries) +
            ($companions | map({key:.name,value:{role:"additional",format:.format,required:true}}) | from_entries)
        ') || return 4
        plan=$(jq -cn --arg target "$target" --arg job "$job" --arg version "$version" \
            --arg primary "$primary" --arg compat "$compat" --arg format "$format" \
            --argjson binaries "$binaries" --argjson outputs "$outputs" \
            '{target:$target,job:$job,version:$version,primary:$primary,compat:$compat,
              archive_format:$format,binaries:$binaries,outputs:$outputs}') || return 4
        plans=$(jq -c --arg target "$target" --argjson plan "$plan" '. + {($target):$plan}' <<< "$plans") || return 4
    done < <(jq -r '.[]' <<< "$enabled")
    printf '%s\n' "$plans"
}

# Workflow primary archives may include notices or other regular data, but
# every configured executable must exist at its exact root name and have the
# owning target's binary format and architecture. Full archive admission runs
# first, including CRC/trailer, path, link and expansion checks.
_act_validate_workflow_primary() {
    local file="$1" plan="$2" format target members binary size mode executable
    format=$(jq -r '.archive_format' <<< "$plan") || return 4
    target=$(jq -r '.target' <<< "$plan") || return 4
    packaging_validate_archive "$file" "$format" || return 4
    members=$(packaging_payload_members "$file" "$format") || return 4
    while IFS= read -r binary; do
        if ! printf '%s\n' "$members" | grep -Fx -- "$binary" >/dev/null; then
            _log_error "Workflow primary $(basename "$file") for $target is missing configured binary $binary"
            return 4
        fi
        size=$(_act_archive_entry_stream "$file" "$format" "$binary" | wc -c | tr -d '[:space:]') || return 4
        mode=$(_act_archive_member_mode "$file" "$format" "$binary") || return 4
        executable=false
        [[ "$mode" != *x* ]] || executable=true
        _act_validate_target_binary_reader "$file::$binary" "$target" "$size" "$executable" \
            _act_read_archive_hex_bytes "$file" "$format" "$binary" || return 4
    done < <(jq -r '.binaries[]' <<< "$plan")
}

# Independent manifest admission repeats this check using a freshly resolved
# configuration plan. Neither a worker's method flag nor its filename can
# choose the owner, declared content type or compiler variant.
_act_validate_workflow_payload_result() {
    local result="$1" plan="$2" payload inventory actual paths additional name path row role format sha size identity
    payload=$(jq -er '.workflow_payload_dir | strings | select(length > 0)' <<< "$result") || return 4
    if ! jq -e --argjson plan "$plan" '
        .method == "act" and .platform == $plan.target and .job == $plan.job and
        .workflow_payload_plan == $plan and (.artifact_dir // "") == "" and (.artifact_path // "") == "" and
        (.workflow_artifact_dir | type == "string" and length > 0) and
        .workflow_artifact_dir != .workflow_payload_dir and
        (.artifact_paths | type == "array" and all(.[]; type == "string")) and
        (.additional_artifacts | type == "array")
    ' <<< "$result" >/dev/null; then
        _log_error "Workflow result does not match its configured payload ownership plan"
        return 4
    fi
    inventory=$(jq -ceS '.workflow_inventory | if type == "array" and length > 0 then sort_by(.path) else error("missing workflow inventory") end' \
        <<< "$result") || return 4
    actual=$(_act_result_artifact_receipts "$result") || return 4
    [[ "$actual" == "$inventory" ]] || { _log_error "Workflow transport or payload bytes differ from their collection inventory"; return 4; }
    paths='[]' additional='[]'
    local seen='[]'
    while IFS= read -r -d '' path; do
        [[ "$path" == "$payload" ]] && continue
        [[ -f "$path" && ! -L "$path" && "${path%/*}" == "$payload" ]] || return 4
        name="${path##*/}"
        row=$(jq -ce --arg name "$name" '.outputs[$name] // error("undeclared workflow payload: " + $name)' <<< "$plan") || return 4
        seen=$(jq -c --arg name "$name" '. + [$name]' <<< "$seen") || return 4
        role=$(jq -r '.role' <<< "$row") || return 4
        format=$(jq -r '.format' <<< "$row") || return 4
        row=$(jq -ce --arg path "$path" '.[] | select(.path == $path)' <<< "$inventory") || return 4
        sha=$(jq -r '.sha256' <<< "$row"); size=$(jq -r '.size_bytes' <<< "$row"); identity=$(jq -r '.identity' <<< "$row")
        _act_validate_additional_artifact "$path" "$(jq -r '.target' <<< "$plan")" "$format" "$sha" "$size" "$identity" || return 4
        if [[ "$role" == additional ]]; then
            additional=$(jq -c --argjson row "$row" '. + [$row]' <<< "$additional") || return 4
        else
            paths=$(jq -c --arg path "$path" '. + [$path]' <<< "$paths") || return 4
            if [[ "$role" == primary ]]; then
                _act_validate_workflow_primary "$path" "$plan" || return 4
            else
                [[ -f "$payload/${name%.sha256}" && ! -L "$payload/${name%.sha256}" ]] || return 4
                sha=$(_act_sha256 "$payload/${name%.sha256}") || return 4
                if ! python3 - "$path" "$sha" "${name%.sha256}" <<'PY'
import sys
path, digest, name = sys.argv[1:]
with open(path, 'rb') as stream:
    data = stream.read(1025)
forms = [digest, digest + '  ' + name, digest + ' *' + name]
allowed = {form.encode('ascii') + ending for form in forms for ending in (b'', b'\n', b'\r\n')}
raise SystemExit(0 if data in allowed else 4)
PY
                then
                    _log_error "Workflow checksum does not describe its owned primary: $name"
                    return 4
                fi
            fi
        fi
    done < <(find "$payload" -print0)
    if ! jq -en --argjson seen "$seen" --argjson plan "$plan" --argjson result "$result" \
        --argjson paths "$paths" --argjson additional "$additional" '
        ($seen | map(ascii_downcase) | length == (unique | length)) and
        (([$plan.outputs | to_entries[] | select(.value.required) | .key] - $seen) | length == 0) and
        ($paths | sort) == ($result.artifact_paths | sort) and
        ($additional | sort_by(.path)) == ($result.additional_artifacts | sort_by(.path))
    ' >/dev/null; then
        _log_error "Workflow result is missing required primaries or companions, or has contradictory payload receipts"
        return 4
    fi
    actual=$(_act_result_artifact_receipts "$result") || return 4
    [[ "$actual" == "$inventory" ]] || return 4
}

# act's upload ZIPs are transport containers. Materialize one exact payload
# namespace before exposing a successful result, retaining both the original
# transport inventory and final files for resume verification. A final archive
# companion is copied intact and never fed through the legacy ZIP heuristic.
_act_materialize_workflow_payloads() {
    local result="$1" plan="$2" raw root payload before after row source copy name path receipt selected
    local index=0 role format paths='[]' additional='[]' inventory module_dir extracted
    local -A seen=()
    raw=$(jq -er '.artifact_dir | strings | select(length > 0)' <<< "$result") || return 4
    before=$(_act_result_artifact_receipts "$(jq -cn --arg dir "$raw" '{workflow_artifact_dir:$dir}')") || return 4
    module_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 3
    if ! declare -F packaging_extract_payload &>/dev/null; then
        # shellcheck source=SCRIPTDIR/packaging.sh
        source "$module_dir/packaging.sh" || return 3
    fi
    root=$(mktemp -d "$ACT_ARTIFACTS_DIR/workflow-payload.XXXXXXXX") || return 4
    payload="$root/payload"
    mkdir -m 700 "$payload" || return 4
    while IFS= read -r row; do
        source=$(jq -r '.path' <<< "$row") || return 4
        index=$((index + 1))
        copy="$root/input-$index"
        receipt=$(_act_collect_stream_exclusive "$copy" 600 _act_stream_local_file "$source") || return 4
        if ! jq -en --argjson source "$row" --argjson copy "$receipt" \
            '$source.sha256 == $copy.sha256 and $source.size_bytes == $copy.size_bytes' >/dev/null; then
            _log_error "Workflow upload changed during held collection: $source"
            return 4
        fi
        name="${source##*/}"
        if act_artifact_zip_is_wrapper act "$source"; then
            extracted="$root/extracted-$index"
            mkdir -m 700 "$extracted" || return 4
            packaging_extract_payload "$copy" zip "$extracted" || return 4
            selected='[]'
            while IFS= read -r -d '' path; do
                [[ -f "$path" && ! -L "$path" ]] || return 4
                selected=$(jq -c --arg name "${path##*/}" --arg path "$path" \
                    '. + [{name:$name,path:$path}]' <<< "$selected") || return 4
            done < <(find "$extracted" -type f -print0)
        elif jq -e --arg name "$name" '.outputs | has($name)' <<< "$plan" >/dev/null; then
            selected=$(jq -cn --arg name "$name" --arg path "$copy" '[{name:$name,path:$path}]') || return 4
        else
            _log_error "Workflow job $(jq -r '.job' <<< "$plan") uploaded an undeclared file: $source"
            return 4
        fi
        while IFS= read -r receipt; do
            name=$(jq -r '.name' <<< "$receipt"); path=$(jq -r '.path' <<< "$receipt")
            if [[ -n "${seen[${name,,}]:-}" ]] ||
               ! jq -e --arg name "$name" '.outputs | has($name)' <<< "$plan" >/dev/null ||
               { ! _act_is_safe_basename "$name" &&
                 ! jq -e --arg name "$name" '.outputs[$name].role == "checksum"' <<< "$plan" >/dev/null; }; then
                _log_error "Workflow job $(jq -r '.job' <<< "$plan") for $(jq -r '.target' <<< "$plan") has a duplicate, foreign or undeclared payload: $name"
                return 4
            fi
            seen["${name,,}"]=1
            role=$(jq -r --arg name "$name" '.outputs[$name].role' <<< "$plan") || return 4
            format=$(jq -r --arg name "$name" '.outputs[$name].format' <<< "$plan") || return 4
            local mode=600
            [[ "$format" != binary ]] || mode=700
            receipt=$(_act_collect_stream_exclusive "$payload/$name" "$mode" _act_stream_local_file "$path") || return 4
            if [[ "$role" == additional ]]; then
                additional=$(jq -c --argjson receipt "$receipt" '. + [$receipt]' <<< "$additional") || return 4
            else
                paths=$(jq -c --arg path "$payload/$name" '. + [$path]' <<< "$paths") || return 4
            fi
        done < <(jq -c '.[]' <<< "$selected")
    done < <(jq -c '.[]' <<< "$before")
    after=$(_act_result_artifact_receipts "$(jq -cn --arg dir "$raw" '{workflow_artifact_dir:$dir}')") || return 4
    [[ "$before" == "$after" ]] || { _log_error "Workflow transport inventory changed during collection"; return 4; }
    result=$(jq -c --arg raw "$raw" --arg payload "$payload" --argjson plan "$plan" \
        --argjson paths "$paths" --argjson additional "$additional" '
        . + {artifact_dir:"",artifact_path:"",artifact_paths:$paths,additional_artifacts:$additional,
             workflow_artifact_dir:$raw,workflow_payload_dir:$payload,workflow_payload_plan:$plan,
             artifact_count:(($paths|length)+($additional|length))}' <<< "$result") || return 4
    inventory=$(_act_result_artifact_receipts "$result") || return 4
    result=$(jq -c --argjson inventory "$inventory" '.workflow_inventory=$inventory' <<< "$result") || return 4
    _act_validate_workflow_payload_result "$result" "$plan" || return 4
    printf '%s\n' "$result"
}

# Reconstruct additional-artifact ownership from trusted configuration before
# manifest admission. This also refuses missing, extra or repeated receipts and
# prevents later variants from taking ownership of platform-level companions.
# Return a path-keyed map with trusted names/formats and the verified receipts.
_act_additional_artifact_receipts_json() {
    local tool="$1" result_json="$2" configured target_json target triple specs
    local receipts names expected triples row name path format sha size identity complete primary_paths
    local verified='{}' workflow_plans workflow_plan
    jq -e '.targets | type == "array" and all(.[]; type == "object")' \
        <<< "$result_json" >/dev/null || return 4
    primary_paths=$(jq -c '[.targets[] |
        if ((.artifact_paths // []) | length) > 0 then .artifact_paths[]
        else (.artifact_path // "" | split(",")[]) end | select(length > 0)]' \
        <<< "$result_json") || return 4
    configured=$(_act_workspace_additional_artifacts_json "$ACT_REPOS_DIR/$tool.yaml") || return 4
    workflow_plans=$(_act_workflow_payload_plans_json "$tool" "$(jq -r '.version // ""' <<< "$result_json")") || return 4
    while IFS= read -r target_json; do
        target=$(jq -er '.platform // .target | strings' <<< "$target_json") || return 4
        specs=$(jq -c --arg target "$target" '.[$target] // []' <<< "$configured") || return 4
        triple=$(jq -r '.target_triple // ""' <<< "$target_json") || return 4
        if [[ "$(jq -r '.method // ""' <<< "$target_json")" != act && -n "$triple" ]] &&
           [[ "$(jq 'length' <<< "$specs")" -gt 0 ]]; then
            triples=$(config_get_target_triples_json "$tool" "$target") || return 4
            if [[ "$triple" != "$(jq -r '.[0] // ""' <<< "$triples")" ]]; then
                specs='[]'
            fi
        fi
        receipts=$(jq -ce '(if has("additional_artifacts") then .additional_artifacts else [] end) |
            if type == "array" and all(.[];
                type == "object" and (.path | type == "string" and length > 0) and
                (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
                (.size_bytes | type == "number" and . > 0 and floor == .) and
                (.identity | type == "string" and
                 test("^(gnu:[0-9]+:[1-9][0-9]*|bsd:[1-9][0-9]*)$")))
            then . else error("invalid additional artifact receipts") end' <<< "$target_json") || return 4
        names=$(jq -c '[.[].path | split("/") | last] | sort' <<< "$receipts") || return 4
        expected=$(jq -c 'map(.name) | sort' <<< "$specs") || return 4
        complete=$(jq -r --arg overall "$(jq -r '.status // ""' <<< "$result_json")" '
            $overall == "success" or .status == "success" or .status == "ok" or .status == "passed"
        ' <<< "$target_json") || return 4
        workflow_plan=$(jq -c --arg target "$target" '.[$target] // null' <<< "$workflow_plans") || return 4
        if [[ "$workflow_plan" != null && "$complete" == true ]]; then
            _act_validate_workflow_payload_result "$target_json" "$workflow_plan" || return 4
        fi
        if ! jq -en --argjson names "$names" --argjson expected "$expected" \
            --argjson complete "$complete" '
            ($names | length) == ($names | unique | length) and
            (($names - $expected) | length) == 0 and
            (if $complete then $names == $expected else true end)
        ' >/dev/null; then
            _log_error "Additional artifact receipts for $target do not match configured names (expected $expected; collected $names)"
            return 4
        fi
        while IFS= read -r row; do
            path=$(jq -r '.path' <<< "$row") || return 4
            name=$(basename "$path")
            if jq -e --arg path "$path" 'index($path) != null' <<< "$primary_paths" >/dev/null; then
                _log_error "Additional artifact is also claimed as a primary payload: $path"
                return 4
            fi
            format=$(jq -er --arg name "$name" '.[] | select(.name == $name) | .format' <<< "$specs") || return 4
            sha=$(jq -r '.sha256' <<< "$row") || return 4
            size=$(jq -r '.size_bytes' <<< "$row") || return 4
            identity=$(jq -r '.identity' <<< "$row") || return 4
            _act_validate_additional_artifact "$path" "$target" "$format" "$sha" "$size" "$identity" || return 4
            if jq -e --arg path "$path" 'has($path)' <<< "$verified" >/dev/null; then
                _log_error "Additional artifact path has multiple producers: $path"
                return 4
            fi
            verified=$(jq -c --arg path "$path" --arg name "$name" --arg format "$format" \
                --arg target "$target" --argjson receipt "$row" \
                '. + {($path): ($receipt + {name:$name, declared_format:$format, target:$target})}' \
                <<< "$verified") || return 4
        done < <(jq -c '.[]' <<< "$receipts")
    done < <(jq -c '.targets[]' <<< "$result_json")
    printf '%s\n' "$verified"
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

# macOS answers stat on /dev/fd/N with the descriptor's access (-r--------), not
# the file's mode. Callers fence identity around this read, so the path names
# the same inode as the held descriptor.
_act_held_file_mode() {
    local descriptor="$1" path="$2"
    [[ "$(uname -s)" != Darwin ]] || descriptor=$path
    stat -L -c %A "$descriptor" 2>/dev/null || stat -L -f %Sp "$descriptor" 2>/dev/null
}

# Freeze a member as soon as collection/staging hands it to the coordinator.
# Keep its original inode open while checking bytes and permissions twice;
# later members and the archiver must not redefine an earlier member's bytes.
# Empty companion files are valid, unlike empty executable/archive streams.
# Strict collection supplies its original receipt and private mode as well:
# extending the receipt must not establish a new identity after that handoff.
_act_workspace_member_receipt() (
    local artifact_dir="$1" member="$2"
    local collection_receipt="${3:-}" collection_mode="${4:-}"
    local path="$artifact_dir/$member" identity sha size mode
    local final_identity final_sha final_size final_mode

    [[ -d "$artifact_dir" && ! -L "$artifact_dir" ]] || return 4
    _act_is_safe_workspace_include_path "$member" || return 4
    _act_workspace_include_path_is_symlink_free "$artifact_dir" "$member" || return 4
    [[ -f "$path" && ! -L "$path" ]] || return 4
    exec 8< "$path" || return 4
    identity=$(_act_file_identity /dev/fd/8) || return 4
    [[ "$(_act_file_identity "$path")" == "$identity" ]] || return 4
    mode=$(_act_held_file_mode /dev/fd/8 "$path") || return 4
    size=$(stat -L -c %s /dev/fd/8 2>/dev/null || stat -L -f %z /dev/fd/8 2>/dev/null) || return 4
    # A fresh read descriptor for each digest avoids relying on whether a
    # /dev/fd reopen shares the original offset (as it can on macOS).
    exec 9< "$path" || return 4
    [[ "$(_act_file_identity /dev/fd/9)" == "$identity" ]] || return 4
    sha=$(_act_sha256 /dev/fd/9) || return 4
    exec 9<&-
    [[ "$sha" =~ ^[a-fA-F0-9]{64}$ && "$size" =~ ^[0-9]+$ &&
       "$mode" =~ ^-[r-][w-][xsS-][r-][w-][xsS-][r-][w-][xtT-]$ ]] || return 4

    _act_workspace_include_path_is_symlink_free "$artifact_dir" "$member" || return 4
    [[ -f "$path" && ! -L "$path" ]] || return 4
    final_identity=$(_act_file_identity "$path") || return 4
    final_mode=$(_act_held_file_mode /dev/fd/8 "$path") || return 4
    final_size=$(stat -L -c %s /dev/fd/8 2>/dev/null || stat -L -f %z /dev/fd/8 2>/dev/null) || return 4
    exec 9< "$path" || return 4
    [[ "$(_act_file_identity /dev/fd/9)" == "$identity" ]] || return 4
    final_sha=$(_act_sha256 /dev/fd/9) || return 4
    exec 9<&-
    _act_workspace_include_path_is_symlink_free "$artifact_dir" "$member" || return 4
    [[ -f "$path" && ! -L "$path" ]] || return 4
    [[ "$identity" == "$final_identity" && "$identity" == "$(_act_file_identity /dev/fd/8)" &&
       "$identity" == "$(_act_file_identity "$path")" && "$mode" == "$final_mode" &&
       "$size" == "$final_size" && "$sha" == "$final_sha" ]] || return 4

    local receipt
    receipt=$(jq -ncS --arg path "$path" --arg member "$member" --arg sha256 "${sha,,}" \
        --argjson size_bytes "$size" --arg identity "$identity" --arg mode "$mode" \
        '{path:$path, member:$member, sha256:$sha256, size_bytes:$size_bytes,
          identity:$identity, mode:$mode}') || return 4
    if [[ -n "$collection_receipt" ]]; then
        case "$collection_mode" in
            600) collection_mode=-rw------- ;;
            700) collection_mode=-rwx------ ;;
            *) return 4 ;;
        esac
        jq -e --argjson collected "$collection_receipt" --arg mode "$collection_mode" '
            .path == $collected.path and .sha256 == $collected.sha256 and
            .size_bytes == $collected.size_bytes and .identity == $collected.identity and
            .mode == $mode
        ' <<< "$receipt" >/dev/null || return 4
    fi
    printf '%s\n' "$receipt"
)

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
    local emit_receipts="${5:-false}"
    local configured=""

    [[ "$emit_receipts" == true || "$emit_receipts" == false ]] || return 7
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
        if [[ "$emit_receipts" == true ]]; then
            _act_workspace_member_receipt "$artifact_dir" "$include" || return 7
        else
            printf '%s\n' "$include"
        fi
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
    local elf_class elf_machine elf_minimum elf_osabi pe_machine pe_magic

    if [[ ! "$size" =~ ^[1-9][0-9]*$ ]]; then
        _log_error "Target primary has no readable bytes: $label"
        return 4
    fi

    case "$target" in
        linux/amd64|linux/arm64|linux/386|linux/armv7|freebsd/amd64)
            elf_class=02 elf_minimum=64
            case "$target" in
                linux/amd64|freebsd/amd64) elf_machine=3e00 ;;
                linux/arm64) elf_machine=b700 ;;
                linux/386) elf_class=01 elf_minimum=52 elf_machine=0300 ;;
                linux/armv7) elf_class=01 elf_minimum=52 elf_machine=2800 ;;
            esac
            if ((size < elf_minimum)) || \
               ! header=$("$reader" "${reader_args[@]}" 0 20); then
                _log_error "Target primary is not a complete ELF header for $target: $label"
                return 4
            fi
            machine="${header:36:4}"
            elf_osabi="${header:14:2}"
            if [[ "${header:0:8}" != "7f454c46" || "${header:8:2}" != "$elf_class" || \
                  "${header:10:2}" != "01" || "$machine" != "$elf_machine" ]] || \
               { [[ "$target" == freebsd/* ]] && [[ "$elf_osabi" != 09 ]]; } || \
               { [[ "$target" == linux/* ]] && [[ "$elf_osabi" != 00 && "$elf_osabi" != 03 ]]; }; then
                _log_error "Target primary ELF format/OS/architecture does not match $target: $label"
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
        windows/amd64|windows/arm64|windows/386)
            pe_magic=0b02
            case "$target" in
                windows/amd64) pe_machine=6486 ;;
                windows/arm64) pe_machine=64aa ;;
                windows/386) pe_machine=4c01 pe_magic=0b01 ;;
            esac
            if ((size < 90)) || \
               [[ "$("$reader" "${reader_args[@]}" 0 2 2>/dev/null || true)" != "4d5a" ]] || \
               ! pe_offset_hex=$("$reader" "${reader_args[@]}" 60 4); then
                _log_error "Target primary is not a complete PE executable: $label"
                return 4
            fi
            pe_offset=$((0x${pe_offset_hex:6:2}${pe_offset_hex:4:2}${pe_offset_hex:2:2}${pe_offset_hex:0:2}))
            if ((pe_offset < 64 || pe_offset + 26 > size)) || \
               [[ "$("$reader" "${reader_args[@]}" "$pe_offset" 4 2>/dev/null || true)" != "50450000" ]] || \
               ! machine=$("$reader" "${reader_args[@]}" "$((pe_offset + 4))" 2) || \
               ! optional_magic=$("$reader" "${reader_args[@]}" "$((pe_offset + 24))" 2) || \
               [[ "$optional_magic" != "$pe_magic" || "$machine" != "$pe_machine" ]]; then
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
        expected_count=$((expected_count + 1))
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

# Ordinary workspace packages may contain scripts as well as machine code.
# Bind every archived member, including empty notices and declared companions,
# to the bytes, permissions, and inode frozen at its collection handoff.
_act_validate_workspace_member_receipts() {
    local archive="$1" format="$2" artifact_dir="$3"
    shift 3
    [[ -f "$archive" && ! -L "$archive" && $# -gt 0 ]] || return 4

    local entries tar_reader=tar
    command -v gtar &>/dev/null && tar_reader=gtar
    case "$format" in
        tar.gz) entries=$("$tar_reader" -tzf "$archive" 2>/dev/null) || return 4 ;;
        tar.xz) entries=$("$tar_reader" -tJf "$archive" 2>/dev/null) || return 4 ;;
        zip) entries=$(unzip -Z1 "$archive" 2>/dev/null) || return 4 ;;
        *) return 4 ;;
    esac

    local -A seen_members=()
    local -a members=()
    local receipt expected actual member expected_sha expected_size expected_mode
    local actual_sha actual_size actual_mode
    for receipt in "$@"; do
        expected=$(jq -ceS 'select(type == "object")' <<< "$receipt") || return 4
        member=$(jq -er '.member | select(type == "string" and length > 0)' <<< "$expected") || return 4
        _act_is_safe_workspace_include_path "$member" || return 4
        [[ -z "${seen_members[$member]:-}" ]] || return 4
        seen_members["$member"]=1
        members+=("$member")
        actual=$(_act_workspace_member_receipt "$artifact_dir" "$member") || return 4
        [[ "$actual" == "$expected" ]] || return 4

        expected_sha=$(jq -er '.sha256' <<< "$expected") || return 4
        expected_size=$(jq -er '.size_bytes' <<< "$expected") || return 4
        expected_mode=$(jq -er '.mode' <<< "$expected") || return 4
        # The source receipt above must still match exactly, including private
        # permissions. Only the archive representation uses public modes.
        if [[ "$expected_mode" == *[xst]* ]]; then
            expected_mode=-rwxr-xr-x
        else
            expected_mode=-rw-r--r--
        fi
        actual_mode=$(_act_archive_member_mode "$archive" "$format" "$member") || return 4
        [[ "$actual_mode" == "$expected_mode" ]] || return 4
        if command -v sha256sum &>/dev/null; then
            actual_sha=$(_act_archive_entry_stream "$archive" "$format" "$member" |
                sha256sum | awk '{print $1}') || return 4
        elif command -v shasum &>/dev/null; then
            actual_sha=$(_act_archive_entry_stream "$archive" "$format" "$member" |
                shasum -a 256 | awk '{print $1}') || return 4
        else
            return 3
        fi
        actual_size=$(_act_archive_entry_stream "$archive" "$format" "$member" |
            wc -c | tr -d '[:space:]') || return 4
        [[ "$actual_sha" == "$expected_sha" && "$actual_size" == "$expected_size" ]] || return 4
    done
    # A receipt subset is not a complete custody proof, even if every member
    # in that subset matches. Duplicates and unreceipted members also fail.
    [[ "$(printf '%s\n' "$entries" | LC_ALL=C sort)" == \
       "$(printf '%s\n' "${members[@]}" | LC_ALL=C sort)" ]]
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

# Validate the complete configured workspace archive. Strict callers retain
# architecture validation by default; ordinary noncompiled languages may opt
# out of the machine-format check while retaining exact closure and executable
# regular payloads. Byte/mode custody is checked separately against receipts.
_act_validate_workspace_archive() {
    local archive="$1"
    local format="$2"
    local target="$3"
    local config_file="$4"
    local validate_architecture="${5:-true}"
    local entries="" expected_entries="" configured=""
    local tar_reader="tar"
    command -v gtar &>/dev/null && tar_reader="gtar"

    [[ "$validate_architecture" == true || "$validate_architecture" == false ]] || return 4
    [[ -f "$archive" && ! -L "$archive" ]] || return 4
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
        _log_error "Workspace archive members do not match configured closure: $archive"
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
        if [[ "$validate_architecture" == true ]]; then
            _act_validate_target_binary_reader \
                "$archive::$member" "$target" "$size" "$executable" \
                _act_read_archive_hex_bytes "$archive" "$format" "$member" || return 4
        elif [[ ! "$size" =~ ^[1-9][0-9]*$ ]] || \
             { [[ "$target" != windows/* ]] && [[ "$executable" != true ]]; }; then
            _log_error "Workspace binary is empty or not executable: $archive::$member"
            return 4
        fi
    done
}

_act_stage_contract_primary() {
    local tool_name="$1"
    local version="$2"
    local run_id="$3"
    local target="$4"
    local result_json="$5"
    local contract_json="$6"

    local expected_name contract_key
    # Archive validators use the same selected variant as the native receipt.
    # Keep this context local so it cannot escape to another matrix worker.
    local _ACT_STRICT_TARGET_TRIPLE
    _ACT_STRICT_TARGET_TRIPLE=$(jq -er '.target_triple // "" | strings' <<< "$result_json") || return 4
    contract_key=$(config_get_release_contract_target_key \
        "$tool_name" "$target" "$_ACT_STRICT_TARGET_TRIPLE") || return 4
    expected_name=$(jq -r --arg target "$contract_key" '.exact_primary_assets[$target] // empty' <<< "$contract_json")
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

    local target_slug="${contract_key//\//-}"
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
    local staged_collection_receipt="" staged_collection_mode=600
    local -a staged_producer=()
    if $source_is_contract_asset || [[ "$staged_format" == "none" ]]; then
        # Prebuilt archives keep their exact compressed bytes and their
        # existing independent admission policy.
        [[ -x "$source_path" && "$staged_format" == "none" ]] && staged_collection_mode=700
        staged_producer=(_act_stream_local_file "$source_path")
    else
        staged_producer=(_act_stream_workspace_archive "$staged_format" \
            "$(dirname "$source_path")" "$(basename "$source_path")")
    fi
    # Bind the exclusive destination before validation, just as workspace
    # collection does. A later valid archive must not replace this receipt.
    if ! staged_collection_receipt=$(_act_collect_stream_exclusive \
        "$staged_path" "$staged_collection_mode" "${staged_producer[@]}"); then
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
        _act_validate_release_archive_metadata "$staged_path" "$staged_format" || return 4
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
    if ! jq -e --arg path "$staged_path" --arg sha256 "${staged_sha,,}" \
            --argjson size_bytes "$staged_size" --arg identity "$staged_identity_after" '
            .path == $path and .sha256 == $sha256 and
            .size_bytes == $size_bytes and .identity == $identity
        ' <<< "$staged_collection_receipt" >/dev/null; then
        _log_error "Staged release primary changed after its exclusive collection: $staged_path"
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

# Keep physical platforms distinct from executable variants. Diagnostic
# contracts contain a projection of these rows; release contracts contain all.
_act_contract_target_rows() {
    local tool="$1" contract="$2" identities rows matrix
    identities=$(config_get_release_contract_targets_json "$tool") || return 4
    matrix=$(jq -r 'any(.[]; .key != .platform)' <<< "$identities") || return 4
    rows=$(jq -ce --argjson contract "$contract" '
        . as $all |
        ($contract.exact_primary_assets | keys) as $keys |
        [$all[] | select(.key as $key | $keys | index($key))] |
        if length > 0 and (map(.key) | sort) == ($keys | sort)
        then . else error("contract identities differ from configured build targets") end
    ' <<< "$identities") || return 4
    if [[ "$matrix" != true ]]; then
        printf '%s\n' "$rows"
        return 0
    fi
    # A matrix requires exact compiler identity for every physical platform,
    # including singleton platforms and singleton-only diagnostic projections.
    # Use the native backend's selection for omitted singleton target_triples;
    # never let the observed manifest choose its own expected default.
    local row platform configured selected environment effective resolved='[]'
    while IFS= read -r row; do
        platform=$(jq -er '.platform' <<< "$row") || return 4
        configured=$(jq -er '.target_triple | strings' <<< "$row") || return 4
        selected=""
        if [[ "$(jq -r '.key' <<< "$row")" != "$platform" ]]; then
            selected="$configured"
        fi
        environment=$(act_get_build_env "$tool" "$platform" "$selected") || return 4
        effective=$(act_get_build_env_value "$environment" CARGO_BUILD_TARGET) || return 4
        if [[ ! "$effective" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ || "$effective" == *..* ||
              ( -n "$configured" && "$configured" != "$effective" ) ]]; then
            _log_error "Strict matrix compiler selection conflicts with $tool $platform"
            return 4
        fi
        resolved=$(jq -c --argjson row "$row" --arg triple "$effective" '
            . + [($row + {target_triple: $triple, require_triple: true})]
        ' <<< "$resolved") || return 4
    done < <(jq -c '.[]' <<< "$rows")
    printf '%s\n' "$resolved"
}

# Project only the artifact inventory, retaining all other strict validators.
# Additional assets must have unambiguous configured target ownership; observed
# outputs can never determine which family members a diagnostic is required to have.
_act_contract_for_build_purpose() {
    local tool="$1" contract="$2" requested="$3" purpose="$4"
    local identities platforms
    identities=$(config_get_release_contract_targets_json "$tool") || return 4
    platforms=$(jq -c '[.[].platform] | unique' <<< "$identities") || return 4
    if ! jq -en --argjson contract "$contract" --argjson requested "$requested" \
        --argjson identities "$identities" --argjson platforms "$platforms" '
        ($requested | type == "array" and length > 0) and
        ($requested | length) == ($requested | unique | length) and
        (($requested - $platforms) | length) == 0 and
        ($contract.exact_primary_assets | keys | sort) == ($identities | map(.key) | sort)
    ' >/dev/null 2>&1; then
        _log_error "Build targets must be a nonempty unique subset of the strict contract"
        return 4
    fi
    if [[ "$purpose" == "release" ]]; then
        if ! jq -en --argjson platforms "$platforms" --argjson requested "$requested" \
            '($requested | sort) == ($platforms | sort)' >/dev/null; then
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
        additional=$(jq -c 'map(.name)' <<< "$additional") || return 4
        ownership=$(jq -nc --argjson owners "$ownership" --arg target "$target" \
            --argjson additional "$additional" '$owners + {($target): $additional}') || return 4
    done < <(jq -r '.[]' <<< "$platforms")
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
        --argjson owners "$ownership" --argjson identities "$identities" '
        [$identities[] | select(.platform as $platform | $requested | index($platform)) | .key] as $keys |
        $contract |
        .exact_primary_assets |= with_entries(select(.key as $key | $keys | index($key))) |
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
    if [[ "${_ACT_ISOLATED_SOURCE_TOOL:-}" == "$tool_name" ]]; then
        checkouts=$(jq -ce --argjson paths "$_ACT_ISOLATED_SOURCE_PATHS" '
            map(.local_path as $original |
                if $paths | has($original) then .local_path = $paths[$original]
                else error("missing isolated sibling source") end)
        ' <<< "$checkouts") || return 4
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

# Prefer GNU timeout/coreutils gtimeout; the owned group also has a portable
# watchdog for coordinators where neither executable is installed.
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

# Shared ownership also protects health probes and post-release verification.
_act_run_with_timeout() {
    _dsr_run_with_timeout _act_timeout_cmd "$@"
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
    local isolated_home
    # Concurrent Bash workers inherit the same $$, and a retry can start in
    # the same second. Allocate exclusively so their actrc append operations
    # cannot combine settings in another invocation's HOME.
    if ! mkdir -p "$cache_root" ||
       ! isolated_home=$(umask 077; mktemp -d "$cache_root/$(date +%Y%m%d-%H%M%S)-$$.XXXXXXXX"); then
        _log_error "Failed to allocate an isolated act home in: $cache_root"
        return 1
    fi
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

    # A timestamp and $$ are shared by sibling Bash workers and quick
    # retries. Reserve a fresh private upload directory atomically, then use
    # its allocated identity for this invocation's independently owned log.
    local artifact_dir
    if ! mkdir -p "$ACT_ARTIFACTS_DIR" "$ACT_LOGS_DIR" ||
       ! artifact_dir=$(umask 077; mktemp -d "$ACT_ARTIFACTS_DIR/$(date +%Y%m%d-%H%M%S)-$$.XXXXXXXX"); then
        _log_error "Failed to allocate act run storage: $ACT_ARTIFACTS_DIR, $ACT_LOGS_DIR"
        return 1
    fi
    local run_id="${artifact_dir##*/}"
    local log_file="$ACT_LOGS_DIR/$run_id.log"
    if ! (umask 077; set -o noclobber; : > "$log_file"); then
        _log_error "Failed to reserve act run log without overwriting existing evidence: $log_file"
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
    if [[ -z "$timeout_cmd" ]]; then
        _log_info "GNU timeout not available; supervising act with the portable deadline"
    fi
    # The shared wrapper owns a separate process group, forwards orchestration
    # cancellation into it, and waits for escalation with either timer engine.
    if [[ -n "$isolated_home" ]]; then
        HOME="$isolated_home" \
        XDG_CONFIG_HOME="$isolated_home/.config" \
        XDG_CACHE_HOME="$isolated_home/.cache" \
        _act_run_with_timeout "$ACT_TIMEOUT" "${act_cmd[@]}" \
            --directory "$repo_path" \
            2>&1 | tee -a "$log_file"
    else
        _act_run_with_timeout "$ACT_TIMEOUT" "${act_cmd[@]}" \
            --directory "$repo_path" \
            2>&1 | tee -a "$log_file"
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

# Give collection and manifest admission the same exact, validated ZIP
# members. A copied transport is inspected before extraction, so member names
# are never interpreted as unzip patterns and duplicate paths, links, CRC
# failures and excessive expansion cannot disappear behind version filtering.
_act_artifact_zip_payloads() {
    local zip_file="$1" version="$2" module_dir before after work receipt members member name
    local -a zip_paths=() matching=()
    local -A names=()
    if ! declare -F packaging_extract_payload &>/dev/null; then
        module_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 3
        # shellcheck source=SCRIPTDIR/packaging.sh
        source "$module_dir/packaging.sh" || return 3
    fi
    before=$(_act_result_artifact_receipts "$(jq -nc --arg path "$zip_file" \
        '{artifact_paths:[$path]}')") || return 4
    work=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/dsr-act-zip.XXXXXXXX") || return 4
    mkdir -m 700 "$work/payload" || return 4
    receipt=$(_act_collect_stream_exclusive "$work/transport.zip" 600 \
        _act_stream_local_file "$zip_file") || return 4
    jq -e --argjson copy "$receipt" \
        '.[0].sha256 == $copy.sha256 and .[0].size_bytes == $copy.size_bytes' \
        <<< "$before" >/dev/null || return 4
    packaging_extract_payload "$work/transport.zip" zip "$work/payload" || return 4
    members=$(packaging_payload_members "$work/transport.zip" zip) || return 4
    [[ -n "$members" ]] || return 4
    while IFS= read -r member; do
        zip_paths+=("$work/payload/$member")
        if [[ "$member" == *"$version"* || "$member" == *"${version#v}"* ]]; then
            matching+=("$work/payload/$member")
        fi
    done <<< "$members"
    if [[ ${#matching[@]} -gt 0 ]]; then zip_paths=("${matching[@]}"); fi
    for member in "${zip_paths[@]}"; do
        name="${member##*/}"
        if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ || "$name" == *..* ||
              -n "${names[${name,,}]:-}" ]]; then
            _log_error "Workflow ZIP has an unsafe or ambiguous release name: $name"
            return 4
        fi
        names["${name,,}"]=1
        [[ -f "$member" && ! -L "$member" ]] || return 4
    done
    after=$(_act_result_artifact_receipts "$(jq -nc --arg path "$zip_file" \
        '{artifact_paths:[$path]}')") || return 4
    [[ "$before" == "$after" ]] || {
        _log_error "Workflow ZIP changed during collection: $zip_file"
        return 4
    }
    printf '%s\0' "${zip_paths[@]}" | jq -Rsc 'split("\u0000")[:-1]'
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
            count=$((count + 1))
        else
            _log_error "Failed to copy artifact: $artifact"
            failed=$((failed + 1))
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

    # Reject the complete configured matrix before even selecting source or
    # hosts. A CLI subset must not hide an unsupported target in the config.
    local configured_targets
    configured_targets=$(yq -o=json -I=0 '.targets' "$config_file") || return 4
    if [[ "$configured_targets" != null ]]; then
        dsr_platform_validate_targets_json "$configured_targets" "targets for $tool_name" || return 4
    fi
    _act_workspace_additional_artifacts_json "$config_file" >/dev/null || return 4

    # Load config into variables
    ACT_REPO_NAME=$(yq -r '.tool_name // ""' "$config_file")
    ACT_REPO_GITHUB=$(yq -r '.repo // ""' "$config_file")
    ACT_REPO_LOCAL_PATH=$(act_get_local_path "$tool_name") || return 4
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

# Infer only a plain, ambient toolchain invocation. A configured executable,
# wrapper or Cargo toolchain selector is checked by its build context instead:
# probing an unrelated default compiler can reject an otherwise valid recipe.
_act_native_host_capability() {
    local tool_name="${1:-}" platform="${2:-}" config_file command program remainder document overrides source_root
    [[ -n "$tool_name" ]] || return 0
    config_file="$ACT_REPOS_DIR/${tool_name}.yaml"
    [[ -f "$config_file" ]] || return 0
    command=$(act_get_build_cmd "$tool_name" "$platform") || return 4
    [[ "$command" =~ ^[[:space:]]*(cargo|go|bun|node)([[:space:]]|$) ]] || return 0
    program="${BASH_REMATCH[1]}"
    remainder="${command#"${command%%[![:space:]]*}"}"
    remainder="${remainder#"$program"}"
    remainder="${remainder#"${remainder%%[![:space:]]*}"}"
    if [[ "$program" == cargo ]]; then
        case "$remainder" in +*|\"+*|\'+*) return 0 ;; esac
    fi
    document=$(yq -o=json -I=0 '.' "$config_file") || return 4
    if ! overrides=$(jq -rs --arg platform "$platform" --arg program "$program" '
        if length == 1 and (.[0] | type == "object") then .[0]
        else error("expected one repository configuration mapping") end |
        [(if .env == null then {} else .env end),
         (if .cross_compile[$platform].env == null then {} else .cross_compile[$platform].env end)] |
        if all(.[]; type == "object") then . else error("env must be a mapping") end |
        any(.[] | keys[] | ascii_upcase;
            . == "PATH" or . == "PATHEXT" or
            ($program == "cargo" and
                (. == "RUSTUP_TOOLCHAIN" or . == "RUSTUP_HOME" or . == "CARGO_HOME" or
                 . == "RUSTC" or . == "RUSTC_WRAPPER" or . == "RUSTC_WORKSPACE_WRAPPER" or
                 . == "CARGO_BUILD_RUSTC" or . == "CARGO_BUILD_RUSTC_WRAPPER" or
                 . == "CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER")))
    ' <<< "$document"); then
        _log_error "Cannot resolve native toolchain requirements from invalid environment configuration: $tool_name/$platform"
        return 4
    fi
    [[ "$overrides" != true ]] || return 0
    if [[ "$program" == cargo ]]; then
        source_root=$(act_get_local_path "$tool_name") || return 4
        if [[ -d "$source_root" ]]; then
            source_root=$(cd "$source_root" && pwd -P) || return 4
            while :; do
                if [[ -e "$source_root/rust-toolchain" || -e "$source_root/rust-toolchain.toml" ||
                      -e "$source_root/.cargo/config" || -e "$source_root/.cargo/config.toml" ]]; then
                    return 0
                fi
                [[ "$source_root" != / ]] || break
                source_root="${source_root%/*}"
                [[ -n "$source_root" ]] || source_root=/
            done
        fi
        printf 'rust\n'
    else
        printf '%s\n' "$program"
    fi
}

# Get native host for a platform
# Usage: act_get_native_host <platform> [tool_name]
# Returns: Host name (trj, mmini, wlap) or empty
act_get_native_host() {
    local platform="$1"
    local tool_name="${2:-}"
    local capability
    capability=$(_act_native_host_capability "$tool_name" "$platform") || return 4

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
    # one being asleep. Selection may fall back to the static mapping, but the
    # source-staging and native-build consumers still require host admission.
    if [[ "${DSR_DISABLE_HOST_SELECTOR:-0}" != "1" ]] && declare -F selector_choose_host &>/dev/null; then
        local selector_args=(--target "$platform")
        [[ -z "$capability" ]] || selector_args+=(--capability "$capability")
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
        # shellcheck source=SCRIPTDIR/config.sh
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
        # shellcheck source=SCRIPTDIR/config.sh
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

# The cargo shim placed first on PATH when a Linux glibc floor is active,
# or when a strict Unix build explicitly invokes cargo-zigbuild. `cargo
# build` becomes `cargo zigbuild --target <triple>.<floor>`. An explicit
# `cargo zigbuild` retains its arguments, including an unversioned target,
# and uses the same pinned Zig dispatch; other subcommands pass
# through untouched. Requires cargo-zigbuild >= 0.23.0 on the build host —
# older releases hand rustc's aarch64 `--fix-cortex-a53-843419` erratum flag
# to zig unfiltered and the link fails (issue #10).
# Pure POSIX sh; reads DSR_RUST_TARGET / DSR_ZIG_TARGET / DSR_LINUX_GLIBC_FLOOR
# from the environment dsr exports for the build.
_act_zig_cargo_shim_sh() {
    cat <<'DSR_ZIG_SHIM_SCRIPT'
#!/bin/sh
# dsr cargo shim: pinned Zig dispatch for Rust release builds.
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
# Cargo's reviewed global options may precede the subcommand. Keep their
# exact argument boundaries; a prefix must not bypass the Zig dispatcher.
_dsr_subcommand=
_dsr_subcommand_index=0
_dsr_skip_value=0
for _dsr_arg in "$@"; do
  _dsr_subcommand_index=$((_dsr_subcommand_index + 1))
  if [ "$_dsr_skip_value" -eq 1 ]; then
    _dsr_skip_value=0
    continue
  fi
  case "$_dsr_arg" in
    -Z|--color) _dsr_skip_value=1 ;;
    -v|-vv|--verbose|-q|--quiet|--locked|--offline|--frozen|-Z*|--color=*) ;;
    *) _dsr_subcommand=$_dsr_arg; break ;;
  esac
done
if { [ "$_dsr_subcommand" != build ] && [ "$_dsr_subcommand" != zigbuild ]; } ||
   [ -z "${DSR_ZIG_TARGET:-}" ] || [ -z "${DSR_RUST_TARGET:-}" ]; then
  if [ -n "$_dsr_toolchain" ]; then
    exec cargo "$_dsr_toolchain" "$@"
  fi
  exec cargo "$@"
fi
if ! command -v cargo-zigbuild >/dev/null 2>&1 || ! command -v zig >/dev/null 2>&1; then
  echo "[dsr] generated DSR Cargo shim needs cargo-zigbuild and zig on this build host (cargo install cargo-zigbuild)" >&2
  exit 4
fi
# cargo-zigbuild prefers Python's ziglang package over PATH's zig in 0.23,
# and 0.24 also accepts a cached command/argument override. The managed shim
# must use the same Zig executable that strict toolchain identity measures.
# Refuse caller overrides rather than silently measuring a different linker.
if [ "${CARGO_ZIGBUILD_ZIG_COMMAND+x}${CARGO_ZIGBUILD_ZIG_COMMAND_ARGS+x}${CARGO_ZIGBUILD_PYTHON_PATH+x}${CARGO_ZIGBUILD_ZIG_PATH+x}${CARGO_ZIGBUILD_ZIG_VERSION+x}" ]; then
  echo "[dsr] generated DSR Cargo shim does not accept Zig dispatch overrides; select zig on PATH" >&2
  exit 4
fi
_dsr_zig_path=$(command -v zig)
case "$_dsr_zig_path" in
  /*) ;;
  *) _dsr_zig_path="$(pwd -P)/$_dsr_zig_path" ;;
esac
if [ ! -f "$_dsr_zig_path" ] || [ ! -x "$_dsr_zig_path" ]; then
  echo "[dsr] generated DSR Cargo shim needs a Zig executable on the delegated PATH" >&2
  exit 4
fi
# /dev/null cannot execute, so the older Python-first resolver falls through
# to the pinned binary. Newer plugins use the same absolute command directly.
# Keep these derived settings inside the build; the parent observer/cache
# environment is unchanged, and the generator hash binds this dispatch rule.
CARGO_ZIGBUILD_PYTHON_PATH=/dev/null
CARGO_ZIGBUILD_ZIG_PATH=$_dsr_zig_path
CARGO_ZIGBUILD_ZIG_COMMAND=$_dsr_zig_path
export CARGO_ZIGBUILD_PYTHON_PATH CARGO_ZIGBUILD_ZIG_PATH CARGO_ZIGBUILD_ZIG_COMMAND
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
# Explicit Zig commands own their target/floor. Pin the same executable as
# managed `cargo build`, without rewriting any of the caller's arguments.
if [ "$_dsr_subcommand" = zigbuild ]; then
  if [ -n "$_dsr_toolchain" ]; then
    exec cargo "$_dsr_toolchain" "$@"
  fi
  exec cargo "$@"
fi
_dsr_expect_target=0
_dsr_have_target=0
_dsr_index=0
for _dsr_arg in "$@"; do
  _dsr_index=$((_dsr_index + 1))
  [ "$_dsr_index" -gt "$_dsr_subcommand_index" ] || continue
  case "$_dsr_arg" in
    --) break ;;
    --target|--target=*) _dsr_have_target=1 ;;
  esac
done
_dsr_count=$#
_dsr_index=0
_dsr_after_separator=0
while [ "$_dsr_index" -lt "$_dsr_count" ]; do
  _dsr_arg=$1
  shift
  _dsr_index=$((_dsr_index + 1))
  if [ "$_dsr_index" -eq "$_dsr_subcommand_index" ]; then
    set -- "$@" zigbuild
    if [ "$_dsr_have_target" -eq 0 ]; then
      set -- "$@" --target "$DSR_ZIG_TARGET"
    fi
    continue
  fi
  if [ "$_dsr_after_separator" -eq 1 ]; then
    set -- "$@" "$_dsr_arg"
    continue
  fi
  if [ "$_dsr_expect_target" -eq 1 ]; then
    _dsr_expect_target=0
    if [ "$_dsr_arg" = "$DSR_RUST_TARGET" ]; then
      _dsr_arg=$DSR_ZIG_TARGET
    fi
    set -- "$@" "$_dsr_arg"
    continue
  fi
  case "$_dsr_arg" in
    --)
      _dsr_after_separator=1
      set -- "$@" "$_dsr_arg"
      ;;
    --target)
      _dsr_expect_target=1
      set -- "$@" "$_dsr_arg"
      ;;
    --target=*)
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
if [ -n "$_dsr_toolchain" ]; then
  exec cargo "$_dsr_toolchain" "$@"
fi
exec cargo "$@"
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

# Check the new, build-writable PATH directory before selecting the observer
# interpreter. Only shell builtins run here: an added python3 must not be able
# to impersonate the very verifier that would reject it. The subshell confines
# shell-specific glob options and inherited glob filters to this check.
_act_zig_shim_bootstrap_guard_sh() {
    local shim_dir="${1:-}" shim_dir_q
    [[ -n "$shim_dir" ]] || return 0
    printf -v shim_dir_q '%q' "$shim_dir"
    printf '_dsr_expected_shim_dir=%s\n' "$shim_dir_q"
    cat <<'DSR_ZIG_BOOTSTRAP_SH'
(
    set +f
    unset GLOBIGNORE || exit 86
    if test -n "${ZSH_VERSION:-}"; then
        setopt nonomatch
    elif test -n "${BASH_VERSION:-}"; then
        shopt -u failglob
    fi
    if ! test -d "$_dsr_expected_shim_dir" || test -L "$_dsr_expected_shim_dir" ||
       ! test -r "$_dsr_expected_shim_dir" || ! test -x "$_dsr_expected_shim_dir"; then
        printf '[dsr] toolchain identity: generated DSR Cargo shim directory is not a readable plain directory\n' >&2
        exit 86
    fi
    for _dsr_shim_entry in "$_dsr_expected_shim_dir"/* "$_dsr_expected_shim_dir"/.[!.]* "$_dsr_expected_shim_dir"/..?*; do
        if test -e "$_dsr_shim_entry" || test -L "$_dsr_shim_entry"; then
            case "$_dsr_shim_entry" in
                "$_dsr_expected_shim_dir/cargo") ;;
                *) printf '[dsr] toolchain identity: unexpected entry in generated DSR Cargo shim directory: %s\n' "$_dsr_shim_entry" >&2; exit 86 ;;
            esac
        fi
    done
) || exit 86
DSR_ZIG_BOOTSTRAP_SH
}

# Resolve Python once to an absolute executable outside the generated shim
# directory, and execute that same selection for the capability check and the
# observer body. Repeating a bare PATH lookup would permit a late python3 file
# to replace a successfully checked interpreter.
_act_toolchain_python_prefix_sh() {
    local shim_dir="${1:-}" shim_dir_q
    _act_zig_shim_bootstrap_guard_sh "$shim_dir" || return $?
    printf -v shim_dir_q '%q' "$shim_dir"
    printf '_dsr_tool_shim_dir=%s\n' "$shim_dir_q"
    cat <<'DSR_TOOL_PYTHON_SH'
dsr_tool_python=
for dsr_tool_candidate in python3 python3.14 python3.13 python3.12 python3.11; do
    dsr_tool_path=$(command -v "$dsr_tool_candidate") || continue
    case "$dsr_tool_path" in /*) ;; *) continue ;; esac
    if test -n "$_dsr_tool_shim_dir"; then
        dsr_tool_parent=$(CDPATH= cd -P "${dsr_tool_path%/*}" && pwd -P) || exit 86
        dsr_tool_shim_parent=$(CDPATH= cd -P "$_dsr_tool_shim_dir" && pwd -P) || exit 86
        # A PATH entry outside the shim directory can still be a symlink or
        # hardlink to its cargo file. Reject that alias before executing even
        # the Python capability probe; normal interpreter symlinks stay valid.
        if test "$dsr_tool_parent" = "$dsr_tool_shim_parent" ||
           test "$dsr_tool_path" -ef "$_dsr_tool_shim_dir/cargo"; then
            printf '[dsr] toolchain identity: Python cannot be selected from or alias the generated DSR Cargo shim directory\n' >&2
            exit 86
        fi
    fi
    if "$dsr_tool_path" -I -c 'import sys; sys.exit(sys.version_info < (3, 11))' 2>/dev/null; then
        dsr_tool_python=$dsr_tool_path
        break
    fi
done
if test -z "$dsr_tool_python"; then
    printf '[dsr] toolchain identity: Python 3.11+ is required for executable attestation\n' >&2
    exit 86
fi
DSR_TOOL_PYTHON_SH
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
    dsr_platform_is_supported "$platform" || {
        _log_error "Unsupported collected binary platform: $platform"
        return 4
    }

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
    # SSH transports bytes: the inherited Windows console code page otherwise
    # corrupts non-ASCII Cargo metadata before the Unix caller can parse JSON.
    # Set this in the wrapper so file-backed and compressed scripts agree.
    # Progress records would otherwise reach stderr as CLIXML noise over ssh.
    payload="[Console]::OutputEncoding=[Text.UTF8Encoding]::new(); \$ProgressPreference='SilentlyContinue'; $script"
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

# A Unix build needs a deadline on its host: terminating an SSH client alone
# does not retire the remote compiler process group. Keep an anchor alive in a
# new session until the supervisor has sent its final group signal, so a reaped
# group leader's PID can never be reused for an unrelated job during cleanup.
# Output-pipe hangup detects transport loss without heartbeat bytes. stdin is
# deliberately /dev/null for builds, as with the existing ssh -n transport.
# This portable process-group guard assumes trusted build programs: a process
# deliberately starting a separate session can escape the owned group.
_act_unix_build_guard_script() {
    local timeout_sec="${1:-$_ACT_BUILD_TIMEOUT}" script="${2:?Unix build script required}"
    local shell="${3:-}" encoded shell_encoded
    if [[ ! "$timeout_sec" =~ ^[1-9][0-9]{0,6}$ ]] || (( timeout_sec > 2147483 )); then
        _log_error "Unix build timeout must be 1..2147483 seconds"
        return 4
    fi
    if ! command -v base64 >/dev/null 2>&1; then
        _log_error "base64 is required to transport a guarded Unix build"
        return 3
    fi
    encoded=$(printf '%s' "$script" | base64 | tr -d '\r\n') || return 4
    shell_encoded=$(printf '%s' "$shell" | base64 | tr -d '\r\n') || return 4
    cat <<'SH'
# DSR_UNIX_BUILD_GUARD
if ! command -v python3 >/dev/null 2>&1; then
    printf '[dsr] Native Unix build supervision requires Python 3.9+ on the build host\n' >&2
    exit 3
fi
exec python3 -I - <<'DSR_UNIX_BUILD_GUARD_PY'
import base64
import os
import select
import signal
import stat
import subprocess
import sys
import threading
import time
SH
    printf 'dsr_build_program = "%s"\n' "$encoded"
    printf 'dsr_build_shell = "%s"\n' "$shell_encoded"
    printf 'dsr_build_timeout = %s\n' "$timeout_sec"
    cat <<'PY'

def diagnostic(message):
    try:
        os.write(2, ('[dsr] ' + message + '\n').encode())
    except OSError:
        pass  # The SSH reader may already have disappeared.

if (sys.version_info < (3, 9) or not hasattr(os, 'fork') or
        not hasattr(os, 'setsid') or not hasattr(select, 'poll')):
    diagnostic('Native Unix build supervision requires Python 3.9+ with POSIX fork, setsid and poll')
    sys.exit(3)

program = base64.b64decode(dsr_build_program, validate=True)
shell = os.fsdecode(base64.b64decode(dsr_build_shell, validate=True))
shell = shell or os.environ.get('SHELL') or '/bin/sh'
# Parse the complete program before execution; no command may read the rest
# of its own script. A pipe also avoids the host's single-argv size limit.
program = b'{\n' + program + b'\n} </dev/null\n'
cancelled = 0

def cancel(signum, _frame):
    global cancelled
    if not cancelled:
        cancelled = 128 + signum

for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
    signal.signal(signum, cancel)
# Preserve the anchor as a waitable child until the final signal, even when
# the invoking login shell inherited SIGCHLD=SIG_IGN.
signal.signal(signal.SIGCHLD, signal.SIG_DFL)
events = select.poll()
for fd in (1, 2):
    mode = os.fstat(fd).st_mode
    if stat.S_ISFIFO(mode) or stat.S_ISSOCK(mode) or os.isatty(fd):
        events.register(fd, 0)  # ERR/HUP/NVAL are returned without POLLOUT.
status_read, status_write = os.pipe()
permit_read, permit_write = os.pipe()
deadline = time.monotonic() + dsr_build_timeout
anchor = os.fork()
if anchor == 0:
    os.close(status_read)
    os.close(permit_write)
    group_owned = False

    def retire_owned_group():
        # This anchor is still the live session/group leader. Signalling our
        # own group cannot race another job's PID allocation, even after the
        # outer supervisor was killed and can no longer reap us.
        os.killpg(os.getpid(), signal.SIGTERM)
        grace = time.monotonic() + 2
        while time.monotonic() < grace:
            time.sleep(0.05)
        os.killpg(os.getpid(), signal.SIGKILL)

    try:
        os.setsid()
        group_owned = True
        # Caught dispositions reset at exec; the build's shell receives the
        # normal signals while this group anchor survives the TERM grace.
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(signum, lambda _signum, _frame: None)
        os.write(status_write, b'R\n')
        if os.read(permit_read, 1) != b'1':
            os._exit(3)
        child = subprocess.Popen([shell, '-s'], stdin=subprocess.PIPE, close_fds=True)

        def run_build():
            try:
                child.communicate(program)
                code = child.returncode if child.returncode >= 0 else 128 - child.returncode
            except BaseException as error:
                diagnostic('Unable to run supervised Unix build: ' + str(error))
                code = 3
            try:
                os.write(status_write, ('E%d\n' % code).encode())
            except OSError:
                pass  # The lease loop below handles a lost supervisor.

        # Launch before starting a thread: there is no fork from a multithreaded
        # Python process. Feeding a large script must not block the watchdog.
        threading.Thread(target=run_build, daemon=True).start()
        lease = select.poll()
        lease.register(permit_read, select.POLLIN)
        # The parent keeps its writer until cleanup is done. EOF retires this
        # group even after SIGKILL/OOM of the outer supervisor; a stopped or
        # otherwise stuck supervisor cannot prevent the host-local deadline.
        while True:
            if lease.poll(100) or time.monotonic() >= deadline:
                retire_owned_group()
    except BaseException as error:
        diagnostic('Unable to launch supervised Unix build: ' + str(error))
        if group_owned:
            retire_owned_group()
        os._exit(3)

os.close(status_write)
os.close(permit_read)
os.set_blocking(status_read, False)
events.register(status_read, select.POLLIN)
ready = False
started = False
buffer = b''
result = 3
try:
    while True:
        observed = events.poll(100)
        if cancelled:
            result = cancelled
            break
        if any(fd in (1, 2) and mask & (select.POLLERR | select.POLLHUP | select.POLLNVAL)
               for fd, mask in observed):
            diagnostic('Build transport closed; retiring the native build process group')
            result = 128 + signal.SIGHUP
            break
        if time.monotonic() >= deadline:
            diagnostic('Native build exceeded its host-side deadline')
            result = 124
            break
        finished = False
        for fd, _mask in observed:
            if fd != status_read:
                continue
            data = os.read(status_read, 128)
            if not data:
                diagnostic('Native build supervisor anchor exited unexpectedly')
                finished = True
                break
            buffer += data
            while b'\n' in buffer:
                line, buffer = buffer.split(b'\n', 1)
                if line == b'R' and not ready:
                    ready = True
                elif line.startswith(b'E') and ready:
                    result = int(line[1:])
                    finished = True
                else:
                    raise RuntimeError('Invalid native build supervisor status')
        if finished:
            break
        if ready and not started:
            # Readiness and channel admission precede any build execution.
            os.write(permit_write, b'1')
            started = True
finally:
    # The anchor has not been waited on, so neither its PID nor its process
    # group can have been recycled. Before R, no build child can exist.
    signal_target = (lambda sig: os.killpg(anchor, sig)) if ready else (lambda sig: os.kill(anchor, sig))
    try:
        signal_target(signal.SIGTERM)
    except ProcessLookupError:
        pass
    grace = time.monotonic() + 2
    while time.monotonic() < grace:
        time.sleep(0.05)
    try:
        signal_target(signal.SIGKILL)
    except ProcessLookupError:
        pass
    os.waitpid(anchor, 0)
    os.close(status_read)
    os.close(permit_write)
sys.exit(result)
DSR_UNIX_BUILD_GUARD_PY
PY
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
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
public static class DSRNativeBuildGuard {
    [StructLayout(LayoutKind.Sequential)] struct FileInfo {
        public uint Attributes, CreationLow, CreationHigh, AccessLow, AccessHigh,
            WriteLow, WriteHigh, Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
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
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern SafeFileHandle CreateFileW(string name, uint access, uint share,
        IntPtr security, uint disposition, uint flags, IntPtr template);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileInfo info);
    [DllImport("kernel32.dll", SetLastError=true)]
    static extern uint GetFileType(SafeFileHandle handle);
    static SafeFileHandle HoldPath(string path, bool directory) {
        string native = path.Replace('/', '\\');
        if (!native.StartsWith(@"\\?\", StringComparison.Ordinal)) native = @"\\?\" + native;
        // As in the private Cargo cache, FILE_LIST_DIRECTORY is required for
        // directory sharing exclusions; FILE_READ_ATTRIBUTES alone is not.
        SafeFileHandle handle = CreateFileW(native, directory ? 0x81u : 0x80000000u,
            directory ? 3u : 1u, IntPtr.Zero, 3, 0x00200000u | 0x02000000u, IntPtr.Zero);
        if (handle.IsInvalid) {
            int error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new Win32Exception(error, "Cannot hold native build launcher path: " + path);
        }
        try {
            FileInfo info;
            if (!GetFileInformationByHandle(handle, out info))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            if ((info.Attributes & (0x400u | 0x40u)) != 0 ||
                    ((info.Attributes & 0x10u) != 0) != directory || GetFileType(handle) != 1 ||
                    (!directory && info.Links != 1))
                throw new IOException("Linked or unexpected native build launcher path: " + path);
            return handle;
        } catch { handle.Dispose(); throw; }
    }
    public static SafeFileHandle[] HoldDirectory(string directory) {
        string path = Path.GetFullPath(directory);
        string root = Path.GetPathRoot(path);
        if (root == null || root.Length != 3 || root[1] != ':')
            throw new IOException("Native build launcher requires a local drive directory");
        List<SafeFileHandle> handles = new List<SafeFileHandle>();
        try {
            string current = root;
            handles.Add(HoldPath(current, true));
            foreach (string part in path.Substring(root.Length).Split(
                    new char[] { '\\', '/' }, StringSplitOptions.RemoveEmptyEntries)) {
                current = Path.Combine(current, part);
                handles.Add(HoldPath(current, true));
            }
            return handles.ToArray();
        } catch {
            foreach (SafeFileHandle handle in handles) handle.Dispose();
            throw;
        }
    }
    public static FileStream OpenPayload(string path) {
        SafeFileHandle handle = HoldPath(path, false);
        try { return new FileStream(handle, FileAccess.Read); }
        catch { handle.Dispose(); throw; }
    }
    public static string BuildCommand(string application, string script) {
        char[] forbidden = new char[] { '\0', '"', '\r', '\n' };
        if (String.IsNullOrEmpty(application) || String.IsNullOrEmpty(script) ||
                application.IndexOfAny(forbidden) >= 0 || script.IndexOfAny(forbidden) >= 0 ||
                application.EndsWith("\\", StringComparison.Ordinal) ||
                script.EndsWith("\\", StringComparison.Ordinal))
            throw new ArgumentException("Invalid native build executable or script path");
        string command = "\"" + application + "\" -NoProfile -NonInteractive -File \"" + script + "\"";
        if (command.Length >= 32767)
            throw new ArgumentException("Native build file command exceeds the Windows process limit");
        return command;
    }
    static IntPtr InheritableStandardHandle(int kind) {
        IntPtr handle = GetStdHandle(kind);
        if (handle == IntPtr.Zero || handle == new IntPtr(-1) ||
                !SetHandleInformation(handle, 1, 1))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        return handle;
    }
    public static int Run(string application, string script, int seconds) {
        string command = BuildCommand(application, script);
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
            if (!CreateProcess(application, new StringBuilder(command), IntPtr.Zero,
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
    # The child gets a held file, never a payload-sized CreateProcess argument.
    printf '$dsrBuildScript='\''%s'\''\n' "$script_quoted"
    cat <<'POWERSHELL'
$dsrBuildDirectoryHandles=@()
$dsrBuildHeld=$null
$dsrBuildHash=$null
$dsrPowerShell=Join-Path $PSHOME 'powershell.exe'
if (-not (Test-Path -LiteralPath $dsrPowerShell -PathType Leaf)) { $dsrPowerShell=Join-Path $PSHOME 'pwsh.exe' }
try {
    if ([string]::IsNullOrEmpty($PSScriptRoot)) { throw 'Native build guard requires its retained launcher directory' }
    $dsrBuildDirectoryHandles=[DSRNativeBuildGuard]::HoldDirectory($PSScriptRoot)
    $dsrBuildPath=Join-Path $PSScriptRoot 'payload.ps1'
    $dsrBuildEncoding=[Text.UTF8Encoding]::new($true)
    $dsrBuildBytes=$dsrBuildEncoding.GetPreamble() + $dsrBuildEncoding.GetBytes($dsrBuildScript)
    $dsrBuildWriter=[IO.File]::Open($dsrBuildPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try {
        $dsrBuildWriter.Write($dsrBuildBytes,0,$dsrBuildBytes.Length)
        $dsrBuildWriter.Flush($true)
    } finally { $dsrBuildWriter.Dispose() }
    # Keep the normal scanner policy. Permit quarantine before opening the
    # read-only custody handle; changed or missing bytes then fail admission.
    $dsrBuildScanner=Join-Path $env:ProgramFiles 'Windows Defender/MpCmdRun.exe'
    if (Test-Path -LiteralPath $dsrBuildScanner) {
        & $dsrBuildScanner -Scan -ScanType 3 -File $dsrBuildPath
        if ($LASTEXITCODE -ne 0) { throw 'Native build payload security scan failed' }
    }
    $dsrBuildHeld=[DSRNativeBuildGuard]::OpenPayload($dsrBuildPath)
    $dsrBuildHash=[Security.Cryptography.SHA256]::Create()
    $dsrBuildExpected=[Convert]::ToBase64String($dsrBuildHash.ComputeHash([byte[]]$dsrBuildBytes))
    $dsrBuildActual=[Convert]::ToBase64String($dsrBuildHash.ComputeHash($dsrBuildHeld))
    if ($dsrBuildActual -cne $dsrBuildExpected) { throw 'Native build payload digest mismatch' }
    [Console]::Error.WriteLine('Native build payload retained: ' + $dsrBuildPath)
POWERSHELL
    printf '    exit [DSRNativeBuildGuard]::Run($dsrPowerShell, $dsrBuildPath, %s)\n' "$timeout_sec"
    cat <<'POWERSHELL'
} finally {
    if ($null -ne $dsrBuildHash) { $dsrBuildHash.Dispose() }
    if ($null -ne $dsrBuildHeld) { $dsrBuildHeld.Dispose() }
    foreach ($dsrBuildDirectoryHandle in $dsrBuildDirectoryHandles) { $dsrBuildDirectoryHandle.Dispose() }
}
POWERSHELL
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
    local remote_parent remote_parent_q remote_dir_q remote_script_q
    destination=$(_act_get_ssh_destination "$host") || return 4
    uuid=$(_act_generate_uuid) || return 4
    _act_is_uuid "$uuid" || return 4
    source_root="${source_root//\\//}"
    if [[ "$source_root" =~ ^/([A-Za-z])/(.*)$ ]]; then
        source_root="${BASH_REMATCH[1]}:/${BASH_REMATCH[2]}"
    fi
    [[ "$source_root" =~ ^[A-Za-z]:/ && "$source_root" != *[[:cntrl:]]* ]] || return 4
    while [[ "$source_root" == */ && ${#source_root} -gt 3 ]]; do source_root="${source_root%/}"; done
    remote_parent="${source_root%/*}"
    [[ ! "$remote_parent" =~ ^[A-Za-z]:$ ]] || remote_parent+='/'
    remote_dir="${remote_parent%/}/launcher-$uuid"
    remote_script="$remote_dir/build.ps1"
    remote_parent_q="${remote_parent//\'/\'\'}"
    remote_dir_q="${remote_dir//\'/\'\'}"
    remote_script_q="${remote_script//\'/\'\'}"
    mkdir -p "$ACT_ARTIFACTS_DIR" || return 4
    local_dir=$(mktemp -d "$ACT_ARTIFACTS_DIR/windows-launcher.XXXXXXXX") || return 4
    local_script="$local_dir/build.ps1"
    (umask 077; printf '%s\n' "$script" > "$local_script") || return 4
    digest=$(_act_sha256 "$local_script") || return 4
    setup="\$ErrorActionPreference='Stop'; \$parent=Get-Item -LiteralPath '$remote_parent_q' -Force; if (-not \$parent.PSIsContainer -or ((\$parent.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'Launcher parent is not a plain directory' }; if (Test-Path -LiteralPath '$remote_dir_q') { throw 'Launcher destination already exists' }; New-Item -ItemType Directory -Path '$remote_dir_q' | Out-Null; \$acl=Get-Acl -LiteralPath '$remote_dir_q'; \$acl.SetAccessRuleProtection(\$true,\$false); \$user=[Security.Principal.WindowsIdentity]::GetCurrent().User; \$rule=[Security.AccessControl.FileSystemAccessRule]::new(\$user,'FullControl','ContainerInherit,ObjectInherit','None','Allow'); \$acl.AddAccessRule(\$rule); Set-Acl -LiteralPath '$remote_dir_q' -AclObject \$acl"
    setup+="; \$system=[Security.Principal.SecurityIdentifier]::new('S-1-5-18'); \$systemRule=[Security.AccessControl.FileSystemAccessRule]::new(\$system,'FullControl','ContainerInherit,ObjectInherit','None','Allow'); \$acl.AddAccessRule(\$systemRule); Set-Acl -LiteralPath '$remote_dir_q' -AclObject \$acl"
    _act_ssh_exec "$host" "$(_act_windows_encoded_powershell "$setup" pwsh)" 60 >&2 || return 4
    scp -q -o ConnectTimeout="$_ACT_SSH_TIMEOUT" -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new "$local_script" "$destination:$remote_script" >&2 || return 4
    # A normal custom scan retains Defender policy; no exclusion, policy
    # bypass, or restoration of quarantined content is permitted here.
    guard="\$ErrorActionPreference='Stop'; \$item=Get-Item -LiteralPath '$remote_script_q' -Force; if (\$item.PSIsContainer -or ((\$item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'Launcher is not a plain file' }; \$scanner=Join-Path \$env:ProgramFiles 'Windows Defender/MpCmdRun.exe'; if (Test-Path -LiteralPath \$scanner) { & \$scanner -Scan -ScanType 3 -File \$item.FullName | ForEach-Object { [Console]::Error.WriteLine(\$_) }; if (\$LASTEXITCODE -ne 0) { throw 'Launcher security scan failed' } }; \$held=[IO.File]::Open('$remote_script_q',[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read); try { \$actual=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(\$held)); if (\$actual -ne '$digest') { throw 'Launcher digest mismatch' }; & '$remote_script_q'; exit \$LASTEXITCODE } finally { \$held.Dispose() }"
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

# Parse the host-specific receiver mount convention without conflating an
# absent setting with MSYS2's deliberately empty drive prefix. Keep the host
# name as jq data, never as part of an executable filter expression.
_act_windows_rsync_prefix_from_json() {
    local host="${1:-}" configuration="${2:-}"
    [[ -n "$host" ]] || return 4
    jq -ers --arg host "$host" '
        if length != 1 or (.[0] | type) != "object" then
            error("expected one hosts configuration object")
        else .[0] end |
        if (.hosts | type) != "object" then
            error("hosts must be an object")
        else .hosts[$host] end |
        if . == null then "/cygdrive"
        elif type != "object" then error("host configuration must be an object")
        elif has("windows_rsync_drive_prefix") then
            .windows_rsync_drive_prefix |
            if type == "string" then .
            else error("windows_rsync_drive_prefix must be a string") end
        else "/cygdrive" end |
        if . == "" then .
        elif test("^/[A-Za-z0-9_.+-]+(/[A-Za-z0-9_.+-]+)*$") and
             (split("/") | all(.[]; . != "." and . != "..")) then .
        else error("windows_rsync_drive_prefix must be empty or a canonical absolute POSIX prefix") end
    ' <<< "$configuration" || return 4
}

# Pure conversion. /cygdrive remains the default for existing Cygwin hosts;
# an explicitly empty second argument selects /c/... as used by MSYS2.
_act_windows_rsync_path() {
    local path="${1:-}" prefix="${2-/cygdrive}"
    # Validate direct callers as well as hosts.yaml-derived values. Never put
    # a configured shell fragment or traversal component into an rsync path.
    if [[ -n "$prefix" ]]; then
        if [[ ! "$prefix" =~ ^/[A-Za-z0-9_.+-]+(/[A-Za-z0-9_.+-]+)*$ ]]; then
            return 4
        fi
        case "$prefix/" in */./*|*/../*) return 4 ;; esac
    fi
    [[ -n "$path" && "$path" != *[[:cntrl:]]* ]] || return 4
    path="${path//\\//}"

    if [[ "$path" =~ ^([A-Za-z]):/(.*)$ ]]; then
        local drive="${BASH_REMATCH[1],,}"
        local rest="${BASH_REMATCH[2]}"
        printf '%s/%s/%s\n' "$prefix" "$drive" "$rest"
        return 0
    fi

    if [[ "$path" =~ ^([A-Za-z]):$ ]]; then
        local drive="${BASH_REMATCH[1],,}"
        printf '%s/%s\n' "$prefix" "$drive"
        return 0
    fi

    # Already-POSIX paths are not prefixed again. A remaining drive-relative
    # spelling is ambiguous (C:foo is not C:/foo), so refuse it explicitly.
    [[ ! "$path" =~ ^[A-Za-z]: ]] || return 4
    printf '%s\n' "$path"
}

# Resolve once for each source transfer, before its bounded rsync retry loop.
# Use the shared single-document/duplicate-key YAML gate. We do not
# persist a cache that could outlive a hosts.yaml change or another host's
# runtime selection. Unconfigured hosts retain the historical Cygwin default.
_act_windows_rsync_host_path() {
    local host="${1:-}" path="${2:-}" prefix=/cygdrive configuration
    [[ -n "$host" ]] || return 4
    if [[ -n "${DSR_HOSTS_FILE:-}" &&
          ( -e "$DSR_HOSTS_FILE" || -L "$DSR_HOSTS_FILE" ) ]]; then
        if [[ ! -f "$DSR_HOSTS_FILE" || -L "$DSR_HOSTS_FILE" ]]; then
            _log_error "Windows rsync requires a regular hosts configuration: $DSR_HOSTS_FILE"
            return 4
        fi
        if ! command -v yq >/dev/null || ! command -v jq >/dev/null; then
            _log_error "Windows rsync host configuration requires yq and jq"
            return 3
        fi
        if ! declare -F _config_read_single_mapping_json >/dev/null; then
            # shellcheck source=src/config.sh
            source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh" || return 3
        fi
        if ! configuration=$(_config_read_single_mapping_json "$DSR_HOSTS_FILE") ||
           ! prefix=$(_act_windows_rsync_prefix_from_json "$host" "$configuration"); then
            _log_error "Invalid windows_rsync_drive_prefix configuration for host: $host"
            return 4
        fi
    fi
    if ! _act_windows_rsync_path "$path" "$prefix"; then
        _log_error "Invalid Windows rsync receiver path for host: $host"
        return 4
    fi
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

# Git's ignore language is not rsync's filter language. Ask Git which
# untracked paths it actually ignores, then emit anchored literal rsync
# exclusions. Tracked inputs remain transferable even inside ignored parents;
# nested/global/info excludes and negations are evaluated by Git itself.
_act_git_sync_excludes() {
    local ignored_path
    git -C "$1" ls-files --others --ignored --exclude-standard --directory -z |
        while IFS= read -r -d '' ignored_path; do
            # rsync interprets backslash escapes only in wildcard patterns.
            # Escape it only when a literal glob character enables that mode.
            case "$ignored_path" in *\**|*\?*|*\[*)
                ignored_path="${ignored_path//\\/\\\\}"
                ignored_path="${ignored_path//\*/\\*}"
                ignored_path="${ignored_path//\?/\\?}"
                ignored_path="${ignored_path//\[/\\[}"
                ;;
            esac
            printf '/%s\0' "$ignored_path" || return 1
        done
}

# A receiver must own its source root and existing Git administration. Do not
# repair an operator checkout with chown or override Git's safe.directory
# policy: a prior root rsync may have imported a controller-only numeric UID.
# The same POSIX program runs locally and through the Unix SSH login shell.
_act_source_sync_prepare_sh() {
    local source_path="$1"
    printf "dsr_source_path='%s'\n" "${source_path//\'/\'\\\'\'}"
    cat <<'SH'
dsr_source_uid=$(id -u) || exit 4
for dsr_source_entry in "$dsr_source_path" "$dsr_source_path/.git"; do
    if [ -e "$dsr_source_entry" ] || [ -L "$dsr_source_entry" ]; then
        if [ -L "$dsr_source_entry" ]; then
            printf '[act] Refusing source sync through symlink: %s\n' "$dsr_source_entry" >&2
            exit 4
        fi
        dsr_source_owner=$(stat -c %u -- "$dsr_source_entry" 2>/dev/null) ||
            dsr_source_owner=$(stat -f %u "$dsr_source_entry" 2>/dev/null) || {
                printf '[act] Cannot verify source ownership: %s\n' "$dsr_source_entry" >&2
                exit 4
            }
        if [ "$dsr_source_owner" != "$dsr_source_uid" ]; then
            printf '[act] Source ownership mismatch: %s belongs to UID %s; build account uses UID %s. Use a fresh owned source stage or repair this checkout before retrying.\n' \
                "$dsr_source_entry" "$dsr_source_owner" "$dsr_source_uid" >&2
            exit 4
        fi
    fi
done
mkdir -p -- "$dsr_source_path" || exit 4
SH
}

# Sync source code to remote host via rsync
# Usage: _act_sync_source <host> <local_path> <remote_path> [extra_excludes...]
# Returns: 0 on success, non-zero on failure
_act_sync_source() (
    local host="$1"
    local local_path="$2"
    local remote_path="$3"
    shift 3
    local respect_gitignore_excludes=true
    local extra_excludes=()
    local git_excludes=""
    # The subshell confines cleanup to this transfer, including early returns
    # and retries, without replacing the caller's traps or changing its cwd.
    trap '[[ -z "$git_excludes" ]] || rm -f -- "$git_excludes"' EXIT

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

    # Preserve ordinary rsync traversal/deletion semantics. A --files-from
    # inventory changes recursion and receiver cleanup; literal ignored-path
    # exclusions retain both while avoiding gitignore/rsync syntax confusion.
    if $respect_gitignore_excludes; then
        if [[ "$(git -C "$local_path" rev-parse --is-inside-work-tree 2>/dev/null)" == true ]]; then
            git_excludes=$(mktemp "${TMPDIR:-/tmp}/dsr-source-excludes.XXXXXXXX") || {
                _log_error "Could not reserve Git source selection for $local_path"
                return 4
            }
            if ! _act_git_sync_excludes "$local_path" > "$git_excludes"; then
                _log_error "Could not enumerate Git source exclusions for $local_path"
                return 4
            fi
            exclude_args+=(--from0 "--exclude-from=$git_excludes")
        else
            # Plain source directories have no Git index to distinguish
            # tracked inputs. Preserve their existing exclusion behavior.
            if [[ -f "$local_path/.gitignore" ]]; then
                exclude_args+=("--exclude-from=$local_path/.gitignore")
            fi
            local global_excludes_file
            global_excludes_file=$(git config --path --get core.excludesFile 2>/dev/null || true)
            if [[ -z "$global_excludes_file" ]]; then
                global_excludes_file="${XDG_CONFIG_HOME:-$HOME/.config}/git/ignore"
            fi
            if [[ -f "$global_excludes_file" ]] && \
               ! grep -q '^!' "$global_excludes_file" 2>/dev/null; then
                exclude_args+=("--exclude-from=$global_excludes_file")
            fi
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

        local prepare_command
        prepare_command=$(_act_source_sync_prepare_sh "$remote_path") || return 4
        sh -c "$prepare_command" || return 4
        local sync_cmd_output sync_cmd_status
        # Equal size and timestamp do not prove equal source bytes (for
        # example, rapid checkouts or restored timestamps). A successful sync
        # must replace those stale files before the host becomes buildable.
        # Keep modes, links, timestamps and byte comparison; numeric ownership
        # belongs to the receiving build account, not the controller machine.
        sync_cmd_output=$(_act_run_with_timeout "$_ACT_SYNC_TIMEOUT" rsync -az --no-owner --no-group --checksum --delete \
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
        local rsync_remote_path="$remote_path"
        local -a rsync_io_opts=()
        local rsync_transport="ssh -o ConnectTimeout=$_ACT_SSH_TIMEOUT -o StrictHostKeyChecking=accept-new"
        if _act_is_windows_host "$host"; then
            # Resolve the receiver's configured mount convention before
            # creating directories or transferring any source bytes.
            rsync_remote_path=$(_act_windows_rsync_host_path "$host" "$remote_path") || return $?
            # Windows OpenSSH plus rsync's non-blocking socket writes fail with
            # "safe_write ... Resource temporarily unavailable (11)" (exit 12)
            # when the transport is a multiplexed ControlMaster channel. Use
            # blocking I/O on a dedicated connection for Windows receivers.
            rsync_io_opts=(--blocking-io)
            rsync_transport+=" -o ControlMaster=no -o ControlPath=none"
        fi

        # rsync does not create the destination's parent directories, so make
        # sure the full remote path exists first (mirrors the local-host and
        # tar-fallback branches). Without this, a missing per-version parent dir
        # makes the whole sync fail with "No such file or directory".
        if _act_is_windows_host "$host"; then
            if ! _act_remote_mkdir "$host" "$remote_path"; then
                _log_error "failed to create remote directory $remote_path on $host"
                return 1
            fi
        else
            local prepare_command
            prepare_command=$(_act_source_sync_prepare_sh "$remote_path") || return 4
            if ! _act_run_with_timeout "$_ACT_SYNC_TIMEOUT" ssh -n \
                -o ConnectTimeout="$_ACT_SSH_TIMEOUT" -o StrictHostKeyChecking=accept-new \
                "$ssh_destination" "$prepare_command"; then
                _log_error "failed to prepare owned source directory $remote_path on $host"
                return 1
            fi
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
            sync_cmd_output=$(_act_run_with_timeout "$_ACT_SYNC_TIMEOUT" rsync -az --no-owner --no-group --checksum --delete \
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
        local remote_extract_cmd
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
            remote_extract_cmd=$(_act_source_sync_prepare_sh "$remote_path") || return 4
            # GNU tar and macOS bsdtar otherwise restore archive UIDs when
            # the receiving SSH account is root, just as rsync -a does.
            remote_extract_cmd+=$'\n''tar --no-same-owner -xzf - -C "$dsr_source_path"'
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
)

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

# Describe Unix write locations as data, never by evaluating recipe text in a
# coordinator shell. The final launcher applies the last environment assignment.
# Relative settings belong to the build's actual working directory, not to the
# coordinator or the original checkout. Source planning has no final per-target
# working directory yet, so that phase admits absolute overrides only; native
# preparation admits the complete, resolved set before creating its private home.
_act_native_writable_paths_json() {
    local source_root="$1" working_root="$2" build_env="$3" language="$4"
    local cache_root="${5:-}" extra_paths="${6:-[]}" absolute_only="${7:-false}"
    jq -nce --arg source "$source_root" --arg working "$working_root" \
        --arg environment "$build_env" --arg language "$language" \
        --arg cache "$cache_root" --argjson extra "$extra_paths" \
        --argjson absolute_only "$absolute_only" '
        def literal:
            . as $path | type == "string" and length > 0 and
            all(explode[]; . >= 32 and . != 127) and
            (["$","`","\\","\""] | all(.[]; . as $char | ($path | contains($char) | not)));
        def absolute:
            literal and startswith("/");
        if ($source | absolute | not) or ($working | absolute | not) or
           ($extra | type != "array") then error("Invalid native writable roots") else . end |
        (reduce ($environment | split("\n")[] | select(contains("="))) as $pair ({};
            ($pair | index("=")) as $equals |
            .[$pair[:$equals]] = $pair[$equals + 1:])) as $env |
        [{role:"source",path:$source}] + $extra +
        (if $working != $source then [{role:"stage",path:$working}] else [] end) +
        (if $cache != "" then [{role:"cargo_cache",path:$cache}] else [] end) +
        ([{role:"temp",name:"TMPDIR"}] +
          (if $language == "rust" then
            [{role:"cargo_home",name:"CARGO_HOME"},
             {role:"cargo_target",name:"CARGO_TARGET_DIR"},
             {role:"cargo_build",name:"CARGO_BUILD_BUILD_DIR"}]
           elif $language == "go" then
            # Even GOENV=off retains GOROOT/go.env defaults on the build host.
            # Admit explicit recipe locations without guessing those defaults.
            [{role:"go_cache",name:"GOCACHE",absolute_required:true,empty_default:true},
             {role:"go_modcache",name:"GOMODCACHE",absolute_required:true,empty_default:true},
             {role:"go_temp",name:"GOTMPDIR",empty_default:true}]
           else [] end) | map(. as $entry | $env[.name] // empty |
              if $entry.empty_default and . == "" then empty
              elif $entry.name == "GOCACHE" and . == "off" then
                  error("GOCACHE=off disables the build cache required by Go")
              elif $absolute_only and $entry.name == "CARGO_TARGET_DIR" and (startswith("/") | not) then
                 empty
             elif literal | not then error("Unresolved native writable environment path: " + $entry.name)
             elif $entry.name == "CARGO_BUILD_BUILD_DIR" and (test("[{}]")) then
                 error("Cargo build-directory templates require resolved writable paths")
              elif $entry.absolute_required and (startswith("/") | not) then
                  error($entry.name + " must be an absolute Go cache path")
             elif startswith("/") then {role:$entry.role,path:.}
             elif $absolute_only then empty
             else {role:$entry.role,path:($working + "/" +
                    (split("/") | map(select(. != "." and . != "")) | join("/")))} end)) |
        if all(.[]; (.path | absolute)) then unique_by([.role,.path])
        else error("Invalid native writable path") end
    ' || return 4
}

# Keep the general host gate, then require fresh evidence for the selected
# paths. Windows has a separate split-storage contract and does not consume
# these Unix path observations.
_act_native_writable_paths_ready() {
    local host="$1" capability="$2" paths="$3"
    local readiness_args=("$host" --writable-paths "$paths")
    [[ -z "$capability" ]] || readiness_args+=(--require "$capability")
    if ! declare -F host_health_is_ready &>/dev/null ||
       ! host_health_is_ready "${readiness_args[@]}"; then
        _log_error "Native writable paths are not ready on $host"
        return 4
    fi
}

_act_source_has_gitlinks() {
    local listing
    listing=$(_act_strict_git -C "$1" ls-tree -r --full-tree "$2" 2>/dev/null) || return 4
    [[ "$listing" == '160000 commit '* || "$listing" == *$'\n160000 commit '* ]]
}

_act_source_archive_export() {
    local repo_path="$1" revision="$2" kind="$3" module_dir commit
    module_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || return 4
    # shellcheck source=src/xwin_source.sh
    source "$module_dir/xwin_source.sh" || return 3
    commit=$(_act_strict_git -C "$repo_path" rev-parse --verify "${revision}^{commit}" 2>/dev/null) || return 4
    if [[ "$kind" == compare ]]; then
        source_archive_matches_git "$repo_path" "$commit"
    else
        source_archive_export "$repo_path" "$commit" "$kind"
    fi
}

_act_stream_git_archive() {
    local status=0
    _act_source_has_gitlinks "$1" "$2" || status=$?
    case "$status" in
        0) _act_source_archive_export "$1" "$2" archive ;;
        1)
            # Keep every already-admitted legacy archive byte-identical.
            # Attribute declarations alone do not imply a changed tree: an
            # export-subst file without a token still has its committed bytes.
            status=0
            _act_source_archive_export "$1" "$2" compare || status=$?
            case "$status" in
                0) _act_strict_git -C "$1" archive --format=tar "$2" 2>/dev/null ;;
                10) _act_source_archive_export "$1" "$2" archive ;;
                *) return "$status" ;;
            esac
            ;;
        *) return "$status" ;;
    esac
}

_act_git_archive_sha256() {
    local repo_path="$1"
    local revision="$2"

    if command -v sha256sum &>/dev/null; then
        (set -o pipefail; _act_stream_git_archive "$repo_path" "$revision" | sha256sum | awk '{print $1}')
    elif command -v shasum &>/dev/null; then
        (set -o pipefail; _act_stream_git_archive "$repo_path" "$revision" | shasum -a 256 | awk '{print $1}')
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
        _act_stream_git_archive "$repo_path" "$revision" >&9 || exit 4
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
    local repository_root="${4:-$root_path}" component cursor="$root_path" gitlink
    local -a parts=()
    local -a gitlink_roots=()
    if [[ $# -gt 4 ]]; then gitlink_roots=("${@:5}"); fi

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
        [[ -d "$cursor" && ! -L "$cursor" ]] || return 1
        case "$component" in
            ""|.) ;;
            ..)
                [[ "$cursor" != "$repository_root" ]] || return 1
                cursor="${cursor%/*}"
                ;;
            *)
                cursor="$cursor/$component"
                [[ ! -L "$cursor" ]] || return 1
                for gitlink in "${gitlink_roots[@]}"; do
                    [[ "$cursor" != "$gitlink" || "$cursor" == "$repository_root" ]] || return 1
                done
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
        local kind gitlink_status=0
        set -C
        umask 077
        exec 9> "$output_file" || exit 4
        descriptor_inode=$(_act_file_identity /dev/fd/9) || exit 4
        _act_source_has_gitlinks "$repo_path" "$revision" || gitlink_status=$?
        if [[ $gitlink_status -eq 0 ]]; then
            _act_source_archive_export "$repo_path" "$revision" manifest >&9 || exit 4
            chmod 600 /dev/fd/9 || exit 4
            path_inode=$(_act_file_identity "$output_file") || exit 4
            [[ -s /dev/fd/9 && -f "$output_file" && ! -L "$output_file" && \
               "$descriptor_inode" == "$path_inode" ]] || exit 4
            exec 9>&-
            exit 0
        elif [[ $gitlink_status -ne 1 ]]; then
            exit "$gitlink_status"
        fi
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
    local object_id mode relative_path parent expected_count actual_count
    local hashes expected_hashes hash_index link_target link_hash repository_root gitlink
    local -a hash_paths=() hash_ids=() hash_modes=()
    local -a gitlink_roots=()

    if [[ ! -d "$root_path" || -L "$root_path" ]] || \
       ! expected_count=$(_act_tracked_manifest_object_count "$manifest_file"); then
        return 4
    fi

    while IFS=$'\t' read -r object_id mode relative_path; do
        [[ "$mode" != "160000" ]] || gitlink_roots+=("$root_path/$relative_path")
    done < "$manifest_file"
    while IFS=$'\t' read -r object_id mode relative_path; do
        [[ "$object_id" =~ ^[0-9a-f]{40}$ && \
           ( "$mode" == "100644" || "$mode" == "100755" || "$mode" == "120000" || \
             "$mode" == "160000" ) && \
           "$relative_path" =~ ^[][A-Za-z0-9_./+@~#,=()\ -]+$ && \
           "$relative_path" != *..* && "$relative_path" != /* ]] || return 4
        if [[ "$mode" == "160000" ]]; then
            # Descendants are individually authenticated manifest rows. The
            # final exact node count also rejects any unlisted child contents.
            if [[ ! -d "$root_path/$relative_path" || -L "$root_path/$relative_path" ]]; then
                return 4
            fi
        elif [[ "$mode" == "120000" ]]; then
            # The link itself is the tracked object: its target string must
            # hash to the committed blob and stay inside the snapshot.
            [[ -L "$root_path/$relative_path" ]] || return 4
            link_target=$(readlink "$root_path/$relative_path") || return 4
            repository_root="$root_path"
            for gitlink in "${gitlink_roots[@]}"; do
                if [[ "$root_path/$relative_path" == "$gitlink"/* && ${#gitlink} -gt ${#repository_root} ]]; then
                    repository_root="$gitlink"
                fi
            done
            _act_strict_symlink_target_is_contained "$root_path" "$relative_path" "$link_target" \
                "$repository_root" "${gitlink_roots[@]}" || return 4
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

# A private controller checkout must not let Cargo resolve a configured
# absolute dependency back into the developer's original checkout. Parse
# committed manifests, including ignored/hidden ones, so quoted keys and
# escaped or multiline TOML strings have the same meaning as they do to Cargo.
_act_validate_isolated_cargo_paths() {
    local source="$1" manifest document
    while IFS= read -r -d '' manifest; do
        case "$manifest" in
            Cargo.toml|*/Cargo.toml|.cargo/config|*/.cargo/config|.cargo/config.toml|*/.cargo/config.toml) ;;
            *) continue ;;
        esac
        if [[ -L "$source/$manifest" ]] ||
           ! document=$(yq -p=toml -o=json -I=0 '.' "$source/$manifest" 2>/dev/null) ||
           ! jq -es '
                length == 1 and
                all(.[0] | .. | objects | to_entries[] |
                    select(.key == "path" or .key == "paths" or .key == "members" or .key == "default-members") |
                    .value | .. | strings;
                    (test("^([/\\\\]|[A-Za-z]:)") | not))
            ' <<< "$document" >/dev/null; then
            _log_error "Isolated Cargo source requires relative paths and TOML-capable yq: $manifest"
            return 4
        fi
    done < <(_git_ops_build_git -C "$source" ls-files -z)
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
            main_package_count=$((main_package_count + 1))
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

# Transport the same lockfile authentication gate used by xwin. Full metadata
# and source inventories stay on the host; only their hashes cross back to the
# coordinator. Every evidence read rejects linked files and linked ancestors.
_act_unix_cargo_sources_runtime() (
    local module
    module="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cargo_sources.sh"
    [[ -f "$module" && ! -L "$module" ]] || return 3
    # shellcheck source=src/cargo_sources.sh
    source "$module" || return 3
    declare -f _cargo_sources
    cat <<'SH'
_dsr_cargo_sources_hash() {
    python3 -I - "$@" <<'DSR_CARGO_SOURCE_HASH'
import hashlib, os, stat, sys
path = sys.argv[1]
if not path.startswith('/') or any(part in ('', '.', '..') for part in path[1:].split('/')):
    sys.exit('noncanonical Cargo dependency evidence path')
parent = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
try:
    parts = path[1:].split('/')
    for part in parts[:-1]:
        child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
        os.close(parent)
        parent = child
    fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    with os.fdopen(fd, 'rb') as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            sys.exit('Cargo dependency evidence is not a private regular file')
        digest = hashlib.sha256()
        for block in iter(lambda: stream.read(1048576), b''):
            digest.update(block)
        identity = lambda info: (info.st_dev, info.st_ino, info.st_mode, info.st_size,
                                 info.st_mtime_ns, info.st_ctime_ns, info.st_nlink)
        if (identity(before) != identity(os.fstat(stream.fileno())) or
                identity(before) != identity(os.stat(parts[-1], dir_fd=parent, follow_symlinks=False))):
            sys.exit('Cargo dependency evidence changed while reading')
        value = digest.hexdigest()
        if len(sys.argv) == 3 and value != sys.argv[2]:
            sys.exit('Cargo dependency evidence differs from coordinator-held authority')
        print(value)
finally:
    os.close(parent)
DSR_CARGO_SOURCE_HASH
}
SH
)

_act_validate_cargo_sources_summary() {
    jq -ce '
        def count: type == "number" and . >= 0 and floor == .;
        select(type == "object" and .schema_version == 1 and
            .kind == "dsr-cargo-dependency-sources" and
            ([.sha256, .metadata_sha256, .authentication.lockfile_sha256] |
                all(type == "string" and test("^[0-9a-f]{64}$"))) and
            ([.package_count, .root_count, .file_count, .size_bytes,
              .authentication.locked_archive_packages, .authentication.locked_git_packages,
              .authentication.workspace_snapshot_packages] | all(count)) and
            .root_count <= .package_count and
            (.authentication.locked_archive_packages + .authentication.locked_git_packages +
                .authentication.workspace_snapshot_packages) == .package_count)
    ' <<< "$1"
}

# Validate host preparation evidence again at compiler admission. The selected
# downloads must name the same lockfile as the authenticated dependency sources.
_act_validate_cargo_cache_selection() {
    jq -ce --argjson sources "$2" '
        .selection | select(type == "object" and
            keys == ["git_revisions", "kind", "lockfile_sha256", "registry_packages"] and
            .kind == "cargo-lock-downloads" and
            (.lockfile_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
            .lockfile_sha256 == $sources.authentication.lockfile_sha256 and
            (.registry_packages | type == "number" and . >= 0 and . <= 10000 and floor == .) and
            (.git_revisions | type == "array" and length <= 10000 and
                all(.[]; type == "string" and test("^[0-9a-f]{40}$")) and . == unique))
    ' <<< "$1"
}

# A remote sidecar cannot authorize its own replacement. Check both held file
# hashes around source verification and compare the verifier's newly observed
# evidence hash as well. This runs before compilation and in an independent
# post-build invocation, so a configured command using exit/exec cannot skip it.
_act_unix_cargo_sources_verify_script() {
    local source_root="$1" cargo_home="$2" sources_json="$3" metadata_digest sources_digest path
    for path in "$source_root" "$cargo_home"; do
        [[ "$path" =~ ^/[A-Za-z0-9_./+-]+$ && "$path" != *..* ]] || return 4
    done
    sources_json=$(_act_validate_cargo_sources_summary "$sources_json") || return 4
    metadata_digest=$(jq -er '.metadata_sha256' <<< "$sources_json") || return 4
    sources_digest=$(jq -er '.sha256' <<< "$sources_json") || return 4
    printf 'set -e\n'
    _act_unix_cargo_sources_runtime || return $?
    cat <<EOF
dsr_source_root=\$(cd '$source_root' && pwd -P)
_dsr_cargo_sources_hash '$cargo_home/.dsr-cargo-metadata.json' '$metadata_digest' >/dev/null
_dsr_cargo_sources_hash '$cargo_home/.dsr-cargo-sources.json' '$sources_digest' >/dev/null
dsr_verified_sources=\$(_cargo_sources verify-workspace '$cargo_home/.dsr-cargo-metadata.json' '$cargo_home/.dsr-cargo-sources.json' "\$dsr_source_root/Cargo.lock")
python3 -I - "\$dsr_verified_sources" '$sources_digest' <<'DSR_CARGO_SOURCE_AUTHORITY'
import json, sys
if json.loads(sys.argv[1])['sha256'] != sys.argv[2]:
    sys.exit('Cargo dependency sources differ from coordinator-held authority')
DSR_CARGO_SOURCE_AUTHORITY
_dsr_cargo_sources_hash '$cargo_home/.dsr-cargo-metadata.json' '$metadata_digest' >/dev/null
_dsr_cargo_sources_hash '$cargo_home/.dsr-cargo-sources.json' '$sources_digest' >/dev/null
EOF
}

# The canonical home retains only downloads selected by the admitted lockfile:
# Cargo never writes to it. Metadata and every target attempt receive independent
# inodes and recreate their own authenticated source trees. Resume can verify its
# seed after the ambient cache disappears, without importing unrelated packages
# or letting normal unpacking race another target's cache inventory.
_act_unix_private_cargo_home_script() {
    local source_root="$1" suffix="$2"
    # Shell ranges follow LC_COLLATE: en_US.UTF-8 can otherwise admit non-ASCII
    # letters in these path components. Keep the wire/path allowlist literal.
    local LC_ALL=C || {
        _log_error "Unable to select ASCII validation locale for strict Unix Cargo paths"
        return 4
    }
    if [[ ! "$source_root" =~ ^/[A-Za-z0-9_./+-]+$ || "$source_root" == *..* ]]; then
        _log_error "Invalid strict Unix Cargo source root: expected an absolute source path using letters, digits, _, ., /, + or -, without '..'"
        return 4
    fi
    if [[ ! "$suffix" =~ ^[A-Za-z0-9][A-Za-z0-9_-]+$ ]]; then
        _log_error "Invalid strict Unix Cargo attempt suffix: require a leading letter or digit and at least one further letter, digit, _ or -"
        return 4
    fi
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
    dsr_private_summary=\$(_cargo_cache_run snapshot "\$dsr_seed_home" "\$strict_home" "\$physical_source_root/Cargo.lock")
    python3 -I - "\$dsr_seed_summary" "\$dsr_private_summary" <<'DSR_PRIVATE_CACHE_COMPARE'
import json, sys
seed, private = (json.loads(value) for value in sys.argv[1:])
if (seed['mode'] != 'private-copy' or private['mode'] != 'private-copy' or
        seed.get('selection', {}).get('kind') != 'cargo-lock-downloads' or
        seed.get('selection') != private.get('selection') or
        seed['inventory_sha256'] != private['inventory_sha256']):
    sys.exit('private Cargo cache seed or lockfile selection changed during preparation')
DSR_PRIVATE_CACHE_COMPARE
else
    # Do not publish an incomplete seed if offline metadata cannot resolve
    # yet. A later attempt can use repaired ambient downloads without ever
    # replacing an admitted seed or overwriting the failed private attempt.
    ambient_home=\${CARGO_HOME:-\$HOME/.cargo}
    if test ! -e "\$ambient_home" && test ! -L "\$ambient_home"; then ambient_home=; fi
    dsr_private_summary=\$(_cargo_cache_run snapshot "\$ambient_home" "\$strict_home" "\$physical_source_root/Cargo.lock")
    dsr_seed_pending=true
fi
_dsr_cargo_home_guard "\$strict_home"
EOF
}

_act_unix_cargo_metadata_body() {
    local build_cmd="${1-cargo build}" build_env="${2:-}" env_pair env_name
    _act_unix_cargo_sources_runtime || return $?
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
dsr_metadata_sha256=$(_dsr_cargo_sources_hash "$strict_home/.dsr-cargo-metadata.json")
dsr_dependency_sources=$(_cargo_sources capture-workspace "$strict_home/.dsr-cargo-metadata.json" "$strict_home/.dsr-cargo-sources.json" "$physical_source_root/Cargo.lock")
_dsr_cargo_sources_hash "$strict_home/.dsr-cargo-metadata.json" "$dsr_metadata_sha256" >/dev/null
dsr_dependency_sources=$(python3 -I - "$dsr_dependency_sources" "$dsr_metadata_sha256" <<'DSR_CARGO_SOURCE_SUMMARY'
import json, sys
summary = json.loads(sys.argv[1])
summary['metadata_sha256'] = sys.argv[2]
print(json.dumps(summary, sort_keys=True, separators=(',', ':')))
DSR_CARGO_SOURCE_SUMMARY
)
if $dsr_seed_pending; then
    _cargo_cache_run snapshot "$strict_home" "$dsr_seed_home" "$physical_source_root/Cargo.lock" >/dev/null
fi
SH
}

_act_prepare_unix_private_cargo_home() {
    local host="$1" source_root="$2" suffix="$3" command summary metadata_body sources_json
    local build_cmd="${4-cargo build}" build_env="${5:-}"
    command=$(_act_unix_private_cargo_home_script "$source_root" "$suffix") || return $?
    # An admitted download seed is reusable across targets, but its earlier
    # metadata result is not compiler authority for a new target/toolchain.
    metadata_body=$(_act_unix_cargo_metadata_body "$build_cmd" "$build_env") || return $?
    command+=$'\n'"$metadata_body"
    command+=$'\n'"$(cat <<'SH'
python3 -I - "$dsr_private_summary" "$dsr_dependency_sources" <<'DSR_NATIVE_CARGO_PREPARED'
import json, sys
summary = json.loads(sys.argv[1])
summary['dependency_sources'] = json.loads(sys.argv[2])
print(json.dumps(summary, sort_keys=True, separators=(',', ':')))
DSR_NATIVE_CARGO_PREPARED
SH
)"
    summary=$(_act_ssh_exec "$host" "$command" "$_ACT_SYNC_TIMEOUT") || {
        local prepare_status=$?
        _log_error "Strict Unix Cargo cache preparation failed on $host (exit $prepare_status)"
        return "$prepare_status"
    }
    if ! sources_json=$(jq -ce '.dependency_sources' <<< "$summary") ||
       ! _act_validate_cargo_sources_summary "$sources_json" >/dev/null; then
        _log_error "Strict Unix Cargo cache preparation returned invalid dependency-source evidence on $host"
        return 4
    fi
    # Physical parent paths can differ through legitimate source aliases, but
    # the home must belong to this attempt, never the retained seed or another
    # target. Do not publish partial/multiple transport receipts on refusal.
    if ! summary=$(jq -cse --arg name ".cargo-home-$suffix" '
        select(length == 1) | .[0] |
        select(type == "object" and .schema_version == 1 and .mode == "private-copy" and
            (.cargo_home | type == "string" and test("^/[A-Za-z0-9_./+-]+$") and
                (contains("..") | not) and endswith("/" + $name)) and
            .receipt_path == (.cargo_home + "/.dsr-cache-seed.json") and
            (.receipt_sha256 | test("^[0-9a-f]{64}$")) and
            (.inventory_sha256 | test("^[0-9a-f]{64}$")) and
            .selection.kind == "cargo-lock-downloads" and
            .selection.lockfile_sha256 == .dependency_sources.authentication.lockfile_sha256)
    ' <<< "$summary"); then
        _log_error "Strict Unix Cargo cache preparation returned invalid private attempt evidence on $host (expected .cargo-home-$suffix)"
        return 4
    fi
    printf '%s\n' "$summary"
}

# Ordinary (non-strict) Unix Rust builds stage their source under a fresh,
# unique stage root. Create that root here and give it a private copy of the
# ambient registry and Git download caches, so a cache prune or in-place write
# on the build host cannot reach a running build (issue #15). Cargo may still
# download missing dependencies into the private home. Prints the seed summary.
_act_prepare_unix_nonstrict_cargo_home() {
    local host="$1" isolation_root="$2" stage_root="$3" cargo_home="$4" source_root="${5:-}" command summary path
    # Paths are embedded in single quotes below; build roots may contain spaces.
    for path in "$isolation_root" "$stage_root" "$cargo_home"; do
        [[ "$path" == /* && "$path" != *"'"* && "$path" != *..* &&
           "$path" != *$'\n'* && "$path" != *$'\r'* ]] || return 4
    done
    if [[ -n "$source_root" ]]; then
        [[ "$source_root" == /* && "$source_root" != *"'"* && "$source_root" != *..* &&
           "$source_root" != *$'\n'* && "$source_root" != *$'\r'* ]] || return 4
    fi
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
# SBH honors ancestor markers for both scanning and direct deletion checks.
# Protect the private source/cache before copying any bytes; the existing
# all-outcome stage cleanup retires this marker with the owned stage. O_EXCL
# refuses every existing leaf, including a FIFO that shell noclobber can block on.
python3 -I - '$stage_root' <<'DSR_ORDINARY_STAGE_PROTECTION'
import os, stat, sys
parent = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
try:
    info = os.fstat(parent)
    if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o777 != 0o700:
        raise RuntimeError('ordinary build stage must be private and owned')
    fd = os.open('.sbh-protect', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                 0o600, dir_fd=parent)
    with os.fdopen(fd, 'w') as marker:
        marker.write('reason = "DSR ordinary native build stage"' + chr(10))
finally:
    os.close(parent)
DSR_ORDINARY_STAGE_PROTECTION
ambient_home=\${CARGO_HOME:-\$HOME/.cargo}
if test ! -e "\$ambient_home" && test ! -L "\$ambient_home"; then ambient_home=; fi
dsr_lockfile=
if test -n '$source_root'; then
    test -d '$source_root'; test ! -L '$source_root'
    if test -e '$source_root/Cargo.lock' || test -L '$source_root/Cargo.lock'; then
        test -f '$source_root/Cargo.lock'; test ! -L '$source_root/Cargo.lock'
        dsr_lockfile='$source_root/Cargo.lock'
    fi
fi
if test -n "\$dsr_lockfile"; then
    dsr_seed_summary=\$(_cargo_cache_run snapshot "\$ambient_home" '$cargo_home' "\$dsr_lockfile")
else
    dsr_seed_summary=\$(_cargo_cache_run snapshot "\$ambient_home" '$cargo_home')
fi
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
# Preserve the transport observation separately from the coordinator's receipt
# validation. Existing callers still receive only the validated receipt; the
# native runner requests the internal envelope to retain the original exit.
_act_finish_private_cargo_home_receipt() {
    local host="$1" command="$2" cargo_home="$3" capture_execution="$4"
    local summary receipt="" command_exit=0 result_exit=0
    summary=$(_act_ssh_exec "$host" "$command" "$_ACT_SYNC_TIMEOUT") || command_exit=$?
    result_exit="$command_exit"
    if [[ $command_exit -eq 0 ]]; then
        receipt=$(jq -ce --arg home "$cargo_home" '
            select(type == "object" and .schema_version == 1 and .mode == "inventory" and
                .cargo_home == $home and .receipt_path == ($home + ".final.json") and
                (.receipt_sha256 | test("^[0-9a-f]{64}$")) and
                (.inventory_sha256 | test("^[0-9a-f]{64}$")))
        ' <<< "$summary") || result_exit=$?
    fi
    if [[ "$capture_execution" == true ]]; then
        if [[ $result_exit -ne 0 && -n "$summary" ]]; then
            printf '%s\n' "$summary" >&2
        fi
        [[ $result_exit -eq 0 ]] || receipt=""
        jq -nc --argjson command_exit "$command_exit" --argjson receipt "${receipt:-null}" \
            '{command_exit_code: $command_exit, receipt: $receipt}' || return 4
    elif [[ $result_exit -eq 0 ]]; then
        printf '%s\n' "$receipt"
    fi
    return "$result_exit"
}

_act_finish_unix_private_cargo_home() {
    local capture_execution=false
    if [[ "${1:-}" == --native-execution ]]; then
        capture_execution=true
        shift
    fi
    local host="$1" cargo_home="$2" seed_digest="$3" command source_verification=""
    [[ $# == 3 || $# == 5 ]] || return 4
    [[ "$cargo_home" =~ ^/[A-Za-z0-9_./+-]+$ && "$cargo_home" != *..* &&
       "$seed_digest" =~ ^[0-9a-f]{64}$ ]] || return 4
    command=$(_act_unix_cargo_cache_runtime) || return $?
    if [[ $# == 5 ]]; then
        source_verification=$(_act_unix_cargo_sources_verify_script "$4" "$cargo_home" "$5") || return $?
        command+=$'\n'"$source_verification"$'\n'
    fi
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
    _act_finish_private_cargo_home_receipt "$host" "$command" "$cargo_home" "$capture_execution"
}

_act_windows_cargo_cache_runtime() {
    local module
    module="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cargo_cache_windows.ps1"
    [[ -f "$module" && ! -L "$module" ]] || return 3
    cat "$module"
}

_act_windows_cargo_context_runtime() {
    local module
    module="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cargo_context_windows.ps1"
    [[ -f "$module" && ! -L "$module" ]] || return 3
    cat "$module"
}

_act_windows_cargo_sources_runtime() {
    local module
    module="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/cargo_sources_windows.ps1"
    [[ -f "$module" && ! -L "$module" ]] || return 3
    cat "$module"
}

_act_windows_source_runtime_script() {
    local module
    module="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/source_snapshot_windows.ps1"
    [[ -f "$module" && ! -L "$module" ]] || return 3
    cat "$module"
}

# Source verification has the same command-line limit as native compilation.
# Keep larger programs as the existing hash-bound, held Windows script files.
_act_windows_source_command() {
    local host="$1" source_root="$2" script="$3" command
    if command=$(_act_windows_encoded_powershell "$script" pwsh 2>/dev/null); then
        printf '%s' "$command"
    else
        _act_windows_stage_build_script "$host" "$source_root" "$script"
    fi
}

# Windows attestation is produced by the selected native process context. Keep
# it separate from the digest-only context receipt and cache inventories, and
# require all three executables before any compiler command is admitted.
_act_validate_windows_toolchain_summary() {
    local summary="$1" source_root="$2"
    source_root="${source_root//\\//}"
    jq -ce --arg source "$source_root" '
        def digest: type == "string" and test("^[0-9a-f]{64}$");
        def native_path: type == "string" and test("^[A-Za-z]:/");
        def executable:
            type == "object" and
            (.program | type == "string" and length > 0) and
            (.selected_path | native_path) and (.selected_sha256 | digest) and
            .selected_kind == "executable" and
            (.version | type == "string" and length > 0) and
            (if has("resolved_path") or has("resolved_sha256") or has("resolved_kind") then
                (.resolved_path | native_path) and (.resolved_sha256 | digest) and
                .resolved_kind == "executable"
             else true end);
        select(type == "object" and .schema_version == 1 and
            (.cwd | native_path) and (.cwd | ascii_downcase) == ($source | ascii_downcase) and
            (.target_triple | type == "string" and test("^[A-Za-z0-9_]+(-[A-Za-z0-9_]+){2,}$")) and
            (.tools | type == "object" and (keys | sort) == ["cargo", "linker", "rustc"] and all(.[]; executable)) and
            (.selection | type == "object" and
                (.rustup_toolchain == null or (.rustup_toolchain | type == "string" and length > 0)) and
                (.cargo_commands | type == "array" and length == 1 and all(.[]; . == "build" or . == "rustc")) and
                (.cargo_config | type == "array" and all(.[];
                    type == "object" and (.path | native_path) and (.sha256 | digest)))))
    ' <<< "$summary"
}

# Requires the Windows cache and source runtimes. The controller supplies both
# hashes; a replaced metadata file or source receipt cannot authorize itself.
# The same body runs before compilation and in independent final admission.
_act_windows_cargo_sources_verify_body() {
    local source_root="$1" cargo_home="$2" sources_json="$3" path metadata_digest sources_digest
    for path in "$source_root" "$cargo_home"; do
        [[ "$path" =~ ^[A-Za-z]:/[A-Za-z0-9_./+-]+$ && "$path" != *..* ]] || return 4
    done
    sources_json=$(_act_validate_cargo_sources_summary "$sources_json") || return 4
    metadata_digest=$(jq -er '.metadata_sha256' <<< "$sources_json") || return 4
    sources_digest=$(jq -er '.sha256' <<< "$sources_json") || return 4
    cat <<EOF
\$dsrMetadataPath=Join-Path '$cargo_home' '.dsr-cargo-metadata.json'
\$dsrSourcesPath=Join-Path '$cargo_home' '.dsr-cargo-sources.json'
if ((Get-DsrCargoSourceFileHash -Path \$dsrMetadataPath) -cne '$metadata_digest' -or
    (Get-DsrCargoSourceFileHash -Path \$dsrSourcesPath) -cne '$sources_digest') {
    throw 'Cargo dependency evidence differs from coordinator-held authority'
}
\$dsrVerifiedSources=Invoke-DsrCargoSources -Operation verify -MetadataPath \$dsrMetadataPath -ReceiptPath \$dsrSourcesPath -Lockfile (Join-Path '$source_root' 'Cargo.lock') -CargoHome '$cargo_home' -SourceRoot '$source_root' -ExpectedSha256 '$sources_digest'
if (\$dsrVerifiedSources.sha256 -cne '$sources_digest' -or
    (Get-DsrCargoSourceFileHash -Path \$dsrMetadataPath) -cne '$metadata_digest' -or
    (Get-DsrCargoSourceFileHash -Path \$dsrSourcesPath) -cne '$sources_digest') {
    throw 'Cargo dependency sources differ from coordinator-held authority'
}
EOF
}

# Both metadata and compilation construct their context from the same ordered
# configured environment. The private home is managed by DSR and wins even
# over a differently cased configured CARGO_HOME on Windows.
_act_windows_cargo_context_setup() {
    local build_cmd="${1-cargo build}" build_env="${2:-}" env_pair env_name name_b64 value_b64 command_b64
    command_b64=$(printf '%s' "$build_cmd" | base64 | tr -d '\r\n') || return 3
    printf '%s\n' '$dsrConfiguredEnvironment=[Collections.Generic.List[string]]::new()'
    while IFS= read -r env_pair; do
        [[ -n "$env_pair" ]] || continue
        env_name="${env_pair%%=*}"
        [[ "$env_pair" == *=* && "$env_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 4
        [[ "${env_name^^}" == CARGO_HOME ]] && continue
        name_b64=$(printf '%s' "$env_name" | base64 | tr -d '\r\n') || return 3
        value_b64=$(printf '%s' "${env_pair#*=}" | base64 | tr -d '\r\n') || return 3
        printf "\$dsrConfiguredEnvironment.Add([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('%s')) + '=' + [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('%s')))\n" "$name_b64" "$value_b64"
    done <<< "$build_env"
    printf '%s\n' '$dsrConfiguredEnvironment.Add("CARGO_HOME=$dsrStrictHome")'
    printf "\$dsrContext=New-DsrCargoContext -BuildCommand ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('%s'))) -SourceRoot \$dsrPhysicalSource -CargoHome \$dsrStrictHome -Environment (\$dsrConfiguredEnvironment.ToArray())\n" "$command_b64"
}

# The cache implementation may exceed Windows command-line limits. Retain an
# inspectable, verified script on the host when inline transport cannot fit.
_act_windows_cache_command() {
    local host="$1" source_root="$2" script="$3" command
    if command=$(_act_windows_encoded_powershell "$script" pwsh 2>/dev/null); then
        printf '%s' "$command"
    else
        _act_windows_stage_build_script "$host" "$source_root" "$script"
    fi
}

_act_windows_cargo_home_name() {
    # Retain the full per-attempt UUID while saving Windows/libgit2 path budget.
    # Other callers keep their existing names; no attempt identity is truncated.
    local suffix="$1"
    if [[ "$suffix" =~ ^windows-(amd64|arm64)-([0-9a-f]{32})$ ]]; then
        printf '.c-%s' "${BASH_REMATCH[2]}"
    else
        printf '.cargo-home-%s' "$suffix"
    fi
}

_act_windows_private_cargo_home_script() {
    local source_root="$1" suffix="$2"
    # Match the Unix ASCII path contract independently of coordinator locale.
    local LC_ALL=C || {
        _log_error "Unable to select ASCII validation locale for strict Windows Cargo paths"
        return 4
    }
    source_root="${source_root//\\//}"
    if [[ ! "$source_root" =~ ^[A-Za-z]:/[A-Za-z0-9_./+-]+$ || "$source_root" == *..* ]]; then
        _log_error "Invalid strict Windows Cargo source root: expected a drive-qualified source path using letters, digits, _, ., /, + or -, without '..'"
        return 4
    fi
    if [[ ! "$suffix" =~ ^[A-Za-z0-9][A-Za-z0-9_-]+$ ]]; then
        _log_error "Invalid strict Windows Cargo attempt suffix: require a leading letter or digit and at least one further letter, digit, _ or -"
        return 4
    fi
    _act_windows_cargo_cache_runtime || return $?
    cat <<EOF
\$ErrorActionPreference='Stop'
\$dsrSourceGuards=Open-DsrCachePathGuard '$source_root'
\$dsrPhysicalSource=(Get-Item -LiteralPath '$source_root' -Force).FullName.Replace('\\','/')
\$dsrLockfile=Get-DsrCacheFullPath (Join-Path \$dsrPhysicalSource 'Cargo.lock')
# Keep the selected lockfile stable through metadata and retained-seed admission.
\$dsrSourceGuards.Add((Open-DsrCacheEntry \$dsrLockfile))
\$dsrSourceParent=Split-Path -Parent \$dsrPhysicalSource
\$dsrSeedHome=Join-Path \$dsrSourceParent '.cargo-home'
\$dsrStrictHome=Join-Path \$dsrSourceParent '$(_act_windows_cargo_home_name "$suffix")'
\$dsrSeedPending=\$false
if (Get-Item -LiteralPath \$dsrSeedHome -Force -ErrorAction SilentlyContinue) {
    Assert-DsrCargoHome -Path \$dsrSeedHome
    \$dsrSeedSummary=Invoke-DsrCargoCache -Operation verify -First \$dsrSeedHome -Second (Join-Path \$dsrSeedHome '.dsr-cache-seed.json')
    \$dsrPrivateSummary=Invoke-DsrCargoCache -Operation snapshot -First \$dsrSeedHome -Second \$dsrStrictHome -Lockfile \$dsrLockfile
    if (\$dsrSeedSummary.mode -cne 'private-copy' -or \$dsrPrivateSummary.mode -cne 'private-copy' -or
        \$dsrSeedSummary.selection.kind -cne 'cargo-lock-downloads' -or
        (ConvertTo-DsrCacheCanonicalJson \$dsrSeedSummary.selection) -cne (ConvertTo-DsrCacheCanonicalJson \$dsrPrivateSummary.selection) -or
        \$dsrPrivateSummary.inventory_sha256 -cne \$dsrSeedSummary.inventory_sha256) {
        throw 'Private Cargo cache seed or lockfile selection changed during preparation'
    }
} else {
    \$dsrAmbient=if (\$env:CARGO_HOME) { \$env:CARGO_HOME } else { Join-Path \$env:USERPROFILE '.cargo' }
    if (-not (Get-Item -LiteralPath \$dsrAmbient -Force -ErrorAction SilentlyContinue)) { \$dsrAmbient='' }
    \$dsrPrivateSummary=Invoke-DsrCargoCache -Operation snapshot -First \$dsrAmbient -Second \$dsrStrictHome -Lockfile \$dsrLockfile
    \$dsrSeedPending=\$true
}
Assert-DsrCargoHome -Path \$dsrStrictHome
EOF
}

_act_windows_cargo_metadata_body() {
    local build_cmd="${1-cargo build}" build_env="${2:-}"
    _act_windows_cargo_context_runtime || return $?
    _act_windows_cargo_sources_runtime || return $?
    cat <<'POWERSHELL'
$dsrAncestor=(Get-Item -LiteralPath $dsrPhysicalSource -Force).Parent
while ($null -ne $dsrAncestor) {
    foreach ($dsrName in @('config','config.toml')) {
        if (Get-Item -LiteralPath (Join-Path $dsrAncestor.FullName ".cargo/$dsrName") -Force -ErrorAction SilentlyContinue) {
            throw 'Untracked ancestor Cargo config is forbidden'
        }
    }
    $dsrAncestor=$dsrAncestor.Parent
}
POWERSHELL
    _act_windows_cargo_context_setup "$build_cmd" "$build_env" || return $?
    cat <<'POWERSHELL'
$dsrMetadataResult=Invoke-DsrCargoContext -Context $dsrContext -Operation Metadata
if ($dsrMetadataResult.Stderr) { [Console]::Error.Write($dsrMetadataResult.Stderr) }
if ($dsrMetadataResult.ExitCode -ne 0) { exit $dsrMetadataResult.ExitCode }
$dsrMetadataText=$dsrMetadataResult.Stdout
$dsrMetadataValue=ConvertFrom-Json -InputObject $dsrMetadataText -ErrorAction Stop
if ($dsrMetadataValue -isnot [pscustomobject] -or $dsrMetadataValue.packages -isnot [array] -or
    $dsrMetadataValue.packages.Count -eq 0 -or $dsrMetadataValue.workspace_root -isnot [string] -or
    -not $dsrMetadataValue.workspace_root) { throw 'Invalid locked Cargo metadata; seed not admitted' }
$dsrMetadataPath=Join-Path $dsrStrictHome '.dsr-cargo-metadata.json'
$dsrMetadataStream=[IO.File]::Open($dsrMetadataPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
try {
    $dsrMetadataBytes=[Text.Encoding]::UTF8.GetBytes($dsrMetadataText)
    $dsrMetadataStream.Write($dsrMetadataBytes,0,$dsrMetadataBytes.Length)
    $dsrMetadataStream.Flush($true)
} finally { $dsrMetadataStream.Dispose() }
Assert-DsrCargoHome -Path $dsrStrictHome
Assert-DsrCargoSeed -CargoHome $dsrStrictHome -ExpectedSha256 $dsrPrivateSummary.receipt_sha256
$dsrMetadataDigest=Get-DsrCargoSourceFileHash -Path $dsrMetadataPath
$dsrDependencySources=Invoke-DsrCargoSources -Operation capture -MetadataPath $dsrMetadataPath -ReceiptPath (Join-Path $dsrStrictHome '.dsr-cargo-sources.json') -Lockfile $dsrLockfile -CargoHome $dsrStrictHome -SourceRoot $dsrPhysicalSource
if ((Get-DsrCargoSourceFileHash -Path $dsrMetadataPath) -cne $dsrMetadataDigest) {
    throw 'Cargo metadata changed during dependency authentication; seed not admitted'
}
if ($dsrPrivateSummary.selection.kind -cne 'cargo-lock-downloads' -or
    $dsrPrivateSummary.selection.lockfile_sha256 -cne $dsrDependencySources.authentication.lockfile_sha256) {
    throw 'Private Cargo download selection differs from authenticated lockfile; seed not admitted'
}
$dsrDependencySources.metadata_sha256=$dsrMetadataDigest
$dsrPrivateSummary.dependency_sources=$dsrDependencySources
$dsrContextSummary=Write-DsrCargoContextReceipt -Context $dsrContext -Path (Join-Path $dsrStrictHome '.dsr-cargo-context.json')
$dsrPrivateSummary.toolchain=$dsrContextSummary.toolchain
$dsrPrivateSummary.cargo_context=@{schema_version=$dsrContextSummary.schema_version;fingerprint=$dsrContextSummary.fingerprint;receipt_sha256=$dsrContextSummary.receipt_sha256}
if ($dsrSeedPending) {
    Invoke-DsrCargoCache -Operation snapshot -First $dsrStrictHome -Second $dsrSeedHome -Lockfile $dsrLockfile | Out-Null
}
foreach ($dsrSourceGuard in $dsrSourceGuards) { $dsrSourceGuard.Dispose() }
POWERSHELL
}

_act_prepare_windows_private_cargo_home() {
    local host="$1" source_root="$2" suffix="$3" build_cmd="${4-cargo build}" build_env="${5:-}" script command summary sources_json toolchain_json
    script=$(_act_windows_private_cargo_home_script "$source_root" "$suffix") || return $?
    script+=$'\n'"$(_act_windows_cargo_metadata_body "$build_cmd" "$build_env")" || return $?
    script+=$'\n''$dsrPrivateSummary | ConvertTo-Json -Compress -Depth 100; exit 0'
    command=$(_act_windows_cache_command "$host" "$source_root" "$script") || return $?
    summary=$(_act_ssh_exec "$host" "$command" "$_ACT_SYNC_TIMEOUT") || {
        local prepare_status=$?
        _log_error "Strict Windows Cargo cache preparation failed on $host (exit $prepare_status)"
        return "$prepare_status"
    }
    if ! sources_json=$(jq -ce '.dependency_sources' <<< "$summary") ||
       ! _act_validate_cargo_sources_summary "$sources_json" >/dev/null; then
        _log_error "Strict Windows Cargo cache preparation returned invalid dependency-source evidence on $host"
        return 4
    fi
    if ! _act_validate_cargo_cache_selection "$summary" "$sources_json" >/dev/null; then
        _log_error "Strict Windows Cargo cache preparation returned invalid lockfile selection evidence on $host"
        return 4
    fi
    if ! toolchain_json=$(jq -ce '.toolchain' <<< "$summary") ||
       ! _act_validate_windows_toolchain_summary "$toolchain_json" "$source_root" >/dev/null; then
        _log_error "Strict Windows Cargo cache preparation returned invalid toolchain evidence on $host"
        return 4
    fi
    # Retain the requested attempt identity even when the host resolves a
    # physical source parent. A valid receipt cannot authorize another home.
    if ! summary=$(jq -cse --arg name "$(_act_windows_cargo_home_name "$suffix")" '
        select(length == 1) | .[0] |
        select(type == "object" and .schema_version == 1 and .mode == "private-copy" and
            (.cargo_home | type == "string" and test("^[A-Za-z]:/[A-Za-z0-9_./+-]+$") and
                (contains("..") | not) and endswith("/" + $name)) and
            .receipt_path == (.cargo_home + "/.dsr-cache-seed.json") and
            (.receipt_sha256 | test("^[0-9a-f]{64}$")) and
            (.inventory_sha256 | test("^[0-9a-f]{64}$")) and
            (.cargo_context | type == "object" and .schema_version == 1 and
                (keys | sort) == ["fingerprint", "receipt_sha256", "schema_version"] and
                (.fingerprint | test("^[0-9a-f]{64}$")) and
                (.receipt_sha256 | test("^[0-9a-f]{64}$"))))
    ' <<< "$summary"); then
        _log_error "Strict Windows Cargo cache preparation returned invalid private attempt evidence on $host (expected $(_act_windows_cargo_home_name "$suffix"))"
        return 4
    fi
    printf '%s\n' "$summary"
}

# The build uses the same context constructor and CMD launcher as admission.
# The coordinator holds both digests, so changing a retained context receipt
# cannot authorize a different command, configuration, or compiler environment.
_act_windows_strict_cargo_build_script() {
    [[ $# == 8 ]] || return 4
    local source_root="$1" cargo_home="$2" build_cmd="$3" build_env="$4"
    local fingerprint="$5" receipt_digest="$6" seed_digest="$7" sources_json="$8" path
    source_root="${source_root//\\//}" cargo_home="${cargo_home//\\//}"
    for path in "$source_root" "$cargo_home"; do
        [[ "$path" =~ ^[A-Za-z]:/[A-Za-z0-9_./+-]+$ && "$path" != *..* ]] || return 4
    done
    [[ "$fingerprint" =~ ^[0-9a-f]{64}$ && "$receipt_digest" =~ ^[0-9a-f]{64}$ &&
       "$seed_digest" =~ ^[0-9a-f]{64}$ ]] || return 4
    _act_windows_cargo_cache_runtime || return $?
    _act_windows_cargo_context_runtime || return $?
    _act_windows_cargo_sources_runtime || return $?
    cat <<EOF
\$ErrorActionPreference='Stop'
\$dsrSourceGuards=Open-DsrCachePathGuard '$source_root'
\$dsrPhysicalSource=(Get-Item -LiteralPath '$source_root' -Force).FullName.Replace('\\','/')
\$dsrStrictHome='$cargo_home'
\$dsrContextPath=Join-Path \$dsrStrictHome '.dsr-cargo-context.json'
try {
Assert-DsrCargoHome -Path \$dsrStrictHome
Assert-DsrCargoSeed -CargoHome \$dsrStrictHome -ExpectedSha256 '$seed_digest'
\$dsrAncestor=(Get-Item -LiteralPath \$dsrPhysicalSource -Force).Parent
while (\$null -ne \$dsrAncestor) {
    foreach (\$dsrName in @('config','config.toml')) {
        if (Get-Item -LiteralPath (Join-Path \$dsrAncestor.FullName ".cargo/\$dsrName") -Force -ErrorAction SilentlyContinue) {
            throw 'Untracked ancestor Cargo config is forbidden'
        }
    }
    \$dsrAncestor=\$dsrAncestor.Parent
}
EOF
    _act_windows_cargo_context_setup "$build_cmd" "$build_env" || return $?
    _act_windows_cargo_sources_verify_body "$source_root" "$cargo_home" "$sources_json" || return $?
    cat <<EOF
Assert-DsrCargoContextReceipt -Context \$dsrContext -Path \$dsrContextPath -Fingerprint '$fingerprint' -ReceiptSha256 '$receipt_digest'
\$dsrBuildResult=Invoke-DsrCargoContext -Context \$dsrContext -Operation Build
if (\$dsrBuildResult.ExitCode -ne 0) { exit \$dsrBuildResult.ExitCode }
Assert-DsrCargoContextReceipt -Context \$dsrContext -Path \$dsrContextPath -Fingerprint '$fingerprint' -ReceiptSha256 '$receipt_digest'
Assert-DsrCargoHome -Path \$dsrStrictHome
Assert-DsrCargoSeed -CargoHome \$dsrStrictHome -ExpectedSha256 '$seed_digest'
} finally { foreach (\$dsrSourceGuard in \$dsrSourceGuards) { \$dsrSourceGuard.Dispose() } }
exit 0
EOF
}

_act_prepare_windows_nonstrict_cargo_home() {
    local host="$1" source_root="$2" stage_root="$3" cargo_home="$4" script command summary path
    local source_root_q
    for path in "$stage_root" "$cargo_home"; do
        [[ "$path" =~ ^[A-Za-z]:/[A-Za-z0-9_./+-]+$ && "$path" != *..* ]] || return 4
    done
    [[ "$stage_root" == */dsr-build-* && "$cargo_home" == "$stage_root/"* ]] || return 4
    source_root="${source_root//\\//}"
    if [[ "$source_root" =~ ^/([A-Za-z])/(.*)$ ]]; then
        source_root="${BASH_REMATCH[1]}:/${BASH_REMATCH[2]}"
    fi
    [[ "$source_root" =~ ^[A-Za-z]:/ && "$source_root" != *[[:cntrl:]]* ]] || return 4
    source_root_q="${source_root//\'/\'\'}"
    script=$(_act_windows_cargo_cache_runtime) || return $?
    script+=$'\n'"$(cat <<EOF
\$ErrorActionPreference='Stop'
\$dsrSource=Get-DsrCacheFullPath '$source_root_q'
\$dsrSourceGuards=Open-DsrCachePathGuard \$dsrSource
try {
# A present but invalid lock must fail the existing held-file checks, never
# become permission to import unrelated ambient sources and Git checkouts.
# Enumerating the guarded root distinguishes absence from inaccessible or
# linked lockfiles without suppressing a filesystem error.
\$dsrLockfile=''
foreach (\$dsrEntry in (Get-DsrCacheChildren \$dsrSource)) {
    if ([StringComparer]::OrdinalIgnoreCase.Equals([IO.Path]::GetFileName(\$dsrEntry), 'Cargo.lock')) {
        \$dsrLockfile=\$dsrEntry
    }
}
\$dsrParent=Split-Path -Parent '$stage_root'
[IO.Directory]::CreateDirectory(\$dsrParent) | Out-Null
if (Get-Item -LiteralPath '$stage_root' -Force -ErrorAction SilentlyContinue) { throw 'Rust isolation path already exists' }
[IO.Directory]::CreateDirectory('$stage_root') | Out-Null
\$dsrAmbient=if (\$env:CARGO_HOME) { \$env:CARGO_HOME } else { Join-Path \$env:USERPROFILE '.cargo' }
if (-not (Get-Item -LiteralPath \$dsrAmbient -Force -ErrorAction SilentlyContinue)) { \$dsrAmbient='' }
if (\$dsrLockfile) {
    \$dsrSummary=Invoke-DsrCargoCache -Operation snapshot -First \$dsrAmbient -Second '$cargo_home' -Lockfile \$dsrLockfile
} else {
    \$dsrSummary=Invoke-DsrCargoCache -Operation snapshot -First \$dsrAmbient -Second '$cargo_home'
}
Assert-DsrCargoHome -Path '$cargo_home'
\$dsrSummary | ConvertTo-Json -Compress -Depth 100
} finally { foreach (\$dsrGuard in \$dsrSourceGuards) { \$dsrGuard.Dispose() } }
exit 0
EOF
)"
    command=$(_act_windows_cache_command "$host" "$source_root" "$script") || return $?
    summary=$(_act_ssh_exec "$host" "$command" "$_ACT_SYNC_TIMEOUT") || return $?
    jq -ce --arg home "$cargo_home" '
        select(type == "object" and .schema_version == 1 and .mode == "private-copy" and
            (.cargo_home | ascii_downcase) == ($home | ascii_downcase) and
            .receipt_path == (.cargo_home + "/.dsr-cache-seed.json") and
            (.receipt_sha256 | test("^[0-9a-f]{64}$")) and
            (.inventory_sha256 | test("^[0-9a-f]{64}$")))
    ' <<< "$summary"
}

_act_finish_windows_private_cargo_home() {
    local capture_execution=false
    if [[ "${1:-}" == --native-execution ]]; then
        capture_execution=true
        shift
    fi
    [[ $# == 3 || $# == 5 || $# == 8 ]] || return 4
    local host="$1" cargo_home="$2" seed_digest="$3" script command source_verification
    local context_verification="" context_fingerprint context_receipt_digest context_json
    [[ "$cargo_home" =~ ^[A-Za-z]:/[A-Za-z0-9_./+-]+$ && "$cargo_home" != *..* &&
       "$seed_digest" =~ ^[0-9a-f]{64}$ ]] || return 4
    script=$(_act_windows_cargo_cache_runtime) || return $?
    script+=$'\n'"\$ErrorActionPreference='Stop'"
    if [[ $# -ge 5 ]]; then
        source_verification=$(_act_windows_cargo_sources_runtime) || return $?
        script+=$'\n'"$source_verification"
        if [[ $# == 8 ]]; then
            context_json=$(jq -ce 'select(type == "object" and .schema_version == 1 and
                (keys | sort) == ["fingerprint", "receipt_sha256", "schema_version"] and
                (.fingerprint | type == "string" and test("^[0-9a-f]{64}$")) and
                (.receipt_sha256 | type == "string" and test("^[0-9a-f]{64}$")))' <<< "$8") || return 4
            context_fingerprint=$(jq -er '.fingerprint' <<< "$context_json") || return 4
            context_receipt_digest=$(jq -er '.receipt_sha256' <<< "$context_json") || return 4
            context_verification=$(_act_windows_cargo_context_runtime) || return $?
            script+=$'\n'"$context_verification"
            [[ "$4" =~ ^[A-Za-z]:/[A-Za-z0-9_./+-]+$ && "$4" != *..* ]] || return 4
            script+=$'\n'"\$dsrPhysicalSource=(Get-Item -LiteralPath '$4' -Force).FullName.Replace('\\','/'); \$dsrStrictHome='$cargo_home'"
            context_verification=$(_act_windows_cargo_context_setup "$6" "$7") || return $?
            script+=$'\n'"$context_verification"
            context_verification="Assert-DsrCargoContextReceipt -Context \$dsrContext -Path (Join-Path '$cargo_home' '.dsr-cargo-context.json') -Fingerprint '$context_fingerprint' -ReceiptSha256 '$context_receipt_digest'"
            script+=$'\n'"$context_verification"
        fi
        source_verification=$(_act_windows_cargo_sources_verify_body "$4" "$cargo_home" "$5") || return $?
        script+=$'\n'"$source_verification"
    fi
    script+=$'\n'"$(cat <<EOF
Assert-DsrCargoHome -Path '$cargo_home'
Assert-DsrCargoSeed -CargoHome '$cargo_home' -ExpectedSha256 '$seed_digest'
\$dsrFinal=Invoke-DsrCargoCache -Operation inventory -First '$cargo_home' -Second '$cargo_home.final.json'
Assert-DsrCargoHome -Path '$cargo_home'
Assert-DsrCargoSeed -CargoHome '$cargo_home' -ExpectedSha256 '$seed_digest'
$context_verification
\$dsrFinal | ConvertTo-Json -Compress -Depth 100
exit 0
EOF
)"
    command=$(_act_windows_cache_command "$host" "$cargo_home" "$script") || return $?
    _act_finish_private_cargo_home_receipt "$host" "$command" "$cargo_home" "$capture_execution"
}

_act_strict_cargo_metadata_json() {
    local host="$1"
    local source_root="$2"
    local build_cmd="${3-cargo build}" build_env="${4:-}"
    local metadata_command metadata_output metadata_json canonical_source_root

    if [[ ! "$source_root" =~ ^[A-Za-z0-9_./:+-]+$ || "$source_root" == *..* ]]; then
        _log_error "Unsafe strict Cargo source root"
        return 4
    fi
    if _act_is_windows_host "$host"; then
        local win_source_root metadata_attempt metadata_script metadata_body
        win_source_root=$(_act_windows_cmd_path "$source_root")
        metadata_attempt=$(_act_generate_uuid) || return 3
        metadata_script=$(_act_windows_private_cargo_home_script \
            "$win_source_root" "metadata-${metadata_attempt//-/}") || return $?
        metadata_body=$(_act_windows_cargo_metadata_body "$build_cmd" "$build_env") || return $?
        metadata_script+=$'\n'"$metadata_body"$'\n''Write-Output $dsrPhysicalSource; Get-Content -LiteralPath $dsrMetadataPath -Raw; exit 0'
        metadata_command=$(_act_windows_cache_command "$host" "$win_source_root" "$metadata_script") || return $?
    else
        local metadata_attempt metadata_body
        metadata_attempt=$(_act_generate_uuid) || return 3
        metadata_command=$(_act_unix_private_cargo_home_script \
            "$source_root" "metadata-${metadata_attempt//-/}") || return $?
        metadata_body=$(_act_unix_cargo_metadata_body "$build_cmd" "$build_env") || return $?
        metadata_command+=$'\n'"$metadata_body"$'\n''printf '\''%s\n'\'' "$physical_source_root"; test -f "$strict_home/.dsr-cargo-metadata.json"; test ! -L "$strict_home/.dsr-cargo-metadata.json"; cat "$strict_home/.dsr-cargo-metadata.json"'
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
    local build_cmd build_env binary_name target_triple command_template configured selected target_slug
    command_template=$(act_get_build_cmd "$tool" "$platform") || return 4
    binary_name=$(yq -r '.binary_name // ""' "$ACT_REPOS_DIR/${tool}.yaml") || return 4
    configured=$(act_get_configured_target_triples "$tool" "$platform") || return 4
    # Preserve singleton environment selection, including existing explicit
    # compiler overrides. Every matrix variant must be admitted independently:
    # target-conditional Cargo dependencies can differ between GNU and musl.
    [[ "$configured" == *$'\n'* ]] || configured=""
    while IFS= read -r selected; do
        build_env=$(act_get_build_env "$tool" "$platform" "$selected") || return 4
        target_triple=$(act_get_build_env_value "$build_env" CARGO_BUILD_TARGET 2>/dev/null || true)
        build_cmd=$(act_substitute_build_cmd_tokens "$command_template" "${binary_name:-$tool}" \
            "$version" "${platform%%/*}" "${platform##*/}" "$target_triple") || return 4
        target_slug="${platform//\//-}"
        [[ -z "$selected" ]] || target_slug+="-$selected"
        build_env+=$'\n'"CARGO_TARGET_DIR=${source_root%/*}/.cargo-target-$target_slug"
        _act_validate_strict_cargo_source_closure \
            "$host" "$source_root" "$dependencies" "$build_cmd" "$build_env" || return 4
    done <<< "$configured"
}

_act_windows_reparse_guard_script() {
    printf '%s' "function Assert-NoReparseChain { param([System.IO.FileSystemInfo]\$Item); for (\$node=\$Item; \$null -ne \$node; \$node=\$node.Parent) { if ((\$node.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'NTFS ReparsePoint is forbidden in a strict release snapshot' } } }; function Assert-PlainDirectory { param([string]\$Path); \$item=Get-Item -LiteralPath \$Path -Force -ErrorAction Stop; if (-not \$item.PSIsContainer) { throw 'Strict release directory is not a directory' }; Assert-NoReparseChain \$item }; function Assert-PlainFile { param([string]\$Path); \$item=Get-Item -LiteralPath \$Path -Force -ErrorAction Stop; if (\$item.PSIsContainer) { throw 'Strict release file is not a file' }; Assert-NoReparseChain \$item };"
}

_act_windows_source_budget_script() {
    local host="$1" parent="$2" archive_bytes="$3" object_count="$4" phase="${5:-archive}"
    local storage status=0 budget reserve drive incoming
    storage=$(_act_windows_storage_config "$host") || status=$?
    [[ $status -ne 1 ]] || return 0
    [[ $status -eq 0 && "$parent" =~ ^[A-Za-z]:/[A-Za-z0-9_./+-]+$ && "$parent" != *..* &&
       "$archive_bytes" =~ ^[0-9]{1,12}$ && "$object_count" =~ ^[0-9]{1,9}$ &&
       ( "$phase" == archive || "$phase" == expansion ) ]] || return 4
    budget=$(jq -r '.source_budget_bytes' <<< "$storage")
    reserve=$(jq -r '.source_reserve_bytes' <<< "$storage")
    drive=$(jq -r '.source_drive' <<< "$storage")
    [[ "${parent:0:1}" == "$drive" ]] || return 4
    # Admit archive transfer first. Once both retained inputs are authenticated,
    # charge the actual planned files, including every materialized link copy.
    # At that point the archive/manifest are already included in dsrExisting.
    incoming="([long]$archive_bytes * 2)"
    if [[ "$phase" == expansion ]]; then
        incoming='[long]$dsrSourcePlan.ExpandedBytes'
    fi
    cat <<EOF
\$dsrIncoming=$incoming+([long]$object_count * 4096)+16777216;
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
            # This fresh run directory also holds private Cargo caches. SBH
            # honors ancestor markers even in emergency cleanup; protect it
            # before extracting source or populating any compiler inputs.
            if ! (umask 077; set -C; printf '%s\n' 'DSR strict release snapshot' > "$snapshot_parent/.sbh-protect"); then
                _log_error "Unable to protect strict release snapshot for $label"
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
        local win_remote_path win_snapshot_parent win_remote_archive win_remote_manifest reparse_guard
        win_remote_path=$(_act_windows_cmd_path "$remote_path")
        win_snapshot_parent=$(_act_windows_cmd_path "$snapshot_parent")
        win_remote_archive=$(_act_windows_cmd_path "$remote_archive")
        win_remote_manifest=$(_act_windows_cmd_path "$remote_manifest")
        reparse_guard=$(_act_windows_reparse_guard_script)
        local win_snapshot_grandparent parent_setup setup_command verify_command verify_script
        win_snapshot_grandparent=$(_act_windows_cmd_path "$snapshot_grandparent")
        if $creates_snapshot_parent; then
            parent_setup="if (Test-Path -LiteralPath '${win_snapshot_parent}') { exit 16 }; New-Item -ItemType Directory -Force -Path '${win_snapshot_grandparent}' | Out-Null; Assert-PlainDirectory '${win_snapshot_grandparent}'; New-Item -ItemType Directory -Path '${win_snapshot_parent}' | Out-Null; Assert-PlainDirectory '${win_snapshot_parent}'"
        else
            parent_setup="Assert-PlainDirectory '${win_snapshot_parent}'"
        fi
        setup_command=$(_act_windows_encoded_powershell "\$ErrorActionPreference='Stop'; if (\$PSVersionTable.PSVersion -lt [version]'7.4') { throw 'Strict Windows source snapshots require PowerShell 7.4 or newer' }; Add-Type -AssemblyName System.Formats.Tar; ${reparse_guard} ${parent_setup}; if ((Test-Path -LiteralPath '${win_remote_path}') -or (Test-Path -LiteralPath '${win_remote_archive}') -or (Test-Path -LiteralPath '${win_remote_manifest}')) { exit 17 }; New-Item -ItemType Directory -Path '${win_remote_path}' | Out-Null; Assert-PlainDirectory '${win_remote_path}'" pwsh) || return 4
        local source_budget_script source_archive_bytes setup_script
        source_archive_bytes=$(_act_file_size "$archive_path") || return 4
        source_budget_script=$(_act_windows_source_budget_script "$host" "$snapshot_parent" "$source_archive_bytes" "$expected_object_count") || return 4
        if [[ -n "$source_budget_script" ]]; then
            setup_script=$(_act_windows_command_script "$setup_command") || return 4
            setup_command=$(_act_windows_encoded_powershell "$source_budget_script"$'\n'"$setup_script" pwsh) || return 4
            setup_command=$(_act_windows_storage_command "$host" "$setup_command") || return 4
        fi
        verify_script=$(_act_windows_strict_snapshot_extract_script "$host" \
            "$win_remote_path" "$win_remote_archive" "$win_remote_manifest" \
            "$local_digest" "$local_manifest_digest" "$expected_object_count") || return 4
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
           ! _act_run_with_timeout "$_ACT_SYNC_TIMEOUT" scp \
            -o ConnectTimeout="$_ACT_SSH_TIMEOUT" -o BatchMode=yes \
            -o StrictHostKeyChecking=accept-new "$manifest_path" \
            "${ssh_destination}:${remote_manifest}" </dev/null; then
            _log_error "Strict fresh Windows source transfer failed for $label"
            return 4
        fi
        # Authenticate both original inputs before creating any source files.
        # A Git symlink is materialized only after its link text and tracked
        # regular referent have both matched the controller's source manifest.
        verify_command=$(_act_windows_source_command "$host" "$remote_path" "$verify_script") || return 4
        if ! remote_digest=$(_act_run_with_timeout "$_ACT_SYNC_TIMEOUT" ssh -n \
            -o ConnectTimeout="$_ACT_SSH_TIMEOUT" -o BatchMode=yes \
            -o StrictHostKeyChecking=accept-new "$ssh_destination" "$verify_command"); then
            _log_error "Strict fresh Windows source sync failed for $label"
            return 4
        fi
    else
        local remote_cmd parent_setup
        if $creates_snapshot_parent; then
            parent_setup="mkdir -p '$snapshot_grandparent'; $(_act_ram_backed_guard_sh "$snapshot_grandparent")test ! -e '$snapshot_parent'; test ! -L '$snapshot_parent'; mkdir '$snapshot_parent'; printf '%s\\n' 'DSR strict release snapshot' > '$snapshot_parent/.sbh-protect'"
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
        local manifest_verify_command reparse_guard
        win_remote_manifest=$(_act_windows_cmd_path "$remote_manifest")
        reparse_guard=$(_act_windows_reparse_guard_script)
        # The manifest was transferred and authenticated before extraction;
        # re-observe its held identity instead of uploading it a second time.
        manifest_verify_command=$(_act_windows_encoded_powershell "\$ErrorActionPreference='Stop'; ${reparse_guard} Assert-PlainDirectory '${win_snapshot_parent}'; Assert-PlainDirectory '${win_remote_path}'; Assert-PlainFile '${win_remote_archive}'; Assert-PlainFile '${win_remote_manifest}'; (Get-FileHash -Algorithm SHA256 -LiteralPath '${win_remote_manifest}').Hash.ToLowerInvariant()" pwsh) || return 4
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
                "$local_manifest_digest" "$expected_object_count" "$local_digest" </dev/null) || \
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
dsr_gitlink_roots=\$(LC_ALL=C awk -F '\\t' '\$2 == "160000" { print \$3 }' '$remote_manifest')
dsr_line_break='
'
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
        repository_root='$remote_path'
        IFS=\$dsr_line_break
        for dsr_gitlink in \$dsr_gitlink_roots; do
            case "\$relative_path" in
                "\$dsr_gitlink"/*)
                    dsr_candidate='$remote_path'/\$dsr_gitlink
                    if test \${#dsr_candidate} -gt \${#repository_root}; then
                        repository_root=\$dsr_candidate
                    fi;;
            esac
        done
        IFS=/
        for component in \$link_dir; do
            case "\$component" in
                ''|.) :;;
                *) cursor="\$cursor/\$component"; test -d "\$cursor"; test ! -L "\$cursor";;
            esac
        done
        for component in \$target; do
            test -d "\$cursor"; test ! -L "\$cursor"
            case "\$component" in
                ''|.) :;;
                ..) test "\$cursor" != "\$repository_root" || exit 21; cursor=\${cursor%/*};;
                *)
                    cursor="\$cursor/\$component"; test ! -L "\$cursor" || exit 21
                    IFS=\$dsr_line_break
                    for dsr_gitlink in \$dsr_gitlink_roots; do
                        test "\$cursor" != '$remote_path'/"\$dsr_gitlink" || \\
                            test "\$cursor" = "\$repository_root" || exit 21
                    done
                    IFS=/;;
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

_act_windows_strict_snapshot_extract_script() {
    local host="$1" remote_path="$2" remote_archive="$3" remote_manifest="$4"
    local expected_archive_digest="$5" expected_manifest_digest="$6" expected_object_count="$7"
    local runtime budget_script snapshot_parent reparse_guard
    remote_path="${remote_path//\\//}"
    snapshot_parent="${remote_path%/*}"
    runtime=$(_act_windows_source_runtime_script) || return 4
    reparse_guard=$(_act_windows_reparse_guard_script) || return 4
    budget_script=$(_act_windows_source_budget_script \
        "$host" "$snapshot_parent" 0 "$expected_object_count" expansion) || return 4
    cat <<EOF
\$ErrorActionPreference='Stop'
$runtime
$reparse_guard
Assert-PlainDirectory '$snapshot_parent'
Assert-PlainDirectory '$remote_path'
\$dsrSourcePlan=Get-DsrWindowsSourcePlan -ArchivePath '$remote_archive' -ManifestPath '$remote_manifest' -ExpectedArchiveSha256 '$expected_archive_digest' -ExpectedManifestSha256 '$expected_manifest_digest' -ExpectedObjectCount $expected_object_count
$budget_script
\$null=Expand-DsrWindowsSourceSnapshot -Plan \$dsrSourcePlan -DestinationPath '$remote_path'
Write-Output \$dsrSourcePlan.ArchiveSha256
EOF
}

_act_windows_strict_snapshot_verify_script() {
    local remote_path="$1" snapshot_parent="$2" remote_archive="$3" remote_manifest="$4"
    local expected_manifest_digest="$5" expected_object_count="$6" expected_archive_digest="${7:-}"
    local runtime reparse_guard archive_argument=""
    runtime=$(_act_windows_source_runtime_script) || return 4
    reparse_guard=$(_act_windows_reparse_guard_script) || return 4
    if [[ -n "$expected_archive_digest" ]]; then
        [[ "$expected_archive_digest" =~ ^[0-9a-f]{64}$ ]] || return 4
        archive_argument=" -ExpectedArchiveSha256 '$expected_archive_digest'"
    fi
    cat <<EOF
\$ErrorActionPreference='Stop'
$runtime
$reparse_guard
Assert-PlainDirectory '$snapshot_parent'
Assert-PlainDirectory '$remote_path'
\$dsrSourcePlan=Get-DsrWindowsSourcePlan -ArchivePath '$remote_archive' -ManifestPath '$remote_manifest' -ExpectedManifestSha256 '$expected_manifest_digest' -ExpectedObjectCount $expected_object_count$archive_argument
\$null=Test-DsrWindowsSourceSnapshot -Plan \$dsrSourcePlan -DestinationPath '$remote_path'
Write-Output (\$dsrSourcePlan.ArchiveSha256 + ' ' + \$dsrSourcePlan.ManifestSha256)
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
            "$expected_manifest_digest" "$expected_object_count" "$expected_digest") || return 4
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
    local remote_manifest="$5" expected_manifest_digest="$6" expected_object_count="$7" expected_archive_digest="${8:-}"
    local remote_cmd verify_output digests

    if _act_is_windows_host "$host"; then
        local verify_script
        verify_script=$(_act_windows_strict_snapshot_verify_script \
            "$(_act_windows_cmd_path "$remote_path")" \
            "$(_act_windows_cmd_path "${remote_path%/*}")" \
            "$(_act_windows_cmd_path "$remote_archive")" \
            "$(_act_windows_cmd_path "$remote_manifest")" \
            "$expected_manifest_digest" "$expected_object_count" "$expected_archive_digest") || return 4
        # Reconstruct materialization from original authenticated Git evidence
        # on every boundary; a saved extraction inventory cannot bless itself.
        remote_cmd=$(_act_windows_source_command "$host" "$remote_path" "$verify_script") || return 4
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

# Export once before any host writes. Missing siblings and layouts that could
# escape or collide with the main staged tree are configuration failures.
_act_export_ordinary_git_contexts() {
    local config_file="$1" local_path="$2" context_parent="$3"
    local sources='[]' contexts='[]' item relative source context count index
    local tool_name="${config_file##*/}"
    tool_name="${tool_name%.yaml}"
    local sibling_names_seen=' source cargo-home '
    sources=$(jq -nc --arg path "$local_path" '[{relative_path:"source",local_path:$path}]') || return 4
    count=$(yq -r '.sibling_crates // [] | length' "$config_file") || return 4
    [[ "$count" =~ ^[0-9]+$ ]] || return 4
    for ((index=0; index<count; index++)); do
        source=$(yq -r ".sibling_crates[$index].local_path // \"\"" "$config_file") || return 4
        source=$(_act_materialized_source_path "$tool_name" "$source") || return 4
        relative=$(yq -r ".sibling_crates[$index].relative_path // \"\"" "$config_file") || return 4
        [[ -n "$relative" ]] || relative="${source##*/}"
        if [[ ! -d "$source" || -L "$source" ||
              ! "$relative" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ||
              "$relative" == *..* || "$relative" == *. ||
              "$sibling_names_seen" == *" ${relative,,} "* ]]; then
            _log_error "Missing sibling source or invalid staged sibling name: $source ($relative)"
            return 4
        fi
        sibling_names_seen+="${relative,,} "
        sources=$(jq -c --arg path "$source" --arg relative "$relative" \
            '. + [{relative_path:$relative,local_path:$path}]' <<< "$sources") || return 4
    done
    while IFS= read -r item; do
        source=$(jq -r .local_path <<< "$item") || return 4
        relative=$(jq -r .relative_path <<< "$item") || return 4
        context=null
        if [[ "$relative" == source ]] ||
           _git_ops_build_git -C "$source" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            if ! context=$(git_ops_export_build_context "$source" "$context_parent/$relative"); then
                _log_error "Cannot export Git build context for $source (requires a complete SHA1 Git worktree)"
                return 4
            fi
        fi
        contexts=$(jq -c --argjson item "$item" --argjson context "$context" \
            '. + [$item + {context:$context}]' <<< "$contexts") || return 4
    done < <(jq -c '.[]' <<< "$sources")
    printf '%s\n' "$contexts"
}

_act_verify_ordinary_git_contexts() {
    local contexts="$1" item source context
    while IFS= read -r item; do
        source=$(jq -r .local_path <<< "$item") || return 4
        [[ -d "$source" && ! -L "$source" ]] || return 4
        context=$(jq -c .context <<< "$item") || return 4
        if [[ "$context" != null ]] && ! git_ops_verify_build_context "$source" "$context"; then
            _log_error "Controller Git HEAD, branch, or tags changed during source transfer: $source"
            return 4
        fi
    done < <(jq -c '.[]' <<< "$contexts")
}

_act_ordinary_source_root_path() {
    local host="$1" identity="$2" configured_path="$3" root="" root_status=0
    _act_is_uuid "$identity" || return 4
    root=$(_act_get_host_build_root "$host") || root_status=$?
    [[ "$root_status" != 4 ]] || return 4
    if [[ -z "$root" ]]; then
        if _act_is_windows_host "$host"; then
            root='C:/Users/Public'
            [[ ! "$configured_path" =~ ^[A-Za-z]:[/\\] ]] || root="${configured_path:0:2}/Users/Public"
        else
            root=/var/tmp
        fi
    fi
    identity="${identity//-/}"
    if _act_is_windows_host "$host"; then identity="${identity:0:12}"; fi
    printf '%s/dsr-source-%s/source\n' "${root%/}" "$identity"
}

_act_prepare_ordinary_source_root() {
    local host="$1" source_root="$2" parent="${2%/*}" base command
    base="${parent%/*}"
    if _act_is_windows_host "$host"; then
        local win_source win_parent win_base guard
        win_source=$(_act_windows_cmd_path "$source_root") || return 4
        win_parent=$(_act_windows_cmd_path "$parent") || return 4
        win_base=$(_act_windows_cmd_path "$base") || return 4
        guard=$(_act_windows_reparse_guard_script) || return 4
        command=$(_act_windows_encoded_powershell "\$ErrorActionPreference='Stop'; $guard New-Item -ItemType Directory -Force -Path '$win_base' | Out-Null; Assert-PlainDirectory '$win_base'; if (Get-Item -LiteralPath '$win_parent' -Force -ErrorAction SilentlyContinue) { throw 'Ordinary source stage already exists' }; New-Item -ItemType Directory -Path '$win_parent' | Out-Null; Assert-PlainDirectory '$win_parent'; New-Item -ItemType Directory -Path '$win_source' | Out-Null; Assert-PlainDirectory '$win_source'; Write-Output (Get-Item -LiteralPath '$win_source' -Force).FullName" pwsh) || return 4
    else
        command="set -e; umask 077; mkdir -p '$base'; test -d '$base'; test ! -L '$base'; $(_act_ram_backed_guard_sh "$base")test ! -e '$parent'; test ! -L '$parent'; mkdir '$parent' '$source_root'; cd '$source_root'; pwd -P"
    fi
    _act_ssh_exec "$host" "$command" "$_ACT_SYNC_TIMEOUT" </dev/null
}

# Import only into a fresh stage, never into an operator checkout. The same
# Git helper validates the transferred bundle before creating a private .git.
_act_restore_ordinary_git_context() {
    local host="$1" source_root="$2" context="$3" relative="$4"
    local bundle remote_bundle remote_context command restored destination
    bundle=$(jq -r .bundle_path <<< "$context") || return 4
    remote_bundle="${source_root%/*}/.dsr-context-${relative}.bundle"
    remote_context=$(jq -c --arg path "$remote_bundle" '.bundle_path=$path' <<< "$context") || return 4
    if _act_is_local_host "$host"; then
        (umask 077; set -C; cat "$bundle" > "$remote_bundle") || return 4
        restored=$(git_ops_restore_build_context "$source_root" "$remote_context") || return 4
    elif _act_is_windows_host "$host"; then
        destination=$(_act_get_ssh_destination "$host") || return 4
        local win_bundle win_source script guard
        win_bundle=$(_act_windows_cmd_path "$remote_bundle") || return 4
        win_source=$(_act_windows_cmd_path "$source_root") || return 4
        remote_context=$(jq -c --arg path "$win_bundle" '.bundle_path=$path' <<< "$context") || return 4
        guard=$(_act_windows_reparse_guard_script) || return 4
        command=$(_act_windows_encoded_powershell "\$ErrorActionPreference='Stop'; $guard Assert-PlainDirectory '$win_source'; if (Get-Item -LiteralPath '$win_bundle' -Force -ErrorAction SilentlyContinue) { throw 'Git context bundle already exists' }" pwsh) || return 4
        _act_ssh_exec "$host" "$command" "$_ACT_SYNC_TIMEOUT" </dev/null || return 4
        _act_run_with_timeout "$_ACT_SYNC_TIMEOUT" scp -o ConnectTimeout="$_ACT_SSH_TIMEOUT" \
            -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$bundle" \
            "$destination:$remote_bundle" </dev/null || return 4
        script=$(git_ops_build_context_powershell "$win_source" "$remote_context") || return 4
        command=$(_act_windows_encoded_powershell "$script" pwsh) || return 4
        restored=$(_act_ssh_exec "$host" "$command" "$_ACT_SYNC_TIMEOUT" </dev/null) || return 4
    else
        destination=$(_act_get_ssh_destination "$host") || return 4
        local script quoted_script quoted_source quoted_context
        command="set -e; set -C; umask 077; test -d '${source_root%/*}'; test ! -L '${source_root%/*}'; cat > '$remote_bundle'"
        _act_run_with_timeout "$_ACT_SYNC_TIMEOUT" ssh -o ConnectTimeout="$_ACT_SSH_TIMEOUT" \
            -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$destination" "$command" \
            < "$bundle" || return 4
        script=$(declare -f _git_ops_build_git _git_ops_build_sha256 _git_ops_build_refs git_ops_restore_build_context) || return 4
        script=$'set -uo pipefail\n'"$script"
        printf -v quoted_source '%q' "$source_root"
        printf -v quoted_context '%q' "$remote_context"
        script+=$'\n'"git_ops_restore_build_context $quoted_source $quoted_context"
        # The SSH login shell need not be Bash. Use POSIX quoting for its
        # outer argument; only the explicit Bash interpreter reads the script.
        quoted_script="'${script//\'/\'\\\'\'}'"
        command="bash -c $quoted_script"
        restored=$(_act_ssh_exec "$host" "$command" "$_ACT_SYNC_TIMEOUT" </dev/null) || return 4
    fi
    # Logs belong on stderr; the importer returns exactly one JSON receipt.
    jq -sce --argjson expected "$remote_context" --arg root "$source_root" '
        def path: gsub("\\\\";"/") | if test("^[A-Za-z]:/") then ascii_downcase else . end;
        select(length == 1) | .[0] | select((del(.source_root)) == $expected) |
        select((.source_root | path) == ($root | path)) | .source_root=$root' \
        <<< "$restored"
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
    local tool_name="${config_file##*/}"
    tool_name="${tool_name%.yaml}"

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
        local sib_local sib_configured sib_relative
        sib_configured=$(yq -r ".sibling_crates[$idx].local_path" "$config_file" 2>/dev/null)
        sib_local=$(_act_materialized_source_path "$tool_name" "$sib_configured") || return 4
        sib_relative=$(yq -r ".sibling_crates[$idx].relative_path // \"\"" "$config_file" 2>/dev/null)
        [[ -z "$sib_relative" ]] && sib_relative=$(basename "$sib_local")

        if [[ ! -d "$sib_local" ]]; then
            _log_error "Required sibling crate not found locally: $sib_local"
            return 1
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
            if patch_output=$(_act_ssh_exec "$host" "$(_act_windows_encoded_powershell "[System.IO.File]::WriteAllText('${toml_path}', [System.IO.File]::ReadAllText('${toml_path}').Replace('${sib_configured}','${relative_ref}'))")" 30 2>&1); then
                _log_ok "Patched Cargo.toml on $host: $sib_configured → $relative_ref"
            else
                _log_error "Failed to patch Cargo.toml on $host for sibling $sib_relative"
                [[ -n "$patch_output" ]] && printf '%s\n' "$patch_output" >&2
                sync_failed=true
            fi
        else
            # macOS sed requires '' after -i; Linux sed requires no arg after -i
            # Use perl for portable in-place replacement
            local patch_output
            if patch_output=$(_act_ssh_exec "$host" "cd '${remote_path}' && perl -pi -e 's|\\Q${sib_configured}\\E|${relative_ref}|g' Cargo.toml" 30 2>&1); then
                _log_ok "Patched Cargo.toml on $host: $sib_configured → $relative_ref"
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
# Usage: act_sync_sources <tool_name> [--stage-ordinary | --strict-release --run-id UUID --git-sha SHA] [--] [targets...]
# Returns: JSON with sync results
act_sync_sources() {
    local tool_name="$1"
    shift
    local targets_arg=()
    local strict_release=false
    local stage_ordinary=false ordinary_stage_id="" ordinary_contexts='[]' primary_git_context=null sibling_git_contexts='{}'
    local strict_run_id=""
    local strict_git_sha=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --strict-release)
                strict_release=true
                shift
                ;;
            --stage-ordinary)
                stage_ordinary=true
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

    if $stage_ordinary && $strict_release; then
        _log_error "Ordinary source staging cannot replace a strict snapshot"
        echo '{"status":"error","error":"Conflicting source staging modes"}'
        return 4
    fi

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
    local configured_host_paths=()
    local admitted_host_capabilities=()
    local admitted_writable_paths=()
    local writable_admission_plans=()
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
        local already_added=false
        local sync_host_index
        for sync_host_index in "${!hosts_to_sync[@]}"; do
            if [[ "${hosts_to_sync[$sync_host_index]}" == "$host" ]]; then
                already_added=true
                remote_path="${host_paths[$sync_host_index]}"
                break
            fi
        done
        # Resolve every host before exporting contexts or staging any source.
        # Repo pins and selector fallback choose a location, not permission to
        # write there; the same health gate must admit those paths as well.
        local capability admission_key admitted already_admitted=false
        capability=$(_act_native_host_capability "$tool_name" "$target") || return 4
        admission_key="$host:$capability"
        for admitted in "${admitted_host_capabilities[@]}"; do
            [[ "$admitted" != "$admission_key" ]] || already_admitted=true
        done
        if ! $already_admitted; then
            local readiness_args=("$host")
            [[ -z "$capability" ]] || readiness_args+=(--require "$capability")
            if ! declare -F host_health_is_ready &>/dev/null || ! host_health_is_ready "${readiness_args[@]}"; then
                _log_error "Native source host is not ready: $host${capability:+ (requires $capability)}"
                jq -nc --arg host "$host" \
                    '{status:"error",exit_code:4,host:$host,error:"Native source host is not ready"}'
                return 4
            fi
            admitted_host_capabilities+=("$admission_key")
        fi
        local configured_remote_path="$remote_path"
        if ! $already_added && $stage_ordinary; then
            ordinary_stage_id=$(_act_generate_uuid) || return 4
            remote_path=$(_act_ordinary_source_root_path "$host" "$ordinary_stage_id" "$configured_remote_path") || return 4
        fi

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

        if ! $already_added && $strict_release; then
            if ! remote_path=$(_act_strict_source_root_path \
                "$remote_path" "$tool_name" "$strict_run_id" "$host"); then
                _log_error "Could not derive a safe fresh source root for $host"
                echo '{"status":"error","error":"Invalid strict release source root"}'
                return 4
            fi
        fi

        if ! _act_is_windows_host "$host"; then
            local sync_build_env sync_language sync_cache_root sync_env_pair sync_filtered_env=""
            local sync_writable_paths sync_paths_key sync_paths_admitted=false
            local sync_extra_paths='[]' sync_dependency_count sync_dependency_index
            local sync_dependency_local sync_dependency_relative sync_source_parent
            sync_source_parent=$(dirname "$remote_path") || return 4
            if $strict_release || $stage_ordinary; then
                sync_extra_paths=$(jq -nc --arg path "$sync_source_parent" \
                    '[{role:"source_parent",path:$path}]') || return 4
            fi
            if $strict_release; then
                sync_extra_paths=$(jq -nc --argjson extra "$sync_extra_paths" \
                    --argjson dependencies "$strict_dependency_checkouts" --arg parent "$sync_source_parent" \
                    '$extra + [$dependencies[] | {role:"source_dependency",path:($parent + "/" + .relative_path)}]') || return 4
            elif [[ "$remote_path" != "$local_path" ]]; then
                sync_dependency_count=$(yq -r '.sibling_crates // [] | length' "$config_file") || return 4
                [[ "$sync_dependency_count" =~ ^[0-9]+$ ]] || return 4
                for ((sync_dependency_index = 0; sync_dependency_index < sync_dependency_count; sync_dependency_index++)); do
                    sync_dependency_local=$(yq -r ".sibling_crates[$sync_dependency_index].local_path" "$config_file") || return 4
                    sync_dependency_local=$(_act_materialized_source_path "$tool_name" "$sync_dependency_local") || return 4
                    sync_dependency_relative=$(yq -r ".sibling_crates[$sync_dependency_index].relative_path // \"\"" "$config_file") || return 4
                    [[ -n "$sync_dependency_relative" ]] || sync_dependency_relative=$(basename "$sync_dependency_local") || return 4
                    sync_extra_paths=$(jq -nc --argjson extra "$sync_extra_paths" \
                        --arg path "$sync_source_parent/$sync_dependency_relative" \
                        '$extra + [{role:"source_dependency",path:$path}]') || return 4
                done
            fi
            sync_build_env=$(act_get_build_env "$tool_name" "$target") || return 4
            sync_language=$(yq -r '.language // ""' "$config_file") || return 4
            sync_cache_root=$(yq -r '.strict_cargo_cache_root // ""' "$config_file") || return 4
            if [[ -n "$sync_cache_root" ]] &&
               { ! $strict_release || [[ "$sync_language" != rust ||
                    ! "$sync_cache_root" =~ ^/[A-Za-z0-9_./+-]+$ || "$sync_cache_root" == *..* ]]; }; then
                _log_error "strict_cargo_cache_root requires strict Unix Rust and a canonical absolute private directory"
                return 4
            fi
            while IFS= read -r sync_env_pair; do
                [[ -n "$sync_env_pair" ]] || continue
                if [[ "$sync_language" == rust ]]; then
                    [[ "$sync_env_pair" != CARGO_HOME=* ]] || continue
                    if $strict_release; then
                        [[ "$sync_env_pair" != CARGO_TARGET_DIR=* ]] || continue
                        [[ -z "$sync_cache_root" || "$sync_env_pair" != CARGO_BUILD_BUILD_DIR=* ]] || continue
                    fi
                fi
                sync_filtered_env+="${sync_filtered_env:+$'\n'}$sync_env_pair"
            done <<< "$sync_build_env"
            sync_writable_paths=$(_act_native_writable_paths_json "$remote_path" "$remote_path" \
                "$sync_filtered_env" "$sync_language" "$sync_cache_root" "$sync_extra_paths" true) || return 4
            sync_paths_key="$host:$capability:$sync_writable_paths"
            for admitted in "${admitted_writable_paths[@]}"; do
                [[ "$admitted" != "$sync_paths_key" ]] || sync_paths_admitted=true
            done
            if ! $sync_paths_admitted; then
                writable_admission_plans+=("$(jq -nc --arg host "$host" --arg capability "$capability" \
                    --argjson paths "$sync_writable_paths" '{host:$host,capability:$capability,paths:$paths}')")
                admitted_writable_paths+=("$sync_paths_key")
            fi
        fi
        $already_added && continue
        hosts_to_sync+=("$host")
        host_paths+=("$remote_path")
        configured_host_paths+=("$configured_remote_path")
    done

    # General host/capability admission for the entire plan completes first.
    # Path-bound observations still precede the first context export or write.
    local writable_plan writable_host writable_capability writable_paths
    for writable_plan in "${writable_admission_plans[@]}"; do
        writable_host=$(jq -r .host <<< "$writable_plan") || return 4
        writable_capability=$(jq -r .capability <<< "$writable_plan") || return 4
        writable_paths=$(jq -c .paths <<< "$writable_plan") || return 4
        if ! _act_native_writable_paths_ready "$writable_host" "$writable_capability" "$writable_paths"; then
            jq -nc --arg host "$writable_host" \
                '{status:"error",exit_code:4,host:$host,error:"Native source writable paths are not ready"}'
            return 4
        fi
    done

    if [[ ${#hosts_to_sync[@]} -eq 0 ]]; then
        _log_info "No build locations need source sync"
        echo '{"status":"skipped","synced":0,"hosts":[],"source_roots":{},"target_hosts":{}}'
        return 0
    fi

    if $stage_ordinary; then
        if ! declare -F git_ops_export_build_context >/dev/null; then
            local git_module="${BASH_SOURCE[0]%/*}/git_ops.sh"
            # shellcheck source=src/git_ops.sh
            source "$git_module" || return 4
        fi
        local context_base context_parent
        context_base="${DSR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsr}/source-contexts"
        mkdir -p "$context_base" || return 4
        context_parent=$(mktemp -d "$context_base/ordinary.XXXXXXXX") || return 4
        if ! ordinary_contexts=$(_act_export_ordinary_git_contexts "$config_file" "$local_path" "$context_parent"); then
            echo '{"status":"error","error":"Cannot capture ordinary source Git contexts"}'
            return 4
        fi
        primary_git_context=$(jq -c '.[0].context | del(.bundle_path)' <<< "$ordinary_contexts") || return 4
        sibling_git_contexts=$(jq -c '[.[] | select(.relative_path != "source" and .context != null) |
            {key:.relative_path,value:(.context | del(.bundle_path))}] | from_entries' <<< "$ordinary_contexts") || return 4
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
        local restored_primary=null restored_siblings='{}'

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
        elif $stage_ordinary; then
            local prepared_source_root stage_name="${remote_path%/source}"
            stage_name="${stage_name##*/}"
            if host_sync_output=$(_act_prepare_ordinary_source_root "$host" "$remote_path" 2>&1); then
                prepared_source_root=$(printf '%s\n' "$host_sync_output" | tr -d '\r' | tail -1)
                prepared_source_root="${prepared_source_root//\\//}"
                if [[ "$prepared_source_root" =~ ^([A-Za-z]:)?/[A-Za-z0-9_./:+-]+$ &&
                      "$prepared_source_root" == */"$stage_name"/source && "$prepared_source_root" != *..* ]]; then
                    remote_path="$prepared_source_root"
                    if host_sync_output=$(_act_sync_source "$host" "$local_path" "$remote_path" "${main_sync_excludes[@]}" 2>&1); then
                        source_synced=true
                    fi
                else
                    host_sync_output="Fresh source stage did not return its canonical path"
                fi
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

            if $sync_ok && $stage_ordinary; then
                local context_entry context_relative context_value restored_context import_output
                while IFS= read -r context_entry; do
                    context_relative=$(jq -r .relative_path <<< "$context_entry") || return 4
                    context_value=$(jq -c .context <<< "$context_entry") || return 4
                    [[ "$context_value" != null ]] || continue
                    if import_output=$(_act_restore_ordinary_git_context "$host" \
                        "${remote_path%/*}/$context_relative" "$context_value" "$context_relative" 2>&1); then
                        restored_context=$(printf '%s\n' "$import_output" | grep '^{' | tail -1)
                        if ! jq -e 'type == "object"' <<< "$restored_context" >/dev/null 2>&1; then
                            host_sync_output="Git context import returned no valid receipt for $context_relative"
                            sync_ok=false
                            break
                        fi
                        if [[ "$context_relative" == source ]]; then
                            restored_primary="$restored_context"
                        else
                            restored_siblings=$(jq -c --arg name "$context_relative" --argjson receipt "$restored_context" \
                                '.[$name]=$receipt' <<< "$restored_siblings") || return 4
                        fi
                    else
                        host_sync_output="Git context import failed for $context_relative: $import_output"
                        printf '%s\n' "$host_sync_output" >&2
                        sync_ok=false
                        break
                    fi
                done < <(jq -c '.[]' <<< "$ordinary_contexts")
                if $sync_ok && ! _act_verify_ordinary_git_contexts "$ordinary_contexts"; then
                    host_sync_output="Controller Git context changed during source synchronization"
                    sync_ok=false
                fi
            fi

            if $sync_ok; then
                synced=$((synced + 1))
                results+=("$(jq -nc --arg host "$host" --arg path "$remote_path" \
                    --arg configured_path "${configured_host_paths[$i]}" --argjson staged "$stage_ordinary" \
                    --argjson context "$restored_primary" --argjson siblings "$restored_siblings" \
                    '{host:$host,path:$path,status:"success"} +
                     (if $staged then {configured_path:$configured_path,git_context:$context,
                       sibling_git_contexts:$siblings} else {} end)')")
                source_root_entries+=("$(jq -nc --arg host "$host" --arg path "$remote_path" \
                    '{key: $host, value: $path}')")
            else
                failed=$((failed + 1))
                results+=("$(jq -nc --arg host "$host" --arg path "$remote_path" \
                    --arg error "$(_act_sync_error_summary "$host_sync_output")" \
                    '{host: $host, path: $path, status: "failed", error: $error}')")
            fi
        else
            failed=$((failed + 1))
            results+=("$(jq -nc --arg host "$host" --arg path "$remote_path" \
                --arg error "$(_act_sync_error_summary "$host_sync_output")" \
                '{host: $host, path: $path, status: "failed", error: $error}')")
        fi
    done

    # Earlier hosts cannot remain admitted if the controller identity moved
    # while a later host was transferring its source or context bundle.
    if $stage_ordinary && ! _act_verify_ordinary_git_contexts "$ordinary_contexts"; then
        synced=0
        failed=${#hosts_to_sync[@]}
        source_root_entries=()
        local failed_results=() prior_result
        for prior_result in "${results[@]}"; do
            failed_results+=("$(jq -c '.status="failed" |
                .error="Controller Git context changed during source synchronization"' <<< "$prior_result")")
        done
        results=("${failed_results[@]}")
    fi

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
        --argjson staged_ordinary "$stage_ordinary" \
        --argjson git_context "$primary_git_context" \
        --argjson sibling_git_contexts "$sibling_git_contexts" \
        '{
            status: $status,
            synced: $synced,
            failed: $failed,
            duration_seconds: $duration,
            hosts: $hosts,
            source_roots: $source_roots,
            target_hosts: $target_hosts
        } + (if $staged_ordinary then {staged_ordinary:true,git_context:$git_context,
            sibling_git_contexts:$sibling_git_contexts} else {} end)'

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
    # Keep release-routing names in ${arch}, but use the compiler's spelling
    # for Go selectors. An inline GOARCH assignment otherwise overrides the
    # correctly resolved environment with unsupported GOARCH=armv7. The
    # existing environment resolver still owns the required GOARM=7 value.
    local go_arch="$arch"
    [[ "$go_arch" != armv7 ]] || go_arch=arm
    cmd="${cmd//\$\{goarch\}/$go_arch}"
    cmd="${cmd//\$\{GOARCH\}/$go_arch}"

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
    global_env=$(yq -r '.env // {} | to_entries | map(.key + "=" + .value) | .[]' "$config_file") || return 4
    [[ -n "$global_env" ]] && result="$global_env"

    # Get platform-specific cross_compile env vars (join with newline to preserve spaces in values)
    local platform_env
    platform_env=$(yq -r ".cross_compile.\"$platform\".env // {} | to_entries | map(.key + \"=\" + .value) | .[]" "$config_file") || return 4
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
        env_language=$(yq -r '.language // ""' "$config_file") || return 4
        derive_opt=$(yq -r '.derive_cargo_build_target' "$config_file") || return 4
        if [[ "$env_language" == go ]]; then
            # Go otherwise silently builds the host platform (or the
            # operator's GOOS/GOARCH), even when this worker was scheduled for
            # another target. Resolve global then platform configuration just
            # as the launcher does, and export one unambiguous target pair.
            # Cross-compilation policy such as CGO_ENABLED stays configured by
            # the repository; deriving a target must not disable cgo for it.
            local go_os="${platform%%/*}" go_arch="${platform##*/}" go_arm=""
            local configured_go_os="" configured_go_arch="" configured_go_arm=""
            local go_environment="" go_pair
            local go_os_set=false go_arch_set=false go_arm_set=false
            if [[ ! "$platform" =~ ^[a-z][a-z0-9]*/[a-z0-9]+$ ]]; then
                _log_error "Invalid Go target platform: $platform"
                return 4
            fi
            # DSR's armv7 routing name selects Go's 32-bit ARM target with
            # an explicit ISA level. Preserve ordinary configured ARMv7
            # recipes without changing GOARM policy for other platforms.
            if [[ "$go_arch" == armv7 ]]; then
                go_arch=arm
                go_arm=7
            fi
            while IFS= read -r go_pair; do
                [[ -n "$go_pair" ]] || continue
                case "$go_pair" in
                    GOOS=*) configured_go_os="${go_pair#*=}"; go_os_set=true; continue ;;
                    GOARCH=*) configured_go_arch="${go_pair#*=}"; go_arch_set=true; continue ;;
                    GOARM=*)
                        if [[ -n "$go_arm" ]]; then
                            configured_go_arm="${go_pair#*=}"
                            go_arm_set=true
                            continue
                        fi
                        ;;
                esac
                [[ -z "$go_environment" ]] || go_environment+=$'\n'
                go_environment+="$go_pair"
            done <<< "$result"
            if { $go_os_set && [[ "$configured_go_os" != "$go_os" ]]; } ||
               { $go_arch_set && [[ "$configured_go_arch" != "$go_arch" ]]; }; then
                _log_error "Configured Go target GOOS=${configured_go_os:-unset} GOARCH=${configured_go_arch:-unset} conflicts with requested platform $platform"
                return 4
            fi
            if [[ -n "$go_arm" ]] && $go_arm_set && [[ "$configured_go_arm" != "$go_arm" ]]; then
                _log_error "Configured GOARM=${configured_go_arm:-unset} conflicts with requested platform $platform (requires GOARM=$go_arm)"
                return 4
            fi
            result="$go_environment"
            derived_pairs+=$'\n'"GOOS=$go_os"$'\n'"GOARCH=$go_arch"
            [[ -z "$go_arm" ]] || derived_pairs+=$'\n'"GOARM=$go_arm"
        fi
        if [[ "$env_language" == "rust" && "$derive_opt" != "false" ]]; then
            local derived_triple
            derived_triple=$(act_get_build_env_value "$result" "CARGO_BUILD_TARGET" 2>/dev/null || true)
            if [[ -z "$derived_triple" ]]; then
                # A direct singleton call defaults to the primary. Matrix
                # workers supplied their exact declared variant above.
                derived_triple=$(yq -r ".target_triples.\"$platform\" | select(tag == \"!!seq\") // [.] | .[0] // \"\"" \
                    "$config_file") || return 4
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

# Get the effective value from ordered, newline-delimited KEY=VALUE pairs.
# Platform overrides follow global declarations, and the launchers export them
# in that order. Keep all declarations for policy checks, but read the last
# matching assignment here, including an explicitly empty value.
# Usage: act_get_build_env_value <build_env> <key>
act_get_build_env_value() {
    local build_env="$1"
    local key="$2"
    local env_pair value="" found=false

    while IFS= read -r env_pair; do
        [[ -z "$env_pair" ]] && continue
        if [[ "$env_pair" == "$key="* ]]; then
            value="${env_pair#*=}"
            found=true
        fi
    done <<< "$build_env"

    if [[ "$found" == true ]]; then
        printf '%s\n' "$value"
        return 0
    fi
    return 1
}

_act_default_rust_target_triple() {
    case "$1" in
        linux/amd64) printf 'x86_64-unknown-linux-gnu\n' ;;
        linux/arm64) printf 'aarch64-unknown-linux-gnu\n' ;;
        linux/386) printf 'i686-unknown-linux-gnu\n' ;;
        linux/armv7) printf 'armv7-unknown-linux-gnueabihf\n' ;;
        darwin/amd64) printf 'x86_64-apple-darwin\n' ;;
        darwin/arm64) printf 'aarch64-apple-darwin\n' ;;
        windows/amd64) printf 'x86_64-pc-windows-msvc\n' ;;
        windows/arm64) printf 'aarch64-pc-windows-msvc\n' ;;
        windows/386) printf 'i686-pc-windows-msvc\n' ;;
        freebsd/amd64) printf 'x86_64-unknown-freebsd\n' ;;
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
        CARGO_*|RUST*|XWIN_*|TEMP|TMP|DSR_RELEASE_GIT_SHA|DSR_RELEASE_GIT_REF|DSR_TARGET_TRIPLE|\
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

# Resolve a built output inside the language's effective output directory.
# Usage: act_get_remote_artifact_path <language> <remote_path> <build_env> <name> <platform> [build_profile] [binary|file]
# Only native binaries receive the Windows .exe suffix. Configured companion
# files have literal basenames, even when executable or extensionless.
act_get_remote_artifact_path() {
    local language="$1"
    local remote_path="${2%/}"
    local build_env="$3"
    local binary_name="$4"
    local platform="$5"
    local build_profile="${6:-release}"
    local artifact_kind="${7:-binary}"
    local artifact_base=""

    case "$artifact_kind" in
        binary|file) ;;
        *)
            _log_error "Unknown native artifact kind: $artifact_kind"
            return 4
            ;;
    esac

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
        if [[ "$artifact_kind" == binary ]]; then
            # The archive inventory already normalizes an explicit .exe suffix.
            # Collection must not turn that selected executable into app.exe.exe.
            remote_artifact_path="${remote_artifact_path%.[eE][xX][eE]}.exe"
        fi
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
_act_materialized_source_path() {
    local tool_name="$1" configured_path="$2" materialized paths="${_ACT_ISOLATED_SOURCE_PATHS:-}"
    if [[ "${_ACT_ISOLATED_SOURCE_TOOL:-}" != "$tool_name" ]]; then
        printf '%s\n' "$configured_path"
        return 0
    fi
    [[ -n "$paths" ]] || return 4
    materialized=$(jq -er --arg path "$configured_path" \
        '.[$path] | strings | select(startswith("/"))' <<< "$paths") || return 4
    [[ -d "$materialized" && ! -L "$materialized" ]] || return 4
    printf '%s\n' "$materialized"
}

act_get_local_path() {
    local tool_name="$1"
    local config_file="$ACT_REPOS_DIR/${tool_name}.yaml"

    if [[ ! -f "$config_file" ]]; then
        return 4
    fi

    local configured_path
    configured_path=$(yq -r '.local_path // ""' "$config_file" 2>/dev/null) || return 4
    _act_materialized_source_path "$tool_name" "$configured_path"
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
        local selected_targets_json
        selected_targets_json=$(printf '%s\0' "${targets_arg[@]}" | jq -Rsc 'split("\u0000")[:-1]') || return 4
        dsr_platform_validate_targets_json "$selected_targets_json" "selected targets for $tool_name" || return 4
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
            ready=$((ready + 1))
        else
            results+=("{\"host\":\"$host\",\"path\":\"$remote_path\",\"status\":\"failed\"}")
            failed=$((failed + 1))
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
    elif _act_unix_program_needs_stdin "$cmd"; then
        _act_ssh_exec_unix_program "$host" "$cmd" "$timeout_sec"
        return
    fi

    if _act_is_local_host "$host"; then
        _act_run_with_timeout "$timeout_sec" bash -lc "$cmd"
    else
        local ssh_destination
        ssh_destination=$(_act_get_ssh_destination "$host") || return 4
        _act_run_with_timeout "$timeout_sec" ssh \
            -T \
            -n \
            -o ConnectTimeout="$_ACT_SSH_TIMEOUT" \
            -o BatchMode=yes \
            -o StrictHostKeyChecking=accept-new \
            "$ssh_destination" "$cmd"
    fi
}

# Linux refuses any single exec argument of 128 KiB or more (MAX_ARG_STRLEN),
# whatever ARG_MAX allows. Generated strict Cargo programs exceed that
# (dsr-00n2), and the login shell's `-c` argument is one such string. Programs
# of 64 KiB and up therefore travel on stdin; smaller commands keep argv.
_ACT_UNIX_ARGV_PROGRAM_MAX_BYTES=65535

_act_unix_program_needs_stdin() {
    # Byte length without a subshell; the caller's locale returns on exit.
    local LC_ALL=C
    (( ${#1} > _ACT_UNIX_ARGV_PROGRAM_MAX_BYTES ))
}

# Run a Unix program read from stdin by the same interpreter that would have
# run it from argv: the remote login shell (sshd runs `$SHELL -c`), or a local
# login bash. The brace group makes the shell parse the whole program before
# running any of it, so no command can consume program text, and the program
# still sees /dev/null on stdin, as with `ssh -n`.
_act_ssh_exec_unix_program() {
    local host="$1" program="$2" timeout_sec="$3" wrapped
    # The here-strings below supply the final newline.
    printf -v wrapped '{\n%s\n} </dev/null' "$program"
    if _act_is_local_host "$host"; then
        _act_run_with_timeout "$timeout_sec" bash -l -s <<< "$wrapped"
    else
        local ssh_destination
        ssh_destination=$(_act_get_ssh_destination "$host") || return 4
        # Single-quoted on purpose: $SHELL expands on the remote host. -T keeps
        # a configured RequestTTY from putting the program through a pty.
        # shellcheck disable=SC2016
        _act_run_with_timeout "$timeout_sec" ssh \
            -T \
            -o ConnectTimeout="$_ACT_SSH_TIMEOUT" \
            -o BatchMode=yes \
            -o StrictHostKeyChecking=accept-new \
            "$ssh_destination" 'exec "$SHELL" -s' <<< "$wrapped"
    fi
}

# Emit a host-side wrapper for opt-in intermediate Cargo caching. Final outputs
# remain in the run's fresh target directory; no cached output is collected on
# failure. Python owns the advisory lock through build and output detachment.
_act_strict_cargo_cache_script() {
    local cache_root="$1" cache_contract="$2" command="$3" zig_shim_dir="${4:-}"
    local root_q contract_q command_q selection_script
    printf -v root_q '%q' "$cache_root"
    printf -v contract_q '%q' "$cache_contract"
    printf -v command_q '%q' "$command"
    selection_script=$(_act_toolchain_identity_script context /dev/null "$command" "" "" "" "$zig_shim_dir") || return $?
    # Assignment preserves an inherited export attribute. Clear it before
    # collecting the potentially large observation, so only fd3 carries it.
    printf 'unset dsr_cache_context || exit $?\n'
    printf 'dsr_cache_context=$(\n%s\n) || exit $?\n' "$selection_script"
    # tomllib needs Python 3.11+; see _act_toolchain_identity_script.
    _act_toolchain_python_prefix_sh "$zig_shim_dir" || return $?
    # Environment entries have the same single-argument limit as exec argv on
    # Linux. Keep the observation on an inherited input descriptor instead.
    printf 'unset DSR_CARGO_TOOLCHAIN_CONTEXT || exit $?\n'
    printf '"$dsr_tool_python" -I - %s %s %s 3<<< "$dsr_cache_context" <<\x27DSR_CARGO_CACHE_PY\x27\n' "$root_q" "$contract_q" "$command_q"
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

with os.fdopen(3) as context_input:
    context = json.load(context_input)
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
# The actual context observer already resolved the reviewed launcher and its
# selected compiler in this command's effective environment. Reuse those
# facts and recheck bytes; a second stale dispatcher must not choose a
# different Cargo (or reject a valid v6/HOME fallback) for the cache key.
def compiler_identity(program, tool, version_args, observed):
    selected = shutil.which(program, path=probe_env.get('PATH'))
    require(selected, 'compiler executable missing: ' + tool)
    selected = pathlib.Path(selected).resolve()
    record = selected_identity['tools'].get(tool)
    require(isinstance(record, dict), 'missing observed compiler identity: ' + tool)
    require(pathlib.Path(record['selected_path']).resolve() == selected and
            digest(selected) == record['selected_sha256'],
            'selected compiler changed after context observation: ' + tool)
    actual = pathlib.Path(record.get('resolved_path', record['selected_path'])).resolve()
    actual_digest = record.get('resolved_sha256', record['selected_sha256'])
    require(record.get('resolved_kind', record['selected_kind']) == 'executable' and
            digest(actual) == actual_digest, 'unresolved or changed compiler executable: ' + tool)
    with actual.open('rb') as stream:
        require(stream.read(2) != b'#!' and actual.name != 'rustup', 'unresolved compiler wrapper: ' + tool)
    recorded_version = record['version'].splitlines()[0] if tool == 'cargo' else record['version']
    require(recorded_version == observed and probe([str(actual), *version_args]) == observed,
            'observed/selected/native compiler version disagreement: ' + tool)
    # Dispatch dependencies belong to the same original observation too.
    # A stable version or native executable cannot hide a changed launcher.
    for name in ('rustup_resolver', 'toolchain_launcher', 'sysroot_resolver'):
        dependency = record.get(name)
        if dependency is None:
            continue
        require(isinstance(dependency, dict), 'invalid compiler dispatch observation: ' + name)
        for path_key, hash_key in (('path', 'sha256'), ('selected_path', 'selected_sha256'),
                                   ('resolved_path', 'resolved_sha256')):
            if path_key in dependency:
                require(digest(pathlib.Path(dependency[path_key]).resolve()) == dependency.get(hash_key),
                        'compiler dispatch dependency changed: ' + name)
    toolchain_launcher = record.get('toolchain_launcher', {'path': str(actual), 'sha256': actual_digest})
    return {'selected_path': str(selected), 'selected_sha256': record['selected_sha256'],
            'toolchain_launcher': toolchain_launcher,
            'executable_path': str(actual), 'executable_sha256': actual_digest}
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
shim_selection = selected_identity.get('selection', {}).get('dsr_cargo_shim')
if shim_selection is not None:
    for variable, field in (('DSR_RUST_TARGET', 'rust_target'), ('DSR_ZIG_TARGET', 'zig_target'),
                            ('DSR_LINUX_GLIBC_FLOOR', 'glibc_floor')):
        # An explicit unversioned command requests no glibc floor. Preserve
        # null in its identity while binding the actual empty environment
        # value; never manufacture a versioned target for cache admission.
        expected = '' if shim_selection[field] is None else shim_selection[field]
        require(probe_env.get(variable, '') == expected, 'generated shim dispatch context changed')
        influences[variable] = expected
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
explicit_zig_selection = selected_identity.get('selection', {}).get('cargo_zigbuild')
if explicit_zig_selection is not None:
    # A shared Rust target must not collapse two explicit GNU ABI requests
    # into the same cache namespace after target canonicalization.
    contract['toolchain']['cargo_zigbuild'] = explicit_zig_selection
if shim_selection is not None:
    # Only the generated launcher's per-run location is ephemeral. The full
    # path remains in the coordinator-held executable observation; the cache
    # key retains its verified bytes/kind and explicit target/floor influences.
    # This is cache key material, not a substitute toolchain identity receipt.
    contract['toolchain']['tools'] = dict(contract['toolchain']['tools'])
    shim_key = dict(contract['toolchain']['tools']['dsr_cargo_shim'])
    del shim_key['selected_path']
    contract['toolchain']['tools']['dsr_cargo_shim'] = shim_key
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
# Args: mode output_json build_cmd extra_tools(space-separated) receipt_pin expected_cwd zig_shim_dir
_act_toolchain_identity_script() {
    local mode="$1" output="$2" build_cmd="$3" extra_tools="${4:-}" receipt_pin="${5:-}" expected_cwd="${6:-}"
    local zig_shim_dir="${7:-}" zig_shim_hash="" shim_dir_q shim_hash_q
    local output_q command_q extra_q pin_q cwd_q python_q=python3
    [[ "$mode" == record || "$mode" == verify || "$mode" == read || "$mode" == metadata || "$mode" == context || "$mode" == target || "$mode" == selection ]] || return 4
    [[ "$output" == /* && "$output" != *..* ]] || return 4
    [[ -z "$expected_cwd" || ( "$expected_cwd" == /* && "$expected_cwd" != *..* ) ]] || return 4
    if [[ -n "$zig_shim_dir" ]]; then
        [[ "$zig_shim_dir" == /* && "$zig_shim_dir" != *..* ]] || return 4
        # Derive authority from the controller's generator, never from worker
        # bytes or a build-controlled environment variable. Preserve the exact
        # trailing newline materialized by _act_zig_shim_prefix_sh.
        zig_shim_hash=$(_act_zig_cargo_shim_sh | _act_sha256 /dev/stdin) || return 4
        [[ "$zig_shim_hash" =~ ^[0-9a-f]{64}$ ]] || return 4
    fi
    printf -v output_q '%q' "$output"
    printf -v command_q '%q' "$build_cmd"
    printf -v extra_q '%q' "$extra_tools"
    printf -v pin_q '%q' "$receipt_pin"
    printf -v cwd_q '%q' "$expected_cwd"
    printf -v shim_dir_q '%q' "$zig_shim_dir"
    printf -v shim_hash_q '%q' "$zig_shim_hash"
    # Target-only planning runs on the coordinator without invoking any build
    # tools or reading its Cargo configuration. The configured PATH may be a
    # remote host path, so use the coordinator's absolute Python interpreter.
    if [[ "$mode" == target || "$mode" == selection ]]; then
        python_q=$(command -v python3) || return 4
        printf -v python_q '%q' "$python_q"
    else
        # Attesting a Cargo configuration needs tomllib (Python 3.11+), but a
        # login shell can put an older python3 first (macOS path_helper puts
        # /usr/bin/python3 3.9 ahead of Homebrew). Prefer a new enough one.
        _act_toolchain_python_prefix_sh "$zig_shim_dir" || return $?
        python_q='"$dsr_tool_python"'
    fi
    printf '%s -I - %s %s %s %s %s %s %s %s <<\x27DSR_TOOLCHAIN_IDENTITY_PY\x27\n' "$python_q" "$mode" "$output_q" "$command_q" "$extra_q" "$pin_q" "$cwd_q" "$shim_dir_q" "$shim_hash_q"
    cat <<'PY'
import hashlib, json, os, pathlib, re, shutil, stat, subprocess, sys

mode, output, command, extra, receipt_pin, expected_cwd, zig_shim_dir, zig_shim_hash = sys.argv[1:9]

def fail(message):
    sys.stderr.write('[dsr] toolchain identity: ' + message + '\n')
    sys.exit(86)

if expected_cwd:
    try:
        physical_cwd = str(pathlib.Path(expected_cwd).resolve(strict=True))
        if not pathlib.Path(physical_cwd).is_dir():
            fail('requested build cwd is not a directory')
    except (OSError, RuntimeError) as error:
        fail('cannot resolve requested build cwd: ' + str(error))
    if mode in ('record', 'verify') and os.getcwd() != physical_cwd:
        fail('toolchain observation does not run in the requested build cwd')
else:
    physical_cwd = None

def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as stream:
        for block in iter(lambda: stream.read(1048576), b''):
            h.update(block)
    return h.hexdigest()

def receipt_identity(info):
    # Strings preserve nanosecond/inode precision through jq and SSH argv.
    return ':'.join(str(value) for value in (
        info.st_dev, info.st_ino, info.st_mode, info.st_nlink,
        info.st_uid, info.st_gid, info.st_size, info.st_mtime_ns, info.st_ctime_ns))

def receipt_info(info):
    if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or
            info.st_uid != os.geteuid() or info.st_mode & 0o077 or
            not 0 < info.st_size <= 1048576):
        fail('identity receipt is not a bounded private regular file')

def read_receipt():
    try:
        pin = json.loads(receipt_pin)
        if (not isinstance(pin, dict) or set(pin) != {'sha256', 'identity'} or
                not isinstance(pin['sha256'], str) or
                not re.fullmatch(r'[0-9a-f]{64}', pin['sha256']) or
                not isinstance(pin['identity'], str) or
                not re.fullmatch(r'[0-9]+(?::[0-9]+){8}', pin['identity'])):
            fail('missing or invalid coordinator-held identity receipt pin')
        fd = os.open(output, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'rb') as stream:
            before = os.fstat(stream.fileno())
            receipt_info(before)
            if receipt_identity(before) != pin['identity']:
                fail('identity receipt replaced or modified since recording')
            data = stream.read(1048577)
            after = os.fstat(stream.fileno())
            named = os.stat(output, follow_symlinks=False)
            if (len(data) != before.st_size or
                    receipt_identity(after) != pin['identity'] or
                    receipt_identity(named) != pin['identity'] or
                    hashlib.sha256(data).hexdigest() != pin['sha256']):
                fail('identity receipt bytes or named inode changed during verification')
        recorded = json.loads(data)
        if not isinstance(recorded, dict):
            fail('identity receipt is not an object')
        if physical_cwd is not None and recorded.get('cwd') != physical_cwd:
            fail('pinned observation does not bind the requested physical build cwd')
        return recorded
    except (OSError, ValueError, TypeError) as error:
        fail('cannot read pinned identity receipt ' + output + ': ' + str(error))

recorded = read_receipt() if mode in ('verify', 'read') else None
if mode == 'read':
    # Collection reads exactly the observation pinned before the compiler,
    # without probing a different login-shell toolchain after the build.
    json.dump(recorded, sys.stdout, sort_keys=True)
    sys.stdout.write('\n')
    sys.exit(0)

def shell_word(raw, variables=()):
    # Read a bounded shell word without evaluating code. Quotes and ordinary
    # escapes are preserved by cargo_shell_words. Only explicitly known
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
    return name in ('PATH', 'DSR_TARGET_TRIPLE', 'DSR_RUST_TARGET', 'DSR_ZIG_TARGET',
                    'DSR_LINUX_GLIBC_FLOOR') or name.startswith(('CARGO_', 'RUST', 'XWIN_')) or bool(re.search(
        r'(^|_)(CC|CXX|CPP|AR|RANLIB|LD|CFLAGS|CXXFLAGS|CPPFLAGS|LDFLAGS|SDKROOT|MACOSX_DEPLOYMENT_TARGET)($|_)', name))


def cargo_env_exemption(name, entry):
    if name not in ('RUST_MIN_STACK', 'RUST_TEST_THREADS', 'CARGO_INCREMENTAL'):
        return None
    force = False
    value = entry
    if isinstance(entry, dict):
        if set(entry) - {'value', 'force', 'relative'}:
            fail('unsupported Cargo environment attributes for ' + name)
        value = entry.get('value')
        force = entry.get('force', False)
        relative = entry.get('relative', False)
        if type(force) is not bool or type(relative) is not bool or relative:
            fail('Cargo numeric environment requires boolean force and relative=false: ' + name)
    # Admit only the disabling value for Cargo's children. Cargo itself reads
    # its process environment before applying [env] (checked below).
    if name == 'CARGO_INCREMENTAL':
        if value != '0':
            fail('Cargo incremental environment requires the string "0": ' + name)
    elif not isinstance(value, str) or not re.fullmatch(r'[1-9][0-9]*', value):
        fail('Cargo environment requires a positive-integer string: ' + name)
    return {'name': name, 'value': value, 'force': force}


def cargo_effective_environment(config, receipts, environment):
    # Cargo applies [env] to its children, not to this observer. Apply the same
    # restricted values when probing those children, after inline assignments
    # have been parsed. Inherited table attributes were merged before defaults.
    effective = {}
    for name, entry in sorted(config.get('env', {}).items()):
        row = cargo_env_exemption(name, entry)
        # Cargo consumes this variable before applying [env] to its children;
        # force=true cannot override an enabling value in Cargo's own process.
        if name == 'CARGO_INCREMENTAL' and name in environment and environment[name] != '0':
            fail('Cargo process incremental environment requires the string "0": ' + name)
        ambient = name in environment and not row['force']
        value = environment[name] if ambient else row['value']
        valid = value == '0' if name == 'CARGO_INCREMENTAL' else (
            isinstance(value, str) and re.fullmatch(r'[1-9][0-9]*', value))
        if not valid:
            fail('effective Cargo numeric environment is invalid: ' + name)
        effective[name] = (value, row['force'], 'environment' if ambient else 'configuration')
    for receipt in receipts:
        for row in receipt.get('env_exemptions', []):
            value, force, source = effective[row['name']]
            row.update(effective_value=value, effective_force=force, effective_source=source)
    for name, (value, _, _) in effective.items():
        environment[name] = value


def cargo_flag_words(value):
    if isinstance(value, str):
        if '\x00' in value:
            fail('Cargo rustflags contain a NUL byte')
        return value.split()
    if isinstance(value, list) and all(isinstance(word, str) for word in value):
        if any('\x00' in word for word in value):
            fail('Cargo rustflags contain a NUL byte')
        return list(value)
    fail('Cargo rustflags must be a string or an array of strings')


def cargo_environment_flags(name, value):
    # Cargo's RUSTFLAGS parser splits on literal spaces, then trims each
    # argument. It does not split internal tabs/newlines or interpret quotes.
    # Encoded flags preserve empty arguments, except that the empty variable
    # itself means no flags. Do not silently rewrite the compiler invocation.
    if name == 'CARGO_ENCODED_RUSTFLAGS':
        return value.split('\x1f') if value else []
    if name == 'RUSTFLAGS':
        if any(character in value for character in '\x1c\x1d\x1e\x1f'):
            fail('unsupported control separator in Cargo RUSTFLAGS')
        return [word.strip() for word in value.split(' ') if word.strip()]
    return cargo_flag_words(value)


def cargo_merge_flags(previous, current):
    cargo_flag_words(current)
    if previous is None:
        return current
    if isinstance(previous, list) and isinstance(current, list):
        return previous + current
    if isinstance(previous, str) and isinstance(current, str):
        return current
    fail('Cargo rustflags change type across configuration files')


def cargo_validate_flags(words, cfg_scoped=False):
    # Inspect actual argument boundaries, including rustc's long option form.
    # Response files would hide compiler/linker selectors from this observer.
    for index, word in enumerate(words):
        if '\x00' in word or word.startswith('@'):
            fail('rustflags response files and NUL bytes are not statically attested')
        if re.match(r'^-[gOvVh]+[CZ]', word):
            fail('clustered rustflags compiler selectors are not statically attested')
        for short, long, forbidden in (('-C', '--codegen', 'linker'),
                                        ('-Z', '--unstable-options', 'codegen-backend')):
            option = None
            if word in (short, long):
                option = words[index + 1] if index + 1 < len(words) else ''
            elif word.startswith(short) and len(word) > len(short):
                option = word[len(short):]
            elif word.startswith(long + '='):
                option = word[len(long) + 1:]
            if option is not None:
                key = re.split(r'[=\s]', option.strip().lstrip('='), maxsplit=1)[0]
                # rustc accepts underscores as well as hyphens in -C/-Z keys.
                if key.replace('_', '-') == forbidden:
                    if forbidden == 'linker':
                        fail('rustflags compiler/linker overrides require explicit attested configuration; move the linker option to [target.<triple>] linker')
                    fail('rustflags compiler/linker overrides require explicit attested configuration')
        if cfg_scoped and (word in ('--cfg', '--target') or word.startswith(('--cfg=', '--target='))):
            fail('cfg-scoped Cargo selection cannot be combined with rustflags --cfg or --target')


def cargo_parse_cfg(text):
    # A deliberately bounded, non-evaluating subset of cargo-platform's grammar.
    # Only target invariants are supported: feature/panic/profile/custom cfgs
    # depend on flags or build scripts and cannot be inferred from a bare probe.
    keys = {'target_arch', 'target_os', 'target_env', 'target_vendor',
            'target_family', 'target_endian', 'target_pointer_width', 'target_abi'}
    if (not isinstance(text, str) or len(text) > 4096 or
            not text.startswith('cfg(') or not text.endswith(')')):
        fail('unsupported Cargo cfg expression')
    tokens, offset = [], 0
    # cargo-platform skips only ASCII spaces, not arbitrary whitespace.
    pattern = re.compile(r' *([A-Za-z_][A-Za-z0-9_]*|"[^"\\\x00-\x1f]*"|[(),=])')
    while offset < len(text):
        match = pattern.match(text, offset)
        if not match:
            fail('unsupported token in Cargo cfg expression: ' + text)
        tokens.append(match.group(1))
        offset = match.end()
        if len(tokens) > 512:
            fail('Cargo cfg expression exceeds the token bound')
    position = 0

    def take(expected=None):
        nonlocal position
        if position == len(tokens) or expected is not None and tokens[position] != expected:
            fail('malformed Cargo cfg expression: ' + text)
        token = tokens[position]
        position += 1
        return token

    def expression(depth=0):
        if depth > 32:
            fail('Cargo cfg expression exceeds the nesting bound')
        name = take()
        if name in ('all', 'any', 'not'):
            take('(')
            children = []
            if position < len(tokens) and tokens[position] != ')':
                while True:
                    children.append(expression(depth + 1))
                    if position < len(tokens) and tokens[position] == ',':
                        # Unlike all()/any(), Cargo's not() has no comma form.
                        if name == 'not':
                            fail('Cargo cfg not() does not accept a comma')
                        take(',')
                        if position < len(tokens) and tokens[position] == ')':
                            break
                    else:
                        break
            take(')')
            if name == 'not' and len(children) != 1:
                fail('Cargo cfg not() requires exactly one predicate')
            return (name, children)
        if position < len(tokens) and tokens[position] == '=':
            take('=')
            value = take()
            if name not in keys or len(value) < 2 or not value.startswith('"') or not value.endswith('"'):
                fail('unsupported Cargo cfg key/value predicate: ' + text)
            return ('atom', (name, value[1:-1]))
        if name not in ('unix', 'windows'):
            fail('unsupported Cargo cfg name: ' + name)
        return ('atom', (name, None))

    take('cfg')
    take('(')
    result = expression()
    take(')')
    if position != len(tokens):
        fail('trailing input in Cargo cfg expression: ' + text)
    return result


def cargo_match_cfg(expression, facts):
    name, value = expression
    if name == 'atom':
        return value in facts
    # Parsing/validation always visits every branch before boolean evaluation.
    values = [cargo_match_cfg(child, facts) for child in value]
    if name == 'not':
        return not values[0]
    return all(values) if name == 'all' else any(values)


def cargo_parse_target_cfg(text):
    if not text or len(text.encode('utf-8')) > 65536:
        fail('rustc target cfg output is missing or exceeds the size bound')
    facts = set()
    for line in text.splitlines():
        match = re.fullmatch(r'([A-Za-z_][A-Za-z0-9_]*)(?:="([^"\\\x00-\x1f]*)")?', line)
        if not match:
            fail('malformed rustc target cfg output')
        fact = (match.group(1), match.group(2))
        if fact in facts:
            fail('duplicate rustc target cfg output')
        facts.add(fact)
    for key in ('target_arch', 'target_os', 'target_env', 'target_vendor',
                'target_endian', 'target_pointer_width'):
        if len([value for name, value in facts if name == key and value is not None]) != 1:
            fail('missing or ambiguous rustc target cfg: ' + key)
    return facts


def cargo_target_settings(config, triple, environment, facts):
    exact = config['target'].get(triple, {})
    matches, decisions, cfg_flags, cfg_linkers = [], [], [], []
    for selector, values in sorted(config['target'].items()):
        if not selector.startswith('cfg('):
            continue
        matched = cargo_match_cfg(cargo_parse_cfg(selector), facts)
        row = {'expression': selector, 'matched': matched}
        if 'rustflags' in values:
            row['rustflags'] = cargo_flag_words(values['rustflags'])
        if 'linker' in values:
            row['linker'] = values['linker']
        decisions.append(row)
        if not matched:
            continue
        matches.append(selector)
        cfg_flags.extend(row.get('rustflags', []))
        if 'linker' in row:
            cfg_linkers.append((selector, row['linker']))
    variable = 'CARGO_TARGET_' + re.sub(r'[^A-Za-z0-9]', '_', triple).upper() + '_LINKER'
    if variable in environment and not environment[variable]:
        fail('an empty Cargo target linker is not statically attested')
    linker = environment.get(variable) or exact.get('linker', '')
    linker_source = variable if environment.get(variable) else ('target.' + triple if linker else None)
    if not linker:
        if len(cfg_linkers) > 1:
            fail('multiple Cargo cfg linkers match the build target')
        if cfg_linkers:
            linker_source, linker = cfg_linkers[0]
    # Keep the configured contributions separate from environment overrides.
    # Cargo's target-specific environment flags append to the exact table.
    target_flags = cargo_flag_words(exact.get('rustflags', []))
    target_variable = variable.removesuffix('LINKER') + 'RUSTFLAGS'
    target_flags.extend(cargo_flag_words(environment.get(target_variable, '')))
    target_flags.extend(cfg_flags)
    if 'CARGO_ENCODED_RUSTFLAGS' in environment:
        flags = cargo_environment_flags('CARGO_ENCODED_RUSTFLAGS', environment['CARGO_ENCODED_RUSTFLAGS'])
        source = 'CARGO_ENCODED_RUSTFLAGS'
    elif 'RUSTFLAGS' in environment:
        flags, source = cargo_environment_flags('RUSTFLAGS', environment['RUSTFLAGS']), 'RUSTFLAGS'
    elif target_flags:
        flags, source = target_flags, 'target'
    else:
        flags = cargo_flag_words(config['build'].get('rustflags', []))
        flags.extend(cargo_flag_words(environment.get('CARGO_BUILD_RUSTFLAGS', '')))
        source = 'build'
    # A selector can straddle independently safe sources: exact ['-C'] plus
    # matching cfg ['linker=...']. Validate the final ordered argv as well.
    cargo_validate_flags(flags, bool(decisions))
    return linker, {'cfg_tables': decisions, 'matched_cfg': matches,
                    'linker': linker or None, 'linker_source': linker_source,
                    'rustflags': flags, 'rustflags_source': source}


def cargo_observe_target(config, triple, environment, compiler):
    cfg_scoped = any(selector.startswith('cfg(') for selector in config['target'])
    # Retain the pre-existing broad environment check, including unselected
    # target variables, and validate every potential cfg contribution. Nothing
    # can smuggle selectors through a currently false branch or a response file.
    for name, value in environment.items():
        if name.endswith('RUSTFLAGS'):
            words = cargo_environment_flags(name, value)
            cargo_validate_flags(words, cfg_scoped)
    cargo_validate_flags(cargo_flag_words(config['build'].get('rustflags', [])), cfg_scoped)
    for selector, values in config['target'].items():
        if selector == triple or selector.startswith('cfg('):
            cargo_validate_flags(cargo_flag_words(values.get('rustflags', [])), cfg_scoped)
    facts, cfg_output = set(), ''
    if cfg_scoped:
        if config.get('unsupported_cfg_context') or any(
                name.startswith('CARGO_UNSTABLE_') for name in environment):
            fail('unstable Cargo host/profile configuration is outside cfg attestation')
        wrappers = ('RUSTC_WRAPPER', 'RUSTC_WORKSPACE_WRAPPER',
                    'CARGO_BUILD_RUSTC_WRAPPER', 'CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER')
        if any(environment.get(name) for name in wrappers) or any(
                config['build'].get(key) for key in ('rustc-wrapper', 'rustc-workspace-wrapper')):
            fail('cfg-scoped Cargo selection through compiler wrappers is not statically attested')
        path = compiler.get('resolved_path', compiler['selected_path'])
        expected = compiler.get('resolved_sha256', compiler['selected_sha256'])
        if is_script(path) or digest(pathlib.Path(path)) != expected:
            fail('cfg probing requires the attested native rustc executable')
        try:
            outcome = subprocess.run([path, '--print=cfg', '--target', triple],
                                     capture_output=True, text=True, timeout=60, env=environment)
        except (OSError, UnicodeError, subprocess.TimeoutExpired) as error:
            fail('cannot observe rustc target cfg: ' + str(error))
        if outcome.returncode:
            fail('rustc target cfg probe failed: ' + outcome.stderr.strip())
        cfg_output = outcome.stdout
        facts = cargo_parse_target_cfg(cfg_output)
        if digest(pathlib.Path(path)) != expected:
            fail('rustc executable changed while probing target cfg')
    linker, receipt = cargo_target_settings(config, triple, environment, facts)
    if cfg_scoped:
        receipt['cfg_probe'] = {'compiler_path': path, 'compiler_sha256': expected,
                                'target_triple': triple,
                                'sha256': hashlib.sha256(cfg_output.encode()).hexdigest(),
                                'values': sorted(cfg_output.splitlines())}
    return linker, receipt


def cargo_configuration():
    # Cargo searches from cwd towards the filesystem root (and CARGO_HOME).
    # Keep its file precedence, array concatenation and config-relative paths.
    # Cfg predicates are parsed here, then evaluated with the selected native
    # compiler's target facts once the actual invocation has been resolved.
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
    config, receipts = {'build': {}, 'target': {}, 'alias': {}, 'env': {}}, []
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
        # These opt-in Cargo features can add flags or change host selection.
        # Do not silently treat them as the supported target configuration.
        if any(key in current for key in ('unstable', 'host', 'target-applies-to-host')):
            config['unsupported_cfg_context'] = True
        environment = current.get('env', {})
        if not isinstance(environment, dict):
            fail('invalid Cargo configuration section: env')
        exemptions = []
        for name, entry in sorted(environment.items()):
            row = cargo_env_exemption(name, entry)
            if row is None:
                if influences(name):
                    fail('Cargo configuration changes the compiler environment; use the configured build environment')
                continue
            exemptions.append(row)
            previous = config['env'].get(name)
            if previous is not None:
                if isinstance(previous, dict) and isinstance(entry, dict):
                    entry = dict(previous, **entry)
                elif not isinstance(previous, str) or not isinstance(entry, str):
                    fail('Cargo numeric environment changes type across configuration files: ' + name)
            config['env'][name] = entry
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
        if 'rustflags' in build:
            build['rustflags'] = cargo_merge_flags(config['build'].get('rustflags'), build['rustflags'])
        config['build'].update(build)
        for target, values in current.get('target', {}).items():
            if not isinstance(values, dict):
                fail('invalid Cargo target configuration')
            values = dict(values)
            if target.lstrip().startswith('cfg'):
                cargo_parse_cfg(target)
            if 'linker' in values:
                if not isinstance(values['linker'], str) or not values['linker'] or '\x00' in values['linker']:
                    fail('Cargo target linker must be a literal executable path')
                if '/' in values['linker'] and not pathlib.Path(values['linker']).is_absolute():
                    values['linker'] = str((path.parent.parent / values['linker']).resolve())
            previous = config['target'].setdefault(target, {})
            if 'rustflags' in values:
                values['rustflags'] = cargo_merge_flags(previous.get('rustflags'), values['rustflags'])
            previous.update(values)
        config['alias'].update(current.get('alias', {}))
        receipt = {'path': str(path), 'sha256': hashlib.sha256(raw).hexdigest()}
        if exemptions:
            receipt['env_exemptions'] = exemptions
        receipts.append(receipt)
    return config, receipts


cargo_config, cargo_config_receipts = (({'build': {}, 'target': {}, 'alias': {}}, [])
                                     if mode in ('target', 'selection') else cargo_configuration())


def cargo_shell_words(text):
    # Keep shell quoting until shell_word validates each literal argument.
    # shlex(posix=False) only recognizes quotes at the start of a word, so it
    # splits common forms such as RUSTFLAGS="-C opt-level=2" or
    # --features="one two". POSIX mode loses the quote/escape evidence needed
    # to distinguish literal dollars and globs from active shell expansion.
    tokens, word, quote, index = [], [], '', 0
    while index < len(text):
        char = text[index]
        if char == '\\' and quote != "'":
            if index + 1 == len(text):
                fail('unfinished escape in Cargo invocation')
            if text[index + 1] != '\n':
                word.extend(text[index:index + 2])
            index += 2
            continue
        if quote:
            word.append(char)
            if char == quote:
                quote = ''
        elif char in "\"'":
            word.append(char)
            quote = char
        elif char in ' \t\r\n;&|()<>':
            if word:
                tokens.append(''.join(word))
                word = []
            if char == '\n':
                tokens.append(char)
            elif char in ';&|()<>':
                end = index + 1
                while end < len(text) and text[end] in ';&|()<>':
                    end += 1
                tokens.append(text[index:end])
                index = end
                continue
        elif char == '#' and not word:
            # A comment starts at a word boundary, not within an argument or
            # quote. Do not join escaped newlines inside the discarded comment.
            end = text.find('\n', index)
            index = len(text) if end == -1 else end
            continue
        else:
            word.append(char)
        index += 1
    if quote:
        fail('unfinished quote in Cargo invocation')
    if word:
        tokens.append(''.join(word))
    return tokens


def invocation_selection():
    tokens = cargo_shell_words(command)
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
        # Cargo accepts -Z after the subcommand too. Host/profile switches
        # change which flags rustc sees, so the cfg guard must cover the whole
        # Cargo argument region, not only the global-options prefix. Stop at
        # --: those words belong to rustc or the executed test/application.
        cargo_arguments = argv[:argv.index('--')] if '--' in argv else argv
        if any(key.startswith('cfg(') for key in cargo_config['target']) and any(
                re.match(r'^-[vqkrw]*Z', arg) for arg in cargo_arguments):
            fail('unstable Cargo options are outside cfg target attestation')
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
        if subcommand == 'rustc' and '--' in argv:
            cargo_validate_flags(argv[argv.index('--') + 1:],
                                 any(key.startswith('cfg(') for key in cargo_config['target']))
        if re.search(r'(?:^|\s)-C\s*linker(?:[=\s]|$)', ' '.join(argv)) or \
                (subcommand == 'rustc' and '--' in argv and
                 any(arg == '--target' or arg.startswith('--target=') for arg in argv[argv.index('--') + 1:])):
            fail('cargo rustc compiler selectors require an explicit target/linker configuration')
        commands.append(subcommand)
        targets, manifests = [], []
        while cursor < len(argv):
            arg = argv[cursor]
            if arg == '--':
                break
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
        zigbuild = None
        if '.' in target:
            # cargo-zigbuild removes this GNU ABI suffix before invoking Cargo
            # and rustc. It is not part of the Rust target or output directory
            # (issue #37). Preserve its exact spelling as separate authority;
            # never normalize an arbitrary Cargo command or malformed suffix.
            matched = re.fullmatch(r'([A-Za-z0-9_]+(?:-[A-Za-z0-9_]+)*-linux-gnu)\.([0-9]+\.[0-9]+)', target)
            if subcommand != 'zigbuild' or not targets or not matched:
                fail('versioned targets require cargo zigbuild --target <GNU Rust triple>.<MAJOR.MINOR>')
            rust_target, floor = matched.groups()
            zigbuild = {'rust_target': rust_target, 'zig_target': target, 'glibc_floor': floor}
            target = rust_target
        elif subcommand == 'zigbuild':
            # Python-first Zig discovery is also used for ordinary GNU and
            # musl targets. Their linker must be the separately observed Zig,
            # without inventing a glibc floor or rewriting the caller's argv.
            if not target:
                fail('explicit cargo zigbuild requires a literal target or configured CARGO_BUILD_TARGET')
            zigbuild = {'rust_target': target, 'zig_target': target, 'glibc_floor': None}
        if zigbuild is not None:
            for name in ('CARGO_BUILD_TARGET', 'DSR_TARGET_TRIPLE'):
                if os.environ.get(name) and os.environ[name] != target:
                    fail('explicit Zig target contradicts the native task ' + name)
                if env.get(name) != os.environ.get(name):
                    fail('build_cmd cannot override the explicit Zig native task target environment')
        selection = {'toolchain': toolchain, 'target': target,
                     'cargo_zigbuild': zigbuild,
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

if mode == 'selection':
    # Coordinator-only intent, before staging or compiler lookup. The worker
    # repeats this parser and must attest the generated dispatcher itself.
    json.dump(selection['cargo_zigbuild'], sys.stdout, sort_keys=True)
    sys.stdout.write('\n')
    sys.exit(0)

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


cargo_effective_environment(cargo_config, cargo_config_receipts, probe_env)

# Metadata runs ordinary locked/offline Cargo without compiling through Zig.
# Every executable build/cache observation of an explicit Zig command instead
# requires the controller-generated, hash-verified dispatcher below.
if selection['cargo_zigbuild'] is not None and not zig_shim_dir and mode != 'metadata':
    fail('explicit cargo zigbuild requires the generated DSR Cargo shim')


# DSR's generated Zig launcher is an additional attested input, not
# Cargo or a Rustup reference. Check it before any compiler version execution,
# then perform normal executable identity checks under the PATH it delegates
# to. The actual build retains the original PATH and therefore still goes
# through cargo-zigbuild. An unknown script at this position never executes.
zig_shim_record = None
zig_shim_file = None
zig_shim_parent = None


def verify_zig_shim():
    if zig_shim_record is None:
        return
    try:
        zig_shim_file.seek(0)
        observed = hashlib.sha256(zig_shim_file.read(65537)).hexdigest()
        named = os.stat(zig_shim_path, follow_symlinks=False)
        parent = os.stat(zig_shim_dir, follow_symlinks=False)
        if (receipt_identity(zig_shim_before) != receipt_identity(os.fstat(zig_shim_file.fileno())) or
                receipt_identity(zig_shim_before) != receipt_identity(named) or
                (parent.st_dev, parent.st_ino) != (zig_shim_parent_before.st_dev, zig_shim_parent_before.st_ino) or
                observed != zig_shim_hash or set(os.listdir(zig_shim_parent)) != {'cargo'}):
            fail('generated DSR Cargo shim changed during toolchain observation')
    except OSError as error:
        fail('cannot verify generated DSR Cargo shim: ' + str(error))


if zig_shim_dir:
    try:
        shim_directory = pathlib.Path(zig_shim_dir)
        zig_shim_path = shim_directory / 'cargo'
        path_entries = probe_env.get('PATH', '').split(os.pathsep)
        if (path_entries[0] != zig_shim_dir or
                shutil.which('cargo', path=probe_env.get('PATH')) != str(zig_shim_path)):
            fail('generated DSR Cargo shim is not the selected first PATH entry')
        if any(any(char in entry for char in '*?[') for entry in path_entries):
            fail('globbed PATH entries are outside generated DSR Cargo shim attestation')
        # Match POSIX IFS splitting and the launcher's concatenation exactly:
        # one trailing empty field is dropped by shell field splitting;
        # initial empties collapse, but later empties retain current-directory
        # lookup. Dropping those would attest a different Cargo or plugin.
        split_entries = path_entries[:-1] if path_entries[-1] == '' else path_entries
        delegated_path = ''
        for entry in split_entries:
            if entry != zig_shim_dir:
                delegated_path += (os.pathsep if delegated_path else '') + entry
        if any(pathlib.Path(entry).resolve() == shim_directory.resolve()
               for entry in delegated_path.split(os.pathsep) if entry):
            fail('recursive alias of generated DSR Cargo shim directory on PATH')
        if any(probe_env.get(name) != os.environ.get(name) for name in (
                'DSR_RUST_TARGET', 'DSR_ZIG_TARGET', 'DSR_LINUX_GLIBC_FLOOR')):
            fail('build_cmd cannot override generated DSR Cargo shim target selection')
        zig_overrides = sorted(name for name in (
            'CARGO_ZIGBUILD_ZIG_COMMAND', 'CARGO_ZIGBUILD_ZIG_COMMAND_ARGS',
            'CARGO_ZIGBUILD_PYTHON_PATH', 'CARGO_ZIGBUILD_ZIG_PATH',
            'CARGO_ZIGBUILD_ZIG_VERSION') if name in probe_env)
        if zig_overrides:
            fail('generated DSR Cargo shim does not accept Zig dispatch overrides: ' +
                 ', '.join(zig_overrides))
        floor = probe_env.get('DSR_LINUX_GLIBC_FLOOR', '')
        explicit_zig = selection['cargo_zigbuild']
        unversioned_zig = explicit_zig is not None and explicit_zig['glibc_floor'] is None
        expected_zig_target = selection['target'] if unversioned_zig else selection['target'] + '.' + floor
        if (probe_env.get('DSR_RUST_TARGET') != selection['target'] or
                probe_env.get('DSR_ZIG_TARGET') != expected_zig_target or
                (unversioned_zig and floor) or
                (not unversioned_zig and (not re.fullmatch(r'[0-9]+\.[0-9]+', floor) or
                                         not selection['target'].endswith('-linux-gnu')))):
            fail('generated DSR Cargo shim target/floor does not match the admitted build')
        if 'zigbuild' in cargo_commands and explicit_zig != {
                'rust_target': selection['target'], 'zig_target': probe_env['DSR_ZIG_TARGET'],
                'glibc_floor': floor or None}:
            fail('explicit Zig target/floor does not match the generated DSR Cargo shim')
        zig_shim_parent = os.open(shim_directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        zig_shim_parent_before = os.fstat(zig_shim_parent)
        fd = os.open('cargo', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=zig_shim_parent)
        zig_shim_file = os.fdopen(fd, 'rb')
        zig_shim_before = os.fstat(zig_shim_file.fileno())
        if (not stat.S_ISREG(zig_shim_before.st_mode) or
                zig_shim_before.st_uid != os.geteuid() or
                zig_shim_before.st_mode & 0o022 or not os.access(zig_shim_path, os.X_OK) or
                zig_shim_before.st_size > 65536 or
                hashlib.sha256(zig_shim_file.read(65537)).hexdigest() != zig_shim_hash):
            fail('generated DSR Cargo shim does not match the trusted generator bytes or ownership')
        zig_shim_record = {'program': 'cargo', 'selected_path': str(zig_shim_path),
                           'selected_sha256': zig_shim_hash, 'selected_kind': 'script', 'version': ''}
        verify_zig_shim()
        probe_env['PATH'] = delegated_path
    except (OSError, RuntimeError) as error:
        fail('cannot admit generated DSR Cargo shim: ' + str(error))


def run(argv, required=True, timeout=60):
    try:
        result = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, env=probe_env)
    except (OSError, subprocess.TimeoutExpired) as error:
        fail('cannot run ' + argv[0] + ': ' + str(error))
    if result.returncode and required:
        fail('toolchain probe failed for ' + argv[0] + ': ' + result.stderr.strip())
    return (result.stdout or result.stderr).strip()

cargo_argv = ['cargo'] + (['+' + selection['toolchain']] if explicit_toolchain else [])

def is_script(path):
    with open(path, 'rb') as stream:
        return stream.read(2) == b'#!'

if 'RUSTUP_FORCE_ARG0' in probe_env:
    fail('configured Rustup dispatch overrides are outside executable attestation')

# These are the existing trusted host's manager locations, not arbitrary
# siblings of a selected executable. A mismatched PATH manager must not hide
# a byte-identical HOME manager. Version output never recognizes a proxy.
rustup_candidates = []
path_rustup = shutil.which('rustup', path=probe_env.get('PATH'))
if path_rustup:
    rustup_candidates.append(pathlib.Path(path_rustup).absolute())
home_rustup = pathlib.Path(probe_env.get('HOME', '') + '/.cargo/bin/rustup')
if home_rustup not in rustup_candidates:
    rustup_candidates.append(home_rustup)


def rustup_reference(expected_digest=None):
    # Reviewed launchers invoke the configured manager, so their unqualified
    # lookup must not fall through a broken PATH manager to another install.
    candidates = rustup_candidates if expected_digest is not None else rustup_candidates[:1]
    for candidate in candidates:
        try:
            physical = candidate.resolve(strict=True)
            if (physical.name != 'rustup' or not physical.is_file() or
                    not os.access(physical, os.X_OK) or is_script(physical)):
                continue
            observed = digest(physical)
            if expected_digest is None or observed == expected_digest:
                return candidate, physical, observed
        except (OSError, RuntimeError):
            continue
    return None


def rustup_resolve(reference, tool):
    candidate, physical, expected = reference
    parent = fd = None
    try:
        parent = os.open(physical.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        parent_before = os.fstat(parent)
        fd = os.open(physical.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode):
            fail('Rustup manager reference is not a regular executable')
        with os.fdopen(fd, 'rb') as stream:
            fd = None

            def unchanged():
                stream.seek(0)
                observed = hashlib.sha256()
                for block in iter(lambda: stream.read(1048576), b''):
                    observed.update(block)
                named = os.stat(physical, follow_symlinks=False)
                current_parent = os.stat(physical.parent, follow_symlinks=False)
                return (candidate.resolve(strict=True) == physical and
                        receipt_identity(before) == receipt_identity(os.fstat(stream.fileno())) and
                        receipt_identity(before) == receipt_identity(named) and
                        (parent_before.st_dev, parent_before.st_ino) ==
                        (current_parent.st_dev, current_parent.st_ino) and
                        observed.hexdigest() == expected)

            if not unchanged():
                fail('Rustup manager reference changed before dispatch resolution')
            which = run([str(physical), 'which', tool])
            if not unchanged():
                fail('Rustup manager reference changed during dispatch resolution')
        actual = pathlib.Path(which)
        if not actual.is_absolute() or not actual.is_file():
            fail('rustup did not resolve the selected ' + tool)
        return actual.resolve(strict=True), {'path': str(physical), 'sha256': expected}
    except (OSError, RuntimeError) as error:
        fail('cannot hold Rustup manager reference: ' + str(error))
    finally:
        if fd is not None:
            os.close(fd)
        if parent is not None:
            os.close(parent)


def refuse_unresolved_rustup(path):
    # Rustup documents FORCE_ARG0 as binary-name dispatch. Native forwarders
    # can relay it, so a response only refuses unresolved delegation; it never
    # grants authority or supplies a resolved executable path.
    environment = dict(probe_env, RUSTUP_FORCE_ARG0='rustup')
    try:
        result = subprocess.run([str(path), '--version'], capture_output=True,
                                text=True, timeout=60, env=environment)
    except (OSError, UnicodeError, subprocess.TimeoutExpired) as error:
        fail('cannot check unresolved Rustup dispatch: ' + str(error))
    if re.fullmatch(
            r'rustup [0-9]+\.[0-9]+\.[0-9]+(?:[-+ ][^\r\n]*)?', result.stdout.strip()):
        fail('unresolved Rustup dispatch or opaque native wrapper: no byte-identical manager reference')
    if result.returncode:
        fail('cannot rule out unresolved Rustup dispatch: version check failed for ' + str(path))

# Same exact reviewed v4 shim/v3 toolchain-wrapper bytes used by the strict
# cache resolver. v6 was additionally source-reviewed against RCH's shim.rs
# template: its unselected local path prefers rustc's sysroot/cargo-rch-real.
# A header/version response never admits a changed or unknown wrapper.
rch_shim_hash = '015f36047d1b732ada59b8644f7fde5e327803a11e56d571d2603af25c970ed7'
rch_toolchain_hash = 'd5966567e177ce968f272848ab8e249da3d9bfca40f90237480e1fbe6bd9d2d0'
rch_shim_v6_hash = '171e35f834fb8f900f85bd9ee22a659b3e710973dc3922d9579d055d560982e5'

def identity(name, program, version_args, rustup_tool=None, required=True):
    selected = shutil.which(program, path=probe_env.get('PATH'))
    if not selected:
        if required:
            fail('required executable not found on the build PATH: ' + program)
        return None
    selected = pathlib.Path(selected).absolute()
    resolved_selected = selected.resolve()
    selected_digest = digest(resolved_selected)
    version = run([str(selected), *version_args]) if version_args else ''
    if version_args and version_args[-1] != '-vV':
        version = version.splitlines()[0] if version else ''
    record = {'program': program, 'selected_path': str(selected),
              'selected_sha256': selected_digest,
              'selected_kind': 'script' if is_script(resolved_selected) else 'executable',
              'version': version}
    actual = None
    manager = rustup_reference(selected_digest) if rustup_tool else None
    proxy = manager is not None
    managed_cargo = rustup_tool == 'cargo' and record['selected_kind'] == 'script' and \
        record['selected_sha256'] in (rch_shim_hash, rch_toolchain_hash, rch_shim_v6_hash)
    if managed_cargo:
        if (probe_env.get('RCH_CARGO_WRAPPER_BYPASS') != '1' or
                probe_env.get('RCH_REAL_CARGO') or probe_env.get('RCH_SHIM_REAL_CARGO')):
            fail('managed RCH Cargo resolution requires explicit bypass without executable overrides')
        if record['selected_sha256'] == rch_toolchain_hash and not explicit_toolchain:
            actual = resolved_selected.parent / 'cargo-rch-real'
        elif record['selected_sha256'] == rch_shim_v6_hash and not explicit_toolchain:
            # Bind the actual dispatch dependency too. RUSTC may name a
            # different explicit compiler; this shim asks PATH's bare rustc.
            # Missing/failed bare rustc is a real HOME-Cargo fallback in v6;
            # an explicit RUSTC can still be the build's working compiler.
            bare_rustc = shutil.which('rustc', path=probe_env.get('PATH'))
            sysroot = ''
            record['sysroot_resolver'] = None
            if bare_rustc:
                resolver = pathlib.Path(bare_rustc).absolute()
                resolved_resolver = resolver.resolve()
                dependency = {'program': 'rustc', 'selected_path': str(resolver),
                              'selected_sha256': digest(resolved_resolver),
                              'selected_kind': 'script' if is_script(resolved_resolver) else 'executable'}
                try:
                    outcome = subprocess.run([str(resolver), '--print', 'sysroot'],
                                             capture_output=True, text=True, timeout=60, env=probe_env)
                except (OSError, subprocess.TimeoutExpired) as error:
                    fail('cannot observe managed Cargo sysroot dispatch: ' + str(error))
                # The reviewed shell shim uses stdout even on a nonzero exit;
                # it never treats stderr as a sysroot path.
                sysroot = outcome.stdout.rstrip('\n')
                dependency['sysroot_probe_exit_code'] = outcome.returncode
                dependency['sysroot'] = sysroot
                record['sysroot_resolver'] = dependency
            candidate = pathlib.Path(sysroot) / 'bin' / 'cargo-rch-real' if sysroot else None
            if candidate is not None and os.access(candidate, os.X_OK):
                # A successful dispatch through a rustup proxy must bind the
                # delegated rustc bytes too, even when RUSTC is different.
                dependency.update(identity('rustc', 'rustc', [], 'rustc'))
                actual = candidate
            else:
                actual = pathlib.Path(probe_env.get('HOME', '') + '/.cargo/bin/cargo')
    if rustup_tool and (proxy or managed_cargo and actual is None):
        reference = manager or rustup_reference()
        if reference is None:
            fail('selected compiler requires an executable rustup resolver')
        actual, record['rustup_resolver'] = rustup_resolve(reference, rustup_tool)
    elif rustup_tool and not managed_cargo:
        refuse_unresolved_rustup(resolved_selected)
        if rustup_tool == 'cargo' and explicit_toolchain:
            fail('an explicit +toolchain requires a recognized Rustup Cargo proxy or reviewed launcher')
    if actual is not None and rustup_tool:
        try:
            actual = actual.resolve(strict=True)
            # The v6 fallback can itself be the stock rustup Cargo proxy.
            if managed_cargo and not is_script(actual):
                fallback_manager = rustup_reference(digest(actual))
                if fallback_manager is not None:
                    actual, record['rustup_resolver'] = rustup_resolve(fallback_manager, rustup_tool)
            if is_script(actual):
                if (rustup_tool != 'cargo' or digest(actual) != rch_toolchain_hash or
                        probe_env.get('RCH_CARGO_WRAPPER_BYPASS') != '1' or
                        probe_env.get('RCH_REAL_CARGO') or probe_env.get('RCH_SHIM_REAL_CARGO')):
                    fail('unresolved compiler launcher: ' + str(actual))
                record['toolchain_launcher'] = {'path': str(actual), 'sha256': digest(actual)}
                actual = (actual.parent / 'cargo-rch-real').resolve(strict=True)
            if not actual.is_file() or not os.access(actual, os.X_OK) or is_script(actual):
                fail('compiler delegation did not resolve a real executable: ' + str(actual))
            refuse_unresolved_rustup(actual)
            actual_digest = digest(actual)
            native_args = version_args[1:] if version_args and version_args[0].startswith('+') else version_args
            native_version = run([str(actual), *native_args]) if native_args else ''
            if native_args and native_args[-1] != '-vV':
                native_version = native_version.splitlines()[0] if native_version else ''
            if native_version != version:
                fail('selected launcher and resolved executable version disagree: ' + program)
            if digest(actual) != actual_digest:
                fail('resolved compiler executable changed during its version probe: ' + program)
        except (OSError, RuntimeError) as error:
            fail('cannot resolve actual compiler executable: ' + str(error))
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
    if selected.resolve() != resolved_selected or digest(resolved_selected) != selected_digest:
        fail('selected executable changed during its identity probe: ' + program)
    return record

triple = selection['target']
cargo_version_args = (['+' + selection['toolchain']] if explicit_toolchain else []) + ['-vV']
compiler = probe_env.get('RUSTC') or probe_env.get('CARGO_BUILD_RUSTC') or cargo_config['build'].get('rustc') or 'rustc'
tools = {'cargo': identity('cargo', 'cargo', cargo_version_args, 'cargo'),
         'rustc': identity('rustc', compiler, ['-vV'], 'rustc')}
if zig_shim_record is not None:
    tools['dsr_cargo_shim'] = zig_shim_record
if not triple:
    triple = next((line.split(': ', 1)[1] for line in tools['rustc']['version'].splitlines()
                   if line.startswith('host: ')), '')
    if not triple:
        fail('rustc did not report its default host target')
linker_variable = 'CARGO_TARGET_' + re.sub(r'[^A-Za-z0-9]', '_', triple).upper() + '_LINKER'
linker, cargo_target_receipt = cargo_observe_target(cargo_config, triple, probe_env, tools['rustc'])
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
if zig_shim_record is not None:
    plugins.add('zigbuild')
for sub in sorted(plugins):
    program = 'cargo-' + sub
    if zig_shim_record is not None and sub == 'zigbuild' and not shutil.which(program, path=probe_env.get('PATH')):
        fail('generated DSR Cargo shim requires cargo-zigbuild on the delegated PATH')
    if shutil.which(program, path=probe_env.get('PATH')):
        tools[program] = identity(program, program, ['--version'], program, required=False)
for name in sorted(set(extra.split()) | ({'zig'} if zig_shim_record is not None else set())):
    if not name.startswith('cargo-') and name not in tools:
        record = identity(name, name, ['version' if name == 'zig' else '--version'],
                          required=zig_shim_record is not None and name == 'zig')
        if record:
            tools[name] = record
verify_zig_shim()
result = {'schema_version': 1, 'cwd': os.getcwd(), 'target_triple': triple,
          'linker_variable': linker_variable if probe_env.get(linker_variable) else None, 'tools': tools,
          'selection': {'rustup_toolchain': selection['toolchain'],
                        'cargo_commands': cargo_commands,
                        'cargo_config': cargo_config_receipts,
                        'cargo_target': cargo_target_receipt}}
if zig_shim_record is not None:
    result['selection']['dsr_cargo_shim'] = {
        'rust_target': probe_env['DSR_RUST_TARGET'], 'zig_target': probe_env['DSR_ZIG_TARGET'],
        'glibc_floor': probe_env.get('DSR_LINUX_GLIBC_FLOOR') or None}
if selection['cargo_zigbuild'] is not None:
    result['selection']['cargo_zigbuild'] = selection['cargo_zigbuild']

def cargo_metadata_index(rows, keys, label):
    if not isinstance(rows, list):
        fail('invalid Cargo metadata ' + label)
    indexed = {}
    for row in rows:
        if not isinstance(row, dict) or any(not isinstance(row.get(key), str) or not row[key] for key in keys):
            fail('invalid Cargo metadata ' + label)
        key = tuple(row[field] for field in keys)
        if key in indexed:
            fail('duplicate Cargo metadata ' + label)
        indexed[key] = row
    return indexed


def cargo_merge_metadata(target, host):
    # --filter-platform is a target projection, not Cargo's host/target unit
    # graph. Build scripts and proc macros can need dependencies selected by
    # the compiler host's cfg even when producing a different target's binary.
    graphs = []
    for document in (target, host):
        if not isinstance(document, dict) or document.get('version') != 1 or not isinstance(document.get('resolve'), dict):
            fail('complete Cargo metadata v1 required for target/host union')
        packages = cargo_metadata_index(document.get('packages'), ('id',), 'packages')
        nodes = cargo_metadata_index(document['resolve'].get('nodes'), ('id',), 'resolve nodes')
        for key, node in nodes.items():
            if key not in packages:
                fail('Cargo metadata resolve node has no package')
            for field in ('dependencies', 'features'):
                values = node.get(field)
                if (not isinstance(values, list) or any(not isinstance(value, str) for value in values) or
                        len(set(values)) != len(values)):
                    fail('invalid Cargo metadata node ' + field)
            dependencies = cargo_metadata_index(node.get('deps'), ('name', 'pkg'), 'dependency edges')
            if (any((dependency,) not in nodes for dependency in node['dependencies']) or
                    set(node['dependencies']) != {edge['pkg'] for edge in dependencies.values()}):
                fail('incomplete Cargo metadata dependency graph')
            for edge in dependencies.values():
                if not isinstance(edge.get('dep_kinds'), list) or any(not isinstance(kind, dict) for kind in edge['dep_kinds']):
                    fail('invalid Cargo metadata dependency kinds')
        graphs.append((packages, nodes))
    if ({key: value for key, value in target.items() if key not in ('packages', 'resolve')} !=
            {key: value for key, value in host.items() if key not in ('packages', 'resolve')} or
            {key: value for key, value in target['resolve'].items() if key != 'nodes'} !=
            {key: value for key, value in host['resolve'].items() if key != 'nodes'}):
        fail('Cargo target/host metadata workspace identity changed')
    packages, nodes = (dict(rows) for rows in graphs[0])
    for key, package in graphs[1][0].items():
        if key in packages and packages[key] != package:
            fail('Cargo target/host metadata package identity changed: ' + package['id'])
        packages[key] = package
    for key, node in graphs[1][1].items():
        if key not in nodes:
            nodes[key] = node
            continue
        previous = nodes[key]
        if ({field: value for field, value in previous.items() if field not in ('dependencies', 'features', 'deps')} !=
                {field: value for field, value in node.items() if field not in ('dependencies', 'features', 'deps')}):
            fail('Cargo target/host metadata resolve identity changed')
        merged = dict(previous)
        for field in ('dependencies', 'features'):
            merged[field] = sorted(set(previous[field]) | set(node[field]))
        edges = cargo_metadata_index(previous['deps'], ('name', 'pkg'), 'dependency edges')
        for edge_key, edge in cargo_metadata_index(node['deps'], ('name', 'pkg'), 'dependency edges').items():
            if edge_key in edges:
                old_edge = edges[edge_key]
                if ({field: value for field, value in old_edge.items() if field != 'dep_kinds'} !=
                        {field: value for field, value in edge.items() if field != 'dep_kinds'}):
                    fail('Cargo target/host metadata dependency edge changed')
                kinds = {json.dumps(kind, sort_keys=True) for kind in old_edge['dep_kinds'] + edge['dep_kinds']}
                edge = dict(edge, dep_kinds=[json.loads(kind) for kind in sorted(kinds)])
            edges[edge_key] = edge
        merged['deps'] = [edges[edge_key] for edge_key in sorted(edges)]
        nodes[key] = merged
    return dict(target, packages=[packages[key] for key in sorted(packages)],
                resolve=dict(target['resolve'], nodes=[nodes[key] for key in sorted(nodes)]))


def cargo_target_metadata(argv, target, compiler_version, source_root, configurations=(), complete_graph=False):
    host = next((line.split(': ', 1)[1] for line in compiler_version.splitlines() if line.startswith('host: ')), '')
    if not re.fullmatch(r'[A-Za-z0-9_]+(?:-[A-Za-z0-9_]+)+', host):
        fail('selected compiler did not report a valid host for Cargo metadata')

    def projection(platform):
        selected = ['--filter-platform', platform] if platform else []
        try:
            return json.loads(run(argv + ['metadata', '--locked', '--offline', '--all-features',
                                  *selected, '--format-version=1',
                                  '--manifest-path', str(source_root / 'Cargo.toml')], timeout=300))
        except ValueError as error:
            fail('invalid selected Cargo metadata: ' + str(error))

    if complete_graph:
        # With an explicit target (even the host triple), Cargo suppresses
        # target Rust flags for build scripts/proc macros. Metadata projections
        # do not model that split. Host-specific flags can distort the host
        # projection too. Wrappers/plugins can inject the same changes, so
        # preserve the original complete graph for these compilation contexts.
        return projection(None)

    # The source-root gate covers every pinned local checkout, including ones
    # used only by another platform. Keep its original complete observation
    # when a projection would hide one; never invent local package authority.
    try:
        import tomllib
    except ImportError:
        return projection(None)
    try:
        for configuration in configurations:
            raw = pathlib.Path(configuration['path']).read_bytes()
            if hashlib.sha256(raw).hexdigest() != configuration['sha256']:
                fail('Cargo configuration changed during metadata admission')
            if tomllib.loads(raw.decode('utf-8')).get('paths'):
                # Legacy path overrides retain registry identities in the
                # lockfile, so local lock entries cannot inventory them.
                return projection(None)
        lock = tomllib.loads((source_root / 'Cargo.lock').read_text(encoding='utf-8'))
        if not isinstance(lock.get('package'), list) or any(not isinstance(row, dict) for row in lock['package']):
            fail('invalid Cargo lockfile package inventory')
        local = cargo_metadata_index([row for row in lock['package'] if 'source' not in row],
                                     ('name', 'version'), 'local lockfile packages')
    except (OSError, ValueError, UnicodeError) as error:
        fail('cannot inventory local Cargo sources: ' + str(error))

    metadata = projection(target)
    # The host projection is deliberately conservative: it can include normal
    # host dependencies as well as build/proc-macro dependencies. Never omit an
    # actual host input merely to minimize a cross-build's authenticated set.
    if host != target:
        metadata = cargo_merge_metadata(metadata, projection(host))
    observed = cargo_metadata_index([package for package in metadata['packages'] if package.get('source') is None],
                                    ('name', 'version'), 'local metadata packages')
    if not local.keys() <= observed.keys():
        # These builds deliberately retain the old all-platform download
        # requirements so exact local-root admission remains unchanged.
        metadata = cargo_merge_metadata(metadata, projection(None))
    return metadata


# Metadata admission uses the same compiler and Rust target as the build,
# including its host dependencies without fetching every unrelated platform.
if mode == 'metadata':
    metadata_flags = (any(value for name, value in probe_env.items() if name.endswith('RUSTFLAGS')) or
                      cargo_config['build'].get('rustflags') or
                      any(values.get('rustflags') for values in cargo_config['target'].values()))
    metadata_complete = (metadata_flags or
                         any(probe_env.get(name) for name in ('RUSTC_WRAPPER', 'RUSTC_WORKSPACE_WRAPPER',
                             'CARGO_BUILD_RUSTC_WRAPPER', 'CARGO_BUILD_RUSTC_WORKSPACE_WRAPPER')) or
                         any(cargo_config['build'].get(name) for name in ('rustc-wrapper', 'rustc-workspace-wrapper')) or
                         any(tools[name].get('resolved_kind', tools[name]['selected_kind']) == 'script'
                             for name in ('cargo', 'rustc')) or
                         any(subcommand != 'build' for subcommand in cargo_commands) or
                         cargo_config.get('unsupported_cfg_context') or
                         any(value for name, value in probe_env.items() if name.startswith('CARGO_UNSTABLE_')) or
                         probe_env.get('DSR_ZIG_TARGET') or zig_shim_record is not None)
    metadata = cargo_target_metadata(cargo_argv, triple, tools['rustc']['version'],
                                     pathlib.Path.cwd(), cargo_config_receipts, bool(metadata_complete))
    verify_zig_shim()
    json.dump(metadata, sys.stdout, sort_keys=True)
    sys.stdout.write('\n')
    sys.exit(0)

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
    data = (json.dumps(result, sort_keys=True) + '\n').encode()
    if len(data) > 1048576:
        fail('identity observation exceeds the receipt size bound')
    try:
        fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(data)
            stream.flush()
            # Do not authorize the compiler with an observation that exists
            # only in userspace/kernel writeback. Keep the receipt fd held
            # through file and directory sync, then recheck its named inode.
            os.fsync(stream.fileno())
            parent_fd = os.open(str(pathlib.Path(output).parent), os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(parent_fd)
            finally:
                os.close(parent_fd)
            held = os.fstat(stream.fileno())
            receipt_info(held)
            if receipt_identity(held) != receipt_identity(os.stat(output, follow_symlinks=False)):
                fail('identity receipt replaced while recording')
    except OSError as error:
        fail('cannot create identity receipt ' + output + ': ' + str(error))
    # This value is returned to the coordinator before compilation. Never
    # recompute the pin from the writable receipt after the build.
    json.dump({'identity': result, 'pin': {
        'sha256': hashlib.sha256(data).hexdigest(), 'identity': receipt_identity(held)}},
        sys.stdout, sort_keys=True)
    sys.stdout.write('\n')
else:
    if recorded != result:
        changed = sorted(name for name in set(recorded.get('tools', {})) | set(tools)
                         if recorded.get('tools', {}).get(name) != tools.get(name))
        fail('build toolchain changed during the build (' + (', '.join(changed) or 'context') +
             '); refusing to collect its artifacts')
    read_receipt()  # Retain the same bytes/inode throughout executable probing.
PY
    printf 'DSR_TOOLCHAIN_IDENTITY_PY\n'
}

# Keep accepted 1 MiB observations off exec argv. Bash's builtin printf feeds
# the original and returned documents directly to one fixed jq program.
_act_bind_toolchain_identity() {
    printf '%s\n' "$1" "$2" "$3" | jq -sce '
        select(length == 3 and (.[0] | type == "object") and
            (.[1] | type == "object") and .[1] == .[2]) |
        .[0].toolchain = .[2] | .[0]'
}

# The summary is small; its targets can carry complete compiler receipts.
# Keep both documents on stdin rather than forwarding a target as exec argv.
_act_bind_orchestration_targets() {
    printf '%s\n' "$1" "$2" | jq -sce '
        select(length == 2 and (.[0] | type == "object") and
          (.[1] | type == "array")) | .[0] + {targets: .[1]}'
}

# Insert one already observed field. This transports bytes and does not
# perform the separate original-pin/pre-/post-build identity verification.
_act_bind_cargo_isolation_field() {
    local field="$1"
    case "$field" in cargo_context|toolchain|dependency_sources) ;; *) return 4 ;; esac
    printf '%s\n' "$2" "$3" | jq -sce --arg field "$field" '
        select(length == 2 and (.[0] | type == "object")) |
        .[0][$field] = .[1] | .[0]'
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
    # The configured environment belongs to the worker. In particular its
    # BASH_ENV must remain data, never a coordinator startup program.
    actual=$(env -i "${pairs[@]}" "$BASH" -p -c "$script") || return 4
    [[ "$actual" == "$selected_triple" ]] || return 4
}

# Read only the explicit Zig invocation on the coordinator; an unversioned
# target retains a null glibc floor. No
# local Cargo configuration or executable is consulted; worker observation
# repeats the selection and authenticates the staged shim before dispatch.
_act_explicit_zigbuild_selection() {
    local build_cmd="$1" build_env="$2" script pair
    local -a pairs=()
    while IFS= read -r pair; do
        [[ -z "$pair" ]] && continue
        [[ "$pair" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || return 4
        pairs+=("$pair")
    done <<< "$build_env"
    script=$(_act_toolchain_identity_script selection /dev/null "$build_cmd") || return 4
    env -i "${pairs[@]}" "$BASH" -p -c "$script"
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

# Retain native execution boundaries in the attempt's private log. These are
# coordinator observations: dispatching the final program does not prove that
# Cargo or a compiler started, and a command returning 124 does not by itself
# establish that a watchdog expired. Callers keep these diagnostic writes best
# effort so a log write failure cannot bypass the ordinary stage cleanup.
_act_log_native_execution() {
    local log_file="$1" event="$2" phase="$3" timeout_seconds="$4"
    local transport_timeout_seconds="$5" command_exit_code="$6" dispatched="$7"
    printf '[dsr] native_execution phase=%s event=%s timeout_seconds=%s transport_timeout_seconds=%s command_exit_code=%s build_program_dispatched=%s\n' \
        "$phase" "$event" "$timeout_seconds" "$transport_timeout_seconds" \
        "$command_exit_code" "$dispatched" | tee -a "$log_file" >&2
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
    # Nested archive/receipt validators must resolve the same exact primary.
    # Bash local scope keeps this selected variant private to this invocation.
    local _ACT_STRICT_TARGET_TRIPLE="$selected_triple"

    # This backend compiles directly on a native host. Until an RCH-backed
    # route exists, an explicit remote-only policy must stop before host
    # selection, source preparation or the later Cargo bypass exports (#17).
    dsr_native_rch_policy "$platform" "${RCH_REQUIRE_REMOTE:-}" || return 4

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
    local host
    host="$bound_host"
    [[ -n "$host" ]] || host=$(act_get_native_host "$platform" "$tool_name")
    if [[ -z "$host" ]]; then
        _log_error "No native host configured for platform: $platform"
        jq -nc --arg platform "$platform" \
            '{status: "error", exit_code: 4, error: ("No native host for " + $platform)}'
        return 4
    fi
    # Native callers may supply a host directly, use a repo pin, or fall back
    # after selector failure. All routes consume the same readiness decision.
    local capability readiness_args=("$host")
    capability=$(_act_native_host_capability "$tool_name" "$platform") || return 4
    [[ -z "$capability" ]] || readiness_args+=(--require "$capability")
    if ! declare -F host_health_is_ready &>/dev/null || ! host_health_is_ready "${readiness_args[@]}"; then
        _log_error "Native build host is not ready: $host${capability:+ (requires $capability)}"
        jq -nc --arg platform "$platform" --arg host "$host" --arg triple "$selected_triple" \
            '{platform:$platform,method:"native",status:"error",exit_code:4,host:$host,
              stage:"host_readiness",error:"Native build host is not ready"} +
             (if $triple == "" then {} else {target_triple:$triple} end)'
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

    # Validate every configured additional-artifact declaration before source
    # staging or compiler invocation, even when only one platform was selected.
    local additional_json
    if ! additional_json=$(_act_workspace_additional_artifacts_json "$config_file" "$platform"); then
        jq -nc --arg platform "$platform" \
            '{platform:$platform, status:"error", exit_code:4,
              error:"Invalid workspace_additional_artifacts configuration; see the rejected declaration above"}'
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
    # Recipe policy cannot be defeated by the unconditional bypass exports
    # later in this backend. This remains a refusal, not RCH execution proof.
    dsr_native_rch_environment_policy "$platform" "$build_env" || return 4
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
    local strict_toolchain_record_cmd="" strict_toolchain_run_prefix="" strict_toolchain_effective_build=""
    local strict_toolchain_extra="" strict_toolchain_pin_json="" strict_toolchain_identity_json=""
    local strict_toolchain_shim_dir=""
    local strict_cargo_context_json='null' strict_dependency_sources_json='null' strict_windows_toolchain_json='null'
    local strict_sources_verification=""
    local build_influence_env_json='{}'
    local cargo_isolation_json='null'
    local native_writable_paths='[]' native_storage_error=""
    local nonstrict_stage_root="" nonstrict_source_root="" nonstrict_cargo_home=""
    local nonstrict_sibling_roots_json='[]'
    local nonstrict_sibling_relatives=()
    if [[ "$language" == "rust" && -n "$remote_path_override" ]]; then
        strict_rust_build=true
        if ! _act_is_windows_host "$host"; then
            local explicit_zig_selection
            explicit_zig_selection=$(_act_explicit_zigbuild_selection "$build_cmd" "$build_env") || return 4
            if [[ "$explicit_zig_selection" != null ]]; then
                rust_floor_triple=$(jq -er '.rust_target' <<< "$explicit_zig_selection") || return 4
                rust_zig_target=$(jq -er '.zig_target' <<< "$explicit_zig_selection") || return 4
                rust_glibc_floor=$(jq -er '.glibc_floor // ""' <<< "$explicit_zig_selection") || return 4
                build_env+=$'\n'"DSR_RUST_TARGET=$rust_floor_triple"
                build_env+=$'\n'"DSR_ZIG_TARGET=$rust_zig_target"
                build_env+=$'\n'"DSR_LINUX_GLIBC_FLOOR=$rust_glibc_floor"
                _log_info "Attesting explicit cargo zigbuild target $rust_zig_target with the generated Zig dispatcher"
            fi
        fi
        if [[ -n "$release_git_sha" || -n "$release_git_ref" ]]; then
            if [[ ! "$release_git_sha" =~ ^[0-9a-f]{40}$ || \
                  "$release_git_sha" =~ ^0{40}$ || \
                  "$release_git_ref" != "v${version#v}" ]]; then
                _log_error "Invalid strict release identity for native Rust build"
                jq -nc '{status: "error", exit_code: 4, error: "Invalid strict Rust release identity"}'
                return 4
            fi
        fi
        local strict_cargo_target_dir="${remote_path%/*}/.cargo-target-${native_target_slug}"
        if [[ -n "$strict_cache_root" || -n "$selected_triple" ]]; then
            # A retry also gets a fresh final-output destination. The host
            # cache wrapper refuses collisions; matrix variants and their
            # retries never share Cargo's host build-script/output directory.
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
        local cargo_attempt cargo_prepare=_act_prepare_unix_private_cargo_home
        cargo_attempt=$(_act_generate_uuid) || return 3
        _act_is_windows_host "$host" && cargo_prepare=_act_prepare_windows_private_cargo_home
        if ! _act_is_windows_host "$host"; then
            local prepared_cargo_home="${remote_path%/*}/.cargo-home-${platform//\//-}-${cargo_attempt//-/}"
            native_writable_paths=$(_act_native_writable_paths_json "$remote_path" "$remote_path" \
                "$strict_build_env"$'\n'"CARGO_HOME=$prepared_cargo_home" "$language" \
                "$strict_cache_root") || return 4
            if ! _act_native_writable_paths_ready "$host" "$capability" "$native_writable_paths"; then
                jq -nc --arg platform "$platform" --arg host "$host" --arg triple "$selected_triple" \
                    '{platform:$platform,method:"native",status:"error",exit_code:4,host:$host,
                      stage:"host_readiness",error:"Native Cargo writable paths are not ready"} +
                     (if $triple == "" then {} else {target_triple:$triple} end)'
                return 4
            fi
        fi
        if ! strict_cargo_seed_json=$("$cargo_prepare" \
                "$host" "$remote_path" "${platform//\//-}-${cargo_attempt//-/}" \
                "$build_cmd" "$strict_build_env") || \
           ! strict_cargo_home=$(jq -er '.cargo_home' <<< "$strict_cargo_seed_json"); then
            _log_error "Unable to prepare a private strict Cargo cache on $host"
            jq -nc '{status: "error", exit_code: 4, error: "Strict Cargo cache preparation failed"}'
            return 4
        fi
        strict_private_cargo_cache=true
        if ! strict_dependency_sources_json=$(jq -ce '.dependency_sources' <<< "$strict_cargo_seed_json") || \
           ! strict_dependency_sources_json=$(_act_validate_cargo_sources_summary "$strict_dependency_sources_json"); then
            _log_error "Strict Cargo dependency sources lack lockfile-authenticated authority"
            jq -nc '{status: "error", exit_code: 4, error: "Strict Cargo dependency authentication failed"}'
            return 4
        fi
        strict_cargo_seed_json=$(jq -c 'del(.dependency_sources)' <<< "$strict_cargo_seed_json") || return 4
        if _act_is_windows_host "$host"; then
            if ! _act_validate_cargo_cache_selection "$strict_cargo_seed_json" "$strict_dependency_sources_json" >/dev/null; then
                _log_error "Strict Windows Cargo cache lacks matching lockfile download selection"
                jq -nc '{status: "error", exit_code: 4, error: "Strict Cargo cache selection admission failed"}'
                return 4
            fi
            strict_cargo_context_json=$(jq -ce '.cargo_context | select(
                type == "object" and .schema_version == 1 and
                (keys | sort) == ["fingerprint", "receipt_sha256", "schema_version"] and
                (.fingerprint | test("^[0-9a-f]{64}$")) and
                (.receipt_sha256 | test("^[0-9a-f]{64}$")))' <<< "$strict_cargo_seed_json") || return 4
            if ! strict_windows_toolchain_json=$(jq -ce '.toolchain' <<< "$strict_cargo_seed_json") || \
               ! strict_windows_toolchain_json=$(_act_validate_windows_toolchain_summary "$strict_windows_toolchain_json" "$remote_path"); then
                _log_error "Strict Windows Cargo toolchain lacks executable identity evidence"
                jq -nc '{status: "error", exit_code: 4, error: "Strict Windows toolchain attestation failed"}'
                return 4
            fi
            strict_cargo_seed_json=$(jq -c 'del(.cargo_context, .toolchain)' <<< "$strict_cargo_seed_json") || return 4
        else
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
            cargo_isolation_json=$(printf '%s\n' "$cargo_isolation_json" "$strict_cargo_seed_json" | \
                jq -sce 'select(length == 2 and (.[0] | type == "object")) |
                .[0].cache_reuse = [] | .[0].dependency_cache = {mode: "private-copy", seed: .[1]} | .[0]') || return 4
        fi
        if [[ "$strict_cargo_context_json" != null ]]; then
            cargo_isolation_json=$(_act_bind_cargo_isolation_field cargo_context \
                "$cargo_isolation_json" "$strict_cargo_context_json") || return 4
        fi
        if [[ "$strict_windows_toolchain_json" != null ]]; then
            cargo_isolation_json=$(_act_bind_cargo_isolation_field toolchain \
                "$cargo_isolation_json" "$strict_windows_toolchain_json") || return 4
        fi
        if [[ "$strict_dependency_sources_json" != null ]]; then
            cargo_isolation_json=$(_act_bind_cargo_isolation_field dependency_sources \
                "$cargo_isolation_json" "$strict_dependency_sources_json") || return 4
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
        # working directory moves to the isolated source copy. The fresh
        # CARGO_HOME holds private dependency-cache copies prepared just before
        # the build runs on either host platform.
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
        # Every ordinary Rust attempt owns its final outputs, including a
        # singleton build with a configured absolute CARGO_TARGET_DIR. Treat
        # that setting as a base: a successful no-op command must not collect
        # a previous attempt's binary. Keep the existing matrix target names.
        nonstrict_target_dir="${nonstrict_target_dir%/}/dsr-${selected_triple:-${platform//\//-}}-${isolation_suffix}"
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
                cache_reuse: []
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

    if ! _act_is_windows_host "$host"; then
        local native_working_root="${nonstrict_source_root:-${output_stage_source:-$remote_path}}"
        native_writable_paths=$(_act_native_writable_paths_json "$remote_path" "$native_working_root" \
            "$build_env" "$language" "$strict_cache_root") || return 4
        if ! _act_native_writable_paths_ready "$host" "$capability" "$native_writable_paths"; then
            jq -nc --arg platform "$platform" --arg host "$host" --arg triple "$selected_triple" \
                '{platform:$platform,method:"native",status:"error",exit_code:4,host:$host,
                  stage:"host_readiness",error:"Native build writable paths are not ready"} +
                 (if $triple == "" then {} else {target_triple:$triple} end)'
            return 4
        fi
    fi

    # Every invocation owns its log, including retries of one target and
    # concurrent standalone callers that share a release run. Allocate before
    # preparation or compilation so unavailable evidence storage fails closed.
    local log_dir log_file native_log_dir native_log_label
    log_dir="$ACT_LOGS_DIR"
    native_log_label="${tool_name}-${native_target_slug}-${run_id:-$$}"
    native_log_label="${native_log_label//[^A-Za-z0-9._+-]/_}"
    if ! mkdir -p "$log_dir" || [[ ! -d "$log_dir" || -L "$log_dir" ]] ||
       ! native_log_dir=$(umask 077; mktemp -d "$log_dir/${native_log_label}.XXXXXXXX") ||
       [[ ! -d "$native_log_dir" || -L "$native_log_dir" ]] ||
       ! (umask 077; set -C; : > "$native_log_dir/build.log"); then
        _log_error "Unable to allocate a private native build log for $platform on $host"
        jq -nc --arg platform "$platform" --arg host "$host" \
            '{platform:$platform,method:"native",host:$host,status:"error",exit_code:4,
              error:"Private native build log could not be allocated; compiler was not started"}'
        return 4
    fi
    log_file="$native_log_dir/build.log"

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
            CARGO_HOME CARGO_TARGET_DIR CARGO_BUILD_BUILD_DIR CARGO_BUILD_TARGET CARGO_BUILD_JOBS
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
    elif [[ "$language" == go ]]; then
        # act_get_build_env binds these to the requested platform. Clear the
        # host's inherited selectors before exporting that effective pair on
        # both Unix and Windows; persistent `go env -w` values lose to it too.
        cargo_env_to_unset=(GOOS GOARCH)
        if [[ "${platform##*/}" == armv7 ]]; then
            cargo_env_to_unset+=(GOARM)
        fi
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
    local remote_cmd windows_build_body=""
    if _act_is_windows_host "$host"; then
        # Windows: use cmd.exe compatible syntax
        # - Use double quotes for paths
        # - Use 'set' instead of 'export' for env vars
        # - Use '&&' which works in cmd.exe
        # Note: In cmd.exe, 'set VAR=value && ...' includes trailing space in value.
        # Using 'set "VAR=value"' protects the value from the space before &&.
        local win_path="${remote_path//\//\\}"
        if ! $strict_rust_build && ! $nonstrict_rust_isolate; then
            local env_exports="" env_name
            for env_name in "${cargo_env_to_unset[@]}"; do
                env_exports+="set \"$env_name=\" && "
            done
            # build_env is newline-delimited to preserve values with spaces.
            while IFS= read -r env_pair; do
                [[ -z "$env_pair" ]] && continue
                env_exports+="set \"$env_pair\" && "
            done <<< "$build_env"
            remote_cmd=$(_act_windows_cmd_via_powershell "cd /d \"${win_path}\" && ${env_exports}${build_cmd}") || return 4
        fi
        if $strict_rust_build; then
            local context_fingerprint context_receipt_digest context_seed_digest
            context_fingerprint=$(jq -er '.fingerprint' <<< "$strict_cargo_context_json") || return 4
            context_receipt_digest=$(jq -er '.receipt_sha256' <<< "$strict_cargo_context_json") || return 4
            context_seed_digest=$(jq -er '.receipt_sha256' <<< "$strict_cargo_seed_json") || return 4
            windows_build_body=$(_act_windows_strict_cargo_build_script \
                "$remote_path" "$strict_cargo_home" "$build_cmd" "$build_env" \
                "$context_fingerprint" "$context_receipt_digest" "$context_seed_digest" \
                "$strict_dependency_sources_json") || return 4
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
            # A native host must not re-offload its private source/cache paths.
            ps_env_assignments+='$psi.EnvironmentVariables["RCH_DISABLED"]="1"; $psi.EnvironmentVariables["RCH_CARGO_WRAPPER_BYPASS"]="1"; '
            for sibling_relative in "${nonstrict_sibling_relatives[@]}"; do
                sibling_win_remote=$(_act_windows_cmd_path \
                    "${remote_path%/*}/$sibling_relative") || return 4
                sibling_win_staged=$(_act_windows_cmd_path \
                    "$nonstrict_stage_root/$sibling_relative") || return 4
                ps_sibling_copies+="\$sibling=Get-Item -LiteralPath '${sibling_win_remote}' -Force; if (-not \$sibling.PSIsContainer -or ((\$sibling.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)) { throw 'Rust sibling source root must be a plain directory' }; New-Item -ItemType Directory -Path '${sibling_win_staged}' | Out-Null; Copy-DsrSourceTree -SourcePath \$sibling.FullName -DestinationPath '${sibling_win_staged}'; "
            done
            local ps_nonstrict_build
            ps_nonstrict_build=$(cat <<EOF
\$ErrorActionPreference='Stop'
$ps_copy_function
$(_act_windows_reparse_guard_script)
Assert-PlainDirectory '${win_path}'
Assert-PlainDirectory '${win_stage_root}'
Assert-PlainDirectory '${win_cargo_home}'
Assert-PlainFile '${win_cargo_home}\\.dsr-cache-seed.json'
\$source=Get-Item -LiteralPath '${win_path}' -Force
\$ancestor=\$source.Parent
while (\$null -ne \$ancestor) {
    foreach (\$name in @('config','config.toml')) {
        \$candidate=Join-Path \$ancestor.FullName ".cargo/\$name"
        if (Test-Path -LiteralPath \$candidate) { [Console]::Error.WriteLine('[dsr] excluding inherited Cargo config: ' + \$candidate) }
    }
    \$ancestor=\$ancestor.Parent
}
New-Item -ItemType Directory -Path '${win_source_root}' | Out-Null
Copy-DsrSourceTree -SourcePath \$source.FullName -DestinationPath '${win_source_root}'
$ps_sibling_copies
if (Test-Path -LiteralPath (Join-Path '${win_source_root}' '.git')) {
    & git -C '${win_source_root}' status --porcelain --untracked-files=no | Out-Null
    if (\$LASTEXITCODE -ne 0) { throw 'Unable to refresh staged Git index metadata' }
}
foreach (\$name in @('registry','git')) {
    \$cache=Join-Path '${win_cargo_home}' \$name
    if (Get-Item -LiteralPath \$cache -Force -ErrorAction SilentlyContinue) { Assert-PlainDirectory \$cache }
}
foreach (\$name in @('config','config.toml','credentials','credentials.toml')) {
    if (Get-Item -LiteralPath (Join-Path '${win_cargo_home}' \$name) -Force -ErrorAction SilentlyContinue) { throw 'Ephemeral CARGO_HOME contains configuration' }
}
\$ancestor=(Get-Item -LiteralPath '${win_source_root}' -Force).Parent
while (\$null -ne \$ancestor) {
    foreach (\$name in @('config','config.toml')) {
        if (Get-Item -LiteralPath (Join-Path \$ancestor.FullName ".cargo/\$name") -Force -ErrorAction SilentlyContinue) { throw 'Staging root inherits Cargo configuration' }
    }
    \$ancestor=\$ancestor.Parent
}
\$psi=New-Object System.Diagnostics.ProcessStartInfo
\$psi.UseShellExecute=\$false
\$keys=@(\$psi.EnvironmentVariables.Keys)
foreach (\$key in \$keys) {
    if ((\$key -match '^(CARGO_|RUST|XWIN_)') -or (\$key -match '^(CC|CXX|CPP|AR|RANLIB|LD|NM|OBJCOPY|STRIP|CFLAGS|CXXFLAGS|CPPFLAGS|LDFLAGS|BINDGEN_EXTRA_CLANG_ARGS|SDKROOT|MACOSX_DEPLOYMENT_TARGET|IPHONEOS_DEPLOYMENT_TARGET|INCLUDE|LIB|LIBPATH)(_|$)') -or (\$key -match '_(CC|CXX|AR|RANLIB|CFLAGS|CXXFLAGS|LDFLAGS)$')) { \$psi.EnvironmentVariables.Remove(\$key) }
}
$ps_env_assignments
\$psi.EnvironmentVariables['CARGO_HOME']='${win_cargo_home}'
\$psi.FileName=\$env:ComSpec
\$psi.WorkingDirectory='${win_source_root}'
\$command=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('${ps_build_b64}'))
\$psi.Arguments='/d /s /c ' + \$command
\$process=[Diagnostics.Process]::Start(\$psi)
\$process.WaitForExit()
exit \$process.ExitCode
EOF
            ) || return 4
            windows_build_body="$ps_nonstrict_build"
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
        # per-target directories. Include the selected variant so GNU and
        # musl tasks of one platform never share (or race on) a shim.
        if [[ -n "$rust_zig_target" ]]; then
            local zig_shim_dir=""
            if $nonstrict_rust_isolate; then
                zig_shim_dir="${nonstrict_stage_root}/.dsr-bin"
            elif $strict_rust_build; then
                zig_shim_dir="${remote_path%/*}/.dsr-bin-${native_target_slug}"
            fi
            if [[ -n "$zig_shim_dir" ]]; then
                cargo_home_prefix+=$(_act_zig_shim_prefix_sh "$zig_shim_dir")
                env_exports+="export PATH='${zig_shim_dir}':\"\$PATH\"; "
                if $strict_rust_build; then
                    strict_toolchain_shim_dir="$zig_shim_dir"
                fi
            fi
        fi
        local effective_build="$build_cmd"
        if [[ -n "$strict_cache_root" ]]; then
            effective_build=$(_act_strict_cargo_cache_script "$strict_cache_root" "$strict_cache_contract" "$build_cmd" \
                "$strict_toolchain_shim_dir") || return 4
        fi
        if [[ -n "$strict_toolchain_receipt" ]]; then
            # Keep the original observation at the coordinator, outside the
            # compiler's writable filesystem. Preparation runs exactly once;
            # replaying it could replace the Cargo shim or a fresh source stage.
            local toolchain_record
            [[ -n "$rust_zig_target" ]] && strict_toolchain_extra="cargo-zigbuild zig"
            toolchain_record=$(_act_toolchain_identity_script record \
                "$strict_toolchain_receipt" "$build_cmd" "$strict_toolchain_extra" "" "$remote_path" \
                "$strict_toolchain_shim_dir") || return 4
            strict_toolchain_record_cmd="set -e; $cargo_home_prefix$cd_cmd; $env_exports$toolchain_record"$'\n'
            strict_toolchain_run_prefix="set -e; $cd_cmd; $env_exports"
            strict_toolchain_effective_build="$effective_build"
        fi
        if [[ "$strict_dependency_sources_json" != null ]]; then
            # Keep the authentication runtime out of the compiler command's
            # argv: combined with toolchain and intermediate-cache scripts it
            # can exceed the host's single-argument limit. Explicit paths and
            # held hashes make the separate pre-build invocation authoritative.
            strict_sources_verification=$(_act_unix_cargo_sources_verify_script \
                "$remote_path" "$strict_cargo_home" "$strict_dependency_sources_json") || return 4
        fi
        remote_cmd="set -e; $cargo_home_prefix$cd_cmd; $env_exports$effective_build"
    fi

    local build_transport_timeout="$_ACT_BUILD_TIMEOUT"
    if _act_is_windows_host "$host"; then
        local windows_build_script windows_build_guard
        if [[ -n "$windows_build_body" ]]; then
            windows_build_script="$windows_build_body"
        else
            windows_build_script=$(_act_windows_command_script "$remote_cmd") || return 4
        fi
        local windows_storage_status=0 windows_lock_script
        _act_windows_storage_config "$host" >/dev/null || windows_storage_status=$?
        [[ $windows_storage_status -eq 0 || $windows_storage_status -eq 1 ]] || return 4
        if [[ $windows_storage_status -eq 0 ]]; then
            if ! declare -F config_windows_storage_lock_script >/dev/null; then
                # shellcheck source=SCRIPTDIR/config.sh
                source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"
            fi
            windows_lock_script=$(config_windows_storage_lock_script "$host") || return 4
            windows_build_script="$windows_lock_script"$'\n'"$windows_build_script"
        fi
        windows_build_guard=$(_act_windows_build_guard_script "$_ACT_BUILD_TIMEOUT" "$windows_build_script") || return 4
        windows_build_script="$windows_build_guard"
        # Every guard needs its private launcher directory, including ordinary
        # and non-Rust builds. remote_path still names the existing source;
        # the future ordinary Cargo stage is prepared separately below.
        remote_cmd=$(_act_windows_stage_build_script "$host" "$remote_path" "$windows_build_script") || return 4
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

    # Ordinary Rust builds: create the stage root with a private copy of
    # the dependency caches before the build command runs (issue #15).
    local exit_code=0
    local native_execution_phase="" native_execution_timeout=null native_execution_transport_timeout=null
    local native_execution_exit=null native_execution_failure_kind="" native_build_program_dispatched=false
    local nonstrict_private_cargo_cache=false nonstrict_cargo_seed_json="" nonstrict_seed_home=""
    local cargo_finish=_act_finish_unix_private_cargo_home
    _act_is_windows_host "$host" && cargo_finish=_act_finish_windows_private_cargo_home
    if $nonstrict_rust_isolate; then
        local nonstrict_prepare_status=0 nonstrict_prepare=_act_prepare_unix_nonstrict_cargo_home
        local nonstrict_prepare_root="$isolation_root"
        if _act_is_windows_host "$host"; then
            nonstrict_prepare=_act_prepare_windows_nonstrict_cargo_home
            nonstrict_prepare_root="$remote_path"
        fi
        if _act_is_windows_host "$host"; then
            nonstrict_cargo_seed_json=$("$nonstrict_prepare" "$host" \
                "$nonstrict_prepare_root" "$nonstrict_stage_root" "$nonstrict_cargo_home" 2>>"$log_file") || \
                nonstrict_prepare_status=$?
        else
            nonstrict_cargo_seed_json=$("$nonstrict_prepare" "$host" \
                "$nonstrict_prepare_root" "$nonstrict_stage_root" "$nonstrict_cargo_home" "$remote_path" 2>>"$log_file") || \
                nonstrict_prepare_status=$?
        fi
        [[ -s "$log_file" ]] && cat "$log_file" >&2
        if [[ $nonstrict_prepare_status -eq 0 ]] && \
           nonstrict_seed_home=$(jq -er '.cargo_home' <<< "$nonstrict_cargo_seed_json") && \
           cargo_isolation_json=$(jq --argjson seed "$nonstrict_cargo_seed_json" \
               '.dependency_cache = {mode: "private-copy", seed: $seed}' <<< "$cargo_isolation_json"); then
            nonstrict_private_cargo_cache=true
        else
            _log_error "Unable to prepare a private Cargo dependency cache on $host; not building $platform" 2>&1 | tee -a "$log_file" >&2
            exit_code=4
        fi
    fi

    if [[ $exit_code -eq 0 && -n "$strict_sources_verification" ]]; then
        native_execution_phase=source_verification
        native_execution_timeout="$_ACT_SYNC_TIMEOUT"
        native_execution_transport_timeout="$_ACT_SYNC_TIMEOUT"
        _act_log_native_execution "$log_file" start "$native_execution_phase" \
            "$native_execution_timeout" "$native_execution_transport_timeout" null false || true
        _act_ssh_exec "$host" "$strict_sources_verification" "$_ACT_SYNC_TIMEOUT" 2>&1 | tee -a "$log_file" >&2
        exit_code=${PIPESTATUS[0]}
        native_execution_exit="$exit_code"
        [[ $exit_code -eq 0 ]] || native_execution_failure_kind="command"
        _act_log_native_execution "$log_file" finish "$native_execution_phase" \
            "$native_execution_timeout" "$native_execution_transport_timeout" "$native_execution_exit" false || true
    fi

    if [[ $exit_code -eq 0 && -n "$strict_toolchain_record_cmd" ]]; then
        local toolchain_observation_json toolchain_observation_raw toolchain_verify
        local toolchain_observation_status=0
        # Source authentication precedes this actual observation. The build
        # re-probes in its own execution shell before AND after the compiler;
        # a new login-shell selection must match the coordinator-held baseline.
        native_execution_phase=toolchain_observation
        native_execution_timeout="$_ACT_SYNC_TIMEOUT"
        native_execution_transport_timeout="$_ACT_SYNC_TIMEOUT"
        _act_log_native_execution "$log_file" start "$native_execution_phase" \
            "$native_execution_timeout" "$native_execution_transport_timeout" null false || true
        toolchain_observation_raw=$(_act_ssh_exec "$host" "$strict_toolchain_record_cmd" \
            "$_ACT_SYNC_TIMEOUT" 2> >(tee -a "$log_file" >&2)) || toolchain_observation_status=$?
        native_execution_exit="$toolchain_observation_status"
        _act_log_native_execution "$log_file" finish "$native_execution_phase" \
            "$native_execution_timeout" "$native_execution_transport_timeout" "$native_execution_exit" false || true
        if [[ $toolchain_observation_status -ne 0 ]]; then
            native_execution_failure_kind="command"
            exit_code="$toolchain_observation_status"
            _log_error "Toolchain observation returned $toolchain_observation_status; refusing compiler launch"
        elif toolchain_observation_json=$(jq -ce --arg target "$selected_triple" '
                select(type == "object" and
                    (.pin | type == "object" and (keys | sort) == ["identity", "sha256"] and
                        (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
                        (.identity | type == "string" and test("^[0-9]+(:[0-9]+){8}$"))) and
                    (.identity | type == "object" and .schema_version == 1 and
                        (.cwd | type == "string" and startswith("/")) and
                        (.target_triple | type == "string" and length > 0) and
                        ($target == "" or .target_triple == $target) and
                        (.tools | type == "object") and
                        (.tools as $tools | all(("cargo", "rustc");
                            $tools[.] | type == "object" and
                            (.selected_path | type == "string" and startswith("/")) and
                            (.selected_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
                            (.version | type == "string" and length > 0)))))
            ' <<< "$toolchain_observation_raw") && \
           strict_toolchain_pin_json=$(jq -c '.pin' <<< "$toolchain_observation_json") && \
           strict_toolchain_identity_json=$(jq -c '.identity' <<< "$toolchain_observation_json") && \
           toolchain_verify=$(_act_toolchain_identity_script verify "$strict_toolchain_receipt" \
                "$build_cmd" "$strict_toolchain_extra" "$strict_toolchain_pin_json" "$remote_path" \
                "$strict_toolchain_shim_dir"); then
            # Restore heredoc terminator newlines dropped by command substitution.
            remote_cmd="$strict_toolchain_run_prefix$toolchain_verify"$'\n'"$strict_toolchain_effective_build"$'\n'"$toolchain_verify"$'\n'
        else
            _log_error "Original toolchain observation or receipt pin invalid; refusing compiler launch"
            native_execution_failure_kind=validation
            exit_code=4
        fi
        if [[ $exit_code -ne 0 && -n "$toolchain_observation_raw" ]]; then
            printf '%s\n' "$toolchain_observation_raw" | tee -a "$log_file" >&2
        fi
    fi

    # Wrap the final effective Unix program after strict toolchain checks have
    # reconstructed it. Its host-side process group is retired after the build
    # or transport ends; the outer deadline allows only the cleanup grace.
    if [[ $exit_code -eq 0 ]] && ! _act_is_windows_host "$host"; then
        local build_shell="" guarded_build_status=0
        _act_is_local_host "$host" && build_shell="$BASH"
        remote_cmd=$(_act_unix_build_guard_script "$_ACT_BUILD_TIMEOUT" "$remote_cmd" "$build_shell") || \
            guarded_build_status=$?
        if [[ $guarded_build_status -ne 0 ]]; then
            exit_code=$guarded_build_status
            native_execution_phase=build_preparation
            native_execution_timeout=null
            native_execution_transport_timeout=null
            native_execution_exit=null
            native_execution_failure_kind=validation
        else
            build_transport_timeout=$((_ACT_BUILD_TIMEOUT + 10))
        fi
    fi

    # Cache/source preparation can consume the last available bytes. Observe
    # the same selected volumes again immediately before starting the compiler.
    if [[ $exit_code -eq 0 ]] && ! _act_is_windows_host "$host" &&
       ! _act_native_writable_paths_ready "$host" "$capability" "$native_writable_paths"; then
        exit_code=4
        native_storage_error="Native writable paths are not ready after preparation; build command was not started"
        _log_error "$native_storage_error"
    fi

    # Execute on remote host
    # Use PIPESTATUS to capture the actual command exit code, not tee's
    if [[ $exit_code -eq 0 ]]; then
        native_execution_phase=build_execution
        native_execution_timeout="$_ACT_BUILD_TIMEOUT"
        native_execution_transport_timeout="$build_transport_timeout"
        native_build_program_dispatched=true
        _act_log_native_execution "$log_file" start "$native_execution_phase" \
            "$native_execution_timeout" "$native_execution_transport_timeout" null true || true
        _act_ssh_exec "$host" "$remote_cmd" "$build_transport_timeout" 2>&1 | tee -a "$log_file" >&2
        exit_code=${PIPESTATUS[0]}
        native_execution_exit="$exit_code"
        [[ $exit_code -eq 0 ]] || native_execution_failure_kind="command"
        _act_log_native_execution "$log_file" finish "$native_execution_phase" \
            "$native_execution_timeout" "$native_execution_transport_timeout" "$native_execution_exit" true || true
    fi
    # A rejected final receipt must not replace the valid preparation record:
    # the failure result still needs that record to emit its diagnostic JSON.
    local verified_cargo_isolation_json
    if [[ $exit_code -eq 0 ]] && $nonstrict_private_cargo_cache; then
        local nonstrict_cargo_final_json nonstrict_cargo_seed_digest nonstrict_cargo_finish_result
        local nonstrict_cargo_finish_status=null nonstrict_cargo_command_exit=null
        nonstrict_cargo_seed_digest=$(jq -er '.receipt_sha256' <<< "$nonstrict_cargo_seed_json") || exit_code=4
        if [[ $exit_code -eq 0 ]]; then
            _act_log_native_execution "$log_file" start cargo_final_verification \
                "$_ACT_SYNC_TIMEOUT" "$_ACT_SYNC_TIMEOUT" null true || true
            nonstrict_cargo_finish_status=0
            nonstrict_cargo_finish_result=$("$cargo_finish" --native-execution \
                "$host" "$nonstrict_seed_home" "$nonstrict_cargo_seed_digest" \
                2> >(tee -a "$log_file" >&2)) || nonstrict_cargo_finish_status=$?
            if ! nonstrict_cargo_command_exit=$(jq -er '
                    .command_exit_code | select(type == "number" and floor == . and . >= 0 and . <= 255)
                ' <<< "$nonstrict_cargo_finish_result" 2>/dev/null); then
                nonstrict_cargo_command_exit=null
                [[ $nonstrict_cargo_finish_status -ne 0 ]] || nonstrict_cargo_finish_status=4
            fi
            _act_log_native_execution "$log_file" finish cargo_final_verification \
                "$_ACT_SYNC_TIMEOUT" "$_ACT_SYNC_TIMEOUT" "$nonstrict_cargo_command_exit" true || true
            if [[ $nonstrict_cargo_finish_status -eq 0 ]]; then
                if nonstrict_cargo_final_json=$(jq -ce '.receipt | select(type == "object")' \
                        <<< "$nonstrict_cargo_finish_result") && \
                   verified_cargo_isolation_json=$(jq --argjson final "$nonstrict_cargo_final_json" \
                        '.dependency_cache.final = $final' <<< "$cargo_isolation_json"); then
                    cargo_isolation_json="$verified_cargo_isolation_json"
                else
                    exit_code=4
                fi
            else
                exit_code="$nonstrict_cargo_finish_status"
            fi
        fi
        if [[ $exit_code -ne 0 ]]; then
            _log_error "Private Cargo cache failed final verification; refusing artifact collection"
            native_execution_phase=cargo_final_verification
            native_execution_timeout="$_ACT_SYNC_TIMEOUT"
            native_execution_transport_timeout="$_ACT_SYNC_TIMEOUT"
            native_execution_exit="$nonstrict_cargo_command_exit"
            native_execution_failure_kind=validation
            [[ "$nonstrict_cargo_command_exit" == null || "$nonstrict_cargo_command_exit" == 0 ]] || \
                native_execution_failure_kind="command"
        fi
    fi
    if [[ $exit_code -eq 0 ]] && $strict_private_cargo_cache; then
        local strict_cargo_final_json strict_cargo_seed_digest strict_cargo_finish_result
        local strict_cargo_finish_status=null strict_cargo_command_exit=null
        strict_cargo_seed_digest=$(jq -er '.receipt_sha256' <<< "$strict_cargo_seed_json") || exit_code=4
        local strict_cargo_finish_args=("$host" "$strict_cargo_home" "$strict_cargo_seed_digest")
        strict_cargo_finish_args+=("$remote_path" "$strict_dependency_sources_json")
        if _act_is_windows_host "$host"; then
            strict_cargo_finish_args+=("$build_cmd" "$build_env" "$strict_cargo_context_json")
        fi
        if [[ $exit_code -eq 0 ]]; then
            _act_log_native_execution "$log_file" start cargo_final_verification \
                "$_ACT_SYNC_TIMEOUT" "$_ACT_SYNC_TIMEOUT" null true || true
            strict_cargo_finish_status=0
            strict_cargo_finish_result=$("$cargo_finish" --native-execution "${strict_cargo_finish_args[@]}" \
                2> >(tee -a "$log_file" >&2)) || strict_cargo_finish_status=$?
            if ! strict_cargo_command_exit=$(jq -er '
                    .command_exit_code | select(type == "number" and floor == . and . >= 0 and . <= 255)
                ' <<< "$strict_cargo_finish_result" 2>/dev/null); then
                strict_cargo_command_exit=null
                [[ $strict_cargo_finish_status -ne 0 ]] || strict_cargo_finish_status=4
            fi
            _act_log_native_execution "$log_file" finish cargo_final_verification \
                "$_ACT_SYNC_TIMEOUT" "$_ACT_SYNC_TIMEOUT" "$strict_cargo_command_exit" true || true
            if [[ $strict_cargo_finish_status -eq 0 ]]; then
                if strict_cargo_final_json=$(jq -ce '.receipt | select(type == "object")' \
                        <<< "$strict_cargo_finish_result") && \
                   verified_cargo_isolation_json=$(jq --argjson final "$strict_cargo_final_json" \
                        '.dependency_cache.final = $final' <<< "$cargo_isolation_json"); then
                    cargo_isolation_json="$verified_cargo_isolation_json"
                else
                    exit_code=4
                fi
            else
                exit_code="$strict_cargo_finish_status"
            fi
        fi
        if [[ $exit_code -ne 0 ]]; then
            _log_error "Strict Cargo cache or dependency sources failed final verification; refusing artifact collection"
            native_execution_phase=cargo_final_verification
            native_execution_timeout="$_ACT_SYNC_TIMEOUT"
            native_execution_transport_timeout="$_ACT_SYNC_TIMEOUT"
            native_execution_exit="$strict_cargo_command_exit"
            native_execution_failure_kind=validation
            [[ "$strict_cargo_command_exit" == null || "$strict_cargo_command_exit" == 0 ]] || \
                native_execution_failure_kind="command"
        fi
    fi
    if [[ $exit_code -eq 0 && -n "$strict_toolchain_receipt" ]]; then
        # Never let a post-build pathname read redefine the pre-build baseline.
        # Secure collection requires the original held byte/inode pin and the
        # exact original observation, including cwd and selected target.
        local toolchain_identity_json="" toolchain_read toolchain_read_status=null
        if toolchain_read=$(_act_toolchain_identity_script read "$strict_toolchain_receipt" \
                "$build_cmd" "$strict_toolchain_extra" "$strict_toolchain_pin_json" "$remote_path"); then
            _act_log_native_execution "$log_file" start toolchain_final_verification 30 30 null true || true
            toolchain_read_status=0
            toolchain_identity_json=$(_act_ssh_exec "$host" "$toolchain_read"$'\n' 30 \
                2> >(tee -a "$log_file" >&2)) || toolchain_read_status=$?
            _act_log_native_execution "$log_file" finish toolchain_final_verification 30 30 "$toolchain_read_status" true || true
            if [[ $toolchain_read_status -eq 0 ]]; then
                if verified_cargo_isolation_json=$(_act_bind_toolchain_identity "$cargo_isolation_json" \
                        "$strict_toolchain_identity_json" "$toolchain_identity_json"); then
                    cargo_isolation_json="$verified_cargo_isolation_json"
                else
                    exit_code=4
                fi
            else
                exit_code="$toolchain_read_status"
            fi
        else
            exit_code=4
        fi
        if [[ $exit_code -ne 0 ]]; then
            _log_error "Strict toolchain identity receipt missing or invalid; refusing artifact collection"
            native_execution_phase=toolchain_final_verification
            native_execution_timeout=30
            native_execution_transport_timeout=30
            native_execution_exit="$toolchain_read_status"
            native_execution_failure_kind=validation
            [[ "$toolchain_read_status" == null || "$toolchain_read_status" == 0 ]] || \
                native_execution_failure_kind="command"
        fi
    fi
    if [[ $exit_code -eq 0 && -n "$strict_cache_root" ]]; then
        local cache_receipt cache_receipt_status=0
        _act_log_native_execution "$log_file" start cache_receipt_verification 30 30 null true || true
        cache_receipt=$(_act_ssh_exec "$host" \
            "cat '${strict_cargo_target_dir}.cache-receipt.json'" 30 \
            2> >(tee -a "$log_file" >&2)) || cache_receipt_status=$?
        _act_log_native_execution "$log_file" finish cache_receipt_verification 30 30 "$cache_receipt_status" true || true
        if [[ $cache_receipt_status -ne 0 ]]; then
            exit_code="$cache_receipt_status"
        elif jq -e '.namespace | test("^[0-9a-f]{64}$")' <<< "$cache_receipt" >/dev/null && \
           jq -e '.final_output_policy == "fresh-run-target-detached-under-custody"' \
                <<< "$cache_receipt" >/dev/null; then
            if verified_cargo_isolation_json=$(jq --argjson receipt "$cache_receipt" \
                    '.intermediate_cache.receipt = $receipt' <<< "$cargo_isolation_json"); then
                cargo_isolation_json="$verified_cargo_isolation_json"
            else
                exit_code=4
            fi
        else
            exit_code=4
        fi
        if [[ $exit_code -ne 0 ]]; then
            _log_error "Strict Cargo cache receipt missing or invalid; refusing artifact collection"
            native_execution_phase=cache_receipt_verification
            native_execution_timeout=30
            native_execution_transport_timeout=30
            native_execution_exit="$cache_receipt_status"
            native_execution_failure_kind=validation
            [[ $cache_receipt_status -eq 0 ]] || native_execution_failure_kind="command"
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
    local native_execution_error=""
    local additional_artifact_receipts=()
    local collected_sha256="" collected_size_bytes=0 collected_identity=""
    local strict_collection_receipts=()
    local workspace_member_receipts=()
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
            # Singleton targets need the same per-attempt custody as variants.
            # Reusing <run>/<platform>/<name> overwrites earlier result bytes
            # on retry, even though their worker receipts remain immutable.
            local native_artifact_parent="$ACT_ARTIFACTS_DIR/${run_id:-build-$tool_name}/${native_target_slug}"
            if ! mkdir -p "$native_artifact_parent" || \
               [[ ! -d "$native_artifact_parent" || -L "$native_artifact_parent" ]] || \
               ! artifact_dir=$(umask 077; mktemp -d "$native_artifact_parent/attempt.XXXXXXXX") || \
               [[ ! -d "$artifact_dir" || -L "$artifact_dir" ]]; then
                _log_error "Unable to create a fresh native artifact directory for $platform${selected_triple:+ ($selected_triple)}"
                jq -nc --arg platform "$platform" --arg host "$host" \
                    '{platform:$platform,method:"native",host:$host,status:"error",exit_code:4,
                      error:"Private native artifact directory could not be allocated"}'
                return 4
            fi
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
            local member_collected=false workspace_member_receipt=""
            local collection_receipt="" collection_mode=""

            _log_info "Downloading artifact: ${host}:${remote_artifact_path}"
            local scp_output
            if $strict_native_build; then
                collection_mode=700
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
                        # Workspace receipts and archive members use the
                        # canonical basename in artifact_dir. Keep failed
                        # first-attempt bytes under retry/, then let the same
                        # exclusive collector create a fresh canonical file.
                        # A no-clobber rename preserves the diagnostic inode;
                        # replacement or failure never licenses an overwrite.
                        local retained_attempt="$fallback_dir/$artifact_filename"
                        local failed_identity="" failed_sha="" failed_size="" retry_ready=false
                        if [[ ! -e "$this_artifact_path" && ! -L "$this_artifact_path" ]]; then
                            retry_ready=true
                        elif [[ -f "$this_artifact_path" && ! -L "$this_artifact_path" ]] && \
                             failed_identity=$(_act_file_identity "$this_artifact_path") && \
                             failed_sha=$(_act_sha256 "$this_artifact_path") && \
                             failed_size=$(_act_file_size "$this_artifact_path") && \
                             mv -n -- "$this_artifact_path" "$retained_attempt" && \
                             [[ ! -e "$this_artifact_path" && ! -L "$this_artifact_path" &&
                                -f "$retained_attempt" && ! -L "$retained_attempt" ]] && \
                             [[ "$(_act_file_identity "$retained_attempt")" == "$failed_identity" &&
                                "$(_act_sha256 "$retained_attempt")" == "$failed_sha" &&
                                "$(_act_file_size "$retained_attempt")" == "$failed_size" ]]; then
                            retry_ready=true
                            _log_info "Retained failed collection attempt: $retained_attempt"
                        fi
                        if ! $retry_ready; then
                            _log_error "Cannot preserve failed collection before bare-name retry: $this_artifact_path"
                        elif _act_is_windows_host "$host"; then
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
                        member_collected=true
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
                        member_collected=true
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
                    member_collected=true
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
                            member_collected=true
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
            if $member_collected && [[ -n "$workspace_binaries" ]]; then
                if workspace_member_receipt=$(_act_workspace_member_receipt \
                        "$artifact_dir" "$artifact_filename" \
                        "$collection_receipt" "$collection_mode"); then
                    workspace_member_receipts+=("$workspace_member_receipt")
                else
                    _log_error "Unable to freeze collected workspace member: $this_artifact_path"
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
                if archive_file_receipt=$(_act_workspace_member_receipt \
                        "$artifact_dir" "$archive_file"); then
                    local_artifact_paths+=("$artifact_dir/$archive_file")
                    workspace_member_receipts+=("$archive_file_receipt")
                else
                    _log_error "Unable to freeze coordinator workspace member: $archive_file"
                    download_failed=true
                fi
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
                "$platform" "$build_profile" file) || {
                _log_error "Cannot resolve workspace archive member: $archive_file"
                download_failed=true
                continue
            }
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
                if [[ -n "$archive_file_receipt" ]] && \
                   { [[ -z "$workspace_binaries" ]] || \
                     workspace_member_receipt=$(_act_workspace_member_receipt \
                         "$artifact_dir" "$archive_file" "$archive_file_receipt" "$archive_file_mode"); }; then
                    local_artifact_paths+=("$archive_file_local")
                    [[ -z "$workspace_binaries" ]] || workspace_member_receipts+=("$workspace_member_receipt")
                else
                    _log_error "Failed to collect workspace archive member $archive_file from $host:$archive_file_remote"
                    download_failed=true
                fi
            elif _act_is_local_host "$host"; then
                if [[ -f "$archive_file_remote" && ! -L "$archive_file_remote" ]] && \
                   cp "$archive_file_remote" "$archive_file_local" && \
                   chmod "$archive_file_mode" "$archive_file_local" && \
                   { [[ -z "$workspace_binaries" ]] || \
                     archive_file_receipt=$(_act_workspace_member_receipt \
                         "$artifact_dir" "$archive_file"); }; then
                    local_artifact_paths+=("$archive_file_local")
                    [[ -z "$workspace_binaries" ]] || workspace_member_receipts+=("$archive_file_receipt")
                else
                    _log_error "Failed to collect workspace archive member $archive_file from $host:$archive_file_remote"
                    download_failed=true
                fi
            elif scp -o ConnectTimeout="$_ACT_SSH_TIMEOUT" \
                    -o StrictHostKeyChecking=accept-new \
                    "${ssh_destination}:${archive_file_remote}" \
                    "$archive_file_local" >/dev/null 2>&1 && \
                 chmod "$archive_file_mode" "$archive_file_local" && \
                 { [[ -z "$workspace_binaries" ]] || \
                   archive_file_receipt=$(_act_workspace_member_receipt \
                       "$artifact_dir" "$archive_file"); }; then
                local_artifact_paths+=("$archive_file_local")
                [[ -z "$workspace_binaries" ]] || workspace_member_receipts+=("$archive_file_receipt")
            else
                _log_error "Failed to collect workspace archive member $archive_file from $host:$archive_file_remote"
                download_failed=true
            fi
        done < <(jq -c '.[]' <<< "$workspace_archive_files_json")

        # Build-produced release assets (installers, archives and other files)
        # are collected by literal name but never folded into the process
        # archive.  The receipt is carried in the target result so strict
        # manifest generation can require its exact name, bytes, and identity.
        local additional_spec additional_name additional_remote additional_local
        local additional_receipt additional_format additional_mode
        local additional_sha additional_size additional_identity
        if [[ -n "$selected_triple" ]]; then
            local additional_owner_triples
            additional_owner_triples=$(act_get_configured_target_triples "$tool_name" "$platform") || return 4
            # Platform-level companions have one producer. Additional assets
            # from later variants cannot duplicate or replace its receipt.
            if [[ "$selected_triple" != "${additional_owner_triples%%$'\n'*}" ]]; then
                additional_json='[]'
            fi
        fi
        while IFS= read -r additional_spec; do
            additional_name=$(jq -r '.name' <<< "$additional_spec") || return 4
            additional_format=$(jq -r '.format' <<< "$additional_spec") || return 4
            additional_mode=600
            if [[ "$additional_format" == binary && "$platform" != windows/* ]]; then
                additional_mode=700
            fi
            if ! _act_is_safe_basename "$additional_name" || \
               [[ -e "$artifact_dir/$additional_name" || -L "$artifact_dir/$additional_name" ]]; then
                _log_error "Unsafe or colliding additional release artifact: $additional_name"
                download_failed=true
                continue
            fi
            additional_remote=$(act_get_remote_artifact_path \
                "$language" "$artifact_source_root" "$build_env" "$additional_name" \
                "$platform" "$build_profile" file) || {
                _log_error "Cannot resolve additional release artifact: $additional_name"
                download_failed=true
                continue
            }
            additional_local="$artifact_dir/$additional_name"
            additional_receipt=""
            if $strict_native_build; then
                if _act_is_local_host "$host"; then
                    additional_receipt=$(_act_collect_stream_exclusive \
                        "$additional_local" "$additional_mode" _act_stream_local_file \
                        "$additional_remote") || additional_receipt=""
                elif _act_is_windows_host "$host"; then
                    additional_receipt=$(_act_collect_stream_exclusive \
                        "$additional_local" "$additional_mode" _act_stream_remote_windows_file \
                        "$host" "$additional_remote") || additional_receipt=""
                else
                    additional_receipt=$(_act_collect_stream_exclusive \
                        "$additional_local" "$additional_mode" _act_stream_remote_unix_file \
                        "$ssh_destination" "$additional_remote") || additional_receipt=""
                fi
                if [[ -z "$additional_receipt" ]]; then
                    _log_error "Failed to collect additional release artifact $additional_name from $host:$additional_remote"
                    download_failed=true
                    continue
                fi
            else
                if _act_is_local_host "$host" && \
                   [[ -f "$additional_remote" && ! -L "$additional_remote" ]] && \
                   cp "$additional_remote" "$additional_local" && \
                   chmod "$additional_mode" "$additional_local"; then
                    :
                elif ! _act_is_local_host "$host" && \
                     scp -o ConnectTimeout="$_ACT_SSH_TIMEOUT" \
                         -o StrictHostKeyChecking=accept-new \
                         "${ssh_destination}:${additional_remote}" \
                         "$additional_local" >/dev/null 2>&1 && \
                     chmod "$additional_mode" "$additional_local"; then
                    :
                else
                    _log_error "Failed to collect additional release artifact $additional_name from $host:$additional_remote"
                    download_failed=true
                    continue
                fi
                additional_sha=$(_act_sha256 "$additional_local") || return 4
                additional_size=$(_act_file_size "$additional_local") || return 4
                additional_identity=$(_act_file_identity "$additional_local") || return 4
                additional_receipt=$(jq -nc --arg path "$additional_local" \
                    --arg sha256 "$additional_sha" --argjson size_bytes "$additional_size" \
                    --arg identity "$additional_identity" \
                    '{path:$path, sha256:$sha256, size_bytes:$size_bytes, identity:$identity}') || return 4
            fi
            additional_sha=$(jq -r '.sha256' <<< "$additional_receipt") || return 4
            additional_size=$(jq -r '.size_bytes' <<< "$additional_receipt") || return 4
            additional_identity=$(jq -r '.identity' <<< "$additional_receipt") || return 4
            if ! _act_validate_additional_artifact "$additional_local" "$platform" \
                "$additional_format" "$additional_sha" "$additional_size" "$additional_identity"; then
                _log_error "Rejected additional release artifact $additional_name from $host:$additional_remote (declared format $additional_format)"
                download_failed=true
                continue
            fi
            additional_artifact_receipts+=("$additional_receipt")
        done < <(jq -c '.[]' <<< "$additional_json")

        # Set final status and artifact path(s)
        # Every remote output has been copied home; a staged build's private
        # source copy is no longer needed by anything below.
        _act_remove_build_stage_root "$host" "$output_stage_root"
        output_stage_root=""

        if [[ "$download_failed" == true ]]; then
            if $strict_native_build || [[ -n "$workspace_binaries" || ${#local_artifact_paths[@]} -eq 0 ]]; then
                status="failed"
                exit_code=7
                if [[ -n "$workspace_binaries" ]]; then
                    local_artifact_path=""
                    local_artifact_paths=()
                    additional_artifact_receipts=()
                fi
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
                # shellcheck source=SCRIPTDIR/artifact_naming.sh
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
                        '{status:"failed",exit_code:7,platform:$platform,
                          artifact_path:"",artifact_paths:[],additional_artifacts:[],
                          error:("Release commit is missing for workspace companion-file staging on " + $platform)}'
                    return 7
                fi
                workspace_include_revision="$release_git_sha"
            fi
            if ! staged_workspace_includes=$(
                _act_stage_workspace_include_files \
                    "$config_file" "$local_path" "$artifact_dir" "$workspace_include_revision" \
                    true
            ); then
                _log_error "Failed to stage configured workspace companion files for $platform"
                jq -nc --arg platform "$platform" \
                    '{status:"failed",exit_code:7,platform:$platform,
                      artifact_path:"",artifact_paths:[],additional_artifacts:[],
                      error:("Workspace companion-file staging failed for " + $platform)}'
                return 7
            fi
            local staged_include staged_include_record
            while IFS= read -r staged_include_record; do
                [[ -n "$staged_include_record" ]] || continue
                if ! staged_include=$(jq -er '.member | select(type == "string" and length > 0)' \
                        <<< "$staged_include_record"); then
                    _log_error "Workspace companion receipt is invalid for $platform"
                    jq -nc --arg platform "$platform" \
                        '{status:"failed",exit_code:7,platform:$platform,
                          artifact_path:"",artifact_paths:[],additional_artifacts:[],
                          error:"Workspace companion receipt is invalid"}'
                    return 7
                fi
                workspace_member_receipts+=("$staged_include_record")
                archive_files+=("$staged_include")
            done <<< "$staged_workspace_includes"
            _log_info "Workspace archive members: ${archive_files[*]}"

            # All workspace producers use the same fresh held destination.
            # An archiver failure never becomes a raw-binary fallback, and a
            # zero-exit partial ZIP still has to prove its complete payload.
            local archive_receipt="" archive_mode=700
            [[ "$platform" == windows/* ]] && archive_mode=600
            if _act_is_safe_basename "$archive_name"; then
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
            fi
            if [[ -n "$archive_receipt" ]] && \
               ! _act_validate_release_archive_metadata "$archive_path" "$archive_ext"; then
                _log_error "Workspace archive metadata is not normalized for publication: $platform"
                archive_receipt=""
            fi
            if $strict_native_build; then
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
            else
                local validate_workspace_architecture=false
                case "$language" in rust|go) validate_workspace_architecture=true ;; esac
                if [[ -n "$archive_receipt" ]] && \
                   ! _act_validate_workspace_archive \
                         "$archive_path" "$archive_ext" "$platform" "$config_file" \
                         "$validate_workspace_architecture"; then
                    _log_error "Workspace archive does not match its configured members for $platform"
                    archive_receipt=""
                fi
            fi
            if [[ -n "$archive_receipt" ]] && \
               ! _act_validate_workspace_member_receipts \
                   "$archive_path" "$archive_ext" "$artifact_dir" \
                   "${workspace_member_receipts[@]}"; then
                _log_error "Workspace archive does not match its frozen member receipts for $platform"
                archive_receipt=""
            fi
            # Member validators must not replace/rewrite the archive that the
            # exclusive producer accepted, even with another valid archive.
            local verified_archive_receipt=""
            if [[ -n "$archive_receipt" ]]; then
                verified_archive_receipt=$(_act_workspace_member_receipt \
                    "$artifact_dir" "$archive_name") || verified_archive_receipt=""
                if [[ -z "$verified_archive_receipt" ]] || \
                   ! jq -e --argjson collected "$archive_receipt" '
                       .path == $collected.path and .sha256 == $collected.sha256 and
                       .size_bytes == $collected.size_bytes and .identity == $collected.identity
                   ' <<< "$verified_archive_receipt" >/dev/null; then
                    _log_error "Workspace archive changed after collection for $platform"
                    archive_receipt=""
                fi
            fi
            if [[ -n "$archive_receipt" ]]; then
                _log_ok "Created archive through held descriptor: $archive_path"
                local_artifact_path="$archive_path"
                local_artifact_paths=("$archive_path")
                collected_sha256=$(jq -r '.sha256' <<< "$archive_receipt")
                collected_size_bytes=$(jq -r '.size_bytes' <<< "$archive_receipt")
                collected_identity=$(jq -r '.identity' <<< "$archive_receipt")
            else
                _log_error "Workspace archive creation or verification failed for $platform"
                echo "Workspace archive creation or verification failed" >> "$log_file"
                status="failed"
                exit_code=7
                local_artifact_path=""
                local_artifact_paths=()
                additional_artifact_receipts=()
                collected_sha256=""
                collected_size_bytes=0
                collected_identity=""
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

    elif [[ -n "$native_storage_error" ]]; then
        # A late capacity refusal never started the build command. Preserve
        # the admission outcome for public reporting and resume accounting.
        status="failed"
        exit_code=4
    elif [[ $exit_code -eq 124 ]]; then
        native_execution_error="Native ${native_execution_phase:-execution} on $host returned exit 124 (configured phase timeout ${native_execution_timeout}s, transport timeout ${native_execution_transport_timeout}s); inspect $log_file for the command or deadline diagnostic"
        _log_error "$native_execution_error"
        status="timeout"
        exit_code=5
    else
        if [[ -n "$native_execution_phase" && -n "$native_execution_failure_kind" ]]; then
            if [[ "$native_execution_failure_kind" == validation ]]; then
                native_execution_error="Native $native_execution_phase validation failed on $host (command exit $native_execution_exit); refusing further build or collection work"
            else
                native_execution_error="Native $native_execution_phase on $host returned exit $native_execution_exit"
            fi
            _log_error "$native_execution_error"
        else
            _log_error "Build failed on $host with exit code $exit_code"
        fi
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
        --arg execution_phase "$native_execution_phase" \
        --arg execution_timeout "$native_execution_timeout" \
        --arg execution_transport_timeout "$native_execution_transport_timeout" \
        --argjson execution_exit "$native_execution_exit" \
        --arg execution_failure_kind "$native_execution_failure_kind" \
        --argjson build_program_dispatched "$native_build_program_dispatched" \
        --arg execution_error "$native_execution_error" \
        --arg storage_error "$native_storage_error" \
        --arg log_file "$log_file" \
        'def seconds: if test("^[1-9][0-9]*$") then tonumber else null end;
        input as $cargo_isolation | {
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
        } + (if $execution_phase == "" then {} else
               {native_execution: {
                   phase: $execution_phase,
                   timeout_seconds: ($execution_timeout | seconds),
                   transport_timeout_seconds: ($execution_transport_timeout | seconds),
                   command_exit_code: $execution_exit,
                   failure_kind: (if $execution_failure_kind == "" then null else $execution_failure_kind end),
                   build_program_dispatched: $build_program_dispatched
               }} end)
          + (if $execution_error == "" then {} else
               {stage: $execution_phase, error: $execution_error} end)
          + (if $storage_error == "" then {} else
               {stage:"host_readiness",error:$storage_error} end)' <<< "$cargo_isolation_json" || return 4

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
    local path artifact_dir directory_field legacy_paths array_count

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

    for directory_field in artifact_dir workflow_artifact_dir workflow_payload_dir; do
        artifact_dir=$(jq -r --arg field "$directory_field" '.[$field] // empty' <<< "$result_json" 2>/dev/null)
        [[ -n "$artifact_dir" ]] || continue
        [[ -d "$artifact_dir" && ! -L "$artifact_dir" ]] || return 4
        # Process substitution cannot propagate find's exit status. Preflight
        # traversal explicitly so an unreadable subtree cannot yield a
        # deceptively partial receipt set.
        find "$artifact_dir" -type f ! -type l -print0 >/dev/null 2>&1 || return 4
        if [[ "$directory_field" != artifact_dir ]] &&
           [[ -n "$(find "$artifact_dir" \( -type l -o \( -type f -links +1 \) -o \( ! -type f ! -type d \) \) -print -quit)" ]]; then
            _log_error "Workflow inventory contains a linked directory/file or special entry: $artifact_dir"
            return 4
        fi
        while IFS= read -r -d '' path; do
            [[ -z "${seen_paths[$path]:-}" ]] || continue
            seen_paths["$path"]=1
            artifact_paths+=("$path")
        done < <(find "$artifact_dir" -type f ! -type l -print0 2>/dev/null)
    done

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

    printf '%s\n' "${receipts[@]}" | jq -scS 'sort_by(.path)'
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
    expected=$(jq -ceS '
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
    _act_workflow_payload_plans_json "$tool" "$version" >/dev/null || return 4
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
            if [[ "$language" != rust ]]; then
                _log_error "Native target variants require a Rust build: $platform"
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
        local job workflow local_path extra_flags workflow_plans workflow_plan materialized
        workflow_plans=$(_act_workflow_payload_plans_json "$tool_name" "$version") || return 4
        workflow_plan=$(jq -c --arg target "$target" '.[$target] // null' <<< "$workflow_plans") || return 4
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
        if [[ "$workflow_plan" != null && "$exit_code" -eq 0 ]] &&
           jq -e '.status == "success" or .status == "ok" or .status == "passed"' <<< "$result" >/dev/null; then
            if materialized=$(_act_materialize_workflow_payloads "$result" "$workflow_plan"); then
                result="$materialized"
            else
                exit_code=4
                result=$(jq -c '.workflow_artifact_dir=.artifact_dir | .artifact_dir="" |
                    .artifact_path="" | .artifact_paths=[] | .additional_artifacts=[] |
                    .status="failed" | .exit_code=4 |
                    .error="Workflow payloads do not satisfy the configured primary and companion ownership contract"' \
                    <<< "$result") || return 4
            fi
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

# Keep the backend's process-group leader alive until the worker has observed
# its exit and requested cleanup. This Bash 4 coprocess owns only this target:
# its stdin is a parent-lifetime channel, never the dispatcher's task stream.
# A caught TERM keeps the anchor alive during cleanup, preventing a delayed
# group signal from reaching a reused PID after an early backend exit.
_act_run_target_group() {
    local group_log="$1"
    shift
    local group_pid="$BASHPID" group_child="" group_finished=false
    local group_cancelled=false group_command="" group_running="" group_exit=0
    local group_read_status=0
    set +m
    trap - EXIT
    trap 'group_cancelled=true' INT TERM HUP PIPE
    # The worker registers its PID/channels before authorizing any backend.
    if ! IFS= read -r group_command || [[ "$group_command" != start ]] || $group_cancelled; then
        return 130
    fi
    "$@" </dev/null >> "$group_log" 2>&1 &
    group_child=$!
    while ! $group_cancelled; do
        if ! $group_finished; then
            group_running=$(jobs -pr)
            case $'\n'"$group_running"$'\n' in
                *$'\n'"$group_child"$'\n'*) ;;
                *)
                    wait "$group_child" || group_exit=$?
                    group_finished=true
                    printf 'exit:%s\n' "$group_exit" || break
                    ;;
            esac
        fi
        group_read_status=0
        IFS= read -r -t 0.1 group_command || group_read_status=$?
        # EOF also retires the group if the outer worker is killed. Backend
        # stdin was replaced above, so it cannot keep this lease pipe open.
        if (( group_read_status == 0 || group_read_status == 1 )); then
            break
        fi
        (( group_read_status > 128 )) || break
    done
    trap '' INT TERM HUP PIPE
    kill -TERM -- "-$group_pid" 2>/dev/null || true
    if ! $group_finished; then
        # Native supervisors have their own two-second descendant drain.
        # Give them time to finish before forcing remaining local processes.
        sleep 5
    fi
    # The live anchor still owns this group even if its backend exited first.
    # Completion does not need a grace delay: no backend work remains valid.
    kill -KILL -- "-$group_pid" 2>/dev/null || true
    return 4
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
    local slot_requested=false backend_started=false
    local scheduled_source=null
    if [[ "$strict_release_contract" == "true" ]]; then
        # Record the source assigned to this worker even if capacity or host
        # admission refuses it. This is not evidence that a compiler ran.
        scheduled_source=$(jq -nc --arg run "$run_id" --arg sha "$release_git_sha" \
            --arg ref "$release_git_ref" --arg host "$host" --argjson roots "$source_roots_json" \
            '{run_id:$run,git_sha:$sha,git_ref:$ref,host:$host,root:$roots[$host]}') || return 4
    fi

    _act_write_worker_result() {
        local body="$1"
        # Never trust build-command stdout to classify an artifact for publication.
        # A refused attempt still belongs to this scheduled target, even when
        # admission stopped before the backend emitted its execution identity.
        # Leave successful identities untouched for the artifact/matrix checks.
        body=$(jq -c --arg purpose "$build_purpose" --arg task_key "$task_key" \
            --arg platform "$target" --arg host "$host" --arg triple "$selected_triple" \
            --argjson source_sync "$source_sync_receipt" \
            --argjson backend_started "$backend_started" \
            --argjson scheduled_source "$scheduled_source" \
            '. + {build_purpose: $purpose, publishable: ($purpose == "release"), task_key:$task_key,
                  backend_started:$backend_started} |
             if (.status // "") | IN("success", "ok", "passed") then .
             else . + {platform:$platform,host:(.host // $host)} +
                  (if $triple == "" then {} else {target_triple:$triple} end) end |
             if $source_sync == null then . else .source_sync = $source_sync end |
             if $scheduled_source == null then del(.scheduled_source)
             else .scheduled_source = $scheduled_source end' \
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

    local worker_pid="" worker_launch_pending=false worker_cancelled=false
    local worker_result_fd="" worker_control_fd="" worker_guard_exit=0
    local -a _ACT_TARGET_GROUP=()
    local _ACT_TARGET_GROUP_PID=""
    _act_worker_release_slot() {
        # Release is ownership-checked and safe when no slot was granted. Mark
        # the request before acquisition so cancellation between grant and
        # return cannot strand this attempt's capacity lease.
        if $slot_requested && declare -F selector_release_slot &>/dev/null; then
            selector_release_slot "$host" "$slot_id" >/dev/null 2>&1 || true
            slot_requested=false
        fi
    }

    _act_worker_drain_group() {
        # Both descriptors came from Bash's own coprocess table. Numeric
        # validation confines eval to closing those descriptors on Bash 4.0,
        # which predates the later {variable} redirection syntax.
        if [[ "$worker_control_fd" =~ ^[0-9]+$ ]]; then
            eval "exec ${worker_control_fd}>&-"
            worker_control_fd=""
        fi
        if [[ "$worker_pid" =~ ^[1-9][0-9]*$ ]]; then
            worker_guard_exit=0
            wait "$worker_pid" 2>/dev/null || worker_guard_exit=$?
            worker_pid=""
        fi
        if [[ "$worker_result_fd" =~ ^[0-9]+$ ]]; then
            eval "exec ${worker_result_fd}<&-"
            worker_result_fd=""
        fi
    }

    _act_worker_cancel() {
        worker_cancelled=true
        # A trap can run between the background fork and assigning $!. Defer
        # cleanup until the exact child process group has been recorded.
        $worker_launch_pending && return 0
        trap '' INT TERM HUP
        # Closing the parent-lifetime channel asks the still-owned anchor
        # to drain every descendant before this worker releases its slot.
        _act_worker_drain_group
        # Preserve a completed receipt if cancellation raced its publication.
        # Otherwise retain an actual interrupted attempt for exact-run resume.
        if [[ ! -e "$result_path" && ! -L "$result_path" ]]; then
            local cancelled_result
            cancelled_result=$(jq -nc --arg target "$target" --arg host "$host" \
                '{platform: $target, host: $host, status: "failed", exit_code: 130,
                  error: "Target interrupted"}') &&
                _act_write_worker_result "$cancelled_result" || true
        fi
        exit 130
    }
    trap _act_worker_release_slot EXIT
    trap _act_worker_cancel INT TERM HUP

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
        slot_requested=true
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
                  stage:"host_capacity", error: $error}')
            if ! _act_write_worker_result "$slot_failure"; then
                _act_worker_release_slot
                trap - EXIT INT TERM HUP
                return 4
            fi
            _act_worker_release_slot
            trap - EXIT INT TERM HUP
            return 2
        fi
    fi

    local worker_status=0 result receipts result_status
    local worker_monitor=false worker_message="" worker_protocol_valid=false
    [[ $- != *m* ]] || worker_monitor=true
    set -m
    worker_launch_pending=true
    # Only this wrapper knows whether capacity was granted and the backend
    # was launched. Backend stdout cannot claim a pre-execution refusal to
    # recover retry budget after it has actually run.
    backend_started=true
    coproc _ACT_TARGET_GROUP {
        _act_run_target_group "$log_path" _act_build_orchestration_target \
            "$tool_name" "$version" "$run_id" "$target" \
            "$strict_release_contract" "$release_contract_json" "$source_roots_json" \
            "$release_git_sha" "$release_git_ref" "$host" "$selected_triple"
    }
    worker_pid="${_ACT_TARGET_GROUP_PID:-}"
    worker_result_fd="${_ACT_TARGET_GROUP[0]:-}"
    worker_control_fd="${_ACT_TARGET_GROUP[1]:-}"
    worker_launch_pending=false
    $worker_monitor || set +m
    $worker_cancelled && _act_worker_cancel
    if [[ "$worker_control_fd" =~ ^[0-9]+$ && "$worker_result_fd" =~ ^[0-9]+$ ]] &&
       printf 'start\n' >&"$worker_control_fd" &&
       IFS= read -r -u "$worker_result_fd" worker_message &&
       [[ "$worker_message" =~ ^exit:([0-9]{1,3})$ ]] &&
       (( 10#${BASH_REMATCH[1]} <= 255 )); then
        worker_status=$((10#${BASH_REMATCH[1]}))
        worker_protocol_valid=true
    fi
    _act_worker_drain_group
    if ! $worker_protocol_valid; then
        worker_status="$worker_guard_exit"
        [[ "$worker_status" -ne 0 ]] || worker_status=6
    fi

    result=$(grep '^{.*}$' "$log_path" | tail -1)
    if [[ -z "$result" ]] || ! jq -e '.' <<< "$result" &>/dev/null; then
        [[ "$worker_status" -ne 0 ]] || worker_status=6
        result=$(jq -nc --arg target "$target" --arg host "$host" \
            --argjson exit_code "$worker_status" \
            '{platform: $target, host: $host, status: "failed",
              exit_code: $exit_code, error: "Worker produced no valid result"}')
    fi
    result_status=$(jq -r '.status // "unknown"' <<< "$result")
    # The log can contain backend success before the orchestration child has
    # finished normalization and strict staging. Its observed exit must agree
    # before those artifact paths become an immutable, reusable success.
    if [[ "$worker_status" -ne 0 ]] &&
       [[ "$result_status" == success || "$result_status" == ok || "$result_status" == passed ]]; then
        result_status=failed
        if ! result=$(jq -c --argjson exit_code "$worker_status" '
            .status = "failed" | .exit_code = $exit_code |
            .error = (.error // "Worker exited nonzero despite reporting success") |
            del(.resume_artifacts)
        ' <<< "$result"); then
            _act_worker_release_slot
            trap - EXIT INT TERM HUP
            return 4
        fi
    fi
    if [[ "$result_status" == success || "$result_status" == ok || "$result_status" == passed ]] && \
       ! _act_matrix_result_matches "$result" "$target" "$selected_triple"; then
        worker_status=4
        result_status=failed
        if ! result=$(jq -c '.status = "failed" | .exit_code = 4 |
            .error = "Native worker result does not match the requested target triple"' <<< "$result"); then
            _act_worker_release_slot
            trap - EXIT INT TERM HUP
            return 4
        fi
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
        # Returning unwinds these locals before the background shell's EXIT
        # trap runs. Release while the attempt's lease identity is still in
        # scope, including storage/receipt failures after a real build.
        _act_worker_release_slot
        trap - EXIT INT TERM HUP
        return 4
    fi
    _act_worker_release_slot
    trap - EXIT INT TERM HUP
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

# The immutable worker receipt omits annotations added by the coordinator.
# Compare every substantive field, allowing only the known true annotations
# from worker collection, recovered-success reuse and retry-limit reporting.
_act_relocation_receipt_matches() {
    local path="$1" saved="$2"
    jq -se --slurpfile saved /dev/stdin '
        def annotations:
            . as $result |
            all(["execution_started","resume_reused","retry_limit_exceeded"][];
                . as $key | ($result | has($key) | not) or $result[$key] == true);
        def receipt:
            del(.log_path,.result_path,.attempt,.execution_started,.resume_reused,.retry_limit_exceeded);
        length == 1 and ($saved | length == 1) and ($saved[0] as $saved | .[0] |
            type == "object" and ($saved | type == "object") and
            annotations and ($saved | annotations) and
            (receipt == ($saved | receipt)))
    ' "$path" <<< "$saved" >/dev/null
}

_act_relocate_failed_target() {
    local tool="$1" version="$2" run_id="$3" before="$4" request="$5" approval_file="$6"
    local target="${request%%=*}" host="${request#*=}" old_host configured_host host_platform
    local config_file="$ACT_REPOS_DIR/${tool}.yaml"
    # Bind the configuration used by host selection, readiness and transport.
    # An inactive default file cannot authorize changes to an override file.
    local hosts_file="${DSR_HOSTS_FILE:-${DSR_CONFIG_DIR:-$HOME/.config/dsr}/hosts.yaml}"
    local entry result result_path sync_json roots hosts receipt repo_hash hosts_hash
    local prior_result prior_log result_hash log_hash
    local approval prior_config prior_config_hash prior_json current_json projection
    local source_inventory dependency_checkouts replacement_path replacement_root
    local source_sha source_ref source_root
    [[ "$request" == *=* && "$target" =~ ^[a-z]+/[a-z0-9]+$ &&
       "$host" =~ ^[A-Za-z0-9_-]+$ ]] || return 4
    local relocation_triples
    relocation_triples=$(act_get_configured_target_triples "$tool" "$target") || return 4
    if [[ "$relocation_triples" == *$'\n'* ]] || jq -e --arg target "$target" '
        any(.context.build_tasks[]?; .platform == $target and .key != $target)
    ' <<< "$before" >/dev/null; then
        _log_error "Platform-only relocation cannot move a variant matrix; resume its failed variants on the bound host"
        return 4
    fi
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
        '.platform == $target and .host == $host and
         (.status | IN("failed","error","timeout")) and
         (.exit_code | type == "number" and floor == . and . > 0 and . <= 255) and
         (.exit_code != 130 and .exit_code != 143) and
         .build_purpose == "release" and .publishable == true' \
        "$prior_result" >/dev/null || return 4
    result_hash=$(_act_sha256 "$prior_result") || return 4
    log_hash=$(_act_sha256 "$prior_log") || return 4
    [[ "$result_hash" =~ ^[0-9a-f]{64}$ && "$log_hash" =~ ^[0-9a-f]{64}$ ]] || return 4
    result=$(jq -c --arg target "$target" '.target_statuses[$target].result' <<< "$before") || return 4
    _act_relocation_receipt_matches "$prior_result" "$result" || return 4
    source_sha=$(jq -er '.git_sha | strings | select(test("^[0-9a-f]{40}$"))' <<< "$before") || return 4
    source_ref=$(jq -er '.git_ref | strings | select(length > 0)' <<< "$before") || return 4
    source_root=$(jq -er --arg host "$old_host" \
        '.context.source_roots[$host] | strings | select(length > 0)' <<< "$before") || return 4
    # Strict Rust attempts may also attest their compiler environment. Keep
    # that evidence mandatory for older receipts, and reject any contradiction
    # when the worker's scheduled source supplies the non-Rust/refusal binding.
    jq -e --arg run "$run_id" --arg sha "$source_sha" --arg ref "$source_ref" \
        --arg host "$old_host" --arg root "$source_root" '
        (.build_influence_env == null or (.build_influence_env | type == "object")) and
        (if has("scheduled_source") then
            .scheduled_source == {run_id:$run,git_sha:$sha,git_ref:$ref,host:$host,root:$root} and
            ((.build_influence_env // {}) as $env |
                if ($env | has("DSR_RELEASE_GIT_SHA") or has("DSR_RELEASE_GIT_REF")) then
                    $env.DSR_RELEASE_GIT_SHA == $sha and $env.DSR_RELEASE_GIT_REF == $ref
                else true end)
         else
            .build_influence_env.DSR_RELEASE_GIT_SHA == $sha and
            .build_influence_env.DSR_RELEASE_GIT_REF == $ref
         end)' \
        "$prior_result" >/dev/null || return 4
    # An unavailable successful artifact is not permission to silently rebuild
    # or relocate it. Preserve all successful receipt identities before staging.
    while IFS= read -r entry; do
        result=$(jq -c '.result // empty' <<< "$entry")
        result_path=$(jq -r '.result_path // empty' <<< "$entry")
        [[ -n "$result" ]] && _act_target_result_available "$result" release true || return 4
        if [[ -n "$result_path" ]]; then
            [[ -f "$result_path" && ! -L "$result_path" ]] || return 4
            _act_relocation_receipt_matches "$result_path" "$result" || return 4
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
      def path: gsub("\\\\";"/") | if test("^[A-Za-z]:/") then ascii_downcase else . end;
      def context:
        type == "object" and
        (.git_sha | type == "string" and test("^[0-9a-f]{40}$") and . != ("0" * 40)) and
        (.git_ref | type == "string" and (. == "" or startswith("refs/heads/"))) and
        (.bundle_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
        (.core_autocrlf == "false" or .core_autocrlf == "true" or .core_autocrlf == "input") and
        (.core_eol == "lf" or .core_eol == "crlf" or .core_eol == "native") and
        (.tags | type == "object" and all(to_entries[];
          (.key | startswith("refs/tags/")) and (.value | type == "string" and test("^[0-9a-f]{40}$"))));
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
      select(if has("staged_ordinary") then
        .staged_ordinary == true and (.git_context | context) and
        (.sibling_git_contexts | type == "object" and all(to_entries[];
          (.key | test("^[A-Za-z0-9][A-Za-z0-9._+-]*$") and (contains("..") | not)) and
          (.value | context))) and
        all(.hosts[] | select(.status == "success"); . as $row |
          (.git_context | context) and
          ((.git_context | del(.bundle_path,.source_root)) == $receipt.git_context) and
          (.git_context.bundle_path | text) and
          ((.git_context.source_root | path) == (.path | path)) and
          (.sibling_git_contexts | type == "object") and
          ((.sibling_git_contexts | keys) == ($receipt.sibling_git_contexts | keys)) and
          all(.sibling_git_contexts | to_entries[]; . as $sibling |
            (.value | context) and (.value.bundle_path | text) and
            ((.value | del(.bundle_path,.source_root)) == $receipt.sibling_git_contexts[$sibling.key]) and
            ((.value.source_root | path) == (($row.path | sub("/source$";"")) + "/" + .key | path))))
        else true end) |
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
    local resume_retry_limit="${BUILD_RETRY_MAX:-3}"
    if $resume_run; then
        if [[ ! "$resume_retry_limit" =~ ^[0-9]{1,4}$ ]] ||
           ((10#$resume_retry_limit < 1 || 10#$resume_retry_limit > 1000)); then
            _log_error "Resume retry limit must be an integer from 1 through 1000"
            return 4
        fi
        resume_retry_limit=$((10#$resume_retry_limit))
    fi
    _act_prior_build_attempts() {
        # Use the same admission rule before dispatch and when rereading a
        # checkpoint. Missing or invalid history must not become attempt zero.
        jq -er -s '
            select(length == 1) | .[0] | select(type == "object") |
            def counter($key): if has($key) then .[$key] else 0 end;
            counter("attempts") as $all | counter("source_sync_failures") as $sync |
            counter("host_readiness_failures") as $readiness |
            counter("host_capacity_failures") as $capacity |
            select(($all | type == "number" and floor == . and . >= 0 and . <= 9007199254740991) and
              ($sync | type == "number" and floor == . and . >= 0 and . <= 9007199254740991) and
              ($readiness | type == "number" and floor == . and . >= 0 and . <= 9007199254740991) and
              ($capacity | type == "number" and floor == . and . >= 0 and . <= 9007199254740991) and
              ($sync + $readiness + $capacity) <= $all) |
            $all - $sync - $readiness - $capacity' <<< "$1"
    }
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
    local targets selected_targets_json=""
    if [[ ${#targets_arg[@]} -gt 0 ]]; then
        selected_targets_json=$(printf '%s\0' "${targets_arg[@]}" | jq -Rsc 'split("\u0000")[:-1]') || return 4
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
    if [[ -n "$selected_targets_json" ]]; then
        requested_targets_json="$selected_targets_json"
    else
        requested_targets_json=$(for target in $targets; do printf '%s\n' "$target"; done | \
            jq -Rsc 'split("\n") | map(select(length > 0))') || return 4
    fi
    if ! jq -en --argjson requested "$requested_targets_json" \
        '($requested | length) == ($requested | unique | length)' >/dev/null 2>&1; then
        _log_error "Duplicate build targets are not allowed"
        jq -nc --arg tool "$tool_name" --arg error "Duplicate build targets are not allowed" \
            '{tool: $tool, status: "error", summary: {total: 0, success: 0, failed: 0}, error: $error, targets: []}'
        return 4
    fi

    local target_validation_error
    if ! target_validation_error=$(dsr_platform_validate_targets_json \
        "$requested_targets_json" "build targets for $tool_name" 2>&1); then
        _log_error "$target_validation_error"
        jq -nc --arg tool "$tool_name" --arg error "$target_validation_error" \
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
        if jq -e '.staged_ordinary == true' <<< "$source_sync_json" >/dev/null; then
            local context_sha context_ref
            context_sha=$(jq -r '.git_context.git_sha' <<< "$source_sync_json") || return 4
            context_ref=$(jq -r '.git_context.git_ref | if . == "" then "HEAD" else sub("^refs/heads/";"") end' <<< "$source_sync_json") || return 4
            if [[ -n "$supplied_git_sha" && "$supplied_git_sha" != "$context_sha" ]] ||
               [[ -n "$supplied_git_ref" && "$supplied_git_ref" != "$context_ref" ]]; then
                _log_error "Staged Git context differs from requested build identity"
                return 4
            fi
            supplied_git_sha="$context_sha"
            supplied_git_ref="$context_ref"
        fi
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
                      "$(_act_sha256 "${DSR_HOSTS_FILE:-${DSR_CONFIG_DIR:-$HOME/.config/dsr}/hosts.yaml}")" != \
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
            if ! jq -e '.target_statuses | type == "object"' <<< "$resume_state" >/dev/null; then
                _log_error "Resume target history is not a target-keyed map"
                _act_release_orchestration_lock
                return 4
            fi
            while IFS= read -r resume_entry; do
                if ! _act_prior_build_attempts "$resume_entry" >/dev/null; then
                    _log_error "Invalid source synchronization/readiness/build attempt counters in resume state"
                    _act_release_orchestration_lock
                    return 4
                fi
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
    local coordinator_error=""
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
            local receipt_exit="$worker_status"
            [[ "$receipt_exit" -ne 0 ]] || receipt_exit=6
            finished_result=$(jq -nc --arg target "$finished_platform" --arg host "$host" \
                --argjson exit_code "$receipt_exit" --argjson worker_exit_code "$worker_status" \
                '{platform: $target, host: $host, status: "failed", exit_code: $exit_code,
                  worker_exit_code: $worker_exit_code,
                  error: "Worker result receipt missing or invalid"}')
        fi
        if [[ "$(jq -r '.status // ""' <<< "$finished_result")" == success ]] && \
           ! _act_matrix_result_matches "$finished_result" "$finished_platform" "$finished_triple"; then
            finished_result=$(jq -c '.status = "failed" | .exit_code = 4 |
                .error = "Completed native result has inconsistent variant identity"' <<< "$finished_result") || return 4
        fi
        finished_result=$(jq -c --arg log_path "$log_path" \
            --argjson attempt "$attempt" \
            --arg purpose "$build_purpose" --arg task_key "$finished_target" \
            '. + {log_path: $log_path, attempt: $attempt, execution_started:true,
                  build_purpose: $purpose, publishable: ($purpose == "release"), task_key:$task_key} |
             del(.result_path)' <<< "$finished_result") || return 4
        # The coordinator waited for this registered worker. Retain that fact
        # before any receipt or state write can fail; storage failure must not
        # turn a genuine attempt into an undispatched target at aggregation.
        final_results["$finished_target"]="$finished_result"
        if [[ -f "$result_path" && ! -L "$result_path" ]]; then
            finished_result=$(jq -c --arg result_path "$result_path" \
                '. + {result_path:$result_path}' <<< "$finished_result") || return 4
        elif [[ ! -e "$result_path" && ! -L "$result_path" ]]; then
            # Even a worker killed before installing its traps has a durable
            # outcome. Identify coordinator recovery rather than pretending
            # the child wrote a receipt; never replace existing evidence.
            finished_result=$(jq -c '. + {receipt_source: "coordinator"}' <<< "$finished_result") || return 4
            final_results["$finished_target"]="$finished_result"
            local retained_result
            retained_result=$(jq -c --arg result_path "$result_path" \
                '. + {result_path:$result_path}' <<< "$finished_result") || return 4
            if ! (umask 077; set -o noclobber; printf '%s\n' "$retained_result" > "$result_path"); then
                _log_error "Could not retain missing worker outcome for $finished_target"
                return 4
            fi
            finished_result="$retained_result"
        else
            _log_error "Worker result receipt path is not a regular file: $result_path"
            return 4
        fi
        final_results["$finished_target"]="$finished_result"
        status=$(jq -r '.status // "unknown"' <<< "$finished_result")

        if $state_available; then
            extra=$(jq -nc --arg host "$host" \
                --arg log_path "$log_path" --arg result_path "$result_path" \
                --argjson attempts "$attempt" \
                'input as $result | {result: $result, host: $host, log_path: $log_path,
                  result_path: $result_path, attempts: $attempts}' <<< "$finished_result") || return 4
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
        trap '' INT TERM HUP
        interrupted=true
        local cancel_index cancel_pid
        for ((cancel_index = 0; cancel_index < ${#worker_pids[@]}; cancel_index++)); do
            [[ -z "${worker_reaped[$cancel_index]:-}" ]] || continue
            cancel_pid="${worker_pids[$cancel_index]}"
            kill -TERM "$cancel_pid" 2>/dev/null || true
        done
    }

    _act_fail_coordinator() {
        [[ -n "$coordinator_error" ]] || coordinator_error="$1"
        _log_error "$1"
        interrupted=true
        # Aggregation can discover unreadable queued history after workers
        # were drained and the signal traps restored. Do not reinstall
        # ignored signals in the caller when no owned worker remains.
        if (( active_workers > 0 )); then
            _act_cancel_parallel_workers
        fi
    }

    _act_refuse_retained_target() {
        local message="$1" known_attempt="${2:-}" refusal refusal_stage=dispatch
        $resume_run && refusal_stage=resume
        # A verified observation is stronger than the failure to persist it.
        # Otherwise return only this coordinator's refusal, without borrowing
        # unverified result paths or inventing an unknown attempt history.
        if [[ -z "${final_results[$task_key]:-}" ]]; then
            if refusal=$(jq -nc --arg target "$target" --arg task_key "$task_key" \
                    --arg triple "$selected_triple" --arg purpose "$build_purpose" \
                    --arg error "$message" --arg attempt "$known_attempt" --arg stage "$refusal_stage" '
                    {platform:$target, task_key:$task_key, status:"failed", exit_code:4,
                     stage:$stage, receipt_source:"coordinator", execution_started:false,
                     error:$error, build_purpose:$purpose, publishable:($purpose == "release")} +
                    (if $triple == "" then {} else {target_triple:$triple} end) +
                    (if $attempt == "" then {} else {attempt:($attempt | tonumber)} end)'); then
                final_results["$task_key"]="$refusal"
            fi
        fi
        _act_fail_coordinator "$message"
    }

    _act_refuse_unstarted_attempt() {
        local message="$1" reserved="$2" refusal refusal_with_path refusal_extra
        local refusal_attempt="$prior_attempts" refusal_status=skipped
        [[ -n "$coordinator_error" ]] || coordinator_error="$message"
        _log_error "$message"
        if $reserved; then
            refusal_attempt="$attempt"
            refusal_status=failed
        fi
        if refusal=$(jq -nc --arg target "$target" --arg task_key "$task_key" \
                --arg triple "$selected_triple" --arg host "$host" \
                --arg purpose "$build_purpose" --arg status "$refusal_status" \
                --arg error "$message" --argjson attempt "$refusal_attempt" \
                '{platform:$target, task_key:$task_key, host:$host, status:$status,
                  exit_code:4, stage:"dispatch", execution_started:false, error:$error,
                  attempt:$attempt, build_purpose:$purpose, publishable:($purpose == "release")} +
                 (if $triple == "" then {} else {target_triple:$triple} end)'); then
            # A failed reservation has no durable attempt identity. Do not
            # create orphan receipts that would obstruct its first retry.
            if $reserved; then
                refusal_with_path=$(jq -c --arg path "$result_path" \
                    '. + {result_path:$path, receipt_source:"coordinator"}' <<< "$refusal")
                if [[ -n "$refusal_with_path" ]] &&
                   (umask 077; set -o noclobber; printf '%s\n' "$refusal_with_path" > "$result_path"); then
                    refusal="$refusal_with_path"
                fi
                if $state_available; then
                    refusal_extra=$(jq -nc --argjson attempts "$attempt" \
                        'input as $result | {result:$result, attempts:$attempts,
                         log_path:null, result_path:($result.result_path // null)}' <<< "$refusal") &&
                        build_state_update_target "$tool_name" "$version" "$task_key" \
                            failed "$refusal_extra" "$run_id" ||
                        _log_error "Could not persist dispatch refusal for $task_key"
                fi
            fi
            final_results["$task_key"]="$refusal"
        fi
        # A coordinator persistence failure must not leave previously started
        # targets running after dispatch stops. Their own traps retain actual
        # interrupted attempts; the coordinator failure remains exit 4.
        _act_cancel_parallel_workers
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
                    if ! _act_record_worker_result "$reap_index" "$worker_status"; then
                        # Completion persistence is a coordinator failure,
                        # not an operator interruption. Keep the first cause
                        # while cancelling and draining all remaining peers.
                        _act_fail_coordinator "Could not retain completed target outcome for ${worker_targets[$reap_index]}"
                    fi
                    return 0
                fi
            done
            sleep 0.05
        done
        return 1
    }
    trap _act_cancel_parallel_workers INT TERM HUP

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
            if ! persisted_entry=$(build_state_get "$tool_name" "$version" "$run_id" | \
                    jq -ce --arg target "$task_key" '.target_statuses[$target] // {}') ||
               ! prior_build_attempts=$(_act_prior_build_attempts "$persisted_entry"); then
                _act_refuse_retained_target "Invalid or unavailable source synchronization/readiness/capacity/build attempt counters for $task_key"
                break
            fi
            prior_attempts=$(jq -r '.attempts // 0' <<< "$persisted_entry")
            persisted_result=$(jq -c '.result // empty' <<< "$persisted_entry")
            persisted_result_path=$(jq -r '.result_path // empty' <<< "$persisted_entry")
        fi

        if $resume_run; then
            if [[ -n "$persisted_result" ]] && \
               ! _act_build_purpose_matches "$persisted_result" "$build_purpose" "$strict_release_contract"; then
                _act_refuse_retained_target "Resume target result has missing or different build purpose: $target" "$prior_attempts"
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
            local recovered_result="" recovered_status=""
            if [[ -n "$persisted_result_path" && -s "$persisted_result_path" ]] &&
               recovered_result=$(jq -ce '.' "$persisted_result_path" 2>/dev/null); then
                if ! _act_build_purpose_matches "$recovered_result" "$build_purpose" "$strict_release_contract"; then
                    _act_refuse_retained_target "Resume sidecar has missing or different build purpose: $target" "$prior_attempts"
                    break
                fi
                if _act_matrix_result_matches "$recovered_result" "$target" "$selected_triple" &&
                   [[ "$(jq -r '.task_key // ""' <<< "$recovered_result")" == "$task_key" ]] &&
                   _act_target_result_available "$recovered_result" "$build_purpose" "$strict_release_contract"; then
                    recovered_status=completed
                elif jq -e --arg task_key "$task_key" --arg platform "$target" \
                        --arg triple "$selected_triple" '
                        .task_key == $task_key and .platform == $platform and
                        ($triple == "" or .target_triple == $triple) and
                        ((.status // "") | IN("failed", "error", "timeout", "cancelled"))
                    ' <<< "$recovered_result" >/dev/null; then
                    # Early failures may precede backend selection, so unlike
                    # successful reuse their identity does not require method.
                    recovered_status=failed
                fi
                if [[ -n "$recovered_status" ]]; then
                    # The immutable sidecar is written before the coordinator
                    # records completion. Its attempt identity comes from the
                    # retained dispatch entry, not fields supplied by a worker.
                    local recovered_log_path
                    recovered_log_path=$(jq -r '.log_path // empty' <<< "$persisted_entry")
                    [[ -f "$recovered_log_path" && ! -L "$recovered_log_path" ]] || recovered_log_path=""
                    recovered_result=$(jq -c \
                        --arg log_path "$recovered_log_path" \
                        --arg result_path "$persisted_result_path" --argjson attempt "$prior_attempts" \
                        --arg status "$recovered_status" '
                        . + {result_path: $result_path, attempt: $attempt} |
                        if $log_path == "" then del(.log_path) else .log_path = $log_path end |
                        if $status == "completed" then
                            . + {resume_reused: true} |
                            if has("execution_started") then . else .execution_started = true end
                        else . end
                    ' <<< "$recovered_result") || {
                        _act_refuse_retained_target "Could not retain recovered target observation for $task_key" "$prior_attempts"
                        break
                    }
                    # Keep this verified sidecar even if checkpointing it
                    # fails. Recovery did not launch another target attempt.
                    final_results["$task_key"]="$recovered_result"
                    if $state_available; then
                        local reconciled_extra
                        if ! reconciled_extra=$(jq -nc --argjson attempts "$prior_attempts" \
                                'input as $result | {result: $result, attempts: $attempts,
                                 reconciled_from_sidecar: true}' <<< "$recovered_result") ||
                           ! build_state_update_target "$tool_name" "$version" "$task_key" "$recovered_status" \
                                "$reconciled_extra" "$run_id"; then
                            _act_refuse_retained_target "Could not persist recovered target outcome for $task_key" "$prior_attempts"
                            break
                        fi
                    fi
                    persisted_result="$recovered_result"
                    if [[ "$recovered_status" == completed ]]; then
                        final_results["$task_key"]="$recovered_result"
                        _log_info "Resume: reconciled completed sidecar for $task_key"
                        continue
                    fi
                    # Reconciliation accounts for source-sync and readiness
                    # refusals once. Reread those authoritative discounts
                    # before applying the compiler budget on every resume.
                    if $state_available; then
                        if ! persisted_entry=$(build_state_get "$tool_name" "$version" "$run_id" | \
                                jq -ce --arg target "$task_key" '.target_statuses[$target] // {}') ||
                           ! prior_build_attempts=$(_act_prior_build_attempts "$persisted_entry"); then
                            _act_refuse_retained_target "Invalid or unavailable reconciled attempt counters for $task_key" "$prior_attempts"
                            break
                        fi
                    fi
                fi
            fi
            if [[ "$prior_build_attempts" -ge "$resume_retry_limit" ]]; then
                local exhausted_result exhausted_extra
                if [[ -n "$persisted_result" ]] &&
                   jq -e --arg task_key "$task_key" --arg platform "$target" \
                        --arg triple "$selected_triple" '
                        .task_key == $task_key and .platform == $platform and
                        ($triple == "" or .target_triple == $triple) and
                        ((.status // "") | IN("failed", "error", "timeout", "cancelled"))
                    ' <<< "$persisted_result" >/dev/null; then
                    # Keep an observed failure's exit and error. Exhaustion is
                    # a scheduling decision, not another worker execution.
                    exhausted_result="$persisted_result"
                else
                    # A lost worker or unavailable successful artifacts cannot
                    # become success merely because the budget is exhausted.
                    # Do not invent a worker exit or rewrite its old sidecar.
                    exhausted_result=$(jq -nc --arg platform "$target" \
                        --arg host "$(jq -r '.host // empty' <<< "$persisted_entry")" \
                        --arg triple "$selected_triple" '
                        {platform: $platform, host: $host, status: "failed", exit_code: 6,
                         stage: "resume", receipt_source: "coordinator",
                         error: "Target retry limit exceeded without a reusable target result"} +
                        (if $triple == "" then {} else {target_triple: $triple} end)
                    ') || {
                        _act_refuse_retained_target "Could not retain retry-budget refusal for $task_key" "$prior_attempts"
                        break
                    }
                fi
                local exhausted_result_path="" exhausted_log_path=""
                # A path that merely exists is not an admitted receipt. Empty
                # or wrong-target sidecars cannot acquire authority at exhaustion.
                if [[ -n "$recovered_status" && -f "$persisted_result_path" && ! -L "$persisted_result_path" ]]; then
                    exhausted_result_path="$persisted_result_path"
                fi
                exhausted_log_path=$(jq -r '.log_path // empty' <<< "$persisted_entry")
                [[ -f "$exhausted_log_path" && ! -L "$exhausted_log_path" ]] || exhausted_log_path=""
                exhausted_result=$(jq -c \
                    --arg log_path "$exhausted_log_path" \
                    --arg result_path "$exhausted_result_path" --argjson attempt "$prior_attempts" \
                    --arg purpose "$build_purpose" --arg task_key "$task_key" '
                    . + {attempt: $attempt,
                         build_purpose: $purpose, publishable: ($purpose == "release"),
                         task_key: $task_key, retry_limit_exceeded: true} |
                    if $log_path == "" then del(.log_path) else .log_path = $log_path end |
                    if $result_path == "" then del(.result_path) else .result_path = $result_path end
                ' <<< "$exhausted_result") || {
                    _act_refuse_retained_target "Could not retain retry-budget outcome for $task_key" "$prior_attempts"
                    break
                }
                final_results["$task_key"]="$exhausted_result"
                if $state_available; then
                    if ! exhausted_extra=$(jq -nc --argjson attempts "$prior_attempts" \
                            'input as $result | {result: $result, attempts: $attempts}' \
                            <<< "$exhausted_result") ||
                       ! build_state_update_target "$tool_name" "$version" "$task_key" failed \
                            "$exhausted_extra" "$run_id"; then
                        _act_refuse_retained_target "Could not persist retry-budget outcome for $task_key" "$prior_attempts"
                        break
                    fi
                fi
                final_results["$task_key"]="$exhausted_result"
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
            _act_fail_coordinator "Refusing to overwrite an existing target attempt receipt"
            break
        fi
        host="act-local"
        if $strict_release_contract; then
            host=$(jq -er --arg target "$target" '.[$target]' <<< "$target_hosts_json") || {
                _act_refuse_retained_target "Strict target host binding became unavailable for $task_key" "$prior_attempts"
                break
            }
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
                <<< "$source_sync_json") || {
                _act_refuse_retained_target "Source synchronization receipt became unavailable for $task_key" "$prior_attempts"
                break
            }
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

        # Do not reserve an attempt while waiting on another target's output.
        # Cancellation there must leave queued tasks at zero attempts, without
        # an empty immutable log that would prevent the next resume.
        $interrupted && break
        local attempt_reserved=false
        # Commit the attempt identity before creating any immutable receipt.
        # If persistence fails, exact-run resume must still be able to start
        # this attempt; after a crash, a saved reservation advances its number.
        if $state_available; then
            if ! build_state_update_target "$tool_name" "$version" "$task_key" "running" \
                "$(jq -nc --arg host "$host" --arg log_path "$log_path" \
                    --arg result_path "$result_path" --argjson attempts "$attempt" \
                    '{host: $host, log_path: $log_path, result_path: $result_path,
                      attempts: $attempts, result: null}')" "$run_id"; then
                $interrupted && break
                _act_refuse_unstarted_attempt "Could not persist target attempt reservation; worker was not started: $task_key" false
                break
            fi
            attempt_reserved=true
            # A new durable reservation supersedes the earlier failed
            # observation, even if cancellation arrives before its worker
            # starts. The immutable prior sidecar remains retained on disk.
            unset 'final_results[$task_key]'
            if ! build_state_update_host "$tool_name" "$version" "$host" "running" \
                    "$(jq -nc --arg target "$target" '{target: $target}')" "$run_id"; then
                $interrupted && break
                _act_refuse_unstarted_attempt "Could not persist host running state; worker was not started: $task_key" true
                break
            fi
        fi
        $interrupted && break
        if ! (umask 077; set -o noclobber; : > "$log_path"); then
            $interrupted && break
            _act_refuse_unstarted_attempt "Could not create immutable target log; worker was not started: $task_key" "$attempt_reserved"
            break
        fi

        # Only this loop may read the remaining JSON task records. Isolate the
        # whole worker, including capacity selection and all descendants, so
        # an stdin-reading build or transport cannot silently eat queued tasks.
        DSR_NATIVE_OUTPUT_STAGE="$output_stage" \
        _act_run_target_worker "$tool_name" "$version" "$run_id" "$target" "$attempt" \
            "$log_path" "$result_path" "$strict_release_contract" \
            "$release_contract_json" "$source_roots_json" "$git_sha" "$git_ref" "$host" "$build_purpose" \
            "$selected_triple" "$task_key" "$target_sync_receipt" </dev/null &
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

        # Cancellation may arrive while the new worker is being registered.
        # Include that worker in cleanup once its PID and receipts are known.
        if $interrupted; then
            _act_cancel_parallel_workers
            break
        fi

        if (( active_workers >= parallel_jobs )); then
            _act_reap_one_worker || interrupted=true
            $interrupted && break
        fi
    done < <(jq -c '.[]' <<< "$build_tasks_json")

    while (( active_workers > 0 )); do
        _act_reap_one_worker || interrupted=true
    done
    trap - INT TERM HUP

    # Deterministic aggregation follows configured target order, never worker
    # completion order.
    while IFS= read -r task_json; do
        target=$(jq -r '.platform' <<< "$task_json")
        task_key=$(jq -r '.key' <<< "$task_json")
        selected_triple=""
        [[ "$task_key" == "$target" ]] || selected_triple=$(jq -r '.target_triple' <<< "$task_json")
        local ordered_result="${final_results[$task_key]:-}" undispatched_attempts=0
        if [[ -z "$ordered_result" && $state_available == true ]]; then
            local ordered_entry
            if ! ordered_entry=$(build_state_get "$tool_name" "$version" "$run_id" | \
                    jq -ce --arg task_key "$task_key" '.target_statuses[$task_key] // {}') ||
               ! _act_prior_build_attempts "$ordered_entry" >/dev/null; then
                _act_refuse_retained_target "Invalid or unavailable retained attempt history for $task_key"
                ordered_result="${final_results[$task_key]:-}"
            else
                ordered_result=$(jq -c '.result // empty' <<< "$ordered_entry") || return 4
                undispatched_attempts=$(jq -r '.attempts // 0' <<< "$ordered_entry") || return 4
            fi
        fi
        if [[ -z "$ordered_result" ]]; then
            # No worker result means this invocation never dispatched this
            # task. Do not invent a failed build or an execution receipt.
            local dispatch_exit=6 dispatch_error="Target was not dispatched"
            if [[ -n "$coordinator_error" ]]; then
                dispatch_exit=4
                dispatch_error="Dispatch stopped before this target started: $coordinator_error"
            elif $interrupted; then
                dispatch_exit=130
                dispatch_error="Interrupted before target dispatch"
            else
                _log_error "No worker was dispatched for requested task $task_key"
            fi
            ordered_result=$(jq -nc --arg target "$target" \
                --argjson exit_code "$dispatch_exit" --arg error "$dispatch_error" \
                --argjson attempt "$undispatched_attempts" \
                '{platform: $target, status: "skipped", attempt: $attempt,
                  exit_code: $exit_code, stage:"dispatch", execution_started:false,
                  error: $error}')
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
    if [[ -n "$coordinator_error" ]]; then
        overall_status="failed"
        overall_exit_code=4
    elif $interrupted; then
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
        results_json=$(printf '%s\n' "${results[@]}" | jq -s '.') || return 4
    fi

    local summary_json
    summary_json=$(jq -nc \
        --arg tool "$tool_name" \
        --arg version "$version" \
        --arg run_id "$run_id" \
        --arg git_sha "$git_sha" \
        --arg git_ref "$git_ref" \
        --argjson source_dependencies "$source_dependencies_json" \
        --arg status "$overall_status" \
        --arg error "$coordinator_error" \
        --argjson exit_code "$overall_exit_code" \
        --argjson duration "$total_duration" \
        --argjson total "$((success_count + fail_count))" \
        --argjson success "$success_count" \
        --argjson failed "$fail_count" \
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
            }
        } + (if $error == "" then {} else {error:$error} end)') || return 4
    _act_bind_orchestration_targets "$summary_json" "$results_json" || return 4

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

# New strict variant contracts cannot use the legacy manifest fallback. Each
# selected compiler target needs its own native execution and source context,
# and exactly one corresponding primary. Singleton contracts retain their
# existing manifest compatibility.
_act_validate_contract_variant_inventory() {
    local tool="$1" manifest="$2" contract="$3" identities
    identities=$(_act_contract_target_rows "$tool" "$contract") || return 4
    if ! jq -e 'any(.[]; .require_triple == true)' <<< "$identities" >/dev/null; then
        return 0
    fi
    if ! jq -e --argjson identities "$identities" '
        . as $manifest |
        ($manifest.build_environments // null) as $environments |
        ($manifest.artifacts // []) as $artifacts |
        ($manifest.requested_targets | type == "array" and
            length == (unique | length) and
            (sort == ($identities | map(.platform) | unique | sort))) and
        ($environments | type == "array" and length == ($identities | length)) and
        all($identities[];
            . as $wanted |
            [$environments[] | select(.target == $wanted.platform and
                .target_triple == $wanted.target_triple)] as $matches |
            [$artifacts[] | select(.target == $wanted.platform and
                .target_triple == $wanted.target_triple)] as $primaries |
            ($matches | length) == 1 and ($primaries | length) == 1 and
            ($matches[0] | .method == "native" and
                (.host | type == "string" and length > 0) and
                .target_triple == $wanted.target_triple and
                .build_influence_env.CARGO_BUILD_TARGET == $wanted.target_triple and
                .build_influence_env.DSR_TARGET_TRIPLE == $wanted.target_triple and
                .build_influence_env.DSR_RELEASE_GIT_SHA == $manifest.source.git_sha and
                .build_influence_env.DSR_RELEASE_GIT_REF == $manifest.source.git_ref and
                .cargo_isolation.mode == "strict-release-snapshot" and
                .cargo_isolation.toolchain.target_triple == $wanted.target_triple))
    ' <<< "$manifest" >/dev/null 2>&1; then
        _log_error "Strict variant manifest lacks exact native compiler/source receipts"
        return 4
    fi
    _act_validate_native_manifest_inventory "$tool" "$manifest"
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
        # shellcheck source=SCRIPTDIR/artifact_naming.sh
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
        requested_targets=$(jq -c '.requested_targets // ([.targets[].platform] | unique)' <<< "$result_json") || return 4
    fi
    contract_json=$(_act_contract_for_build_purpose "$tool" "$contract_json" \
        "$requested_targets" "$build_purpose") || return 4
    local contract_targets_json
    contract_targets_json=$(_act_contract_target_rows "$tool" "$contract_json") || return 4
    if jq -e 'any(.[]; .require_triple == true)' <<< "$contract_targets_json" >/dev/null && \
       ! jq -e 'has("requested_targets")' <<< "$result_json" >/dev/null; then
        _log_error "Strict variant results require their original requested platform inventory"
        return 4
    fi

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

    if ! jq -e --argjson expected "$contract_targets_json" '
        .targets as $results |
        .status == "success" and
        (.summary | type == "object") and
        .summary.total == ($expected | length) and
        .summary.success == ($expected | length) and
        .summary.failed == 0 and
        (.targets | type == "array") and
        (.targets | length) == ($expected | length) and
        all($expected[];
            . as $wanted |
            [$results[] | select(.platform == $wanted.platform and
                (($wanted.require_triple | not) or .target_triple == $wanted.target_triple))] as $matches |
            ($matches | length) == 1 and
            (if $wanted.require_triple then
                $matches[0].task_key == $wanted.key and $matches[0].method == "native"
             else true end)) and
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
    _act_validate_native_matrix_result_inventory "$tool" "$result_json" || return 4

    local verified_additional
    verified_additional=$(_act_additional_artifact_receipts_json "$tool" "$result_json") || return 4

    if ! jq -e '
        .checksum_sidecar == "sha256" and
        (.exact_primary_assets | type == "object") and
        ([.exact_primary_assets[]] | length) == ([.exact_primary_assets[]] | unique | length)
    ' <<< "$contract_json" >/dev/null 2>&1; then
        _log_error "Release contract primary asset mapping is invalid"
        return 4
    fi

    local artifacts=()
    local target expected_name expected_input_name format contract_row contract_key contract_triple
    local _ACT_STRICT_TARGET_TRIPLE=""
    local target_json artifact_path artifact_dir
    local frozen_sha frozen_size frozen_identity
    while IFS= read -r contract_row; do
        contract_key=$(jq -er '.key' <<< "$contract_row") || return 4
        target=$(jq -er '.platform' <<< "$contract_row") || return 4
        contract_triple=$(jq -er '.target_triple // "" | strings' <<< "$contract_row") || return 4
        target_json=$(jq -c --arg target "$target" --arg key "$contract_key" \
            --arg triple "$contract_triple" --argjson row "$contract_row" '
            .targets[] | select(.platform == $target and
                (($row.require_triple | not) or .target_triple == $triple))' <<< "$result_json") || return 4
        _ACT_STRICT_TARGET_TRIPLE=$(_act_native_result_target_triple "$tool" "$target_json") || return 4
        workspace_binaries=$(_act_workspace_binaries_for_target "$config_file" "$target") || return 4
        expected_name=$(jq -r --arg target "$contract_key" '.exact_primary_assets[$target]' <<< "$contract_json")
        if ! _act_is_safe_basename "$expected_name"; then
            _log_error "Unsafe release asset basename for $target: $expected_name"
            return 4
        fi
        expected_input_name="$binary_name"
        [[ "$target" == windows/* ]] && expected_input_name="${binary_name%.exe}.exe"
        format=$(_act_archive_format "$expected_name")

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
                primary_count=$((primary_count + 1))
            elif [[ "$candidate_name" == "${expected_name}.sha256" ]]; then
                sidecar_count=$((sidecar_count + 1))
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
            --arg target_triple "$_ACT_STRICT_TARGET_TRIPLE" \
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
            } + (if $target_triple == "" then {} else {target_triple: $target_triple} end)'); then
            _log_error "Failed to serialize release artifact metadata for $target"
            return 4
        fi
        artifacts+=("$artifact_json")
    done < <(jq -c '.[]' <<< "$contract_targets_json")

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
        if ! jq -e --arg path "$additional_path" --arg name "$additional_name" \
            '.[$path].name == $name' <<< "$verified_additional" >/dev/null; then
            _log_error "Additional artifact has no configured and validated producer: $additional_name"
            return 4
        fi
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
        [[ -f "$additional_path" && ! -L "$additional_path" &&
           "$additional_identity_after" == "$additional_identity_before" &&
           "$(_act_sha256 "$additional_path")" == "$additional_sha" &&
           "$(_act_file_size "$additional_path")" == "$additional_size" ]] || return 4
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
        --argjson artifacts "$artifacts_json" \
        --arg purpose "$build_purpose" \
        --argjson requested_targets "$requested_targets" \
        'input as $build_environments | {
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
        }' <<< "$build_environments_json"); then
        _log_error "Failed to serialize release manifest"
        return 4
    fi

    if ! jq -e --argjson contract "$contract_json" --argjson identities "$contract_targets_json" \
        --argjson base_additional "$base_additional_json" '
        (.artifacts | length) ==
            (($contract.exact_primary_assets | length) + ($base_additional | length)) and
        ([.artifacts[] | select(.target != "additional") | . as $artifact |
          $identities[] | select(.platform == $artifact.target and
            ((.require_triple | not) or .target_triple == $artifact.target_triple)) |
          {key: .key, value: $artifact.name}] | from_entries) ==
            $contract.exact_primary_assets and
        ([.artifacts[] | select(.target == "additional") | .name] | sort) ==
            $base_additional and
        ([.artifacts[].name] | length) ==
            ([.artifacts[].name] | unique | length)
    ' <<< "$manifest" >/dev/null 2>&1; then
        _log_error "Final manifest does not match the release contract"
        return 4
    fi
    _act_validate_contract_variant_inventory "$tool" "$manifest" "$contract_json" || return 4

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
_act_verify_collected_manifest() {
    [[ $# -eq 2 || ( $# -eq 3 && "$3" == --collected ) ]] || return 4
    local manifest="$1" directory="$2" name sha size path
    jq -e '.artifacts | length > 0 and
        (map(.name) | length == (unique | length)) and
        all(.[]; (.name | type == "string" and
            test("^[A-Za-z0-9][A-Za-z0-9._+-]*$")))' "$manifest" >/dev/null || return 4
    while IFS=$'\t' read -r name sha size; do
        path="$directory/$name"
        if [[ ! -f "$path" || -L "$path" ]] ||
           [[ "$(_act_sha256 "$path")" != "$sha" || "$(_act_file_size "$path")" != "$size" ]]; then
            _log_error "Final collected artifact disagrees with manifest: $name"
            return 4
        fi
    done < <(jq -r '.artifacts[] | [.name,.sha256,(.size_bytes|tostring)] | @tsv' "$manifest")

    # CLI collection owns this NUL-framed inventory. Paths found in a manifest
    # cannot declare their own completeness: every actual collected payload
    # must survive naming and packaging as a manifest row. Share the existing
    # CLI coverage gate with direct final-admission callers and regression tests.
    if [[ "${3:-}" == --collected ]]; then
        local -a collected=()
        local collected_json
        name=""
        while IFS= read -r -d '' name; do
            [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || return 4
            case "$name" in
                *.minisig|*.sig|*.sha256|*.sha512|SHA256SUMS*|*.sbom.*|*.intoto.jsonl) ;;
                *) collected+=("$name") ;;
            esac
        done
        [[ -z "$name" ]] || return 4
        if [[ ${#collected[@]} -gt 0 ]]; then
            collected_json=$(printf '%s\n' "${collected[@]}" | jq -Rsc 'split("\n")[:-1]') || return 4
            jq -e --argjson collected "$collected_json" '
                (.artifacts | map(.name)) as $names |
                all($collected[]; . as $name | $names | index($name) != null)
            ' "$manifest" >/dev/null || {
                _log_error "Collected artifact is absent from final manifest"
                return 4
            }
        fi
    fi
    return 0
}

act_generate_manifest() {
    local result_json="$1"
    local output_file="$2"
    local collection_names="${3-}"
    [[ -n "$collection_names" ]] || collection_names='{}'
    jq -e 'type == "object" and all(.[]; type == "string")' <<< "$collection_names" >/dev/null || return 4

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
        # shellcheck source=SCRIPTDIR/config.sh
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
    local verified_additional verified_workflow_files workflow_plans
    verified_additional=$(_act_additional_artifact_receipts_json "$tool" "$result_json") || return 4
    workflow_plans=$(_act_workflow_payload_plans_json "$tool" "$version") || return 4
    verified_workflow_files=$(jq -c --argjson plans "$workflow_plans" '[.targets[] |
        select(.method == "act" and $plans[.platform] != null and
               (.status == "success" or .status == "ok" or .status == "passed")) |
        .platform as $target | .artifact_paths[] | {key:.,value:$target}] | from_entries' <<< "$result_json") || return 4
    if ! declare -F artifact_naming_artifact_variant &>/dev/null; then
        # shellcheck source=SCRIPTDIR/artifact_naming.sh
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
            *freebsd*)       os="freebsd" ;;
            *windows*|*.exe) os="windows" ;;
        esac
        case "$nm" in
            *_aarch64*|*-aarch64*|*_arm64*|*-arm64*) arch="arm64" ;;
            *_x86_64*|*-x86_64*|*_amd64*|*-amd64*)   arch="amd64" ;;
            *_armv7*|*-armv7*) arch="armv7" ;;
            *_386*|*-386*|*_i686*|*-i686*) arch="386" ;;
        esac
        dsr_platform_is_supported "$os/$arch" && printf '%s/%s\n' "$os" "$arch"
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
            _log_error "Declared artifact is missing: $file"
            return 4
        fi
        [[ -z "$target" ]] && return 0

        local name additional_receipt literal_additional=false authoritative_workflow=false
        name=$(basename "$file")
        additional_receipt=$(jq -c --arg path "$file" '.[$path] // null' <<< "$verified_additional") || return 4
        if [[ "$additional_receipt" != null ]]; then
            literal_additional=true
            [[ "$name" == "$(jq -r '.name' <<< "$additional_receipt")" &&
               "$target" == "$(jq -r '.target' <<< "$additional_receipt")" ]] || return 4
        fi
        if jq -e --arg path "$file" 'has($path)' <<< "$verified_workflow_files" >/dev/null; then
            authoritative_workflow=true
            [[ "$(jq -r --arg path "$file" '.[$path]' <<< "$verified_workflow_files")" == "$target" ]] || return 4
        fi

        case "$name" in
            *.minisig|*.sig|*.sha256|*.sha512|SHA256SUMS*|*.sbom.*|*.intoto.jsonl)
                return 0
                ;;
        esac
        if [[ "$native_result" == true ]]; then
            [[ ! -L "$file" ]] || return 4
            if ! $literal_additional; then
                name=$(_act_native_variant_artifact_name "$tool" "$target" "$declared_triple" "$name") || return 4
            fi
            if [[ -n "${seen_native_paths[$file]:-}" && \
                  "${seen_native_paths[$file]}" != "$target|$declared_triple" ]]; then
                _log_error "Native artifact path is shared by distinct variants: $file"
                return 4
            fi
            seen_native_paths["$file"]="$target|$declared_triple"
        fi
        local collected_name
        collected_name=$(jq -r --arg key "$target||$declared_triple||$name" '.[$key] // empty' <<< "$collection_names") || return 4
        if [[ -n "$collected_name" ]]; then
            _act_is_safe_basename "$collected_name" || return 4
            if $literal_additional && [[ "$collected_name" != "$name" ]]; then
                _log_error "Additional artifact collection changed its configured literal name: $name"
                return 4
            fi
            name="$collected_name"
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

        local sha size format
        sha=$(_act_sha256 "$file" 2>/dev/null || echo "")
        size=$(_act_file_size "$file")
        format=$(_act_archive_format "$name")

        if [[ -z "$sha" ]]; then
            _log_warn "Unable to compute SHA256 for artifact: $file"
            return 4
        fi
        if [[ -z "$size" || "$size" -le 0 ]]; then
            _log_warn "Unable to determine size for artifact: $file"
            return 4
        fi
        if $literal_additional; then
            if [[ -L "$file" || "$sha" != "$(jq -r '.sha256' <<< "$additional_receipt")" ||
                  "$size" != "$(jq -r '.size_bytes' <<< "$additional_receipt")" ||
                  "$(_act_file_identity "$file")" != "$(jq -r '.identity' <<< "$additional_receipt")" ]]; then
                _log_error "Additional artifact changed after format validation: $file"
                return 4
            fi
        fi
        if [[ -n "${seen_names[$name]:-}" ]]; then
            if $literal_additional || jq -e --arg name "$name" \
                'any(.[]; .name == $name)' <<< "$verified_additional" >/dev/null; then
                _log_error "Additional artifact shares a release name with another payload: $name"
                return 4
            fi
            if [[ "${seen_names[$name]}" != "$sha" ]]; then
                _log_error "Artifacts have the same release name and different bytes: $name"
                return 4
            fi
            return 0
        fi

        # If the filename embeds a recognizable platform suffix, trust it
        # over the orchestration-step target — the latter is unreliable when
        # matrix workflows produce cross-platform artifacts under a single
        # act job.
        local inferred_target
        inferred_target=""
        if ! $literal_additional && ! $authoritative_workflow; then
            inferred_target=$(_act_infer_target_from_name "$name")
        fi
        if [[ "$native_result" == true && -n "$inferred_target" && "$inferred_target" != "$target" ]]; then
            _log_error "Native artifact platform contradicts its worker result: $name ($target)"
            return 4
        elif [[ -n "$inferred_target" ]]; then
            target="$inferred_target"
        fi
        local target_triple
        if [[ "$native_result" == true && -n "$declared_triple" ]]; then
            target_triple="$declared_triple"
        elif $literal_additional || $authoritative_workflow; then
            target_triple=$(_act_manifest_target_triple "$target" "") || return 4
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

    _act_manifest_add_zip_entries() {
        local zip_file="$1"
        local target="$2"
        local payloads file
        payloads=$(_act_artifact_zip_payloads "$zip_file" "$manifest_version") || return 4
        while IFS= read -r -d '' file; do
            # The ordinary file path already preserves compiler variants,
            # infers matrix targets and rejects same-name different bytes.
            _act_manifest_add_file "$file" "$target" || return $?
        done < <(jq -j '.[] | ., "\u0000"' <<< "$payloads")
    }

    while IFS= read -r target_json; do
        [[ -z "$target_json" ]] && continue
        if jq -e 'has("resume_artifacts")' <<< "$target_json" >/dev/null &&
           ! _act_target_result_available "$target_json"; then
            _log_error "Worker artifact inventory changed before manifest generation"
            return 4
        fi
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
            ((if $count > 0 then .artifact_paths[] else
                (.artifact_path // "" | split(",")[]) end),
             ((.additional_artifacts // [])[]? | .path // "")) | ., "\u0000"
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
    requested_targets_json=$(jq -c --arg platform_pattern "$(dsr_platform_pattern)" '
        .requested_targets // null |
        if . == null or (type == "array" and all(.[];
            type == "string" and (test("[\u0000-\u001f\u007f]") | not) and test($platform_pattern)))
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
        --argjson requested_targets "$requested_targets_json" \
        --argjson artifacts "$artifacts_json" \
        'input as $build_environments | {
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
        } + (if $requested_targets == null then {} else {requested_targets: $requested_targets} end)' \
            <<< "$build_environments_json") || {
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
export -f _act_native_host_capability
export -f act_list_tools act_build_matrix
export -f act_get_build_cmd act_substitute_build_cmd_tokens act_get_build_env act_get_repo act_get_local_path
export -f _act_materialized_source_path
export -f act_get_build_env_value act_get_remote_artifact_path
export -f act_run_native_build act_orchestrate_build act_generate_manifest
export -f _act_result_artifact_receipts _act_target_result_available
export -f _act_build_orchestration_target _act_run_target_worker
export -f act_sync_sources
