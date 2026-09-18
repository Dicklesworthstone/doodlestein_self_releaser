#!/usr/bin/env bash
# checksum_sync.sh - Sync checksums to downstream flywheel repos
#
# bd-1jt.3.5: Implement checksum auto-sync across flywheel repos
#
# Usage:
#   source checksum_sync.sh
#   checksum_sync <tool> <version>   # Sync checksums after release
#
# This module updates checksum manifests in downstream repos when installers
# change. It always works in /tmp to avoid modifying /data/projects.

set -uo pipefail

# ============================================================================
# Configuration
# ============================================================================

# Never modify these directories
CHECKSUM_SYNC_PROTECTED_PATHS=("/data/projects" "$HOME/projects")

# Colors for output (if not disabled)
if [[ -z "${NO_COLOR:-}" && -t 2 ]]; then
    _CS_RED=$'\033[0;31m'
    _CS_GREEN=$'\033[0;32m'
    _CS_YELLOW=$'\033[0;33m'
    _CS_BLUE=$'\033[0;34m'
    _CS_NC=$'\033[0m'
else
    _CS_RED='' _CS_GREEN='' _CS_YELLOW='' _CS_BLUE='' _CS_NC=''
fi

_cs_log_info()  { echo "${_CS_BLUE}[checksum-sync]${_CS_NC} $*" >&2; }
_cs_log_ok()    { echo "${_CS_GREEN}[checksum-sync]${_CS_NC} $*" >&2; }
_cs_log_warn()  { echo "${_CS_YELLOW}[checksum-sync]${_CS_NC} $*" >&2; }
_cs_log_error() { echo "${_CS_RED}[checksum-sync]${_CS_NC} $*" >&2; }
_cs_log_debug() { [[ "${CS_DEBUG:-}" == "1" ]] && echo "${_CS_BLUE}[checksum-sync:debug]${_CS_NC} $*" >&2 || true; }

# ============================================================================
# Safety Checks
# ============================================================================

# Normalize a path without relying on realpath (resolves ., .., and //)
# Duplicated from guardrails.sh for standalone use
_cs_normalize_path() {
    local path="$1"
    local is_abs=false
    [[ "$path" == /* ]] && is_abs=true

    local IFS='/'
    local -a parts=()
    read -r -a parts <<< "$path"

    local -a stack=()
    local part
    for part in "${parts[@]}"; do
        case "$part" in
            ""|".")
                continue
                ;;
            "..")
                if [[ ${#stack[@]} -gt 0 ]]; then
                    unset 'stack[${#stack[@]}-1]'
                elif ! $is_abs; then
                    stack+=("..")
                fi
                ;;
            *)
                stack+=("$part")
                ;;
        esac
    done

    local normalized=""
    if $is_abs; then
        normalized="/"
    fi
    if [[ ${#stack[@]} -gt 0 ]]; then
        local joined
        joined=$(IFS=/; printf '%s' "${stack[*]}")
        normalized+="$joined"
    fi

    [[ -z "$normalized" ]] && normalized="/"
    printf '%s' "$normalized"
}

# Verify path is safe to modify (not in protected directories)
# Args: path
# Returns: 0 if safe, 1 if protected
_cs_is_safe_path() {
    local path="$1"
    local abs_path

    # Convert to absolute path first
    if [[ "$path" != /* ]]; then
        path="$PWD/$path"
    fi

    # Normalize path to resolve .., ., and //
    # Use realpath if available (handles symlinks), otherwise use pure-bash fallback
    if command -v realpath &>/dev/null && realpath -m / &>/dev/null 2>&1; then
        abs_path=$(realpath -m "$path" 2>/dev/null || _cs_normalize_path "$path")
    else
        abs_path=$(_cs_normalize_path "$path")
    fi

    for protected in "${CHECKSUM_SYNC_PROTECTED_PATHS[@]}"; do
        # Check for exact match OR path is inside protected directory
        if [[ "$abs_path" == "$protected" || "$abs_path" == "$protected/"* ]]; then
            _cs_log_error "Refusing to modify protected path: $abs_path"
            _cs_log_error "Protected prefix: $protected"
            return 1
        fi
    done
    return 0
}

# Hash stdin, not a pathname printed by the hash tool. GNU sha256sum escapes
# certain filenames; that escape prefix is not part of the actual digest.
_cs_sha256() {
    local file="${1:-}" digest
    [[ -f "$file" && ! -L "$file" ]] || return 4
    if command -v sha256sum &>/dev/null; then
        digest=$(sha256sum < "$file") || return 1
    elif command -v shasum &>/dev/null; then
        digest=$(shasum -a 256 < "$file") || return 1
    else
        return 3
    fi
    digest="${digest%% *}"
    [[ "$digest" =~ ^[0-9a-fA-F]{64}$ && -f "$file" && ! -L "$file" ]] || return 1
    printf '%s\n' "${digest,,}"
}

# Portable, unescaped sha256sum member names. Spaces are supported; escaped
# filenames, controls, absolute/drive paths, options and traversal are not.
# A single conventional ./ prefix is normalized before duplicate detection.
_cs_member_name() {
    local name="${1:-}"
    name="${name#./}"
    [[ -n "$name" && "$name" != /* && "$name" != -* && "$name" != */ &&
       "$name" != *[[:cntrl:]]* && "$name" != *\\* && "$name" != *:* ]] || return 4
    case "/$name/" in *'/../'*|*'/./'*|*'//'*) return 4 ;; esac
    printf '%s\n' "$name"
}

