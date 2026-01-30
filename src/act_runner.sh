#!/usr/bin/env bash
# act_runner.sh - nektos/act integration for dsr
#
# Usage:
#   source act_runner.sh
#   act_run_workflow <repo_path> <workflow> [job] [event]
#
# This module handles running GitHub Actions workflows locally via act,
# collecting artifacts, and returning structured results.

set -uo pipefail

# Configuration (can be overridden)
ACT_ARTIFACTS_DIR="${ACT_ARTIFACTS_DIR:-/tmp/dsr-act-artifacts}"
ACT_LOGS_DIR="${ACT_LOGS_DIR:-/tmp/dsr-act-logs}"
ACT_TIMEOUT="${ACT_TIMEOUT:-3600}"  # 1 hour default

# Colors for output (if not disabled)
if [[ -z "${NO_COLOR:-}" && -t 2 ]]; then
    _RED=$'\033[0;31m'
    _GREEN=$'\033[0;32m'
    _YELLOW=$'\033[0;33m'
    _BLUE=$'\033[0;34m'
    _NC=$'\033[0m'
else
    _RED='' _GREEN='' _YELLOW='' _BLUE='' _NC=''
fi

_log_info()  { echo "${_BLUE}[act]${_NC} $*" >&2; }
_log_ok()    { echo "${_GREEN}[act]${_NC} $*" >&2; }
_log_warn()  { echo "${_YELLOW}[act]${_NC} $*" >&2; }
_log_error() { echo "${_RED}[act]${_NC} $*" >&2; }

# Check if act is available
act_check() {
    if ! command -v act &>/dev/null; then
        _log_error "act not found. Install: brew install act (macOS) or go install github.com/nektos/act@latest"
        return 3
    fi

    if ! docker info &>/dev/null; then
        _log_error "Docker daemon not running or not accessible"
        return 3
    fi

    return 0
}

# List jobs in a workflow
# Usage: act_list_jobs <workflow_file>
# Returns: JSON array of job definitions
act_list_jobs() {
    local workflow="$1"

    if [[ ! -f "$workflow" ]]; then
        _log_error "Workflow file not found: $workflow"
        return 4
    fi

    # Parse workflow YAML to extract job info
    # act -l outputs: Stage  Job ID  Job name  Workflow name  Workflow file  Events
    act -l -W "$workflow" 2>/dev/null | tail -n +2 | while IFS=$'\t' read -r stage job_id job_name workflow_name workflow_file events; do
        echo "$job_id"
    done
}

# Get runs-on value for a job
# Usage: act_get_runner <workflow_file> <job_id>
act_get_runner() {
    local workflow="$1"
    local job_id="$2"

    # Parse YAML to get runs-on (simplified, assumes standard format)
    # For complex cases, use yq
    if command -v yq &>/dev/null; then
        yq ".jobs.$job_id.runs-on" "$workflow" 2>/dev/null
    else
        # Fallback: grep-based extraction (handles simple cases)
        awk -v job="$job_id:" '
            $0 ~ job { in_job=1 }
            in_job && /runs-on:/ { gsub(/.*runs-on:[ ]*/, ""); gsub(/["\047]/, ""); print; exit }
            in_job && /^[a-z]/ && $0 !~ job { exit }
        ' "$workflow"
    fi
}

# Check if a job can run via act (Linux runner)
# Usage: act_can_run <runs_on_value>
# Returns: 0 if can run, 1 if needs native runner
act_can_run() {
    local runs_on="$1"

    case "$runs_on" in
        ubuntu-*|ubuntu-latest)
            return 0
            ;;
        macos-*|macos-latest|windows-*|windows-latest)
            return 1
            ;;
        self-hosted*)
            # Check for linux label
            if [[ "$runs_on" == *"linux"* ]]; then
                return 0
            fi
            return 1
            ;;
        *)
            _log_warn "Unknown runner: $runs_on, assuming Linux"
            return 0
            ;;
    esac
}

