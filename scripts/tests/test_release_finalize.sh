#!/usr/bin/env bash
# Real state, hashing, JSON, locks and processes. SBOM/GitHub API boundaries are
# explicit file-backed fixtures; this is not live Syft or GitHub integration.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
MODULE="${FINALIZE_TEST_MODULE:-$ROOT/src/release_finalize.sh}"
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
trap 'exit 5' HUP INT TERM
mkdir -p "$WORK/bin" "$WORK/cases"
export PATH="$WORK/bin:$PATH"
export RF_SHA=1111111111111111111111111111111111111111
export RF_TEST_REPO_ROOT="$ROOT"
trace() { printf '%s\n' "$*" >> "$RF_CASE/calls"; }
_sbr_require() { trace auth; [[ "${RF_MODE:-}" != noauth ]] || return 3; }
_sbr_run() { "$@"; }
_sbr_context() { trace context; cat "$RF_CASE/context.json"; }
_sbr_inventory() {
    trace inventory
    if [[ "${RF_MODE:-}" == late-inventory && -f "$RF_CASE/verified" ]]; then
        jq '.[0].id+=100' "$RF_CASE/inventory.json"
    else cat "$RF_CASE/inventory.json"; fi
}
_sbr_inventory_sha256() {
    local file
    file=$(mktemp "$2/inventory.XXXXXXXX") || return 1
    jq -cS 'sort_by(.name)' <<< "$1" > "$file" || return 1
    _rf_hash "$file"
}
# The source fixture keeps the real manifest/digest contract and performs hashes
# over actual local and simulated-remote file bytes, not canned success strings.
fixture_local_verify() {
    local root="$1" out="$2" ext="$3" manifest entry name digest
    manifest="$out/sbom-manifest.$ext.json"
    [[ -f "$manifest" ]] || return 4
    while IFS= read -r entry; do
        name=$(jq -r '.artifact.name' <<< "$entry"); digest=$(jq -r '.artifact.sha256' <<< "$entry")
        [[ "$(_rf_hash "$root/$name")" == "$digest" ]] || return 7
        name=$(jq -r '.sbom.name' <<< "$entry"); digest=$(jq -r '.sbom.sha256' <<< "$entry")
        [[ "$(_rf_hash "$out/$name")" == "$digest" ]] || return 7
    done < <(jq -c '.artifacts[]' "$manifest")
}
sbom_generate_artifacts() {
    trace generate
    [[ "${RF_MODE:-}" != generate-fail ]] || return 6
    if [[ "${RF_MODE:-}" == cancel-generate ]]; then finalize-cancel-probe || return $?; fi
    local root="$1" format="$3" out="$5" ext=spdx sha doc_sha
    [[ "$format" != cyclonedx ]] || ext=cdx
    mkdir -p "$out"
    if [[ ! -e "$out/sbom-manifest.$ext.json" ]]; then
        printf '{"fixture":"%s"}\n' "$format" > "$out/tool.tar.gz.sbom.$ext.json"
        sha=$(_rf_hash "$root/tool.tar.gz") || return $?
        doc_sha=$(_rf_hash "$out/tool.tar.gz.sbom.$ext.json") || return $?
        jq -nc --arg format "$format" --arg ext "$ext" --arg sha "$sha" --arg doc "$doc_sha" '
            {schema_version:1,kind:"dsr-sbom-release",status:"complete",format:$format,
             artifacts:[{artifact:{name:"tool.tar.gz",sha256:$sha},
             sbom:{name:("tool.tar.gz.sbom."+$ext+".json"),sha256:$doc}}]}' > "$out/sbom-manifest.$ext.json"
    fi
    fixture_local_verify "$root" "$out" "$ext" || return $?
    if [[ "${RF_MODE:-}" == moved-during-generation ]]; then
        jq '.tag_commit=("2"*40)' "$RF_CASE/context.json" > "$RF_CASE/changed-context.json"
        command mv "$RF_CASE/changed-context.json" "$RF_CASE/context.json"
    fi
    printf '%s\n' "$out/sbom-manifest.$ext.json"
}
sbom_verify_artifacts() {
    trace local-verify
    local ext=spdx
    [[ "$3" != cyclonedx ]] || ext=cdx
    fixture_local_verify "$1" "$5" "$ext"
}
fixture_receipt() {
    local format="$1" pin="$2" ext=spdx inventory sha
    [[ "$format" != cyclonedx ]] || ext=cdx
    [[ "$(_rf_hash "$RF_CASE/remote/sbom-manifest.$ext.json")" == "$pin" ]] || return 7
    fixture_local_verify "$RF_CASE/remote" "$RF_CASE/remote" "$ext" || return $?
    inventory=$(cat "$RF_CASE/inventory.json") || return 1
    sha=$(_sbr_inventory_sha256 "$inventory" "$RF_CASE") || return $?
    jq -nc --argjson context "$(cat "$RF_CASE/context.json")" --arg format "$format" --arg ext "$ext" --arg sha "$pin" --arg inv "$sha" '
        $context+{schema_version:1,kind:"dsr-sbom-remote-verification",status:"verified",format:$format,
        manifest:{name:("sbom-manifest."+$ext+".json"),asset_id:3,sha256:$sha},artifact_count:1,
        asset_inventory_sha256:$inv,verification_policy:"expected-manifest-sha256"}'
}
fixture_inner_timeout() { run_with_timeout 30 finalize-cancel-probe; }
fixture_nested_transport() { run_with_timeout 30 fixture_inner_timeout; }
fixture_adapter_transport() (
    # Keep the production adapter and nested deadline ownership. Only the
    # transport's actual work is a fixture; no GitHub request is made here.
    source "$RF_TEST_REPO_ROOT/src/sbom_release.sh" || return 3
    _sbom_log() { printf '[fixture-sbom] %s\n' "$*" >&2; }
    SBOM_REMOTE_TIMEOUT=30 _sbr_run fixture_inner_timeout
)
sbom_publish_artifacts() {
    trace publish
    [[ "${RF_MODE:-}" != publish-fail ]] || return 7
    [[ "${RF_MODE:-}" != publish-false-success ]] || { printf '{}\n'; return 0; }
    case "${RF_MODE:-}" in
        cancel-publish) finalize-cancel-probe || return $? ;;
        cancel-nested) fixture_nested_transport || return $? ;;
        cancel-adapter) fixture_adapter_transport || return $? ;;
    esac
    local root="$1" format="$7" out="$9" ext=spdx file records='' i=0 hash
    [[ "$format" != cyclonedx ]] || ext=cdx
    mkdir -p "$RF_CASE/remote"
    for file in tool.tar.gz "tool.tar.gz.sbom.$ext.json" "sbom-manifest.$ext.json"; do
        if [[ "$file" == tool.tar.gz ]]; then cp "$root/$file" "$RF_CASE/remote/$file"
        else cp "$out/$file" "$RF_CASE/remote/$file"; fi
        i=$((i+1)); hash=$(_rf_hash "$RF_CASE/remote/$file") || return 1
        records+="$(jq -nc --arg name "$file" --arg sha "$hash" --argjson i "$i" --argjson size "$(wc -c < "$RF_CASE/remote/$file")" \
            '{id:$i,name:$name,size:$size,state:"uploaded",digest:("sha256:"+$sha)}')"$'\n'
    done
    jq -sc 'sort_by(.name)' <<< "$records" > "$RF_CASE/inventory.json"
    hash=$(_rf_hash "$out/sbom-manifest.$ext.json") || return 1
    jq -nc --argjson verification "$(fixture_receipt "$format" "$hash")" \
        '{kind:"dsr-sbom-publication",status:"verified",dry_run:false,verification:$verification}'
}
sbom_verify_release() {
    trace verify
    [[ "${RF_MODE:-}" != verify-fail ]] || return 7
    local receipt format="$6" pin="$8"
    receipt=$(fixture_receipt "$format" "$pin") || return $?
    : > "$RF_CASE/verified"
    case "${RF_MODE:-}" in
        bad-evidence) jq '.status="planned"' <<< "$receipt" ;;
        wrong-manifest) jq '.manifest.sha256=("0"*64)' <<< "$receipt" ;;
        wrong-release) jq '.release.id+=1' <<< "$receipt" ;;
        wrong-commit) jq '.tag_commit=("2"*40)' <<< "$receipt" ;;
        *) printf '%s\n' "$receipt" ;;
    esac
}
export -f trace _sbr_require _sbr_run _sbr_context _sbr_inventory _sbr_inventory_sha256
export -f fixture_local_verify fixture_receipt sbom_generate_artifacts sbom_verify_artifacts sbom_publish_artifacts sbom_verify_release
export -f fixture_inner_timeout fixture_nested_transport fixture_adapter_transport
cat > "$WORK/bin/gh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
printf 'patch\n' >> "$RF_CASE/calls"
printf '%s\n' "$@" > "$RF_CASE/gh.args"
body="${*: -1}"
cp "$body" "$RF_CASE/patch.json"
[[ "$*" == 'api --hostname github.com --method PATCH repos/owner/tool/releases/42 --input '* ]] || exit 9
jq -e '.=={draft:false,make_latest:"false"}' "$body" >/dev/null || exit 9
case "${RF_MODE:-}" in patch-fail) exit 1 ;; patch-noop) echo '{}'; exit 0 ;; esac
if [[ "${RF_MODE:-}" == cancel-promote ]]; then finalize-cancel-probe || exit $?; fi
jq '.release.draft=false' "$RF_CASE/context.json" > "$RF_CASE/next.json"
mv "$RF_CASE/next.json" "$RF_CASE/context.json"
if [[ "${RF_MODE:-}" == patch-drift ]]; then
    jq '.[0].id+=100' "$RF_CASE/inventory.json" > "$RF_CASE/next.json"
    mv "$RF_CASE/next.json" "$RF_CASE/inventory.json"
