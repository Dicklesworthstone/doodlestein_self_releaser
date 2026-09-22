#!/usr/bin/env bash
# Real build-set collection and finalizer argument/evidence handoff. The
# existing network finalizer is replaced only at its public function boundary.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DSR_BUNDLE_FIXTURES_ONLY=true source "$HERE/test_release_bundle.sh"
source "$ROOT/src/release_finalize.sh"
MODE=ready
release_finalize() {
    local _root=$1 _manifest='' _repo='' _tag='' _sha='' _promote=false _arg
    printf 'call\n' >> "$WORK/calls"
    jq -cn --args '$ARGS.positional' -- "$@" > "$WORK/engine-args.json"
    shift
    while (($#)); do
        _arg=$1
        case "$_arg" in
            --build-manifest) _manifest=$2; shift 2 ;;
            --repo) _repo=$2; shift 2 ;; --tag) _tag=$2; shift 2 ;; --sha) _sha=$2; shift 2 ;;
            --promote) _promote=true; shift ;;
            *) shift ;;
        esac
    done
    [[ -d "$_root" && -f "$_manifest" && "$_repo" == owner/tool && "$_tag" == v1.2.3 && "$_sha" == "$SOURCE_SHA" ]] || return 99
    _slsa_manifest_statement "$_manifest" "$_repo" test:finalizer > "$WORK/handoff-proof.json" || return 99
    _slsa_release_assets "$WORK/handoff-proof.json" "$_root" || return 99
    jq -e '.summary=={total:3,success:3,failed:0} and (.artifacts|length)==4' "$_manifest" >/dev/null || return 99
    case "$MODE" in
        failure) printf '{"kind":"dsr-release-finalization-result","status":"error","exit_code":7,"error":"injected publication failure"}\n'; return 7 ;;
        malformed) printf '{}\n'; return 0 ;;
        false-plan) printf '{"kind":"dsr-release-finalization-result","status":"planned","exit_code":0}\n'; return 0 ;;
        drift) printf 'changed manifest\n' >> "$_manifest" ;;
    esac
    jq -cn --argjson promote "$_promote" '{kind:"dsr-release-finalization-result",
        status:(if $promote then "published" else "ready" end),exit_code:0,dry_run:false,
        verification:{fixture:true},promotion_attempted:$promote}'
}
pipeline() { release_finalize_build_set --build-set "$WORK/plan.json" --bundle-dir "$WORK/bundle" "$@"; }
make_fixture "$WORK/builds"
make_plan "$WORK/builds" "$WORK/plan.json"
mv "$WORK/builds/windows/manifest.json" "$WORK/held-manifest.json"
run_code 'incomplete matrix blocks finalizer invocation' 1 pipeline --create-draft
assert 'waiting result is one finalization envelope' jq -es 'length==1 and (.[0]|.status=="waiting_for_builds" and .exit_code==1 and .bundle.publishable==false)' "$WORK/result.json"
assert 'no release API boundary reached for a missing target' test ! -e "$WORK/calls"
assert 'ready targets survive the blocked finalization' test -f "$WORK/bundle/inputs/linux/build-manifest.json"
mv "$WORK/held-manifest.json" "$WORK/builds/windows/manifest.json"
mv "$WORK/builds/linux" "$WORK/offline-linux"
mv "$WORK/builds/darwin" "$WORK/offline-darwin"
run_code 'same invocation resumes collection and hands off the complete release' 0 pipeline --create-draft
assert 'result retains bundle and original finalization evidence' jq -e '.status=="ready" and .bundle.status=="verified" and .verification.fixture and .promotion_attempted==false' "$WORK/result.json"
assert 'plan identity supplies repo, tag, commit, payload upload and manifest' jq -e --arg sha "$SOURCE_SHA" --arg root "$WORK/bundle" '
    .[0]==($root+"/release/artifacts") and .[index("--repo")+1]=="owner/tool" and
    .[index("--tag")+1]=="v1.2.3" and .[index("--sha")+1]==$sha and
    index("--upload-payloads")!=null and .[index("--build-manifest")+1]==($root+"/release/build-manifest.json")' "$WORK/engine-args.json"
assert 'metadata and finalization state default outside immutable payloads' jq -e --arg root "$WORK/bundle" \
    '.[index("--output-dir")+1]==($root+"/metadata") and .[index("--state-dir")+1]==($root+"/finalization")' "$WORK/engine-args.json"
assert 'promotion, signing and dispatch tool are not silently enabled' jq -e \
    'index("--promote")==null and index("--require-signatures")==null and index("--tool")==null' "$WORK/engine-args.json"
PIN=$(_slsa_sha256 "$WORK/bundle/release/build-manifest.json")
MODE=failure
run_code 'publication failure preserves original engine exit code' 7 pipeline --create-draft
assert 'failed publication retains bundle and engine diagnostic' jq -e '.exit_code==7 and .error=="injected publication failure" and .bundle.status=="verified"' "$WORK/result.json"
assert 'failed publication never discards the assembled release' test -f "$WORK/bundle/release/result.json"
MODE=ready
run_code 'publication retry reuses the same aggregate manifest identity' 0 pipeline --create-draft
assert 'aggregate hash is unchanged after publication retry' test "$PIN" = "$(_slsa_sha256 "$WORK/bundle/release/build-manifest.json")"
printf 'public fixture\n' > "$WORK/key.pub"
printf 'private fixture\n' > "$WORK/key.key"
printf 'release notes\n' > "$WORK/notes.md"
TITLE='Tool release; $(never-execute)'
run_code 'explicit signing, promotion and downstream options reach the engine' 0 pipeline --create-draft --promote \
    --require-signatures --public-key "$WORK/key.pub" --secret-key "$WORK/key.key" \
    --integrity-dir "$WORK/integrity" --release-name "$TITLE" --release-notes-file "$WORK/notes.md" \
    --dispatch-repos owner/formulas --dispatch-run-id release-123
