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
ARTIFACT_NAMING="${name}-${version}-${os}-${arch}"

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
        cat << EOF
{
  "tool": "$TOOL_NAME",
  "status": "$status",
  "message": "$message",
  "version": "$version",
  "path": "$path"
}
EOF
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
    artifact_name="${artifact_name//\$\{ext\}/$format}"
    local asset_name="${artifact_name}.${format}"

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
    artifact_name="${artifact_name//\$\{ext\}/$format}"

    echo "https://github.com/$REPO/releases/download/$version/${artifact_name}.${format}"
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
_SKILL_CONTENT_B64='LS0tCm5hbWU6IG50bQpkZXNjcmlwdGlvbjogIk5hbWVkIFRtdXggTWFuYWdlciAtIE11bHRpLWFnZW50IG9yY2hlc3RyYXRpb24gZm9yIENsYXVkZSBDb2RlLCBDb2RleCwgYW5kIEdlbWluaSBpbiB0aWxlZCB0bXV4IHBhbmVzLiBWaXN1YWwgZGFzaGJvYXJkcywgY29tbWFuZCBwYWxldHRlLCBjb250ZXh0IHJvdGF0aW9uLCByb2JvdCBtb2RlIEFQSSwgd29yayBhc3NpZ25tZW50LCBzYWZldHkgc3lzdGVtLiBHbyBDTEkuIgotLS0KCiMgTlRNIOKAlCBOYW1lZCBUbXV4IE1hbmFnZXIKCkEgR28gQ0xJIHRoYXQgdHJhbnNmb3JtcyB0bXV4IGludG8gYSAqKm11bHRpLWFnZW50IGNvbW1hbmQgY2VudGVyKiogZm9yIG9yY2hlc3RyYXRpbmcgQ2xhdWRlIENvZGUsIENvZGV4LCBhbmQgR2VtaW5pIGFnZW50cyBpbiBwYXJhbGxlbC4gU3Bhd24sIG1hbmFnZSwgYW5kIGNvb3JkaW5hdGUgQUkgYWdlbnRzIGFjcm9zcyB0aWxlZCBwYW5lcyB3aXRoIHN0dW5uaW5nIFRVSSwgYXV0b21hdGVkIGNvbnRleHQgcm90YXRpb24sIGFuZCBkZWVwIGludGVncmF0aW9ucyB3aXRoIHRoZSBBZ2VudCBGbHl3aGVlbCBlY29zeXN0ZW0uCgojIyBXaHkgVGhpcyBFeGlzdHMKCk1hbmFnaW5nIG11bHRpcGxlIEFJIGNvZGluZyBhZ2VudHMgaXMgcGFpbmZ1bDoKLSAqKldpbmRvdyBjaGFvcyoqOiBFYWNoIGFnZW50IG5lZWRzIGl0cyBvd24gdGVybWluYWwKLSAqKkNvbnRleHQgc3dpdGNoaW5nKio6IEp1bXBpbmcgYmV0d2VlbiB3aW5kb3dzIGJyZWFrcyBmbG93Ci0gKipObyBvcmNoZXN0cmF0aW9uKio6IFNhbWUgcHJvbXB0IHRvIG11bHRpcGxlIGFnZW50cyByZXF1aXJlcyBtYW51YWwgY29weS1wYXN0ZQotICoqU2Vzc2lvbiBmcmFnaWxpdHkqKjogRGlzY29ubmVjdGluZyBmcm9tIFNTSCBsb3NlcyBhbGwgYWdlbnQgc2Vzc2lvbnMKLSAqKk5vIHZpc2liaWxpdHkqKjogSGFyZCB0byBzZWUgYWdlbnQgc3RhdHVzIGF0IGEgZ2xhbmNlCgpOVE0gc29sdmVzIGFsbCBvZiB0aGlzIHdpdGggb25lIHNlc3Npb24gY29udGFpbmluZyBtYW55IGFnZW50cywgcGVyc2lzdGVudCBhY3Jvc3MgU1NIIGRpc2Nvbm5lY3Rpb25zLgoKIyMgUXVpY2sgU3RhcnQKCmBgYGJhc2gKIyBJbnN0YWxsCmN1cmwgLWZzU0wgaHR0cHM6Ly9yYXcuZ2l0aHVidXNlcmNvbnRlbnQuY29tL0RpY2tsZXN3b3J0aHN0b25lL250bS9tYWluL2luc3RhbGwuc2ggfCBiYXNoCgojIEFkZCBzaGVsbCBpbnRlZ3JhdGlvbgplY2hvICdldmFsICIkKG50bSBzaGVsbCB6c2gpIicgPj4gfi8uenNocmMgJiYgc291cmNlIH4vLnpzaHJjCgojIEludGVyYWN0aXZlIHR1dG9yaWFsCm50bSB0dXRvcmlhbAoKIyBDaGVjayBkZXBlbmRlbmNpZXMKbnRtIGRlcHMgLXYKCiMgQ3JlYXRlIG11bHRpLWFnZW50IHNlc3Npb24KbnRtIHNwYXduIG15cHJvamVjdCAtLWNjPTIgLS1jb2Q9MSAtLWdtaT0xCgojIFNlbmQgcHJvbXB0IHRvIGFsbCBDbGF1ZGUgYWdlbnRzCm50bSBzZW5kIG15cHJvamVjdCAtLWNjICJFeHBsb3JlIHRoaXMgY29kZWJhc2UgYW5kIHN1bW1hcml6ZSBpdHMgYXJjaGl0ZWN0dXJlLiIKCiMgT3BlbiBjb21tYW5kIHBhbGV0dGUgKG9yIHByZXNzIEY2IGFmdGVyIGBudG0gYmluZGApCm50bSBwYWxldHRlIG15cHJvamVjdApgYGAKCiMjIFNlc3Npb24gQ3JlYXRpb24KCiMjIyBTcGF3biBBZ2VudHMKCmBgYGJhc2gKbnRtIHNwYXduIG15cHJvamVjdCAtLWNjPTMgLS1jb2Q9MiAtLWdtaT0xICAgIyAzIENsYXVkZSArIDIgQ29kZXggKyAxIEdlbWluaQpudG0gcXVpY2sgbXlwcm9qZWN0IC0tdGVtcGxhdGU9Z28gICAgICAgICAgICAgIyBGdWxsIHByb2plY3Qgc2NhZmZvbGQgKyBhZ2VudHMKbnRtIGNyZWF0ZSBteXByb2plY3QgLS1wYW5lcz0xMCAgICAgICAgICAgICAgICMgRW1wdHkgcGFuZXMgb25seQpudG0gc3Bhd24gbXlwcm9qZWN0IC0tcHJvZmlsZXM9YXJjaGl0ZWN0LGltcGxlbWVudGVyLHRlc3RlcgpgYGAKCiMjIyBBZ2VudCBGbGFncwoKfCBGbGFnIHwgQWdlbnQgfCBDTEkgQ29tbWFuZCB8CnwtLS0tLS18LS0tLS0tLXwtLS0tLS0tLS0tLS0tfAp8IGAtLWNjPU5gIHwgQ2xhdWRlIENvZGUgfCBgY2xhdWRlYCB8CnwgYC0tY29kPU5gIHwgQ29kZXggQ0xJIHwgYGNvZGV4YCB8CnwgYC0tZ21pPU5gIHwgR2VtaW5pIENMSSB8IGBnZW1pbmlgIHwKCiMjIyBBZGQgTW9yZSBBZ2VudHMKCmBgYGJhc2gKbnRtIGFkZCBteXByb2plY3QgLS1jYz0yICAgICAgICAgICAgICAjIEFkZCAyIG1vcmUgQ2xhdWRlIGFnZW50cwpudG0gYWRkIG15cHJvamVjdCAtLWNvZD0xIC0tZ21pPTEgICAgICMgQWRkIG1peGVkIGFnZW50cwpgYGAKCiMjIFNlbmRpbmcgUHJvbXB0cwoKYGBgYmFzaApudG0gc2VuZCBteXByb2plY3QgLS1jYyAiSW1wbGVtZW50IHVzZXIgYXV0aCIgICAgICMgVG8gYWxsIENsYXVkZQpudG0gc2VuZCBteXByb2plY3QgLS1jb2QgIldyaXRlIHVuaXQgdGVzdHMiICAgICAgICMgVG8gYWxsIENvZGV4Cm50bSBzZW5kIG15cHJvamVjdCAtLWdtaSAiUmV2aWV3IGFuZCBkb2N1bWVudCIgICAgIyBUbyBhbGwgR2VtaW5pCm50bSBzZW5kIG15cHJvamVjdCAtLWFsbCAiUmV2aWV3IGN1cnJlbnQgc3RhdGUiICAgIyBUbyBBTEwgYWdlbnRzCm50bSBpbnRlcnJ1cHQgbXlwcm9qZWN0ICAgICAgICAgICAgICAgICAgICAgICAgICAgIyBDdHJsK0MgdG8gYWxsCmBgYAoKIyMgU2Vzc2lvbiBOYXZpZ2F0aW9uCgp8IENvbW1hbmQgfCBBbGlhcyB8IERlc2NyaXB0aW9uIHwKfC0tLS0tLS0tLXwtLS0tLS0tfC0tLS0tLS0tLS0tLS18CnwgYG50bSBsaXN0YCB8IGBsbnRgIHwgTGlzdCBhbGwgdG11eCBzZXNzaW9ucyB8CnwgYG50bSBhdHRhY2hgIHwgYHJudGAgfCBBdHRhY2ggdG8gc2Vzc2lvbiB8CnwgYG50bSBzdGF0dXNgIHwgYHNudGAgfCBTaG93IHBhbmUgZGV0YWlscyB3aXRoIGFnZW50IGNvdW50cyB8CnwgYG50bSB2aWV3YCB8IGB2bnRgIHwgVW56b29tLCB0aWxlIGxheW91dCwgYXR0YWNoIHwKfCBgbnRtIHpvb21gIHwgYHpudGAgfCBab29tIHRvIHNwZWNpZmljIHBhbmUgfAp8IGBudG0gZGFzaGJvYXJkYCB8IGBkYXNoYCwgYGRgIHwgSW50ZXJhY3RpdmUgdmlzdWFsIGRhc2hib2FyZCB8CnwgYG50bSBraWxsYCB8IGBrbnRgIHwgS2lsbCBzZXNzaW9uIChgLWZgIHRvIGZvcmNlKSB8CgojIyBDb21tYW5kIFBhbGV0dGUKCkZ1enp5LXNlYXJjaGFibGUgVFVJIHdpdGggcHJlLWNvbmZpZ3VyZWQgcHJvbXB0czoKCmBgYGJhc2gKbnRtIHBhbGV0dGUgbXlwcm9qZWN0ICAgICMgT3BlbiBwYWxldHRlCm50bSBiaW5kICAgICAgICAgICAgICAgICAjIFNldCB1cCBGNiBrZXliaW5kaW5nCm50bSBiaW5kIC0ta2V5PUY1ICAgICAgICAjIFVzZSBkaWZmZXJlbnQga2V5CmBgYAoKIyMjIFBhbGV0dGUgRmVhdHVyZXMKCi0gQW5pbWF0ZWQgZ3JhZGllbnQgYmFubmVyIHdpdGggQ2F0cHB1Y2NpbiB0aGVtZXMKLSBGdXp6eSBzZWFyY2ggd2l0aCBsaXZlIGZpbHRlcmluZwotIFBpbi9mYXZvcml0ZSBjb21tYW5kcyAoYEN0cmwrUGAgLyBgQ3RybCtGYCkKLSBMaXZlIHByZXZpZXcgcGFuZSB3aXRoIG1ldGFkYXRhCi0gUXVpY2sgc2VsZWN0IHdpdGggbnVtYmVycyAxLTkKLSBWaXN1YWwgdGFyZ2V0IHNlbGVjdG9yIChBbGwvQ2xhdWRlL0NvZGV4L0dlbWluaSkKCiMjIyBQYWxldHRlIE5hdmlnYXRpb24KCnwgS2V5IHwgQWN0aW9uIHwKfC0tLS0tfC0tLS0tLS0tfAp8IGDihpEv4oaTYCBvciBgai9rYCB8IE5hdmlnYXRlIHwKfCBgMS05YCB8IFF1aWNrIHNlbGVjdCB8CnwgYEVudGVyYCB8IFNlbGVjdCBjb21tYW5kIHwKfCBgRXNjYCB8IEJhY2sgLyBRdWl0IHwKfCBgP2AgfCBIZWxwIG92ZXJsYXkgfAp8IGBDdHJsK1BgIHwgUGluL3VucGluIHwKfCBgQ3RybCtGYCB8IEZhdm9yaXRlIHwKCiMjIEludGVyYWN0aXZlIERhc2hib2FyZAoKYGBgYmFzaApudG0gZGFzaGJvYXJkIG15cHJvamVjdCAgICMgT3I6IG50bSBkYXNoIG15cHJvamVjdApgYGAKCiMjIyBEYXNoYm9hcmQgRmVhdHVyZXMKCi0gVmlzdWFsIHBhbmUgZ3JpZCB3aXRoIGNvbG9yLWNvZGVkIGFnZW50IGNhcmRzCi0gTGl2ZSBhZ2VudCBjb3VudHMgKENsYXVkZS9Db2RleC9HZW1pbmkvVXNlcikKLSBUb2tlbiB2ZWxvY2l0eSBiYWRnZXMgKHRva2Vucy1wZXItbWludXRlKQotIENvbnRleHQgdXNhZ2UgaW5kaWNhdG9ycyAoZ3JlZW4veWVsbG93L29yYW5nZS9yZWQpCi0gUmVhbC10aW1lIHJlZnJlc2ggd2l0aCBgcmAKCiMjIyBEYXNoYm9hcmQgTmF2aWdhdGlvbgoKfCBLZXkgfCBBY3Rpb24gfAp8LS0tLS18LS0tLS0tLS18CnwgYOKGkS/ihpNgIG9yIGBqL2tgIHwgTmF2aWdhdGUgcGFuZXMgfAp8IGAxLTlgIHwgUXVpY2sgc2VsZWN0IHwKfCBgemAgb3IgYEVudGVyYCB8IFpvb20gdG8gcGFuZSB8CnwgYHJgIHwgUmVmcmVzaCB8CnwgYGNgIHwgVmlldyBjb250ZXh0IHwKfCBgbWAgfCBPcGVuIEFnZW50IE1haWwgfAp8IGBxYCB8IFF1aXQgfAoKIyMgT3V0cHV0IENhcHR1cmUKCmBgYGJhc2gKbnRtIGNvcHkgbXlwcm9qZWN0OjEgICAgICAgICAgICAgICMgQ29weSBzcGVjaWZpYyBwYW5lCm50bSBjb3B5IG15cHJvamVjdCAtLWFsbCAgICAgICAgICAjIENvcHkgYWxsIHBhbmVzCm50bSBjb3B5IG15cHJvamVjdCAtLWNjICAgICAgICAgICAjIENvcHkgQ2xhdWRlIHBhbmVzIG9ubHkKbnRtIGNvcHkgbXlwcm9qZWN0IC0tcGF0dGVybiAnRVJST1InICAjIEZpbHRlciBieSByZWdleApudG0gY29weSBteXByb2plY3QgLS1jb2RlICAgICAgICAgIyBFeHRyYWN0IGNvZGUgYmxvY2tzIG9ubHkKbnRtIGNvcHkgbXlwcm9qZWN0IC0tb3V0cHV0IG91dC50eHQgICAjIFNhdmUgdG8gZmlsZQpudG0gc2F2ZSBteXByb2plY3QgLW8gfi9sb2dzICAgICAgIyBTYXZlIGFsbCBvdXRwdXRzCmBgYAoKIyMgTW9uaXRvcmluZyAmIEFuYWx5c2lzCgpgYGBiYXNoCm50bSBhY3Rpdml0eSBteXByb2plY3QgLS13YXRjaCAgICAjIFJlYWwtdGltZSBhY3Rpdml0eQpudG0gaGVhbHRoIG15cHJvamVjdCAgICAgICAgICAgICAgIyBIZWFsdGggc3RhdHVzCm50bSB3YXRjaCBteXByb2plY3QgLS1jYyAgICAgICAgICAjIFN0cmVhbSBvdXRwdXQKbnRtIGV4dHJhY3QgbXlwcm9qZWN0IC0tbGFuZz1nbyAgICMgRXh0cmFjdCBjb2RlIGJsb2NrcwpudG0gZGlmZiBteXByb2plY3QgY2NfMSBjb2RfMSAgICAgIyBDb21wYXJlIHBhbmVzCm50bSBncmVwICdlcnJvcicgbXlwcm9qZWN0IC1DIDMgICAjIFNlYXJjaCB3aXRoIGNvbnRleHQKbnRtIGFuYWx5dGljcyAtLWRheXMgNyAgICAgICAgICAgICMgU2Vzc2lvbiBzdGF0aXN0aWNzCm50bSBsb2NrcyBteXByb2plY3QgLS1hbGwtYWdlbnRzICAjIEZpbGUgcmVzZXJ2YXRpb25zCmBgYAoKIyMjIEFjdGl2aXR5IFN0YXRlcwoKfCBTdGF0ZSB8IEljb24gfCBEZXNjcmlwdGlvbiB8CnwtLS0tLS0tfC0tLS0tLXwtLS0tLS0tLS0tLS0tfAp8IFdBSVRJTkcgfCDil48gfCBJZGxlLCByZWFkeSBmb3Igd29yayB8CnwgR0VORVJBVElORyB8IOKWtiB8IFByb2R1Y2luZyBvdXRwdXQgfAp8IFRISU5LSU5HIHwg4peQIHwgUHJvY2Vzc2luZyAobm8gb3V0cHV0IHlldCkgfAp8IEVSUk9SIHwg4pyXIHwgRW5jb3VudGVyZWQgZXJyb3IgfAp8IFNUQUxMRUQgfCDil68gfCBTdG9wcGVkIHVuZXhwZWN0ZWRseSB8CgojIyBDaGVja3BvaW50cwoKYGBgYmFzaApudG0gY2hlY2twb2ludCBzYXZlIG15cHJvamVjdCAtbSAiQmVmb3JlIHJlZmFjdG9yIgpudG0gY2hlY2twb2ludCBsaXN0IG15cHJvamVjdApudG0gY2hlY2twb2ludCBzaG93IG15cHJvamVjdCAyMDI1MTIxMC0xNDMwNTIKbnRtIGNoZWNrcG9pbnQgZGVsZXRlIG15cHJvamVjdCAyMDI1MTIxMC0xNDMwNTIgLWYKYGBgCgojIyBDb250ZXh0IFdpbmRvdyBSb3RhdGlvbgoKTlRNIG1vbml0b3JzIGNvbnRleHQgdXNhZ2UgYW5kIGF1dG8tcm90YXRlcyBhZ2VudHMgYmVmb3JlIGV4aGF1c3RpbmcgY29udGV4dC4KCiMjIyBIb3cgSXQgV29ya3MKCjEuICoqTW9uaXRvcmluZyoqOiBUb2tlbiB1c2FnZSBlc3RpbWF0ZWQgcGVyIGFnZW50CjIuICoqV2FybmluZyoqOiBBbGVydCBhdCA4MCUgdXNhZ2UKMy4gKipDb21wYWN0aW9uKio6IFRyeSBgL2NvbXBhY3RgIG9yIHN1bW1hcml6YXRpb24gZmlyc3QKNC4gKipSb3RhdGlvbioqOiBGcmVzaCBhZ2VudCB3aXRoIGhhbmRvZmYgc3VtbWFyeSBpZiBuZWVkZWQKCiMjIyBDb250ZXh0IEluZGljYXRvcnMKCnwgQ29sb3IgfCBVc2FnZSB8IFN0YXR1cyB8CnwtLS0tLS0tfC0tLS0tLS18LS0tLS0tLS18CnwgR3JlZW4gfCA8IDQwJSB8IFBsZW50eSBvZiByb29tIHwKfCBZZWxsb3cgfCA0MC02MCUgfCBDb21mb3J0YWJsZSB8CnwgT3JhbmdlIHwgNjAtODAlIHwgQXBwcm9hY2hpbmcgdGhyZXNob2xkIHwKfCBSZWQgfCA+IDgwJSB8IE5lZWRzIGF0dGVudGlvbiB8CgojIyMgQXV0b21hdGljIENvbXBhY3Rpb24gUmVjb3ZlcnkKCldoZW4gY29udGV4dCBpcyBjb21wYWN0ZWQsIE5UTSBzZW5kcyBhIHJlY292ZXJ5IHByb21wdDoKCmBgYHRvbWwKW2NvbnRleHRfcm90YXRpb24ucmVjb3ZlcnldCmVuYWJsZWQgPSB0cnVlCnByb21wdCA9ICJSZXJlYWQgQUdFTlRTLm1kIHNvIGl0J3Mgc3RpbGwgZnJlc2ggaW4geW91ciBtaW5kLiBVc2UgdWx0cmF0aGluay4iCmluY2x1ZGVfYmVhZF9jb250ZXh0ID0gdHJ1ZSAgICMgSW5jbHVkZSBwcm9qZWN0IHN0YXRlIGZyb20gYnYKYGBgCgojIyBSb2JvdCBNb2RlIChBSSBBdXRvbWF0aW9uKQoKTWFjaGluZS1yZWFkYWJsZSBKU09OIG91dHB1dCBmb3IgQUkgYWdlbnRzIGFuZCBhdXRvbWF0aW9uLgoKIyMjIFN0YXRlIEluc3BlY3Rpb24KCmBgYGJhc2gKbnRtIC0tcm9ib3Qtc3RhdHVzICAgICAgICAgICAgICAjIFNlc3Npb25zLCBwYW5lcywgYWdlbnQgc3RhdGVzCm50bSAtLXJvYm90LWNvbnRleHQ9U0VTU0lPTiAgICAgIyBDb250ZXh0IHdpbmRvdyB1c2FnZQpudG0gLS1yb2JvdC1zbmFwc2hvdCAgICAgICAgICAgICMgVW5pZmllZCBzdGF0ZTogc2Vzc2lvbnMgKyBiZWFkcyArIG1haWwKbnRtIC0tcm9ib3QtdGFpbD1TRVNTSU9OICAgICAgICAjIFJlY2VudCBwYW5lIG91dHB1dApudG0gLS1yb2JvdC1pbnNwZWN0LXBhbmU9U0VTUyAgICMgRGV0YWlsZWQgcGFuZSBpbnNwZWN0aW9uCm50bSAtLXJvYm90LWZpbGVzPVNFU1NJT04gICAgICAgIyBGaWxlIGNoYW5nZXMgd2l0aCBhdHRyaWJ1dGlvbgpudG0gLS1yb2JvdC1tZXRyaWNzPVNFU1NJT04gICAgICMgU2Vzc2lvbiBtZXRyaWNzCm50bSAtLXJvYm90LXBsYW4gICAgICAgICAgICAgICAgIyBidiBleGVjdXRpb24gcGxhbgpudG0gLS1yb2JvdC1kYXNoYm9hcmQgICAgICAgICAgICMgRGFzaGJvYXJkIHN1bW1hcnkKbnRtIC0tcm9ib3QtaGVhbHRoICAgICAgICAgICAgICAjIFByb2plY3QgaGVhbHRoCmBgYAoKIyMjIEFnZW50IENvbnRyb2wKCmBgYGJhc2gKbnRtIC0tcm9ib3Qtc2VuZD1TRVNTSU9OIC0tbXNnPSJGaXggYXV0aCIgLS10eXBlPWNsYXVkZQpudG0gLS1yb2JvdC1zcGF3bj1TRVNTSU9OIC0tc3Bhd24tY2M9MiAtLXNwYXduLXdhaXQKbnRtIC0tcm9ib3QtaW50ZXJydXB0PVNFU1NJT04KbnRtIC0tcm9ib3QtYXNzaWduPVNFU1NJT04gLS1hc3NpZ24tYmVhZHM9YmQtMSxiZC0yCm50bSAtLXJvYm90LXJlcGxheT1TRVNTSU9OIC0tcmVwbGF5LWlkPUlECmBgYAoKIyMjIEJlYWQgTWFuYWdlbWVudAoKYGBgYmFzaApudG0gLS1yb2JvdC1iZWFkLWNsYWltPUJFQURfSUQgLS1iZWFkLWFzc2lnbmVlPWFnZW50Cm50bSAtLXJvYm90LWJlYWQtY3JlYXRlIC0tYmVhZC10aXRsZT0iRml4IGJ1ZyIgLS1iZWFkLXR5cGU9YnVnCm50bSAtLXJvYm90LWJlYWQtc2hvdz1CRUFEX0lECm50bSAtLXJvYm90LWJlYWQtY2xvc2U9QkVBRF9JRCAtLWJlYWQtY2xvc2UtcmVhc29uPSJGaXhlZCIKYGBgCgojIyMgQ0FTUyBJbnRlZ3JhdGlvbgoKYGBgYmFzaApudG0gLS1yb2JvdC1jYXNzLXNlYXJjaD0iYXV0aCBlcnJvciIgLS1jYXNzLXNpbmNlPTdkCm50bSAtLXJvYm90LWNhc3MtY29udGV4dD0iaG93IHRvIGltcGxlbWVudCBhdXRoIgpudG0gLS1yb2JvdC1jYXNzLXN0YXR1cwpgYGAKCiMjIyBFeGl0IENvZGVzCgp8IENvZGUgfCBNZWFuaW5nIHwKfC0tLS0tLXwtLS0tLS0tLS18CnwgYDBgIHwgU3VjY2VzcyB8CnwgYDFgIHwgRXJyb3IgfAp8IGAyYCB8IFVuYXZhaWxhYmxlL05vdCBpbXBsZW1lbnRlZCB8CgojIyBXb3JrIERpc3RyaWJ1dGlvbgoKSW50ZWdyYXRpb24gd2l0aCBCViBmb3IgaW50ZWxsaWdlbnQgd29yayBhc3NpZ25tZW50OgoKYGBgYmFzaApudG0gd29yayB0cmlhZ2UgICAgICAgICAgICAgICAjIEZ1bGwgdHJpYWdlIHdpdGggcmVjb21tZW5kYXRpb25zCm50bSB3b3JrIHRyaWFnZSAtLWJ5LWxhYmVsICAgICMgR3JvdXAgYnkgZG9tYWluCm50bSB3b3JrIHRyaWFnZSAtLXF1aWNrICAgICAgICMgUXVpY2sgd2lucyBvbmx5Cm50bSB3b3JrIGFsZXJ0cyAgICAgICAgICAgICAgICMgU3RhbGUgaXNzdWVzLCBwcmlvcml0eSBkcmlmdCwgY3ljbGVzCm50bSB3b3JrIHNlYXJjaCAiSldUIGF1dGgiICAgICMgU2VtYW50aWMgc2VhcmNoCm50bSB3b3JrIGltcGFjdCBzcmMvYXBpLyouZ28gICMgSW1wYWN0IGFuYWx5c2lzCm50bSB3b3JrIG5leHQgICAgICAgICAgICAgICAgICMgU2luZ2xlIGJlc3QgbmV4dCBhY3Rpb24KYGBgCgojIyMgSW50ZWxsaWdlbnQgQXNzaWdubWVudAoKYGBgYmFzaApudG0gLS1yb2JvdC1hc3NpZ249bXlwcm9qZWN0IC0tYXNzaWduLXN0cmF0ZWd5PWJhbGFuY2VkICAjIERlZmF1bHQKbnRtIC0tcm9ib3QtYXNzaWduPW15cHJvamVjdCAtLWFzc2lnbi1zdHJhdGVneT1zcGVlZCAgICAgIyBNYXhpbWl6ZSB0aHJvdWdocHV0Cm50bSAtLXJvYm90LWFzc2lnbj1teXByb2plY3QgLS1hc3NpZ24tc3RyYXRlZ3k9cXVhbGl0eSAgICMgQmVzdCBhZ2VudC10YXNrIG1hdGNoCm50bSAtLXJvYm90LWFzc2lnbj1teXByb2plY3QgLS1hc3NpZ24tc3RyYXRlZ3k9ZGVwZW5kZW5jeSAjIFVuYmxvY2sgZG93bnN0cmVhbQpgYGAKCiMjIyBBZ2VudCBDYXBhYmlsaXR5IE1hdHJpeAoKfCBBZ2VudCB8IEJlc3QgQXQgfAp8LS0tLS0tLXwtLS0tLS0tLS18CnwgKipDbGF1ZGUqKiB8IEFuYWx5c2lzLCByZWZhY3RvcmluZywgZG9jdW1lbnRhdGlvbiwgYXJjaGl0ZWN0dXJlIHwKfCAqKkNvZGV4KiogfCBGZWF0dXJlIGltcGxlbWVudGF0aW9uLCBidWcgZml4ZXMsIHF1aWNrIHRhc2tzIHwKfCAqKkdlbWluaSoqIHwgRG9jdW1lbnRhdGlvbiwgYW5hbHlzaXMsIGZlYXR1cmVzIHwKCiMjIFByb2ZpbGVzICYgUGVyc29uYXMKCmBgYGJhc2gKbnRtIHByb2ZpbGVzIGxpc3QgICAgICAgICAgICAgICAgICAgICMgTGlzdCBwcm9maWxlcwpudG0gcHJvZmlsZXMgc2hvdyBhcmNoaXRlY3QgICAgICAgICAgIyBTaG93IGRldGFpbHMKbnRtIHNwYXduIG15cHJvamVjdCAtLXByb2ZpbGVzPWFyY2hpdGVjdCxpbXBsZW1lbnRlcix0ZXN0ZXIKbnRtIHNwYXduIG15cHJvamVjdCAtLXByb2ZpbGUtc2V0PWJhY2tlbmQtdGVhbQpgYGAKCiMjIyBCdWlsdC1pbiBQcm9maWxlcwoKYGFyY2hpdGVjdGAsIGBpbXBsZW1lbnRlcmAsIGByZXZpZXdlcmAsIGB0ZXN0ZXJgLCBgZG9jdW1lbnRlcmAKCiMjIEFnZW50IE1haWwgSW50ZWdyYXRpb24KCmBgYGJhc2gKbnRtIG1haWwgc2VuZCBteXByb2plY3QgLS10byBHcmVlbkNhc3RsZSAiUmV2aWV3IEFQSSBjaGFuZ2VzIgpudG0gbWFpbCBzZW5kIG15cHJvamVjdCAtLWFsbCAiQ2hlY2twb2ludDogc3luYyBzdGF0dXMiCm50bSBtYWlsIGluYm94IG15cHJvamVjdApudG0gbWFpbCByZWFkIG15cHJvamVjdCAtLWFnZW50IEJsdWVMYWtlCm50bSBtYWlsIGFjayBteXByb2plY3QgNDIKYGBgCgojIyMgUHJlLWNvbW1pdCBHdWFyZAoKYGBgYmFzaApudG0gaG9va3MgZ3VhcmQgaW5zdGFsbCAgICAjIFByZXZlbnQgY29uZmxpY3RpbmcgY29tbWl0cwpudG0gaG9va3MgZ3VhcmQgdW5pbnN0YWxsCmBgYAoKIyMgTm90aWZpY2F0aW9ucwoKTXVsdGktY2hhbm5lbCBub3RpZmljYXRpb25zIGZvciBldmVudHM6CgpgYGB0b21sCltub3RpZmljYXRpb25zXQplbmFibGVkID0gdHJ1ZQpldmVudHMgPSBbImFnZW50LmVycm9yIiwgImFnZW50LmNyYXNoZWQiLCAiYWdlbnQucmF0ZV9saW1pdCJdCgpbbm90aWZpY2F0aW9ucy5kZXNrdG9wXQplbmFibGVkID0gdHJ1ZQoKW25vdGlmaWNhdGlvbnMud2ViaG9va10KZW5hYmxlZCA9IHRydWUKdXJsID0gImh0dHBzOi8vaG9va3Muc2xhY2suY29tLy4uLiIKYGBgCgojIyMgRXZlbnQgVHlwZXMKCmBhZ2VudC5lcnJvcmAsIGBhZ2VudC5jcmFzaGVkYCwgYGFnZW50LnJhdGVfbGltaXRgLCBgcm90YXRpb24ubmVlZGVkYCwgYHNlc3Npb24uY3JlYXRlZGAsIGBzZXNzaW9uLmtpbGxlZGAsIGBoZWFsdGguZGVncmFkZWRgCgojIyBBbGVydGluZyBTeXN0ZW0KCiMjIyBBbGVydCBUeXBlcwoKfCBUeXBlIHwgU2V2ZXJpdHkgfCBEZXNjcmlwdGlvbiB8CnwtLS0tLS18LS0tLS0tLS0tLXwtLS0tLS0tLS0tLS0tfAp8IGB1bmhlYWx0aHlgIHwgSGlnaCB8IEFnZW50IGVudGVycyB1bmhlYWx0aHkgc3RhdGUgfAp8IGBkZWdyYWRlZGAgfCBNZWRpdW0gfCBBZ2VudCBwZXJmb3JtYW5jZSBkZWdyYWRlcyB8CnwgYHJhdGVfbGltaXRlZGAgfCBNZWRpdW0gfCBBUEkgcmF0ZSBsaW1pdCBkZXRlY3RlZCB8CnwgYHJlc3RhcnRfZmFpbGVkYCB8IEhpZ2ggfCBSZXN0YXJ0IGF0dGVtcHQgZmFpbGVkIHwKfCBgbWF4X3Jlc3RhcnRzYCB8IENyaXRpY2FsIHwgUmVzdGFydCBsaW1pdCBleGNlZWRlZCB8CgpgYGBiYXNoCm50bSAtLXJvYm90LWFsZXJ0cwpudG0gLS1yb2JvdC1kaXNtaXNzLWFsZXJ0PUFMRVJUX0lECmBgYAoKIyMgQ29tbWFuZCBIb29rcwoKYGBgdG9tbAojIH4vLmNvbmZpZy9udG0vaG9va3MudG9tbAoKW1tjb21tYW5kX2hvb2tzXV0KZXZlbnQgPSAicG9zdC1zcGF3biIKY29tbWFuZCA9ICJub3RpZnktc2VuZCAnTlRNJyAnQWdlbnRzIHNwYXduZWQnIgoKW1tjb21tYW5kX2hvb2tzXV0KZXZlbnQgPSAicHJlLXNlbmQiCmNvbW1hbmQgPSAiZWNobyBcIiQoZGF0ZSk6ICROVE1fTUVTU0FHRVwiID4+IH4vLm50bS1zZW5kLmxvZyIKYGBgCgojIyMgQXZhaWxhYmxlIEV2ZW50cwoKYHByZS1zcGF3bmAsIGBwb3N0LXNwYXduYCwgYHByZS1zZW5kYCwgYHBvc3Qtc2VuZGAsIGBwcmUtYWRkYCwgYHBvc3QtYWRkYCwgYHByZS1zaHV0ZG93bmAsIGBwb3N0LXNodXRkb3duYAoKIyMgU2FmZXR5IFN5c3RlbQoKQmxvY2tzIGRhbmdlcm91cyBjb21tYW5kcyBmcm9tIEFJIGFnZW50czoKCmBgYGJhc2gKbnRtIHNhZmV0eSBzdGF0dXMgICAgICAgICAgICAgICMgUHJvdGVjdGlvbiBzdGF0dXMKbnRtIHNhZmV0eSBjaGVjayAiZ2l0IHJlc2V0IC0taGFyZCIKbnRtIHNhZmV0eSBpbnN0YWxsICAgICAgICAgICAgICMgSW5zdGFsbCBnaXQgd3JhcHBlciArIENsYXVkZSBob29rCm50bSBzYWZldHkgdW5pbnN0YWxsCmBgYAoKIyMjIFByb3RlY3RlZCBDb21tYW5kcwoKfCBQYXR0ZXJuIHwgUmlzayB8IEFjdGlvbiB8CnwtLS0tLS0tLS18LS0tLS0tfC0tLS0tLS0tfAp8IGBnaXQgcmVzZXQgLS1oYXJkYCB8IExvc2VzIHVuY29tbWl0dGVkIGNoYW5nZXMgfCBCbG9jayB8CnwgYGdpdCBwdXNoIC0tZm9yY2VgIHwgT3ZlcndyaXRlcyByZW1vdGUgaGlzdG9yeSB8IEJsb2NrIHwKfCBgcm0gLXJmIC9gIHwgQ2F0YXN0cm9waGljIGRlbGV0aW9uIHwgQmxvY2sgfAp8IGBEUk9QIFRBQkxFYCB8IERhdGFiYXNlIGRlc3RydWN0aW9uIHwgQmxvY2sgfAoKIyMgTXVsdGktQWdlbnQgU3RyYXRlZ2llcwoKIyMjIERpdmlkZSBhbmQgQ29ucXVlcgoKYGBgYmFzaApudG0gc2VuZCBteXByb2plY3QgLS1jYyAiZGVzaWduIHRoZSBkYXRhYmFzZSBzY2hlbWEiCm50bSBzZW5kIG15cHJvamVjdCAtLWNvZCAiaW1wbGVtZW50IHRoZSBtb2RlbHMiCm50bSBzZW5kIG15cHJvamVjdCAtLWdtaSAid3JpdGUgdGVzdHMiCmBgYAoKIyMjIENvbXBldGl0aXZlIENvbXBhcmlzb24KCmBgYGJhc2gKbnRtIHNlbmQgbXlwcm9qZWN0IC0tYWxsICJpbXBsZW1lbnQgYSByYXRlIGxpbWl0ZXIiCm50bSB2aWV3IG15cHJvamVjdCAgIyBDb21wYXJlIHNpZGUtYnktc2lkZQpgYGAKCiMjIyBSZXZpZXcgUGlwZWxpbmUKCmBgYGJhc2gKbnRtIHNlbmQgbXlwcm9qZWN0IC0tY2MgImltcGxlbWVudCBmZWF0dXJlIFgiCm50bSBzZW5kIG15cHJvamVjdCAtLWNvZCAicmV2aWV3IENsYXVkZSdzIGNvZGUiCm50bSBzZW5kIG15cHJvamVjdCAtLWdtaSAid3JpdGUgdGVzdHMgZm9yIGVkZ2UgY2FzZXMiCmBgYAoKIyMgQ29uZmlndXJhdGlvbgoKYGBgYmFzaApudG0gY29uZmlnIGluaXQgICAgICAgICAgIyBDcmVhdGUgfi8uY29uZmlnL250bS9jb25maWcudG9tbApudG0gY29uZmlnIHNob3cgICAgICAgICAgIyBTaG93IGN1cnJlbnQgY29uZmlnCm50bSBjb25maWcgcHJvamVjdCBpbml0ICAjIENyZWF0ZSAubnRtL2NvbmZpZy50b21sIGluIHByb2plY3QKYGBgCgojIyMgRXhhbXBsZSBDb25maWcKCmBgYHRvbWwKcHJvamVjdHNfYmFzZSA9ICJ+L0RldmVsb3BlciIKClthZ2VudHNdCmNsYXVkZSA9ICdjbGF1ZGUgLS1kYW5nZXJvdXNseS1za2lwLXBlcm1pc3Npb25zJwpjb2RleCA9ICJjb2RleCAtLWRhbmdlcm91c2x5LWJ5cGFzcy1hcHByb3ZhbHMtYW5kLXNhbmRib3giCmdlbWluaSA9ICJnZW1pbmkgLS15b2xvIgoKW3RtdXhdCmRlZmF1bHRfcGFuZXMgPSAxMApwYWxldHRlX2tleSA9ICJGNiIKCltjb250ZXh0X3JvdGF0aW9uXQplbmFibGVkID0gdHJ1ZQp3YXJuaW5nX3RocmVzaG9sZCA9IDAuODAKcm90YXRlX3RocmVzaG9sZCA9IDAuOTUKYGBgCgojIyBFbnZpcm9ubWVudCBWYXJpYWJsZXMKCnwgVmFyaWFibGUgfCBEZXNjcmlwdGlvbiB8CnwtLS0tLS0tLS0tfC0tLS0tLS0tLS0tLS18CnwgYE5UTV9QUk9KRUNUU19CQVNFYCB8IEJhc2UgZGlyZWN0b3J5IGZvciBwcm9qZWN0cyB8CnwgYE5UTV9USEVNRWAgfCBDb2xvciB0aGVtZTogYGF1dG9gLCBgbW9jaGFgLCBgbGF0dGVgLCBgbm9yZGAsIGBwbGFpbmAgfAp8IGBOVE1fSUNPTlNgIHwgSWNvbiBzZXQ6IGBuZXJkYCwgYHVuaWNvZGVgLCBgYXNjaWlgIHwKfCBgTlRNX1JFRFVDRV9NT1RJT05gIHwgRGlzYWJsZSBhbmltYXRpb25zIHwKfCBgTlRNX1BST0ZJTEVgIHwgRW5hYmxlIHBlcmZvcm1hbmNlIHByb2ZpbGluZyB8CgojIyBUaGVtZXMgJiBEaXNwbGF5CgojIyMgQ29sb3IgVGhlbWVzCgp8IFRoZW1lIHwgRGVzY3JpcHRpb24gfAp8LS0tLS0tLXwtLS0tLS0tLS0tLS0tfAp8IGBhdXRvYCB8IERldGVjdCBsaWdodC9kYXJrIHwKfCBgbW9jaGFgIHwgRGVmYXVsdCBkYXJrLCB3YXJtIHwKfCBgbGF0dGVgIHwgTGlnaHQgdmFyaWFudCB8CnwgYG5vcmRgIHwgQXJjdGljLWluc3BpcmVkIHwKfCBgcGxhaW5gIHwgTm8gY29sb3IgfAoKIyMjIEFnZW50IENvbG9ycwoKfCBBZ2VudCB8IENvbG9yIHwKfC0tLS0tLS18LS0tLS0tLXwKfCBDbGF1ZGUgfCBNYXV2ZSAoUHVycGxlKSB8CnwgQ29kZXggfCBCbHVlIHwKfCBHZW1pbmkgfCBZZWxsb3cgfAp8IFVzZXIgfCBHcmVlbiB8CgojIyMgRGlzcGxheSBXaWR0aCBUaWVycwoKfCBXaWR0aCB8IEJlaGF2aW9yIHwKfC0tLS0tLS18LS0tLS0tLS0tLXwKfCA8MTIwIGNvbHMgfCBTdGFja2VkIGxheW91dCB8CnwgMTIwLTE5OSBjb2xzIHwgTGlzdC9kZXRhaWwgc3BsaXQgfAp8IDIwMC0yMzkgY29scyB8IFdpZGVyIGd1dHRlcnMgfAp8IDI0MCsgY29scyB8IEZ1bGwgZGV0YWlsIHwKCiMjIFBhbmUgTmFtaW5nIENvbnZlbnRpb24KClBhdHRlcm46IGA8cHJvamVjdD5fXzxhZ2VudD5fPG51bWJlcj5gCgotIGBteXByb2plY3RfX2NjXzFgIC0gRmlyc3QgQ2xhdWRlCi0gYG15cHJvamVjdF9fY29kXzJgIC0gU2Vjb25kIENvZGV4Ci0gYG15cHJvamVjdF9fZ21pXzFgIC0gRmlyc3QgR2VtaW5pCgpTdGF0dXMgaW5kaWNhdG9yczogKipDKiogPSBDbGF1ZGUsICoqWCoqID0gQ29kZXgsICoqRyoqID0gR2VtaW5pLCAqKlUqKiA9IFVzZXIKCiMjIFNoZWxsIEFsaWFzZXMKCkFmdGVyIGBldmFsICIkKG50bSBzaGVsbCB6c2gpImA6Cgp8IENhdGVnb3J5IHwgQWxpYXNlcyB8CnwtLS0tLS0tLS0tfC0tLS0tLS0tLXwKfCBBZ2VudCBMYXVuY2ggfCBgY2NgLCBgY29kYCwgYGdtaWAgfAp8IFNlc3Npb24gfCBgY250YCwgYHNhdGAsIGBxcHNgIHwKfCBBZ2VudCBNZ210IHwgYGFudGAsIGBicGAsIGBpbnRgIHwKfCBOYXZpZ2F0aW9uIHwgYHJudGAsIGBsbnRgLCBgc250YCwgYHZudGAsIGB6bnRgIHwKfCBEYXNoYm9hcmQgfCBgZGFzaGAsIGBkYCB8CnwgT3V0cHV0IHwgYGNwbnRgLCBgc3ZudGAgfAp8IFV0aWxpdGllcyB8IGBuY3BgLCBga250YCwgYGNhZGAgfAoKIyMgSW5zdGFsbGF0aW9uCgpgYGBiYXNoCiMgT25lLWxpbmVyIChyZWNvbW1lbmRlZCkKY3VybCAtZnNTTCBodHRwczovL3Jhdy5naXRodWJ1c2VyY29udGVudC5jb20vRGlja2xlc3dvcnRoc3RvbmUvbnRtL21haW4vaW5zdGFsbC5zaCB8IGJhc2gKCiMgSG9tZWJyZXcKYnJldyBpbnN0YWxsIGRpY2tsZXN3b3J0aHN0b25lL3RhcC9udG0KCiMgR28gaW5zdGFsbApnbyBpbnN0YWxsIGdpdGh1Yi5jb20vRGlja2xlc3dvcnRoc3RvbmUvbnRtL2NtZC9udG1AbGF0ZXN0CgojIERvY2tlcgpkb2NrZXIgcHVsbCBnaGNyLmlvL2RpY2tsZXN3b3J0aHN0b25lL250bTpsYXRlc3QKYGBgCgojIyBVcGdyYWRlCgpgYGBiYXNoCm50bSB1cGdyYWRlICAgICAgICAgICAgICAjIENoZWNrIGFuZCBpbnN0YWxsIHVwZGF0ZXMKbnRtIHVwZ3JhZGUgLS1jaGVjayAgICAgICMgQ2hlY2sgb25seQpudG0gdXBncmFkZSAtLXllcyAgICAgICAgIyBBdXRvLWNvbmZpcm0KYGBgCgojIyBUbXV4IEVzc2VudGlhbHMKCnwgS2V5cyB8IEFjdGlvbiB8CnwtLS0tLS18LS0tLS0tLS18CnwgYEN0cmwrQiwgRGAgfCBEZXRhY2ggfAp8IGBDdHJsK0IsIFtgIHwgU2Nyb2xsL2NvcHkgbW9kZSB8CnwgYEN0cmwrQiwgemAgfCBUb2dnbGUgem9vbSB8CnwgYEN0cmwrQiwgQXJyb3dgIHwgTmF2aWdhdGUgcGFuZXMgfAp8IGBGNmAgfCBPcGVuIE5UTSBwYWxldHRlIChhZnRlciBgbnRtIGJpbmRgKSB8CgojIyBJbnRlZ3JhdGlvbiB3aXRoIEZseXdoZWVsCgp8IFRvb2wgfCBJbnRlZ3JhdGlvbiB8CnwtLS0tLS18LS0tLS0tLS0tLS0tLXwKfCAqKkFnZW50IE1haWwqKiB8IE1lc3NhZ2Ugcm91dGluZywgZmlsZSByZXNlcnZhdGlvbnMsIHByZS1jb21taXQgZ3VhcmQgfAp8ICoqQlYqKiB8IFdvcmsgZGlzdHJpYnV0aW9uLCB0cmlhZ2UsIGFzc2lnbm1lbnQgc3RyYXRlZ2llcyB8CnwgKipDQVNTKiogfCBTZWFyY2ggcGFzdCBzZXNzaW9ucyB2aWEgcm9ib3QgbW9kZSB8CnwgKipDTSoqIHwgUHJvY2VkdXJhbCBtZW1vcnkgZm9yIGFnZW50IGhhbmRvZmZzIHwKfCAqKkRDRyoqIHwgU2FmZXR5IHN5c3RlbSBpbnRlZ3JhdGlvbiB8CnwgKipVQlMqKiB8IEF1dG8tc2Nhbm5pbmcgb24gZmlsZSBjaGFuZ2VzIHw='

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
_install_claude_skill() {
    local skill_dir="${HOME}/.claude/skills/${TOOL_NAME}"

    # Check if Claude Code is installed
    if [[ ! -d "${HOME}/.claude" ]] && ! command -v claude &>/dev/null; then
        return 0  # Claude Code not installed, skip silently
    fi

    _log_info "Installing Claude Code skill..."

    # Create skill directory
    mkdir -p "$skill_dir"

    # Write skill file from decoded base64 content
    local skill_content
    skill_content=$(_decode_skill_content)
    if [[ -n "$skill_content" ]]; then
        printf '%s\n' "$skill_content" > "$skill_dir/SKILL.md"
        _log_ok "Claude Code skill installed: $skill_dir/SKILL.md"
        return 0
    else
        _log_warn "Skill content not embedded, skipping Claude Code skill"
        return 0
    fi
}

