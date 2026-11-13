#!/usr/bin/env bash
# Exercise the actual fallback command and release hash/purpose guards against
# real files. Build hosts, signing, notifications and network publication are
# controllable boundaries; this suite does not execute external releases.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# Completed-checkpoint admission uses the task planner and its configuration
# dependencies. Load the same modules as the CLI; extracting the planner alone
# would omit workflow-payload admission and turn valid resumes into fixture errors.
# shellcheck source=src/config.sh
source "$ROOT/src/config.sh"
# shellcheck source=src/act_runner.sh
source "$ROOT/src/act_runner.sh"
# Keep recipe admission real in the lightweight fixtures too; their state
# transport boundaries below do not replace the retained-config validator.
# shellcheck source=src/build_state.sh
source "$ROOT/src/build_state.sh"
# Keep inventory admission real even though cryptographic signing is a
# controlled boundary below. Sourcing the module does not generate any key.
# shellcheck source=src/signing.sh
source "$ROOT/src/signing.sh"
# shellcheck source=src/git_ops.sh
source "$ROOT/src/git_ops.sh"
# shellcheck source=src/sbom.sh
source "$ROOT/src/sbom.sh"
# Admission uses the real attempt-pinned job reader; only gh_api responses
# are controlled in the focused watcher-origin fixtures below.
# shellcheck source=src/github.sh
source "$ROOT/src/github.sh"
COMMAND_FILE="${DSR_TEST_COMMAND_FILE:-$ROOT/dsr}"
HELPERS_FILE="${DSR_TEST_HELPERS_FILE:-$COMMAND_FILE}"
# shellcheck source=/dev/null
source <(awk '/^(_release_file_size|_release_sha256|_release_require_publishable_artifacts|_release_sbom_policy|_check_configured_repos|_check_waiting_jobs|_watch_configured_repo_matches|_watch_validate_admission_json|_watch_admit_upstream)\(\) \{/{copy=1} copy{print} copy && /^\}/{copy=0}' "$HELPERS_FILE")
# shellcheck source=/dev/null
source <(awk '/^cmd_fallback\(\) \{/{copy=1} copy{print} copy && /^\}/{exit}' "$COMMAND_FILE")
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
_dsr_require() { :; }
config_load() { :; }
config_get() { printf '%s\n' "${2:-}"; }
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
    if [[ "$THROTTLE_RC" == 1 ]]; then
        printf '{"repo":"%s","status":"throttled","queued_count":1,"stuck_in_progress_count":0}\n' "$1"
    else
        jq -nc --arg repo "$1" --argjson rc "$THROTTLE_RC" '
            {repo:$repo,status:(if $rc == 0 then "ok" else "error" end),queued_count:0,stuck_in_progress_count:0} |
            if $rc == 5 then . + {error:"workflow job inspection interrupted"}
            elif $rc != 0 then . + {error:"failed to fetch runs"} else . end'
    fi
    return "$THROTTLE_RC"
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
    if [[ -n "${QUALITY_MUTATES_PINNED_CHILD:-}" ]]; then
        printf 'mutated child\n' >> "${quality_source%/*}/$QUALITY_MUTATES_PINNED_CHILD"
    fi
    if [[ "${WATCH_ADMISSION_TRANSITION:-}" == quality ]]; then
        watch_admission_complete_upstream || return 1
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
        if [[ "$SIGN_MODE" == submodule ]]; then printf 'mutated by signer\n' >> "$(act_get_local_path tool)/vendor/library/src.txt"; fi
        if [[ "$SIGN_MODE" == tag ]]; then git -C "$(act_get_local_path tool)" tag -f v1.2.3 "$OTHER_SHA" >/dev/null; fi
    fi
    if [[ "${WATCH_ADMISSION_TRANSITION:-}" == signing ]]; then
        watch_admission_complete_upstream || return 1
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
        if [[ "${_ACT_ISOLATED_SOURCE_IDENTITY:-null}" != null ]] &&
           act_platform_uses_act tool linux/amd64; then
            local sync tasks source_plan source_layout=null
            # Exercise the real act-only synchronization and per-target
            # receipt producers. The fixture compiler remains the boundary.
            tasks=$(_act_build_task_plan tool 1.2.3 '["linux/amd64","darwin/arm64"]' false) || return 4
            sync=$(act_sync_sources tool --stage-ordinary -- linux/amd64 darwin/arm64) || return 4
            sync=$(_act_validate_source_sync_receipt "$sync" "$tasks") || return 4
            printf '%s\n' "$sync" > "$CASE/build-source-sync.json"
            _act_target_source_sync_json "$sync" act > "$CASE/build-target-source-sync.json" || return 4
            source_plan=$(_act_source_plan_for_tool tool linux/amd64) || return 4
            if [[ "$source_plan" != null ]]; then
                _act_load_source_layout || return 4
                source_layout=$(act_source_materialize "$source_plan" "$CASE/workflow-sources") || return 4
                # Both fixture targets select this one literal workflow job.
                # Preserve the real projection evidence rather than inventing
                # a successful source-layout receipt at the compiler boundary.
                jq -e --argjson identity "$(jq -c .identity <<< "$source_layout")" \
                    'all(.[]; .workflow_source == $identity)' <<< "$tasks" >/dev/null || return 4
            fi
            printf '%s\n' "$tasks" > "$CASE/build-tasks.json"
            printf '%s\n' "$source_layout" > "$CASE/build-source-layout.json"
        fi
    fi
    local out="" arg
    while (($#)); do
        arg="$1"; shift
        if [[ "$arg" == --output-dir ]]; then out="$1"; shift; fi
    done
    if [[ "$CONTRACT" != null && -e "$out" ]]; then return 4; fi
    mkdir -p "$out" || return 4
    printf 'daemon bytes\n' > "$out/daemon"
    if [[ -n "${BUILD_FROM_PINNED_CHILD:-}" ]]; then
        local selected_source selected_child
        selected_source=$(act_get_local_path tool) || return 4
        selected_child="${selected_source%/*}/$BUILD_FROM_PINNED_CHILD"
        # A shell fixture build embeds actual selected Git metadata and source
        # bytes in its artifact. It does not claim native compiler execution.
        git -C "$selected_child" rev-parse HEAD > "$out/daemon" || return 4
        cat "$selected_child/src.txt" >> "$out/daemon" || return 4
    fi
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
    if [[ -n "${BUILD_MUTATES_PINNED_CHILD:-}" ]]; then
        local private_source
        private_source=$(act_get_local_path tool) || return 4
        printf 'mutated by build\n' >> "${private_source%/*}/$BUILD_MUTATES_PINNED_CHILD"
    fi
    printf '{"child":"build"}\n'
    if [[ "$SIGNAL_PHASE" == build ]]; then kill -TERM "$BASHPID"; fi
    if [[ "${WATCH_ADMISSION_TRANSITION:-}" == build ]]; then
        watch_admission_complete_upstream || return 1
    fi
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
    INIT_RC=0 LOCK_RC=0 UNLOCK_RC=0 QUALITY_RC=0 BUILD_RC=0 SIGN_RC=0 RELEASE_RC=0 CONFIG_RC=0 THROTTLE_RC=1
    CONTRACT=null SIGN_ENABLED=true SIGN_WANTED=true MANIFEST_MODE=valid SIGNAL_PHASE=""
    export SIGNING_PRIVATE_KEY="$CASE/keys/minisign.key" SIGNING_PUBLIC_KEY="$CASE/keys/minisign.pub"
    SIGN_MODE=valid SCAN_RC=0 RELEASE_EXISTS=false QUALITY_MUTATES_SOURCE=false BUILD_MUTATES_SOURCE=false
    QUALITY_MUTATES_SIBLING=false
    QUALITY_MUTATES_PINNED_CHILD='' BUILD_MUTATES_PINNED_CHILD=''
    BUILD_FROM_PINNED_CHILD=''
    OTHER_SHA="" REMOTE_TAG_MODE=valid RELEASE_RESULT_MODE=public
    WATCH_ADMISSION_TRANSITION="" WATCH_HTTP_DRIFT="" WATCH_HTTP_RC=0
    RUN=11111111-1111-4111-8111-111111111111 SOURCE_SHA=0000000000000000000000000000000000000000
    TARGETS='linux/amd64 darwin/arm64'
    OUT="$CASE/artifacts"
}
checkpoint() {
    local recipe_digest
    recipe_digest=$(_release_sha256 "$ACT_REPOS_DIR/tool.yaml") || return 1
    jq -nc --arg status "$1" --arg sha "$SOURCE_SHA" --arg run "$RUN" --arg out "$OUT" \
        --arg recipe "$recipe_digest" '
        {tool:"tool",version:"1.2.3",run_id:$run,status:$status,git_sha:$sha,
         targets:["linux/amd64","darwin/arm64"],
         context:{output_dir:$out,build_purpose:"release",publishable:true,
                  repo_config_sha256:$recipe}}' > "$CASE/checkpoint.json"
}
completed_fixture() {
    git -C "$CASE/source" init -q
    printf 'source code\n' > "$CASE/source/src.txt"
    git -C "$CASE/source" add src.txt
    if [[ "${1:-}" == workflow ]]; then
        mkdir -p "$CASE/source/.github/workflows" || return 1
        cat > "$CASE/source/.github/workflows/release.yml" <<'YAML'
name: Fixture release
on: workflow_dispatch
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: test -f src.txt
YAML
        git -C "$CASE/source" add .github/workflows/release.yml || return 1
    fi
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
test_throttle_check_interruption() {
    setup interrupted-throttle
    THROTTLE_RC=5 QUALITY_MUTATES_SOURCE=true
    printf 'original source\n' > "$CASE/source/src.txt"
    run_fallback
    [[ "$RC" == 5 && ! -e "$OUT" && ! -e "$CASE/lock" &&
       ! -e "$DSR_STATE_DIR/fallback-sources" && "$(cat "$CASE/source/src.txt")" == 'original source' ]] &&
        one_result && ! grep -Eq '^(CHECK|BUILD|SIGN|RELEASE) ' "$CALLS" &&
        grep -q '^UNLOCK ' "$CALLS" &&
        jq -e '.status == "error" and .details.phase == "check" and
            .details.phases.build == "blocked" and .details.phases.release == "blocked" and
            [.details.steps[] | [.command,.status,.exit_code]] == [["check","error",5]]' \
            "$CASE/stdout" >/dev/null
}
test_throttle_check_manual_request() {
    setup "manual-throttle-$1"
    THROTTLE_RC="$1"
    run_fallback
    [[ "$RC" == 0 && ! -e "$CASE/lock" ]] && one_result &&
        grep -q '^CHECK ' "$CALLS" && grep -q '^BUILD ' "$CALLS" && grep -q '^RELEASE ' "$CALLS" &&
        jq -e --argjson rc "$1" '.details.phases.release == "success" and
            .details.steps[0].exit_code == $rc and
            .details.steps[0].status == (if $rc == 0 then "success" else "error" end) and
            (.details.trigger | startswith("manual:"))' "$CASE/stdout" >/dev/null
}
# Watcher-origin fallbacks must keep the exact upstream attempt eligible while
# source preparation, checks and compilation run. Admission and job parsing stay
# real; only the GitHub HTTP boundary supplies controlled observations.
watch_admission_update_json() {
    local file="$1" filter="$2"
    jq "$filter" "$file" > "$file.next" && mv "$file.next" "$file"
}
watch_admission_complete_upstream() {
    watch_admission_update_json "$CASE/watch-run.json" '.status="completed" | .conclusion="success"'
}
watch_admission_fixture() {
    setup "watch-admission-$1"
    git -C "$CASE/source" init -q || return 1
    printf 'source code\n' > "$CASE/source/src.txt"
    git -C "$CASE/source" add src.txt || return 1
    git -C "$CASE/source" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm source || return 1
    git -C "$CASE/source" tag v1.2.3 || return 1
    SOURCE_SHA=$(git -C "$CASE/source" rev-parse HEAD) || return 1
    export DSR_CONFIG_DIR="$CASE" DSR_REPOS_FILE="$CASE/repos.yaml"
    jq -nc --arg path "$CASE/source" '
        {tool_name:"tool",repo:"owner/tool",local_path:$path,enabled:true,
         language:"go",binary_name:"tool",workflow:"release.yml",
         targets:["linux/amd64","darwin/arm64"]}' > "$ACT_REPOS_DIR/tool.yaml" || return 1
    WATCH_ADMISSION=$(jq -nc --arg sha "$SOURCE_SHA" '
        {run_id:"12345",run_attempt:2,workflow_id:17,repo:"owner/tool",
         version:"v1.2.3",git_sha:$sha,reason:"throttled",threshold_seconds:600}') || return 1
    jq -nc --arg sha "$SOURCE_SHA" '
        {id:12345,repository:{full_name:"owner/tool"},head_branch:"v1.2.3",
         head_sha:$sha,status:"queued",conclusion:null,run_attempt:2,workflow_id:17,
         path:".github/workflows/release.yml",event:"push",
         created_at:"2000-01-01T00:00:00Z",run_started_at:"2000-01-01T00:00:00Z"}' \
        > "$CASE/watch-run.json" || return 1
    jq -nc --arg sha "$SOURCE_SHA" '
        {total_count:1,jobs:[{id:1,run_id:12345,run_attempt:2,head_sha:$sha,
          status:"queued",created_at:"2000-01-01T00:00:00Z",
          started_at:null,completed_at:null}]}' > "$CASE/watch-jobs.json" || return 1
    gh_api() {
        printf 'UPSTREAM %s\n' "$*" >> "$CALLS"
        [[ $# == 2 && "$2" == --no-cache ]] || return 99
        case "$1" in
            repos/owner/tool/actions/runs/12345)
                [[ "$WATCH_HTTP_RC" == 0 ]] || return "$WATCH_HTTP_RC"
                cat "$CASE/watch-run.json" ;;
            'repos/owner/tool/actions/runs/12345/attempts/2/jobs?per_page=100&page=1')
                cat "$CASE/watch-jobs.json" || return 1
                if [[ "$WATCH_HTTP_DRIFT" == attempt ]]; then
                    watch_admission_update_json "$CASE/watch-run.json" '.run_attempt=3' || return 1
                fi ;;
            *) return 99 ;;
        esac
    }
}
test_watch_admission_success() {
    watch_admission_fixture "success-$1" || return 1
    if [[ "$1" != throttled ]]; then
        WATCH_ADMISSION=$(jq '.reason="upstream_failure" | .threshold_seconds=0' <<< "$WATCH_ADMISSION") || return 1
        watch_admission_update_json "$CASE/watch-run.json" \
            ".status=\"completed\" | .conclusion=\"$1\"" || return 1
    fi
    run_fallback --expected-sha "$SOURCE_SHA" --watch-admission "$WATCH_ADMISSION"
    [[ "$RC" == 0 && ! -e "$CASE/lock" ]] && one_result &&
        grep -q '^CHECK ' "$CALLS" && grep -q '^BUILD ' "$CALLS" &&
        grep -q '^SIGN ' "$CALLS" && grep -q '^RELEASE ' "$CALLS" &&
        ! grep -q '^THROTTLE ' "$CALLS" &&
        grep -q '^UPSTREAM repos/owner/tool/actions/runs/12345 --no-cache$' "$CALLS" || return 1
    if [[ "$1" == throttled ]]; then
        grep -Fq 'UPSTREAM repos/owner/tool/actions/runs/12345/attempts/2/jobs?per_page=100&page=1 --no-cache' "$CALLS"
    else
        ! grep -q '/jobs?' "$CALLS"
    fi
}
test_watch_admission_initial_refusal() {
    watch_admission_fixture "initial-$1" || return 1
    local expected_rc=2
    case "$1" in
        success) watch_admission_complete_upstream || return 1 ;;
        cancelled) watch_admission_update_json "$CASE/watch-run.json" '.status="completed" | .conclusion="cancelled"' || return 1 ;;
        failed) watch_admission_update_json "$CASE/watch-run.json" '.status="completed" | .conclusion="failure"' || return 1 ;;
        active) watch_admission_update_json "$CASE/watch-jobs.json" '.jobs[0].status="in_progress"' || return 1 ;;
        waiting) watch_admission_update_json "$CASE/watch-jobs.json" '.jobs[0].status="waiting"' || return 1 ;;
        recent) watch_admission_update_json "$CASE/watch-jobs.json" '.jobs[0].created_at=(now | todateiso8601)' || return 1 ;;
        attempt) expected_rc=4; watch_admission_update_json "$CASE/watch-run.json" '.run_attempt=3' || return 1 ;;
        workflow) expected_rc=4; watch_admission_update_json "$CASE/watch-run.json" '.workflow_id=18' || return 1 ;;
        source) expected_rc=4; watch_admission_update_json "$CASE/watch-run.json" '.head_sha=("f"*40)' || return 1 ;;
        disabled) watch_admission_update_json "$ACT_REPOS_DIR/tool.yaml" '.enabled=false' || return 1 ;;
        unreadable) expected_rc=8; WATCH_HTTP_RC=8 ;;
        interrupted) expected_rc=5; WATCH_HTTP_RC=130 ;;
        jobs-rerun) expected_rc=4; WATCH_HTTP_DRIFT=attempt ;;
        *) return 1 ;;
    esac
    run_fallback --expected-sha "$SOURCE_SHA" --isolate-source --watch-admission "$WATCH_ADMISSION"
    [[ "$RC" == "$expected_rc" && ! -e "$OUT" && ! -e "$CASE/lock" &&
       ! -e "$DSR_STATE_DIR/fallback-sources" ]] && one_result &&
        ! grep -Eq '^(INIT|LOCK|CHECK|BUILD|SIGN|RELEASE)( |$)' "$CALLS" &&
        jq -e '.details.phase=="admission" and .details.phases.release=="blocked"' "$CASE/stdout" >/dev/null || return 1
    if [[ "$1" == jobs-rerun ]]; then
        [[ "$(grep -c '^UPSTREAM repos/owner/tool/actions/runs/12345 --no-cache$' "$CALLS")" == 2 ]] &&
            grep -Fq 'UPSTREAM repos/owner/tool/actions/runs/12345/attempts/2/jobs?per_page=100&page=1 --no-cache' "$CALLS"
    fi
}
test_watch_admission_late_refusal() {
    watch_admission_fixture "late-$1" || return 1
    WATCH_ADMISSION_TRANSITION="$1"
    run_fallback --expected-sha "$SOURCE_SHA" --watch-admission "$WATCH_ADMISSION"
    [[ "$RC" == 2 && ! -e "$CASE/lock" ]] && one_result &&
        grep -q '^CHECK ' "$CALLS" && ! grep -q '^RELEASE ' "$CALLS" &&
        jq -e '.details.phase=="admission" and .details.phases.release=="blocked"' "$CASE/stdout" >/dev/null || return 1
    if [[ "$1" == quality ]]; then
        ! grep -Eq '^(BUILD|SIGN) ' "$CALLS" && [[ ! -e "$OUT" ]]
    else
        jq -e '[.details.steps[] | select(.command=="release") | {status,exit_code}] ==
            [{status:"error",exit_code:2}]' "$CASE/stdout" >/dev/null &&
            grep -q '^BUILD ' "$CALLS" &&
            [[ "$(cat "$OUT/daemon")" == 'daemon bytes' && "$(cat "$OUT/worker")" == 'worker bytes' ]] &&
            jq -e --arg sha "$(_release_sha256 "$OUT/daemon")" --arg source "$SOURCE_SHA" \
                '.source.git_sha==$source and any(.artifacts[]; .name=="daemon" and .sha256==$sha)' \
                "$OUT/tool-v1.2.3-manifest.json" >/dev/null || return 1
        if [[ "$1" == signing ]]; then
            grep -q '^SIGN ' "$CALLS" && signing_verify "$OUT/daemon" && signing_verify "$OUT/worker"
        fi
    fi
}
test_watch_admission_arguments() {
    watch_admission_fixture "arguments-$1" || return 1
    local admission="$WATCH_ADMISSION"
    case "$1" in
        missing-field) admission=$(jq 'del(.run_attempt)' <<< "$admission") || return 1 ;;
        extra-field) admission=$(jq '.unexpected=true' <<< "$admission") || return 1 ;;
        fractional-attempt) admission=$(jq '.run_attempt=1.5' <<< "$admission") || return 1 ;;
        wrong-repo) admission=$(jq '.repo="owner/other"' <<< "$admission") || return 1 ;;
        bad-reason) admission=$(jq '.reason="manual"' <<< "$admission") || return 1 ;;
        bad-threshold) admission=$(jq '.threshold_seconds=0' <<< "$admission") || return 1 ;;
        missing-expected)
            run_fallback --watch-admission "$admission"
            [[ "$RC" == 4 && ! -s "$CALLS" && ! -e "$DSR_STATE_DIR" ]] && return 0
            return 1 ;;
        build-only)
            run_fallback --expected-sha "$SOURCE_SHA" --watch-admission "$admission" --build-only
            [[ "$RC" == 4 && ! -s "$CALLS" && ! -e "$DSR_STATE_DIR" ]] && return 0
            return 1 ;;
        *) return 1 ;;
    esac
    run_fallback --expected-sha "$SOURCE_SHA" --watch-admission "$admission"
    [[ "$RC" == 4 && ! -s "$CALLS" && ! -e "$OUT" && ! -e "$DSR_STATE_DIR" ]]
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
    # Strict publication custody uses the real producer/finalizer in the
    # strict recovery suite. Here verify fresh build output and signer ownership.
    setup strict; CONTRACT='{"checksum_sidecar":"sha256"}'; run_fallback --build-only
    [[ "$RC" == 0 && ! -e "$CASE/lock" ]] && one_result && ! grep -q '^SIGN ' "$CALLS"
}
test_sbom_forwarding() {
    setup sbom; run_fallback --sbom --sbom-format spdx-json
    [[ "$RC" == 0 ]] && one_result &&
        grep -Fq -- '--sbom --sbom-format spdx-json' "$CALLS"
}
test_strict_sbom_refusal() {
    setup strict-sbom; CONTRACT='{"checksum_sidecar":"sha256"}'; run_fallback --sbom
    [[ "$RC" == 4 && ! -e "$OUT" && ! -e "$DSR_STATE_DIR" && ! -s "$CALLS" ]]
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

# The public build command must produce the partial checkpoint consumed by the
# public fallback command. Keep source staging, Git bundles, worker dispatch,
# state/locks, artifact hashing, collection and final manifests real. Native
# payloads, host health/slots and notifications are controlled boundaries; this
# is resume integration coverage, not compiler or host-readiness qualification.
# Run alone with DSR_TEST_FILTER=test_partial_resume_real_workers.
test_partial_resume_real_workers() {
    local dependency
    for dependency in python3 git jq yq rsync tar gzip; do
        command -v "$dependency" >/dev/null || {
            printf 'Missing partial-resume test dependency: %s\n' "$dependency" >&2
            return 1
        }
    done
    python3 - "$ROOT" "$COMMAND_FILE" "$TEST_ROOT" <<'PY'
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

project, command, parent = map(Path, sys.argv[1:])
root = parent / 'partial-real-workers'
root.mkdir()
print('Retained public partial-resume fixture: ' + str(root), flush=True)
checks = failures = 0
targets = ['linux/amd64', 'linux/arm64']


def check(label, valid):
    global checks, failures
    checks += 1
    failures += not valid
    print(('PASS: ' if valid else 'FAIL: ') + label, flush=True)
    return valid


def read(path):
    return json.loads(path.read_text())


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def events(case):
    path = case / 'events.jsonl'
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


payload = root / 'payload.py'
payload.write_text(r'''import json, os, sys
from pathlib import Path
case, platform, attempt = Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])
assert sys.stdin.buffer.read() == b''
fd = os.open(case / 'events.jsonl', os.O_APPEND | os.O_CREAT | os.O_WRONLY, 0o600)
os.write(fd, (json.dumps(dict(platform=platform,attempt=attempt,pid=os.getpid()))+'\n').encode())
os.close(fd)
if platform == 'linux/arm64' and not (case / 'repaired').exists():
    print(json.dumps(dict(platform=platform,method='native',host='fixturehost',
                         status='failed',exit_code=17,error='deliberate payload failure')),flush=True)
    raise SystemExit(17)
path = case / 'payloads' / ('tool-' + platform.replace('/', '-') + '.attempt-' + str(attempt) + '.bin')
with path.open('xb') as out:
    out.write(('release payload for '+platform+'\n').encode())
print(json.dumps(dict(platform=platform,method='native',host='fixturehost',status='success',
                     exit_code=0,artifact_path=str(path),artifact_paths=[str(path)])),flush=True)
''')

driver = root / 'driver.sh'
driver.write_text(r'''#!/usr/bin/env bash
set -uo pipefail
for module in logging config build_state act_runner artifact_naming git_ops packaging sbom signing slsa; do
    source "$PARTIAL_PROJECT/src/$module.sh" || exit 1
done
export SCRIPT_DIR="$PARTIAL_PROJECT" JSON_MODE=true DRY_RUN=false VERBOSE=false DSR_VERSION=fixture
declare -A _DSR_LOADED_MODULES=([packaging]=1 [artifact_naming]=1 [sbom]=1 [signing]=1)
# Load exact public definitions, as the native artifact integration suite does.
# No replacement cmd_build, fallback, state updater, collector or resume planner.
source <(awk '/^(_dsr_require|cmd_build|cmd_fallback|_release_file_size|_release_sha256|_release_require_publishable_artifacts|_release_sbom_policy)\(\) \{/{copy=1} copy{print} copy && /^\}/{copy=0}' "$PARTIAL_COMMAND") || exit 1
source <(awk '/^json_envelope\(\) \{/{copy=1} copy{print} copy && /^# ====/{exit}' "$PARTIAL_COMMAND") || exit 1
selector_acquire_slot() { printf 'SLOT %s\n' "$*" >> "$PARTIAL_CASE/boundaries"; }
selector_release_slot() { :; }
host_health_is_ready() { printf 'READINESS %s\n' "$*" >> "$PARTIAL_CASE/boundaries"; }
act_run_native_build() { python3 "$PARTIAL_PAYLOAD" "$PARTIAL_CASE" "$2" "$attempt"; }
notify_event() { printf 'NOTIFY %s\n' "$*" >> "$PARTIAL_CASE/boundaries"; }
qg_run_checks() {
    printf 'CHECK %s\n' "$*" >> "$PARTIAL_CASE/boundaries"
    [[ "$(git -C "$PARTIAL_CASE/source" rev-parse HEAD)" == "$PARTIAL_SHA" ]]
}
signing_is_enabled() { return 1; }
signing_wanted() { return 1; }
cmd_release() {
    if [[ "$PARTIAL_MODE" != publish && "$PARTIAL_MODE" != publish-isolated ]]; then
        printf 'UNEXPECTED_PUBLICATION %s\n' "$*" >> "$PARTIAL_CASE/boundaries"
        return 7
    fi
    printf 'PUBLISH %s\n' "$*" >> "$PARTIAL_CASE/boundaries"
    printf '%s\n' '{"command":"release","status":"success","exit_code":0,"details":{"repo":"fixture/tool","tag":"v1.2.3","release_id":91,"draft":false}}'
}
_check_repo() {
    if [[ "$PARTIAL_MODE" != publish && "$PARTIAL_MODE" != publish-isolated ]]; then
        printf 'UNEXPECTED_NETWORK %s\n' "$*" >> "$PARTIAL_CASE/boundaries"
        return 8
    fi
    printf 'THROTTLE %s\n' "$*" >> "$PARTIAL_CASE/boundaries"
    printf '%s\n' '{"queued_count":0,"stuck_in_progress_count":0}'
}
_release_contract_scan_release_by_tag() {
    printf 'RELEASE_SCAN %s\n' "$*" >> "$PARTIAL_CASE/boundaries"
    printf '%s\n' '{"count":0,"release":null}'
}
gh_resolve_tag_sha() {
    printf 'REMOTE_TAG %s\n' "$*" >> "$PARTIAL_CASE/boundaries"
    printf '%s\n' "$PARTIAL_SHA"
}
case "$PARTIAL_MODE" in
    first)
        cmd_build tool --version 1.2.3 --no-sync --jobs "$PARTIAL_JOBS" --output-dir "$PARTIAL_CASE/output" ;;
    plan)
        build_state_init && build_state_resume tool 1.2.3 "$PARTIAL_RUN" ;;
    status)
        build_state_init && build_state_update_status tool 1.2.3 "$PARTIAL_STATUS" "$PARTIAL_RUN" ;;
    resume)
        cmd_fallback tool --version 1.2.3 --expected-sha "$PARTIAL_SHA" --build-only \
            --resume="$PARTIAL_RUN" --output-dir "$PARTIAL_CASE/output" ;;
    publish|publish-isolated)
        isolation=()
        [[ "$PARTIAL_MODE" != publish-isolated ]] || isolation+=(--isolate-source)
        cmd_fallback tool --version 1.2.3 --expected-sha "$PARTIAL_SHA" \
            --resume="$PARTIAL_RUN" --output-dir "$PARTIAL_CASE/output" "${isolation[@]}" ;;
    lease)
        build_state_init && build_lock_acquire tool v1.2.3 &&
            build_lock_release tool v1.2.3 && printf '%s\n' '{"available":true}' ;;
esac
''')


def fixture(name, jobs):
    case = root / name
    for directory in ('config/repos.d', 'source', 'state', 'cache', 'payloads'):
        (case / directory).mkdir(parents=True)
    (case / 'source/source.txt').write_text('fixture release source\n')
    for args in (['init', '-q', '-b', 'main'], ['add', '.'],
                 ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                  '-c', 'commit.gpgsign=false', 'commit', '-qm', 'fixture'], ['tag', 'v1.2.3']):
        subprocess.run(['git', '-C', str(case / 'source')] + args, check=True)
    sha = subprocess.check_output(['git', '-C', str(case / 'source'), 'rev-parse', 'HEAD'], text=True).strip()
    (case / 'config/config.yaml').write_text('schema_version: "1.0.0"\n')
    (case / 'config/repos.yaml').write_text('tools: {}\n')
    (case / 'config/hosts.yaml').write_text(json.dumps({
        'schema_version': '1.0.0', 'hosts': {'fixturehost': {'platform': 'linux/amd64',
        'connection': 'local', 'concurrency': 2, 'build_root': str(case / 'stages')}},
        'platform_mapping': {target: 'fixturehost' for target in targets}}))
    (case / 'config/repos.d/tool.yaml').write_text(json.dumps({
        'tool_name': 'tool', 'repo': 'fixture/tool', 'local_path': str(case / 'source'),
        'language': 'go', 'binary_name': 'tool', 'build_cmd': 'fixture payload process',
        'targets': targets, 'act_job_map': {target: None for target in targets},
        'cross_compile': {target: {'host': 'fixturehost'} for target in targets}}))
    env = dict(os.environ, PARTIAL_PROJECT=str(project), PARTIAL_COMMAND=str(command), PARTIAL_CASE=str(case),
        PARTIAL_PAYLOAD=str(payload), PARTIAL_JOBS=str(jobs), PARTIAL_SHA=sha,
        DSR_CONFIG_DIR=str(case / 'config'), DSR_CONFIG_FILE=str(case / 'config/config.yaml'),
        DSR_REPOS_FILE=str(case / 'config/repos.yaml'), DSR_HOSTS_FILE=str(case / 'config/hosts.yaml'),
        DSR_STATE_DIR=str(case / 'state'), DSR_CACHE_DIR=str(case / 'cache'),
        ACT_CONFIG_DIR=str(case / 'config'), ACT_REPOS_DIR=str(case / 'config/repos.d'),
        ACT_ARTIFACTS_DIR=str(case / 'artifacts'), ACT_LOGS_DIR=str(case / 'logs'),
        DSR_DISABLE_HOST_SELECTOR='1', DSR_RETRY_MAX='3', RCH_DISABLED='1',
        RCH_CARGO_WRAPPER_BYPASS='1', NO_COLOR='1')
    for key in ('DSR_BUILD_LOCK_HELD_BY_CALLER', 'DSR_RUN_ID', 'RCH_REQUIRE_REMOTE'):
        env.pop(key, None)
    return case, env


def invoke(case, env, mode, label=None, **extra):
    label = label or mode
    with (case / (label + '.stdout')).open('wb') as out, (case / (label + '.stderr')).open('wb') as err:
        result = subprocess.run(['bash', str(driver)], env=dict(env, PARTIAL_MODE=mode, **extra),
            stdin=subprocess.DEVNULL, stdout=out, stderr=err, timeout=90)
    if mode == 'status':
        check(case.name + '/' + label + ': real state transition succeeds', result.returncode == 0)
        return result.returncode, {}
    try:
        value = read(case / (label + '.stdout'))
    except (ValueError, OSError):
        value = {}
    check(case.name + '/' + label + ': exactly one structured result', isinstance(value, dict) and bool(value))
    return result.returncode, value


def seed(name, jobs):
    case, env = fixture(name, jobs)
    code, result = invoke(case, env, 'first')
    check(name + ': public build reports one real success and one real failure',
          code == 1 and result.get('status') == 'partial' and result.get('exit_code') == 1 and
          result.get('details', {}).get('success') == 1 and result.get('details', {}).get('failed') == 1 and
          result.get('details', {}).get('publishable') is False)
    identity = result.get('details', {}).get('run_id', '')
    state_path = case / 'state/builds/tool/1.2.3' / identity / 'state.json'
    state = read(state_path)
    (case / 'first.state.json').write_text(state_path.read_text())
    check(name + ': actual persisted checkpoint is partial with exact target outcomes',
          state['status'] == 'partial' and state['context']['parallel_jobs'] == jobs and
          state['context'].get('repo_config_sha256') == digest(case / 'config/repos.d/tool.yaml') and
          state['target_statuses']['linux/amd64']['status'] == 'completed' and
          state['target_statuses']['linux/arm64']['status'] == 'failed' and
          state['target_statuses']['linux/arm64']['result']['exit_code'] == 17)
    check(name + ': both payloads genuinely executed once',
          Counter((event['platform'], event['attempt']) for event in events(case)) ==
          Counter({('linux/amd64', 1): 1, ('linux/arm64', 1): 1}))
    env['PARTIAL_RUN'] = identity
    code, plan = invoke(case, env, 'plan')
    check(name + ': public state planner admits only unfinished target',
          code == 0 and plan.get('can_resume') is True and plan.get('current_status') == 'partial' and
          plan.get('completed_targets') == ['linux/amd64'] and plan.get('targets_to_process') == ['linux/arm64'])
    return case, env, state_path, state


for jobs in (1, 2):
    case, env, state_path, initial = seed('jobs-' + str(jobs), jobs)
    before = {Path(row['result_path']): digest(Path(row['result_path']))
              for row in initial['target_statuses'].values()}
    successful_payload = Path(initial['target_statuses']['linux/amd64']['result']['artifact_path'])
    before[successful_payload] = digest(successful_payload)
    (case / 'repaired').write_text('repair complete\n')
    code, resumed = invoke(case, env, 'resume')
    state = read(state_path)
    (case / 'resume.state.json').write_text(state_path.read_text())
    check(case.name + ': public fallback resumes the exact partial UUID successfully',
          code == 0 and resumed.get('status') == 'success' and resumed.get('exit_code') == 0 and
          resumed.get('details', {}).get('resume_run_id') == initial['run_id'] and
          resumed.get('details', {}).get('phases', {}).get('verification') == 'passed')
    check(case.name + ': completed target reused while failed target receives a second real attempt',
          Counter((event['platform'], event['attempt']) for event in events(case)) ==
          Counter({('linux/amd64', 1): 1, ('linux/arm64', 1): 1, ('linux/arm64', 2): 1}) and
          state['target_statuses']['linux/amd64']['attempts'] == 1 and
          state['target_statuses']['linux/arm64']['attempts'] == 2)
    check(case.name + ': prior worker receipts and successful payload stay immutable',
          all(path.is_file() and digest(path) == prior for path, prior in before.items()))
    manifest_path = case / 'output/tool-v1.2.3-manifest.json'
    manifest = read(manifest_path) if manifest_path.exists() else {}
    check(case.name + ': verified full manifest and completed state retain source and run identity',
          state['status'] == 'completed' and state['run_id'] == initial['run_id'] and
          manifest.get('run_id') == initial['run_id'] and manifest.get('publishable') is True and
          manifest.get('source', {}).get('git_sha') == env['PARTIAL_SHA'] and
          manifest.get('summary') == {'total': 2, 'success': 2, 'failed': 0} and
          bool(manifest.get('artifacts')) and all(
              digest(case / 'output' / row['name']) == row['sha256'] and
              (case / 'output' / row['name']).stat().st_size == row['size_bytes']
              for row in manifest.get('artifacts', [])))
    boundaries = (case / 'boundaries').read_text()
    check(case.name + ': source admission ran and build-only made no publication/network call',
          'READINESS ' in boundaries and 'UNEXPECTED_' not in boundaries and
          resumed.get('details', {}).get('phases', {}).get('release') == 'skipped')

# Reuse a real completed checkpoint from the public build/fallback sequence.
# Config drift must fail before isolated Git materialization, quality hooks,
# signing or publication; retained outputs are not permission to reinterpret
# the recipe. No replacement compiler or updater runs in these refusal cases.
completed_bytes = state_path.read_bytes()
recipe_path = case / 'config/repos.d/tool.yaml'
recipe_bytes = recipe_path.read_bytes()
completed_events = events(case)
completed_files = {Path(row['result_path']) for row in state['target_statuses'].values()}
completed_files.update(Path(row['result']['artifact_path']) for row in state['target_statuses'].values())
completed_files.update(path for path in (case / 'output').iterdir() if path.is_file())
completed_identity = {path: (path.stat().st_ino, digest(path)) for path in completed_files}
for change in ('build-command', 'environment', 'packaging', 'missing-binding', 'malformed-binding'):
    recipe = json.loads(recipe_bytes)
    retained = json.loads(completed_bytes)
    if change == 'build-command':
        recipe['build_cmd'] = 'different build recipe'
    elif change == 'environment':
        recipe['env'] = {'BUILD_FLAVOR': 'different'}
    elif change == 'packaging':
        recipe['binary_name'] = 'different-name'
    elif change == 'missing-binding':
        retained['context'].pop('repo_config_sha256', None)
    else:
        retained['context']['repo_config_sha256'] = 'not-a-config-digest'
    recipe_path.write_bytes(recipe_bytes if change.endswith('binding') else json.dumps(recipe).encode())
    state_path.write_bytes(completed_bytes if not change.endswith('binding') else json.dumps(retained).encode())
    selected_state = (state_path.stat().st_ino, digest(state_path))
    before_boundaries = (case / 'boundaries').read_text()
    code, result = invoke(case, env, 'publish-isolated', 'recipe-' + change)
    new_boundaries = (case / 'boundaries').read_text()[len(before_boundaries):]
    check(change + ': completed fallback refuses the recipe before source, quality or publication',
          code == 4 and result.get('exit_code') == 4 and result.get('details', {}).get('phase') == 'resume' and
          not (case / 'state/fallback-sources').exists() and events(case) == completed_events and
          not any(line.startswith(('CHECK ', 'READINESS ', 'SLOT ', 'PUBLISH ', 'THROTTLE ',
                                   'RELEASE_SCAN ', 'REMOTE_TAG ', 'UNEXPECTED_'))
                  for line in new_boundaries.splitlines()))
    check(change + ': checkpoint, frozen receipts and published build output stay unchanged',
          (state_path.stat().st_ino, digest(state_path)) == selected_state and
          all(path.is_file() and (path.stat().st_ino, digest(path)) == identity
              for path, identity in completed_identity.items()))
    code, lease = invoke(case, env, 'lease', 'lease-after-' + change)
    check(change + ': refusal releases the actual coordinator lease', code == 0 and lease.get('available') is True)

recipe_path.write_bytes(recipe_bytes)
state_path.write_bytes(completed_bytes)
before_boundaries = (case / 'boundaries').read_text()
code, result = invoke(case, env, 'publish', 'recipe-restored-publication')
new_boundaries = (case / 'boundaries').read_text()[len(before_boundaries):]
check('restored recipe: completed fallback reuses the real build and reaches confirmed publication',
      code == 0 and result.get('status') == 'success' and
      result.get('details', {}).get('resume_run_id') == state['run_id'] and
      result.get('details', {}).get('phases', {}).get('release') == 'success' and
      sum(line.startswith('PUBLISH ') for line in new_boundaries.splitlines()) == 1 and
      'CHECK ' in new_boundaries and events(case) == completed_events)
check('restored recipe: publication preserves checkpoint, worker receipts and sealed build output',
      state_path.read_bytes() == completed_bytes and
      all(path.is_file() and (path.stat().st_ino, digest(path)) == identity
          for path, identity in completed_identity.items()))
code, lease = invoke(case, env, 'lease', 'lease-after-publication')
check('restored recipe: successful publication releases the actual coordinator lease',
      code == 0 and lease.get('available') is True)

case, env, state_path, initial = seed('refusal-guards', 2)
before_events = events(case)
for status in ('cancelled', 'unknown-state'):
    invoke(case, env, 'status', 'set-' + status, PARTIAL_STATUS=status)
    before_state = digest(state_path)
    code, result = invoke(case, env, 'resume', 'refuse-' + status)
    check(status + ': rejected before checks, retries or publication',
          code == 4 and result.get('exit_code') == 4 and result.get('details', {}).get('phase') == 'resume' and
          digest(state_path) == before_state and events(case) == before_events and
          'CHECK ' not in (case / 'boundaries').read_text() and
          'UNEXPECTED_' not in (case / 'boundaries').read_text())

invoke(case, env, 'status', 'restore-partial', PARTIAL_STATUS='partial')
successful_payload = Path(initial['target_statuses']['linux/amd64']['result']['artifact_path'])
good_digest = digest(successful_payload)
original_receipt = Path(initial['target_statuses']['linux/amd64']['result_path'])
receipt_digest = digest(original_receipt)
with successful_payload.open('ab') as changed:
    changed.write(b'changed bytes must not be reused\n')
changed_digest = digest(successful_payload)
(case / 'repaired').write_text('repair complete\n')
code, result = invoke(case, env, 'resume', 'refuse-artifact-drift')
state = read(state_path)
replacement = Path(state['target_statuses']['linux/amd64']['result']['artifact_path'])
check('changed completed artifact requires a genuine replacement attempt',
      Counter((event['platform'], event['attempt']) for event in events(case)) ==
      Counter({('linux/amd64', 1): 1, ('linux/arm64', 1): 1,
               ('linux/amd64', 2): 1, ('linux/arm64', 2): 1}) and
      replacement != successful_payload and digest(replacement) == good_digest and
      digest(successful_payload) == changed_digest and digest(original_receipt) == receipt_digest)
# Replacement payload names deliberately include their attempt. The old
# collected output therefore remains outside the new manifest, and fallback
# must refuse that stale inventory even after both rebuilds have succeeded.
manifest_path = case / 'output/tool-v1.2.3-manifest.json'
manifest = read(manifest_path) if manifest_path.exists() else {}
check('rebuilt manifest cannot claim the corrupted or superseded payload',
      state['status'] == 'completed' and bool(manifest.get('artifacts')) and
      all(row['sha256'] != changed_digest and row['name'] != successful_payload.name
          for row in manifest.get('artifacts', [])))
check('unmanifested prior output still blocks fallback publication',
      code == 6 and result.get('exit_code') == 6 and
      result.get('details', {}).get('phase') == 'verification' and
      'Release payload is absent from manifest' in (case / 'refuse-artifact-drift.stderr').read_text() and
      'UNEXPECTED_' not in (case / 'boundaries').read_text())
print('Public partial-resume checks: %d, failures: %d' % (checks, failures), flush=True)
raise SystemExit(bool(failures))
PY
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
test_completed_ordinary_source_inputs() {
    setup "completed-ordinary-$1"
    mkdir -p "$CASE/sibling" "$CASE/initial-source-contexts" || return 1
    git -C "$CASE/sibling" init -q || return 1
    printf 'sibling input\n' > "$CASE/sibling/src.txt"
    printf 'ignored.log\n' > "$CASE/sibling/.gitignore"
    printf 'ignored output\n' > "$CASE/sibling/ignored.log"
    git -C "$CASE/sibling" add src.txt .gitignore || return 1
    git -C "$CASE/sibling" -c user.name=Fixture -c user.email=fixture@example.invalid \
        commit -qm sibling || return 1
    printf 'sibling_crates:\n  - local_path: %s\n    relative_path: sibling\n' \
        "$CASE/sibling" >> "$ACT_REPOS_DIR/tool.yaml"
    completed_fixture || return 1
    local contexts inputs tasks checkpoint_before payload_before expected_rc=4
    contexts=$(_act_export_ordinary_git_contexts "$ACT_REPOS_DIR/tool.yaml" \
        "$CASE/source" "$CASE/initial-source-contexts") || return 1
    inputs=$(_act_project_ordinary_sources "$ACT_REPOS_DIR/tool.yaml" "$contexts" \
        "$CASE/initial-source-contexts/selected-sources") || return 1
    tasks=$(_act_build_task_plan tool 1.2.3 '["linux/amd64","darwin/arm64"]' false) || return 1
    jq --argjson inputs "$inputs" --argjson tasks "$tasks" \
        '.context.source_sync={staged_ordinary:true,source_inputs:$inputs} | .context.build_tasks=$tasks' \
        "$CASE/checkpoint.json" > "$CASE/bound-state.json" || return 1
    mv "$CASE/bound-state.json" "$CASE/checkpoint.json" || return 1
    case "$1" in
        matching) expected_rc=0 ;;
        excluded) printf 'new ignored output\n' >> "$CASE/sibling/ignored.log"; expected_rc=0 ;;
        selected) printf 'new sibling input\n' >> "$CASE/sibling/src.txt" ;;
        permissions) chmod 755 "$CASE/sibling/src.txt" ;;
        unbound)
            jq 'del(.context.source_sync.source_inputs)' "$CASE/checkpoint.json" > "$CASE/unbound-state.json" || return 1
            mv "$CASE/unbound-state.json" "$CASE/checkpoint.json" || return 1 ;;
        quality) QUALITY_MUTATES_PINNED_CHILD=sibling/src.txt; expected_rc=6 ;;
    esac
    checkpoint_before=$(_release_sha256 "$CASE/checkpoint.json") || return 1
    payload_before=$(_release_sha256 "$OUT/worker") || return 1
    run_fallback --resume
    [[ "$RC" == "$expected_rc" ]] && one_result &&
        [[ "$(_release_sha256 "$CASE/checkpoint.json")" == "$checkpoint_before" &&
           "$(_release_sha256 "$OUT/worker")" == "$payload_before" && ! -e "$CASE/lock" ]] &&
        ! grep -q '^BUILD ' "$CALLS" || return 1
    if [[ "$expected_rc" == 0 ]]; then
        grep -q '^RELEASE ' "$CALLS"
    else
        ! grep -q '^RELEASE ' "$CALLS"
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
    completed_fixture workflow || return 1
    git -C "$CASE/source" -c user.name=Fixture -c user.email=fixture@example.invalid \
        tag -am release v1.2.3 || return 1
    export DSR_CONFIG_DIR="$CASE" DSR_REPOS_FILE="$CASE/repos.yaml"
    jq -nc --arg path "$CASE/source" \
        '{repo:"owner/tool",local_path:$path,language:"go",binary_name:"tool",
          workflow:".github/workflows/release.yml",targets:["linux/amd64","darwin/arm64"],
          act_job_map:{"linux/amd64":"build","darwin/arm64":"build"}}' > "$ACT_REPOS_DIR/tool.yaml"
    # This is the completed fixture's original workflow configuration, before
    # any test-specific mutation; capture its actual recipe binding.
    checkpoint completed || return 1
    # shellcheck source=/dev/null
    source <(awk '/^(config_get_tool_field|_config_read_single_mapping_json|_config_canonicalize_release_source_dependency_checkouts_json|_config_get_release_source_dependency_checkouts_json|config_get_release_source_dependencies_json)\(\) \{/{copy=1} copy{print} copy && /^\}/{copy=0}' "$ROOT/src/config.sh")
    # shellcheck source=/dev/null
    source <(awk '/^(_act_materialized_source_path|act_get_local_path|act_load_repo_config|act_platform_uses_act|_act_release_source_dependencies_json|_act_release_source_dependency_checkouts_json|_act_export_ordinary_git_contexts|_act_validate_isolated_cargo_paths|_act_sync_sibling_crates)\(\) \{/{copy=1} copy{print} copy && /^\}/{copy=0}' "$ROOT/src/act_runner.sh")
}

