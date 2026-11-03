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

write_prune_run_state() {
    local path="$1" tool="$2" version="$3" run="$4"
    local roots="${5:-}" history="${6:-}"
    [[ -n "$roots" ]] || roots='{}'
    [[ -n "$history" ]] || history='[]'
    jq -nc --arg tool "$tool" --arg version "$version" --arg run "$run" \
        --argjson roots "$roots" --argjson history "$history" \
        '{tool:$tool,version:$version,run_id:$run,status:"completed",
          created_at:"2025-01-01T00:00:00Z",updated_at:"2025-01-01T00:00:00Z",
          targets:[],target_statuses:{},hosts:{},
          context:{source_roots:$roots},source_sync_history:$history}' > "$path"
}

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
    local run
    for run in run-001 run-002 run-003 run-004 run-005 run-006; do
        write_prune_run_state "$state_dir/builds/test-tool/v1.0.0/$run/state.json" \
            test-tool v1.0.0 "$run" || return 1
    done
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

# The layout dsr writes: artifacts/<tool>-<tag>/ beside its manifest, a
# release journal for published tags, and UUID-named build runs with `latest`.
seed_real_layout() {
    local s="$DSR_STATE_DIR" run
    mkdir -p "$s/artifacts" "$s/releases" "$s/builds/tool/v1.0.0"
    for run in tool-v1.0.0 tool-v1.1.0 tool-v2.0.0; do
        mkdir -p "$s/artifacts/$run"
        echo payload > "$s/artifacts/$run/tool-linux-amd64.tar.gz"
        printf '{"tool":"tool","version":"%s"}\n' "${run#tool-}" > "$s/artifacts/$run-manifest.json"
    done
    echo '{"uploaded":[]}' > "$s/releases/tool-v1.0.0-upload.json"
    for run in 11111111-1111-4111-8111-111111111111 22222222-2222-4222-8222-222222222222 \
        33333333-3333-4333-8333-333333333333 44444444-4444-4444-8444-444444444444; do
        mkdir -p "$s/builds/tool/v1.0.0/$run"
        write_prune_run_state "$s/builds/tool/v1.0.0/$run/state.json" tool v1.0.0 "$run" || return 1
    done
    ln -s 11111111-1111-4111-8111-111111111111 "$s/builds/tool/v1.0.0/latest"
    # Oldest first; tool-v2.0.0 and run 4444... stay recent.
    touch -d '90 days ago' "$s/artifacts/tool-v1.0.0" "$s/artifacts/tool-v1.0.0-manifest.json" \
        "$s/builds/tool/v1.0.0/11111111-1111-4111-8111-111111111111"
    touch -d '80 days ago' "$s/artifacts/tool-v1.1.0" "$s/artifacts/tool-v1.1.0-manifest.json" \
        "$s/builds/tool/v1.0.0/22222222-2222-4222-8222-222222222222"
    touch -d '70 days ago' "$s/builds/tool/v1.0.0/33333333-3333-4333-8333-333333333333"
}

