#!/usr/bin/env bash
# src/upgrade_verify.sh - Verify tool upgrade commands work correctly
#
# bd-1jt.5.6: Implement upgrade command verification after release
#
# After releasing binaries, verify that each tool's configured update-check
# command correctly finds the new release assets. The default command is
# `upgrade --check`; repositories with a different CLI contract can set an
# `upgrade_check_args` string array in repos.d/<tool>.yaml.
#
# Usage:
#   source "$SCRIPT_DIR/src/upgrade_verify.sh"
#   upgrade_verify_tool ntm
#   upgrade_verify_all
#
# Required modules:
#   - logging.sh (for log_info, log_error, etc.)
#   - config.sh (for repos config)

# Exported helpers may run in a fresh Bash whose BASH_SOURCE is environment.
# Bind module imports to the actual sourced file, never that child shell cwd.
_DSR_UPGRADE_VERIFY_DIR=$(CDPATH='' cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || { return 3 2>/dev/null || exit 3; }
export _DSR_UPGRADE_VERIFY_DIR
# shellcheck source=src/guardrails.sh
source "$_DSR_UPGRADE_VERIFY_DIR/guardrails.sh" || { return 3 2>/dev/null || exit 3; }

# ============================================================================
# Configuration
# ============================================================================

# Default timeout for upgrade check (seconds)
UPGRADE_VERIFY_TIMEOUT=30

# ============================================================================
# Verification Functions
# ============================================================================

# Verify upgrade command works for a tool
# Args: tool_name [--version <ver>] [--build-from-source]
# Returns: 0 on success, 1 on failure
upgrade_verify_tool() (
    local tool_name="${1:-}"
    shift 1 2>/dev/null || true

    local version=""
    local build_from_source=false
    local dry_run=false
    local structured=false installed_only=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version|-V) [[ $# -ge 2 ]] || return 4; version="$2"; shift 2 ;;
            --build-from-source) build_from_source=true; shift ;;
            --dry-run) dry_run=true; shift ;;
            --json) structured=true; shift ;;
            --installed-only) installed_only=true; shift ;;
            *) shift ;;
        esac
    done

    if [[ -z "$tool_name" ]]; then
        log_error "Tool name required"
        return 4
    fi

    log_info "Verifying upgrade command for $tool_name..."

    local binary_name
    binary_name=$(_upgrade_tool_binary_name "$tool_name")
    local built=false build_planned=false output="" exit_code=null latest_version="" platform
    platform="$(uname -s | tr '[:upper:]' '[:lower:]')/$(uname -m)"

    # Both public output modes report the same attempt. A check that never
    # started has no updater exit code, including planned and failed builds.
    _upgrade_result() {
        local verdict="$1" error="${2:-}"
        $structured || return 0
        printf '%s' "$output" | jq -Rsc --arg tool "$tool_name" --arg binary "$binary_name" \
            --arg platform "$platform" --arg status "$verdict" --arg error "$error" \
            --arg expected "${version#v}" --arg latest "$latest_version" \
            --argjson dry_run "$dry_run" --argjson built "$built" \
            --argjson plan "$build_planned" --argjson code "$exit_code" '
            {tool:$tool, binary:$binary, platform:$platform, status:$status,
             dry_run:$dry_run, built_from_source:$built, build_planned:$plan,
             found_asset:($status == "passed"), exit_code:$code,
             expected_version:(if $expected == "" then null else $expected end),
             latest_version:(if $latest == "" then null else $latest end), output:.}
             + (if $error == "" then {} else {error:$error} end)'
    }

    # Find the tool binary
    local bin_path=""

    # Check if installed in PATH
    if command -v "$binary_name" &>/dev/null; then
        bin_path=$(command -v "$binary_name")
        log_debug "Found $binary_name at: $bin_path"
    elif [[ "$binary_name" != "$tool_name" ]] && command -v "$tool_name" &>/dev/null; then
        bin_path=$(command -v "$tool_name")
        log_debug "Found $tool_name at: $bin_path"
    fi

    # The module's no-argument JSON inventory only inspects installed tools.
    if $installed_only && [[ -z "$bin_path" ]]; then
        _upgrade_result error "Tool not found in PATH"
        return 1
    fi

    # Track if we built from source (for cleanup)
    local built_tmpdir=""

    # Build from source if requested or not found
    if $build_from_source || [[ -z "$bin_path" ]]; then
        local repo_dir
        repo_dir=$(_upgrade_find_repo_dir "$tool_name")

        if [[ -z "$repo_dir" || ! -d "$repo_dir" ]]; then
            log_error "Repository not found for $tool_name"
            _upgrade_result error "Repository not found for $tool_name"
            return 1
        fi

        if $dry_run; then
            # A dry run reports the build; it does not compile anything.
            log_info "[DRY RUN] Would build $binary_name from source in $repo_dir"
            build_planned=true
            bin_path="<$binary_name built from $repo_dir>"
        else
            log_info "Building $binary_name from source for $tool_name..."
            local build_status=0
            bin_path=$(_upgrade_build_tool "$tool_name" "$repo_dir" "$binary_name") || build_status=$?

            if [[ "$build_status" != 0 || -z "$bin_path" || ! -f "$bin_path" ||
                  ! -x "$bin_path" || -L "$bin_path" ]]; then
                log_error "Failed to build $binary_name for $tool_name"
                _upgrade_result failed "Failed to build $binary_name for $tool_name"
                if ((build_status == 5 || build_status == 124 || (build_status >= 129 && build_status <= 255))); then
                    return 5
                fi
                return 1
            fi

            # Track the tmpdir for cleanup (bin_path is like /tmp/xxx/tool)
            built_tmpdir=$(dirname "$bin_path")
            built=true
        fi
    fi

    if [[ -z "$bin_path" ]]; then
        log_error "$binary_name not found in PATH and --build-from-source not specified"
        _upgrade_result error "$binary_name not found"
        return 1
    fi

    local check_args_output
    if ! check_args_output=$(_upgrade_check_args "$tool_name"); then
        log_error "Invalid upgrade_check_args configuration for $tool_name"
        [[ -n "$built_tmpdir" ]] && rm -rf "$built_tmpdir"
        _upgrade_result error "Invalid upgrade_check_args configuration"
        return 4
    fi

    local -a check_args=()
    mapfile -t check_args <<< "$check_args_output"

    local check_command
    printf -v check_command '%q ' "$bin_path" "${check_args[@]}"
    check_command=${check_command% }

    # Run upgrade check
    log_info "Running upgrade check..."
    if $dry_run; then
        log_info "[DRY RUN] Would run: $check_command"
        [[ -n "$built_tmpdir" ]] && rm -rf "$built_tmpdir"
        _upgrade_result planned
        return $?
    fi

    exit_code=0
    output=$(run_with_timeout "$UPGRADE_VERIFY_TIMEOUT" "$bin_path" "${check_args[@]}" 2>&1) || exit_code=$?
    latest_version=$(_upgrade_extract_latest_version "$output")

    # Informational output can precede a failed request or a timeout. Check the
    # actual process result before announcing an update or accepting its version.
    if ! _upgrade_check_succeeded "$exit_code" "$output"; then
        log_error "Upgrade verification FAILED for $tool_name"
        log_error "Exit code: $exit_code"
        log_error "Output: $output"
        [[ -n "$built_tmpdir" ]] && rm -rf "$built_tmpdir"
        _upgrade_result failed
        return 1
    fi

    local current_version=""

    # Check for common success patterns
    # Here-strings keep `grep -q` from SIGPIPE-ing a writer of large output,
    # which pipefail would turn into a missed match.
    if grep -qi "found.*asset\|download.*available\|update.*available" <<< "$output"; then
        log_ok "$tool_name update check: Found update"
    elif grep -qi "up.to.date\|no update\|already.*latest" <<< "$output"; then
        log_ok "$tool_name update check: Up to date"
    else
        log_ok "$tool_name update check: Completed successfully"
    fi

    # Extract versions if present (using portable grep -oE)
    current_version=$(echo "$output" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)

    if [[ -n "$current_version" ]]; then
        log_debug "Current version: $current_version"
    fi
    if [[ -n "$latest_version" ]]; then
        log_debug "Latest version: $latest_version"
    fi

    if [[ -n "$version" ]]; then
        local expected_version="${version#v}"
        if [[ "$latest_version" != "$expected_version" ]]; then
            log_error "$tool_name update check did not resolve the released version"
            log_error "Expected latest version: $expected_version"
            log_error "Observed latest version: ${latest_version:-<none>}"
            [[ -n "$built_tmpdir" ]] && rm -rf "$built_tmpdir"
            _upgrade_result failed
            return 1
        fi
        log_ok "$tool_name update check resolved exact version $expected_version"
    fi

    # Build result
    # Preserve the reported uname platform; normalize the human-facing label.
    local display_platform="$platform"
    case "$platform" in
        linux/x86_64) display_platform="linux/amd64" ;;
        linux/aarch64) display_platform="linux/arm64" ;;
        darwin/x86_64) display_platform="darwin/amd64" ;;
    esac

    # Cleanup built binary tmpdir
    [[ -n "$built_tmpdir" ]] && rm -rf "$built_tmpdir"

    log_ok "Upgrade verification PASSED for $tool_name on $display_platform"
    _upgrade_result passed
)