# The mock compiler retains production source plans and materialized layouts.
# Seed only the checkpoint envelope here, so resume admission must verify that
# original evidence against the new attempt's freshly resolved task identities.
isolated_workflow_checkpoint() {
    checkpoint completed
    jq --slurpfile sync "$CASE/build-source-sync.json" \
        --slurpfile target "$CASE/build-target-source-sync.json" \
        --slurpfile tasks "$CASE/build-tasks.json" \
        --slurpfile layout "$CASE/build-source-layout.json" '
        .context.source_sync=$sync[0] | .context.build_tasks=$tasks[0] |
        .source_sync_history=[{receipt:$sync[0]}] |
        .target_statuses=($tasks[0] | map({key:.key,value:{status:"completed",result:
            ({status:"success",method:.method,platform:.platform,source_sync:$target[0]} +
             if $layout[0] == null then {} else {source_layout:$layout[0]} end)}}) | from_entries)
    ' "$CASE/checkpoint.json" > "$CASE/workflow-checkpoint.json" || return 1
    mv "$CASE/workflow-checkpoint.json" "$CASE/checkpoint.json"
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
    setup "isolated-sibling-${2:-$1}"; isolated_fixture || return 1
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
    jq -e --arg sha "$SOURCE_SHA" --arg revision "$revision" \
        '.source_materialization == {git_sha:$sha,submodules:[],
            dependencies:[{relative_path:"dependency",git_sha:$revision,submodules:[]}]}' \
        "$CASE/build-source-sync.json" >/dev/null || return 1
    jq -e --slurpfile sync "$CASE/build-source-sync.json" \
        '.status == "success" and .source_materialization == $sync[0].source_materialization' \
        "$CASE/build-target-source-sync.json" >/dev/null || return 1
    jq -e --arg path "$dependency" --arg revision "$revision" \
        '.[0].local_path == $path and .[0].git_sha == $revision' "$CASE/build-dependencies.json" >/dev/null &&
        jq -e --arg path "$dependency" --arg revision "$revision" \
            'any(.[]; .relative_path == "dependency" and .local_path == $path and .context.git_sha == $revision)' \
            "$CASE/build-contexts.json" >/dev/null
}

