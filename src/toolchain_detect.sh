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
