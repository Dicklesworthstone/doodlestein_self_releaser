#!/usr/bin/env bash
# Exercise the actual fallback command and release hash/purpose guards against
# real files. Build hosts, signing, notifications and network publication are
# controllable boundaries; this suite does not execute external releases.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
COMMAND_FILE="${DSR_TEST_COMMAND_FILE:-$ROOT/dsr}"
HELPERS_FILE="${DSR_TEST_HELPERS_FILE:-$COMMAND_FILE}"
source <(awk '/^(_release_file_size|_release_sha256|_release_require_publishable_artifacts)\(\) \{/{copy=1} copy{print} copy && /^\}/{copy=0}' "$HELPERS_FILE")
source <(awk '/^cmd_fallback\(\) \{/{copy=1} copy{print} copy && /^\}/{exit}' "$COMMAND_FILE")
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dsr-fallback-tests.XXXXXXXX") || exit 1
printf 'Fixtures: %s\n' "$TEST_ROOT"
PASS=0 FAIL=0

log_info() { printf '%s\n' "$*" >&2; }
log_error() { log_info "$@"; }
log_warn() { log_info "$@"; }
log_ok() { log_info "$@"; }
log_set_tool() { :; }
act_load_repo_config() { return 0; }
act_get_local_path() { printf '%s\n' "$CASE/source"; }
act_get_repo() { printf '%s\n' owner/tool; }
config_get_tool_field() { printf '\n'; }
config_get_release_contract_json() { printf '%s\n' "$CONTRACT"; }
config_validate_release_contract() { return "$CONFIG_RC"; }
version_detect() { printf '%s\n' 1.2.3; }
git_ops_version_to_tag() { printf 'v%s\n' "${1#v}"; }
json_envelope() {
    jq -nc --arg cmd "$1" --arg status "$2" --argjson rc "$3" --argjson details "$4" \
        '{command:$cmd,status:$status,exit_code:$rc,details:$details}'
}
notify_event() { printf 'NOTIFY %s\n' "$1" >> "$CALLS"; printf 'notification output\n'; }
build_state_init() {
    printf 'INIT\n' >> "$CALLS"
    [[ "$INIT_RC" == 0 ]] || return "$INIT_RC"
    mkdir -p "$DSR_STATE_DIR/builds"
}
build_lock_acquire() {
    printf 'LOCK %s %s\n' "$1" "$2" >> "$CALLS"
    [[ "$LOCK_RC" == 0 ]] || return "$LOCK_RC"
    mkdir "$CASE/lock"
}
build_lock_release() {
    printf 'UNLOCK %s %s\n' "$1" "$2" >> "$CALLS"
    [[ "$UNLOCK_RC" == 0 ]] || return "$UNLOCK_RC"
    rmdir "$CASE/lock"
}
qg_run_checks() {
    printf 'CHECK %s\n' "$*" >> "$CALLS"
    printf '{"child":"quality"}\n'
    if [[ "$SIGNAL_PHASE" == checks ]]; then kill -TERM "$BASHPID"; fi
    return "$QUALITY_RC"
}
signing_is_enabled() { [[ "$SIGN_ENABLED" == true ]]; }
signing_sign_batch() {
    printf 'SIGN %s\n' "$*" >> "$CALLS"
    printf 'signature output\n'
    return "$SIGN_RC"
}
# The old command used this directory-wide signer; keep it implemented for the
# negative control rather than mistaking a missing fixture for a regression.
signing_sign_files() { signing_sign_batch "$@"; }
cmd_release() {
    printf 'RELEASE %s\n' "$*" >> "$CALLS"
    printf '{"child":"release"}\n'
    return "$RELEASE_RC"
}
cmd_build() {
    printf 'BUILD %s flag=%s\n' "$*" "${DSR_BUILD_LOCK_HELD_BY_CALLER:-unset}" >> "$CALLS"
    local out="" arg
    while (($#)); do
        arg="$1"; shift
        if [[ "$arg" == --output-dir ]]; then out="$1"; shift; fi
    done
    if [[ "$CONTRACT" != null && -e "$out" ]]; then return 4; fi
    mkdir -p "$out" || return 4
    printf 'daemon bytes\n' > "$out/daemon"
    printf 'worker bytes\n' > "$out/worker"
    printf 'unrelated\n' > "$out/tool-obsolete"
    local manifest="$out/tool-v1.2.3-manifest.json" body
    body=$(jq -nc --arg sha "$(_release_sha256 "$out/daemon")" \
        --arg worker_sha "$(_release_sha256 "$out/worker")" \
        --argjson size "$(_release_file_size "$out/daemon")" \
        --argjson worker_size "$(_release_file_size "$out/worker")" '
        {tool:"tool",version:"v1.2.3",status:"success",build_purpose:"release",publishable:true,
         summary:{total:2,success:2,failed:0},
         artifacts:[{name:"daemon",sha256:$sha,size_bytes:$size},
                    {name:"worker",sha256:$worker_sha,size_bytes:$worker_size}]}') || return 6
    case "$MANIFEST_MODE" in
        missing) ;;
        malformed) printf '{broken\n' > "$manifest" ;;
        multiple) printf '%s\n%s\n' "$body" "$body" > "$manifest" ;;
        *)
            case "$MANIFEST_MODE" in
                empty) body=$(jq '.artifacts=[]' <<< "$body") ;;
                partial) body=$(jq '.summary.success=1 | .summary.failed=1' <<< "$body") ;;
                wrong-tool) body=$(jq '.tool="other"' <<< "$body") ;;
                wrong-version) body=$(jq '.version="v9.0.0"' <<< "$body") ;;
                duplicate) body=$(jq '.artifacts[1]=.artifacts[0]' <<< "$body") ;;
                unsafe) body=$(jq '.artifacts[0].name="../foreign"' <<< "$body") ;;
                diagnostic) body=$(jq '.publishable=false' <<< "$body") ;;
            esac
            printf '%s\n' "$body" > "$manifest"
            case "$MANIFEST_MODE" in
                corrupt) printf 'different payload\n' > "$out/daemon" ;;
                absent) mv "$out/worker" "$CASE/saved-worker" ;;
                symlink) mv "$out/worker" "$CASE/saved-worker"; ln -s "$CASE/saved-worker" "$out/worker" ;;
                manifest-link) mv "$manifest" "$CASE/saved-manifest"; ln -s "$CASE/saved-manifest" "$manifest" ;;
                hash-failure) _release_sha256() { return 3; } ;;
            esac
            ;;
    esac
    printf '{"child":"build"}\n'
    if [[ "$SIGNAL_PHASE" == build ]]; then kill -TERM "$BASHPID"; fi
    return "$BUILD_RC"
}

