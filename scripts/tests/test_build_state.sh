#!/usr/bin/env bash
# test_build_state.sh - Tests for src/build_state.sh
#
# Run: ./scripts/tests/test_build_state.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

pass() { ((TESTS_PASSED++)); echo "${GREEN}PASS${NC}: $1"; }
fail() { ((TESTS_FAILED++)); echo "${RED}FAIL${NC}: $1"; }

# Setup test environment
TEMP_DIR=$(mktemp -d)
export DSR_STATE_DIR="$TEMP_DIR/state"
DSR_RUN_ID="test-run-$(date +%s)-$$"
export DSR_RUN_ID

# Stub logging functions
log_info() { :; }
log_warn() { :; }
log_error() { echo "ERROR: $*" >&2; }
log_debug() { :; }
export -f log_info log_warn log_error log_debug

# Source the build_state module
source "$PROJECT_ROOT/src/build_state.sh"

# ============================================================================
# Lock Tests
# ============================================================================

test_build_lock_acquire() {
  ((TESTS_RUN++))
  build_state_init

  if build_lock_acquire "test-tool" "v1.0.0"; then
    pass "build_lock_acquire succeeds"
  else
    fail "build_lock_acquire should succeed"
  fi
  build_lock_release "test-tool" "v1.0.0"
}

test_build_lock_blocks_concurrent() {
  ((TESTS_RUN++))
  build_state_init

  build_lock_acquire "test-tool2" "v1.0.0" || true

  # Try to acquire same lock (should fail)
  if build_lock_acquire "test-tool2" "v1.0.0" 2>/dev/null; then
    fail "build_lock_acquire should fail for concurrent access"
    build_lock_release "test-tool2" "v1.0.0"
  else
    pass "build_lock_acquire blocks concurrent access"
  fi
  build_lock_release "test-tool2" "v1.0.0"
}

test_build_lock_release() {
  ((TESTS_RUN++))
  build_state_init

  build_lock_acquire "test-tool3" "v1.0.0" || true
  if build_lock_release "test-tool3" "v1.0.0"; then
    pass "build_lock_release succeeds"
  else
    fail "build_lock_release should succeed"
  fi
}

test_build_lock_check() {
  ((TESTS_RUN++))
  build_state_init

  # Should not be locked initially
  if build_lock_check "test-tool4" "v1.0.0"; then
    fail "build_lock_check should return false when not locked"
  else
    # Now acquire lock
    build_lock_acquire "test-tool4" "v1.0.0" || true
    if build_lock_check "test-tool4" "v1.0.0"; then
      pass "build_lock_check detects lock correctly"
    else
      fail "build_lock_check should detect lock"
    fi
    build_lock_release "test-tool4" "v1.0.0"
  fi
}

test_build_lock_info() {
  ((TESTS_RUN++))
  build_state_init

  build_lock_acquire "test-tool5" "v1.0.0" || true
  local info
  info=$(build_lock_info "test-tool5" "v1.0.0")

  if echo "$info" | jq -e '.locked == true' >/dev/null 2>&1; then
    pass "build_lock_info returns valid JSON"
  else
    fail "build_lock_info should return locked=true"
  fi
  build_lock_release "test-tool5" "v1.0.0"
}

# Real shell/process tests for the custody boundary. The Python path forces
# only flock discovery to be unavailable, exercising the production macOS
# fcntl fallback without substituting lock acquisition or release behavior.
test_build_lock_custody() {
  python3 - "$PROJECT_ROOT" "${1:-all}" <<'PY'
import errno
import fcntl
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import time

project = Path(sys.argv[1])
borrow_only = sys.argv[2] == 'borrow'
root = Path(tempfile.mkdtemp(prefix='dsr-build-custody-'))
print('Retained build custody fixture: ' + str(root), flush=True)
checks = 0


def check(label, value):
    global checks
    if not value:
        raise AssertionError(label)
    checks += 1
    print('PASS: ' + label, flush=True)


def until(predicate, seconds=12):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.02)
    raise AssertionError('fixture barrier timed out')


def inventory(path):
    if not path.exists():
        return None
    entries = []
    for item in sorted([path, *path.rglob('*')]):
        info = item.lstat()
        payload = (os.readlink(item) if stat.S_ISLNK(info.st_mode) else
                   item.read_bytes() if stat.S_ISREG(info.st_mode) else None)
        entries.append((str(item.relative_to(path)), info.st_dev, info.st_ino,
                        info.st_mode, info.st_nlink, info.st_size,
                        info.st_mtime_ns, info.st_ctime_ns, payload))
    return entries


def independently_free(path):
    # This observer opens a separate description in the Python controller;
    # none of the Bash owner's descriptors or registry are inherited here.
    with path.open('r+b') as stream:
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            if error.errno in (errno.EAGAIN, errno.EACCES):
                return False
            raise
    return True


driver = root / 'driver.sh'
driver.write_text(r'''#!/usr/bin/env bash
set -uo pipefail
log_info() { :; }; log_warn() { :; }; log_debug() { :; }
log_error() { printf '%s\n' "$*" >&2; }
# shellcheck source=src/build_state.sh
source "$MODULE" || exit 90
if [[ "$BACKEND" == python ]]; then
    command() {
        if [[ "${1:-}" == -v && "${2:-}" == flock ]]; then return 1; fi
        builtin command "$@"
    }
fi
registry_snapshot() {
    declare -p _BUILD_LOCK_PATHS _BUILD_LOCK_FDS _BUILD_LOCK_IDENTITIES \
        _BUILD_LOCK_OWNERS _BUILD_LOCK_RECORDS _BUILD_LOCK_REGISTRY_READY _BUILD_STATE_DIR
}
borrow_without_registry_changes() {
    local before status=0
    before=$(registry_snapshot) || return 110
    build_lock_borrow task v1 || status=$?
    [[ "$(registry_snapshot)" == "$before" ]] || return 111
    return "$status"
}
if [[ "$ACTION" == borrow-absent ]]; then
    # Exercise the no-registry path before initialization can create anything.
    borrow_without_registry_changes
    exit $?
fi
build_state_init || exit 91
barrier() {
    local deadline=$((SECONDS + 20))
    while [[ ! -f "$1" ]]; do
        ((SECONDS < deadline)) || return 1
        sleep 0.02
    done
}
participant() {
    local name="$1" status=0 owner
    printf '%s\n' "$BASHPID" > "$FIXTURE/$name.ready"
    barrier "$FIXTURE/start" || return 92
    build_lock_acquire task v1 || status=$?
    if [[ "$status" == 0 ]]; then
        read -r owner _ < "$DSR_STATE_DIR/builds/task/v1/.lock"
        [[ "$owner" == "$BASHPID" ]] || return 93
    fi
    printf '%s\n' "$status" > "$FIXTURE/$name.result"
    if [[ "$status" == 0 ]]; then
        barrier "$FIXTURE/release" || return 94
        build_lock_release task v1 || return 95
    fi
    return "$status"
}
case "$ACTION" in
    borrow-unregistered)
        borrow_without_registry_changes
        exit $?
        ;;
    borrow)
        build_lock_acquire task v1 || exit 112
        printf 'ready\n' > "$FIXTURE/owner.ready"
        barrier "$FIXTURE/start" || exit 113
        borrow_without_registry_changes || exit 114
        (
            borrow_without_registry_changes || exit 115
            status=0; build_lock_release task v1 || status=$?
            [[ "$status" == 1 ]] || exit 116
            printf 'ready\n' > "$FIXTURE/child.ready"
            barrier "$FIXTURE/release-child"
        ) & child=$!
        barrier "$FIXTURE/child.ready" || exit 117
        printf 'ready\n' > "$FIXTURE/borrow.ready"
        barrier "$FIXTURE/release-parent" || exit 118
        build_lock_release task v1 || exit 119
        printf 'ready\n' > "$FIXTURE/parent-released"
        wait "$child" || exit 120
        ;;
    borrow-fault)
        build_lock_acquire task v1 || exit 121
        descriptor=''
        for index in "${!_BUILD_LOCK_PATHS[@]}"; do
            if [[ "${_BUILD_LOCK_PATHS[$index]}" == "$DSR_STATE_DIR/builds/task/v1/.lock" ]]; then
                descriptor="${_BUILD_LOCK_FDS[$index]}"
                break
            fi
        done
        [[ "$descriptor" =~ ^[0-9]{1,3}$ ]] || exit 122
        case "$FAULT" in
            closed) _build_lock_close_fd "$descriptor" || exit 123 ;;
            reused-other)
                _build_lock_close_fd "$descriptor" || exit 123
                eval 'exec '"$descriptor"'<> "$FIXTURE/unrelated"' || exit 124
                printf 'caller:' >&"$descriptor" || exit 125
                ;;
            reopened-held)
                # Retain the genuine held description, but replace the
                # registered FD with an independent open of the SAME inode.
                exec 80<&"$descriptor" || exit 126
                _build_lock_close_fd "$descriptor" || exit 123
                eval 'exec '"$descriptor"'<> "$DSR_STATE_DIR/builds/task/v1/.lock.lease"' || exit 124
                ;;
            reopened-free)
                _build_lock_close_fd "$descriptor" || exit 123
                eval 'exec '"$descriptor"'<> "$DSR_STATE_DIR/builds/task/v1/.lock.lease"' || exit 124
                ;;
            unlocked)
                python3 - "$descriptor" <<'UNLOCK'
import fcntl, sys
fcntl.flock(int(sys.argv[1]), fcntl.LOCK_UN)
UNLOCK
                [[ "$?" == 0 ]] || exit 127
                ;;
        esac
        printf 'ready\n' > "$FIXTURE/holder.ready"
        barrier "$FIXTURE/start" || exit 128
        status=0; borrow_without_registry_changes || status=$?
        printf '%s\n' "$status" > "$FIXTURE/borrow.result"
        [[ "$status" == 4 ]] || exit 129
        if [[ "$FAULT" != closed ]]; then
            { : <&"$descriptor"; } || exit 130
        fi
        barrier "$FIXTURE/release" || exit 131
        case "$FAULT" in
            closed) ;;
            reused-other) printf 'after\n' >&"$descriptor" || exit 132 ;;
            reopened-held)
                eval 'exec '"$descriptor"'<&80' || exit 133
                exec 80>&-
                build_lock_release task v1 || exit 134
                ;;
            *) build_lock_release task v1 || exit 134 ;;
        esac
        ;;
    basic)
        exec 10<> "$FIXTURE/caller-a" 11<> "$FIXTURE/caller-b"
        printf 'first:' >&10; printf 'second:' >&11
        build_lock_acquire one v1 && build_lock_acquire two v1 || exit 96
        status=0; build_lock_acquire one v1 || status=$?
        [[ "$status" == 2 ]] && build_lock_check one v1 || exit 97
        # A loader re-source must preserve both namespace and descriptor registry.
        loader() {
            # shellcheck source=src/build_state.sh
            source "$MODULE"
        }
        loader || exit 98
        status=0; (build_lock_release one v1) || status=$?
        [[ "$status" == 1 ]] && build_lock_check one v1 || exit 99
        (printf '%s\n' "$BASHPID" > "$FIXTURE/child.ready";
         barrier "$FIXTURE/release") & child=$!
        barrier "$FIXTURE/child.ready" || exit 100
        build_lock_release one v1 && build_lock_release two v1 || exit 101
        # Closing this shell's copies cannot unlock the child's description.
        build_lock_check one v1 && build_lock_check two v1 || exit 102
        printf 'ready\n' > "$FIXTURE/parent-released"
        wait "$child" || exit 103
        if build_lock_check one v1 || build_lock_check two v1; then exit 104; fi
        build_lock_release one v1 || exit 105
        build_lock_acquire one v1 && build_lock_release one v1 || exit 106
        printf 'after\n' >&10; printf 'after\n' >&11
        [[ "$(cat "$FIXTURE/caller-a")" == first:after &&
           "$(cat "$FIXTURE/caller-b")" == second:after ]] || exit 107
        ;;
    compete) participant "$NAME"; exit $? ;;
    siblings)
        participant sibling-a & first=$!
        participant sibling-b & second=$!
        wait "$first" || true
        wait "$second" || true
        ;;
    acquire) build_lock_acquire "${TOOL:-task}" v1; exit $? ;;
    inspect) build_lock_info "${TOOL:-task}" v1 ;;
    hold)
        build_lock_acquire task v1 || exit 108
        printf 'ready\n' > "$FIXTURE/holder.ready"
        barrier "$FIXTURE/release" || exit 109
        # Identity-tampering cases intentionally cannot claim an explicit release.
        build_lock_release task v1
        ;;
esac
''')


def environment(case, backend, action, **extra):
    return dict(os.environ, DSR_STATE_DIR=str(case / 'state'), DSR_RUN_ID='custody-fixture',
                MODULE=os.environ.get('DSR_TEST_BUILD_STATE', str(project / 'src/build_state.sh')),
                FIXTURE=str(case),
                BACKEND=backend, ACTION=action, **extra)


def run(case, backend, action, **extra):
    return subprocess.run(['bash', str(driver)], env=environment(case, backend, action, **extra),
                          stdin=subprocess.DEVNULL, capture_output=True, timeout=10)


