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

# Compute SHA256 for a file (portable: sha256sum or shasum -a 256)
_act_sha256() {
    local file="$1"

    if command -v sha256sum &>/dev/null; then
        sha256sum "$file" 2>/dev/null | awk '{print $1}'
        return $?
    fi

    if command -v shasum &>/dev/null; then
        shasum -a 256 "$file" 2>/dev/null | awk '{print $1}'
        return $?
    fi

    return 3
}

# Get file size in bytes (portable)
_act_file_size() {
    local file="$1"
    stat -c %s "$file" 2>/dev/null || stat -f %z "$file" 2>/dev/null || echo 0
}

# Infer archive format from filename
_act_archive_format() {
    local name="$1"
    case "$name" in
        *.tar.gz|*.tgz) echo "tar.gz" ;;
        *.tar.xz) echo "tar.xz" ;;
        *.zip) echo "zip" ;;
        *) echo "none" ;;
    esac
}

# Timeout helper (supports GNU timeout and coreutils gtimeout)
_ACT_TIMEOUT_CMD=""
_act_timeout_cmd() {
    if [[ -n "$_ACT_TIMEOUT_CMD" ]]; then
        echo "$_ACT_TIMEOUT_CMD"
        return 0
    fi

    if command -v timeout &>/dev/null; then
        _ACT_TIMEOUT_CMD="timeout"
    elif command -v gtimeout &>/dev/null; then
        _ACT_TIMEOUT_CMD="gtimeout"
    else
        _ACT_TIMEOUT_CMD=""
    fi

    echo "$_ACT_TIMEOUT_CMD"
}

_act_run_with_timeout() {
    local seconds="$1"
    shift
    local cmd
    cmd=$(_act_timeout_cmd)
    if [[ -n "$cmd" ]]; then
        "$cmd" "$seconds" "$@"
    else
        "$@"
    fi
}

