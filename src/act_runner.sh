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
ACT_ARTIFACTS_DIR="${ACT_ARTIFACTS_DIR:-${DSR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsr}/artifacts}"
ACT_LOGS_DIR="${ACT_LOGS_DIR:-${DSR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsr}/logs/$(date +%Y-%m-%d)/builds}"
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
    act -l -W "$workflow" 2>/dev/null | tail -n +2 | while IFS=$'\t' read -r _ job_id _ _ _ _; do
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
        ubuntu-*)
            return 0
            ;;
        macos-*|windows-*)
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
    # Use PIPESTATUS to capture the actual command exit code, not tee's
    timeout "$ACT_TIMEOUT" "${act_cmd[@]}" \
        --directory "$repo_path" \
        2>&1 | tee "$log_file"
    local exit_code=${PIPESTATUS[0]}

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    # Output results as JSON (to stdout)
    local artifact_count status
    artifact_count=$(find "$artifact_dir" -type f 2>/dev/null | wc -l)

    if [[ "$exit_code" -eq 0 ]]; then
        _log_ok "Workflow completed successfully in ${duration}s"
        status="success"
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

    # Helper to convert array to JSON array (handles empty arrays correctly)
    _array_to_json() {
        if [[ $# -eq 0 ]]; then
            echo "[]"
        else
            printf '%s\n' "$@" | jq -R . | jq -s .
        fi
    }

    # Output JSON analysis
    cat <<EOF
{
  "workflow": "$workflow",
  "linux_jobs": $(_array_to_json "${linux_jobs[@]+"${linux_jobs[@]}"}"),
  "macos_jobs": $(_array_to_json "${macos_jobs[@]+"${macos_jobs[@]}"}"),
  "windows_jobs": $(_array_to_json "${windows_jobs[@]+"${windows_jobs[@]}"}"),
  "other_jobs": $(_array_to_json "${other_jobs[@]+"${other_jobs[@]}"}"),
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

# ============================================================================
# Compatibility Matrix Functions
# ============================================================================

# Configuration directories
ACT_CONFIG_DIR="${DSR_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/dsr}"
ACT_REPOS_DIR="${ACT_CONFIG_DIR}/repos.d"

# Load repo configuration
# Usage: act_load_repo_config <tool_name>
# Returns: Sets global ACT_REPO_* variables
act_load_repo_config() {
    local tool_name="$1"
    local config_file="$ACT_REPOS_DIR/${tool_name}.yaml"

    if [[ ! -f "$config_file" ]]; then
        _log_error "Repo config not found: $config_file"
        return 4
    fi

    # Check for yq
    if ! command -v yq &>/dev/null; then
        _log_error "yq required for config parsing. Install: brew install yq"
        return 3
    fi

    # Load config into variables
    ACT_REPO_NAME=$(yq -r '.tool_name // empty' "$config_file")
    ACT_REPO_GITHUB=$(yq -r '.repo // empty' "$config_file")
    ACT_REPO_LOCAL_PATH=$(yq -r '.local_path // empty' "$config_file")
    ACT_REPO_LANGUAGE=$(yq -r '.language // empty' "$config_file")
    ACT_REPO_WORKFLOW=$(yq -r '.workflow // ".github/workflows/release.yml"' "$config_file")

    export ACT_REPO_NAME ACT_REPO_GITHUB ACT_REPO_LOCAL_PATH ACT_REPO_LANGUAGE ACT_REPO_WORKFLOW

    _log_info "Loaded config for $tool_name: $ACT_REPO_GITHUB"
    return 0
}

# Get act job for a target platform
# Usage: act_get_job_for_target <tool_name> <platform>
# Returns: Job name or empty if native build required
act_get_job_for_target() {
    local tool_name="$1"
    local platform="$2"
    local config_file="$ACT_REPOS_DIR/${tool_name}.yaml"

    if [[ ! -f "$config_file" ]]; then
        _log_error "Repo config not found: $config_file"
        return 4
    fi

    # Use yq to extract the job mapping
    # Format in YAML: act_job_map.linux/amd64: build-linux
    local job
    job=$(yq -r ".act_job_map.\"$platform\" // empty" "$config_file" 2>/dev/null)

    # Handle null values (native build required)
    if [[ "$job" == "null" || -z "$job" ]]; then
        echo ""
        return 1  # Native build required
    fi

    echo "$job"
    return 0
}

# Check if a platform can be built via act
# Usage: act_platform_uses_act <tool_name> <platform>
# Returns: 0 if act, 1 if native
act_platform_uses_act() {
    local tool_name="$1"
    local platform="$2"

    local job
    job=$(act_get_job_for_target "$tool_name" "$platform")

    if [[ -n "$job" ]]; then
        return 0  # Uses act
    else
        return 1  # Native build
    fi
}

# Get act flags for a tool/platform combination
# Usage: act_get_flags <tool_name> <platform>
# Returns: Array of act flags as space-separated string
act_get_flags() {
    local tool_name="$1"
    local platform="$2"
    local config_file="$ACT_REPOS_DIR/${tool_name}.yaml"

    if [[ ! -f "$config_file" ]]; then
        echo ""
        return 4
    fi

    local flags=()

    # Get platform-specific image override
    local image
    image=$(yq -r ".act_overrides.platform_image // empty" "$config_file" 2>/dev/null)
    if [[ -n "$image" ]]; then
        flags+=("-P ubuntu-latest=$image")
    fi

    # Get secrets file if specified
    local secrets_file
    secrets_file=$(yq -r ".act_overrides.secrets_file // empty" "$config_file" 2>/dev/null)
    if [[ -n "$secrets_file" ]]; then
        flags+=("--secret-file $secrets_file")
    fi

    # Get env file if specified
    local env_file
    env_file=$(yq -r ".act_overrides.env_file // empty" "$config_file" 2>/dev/null)
    if [[ -n "$env_file" ]]; then
        flags+=("--env-file $env_file")
    fi

    # Platform-specific flags
    if [[ "$platform" == "linux/arm64" ]]; then
        # Check for ARM64 specific overrides
        local arm64_flags
        arm64_flags=$(yq -r '.act_overrides.linux_arm64_flags[]? // empty' "$config_file" 2>/dev/null)
        if [[ -n "$arm64_flags" ]]; then
            while IFS= read -r flag; do
                flags+=("$flag")
            done <<< "$arm64_flags"
        fi
    fi

    echo "${flags[*]}"
}

# Get all targets for a tool
# Usage: act_get_targets <tool_name>
# Returns: Space-separated list of platforms
act_get_targets() {
    local tool_name="$1"
    local config_file="$ACT_REPOS_DIR/${tool_name}.yaml"

    if [[ ! -f "$config_file" ]]; then
        echo ""
        return 4
    fi

    yq -r '.targets[]' "$config_file" 2>/dev/null | tr '\n' ' '
}

# Get native host for a platform
# Usage: act_get_native_host <platform>
# Returns: Host name (trj, mmini, wlap) or empty
act_get_native_host() {
    local platform="$1"

    case "$platform" in
        linux/amd64|linux/arm64)
            echo "trj"
            ;;
        darwin/arm64|darwin/amd64)
            echo "mmini"
            ;;
        windows/amd64)
            echo "wlap"
            ;;
        *)
            echo ""
            return 1
            ;;
    esac
}

