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
sbom_publish_artifacts() {
    trace publish
    [[ "${RF_MODE:-}" != publish-fail ]] || return 7
    [[ "${RF_MODE:-}" != publish-false-success ]] || { printf '{}\n'; return 0; }
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
state_path() { find "$CASE/state" -name state.json -print | head -1; }

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

printf '\nRelease finalization checks: %d; failures: %d\n' "$checks" "$failures"
[[ "$failures" -eq 0 ]]
