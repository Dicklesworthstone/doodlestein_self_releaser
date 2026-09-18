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

# Clone a repository to a temp directory
# Args: repo [--branch branch]
# Returns: path to cloned repo on stdout
_cs_clone_repo() {
    local repo="$1"
    local branch="${2:-}"

    # Ensure we're working in /tmp
    local temp_dir
    temp_dir=$(mktemp -d "/tmp/dsr-checksum-sync-XXXXXX")

    if ! _cs_is_safe_path "$temp_dir"; then
        rm -rf "$temp_dir"
        return 1
    fi

    local clone_args=(--depth 1)
    [[ -n "$branch" ]] && clone_args+=(--branch "$branch")

    local repo_url="https://github.com/$repo.git"
    if git clone "${clone_args[@]}" "$repo_url" "$temp_dir/repo" 2>/dev/null; then
        echo "$temp_dir/repo"
        return 0
    else
        _cs_log_error "Failed to clone: $repo"
        rm -rf "$temp_dir"
        return 1
    fi
}

# Update checksums in a target repository
# Args: repo_path checksums_content [--commit] [--push]
_cs_update_repo_checksums() {
    local repo_path="$1"
    local checksums_content="$2"
    local commit=false
    local push=false
    local checksums_file=""

    shift 2
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --commit) commit=true; shift ;;
            --push) push=true; shift ;;
            --checksums-file) checksums_file="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if ! _cs_is_safe_path "$repo_path"; then
        return 1
    fi

    # Find or create checksums file
    if [[ -z "$checksums_file" ]]; then
        checksums_file="SHA256SUMS.txt"
    fi

    local full_path="$repo_path/$checksums_file"

    # Update checksums
    echo -n "$checksums_content" > "$full_path"
    _cs_log_ok "Updated: $checksums_file"

    if $commit; then
        git -C "$repo_path" add "$checksums_file"
        if ! git -C "$repo_path" diff --cached --quiet; then
            git -C "$repo_path" commit -m "Update checksums" >/dev/null 2>&1
            _cs_log_ok "Committed changes"

            if $push; then
                if git -C "$repo_path" push >/dev/null 2>&1; then
                    _cs_log_ok "Pushed to remote"
                else
                    _cs_log_error "Push failed"
                    return 1
                fi
            fi
        else
            _cs_log_info "No changes to commit"
        fi
    fi

    return 0
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
checksum_sync() {
    local tool_name=""
    local version=""
    local artifacts_dir=""
    local target_repos=()
    local checksums_file="SHA256SUMS.txt"
    local push_changes=false
    local open_issue=false
    local dry_run=false
    local is_external=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tool|-t)
                tool_name="$2"
                shift 2
                ;;
            --version|-V)
                version="$2"
                shift 2
                ;;
            --artifacts-dir|-a)
                artifacts_dir="$2"
                shift 2
                ;;
            --target-repo|-r)
                target_repos+=("$2")
                shift 2
                ;;
            --checksums-file)
                checksums_file="$2"
                shift 2
                ;;
            --push)
                push_changes=true
                shift
                ;;
            --open-issue)
                open_issue=true
                shift
                ;;
            --external)
                is_external=true
                shift
                ;;
            --dry-run|-n)
                dry_run=true
                shift
                ;;
            --help|-h)
                cat << 'EOF'
checksum_sync - Sync checksums to downstream repos

USAGE:
    checksum_sync <tool> <version>
    checksum_sync --tool <name> --version <tag> [options]

OPTIONS:
    -t, --tool <name>           Tool to sync checksums for
    -V, --version <ver>         Version/tag to sync
    -a, --artifacts-dir <dir>   Directory with release artifacts
    -r, --target-repo <repo>    Target repository (can repeat)
    --checksums-file <file>     Checksums file name (default: SHA256SUMS.txt)
    --push                      Push changes to remote repos
    --open-issue                Open security review issue (for external tools)
    --external                  Treat as external tool (triggers review)
    -n, --dry-run               Show what would be done

DESCRIPTION:
    After a dsr release, updates checksum manifests in downstream repositories.

    For internal tools: auto-commits and optionally pushes changes.
    For external tools: opens a security review issue instead of auto-merge.

    All operations happen in /tmp to avoid modifying /data/projects.