_cs_regular_member() {
    local root="$1" name="$2" part cursor="$1"
    [[ -d "$root" && ! -L "$root" ]] || return 4
    while [[ "$name" == */* ]]; do
        part="${name%%/*}"; name="${name#*/}"
        cursor="$cursor/$part"
        [[ -d "$cursor" && ! -L "$cursor" ]] || return 4
    done
    [[ -f "$cursor/$name" && ! -L "$cursor/$name" ]]
}

# Validate a WHOLE manifest before emitting any records. No empty success,
# duplicate names (including ./ aliases), malformed rows or ignored HTML.
# Args: manifest_file
# stdout: normalized text-mode SHA256 records, sorted by filename in C locale.
# Both sha256sum text/binary modes, uppercase digests, CRLF, comments, and a
# final record without a newline are accepted. This validates syntax, NOT trust.
checksum_manifest_normalize() (
    [[ $# -eq 1 && -f "$1" && ! -L "$1" && -s "$1" ]] || return 4
    local manifest="$1" line hash sep name key rows='' count=0
    local -A seen=()
    # Bash read would silently remove NUL bytes. Reject them before parsing.
    LC_ALL=C tr -d '\000' < "$manifest" | cmp -s - "$manifest" || return 4
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -n "$line" && "$line" != \#* ]] || continue
        [[ "$line" == *[![:space:]]* ]] || continue
        hash="${line:0:64}"; sep="${line:64:2}"; name="${line:66}"
        if [[ ! "$hash" =~ ^[0-9a-fA-F]{64}$ || ( "$sep" != '  ' && "$sep" != ' *' ) ]]; then
            _cs_log_error "Malformed checksum record"
            return 4
        fi
        name=$(_cs_member_name "$name") || { _cs_log_error "Unsafe checksum member"; return 4; }
        # Prefix the associative key to keep even unusual literal names data.
        key="member:$name"
        [[ -z "${seen[$key]:-}" ]] || { _cs_log_error "Duplicate checksum member: $name"; return 4; }
        seen["$key"]=1
        rows+="${hash,,}  $name"$'\n'
        count=$((count + 1))
    done < "$manifest"
    ((count > 0)) || { _cs_log_error "Checksum manifest has no records"; return 4; }
    # Fixed 66-byte hash/separator prefix. sort's key includes the complete
    # filename, including its spaces, not just a whitespace-delimited word.
    printf '%s' "$rows" | LC_ALL=C sort -k1.67
)

# Directory releases are flat. Preserve existing metadata exclusion by default;
# --include-metadata covers README/text, SBOM and provenance payloads as well.
# Integrity manifests/signatures never hash themselves or form signature cycles.
_cs_skip_member() {
    case "$1" in
        *.sha256|*.sha512|*.md5|*.minisig|*.sig|*.asc|*SHA256SUMS*|checksums.txt) return 0 ;;
    esac
    if [[ "$2" != true ]]; then
        case "$1" in *.txt|*.intoto.jsonl|*.sbom.*) return 0 ;; esac
    fi
    return 1
}

# Record selection with checked find output and NUL-delimited pathname reads.
# Linked/special candidates must fail, not silently disappear from the set.
_cs_select_members() (
    local root="$1" include="$2" exclude="$3" metadata="$4" output="$5" inventory="$6"
    local file name members=''
    find "$root" -mindepth 1 -maxdepth 1 -print0 > "$inventory" || return 1
    while IFS= read -r -d '' file; do
        [[ ! -d "$file" || -L "$file" ]] || continue
        name="${file##*/}"
        [[ "$name" == $include ]] || continue
        [[ -z "$exclude" || ! "$name" =~ $exclude ]] || continue
        [[ "$file" != "$output" ]] || continue
        _cs_skip_member "$name" "$metadata" && continue
        _cs_member_name "$name" >/dev/null || return 4
        [[ -f "$file" && ! -L "$file" ]] || { _cs_log_error "Unsafe checksum candidate: $name"; return 4; }
        [[ -z "$output" || ! "$file" -ef "$output" ]] || {
            _cs_log_error "Checksum output aliases an artifact: $name"; return 4;
        }
        members+="$name"$'\n'
    done < "$inventory"
    [[ -n "$members" ]] || { _cs_log_error "No artifacts selected for checksums"; return 7; }
    printf '%s' "$members" | LC_ALL=C sort
)

# Generate a complete deterministic manifest, including separate versioned and
# compatibility names even when their bytes/inodes match. No partial stdout or
# truncated old output after hashing, selection or publication failures.
# Args: dir [--output file] [--include glob] [--exclude regex] [--include-metadata]
checksum_generate() (
    local dir='' output='' include='*' exclude='' metadata=false option
    while (($#)); do
        case "$1" in
            --output|-o|--include|-i|--exclude|-e)
                [[ $# -ge 2 && -n "$2" ]] || return 4
                option="$1"
                case "$option" in
                    --output|-o) output="$2" ;;
                    --include|-i) include="$2" ;;
                    *) exclude="$2" ;;
                esac
                shift 2 ;;
            --include-metadata) metadata=true; shift ;;
            --) shift; [[ $# -eq 1 && -z "$dir" ]] || return 4; dir="$1"; shift ;;
            -*) return 4 ;;
            *) [[ -z "$dir" ]] || return 4; dir="$1"; shift ;;
        esac
    done
    [[ -n "$dir" && -d "$dir" && ! -L "$dir" && "$include" != */* ]] || return 4
    local regex_status=0
    [[ '' =~ $exclude ]] || regex_status=$?
    [[ "$regex_status" != 2 ]] || return 4
    dir=$(cd "$dir" && pwd -P) || return 4
    local parent="${TMPDIR:-/tmp}" name work cleanup members again member digest hash_status
    if [[ -n "$output" ]]; then
        parent=$(dirname "$output"); name=$(basename "$output")
        _cs_member_name "$name" >/dev/null || return 4
        [[ -d "$parent" && ! -L "$parent" && ! -L "$output" &&
           ( ! -e "$output" || -f "$output" ) ]] || return 4
        parent=$(cd "$parent" && pwd -P) || return 4
        output="$parent/$name"
    fi
    work=$(mktemp -d "$parent/.dsr-checksums.XXXXXXXX") || return 1
    printf -v cleanup 'rm -f -- %q %q %q %q; rmdir -- %q 2>/dev/null || true' \
        "$work/inventory" "$work/manifest" "$work/normalized" "$work/verify.log" "$work"
    trap "$cleanup" EXIT
    trap 'exit 5' HUP INT TERM
    members=$(_cs_select_members "$dir" "$include" "$exclude" "$metadata" "$output" "$work/inventory") || return $?
    : > "$work/manifest" || return 1
    while IFS= read -r member; do
        digest=$(_cs_sha256 "$dir/$member") || {
            hash_status=$?; _cs_log_error "Cannot hash artifact: $member"; return "$hash_status";
        }
        printf '%s  %s\n' "$digest" "$member" >> "$work/manifest" || return 1
    done <<< "$members"
    checksum_manifest_normalize "$work/manifest" > "$work/normalized" || return $?
    # Rehash the entire selection after collecting it; a late producer must
    # not silently change an earlier artifact or add/remove a release name.
    checksum_verify "$work/normalized" "$dir" >/dev/null 2> "$work/verify.log" || {
        hash_status=$?; cat "$work/verify.log" >&2; return "$hash_status";
    }
    again=$(_cs_select_members "$dir" "$include" "$exclude" "$metadata" "$output" "$work/inventory") || return $?
    [[ "$members" == "$again" ]] || { _cs_log_error "Artifact selection changed while hashing"; return 1; }
    if [[ -n "$output" ]]; then
        [[ ! -L "$output" && ( ! -e "$output" || -f "$output" ) ]] || return 4
        if [[ -f "$output" ]] && cmp -s "$work/normalized" "$output"; then
            _cs_log_info "Retaining identical checksum manifest: $output"
            return 0
        fi
        mv -f -- "$work/normalized" "$output" || return 1
    else
        cat "$work/normalized" || return 1
    fi
)

# Verify every record; --strict also enforces complete flat-directory coverage
# under the same selection policy as generation. Syntax errors are exit 4,
# missing/mismatching payloads exit 1, unavailable hash tools exit 3.
# Args: manifest dir [--strict] [--include-metadata]
checksum_verify() (
    [[ $# -ge 2 ]] || return 4
    local manifest="$1" dir="$2" strict=false metadata=false
    shift 2
    while (($#)); do
        case "$1" in --strict) strict=true ;; --include-metadata) metadata=true ;; *) return 4 ;; esac
        shift
    done
    [[ -d "$dir" && ! -L "$dir" ]] || return 4
    dir=$(cd "$dir" && pwd -P) || return 4
    local normalized line expected name actual verified=0 listed='' selected work cleanup canonical_manifest
    normalized=$(checksum_manifest_normalize "$manifest") || return $?
    while IFS= read -r line; do
        expected="${line:0:64}"; name="${line:66}"
        _cs_regular_member "$dir" "$name" || { _cs_log_error "Missing or unsafe artifact: $name"; return 1; }
        actual=$(_cs_sha256 "$dir/$name") || return $?
        [[ "$actual" == "$expected" ]] || { _cs_log_error "Checksum mismatch: $name"; return 1; }
        listed+="$name"$'\n'
        verified=$((verified + 1))
    done <<< "$normalized"
    if $strict; then
        canonical_manifest="$(cd "$(dirname "$manifest")" && pwd -P)/$(basename "$manifest")" || return 4
        work=$(mktemp -d "${TMPDIR:-/tmp}/dsr-checksum-verify.XXXXXXXX") || return 1
        printf -v cleanup 'rm -f -- %q; rmdir -- %q 2>/dev/null || true' "$work/inventory" "$work"
        trap "$cleanup" EXIT
        trap 'exit 5' HUP INT TERM
        selected=$(_cs_select_members "$dir" '*' '' "$metadata" "$canonical_manifest" "$work/inventory") || return $?
        [[ "${listed%$'\n'}" == "$selected" ]] || { _cs_log_error "Manifest does not cover the exact release asset set"; return 1; }
    fi
    _cs_log_ok "Verified $verified file(s)"
)

# ============================================================================
# Repository Sync
# ============================================================================

_cs_repo_name() { [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; }

_cs_repo_member() {
    local name
    name=$(_cs_member_name "${1:-}") || return 4
    case "/${name,,}/" in *'/.git/'*) return 4 ;; esac
    printf '%s\n' "$name"
}

# Preserve credential helpers and operator URL mappings, but never let ambient
# Git plumbing redirect writes into another worktree/index. Paths stay literal.
_cs_git() (
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
    unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
    unset GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
    unset GIT_GLOB_PATHSPECS GIT_NOGLOB_PATHSPECS GIT_ICASE_PATHSPECS
    export GIT_TERMINAL_PROMPT=0 GIT_NO_REPLACE_OBJECTS=1 GIT_LITERAL_PATHSPECS=1
    git -c core.fsmonitor=false -c submodule.recurse=false "$@"
)

# New private checkout owned by this sync invocation. Keep it on failure and
# after an unpushed commit: deleting it would discard the only completed work.
_cs_clone_repo() {
    local repo="$1" destination="$2"
    _cs_repo_name "$repo" && [[ ! -e "$destination" && ! -L "$destination" ]] || return 4
    _cs_is_safe_path "$destination" || return 4
    _cs_git clone --depth 1 --no-recurse-submodules "https://github.com/$repo.git" "$destination" >&2 || return 8
    printf '%s\n' "$destination"
}

# Atomic manifest update, commit ONLY its literal path, and explicitly push
# the current branch when requested (also on an unchanged retry). No force.
# Reject user edits to the target; unrelated staged work is never committed.
# Args: repo_path checksums_content [--commit] [--push] [--checksums-file path]
# stdout: one update receipt on success; failures retain checkout diagnostics.
_cs_update_repo_checksums() (
    [[ $# -ge 2 ]] || return 4
    local repo_path="$1" content="$2" commit=false push=false member=SHA256SUMS.txt
    shift 2
    while (($#)); do
        case "$1" in
            --commit) commit=true; shift ;;
            --push) push=true; shift ;;
            --checksums-file) [[ $# -ge 2 && -n "$2" ]] || return 4; member="$2"; shift 2 ;;
            *) return 4 ;;
        esac
    done
    if $push && ! $commit; then return 4; fi
    command -v jq >/dev/null || return 3
    [[ -d "$repo_path" && ! -L "$repo_path" ]] || return 4
    repo_path=$(cd "$repo_path" && pwd -P) || return 4
    _cs_is_safe_path "$repo_path" || return 4
    member=$(_cs_repo_member "$member") || return 4
    local top branch='' head='' stage cleanup normalized full_path parent cursor rest part tracked=false changed=false
    local publish_stage='' publish_cleanup
    top=$(_cs_git -C "$repo_path" rev-parse --show-toplevel) || return 4
    [[ "$top" == "$repo_path" ]] || return 4
    if $commit; then
        head=$(_cs_git -C "$repo_path" rev-parse --verify HEAD) || return 4
        branch=$(_cs_git -C "$repo_path" symbolic-ref -q HEAD) || return 4
    fi
    # Resolve only directory components, refusing links before creating/writing
    # anything under the requested repository-relative path.
    cursor="$repo_path"; rest="$member"
    while [[ "$rest" == */* ]]; do
        part="${rest%%/*}"; rest="${rest#*/}"; cursor="$cursor/$part"
        [[ ! -L "$cursor" && ( ! -e "$cursor" || -d "$cursor" ) ]] || return 4
    done
    full_path="$repo_path/$member"; parent="$cursor"
    [[ ! -L "$full_path" && ( ! -e "$full_path" || -f "$full_path" ) ]] || return 4
    if _cs_git -C "$repo_path" ls-files --error-unmatch -- "$member" >/dev/null 2>&1; then tracked=true; fi
    if $tracked; then
        _cs_git -C "$repo_path" diff --quiet -- "$member" &&
        _cs_git -C "$repo_path" diff --cached --quiet -- "$member" || {
            _cs_log_error "Checksum destination has uncommitted changes: $member"; return 2;
        }
    elif [[ -e "$full_path" ]]; then
        _cs_log_error "Refusing to replace an untracked checksum file: $member"; return 2
    fi
    # Syntax is checked before even creating missing target directories.
    stage=$(mktemp -d "$repo_path/.dsr-checksum-update.XXXXXXXX") || return 1
    printf -v cleanup 'rm -f -- %q %q; rmdir -- %q 2>/dev/null || true' "$stage/input" "$stage/manifest" "$stage"
    trap "$cleanup" EXIT
    trap 'exit 5' HUP INT TERM
    printf '%s\n' "$content" > "$stage/input" || return 1
    checksum_manifest_normalize "$stage/input" > "$stage/manifest" || return $?
    if [[ ! -f "$full_path" ]] || ! cmp -s "$stage/manifest" "$full_path"; then
        mkdir -p -- "$parent" || return 1
        [[ ! -L "$full_path" && ( ! -e "$full_path" || -f "$full_path" ) ]] || return 4
        # The target subdirectory can be a different mounted filesystem. Stage
        # beside the final path so mv is a rename, not a cross-device copy.
        publish_stage=$(mktemp -d "$parent/.dsr-checksum-output.XXXXXXXX") || return 1
        printf -v publish_cleanup 'rm -f -- %q; rmdir -- %q 2>/dev/null || true' "$publish_stage/manifest" "$publish_stage"
        trap "$cleanup; $publish_cleanup" EXIT
        cp -- "$stage/manifest" "$publish_stage/manifest" || return 1
        cmp -s "$stage/manifest" "$publish_stage/manifest" || return 1
        chmod 644 "$publish_stage/manifest" || return 1
        mv -f -- "$publish_stage/manifest" "$full_path" || return 1
        changed=true
    fi
    if $commit && $changed; then
        _cs_git -C "$repo_path" add -- "$member" || return 1
        # --only explicitly excludes unrelated staged changes. Do not suppress
        # commit failures (missing identity, rejected hooks, signing failures).
        _cs_git -C "$repo_path" commit --only -m "Update checksums" -- "$member" >&2 || return 1
        head=$(_cs_git -C "$repo_path" rev-parse --verify HEAD) || return 1
    fi
    if $commit; then
        normalized=$(checksum_manifest_normalize "$stage/input") || return 1
        [[ "$(_cs_git -C "$repo_path" show "HEAD:$member")" == "$normalized" ]] || return 1
    fi
    if $push; then
        _cs_git -C "$repo_path" push --porcelain origin "HEAD:$branch" >&2 || return 8
    fi
    jq -nc --arg path "$repo_path" --arg file "$member" --arg sha "$head" --arg branch "$branch" \
        --argjson changed "$changed" --argjson pushed "$push" \
        '{checkout:$path,checksums_file:$file,changed:$changed,pushed:$pushed,
          commit:(if $sha == "" then null else $sha end),branch:$branch}'
)