for backend in ('flock', 'python'):
    case = root / (backend + '-borrow-absent')
    case.mkdir()
    absent = run(case, backend, 'borrow-absent')
    check(case.name + ': no registry returns 1 without initializing a namespace',
          absent.returncode == 1 and not (case / 'state').exists())

    case = root / (backend + '-borrow')
    case.mkdir()
    with open(case / 'stdout', 'wb') as out, open(case / 'stderr', 'wb') as err:
        owner = subprocess.Popen(['bash', str(driver)], env=environment(case, backend, 'borrow'),
                                 stdin=subprocess.DEVNULL, stdout=out, stderr=err)
        try:
            until(lambda: (case / 'owner.ready').exists() or owner.poll() is not None)
            check(case.name + ': genuine owner acquired custody',
                  (case / 'owner.ready').exists() and owner.poll() is None)
            before = inventory(case / 'state')
            unregistered = run(case, backend, 'borrow-unregistered')
            check(case.name + ': a busy pathname alone cannot grant borrowing',
                  unregistered.returncode == 1 and inventory(case / 'state') == before)
            (case / 'start').write_text('continue\n')
            until(lambda: (case / 'borrow.ready').exists() or owner.poll() is not None)
            check(case.name + ': owning shell and inherited child borrow without changing custody',
                  (case / 'borrow.ready').exists() and owner.poll() is None and
                  inventory(case / 'state') == before)
            lease = case / 'state/builds/task/v1/.lock.lease'
            check(case.name + ': independent acquisition stays excluded after borrowing',
                  not independently_free(lease) and run(case, backend, 'acquire').returncode == 2)
            (case / 'release-parent').write_text('continue\n')
            until(lambda: (case / 'parent-released').exists() or owner.poll() is not None)
            check(case.name + ': acquiring parent remains releasable while borrowed child retains exclusion',
                  (case / 'parent-released').exists() and owner.poll() is None and
                  not independently_free(lease) and inventory(case / 'state') == before)
        finally:
            for name in ('start', 'release-parent', 'release-child'):
                (case / name).write_text('continue\n')
            owner.wait(timeout=10)
        check(case.name + ': final borrower exit frees custody for another owner',
              owner.returncode == 0 and independently_free(lease) and
              run(case, backend, 'acquire').returncode == 0)

    for fault in ('metadata-changed', 'metadata-replaced', 'lease-replaced',
                  'closed', 'reused-other', 'reopened-free', 'reopened-held', 'unlocked'):
        case = root / (backend + '-borrow-' + fault)
        case.mkdir()
        namespace = case / 'state/builds/task/v1'
        metadata, lease = namespace / '.lock', namespace / '.lock.lease'
        retained = namespace / '.retained-original'
        with open(case / 'stdout', 'wb') as out, open(case / 'stderr', 'wb') as err:
            owner = subprocess.Popen(['bash', str(driver)],
                env=environment(case, backend, 'borrow-fault', FAULT=fault),
                stdin=subprocess.DEVNULL, stdout=out, stderr=err)
            original = None
            try:
                until(lambda: (case / 'holder.ready').exists() or owner.poll() is not None)
                check(case.name + ': genuine descriptor fault fixture is ready',
                      (case / 'holder.ready').exists() and owner.poll() is None)
                if fault in ('metadata-changed', 'metadata-replaced'):
                    original = metadata.read_bytes()
                    fields = original.decode().split()
                    fields[2] = 'different-run'
                    if fault == 'metadata-replaced':
                        metadata.rename(retained)
                    metadata.write_text(' '.join(fields) + '\n')
                elif fault == 'lease-replaced':
                    lease.rename(retained)
                    lease.touch()
                before = inventory(case / 'state')
                (case / 'start').write_text('continue\n')
                until(lambda: (case / 'borrow.result').exists() or owner.poll() is not None)
                check(case.name + ': unverifiable custody returns 4 without rewriting evidence or registry',
                      (case / 'borrow.result').read_text().strip() == '4' and
                      owner.poll() is None and inventory(case / 'state') == before)
                held = fault in ('metadata-changed', 'metadata-replaced', 'reopened-held')
                check(case.name + ': refusal preserves the actual kernel lease state',
                      independently_free(lease) == (not held) and
                      (fault != 'lease-replaced' or not independently_free(retained)) and
                      (fault != 'reused-other' or independently_free(case / 'unrelated')))
            finally:
                if original is not None:
                    if fault == 'metadata-replaced':
                        metadata.rename(namespace / '.retained-replacement')
                        retained.rename(metadata)
                    else:
                        metadata.write_bytes(original)
                elif fault == 'lease-replaced' and retained.exists():
                    lease.rename(namespace / '.retained-replacement')
                    retained.rename(lease)
                for name in ('start', 'release'):
                    (case / name).write_text('continue\n')
                owner.wait(timeout=10)
            check(case.name + ': refusal leaves caller descriptors and original release responsibility intact',
                  owner.returncode == 0 and independently_free(lease) and
                  (fault != 'reused-other' or (case / 'unrelated').read_text() == 'caller:after\n'))

    if borrow_only:
        continue
    case = root / (backend + '-basic')
    case.mkdir()
    with open(case / 'stdout', 'wb') as out, open(case / 'stderr', 'wb') as err:
        owner = subprocess.Popen(['bash', str(driver)], env=environment(case, backend, 'basic'),
                                 stdin=subprocess.DEVNULL, stdout=out, stderr=err)
        try:
            until(lambda: (case / 'parent-released').exists() or owner.poll() is not None)
            check(backend + ': distinct locks, same-shell refusal, re-source and child ownership checks pass',
                  (case / 'parent-released').exists() and owner.poll() is None)
            for tool in ('one', 'two'):
                probe = run(case, backend, 'acquire', TOOL=tool)
                info = run(case, backend, 'inspect', TOOL=tool)
                check(backend + ': inherited child keeps ' + tool + ' excluded after owner release',
                      probe.returncode == 2 and info.returncode == 0 and
                      json.loads(info.stdout)['custody'] == 'held')
        finally:
            (case / 'release').write_text('continue\n')
            if owner.poll() is None:
                owner.wait(timeout=10)
        check(backend + ': final descendant close allows reacquisition and preserves caller descriptors',
              owner.returncode == 0 and (case / 'caller-a').read_text() == 'first:after\n' and
              (case / 'caller-b').read_text() == 'second:after\n')
        free = run(case, backend, 'inspect', TOOL='one')
        check(backend + ': retained valid metadata reports free custody after release',
              free.returncode == 0 and json.loads(free.stdout)['locked'] is False and
              (case / 'state/builds/one/v1/.lock.lease').is_file())

    for sibling in (False, True):
        case = root / (backend + ('-siblings' if sibling else '-independent'))
        case.mkdir()
        names = ['sibling-a', 'sibling-b'] if sibling else ['process-%d' % i for i in range(8)]
        processes = []
        streams = []
        try:
            for name in (['parent'] if sibling else names):
                stream = open(case / (name + '.log'), 'wb')
                streams.append(stream)
                processes.append(subprocess.Popen(['bash', str(driver)],
                    env=environment(case, backend, 'siblings' if sibling else 'compete', NAME=name),
                    stdin=subprocess.DEVNULL, stdout=stream, stderr=stream))
            until(lambda: all((case / (name + '.ready')).exists() for name in names))
            (case / 'start').write_text('continue\n')
            until(lambda: all((case / (name + '.result')).exists() for name in names))
            results = {name: int((case / (name + '.result')).read_text()) for name in names}
            check(case.name + ': exactly one simultaneous independent owner is admitted',
                  list(results.values()).count(0) == 1 and list(results.values()).count(2) == len(names) - 1)
            winner = next(name for name in names if results[name] == 0)
            pid = int((case / (winner + '.ready')).read_text())
            metadata = (case / 'state/builds/task/v1/.lock').read_text()
            check(case.name + ': metadata identifies the actual acquiring process',
                  int(metadata.split()[0]) == pid and
                  (not sibling or pid != processes[0].pid))
        finally:
            (case / 'release').write_text('continue\n')
            for process in processes:
                process.wait(timeout=10)
            for stream in streams:
                stream.close()

    for kind in ('legacy', 'malformed', 'linked-lease', 'linked-metadata', 'missing-lease', 'replaced-lease'):
        case = root / (backend + '-' + kind)
        namespace = case / 'state/builds/task/v1'
        namespace.mkdir(parents=True)
        metadata, lease = namespace / '.lock', namespace / '.lock.lease'
        victim = case / 'victim'
        victim.write_text('retained independent bytes\n')
        owner = None
        out = err = None
        try:
            if kind == 'legacy':
                metadata.write_text('999999 0 legacy-run\n')
            elif kind == 'malformed':
                lease.touch()
                metadata.write_text('invalid custody\n')
            elif kind == 'linked-lease':
                lease.symlink_to(victim)
            elif kind == 'linked-metadata':
                metadata.symlink_to(victim)
            else:
                out, err = open(case / 'stdout', 'wb'), open(case / 'stderr', 'wb')
                owner = subprocess.Popen(['bash', str(driver)], env=environment(case, backend, 'hold'),
                                         stdin=subprocess.DEVNULL, stdout=out, stderr=err)
                until(lambda: (case / 'holder.ready').exists())
                lease.rename(namespace / '.retained-original-lease')
                if kind == 'replaced-lease':
                    lease.touch()
            before = metadata.read_bytes() if metadata.exists() else None
            refused = run(case, backend, 'acquire')
            info = run(case, backend, 'inspect')
            check(case.name + ': unsafe or legacy custody refuses admission and reports locked',
                  refused.returncode == 1 and info.returncode == 0 and
                  json.loads(info.stdout)['locked'] is True and
                  json.loads(info.stdout)['custody'] == 'unverifiable')
            check(case.name + ': refusal preserves existing metadata and unrelated bytes',
                  victim.read_text() == 'retained independent bytes\n' and
                  (before is None or metadata.read_bytes() == before))
        finally:
            if owner is not None:
                (case / 'release').write_text('continue\n')
                owner.wait(timeout=10)
                out.close(); err.close()

print('Build custody: %d checks passed' % checks, flush=True)
PY
}

# ============================================================================
# State Tests
# ============================================================================

test_build_state_create() {
  ((TESTS_RUN++))
  build_state_init

  local run_id
  run_id=$(build_state_create "ntm" "v1.2.3" "linux/amd64,darwin/arm64")

  if [[ -n "$run_id" && "$run_id" =~ ^(test-)?run- ]]; then
    pass "build_state_create returns run_id"
  else
    fail "build_state_create should return run_id, got: $run_id"
  fi
}

test_build_state_rejects_run_collision() {
  ((TESTS_RUN++))
  build_state_init

  local first_state second_status=0
  build_state_create "collision-tool" "v1.0.0" "linux/amd64" >/dev/null
  first_state=$(build_state_get "collision-tool" "v1.0.0" "$DSR_RUN_ID")
  build_state_create "collision-tool" "v1.0.0" "darwin/arm64" >/dev/null 2>&1 || second_status=$?

  if [[ "$second_status" -ne 0 ]] &&
     [[ "$(build_state_get "collision-tool" "v1.0.0" "$DSR_RUN_ID")" == "$first_state" ]]; then
    pass "build_state_create preserves an existing immutable run namespace"
  else
    fail "build_state_create should reject a run ID collision without changing state"
  fi
}

test_build_state_get() {
  ((TESTS_RUN++))
  build_state_init

  build_state_create "ntm2" "v1.0.0" "linux/amd64" >/dev/null
  local state
  state=$(build_state_get "ntm2" "v1.0.0" "latest")

  if echo "$state" | jq -e '.tool == "ntm2"' >/dev/null 2>&1; then
    pass "build_state_get returns valid state"
  else
    fail "build_state_get should return tool name in state"
  fi
}

test_build_state_update_status() {
  ((TESTS_RUN++))
  build_state_init

  build_state_create "ntm3" "v1.0.0" "" >/dev/null
  build_state_update_status "ntm3" "v1.0.0" "running"

  local state
  state=$(build_state_get "ntm3" "v1.0.0" "latest")

  if echo "$state" | jq -e '.status == "running"' >/dev/null 2>&1; then
    pass "build_state_update_status updates status"
  else
    fail "build_state_update_status should update status"
  fi
}

test_build_state_update_preserves_private_mode() {
  ((TESTS_RUN++))
  build_state_init

  local run_id workspace state_file old_umask mode
  run_id=$(build_state_create "private-mode-tool" "v1.0.0" "linux/amd64")
  workspace=$(build_state_workspace "private-mode-tool" "v1.0.0" "$run_id")
  state_file="$workspace/state.json"
  old_umask=$(umask)
  umask 000
  build_state_update_status "private-mode-tool" "v1.0.0" "running" "$run_id"
  umask "$old_umask"
  mode=$(stat -c '%a' "$state_file" 2>/dev/null || stat -f '%Lp' "$state_file" 2>/dev/null)

  if [[ "$mode" == "600" ]]; then
    pass "atomic state updates retain mode 0600 under a permissive caller umask"
  else
    fail "atomic state update mode should be 600, got: $mode"
  fi
}