setup() {
    CASE="$TEST_ROOT/$1"; mkdir -p "$CASE/source"
    CALLS="$CASE/calls"; : > "$CALLS"
    export DSR_STATE_DIR="$CASE/state"
    JSON_MODE=true DRY_RUN=false
    INIT_RC=0 LOCK_RC=0 UNLOCK_RC=0 QUALITY_RC=0 BUILD_RC=0 SIGN_RC=0 RELEASE_RC=0 CONFIG_RC=0
    CONTRACT=null SIGN_ENABLED=true MANIFEST_MODE=valid SIGNAL_PHASE=""
    OUT="$CASE/artifacts"
}
run_fallback() {
    RC=0
    cmd_fallback tool --version 1.2.3 --output-dir "$OUT" "$@" > "$CASE/stdout" 2> "$CASE/stderr" || RC=$?
}
one_result() {
    jq -es --argjson rc "$RC" 'length==1 and .[0].command=="fallback" and .[0].exit_code==$rc' \
        "$CASE/stdout" >/dev/null
}
blocked() {
    ! grep -q '^RELEASE ' "$CALLS" && ! grep -q '^SIGN ' "$CALLS" && [[ ! -e "$CASE/lock" ]]
}
run_test() {
    if ( "$@" ); then PASS=$((PASS+1)); printf 'PASS: %s\n' "$*"
    else FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$*"; fi
}

