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
log_pass() { echo "PASS $1"; ((PASS_COUNT++)); }
log_fail() { echo "FAIL $1"; ((FAIL_COUNT++)); }

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

export ACT_LOGS_DIR="$TEMP_DIR/logs"
export ACT_ARTIFACTS_DIR="$TEMP_DIR/artifacts"
export ACT_REPOS_DIR="$TEMP_DIR/repos.d"
export ACT_CONFIG_DIR="$TEMP_DIR"
mkdir -p "$ACT_LOGS_DIR" "$ACT_ARTIFACTS_DIR" "$ACT_REPOS_DIR"

# shellcheck source=../../src/act_runner.sh
source "$PROJECT_ROOT/src/act_runner.sh"
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

    DSR_STRICT_BUILD_ROOT="/opt/strict-override" \
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
out=$(PATH="$TEMP_DIR/bin-none" sh -c "set -e; ${guard}echo survived" 2>/dev/null) || status=$?
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

echo
echo "Passed: $PASS_COUNT  Failed: $FAIL_COUNT"
[[ $FAIL_COUNT -eq 0 ]]