test_isolated_source_sibling_graph_resume() {
    local mode="$1" before filter='.'
    test_isolated_source_pinned_siblings pinned "resume-graph-$mode" || return 1
    before=$(jq -r '.details.source_materialization.source_root' "$CASE/stdout") || return 1
    isolated_workflow_checkpoint || return 1
    case "$mode" in
        partial) filter='.status="partial" | .target_statuses["darwin/arm64"]={status:"failed"}' ;;
        pending) filter='.status="failed" | .target_statuses |= with_entries(.value={status:"pending"})' ;;
        context) filter='del(.context.source_sync.source_materialization)' ;;
        history) filter='.source_sync_history[0].receipt.source_materialization.dependencies[0].git_sha=("f"*40)' ;;
        embedded) filter='.target_statuses["linux/amd64"].result.source_sync.source_materialization.dependencies[0].git_sha=("f"*40)' ;;
        missing-target) filter='del(.target_statuses["linux/amd64"].result.source_sync)' ;;
        sidecar)
            jq -nc --slurpfile source "$CASE/build-target-source-sync.json" '
                {status:"success",source_sync:$source[0]} |
                .source_sync.source_materialization.dependencies[0].git_sha=("f"*40)
            ' > "$CASE/retained-sibling-result.json" || return 1
            filter='.target_statuses["linux/amd64"].result_path=$path'
            ;;
        removed)
            jq '.sibling_crates=[]' "$ACT_REPOS_DIR/tool.yaml" > "$CASE/removed-sibling-config.json" || return 1
            mv "$CASE/removed-sibling-config.json" "$ACT_REPOS_DIR/tool.yaml"
            ;;
        layout-missing) filter='del(.target_statuses["linux/amd64"].result.source_layout)' ;;
        layout-identity) filter='.target_statuses["linux/amd64"].result.source_layout.identity.workflow_sha256=("f"*64)' ;;
        layout-method-missing) filter='del(.target_statuses["linux/amd64"].result.source_layout,.target_statuses["linux/amd64"].result.method)' ;;
        layout-method-native) filter='del(.target_statuses["linux/amd64"].result.source_layout) | .target_statuses["linux/amd64"].result.method="native"' ;;
        layout-plan-missing) filter='del(.context.build_tasks)' ;;
        layout-bytes)
            printf '\n' >> "$(jq -r .projected_workflow "$CASE/build-source-layout.json")" || return 1
            ;;
        layout-sidecar-matching|layout-sidecar-missing|layout-sidecar-identity)
            jq '.target_statuses["linux/amd64"].result' "$CASE/checkpoint.json" \
                > "$CASE/retained-sibling-result.json" || return 1
            local sidecar_filter='.'
            if [[ "$mode" == layout-sidecar-missing ]]; then
                # A method label cannot downgrade the task's current source
                # requirement, even when the embedded result remains valid.
                sidecar_filter='del(.source_layout) | .method="native"'
            elif [[ "$mode" == layout-sidecar-identity ]]; then
                sidecar_filter='.source_layout.identity.dependencies[0].git_sha=("f"*40)'
            fi
            jq "$sidecar_filter" "$CASE/retained-sibling-result.json" \
                > "$CASE/selected-sibling-result.json" || return 1
            mv "$CASE/selected-sibling-result.json" "$CASE/retained-sibling-result.json"
            filter='.target_statuses["linux/amd64"].result_path=$path'
            ;;
    esac
    jq --arg path "$CASE/retained-sibling-result.json" "$filter" "$CASE/checkpoint.json" \
        > "$CASE/selected-sibling-checkpoint.json" || return 1
    mv "$CASE/selected-sibling-checkpoint.json" "$CASE/checkpoint.json"
    : > "$CALLS"
    run_fallback --expected-sha "$SOURCE_SHA" --isolate-source "--resume=$RUN"
    case "$mode" in
        matching|partial|pending|layout-sidecar-matching)
            [[ "$RC" == 0 ]] && one_result || return 1
            [[ "$(jq -r '.details.source_materialization.source_root' "$CASE/stdout")" != "$before" ]] || return 1
            if [[ "$mode" == partial || "$mode" == pending ]]; then grep -q '^BUILD ' "$CALLS"
            else ! grep -q '^BUILD ' "$CALLS"; fi
            ;;
        *)
            [[ "$RC" == 4 ]] && one_result || return 1
            jq -e '.details.phase == "resume"' "$CASE/stdout" >/dev/null &&
                ! grep -q '^CHECK\|^BUILD\|^RELEASE ' "$CALLS"
            ;;
    esac
}

