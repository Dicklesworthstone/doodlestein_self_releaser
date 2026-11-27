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
        # The staged payload is 0400 and cp keeps that: make the fixture's
        # remote copy writable or nothing is corrupted (non-root runs).
        chmod u+w "$CASE/remote/$id" || return 1
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
        inventory_drift) change_json "$CASE/inventory.json" 'map(if .id==1000 then .size+=1 else . end)' ;;
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
# Called indirectly through capture, which forwards optional publication flags.
# shellcheck disable=SC2120
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
payload_seed_large_inventory() {
    # The existing metadata is deliberately outside the selected payload set.
    # Its complete remote identity still participates in every publication gate.
    change_json "$CASE/inventory.json" '. + [range(0;500) |
        {id:(1000+.),name:("existing-"+(("0000"+tostring)[-4:])+"-"+("x"*195)+".json"),
         state:"uploaded",size:7,digest:("sha256:"+("a"*64))}] | sort_by(.name)'
}
payload_large_inventory_cases() {
    local saved_state inventory plan pinned filter
    new_case large_inventory
    payload_seed_large_inventory
    cp "$CASE/inventory.json" "$CASE/original-inventory.json"
    check 'payload inventory exceeds the single-argument limit' test "$(wc -c < "$CASE/inventory.json")" -gt 131072
    capture upload
    check 'large remote inventory permits complete payload publication' test "$status" -eq 0
    check 'large release uploads each selected payload once' test "$(count)" -eq 3
    check 'large release receipt retains all selected asset identities' jq -es \
        'length==1 and (.[0]|.status=="verified" and .upload_attempts==3 and (.assets|length)==3)' "$CASE/out"
    check 'large publication preserves every existing metadata row' jq -es \
        --slurpfile original "$CASE/original-inventory.json" \
        'length==1 and (.[0]|map(select(.id>=1000 and .id<1500)))==$original[0]' "$CASE/inventory.json"
    saved_state=$(state_path)
    check 'large publication persists a complete verified payload set' jq -e \
        '.complete and (.assets|length)==3 and .plan.context.tag_commit==("1"*40)' "$saved_state"
    if [[ -n "$saved_state" ]]; then cp "$saved_state" "$CASE/saved-state.json"; fi
    capture upload
    check 'large completed publication can resume' test "$status" -eq 0
    check 'large completed retry never reuploads payloads' test "$(count)" -eq 3
    check 'large completed retry preserves exact checkpoint bytes' cmp -s "$saved_state" "$CASE/saved-state.json"
    change_json "$CASE/inventory.json" 'map(if .name=="b.zip" then .id+=9000 else . end)'
    capture upload
    check 'large retry rejects replaced acknowledged asset IDs' test "$status" -eq 7
    check 'large retained-ID conflict never overwrites an asset' test "$(count)" -eq 3

    new_case large_lost_ack
    payload_seed_large_inventory
    MODE=lost; capture upload
    check 'large upload retains the transport acknowledgement failure' test "$status" -eq 8
    check 'large interrupted upload retains accepted remote payload bytes' jq -e \
        '[.[]|select(.name=="a.tar.gz" or .name=="b.zip")]|length==2' "$CASE/inventory.json"
    unset MODE; capture upload
    check 'large lost acknowledgement resumes from independent inventory' test "$status" -eq 0
    check 'large lost acknowledgement never duplicates an accepted upload' test "$(count)" -eq 3

    inventory=$(cat "$CASE/inventory.json")
    plan=$(_rup_manifest "$MANIFEST" owner/tool v1.0.0 "$PIN")
    pinned=$(jq -c '[.[]|select(.name=="b.zip")]' <<< "$inventory")
    capture _rup_preflight owner/tool "$inventory" "$plan" "$pinned" "$WORK"
    check 'large unchanged retained inventory passes preflight' test "$status" -eq 0
    for filter in '.id+=1' '.size+=1' '.digest=("sha256:"+("0"*64))' '.state="starter"'; do
        capture _rup_preflight owner/tool "$inventory" "$plan" "$(jq -c "map($filter)" <<< "$pinned")" "$WORK"
        check "large preflight preserves complete retained identity: $filter" test "$status" -eq 7
    done
    capture _rup_preflight owner/tool "$inventory"$'\n[]' "$plan" "$pinned" "$WORK"
    check 'large preflight rejects trailing inventory documents' nonzero "$status"
    capture _rup_preflight owner/tool "$inventory" "$plan" "$pinned"$'\n[]' "$WORK"
    check 'large preflight rejects trailing retained-identity documents' nonzero "$status"

    new_case large_inventory_drift
    payload_seed_large_inventory
    MODE=inventory_drift; capture upload
    check 'large publication detects existing metadata changing during upload' test "$status" -eq 7
    check 'large inventory drift stops all subsequent uploads' test "$(count)" -eq 1
    check 'large inventory drift emits no verified receipt' test ! -s "$CASE/out"
    new_case large_unselected
    payload_seed_large_inventory
    change_json "$CASE/inventory.json" '.+[{id:90,name:"unplanned.zip",state:"uploaded",size:7,digest:null}]|sort_by(.name)'
    capture upload
    check 'large release still refuses unselected remote payloads' test "$status" -eq 7
    check 'large unselected payload conflict precedes every upload' test "$(count)" -eq 0
}
# A large selected release exercises different boundaries from unrelated remote
# metadata: selection, retained IDs and checkpoints each grow with payload count.
payload_seed_large_selection() {
    local name hash size
    hash=$(_slsa_sha256 "$ART/a.tar.gz") || return 1
    size=$(wc -c < "$ART/a.tar.gz") || return 1
    jq -nc --arg hash "$hash" --argjson size "$size" '
        [range(0;420)|{
            name:("large-"+(("0000"+tostring)[-4:])+"-"+("x"*220)+".bin"),
            target:"linux/amd64",sha256:$hash,size_bytes:$size,archive_format:"binary"
        }]' > "$CASE/selected-rows.json" || return 1
    jq -r '.[].name' "$CASE/selected-rows.json" > "$CASE/selected-names" || return 1
    while IFS= read -r name; do
        printf 'linux payload\n' > "$ART/$name" || return 1
    done < "$CASE/selected-names"
    jq -cS --slurpfile extra "$CASE/selected-rows.json" '.artifacts += $extra[0]' \
        "$MANIFEST" > "$CASE/next.json" || return 1
    mv "$CASE/next.json" "$MANIFEST"
}
payload_large_selection_cases() {
    local selection context plan inventory state pin changed filter
    new_case large_selection
    payload_seed_large_selection || { failures=$((failures+1)); return 1; }
    selection=$(_rup_manifest "$MANIFEST" owner/tool v1.0.0 "$PIN") || {
        failures=$((failures+1)); return 1;
    }
    printf '%s\n' "$selection" > "$CASE/selection.json"
    check 'actual selected manifest exceeds a single executable argument' \
        test "$(wc -c < "$CASE/selection.json")" -gt 131072
    capture upload --dry-run
    check 'large real payload selection produces a dry-run plan' test "$status" -eq 0
    check 'large dry-run preserves every selected name and digest' jq -es \
        --slurpfile expected "$CASE/selection.json" \
        'length==1 and (.[0]|.status=="planned" and .dry_run==true and .plan==$expected[0] and (.plan.artifacts|length)==423)' "$CASE/out"
    check 'large dry-run performs no authentication' test ! -s "$CASE/auth"
    check 'large dry-run performs no upload' test "$(count)" -eq 0
    check 'large dry-run creates no persistent publication state' test ! -e "$CASE/state"

    context=$(_rup_context_key "$(cat "$CASE/context.json")" owner/tool v1.0.0 "$PIN") || {
        failures=$((failures+1)); return 1;
    }
    plan=$(jq -cS --slurpfile context /dev/fd/3 '.+{context:$context[0]}' \
        3<<< "$context" <<< "$selection") || return 1
    printf '%s\n' "$plan" > "$CASE/plan.json"
    # These ID-bearing rows are explicit API-boundary fixtures. The selected
    # files and their build-manifest authentication above use real bytes.
    jq -cS '[.artifacts|to_entries[]|{id:(1000+.key),name:.value.name,
        state:"uploaded",size:.value.size_bytes,digest:("sha256:"+.value.sha256)}]|
        sort_by(.name)' "$MANIFEST" > "$CASE/expected-selected.json" || return 1
    jq -cS '.+[{id:9,name:"private.json",state:"uploaded",size:7,digest:null}]|sort_by(.name)' \
        "$CASE/expected-selected.json" > "$CASE/inventory.json" || return 1
    inventory=$(cat "$CASE/inventory.json") || return 1
    check 'selected remote identities exceed one executable argument' \
        test "$(wc -c < "$CASE/expected-selected.json")" -gt 131072
    capture _rup_selected_assets "$inventory" "$plan"
    check 'large selection retains all and only selected remote rows' test "$status" -eq 0
    check 'large selection preserves exact selected IDs, sizes and digests' jq -es \
        --slurpfile expected "$CASE/expected-selected.json" \
        'length==1 and .[0]==$expected[0]' "$CASE/out"
    capture _rup_selected_assets "$inventory"$'\n[]' "$plan"
    check 'large selection rejects trailing inventory documents' nonzero "$status"
    capture _rup_selected_assets "$inventory" "$plan"$'\n{}'
    check 'large selection rejects trailing plan documents' nonzero "$status"

    jq -ncS --slurpfile plan "$CASE/plan.json" --slurpfile assets "$CASE/expected-selected.json" \
        '{schema_version:1,kind:"dsr-release-payload-state",plan:$plan[0],assets:$assets[0],complete:true}' \
        > "$CASE/complete-state.json" || return 1
    state=$(cat "$CASE/complete-state.json") || return 1
    capture _rup_state_valid "$CASE/complete-state.json" "$plan"
    check 'large complete recovery checkpoint validates its exact plan' test "$status" -eq 0
    capture _rup_state_valid "$CASE/complete-state.json" "$plan"$'\n{}'
    check 'checkpoint validation rejects trailing selected plans' nonzero "$status"
    capture _rup_save "$CASE/checkpoint.json" "$state" absent "$plan" "$CASE"
    check 'large checkpoint persists every selected identity' test "$status" -eq 0
    check 'checkpoint bytes equal the complete input evidence' cmp -s "$CASE/checkpoint.json" "$CASE/complete-state.json"
    pin=$(_slsa_sha256 "$CASE/complete-state.json") || return 1
    capture _rup_save "$CASE/checkpoint.json" "$state" "$pin" "$plan" "$CASE"
    check 'unchanged large checkpoint can be saved again' test "$status" -eq 0
    check 'unchanged large checkpoint remains byte-stable' cmp -s "$CASE/checkpoint.json" "$CASE/complete-state.json"
    for filter in '.assets[-1].id=.assets[0].id' '.assets[-1].size+=1' \
        '.assets[-1].digest=("sha256:"+("0"*64))' '.assets[-1].state="starter"' \
        '.assets=.assets[:-1]' '.plan.artifacts=.plan.artifacts[:-1]'; do
        changed=$(jq -cS "$filter" "$CASE/complete-state.json") || return 1
        capture _rup_save "$CASE/checkpoint.json" "$changed" "$pin" "$plan" "$CASE"
        check "large recovery refuses inconsistent checkpoint: $filter" test "$status" -eq 2
        check 'refused checkpoint keeps previous complete evidence unchanged' \
            cmp -s "$CASE/checkpoint.json" "$CASE/complete-state.json"
    done
    changed=$(jq -cS '.artifacts[-1].sha256=("0"*64)' "$CASE/plan.json") || return 1
    capture _rup_state_valid "$CASE/complete-state.json" "$changed"
    check 'large checkpoint cannot be rebound to a changed selection' nonzero "$status"
    capture _rup_save "$CASE/checkpoint.json" "$state" absent "$plan" "$CASE"
    check 'large checkpoint cannot overwrite an unexpectedly occupied destination' test "$status" -eq 2
    check 'occupied-destination refusal preserves checkpoint bytes' \
        cmp -s "$CASE/checkpoint.json" "$CASE/complete-state.json"

    printf changed >> "$ART/b.zip"
    capture upload --dry-run
    check 'large real-file plan refuses altered selected bytes' test "$status" -eq 7
    check 'altered selection emits no planned receipt' test ! -s "$CASE/out"
    printf 'windows payload\n' > "$ART/b.zip"
    printf extra > "$ART/unplanned.zip"
    capture upload --dry-run
    check 'large plan still refuses an unselected local payload' test "$status" -eq 4
    check 'large refusal performs no authentication' test ! -s "$CASE/auth"
    check 'large refusal performs no upload' test "$(count)" -eq 0
}

