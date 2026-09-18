#!/usr/bin/env bash
# Real manifests, SHA256, snapshots, files and locks; GitHub transport is a
# file-backed fixture. No live release or signing credentials are used.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
source "$ROOT/src/slsa.sh"
source "$ROOT/src/sbom.sh"
source "$ROOT/src/sbom_release.sh"
source "$ROOT/src/release_payloads.sh"
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
PIN=1111111111111111111111111111111111111111
checks=0 failures=0 CASE='' ART='' MANIFEST='' status=0
check() {
    local label="$1"; shift; checks=$((checks+1))
    if "$@" > "$WORK/assertion.out" 2>&1; then printf 'ok %s - %s\n' "$checks" "$label"
    else printf 'not ok %s - %s\n' "$checks" "$label"; cat "$WORK/assertion.out"; failures=$((failures+1)); fi
}
nonzero() { [[ "$1" -ne 0 ]]; }
count() { wc -l < "$CASE/uploads"; }
state_path() { find "$CASE/state" -name state.json -type f | head -1; }
capture() { status=0; "$@" > "$CASE/out" 2> "$CASE/err" || status=$?; }
change_json() { jq "$2" "$1" > "$CASE/next.json" && mv "$CASE/next.json" "$1"; }
_sbr_require() { printf 'auth\n' >> "$CASE/auth"; }
_sbr_run() { "$@"; }
_sbr_context() { cat "$CASE/context.json"; }
_sbr_inventory() { cat "$CASE/inventory.json"; }
gh_download_release_asset() {
    printf '%s\n' "$2" >> "$CASE/downloads"
    cp "$CASE/remote/$2" "$3"
}
gh_upload_asset_named() {
    local url="$1" path="$2" name="$3" mime="$4" id hash size receipt
    [[ "$url" == 'https://uploads.github.com/repos/owner/tool/releases/17/assets{?name,label}' && "$mime" == application/octet-stream ]] || return 4
    [[ "$path" != "$ART/"* && -f "${path%/*}/a.tar.gz" && -f "${path%/*}/b.zip" && -f "${path%/*}/z-compat.tar.gz" ]] || return 4
    printf '%s\n' "$name" >> "$CASE/uploads"
    if [[ "$name" == b.zip && "${MODE:-}" == fail ]]; then return 7; fi
    id=$(jq '([.[].id]+[100]|max)+1' "$CASE/inventory.json")
    hash=$(_slsa_sha256 "$path") || return 1
    size=$(wc -c < "$path")
    receipt=$(jq -nc --arg name "$name" --arg hash "$hash" --argjson size "$size" --argjson id "$id" \
        '{id:$id,name:$name,state:"uploaded",size:$size,digest:("sha256:"+$hash)}') || return 1
    if [[ "${MODE:-}" == false_success ]]; then printf '%s\n' "$receipt"; return 0; fi
    cp "$path" "$CASE/remote/$id" || return 1
    if [[ "${MODE:-}" == no_digest ]]; then receipt=$(jq '.digest=null' <<< "$receipt"); fi
    if [[ "${MODE:-}" == corrupt ]]; then
        printf changed >> "$CASE/remote/$id"
        receipt=$(jq --arg digest "sha256:$(_slsa_sha256 "$CASE/remote/$id")" '.digest=$digest' <<< "$receipt")
    fi
    jq -cS --argjson item "$receipt" '.+[$item]|sort_by(.name)' "$CASE/inventory.json" > "$CASE/inventory.next"
    mv "$CASE/inventory.next" "$CASE/inventory.json"
    case "${MODE:-}" in
        source_drift) printf changed >> "$ART/z-compat.tar.gz" ;;
        stage_drift) chmod u+w "${path%/*}/z-compat.tar.gz"; printf changed >> "${path%/*}/z-compat.tar.gz" ;;
        moved_tag) change_json "$CASE/context.json" '.tag_commit=("2"*40)' ;;
        promoted) change_json "$CASE/context.json" '.release.draft=false' ;;
        wrong_receipt) receipt=$(jq '.id=900' <<< "$receipt") ;;
        lost) [[ "$name" != b.zip ]] || return 8 ;;
    esac
    printf '%s\n' "$receipt"
}
make_manifest() {
    local name target hash size entries=''
    for name in a.tar.gz b.zip z-compat.tar.gz; do
        [[ -f "$ART/$name" ]] || continue
        target=linux/amd64; [[ "$name" != b.zip ]] || target=windows/amd64
        hash=$(_slsa_sha256 "$ART/$name"); size=$(wc -c < "$ART/$name")
        entries+="$(jq -nc --arg name "$name" --arg target "$target" --arg sha "$hash" --argjson size "$size" \
            '{name:$name,target:$target,sha256:$sha,size_bytes:$size,archive_format:"binary",path:"/private/not-a-source"}')"$'\n'
    done
    jq -sc --arg sha "$PIN" '
        {schema_version:"1.0.0",tool:"tool",version:"v1.0.0",run_id:"build-1",status:"success",
         built_at:"2026-09-18T00:00:00Z",source:{git_sha:$sha,git_ref:"v1.0.0",dependencies:[]},
         artifacts:.,summary:{total:(map(.target)|unique|length),success:(map(.target)|unique|length),failed:0}}' \
        <<< "$entries" > "$MANIFEST"
}
new_case() {
    CASE="$WORK/$1"; ART="$CASE/artifacts"; MANIFEST="$CASE/manifest.json"
    mkdir -p "$ART" "$CASE/remote"
    : > "$CASE/uploads"; : > "$CASE/auth"; : > "$CASE/downloads"
    printf 'linux payload\n' > "$ART/a.tar.gz"
    printf 'windows payload\n' > "$ART/b.zip"
    ln "$ART/a.tar.gz" "$ART/z-compat.tar.gz"
    printf '{"private":"never upload"}\n' > "$ART/private.json"
    make_manifest
    printf '[]\n' > "$CASE/inventory.json"
    jq -cSn --arg sha "$PIN" '
        {repository:{id:9,node_id:"repo-9",full_name:"owner/tool"},
         release:{id:17,node_id:"release-17",tag_name:"v1.0.0",draft:true,prerelease:false,target_commitish:"main",
           upload_url:"https://uploads.github.com/repos/owner/tool/releases/17/assets{?name,label}"},tag_commit:$sha}' > "$CASE/context.json"
    unset MODE DRY_RUN
}
upload() { release_upload_payloads "$ART" --build-manifest "$MANIFEST" --repo owner/tool --tag v1.0.0 --sha "$PIN" --state-dir "$CASE/state" "$@"; }
seed() {
    local name="$1" id="$2" hash size
    cp "$ART/$name" "$CASE/remote/$id"
    hash=$(_slsa_sha256 "$ART/$name"); size=$(wc -c < "$ART/$name")
    jq -cS --arg name "$name" --arg sha "$hash" --argjson size "$size" --argjson id "$id" \
        '.+[{id:$id,name:$name,state:"uploaded",size:$size,digest:("sha256:"+$sha)}]|sort_by(.name)' \
        "$CASE/inventory.json" > "$CASE/inventory.next"
    mv "$CASE/inventory.next" "$CASE/inventory.json"
}
if [[ "${DSR_PAYLOAD_FIXTURES_ONLY:-false}" == true ]]; then return 0; fi
new_case complete
capture upload
check 'all payloads upload from verified snapshots' test "$status" -eq 0
check 'versioned and compatibility aliases remain distinct' test "$(count)" -eq 3
check 'receipt verifies all assets' jq -e '.status=="verified" and .dry_run==false and (.assets|length)==3 and .upload_attempts==3' "$CASE/out"
check 'private metadata is never uploaded' jq -e 'all(.[];.name!="private.json" and .name!="manifest.json")' "$CASE/inventory.json"
state=$(state_path); cp "$state" "$CASE/saved"
check 'state pins complete artifact identities' jq -e '.complete and (.assets|length)==3 and .plan.context.tag_commit==("1"*40)' "$state"
capture upload
check 'completed retry succeeds' test "$status" -eq 0
check 'completed retry reuses every asset' test "$(count)" -eq 3
check 'completed state is byte-stable' cmp -s "$state" "$CASE/saved"
change_json "$CASE/context.json" '.release.draft=false'
capture upload
check 'complete public release can be verified read-only' test "$status" -eq 0
check 'published retry never uploads' test "$(count)" -eq 3
new_case partial
MODE=fail; capture upload
check 'later upload failure propagates' test "$status" -eq 7
check 'first asset is retained' jq -e 'length==1 and .[0].name=="a.tar.gz"' "$CASE/inventory.json"
state=$(state_path)
check 'partial state persists completed ID' jq -e '(.complete|not) and (.assets|length)==1' "$state"
unset MODE; capture upload
check 'partial upload resumes' test "$status" -eq 0
check 'partial retry does not resend acknowledged asset' test "$(count)" -eq 4
new_case lost
MODE=lost; capture upload
check 'lost acknowledgement reports failure' test "$status" -eq 8
check 'lost acknowledgement leaves remote bytes' jq -e 'length==2' "$CASE/inventory.json"
unset MODE; capture upload
check 'retry reconciles lost acknowledgement' test "$status" -eq 0
check 'lost acknowledgement never requires duplicate upload' test "$(count)" -eq 3
new_case missing_digest
MODE=no_digest; capture upload
check 'missing digests use immutable-ID download' test "$status" -eq 0
check 'download fallback actually executed' test -s "$CASE/downloads"
change_json "$CASE/inventory.json" '.[0].digest="sha256:bad"'
before=$(wc -l < "$CASE/downloads"); capture upload
check 'mismatched digest cannot fall back' nonzero "$status"
check 'mismatched digest gets no weaker download' test "$(wc -l < "$CASE/downloads")" -eq "$before"
for filter in '.status="failed"' '.source.git_sha=("2"*40)' '.version="v2.0.0"' '.summary.failed=1' '.summary.total=3' '.artifacts += [.artifacts[0]]' '.artifacts[0].name="../escape"' '.artifacts[0].size_bytes=1' '.artifacts[0].sha256=("0"*64)' '.artifacts=[]' '.hosts=[{platform:"linux/amd64",status:"success"}]'; do
    new_case "manifest-$checks"
    change_json "$MANIFEST" "$filter"; capture upload
    check "manifest rejects $filter" nonzero "$status"
    check 'invalid manifest makes no upload' test "$(count)" -eq 0
