#!/usr/bin/env bash
# Exercise the actual fallback command and release hash/purpose guards against
# real files. Build hosts, signing, notifications and network publication are
# controllable boundaries; this suite does not execute external releases.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# Keep inventory admission real even though cryptographic signing is a
# controlled boundary below. Sourcing the module does not generate any key.
# shellcheck source=src/signing.sh
source "$ROOT/src/signing.sh"
# shellcheck source=src/git_ops.sh
source "$ROOT/src/git_ops.sh"
COMMAND_FILE="${DSR_TEST_COMMAND_FILE:-$ROOT/dsr}"
HELPERS_FILE="${DSR_TEST_HELPERS_FILE:-$COMMAND_FILE}"
# shellcheck source=/dev/null
source <(awk '/^(_release_file_size|_release_sha256|_release_require_publishable_artifacts)\(\) \{/{copy=1} copy{print} copy && /^\}/{copy=0}' "$HELPERS_FILE")
# shellcheck source=/dev/null
source <(awk '/^cmd_fallback\(\) \{/{copy=1} copy{print} copy && /^\}/{exit}' "$COMMAND_FILE")
# shellcheck source=/dev/null
source <(awk '/^_act_build_task_plan\(\) \{/{copy=1} copy{print} copy && /^\}/{exit}' "$ROOT/src/act_runner.sh")
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dsr-fallback-tests.XXXXXXXX") || exit 1
printf 'Fixtures: %s\n' "$TEST_ROOT"
PASS=0 FAIL=0

