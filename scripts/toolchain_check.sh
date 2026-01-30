#!/usr/bin/env bash
# toolchain_check.sh - Check and harmonize build toolchains across machines
#
# Usage:
#   ./toolchain_check.sh           # Check all machines
#   ./toolchain_check.sh --json    # JSON output
#   ./toolchain_check.sh --update sb  # Update specific machine
#
# Build machines:
#   trj   - Threadripper (local, Linux)
#   wlap  - Surface Book (Windows, remote via Tailscale)
#   mmini - Mac Mini (macOS, remote via Tailscale)

set -uo pipefail

# Configuration
# Machine names map to SSH config entries:
#   trj   - local (Threadripper)
#   wlap  - Windows laptop (Surface Book) via Tailscale
#   mmini - Mac Mini via Tailscale
#   fmd   - OVH server (Linux)
MACHINES=(trj wlap mmini)
SSH_TIMEOUT=15

# Colors
if [[ -z "${NO_COLOR:-}" && -t 1 ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    BLUE=$'\033[0;34m'
    NC=$'\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

log_info() { echo -e "${BLUE}[info]${NC} $*"; }
log_ok()   { echo -e "${GREEN}[ok]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[warn]${NC} $*"; }
log_err()  { echo -e "${RED}[error]${NC} $*"; }

# Get tool version on remote machine
get_remote_version() {
    local host="$1"
    local tool="$2"
    local cmd="$3"

    local version
    if [[ "$host" == "trj" ]]; then
        version=$(eval "$cmd" 2>/dev/null | head -1) || version="not installed"
    else
        version=$(timeout "$SSH_TIMEOUT" ssh -o ConnectTimeout=5 "$host" "$cmd" 2>/dev/null | head -1) || version="unreachable"
    fi

    echo "$version"
}

# Check Rust version
check_rust() {
    local host="$1"

    local version
    if [[ "$host" == "wlap" ]]; then
        version=$(get_remote_version "$host" "rust" "rustc --version")
    else
        version=$(get_remote_version "$host" "rust" "rustc --version")
    fi

    # Extract just version number
    echo "$version" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown"
}

# Check Go version
check_go() {
    local host="$1"

    local version
    if [[ "$host" == "wlap" ]]; then
        version=$(get_remote_version "$host" "go" "go version")
    else
        version=$(get_remote_version "$host" "go" "go version")
    fi

    # Extract version number
    echo "$version" | grep -oE 'go[0-9]+\.[0-9]+(\.[0-9]+)?' | sed 's/go//' | head -1 || echo "unknown"
}

# Check Node version
check_node() {
    local host="$1"

    local version
    if [[ "$host" == "wlap" ]]; then
        version=$(get_remote_version "$host" "node" "node --version 2>nul")
    else
        version=$(get_remote_version "$host" "node" "node --version")
    fi

    echo "$version" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "none"
}

# Check Bun version
check_bun() {
    local host="$1"

    local version
    if [[ "$host" == "wlap" ]]; then
        version=$(get_remote_version "$host" "bun" "bun --version 2>nul")
    else
        version=$(get_remote_version "$host" "bun" "bun --version")
    fi

    echo "$version" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "none"
}

# Check all tools on a machine
check_machine() {
    local host="$1"

    local rust go node bun

    # Check connectivity first
    if [[ "$host" != "trj" ]]; then
        if ! timeout "$SSH_TIMEOUT" ssh -o ConnectTimeout=5 "$host" "echo ok" &>/dev/null; then
            echo "$host:unreachable"
            return 1
        fi
    fi

    rust=$(check_rust "$host")
    go=$(check_go "$host")
    node=$(check_node "$host")
    bun=$(check_bun "$host")

    echo "$host:rust=$rust,go=$go,node=$node,bun=$bun"
}

# Display version comparison table
show_comparison() {
    echo ""
    echo "╔══════════════════════════════════════════════════════════════════════════════════════╗"
    echo "║                           Build Toolchain Versions                                   ║"
    echo "╠══════════╦═══════════════════╦═══════════════╦═══════════════════╦═════════════════╣"
    echo "║ Machine  ║ Rust              ║ Go            ║ Node              ║ Bun             ║"
    echo "╠══════════╬═══════════════════╬═══════════════╬═══════════════════╬═════════════════╣"

    local trj_rust="" trj_go="" trj_node="" trj_bun=""

    for machine in "${MACHINES[@]}"; do
        log_info "Checking $machine..."
        local result
        result=$(check_machine "$machine")

        if [[ "$result" == *":unreachable"* ]]; then
            printf "║ %-8s ║ %-17s ║ %-13s ║ %-17s ║ %-15s ║\n" "$machine" "${RED}unreachable${NC}" "-" "-" "-"
            continue
        fi

        local rust go node bun
        rust=$(echo "$result" | grep -oP 'rust=\K[^,]+')
        go=$(echo "$result" | grep -oP 'go=\K[^,]+')
        node=$(echo "$result" | grep -oP 'node=\K[^,]+')
        bun=$(echo "$result" | grep -oP 'bun=\K[^,]+')

        # Store trj versions as baseline
        if [[ "$machine" == "trj" ]]; then
            trj_rust="$rust"
            trj_go="$go"
            trj_node="$node"
            trj_bun="$bun"
        fi

        # Color code versions (green if matches trj, yellow if older)
        local rust_display go_display node_display bun_display

        if [[ "$machine" == "trj" ]]; then
            rust_display="${GREEN}$rust${NC}"
            go_display="${GREEN}$go${NC}"
            node_display="${GREEN}$node${NC}"
            bun_display="${GREEN}$bun${NC}"
        else
            if [[ "$rust" == "$trj_rust" ]]; then
                rust_display="${GREEN}$rust${NC}"
            elif [[ "$rust" == "unknown" || "$rust" == "none" ]]; then
                rust_display="${RED}$rust${NC}"
            else
                rust_display="${YELLOW}$rust${NC}"
            fi

            if [[ "$go" == "$trj_go" ]]; then
                go_display="${GREEN}$go${NC}"
            elif [[ "$go" == "unknown" || "$go" == "none" ]]; then
                go_display="${RED}$go${NC}"
            else
                go_display="${YELLOW}$go${NC}"
            fi

            if [[ "$node" == "$trj_node" ]]; then
                node_display="${GREEN}$node${NC}"
            elif [[ "$node" == "unknown" || "$node" == "none" ]]; then
                node_display="${RED}$node${NC}"
            else
                node_display="${YELLOW}$node${NC}"
            fi

            if [[ "$bun" == "$trj_bun" ]]; then
                bun_display="${GREEN}$bun${NC}"
            elif [[ "$bun" == "unknown" || "$bun" == "none" ]]; then
                bun_display="${RED}$bun${NC}"
            else
                bun_display="${YELLOW}$bun${NC}"
            fi
        fi

        printf "║ %-8s ║ %-17s ║ %-13s ║ %-17s ║ %-15s ║\n" \
            "$machine" "$rust_display" "$go_display" "$node_display" "$bun_display"
    done

    echo "╚══════════╩═══════════════════╩═══════════════╩═══════════════════╩═════════════════╝"
    echo ""
    echo "Legend: ${GREEN}✓ Up to date${NC} | ${YELLOW}⚠ Behind${NC} | ${RED}✗ Missing/Unreachable${NC}"
}

# Generate update commands for a machine
generate_update_commands() {
    local host="$1"

    echo ""
    echo "=== Update commands for $host ==="

    case "$host" in
        wlap)
            echo ""
            echo "# Windows (wlap) - Run in PowerShell as Administrator"
            echo ""
            echo "# Update Rust"
            echo "rustup update stable"
            echo ""
            echo "# Update Go (download from https://go.dev/dl/)"
            echo "# Or with winget:"
            echo "winget upgrade GoLang.Go"
            echo ""
            echo "# Install Node (via fnm or nvm-windows)"
            echo "winget install Schniz.fnm"
            echo "fnm install --lts"
            echo ""
            echo "# Install Bun"
            echo "powershell -c 'irm bun.sh/install.ps1 | iex'"
            ;;
        mmini)
            echo ""
            echo "# macOS (mmini)"
            echo ""
            echo "# Update Rust"
            echo "rustup update stable"
            echo ""
            echo "# Update Go"
            echo "brew upgrade go"
            echo ""
            echo "# Update Node"
            echo "brew upgrade node"
            echo "# Or with fnm:"
            echo "fnm install --lts"
            echo ""
            echo "# Install/Update Bun"
            echo "curl -fsSL https://bun.sh/install | bash"
            ;;
        trj)
            echo ""
            echo "# Linux (trj) - baseline machine"
            echo ""
            echo "# Update Rust"
            echo "rustup update"
            echo ""
            echo "# Update Go"
            echo "# Already managed - check /usr/local/go"
            echo ""
            echo "# Update Node"
            echo "fnm install --lts"
            echo ""
            echo "# Update Bun"
            echo "bun upgrade"
            ;;
    esac
}

