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

# Keep terminal statuses visible to the caller so a stopped install cannot be
# reported as an ordinary failure or followed by another executable probe.
canary_fail() {
    failure_status=\$1
    shift
    printf '%s\n' "\$*" >&2
    if [ "\$failure_status" -eq 5 ] || [ "\$failure_status" -eq 124 ] ||
       { [ "\$failure_status" -ge 129 ] && [ "\$failure_status" -le 192 ]; }; then
        exit "\$failure_status"
    fi
    exit 1
}

echo "=== Canary test: $tool on $image (mode: $mode) ==="

# Install dependencies
sh -c "$install_deps" || canary_fail \$? "Dependency installation failed"

# Run installer
echo "Installing $tool..."
if [ "$installer_source" = /install.sh ]; then
    # Local installer
    bash /install.sh$installer_args_shell 2>&1 || canary_fail \$? "Installer failed"
else
    # Complete acquisition before executing any installer bytes. This also
    # preserves curl failures when the bootstrap shell has no pipefail.
    installer_download=\$(mktemp) || canary_fail \$? "Could not prepare installer download"
    trap 'rm -f "\$installer_download"' EXIT
    curl -A "dsr-canary (+https://github.com/Dicklesworthstone/doodlestein_self_releaser)" \\
        -fsSL --connect-timeout 15 -o "\$installer_download" $(_canary_shell_escape "$installer_source") ||
        canary_fail \$? "Installer download failed"
    bash "\$installer_download"$installer_args_shell 2>&1 || canary_fail \$? "Installer failed"
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
        canary_fail "\$status" "✗ \$binary_name --version failed (exit: \$status)"
    fi

    # Try --help
    if "\$binary_name" --help >/tmp/dsr-canary-help.txt 2>&1; then
        head -5 /tmp/dsr-canary-help.txt
        echo "✓ \$binary_name --help works"
    else
        status=\$?
        head -5 /tmp/dsr-canary-help.txt
        canary_fail "\$status" "✗ \$binary_name --help failed (exit: \$status)"
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

    output=$(_canary_run_with_timeout "$CANARY_TIMEOUT" docker build -t "$tag" "$tmpdir" 2>&1) || status=$?
    if [[ $status -ne 0 ]]; then
        log_error "Failed to build Docker image (exit $status)"
        [[ -z "$output" ]] || printf '%s\n' "$output" >&2
        return "$status"
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