test_build_state_update_host() {
  ((TESTS_RUN++))
  build_state_init

  build_state_create "ntm4" "v1.0.0" "linux/amd64" >/dev/null
  build_state_update_host "ntm4" "v1.0.0" "trj" "running"
  build_state_update_host "ntm4" "v1.0.0" "trj" "completed" '{"duration_ms": 5000}'

  local state
  state=$(build_state_get "ntm4" "v1.0.0" "latest")

  if echo "$state" | jq -e '.hosts.trj.status == "completed"' >/dev/null 2>&1; then
    if echo "$state" | jq -e '.hosts.trj.duration_ms == 5000' >/dev/null 2>&1; then
      pass "build_state_update_host updates host with extra data"
    else
      fail "build_state_update_host should preserve extra data"
    fi
  else
    fail "build_state_update_host should update host status"
  fi
}

test_build_state_add_artifact() {
  ((TESTS_RUN++))
  build_state_init

  build_state_create "ntm5" "v1.0.0" "" >/dev/null
  build_state_add_artifact "ntm5" "v1.0.0" "ntm-linux-amd64" "/tmp/artifact" "abc123"

  local state
  state=$(build_state_get "ntm5" "v1.0.0" "latest")

  if echo "$state" | jq -e '.artifacts | length > 0' >/dev/null 2>&1; then
    pass "build_state_add_artifact adds artifact"
  else
    fail "build_state_add_artifact should add artifact"
  fi
}

# ============================================================================
# Resume Tests
# ============================================================================

test_build_state_can_resume() {
  ((TESTS_RUN++))
  build_state_init

  build_state_create "ntm6" "v1.0.0" "" >/dev/null
  build_state_update_status "ntm6" "v1.0.0" "failed"

  if build_state_can_resume "ntm6" "v1.0.0"; then
    pass "build_state_can_resume returns true for failed build"
  else
    fail "build_state_can_resume should return true for failed"
  fi

  ((TESTS_RUN++))
  build_state_update_status "ntm6" "v1.0.0" "completed"
  if build_state_can_resume "ntm6" "v1.0.0"; then
    fail "build_state_can_resume should return false for completed"
  else
    pass "build_state_can_resume returns false for completed"
  fi
}

test_build_state_completed_hosts() {
  ((TESTS_RUN++))
  build_state_init

  build_state_create "ntm7" "v1.0.0" "trj,mmini" >/dev/null
  build_state_update_host "ntm7" "v1.0.0" "trj" "completed"
  build_state_update_host "ntm7" "v1.0.0" "mmini" "failed"

  local completed
  completed=$(build_state_completed_hosts "ntm7" "v1.0.0")

  if [[ "$completed" == "trj" ]]; then
    pass "build_state_completed_hosts returns completed hosts"
  else
    fail "build_state_completed_hosts should return trj, got: $completed"
  fi
}

# ============================================================================
# Workspace Tests
# ============================================================================

test_build_state_workspace() {
  ((TESTS_RUN++))
  build_state_init

  local run_id
  run_id=$(build_state_create "ntm8" "v1.0.0" "")

  local workspace
  workspace=$(build_state_workspace "ntm8" "v1.0.0" "$run_id")

  if [[ -d "$workspace" && "$workspace" == *"$run_id"* ]]; then
    pass "build_state_workspace returns valid directory"
  else
    fail "build_state_workspace should return valid directory, got: $workspace"
  fi
}

test_build_state_artifacts_dir() {
  ((TESTS_RUN++))
  build_state_init

  build_state_create "ntm9" "v1.0.0" "" >/dev/null

  local artifacts_dir
  artifacts_dir=$(build_state_artifacts_dir "ntm9" "v1.0.0")

  if [[ -d "$artifacts_dir" && "$artifacts_dir" == */artifacts ]]; then
    pass "build_state_artifacts_dir returns valid directory"
  else
    fail "build_state_artifacts_dir should return valid directory"
  fi
}

test_build_state_list() {
  ((TESTS_RUN++))
  build_state_init

  # Create multiple builds with unique run IDs
  DSR_RUN_ID="run-$(date +%s)-1" build_state_create "ntm10" "v1.0.0" "" >/dev/null
  sleep 0.1
  DSR_RUN_ID="run-$(date +%s)-2" build_state_create "ntm10" "v1.0.0" "" >/dev/null

  local builds
  builds=$(build_state_list "ntm10" "v1.0.0" | wc -l)

  if [[ "$builds" -ge 2 ]]; then
    pass "build_state_list returns all builds"
  else
    fail "build_state_list should return at least 2 builds, got: $builds"
  fi
}

# ============================================================================
# Retry and Recovery Tests
# ============================================================================

test_build_retry_backoff_calculation() {
  ((TESTS_RUN++))

  local delay0 delay1 delay2
  delay0=$(_build_calc_backoff 0)
  delay1=$(_build_calc_backoff 1)
  delay2=$(_build_calc_backoff 2)

  # Exponential: base * 2^attempt (default base=5)
  # delay0 ~= 5, delay1 ~= 10, delay2 ~= 20 (plus jitter)
  if [[ "$delay1" -ge "$delay0" && "$delay2" -ge "$delay1" ]]; then
    pass "_build_calc_backoff increases exponentially"
  else
    fail "_build_calc_backoff: delays should increase (got $delay0, $delay1, $delay2)"
  fi
}

test_build_retry_with_backoff_success() {
  ((TESTS_RUN++))

  local attempt_count=0
  test_cmd() { ((attempt_count++)); return 0; }
  export -f test_cmd

  if build_retry_with_backoff 3 test_cmd; then
    if [[ "$attempt_count" -eq 1 ]]; then
      pass "build_retry_with_backoff succeeds on first try"
    else
      fail "build_retry_with_backoff: expected 1 attempt, got $attempt_count"
    fi
  else
    fail "build_retry_with_backoff should succeed"
  fi
}

test_build_retry_with_backoff_failure() {
  ((TESTS_RUN++))

  # Override retry settings for faster test
  BUILD_RETRY_BASE_DELAY=0

  if ! build_retry_with_backoff 2 false 2>/dev/null; then
    pass "build_retry_with_backoff fails after max attempts"
  else
    fail "build_retry_with_backoff should fail"
  fi

  BUILD_RETRY_BASE_DELAY=5
}

test_build_state_record_retry() {
  ((TESTS_RUN++))
  build_state_init

  build_state_create "retry-tool1" "v1.0.0" "trj" >/dev/null
  build_state_update_host "retry-tool1" "v1.0.0" "trj" "running"
  build_state_record_retry "retry-tool1" "v1.0.0" "trj" 1 "connection timeout"

  local state
  state=$(build_state_get "retry-tool1" "v1.0.0")

  if echo "$state" | jq -e '.hosts.trj.retry_count == 1' >/dev/null 2>&1; then
    if echo "$state" | jq -e '.hosts.trj.last_error == "connection timeout"' >/dev/null 2>&1; then
      pass "build_state_record_retry records attempt and error"
    else
      fail "build_state_record_retry should record error message"
    fi
  else
    fail "build_state_record_retry should increment retry_count"
  fi
}

test_build_state_get_retry_count() {
  ((TESTS_RUN++))
  build_state_init

  build_state_create "retry-tool2" "v1.0.0" "trj" >/dev/null
  build_state_update_host "retry-tool2" "v1.0.0" "trj" "running"

  local count
  count=$(build_state_get_retry_count "retry-tool2" "v1.0.0" "trj")

  if [[ "$count" -eq 0 ]]; then
    # Now add a retry
    build_state_record_retry "retry-tool2" "v1.0.0" "trj" 1 "error"
    count=$(build_state_get_retry_count "retry-tool2" "v1.0.0" "trj")
    if [[ "$count" -eq 1 ]]; then
      pass "build_state_get_retry_count returns correct count"
    else
      fail "build_state_get_retry_count should return 1, got: $count"
    fi
  else
    fail "build_state_get_retry_count should return 0 initially"
  fi
}

test_build_state_can_retry() {
  ((TESTS_RUN++))
  build_state_init

  # Override max retries for test
  BUILD_RETRY_MAX=2

  build_state_create "retry-tool3" "v1.0.0" "trj" >/dev/null
  build_state_update_host "retry-tool3" "v1.0.0" "trj" "running"

  # Should be able to retry initially
  if build_state_can_retry "retry-tool3" "v1.0.0" "trj"; then
    # Add retries up to limit
    build_state_record_retry "retry-tool3" "v1.0.0" "trj" 1 "error"
    build_state_record_retry "retry-tool3" "v1.0.0" "trj" 2 "error"

    # Should not be able to retry now
    if ! build_state_can_retry "retry-tool3" "v1.0.0" "trj"; then
      pass "build_state_can_retry respects retry limit"
    else
      fail "build_state_can_retry should return false after max retries"
    fi
  else
    fail "build_state_can_retry should return true initially"
  fi

  BUILD_RETRY_MAX=3
}

test_build_state_resume() {
  ((TESTS_RUN++))
  build_state_init

  build_state_create "resume-tool" "v1.0.0" "trj,mmini,wlap" >/dev/null
  build_state_update_status "resume-tool" "v1.0.0" "running"
  build_state_update_host "resume-tool" "v1.0.0" "trj" "completed"
  build_state_update_host "resume-tool" "v1.0.0" "mmini" "failed"
  # wlap is still pending

  local resume_plan
  resume_plan=$(build_state_resume "resume-tool" "v1.0.0")

  if echo "$resume_plan" | jq -e '.can_resume == true' >/dev/null 2>&1; then
    local hosts_to_process
    hosts_to_process=$(echo "$resume_plan" | jq -r '.hosts_to_process | length')
    # Should process wlap (pending) and mmini (failed, retryable)
    if [[ "$hosts_to_process" -ge 1 ]]; then
      pass "build_state_resume generates valid resume plan"
    else
      fail "build_state_resume should identify hosts to process"
    fi
  else
    fail "build_state_resume should return can_resume=true"
  fi
}

test_build_state_exec_with_retry() {
  ((TESTS_RUN++))
  build_state_init

  # Override settings for faster test
  BUILD_RETRY_MAX=2
  BUILD_RETRY_BASE_DELAY=0

  build_state_create "exec-tool" "v1.0.0" "trj" >/dev/null

  # Test with command that succeeds
  if build_state_exec_with_retry "exec-tool" "v1.0.0" "trj" true 2>/dev/null; then
    local state
    state=$(build_state_get "exec-tool" "v1.0.0")
    if echo "$state" | jq -e '.hosts.trj.status == "completed"' >/dev/null 2>&1; then
      pass "build_state_exec_with_retry marks host completed on success"
    else
      fail "build_state_exec_with_retry should mark host as completed"
    fi
  else
    fail "build_state_exec_with_retry should succeed with true command"
  fi

  # shellcheck disable=SC2034  # These are used by sourced build_state.sh
  BUILD_RETRY_MAX=3
  # shellcheck disable=SC2034
  BUILD_RETRY_BASE_DELAY=5
}

# Checkpoint transactions use real concurrent processes and files. Only the
# command boundary is replaced for deterministic write-failure/crash injection.
run_state_regression() {
  local name="$1"
  shift
  ((TESTS_RUN++))
  if ( "$@" ); then
    pass "$name"
  else
    fail "$name"
  fi
}

test_checkpoint_validation() {
  local dir="$TEMP_DIR/checkpoint-validation" filter before source status
  mkdir "$dir" || return 1
  source="$dir/state.json"
  before='{"run_id":"fixed","counter":0}'
  for filter in 'empty' '., .' '[]' 'null' 'true' '"text"' 'error("injected")' \
    '.run_id = "other"'; do
    printf '%s\n' "$before" > "$source"
    status=0
    _build_state_jq_update "$source" "$filter" 2>/dev/null || status=$?
    [[ $status -ne 0 && "$(cat "$source")" == "$before" ]] || return 1
  done
  for before in '' '{} {}' '[]' 'null' '{broken'; do
    printf '%s' "$before" > "$source"
    status=0
    _build_state_jq_update "$source" '{counter:1}' 2>/dev/null || status=$?
    [[ $status -ne 0 && "$(cat "$source")" == "$before" ]] || return 1
  done
  [[ -z "$(find "$dir" -mindepth 1 -type d -print)" ]]
}

test_checkpoint_foreign_temp_preserved() {
  local source="$TEMP_DIR/foreign-temp-state.json"
  printf '{"counter":0}\n' > "$source"
  printf 'another writer owns these bytes\n' > "$source.tmp.$$"
  _build_state_jq_update "$source" '.counter += 1' || return 1
  [[ "$(cat "$source.tmp.$$")" == 'another writer owns these bytes' ]] &&
    jq -e '.counter == 1' "$source" >/dev/null
}

test_checkpoint_descriptor_identity() {
  local source="$TEMP_DIR/descriptor-state.json" lock_identity
  printf '{"counter":0}\n' > "$source"
  : > "$source.update.lock"
  exec 9<> "$source.update.lock" || return 1
  lock_identity=$(_build_state_fd_identity 9) || return 1
  [[ "$lock_identity" == "$(_build_state_file_identity "$source.update.lock")" ]] || return 1
  mv "$source.update.lock" "$source.original-lock" || return 1
  : > "$source.update.lock"
  [[ "$lock_identity" == "$(_build_state_fd_identity 9)" ]] || return 1
  [[ "$lock_identity" != "$(_build_state_file_identity "$source.update.lock")" ]] || return 1
  exec 9>&-
  ! _build_state_fd_identity invalid 2>/dev/null
}

