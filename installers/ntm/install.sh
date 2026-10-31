#!/usr/bin/env bash
# install.sh - Install ntm
#
# Usage:
#   curl -sSfL https://raw.githubusercontent.com/Dicklesworthstone/ntm/main/install.sh | bash
#   curl -sSfL https://raw.githubusercontent.com/Dicklesworthstone/ntm/main/install.sh | bash -s -- -v 1.2.3
#   curl -sSfL https://raw.githubusercontent.com/Dicklesworthstone/ntm/main/install.sh | bash -s -- --json
#
# Options:
#   -v, --version VERSION    Install specific version, e.g. 1.2.3 or v1.2.3 (default: latest)
#   -d, --dir DIR            Installation directory (default: ~/.local/bin)
#   -y, --yes                Replace an existing binary without asking
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
TOOL_NAME='ntm'
REPO='Dicklesworthstone/ntm'
BINARY_NAME='ntm'
ARCHIVE_FORMAT_LINUX="tar.gz"
ARCHIVE_FORMAT_DARWIN="tar.gz"
ARCHIVE_FORMAT_WINDOWS="zip"
# The template is data, not shell code. Expand its variables only in the renderer.
ARTIFACT_NAMING='${name}_${version}_${os}_${arch}'
LINUX_LIBC_FALLBACK='none'
STRICT_RELEASE_CONTRACT=false

# Minisign public key for signature verification (embedded from dsr config)
# If empty, signature verification is skipped
MINISIGN_PUBKEY=""

# Validated source selection, embedded as data by the generator. The source
# engine below is embedded too: installed clients need no DSR checkout.
SOURCE_LANGUAGE='go'
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

