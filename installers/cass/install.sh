#!/usr/bin/env bash
# install.sh - Install cass
#
# Usage:
#   curl -sSfL https://raw.githubusercontent.com/Dicklesworthstone/coding_agent_session_search/main/install.sh | bash
#   curl -sSfL https://raw.githubusercontent.com/Dicklesworthstone/coding_agent_session_search/main/install.sh | bash -s -- -v 1.2.3
#   curl -sSfL https://raw.githubusercontent.com/Dicklesworthstone/coding_agent_session_search/main/install.sh | bash -s -- --json
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
TOOL_NAME="cass"
REPO="Dicklesworthstone/coding_agent_session_search"
BINARY_NAME="cass"
ARCHIVE_FORMAT_LINUX="tar.gz"
ARCHIVE_FORMAT_DARWIN="tar.gz"
ARCHIVE_FORMAT_WINDOWS="zip"
# shellcheck disable=SC2154  # ${name} etc are literal patterns substituted at runtime
ARTIFACT_NAMING="${name}-${os}-${arch}"

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
    # Atomic write: copy to .tmp then rename.  Otherwise a Ctrl-C
    # mid-cp leaves a truncated file in the cache, and the next run
    # silently uses it (the cache check is just `[[ -f ]]`).
    local tmp_file="${cache_file}.tmp.$$"
    if cp "$src_file" "$tmp_file" && mv -f "$tmp_file" "$cache_file"; then
        _log_info "Cached archive: $cache_file"
    else
        rm -f "$tmp_file" 2>/dev/null || true
        _log_warn "Failed to cache archive: $cache_file"
    fi
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
            # Match the EXACT filename — earlier this used a regex
            # substring grep that could match `prebv.tar.gz` or
            # `cass.tar.gz.minisig` for filename `cass.tar.gz`,
            # silently picking up the wrong hash. Use awk with
            # literal field equality on column 2; accept both the
            # `<hash>  <name>` (text) and `<hash> *<name>` (binary)
            # sha256sum conventions.
            expected_sha=$(printf '%s\n' "$checksums" | awk -v fname="$filename" '
                $2 == fname || $2 == "*" fname {print $1; exit}
            ')

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