test_checkpoint_replaced_lock_rejected() {
  local source="$TEMP_DIR/replaced-lock-state.json" status=0
  printf '{"counter":0}\n' > "$source"
  _build_state_wait_lock() {
    mv "$source.update.lock" "$source.original-lock" || return 1
    : > "$source.update.lock"
  }
  _build_state_jq_update "$source" '.counter = 1' 2>/dev/null || status=$?
  [[ $status -ne 0 ]] && jq -e '.counter == 0' "$source" >/dev/null
}

test_checkpoint_concurrent_increments() {
  local source="$TEMP_DIR/concurrent-state.json" _worker _iteration pid result=0
  local -a pids=()
  printf '{"counter":0}\n' > "$source"
  for _worker in 1 2 3 4 5 6 7 8; do
    (
      for _iteration in 1 2 3 4 5 6; do
        _build_state_jq_update "$source" '.counter += 1' || exit 1
      done
    ) &
    pids+=("$!")
  done
  for pid in "${pids[@]}"; do wait "$pid" || result=1; done
  [[ $result -eq 0 ]] && jq -e '.counter == 48' "$source" >/dev/null
}

test_checkpoint_symlinks_rejected() {
  local original="$TEMP_DIR/symlink-original.json" source="$TEMP_DIR/symlink-state.json"
  printf '{"counter":0}\n' > "$original"
  ln -s "$original" "$source" || return 1
  ! _build_state_jq_update "$source" '.counter = 1' || return 1
  [[ -L "$source" ]] && jq -e '.counter == 0' "$original" >/dev/null || return 1
  source="$TEMP_DIR/symlink-lock-state.json"
  printf '{"counter":0}\n' > "$source"
  ln -s "$original" "$source.update.lock" || return 1
  ! _build_state_jq_update "$source" '.counter = 1' || return 1
  [[ -L "$source.update.lock" ]] && jq -e '.counter == 0' "$original" "$source" >/dev/null
}

test_checkpoint_publication_failure() {
  local source="$TEMP_DIR/failed-publication.json"
  printf '{"counter":0}\n' > "$source"
  mv() { return 1; }
  ! _build_state_jq_update "$source" '.counter = 1' || return 1
  unset -f mv
  jq -e '.counter == 0' "$source" >/dev/null || return 1
  _build_state_jq_update "$source" '.counter = 2' &&
    jq -e '.counter == 2' "$source" >/dev/null
}

test_checkpoint_external_write_detected() {
  local source="$TEMP_DIR/external-write.json" status=0
  printf '{"counter":0}\n' > "$source"
  jq() {
    if [[ "${1:-}" == '.counter = 99' ]]; then
      printf '{"counter":17}\n' > "$source"
    fi
    command jq "$@"
  }
  _build_state_jq_update "$source" '.counter = 99' 2>/dev/null || status=$?
  unset -f jq
  [[ $status -ne 0 ]] && jq -e '.counter == 17' "$source" >/dev/null
}

test_checkpoint_caller_scope_preserved() {
  local source="$TEMP_DIR/caller-scope.json" before after old_umask mode
  printf '{"counter":0}\n' > "$source"
  trap ':' INT TERM
  before=$(trap -p INT TERM)
  old_umask=$(umask)
  umask 000
  _build_state_jq_update "$source" '.counter = 1' || return 1
  [[ "$(umask)" == 0000 ]] || return 1
  umask "$old_umask"
  after=$(trap -p INT TERM)
  mode=$(stat -c %a "$source" 2>/dev/null || stat -f %Lp "$source")
  [[ "$before" == "$after" && "$mode" == 600 ]]
}

test_checkpoint_timeout_and_independent_files() {
  local label="${1:-native}"
  local source="$TEMP_DIR/$label-locked-state.json" other="$TEMP_DIR/$label-independent-state.json"
  local ready="$TEMP_DIR/$label-update-lock-ready" stop="$TEMP_DIR/$label-update-lock-stop"
  local pid _step status=0 result=0
  printf '{"counter":0}\n' > "$source"
  printf '{"counter":0}\n' > "$other"
  : > "$source.update.lock"
  (
    exec 9<> "$source.update.lock" || exit 1
    _build_state_wait_lock 9 1 || exit 1
    : > "$ready"
    for _step in {1..500}; do
      [[ -e "$stop" ]] && exit 0
      sleep 0.01
    done
    exit 1
  ) &
  pid=$!
  for _step in {1..300}; do [[ -e "$ready" ]] && break; sleep 0.01; done
  [[ -e "$ready" ]] || result=1
  DSR_STATE_LOCK_TIMEOUT=0 _build_state_jq_update "$source" '.counter = 1' \
    2>/dev/null || status=$?
  [[ $status -ne 0 ]] || result=1
  jq -e '.counter == 0' "$source" >/dev/null || result=1
  DSR_STATE_LOCK_TIMEOUT=0 _build_state_jq_update "$other" '.counter = 1' || result=1
  : > "$stop"
  wait "$pid" || result=1
  _build_state_jq_update "$source" '.counter = 2' || result=1
  [[ $result -eq 0 ]] && jq -e '.counter == 2' "$source" >/dev/null
}

test_checkpoint_crash_recovery() {
  local source="$TEMP_DIR/crashed-writer.json" status=0
  printf '{"counter":0}\n' > "$source"
  jq() {
    if [[ "${1:-}" == '.counter = 91' ]]; then
      # This is the isolated update subshell, never the caller/test runner.
      kill -KILL "$BASHPID"
    fi
    command jq "$@"
  }
  _build_state_jq_update "$source" '.counter = 91' 2>/dev/null || status=$?
  unset -f jq
  [[ $status -ne 0 ]] && jq -e '.counter == 0' "$source" >/dev/null || return 1
  DSR_STATE_LOCK_TIMEOUT=0 _build_state_jq_update "$source" '.counter = 1' &&
    jq -e '.counter == 1' "$source" >/dev/null
}

test_checkpoint_python_lock_backend() {
  command -v python3 >/dev/null || return 1
  # Hide only flock discovery; use the actual standard-library fallback and
  # actual inherited descriptors, not a mock lock implementation.
  command() {
    if [[ "$#" -eq 2 && "$1" == -v && "$2" == flock ]]; then return 1; fi
    builtin command "$@"
  }
  test_checkpoint_timeout_and_independent_files python
}

test_checkpoint_lock_config() {
  local source="$TEMP_DIR/invalid-lock-timeout.json" value
  printf '{"counter":0}\n' > "$source"
  for value in -1 1.5 nope 3601 99999; do
    ! DSR_STATE_LOCK_TIMEOUT="$value" _build_state_jq_update "$source" '.counter = 1' \
      2>/dev/null || return 1
  done
  DSR_STATE_LOCK_TIMEOUT=0000 _build_state_jq_update "$source" '.counter = 2' &&
    jq -e '.counter == 2' "$source" >/dev/null
}

# Resume/retry tests use actual checkpoints. Every fixture has a separate tool
# namespace so the suite can exercise latest-pointer changes without cross-talk.
seed_resume_fixture() {
  local tool="$1" targets="${2:-linux/amd64,darwin/arm64}"
  build_state_init || return 1
  DSR_RUN_ID="${tool}-run" build_state_create "$tool" v1.0.0 "$targets" >/dev/null || return 1
  RESUME_STATE_FILE="$_BUILD_STATE_DIR/$tool/v1.0.0/${tool}-run/state.json"
}

test_state_read_identity_and_shape() {
  seed_resume_fixture read-identity || return 1
  local before filter invalid output status
  before=$(cat "$RESUME_STATE_FILE")
  for filter in '.tool = "other"' '.version = "v9.0.0"' '.run_id = "other"' \
    '., .' '[]' 'null'; do
    jq "$filter" <<< "$before" > "$RESUME_STATE_FILE" || return 1
    status=0
    output=$(build_state_get read-identity v1.0.0 2>/dev/null) || status=$?
    [[ $status -ne 0 && -z "$output" ]] || return 1
  done
  for invalid in '' '{broken'; do
    printf '%s' "$invalid" > "$RESUME_STATE_FILE"
    ! build_state_get read-identity v1.0.0 >/dev/null 2>&1 || return 1
  done
  printf '%s\n' "$before" > "$RESUME_STATE_FILE"
  [[ "$(build_state_get read-identity v1.0.0)" == "$before" ]] || return 1
  ! build_state_get ../read-identity v1.0.0 >/dev/null 2>&1 || return 1
  ! build_state_get read-identity v1.0.0 ../outside >/dev/null 2>&1 || return 1
  mv "$RESUME_STATE_FILE" "$RESUME_STATE_FILE.saved" || return 1
  ln -s "$RESUME_STATE_FILE.saved" "$RESUME_STATE_FILE" || return 1
  ! build_state_get read-identity v1.0.0 >/dev/null 2>&1
}

test_resume_unknown_status_rejected() {
  seed_resume_fixture unknown-status || return 1
  local status plan code
  for status in completed cancelled unknown null; do
    _build_state_jq_update "$RESUME_STATE_FILE" --arg status "$status" '.status = $status' || return 1
    ! build_state_can_resume unknown-status v1.0.0 || return 1
    code=0
    plan=$(build_state_resume unknown-status v1.0.0 2>/dev/null) || code=$?
    [[ $code -ne 0 ]] && jq -es 'length == 1 and .[0].can_resume == false' \
      <<< "$plan" >/dev/null || return 1
  done
  for status in created running failed; do
    _build_state_jq_update "$RESUME_STATE_FILE" --arg status "$status" '.status = $status' || return 1
    build_state_can_resume unknown-status v1.0.0 || return 1
  done
  _build_state_jq_update "$RESUME_STATE_FILE" 'del(.status)' || return 1
  ! build_state_can_resume unknown-status v1.0.0
}

test_state_evidence_rejection() {
  seed_resume_fixture bad-evidence || return 1
  local evidence before
  before=$(cat "$RESUME_STATE_FILE")
  for evidence in '[]' 'null' 'true' '42' '{} {}' '{broken'; do
    ! build_state_update_host bad-evidence v1.0.0 trj completed "$evidence" \
      2>/dev/null || return 1
    ! build_state_update_target bad-evidence v1.0.0 linux/amd64 completed "$evidence" \
      2>/dev/null || return 1
    [[ "$(cat "$RESUME_STATE_FILE")" == "$before" ]] || return 1
  done
}

test_resume_single_snapshot_after_latest_moves() {
  seed_resume_fixture moving-latest linux/amd64 || return 1
  local first_state="$RESUME_STATE_FILE" second_state calls="$TEMP_DIR/resume-read.calls"
  _build_state_jq_update "$first_state" '
    .hosts = {trj:{status:"failed",retry_count:1}} |
    .context = {target_hosts:{"linux/amd64":"trj"}, marker:"first"} |
    .target_statuses["linux/amd64"] = {status:"failed",attempts:1}' || return 1
  DSR_RUN_ID=second-run build_state_create moving-latest v1.0.0 darwin/arm64 >/dev/null || return 1
  second_state="$_BUILD_STATE_DIR/moving-latest/v1.0.0/second-run/state.json"
  _build_state_jq_update "$second_state" '
    .hosts = {mmini:{status:"completed"}} | .context = {marker:"second"}' || return 1
  ln -sfn moving-latest-run "$_BUILD_STATE_DIR/moving-latest/v1.0.0/latest"
  # Load the real reader in a subshell, preserving this observation wrapper
  # without evaluating a rewritten function body. Move latest after the read.
  build_state_get() {
    local value
    value=$(
      # shellcheck source=../../src/build_state.sh
      source "$PROJECT_ROOT/src/build_state.sh"
      build_state_init || exit 1
      build_state_get "$@"
    ) || return 1
    printf 'read\n' >> "$calls"
    ln -sfn second-run "$_BUILD_STATE_DIR/moving-latest/v1.0.0/latest"
    printf '%s\n' "$value"
  }
  local plan
  plan=$(build_state_resume moving-latest v1.0.0) || return 1
  [[ "$(wc -l < "$calls")" -eq 1 ]] || return 1
  jq -e '.run_id == "moving-latest-run" and .context.marker == "first" and
    .failed_hosts == ["trj"] and .hosts_to_process == ["trj"] and
    .completed_hosts == [] and .targets_to_process == ["linux/amd64"]' <<< "$plan" >/dev/null
}

test_resume_host_routing_and_target_evidence() {
  seed_resume_fixture route-plan linux/amd64,darwin/arm64,windows/amd64 || return 1
  _build_state_jq_update "$RESUME_STATE_FILE" '
    .context.target_hosts = {"linux/amd64":"trj","darwin/arm64":"mmini","windows/amd64":"wlap"} |
    .hosts = {trj:{status:"completed"},mmini:{status:"running",retry_count:1}} |
    .target_statuses = {
      "linux/amd64":{status:"completed",attempts:1,result:{artifact:"candidate"}},
      "darwin/arm64":{status:"completed",attempts:1,result:{}},
      "windows/amd64":{status:"running",attempts:3}}' || return 1
  local plan pending completed
  plan=$(build_state_resume route-plan v1.0.0) || return 1
  pending=$(build_state_pending_hosts route-plan v1.0.0) || return 1
  completed=$(build_state_completed_targets route-plan v1.0.0) || return 1
  [[ "$pending" == $'mmini\nwlap' && "$completed" == linux/amd64 ]] || return 1
  jq -e '.completed_hosts == ["trj"] and .hosts_to_process == ["mmini","wlap"] and
    .completed_targets == ["linux/amd64"] and .targets_to_process == ["darwin/arm64"] and
    .exceeded_target_retry_limit == ["windows/amd64"]' <<< "$plan" >/dev/null || return 1
  seed_resume_fixture legacy-hosts trj,mmini,wlap || return 1
  build_state_update_host legacy-hosts v1.0.0 trj completed || return 1
  [[ "$(build_state_pending_hosts legacy-hosts v1.0.0)" == $'mmini\nwlap' ]]
}