log_info() { printf '%s\n' "$*" >&2; }
log_error() { log_info "$@"; }
log_warn() { log_info "$@"; }
log_ok() { log_info "$@"; }
log_set_tool() { :; }
_log_info() { log_info "$@"; }
_log_error() { log_error "$@"; }
_log_ok() { log_ok "$@"; }
_cfg_log_error() { log_error "$@"; }
act_load_repo_config() { return 0; }
act_get_local_path() { printf '%s\n' "$CASE/source"; }
act_get_repo() { printf '%s\n' owner/tool; }
act_get_targets() { printf '%s\n' "$TARGETS"; }
# These fixtures represent ordinary workflow targets. Completed fallback
# admission uses the real task planner against their explicit configuration.
act_platform_uses_act() { return 0; }
# The throttle check finds one queued release run: the fallback's trigger.
_check_repo() {
    printf 'THROTTLE %s\n' "$1" >> "$CALLS"
    printf '{"repo":"%s","status":"throttled","queued_count":1,"stuck_in_progress_count":0}\n' "$1"
    return 1
}
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
gh_resolve_tag_sha() {
    printf 'REMOTE_TAG %s\n' "$*" >> "$CALLS"
    case "$REMOTE_TAG_MODE" in
        unavailable) return 1 ;;
        mismatch) printf '%s\n' ffffffffffffffffffffffffffffffffffffffff; return 0 ;;
        source) printf 'mutated during tag lookup\n' >> "$CASE/source/src.txt" ;;
        tag) git -C "$CASE/source" tag -f v1.2.3 "$OTHER_SHA" >/dev/null || return 1 ;;
    esac
    printf '%s\n' "$SOURCE_SHA"
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
    local quality_source="$CASE/source" argument
    while (($#)); do
        argument="$1"; shift
        if [[ "$argument" == --work-dir ]]; then quality_source="$1"; shift; fi
    done
    if [[ "${_ACT_ISOLATED_SOURCE_TOOL:-}" == tool ]]; then
        printf 'CHECK_SOURCE %s\n' "$quality_source" >> "$CALLS"
        [[ "$quality_source" != "$CASE/source" &&
           "$(git -C "$quality_source" rev-parse HEAD)" == "$SOURCE_SHA" ]] || return 4
    fi
    if [[ "$SIGNAL_PHASE" == checks ]]; then kill -TERM "$BASHPID"; fi
    if [[ "$QUALITY_MUTATES_SOURCE" == true ]]; then printf 'mutated\n' >> "$quality_source/src.txt"; fi
    if [[ "${QUALITY_MUTATES_SIBLING:-false}" == true ]]; then
        local sibling
        sibling=$(_act_release_source_dependency_checkouts_json tool | jq -r '.[0].local_path') || return 4
        printf 'mutated sibling\n' >> "$sibling/src.txt"
    fi
    return "$QUALITY_RC"
}
signing_is_enabled() { [[ "$SIGN_ENABLED" == true ]]; }
# Configuration asks for signing (independent of whether the keypair works).
signing_wanted() { [[ "$SIGN_WANTED" == true ]]; }
signing_check() { printf 'KEYCHECK\n' >> "$CALLS"; return 3; }
signing_sign_batch() {
    local payload all_retained=true
    for payload in "$@"; do
        if [[ -e "${payload}.minisig" || -L "${payload}.minisig" ]]; then
            [[ -f "${payload}.minisig" && ! -L "${payload}.minisig" ]] &&
                signing_verify "$payload" || return 1
        else
            all_retained=false
        fi
    done
    $all_retained && return 0
    printf 'SIGN %s\n' "$*" >> "$CALLS"
    printf 'signature output\n'
    if [[ "$SIGN_RC" == 0 && "$SIGN_MODE" != missing ]]; then
        for payload in "$@"; do
            printf 'fixture-signature:%s\n' "$(_release_sha256 "$payload")" > "${payload}.minisig"
        done
        if [[ "$SIGN_MODE" == corrupt ]]; then printf 'invalid\n' > "${1}.minisig"; fi
        if [[ "$SIGN_MODE" == mutate ]]; then printf 'mutated\n' >> "$1"; fi
        if [[ "$SIGN_MODE" == manifest ]]; then printf '\n' >> "$OUT/tool-v1.2.3-manifest.json"; fi
        if [[ "$SIGN_MODE" == source ]]; then printf 'mutated by signer\n' >> "$(act_get_local_path tool)/src.txt"; fi
        if [[ "$SIGN_MODE" == tag ]]; then git -C "$(act_get_local_path tool)" tag -f v1.2.3 "$OTHER_SHA" >/dev/null; fi
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
    if [[ "$RELEASE_RESULT_MODE" == malformed ]]; then
        printf '{invalid\n'
    else
        jq -nc --arg mode "$RELEASE_RESULT_MODE" --argjson rc "$RELEASE_RC" '
            {command:"release",status:(if $rc==0 then "success" else "error" end),exit_code:$rc,
             details:{repo:"owner/tool",tag:"v1.2.3",release_id:9,draft:false}} |
            if $mode=="draft" then .details.draft=true
            elif $mode=="missing-visibility" then del(.details.draft)
            elif $mode=="wrong-tag" then .details.tag="v9.9.9"
            elif $mode=="wrong-repo" then .details.repo="owner/other"
            else . end'
    fi
    if [[ "${_ACT_ISOLATED_SOURCE_TOOL:-}" == tool ]]; then
        act_load_repo_config tool || return 4
        local source
        source=$(act_get_local_path tool) || return 4
        [[ "$source" == "$ACT_REPO_LOCAL_PATH" && "$source" != "$CASE/source" &&
           "$(git -C "$source" rev-parse HEAD)" == "$SOURCE_SHA" ]] || return 4
        printf 'RELEASE_SOURCE %s\n' "$source" >> "$CALLS"
    fi
    return "$RELEASE_RC"
}
cmd_build() {
    printf 'BUILD %s flag=%s\n' "$*" "${DSR_BUILD_LOCK_HELD_BY_CALLER:-unset}" >> "$CALLS"
    if [[ "${_ACT_ISOLATED_SOURCE_TOOL:-}" == tool ]]; then
        act_load_repo_config tool || return 4
        local source contexts
        source=$(act_get_local_path tool) || return 4
        [[ "$source" == "$ACT_REPO_LOCAL_PATH" && "$source" != "$CASE/source" &&
           "$(git -C "$source" rev-parse HEAD)" == "$SOURCE_SHA" ]] || return 4
        printf 'BUILD_SOURCE %s\n' "$source" >> "$CALLS"
        _act_release_source_dependency_checkouts_json tool > "$CASE/build-dependencies.json" || return 4
        contexts=$(mktemp -d "$CASE/contexts.XXXXXXXX") || return 4
        _act_export_ordinary_git_contexts "$ACT_REPOS_DIR/tool.yaml" "$source" "$contexts" \
            > "$CASE/build-contexts.json" || return 4
    fi
    local out="" arg
    while (($#)); do
        arg="$1"; shift
        if [[ "$arg" == --output-dir ]]; then out="$1"; shift; fi
    done
    if [[ "$CONTRACT" != null && -e "$out" ]]; then return 4; fi
    mkdir -p "$out" || return 4
    printf 'daemon bytes\n' > "$out/daemon"
    printf 'worker bytes\n' > "$out/worker"
    mkdir -p "$out/diagnostics" || return 4
    printf 'unrelated\n' > "$out/diagnostics/tool-obsolete"
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
                wrong-source) body=$(jq '.source.git_sha=("f"*40)' <<< "$body") ;;
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
                extra-payload) printf 'undeclared payload\n' > "$out/tool-obsolete" ;;
            esac
            ;;
    esac
    if [[ "$BUILD_MUTATES_SOURCE" == true ]]; then printf 'mutated by build\n' >> "$(act_get_local_path tool)/src.txt"; fi
    printf '{"child":"build"}\n'
    if [[ "$SIGNAL_PHASE" == build ]]; then kill -TERM "$BASHPID"; fi
    return "$BUILD_RC"
}

setup() {
    CASE="$TEST_ROOT/$1"; mkdir -p "$CASE/source"
    ACT_REPOS_DIR="$CASE/repos.d"
    mkdir -p "$ACT_REPOS_DIR"
    printf 'language: go\nbinary_name: tool\n' > "$ACT_REPOS_DIR/tool.yaml"
    CALLS="$CASE/calls"; : > "$CALLS"
    export DSR_STATE_DIR="$CASE/state"
    export JSON_MODE=true DRY_RUN=false
    INIT_RC=0 LOCK_RC=0 UNLOCK_RC=0 QUALITY_RC=0 BUILD_RC=0 SIGN_RC=0 RELEASE_RC=0 CONFIG_RC=0
    CONTRACT=null SIGN_ENABLED=true SIGN_WANTED=true MANIFEST_MODE=valid SIGNAL_PHASE=""
    export SIGNING_PRIVATE_KEY="$CASE/keys/minisign.key" SIGNING_PUBLIC_KEY="$CASE/keys/minisign.pub"
    SIGN_MODE=valid SCAN_RC=0 RELEASE_EXISTS=false QUALITY_MUTATES_SOURCE=false BUILD_MUTATES_SOURCE=false
    QUALITY_MUTATES_SIBLING=false
    OTHER_SHA="" REMOTE_TAG_MODE=valid RELEASE_RESULT_MODE=public
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
    [[ -z "${DSR_TEST_FILTER:-}" || "$*" == *"$DSR_TEST_FILTER"* ]] || return 0
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
    [[ "$RC" == "$1" ]] && one_result && blocked &&
        jq -e --argjson rc "$1" '[.details.steps[].command] == ["check", "build"] and
            .details.steps[0].throttled and .details.steps[1].exit_code == $rc and
            .details.steps[1].status == (if $rc == 1 then "partial" else "error" end) and
            (.details.trigger | startswith("release workflow throttled"))' "$CASE/stdout" >/dev/null
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
    [[ "$RC" == 0 && ! -e "$CASE/lock" ]] && one_result && ! grep -q '^RELEASE\|^THROTTLE' "$CALLS" &&
        jq -e '.details.phases.release=="skipped" and [.details.steps[].command] == ["build"]' \
            "$CASE/stdout" >/dev/null
}
test_release_failure() {
    setup "release-$1"; RELEASE_RC="$1"; run_fallback
    [[ "$RC" == "$1" && ! -e "$CASE/lock" ]] && one_result && ! grep -q '^NOTIFY fallback.success' "$CALLS" &&
        jq -e --argjson rc "$1" '[.details.steps[] | [.command, .exit_code]] ==
            [["check", 1], ["build", 0], ["release", $rc]]' "$CASE/stdout" >/dev/null
}
test_release_requires_public_confirmation() {
    setup "release-confirmation-$1"
    RELEASE_RESULT_MODE="$1" RELEASE_EXISTS=true
    checkpoint failed
    run_fallback --resume
    [[ "$RC" == 7 && ! -e "$CASE/lock" ]] && one_result &&
        grep -q '^RELEASE .*--resume' "$CALLS" && ! grep -q '^NOTIFY fallback.success' "$CALLS" &&
        jq -e '.details.phase=="release" and .details.phases.release=="blocked"' "$CASE/stdout" >/dev/null
}
test_release_public_confirmation_completes() {
    setup release-public-confirmation
    RELEASE_EXISTS=true
    checkpoint failed
    run_fallback --resume
    [[ "$RC" == 0 && ! -e "$CASE/lock" ]] && one_result &&
        grep -q '^RELEASE .*--resume' "$CALLS" &&
        jq -e '.details.phases.release=="success"' "$CASE/stdout" >/dev/null
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
test_completed_task_plan() {
    setup "completed-plan-$1"; completed_fixture
    local tasks
    tasks=$(_act_build_task_plan tool 1.2.3 '["linux/amd64","darwin/arm64"]' false) || return 1
    jq --argjson tasks "$tasks" '.context.build_tasks=$tasks' "$CASE/checkpoint.json" > "$CASE/planned-state.json"
    mv "$CASE/planned-state.json" "$CASE/checkpoint.json"
    if [[ "$1" == drift ]]; then
        jq '.context.build_tasks |= reverse' "$CASE/checkpoint.json" > "$CASE/drifted-state.json"
        mv "$CASE/drifted-state.json" "$CASE/checkpoint.json"
    fi
    run_fallback --resume
    if [[ "$1" == matching ]]; then
        [[ "$RC" == 0 ]] && one_result && ! grep -q '^BUILD ' "$CALLS" && grep -q '^RELEASE ' "$CALLS"
    else
        [[ "$RC" == 4 ]] && one_result && blocked && ! grep -q '^BUILD ' "$CALLS"
    fi
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
# Signing is configured but the keypair that exists cannot sign: never ship
# unsigned assets that installers embedding that key would reject.
test_unusable_signing_key_blocks_release() {
    setup unusable_key; SIGN_ENABLED=false
    mkdir -p "$CASE/keys"; printf 'key\n' > "$SIGNING_PRIVATE_KEY"
    run_fallback
    [[ "$RC" == 7 ]] && one_result && blocked && grep -q '^KEYCHECK' "$CALLS" &&
        jq -e '.[0].details.phases.signing == "failed" and (.[0].details.error | contains("cannot sign"))' \
            <(jq -s . "$CASE/stdout") >/dev/null
}
# With no keypair at all the release goes ahead unsigned, and says so.
test_missing_signing_key_releases_unsigned_loudly() {
    setup missing_key; SIGN_ENABLED=false
    run_fallback
    [[ "$RC" == 0 ]] && grep -q '^RELEASE ' "$CALLS" && ! grep -q '^SIGN ' "$CALLS" &&
        grep -q 'releasing UNSIGNED' "$CASE/stderr" &&
        jq -e '.details.phases.signing == "unsigned"' "$CASE/stdout" >/dev/null
}
# signing.enabled: false is an explicit opt-out: no warning, no failure.
test_signing_disabled_by_config_is_quiet() {
    setup signing_off; SIGN_ENABLED=false SIGN_WANTED=false
    mkdir -p "$CASE/keys"; printf 'key\n' > "$SIGNING_PRIVATE_KEY"
    run_fallback
    [[ "$RC" == 0 ]] && ! grep -q 'UNSIGNED\|KEYCHECK' "$CASE/stderr" "$CALLS" &&
        jq -e '.details.phases.signing == "skipped"' "$CASE/stdout" >/dev/null
}

# A watcher may run after the checkout has advanced, or while quality/build
# commands mutate it. The public fallback's expected source must survive every
# boundary, including completed-build reuse and build-only operation.
test_expected_source_success() {
    setup "expected-success-$1"; completed_fixture
    git -C "$CASE/source" -c user.name=Fixture -c user.email=fixture@example.invalid \
        tag -am source v1.2.3 || return 1
    if [[ "$1" == resume ]]; then
        run_fallback --expected-sha "$SOURCE_SHA" --resume
    elif [[ "$1" == build-only ]]; then
        run_fallback "--expected-sha=$SOURCE_SHA" --build-only
    else
        run_fallback --expected-sha "${SOURCE_SHA^^}"
    fi
    [[ "$RC" == 0 ]] && one_result &&
        jq -e --arg sha "$SOURCE_SHA" '.details.expected_sha==$sha and .details.phases.verification=="passed"' \
            "$CASE/stdout" >/dev/null || return 1
    if [[ "$1" == build-only ]]; then ! grep -q '^RELEASE \|^REMOTE_TAG ' "$CALLS"
    else
        grep -q '^REMOTE_TAG owner/tool v1.2.3$' "$CALLS" && grep -q '^RELEASE ' "$CALLS"
    fi
}
test_expected_source_initial_refusal() {
    setup "expected-refuse-$1"; completed_fixture
    local expected="$SOURCE_SHA"
    case "$1" in
        branch-only) git -C "$CASE/source" branch v1.2.3 ;;
        missing-tag) ;;
        *) git -C "$CASE/source" tag v1.2.3 || return 1 ;;
    esac
    case "$1" in
        wrong-sha) expected=ffffffffffffffffffffffffffffffffffffffff ;;
        head-moved)
            git -C "$CASE/source" -c user.name=Fixture -c user.email=fixture@example.invalid \
                commit --allow-empty -qm later || return 1 ;;
        dirty) printf 'dirty\n' >> "$CASE/source/src.txt" ;;
        staged)
            printf 'staged\n' >> "$CASE/source/src.txt"
            git -C "$CASE/source" add src.txt || return 1 ;;
        untracked) printf 'untracked\n' > "$CASE/source/untracked.txt" ;;
    esac
    run_fallback --expected-sha "$expected"
    [[ "$RC" == 4 ]] && one_result && blocked &&
        ! grep -q '^INIT\|^LOCK\|^CHECK\|^BUILD ' "$CALLS" &&
        jq -e '.details.phase=="source" and .details.phases.release=="blocked"' "$CASE/stdout" >/dev/null
}
test_expected_source_drift() {
    setup "expected-drift-$1"; completed_fixture
    git -C "$CASE/source" tag v1.2.3 || return 1
    case "$1" in
        quality) QUALITY_MUTATES_SOURCE=true ;;
        build) BUILD_MUTATES_SOURCE=true ;;
        manifest) MANIFEST_MODE=wrong-source ;;
        signing) SIGN_MODE=source ;;
        tag)
            # Make another real commit without changing the expected checkout.
            OTHER_SHA=$(printf 'other commit\n' | git -C "$CASE/source" \
                -c user.name=Fixture -c user.email=fixture@example.invalid \
                commit-tree "HEAD^{tree}" -p HEAD) || return 1
            SIGN_MODE=tag ;;
    esac
    run_fallback --expected-sha "$SOURCE_SHA"
    local expected_rc=6
    [[ "$1" == quality ]] && expected_rc=4
    [[ "$RC" == "$expected_rc" && ! -e "$CASE/lock" ]] && one_result &&
        ! grep -q '^RELEASE ' "$CALLS" || return 1
    if [[ "$1" == quality ]]; then ! grep -q '^BUILD\|^SIGN ' "$CALLS"
    elif [[ "$1" == build || "$1" == manifest ]]; then ! grep -q '^SIGN ' "$CALLS"; fi
}
test_expected_remote_tag_refusal() {
    setup "expected-remote-$1"; completed_fixture
    git -C "$CASE/source" tag v1.2.3 || return 1
    REMOTE_TAG_MODE="$1"
    local expected_rc=7
    [[ "$1" == unavailable ]] && expected_rc=8
    if [[ "$1" == tag ]]; then
        OTHER_SHA=$(printf 'other remote-boundary commit\n' | git -C "$CASE/source" \
            -c user.name=Fixture -c user.email=fixture@example.invalid \
            commit-tree "HEAD^{tree}" -p HEAD) || return 1
    fi
    run_fallback --expected-sha "$SOURCE_SHA"
    [[ "$RC" == "$expected_rc" && ! -e "$CASE/lock" ]] && one_result &&
        grep -q '^REMOTE_TAG owner/tool v1.2.3$' "$CALLS" &&
        ! grep -q '^RELEASE ' "$CALLS" &&
        jq -e '.details.phase=="release" and .details.phases.release=="blocked"' "$CASE/stdout" >/dev/null
}
test_expected_source_argument_refusal() {
    setup "expected-argument-$1"
    case "$1" in
        missing) run_fallback --expected-sha ;;
        empty) run_fallback --expected-sha= ;;
        short) run_fallback --expected-sha abcdef0 ;;
        zero) run_fallback --expected-sha 0000000000000000000000000000000000000000 ;;
        duplicate) run_fallback --expected-sha ffffffffffffffffffffffffffffffffffffffff --expected-sha ffffffffffffffffffffffffffffffffffffffff ;;
        version)
            RC=0
            cmd_fallback tool --expected-sha ffffffffffffffffffffffffffffffffffffffff \
                > "$CASE/stdout" 2> "$CASE/stderr" || RC=$? ;;
    esac
    [[ "$RC" == 4 && ! -s "$CALLS" ]]
}