test_isolated_source_submodules() {
    local mode="$1" parent child pin snapshot expected=0 selected index_before source_before parent_index
    setup "isolated-submodules-${2:-$mode}"; isolated_fixture || return 1
    parent="$CASE/source"
    if [[ "$mode" == sibling ]]; then
        parent="$CASE/dependency"
        mkdir "$parent"
        git -C "$parent" init -q -b main || return 1
        printf 'sibling root\n' > "$parent/src.txt"
    fi
    child="$parent/vendor/library"
    mkdir -p "$child"
    git -C "$child" init -q -b main || return 1
    printf 'pinned child source\n' > "$child/src.txt"
    if [[ "$mode" == absolute ]]; then
        printf '[dependencies]\nlocal = { path = "%s" }\n' "$CASE/source" > "$child/Cargo.toml"
    fi
    git -C "$child" add . || return 1
    git -C "$child" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm child || return 1
    pin=$(git -C "$child" rev-parse HEAD) || return 1
    printf '[submodule "vendor/library"]\n\tpath = vendor/library\n\turl = https://must-not-fetch.invalid/library.git\n' > "$parent/.gitmodules"
    git -C "$parent" add src.txt .gitmodules || return 1
    git -C "$parent" update-index --add --cacheinfo "160000,$pin,vendor/library" || return 1
    git -C "$parent" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm parent || return 1
    if [[ "$mode" == sibling ]]; then
        jq --arg path "$parent" --arg revision "$(git -C "$parent" rev-parse HEAD)" \
            '.sibling_crates=[{relative_path:"dependency",local_path:$path,revision:$revision}]' \
            "$ACT_REPOS_DIR/tool.yaml" > "$CASE/submodule-config.json" || return 1
        mv "$CASE/submodule-config.json" "$ACT_REPOS_DIR/tool.yaml"
    else
        SOURCE_SHA=$(git -C "$parent" rev-parse HEAD) || return 1
        git -C "$parent" -c user.name=Fixture -c user.email=fixture@example.invalid tag -fam release v1.2.3 >/dev/null || return 1
    fi
    printf 'staged child developer work\n' > "$child/src.txt"
    git -C "$child" add src.txt || return 1
    printf 'unstaged child developer work\n' > "$child/src.txt"
    printf 'private child work\n' > "$child/untracked.txt"
    index_before=$(_release_sha256 "$child/.git/index") || return 1
    parent_index=$(_release_sha256 "$parent/.git/index") || return 1
    source_before=$(_release_sha256 "$child/src.txt") || return 1
    BUILD_FROM_PINNED_CHILD='source/vendor/library'
    [[ "$mode" != sibling ]] || BUILD_FROM_PINNED_CHILD='dependency/vendor/library'
    case "$mode" in
        absolute) expected=4 ;;
        quality) QUALITY_MUTATES_PINNED_CHILD='source/vendor/library/src.txt'; expected=4 ;;
        build) BUILD_MUTATES_PINNED_CHILD='source/vendor/library/src.txt'; expected=6 ;;
        signing) SIGN_MODE=submodule; expected=6 ;;
    esac
    run_fallback --expected-sha "$SOURCE_SHA" --isolate-source
    [[ "$RC" == "$expected" ]] && one_result || return 1
    [[ "$(_release_sha256 "$child/.git/index")" == "$index_before" &&
       "$(_release_sha256 "$parent/.git/index")" == "$parent_index" &&
       "$(_release_sha256 "$child/src.txt")" == "$source_before" &&
       "$(cat "$child/untracked.txt")" == 'private child work' ]] || return 1
    if [[ "$expected" != 0 ]]; then
        ! grep -q '^RELEASE ' "$CALLS" || return 1
        [[ "$mode" != absolute ]] || ! grep -q '^CHECK\|^BUILD ' "$CALLS"
        return $?
    fi
    snapshot=$(jq -r '.details.source_materialization.source_root' "$CASE/stdout") || return 1
    selected="$snapshot/vendor/library"
    [[ "$mode" != sibling ]] || selected="${snapshot%/*}/dependency/vendor/library"
    [[ "$(git -C "$selected" rev-parse HEAD)" == "$pin" &&
       "$(cat "$selected/src.txt")" == 'pinned child source' && ! -e "$selected/untracked.txt" ]] || return 1
    [[ "$(cat "$OUT/daemon")" == "$pin"$'\n''pinned child source' ]] || return 1
    if [[ "$mode" == sibling ]]; then
        jq -e --arg pin "$pin" 'any(.details.source_materialization.dependencies[].submodules[];
            .path == "vendor/library" and .git_sha == $pin)' "$CASE/stdout" >/dev/null || return 1
    fi
    jq -e --arg pin "$pin" 'any(.[]; .submodule == true and .context.git_sha == $pin)' \
        "$CASE/build-contexts.json" >/dev/null || return 1
    grep -Fqx "RELEASE_SOURCE $snapshot" "$CALLS"
}