test_resume_rejects_malformed_inventory() {
  seed_resume_fixture bad-plan || return 1
  local original filter status plan
  original=$(cat "$RESUME_STATE_FILE")
  for filter in '.targets = ["linux/amd64","linux/amd64"]' '.targets = null' \
    '.targets = [1]' '.hosts = []' '.hosts.trj = false' \
    '.hosts.trj = {status:"failed",retry_count:-1}' \
    '.hosts.trj = {status:"failed",retry_count:"0"}' \
    '.hosts.trj = {status:"running",retry_count:null}' \
    '.hosts.trj = {status:"mystery"}' '.target_statuses["linux/amd64"].attempts = 1.5' \
    '.target_statuses["linux/amd64"].attempts = false' '.target_statuses.other = {}' \
    '.target_statuses["linux/amd64"].source_sync_failures = -1' \
    '.target_statuses["linux/amd64"].source_sync_failures = "0"' \
    '.target_statuses["linux/amd64"].source_sync_failures = 1.5' \
    '.target_statuses["linux/amd64"].source_sync_failures = 99' \
    '.target_statuses["linux/amd64"].host_readiness_failures = -1' \
    '.target_statuses["linux/amd64"].host_readiness_failures = "0"' \
    '.target_statuses["linux/amd64"].host_readiness_failures = null' \
    '.target_statuses["linux/amd64"].host_readiness_failures = 1.5' \
    '.target_statuses["linux/amd64"].host_readiness_failures = 99' \
    '.target_statuses["linux/amd64"].host_capacity_failures = -1' \
    '.target_statuses["linux/amd64"].host_capacity_failures = "0"' \
    '.target_statuses["linux/amd64"].host_capacity_failures = null' \
    '.target_statuses["linux/amd64"].host_capacity_failures = false' \
    '.target_statuses["linux/amd64"].host_capacity_failures = 1.5' \
    '.target_statuses["linux/amd64"].host_capacity_failures = 99' \
    '.target_statuses["linux/amd64"] |= . + {attempts:3,source_sync_failures:2,host_readiness_failures:2}' \
    '.target_statuses["linux/amd64"] |= . + {attempts:3,source_sync_failures:1,host_readiness_failures:1,host_capacity_failures:2}' \
    '.context = []' '.context.target_hosts = {"linux/amd64":null}'; do
    jq "$filter" <<< "$original" > "$RESUME_STATE_FILE" || return 1
    status=0
    plan=$(build_state_resume bad-plan v1.0.0 2>/dev/null) || status=$?
    [[ $status -ne 0 ]] && jq -es 'length == 1 and .[0].can_resume == false' \
      <<< "$plan" >/dev/null || return 1
  done
}

test_retry_budget_validation() {
  local marker="$TEMP_DIR/invalid-retry-command" value status
  retry_command() { : > "$marker"; }
  for value in 0 -1 1.5 nope 1001; do
    status=0
    build_retry_with_backoff "$value" retry_command 2>/dev/null || status=$?
    [[ $status -eq 4 && ! -e "$marker" ]] || return 1
  done
  ! build_retry_with_backoff 2 '' 2>/dev/null || return 1
  status=0
  BUILD_RETRY_BASE_DELAY=0 build_retry_with_backoff 02 bash -c 'exit 17' \
    2>/dev/null || status=$?
  [[ $status -eq 17 ]]
}

test_retry_backoff_is_bounded() {
  local BUILD_RETRY_MAX=3 BUILD_RETRY_BASE_DELAY=5 BUILD_RETRY_MAX_DELAY=7
  local attempt _iteration delay
  for attempt in 0 1 2 63 64 1000; do
    for _iteration in 1 2 3 4 5 6 7 8; do
      delay=$(_build_calc_backoff "$attempt") || return 1
      [[ "$delay" =~ ^[0-9]+$ ]] && ((delay <= 7)) || return 1
    done
  done
  BUILD_RETRY_BASE_DELAY=0
  [[ "$(_build_calc_backoff 1000)" == 0 ]] || return 1
  BUILD_RETRY_BASE_DELAY=00005 BUILD_RETRY_MAX_DELAY=00000
  [[ "$(_build_calc_backoff 0001)" == 0 ]] || return 1
  BUILD_RETRY_BASE_DELAY=-1
  ! _build_calc_backoff 1 2>/dev/null
}

test_retry_unreadable_budget_blocks_execution() {
  seed_resume_fixture bad-budget || return 1
  local original value status marker="$TEMP_DIR/bad-budget-command"
  original=$(cat "$RESUME_STATE_FILE")
  retry_command() { : > "$marker"; }
  ! build_state_can_retry missing-tool v1.0.0 trj 2>/dev/null || return 1
  for value in null false '"0"' -1 1.5; do
    jq --argjson value "$value" '.hosts.trj = {status:"failed",retry_count:$value}' \
      <<< "$original" > "$RESUME_STATE_FILE" || return 1
    ! build_state_can_retry bad-budget v1.0.0 trj 2>/dev/null || return 1
    status=0
    build_state_exec_with_retry bad-budget v1.0.0 trj retry_command 2>/dev/null || status=$?
    [[ $status -ne 0 && ! -e "$marker" ]] || return 1
  done
  for value in null false '[]' '"invalid"'; do
    jq --argjson value "$value" '.hosts.trj = $value' \
      <<< "$original" > "$RESUME_STATE_FILE" || return 1
    ! build_state_can_retry bad-budget v1.0.0 trj 2>/dev/null || return 1
    status=0
    build_state_exec_with_retry bad-budget v1.0.0 trj retry_command 2>/dev/null || status=$?
    [[ $status -ne 0 && ! -e "$marker" ]] || return 1
  done
}

test_retry_preserves_exit_code_and_saved_budget() {
  seed_resume_fixture saved-budget trj || return 1
  _build_state_jq_update "$RESUME_STATE_FILE" '.hosts.trj = {status:"failed",retry_count:2}' || return 1
  local BUILD_RETRY_MAX=3 BUILD_RETRY_BASE_DELAY=0
  local marker="$TEMP_DIR/saved-budget-command" status=0
  retry_command() { printf 'attempt\n' >> "$marker"; return 17; }
  build_state_exec_with_retry saved-budget v1.0.0 trj retry_command 2>/dev/null || status=$?
  [[ $status -ne 0 && "$(wc -l < "$marker")" -eq 1 ]] || return 1
  jq -e '.hosts.trj.status == "failed" and .hosts.trj.retry_count == 3 and
    .hosts.trj.exit_code == 17 and .hosts.trj.retries[0].attempt == 3 and
    .hosts.trj.retries[0].error == "exit code 17"' "$RESUME_STATE_FILE" >/dev/null || return 1
  ! build_state_exec_with_retry saved-budget v1.0.0 trj retry_command 2>/dev/null || return 1
  [[ "$(wc -l < "$marker")" -eq 1 ]]
}

test_retry_success_and_failure_share_receipt() {
  seed_resume_fixture retry-success trj || return 1
  local BUILD_RETRY_MAX=3 BUILD_RETRY_BASE_DELAY=0 marker="$TEMP_DIR/retry-success-command"
  retry_command() {
    if [[ ! -e "$marker" ]]; then : > "$marker"; return 23; fi
    return 0
  }
  build_state_exec_with_retry retry-success v1.0.0 trj retry_command || return 1
  jq -e '.hosts.trj.status == "completed" and .hosts.trj.exit_code == 0 and
    .hosts.trj.retry_count == 0 and .hosts.trj.attempts_started == 2 and
    .hosts.trj.active_attempt == null and .hosts.trj.retries[0].exit_code == 23' \
    "$RESUME_STATE_FILE" >/dev/null
}

test_retry_reservation_failure_prevents_command() {
  seed_resume_fixture reservation-failure trj || return 1
  local marker="$TEMP_DIR/reservation-command" status=0
  retry_command() { : > "$marker"; }
  _build_state_jq_update() { return 1; }
  build_state_exec_with_retry reservation-failure v1.0.0 trj retry_command || status=$?
  [[ $status -ne 0 && ! -e "$marker" ]]
}

test_retry_receipt_failure_stops_execution() {
  local code tool marker status
  local BUILD_RETRY_BASE_DELAY=0
  for code in 0 17; do
    tool="receipt-failure-$code"
    seed_resume_fixture "$tool" trj || return 1
    marker="$TEMP_DIR/$tool-command"
    retry_command() { printf 'attempt\n' >> "$marker"; return "$code"; }
    mv() {
      [[ ! -e "$marker" ]] || return 1
      command mv "$@"
    }
    status=0
    build_state_exec_with_retry "$tool" v1.0.0 trj retry_command 2>/dev/null || status=$?
    unset -f mv
    [[ $status -ne 0 && "$(wc -l < "$marker")" -eq 1 ]] || return 1
    jq -e '.hosts.trj.status == "running" and .hosts.trj.retry_count == 1' \
      "$RESUME_STATE_FILE" >/dev/null || return 1
  done
}

test_retry_pins_run_when_latest_moves() {
  seed_resume_fixture retry-latest trj || return 1
  local first="$RESUME_STATE_FILE" second before
  DSR_RUN_ID=second-run build_state_create retry-latest v1.0.0 mmini >/dev/null || return 1
  second="$_BUILD_STATE_DIR/retry-latest/v1.0.0/second-run/state.json"
  before=$(cat "$second")
  ln -sfn retry-latest-run "$_BUILD_STATE_DIR/retry-latest/v1.0.0/latest"
  retry_command() {
    ln -sfn second-run "$_BUILD_STATE_DIR/retry-latest/v1.0.0/latest"
  }
  build_state_exec_with_retry retry-latest v1.0.0 trj retry_command || return 1
  [[ "$(cat "$second")" == "$before" ]] &&
    jq -e '.hosts.trj.status == "completed" and .hosts.trj.exit_code == 0' "$first" >/dev/null
}

test_retry_interruption_is_not_retried() {
  local code tool marker status
  local BUILD_RETRY_BASE_DELAY=0
  for code in 5 130 143; do
    tool="retry-interrupted-$code"
    seed_resume_fixture "$tool" trj || return 1
    marker="$TEMP_DIR/$tool-command"
    retry_command() { printf 'attempt\n' >> "$marker"; return "$code"; }
    status=0
    build_state_exec_with_retry "$tool" v1.0.0 trj retry_command 2>/dev/null || status=$?
    [[ $status -eq 5 && "$(wc -l < "$marker")" -eq 1 ]] || return 1
    jq -e --argjson code "$code" '.hosts.trj.status == "cancelled" and
      .hosts.trj.exit_code == $code and .hosts.trj.retry_count == 1' "$RESUME_STATE_FILE" \
      >/dev/null || return 1
  done
}

test_retry_host_execution_lock() {
  seed_resume_fixture host-execution trj,mmini || return 1
  local ready="$TEMP_DIR/host-execution-ready" stop="$TEMP_DIR/host-execution-stop"
  local forbidden="$TEMP_DIR/host-execution-duplicate" pid _step status=0 result=0
  slow_command() {
    : > "$ready"
    for _step in {1..1000}; do [[ -e "$stop" ]] && return 0; sleep 0.01; done
    return 19
  }
  duplicate_command() { : > "$forbidden"; }
  build_state_exec_with_retry host-execution v1.0.0 trj slow_command &
  pid=$!
  for _step in {1..500}; do [[ -e "$ready" ]] && break; sleep 0.01; done
  [[ -e "$ready" ]] || result=1
  build_state_exec_with_retry host-execution v1.0.0 trj duplicate_command \
    2>/dev/null || status=$?
  [[ $status -eq 2 && ! -e "$forbidden" ]] || result=1
  build_state_exec_with_retry host-execution v1.0.0 mmini true || result=1
  : > "$stop"
  wait "$pid" || result=1
  [[ $result -eq 0 ]] && jq -e '.hosts.trj.status == "completed" and
    .hosts.mmini.status == "completed"' "$RESUME_STATE_FILE" >/dev/null
}

test_retry_crash_consumes_reserved_attempt() {
  seed_resume_fixture retry-crash trj || return 1
  local status=0 marker="$TEMP_DIR/retry-crash-command" BUILD_RETRY_MAX=1
  crash_command() { kill -KILL "$BASHPID"; }
  retry_command() { : > "$marker"; }
  build_state_exec_with_retry retry-crash v1.0.0 trj crash_command \
    2>/dev/null || status=$?
  [[ $status -ne 0 ]] && jq -e '.hosts.trj.status == "running" and
    .hosts.trj.retry_count == 1' "$RESUME_STATE_FILE" >/dev/null || return 1
  ! build_state_exec_with_retry retry-crash v1.0.0 trj retry_command \
    2>/dev/null || return 1
  [[ ! -e "$marker" ]] || return 1
  BUILD_RETRY_MAX=2
  build_state_exec_with_retry retry-crash v1.0.0 trj retry_command || return 1
  [[ -e "$marker" ]] && jq -e '.hosts.trj.status == "completed" and
    .hosts.trj.attempts_started == 2' "$RESUME_STATE_FILE" >/dev/null
}