# Run isolated-source cases through the actual configuration/path consumers,
# including strict dependency projection and ordinary Git-context export.
isolated_fixture() {
    completed_fixture
    git -C "$CASE/source" -c user.name=Fixture -c user.email=fixture@example.invalid \
        tag -am release v1.2.3 || return 1
    export DSR_CONFIG_DIR="$CASE" DSR_REPOS_FILE="$CASE/repos.yaml"
    jq -nc --arg path "$CASE/source" \
        '{repo:"owner/tool",local_path:$path,language:"go",binary_name:"tool"}' > "$ACT_REPOS_DIR/tool.yaml"
    # shellcheck source=/dev/null
    source <(awk '/^(config_get_tool_field|_config_read_single_mapping_json|_config_canonicalize_release_source_dependency_checkouts_json|_config_get_release_source_dependency_checkouts_json|config_get_release_source_dependencies_json)\(\) \{/{copy=1} copy{print} copy && /^\}/{copy=0}' "$ROOT/src/config.sh")
    # shellcheck source=/dev/null
    source <(awk '/^(_act_materialized_source_path|act_get_local_path|act_load_repo_config|_act_release_source_dependencies_json|_act_release_source_dependency_checkouts_json|_act_export_ordinary_git_contexts|_act_validate_isolated_cargo_paths|_act_sync_sibling_crates)\(\) \{/{copy=1} copy{print} copy && /^\}/{copy=0}' "$ROOT/src/act_runner.sh")
}

