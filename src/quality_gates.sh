#!/usr/bin/env bash
# quality_gates.sh - Pre-release quality gates for dsr
#
# Runs configured quality checks (lint, test, typecheck) before release,
# FAIL-CLOSED with evidence-complete aggregate receipts (frankensim bead
# oxmp): missing/malformed/unreadable configuration and zero derived
# checks are hard failures, never silent successes; dry-run entries are
# Planned/NotExecuted and can never increment passed counts; every
# executed command retains a complete durable log (argv, cwd, env
# subset, exit status, sha256); the aggregate receipt binds the DSR
# version, config hash, ordered checks, log hashes, and before/after
# source + lock snapshots — a tree that moves during the run
# invalidates the aggregate.
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
#         - "cargo clippy --all-targets --locked -- -D warnings"
#         - "cargo test --locked"
#         - "cargo fmt --check"
#
# Exit codes (qg_run_checks):
#   0 - every configured check EXECUTED and passed
#   1 - one or more checks failed, or the source moved during the run
#   2 - dry run: checks planned, none executed (never a pass)
#   4 - configuration failure (missing/malformed/unreadable/zero checks)

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

# Portable sha256 of a file; "-" hashes stdin.
_qg_sha256() {
    if command -v sha256sum &>/dev/null; then
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    else
        shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
    fi
}

_qg_now_ms() {
    if declare -f _get_ms_timestamp &>/dev/null; then
        _get_ms_timestamp
        return
    fi
    # BSD date has no %3N (prints it literally) — validate before use.
    local ms
    ms=$(date +%s%3N 2>/dev/null)
    if [[ "$ms" =~ ^[0-9]+$ ]]; then
        echo "$ms"
    else
        echo "$(($(date +%s) * 1000))"
    fi
}

# Snapshot the source state of a work dir: git HEAD, a hash of the
# porcelain dirt listing, and the lock-file hash (empty markers when not
# a git repo / no lockfile). One line: head|dirt_sha|lock_sha
_qg_source_snapshot() {
    local dir="${1:-.}"
    local head dirt_sha lock_sha
    head=$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo "not-a-git-repo")
    dirt_sha=$(git -C "$dir" status --porcelain --untracked-files=all 2>/dev/null \
        | { command -v sha256sum &>/dev/null && sha256sum || shasum -a 256; } \
        | awk '{print $1}')
    if [[ -f "$dir/Cargo.lock" ]]; then
        lock_sha=$(_qg_sha256 "$dir/Cargo.lock")
    else
        lock_sha="no-lockfile"
    fi
    echo "${head}|${dirt_sha}|${lock_sha}"
}

# Get configured checks for a tool — FAIL CLOSED (bead oxmp): a missing
# file, unreadable file, malformed YAML, or absent tool key is a
# CONFIGURATION FAILURE (rc 4), never an empty success.
# Usage: qg_get_checks <tool_name>
# Returns: JSON array of check commands on stdout; rc per header.
qg_get_checks() {
    local tool_name="$1"

    if ! command -v yq &>/dev/null; then
        _qg_log_error "yq required for reading tool configuration"
        return 3
    fi

    local repos_file="${DSR_REPOS_FILE:-${DSR_CONFIG_DIR:-$HOME/.config/dsr}/repos.yaml}"
    if [[ ! -f "$repos_file" ]]; then
        _qg_log_error "Repos file not found: $repos_file (a release gate cannot vacuously pass)"
        return 4
    fi
    if [[ ! -r "$repos_file" ]]; then
        _qg_log_error "Repos file not readable: $repos_file"
        return 4
    fi

    # Malformed YAML must surface, not silently become [].
    if ! yq -e '.' "$repos_file" >/dev/null 2>&1; then
        _qg_log_error "Repos file is not valid YAML: $repos_file"
        return 4
    fi

    # Use strenv() to bind $tool_name into the yq path safely.
    # $tool_name comes from `dsr quality --tool <name>` (CLI arg) so
    # could in theory carry yq metachars (`.`, `[`, `(`, …); spliced
    # interpolation would silently match the wrong key or evaluate
    # an unintended expression.  Same defense-in-depth class as the
    # round-4 config.sh fix.
    local has_tool
    has_tool=$(DSR_TOOL="$tool_name" yq -r '.tools | has(strenv(DSR_TOOL))' "$repos_file" 2>/dev/null)
    if [[ "$has_tool" != "true" ]]; then
        # Legacy layouts keep tools at the top level; accept either, but
        # an unknown tool is a configuration failure.
        has_tool=$(DSR_TOOL="$tool_name" yq -r 'has(strenv(DSR_TOOL))' "$repos_file" 2>/dev/null)
        if [[ "$has_tool" != "true" ]]; then
            _qg_log_error "Tool '$tool_name' is not configured in $repos_file"
            return 4
        fi
        DSR_TOOL="$tool_name" yq -o=json '.[strenv(DSR_TOOL)].checks // []' "$repos_file" 2>/dev/null
        return 0
    fi

    DSR_TOOL="$tool_name" yq -o=json '.tools[strenv(DSR_TOOL)].checks // []' "$repos_file" 2>/dev/null
}

