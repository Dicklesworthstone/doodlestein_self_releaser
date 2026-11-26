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

# shellcheck source=src/guardrails.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/guardrails.sh" || { return 3 2>/dev/null || exit 3; }

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

_canary_run_with_timeout() {
    run_with_timeout "$@"
}

# Shell-escape a string for safe remote execution (single-quote strategy)
_canary_shell_escape() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\"'\"'/g")"
}

# Use the same generated-installer destination as `dsr installer generate`.
_canary_installer_directory() {
    local script_dir="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
    printf '%s\n' "${DSR_INSTALLER_DIR:-$script_dir/installers}"
}

# Resolve the actual repository before choosing a local or upstream installer.
# The public tool key may be an alias, and a configured fork must never silently
# run the checked-in installer's original repository instead. Read configuration
# explicitly: a malformed file is not evidence that no override exists.
_canary_installer_source() {
    local tool="$1" config_dir="${DSR_CONFIG_DIR:-$HOME/.config/dsr}"
    local registry="${DSR_REPOS_FILE:-$config_dir/repos.yaml}"
    local tool_config="$config_dir/repos.d/$tool.yaml" config='{}' document
    local repo script_path configured_repo local_installer declaration
    [[ "$tool" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 4
    command -v jq >/dev/null 2>&1 || return 3

    if [[ -e "$registry" || -L "$registry" || -e "$tool_config" || -L "$tool_config" ]]; then
        command -v yq >/dev/null 2>&1 &&
            declare -F _config_read_single_mapping_json >/dev/null || {
                log_error "Configuration support and yq are required to select a canary installer"
                return 3
            }
    fi
    if [[ -e "$registry" || -L "$registry" ]]; then
        document=$(_config_read_single_mapping_json "$registry") || return $?
        config=$(jq -ce --arg tool "$tool" '
            (if has("tools") then .tools else {} end) |
            if type != "object" then error("tools must be a mapping")
            elif has($tool) then .[$tool] | if type == "object" then . else error("tool must be a mapping") end
            else {} end' <<< "$document") || return 4
        config=$(jq -c 'if has("repo") then . elif (.github | type) == "object" then
            if (.github | has("repo")) then . + {repo:.github.repo} else . end else . end' \
            <<< "$config") || return 4
    fi
    if [[ -e "$tool_config" || -L "$tool_config" ]]; then
        document=$(_config_read_single_mapping_json "$tool_config") || return $?
        # Normalize the older nested spelling before merging, so a per-tool
        # github.repo also overrides a flat repository in the registry.
        document=$(jq -c 'if has("repo") then . elif (.github | type) == "object" then
            if (.github | has("repo")) then . + {repo:.github.repo} else . end else . end' \
            <<< "$document") || return 4
        config=$(printf '%s\n' "$config" "$document" | jq -sc '.[0] + .[1]') || return 4
    fi
    configured_repo=$(jq -r 'has("repo")' <<< "$config") || return 4
    repo=$(jq -er --arg default "Dicklesworthstone/$tool" '
        (if has("repo") then .repo else $default end) |
        strings | select(test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$") and
            (test("[\u0000-\u001f\u007f]") | not))' <<< "$config") || {
        log_error "Invalid canary repository for $tool"
        return 4
    }
    script_path=$(jq -er '
        (if has("install_script_path") then .install_script_path else "install.sh" end) |
        strings | select(length > 0 and (test("[\u0000-\u001f\u007f\\\\]") | not) and
            (split("/") | all(. != "" and . != "." and . != "..")))' <<< "$config") || {
        log_error "Invalid canary install_script_path for $tool"
        return 4
    }
    local_installer="$(_canary_installer_directory)/$tool/install.sh"
    if [[ -f "$local_installer" && "$script_path" == install.sh ]]; then
        # Generated installers declare REPO once using a literal assignment.
        # Do not source executable code to discover its repository. An unknown
        # or conflicting declaration cannot override an explicit config.
        declaration=$(sed -n '/^REPO=/p' "$local_installer") || return 4
        if [[ "$configured_repo" == false || "$declaration" == "REPO='$repo'" ||
              "$declaration" == "REPO=\"$repo\"" ]]; then
            printf '%s\n' "$local_installer"
            return 0
        fi
        log_info "Using $repo installer instead of a local installer with a different repository binding"
    fi
    script_path=$(printf '%s' "$script_path" | jq -sRr 'split("/") | map(@uri) | join("/")') || return 4
    printf 'https://raw.githubusercontent.com/%s/main/%s\n' "$repo" "$script_path"
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
    shift
    local packages="curl ca-certificates"
    local package
    for package in "$@"; do
        if [[ ! "$package" =~ ^[A-Za-z0-9.+_-]+$ ]]; then
            log_error "Invalid canary prerequisite package: $package"
            return 4
        fi
        packages+=" $package"
    done

    case "$image" in
        ubuntu*|debian*)
            echo "apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $packages"
            ;;
        fedora*|centos*|rhel*)
            echo "dnf install -y -q $packages"
            ;;
        alpine*)
            echo "apk add --no-cache bash $packages"
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

# Resolve the executable name independently from the repository/tool key.  A
# number of repositories intentionally ship a shorter binary name (for
# example, frankenterm ships `ft`).
_canary_get_binary_name() {
    local tool="$1"
    local binary_name=""

    if declare -F config_get_tool_field &>/dev/null; then
        binary_name=$(config_get_tool_field "$tool" "binary_name" "" 2>/dev/null || echo "")
    fi
    [[ -n "$binary_name" ]] || binary_name="$tool"
    if [[ ! "$binary_name" =~ ^[A-Za-z0-9._+-]+$ ]]; then
        log_error "Invalid canary binary_name for $tool"
        return 4
    fi
    printf '%s\n' "$binary_name"
}

# Emit one installer argument per line.  Generated DSR installers use the
# historical mode flags by default; repositories with an owned installer can
# declare `canary_installer_args` in repos.d/<tool>.yaml, including an empty
# array when the installer needs no arguments.
_canary_get_installer_args() {
    local tool="$1"
    local mode="$2"
    local config_dir="${DSR_CONFIG_DIR:-$HOME/.config/dsr}"
    local config_file="$config_dir/repos.d/$tool.yaml"

    if [[ -f "$config_file" ]] && command -v yq &>/dev/null && \
       yq -e 'has("canary_installer_args")' "$config_file" >/dev/null 2>&1; then
        if ! command -v jq &>/dev/null; then
            log_error "jq is required to read canary_installer_args"
            return 3
        fi
        local args_json
        if ! args_json=$(yq -o=json -I=0 '.canary_installer_args' \
                "$config_file" 2>/dev/null); then
            log_error "Invalid canary_installer_args configuration for $tool"
            return 4
        fi
        if ! jq -e '
                if type == "array" and
                   all(.[]; type == "string" and length > 0 and
                            (contains("\n") | not) and (contains("\r") | not))
                then true
                else error("canary_installer_args must be an array of non-empty single-line strings")
                end
            ' <<< "$args_json" >/dev/null; then
            log_error "Invalid canary_installer_args configuration for $tool"
            return 4
        fi
        jq -r '.[]' <<< "$args_json"
        return 0
    fi

    printf '%s\n' --mode "$mode" --non-interactive
}

# Emit package-manager names that the owned installer deliberately treats as
# prerequisites rather than bootstrapping itself.  The same conservative token
# grammar is valid for apt, dnf, and apk package names and prevents this config
# from becoming shell source inside the generated container script.
_canary_get_packages() {
    local tool="$1"
    local config_dir="${DSR_CONFIG_DIR:-$HOME/.config/dsr}"
    local config_file="$config_dir/repos.d/$tool.yaml"

    [[ -f "$config_file" ]] || return 0
    if ! command -v yq &>/dev/null || ! command -v jq &>/dev/null; then
        log_error "yq and jq are required to read canary_packages"
        return 3
    fi
    if ! yq -e 'has("canary_packages")' "$config_file" >/dev/null 2>&1; then
        return 0
    fi

    local packages_json
    if ! packages_json=$(yq -o=json -I=0 '.canary_packages' \
            "$config_file" 2>/dev/null); then
        log_error "Invalid canary_packages configuration for $tool"
        return 4
    fi
    if ! jq -e '
            if type == "array" and
               all(.[]; type == "string" and test("^[A-Za-z0-9.+_-]+$"))
            then true
            else error("canary_packages must be an array of safe package names")
            end
        ' <<< "$packages_json" >/dev/null; then
        log_error "Invalid canary_packages configuration for $tool"
        return 4
    fi
    jq -r '.[]' <<< "$packages_json"
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

    if [[ ! "$tool" =~ ^[A-Za-z0-9._-]+$ ]]; then
        log_error "Invalid canary tool name: $tool"
        return 4
    fi
    case "$mode" in
        vibe|safe) ;;
        *)
            log_error "Invalid canary mode: $mode"
            return 4
            ;;
    esac

    local binary_name
    binary_name=$(_canary_get_binary_name "$tool") || return $?
    local installer_args_output
    installer_args_output=$(_canary_get_installer_args "$tool" "$mode") || return $?
    local -a installer_args=()
    if [[ -n "$installer_args_output" ]]; then
        mapfile -t installer_args <<< "$installer_args_output"
    fi
    local installer_args_shell=""
    local installer_arg
    for installer_arg in "${installer_args[@]}"; do
        installer_args_shell+=" $(_canary_shell_escape "$installer_arg")"
    done
    local canary_packages_output
    canary_packages_output=$(_canary_get_packages "$tool") || return $?
    local -a canary_packages=()
    if [[ -n "$canary_packages_output" ]]; then
        mapfile -t canary_packages <<< "$canary_packages_output"
    fi

    local installer_source
    installer_source=$(_canary_installer_source "$tool") || return $?

    # Prepare test directory.
    # RETURN handles normal exit; INT/TERM cover the common case where
    # the user Ctrl-C's during `docker build` or `docker run` (the
    # most time-consuming steps below).  We expand $tmpdir at trap
    # set time so the cleanup still works even after `local` scope
    # would otherwise hide it.
    local tmpdir
    tmpdir=$(mktemp -d) || return 1
    # shellcheck disable=SC2064  # We want $tmpdir expanded now, at trap definition time
    trap "rm -rf '$tmpdir' 2>/dev/null; trap - RETURN INT TERM" RETURN INT TERM

    # Create test script
    local install_deps
    install_deps=$(_canary_get_install_cmd "$image" "${canary_packages[@]}") || return $?
    local shell
    shell=$(_canary_get_shell "$image")

    # If we have a local installer, copy it
    if [[ -f "$installer_source" ]]; then
        cp "$installer_source" "$tmpdir/install.sh" || return 1
        chmod +x "$tmpdir/install.sh" || return 1
        installer_source="/install.sh"
    fi

    # Create the test script
    cat > "$tmpdir/test.sh" << TESTSCRIPT
#!/usr/bin/env $shell
set -u
if (set -o pipefail) 2>/dev/null; then
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
if [ "$installer_source" = /install.sh ]; then
    # Local installer
    if ! bash /install.sh$installer_args_shell 2>&1; then
        echo "Installer failed" >&2
        exit 1
    fi
else
    # Complete acquisition before executing any installer bytes. This also
    # preserves curl failures when the bootstrap shell has no pipefail.
    installer_download=\$(mktemp) || exit 1
    trap 'rm -f "\$installer_download"' EXIT
    if ! curl -A "dsr-canary (+https://github.com/Dicklesworthstone/doodlestein_self_releaser)" \\
        -fsSL --connect-timeout 15 -o "\$installer_download" $(_canary_shell_escape "$installer_source"); then
        echo "Installer download failed" >&2
        exit 1
    fi
    if ! bash "\$installer_download"$installer_args_shell 2>&1; then
        echo "Installer failed" >&2
        exit 1
    fi
fi

export PATH="\$HOME/.local/bin:/usr/local/bin:/usr/bin:\$PATH"

# Verify installation
echo ""
echo "=== Verification ==="

# Check if binary is in PATH
binary_name=$(_canary_shell_escape "$binary_name")
if command -v "\$binary_name" >/dev/null 2>&1; then
    echo "✓ \$binary_name found in PATH"

    # Try --version
    if "\$binary_name" --version 2>&1; then
        echo "✓ \$binary_name --version works"
    else
        status=\$?
        echo "✗ \$binary_name --version failed (exit: \$status)" >&2
        exit 1
    fi

    # Try --help
    if "\$binary_name" --help >/tmp/dsr-canary-help.txt 2>&1; then
        head -5 /tmp/dsr-canary-help.txt
        echo "✓ \$binary_name --help works"
    else
        status=\$?
        head -5 /tmp/dsr-canary-help.txt
        echo "✗ \$binary_name --help failed (exit: \$status)" >&2
        exit 1
    fi
else
    echo "✗ \$binary_name NOT found in PATH"
    echo "PATH: \$PATH"

    # Check common install locations
    for dir in /usr/local/bin /usr/bin ~/.local/bin; do
        if [ -f "\$dir/\$binary_name" ]; then
            echo "Found at: \$dir/\$binary_name"
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
        local installer_directory
        installer_directory=$(_canary_installer_directory) || return $?
        while IFS= read -r -d '' dir; do
            tools+=("$(basename "$dir")")
        done < <(find "$installer_directory" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
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

    if [[ ! "$tool" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ || -z "$host" ||
          "$host" == -* || "$host" == *[[:space:]]* || "$host" == *[[:cntrl:]]* ]]; then
        log_error "Invalid canary tool or SSH host"
        return 4
    fi
    case "$mode" in vibe|safe) ;; *) log_error "Invalid canary mode: $mode"; return 4 ;; esac
    local installer_source binary_name installer_args_output installer_arg installer_args_shell=""
    installer_source=$(_canary_installer_source "$tool") || return $?
    binary_name=$(_canary_get_binary_name "$tool") || return $?
    installer_args_output=$(_canary_get_installer_args "$tool" "$mode") || return $?
    while IFS= read -r installer_arg; do
        [[ -n "$installer_arg" ]] || continue
        installer_args_shell+=" $(_canary_shell_escape "$installer_arg")"
    done <<< "$installer_args_output"

    log_info "Running canary test for $tool on macOS ($host)..."

    # Check SSH connectivity
    if ! _canary_run_with_timeout 5 ssh -o ConnectTimeout=3 -o BatchMode=yes "$host" "echo ok" &>/dev/null; then
        log_error "Cannot connect to $host"
        return 1
    fi

    local output
    local status=0
    local remote_script remote_cmd local_source=false
    [[ ! -f "$installer_source" ]] || local_source=true
    remote_script=$(cat <<SCRIPT
set -uo pipefail
canary_dir=\$(mktemp -d "\${TMPDIR:-/tmp}/dsr-canary.XXXXXXXX") || exit 1
trap 'rm -rf -- "\$canary_dir"' EXIT
trap 'exit 5' HUP INT TERM
if $local_source; then
    cat > "\$canary_dir/install.sh" || exit 1
else
    if ! curl -A 'dsr-canary (+https://github.com/Dicklesworthstone/doodlestein_self_releaser)' \\
        -fsSL --connect-timeout 15 -o "\$canary_dir/install.sh" $(_canary_shell_escape "$installer_source"); then
        echo 'Installer download failed' >&2
        exit 1
    fi
fi
if ! bash "\$canary_dir/install.sh"$installer_args_shell; then
    echo 'Installer failed' >&2
    exit 1
fi
export PATH="\$HOME/.local/bin:/usr/local/bin:/usr/bin:\$PATH"
binary_name=$(_canary_shell_escape "$binary_name")
command -v "\$binary_name" >/dev/null 2>&1 || { echo "Missing installed executable: \$binary_name" >&2; exit 1; }
"\$binary_name" --version || exit 1
if ! "\$binary_name" --help > "\$canary_dir/help.txt" 2>&1; then
    head -5 "\$canary_dir/help.txt" >&2
    exit 1
fi
head -5 "\$canary_dir/help.txt"
SCRIPT
    ) || return 1
    remote_cmd="bash -c $(_canary_shell_escape "$remote_script")"
    if $local_source; then
        output=$(_canary_run_with_timeout "$CANARY_TIMEOUT" ssh -o ConnectTimeout=3 -o BatchMode=yes \
            "$host" "$remote_cmd" < "$installer_source" 2>&1) || status=$?
    else
        output=$(_canary_run_with_timeout "$CANARY_TIMEOUT" ssh -o ConnectTimeout=3 -o BatchMode=yes \
            "$host" "$remote_cmd" </dev/null 2>&1) || status=$?
    fi

    if [[ $status -eq 0 ]]; then
        log_ok "$tool installed and working on $host"
    else
        log_error "$tool canary failed on $host"
        echo "$output" >&2
    fi

    return $status
}

