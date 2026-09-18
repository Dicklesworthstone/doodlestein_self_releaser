#!/usr/bin/env bash
# install_gen.sh - Generate per-tool install scripts from templates
#
# Usage:
#   source install_gen.sh
#   install_gen_create <tool>           # Generate install.sh for a tool
#   install_gen_all                     # Generate for all tools in repos.d
#   install_gen_validate <tool>         # Validate generated script
#
# Template requirements enforced:
#   - Shebang: #!/usr/bin/env bash
#   - set -uo pipefail (no set -e)
#   - Explicit error handling
#   - stderr for human logs, stdout for JSON/paths if --json

set -uo pipefail

# Get script directory for sourcing dependencies
_IG_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source dependencies if not already loaded
if ! declare -f log_info &>/dev/null; then
    # Try to source logging from dsr's src directory
    if [[ -f "$_IG_SCRIPT_DIR/logging.sh" ]]; then
        # shellcheck source=/dev/null
        source "$_IG_SCRIPT_DIR/logging.sh"
    else
        # Fallback minimal logging
        log_info()  { echo "[install_gen] $*" >&2; }
        log_ok()    { echo "[install_gen] ✓ $*" >&2; }
        log_warn()  { echo "[install_gen] ⚠ $*" >&2; }
        log_error() { echo "[install_gen] ✗ $*" >&2; }
    fi
fi

# Default config directory
_IG_CONFIG_DIR="${DSR_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/dsr}"
_IG_REPOS_D="${_IG_CONFIG_DIR}/repos.d"

# Output directory for generated installers
_IG_OUTPUT_DIR="${DSR_INSTALLER_DIR:-./installers}"

# ============================================================================
# INSTALLER TEMPLATE
# ============================================================================

# Generate the install.sh script for a tool
# The template is embedded here for easy maintenance
_install_gen_template() {
    # Parameters passed to template - used via placeholder substitution
    # $1=tool_name, $2=repo, $3=binary_name, $4=archive_linux, $5=archive_darwin
    # $6=archive_windows, $7=artifact_naming, $8=language

    cat << 'TEMPLATE_START'
#!/usr/bin/env bash
# install.sh - Install __TOOL_NAME__
#
# Usage:
#   curl -sSfL https://raw.githubusercontent.com/__REPO__/main/install.sh | bash
#   curl -sSfL https://raw.githubusercontent.com/__REPO__/main/install.sh | bash -s -- -v 1.2.3
#   curl -sSfL https://raw.githubusercontent.com/__REPO__/main/install.sh | bash -s -- --json
#
# Options:
#   -v, --version VERSION    Install specific version (default: latest)
#   -d, --dir DIR            Installation directory (default: ~/.local/bin)
#   --verify                 Verify checksums (always enabled)
#   --require-signatures     Require a configured key and valid minisign signature
#   --json                   Output JSON for automation
#   --non-interactive        No prompts, fail on missing consent
#   --cache-dir DIR          Cache directory (default: ~/.cache/dsr/installers)
#   --offline [ARCHIVE]      No network; requires --version and local checksum evidence
#   --prefer-gh              Prefer gh release download for private repos
#   --from-source            Build source instead of downloading (explicit code-execution consent)
#   --allow-source-build     Allow source fallback when discovery/download is unavailable
#   --source-ref REF         With --from-source: HEAD, full SHA, refs/heads/* or refs/tags/*
#   --source-timeout SECONDS  Per-command source-build limit (default: 3600)
#   --source-if-stale N       With --allow-source-build: build head if latest is >N commits behind
#   --no-skills              Skip AI coding agent skill installation
#   --help                   Show this help
#
# AI Coding Agent Skills:
#   The installer automatically installs skills for Claude Code and Codex CLI.
#   Skills teach AI agents about the tool's commands, workflows, and best practices.
#   Use --no-skills to skip skill installation.
#
# Safety:
#   - Never overwrites without asking (unless --yes)
#   - Verifies checksums by default
#   - Supports offline installation from cached archives
#   - Caches downloads for future offline use
#   - Source builds are opt-in, never signed releases, and never cached as releases
#   - --yes permits replacement only; it does not authorize source execution

set -uo pipefail

# Configuration
TOOL_NAME="__TOOL_NAME__"
REPO="__REPO__"
BINARY_NAME="__BINARY_NAME__"
ARCHIVE_FORMAT_LINUX="__ARCHIVE_FORMAT_LINUX__"
ARCHIVE_FORMAT_DARWIN="__ARCHIVE_FORMAT_DARWIN__"
ARCHIVE_FORMAT_WINDOWS="__ARCHIVE_FORMAT_WINDOWS__"
# The template is data, not shell code. Expand its variables only in the renderer.
ARTIFACT_NAMING='__ARTIFACT_NAMING__'

# Minisign public key for signature verification (embedded from dsr config)
# If empty, signature verification is skipped
MINISIGN_PUBKEY="__MINISIGN_PUBKEY__"

# Validated source selection, embedded as data by the generator. The source
# engine below is embedded too: installed clients need no DSR checkout.
SOURCE_LANGUAGE='__SOURCE_LANGUAGE__'
SOURCE_SUBDIR='__SOURCE_SUBDIR__'
SOURCE_ENTRY='__SOURCE_ENTRY__'
SOURCE_PACKAGE='__SOURCE_PACKAGE__'

__SOURCE_BUILD_ENGINE__

# Runtime state
_VERSION=""
_INSTALL_DIR="${HOME}/.local/bin"
_JSON_MODE=false
_JSON_EMITTED=false
_VERIFY=true
_REQUIRE_SIGNATURES=false
_NON_INTERACTIVE=false
_AUTO_YES=false
_OFFLINE_ARCHIVE=""
_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/dsr/installers"
_OFFLINE_MODE=false
_PREFER_GH=false
_SKIP_SKILLS=false
_FROM_SOURCE=false
_ALLOW_SOURCE_BUILD=false
_SOURCE_REF=""
_SOURCE_TIMEOUT=3600
_SOURCE_RECEIPT=null
_SOURCE_IF_STALE=""
_RELEASE_FRESHNESS=null
_KEEP_SOURCE_LOGS=false
# Working directory created by main(). Declared at script scope so the
# EXIT trap (which fires AFTER main returns and its locals have been
# popped) can still see it and clean up. Leaving this as `local temp_dir`
# inside main() made the trap fire with an empty expansion and leak the
# tmpdir under /tmp on every install.
_TEMP_DIR=""
_cleanup_temp_dir() {
    if [[ -n "${_TEMP_DIR:-}" && -d "$_TEMP_DIR" ]]; then
        if $_KEEP_SOURCE_LOGS && [[ -d "$_TEMP_DIR/source-build" ]]; then
            _log_warn "Source build diagnostics retained at: $_TEMP_DIR/source-build"
        else
            rm -rf "$_TEMP_DIR"
        fi
    fi
}

# Colors (disable if NO_COLOR set or not a terminal)
if [[ -z "${NO_COLOR:-}" && -t 2 ]]; then
    _RED=$'\033[0;31m'
    _GREEN=$'\033[0;32m'
    _YELLOW=$'\033[0;33m'
    _BLUE=$'\033[0;34m'
    _NC=$'\033[0m'
else
    _RED='' _GREEN='' _YELLOW='' _BLUE='' _NC=''
fi

_log_info()  { echo "${_BLUE}[$TOOL_NAME]${_NC} $*" >&2; }
_log_ok()    { echo "${_GREEN}[$TOOL_NAME]${_NC} $*" >&2; }
_log_warn()  { echo "${_YELLOW}[$TOOL_NAME]${_NC} $*" >&2; }
_log_error() { echo "${_RED}[$TOOL_NAME]${_NC} $*" >&2; }

# JSON output helper
_json_result() {
    local status="$1"
    local message="$2"
    local version="${3:-}"
    local path="${4:-}"

    if $_JSON_MODE; then
        _JSON_EMITTED=true
        if command -v jq &>/dev/null; then
            jq -nc \
                --arg tool "$TOOL_NAME" \
                --arg status "$status" \
                --arg message "$message" \
                --arg version "$version" \
                --arg path "$path" \
                --argjson source_receipt "$_SOURCE_RECEIPT" \
                --argjson freshness "$_RELEASE_FRESHNESS" \
                '{tool: $tool, status: $status, message: $message, version: $version, path: $path}
                 + if $status == "success" and $source_receipt != null
                   then {method:"source", signed_release:false, source:$source_receipt} else {} end
                 + if $freshness != null then {freshness:$freshness} else {} end'
        else
            # Fallback for systems without jq - escape JSON special characters
            # Order matters: escape backslashes first, then quotes, then control chars
            _json_escape_str() {
                local s="$1"
                s="${s//\\/\\\\}"      # \ -> \\
                s="${s//\"/\\\"}"      # " -> \"
                s="${s//$'\n'/\\n}"    # newline -> \n
                s="${s//$'\t'/\\t}"    # tab -> \t
                s="${s//$'\r'/\\r}"    # carriage return -> \r
                printf '%s' "$s"
            }
            local esc_tool esc_status esc_msg esc_ver esc_path
            esc_tool=$(_json_escape_str "$TOOL_NAME")
            esc_status=$(_json_escape_str "$status")
            esc_msg=$(_json_escape_str "$message")
            esc_ver=$(_json_escape_str "$version")
            esc_path=$(_json_escape_str "$path")
            printf '{"tool":"%s","status":"%s","message":"%s","version":"%s","path":"%s"}\n' \
                "$esc_tool" "$esc_status" "$esc_msg" "$esc_ver" "$esc_path"
        fi
    fi
}

# Detect platform (OS and architecture)
_detect_platform() {
    local os arch

    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    case "$os" in
        darwin) os="darwin" ;;
        linux) os="linux" ;;
        mingw*|msys*|cygwin*) os="windows" ;;
        *) _log_error "Unsupported OS: $os"; return 1 ;;
    esac

    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7*) arch="armv7" ;;
        i386|i686) arch="386" ;;
        *) _log_error "Unsupported architecture: $arch"; return 1 ;;
    esac

    echo "$os/$arch"
}

