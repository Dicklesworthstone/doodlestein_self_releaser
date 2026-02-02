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
    # $6=archive_windows, $7=artifact_naming, $8=language (unused in template)

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
#   --verify                 Verify checksum + minisign signature
#   --json                   Output JSON for automation
#   --non-interactive        No prompts, fail on missing consent
#   --cache-dir DIR          Cache directory (default: ~/.cache/dsr/installers)
#   --offline                Use cached archives only (fail if not cached)
#   --prefer-gh              Prefer gh release download for private repos
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

set -uo pipefail

# Configuration
TOOL_NAME="__TOOL_NAME__"
REPO="__REPO__"
BINARY_NAME="__BINARY_NAME__"
ARCHIVE_FORMAT_LINUX="__ARCHIVE_FORMAT_LINUX__"
ARCHIVE_FORMAT_DARWIN="__ARCHIVE_FORMAT_DARWIN__"
ARCHIVE_FORMAT_WINDOWS="__ARCHIVE_FORMAT_WINDOWS__"
# shellcheck disable=SC2154  # ${name} etc are literal patterns substituted at runtime
ARTIFACT_NAMING="__ARTIFACT_NAMING__"

# Minisign public key for signature verification (embedded from dsr config)
# If empty, signature verification is skipped
MINISIGN_PUBKEY="__MINISIGN_PUBKEY__"

# Runtime state
_VERSION=""
_INSTALL_DIR="${HOME}/.local/bin"
_JSON_MODE=false
_VERIFY=false
_REQUIRE_SIGNATURES=false
_NON_INTERACTIVE=false
_AUTO_YES=false
_OFFLINE_ARCHIVE=""
_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/dsr/installers"
_OFFLINE_MODE=false
_PREFER_GH=false
_SKIP_SKILLS=false

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
        if command -v jq &>/dev/null; then
            jq -nc \
                --arg tool "$TOOL_NAME" \
                --arg status "$status" \
                --arg message "$message" \
                --arg version "$version" \
                --arg path "$path" \
                '{tool: $tool, status: $status, message: $message, version: $version, path: $path}'
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

    if [[ -f "$cache_file" ]]; then
        _log_info "Using cached archive: $cache_file"
        echo "$cache_file"
        return 0
    fi
    return 1
}

# Save archive to cache
_cache_put() {
    local src_file="$1"
    local version="$2"
    local platform="$3"
    local format="$4"
    local cache_file
    cache_file=$(_cache_path "$version" "$platform" "$format")
    local cache_dir
    cache_dir=$(dirname "$cache_file")

    mkdir -p "$cache_dir"
    cp "$src_file" "$cache_file"
    _log_info "Cached archive: $cache_file"
}

# ============================================================================
# GH CLI DOWNLOAD
# ============================================================================

# Download release asset using gh CLI (supports private repos)
_gh_download() {
    local version="$1"
    local platform="$2"
    local format="$3"
    local dest="$4"

    if ! command -v gh &>/dev/null; then
        return 1
    fi

    # Check gh auth status
    if ! gh auth status &>/dev/null; then
        _log_warn "gh not authenticated - falling back to curl"
        return 1
    fi

    local os="${platform%/*}"
    local arch="${platform#*/}"
    local version_num="${version#v}"

    # Construct asset name from pattern
    local artifact_name="$ARTIFACT_NAMING"
    artifact_name="${artifact_name//\$\{name\}/$TOOL_NAME}"
    artifact_name="${artifact_name//\$\{binary\}/$BINARY_NAME}"
    artifact_name="${artifact_name//\$\{version\}/$version_num}"
    artifact_name="${artifact_name//\$\{os\}/$os}"
    artifact_name="${artifact_name//\$\{arch\}/$arch}"
    # Only append extension if pattern doesn't include ${ext}
    local asset_name
    if [[ "$ARTIFACT_NAMING" == *'${ext}'* ]]; then
        artifact_name="${artifact_name//\$\{ext\}/$format}"
        asset_name="$artifact_name"
    else
        asset_name="${artifact_name}.${format}"
    fi

    _log_info "Downloading via gh release download: $asset_name"

    local dest_dir
    dest_dir=$(dirname "$dest")

    if gh release download "$version" --repo "$REPO" --pattern "$asset_name" --dir "$dest_dir" 2>/dev/null; then
        # gh downloads with the original filename, move to our destination
        local downloaded_file="$dest_dir/$asset_name"
        if [[ -f "$downloaded_file" && "$downloaded_file" != "$dest" ]]; then
            mv "$downloaded_file" "$dest"
        fi
        _log_ok "Downloaded via gh CLI"
        return 0
    else
        _log_warn "gh release download failed - falling back to curl"
        return 1
    fi
}