# Only transport failures try another source. A downloaded but malformed
# manifest is fatal, never a reason to select a different set of checksums.
_cs_fetch_manifest() {
    local repo="$1" tag="$2" tool="$3" output="$4" prefer="$5" transport candidate
    local transports=(curl gh)
    [[ "$prefer" != true ]] || transports=(gh curl)
    for candidate in checksums.sha256 SHA256SUMS.txt "${tool}-${tag#v}-SHA256SUMS.txt" checksums.txt; do
        for transport in "${transports[@]}"; do
            command -v "$transport" >/dev/null || continue
            if [[ "$transport" == curl ]]; then
                curl -sSfL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 60 \
                    "https://github.com/$repo/releases/download/${tag//+/%2B}/$candidate" -o "$output" 2>/dev/null || continue
            else
                GH_HOST=github.com gh release download "$tag" --repo "$repo" --pattern "$candidate" \
                    --output "$output" --clobber 2>/dev/null || continue
            fi
            checksum_manifest_normalize "$output" >/dev/null || return 4
            printf '%s\n' "$candidate"
            return 0
        done
    done
    _cs_log_error "No checksum manifest available for $repo $tag"
    return 7
}

# ============================================================================
# Main Sync Command
# ============================================================================

# Sync checksums to downstream repos after release
# Usage: checksum_sync <tool> <version> [options]
# Options:
#   --artifacts-dir <dir>  Directory with release artifacts
#   --target-repo <repo>   Target repository to update (can repeat)
#   --checksums-file <file> Checksums file in target repo (default: SHA256SUMS.txt)
#   --push                  Push changes to remote
#   --open-issue            Open security review issue instead of auto-merge
#   --dry-run               Show what would be done
checksum_sync() (
    local tool_name='' version='' repo='' artifacts_dir='' manifest='' checksums_file=SHA256SUMS.txt
    local push_changes=false review=false dry_run=false json=false metadata=false prefer=false
    local workspace='' tag='' source_kind='' source_asset='' manifest_sha='' error='' arg option
    local start_time=$SECONDS synced=0 failed=0 planned=0 issues_opened=0
    local -a target_repos=() results=()
    for arg in "$@"; do [[ "$arg" != --json ]] || json=true; done
    command -v jq >/dev/null || {
        _cs_log_error 'jq is required for checksum sync'
        if $json; then printf '%s\n' '{"status":"error","exit_code":3,"error":"jq is required"}'; fi
        return 3
    }
    _cs_sync_finish() {
        local code=$? overall=success entries
        trap - EXIT
        if ((code != 0)); then
            overall=error
            ((synced + issues_opened == 0)) || overall=partial
            [[ -n "$error" ]] || error="Checksum sync failed (exit $code)"
        fi
        entries=$(printf '%s\n' "${results[@]}" | jq -s '.') || exit 1
        if $json; then
            jq -nc --arg status "$overall" --argjson code "$code" --arg tool "$tool_name" \
                --arg version "$tag" --arg repo "$repo" --arg workspace "$workspace" --arg error "$error" \
                --arg source "$source_kind" --arg asset "$source_asset" --arg digest "$manifest_sha" \
                --argjson duration "$((SECONDS - start_time))" --argjson results "$entries" \
                --argjson synced "$synced" --argjson failed "$failed" --argjson planned "$planned" \
                --argjson issues "$issues_opened" --argjson dry_run "$dry_run" \
                '{status:$status,exit_code:$code,tool:$tool,version:$version,repository:$repo,
                  workspace:(if $workspace == "" then null else $workspace end),dry_run:$dry_run,
                  source:{kind:$source,asset:$asset,manifest_sha256:$digest},
                  error:(if $error == "" then null else $error end),duration_seconds:$duration,
                  synced:$synced,failed:$failed,planned:$planned,issues_opened:$issues,results:$results}' || exit 1
        fi
        [[ -z "$workspace" ]] || _cs_log_info "Checksum sync workspace retained: $workspace"
        exit "$code"
    }
    trap _cs_sync_finish EXIT
    trap 'error="Sync interrupted"; exit 5' HUP INT TERM
    while (($#)); do
        case "$1" in
            --tool|-t|--version|-V|--repo|--artifacts-dir|-a|--manifest|--target-repo|-r|--checksums-file)
                [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || { error="Missing value for $1"; return 4; }
                option="$1"
                case "$option" in
                    --tool|-t) tool_name="$2" ;;
                    --version|-V) version="$2" ;;
                    --repo) repo="$2" ;;
                    --artifacts-dir|-a) artifacts_dir="$2" ;;
                    --manifest) manifest="$2" ;;
                    --target-repo|-r) target_repos+=("$2") ;;
                    --checksums-file) checksums_file="$2" ;;
                esac
                shift 2 ;;
            --push) push_changes=true; shift ;;
            --external|--open-issue) review=true; shift ;;
            --dry-run|-n) dry_run=true; shift ;;
            --json) shift ;;
            --include-metadata) metadata=true; shift ;;
            --prefer-gh) prefer=true; shift ;;
            --help|-h)
                cat >&2 <<'EOF'
