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

# Compare semver versions
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

    # Use sort -V for version comparison
    if [[ "$(printf '%s\n%s' "$v2" "$v1" | sort -V | head -1)" == "$v2" ]]; then
        return 0
    else
        return 1
    fi
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

    if [[ "$_TC_NON_INTERACTIVE" == "true" ]]; then
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
    local result
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

    cat << EOF
{
  "toolchain": "rust",
  "installed": $installed,
  "version": "$version",
  "path": "$path",
  "minimum_version": "$TOOLCHAIN_RUST_MIN_VERSION",
  "meets_minimum": $meets_minimum,
  "install_method": "$install_method"
}
EOF
}

# Install Rust via rustup
# Returns: 0 on success, 1 on failure
# shellcheck disable=SC2120  # Optional nightly parameter for future use
_tc_install_rust() {
    local nightly="${1:-false}"

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

    cat << EOF
{
  "toolchain": "go",
  "installed": $installed,
  "version": "$version",
  "path": "$path",
  "goroot": "$goroot",
  "minimum_version": "$TOOLCHAIN_GO_MIN_VERSION",
  "meets_minimum": $meets_minimum
}
EOF
}

# Install Go
# shellcheck disable=SC2120  # Optional version parameter for future use
_tc_install_go() {
    local go_version="${1:-1.23.0}"

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
    if [[ -w /usr/local ]]; then
        tar -C /usr/local -xzf "$temp_file"
    else
        _tc_log_info "Need sudo to install to /usr/local/go"
        sudo tar -C /usr/local -xzf "$temp_file"
    fi

    rm -f "$temp_file"

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

    cat << EOF
{
  "toolchain": "bun",
  "installed": $installed,
  "version": "$version",
  "path": "$path",
  "minimum_version": "$TOOLCHAIN_BUN_MIN_VERSION",
  "meets_minimum": $meets_minimum
}
EOF
}

# Install Bun
_tc_install_bun() {
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

    cat << EOF
{
  "toolchain": "node",
  "installed": $installed,
  "version": "$version",
  "path": "$path",
  "npm_version": "$npm_version",
  "minimum_version": "$TOOLCHAIN_NODE_MIN_VERSION",
  "meets_minimum": $meets_minimum
}
EOF
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
    local rust go bun node
    rust=$(toolchain_detect_rust)
    go=$(toolchain_detect_go)
    bun=$(toolchain_detect_bun)
    node=$(toolchain_detect_node)

    cat << EOF
{
  "platform": "$(_tc_detect_platform)",
  "toolchains": [
    $rust,
    $go,
    $bun,
    $node
  ]
}
EOF
}

# Ensure a toolchain is available (detect + optionally install)
# Usage: toolchain_ensure <toolchain> [--install]
# Returns: 0 if available, 1 if not
toolchain_ensure() {
    local toolchain="${1:-}"
    local auto_install=false
    [[ "${2:-}" == "--install" ]] && auto_install=true

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

# Print human-readable status for all toolchains
toolchain_status() {
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