# Get latest version from GitHub
_get_latest_version() {
    local api_url="https://api.github.com/repos/$REPO/releases/latest"
    local response

    if ! command -v curl &>/dev/null; then
        _log_error "curl is required but not installed"
        return 3
    fi

    response=$(curl -sSfL "$api_url" 2>/dev/null) || {
        _log_error "Failed to fetch latest version from GitHub"
        return 1
    }

    # Extract tag_name from JSON (works with jq or POSIX tools)
    if command -v jq &>/dev/null; then
        echo "$response" | jq -r '.tag_name'
    else
        # Avoid non-portable grep -P (not available on macOS/BSD)
        echo "$response" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
    fi
}

# Construct download URL
_get_download_url() {
    local version="$1"
    local platform="$2"
    local format="$3"

    local os="${platform%/*}"
    local arch="${platform#*/}"
    local version_num="${version#v}"

    # Apply artifact naming pattern
    local artifact_name="$ARTIFACT_NAMING"
    artifact_name="${artifact_name//\$\{name\}/$TOOL_NAME}"
    artifact_name="${artifact_name//\$\{binary\}/$BINARY_NAME}"
    artifact_name="${artifact_name//\$\{version\}/$version_num}"
    artifact_name="${artifact_name//\$\{os\}/$os}"
    artifact_name="${artifact_name//\$\{arch\}/$arch}"
    # Only append extension if pattern doesn't include ${ext}
    local final_name
    if [[ "$ARTIFACT_NAMING" == *'${ext}'* ]]; then
        artifact_name="${artifact_name//\$\{ext\}/$format}"
        final_name="$artifact_name"
    else
        final_name="${artifact_name}.${format}"
    fi

    echo "https://github.com/$REPO/releases/download/$version/${final_name}"
}

# Download and verify checksum
_download_and_verify() {
    local url="$1"
    local dest="$2"
    local checksums_url="$3"

    _log_info "Downloading from: $url"

    if ! curl -sSfL "$url" -o "$dest" 2>/dev/null; then
        _log_error "Download failed"
        return 1
    fi

    # Verify checksum if available
    if [[ -n "$checksums_url" ]]; then
        local checksums
        if ! checksums=$(curl -sSfL "$checksums_url" 2>/dev/null); then
            _log_error "Failed to download checksums"
            return 1
        fi

        if [[ -n "$checksums" ]]; then
            local expected_sha
            local filename
            filename=$(basename "$dest")
            expected_sha=$(echo "$checksums" | grep "$filename" | awk '{print $1}')

            if [[ -n "$expected_sha" ]]; then
                local actual_sha
                if command -v sha256sum &>/dev/null; then
                    actual_sha=$(sha256sum "$dest" | awk '{print $1}')
                elif command -v shasum &>/dev/null; then
                    actual_sha=$(shasum -a 256 "$dest" | awk '{print $1}')
                fi

                if [[ "$actual_sha" == "$expected_sha" ]]; then
                    _log_ok "Checksum verified"
                else
                    _log_error "Checksum mismatch!"
                    _log_error "Expected: $expected_sha"
                    _log_error "Got:      $actual_sha"
                    rm -f "$dest"
                    return 1
                fi
            fi
        fi
    fi

    return 0
}

