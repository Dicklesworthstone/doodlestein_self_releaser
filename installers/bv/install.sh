#!/usr/bin/env bash
# install.sh - Install bv
#
# Usage:
#   curl -sSfL https://raw.githubusercontent.com/Dicklesworthstone/beads_viewer/main/install.sh | bash
#   curl -sSfL https://raw.githubusercontent.com/Dicklesworthstone/beads_viewer/main/install.sh | bash -s -- -v 1.2.3
#   curl -sSfL https://raw.githubusercontent.com/Dicklesworthstone/beads_viewer/main/install.sh | bash -s -- --json
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
TOOL_NAME="bv"
REPO="Dicklesworthstone/beads_viewer"
BINARY_NAME="bv"
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