# Exercise a failed parser after the last inventory gate and before POST. A
# complete public release must remain read-only even when the lookup was stopped.
payload_lookup_failure_cases() {
    local mode rc expected
    for mode in public draft; do
        new_case "lookup-$mode"
        if [[ "$mode" == public ]]; then
            seed a.tar.gz 101; seed b.zip 102; seed z-compat.tar.gz 103
            change_json "$CASE/context.json" '.release.draft=false'
        fi
        cp "$CASE/inventory.json" "$CASE/before.json" || return 1
        for rc in 130 5; do
            expected=1; [[ "$rc" != 130 ]] || expected=5
            capture upload_with_failed_lookup "$rc"
            check "$mode release stops after lookup exit $rc" test "$status" -eq "$expected"
            check "$mode lookup exit $rc reaches the publication decision" test -s "$CASE/lookup"
            check "$mode lookup exit $rc sends no upload" test "$(count)" -eq 0
            check "$mode lookup exit $rc preserves remote inventory" cmp -s "$CASE/before.json" "$CASE/inventory.json"
            check "$mode lookup exit $rc emits no success receipt" test ! -s "$CASE/out"
        done
        capture upload
        check "$mode release can resume from the retained plan" test "$status" -eq 0
        if [[ "$mode" == public ]]; then check 'public retry stays read-only' test "$(count)" -eq 0
        else check 'draft retry sends each missing payload once' test "$(count)" -eq 3; fi
    done
}
upload_with_failed_lookup() (
    local lookup_rc="$1"
    : > "$CASE/lookup"
    jq() {
        if [[ "${5:-}" == 'any(.[];.name==$name)' ]]; then
            printf '%s\n' "$lookup_rc" >> "$CASE/lookup"
            printf 'false\n'
            return "$lookup_rc"
        fi
        command jq "$@"
    }
    upload
)

if [[ "${DSR_PAYLOAD_FIXTURES_ONLY:-false}" == true ]]; then return 0; fi
if [[ "${1:-}" == --lookup-only ]]; then
    payload_lookup_failure_cases || failures=$((failures+1))
    printf '\nPayload publication checks: %d; failures: %d\n' "$checks" "$failures"
    [[ "$failures" -eq 0 ]]; exit $?
fi
if [[ "${1:-}" == --large-selection-only ]]; then
    payload_large_selection_cases || failures=$((failures+1))
    printf '\nPayload publication checks: %d; failures: %d\n' "$checks" "$failures"
    [[ "$failures" -eq 0 ]]; exit $?
fi
if [[ "${1:-}" == --large-inventory-only ]]; then
    payload_large_inventory_cases
    printf '\nPayload publication checks: %d; failures: %d\n' "$checks" "$failures"
    [[ "$failures" -eq 0 ]]; exit $?
fi
payload_lookup_failure_cases || failures=$((failures+1))
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
payload_large_inventory_cases
printf '\nPayload publication checks: %d; failures: %d\n' "$checks" "$failures"
[[ "$failures" -eq 0 ]]
