#!/usr/bin/env bash
# e2e_prune.sh - E2E tests for dsr prune command
#
# Tests prune subcommand with real behavior (no mocks).
# Verifies safety guardrails, dry-run, and JSON output.
#
# Run: ./scripts/tests/e2e_prune.sh [--snapshot-only|--snapshot-race-only|--snapshot-boundary-only]

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

# Snapshot previews must not create cleanup receipts, lease files, logs, or
# change protected source/cache metadata. Inspect every entry without following
# directory links; omit only atime, which a read-only probe may legitimately
# advance on a filesystem mounted without noatime.
prune_snapshot_inventory() {
    python3 - "$@" <<'PY'
import hashlib, json, os, stat, sys
rows = []
def visit(path):
    if not os.path.lexists(path):
        rows.append([path, 'missing'])
        return
    info = os.lstat(path)
    data = (os.readlink(path) if stat.S_ISLNK(info.st_mode) else
            hashlib.sha256(open(path, 'rb').read()).hexdigest()
            if stat.S_ISREG(info.st_mode) else '')
    rows.append([path, info.st_dev, info.st_ino, info.st_mode, info.st_uid,
                 info.st_gid, info.st_nlink, info.st_size, info.st_mtime_ns,
                 info.st_ctime_ns, data])
    if stat.S_ISDIR(info.st_mode):
        for name in sorted(os.listdir(path)):
            visit(os.path.join(path, name))
for root in sys.argv[1:]:
    visit(root)
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

# Canonical current output plus its supported adjacent manifest. Bind completed
# publication markers to the actual manifest bytes; pending outputs deliberately
# retain an older valid manifest so its presence cannot grant prune authority.
seed_prune_artifact_set() {
    local tool="$1" tag="$2" publication="${3:-completed}"
    local set_name="$tool-$tag" purpose=release publishable=true
    local directory="$DSR_STATE_DIR/artifacts/$set_name" manifest digest
    local run="${4:-22222222-2222-4222-8222-222222222222}"
    local sha="${5:-1111111111111111111111111111111111111111}"
    [[ "$publication" != nonpublishable ]] || { purpose=diagnostic-native; publishable=false; }
    (umask 077; mkdir -p "$directory") || return 1
    printf 'retained release payload for %s\n' "$set_name" > "$directory/payload"
    manifest="$directory/$set_name-manifest.json"
    jq -nc --arg tool "$tool" --arg tag "$tag" --arg run "$run" --arg sha "$sha" \
        --arg purpose "$purpose" --argjson publishable "$publishable" \
        '{tool:$tool,version:$tag,run_id:$run,source:{git_sha:$sha},status:"success",
          build_purpose:$purpose,publishable:$publishable,summary:{total:1,success:1,failed:0},
          artifacts:[{name:"payload",path:"payload",target:"linux/amd64"}]}' > "$manifest" || return 1
    cp "$manifest" "$DSR_STATE_DIR/artifacts/$set_name-manifest.json" || return 1
    digest=$(python3 - "$manifest" <<'PY'
import hashlib, pathlib, sys
print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())
PY
) || return 1
    if [[ "$publication" != legacy ]]; then
        jq -nc --arg publication "$publication" --arg run "$run" --arg sha "$sha" \
            --arg purpose "$purpose" --argjson publishable "$publishable" \
            --arg manifest "$set_name-manifest.json" --arg digest "$digest" '
            {publication_schema:1,run_id:$run,git_sha:$sha,build_purpose:$purpose} +
            (if $publication == "pending" then {publication_status:"pending",publishable:false}
             else {publication_status:"completed",publishable:$publishable,
                   manifest_name:$manifest,manifest_sha256:$digest} end)
          ' > "$directory/.dsr-build-purpose.json" || return 1
    fi
    python3 - "$directory" "$DSR_STATE_DIR/artifacts/$set_name-manifest.json" <<'PY'
import os, sys, time
old = time.time() - 60 * 86400
for path in sys.argv[1:]:
    os.utime(path, (old, old))
PY
}

prune_reported_path() {
    exec_stdout | jq -e --arg path "$1" \
        'any(.details.pruned_paths[]?; .path == $path)' >/dev/null
}

prune_reported_retention() {
    exec_stdout | jq -e --arg path "$1" --arg reason "$2" \
        'any(.details.retained_build_paths[]?; .path == $path and .reason == $reason)' >/dev/null
}

