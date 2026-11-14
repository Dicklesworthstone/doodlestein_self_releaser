#!/usr/bin/env bash
# install.sh - Install cass
#
# Usage:
#   curl -sSfL https://raw.githubusercontent.com/Dicklesworthstone/coding_agent_session_search/main/install.sh | bash
#   curl -sSfL https://raw.githubusercontent.com/Dicklesworthstone/coding_agent_session_search/main/install.sh | bash -s -- -v 1.2.3
#   curl -sSfL https://raw.githubusercontent.com/Dicklesworthstone/coding_agent_session_search/main/install.sh | bash -s -- --json
#
# Options:
#   -v, --version VERSION    Install specific version, e.g. 1.2.3 or v1.2.3 (default: latest)
#   -d, --dir DIR            Installation directory (default: ~/.local/bin)
#   -y, --yes                Replace an existing binary without asking
#   --recover               With --yes: recover a stopped installation (Python 3 required)
#   --mode vibe|safe         vibe (default) also installs agent skills; safe installs
#                            only the verified release binary (no skills, no source builds)
#   --verify                 Verify checksums (always enabled)
#   --require-signatures     Require a configured key and valid minisign signature
#   --json                   Output JSON for automation
#   --non-interactive        No prompts, fail on missing consent
#   --cache-dir DIR          Cache directory (default: ~/.cache/dsr/installers)
#   --offline [ARCHIVE]      No network; requires --version and local checksum evidence
#   --prefer-gh              Prefer gh release download for private repos
#   --from-source            Build source instead of downloading (explicit code-execution consent)
#   --allow-source-build     Allow source fallback when discovery/download is unavailable
#   --install-toolchain      With source consent: bootstrap a missing compiler for this build
#   --source-ref REF         With --from-source: HEAD, full SHA, refs/heads/* or refs/tags/*
#   --source-timeout SECONDS  Per-command source-build limit (default: 3600)
#   --source-if-stale N       With --allow-source-build: build head if latest is >N commits behind
#   --allow-build            Alias for --allow-source-build
#   --build-timeout SECONDS   Alias for --source-timeout
#   --prefer-source-if-stale  Use --source-if-stale with a default threshold of 10
#   --stale-threshold N       Threshold for --prefer-source-if-stale (0 through 999999)
#   --no-skills              Skip AI coding agent skill installation
#   --libc gnu|musl          Linux build variant to install (default: this system's C library)
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
TOOL_NAME='cass'
REPO='Dicklesworthstone/coding_agent_session_search'
BINARY_NAME='cass'
ARCHIVE_FORMAT_LINUX="tar.gz"
ARCHIVE_FORMAT_DARWIN="tar.gz"
ARCHIVE_FORMAT_WINDOWS="zip"
ARCHIVE_FORMAT_FREEBSD="tar.gz"
SUPPORTED_PLATFORM_PATTERN="^(linux/amd64|linux/arm64|linux/386|linux/armv7|darwin/amd64|darwin/arm64|windows/amd64|windows/arm64|windows/386|freebsd/amd64)$"
# The template is data, not shell code. Expand its variables only in the renderer.
ARTIFACT_NAMING='${name}-${os}-${arch}'
LINUX_LIBC_FALLBACK='none'
STRICT_RELEASE_CONTRACT=false

# Minisign public key for signature verification (embedded from dsr config)
# If empty, signature verification is skipped
MINISIGN_PUBKEY=""

# Validated source selection, embedded as data by the generator. The source
# engine below is embedded too: installed clients need no DSR checkout.
SOURCE_LANGUAGE='rust'
SOURCE_SUBDIR='.'
SOURCE_ENTRY=''
SOURCE_PACKAGE=''

#!/usr/bin/env bash
# toolchain_detect.sh - Toolchain detection and installation for dsr installers
#
# This module is designed to be embedded in or sourced by curl-bash installers.
# It detects toolchain availability, version compatibility, and offers safe
# installation without breaking existing setups.
#
# Usage:
#   source toolchain_detect.sh
#   toolchain_detect_all          # Detect all toolchains
#   toolchain_detect rust         # Detect specific toolchain
#   toolchain_ensure rust         # Ensure toolchain is available
#   toolchain_install rust        # Install if missing (with consent)
#
# Safety rules:
#   - NEVER overwrites existing toolchain installations
#   - NEVER auto-deletes user installations
#   - Always asks for consent before installing
#   - Respects --non-interactive mode

set -uo pipefail

# Version requirements (minimum supported)
TOOLCHAIN_RUST_MIN_VERSION="1.70.0"
TOOLCHAIN_GO_MIN_VERSION="1.21.0"
TOOLCHAIN_BUN_MIN_VERSION="1.0.0"
TOOLCHAIN_NODE_MIN_VERSION="18.0.0"

# Installation URLs
TOOLCHAIN_RUST_INSTALL_URL="https://sh.rustup.rs"
TOOLCHAIN_GO_DOWNLOAD_URL="https://go.dev/dl/"
TOOLCHAIN_BUN_INSTALL_URL="https://bun.sh/install"
TOOLCHAIN_NODE_DOWNLOAD_URL="https://nodejs.org/en/download/"

# State
_TC_NON_INTERACTIVE="${NON_INTERACTIVE:-false}"
_TC_VERBOSE="${VERBOSE:-false}"

# Colors (disable if NO_COLOR set or not a terminal)
if [[ -z "${NO_COLOR:-}" && -t 2 ]]; then
    _TC_RED=$'\033[0;31m'
    _TC_GREEN=$'\033[0;32m'
    _TC_YELLOW=$'\033[0;33m'
    _TC_BLUE=$'\033[0;34m'
    _TC_NC=$'\033[0m'
else
    _TC_RED='' _TC_GREEN='' _TC_YELLOW='' _TC_BLUE='' _TC_NC=''
fi

_tc_log_info()  { echo "${_TC_BLUE}[toolchain]${_TC_NC} $*" >&2; }
_tc_log_ok()    { echo "${_TC_GREEN}[toolchain]${_TC_NC} $*" >&2; }
_tc_log_warn()  { echo "${_TC_YELLOW}[toolchain]${_TC_NC} $*" >&2; }
_tc_log_error() { echo "${_TC_RED}[toolchain]${_TC_NC} $*" >&2; }

# Determine non-interactive mode (supports installers + dsr globals)
_tc_is_non_interactive() {
    [[ "${_TC_NON_INTERACTIVE:-false}" == "true" ]] || \
    [[ "${NON_INTERACTIVE:-}" == "true" ]] || \
    [[ "${_NON_INTERACTIVE:-}" == "true" ]] || \
    [[ "${DSR_NON_INTERACTIVE:-}" == "true" ]]
}

# Check for required dependencies
_tc_require_jq() {
    if ! command -v jq &>/dev/null; then
        _tc_log_error "jq is required but not installed"
        _tc_log_info "Install: apt install jq (Debian/Ubuntu) or brew install jq (macOS)"
        return 3
    fi
    return 0
}

_tc_require_curl() {
    if ! command -v curl &>/dev/null; then
        _tc_log_error "curl is required but not installed"
        return 3
    fi
    return 0
}

# Compare semver versions (pure bash - works on macOS/Linux/BSD)
# Returns: 0 if v1 >= v2, 1 if v1 < v2
_tc_version_ge() {
    local v1="$1"
    local v2="$2"

    # Extract numeric parts only
    v1=$(echo "$v1" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
    v2=$(echo "$v2" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)

    # Handle missing versions
    [[ -z "$v1" ]] && return 1
    [[ -z "$v2" ]] && return 0

    # Pure bash version comparison (portable - works without sort -V)
    local v1_parts v2_parts
    IFS='.' read -ra v1_parts <<< "$v1"
    IFS='.' read -ra v2_parts <<< "$v2"

    local i
    for ((i=0; i<3; i++)); do
        # Prefix segments with 10# so bash arithmetic uses base-10
        # explicitly. Without it, a version segment with a leading zero
        # (e.g. the "08" in a hypothetical 1.08.0 tag, or "09" in a
        # zero-padded build identifier) is parsed as octal and the
        # comparison aborts with "value too great for base" the moment
        # the digit is 8 or 9. The 10# prefix is safe for any pure-digit
        # string and standard practice for set -u shells.
        local n1=$((10#${v1_parts[i]:-0}))
        local n2=$((10#${v2_parts[i]:-0}))
        if ((n1 > n2)); then
            return 0
        elif ((n1 < n2)); then
            return 1
        fi
    done
    return 0  # Equal versions
}

# Detect OS and architecture
_tc_detect_platform() {
    local os arch

    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    case "$os" in
        darwin) os="darwin" ;;
        linux) os="linux" ;;
        mingw*|msys*|cygwin*) os="windows" ;;
        *) os="unknown" ;;
    esac

    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64) arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        armv7*) arch="armv7" ;;
        i386|i686) arch="386" ;;
        *) arch="unknown" ;;
    esac

    echo "$os/$arch"
}

# Prompt user for yes/no
# Usage: _tc_prompt "Question?" [default]
# Returns: 0 for yes, 1 for no
_tc_prompt() {
    local question="$1"
    local default="${2:-n}"

    if _tc_is_non_interactive; then
        _tc_log_error "Cannot prompt in non-interactive mode"
        _tc_log_info "Run interactively or use --yes to auto-approve"
        return 1
    fi

    local yn_prompt
    if [[ "$default" == "y" ]]; then
        yn_prompt="[Y/n]"
    else
        yn_prompt="[y/N]"
    fi

    local response
    read -rp "${_TC_BLUE}[toolchain]${_TC_NC} $question $yn_prompt " response
    response=${response:-$default}

    case "$response" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# ============================================================================
# RUST DETECTION
# ============================================================================

# Detect Rust installation
# Returns: JSON object with detection results
toolchain_detect_rust() {
    local installed=false
    local version=""
    local path=""
    local meets_minimum=false
    local install_method=""

    # Check for rustc
    if command -v rustc &>/dev/null; then
        installed=true
        version=$(rustc --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        path=$(command -v rustc)

        if _tc_version_ge "$version" "$TOOLCHAIN_RUST_MIN_VERSION"; then
            meets_minimum=true
        fi

        # Detect installation method
        if command -v rustup &>/dev/null; then
            install_method="rustup"
        elif [[ "$path" == *"/usr/bin/"* ]]; then
            install_method="system"
        elif [[ "$path" == *".cargo/bin/"* ]]; then
            install_method="cargo"
        else
            install_method="unknown"
        fi
    fi

    # Use jq for safe JSON construction
    jq -nc \
        --argjson installed "$installed" \
        --arg version "$version" \
        --arg path "$path" \
        --arg minimum_version "$TOOLCHAIN_RUST_MIN_VERSION" \
        --argjson meets_minimum "$meets_minimum" \
        --arg install_method "$install_method" \
        '{
            toolchain: "rust",
            installed: $installed,
            version: $version,
            path: $path,
            minimum_version: $minimum_version,
            meets_minimum: $meets_minimum,
            install_method: $install_method
        }'
}

# Install Rust via rustup
# Returns: 0 on success, 1 on failure
# shellcheck disable=SC2120  # Optional nightly parameter for future use
_tc_install_rust() {
    local nightly="${1:-false}"

    _tc_require_curl || return $?
    _tc_log_info "Installing Rust via rustup..."

    # Check if already installed
    if command -v rustc &>/dev/null; then
        _tc_log_warn "Rust is already installed at $(command -v rustc)"
        _tc_log_warn "Use 'rustup update' to update existing installation"
        return 1
    fi

    # Download and run rustup installer
    local rustup_args=("-y")
    if [[ "$nightly" == "true" ]]; then
        rustup_args+=("--default-toolchain" "nightly")
    fi

    if ! curl --proto '=https' --tlsv1.2 -sSf "$TOOLCHAIN_RUST_INSTALL_URL" | sh -s -- "${rustup_args[@]}"; then
        _tc_log_error "Failed to install Rust"
        return 1
    fi

    # Source cargo environment
    if [[ -f "$HOME/.cargo/env" ]]; then
        # shellcheck source=/dev/null
        source "$HOME/.cargo/env"
    fi

    _tc_log_ok "Rust installed successfully"
    _tc_log_info "Version: $(rustc --version 2>/dev/null)"
    return 0
}

# ============================================================================
# GO DETECTION
# ============================================================================

# Detect Go installation
toolchain_detect_go() {
    local installed=false
    local version=""
    local path=""
    local meets_minimum=false
    local goroot=""

    if command -v go &>/dev/null; then
        installed=true
        version=$(go version 2>/dev/null | grep -oE 'go[0-9]+\.[0-9]+(\.[0-9]+)?' | sed 's/go//')
        path=$(command -v go)
        goroot=$(go env GOROOT 2>/dev/null || echo "")

        if _tc_version_ge "$version" "$TOOLCHAIN_GO_MIN_VERSION"; then
            meets_minimum=true
        fi
    fi

    # Use jq for safe JSON construction
    jq -nc \
        --argjson installed "$installed" \
        --arg version "$version" \
        --arg path "$path" \
        --arg goroot "$goroot" \
        --arg minimum_version "$TOOLCHAIN_GO_MIN_VERSION" \
        --argjson meets_minimum "$meets_minimum" \
        '{
            toolchain: "go",
            installed: $installed,
            version: $version,
            path: $path,
            goroot: $goroot,
            minimum_version: $minimum_version,
            meets_minimum: $meets_minimum
        }'
}

# Install Go
# shellcheck disable=SC2120  # Optional version parameter for future use
_tc_install_go() {
    local go_version="${1:-1.23.0}"

    _tc_require_curl || return $?
    _tc_log_info "Installing Go $go_version..."

    if command -v go &>/dev/null; then
        _tc_log_warn "Go is already installed at $(command -v go)"
        _tc_log_info "Manual upgrade instructions:"
        _tc_log_info "  1. Download from $TOOLCHAIN_GO_DOWNLOAD_URL"
        _tc_log_info "  2. Remove existing: sudo rm -rf /usr/local/go"
        _tc_log_info "  3. Extract: sudo tar -C /usr/local -xzf go*.tar.gz"
        return 1
    fi

    local platform
    platform=$(_tc_detect_platform)
    local os="${platform%/*}"
    local arch="${platform#*/}"

    local download_url="${TOOLCHAIN_GO_DOWNLOAD_URL}go${go_version}.${os}-${arch}.tar.gz"

    _tc_log_info "Downloading from: $download_url"

    # Download to temp
    local temp_file
    temp_file=$(mktemp)
    if ! curl -sSL "$download_url" -o "$temp_file"; then
        _tc_log_error "Failed to download Go"
        rm -f "$temp_file"
        return 1
    fi

    # Check if we can write to /usr/local
    local extract_ok=false
    if [[ -w /usr/local ]]; then
        if tar -C /usr/local -xzf "$temp_file"; then
            extract_ok=true
        fi
    else
        _tc_log_info "Need sudo to install to /usr/local/go"
        if sudo tar -C /usr/local -xzf "$temp_file"; then
            extract_ok=true
        fi
    fi

    rm -f "$temp_file"

    if [[ "$extract_ok" != "true" ]]; then
        _tc_log_error "Failed to extract Go archive"
        return 1
    fi

    # Add to PATH hint
    _tc_log_ok "Go installed to /usr/local/go"
    _tc_log_info "Add to PATH: export PATH=\$PATH:/usr/local/go/bin"

    return 0
}

# ============================================================================
# BUN DETECTION
# ============================================================================

# Detect Bun installation
toolchain_detect_bun() {
    local installed=false
    local version=""
    local path=""
    local meets_minimum=false

    if command -v bun &>/dev/null; then
        installed=true
        version=$(bun --version 2>/dev/null | head -1)
        path=$(command -v bun)

        if _tc_version_ge "$version" "$TOOLCHAIN_BUN_MIN_VERSION"; then
            meets_minimum=true
        fi
    fi

    # Use jq for safe JSON construction
    jq -nc \
        --argjson installed "$installed" \
        --arg version "$version" \
        --arg path "$path" \
        --arg minimum_version "$TOOLCHAIN_BUN_MIN_VERSION" \
        --argjson meets_minimum "$meets_minimum" \
        '{
            toolchain: "bun",
            installed: $installed,
            version: $version,
            path: $path,
            minimum_version: $minimum_version,
            meets_minimum: $meets_minimum
        }'
}

# Install Bun
_tc_install_bun() {
    _tc_require_curl || return $?
    _tc_log_info "Installing Bun..."

    if command -v bun &>/dev/null; then
        _tc_log_warn "Bun is already installed at $(command -v bun)"
        _tc_log_info "Upgrade with: bun upgrade"
        return 1
    fi

    if ! curl -fsSL "$TOOLCHAIN_BUN_INSTALL_URL" | bash; then
        _tc_log_error "Failed to install Bun"
        return 1
    fi

    # Source bun if available
    if [[ -f "$HOME/.bun/bin/bun" ]]; then
        export BUN_INSTALL="$HOME/.bun"
        export PATH="$BUN_INSTALL/bin:$PATH"
    fi

    _tc_log_ok "Bun installed successfully"
    return 0
}

# ============================================================================
# NODE DETECTION
# ============================================================================

# Detect Node.js installation
toolchain_detect_node() {
    local installed=false
    local version=""
    local path=""
    local meets_minimum=false
    local npm_version=""

    if command -v node &>/dev/null; then
        installed=true
        version=$(node --version 2>/dev/null | sed 's/^v//')
        path=$(command -v node)

        if _tc_version_ge "$version" "$TOOLCHAIN_NODE_MIN_VERSION"; then
            meets_minimum=true
        fi

        if command -v npm &>/dev/null; then
            npm_version=$(npm --version 2>/dev/null)
        fi
    fi

    # Use jq for safe JSON construction
    jq -nc \
        --argjson installed "$installed" \
        --arg version "$version" \
        --arg path "$path" \
        --arg npm_version "$npm_version" \
        --arg minimum_version "$TOOLCHAIN_NODE_MIN_VERSION" \
        --argjson meets_minimum "$meets_minimum" \
        '{
            toolchain: "node",
            installed: $installed,
            version: $version,
            path: $path,
            npm_version: $npm_version,
            minimum_version: $minimum_version,
            meets_minimum: $meets_minimum
        }'
}

# ============================================================================
# UNIFIED INTERFACE
# ============================================================================

# Detect a specific toolchain
# Usage: toolchain_detect <toolchain>
# Returns: JSON detection result
toolchain_detect() {
    local toolchain="${1:-}"

    case "$toolchain" in
        rust|rustc|cargo)
            toolchain_detect_rust
            ;;
        go|golang)
            toolchain_detect_go
            ;;
        bun)
            toolchain_detect_bun
            ;;
        node|nodejs|npm)
            toolchain_detect_node
            ;;
        *)
            _tc_log_error "Unknown toolchain: $toolchain"
            _tc_log_info "Supported: rust, go, bun, node"
            return 4
            ;;
    esac
}

# Detect all toolchains
# Returns: JSON array of all detection results
toolchain_detect_all() {
    local rust_json go_json bun_json node_json platform
    rust_json=$(toolchain_detect_rust)
    go_json=$(toolchain_detect_go)
    bun_json=$(toolchain_detect_bun)
    node_json=$(toolchain_detect_node)
    platform=$(_tc_detect_platform)

    # Use jq to safely combine JSON objects
    jq -nc \
        --arg platform "$platform" \
        --argjson rust "$rust_json" \
        --argjson go "$go_json" \
        --argjson bun "$bun_json" \
        --argjson node "$node_json" \
        '{
            platform: $platform,
            toolchains: [$rust, $go, $bun, $node]
        }'
}

# Ensure a toolchain is available (detect + optionally install)
# Usage: toolchain_ensure <toolchain> [--install]
# Returns: 0 if available, 1 if not
toolchain_ensure() {
    local toolchain="${1:-}"
    local auto_install=false
    [[ "${2:-}" == "--install" ]] && auto_install=true

    _tc_require_jq || return $?

    local result
    result=$(toolchain_detect "$toolchain")

    local installed meets_minimum
    installed=$(echo "$result" | jq -r '.installed')
    meets_minimum=$(echo "$result" | jq -r '.meets_minimum')

    if [[ "$installed" == "true" && "$meets_minimum" == "true" ]]; then
        _tc_log_ok "$toolchain: OK ($(echo "$result" | jq -r '.version'))"
        return 0
    elif [[ "$installed" == "true" && "$meets_minimum" == "false" ]]; then
        local version min_version
        version=$(echo "$result" | jq -r '.version')
        min_version=$(echo "$result" | jq -r '.minimum_version')
        _tc_log_warn "$toolchain: Installed ($version) but below minimum ($min_version)"
        _tc_log_info "Manual upgrade recommended - existing install preserved"
        return 1
    else
        _tc_log_warn "$toolchain: Not installed"

        if $auto_install; then
            if _tc_prompt "Install $toolchain?" "y"; then
                toolchain_install "$toolchain"
                return $?
            fi
        fi

        return 1
    fi
}

# Install a toolchain (with user consent)
# Usage: toolchain_install <toolchain> [--yes]
# Returns: 0 on success, 1 on failure
toolchain_install() {
    local toolchain="${1:-}"
    local auto_yes=false
    [[ "${2:-}" == "--yes" ]] && auto_yes=true

    _tc_require_jq || return $?
    _tc_require_curl || return $?

    # Check if already installed
    local result
    result=$(toolchain_detect "$toolchain")
    local installed
    installed=$(echo "$result" | jq -r '.installed')

    if [[ "$installed" == "true" ]]; then
        local path version
        path=$(echo "$result" | jq -r '.path')
        version=$(echo "$result" | jq -r '.version')
        _tc_log_warn "$toolchain is already installed"
        _tc_log_info "  Path: $path"
        _tc_log_info "  Version: $version"
        _tc_log_info "Existing installation preserved - use native tools to upgrade"
        return 1
    fi

    # Confirm installation
    if ! $auto_yes && ! _tc_prompt "Install $toolchain?"; then
        _tc_log_info "Installation cancelled"
        return 1
    fi

    # Perform installation
    case "$toolchain" in
        rust|rustc|cargo)
            _tc_install_rust
            ;;
        go|golang)
            _tc_install_go
            ;;
        bun)
            _tc_install_bun
            ;;
        node|nodejs)
            _tc_log_error "Node.js installation not automated"
            _tc_log_info "Please install from: $TOOLCHAIN_NODE_DOWNLOAD_URL"
            _tc_log_info "Or use a version manager like nvm, fnm, or volta"
            return 1
            ;;
        *)
            _tc_log_error "Unknown toolchain: $toolchain"
            return 4
            ;;
    esac
}