# Get archive format for platform
_get_archive_format() {
    local platform="$1"
    local os="${platform%/*}"

    case "$os" in
        linux) echo "$ARCHIVE_FORMAT_LINUX" ;;
        darwin) echo "$ARCHIVE_FORMAT_DARWIN" ;;
        windows) echo "$ARCHIVE_FORMAT_WINDOWS" ;;
        *) echo "tar.gz" ;;
    esac
}

# ============================================================================
# CACHE FUNCTIONS
# ============================================================================

# Get cache path for a specific version/platform
_cache_path() {
    local version="$1"
    local platform="$2"
    local format="$3"
    local os="${platform%/*}"
    local arch="${platform#*/}"
    echo "${_CACHE_DIR}/${TOOL_NAME}/${version}/${os}-${arch}.${format}"
}

# Check if cached archive exists
_cache_get() {
    local version="$1"
    local platform="$2"
    local format="$3"
    local cache_file
    cache_file=$(_cache_path "$version" "$platform" "$format")

    if [[ -f "$cache_file" && ! -L "$cache_file" && -s "$cache_file" ]]; then
        _log_info "Using cached archive: $cache_file"
        echo "$cache_file"
        return 0
    fi
    return 1
}

# Save only verified bytes and their evidence. Each file is atomically replaced;
# interrupted or concurrent updates can cause a verification failure, not a bypass.
_cache_put() (
    local src_file="$1"
    local version="$2"
    local platform="$3"
    local format="$4"
    local cache_file
    cache_file=$(_cache_path "$version" "$platform" "$format")
    local cache_dir
    cache_dir=$(dirname "$cache_file")

    mkdir -p "$cache_dir" || return 1
    [[ ! -L "$cache_dir" ]] || return 1
    local stage suffix cleanup
    stage=$(mktemp -d "$cache_dir/.verified.XXXXXXXX") || return 1
    printf -v cleanup 'rm -rf -- %q' "$stage"
    trap "$cleanup" EXIT
    for suffix in '' .sha256 .minisig; do
        if [[ "$suffix" == .minisig && ! -f "$src_file$suffix" ]]; then
            continue
        fi
        [[ -f "$src_file$suffix" && ! -L "$src_file$suffix" ]] || return 1
        cp -- "$src_file$suffix" "$stage/payload$suffix" || return 1
    done
    for suffix in .sha256 .minisig ''; do
        [[ -f "$stage/payload$suffix" ]] || continue
        [[ ! -L "$cache_file$suffix" && ( ! -e "$cache_file$suffix" || -f "$cache_file$suffix" ) ]] || return 1
        mv -f -- "$stage/payload$suffix" "$cache_file$suffix" || return 1
    done
    _log_info "Cached verified archive: $cache_file"
)

# Copy evidence alongside staged bytes; never follow a supplied sidecar symlink.
_copy_local_archive() {
    local source="$1" destination="$2" suffix
    [[ -f "$source" && ! -L "$source" && -s "$source" ]] || return 1
    cp -- "$source" "$destination" || return 1
    for suffix in .sha256 .minisig; do
        if [[ -e "$source$suffix" || -L "$source$suffix" ]]; then
            [[ -f "$source$suffix" && ! -L "$source$suffix" ]] || return 1
            cp -- "$source$suffix" "$destination$suffix" || return 1
        fi
    done
}

# ============================================================================
# ARTIFACT NAMING
# ============================================================================

_has_known_ext() {
    local name="$1"
    case "$name" in
        *.tar.gz|*.tgz|*.tar.xz|*.zip|*.exe) return 0 ;;
        *) return 1 ;;
    esac
}

_resolve_arch_alias() {
    local arch="$1"

    case "$arch" in
__ARCH_ALIAS_CASES__
    esac

    echo "$arch"
}

_resolve_target_triple() {
    local os="$1"
    local arch="$2"

    case "${os}/${arch}" in
__TARGET_TRIPLE_CASES__
    esac

    case "${os}/${arch}" in
        linux/amd64) echo "x86_64-unknown-linux-gnu" ;;
        linux/arm64) echo "aarch64-unknown-linux-gnu" ;;
        darwin/amd64) echo "x86_64-apple-darwin" ;;
        darwin/arm64) echo "aarch64-apple-darwin" ;;
        windows/amd64) echo "x86_64-pc-windows-msvc" ;;
        windows/arm64) echo "aarch64-pc-windows-msvc" ;;
        *) echo "${os}-${arch}" ;;
    esac
}

_apply_artifact_pattern() {
    local pattern="$1"
    local os="$2"
    local arch="$3"
    local version_num="$4"
    local format="$5"
    [[ "$format" != none ]] || format=""

    local name="$pattern"
    local arch_alias
    arch_alias=$(_resolve_arch_alias "$arch")
    local target="${os}-${arch_alias}"
    local target_triple
    target_triple=$(_resolve_target_triple "$os" "$arch")

    name="${name//\$\{name\}/$TOOL_NAME}"
    name="${name//\$\{binary\}/$BINARY_NAME}"
    name="${name//\$\{version\}/$version_num}"
    name="${name//\$\{os\}/$os}"
    name="${name//\$\{arch\}/$arch_alias}"
    name="${name//\$\{target\}/$target}"
    name="${name//\$\{TARGET\}/$target}"
    name="${name//\$\{target_triple\}/$target_triple}"
    name="${name//\$\{TARGET_TRIPLE\}/$target_triple}"

    if [[ "$pattern" == *'${ext}'* || "$pattern" == *'${EXT}'* ]]; then
        if [[ -z "$format" ]]; then
            name="${name//\.\$\{ext\}/}"
            name="${name//\.\$\{EXT\}/}"
        fi
        name="${name//\$\{ext\}/$format}"
        name="${name//\$\{EXT\}/$format}"
        echo "$name"
        return 0
    fi

    if _has_known_ext "$name"; then
        echo "$name"
        return 0
    fi

    if [[ -n "$format" ]]; then echo "${name}.${format}"; else echo "$name"; fi
}

# ============================================================================
# GH CLI DOWNLOAD
# ============================================================================

# Fetch one exact asset for payloads AND their checksum/signature sidecars.
# Transport fallback happens here, before verification, never after it fails.
_fetch_release_asset() {
    local asset="$1" dest="$2" url
    $_OFFLINE_MODE && return 1
    [[ "$asset" =~ ^[A-Za-z0-9._+-]+$ && "$asset" != . && "$asset" != .. ]] || return 4
    url="https://github.com/$REPO/releases/download/$_VERSION/${asset//+/%2B}"
    if $_PREFER_GH && command -v gh &>/dev/null; then
        if gh release download "$_VERSION" --repo "$REPO" --pattern "$asset" --output "$dest" --clobber 2>/dev/null &&
           [[ -f "$dest" && ! -L "$dest" && -s "$dest" ]]; then
            return 0
        fi
    fi
    if command -v curl &>/dev/null &&
       curl -sSfL --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 300 \
           --retry 2 "$url" -o "$dest" 2>/dev/null && [[ -f "$dest" && ! -L "$dest" && -s "$dest" ]]; then
        return 0
    fi
    if ! $_PREFER_GH && command -v gh &>/dev/null; then
        if gh release download "$_VERSION" --repo "$REPO" --pattern "$asset" --output "$dest" --clobber 2>/dev/null &&
           [[ -f "$dest" && ! -L "$dest" && -s "$dest" ]]; then
            return 0
        fi
    fi
    return 1
}