fi
[[ "${RF_MODE:-}" != patch-lost ]] || exit 1
cat "$RF_CASE/context.json"
SH
chmod +x "$WORK/bin/gh"
cat > "$WORK/bin/finalize-cancel-probe" <<'PY'
#!/usr/bin/env python3
import os
from pathlib import Path
import subprocess
import sys

# The transport child has no inherited lock descriptor and resists graceful
# termination. Only its owner's group drain can stop the late mutation.
child = subprocess.Popen([sys.executable, '-c', r'''
import os
from pathlib import Path
import signal
import time
case = Path(os.environ['RF_CASE'])
for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(sig, signal.SIG_IGN)
(case/'transport.pid').write_text(str(os.getpid()))
deadline = time.monotonic() + 20
while not (case/'allow-late-mutation').exists():
    if time.monotonic() >= deadline:
        raise SystemExit(94)
    time.sleep(.02)
(case/'late-mutation').write_text('a cancelled transport still published')
'''], close_fds=True)
child.wait()
PY
chmod +x "$WORK/bin/finalize-cancel-probe"
cat > "$WORK/bin/curl" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
cat >/dev/null
url="${*: -1}" body='' headers='' output=''
while [[ $# -gt 0 ]]; do
    case "$1" in
        --data-binary) body="${2#@}"; shift 2 ;;
        --dump-header) headers="$2"; shift 2 ;;
        --output) output="$2"; shift 2 ;;
        *) shift ;;
    esac