# Download only from the official distribution endpoints selected below. A
# bootstrap is private and fresh: never let a retained file or symlink redirect
# an upstream download, and never execute an unverified partial response.
_tc_bootstrap_fetch() {
    local url="$1" output="$2" maximum="${3:-1073741824}"
    [[ "$url" == https://* && ! -e "$output" && ! -L "$output" ]] || return 4
    curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 15 \
        --max-time 300 --retry 2 --max-filesize "$maximum" "$url" -o "$output" || return 8
    [[ -f "$output" && ! -L "$output" && -s "$output" ]] || return 8
}

_tc_bootstrap_sha256() {
    local hash
    [[ -f "$1" && ! -L "$1" && -s "$1" ]] || return 1
    if command -v sha256sum >/dev/null 2>&1; then hash=$(sha256sum < "$1") || return 1
    elif command -v shasum >/dev/null 2>&1; then hash=$(shasum -a 256 < "$1") || return 1
    else return 3; fi
    hash="${hash%% *}"
    [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$hash"
}

_tc_bootstrap_checksum() {
    local file="$1" selected="$2"
    LC_ALL=C awk -v name="$selected" '
        { sub(/\r$/, "") }
        NF == 0 { next }
        {
            hash=substr($0,1,64); sep=substr($0,65,2); entry=substr($0,67)
            if ((sep == "  " || sep == " *") && entry == name) {
                count++; value=hash
                if (length(hash) != 64 || hash !~ /^[0-9a-fA-F]+$/) bad=1
            }
        }
        END { if (count == 1 && !bad) print tolower(value); else exit 1 }
    ' "$file"
}

_tc_bootstrap_linux_libc() {
    local value=''
    if command -v getconf >/dev/null 2>&1; then
        value=$(getconf GNU_LIBC_VERSION 2>/dev/null) || true
        [[ "$value" != glibc\ * ]] || { printf 'gnu\n'; return 0; }
    fi
    if command -v ldd >/dev/null 2>&1; then
        value=$(ldd --version 2>&1) || true
        case "${value,,}" in
            *musl*) printf 'musl\n'; return 0 ;;
            *glibc*|*'gnu libc'*|*'gnu c library'*) printf 'gnu\n'; return 0 ;;
        esac
    fi
    _tc_log_error 'Cannot identify the Linux C library for toolchain bootstrap'
    return 3
}

# Go's official archive has one go/ root and regular files/directories. Inspect
# the complete member list before extraction, retaining no links, duplicate
# paths, special files or paths outside that root. No system prefix is touched.
_tc_bootstrap_extract_go() {
    local archive="$1" destination="$2" members listing member normalized='' duplicate line
    local count=0 types=0
    members=$(tar -tzf "$archive") || return 7
    listing=$(LC_ALL=C tar -tvzf "$archive") || return 7
    [[ -n "$members" ]] || return 7
    while IFS= read -r member; do
        count=$((count + 1))
        [[ "$member" != *[[:cntrl:]]* && "$member" != *\\* && "$member" == go/* ]] || return 7
        member="${member%/}"
        case "/$member/" in *'/../'*|*'/./'*|*'//'*) return 7 ;; esac
        normalized+="$member"$'\n'
    done <<< "$members"
    duplicate=$(printf '%s' "$normalized" | LC_ALL=C sort | LC_ALL=C uniq -d) || return 7
    [[ -z "$duplicate" ]] || return 7
    while IFS= read -r line; do
        case "${line:0:1}" in -|d) types=$((types + 1)) ;; *) return 7 ;; esac
    done <<< "$listing"
    [[ "$count" -eq "$types" ]] || return 7
    tar --no-same-owner --no-same-permissions -xzf "$archive" -C "$destination" || return 7
    [[ -f "$destination/go/bin/go" && ! -L "$destination/go/bin/go" ]] || return 7
}

_tc_go_required_version() {
    local requirements="$1" requested implicit=1.16
    local version_pattern='^go[1-9][0-9]*\.[0-9]+(\.[0-9]+)?$'
    [[ -f "$requirements" && ! -L "$requirements" ]] || return 4
    [[ "${requirements##*/}" != go.work ]] || implicit=1.18
    # The go directive is the minimum; toolchain may suggest a newer compiler.
    # Use the higher numeric requirement. A major.minor selects its newest
    # published patch, never a different minor. Missing go directives use Go's
    # documented module/workspace defaults. The source engine admits this file
    # from its pinned checkout; the same selection drives installed-Go admission
    # and private bootstrap. Go parses the full file after compiler selection.
    requested=$(awk -v implicit="$implicit" '
        function at_least(selected, minimum, a, b, n, m, i, left, right) {
            n=split(selected,a,"."); m=split(minimum,b,".")
            for (i=1; i<=3; i++) {
                left=(i<=n ? a[i]+0 : 0); right=(i<=m ? b[i]+0 : 0)
                if (left > right) return 1
                if (left < right) return 0
            }
            return 1
        }
        { sub(/\r$/, ""); sub(/\/\/.*/, "") }
        $1 == "go" {
            if (NF != 2 || ++g != 1 || $2 !~ /^[1-9][0-9]*\.[0-9]+(\.[0-9]+)?$/) bad=1
            version=$2
        }
        $1 == "toolchain" {
            if (NF != 2 || ++t != 1 || ($2 != "default" && $2 !~ /^go[1-9][0-9]*\.[0-9]+(\.[0-9]+)?$/)) bad=1
            selected=$2
        }
        END {
            if (bad) exit 1
            if (!g) version=implicit
            if (selected != "" && selected != "default") {
                if (at_least(substr(selected,3),version)) print selected
                else print "go" version
            }
            else print "go" version
        }' "$requirements") || {
        _tc_log_error 'Go bootstrap requires valid numeric go/toolchain versions without duplicate directives'; return 4;
    }
    [[ "$requested" =~ $version_pattern ]] || {
        _tc_log_error 'Go bootstrap requires a released numeric go/toolchain version'; return 4;
    }
    printf '%s\n' "$requested"
}

_tc_bootstrap_go() {
    local tree="$1" root="$2" platform="$3" requested selection version filename digest size actual
    local requirements="${4:-$tree/go.mod}"
    requested=$(_tc_go_required_version "$requirements") || return $?
    _tc_bootstrap_fetch 'https://go.dev/dl/?mode=json&include=all' "$root/releases.json" 8388608 || return $?
    selection=$(jq -ers --arg requested "$requested" --arg os "${platform%/*}" --arg arch "${platform#*/}" '
        if length != 1 or (.[0]|type) != "array" then error("invalid Go release metadata") else .[0] end |
        [$requested | ltrimstr("go") | split(".")[] | tonumber] as $parts |
        [ .[] | select(.stable == true and (.version|type) == "string") |
          select(.version | test("^go[1-9][0-9]*\\.[0-9]+(\\.[0-9]+)?$")) |
          select(if ($parts|length) == 3 then .version == $requested
                 else .version == $requested or (.version|startswith($requested + ".")) end) ] |
        sort_by(.version | ltrimstr("go") | split(".") | map(tonumber)) |
        if length == 0 or (map(.version) | length != (unique|length)) then error("missing or duplicate Go release") else last end |
        . as $release | [ .files[] | select(.os == $os and .arch == $arch and .kind == "archive") ] |
        if length == 1 and (.[0].sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
           (.[0].size | type == "number" and floor == . and . > 0 and . <= 1073741824) and
           .[0].filename == ($release.version + "." + $os + "-" + $arch + ".tar.gz")
        then [$release.version, .[0].filename, .[0].sha256, (.[0].size|tostring)] | @tsv
        else error("no unambiguous matching Go distribution") end
    ' "$root/releases.json") || return 7
    IFS=$'\t' read -r version filename digest size <<< "$selection" || return 7
    _TC_BOOTSTRAP_URL="https://go.dev/dl/$filename"
    _tc_bootstrap_fetch "$_TC_BOOTSTRAP_URL" "$root/distribution.tar.gz" || return $?
    actual=$(_tc_bootstrap_sha256 "$root/distribution.tar.gz") || return $?
    [[ "$actual" == "$digest" && "$(wc -c < "$root/distribution.tar.gz" | tr -d '[:space:]')" == "$size" ]] || {
        _tc_log_error 'Go distribution checksum or size mismatch'; return 7;
    }
    _tc_bootstrap_extract_go "$root/distribution.tar.gz" "$root" || return $?
    export GOROOT="$root/go" GOENV=off GOTOOLCHAIN=local GOWORK=off
    _TC_BOOTSTRAP_BIN="$root/go/bin"
    _TC_BOOTSTRAP_VERSION=$("$_TC_BOOTSTRAP_BIN/go" version) || return 7
    [[ "$_TC_BOOTSTRAP_VERSION" == "go version $version $platform" ]] || return 7
    _TC_BOOTSTRAP_SHA="$digest"
}

_tc_bootstrap_rust() {
    local tree="$1" root="$2" platform="$3" host libc expected actual cursor boundary pinned=false
    cursor="$tree"; boundary="$tree"
    case "$platform" in
        linux/amd64|linux/arm64)
            libc=$(_tc_bootstrap_linux_libc) || return $?
            host="x86_64-unknown-linux-$libc"
            [[ "$platform" != linux/arm64 ]] || host="aarch64-unknown-linux-$libc" ;;
        darwin/amd64) host=x86_64-apple-darwin ;;
        darwin/arm64) host=aarch64-apple-darwin ;;
        *) return 3 ;;
    esac
    _TC_BOOTSTRAP_URL="https://static.rust-lang.org/rustup/dist/$host/rustup-init"
    _tc_bootstrap_fetch "$_TC_BOOTSTRAP_URL.sha256" "$root/rustup-init.sha256" 4096 || return $?
    expected=$(awk 'NF { n++; if ($1 !~ /^[0-9a-fA-F]+$/ || length($1) != 64) bad=1; value=$1 }
        END { if (n == 1 && !bad) print tolower(value); else exit 1 }' "$root/rustup-init.sha256") || return 7
    _tc_bootstrap_fetch "$_TC_BOOTSTRAP_URL" "$root/rustup-init" 104857600 || return $?
    actual=$(_tc_bootstrap_sha256 "$root/rustup-init") || return $?
    [[ "$actual" == "$expected" ]] || { _tc_log_error 'Rustup distribution checksum mismatch'; return 7; }
    chmod 700 "$root/rustup-init" || return 1
    export CARGO_HOME="$root/cargo" RUSTUP_HOME="$root/rustup" RUSTUP_AUTO_INSTALL=0
    export RUSTUP_DIST_SERVER=https://static.rust-lang.org RUSTUP_UPDATE_ROOT=https://static.rust-lang.org/rustup
    export RUSTUP_INIT_SKIP_PATH_CHECK=yes
    unset RUSTUP_TOOLCHAIN
    export PATH="$CARGO_HOME/bin:$PATH"
    "$root/rustup-init" -y --no-modify-path --profile minimal --default-toolchain none --default-host "$host" >&2 || return 7
    [[ -x "$CARGO_HOME/bin/rustup" ]] || return 7
    # Let rustup parse the repository's own TOML/legacy toolchain file. Search
    # only up to the isolated Git root, so an ambient parent override cannot
    # become a bootstrap requirement for an otherwise unpinned repository.
    # A standalone caller may supply a non-Git tree; in that case inspect only
    # that directory. Source installers always provide a detached Git checkout.
    while [[ "$cursor" != / ]]; do
        if [[ -e "$cursor/.git" ]]; then boundary="$cursor"; break; fi
        cursor="${cursor%/*}"; cursor="${cursor:-/}"
    done
    cursor="$tree"
    while :; do
        if [[ -e "$cursor/rust-toolchain" || -e "$cursor/rust-toolchain.toml" ||
              -L "$cursor/rust-toolchain" || -L "$cursor/rust-toolchain.toml" ]]; then
            [[ ! -L "$cursor/rust-toolchain" && ! -L "$cursor/rust-toolchain.toml" ]] || return 4
            pinned=true; break
        fi
        [[ "$cursor" != "$boundary" ]] || break
        cursor="${cursor%/*}"; cursor="${cursor:-/}"
    done
    if $pinned; then
        (cd "$tree" && "$CARGO_HOME/bin/rustup" toolchain install --profile minimal) >&2 || return 7
    else
        export RUSTUP_TOOLCHAIN=stable
        _TC_BOOTSTRAP_RUSTUP_TOOLCHAIN=stable
        "$CARGO_HOME/bin/rustup" default stable >&2 || return 7
    fi
    _TC_BOOTSTRAP_BIN="$CARGO_HOME/bin"
    _TC_BOOTSTRAP_VERSION=$(cd "$tree" && "$_TC_BOOTSTRAP_BIN/rustc" --version) || return 7
    [[ "$_TC_BOOTSTRAP_VERSION" == rustc\ * && -x "$_TC_BOOTSTRAP_BIN/cargo" ]] || return 7
    _TC_BOOTSTRAP_SHA="$expected"
}

_tc_bootstrap_bun() {
    local tree="$1" root="$2" platform="$3" version engine target libc checksums expected actual member candidate
    [[ -f "$tree/package.json" && ! -L "$tree/package.json" ]] || return 4
    version=$(jq -ers '
        if length != 1 or (.[0]|type) != "object" then error("invalid package.json") else .[0] end |
        (.packageManager // "") as $manager |
        if ($manager|type) != "string" then error("invalid packageManager")
        elif ($manager|startswith("bun@")) then $manager|ltrimstr("bun@") else "" end
    ' "$tree/package.json") || return 4
    engine=$(jq -er '.engines.bun // "" | if type == "string" then . else error("invalid Bun engine") end' "$tree/package.json") || return 4
    if [[ -n "$version" && ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        _tc_log_error 'Bun packageManager must pin one released numeric version'; return 4
    fi
    [[ -n "$version" || ! "$engine" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || version="$engine"
    if [[ -z "$version" ]]; then
        _tc_bootstrap_fetch 'https://api.github.com/repos/oven-sh/bun/releases/latest' "$root/release.json" 8388608 || return $?
        version=$(jq -ers 'if length == 1 and (.[0].tag_name|type == "string" and test("^bun-v[0-9]+\\.[0-9]+\\.[0-9]+$"))
            then .[0].tag_name|ltrimstr("bun-v") else error("invalid Bun release identity") end' "$root/release.json") || return 7
    fi
    case "$platform" in
        linux/amd64) target=bun-linux-x64 ;;
        linux/arm64) target=bun-linux-aarch64 ;;
        darwin/amd64) target=bun-darwin-x64 ;;
        darwin/arm64) target=bun-darwin-aarch64 ;;
        *) return 3 ;;
    esac
    if [[ "$platform" == linux/* ]]; then
        libc=$(_tc_bootstrap_linux_libc) || return $?
        [[ "$libc" != musl ]] || target+=-musl
    fi
    checksums="$root/SHASUMS256.txt"
    _tc_bootstrap_fetch "https://github.com/oven-sh/bun/releases/download/bun-v$version/SHASUMS256.txt" "$checksums" 1048576 || return $?
    # Older x64 distributions publish a baseline build for CPUs without AVX2.
    # Use it when present; newer releases use runtime instruction selection.
    candidate="$target"
    if [[ "$platform" == */amd64 ]] && _tc_bootstrap_checksum "$checksums" "$target-baseline.zip" >/dev/null; then
        candidate+="-baseline"
    fi
    expected=$(_tc_bootstrap_checksum "$checksums" "$candidate.zip") || return 7
    _TC_BOOTSTRAP_URL="https://github.com/oven-sh/bun/releases/download/bun-v$version/$candidate.zip"
    _tc_bootstrap_fetch "$_TC_BOOTSTRAP_URL" "$root/distribution.zip" || return $?
    actual=$(_tc_bootstrap_sha256 "$root/distribution.zip") || return $?
    [[ "$actual" == "$expected" ]] || { _tc_log_error 'Bun distribution checksum mismatch'; return 7; }
    command -v unzip >/dev/null 2>&1 || return 3
    member="$candidate/bun"
    [[ "$(unzip -Z1 "$root/distribution.zip" | LC_ALL=C awk -v selected="$member" '$0 == selected { count++ } END { print count+0 }')" == 1 ]] || return 7
    mkdir "$root/bun" "$root/bun/bin" || return 1
    unzip -p "$root/distribution.zip" "$member" > "$root/bun/bin/bun" || return 7
    [[ -s "$root/bun/bin/bun" ]] || return 7
    chmod 700 "$root/bun/bin/bun" || return 1
    export BUN_INSTALL="$root/bun" BUN_INSTALL_CACHE_DIR="$root/bun/cache"
    _TC_BOOTSTRAP_BIN="$root/bun/bin"
    _TC_BOOTSTRAP_VERSION=$("$_TC_BOOTSTRAP_BIN/bun" --version) || return 7
    [[ "$_TC_BOOTSTRAP_VERSION" == "$version" ]] || return 7
    if [[ -n "$engine" ]]; then
        # Bun before 1.3 included an extra [eval] argv entry. An invocation-only
        # environment value preserves the same range across pinned versions.
        DSR_BOOTSTRAP_BUN_RANGE="$engine" "$_TC_BOOTSTRAP_BIN/bun" --eval \
            'if (!Bun.semver.satisfies(Bun.version, process.env.DSR_BOOTSTRAP_BUN_RANGE)) process.exit(1)' || {
            _tc_log_error 'The selected Bun release does not satisfy package.json engines.bun'; return 7;
        }
    fi
    _TC_BOOTSTRAP_SHA="$expected"
}

# Prepare a missing compiler for one explicitly authorized source attempt.
# The caller owns timeout/process-group supervision. All distribution bytes,
# metadata and installed tools remain below this new private directory; no
# existing toolchain, profile, system directory or default compiler is changed.
# stdout: receipt JSON; receipt.json appears only after compiler activation was
# verified. Selection/version policy is read from the already pinned source.
# Optional --go-requirements selects a caller-admitted go.work at or above the
# build directory, or its go.mod. Four-argument callers keep their old policy.
toolchain_bootstrap() (
    [[ $# -eq 4 || $# -eq 6 ]] || return 4
    [[ "$4" == --allow-install ]] || return 4
    local language="$1" tree="$2" root="$3" platform parent command go_requirements='' requirements_parent
    local _TC_BOOTSTRAP_URL='' _TC_BOOTSTRAP_SHA='' _TC_BOOTSTRAP_BIN='' _TC_BOOTSTRAP_VERSION='' _TC_BOOTSTRAP_RUSTUP_TOOLCHAIN=''
    [[ "$language" != typescript ]] || language=bun
    case "$language" in rust|go|bun) ;; *) return 4 ;; esac
    [[ -d "$tree" && ! -L "$tree" && -n "$root" && "$root" != */ && ! -e "$root" && ! -L "$root" ]] || return 4
    parent=$(dirname "$root")
    [[ -d "$parent" && ! -L "$parent" ]] || return 4
    tree=$(cd "$tree" && pwd -P) || return 4
    root="$(cd "$parent" && pwd -P)/${root##*/}"
    if [[ $# -eq 6 ]]; then
        [[ "$language" == go && "$5" == --go-requirements ]] || return 4
        go_requirements="$6"
        [[ "$go_requirements" == /* && "$go_requirements" != *[[:cntrl:]]* &&
           -f "$go_requirements" && ! -L "$go_requirements" ]] || return 4
        requirements_parent=$(cd "$(dirname "$go_requirements")" && pwd -P) || return 4
        go_requirements="$requirements_parent/${go_requirements##*/}"
        case "${go_requirements##*/}" in
            go.work) [[ "$tree" == "$requirements_parent" || "$tree" == "$requirements_parent/"* ]] || return 4 ;;
            go.mod) [[ "$tree" == "$requirements_parent" ]] || return 4 ;;
            *) return 4 ;;
        esac
    fi
    platform=$(_tc_detect_platform)
    case "$platform" in linux/amd64|linux/arm64|darwin/amd64|darwin/arm64) ;; *)
        _tc_log_error "Isolated toolchain bootstrap is not supported on $platform; install the compiler first"; return 3 ;;
    esac
    for command in curl jq; do command -v "$command" >/dev/null 2>&1 || return 3; done
    if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then return 3; fi
    umask 077
    mkdir "$root" || return 1
    _tc_log_info "Preparing an isolated $language compiler for $platform"
    case "$language" in
        rust) _tc_bootstrap_rust "$tree" "$root" "$platform" || return $? ;;
        go) _tc_bootstrap_go "$tree" "$root" "$platform" "$go_requirements" || return $? ;;
        bun) _tc_bootstrap_bun "$tree" "$root" "$platform" || return $? ;;
    esac
    local receipt
    receipt=$(jq -nc --arg language "$language" --arg platform "$platform" --arg root "$root" \
        --arg bin "$_TC_BOOTSTRAP_BIN" --arg version "$_TC_BOOTSTRAP_VERSION" \
        --arg url "$_TC_BOOTSTRAP_URL" --arg sha "$_TC_BOOTSTRAP_SHA" \
        --arg rustup_toolchain "$_TC_BOOTSTRAP_RUSTUP_TOOLCHAIN" \
        '{schema_version:1,method:"isolated-bootstrap",language:$language,platform:$platform,
          root:$root,bin_dir:$bin,version:$version,distribution_url:$url,distribution_sha256:$sha} +
          (if $language == "rust" then {rustup_toolchain:$rustup_toolchain} else {} end)') || return 1
    (set -C; printf '%s\n' "$receipt" > "$root/receipt.json") || return 1
    printf '%s\n' "$receipt"
)

# Print human-readable status for all toolchains
toolchain_status() {
    _tc_require_jq || return $?

    local platform
    platform=$(_tc_detect_platform)

    echo ""
    _tc_log_info "Platform: $platform"
    echo ""

    local toolchains=("rust" "go" "bun" "node")
    for tc in "${toolchains[@]}"; do
        local result installed version min_version meets
        result=$(toolchain_detect "$tc")
        installed=$(echo "$result" | jq -r '.installed')
        version=$(echo "$result" | jq -r '.version')
        min_version=$(echo "$result" | jq -r '.minimum_version')
        meets=$(echo "$result" | jq -r '.meets_minimum')

        if [[ "$installed" == "true" ]]; then
            if [[ "$meets" == "true" ]]; then
                _tc_log_ok "$tc: $version (min: $min_version)"
            else
                _tc_log_warn "$tc: $version (min: $min_version) - UPGRADE RECOMMENDED"
            fi
        else
            _tc_log_warn "$tc: not installed (min: $min_version)"
        fi
    done
    echo ""
}

# Export functions
export -f toolchain_detect toolchain_detect_all toolchain_ensure toolchain_install toolchain_status
export -f toolchain_detect_rust toolchain_detect_go toolchain_detect_bun toolchain_detect_node
export -f toolchain_bootstrap
#!/usr/bin/env bash
# install_source.sh - pinned, opt-in source builds for standalone installers.
# Embedded by install_gen.sh; no DSR installation is needed on the client.
# Source builds execute repository/dependency build code. They are NOT signed
# release artifacts. A missing compiler is installed only with separate
# --install-toolchain consent, inside this source attempt's private directory.
# GitHub source fetches use the same chosen account as release downloads.
# Without a selected GitHub credential, ordinary Git authentication and URL
# policy remain available for anonymous or custom-helper installations.
#
# install_source_build owner/repo ref language binary new_directory --allow-build
#   [--subdir relative/path] [--entry relative/path] [--package cargo_package]
#   [--bin name ...] [--timeout seconds] [--install-toolchain]
# Timeout applies to each fetch/compiler command, including its children.
# stdout: one receipt JSON after a successful build; stderr: progress/errors.
# Exit: 3 missing dependency, 4 invalid input, 5 timeout/interruption,
#       6 build failure, 7 distribution verification, 8 retrieval failure,
#       1 local I/O failure.

_isb_log() { printf '[source-build] %s\n' "$*" >&2; }

_isb_name() {
    [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]
}

_isb_binary_name() {
    local name="$1"
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*)
            [[ "${name,,}" != *.exe ]] || name="${name%????}"
            name+=.exe ;;
    esac
    printf '%s\n' "$name"
}

_isb_relative_path() {
    [[ "$1" == . ]] && return 0
    [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9._+/-]*$ && "$1" != */ ]] || return 1
    case "/$1/" in *'/../'*|*'/./'*|*'//'*|*'/.git/'*) return 1 ;; esac
}

# Ref names are not revspecs, refspecs, options, or shell expressions. Tags
# requested by --version are passed as refs/tags/<version>, never as HEAD.
_isb_ref() {
    # The embedded engine must parse before the installer can require Bash 4
    # for source execution. Early Bash 3.2 parsers need grouped EREs in variables.
    local reference_pattern='^refs/(heads|tags)/[A-Za-z0-9_][A-Za-z0-9._+/-]*$'
    [[ "$1" == HEAD || "$1" =~ ^[0-9a-fA-F]{40}$ || "$1" =~ ^[0-9a-fA-F]{64}$ ]] && return 0
    case "$1" in refs/heads/*|refs/tags/*) ;; *) return 1 ;; esac
    [[ "$1" =~ $reference_pattern ]] &&
        git check-ref-format "$1" >/dev/null 2>&1
}

_isb_path_in_tree() {
    local root="$1" path="$2" part cursor="$1"
    _isb_relative_path "$path" || return 1
    [[ -d "$root" && ! -L "$root" ]] || return 1
    [[ "$path" == . ]] && return 0
    while [[ -n "$path" ]]; do
        part="${path%%/*}"
        cursor="$cursor/$part"
        [[ ! -L "$cursor" ]] || return 1
        if [[ "$path" == */* ]]; then
            [[ -d "$cursor" ]] || return 1
            path="${path#*/}"
        else
            [[ -e "$cursor" ]] || return 1
            break
        fi
    done
}

_isb_sha256() {
    local hash
    [[ -s "$1" && -f "$1" && ! -L "$1" ]] || return 1
    if command -v sha256sum >/dev/null 2>&1; then
        hash=$(sha256sum < "$1") || return 1
    elif command -v shasum >/dev/null 2>&1; then
        hash=$(shasum -a 256 < "$1") || return 1
    else
        return 3
    fi
    hash="${hash%% *}"
    [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$hash"
}

# A portable Bash watchdog, including on macOS without GNU timeout. Job
# control gives BOTH children their own process groups. Killing the group
# also stops compiler children; killing only cargo/go would orphan them.
# Each call owns a fresh log path and leaves diagnostics for the caller.
_isb_run() (
    local limit="$1" log="$2" child guard requester supervisor="$BASHPID" status=0
    shift 2
    [[ "$limit" =~ ^[1-9][0-9]{0,4}$ && ! -e "$log" && ! -L "$log" &&
       ! -e "$log.timeout" && ! -L "$log.timeout" ]] || return 4
    requester=$(ps -o ppid= -p "$supervisor") || return 3
    requester="${requester//[[:space:]]/}"
    [[ "$requester" =~ ^[1-9][0-9]*$ ]] || return 3
    set -m
    "$@" </dev/null > "$log" 2>&1 &
    child=$!
    (
        set +m
        timer=''
        _isb_timer_stop() {
            trap '' HUP INT TERM
            [[ -z "$timer" ]] || kill "$timer" 2>/dev/null || true
            [[ -z "$timer" ]] || wait "$timer" 2>/dev/null || true
            exit 0
        }
        trap _isb_timer_stop HUP INT TERM
        deadline=$((SECONDS + limit))
        # A caller killed by PID (rather than by foreground process group)
        # cannot forward signals through Bash command substitutions. Notice
        # its disappearance here instead of leaving an orphaned compiler.
        while ((SECONDS < deadline)) && kill -0 "$requester" 2>/dev/null && kill -0 "$$" 2>/dev/null; do
            sleep 1 & timer=$!
            wait "$timer" || exit 5
        done
        printf 'timeout-or-caller-exit\n' > "$log.timeout"
        kill -TERM -- "-$child" 2>/dev/null || true
        sleep 2 & timer=$!
        wait "$timer" || exit 5
        kill -KILL -- "-$child" 2>/dev/null || true
    ) &
    guard=$!
    _isb_cancel() {
        trap '' HUP INT TERM
        kill -TERM -- "-$child" "-$guard" 2>/dev/null || true
        wait "$guard" 2>/dev/null || true
        sleep 1
        kill -KILL -- "-$child" 2>/dev/null || true
        wait "$child" 2>/dev/null || true
        exit 5
    }
    trap _isb_cancel HUP INT TERM
    wait "$child" 2>/dev/null || status=$?
    # A timed-out process can exit while one of its descendants ignores TERM.
    # Always dispose of that process group before stopping the watchdog.
    kill -TERM -- "-$child" "-$guard" 2>/dev/null || true
    kill -KILL -- "-$child" 2>/dev/null || true
    wait "$guard" 2>/dev/null || true
    trap - HUP INT TERM
    if [[ -f "$log.timeout" ]]; then
        _isb_log "Command interrupted or exceeded ${limit}s; log: $log"
        return 5
    fi
    if ((status != 0)); then
        tail -n 40 "$log" >&2
        _isb_log "Command failed (exit $status); log: $log"
    fi
    return "$status"
)

_isb_git() (
    # Ambient repository plumbing must not redirect writes into a caller's
    # checkout. User credential helpers and URL policy remain available.
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
    unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
    unset GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
    export GIT_TERMINAL_PROMPT=0 GIT_NO_REPLACE_OBJECTS=1
    git -c core.hooksPath=/dev/null -c core.fsmonitor=false -c submodule.recurse=false "$@"
)

_isb_checkout() (
    set +x
    local repo="$1" ref="$2" dir="$3" token='' token_status=0 trace_name authorization
    local -a git_options=() init_options=()
    token=$(_installer_github_token) || token_status=$?
    # With no selected GitHub credential, retain the existing Git-only path:
    # anonymous HTTPS, user credential helpers and configured URL policy.
    # A malformed explicit credential must not fall through to that path.
    ((token_status != 5)) || return 5
    ((token_status == 0 || token_status == 3)) || return 8
    if [[ -n "$token" ]]; then
        # A header supplied before the first request also prevents libcurl's
        # ~/.netrc from authenticating as another account before a reactive
        # Git credential helper runs. jq is already a source-build dependency;
        # secret input reaches it only on stdin. Git reads the scoped header
        # from this process's environment, never an argv, URL or stored file.
        command -v jq >/dev/null 2>&1 || return 3
        authorization=$(printf 'x-access-token:%s' "$token" | jq -Rrs '@base64') || return 8
        export DSR_INSTALLER_GIT_AUTHORIZATION="Authorization: Basic $authorization"
        # A chosen account cannot be redirected by global/system insteadOf
        # rules, extra Authorization headers or another credential helper.
        # The fresh repository gets no ambient template/configuration either.
        export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_ALLOW_PROTOCOL=https
        unset GIT_TEMPLATE_DIR GIT_ASKPASS SSH_ASKPASS GIT_CURL_VERBOSE GIT_SSL_NO_VERIFY
        for trace_name in "${!GIT_TRACE@}"; do unset "$trace_name"; done
        # --config-env is supported by Git 2.31+. An older Git refuses this
        # command before network access rather than ignoring the credential
        # policy as an unknown -c option could.
        git_options=(-c credential.helper= -c credential.interactive=false -c core.askPass=
            -c http.extraHeader= "--config-env=http.https://github.com/$repo.git.extraHeader=DSR_INSTALLER_GIT_AUTHORIZATION"
            -c http.followRedirects=false -c http.sslVerify=true)
        init_options=(--template=)
    fi
    _isb_git ${git_options[@]+"${git_options[@]}"} init -q ${init_options[@]+"${init_options[@]}"} "$dir" || return 8
    _isb_git ${git_options[@]+"${git_options[@]}"} -C "$dir" remote add origin "https://github.com/$repo.git" || return 8
    _isb_git ${git_options[@]+"${git_options[@]}"} -C "$dir" fetch -q --depth=1 --no-tags --recurse-submodules=no origin "$ref" || return 8
    local commit
    commit=$(_isb_git ${git_options[@]+"${git_options[@]}"} -C "$dir" rev-parse --verify 'FETCH_HEAD^{commit}') || return 8
    [[ "$commit" =~ ^[0-9a-f]{40}$ || "$commit" =~ ^[0-9a-f]{64}$ ]] || return 8
    if [[ "$ref" =~ ^[0-9a-fA-F]{40}$ || "$ref" =~ ^[0-9a-fA-F]{64}$ ]]; then
        [[ "$commit" == "${ref,,}" ]] || return 8
    fi
    _isb_git ${git_options[@]+"${git_options[@]}"} -C "$dir" -c advice.detachedHead=false checkout -q --detach "$commit" || return 8
)

_isb_in_dir() ( cd "$1" && shift && "$@" )

# Shared by Git source checkout, release acquisition and freshness in generated
# installers, and usable when this source module is loaded alone. Match DSR's token order;
# gh otherwise prefers GH_TOKEN and may inherit an unrelated enterprise host.
# Resolve only one account. An invalid explicit token must not try a stored
# login. Keep credentials and tracing changes confined to this child process.
_installer_github_token() (
    set +x
    local token='' status=0
    if [[ -n "${DSR_GH_TOKEN:-}" ]]; then
        token="$DSR_GH_TOKEN"
    elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
        token="$GITHUB_TOKEN"
    elif [[ -n "${GH_TOKEN:-}" ]]; then
        token="$GH_TOKEN"
    else
        command -v gh >/dev/null 2>&1 || return 3
        token=$(GH_HOST=github.com gh auth token --hostname github.com 2>/dev/null) || status=$?
        case "$status" in
            0) ;;
            2|129|130|131|143) return 5 ;;
            *) return 3 ;;
        esac
    fi
    [[ -n "$token" ]] || return 3
    [[ "$token" != *$'\r'* && "$token" != *$'\n'* ]] || return 4
    printf '%s\n' "$token"
)

# Bound the whole GitHub CLI request, including stored-token lookup. Curl's
# network timeout does not cover a blocked gh credential helper. Keep stdout
# streaming to the caller and credentials off disk; only the timeout marker is
# stored. Job control gives this request and watchdog separate owned groups,
# using syntax supported by release installers on stock macOS Bash 3.2.
# Match the curl acquisition budgets: 30s metadata, 300s release payloads.
_installer_run_gh() (
    set +x
    local limit="${DSR_INSTALLER_GH_TIMEOUT:-}" directory child='' guard='' status=0 interrupted=false
    if [[ -z "$limit" ]]; then
        if [[ "${1:-} ${2:-}" == 'release download' ]]; then limit=300
        else limit=30; fi
    fi
    [[ "$limit" =~ ^[1-9][0-9]{0,2}$ ]] && ((limit <= 300)) || {
        printf '[installer] DSR_INSTALLER_GH_TIMEOUT must be 1 through 300 seconds\n' >&2
        return 4
    }
    command -v gh >/dev/null 2>&1 || return 3
    directory=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/dsr-gh.XXXXXXXX") || return 8
    _installer_gh_dispose() {
        trap '' HUP INT TERM
        [[ -z "$child" ]] || kill -TERM -- "-$child" 2>/dev/null || true
        [[ -z "$guard" ]] || kill -TERM -- "-$guard" 2>/dev/null || true
        [[ -z "$child" ]] || kill -KILL -- "-$child" 2>/dev/null || true
        [[ -z "$child" ]] || wait "$child" 2>/dev/null || true
        [[ -z "$guard" ]] || wait "$guard" 2>/dev/null || true
        rm -f -- "$directory/timeout" 2>/dev/null || true
        rmdir -- "$directory" 2>/dev/null || true
    }
    _installer_gh_cancel() {
        _installer_gh_dispose
        exit 5
    }
    # Record setup signals until both launched process IDs are available.
    # A trap between starting a job and reading $! must not lose that child.
    trap 'interrupted=true' HUP INT TERM
    set -m
    (
        set +m
        token=$(_installer_github_token) || exit $?
        request_status=0
        GH_HOST=github.com GH_TOKEN="$token" gh "$@" || request_status=$?
        case "$request_status" in
            0) exit 0 ;;
            # gh uses 1 for both unavailable assets and other request failures.
            # Only the acquisition caller can combine it with independent HTTP
            # evidence; it must never authorize source execution by itself.
            1) exit 1 ;;
            2|129|130|131|143) exit 5 ;;
            *) exit 8 ;;
        esac
    ) </dev/null &
    child=$!
    $interrupted && _installer_gh_cancel
    (
        set +m
        timer=''
        _installer_gh_stop_timer() {
            trap '' HUP INT TERM
            [[ -z "$timer" ]] || kill "$timer" 2>/dev/null || true
            [[ -z "$timer" ]] || wait "$timer" 2>/dev/null || true
            exit 0
        }
        trap _installer_gh_stop_timer HUP INT TERM
        sleep "$limit" & timer=$!
        wait "$timer" || exit 0
        printf 'timeout\n' > "$directory/timeout"
        kill -TERM -- "-$child" 2>/dev/null || true
        sleep 2 & timer=$!
        wait "$timer" || exit 0
        kill -KILL -- "-$child" 2>/dev/null || true
    ) &
    guard=$!
    trap _installer_gh_cancel HUP INT TERM
    $interrupted && _installer_gh_cancel
    wait "$child" 2>/dev/null || status=$?
    if [[ -f "$directory/timeout" ]]; then
        printf '[installer] GitHub CLI request exceeded %ss\n' "$limit" >&2
        # A credential/CLI timeout is ambiguous, never proof that a release
        # is absent and therefore never permission to compile source.
        status=8
    fi
    _installer_gh_dispose
    return "$status"
)