# A tag becomes one URL and cache-path component; never accept API null,
# multiple results, redirects to other repositories, or path/query syntax.
_valid_release_version() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ && "$1" != null ]]
}

# Use authenticated discovery for private repos and an API-independent public
# redirect when the releases API is throttled. Never guess a tag from a date.
_get_latest_version() {
    local api_url="https://api.github.com/repos/$REPO/releases/latest"
    local response version="" effective prefix="https://github.com/$REPO/releases/tag/"
    $_OFFLINE_MODE && return 4
    if $_PREFER_GH && command -v gh &>/dev/null; then
        if version=$(gh release view --repo "$REPO" --json tagName --jq '.tagName' 2>/dev/null) &&
           _valid_release_version "$version"; then
            printf '%s\n' "$version"; return 0
        fi
    fi
    if command -v curl &>/dev/null; then
        if response=$(curl -sSfL --proto '=https' --proto-redir '=https' --connect-timeout 10 \
            --max-time 30 "$api_url" 2>/dev/null); then
            if command -v jq &>/dev/null; then
                version=$(jq -er -s 'if length == 1 and (.[0].tag_name | type == "string")
                    then .[0].tag_name else error("invalid release") end' <<< "$response" 2>/dev/null) || version=""
                if _valid_release_version "$version"; then
                    printf '%s\n' "$version"; return 0
                fi
            fi
        fi
        # HEAD follows only HTTPS redirects. Pin the final owner/repo and tag
        # route rather than accepting a login page, another repo, or /latest.
        if effective=$(curl -sSfIL --proto '=https' --proto-redir '=https' --max-redirs 5 \
            --connect-timeout 10 --max-time 30 -o /dev/null -w '%{url_effective}' \
            "https://github.com/$REPO/releases/latest" 2>/dev/null) && [[ "$effective" == "$prefix"* ]]; then
            version="${effective#"$prefix"}"
            version="${version//%2B/+}"; version="${version//%2b/+}"
            if _valid_release_version "$version"; then
                _log_info "Resolved latest release without the GitHub API: $version"
                printf '%s\n' "$version"; return 0
            fi
        fi
    fi
    if ! $_PREFER_GH && command -v gh &>/dev/null; then
        if version=$(gh release view --repo "$REPO" --json tagName --jq '.tagName' 2>/dev/null) &&
           _valid_release_version "$version"; then
            printf '%s\n' "$version"; return 0
        fi
    fi
    _log_error "Cannot resolve latest release; use --version with an existing release tag"
    return 1
}

# Accept exactly one SHA256 record for the RELEASE name, not the staging name.
# Hash-only sidecars are allowed only when fetched as <asset>.sha256.
_checksum_expected() {
    local manifest="$1" asset="$2" hash_only="${3:-false}"
    [[ -f "$manifest" && ! -L "$manifest" && -s "$manifest" ]] || return 1
    LC_ALL=C awk -v name="$asset" -v bare="$hash_only" '
        { sub(/\r$/, "") }
        /^[[:space:]]*$/ || /^#/ { next }
        {
            records++
            hash=substr($0,1,64); sep=substr($0,65,2); file=substr($0,67)
            if ((sep == "  " || sep == " *") && file == name) {
                count++; value=hash
                if (length(hash) != 64 || hash !~ /^[0-9a-fA-F]+$/) bad=1
            }
            if (bare == "true" && length($0) == 64 && $0 ~ /^[0-9a-fA-F]+$/) {
                raw++; value=$0
            }
        }
        END {
            if (!bad && ((count == 1 && raw == 0) || (count == 0 && raw == 1 && records == 1)))
                print tolower(value)
            else exit 1
        }' "$manifest"
}

# Hash stdin so filename quoting from sha256sum/shasum cannot alter the digest.
_file_sha256() {
    local result
    if command -v sha256sum &>/dev/null; then
        result=$(sha256sum < "$1") || return 1
    elif command -v shasum &>/dev/null; then
        result=$(shasum -a 256 < "$1") || return 1
    else
        _log_error "sha256sum or shasum is required"
        return 3
    fi
    result="${result%% *}"
    [[ "$result" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$result"
}

# Check every acquisition path; write normalized evidence only after a match.
_verify_checksum() {
    local file="$1" asset="$2" expected actual candidate manifest hash_only=false
    manifest="$file.sha256"
    if [[ -e "$manifest" || -L "$manifest" ]]; then
        expected=$(_checksum_expected "$manifest" "$asset" true) || {
            _log_error "Invalid local checksum evidence for $asset"; return 1;
        }
    else
        if $_OFFLINE_MODE; then
            _log_error "Offline archive requires a .sha256 sidecar for $asset"
            return 1
        fi
        manifest="$file.checksums.download"
        local found=false
        for candidate in "$asset.sha256" checksums.sha256 \
            "${TOOL_NAME}-${_VERSION#v}-SHA256SUMS.txt" SHA256SUMS.txt checksums.txt; do
            if _fetch_release_asset "$candidate" "$manifest"; then
                found=true
                [[ "$candidate" != "$asset.sha256" ]] || hash_only=true
                break
            fi
        done
        if ! $found; then
            _log_error "No release checksums available for $asset"
            return 1
        fi
        expected=$(_checksum_expected "$manifest" "$asset" "$hash_only") || {
            _log_error "Checksum manifest must contain exactly one valid entry for $asset"; return 1;
        }
    fi
    actual=$(_file_sha256 "$file") || return $?
    if [[ "$actual" != "$expected" ]]; then
        _log_error "Checksum mismatch for $asset"
        return 1
    fi
    printf '%s  %s\n' "$expected" "$asset" > "$file.sha256" || return 1
    _log_ok "Checksum verified: $asset"
}

# A configured key is a trust requirement, including cached and offline bytes.
# Missing signatures/tools never silently downgrade a signed installer.
_verify_minisign() {
    local file="$1"
    local asset="$2"

    # Skip if no public key configured
    # Do not repeat the full placeholder here: generation would replace both
    # sides of that comparison and silently disable every configured key.
    if [[ -z "$MINISIGN_PUBKEY" || "$MINISIGN_PUBKEY" == __MINISIGN_* ]]; then
        if $_REQUIRE_SIGNATURES; then
            _log_error "Signature verification required but no public key configured"
            return 1
        fi
        return 0
    fi

    if ! command -v minisign &>/dev/null; then
        _log_error "minisign required for the configured signing key but not installed"
        return 3
    fi

    local sig_file="${file}.minisig"
    if [[ ! -e "$sig_file" && ! -L "$sig_file" ]]; then
        _fetch_release_asset "$asset.minisig" "$sig_file" || {
            _log_error "Signature unavailable for $asset"; return 1;
        }
    fi
    [[ -f "$sig_file" && ! -L "$sig_file" && -s "$sig_file" ]] || return 1

    # Create temp file for public key
    local pubkey_file
    pubkey_file="${file}.pubkey"
    printf '%s\n' "$MINISIGN_PUBKEY" > "$pubkey_file" || return 1

    # Verify
    _log_info "Verifying signature..."
    local key_args=(-p "$pubkey_file")
    [[ "$MINISIGN_PUBKEY" == *$'\n'* ]] || key_args=(-P "$MINISIGN_PUBKEY")
    if minisign -Vm "$file" "${key_args[@]}" -x "$sig_file" >/dev/null 2>&1; then
        _log_ok "Signature verified"
        return 0
    else
        _log_error "Signature verification FAILED!"
        _log_error "The file may have been tampered with."
        return 1
    fi
}

# Validate both paths and entry types before extracting any bytes. The private
# extraction directory is new, so no pre-existing links can redirect writes.
_extract_archive() {
    local archive="$1"
    local dest_dir="$2"
    local format="$3" members listing member line count=0 types=0 untyped=false
    [[ -f "$archive" && ! -L "$archive" && -s "$archive" && ! -e "$dest_dir" && ! -L "$dest_dir" ]] || return 1
    local tar_args=()
    case "$format" in
        none|exe)
            mkdir -- "$dest_dir" || return 1
            cp -- "$archive" "$dest_dir/$BINARY_NAME" || return 1
            return 0 ;;
        tar.gz|tgz) tar_args=(-z) ;;
        tar.xz) tar_args=(-J) ;;
        tar) ;;
        zip) command -v unzip &>/dev/null || return 3 ;;
        *) return 4 ;;
    esac
    if [[ "$format" == zip ]]; then
        members=$(unzip -Z1 "$archive" 2>/dev/null) || return 1
        listing=$(LC_ALL=C unzip -Z -l "$archive" 2>/dev/null) || return 1
    else
        members=$(tar "${tar_args[@]}" -tf "$archive" 2>/dev/null) || return 1
        listing=$(LC_ALL=C tar "${tar_args[@]}" -tvf "$archive" 2>/dev/null) || return 1
    fi
    [[ -n "$members" ]] || return 1
    local -A seen=()
    while IFS= read -r member; do
        count=$((count + 1))
        [[ "$member" != /* && "$member" != *[[:cntrl:]]* && "$member" != *\\* && "$member" != *:* ]] || return 1
        while [[ "$member" == ./* ]]; do member="${member#./}"; done
        member="${member%/}"
        [[ -n "$member" && "$member" != . ]] || continue
        [[ "$member" != -* ]] || return 1
        case "/$member/" in *'/../'*|*'/./'*|*'//'*) return 1 ;; esac
        [[ -z "${seen[$member]:-}" ]] || { _log_error "Duplicate archive member: $member"; return 1; }
        seen["$member"]=1
    done <<< "$members"
    while IFS= read -r line; do
        if [[ "$format" == zip ]]; then
            case "$line" in 'Archive: '*|'Zip file size: '*) continue ;; esac
            [[ "$line" =~ ^[0-9]+[[:space:]]files?, ]] && continue
        fi
        case "${line:0:1}" in
            -|d) types=$((types + 1)) ;;
            '?')
                [[ "$format" == zip ]] || return 1
                untyped=true; types=$((types + 1)) ;;
            *) _log_error "Archive contains a link, special file, or unrecognized entry"; return 1 ;;
        esac
    done <<< "$listing"
    [[ "$count" -eq "$types" ]] || return 1
    if $untyped; then
        # ZIP writers may record permissions but omit S_IFREG (Python's
        # writestr does this). Accept zero type bits, not arbitrary unknown
        # types, and require an attribute record for every entry.
        local attributes=0 mode
        listing=$(LC_ALL=C unzip -Z -v "$archive" 2>/dev/null) || return 1
        while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]+Unix\ file\ attributes\ \(([0-7]{6})\ octal\) ]]; then
                mode=$((8#${BASH_REMATCH[1]} & 0170000))
                ((mode == 0 || mode == 0100000 || mode == 0040000)) || return 1
                attributes=$((attributes + 1))
            fi
        done <<< "$listing"
        [[ "$attributes" -eq "$count" ]] || return 1
    fi
    mkdir -- "$dest_dir" || return 1
    if [[ "$format" == zip ]]; then
        unzip -q "$archive" -d "$dest_dir" || return 1
    else
        tar "${tar_args[@]}" --no-same-owner --no-same-permissions -xf "$archive" -C "$dest_dir" || return 1
    fi
}

# Stage in the destination filesystem, compare bytes, set final permissions,
# then rename. A failed copy/chmod/rename must leave an existing binary intact.
_install_binary() (
    local src_binary="$1"
    local dest_dir="$2"

    local dest_binary="$dest_dir/$BINARY_NAME"

    [[ -f "$src_binary" && ! -L "$src_binary" && -s "$src_binary" && ! -L "$dest_dir" ]] || return 1
    mkdir -p -- "$dest_dir" || return 1
    [[ ! -L "$dest_binary" && ( ! -e "$dest_binary" || -f "$dest_binary" ) ]] || {
        _log_error "Refusing a linked or non-regular install destination: $dest_binary"; return 1;
    }

    # Check if binary already exists
    if [[ -f "$dest_binary" ]]; then
        if ! $_AUTO_YES; then
            if $_NON_INTERACTIVE; then
                _log_error "Binary already exists at $dest_binary"
                _log_info "Use --yes to overwrite or remove it manually"
                return 1
            fi

            _log_warn "Binary already exists: $dest_binary"
            read -rp "Overwrite? [y/N] " response || return 1
            if [[ ! "$response" =~ ^[yY] ]]; then
                _log_info "Installation cancelled"
                return 1
            fi
        fi
    fi

    local stage cleanup expected actual
    expected=$(_file_sha256 "$src_binary") || return $?
    stage=$(mktemp -d "$dest_dir/.${BINARY_NAME}.install.XXXXXXXX") || return 1
    printf -v cleanup 'rm -rf -- %q' "$stage"
    trap "$cleanup" EXIT
    trap 'exit 5' HUP INT TERM
    cp -- "$src_binary" "$stage/payload" || return 1
    chmod 755 "$stage/payload" || return 1
    actual=$(_file_sha256 "$stage/payload") || return $?
    [[ "$actual" == "$expected" ]] || return 1
    [[ ! -L "$dest_binary" && ( ! -e "$dest_binary" || -f "$dest_binary" ) ]] || return 1
    mv -f -- "$stage/payload" "$dest_binary" || return 1
    [[ -f "$dest_binary" && ! -L "$dest_binary" && -x "$dest_binary" ]] || return 1
    [[ "$(_file_sha256 "$dest_binary")" == "$expected" ]] || return 1

    _log_ok "Installed to: $dest_binary"

    # Check if in PATH
    if [[ ":$PATH:" != *":$dest_dir:"* ]]; then
        _log_warn "$dest_dir is not in your PATH"
        _log_info "Add to your shell config:"
        _log_info "  export PATH=\"\$PATH:$dest_dir\""
    fi

    return 0
)

# ============================================================================
# SKILL INSTALLATION
# ============================================================================

# Skill archive is embedded at generation time as a gzip-compressed tarball
# encoded in base64 so multi-file skill trees can be restored on install.
# If this placeholder was not replaced, skill installation is skipped.
_SKILL_ARCHIVE_B64='__SKILL_ARCHIVE_B64__'

# Decode skill archive at runtime
_decode_skill_archive() {
    # Skip if placeholder wasn't replaced (check for literal __ prefix)
    if [[ "$_SKILL_ARCHIVE_B64" == _* ]]; then
        return 1
    fi
    if [[ -n "$_SKILL_ARCHIVE_B64" ]] && command -v base64 &>/dev/null; then
        # macOS uses -D, Linux uses -d
        base64 -d 2>/dev/null <<< "$_SKILL_ARCHIVE_B64" || base64 -D 2>/dev/null <<< "$_SKILL_ARCHIVE_B64"
    fi
}

_install_skill_archive_to_dir() {
    local skill_dir="$1"
    local stage_dir=""

    stage_dir="$(mktemp -d 2>/dev/null || true)"
    if [[ -z "$stage_dir" || ! -d "$stage_dir" ]]; then
        _log_warn "Failed to create temporary directory for skill installation"
        return 1
    fi

    # Pre-validate the archive listing before extracting.  Skill
    # content is publisher-controlled, but a compromised release
    # tarball could contain absolute paths, ".." traversal entries,
    # or symlinks that escape $stage_dir during extraction (or worse,
    # during the subsequent `cp -R "$stage_dir/." "$skill_dir/"`
    # which faithfully recreates symlinks under ~/.claude/).  Reject
    # any entry whose name starts with `/`, contains `../`, or whose
    # type-flag indicates a symlink/hardlink.  Then extract with the
    # safest tar flags available on both GNU and BSD tar.
    local listing=""
    listing=$(_decode_skill_archive | tar -tzf - 2>/dev/null) || {
        rm -rf "$stage_dir" 2>/dev/null || true
        _log_warn "Failed to read embedded skill archive"
        return 1
    }
    if printf '%s\n' "$listing" | grep -E '^/|(^|/)\.\.(/|$)' >/dev/null 2>&1; then
        rm -rf "$stage_dir" 2>/dev/null || true
        _log_warn "Skill archive contains unsafe path entries; refusing to extract"
        return 1
    fi

    if ! _decode_skill_archive | tar -xzf - \
            --no-same-owner \
            --no-same-permissions \
            -C "$stage_dir" >/dev/null 2>&1; then
        # Retry without the GNU-only flags for BSD tar (macOS).
        if ! _decode_skill_archive | tar -xzf - -C "$stage_dir" >/dev/null 2>&1; then
            rm -rf "$stage_dir" 2>/dev/null || true
            _log_warn "Failed to extract embedded skill archive"
            return 1
        fi
    fi

    # Belt-and-suspenders: walk the staged tree and reject any
    # symlinks before we copy.  Catches whatever tar didn't filter.
    if find "$stage_dir" -type l 2>/dev/null | grep -q .; then
        rm -rf "$stage_dir" 2>/dev/null || true
        _log_warn "Skill archive contains symbolic links; refusing to install"
        return 1
    fi

    if [[ ! -f "$stage_dir/SKILL.md" ]]; then
        rm -rf "$stage_dir" 2>/dev/null || true
        _log_warn "Embedded skill archive is missing SKILL.md"
        return 1
    fi

    mkdir -p "$skill_dir"
    if ! cp -R "$stage_dir/." "$skill_dir/" 2>/dev/null; then
        rm -rf "$stage_dir" 2>/dev/null || true
        _log_warn "Failed to install skill archive into $skill_dir"
        return 1
    fi

    rm -rf "$stage_dir" 2>/dev/null || true
    return 0
}

# Install skill for Claude Code
# Returns 0 if skill was installed, 1 if skipped
_install_claude_skill() {
    local skill_dir="${HOME}/.claude/skills/${TOOL_NAME}"

    # Check if Claude Code is installed
    if [[ ! -d "${HOME}/.claude" ]] && ! command -v claude &>/dev/null; then
        return 1  # Claude Code not installed, skip silently
    fi

    if [[ "$_SKILL_ARCHIVE_B64" != _* ]] && [[ -n "$_SKILL_ARCHIVE_B64" ]]; then
        _log_info "Installing Claude Code skill..."
        if _install_skill_archive_to_dir "$skill_dir"; then
            _log_ok "Claude Code skill installed: $skill_dir/SKILL.md"
            return 0
        fi
    fi

    return 1  # No skill archive, skip
}

# Install skill for Codex CLI
# Returns 0 if skill was installed, 1 if skipped
_install_codex_skill() {
    local skill_dir="${HOME}/.codex/skills/${TOOL_NAME}"

    # Check if Codex CLI is installed
    if [[ ! -d "${HOME}/.codex" ]] && ! command -v codex &>/dev/null; then
        return 1  # Codex CLI not installed, skip silently
    fi

    if [[ "$_SKILL_ARCHIVE_B64" != _* ]] && [[ -n "$_SKILL_ARCHIVE_B64" ]]; then
        _log_info "Installing Codex CLI skill..."
        if _install_skill_archive_to_dir "$skill_dir"; then
            _log_ok "Codex CLI skill installed: $skill_dir/SKILL.md"
            return 0
        fi
    fi

    return 1  # No skill archive, skip
}

# Install skills for all detected AI coding agents
_install_skills() {
    if $_SKIP_SKILLS; then
        _log_info "Skipping skill installation (--no-skills)"
        return 0
    fi

    # Check if skill archive is available before announcing anything
    if [[ "$_SKILL_ARCHIVE_B64" == _* ]] || [[ -z "$_SKILL_ARCHIVE_B64" ]]; then
        return 0  # No skill archive embedded, skip silently
    fi

    local installed_any=false

    # Try Claude Code
    if _install_claude_skill; then
        installed_any=true
    fi

    # Try Codex CLI
    if _install_codex_skill; then
        installed_any=true
    fi

    if $installed_any; then
        echo "" >&2
        _log_info "AI coding agent skills installed for ${TOOL_NAME}"
        _log_info ""
        _log_info "Skills teach AI agents about ${TOOL_NAME}'s commands and workflows."
        _log_info "To use: type /${TOOL_NAME} in Claude Code or Codex CLI conversations."
        echo "" >&2
    fi

    return 0
}

# Source fallback is deliberately separate from artifact verification. Only
# discovery/acquisition failures may call this path; a bad checksum, signature,
# archive, cache entry, or install must terminate the original release path.
_install_from_source() {
    local reason="$1" ref="${_SOURCE_REF:-}" receipt payload actual installed_path
    if ! $_ALLOW_SOURCE_BUILD || $_OFFLINE_MODE || $_REQUIRE_SIGNATURES; then
        _log_error "Source fallback requires --allow-source-build (or --from-source), online mode, and no --require-signatures"
        return 4
    fi
    if [[ -z "$ref" ]]; then
        if [[ -n "$_VERSION" ]]; then ref="refs/tags/$_VERSION"; else ref=HEAD; fi
    fi
    _log_warn "$reason; source builds execute repository and dependency code"
    _log_warn "Building $REPO at $ref locally; this is NOT a signed release"
    if [[ -z "$_TEMP_DIR" ]]; then
        _TEMP_DIR=$(mktemp -d) || return 1
        # macOS /var and user TMPDIR aliases may be symlinks. Match the source
        # engine's physical paths rather than rejecting its valid receipt.
        _TEMP_DIR=$(cd "$_TEMP_DIR" && pwd -P) || return 1
        trap _cleanup_temp_dir EXIT
    fi
    local args=(--allow-build --subdir "$SOURCE_SUBDIR" --timeout "$_SOURCE_TIMEOUT")
    [[ -z "$SOURCE_ENTRY" ]] || args+=(--entry "$SOURCE_ENTRY")
    [[ -z "$SOURCE_PACKAGE" ]] || args+=(--package "$SOURCE_PACKAGE")
    _KEEP_SOURCE_LOGS=true
    receipt=$(install_source_build "$REPO" "$ref" "$SOURCE_LANGUAGE" "$BINARY_NAME" \
        "$_TEMP_DIR/source-build" "${args[@]}") || return $?
    # Consume a single complete receipt and recheck the selected payload. Do
    # not let compiler stdout become success JSON or a different install path.
    if ! jq -es --arg repo "$REPO" --arg ref "$ref" --arg language "$SOURCE_LANGUAGE" '
        length == 1 and (.[0] | type == "object" and .schema_version == 1 and
        .method == "source" and .signed_release == false and
        .repository == $repo and .requested_ref == $ref and .language == $language and
        (.source_commit | type == "string" and test("^([0-9a-f]{40}|[0-9a-f]{64})$")) and
        (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
        (.size_bytes | type == "number" and floor == . and . > 0) and
        (.compiler | type == "string" and length > 0) and (.path | type == "string"))
    ' <<< "$receipt" >/dev/null 2>&1; then
        _log_error "Invalid source build receipt"
        return 6
    fi
    payload=$(jq -r '.path' <<< "$receipt") || return 6
    [[ "$payload" == "$_TEMP_DIR/source-build/output/"* ]] || return 6
    _isb_path_in_tree "$_TEMP_DIR/source-build/output" "${payload#"$_TEMP_DIR/source-build/output/"}" || return 6
    actual=$(_file_sha256 "$payload") || return $?
    [[ "$actual" == "$(jq -r '.sha256' <<< "$receipt")" ]] || return 6
    [[ "$(wc -c < "$payload" | tr -d '[:space:]')" == "$(jq -r '.size_bytes' <<< "$receipt")" ]] || return 6
    _install_binary "$payload" "$_INSTALL_DIR" || return $?
    installed_path="$_INSTALL_DIR/$BINARY_NAME"
    [[ "$(_file_sha256 "$installed_path")" == "$actual" ]] || return 6
    # The public receipt must not point at a temporary payload removed on exit.
    _SOURCE_RECEIPT=$(jq -c 'del(.path)' <<< "$receipt") || return 6
    _KEEP_SOURCE_LOGS=false
    _install_skills
    _log_ok "Installed local source build at commit $(jq -r '.source_commit' <<< "$receipt")"
    _json_result success "Installed from source (not a signed release)" "$_VERSION" "$installed_path"
}

# Main installation function
main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -v|--version)
                [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || return 4
                _VERSION="$2"
                shift 2
                ;;
            -d|--dir)
                [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || return 4
                _INSTALL_DIR="$2"
                shift 2
                ;;
            --verify)
                _VERIFY=true
                shift
                ;;
            --require-signatures)
                _REQUIRE_SIGNATURES=true
                _VERIFY=true
                shift
                ;;
            --json)
                _JSON_MODE=true
                shift
                ;;
            --non-interactive)
                _NON_INTERACTIVE=true
                shift
                ;;
            -y|--yes)
                _AUTO_YES=true
                shift
                ;;
            --offline)
                _OFFLINE_MODE=true
                # --offline alone means cache-only mode
                # --offline <path> means use explicit archive
                if [[ "${2:-}" =~ ^- ]] || [[ -z "${2:-}" ]]; then
                    _OFFLINE_MODE=true
                    shift
                else
                    _OFFLINE_ARCHIVE="$2"
                    shift 2
                fi
                ;;
            --cache-dir)
                [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || return 4
                _CACHE_DIR="$2"
                shift 2
                ;;
            --prefer-gh)
                _PREFER_GH=true
                shift
                ;;
            --from-source)
                _FROM_SOURCE=true
                _ALLOW_SOURCE_BUILD=true
                shift
                ;;
            --allow-source-build)
                _ALLOW_SOURCE_BUILD=true
                shift
                ;;
            --source-ref|--source-timeout|--source-if-stale)
                [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || return 4
                case "$1" in
                    --source-ref) _SOURCE_REF="$2" ;;
                    --source-timeout) _SOURCE_TIMEOUT="$2" ;;
                    --source-if-stale) _SOURCE_IF_STALE="$2" ;;
                esac
                shift 2
                ;;
            --no-skills)
                _SKIP_SKILLS=true
                shift
                ;;
            --help|-h)
                grep '^#' "$0" | grep -v '^#!/' | sed 's/^# //' | sed 's/^#//'
                return 0
                ;;
            *)
                _log_error "Unknown option: $1"
                return 4
                ;;
        esac
    done

    [[ "$_SOURCE_TIMEOUT" =~ ^[1-9][0-9]{0,4}$ ]] || return 4
    if [[ -n "$_SOURCE_IF_STALE" ]]; then
        if [[ ! "$_SOURCE_IF_STALE" =~ ^(0|[1-9][0-9]{0,5})$ || -n "$_VERSION" ]] ||
           ! $_ALLOW_SOURCE_BUILD || $_FROM_SOURCE; then
            _log_error "--source-if-stale needs --allow-source-build, a nonnegative integer, and latest-release mode (no --version or --from-source)"
            return 4
        fi
        command -v jq >/dev/null 2>&1 || return 3
    fi
    if [[ -n "$_SOURCE_REF" ]] && { ! $_FROM_SOURCE || [[ -n "$_VERSION" ]]; }; then
        _log_error "--source-ref requires --from-source and cannot be combined with --version"
        return 4
    fi
    if $_ALLOW_SOURCE_BUILD && { $_OFFLINE_MODE || $_REQUIRE_SIGNATURES; }; then
        _log_error "Source builds cannot satisfy --offline or --require-signatures"
        return 4
    fi
    if [[ -n "$_VERSION" ]] && ! _valid_release_version "$_VERSION"; then
        _log_error "Invalid release version"
        return 4
    fi

    # Detect platform
    local platform
    platform=$(_detect_platform) || return $?
    _log_info "Platform: $platform"

    if [[ ! "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ||
          ! "$TOOL_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ||
          ! "$BINARY_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
        _log_error "Invalid installer identity"
        return 4
    fi
    if $_FROM_SOURCE; then
        _install_from_source "Explicit --from-source request"
        return $?
    fi
    # Get version
    if [[ -z "$_VERSION" ]]; then
        if $_OFFLINE_MODE; then
            _log_error "Offline installation requires --version; latest cannot be resolved without network"
            return 4
        fi
        _log_info "Fetching latest version..."
        local discovery_status=0
        _VERSION=$(_get_latest_version) || discovery_status=$?
        if ((discovery_status != 0)); then
            _VERSION=""
            if $_ALLOW_SOURCE_BUILD; then
                _install_from_source "Latest release could not be resolved"
                return $?
            fi
            return "$discovery_status"
        fi
    fi
    # These values become URL/path components, never shell or glob patterns.
    if ! _valid_release_version "$_VERSION"; then
        _log_error "Invalid release version"
        return 4
    fi
    _log_info "Version: $_VERSION"

    # Get archive format
    local format
    format=$(_get_archive_format "$platform")
    case "$format" in tar.gz|tgz|tar.xz|zip|tar|none|exe) ;; *) return 4 ;; esac
    local asset_name
    asset_name=$(_apply_artifact_pattern "$ARTIFACT_NAMING" "${platform%/*}" \
        "${platform#*/}" "${_VERSION#v}" "$format") || return $?
    [[ "$asset_name" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]] || {
        _log_error "Unresolved or unsafe release asset name: $asset_name"; return 4;
    }

    # Create temp directory. _TEMP_DIR is a script-scope global so the
    # EXIT trap can still see it after main() returns and locals are
    # popped.
    _TEMP_DIR=$(mktemp -d) || return 1
    _TEMP_DIR=$(cd "$_TEMP_DIR" && pwd -P) || return 1
    trap _cleanup_temp_dir EXIT
    local temp_dir="$_TEMP_DIR"

    local archive_file="$temp_dir/${TOOL_NAME}.${format}"
    local extract_dir="$temp_dir/extracted"

    # Acquisition has no authority to skip verification.
    if [[ -n "$_OFFLINE_ARCHIVE" ]]; then
        _copy_local_archive "$_OFFLINE_ARCHIVE" "$archive_file" || return $?
        _log_info "Using offline archive: $_OFFLINE_ARCHIVE"
    else
        # Check cache first
        local cached_file
        if cached_file=$(_cache_get "$_VERSION" "$platform" "$format"); then
            _copy_local_archive "$cached_file" "$archive_file" || return $?
        elif $_OFFLINE_MODE; then
            # Offline mode requires cache hit
            _log_error "Offline mode: no cached archive for $TOOL_NAME $_VERSION ($platform)"
            _log_info "Cache location: $_CACHE_DIR/$TOOL_NAME/$_VERSION/"
            _log_info "Download first without --offline flag"
            _json_result "error" "No cached archive available" "$_VERSION" ""
            return 1
        else
            if ! _fetch_release_asset "$asset_name" "$archive_file"; then
                if $_ALLOW_SOURCE_BUILD; then
                    _install_from_source "Release payload unavailable for $platform"
                    return $?
                fi
                _log_error "Failed to download archive"
                _json_result "error" "Download failed" "$_VERSION" ""
                return 1
            fi

        fi
    fi

    _verify_checksum "$archive_file" "$asset_name" || return $?
    _verify_minisign "$archive_file" "$asset_name" || return $?
    # Extract
    _log_info "Extracting..."
    _extract_archive "$archive_file" "$extract_dir" "$format" || return $?

    # Find binary
    local binary_path candidates
    candidates=$(find "$extract_dir" -type f \( -name "$BINARY_NAME" -o -name "${BINARY_NAME}.exe" \) -print) || return 1
    if [[ -z "$candidates" || "$candidates" == *$'\n'* ]]; then
        _log_error "Archive must contain exactly one matching binary"
        return 1
    fi
    binary_path="$candidates"
    # A stale-release policy must NEVER launder a bad artifact into a source
    # build. Check it only after integrity, extraction and binary selection.
    if [[ -n "$_SOURCE_IF_STALE" ]]; then
        local freshness_args=() freshness_status=0
        $_PREFER_GH && freshness_args+=(--prefer-gh)
        _RELEASE_FRESHNESS=$(install_source_freshness "$REPO" "$_VERSION" "$_SOURCE_IF_STALE" \
            "$temp_dir/freshness" "${freshness_args[@]}") || freshness_status=$?
        [[ "$freshness_status" != 5 ]] || return 5
        if ((freshness_status != 0)); then
            _RELEASE_FRESHNESS=$(jq -nc --arg tag "$_VERSION" \
                '{status:"unknown", release_version:$tag, reason:"freshness check unavailable"}') || return 1
        fi
        case "$(jq -r '.status' <<< "$_RELEASE_FRESHNESS")" in
            stale)
                _SOURCE_REF=$(jq -r '.head_commit' <<< "$_RELEASE_FRESHNESS") || return 1
                _log_warn "Release $_VERSION is $(jq -r '.commits_behind' <<< "$_RELEASE_FRESHNESS") commits behind the observed default branch"
                # The selected head is newer than the release; do not label it
                # with the old version or resolve a moving branch a second time.
                _VERSION=""
                _install_from_source "Explicit stale-release policy selected pinned revision $_SOURCE_REF"
                return $?
                ;;
            unknown) _log_warn "Freshness unknown; keeping the verified release" ;;
            fresh) _log_info "Latest release is within the requested commit-distance threshold" ;;
            *) return 1 ;;
        esac
    fi
    if ! $_OFFLINE_MODE; then
        _cache_put "$archive_file" "$_VERSION" "$platform" "$format" || \
            _log_warn "Could not cache verified archive"
    fi

    # Install
    _install_binary "$binary_path" "$_INSTALL_DIR" || return $?

    # Install AI coding agent skills
    _install_skills

    # Verify installation
    local installed_path="$_INSTALL_DIR/$BINARY_NAME"
    if [[ -f "$installed_path" ]]; then
        local installed_version="unknown" timeout_cmd=""
        if command -v timeout &>/dev/null; then timeout_cmd=timeout
        elif command -v gtimeout &>/dev/null; then timeout_cmd=gtimeout; fi
        if [[ -n "$timeout_cmd" ]]; then
            installed_version=$("$timeout_cmd" 10 "$installed_path" --version 2>/dev/null | head -1) || installed_version="unknown"
        fi
        _log_ok "Installation complete!"
        _log_info "Version: $installed_version"

        _json_result "success" "Installation complete" "$_VERSION" "$installed_path"
        return 0
    else
        _log_error "Installation verification failed"
        _json_result "error" "Installation verification failed" "$_VERSION" ""
        return 1
    fi
}