# Update toolchain on remote machine
update_machine() {
    local host="$1"

    log_info "Updating toolchain on $host..."

    case "$host" in
        wlap)
            # Windows updates via SSH
            log_info "Updating Rust on Windows..."
            ssh "$host" "rustup update stable" || log_warn "Rust update failed"
            ;;
        mmini)
            log_info "Updating on macOS..."
            ssh "$host" "rustup update stable && brew upgrade go node" || log_warn "Update failed"
            ;;
        trj)
            log_info "Updating locally..."
            rustup update || log_warn "Rust update failed"
            ;;
    esac

    log_ok "Update complete for $host"
}

# JSON output mode
output_json() {
    echo "{"
    echo '  "checked_at": "'$(date -Iseconds)'",'
    echo '  "machines": ['

    local first=true
    for machine in "${MACHINES[@]}"; do
        local result
        result=$(check_machine "$machine" 2>/dev/null)

        if [[ "$first" != true ]]; then
            echo ","
        fi
        first=false

        if [[ "$result" == *":unreachable"* ]]; then
            echo "    {\"name\": \"$machine\", \"status\": \"unreachable\"}"
        else
            local rust go node
            rust=$(echo "$result" | grep -oP 'rust=\K[^,]+')
            go=$(echo "$result" | grep -oP 'go=\K[^,]+')
            node=$(echo "$result" | grep -oP 'node=\K[^,]+')

            echo -n "    {\"name\": \"$machine\", \"status\": \"ok\", "
            echo -n "\"rust\": \"$rust\", \"go\": \"$go\", \"node\": \"$node\"}"
        fi
    done

    echo ""
    echo "  ]"
    echo "}"
}

# Main
main() {
    local json_mode=false
    local update_target=""
    local show_commands=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json|-j)
                json_mode=true
                shift
                ;;
            --update|-u)
                update_target="$2"
                shift 2
                ;;
            --commands|-c)
                show_commands=true
                shift
                ;;
            --help|-h)
                echo "Usage: $0 [options]"
                echo ""
                echo "Options:"
                echo "  --json, -j          JSON output"
                echo "  --update, -u HOST   Update toolchain on HOST"
                echo "  --commands, -c      Show update commands for all machines"
                echo "  --help, -h          Show this help"
                exit 0
                ;;
            *)
                log_err "Unknown option: $1"
                exit 4
                ;;
        esac
    done

    if [[ "$json_mode" == true ]]; then
        output_json
    elif [[ -n "$update_target" ]]; then
        update_machine "$update_target"
    elif [[ "$show_commands" == true ]]; then
        for machine in "${MACHINES[@]}"; do
            generate_update_commands "$machine"
        done
    else
        show_comparison
    fi
}

main "$@"