# Resolve the selected tools once so every matrix cell exercises the same set.
# An empty explicit selection is an error, not a request to test everything.
_canary_select_tools() {
    local supplied="${1:-false}" selection="${2:-}"
    local installer_directory installer tool
    local tools=()
    if [[ "$supplied" == true ]]; then
        if [[ ! "$selection" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*(,[A-Za-z0-9][A-Za-z0-9._-]*)*$ ]]; then
            log_error "Expected a nonempty comma-separated list of canary tools"
            return 4
        fi
        IFS=',' read -ra tools <<< "$selection"
    else
        installer_directory=$(_canary_installer_directory) || return $?
        for installer in "$installer_directory"/*/install.sh; do
            [[ -f "$installer" ]] || continue
            tool="${installer%/install.sh}"
            tool="${tool##*/}"
            if [[ ! "$tool" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
                log_error "Invalid canary tool directory: $tool"
                return 4
            fi
            tools+=("$tool")
        done
    fi
    if [[ ${#tools[@]} -eq 0 ]]; then
        log_error "No canary tools selected; generate installers or pass --tools"
        return 4
    fi
    printf '%s\n' "${tools[@]}" | LC_ALL=C sort -u
}

# Accept only actual, self-consistent rows for the requested image/mode/tools.
# A partial result can still preserve useful evidence, but cannot pass a matrix.
_canary_validate_image_result() {
    jq -ces --arg image "$1" --arg mode "$2" --argjson tools "$3" --argjson code "${4:-0}" '
        if length != 1 then error("expected one image result") else .[0] end |
        select(type == "object" and .image == $image and .mode == $mode and
            (.results | type) == "array" and
            all(.results[];
                (.tool | type) == "string" and
                (.status == "passed" or .status == "failed") and
                (.duration | type) == "number" and .duration >= 0 and
                (.duration | floor) == .duration and
                (if has("exit_code") then
                    (.exit_code | type) == "number" and
                    (.exit_code | floor) == .exit_code and
                    .exit_code >= 0 and .exit_code <= 255 and
                    ((.status == "passed" and .exit_code == 0) or
                     (.status == "failed" and .exit_code != 0))
                 else true end)) and
            ([.results[].tool] | unique | length) == (.results | length) and
            (([.results[].tool] - $tools) | length) == 0 and
            .passed == ([.results[] | select(.status == "passed")] | length) and
            .failed == ([.results[] | select(.status == "failed")] | length) and
            .total == (.results | length) and
            (if has("exit_code") then .exit_code == $code else true end) and
            (if has("expected") then .expected == ($tools | length) else true end) and
            (if has("complete") then (.complete | type) == "boolean" else true end))'
}

# Run canary tests for all tools on a specific image
# Usage: canary_run_image <image> [--tools tool1,tool2,...] [--mode vibe|safe]
canary_run_image() {
    local image="${1:-}"
    [[ -n "$image" ]] || { log_error "Canary image is required"; return 4; }
    shift

    local tools=() selection="" selection_given=false selected_tools
    local mode="vibe"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tools)
                [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || {
                    log_error "--tools requires a nonempty tool list"; return 4;
                }
                selection="$2"
                selection_given=true
                shift 2
                ;;
            --mode)
                [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || {
                    log_error "--mode requires vibe or safe"; return 4;
                }
                mode="$2"
                shift 2
                ;;
            *)
                log_error "Unknown canary image option: $1"
                return 4
                ;;
        esac
    done
    case "$mode" in vibe|safe) ;; *) log_error "Invalid canary mode: $mode"; return 4 ;; esac
    selected_tools=$(_canary_select_tools "$selection_given" "$selection") || return $?
    mapfile -t tools <<< "$selected_tools"

    local passed=0 failed=0 status=0 complete=true
    local results=()
    local tool start_time tool_status row
    for tool in "${tools[@]}"; do
        log_info "Testing $tool on $image (mode: $mode)..."
        start_time=$(date +%s)
        tool_status=0
        canary_run_test "$tool" "$image" "$mode" || tool_status=$?
        if [[ $tool_status -eq 0 ]]; then
            log_ok "  $tool: PASSED"
            ((passed++))
        else
            log_error "  $tool: FAILED"
            ((failed++))
            [[ $status -ne 0 && $status -ne 1 ]] || status=$tool_status
        fi
        row=$(jq -nc --arg tool "$tool" --argjson code "$tool_status" \
            --argjson duration "$(($(date +%s) - start_time))" \
            '{tool: $tool, status: (if $code == 0 then "passed" else "failed" end),
              duration: $duration, exit_code: $code}') || return 3
        results+=("$row")
        if [[ $tool_status -eq 5 || ( $tool_status -ge 129 && $tool_status -le 192 ) ]]; then
            status=$tool_status
            complete=false
            break
        fi
    done

    local results_json
    results_json=$(printf '%s\n' "${results[@]}" | jq -sc '.') || return 3

    jq -nc \
        --arg image "$image" \
        --arg mode "$mode" \
        --argjson passed "$passed" \
        --argjson failed "$failed" \
        --argjson expected "${#tools[@]}" \
        --argjson complete "$complete" \
        --argjson code "$status" \
        --argjson results "$results_json" \
        '{
            image: $image,
            mode: $mode,
            passed: $passed,
            failed: $failed,
            total: ($passed + $failed),
            expected: $expected,
            complete: $complete,
            exit_code: $code,
            results: $results
        }' || return 3

    return "$status"
}