test_isolated_source_preserves_checkout() {
    setup "isolated-preserve-$1"; isolated_fixture || return 1
    printf 'later committed source\n' > "$CASE/source/src.txt"
    git -C "$CASE/source" -c user.name=Fixture -c user.email=fixture@example.invalid \
        commit -qam later || return 1
    printf 'staged developer work\n' > "$CASE/source/src.txt"
    git -C "$CASE/source" add src.txt || return 1
    printf 'unstaged developer work\n' >> "$CASE/source/src.txt"
    printf 'untracked developer work\n' > "$CASE/source/private.txt"
    printf '#!/usr/bin/env bash\ntouch "%s/hook-ran"\n' "$CASE" > "$CASE/source/.git/hooks/post-checkout"
    chmod +x "$CASE/source/.git/hooks/post-checkout"
    local index_before head_before tag_before content_before snapshot
    index_before=$(_release_sha256 "$CASE/source/.git/index")
    content_before=$(_release_sha256 "$CASE/source/src.txt")
    head_before=$(git -C "$CASE/source" rev-parse HEAD)
    tag_before=$(git -C "$CASE/source" rev-parse refs/tags/v1.2.3)
    case "$1" in
        config)
            jq '.fallback={isolate_source:true}' "$ACT_REPOS_DIR/tool.yaml" > "$CASE/isolation-config.json"
            mv "$CASE/isolation-config.json" "$ACT_REPOS_DIR/tool.yaml"
            run_fallback --expected-sha "$SOURCE_SHA" ;;
        resume) run_fallback --expected-sha "$SOURCE_SHA" --isolate-source --resume ;;
        build-only) run_fallback --expected-sha "$SOURCE_SHA" --isolate-source --build-only ;;
        *) run_fallback --expected-sha "$SOURCE_SHA" --isolate-source ;;
    esac
    [[ "$RC" == 0 ]] && one_result || return 1
    snapshot=$(jq -r '.details.source_materialization.source_root' "$CASE/stdout") || return 1
    [[ "$(cat "$snapshot/src.txt")" == 'source code' && ! -e "$snapshot/private.txt" && ! -e "$CASE/hook-ran" &&
       "$(_release_sha256 "$CASE/source/.git/index")" == "$index_before" &&
       "$(_release_sha256 "$CASE/source/src.txt")" == "$content_before" &&
       "$(git -C "$CASE/source" rev-parse HEAD)" == "$head_before" &&
       "$(git -C "$CASE/source" rev-parse refs/tags/v1.2.3)" == "$tag_before" &&
       "$(cat "$CASE/source/private.txt")" == 'untracked developer work' &&
       "$(git -C "$snapshot" rev-parse refs/tags/v1.2.3)" == "$tag_before" ]] || return 1
    jq -e '.details.isolated_source and .details.source_materialization.transport == "local-objects"' \
        "$CASE/stdout" >/dev/null || return 1
    grep -Fqx "CHECK_SOURCE $snapshot" "$CALLS" || return 1
    if [[ "$1" == resume ]]; then ! grep -q '^BUILD ' "$CALLS"
    else grep -Fqx "BUILD_SOURCE $snapshot" "$CALLS"; fi || return 1
    if [[ "$1" == build-only ]]; then ! grep -q '^RELEASE\|^REMOTE_TAG' "$CALLS"
    else grep -Fqx "RELEASE_SOURCE $snapshot" "$CALLS"; fi
}

