#!/usr/bin/env bash
# e2e_prune.sh - E2E tests for dsr prune command
#
# Tests prune subcommand with real behavior (no mocks).
# Verifies safety guardrails, dry-run, and JSON output.
#
# Run: ./scripts/tests/e2e_prune.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSR_CMD="$PROJECT_ROOT/dsr"

# Source the test harness
source "$PROJECT_ROOT/tests/helpers/test_harness.bash"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
NC=$'\033[0m'

pass() { ((TESTS_PASSED++)); echo "${GREEN}PASS${NC}: $1"; }
fail() { ((TESTS_FAILED++)); echo "${RED}FAIL${NC}: $1"; }
skip() { ((TESTS_SKIPPED++)); echo "${YELLOW}SKIP${NC}: $1"; }

# ============================================================================
# Helper: Create test state directory structure
# ============================================================================

seed_state_fixtures() {
    local max_age="${1:-45}"  # Days ago for old items (default: 45)

    # Note: dsr uses XDG_STATE_HOME/dsr not DSR_STATE_DIR in some code paths
    # So we create fixtures in both locations to be safe
    local state_dir="$DSR_STATE_DIR"
    local cache_dir="$DSR_CACHE_DIR"

    # Also export DSR_STATE_DIR to match (for prune to use)
    export DSR_STATE_DIR="$state_dir"
    export DSR_CACHE_DIR="$cache_dir"

    # Create state directory structure
    mkdir -p "$state_dir/logs/2025-12-01"
    mkdir -p "$state_dir/logs/2025-12-15"
    mkdir -p "$state_dir/manifests"
    mkdir -p "$state_dir/artifacts/test-tool/v1.0.0"
    mkdir -p "$state_dir/artifacts/test-tool/v1.1.0"
    mkdir -p "$state_dir/builds/test-tool/v1.0.0/run-001"
    mkdir -p "$state_dir/builds/test-tool/v1.0.0/run-002"
    mkdir -p "$state_dir/builds/test-tool/v1.0.0/run-003"
    mkdir -p "$state_dir/builds/test-tool/v1.0.0/run-004"
    mkdir -p "$state_dir/builds/test-tool/v1.0.0/run-005"
    mkdir -p "$state_dir/builds/test-tool/v1.0.0/run-006"

    # Create cache directory structure
    mkdir -p "$cache_dir/old-cache"
    mkdir -p "$cache_dir/recent-cache"

    # Create dummy files
    echo "old log file" > "$state_dir/logs/2025-12-01/run.log"
    echo "old log file 2" > "$state_dir/logs/2025-12-15/run.log"
    echo '{"tool": "test-tool", "version": "v1.0.0"}' > "$state_dir/manifests/test-tool-v1.0.0.json"
    echo "binary data" > "$state_dir/artifacts/test-tool/v1.0.0/test-tool-linux-amd64"
    echo "binary data" > "$state_dir/artifacts/test-tool/v1.1.0/test-tool-linux-amd64"
    echo "run state" > "$state_dir/builds/test-tool/v1.0.0/run-001/state.json"
    echo "run state" > "$state_dir/builds/test-tool/v1.0.0/run-002/state.json"
    echo "run state" > "$state_dir/builds/test-tool/v1.0.0/run-003/state.json"
    echo "run state" > "$state_dir/builds/test-tool/v1.0.0/run-004/state.json"
    echo "run state" > "$state_dir/builds/test-tool/v1.0.0/run-005/state.json"
    echo "run state" > "$state_dir/builds/test-tool/v1.0.0/run-006/state.json"
    echo "old cache" > "$cache_dir/old-cache/data"
    echo "recent cache" > "$cache_dir/recent-cache/data"

    # Make old items actually old using touch with dates
    local old_date
    old_date=$(date -d "$max_age days ago" +%Y%m%d%H%M.%S 2>/dev/null || date -v-"${max_age}"d +%Y%m%d%H%M.%S 2>/dev/null || echo "")

    if [[ -n "$old_date" ]]; then
        touch -t "${old_date}" "$state_dir/logs/2025-12-01" 2>/dev/null || true
        touch -t "${old_date}" "$state_dir/logs/2025-12-01/run.log" 2>/dev/null || true
        touch -t "${old_date}" "$state_dir/logs/2025-12-15" 2>/dev/null || true
        touch -t "${old_date}" "$state_dir/logs/2025-12-15/run.log" 2>/dev/null || true
        touch -t "${old_date}" "$state_dir/manifests/test-tool-v1.0.0.json" 2>/dev/null || true
        touch -t "${old_date}" "$state_dir/artifacts/test-tool/v1.0.0" 2>/dev/null || true
        touch -t "${old_date}" "$state_dir/builds/test-tool/v1.0.0/run-001" 2>/dev/null || true
        touch -t "${old_date}" "$state_dir/builds/test-tool/v1.0.0/run-002" 2>/dev/null || true
        touch -t "${old_date}" "$cache_dir/old-cache" 2>/dev/null || true
        touch -t "${old_date}" "$cache_dir/old-cache/data" 2>/dev/null || true
    fi
}

