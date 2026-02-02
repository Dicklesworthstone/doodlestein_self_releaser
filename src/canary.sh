#!/usr/bin/env bash
# src/canary.sh - Installer canary testing module
#
# Automated testing of installer scripts in fresh Docker containers.
# Catches regressions before users encounter them.
#
# Usage:
#   source "$SCRIPT_DIR/src/canary.sh"
#   canary_run_test ntm ubuntu:24.04 vibe
#
# Required modules:
#   - logging.sh (for log_info, log_error, etc.)
#   - config.sh (for repos config)

# shellcheck disable=SC2034  # Variables may be used by sourcing scripts

# ============================================================================
# Configuration
# ============================================================================

# Default test matrix
CANARY_MATRIX=(
    "ubuntu:22.04"
    "ubuntu:24.04"
    "debian:12"
    "fedora:39"
    "alpine:latest"
)

# macOS hosts for native testing
CANARY_MACOS_HOSTS=("mmini")

# Modes to test
CANARY_MODES=("vibe" "safe")

# State directory for canary results
CANARY_STATE_DIR="${DSR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsr}/canary"

# Timeout for each test (seconds)
CANARY_TIMEOUT=300

# Timeout helper (supports GNU timeout and coreutils gtimeout)
_CANARY_TIMEOUT_CMD=""
_canary_timeout_cmd() {
    if [[ -n "$_CANARY_TIMEOUT_CMD" ]]; then
        echo "$_CANARY_TIMEOUT_CMD"
        return 0
    fi

    if command -v timeout &>/dev/null; then
        _CANARY_TIMEOUT_CMD="timeout"
    elif command -v gtimeout &>/dev/null; then
        _CANARY_TIMEOUT_CMD="gtimeout"
    else
        _CANARY_TIMEOUT_CMD=""
    fi

    echo "$_CANARY_TIMEOUT_CMD"
}

_canary_run_with_timeout() {
    local seconds="$1"
    shift
    local cmd
    cmd=$(_canary_timeout_cmd)
    if [[ -n "$cmd" ]]; then
        "$cmd" "$seconds" "$@"
    else
        "$@"
    fi
}

# Shell-escape a string for safe remote execution (single-quote strategy)
_canary_shell_escape() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\"'\"'/g")"
}

# ============================================================================
# Docker Helpers
# ============================================================================

# Check if Docker is available and running
canary_check_docker() {
    if ! command -v docker &>/dev/null; then
        log_error "Docker not installed"
        return 1
    fi

    if ! docker info &>/dev/null 2>&1; then
        log_error "Docker daemon not running"
        return 1
    fi

    return 0
}

# Get the package manager install command for a given image
_canary_get_install_cmd() {
    local image="$1"

    case "$image" in
        ubuntu*|debian*)
            echo "apt-get update -qq && apt-get install -y -qq curl ca-certificates"
            ;;
        fedora*|centos*|rhel*)
            echo "dnf install -y -q curl ca-certificates"
            ;;
        alpine*)
            echo "apk add --no-cache curl ca-certificates bash"
            ;;
        *)
            echo "echo 'Unknown package manager for $image' >&2; exit 1"
            ;;
    esac
}

# Get the shell to use for a given image
_canary_get_shell() {
    local image="$1"

    case "$image" in
        alpine*)
            echo "sh"
            ;;
        *)
            echo "bash"
            ;;
    esac
}

# ============================================================================
# Test Execution
# ============================================================================