# Verify minisign signature
_verify_minisign() {
    local file="$1"
    local sig_url="$2"

    # Skip if no public key configured
    if [[ -z "$MINISIGN_PUBKEY" || "$MINISIGN_PUBKEY" == "__MINISIGN_PUBKEY__" ]]; then
        if $_REQUIRE_SIGNATURES; then
            _log_error "Signature verification required but no public key configured"
            return 1
        fi
        return 0
    fi

    # Check if minisign is available
    if ! command -v minisign &>/dev/null; then
        if $_REQUIRE_SIGNATURES; then
            _log_error "minisign required for signature verification but not installed"
            _log_info "Install: https://jedisct1.github.io/minisign/"
            return 1
        fi
        _log_warn "minisign not available - skipping signature verification"
        return 0
    fi

    # Download signature
    local sig_file="${file}.minisig"
    _log_info "Downloading signature..."
    if ! curl -sSfL "$sig_url" -o "$sig_file" 2>/dev/null; then
        if $_REQUIRE_SIGNATURES; then
            _log_error "Signature download failed"
            return 1
        fi
        _log_warn "No signature available - skipping verification"
        return 0
    fi

    # Create temp file for public key
    local pubkey_file
    pubkey_file=$(mktemp)
    echo "$MINISIGN_PUBKEY" > "$pubkey_file"

    # Verify
    _log_info "Verifying signature..."
    if minisign -Vm "$file" -p "$pubkey_file" 2>/dev/null; then
        _log_ok "Signature verified"
        rm -f "$pubkey_file" "$sig_file"
        return 0
    else
        _log_error "Signature verification FAILED!"
        _log_error "The file may have been tampered with."
        rm -f "$pubkey_file" "$sig_file"
        return 1
    fi
}

# Extract archive
_extract_archive() {
    local archive="$1"
    local dest_dir="$2"
    local format="${archive##*.}"

    mkdir -p "$dest_dir"

    case "$archive" in
        *.tar.gz|*.tgz)
            tar -xzf "$archive" -C "$dest_dir"
            ;;
        *.tar)
            tar -xf "$archive" -C "$dest_dir"
            ;;
        *.zip)
            if command -v unzip &>/dev/null; then
                unzip -q "$archive" -d "$dest_dir"
            else
                _log_error "unzip required to extract .zip files"
                return 1
            fi
            ;;
        *)
            _log_error "Unknown archive format: $archive"
            return 1
            ;;
    esac
}

# Install binary
_install_binary() {
    local src_binary="$1"
    local dest_dir="$2"

    local dest_binary="$dest_dir/$BINARY_NAME"

    # Create install directory
    mkdir -p "$dest_dir"

    # Check if binary already exists
    if [[ -f "$dest_binary" ]]; then
        if ! $_AUTO_YES; then
            if $_NON_INTERACTIVE; then
                _log_error "Binary already exists at $dest_binary"
                _log_info "Use --yes to overwrite or remove it manually"
                return 1
            fi

            _log_warn "Binary already exists: $dest_binary"
            read -rp "Overwrite? [y/N] " response
            if [[ ! "$response" =~ ^[yY] ]]; then
                _log_info "Installation cancelled"
                return 1
            fi
        fi
    fi

    # Install
    cp "$src_binary" "$dest_binary"
    chmod +x "$dest_binary"

    _log_ok "Installed to: $dest_binary"

    # Check if in PATH
    if [[ ":$PATH:" != *":$dest_dir:"* ]]; then
        _log_warn "$dest_dir is not in your PATH"
        _log_info "Add to your shell config:"
        _log_info "  export PATH=\"\$PATH:$dest_dir\""
    fi

    return 0
}

# ============================================================================
# SKILL INSTALLATION
# ============================================================================

# Skill content is embedded at generation time (base64 encoded to avoid escaping issues)
# If this placeholder was not replaced, skill installation is skipped
_SKILL_CONTENT_B64='__SKILL_CONTENT_B64__'

# Decode skill content at runtime
_decode_skill_content() {
    # Skip if placeholder wasn't replaced (check for literal __ prefix)
    if [[ "$_SKILL_CONTENT_B64" == _* ]]; then
        return 1
    fi
    if [[ -n "$_SKILL_CONTENT_B64" ]] && command -v base64 &>/dev/null; then
        # macOS uses -D, Linux uses -d
        base64 -d 2>/dev/null <<< "$_SKILL_CONTENT_B64" || base64 -D 2>/dev/null <<< "$_SKILL_CONTENT_B64"
    fi
}

