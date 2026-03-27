#!/usr/bin/env bash
# install.sh - Install ntm
#
# Usage:
#   curl -sSfL https://raw.githubusercontent.com/Dicklesworthstone/ntm/main/install.sh | bash
#   curl -sSfL https://raw.githubusercontent.com/Dicklesworthstone/ntm/main/install.sh | bash -s -- -v 1.2.3
#   curl -sSfL https://raw.githubusercontent.com/Dicklesworthstone/ntm/main/install.sh | bash -s -- --json
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
TOOL_NAME="ntm"
REPO="Dicklesworthstone/ntm"
BINARY_NAME="ntm"
ARCHIVE_FORMAT_LINUX="tar.gz"
ARCHIVE_FORMAT_DARWIN="tar.gz"
ARCHIVE_FORMAT_WINDOWS="zip"
# shellcheck disable=SC2154  # ${name} etc are literal patterns substituted at runtime
ARTIFACT_NAMING="${name}_${version}_${os}_${arch}"

# Minisign public key for signature verification (embedded from dsr config)
# If empty, signature verification is skipped
MINISIGN_PUBKEY=""

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

    esac

    echo "$arch"
}

_resolve_target_triple() {
    local os="$1"
    local arch="$2"

    case "${os}/${arch}" in

    esac

    case "${os}/${arch}" in
        linux/amd64) echo "x86_64-unknown-linux-gnu" ;;
        linux/arm64) echo "aarch64-unknown-linux-gnu" ;;
        darwin/amd64) echo "x86_64-apple-darwin" ;;
        darwin/arm64) echo "aarch64-apple-darwin" ;;
        windows/amd64) echo "x86_64-pc-windows-msvc" ;;
        *) echo "${os}-${arch}" ;;
    esac
}

_apply_artifact_pattern() {
    local pattern="$1"
    local os="$2"
    local arch="$3"
    local version_num="$4"
    local format="$5"

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
        name="${name//\$\{ext\}/$format}"
        name="${name//\$\{EXT\}/$format}"
        echo "$name"
        return 0
    fi

    if _has_known_ext "$name"; then
        echo "$name"
        return 0
    fi

    echo "${name}.${format}"
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
    local asset_name
    asset_name=$(_apply_artifact_pattern "$ARTIFACT_NAMING" "$os" "$arch" "$version_num" "$format")

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
    local final_name
    final_name=$(_apply_artifact_pattern "$ARTIFACT_NAMING" "$os" "$arch" "$version_num" "$format")

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
    if [[ -z "$MINISIGN_PUBKEY" || "$MINISIGN_PUBKEY" == "" ]]; then
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
        *.tar.xz)
            tar -xJf "$archive" -C "$dest_dir"
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

# Skill archive is embedded at generation time as a gzip-compressed tarball
# encoded in base64 so multi-file skill trees can be restored on install.
# If this placeholder was not replaced, skill installation is skipped.
_SKILL_ARCHIVE_B64='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'

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

    if ! _decode_skill_archive | tar -xzf - -C "$stage_dir" >/dev/null 2>&1; then
        rm -rf "$stage_dir" 2>/dev/null || true
        _log_warn "Failed to extract embedded skill archive"
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