test_success() {
    setup success; run_fallback
    [[ "$RC" == 0 && ! -e "$CASE/lock" ]] && one_result &&
        grep -Fq "SIGN $OUT/daemon $OUT/worker" "$CALLS" &&
        jq -e '.details.artifacts_count==2 and .details.phases.release=="success"' "$CASE/stdout" >/dev/null &&
        [[ ! -e "$OUT/tool-1.2.3-SHA256SUMS.txt" ]]
}
test_build_failure() {
    setup "build-$1"; BUILD_RC="$1"; run_fallback
    [[ "$RC" == "$1" ]] && one_result && blocked
}
test_manifest_failure() {
    setup "manifest-$1"; MANIFEST_MODE="$1"; run_fallback
    [[ "$RC" == 6 ]] && blocked
}
test_signing_failure() {
    setup sign; SIGN_RC=1; run_fallback
    [[ "$RC" == 7 && ! -e "$CASE/lock" ]] && one_result && ! grep -q '^RELEASE ' "$CALLS"
}
test_strict_fresh_output() {
    setup strict; CONTRACT='{"checksum_sidecar":"sha256"}'; run_fallback
    [[ "$RC" == 0 && ! -e "$CASE/lock" ]] && one_result && ! grep -q '^SIGN ' "$CALLS"
}
test_dry_run() {
    setup "dry-$1"
    if [[ "$1" == global ]]; then DRY_RUN=true; run_fallback; else run_fallback --dry-run; fi
    [[ "$RC" == 0 && ! -s "$CALLS" && ! -e "$OUT" && ! -e "$DSR_STATE_DIR" ]] && one_result
}
test_state_failure() {
    setup state; INIT_RC=1; run_fallback
    [[ "$RC" == 4 ]] && one_result && ! grep -q '^LOCK\|^CHECK\|^BUILD\|^RELEASE' "$CALLS"
}
test_lock_failure() {
    setup "lock-$1"; LOCK_RC="$1"; run_fallback
    [[ "$RC" == "$1" ]] && one_result && ! grep -q '^CHECK\|^BUILD\|^RELEASE\|^UNLOCK' "$CALLS"
}
test_quality_failure() {
    setup quality; QUALITY_RC=1; run_fallback --skip-checks
    [[ "$RC" == 6 ]] && one_result && blocked &&
        ! grep -q '^BUILD' "$CALLS" && grep -q -- '--skip-checks' "$CALLS"
}
test_build_only() {
    setup build_only; run_fallback --build-only
    [[ "$RC" == 0 && ! -e "$CASE/lock" ]] && one_result && ! grep -q '^RELEASE' "$CALLS" &&
        jq -e '.details.phases.release=="skipped"' "$CASE/stdout" >/dev/null
}
test_release_failure() {
    setup "release-$1"; RELEASE_RC="$1"; run_fallback
    [[ "$RC" == "$1" && ! -e "$CASE/lock" ]] && one_result && ! grep -q '^NOTIFY fallback.success' "$CALLS"
}
test_resume_reaches_build() {
    setup resume; run_fallback --resume
    [[ "$RC" == 0 ]] && grep -q '^BUILD .*--resume' "$CALLS"
}
test_preserves_caller_state() {
    setup caller
    export DSR_BUILD_LOCK_HELD_BY_CALLER=previous
    trap ':' EXIT
    local old_trap; old_trap=$(trap -p EXIT)
    run_fallback
    [[ "$RC" == 0 && "$(trap -p EXIT)" == "$old_trap" && "$DSR_BUILD_LOCK_HELD_BY_CALLER" == previous ]]
}
test_signal_releases_lock() {
    setup "signal-$1"; SIGNAL_PHASE="$1"; run_fallback
    [[ "$RC" == 143 && ! -e "$CASE/lock" ]] && ! grep -q '^RELEASE' "$CALLS"
}
test_invalid_argument() {
    setup "argument-$1"; run_fallback "$1"
    [[ "$RC" == 4 && ! -s "$CALLS" ]]
}

run_test test_success
for rc in 1 2 3 4 5 6 8 130 143; do run_test test_build_failure "$rc"; done
for mode in missing malformed multiple empty partial wrong-tool wrong-version duplicate unsafe diagnostic corrupt absent symlink manifest-link hash-failure; do
    run_test test_manifest_failure "$mode"
done
run_test test_signing_failure
run_test test_strict_fresh_output
run_test test_dry_run global
run_test test_dry_run command
run_test test_state_failure
run_test test_lock_failure 2
run_test test_lock_failure 8
run_test test_quality_failure
run_test test_build_only
for rc in 1 7 8 130; do run_test test_release_failure "$rc"; done
run_test test_resume_reaches_build
run_test test_preserves_caller_state
run_test test_signal_releases_lock checks
run_test test_signal_releases_lock build
for arg in --tool --version --output-dir --unknown; do run_test test_invalid_argument "$arg"; done
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