checksum_sync - Sync validated release checksums to downstream repositories
USAGE:
    checksum_sync TOOL VERSION [--repo OWNER/REPO] [options]
    bash src/checksum_sync.sh sync TOOL VERSION [options]
OPTIONS:
    --artifacts-dir DIR      Generate and reverify local release checksums
    --manifest FILE          Use an existing manifest (syntax checked, not authenticated)
    --target-repo OWNER/REPO Downstream destination; repeat for multiple repositories
    --checksums-file PATH    Repository-relative output (default: SHA256SUMS.txt)
    --include-metadata       Include text, SBOM and provenance in local generation
    --prefer-gh              Prefer authenticated GitHub CLI release downloads
    --push                   Push the checksum commit to the current branch; never force
    --external, --open-issue Open a security review issue instead of committing
    --dry-run                Validate and plan without cloning or writing remote repositories
    --json                   One result with per-target outcomes and retained checkout paths
Local commits and failed checkouts are retained in the reported private workspace.
Download-only manifests are syntax-validated, not proof of artifact authenticity.
EOF
                return 0 ;;
            -*) error="Unknown option: $1"; return 4 ;;
            *)
                if [[ -z "$tool_name" ]]; then tool_name="$1"
                elif [[ -z "$version" ]]; then version="$1"
                else error='Too many positional arguments'; return 4; fi
                shift ;;
        esac
    done
    error='Invalid checksum sync configuration'
    [[ "$tool_name" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ && "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || return 4
    [[ "$version" != null && "$version" != v ]] || return 4
    tag="v${version#v}"
    checksums_file=$(_cs_repo_member "$checksums_file") || return 4
    [[ -z "$manifest" || -z "$artifacts_dir" ]] || return 4
    [[ -z "$manifest" || ( -f "$manifest" && ! -L "$manifest" ) ]] || return 4
    [[ -z "$artifacts_dir" || ( -d "$artifacts_dir" && ! -L "$artifacts_dir" ) ]] || return 4
    if [[ -z "$repo" ]]; then
        if declare -F act_get_repo >/dev/null; then
            repo=$(act_get_repo "$tool_name") || return 4
        fi
        [[ -n "$repo" ]] || repo="Dicklesworthstone/$tool_name"
    fi
    _cs_repo_name "$repo" || return 4
    ((${#target_repos[@]} > 0)) || target_repos=("$repo")
    local target key
    local -A seen=()
    local -a unique_targets=()
    for target in "${target_repos[@]}"; do
        _cs_repo_name "$target" || return 4
        key="${target,,}"
        [[ -z "${seen[$key]:-}" ]] || continue
        seen["$key"]=1; unique_targets+=("$target")
    done
    error=''
    local root="${TMPDIR:-/tmp}"
    root=$(cd "$root" && pwd -P) || return 4
    _cs_is_safe_path "$root" || { error='Protected temporary root'; return 4; }
    workspace=$(mktemp -d "$root/dsr-checksum-sync.XXXXXXXX") || return 1
    workspace=$(cd "$workspace" && pwd -P) || return 1
    local content='' candidate state_dir="${DSR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsr}"
    if [[ -z "$artifacts_dir" && -z "$manifest" ]]; then
        for candidate in "$state_dir/releases/$tool_name/$tag" "$state_dir/artifacts/$tool_name/$tag" "/tmp/dsr-release-$tool_name-$tag"; do
            [[ -d "$candidate" && ! -L "$candidate" ]] || continue
            artifacts_dir="$candidate"; break
        done
    fi
    if [[ -n "$artifacts_dir" ]]; then
        source_kind=local_artifacts
        _cs_log_info "Generating checksums from: $artifacts_dir"
        local -a generate_args=()
        $metadata && generate_args+=(--include-metadata)
        checksum_generate "$artifacts_dir" --output "$workspace/manifest" "${generate_args[@]}" || {
            local rc=$?; error='Local artifact checksum generation failed'; return "$rc";
        }
    elif [[ -n "$manifest" ]]; then
        source_kind=provided_manifest
        checksum_manifest_normalize "$manifest" > "$workspace/manifest" || { error='Invalid provided manifest'; return 4; }
    else
        source_kind=release_manifest
        source_asset=$(_cs_fetch_manifest "$repo" "$tag" "$tool_name" "$workspace/download" "$prefer") || {
            local rc=$?; error='Release checksum download or validation failed'; return "$rc";
        }
        checksum_manifest_normalize "$workspace/download" > "$workspace/manifest" || return 4
    fi
    content=$(cat "$workspace/manifest") || return 1
    manifest_sha=$(_cs_sha256 "$workspace/manifest") || return $?
    local index=0 checkout receipt rc action entry issue_url body
    for target in "${unique_targets[@]}"; do
        index=$((index + 1)); rc=0; receipt='{}'; checkout=''; action=update
        if $dry_run; then
            action=planned; planned=$((planned + 1))
            _cs_log_info "[dry-run] Would update $checksums_file in $target"
        elif $review; then
            action=issue_opened
            body=$(printf '## Checksum review: %s %s\n\nManifest SHA256: `%s`\n\nSource: %s\n\nValidate against the official release before accepting.\n\n```text\n%s\n```\n' \
                "$tool_name" "$tag" "$manifest_sha" "$source_kind" "$content") || return 1
            if ! command -v gh >/dev/null; then rc=3
            elif issue_url=$(GH_HOST=github.com gh issue create --repo "$target" \
                --title "Security Review: Update checksums for $tool_name $tag" --body "$body" 2> "$workspace/target-$index.log"); then
                receipt=$(jq -nc --arg url "$issue_url" '{issue_url:$url}') || return 1
                issues_opened=$((issues_opened + 1))
            else rc=$?; fi
        else
            checkout="$workspace/target-$index"
            if ! _cs_clone_repo "$target" "$checkout" > "$workspace/target-$index.path" 2> "$workspace/target-$index.log"; then
                rc=8; action=clone
            else
                local -a update_args=(--commit --checksums-file "$checksums_file")
                $push_changes && update_args+=(--push)
                receipt=$(_cs_update_repo_checksums "$checkout" "$content" "${update_args[@]}" 2>> "$workspace/target-$index.log") || rc=$?
                ((rc != 0)) || synced=$((synced + 1))
            fi
        fi
        if ((rc != 0)); then
            failed=$((failed + 1)); receipt='{}'
            _cs_log_error "$action failed for $target (exit $rc); checkout/logs retained"
        fi
        entry=$(jq -nc --arg repo "$target" --arg action "$action" --arg path "$checkout" \
            --argjson code "$rc" --argjson receipt "$receipt" \
            '{repo:$repo,action:$action,status:(if $code == 0 then "success" else "error" end),
              exit_code:$code,checkout:(if $path == "" then null else $path end)} + $receipt') || return 1
        results+=("$entry")
    done
    _cs_log_info "Checksum sync: $synced updated, $issues_opened review issues, $planned planned, $failed failed"
    ((failed == 0)) || { error='One or more downstream updates failed'; return 1; }
    return 0
)

# JSON output wrapper
checksum_sync_json() (
    command -v jq >/dev/null || { checksum_sync --json "$@"; return $?; }
    local stage cleanup root code=0
    root=$(cd "${TMPDIR:-/tmp}" && pwd -P) || return 4
    if ! _cs_is_safe_path "$root"; then checksum_sync --json "$@"; return $?; fi
    stage=$(mktemp -d "$root/dsr-checksum-json.XXXXXXXX") || return 1
    printf -v cleanup 'rm -f -- %q %q; rmdir -- %q 2>/dev/null || true' "$stage/result" "$stage/log" "$stage"
    trap "$cleanup" EXIT
    trap 'exit 5' HUP INT TERM
    checksum_sync --json "$@" > "$stage/result" 2> "$stage/log" || code=$?
    jq -ce -s --rawfile output "$stage/log" '
        if length == 1 and (.[0] | type == "object") then .[0] + {output:$output}
        else error("invalid sync result") end' "$stage/result" || return 1
    return "$code"
)

# ============================================================================
# Exports
# ============================================================================

export -f checksum_manifest_normalize checksum_generate checksum_verify checksum_sync checksum_sync_json

# Standalone entry point as well as a sourceable module. No release or remote
# mutation occurs merely by sourcing this file.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    command="${1:-}"; shift 2>/dev/null || true
    case "$command" in
        generate) checksum_generate "$@" ;;
        verify) checksum_verify "$@" ;;
        normalize) checksum_manifest_normalize "$@" ;;
        sync) checksum_sync "$@" ;;
        *) printf 'Usage: checksum_sync.sh {generate|verify|normalize|sync} [arguments]\n' >&2; exit 4 ;;
    esac
    exit $?
fi