# Install skill for Claude Code
# Returns 0 if skill was installed, 1 if skipped
_install_claude_skill() {
    local skill_dir="${HOME}/.claude/skills/${TOOL_NAME}"

    # Check if Claude Code is installed
    if [[ ! -d "${HOME}/.claude" ]] && ! command -v claude &>/dev/null; then
        return 1  # Claude Code not installed, skip silently
    fi

    # Write skill file from decoded base64 content
    local skill_content
    skill_content=$(_decode_skill_content)
    if [[ -n "$skill_content" ]]; then
        _log_info "Installing Claude Code skill..."
        mkdir -p "$skill_dir"
        printf '%s\n' "$skill_content" > "$skill_dir/SKILL.md"
        _log_ok "Claude Code skill installed: $skill_dir/SKILL.md"
        return 0
    else
        return 1  # No skill content, skip
    fi
}

# Install skill for Codex CLI
# Returns 0 if skill was installed, 1 if skipped
_install_codex_skill() {
    local skill_dir="${HOME}/.codex/skills/${TOOL_NAME}"

    # Check if Codex CLI is installed
    if [[ ! -d "${HOME}/.codex" ]] && ! command -v codex &>/dev/null; then
        return 1  # Codex CLI not installed, skip silently
    fi

    # Write skill file from decoded base64 content
    local skill_content
    skill_content=$(_decode_skill_content)
    if [[ -n "$skill_content" ]]; then
        _log_info "Installing Codex CLI skill..."
        mkdir -p "$skill_dir"
        printf '%s\n' "$skill_content" > "$skill_dir/SKILL.md"
        _log_ok "Codex CLI skill installed: $skill_dir/SKILL.md"
        return 0
    else
        return 1  # No skill content, skip
    fi
}

# Install skills for all detected AI coding agents
_install_skills() {
    if $_SKIP_SKILLS; then
        _log_info "Skipping skill installation (--no-skills)"
        return 0
    fi

    # Check if skill content is available before announcing anything
    local skill_content
    skill_content=$(_decode_skill_content)
    if [[ -z "$skill_content" ]]; then
        return 0  # No skill content embedded, skip silently
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

# Main installation function
main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -v|--version)
                _VERSION="$2"
                shift 2
                ;;
            -d|--dir)
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
                _CACHE_DIR="$2"
                shift 2
                ;;
            --prefer-gh)
                _PREFER_GH=true
                shift
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

    # Detect platform
    local platform
    platform=$(_detect_platform) || return $?
    _log_info "Platform: $platform"

    # Get version
    if [[ -z "$_VERSION" ]]; then
        _log_info "Fetching latest version..."
        _VERSION=$(_get_latest_version) || return $?
    fi
    _log_info "Version: $_VERSION"

    # Get archive format
    local format
    format=$(_get_archive_format "$platform")

    # Create temp directory
    local temp_dir
    temp_dir=$(mktemp -d)
    trap 'rm -rf "$temp_dir"' EXIT

    local archive_file="$temp_dir/${TOOL_NAME}.${format}"
    local extract_dir="$temp_dir/extracted"

    # Download or use offline archive
    local from_cache=false
    if [[ -n "$_OFFLINE_ARCHIVE" ]]; then
        # Explicit offline archive path
        if [[ ! -f "$_OFFLINE_ARCHIVE" ]]; then
            _log_error "Offline archive not found: $_OFFLINE_ARCHIVE"
            return 1
        fi
        cp "$_OFFLINE_ARCHIVE" "$archive_file"
        _log_info "Using offline archive: $_OFFLINE_ARCHIVE"
    else
        # Check cache first
        local cached_file
        if cached_file=$(_cache_get "$_VERSION" "$platform" "$format"); then
            cp "$cached_file" "$archive_file"
            from_cache=true
        elif $_OFFLINE_MODE; then
            # Offline mode requires cache hit
            _log_error "Offline mode: no cached archive for $TOOL_NAME $_VERSION ($platform)"
            _log_info "Cache location: $_CACHE_DIR/$TOOL_NAME/$_VERSION/"
            _log_info "Download first without --offline flag"
            _json_result "error" "No cached archive available" "$_VERSION" ""
            return 1
        else
            # Download from network
            local download_url
            download_url=$(_get_download_url "$_VERSION" "$platform" "$format")
            local download_success=false

            # Try gh release download first if preferred
            if $_PREFER_GH && _gh_download "$_VERSION" "$platform" "$format" "$archive_file"; then
                download_success=true
            fi

            # Fall back to curl
            if ! $download_success; then
                local checksums_url=""
                if $_VERIFY; then
                    checksums_url="https://github.com/$REPO/releases/download/$_VERSION/${TOOL_NAME}-${_VERSION#v}-SHA256SUMS.txt"
                fi

                if _download_and_verify "$download_url" "$archive_file" "$checksums_url"; then
                    download_success=true
                else
                    # If curl failed and gh is available, try gh as last resort
                    if ! $_PREFER_GH && _gh_download "$_VERSION" "$platform" "$format" "$archive_file"; then
                        download_success=true
                    fi
                fi
            fi

            if ! $download_success; then
                _log_error "Failed to download archive"
                _json_result "error" "Download failed" "$_VERSION" ""
                return 1
            fi

            # Cache the downloaded archive for future use
            _cache_put "$archive_file" "$_VERSION" "$platform" "$format"
        fi

        # Verify minisign signature if available (skip for cached files by default)
        if ! $from_cache && { $_VERIFY || $_REQUIRE_SIGNATURES; }; then
            local download_url
            download_url=$(_get_download_url "$_VERSION" "$platform" "$format")
            local sig_url="${download_url}.minisig"
            _verify_minisign "$archive_file" "$sig_url" || return $?
        fi
    fi

    # Extract
    _log_info "Extracting..."
    _extract_archive "$archive_file" "$extract_dir" || return $?

    # Find binary
    local binary_path
    binary_path=$(find "$extract_dir" -name "$BINARY_NAME" -type f | head -1)
    if [[ -z "$binary_path" ]]; then
        # Try with .exe for Windows
        binary_path=$(find "$extract_dir" -name "${BINARY_NAME}.exe" -type f | head -1)
    fi

    if [[ -z "$binary_path" ]]; then
        _log_error "Binary not found in archive"
        return 1
    fi

    # Install
    _install_binary "$binary_path" "$_INSTALL_DIR" || return $?

    # Install AI coding agent skills
    _install_skills

    # Verify installation
    local installed_path="$_INSTALL_DIR/$BINARY_NAME"
    if [[ -f "$installed_path" ]]; then
        local installed_version
        installed_version=$("$installed_path" --version 2>/dev/null | head -1 || echo "unknown")
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