# Run a single check command
# Usage: _qg_run_single_check <command> <work_dir> <dry_run> <log_file>
# Returns: JSON object with result. Dry-run entries carry
# status="planned", executed=false and MUST NOT be counted as passed.
_qg_run_single_check() {
    local cmd="$1"
    local work_dir="$2"
    local dry_run="$3"
    local log_file="$4"

    local start_ms end_ms duration_ms exit_code=0
    start_ms=$(_qg_now_ms)

    if [[ "$dry_run" == "true" ]]; then
        _qg_log_info "(dry-run) Planned, NOT executed: $cmd"
        jq -nc --arg cmd "$cmd" '{
            command: $cmd,
            status: "planned",
            executed: false,
            passed: false,
            exit_code: null,
            duration_ms: 0,
            output_preview: "dry-run: not executed",
            log_path: null,
            log_sha256: null
        }'
        return 0
    fi

    _qg_log_info "Running: $cmd"
    local resolved_cwd
    resolved_cwd=$(cd "${work_dir:-.}" 2>/dev/null && pwd || pwd)
    # Complete durable log: header with exact argv/cwd/env subset, then
    # the FULL command output (no truncation — bead oxmp).
    {
        echo "# dsr quality check"
        echo "# argv: $cmd"
        echo "# cwd: $resolved_cwd"
        echo "# env: PATH=$PATH"
        env | LC_ALL=C grep -E '^(DSR_|CARGO_|RUST)' | sed 's/^/# env: /' || true
        echo "# started_ms: $start_ms"
        echo "# ----"
    } > "$log_file"

    if [[ -n "$work_dir" && -d "$work_dir" ]]; then
        (cd "$work_dir" && eval "$cmd") >> "$log_file" 2>&1 || exit_code=$?
    else
        (eval "$cmd") >> "$log_file" 2>&1 || exit_code=$?
    fi
    echo "# exit_code: $exit_code" >> "$log_file"

    end_ms=$(_qg_now_ms)
    duration_ms=$((end_ms - start_ms))

    if [[ $exit_code -eq 0 ]]; then
        _qg_log_ok "  ✓ Passed (${duration_ms}ms)"
    else
        _qg_log_error "  ✗ Failed (exit code: $exit_code) — full log: $log_file"
    fi

    local preview log_sha
    preview=$(tail -c 1000 "$log_file" | jq -Rs '.')
    log_sha=$(_qg_sha256 "$log_file")

    jq -nc \
        --arg cmd "$cmd" \
        --arg cwd "$resolved_cwd" \
        --argjson exit_code "$exit_code" \
        --argjson duration_ms "$duration_ms" \
        --argjson preview "$preview" \
        --arg log_path "$log_file" \
        --arg log_sha "$log_sha" \
        '{
            command: $cmd,
            status: (if $exit_code == 0 then "passed" else "failed" end),
            executed: true,
            passed: ($exit_code == 0),
            exit_code: $exit_code,
            cwd: $cwd,
            duration_ms: $duration_ms,
            output_preview: $preview,
            log_path: $log_path,
            log_sha256: $log_sha
        }'
}

# Run all quality checks for a tool
# Usage: qg_run_checks <tool_name> [options]
# Options:
#   --dry-run       Plan checks without executing (exit 2, never a pass)
#   --skip-checks   Skip all checks (return success; explicit operator bypass)
#   --work-dir      Directory to run checks in
# Returns: evidence-complete aggregate receipt JSON on stdout; also
# retained durably next to the per-check logs. Exit codes per header.
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

Run quality gate checks before release (fail-closed, evidence-complete).

Options:
  --dry-run       Plan checks without executing (exit 2, never a pass)
  --skip-checks   Skip all checks (explicit operator bypass)
  --work-dir      Directory to run checks in