done
repo="${url#https://api.github.com/repos/}"; repo="${repo%/dispatches}"
printf 'post %s\n' "$repo" >> "$RF_CASE/calls"
cp "$body" "$RF_CASE/${repo//\//_}.json"
jq -c --arg repo "$repo" '.+{destination:$repo}' "$body" >> "$RF_CASE/posts.jsonl"
code=204 rc=0 extra=''
case "${RF_MODE:-}" in
    dispatch-reject) [[ "$repo" != owner/b ]] || code=422 ;;
    dispatch-uncertain) if [[ "$repo" == owner/b ]]; then code=000; rc=28; fi ;;
    dispatch-after-first|dispatch-after-last)
        if [[ ( "$RF_MODE" == dispatch-after-first && "$repo" == owner/a ) ||
              ( "$RF_MODE" == dispatch-after-last && "$repo" == owner/b ) ]]; then
            jq '.[0].id+=100' "$RF_CASE/inventory.json" > "$RF_CASE/changed-inventory.json"
            mv "$RF_CASE/changed-inventory.json" "$RF_CASE/inventory.json"
        fi ;;
    dispatch-rate-change)
        code=429; extra=$'Retry-After: 0\r\n'
        jq '.tag_commit=("2"*40)' "$RF_CASE/context.json" > "$RF_CASE/changed-context.json"
        mv "$RF_CASE/changed-context.json" "$RF_CASE/context.json" ;;
esac
printf 'HTTP/2 %s\r\n%s\r\n' "$code" "$extra" > "$headers"
printf '{}' > "$output"
printf '%s' "$code"
exit "$rc"
SH
chmod +x "$WORK/bin/curl"
source "${DISPATCH_TEST_MODULE:-$ROOT/src/dispatch.sh}"
source "$MODULE"
checks=0 failures=0 CASE='' status=0 output=''
check() {
    local label="$1"; shift; checks=$((checks+1))
    if "$@" > "$WORK/check.out" 2>&1; then printf 'ok %d - %s\n' "$checks" "$label"
    else printf 'not ok %d - %s\n' "$checks" "$label"; cat "$WORK/check.out"; failures=$((failures+1)); fi
}
new_case() {
    CASE="$WORK/cases/$1"; mkdir -p "$CASE/artifacts" "$CASE/meta"
    export RF_CASE="$CASE" DSR_STATE_DIR="$CASE/state"
    export DSR_GH_TOKEN=fixture-token DISPATCH_RETRY_DELAY=0 DISPATCH_MAX_WAIT=0 DISPATCH_MAX_RETRIES=3
    unset DISPATCH_STATE_DIR
    unset RF_MODE DRY_RUN
    : > "$CASE/calls"
    printf 'real payload bytes\n' > "$CASE/artifacts/tool.tar.gz"
    jq -nc --arg sha "$RF_SHA" '{repository:{id:7,node_id:"repo-7",full_name:"owner/tool"},
        release:{id:42,node_id:"release-42",tag_name:"v1.0.0",draft:true,prerelease:false,
          target_commitish:"main",upload_url:"https://uploads.github.com/repos/owner/tool/releases/42/assets{?name,label}"},
        tag_commit:$sha}' > "$CASE/context.json"
    printf '[]\n' > "$CASE/inventory.json"
}
run_finalize() { release_finalize "$CASE/artifacts" --repo owner/tool --tag v1.0.0 --sha "$RF_SHA" --output-dir "$CASE/meta" "$@"; }
capture() { status=0; "$@" > "$CASE/out" 2> "$CASE/err" || status=$?; output=$(cat "$CASE/out"); }
count() { grep -c -x "$1" "$CASE/calls" || true; }
state_path() { find "$CASE/state/release-finalize" -name state.json -print | head -1; }
outbox_path() { find "$CASE/state/dispatch" -name state.json -print | head -1; }
handoff() { run_finalize --tool tool --dispatch-repos owner/a,owner/b --promote "$@"; }

new_case ready
capture run_finalize
check 'default finalization verifies but retains draft' test "$status" -eq 0
check 'default result is ready, not falsely published' jq -e '.status=="ready" and .verification.release.draft==true' "$CASE/out"
check 'default mode performs no promotion' test "$(count patch)" -eq 0
check 'inventory is generated before publication' bash -c '[[ "$(grep -n "^generate$" "$1"|cut -d: -f1)" -lt "$(grep -n "^publish$" "$1"|cut -d: -f1)" ]]' bash "$CASE/calls"
check 'state binds exact expected source commit' jq -e --arg sha "$RF_SHA" '.plan.context.tag_commit==$sha and .phase=="evidence_ready"' "$(state_path)"
capture run_finalize --promote
check 'ready release can subsequently be published' test "$status" -eq 0
check 'published result has independently verified public mode' jq -e '.status=="published" and .verification.release.draft==false' "$CASE/out"
check 'promotion changes only draft and disables latest selection' jq -e '.=={draft:false,make_latest:"false"}' "$CASE/patch.json"
check 'only one promotion occurs' test "$(count patch)" -eq 1
check 'promotion state is recorded' jq -e '.phase=="published" and .promotion_attempts==1' "$(state_path)"
cp "$(state_path)" "$CASE/before-state.json"
before_inode=$(stat -c %i "$(state_path)")
capture run_finalize --promote
check 'public retry succeeds without another PATCH' test "$status" -eq 0
check 'public retry does not republish release mode' test "$(count patch)" -eq 1
check 'public retry retains state bytes' cmp -s "$(state_path)" "$CASE/before-state.json"
check 'public retry does not rewrite identical state' test "$(stat -c %i "$(state_path)")" = "$before_inode"

for mode in generate-fail publish-fail publish-false-success verify-fail bad-evidence wrong-manifest wrong-release wrong-commit late-inventory; do
    new_case "$mode"; export RF_MODE="$mode"
    capture run_finalize --promote
    check "$mode fails closed" test "$status" -ne 0
    check "$mode cannot promote a draft" test "$(count patch)" -eq 0
    check "$mode failure is structured" jq -e '.status=="error" and .exit_code!=0 and (.error|length)>0' "$CASE/out"
done