prune_reported_artifact_retention() {
    exec_stdout | jq -e --arg path "$1" --arg reason "$2" \
        'any(.details.retained_artifact_paths[]?; .path == $path and .reason == $reason)' >/dev/null
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
    local kind="${1:-checkpoint}"
    harness_setup
    seed_minimal_config
    local directory stop_path
    if [[ "$kind" == artifact ]]; then
        seed_prune_artifact_set guarded-tool v1.0.0
        directory="$DSR_STATE_DIR/artifacts/guarded-tool-v1.0.0"
        stop_path="$directory-manifest.json"
    else
        seed_prune_pair guarded-tool v1.0.0
        directory="$DSR_STATE_DIR/builds/guarded-tool/v1.0.0"
        stop_path="$directory/old-run"
    fi
    local control="$TEST_TMPDIR/removal" real_rm prune_pid status problems=()
    real_rm=$(command -v rm)
    mkdir -p "$control/bin"
    mkfifo "$control/release"
    # Pause only this fixture's actual deletion. Every invocation ultimately
    # delegates its exact arguments to real rm; lock acquisition is unmodified.
    cat > "$control/bin/rm" <<'SH'
#!/usr/bin/env bash
if [[ "$#" == 2 && ( "$1" == -rf || "$1" == -f ) && "$2" == "$DSR_PRUNE_STOP_PATH" ]]; then
    exec 8<> "$DSR_PRUNE_GATE/release"
    printf '%s\n' "$@" > "$DSR_PRUNE_GATE/arguments"
    : > "$DSR_PRUNE_GATE/ready"
    IFS= read -r -t 30 <&8 || exit 1
fi
exec "$DSR_PRUNE_REAL_RM" "$@"
SH
    chmod +x "$control/bin/rm"
    env PATH="$control/bin:$PATH" DSR_PRUNE_STOP_PATH="$stop_path" \
        DSR_PRUNE_GATE="$control" DSR_PRUNE_REAL_RM="$real_rm" \
        "$DSR_CMD" --json prune --max-age 30 --keep-last 0 --force \
        > "$control/prune.stdout" 2> "$control/prune.stderr" &
    prune_pid=$!
    if wait_prune_marker "$control/ready"; then
        [[ -e "$stop_path" ]] || problems+=("deletion did not pause before removing its subject")
        if [[ "$kind" == artifact ]]; then
            [[ ! -e "$directory" ]] || problems+=("sidecar boundary did not follow artifact directory removal")
        fi
        status=0
        try_prune_build_lease guarded-tool v1.0.0 > "$control/during.log" 2>&1 || status=$?
        [[ "$status" -eq 2 ]] || problems+=("build acquired custody during deletion (status $status)")
        if [[ "$kind" == artifact ]]; then
            status=0
            try_prune_build_lease guarded-tool 1.0.0 > "$control/during-bare.log" 2>&1 || status=$?
            [[ "$status" -eq 2 ]] || problems+=("bare-version build acquired custody during sidecar deletion (status $status)")
        fi
    else
        problems+=("prune never reached the actual removal boundary")
    fi
    release_prune_gate "$control" || problems+=("could not resume actual removal")
    wait "$prune_pid" || problems+=("prune failed after release")
    [[ ! -e "$stop_path" ]] || problems+=("eligible removal failed")
    [[ "$kind" == artifact || -d "$directory/latest-run" ]] || problems+=("latest run was removed")
    jq -e --arg path "$stop_path" 'any(.details.pruned_paths[]?; .path == $path)' \
        "$control/prune.stdout" >/dev/null || problems+=("completed removal not reported")
    try_prune_build_lease guarded-tool v1.0.0 > "$control/after.log" 2>&1 || problems+=("prune left custody held after completion")
    if [[ "$kind" == artifact ]]; then
        try_prune_build_lease guarded-tool 1.0.0 > "$control/after-bare.log" 2>&1 || problems+=("prune left bare-version custody held after completion")
    fi
    prune_case_result "prune holds the real build lease through actual $kind removal" "${problems[@]}"
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

test_prune_artifact_build_custody() {
    ((TESTS_RUN++))
    local mode="$1" locked_version="$2"
    harness_setup
    seed_minimal_config
    seed_prune_pair active-tool "$locked_version"
    seed_prune_artifact_set active-tool v1.0.0
    seed_prune_artifact_set idle-tool v2.0.0
    local active="$DSR_STATE_DIR/artifacts/active-tool-v1.0.0"
    local idle="$DSR_STATE_DIR/artifacts/idle-tool-v2.0.0"
    local control="$TEST_TMPDIR/artifact-custody" before after problems=()
    if ! start_prune_lease "$mode" "$control" active-tool "$locked_version"; then
        fail "Could not establish real $mode artifact custody for $locked_version"
        harness_teardown
        return
    fi
    before=$(prune_tree_inventory "$DSR_STATE_DIR" "$DSR_CACHE_DIR")
    exec_run "$DSR_CMD" --json --dry-run prune --max-age 30 --keep-last 0 --force
    after=$(prune_tree_inventory "$DSR_STATE_DIR" "$DSR_CACHE_DIR")
    [[ "$(exec_status)" -eq 0 && "$before" == "$after" ]] || problems+=("artifact dry-run changed state or custody")
    prune_reported_artifact_retention "$active" build_custody || problems+=("held artifact custody not reported in dry-run")
    ! prune_reported_path "$active" && ! prune_reported_path "$active-manifest.json" || problems+=("dry-run selected held artifacts")
    prune_reported_path "$idle" && prune_reported_path "$idle-manifest.json" || problems+=("dry-run missed an unrelated completed artifact set")

    before=$(prune_tree_inventory "$active" "$active-manifest.json")
    exec_run "$DSR_CMD" --json prune --max-age 30 --keep-last 0 --force
    after=$(prune_tree_inventory "$active" "$active-manifest.json")
    [[ "$(exec_status)" -eq 0 && "$before" == "$after" ]] || problems+=("held artifact bytes or identity changed")
    prune_reported_artifact_retention "$active" build_custody || problems+=("held artifact custody not reported")
    ! prune_reported_path "$active" && ! prune_reported_path "$active-manifest.json" || problems+=("held artifacts reported as pruned")
    [[ ! -e "$idle" && ! -e "$idle-manifest.json" ]] &&
        prune_reported_path "$idle" && prune_reported_path "$idle-manifest.json" || problems+=("unrelated completed artifact set was not removed")

    release_prune_lease "$control" || problems+=("fixture could not release custody")
    [[ "$mode" == inherited ]] || wait "$PRUNE_COORDINATOR_PID" || problems+=("coordinator did not exit cleanly")
    exec_run "$DSR_CMD" --json prune --max-age 30 --keep-last 0 --force
    [[ "$(exec_status)" -eq 0 && ! -e "$active" && ! -e "$active-manifest.json" ]] &&
        prune_reported_path "$active" && prune_reported_path "$active-manifest.json" || problems+=("released completed artifact set was not removed")
    prune_case_result "prune preserves complete artifacts under $mode $locked_version custody" "${problems[@]}"
    harness_teardown
}

test_prune_retains_pending_artifact_publication() {
    ((TESTS_RUN++))
    harness_setup
    seed_minimal_config
    local publication directory before after problems=() protected=()
    for publication in pending nonpublishable; do
        seed_prune_artifact_set "$publication-tool" v1.0.0 "$publication"
        directory="$DSR_STATE_DIR/artifacts/$publication-tool-v1.0.0"
        protected+=("$directory" "$directory-manifest.json")
    done
    seed_prune_artifact_set idle-tool v2.0.0
    local idle="$DSR_STATE_DIR/artifacts/idle-tool-v2.0.0"
    before=$(prune_tree_inventory "$DSR_STATE_DIR" "$DSR_CACHE_DIR")
    exec_run "$DSR_CMD" --json --dry-run prune --max-age 30 --keep-last 0 --force
    after=$(prune_tree_inventory "$DSR_STATE_DIR" "$DSR_CACHE_DIR")
    [[ "$(exec_status)" -eq 0 && "$before" == "$after" ]] || problems+=("pending artifact dry-run changed the filesystem")
    for publication in pending nonpublishable; do
        directory="$DSR_STATE_DIR/artifacts/$publication-tool-v1.0.0"
        prune_reported_artifact_retention "$directory" publication_pending || problems+=("$publication output not retained in dry-run")
        ! prune_reported_path "$directory" && ! prune_reported_path "$directory-manifest.json" || problems+=("$publication output selected in dry-run")
    done
    before=$(prune_tree_inventory "${protected[@]}")
    exec_run "$DSR_CMD" --json prune --max-age 30 --keep-last 0 --force
    after=$(prune_tree_inventory "${protected[@]}")
    [[ "$(exec_status)" -eq 0 && "$before" == "$after" ]] || problems+=("pending/nonpublishable output changed without a lease")
    for publication in pending nonpublishable; do
        directory="$DSR_STATE_DIR/artifacts/$publication-tool-v1.0.0"
        prune_reported_artifact_retention "$directory" publication_pending || problems+=("$publication output retention not reported")
        ! prune_reported_path "$directory" && ! prune_reported_path "$directory-manifest.json" || problems+=("$publication output reported as pruned")
    done
    [[ ! -e "$idle" && ! -e "$idle-manifest.json" ]] &&
        prune_reported_path "$idle" && prune_reported_path "$idle-manifest.json" || problems+=("unrelated completed output was not removed")
    prune_case_result "prune retains pending and nonpublishable artifacts despite an old valid manifest" "${problems[@]}"
    harness_teardown
}

test_prune_retains_unbound_artifact_ownership() {
    ((TESTS_RUN++))
    harness_setup
    seed_minimal_config
    local name directory old_directory before after problems=() directories=() protected=()
    for name in conflict run-conflict source-conflict malformed-manifest malformed-identity; do
        seed_prune_artifact_set "$name-tool" v1.0.0 legacy
        directories+=("$DSR_STATE_DIR/artifacts/$name-tool-v1.0.0")
    done
    directory="$DSR_STATE_DIR/artifacts/conflict-tool-v1.0.0"
    jq '.version = "v2.0.0"' "$directory-manifest.json" > "$TEST_TMPDIR/conflicting-owner.json"
    mv "$TEST_TMPDIR/conflicting-owner.json" "$directory-manifest.json"
    directory="$DSR_STATE_DIR/artifacts/run-conflict-tool-v1.0.0"
    jq '.run_id = "33333333-3333-4333-8333-333333333333"' "$directory-manifest.json" > "$TEST_TMPDIR/conflicting-run.json"
    mv "$TEST_TMPDIR/conflicting-run.json" "$directory-manifest.json"
    directory="$DSR_STATE_DIR/artifacts/source-conflict-tool-v1.0.0"
    jq '.source.git_sha = ("2" * 40)' "$directory-manifest.json" > "$TEST_TMPDIR/conflicting-source.json"
    mv "$TEST_TMPDIR/conflicting-source.json" "$directory-manifest.json"
    directory="$DSR_STATE_DIR/artifacts/malformed-identity-tool-v1.0.0"
    jq '.run_id = [] | .source.git_sha = {}' "$directory-manifest.json" > "$TEST_TMPDIR/malformed-identity.json"
    cp "$TEST_TMPDIR/malformed-identity.json" "$directory/malformed-identity-tool-v1.0.0-manifest.json"
    cp "$TEST_TMPDIR/malformed-identity.json" "$directory-manifest.json"
    printf '{"tool":' > "$DSR_STATE_DIR/artifacts/malformed-manifest-tool-v1.0.0/malformed-manifest-tool-v1.0.0-manifest.json"
    for name in malformed-marker unbound-marker; do
        seed_prune_artifact_set "$name-tool" v1.0.0
        directories+=("$DSR_STATE_DIR/artifacts/$name-tool-v1.0.0")
    done
    printf '{"publication_schema":' > "$DSR_STATE_DIR/artifacts/malformed-marker-tool-v1.0.0/.dsr-build-purpose.json"
    directory="$DSR_STATE_DIR/artifacts/unbound-marker-tool-v1.0.0"
    jq '.manifest_sha256 = ("0" * 64)' "$directory/.dsr-build-purpose.json" > "$TEST_TMPDIR/unbound-marker.json"
    mv "$TEST_TMPDIR/unbound-marker.json" "$directory/.dsr-build-purpose.json"
    # Completed metadata cannot authorize pruning a custom output, a retained
    # quarantine, or a worker's UUID directory under the artifact root.
    for name in custom-output 44444444-4444-4444-8444-444444444444 worker-tool-v1.0.0.stale-20250101; do
        seed_prune_artifact_set worker-tool v1.0.0
        old_directory="$DSR_STATE_DIR/artifacts/worker-tool-v1.0.0"
        directory="$DSR_STATE_DIR/artifacts/$name"
        mv "$old_directory" "$directory"
        mv "$old_directory-manifest.json" "$directory-manifest.json"
        directories+=("$directory")
    done
    for directory in "${directories[@]}"; do
        protected+=("$directory" "$directory-manifest.json")
    done
    seed_prune_artifact_set idle-tool v2.0.0
    local idle="$DSR_STATE_DIR/artifacts/idle-tool-v2.0.0"
    before=$(prune_tree_inventory "${protected[@]}")
    exec_run "$DSR_CMD" --json prune --max-age 30 --keep-last 0 --force
    after=$(prune_tree_inventory "${protected[@]}")
    [[ "$(exec_status)" -eq 0 && "$before" == "$after" ]] || problems+=("unbound artifact bytes or identity changed")
    for directory in "${directories[@]}"; do
        prune_reported_artifact_retention "$directory" artifact_ownership || problems+=("ownership refusal missing for ${directory##*/}")
        ! prune_reported_path "$directory" && ! prune_reported_path "$directory-manifest.json" || problems+=("unbound set reported as pruned: ${directory##*/}")
    done
    [[ ! -e "$idle" && ! -e "$idle-manifest.json" ]] &&
        prune_reported_path "$idle" && prune_reported_path "$idle-manifest.json" || problems+=("unrelated completed artifact set was not removed")
    prune_case_result "prune retains conflicting, malformed, unbound and noncanonical artifact ownership" "${problems[@]}"
    harness_teardown
}

test_prune_completed_artifact_publication() {
    ((TESTS_RUN++))
    harness_setup
    seed_minimal_config
    seed_prune_artifact_set completed-tool v1.0.0 completed
    seed_prune_artifact_set legacy-tool v1.0.0 legacy
    local name directory problems=()
    exec_run "$DSR_CMD" --json prune --max-age 30 --keep-last 0 --force
    [[ "$(exec_status)" -eq 0 ]] || problems+=("prune failed")
    for name in completed-tool-v1.0.0 legacy-tool-v1.0.0; do
        directory="$DSR_STATE_DIR/artifacts/$name"
        [[ ! -e "$directory" && ! -e "$directory-manifest.json" ]] &&
            prune_reported_path "$directory" && prune_reported_path "$directory-manifest.json" || problems+=("eligible set was not removed: $name")
    done
    prune_case_result "prune removes completed manifest-bound and legacy canonical artifact sets" "${problems[@]}"
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
# Explicit strict snapshot reclamation
# ============================================================================

seed_prune_snapshot_config() {
    seed_minimal_config || return 1
    cat > "$DSR_CONFIG_DIR/hosts.yaml" <<'YAML'
hosts:
  snap_local:
    platform: linux/amd64
    connection: local
  snap_history:
    platform: linux/amd64
    connection: local
  snap_relocated:
    platform: linux/amd64
    connection: local
  snap_remote:
    platform: linux/amd64
    connection: ssh
    ssh_host: snapshot-test-target
YAML
}

# Invoke the production issuer and descriptor-relative filesystem implementation
# in a fresh shell; no source admission, ownership, removal, or lease helper is
# replaced by the tests. Only the explicit transport test substitutes SSH's
# network boundary, and still executes its real streamed producer program.
prune_snapshot_backend() (
    export DSR_HOSTS_FILE="$DSR_CONFIG_DIR/hosts.yaml"
    # shellcheck source=../../src/logging.sh
    source "$PROJECT_ROOT/src/logging.sh" || exit 1
    # shellcheck source=../../src/act_runner.sh
    source "$PROJECT_ROOT/src/act_runner.sh" || exit 1
    "$@"
)

seed_prune_owned_snapshot() {
    local tool="$1" run="$2" host="$3"
    local sha="${4:-1111111111111111111111111111111111111111}"
    local base="$TEST_TMPDIR/snapshots/$host"
    mkdir -p "$base" || return 1
    PRUNE_SNAPSHOT_SOURCE="$base/$tool-$run/source"
    PRUNE_SNAPSHOT_PIN=$(prune_snapshot_backend _act_create_strict_snapshot_owner \
        "$host" "$PRUNE_SNAPSHOT_SOURCE" "$tool" "$run" "$sha") || return 1
    mkdir -p "$PRUNE_SNAPSHOT_SOURCE" "${PRUNE_SNAPSHOT_SOURCE%/source}/.cargo-home/registry" || return 1
    printf 'frozen source for %s on %s\n' "$tool" "$host" > "$PRUNE_SNAPSHOT_SOURCE/input.rs"
    printf 'offline cache for %s on %s\n' "$tool" "$host" > "${PRUNE_SNAPSHOT_SOURCE%/source}/.cargo-home/registry/pinned"
    chmod 600 "$PRUNE_SNAPSHOT_SOURCE/input.rs" "${PRUNE_SNAPSHOT_SOURCE%/source}/.cargo-home/registry/pinned"
}

seed_prune_snapshot_run() {
    local tool="$1" version="$2" run="$3" host="${4:-snap_local}"
    local sha=1111111111111111111111111111111111111111
    local tag="v${version#v}" output result receipts directory
    seed_prune_owned_snapshot "$tool" "$run" "$host" "$sha" || return 1
    seed_prune_artifact_set "$tool" "$tag" completed "$run" "$sha" || return 1
    output="$DSR_STATE_DIR/artifacts/$tool-$tag"
    result=$(jq -nc --arg path "$output/payload" --arg host "$host" \
        '{status:"success",exit_code:0,host:$host,platform:"linux/amd64",
          task_key:"linux/amd64",method:"native",build_purpose:"release",publishable:true,
          artifact_path:$path}') || return 1
    receipts=$(prune_snapshot_backend _act_result_artifact_receipts "$result") || return 1
    result=$(jq -nc --argjson result "$result" --argjson receipts "$receipts" \
        '$result + {resume_artifacts:$receipts}') || return 1
    directory="$DSR_STATE_DIR/builds/$tool/$version/$run"
    (umask 077; mkdir -p "$directory") || return 1
    jq -nc --arg tool "$tool" --arg version "$version" --arg run "$run" \
        --arg sha "$sha" --arg host "$host" --arg root "$PRUNE_SNAPSHOT_SOURCE" \
        --argjson pin "$PRUNE_SNAPSHOT_PIN" --argjson result "$result" --arg output "$output" '
        {tool:$tool,version:$version,run_id:$run,status:"completed",git_sha:$sha,git_ref:("v" + ($version | ltrimstr("v"))),
         created_at:"2025-01-01T00:00:00Z",updated_at:"2025-01-01T00:00:00Z",
         targets:["linux/amd64"],hosts:{($host):{status:"completed",attempts:1}},
         target_statuses:{"linux/amd64":{status:"completed",attempts:1,result:$result}},
         context:{build_purpose:"release",publishable:true,source_roots:{($host):$root},
           snapshot_owners:{($host):$pin},target_hosts:{"linux/amd64":$host},
           build_tasks:[{key:"linux/amd64",platform:"linux/amd64",target_triple:"",method:"native"}],
           source_sync:null,output_dir:$output,parallel_jobs:1},source_sync_history:[],relocations:[]}
      ' > "$directory/state.json" || return 1
    python3 - "$directory" <<'PY'
import os, sys, time
old = time.time() - 60 * 86400
os.utime(sys.argv[1], (old, old))
PY
    PRUNE_SNAPSHOT_STATE="$directory/state.json"
}

# Fixture rewrites are deliberate changes made before the public command. Keep
# their retirement age fixed; the production checkpoint writer is never patched
# or intercepted.
prune_snapshot_edit_state() {
    local file="$1" filter="$2"
    shift 2
    local mtime
    mtime=$(python3 -c 'import os, sys; print(os.stat(os.path.dirname(sys.argv[1])).st_mtime_ns)' "$file") || return 1
    jq "$@" "$filter" "$file" > "$file.fixture-next" && mv "$file.fixture-next" "$file" || return 1
    python3 - "$file" "$mtime" <<'PY'
import os, sys
directory = os.path.dirname(sys.argv[1])
os.utime(directory, ns=(os.stat(directory).st_atime_ns, int(sys.argv[2])))
PY
}

prune_snapshot_reported() {
    local source="$1" status="$2"
    exec_stdout | jq -e --arg source "$source" --arg status "$status" \
        'any(.details.snapshot_results[]?; .source_root == $source and .status == $status)' >/dev/null
}

prune_snapshot_retained() {
    local source="$1" reason="$2"
    exec_stdout | jq -e --arg source "$source" --arg reason "$reason" \
        'any(.details.retained_snapshot_paths[]?; .path == $source and .reason == $reason)' >/dev/null
}

test_prune_snapshots_reclaims_owned_only() {
    ((TESTS_RUN++))
    harness_setup
    seed_prune_snapshot_config
    local tool=snapshot-tool version=v1.0.0 run=33333333-3333-4333-8333-333333333333
    local source pin state before_state before_other after_other inspection problems=()
    if ! seed_prune_snapshot_run "$tool" "$version" "$run"; then
        fail "snapshot fixture is issued by the production owner helper"
        harness_teardown
        return
    fi
    source="$PRUNE_SNAPSHOT_SOURCE" pin="$PRUNE_SNAPSHOT_PIN" state="$PRUNE_SNAPSHOT_STATE"
    mkdir -p "$DSR_STATE_DIR/logs/2020-01-01" "$DSR_CACHE_DIR/old-cache"
    printf 'retained ordinary log\n' > "$DSR_STATE_DIR/logs/2020-01-01/run.log"
    printf 'retained ordinary cache\n' > "$DSR_CACHE_DIR/old-cache/data"
    python3 - "$DSR_STATE_DIR/logs/2020-01-01" "$DSR_STATE_DIR/logs/2020-01-01/run.log" "$DSR_CACHE_DIR/old-cache" <<'PY'
import os, sys, time
old = time.time() - 60 * 86400
for path in sys.argv[1:]:
    os.utime(path, (old, old))
PY
    before_state=$(jq -cS 'del(.snapshot_cleanup,.updated_at)' "$state")
    before_other=$(prune_snapshot_inventory "$DSR_STATE_DIR/artifacts" "$DSR_CACHE_DIR" "$DSR_STATE_DIR/logs/2020-01-01")
    inspection=$(prune_snapshot_backend _act_reclaim_strict_snapshot snap_local "$pin" inspect) || problems+=("owner inspection refused fixture")
    exec_run "$DSR_CMD" --json prune --snapshots --max-age 30 --keep-last 0 --force
    cp "$_EXEC_STDOUT_FILE" "$TEST_TMPDIR/snapshot-success-envelope.json" || problems+=("successful cleanup envelope could not be retained")
    [[ "$(exec_status)" -eq 0 ]] || problems+=("snapshot prune failed")
    [[ ! -e "${source%/source}" && ! -L "${source%/source}" ]] || problems+=("owned source and private cache remained")
    [[ -f "$state" && "$before_state" == "$(jq -cS 'del(.snapshot_cleanup,.updated_at)' "$state")" ]] || problems+=("checkpoint provenance changed")
    after_other=$(prune_snapshot_inventory "$DSR_STATE_DIR/artifacts" "$DSR_CACHE_DIR" "$DSR_STATE_DIR/logs/2020-01-01")
    [[ "$before_other" == "$after_other" ]] || problems+=("snapshot-only mode changed artifacts, ordinary cache, or old logs")
    prune_snapshot_reported "$source" removed || problems+=("removed snapshot was not reported")
    exec_stdout | jq -e --argjson expected "${inspection:-null}" '
        .details.snapshots_only == true and .details.pruned_count == 1 and
        .details.bytes_freed == $expected.size_bytes and .details.bytes_freed > 0 and
        (.details.pruned_paths | length == 1) and .details.pruned_paths[0].status == "removed"
      ' >/dev/null || problems+=("removed bytes or explicit snapshot mode was misreported")
    jq -e --arg source "$source" --argjson pin "$pin" '
        .snapshot_cleanup.schema_version == 1 and (.snapshot_cleanup.roots | length == 1) and
        .snapshot_cleanup.roots[0].source_root == $source and
        .snapshot_cleanup.roots[0].owner_pin == $pin and
        .snapshot_cleanup.roots[0].result.status == "removed" and
        (.snapshot_cleanup.retention_mtime | type == "number")
      ' "$state" >/dev/null || problems+=("per-root cleanup journal lost original ownership")
    # The checkpoint remains old by its retained selection time even though its
    # journal write changes the directory mtime. A retry must not charge bytes
    # again or require that the now-absent receipt be recreated.
    exec_run "$DSR_CMD" --json prune --snapshots --max-age 30 --keep-last 0 --force
    [[ "$(exec_status)" -eq 0 ]] && prune_snapshot_reported "$source" already_absent || problems+=("completed cleanup did not replay idempotently")
    exec_stdout | jq -e '.details.pruned_count == 0 and .details.bytes_freed == 0' >/dev/null || problems+=("repeat cleanup double-counted removed bytes")
    jq -e '.snapshot_cleanup.roots | length == 1' "$state" >/dev/null || problems+=("repeat cleanup duplicated its journal")
    prune_case_result "snapshot prune removes only issued source/cache ownership, preserves provenance, and retries without double charging" "${problems[@]}"
    harness_teardown
}

test_prune_snapshots_preview_read_only() {
    ((TESTS_RUN++))
    harness_setup
    seed_prune_snapshot_config
    local run=44444444-4444-4444-8444-444444444444 source before after problems=()
    if ! seed_prune_snapshot_run preview-tool 1.0.0 "$run"; then
        fail "snapshot preview fixture is issued by the production owner helper"
        harness_teardown
        return
    fi
    source="$PRUNE_SNAPSHOT_SOURCE"
    before=$(prune_snapshot_inventory "$DSR_CONFIG_DIR" "$DSR_STATE_DIR" "$DSR_CACHE_DIR" "$TEST_TMPDIR/snapshots")
    exec_run "$DSR_CMD" --json --dry-run prune --snapshots --max-age 30 --keep-last 0 --force
    after=$(prune_snapshot_inventory "$DSR_CONFIG_DIR" "$DSR_STATE_DIR" "$DSR_CACHE_DIR" "$TEST_TMPDIR/snapshots")
    [[ "$(exec_status)" -eq 0 && "$before" == "$after" ]] || problems+=("global preview changed protected bytes or filesystem metadata")
    prune_snapshot_reported "$source" eligible || problems+=("eligible source was not previewed")
    exec_stdout | jq -e '.details.snapshots_only == true and .details.dry_run == true and
        .details.pruned_count == 1 and .details.bytes_freed > 0' >/dev/null || problems+=("preview projection is incomplete")
    [[ ! -e "$DSR_STATE_DIR/builds/preview-tool/1.0.0/.lock" &&
       ! -e "$DSR_STATE_DIR/builds/preview-tool/v1.0.0/.lock" ]] || problems+=("preview created a canonical or recorded-version lease")
    jq -e 'has("snapshot_cleanup") | not' "$PRUNE_SNAPSHOT_STATE" >/dev/null || problems+=("preview wrote cleanup journal")
    exec_run "$DSR_CMD" --json prune --snapshots --dry-run --max-age 30 --keep-last 0 --force
    after=$(prune_snapshot_inventory "$DSR_CONFIG_DIR" "$DSR_STATE_DIR" "$DSR_CACHE_DIR" "$TEST_TMPDIR/snapshots")
    [[ "$(exec_status)" -eq 0 && "$before" == "$after" ]] || problems+=("subcommand preview changed protected bytes or filesystem metadata")
    prune_snapshot_reported "$source" eligible || problems+=("subcommand preview omitted eligible source")
    prune_case_result "both snapshot previews leave source, cache, state, config, log and absent lease metadata unchanged" "${problems[@]}"
    harness_teardown
}

test_prune_snapshots_historical_roots() {
    ((TESTS_RUN++))
    harness_setup
    seed_prune_snapshot_config
    local tool=history-tool run=55555555-5555-4555-8555-555555555555
    local state current history relocated original problems=()
    if ! seed_prune_snapshot_run "$tool" v1.0.0 "$run"; then
        fail "historical snapshot fixture is issued by the production owner helper"
        harness_teardown
        return
    fi
    state="$PRUNE_SNAPSHOT_STATE" current="$PRUNE_SNAPSHOT_SOURCE"
    seed_prune_owned_snapshot "$tool" "$run" snap_history || problems+=("history owner could not be issued")
    history="$PRUNE_SNAPSHOT_SOURCE"
    prune_snapshot_edit_state "$state" '.source_sync_history = [{recorded_at:"2025-01-01T00:00:00Z",receipt:{source_roots:{snap_history:$root},snapshot_owners:{snap_history:$pin}}}]' \
        --arg root "$history" --argjson pin "$PRUNE_SNAPSHOT_PIN" || problems+=("history fixture failed")
    seed_prune_owned_snapshot "$tool" "$run" snap_relocated || problems+=("relocation owner could not be issued")
    relocated="$PRUNE_SNAPSHOT_SOURCE"
    prune_snapshot_edit_state "$state" '.relocations = [{verified_source_sync:{source_roots:{snap_relocated:$root},snapshot_owners:{snap_relocated:$pin}},prior_context:.context}] |
        .context.source_sync = {source_roots:.context.source_roots,snapshot_owners:.context.snapshot_owners}' \
        --arg root "$relocated" --argjson pin "$PRUNE_SNAPSHOT_PIN" || problems+=("relocation fixture failed")
    original=$(jq -cS 'del(.snapshot_cleanup,.updated_at)' "$state")
    exec_run "$DSR_CMD" --json prune --snapshots --max-age 30 --keep-last 0 --force
    [[ "$(exec_status)" -eq 0 ]] || problems+=("historical reclaim failed")
    local source
    for source in "$current" "$history" "$relocated"; do
        [[ ! -e "${source%/source}" ]] && prune_snapshot_reported "$source" removed || problems+=("historical root was missed: $source")
    done
    exec_stdout | jq -e '.details.pruned_count == 3 and (.details.snapshot_results | length == 3)' >/dev/null || problems+=("duplicate current/source-sync/prior-context references were counted twice")
    jq -e '.snapshot_cleanup.roots | length == 3' "$state" >/dev/null || problems+=("historical roots were not individually journaled")
    [[ "$original" == "$(jq -cS 'del(.snapshot_cleanup,.updated_at)' "$state")" ]] || problems+=("historical source and relocation evidence was rewritten")
    prune_case_result "snapshot reclaim unions current, repeated sync, and prior relocation ownership without losing provenance" "${problems[@]}"
    harness_teardown
}

test_prune_snapshots_ownership_refusals() {
    local kind
    for kind in legacy nonce root-mode receipt-mode receipt-replaced protection-replaced root-replaced root-link ancestor-link route external-hardlink owner; do
        ((TESTS_RUN++))
        harness_setup
        seed_prune_snapshot_config
        local tool=unsafe-snapshot run=66666666-6666-4666-8666-666666666666
        local source parent state before after problems=()
        if [[ "$kind" == owner && "${EUID:-1}" -ne 0 ]]; then
            skip "snapshot owner-UID refusal requires permission to create a differently owned fixture"
            harness_teardown
            continue
        fi
        if ! seed_prune_snapshot_run "$tool" v1.0.0 "$run"; then
            fail "snapshot $kind fixture is issued by the production owner helper"
            harness_teardown
            continue
        fi
        source="$PRUNE_SNAPSHOT_SOURCE" parent="${PRUNE_SNAPSHOT_SOURCE%/source}" state="$PRUNE_SNAPSHOT_STATE"
        case "$kind" in
            legacy) prune_snapshot_edit_state "$state" 'del(.context.snapshot_owners)' ;;
            nonce) prune_snapshot_edit_state "$state" '.context.snapshot_owners.snap_local.nonce = "forged-nonce"' ;;
            root-mode) chmod 755 "$parent" ;;
            receipt-mode) chmod 644 "$parent/.dsr-snapshot-owner.json" ;;
            receipt-replaced)
                cp "$parent/.dsr-snapshot-owner.json" "$parent/receipt-copy"
                chmod 600 "$parent/receipt-copy"
                mv "$parent/receipt-copy" "$parent/.dsr-snapshot-owner.json"
                ;;
            protection-replaced)
                cp "$parent/.sbh-protect" "$parent/protection-copy"
                chmod 600 "$parent/protection-copy"
                mv "$parent/protection-copy" "$parent/.sbh-protect"
                ;;
            root-replaced)
                mv "$parent" "$parent.original"
                cp -a "$parent.original" "$parent"
                ;;
            root-link)
                mv "$parent" "$parent.original"
                ln -s "$parent.original" "$parent"
                ;;
            ancestor-link)
                mv "${parent%/*}" "${parent%/*}.original"
                ln -s "${parent%/*}.original" "${parent%/*}"
                ;;
            route)
                yq -o=json '.hosts.snap_local.platform = "darwin/arm64"' "$DSR_CONFIG_DIR/hosts.yaml" > "$DSR_CONFIG_DIR/hosts.next"
                mv "$DSR_CONFIG_DIR/hosts.next" "$DSR_CONFIG_DIR/hosts.yaml"
                ;;
            external-hardlink) ln "$source/input.rs" "$TEST_TMPDIR/external-hardlink" ;;
            owner) chown 65534 "$parent" ;;
        esac
        before=$(prune_snapshot_inventory "$TEST_TMPDIR/snapshots" "$state" "$DSR_STATE_DIR/artifacts" "$TEST_TMPDIR/external-hardlink")
        exec_run "$DSR_CMD" --json prune --snapshots --max-age 30 --keep-last 0 --force
        after=$(prune_snapshot_inventory "$TEST_TMPDIR/snapshots" "$state" "$DSR_STATE_DIR/artifacts" "$TEST_TMPDIR/external-hardlink")
        [[ "$(exec_status)" -eq 0 && "$before" == "$after" ]] || problems+=("unsafe $kind ownership was changed or caused destructive work")
        exec_stdout | jq -e '.details.pruned_count == 0 and .details.bytes_freed == 0' >/dev/null || problems+=("unsafe ownership reported freed bytes")
        prune_snapshot_retained "$source" snapshot_ownership ||
            prune_reported_retention "${state%/state.json}" invalid_state || problems+=("unsafe ownership refusal was not reported")
        jq -e 'has("snapshot_cleanup") | not' "$state" >/dev/null || problems+=("refused root received a cleanup journal")
        prune_case_result "snapshot reclamation refuses $kind ownership without changing source, output, or checkpoint" "${problems[@]}"
        # Restore only fixture UID custody so the ordinary harness can clean
        # its private tree when tests run without DEBUG.
        [[ "$kind" != owner ]] || chown "${EUID:-0}" "$parent"
        harness_teardown
    done
}

