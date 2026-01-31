#!/usr/bin/env bash
# scripts/coverage.sh - Function-level coverage reporting for Bash scripts
#
# bd-ov2: Test infrastructure: coverage reporting and metrics
#
# Usage:
#   ./scripts/coverage.sh                    # Full coverage report
#   ./scripts/coverage.sh --module config.sh # Single module
#   ./scripts/coverage.sh --json             # JSON output for CI
#   ./scripts/coverage.sh --threshold 80     # Fail if below threshold
#
# This script provides function-level coverage tracking since Bash doesn't
# have built-in coverage tools like gcov. It works by:
# 1. Parsing exported functions from src/*.sh modules
# 2. Scanning test files to find which functions are called
# 3. Generating a coverage report

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

# Options
JSON_MODE=false
VERBOSE=false
TARGET_MODULE=""
THRESHOLD=0

# ============================================================================
# Function Discovery
# ============================================================================

# Extract exported functions from a module
# Args: module_path
# Output: function names, one per line
get_exported_functions() {
    local module="$1"

    if [[ ! -f "$module" ]]; then
        return 1
    fi

    # Find export -f lines and extract function names
    grep -E '^export -f' "$module" 2>/dev/null | \
        sed 's/export -f//' | \
        tr ' ' '\n' | \
        grep -v '^$' | \
        sort -u
}

# Extract all function definitions from a module (even non-exported)
# Args: module_path
# Output: function names, one per line
get_all_functions() {
    local module="$1"

    if [[ ! -f "$module" ]]; then
        return 1
    fi

    # Match: func_name() { or function func_name {
    grep -E '^[a-zA-Z_][a-zA-Z0-9_]*\s*\(\)' "$module" 2>/dev/null | \
        sed 's/().*//' | \
        tr -d ' ' | \
        sort -u
}

# Count functions in a module
count_functions() {
    local module="$1"
    local export_only="${2:-true}"

    if [[ "$export_only" == "true" ]]; then
        get_exported_functions "$module" | wc -l | tr -d ' '
    else
        get_all_functions "$module" | wc -l | tr -d ' '
    fi
}

# ============================================================================
# Test Coverage Detection
# ============================================================================

# Find all test files
get_test_files() {
    find "$PROJECT_ROOT" -type f \( -name "test_*.sh" -o -name "*.bats" \) \
        -not -path "*/node_modules/*" \
        -not -path "*/.git/*" 2>/dev/null | sort
}

# Check if a function is called in any test file
# Args: function_name
# Returns: 0 if found, 1 if not
is_function_tested() {
    local func_name="$1"
    local test_files

    test_files=$(get_test_files)

    if [[ -z "$test_files" ]]; then
        return 1
    fi

    # Search for function call in test files
    # Patterns: func_name, func_name $arg, func_name "arg", $(func_name)
    echo "$test_files" | xargs grep -l -E "\b${func_name}\b" 2>/dev/null | head -1 | grep -q .
}

# Get list of test files that call a function
get_tests_calling_function() {
    local func_name="$1"
    local test_files

    test_files=$(get_test_files)

    if [[ -z "$test_files" ]]; then
        return
    fi

    echo "$test_files" | xargs grep -l -E "\b${func_name}\b" 2>/dev/null | \
        while read -r file; do
            basename "$file"
        done | sort -u
}

# ============================================================================
# Coverage Calculation
# ============================================================================

# Calculate coverage for a single module
# Args: module_path
# Output: JSON object with coverage stats
calc_module_coverage() {
    local module="$1"
    local module_name
    module_name=$(basename "$module")

    local total=0
    local tested=0
    local untested=()
    local tested_funcs=()

    while IFS= read -r func; do
        [[ -z "$func" ]] && continue
        ((total++))

        if is_function_tested "$func"; then
            ((tested++))
            tested_funcs+=("$func")
        else
            untested+=("$func")
        fi
    done < <(get_exported_functions "$module")

    local coverage=0
    if [[ $total -gt 0 ]]; then
        coverage=$((tested * 100 / total))
    fi

    # Build JSON
    local untested_json
    untested_json=$(printf '%s\n' "${untested[@]}" 2>/dev/null | jq -R . | jq -sc '.')
    [[ -z "$untested_json" || "$untested_json" == "null" ]] && untested_json="[]"

    local tested_json
    tested_json=$(printf '%s\n' "${tested_funcs[@]}" 2>/dev/null | jq -R . | jq -sc '.')
    [[ -z "$tested_json" || "$tested_json" == "null" ]] && tested_json="[]"

    jq -nc \
        --arg module "$module_name" \
        --argjson total "$total" \
        --argjson tested "$tested" \
        --argjson coverage "$coverage" \
        --argjson untested "$untested_json" \
        --argjson tested_funcs "$tested_json" \
        '{
            module: $module,
            total_functions: $total,
            tested_functions: $tested,
            coverage_percent: $coverage,
            untested: $untested,
            tested: $tested_funcs
        }'
}