# Install skill for Codex CLI
_install_codex_skill() {
    local skill_dir="${HOME}/.codex/skills/${TOOL_NAME}"

    # Check if Codex CLI is installed
    if [[ ! -d "${HOME}/.codex" ]] && ! command -v codex &>/dev/null; then
        return 0  # Codex CLI not installed, skip silently
    fi

    _log_info "Installing Codex CLI skill..."

    # Create skill directory
    mkdir -p "$skill_dir"

    # Write skill file from decoded base64 content
    local skill_content
    skill_content=$(_decode_skill_content)
    if [[ -n "$skill_content" ]]; then
        printf '%s\n' "$skill_content" > "$skill_dir/SKILL.md"
        _log_ok "Codex CLI skill installed: $skill_dir/SKILL.md"
        return 0
    else
        _log_warn "Skill content not embedded, skipping Codex CLI skill"
        return 0
    fi
}

# Install skills for all detected AI coding agents
_install_skills() {
    if $_SKIP_SKILLS; then
        _log_info "Skipping skill installation (--no-skills)"
        return 0
    fi

    local installed_any=false

    echo "" >&2
    _log_info "Installing AI coding agent skills..."
    _log_info ""
    _log_info "Skills teach AI agents (Claude Code, Codex CLI) about ${TOOL_NAME}'s"
    _log_info "commands, workflows, and best practices. When you invoke /${TOOL_NAME} in"
    _log_info "a conversation, the agent gains specialized knowledge about the tool."
    _log_info ""

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
        _log_info "How to use the ${TOOL_NAME} skill:"
        _log_info "  1. Start a conversation with Claude Code or Codex CLI"
        _log_info "  2. Type /${TOOL_NAME} to invoke the skill"
        _log_info "  3. The agent will have full knowledge of ${TOOL_NAME} commands"
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