# Run the full test matrix
# Usage: canary_run_matrix [--tools tool1,tool2,...] [--modes vibe,safe]
canary_run_matrix() {
    local selection="" selection_given=false selected_tools tools_csv
    local tools=()
    local modes=("${CANARY_MODES[@]}")

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tools)
                [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || {
                    log_error "--tools requires a nonempty tool list"; return 4;
                }
                selection="$2"
                selection_given=true
                shift 2
                ;;
            --modes)
                [[ $# -ge 2 && "$2" =~ ^(vibe|safe)(,(vibe|safe))*$ ]] || {
                    log_error "--modes requires a comma-separated list of vibe or safe"; return 4;
                }
                IFS=',' read -ra modes <<< "$2"
                shift 2
                ;;
            *)
                log_error "Unknown canary matrix option: $1"
                return 4
                ;;
        esac
    done

    if [[ ${#CANARY_MATRIX[@]} -eq 0 || ${#modes[@]} -eq 0 ]]; then
        log_error "Canary matrix requires at least one image and mode"
        return 4
    fi
    local image mode
    for image in "${CANARY_MATRIX[@]}"; do
        [[ -n "$image" && "$image" != -* && "$image" != *[[:space:]]* ]] || {
            log_error "Invalid canary matrix image: $image"; return 4;
        }
    done
    for mode in "${modes[@]}"; do
        case "$mode" in vibe|safe) ;; *) log_error "Invalid canary mode: $mode"; return 4 ;; esac
    done
    selected_tools=$(_canary_select_tools "$selection_given" "$selection") || return $?
    mapfile -t tools <<< "$selected_tools"
    tools_csv=$(IFS=','; printf '%s' "${tools[*]}")
    local tools_json images_json modes_json
    tools_json=$(printf '%s\n' "${tools[@]}" | jq -Rsc 'split("\n")[:-1]') || return 3
    images_json=$(printf '%s\n' "${CANARY_MATRIX[@]}" | jq -Rsc 'split("\n")[:-1]') || return 3
    modes_json=$(printf '%s\n' "${modes[@]}" | jq -Rsc 'split("\n")[:-1]') || return 3

    local total_passed=0 total_failed=0 errors=0 status=0
    local image_results=()
    local result child_status cell_status cell_error cell_complete cell_total reported_complete passed failed
    for image in "${CANARY_MATRIX[@]}"; do
        for mode in "${modes[@]}"; do
            log_info "=== Matrix: $image ($mode mode) ==="
            child_status=0
            result=$(canary_run_image "$image" --tools "$tools_csv" --mode "$mode") || child_status=$?
            cell_error=""
            cell_complete=true
            if result=$(_canary_validate_image_result "$image" "$mode" "$tools_json" "$child_status" <<< "$result" 2>/dev/null); then
                passed=$(jq -r '.passed' <<< "$result") || return 3
                failed=$(jq -r '.failed' <<< "$result") || return 3
                cell_total=$((passed + failed))
                reported_complete=$(jq -r 'if has("complete") then .complete else true end' <<< "$result") || return 3
                if [[ $cell_total -ne ${#tools[@]} || "$reported_complete" != true ]]; then
                    cell_complete=false
                    cell_error="Canary image did not report every selected tool"
                    [[ $child_status -ne 0 ]] || child_status=3
                elif [[ $child_status -eq 0 && $failed -ne 0 ]]; then
                    cell_error="Canary image reported failures with a successful exit"
                    child_status=3
                elif [[ $child_status -ne 0 && ( $child_status -ne 1 || $failed -eq 0 ) ]]; then
                    cell_error="Canary image exited with status $child_status"
                fi
            else
                passed=0
                failed=0
                cell_complete=false
                cell_error="Canary image produced no valid result"
                [[ $child_status -ne 0 ]] || child_status=3
                result=$(jq -nc --arg image "$image" --arg mode "$mode" \
                    '{image: $image, mode: $mode, passed: 0, failed: 0, total: 0, results: []}') || return 3
            fi
            if [[ $child_status -eq 5 || ( $child_status -ge 129 && $child_status -le 192 ) ]]; then
                cell_complete=false
                cell_error="Canary image was interrupted (status $child_status)"
            fi
            cell_status=passed
            if [[ -n "$cell_error" ]]; then
                cell_status=error
                ((errors++))
                log_error "$cell_error: $image ($mode)"
                [[ $status -ne 0 && $status -ne 1 ]] || status=$child_status
            elif [[ $failed -ne 0 ]]; then
                cell_status=failed
                [[ $status -ne 0 ]] || status=1
            fi
            ((total_passed += passed))
            ((total_failed += failed))
            result=$(jq -c --arg status "$cell_status" --arg error "$cell_error" \
                --argjson code "$child_status" --argjson expected "${#tools[@]}" \
                --argjson complete "$cell_complete" \
                '. + {status: $status, exit_code: $code, expected: $expected, complete: $complete} |
                 if $error != "" then . + {error: $error} else del(.error) end' <<< "$result") || return 3
            image_results+=("$result")
            if [[ $child_status -eq 5 || ( $child_status -ge 129 && $child_status -le 192 ) ]]; then
                status=$child_status
                break 2
            fi
        done
    done

    log_info "=== Matrix Summary ==="
    log_info "Total passed: $total_passed"
    log_info "Total failed: $total_failed"
    log_info "Execution errors: $errors"

    local results_json
    results_json=$(printf '%s\n' "${image_results[@]}" | jq -sc '.') || return 3
    jq -nc --argjson tools "$tools_json" --argjson images "$images_json" \
        --argjson modes "$modes_json" --argjson results "$results_json" \
        --argjson passed "$total_passed" --argjson failed "$total_failed" \
        --argjson errors "$errors" --argjson code "$status" '
        {
            type: "matrix",
            status: (if $code == 0 then "passed" elif $errors > 0 then "error" else "failed" end),
            exit_code: $code,
            tools: $tools,
            images: $images,
            modes: $modes,
            passed: $passed,
            failed: $failed,
            total: ($passed + $failed),
            expected: (($tools | length) * ($images | length) * ($modes | length)),
            errors: $errors,
            complete: (($results | length) == (($images | length) * ($modes | length)) and
                       all($results[]; .complete)),
            results: $results
        }' || return 3
    return "$status"
}

# ============================================================================
# macOS Testing (via SSH)
# ============================================================================

# Run canary test on macOS via SSH
# Usage: canary_run_macos <tool> <host> <mode> [verbose]
canary_run_macos() {
    local tool="$1"
    local host="${2:-mmini}"
    local mode="${3:-vibe}"
    local verbose="${4:-false}"

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

    # Preserve interruption and transport status from the connectivity probe.
    local output status=0
    _canary_run_with_timeout 5 ssh -o ConnectTimeout=3 -o BatchMode=yes "$host" "echo ok" \
        &>/dev/null || status=$?
    if [[ $status -ne 0 ]]; then
        log_error "Cannot connect to $host"
        return "$status"
    fi

    local remote_script remote_cmd local_source=false
    [[ ! -f "$installer_source" ]] || local_source=true
    remote_script=$(cat <<SCRIPT
set -uo pipefail
canary_fail() {
    failure_status=\$1
    shift
    printf '%s\n' "\$*" >&2
    if [ "\$failure_status" -eq 5 ] || [ "\$failure_status" -eq 124 ] ||
       { [ "\$failure_status" -ge 129 ] && [ "\$failure_status" -le 192 ]; }; then
        exit "\$failure_status"
    fi
    exit 1
}
canary_dir=\$(mktemp -d "\${TMPDIR:-/tmp}/dsr-canary.XXXXXXXX") ||
    canary_fail \$? 'Could not prepare installer directory'
trap 'rm -rf -- "\$canary_dir"' EXIT
trap 'exit 5' HUP INT TERM
if $local_source; then
    cat > "\$canary_dir/install.sh" || canary_fail \$? 'Installer transfer failed'
else
    curl -A 'dsr-canary (+https://github.com/Dicklesworthstone/doodlestein_self_releaser)' \\
        -fsSL --connect-timeout 15 -o "\$canary_dir/install.sh" $(_canary_shell_escape "$installer_source") ||
        canary_fail \$? 'Installer download failed'
fi
bash "\$canary_dir/install.sh"$installer_args_shell || canary_fail \$? 'Installer failed'
export PATH="\$HOME/.local/bin:/usr/local/bin:/usr/bin:\$PATH"
binary_name=$(_canary_shell_escape "$binary_name")
command -v "\$binary_name" >/dev/null 2>&1 || { echo "Missing installed executable: \$binary_name" >&2; exit 1; }
"\$binary_name" --version || canary_fail \$? 'Installed executable --version failed'
if "\$binary_name" --help > "\$canary_dir/help.txt" 2>&1; then
    head -5 "\$canary_dir/help.txt"
else
    status=\$?
    head -5 "\$canary_dir/help.txt" >&2
    canary_fail "\$status" 'Installed executable --help failed'
fi
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
        [[ "$verbose" != true || -z "$output" ]] || printf '%s\n' "$output" >&2
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