assert 'promotion is explicit in the retained result' jq -e '.status=="published" and .promotion_attempted' "$WORK/result.json"
assert 'policy arguments and literal title are not reinterpreted' jq -e --arg title "$TITLE" --arg public "$WORK/key.pub" \
    'index("--require-signatures")!=null and index("--promote")!=null and
     .[index("--public-key")+1]==$public and .[index("--release-name")+1]==$title and .[index("--tool")+1]=="tool"' "$WORK/engine-args.json"
run_code 'prepared-only signature policy is forwarded without enabling signing' 0 pipeline \
    --prepared-signatures --public-key "$WORK/key.pub" --integrity-dir "$WORK/integrity"
assert 'prepared mode does not add require-signatures or a secret key' jq -e \
    'index("--prepared-signatures")!=null and index("--require-signatures")==null and index("--secret-key")==null' "$WORK/engine-args.json"
CALLS=$(wc -l < "$WORK/calls")
for FLAG in --repo --tag --sha --tool --build-manifest --upload-payloads --unknown; do
    run_code "plan-owned/unknown option is refused: $FLAG" 4 pipeline "$FLAG" ignored
    assert 'argument rejection produces one error envelope' jq -es 'length==1 and .[0].exit_code==4' "$WORK/result.json"
done
run_code 'immutable payload namespace cannot become an SBOM output directory' 4 pipeline --output-dir "$WORK/bundle/release/artifacts"
run_code 'checkpoint namespace cannot become a state directory' 4 pipeline --state-dir "$WORK/bundle/inputs/state"
run_code 'signing requires an explicit public key' 4 pipeline --require-signatures
run_code 'mutually exclusive signature modes are refused' 4 pipeline --require-signatures --prepared-signatures --public-key "$WORK/key.pub" --integrity-dir "$WORK/integrity"
run_code 'draft-only metadata cannot be silently ignored' 4 pipeline --release-name title
run_code 'dispatch while creating a draft requires explicit promotion' 4 pipeline --create-draft --dispatch-repos owner/formulas
run_code 'duplicate flags are rejected before collecting or publishing' 4 pipeline --promote --promote
run_code 'invalid output format is rejected' 4 pipeline --format unsupported
assert 'invalid options never invoke the finalizer' test "$CALLS" = "$(wc -l < "$WORK/calls")"
run_code 'dry run plans even when original build hosts are gone' 0 release_finalize_build_set \
    --build-set "$WORK/plan.json" --bundle-dir "$WORK/dry-bundle" --create-draft --dry-run
assert 'dry run never claims that signing or publication policy was verified' jq -e \
    '.status=="planned" and .dry_run and .policy_verified==false and .bundle.publishable==false' "$WORK/result.json"
assert 'dry finalization creates no bundle' test ! -e "$WORK/dry-bundle"
assert 'dry finalization does not call the live engine' test "$CALLS" = "$(wc -l < "$WORK/calls")"
cp "$WORK/bundle/release/artifacts/tool-linux" "$WORK/healthy-payload"
printf 'drift\n' > "$WORK/bundle/release/artifacts/tool-linux"
run_code 'completed payload drift blocks publication on retry' 7 pipeline
assert 'corrupted output never reaches the finalizer boundary' test "$CALLS" = "$(wc -l < "$WORK/calls")"
cp "$WORK/healthy-payload" "$WORK/bundle/release/artifacts/tool-linux"
MODE=malformed
run_code 'malformed engine success is not accepted' 7 pipeline
MODE=false-plan
run_code 'a planned engine result cannot pass as live completion' 7 pipeline
MODE=drift
run_code 'manifest drift during the finalizer handoff is reported' 7 pipeline

# Exercise the real CLI router with an explicit core boundary fixture. This
# proves source loading, argv fidelity and dispatch without any network calls.
mkdir -p "$WORK/cli"
cp "$ROOT/src/release_finalize.sh" "$WORK/cli/release_finalize.sh"
cp "$ROOT/src/release_bundle.sh" "$WORK/cli/release_bundle.sh"
cp "$ROOT/src/slsa.sh" "$WORK/cli/slsa.sh"
cat > "$WORK/cli/release_finalize_core.sh" <<'SH'
#!/usr/bin/env bash
release_finalize() { jq -cn --args '{legacy_args:$ARGS.positional}' -- "$@"; }
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then printf 'existing finalizer help\n'; fi
SH
run_code 'CLI retains the ordinary artifacts-first route' 0 bash "$WORK/cli/release_finalize.sh" '/path with spaces' --repo owner/tool
assert 'ordinary route forwards exact arguments' jq -e '.legacy_args==["/path with spaces","--repo","owner/tool"]' "$WORK/result.json"
run_code 'CLI exposes complete build-set planning' 0 bash "$WORK/cli/release_finalize.sh" --build-set "$WORK/plan.json" --bundle-dir "$WORK/cli-dry" --dry-run
assert 'CLI build-set route emits a finalizer envelope' jq -e '.kind=="dsr-release-finalization-result" and .stage=="build-set-plan"' "$WORK/result.json"
run_code 'help includes both existing and build-set usage' 0 bash "$WORK/cli/release_finalize.sh" --help
assert 'existing help remains visible' grep -q 'existing finalizer help' "$WORK/result.json"
assert 'new build-set usage is visible' grep -q -- '--build-set' "$WORK/result.json"
printf '\nBuild-set finalization: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