# Emit one machine-readable result on every failure, including preflight.
for arg in "$@"; do [[ "$arg" != --json ]] || _JSON_MODE=true; done
if main "$@"; then
    :
else
    status=$?
    if ! $_JSON_EMITTED; then
        _json_result "error" "Installation failed (exit $status)" "$_VERSION" ""
    fi
    exit "$status"
fi
TEMPLATE_START
}

# ============================================================================
# GENERATOR FUNCTIONS
# ============================================================================

# Load tool config from repos.d
_install_gen_load_config() {
    local tool_name="$1"
    local config_file=""

    # Check local config first, then user config
    if [[ -f "./config/repos.d/${tool_name}.yaml" ]]; then
        config_file="./config/repos.d/${tool_name}.yaml"
    elif [[ -f "$_IG_REPOS_D/${tool_name}.yaml" ]]; then
        config_file="$_IG_REPOS_D/${tool_name}.yaml"
    fi

    if [[ -z "$config_file" || ! -f "$config_file" ]]; then
        log_error "Config not found for tool: $tool_name"
        log_info "Looked in: ./config/repos.d/ and $_IG_REPOS_D/"
        return 4
    fi

    echo "$config_file"
}

# Extract value from YAML using yq or grep fallback
_install_gen_yaml_get() {
    local file="$1"
    local key="$2"
    local default="${3:-}"

    if command -v yq &>/dev/null; then
        local value
        value=$(yq -r ".$key // \"\"" "$file" 2>/dev/null)
        if [[ -n "$value" && "$value" != "null" ]]; then
            echo "$value"
            return 0
        fi
    else
        # Grep fallback for simple keys
        local value
        value=$(grep "^${key}:" "$file" 2>/dev/null | sed 's/^[^:]*:[[:space:]]*//' | sed 's/[[:space:]]*$//')
        if [[ -n "$value" ]]; then
            echo "$value"
            return 0
        fi
    fi

    echo "$default"
}