test_isolated_source_retries_fresh() {
    setup isolated-retry; isolated_fixture || return 1
    checkpoint failed
    BUILD_RC=6
    run_fallback --expected-sha "$SOURCE_SHA" --isolate-source
    [[ "$RC" == 6 ]] || return 1
    local first second
    first=$(jq -r '.details.source_materialization.source_root' "$CASE/stdout")
    BUILD_RC=0
    printf 'developer edit between attempts\n' >> "$CASE/source/src.txt"
    run_fallback --expected-sha "$SOURCE_SHA" --isolate-source "--resume=$RUN"
    [[ "$RC" == 0 ]] && one_result || return 1
    second=$(jq -r '.details.source_materialization.source_root' "$CASE/stdout")
    [[ "$first" != "$second" && -d "$first/.git" && -d "$second/.git" ]] &&
        grep -q "^BUILD .*--resume=$RUN" "$CALLS" &&
        jq -e --arg run "$RUN" '.details.resume_run_id == $run' "$CASE/stdout" >/dev/null
}

test_isolated_source_pinned_siblings() {
    setup "isolated-sibling-$1"; isolated_fixture || return 1
    mkdir "$CASE/sibling"
    git -C "$CASE/sibling" init -q
    printf 'pinned dependency\n' > "$CASE/sibling/src.txt"
    if [[ "$1" == absolute ]]; then
        printf '[dependencies]\noriginal = { path = "%s" }\n' "$CASE/source" > "$CASE/sibling/Cargo.toml"
    fi
    git -C "$CASE/sibling" add .
    git -C "$CASE/sibling" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm dependency
    local revision source_before snapshot dependency
    revision=$(git -C "$CASE/sibling" rev-parse HEAD)
    printf 'dirty dependency work\n' >> "$CASE/sibling/src.txt"
    source_before=$(_release_sha256 "$CASE/sibling/src.txt")
    jq --arg path "$CASE/sibling" --arg revision "$revision" \
        '.sibling_crates=[{relative_path:"dependency",local_path:$path,revision:$revision}]' \
        "$ACT_REPOS_DIR/tool.yaml" > "$CASE/sibling-config.json"
    mv "$CASE/sibling-config.json" "$ACT_REPOS_DIR/tool.yaml"
    if [[ "$1" == unpinned ]]; then
        jq 'del(.sibling_crates[0].revision)' "$ACT_REPOS_DIR/tool.yaml" > "$CASE/unpinned.json"
        mv "$CASE/unpinned.json" "$ACT_REPOS_DIR/tool.yaml"
    elif [[ "$1" == mutated ]]; then
        QUALITY_MUTATES_SIBLING=true
    fi
    run_fallback --expected-sha "$SOURCE_SHA" --isolate-source
    [[ "$(_release_sha256 "$CASE/sibling/src.txt")" == "$source_before" ]] || return 1
    if [[ "$1" != pinned ]]; then
        [[ "$RC" == 4 ]] && blocked && ! grep -q '^BUILD ' "$CALLS" || return 1
        [[ "$1" != absolute ]] || ! grep -q '^CHECK ' "$CALLS"
        return $?
    fi
    [[ "$RC" == 0 ]] && one_result || return 1
    snapshot=$(jq -r '.details.source_materialization.source_root' "$CASE/stdout")
    dependency="${snapshot%/*}/dependency"
    [[ "$(cat "$dependency/src.txt")" == 'pinned dependency' ]] || return 1
    jq -e --arg path "$dependency" --arg revision "$revision" \
        '.[0].local_path == $path and .[0].git_sha == $revision' "$CASE/build-dependencies.json" >/dev/null &&
        jq -e --arg path "$dependency" --arg revision "$revision" \
            'any(.[]; .relative_path == "dependency" and .local_path == $path and .context.git_sha == $revision)' \
            "$CASE/build-contexts.json" >/dev/null
}