EXAMPLES:
    checksum_sync ntm v1.2.3                      # Auto-detect artifacts
    checksum_sync ntm v1.2.3 --push               # Commit and push
    checksum_sync ntm v1.2.3 --external           # Open review issue
    checksum_sync ntm v1.2.3 --dry-run            # Preview changes

EXIT CODES:
    0  - Checksums synced successfully
    1  - Sync failed
    3  - Authentication error
    4  - Invalid arguments
    7  - Artifacts not found
EOF
                return 0
                ;;
            -*)
                _cs_log_error "Unknown option: $1"
                return 4
                ;;
            *)
                # Positional arguments: tool, version
                if [[ -z "$tool_name" ]]; then
                    tool_name="$1"
                elif [[ -z "$version" ]]; then
                    version="$1"
                fi
                shift
                ;;
        esac
    done

    # Validate required arguments
    if [[ -z "$tool_name" ]]; then
        _cs_log_error "Tool name required"
        return 4
    fi

    if [[ -z "$version" ]]; then
        _cs_log_error "Version required"
        return 4
    fi

    # Record start time
    local start_time
    start_time=$(date +%s)

    # Normalize version
    local tag="${version#v}"
    tag="v$tag"

    _cs_log_info "Syncing checksums for $tool_name $tag"

    # If artifacts directory not specified, try to find release artifacts
    if [[ -z "$artifacts_dir" ]]; then
        # Try common locations
        local state_dir="${DSR_STATE_DIR:-$HOME/.local/state/dsr}"
        local possible_dirs=(
            "$state_dir/releases/$tool_name/$tag"
            "$state_dir/artifacts/$tool_name/$tag"
            "/tmp/dsr-release-$tool_name-$tag"
        )
        for dir in "${possible_dirs[@]}"; do
            if [[ -d "$dir" ]]; then
                artifacts_dir="$dir"
                break
            fi
        done
    fi

    # Generate checksums
    local checksums_content=""
    if [[ -n "$artifacts_dir" && -d "$artifacts_dir" ]]; then
        _cs_log_info "Generating checksums from: $artifacts_dir"
        checksums_content=$(checksum_generate "$artifacts_dir") || return $?
    else
        # Try to fetch from GitHub release
        _cs_log_info "Fetching checksums from GitHub release..."
        local repo
        if command -v act_get_repo &>/dev/null; then
            repo=$(act_get_repo "$tool_name" 2>/dev/null)
        fi
        [[ -z "$repo" ]] && repo="Dicklesworthstone/$tool_name"

        local checksums_url="https://github.com/$repo/releases/download/$tag/${tool_name}-${tag#v}-SHA256SUMS.txt"
        checksums_content=$(curl -sL "$checksums_url" 2>/dev/null)

        if [[ -z "$checksums_content" ]]; then
            _cs_log_error "Could not find checksums for $tool_name $tag"
            _cs_log_error "Tried: $checksums_url"
            return 7
        fi
    fi

    if [[ -z "$checksums_content" ]]; then
        _cs_log_error "No checksums to sync"
        return 7
    fi

    _cs_log_debug "Checksums content:"
    _cs_log_debug "$checksums_content"

    # If no target repos specified, use default (the tool's own repo)
    if [[ ${#target_repos[@]} -eq 0 ]]; then
        local default_repo=""
        if command -v act_get_repo &>/dev/null; then
            default_repo=$(act_get_repo "$tool_name" 2>/dev/null) || default_repo=""
        fi
        [[ -z "$default_repo" ]] && default_repo="Dicklesworthstone/$tool_name"
        target_repos=("$default_repo")
    fi

    local synced=0
    local failed=0
    local issues_opened=0
    local results=()

    for target_repo in "${target_repos[@]}"; do
        _cs_log_info "Updating: $target_repo"

        if $dry_run; then
            _cs_log_info "[dry-run] Would update $checksums_file in $target_repo"
            _cs_log_info "[dry-run] Checksums:"
            echo "$checksums_content" | head -5 >&2
            [[ $(echo "$checksums_content" | wc -l) -gt 5 ]] && _cs_log_info "[dry-run] ..."
            ((synced++))
            continue
        fi

        # For external tools, open an issue instead of auto-merge
        if $is_external || $open_issue; then
            _cs_log_info "Opening security review issue for external tool..."

            local issue_title="Security Review: Update checksums for $tool_name $tag"
            local issue_body="## Checksum Update Request

Tool: \`$tool_name\`
Version: \`$tag\`

### Proposed Checksums
\`\`\`
$checksums_content
\`\`\`

### Action Required
Please review and verify these checksums before merging.

- [ ] Checksums match official release
- [ ] No unexpected changes
- [ ] Source verified

/cc @maintainer"

            if command -v gh &>/dev/null && gh auth status &>/dev/null; then
                if gh issue create --repo "$target_repo" --title "$issue_title" --body "$issue_body" >/dev/null 2>&1; then
                    _cs_log_ok "Security review issue opened in $target_repo"
                    ((issues_opened++))
                    results+=("$(jq -nc --arg repo "$target_repo" '{repo: $repo, action: "issue_opened", status: "success"}')")
                else
                    _cs_log_error "Failed to open issue in $target_repo"
                    ((failed++))
                    results+=("$(jq -nc --arg repo "$target_repo" '{repo: $repo, action: "issue_opened", status: "error"}')")
                fi
            else
                _cs_log_warn "gh CLI not available, cannot open issue"
                _cs_log_info "Manual review required for: $target_repo"
                ((failed++))
                results+=("$(jq -nc --arg repo "$target_repo" '{repo: $repo, action: "issue_opened", status: "error", reason: "gh_unavailable"}')")
            fi
            continue
        fi

        # Clone repo to temp directory
        local repo_path
        repo_path=$(_cs_clone_repo "$target_repo")
        if [[ -z "$repo_path" ]]; then
            _cs_log_error "Failed to clone $target_repo"
            ((failed++))
            results+=("$(jq -nc --arg repo "$target_repo" '{repo: $repo, action: "clone", status: "error"}')")
            continue
        fi

        # Update checksums
        local update_args=(--commit)
        $push_changes && update_args+=(--push)
        update_args+=(--checksums-file "$checksums_file")

        if _cs_update_repo_checksums "$repo_path" "$checksums_content" "${update_args[@]}"; then
            ((synced++))
            results+=("$(jq -nc --arg repo "$target_repo" --argjson pushed "$push_changes" '{repo: $repo, action: "updated", status: "success", pushed: $pushed}')")
        else
            ((failed++))
            results+=("$(jq -nc --arg repo "$target_repo" '{repo: $repo, action: "update", status: "error"}')")
        fi

        # Cleanup
        rm -rf "$(dirname "$repo_path")"
    done

    # Calculate duration
    local end_time duration
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    # Determine overall status
    local status="success"
    local exit_code=0
    if [[ $failed -gt 0 ]]; then
        if [[ $synced -eq 0 && $issues_opened -eq 0 ]]; then
            status="error"
            exit_code=1
        else
            status="partial"
            exit_code=1
        fi
    fi

    # Output summary
    _cs_log_info ""
    _cs_log_info "=== Checksum Sync Summary ==="
    _cs_log_info "Tool:     $tool_name"
    _cs_log_info "Version:  $tag"
    _cs_log_info "Synced:   $synced repo(s)"
    [[ $issues_opened -gt 0 ]] && _cs_log_info "Issues:   $issues_opened opened"
    [[ $failed -gt 0 ]] && _cs_log_error "Failed:   $failed repo(s)"
    _cs_log_info "Duration: ${duration}s"

    return $exit_code
}

# JSON output wrapper
checksum_sync_json() {
    local args=("$@")
    local start_time
    start_time=$(date +%s)

    local output status="success" exit_code=0
    output=$(checksum_sync "${args[@]}" 2>&1) || {
        exit_code=$?
        status="error"
    }

    local end_time duration
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    jq -nc \
        --arg status "$status" \
        --argjson exit_code "$exit_code" \
        --arg output "$output" \
        --argjson duration "$duration" \
        '{
            status: $status,
            exit_code: $exit_code,
            output: $output,
            duration_seconds: $duration
        }'
}

# ============================================================================
# Exports
# ============================================================================

export -f checksum_manifest_normalize checksum_generate checksum_verify checksum_sync checksum_sync_json
