#!/usr/bin/env bash
# quality_gates.sh - Pre-release quality gates for dsr
#
# Runs configured quality checks (lint, test, typecheck) before release.
#
# Usage:
#   source quality_gates.sh
#   qg_run_checks <tool_name> [--dry-run] [--skip-checks]
#   qg_get_checks <tool_name>  # list configured checks
#
# Check Configuration (in repos.yaml):
#   tools:
#     ntm:
#       checks:
#         - "cargo clippy --all-targets -- -D warnings"
#         - "cargo test"
#         - "cargo fmt --check"

set -uo pipefail

# Colors for output
if [[ -z "${NO_COLOR:-}" && -t 2 ]]; then
    _QG_GREEN=$'\033[0;32m'
    _QG_RED=$'\033[0;31m'
    _QG_YELLOW=$'\033[0;33m'
    _QG_BLUE=$'\033[0;34m'
    _QG_GRAY=$'\033[0;90m'
    _QG_NC=$'\033[0m'
else
    _QG_GREEN='' _QG_RED='' _QG_YELLOW='' _QG_BLUE='' _QG_GRAY='' _QG_NC=''
fi

_qg_log_info()  { echo "${_QG_BLUE}[quality]${_QG_NC} $*" >&2; }
_qg_log_ok()    { echo "${_QG_GREEN}[quality]${_QG_NC} $*" >&2; }
_qg_log_warn()  { echo "${_QG_YELLOW}[quality]${_QG_NC} $*" >&2; }
_qg_log_error() { echo "${_QG_RED}[quality]${_QG_NC} $*" >&2; }

# Get configured checks for a tool
# Usage: qg_get_checks <tool_name>
# Returns: JSON array of check commands
qg_get_checks() {
    local tool_name="$1"

    if ! command -v yq &>/dev/null; then
        _qg_log_error "yq required for reading tool configuration"
        echo '[]'
        return 3
    fi

    local repos_file="${DSR_REPOS_FILE:-${DSR_CONFIG_DIR:-$HOME/.config/dsr}/repos.yaml}"
    if [[ ! -f "$repos_file" ]]; then
        _qg_log_warn "Repos file not found: $repos_file"
        echo '[]'
        return 0
    fi

    # Use strenv() to bind $tool_name into the yq path safely.
    # $tool_name comes from `dsr quality --tool <name>` (CLI arg) so
    # could in theory carry yq metachars (`.`, `[`, `(`, …); spliced
    # interpolation would silently match the wrong key or evaluate
    # an unintended expression.  Same defense-in-depth class as the
    # round-4 config.sh fix.
    local checks
    checks=$(DSR_TOOL="$tool_name" yq -o=json '.tools[strenv(DSR_TOOL)].checks // []' "$repos_file" 2>/dev/null) || checks='[]'
    echo "$checks"
}

# Run a single check command
# Usage: _qg_run_single_check <command> <work_dir> <dry_run>
# Returns: JSON object with result
_qg_run_single_check() {
    local cmd="$1"
    local work_dir="$2"
    local dry_run="$3"

    local start_ms end_ms duration_ms exit_code=0 output=""

    # Get start time (use logging module helper if available)
    if declare -f _get_ms_timestamp &>/dev/null; then
        start_ms=$(_get_ms_timestamp)
    else
        # Fallback: prefer date +%s%3N if supported
        start_ms=$(date +%s%3N 2>/dev/null || echo "$(($(date +%s) * 1000))")
    fi

    if [[ "$dry_run" == "true" ]]; then
        _qg_log_info "(dry-run) Would run: $cmd"
        output="dry-run: skipped"
        exit_code=0
    else
        _qg_log_info "Running: $cmd"

        # Run the command in the work directory
        if [[ -n "$work_dir" && -d "$work_dir" ]]; then
            output=$(cd "$work_dir" && eval "$cmd" 2>&1) || exit_code=$?
        else
            output=$(eval "$cmd" 2>&1) || exit_code=$?
        fi
    fi

    # Get end time (use logging module helper if available)
    if declare -f _get_ms_timestamp &>/dev/null; then
        end_ms=$(_get_ms_timestamp)
    else
        # Fallback: prefer date +%s%3N if supported
        end_ms=$(date +%s%3N 2>/dev/null || echo "$(($(date +%s) * 1000))")
    fi

    duration_ms=$((end_ms - start_ms))

    # Log result
    if [[ $exit_code -eq 0 ]]; then
        _qg_log_ok "  ✓ Passed (${duration_ms}ms)"
    else
        _qg_log_error "  ✗ Failed (exit code: $exit_code)"
    fi

    # Escape output for JSON
    local escaped_output
    escaped_output=$(echo "$output" | head -c 1000 | jq -Rs '.')

    # Return JSON result
    jq -nc \
        --arg cmd "$cmd" \
        --argjson exit_code "$exit_code" \
        --argjson duration_ms "$duration_ms" \
        --argjson output "$escaped_output" \
        '{
            command: $cmd,
            exit_code: $exit_code,
            duration_ms: $duration_ms,
            passed: ($exit_code == 0),
            output: $output
        }'
}

