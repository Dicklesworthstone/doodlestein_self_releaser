#!/usr/bin/env bash
# test_json_schemas.sh - Validate JSON fixtures against schemas
#
# Usage: ./test_json_schemas.sh
#
# Requires: ajv-cli (npm install -g ajv-cli) or falls back to jq validation

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCHEMAS_DIR="$PROJECT_ROOT/schemas"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"

# Colors (disable with NO_COLOR=1)
if [[ -z "${NO_COLOR:-}" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

log_pass() { echo -e "${GREEN}✓${NC} $1"; ((PASS_COUNT++)); }
log_fail() { echo -e "${RED}✗${NC} $1"; ((FAIL_COUNT++)); }
log_skip() { echo -e "${YELLOW}○${NC} $1"; ((SKIP_COUNT++)); }
log_info() { echo -e "${BLUE}→${NC} $1"; }

# Check if ajv-cli is available
use_ajv=false
if command -v ajv &>/dev/null; then
    use_ajv=true
    log_info "Using ajv-cli for schema validation"
else
    log_info "ajv-cli not found, using jq for basic validation"
    log_info "Install ajv-cli for full schema validation: npm install -g ajv-cli"
fi

validate_with_ajv() {
    local fixture="$1"
    local schema="$2"

    if ajv validate -s "$schema" -d "$fixture" --strict=false 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

validate_with_jq() {
    local fixture="$1"
    local schema_name="$2"

    # Basic structural validation with jq
    local errors=()

    # Check required envelope fields
    local required_fields=("command" "status" "exit_code" "run_id" "started_at" "duration_ms" "tool" "version")
    for field in "${required_fields[@]}"; do
        if ! jq -e ".$field" "$fixture" &>/dev/null; then
            errors+=("Missing required field: $field")
        fi
    done

    # Validate status enum
    local status
    status=$(jq -r '.status' "$fixture" 2>/dev/null)
    if [[ ! "$status" =~ ^(success|partial|error)$ ]]; then
        errors+=("Invalid status: $status (expected success|partial|error)")
    fi

    # Validate exit_code is integer
    if ! jq -e '.exit_code | type == "number"' "$fixture" &>/dev/null; then
        errors+=("exit_code must be a number")
    fi

    # Validate tool is "dsr"
    local tool
    tool=$(jq -r '.tool' "$fixture" 2>/dev/null)
    if [[ "$tool" != "dsr" ]]; then
        errors+=("tool must be 'dsr', got '$tool'")
    fi

    # Validate artifacts array structure if present
    if jq -e '.artifacts | length > 0' "$fixture" &>/dev/null; then
        if ! jq -e '.artifacts[0].name and .artifacts[0].target and .artifacts[0].sha256' "$fixture" &>/dev/null; then
            errors+=("Artifacts missing required fields (name, target, sha256)")
        fi
    fi

    if [[ ${#errors[@]} -gt 0 ]]; then
        for err in "${errors[@]}"; do
            echo "  - $err" >&2
        done
        return 1
    fi
    return 0
}

validate_fixture() {
    local fixture="$1"
    local fixture_name
    fixture_name=$(basename "$fixture")

    # Determine which detail schema to use based on command
    local command
    command=$(jq -r '.command' "$fixture" 2>/dev/null)
    local detail_schema="$SCHEMAS_DIR/${command}-details.json"

    echo ""
    log_info "Validating: $fixture_name (command: $command)"

    # Validate against envelope schema
    if $use_ajv; then
        if validate_with_ajv "$fixture" "$SCHEMAS_DIR/envelope.json"; then
            log_pass "Envelope schema validation"
        else
            log_fail "Envelope schema validation"
        fi

        # Validate details against command-specific schema
        if [[ -f "$detail_schema" ]]; then
            # Extract details and validate
            local details_tmp
            details_tmp=$(mktemp)
            jq '.details' "$fixture" > "$details_tmp"
            if validate_with_ajv "$details_tmp" "$detail_schema"; then
                log_pass "Details schema validation ($command)"
            else
                log_fail "Details schema validation ($command)"
            fi
            rm -f "$details_tmp"
        else
            log_skip "No detail schema for command: $command"
        fi
    else
        # Fall back to jq validation
        if validate_with_jq "$fixture" "envelope"; then
            log_pass "Basic structure validation"
        else
            log_fail "Basic structure validation"
        fi
    fi
}

# Test exit code consistency
test_exit_code_consistency() {
    echo ""
    log_info "Testing exit code consistency..."

    for fixture in "$FIXTURES_DIR"/*.json; do
        [[ -f "$fixture" ]] || continue
        local fixture_name
        fixture_name=$(basename "$fixture")

        local status exit_code
        status=$(jq -r '.status' "$fixture")
        exit_code=$(jq -r '.exit_code' "$fixture")

        # Verify exit code matches status
        case "$status" in
            "success")
                if [[ "$exit_code" -eq 0 ]]; then
                    log_pass "$fixture_name: status=success → exit_code=0"
                else
                    log_fail "$fixture_name: status=success but exit_code=$exit_code (expected 0)"
                fi
                ;;
            "partial"|"error")
                if [[ "$exit_code" -gt 0 ]]; then
                    log_pass "$fixture_name: status=$status → exit_code=$exit_code (non-zero)"
                else
                    log_fail "$fixture_name: status=$status but exit_code=0 (expected >0)"
                fi
                ;;
        esac
    done
}

# Test timestamp format
test_timestamp_format() {
    echo ""
    log_info "Testing ISO8601 timestamp format..."

    local iso8601_regex='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

    for fixture in "$FIXTURES_DIR"/*.json; do
        [[ -f "$fixture" ]] || continue
        local fixture_name
        fixture_name=$(basename "$fixture")

        local started_at
        started_at=$(jq -r '.started_at' "$fixture")

        if [[ "$started_at" =~ $iso8601_regex ]]; then
            log_pass "$fixture_name: started_at is valid ISO8601"
        else
            log_fail "$fixture_name: started_at '$started_at' is not valid ISO8601"
        fi
    done
}

# Test UUID format
test_uuid_format() {
    echo ""
    log_info "Testing UUID format for run_id..."

    local uuid_regex='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

    for fixture in "$FIXTURES_DIR"/*.json; do
        [[ -f "$fixture" ]] || continue
        local fixture_name
        fixture_name=$(basename "$fixture")

        local run_id
        run_id=$(jq -r '.run_id' "$fixture")

        if [[ "$run_id" =~ $uuid_regex ]]; then
            log_pass "$fixture_name: run_id is valid UUID"
        else
            log_fail "$fixture_name: run_id '$run_id' is not valid UUID"
        fi
    done
}

# Test SHA256 checksum format
test_sha256_format() {
    echo ""
    log_info "Testing SHA256 checksum format..."

    local sha256_regex='^[a-f0-9]{64}$'

    for fixture in "$FIXTURES_DIR"/*.json; do
        [[ -f "$fixture" ]] || continue
        local fixture_name
        fixture_name=$(basename "$fixture")

        # Check artifacts if present
        local artifact_count
        artifact_count=$(jq '.artifacts | length' "$fixture")

        if [[ "$artifact_count" -gt 0 ]]; then
            local all_valid=true
            while IFS= read -r sha; do
                if [[ ! "$sha" =~ $sha256_regex ]]; then
                    all_valid=false
                    log_fail "$fixture_name: Invalid SHA256 '$sha'"
                fi
            done < <(jq -r '.artifacts[].sha256' "$fixture")

            if $all_valid; then
                log_pass "$fixture_name: All artifact SHA256 checksums valid"
            fi
        else
            log_skip "$fixture_name: No artifacts to check"
        fi
    done
}

# Main
main() {
    echo "═══════════════════════════════════════════════════════════════"
    echo "  DSR JSON Schema Validation Tests"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "Schemas directory: $SCHEMAS_DIR"
    echo "Fixtures directory: $FIXTURES_DIR"

    # Verify directories exist
    if [[ ! -d "$SCHEMAS_DIR" ]]; then
        log_fail "Schemas directory not found: $SCHEMAS_DIR"
        exit 1
    fi

    if [[ ! -d "$FIXTURES_DIR" ]]; then
        log_fail "Fixtures directory not found: $FIXTURES_DIR"
        exit 1
    fi

    # Run schema validation on each fixture
    for fixture in "$FIXTURES_DIR"/*.json; do
        [[ -f "$fixture" ]] || continue
        validate_fixture "$fixture"
    done

    # Run additional tests
    test_exit_code_consistency
    test_timestamp_format
    test_uuid_format
    test_sha256_format

    # Summary
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Summary"
    echo "═══════════════════════════════════════════════════════════════"
    echo -e "  ${GREEN}Passed:${NC}  $PASS_COUNT"
    echo -e "  ${RED}Failed:${NC}  $FAIL_COUNT"
    echo -e "  ${YELLOW}Skipped:${NC} $SKIP_COUNT"
    echo ""

    if [[ $FAIL_COUNT -gt 0 ]]; then
        echo -e "${RED}Some tests failed!${NC}"
        exit 1
    else
        echo -e "${GREEN}All tests passed!${NC}"
        exit 0
    fi
}

main "$@"