test_retry_record_failure_propagates() {
  seed_resume_fixture retry-record trj || return 1
  _build_state_jq_update() { return 1; }
  ! build_state_record_retry retry-record v1.0.0 trj 1 'failure'
}

test_native_matrix_resume_tasks() {
  local run_id plan tasks digest
  run_id=$(build_state_create matrix-state v1.0.0 linux/amd64) || return 1
  tasks='[{"key":"linux/amd64@x86_64-unknown-linux-gnu","platform":"linux/amd64","target_triple":"x86_64-unknown-linux-gnu","method":"native"},{"key":"linux/amd64@x86_64-unknown-linux-musl","platform":"linux/amd64","target_triple":"x86_64-unknown-linux-musl","method":"native"}]'
  digest=$(printf '%064d' 1)
  build_state_set_context matrix-state v1.0.0 "$run_id" '' '' '{}' '' 2 '{}' release \
    "$tasks" "$digest" || return 1
  build_state_update_target matrix-state v1.0.0 linux/amd64@x86_64-unknown-linux-gnu completed \
    '{"attempts":1,"result":{"status":"success","target_triple":"x86_64-unknown-linux-gnu"}}' "$run_id" || return 1
  build_state_update_target matrix-state v1.0.0 linux/amd64@x86_64-unknown-linux-musl failed \
    '{"attempts":1,"result":{"status":"failed"}}' "$run_id" || return 1
  build_state_update_status matrix-state v1.0.0 partial "$run_id" || return 1
  build_state_can_resume matrix-state v1.0.0 "$run_id" || return 1
  plan=$(build_state_resume matrix-state v1.0.0 "$run_id") || return 1
  jq -e '.completed_targets == ["linux/amd64@x86_64-unknown-linux-gnu"] and
    .targets_to_process == ["linux/amd64@x86_64-unknown-linux-musl"] and
    (.context.build_tasks | length) == 2' <<< "$plan" >/dev/null || return 1
  [[ "$(build_state_pending_targets matrix-state v1.0.0 "$run_id")" == \
    linux/amd64@x86_64-unknown-linux-musl ]] || return 1
  build_state_get matrix-state v1.0.0 "$run_id" | jq -e '
    .targets == ["linux/amd64"] and (.target_statuses | length) == 2' >/dev/null || return 1
  local state_file
  state_file="$(_build_get_tool_dir matrix-state v1.0.0)/$run_id/state.json"
  _build_state_jq_update "$state_file" '.context.build_tasks[1].key = .context.build_tasks[0].key' || return 1
  ! build_state_resume matrix-state v1.0.0 "$run_id" >/dev/null 2>&1
}

# State-layer proof only: real checkpoint transactions and coordinator leases,
# with explicit retained receipt/source fixtures. No compiler or remote host is
# substituted for a successful build; orchestration tests own those boundaries.
test_failed_variant_relocation_state() {
  python3 - "$PROJECT_ROOT" "$TEMP_DIR" <<'PY'
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

project, temporary = map(Path, sys.argv[1:])
work = temporary / 'variant-relocation'
work.mkdir()
checks = 0
gnu = 'linux/amd64@x86_64-unknown-linux-gnu'
musl = 'linux/amd64@x86_64-unknown-linux-musl'
windows = 'windows/amd64'
tool, version, run = 'variant-state', 'v1.0.0', 'retained-run'
digest = '1' * 64

def check(label, value, result=None):
    global checks
    if not value:
        if result is not None:
            print(result.stderr[-3000:], file=sys.stderr)
        raise AssertionError(label)
    checks += 1
    print('PASS: ' + label, flush=True)

def write(path, value):
    path.write_text(json.dumps(value) + '\n')

def read(path):
    return json.loads(path.read_text())

def fingerprint(path):
    info = path.stat()
    return (info.st_dev, info.st_ino, info.st_mode, info.st_mtime_ns,
            info.st_ctime_ns, path.read_bytes())

driver = work / 'driver.sh'
driver.write_text(r'''#!/usr/bin/env bash
set -uo pipefail
log_info() { :; }; log_warn() { :; }; log_debug() { :; }
log_error() { printf '%s\n' "$*" >&2; }
source "$PROJECT/src/guardrails.sh" || exit 90
source "$MODULE" || exit 91
build_state_init || exit 92
case "$1" in
  relocate|relocate_unframed)
    IFS= read -r before || exit 93
    IFS= read -r roots || exit 93
    IFS= read -r receipt || exit 93
    if [[ "$1" == relocate_unframed ]]; then
      roots="$roots"$'\n'"$receipt"
      receipt=""
    fi
    build_lock_acquire "$TOOL" "$VERSION" || exit 94
    status=0
    build_state_relocate_failed_target "$TOOL" "$VERSION" "$RUN" "$before" "$2" "$3" "$roots" "$receipt" || status=$?
    build_lock_release "$TOOL" "$VERSION" || exit 95
    exit "$status" ;;
  failed_attempt)
    extra=$(cat)
    build_state_update_target "$TOOL" "$VERSION" "$2" failed "$extra" "$RUN" ;;
  project) state=$(cat); build_state_effective_task_hosts "$state" ;;
  authority) state=$(cat); build_state_validate_task_host_overrides "$state" ;;
  resume) build_state_resume "$TOOL" "$VERSION" "$RUN" ;;
  pending) build_state_pending_hosts "$TOOL" "$VERSION" "$RUN" ;;
esac
''')

def call(case, action, *args, documents=(), budget=3):
    env = dict(os.environ, PROJECT=str(project), CASE=str(case), TOOL=tool,
               VERSION=version, RUN=run, DSR_STATE_DIR=str(case / 'state'),
               DSR_RETRY_MAX=str(budget),
               MODULE=os.environ.get('DSR_TEST_BUILD_STATE_MODULE', str(project / 'src/build_state.sh')))
    return subprocess.run(['bash', str(driver), action, *args], env=env,
                          input=''.join(json.dumps(item) + '\n' for item in documents),
                          capture_output=True, text=True, timeout=15)

def state_path(case):
    return case / 'state/builds' / tool / version / run / 'state.json'

def fixture(name, failed=(musl,)):
    case = work / name
    path = state_path(case)
    path.parent.mkdir(parents=True)
    tasks = [dict(key=gnu, platform='linux/amd64', target_triple='x86_64-unknown-linux-gnu', method='native'),
             dict(key=musl, platform='linux/amd64', target_triple='x86_64-unknown-linux-musl', method='native'),
             dict(key=windows, platform=windows, target_triple='x86_64-pc-windows-msvc', method='native')]
    entries = {}
    for index, task in enumerate(tasks):
        payload, log, receipt = (case / (str(index) + suffix) for suffix in ('.payload', '.log', '.json'))
        payload.write_bytes(('retained bytes for ' + task['key']).encode())
        log.write_text('retained worker log\n')
        outcome = dict(status='failed' if task['key'] in failed else 'success',
                       platform=task['platform'], task_key=task['key'], target_triple=task['target_triple'],
                       host='stable' if task['key'] == windows else 'original',
                       build_purpose='release', publishable=True, artifact_path=str(payload),
                       sha256=hashlib.sha256(payload.read_bytes()).hexdigest())
        write(receipt, outcome)
        entries[task['key']] = dict(status='failed' if task['key'] in failed else 'completed',
                                   attempts=5 if task['key'] == musl else 1, result=outcome,
                                   log_path=str(log), result_path=str(receipt))
        if task['key'] == musl:
            entries[task['key']].update(source_sync_failures=1, host_readiness_failures=1, host_capacity_failures=1)
    state = dict(tool=tool, version=version, run_id=run, status='partial',
                 created_at='2026-01-01T00:00:00Z', updated_at='2026-01-01T00:00:00Z',
                 git_sha='a' * 40, git_ref=version, targets=['linux/amd64', windows],
                 hosts={'original': {'status':'failed', 'retry_count':0}}, target_statuses=entries,
                 context=dict(build_purpose='release', publishable=True, build_tasks=tasks,
                              native_matrix_config_sha256=digest, source_sync=None, parallel_jobs=2,
                              output_dir=str(case / 'output'),
                              target_hosts={'linux/amd64':'original', windows:'stable'},
                              source_roots={host:str(case / 'sources' / host) for host in ('original','stable')}))
    write(path, state)
    path.chmod(0o600)
    return case, state

def admission(case, before, key=musl, host='replacement', config_hash=None, host_platform=None):
    context = before['context']
    task = next(row for row in context['build_tasks'] if row['key'] == key)
    old = context.get('task_host_overrides', {}).get(key, context['target_hosts'][task['platform']])
    config_hash = config_hash or context['native_matrix_config_sha256']
    root = context['source_roots'].get(host, str(case / 'sources' / host))
    prior = before['target_statuses'][key]
    approval = dict(run_id=run, target=key, new_host=host,
                    prior_repo_config_sha256=context['native_matrix_config_sha256'],
                    repo_config_sha256=config_hash, hosts_config_sha256='2' * 64)
    receipt = dict(target=key, task_key=key, platform=task['platform'], target_triple=task['target_triple'],
                   old_host=old, new_host=host, new_host_platform=host_platform or task['platform'],
                   git_sha=before['git_sha'], git_ref=before['git_ref'], prior_target=copy.deepcopy(prior),
                   prior_context=copy.deepcopy(context), approval=approval,
                   repo_config_sha256=config_hash, hosts_config_sha256='2' * 64,
                   prior_result_sha256=hashlib.sha256(Path(prior['result_path']).read_bytes()).hexdigest(),
                   prior_log_sha256=hashlib.sha256(Path(prior['log_path']).read_bytes()).hexdigest(),
                   verified_source_sync=dict(status='success', failed=0,
                       target_hosts={task['platform']:host}, source_roots={host:root}),
                   verified_source_inventory=[dict(path='source', git_sha=before['git_sha'],
                       archive_sha256='3' * 64, manifest_sha256='4' * 64)])
    effective = {row['key']:context.get('task_host_overrides', {}).get(row['key'], context['target_hosts'][row['platform']])
                 for row in context['build_tasks']}
    effective[key] = host
    roots = dict(context['source_roots'], **{host:root})
    roots = {name:value for name,value in roots.items() if name in effective.values()}
    return roots, receipt

def relocate(case, before, key=musl, host='replacement', **options):
    roots, receipt = admission(case, before, key, host, **options)
    result = call(case, 'relocate', key, host, documents=(before, roots, receipt))
    check('approved relocation commits ' + key + ' to ' + host, result.returncode == 0, result)
    after = read(state_path(case))
    check('approved history is valid after ' + host,
          call(case, 'authority', documents=(after,)).returncode == 0)
    return after

case, before = fixture('qualified')
evidence = {path:fingerprint(path) for path in case.iterdir() if path.is_file()}
after = relocate(case, before)
check('qualified move preserves platform map, ordered inventory, all attempts and successful siblings',
      after['context']['target_hosts'] == before['context']['target_hosts'] and
      after['context']['build_tasks'] == before['context']['build_tasks'] and
      after['context']['native_matrix_config_sha256'] == digest and
      after['target_statuses'] == before['target_statuses'] and
      after['context']['task_host_overrides'] == {musl:'replacement'} and
      all(fingerprint(path) == saved for path,saved in evidence.items()))
plan = call(case, 'resume', budget=2)
check('relocation cannot refund the two consumed compiler attempts', plan.returncode == 0 and
      json.loads(plan.stdout)['exceeded_target_retry_limit'] == [musl] and
      json.loads(plan.stdout)['targets_to_process'] == [], plan)
plan = call(case, 'resume', budget=3)
check('remaining budget resumes only the failed exact task', plan.returncode == 0 and
      json.loads(plan.stdout)['targets_to_process'] == [musl], plan)
retry = copy.deepcopy(after['target_statuses'][musl])
retry['attempts'] += 1
retry['result']['host'] = 'replacement'
retry['result_path'] = str(case / 'replacement-attempt.json')
retry['log_path'] = str(case / 'replacement-attempt.log')
write(Path(retry['result_path']), retry['result'])
Path(retry['log_path']).write_text('replacement compiler failed\n')
recorded = call(case, 'failed_attempt', musl, documents=(retry,))
check('repeated relocation follows a retained failed attempt on the current replacement',
      recorded.returncode == 0, recorded)
failed_replacement = read(state_path(case))
again = relocate(case, failed_replacement, host='second')
check('repeated move retains both approvals and only removes the unused replacement source root',
      len(again['relocations']) == 2 and again['relocations'][1]['old_host'] == 'replacement' and
      set(again['context']['source_roots']) == {'original','stable','second'} and
      again['target_statuses'] == failed_replacement['target_statuses'] and
      all(fingerprint(path) == saved for path,saved in evidence.items()))
plan = call(case, 'resume', budget=3)
check('a second move preserves the additional consumed compiler attempt', plan.returncode == 0 and
      json.loads(plan.stdout)['exceeded_target_retry_limit'] == [musl], plan)

for label, mutate in (
    ('missing history', lambda s:s.pop('relocations')),
    ('removed override', lambda s:s['context'].pop('task_host_overrides')),
    ('null override', lambda s:s['context'].__setitem__('task_host_overrides', None)),
    ('forged already-staged route', lambda s:s['context']['task_host_overrides'].__setitem__(musl, 'original')),
    ('reordered history', lambda s:s['relocations'].reverse()),
    ('unapproved destination', lambda s:s['relocations'][-1]['approval'].__setitem__('new_host', 'original')),
    ('contradictory failed host', lambda s:s['relocations'][-1]['prior_target']['result'].__setitem__('host', 'original')),
    ('changed retained source', lambda s:s['context']['source_roots'].__setitem__('original', '/changed'))):
    forged = copy.deepcopy(again); mutate(forged); write(state_path(case), forged)
    saved = fingerprint(state_path(case))
    result = call(case, 'resume')
    check('ordinary resume refuses ' + label + ' without rewriting custody',
          result.returncode != 0 and fingerprint(state_path(case)) == saved, result)
write(state_path(case), before)
roots, receipt = admission(case, before)
saved = fingerprint(state_path(case))
unframed = call(case, 'relocate_unframed', musl, 'replacement', documents=(before, roots, receipt))
check('each streamed relocation argument must contain exactly one document',
      unframed.returncode != 0 and fingerprint(state_path(case)) == saved, unframed)

for label, mutate in (
    ('stale snapshot', lambda b,r,p:b.__setitem__('updated_at', 'stale')),
    ('wrong failed receipt', lambda b,r,p:p['prior_target'].__setitem__('attempts', 0)),
    ('changed recipe', lambda b,r,p:(p.__setitem__('repo_config_sha256', '5'*64), p['approval'].__setitem__('repo_config_sha256', '5'*64))),
    ('wrong source pin', lambda b,r,p:p.__setitem__('git_sha', 'b'*40)),
    ('missing successful sibling root', lambda b,r,p:r.pop('original')),
    ('replaced successful sibling root', lambda b,r,p:r.__setitem__('original', '/changed')),
    ('cross-platform qualified host', lambda b,r,p:p.__setitem__('new_host_platform', 'darwin/arm64'))):
    saved = fingerprint(state_path(case)); selected = copy.deepcopy(before)
    roots, receipt = admission(case, selected); mutate(selected, roots, receipt)
    result = call(case, 'relocate', musl, 'replacement', documents=(selected, roots, receipt))
    check('atomic relocation refuses ' + label, result.returncode != 0 and fingerprint(state_path(case)) == saved, result)

projected = call(case, 'project', documents=({'context':before['context']},))
check('initial projection needs context only', projected.returncode == 0 and
      json.loads(projected.stdout) == {gnu:'original', musl:'original', windows:'stable'}, projected)
singleton = copy.deepcopy(before); singleton['context']['build_tasks'][2]['target_triple'] += '+native'
check('singleton backend compiler identity retains plus support', call(case, 'project', documents=(singleton,)).returncode == 0)
for label, mutate in (
    ('explicit null', lambda s:s['context'].__setitem__('task_host_overrides', None)),
    ('unknown task', lambda s:s['context'].__setitem__('task_host_overrides', {'linux/amd64@unknown':'replacement'})),
    ('bare platform', lambda s:s['context'].__setitem__('task_host_overrides', {'linux/amd64':'replacement'})),
    ('missing platform host', lambda s:s['context']['target_hosts'].pop(windows)),
    ('qualified act task', lambda s:s['context']['build_tasks'][0].__setitem__('method', 'act'))):
    invalid = copy.deepcopy(before); mutate(invalid)
    check('projection refuses ' + label, call(case, 'project', documents=(invalid,)).returncode != 0)
for triple in ('x86_64-unknown-linux-gnu+extra', 'x86_64..gnu', '_x86_64-unknown-linux-gnu'):
    invalid = copy.deepcopy(before)
    invalid['context']['build_tasks'][0].update(target_triple=triple, key='linux/amd64@'+triple)
    check('projection follows configured triple rules for ' + triple, call(case, 'project', documents=(invalid,)).returncode != 0)

for order in ('singleton-first', 'qualified-first'):
    mixed, state = fixture(order, failed=(musl, windows))
    steps = [(windows, 'cross', dict(config_hash='6'*64, host_platform='linux/amd64')),
             (musl, 'replacement', {})]
    if order == 'qualified-first':steps.reverse()
    for key, host, options in steps:state = relocate(mixed, state, key, host, **options)
    check(order + ' preserves singleton cross-build policy and qualified recipe custody',
          state['context']['task_host_overrides'] == {musl:'replacement'} and
          state['context']['target_hosts'][windows] == 'cross' and
          state['context']['native_matrix_config_sha256'] == '6'*64)

retired, state = fixture('all-variants-moved', failed=(gnu, musl))
state = relocate(retired, state, gnu, 'first')
state = relocate(retired, state, musl, 'second')
plan, pending = call(retired, 'resume'), call(retired, 'pending')
check('unused platform default is absent from processing lists and source roots',
      plan.returncode == 0 and pending.returncode == 0 and
      'original' not in json.loads(plan.stdout)['hosts_to_process'] and
      'original' not in pending.stdout.splitlines() and
      'original' not in state['context']['source_roots'] and 'original' in state['hosts'])

large, state = fixture('large-receipts')
state['target_statuses'][musl]['result']['captured_output'] = 'retained compiler metadata\n' * 8192
write(Path(state['target_statuses'][musl]['result_path']), state['target_statuses'][musl]['result'])
write(state_path(large), state)
_, proof = admission(large, state)
check('large state and relocation receipt each exceed one Linux argv string',
      len(json.dumps(state).encode()) > 131072 and len(json.dumps(proof).encode()) > 131072)
after = relocate(large, state)
check('streamed compare-and-swap preserves large failed receipts without truncation',
      after['target_statuses'] == state['target_statuses'] and
      after['relocations'][0]['prior_target'] == state['target_statuses'][musl])
print(json.dumps(dict(checks=checks, passed=True, fixtures=str(work))), flush=True)
PY
}