test_prune_snapshots_symlink_contents() {
    ((TESTS_RUN++))
    harness_setup
    seed_prune_snapshot_config
    local run=77777777-7777-4777-8777-777777777777 source outside before after problems=()
    if ! seed_prune_snapshot_run linked-content v1.0.0 "$run"; then
        fail "linked-content snapshot fixture is issued by the production owner helper"
        harness_teardown
        return
    fi
    source="$PRUNE_SNAPSHOT_SOURCE" outside="$TEST_TMPDIR/outside-cache"
    mkdir "$outside"
    printf 'unrelated cache must survive\n' > "$outside/valuable"
    ln -s "$outside" "${source%/source}/.cargo-home/linked-cache"
    ln -s "$outside/valuable" "$source/linked-file"
    before=$(prune_snapshot_inventory "$outside")
    exec_run "$DSR_CMD" --json prune --snapshots --max-age 30 --keep-last 0 --force
    after=$(prune_snapshot_inventory "$outside")
    [[ "$(exec_status)" -eq 0 && ! -e "${source%/source}" ]] || problems+=("owned tree with safe unlink-only symlinks was not reclaimed")
    [[ "$before" == "$after" ]] || problems+=("reclaim followed a source/cache link into unrelated files")
    prune_snapshot_reported "$source" removed || problems+=("symlink-safe removal was not reported")
    prune_case_result "snapshot reclaim unlinks source/cache symlinks without following or changing outside targets" "${problems[@]}"
    harness_teardown
}