_tc_bootstrap_go() {
    local tree="$1" root="$2" platform="$3" requested selection version filename digest size actual
    [[ -f "$tree/go.mod" && ! -L "$tree/go.mod" ]] || return 4
    # The toolchain directive is an exact preferred compiler. Without it, use
    # the stated go version; a major.minor selects its newest published patch,
    # never a different minor. Do not silently update a pinned requirement.
    requested=$(awk '
        { sub(/\/\/.*/, "") }
        $1 == "go" { if (NF != 2 || ++g != 1) bad=1; version=$2 }
        $1 == "toolchain" { if (NF != 2 || ++t != 1) bad=1; selected=$2 }
        END {
            if (bad || g != 1) exit 1
            if (selected != "" && selected != "default") print selected
            else print "go" version
        }' "$tree/go.mod") || return 4
    [[ "$requested" =~ ^go[1-9][0-9]*\.[0-9]+(\.[0-9]+)?$ ]] || {
        _tc_log_error 'Go bootstrap requires a released numeric go/toolchain version in go.mod'; return 4;
    }
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
toolchain_bootstrap() (
    [[ $# -eq 4 && "$4" == --allow-install ]] || return 4
    local language="$1" tree="$2" root="$3" platform parent command
    local _TC_BOOTSTRAP_URL='' _TC_BOOTSTRAP_SHA='' _TC_BOOTSTRAP_BIN='' _TC_BOOTSTRAP_VERSION='' _TC_BOOTSTRAP_RUSTUP_TOOLCHAIN=''
    [[ "$language" != typescript ]] || language=bun
    case "$language" in rust|go|bun) ;; *) return 4 ;; esac
    [[ -d "$tree" && ! -L "$tree" && -n "$root" && "$root" != */ && ! -e "$root" && ! -L "$root" ]] || return 4
    parent=$(dirname "$root")
    [[ -d "$parent" && ! -L "$parent" ]] || return 4
    tree=$(cd "$tree" && pwd -P) || return 4
    root="$(cd "$parent" && pwd -P)/${root##*/}"
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
        go) _tc_bootstrap_go "$tree" "$root" "$platform" || return $? ;;
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
    [[ "$1" == HEAD || "$1" =~ ^[0-9a-fA-F]{40}$ || "$1" =~ ^[0-9a-fA-F]{64}$ ]] && return 0
    case "$1" in refs/heads/*|refs/tags/*) ;; *) return 1 ;; esac
    [[ "$1" =~ ^refs/(heads|tags)/[A-Za-z0-9_][A-Za-z0-9._+/-]*$ ]] &&
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
    local token=''
    if [[ -n "${DSR_GH_TOKEN:-}" ]]; then
        token="$DSR_GH_TOKEN"
    elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
        token="$GITHUB_TOKEN"
    elif [[ -n "${GH_TOKEN:-}" ]]; then
        token="$GH_TOKEN"
    else
        command -v gh >/dev/null 2>&1 || return 3
        token=$(GH_HOST=github.com gh auth token --hostname github.com 2>/dev/null) || return 3
    fi
    [[ -n "$token" ]] || return 3
    [[ "$token" != *$'\r'* && "$token" != *$'\n'* ]] || return 4
    printf '%s\n' "$token"
)

_installer_run_gh() (
    set +x
    command -v gh >/dev/null 2>&1 || return 3
    local token
    token=$(_installer_github_token) || return $?
    GH_HOST=github.com GH_TOKEN="$token" gh "$@"
)

# Freshness is advisory release metadata, NOT artifact or commit-signature
# verification. Query only GitHub's API and do not inherit a GH_HOST override.
# Separate API bytes from diagnostic logs so warnings cannot become JSON.
_isb_freshness_request() {
    local transport="$1" endpoint="$2" destination="$3"
    if [[ "$transport" == gh ]]; then
        _installer_run_gh api --hostname github.com --method GET \
            -H 'Accept: application/vnd.github+json' -H 'Cache-Control: no-cache' \
            "$endpoint" > "$destination"
    else
        curl -sSf --proto '=https' --connect-timeout 10 --max-time 30 \
            -H 'Accept: application/vnd.github+json' -H 'Cache-Control: no-cache' \
            "https://api.github.com/$endpoint" -o "$destination"
    fi
}

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
    [[ $# -eq 4 || ( $# -eq 5 && "$5" == --prefer-gh ) ]] || return 4
    [[ $# -ne 5 ]] || prefer=true
    [[ "$repo" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ &&
       "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ && "$tag" != null &&
       "$threshold" =~ ^(0|[1-9][0-9]{0,5})$ ]] || return 4
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

# Activate an explicitly requested bootstrap only when a compiler is missing.
# This runs inside _isb_compile's subshell, so PATH and language homes never
# escape the source attempt or replace the caller's installed toolchain.
_isb_prepare_toolchain() {
    local language="$1" tree="$2" output="$3" limit="$4" command root bin source_dir status=0
    case "$language" in rust) command=cargo ;; go) command=go ;; *) command=bun ;; esac
    if command -v "$command" >/dev/null 2>&1 &&
       { [[ "$language" != rust ]] || command -v rustc >/dev/null 2>&1; }; then
        if [[ "$language" != rust || "${_ISB_INSTALL_TOOLCHAIN:-false}" != true ]]; then
            return 0
        fi
        # A working installed compiler is preserved even if it is too old for
        # the project. An unavailable rustup-selected compiler is a missing
        # toolchain; bootstrap it privately instead of changing that rustup home.
        _isb_run "$limit" "$output/toolchain-probe.log" _isb_probe_rust "$tree" || status=$?
        ((status != 0)) || return 0
        [[ "$status" != 5 ]] || return 5
        _isb_log 'The existing Rust commands do not provide the selected compiler; preparing an isolated toolchain'
    fi
    if [[ "${_ISB_INSTALL_TOOLCHAIN:-false}" != true ]]; then
        _isb_log "Missing $command; --install-toolchain permits an isolated compiler for this build"
        return 3
    fi
    if ! declare -F toolchain_bootstrap >/dev/null 2>&1; then
        source_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || return 3
        [[ -f "$source_dir/toolchain_detect.sh" && ! -L "$source_dir/toolchain_detect.sh" ]] || return 3
        # shellcheck source=SCRIPTDIR/toolchain_detect.sh
        source "$source_dir/toolchain_detect.sh" || return 3
    fi
    root="$output/toolchain"
    _isb_log "Preparing a private $language toolchain; existing installations and profiles are preserved"
    _isb_run "$limit" "$output/toolchain.log" toolchain_bootstrap \
        "$language" "$tree" "$root" --allow-install || return $?
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

# Build only the requested executable family, into a new private output directory.
# Never run arbitrary command strings from installer configuration.
_isb_compile() (
    local language="$1" tree="$2" output="$3" binary="$4" entry="$5" package="$6" limit="$7"
    shift 7
    local -a binaries=("$@") targets=()
    ((${#binaries[@]})) || binaries=("$binary")
    [[ "$language" == rust || ${#binaries[@]} -eq 1 ]] || return 4
    local status=0 host target name mod=readonly
    cd "$tree" || return 4
    _isb_prepare_toolchain "$language" "$tree" "$output" "$limit" || return $?
    binary=$(_isb_binary_name "$binary") || return 4
    case "$language" in
        rust)
            [[ -f Cargo.toml && ! -L Cargo.toml ]] || return 4
            # rustup proxies may auto-install a missing repository-selected
            # toolchain. Any separately authorized bootstrap is already active;
            # never let a proxy modify an existing global installation.
            # https://rust-lang.github.io/rustup/environment-variables.html
            export RUSTUP_AUTO_INSTALL=0
            _isb_run "$limit" "$output/compiler.log" rustc -vV || { status=$?; [[ $status == 5 ]] && return 5; return 6; }
            host=$(sed -n 's/^host: //p' "$output/compiler.log")
            [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 6
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
            [[ -f go.mod && ! -L go.mod ]] || return 4
            # Build for this installer host, not an inherited cross target.
            export GOENV=off GOWORK=off GOTOOLCHAIN=local GOFLAGS='' GOOS='' GOARCH=''
            _isb_run "$limit" "$output/compiler.log" go version || { status=$?; [[ $status == 5 ]] && return 5; return 6; }
            _isb_run "$limit" "$output/platform.log" go env GOHOSTOS GOHOSTARCH || { status=$?; [[ $status == 5 ]] && return 5; return 6; }
            local host_os host_arch
            host_os=$(sed -n '1p' "$output/platform.log")
            host_arch=$(sed -n '2p' "$output/platform.log")
            [[ "$host_os" =~ ^[a-z0-9]+$ && "$host_arch" =~ ^[a-z0-9]+$ ]] || return 6
            export GOOS="$host_os" GOARCH="$host_arch"
            [[ ! -d vendor ]] || mod=vendor
            if [[ -z "$entry" ]]; then
                entry=.
                [[ ! -d "cmd/${binary%.exe}" ]] || entry="cmd/${binary%.exe}"
            fi
            _isb_path_in_tree "$tree" "$entry" || return 4
            _isb_run "$limit" "$output/package.log" go list "-mod=$mod" -f '{{.Name}}' "./$entry" || { status=$?; [[ $status == 5 ]] && return 5; return 6; }
            [[ "$(cat "$output/package.log")" == main ]] || { _isb_log 'Requested Go package is not one executable'; return 6; }
            target="$output/$binary"
            _isb_run "$limit" "$output/build.log" go build "-mod=$mod" -trimpath -o "$target" "./$entry" || { status=$?; [[ $status == 5 ]] && return 5; return 6; }
            targets+=("$target")
            ;;
        bun|typescript)
            [[ -f package.json && ! -L package.json ]] || return 4
            if [[ -z "$entry" ]]; then
                entry=$(jq -er --arg binary "${binary%.exe}" '.bin | if type == "string" then . elif type == "object" then .[$binary] else empty end | select(type == "string" and length > 0)' package.json) || {
                    _isb_log 'Bun source build needs source_entry or a matching package.json bin'; return 4;
                }
                entry="${entry#./}"
            fi
            _isb_path_in_tree "$tree" "$entry" && [[ -f "$entry" ]] || return 4
            if [[ ! -f bun.lock && ! -f bun.lockb ]]; then
                _isb_log 'A committed bun.lock or bun.lockb is required'; return 4
            fi
            [[ ! -L bun.lock && ! -L bun.lockb ]] || return 4
            _isb_run "$limit" "$output/compiler.log" bun --version || { status=$?; [[ $status == 5 ]] && return 5; return 6; }
            _isb_run "$limit" "$output/dependencies.log" bun install --frozen-lockfile || { status=$?; [[ $status == 5 ]] && return 5; return 6; }
            target="$output/$binary"
            _isb_run "$limit" "$output/build.log" bun build --compile --outfile "$target" "./$entry" || { status=$?; [[ $status == 5 ]] && return 5; return 6; }
            targets+=("$target")
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
    if [[ "$language" != rust && ${#binaries[@]} -gt 1 ]]; then
        _isb_log 'Executable families are supported only for Rust source builds'
        return 4
    fi
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
    local build_root
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
    local toolchain_receipt=null
    if [[ -f "$output/toolchain/receipt.json" ]]; then
        toolchain_receipt=$(jq -ce 'del(.root,.bin_dir)' "$output/toolchain/receipt.json") || return 7
    fi
    receipt=$(jq -nc --arg repo "$repo" --arg ref "$ref" --arg commit "$commit" \
        --arg language "$language" --arg path "$payload" --arg sha "$sha" --argjson size "$size" \
        --argjson binaries "$binaries_json" \
        --argjson toolchain "$toolchain_receipt" \
        --arg compiler "$(cat "$output/compiler.log")" \
        '{schema_version:1,method:"source",repository:$repo,requested_ref:$ref,source_commit:$commit,
          language:$language,path:$path,sha256:$sha,size_bytes:$size,compiler:$compiler,
          binaries:$binaries,signed_release:false} +
          (if $toolchain == null then {} else {toolchain:$toolchain} end)') || return 1
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
_INSTALLED_BINARIES_JSON='[]'
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
        *) printf '%s\n' 'ntm' ;;
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
    echo "${_CACHE_DIR}/${TOOL_NAME}/${version}/${platform//\//-}.${format}"
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
        case "${version,,}" in
            *musl*) echo musl; return 0 ;;
            *"gnu libc"*|*"gnu c library"*|*glibc*) echo gnu; return 0 ;;
        esac
    fi
    if command -v getconf >/dev/null 2>&1; then
        version=$(getconf GNU_LIBC_VERSION 2>/dev/null) || true
        [[ "${version,,}" != *glibc* ]] || { echo gnu; return 0; }
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
            _log_error "Artifact naming does not distinguish $_TARGET_TRIPLE from primary $primary; use a target-qualified pattern"
            return 4
        fi
    fi
    printf '%s\n' "$name"
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
        if _installer_run_gh release download "$_VERSION" --repo "github.com/$REPO" --pattern "$asset" --output "$dest" --clobber 2>/dev/null &&
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
        if _installer_run_gh release download "$_VERSION" --repo "github.com/$REPO" --pattern "$asset" --output "$dest" --clobber 2>/dev/null &&
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
        if version=$(_installer_run_gh release view --repo "github.com/$REPO" --json tagName --jq '.tagName' 2>/dev/null) &&
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
        if version=$(_installer_run_gh release view --repo "github.com/$REPO" --json tagName --jq '.tagName' 2>/dev/null) &&
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
        tar ${tar_args[@]+"${tar_args[@]}"} --no-same-owner --no-same-permissions -xf "$archive" -C "$dest_dir" || return 1
    fi
}

# Stage the complete family and backups on the destination filesystem before
# replacing its first member. On failure, restore every touched destination;
# unrelated executables are never moved or removed.
# This function is launched only as a background job by _install_binaries.
# A second function-body subshell would hide the actual writer behind $! and
# leave it running when the parent forwards a signal to its tracked child.
_install_family_transaction() {
    local dest_dir="$1"; shift
    local sources=("$@") hashes=() sizes=() previous=()
    local name path hash size previous_hash backup_hash index=0 stage='' committed=false touched=0
    local receipt='[' separator='' original_dir="$dest_dir"
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
    # Gather every replacement decision before creating files in the prefix.
    for name in "${_INSTALL_NAMES[@]}"; do
        path="$dest_dir/$name"
        [[ ! -L "$path" && ( ! -e "$path" || -f "$path" ) ]] || {
            _log_error "Refusing a linked or non-regular install destination: $path"; exit 1;
        }
        if [[ -f "$path" ]] && ! $_AUTO_YES; then
            if $_NON_INTERACTIVE; then
                _log_error "Binary already exists at $path"
                _log_info "Use --yes to overwrite or remove it manually"
                exit 1
            fi
            _log_warn "Binary already exists: $path"
            local response=""
            if ! read -rp "Overwrite? [y/N] " response < /dev/tty 2>/dev/null; then
                _log_error "No terminal to confirm replacing $path"
                _log_info "Re-run with --yes to replace it"
                exit 1
            fi
            if [[ ! "$response" =~ ^[yY] ]]; then
                _log_info "Installation cancelled"
                exit 1
            fi
        fi
    done
    mkdir -p -- "$dest_dir" || exit 1
    stage=$(mktemp -d "$dest_dir/.${BINARY_NAME}.install.XXXXXXXX") || exit 1
    _finish_family_transaction() {
        local status=$? restore_index restore_name failed=false
        trap - EXIT
        # Finish restoration even if the caller repeats an interrupt while
        # backups are being moved back into place.
        trap '' HUP INT TERM
        if ! $committed; then
            restore_index=$((touched - 1))
            while ((restore_index >= 0)); do
                restore_name="${_INSTALL_NAMES[$restore_index]}"
                if [[ "${previous[$restore_index]}" == true ]]; then
                    mv -f -- "$stage/old/$restore_name" "$dest_dir/$restore_name" || failed=true
                else
                    rm -f -- "$dest_dir/$restore_name" || failed=true
                fi
                restore_index=$((restore_index - 1))
            done
        fi
        if $failed; then
            _log_error "Could not restore every previous binary; recovery files retained at: $stage"
            exit 1
        fi
        rm -rf -- "$stage"
        exit "$status"
    }
    trap _finish_family_transaction EXIT
    trap 'exit 5' HUP INT TERM
    mkdir -- "$stage/new" "$stage/old" || exit 1
    for name in "${_INSTALL_NAMES[@]}"; do
        cp -- "${sources[$index]}" "$stage/new/$name" || exit 1
        chmod 755 "$stage/new/$name" || exit 1
        [[ "$(_file_sha256 "$stage/new/$name")" == "${hashes[$index]}" ]] || exit 1
        path="$dest_dir/$name"
        if [[ -f "$path" && ! -L "$path" ]]; then
            cp -p -- "$path" "$stage/old/$name" || exit 1
            previous_hash=$(_file_sha256 "$path") || exit 1
            backup_hash=$(_file_sha256 "$stage/old/$name") || exit 1
            [[ "$previous_hash" == "$backup_hash" ]] || exit 1
            previous+=(true)
        elif [[ ! -e "$path" && ! -L "$path" ]]; then
            previous+=(false)
        else
            exit 1
        fi
        receipt+="$separator"'{"name":"'"$(_json_escape_str "$name")"'","path":"'"$(_json_escape_str "$original_dir/$name")"'","sha256":"'"${hashes[$index]}"'","size_bytes":'"${sizes[$index]}"'}'
        separator=,
        index=$((index + 1))
    done
    receipt+=']'
    index=0
    for name in "${_INSTALL_NAMES[@]}"; do
        path="$dest_dir/$name"
        [[ ! -L "$path" && ( ! -e "$path" || -f "$path" ) ]] || exit 1
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
    local receipt receipt_file family_pid='' previous_traps interrupted=false status=0
    receipt_file=$(mktemp "$_TEMP_DIR/install-family.XXXXXXXX") || return 1
    previous_traps=$(trap -p HUP INT TERM)
    # Sending TERM to only this installer PID must also stop its transaction.
    # Wait for the child's rollback before restoring the caller's handlers.
    trap 'interrupted=true; if [[ -n "$family_pid" ]]; then kill -TERM "$family_pid" 2>/dev/null || true; fi' HUP INT TERM
    _install_family_transaction "$_INSTALL_DIR" "${_INSTALL_PATHS[@]}" > "$receipt_file" &
    family_pid=$!
    if $interrupted; then kill -TERM "$family_pid" 2>/dev/null || true; fi
    wait "$family_pid" || status=$?
    if $interrupted; then
        trap '' HUP INT TERM
        wait "$family_pid" 2>/dev/null || true
        status=5
    fi
    trap - HUP INT TERM
    if [[ -n "$previous_traps" ]]; then eval "$previous_traps"; fi
    ((status == 0)) || return "$status"
    receipt=$(cat -- "$receipt_file") || return 1
    _INSTALLED_BINARIES_JSON="$receipt"
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
_SKILL_ARCHIVE_B64='H4sIAAAAAAAAA+1a624bxxX2732KKdNL4nJJy5JtwAhTKLKTqLUsV1KQH0URDneH5ES7O9uZWdEMgqIP0Sfsk/Q7Z3aXu6Tk5EeNougeGBE5nMuZc/nOZTKZPvro9AT04tkz/gva/8ufj54dPT86Pj5+fnyE8Rcvjo4fiWcfn7VHjyrnpRXikTXGf2jez/3+P0qT6fWfzt+8meTpxzuDFPz85OQB/T99Aq339X8EevFIPPl4LO3o/1z/cRxHhczVS1H4PEqVS6wuvTbFS/FFHAlxVRXi7c2FWBor8irzOpYrVXjh8+q9MDZZK+etpAVjsTH2VnirMWMsrFkYL3KT4rOTS+W3Y2yXGGNTXdQLZJGKzCQyE6fvzt1EfOuU2KxVIVwpN4UuVsJtpM3dWKQaQz5Z0xgdM8bZ2M6Uig7H4Bzsz4V02FMEDsHwusrxNUwydhLRZaPPfxXH4uby7KX4c6WTW3EN/Xvxk7hWzoErcdm9FMZf1UeL34orVTm5yJQ4dU55hx+/oyufF15lmcapicLYWeeOtC9fHh+uWCIXkAifZu8UXRuf31nzg0o8tncmq+plV2qpLO3o+EsmvUrF9a3OMifi+Iso+oT18q9//FO8hf5ScUMauZAFbm+j6Avx+PGZsUokspQLnWm/ffn4sbipbCHmpLy50IU3QgpctUp8ZVUKpanE3EFadMeutknkkEKiJmHnKyVT4dcKC0ojlto6P8Hu50sehEBXyvNvTkPwW7GGYuanX79+e3MNpJmTbuZXr09fXbymr3Qu72eg/4VaEtuyLLMtKdavtROO7j2BGEoTB4PRReAbwnKCeLYacgWzyuqEJSPTO90yTCqyEtMh9DsYSeVNzgqCUDAhZvsRqXTrhZGWWOKBUmbKezUPpmpwOStuvj0XrrJLSaqRYHXZWJqb8FZfkatIslUV08VYmrsTx6K0pFsxj2N2kvjxPCx8a4pYdxg9e3MOh8mxcwoRVDBBEiPx5VTR8tjxumYIIrp1ItPOtxfRpcrAELQtfeXqC9V7wRLn4SY0gx0QN93yEOkzyRQ+Oji9Mdmksa2OkdNeGrbbk+gpW86F1BnUS4fIoKxm11QtJUysBwkQjc41XT5IBCKi63mrlJvvWG7HxGQyCay7qiyNJR9pGWF2XXufYKulyXSCq2WZ2TgazsNJMF0ZZnTtNGjK9S4QmyLbMrpAGw0nsStVopcwPVtlCoC1NHQCDpDBESC2Tz7pIk4UzefzBQwOjnwOYwZHYgqkLOCpAgiU3EZJZTMRL931GzFae1+6l9OplZvJSvt1tajAUmJgLoWfwEqmr7A1jgZHfu28KdQUoprmUhdTHfafuPUffv1pCiQRv/+N+2wEYCEGREyIgn9Kum1MiB2xM6gS43cENGcwYyzCnS1BFExTQjQMWjz1b3ytfFuPYSuv8pIga7YytMEbWRVkviLX76EiRnVeyUDfW5kks6f0x6SzI/xd5Xp2RFu0MEwijxon2FsqRheyZGXD39Yik1v4GZkNJpWELqRjeC5ASYC/YjKKgvhL2oFtvbK2QTyxsrJc83q3dbgSe0+QTsfrcDIgAM49y6W9Tc2m4BmNd7tClm5tPOmbjeDeQBNFFPzAgQuAkspt7E2MP7hnmJ/ppUq2CUEzo3wOPl/uzOhBcR7X4nzaivP+qZlcqEwsLdtUWqvig3MXMrndTRUdZ+VlMt3XT332/g+HJ5P2eSqBWOCBgWu3jAfvtNrsDf1oTN7Z/Dgc6D0AeW9mi/Z74zXod0ZZc9DPsspqWcAUgdOF+1n541NeejHiiNkiS7ApTjygWAoSW7ao0f27WIGTsxgLktv7ZxDIpPEKoi8eYgQ4Zgo5k7A67ftjGs7K5qTsy4c0jsNXyCwYH2YuJ9ZZo89rdZ209t16Kl1yL2WKom/0ah1nirIMuA4FakzAJ0T5AunRD8jHxZyPB/xm0Picg91E3DCEI/SXZgOvhksBwKuS8T3amopC5YICGBIAitNNytjqSmyAm9iiZqhxqxoeSEuSeZzs6XQfZgipR2eE0KVBuA66rBCmrf4R+QsFX8h1Mrp/dSkLBV8ZXW6KHVDlehVgoLuKjYdX7daPrrdFgsAmCNf5ZAoulqJosURk8w+dmwjOLAqZTenEKcUzSo9WhmyT/ShkWtUiYN3923jkCO/B2R1qJu1cpWajQpNKePcRQaGGbB86636RNNZkTYWIIZdIQygIjm7krdrJKETUuCofECz0DTxeYIv6S8zYqlbbGUIZZiOZ3ka8Fmku8iG3A5dmgIxq39fIL5ecLbTTd0O8oO96TejbTW9H6tkhANW3YCNs42XnkMOf+ssbULLsTVljxySNZiRUKQhCsDB2ggk7XCKLNpCT3ehVVVc7gOA8mv99OgnDnEGEFKu7OSfg80n7IyM+qjwT8pZdshVy+Qh8VDnl8nXK50IydFA7RRFxx0CAFLYA2gQ4QLIBp0E0pySCLnHuOfniuiNOMuwf4rFTmUrajBTDelXcEyU7sfueWL5A4LVd5SNZVNa73XenCETF6I/f3bBpjnY/AUmhnY79l5p9oLF9nlSo9zs7CklGsMvAcR9sUDcw+h6a8gMrFogmbraw8dHT4zH/OaF9KBufAajV+9ZyOvUD65EzZULSjQSskS5w9gbsifnirrEBJChNeqR3tXW8tBp8ITGmVGjCuyNVpYViV+bsTmjSZWDpNhxHRhPyLVWsAOO/gxlILoNCJwHYUFY+WM5B8XEV6tZtsKACbqLeU77HGT5Va4CWIiUT7FUb7OQIFHB/n233rCSnyuV+8L8KmNtAPbPQJI6Mf0uTVA0S8z66WJj3e3nGrkrbPyFoy3VmYeuDTCf8AnknVGeiRnOdnEWcUD6GiKrEKNTwuDSXlYGrVg7INe9NrboTUvhnl8uDCW302Z+zi5JO3nXZi3Mxqkt9q93ttsW10f7CvoD2f6W6lDbpT/A6D+XuDoObEQbRzxtw1ekX/DNCHzcqGtcmn4XQYKBsKAoGVHMmq1T7sMs+UxKQ5R6UBTit8oOs8rytVg233boZZd/QY4a7By2HC5lmszA3uFu/4tX+w4VCP4PfFdq92BeGcmVX1ByARNT3R7vyJvS7yCdOS+x/JzMX/JIwe1HpzMdAjronWLMX+hGynt/2V0JLkKp0bvhQDm1QqKdibRLoAJEDmy60P8jDAw/BsLsjIUCh2kUNzVU9XX2NGqA7Kfg1JWBrU8G9n550f62L6YDYtXDZHNh1u6O4iU6bgrEeU2mtgUYtbV+oDgEsgo7hNgN8hFwkQPXe+D1DCA/bepzAF8AA8xptUF6tmt7cwkrE0lFtg8tdyO711axCZQ/nMktkO5Lxk/SXOmoFICPxhK+A1hXl+qE7Rj2XXa8KvjQfC7NQ2/tPqOEciwuKBZ0WaRSFvizn7FwW76m4iSowgrI30DY8dW3EbSG+s4aD2rw7SI2B3kBbKPZGm2IfA3mKEogjf28GcgCngojPTJ5TR0q6206riG/b2PoD96MINOs6au5Ws9H1PfUGtV22pZoFj+xtgjDX2wPfY0JEBNXZ8ZO+TDziVW8ywaabPXuyd3udxY038Zd6QW9pZSn0cMdsT0fOxQFrZx/A2mY6pzQx412d39TKnCH/KA6mUkqo8zoFqlfEIVNSqC+IpaP7FiFh2FvEY7UHzUZQIupkr9Laby7r5Ad4bMqgPk+p3dFEfGmMp5ytDAZ8YG9PUc9SatH7lVL0IsQC2w5uJADjeCJOE7+3F9aPRVMKhU/hkuEzBwl6JxFNFhKdUAs9XnyYN6GXTSfMYTESKUCACzd+d9C5DjGm8f725SU8IyHTVdS6bl8Yelnc7gmEsP9d06G+rv0hxAwED9Mmc+1bEa9Iq/BQ0VRjD3kSN7ipmqac7cXx8QseJctBdh6eDFqQbpiwVSG4wGlG3NRylTzZyjyjhLzuHuy1jvptdtomfvrk6QlM6gnZ1cmz5zGAOe1PbrF+d3zIFX7ZcmrPF1UJpkyWKjt7ke5l+HWHf8mWWqzgSHeqeXijSqXuPdTRtqtcWuIA+5mK2TSCfqnrbPklAFo8fLyC9NsUY16bQNsvrrNtyrW4N75Xj+71XkIZKihi1evd9/hR/bKu86UNjYn+WiGpZQObgtQponFQyiSqEi+mIgmtbincNod0b4N90yVULVbqQzXap5dTUbmKy5icuk11yXF4W5o6EW+o0+lwODc6/f5WFDObMjt0RedByu1rIApmKuGi5gWueTGlooq4RPBHhYiUXRGOs4fTxRAlwjspHcm9I35SEwuTUt3zk7gxJSJS59lR/ITRGJlS/V9867fu6peptr02rp2bXhzJ2ccCEY+e/3DseNd2k83T6V/OLi8uTt++on7oXz+17XPntDP+GZ972uLiUvErZacgFKH1jtMJKMlgkGCRMY8Z8qYUaaaE5fWq0LbB6VeXX17exBeXr17vn9/7JXDwDT8kt3nAuOkRj8Wt2i40l5Yu5LD0PNj2U0NEoyqMz3x1ev3Nl5enV6/2j+z+EE5s3Mq2bjVuTSPYMRKr2j2ggXV9er9H05X126/Ovz6UdD1KZwYz674zR1Es5uzyHOEDHHAlS+0eQgHqdazpeXItb1XNAhfA3Qcz2mVhw2rWBL+itPVSeF4pEoiQZ96FmdwLiOWGnwuRNtHTIGzJ6x9DtoyppNswmX9rMdkqb7VC9h39t//vioEGGmiggQYaaKCBBhpooIEGGmiggQYaaKCBBhpooIEGGmiggQYaaKCBBhpooIEGGmiggQb6z9K/AS/WGpsAUAAA'

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
install.sh - Install ntm

Usage:
  curl -sSfL https://raw.githubusercontent.com/Dicklesworthstone/ntm/main/install.sh | bash
  curl -sSfL https://raw.githubusercontent.com/Dicklesworthstone/ntm/main/install.sh | bash -s -- -v 1.2.3
  curl -sSfL https://raw.githubusercontent.com/Dicklesworthstone/ntm/main/install.sh | bash -s -- --json

Options:
  -v, --version VERSION    Install specific version, e.g. 1.2.3 or v1.2.3 (default: latest)
  -d, --dir DIR            Installation directory (default: ~/.local/bin)
  -y, --yes                Replace an existing binary without asking
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
            --mode)
                [[ $# -ge 2 && "$2" =~ ^(vibe|safe)$ ]] || {
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
                [[ $# -ge 2 && "$2" =~ ^(gnu|musl)$ ]] || {
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

    # Both CLI spellings use the same post-verification freshness path. Never
    # silently resolve conflicting thresholds by whichever flag appeared last.
    if $prefer_stale; then
        [[ "$stale_threshold" =~ ^(0|[1-9][0-9]{0,5})$ && -z "$_SOURCE_IF_STALE" ]] || {
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
    if $_FROM_SOURCE; then
        _install_from_source "Explicit --from-source request"
        return $?
    fi
    _TARGET_TRIPLE=$(_select_target_triple "${platform%/*}" "${platform#*/}") || return $?
    if [[ ! "$_TARGET_TRIPLE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        _log_error "Unresolved target triple for $platform"
        return 4
    fi
    local install_targets="$_TARGET_TRIPLE" fallback_triple
    fallback_triple=$(_fallback_target_triple "${platform%/*}" "${platform#*/}" "$_TARGET_TRIPLE") || return $?
    [[ -z "$fallback_triple" ]] || install_targets+=$'\n'"$fallback_triple"
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

    local format asset_name asset_plan

    # Create temp directory. _TEMP_DIR is a script-scope global so the
    # EXIT trap can still see it after main() returns and locals are
    # popped.
    _TEMP_DIR=$(mktemp -d) || return 1
    _TEMP_DIR=$(cd "$_TEMP_DIR" && pwd -P) || return 1
    trap _cleanup_temp_dir EXIT
    local temp_dir="$_TEMP_DIR"

    local archive_file="" cache_platform="$platform" cached_file acquired=false
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
        elif cached_file=$(_cache_get "$_VERSION" "$cache_platform" "$format"); then
            _copy_local_archive "$cached_file" "$archive_file" || return $?
        elif $_OFFLINE_MODE; then
            _log_warn "Offline mode: no cached archive for $TOOL_NAME $_VERSION ($_TARGET_TRIPLE)"
            continue
        elif ! _fetch_release_asset "$asset_name" "$archive_file"; then
            _log_warn "Release payload unavailable: $asset_name"
            continue
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
        _cache_put "$archive_file" "$_VERSION" "$cache_platform" "$format" || \
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