# Check if act is available and properly configured
act_check() {
    if ! command -v act &>/dev/null; then
        _log_error "act not found. Install: brew install act (macOS) or go install github.com/nektos/act@latest"
        return 3
    fi

    if ! docker info &>/dev/null; then
        _log_error "Docker daemon not running or not accessible"
        return 3
    fi

    # CRITICAL: Check for UID mismatch configuration
    # catthehacker images run as UID 1001. Without --user flag,
    # files created by act will have wrong ownership!
    local actrc_file="$HOME/.actrc"
    if [[ -f "$actrc_file" ]]; then
        local has_bind=false has_user=false
        # Use 'command grep' to bypass any aliases (e.g., rg aliased as grep)
        # Pattern handles optional leading whitespace: "  --bind" or "--bind"
        if command grep -qE '^[[:space:]]*--bind([[:space:]]|$)' "$actrc_file" 2>/dev/null; then
            has_bind=true
        fi
        if command grep -qE -- '--container-options.*--user|--container-options=.*--user' "$actrc_file" 2>/dev/null; then
            has_user=true
        fi

        if $has_bind && ! $has_user; then
            _log_error "═══════════════════════════════════════════════════════════════════"
            _log_error "CRITICAL: ~/.actrc has --bind but missing --user flag!"
            _log_error ""
            _log_error "Files created by act will have WRONG OWNERSHIP (UID 1001 instead of $(id -u))"
            _log_error "This WILL corrupt your repository with inaccessible files!"
            _log_error ""
            _log_error "FIX: Add this line to ~/.actrc:"
            _log_error "    --container-options --user=$(id -u):$(id -g)"
            _log_error ""
            _log_error "Or run: echo '--container-options --user=$(id -u):$(id -g)' >> ~/.actrc"
            _log_error "Or run: dsr doctor --fix"
            _log_error "═══════════════════════════════════════════════════════════════════"
            return 3
        fi
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
            $0 ~ "^[[:space:]]*" job { in_job=1 }
            in_job && /runs-on:/ { gsub(/.*runs-on:[ ]*/, ""); gsub(/["\047]/, ""); print; exit }
            in_job && /^[[:space:]]*[a-zA-Z]/ && $0 !~ job { exit }
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
# Usage: act_run_workflow <repo_path> <workflow> [job] [event] [version] [extra_args...]
# Returns: exit code (0=success, 1=partial, 6=build failed, 3=dependency error)
# Note: When version is provided, GITHUB_REF/GITHUB_REF_NAME/GITHUB_REF_TYPE are injected
#       to simulate a tag push for release workflows
act_run_workflow() {
    local repo_path="$1"
    local workflow="$2"
    local job="${3:-}"
    local event="${4:-push}"
    local version="${5:-}"
    shift 5 2>/dev/null || true
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

    if ! mkdir -p "$artifact_dir" "$ACT_LOGS_DIR"; then
        _log_error "Failed to create run directories: $artifact_dir, $ACT_LOGS_DIR"
        return 1
    fi

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

    # Inject tag context for release workflows when version is provided
    # This simulates a tag push so workflows can detect the version
    if [[ -n "$version" ]]; then
        local tag="v${version#v}"  # Ensure v prefix, avoid doubling
        act_cmd+=(--env "GITHUB_REF=refs/tags/$tag")
        act_cmd+=(--env "GITHUB_REF_NAME=$tag")
        act_cmd+=(--env "GITHUB_REF_TYPE=tag")
        _log_info "Injecting tag context: $tag"
    fi

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
    local timeout_cmd
    timeout_cmd=$(_act_timeout_cmd)
    if [[ -n "$timeout_cmd" ]]; then
        "$timeout_cmd" "$ACT_TIMEOUT" "${act_cmd[@]}" \
            --directory "$repo_path" \
            2>&1 | tee "$log_file"
    else
        _log_warn "timeout command not available; running act without timeout"
        "${act_cmd[@]}" \
            --directory "$repo_path" \
            2>&1 | tee "$log_file"
    fi
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
    jq -nc \
        --arg run_id "$run_id" \
        --arg workflow "$workflow" \
        --arg job "${job:-all}" \
        --arg status "$status" \
        --argjson exit_code "$exit_code" \
        --argjson duration_seconds "$duration" \
        --arg artifact_dir "$artifact_dir" \
        --argjson artifact_count "$artifact_count" \
        --arg log_file "$log_file" \
        '{
            run_id: $run_id,
            workflow: $workflow,
            job: $job,
            status: $status,
            exit_code: $exit_code,
            duration_seconds: $duration_seconds,
            artifact_dir: $artifact_dir,
            artifact_count: $artifact_count,
            log_file: $log_file
        }'

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

    if ! mkdir -p "$output_dir"; then
        _log_error "Failed to create output directory: $output_dir"
        return 1
    fi

    # act stores artifacts in subdirectories by artifact name
    local count=0
    local failed=0
    while IFS= read -r -d '' artifact; do
        local basename
        basename=$(basename "$artifact")
        if cp "$artifact" "$output_dir/$basename"; then
            _log_info "Collected: $basename"
            ((count++))
        else
            _log_error "Failed to copy artifact: $artifact"
            ((failed++))
        fi
    done < <(find "$artifact_dir" -type f -print0)

    if [[ $failed -gt 0 ]]; then
        _log_error "Failed to collect $failed artifact(s)"
        return 1
    fi

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
    jq -nc \
        --arg workflow "$workflow" \
        --argjson linux_jobs "$(_array_to_json "${linux_jobs[@]+"${linux_jobs[@]}"}")" \
        --argjson macos_jobs "$(_array_to_json "${macos_jobs[@]+"${macos_jobs[@]}"}")" \
        --argjson windows_jobs "$(_array_to_json "${windows_jobs[@]+"${windows_jobs[@]}"}")" \
        --argjson other_jobs "$(_array_to_json "${other_jobs[@]+"${other_jobs[@]}"}")" \
        --argjson act_compatible "${#linux_jobs[@]}" \
        --argjson native_required "$((${#macos_jobs[@]} + ${#windows_jobs[@]}))" \
        '{
            workflow: $workflow,
            linux_jobs: $linux_jobs,
            macos_jobs: $macos_jobs,
            windows_jobs: $windows_jobs,
            other_jobs: $other_jobs,
            act_compatible: $act_compatible,
            native_required: $native_required
        }'
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
    ACT_REPO_NAME=$(yq -r '.tool_name // ""' "$config_file")
    ACT_REPO_GITHUB=$(yq -r '.repo // ""' "$config_file")
    ACT_REPO_LOCAL_PATH=$(yq -r '.local_path // ""' "$config_file")
    ACT_REPO_LANGUAGE=$(yq -r '.language // ""' "$config_file")
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
    job=$(yq -r '.act_job_map."'"$platform"'" // ""' "$config_file" 2>/dev/null)

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
    image=$(yq -r '.act_overrides.platform_image // ""' "$config_file" 2>/dev/null)
    if [[ -n "$image" ]]; then
        flags+=("-P ubuntu-latest=$image")
    fi

    # Get secrets file if specified
    local secrets_file
    secrets_file=$(yq -r '.act_overrides.secrets_file // ""' "$config_file" 2>/dev/null)
    if [[ -n "$secrets_file" ]]; then
        flags+=("--secret-file $secrets_file")
    fi

    # Get env file if specified
    local env_file
    env_file=$(yq -r '.act_overrides.env_file // ""' "$config_file" 2>/dev/null)
    if [[ -n "$env_file" ]]; then
        flags+=("--env-file $env_file")
    fi

    # Platform-specific flags
    if [[ "$platform" == "linux/arm64" ]]; then
        # Check for ARM64 specific overrides
        local arm64_flags
        arm64_flags=$(yq -r '.act_overrides.linux_arm64_flags[]? // ""' "$config_file" 2>/dev/null)
        if [[ -n "$arm64_flags" ]]; then
            while IFS= read -r flag; do
                flags+=("$flag")
            done <<< "$arm64_flags"
        fi
    fi

    # Matrix filtering for targeted builds (optional)
    # Example:
    # act_matrix:
    #   "linux/amd64":
    #     os: ubuntu-latest
    #     target: linux/amd64
    local matrix_entries
    matrix_entries=$(yq -r '
        .act_matrix."'"$platform"'" // {} |
        to_entries |
        .[] |
        select(.value != null and .value != "") |
        .key + ":" + (.value | tostring)
    ' "$config_file" 2>/dev/null)
    if [[ -n "$matrix_entries" ]]; then
        while IFS= read -r entry; do
            [[ -n "$entry" ]] && flags+=("--matrix $entry")
        done <<< "$matrix_entries"
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

    jq -nc \
        --arg tool "$tool_name" \
        --arg platform "$platform" \
        --arg method "$method" \
        --arg host "$host" \
        --arg job "$job" \
        '{
            tool: $tool,
            platform: $platform,
            method: $method,
            host: $host,
            job: $job
        }'
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
    # Save state without eval - shopt -q returns 0 if set, 1 if unset
    local had_nullglob=false
    shopt -q nullglob && had_nullglob=true
    shopt -s nullglob

    for config in "$ACT_REPOS_DIR"/*.yaml; do
        # Skip template files (start with _)
        if [[ ! "$(basename "$config")" =~ ^_ ]]; then
            basename "$config" .yaml
        fi
    done

    # Restore previous nullglob setting without eval
    if $had_nullglob; then
        shopt -s nullglob
    else
        shopt -u nullglob
    fi
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
_ACT_SYNC_TIMEOUT="${DSR_SYNC_TIMEOUT:-300}"  # 5 minutes for sync

# ============================================================================
# Source Code Sync for Remote Native Builds
# ============================================================================

# Default exclude patterns for rsync
_ACT_SYNC_DEFAULT_EXCLUDES=(
    '.git'
    'target'
    'node_modules'
    '.beads'
    '*.log'
    '.DS_Store'
    '__pycache__'
    '*.pyc'
    '.env'
    '.env.local'
)

# Check if rsync is available on remote host
# Usage: _act_has_rsync <host>
# Returns: 0 if rsync available, 1 otherwise
_act_has_rsync() {
    local host="$1"
    _act_run_with_timeout 10 ssh -o ConnectTimeout="$_ACT_SSH_TIMEOUT" \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new \
        "$host" 'command -v rsync >/dev/null 2>&1' 2>/dev/null
}

# Sync source code to remote host via rsync
# Usage: _act_sync_source <host> <local_path> <remote_path> [extra_excludes...]
# Returns: 0 on success, non-zero on failure
_act_sync_source() {
    local host="$1"
    local local_path="$2"
    local remote_path="$3"
    shift 3
    local extra_excludes=("$@")

    if [[ ! -d "$local_path" ]]; then
        _log_error "Local path not found: $local_path"
        return 4
    fi

    # Build exclude args
    local exclude_args=()
    for pattern in "${_ACT_SYNC_DEFAULT_EXCLUDES[@]}"; do
        exclude_args+=("--exclude=$pattern")
    done
    for pattern in "${extra_excludes[@]}"; do
        exclude_args+=("--exclude=$pattern")
    done

    # Add .gitignore patterns if available
    if [[ -f "$local_path/.gitignore" ]]; then
        exclude_args+=("--exclude-from=$local_path/.gitignore")
    fi

    _log_info "Syncing source to $host:$remote_path"

    local start_time
    start_time=$(date +%s)

    # Check for rsync on remote
    if _act_has_rsync "$host"; then
        # Use rsync for efficient sync
        if _act_run_with_timeout "$_ACT_SYNC_TIMEOUT" rsync -az --delete \
            "${exclude_args[@]}" \
            -e "ssh -o ConnectTimeout=$_ACT_SSH_TIMEOUT -o StrictHostKeyChecking=accept-new" \
            "$local_path/" "$host:$remote_path/" 2>&1; then
            local duration=$(($(date +%s) - start_time))
            _log_ok "Sync completed in ${duration}s (rsync)"
            return 0
        else
            _log_error "rsync failed"
            return 1
        fi
    else
        # Fallback: tar + ssh + untar (works everywhere)
        _log_warn "rsync not available on $host, using tar fallback"

        # Build tar exclude args
        local tar_excludes=()
        for pattern in "${_ACT_SYNC_DEFAULT_EXCLUDES[@]}"; do
            tar_excludes+=("--exclude=$pattern")
        done
        for pattern in "${extra_excludes[@]}"; do
            tar_excludes+=("--exclude=$pattern")
        done

        # Create remote directory and extract
        # Windows (wlap) needs different mkdir syntax - use cmd /c with backslashes
        local mkdir_cmd
        if [[ "$host" == "wlap" ]]; then
            # Windows: convert forward slashes to backslashes, use cmd /c
            local win_path="${remote_path//\//\\}"
            mkdir_cmd="cmd /c \"if not exist \\\"$win_path\\\" mkdir \\\"$win_path\\\"\" && cd /d \"$win_path\""
        else
            mkdir_cmd="mkdir -p \"$remote_path\" && cd \"$remote_path\""
        fi

        if _act_run_with_timeout "$_ACT_SYNC_TIMEOUT" bash -c "
            cd '$local_path' && \
            tar czf - ${tar_excludes[*]} . | \
            ssh -o ConnectTimeout=$_ACT_SSH_TIMEOUT \
                -o StrictHostKeyChecking=accept-new \
                '$host' '$mkdir_cmd && tar xzf -'
        " 2>&1; then
            local duration=$(($(date +%s) - start_time))
            _log_ok "Sync completed in ${duration}s (tar)"
            return 0
        else
            _log_error "tar fallback sync failed"
            return 1
        fi
    fi
}

# Sync source to all native build hosts for a tool
# Usage: act_sync_sources <tool_name> [targets...]
# Returns: JSON with sync results
act_sync_sources() {
    local tool_name="$1"
    shift
    local targets_arg=("$@")

    local config_file="$ACT_REPOS_DIR/${tool_name}.yaml"
    if [[ ! -f "$config_file" ]]; then
        _log_error "Config not found: $config_file"
        echo '{"status":"error","error":"Config not found"}'
        return 4
    fi

    local local_path
    local_path=$(act_get_local_path "$tool_name")
    if [[ -z "$local_path" || ! -d "$local_path" ]]; then
        _log_error "Local path not found: $local_path"
        echo '{"status":"error","error":"Local path not found"}'
        return 4
    fi

    # Determine targets
    local targets
    if [[ ${#targets_arg[@]} -gt 0 ]]; then
        targets="${targets_arg[*]}"
    else
        targets=$(act_get_targets "$tool_name")
    fi

    # Find unique native hosts that need sync
    local hosts_to_sync=()
    local host_paths=()
    for target in $targets; do
        # Skip targets that use act (no sync needed)
        if act_platform_uses_act "$tool_name" "$target"; then
            continue
        fi

        local host
        host=$(act_get_native_host "$target")
        if [[ -z "$host" ]]; then
            continue
        fi

        # Skip duplicates
        local already_added=false
        for h in "${hosts_to_sync[@]}"; do
            if [[ "$h" == "$host" ]]; then
                already_added=true
                break
            fi
        done
        if $already_added; then
            continue
        fi

        # Get remote path (host_paths override or fallback to local_path)
        local remote_path
        remote_path=$(yq -r '.host_paths.'"$host"' // ""' "$config_file" 2>/dev/null)
        [[ -z "$remote_path" ]] && remote_path="$local_path"

        hosts_to_sync+=("$host")
        host_paths+=("$remote_path")
    done

    if [[ ${#hosts_to_sync[@]} -eq 0 ]]; then
        _log_info "No native build hosts need sync"
        echo '{"status":"skipped","synced":0,"hosts":[]}'
        return 0
    fi

    _log_info "Syncing to ${#hosts_to_sync[@]} host(s): ${hosts_to_sync[*]}"

    local synced=0
    local failed=0
    local results=()
    local start_time
    start_time=$(date +%s)

    for i in "${!hosts_to_sync[@]}"; do
        local host="${hosts_to_sync[$i]}"
        local remote_path="${host_paths[$i]}"

        if _act_sync_source "$host" "$local_path" "$remote_path"; then
            ((synced++))
            results+=("{\"host\":\"$host\",\"path\":\"$remote_path\",\"status\":\"success\"}")
        else
            ((failed++))
            results+=("{\"host\":\"$host\",\"path\":\"$remote_path\",\"status\":\"failed\"}")
        fi
    done

    local total_duration=$(($(date +%s) - start_time))

    # Determine overall status
    local status
    if [[ $failed -eq 0 ]]; then
        status="success"
    elif [[ $synced -gt 0 ]]; then
        status="partial"
    else
        status="failed"
    fi

    # Build results JSON
    local results_json
    if [[ ${#results[@]} -eq 0 ]]; then
        results_json="[]"
    else
        results_json=$(printf '%s\n' "${results[@]}" | jq -s '.')
    fi

    jq -nc \
        --arg status "$status" \
        --argjson synced "$synced" \
        --argjson failed "$failed" \
        --argjson duration "$total_duration" \
        --argjson hosts "$results_json" \
        '{
            status: $status,
            synced: $synced,
            failed: $failed,
            duration_seconds: $duration,
            hosts: $hosts
        }'

    if [[ $failed -gt 0 ]]; then
        return 1
    fi
    return 0
}

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

# Get GitHub repo for a tool
# Usage: act_get_repo <tool_name>
act_get_repo() {
    local tool_name="$1"
    local config_file="$ACT_REPOS_DIR/${tool_name}.yaml"

    if [[ ! -f "$config_file" ]]; then
        return 4
    fi

    yq -r '.repo // ""' "$config_file" 2>/dev/null
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

# Ensure remote repo is in a valid git state for builds (bd-1tv.9)
# Handles: missing repos, broken .git, dirty working tree
#
# Usage: act_ensure_remote_repo_ready <host> <remote_path> <repo_url> <version>
# Returns: 0 on success, 1 on failure
act_ensure_remote_repo_ready() {
    local host="$1"
    local remote_path="$2"
    local repo_url="$3"
    local version="$4"

    _log_info "Ensuring repo at $host:$remote_path is ready..."

    # Determine if this is a Windows host
    local is_windows=false
    [[ "$host" == "wlap" ]] && is_windows=true

    # Build commands for git operations
    local test_dir_cmd test_git_cmd clone_cmd pull_cmd checkout_cmd stash_cmd rm_cmd

    if $is_windows; then
        # Windows: use PowerShell for reliable path handling
        local win_path="${remote_path//\//\\}"
        test_dir_cmd="if exist \"$win_path\" (exit 0) else (exit 1)"
        test_git_cmd="if exist \"$win_path\\.git\" (exit 0) else (exit 1)"
        clone_cmd="git clone \"$repo_url\" \"$win_path\""
        pull_cmd="cd /d \"$win_path\" && git fetch --all --tags && git reset --hard origin/HEAD"
        checkout_cmd="cd /d \"$win_path\" && git checkout \"$version\""
        stash_cmd="cd /d \"$win_path\" && git stash --include-untracked"
        rm_cmd="rmdir /s /q \"$win_path\""
    else
        # Unix
        test_dir_cmd="test -d '$remote_path'"
        test_git_cmd="test -d '$remote_path/.git'"
        clone_cmd="git clone '$repo_url' '$remote_path'"
        pull_cmd="cd '$remote_path' && git fetch --all --tags && git reset --hard origin/HEAD"
        checkout_cmd="cd '$remote_path' && git checkout '$version'"
        stash_cmd="cd '$remote_path' && git stash --include-untracked"
        rm_cmd="rm -rf '$remote_path'"
    fi

    # Step 1: Check if path exists
    if ! _act_ssh_exec "$host" "$test_dir_cmd" 30 &>/dev/null; then
        _log_info "Directory doesn't exist on $host, cloning..."
        if ! _act_ssh_exec "$host" "$clone_cmd" 300; then
            _log_error "Failed to clone repo on $host"
            return 1
        fi
        _log_ok "Cloned repo on $host"
    else
        # Step 2: Check if .git exists
        if ! _act_ssh_exec "$host" "$test_git_cmd" 30 &>/dev/null; then
            _log_warn "Missing .git on $host, re-cloning..."

            # Remove existing directory and clone fresh
            if ! _act_ssh_exec "$host" "$rm_cmd && $clone_cmd" 300; then
                _log_error "Failed to re-clone repo on $host"
                return 1
            fi
            _log_ok "Re-cloned repo on $host"
        else
            # Step 3: Try to update (stash if needed)
            _log_info "Updating repo on $host..."

            # First try a clean pull with reset (handles most dirty tree issues)
            if ! _act_ssh_exec "$host" "$pull_cmd" 120 2>/dev/null; then
                _log_warn "Pull failed on $host, trying stash and pull..."

                # Stash any local changes and try again
                if _act_ssh_exec "$host" "$stash_cmd" 60 2>/dev/null; then
                    if ! _act_ssh_exec "$host" "$pull_cmd" 120; then
                        _log_error "Pull still failed after stash on $host"
                        return 1
                    fi
                else
                    # Last resort: nuke everything and re-clone
                    _log_warn "Stash failed, re-cloning as last resort..."
                    if ! _act_ssh_exec "$host" "$rm_cmd && $clone_cmd" 300; then
                        _log_error "Re-clone failed on $host"
                        return 1
                    fi
                fi
            fi
            _log_ok "Updated repo on $host"
        fi
    fi

    # Step 4: Checkout the target version
    _log_info "Checking out $version on $host..."
    if ! _act_ssh_exec "$host" "$checkout_cmd" 60; then
        _log_error "Failed to checkout $version on $host"
        return 1
    fi

    _log_ok "Repo ready at $host:$remote_path (version: $version)"
    return 0
}

# Ensure repos are ready on all native build hosts for a tool
# Usage: act_ensure_repos_ready <tool_name> <version> [targets...]
# Returns: JSON with readiness results
act_ensure_repos_ready() {
    local tool_name="$1"
    local version="$2"
    shift 2
    local targets_arg=("$@")

    local config_file="$ACT_REPOS_DIR/${tool_name}.yaml"
    if [[ ! -f "$config_file" ]]; then
        _log_error "Config not found: $config_file"
        echo '{"status":"error","error":"Config not found"}'
        return 4
    fi

    local repo_url
    repo_url=$(act_get_repo "$tool_name")
    if [[ -z "$repo_url" ]]; then
        _log_error "No repo URL in config"
        echo '{"status":"error","error":"No repo URL in config"}'
        return 4
    fi

    # Convert repo shorthand to full URL
    if [[ "$repo_url" != https://* && "$repo_url" != git@* ]]; then
        repo_url="https://github.com/${repo_url}.git"
    fi

    # Determine targets
    local targets
    if [[ ${#targets_arg[@]} -gt 0 ]]; then
        targets="${targets_arg[*]}"
    else
        targets=$(act_get_targets "$tool_name")
    fi

    # Find unique native hosts that need repo setup
    local -A hosts_checked=()
    local results=()
    local ready=0 failed=0

    for target in $targets; do
        # Skip targets that use act (no remote repo needed)
        if act_platform_uses_act "$tool_name" "$target"; then
            continue
        fi

        local host
        host=$(act_get_native_host "$target")
        [[ -z "$host" ]] && continue

        # Skip if already checked this host
        [[ -n "${hosts_checked[$host]:-}" ]] && continue
        hosts_checked[$host]=1

        # Get remote path for this host
        local remote_path
        remote_path=$(yq -r '.host_paths.'"$host"' // ""' "$config_file" 2>/dev/null)
        if [[ -z "$remote_path" ]]; then
            remote_path=$(act_get_local_path "$tool_name")
        fi

        _log_info "Checking $host:$remote_path..."

        if act_ensure_remote_repo_ready "$host" "$remote_path" "$repo_url" "$version"; then
            results+=("{\"host\":\"$host\",\"path\":\"$remote_path\",\"status\":\"ready\"}")
            ((ready++))
        else
            results+=("{\"host\":\"$host\",\"path\":\"$remote_path\",\"status\":\"failed\"}")
            ((failed++))
        fi
    done

    # Build results JSON
    local status
    if [[ $failed -eq 0 ]]; then
        status="success"
    elif [[ $ready -gt 0 ]]; then
        status="partial"
    else
        status="failed"
    fi

    local results_json
    if [[ ${#results[@]} -eq 0 ]]; then
        results_json="[]"
    else
        results_json=$(printf '%s\n' "${results[@]}" | jq -s '.')
    fi

    jq -nc \
        --arg status "$status" \
        --argjson ready "$ready" \
        --argjson failed "$failed" \
        --argjson hosts "$results_json" \
        '{
            status: $status,
            ready: $ready,
            failed: $failed,
            hosts: $hosts
        }'

    [[ $failed -gt 0 ]] && return 1
    return 0
}

# Execute command on remote host via SSH
# Usage: _act_ssh_exec <host> <command> [timeout]
# Returns: Exit code from remote command
_act_ssh_exec() {
    local host="$1"
    local cmd="$2"
    local timeout_sec="${3:-$_ACT_BUILD_TIMEOUT}"

    _act_run_with_timeout "$timeout_sec" ssh \
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
        jq -nc --arg platform "$platform" \
            '{status: "error", exit_code: 4, error: ("No native host for " + $platform)}'
        return 4
    fi

    # Get build configuration
    local local_path build_cmd build_env binary_name
    local config_file="$ACT_REPOS_DIR/${tool_name}.yaml"

    if [[ ! -f "$config_file" ]]; then
        _log_error "Config not found: $config_file"
        jq -nc --arg config_file "$config_file" \
            '{status: "error", exit_code: 4, error: ("Config not found: " + $config_file)}'
        return 4
    fi

    local_path=$(act_get_local_path "$tool_name")
    build_cmd=$(act_get_build_cmd "$tool_name")
    build_env=$(act_get_build_env "$tool_name" "$platform")
    binary_name=$(yq -r '.binary_name // ""' "$config_file" 2>/dev/null)

    # Check for workspace_binaries (multi-binary Rust workspaces)
    local workspace_binaries
    workspace_binaries=$(yq -r '.workspace_binaries // [] | .[]' "$config_file" 2>/dev/null)

    if [[ -z "$local_path" || -z "$build_cmd" ]]; then
        _log_error "Missing local_path or build_cmd in config"
        jq -nc '{status: "error", exit_code: 4, error: "Missing required config fields"}'
        return 4
    fi

    # Determine remote path (check host_paths.<host> first, fallback to local_path)
    local remote_path
    remote_path=$(yq -r '.host_paths.'"$host"' // ""' "$config_file" 2>/dev/null)
    if [[ -z "$remote_path" ]]; then
        remote_path="$local_path"
    fi

    # Prepare log file
    local log_dir log_file
    log_dir="$ACT_LOGS_DIR"
    mkdir -p "$log_dir"
    log_file="$log_dir/${tool_name}-${platform//\//-}-${run_id:-$$}.log"

    _log_info "Building $tool_name for $platform on $host"
    _log_info "Remote path: $remote_path"
    _log_info "Build cmd: $build_cmd"
    _log_info "Log file: $log_file"

    local start_time
    start_time=$(date +%s)

    # Construct the remote command
    # For SSH, we need to cd to repo, set env vars, and run build
    local remote_cmd
    if [[ "$platform" == windows/* ]]; then
        # Windows: use cmd.exe compatible syntax
        # - Use double quotes for paths
        # - Use 'set' instead of 'export' for env vars
        # - Use '&&' which works in cmd.exe
        # Note: In cmd.exe, 'set VAR=value && ...' includes trailing space in value.
        # Using 'set "VAR=value"' protects the value from the space before &&.
        local env_exports=""
        for env_pair in $build_env; do
            env_exports+="set \"$env_pair\" && "
        done
        # Convert forward slashes to backslashes for Windows paths
        local win_path="${remote_path//\//\\}"
        remote_cmd="cd /d \"${win_path}\" && ${env_exports}${build_cmd}"
    else
        # Unix: use bash/zsh compatible syntax
        local env_exports=""
        for env_pair in $build_env; do
            env_exports+="export $env_pair; "
        done
        remote_cmd="cd '${remote_path//\'/\'\\\'\'}' && $env_exports$build_cmd"
    fi

    # Execute on remote host
    # Use PIPESTATUS to capture the actual command exit code, not tee's
    _act_ssh_exec "$host" "$remote_cmd" 2>&1 | tee "$log_file"
    local exit_code=${PIPESTATUS[0]}

    local end_time duration
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    # Determine result
    local status local_artifact_path="" local_artifact_paths=()
    if [[ $exit_code -eq 0 ]]; then
        _log_ok "Build completed on $host in ${duration}s"
        status="success"

        # Use run_id if available to group artifacts; isolate per-target to avoid name collisions
        local artifact_dir="$ACT_ARTIFACTS_DIR/${run_id:-build-$tool_name-$(date +%s)}/${platform//\//-}"
        mkdir -p "$artifact_dir"

        # Small delay to ensure files are fully flushed on remote
        sleep 1

        # Determine which binaries to download
        local binaries_to_download=()
        if [[ -n "$workspace_binaries" ]]; then
            # Multi-binary workspace: download each binary
            while IFS= read -r bin; do
                [[ -n "$bin" ]] && binaries_to_download+=("$bin")
            done <<< "$workspace_binaries"
            _log_info "Workspace mode: downloading ${#binaries_to_download[@]} binaries"
        elif [[ -n "$binary_name" ]]; then
            # Single binary mode
            binaries_to_download=("$binary_name")
        else
            _log_error "No binary_name or workspace_binaries configured"
            jq -nc '{status: "error", exit_code: 4, error: "No binaries configured"}'
            return 4
        fi

        # Sanity check: ensure we have binaries to download
        if [[ ${#binaries_to_download[@]} -eq 0 ]]; then
            _log_error "No binaries to download (workspace_binaries may be empty)"
            jq -nc '{status: "error", exit_code: 4, error: "No binaries to download"}'
            return 4
        fi

        # Remote artifact path depends on language
        local language
        language=$(yq -r '.language // ""' "$config_file" 2>/dev/null)

        local download_failed=false
        for bin in "${binaries_to_download[@]}"; do
            local remote_artifact_path
            case "$language" in
                rust)
                    remote_artifact_path="$remote_path/target/release/$bin"
                    ;;
                go)
                    remote_artifact_path="$remote_path/$bin"
                    ;;
                *)
                    remote_artifact_path="$remote_path/$bin"
                    ;;
            esac

            # Handle Windows specifics
            if [[ "$platform" == windows/* ]]; then
                # Add .exe extension (keep forward slashes - SCP via OpenSSH uses them)
                remote_artifact_path+=".exe"
            fi

            local artifact_filename
            artifact_filename=$(basename "$remote_artifact_path")
            local this_artifact_path="$artifact_dir/$artifact_filename"

            _log_info "Downloading artifact: ${host}:${remote_artifact_path}"
            local scp_output
            if scp_output=$(scp -o ConnectTimeout="$_ACT_SSH_TIMEOUT" \
                   -o StrictHostKeyChecking=accept-new \
                   "${host}:${remote_artifact_path}" "$this_artifact_path" 2>&1); then
                _log_ok "Artifact downloaded: $this_artifact_path"
                # Log file size for verification
                if [[ -f "$this_artifact_path" ]]; then
                    local file_size
                    file_size=$(stat -f%z "$this_artifact_path" 2>/dev/null || stat -c%s "$this_artifact_path" 2>/dev/null || echo "unknown")
                    _log_info "Artifact size: $file_size bytes"
                fi
                local_artifact_paths+=("$this_artifact_path")
            else
                _log_error "Failed to download artifact $bin from $host"
                _log_error "SCP error: $scp_output"
                echo "SCP failed for $bin: $scp_output" >> "$log_file"
                download_failed=true
            fi
        done

        # Set final status and artifact path(s)
        if [[ "$download_failed" == true ]]; then
            if [[ ${#local_artifact_paths[@]} -eq 0 ]]; then
                status="failed"
                exit_code=7
            else
                # Partial success - some artifacts downloaded
                status="partial"
                _log_warn "Some artifacts failed to download"
            fi
        fi

        # Package workspace binaries into a single tarball
        if [[ -n "$workspace_binaries" && ${#local_artifact_paths[@]} -gt 0 && "$status" != "failed" ]]; then
            _log_info "Packaging ${#local_artifact_paths[@]} workspace binaries into release tarball..."

            # Determine archive format
            local archive_ext="tar.gz"
            if [[ "$platform" == windows/* ]]; then
                archive_ext="zip"
            fi

            # Parse platform for naming: linux/amd64 -> linux-amd64
            local plat_name="${platform//\//-}"
            # Use version parameter (strip leading 'v' if present)
            local version_stripped="${version#v}"

            # Validate version is not empty
            if [[ -z "$version_stripped" ]]; then
                _log_warn "Version is empty, using 'unknown' for archive name"
                version_stripped="unknown"
            fi

            local archive_name=""
            if ! declare -F artifact_naming_generate_dual_for_tool &>/dev/null; then
                local script_dir
                script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
                # shellcheck source=./artifact_naming.sh
                source "$script_dir/artifact_naming.sh" 2>/dev/null || true
            fi

            if declare -F artifact_naming_generate_dual_for_tool &>/dev/null; then
                local os arch names_json
                os="${platform%/*}"
                arch="${platform#*/}"
                names_json=$(artifact_naming_generate_dual_for_tool "$tool_name" "$version" "$os" "$arch" "$archive_ext" "$local_path" 2>/dev/null || echo "")
                archive_name=$(echo "$names_json" | jq -r '.versioned // empty' 2>/dev/null)
            fi

            if [[ -z "$archive_name" ]]; then
                archive_name="${tool_name}-${version_stripped}-${plat_name}.${archive_ext}"
            fi
            local archive_path="$artifact_dir/$archive_name"

            # Get just the filenames for archive creation
            local archive_files=()
            for p in "${local_artifact_paths[@]}"; do
                archive_files+=("$(basename "$p")")
            done

            # Create the archive
            local archive_output
            if [[ "$archive_ext" == "zip" ]]; then
                # Windows: use zip
                if command -v zip &>/dev/null; then
                    archive_output=$(cd "$artifact_dir" && zip "$archive_name" "${archive_files[@]}" 2>&1)
                    if [[ -f "$archive_path" ]]; then
                        _log_ok "Created archive: $archive_path"
                        # Update artifact path to point to the archive
                        local_artifact_path="$archive_path"
                        local_artifact_paths=("$archive_path")
                    else
                        _log_warn "Failed to create zip archive"
                        _log_warn "zip output: $archive_output"
                        echo "Archive creation failed: $archive_output" >> "$log_file"
                        # Fall back to comma-separated paths
                        local_artifact_path=$(IFS=','; echo "${local_artifact_paths[*]}")
                    fi
                else
                    _log_warn "zip not available, skipping archive creation"
                    # Fall back to comma-separated paths
                    local_artifact_path=$(IFS=','; echo "${local_artifact_paths[*]}")
                fi
            else
                # Unix: use tar
                archive_output=$(cd "$artifact_dir" && tar czf "$archive_name" "${archive_files[@]}" 2>&1)
                if [[ -f "$archive_path" ]]; then
                    _log_ok "Created archive: $archive_path"
                    # Update artifact path to point to the archive
                    local_artifact_path="$archive_path"
                    local_artifact_paths=("$archive_path")
                else
                    _log_warn "Failed to create tar archive"
                    _log_warn "tar output: $archive_output"
                    echo "Archive creation failed: $archive_output" >> "$log_file"
                    # Fall back to comma-separated paths
                    local_artifact_path=$(IFS=','; echo "${local_artifact_paths[*]}")
                fi
            fi
        else
            # Join paths with comma for JSON output (single binary or no packaging needed)
            local_artifact_path=$(IFS=','; echo "${local_artifact_paths[*]}")
        fi

    elif [[ $exit_code -eq 124 ]]; then
        _log_error "Build timed out on $host after ${_ACT_BUILD_TIMEOUT}s"
        status="timeout"
        exit_code=5
    else
        _log_error "Build failed on $host with exit code $exit_code"
        status="failed"
        exit_code=6
    fi

    # Return JSON result (pointing to LOCAL artifact path)
    # Build artifact_paths array from comma-separated string
    local artifact_paths_json="[]"
    if [[ -n "${local_artifact_path:-}" ]]; then
        artifact_paths_json=$(echo "$local_artifact_path" | tr ',' '\n' | jq -R . | jq -sc .)
    fi

    jq -nc \
        --arg tool "$tool_name" \
        --arg platform "$platform" \
        --arg host "$host" \
        --arg status "$status" \
        --argjson exit_code "$exit_code" \
        --argjson duration "$duration" \
        --arg artifact_path "${local_artifact_path:-}" \
        --argjson artifact_paths "$artifact_paths_json" \
        --arg log_file "$log_file" \
        '{
            tool: $tool,
            platform: $platform,
            host: $host,
            method: "native",
            status: $status,
            exit_code: $exit_code,
            duration_seconds: $duration,
            artifact_path: $artifact_path,
            artifact_paths: $artifact_paths,
            log_file: $log_file
        }'

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

    # Resolve git metadata for manifest (best-effort)
    local git_sha="" git_ref=""
    if command -v git &>/dev/null && [[ -n "${ACT_REPO_LOCAL_PATH:-}" && -d "$ACT_REPO_LOCAL_PATH/.git" ]]; then
        git_sha=$(git -C "$ACT_REPO_LOCAL_PATH" rev-parse HEAD 2>/dev/null || true)
        git_ref=$(git -C "$ACT_REPO_LOCAL_PATH" symbolic-ref -q --short HEAD 2>/dev/null || true)
        if [[ -z "$git_ref" || "$git_ref" == "HEAD" ]]; then
            git_ref=$(git -C "$ACT_REPO_LOCAL_PATH" describe --tags --exact-match 2>/dev/null || true)
        fi
    fi
    [[ -z "$git_ref" ]] && git_ref="v${version#v}"
    [[ -z "$git_sha" ]] && git_sha="0000000000000000000000000000000000000000"

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

            # Run act workflow with version for tag context injection
            local full_output
            full_output=$(act_run_workflow "$local_path" "$workflow" "$job" "push" "$version" "${act_args[@]}" 2>&1) || exit_code=$?

            # Extract JSON from mixed output (act logs + JSON at end)
            # jq -nc outputs single-line compact JSON, so match lines that start with { and end with }
            result=$(echo "$full_output" | grep '^{.*}$' | tail -1)

            # Fallback if no JSON found
            if [[ -z "$result" ]] || ! echo "$result" | jq -e '.' &>/dev/null; then
                _log_warn "Could not parse JSON from act output, creating status from exit code"
                local fallback_status="failed"
                [[ "$exit_code" -eq 0 ]] && fallback_status="success"
                result=$(jq -nc --arg status "$fallback_status" --argjson exit_code "$exit_code" \
                    '{status: $status, exit_code: $exit_code}')
            fi

            # Wrap in consistent format
            result=$(echo "$result" | jq --arg target "$target" --arg method "act" \
                '. + {platform: $target, method: $method}' 2>/dev/null || echo "$result")
        else
            # Run via SSH (native build)
            _log_info "Method: native (host=$host)"
            local full_native_output
            full_native_output=$(act_run_native_build "$tool_name" "$target" "$version" "$run_id") || exit_code=$?
            # Extract JSON from output (native build includes build output + JSON at end)
            result=$(echo "$full_native_output" | grep '^{' | tail -1)
            if [[ -z "$result" ]] || ! echo "$result" | jq -e '.' &>/dev/null; then
                _log_warn "Could not parse JSON from native build output"
                local fallback_status="failed"
                [[ "$exit_code" -eq 0 ]] && fallback_status="success"
                result=$(jq -nc --arg status "$fallback_status" --argjson exit_code "$exit_code" \
                    --arg platform "$target" --arg method "native" \
                    '{status: $status, exit_code: $exit_code, platform: $platform, method: $method}')
            fi
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

    jq -nc \
        --arg tool "$tool_name" \
        --arg version "$version" \
        --arg run_id "$run_id" \
        --arg git_sha "$git_sha" \
        --arg git_ref "$git_ref" \
        --arg status "$overall_status" \
        --argjson exit_code "$overall_exit_code" \
        --argjson duration "$total_duration" \
        --argjson total "$((success_count + fail_count))" \
        --argjson success "$success_count" \
        --argjson failed "$fail_count" \
        --argjson targets "$results_json" \
        '{
            tool: $tool,
            version: $version,
            run_id: $run_id,
            git_sha: $git_sha,
            git_ref: $git_ref,
            status: $status,
            exit_code: $exit_code,
            duration_seconds: $duration,
            summary: {
                total: $total,
                success: $success,
                failed: $failed
            },
            targets: $targets
        }'

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

    local manifest_version
    manifest_version="v${version#v}"

    local git_sha git_ref
    git_sha=$(echo "$result_json" | jq -r '.git_sha // empty' 2>/dev/null)
    git_ref=$(echo "$result_json" | jq -r '.git_ref // empty' 2>/dev/null)

    if [[ -z "$git_sha" || "$git_sha" == "null" ]]; then
        if command -v git &>/dev/null && [[ -n "${ACT_REPO_LOCAL_PATH:-}" && -d "$ACT_REPO_LOCAL_PATH/.git" ]]; then
            git_sha=$(git -C "$ACT_REPO_LOCAL_PATH" rev-parse HEAD 2>/dev/null || true)
        fi
    fi
    [[ -z "$git_sha" || "$git_sha" == "null" ]] && git_sha="0000000000000000000000000000000000000000"

    if [[ -z "$git_ref" || "$git_ref" == "null" ]]; then
        if command -v git &>/dev/null && [[ -n "${ACT_REPO_LOCAL_PATH:-}" && -d "$ACT_REPO_LOCAL_PATH/.git" ]]; then
            git_ref=$(git -C "$ACT_REPO_LOCAL_PATH" symbolic-ref -q --short HEAD 2>/dev/null || true)
            if [[ -z "$git_ref" || "$git_ref" == "HEAD" ]]; then
                git_ref=$(git -C "$ACT_REPO_LOCAL_PATH" describe --tags --exact-match 2>/dev/null || true)
            fi
        fi
    fi
    [[ -z "$git_ref" || "$git_ref" == "null" ]] && git_ref="$manifest_version"

    local built_at
    built_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    local duration_seconds duration_ms
    duration_seconds=$(echo "$result_json" | jq -r '.duration_seconds // 0' 2>/dev/null || echo 0)
    [[ "$duration_seconds" =~ ^[0-9]+$ ]] || duration_seconds=0
    duration_ms=$((duration_seconds * 1000))

    local artifacts=()
    local seen_paths=()

    _act_manifest_add_file() {
        local file="$1"
        local target="$2"

        [[ -z "$file" || ! -f "$file" ]] && return 0
        [[ -z "$target" ]] && return 0

        local name
        name=$(basename "$file")

        case "$name" in
            *.minisig|*.sig|*.sha256|*.sha512|SHA256SUMS*|*.sbom.*|*.intoto.jsonl)
                return 0
                ;;
        esac

        for seen in "${seen_paths[@]}"; do
            [[ "$seen" == "$file" ]] && return 0
        done

        local sha size format
        sha=$(_act_sha256 "$file" 2>/dev/null || echo "")
        size=$(_act_file_size "$file")
        format=$(_act_archive_format "$name")

        if [[ -z "$sha" ]]; then
            _log_warn "Unable to compute SHA256 for artifact: $file"
            return 0
        fi
        if [[ -z "$size" || "$size" -le 0 ]]; then
            _log_warn "Unable to determine size for artifact: $file"
            return 0
        fi

        local sig_file=""
        local signed=false
        if [[ -f "${file}.minisig" ]]; then
            signed=true
            sig_file=$(basename "${file}.minisig")
        fi

        local artifact_json
        artifact_json=$(jq -nc \
            --arg name "$name" \
            --arg target "$target" \
            --arg sha "$sha" \
            --argjson size "$size" \
            --arg format "$format" \
            --argjson signed "$signed" \
            --arg sig "$sig_file" \
            '{
                name: $name,
                target: $target,
                sha256: $sha,
                size_bytes: $size,
                archive_format: $format,
                signed: $signed,
                signature_file: $sig
            }')

        artifacts+=("$artifact_json")
        seen_paths+=("$file")
    }

    _act_sha256_zip_entry() {
        local zip_file="$1"
        local entry="$2"

        if command -v sha256sum &>/dev/null; then
            unzip -p "$zip_file" "$entry" 2>/dev/null | sha256sum | awk '{print $1}'
            return 0
        fi

        if command -v shasum &>/dev/null; then
            unzip -p "$zip_file" "$entry" 2>/dev/null | shasum -a 256 | awk '{print $1}'
            return 0
        fi

        return 3
    }

    _act_zip_entry_size() {
        local zip_file="$1"
        local entry="$2"
        unzip -p "$zip_file" "$entry" 2>/dev/null | wc -c | tr -d ' '
    }

    _act_manifest_add_zip_entries() {
        local zip_file="$1"
        local target="$2"
        local version_tag="$manifest_version"
        local version_stripped="${manifest_version#v}"

        if ! command -v unzip &>/dev/null; then
            _log_warn "unzip not available; treating $zip_file as artifact"
            _act_manifest_add_file "$zip_file" "$target"
            return 0
        fi

        local entries
        entries=$(unzip -Z1 "$zip_file" 2>/dev/null)
        if [[ -z "$entries" ]]; then
            _log_warn "No entries found in zip artifact: $zip_file"
            return 0
        fi

        local -a matched_entries=()
        while IFS= read -r entry; do
            [[ -z "$entry" || "$entry" == */ ]] && continue
            if [[ "$entry" == *"$version_tag"* || "$entry" == *"$version_stripped"* ]]; then
                matched_entries+=("$entry")
            fi
        done <<< "$entries"

        local -a use_entries=()
        if [[ ${#matched_entries[@]} -gt 0 ]]; then
            use_entries=("${matched_entries[@]}")
        else
            while IFS= read -r entry; do
                [[ -z "$entry" || "$entry" == */ ]] && continue
                use_entries+=("$entry")
            done <<< "$entries"
        fi

        local entry
        for entry in "${use_entries[@]}"; do
            local name
            name=$(basename "$entry")

            case "$name" in
                *.minisig|*.sig|*.sha256|*.sha512|SHA256SUMS*|*.sbom.*|*.intoto.jsonl)
                    continue
                    ;;
            esac

            local seen_key="${zip_file}::${entry}"
            for seen in "${seen_paths[@]}"; do
                [[ "$seen" == "$seen_key" ]] && continue 2
            done

            local sha size format
            sha=$(_act_sha256_zip_entry "$zip_file" "$entry" 2>/dev/null || echo "")
            size=$(_act_zip_entry_size "$zip_file" "$entry")
            format=$(_act_archive_format "$name")

            if [[ -z "$sha" ]]; then
                _log_warn "Unable to compute SHA256 for artifact: $zip_file::$entry"
                continue
            fi
            if [[ -z "$size" || "$size" -le 0 ]]; then
                _log_warn "Unable to determine size for artifact: $zip_file::$entry"
                continue
            fi

            local artifact_json
            artifact_json=$(jq -nc \
                --arg name "$name" \
                --arg target "$target" \
                --arg sha "$sha" \
                --argjson size "$size" \
                --arg format "$format" \
                '{
                    name: $name,
                    target: $target,
                    sha256: $sha,
                    size_bytes: $size,
                    archive_format: $format,
                    signed: false,
                    signature_file: ""
                }')

            artifacts+=("$artifact_json")
            seen_paths+=("$seen_key")
        done
    }

    while IFS= read -r target_json; do
        [[ -z "$target_json" ]] && continue
        local target
        target=$(echo "$target_json" | jq -r '.platform // .target // empty' 2>/dev/null)
        local artifact_path
        artifact_path=$(echo "$target_json" | jq -r '.artifact_path // empty' 2>/dev/null)
        local artifact_dir
        artifact_dir=$(echo "$target_json" | jq -r '.artifact_dir // empty' 2>/dev/null)

        if [[ -n "$artifact_path" && -f "$artifact_path" ]]; then
            _act_manifest_add_file "$artifact_path" "$target"
        fi

        if [[ -n "$artifact_dir" && -d "$artifact_dir" ]]; then
            while IFS= read -r -d '' file; do
                if [[ "$file" == *.zip ]]; then
                    _act_manifest_add_zip_entries "$file" "$target"
                else
                    _act_manifest_add_file "$file" "$target"
                fi
            done < <(find "$artifact_dir" -type f -print0 2>/dev/null)
        fi
    done < <(echo "$result_json" | jq -c '.targets[]?' 2>/dev/null || true)

    local artifacts_json="[]"
    if [[ ${#artifacts[@]} -gt 0 ]]; then
        artifacts_json=$(printf '%s\n' "${artifacts[@]}" | jq -s '.')
    fi

    local manifest
    manifest=$(jq -nc \
        --arg tool "$tool" \
        --arg version "$manifest_version" \
        --arg run_id "$run_id" \
        --arg git_sha "$git_sha" \
        --arg git_ref "$git_ref" \
        --arg built_at "$built_at" \
        --arg status "$status" \
        --argjson duration_ms "$duration_ms" \
        --argjson artifacts "$artifacts_json" \
        '{
            schema_version: "1.0.0",
            tool: $tool,
            version: $version,
            run_id: $run_id,
            git_sha: $git_sha,
            git_ref: $git_ref,
            built_at: $built_at,
            duration_ms: $duration_ms,
            status: $status,
            artifacts: $artifacts
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
export -f act_get_build_cmd act_get_build_env act_get_repo act_get_local_path
export -f act_run_native_build act_orchestrate_build act_generate_manifest
export -f act_sync_sources