# Run a workflow via act
# Usage: act_run_workflow <repo_path> <workflow> [job] [event] [extra_args...]
# Returns: exit code (0=success, 1=partial, 6=build failed, 3=dependency error)
act_run_workflow() {
    local repo_path="$1"
    local workflow="$2"
    local job="${3:-}"
    local event="${4:-push}"
    shift 4 2>/dev/null || true
    local extra_args=("$@")

    if ! act_check; then
        return 3
    fi

    local workflow_path="$repo_path/$workflow"
    if [[ ! -f "$workflow_path" ]]; then
        _log_error "Workflow not found: $workflow_path"
        return 4
    fi

    # Create run directories
    local run_id
    run_id="$(date +%Y%m%d-%H%M%S)-$$"
    local artifact_dir="$ACT_ARTIFACTS_DIR/$run_id"
    local log_file="$ACT_LOGS_DIR/$run_id.log"

    mkdir -p "$artifact_dir" "$ACT_LOGS_DIR"

    # Build act command
    local act_cmd=(
        act
        -W "$workflow"
        --artifact-server-path "$artifact_dir"
    )

    # Add job filter if specified
    if [[ -n "$job" ]]; then
        act_cmd+=(-j "$job")
    fi

    # Add event
    act_cmd+=("$event")

    # Add any extra arguments
    if [[ ${#extra_args[@]} -gt 0 ]]; then
        act_cmd+=("${extra_args[@]}")
    fi

    _log_info "Running: ${act_cmd[*]}"
    _log_info "Artifacts: $artifact_dir"
    _log_info "Log: $log_file"

    local start_time
    start_time=$(date +%s)

    # Run act with timeout
    local exit_code=0
    if ! timeout "$ACT_TIMEOUT" "${act_cmd[@]}" \
        --directory "$repo_path" \
        2>&1 | tee "$log_file"; then
        exit_code=$?
    fi

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    # Output results as JSON (to stdout)
    local artifact_count
    artifact_count=$(find "$artifact_dir" -type f 2>/dev/null | wc -l)

    if [[ "$exit_code" -eq 0 ]]; then
        _log_ok "Workflow completed successfully in ${duration}s"
        local status="success"
    elif [[ "$exit_code" -eq 124 ]]; then
        _log_error "Workflow timed out after ${ACT_TIMEOUT}s"
        status="timeout"
        exit_code=5
    else
        _log_error "Workflow failed with exit code $exit_code"
        status="failed"
        exit_code=6
    fi

    # Return JSON result
    cat <<EOF
{
  "run_id": "$run_id",
  "workflow": "$workflow",
  "job": "${job:-all}",
  "status": "$status",
  "exit_code": $exit_code,
  "duration_seconds": $duration,
  "artifact_dir": "$artifact_dir",
  "artifact_count": $artifact_count,
  "log_file": "$log_file"
}
EOF

    return "$exit_code"
}

# Collect artifacts from act run
# Usage: act_collect_artifacts <artifact_dir> <output_dir>
act_collect_artifacts() {
    local artifact_dir="$1"
    local output_dir="$2"

    if [[ ! -d "$artifact_dir" ]]; then
        _log_error "Artifact directory not found: $artifact_dir"
        return 1
    fi

    mkdir -p "$output_dir"

    # act stores artifacts in subdirectories by artifact name
    local count=0
    while IFS= read -r -d '' artifact; do
        local basename
        basename=$(basename "$artifact")
        cp "$artifact" "$output_dir/$basename"
        _log_info "Collected: $basename"
        ((count++))
    done < <(find "$artifact_dir" -type f -print0)

    _log_ok "Collected $count artifacts"
    return 0
}

# Parse workflow to identify platform targets
# Usage: act_analyze_workflow <workflow_file>
# Returns: JSON with platform breakdown
act_analyze_workflow() {
    local workflow="$1"

    if [[ ! -f "$workflow" ]]; then
        _log_error "Workflow not found: $workflow"
        return 4
    fi

    local linux_jobs=()
    local macos_jobs=()
    local windows_jobs=()
    local other_jobs=()

    # Parse workflow to categorize jobs by runner
    while IFS= read -r job_id; do
        local runner
        runner=$(act_get_runner "$workflow" "$job_id")

        case "$runner" in
            ubuntu-*|*linux*)
                linux_jobs+=("$job_id")
                ;;
            macos-*)
                macos_jobs+=("$job_id")
                ;;
            windows-*)
                windows_jobs+=("$job_id")
                ;;
            *)
                other_jobs+=("$job_id")
                ;;
        esac
    done < <(act_list_jobs "$workflow")

    # Output JSON analysis
    cat <<EOF
{
  "workflow": "$workflow",
  "linux_jobs": $(printf '%s\n' "${linux_jobs[@]}" | jq -R . | jq -s .),
  "macos_jobs": $(printf '%s\n' "${macos_jobs[@]}" | jq -R . | jq -s .),
  "windows_jobs": $(printf '%s\n' "${windows_jobs[@]}" | jq -R . | jq -s .),
  "other_jobs": $(printf '%s\n' "${other_jobs[@]}" | jq -R . | jq -s .),
  "act_compatible": ${#linux_jobs[@]},
  "native_required": $((${#macos_jobs[@]} + ${#windows_jobs[@]}))
}
EOF
}

# Clean up old act artifacts
# Usage: act_cleanup [days]
act_cleanup() {
    local days="${1:-7}"

    _log_info "Cleaning artifacts older than $days days..."

    find "$ACT_ARTIFACTS_DIR" -type d -mtime +"$days" -exec rm -rf {} + 2>/dev/null || true
    find "$ACT_LOGS_DIR" -type f -mtime +"$days" -delete 2>/dev/null || true

    _log_ok "Cleanup complete"
}

# Export functions for use by other scripts
export -f act_check act_list_jobs act_get_runner act_can_run
export -f act_run_workflow act_collect_artifacts act_analyze_workflow act_cleanup