for mode in patch-fail patch-noop patch-drift; do
    new_case "$mode"; export RF_MODE="$mode"
    capture run_finalize --promote
    check "$mode is not reported as completed promotion" test "$status" -ne 0
    check "$mode sends at most one PATCH" test "$(count patch)" -eq 1
    check "$mode preserves a recoverable finalization state" jq -e '.phase=="promoting" and .promotion_attempts==1' "$(state_path)"
done
new_case lost
export RF_MODE=patch-lost
capture run_finalize --promote
check 'lost acknowledgement reconciles actual published release' test "$status" -eq 0
check 'lost acknowledgement records transport failure without replay' jq -e '.status=="published" and .promotion_transport_exit_code==1' "$CASE/out"
check 'lost acknowledgement is not blindly replayed' test "$(count patch)" -eq 1

new_case wrong-source
capture release_finalize "$CASE/artifacts" --repo owner/tool --tag v1.0.0 --sha 2222222222222222222222222222222222222222 --promote
check 'wrong expected commit fails before scanning' test "$(count generate)" -eq 0
check 'wrong expected commit fails before publishing evidence' test "$(count publish)" -eq 0
check 'wrong expected commit is nonzero' test "$status" -eq 7

new_case moved-during-generation
export RF_MODE=moved-during-generation
capture run_finalize --promote
check 'source movement during scan is rejected' test "$status" -eq 7
check 'source movement prevents evidence upload' test "$(count publish)" -eq 0
check 'source movement prevents promotion' test "$(count patch)" -eq 0

new_case changed-release
capture run_finalize
before=$(count generate)
jq '.release.node_id="recreated-release"' "$CASE/context.json" > "$CASE/next.json"
mv "$CASE/next.json" "$CASE/context.json"
capture run_finalize --promote
check 'recreated release conflicts with the saved plan' test "$status" -eq 2
check 'recreated release is rejected before rescanning' test "$(count generate)" -eq "$before"

new_case dry
export RF_MODE=noauth
capture run_finalize --promote --dry-run
check 'dry-run works without authentication' test "$status" -eq 0
check 'dry-run makes no library or API calls' test ! -s "$CASE/calls"
check 'dry-run creates no persistent state' test ! -e "$CASE/state"
check 'dry-run is explicitly planned' jq -e '.status=="planned" and .dry_run==true' "$CASE/out"
export DRY_RUN=true
capture run_finalize --promote
check 'global dry-run also avoids effects' test ! -s "$CASE/calls"

new_case arguments
for option in --sha --repo --tag --output-dir --unknown; do
    capture run_finalize "$option"
    check "malformed option is invalid arguments: $option" test "$status" -eq 4
done
check 'argument failures perform no remote calls' test ! -s "$CASE/calls"

new_case local-drift
capture run_finalize
printf changed >> "$CASE/artifacts/tool.tar.gz"
before=$(count publish)
capture run_finalize --promote
check 'changed local artifact cannot promote' test "$status" -ne 0
check 'local drift detected before further evidence publication' test "$(count publish)" -eq "$before"
check 'local drift does not promote' test "$(count patch)" -eq 0

new_case state-conflict
capture run_finalize
state=$(state_path)
printf '{corrupt' > "$state"
before=$(count publish)
capture run_finalize --promote
check 'corrupt state is rejected' test "$status" -eq 2
check 'corrupt state cannot cause new uploads' test "$(count publish)" -eq "$before"
check 'corrupt state survives for diagnosis' grep -F '{corrupt' "$state"

new_case promotion-intent-failure
mv() {
    local src="${*: -2:1}"
    if [[ "$src" == */state.* ]] && jq -e '.phase=="promoting"' "$src" >/dev/null 2>&1; then return 19; fi
    command mv "$@"
}
capture run_finalize --promote
check 'intent storage failure blocks public mutation' test "$(count patch)" -eq 0
check 'intent storage failure propagates' test "$status" -ne 0
unset -f mv
capture run_finalize --promote
check 'retry safely recovers from unsent promotion intent' test "$status" -eq 0

new_case acknowledgement-store-failure
mv() {
    local src="${*: -2:1}"
    if [[ "$src" == */state.* ]] && jq -e '.phase=="published"' "$src" >/dev/null 2>&1; then return 19; fi
    command mv "$@"
}
capture run_finalize --promote
check 'published-state persistence failure remains an error' test "$status" -ne 0
check 'release was actually promoted before storage failure' test "$(count patch)" -eq 1
unset -f mv
capture run_finalize --promote
check 'retry reconciles promotion after state write failure' test "$status" -eq 0
check 'reconciliation does not repeat PATCH' test "$(count patch)" -eq 1

new_case concurrent
pids=()
for i in 1 2 3 4; do
    bash "$MODULE" "$CASE/artifacts" --repo owner/tool --tag v1.0.0 --sha "$RF_SHA" --output-dir "$CASE/meta" --promote > "$CASE/worker-$i.out" 2> "$CASE/worker-$i.err" &
    pids+=("$!")
done
succeeded=0
for pid in "${pids[@]}"; do if wait "$pid"; then succeeded=$((succeeded+1)); fi; done
check 'one concurrent finalizer completes' test "$succeeded" -ge 1
check 'concurrent finalizers promote once' test "$(count patch)" -eq 1
capture run_finalize --promote
check 'concurrent finalization leaves a reusable completed state' test "$status" -eq 0

new_case cyclonedx
capture run_finalize --format cyclonedx --promote
check 'CycloneDX finalization is supported' test "$status" -eq 0
check 'CycloneDX evidence uses its own manifest name' jq -e '.verification.manifest.name=="sbom-manifest.cdx.json"' "$CASE/out"