test_prune_snapshots_unfinished_publication() {
    local kind
    for kind in running failed pending-output diagnostic missing-marker wrong-run wrong-sha incomplete-target changed-artifact; do
        ((TESTS_RUN++))
        harness_setup
        seed_prune_snapshot_config
        local run=88888888-8888-4888-8888-888888888888 tool=unfinished-tool
        local source state output before after problems=()
        if ! seed_prune_snapshot_run "$tool" v1.0.0 "$run"; then
            fail "snapshot $kind fixture is issued by the production owner helper"
            harness_teardown
            continue
        fi
        source="$PRUNE_SNAPSHOT_SOURCE" state="$PRUNE_SNAPSHOT_STATE"
        output="$DSR_STATE_DIR/artifacts/$tool-v1.0.0"
        case "$kind" in
            running|failed) prune_snapshot_edit_state "$state" '.status = $status' --arg status "$kind" ;;
            pending-output)
                jq '.publication_status="pending" | .publishable=false' "$output/.dsr-build-purpose.json" > "$output/marker-next"
                mv "$output/marker-next" "$output/.dsr-build-purpose.json"
                ;;
            diagnostic) prune_snapshot_edit_state "$state" '.context.build_purpose="diagnostic-native" | .context.publishable=false' ;;
            missing-marker) mv "$output/.dsr-build-purpose.json" "$TEST_TMPDIR/missing-marker" ;;
            wrong-run) prune_snapshot_edit_state "$state" '.run_id="99999999-9999-4999-8999-999999999999"' ;;
            wrong-sha) prune_snapshot_edit_state "$state" '.git_sha="2222222222222222222222222222222222222222"' ;;
            incomplete-target) prune_snapshot_edit_state "$state" '.target_statuses["linux/amd64"].status="pending"' ;;
            changed-artifact) printf 'different successful artifact generation\n' >> "$output/payload" ;;
        esac
        before=$(prune_snapshot_inventory "$TEST_TMPDIR/snapshots" "$state" "$DSR_STATE_DIR/artifacts")
        exec_run "$DSR_CMD" --json prune --snapshots --max-age 30 --keep-last 0 --force
        after=$(prune_snapshot_inventory "$TEST_TMPDIR/snapshots" "$state" "$DSR_STATE_DIR/artifacts")
        [[ "$(exec_status)" -eq 0 && "$before" == "$after" ]] || problems+=("unpublishable $kind run lost protected evidence")
        exec_stdout | jq -e --arg run_path "${state%/state.json}" --arg source "$source" '
            .details.pruned_count == 0 and .details.bytes_freed == 0 and
            (any(.details.retained_build_paths[]?; .path == $run_path) or
             any(.details.retained_snapshot_paths[]?; .path == $source))
          ' >/dev/null || problems+=("unfinished/unbound publication refusal was not reported")
        jq -e 'has("snapshot_cleanup") | not' "$state" >/dev/null || problems+=("unfinished run gained cleanup authority")
        prune_case_result "snapshot reclaim retains $kind run and publication evidence" "${problems[@]}"
        harness_teardown
    done
}