test_source_sync_context_refresh() {
  local run_id partial repaired roots hosts before after
  run_id=$(build_state_create sync-context v1.0.0 linux/amd64,linux/arm64) || return 1
  hosts='{"linux/amd64":"healthy","linux/arm64":"offline"}'
  roots='{"healthy":"/work/healthy"}'
  partial=$(jq -nc --argjson hosts "$hosts" --argjson roots "$roots" '
    {status:"partial",synced:1,failed:1,target_hosts:$hosts,source_roots:$roots,
     hosts:[{host:"healthy",path:"/work/healthy",status:"success"},
       {host:"offline",path:"/work/offline",status:"failed",error:"disconnected"}]}') || return 1
  build_state_set_context sync-context v1.0.0 "$run_id" commit main "$roots" /output 2 \
    "$hosts" release '' '' "$partial" || return 1
  build_state_update_target sync-context v1.0.0 linux/amd64 completed \
    '{"attempts":1,"result":{"status":"success","artifact_path":"/output/retained"}}' "$run_id" || return 1
  build_state_update_status sync-context v1.0.0 partial "$run_id" || return 1
  before=$(build_state_get sync-context v1.0.0 "$run_id") || return 1
  roots='{"healthy":"/work/healthy","offline":"/work/offline"}'
  repaired=$(jq -c --argjson roots "$roots" '
    .status = "success" | .synced = 2 | .failed = 0 | .source_roots = $roots |
    .hosts[1].status = "success" | del(.hosts[1].error)' <<< "$partial") || return 1
  if build_state_set_source_sync sync-context v1.0.0 "$run_id" "$repaired" '{}' "$hosts" \
      2>/dev/null; then return 1; fi
  [[ "$(build_state_get sync-context v1.0.0 "$run_id")" == "$before" ]] || return 1
  build_state_set_source_sync sync-context v1.0.0 "$run_id" "$repaired" "$roots" "$hosts" || return 1
  after=$(build_state_get sync-context v1.0.0 "$run_id") || return 1
  jq -en --argjson before "$before" --argjson after "$after" --argjson repaired "$repaired" '
    $after.context.source_sync == $repaired and
    $after.target_statuses == $before.target_statuses and
    $after.context.output_dir == $before.context.output_dir and
    ($after.source_sync_history | length) == 2 and
    $after.source_sync_history[0].receipt == $before.context.source_sync and
    $after.source_sync_history[1].receipt == $repaired' >/dev/null || return 1
  build_state_set_source_sync sync-context v1.0.0 "$run_id" null "$roots" "$hosts" || return 1
  build_state_get sync-context v1.0.0 "$run_id" | jq -e --argjson roots "$roots" --argjson hosts "$hosts" '
    .context.source_sync == null and .context.source_roots == $roots and
    .context.target_hosts == $hosts and (.source_sync_history | length) == 3 and
    .source_sync_history[-1].receipt == null and .target_statuses["linux/amd64"].attempts == 1' \
    >/dev/null || return 1
  build_state_update_status sync-context v1.0.0 completed "$run_id" || return 1
  before=$(build_state_get sync-context v1.0.0 "$run_id") || return 1
  if build_state_set_source_sync sync-context v1.0.0 "$run_id" "$repaired" "$roots" "$hosts" \
      2>/dev/null; then return 1; fi
  [[ "$(build_state_get sync-context v1.0.0 "$run_id")" == "$before" ]]
}

test_source_sync_compiler_retry_budget() {
  local run_id attempt extra plan
  local BUILD_RETRY_MAX=3
  run_id=$(build_state_create sync-budget v1.0.0 linux/amd64) || return 1
  build_state_set_context sync-budget v1.0.0 "$run_id" '' '' '{}' /output 1 '{}' || return 1
  build_state_update_status sync-budget v1.0.0 failed "$run_id" || return 1
  for attempt in 1 2 3 4; do
    extra=$(jq -nc --argjson attempt "$attempt" '
      {attempts:$attempt,result:{status:"failed",stage:"source_sync",attempt:$attempt}}') || return 1
    build_state_update_target sync-budget v1.0.0 linux/amd64 failed "$extra" "$run_id" || return 1
    # Re-recording a failed receipt cannot mint another compiler retry.
    build_state_update_target sync-budget v1.0.0 linux/amd64 failed "$extra" "$run_id" || return 1
  done
  plan=$(build_state_resume sync-budget v1.0.0 "$run_id") || return 1
  jq -e '.targets_to_process == ["linux/amd64"] and .exceeded_target_retry_limit == []' \
    <<< "$plan" >/dev/null || return 1
  build_state_get sync-budget v1.0.0 "$run_id" | jq -e '
    .target_statuses["linux/amd64"].attempts == 4 and
    .target_statuses["linux/amd64"].source_sync_failures == 4' >/dev/null || return 1
  for attempt in 5 6 7; do
    extra=$(jq -nc --argjson attempt "$attempt" '{attempts:$attempt,result:null}') || return 1
    build_state_update_target sync-budget v1.0.0 linux/amd64 running "$extra" "$run_id" || return 1
    extra=$(jq -nc --argjson attempt "$attempt" '
      {attempts:$attempt,result:{status:"failed",stage:"build",attempt:$attempt}}') || return 1
    build_state_update_target sync-budget v1.0.0 linux/amd64 failed "$extra" "$run_id" || return 1
    plan=$(build_state_resume sync-budget v1.0.0 "$run_id") || return 1
    if ((attempt < 7)); then
      jq -e '.targets_to_process == ["linux/amd64"]' <<< "$plan" >/dev/null || return 1
    else
      jq -e '.targets_to_process == [] and .exceeded_target_retry_limit == ["linux/amd64"]' \
        <<< "$plan" >/dev/null || return 1
    fi
  done
}

test_host_readiness_compiler_retry_budget() {
  local run_id attempt extra plan
  local BUILD_RETRY_MAX=3
  run_id=$(build_state_create readiness-budget v1.0.0 linux/amd64) || return 1
  build_state_set_context readiness-budget v1.0.0 "$run_id" '' '' '{}' /output 1 '{}' || return 1
  build_state_update_status readiness-budget v1.0.0 failed "$run_id" || return 1
  # Source transfer and three host-readiness refusals retain four distinct
  # attempts without admitting a compiler. Replay is idempotent for each.
  for attempt in 1 2 3 4; do
    extra=$(jq -nc --argjson attempt "$attempt" '
      {attempts:$attempt,result:{status:"failed",exit_code:4,attempt:$attempt,
       stage:(if $attempt == 1 then "source_sync" else "host_readiness" end)}}') || return 1
    build_state_update_target readiness-budget v1.0.0 linux/amd64 failed "$extra" "$run_id" || return 1
    build_state_update_target readiness-budget v1.0.0 linux/amd64 failed "$extra" "$run_id" || return 1
  done
  plan=$(build_state_resume readiness-budget v1.0.0 "$run_id") || return 1
  jq -e '.targets_to_process == ["linux/amd64"] and .exceeded_target_retry_limit == []' \
    <<< "$plan" >/dev/null || return 1
  build_state_get readiness-budget v1.0.0 "$run_id" | jq -e '
    .target_statuses["linux/amd64"].attempts == 4 and
    .target_statuses["linux/amd64"].source_sync_failures == 1 and
    .target_statuses["linux/amd64"].host_readiness_failures == 3' >/dev/null || return 1
  # A label alone cannot exempt a compiler failure. Exit 4 from a build
  # stage, or another exit with the readiness label, still consumes budget.
  for attempt in 5 6 7; do
    extra=$(jq -nc --argjson attempt "$attempt" '{attempts:$attempt,result:null}') || return 1
    build_state_update_target readiness-budget v1.0.0 linux/amd64 running "$extra" "$run_id" || return 1
    extra=$(jq -nc --argjson attempt "$attempt" '
      {attempts:$attempt,result:{status:"failed",attempt:$attempt,
       stage:(if $attempt == 6 then "host_readiness" else "build" end),
       exit_code:(if $attempt == 5 then 4 else 9 end)}}') || return 1
    build_state_update_target readiness-budget v1.0.0 linux/amd64 failed "$extra" "$run_id" || return 1
    plan=$(build_state_resume readiness-budget v1.0.0 "$run_id") || return 1
    if ((attempt < 7)); then
      jq -e '.targets_to_process == ["linux/amd64"]' <<< "$plan" >/dev/null || return 1
    else
      jq -e '.targets_to_process == [] and .exceeded_target_retry_limit == ["linux/amd64"]' \
        <<< "$plan" >/dev/null || return 1
    fi
  done
  build_state_get readiness-budget v1.0.0 "$run_id" | jq -e '
    .target_statuses["linux/amd64"].attempts == 7 and
    .target_statuses["linux/amd64"].source_sync_failures == 1 and
    .target_statuses["linux/amd64"].host_readiness_failures == 3' >/dev/null
}

test_host_capacity_compiler_retry_budget() {
  local run_id attempt extra plan
  local BUILD_RETRY_MAX=3
  build_state_init || return 1
  run_id=$(build_state_create capacity-budget v1.0.0 linux/amd64) || return 1
  build_state_set_context capacity-budget v1.0.0 "$run_id" '' '' '{}' /output 1 '{}' || return 1
  build_state_update_status capacity-budget v1.0.0 failed "$run_id" || return 1
  # Six reservations fail before compilation, including four busy-host
  # refusals: the immutable attempt number must outgrow the retry allowance
  # without preventing a build once capacity becomes available.
  for attempt in 1 2 3 4 5 6; do
    extra=$(jq -nc --argjson attempt "$attempt" '{attempts:$attempt,result:null}') || return 1
    build_state_update_target capacity-budget v1.0.0 linux/amd64 running "$extra" "$run_id" || return 1
    extra=$(jq -nc --argjson attempt "$attempt" '
      {attempts:$attempt,result:{attempt:$attempt,backend_started:false,
       status:(if $attempt == 6 then "error" else "failed" end),
       exit_code:(if $attempt < 3 then 4 else 2 end),
       stage:(if $attempt == 1 then "source_sync" elif $attempt == 2 then "host_readiness"
              else "host_capacity" end)}}') || return 1
    build_state_update_target capacity-budget v1.0.0 linux/amd64 failed "$extra" "$run_id" || return 1
    # Aggregation and resumed receipt replay may repeat this exact write.
    build_state_update_target capacity-budget v1.0.0 linux/amd64 failed "$extra" "$run_id" || return 1
    plan=$(build_state_resume capacity-budget v1.0.0 "$run_id") || return 1
    jq -e '.targets_to_process == ["linux/amd64"] and .exceeded_target_retry_limit == []' \
      <<< "$plan" >/dev/null || return 1
  done
  build_state_get capacity-budget v1.0.0 "$run_id" | jq -e '
    .target_statuses["linux/amd64"] |
    .attempts == 6 and .source_sync_failures == 1 and .host_readiness_failures == 1 and
    .host_capacity_failures == 4' >/dev/null || return 1
  # Once a backend runs, even exit 2 is a genuine build attempt. Exactly the
  # configured three attempts remain available after all six refusals.
  for attempt in 7 8 9; do
    extra=$(jq -nc --argjson attempt "$attempt" '{attempts:$attempt,result:null}') || return 1
    build_state_update_target capacity-budget v1.0.0 linux/amd64 running "$extra" "$run_id" || return 1
    extra=$(jq -nc --argjson attempt "$attempt" '
      {attempts:$attempt,result:{status:"failed",stage:"build",exit_code:2,
       backend_started:true,attempt:$attempt}}') || return 1
    build_state_update_target capacity-budget v1.0.0 linux/amd64 failed "$extra" "$run_id" || return 1
    plan=$(build_state_resume capacity-budget v1.0.0 "$run_id") || return 1
    if ((attempt < 9)); then
      jq -e '.targets_to_process == ["linux/amd64"] and .exceeded_target_retry_limit == []' \
        <<< "$plan" >/dev/null || return 1
    else
      jq -e '.targets_to_process == [] and .exceeded_target_retry_limit == ["linux/amd64"]' \
        <<< "$plan" >/dev/null || return 1
    fi
  done
  build_state_get capacity-budget v1.0.0 "$run_id" | jq -e '
    .target_statuses["linux/amd64"] |
    .attempts == 9 and .source_sync_failures == 1 and .host_readiness_failures == 1 and
    .host_capacity_failures == 4' >/dev/null
}

test_host_capacity_requires_preexecution_evidence() {
  local BUILD_RETRY_MAX=1
  local sequence=0 filter tool run_id extra plan
  build_state_init || return 1
  for filter in '.stage="build"' '.exit_code=6' '.status="success"' \
    '.backend_started=true' 'del(.backend_started)' '.backend_started=null' \
    '.backend_started="false"'; do
    ((sequence+=1))
    tool="capacity-evidence-$sequence"
    run_id=$(build_state_create "$tool" v1.0.0 linux/amd64) || return 1
    build_state_update_status "$tool" v1.0.0 failed "$run_id" || return 1
    extra=$(jq -nc '{status:"failed",stage:"host_capacity",exit_code:2,backend_started:false}' |
      jq -c "$filter" | jq -c '{attempts:1,result:.}') || return 1
    build_state_update_target "$tool" v1.0.0 linux/amd64 failed "$extra" "$run_id" || return 1
    build_state_update_target "$tool" v1.0.0 linux/amd64 failed "$extra" "$run_id" || return 1
    plan=$(build_state_resume "$tool" v1.0.0 "$run_id") || return 1
    jq -e '.targets_to_process == [] and .exceeded_target_retry_limit == ["linux/amd64"]' \
      <<< "$plan" >/dev/null || return 1
    build_state_get "$tool" v1.0.0 "$run_id" | jq -e --argjson limit "$BUILD_RETRY_MAX" '
      .target_statuses["linux/amd64"] |
      .attempts == $limit and (.host_capacity_failures // 0) == 0' >/dev/null || return 1
  done
}

# Cleanup
cleanup() {
  if [[ "${DSR_TEST_KEEP_TMP:-0}" == 1 ]]; then
    printf 'Retained build-state fixture: %s\n' "$TEMP_DIR" >&2
  else
    rm -rf "$TEMP_DIR"
  fi
}
trap cleanup EXIT

if [[ "${1:-}" == --lock-custody-only ]]; then
  test_build_lock_custody
  exit $?
fi

if [[ "${1:-}" == --lock-borrow-only ]]; then
  test_build_lock_custody borrow
  exit $?
fi

if [[ "${1:-}" == --capacity-budget-only ]]; then
  run_state_regression "capacity refusals retain all compiler retries without double counting" test_host_capacity_compiler_retry_budget
  run_state_regression "capacity exemptions require an explicit pre-execution refusal" test_host_capacity_requires_preexecution_evidence
  run_state_regression "resume rejects malformed and overlapping refusal counters" test_resume_rejects_malformed_inventory
  echo "Tests run: $TESTS_RUN  Passed: $TESTS_PASSED  Failed: $TESTS_FAILED"
  [[ $TESTS_FAILED -eq 0 ]]
  exit $?
fi

if [[ "${1:-}" == --variant-relocation-only ]]; then
  run_state_regression "qualified relocation preserves receipts, history, routing and attempt budget" test_failed_variant_relocation_state
  echo "Tests run: $TESTS_RUN  Passed: $TESTS_PASSED  Failed: $TESTS_FAILED"
  [[ $TESTS_FAILED -eq 0 ]]
  exit $?
fi

# ============================================================================
# Run All Tests
# ============================================================================

echo "Running build_state module tests..."
echo ""

# Lock tests
test_build_lock_acquire
test_build_lock_blocks_concurrent
test_build_lock_release
test_build_lock_check
test_build_lock_info
((TESTS_RUN++))
if test_build_lock_custody; then
  pass "inherited build custody preserves exclusion, ownership and caller descriptors"
else
  fail "inherited build custody regression"
fi

# State tests
test_build_state_create
test_build_state_rejects_run_collision
test_build_state_get
test_build_state_update_status
test_build_state_update_preserves_private_mode
test_build_state_update_host
test_build_state_add_artifact

# Resume tests
test_build_state_can_resume
test_build_state_completed_hosts

# Workspace tests
test_build_state_workspace
test_build_state_artifacts_dir
test_build_state_list

# Retry tests
test_build_retry_backoff_calculation
test_build_retry_with_backoff_success
test_build_retry_with_backoff_failure
test_build_state_record_retry
test_build_state_get_retry_count
test_build_state_can_retry
test_build_state_resume
test_build_state_exec_with_retry

# Checkpoint transaction regressions
run_state_regression "checkpoint rejects invalid input/output and identity drift" test_checkpoint_validation
run_state_regression "checkpoint preserves another writer's PID-named temporary file" test_checkpoint_foreign_temp_preserved
run_state_regression "descriptor identity matches its file and survives pathname replacement" test_checkpoint_descriptor_identity
run_state_regression "checkpoint rejects a replaced lock after opening its descriptor" test_checkpoint_replaced_lock_rejected
run_state_regression "48 overlapping checkpoint writes lose no updates" test_checkpoint_concurrent_increments
run_state_regression "checkpoint rejects source/lock symlinks without changing their targets" test_checkpoint_symlinks_rejected
run_state_regression "failed checkpoint publication preserves old state and permits retry" test_checkpoint_publication_failure
run_state_regression "checkpoint detects non-cooperating writes" test_checkpoint_external_write_detected
run_state_regression "checkpoint preserves caller traps/umask and mode 0600" test_checkpoint_caller_scope_preserved
run_state_regression "checkpoint lock wait is bounded and unrelated runs remain writable" test_checkpoint_timeout_and_independent_files
run_state_regression "killed checkpoint writer does not strand the lock" test_checkpoint_crash_recovery
run_state_regression "Python lock fallback retains the lock in the owning shell" test_checkpoint_python_lock_backend
run_state_regression "checkpoint validates bounded timeout configuration" test_checkpoint_lock_config

# Single-generation resume and durable retry execution regressions
run_state_regression "state reads reject malformed checkpoints and wrong run identities" test_state_read_identity_and_shape
run_state_regression "resume rejects unknown or terminal run statuses" test_resume_unknown_status_rejected
run_state_regression "state writes reject invalid supplied host/target evidence" test_state_evidence_rejection
run_state_regression "resume uses one checkpoint even when latest moves mid-read" test_resume_single_snapshot_after_latest_moves
run_state_regression "resume maps real hosts and rejects empty target completion evidence" test_resume_host_routing_and_target_evidence
run_state_regression "resume rejects malformed target/host inventories and counters" test_resume_rejects_malformed_inventory
run_state_regression "native variant checkpoints resume only failed tasks and reject duplicate identities" test_native_matrix_resume_tasks
run_state_regression "qualified relocation preserves receipts, history, routing and attempt budget" test_failed_variant_relocation_state
run_state_regression "source-sync refresh preserves completed artifacts and records repair/opt-out history" test_source_sync_context_refresh
run_state_regression "source-sync failures preserve the compiler retry allowance without double counting" test_source_sync_compiler_retry_budget
run_state_regression "host-readiness refusals preserve compiler retries and real build failures exhaust them" test_host_readiness_compiler_retry_budget
run_state_regression "capacity refusals retain all compiler retries without double counting" test_host_capacity_compiler_retry_budget
run_state_regression "capacity exemptions require an explicit pre-execution refusal" test_host_capacity_requires_preexecution_evidence
run_state_regression "generic retry rejects zero or invalid budgets before execution" test_retry_budget_validation
run_state_regression "exponential retry backoff never exceeds its cap or overflows" test_retry_backoff_is_bounded
run_state_regression "missing or invalid saved retry budgets cannot launch commands" test_retry_unreadable_budget_blocks_execution
run_state_regression "retry execution preserves real exit codes and saved attempt budget" test_retry_preserves_exit_code_and_saved_budget
run_state_regression "retry success/failure receipts are complete and atomic" test_retry_success_and_failure_share_receipt
run_state_regression "failed attempt reservation prevents command execution" test_retry_reservation_failure_prevents_command
run_state_regression "failed completion receipt prevents success or another retry" test_retry_receipt_failure_stops_execution
run_state_regression "retry receipts stay bound to their original run after latest moves" test_retry_pins_run_when_latest_moves
run_state_regression "interrupted commands record cancellation and are not retried" test_retry_interruption_is_not_retried
run_state_regression "same-host execution is exclusive while other hosts overlap" test_retry_host_execution_lock
run_state_regression "killed retry execution consumes budget and releases its host lock" test_retry_crash_consumes_reserved_attempt
run_state_regression "retry history persistence errors propagate to the caller" test_retry_record_failure_propagates

echo ""
echo "=========================================="
echo "Tests run: $TESTS_RUN"
echo "Passed:    $TESTS_PASSED"
echo "Failed:    $TESTS_FAILED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