new_case handoff
capture handoff
check 'one command finalizes release and acknowledges downstream handoff' test "$status" -eq 0
check 'complete result separates release verification from dispatch acknowledgement' jq -e '.status=="complete" and .verification.release.draft==false and .dispatch.status=="accepted"' "$CASE/out"
check 'each downstream target receives one event' test "$(count 'post owner/a'),$(count 'post owner/b')" = '1,1'
check 'downstream event is bound to the exact verified evidence' jq -e '.client_payload | .sha=="1111111111111111111111111111111111111111" and .release_evidence.release_id==42 and .release_evidence.manifest.asset_id==3 and (.release_evidence.asset_inventory_sha256|length)==64' "$CASE/owner_a.json"
check 'publication precedes every downstream event' bash -c '[[ "$(grep -n "^patch$" "$1"|cut -d: -f1)" -lt "$(grep -n "^post owner/a$" "$1"|cut -d: -f1)" ]]' bash "$CASE/calls"
cp "$CASE/owner_a.json" "$CASE/first-event.json"
capture handoff
check 'completed handoff retry succeeds' test "$status" -eq 0
check 'completed handoff retry sends no duplicate events' test "$(count 'post owner/a'),$(count 'post owner/b')" = '1,1'
check 'completed handoff retry does not republish' test "$(count patch)" -eq 1
check 'handoff plan preserves immutable requests' cmp -s "$CASE/owner_a.json" "$CASE/first-event.json"

new_case handoff-after-ready
capture run_finalize
capture handoff
check 'an initially separate verification can acquire a handoff once' test "$status" -eq 0
capture run_finalize --promote
check 'a recorded handoff cannot silently be omitted' test "$status" -eq 2
capture run_finalize --tool tool --dispatch-repos owner/a --promote
check 'a recorded handoff cannot silently lose a destination' test "$status" -eq 2

new_case handoff-reject
export RF_MODE=dispatch-reject
capture handoff
check 'downstream rejection makes finalization incomplete' test "$status" -eq 1
check 'incomplete JSON retains already-published release and both outcomes' jq -e '.status=="incomplete" and .verification.release.draft==false and [.dispatch.results[].outcome]==["accepted","rejected"]' "$CASE/out"
cp "$CASE/owner_b.json" "$CASE/rejected-event.json"
unset RF_MODE
capture handoff
check 'partial handoff recovers without rebuilding or promotion' test "$status" -eq 0
check 'partial recovery sends only the rejected destination' test "$(count 'post owner/a'),$(count 'post owner/b')" = '1,2'
check 'partial recovery preserves exact evidence-bearing request' cmp -s "$CASE/owner_b.json" "$CASE/rejected-event.json"
check 'partial recovery does not repeat promotion' test "$(count patch)" -eq 1

new_case handoff-uncertain
export RF_MODE=dispatch-uncertain
capture handoff
check 'lost downstream acknowledgement returns uncertainty' test "$status" -eq 8
unset RF_MODE
capture handoff
check 'ordinary finalizer retry does not replay uncertain delivery' test "$(count 'post owner/b')" -eq 1
check 'uncertainty remains visible after ordinary retry' jq -e '.status=="incomplete" and .dispatch.results[1].outcome=="uncertain"' "$CASE/out"
capture handoff --retry-uncertain
check 'explicit uncertain replay is supported by the integrated command' test "$status" -eq 0
check 'explicit uncertain retry revisits only that destination' test "$(count 'post owner/a'),$(count 'post owner/b')" = '1,2'

new_case changed-during-handoff
export RF_MODE=dispatch-after-first
capture handoff
check 'asset movement during handoff returns failure' test "$status" -eq 7
check 'asset movement prevents later destinations from being triggered' test "$(count 'post owner/a'),$(count 'post owner/b')" = '1,0'
check 'already accepted and unsent outcomes survive the late gate failure' jq -e '[.dispatch.results[].outcome]==["accepted","pending"]' "$CASE/out"

new_case changed-after-last
export RF_MODE=dispatch-after-last
capture handoff
check 'change after the final POST prevents false overall completion' test "$status" -eq 7
check 'post-delivery failure retains actual acknowledged outcomes' jq -e '.status=="incomplete" and .dispatch.status=="accepted"' "$CASE/out"

new_case changed-during-rate-limit
export RF_MODE=dispatch-rate-change
capture handoff
check 'release gate runs again before a rate-limit retry' test "$status" -eq 7
check 'rate-limit gate prevents second POST and all later destinations' test "$(count 'post owner/a'),$(count 'post owner/b')" = '1,0'
check 'rate-limit gate produces a retryable blocked outcome' jq -e '.dispatch.results[0].outcome=="blocked" and .dispatch.results[0].receipt.attempts==1' "$CASE/out"

new_case post-intent-gate
mv() {
    local src="${*: -2:1}"
    if [[ "$src" == */state.* ]] && jq -e '.kind=="dsr-dispatch-outbox" and any(.deliveries[];.history[-1].outcome=="sending")' "$src" >/dev/null 2>&1; then
        command mv "$@" || return $?
        jq '.tag_commit=("2"*40)' "$RF_CASE/context.json" > "$RF_CASE/changed-context.json"
        command mv "$RF_CASE/changed-context.json" "$RF_CASE/context.json"
    else command mv "$@"; fi
}
capture handoff
check 'release movement after persisted intent still prevents POST' test "$(count 'post owner/a')" -eq 0
check 'pre-POST gate failure is blocked, not falsely uncertain' jq -e '.dispatch.results[0].outcome=="blocked" and .dispatch.results[0].receipt.attempts==0' "$CASE/out"
unset -f mv
jq --arg sha "$RF_SHA" '.tag_commit=$sha' "$CASE/context.json" > "$CASE/restored-context.json"
mv "$CASE/restored-context.json" "$CASE/context.json"
capture handoff
check 'known-unsent blocked delivery resumes without uncertain replay consent' test "$status" -eq 0
check 'blocked recovery sends each destination once' test "$(count 'post owner/a'),$(count 'post owner/b')" = '1,1'