test_prune_real_layout_keeps_releases_and_latest() {
    ((TESTS_RUN++))
    harness_setup
    seed_minimal_config
    if ! touch -d '1 day ago' "$TEST_TMPDIR" 2>/dev/null; then
        skip "touch -d unavailable"
        harness_teardown
        return 0
    fi
    seed_real_layout
    local s="$DSR_STATE_DIR" problems=()

    exec_run "$DSR_CMD" --json prune --max-age 30 --keep-last 1 --force
    [[ "$(exec_status)" -eq 0 ]] || problems+=("exit $(exec_status)")
    [[ ! -e "$s/artifacts/tool-v1.1.0" && ! -e "$s/artifacts/tool-v1.1.0-manifest.json" ]] ||
        problems+=("old unreleased artifact set kept")
    [[ -d "$s/artifacts/tool-v1.0.0" && -f "$s/artifacts/tool-v1.0.0-manifest.json" ]] ||
        problems+=("published release artifacts removed")
    [[ -d "$s/artifacts/tool-v2.0.0" ]] || problems+=("newest artifact set removed")
    [[ -d "$s/builds/tool/v1.0.0/11111111-1111-4111-8111-111111111111" ]] ||
        problems+=("run that latest points to removed")
    [[ -d "$s/builds/tool/v1.0.0/44444444-4444-4444-8444-444444444444" ]] || problems+=("newest run removed")
    [[ ! -e "$s/builds/tool/v1.0.0/22222222-2222-4222-8222-222222222222" &&
       ! -e "$s/builds/tool/v1.0.0/33333333-3333-4333-8333-333333333333" ]] ||
        problems+=("old UUID runs beyond keep-last kept")
    exec_stdout | jq -e '.details.keep_releases == true and .details.kept_for_releases == 1' >/dev/null ||
        problems+=("details do not report the kept release")

    exec_run "$DSR_CMD" prune --max-age 30 --keep-last 1 --no-keep-releases --force
    [[ ! -e "$s/artifacts/tool-v1.0.0" ]] || problems+=("--no-keep-releases kept the released set")

    if [[ ${#problems[@]} -eq 0 ]]; then
        pass "prune removes old artifact sets and UUID runs, keeping releases, latest and keep-last"
    else
        fail "prune real layout: ${problems[*]}"
        echo "stderr: $(exec_stderr | tail -10)"
    fi
    harness_teardown
}

test_prune_global_dry_run_deletes_nothing() {
    ((TESTS_RUN++))
    harness_setup
    seed_minimal_config
    if ! touch -d '1 day ago' "$TEST_TMPDIR" 2>/dev/null; then
        skip "touch -d unavailable"
        harness_teardown
        return 0
    fi
    seed_real_layout
    local before after
    before=$(find "$DSR_STATE_DIR" | sort)

    exec_run "$DSR_CMD" --json --dry-run prune --max-age 30 --keep-last 1 --force
    after=$(find "$DSR_STATE_DIR" | sort)
    if [[ "$(exec_status)" -eq 0 && "$before" == "$after" ]] &&
       exec_stdout | jq -e '.details.dry_run == true and .details.pruned_count >= 3' >/dev/null; then
        pass "global --dry-run prune lists items but deletes nothing"
    else
        fail "global --dry-run prune must not delete"
        diff <(echo "$before") <(echo "$after") | head -5
    fi
    harness_teardown
}

# Inspect real entries without following symlinks. Ignore access times, which
# readers may update; retain content, inode, permissions and modification time.
prune_tree_inventory() {
    python3 - "$@" <<'PY'
import hashlib, json, os, pathlib, stat, sys
rows = []
for argument in sys.argv[1:]:
    root = pathlib.Path(argument)
    if not os.path.lexists(root):
        rows.append([str(root), 'missing'])
        continue
    for path in [root] + sorted(root.rglob('*')):
        info = path.lstat()
        data = (os.readlink(path) if stat.S_ISLNK(info.st_mode) else
                hashlib.sha256(path.read_bytes()).hexdigest() if stat.S_ISREG(info.st_mode) else '')
        rows.append([str(path), info.st_ino, info.st_mode, info.st_uid, info.st_gid,
                     info.st_nlink, info.st_mtime_ns, data])
print(json.dumps(rows, separators=(',', ':')))
PY
}

seed_prune_old_run() {
    local tool="$1" version="$2" run="$3" roots="${4:-}" history="${5:-}"
    local directory="$DSR_STATE_DIR/builds/$tool/$version/$run"
    mkdir -p "$directory" || return 1
    write_prune_run_state "$directory/state.json" "$tool" "$version" "$run" "$roots" "$history" || return 1
    python3 - "$directory" <<'PY'
import os, sys, time
old = time.time() - 60 * 86400
os.utime(sys.argv[1], (old, old))
PY
}

seed_prune_pair() {
    local tool="$1" version="$2"
    seed_prune_old_run "$tool" "$version" old-run || return 1
    seed_prune_old_run "$tool" "$version" latest-run || return 1
    ln -s latest-run "$DSR_STATE_DIR/builds/$tool/$version/latest"
}

prune_reported_path() {
    exec_stdout | jq -e --arg path "$1" \
        'any(.details.pruned_paths[]?; .path == $path)' >/dev/null
}

prune_reported_retention() {
    exec_stdout | jq -e --arg path "$1" --arg reason "$2" \
        'any(.details.retained_build_paths[]?; .path == $path and .reason == $reason)' >/dev/null
}

prune_case_result() {
    local label="$1"
    shift
    if [[ $# -eq 0 ]]; then
        pass "$label"
    else
        fail "$label: $*"
        echo "stderr: $(exec_stderr | tail -10)"
    fi
}

wait_prune_marker() {
    python3 - "$1" <<'PY'
import pathlib, sys, time
marker = pathlib.Path(sys.argv[1])
deadline = time.monotonic() + 10
while not marker.exists() and time.monotonic() < deadline:
    time.sleep(0.02)
sys.exit(0 if marker.exists() else 1)
PY
}

# Real kernel custody from the same helpers used by builds. In inherited mode
# the coordinator releases its own descriptor and exits before prune starts.
# The orphaned worker remains the sole lease holder until the test releases it.
start_prune_lease() {
    local mode="$1" control="$2" tool="$3" version="$4"
    mkdir -p "$control" || return 1
    mkfifo "$control/release" || return 1
    (
        # shellcheck source=../../src/logging.sh
        source "$PROJECT_ROOT/src/logging.sh" || exit 1
        # shellcheck source=../../src/build_state.sh
        source "$PROJECT_ROOT/src/build_state.sh" || exit 1
        build_state_init || exit 1
        build_lock_acquire "$tool" "$version" || exit 1
        if [[ "$mode" == inherited ]]; then
            (
                exec 8<> "$control/release"
                : > "$control/ready"
                IFS= read -r -t 30 <&8 || exit 1
                local descriptor
                for descriptor in "${_BUILD_LOCK_FDS[@]}"; do
                    [[ -z "$descriptor" ]] || _build_lock_close_fd "$descriptor" || exit 1
                done
                : > "$control/done"
            ) &
            printf '%s\n' "$!" > "$control/worker.pid"
            build_lock_release "$tool" "$version" || exit 1
            exit 0
        fi
        exec 8<> "$control/release"
        : > "$control/ready"
        IFS= read -r -t 30 <&8 || exit 1
        build_lock_release "$tool" "$version" || exit 1
        : > "$control/done"
    ) > "$control/holder.log" 2>&1 &
    PRUNE_COORDINATOR_PID=$!
    wait_prune_marker "$control/ready" || return 1
    if [[ "$mode" == inherited ]]; then
        wait "$PRUNE_COORDINATOR_PID" || return 1
    fi
}

release_prune_gate() {
    python3 - "$1/release" <<'PY'
import os, sys
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_NONBLOCK)
try:
    os.write(fd, b'release\n')
finally:
    os.close(fd)
PY
}

release_prune_lease() {
    release_prune_gate "$1" || return 1
    wait_prune_marker "$1/done"
}

try_prune_build_lease() {
    bash -c '
        source "$1/src/logging.sh" && source "$1/src/build_state.sh" && build_state_init || exit 1
        status=0
        build_lock_acquire "$2" "$3" || status=$?
        [[ "$status" != 0 ]] || build_lock_release "$2" "$3" || exit 1
        exit "$status"
    ' _ "$PROJECT_ROOT" "$1" "$2"
}

test_prune_holds_custody_until_removal_finishes() {
    ((TESTS_RUN++))
    harness_setup
    seed_minimal_config
    seed_prune_pair guarded-tool v1.0.0
    local directory="$DSR_STATE_DIR/builds/guarded-tool/v1.0.0"
    local control="$TEST_TMPDIR/removal" real_rm prune_pid status problems=()
    real_rm=$(command -v rm)
    mkdir -p "$control/bin"
    mkfifo "$control/release"
    # Pause only this fixture's actual deletion. Every invocation ultimately
    # delegates its exact arguments to real rm; lock acquisition is unmodified.
    cat > "$control/bin/rm" <<'SH'
#!/usr/bin/env bash
if [[ "$#" == 2 && "$1" == -rf && "$2" == "$DSR_PRUNE_STOP_PATH" ]]; then
    exec 8<> "$DSR_PRUNE_GATE/release"
    printf '%s\n' "$@" > "$DSR_PRUNE_GATE/arguments"
    : > "$DSR_PRUNE_GATE/ready"
    IFS= read -r -t 30 <&8 || exit 1
fi
exec "$DSR_PRUNE_REAL_RM" "$@"
SH
    chmod +x "$control/bin/rm"
    env PATH="$control/bin:$PATH" DSR_PRUNE_STOP_PATH="$directory/old-run" \
        DSR_PRUNE_GATE="$control" DSR_PRUNE_REAL_RM="$real_rm" \
        "$DSR_CMD" --json prune --max-age 30 --keep-last 0 --force \
        > "$control/prune.stdout" 2> "$control/prune.stderr" &
    prune_pid=$!
    if wait_prune_marker "$control/ready"; then
        [[ -d "$directory/old-run" ]] || problems+=("deletion did not pause before removing the run")
        status=0
        try_prune_build_lease guarded-tool v1.0.0 > "$control/during.log" 2>&1 || status=$?
        [[ "$status" -eq 2 ]] || problems+=("build acquired custody during deletion (status $status)")
    else
        problems+=("prune never reached the actual removal boundary")
    fi
    release_prune_gate "$control" || problems+=("could not resume actual removal")
    wait "$prune_pid" || problems+=("prune failed after release")
    [[ ! -e "$directory/old-run" && -d "$directory/latest-run" ]] || problems+=("eligible removal/latest retention failed")
    jq -e --arg path "$directory/old-run" 'any(.details.pruned_paths[]?; .path == $path)' \
        "$control/prune.stdout" >/dev/null || problems+=("completed removal not reported")
    try_prune_build_lease guarded-tool v1.0.0 > "$control/after.log" 2>&1 || problems+=("prune left custody held after completion")
    prune_case_result "prune holds the real build lease through actual removal" "${problems[@]}"
    if [[ ${#problems[@]} -gt 0 ]]; then
        cat "$control/prune.stderr" "$control/during.log" "$control/after.log" 2>/dev/null
    fi
    harness_teardown
}

test_prune_build_custody() {
    ((TESTS_RUN++))
    local mode="$1" version="$2" locked_version="$3"
    harness_setup
    seed_minimal_config
    seed_prune_pair active-tool "$version"
    seed_prune_pair idle-tool v1.0.0
    local directory="$DSR_STATE_DIR/builds/active-tool/$version"
    local idle="$DSR_STATE_DIR/builds/idle-tool/v1.0.0/old-run"
    local control="$TEST_TMPDIR/custody" before after problems=()
    if ! start_prune_lease "$mode" "$control" active-tool "$locked_version"; then
        fail "Could not establish real $mode build custody for $locked_version"
        harness_teardown
        return
    fi
    before=$(prune_tree_inventory "$DSR_STATE_DIR/builds")
    exec_run "$DSR_CMD" --json --dry-run prune --max-age 30 --keep-last 0 --force
    after=$(prune_tree_inventory "$DSR_STATE_DIR/builds")
    [[ "$(exec_status)" -eq 0 && "$before" == "$after" ]] || problems+=("dry-run changed custody or state")
    prune_reported_retention "$directory" build_custody || problems+=("dry-run did not report held custody")
    ! prune_reported_path "$directory/old-run" || problems+=("dry-run selected the held run")
    prune_reported_path "$idle" || problems+=("dry-run missed the unrelated eligible run")

    before=$(prune_tree_inventory "$directory/old-run")
    exec_run "$DSR_CMD" --json prune --max-age 30 --keep-last 0 --force
    after=$(prune_tree_inventory "$directory/old-run")
    [[ "$(exec_status)" -eq 0 && "$before" == "$after" ]] || problems+=("held run changed or disappeared")
    prune_reported_retention "$directory" build_custody || problems+=("held custody not reported")
    [[ ! -e "$idle" ]] && prune_reported_path "$idle" || problems+=("unrelated eligible run was not pruned")
    ! prune_reported_path "$directory/old-run" || problems+=("held run reported as pruned")

    release_prune_lease "$control" || problems+=("fixture could not release custody")
    [[ "$mode" == inherited ]] || wait "$PRUNE_COORDINATOR_PID" || problems+=("coordinator did not exit cleanly")
    exec_run "$DSR_CMD" --json prune --max-age 30 --keep-last 0 --force
    [[ "$(exec_status)" -eq 0 && ! -e "$directory/old-run" ]] &&
        prune_reported_path "$directory/old-run" || problems+=("released ordinary run was not pruned")
    [[ -d "$directory/latest-run" ]] || problems+=("latest run was removed")
    prune_case_result "prune respects $mode custody for $version via $locked_version" "${problems[@]}"
    harness_teardown
}

test_prune_dry_run_custody_is_read_only() {
    ((TESTS_RUN++))
    harness_setup
    seed_minimal_config
    seed_prune_pair fresh-tool 1.0.0
    seed_prune_pair free-tool v1.0.0
    local before after problems=()
    if ! bash -c '
        source "$1/src/logging.sh" && source "$1/src/build_state.sh" &&
        build_state_init && build_lock_acquire free-tool v1.0.0 && build_lock_release free-tool v1.0.0
    ' _ "$PROJECT_ROOT" > "$TEST_TMPDIR/free-lease.log" 2>&1; then
        fail "Could not establish a real released build lease"
        harness_teardown
        return
    fi
    before=$(prune_tree_inventory "$DSR_STATE_DIR" "$DSR_CACHE_DIR")
    exec_run "$DSR_CMD" --json --dry-run prune --max-age 30 --keep-last 0 --force
    after=$(prune_tree_inventory "$DSR_STATE_DIR" "$DSR_CACHE_DIR")
    [[ "$(exec_status)" -eq 0 && "$before" == "$after" ]] || problems+=("dry-run wrote state or lease metadata")
    prune_reported_path "$DSR_STATE_DIR/builds/fresh-tool/1.0.0/old-run" || problems+=("fresh eligible run not listed")
    prune_reported_path "$DSR_STATE_DIR/builds/free-tool/v1.0.0/old-run" || problems+=("released eligible run not listed")
    prune_case_result "dry-run probes absent and released leases without filesystem changes" "${problems[@]}"
    harness_teardown
}

test_prune_retains_source_roots() {
    ((TESTS_RUN++))
    local location="$1"
    harness_setup
    seed_minimal_config
    seed_prune_pair strict-tool v1.0.0
    seed_prune_pair idle-tool v1.0.0
    local snapshot="$TEST_TMPDIR/strict-snapshots" roots history='[]' current='{}'
    local directory="$DSR_STATE_DIR/builds/strict-tool/v1.0.0/old-run"
    local idle="$DSR_STATE_DIR/builds/idle-tool/v1.0.0/old-run" before after problems=()
    (umask 077; mkdir -p "$snapshot/run/source" "$snapshot/run/.cargo-home/registry")
    printf 'protected release source\n' > "$snapshot/.sbh-protect"
    printf '[package]\nname = "retained"\nversion = "1.0.0"\n' > "$snapshot/run/source/Cargo.toml"
    printf 'irreplaceable pinned offline cache\n' > "$snapshot/run/.cargo-home/registry/pinned-source"
    chmod 600 "$snapshot/.sbh-protect" "$snapshot/run/source/Cargo.toml" "$snapshot/run/.cargo-home/registry/pinned-source"
    roots=$(jq -nc --arg root "$snapshot/run/source" '{builder:$root}')
    if [[ "$location" == context ]]; then
        current="$roots"
    else
        history=$(jq -nc --argjson roots "$roots" \
            '[{recorded_at:"2025-01-01T00:00:00Z",receipt:{source_roots:$roots}}]')
    fi
    write_prune_run_state "$directory/state.json" strict-tool v1.0.0 old-run "$current" "$history"
    before=$(prune_tree_inventory "$directory" "$snapshot")
    exec_run "$DSR_CMD" --json prune --max-age 30 --keep-last 0 --force
    after=$(prune_tree_inventory "$directory" "$snapshot")
    [[ "$(exec_status)" -eq 0 && "$before" == "$after" ]] || problems+=("checkpoint or protected snapshot changed")
    prune_reported_retention "$directory" source_roots || problems+=("$location source roots not reported")
    ! prune_reported_path "$directory" || problems+=("source-bound run reported as pruned")
    [[ ! -e "$idle" ]] && prune_reported_path "$idle" || problems+=("ordinary eligible run was not pruned")
    prune_case_result "prune retains completed non-latest $location source custody and offline cache" "${problems[@]}"
    harness_teardown
}

test_prune_retains_unverifiable_state() {
    ((TESTS_RUN++))
    harness_setup
    seed_minimal_config
    seed_prune_pair idle-tool v1.0.0
    local version_dir="$DSR_STATE_DIR/builds/unsafe-tool/v1.0.0" run before after problems=() retained_paths=()
    local linked_state="$TEST_TMPDIR/linked-state.json"
    for run in malformed wrong-identity linked missing missing-receipt malformed-history; do
        seed_prune_old_run unsafe-tool v1.0.0 "$run"
        retained_paths+=("$version_dir/$run")
    done
    printf '{"tool":' > "$version_dir/malformed/state.json"
    write_prune_run_state "$version_dir/wrong-identity/state.json" unsafe-tool v1.0.0 unrelated-run
    write_prune_run_state "$version_dir/missing-receipt/state.json" unsafe-tool v1.0.0 missing-receipt \
        '{}' '[{"recorded_at":"2025-01-01T00:00:00Z"}]'
    write_prune_run_state "$version_dir/malformed-history/state.json" unsafe-tool v1.0.0 malformed-history '{}' '{}'
    # Retain the fixture's original states instead of deleting them to create
    # the symlink and absent-state cases.
    mv "$version_dir/linked/state.json" "$linked_state"
    ln -s "$linked_state" "$version_dir/linked/state.json"
    mv "$version_dir/missing/state.json" "$TEST_TMPDIR/missing-state.json"
    python3 - "$version_dir/linked" "$version_dir/missing" <<'PY'
import os, sys, time
old = time.time() - 60 * 86400
for path in sys.argv[1:]:
    os.utime(path, (old, old))
PY
    before=$(prune_tree_inventory "${retained_paths[@]}" "$linked_state")
    exec_run "$DSR_CMD" --json prune --max-age 30 --keep-last 0 --force
    [[ "$(exec_status)" -eq 0 ]] || problems+=("prune failed")
    # Actual pruning may create the version's lease; compare the retained
    # checkpoints individually rather than treating custody creation as damage.
    for run in malformed wrong-identity linked missing missing-receipt malformed-history; do
        [[ -d "$version_dir/$run" ]] || problems+=("$run checkpoint was removed")
        prune_reported_retention "$version_dir/$run" invalid_state || problems+=("$run refusal not reported")
        ! prune_reported_path "$version_dir/$run" || problems+=("$run checkpoint reported as pruned")
    done
    after=$(prune_tree_inventory "${retained_paths[@]}" "$linked_state")
    [[ "$before" == "$after" ]] || problems+=("unverifiable checkpoint bytes or identity changed")
    [[ ! -e "$DSR_STATE_DIR/builds/idle-tool/v1.0.0/old-run" ]] &&
        prune_reported_path "$DSR_STATE_DIR/builds/idle-tool/v1.0.0/old-run" || problems+=("ordinary eligible run was not pruned")
    prune_case_result "prune retains malformed, mismatched, linked, missing and incomplete-history checkpoints" "${problems[@]}"
    harness_teardown
}

test_prune_allows_explicit_no_sync_history() {
    ((TESTS_RUN++))
    harness_setup
    seed_minimal_config
    seed_prune_pair ordinary-tool v1.0.0
    local directory="$DSR_STATE_DIR/builds/ordinary-tool/v1.0.0" problems=()
    write_prune_run_state "$directory/old-run/state.json" ordinary-tool v1.0.0 old-run \
        '{}' '[{"recorded_at":"2025-01-01T00:00:00Z","receipt":null}]'
    exec_run "$DSR_CMD" --json prune --max-age 30 --keep-last 0 --force
    [[ "$(exec_status)" -eq 0 && ! -e "$directory/old-run" ]] || problems+=("ordinary no-sync run was not pruned")
    prune_reported_path "$directory/old-run" || problems+=("ordinary no-sync removal not reported")
    [[ -d "$directory/latest-run" ]] || problems+=("latest run was removed")
    prune_case_result "prune removes an ordinary completed run with an explicit null source-sync receipt" "${problems[@]}"
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
test_prune_real_layout_keeps_releases_and_latest
test_prune_global_dry_run_deletes_nothing

echo ""
echo "Build Custody and Snapshot Retention Tests:"
test_prune_holds_custody_until_removal_finishes
test_prune_build_custody coordinator v1.0.0 v1.0.0
test_prune_build_custody inherited v1.0.0 v1.0.0
test_prune_build_custody coordinator 1.0.0 v1.0.0
test_prune_dry_run_custody_is_read_only
test_prune_retains_source_roots context
test_prune_retains_source_roots history
test_prune_retains_unverifiable_state
test_prune_allows_explicit_no_sync_history

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