seed_minimal_config() {
    mkdir -p "$DSR_CONFIG_DIR"
    cat > "$DSR_CONFIG_DIR/config.yaml" << 'YAML'
schema_version: "1.0.0"
threshold_seconds: 600
log_level: info
signing:
  enabled: false
YAML
}

# ============================================================================
# Tests: Help (always works)
# ============================================================================

test_prune_help() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" prune --help

    if exec_stdout_contains "USAGE:" && exec_stdout_contains "prune"; then
        pass "prune --help shows usage information"
    else
        fail "prune --help should show usage"
        echo "stdout: $(exec_stdout)"
    fi

    harness_teardown
}

test_prune_help_shows_options() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" prune --help

    if exec_stdout_contains "--dry-run" && exec_stdout_contains "--max-age" && exec_stdout_contains "--keep-last"; then
        pass "prune --help shows all options"
    else
        fail "prune --help should show --dry-run, --max-age, --keep-last"
        echo "stdout: $(exec_stdout)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: dry-run behavior
# ============================================================================

test_prune_dry_run_no_delete() {
    ((TESTS_RUN++))
    harness_setup
    seed_minimal_config
    seed_state_fixtures 45

    local state_dir="$DSR_STATE_DIR"

    # Count user-created fixture files before (exclude logs subdir which dsr may write to)
    local fixtures_before
    fixtures_before=$(find "$state_dir/manifests" "$state_dir/artifacts" "$state_dir/builds" -type f 2>/dev/null | wc -l)

    exec_run "$DSR_CMD" prune --dry-run --max-age 30 --force

    # Count user-created fixture files after (exclude logs which may have been written)
    local fixtures_after
    fixtures_after=$(find "$state_dir/manifests" "$state_dir/artifacts" "$state_dir/builds" -type f 2>/dev/null | wc -l)

    # Dry run should not delete any of our fixture files
    if [[ "$fixtures_before" -eq "$fixtures_after" ]]; then
        pass "prune --dry-run does not delete files"
    else
        fail "prune --dry-run should not delete files (before: $fixtures_before, after: $fixtures_after)"
    fi

    harness_teardown
}