test_isolated_source_drift() {
    setup "isolated-drift-$1"; isolated_fixture || return 1
    local source_before expected=6
    source_before=$(_release_sha256 "$CASE/source/src.txt")
    case "$1" in
        quality) QUALITY_MUTATES_SOURCE=true; expected=4 ;;
        build) BUILD_MUTATES_SOURCE=true ;;
        signing) SIGN_MODE=source ;;
    esac
    run_fallback --expected-sha "$SOURCE_SHA" --isolate-source
    [[ "$RC" == "$expected" && "$(_release_sha256 "$CASE/source/src.txt")" == "$source_before" ]] &&
        one_result && ! grep -q '^RELEASE ' "$CALLS"
}

test_isolated_source_cargo_paths() {
    setup "isolated-cargo-$1"; isolated_fixture || return 1
    local manifest="$CASE/source/Cargo.toml"
    case "$1" in
        quoted) printf '[dependencies]\nlocal = { "path" = "\\u002Fdeveloper/checkout" }\n' > "$manifest" ;;
        hidden)
            mkdir "$CASE/source/.hidden"
            manifest="$CASE/source/.hidden/Cargo.toml"
            printf '.hidden/\n' > "$CASE/source/.gitignore"
            printf '[dependencies.local]\npath = """\n/developer/checkout"""\n' > "$manifest" ;;
        relative) printf '[dependencies]\nlocal = { path = "../dependency" }\n' > "$manifest" ;;
        *) printf '[dependencies]\nlocal = { path = "/developer/checkout" }\n' > "$manifest" ;;
    esac
    git -C "$CASE/source" add -f . || return 1
    git -C "$CASE/source" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm manifest || return 1
    SOURCE_SHA=$(git -C "$CASE/source" rev-parse HEAD)
    git -C "$CASE/source" -c user.name=Fixture -c user.email=fixture@example.invalid tag -fam release v1.2.3 >/dev/null || return 1
    local before
    before=$(_release_sha256 "$manifest")
    run_fallback --expected-sha "$SOURCE_SHA" --isolate-source
    [[ "$(_release_sha256 "$manifest")" == "$before" ]] || return 1
    if [[ "$1" == relative ]]; then
        [[ "$RC" == 0 ]] && one_result
    else
        [[ "$RC" == 4 ]] && one_result && blocked && ! grep -q '^CHECK\|^BUILD ' "$CALLS"
    fi
}