# Run main
main "$@"
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
    local repo binary_name language
    local archive_linux archive_darwin archive_windows
    local artifact_naming

    tool_name=$(_install_gen_yaml_get "$config_file" "tool_name" "$tool_name")
    repo=$(_install_gen_yaml_get "$config_file" "repo" "")
    binary_name=$(_install_gen_yaml_get "$config_file" "binary_name" "$tool_name")
    language=$(_install_gen_yaml_get "$config_file" "language" "go")

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

    artifact_naming=$(_install_gen_yaml_get "$config_file" "artifact_naming" '${name}-${version}-${os}-${arch}')
    # Strip surrounding quotes if present
    artifact_naming="${artifact_naming#\"}"
    artifact_naming="${artifact_naming%\"}"

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

    # Get skill content (look in multiple locations)
    local skill_content=""
    local skill_paths=(
        "./SKILL.md"
        "./config/skills/${tool_name}/SKILL.md"
    )
    local local_path
    local_path=$(_install_gen_yaml_get "$config_file" "local_path" "")
    if [[ -n "$local_path" && -f "$local_path/SKILL.md" ]]; then
        skill_paths=("$local_path/SKILL.md" "${skill_paths[@]}")
    fi
    for skill_path in "${skill_paths[@]}"; do
        if [[ -f "$skill_path" ]]; then
            skill_content=$(cat "$skill_path")
            log_info "  Skill: $skill_path"
            break
        fi
    done
    if [[ -z "$skill_content" ]]; then
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

    # Handle skill content - use base64 encoding to avoid escaping issues
    if [[ -n "$skill_content" ]]; then
        local skill_b64
        # Encode skill content as base64 (works on both Linux and macOS)
        skill_b64=$(printf '%s' "$skill_content" | base64 | tr -d '\n')
        template="${template//__SKILL_CONTENT_B64__/$skill_b64}"
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