done
new_case extra_local
printf extra > "$ART/unplanned.zip"; capture upload
check 'extra local payload is rejected' nonzero "$status"
check 'local set conflict precedes auth' test ! -s "$CASE/auth"
new_case linked
mv "$ART/b.zip" "$CASE/b.saved"; ln -s "$CASE/b.saved" "$ART/b.zip"; capture upload
check 'linked payload is rejected' nonzero "$status"
check 'linked payload makes no partial release' test "$(count)" -eq 0
for mode in source_drift stage_drift moved_tag promoted wrong_receipt false_success corrupt; do
    new_case "$mode"; MODE="$mode"; capture upload
    check "$mode stops publication" nonzero "$status"
    check "$mode stops later targets" test "$(count)" -eq 1
    check "$mode emits no verified receipt" test ! -s "$CASE/out"
done
for filter in '.[0].digest=("sha256:"+("0"*64))' '.[0].size+=1' '.[0].state="starter"'; do
    new_case "occupied-$checks"; seed b.zip 80; change_json "$CASE/inventory.json" "$filter"; capture upload
    check "occupied conflict: $filter" nonzero "$status"
    check 'all targets preflight before first upload' test "$(count)" -eq 0
done
new_case orphan
jq -nc '[{id:80,name:"b.zip.minisig",state:"uploaded",size:10,digest:null}]' > "$CASE/inventory.json"; capture upload
check 'orphan signature blocks new payload' nonzero "$status"
check 'orphan conflict blocks earlier uploads' test "$(count)" -eq 0
new_case extra_remote
jq -nc '[{id:80,name:"unplanned.zip",state:"uploaded",size:10,digest:null}]' > "$CASE/inventory.json"; capture upload
check 'unexpected remote payload is rejected' nonzero "$status"
check 'unexpected payload is retained' jq -e 'length==1 and .[0].id==80' "$CASE/inventory.json"
new_case changed_plan
MODE=fail; capture upload; unset MODE
mv "$ART/b.zip" "$CASE/b.saved"; make_manifest; capture upload
check 'retry cannot drop unfinished manifest target' test "$status" -eq 2
check 'changed plan makes no additional uploads' test "$(count)" -eq 2
new_case replaced_id
capture upload
change_json "$CASE/inventory.json" '.[0].id=999'; capture upload
check 'replaced asset ID is rejected on retry' nonzero "$status"
check 'replacement never triggers clobber' test "$(count)" -eq 3
new_case public_missing
change_json "$CASE/context.json" '.release.draft=false'; capture upload
check 'incomplete public release is not modified' test "$status" -eq 4
check 'public missing payload receives no upload' test "$(count)" -eq 0
new_case dry
capture upload --dry-run
check 'dry-run produces local plan' test "$status" -eq 0
check 'dry-run performs no auth' test ! -s "$CASE/auth"
check 'dry-run creates no persistent state' test ! -e "$CASE/state"
check 'dry-run is not verified' jq -e '.status=="planned" and .dry_run' "$CASE/out"
DRY_RUN=true; capture upload
check 'global dry-run honored' test "$(count)" -eq 0
new_case copy_failure
cp() { [[ "$1" != -- ]] || return 19; command cp "$@"; }
capture upload
check 'staging failure blocks all uploads' test "$(count)" -eq 0
check 'staging failure remains nonzero' nonzero "$status"
unset -f cp
new_case state_failure
ln() { [[ "$*" != *state.json* ]] || return 19; command ln "$@"; }
capture upload
check 'failed plan persistence blocks all uploads' test "$(count)" -eq 0
check 'failed plan persistence is nonzero' nonzero "$status"
unset -f ln
new_case concurrent
pids=()
for i in 1 2 3 4; do upload > "$CASE/worker-$i.out" 2> "$CASE/worker-$i.err" & pids+=("$!"); done
passed=0
for pid in "${pids[@]}"; do if wait "$pid"; then passed=$((passed+1)); fi; done
check 'competing publisher completes' test "$passed" -ge 1
check 'concurrent publishers send each name once' test "$(count)" -eq 3
capture upload
check 'concurrent result verifies on retry' test "$status" -eq 0
printf '\nPayload publication checks: %d; failures: %d\n' "$checks" "$failures"
[[ "$failures" -eq 0 ]]
