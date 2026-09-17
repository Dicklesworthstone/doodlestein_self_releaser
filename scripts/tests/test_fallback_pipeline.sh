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
act_get_targets() { printf '%s\n' "$TARGETS"; }
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
build_state_get() {
    printf 'STATE %s\n' "$*" >> "$CALLS"
    [[ -f "$CASE/checkpoint.json" ]] || return 1
    cat "$CASE/checkpoint.json"
}
_release_contract_scan_release_by_tag() {
    printf 'SCAN %s\n' "$*" >> "$CALLS"
    [[ "$SCAN_RC" == 0 ]] || return "$SCAN_RC"
    if [[ "$RELEASE_EXISTS" == true ]]; then
        printf '{"count":1,"release":{"id":9,"tag_name":"v1.2.3"}}\n'
    else
        printf '{"count":0,"release":null}\n'
    fi
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
    if [[ "$QUALITY_MUTATES_SOURCE" == true ]]; then printf 'mutated\n' >> "$CASE/source/src.txt"; fi
    return "$QUALITY_RC"
}
signing_is_enabled() { [[ "$SIGN_ENABLED" == true ]]; }
signing_sign_batch() {
    printf 'SIGN %s\n' "$*" >> "$CALLS"
    printf 'signature output\n'
    local payload
    if [[ "$SIGN_RC" == 0 && "$SIGN_MODE" != missing ]]; then
        for payload in "$@"; do
            printf 'fixture-signature:%s\n' "$(_release_sha256 "$payload")" > "${payload}.minisig"
        done
        if [[ "$SIGN_MODE" == corrupt ]]; then printf 'invalid\n' > "${1}.minisig"; fi
        if [[ "$SIGN_MODE" == mutate ]]; then printf 'mutated\n' >> "$1"; fi
        if [[ "$SIGN_MODE" == manifest ]]; then printf '\n' >> "$OUT/tool-v1.2.3-manifest.json"; fi
    fi
    return "$SIGN_RC"
}
signing_verify() {
    printf 'VERIFY %s\n' "$1" >> "$CALLS"
    [[ -f "${1}.minisig" && "$(cat "${1}.minisig")" == "fixture-signature:$(_release_sha256 "$1")" ]]
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
    body=$(jq -nc --arg run "$RUN" --arg source "$SOURCE_SHA" \
        --arg sha "$(_release_sha256 "$out/daemon")" \
        --arg worker_sha "$(_release_sha256 "$out/worker")" \
        --argjson size "$(_release_file_size "$out/daemon")" \
        --argjson worker_size "$(_release_file_size "$out/worker")" '
        {tool:"tool",version:"v1.2.3",status:"success",build_purpose:"release",publishable:true,
         run_id:$run,source:{git_sha:$source,git_ref:"v1.2.3"},
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
    SIGN_MODE=valid SCAN_RC=0 RELEASE_EXISTS=false QUALITY_MUTATES_SOURCE=false
    RUN=11111111-1111-4111-8111-111111111111 SOURCE_SHA=0000000000000000000000000000000000000000
    TARGETS='linux/amd64 darwin/arm64'
    OUT="$CASE/artifacts"
}
checkpoint() {
    jq -nc --arg status "$1" --arg sha "$SOURCE_SHA" --arg run "$RUN" --arg out "$OUT" '
        {tool:"tool",version:"1.2.3",run_id:$run,status:$status,git_sha:$sha,
         targets:["linux/amd64","darwin/arm64"],
         context:{output_dir:$out,build_purpose:"release",publishable:true}}' > "$CASE/checkpoint.json"
}
completed_fixture() {
    git -C "$CASE/source" init -q
    printf 'source code\n' > "$CASE/source/src.txt"
    git -C "$CASE/source" add src.txt
    git -C "$CASE/source" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm source
    SOURCE_SHA=$(git -C "$CASE/source" rev-parse HEAD)
    cmd_build tool --version 1.2.3 --output-dir "$OUT" >/dev/null
    checkpoint completed
    : > "$CALLS"
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
    setup resume; checkpoint failed; run_fallback --resume
    [[ "$RC" == 0 ]] && grep -q "^BUILD .*--resume=$RUN" "$CALLS" &&
        [[ $(grep -c '^STATE ' "$CALLS") == 1 ]]
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
test_completed_resume() {
    setup "completed-$1"; completed_fixture; RELEASE_EXISTS="$1"
    run_fallback --resume
    [[ "$RC" == 0 ]] && one_result && ! grep -q '^BUILD ' "$CALLS" &&
        [[ $(grep -c '^STATE ' "$CALLS") == 1 ]] && grep -q '^CHECK ' "$CALLS" &&
        jq -e --arg run "$RUN" '.details.resume_run_id==$run and .details.artifacts_count==2' "$CASE/stdout" >/dev/null || return 1
    if [[ "$1" == true ]]; then grep -q '^RELEASE .*--resume' "$CALLS"
    else ! grep -q '^RELEASE .*--resume' "$CALLS"; fi
}
test_completed_default_output() {
    setup completed_output; completed_fixture
    RC=0
    cmd_fallback tool --version 1.2.3 --resume > "$CASE/stdout" 2> "$CASE/stderr" || RC=$?
    [[ "$RC" == 0 ]] && one_result && grep -Fq -- "--artifacts $OUT" <(grep '^RELEASE' "$CALLS")
}
test_completed_rejects_drift() {
    setup "drift-$1"; completed_fixture
    case "$1" in
        source) printf 'changed\n' >> "$CASE/source/src.txt" ;;
        targets) TARGETS=linux/amd64 ;;
        output) OUT="$CASE/different-output" ;;
        run) jq '.run_id="22222222-2222-4222-8222-222222222222"' "$OUT/tool-v1.2.3-manifest.json" > "$CASE/m"; mv "$CASE/m" "$OUT/tool-v1.2.3-manifest.json" ;;
        manifest-sha) jq '.source.git_sha=("f"*40)' "$OUT/tool-v1.2.3-manifest.json" > "$CASE/m"; mv "$CASE/m" "$OUT/tool-v1.2.3-manifest.json" ;;
        payload) printf 'changed\n' >> "$OUT/worker" ;;
        quality-source) QUALITY_MUTATES_SOURCE=true ;;
    esac
    run_fallback --resume
    [[ "$RC" != 0 && ! -e "$CASE/lock" ]] && ! grep -q '^BUILD\|^RELEASE' "$CALLS"
}
test_invalid_checkpoint() {
    setup "checkpoint-$1"; completed_fixture
    case "$1" in
        missing) mv "$CASE/checkpoint.json" "$CASE/old-state" ;;
        malformed) printf 'invalid\n' > "$CASE/checkpoint.json" ;;
        cancelled) checkpoint cancelled ;;
        diagnostic) jq '.context.publishable=false' "$CASE/checkpoint.json" > "$CASE/s"; mv "$CASE/s" "$CASE/checkpoint.json" ;;
        selected) RUN=22222222-2222-4222-8222-222222222222 ;;
    esac
    run_fallback "--resume=$RUN"
    [[ "$RC" == 4 ]] && blocked && ! grep -q '^BUILD ' "$CALLS"
}
test_signature_resume() {
    setup signature_resume; completed_fixture; RELEASE_RC=1
    run_fallback --resume
    [[ "$RC" == 1 ]] || return 1
    local before; before=$(_release_sha256 "$OUT/daemon.minisig")
    RELEASE_RC=0 RELEASE_EXISTS=true
    : > "$CALLS"
    run_fallback --resume
    [[ "$RC" == 0 && "$(_release_sha256 "$OUT/daemon.minisig")" == "$before" ]] &&
        ! grep -q '^BUILD\|^SIGN ' "$CALLS" && grep -q '^RELEASE .*--resume' "$CALLS"
}
test_signature_failure() {
    setup "signature-$1"; completed_fixture
    case "$1" in
        existing-corrupt) printf invalid > "$OUT/daemon.minisig" ;;
        existing-symlink) printf invalid > "$CASE/foreign-sig"; ln -s "$CASE/foreign-sig" "$OUT/daemon.minisig" ;;
        *) SIGN_MODE="$1" ;;
    esac
    run_fallback --resume
    [[ "$RC" != 0 && ! -e "$CASE/lock" ]] && ! grep -q '^RELEASE ' "$CALLS"
}
test_release_scan_failure() {
    setup scan_failure; completed_fixture; SCAN_RC=8
    run_fallback --resume
    [[ "$RC" == 8 && ! -e "$CASE/lock" ]] && one_result && ! grep -q '^RELEASE ' "$CALLS"
}
test_signing_interruption() {
    setup "sign-interrupt-$1"; SIGN_RC="$1"; run_fallback
    [[ "$RC" == "$1" && ! -e "$CASE/lock" ]] && one_result && ! grep -q '^RELEASE ' "$CALLS"
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
run_test test_invalid_argument --resume=unsafe
run_test test_completed_resume true
run_test test_completed_resume false
run_test test_completed_default_output
for drift in source targets output run manifest-sha payload quality-source; do run_test test_completed_rejects_drift "$drift"; done
for mode in missing malformed cancelled diagnostic selected; do run_test test_invalid_checkpoint "$mode"; done
run_test test_signature_resume
for mode in existing-corrupt existing-symlink missing corrupt mutate manifest; do run_test test_signature_failure "$mode"; done
run_test test_release_scan_failure
for rc in 5 130 143; do run_test test_signing_interruption "$rc"; done
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