test_isolated_source_submodule_resume() {
    local mode="$1" fixture_mode=root before
    [[ "$mode" != sibling ]] || fixture_mode=sibling
    test_isolated_source_submodules "$fixture_mode" "resume-$mode" || return 1
    before=$(jq -r '.details.source_materialization.source_root' "$CASE/stdout") || return 1
    isolated_workflow_checkpoint || return 1
    local filter='.'
    case "$mode" in
        partial) filter='.status="partial" | .target_statuses["darwin/arm64"]={status:"failed"}' ;;
        pending) filter='.status="failed" | .target_statuses |= with_entries(.value={status:"pending"})' ;;
        legacy) filter='del(.context.source_sync.source_materialization) | .source_sync_history[].receipt |= del(.source_materialization) | .target_statuses[].result.source_sync |= del(.source_materialization)' ;;
        context) filter='del(.context.source_sync.source_materialization)' ;;
        history) filter='.source_sync_history[0].receipt.source_materialization.submodules[0].git_sha=("f"*40)' ;;
        embedded) filter='.target_statuses["linux/amd64"].result.source_sync.source_materialization.submodules[0].git_tree=("f"*40)' ;;
        missing-target) filter='del(.target_statuses["linux/amd64"].result.source_sync)' ;;
        sidecar)
            jq -nc --slurpfile source "$CASE/build-target-source-sync.json" '
                {status:"success",source_sync:$source[0]} |
                .source_sync.source_materialization.submodules[0].git_sha=("f"*40)
            ' > "$CASE/retained-result.json" || return 1
            filter='.target_statuses["linux/amd64"].result_path=$path'
            ;;
    esac
    jq --arg path "$CASE/retained-result.json" "$filter" "$CASE/checkpoint.json" > "$CASE/selected-checkpoint.json" || return 1
    mv "$CASE/selected-checkpoint.json" "$CASE/checkpoint.json"
    : > "$CALLS"
    run_fallback --expected-sha "$SOURCE_SHA" --isolate-source "--resume=$RUN"
    case "$mode" in
        matching|sibling|partial|pending)
            [[ "$RC" == 0 ]] && one_result || return 1
            [[ "$(jq -r '.details.source_materialization.source_root' "$CASE/stdout")" != "$before" ]] || return 1
            if [[ "$mode" == partial || "$mode" == pending ]]; then grep -q '^BUILD ' "$CALLS"
            else ! grep -q '^BUILD ' "$CALLS"; fi
            ;;
        *)
            [[ "$RC" == 4 ]] && one_result || return 1
            jq -e '.details.phase == "resume" and (.details.error | contains("submodule graph"))' "$CASE/stdout" >/dev/null &&
                ! grep -q '^CHECK\|^BUILD\|^RELEASE ' "$CALLS"
            ;;
    esac
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
    # This compatibility fixture describes an old native-host receipt, whose
    # exact Git pins can remain sufficient when there are no nested children.
    # An act result with siblings must instead retain its workflow projection.
    jq --arg path "$CASE/sibling" --arg revision "$revision" \
        '.sibling_crates=[{relative_path:"dependency",local_path:$path,revision:$revision}] | .act_job_map={}' \
        "$ACT_REPOS_DIR/tool.yaml" > "$CASE/sibling-config.json"
    mv "$CASE/sibling-config.json" "$ACT_REPOS_DIR/tool.yaml"
    receipt=$(jq -nc --arg sha "$SOURCE_SHA" --arg revision "$revision" \
        '{git_context:{git_sha:$sha},sibling_git_contexts:{dependency:{git_sha:$revision}}}')
    jq --argjson receipt "$receipt" --arg recipe "$(_release_sha256 "$ACT_REPOS_DIR/tool.yaml")" '
        .context.repo_config_sha256=$recipe |
        .context.source_sync=$receipt | .source_sync_history=[{receipt:$receipt}] |
        .target_statuses=(.targets | map({key:.,value:{status:"completed",result:{status:"success",method:"native",source_sync:$receipt}}}) | from_entries)
    ' "$CASE/checkpoint.json" > "$CASE/source-state.json"
    mv "$CASE/source-state.json" "$CASE/checkpoint.json"
    case "$1" in
        partial) jq '.status="partial"' "$CASE/checkpoint.json" > "$CASE/revised-state.json" ;;
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
                .context.repo_config_sha256=$digest |
                .target_statuses=($tasks | map({key:.key,value:{status:"completed",result:{status:"success",method:"native",source_sync:$receipt}}}) | from_entries)
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
run_test test_throttle_check_interruption
run_test test_throttle_check_manual_request 0
run_test test_throttle_check_manual_request 8
for mode in throttled failure timed_out startup_failure; do run_test test_watch_admission_success "$mode"; done
for mode in success cancelled failed active waiting recent attempt workflow source disabled unreadable interrupted jobs-rerun; do
    run_test test_watch_admission_initial_refusal "$mode"