# Generate install.sh for a single tool
install_gen_create() {
    local tool_name="${1:-}"

    if [[ -z "$tool_name" ]]; then
        log_error "Tool name required"
        log_info "Usage: install_gen_create <tool>"
        return 4
    fi

    # Load config
    local config_file
    config_file=$(_install_gen_load_config "$tool_name") || return $?
    log_info "Loading config from: $config_file"

    # Extract values
    local repo binary_name language workflow_path local_path
    local archive_linux archive_darwin archive_windows
    local artifact_naming
    local source_subdir source_entry source_package source_engine field value

    tool_name=$(_install_gen_yaml_get "$config_file" "tool_name" "$tool_name")
    repo=$(_install_gen_yaml_get "$config_file" "repo" "")
    binary_name=$(_install_gen_yaml_get "$config_file" "binary_name" "$tool_name")
    language=$(_install_gen_yaml_get "$config_file" "language" "go")
    workflow_path=$(_install_gen_yaml_get "$config_file" "workflow" ".github/workflows/release.yml")
    local_path=$(_install_gen_yaml_get "$config_file" "local_path" "")

    # Embed the source engine as code, but source-selection fields as validated
    # literals. Failure must precede creation or replacement of any installer.
    [[ -f "$_IG_SCRIPT_DIR/install_source.sh" && ! -L "$_IG_SCRIPT_DIR/install_source.sh" ]] || return 3
    # shellcheck source=./install_source.sh
    source "$_IG_SCRIPT_DIR/install_source.sh" || return 3
    source_engine=$(cat "$_IG_SCRIPT_DIR/install_source.sh") || return 3
    [[ -n "$source_engine" && "$language" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]] || return 4
    for field in source_subdir source_entry source_package; do
        value=$(_install_gen_yaml_get "$config_file" "$field" "") || return 4
        case "$value" in
            \"*\") value="${value#\"}"; value="${value%\"}" ;;
            \'*\') value="${value#\'}"; value="${value%\'}" ;;
        esac
        printf -v "$field" '%s' "$value"
    done
    source_subdir="${source_subdir:-.}"
    _isb_relative_path "$source_subdir" || return 4
    [[ -z "$source_entry" ]] || _isb_relative_path "$source_entry" || return 4
    [[ -z "$source_package" ]] || _isb_name "$source_package" || return 4
    [[ "$language" != rust || -z "$source_entry" ]] || return 4
    [[ "$language" == rust || -z "$source_package" ]] || return 4

    # Archive formats (with yq for nested keys)
    if command -v yq &>/dev/null; then
        archive_linux=$(yq -r '.archive_format.linux // "tar.gz"' "$config_file" 2>/dev/null)
        archive_darwin=$(yq -r '.archive_format.darwin // "tar.gz"' "$config_file" 2>/dev/null)
        archive_windows=$(yq -r '.archive_format.windows // "zip"' "$config_file" 2>/dev/null)
    else
        archive_linux="tar.gz"
        archive_darwin="tar.gz"
        archive_windows="zip"
    fi

    artifact_naming=$(_install_gen_yaml_get "$config_file" "artifact_naming" "")
    # Strip surrounding quotes if present
    artifact_naming="${artifact_naming#\"}"
    artifact_naming="${artifact_naming%\"}"
    artifact_naming="${artifact_naming#\'}"
    artifact_naming="${artifact_naming%\'}"

    # If no explicit artifact_naming, try to derive from workflow
    if [[ -z "$artifact_naming" && -n "$local_path" && -n "$workflow_path" ]]; then
        if ! declare -F artifact_naming_parse_workflow &>/dev/null; then
            if [[ -f "$_IG_SCRIPT_DIR/artifact_naming.sh" ]]; then
                # shellcheck source=/dev/null
                source "$_IG_SCRIPT_DIR/artifact_naming.sh" 2>/dev/null || true
            fi
        fi

        local workflow_file="$local_path/$workflow_path"
        if [[ -f "$workflow_file" ]] && declare -F artifact_naming_parse_workflow &>/dev/null; then
            local patterns_json
            patterns_json=$(artifact_naming_parse_workflow "$workflow_file" 2>/dev/null || echo "[]")
            if declare -F _an_choose_workflow_pattern &>/dev/null; then
                artifact_naming=$(_an_choose_workflow_pattern "$patterns_json")
            fi
        fi
    fi

    # Fallback: GoReleaser config if workflow doesn't yield a pattern
    if [[ -z "$artifact_naming" && -n "$local_path" && -f "$_IG_SCRIPT_DIR/artifact_naming.sh" ]]; then
        if ! declare -F artifact_naming_parse_goreleaser &>/dev/null; then
            # shellcheck source=/dev/null
            source "$_IG_SCRIPT_DIR/artifact_naming.sh" 2>/dev/null || true
        fi

        local goreleaser_file=""
        for candidate in ".goreleaser.yml" ".goreleaser.yaml" "goreleaser.yml" "goreleaser.yaml"; do
            if [[ -f "$local_path/$candidate" ]]; then
                goreleaser_file="$local_path/$candidate"
                break
            fi
        done
        if [[ -n "$goreleaser_file" ]] && declare -F artifact_naming_parse_goreleaser &>/dev/null; then
            artifact_naming=$(artifact_naming_parse_goreleaser "$goreleaser_file" 2>/dev/null || echo "")
        fi
    fi

    if [[ -z "$artifact_naming" ]]; then
        artifact_naming='${name}-${version}-${os}-${arch}'
    fi
    # This value is embedded in a shell single-quoted literal. Reject a quote
    # rather than letting configuration create executable installer code.
    if [[ "$artifact_naming" == *\'* || "$artifact_naming" == *[[:cntrl:]]* ]]; then
        log_error "Unsafe artifact_naming template"
        return 4
    fi

    # Target triple + arch alias overrides (optional)
    local target_triple_cases=""
    local arch_alias_cases=""
    if command -v yq &>/dev/null; then
        while IFS=$'\t' read -r platform triple; do
            [[ -z "$platform" || -z "$triple" || "$platform" == "null" || "$triple" == "null" ]] && continue
            target_triple_cases+=$'        '"$platform"$') echo "'"$triple"'" ;;'$'\n'
        done < <(yq -r '.target_triples // {} | to_entries[] | [.key, .value] | @tsv' "$config_file" 2>/dev/null)

        while IFS=$'\t' read -r arch alias; do
            [[ -z "$arch" || -z "$alias" || "$arch" == "null" || "$alias" == "null" ]] && continue
            arch_alias_cases+=$'        '"$arch"$') echo "'"$alias"'" ;;'$'\n'
        done < <(yq -r '.arch_aliases // {} | to_entries[] | [.key, .value] | @tsv' "$config_file" 2>/dev/null)
    fi

    # Get minisign public key (from tool config or global dsr config)
    local minisign_pubkey=""
    minisign_pubkey=$(_install_gen_yaml_get "$config_file" "minisign_pubkey" "")
    if [[ -z "$minisign_pubkey" ]]; then
        # Try global config
        local global_config="$_IG_CONFIG_DIR/config.yaml"
        if [[ -f "$global_config" ]]; then
            minisign_pubkey=$(_install_gen_yaml_get "$global_config" "signing.minisign_pubkey" "")
        fi
    fi

    # Get skill content (prefer full skill directory, then fall back to SKILL.md only)
    local skill_root=""
    local skill_file=""
    local skill_dir_candidates=(
        "./.claude/skills/${tool_name}"
        "./config/skills/${tool_name}"
    )
    local skill_file_candidates=(
        "./SKILL.md"
        "./config/skills/${tool_name}/SKILL.md"
    )
    if [[ -n "$local_path" ]]; then
        skill_dir_candidates=(
            "$local_path/.claude/skills/${tool_name}"
            "${skill_dir_candidates[@]}"
        )
        skill_file_candidates=(
            "$local_path/SKILL.md"
            "${skill_file_candidates[@]}"
        )
    fi

    local skill_candidate=""
    for skill_candidate in "${skill_dir_candidates[@]}"; do
        if [[ -f "$skill_candidate/SKILL.md" ]]; then
            skill_root="$skill_candidate"
            log_info "  Skill: $skill_candidate"
            break
        fi
    done
    if [[ -z "$skill_root" ]]; then
        for skill_candidate in "${skill_file_candidates[@]}"; do
            if [[ -f "$skill_candidate" ]]; then
                skill_file="$skill_candidate"
                log_info "  Skill: $skill_candidate"
                break
            fi
        done
    fi
    if [[ -z "$skill_root" && -z "$skill_file" ]]; then
        log_info "  Skill: (none found, skills will be skipped)"
    fi

    if [[ -z "$repo" ]]; then
        log_error "No repo defined in config"
        return 4
    fi

    log_info "Generating installer for: $tool_name"
    log_info "  Repo: $repo"
    log_info "  Binary: $binary_name"
    log_info "  Language: $language"

    # Create output directory
    local output_dir="$_IG_OUTPUT_DIR/$tool_name"
    mkdir -p "$output_dir"

    # Generate script
    local output_file="$output_dir/install.sh"
    local template
    template=$(_install_gen_template \
        "$tool_name" \
        "$repo" \
        "$binary_name" \
        "$archive_linux" \
        "$archive_darwin" \
        "$archive_windows" \
        "$artifact_naming" \
        "$language")

    # Replace placeholders
    template="${template//__TOOL_NAME__/$tool_name}"
    template="${template//__REPO__/$repo}"
    template="${template//__BINARY_NAME__/$binary_name}"
    template="${template//__ARCHIVE_FORMAT_LINUX__/$archive_linux}"
    template="${template//__ARCHIVE_FORMAT_DARWIN__/$archive_darwin}"
    template="${template//__ARCHIVE_FORMAT_WINDOWS__/$archive_windows}"
    template="${template//__ARTIFACT_NAMING__/$artifact_naming}"
    template="${template//__MINISIGN_PUBKEY__/$minisign_pubkey}"
    template="${template//__TARGET_TRIPLE_CASES__/$target_triple_cases}"
    template="${template//__ARCH_ALIAS_CASES__/$arch_alias_cases}"
    template="${template//__SOURCE_LANGUAGE__/"$language"}"
    template="${template//__SOURCE_SUBDIR__/"$source_subdir"}"
    template="${template//__SOURCE_ENTRY__/"$source_entry"}"
    template="${template//__SOURCE_PACKAGE__/"$source_package"}"
    # Quoted replacement is essential: Bash 5.2's patsub_replacement otherwise
    # treats every ampersand in the engine as the matched placeholder text.
    template="${template//__SOURCE_BUILD_ENGINE__/"$source_engine"}"

    # Handle skill content - archive the full skill tree when available
    if [[ -n "$skill_root" || -n "$skill_file" ]]; then
        local skill_archive_b64=""
        local skill_stage=""
        local archive_root=""

        if [[ -n "$skill_root" ]]; then
            archive_root="$skill_root"
        else
            skill_stage="$(mktemp -d 2>/dev/null || true)"
            if [[ -n "$skill_stage" && -d "$skill_stage" ]]; then
                cp "$skill_file" "$skill_stage/SKILL.md"
                archive_root="$skill_stage"
            fi
        fi

        if [[ -n "$archive_root" ]]; then
            skill_archive_b64="$(tar -czf - -C "$archive_root" . | base64 | tr -d '\n')"
        fi
        if [[ -n "$skill_stage" && -d "$skill_stage" ]]; then
            rm -rf "$skill_stage" 2>/dev/null || true
        fi
        if [[ -n "$skill_archive_b64" ]]; then
            template="${template//__SKILL_ARCHIVE_B64__/$skill_archive_b64}"
        fi
    fi

    echo "$template" > "$output_file"
    chmod +x "$output_file"

    log_ok "Generated: $output_file"

    # Validate with ShellCheck if available
    if command -v shellcheck &>/dev/null; then
        if shellcheck -S warning "$output_file" 2>/dev/null; then
            log_ok "ShellCheck validation passed"
        else
            log_warn "ShellCheck found issues (run: shellcheck $output_file)"
        fi
    fi

    echo "$output_file"
}

# Generate installers for all tools in repos.d
install_gen_all() {
    local config_dirs=("./config/repos.d" "$_IG_REPOS_D")
    local count=0
    local errors=0

    for dir in "${config_dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            continue
        fi

        for config_file in "$dir"/*.yaml; do
            [[ -f "$config_file" ]] || continue

            # Skip templates
            local filename
            filename=$(basename "$config_file")
            [[ "$filename" == _* ]] && continue

            local tool_name="${filename%.yaml}"
            log_info "Processing: $tool_name"

            if install_gen_create "$tool_name" >/dev/null 2>&1; then
                ((count++))
            else
                ((errors++))
                log_warn "Failed: $tool_name"
            fi
        done
    done

    log_info "Generated $count installer(s)"
    [[ $errors -gt 0 ]] && log_warn "$errors failed"

    return $errors
}

# Validate a generated installer
install_gen_validate() {
    local tool_name="${1:-}"

    if [[ -z "$tool_name" ]]; then
        log_error "Tool name required"
        return 4
    fi

    local script="$_IG_OUTPUT_DIR/$tool_name/install.sh"

    if [[ ! -f "$script" ]]; then
        log_error "Installer not found: $script"
        log_info "Generate first with: install_gen_create $tool_name"
        return 4
    fi

    log_info "Validating: $script"

    # Check syntax
    if ! bash -n "$script" 2>/dev/null; then
        log_error "Syntax error in generated script"
        return 6
    fi
    log_ok "Syntax check passed"

    # ShellCheck
    if command -v shellcheck &>/dev/null; then
        if shellcheck -S warning "$script"; then
            log_ok "ShellCheck passed"
        else
            log_error "ShellCheck found issues"
            return 1
        fi
    else
        log_warn "ShellCheck not available - skipping"
    fi

    # Check required elements
    if grep -q "set -uo pipefail" "$script"; then
        log_ok "Has set -uo pipefail"
    else
        log_warn "Missing set -uo pipefail"
    fi

    if grep -q "_log_error\|_log_info" "$script"; then
        log_ok "Has logging functions"
    else
        log_warn "Missing logging functions"
    fi

    if grep -q "sha256sum\|shasum" "$script"; then
        log_ok "Has checksum verification"
    else
        log_warn "Missing checksum verification"
    fi

    log_ok "Validation complete"
    return 0
}

# Export functions
export -f install_gen_create install_gen_all install_gen_validate