new_case malformed-handoff
capture run_finalize --tool tool --dispatch-repos owner/a,../invalid --promote
check 'invalid downstream target fails before all library effects' test ! -s "$CASE/calls"
capture run_finalize --dispatch-repos owner/a --promote
check 'tool identity is required for downstream events' test "$status" -eq 4
capture run_finalize --tool tool --dispatch-repos owner/a,owner/b
check 'a draft cannot trigger downstream without explicit promotion consent' test "$status" -eq 4
check 'unapproved draft cannot upload evidence or dispatch' test "$(count publish),$(count 'post owner/a')" = '0,0'

new_case dispatch-dry
capture handoff --dry-run
check 'handoff dry-run does not call transport or scanner libraries' test ! -s "$CASE/calls"
check 'handoff dry-run does not create state' test ! -e "$CASE/state"
check 'handoff dry-run lists the selected destinations' jq -e '.dispatch_repos==["owner/a","owner/b"]' "$CASE/out"

new_case existing-outbox-conflict
capture dispatch_release tool v1.0.0 --sha "$RF_SHA" --source-repo owner/tool --repos owner/a,owner/b
check 'existing generic dispatch fixture completed' test "$status" -eq 0
capture handoff
check 'mismatched old outbox is not silently upgraded or resent' test "$status" -eq 2
check 'mismatched old outbox prevents promotion' test "$(count patch)" -eq 0
check 'mismatched old outbox creates no extra events' test "$(count 'post owner/a'),$(count 'post owner/b')" = '1,1'

for scenario in cli:TERM:generate cli:INT:publish sourced:TERM:promote sourced:INT:generate cli:KILL:publish \
    cli:TERM:nested cli:KILL:nested sourced:TERM:adapter; do
    new_case "cancel-${scenario//:/-}"
    export RF_MODE="cancel-${scenario##*:}"
    check "$scenario cancellation drains transport descendants before releasing state custody" \
        python3 - "$MODULE" "$CASE" "$scenario" <<'PY'
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

module, directory, scenario = sys.argv[1:]
case = Path(directory)
route, selected_signal, phase = scenario.split(':')
arguments = [str(case/'artifacts'), '--repo', 'owner/tool', '--tag', 'v1.0.0',
             '--sha', os.environ['RF_SHA'], '--output-dir', str(case/'meta'), '--promote']
if route == 'sourced':
    driver = r'''
source "$1" || exit 90
shift
trap ': caller signal trap' HUP INT TERM PIPE
trap ': caller exit trap' EXIT
before=$(trap -p HUP INT TERM PIPE EXIT)
before_mask=$(umask)
before_options=$-
release_finalize "$@"
rc=$?
[[ $(trap -p HUP INT TERM PIPE EXIT) == "$before" && $(umask) == "$before_mask" && $- == "$before_options" ]] || exit 99
exit "$rc"
'''
    command = ['bash', '-c', driver, '_', module, *arguments]
else:
    command = ['bash', module, *arguments]
(case/'tmp').mkdir()
env = dict(os.environ, TMPDIR=str(case/'tmp'))
pidfile = case/'transport.pid'
child = None
proc = None

def alive(pid):
    try:
        os.kill(pid, 0)
        stat = Path('/proc')/str(pid)/'stat'
        return not stat.exists() or stat.read_text().split(') ', 1)[1].split()[0] != 'Z'
    except (ProcessLookupError, FileNotFoundError):
        return False

try:
    with (case/'cancel.out').open('wb') as out, (case/'cancel.err').open('wb') as err:
        proc = subprocess.Popen(command, env=env, stdout=out, stderr=err, start_new_session=True)
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline and not pidfile.exists() and proc.poll() is None:
            time.sleep(.02)
        assert pidfile.exists(), 'finalizer did not reach the transport: ' + (case/'cancel.err').read_text()
        child = int(pidfile.read_text())
        locks = list((case/'state/release-finalize').glob('*/lock'))
        assert len(locks) == 1, 'release session lock was not acquired'
        with locks[0].open('a') as lock:
            proc.send_signal(getattr(signal, 'SIG'+selected_signal))
            deadline = time.monotonic() + 12
            while time.monotonic() < deadline:
                released = False
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    pass
                else:
                    assert not alive(child), 'release lock became free while an upload descendant was still live'
                    fcntl.flock(lock, fcntl.LOCK_UN)
                    released = True
                if proc.poll() is not None:
                    if selected_signal != 'KILL':
                        assert not alive(child), 'public finalization returned before its transport finished draining'
                        break
                    # A killed caller has no return boundary. Its independent
                    # anchors may still be retiring after the transport dies.
                    if not alive(child) and released:
                        break
                time.sleep(.01)
            code = proc.wait(timeout=1)
            assert not alive(child), 'a cancelled transport survived the owner'
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            fcntl.flock(lock, fcntl.LOCK_UN)
    if selected_signal == 'KILL':
        assert code == -signal.SIGKILL, 'owner-death fixture did not kill its waiter'
    else:
        result = json.loads((case/'cancel.out').read_text())
        assert code == 5 and result['exit_code'] == 5 and result['status'] == 'error', (code, result)
        assert result['error'] == 'Release finalization interrupted', result
    (case/'allow-late-mutation').touch()
    time.sleep(.1)
    assert not (case/'late-mutation').exists(), 'publication continued after cancellation'
    assert json.loads((case/'context.json').read_text())['release']['draft'] is True, 'cancelled work promoted the release'
    state = json.loads(next((case/'state/release-finalize').glob('*/state.json')).read_text())
    assert state['phase'] != 'published', 'cancellation falsely recorded successful publication'
finally:
    if proc is not None and proc.poll() is None:
        proc.kill()
        proc.wait()
    if child is not None and alive(child):
        os.kill(child, signal.SIGKILL)
PY
    unset RF_MODE
    capture run_finalize --promote
    check "$scenario cancellation retains a resumable verified release session" test "$status" -eq 0
done

new_case cancel-before-launch
check 'an interrupt during supervisor setup prevents all publication work and preserves caller traps' \
    bash -c '