# Verify upgrade command for all tools
# Args: [--version <ver>] [--build-from-source] [--dry-run]
upgrade_verify_all() (
    local build_from_source=false
    local dry_run=false
    local version=""
    local structured=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --version|-V)
                [[ $# -ge 2 ]] || return 4
                version="$2"; shift 2 ;;
            --build-from-source) build_from_source=true; shift ;;
            --dry-run) dry_run=true; shift ;;
            --json) structured=true; shift ;;
            *) shift ;;
        esac
    done

    local -a args=()
    [[ -z "$version" ]] || args+=(--version "$version")
    $build_from_source && args+=(--build-from-source)
    $dry_run && args+=(--dry-run)

    local repos_dir="${ACT_REPOS_DIR:-${DSR_CONFIG_DIR:-$HOME/.config/dsr}/repos.d}"
    local -a results=()
    local passed=0 failed=0 skipped=0
    local row verify_status interrupted=false
    _upgrade_all_report() {
        $structured || return 0
        printf '%s\n' ${results[@]+"${results[@]}"} |
            jq -sc --argjson dry "$dry_run" --arg error "${1:-}" '
                {mode:"all", dry_run:$dry, tools:., summary:{
                    passed:map(select(.status == "passed"))|length,
                    planned:map(select(.status == "planned"))|length,
                    failed:map(select(.status == "failed" or .status == "error"))|length,
                    interrupted:map(select(.status == "interrupted"))|length,
                    skipped:map(select(.status == "skipped"))|length
                }} + (if $error == "" then {} else {error:$error} end)'
    }

    if [[ ! -d "$repos_dir" ]]; then
        log_error "repos.d directory not found: $repos_dir"
        _upgrade_all_report "repos.d directory not found: $repos_dir"
        return 4
    fi

    log_info "Verifying upgrade commands for all tools..."

    local config_file tool_name
    for config_file in "$repos_dir"/*.yaml; do
        [[ -f "$config_file" ]] || continue
        [[ "$(basename "$config_file")" == _* ]] && continue

        tool_name=$(basename "$config_file" .yaml)

        # Explicit selection does not depend on an installed executable. The
        # single-tool verifier builds a missing binary or honors a requested
        # source build, then validates the configured command and its result.
        local has_upgrade=false
        local binary_name bin_path=""
        if $build_from_source || _upgrade_has_explicit_check_args "$tool_name"; then
            has_upgrade=true
        else
            binary_name=$(_upgrade_tool_binary_name "$tool_name")
            bin_path=$(command -v "$binary_name" 2>/dev/null || true)
            if [[ -z "$bin_path" && "$binary_name" != "$tool_name" ]]; then
                bin_path=$(command -v "$tool_name" 2>/dev/null || true)
            fi
            # Capture --help before searching it: `--help | grep -q` lets a
            # long help text SIGPIPE the tool and pipefail hides the match.
            if [[ -n "$bin_path" ]] && grep -q "upgrade" <<< "$("$bin_path" --help 2>&1)"; then
                has_upgrade=true
            fi
        fi

        if ! $has_upgrade; then
            log_debug "Skipping $tool_name: no update-check command"
            ((skipped++))
            if $structured; then
                row=$(jq -nc --arg tool "$tool_name" '{tool:$tool, status:"skipped", reason:"no update-check command"}') || return 1
                results+=("$row")
            fi
            continue
        fi

        verify_status=0
        if $structured; then
            row=$(upgrade_verify_tool "$tool_name" --json ${args[@]+"${args[@]}"}) || verify_status=$?
            if ! row=$(jq -ces --arg tool "$tool_name" --argjson code "$verify_status" '
                select(length == 1) | .[0] | select(type == "object" and .tool == $tool) |
                .verification_exit_code = $code |
                if $code == 5 then .status = "interrupted" else . end' <<< "$row"); then
                # A missing receipt must never count as a passed check. Keep
                # cancellation terminal even if formatting its evidence failed.
                ((verify_status != 0)) || verify_status=1
                row=$(jq -nc --arg tool "$tool_name" --argjson code "$verify_status" '
                    {tool:$tool, status:(if $code == 5 then "interrupted" else "error" end),
                     verification_exit_code:$code, error:"Could not read the verification result"}') || return "$verify_status"
            fi
            results+=("$row")
        else
            upgrade_verify_tool "$tool_name" ${args[@]+"${args[@]}"} || verify_status=$?
        fi
        if [[ "$verify_status" == 0 ]]; then
            ((passed++))
        else
            if [[ "$verify_status" == 5 ]]; then
                log_error "Upgrade verification interrupted; later tools were not started"
                interrupted=true
                break
            fi
            ((failed++))
        fi
    done

    if $interrupted; then
        _upgrade_all_report
        return 5
    fi

    # Summary
    if $dry_run; then
        log_info "Upgrade verification complete: $passed planned, $failed failed, $skipped skipped"
    else
        log_info "Upgrade verification complete: $passed passed, $failed failed, $skipped skipped"
    fi

    if ((passed == 0 && failed == 0)); then
        log_error "No upgrade checks were selected"
        _upgrade_all_report "No upgrade checks were selected"
        return 1
    fi
    _upgrade_all_report || return 1
    [[ $failed -eq 0 ]]
)

# Get upgrade verification results as JSON
upgrade_verify_json() {
    local tool_name="${1:-}"
    shift || true
    if [[ -n "$tool_name" ]]; then
        upgrade_verify_tool "$tool_name" --json "$@"
    else
        # All tools
        echo '{"tools": ['
        local first=true platform config_file
        platform="$(uname -s | tr '[:upper:]' '[:lower:]')/$(uname -m)"
        local repos_dir="${ACT_REPOS_DIR:-${DSR_CONFIG_DIR:-$HOME/.config/dsr}/repos.d}"

        for config_file in "$repos_dir"/*.yaml; do
            [[ -f "$config_file" ]] || continue
            [[ "$(basename "$config_file")" == _* ]] && continue

            tool_name=$(basename "$config_file" .yaml)
            $first || echo ","
            first=false

            upgrade_verify_tool "$tool_name" --json --installed-only 2>/dev/null || true
        done

        echo '], "platform": "'"$platform"'"}'
    fi
}

# ============================================================================
# Internal Helpers
# ============================================================================

# Both output modes use the updater's process result as a prerequisite. Keep
# the established zero-exit generic/no-update behavior, but an explicit asset
# lookup failure must win over any earlier positive informational output.
_upgrade_check_succeeded() {
    local exit_code="$1" output="$2" match_status=0
    [[ "$exit_code" == 0 ]] || return 1
    grep -qi "no suitable release asset\|asset not found\|failed to find" <<< "$output" || match_status=$?
    [[ "$match_status" == 1 ]]
}

# Extract the version identified as latest (or update-available) from tool
# output. Prefer a line containing "latest" so a preceding current-version
# line cannot satisfy an exact release check.
_upgrade_extract_latest_version() {
    local output="$1"
    local version=""

    version=$(printf '%s\n' "$output" | grep -i 'latest' |
        grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?' |
        tail -1 || true)
    if [[ -z "$version" ]]; then
        version=$(printf '%s\n' "$output" | grep -iE 'update.*available|available.*update' |
            grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?' |
            tail -1 || true)
    fi

    printf '%s\n' "${version#v}"
}

# Print the update-check argv, one argument per line. Arguments are read as a
# YAML string array and passed directly to the binary; they are never evaluated
# as shell source. Repositories without an override retain the established
# `upgrade --check` default.
_upgrade_check_args() {
    local tool_name="$1"
    local repos_dir="${ACT_REPOS_DIR:-${DSR_CONFIG_DIR:-$HOME/.config/dsr}/repos.d}"
    local config_file="$repos_dir/$tool_name.yaml"

    if [[ ! -f "$config_file" ]]; then
        printf '%s\n' upgrade --check
        return 0
    fi

    if ! command -v yq &>/dev/null || ! command -v jq &>/dev/null; then
        log_error "yq and jq are required to read upgrade_check_args"
        return 3
    fi

    local args_json
    if ! args_json=$(yq -o=json -I=0 \
            '.upgrade_check_args // ["upgrade", "--check"]' \
            "$config_file" 2>/dev/null); then
        return 4
    fi

    jq -er '
        if type == "array" and length > 0 and
           all(.[]; type == "string" and length > 0 and
                    (contains("\n") | not) and (contains("\r") | not))
        then .[]
        else error("upgrade_check_args must be a non-empty array of non-empty single-line strings")
        end
    ' <<< "$args_json"
}

# Return success when the repository explicitly declares its update-check
# command. This lets `upgrade verify --all` discover nonstandard verbs such as
# `update --check` without guessing from help text.
_upgrade_has_explicit_check_args() {
    local tool_name="$1"
    local repos_dir="${ACT_REPOS_DIR:-${DSR_CONFIG_DIR:-$HOME/.config/dsr}/repos.d}"
    local config_file="$repos_dir/$tool_name.yaml"

    [[ -f "$config_file" ]] || return 1
    command -v yq &>/dev/null || return 1
    yq -e 'has("upgrade_check_args")' "$config_file" >/dev/null 2>&1
}

# Resolve the executable/Cargo binary name for a DSR config key. Config files
# are often keyed by repo name while the distributed executable is shorter
# (for example, beads_rust -> br).
_upgrade_tool_binary_name() {
    local tool_name="$1"
    local binary_name=""

    if ! declare -F config_get_tool_field &>/dev/null; then
        local script_dir
        script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        # shellcheck source=SCRIPTDIR/config.sh
        source "$script_dir/config.sh" 2>/dev/null || true
    fi

    if declare -F config_get_tool_field &>/dev/null; then
        binary_name=$(config_get_tool_field "$tool_name" "binary_name" "" 2>/dev/null || echo "")
        if [[ -z "$binary_name" ]]; then
            binary_name=$(config_get_tool_field "$tool_name" "tool_name" "" 2>/dev/null || echo "")
        fi
    fi

    echo "${binary_name:-$tool_name}"
}

# Find repository directory for a tool
_upgrade_find_repo_dir() {
    local tool_name="$1"
    local repos_dir="${ACT_REPOS_DIR:-${DSR_CONFIG_DIR:-$HOME/.config/dsr}/repos.d}"
    local config_file="$repos_dir/$tool_name.yaml"

    if [[ ! -f "$config_file" ]]; then
        # Try standard location
        local default_path="/data/projects/$tool_name"
        if [[ -d "$default_path" ]]; then
            echo "$default_path"
            return 0
        fi
        return 1
    fi

    # Get local_path from config
    local local_path
    if command -v yq &>/dev/null; then
        local_path=$(yq -r '.local_path // ""' "$config_file" 2>/dev/null)
    else
        local_path=$(grep '^local_path:' "$config_file" 2>/dev/null | \
                    sed 's/local_path:\s*//' | tr -d '"' | tr -d "'")
    fi

    if [[ -n "$local_path" && -d "$local_path" ]]; then
        echo "$local_path"
        return 0
    fi

    return 1
}