# Run a canary test for a single tool/image/mode combination
# Usage: canary_run_test <tool> <image> <mode> [--verbose]
# Returns: 0 on success, 1 on failure
canary_run_test() {
    local tool="$1"
    local image="$2"
    local mode="${3:-vibe}"
    local verbose="${4:-false}"

    local installer_path
    local installer_url

    # Check for local installer first
    local script_dir="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    installer_path="$script_dir/installers/$tool/install.sh"

    if [[ ! -f "$installer_path" ]]; then
        # Try to construct URL from repos config
        installer_url="https://raw.githubusercontent.com/Dicklesworthstone/$tool/main/install.sh"
        installer_path=""
    fi

    # Prepare test directory
    local tmpdir
    tmpdir=$(mktemp -d)
    # shellcheck disable=SC2064  # We want $tmpdir expanded now, at trap definition time
    trap "rm -rf '$tmpdir'" RETURN

    # Create test script
    local install_deps
    install_deps=$(_canary_get_install_cmd "$image")
    local shell
    shell=$(_canary_get_shell "$image")

    # If we have a local installer, copy it
    local installer_source
    if [[ -n "$installer_path" && -f "$installer_path" ]]; then
        cp "$installer_path" "$tmpdir/install.sh"
        chmod +x "$tmpdir/install.sh"
        installer_source="/install.sh"
    else
        installer_source="$installer_url"
    fi

    # Create the test script
    cat > "$tmpdir/test.sh" << TESTSCRIPT
#!/usr/bin/env $shell
set -u
if set -o pipefail 2>/dev/null; then
    set -o pipefail
fi

echo "=== Canary test: $tool on $image (mode: $mode) ==="

# Install dependencies
if ! sh -c "$install_deps"; then
    echo "Dependency installation failed" >&2
    exit 1
fi

# Run installer
echo "Installing $tool..."
if [ -f "/install.sh" ]; then
    # Local installer
    $shell /install.sh --mode $mode --non-interactive 2>&1 || true
else
    # Remote installer
    curl -sSL "$installer_source" | $shell -s -- --mode $mode --non-interactive 2>&1 || true
fi

# Verify installation
echo ""
echo "=== Verification ==="

# Check if binary is in PATH
if command -v $tool &>/dev/null; then
    echo "✓ $tool found in PATH"

    # Try --version
    if $tool --version 2>&1; then
        echo "✓ $tool --version works"
    else
        echo "! $tool --version failed (exit: \$?)"
    fi

    # Try --help
    if $tool --help 2>&1 | head -5; then
        echo "✓ $tool --help works"
    else
        echo "! $tool --help failed (exit: \$?)"
    fi
else
    echo "✗ $tool NOT found in PATH"
    echo "PATH: \$PATH"

    # Check common install locations
    for dir in /usr/local/bin /usr/bin ~/.local/bin; do
        if [ -f "\$dir/$tool" ]; then
            echo "Found at: \$dir/$tool"
        fi
    done

    exit 1
fi

echo ""
echo "=== Canary test PASSED ==="
TESTSCRIPT
    chmod +x "$tmpdir/test.sh"

    # Build Dockerfile - conditionally include install.sh if it exists
    if [[ -f "$tmpdir/install.sh" ]]; then
        cat > "$tmpdir/Dockerfile" << DOCKERFILE
FROM $image
COPY test.sh /test.sh
COPY install.sh /install.sh
RUN chmod +x /test.sh /install.sh
CMD ["/test.sh"]
DOCKERFILE
    else
        cat > "$tmpdir/Dockerfile" << DOCKERFILE
FROM $image
COPY test.sh /test.sh
RUN chmod +x /test.sh
CMD ["/test.sh"]
DOCKERFILE
    fi

    # Build and run
    local tag
    tag="dsr-canary-$tool-$(echo "$image" | tr ':/' '-')-$(date +%s)"
    local output
    local status=0

    log_info "Building test image for $tool on $image..."

    if ! docker build -t "$tag" "$tmpdir" &>/dev/null; then
        log_error "Failed to build Docker image"
        return 1
    fi

    log_info "Running canary test..."

    output=$(_canary_run_with_timeout "$CANARY_TIMEOUT" docker run --rm "$tag" 2>&1) || status=$?

    # Cleanup image
    docker rmi "$tag" &>/dev/null || true

    # Log output if verbose or failed (to stderr to avoid mixing with JSON)
    if [[ "$verbose" == "true" ]] || [[ $status -ne 0 ]]; then
        echo "$output" >&2
    fi

    return $status
}

# Run canary tests for all tools on a specific image
# Usage: canary_run_image <image> [--tools tool1,tool2,...] [--mode vibe|safe]
canary_run_image() {
    local image="$1"
    shift

    local tools=()
    local mode="vibe"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tools)
                IFS=',' read -ra tools <<< "$2"
                shift 2
                ;;
            --mode)
                mode="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    # Default to all tools with installers
    if [[ ${#tools[@]} -eq 0 ]]; then
        local script_dir="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
        while IFS= read -r -d '' dir; do
            tools+=("$(basename "$dir")")
        done < <(find "$script_dir/installers" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
    fi

    local passed=0
    local failed=0
    local results=()

    for tool in "${tools[@]}"; do
        log_info "Testing $tool on $image (mode: $mode)..."

        local start_time
        start_time=$(date +%s)

        if canary_run_test "$tool" "$image" "$mode"; then
            log_ok "  $tool: PASSED"
            ((passed++))
            results+=("$(jq -nc --arg tool "$tool" --argjson duration "$(($(date +%s) - start_time))" '{tool: $tool, status: "passed", duration: $duration}')")
        else
            log_error "  $tool: FAILED"
            ((failed++))
            results+=("$(jq -nc --arg tool "$tool" --argjson duration "$(($(date +%s) - start_time))" '{tool: $tool, status: "failed", duration: $duration}')")
        fi
    done

    # Return results as JSON
    local results_json
    results_json=$(printf '%s\n' "${results[@]}" | jq -sc '.')

    jq -nc \
        --arg image "$image" \
        --arg mode "$mode" \
        --argjson passed "$passed" \
        --argjson failed "$failed" \
        --argjson results "$results_json" \
        '{
            image: $image,
            mode: $mode,
            passed: $passed,
            failed: $failed,
            total: ($passed + $failed),
            results: $results
        }'

    [[ $failed -eq 0 ]]
}

# Run the full test matrix
# Usage: canary_run_matrix [--tools tool1,tool2,...] [--modes vibe,safe]
canary_run_matrix() {
    local tools_arg=""
    local modes=("${CANARY_MODES[@]}")

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tools)
                tools_arg="--tools $2"
                shift 2
                ;;
            --modes)
                IFS=',' read -ra modes <<< "$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    local total_passed=0
    local total_failed=0
    local image_results=()

    for image in "${CANARY_MATRIX[@]}"; do
        for mode in "${modes[@]}"; do
            log_info "=== Matrix: $image ($mode mode) ==="

            local result
            # shellcheck disable=SC2086  # Intentional word splitting for tools_arg
            result=$(canary_run_image "$image" $tools_arg --mode "$mode" 2>/dev/null) || true

            local passed failed
            passed=$(echo "$result" | jq -r '.passed // 0')
            failed=$(echo "$result" | jq -r '.failed // 0')

            ((total_passed += passed))
            ((total_failed += failed))

            image_results+=("$result")
        done
    done

    # Summary
    echo ""
    log_info "=== Matrix Summary ==="
    log_info "Total passed: $total_passed"
    log_info "Total failed: $total_failed"

    [[ $total_failed -eq 0 ]]
}