source "$1" || exit 90
trap ": caller signal trap" HUP INT TERM PIPE
trap ": caller exit trap" EXIT
before=$(trap -p HUP INT TERM PIPE EXIT)
type() {
    if [[ "$*" == "-P sleep" ]]; then kill -TERM "$BASHPID"; fi
    builtin type "$@"
}
_rf_execute() { : > "$RF_CASE/unexpected-engine"; return 91; }
release_finalize fixture > "$RF_CASE/cancel.out"
rc=$?
[[ $rc == 5 && ! -e "$RF_CASE/unexpected-engine" && $(trap -p HUP INT TERM PIPE EXIT) == "$before" ]] || exit 1
jq -es "length==1 and (.[0]|.kind==\"dsr-release-finalization-result\" and .exit_code==5 and .status==\"error\")" "$RF_CASE/cancel.out"
' _ "$MODULE"

new_case sourced-input
check 'the sourced finalizer preserves stdin scripts, data streams and payload exit status' \
    python3 - "$MODULE" <<'PY'
import json
import subprocess
import sys

module = sys.argv[1]
script = r'''
set -uo pipefail
source "$1" || exit 90
release_finalize "$RF_CASE/artifacts" --repo owner/tool --tag v1.0.0 --sha "$RF_SHA" --dry-run
rc=$?
printf 'caller continued\n' >&2
exit "$rc"
'''
result = subprocess.run(['bash', '-s', '--', module], input=script, text=True,
                        capture_output=True, timeout=10)
assert result.returncode == 0, (result.returncode, result.stderr)
assert json.loads(result.stdout)['status'] == 'planned', result.stdout
assert result.stderr == 'caller continued\n', result.stderr
script = r'''
set -uo pipefail
source "$1" || exit 90
_rf_execute() {
    local payload
    IFS= read -r payload || return 91
    jq -cn --arg payload "$payload" '{kind:"dsr-release-finalization-result",status:"error",exit_code:23,payload:$payload}'
    return 23
}
release_finalize fixture
'''
data = 'spaces, $literal and ; shell punctuation'
result = subprocess.run(['bash', '-c', script, '_', module], input=data+'\n', text=True,
                        capture_output=True, timeout=10)
assert result.returncode == 23, (result.returncode, result.stderr)
report = json.loads(result.stdout)
assert report['exit_code'] == 23 and report['payload'] == data, report
PY

check 'a completion message split across read deadlines preserves the actual worker exit' \
    bash -c '
source "$1" || exit 90
printf() {
    case "$1" in
        exit:*) builtin printf "exit:"; command sleep 0.2; builtin printf "%s\n" "$2" ;;
        *) builtin printf "$@" ;;
    esac
}
reject() { return 4; }
rc=0
_rf_run_owned 1 reject || rc=$?
[[ $rc == 4 ]]
' _ "$MODULE"

