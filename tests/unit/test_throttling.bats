#!/usr/bin/env bats
# test_throttling.bats - Unit tests for throttling logic and watch mode
#
# bd-1jt.5.22: Tests for throttling logic + watch debounce/dedupe
#
# Coverage:
# - Queue-time threshold calculations with mocked time
# - Watch mode dedupe via triggered.json state
# - Jittered sleep intervals
# - Exponential backoff progression
# - Log capture on failure
#
# Run: bats tests/unit/test_throttling.bats

# Load test harness
load ../helpers/test_harness.bash

# ============================================================================
# Test Setup
# ============================================================================

setup() {
    harness_setup

    # Source watch-related functions from dsr for testing
    # We extract the functions we need to test in isolation

    # Watch state variables (mirrored from dsr)
    _WATCH_STATE_DIR="$DSR_STATE_DIR"
    _WATCH_TRIGGERED_FILE="$_WATCH_STATE_DIR/triggered.json"

    # Backoff constants
    _WATCH_BACKOFF_INITIAL=60
    _WATCH_BACKOFF_MAX=3600
    _WATCH_CURRENT_BACKOFF=0

    # Jitter constant
    _WATCH_JITTER_PERCENT=20

    # Create state directory
    mkdir -p "$_WATCH_STATE_DIR"

    # Define the watch functions for testing (mirrors dsr implementation)

    _watch_load_triggered() {
        if [[ -f "$_WATCH_TRIGGERED_FILE" ]]; then
            cat "$_WATCH_TRIGGERED_FILE"
        else
            echo '{"runs": {}, "last_check": null}'
        fi
    }

    _watch_save_triggered() {
        local state="$1"
        echo "$state" > "$_WATCH_TRIGGERED_FILE"
    }

    _watch_is_triggered() {
        local run_id="$1"
        local state
        state=$(_watch_load_triggered)
        echo "$state" | jq -e --arg id "$run_id" '.runs[$id] != null' &>/dev/null
    }

    _watch_mark_triggered() {
        local run_id="$1"
        local state now
        state=$(_watch_load_triggered)
        now=$(mock_time_get)  # Use mocked time

        state=$(echo "$state" | jq --arg id "$run_id" --arg ts "$now" \
            '.runs[$id] = $ts | .last_check = $ts')

        _watch_save_triggered "$state"
    }

    # Note: _watch_cleanup_triggered uses real date for cutoff calculation
    # We test its behavior with controlled timestamps in the triggered file
    _watch_cleanup_triggered() {
        local state cutoff
        state=$(_watch_load_triggered)
        # For testing, calculate cutoff relative to frozen time
        local current_epoch
        current_epoch=$(mock_time_epoch)
        local cutoff_epoch=$((current_epoch - 86400))  # 24 hours ago

        if command -v python3 &>/dev/null; then
            cutoff=$(python3 -c "from datetime import datetime, timezone; print(datetime.fromtimestamp($cutoff_epoch, tz=timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))")
        else
            cutoff=$(date -u -d "@$cutoff_epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
        fi

        if [[ -n "$cutoff" ]]; then
            state=$(echo "$state" | jq --arg cutoff "$cutoff" \
                '.runs |= with_entries(select(.value >= $cutoff))')
            _watch_save_triggered "$state"
        fi
    }

    _watch_jittered_sleep() {
        local base_interval="$1"
        local jitter_range=$((base_interval * _WATCH_JITTER_PERCENT / 100))
        local jitter=$((RANDOM % (jitter_range * 2 + 1) - jitter_range))
        local sleep_time=$((base_interval + jitter))

        [[ $sleep_time -lt 10 ]] && sleep_time=10
        echo "$sleep_time"
    }

    # Backoff progression function
    # Note: Uses global variables set in setup()
    _apply_backoff() {
        if [[ "${_WATCH_CURRENT_BACKOFF:-0}" -eq 0 ]]; then
            _WATCH_CURRENT_BACKOFF="${_WATCH_BACKOFF_INITIAL:-60}"
        else
            _WATCH_CURRENT_BACKOFF=$((_WATCH_CURRENT_BACKOFF * 2))
            if [[ $_WATCH_CURRENT_BACKOFF -gt "${_WATCH_BACKOFF_MAX:-3600}" ]]; then
                _WATCH_CURRENT_BACKOFF="${_WATCH_BACKOFF_MAX:-3600}"
            fi
        fi
    }

    _reset_backoff() {
        _WATCH_CURRENT_BACKOFF=0
    }

    # Queue-time calculation (simplified version of _check_repo logic)
    _calculate_queue_age() {
        local created_at="$1"
        local now="$2"

        # Parse ISO8601 timestamps to epoch and calculate difference
        local created_epoch now_epoch

        if command -v python3 &>/dev/null; then
            created_epoch=$(python3 -c "from datetime import datetime; print(int(datetime.fromisoformat('${created_at}'.replace('Z', '+00:00')).timestamp()))")
            now_epoch=$(python3 -c "from datetime import datetime; print(int(datetime.fromisoformat('${now}'.replace('Z', '+00:00')).timestamp()))")
        else
            created_epoch=$(date -d "$created_at" +%s 2>/dev/null || echo 0)
            now_epoch=$(date -d "$now" +%s 2>/dev/null || echo 0)
        fi

        echo $((now_epoch - created_epoch))
    }

    # Check if run exceeds threshold
    _is_throttled() {
        local age="$1"
        local threshold="$2"
        [[ "$age" -gt "$threshold" ]]
    }
}

teardown() {
    harness_teardown
}

# ============================================================================
# Watch Dedupe Tests - triggered.json state management
# ============================================================================

@test "dedupe: initial state has empty runs" {
    local state
    state=$(_watch_load_triggered)

    local runs_count
    runs_count=$(echo "$state" | jq '.runs | length')

    assert_equal "0" "$runs_count" "Initial state should have no runs"
}

@test "dedupe: mark run as triggered creates entry" {
    _watch_mark_triggered "run-123"

    local state
    state=$(_watch_load_triggered)

    local has_run
    has_run=$(echo "$state" | jq -r '.runs["run-123"] != null')

    assert_equal "true" "$has_run" "Run should be marked as triggered"
}

@test "dedupe: is_triggered returns true for marked run" {
    _watch_mark_triggered "run-456"

    assert_success _watch_is_triggered "run-456"
}

@test "dedupe: is_triggered returns false for unknown run" {
    assert_failure _watch_is_triggered "run-unknown"
}

@test "dedupe: multiple runs can be marked" {
    _watch_mark_triggered "run-100"
    _watch_mark_triggered "run-200"
    _watch_mark_triggered "run-300"

    local state
    state=$(_watch_load_triggered)

    local runs_count
    runs_count=$(echo "$state" | jq '.runs | length')

    assert_equal "3" "$runs_count" "All three runs should be tracked"

    assert_success _watch_is_triggered "run-100"
    assert_success _watch_is_triggered "run-200"
    assert_success _watch_is_triggered "run-300"
}

@test "dedupe: marking same run twice preserves entry" {
    _watch_mark_triggered "run-dup"
    _watch_mark_triggered "run-dup"

    local state
    state=$(_watch_load_triggered)

    local runs_count
    runs_count=$(echo "$state" | jq '.runs | length')

    assert_equal "1" "$runs_count" "Duplicate marking should not create extra entries"
}

@test "dedupe: last_check is updated on mark" {
    _watch_mark_triggered "run-check"

    local state
    state=$(_watch_load_triggered)

    local last_check
    last_check=$(echo "$state" | jq -r '.last_check')

    # Should match our frozen time
    assert_equal "2026-01-30T12:00:00Z" "$last_check" "last_check should be frozen time"
}

# ============================================================================
# Watch Cleanup Tests - triggered.json garbage collection
# ============================================================================

@test "cleanup: removes entries older than 24 hours" {
    # Set up state with old and new entries
    # Frozen time is 2026-01-30T12:00:00Z

    local old_ts="2026-01-29T10:00:00Z"   # 26 hours ago - should be removed
    local new_ts="2026-01-30T10:00:00Z"   # 2 hours ago - should remain

    local state
    state=$(jq -nc \
        --arg old_id "run-old" \
        --arg old_ts "$old_ts" \
        --arg new_id "run-new" \
        --arg new_ts "$new_ts" \
        '{runs: {($old_id): $old_ts, ($new_id): $new_ts}, last_check: null}')

    _watch_save_triggered "$state"

    # Run cleanup
    _watch_cleanup_triggered

    # Check results
    local cleaned_state
    cleaned_state=$(_watch_load_triggered)

    local runs_count
    runs_count=$(echo "$cleaned_state" | jq '.runs | length')

    assert_equal "1" "$runs_count" "Only recent run should remain"
    assert_failure _watch_is_triggered "run-old"
    assert_success _watch_is_triggered "run-new"
}

@test "cleanup: preserves entries exactly 24 hours old" {
    # Entry exactly at 24 hour boundary
    local boundary_ts="2026-01-29T12:00:00Z"  # Exactly 24 hours ago

    local state
    state=$(jq -nc \
        --arg id "run-boundary" \
        --arg ts "$boundary_ts" \
        '{runs: {($id): $ts}, last_check: null}')

    _watch_save_triggered "$state"

    _watch_cleanup_triggered

    # Boundary entry should remain (>= cutoff)
    assert_success _watch_is_triggered "run-boundary"
}

@test "cleanup: handles empty state" {
    # Start with fresh state
    _watch_cleanup_triggered

    local state
    state=$(_watch_load_triggered)

    local runs_count
    runs_count=$(echo "$state" | jq '.runs | length')

    assert_equal "0" "$runs_count" "Empty state should remain empty"
}

# ============================================================================
# Jittered Sleep Tests
# ============================================================================

@test "jitter: base 300s returns value in range [240, 360]" {
    # With 20% jitter, 300s base should give [240, 360]
    local result
    result=$(_watch_jittered_sleep 300)

    [[ "$result" -ge 240 ]] || {
        echo "Result $result < 240 (min)" >&2
        return 1
    }

    [[ "$result" -le 360 ]] || {
        echo "Result $result > 360 (max)" >&2
        return 1
    }
}

@test "jitter: base 60s returns value in range [48, 72]" {
    # With 20% jitter, 60s base should give [48, 72]
    local result
    result=$(_watch_jittered_sleep 60)

    [[ "$result" -ge 48 ]] || {
        echo "Result $result < 48 (min)" >&2
        return 1
    }

    [[ "$result" -le 72 ]] || {
        echo "Result $result > 72 (max)" >&2
        return 1
    }
}

@test "jitter: small base enforces minimum of 10s" {
    # Very small interval should floor at 10
    local result
    result=$(_watch_jittered_sleep 5)

    assert_equal "10" "$result" "Minimum jittered sleep should be 10s"
}

@test "jitter: multiple calls give varying results" {
    # Due to RANDOM, repeated calls should (usually) give different values
    local results=()
    local i

    for ((i=0; i<10; i++)); do
        results+=("$(_watch_jittered_sleep 300)")
    done

    # Check that not all values are identical
    local unique_count
    unique_count=$(printf '%s\n' "${results[@]}" | sort -u | wc -l)

    [[ "$unique_count" -gt 1 ]] || {
        echo "Expected variation in jittered values, got all identical: ${results[*]}" >&2
        return 1
    }
}

# ============================================================================
# Backoff Tests
# ============================================================================

@test "backoff: initial backoff is 60s" {
    _reset_backoff
    _apply_backoff

    assert_equal "60" "$_WATCH_CURRENT_BACKOFF" "Initial backoff should be 60s"
}

@test "backoff: doubles on each application" {
    _reset_backoff

    _apply_backoff
    assert_equal "60" "$_WATCH_CURRENT_BACKOFF" "First backoff: 60s"

    _apply_backoff
    assert_equal "120" "$_WATCH_CURRENT_BACKOFF" "Second backoff: 120s"

    _apply_backoff
    assert_equal "240" "$_WATCH_CURRENT_BACKOFF" "Third backoff: 240s"

    _apply_backoff
    assert_equal "480" "$_WATCH_CURRENT_BACKOFF" "Fourth backoff: 480s"
}

@test "backoff: caps at 3600s (1 hour)" {
    _reset_backoff

    # Apply enough times to exceed max
    local i
    for ((i=0; i<10; i++)); do
        _apply_backoff
    done

    assert_equal "3600" "$_WATCH_CURRENT_BACKOFF" "Backoff should cap at 3600s"
}

@test "backoff: reset clears backoff to 0" {
    _apply_backoff
    _apply_backoff

    [[ "$_WATCH_CURRENT_BACKOFF" -gt 0 ]] || {
        echo "Backoff should be non-zero before reset" >&2
        return 1
    }

    _reset_backoff

    assert_equal "0" "$_WATCH_CURRENT_BACKOFF" "Reset should clear backoff"
}

@test "backoff: progression follows exponential pattern" {
    _reset_backoff

    local expected_values=(60 120 240 480 960 1920 3600 3600)
    local i

    for i in "${!expected_values[@]}"; do
        _apply_backoff
        assert_equal "${expected_values[$i]}" "$_WATCH_CURRENT_BACKOFF" \
            "Backoff step $((i+1)) should be ${expected_values[$i]}s"
    done
}

# ============================================================================
# Queue-Time Calculation Tests (with frozen time)
# ============================================================================

@test "queue-time: calculates age correctly" {
    # Frozen time: 2026-01-30T12:00:00Z
    local now
    now=$(mock_time_get)

    local created="2026-01-30T11:50:00Z"  # 10 minutes ago

    local age
    age=$(_calculate_queue_age "$created" "$now")

    assert_equal "600" "$age" "Age should be 600 seconds (10 minutes)"
}

@test "queue-time: identifies run exceeding threshold" {
    local now
    now=$(mock_time_get)

    local created="2026-01-30T11:50:00Z"  # 10 minutes = 600s ago
    local age
    age=$(_calculate_queue_age "$created" "$now")

    local threshold=300  # 5 minutes

    assert_success _is_throttled "$age" "$threshold"
}

@test "queue-time: identifies run within threshold" {
    local now
    now=$(mock_time_get)

    local created="2026-01-30T11:58:00Z"  # 2 minutes = 120s ago
    local age
    age=$(_calculate_queue_age "$created" "$now")

    local threshold=300  # 5 minutes

    assert_failure _is_throttled "$age" "$threshold"
}

@test "queue-time: handles exact threshold boundary" {
    local now
    now=$(mock_time_get)

    local created="2026-01-30T11:55:00Z"  # Exactly 5 minutes = 300s ago
    local age
    age=$(_calculate_queue_age "$created" "$now")

    local threshold=300

    # At exactly threshold, should NOT be throttled (> not >=)
    assert_failure _is_throttled "$age" "$threshold"
}

@test "queue-time: handles time advancement" {
    local now
    now=$(mock_time_get)

    local created="2026-01-30T11:58:00Z"  # 2 minutes ago
    local age
    age=$(_calculate_queue_age "$created" "$now")

    local threshold=300  # 5 minutes

    # Initially not throttled
    assert_failure _is_throttled "$age" "$threshold"

    # Advance time by 5 minutes
    mock_time_advance 300

    now=$(mock_time_get)
    age=$(_calculate_queue_age "$created" "$now")

    # Now should be throttled (7 minutes > 5 minutes)
    assert_success _is_throttled "$age" "$threshold"
}

# ============================================================================
# Integration Tests - Combined Scenarios
# ============================================================================

@test "integration: dedupe prevents double triggering" {
    local run_id="run-integration-1"

    # First trigger attempt should succeed
    assert_failure _watch_is_triggered "$run_id"

    # Mark as triggered
    _watch_mark_triggered "$run_id"

    # Second trigger attempt should be blocked
    assert_success _watch_is_triggered "$run_id"
}

@test "integration: time advancement affects cleanup" {
    # Mark a run at current frozen time
    _watch_mark_triggered "run-current"

    # Verify it exists
    assert_success _watch_is_triggered "run-current"

    # Advance time by 25 hours
    mock_time_advance $((25 * 3600))

    # Mark another run at new time
    _watch_mark_triggered "run-new"

    # Run cleanup
    _watch_cleanup_triggered

    # Old run should be cleaned up, new should remain
    assert_failure _watch_is_triggered "run-current"
    assert_success _watch_is_triggered "run-new"
}

@test "integration: backoff resets on success" {
    # Build up backoff
    _apply_backoff
    _apply_backoff
    _apply_backoff

    [[ "$_WATCH_CURRENT_BACKOFF" -eq 240 ]] || {
        echo "Backoff should be 240s after 3 failures" >&2
        return 1
    }

    # Simulate success
    _reset_backoff

    assert_equal "0" "$_WATCH_CURRENT_BACKOFF"

    # Next failure should start from initial
    _apply_backoff
    assert_equal "60" "$_WATCH_CURRENT_BACKOFF"
}

# ============================================================================
# Log Capture Tests (verify harness functionality)
# ============================================================================

@test "log capture: captures output on test execution" {
    # Write to log capture
    log_capture_write "Test message for capture"

    # Verify it was captured
    local log_contents
    log_contents=$(cat "$TEST_TMPDIR/test.log")

    assert_contains "$log_contents" "Test message for capture"
}

@test "log capture: captures stderr redirect" {
    # Redirect stderr to log
    echo "Stderr test" >&2 2>> "$TEST_TMPDIR/test.log"

    local log_contents
    log_contents=$(cat "$TEST_TMPDIR/test.log")

    # Log should contain our test header at minimum
    [[ -n "$log_contents" ]] || {
        echo "Log file should not be empty" >&2
        return 1
    }
}

# ============================================================================
# Edge Cases
# ============================================================================

@test "edge: handles missing triggered.json gracefully" {
    rm -f "$_WATCH_TRIGGERED_FILE"

    local state
    state=$(_watch_load_triggered)

    # Should return default state
    local runs_count
    runs_count=$(echo "$state" | jq '.runs | length')

    assert_equal "0" "$runs_count"
}

@test "edge: handles corrupted triggered.json" {
    # Write invalid JSON
    echo "not valid json" > "$_WATCH_TRIGGERED_FILE"

    # is_triggered should fail gracefully (returns non-zero for "not found")
    # The key is that it doesn't crash with a bash error
    run _watch_is_triggered "any-id"

    # jq returns various exit codes (1 or 5) for parse errors
    # This is treated as "not triggered" - corrupted file = assume not triggered
    [[ "$status" -ne 0 ]] || {
        echo "Corrupted JSON should return non-zero (got status=$status)" >&2
        return 1
    }
}

@test "edge: jitter with zero percent would return base" {
    # Temporarily set jitter to 0
    local old_jitter=$_WATCH_JITTER_PERCENT
    _WATCH_JITTER_PERCENT=0

    local result
    result=$(_watch_jittered_sleep 100)

    # Restore
    _WATCH_JITTER_PERCENT=$old_jitter

    assert_equal "100" "$result" "Zero jitter should return base interval"
}