# ============================================================================
# macOS Testing (via SSH)
# ============================================================================

# Run canary test on macOS via SSH
# Usage: canary_run_macos <tool> <host> <mode>
canary_run_macos() {
    local tool="$1"
    local host="${2:-mmini}"
    local mode="${3:-vibe}"

    log_info "Running canary test for $tool on macOS ($host)..."

    # Check SSH connectivity
    if ! _canary_run_with_timeout 5 ssh -o ConnectTimeout=3 -o BatchMode=yes "$host" "echo ok" &>/dev/null; then
        log_error "Cannot connect to $host"
        return 1
    fi

    # Run installer via SSH
    local installer_url="https://raw.githubusercontent.com/Dicklesworthstone/$tool/main/install.sh"

    local output
    local status=0
    local installer_url_esc mode_esc tool_esc
    installer_url_esc=$(_canary_shell_escape "$installer_url")
    mode_esc=$(_canary_shell_escape "$mode")
    tool_esc=$(_canary_shell_escape "$tool")
    local remote_cmd
    remote_cmd="curl -sSL $installer_url_esc | bash -s -- --mode $mode_esc --non-interactive && $tool_esc --version"

    output=$(ssh "$host" "$remote_cmd" 2>&1) || status=$?

    if [[ $status -eq 0 ]]; then
        log_ok "$tool installed and working on $host"
    else
        log_error "$tool canary failed on $host"
        echo "$output"
    fi

    return $status
}

# ============================================================================
# Results Storage
# ============================================================================

# Save canary results to state directory
canary_save_results() {
    local results_json="$1"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    mkdir -p "$CANARY_STATE_DIR"

    # Save latest results
    echo "$results_json" | jq --arg ts "$timestamp" '. + {timestamp: $ts}' \
        > "$CANARY_STATE_DIR/latest.json"

    # Archive with date
    local date_str
    date_str=$(date +%Y-%m-%d)
    echo "$results_json" | jq --arg ts "$timestamp" '. + {timestamp: $ts}' \
        >> "$CANARY_STATE_DIR/history-$date_str.jsonl"

    log_info "Results saved to $CANARY_STATE_DIR"
}

# Get latest canary results
canary_get_latest() {
    if [[ -f "$CANARY_STATE_DIR/latest.json" ]]; then
        cat "$CANARY_STATE_DIR/latest.json"
    else
        echo '{"error": "No canary results found"}'
        return 1
    fi
}

# ============================================================================
# Scheduling
# ============================================================================

# Setup daily canary cron job
canary_schedule() {
    local schedule="${1:-0 6 * * *}"  # Default: 6am daily

    local script_path
    script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/dsr"

    # Check if already scheduled
    if crontab -l 2>/dev/null | grep -q "dsr canary run --all"; then
        log_warn "Canary already scheduled. Updating..."
        crontab -l 2>/dev/null | grep -v "dsr canary" | crontab -
    fi

    # Add new cron entry
    (crontab -l 2>/dev/null; echo "$schedule $script_path canary run --all --json >> $CANARY_STATE_DIR/cron.log 2>&1") | crontab -

    log_ok "Canary scheduled: $schedule"
    log_info "Log file: $CANARY_STATE_DIR/cron.log"
}

# Show current schedule
canary_show_schedule() {
    if crontab -l 2>/dev/null | grep -q "dsr canary"; then
        crontab -l 2>/dev/null | grep "dsr canary"
    else
        log_info "No canary schedule configured"
    fi
}

# Remove canary from cron
canary_unschedule() {
    if crontab -l 2>/dev/null | grep -q "dsr canary"; then
        crontab -l 2>/dev/null | grep -v "dsr canary" | crontab -
        log_ok "Canary schedule removed"
    else
        log_info "No canary schedule to remove"
    fi
}