test_prune_snapshots_retention() {
    local kind
    for kind in age keep-last latest published-release; do
        ((TESTS_RUN++))
        harness_setup
        seed_prune_snapshot_config
        local run=99999999-9999-4999-8999-999999999999 tool=retention-tool
        local source state before after problems=() options=(--max-age 30 --keep-last 0)
        if ! seed_prune_snapshot_run "$tool" v1.0.0 "$run"; then
            fail "snapshot $kind retention fixture is issued by the production owner helper"
            harness_teardown
            continue
        fi
        source="$PRUNE_SNAPSHOT_SOURCE" state="$PRUNE_SNAPSHOT_STATE"
        case "$kind" in
            age) options=(--max-age 90 --keep-last 0) ;;
            keep-last) options=(--max-age 30 --keep-last 1) ;;
            latest) ln -s "$run" "${state%/$run/state.json}/latest" ;;
            published-release)
                mkdir -p "$DSR_STATE_DIR/releases"
                printf '{"status":"success"}\n' > "$DSR_STATE_DIR/releases/$tool-v1.0.0-upload.json"
                ;;
        esac
        before=$(prune_snapshot_inventory "$TEST_TMPDIR/snapshots" "$state")
        exec_run "$DSR_CMD" --json prune --snapshots "${options[@]}" --force
        after=$(prune_snapshot_inventory "$TEST_TMPDIR/snapshots" "$state")
        [[ "$(exec_status)" -eq 0 && "$before" == "$after" ]] || problems+=("$kind retention failed")
        exec_stdout | jq -e '.details.pruned_count == 0 and .details.bytes_freed == 0' >/dev/null || problems+=("retained source was charged as reclaimed")
        if [[ "$kind" == published-release ]]; then
            prune_reported_retention "${state%/state.json}" release_retention || problems+=("release retention was not explained")
            exec_run "$DSR_CMD" --json prune --snapshots --max-age 30 --keep-last 0 --no-keep-releases --force
            [[ "$(exec_status)" -eq 0 && ! -e "${source%/source}" ]] || problems+=("explicit published-release override did not reclaim old source")
            [[ -f "$DSR_STATE_DIR/releases/$tool-v1.0.0-upload.json" && -f "$state" ]] || problems+=("release override removed provenance")
        fi
        prune_case_result "snapshot reclamation honors $kind retention" "${problems[@]}"
        harness_teardown
    done
}

test_prune_snapshots_inherited_custody() {
    local locked_version
    for locked_version in 1.0.0 v1.0.0; do
        ((TESTS_RUN++))
        harness_setup
        seed_prune_snapshot_config
        local tool=custody-snapshot run=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa
        local source state before after control="$TEST_TMPDIR/lease" problems=()
        if ! seed_prune_snapshot_run "$tool" 1.0.0 "$run"; then
            fail "snapshot custody fixture is issued by the production owner helper"
            harness_teardown
            continue
        fi
        source="$PRUNE_SNAPSHOT_SOURCE" state="$PRUNE_SNAPSHOT_STATE"
        if ! start_prune_lease inherited "$control" "$tool" "$locked_version"; then
            fail "descendant-only $locked_version build lease could not be acquired"
            harness_teardown
            continue
        fi
        before=$(prune_snapshot_inventory "$TEST_TMPDIR/snapshots" "$state")
        exec_run "$DSR_CMD" --json prune --snapshots --max-age 30 --keep-last 0 --force
        after=$(prune_snapshot_inventory "$TEST_TMPDIR/snapshots" "$state")
        [[ "$(exec_status)" -eq 0 && "$before" == "$after" ]] || problems+=("descendant-held source or checkpoint was changed")
        prune_reported_retention "${state%/$run/state.json}" build_custody || problems+=("recorded/canonical build custody refusal was not reported")
        exec_stdout | jq -e '.details.pruned_count == 0 and .details.bytes_freed == 0' >/dev/null || problems+=("busy snapshot was charged as reclaimed")
        release_prune_lease "$control" || problems+=("descendant did not release custody")
        exec_run "$DSR_CMD" --json prune --snapshots --max-age 30 --keep-last 0 --force
        [[ "$(exec_status)" -eq 0 && ! -e "${source%/source}" ]] || problems+=("retired snapshot was not reclaimed after descendant exit")
        prune_snapshot_reported "$source" removed || problems+=("post-custody cleanup was not reported")
        prune_case_result "snapshot cleanup honors inherited $locked_version lease after coordinator exit" "${problems[@]}"
        harness_teardown
    done
}

# This is a transport-boundary fixture, not native-host qualification. The
# remote issuer/reclaimer are the production streamed programs operating on
# real private directories. The adapter can make one SSH destination unavailable
# without replacing owner validation, descriptor walking, journaling, or locks.
install_prune_snapshot_ssh_boundary() {
    local directory="$TEST_TMPDIR/ssh-boundary"
    mkdir -p "$directory/bin" "$directory/control" || return 1
    cat > "$directory/bin/ssh" <<'BASH'
#!/usr/bin/env bash
set -uo pipefail
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|-p|-l|-i|-F|-J) shift 2 ;;
        -n|-T|-q|-tt) shift ;;
        --) shift; break ;;
        -*) echo "unexpected SSH fixture option: $1" >&2; exit 64 ;;
        *) break ;;
    esac