# Freshness is advisory release metadata, NOT artifact or commit-signature
# verification. Query only GitHub's API and do not inherit a GH_HOST override.
# Separate API bytes from diagnostic logs so warnings cannot become JSON.
_isb_freshness_request() (
    set +x
    local transport="$1" endpoint="$2" destination="$3"
    if [[ "$transport" == gh ]]; then
        _installer_run_gh api --hostname github.com --method GET \
            -H 'Accept: application/vnd.github+json' -H 'Cache-Control: no-cache' \
            "$endpoint" > "$destination"
    elif ! command -v gh >/dev/null 2>&1 &&
         [[ -n "${DSR_GH_TOKEN:-}" || -n "${GITHUB_TOKEN:-}" || -n "${GH_TOKEN:-}" ]]; then
        # Match token-only release acquisition without adding a gh dependency.
        # Keep credentials off argv and disk, ignore ambient curl options, and
        # never follow metadata redirects. These endpoints are assembled only
        # from the admitted repository/tag and the resolved immutable commits.
        local token escaped_token bytes status maximum=8388608
        token=$(_installer_github_token) || return $?
        [[ ${#token} -le 8192 && "$token" != *[[:cntrl:]]* ]] || return 4
        escaped_token="${token//\\/\\\\}"; escaped_token="${escaped_token//\"/\\\"}"
        set -o pipefail
        if ! printf 'header = "Authorization: Bearer %s"\n' "$escaped_token" |
            curl -q --config - --silent --globoff --proto '=https' \
                --connect-timeout 10 --max-time 30 --max-filesize "$maximum" \
                -H 'Accept: application/vnd.github+json' -H 'Cache-Control: no-cache' \
                -H 'X-GitHub-Api-Version: 2022-11-28' \
                "https://api.github.com/$endpoint" --output /dev/fd/3 \
                --write-out '%{http_code}' 3>&1 > "$destination.http" 2>/dev/null |
            head -c "$((maximum + 1))" > "$destination"; then
            return 8
        fi
        bytes=$(wc -c < "$destination" | tr -d '[:space:]') || return 1
        status=$(cat -- "$destination.http") || return 1
        [[ "$status" == 200 && "$bytes" =~ ^[0-9]+$ ]] && ((bytes <= maximum)) || return 8
    else
        curl -sSf --proto '=https' --connect-timeout 10 --max-time 30 \
            -H 'Accept: application/vnd.github+json' -H 'Cache-Control: no-cache' \
            "https://api.github.com/$endpoint" -o "$destination"
    fi
)

_isb_freshness_get() {
    local endpoint="$1" destination="$2" prefer="$3" transport status
    local transports=(curl gh)
    [[ "$prefer" != true ]] || transports=(gh curl)
    for transport in "${transports[@]}"; do
        command -v "$transport" >/dev/null 2>&1 || continue
        status=0
        _isb_run 35 "$destination.$transport.log" _isb_freshness_request \
            "$transport" "$endpoint" "$destination" 2>/dev/null || status=$?
        if ((status == 0)) && [[ -f "$destination" && ! -L "$destination" ]] &&
           jq -es 'length == 1' "$destination" >/dev/null 2>&1; then
            return 0
        fi
        # An actual cancellation is not an unavailable API. Watchdog timeouts
        # do count as unavailable; their marker distinguishes the two cases.
        if ((status == 5)) && [[ ! -e "$destination.$transport.log.timeout" ]]; then
            return 5
        fi
    done
    return 8
}

# Print one decision about the latest release's distance from the default
# branch. Resolve tag and head to immutable commits BEFORE comparing, and use
# ahead_by/total_commits, never the length/last entry of a paginated commit list.
# API docs: https://docs.github.com/en/rest/commits/commits#compare-two-commits
# Usage: install_source_freshness owner/repo tag threshold new_dir [--prefer-gh]
# Stale means strictly MORE than threshold commits behind an ancestral head.
# Unavailable, malformed or divergent history is "unknown", never permission
# to compile. This helper does not fetch Git objects or execute repository code.
install_source_freshness() (
    local repo="${1:-}" tag="${2:-}" threshold="${3:-}" directory="${4:-}" prefer=false
    local threshold_pattern='^(0|[1-9][0-9]{0,5})$'
    [[ $# -eq 4 || ( $# -eq 5 && "$5" == --prefer-gh ) ]] || return 4
    [[ $# -ne 5 ]] || prefer=true
    [[ "$repo" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ &&
       "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ && "$tag" != null &&
       "$threshold" =~ $threshold_pattern ]] || return 4
    command -v jq >/dev/null 2>&1 || return 3
    _isb_freshness_unknown() {
        jq -nc --arg repo "$repo" --arg tag "$tag" --argjson threshold "$threshold" --arg reason "$1" \
            '{status:"unknown", repository:$repo, release_version:$tag, threshold:$threshold, reason:$reason}'
    }
    command -v ps >/dev/null 2>&1 || { _isb_freshness_unknown 'process watchdog unavailable'; return; }
    [[ -n "$directory" && ! -e "$directory" && ! -L "$directory" && "$directory" != */ ]] || return 4
    local parent name status=0 head base encoded_tag decision
    parent=$(dirname "$directory"); name=$(basename "$directory")
    _isb_name "$name" && [[ -d "$parent" && ! -L "$parent" ]] || return 4
    parent=$(cd "$parent" && pwd -P) || return 4
    directory="$parent/$name"
    umask 077
    mkdir "$directory" || return 1
    trap 'exit 5' HUP INT TERM
    # Omitted sha on list-commits means the repository's default branch, not
    # a hard-coded branch name or the default branch of a different repo.
    _isb_freshness_get "repos/$repo/commits?per_page=1" "$directory/head.json" "$prefer" || status=$?
    [[ "$status" != 5 ]] || return 5
    if ((status != 0)) || ! head=$(jq -er -s '
        if length == 1 and (.[0] | type == "array" and length == 1)
        then .[0][0].sha | select(type == "string" and (length == 40 or length == 64)
            and (test("[^0-9a-f]") | not))
        else empty end' "$directory/head.json" 2>/dev/null); then
        _isb_freshness_unknown 'default branch revision unavailable'; return
    fi
    # tags/ disambiguates a same-named branch; Get a commit peels annotated tags.
    encoded_tag=$(jq -nr --arg tag "tags/$tag" '$tag | @uri') || return 1
    status=0
    _isb_freshness_get "repos/$repo/commits/$encoded_tag" "$directory/base.json" "$prefer" || status=$?
    [[ "$status" != 5 ]] || return 5
    if ((status != 0)) || ! base=$(jq -er -s '
        if length == 1 then .[0].sha | select(type == "string" and (length == 40 or length == 64)
            and (test("[^0-9a-f]") | not))
        else empty end' "$directory/base.json" 2>/dev/null); then
        _isb_freshness_unknown 'release tag revision unavailable'; return
    fi
    status=0
    _isb_freshness_get "repos/$repo/compare/$base...$head?per_page=1" "$directory/compare.json" "$prefer" || status=$?
    [[ "$status" != 5 ]] || return 5
    if ((status != 0)); then
        _isb_freshness_unknown 'commit comparison unavailable'; return
    fi
    if ! decision=$(jq -ce -s --arg repo "$repo" --arg tag "$tag" --arg base "$base" --arg head "$head" \
        --argjson threshold "$threshold" '
        def count: type == "number" and floor == . and . >= 0 and . <= 1000000000;
        if length != 1 then error("multiple comparisons") else .[0] end |
        if type != "object" or .base_commit.sha != $base or
           (.ahead_by | count | not) or (.behind_by | count | not) or
           (.total_commits | count | not) or .total_commits != .ahead_by or
           .behind_by != 0 or .merge_base_commit.sha != $base or
           (if $head == $base then .status != "identical" or .ahead_by != 0
            else .status != "ahead" or .ahead_by <= 0 end)
        then error("incomplete, inconsistent or non-ancestral comparison")
        else {status:(if .ahead_by > $threshold then "stale" else "fresh" end),
              repository:$repo, release_version:$tag, release_commit:$base,
              head_commit:$head, commits_behind:.ahead_by, threshold:$threshold}
        end' "$directory/compare.json" 2>/dev/null); then
        _isb_freshness_unknown 'comparison is invalid or history is not ancestral'; return
    fi
    printf '%s\n' "$decision"
)

# A rustup proxy can exist without its selected compiler. Probe that compiler
# without granting rustup permission to install into the user's existing home.
_isb_probe_rust() (
    export RUSTUP_AUTO_INSTALL=0
    cd "$1" || return 4
    rustc -vV && cargo --version
)

# Inspect the installed Go compiler without letting Go download another one,
# adopt an ambient workspace, or consult a user-written Go environment file.
_isb_probe_go() (
    export GOENV=off GOWORK=off GOTOOLCHAIN=local GOFLAGS='' GO111MODULE=on GOTELEMETRY=off
    cd "$1" || return 4
    go version
)

# Activate an explicitly requested bootstrap when a compiler is unavailable,
# or when an installed Go compiler is older than the pinned source requires.
# This runs inside _isb_compile's subshell, so PATH and language homes never
# escape the source attempt or replace the caller's installed toolchain.
_isb_prepare_toolchain() {
    local language="$1" tree="$2" output="$3" limit="$4" command root bin source_dir status=0
    local go_requirements="${5:-}" installed=false required observed version
    local go_version_pattern='^go version go([1-9][0-9]*\.[0-9]+\.[0-9]+|1\.([0-9]|1[0-9]|20)) [a-z0-9]+/[a-z0-9]+$'
    local -a bootstrap_options=(--allow-install)
    [[ -z "$go_requirements" || "$language" == go ]] || return 4
    [[ -z "$go_requirements" ]] || bootstrap_options+=(--go-requirements "$go_requirements")
    case "$language" in rust) command=cargo ;; go) command=go ;; *) command=bun ;; esac
    if command -v "$command" >/dev/null 2>&1 &&
       { [[ "$language" != rust ]] || command -v rustc >/dev/null 2>&1; }; then
        installed=true
        if [[ "${_ISB_INSTALL_TOOLCHAIN:-false}" != true ||
              ( "$language" != rust && "$language" != go ) ]]; then
            return 0
        fi
        if [[ "$language" == rust ]]; then
            # An unavailable rustup-selected compiler is a missing toolchain;
            # bootstrap privately instead of changing that rustup home.
            _isb_run "$limit" "$output/toolchain-probe.log" _isb_probe_rust "$tree" || status=$?
            ((status != 0)) || return 0
            ((status != 5 && status < 128)) || return 5
            _isb_log 'The existing Rust commands do not provide the selected compiler; preparing an isolated toolchain'
        fi
    fi
    if [[ "${_ISB_INSTALL_TOOLCHAIN:-false}" != true ]]; then
        _isb_log "Missing $command; --install-toolchain permits an isolated compiler for this build"
        return 3
    fi
    if ! declare -F toolchain_bootstrap >/dev/null 2>&1 ||
       { [[ "$language" == go ]] && ! declare -F _tc_go_required_version >/dev/null 2>&1; }; then
        source_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || return 3
        [[ -f "$source_dir/toolchain_detect.sh" && ! -L "$source_dir/toolchain_detect.sh" ]] || return 3
        # shellcheck source=SCRIPTDIR/toolchain_detect.sh
        source "$source_dir/toolchain_detect.sh" || return 3
    fi
    if $installed && [[ "$language" == go ]]; then
        # The same committed requirement selects both admission and bootstrap.
        # A toolchain preference is a minimum for an existing installation;
        # preserve a newer compiler rather than downloading a downgrade.
        required=$(_tc_go_required_version "${go_requirements:-$tree/go.mod}") || return $?
        _isb_run "$limit" "$output/toolchain-probe.log" _isb_probe_go "$tree" || status=$?
        ((status != 5 && status < 128)) || return 5
        if ((status == 0)); then
            observed=$(cat "$output/toolchain-probe.log") || return 1
            # Before Go 1.21 initial releases omitted the patch component.
            # A modern two-component version identifies an unreleased compiler.
            if [[ "$observed" =~ $go_version_pattern ]]; then
                version="${BASH_REMATCH[1]}"
                required="${required#go}"
                [[ "$version" == *.*.* ]] || version+=.0
                [[ "$required" == *.*.* ]] || required+=.0
                if _tc_version_ge "$version" "$required"; then
                    return 0
                fi
                _isb_log "Installed Go $version is older than the pinned requirement $required; preparing an isolated toolchain"
            else
                _isb_log 'The existing Go command did not identify a released compiler; preparing an isolated toolchain'
            fi
        else
            _isb_log 'The existing Go command is unavailable; preparing an isolated toolchain'
        fi
    fi
    root="$output/toolchain"
    _isb_log "Preparing a private $language toolchain; existing installations and profiles are preserved"
    _isb_run "$limit" "$output/toolchain.log" toolchain_bootstrap \
        "$language" "$tree" "$root" "${bootstrap_options[@]}" || return $?
    [[ "$language" != typescript ]] || language=bun
    case "$language" in rust) bin="$root/cargo/bin" ;; go) bin="$root/go/bin" ;; bun) bin="$root/bun/bin" ;; esac
    [[ -f "$root/receipt.json" && ! -L "$root/receipt.json" && -d "$bin" && ! -L "$bin" ]] || return 7
    jq -es --arg root "$root" --arg bin "$bin" --arg language "$language" '
        length == 1 and (.[0] | .schema_version == 1 and .method == "isolated-bootstrap" and
        .root == $root and .bin_dir == $bin and .language == $language and
        (.version | type == "string" and length > 0) and
        (.distribution_url | type == "string" and startswith("https://")) and
        (.distribution_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
        ((.rustup_toolchain // "") == "" or .rustup_toolchain == "stable"))
    ' "$root/receipt.json" >/dev/null || return 7
    export PATH="$bin:$PATH"
    hash -r
    case "$language" in
        rust)
            export CARGO_HOME="$root/cargo" RUSTUP_HOME="$root/rustup" RUSTUP_AUTO_INSTALL=0
            unset RUSTUP_TOOLCHAIN
            if [[ "$(jq -r '.rustup_toolchain // ""' "$root/receipt.json")" == stable ]]; then
                export RUSTUP_TOOLCHAIN=stable
            fi
            ;;
        go)
            export GOROOT="$root/go" GOPATH="$root/go-work" GOCACHE="$root/go-cache"
            ;;
        bun)
            export BUN_INSTALL="$root/bun" BUN_INSTALL_CACHE_DIR="$root/bun/cache"
            ;;
    esac
}

# Resolve every Go/Bun entry before a compiler or dependency install can run.
# An explicit entry selects only the primary. Companions must have their own
# conventional Go command directory or package.json bin declaration; a missing
# companion must never fall back to building the primary a second time.
_isb_source_entries() (
    local language="$1" tree="$2" binary="$3" entry="$4"
    shift 4
    local name source_name selected primary windows=false
    local -a entries=()
    case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) windows=true ;; esac
    binary=$(_isb_binary_name "$binary") || return 4
    for name in "$@"; do
        name=$(_isb_binary_name "$name") || return 4
        primary=false
        if [[ "$name" == "$binary" ]] || { $windows && [[ "${name,,}" == "${binary,,}" ]]; }; then
            primary=true
        fi
        source_name="$name"
        $windows && source_name="${source_name%.exe}"
        selected=''
        $primary && selected="$entry"
        if [[ -z "$selected" ]]; then
            case "$language" in
                go)
                    selected="cmd/$source_name"
                    if $primary && [[ ! -e "$tree/$selected" && ! -L "$tree/$selected" ]]; then
                        selected=.
                    fi
                    ;;
                bun|typescript)
                    selected=$(jq -er --arg binary "$source_name" --argjson primary "$primary" '
                        .bin | if type == "object" then .[$binary]
                        elif type == "string" and $primary then . else empty end |
                        select(type == "string" and length > 0)
                    ' "$tree/package.json") || {
                        _isb_log "Bun source entry is missing for $name; declare package.json bin.$source_name"
                        return 4
                    }
                    selected="${selected#./}"
                    ;;
                *) return 4 ;;
            esac
        fi
        if ! _isb_path_in_tree "$tree" "$selected"; then
            _isb_log "Missing or unsafe source entry for $name: $selected"
            return 4
        fi
        case "$language" in
            go) [[ -d "$tree/$selected" ]] || {
                _isb_log "Go source entry for $name must be a package directory: $selected"; return 4;
            } ;;
            *) [[ -f "$tree/$selected" ]] || {
                _isb_log "Bun source entry for $name must be a regular file: $selected"; return 4;
            } ;;
        esac
        entries+=("$selected")
    done
    printf '%s\n' "${entries[@]}"
)

# Resolve Go's relative use/replace directories without letting a lexical '..'
# cross the fetched checkout, or a symlink change what that boundary means.
# In particular, checking only realpath's final answer would admit a linked
# ancestor that happened to return to the checkout later in the path.
_isb_go_directory() (
    local root="$1" base="$2" reference="$3" cursor="$1" path part
    [[ -d "$root" && ! -L "$root" && "$root" == /* &&
       ( "$base" == "$root" || "$base" == "$root/"* ) &&
       -n "$reference" && "$reference" != /* && "$reference" != *\\* &&
       "$reference" != *:* && "$reference" != *[[:cntrl:]]* ]] || return 4
    path="${base#"$root"}"
    path="${path#/}"
    for path in "$path" "$reference"; do
        while [[ -n "$path" ]]; do
            part="${path%%/*}"
            if [[ "$path" == */* ]]; then path="${path#*/}"; else path=''; fi
            case "$part" in
                ''|.) continue ;;
                ..) [[ "$cursor" != "$root" ]] || return 4; cursor="${cursor%/*}" ;;
                *)
                    [[ "${part,,}" != .git ]] || return 4
                    cursor="$cursor/$part"
                    [[ -d "$cursor" && ! -L "$cursor" ]] || return 4
                    ;;
            esac
        done
    done
    printf '%s\n' "$cursor"
)