# Run all quality checks for a tool
# Usage: qg_run_checks <tool_name> [options]
# Options:
#   --dry-run       Show checks without running them
#   --skip-checks   Skip all checks (return success)
#   --work-dir      Directory to run checks in
# Returns: JSON object with results, exits with appropriate code
qg_run_checks() {
    local tool_name=""
    local dry_run=false
    local skip_checks=false
    local work_dir=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run|-n)
                dry_run=true
                shift
                ;;
            --skip-checks)
                skip_checks=true
                shift
                ;;
            --work-dir)
                work_dir="$2"
                shift 2
                ;;
            --help|-h)
                cat << 'EOF'
Usage: qg_run_checks <tool_name> [options]

Run quality gate checks before release.

Options:
  --dry-run       Show checks without running them
  --skip-checks   Skip all checks (return success)
  --work-dir      Directory to run checks in

Exit Codes:
  0  - All checks passed
  1  - One or more checks failed
  4  - Invalid arguments or configuration
EOF
                return 0
                ;;
            -*)
                _qg_log_error "Unknown option: $1"
                return 4
                ;;
            *)
                tool_name="$1"
                shift
                ;;
        esac
    done

    if [[ -z "$tool_name" ]]; then
        _qg_log_error "Tool name required"
        return 4
    fi

    # Handle skip-checks
    if $skip_checks; then
        _qg_log_warn "Skipping quality checks (--skip-checks)"
        jq -nc --arg tool "$tool_name" '{
            tool: $tool,
            skipped: true,
            checks: [],
            passed: 0,
            failed: 0,
            total: 0,
            duration_ms: 0
        }'
        return 0
    fi

    # Get checks for tool
    local checks
    checks=$(qg_get_checks "$tool_name")

    local check_count
    check_count=$(echo "$checks" | jq 'length')

    if [[ "$check_count" -eq 0 ]]; then
        _qg_log_info "No quality checks configured for $tool_name"
        jq -nc --arg tool "$tool_name" '{
            tool: $tool,
            skipped: false,
            checks: [],
            passed: 0,
            failed: 0,
            total: 0,
            duration_ms: 0
        }'
        return 0
    fi

    _qg_log_info "Running $check_count quality check(s) for $tool_name"
    $dry_run && _qg_log_info "(dry-run mode)"
    echo "" >&2

    # Run each check
    local results=()
    local total_start_ms total_end_ms
    local passed=0 failed=0

    if declare -f _get_ms_timestamp &>/dev/null; then
        total_start_ms=$(_get_ms_timestamp)
    else
        total_start_ms=$(date +%s%3N 2>/dev/null || echo "$(($(date +%s) * 1000))")
    fi

    while IFS= read -r cmd; do
        [[ -z "$cmd" ]] && continue

        local result
        result=$(_qg_run_single_check "$cmd" "$work_dir" "$dry_run")
        results+=("$result")

        local check_passed
        check_passed=$(echo "$result" | jq -r '.passed')
        if [[ "$check_passed" == "true" ]]; then
            ((passed++))
        else
            ((failed++))
        fi
    done < <(echo "$checks" | jq -r '.[]')

    if declare -f _get_ms_timestamp &>/dev/null; then
        total_end_ms=$(_get_ms_timestamp)
    else
        total_end_ms=$(date +%s%3N 2>/dev/null || echo "$(($(date +%s) * 1000))")
    fi

    local total_duration_ms=$((total_end_ms - total_start_ms))

    echo "" >&2

    # Build results JSON
    local checks_json
    if [[ ${#results[@]} -gt 0 ]]; then
        checks_json=$(printf '%s\n' "${results[@]}" | jq -s '.')
    else
        checks_json='[]'
    fi

    local result_json
    result_json=$(jq -nc \
        --arg tool "$tool_name" \
        --argjson dry_run "$dry_run" \
        --argjson checks "$checks_json" \
        --argjson passed "$passed" \
        --argjson failed "$failed" \
        --argjson total "$check_count" \
        --argjson duration_ms "$total_duration_ms" \
        '{
            tool: $tool,
            dry_run: $dry_run,
            skipped: false,
            checks: $checks,
            passed: $passed,
            failed: $failed,
            total: $total,
            duration_ms: $duration_ms
        }')

    # Output result
    echo "$result_json"

    # Log summary
    if [[ $failed -gt 0 ]]; then
        _qg_log_error "Quality gates FAILED: $passed/$check_count passed"
        return 1
    else
        _qg_log_ok "Quality gates passed: $passed/$check_count checks (${total_duration_ms}ms)"
        return 0
    fi
}

# Export functions
export -f qg_get_checks qg_run_checks _qg_run_single_check