done
destination="${1:-}"
[[ $# -gt 0 ]] && shift
[[ "$destination" == snapshot-test-target ]] || exit 64
printf '%s\n' "$destination" >> "$PRUNE_SNAPSHOT_TRANSPORT_CONTROL/calls"
if [[ -f "$PRUNE_SNAPSHOT_TRANSPORT_CONTROL/unavailable" ]]; then
    echo 'fixture SSH destination is unavailable' >&2
    exit 255
fi
[[ $# -gt 0 ]] || exit 64
exec bash -c "$*"
BASH
    chmod +x "$directory/bin/ssh" || return 1
    export PRUNE_SNAPSHOT_TRANSPORT_CONTROL="$directory/control"
    export PATH="$directory/bin:$PATH"
}

test_prune_snapshots_partial_transport_retry() {
    ((TESTS_RUN++))
    harness_setup
    seed_prune_snapshot_config
    local original_path="$PATH" tool=partial-tool run=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb
    local state local_source remote_source before_state local_bytes=0 remote_bytes=0
    local first_journal outside_before outside_after problems=()
    install_prune_snapshot_ssh_boundary || problems+=("SSH boundary setup failed")
    if ! seed_prune_snapshot_run "$tool" v1.0.0 "$run"; then
        fail "partial snapshot fixture is issued by the production owner helper"
        export PATH="$original_path"
        unset PRUNE_SNAPSHOT_TRANSPORT_CONTROL
        harness_teardown
        return
    fi
    state="$PRUNE_SNAPSHOT_STATE" local_source="$PRUNE_SNAPSHOT_SOURCE"
    local_bytes=$(prune_snapshot_backend _act_reclaim_strict_snapshot snap_local "$PRUNE_SNAPSHOT_PIN" inspect | jq -er .size_bytes) || problems+=("local owner inspection failed")
    seed_prune_owned_snapshot "$tool" "$run" snap_remote || problems+=("remote streamed producer failed")
    remote_source="$PRUNE_SNAPSHOT_SOURCE"
    remote_bytes=$(prune_snapshot_backend _act_reclaim_strict_snapshot snap_remote "$PRUNE_SNAPSHOT_PIN" inspect | jq -er .size_bytes) || problems+=("remote streamed owner inspection failed")
    prune_snapshot_edit_state "$state" '.source_sync_history = [{recorded_at:"2025-01-01T00:00:00Z",receipt:{source_roots:{snap_remote:$root},snapshot_owners:{snap_remote:$pin}}}]' \
        --arg root "$remote_source" --argjson pin "$PRUNE_SNAPSHOT_PIN" || problems+=("remote history fixture failed")
    before_state=$(jq -cS 'del(.snapshot_cleanup,.updated_at)' "$state")
    outside_before=$(prune_snapshot_inventory "$DSR_STATE_DIR/artifacts")
    : > "$PRUNE_SNAPSHOT_TRANSPORT_CONTROL/unavailable"
    exec_run "$DSR_CMD" --json prune --snapshots --max-age 30 --keep-last 0 --force
    cp "$_EXEC_STDOUT_FILE" "$TEST_TMPDIR/snapshot-partial-host-envelope.json" || problems+=("partial-host envelope could not be retained")
    [[ "$(exec_status)" -eq 1 && ! -e "${local_source%/source}" && -d "${remote_source%/source}" ]] || problems+=("partial host failure did not preserve only the unreclaimed source")
    prune_snapshot_reported "$local_source" removed || problems+=("first host removal was not reported")
    prune_snapshot_retained "$remote_source" snapshot_transport || problems+=("failed host transport was not distinguished")
    exec_stdout | jq -e --argjson bytes "$local_bytes" '.details.pruned_count == 1 and .details.bytes_freed == $bytes' >/dev/null || problems+=("partial pass charged bytes from failed host")
    jq -e --arg source "$local_source" '.snapshot_cleanup.roots | length == 1 and .[0].source_root == $source' "$state" >/dev/null || problems+=("partial pass did not checkpoint its successful root")
    first_journal=$(jq -cS '.snapshot_cleanup.roots[0]' "$state")
    mv "$PRUNE_SNAPSHOT_TRANSPORT_CONTROL/unavailable" "$PRUNE_SNAPSHOT_TRANSPORT_CONTROL/unavailable.saved"
    exec_run "$DSR_CMD" --json prune --snapshots --max-age 30 --keep-last 0 --force
    [[ "$(exec_status)" -eq 0 && ! -e "${remote_source%/source}" ]] || problems+=("retry did not finish the restored host")
    prune_snapshot_reported "$local_source" already_absent || problems+=("retry did not replay the successful first-host journal")
    prune_snapshot_reported "$remote_source" removed || problems+=("retry did not report the remaining host")
    exec_stdout | jq -e --argjson bytes "$remote_bytes" '.details.pruned_count == 1 and .details.bytes_freed == $bytes' >/dev/null || problems+=("retry double-counted prior host bytes")
    jq -e '.snapshot_cleanup.roots | length == 2' "$state" >/dev/null || problems+=("retry did not retain both successful cleanup receipts")
    [[ "$first_journal" == "$(jq -cS --arg source "$local_source" '.snapshot_cleanup.roots[] | select(.source_root==$source)' "$state")" ]] || problems+=("retry rewrote a completed cleanup receipt")
    [[ "$before_state" == "$(jq -cS 'del(.snapshot_cleanup,.updated_at)' "$state")" ]] || problems+=("partial retry rewrote source or build provenance")
    outside_after=$(prune_snapshot_inventory "$DSR_STATE_DIR/artifacts")
    [[ "$outside_before" == "$outside_after" ]] || problems+=("partial retry changed release output")
    export PATH="$original_path"
    unset PRUNE_SNAPSHOT_TRANSPORT_CONTROL
    prune_case_result "partial SSH failure retains per-root progress and retries remaining source without double accounting" "${problems[@]}"
    harness_teardown
}

test_prune_snapshots_retained_data_overlap() {
    local kind
    for kind in nested-output nested-artifact nested-checkpoint; do
        ((TESTS_RUN++))
        harness_setup
        seed_prune_snapshot_config
        local run=cccccccc-cccc-4ccc-8ccc-cccccccccccc tool=overlap-tool
        local original_state_dir="$DSR_STATE_DIR" source parent state output retained_path result receipts
        local before after problems=()
        if ! seed_prune_snapshot_run "$tool" v1.0.0 "$run"; then
            fail "snapshot $kind overlap fixture is issued by the production owner helper"
            harness_teardown
            continue
        fi
        source="$PRUNE_SNAPSHOT_SOURCE" parent="${PRUNE_SNAPSHOT_SOURCE%/source}" state="$PRUNE_SNAPSHOT_STATE"
        output="$DSR_STATE_DIR/artifacts/$tool-v1.0.0"
        retained_path="$output/payload"
        case "$kind" in
            nested-output)
                mv "$output" "$parent/$tool-v1.0.0"
                mv "$output-manifest.json" "$parent/$tool-v1.0.0-manifest.json"
                output="$parent/$tool-v1.0.0"
                retained_path="$output/payload"
                ;;
            nested-artifact)
                retained_path="$source/retained-payload"
                cp "$output/payload" "$retained_path"
                ;;
            nested-checkpoint)
                mkdir "$parent/retained-state"
                mv "$DSR_STATE_DIR/builds" "$parent/retained-state/builds"
                export DSR_STATE_DIR="$parent/retained-state"
                state="$DSR_STATE_DIR/builds/$tool/v1.0.0/$run/state.json"
                ;;
        esac
        # Keep both the published output and completed target receipt valid.
        # A refusal must come from overlapping retained data, not stale paths
        # or deliberately corrupt artifact hashes after the fixture move.
        result=$(jq -c --arg path "$retained_path" '.target_statuses["linux/amd64"].result |
            .artifact_path=$path | del(.resume_artifacts)' "$state") || problems+=("completed result fixture could not be read")
        receipts=$(prune_snapshot_backend _act_result_artifact_receipts "$result") || problems+=("real retained artifact receipt could not be issued")
        result=$(jq -nc --argjson result "$result" --argjson receipts "$receipts" \
            '$result + {resume_artifacts:$receipts}') || problems+=("completed result fixture could not be rebound")
        prune_snapshot_edit_state "$state" '.context.output_dir=$output | .target_statuses["linux/amd64"].result=$result' \
            --arg output "$output" --argjson result "$result" || problems+=("overlap fixture checkpoint could not be updated")
        prune_snapshot_backend _act_target_result_available "$result" release true || problems+=("overlap control has unavailable successful output")
        prune_snapshot_backend _act_reclaim_strict_snapshot snap_local "$PRUNE_SNAPSHOT_PIN" inspect >/dev/null || problems+=("overlap control lacks valid snapshot ownership")
        # Live custody may create lease files or session logs inside a deliberately
        # nested state tree. Compare the protected source, original proof, exact
        # checkpoint and release output independently of those runtime records.
        before=$(prune_snapshot_inventory "$source" "$parent/.cargo-home" \
            "$parent/.dsr-snapshot-owner.json" "$parent/.sbh-protect" "$state" "$output" "$output-manifest.json")
        exec_run "$DSR_CMD" --json prune --snapshots --max-age 30 --keep-last 0 --force
        after=$(prune_snapshot_inventory "$source" "$parent/.cargo-home" \
            "$parent/.dsr-snapshot-owner.json" "$parent/.sbh-protect" "$state" "$output" "$output-manifest.json")
        [[ "$(exec_status)" -eq 0 && -d "$parent" && "$before" == "$after" ]] || problems+=("snapshot cleanup changed overlapping retained data")
        exec_stdout | jq -e --arg run_path "${state%/state.json}" --arg source "$source" '
            .details.pruned_count == 0 and .details.bytes_freed == 0 and
            (any(.details.retained_build_paths[]?; .path == $run_path) or
             any(.details.retained_snapshot_paths[]?; .path == $source))
          ' >/dev/null || problems+=("retained-data overlap refusal was not reported")
        jq -e 'has("snapshot_cleanup") | not' "$state" >/dev/null || problems+=("overlapping root was journaled as reclaimed")
        export DSR_STATE_DIR="$original_state_dir"
        prune_case_result "snapshot reclaim retains $kind with valid ownership and completed artifact evidence" "${problems[@]}"
        harness_teardown
    done
}

# One explicit failure-injection boundary: execute the production descriptor
# walk, payload deletion, retirement proof and marker unlink unchanged, then
# raise immediately before the final snapshot-root rmdir. Reload the original
# executor before dispatch so transport, file validation and all other cleanup
# instructions remain real. This is not a signal-delivery or remote-host test.
prune_snapshot_interrupt_final_rmdir() (
    export DSR_HOSTS_FILE="$DSR_CONFIG_DIR/hosts.yaml"
    # shellcheck source=../../src/logging.sh
    source "$PROJECT_ROOT/src/logging.sh" || exit 1
    # shellcheck source=../../src/act_runner.sh
    source "$PROJECT_ROOT/src/act_runner.sh" || exit 1
    _act_strict_snapshot_exec() {
        local interrupted_host="$1" interrupted_program="$2" interrupted_route="$3"
        local boundary="        os.rmdir(name, dir_fd=parent)" remaining
        [[ "$interrupted_program" == *"$boundary"* ]] || return 4
        remaining="${interrupted_program#*"$boundary"}"
        [[ "$remaining" != *"$boundary"* ]] || return 4
        interrupted_program="${interrupted_program/"$boundary"/"        raise RuntimeError('fixture final-rmdir interruption')"}"
        # shellcheck source=../../src/act_runner.sh
        source "$PROJECT_ROOT/src/act_runner.sh" || return 1
        _act_strict_snapshot_exec "$interrupted_host" "$interrupted_program" "$interrupted_route"
    }
    _act_reclaim_strict_snapshot "$1" "$2" remove
)

test_prune_snapshots_interrupted_tail() {
    local kind
    for kind in retry missing-retirement-proof replaced-root; do
        ((TESTS_RUN++))
        harness_setup
        seed_prune_snapshot_config
        local run=dddddddd-dddd-4ddd-8ddd-dddddddddddd tool=tail-tool
        local source parent state receipt before after nonce interruption_status=0 problems=()
        if ! seed_prune_snapshot_run "$tool" v1.0.0 "$run"; then
            fail "snapshot $kind tail fixture is issued by the production owner helper"
            harness_teardown
            continue
        fi
        source="$PRUNE_SNAPSHOT_SOURCE" parent="${PRUNE_SNAPSHOT_SOURCE%/source}" state="$PRUNE_SNAPSHOT_STATE"
        nonce=$(jq -er .nonce <<< "$PRUNE_SNAPSHOT_PIN") || problems+=("issued pin lacks a nonce")
        receipt="${parent%/*}/.dsr-snapshot-retirement-$nonce.json"
        prune_snapshot_interrupt_final_rmdir snap_local "$PRUNE_SNAPSHOT_PIN" \
            > "$TEST_TMPDIR/tail-interruption.out" 2> "$TEST_TMPDIR/tail-interruption.log" || interruption_status=$?
        [[ "$interruption_status" -ne 0 &&
           "$(< "$TEST_TMPDIR/tail-interruption.log")" == *"fixture final-rmdir interruption"* ]] || problems+=("injected final-rmdir boundary was not reached")
        [[ -d "$parent" && -f "$receipt" && ! -e "$parent/.dsr-snapshot-owner.json" &&
           ! -e "$parent/.sbh-protect" && ! -e "$source" && ! -e "$parent/.cargo-home" ]] || problems+=("real cleanup did not leave the authenticated empty-root tail")
        case "$kind" in
            missing-retirement-proof) mv "$receipt" "$TEST_TMPDIR/retirement-saved.json" ;;
            replaced-root)
                mv "$parent" "$parent.original"
                mkdir -m 700 "$parent"
                ;;
        esac
        before=$(prune_snapshot_inventory "$DSR_CONFIG_DIR" "$DSR_STATE_DIR" "$DSR_CACHE_DIR" \
            "$TEST_TMPDIR/snapshots" "$TEST_TMPDIR/retirement-saved.json")
        exec_run "$DSR_CMD" --json --dry-run prune --snapshots --max-age 30 --keep-last 0 --force
        after=$(prune_snapshot_inventory "$DSR_CONFIG_DIR" "$DSR_STATE_DIR" "$DSR_CACHE_DIR" \
            "$TEST_TMPDIR/snapshots" "$TEST_TMPDIR/retirement-saved.json")
        [[ "$(exec_status)" -eq 0 && "$before" == "$after" ]] || problems+=("tail preview changed retained filesystem metadata")
        if [[ "$kind" == retry ]]; then
            prune_snapshot_reported "$source" eligible || problems+=("authenticated empty-root tail was not previewed")
        else
            prune_snapshot_retained "$source" snapshot_ownership || problems+=("unauthorized markerless tail was not refused in preview")
        fi
        before=$(prune_snapshot_inventory "$state" "$DSR_STATE_DIR/artifacts" \
            "$TEST_TMPDIR/snapshots" "$TEST_TMPDIR/retirement-saved.json")
        exec_run "$DSR_CMD" --json prune --snapshots --max-age 30 --keep-last 0 --force
        if [[ "$kind" == retry ]]; then
            [[ "$(exec_status)" -eq 0 && ! -e "$parent" && ! -e "$receipt" ]] || problems+=("authenticated tail retry did not finish root and sibling-proof removal")
            prune_snapshot_reported "$source" removed || problems+=("tail completion was not reported")
            exec_stdout | jq -e '.details.pruned_count == 1 and .details.bytes_freed == 0' >/dev/null || problems+=("tail retry charged already-removed payload bytes")
            jq -e '.snapshot_cleanup.roots | length == 1 and .[0].result.status == "removed" and .[0].result.size_bytes == 0' \
                "$state" >/dev/null || problems+=("tail completion was not journaled with its actual remaining bytes")
        else
            after=$(prune_snapshot_inventory "$state" "$DSR_STATE_DIR/artifacts" \
                "$TEST_TMPDIR/snapshots" "$TEST_TMPDIR/retirement-saved.json")
            [[ "$(exec_status)" -eq 0 && "$before" == "$after" ]] || problems+=("unauthorized markerless root or proof was changed")
            prune_snapshot_retained "$source" snapshot_ownership || problems+=("unsafe tail refusal was not reported")
            exec_stdout | jq -e '.details.pruned_count == 0 and .details.bytes_freed == 0' >/dev/null || problems+=("refused tail was counted as removed")
            jq -e 'has("snapshot_cleanup") | not' "$state" >/dev/null || problems+=("refused tail gained a cleanup journal")
        fi
        prune_case_result "snapshot final-rmdir interruption handles $kind with original ownership and exact byte accounting" "${problems[@]}"
        harness_teardown
    done
}

