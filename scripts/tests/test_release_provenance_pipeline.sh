#!/usr/bin/env bash
# Actual entry/core/SLSA admission with deterministic producer/collector fixture
# commands. External signing, scanning and transport use the explicit fixtures
# in test_release_provenance_finalize.sh; no live compiler/API/crypto claim.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DSR_PROVENANCE_FIXTURES_ONLY=true source "$HERE/test_release_provenance_finalize.sh"
INSTALL="$WORK/install"
mkdir -p "$INSTALL/src"
cp "$ROOT/src/release_finalize.sh" "$ROOT/src/release_finalize_core.sh" "$ROOT/src/slsa.sh" "$INSTALL/src/"
# The production router has no test override. Use a temporary installation with
# deterministic modules at the build/collection boundaries, not a second router.
cat > "$INSTALL/src/release_bundle.sh" <<'BUNDLE'
_rb_require() { :; }
_rb_log() { printf '%s\n' "$*" >&2; }
_rb_path() { [[ "$1" == /* && "$1" != *'/../'* && "$1" != *'/./'* && "$1" != *'//'* && ! -L "$1" ]]; }
_rb_plan() { jq -cSe '.required_targets|=sort|.builds|=(map(.targets|=sort)|sort_by(.id))' "$1"; }
release_bundle() (
    local plan='' output='' dry=false pin manifest root name
    while (($#)); do case "$1" in
        --plan) plan=$2; shift 2 ;; --output-dir) output=$2; shift 2 ;; --dry-run) dry=true; shift ;; *) return 99 ;;
    esac; done
    if [[ "$dry" == true ]]; then
        jq -cn --slurpfile p "$plan" '{kind:"dsr-release-bundle",status:"planned",publishable:false,dry_run:true,plan:$p[0]}'
        return
    fi
    manifest=$(jq -r '.builds[0].manifest' "$plan"); root=$(jq -r '.builds[0].artifacts_dir' "$plan")
    mkdir -p "$output/release/artifacts" || return 1
    if [[ -f "$output/release/build-manifest.json" ]]; then
        cmp -s "$manifest" "$output/release/build-manifest.json" || return 7
    else
        cp "$manifest" "$output/release/build-manifest.json" || return 1
        while IFS= read -r name; do cp "$root/$name" "$output/release/artifacts/$name" || return 1
        done < <(jq -r '.artifacts[].name' "$manifest")
    fi
    # Even the boundary fixture verifies real producer bytes before handoff.
    _slsa_manifest_statement "$manifest" owner/tool test:bundle > "$output/proof-check.json" || return $?
    _slsa_release_assets "$output/proof-check.json" "$output/release/artifacts" || return $?
    pin=$(_rb_plan "$plan" | sha256sum); pin=${pin%% *}
    jq -cn --arg output "$output" --arg pin "$pin" --arg hash "$(_slsa_sha256 "$manifest")" --slurpfile p "$plan" \
        '{kind:"dsr-release-bundle",status:"verified",exit_code:0,publishable:true,output_dir:$output,
          plan_sha256:$pin,targets:$p[0].required_targets,manifest:($output+"/release/build-manifest.json"),
          manifest_sha256:$hash,artifacts_dir:($output+"/release/artifacts")}'
)
BUNDLE
cat > "$INSTALL/src/release_builds.sh" <<'BUILDS'
#!/usr/bin/env bash
set -uo pipefail
source "$(dirname "$0")/slsa.sh"
source "$(dirname "$0")/release_bundle.sh"
plan='' output='' jobs='' dry=false
while (($#)); do case "$1" in
    --plan) plan=$2; shift 2 ;; --output-dir) output=$2; shift 2 ;; --jobs) jobs=$2; shift 2 ;;
    --dry-run) dry=true; shift ;; *) exit 99 ;;
esac; done
canonical=$(_rb_plan "$plan") || exit 4
hash=$(printf '%s\n' "$canonical" | sha256sum); hash=${hash%% *}
if [[ "$dry" == true ]]; then
    jq -cn --arg hash "$hash" --argjson p "$canonical" '{kind:"dsr-release-builds",status:"planned",exit_code:0,
        dry_run:true,publishable:false,plan:$p,plan_sha256:$hash}'
    exit
fi
printf 'build-boundary\n' >> "$PIPELINE_CASE/calls"
if [[ $(cat "$PIPELINE_CASE/build-mode") == fail ]]; then
    printf '{"kind":"dsr-release-builds","status":"incomplete","exit_code":1,"publishable":false}\n'
    exit 1
fi
mkdir -p "$output"
jq -cS '.builds|=map(del(.driver))' <<< "$canonical" > "$output/build-set.json"
receipt=$(release_bundle --plan "$output/build-set.json" --output-dir "$output/bundle") || exit $?
jq -cn --arg output "$output" --arg hash "$hash" --arg pin "$(_slsa_sha256 "$output/build-set.json")" \
    --argjson bundle "$receipt" '{kind:"dsr-release-builds",status:"verified",exit_code:0,publishable:true,dry_run:false,
        plan_sha256:$hash,build_set:($output+"/build-set.json"),build_set_sha256:$pin,bundle:$bundle}'
BUILDS
source "$INSTALL/src/release_finalize.sh"
setup_pipeline() {
    new_case "$1"
    export PIPELINE_CASE="$CASE"
    printf 'good\n' > "$CASE/build-mode"
    jq -cn --arg manifest "$BUILD" --arg pin "$(_rf_hash "$BUILD")" --arg root "$CASE/artifacts" --arg sha "$SOURCE_SHA" \
        '{schema_version:1,repo:"owner/tool",tool:"tool",tag:"v1.0.0",source_sha:$sha,
          required_targets:["linux/amd64","windows/arm64"],builds:[{id:"all",manifest:$manifest,
            manifest_sha256:$pin,artifacts_dir:$root,targets:["linux/amd64","windows/arm64"]}]}' > "$CASE/set.json"
    jq '.builds[0].driver="import"' "$CASE/set.json" > "$CASE/plan.json"
}
set_flow() { release_finalize_build_set --build-set "$CASE/set.json" --bundle-dir "$CASE/bundle" \
    --require-signatures --public-key "$CASE/key.pub" --secret-key "$CASE/key.key" --integrity-dir "$CASE/proofs" "$@"; }
plan_flow() { release_finalize_build_plan --build-plan "$CASE/plan.json" --build-dir "$CASE/builds" --build-jobs 2 \
    --require-signatures --public-key "$CASE/key.pub" --secret-key "$CASE/key.key" --integrity-dir "$CASE/proofs" "$@"; }
setup_pipeline invalid
for flow in set_flow plan_flow; do
    run_code 'required builder cannot be omitted before build/collection' 4 "$flow" --require-provenance
    run_code 'builder alone cannot silently enable provenance' 4 "$flow" --provenance-builder "$BUILDER"
    run_code 'duplicate provenance flag rejected before execution' 4 "$flow" --require-provenance --require-provenance --provenance-builder "$BUILDER"
    run_code 'control characters in builder are rejected' 4 "$flow" --require-provenance --provenance-builder $'bad\nbuilder'
    run_code 'caller cannot replace the plan-owned manifest' 4 "$flow" --require-provenance --provenance-builder "$BUILDER" --build-manifest "$BUILD"
done
run_code 'build-plan provenance requires a signature policy' 4 release_finalize_build_plan \
    --build-plan "$CASE/plan.json" --build-dir "$CASE/builds" --require-provenance --provenance-builder "$BUILDER"
assert 'invalid policy reached no producer or remote effect' test ! -s "$CASE/calls"
assert 'invalid policy created no build directory' test ! -e "$CASE/builds"
run_code 'actual CLI recognizes build-plan provenance policy errors' 4 bash "$INSTALL/src/release_finalize.sh" \
    --build-plan "$CASE/plan.json" --build-dir "$CASE/cli" --require-provenance --provenance-builder "$BUILDER"

setup_pipeline planned
LITERAL='dsr:$(never-execute); reviewed builder'
for flow in set_flow plan_flow; do
    run_code 'combined planning retains explicit literal provenance options' 0 "$flow" --require-provenance --provenance-builder "$LITERAL" --dry-run
    assert 'planning does not claim cryptographic or remote verification' jq -e --arg builder "$LITERAL" \
        '.status=="planned" and .dry_run and .policy_verified==false and
         (.finalization_options|index("--require-provenance")!=null and .[index("--provenance-builder")+1]==$builder and index("--promote")==null)' "$CASE/result.json"
done
assert 'planning created no proof or remote side effects' test ! -s "$CASE/calls"
assert 'planning did not create a bundle' test ! -e "$CASE/bundle"
assert 'planning did not create build state' test ! -e "$CASE/builds"

setup_pipeline set-success
run_code 'complete build set reaches the actual provenance-gated core' 0 set_flow --require-provenance --provenance-builder "$LITERAL"
assert 'draft remains a draft without explicit promotion' jq -e '.status=="ready" and .provenance.authenticated and .provenance.release.draft' "$CASE/result.json"
assert 'builder is never reinterpreted as shell input' jq -e --arg builder "$LITERAL" '.provenance.builder==$builder' "$CASE/result.json"
assert 'proof identifies the exact aggregate build manifest' jq -e --arg hash "$(_rf_hash "$CASE/bundle/release/build-manifest.json")" \
    '.provenance.build_manifest_sha256==$hash and .bundle.manifest_sha256==$hash and .provenance.targets==.bundle.targets' "$CASE/result.json"
assert 'provenance files are outside the immutable payload namespace' test ! -e "$CASE/bundle/release/artifacts/release.intoto.jsonl"
assert 'core re-verifies remote proof even without promotion' test "$(count 'provenance-verify true')" = 2
run_code 'same build-set invocation reuses its retained signed proof' 0 set_flow --require-provenance --provenance-builder "$LITERAL"
assert 'retry signs the proof only once' test "$(count sign-provenance)" = 1
BEFORE=$(count context)
run_code 'retry cannot omit provenance at the public build-set entry' 2 set_flow
assert 'omission is rejected before another remote context read' test "$(count context)" = "$BEFORE"

setup_pipeline plan-failure
printf 'fail\n' > "$CASE/build-mode"
run_code 'failed build jobs block provenance preparation and promotion' 1 plan_flow --require-provenance --provenance-builder "$BUILDER" --promote
assert 'failed build retains its stage rather than appearing as verified provenance' jq -e '.status=="builds_incomplete" and .stage=="build" and .builds.exit_code==1 and (has("provenance")|not)' "$CASE/result.json"
assert 'failed build does not generate or publish a proof' test "$(count sign-provenance):$(count provenance-publish):$(count promote)" = '0:0:0'
printf 'good\n' > "$CASE/build-mode"
run_code 'successful build plan passes exact manifest to provenance and promotion' 0 plan_flow --require-provenance --provenance-builder "$BUILDER" --promote --dispatch-repos owner/checksums
assert 'combined result retains build, bundle and post-promotion provenance' jq -e \
    '.status=="complete" and .builds.status=="verified" and .bundle.status=="verified" and
     .provenance.authenticated and .provenance.release.draft==false and
     .provenance.build_manifest_sha256==.bundle.manifest_sha256' "$CASE/result.json"
assert 'generated proof covers every requested target and alias' jq -e \
    '.provenance.targets==["linux/amd64","windows/arm64"] and .provenance.artifact_count==3' "$CASE/result.json"
assert 'downstream evidence retains the same manifest provenance' jq -e --arg hash "$(_rf_hash "$CASE/builds/bundle/release/build-manifest.json")" \
    '.payload.release_evidence.provenance.build_manifest_sha256==$hash' "$CASE/dispatch.json"
run_code 'completed build-plan retry does not regenerate or repromote proof' 0 plan_flow --require-provenance --provenance-builder "$BUILDER" --promote --dispatch-repos owner/checksums
assert 'completed pipeline keeps one signature and promotion' test "$(count sign-provenance):$(count promote)" = '1:1'

setup_pipeline plan-publication-retry
MODE=lost-signature
run_code 'lost provenance upload acknowledgement propagates through build plan' 8 plan_flow --require-provenance --provenance-builder "$BUILDER" --promote
assert 'failed provenance upload never promotes' test "$(count promote)" = 0
MODE=''
run_code 'same pipeline retries the selected proof pair' 0 plan_flow --require-provenance --provenance-builder "$BUILDER" --promote
assert 'proof pair is not re-signed or re-uploaded on retry' test \
    "$(count sign-provenance):$(count 'upload release.intoto.jsonl'):$(count 'upload release.intoto.jsonl.minisig')" = '1:1:1'

# Inject drift at record serialization, after the real SLSA verification call.
# Returning a newly hashed record must not select unauthenticated replacement
# bytes and defer their rejection until after payload uploads.
_ri_file_record() {
    local hash size
    if [[ ! -e "$CASE/selection-drift" && "$1" == "$CASE/proofs/"* &&
          ( ( "$MODE" == statement-selection-drift && "$2" == release.intoto.jsonl ) ||
            ( "$MODE" == signature-selection-drift && "$2" == release.intoto.jsonl.minisig ) ) ]]; then
        printf '\n' >> "$1"
        touch "$CASE/selection-drift"
    fi
    hash=$(_slsa_sha256 "$1") || return $?
    size=$(wc -c < "$1") || return 1
    jq -cn --arg name "$2" --arg hash "$hash" --argjson size "$size" '{name:$name,sha256:$hash,size:$size}'
}
for mode in statement-selection-drift signature-selection-drift; do
    setup_pipeline "$mode"; MODE=$mode
    run_code 'proof records cannot select bytes changed after authentication' 7 set_flow --require-provenance --provenance-builder "$BUILDER" --promote
    assert 'changed proof selection fails before any payload or proof upload' test \
        "$(count payload-publish):$(count provenance-publish):$(count promote)" = '0:0:0'
done
setup_pipeline lost-promotion; MODE=lost-promotion
run_code 'lost promotion acknowledgement is reconciled with authenticated provenance' 0 set_flow --require-provenance --provenance-builder "$BUILDER" --promote
assert 'reconciled promotion retains transport failure and verified public result' jq -e \
    '.status=="published" and .promotion_transport_exit_code==8 and .provenance.authenticated and .provenance.release.draft==false' "$CASE/result.json"
assert 'lost acknowledgement performs one promotion, not a replay' test "$(count promote)" = 1

bash "$INSTALL/src/release_finalize.sh" --help > "$WORK/help.txt" || exit 1
assert 'public help exposes provenance alongside existing routes' grep -q -- '--require-provenance --provenance-builder' "$WORK/help.txt"
printf '\nBuild-plan/set provenance integration: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