# The compiler supplies syntax and package identity. Git supplies authority:
# source manifests and locks must be unchanged regular blobs from the fetched
# commit, never ambient or generated inputs.
_isb_source_committed_file() {
    local root="$1" path="$2" relative row mode type oid rest actual hash attributes filter
    [[ "$path" == "$root/"* && -f "$path" && ! -L "$path" ]] || return 4
    relative="${path#"$root"/}"
    row=$(_isb_git --literal-pathspecs -C "$root" ls-tree HEAD -- "$relative") || return 4
    [[ -n "$row" && "$row" != *$'\n'* ]] || return 4
    IFS=$' \t' read -r mode type oid rest <<< "$row"
    [[ "$type" == blob && ( "$mode" == 100644 || "$mode" == 100755 ) &&
       ( "$oid" =~ ^[0-9a-f]{40}$ || "$oid" =~ ^[0-9a-f]{64}$ ) ]] || return 4
    actual=$(_isb_git -C "$root" hash-object --no-filters -- "$path") || return 4
    if [[ "$actual" != "$oid" ]]; then
        # A normal checkout can apply core.autocrlf or tracked text/eol
        # attributes. Let Git perform that normalization, but disable the
        # selected external filter driver before hashing: metadata admission
        # must not execute a clean/process hook. The receipt still hashes the
        # actual checkout bytes that Go parses, including their line endings.
        attributes=$(_isb_git --literal-pathspecs -C "$root" check-attr filter -- "$relative") || return 4
        [[ "$attributes" != *$'\n'* && "$attributes" == *': filter: '* ]] || return 4
        filter="${attributes#*: filter: }"
        [[ "$filter" =~ ^[A-Za-z0-9_/-][A-Za-z0-9._/-]*$ ]] || return 4
        actual=$(_isb_git -c "filter.$filter.clean=" -c "filter.$filter.process=" \
            -c "filter.$filter.required=false" -C "$root" hash-object --path="$relative" -- "$path") || return 4
    fi
    [[ "$actual" == "$oid" ]] || return 4
    # Empty committed go.sum files are valid; payload hashing intentionally
    # requires nonempty executables, so use the metadata boundary here.
    if command -v sha256sum >/dev/null 2>&1; then hash=$(sha256sum < "$path") || return 1
    elif command -v shasum >/dev/null 2>&1; then hash=$(shasum -a 256 < "$path") || return 1
    else return 3; fi
    hash="${hash%% *}"
    [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$hash"
}

# Compiler-independent selection is shared with isolated bootstrap: a fresh
# machine must choose its compiler from the same committed workfile that the
# eventual Go invocation will use. Never inspect an ambient parent workspace.
# Go itself still parses the complete file after a compiler is available.
_isb_go_requirements() (
    local root="$1" tree="$2" cursor="$2" relative selected=''
    relative="${tree#"$root"/}"; [[ "$tree" != "$root" ]] || relative=.
    _isb_go_directory "$root" "$root" "$relative" >/dev/null 2>&1 || {
        _isb_log 'Go build directory escapes the fetched checkout'; return 4;
    }
    while :; do
        if [[ -e "$cursor/go.work" || -L "$cursor/go.work" ]]; then
            selected="$cursor/go.work"
            break
        fi
        [[ "$cursor" != "$root" ]] || break
        cursor="${cursor%/*}"
    done
    [[ -n "$selected" ]] || selected="$tree/go.mod"
    _isb_source_committed_file "$root" "$selected" >/dev/null || {
        _isb_log "The selected ${selected##*/} must be an unchanged committed regular file"; return 4;
    }
    printf '%s\n' "$selected"
)

# Select one committed workspace, or the existing standalone module. Only
# main modules contribute replacement rules: Go ignores replace directives in
# dependency modules, including modules selected by a local replacement.
_isb_go_context() (
    set -o pipefail
    local root="$1" tree="$2" output="$3" limit="$4" requirements work='' work_dir=''
    local work_hash='' parsed paths module_root relative module_path module_hash sum_file status=0
    local index=0 document scope row old version replacement replacement_version key identity hash
    local replacement_module replacement_relative vendor=false vendor_hash='' mod=readonly
    local -a module_roots=() documents=() scopes=()
    local -A seen_paths=() seen_modules=() workspace_replaces=() replacements=()
    export GOENV=off GOFLAGS='' GOWORK=off GOTOOLCHAIN=local GO111MODULE=on GOTELEMETRY=off
    requirements=$(_isb_go_requirements "$root" "$tree") || return $?
    if [[ "${requirements##*/}" == go.work ]]; then
        work="$requirements"; work_dir="${work%/*}"
        work_hash=$(_isb_source_committed_file "$root" "$work") || return 4
        _isb_run "$limit" "$output/go-workspace.log" go work edit -json "$work" || {
            status=$?; [[ "$status" != 5 ]] || return 5; return 4;
        }
        if ! jq -es 'length == 1 and (.[0] | type == "object" and
            (.Use | type == "array" and length > 0 and all(.[];
                type == "object" and (.DiskPath | type == "string" and length > 0 and
                (test("[[:cntrl:]]") | not)))))' "$output/go-workspace.log" >/dev/null; then
            _isb_log 'Go workspace must select at least one literal module directory'; return 4
        fi
        paths=$(jq -r '.Use[].DiskPath' "$output/go-workspace.log") || return 4
        while IFS= read -r relative; do
            module_root=$(_isb_go_directory "$root" "$work_dir" "$relative") || {
                _isb_log "Go workspace module escapes the checkout or traverses a link: $relative"; return 4;
            }
            module_roots+=("$module_root")
        done <<< "$paths"
        documents+=("$output/go-workspace.log"); scopes+=("$work_dir")
    fi
    if [[ -z "$work" ]]; then
        module_roots=("$tree")
        work_dir="$tree"
    elif [[ -e "$work.sum" || -L "$work.sum" ]]; then
        _isb_source_committed_file "$root" "$work.sum" >/dev/null || {
            _isb_log 'go.work.sum must be an unchanged committed regular file'; return 4;
        }
    fi
    : > "$output/go-modules.jsonl" || return 1
    : > "$output/go-replacements.jsonl" || return 1
    for module_root in "${module_roots[@]}"; do
        relative="${module_root#"$root"/}"; [[ "$module_root" != "$root" ]] || relative=.
        [[ -z "${seen_paths[$relative]:-}" ]] || { _isb_log 'Go workspace repeats a module directory'; return 4; }
        seen_paths[$relative]=1
        module_hash=$(_isb_source_committed_file "$root" "$module_root/go.mod") || {
            _isb_log "Go module requires an unchanged committed regular go.mod: $relative"; return 4;
        }
        sum_file="$module_root/go.sum"
        if [[ -e "$sum_file" || -L "$sum_file" ]]; then
            _isb_source_committed_file "$root" "$sum_file" >/dev/null || {
                _isb_log "Go module checksum file is not an unchanged committed regular file: $relative"; return 4;
            }
        fi
        parsed="$output/go-module-$index.log"; index=$((index + 1))
        _isb_run "$limit" "$parsed" go mod edit -json "$module_root/go.mod" || {
            status=$?; [[ "$status" != 5 ]] || return 5; return 4;
        }
        module_path=$(jq -ers 'if length == 1 then .[0].Module.Path |
            select(type == "string" and length > 0 and (test("[[:cntrl:]]") | not))
            else empty end' "$parsed") || { _isb_log "Invalid Go module identity: $relative"; return 4; }
        [[ -z "${seen_modules[$module_path]:-}" ]] || { _isb_log "Go workspace repeats module identity: $module_path"; return 4; }
        seen_modules[$module_path]=1
        jq -nc --arg path "$relative" --arg module "$module_path" --arg hash "$module_hash" \
            '{path:$path,module_path:$module,go_mod_sha256:$hash}' >> "$output/go-modules.jsonl" || return 1
        documents+=("$parsed"); scopes+=("$module_root")
    done
    if [[ -e "$work_dir/vendor" || -L "$work_dir/vendor" ]]; then
        _isb_go_directory "$root" "$work_dir" vendor >/dev/null || {
            _isb_log 'Selected Go vendor directory must stay inside the checkout without links'; return 4;
        }
        document="$work_dir/vendor/modules.txt"
        [[ ! -L "$document" && ( ! -e "$document" || -f "$document" ) ]] || return 4
        if [[ -z "$work" ]]; then
            # Preserve standalone module vendoring, including legacy vendor
            # directories without a modules.txt when Go itself admits them.
            [[ ! -e "$document" ]] || _isb_source_committed_file "$root" "$document" >/dev/null || return 4
            vendor=true; mod=vendor
        elif [[ -f "$document" ]] && head -c 512 "$document" | jq -eRs '
            split("\n")[0] | if startswith("## ") then .[3:] | split(";") |
            any(.[]; gsub("^[[:space:]]+|[[:space:]]+$"; "") == "workspace")
            else false end' >/dev/null; then
            # Go ignores a member module's vendor tree and a legacy module
            # vendor at the workspace root. Match its workspace annotation
            # before choosing vendor mode, rather than forcing an invalid one.
            vendor_hash=$(_isb_source_committed_file "$root" "$document") || return 4
            vendor=true; mod=vendor
        fi
    fi
    # Explicit vendor mode reads the committed vendor tree, not the original
    # directories named by replace rules. Those originals need not exist in a
    # self-contained clone. Go still checks vendor consistency before building;
    # the caller rechecks all tracked source bytes after the complete family.
    if [[ "$mod" != vendor ]]; then
    for index in "${!documents[@]}"; do
        document="${documents[$index]}"; scope="${scopes[$index]}"
        if ! jq -es 'length == 1 and (.[0] | (.Replace // []) | type == "array" and all(.[];
            (.Old.Path | type == "string" and length > 0 and (test("[[:cntrl:]]") | not)) and
            ((.Old.Version // "") | type == "string" and (test("[[:cntrl:]]") | not)) and
            (.New.Path | type == "string" and length > 0 and (test("[[:cntrl:]]") | not)) and
            ((.New.Version // "") | type == "string" and (test("[[:cntrl:]]") | not))))' "$document" >/dev/null; then
            _isb_log 'Invalid Go replacement selection'; return 4
        fi
        paths=$(jq -c '(.Replace // [])[]' "$document") || return 4
        while IFS= read -r row; do
            [[ -n "$row" ]] || continue
            old=$(jq -r '.Old.Path' <<< "$row") || return 4
            version=$(jq -r '.Old.Version // ""' <<< "$row") || return 4
            replacement=$(jq -r '.New.Path' <<< "$row") || return 4
            replacement_version=$(jq -r '.New.Version // ""' <<< "$row") || return 4
            key="$old@$version"
            if [[ -n "$work" && "$document" == "$output/go-workspace.log" ]]; then
                [[ -z "${workspace_replaces[$key]:-}" ]] || { _isb_log 'Repeated Go workspace replacement'; return 4; }
                workspace_replaces[$key]=1
            elif [[ -n "${workspace_replaces[$old@]:-}" || -n "${workspace_replaces[$key]:-}" ]]; then
                continue
            fi
            # An exact workspace override does not erase a module wildcard:
            # other dependency versions could still select that directory.
            # Keep it confined even when the current graph might not use it;
            # admission does not resolve an external graph to prove absence.
            if [[ -n "$replacement_version" ]]; then
                identity="module:$replacement@$replacement_version"
            else
                replacement=$(_isb_go_directory "$root" "$scope" "$replacement") || {
                    _isb_log "Local Go replacement escapes the checkout or traverses a link: $old"; return 4;
                }
                identity="directory:$replacement"
            fi
            if [[ -n "${replacements[$key]:-}" ]]; then
                [[ "${replacements[$key]}" == "$identity" ]] || { _isb_log "Conflicting Go replacement: $old"; return 4; }
                continue
            fi
            replacements[$key]="$identity"
            [[ -z "$replacement_version" ]] || continue
            hash=$(_isb_source_committed_file "$root" "$replacement/go.mod") || {
                _isb_log "Local Go replacement requires a committed regular go.mod: $old"; return 4;
            }
            if [[ -e "$replacement/go.sum" || -L "$replacement/go.sum" ]]; then
                _isb_source_committed_file "$root" "$replacement/go.sum" >/dev/null || return 4
            fi
            parsed="$output/go-replacement-${#replacements[@]}.log"
            _isb_run "$limit" "$parsed" go mod edit -json "$replacement/go.mod" || {
                status=$?; [[ "$status" != 5 ]] || return 5; return 4;
            }
            replacement_module=$(jq -ers 'if length == 1 then .[0].Module.Path |
                select(type == "string" and length > 0 and (test("[[:cntrl:]]") | not))
                else empty end' "$parsed") || return 4
            replacement_relative="${replacement#"$root"/}"; [[ "$replacement" != "$root" ]] || replacement_relative=.
            jq -nc --arg module "$old" --arg version "$version" --arg path "$replacement_relative" \
                --arg replacement "$replacement_module" --arg hash "$hash" \
                '{module_path:$module,version:$version,path:$path,replacement_module_path:$replacement,go_mod_sha256:$hash}' \
                >> "$output/go-replacements.jsonl" || return 1
        done <<< "$paths"
    done
    fi
    relative="${work#"$root"/}"
    jq -nc --arg work "${work:-off}" --arg path "$relative" --arg hash "$work_hash" --arg mod "$mod" \
        --argjson vendor "$vendor" --arg vendor_hash "$vendor_hash" --slurpfile modules "$output/go-modules.jsonl" \
        --slurpfile replacements "$output/go-replacements.jsonl" \
        '{gowork:$work,mod:$mod,go_workspace:(if $work == "off" then null else
          {path:$path,sha256:$hash,modules:$modules,local_replacements:$replacements,vendor:$vendor} +
          (if $vendor then {vendor_modules_sha256:$vendor_hash} else {} end) end)}' \
        > "$output/go-context.json"
)

# Select a locked project without walking outside the fetched checkout. Bun
# itself subsequently confirms that the selected package belongs to this root;
# a nearby unrelated lockfile is not sufficient workspace authority.
_isb_bun_dependency_root() (
    local root="$1" tree="$2" cursor="$2" relative lock found=false
    relative="${tree#"$root"/}"; [[ "$tree" != "$root" ]] || relative=.
    _isb_path_in_tree "$root" "$relative" && [[ -d "$tree" ]] || return 4
    while :; do
        found=false
        for lock in bun.lock bun.lockb; do
            if [[ -e "$cursor/$lock" || -L "$cursor/$lock" ]]; then
                [[ -f "$cursor/$lock" && ! -L "$cursor/$lock" ]] || return 4
                [[ -z "${_ISB_CHECKOUT_ROOT:-}" ]] ||
                    _isb_source_committed_file "$root" "$cursor/$lock" >/dev/null || return 4
                found=true
            fi
        done
        if $found; then
            [[ -f "$cursor/package.json" && ! -L "$cursor/package.json" ]] || return 4
            [[ -z "${_ISB_CHECKOUT_ROOT:-}" ]] ||
                _isb_source_committed_file "$root" "$cursor/package.json" >/dev/null || return 4
            if [[ "$cursor" != "$tree" ]]; then
                jq -es 'length == 1 and (.[0].workspaces |
                    (if type == "object" then .packages else . end) |
                    type == "array" and length > 0 and all(.[]; type == "string" and length > 0))' \
                    "$cursor/package.json" >/dev/null || return 4
            fi
            printf '%s\n' "$cursor"
            return 0
        fi
        [[ "$cursor" != "$root" ]] || break
        cursor="${cursor%/*}"
    done
    _isb_log 'A committed bun.lock or bun.lockb is required in the selected package or its workspace'
    return 4
)

_isb_bun_context() (
    local root="$1" tree="$2" dependency_root="$3" output="$4" limit="$5" status=0
    local selected expected="$dependency_root/node_modules/.bin" lock hash size relative
    local package_hash root_hash root_relative member_relative
    local -a locks=()
    _isb_run "$limit" "$output/bun-project.log" bun pm bin || {
        status=$?; [[ "$status" != 5 ]] || return 5; return 4;
    }
    selected=$(cat "$output/bun-project.log") || return 1
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*)
            command -v cygpath >/dev/null 2>&1 || return 3
            expected=$(cygpath -am "$expected") || return 4
            selected="${selected%$'\r'}"; selected="${selected//\\//}"
            selected="${selected,,}"; expected="${expected,,}"
            ;;
    esac
    [[ "$selected" == "$expected" ]] || {
        _isb_log 'Bun did not select the committed dependency root for this source package'; return 4;
    }
    package_hash=$(_isb_sha256 "$tree/package.json") || return $?
    root_hash=$(_isb_sha256 "$dependency_root/package.json") || return $?
    for lock in bun.lock bun.lockb; do
        [[ -f "$dependency_root/$lock" && ! -L "$dependency_root/$lock" ]] || continue
        hash=$(_isb_sha256 "$dependency_root/$lock") || return $?
        size=$(wc -c < "$dependency_root/$lock") || return 1
        relative="${dependency_root#"$root"/}/$lock"
        [[ "$dependency_root" != "$root" ]] || relative="$lock"
        locks+=("$(jq -nc --arg path "$relative" --arg hash "$hash" --argjson size "$size" \
            '{path:$path,sha256:$hash,size_bytes:$size}')") || return 1
    done
    ((${#locks[@]} > 0)) || return 4
    root_relative="${dependency_root#"$root"/}"; [[ "$dependency_root" != "$root" ]] || root_relative=.
    member_relative="${tree#"$dependency_root"/}"; [[ "$tree" != "$dependency_root" ]] || member_relative=.
    printf '%s\n' "${locks[@]}" | jq -sc --arg package_hash "$package_hash" --arg root_hash "$root_hash" \
        --arg root "$root_relative" --arg member "$member_relative" \
        '{package_json_sha256:$package_hash,bun_lockfiles:.} +
         (if $member == "." then {} else {bun_workspace:{root:$root,member:$member,package_json_sha256:$root_hash}} end)' \
        > "$output/bun-context.json"
)

# Build only the requested executable family, into a new private output directory.
# Never run arbitrary command strings from installer configuration.
_isb_compile() (
    local language="$1" tree="$2" output="$3" binary="$4" entry="$5" package="$6" limit="$7"
    shift 7
    local -a binaries=("$@") targets=() entries=()
    ((${#binaries[@]})) || binaries=("$binary")
    local status=0 host target name mod=readonly resolved_entries selected_entry index log
    cd "$tree" || return 4
    binary=$(_isb_binary_name "$binary") || return 4
    case "$language" in
        rust)
            [[ -f Cargo.toml && ! -L Cargo.toml ]] || return 4
            _isb_prepare_toolchain "$language" "$tree" "$output" "$limit" || return $?
            # rustup proxies may auto-install a missing repository-selected
            # toolchain. Any separately authorized bootstrap is already active;
            # never let a proxy modify an existing global installation.
            # https://rust-lang.github.io/rustup/environment-variables.html
            export RUSTUP_AUTO_INSTALL=0
            # Use the compiler whose identity is recorded below, not an
            # inherited Cargo-only RUSTC or build-cache wrapper. Preserve
            # compiler homes and dependency caches, as the Windows source
            # engine does, while keeping this attempt's outputs private.
            local rustc_command
            rustc_command=$(command -v rustc) || return 3
            export RUSTC="$rustc_command" RUSTC_WRAPPER='' RUSTC_WORKSPACE_WRAPPER=''
            # Empty flag variables still suppress .cargo/config.toml. Remove
            # ambient overrides so the pinned project's cfg/link flags apply.
            unset RUSTFLAGS CARGO_ENCODED_RUSTFLAGS CARGO_BUILD_RUSTFLAGS
            _isb_run "$limit" "$output/compiler.log" "$rustc_command" -vV || { status=$?; [[ $status == 5 ]] && return 5; return 6; }
            host=$(sed -n 's/^host: //p' "$output/compiler.log")
            [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 6
            export CARGO_BUILD_TARGET="$host" CARGO_TARGET_DIR="$output/target" CARGO_INCREMENTAL=0
            local artifact_path cargo_name windows_paths=false
            case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) windows_paths=true ;; esac
            local -a args=(build --locked --release --message-format=json-render-diagnostics
                --target "$host" --target-dir "$output/target")
            if [[ -n "$package" ]]; then
                args+=(--package "$package")
            elif ((${#binaries[@]} > 1)); then
                # A package-root workspace defaults to building only its root
                # package. Explicit family members can live in other packages.
                args+=(--workspace)
            fi
            for name in "${binaries[@]}"; do
                name=$(_isb_binary_name "$name") || return 4
                cargo_name="$name"
                $windows_paths && cargo_name="${cargo_name%.exe}"
                args+=(--bin "$cargo_name")
                targets+=("$output/target/$host/release/$name")
            done
            _isb_run "$limit" "$output/build.log" cargo "${args[@]}" || { status=$?; [[ $status == 5 ]] && return 5; return 6; }
            for target in "${targets[@]}"; do
                name="${target##*/}"
                cargo_name="$name"
                artifact_path="$target"
                if $windows_paths; then
                    cargo_name="${cargo_name%.exe}"
                    command -v cygpath >/dev/null 2>&1 || {
                        _isb_log 'cygpath is required to validate native Windows Cargo output paths'; return 3;
                    }
                    artifact_path=$(cygpath -am "$target") || return 6
                fi
                # A workspace can contain several packages providing the same
                # --bin name. Cargo can exit zero after warning that their
                # executable paths collide. Only one actual compiler artifact
                # may provide each requested output, using Cargo's resolved
                # package/default-feature/required-feature selection.
                if ! jq -eRs --arg name "$cargo_name" --arg path "$artifact_path" \
                    --argjson windows "$windows_paths" '
                    def native_path:
                        if $windows then gsub("\\\\"; "/") | ascii_downcase else . end;
                    [split("\n")[] | fromjson? |
                        select(.reason == "compiler-artifact" and .target.name == $name and
                            (.target.kind | type == "array" and index("bin") != null))] |
                    length == 1 and (.[0].executable | type == "string") and
                    (.[0].executable | native_path) == ($path | native_path) and
                    (.[0].package_id | type == "string" and length > 0)
                ' "$output/build.log" >/dev/null; then
                    _isb_log "Cargo did not identify exactly one executable provider for: $name"
                    return 6
                fi
            done
            ;;
        go)
            resolved_entries=$(_isb_source_entries "$language" "$tree" "$binary" "$entry" "${binaries[@]}") || return $?
            while IFS= read -r selected_entry; do entries+=("$selected_entry"); done <<< "$resolved_entries"
            export GOENV=off GOWORK=off GOTOOLCHAIN=local GOFLAGS='' GO111MODULE=on GOTELEMETRY=off
            local go_requirements
            go_requirements=$(_isb_go_requirements "${_ISB_CHECKOUT_ROOT:-$tree}" "$tree") || return $?
            _isb_prepare_toolchain "$language" "$tree" "$output" "$limit" "$go_requirements" || return $?
            # Build for this installer host, not an inherited cross target.
            export GOOS='' GOARCH=''
            _isb_run "$limit" "$output/compiler.log" go version || { status=$?; [[ $status == 5 ]] && return 5; return 6; }
            _isb_run "$limit" "$output/platform.log" go env GOHOSTOS GOHOSTARCH || { status=$?; [[ $status == 5 ]] && return 5; return 6; }
            local host_os host_arch
            host_os=$(sed -n '1p' "$output/platform.log")
            host_arch=$(sed -n '2p' "$output/platform.log")
            [[ "$host_os" =~ ^[a-z0-9]+$ && "$host_arch" =~ ^[a-z0-9]+$ ]] || return 6
            export GOOS="$host_os" GOARCH="$host_arch"
            _isb_go_context "${_ISB_CHECKOUT_ROOT:-$tree}" "$tree" "$output" "$limit" || return $?
            GOWORK=$(jq -er .gowork "$output/go-context.json") || return 4
            mod=$(jq -er .mod "$output/go-context.json") || return 4
            export GOWORK
            # Check all providers before compiling the first member. A library
            # can make go build succeed with an archive, not an executable.
            for index in "${!entries[@]}"; do
                log="$output/package.log"
                ((${#entries[@]} == 1)) || log="$output/package-$index.log"
                _isb_run "$limit" "$log" go list "-mod=$mod" -f '{{.Name}}' "./${entries[$index]}" || {
                    status=$?; [[ $status == 5 ]] && return 5; return 6;
                }
                [[ "$(cat "$log")" == main ]] || {
                    _isb_log "Requested Go package is not one executable: ${binaries[$index]} (${entries[$index]})"; return 6;
                }
            done
            # Executable names may legally be compiler.log or dependencies.log.
            # Keep payloads separate from retained diagnostics and toolchains.
            mkdir "$output/bin" || return 1
            for index in "${!entries[@]}"; do
                name=$(_isb_binary_name "${binaries[$index]}") || return 4
                _isb_path_in_tree "$tree" "${entries[$index]}" || return 6
                target="$output/bin/$name"
                log="$output/build.log"
                ((${#entries[@]} == 1)) || log="$output/build-$index.log"
                _isb_run "$limit" "$log" go build "-mod=$mod" -trimpath -o "$target" "./${entries[$index]}" || {
                    status=$?; [[ $status == 5 ]] && return 5; return 6;
                }
                targets+=("$target")
            done
            ;;
        bun|typescript)
            [[ -f package.json && ! -L package.json ]] || return 4
            resolved_entries=$(_isb_source_entries "$language" "$tree" "$binary" "$entry" "${binaries[@]}") || return $?
            while IFS= read -r selected_entry; do entries+=("$selected_entry"); done <<< "$resolved_entries"
            local bun_root checkout_root="${_ISB_CHECKOUT_ROOT:-$tree}"
            [[ -z "${_ISB_CHECKOUT_ROOT:-}" ]] ||
                _isb_source_committed_file "$checkout_root" "$tree/package.json" >/dev/null || return 4
            bun_root=$(_isb_bun_dependency_root "$checkout_root" "$tree") || return $?
            unset NODE_OPTIONS BUN_OPTIONS
            _isb_prepare_toolchain "$language" "$bun_root" "$output" "$limit" || return $?
            _isb_run "$limit" "$output/compiler.log" bun --version || { status=$?; [[ $status == 5 ]] && return 5; return 6; }
            _isb_bun_context "$checkout_root" "$tree" "$bun_root" "$output" "$limit" || return $?
            _isb_run "$limit" "$output/dependencies.log" _isb_in_dir "$bun_root" bun install --frozen-lockfile || {
                status=$?; [[ $status == 5 ]] && return 5; return 6;
            }
            mkdir "$output/bin" || return 1
            for index in "${!entries[@]}"; do
                name=$(_isb_binary_name "${binaries[$index]}") || return 4
                _isb_path_in_tree "$tree" "${entries[$index]}" && [[ -f "${entries[$index]}" ]] || return 6
                target="$output/bin/$name"
                log="$output/build.log"
                ((${#entries[@]} == 1)) || log="$output/build-$index.log"
                _isb_run "$limit" "$log" bun build --compile --outfile "$target" "./${entries[$index]}" || {
                    status=$?; [[ $status == 5 ]] && return 5; return 6;
                }
                targets+=("$target")
            done
            ;;
        *) return 4 ;;
    esac
    for target in "${targets[@]}"; do
        _isb_path_in_tree "$output" "${target#"$output"/}" && [[ -f "$target" && -s "$target" ]] || {
            _isb_log "Build did not produce a nonempty regular executable: ${target##*/}"; return 6;
        }
        chmod 755 "$target" || return 1
    done
    printf '%s\n' "${targets[@]}"
)

install_source_build() (
    local repo="${1:-}" ref="${2:-}" language="${3:-}" binary="${4:-}" destination="${5:-}"
    [[ $# -ge 5 ]] || return 4
    shift 5
    local allow=false subdir=. entry='' package='' limit=3600 _ISB_INSTALL_TOOLCHAIN=false
    local -a binaries=()
    while (($#)); do
        case "$1" in
            --allow-build) allow=true; shift ;;
            --install-toolchain) _ISB_INSTALL_TOOLCHAIN=true; shift ;;
            --subdir|--entry|--package|--timeout|--bin)
                [[ $# -ge 2 && -n "$2" ]] || return 4
                case "$1" in
                    --subdir) subdir="$2" ;;
                    --entry) entry="$2" ;;
                    --package) package="$2" ;;
                    --timeout) limit="$2" ;;
                    --bin) binaries+=("$2") ;;
                esac
                shift 2 ;;
            *) return 4 ;;
        esac
    done
    if ! $allow; then
        _isb_log 'Source builds execute repository code; explicit --allow-build consent is required'
        return 4
    fi
    [[ "$repo" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || return 4
    _isb_name "$binary" && _isb_relative_path "$subdir" || return 4
    [[ -z "$entry" ]] || _isb_relative_path "$entry" || return 4
    [[ -z "$package" ]] || _isb_name "$package" || return 4
    [[ "$limit" =~ ^[1-9][0-9]{0,4}$ ]] || return 4
    case "$language" in rust|go|bun|typescript) ;; *) _isb_log "Unsupported source language: $language"; return 4 ;; esac
    [[ "$language" != rust || -z "$entry" ]] || { _isb_log 'Rust selects the configured binary, not --entry'; return 4; }
    [[ "$language" == rust || -z "$package" ]] || { _isb_log '--package is only supported for Rust'; return 4; }
    ((${#binaries[@]})) || binaries=("$binary")
    local -A binary_keys=()
    local -a binary_names=()
    local selected key primary_name primary_index=-1 index=0 windows=false
    case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) windows=true ;; esac
    primary_name=$(_isb_binary_name "$binary") || return 4
    for selected in "${binaries[@]}"; do
        _isb_name "$selected" || { _isb_log "Unsafe executable name: $selected"; return 4; }
        key="$selected"
        if $windows; then
            key="${key,,}"
            key="${key%.exe}"
        fi
        if [[ -n "${binary_keys[$key]:-}" ]]; then
            _isb_log "Duplicate or colliding executable name: $selected"
            return 4
        fi
        binary_keys[$key]=1
        selected=$(_isb_binary_name "$selected") || return 4
        binary_names+=("$selected")
        if [[ "$selected" == "$primary_name" ]] ||
           { $windows && [[ "${selected,,}" == "${primary_name,,}" ]]; }; then
            primary_index=$index
        fi
        index=$((index + 1))
    done
    if ((primary_index < 0)); then
        _isb_log "Requested executable family must include primary binary: $binary"
        return 4
    fi
    local tool
    for tool in git jq ps; do
        command -v "$tool" >/dev/null 2>&1 || { _isb_log "Required source-build dependency missing: $tool"; return 3; }
    done
    case "$language" in rust) tool=cargo ;; go) tool=go ;; *) tool=bun ;; esac
    if ! $_ISB_INSTALL_TOOLCHAIN; then
        command -v "$tool" >/dev/null 2>&1 || { _isb_log "Install $tool first, or opt in with --install-toolchain"; return 3; }
        [[ "$language" != rust ]] || command -v rustc >/dev/null 2>&1 || return 3
    fi
    if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then return 3; fi
    _isb_ref "$ref" || { _isb_log 'Use HEAD, a full commit SHA, refs/heads/<branch>, or refs/tags/<tag>'; return 4; }
    [[ -n "$destination" && ! -e "$destination" && ! -L "$destination" && "$destination" != */ ]] || return 4
    local parent name
    parent=$(dirname "$destination")
    name=$(basename "$destination")
    _isb_name "$name" && [[ -d "$parent" && ! -L "$parent" ]] || return 4
    parent=$(cd "$parent" && pwd -P) || return 4
    destination="$parent/$name"
    umask 077
    mkdir "$destination" || return 1
    local tree="$destination/source" output="$destination/output" status=0 commit payload sha size receipt payloads
    mkdir "$output" || return 1
    _isb_log "Fetching $repo at $ref into an isolated checkout"
    _isb_run "$limit" "$destination/fetch.log" _isb_checkout "$repo" "$ref" "$tree" || {
        status=$?; [[ $status == 5 ]] && return 5; return 8;
    }
    commit=$(_isb_git -C "$tree" rev-parse --verify 'HEAD^{commit}') || return 8
    # An incomplete checkout cannot masquerade as a supported source build.
    local entries
    entries=$(_isb_git -C "$tree" ls-files --stage) || return 8
    if grep -q '^160000 ' <<< "$entries"; then
        _isb_log 'Submodule source builds require a project-specific dependency setup'; return 4
    fi
    _isb_path_in_tree "$tree" "$subdir" && [[ -d "$tree/$subdir" ]] || return 4
    local build_root _ISB_CHECKOUT_ROOT="$tree"
    build_root=$(cd "$tree/$subdir" && pwd -P) || return 4
    _isb_log "Building ${binary_names[*]} from pinned commit $commit ($language)"
    payloads=$(_isb_compile "$language" "$build_root" "$output" "$binary" "$entry" "$package" "$limit" "${binaries[@]}") || return $?
    # Preserve the source pin through compilation. Build scripts may not move
    # HEAD or modify tracked inputs and then claim they built the pinned tree.
    [[ "$(_isb_git -C "$tree" rev-parse --verify 'HEAD^{commit}')" == "$commit" ]] || return 6
    _isb_git -C "$tree" diff --quiet HEAD -- || { _isb_log 'Build modified tracked source inputs'; return 6; }
    local -a binary_receipts=()
    local primary_payload='' primary_sha='' primary_size='' binaries_json
    index=0
    while IFS= read -r payload; do
        [[ $index -lt ${#binary_names[@]} && "$payload" == "$output/"* &&
           "${payload##*/}" == "${binary_names[$index]}" ]] || return 6
        _isb_path_in_tree "$output" "${payload#"$output"/}" || return 6
        sha=$(_isb_sha256 "$payload") || return $?
        size=$(wc -c < "$payload") || return 1
        size="${size//[[:space:]]/}"
        binary_receipts+=("$(jq -nc --arg name "${binary_names[$index]}" --arg path "$payload" \
            --arg sha "$sha" --argjson size "$size" \
            '{name:$name,path:$path,sha256:$sha,size_bytes:$size}')") || return 1
        if ((index == primary_index)); then
            primary_payload="$payload"; primary_sha="$sha"; primary_size="$size"
        fi
        index=$((index + 1))
    done <<< "$payloads"
    [[ $index -eq ${#binary_names[@]} && -n "$primary_payload" ]] || return 6
    payload="$primary_payload"; sha="$primary_sha"; size="$primary_size"
    binaries_json=$(printf '%s\n' "${binary_receipts[@]}" | jq -sc '.') || return 1
    local toolchain_receipt=null go_context_file=/dev/null bun_context_file=/dev/null
    if [[ -f "$output/toolchain/receipt.json" ]]; then
        toolchain_receipt=$(jq -ce 'del(.root,.bin_dir)' "$output/toolchain/receipt.json") || return 7
    fi
    if [[ "$language" == go ]]; then
        go_context_file="$output/go-context.json"
        [[ -f "$go_context_file" && ! -L "$go_context_file" ]] || return 7
    fi
    if [[ "$language" == bun || "$language" == typescript ]]; then
        bun_context_file="$output/bun-context.json"
        [[ -f "$bun_context_file" && ! -L "$bun_context_file" ]] || return 7
    fi
    receipt=$(jq -nc --arg repo "$repo" --arg ref "$ref" --arg commit "$commit" \
        --arg language "$language" --arg path "$payload" --arg sha "$sha" --argjson size "$size" \
        --argjson binaries "$binaries_json" \
        --argjson toolchain "$toolchain_receipt" \
        --slurpfile go_context "$go_context_file" \
        --slurpfile bun_context "$bun_context_file" \
        --arg compiler "$(cat "$output/compiler.log")" \
        '{schema_version:1,method:"source",repository:$repo,requested_ref:$ref,source_commit:$commit,
          language:$language,path:$path,sha256:$sha,size_bytes:$size,compiler:$compiler,
          binaries:$binaries,signed_release:false} +
          (if $toolchain == null then {} else {toolchain:$toolchain} end) +
          (if $go_context[0].go_workspace == null then {} else {go_workspace:$go_context[0].go_workspace} end) +
          ($bun_context[0] // {})') || return 1
    (set -C; printf '%s\n' "$receipt" > "$destination/receipt.json") || return 1
    _isb_log "Built $binary; SHA256 $sha (locally built, not a signed release)"
    printf '%s\n' "$receipt"
)

# Runtime state
_VERSION=""
_INSTALL_DIR="${HOME}/.local/bin"
_JSON_MODE=false
_JSON_EMITTED=false
_VERIFY=true
_REQUIRE_SIGNATURES=false
_NON_INTERACTIVE=false
_AUTO_YES=false
_RECOVER=false
_OFFLINE_ARCHIVE=""
_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/dsr/installers"
_OFFLINE_MODE=false
_PREFER_GH=false
_SKIP_SKILLS=false
_FROM_SOURCE=false
_ALLOW_SOURCE_BUILD=false
_INSTALL_TOOLCHAIN=false
_SOURCE_REF=""
_SOURCE_TIMEOUT=3600
_SOURCE_RECEIPT=null
_SOURCE_IF_STALE=""
_RELEASE_FRESHNESS=null
_KEEP_SOURCE_LOGS=false
_LIBC=""
_TARGET_TRIPLE=""
_INSTALL_PLATFORM=""
_PRIMARY_INSTALL_NAME="$BINARY_NAME"
_INSTALL_NAMES=()
_INSTALL_PATHS=()
_INSTALL_APPROVALS=()
_INSTALLED_BINARIES_JSON='[]'
_GITHUB_ASSET_INDEX=""
_GITHUB_ASSET_REPO=""
_GITHUB_ASSET_TAG=""
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

# Shared by success receipts and the jq-free installer path. Work bytewise so
# UTF-8 remains unchanged while every JSON control character is escaped.
_json_escape_str() {
    local value="$1" char code index=0 LC_ALL=C
    while ((index < ${#value})); do
        char="${value:$index:1}"
        case "$char" in
            '"') printf '\\"' ;;
            '\') printf '\\\\' ;;
            *)
                printf -v code '%d' "'$char"
                if ((code < 32)); then printf '\\u%04x' "$code"
                else printf '%s' "$char"; fi ;;
        esac
        index=$((index + 1))
    done
}

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
                --argjson binaries "$_INSTALLED_BINARIES_JSON" \
                '{tool: $tool, status: $status, message: $message, version: $version, path: $path}
                 + if $status == "success" then {binaries:$binaries} else {} end
                 + if $status == "success" and $source_receipt != null
                   then {method:"source", signed_release:false, source:$source_receipt} else {} end
                 + if $freshness != null then {freshness:$freshness} else {} end'
        else
            local esc_tool esc_status esc_msg esc_ver esc_path
            esc_tool=$(_json_escape_str "$TOOL_NAME")
            esc_status=$(_json_escape_str "$status")
            esc_msg=$(_json_escape_str "$message")
            esc_ver=$(_json_escape_str "$version")
            esc_path=$(_json_escape_str "$path")
            printf '{"tool":"%s","status":"%s","message":"%s","version":"%s","path":"%s"' \
                "$esc_tool" "$esc_status" "$esc_msg" "$esc_ver" "$esc_path"
            [[ "$status" != success ]] || printf ',"binaries":%s' "$_INSTALLED_BINARIES_JSON"
            printf '}\n'
        fi
    fi
}

# Validated at generation time; no YAML or jq is needed on release clients.
_workspace_binary_names() {
    case "$1" in
        *) printf '%s\n' 'cass' ;;
    esac
}

_select_install_family() {
    local platform="$1" names name normalized seen='' primary_key key
    names=$(_workspace_binary_names "$platform") || return 4
    _INSTALL_PLATFORM="$platform"
    _INSTALL_NAMES=()
    _PRIMARY_INSTALL_NAME="$BINARY_NAME"
    primary_key="$BINARY_NAME"
    if [[ "$platform" == windows/* ]]; then
        primary_key=$(printf '%s' "$primary_key" | tr '[:upper:]' '[:lower:]') || return 4
        primary_key="${primary_key%.exe}.exe"
    fi
    local primary_found=false
    while IFS= read -r name; do
        [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ && "$name" != *..* ]] || return 4
        normalized="$name"; key="$name"
        if [[ "$platform" == windows/* ]]; then
            key=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]') || return 4
            if [[ "$key" == *.exe ]]; then normalized="${name:0:${#name}-4}.exe"
            else normalized="$name.exe"; fi
            key="${key%.exe}.exe"
        fi
        case "$seen" in *"|$key|"*) return 4 ;; esac
        seen+="|$key|"
        if [[ "$key" == "$primary_key" ]]; then
            primary_found=true
            _PRIMARY_INSTALL_NAME="$normalized"
        fi
        _INSTALL_NAMES+=("$normalized")
    done <<< "$names"
    $primary_found || { _log_error "Executable family omits primary $BINARY_NAME"; return 4; }
}

# Detect platform (OS and architecture)
_detect_platform() {
    local os arch

    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    case "$os" in
        darwin) os="darwin" ;;
        linux) os="linux" ;;
        freebsd) os="freebsd" ;;
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

    if [[ ! "$os/$arch" =~ $SUPPORTED_PLATFORM_PATTERN ]]; then
        _log_error "Unsupported platform: $os/$arch"
        return 1
    fi
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
        freebsd) echo "$ARCHIVE_FORMAT_FREEBSD" ;;
        *) echo "tar.gz" ;;
    esac
}

# ============================================================================
# CACHE FUNCTIONS
# ============================================================================

# A checksum proves the cached bytes match their sidecar, not which repository
# supplied them. Bind cache selection to the exact repository, release asset,
# platform/ABI and interpretation before consulting any locally saved evidence.
# Each asset owns its sidecars, so another asset ending in .sha256 or .minisig
# cannot overwrite its evidence. Unscoped older entries are not adopted.
_cache_path() {
    local version="$1"
    local platform="$2"
    local format="$3"
    local asset="${4:-}"
    [[ "$asset" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ && "$asset" != *..* ]] || return 4
    echo "${_CACHE_DIR}/${TOOL_NAME}/${REPO}/${version}/${platform//\//-}/${format}/${asset}/payload"
}

# Check if cached archive exists
_cache_get() {
    local version="$1"
    local platform="$2"
    local format="$3"
    local asset="$4"
    local cache_file
    cache_file=$(_cache_path "$version" "$platform" "$format" "$asset") || return $?

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
    local asset="$5"
    local cache_file
    cache_file=$(_cache_path "$version" "$platform" "$format" "$asset") || return $?
    local cache_dir
    cache_dir=$(dirname "$cache_file")

    mkdir -p "$cache_dir" || return 1
    [[ ! -L "$cache_dir" ]] || return 1
    local stage suffix cleanup
    stage=$(mktemp -d "$cache_dir/.verified.XXXXXXXX") || return 1
    printf -v cleanup 'rm -rf -- %q' "$stage"
    # shellcheck disable=SC2064 # expand now: $cleanup is a %q-quoted command for this stage
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

    esac

    echo "$arch"
}

# Configured targets are distinct from the default table: their cache entries
# are qualified by the actual selected triple, including scalar overrides.
_configured_target_triples() {
    local os="$1"
    local arch="$2"
    case "${os}/${arch}" in

    esac
    return 1
}

# Generic Go releases built with CGO disabled do not select a C-library ABI.
# This table comes from the effective build configuration, never client env.
# Explicit compiler targets and strict release contracts are not included.
_libc_independent_go_platform() {
    case "$1" in

    esac
    return 1
}

# Target triples released for a platform, primary first.
_target_triple_candidates() {
    local os="$1" arch="$2"
    _configured_target_triples "$os" "$arch" && return 0

    case "${os}/${arch}" in
        linux/amd64) echo "x86_64-unknown-linux-gnu" ;;
        linux/arm64) echo "aarch64-unknown-linux-gnu" ;;
        linux/386) echo "i686-unknown-linux-gnu" ;;
        linux/armv7) echo "armv7-unknown-linux-gnueabihf" ;;
        darwin/amd64) echo "x86_64-apple-darwin" ;;
        darwin/arm64) echo "aarch64-apple-darwin" ;;
        windows/amd64) echo "x86_64-pc-windows-msvc" ;;
        windows/arm64) echo "aarch64-pc-windows-msvc" ;;
        windows/386) echo "i686-pc-windows-msvc" ;;
        freebsd/amd64) echo "x86_64-unknown-freebsd" ;;
        *) echo "${os}-${arch}" ;;
    esac
}

# Inspect ldd itself, never a downloaded executable. musl's version command
# writes to stderr and may exit nonzero; capture the text independently of rc.
# An installed alternate musl loader must not override a recognized GNU host.
_detect_linux_libc() {
    local version="" loader
    if command -v ldd >/dev/null 2>&1; then
        version=$(ldd --version 2>&1) || true
        version=$(printf '%s' "$version" | LC_ALL=C tr '[:upper:]' '[:lower:]') || return 1
        case "$version" in
            *musl*) echo musl; return 0 ;;
            *"gnu libc"*|*"gnu c library"*|*glibc*) echo gnu; return 0 ;;
        esac
    fi
    if command -v getconf >/dev/null 2>&1; then
        version=$(getconf GNU_LIBC_VERSION 2>/dev/null) || true
        version=$(printf '%s' "$version" | LC_ALL=C tr '[:upper:]' '[:lower:]') || return 1
        [[ "$version" != *glibc* ]] || { echo gnu; return 0; }
    fi
    for loader in /lib/ld-musl-*.so.1 /usr/lib/ld-musl-*.so.1; do
        if [[ -e "$loader" ]]; then
            echo musl
            return 0
        fi
    done
    return 1
}

# The variant to install: the --libc request, else this Linux system's C
# library. Explicit requests are exact. An automatic GNU -> musl fallback is
# allowed only by linux_libc_fallback: musl; musl never falls back to GNU.
_select_target_triple() {
    local os="$1" arch="$2" candidates libc="$_LIBC" triple
    candidates=$(_target_triple_candidates "$os" "$arch")
    if [[ "$os" != linux ]]; then
        [[ -z "$libc" ]] || { _log_error "--libc is supported only on Linux"; return 4; }
        echo "${candidates%% *}"
        return 0
    fi
    if [[ -z "$libc" ]] && _libc_independent_go_platform "$os/$arch"; then
        _log_info "Using the Go release built with CGO disabled for $os/$arch"
        echo "${candidates%% *}"
        return 0
    fi
    if [[ -z "$libc" ]] && ! libc=$(_detect_linux_libc); then
        _log_error "Cannot identify Linux libc; use --libc gnu or --libc musl to select a known variant"
        return 4
    fi
    for triple in $candidates; do
        if [[ -n "$libc" && "${triple##*-}" == "$libc"* ]]; then
            echo "$triple"
            return 0
        fi
    done
    if [[ -z "$_LIBC" && "$libc" == gnu && "$LINUX_LIBC_FALLBACK" == musl ]]; then
        for triple in $candidates; do
            if [[ "${triple##*-}" == musl* ]]; then
                _log_warn "No GNU variant configured; using the explicit GNU-to-musl fallback: $triple"
                echo "$triple"
                return 0
            fi
        done
    fi
    # A known host with no compatible release is an acquisition absence.
    # Only explicit source consent may select this internal status; unknown
    # libc and an unsatisfied --libc request keep their original refusals.
    # The caller must still resolve the release tag before invoking source.
    if [[ -z "$_LIBC" ]] && $_ALLOW_SOURCE_BUILD; then
        _log_warn "No $libc release build of $TOOL_NAME is configured for ${os}/${arch}; source fallback is permitted"
        return 1
    fi
    _log_error "No $libc build of $TOOL_NAME is configured for ${os}/${arch}"
    return 4
}

# A second acquisition candidate is permitted only for automatic GNU selection.
# The caller never consults it after checksum/signature/extraction failure.
_fallback_target_triple() {
    local os="$1" arch="$2" selected="$3" triple candidates
    [[ "$os" == linux && "${selected##*-}" == gnu* &&
       -z "$_LIBC" && "$LINUX_LIBC_FALLBACK" == musl ]] || return 0
    candidates=$(_target_triple_candidates "$os" "$arch")
    for triple in $candidates; do
        if [[ "${triple##*-}" == musl* ]]; then echo "$triple"; return 0; fi
    done
}

_target_cache_platform() {
    local platform="$1"
    if [[ -z "$_LIBC" ]] && _libc_independent_go_platform "$platform"; then
        # Do not adopt a generic cache made before the no-CGO build policy was
        # embedded: those bytes may have required the original host's libc.
        printf '%s/cgo-disabled\n' "$platform"
    elif _configured_target_triples "${platform%/*}" "${platform#*/}" >/dev/null || [[ -n "$_LIBC" ]]; then
        printf '%s/%s\n' "$platform" "$_TARGET_TRIPLE"
    else
        printf '%s\n' "$platform"
    fi
}

_resolve_target_triple() {
    if [[ -n "$_TARGET_TRIPLE" ]]; then
        echo "$_TARGET_TRIPLE"
        return 0
    fi
    local candidates
    candidates=$(_target_triple_candidates "$1" "$2")
    echo "${candidates%% *}"
}

# Strict releases own literal asset names and formats for each compiler target.
# Keep this table separate from generic naming: even an arbitrary Full/Lite
# name must select the exact variant, without aliases or extension guesses.
_contract_asset_plan() {
    case "$1@$_TARGET_TRIPLE" in

    esac
    _log_error "No exact release asset is configured for $1 ($_TARGET_TRIPLE)"
    return 4
}

# Ordinary native Rust matrices publish colliding secondary names with the
# full compiler triple. Workflow jobs do not own that naming rule. This table
# is frozen from the same per-platform act_job_map routing used by the build.
_native_variant_platform() {
    case "$1" in

    esac
    return 1
}

# Match _act_native_variant_artifact_name's suffix placement, including raw
# names and sidecars. The caller has already established native ownership,
# a configured nonprimary target, and a collision with the primary name.
_qualified_native_asset_name() {
    local name="$1" base="$1" ext=""
    case "$name" in
        *.tar.gz) ext=.tar.gz; base="${name%.tar.gz}" ;;
        *.tar.xz) ext=.tar.xz; base="${name%.tar.xz}" ;;
        *.tgz) ext=.tgz; base="${name%.tgz}" ;;
        *.zip) ext=.zip; base="${name%.zip}" ;;
        *.exe) ext=.exe; base="${name%.exe}" ;;
        *.minisig|*.sha256|*.sha512|*.sig)
            ext=".${name##*.}"
            base=$(_qualified_native_asset_name "${name%.*}") || return $?
            printf '%s%s\n' "$base" "$ext"
            return 0 ;;
    esac
    printf '%s-%s%s\n' "$base" "$_TARGET_TRIPLE" "$ext"
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

# Generic aliases belong to the configured primary. A nonprimary variant must
# have a distinct download name; otherwise a musl request could fetch GNU bytes
# even with separate cache entries and a valid checksum.
_variant_asset_name() {
    local os="$1" arch="$2" version="$3" format="$4" name candidates primary primary_name
    if $STRICT_RELEASE_CONTRACT; then
        local plan
        plan=$(_contract_asset_plan "$os/$arch") || return $?
        printf '%s\n' "${plan%%$'\t'*}"
        return 0
    fi
    name=$(_apply_artifact_pattern "$ARTIFACT_NAMING" "$os" "$arch" "$version" "$format") || return $?
    [[ "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ && "$name" != *..* ]] || {
        _log_error "Unresolved or unsafe release asset name: $name"; return 4;
    }
    if [[ "$os" == linux ]]; then
        local words=" ${name//[-_.]/ } " libc="${_TARGET_TRIPLE##*-}" token
        for token in gnu musl gnueabi gnueabihf musleabi musleabihf gnux32 gnullvm uclibc; do
            if [[ "$words" == *" $token "* && "$libc" != "$token" ]]; then
                _log_error "Asset name $name contradicts selected target $_TARGET_TRIPLE"
                return 4
            fi
        done
    fi
    candidates=$(_target_triple_candidates "$os" "$arch")
    primary="${candidates%% *}"
    if [[ "$_TARGET_TRIPLE" != "$primary" ]]; then
        primary_name=$(_TARGET_TRIPLE="$primary" _apply_artifact_pattern "$ARTIFACT_NAMING" "$os" "$arch" "$version" "$format") || return $?
        if [[ "$name" == "$primary_name" ]]; then
            if _native_variant_platform "$os/$arch"; then
                name=$(_qualified_native_asset_name "$name") || return $?
            else
                _log_error "Artifact naming does not distinguish $_TARGET_TRIPLE from primary $primary; use a target-qualified pattern"
                return 4
            fi
        fi
    fi
    printf '%s\n' "$name"
}

# ============================================================================
# GH CLI DOWNLOAD
# ============================================================================

# A token-only installation must not require a separately installed GitHub CLI.
# Keep the existing anonymous/gh preference when gh is available. Inspect
# credentials only in an untraced child; even a malformed explicit token selects
# this path so it cannot fall through to an anonymous request.
_installer_token_api_selected() (
    set +x
    ! command -v gh >/dev/null 2>&1 &&
        [[ -n "${DSR_GH_TOKEN:-}" || -n "${GITHUB_TOKEN:-}" || -n "${GH_TOKEN:-}" ]]
)

_installer_token_api_dependencies() {
    if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        _log_error "Private release installation without gh requires curl and jq"
        return 3
    fi
}

# Only HTTPS DNS origins on the default port are accepted. Do not let URL
# credentials, fragments, backslashes or control characters change routing.
# curl resolves relative Location values before returning redirect_url.
_installer_api_https_url() {
    local url="$1" authority tail
    local authority_pattern='^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:443)?$'
    [[ "$url" == https://* && "$url" != *[[:space:][:cntrl:]]* &&
       "$url" != *\\* && "$url" != *'#'* && ${#url} -le 16384 ]] || return 1
    tail="${url#https://}"
    [[ "$tail" == */* ]] || return 1
    authority="${tail%%/*}"
    [[ "$authority" =~ $authority_pattern ]]
}

# Scope credentials to this repository's release API, including redirects.
# Refuse encoded or literal traversal even when the raw prefix appears correct.
_installer_api_in_scope() {
    local url="$1" tail authority path
    _installer_api_https_url "$url" || return 1
    tail="${url#https://}"; authority="${tail%%/*}"
    authority=$(printf '%s' "$authority" | tr '[:upper:]' '[:lower:]') || return 1
    [[ "$authority" == api.github.com || "$authority" == api.github.com:443 ]] || return 1
    path="/${tail#*/}"; path="${path%%\?*}"
    path="${path//%2B/+}"; path="${path//%2b/+}"
    [[ "$path" == "/repos/$REPO/releases/"* && "$path" != *%* &&
       "$path" =~ ^[A-Za-z0-9._+/-]+$ ]] || return 1
    case "$path/" in *'/../'*|*'/./'*|*'//'*) return 1 ;; esac
}

# One complete transfer, with manual redirects and a bounded body pipe. Both
# the credential and signed object-store URLs reach curl through stdin, never
# command arguments or a saved curl config. -q ignores an ambient .curlrc.
# The pipe enforces the byte limit even on curl versions whose --max-filesize
# only checks Content-Length. The request deadline covers every redirect.
_installer_api_download() (
    set +x
    set -o pipefail
    local url="$1" destination="$2" kind="$3" maximum="$4" limit="$5"
    local source_fallback="${6:-false}" transfer_status
    local -a transfer_statuses=()
    local token escaped_token escaped_url status reply next authority tail bytes
    local redirects=0 send_credential=true remaining deadline=$((SECONDS + limit))
    local transfer_maximum="$maximum"
    local accept='application/vnd.github+json' response_file="$destination.http"
    _installer_token_api_dependencies || return $?
    token=$(_installer_github_token) || {
        _log_error "Invalid selected GitHub credential"; return 4;
    }
    [[ ${#token} -le 8192 && "$token" != *[[:cntrl:]]* ]] || {
        _log_error "Invalid selected GitHub credential"; return 4;
    }
    [[ "$maximum" =~ ^[1-9][0-9]*$ && "$limit" =~ ^[1-9][0-9]*$ &&
       ( "$kind" == json || "$kind" == asset ) &&
       ( "$source_fallback" == true || "$source_fallback" == false ) ]] || return 4
    # A redirect's small HTML body may exceed a checksum/signature asset's
    # actual size. Bound it independently; a final 200 still obeys maximum.
    ((transfer_maximum >= 65536)) || transfer_maximum=65536
    _installer_api_in_scope "$url" || return 4
    [[ "$kind" != asset ]] || accept='application/octet-stream'
    escaped_token="${token//\\/\\\\}"; escaped_token="${escaped_token//\"/\\\"}"
    while ((redirects <= 5)); do
        _installer_api_https_url "$url" || {
            _log_error "Refusing an unsafe GitHub download redirect"; return 8;
        }
        if ! _installer_api_in_scope "$url"; then
            tail="${url#https://}"; authority="${tail%%/*}"
            authority=$(printf '%s' "$authority" | tr '[:upper:]' '[:lower:]') || return 8
            if [[ "$kind" != asset || "$authority" == api.github.com || "$authority" == api.github.com:443 ]]; then
                _log_error "GitHub API redirect changed the selected repository"; return 8
            fi
            # A later redirect back to GitHub must not regain this credential.
            send_credential=false
        fi
        # Validate an already-observed redirect before considering expiry;
        # elapsed time cannot turn an unsafe destination into availability.
        remaining=$((deadline - SECONDS))
        if ((remaining <= 0)); then
            _log_error "GitHub download exceeded its complete-transfer deadline"
            [[ "$source_fallback" != true ]] || return 1
            return 8
        fi
        escaped_url="${url//\\/\\\\}"; escaped_url="${escaped_url//\"/\\\"}"
        if ! {
            printf 'url = "%s"\n' "$escaped_url"
            if $send_credential; then
                printf 'header = "Authorization: Bearer %s"\n' "$escaped_token"
            fi
        } | curl -q --config - --silent --globoff --proto '=https' --proto-redir '=https' \
            --connect-timeout 15 --max-time "$remaining" --max-filesize "$transfer_maximum" \
            --header "Accept: $accept" --header 'X-GitHub-Api-Version: 2022-11-28' \
            --user-agent 'dsr-installer' --output /dev/fd/3 \
            --write-out '%{http_code}\n%{redirect_url}' 3>&1 > "$response_file" 2>/dev/null |
            head -c "$((transfer_maximum + 1))" > "$destination"; then
            transfer_statuses=("${PIPESTATUS[@]}")
            for transfer_status in "${transfer_statuses[@]}"; do
                case "$transfer_status" in
                    129|130|131|143) _log_error "GitHub acquisition was cancelled"; return 5 ;;
                esac
            done
            if [[ "${transfer_statuses[1]:-0}" == 42 ]]; then
                _log_error "GitHub acquisition was cancelled"; return 5
            fi
            _log_error "GitHub download failed during transfer"
            # Only opted-in discovery/primary callers receive the internal
            # unavailable result. Failed local writes, size limits, TLS trust,
            # malformed options and other client errors never grant consent.
            # Curl exit codes: https://curl.se/docs/manpage.html#EXIT-CODES
            if [[ "$source_fallback" == true && "${transfer_statuses[0]:-1}" == 0 &&
                  "${transfer_statuses[2]:-1}" == 0 ]]; then
                # A transfer can fail after receiving a denial or redirect.
                # Its incomplete body cannot erase that HTTP evidence.
                reply=$(cat -- "$response_file") || return 8
                status="${reply%%$'\n'*}"
                case "$status" in
                    000|200|408|429|5[0-9][0-9])
                        case "${transfer_statuses[1]:-0}" in
                            5|6|7|16|18|28|52|55|56|92|95) return 1 ;;
                        esac
                        ;;
                esac
            fi
            return 8
        fi
        bytes=$(wc -c < "$destination" | tr -d '[:space:]') || return 8
        [[ "$bytes" =~ ^[0-9]+$ ]] && ((bytes <= transfer_maximum)) || {
            _log_error "GitHub download exceeds its size limit"; return 7;
        }
        reply=$(cat -- "$response_file") || return 8
        status="${reply%%$'\n'*}"
        if [[ "$status" == 200 ]]; then
            ((bytes <= maximum)) || {
                _log_error "GitHub download exceeds its size limit"; return 7;
            }
            return 0
        fi
        case "$status" in
            301|302|303|307|308)
                next="${reply#*$'\n'}"
                [[ "$reply" == *$'\n'* && -n "$next" && $redirects -lt 5 ]] || {
                    _log_error "Invalid or excessive GitHub download redirects"; return 8;
                }
                url="$next"; redirects=$((redirects + 1))
                ;;
            *)
                [[ "$status" =~ ^[0-9]{3}$ ]] || status=unknown
                _log_error "GitHub download failed with HTTP $status"
                if [[ "$source_fallback" == true ]]; then
                    case "$status" in 408|429|5[0-9][0-9]) return 1 ;; esac
                fi
                return 8
                ;;
        esac
    done
    return 8
)

# Validate exactly one published release object. A singleton array, boolean
# string, absent draft marker or mismatched tag is not a release identity.
_installer_api_release_id() {
    local file="$1" tag="$2"
    jq -er -s --arg tag "$tag" '
        def positive_id: type == "number" and . > 0 and . <= 9007199254740991 and floor == .;
        if length == 1 and (.[0] | type == "object" and
            (.id | positive_id) and (.tag_name | type == "string") and
            .tag_name == $tag and .draft == false)
        then .[0].id else error("invalid published release identity") end
    ' "$file" 2>/dev/null
}

_installer_api_latest() (
    local source_fallback="${1:-false}" directory tag
    _installer_token_api_dependencies || return $?
    directory=$(mktemp -d) || return 8
    trap 'rm -rf -- "$directory"' EXIT
    _installer_api_download "https://api.github.com/repos/$REPO/releases/latest" \
        "$directory/release.json" json 8388608 30 "$source_fallback" || return $?
    tag=$(jq -er -s 'if length == 1 and (.[0] | type == "object") and
        (.[0].tag_name | type == "string") then .[0].tag_name else error("invalid tag") end' \
        "$directory/release.json" 2>/dev/null) || {
        _log_error "Malformed GitHub release tag"; return 7;
    }
    _valid_release_version "$tag" &&
        _installer_api_release_id "$directory/release.json" "$tag" >/dev/null || {
        _log_error "GitHub release identity does not select a published tag"; return 7;
    }
    printf '%s\n' "$tag"
)

# Discover every page before selecting any asset. Build our own endpoint URLs;
# neither browser_download_url nor Link headers control repository selection.
# Keep the normalized inventory in private staging, not argv or a token cache.
_installer_api_prepare_assets() {
    local source_fallback="${1:-false}"
    if [[ "$_GITHUB_ASSET_REPO" == "$REPO" && "$_GITHUB_ASSET_TAG" == "$_VERSION" &&
          -f "$_GITHUB_ASSET_INDEX" && ! -L "$_GITHUB_ASSET_INDEX" ]]; then return 0; fi
    _installer_token_api_dependencies || return $?
    [[ -n "$_TEMP_DIR" && -d "$_TEMP_DIR" && ! -L "$_TEMP_DIR" ]] || return 8
    local directory release_id page=1 count
    directory=$(mktemp -d "$_TEMP_DIR/github-release.XXXXXXXX") || return 8
    _installer_api_download "https://api.github.com/repos/$REPO/releases/tags/${_VERSION//+/%2B}" \
        "$directory/release.json" json 8388608 30 "$source_fallback" || return $?
    release_id=$(_installer_api_release_id "$directory/release.json" "$_VERSION") || {
        _log_error "GitHub release identity does not match the selected published tag"; return 7;
    }
    printf '[]\n' > "$directory/assets.json" || return 8
    while ((page <= 101)); do
        _installer_api_download "https://api.github.com/repos/$REPO/releases/$release_id/assets?per_page=100&page=$page" \
            "$directory/page.json" json 8388608 30 "$source_fallback" || return $?
        if ! jq -e -s '
            def integer: type == "number" and . >= 0 and . <= 9007199254740991 and floor == .;
            if length == 1 and (.[0] | type == "array" and length <= 100) and
                all(.[0][]; type == "object" and (.id | integer and . > 0) and
                    (.name | type == "string" and length > 0 and length <= 1024 and
                        (test("[\u0000-\u001f\u007f]") | not)) and
                    (.size | integer) and (.state | type == "string"))
            then .[0] | map({id, name, size, state})
            else error("invalid release asset page") end
        ' "$directory/page.json" > "$directory/selected-page.json" 2>/dev/null; then
            _log_error "Malformed GitHub release asset page"; return 7
        fi
        count=$(jq -er 'length' "$directory/selected-page.json") || return 7
        if ! jq -e --slurpfile page "$directory/selected-page.json" '
            (. + $page[0]) as $assets |
            if ($assets | length <= 10000) and
                ($assets | group_by(.id) | all(.[]; length == 1)) and
                ($assets | group_by(.name) | all(.[]; length == 1))
            then $assets else error("duplicate or excessive release assets") end
        ' "$directory/assets.json" > "$directory/next-assets.json" 2>/dev/null; then
            _log_error "Duplicate GitHub release asset identity or inventory exceeds 10000 entries"; return 7
        fi
        mv -- "$directory/next-assets.json" "$directory/assets.json" || return 8
        if ((count < 100)); then
            _GITHUB_ASSET_REPO="$REPO"
            _GITHUB_ASSET_TAG="$_VERSION"
            _GITHUB_ASSET_INDEX="$directory/assets.json"
            return 0
        fi
        page=$((page + 1))
    done
    _log_error "GitHub release asset inventory exceeds 10000 entries"
    return 7
}

_installer_api_fetch_asset() {
    local asset="$1" destination="$2" maximum="$3" selection asset_id size actual
    local source_fallback="${4:-false}"
    _installer_api_prepare_assets "$source_fallback" || return $?
    selection=$(jq -r --arg name "$asset" --argjson maximum "$maximum" '
        map(select(.name == $name)) |
        if length == 0 then "missing"
        elif length == 1 and (.[0] | .state == "uploaded" and .size > 0 and .size <= $maximum)
        then .[0] | [.id, .size] | @tsv else "invalid" end
    ' "$_GITHUB_ASSET_INDEX") || return 7
    [[ "$selection" != missing ]] || return 1
    if [[ "$selection" == invalid ]]; then
        _log_error "Selected release asset is incomplete or exceeds its size limit: $asset"; return 7
    fi
    IFS=$'\t' read -r asset_id size <<< "$selection"
    # Presence in the inventory is authoritative. Auth failures, deleted
    # members or changed bytes are never optional misses. Only primary-payload
    # acquisition explicitly opts into classified source fallback; proof
    # downloads keep every discovered-member transport failure terminal.
    _installer_api_download "https://api.github.com/repos/$REPO/releases/assets/$asset_id" \
        "$destination" asset "$size" 300 "$source_fallback" || return $?
    actual=$(wc -c < "$destination" | tr -d '[:space:]') || return 8
    if [[ "$actual" != "$size" ]]; then
        _log_error "Release asset size changed after discovery: $asset"; return 7
    fi
}

# Anonymous requests distinguish proven absence from refusals before source
# fallback. Bound every response and the complete redirect chain, ignore curl
# configuration, and retain HTTP evidence when a transfer subsequently fails.
# Status 9 is internal: a denied anonymous API request may still resolve a
# public tag, or a denied public asset may use gh, but neither authorizes source.
_installer_public_download() (
    set +x
    local url="$1" destination="$2" maximum="$3" limit="$4" kind="$5"
    local status reply next remaining bytes part code escaped_url
    local redirects=0 deadline=$((SECONDS + limit))
    local response_file="$destination.http" transfer_maximum="$maximum"
    local -a transfer_statuses=() method=()
    [[ "$maximum" =~ ^[1-9][0-9]*$ && "$limit" =~ ^[1-9][0-9]*$ &&
       ( "$kind" == json || "$kind" == asset || "$kind" == head ) ]] || return 4
    command -v curl >/dev/null 2>&1 || return 3
    ((transfer_maximum >= 65536)) || transfer_maximum=65536
    [[ "$kind" != head ]] || method=(--head)
    while ((redirects <= 5)); do
        _installer_api_https_url "$url" || {
            _log_error "Refusing an unsafe public release redirect"; return 8;
        }
        if [[ "$kind" == json ]]; then
            _installer_api_in_scope "$url" || {
                _log_error "Public release API redirect changed the selected repository"; return 8;
            }
        elif [[ "$kind" == head && "$url" != "https://github.com/$REPO/releases/latest" ]]; then
            part="${url#"https://github.com/$REPO/releases/tag/"}"
            part="${part//%2B/+}"; part="${part//%2b/+}"
            [[ "$url" == "https://github.com/$REPO/releases/tag/"* ]] && _valid_release_version "$part" || {
                _log_error "Public release discovery left the selected repository tag route"; return 8;
            }
        fi
        remaining=$((deadline - SECONDS))
        if ((remaining <= 0)); then
            _log_error "Public release request exceeded its complete-transfer deadline"
            return 1
        fi
        escaped_url="${url//\\/\\\\}"; escaped_url="${escaped_url//\"/\\\"}"
        if ! printf 'url = "%s"\n' "$escaped_url" |
            curl -q --config - --silent --globoff --proto '=https' --proto-redir '=https' \
            --connect-timeout 15 --max-time "$remaining" --max-filesize "$transfer_maximum" \
            --user-agent 'dsr-installer' ${method[@]+"${method[@]}"} \
            --output /dev/fd/3 --write-out '%{http_code}\n%{redirect_url}' \
            3>&1 > "$response_file" 2>/dev/null | head -c "$((transfer_maximum + 1))" > "$destination"; then
            transfer_statuses=("${PIPESTATUS[@]}")
            for code in "${transfer_statuses[@]}"; do
                case "$code" in 129|130|131|143) _log_error "Release acquisition was cancelled"; return 5 ;; esac
            done
            [[ "${transfer_statuses[1]:-0}" != 42 ]] || return 5
            reply=$(cat -- "$response_file") || return 8
            status="${reply%%$'\n'*}"
            if [[ "${transfer_statuses[0]:-1}" == 0 && "${transfer_statuses[2]:-1}" == 0 ]]; then
                case "$status" in
                    000|200|408|429|5[0-9][0-9])
                        case "${transfer_statuses[1]:-0}" in
                            5|6|7|16|18|28|52|55|56|92|95) return 1 ;;
                        esac
                        ;;
                esac
            fi
            _log_error "Public release transfer failed without availability evidence"
            return 8
        fi
        bytes=$(wc -c < "$destination" | tr -d '[:space:]') || return 8
        [[ "$bytes" =~ ^[0-9]+$ ]] && ((bytes <= transfer_maximum)) || return 7
        reply=$(cat -- "$response_file") || return 8
        status="${reply%%$'\n'*}"
        if [[ "$status" == 200 ]]; then
            ((bytes <= maximum)) || return 7
            [[ "$kind" != head ]] || printf '%s\n' "$url"
            return 0
        fi
        case "$status" in
            301|302|303|307|308)
                next="${reply#*$'\n'}"
                [[ "$reply" == *$'\n'* && -n "$next" && $redirects -lt 5 ]] || return 8
                url="$next"; redirects=$((redirects + 1))
                ;;
            404|410|408|429|5[0-9][0-9]) return 1 ;;
            403) [[ "$kind" != json && "$kind" != asset ]] || return 9; return 8 ;;
            401) [[ "$kind" != asset ]] || return 9; return 8 ;;
            *) _log_error "Public release request failed with HTTP ${status:-unknown}"; return 8 ;;
        esac
    done
    return 8
)

# Fetch one exact asset for payloads AND their checksum/signature sidecars.
# Transport fallback happens here, before verification, never after it fails.
_fetch_release_asset() {
    local asset="$1" dest="$2" maximum="${3:-2147483648}" url status=0 failure=3
    local source_fallback="${4:-false}" gh_ambiguous=false
    $_OFFLINE_MODE && return 1
    [[ "$asset" =~ ^[A-Za-z0-9._+-]+$ && "$asset" != . && "$asset" != .. ]] || return 4
    if _installer_token_api_selected; then
        _installer_api_fetch_asset "$asset" "$dest" "$maximum" "$source_fallback"
        return $?
    fi
    url="https://github.com/$REPO/releases/download/$_VERSION/${asset//+/%2B}"
    if $_PREFER_GH && command -v gh &>/dev/null; then
        _installer_run_gh release download "$_VERSION" --repo "github.com/$REPO" --pattern "$asset" --output "$dest" --clobber 2>/dev/null || status=$?
        if ((status == 0)); then
            [[ -f "$dest" && ! -L "$dest" && -s "$dest" ]] || return 7
            return 0
        fi
        case "$status" in 5|4) return "$status" ;; 1) gh_ambiguous=true ;; 3) ;; *) failure=8 ;; esac
    fi
    if command -v curl &>/dev/null; then
        status=0
        _installer_public_download "$url" "$dest" "$maximum" 300 asset || status=$?
        if ((status == 0)); then
            [[ -f "$dest" && ! -L "$dest" && -s "$dest" ]] || return 7
            return 0
        fi
        case "$status" in
            1) [[ "$failure" == 8 ]] || failure=1 ;;
            9) failure=8 ;;
            *) return "$status" ;;
        esac
    fi
    if ! $_PREFER_GH && command -v gh &>/dev/null; then
        status=0
        _installer_run_gh release download "$_VERSION" --repo "github.com/$REPO" --pattern "$asset" --output "$dest" --clobber 2>/dev/null || status=$?
        if ((status == 0)); then
            [[ -f "$dest" && ! -L "$dest" && -s "$dest" ]] || return 7
            return 0
        fi
        case "$status" in 5|4) return "$status" ;; 1) gh_ambiguous=true ;; 3) ;; *) failure=8 ;; esac
    fi
    # A missing optional sidecar may proceed to another checksum filename
    # after curl independently proves availability failure. An ambiguous gh
    # failure cannot supply that evidence, or permit compiling the payload.
    if $gh_ambiguous && { [[ "$source_fallback" == true ]] || [[ "$failure" == 3 ]]; }; then
        return 8
    fi
    return "$failure"
}