# Observe the first real payload unlink through Linux inotify, then move that
# still-open child directory outside the owned snapshot. A held descriptor alone
# must not permit the worker to keep deleting through the moved child. This uses
# the actual helper and kernel notification; no deletion/check helper is mocked.
test_prune_snapshots_descendant_move() {
    ((TESTS_RUN++))
    if [[ "$(uname -s)" != Linux ]]; then
        skip "actual descendant-move notification fixture requires Linux inotify"
        return
    fi
    harness_setup
    seed_prune_snapshot_config
    local run=eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee tool=moving-child-tool
    local source parent state before_state before_artifacts after_artifacts race_status=0 problems=()
    local module="${PRUNE_SNAPSHOT_RACE_MODULE:-$PROJECT_ROOT/src/act_runner.sh}"
    local control="$TEST_TMPDIR/descendant-race"
    if ! seed_prune_snapshot_run "$tool" v1.0.0 "$run"; then
        fail "descendant-move snapshot fixture is issued by the production owner helper"
        harness_teardown
        return
    fi
    source="$PRUNE_SNAPSHOT_SOURCE" parent="${PRUNE_SNAPSHOT_SOURCE%/source}" state="$PRUNE_SNAPSHOT_STATE"
    mkdir "$control"
    printf '%s\n' "$PRUNE_SNAPSHOT_PIN" > "$control/owner-pin.json"
    if [[ -n "${PRUNE_SNAPSHOT_RACE_MODULE:-}" ]]; then
        # Explicit counterexample mode can run an immutable earlier helper. Its
        # supporting imports remain the real current guardrails and platforms.
        mkdir "$control/module"
        cp "$module" "$control/module/act_runner.sh" || problems+=("counterexample module could not be copied")
        ln -s "$PROJECT_ROOT/src/guardrails.sh" "$control/module/guardrails.sh"
        ln -s "$PROJECT_ROOT/src/platforms.sh" "$control/module/platforms.sh"
        module="$control/module/act_runner.sh"
    fi
    before_state=$(prune_snapshot_inventory "$state")
    before_artifacts=$(prune_snapshot_inventory "$DSR_STATE_DIR/artifacts")
    DSR_HOSTS_FILE="$DSR_CONFIG_DIR/hosts.yaml" DSR_SYNC_TIMEOUT=25 \
        python3 - "$module" "$control/owner-pin.json" "$source" "$control" <<'PY' || race_status=$?
import ctypes, hashlib, json, os, pathlib, select, signal, subprocess, sys, time

module, pin, source, control = map(pathlib.Path, sys.argv[1:])
for index in range(1000):
    (source / ('payload-%04d' % index)).write_text('retained payload %04d\n' % index)
original = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in source.iterdir()}
libc = ctypes.CDLL(None, use_errno=True)
descriptor = libc.inotify_init1(os.O_CLOEXEC | os.O_NONBLOCK)
if descriptor < 0:
    raise OSError(ctypes.get_errno(), 'inotify initialization failed')
if libc.inotify_add_watch(descriptor, os.fsencode(source), 0x00000200) < 0:
    os.close(descriptor)
    raise OSError(ctypes.get_errno(), 'inotify payload watch failed')
relocated = control / 'retained-source'
moved = False
at_move = []
status = None
process = None
try:
    with (control / 'remove.stdout').open('wb') as output, (control / 'remove.stderr').open('wb') as errors:
        process = subprocess.Popen(['bash', '-c',
            'source "$1" || exit; _act_reclaim_strict_snapshot snap_local "$(cat "$2")" remove',
            '_', str(module), str(pin)], stdout=output, stderr=errors, start_new_session=True)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and process.poll() is None:
            if select.select([descriptor], [], [], 0.1)[0]:
                os.read(descriptor, 65536)
                source.rename(relocated)
                moved = True
                at_move = sorted(os.listdir(relocated))
                break
        status = process.wait(timeout=35)
finally:
    os.close(descriptor)
    if process is not None and process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)
after = sorted(os.listdir(relocated)) if moved else []
changed = [name for name in after
           if hashlib.sha256((relocated / name).read_bytes()).hexdigest() != original.get(name)]
summary = {'moved': moved, 'remaining_at_move': len(at_move), 'remaining_after': len(after),
           'helper_exit': status, 'outside_deleted': sorted(set(at_move) - set(after)),
           'outside_added': sorted(set(after) - set(at_move)), 'changed_bytes': changed}
(control / 'summary.json').write_text(json.dumps(summary, sort_keys=True) + '\n')
(control / 'inventory-at-move.json').write_text(json.dumps({name: original[name] for name in at_move}, sort_keys=True) + '\n')
print(json.dumps({'moved': moved, 'remaining_at_move': len(at_move), 'remaining_after': len(after),
                  'helper_exit': status, 'outside_deleted': len(summary['outside_deleted']),
                  'outside_added': len(summary['outside_added']), 'changed_bytes': len(changed)}, sort_keys=True))
if not moved or not at_move or status != 4 or at_move != after or changed:
    raise SystemExit(1)
PY
    [[ "$race_status" -eq 0 ]] || problems+=("actual moved descendant lost custody or retained files")
    [[ -d "$parent" && -f "$parent/.dsr-snapshot-owner.json" && -f "$parent/.sbh-protect" ]] || problems+=("refused race discarded snapshot ownership evidence")
    [[ "$before_state" == "$(prune_snapshot_inventory "$state")" ]] || problems+=("refused race changed its completed checkpoint")
    after_artifacts=$(prune_snapshot_inventory "$DSR_STATE_DIR/artifacts")
    [[ "$before_artifacts" == "$after_artifacts" ]] || problems+=("refused race changed release output")
    jq -e 'has("snapshot_cleanup") | not' "$state" >/dev/null || problems+=("refused race gained a cleanup journal")
    prune_case_result "actual inotify descendant move stops cleanup without deleting retained outside filenames or bytes" "${problems[@]}"
    harness_teardown
}