# ============================================================================
# Reporting
# ============================================================================

# Print text report for a single module
print_module_report() {
    local module="$1"
    local module_name
    module_name=$(basename "$module")

    local coverage_json
    coverage_json=$(calc_module_coverage "$module")

    local total tested coverage
    total=$(echo "$coverage_json" | jq -r '.total_functions')
    tested=$(echo "$coverage_json" | jq -r '.tested_functions')
    coverage=$(echo "$coverage_json" | jq -r '.coverage_percent')

    # Color based on coverage
    local color="$RED"
    [[ $coverage -ge 50 ]] && color="$YELLOW"
    [[ $coverage -ge 80 ]] && color="$GREEN"

    printf "%-25s %8s %8s %s%6s%%%s\n" "$module_name" "$total" "$tested" "$color" "$coverage" "$NC"
}

# Print full text report
print_full_report() {
    echo ""
    echo "=== DSR Test Coverage Report ==="
    echo ""
    printf "%-25s %8s %8s %8s\n" "Module" "Total" "Tested" "Coverage"
    printf "%-25s %8s %8s %8s\n" "------" "-----" "------" "--------"

    local grand_total=0
    local grand_tested=0
    local modules_below_threshold=()

    for module in "$PROJECT_ROOT"/src/*.sh; do
        [[ -f "$module" ]] || continue

        print_module_report "$module"

        local coverage_json
        coverage_json=$(calc_module_coverage "$module")
        grand_total=$((grand_total + $(echo "$coverage_json" | jq -r '.total_functions')))
        grand_tested=$((grand_tested + $(echo "$coverage_json" | jq -r '.tested_functions')))

        local coverage
        coverage=$(echo "$coverage_json" | jq -r '.coverage_percent')
        if [[ $THRESHOLD -gt 0 && $coverage -lt $THRESHOLD ]]; then
            modules_below_threshold+=("$(basename "$module"):$coverage%")
        fi
    done

    # Grand total
    local grand_coverage=0
    [[ $grand_total -gt 0 ]] && grand_coverage=$((grand_tested * 100 / grand_total))

    printf "%-25s %8s %8s %8s\n" "------" "-----" "------" "--------"

    local total_color="$RED"
    [[ $grand_coverage -ge 50 ]] && total_color="$YELLOW"
    [[ $grand_coverage -ge 80 ]] && total_color="$GREEN"

    printf "${BLUE}%-25s %8s %8s %s%6s%%%s${NC}\n" "TOTAL" "$grand_total" "$grand_tested" "$total_color" "$grand_coverage" "$NC"

    # Show untested functions if verbose
    if $VERBOSE; then
        echo ""
        echo "=== Untested Functions ==="
        for module in "$PROJECT_ROOT"/src/*.sh; do
            [[ -f "$module" ]] || continue

            local coverage_json
            coverage_json=$(calc_module_coverage "$module")
            local untested
            untested=$(echo "$coverage_json" | jq -r '.untested[]' 2>/dev/null)

            if [[ -n "$untested" ]]; then
                echo ""
                echo "$(basename "$module"):"
                echo "$untested" | sed 's/^/  - /'
            fi
        done
    fi

    echo ""

    # Check threshold
    if [[ $THRESHOLD -gt 0 ]]; then
        if [[ $grand_coverage -lt $THRESHOLD ]]; then
            echo "${RED}ERROR: Coverage ($grand_coverage%) below threshold ($THRESHOLD%)${NC}"
            if [[ ${#modules_below_threshold[@]} -gt 0 ]]; then
                echo "Modules below threshold:"
                printf '  - %s\n' "${modules_below_threshold[@]}"
            fi
            return 1
        else
            echo "${GREEN}Coverage ($grand_coverage%) meets threshold ($THRESHOLD%)${NC}"
        fi
    fi
}

# Generate full JSON report
generate_json_report() {
    local modules=()
    local grand_total=0
    local grand_tested=0

    for module in "$PROJECT_ROOT"/src/*.sh; do
        [[ -f "$module" ]] || continue

        local coverage_json
        coverage_json=$(calc_module_coverage "$module")
        modules+=("$coverage_json")

        grand_total=$((grand_total + $(echo "$coverage_json" | jq -r '.total_functions')))
        grand_tested=$((grand_tested + $(echo "$coverage_json" | jq -r '.tested_functions')))
    done

    local grand_coverage=0
    [[ $grand_total -gt 0 ]] && grand_coverage=$((grand_tested * 100 / grand_total))

    local threshold_met=true
    [[ $THRESHOLD -gt 0 && $grand_coverage -lt $THRESHOLD ]] && threshold_met=false

    local modules_json
    modules_json=$(printf '%s\n' "${modules[@]}" | jq -sc '.')

    jq -nc \
        --arg timestamp "$(date -Iseconds)" \
        --argjson modules "$modules_json" \
        --argjson total "$grand_total" \
        --argjson tested "$grand_tested" \
        --argjson coverage "$grand_coverage" \
        --argjson threshold "$THRESHOLD" \
        --argjson threshold_met "$threshold_met" \
        '{
            timestamp: $timestamp,
            modules: $modules,
            summary: {
                total_functions: $total,
                tested_functions: $tested,
                coverage_percent: $coverage,
                threshold: $threshold,
                threshold_met: $threshold_met
            }
        }'
}

# ============================================================================
# Main
# ============================================================================

show_help() {
    cat << 'EOF'
scripts/coverage.sh - Function-level coverage reporting for dsr

USAGE:
    ./scripts/coverage.sh [options]

OPTIONS:
    --module <name>    Report for a single module (e.g., config.sh)
    --json             Output JSON instead of text
    --verbose, -v      Show untested functions
    --threshold <pct>  Fail if coverage below threshold (0-100)
    --help, -h         Show this help

DESCRIPTION:
    Provides function-level coverage tracking for Bash scripts by:
    1. Parsing exported functions from src/*.sh modules
    2. Scanning test files to find which functions are called
    3. Generating a coverage report

    This is an approximation - a function is considered "tested" if its
    name appears in any test file.

EXAMPLES:
    ./scripts/coverage.sh                    # Full report
    ./scripts/coverage.sh --json             # JSON for CI
    ./scripts/coverage.sh --threshold 75     # Fail if <75%
    ./scripts/coverage.sh --module config.sh # Single module
    ./scripts/coverage.sh -v                 # Show untested functions

EXIT CODES:
    0  - Success (or coverage meets threshold)
    1  - Coverage below threshold
    2  - Error
EOF
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --module)
                TARGET_MODULE="$2"
                shift 2
                ;;
            --json)
                JSON_MODE=true
                shift
                ;;
            --verbose|-v)
                VERBOSE=true
                shift
                ;;
            --threshold)
                THRESHOLD="$2"
                shift 2
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                show_help >&2
                exit 2
                ;;
        esac
    done

    # Validate threshold
    if [[ $THRESHOLD -lt 0 || $THRESHOLD -gt 100 ]]; then
        echo "Error: threshold must be 0-100" >&2
        exit 2
    fi

    # Single module mode
    if [[ -n "$TARGET_MODULE" ]]; then
        local module_path="$PROJECT_ROOT/src/$TARGET_MODULE"
        if [[ ! -f "$module_path" ]]; then
            echo "Error: module not found: $TARGET_MODULE" >&2
            exit 2
        fi

        if $JSON_MODE; then
            calc_module_coverage "$module_path"
        else
            echo ""
            echo "=== Coverage: $TARGET_MODULE ==="
            echo ""
            printf "%-25s %8s %8s %8s\n" "Module" "Total" "Tested" "Coverage"
            printf "%-25s %8s %8s %8s\n" "------" "-----" "------" "--------"
            print_module_report "$module_path"

            if $VERBOSE; then
                local coverage_json
                coverage_json=$(calc_module_coverage "$module_path")
                local untested
                untested=$(echo "$coverage_json" | jq -r '.untested[]' 2>/dev/null)

                if [[ -n "$untested" ]]; then
                    echo ""
                    echo "Untested functions:"
                    echo "$untested" | sed 's/^/  - /'
                fi
            fi
        fi
        exit 0
    fi

    # Full report
    if $JSON_MODE; then
        generate_json_report
        local result=$?

        # Check threshold for exit code
        if [[ $THRESHOLD -gt 0 ]]; then
            local coverage
            coverage=$(generate_json_report | jq -r '.summary.coverage_percent')
            [[ $coverage -lt $THRESHOLD ]] && exit 1
        fi
        exit $result
    else
        print_full_report
    fi
}

main "$@"