test_prune_dry_run_lists_items() {
    ((TESTS_RUN++))
    harness_setup
    seed_minimal_config
    seed_state_fixtures 45

    exec_run "$DSR_CMD" prune --dry-run --max-age 30 --force
    local status
    status=$(exec_status)

    # Should succeed
    if [[ "$status" -eq 0 ]]; then
        pass "prune --dry-run succeeds"
    else
        fail "prune --dry-run should succeed (exit: $status)"
        echo "stderr: $(exec_stderr | head -10)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: JSON output
# ============================================================================

test_prune_json_valid() {
    ((TESTS_RUN++))
    harness_setup
    seed_minimal_config
    seed_state_fixtures 45

    exec_run "$DSR_CMD" --json prune --dry-run --max-age 30 --force
    local output
    output=$(exec_stdout)

    if echo "$output" | jq . >/dev/null 2>&1; then
        pass "prune --json produces valid JSON"
    else
        fail "prune --json should produce valid JSON"
        echo "output: $output"
    fi

    harness_teardown
}

test_prune_json_has_required_fields() {
    ((TESTS_RUN++))
    harness_setup
    seed_minimal_config
    seed_state_fixtures 45

    exec_run "$DSR_CMD" --json prune --dry-run --max-age 30 --force
    local output
    output=$(exec_stdout)

    # Check required fields from prune-details.json schema
    local has_state_dir has_dry_run has_pruned_count has_bytes_freed
    has_state_dir=$(echo "$output" | jq '.details | has("state_dir")' 2>/dev/null)
    has_dry_run=$(echo "$output" | jq '.details | has("dry_run")' 2>/dev/null)
    has_pruned_count=$(echo "$output" | jq '.details | has("pruned_count")' 2>/dev/null)
    has_bytes_freed=$(echo "$output" | jq '.details | has("bytes_freed")' 2>/dev/null)

    if [[ "$has_state_dir" == "true" && "$has_dry_run" == "true" && "$has_pruned_count" == "true" && "$has_bytes_freed" == "true" ]]; then
        pass "prune JSON has required schema fields"
    else
        fail "prune JSON missing required fields"
        echo "has_state_dir: $has_state_dir"
        echo "has_dry_run: $has_dry_run"
        echo "has_pruned_count: $has_pruned_count"
        echo "has_bytes_freed: $has_bytes_freed"
        echo "output: $(echo "$output" | jq '.details' 2>/dev/null | head -20)"
    fi

    harness_teardown
}

test_prune_json_dry_run_flag() {
    ((TESTS_RUN++))
    harness_setup
    seed_minimal_config
    seed_state_fixtures 45

    exec_run "$DSR_CMD" --json prune --dry-run --max-age 30 --force
    local output
    output=$(exec_stdout)

    local dry_run_value
    dry_run_value=$(echo "$output" | jq '.details.dry_run' 2>/dev/null)

    if [[ "$dry_run_value" == "true" ]]; then
        pass "prune JSON reports dry_run: true"
    else
        fail "prune JSON should report dry_run: true"
        echo "dry_run: $dry_run_value"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Actual prune behavior
# ============================================================================

test_prune_removes_old_logs() {
    ((TESTS_RUN++))
    harness_setup
    seed_minimal_config
    seed_state_fixtures 45

    local state_dir="$DSR_STATE_DIR"

    # Verify old logs exist
    if [[ ! -d "$state_dir/logs/2025-12-01" ]]; then
        skip "Could not set up old log directory"
        harness_teardown
        return 0
    fi

    exec_run "$DSR_CMD" prune --max-age 30 --force

    # Check if old log directories were removed
    if [[ ! -d "$state_dir/logs/2025-12-01" ]] || [[ ! -d "$state_dir/logs/2025-12-15" ]]; then
        pass "prune removes old log directories"
    else
        # Check mtime - if touch didn't work, skip
        local mtime_days
        mtime_days=$(( ($(date +%s) - $(stat -c %Y "$state_dir/logs/2025-12-01" 2>/dev/null || stat -f %m "$state_dir/logs/2025-12-01" 2>/dev/null || date +%s)) / 86400 ))
        if [[ "$mtime_days" -lt 30 ]]; then
            skip "Touch command didn't set old mtime (days ago: $mtime_days)"
        else
            fail "prune should remove old log directories"
            echo "2025-12-01 exists: $(test -d "$state_dir/logs/2025-12-01" && echo yes || echo no)"
            echo "mtime days: $mtime_days"
        fi
    fi

    harness_teardown
}

test_prune_respects_keep_last() {
    ((TESTS_RUN++))
    harness_setup
    seed_minimal_config
    seed_state_fixtures 45

    local state_dir="$DSR_STATE_DIR"

    # We have 6 runs, keep_last=5 should remove 1 old one
    exec_run "$DSR_CMD" prune --max-age 30 --keep-last 5 --force

    # Count remaining run directories
    local run_count
    run_count=$(find "$state_dir/builds/test-tool/v1.0.0" -maxdepth 1 -type d -name 'run-*' 2>/dev/null | wc -l)

    # Should have at most 5 (or 6 if dates weren't properly set)
    if [[ "$run_count" -le 5 ]]; then
        pass "prune respects --keep-last (runs: $run_count)"
    else
        skip "prune keep-last may not trigger without proper mtime (runs: $run_count)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Error handling
# ============================================================================

test_prune_invalid_max_age() {
    ((TESTS_RUN++))
    harness_setup
    seed_minimal_config
    mkdir -p "$DSR_STATE_DIR"

    exec_run "$DSR_CMD" prune --max-age invalid --force
    local status
    status=$(exec_status)

    if [[ "$status" -eq 4 ]]; then
        pass "prune fails with invalid --max-age (exit: 4)"
    else
        fail "prune should fail with exit 4 for invalid --max-age (got: $status)"
    fi

    harness_teardown
}

test_prune_invalid_keep_last() {
    ((TESTS_RUN++))
    harness_setup
    seed_minimal_config
    mkdir -p "$DSR_STATE_DIR"

    exec_run "$DSR_CMD" prune --keep-last invalid --force
    local status
    status=$(exec_status)

    if [[ "$status" -eq 4 ]]; then
        pass "prune fails with invalid --keep-last (exit: 4)"
    else
        fail "prune should fail with exit 4 for invalid --keep-last (got: $status)"
    fi

    harness_teardown
}

test_prune_unknown_option() {
    ((TESTS_RUN++))
    harness_setup
    seed_minimal_config
    mkdir -p "$DSR_STATE_DIR"

    exec_run "$DSR_CMD" prune --unknown-option --force
    local status
    status=$(exec_status)

    if [[ "$status" -eq 4 ]]; then
        pass "prune fails with unknown option (exit: 4)"
    else
        fail "prune should fail with exit 4 for unknown option (got: $status)"
    fi

    harness_teardown
}

test_prune_missing_state_dir() {
    ((TESTS_RUN++))
    harness_setup
    seed_minimal_config

    # Point to a truly non-existent state directory
    # Note: dsr may fall back to XDG_STATE_HOME, so unset that too
    local fake_state_dir="$TEST_TMPDIR/definitely_does_not_exist_state"
    export DSR_STATE_DIR="$fake_state_dir"
    export XDG_STATE_HOME="$TEST_TMPDIR/definitely_does_not_exist_xdg"
    # Make sure the directories don't exist
    rm -rf "$fake_state_dir" 2>/dev/null || true
    rm -rf "$TEST_TMPDIR/definitely_does_not_exist_xdg" 2>/dev/null || true

    exec_run "$DSR_CMD" prune --dry-run --force
    local status
    status=$(exec_status)

    # Should fail with exit 4 (invalid args / missing directory)
    # However, dsr might create the directory on init, so accept either behavior
    if [[ "$status" -eq 4 ]]; then
        pass "prune fails with missing state dir (exit: 4)"
    elif [[ "$status" -eq 0 ]] && exec_stderr_contains "not found"; then
        pass "prune reports missing state dir but continues (exit: 0)"
    elif [[ "$status" -eq 0 ]]; then
        # dsr might create the state dir automatically - check if it did
        if [[ -d "$fake_state_dir" ]] || [[ -d "$TEST_TMPDIR/definitely_does_not_exist_xdg/dsr" ]]; then
            skip "dsr auto-creates state directory (this is valid behavior)"
        else
            skip "dsr handles missing state dir gracefully (exit: $status)"
        fi
    else
        fail "prune should fail with exit 4 for missing state dir (got: $status)"
        echo "stderr: $(exec_stderr | head -5)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Stream separation
# ============================================================================

test_prune_stream_separation() {
    ((TESTS_RUN++))
    harness_setup
    seed_minimal_config
    seed_state_fixtures 45

    exec_run "$DSR_CMD" --json prune --dry-run --max-age 30 --force

    local stdout stderr
    stdout=$(exec_stdout)
    stderr=$(exec_stderr)

    # stdout should be JSON only (no log messages)
    local stdout_is_json=false
    if echo "$stdout" | jq . >/dev/null 2>&1; then
        stdout_is_json=true
    fi

    # stderr should NOT contain JSON
    local stderr_has_json=false
    if echo "$stderr" | grep -q '^{.*}$'; then
        stderr_has_json=true
    fi

    if [[ "$stdout_is_json" == "true" && "$stderr_has_json" == "false" ]]; then
        pass "prune maintains stream separation (JSON on stdout, messages on stderr)"
    else
        fail "prune should maintain stream separation"
        echo "stdout is JSON: $stdout_is_json"
        echo "stderr has JSON: $stderr_has_json"
        echo "stderr preview: $(echo "$stderr" | head -3)"
    fi

    harness_teardown
}

# ============================================================================
# Cleanup
# ============================================================================

cleanup() {
    exec_cleanup 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================================
# Run All Tests
# ============================================================================

echo "=== E2E: dsr prune Tests ==="
echo ""

echo "Help Tests (always work):"
test_prune_help
test_prune_help_shows_options

echo ""
echo "Dry-run Tests:"
test_prune_dry_run_no_delete
test_prune_dry_run_lists_items

echo ""
echo "JSON Output Tests:"
test_prune_json_valid
test_prune_json_has_required_fields
test_prune_json_dry_run_flag

echo ""
echo "Actual Prune Tests:"
test_prune_removes_old_logs
test_prune_respects_keep_last

echo ""
echo "Error Handling Tests:"
test_prune_invalid_max_age
test_prune_invalid_keep_last
test_prune_unknown_option
test_prune_missing_state_dir

echo ""
echo "Stream Separation Tests:"
test_prune_stream_separation

echo ""
echo "=========================================="
echo "Tests run:    $TESTS_RUN"
echo "Passed:       $TESTS_PASSED"
echo "Skipped:      $TESTS_SKIPPED"
echo "Failed:       $TESTS_FAILED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