Exit Codes:
  0  - All checks EXECUTED and passed
  1  - One or more checks failed, or the source moved during the run
  2  - Dry run: planned only, nothing executed
  4  - Invalid arguments or configuration (missing/malformed/zero checks)
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

    # Handle skip-checks (an explicit operator bypass, visibly labeled)
    if $skip_checks; then
        _qg_log_warn "Skipping quality checks (--skip-checks)"
        jq -nc --arg tool "$tool_name" '{
            tool: $tool,
            status: "skipped",
            skipped: true,
            checks: [],
            passed: 0,
            failed: 0,
            planned: 0,
            total: 0,
            duration_ms: 0
        }'
        return 0
    fi

    # Get checks for tool — configuration failures are HARD failures.
    local checks rc=0
    checks=$(qg_get_checks "$tool_name") || rc=$?
    if [[ $rc -ne 0 ]]; then
        jq -nc --arg tool "$tool_name" --argjson rc "$rc" '{
            tool: $tool,
            status: "config-error",
            skipped: false,
            checks: [],
            passed: 0,
            failed: 0,
            planned: 0,
            total: 0,
            duration_ms: 0,
            config_rc: $rc
        }'
        return 4
    fi

    local check_count
    check_count=$(echo "$checks" | jq 'length' 2>/dev/null) || check_count=0

    if [[ "$check_count" -eq 0 ]]; then
        # Zero derived checks would make the release gate vacuous —
        # hard failure (bead oxmp), never a silent success.
        _qg_log_error "No quality checks configured for $tool_name — a release gate with zero checks proves nothing"
        jq -nc --arg tool "$tool_name" '{
            tool: $tool,
            status: "config-error",
            skipped: false,
            checks: [],
            passed: 0,
            failed: 0,
            planned: 0,
            total: 0,
            duration_ms: 0
        }'
        return 4
    fi

    local repos_file="${DSR_REPOS_FILE:-${DSR_CONFIG_DIR:-$HOME/.config/dsr}/repos.yaml}"
    local run_dir="${DSR_QUALITY_LOG_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsr/quality-logs}/${tool_name}/$(date +%Y%m%dT%H%M%S)-$$"
    mkdir -p "$run_dir"

    local snapshot_before
    snapshot_before=$(_qg_source_snapshot "${work_dir:-.}")

    _qg_log_info "Running $check_count quality check(s) for $tool_name"
    $dry_run && _qg_log_warn "(dry-run mode: checks are PLANNED, not executed — this cannot pass the gate)"
    echo "" >&2

    # Run each check
    local results=()
    local total_start_ms total_end_ms
    local passed=0 failed=0 planned=0 idx=0
    total_start_ms=$(_qg_now_ms)

    while IFS= read -r cmd; do
        [[ -z "$cmd" ]] && continue
        idx=$((idx + 1))

        local result status
        result=$(_qg_run_single_check "$cmd" "$work_dir" "$dry_run" "$run_dir/check-$idx.log")
        results+=("$result")

        status=$(echo "$result" | jq -r '.status')
        case "$status" in
            passed)  passed=$((passed + 1)) ;;
            planned) planned=$((planned + 1)) ;;
            *)       failed=$((failed + 1)) ;;
        esac
    done < <(echo "$checks" | jq -r '.[]')

    total_end_ms=$(_qg_now_ms)
    local total_duration_ms=$((total_end_ms - total_start_ms))
    echo "" >&2

    local snapshot_after
    snapshot_after=$(_qg_source_snapshot "${work_dir:-.}")
    local moving=false
    if ! $dry_run && [[ "$snapshot_before" != "$snapshot_after" ]]; then
        moving=true
        _qg_log_error "Source state moved during the run (before: $snapshot_before, after: $snapshot_after) — the aggregate cannot bind a moving tree"
    fi

    # Build results JSON
    local checks_json
    if [[ ${#results[@]} -gt 0 ]]; then
        checks_json=$(printf '%s\n' "${results[@]}" | jq -s '.')
    else
        checks_json='[]'
    fi

    local overall
    if $dry_run; then
        overall="planned"
    elif $moving; then
        overall="invalidated-moving-source"
    elif [[ $failed -gt 0 ]]; then
        overall="failed"
    else
        overall="passed"
    fi

    local config_sha
    config_sha=$(_qg_sha256 "$repos_file")

    local result_json
    result_json=$(jq -nc \
        --arg tool "$tool_name" \
        --arg status "$overall" \
        --arg dsr_version "${DSR_VERSION:-unversioned}" \
        --arg config_path "$repos_file" \
        --arg config_sha "$config_sha" \
        --arg snap_before "$snapshot_before" \
        --arg snap_after "$snapshot_after" \
        --arg run_dir "$run_dir" \
        --argjson dry_run "$dry_run" \
        --argjson checks "$checks_json" \
        --argjson passed "$passed" \
        --argjson failed "$failed" \
        --argjson planned "$planned" \
        --argjson total "$check_count" \
        --argjson duration_ms "$total_duration_ms" \
        '{
            tool: $tool,
            status: $status,
            dry_run: $dry_run,
            skipped: false,
            dsr_version: $dsr_version,
            config_path: $config_path,
            config_sha256: $config_sha,
            source_before: $snap_before,
            source_after: $snap_after,
            run_dir: $run_dir,
            checks: $checks,
            passed: $passed,
            failed: $failed,
            planned: $planned,
            total: $total,
            duration_ms: $duration_ms
        }')

    # Durable aggregate receipt next to the per-check logs.
    echo "$result_json" > "$run_dir/receipt.json"

    # Output result
    echo "$result_json"

    # Log summary + exit per contract
    if $dry_run; then
        _qg_log_warn "Dry run: $planned/$check_count planned, 0 executed — not a pass"
        return 2
    fi
    if $moving; then
        return 1
    fi
    if [[ $failed -gt 0 ]]; then
        _qg_log_error "Quality gates FAILED: $passed/$check_count passed — receipt: $run_dir/receipt.json"
        return 1
    fi
    _qg_log_ok "Quality gates passed: $passed/$check_count checks (${total_duration_ms}ms) — receipt: $run_dir/receipt.json"
    return 0
}

# Export functions
export -f qg_get_checks qg_run_checks 2>/dev/null || true