# Build the primary Bun executable with the same entry, lockfile and workspace
# admission used by generated source installers. This checks a local checkout;
# it does not install a compiler, replace an installed tool or attest a release.
_upgrade_build_bun_tool() (
    local tool_name="$1" repo_dir="$2" binary_name="$3" tmpdir="$4"
    local config_file="${ACT_REPOS_DIR:-${DSR_CONFIG_DIR:-$HOME/.config/dsr}/repos.d}/$tool_name.yaml"
    local source_dir configuration subdir entry language tree output built status=0
    local _ISB_CHECKOUT_ROOT _ISB_INSTALL_TOOLCHAIN=false
    local limit="${DSR_BUILD_TIMEOUT:-3600}"
    command -v jq >/dev/null && command -v yq >/dev/null &&
        command -v git >/dev/null && command -v ps >/dev/null || return 3
    [[ "$limit" =~ ^[1-9][0-9]{0,4}$ ]] || return 4
    source_dir="${_DSR_UPGRADE_VERIFY_DIR:-}"
    [[ "$source_dir" == /* && -d "$source_dir" && ! -L "$source_dir" ]] || return 3
    # shellcheck source=SCRIPTDIR/install_source.sh
    source "$source_dir/install_source.sh" || return 3
    _isb_name "$binary_name" && [[ "$binary_name" != *..* ]] || return 4
    [[ -f "$config_file" && ! -L "$config_file" ]] || return 4
    if ! declare -F _config_read_single_mapping_json >/dev/null; then
        # shellcheck source=SCRIPTDIR/config.sh
        source "$source_dir/config.sh" || return 3
    fi
    configuration=$(_config_read_single_mapping_json "$config_file") || return $?
    configuration=$(jq -ce '
        {language:.language,
         subdir:(if has("source_subdir") then .source_subdir else "." end),
         entry:(if has("source_entry") then .source_entry else "" end),
         package:(if has("source_package") then .source_package else "" end)} |
        select((.language == "bun" or .language == "typescript") and
               (.subdir|type == "string" and length > 0) and
               (.entry|type == "string") and .package == "")
    ' <<< "$configuration") || return 4
    language=$(jq -r .language <<< "$configuration") || return 4
    subdir=$(jq -r .subdir <<< "$configuration") || return 4
    entry=$(jq -r .entry <<< "$configuration") || return 4
    _ISB_CHECKOUT_ROOT=$(cd "$repo_dir" && pwd -P) || return 4
    _isb_path_in_tree "$_ISB_CHECKOUT_ROOT" "$subdir" || return 4
    [[ -z "$entry" ]] || _isb_relative_path "$entry" || return 4
    tree="$_ISB_CHECKOUT_ROOT"
    [[ "$subdir" == . ]] || tree+="/$subdir"
    [[ -d "$tree" ]] || return 4
    output="$tmpdir/.build"
    mkdir "$output" || return 1
    built=$(_isb_compile "$language" "$tree" "$output" "$binary_name" "$entry" '' "$limit") || status=$?
    if ((status != 0)); then
        log_error "Bun source verification build failed; diagnostics: $output"
        local log
        for log in "$output/compiler.log" "$output/bun-project.log" "$output/dependencies.log" "$output/build.log"; do
            [[ ! -f "$log" || -L "$log" ]] || tail -n 20 "$log" >&2
        done
        return "$status"
    fi
    [[ "$built" == "$output/bin/$(_isb_binary_name "$binary_name")" && -f "$built" &&
       -s "$built" && -x "$built" && ! -L "$built" ]] || return 6
    # The public verifier owns this whole attempt directory. Keep its primary
    # at the existing cleanup boundary, while compiler logs stay in build/.
    cp -p -- "$built" "$tmpdir/$binary_name" || return 1
)

# Read Cargo feature options without evaluating configuration as shell source.
# The installer engine owns feature-name grammar, bounds and uniqueness; this
# local verification caller shares that admission and the strict YAML parser.
# Print one argument per line, with no output when the recipe has no opt-in.
_upgrade_source_cargo_arguments() (
    local tool_name="$1" language="$2" config_file source_dir configuration selection feature
    config_file="${ACT_REPOS_DIR:-${DSR_CONFIG_DIR:-$HOME/.config/dsr}/repos.d}/$tool_name.yaml"
    [[ ! -L "$config_file" ]] || return 4
    [[ -f "$config_file" ]] || return 0
    command -v jq >/dev/null && command -v yq >/dev/null || return 3
    source_dir="${_DSR_UPGRADE_VERIFY_DIR:-}"
    [[ "$source_dir" == /* && -d "$source_dir" && ! -L "$source_dir" ]] || return 3
    if ! declare -F _config_read_single_mapping_json >/dev/null; then
        # shellcheck source=SCRIPTDIR/config.sh
        source "$source_dir/config.sh" || return 3
    fi
    configuration=$(_config_read_single_mapping_json "$config_file") || return $?
    jq -e 'has("source_features") or has("source_no_default_features")' \
        <<< "$configuration" >/dev/null || return 0
    if [[ "$language" != rust ]] || ! jq -e \
            '(has("language") | not) or .language == "rust"' <<< "$configuration" >/dev/null; then
        log_error 'Cargo feature selection is only supported for Rust'
        return 4
    fi
    selection=$(jq -ce '
        {features:(if has("source_features") then .source_features else [] end),
         no_default_features:(if has("source_no_default_features") then .source_no_default_features else false end)} |
        select((.features | type == "array" and all(.[];
            type == "string" and (test("[[:cntrl:]]") | not))) and
            (.no_default_features | type == "boolean"))
    ' <<< "$configuration") || return 4
    if ! declare -F _isb_cargo_features_valid >/dev/null; then
        # shellcheck source=SCRIPTDIR/install_source.sh
        source "$source_dir/install_source.sh" || return 3
    fi
    local -a features=()
    mapfile -t features < <(jq -r '.features[]' <<< "$selection")
    _isb_cargo_features_valid ${features[@]+"${features[@]}"} || return 4
    for feature in ${features[@]+"${features[@]}"}; do
        printf '%s\n' --features "$feature"
    done
    if jq -e '.no_default_features' <<< "$selection" >/dev/null; then
        printf '%s\n' --no-default-features
    fi
    return 0
)

# Build the configured primary updater from a local checkout. Share installer
# recipe/path admission and command supervision, but retain local verification
# semantics: Go/Rust inputs need not be committed or have a pre-existing lock.
# This is not a pinned-source build receipt or a release artifact attestation.
_upgrade_build_tool() (
    local tool_name="$1"
    local repo_dir="$2"
    local binary_name="${3:-$tool_name}"
    local source_dir configuration='{}' selection config_file root tree subdir entry package language
    local cargo_arguments limit="${DSR_BUILD_TIMEOUT:-3600}" status=0 log_file selected package_name
    local -a cargo_options=()
    command -v jq >/dev/null && command -v ps >/dev/null || return 3
    [[ "$limit" =~ ^[1-9][0-9]{0,4}$ ]] || return 4
    source_dir="${_DSR_UPGRADE_VERIFY_DIR:-}"
    [[ "$source_dir" == /* && -d "$source_dir" && ! -L "$source_dir" ]] || return 3
    # shellcheck source=SCRIPTDIR/install_source.sh
    source "$source_dir/install_source.sh" || return 3
    _isb_name "$tool_name" && _isb_name "$binary_name" || return 4
    config_file="${ACT_REPOS_DIR:-${DSR_CONFIG_DIR:-$HOME/.config/dsr}/repos.d}/$tool_name.yaml"
    [[ ! -L "$config_file" ]] || return 4
    if [[ -e "$config_file" ]]; then
        [[ -f "$config_file" ]] || return 4
        command -v yq >/dev/null || return 3
        if ! declare -F _config_read_single_mapping_json >/dev/null; then
            # shellcheck source=SCRIPTDIR/config.sh
            source "$source_dir/config.sh" || return 3
        fi
        configuration=$(_config_read_single_mapping_json "$config_file") || return $?
    fi
    selection=$(jq -ce '
        {language:(if has("language") then .language else "" end),
         subdir:(if has("source_subdir") then .source_subdir else "." end),
         entry:(if has("source_entry") then .source_entry else "" end),
         package:(if has("source_package") then .source_package else "" end)} |
        select((.language | type == "string") and
               (.subdir | type == "string" and length > 0) and
               (.entry | type == "string") and (.package | type == "string"))
    ' <<< "$configuration") || return 4
    language=$(jq -r .language <<< "$selection") || return 4
    subdir=$(jq -r .subdir <<< "$selection") || return 4
    entry=$(jq -r .entry <<< "$selection") || return 4
    package=$(jq -r .package <<< "$selection") || return 4
    root=$(cd "$repo_dir" && pwd -P) || return 4
    _isb_path_in_tree "$root" "$subdir" || return 4
    tree="$root"
    [[ "$subdir" == . ]] || tree+="/$subdir"
    [[ -d "$tree" ]] || return 4
    [[ -z "$entry" ]] || _isb_relative_path "$entry" || return 4
    [[ -z "$package" ]] || _isb_name "$package" || return 4
    # Go searches parents for a workspace even when the current directory
    # has its own module. Limit both searches to this configured local_path.
    local cursor="$tree" go_work="" go_mod=""
    if [[ -z "$language" || "$language" == go ]]; then
        while :; do
            if [[ -z "$go_work" && ( -e "$cursor/go.work" || -L "$cursor/go.work" ) ]]; then
                go_work="$cursor/go.work"
            fi
            if [[ -z "$go_mod" && ( -e "$cursor/go.mod" || -L "$cursor/go.mod" ) ]]; then
                go_mod="$cursor/go.mod"
            fi
            [[ "$cursor" != "$root" && "$cursor" != / ]] || break
            cursor="${cursor%/*}"
            [[ -n "$cursor" ]] || cursor=/
        done
    fi
    if [[ -z "$language" ]]; then
        if [[ -f "$tree/go.mod" ]]; then language=go
        elif [[ -f "$tree/Cargo.toml" ]]; then language=rust
        elif [[ -n "$go_work" || -n "$go_mod" ]]; then language=go
        fi
    fi
    case "$language" in go|rust|bun|typescript) ;; *) return 4 ;; esac
    [[ "$language" != rust || -z "$entry" ]] || return 4
    [[ "$language" == rust || -z "$package" ]] || return 4
    cargo_arguments=$(_upgrade_source_cargo_arguments "$tool_name" "$language") || return $?
    [[ -z "$cargo_arguments" ]] || mapfile -t cargo_options <<< "$cargo_arguments"
    local tmpdir
    umask 077
    tmpdir=$(mktemp -d) || return 1
    tmpdir=$(cd "$tmpdir" && pwd -P) || return 1
    local bin_path="$tmpdir/$binary_name"
    # Compiler stdout is protocol data. Keep warnings/download diagnostics on
    # stderr in the watchdog log instead of mixing them into names or JSON.
    _upgrade_capture_stdout() {
        local destination="$1"
        shift
        "$@" > "$destination"
    }

    if [[ "$language" == bun || "$language" == typescript ]]; then
        log_debug "Building Bun/TypeScript project..."
        _upgrade_build_bun_tool "$tool_name" "$repo_dir" "$binary_name" "$tmpdir" || return $?
    elif [[ "$language" == go ]]; then
        command -v go >/dev/null || return 3
        if [[ -z "$go_work" && -z "$go_mod" ]]; then
            log_error "No Go workspace or module within the configured checkout: $tree"
            return 4
        fi
        local metadata
        for metadata in "$go_work" "$go_mod"; do
            [[ -z "$metadata" || ( -f "$metadata" && ! -L "$metadata" ) ]] || {
                log_error "Go source metadata must be a regular file: $metadata"
                return 4
            }
        done
        # Run the local updater for this host. Caller build flags (including
        # -overlay and -modfile), cross targets and external workfiles can
        # otherwise change the program being verified.
        export GOENV=off GOWORK="${go_work:-off}" GOFLAGS='' GO111MODULE=on
        export GOTOOLCHAIN=local GOOS='' GOARCH=''
        selected=$(_isb_source_entries go "$tree" "$binary_name" "$entry" "$binary_name") || return $?
        mkdir "$tmpdir/.build" || return 1
        log_debug "Building Go project..."
        _isb_run "$limit" "$tmpdir/.build/package.log" _upgrade_capture_stdout \
            "$tmpdir/.build/package-name" _isb_in_dir "$tree" \
            go list -f '{{.Name}}' "./$selected" || status=$?
        if ((status == 0)); then
            package_name=$(cat "$tmpdir/.build/package-name") || status=$?
            if ((status == 0)) && [[ "$package_name" != main ]]; then
                log_error "Configured Go source entry is not one executable: $selected"
                status=6
            fi
        fi
        if ((status == 0)); then
            _isb_run "$limit" "$tmpdir/.build/compile.log" _isb_in_dir "$tree" \
                go build -o "$bin_path" "./$selected" || status=$?
        fi
    else
        command -v cargo >/dev/null || return 3
        [[ -f "$tree/Cargo.toml" && ! -L "$tree/Cargo.toml" ]] || return 4
        mkdir "$tmpdir/.build" || return 1
        local -a build_args=(build --release --message-format=json-render-diagnostics
            --manifest-path "$tree/Cargo.toml" --target-dir "$tmpdir/.build/target" --bin "$binary_name")
        [[ -z "$package" ]] || build_args+=(--package "$package")
        build_args+=(${cargo_options[@]+"${cargo_options[@]}"})
        log_debug "Building Rust project..."
        log_file="$tmpdir/.build/compile.log"
        _isb_run "$limit" "$log_file" _upgrade_capture_stdout "$tmpdir/.build/artifacts.jsonl" \
            _isb_in_dir "$tree" cargo "${build_args[@]}" || status=$?
        if ((status == 0)); then
            # Cargo's actual artifact record owns the output path, including
            # .cargo/config.toml build.target and Windows executable suffixes.
            # Never execute a guessed or stale shared target/release binary.
            selected=$(jq -erRs --arg name "$binary_name" '
                [split("\n")[] | fromjson?] as $messages |
                [$messages[] | select(.reason == "compiler-artifact" and
                    .target.name == $name and (.target.kind | index("bin") != null))] as $binaries |
                select(($binaries | length) == 1 and
                    ([$messages[] | select(.reason == "build-finished")] | length == 1) and
                    any($messages[]; .reason == "build-finished" and .success == true)) |
                $binaries[0].executable | select(type == "string" and length > 0 and
                    (test("[[:cntrl:]]") | not))
            ' "$tmpdir/.build/artifacts.jsonl") || {
                status=$?
                # jq uses 5 for an empty/invalid artifact selection, not the
                # watchdog interruption code. Preserve actual signal statuses.
                if ((status != 124 && status < 129)); then status=6; fi
            }
            if ((status == 0)); then
                [[ "$selected" == "$tmpdir/.build/target/"* && -f "$selected" &&
                   -s "$selected" && -x "$selected" && ! -L "$selected" ]] &&
                    _isb_path_in_tree "$tmpdir/.build/target" "${selected#"$tmpdir/.build/target/"}" || status=6
            fi
            if ((status == 0)); then
                cp -p -- "$selected" "$bin_path" || status=$?
            fi
        fi
    fi

    if ((status == 0)) && [[ -f "$bin_path" && -s "$bin_path" && -x "$bin_path" && ! -L "$bin_path" ]]; then
        printf '%s\n' "$bin_path"
        return 0
    fi

    log_error "Source verification build failed; diagnostics: $tmpdir"
    if ((status == 5 || status == 124 || (status >= 129 && status <= 255))); then return 5; fi
    return 6
)

# Export functions
export -f upgrade_verify_tool upgrade_verify_all upgrade_verify_json
export -f _upgrade_check_succeeded _upgrade_extract_latest_version _upgrade_check_args _upgrade_has_explicit_check_args
export -f _upgrade_tool_binary_name _upgrade_find_repo_dir _upgrade_build_tool _upgrade_source_cargo_arguments
export -f _upgrade_build_bun_tool