# A tag becomes one URL and cache-path component; never accept API null,
# multiple results, redirects to other repositories, or path/query syntax.
_valid_release_version() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ && "$1" != null ]]
}

# Use authenticated discovery for private repos and an API-independent public
# redirect when the releases API is throttled. Never guess a tag from a date.
_get_latest_version() (
    local api_url="https://api.github.com/repos/$REPO/releases/latest"
    local version="" effective prefix="https://github.com/$REPO/releases/tag/"
    local status=0 failure=3 directory
    $_OFFLINE_MODE && return 4
    if _installer_token_api_selected; then
        _installer_api_latest "$_ALLOW_SOURCE_BUILD"
        return $?
    fi
    if $_PREFER_GH && command -v gh &>/dev/null; then
        version=$(_installer_run_gh release view --repo "github.com/$REPO" --json tagName --jq '.tagName' 2>/dev/null) || status=$?
        if ((status == 0)); then
            _valid_release_version "$version" || return 7
            printf '%s\n' "$version"; return 0
        fi
        case "$status" in 5|4) return "$status" ;; 3) ;; *) failure=8 ;; esac
    fi
    if command -v curl &>/dev/null; then
        directory=$(mktemp -d) || return 8
        trap 'rm -rf -- "$directory"' EXIT
        if command -v jq &>/dev/null; then
            status=0
            _installer_public_download "$api_url" "$directory/release.json" 8388608 30 json || status=$?
            if ((status == 0)); then
                version=$(jq -er -s 'if length == 1 and (.[0] | type == "object") and
                    (.[0].tag_name | type == "string") then .[0].tag_name else error("invalid release") end' \
                    "$directory/release.json" 2>/dev/null) && _valid_release_version "$version" &&
                    _installer_api_release_id "$directory/release.json" "$version" >/dev/null || {
                    _log_error "Malformed public release metadata"; return 7;
                }
                printf '%s\n' "$version"; return 0
            fi
            case "$status" in 1) [[ "$failure" == 8 ]] || failure=1 ;; 9) failure=8 ;; *) return "$status" ;; esac
        fi
        # HEAD follows only HTTPS redirects. Pin the final owner/repo and tag
        # route rather than accepting a login page, another repo, or /latest.
        status=0
        effective=$(_installer_public_download "https://github.com/$REPO/releases/latest" \
            "$directory/latest" 8388608 30 head) || status=$?
        if ((status == 0)) && [[ "$effective" == "$prefix"* ]]; then
            version="${effective#"$prefix"}"
            version="${version//%2B/+}"; version="${version//%2b/+}"
            if _valid_release_version "$version"; then
                _log_info "Resolved latest release without the GitHub API: $version"
                printf '%s\n' "$version"; return 0
            fi
        fi
        if ((status == 1)); then
            [[ "$failure" == 8 ]] || failure=1
        elif ((status == 0)); then
            return 8
        else
            return "$status"
        fi
    fi
    if ! $_PREFER_GH && command -v gh &>/dev/null; then
        status=0
        version=$(_installer_run_gh release view --repo "github.com/$REPO" --json tagName --jq '.tagName' 2>/dev/null) || status=$?
        if ((status == 0)); then
            _valid_release_version "$version" || return 7
            printf '%s\n' "$version"; return 0
        fi
        case "$status" in 5|4) return "$status" ;; 3) ;; *) failure=8 ;; esac
    fi
    _log_error "Cannot resolve latest release; use --version with an existing release tag"
    return "$failure"
)

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
        local found=false fetch_status
        for candidate in "$asset.sha256" checksums.sha256 SHA256SUMS \
            "${TOOL_NAME}-${_VERSION#v}-SHA256SUMS.txt" SHA256SUMS.txt checksums.txt; do
            fetch_status=0
            _fetch_release_asset "$candidate" "$manifest" 8388608 || fetch_status=$?
            if ((fetch_status == 0)); then
                found=true
                [[ "$candidate" != "$asset.sha256" ]] || hash_only=true
                break
            fi
            # Only an absent inventory name can select the next checksum.
            ((fetch_status == 1)) || return "$fetch_status"
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

    local sig_file="${file}.minisig" fetch_status=0
    if [[ ! -e "$sig_file" && ! -L "$sig_file" ]]; then
        _fetch_release_asset "$asset.minisig" "$sig_file" 1048576 || fetch_status=$?
        if ((fetch_status != 0)); then
            _log_error "Signature unavailable for $asset"
            ((fetch_status != 5)) || return 5
            return 1
        fi
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
            cp -- "$archive" "$dest_dir/$_PRIMARY_INSTALL_NAME" || return 1
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
        # ${a[@]+"${a[@]}"}: plain tar has no flag, and an empty "${a[@]}"
        # is an unbound-variable abort under set -u before Bash 4.4.
        members=$(tar ${tar_args[@]+"${tar_args[@]}"} -tf "$archive" 2>/dev/null) || return 1
        listing=$(LC_ALL=C tar ${tar_args[@]+"${tar_args[@]}"} -tvf "$archive" 2>/dev/null) || return 1
    fi
    [[ -n "$members" ]] || return 1
    # Runs under `curl | bash`, which is Bash 3.2 on stock macOS: no
    # associative arrays. Collect normalized names, then look for repeats.
    local normalized="" duplicate
    while IFS= read -r member; do
        count=$((count + 1))
        [[ "$member" != /* && "$member" != *[[:cntrl:]]* && "$member" != *\\* && "$member" != *:* ]] || return 1
        while [[ "$member" == ./* ]]; do member="${member#./}"; done
        member="${member%/}"
        [[ -n "$member" && "$member" != . ]] || continue
        [[ "$member" != -* ]] || return 1
        case "/$member/" in *'/../'*|*'/./'*|*'//'*) return 1 ;; esac
        if [[ "$_INSTALL_PLATFORM" == windows/* ]]; then
            # A case-insensitive filesystem would overwrite these members
            # during extraction, hiding the duplicate from binary selection.
            member=$(printf '%s' "$member" | LC_ALL=C tr '[:upper:]' '[:lower:]') || return 1
        fi
        normalized+="$member"$'\n'
    done <<< "$members"
    # A failed sort/uniq must not read as "no duplicates" (pipefail is on).
    duplicate=$(printf '%s' "$normalized" | LC_ALL=C sort | LC_ALL=C uniq -d) || return 1
    duplicate="${duplicate%%$'\n'*}"
    [[ -z "$duplicate" ]] || { _log_error "Duplicate archive member: $duplicate"; return 1; }
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
        local attributes=0 mode attribute_pattern='^[[:space:]]+Unix file attributes \(([0-7]{6}) octal\)'
        listing=$(LC_ALL=C unzip -Z -v "$archive" 2>/dev/null) || return 1
        while IFS= read -r line; do
            if [[ "$line" =~ $attribute_pattern ]]; then
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
        tar ${tar_args[@]+"${tar_args[@]}"} --no-same-owner --no-same-permissions -xf "$archive" -C "$dest_dir" || return 1
    fi
}

# Inspect bounded native headers without executing a downloaded program or
# requiring Python/file on the installer host. Bash 3.2 and BSD/GNU od work.
# These checks bind executable format and CPU, not every runtime dependency,
# minimum OS release, CPU extension, or libc symbol version.
_installer_header_bytes() {
    local path="$1" offset="$2" count="$3" data
    local -a bytes=()
    data=$(LC_ALL=C od -An -v -tu1 -j "$offset" -N "$count" "$path" 2>/dev/null) || return 1
    data="${data//$'\n'/ }"
    read -r -a bytes <<< "$data"
    (( ${#bytes[@]} == count )) || return 1
    printf '%s\n' "${bytes[*]}"
}

# Decode at most eight header bytes, refusing offsets outside a 32-bit file
# extent before multiplication can overflow shell arithmetic. Payloads larger
# than 4 GiB require a different admission policy, not a truncated offset.
_installer_header_uint() {
    local endian="$1" value=0 index byte
    shift
    local -a digits=("$@")
    (( ${#digits[@]} > 0 && ${#digits[@]} <= 8 )) || return 1
    for ((index=0; index<${#digits[@]}; index++)); do
        if [[ "$endian" == le ]]; then byte="${digits[${#digits[@]}-index-1]}"
        else byte="${digits[index]}"; fi
        [[ "$byte" =~ ^[0-9]+$ ]] && (( byte <= 255 && value <= 16777215 )) || return 1
        value=$((value * 256 + byte))
    done
    printf '%s\n' "$value"
}

_installer_macho_slice() {
    local path="$1" offset="$2" length="$3" expected_cpu="$4" expected_subtype="${5:-}"
    local data endian header_size cpu subtype kind commands command_bytes magic
    local -a header=()
    (( length >= 32 )) || return 1
    data=$(_installer_header_bytes "$path" "$offset" 32) || return 1
    read -r -a header <<< "$data"
    magic="${header[0]} ${header[1]} ${header[2]} ${header[3]}"
    case "$magic" in
        '207 250 237 254') endian=le; header_size=32 ;;
        '254 237 250 207') endian=be; header_size=32 ;;
        '206 250 237 254') endian=le; header_size=28 ;;
        '254 237 250 206') endian=be; header_size=28 ;;
        *) return 1 ;;
    esac
    cpu=$(_installer_header_uint "$endian" "${header[@]:4:4}") || return 1
    subtype=$(_installer_header_uint "$endian" "${header[@]:8:4}") || return 1
    kind=$(_installer_header_uint "$endian" "${header[@]:12:4}") || return 1
    commands=$(_installer_header_uint "$endian" "${header[@]:16:4}") || return 1
    command_bytes=$(_installer_header_uint "$endian" "${header[@]:20:4}") || return 1
    [[ "$cpu" == "$expected_cpu" && ( -z "$expected_subtype" || "$subtype" == "$expected_subtype" ) ]] || return 1
    # Current Intel/ARM macOS slices are little-endian, even inside a fat
    # container whose table is big-endian. Legacy extra slices may differ.
    case "$cpu" in 16777223|16777228) [[ "$endian" == le ]] || return 1 ;; esac
    (( kind == 2 && commands > 0 && commands <= command_bytes / 8 &&
       command_bytes <= length - header_size )) || return 1
    if (( cpu & 16777216 )); then (( header_size == 32 )) || return 1
    else (( header_size == 28 )) || return 1; fi
}

_installer_native_payload() {
    local path="$1" size="$3" data magic os="${2%/*}" arch="${2#*/}"
    local class machine expected_class expected_machine kind version offset width entry
    local header_size ph_size ph_count expected_ph_size cpu subtype count table_size stride
    local length align index prior found=false endian=be optional_size optional_magic sections flags subsystem
    local -a header=() row=() starts=() ends=()
    data=$(_installer_header_bytes "$path" 0 4) || return 1
    read -r -a header <<< "$data"
    magic="${header[*]}"
    case "$magic" in
        '127 69 76 70')
            [[ "$os" == linux || "$os" == freebsd ]] || return 1
            (( size >= 52 )) || return 1
            data=$(_installer_header_bytes "$path" 0 52) || return 1
            read -r -a header <<< "$data"
            class="${header[4]}"
            [[ "${header[5]}" == 1 && "${header[6]}" == 1 ]] || return 1
            case "$os:${header[7]}" in linux:0|linux:3|freebsd:0|freebsd:9) ;; *) return 1 ;; esac
            case "$arch" in
                amd64) expected_class=2; expected_machine=62 ;;
                arm64) expected_class=2; expected_machine=183 ;;
                386) expected_class=1; expected_machine=3 ;;
                armv7) expected_class=1; expected_machine=40 ;;
                *) return 1 ;;
            esac
            machine=$(_installer_header_uint le "${header[@]:18:2}") || return 1
            kind=$(_installer_header_uint le "${header[@]:16:2}") || return 1
            version=$(_installer_header_uint le "${header[@]:20:4}") || return 1
            (( class == expected_class && machine == expected_machine &&
               (kind == 2 || kind == 3) && version == 1 )) || return 1
            if (( class == 2 )); then
                data=$(_installer_header_bytes "$path" 0 64) || return 1
                read -r -a header <<< "$data"
                header_size=64; width=8; expected_ph_size=56
                offset=$(_installer_header_uint le "${header[@]:32:8}") || return 1
                ph_size=$(_installer_header_uint le "${header[@]:54:2}") || return 1
                ph_count=$(_installer_header_uint le "${header[@]:56:2}") || return 1
                length=$(_installer_header_uint le "${header[@]:52:2}") || return 1
            else
                header_size=52; width=4; expected_ph_size=32
                offset=$(_installer_header_uint le "${header[@]:28:4}") || return 1
                ph_size=$(_installer_header_uint le "${header[@]:42:2}") || return 1
                ph_count=$(_installer_header_uint le "${header[@]:44:2}") || return 1
                length=$(_installer_header_uint le "${header[@]:40:2}") || return 1
            fi
            entry="${header[*]:24:width}"
            [[ "$entry" == *[1-9]* ]] || return 1
            (( length == header_size && offset >= header_size && ph_size == expected_ph_size &&
               ph_count > 0 && ph_count < 65535 && offset + ph_size * ph_count <= size ))
            ;;
        '207 250 237 254'|'254 237 250 207'|'206 250 237 254'|'254 237 250 206')
            [[ "$os" == darwin ]] || return 1
            case "$arch" in amd64) cpu=16777223 ;; arm64) cpu=16777228 ;; *) return 1 ;; esac
            _installer_macho_slice "$path" 0 "$size" "$cpu"
            ;;
        '202 254 186 190'|'190 186 254 202'|'202 254 186 191'|'191 186 254 202')
            [[ "$os" == darwin ]] || return 1
            case "$arch" in amd64) expected_machine=16777223 ;; arm64) expected_machine=16777228 ;; *) return 1 ;; esac
            case "$magic" in
                '202 254 186 190') stride=20; endian=be ;;
                '190 186 254 202') stride=20; endian=le ;;
                '202 254 186 191') stride=32; endian=be ;;
                *) stride=32; endian=le ;;
            esac
            data=$(_installer_header_bytes "$path" 4 4) || return 1
            read -r -a header <<< "$data"
            count=$(_installer_header_uint "$endian" "${header[@]}") || return 1
            table_size=$((8 + count * stride))
            (( count > 0 && count <= 64 && table_size <= size )) || return 1
            for ((index=0; index<count; index++)); do
                data=$(_installer_header_bytes "$path" "$((8 + index * stride))" "$stride") || return 1
                read -r -a row <<< "$data"
                cpu=$(_installer_header_uint "$endian" "${row[@]:0:4}") || return 1
                subtype=$(_installer_header_uint "$endian" "${row[@]:4:4}") || return 1
                if (( stride == 32 )); then
                    offset=$(_installer_header_uint "$endian" "${row[@]:8:8}") || return 1
                    length=$(_installer_header_uint "$endian" "${row[@]:16:8}") || return 1
                    align=$(_installer_header_uint "$endian" "${row[@]:24:4}") || return 1
                    [[ "${row[*]:28:4}" == '0 0 0 0' ]] || return 1
                else
                    offset=$(_installer_header_uint "$endian" "${row[@]:8:4}") || return 1
                    length=$(_installer_header_uint "$endian" "${row[@]:12:4}") || return 1
                    align=$(_installer_header_uint "$endian" "${row[@]:16:4}") || return 1
                fi
                (( offset >= table_size && length >= 32 && offset + length <= size &&
                   align <= 31 && offset % (1 << align) == 0 )) || return 1
                for ((prior=0; prior<index; prior++)); do
                    (( offset >= ends[prior] || offset + length <= starts[prior] )) || return 1
                done
                starts+=("$offset"); ends+=("$((offset + length))")
                _installer_macho_slice "$path" "$offset" "$length" "$cpu" "$subtype" || return 1
                [[ "$cpu" != "$expected_machine" ]] || found=true
            done
            $found
            ;;
        *)
            [[ "${header[0]} ${header[1]}" == '77 90' && "$os" == windows && $size -ge 64 ]] || return 1
            data=$(_installer_header_bytes "$path" 60 4) || return 1
            read -r -a header <<< "$data"
            offset=$(_installer_header_uint le "${header[@]}") || return 1
            (( offset >= 64 && offset + 24 <= size )) || return 1
            data=$(_installer_header_bytes "$path" "$offset" 24) || return 1
            read -r -a header <<< "$data"
            [[ "${header[*]:0:4}" == '80 69 0 0' ]] || return 1
            machine=$(_installer_header_uint le "${header[@]:4:2}") || return 1
            sections=$(_installer_header_uint le "${header[@]:6:2}") || return 1
            optional_size=$(_installer_header_uint le "${header[@]:20:2}") || return 1
            flags=$(_installer_header_uint le "${header[@]:22:2}") || return 1
            case "$arch" in
                amd64) expected_machine=34404; optional_magic=523; width=112 ;;
                arm64) expected_machine=43620; optional_magic=523; width=112 ;;
                386) expected_machine=332; optional_magic=267; width=96 ;;
                *) return 1 ;;
            esac
            (( machine == expected_machine && sections > 0 && sections <= 96 &&
               (flags & 2) != 0 && (flags & 8192) == 0 && optional_size >= width &&
               offset + 24 + optional_size + sections * 40 <= size )) || return 1
            data=$(_installer_header_bytes "$path" "$((offset + 24))" "$width") || return 1
            read -r -a header <<< "$data"
            kind=$(_installer_header_uint le "${header[@]:0:2}") || return 1
            entry=$(_installer_header_uint le "${header[@]:16:4}") || return 1
            subsystem=$(_installer_header_uint le "${header[@]:68:2}") || return 1
            (( kind == optional_magic && entry > 0 && (subsystem == 2 || subsystem == 3) ))
            ;;
    esac
}

