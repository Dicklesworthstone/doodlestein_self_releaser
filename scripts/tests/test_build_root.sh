#!/usr/bin/env bash
# test_build_root.sh - hosts.yaml build_root and RAM-backed staging guards
#
# Covers issue #6: strict release snapshots must never default to /tmp (often
# a RAM-backed tmpfs), hosts.yaml may pin a per-host build_root, unsafe values
# fail closed, and the embedded staging guard refuses tmpfs/ramfs roots.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS_COUNT=0
FAIL_COUNT=0
log_pass() { echo "PASS $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
log_fail() { echo "FAIL $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

export ACT_LOGS_DIR="$TEMP_DIR/logs"
export ACT_ARTIFACTS_DIR="$TEMP_DIR/artifacts"
export ACT_REPOS_DIR="$TEMP_DIR/repos.d"
export ACT_CONFIG_DIR="$TEMP_DIR"
mkdir -p "$ACT_LOGS_DIR" "$ACT_ARTIFACTS_DIR" "$ACT_REPOS_DIR"

# shellcheck source=../../src/act_runner.sh
source "${DSR_TEST_ACT_RUNNER:-$PROJECT_ROOT/src/act_runner.sh}"
# act_runner.sh resets these from DSR_CONFIG_DIR at source time; keep the fixture.
export ACT_CONFIG_DIR="$TEMP_DIR" ACT_REPOS_DIR="$TEMP_DIR/repos.d"
_log_info()  { :; }
_log_error() { :; }
_log_ok()    { :; }
_log_warn()  { :; }

unset DSR_STRICT_BUILD_ROOT DSR_HOSTS_FILE
RUN_ID="550e8400-e29b-41d4-a716-446655440099"

# --- default roots ----------------------------------------------------------
actual=$(_act_strict_source_root_path "/remote/repo" "tool" "$RUN_ID")
if [[ "$actual" == "/var/tmp/.dsr-release-snapshots/tool-$RUN_ID/source" ]]; then
    log_pass "POSIX strict snapshots default to /var/tmp, not /tmp"
else
    log_fail "Unexpected default strict root: $actual"
fi

actual=$(_act_strict_source_root_path "C:/Users/build/repo" "tool" "$RUN_ID")
if [[ "$actual" == "C:/Users/Public/.dsr-release-snapshots/tool-$RUN_ID/source" ]]; then
    log_pass "Windows strict snapshots keep the drive-qualified public root"
else
    log_fail "Unexpected Windows strict root: $actual"
fi

# --- hosts.yaml build_root --------------------------------------------------
cat > "$TEMP_DIR/hosts.yaml" <<EOF
hosts:
  h1:
    platform: linux/amd64
    connection: ssh
    ssh_host: h1
    build_root: /srv/dsr-builds/
  h2:
    platform: linux/amd64
    connection: ssh
    ssh_host: h2
    build_root: relative/dir
  h3:
    platform: linux/amd64
    connection: ssh
    ssh_host: h3
    build_root: /srv/../etc
  h4:
    platform: linux/amd64
    connection: local
    build_root: $HOME/dsr-builds
  h5:
    platform: linux/amd64
    connection: ssh
    ssh_host: h5
    build_root: $HOME/dsr-builds
EOF
export DSR_HOSTS_FILE="$TEMP_DIR/hosts.yaml"

if command -v yq >/dev/null 2>&1; then
    actual=$(_act_strict_source_root_path "/remote/repo" "tool" "$RUN_ID" "h1")
    if [[ "$actual" == "/srv/dsr-builds/.dsr-release-snapshots/tool-$RUN_ID/source" ]]; then
        log_pass "hosts.yaml build_root (trailing slash trimmed) roots the strict snapshot"
    else
        log_fail "Expected /srv/dsr-builds strict root, got: $actual"
    fi

    actual=$(_act_get_host_build_root "h1")
    if [[ "$actual" == "/srv/dsr-builds" ]]; then
        log_pass "_act_get_host_build_root returns the normalized root"
    else
        log_fail "Unexpected build_root for h1: $actual"
    fi

    for bad in h2 h3 h4; do
        status=0
        _act_strict_source_root_path "/remote/repo" "tool" "$RUN_ID" "$bad" >/dev/null || status=$?
        if [[ $status -eq 4 ]]; then
            log_pass "Unsafe build_root for $bad fails closed (exit 4)"
        else
            log_fail "Expected exit 4 for unsafe build_root on $bad, got $status"
        fi
    done

    # A remote host may legitimately use a path under the operator's local $HOME
    # string; the \$HOME rule only applies to the local host.
    actual=$(_act_strict_source_root_path "/remote/repo" "tool" "$RUN_ID" "h5")
    if [[ "$actual" == "$HOME/dsr-builds/.dsr-release-snapshots/tool-$RUN_ID/source" ]]; then
        log_pass "\$HOME-prefixed build_root is accepted for a remote (ssh) host"
    else
        log_fail "Expected remote host build_root under \$HOME to be accepted, got: $actual"
    fi

    actual=$(_act_strict_source_root_path "/remote/repo" "tool" "$RUN_ID" "h-not-configured")
    if [[ "$actual" == "/var/tmp/.dsr-release-snapshots/tool-$RUN_ID/source" ]]; then
        log_pass "Hosts without build_root keep the /var/tmp default"
    else
        log_fail "Unexpected root for unconfigured host: $actual"
    fi

    actual=$(DSR_STRICT_BUILD_ROOT="/opt/strict-override" _act_strict_source_root_path "/remote/repo" "tool" "$RUN_ID" "h1")
    if [[ "$actual" == "/opt/strict-override/tool-$RUN_ID/source" ]]; then
        log_pass "DSR_STRICT_BUILD_ROOT still overrides hosts.yaml build_root"
    else
        log_fail "Expected DSR_STRICT_BUILD_ROOT to win, got: $actual"
    fi
else
    echo "SKIP hosts.yaml build_root cases (yq not installed)"
fi
unset DSR_HOSTS_FILE

# --- RAM-backed guard snippet ----------------------------------------------
mkdir -p "$TEMP_DIR/bin-tmpfs" "$TEMP_DIR/bin-ext4" "$TEMP_DIR/bin-none"
printf '#!/bin/sh\necho tmpfs\n' > "$TEMP_DIR/bin-tmpfs/findmnt"
printf '#!/bin/sh\necho ext4\n' > "$TEMP_DIR/bin-ext4/findmnt"
printf '#!/bin/sh\nexit 1\n' > "$TEMP_DIR/bin-none/stat"
chmod +x "$TEMP_DIR/bin-tmpfs/findmnt" "$TEMP_DIR/bin-ext4/findmnt" "$TEMP_DIR/bin-none/stat"
guard=$(_act_ram_backed_guard_sh "/any/root")

status=0
out=$(PATH="$TEMP_DIR/bin-tmpfs:/usr/bin:/bin" sh -c "set -e; ${guard}echo survived" 2>"$TEMP_DIR/guard.err") || status=$?
if [[ $status -eq 4 && "$out" != *survived* ]] && grep -q 'refusing to stage the build under RAM-backed /any/root (tmpfs)' "$TEMP_DIR/guard.err"; then
    log_pass "Guard aborts with exit 4 on a tmpfs root and names the fix"
else
    log_fail "Guard did not abort on tmpfs: status=$status out=$out err=$(cat "$TEMP_DIR/guard.err")"
fi

status=0
out=$(PATH="$TEMP_DIR/bin-ext4:/usr/bin:/bin" sh -c "set -e; ${guard}echo survived" 2>/dev/null) || status=$?
if [[ $status -eq 0 && "$out" == "survived" ]]; then
    log_pass "Guard lets a disk-backed root through"
else
    log_fail "Guard blocked an ext4 root: status=$status out=$out"
fi

status=0
out=$(PATH="$TEMP_DIR/bin-none:/usr/bin:/bin" sh -c "set -e; ${guard}echo survived" 2>/dev/null) || status=$?
if [[ $status -eq 0 && "$out" == "survived" ]]; then
    log_pass "Guard is a no-op when neither findmnt nor GNU stat is usable"
else
    log_fail "Guard failed without probe tools: status=$status out=$out"
fi

guard_quoted=$(_act_ram_backed_guard_sh "/odd'name")
if [[ "$guard_quoted" == *"-T '/odd'\\''name'"* ]]; then
    log_pass "Guard shell-quotes roots containing single quotes"
else
    log_fail "Guard quoting wrong: $guard_quoted"
fi

if PATH="$TEMP_DIR/bin-tmpfs:/usr/bin:/bin" _act_dir_is_ram_backed "/any/root"; then
    log_pass "_act_dir_is_ram_backed detects tmpfs"
else
    log_fail "_act_dir_is_ram_backed missed tmpfs"
fi
if PATH="$TEMP_DIR/bin-ext4:/usr/bin:/bin" _act_dir_is_ram_backed "/any/root"; then
    log_fail "_act_dir_is_ram_backed flagged ext4"
else
    log_pass "_act_dir_is_ram_backed ignores ext4"
fi

# The storage probe is the sole filesystem admission fixture. Real Git,
# archives, SSH command execution and tracked-byte verification still run;
# these cases do not claim actual disk-backed placement or native compilation.
snapshot_repo="$TEMP_DIR/snapshot-repo"
mkdir "$snapshot_repo"
printf 'exact snapshot bytes\n' > "$snapshot_repo/tracked.txt"
git -C "$snapshot_repo" init -q -b main
git -C "$snapshot_repo" add tracked.txt
git -C "$snapshot_repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm snapshot
snapshot_sha=$(git -C "$snapshot_repo" rev-parse HEAD)
cat > "$TEMP_DIR/snapshot-hosts.yaml" <<'YAML'
hosts:
  snapshot-local:
    connection: local
    platform: linux/amd64
  snapshot-remote:
    connection: ssh
    ssh_host: snapshot-fixture
    platform: linux/amd64
YAML
export DSR_HOSTS_FILE="$TEMP_DIR/snapshot-hosts.yaml"
cat > "$TEMP_DIR/bin-ext4/ssh" <<'SSH'
#!/usr/bin/env bash
set -uo pipefail
while (($#)); do
    case "$1" in -o) shift 2 ;; -n) shift ;; *) break ;; esac
done
[[ $# -eq 2 && "$1" == snapshot-fixture ]] || exit 255
exec bash -c "$2"
SSH
chmod +x "$TEMP_DIR/bin-ext4/ssh"
for snapshot_host in snapshot-local snapshot-remote; do
    snapshot_source="$TEMP_DIR/$snapshot_host/run/source"
    snapshot_status=0
    (
        export PATH="$TEMP_DIR/bin-ext4:$PATH"
        # Observe protection at extraction, before any tracked source or
        # future private Cargo cache can be exposed to the cleanup scanner.
        tar() {
            if [[ "$1" == -xf ]]; then
                [[ -f "${2%/*}/.sbh-protect" && ! -L "${2%/*}/.sbh-protect" ]] || return 99
                printf 'protected-before-extract\n' >> "$TEMP_DIR/$snapshot_host-extraction"
            fi
            command tar "$@"
        }
        export -f tar
        export TEMP_DIR snapshot_host
        _act_sync_strict_checkout "$snapshot_host" "$snapshot_repo" "$snapshot_sha" \
            "$snapshot_source" source.tar snapshot
    ) > "$TEMP_DIR/$snapshot_host.out" 2> "$TEMP_DIR/$snapshot_host.err" || snapshot_status=$?
    if [[ $snapshot_status -eq 0 && -s "$TEMP_DIR/$snapshot_host-extraction" ]]; then
        log_pass "$snapshot_host protects its fresh snapshot before real extraction"
    else
        log_fail "$snapshot_host snapshot transfer failed (exit $snapshot_status)"
    fi
    if [[ -f "$snapshot_source/tracked.txt" ]] && cmp -s "$snapshot_repo/tracked.txt" "$snapshot_source/tracked.txt"; then
        log_pass "$snapshot_host retains the exact committed source bytes"
    else
        log_fail "$snapshot_host source bytes differ"
    fi
    if [[ -f "${snapshot_source%/*}/.sbh-protect" && ! -e "$snapshot_source/.sbh-protect" ]]; then
        log_pass "$snapshot_host protects the cache ancestor outside the authenticated source tree"
    else
        log_fail "$snapshot_host protection marker has the wrong placement"
    fi
done

# An obstruction at the fresh marker pathname must stop admission before
# either an archive or a source directory is populated.
snapshot_source="$TEMP_DIR/blocked-snapshot/run/source"
snapshot_status=0
(
    export PATH="$TEMP_DIR/bin-ext4:$PATH"
    mkdir() {
        command mkdir "$@" || return $?
        if [[ "${!#}" == "${snapshot_source%/*}" ]]; then
            command mkdir "${snapshot_source%/*}/.sbh-protect"
        fi
    }
    _act_sync_strict_checkout snapshot-local "$snapshot_repo" "$snapshot_sha" \
        "$snapshot_source" source.tar snapshot
) > "$TEMP_DIR/blocked-snapshot.out" 2> "$TEMP_DIR/blocked-snapshot.err" || snapshot_status=$?
if [[ $snapshot_status -eq 4 && ! -e "$snapshot_source" && ! -e "${snapshot_source%/*}/.source.tar" ]]; then
    log_pass "marker creation failure refuses before source or archive admission"
else
    log_fail "marker creation failure reached source staging (exit $snapshot_status)"
fi

echo
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"
[[ $FAIL_COUNT -eq 0 ]]