# Get build strategy for a tool/platform
# Usage: act_get_build_strategy <tool_name> <platform>
# Returns: JSON with method, host, job info
act_get_build_strategy() {
    local tool_name="$1"
    local platform="$2"

    local job host method

    if act_platform_uses_act "$tool_name" "$platform"; then
        job=$(act_get_job_for_target "$tool_name" "$platform")
        host="trj"
        method="act"
    else
        job=""
        host=$(act_get_native_host "$platform")
        method="native"
    fi

    cat <<EOF
{
  "tool": "$tool_name",
  "platform": "$platform",
  "method": "$method",
  "host": "$host",
  "job": "$job"
}
EOF
}

# List all configured tools
# Usage: act_list_tools
# Returns: List of tool names
act_list_tools() {
    if [[ ! -d "$ACT_REPOS_DIR" ]]; then
        _log_warn "Repos directory not found: $ACT_REPOS_DIR"
        return 1
    fi

    # Use nullglob to handle empty directory gracefully
    local old_nullglob
    old_nullglob=$(shopt -p nullglob || true)
    shopt -s nullglob

    for config in "$ACT_REPOS_DIR"/*.yaml; do
        # Skip template files (start with _)
        if [[ ! "$(basename "$config")" =~ ^_ ]]; then
            basename "$config" .yaml
        fi
    done

    # Restore previous nullglob setting
    eval "$old_nullglob" 2>/dev/null || shopt -u nullglob
}

# Generate full build matrix for a tool
# Usage: act_build_matrix <tool_name>
# Returns: JSON array of build strategies
act_build_matrix() {
    local tool_name="$1"
    local targets strategies=()

    targets=$(act_get_targets "$tool_name")

    for target in $targets; do
        local strategy
        strategy=$(act_get_build_strategy "$tool_name" "$target")
        strategies+=("$strategy")
    done

    if [[ ${#strategies[@]} -eq 0 ]]; then
        echo "[]"
    else
        printf '%s\n' "${strategies[@]}" | jq -s '.'
    fi
}

# ============================================================================
# Hybrid Build Orchestration (act + SSH)
# ============================================================================

# SSH settings for native builds
_ACT_SSH_TIMEOUT="${DSR_SSH_TIMEOUT:-30}"
_ACT_BUILD_TIMEOUT="${DSR_BUILD_TIMEOUT:-3600}"

# Get build command from config
# Usage: act_get_build_cmd <tool_name>
act_get_build_cmd() {
    local tool_name="$1"
    local config_file="$ACT_REPOS_DIR/${tool_name}.yaml"

    if [[ ! -f "$config_file" ]]; then
        return 4
    fi

    yq -r '.build_cmd // ""' "$config_file" 2>/dev/null
}

# Get environment variables for a build target
# Usage: act_get_build_env <tool_name> <platform>
# Returns: Space-separated KEY=VALUE pairs
act_get_build_env() {
    local tool_name="$1"
    local platform="$2"
    local config_file="$ACT_REPOS_DIR/${tool_name}.yaml"

    if [[ ! -f "$config_file" ]]; then
        echo ""
        return 4
    fi

    local result=""

    # Get global env vars
    local global_env
    global_env=$(yq -r '.env // {} | to_entries | map(.key + "=" + .value) | .[]' "$config_file" 2>/dev/null)
    [[ -n "$global_env" ]] && result="$global_env"

    # Get platform-specific cross_compile env vars
    local platform_env
    platform_env=$(yq -r ".cross_compile.\"$platform\".env // {} | to_entries | map(.key + \"=\" + .value) | .[]" "$config_file" 2>/dev/null)
    [[ -n "$platform_env" ]] && result="$result $platform_env"

    echo "$result"
}

# Get local path for a tool
# Usage: act_get_local_path <tool_name>
act_get_local_path() {
    local tool_name="$1"
    local config_file="$ACT_REPOS_DIR/${tool_name}.yaml"

    if [[ ! -f "$config_file" ]]; then
        return 4
    fi

    yq -r '.local_path // ""' "$config_file" 2>/dev/null
}

# Execute command on remote host via SSH
# Usage: _act_ssh_exec <host> <command> [timeout]
# Returns: Exit code from remote command
_act_ssh_exec() {
    local host="$1"
    local cmd="$2"
    local timeout_sec="${3:-$_ACT_BUILD_TIMEOUT}"

    timeout "$timeout_sec" ssh \
        -o ConnectTimeout="$_ACT_SSH_TIMEOUT" \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new \
        "$host" "$cmd"
}

# Run native build on remote host via SSH
# Usage: act_run_native_build <tool_name> <platform> <version> [run_id]
# Returns: JSON result with status, exit_code, artifact info
act_run_native_build() {
    local tool_name="$1"
    local platform="$2"
    local version="$3"
    local run_id="${4:-}"

    local host
    host=$(act_get_native_host "$platform")
    if [[ -z "$host" ]]; then
        _log_error "No native host configured for platform: $platform"
        cat << EOF
{"status": "error", "exit_code": 4, "error": "No native host for $platform"}
EOF
        return 4
    fi

    # Get build configuration
    local local_path build_cmd build_env binary_name
    local config_file="$ACT_REPOS_DIR/${tool_name}.yaml"

    if [[ ! -f "$config_file" ]]; then
        _log_error "Config not found: $config_file"
        cat << EOF
{"status": "error", "exit_code": 4, "error": "Config not found: $config_file"}
EOF
        return 4
    fi

    local_path=$(act_get_local_path "$tool_name")
    build_cmd=$(act_get_build_cmd "$tool_name")
    build_env=$(act_get_build_env "$tool_name" "$platform")
    binary_name=$(yq -r '.binary_name // ""' "$config_file" 2>/dev/null)

    if [[ -z "$local_path" || -z "$build_cmd" ]]; then
        _log_error "Missing local_path or build_cmd in config"
        cat << EOF
{"status": "error", "exit_code": 4, "error": "Missing required config fields"}
EOF
        return 4
    fi

    # Prepare log file
    local log_dir log_file
    log_dir="$ACT_LOGS_DIR"
    mkdir -p "$log_dir"
    log_file="$log_dir/${tool_name}-${platform//\//-}-${run_id:-$$}.log"

    _log_info "Building $tool_name for $platform on $host"
    _log_info "Local path: $local_path"
    _log_info "Build cmd: $build_cmd"
    _log_info "Log file: $log_file"

    local start_time
    start_time=$(date +%s)

    # Construct the remote command
    # For SSH, we need to cd to repo, set env vars, and run build
    local env_exports=""
    for env_pair in $build_env; do
        env_exports+="export $env_pair; "
    done

    local remote_cmd="cd '$local_path' && $env_exports$build_cmd"

    # Execute on remote host
    # Use PIPESTATUS to capture the actual command exit code, not tee's
    _act_ssh_exec "$host" "$remote_cmd" 2>&1 | tee "$log_file"
    local exit_code=${PIPESTATUS[0]}

    local end_time duration
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    # Determine result
    local status artifact_path
    if [[ $exit_code -eq 0 ]]; then
        _log_ok "Build completed on $host in ${duration}s"
        status="success"

        # Artifact path depends on language
        local language
        language=$(yq -r '.language // ""' "$config_file" 2>/dev/null)
        case "$language" in
            rust)
                artifact_path="$local_path/target/release/$binary_name"
                ;;
            go)
                artifact_path="$local_path/$binary_name"
                ;;
            *)
                artifact_path="$local_path/$binary_name"
                ;;
        esac

        # Add .exe extension for Windows
        [[ "$platform" == windows/* ]] && artifact_path+=".exe"
    elif [[ $exit_code -eq 124 ]]; then
        _log_error "Build timed out on $host after ${_ACT_BUILD_TIMEOUT}s"
        status="timeout"
        exit_code=5
    else
        _log_error "Build failed on $host with exit code $exit_code"
        status="failed"
        exit_code=6
    fi

    # Return JSON result
    cat << EOF
{
  "tool": "$tool_name",
  "platform": "$platform",
  "host": "$host",
  "method": "native",
  "status": "$status",
  "exit_code": $exit_code,
  "duration_seconds": $duration,
  "artifact_path": "${artifact_path:-}",
  "log_file": "$log_file"
}
EOF

    return "$exit_code"
}

# Main orchestration function: coordinate act + SSH builds
# Usage: act_orchestrate_build <tool_name> <version> [targets...]
# Returns: JSON with aggregated results
act_orchestrate_build() {
    local tool_name="$1"
    local version="$2"
    shift 2
    local targets_arg=("$@")

    # Load config
    if ! act_load_repo_config "$tool_name"; then
        _log_error "Failed to load config for $tool_name"
        return 4
    fi

    # Get targets (from args or config)
    local targets
    if [[ ${#targets_arg[@]} -gt 0 ]]; then
        targets="${targets_arg[*]}"
    else
        targets=$(act_get_targets "$tool_name")
    fi

    if [[ -z "$targets" ]]; then
        _log_error "No targets configured for $tool_name"
        return 4
    fi

    _log_info "Orchestrating build for $tool_name $version"
    _log_info "Targets: $targets"

    # Initialize build state (if build_state.sh is sourced)
    local run_id
    if command -v build_state_create &>/dev/null; then
        if ! build_lock_acquire "$tool_name" "$version"; then
            _log_error "Build already in progress (lock held)"
            return 2
        fi
        run_id=$(build_state_create "$tool_name" "$version" "${targets// /,}")
        build_state_update_status "$tool_name" "$version" "running" "$run_id"
    else
        run_id="run-$(date +%s)-$$"
    fi

    _log_info "Run ID: $run_id"

    # Track results
    local results=()
    local success_count=0
    local fail_count=0
    local start_time
    start_time=$(date +%s)

    # Process each target
    for target in $targets; do
        _log_info "--- Building target: $target ---"

        # Update host status
        local host
        host=$(act_get_native_host "$target")
        if command -v build_state_update_host &>/dev/null; then
            build_state_update_host "$tool_name" "$version" "$host" "running" '{"target":"'"$target"'"}' "$run_id"
        fi

        # Determine build method
        local result exit_code=0
        if act_platform_uses_act "$tool_name" "$target"; then
            # Run via act
            local job workflow local_path extra_flags
            job=$(act_get_job_for_target "$tool_name" "$target")
            workflow="$ACT_REPO_WORKFLOW"
            local_path="$ACT_REPO_LOCAL_PATH"
            extra_flags=$(act_get_flags "$tool_name" "$target")

            _log_info "Method: act (job=$job)"

            # Collect extra args
            local act_args=()
            [[ -n "$extra_flags" ]] && read -ra act_args <<< "$extra_flags"

            # Run act workflow
            result=$(act_run_workflow "$local_path" "$workflow" "$job" "push" "${act_args[@]}" 2>&1) || exit_code=$?

            # Wrap in consistent format
            result=$(echo "$result" | jq --arg target "$target" --arg method "act" \
                '. + {platform: $target, method: $method}' 2>/dev/null || echo "$result")
        else
            # Run via SSH (native build)
            _log_info "Method: native (host=$host)"
            result=$(act_run_native_build "$tool_name" "$target" "$version" "$run_id") || exit_code=$?
        fi

        # Update result tracking
        results+=("$result")

        local status
        status=$(echo "$result" | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")

        if [[ "$status" == "success" ]]; then
            ((success_count++))
            if command -v build_state_update_host &>/dev/null; then
                build_state_update_host "$tool_name" "$version" "$host" "completed" \
                    "$(echo "$result" | jq -c '{artifact_path, duration_seconds}' 2>/dev/null || echo '{}')" "$run_id"
            fi
        else
            ((fail_count++))
            if command -v build_state_update_host &>/dev/null; then
                build_state_update_host "$tool_name" "$version" "$host" "failed" \
                    "$(echo "$result" | jq -c '{exit_code, error: .error // .status}' 2>/dev/null || echo '{}')" "$run_id"
            fi
        fi

        _log_info "Result: $status (exit_code=$exit_code)"
    done

    local end_time total_duration
    end_time=$(date +%s)
    total_duration=$((end_time - start_time))

    # Determine overall status
    local overall_status overall_exit_code
    if [[ $fail_count -eq 0 ]]; then
        overall_status="success"
        overall_exit_code=0
    elif [[ $success_count -gt 0 ]]; then
        overall_status="partial"
        overall_exit_code=1
    else
        overall_status="failed"
        overall_exit_code=6
    fi

    # Update build state
    if command -v build_state_update_status &>/dev/null; then
        build_state_update_status "$tool_name" "$version" "$overall_status" "$run_id"
        build_lock_release "$tool_name" "$version"
    fi

    _log_info "=== Build orchestration complete ==="
    _log_info "Status: $overall_status (success=$success_count, failed=$fail_count)"
    _log_info "Duration: ${total_duration}s"

    # Return aggregated JSON result
    local results_json
    if [[ ${#results[@]} -eq 0 ]]; then
        results_json="[]"
    else
        results_json=$(printf '%s\n' "${results[@]}" | jq -s '.' 2>/dev/null || echo '[]')
    fi

    cat << EOF
{
  "tool": "$tool_name",
  "version": "$version",
  "run_id": "$run_id",
  "status": "$overall_status",
  "exit_code": $overall_exit_code,
  "duration_seconds": $total_duration,
  "summary": {
    "total": $((success_count + fail_count)),
    "success": $success_count,
    "failed": $fail_count
  },
  "targets": $results_json
}
EOF

    return "$overall_exit_code"
}

# Generate build manifest from orchestration results
# Usage: act_generate_manifest <orchestration_result_json> <output_file>
act_generate_manifest() {
    local result_json="$1"
    local output_file="$2"

    local tool version run_id status
    tool=$(echo "$result_json" | jq -r '.tool')
    version=$(echo "$result_json" | jq -r '.version')
    run_id=$(echo "$result_json" | jq -r '.run_id')
    status=$(echo "$result_json" | jq -r '.status')

    local manifest
    manifest=$(jq -nc \
        --arg tool "$tool" \
        --arg version "$version" \
        --arg run_id "$run_id" \
        --arg status "$status" \
        --arg generated_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        --argjson targets "$(echo "$result_json" | jq '.targets // []')" \
        '{
            schema_version: "1.0.0",
            tool: $tool,
            version: $version,
            run_id: $run_id,
            status: $status,
            generated_at: $generated_at,
            artifacts: ($targets | map(select(.status == "success") | {
                platform: .platform,
                host: .host,
                method: .method,
                path: .artifact_path,
                duration_seconds: .duration_seconds
            }))
        }')

    if [[ -n "$output_file" ]]; then
        echo "$manifest" > "$output_file"
        _log_info "Manifest written to: $output_file"
    else
        echo "$manifest"
    fi
}

# Export functions for use by other scripts
export -f act_check act_list_jobs act_get_runner act_can_run
export -f act_run_workflow act_collect_artifacts act_analyze_workflow act_cleanup
export -f act_load_repo_config act_get_job_for_target act_platform_uses_act
export -f act_get_flags act_get_targets act_get_native_host act_get_build_strategy
export -f act_list_tools act_build_matrix
export -f act_get_build_cmd act_get_build_env act_get_local_path
export -f act_run_native_build act_orchestrate_build act_generate_manifest