done
for mode in quality build signing; do run_test test_watch_admission_late_refusal "$mode"; done
for mode in missing-field extra-field fractional-attempt wrong-repo bad-reason bad-threshold missing-expected build-only; do
    run_test test_watch_admission_arguments "$mode"
done
for rc in 1 2 3 4 5 6 8 130 143; do run_test test_build_failure "$rc"; done
for mode in missing malformed multiple empty partial wrong-tool wrong-version duplicate unsafe diagnostic corrupt absent symlink manifest-link hash-failure extra-payload; do
    run_test test_manifest_failure "$mode"
done
run_test test_signing_failure
run_test test_strict_fresh_output
run_test test_sbom_forwarding
run_test test_strict_sbom_refusal
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
run_test test_partial_resume_real_workers
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
for mode in matching excluded selected permissions unbound quality; do
    run_test test_completed_ordinary_source_inputs "$mode"
done
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
for mode in matching partial pending context history embedded missing-target sidecar removed; do
    run_test test_isolated_source_sibling_graph_resume "$mode"
done
for mode in layout-missing layout-identity layout-method-missing layout-method-native layout-plan-missing \
    layout-bytes layout-sidecar-matching layout-sidecar-missing layout-sidecar-identity; do
    run_test test_isolated_source_sibling_graph_resume "$mode"
done
for mode in root sibling quality build signing absolute; do run_test test_isolated_source_submodules "$mode"; done
for mode in matching sibling partial pending legacy context history embedded missing-target sidecar; do run_test test_isolated_source_submodule_resume "$mode"; done
for mode in quality build signing; do run_test test_isolated_source_drift "$mode"; done
for mode in absolute quoted hidden relative; do run_test test_isolated_source_cargo_paths "$mode"; done
for mode in matching partial variants pending changed removed history embedded sidecar missing; do run_test test_isolated_source_sibling_resume "$mode"; done
for mode in unix windows; do run_test test_isolated_source_sync_paths "$mode"; done
for mode in valid mismatch unavailable; do run_test test_isolated_source_fetch "$mode"; done
for mode in dry arguments; do run_test test_isolated_source_plan_and_arguments "$mode"; done
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