# Keep an interactive session controller alive when killing the public caller:
# killing the PTY session leader would send SIGHUP and mask lease-EOF defects.
# The payload models an encrypted-key prompt, not cryptographic signing.
test_finalization_tty() {
    python3 - "$MODULE" "$CASE" <<'PY'
import json
import os
from pathlib import Path
import pty
import select
import signal
import subprocess
import sys
import time

module, directory = sys.argv[1:]
driver = r'''
set -uo pipefail
source "$1" || exit 90
if [[ "$RF_TTY_MONITOR" == on ]]; then set -m; else set +m; fi
trap ': caller suspension trap' TSTP
printf '%s\n' "$BASHPID" > "$RF_CASE/owner.pid"
snapshot() {
    local flags="$-" suspension
    suspension=$(trap -p TSTP)
    set +m
    python3 -c 'import json,os,sys
from pathlib import Path
path,pid,flags,suspension=sys.argv[1:]; pid=int(pid)
fd=os.open("/dev/tty",os.O_RDWR|os.O_NOCTTY)
Path(path).write_text(json.dumps(dict(pid=pid,pgrp=os.getpgid(pid),foreground=os.tcgetpgrp(fd),monitor="m" in flags,suspension=suspension)))
os.close(fd)' "$RF_CASE/$1.json" "$BASHPID" "$flags" "$suspension"
    [[ "$flags" != *m* ]] || set -m
    return 0
}
tty_payload() {
    exec 3<>/dev/tty || return 91
    printf '%s\n' "$BASHPID" > "$RF_CASE/payload.pid"
    python3 -c 'import os,signal,sys,time
from pathlib import Path
for sig in (signal.SIGTERM,signal.SIGHUP,signal.SIGINT): signal.signal(sig,signal.SIG_IGN)
Path(sys.argv[1]).write_text(str(os.getpid()))
while True: time.sleep(.1)' "$RF_CASE/resistant.pid" &
    while [[ ! -s "$RF_CASE/resistant.pid" ]]; do command sleep .01; done
    printf 'Fixture password prompt: ' >&3
    : > "$RF_CASE/ready"
    local reply=''
    IFS= read -r reply <&3 || return 92
    [[ "$reply" == fixture-only ]] || return 93
    printf '%s\n' '{"kind":"dsr-release-finalization-result","status":"complete","exit_code":0,"reply_received":true}'
}
_rf_execute() {
    printf '%s\n' "$BASHPID" > "$RF_CASE/engine.pid"
    _rf_run_owned 2 tty_payload
}
if [[ "$RF_TTY_EVENT" == missing-python ]]; then
    command() {
        [[ "$*" != '-v python3' ]] || return 1
        builtin command "$@"
    }
fi
snapshot before
rc=0
release_finalize fixture > "$RF_CASE/result.json" || rc=$?
snapshot after
printf '%s\n' "$rc" > "$RF_CASE/rc"
exit "$rc"
'''

def processes():
    rows = subprocess.check_output(['ps', '-e', '-o', 'pid=,ppid=,pgid=,stat='], text=True)
    return {int(pid): (int(parent), int(group), state)
            for pid, parent, group, state in (row.split() for row in rows.splitlines())}

def active(pids):
    current = processes()
    return {pid for pid in pids if pid in current and current[pid][2][0] not in ('Z', 'X')}

for monitor in ('off', 'on'):
    for event in ('success', 'ctrl-c', 'ctrl-z', 'pid-term', 'owner-kill', 'missing-python'):
        case = Path(directory) / (monitor + '-' + event)
        case.mkdir()
        env = {key: value for key, value in os.environ.items()
               if key not in ('BASH_ENV', 'ENV') and not key.startswith('BASH_FUNC_')}
        env.update(RF_CASE=str(case), RF_TTY_MODULE=module, RF_TTY_DRIVER=driver,
                   RF_TTY_MONITOR=monitor, RF_TTY_EVENT=event, HISTFILE='/dev/null',
                   PS1='FINALIZE_PTY> ', PS2='CONTINUE> ', TERM='dumb')
        shell, terminal = pty.fork()
        if shell == 0:
            os.execvpe('bash', ['bash', '--noprofile', '--norc', '-i'], env)
        transcript, owned = bytearray(), set()

        def pump():
            if select.select([terminal], [], [], .02)[0]:
                try:
                    transcript.extend(os.read(terminal, 65536))
                except OSError:
                    pass

        def until(predicate, seconds=12):
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                if predicate():
                    return True
                pump()
            return bool(predicate())

        try:
            assert until(lambda: b'FINALIZE_PTY> ' in transcript), 'session controller did not start'
            os.write(terminal, b'bash -c "$RF_TTY_DRIVER" _ "$RF_TTY_MODULE"\n')
            if event != 'missing-python':
                assert until(lambda: (case/'ready').exists()), 'nested terminal reader did not start'
                owner, engine, payload = (int((case/(name+'.pid')).read_text())
                                          for name in ('owner', 'engine', 'payload'))
                table = processes()
                owned = {owner}
                while True:
                    descendants = {pid for pid, row in table.items() if row[0] in owned} - owned
                    if not descendants:
                        break
                    owned.update(descendants)
                assert len({table[pid][1] for pid in (owner, engine, payload)}) == 3, 'nested groups are not isolated'
                assert os.tcgetpgrp(terminal) == table[payload][1], 'password reader does not own foreground'
                if event == 'success':
                    os.write(terminal, b'fixture-only\n')
                elif event in ('ctrl-c', 'ctrl-z'):
                    os.write(terminal, b'\x03' if event == 'ctrl-c' else b'\x1a')
                else:
                    os.kill(owner, signal.SIGTERM if event == 'pid-term' else signal.SIGKILL)
                if event == 'owner-kill':
                    assert until(lambda: os.tcgetpgrp(terminal) == shell), 'session controller did not reclaim foreground'
                    os.write(terminal, b'\n')
                    assert until(lambda: not active(owned)), 'lease EOF left an owned descendant alive'
                    assert not (case/'rc').exists() and not (case/'result.json').read_text().strip(), 'dead owner reported success'
                    print('PASS PTY ' + case.name, flush=True)
                    continue
            assert until(lambda: (case/'rc').exists()), 'public finalization did not return'
            code = int((case/'rc').read_text())
            result = json.loads((case/'result.json').read_text())
            expected = 0 if event == 'success' else 3 if event == 'missing-python' else 5
            assert code == expected and result['exit_code'] == expected, (code, result)
            assert result['kind'] == 'dsr-release-finalization-result', result
            if event == 'success':
                assert result.get('reply_received') is True, result
            elif event == 'missing-python':
                assert not (case/'engine.pid').exists() and not (case/'ready').exists(), 'missing dependency admitted work'
            else:
                assert result['status'] == 'error' and result['error'] == 'Release finalization interrupted', result
            before, after = (json.loads((case/(phase+'.json')).read_text()) for phase in ('before', 'after'))
            assert before == after and before['monitor'] == (monitor == 'on'), (before, after)
            assert before['foreground'] == before['pgrp'], 'caller did not regain its terminal'
            assert not active(owned - {before['pid']}), 'owned work survived public return'
            assert until(lambda: os.tcgetpgrp(terminal) == shell), 'launching shell lost its terminal'
            print('PASS PTY ' + case.name, flush=True)
        except Exception as error:
            raise AssertionError(case.name + ': ' + str(error)) from error
        finally:
            (case/'transcript').write_bytes(transcript)
            for pid in active(owned):
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            try:
                os.write(terminal, b'exit\n')
            except OSError:
                pass
            if not until(lambda: os.waitpid(shell, os.WNOHANG)[0] == shell, 2):
                os.kill(shell, signal.SIGKILL)
                os.waitpid(shell, 0)
            os.close(terminal)
PY
}

new_case terminal-lifecycle
check 'terminal prompts, interrupts and owner death preserve foreground, monitor mode and descendant custody' \
    test_finalization_tty

new_case handoff-concurrent
pids=()
for i in 1 2 3 4; do
    bash "$MODULE" "$CASE/artifacts" --repo owner/tool --tag v1.0.0 --sha "$RF_SHA" --output-dir "$CASE/meta" --promote \
        --tool tool --dispatch-repos owner/a,owner/b > "$CASE/worker-$i.out" 2> "$CASE/worker-$i.err" &
    pids+=("$!")
done
succeeded=0
for pid in "${pids[@]}"; do if wait "$pid"; then succeeded=$((succeeded+1)); fi; done
check 'one complete concurrent pipeline succeeds' test "$succeeded" -ge 1
check 'concurrent pipelines publish once' test "$(count patch)" -eq 1
check 'concurrent pipelines dispatch each target once' test "$(count 'post owner/a'),$(count 'post owner/b')" = '1,1'

printf '\nRelease finalization checks: %d; failures: %d\n' "$checks" "$failures"
[[ "$failures" -eq 0 ]]