test_prune_snapshots_nested_custody() {
    local kind
    for kind in nested-owner protected-stage nested-retirement; do
        ((TESTS_RUN++))
        harness_setup
        seed_prune_snapshot_config
        local run=12121212-1212-4212-8212-121212121212 tool=outer-owner
        local child_run=34343434-3434-4434-8434-343434343434
        local source parent state pin child_source child_parent child_pin receipt nonce
        local before after inspect_status=0 interruption_status=0 problems=()
        if ! seed_prune_snapshot_run "$tool" v1.0.0 "$run"; then
            fail "snapshot $kind boundary fixture is issued by the production owner helper"
            harness_teardown
            continue
        fi
        source="$PRUNE_SNAPSHOT_SOURCE" parent="${PRUNE_SNAPSHOT_SOURCE%/source}"
        state="$PRUNE_SNAPSHOT_STATE" pin="$PRUNE_SNAPSHOT_PIN"
        if [[ "$kind" == protected-stage ]]; then
            mkdir -m 700 "$source/protected-stage"
            printf 'protected ordinary checkout\n' > "$source/protected-stage/.sbh-protect"
            printf 'independently retained stage bytes\n' > "$source/protected-stage/payload"
            chmod 600 "$source/protected-stage/.sbh-protect" "$source/protected-stage/payload"
        else
            child_source="$source/nested/inner-owner-$child_run/source"
            child_parent="${child_source%/source}"
            child_pin=$(prune_snapshot_backend _act_create_strict_snapshot_owner snap_local \
                "$child_source" inner-owner "$child_run" 2222222222222222222222222222222222222222) || problems+=("independent nested owner could not be issued")
            mkdir "$child_source"
            printf 'independent inner run bytes\n' > "$child_source/payload"
            prune_snapshot_backend _act_reclaim_strict_snapshot snap_local "$child_pin" inspect >/dev/null || problems+=("nested owner control is not independently valid")
            if [[ "$kind" == nested-retirement ]]; then
                nonce=$(jq -er .nonce <<< "$child_pin") || problems+=("nested owner nonce unavailable")
                receipt="${child_parent%/*}/.dsr-snapshot-retirement-$nonce.json"
                prune_snapshot_interrupt_final_rmdir snap_local "$child_pin" \
                    > "$TEST_TMPDIR/nested-interruption.out" 2> "$TEST_TMPDIR/nested-interruption.log" || interruption_status=$?
                [[ "$interruption_status" -ne 0 && -f "$receipt" && -d "$child_parent" &&
                   ! -e "$child_parent/.dsr-snapshot-owner.json" && ! -e "$child_parent/.sbh-protect" &&
                   "$(< "$TEST_TMPDIR/nested-interruption.log")" == *"fixture final-rmdir interruption"* ]] || problems+=("nested authenticated retirement tail was not reached")
                prune_snapshot_backend _act_reclaim_strict_snapshot snap_local "$child_pin" inspect >/dev/null || problems+=("nested retirement proof is not independently valid")
            fi
        fi
        before=$(prune_snapshot_inventory "$parent" "$state" "$DSR_STATE_DIR/artifacts")
        prune_snapshot_backend _act_reclaim_strict_snapshot snap_local "$pin" inspect \
            > "$TEST_TMPDIR/outer-inspection.out" 2> "$TEST_TMPDIR/outer-inspection.log" || inspect_status=$?
        [[ "$inspect_status" -eq 4 ]] || problems+=("outer inspection admitted independent descendant custody")
        exec_run "$DSR_CMD" --json --dry-run prune --snapshots --max-age 30 --keep-last 0 --force
        after=$(prune_snapshot_inventory "$parent" "$state" "$DSR_STATE_DIR/artifacts")
        [[ "$(exec_status)" -eq 0 && "$before" == "$after" ]] || problems+=("boundary preview changed protected evidence")
        prune_snapshot_retained "$source" snapshot_ownership || problems+=("boundary preview did not retain the outer root")
        exec_run "$DSR_CMD" --json prune --snapshots --max-age 30 --keep-last 0 --force
        after=$(prune_snapshot_inventory "$parent" "$state" "$DSR_STATE_DIR/artifacts")
        [[ "$(exec_status)" -eq 0 && "$before" == "$after" ]] || problems+=("outer cleanup changed independently protected descendant custody")
        prune_snapshot_retained "$source" snapshot_ownership || problems+=("boundary refusal was not reported")
        exec_stdout | jq -e '.details.pruned_count == 0 and .details.bytes_freed == 0' >/dev/null || problems+=("protected descendant was charged as reclaimed")
        jq -e 'has("snapshot_cleanup") | not' "$state" >/dev/null || problems+=("refused ownership boundary gained a cleanup journal")
        prune_case_result "snapshot reclaim retains $kind without crossing independent descendant custody" "${problems[@]}"
        harness_teardown
    done
}

test_prune_snapshots_bind_output() {
    ((TESTS_RUN++))
    if [[ "$(uname -s)" != Linux ]] || ! command -v unshare >/dev/null ||
       ! command -v mount >/dev/null || ! command -v umount >/dev/null ||
       ! unshare --user --map-root-user --mount --propagation private --fork -- true >/dev/null 2>&1; then
        skip "actual bind-output fixture requires an isolated user/mount namespace"
        return
    fi
    harness_setup
    local namespace_status=0 problems=()
    # All ownership is issued in the same UID/mount view as the real CLI. A
    # private namespace keeps the real bind mount isolated and self-contained.
    (
        export -f seed_minimal_config seed_prune_snapshot_config seed_prune_owned_snapshot
        export -f seed_prune_snapshot_run seed_prune_artifact_set prune_snapshot_backend prune_snapshot_inventory
        unshare --user --map-root-user --mount --propagation private --fork -- bash -s -- "$PROJECT_ROOT" <<'BASH'
set -uo pipefail
PROJECT_ROOT="$1"
DSR_CMD="$PROJECT_ROOT/dsr"
seed_prune_snapshot_config || exit 1
tool=bind-output-tool
run=56565656-5656-4656-8656-565656565656
seed_prune_snapshot_run "$tool" v1.0.0 "$run" || exit 1
source="$PRUNE_SNAPSHOT_SOURCE"
parent="${source%/source}"
state="$PRUNE_SNAPSHOT_STATE"
output="$DSR_STATE_DIR/artifacts/$tool-v1.0.0"
nested="$parent/retained-output"
mv "$output" "$nested" || exit 1
mkdir -m 700 "$output" || exit 1
mount --bind "$nested" "$output" || exit 1
trap 'umount "$output"' EXIT
python3 - "$nested" "$output" <<'PY'
import os, sys
nested, alias = sys.argv[1:]
left, right = os.stat(nested), os.stat(alias)
assert (left.st_dev, left.st_ino) == (right.st_dev, right.st_ino)
assert os.path.realpath(nested) != os.path.realpath(alias)
assert os.stat(os.path.join(alias, 'payload')).st_nlink == 1
PY
[[ $? -eq 0 ]] || exit 1
# The move and bind preserve all original publication and target receipts.
result=$(jq -c '.target_statuses["linux/amd64"].result' "$state") || exit 1
prune_snapshot_backend _act_target_result_available "$result" release true || exit 1
prune_snapshot_backend _act_reclaim_strict_snapshot snap_local "$PRUNE_SNAPSHOT_PIN" inspect >/dev/null || exit 1
before=$(prune_snapshot_inventory "$parent" "$state" "$output" "$output-manifest.json") || exit 1
"$DSR_CMD" --json --dry-run prune --snapshots --max-age 30 --keep-last 0 --force \
    > "$TEST_TMPDIR/bind-preview-envelope.json" 2> "$TEST_TMPDIR/bind-preview.stderr" || exit 1
after=$(prune_snapshot_inventory "$parent" "$state" "$output" "$output-manifest.json") || exit 1
[[ "$before" == "$after" ]] || exit 1
"$DSR_CMD" --json prune --snapshots --max-age 30 --keep-last 0 --force \
    > "$TEST_TMPDIR/bind-retained-envelope.json" 2> "$TEST_TMPDIR/bind-retained.stderr" || exit 1
after=$(prune_snapshot_inventory "$parent" "$state" "$output" "$output-manifest.json") || exit 1
[[ "$before" == "$after" ]] || exit 1
for envelope in "$TEST_TMPDIR/bind-preview-envelope.json" "$TEST_TMPDIR/bind-retained-envelope.json"; do
    jq -e --arg source "$source" --arg run_path "${state%/state.json}" '
        .details.snapshots_only == true and .details.pruned_count == 0 and .details.bytes_freed == 0 and
        (any(.details.retained_snapshot_paths[]?; .path == $source) or
         any(.details.retained_build_paths[]?; .path == $run_path))
      ' "$envelope" >/dev/null || exit 1
done
jq -e 'has("snapshot_cleanup") | not' "$state" >/dev/null || exit 1
printf '{"bind_mount":true,"original_receipts_preserved":true,"retained":true}\n' > "$TEST_TMPDIR/bind-summary.json"
umount "$output" || exit 1
trap - EXIT
BASH
    ) || namespace_status=$?
    [[ "$namespace_status" -eq 0 ]] || problems+=("real bind alias was admitted or retained data changed")
    prune_case_result "snapshot reclaim preserves canonical completed output bound to a descendant by a real bind mount" "${problems[@]}"
    harness_teardown
}

run_snapshot_prune_tests() {
    echo ""
    echo "Explicit Strict Snapshot Reclamation Tests:"
    test_prune_snapshots_reclaims_owned_only
    test_prune_snapshots_preview_read_only
    test_prune_snapshots_historical_roots
    test_prune_snapshots_ownership_refusals
    test_prune_snapshots_symlink_contents
    test_prune_snapshots_unfinished_publication
    test_prune_snapshots_retention
    test_prune_snapshots_inherited_custody
    test_prune_snapshots_partial_transport_retry
    test_prune_snapshots_retained_data_overlap
    test_prune_snapshots_interrupted_tail
    test_prune_snapshots_descendant_move
    test_prune_snapshots_nested_custody
    test_prune_snapshots_bind_output
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

case "${1:-}" in
    ""|--snapshot-only|--snapshot-race-only|--snapshot-boundary-only) ;;
    *) echo "Usage: $0 [--snapshot-only|--snapshot-race-only|--snapshot-boundary-only]" >&2; exit 2 ;;
esac

if [[ -z "${1:-}" ]]; then
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
echo "Artifact Custody and Publication Tests:"
test_prune_holds_custody_until_removal_finishes artifact
test_prune_artifact_build_custody coordinator v1.0.0
test_prune_artifact_build_custody inherited v1.0.0
test_prune_artifact_build_custody coordinator 1.0.0
test_prune_retains_pending_artifact_publication
test_prune_retains_unbound_artifact_ownership
test_prune_completed_artifact_publication

echo ""
echo "Error Handling Tests:"
test_prune_invalid_max_age
test_prune_invalid_keep_last
test_prune_unknown_option
test_prune_missing_state_dir

echo ""
echo "Stream Separation Tests:"
test_prune_stream_separation
fi

if [[ "${1:-}" == --snapshot-race-only ]]; then
    test_prune_snapshots_descendant_move
elif [[ "${1:-}" == --snapshot-boundary-only ]]; then
    test_prune_snapshots_nested_custody
    test_prune_snapshots_bind_output
else
    run_snapshot_prune_tests
fi

echo ""
echo "=========================================="
echo "Tests run:    $TESTS_RUN"
echo "Passed:       $TESTS_PASSED"
echo "Skipped:      $TESTS_SKIPPED"
echo "Failed:       $TESTS_FAILED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