test_isolated_source_sibling_resume() {
    setup "isolated-sibling-resume-$1"; isolated_fixture || return 1
    mkdir "$CASE/sibling"
    git -C "$CASE/sibling" init -q
    printf 'dependency one\n' > "$CASE/sibling/src.txt"
    git -C "$CASE/sibling" add src.txt
    git -C "$CASE/sibling" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm dependency
    local revision receipt
    revision=$(git -C "$CASE/sibling" rev-parse HEAD)
    jq --arg path "$CASE/sibling" --arg revision "$revision" \
        '.sibling_crates=[{relative_path:"dependency",local_path:$path,revision:$revision}]' \
        "$ACT_REPOS_DIR/tool.yaml" > "$CASE/sibling-config.json"
    mv "$CASE/sibling-config.json" "$ACT_REPOS_DIR/tool.yaml"
    receipt=$(jq -nc --arg sha "$SOURCE_SHA" --arg revision "$revision" \
        '{git_context:{git_sha:$sha},sibling_git_contexts:{dependency:{git_sha:$revision}}}')
    jq --argjson receipt "$receipt" '
        .context.source_sync=$receipt | .source_sync_history=[{receipt:$receipt}] |
        .target_statuses=(.targets | map({key:.,value:{status:"completed",result:{status:"success",source_sync:$receipt}}}) | from_entries)
    ' "$CASE/checkpoint.json" > "$CASE/source-state.json"
    mv "$CASE/source-state.json" "$CASE/checkpoint.json"
    case "$1" in
        partial) jq '.status="failed"' "$CASE/checkpoint.json" > "$CASE/revised-state.json" ;;
        pending)
            jq --arg path "$CASE/not-yet-written-result.json" '
                .status="failed" | .target_statuses["darwin/arm64"]={status:"running",result_path:$path}
            ' "$CASE/checkpoint.json" > "$CASE/revised-state.json" ;;
        variants)
            jq '.language="rust"' "$ACT_REPOS_DIR/tool.yaml" > "$CASE/variant-config.json"
            mv "$CASE/variant-config.json" "$ACT_REPOS_DIR/tool.yaml"
            # Keep the real task planner; compiler admission is a boundary in
            # this fallback suite, which never executes a native compiler.
            # shellcheck source=/dev/null
            source <(awk '/^(_act_token_is_safe|act_substitute_build_cmd_tokens)\(\) \{/{copy=1} copy{print} copy && /^\}/{copy=0}' "$ROOT/src/act_runner.sh")
            act_platform_uses_act() { return 1; }
            act_get_configured_target_triples() {
                if [[ "$2" == linux/amd64 ]]; then
                    printf '%s\n' x86_64-unknown-linux-gnu x86_64-unknown-linux-musl
                else printf '%s\n' aarch64-apple-darwin; fi
            }
            act_get_build_cmd() { printf '%s\n' 'cargo build'; }
            act_get_build_env() { printf 'CARGO_BUILD_TARGET=%s\n' "$3"; }
            _act_validate_native_target_command() { return 0; }
            _act_sha256() { _release_sha256 "$1"; }
            local tasks config_digest
            tasks=$(_act_build_task_plan tool 1.2.3 '["linux/amd64","darwin/arm64"]' false) || return 1
            config_digest=$(_release_sha256 "$ACT_REPOS_DIR/tool.yaml")
            jq --argjson tasks "$tasks" --arg digest "$config_digest" --argjson receipt "$receipt" '
                .context.build_tasks=$tasks | .context.native_matrix_config_sha256=$digest |
                .target_statuses=($tasks | map({key:.key,value:{status:"completed",result:{status:"success",source_sync:$receipt}}}) | from_entries)
            ' "$CASE/checkpoint.json" > "$CASE/revised-state.json"
            printf 'third variant bytes\n' > "$OUT/variant"
            jq --argjson tasks "$tasks" --arg sha "$(_release_sha256 "$OUT/variant")" \
                --argjson size "$(_release_file_size "$OUT/variant")" '
                .summary={total:3,success:3,failed:0} |
                .artifacts[0] += {target:$tasks[0].platform,target_triple:$tasks[0].target_triple} |
                .artifacts[1] += {target:$tasks[1].platform,target_triple:$tasks[1].target_triple} |
                .artifacts += [{name:"variant",sha256:$sha,size_bytes:$size,
                    target:$tasks[2].platform,target_triple:$tasks[2].target_triple}]
            ' "$OUT/tool-v1.2.3-manifest.json" > "$CASE/variant-manifest.json"
            mv "$CASE/variant-manifest.json" "$OUT/tool-v1.2.3-manifest.json" ;;
        history) jq '.source_sync_history[0].receipt.sibling_git_contexts.dependency.git_sha=("f"*40)' "$CASE/checkpoint.json" > "$CASE/revised-state.json" ;;
        embedded) jq '.target_statuses["linux/amd64"].result.source_sync.sibling_git_contexts.dependency.git_sha=("f"*40)' "$CASE/checkpoint.json" > "$CASE/revised-state.json" ;;
        sidecar)
            jq --argjson receipt "$receipt" -nc '{status:"success",source_sync:$receipt} | .source_sync.sibling_git_contexts.dependency.git_sha=("f"*40)' > "$CASE/target-sidecar.json"
            jq --arg path "$CASE/target-sidecar.json" '.target_statuses["linux/amd64"].result_path=$path' "$CASE/checkpoint.json" > "$CASE/revised-state.json" ;;
        missing) jq 'del(.context.source_sync,.source_sync_history,.target_statuses)' "$CASE/checkpoint.json" > "$CASE/revised-state.json" ;;
        changed|removed)
            local transform='.sibling_crates[0].revision=("f"*40)'
            [[ "$1" != removed ]] || transform='.sibling_crates=[]'
            jq "$transform" "$ACT_REPOS_DIR/tool.yaml" > "$CASE/changed-config.json"
            mv "$CASE/changed-config.json" "$ACT_REPOS_DIR/tool.yaml" ;;
    esac
    [[ ! -f "$CASE/revised-state.json" ]] || mv "$CASE/revised-state.json" "$CASE/checkpoint.json"
    run_fallback --expected-sha "$SOURCE_SHA" --isolate-source --resume
    if [[ "$1" == matching || "$1" == partial || "$1" == variants || "$1" == pending ]]; then
        [[ "$RC" == 0 ]] && one_result || return 1
        if [[ "$1" == partial || "$1" == pending ]]; then grep -q '^BUILD ' "$CALLS"
        else ! grep -q '^BUILD ' "$CALLS"; fi
    else
        [[ "$RC" == 4 ]] && one_result && blocked && ! grep -q '^CHECK\|^BUILD ' "$CALLS"
    fi
}

test_isolated_source_sync_paths() {
    setup "isolated-sync-$1"; isolated_fixture || return 1
    mkdir -p "$CASE/original-dependency" "$CASE/private-dependency" "$CASE/remote/source"
    printf 'dirty original\n' > "$CASE/original-dependency/src.txt"
    printf 'pinned bytes\n' > "$CASE/private-dependency/src.txt"
    printf '[dependencies]\nlocal = { path = "%s" }\n' "$CASE/original-dependency" > "$CASE/remote/source/Cargo.toml"
    jq --arg path "$CASE/original-dependency" '.sibling_crates=[{relative_path:"dependency",local_path:$path}]' \
        "$ACT_REPOS_DIR/tool.yaml" > "$CASE/sync-config.json"
    mv "$CASE/sync-config.json" "$ACT_REPOS_DIR/tool.yaml"
    local _ACT_ISOLATED_SOURCE_TOOL=tool _ACT_ISOLATED_SOURCE_PATHS
    _ACT_ISOLATED_SOURCE_PATHS=$(jq -nc --arg old "$CASE/original-dependency" --arg new "$CASE/private-dependency" '{($old):$new}')
    _act_is_windows_host() { [[ "$1" == windows ]]; }
    _act_windows_encoded_powershell() { printf '%s\n' "$1"; }
    _act_sync_source() { cp -a "$2" "$3"; }
    _act_ssh_exec() {
        printf '%s\n' "$2" > "$CASE/patch-command"
        [[ "$1" == windows ]] || bash -c "$2"
    }
    _act_sync_sibling_crates "$1" "$CASE/remote/source" "$ACT_REPOS_DIR/tool.yaml" 1 || return 1
    [[ "$(cat "$CASE/remote/dependency/src.txt")" == 'pinned bytes' ]] || return 1
    if [[ "$1" == windows ]]; then
        grep -Fq ".Replace('$CASE/original-dependency','../dependency')" "$CASE/patch-command"
    else
        grep -Fq 'path = "../dependency"' "$CASE/remote/source/Cargo.toml"
    fi
}