_installer_validate_executable() {
    local path="$1" platform="$2" size data line
    [[ -f "$path" && ! -L "$path" && -s "$path" ]] || return 7
    command -v od >/dev/null 2>&1 || { _log_error 'od is required to inspect executable headers'; return 3; }
    size=$(wc -c < "$path" | tr -d '[:space:]') || return 1
    [[ "$size" =~ ^[1-9][0-9]*$ && ${#size} -le 10 ]] && (( size <= 4294967295 )) || return 7
    data=$(_installer_header_bytes "$path" 0 2) || return 7
    if [[ "$data" == '35 33' ]]; then
        # Script launchers are intentional release payloads even for compiled
        # projects. Recognize their interpreter declaration, never run it.
        line=$(LC_ALL=C head -c 4096 "$path") || return 1
        line="${line%%$'\n'*}"
        line="${line%$'\r'}"
        [[ "$line" =~ ^#![[:blank:]]*/[^[:space:][:cntrl:]]+ ]] && return 0
    elif _installer_native_payload "$path" "$platform" "$size"; then
        return 0
    fi
    _log_error "Executable format or architecture does not match $platform: ${path##*/}"
    return 7
}

# GNU and BSD stat use different format switches. This identity check is also
# used for the private owner file, so cleanup cannot remove a replacement lock.
_install_lock_identity() {
    local value
    value=$(stat -c '%d:%i' -- "$1" 2>/dev/null) ||
        value=$(stat -f '%d:%i' "$1" 2>/dev/null) || return 1
    [[ "$value" =~ ^[0-9]+:[0-9]+$ ]] || return 1
    printf '%s\n' "$value"
}

_install_lock_owned() {
    local directory="$1" directory_identity="$2" owner_identity="$3" owner="$4" observed
    [[ -d "$directory" && ! -L "$directory" && -f "$directory/owner" && ! -L "$directory/owner" ]] || return 1
    [[ "$(_install_lock_identity "$directory")" == "$directory_identity" &&
       "$(_install_lock_identity "$directory/owner")" == "$owner_identity" ]] || return 1
    observed=$(cat -- "$directory/owner") || return 1
    [[ "$observed" == "$owner" ]]
}

# File identities distinguish our renamed payloads from a later user's edit.
# Keep this producer in Bash: ordinary release installation needs no Python.
_install_file_record() {
    local path="$1" before after hash mode value
    local fields=()
    [[ -f "$path" && ! -L "$path" ]] || return 1
    before=$(stat -c '%d %i %a %u %g %h %s' -- "$path" 2>/dev/null) ||
        before=$(stat -f '%d %i %Lp %u %g %l %z' "$path" 2>/dev/null) || return 1
    read -r -a fields <<< "$before"
    [[ ${#fields[@]} -eq 7 && "${fields[2]}" =~ ^[0-7]{1,4}$ ]] || return 1
    for value in "${fields[@]}"; do [[ "$value" =~ ^[0-9]+$ ]] || return 1; done
    mode=$((8#${fields[2]}))
    hash=$(_file_sha256 "$path") || return $?
    after=$(stat -c '%d %i %a %u %g %h %s' -- "$path" 2>/dev/null) ||
        after=$(stat -f '%d %i %Lp %u %g %l %z' "$path" 2>/dev/null) || return 1
    [[ -f "$path" && ! -L "$path" && "$before" == "$after" ]] || return 1
    printf '{"identity":"%s:%s","nlink":%s,"mode":%s,"uid":%s,"gid":%s,"size":%s,"sha256":"%s"}' \
        "${fields[0]}" "${fields[1]}" "${fields[5]}" "$mode" "${fields[3]}" "${fields[4]}" "${fields[6]}" "$hash"
}

_install_destination_record() {
    if [[ -e "$1" || -L "$1" ]]; then _install_file_record "$1"
    else printf 'null'; fi
}

# Stage the complete family and backups on the destination filesystem before
# replacing its first member. On failure, restore every touched destination;
# unrelated executables are never moved or removed.
# This function is launched only as a background job by _install_binaries.
# A second function-body subshell would hide the actual writer behind $! and
# leave it running when the parent forwards a signal to its tracked child.
_install_family_transaction() {
    # Job control in the foreground parent gives this writer its own group.
    # All its utility children remain in that group after the writer dies.
    set +m
    local dest_dir="$1" startup="$2"; shift 2
    local sources=("$@") hashes=() sizes=() previous=() originals=() candidates=() backups=() restorations=()
    local name path hash size previous_hash backup_hash index=0 stage='' committed=false touched=0
    local receipt='[' separator='' original_dir="$dest_dir"
    local install_lock='' lock_identity='' owner_identity='' lock_owner='' lock_held=false lock_setup_interrupted=false
    local writer_pid='' writer_group='' writer_host='' writer_host_hex='' directory_hex='' process_scope=global startup_deadline=$((SECONDS + 5))
    local directory_identity='' stage_identity='' journal='' journal_hash='' original_record backup_record rollback_record candidate_record
    local original_identity='' original_identities='|'
    while ((SECONDS < startup_deadline)); do
        if [[ -f "$startup" && ! -L "$startup" ]] && IFS= read -r writer_pid < "$startup"; then break; fi
        sleep 0.01
    done
    [[ "$writer_pid" =~ ^[1-9][0-9]*$ ]] || exit 3
    writer_group=$(ps -o pgid= -p "$writer_pid") || exit 3
    writer_group="${writer_group//[[:space:]]/}"
    [[ "$writer_group" == "$writer_pid" ]] || { _log_error 'Cannot isolate the installation writer'; exit 3; }
    writer_host=$(uname -n) || exit 3
    writer_host_hex=$(printf '%s' "$writer_host" | od -An -tx1 | tr -d '[:space:]') || exit 3
    if [[ "$_INSTALL_PLATFORM" == linux/* ]]; then
        process_scope=$(readlink /proc/self/ns/pid) || {
            _log_error 'Linux installation custody requires procfs PID namespace identity'; exit 3;
        }
        [[ "$process_scope" =~ ^pid:\[[0-9]+\]$ ]] || exit 3
    fi
    [[ ${#sources[@]} -eq ${#_INSTALL_NAMES[@]} && ${#sources[@]} -gt 0 ]] || exit 1
    for path in "${sources[@]}"; do
        [[ -f "$path" && ! -L "$path" && -s "$path" ]] || exit 1
        hash=$(_file_sha256 "$path") || exit 1
        [[ "$hash" =~ ^[0-9a-fA-F]{64}$ ]] || exit 1
        size=$(wc -c < "$path" | tr -d '[:space:]') || exit 1
        [[ "$size" =~ ^[1-9][0-9]*$ ]] || exit 1
        hashes+=("$hash"); sizes+=("$size")
    done
    if [[ -L "$dest_dir" ]]; then
        # A symlinked bin dir (dotfile managers) is the user's choice: install
        # into the directory it resolves to rather than through the link.
        # Empty CDPATH: a relative --dir must not be resolved via CDPATH,
        # which also makes cd print the directory into this capture.
        dest_dir=$(CDPATH='' cd -P -- "$dest_dir" 2>/dev/null && pwd -P) || {
            _log_error "Install directory is a dangling or unusable symlink: $original_dir"; exit 1;
        }
    fi
    mkdir -p -- "$dest_dir" || exit 1
    dest_dir=$(CDPATH='' cd -P -- "$dest_dir" && pwd -P) || exit 1
    if ! directory_identity=$(_install_lock_identity "$dest_dir"); then
        _log_error "stat cannot identify the installation directory; refusing unprotected replacement: $dest_dir"
        exit 3
    fi
    install_lock="$dest_dir/.dsr-install.lock"
    lock_owner="pid=$writer_pid tool=$TOOL_NAME token=$RANDOM-$RANDOM-$RANDOM"
    _finish_family_transaction() {
        local status=$? restore_index restore_name current_record failed=false outcome=rolled-back
        trap - EXIT
        # Keep ownership through restoration even if the caller repeats TERM.
        trap '' HUP INT TERM
        if $lock_held; then
            if [[ -z "$owner_identity" ]]; then
                # Setup failed before a complete owner record. Remove only an
                # empty directory whose identity is still ours; never recurse.
                if [[ -n "$lock_identity" && ! -L "$install_lock" &&
                      "$(_install_lock_identity "$install_lock")" == "$lock_identity" ]]; then
                    rmdir -- "$install_lock" 2>/dev/null ||
                        _log_error "Incomplete installation lock retained for inspection: $install_lock"
                fi
                exit "$status"
            fi
            if ! _install_lock_owned "$install_lock" "$lock_identity" "$owner_identity" "$lock_owner"; then
                _log_error "Installation lock ownership changed; refusing uncoordinated rollback or cleanup"
                [[ -z "$stage" ]] || _log_error "Recovery files retained at: $stage"
                exit 1
            fi
        fi
        if ! $committed; then
            # Inspect the complete family before restoring its first member.
            # An independent edit must not be overwritten by our error handler.
            restore_index=0
            while ((touched > 0 && restore_index < ${#originals[@]})); do
                restore_name="${_INSTALL_NAMES[$restore_index]}"
                current_record=$(_install_destination_record "$dest_dir/$restore_name") || failed=true
                if [[ "$current_record" != "${originals[$restore_index]}" &&
                      "$current_record" != "${candidates[$restore_index]}" &&
                      "$current_record" != "${restorations[$restore_index]}" ]]; then failed=true; fi
                if [[ "${originals[$restore_index]}" != null ]]; then
                    [[ "$(_install_file_record "$stage/old/$restore_name")" == "${backups[$restore_index]}" &&
                       "$(_install_file_record "$stage/restore/$restore_name")" == "${restorations[$restore_index]}" ]] || failed=true
                fi
                restore_index=$((restore_index + 1))
            done
            if $failed; then
                _log_error "Install destination changed outside this transaction; preserving family and recovery evidence: $stage"
                exit 1
            fi
            restore_index=$((touched - 1))
            while ((restore_index >= 0)); do
                restore_name="${_INSTALL_NAMES[$restore_index]}"
                current_record=$(_install_destination_record "$dest_dir/$restore_name") || { failed=true; break; }
                if [[ "$current_record" == "${originals[$restore_index]}" ||
                      "$current_record" == "${restorations[$restore_index]}" ]]; then
                    restore_index=$((restore_index - 1))
                    continue
                elif [[ "$current_record" != "${candidates[$restore_index]}" ]]; then
                    failed=true
                    break
                elif [[ "${previous[$restore_index]}" == true ]]; then
                    [[ "$(_install_file_record "$stage/restore/$restore_name")" == "${restorations[$restore_index]}" ]] || { failed=true; break; }
                    mv -f -- "$stage/restore/$restore_name" "$dest_dir/$restore_name" || { failed=true; break; }
                else
                    rm -f -- "$dest_dir/$restore_name" || { failed=true; break; }
                fi
                restore_index=$((restore_index - 1))
            done
        else
            outcome=committed
        fi
        if $failed; then
            _log_error "Could not restore every previous binary; recovery files and installation lock retained: $stage"
            exit 1
        fi
        if [[ -n "$journal_hash" ]]; then
            # A complete marker is written only after all replacements or all
            # restorations finished. It makes cleanup interruption recoverable.
            if ! (umask 077; printf '%s\n%s\n' "$outcome" "$journal_hash" > "$install_lock/completion.pending") ||
               ! mv -- "$install_lock/completion.pending" "$install_lock/completion"; then
                _log_error "Cannot record completed installation; recovery evidence retained: $stage"
                exit 1
            fi
        fi
        if $lock_held; then
            if ! _install_lock_owned "$install_lock" "$lock_identity" "$owner_identity" "$lock_owner"; then
                _log_error "Could not release the owned installation lock; inspect before retrying: $install_lock"
                exit 1
            fi
            if [[ -n "$stage" ]]; then
                # Retire the common lock atomically before deleting backups.
                # A killed cleanup cannot strand an active lock with no journal.
                if [[ "$(_install_lock_identity "$stage")" != "$stage_identity" || -e "$stage/lock" || -L "$stage/lock" ]] ||
                   ! mv -- "$install_lock" "$stage/lock" ||
                   ! _install_lock_owned "$stage/lock" "$lock_identity" "$owner_identity" "$lock_owner"; then
                    _log_error "Cannot retire installation custody; evidence retained: $stage"
                    exit 1
                fi
            elif ! rm -- "$install_lock/owner" || ! rmdir -- "$install_lock"; then
                _log_error "Could not release the owned installation lock; inspect before retrying: $install_lock"
                exit 1
            fi
        fi
        [[ -z "$stage" ]] || rm -rf -- "$stage"
        exit "$status"
    }
    trap _finish_family_transaction EXIT
    # Record signals during the few setup commands, then handle cancellation
    # once ownership can be released safely. Do not silently ignore a signal.
    trap 'lock_setup_interrupted=true' HUP INT TERM
    # One backend for every installer/PATH. Portable mkdir provides exclusion
    # on macOS and FreeBSD too; a flock fallback would split the writer set.
    if ! (umask 077; mkdir -- "$install_lock") 2>/dev/null; then
        if [[ ! -e "$install_lock" && ! -L "$install_lock" ]]; then
            _log_error "Cannot create the installation lock; check directory permissions and free space: $dest_dir"
            exit 1
        fi
        _log_error "Installation directory is busy or its lock needs inspection: $install_lock"
        _log_info 'Wait for the active installer to finish, then retry.'
        _log_info 'If it stopped unexpectedly, run this installer with --recover --yes and the same --dir; --yes alone does not steal locks.'
        exit 2
    fi
    lock_held=true
    lock_identity=$(_install_lock_identity "$install_lock") || {
        _log_error "Cannot identify the new installation lock; inspect before retrying: $install_lock"
        exit 1
    }
    (umask 077; printf '%s\n' "$lock_owner" > "$install_lock/owner") || exit 1
    owner_identity=$(_install_lock_identity "$install_lock/owner") || {
        _log_error "Cannot identify the installation lock owner; inspect before retrying: $install_lock"
        exit 1
    }
    trap 'exit 5' HUP INT TERM
    $lock_setup_interrupted && exit 5
    _install_lock_owned "$install_lock" "$lock_identity" "$owner_identity" "$lock_owner" || exit 1
    # Foreground consent is bound to the exact observed files. Recheck it
    # under the common writer lock before staging any replacement.
    for name in "${_INSTALL_NAMES[@]}"; do
        path="$dest_dir/$name"
        [[ ! -L "$path" && ( ! -e "$path" || -f "$path" ) ]] || {
            _log_error "Refusing a linked or non-regular install destination: $path"; exit 1;
        }
        if [[ -f "$path" ]]; then
            original_identity=$(_install_lock_identity "$path") || exit 1
            case "$original_identities" in
                *"|$original_identity|"*) _log_error 'Two installed family members share an inode; separate them before replacement'; exit 4 ;;
            esac
            original_identities+="$original_identity|"
        fi
        if [[ -f "$path" ]] && ! $_AUTO_YES; then
            if [[ "${_INSTALL_APPROVALS[$index]:-}" != "$(_install_file_record "$path")" ]]; then
                _log_error "Install destination changed after overwrite consent; retry: $path"
                exit 1
            fi
        elif ! $_AUTO_YES && [[ "${_INSTALL_APPROVALS[$index]:-absent}" != absent ]]; then
            _log_error "Install destination disappeared after overwrite consent; retry: $path"
            exit 1
        fi
        index=$((index + 1))
    done
    stage=$(umask 077; mktemp -d "$dest_dir/.${BINARY_NAME}.install.XXXXXXXX") || exit 1
    stage_identity=$(_install_lock_identity "$stage") || exit 1
    (umask 077; mkdir -- "$stage/new" "$stage/old" "$stage/restore") || exit 1
    # Unix paths are bytes and need not be UTF-8. Hex keeps journal JSON valid
    # and binds their exact spelling without requiring Python during install.
    directory_hex=$(printf '%s' "$dest_dir" | od -An -tx1 | tr -d '[:space:]') || exit 1
    journal='{"schema_version":1,"tool":"'"$(_json_escape_str "$TOOL_NAME")"'","repository":"'"$(_json_escape_str "$REPO")"'","platform":"'"$(_json_escape_str "$_INSTALL_PLATFORM")"'","directory_hex":"'"$directory_hex"'","directory_identity":"'"$directory_identity"'","lock_identity":"'"$lock_identity"'","owner_identity":"'"$owner_identity"'","owner":"'"$(_json_escape_str "$lock_owner")"'","process_group":'"$writer_pid"',"process_scope":"'"$process_scope"'","hostname_hex":"'"$writer_host_hex"'","stage":"'"${stage##*/}"'","stage_identity":"'"$stage_identity"'","members":['
    index=0
    for name in "${_INSTALL_NAMES[@]}"; do
        cp -- "${sources[$index]}" "$stage/new/$name" || exit 1
        chmod 755 "$stage/new/$name" || exit 1
        [[ "$(_file_sha256 "$stage/new/$name")" == "${hashes[$index]}" ]] || exit 1
        _installer_validate_executable "$stage/new/$name" "$_INSTALL_PLATFORM" || exit $?
        candidate_record=$(_install_file_record "$stage/new/$name") || exit 1
        path="$dest_dir/$name"
        if [[ -f "$path" && ! -L "$path" ]]; then
            original_record=$(_install_file_record "$path") || exit 1
            cp -p -- "$path" "$stage/old/$name" || exit 1
            previous_hash=$(_file_sha256 "$path") || exit 1
            backup_hash=$(_file_sha256 "$stage/old/$name") || exit 1
            [[ "$previous_hash" == "$backup_hash" ]] || exit 1
            backup_record=$(_install_file_record "$stage/old/$name") || exit 1
            cp -p -- "$stage/old/$name" "$stage/restore/$name" || exit 1
            rollback_record=$(_install_file_record "$stage/restore/$name") || exit 1
            [[ "$(_install_file_record "$path")" == "$original_record" &&
               "${original_record#*,\"mode\":}" == "${backup_record#*,\"mode\":}" &&
               "${original_record#*,\"mode\":}" == "${rollback_record#*,\"mode\":}" ]] || exit 1
            previous+=(true)
        elif [[ ! -e "$path" && ! -L "$path" ]]; then
            original_record=null; backup_record=null; rollback_record=null
            previous+=(false)
        else
            exit 1
        fi
        receipt+="$separator"'{"name":"'"$(_json_escape_str "$name")"'","path":"'"$(_json_escape_str "$original_dir/$name")"'","sha256":"'"${hashes[$index]}"'","size_bytes":'"${sizes[$index]}"'}'
        journal+="$separator"'{"name":"'"$name"'","original":'"$original_record"',"backup":'"$backup_record"',"rollback":'"$rollback_record"',"candidate":'"$candidate_record"'}'
        originals+=("$original_record"); candidates+=("$candidate_record"); backups+=("$backup_record"); restorations+=("$rollback_record")
        separator=,
        index=$((index + 1))
    done
    receipt+=']'
    journal+=']}'
    (umask 077; printf '%s\n' "$journal" > "$install_lock/journal.pending") || exit 1
    mv -- "$install_lock/journal.pending" "$install_lock/journal.json" || exit 1
    journal_hash=$(_file_sha256 "$install_lock/journal.json") || exit 1
    index=0
    for name in "${_INSTALL_NAMES[@]}"; do
        [[ "$(_install_destination_record "$dest_dir/$name")" == "${originals[$index]}" ]] || {
            _log_error "Install destination changed during staging; preserving it: $name"; exit 1;
        }
        index=$((index + 1))
    done
    index=0
    for name in "${_INSTALL_NAMES[@]}"; do
        _install_lock_owned "$install_lock" "$lock_identity" "$owner_identity" "$lock_owner" || exit 1
        path="$dest_dir/$name"
        [[ "$(_install_destination_record "$path")" == "${originals[$index]}" ]] || {
            _log_error "Install destination changed before replacement; preserving it: $name"; exit 1;
        }
        touched=$((index + 1))
        mv -f -- "$stage/new/$name" "$path" || exit 1
        index=$((index + 1))
    done
    index=0
    for name in "${_INSTALL_NAMES[@]}"; do
        path="$dest_dir/$name"
        [[ -f "$path" && ! -L "$path" && -x "$path" ]] || exit 1
        [[ "$(_file_sha256 "$path")" == "${hashes[$index]}" ]] || exit 1
        index=$((index + 1))
    done
    committed=true
    for name in "${_INSTALL_NAMES[@]}"; do _log_ok "Installed to: $original_dir/$name"; done
    if [[ ":$PATH:" != *":$dest_dir:"* && ":$PATH:" != *":$original_dir:"* ]]; then
        _log_warn "$dest_dir is not in your PATH"
        _log_info "Add to your shell config:"
        _log_info "  export PATH=\"\$PATH:$dest_dir\""
    fi

    printf '%s\n' "$receipt"
    exit $?
}

_install_binaries() {
    local receipt receipt_file family_pid='' previous_traps interrupted=false status=0 monitor=false cancel_guard=''
    local name path approval response
    _INSTALL_APPROVALS=()
    # A job-control process group must not read a foreground terminal. Obtain
    # consent here, then let the writer validate the exact files under lock.
    if ! $_AUTO_YES; then
        for name in "${_INSTALL_NAMES[@]}"; do
            path="$_INSTALL_DIR/$name"
            if [[ -f "$path" && ! -L "$path" ]]; then
                if $_NON_INTERACTIVE; then
                    _log_error "Binary already exists at $path"
                    _log_info 'Use --yes to overwrite or remove it manually'
                    return 1
                fi
                approval=$(_install_file_record "$path") || return 1
                _log_warn "Binary already exists: $path"
                response=''
                printf 'Overwrite? [y/N] ' >&2
                if ! read -r response < /dev/tty 2>/dev/null; then
                    _log_error "No terminal to confirm replacing $path; re-run with --yes"
                    return 1
                fi
                [[ "$response" =~ ^[yY] ]] || { _log_info 'Installation cancelled'; return 1; }
                _INSTALL_APPROVALS+=("$approval")
            elif [[ ! -e "$path" && ! -L "$path" ]]; then
                _INSTALL_APPROVALS+=(absent)
            else
                _log_error "Refusing a linked or non-regular install destination: $path"
                return 1
            fi
        done
    fi
    receipt_file=$(mktemp "$_TEMP_DIR/install-family.XXXXXXXX") || return 1
    previous_traps=$(trap -p HUP INT TERM)
    # Sending TERM to only this installer PID must also stop its transaction.
    # Wait for the child's rollback before restoring the caller's handlers.
    trap 'interrupted=true; if [[ -n "$family_pid" ]]; then kill -TERM -- "-$family_pid" 2>/dev/null || true; fi' HUP INT TERM
    case $- in *m*) monitor=true ;; esac
    set -m
    _install_family_transaction "$_INSTALL_DIR" "$receipt_file.writer" "${_INSTALL_PATHS[@]}" > "$receipt_file" &
    family_pid=$!
    $monitor || set +m
    if ! (umask 077; set -C; printf '%s\n' "$family_pid" > "$receipt_file.writer"); then
        kill -TERM -- "-$family_pid" 2>/dev/null || true
        interrupted=true
    fi
    if $interrupted; then kill -TERM -- "-$family_pid" 2>/dev/null || true; fi
    wait "$family_pid" || status=$?
    if $interrupted; then
        trap '' HUP INT TERM
        # Give ordinary rollback time to finish, but do not let a utility
        # that ignores TERM defer the writer's trap indefinitely. A forced
        # stop leaves the immutable journal for explicit recovery.
        set -m
        (
            set +m
            timer=''
            _install_stop_cancel_guard() {
                trap '' HUP INT TERM
                [[ -z "$timer" ]] || kill "$timer" 2>/dev/null || true
                [[ -z "$timer" ]] || wait "$timer" 2>/dev/null || true
                exit 0
            }
            trap _install_stop_cancel_guard HUP INT TERM
            sleep 5 & timer=$!
            wait "$timer" || exit 0
            if kill -0 "$family_pid" 2>/dev/null; then
                kill -KILL -- "-$family_pid" 2>/dev/null || true
            fi
        ) &
        cancel_guard=$!
        $monitor || set +m
        wait "$family_pid" 2>/dev/null || true
        kill -TERM "$cancel_guard" 2>/dev/null || true
        wait "$cancel_guard" 2>/dev/null || true
        status=5
    fi
    trap - HUP INT TERM
    if [[ -n "$previous_traps" ]]; then eval "$previous_traps"; fi
    ((status == 0)) || return "$status"
    receipt=$(cat -- "$receipt_file") || return 1
    _INSTALLED_BINARIES_JSON="$receipt"
}

# Recovery is an explicit local operation, before release discovery or source
# execution. Python supplies directory-relative, no-follow operations and a
# kernel lease between recoverers; ordinary installation remains Bash-only.
_recover_installation() {
    command -v python3 >/dev/null 2>&1 || { _log_error 'Python 3 is required for --recover'; return 3; }
    local result status=0
    result=$(python3 -I - "$_INSTALL_DIR" "$TOOL_NAME" "$REPO" "$_INSTALL_PLATFORM" "$BINARY_NAME" "$_JSON_MODE" "${_INSTALL_NAMES[@]}" <<'DSR_INSTALL_RECOVERY_PY'
import hashlib
import json
import os
import re
import signal
import socket
import stat
import subprocess
import sys
import uuid

os.umask(0o077)
directory, tool, repository, platform, primary, json_mode = sys.argv[1:7]
names = sys.argv[7:]
descriptors = []
chain = []
leases = []
changed = []
evidence = ''
outcome = 'refused'
recovered = False


class Refusal(Exception):
    def __init__(self, message, code=4):
        super().__init__(message)
        self.code = code


def need(condition, message, code=4):
    if not condition:
        raise Refusal(message, code)


def stop(signum, frame):
    raise Refusal('Recovery interrupted; retained evidence permits another --recover --yes', 5)


def held(fd):
    descriptors.append(fd)
    return fd


def identity(info):
    return '%s:%s' % (info.st_dev, info.st_ino)


def fingerprint(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid,
            info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def entry(parent, name):
    try:
        return os.stat(name, dir_fd=parent, follow_symlinks=False)
    except FileNotFoundError:
        return None


def open_directory(parent, name, expected=None, private=False):
    fd = held(os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent))
    info = os.fstat(fd)
    need(expected is None or identity(info) == expected, 'Directory identity changed: ' + name)
    if private:
        need(info.st_uid == os.geteuid() and not stat.S_IMODE(info.st_mode) & 0o022,
             'Recovery directory has unsafe ownership or permissions: ' + name)
    chain.append((parent, name, fd, identity(info)))
    return fd


def custody():
    for parent, name, fd, expected in chain:
        info = entry(parent, name)
        need(info is not None and stat.S_ISDIR(info.st_mode) and
             identity(info) == expected == identity(os.fstat(fd)),
             'Recovery directory moved or was replaced: ' + name)
    for parent, name, fd, expected in leases:
        info = entry(parent, name)
        need(info is not None and stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and
             info.st_uid == os.geteuid() and stat.S_IMODE(info.st_mode) == 0o600 and
             identity(info) == expected == identity(os.fstat(fd)),
             'Recovery lease owner was replaced or changed')


def read_file(parent, name, limit, private=False):
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    try:
        before = os.fstat(fd)
        need(stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and before.st_size <= limit,
             'Invalid recovery metadata: ' + name)
        if private:
            need(before.st_uid == os.geteuid() and stat.S_IMODE(before.st_mode) == 0o600,
                 'Recovery metadata has unsafe ownership or permissions: ' + name)
        chunks = []
        remaining = limit + 1
        while remaining:
            chunk = os.read(fd, min(65536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        value = b''.join(chunks)
        need(len(value) <= limit and fingerprint(before) == fingerprint(os.fstat(fd)) and
             fingerprint(before) == fingerprint(os.stat(name, dir_fd=parent, follow_symlinks=False)),
             'Recovery metadata changed during inspection: ' + name)
        return value, identity(before)
    finally:
        os.close(fd)


def file_record(parent, name):
    if entry(parent, name) is None:
        return None
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    try:
        before = os.fstat(fd)
        need(stat.S_ISREG(before.st_mode), 'Linked or non-regular family member: ' + name)
        digest = hashlib.sha256()
        while True:
            chunk = os.read(fd, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
        need(fingerprint(before) == fingerprint(os.fstat(fd)) and
             fingerprint(before) == fingerprint(os.stat(name, dir_fd=parent, follow_symlinks=False)),
             'Family member changed during inspection: ' + name)
        return {'identity': identity(before), 'nlink': before.st_nlink, 'mode': stat.S_IMODE(before.st_mode),
                'uid': before.st_uid, 'gid': before.st_gid, 'size': before.st_size, 'sha256': digest.hexdigest()}
    finally:
        os.close(fd)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        need(key not in result, 'Duplicate recovery journal field')
        result[key] = value
    return result


def record_valid(value):
    return (isinstance(value, dict) and set(value) == {'identity', 'nlink', 'mode', 'uid', 'gid', 'size', 'sha256'} and
            isinstance(value['identity'], str) and re.fullmatch(r'[0-9]+:[0-9]+', value['identity']) and
            isinstance(value['sha256'], str) and re.fullmatch(r'[0-9a-f]{64}', value['sha256']) and
            all(type(value[key]) is int and value[key] >= 0 for key in ('nlink', 'mode', 'uid', 'gid', 'size')) and
            value['nlink'] > 0 and value['mode'] <= 0o7777)


def contents(value):
    return {key: value[key] for key in ('mode', 'uid', 'gid', 'size', 'sha256')}


def inactive_group(group):
    try:
        os.killpg(group, 0)
    except ProcessLookupError:
        return
    except PermissionError:
        raise Refusal('The original installation process group is still active or inaccessible', 2)
    # Zombies cannot perform a delayed rename. A complete ps census lets
    # recovery work even when an init process is slow to reap killed children.
    observed = subprocess.run(['ps', '-axo', 'pid=,pgid=,stat='], stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, text=True, timeout=5)
    need(observed.returncode == 0, 'Cannot inspect the original installation process group', 2)
    members = []
    for line in observed.stdout.splitlines():
        fields = line.split()
        need(len(fields) == 3 and fields[0].isdigit() and fields[1].isdigit() and fields[2],
             'Incomplete process observation; installation recovery withheld', 2)
        if int(fields[1]) == group:
            members.append(fields[2])
    need(members and all(value.startswith('Z') for value in members),
         'The original installation writer or a descendant is still active; wait before recovery', 2)


def run():
    global directory, evidence, outcome, recovered
    try:
        import fcntl
    except ImportError:
        raise Refusal('Installation recovery requires Unix Python 3 with fcntl', 3)
    directory = os.path.realpath(directory)
    need(os.path.isabs(directory) and os.path.isdir(directory), 'Recovery requires an existing installation directory')
    parent = held(os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW))
    for component in directory.split('/')[1:]:
        if component:
            parent = open_directory(parent, component)
    prefix = parent
    guard_name = '.dsr-install.lock'
    if entry(prefix, guard_name) is None:
        outcome = 'nothing-to-recover'
        return []
    guard = open_directory(prefix, guard_name, private=True)
    guard_identity = identity(os.fstat(guard))
    evidence = directory + '/' + guard_name
    owner, owner_identity = read_file(guard, 'owner', 4096, private=True)
    raw, journal_identity = read_file(guard, 'journal.json', 64 * 1024 * 1024, private=True)
    journal = json.loads(raw, object_pairs_hook=unique_object)
    journal_hash = hashlib.sha256(raw).hexdigest()
    keys = {'schema_version', 'tool', 'repository', 'platform', 'directory_hex', 'directory_identity', 'lock_identity',
            'owner_identity', 'owner', 'process_group', 'process_scope', 'hostname_hex', 'stage', 'stage_identity', 'members'}
    need(isinstance(journal, dict) and set(journal) == keys and type(journal['schema_version']) is int and
         journal['schema_version'] == 1, 'Unsupported or incomplete installation journal')
    need(all(isinstance(journal[key], str) and re.fullmatch(r'[0-9]+:[0-9]+', journal[key])
             for key in ('directory_identity', 'lock_identity', 'owner_identity', 'stage_identity')),
         'Invalid installation directory or owner identity')
    need(journal['tool'] == tool and journal['repository'] == repository and journal['platform'] == platform and
         journal['directory_hex'] == os.fsencode(directory).hex() and journal['directory_identity'] == identity(os.fstat(prefix)) and
         journal['lock_identity'] == guard_identity and journal['owner_identity'] == owner_identity and
         isinstance(journal['owner'], str) and owner == (journal['owner'] + '\n').encode() and
         journal['hostname_hex'] == os.fsencode(socket.gethostname()).hex(), 'Installation journal belongs to another directory, tool, platform, host or owner')
    group = journal['process_group']
    need(type(group) is int and 1 < group <= 2147483647 and
         re.fullmatch(r'pid=' + str(group) + r' tool=' + re.escape(tool) + r' token=[0-9]+-[0-9]+-[0-9]+', journal['owner']),
         'Invalid installation writer identity')
    scope = os.readlink('/proc/self/ns/pid') if platform.startswith('linux/') else 'global'
    need(journal['process_scope'] == scope, 'Recovery must run in the original installation PID namespace')
    inactive_group(group)
    stage_name = journal['stage']
    need(isinstance(stage_name, str) and re.fullmatch(r'\.' + re.escape(primary) + r'\.install\.[A-Za-z0-9]{8}', stage_name),
         'Unsafe installation stage name')
    completed = None
    completion_record = None
    if entry(guard, 'completion') is not None:
        completion_record = read_file(guard, 'completion', 256, private=True)
        value = completion_record[0]
        for phase in ('committed', 'rolled-back'):
            if value == (phase + '\n' + journal_hash + '\n').encode():
                completed = phase
        need(completed is not None, 'Completion marker contradicts the installation journal')
    original_stage = entry(prefix, stage_name)
    archived_stage = entry(guard, 'evidence')
    need((original_stage is None) != (archived_stage is None), 'Installation evidence is missing or ambiguous')
    stage_parent, stage_entry = (prefix, stage_name) if original_stage is not None else (guard, 'evidence')
    stage = open_directory(stage_parent, stage_entry, journal['stage_identity'], private=True)
    need(set(os.listdir(stage)) == {'new', 'old', 'restore'}, 'Installation stage contains unrecognized resources')
    new = open_directory(stage, 'new', private=True)
    old = open_directory(stage, 'old', private=True)
    restore = open_directory(stage, 'restore', private=True)
    members = journal['members']
    need(isinstance(members, list) and len(members) == len(names) and
         all(isinstance(member, dict) and set(member) == {'name', 'original', 'backup', 'rollback', 'candidate'} for member in members) and
         [member['name'] for member in members] == names and len(set(names)) == len(names),
         'Journal executable family differs from this installer')
    pins = set()
    for member in members:
        need(re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._+-]*', member['name']) and '..' not in member['name'], 'Unsafe executable name')
        candidate = member['candidate']
        need(record_valid(candidate) and candidate['nlink'] == 1 and candidate['mode'] == 0o755,
             'Invalid candidate executable record')
        if member['original'] is None:
            need(member['backup'] is None and member['rollback'] is None, 'Absent executable has unexpected backup records')
        else:
            need(all(record_valid(member[key]) for key in ('original', 'backup', 'rollback')) and
                 member['backup']['nlink'] == member['rollback']['nlink'] == 1 and
                 contents(member['original']) == contents(member['backup']) == contents(member['rollback']),
                 'Backup records contradict the original executable')
        for key in ('original', 'candidate', 'backup', 'rollback'):
            value = member[key]
            if value is not None:
                need(value['identity'] not in pins, 'Two staged executable records share an identity')
                pins.add(value['identity'])

    recovery_receipt = json.dumps({'schema_version': 1, 'outcome': 'committed' if completed == 'committed' else 'rolled-back',
                                  'journal_sha256': journal_hash}, sort_keys=True).encode() + b'\n'

    def inspect():
        custody()
        need(set(os.listdir(guard)) <= {'owner', 'journal.json', 'completion', 'completion.pending',
                                       'evidence', 'recovery-result.json', 'recovery-result.pending'},
             'Installation lock contains unrecognized resources')
        need(read_file(guard, 'owner', 4096, private=True) == (owner, owner_identity) and
             read_file(guard, 'journal.json', 64 * 1024 * 1024, private=True) == (raw, journal_identity),
             'Installation owner or journal changed during recovery')
        observed_completion = read_file(guard, 'completion', 256, private=True) if entry(guard, 'completion') is not None else None
        need(observed_completion == completion_record, 'Installation completion marker changed during recovery')
        if entry(guard, 'completion.pending') is not None:
            pending, _ = read_file(guard, 'completion.pending', 256, private=True)
            need(any((phase + '\n' + journal_hash + '\n').encode().startswith(pending) for phase in ('committed', 'rolled-back')),
                 'Unexpected pending installation completion record')
        if entry(guard, 'recovery-result.json') is not None:
            need(read_file(guard, 'recovery-result.json', 4096, private=True)[0] == recovery_receipt,
                 'Conflicting prior recovery receipt')
        if entry(guard, 'recovery-result.pending') is not None:
            pending, _ = read_file(guard, 'recovery-result.pending', 4096, private=True)
            need(recovery_receipt.startswith(pending), 'Unexpected pending recovery receipt')
        for fd in (new, old, restore):
            need(set(os.listdir(fd)) <= set(names), 'Staged family contains unrelated files')
        states = []
        for member in members:
            name = member['name']
            current = file_record(prefix, name)
            if current == member['original']:
                state = 'original'
            elif current == member['candidate']:
                state = 'candidate'
            elif member['rollback'] is not None and current == member['rollback']:
                state = 'rollback'
            else:
                raise Refusal('Installed file changed outside this transaction; preserved: ' + name)
            staged = file_record(new, name)
            need(staged is None or staged == member['candidate'], 'Candidate evidence changed: ' + name)
            need(not (state == 'original' and current is not None and staged is None), 'Untouched member lost its candidate evidence: ' + name)
            need(file_record(old, name) == member['backup'], 'Original backup changed or disappeared: ' + name)
            replacement = file_record(restore, name)
            need(replacement == member['rollback'] or
                 (replacement is None and state == 'rollback'), 'Restoration copy changed or disappeared: ' + name)
            if completed == 'committed':
                need(state == 'candidate', 'Completed installation no longer matches its verified family')
            elif completed == 'rolled-back':
                need(state != 'candidate', 'Completed rollback no longer matches its previous family')
            states.append(state)
        inactive_group(group)
        return states

    inspect()
    # The journal pins this immutable file's inode. Recoverers cannot split
    # their exclusion by replacing a separate, unbound lease pathname.
    lease = held(os.open('owner', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=guard))
    info = os.fstat(lease)
    need(stat.S_ISREG(info.st_mode) and info.st_nlink == 1 and info.st_uid == os.geteuid() and
         stat.S_IMODE(info.st_mode) == 0o600 and identity(info) == owner_identity, 'Invalid installation recovery lease')
    try:
        fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise Refusal('Another recovery is active for this installation directory', 2)
    leases.append((guard, 'owner', lease, owner_identity))
    states = inspect()
    if completed != 'committed':
        for member, state in zip(members, states):
            if state != 'candidate':
                continue
            custody()
            inactive_group(group)
            name = member['name']
            need(file_record(prefix, name) == member['candidate'] and file_record(old, name) == member['backup'],
                 'Recovery inputs changed before restoring ' + name)
            if member['original'] is None:
                os.unlink(name, dir_fd=prefix)
            else:
                need(file_record(restore, name) == member['rollback'], 'Restoration copy changed: ' + name)
                os.replace(name, name, src_dir_fd=restore, dst_dir_fd=prefix)
            changed.append(name)
        outcome = 'rolled-back'
    else:
        outcome = 'committed'
    final_states = inspect()
    need(completed == 'committed' or all(state != 'candidate' for state in final_states), 'Recovery did not restore the complete family')
    receipt = recovery_receipt
    if entry(guard, 'recovery-result.json') is not None:
        need(read_file(guard, 'recovery-result.json', 4096, private=True)[0] == receipt, 'Conflicting prior recovery receipt')
    else:
        prior_pending = None
        if entry(guard, 'recovery-result.pending') is not None:
            prior_pending = read_file(guard, 'recovery-result.pending', 4096, private=True)
            need(receipt.startswith(prior_pending[0]), 'Unexpected interrupted recovery receipt')
        flags = os.O_WRONLY | os.O_NOFOLLOW
        if prior_pending is None:
            flags |= os.O_CREAT | os.O_EXCL
        pending = os.open('recovery-result.pending', flags, 0o600, dir_fd=guard)
        try:
            need(prior_pending is None or identity(os.fstat(pending)) == prior_pending[1], 'Pending recovery receipt changed')
            with os.fdopen(pending, 'wb') as stream:
                stream.write(receipt)
                stream.flush()
                os.fsync(stream.fileno())
        except BaseException:
            raise
        os.rename('recovery-result.pending', 'recovery-result.json', src_dir_fd=guard, dst_dir_fd=guard)
    if stage_parent == prefix:
        inspect()
        os.rename(stage_name, 'evidence', src_dir_fd=prefix, dst_dir_fd=guard)
        chain[:] = [(guard, 'evidence', fd, pin) if fd == stage else (parent_fd, name, fd, pin)
                    for parent_fd, name, fd, pin in chain]
    inspect()
    inactive_group(group)
    archive_name = '.dsr-recovered-' + uuid.uuid4().hex
    os.mkdir(archive_name, 0o700, dir_fd=prefix)
    archive = open_directory(prefix, archive_name, private=True)
    custody()
    # The new private archive owns its empty destination. Retiring the common
    # guard is the final operation that touches the installation namespace.
    os.rename(guard_name, 'transaction', src_dir_fd=prefix, dst_dir_fd=archive)
    need(identity(os.stat('transaction', dir_fd=archive, follow_symlinks=False)) == guard_identity,
         'Retired installation lock changed unexpectedly')
    evidence = directory + '/' + archive_name + '/transaction'
    recovered = True
    result = []
    for member in members:
        current = member['candidate'] if outcome == 'committed' else member['original']
        if current is not None:
            result.append({'name': member['name'], 'path': directory + '/' + member['name'],
                           'sha256': current['sha256'], 'size_bytes': current['size']})
    return result


for number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    signal.signal(number, stop)
code = 0
binaries = []
try:
    binaries = run()
    message = 'No active installation transaction' if outcome == 'nothing-to-recover' else 'Installation recovery complete: ' + outcome
except Refusal as error:
    code, message = error.code, str(error)
except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
    code, message = 4, 'Installation recovery refused; retained evidence requires inspection: ' + str(error)
finally:
    for fd in reversed(descriptors):
        os.close(fd)
print('[' + tool + '] ' + message, file=sys.stderr)
if evidence:
    print('[' + tool + '] Recovery evidence: ' + evidence, file=sys.stderr)
if json_mode == 'true':
    print(json.dumps({'tool': tool, 'status': 'success' if code == 0 else 'error', 'message': message,
                      'version': '', 'path': directory, 'action': 'recover', 'binaries': binaries,
                      'recovery': {'outcome': outcome, 'recovered': recovered, 'changed_names': changed, 'evidence_path': evidence}}))
raise SystemExit(code)
DSR_INSTALL_RECOVERY_PY
) || status=$?
    if [[ -n "$result" ]]; then
        printf '%s\n' "$result"
        _JSON_EMITTED=true
    fi
    return "$status"
}

_select_archive_binaries() {
    local directory="$1" name candidates alternate path other use_alternate
    _INSTALL_PATHS=()
    for name in "${_INSTALL_NAMES[@]}"; do
        alternate="$name.exe"
        [[ "$name" != *.exe ]] || alternate="${name%.exe}"
        use_alternate=true
        # Unix permits two explicitly configured binaries named app and
        # app.exe. Neither may borrow the other's exact family member.
        for other in "${_INSTALL_NAMES[@]}"; do
            [[ "$other" != "$alternate" ]] || use_alternate=false
        done
        if [[ "$_INSTALL_PLATFORM" == windows/* ]]; then
            candidates=$(find "$directory" -type f \( -iname "$name" -o -iname "$alternate" \) -print) || return 1
        elif $use_alternate; then
            candidates=$(find "$directory" -type f \( -name "$name" -o -name "$alternate" \) -print) || return 1
        else
            candidates=$(find "$directory" -type f -name "$name" -print) || return 1
        fi
        if [[ -z "$candidates" || "$candidates" == *$'\n'* ]]; then
            _log_error "Archive must contain exactly one matching binary for $name"
            return 1
        fi
        [[ -f "$candidates" && ! -L "$candidates" && -s "$candidates" ]] || return 1
        _installer_validate_executable "$candidates" "$_INSTALL_PLATFORM" || return $?
        for path in ${_INSTALL_PATHS[@]+"${_INSTALL_PATHS[@]}"}; do
            [[ "$path" != "$candidates" ]] || { _log_error "Two executable names select the same archive member"; return 1; }
        done
        _INSTALL_PATHS+=("$candidates")
    done
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
    # Capture the whole walk: `find | grep -q .` lets grep's early exit
    # SIGPIPE find once many links exist, and pipefail then reported "no
    # symlinks".  A failed walk refuses the install rather than passing it.
    local staged_links=""
    if ! staged_links=$(find "$stage_dir" -type l 2>/dev/null) || \
       [[ -n "$staged_links" ]]; then
        rm -rf "$stage_dir" 2>/dev/null || true
        _log_warn "Skill archive contains symbolic links (or could not be scanned); refusing to install"
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
    local reason="$1" ref="${_SOURCE_REF:-}" receipt payload actual installed_path name expected_names member
    if ! $_ALLOW_SOURCE_BUILD || $_OFFLINE_MODE || $_REQUIRE_SIGNATURES; then
        _log_error "Source fallback requires --allow-source-build (or --from-source), online mode, and no --require-signatures"
        return 4
    fi
    # The embedded source engine needs Bash 4 ($BASHPID, ${var,,}); stock
    # macOS /bin/bash is 3.2. Refuse clearly instead of failing mid-build.
    if ((BASH_VERSINFO[0] < 4)); then
        _log_error "Source builds need Bash 4+ (this is $BASH_VERSION); rerun the installer under a newer bash (e.g. Homebrew's bash)"
        return 3
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
    $_INSTALL_TOOLCHAIN && args+=(--install-toolchain)
    [[ -z "$SOURCE_ENTRY" ]] || args+=(--entry "$SOURCE_ENTRY")
    [[ -z "$SOURCE_PACKAGE" ]] || args+=(--package "$SOURCE_PACKAGE")
    for name in "${_INSTALL_NAMES[@]}"; do args+=(--bin "$name"); done
    _KEEP_SOURCE_LOGS=true
    receipt=$(install_source_build "$REPO" "$ref" "$SOURCE_LANGUAGE" "$BINARY_NAME" \
        "$_TEMP_DIR/source-build" "${args[@]}") || return $?
    # Require exactly the selected family and bind the retained primary fields
    # to its member. Compiler output cannot select a different installation set.
    expected_names=$(printf '%s\n' "${_INSTALL_NAMES[@]}" | jq -Rsc 'split("\n")[:-1]') || return 6
    if ! jq -es --arg repo "$REPO" --arg ref "$ref" --arg language "$SOURCE_LANGUAGE" \
        --arg primary "$_PRIMARY_INSTALL_NAME" --argjson expected "$expected_names" '
        length == 1 and (.[0] | type == "object" and .schema_version == 1 and
        .method == "source" and .signed_release == false and
        .repository == $repo and .requested_ref == $ref and .language == $language and
        (.source_commit | type == "string" and test("^([0-9a-f]{40}|[0-9a-f]{64})$")) and
        (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
        (.size_bytes | type == "number" and floor == . and . > 0) and
        (.compiler | type == "string" and length > 0) and (.path | type == "string") and
        (.binaries | type == "array" and length == ($expected | length) and
            (map(.name) | sort) == ($expected | sort) and
            all(.[]; (.path | type == "string" and length > 0) and
                (.sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
                (.size_bytes | type == "number" and floor == . and . > 0))) and
        (. as $receipt | any(.binaries[]; .name == $primary and
            .path == $receipt.path and .sha256 == $receipt.sha256 and
            .size_bytes == $receipt.size_bytes)))
    ' <<< "$receipt" >/dev/null 2>&1; then
        _log_error "Invalid source build receipt"
        return 6
    fi
    _INSTALL_PATHS=()
    for name in "${_INSTALL_NAMES[@]}"; do
        member=$(jq -c --arg name "$name" '.binaries[] | select(.name == $name)' <<< "$receipt") || return 6
        payload=$(jq -r '.path' <<< "$member") || return 6
        [[ "$payload" == "$_TEMP_DIR/source-build/output/"* ]] || return 6
        _isb_path_in_tree "$_TEMP_DIR/source-build/output" "${payload#"$_TEMP_DIR/source-build/output/"}" || return 6
        [[ -f "$payload" && ! -L "$payload" && -s "$payload" && "${payload##*/}" == "$name" ]] || return 6
        actual=$(_file_sha256 "$payload") || return $?
        [[ "$actual" == "$(jq -r '.sha256' <<< "$member")" ]] || return 6
        [[ "$(wc -c < "$payload" | tr -d '[:space:]')" == "$(jq -r '.size_bytes' <<< "$member")" ]] || return 6
        _INSTALL_PATHS+=("$payload")
    done
    # The public receipt must not point at a temporary payload removed on exit.
    _SOURCE_RECEIPT=$(jq -c 'del(.path) | .binaries |= map(del(.path))' <<< "$receipt") || return 6
    _install_binaries || return $?
    installed_path="$_INSTALL_DIR/$_PRIMARY_INSTALL_NAME"
    _KEEP_SOURCE_LOGS=false
    _install_skills
    _log_ok "Installed local source build at commit $(jq -r '.source_commit' <<< "$receipt")"
    _json_result success "Installed from source (not a signed release)" "$_VERSION" "$installed_path"
}

# The header comment is the help text. Run as `curl ... | bash` the script
# has no file to read it back from, so the generator embeds a copy here.
_usage() {
    cat << 'DSR_INSTALLER_HELP'
install.sh - Install cass

Usage:
  curl -sSfL https://raw.githubusercontent.com/Dicklesworthstone/coding_agent_session_search/main/install.sh | bash
  curl -sSfL https://raw.githubusercontent.com/Dicklesworthstone/coding_agent_session_search/main/install.sh | bash -s -- -v 1.2.3
  curl -sSfL https://raw.githubusercontent.com/Dicklesworthstone/coding_agent_session_search/main/install.sh | bash -s -- --json

Options:
  -v, --version VERSION    Install specific version, e.g. 1.2.3 or v1.2.3 (default: latest)
  -d, --dir DIR            Installation directory (default: ~/.local/bin)
  -y, --yes                Replace an existing binary without asking
  --recover               With --yes: recover a stopped installation (Python 3 required)
  --mode vibe|safe         vibe (default) also installs agent skills; safe installs
                           only the verified release binary (no skills, no source builds)
  --verify                 Verify checksums (always enabled)
  --require-signatures     Require a configured key and valid minisign signature
  --json                   Output JSON for automation
  --non-interactive        No prompts, fail on missing consent
  --cache-dir DIR          Cache directory (default: ~/.cache/dsr/installers)
  --offline [ARCHIVE]      No network; requires --version and local checksum evidence
  --prefer-gh              Prefer gh release download for private repos
  --from-source            Build source instead of downloading (explicit code-execution consent)
  --allow-source-build     Allow source fallback when discovery/download is unavailable
  --install-toolchain      With source consent: bootstrap a missing compiler for this build
  --source-ref REF         With --from-source: HEAD, full SHA, refs/heads/* or refs/tags/*
  --source-timeout SECONDS  Per-command source-build limit (default: 3600)
  --source-if-stale N       With --allow-source-build: build head if latest is >N commits behind
  --allow-build            Alias for --allow-source-build
  --build-timeout SECONDS   Alias for --source-timeout
  --prefer-source-if-stale  Use --source-if-stale with a default threshold of 10
  --stale-threshold N       Threshold for --prefer-source-if-stale (0 through 999999)
  --no-skills              Skip AI coding agent skill installation
  --libc gnu|musl          Linux build variant to install (default: this system's C library)
  --help                   Show this help

AI Coding Agent Skills:
  The installer automatically installs skills for Claude Code and Codex CLI.
  Skills teach AI agents about the tool's commands, workflows, and best practices.
  Use --no-skills to skip skill installation.

Safety:
  - Never overwrites without asking (unless --yes)
  - Verifies checksums by default
  - Supports offline installation from cached archives
  - Caches downloads for future offline use
  - Source builds are opt-in, never signed releases, and never cached as releases
  - --yes permits replacement only; it does not authorize source execution
DSR_INSTALLER_HELP
}

# Main installation function
main() {
    local prefer_stale=false stale_threshold=10 stale_threshold_set=false
    local install_mode=vibe
    local stale_threshold_pattern='^(0|[1-9][0-9]{0,5})$'
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -v|--version)
                [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || { _log_error "$1 requires a version"; return 4; }
                _VERSION="$2"
                shift 2
                ;;
            -d|--dir)
                [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || { _log_error "$1 requires a directory"; return 4; }
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
            --recover)
                _RECOVER=true
                shift
                ;;
            --mode)
                [[ $# -ge 2 && ( "$2" == vibe || "$2" == safe ) ]] || {
                    _log_error "--mode requires vibe or safe"
                    return 4
                }
                install_mode="$2"
                shift 2
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
                [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || { _log_error "$1 requires a directory"; return 4; }
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
            --allow-source-build|--allow-build)
                _ALLOW_SOURCE_BUILD=true
                shift
                ;;
            --install-toolchain)
                _INSTALL_TOOLCHAIN=true
                shift
                ;;
            --prefer-source-if-stale)
                prefer_stale=true
                shift
                ;;
            --stale-threshold)
                [[ $# -ge 2 && -n "$2" ]] || { _log_error "$1 requires a number"; return 4; }
                stale_threshold="$2"
                stale_threshold_set=true
                shift 2
                ;;
            --source-ref|--source-timeout|--build-timeout|--source-if-stale)
                [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || { _log_error "$1 requires a value"; return 4; }
                case "$1" in
                    --source-ref) _SOURCE_REF="$2" ;;
                    --source-timeout|--build-timeout) _SOURCE_TIMEOUT="$2" ;;
                    --source-if-stale) _SOURCE_IF_STALE="$2" ;;
                esac
                shift 2
                ;;
            --no-skills)
                _SKIP_SKILLS=true
                shift
                ;;
            --libc)
                [[ $# -ge 2 && ( "$2" == gnu || "$2" == musl ) ]] || {
                    _log_error "--libc requires gnu or musl"
                    return 4
                }
                _LIBC="$2"
                shift 2
                ;;
            --help|-h)
                _usage
                return 0
                ;;
            *)
                _log_error "Unknown option: $1"
                return 4
                ;;
        esac
    done

    if $_RECOVER; then
        if ! $_AUTO_YES || $_FROM_SOURCE || $_ALLOW_SOURCE_BUILD || $_INSTALL_TOOLCHAIN || $_OFFLINE_MODE ||
           $_REQUIRE_SIGNATURES || $_PREFER_GH || $prefer_stale || $stale_threshold_set ||
           [[ -n "$_VERSION$_SOURCE_REF$_SOURCE_IF_STALE$_LIBC" || "$_SOURCE_TIMEOUT" != 3600 ]]; then
            _log_error '--recover requires --yes and cannot be combined with release or source selection'
            return 4
        fi
        # Bash 3.2 uses temporary files for here strings/documents. Establish
        # private readable permissions before family selection and Python's
        # program input, even when the caller's umask removes owner access.
        umask 077 || return 1
    fi

    # Both CLI spellings use the same post-verification freshness path. Never
    # silently resolve conflicting thresholds by whichever flag appeared last.
    if $prefer_stale; then
        [[ "$stale_threshold" =~ $stale_threshold_pattern && -z "$_SOURCE_IF_STALE" ]] || {
            _log_error "--stale-threshold must be 0 through 999999, and not combined with --source-if-stale"
            return 4
        }
        _SOURCE_IF_STALE="$stale_threshold"
    elif $stale_threshold_set; then
        _log_error "--stale-threshold requires --prefer-source-if-stale"
        return 4
    fi
    [[ "$_SOURCE_TIMEOUT" =~ ^[1-9][0-9]{0,4}$ ]] || {
        _log_error "--source-timeout must be 1 through 99999 seconds"
        return 4
    }
    if [[ -n "$_SOURCE_IF_STALE" ]]; then
        if [[ ! "$_SOURCE_IF_STALE" =~ $stale_threshold_pattern || -n "$_VERSION" ]] ||
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
    if $_INSTALL_TOOLCHAIN && ! $_ALLOW_SOURCE_BUILD; then
        _log_error "--install-toolchain requires --from-source or --allow-source-build"
        return 4
    fi
    if [[ -n "$_VERSION" ]] && ! _valid_release_version "$_VERSION"; then
        _log_error "Invalid release version"
        return 4
    fi
    # Release tags are v-prefixed; `-v 1.2.3` names the same release as
    # `-v v1.2.3` (download URL, gh download and offline cache key alike).
    if [[ "$_VERSION" =~ ^[0-9] ]]; then
        _VERSION="v$_VERSION"
    fi
    # Safe mode installs only the verified release binary.
    if [[ "$install_mode" == safe ]]; then
        if $_ALLOW_SOURCE_BUILD; then
            _log_error "--mode safe installs verified releases only; source builds are not allowed"
            return 4
        fi
        _SKIP_SKILLS=true
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
    _select_install_family "$platform" || return $?
    if $_RECOVER; then
        _recover_installation
        return $?
    fi
    if $_FROM_SOURCE; then
        _install_from_source "Explicit --from-source request"
        return $?
    fi
    local install_targets='' fallback_triple target_status=0
    _TARGET_TRIPLE=$(_select_target_triple "${platform%/*}" "${platform#*/}") || target_status=$?
    if ((target_status != 0)); then
        # Status 1 is reserved for an auto-detected, known libc without a
        # compatible configured release and with explicit source consent.
        # Keep version discovery below: a resolved release builds its tag,
        # while unavailable latest discovery follows the existing HEAD policy.
        ((target_status == 1)) && $_ALLOW_SOURCE_BUILD && [[ -z "$_LIBC" ]] || return "$target_status"
    else
        if [[ ! "$_TARGET_TRIPLE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
            _log_error "Unresolved target triple for $platform"
            return 4
        fi
        install_targets="$_TARGET_TRIPLE"
        fallback_triple=$(_fallback_target_triple "${platform%/*}" "${platform#*/}" "$_TARGET_TRIPLE") || return $?
        [[ -z "$fallback_triple" ]] || install_targets+=$'\n'"$fallback_triple"
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
            ((discovery_status == 1)) || return "$discovery_status"
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

    if ((target_status == 1)); then
        _install_from_source "No compatible release target is configured for $platform"
        return $?
    fi

    local format asset_name asset_plan

    # Create temp directory. _TEMP_DIR is a script-scope global so the
    # EXIT trap can still see it after main() returns and locals are
    # popped.
    _TEMP_DIR=$(mktemp -d) || return 1
    _TEMP_DIR=$(cd "$_TEMP_DIR" && pwd -P) || return 1
    trap _cleanup_temp_dir EXIT
    local temp_dir="$_TEMP_DIR"

    local archive_file="" cache_platform="$platform" cached_file acquired=false acquisition_status
    local extract_dir="$temp_dir/extracted"

    # Select the target before cache lookup. Each candidate has its own bytes
    # and sidecars; a failed acquisition cannot leave evidence for another ABI.
    while IFS= read -r _TARGET_TRIPLE; do
        [[ -n "$_TARGET_TRIPLE" ]] || continue
        _log_info "Target: $_TARGET_TRIPLE"
        if $STRICT_RELEASE_CONTRACT; then
            asset_plan=$(_contract_asset_plan "$platform") || return $?
            IFS=$'\t' read -r asset_name format <<< "$asset_plan"
        else
            format=$(_get_archive_format "$platform") || return $?
            asset_name=$(_variant_asset_name "${platform%/*}" "${platform#*/}" "${_VERSION#v}" "$format") || return $?
        fi
        case "$format" in tar.gz|tgz|tar.xz|zip|tar|none|exe) ;; *) return 4 ;; esac
        cache_platform=$(_target_cache_platform "$platform") || return $?
        archive_file="$temp_dir/${_TARGET_TRIPLE}-${TOOL_NAME}.${format}"
        if [[ -n "$_OFFLINE_ARCHIVE" ]]; then
            _copy_local_archive "$_OFFLINE_ARCHIVE" "$archive_file" || return $?
            _log_info "Using offline archive: $_OFFLINE_ARCHIVE"
        elif cached_file=$(_cache_get "$_VERSION" "$cache_platform" "$format" "$asset_name"); then
            _copy_local_archive "$cached_file" "$archive_file" || return $?
        elif $_OFFLINE_MODE; then
            _log_warn "Offline mode: no cached archive for $TOOL_NAME $_VERSION ($_TARGET_TRIPLE)"
            continue
        else
            acquisition_status=0
            _fetch_release_asset "$asset_name" "$archive_file" 2147483648 "$_ALLOW_SOURCE_BUILD" || acquisition_status=$?
            if ((acquisition_status != 0)); then
                ((acquisition_status == 1)) || return "$acquisition_status"
                _log_warn "Release payload unavailable: $asset_name"
                continue
            fi
        fi
        # Integrity failure is final. The fallback policy grants another
        # acquisition attempt only; it never launders rejected release bytes.
        _verify_checksum "$archive_file" "$asset_name" || return $?
        _verify_minisign "$archive_file" "$asset_name" || return $?
        acquired=true
        break
    done <<< "$install_targets"
    if ! $acquired; then
        if $_ALLOW_SOURCE_BUILD; then
            _install_from_source "Release payload unavailable for $platform"
            return $?
        fi
        _log_error "No release payload available for $platform under the configured libc policy"
        _json_result "error" "No release payload available" "$_VERSION" ""
        return 1
    fi
    # Extract
    _log_info "Extracting..."
    _extract_archive "$archive_file" "$extract_dir" "$format" || return $?

    _select_archive_binaries "$extract_dir" || return $?
    # A stale-release policy must NEVER launder a bad artifact into a source
    # build. Check it only after integrity, extraction and binary selection.
    if [[ -n "$_SOURCE_IF_STALE" ]]; then
        local freshness_args=() freshness_status=0
        $_PREFER_GH && freshness_args+=(--prefer-gh)
        _RELEASE_FRESHNESS=$(install_source_freshness "$REPO" "$_VERSION" "$_SOURCE_IF_STALE" \
            "$temp_dir/freshness" ${freshness_args[@]+"${freshness_args[@]}"}) || freshness_status=$?
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
        _cache_put "$archive_file" "$_VERSION" "$cache_platform" "$format" "$asset_name" || \
            _log_warn "Could not cache verified archive"
    fi

    # Install
    _install_binaries || return $?

    # Install AI coding agent skills
    _install_skills

    # Verify installation
    local installed_path="$_INSTALL_DIR/$_PRIMARY_INSTALL_NAME"
    if [[ -f "$installed_path" ]]; then
        local installed_version="unknown" timeout_cmd=""
        if command -v timeout &>/dev/null; then timeout_cmd=timeout
        elif command -v gtimeout &>/dev/null; then timeout_cmd=gtimeout; fi
        if [[ -n "$timeout_cmd" ]]; then
            # Capture, then keep the first line: `| head -1` can SIGPIPE a
            # multi-line --version under pipefail and discard a good answer.
            if installed_version=$("$timeout_cmd" 10 "$installed_path" --version 2>/dev/null) && \
               [[ -n "$installed_version" ]]; then
                installed_version="${installed_version%%$'\n'*}"
            else
                installed_version="unknown"
            fi
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