# ============================================================================
# Results Storage
# ============================================================================

# Save canary results to state directory
canary_save_results() {
    local results_json="$1"
    local timestamp stamped tmp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Only a single results object is saved, and latest.json is replaced
    # atomically: unparseable input must never truncate the previous results.
    if ! stamped=$(jq -cse --arg ts "$timestamp" \
            'if length == 1 and (.[0] | type == "object") then .[0] + {timestamp: $ts} else error("not one results object") end' \
            <<< "$results_json" 2>/dev/null); then
        log_error "Canary results are not a JSON object; previous results kept"
        return 1
    fi

    mkdir -p "$CANARY_STATE_DIR" || return 1
    tmp=$(mktemp "$CANARY_STATE_DIR/latest.json.XXXXXX") || return 1
    if ! printf '%s\n' "$stamped" > "$tmp" || ! mv -f "$tmp" "$CANARY_STATE_DIR/latest.json"; then
        rm -f "$tmp"
        return 1
    fi

    # Archive with date
    local date_str
    date_str=$(date +%Y-%m-%d)
    printf '%s\n' "$stamped" >> "$CANARY_STATE_DIR/history-$date_str.jsonl" || return 1

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

CANARY_DEFAULT_SCHEDULE="0 6 * * *"  # 6am daily

# A cron schedule: five fields or an @keyword. Anything else (a newline in
# particular) could add arbitrary crontab lines.
canary_validate_cron() {
    local expr="$1"
    local field='[0-9A-Za-z*/,-]+'
    [[ "$expr" =~ ^@(reboot|yearly|annually|monthly|weekly|daily|midnight|hourly)$ ]] && return 0
    [[ "$expr" =~ ^${field}[[:blank:]]+${field}[[:blank:]]+${field}[[:blank:]]+${field}[[:blank:]]+${field}$ ]]
}

# Print the crontab line that runs the canary suite on <schedule>.
canary_cron_entry() {
    local schedule="${1:-$CANARY_DEFAULT_SCHEDULE}"
    local script_path log_file
    canary_validate_cron "$schedule" || return 4
    script_path="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/dsr"
    log_file="$CANARY_STATE_DIR/cron.log"
    printf '%s %q canary run --all --json >> %q 2>&1\n' "$schedule" "$script_path" "$log_file"
}

# Current crontab, empty when the user has none.
_canary_crontab_current() {
    crontab -l 2>/dev/null || true
}

# Setup daily canary cron job, replacing an existing canary entry.
canary_schedule() {
    local schedule="${1:-$CANARY_DEFAULT_SCHEDULE}"
    local entry current kept

    if ! entry=$(canary_cron_entry "$schedule"); then
        log_error "Invalid cron schedule: $schedule"
        return 4
    fi
    if ! command -v crontab &>/dev/null; then
        log_error "crontab not available; cannot schedule canary runs"
        return 3
    fi

    current=$(_canary_crontab_current)
    if grep -q "dsr canary" <<< "$current"; then
        log_warn "Canary already scheduled. Updating..."
    fi
    kept=$(grep -v "dsr canary" <<< "$current" || true)

    mkdir -p "$CANARY_STATE_DIR" || return 1
    if ! printf '%s%s\n' "${kept:+$kept$'\n'}" "$entry" | crontab -; then
        log_error "crontab rejected the canary entry; schedule unchanged"
        return 1
    fi

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
    local current kept
    if ! command -v crontab &>/dev/null; then
        log_error "crontab not available"
        return 3
    fi
    current=$(_canary_crontab_current)
    if ! grep -q "dsr canary" <<< "$current"; then
        log_info "No canary schedule to remove"
        return 0
    fi
    kept=$(grep -v "dsr canary" <<< "$current" || true)
    if ! printf '%s\n' "$kept" | crontab -; then
        log_error "crontab rejected the update; canary schedule not removed"
        return 1
    fi
    log_ok "Canary schedule removed"
}