test_isolated_source_fetch() {
    setup "isolated-fetch-$1"; isolated_fixture || return 1
    # The transport boundary substitutes a local Git server, while real fetch,
    # pack validation, tag peeling, checkout, and source checks still execute.
    mv "$CASE/source" "$CASE/remote"
    if [[ "$1" == mismatch ]]; then
        git -C "$CASE/remote" -c user.name=Fixture -c user.email=fixture@example.invalid \
            commit --allow-empty -qm moved || return 1
        git -C "$CASE/remote" tag -f v1.2.3 >/dev/null || return 1
    fi
    FETCH_MODE="$1"
    git() {
        local -a arguments=("$@")
        local index
        for index in "${!arguments[@]}"; do
            if [[ "${arguments[$index]}" == https://github.com/owner/tool.git ]]; then
                printf 'FETCH_URL %s\n' "${arguments[$index]}" >> "$CALLS"
                [[ "$FETCH_MODE" != unavailable ]] || return 1
                arguments[$index]="$CASE/remote"
                command git -c protocol.file.allow=always "${arguments[@]}"
                return $?
            fi
        done
        command git "$@"
    }
    run_fallback --expected-sha "$SOURCE_SHA" --isolate-source
    [[ ! -e "$CASE/source" ]] && grep -q '^FETCH_URL https://github.com/owner/tool.git$' "$CALLS" || return 1
    case "$1" in
        mismatch) [[ "$RC" == 4 ]] && blocked && ! grep -q '^CHECK ' "$CALLS" ;;
        unavailable) [[ "$RC" == 8 ]] && blocked && ! grep -q '^CHECK ' "$CALLS" ;;
        *) [[ "$RC" == 0 ]] && one_result && jq -e \
            '.details.source_materialization.transport == "github"' "$CASE/stdout" >/dev/null ;;
    esac
}

test_isolated_source_plan_and_arguments() {
    setup "isolated-plan-$1"; isolated_fixture || return 1
    printf 'developer edit\n' >> "$CASE/source/src.txt"
    if [[ "$1" == dry ]]; then
        run_fallback --expected-sha "$SOURCE_SHA" --isolate-source --dry-run
        [[ "$RC" == 0 && ! -s "$CALLS" && ! -e "$DSR_STATE_DIR" ]] && one_result &&
            jq -e '.status == "dry_run" and .details.isolated_source and .details.source_materialization == null' \
                "$CASE/stdout" >/dev/null
    else
        run_fallback --isolate-source
        [[ "$RC" == 4 && ! -e "$DSR_STATE_DIR" ]] && ! grep -q '^BUILD\|^CHECK\|^LOCK' "$CALLS"
    fi
}

run_test test_success
for rc in 1 2 3 4 5 6 8 130 143; do run_test test_build_failure "$rc"; done
for mode in missing malformed multiple empty partial wrong-tool wrong-version duplicate unsafe diagnostic corrupt absent symlink manifest-link hash-failure extra-payload; do
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
for mode in draft missing-visibility wrong-tag wrong-repo malformed; do run_test test_release_requires_public_confirmation "$mode"; done
run_test test_release_public_confirmation_completes
run_test test_resume_reaches_build
run_test test_preserves_caller_state
run_test test_signal_releases_lock checks
run_test test_signal_releases_lock build
for arg in --tool --version --output-dir --unknown; do run_test test_invalid_argument "$arg"; done
run_test test_invalid_argument --resume=unsafe
run_test test_completed_resume true
run_test test_completed_resume false
run_test test_completed_default_output
run_test test_completed_task_plan matching
run_test test_completed_task_plan drift
for drift in source targets output run manifest-sha payload quality-source; do run_test test_completed_rejects_drift "$drift"; done
for mode in missing malformed cancelled diagnostic selected; do run_test test_invalid_checkpoint "$mode"; done
run_test test_signature_resume
for mode in existing-corrupt existing-symlink missing corrupt mutate manifest; do run_test test_signature_failure "$mode"; done
run_test test_release_scan_failure
for rc in 5 130 143; do run_test test_signing_interruption "$rc"; done
run_test test_unusable_signing_key_blocks_release
run_test test_missing_signing_key_releases_unsigned_loudly
run_test test_signing_disabled_by_config_is_quiet
for mode in fresh resume build-only; do run_test test_expected_source_success "$mode"; done
for mode in branch-only missing-tag wrong-sha head-moved dirty staged untracked; do
    run_test test_expected_source_initial_refusal "$mode"
done
for mode in quality build manifest signing tag; do run_test test_expected_source_drift "$mode"; done
for mode in mismatch unavailable source tag; do run_test test_expected_remote_tag_refusal "$mode"; done
for mode in missing empty short zero duplicate version; do run_test test_expected_source_argument_refusal "$mode"; done
for mode in flag config resume build-only; do run_test test_isolated_source_preserves_checkout "$mode"; done
run_test test_isolated_source_retries_fresh
for mode in pinned unpinned mutated absolute; do run_test test_isolated_source_pinned_siblings "$mode"; done
for mode in quality build signing; do run_test test_isolated_source_drift "$mode"; done
for mode in absolute quoted hidden relative; do run_test test_isolated_source_cargo_paths "$mode"; done
for mode in matching partial variants pending changed removed history embedded sidecar missing; do run_test test_isolated_source_sibling_resume "$mode"; done
for mode in unix windows; do run_test test_isolated_source_sync_paths "$mode"; done
for mode in valid mismatch unavailable; do run_test test_isolated_source_fetch "$mode"; done
for mode in dry arguments; do run_test test_isolated_source_plan_and_arguments "$mode"; done
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
