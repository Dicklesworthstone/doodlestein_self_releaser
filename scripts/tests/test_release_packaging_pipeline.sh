#!/usr/bin/env bash
# Real collector, archive construction, manifest/SLSA admission and finalizer.
# Signing, scanning and GitHub transport are the explicit file-backed fixtures
# from the provenance suite, not native cryptographic/network acceptance.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DSR_PROVENANCE_FIXTURES_ONLY=true source "$HERE/test_release_provenance_finalize.sh"
source "$ROOT/src/release_finalize.sh"

# The fixture scanner selects the exact admitted manifest namespace, including
# the new ZIP name; it does not decide which producer or packaged bytes to use.
_sbom_select_artifacts() { jq -r '.artifacts[].name' "$BUILD" | sort; }

package_case() {
    new_case "$1"
    chmod 755 "$CASE/artifacts/tool-linux" "$CASE/artifacts/tool-linux-alias"
    jq -cn --arg root "$CASE" --arg pin "$(_rf_hash "$BUILD")" --arg sha "$SOURCE_SHA" --slurpfile m "$BUILD" \
        '{schema_version:1,repo:"owner/tool",tool:"tool",tag:"v1.0.0",source_sha:$sha,
          required_targets:["linux/amd64","windows/arm64"],
          required_assets:($m[0].artifacts|map({name,target,archive_format})),
          builds:[{id:"producer",targets:["linux/amd64","windows/arm64"],manifest:($root+"/build.json"),
                   manifest_sha256:$pin,artifacts_dir:($root+"/artifacts")}]}' > "$CASE/set.json"
    cat > "$CASE/recipe.json" <<'JSON'
{"schema_version":1,"artifacts":[
 {"name":"tool-linux.tar.gz","target":"linux/amd64","archive_format":"tar.gz",
  "members":[{"source":"tool-linux","path":"tool"},{"source":"tool-linux-alias","path":"helper"}],
  "aliases":["tool-linux-alias.tar.gz"]},
 {"name":"tool-windows.zip","target":"windows/arm64","archive_format":"zip",
  "members":[{"source":"tool-windows.exe","path":"tool.exe"}]}]}
JSON
    BUILD="$CASE/bundle/packaged/release/build-manifest.json"
}

set_base() {
    release_finalize_build_set --build-set "$CASE/set.json" --bundle-dir "$CASE/bundle" \
        --require-signatures --public-key "$CASE/key.pub" --secret-key "$CASE/key.key" \
        --integrity-dir "$CASE/proofs" --output-dir "$CASE/meta" --state-dir "$CASE/state" \
        --require-provenance --provenance-builder "$BUILDER" "$@"
}
package_flow() { set_base --packaging-recipe "$CASE/recipe.json" "$@"; }
snapshot() {
    python3 - "$CASE/bundle" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
print(json.dumps({str(p.relative_to(root)): [p.stat().st_ino, hashlib.sha256(p.read_bytes()).hexdigest()]
                  for part in ("release", "inputs", "packaged/release") for p in (root/part).rglob("*") if p.is_file()}, sort_keys=True))
PY
}

package_case preview
run_code 'build-set preview describes input and final asset contracts' 0 package_flow --dry-run
assert 'preview does not package, sign, or authenticate remote data' test ! -s "$CASE/calls"
assert 'preview creates no persistent bundle' test ! -e "$CASE/bundle"
assert 'preview retains both exact namespaces without claiming policy verification' jq -e \
    '.status=="planned" and .policy_verified==false and .packaging.kind=="dsr-release-packaging-plan" and
     (.bundle.plan.required_assets|map(.name))==["tool-linux","tool-linux-alias","tool-windows.exe"] and
     (.packaging.required_assets|map(.name))==["tool-linux-alias.tar.gz","tool-linux.tar.gz","tool-windows.zip"]' "$CASE/result.json"
for mutation in '.artifacts|=.[0:1]' \
    '.artifacts[0].members[1].source="missing-companion"' \
    '.artifacts[0].target="darwin/arm64"' \
    '.artifacts[0].aliases=["tool-windows.zip"]'; do
    cp "$CASE/recipe.json" "$CASE/saved-recipe.json"
    jq "$mutation" "$CASE/saved-recipe.json" > "$CASE/recipe.json"
    run_code 'incompatible recipe is rejected before collection' 4 package_flow
    assert 'invalid recipe makes no bundle or API calls' test ! -e "$CASE/bundle"
    assert 'invalid recipe never reaches authentication' test ! -s "$CASE/calls"
    cp "$CASE/saved-recipe.json" "$CASE/recipe.json"
done
run_code 'duplicate packaging options cannot select a second recipe' 4 package_flow --packaging-recipe "$CASE/recipe.json"
for option in --output-dir --state-dir --integrity-dir --dispatch-state-dir; do
    # Exercise parser path rejection without duplicate options from set_base.
    run_code 'finalizer writers cannot occupy the immutable package namespace' 4 release_finalize_build_set \
        --build-set "$CASE/set.json" --bundle-dir "$CASE/bundle" --packaging-recipe "$CASE/recipe.json" \
        "$option" "$CASE/bundle/packaged/release/artifacts"
done
ln -s "$CASE/recipe.json" "$CASE/linked-recipe.json"
run_code 'recipe symlink is refused before any writes' 4 set_base --packaging-recipe "$CASE/linked-recipe.json"

package_case success
run_code 'real archive packaging reaches provenance-gated finalization' 0 package_flow
assert 'default finalization leaves the verified release a draft' jq -e '.status=="ready" and .provenance.release.draft' "$CASE/result.json"
assert 'proof binds packaged manifest, not raw producer bundle' jq -e \
    '.provenance.build_manifest_sha256==.packaging.manifest_sha256 and
     .packaging.source_manifest_sha256==.bundle.manifest_sha256 and
     .provenance.build_manifest_sha256!=.bundle.manifest_sha256 and .provenance.authenticated' "$CASE/result.json"
assert 'only packaged payload names and all aliases enter the signed statement' jq -e \
    '(.subject|map(.name))==["tool-linux-alias.tar.gz","tool-linux.tar.gz","tool-windows.zip"]' "$CASE/remote/release.intoto.jsonl"
assert 'raw build names never enter the remote payload inventory' jq -e \
    'all(.[]; .name!="tool-linux" and .name!="tool-linux-alias" and .name!="tool-windows.exe")' "$CASE/inventory.json"
assert 'archive entries are flat, renamed and byte/mode preserving' python3 - "$CASE" <<'PY'
import pathlib, sys, tarfile, zipfile
root = pathlib.Path(sys.argv[1])
out = root / "bundle/packaged/release/artifacts"
with tarfile.open(out / "tool-linux.tar.gz") as archive:
    assert sorted(archive.getnames()) == ["helper", "tool"]
    for name in archive.getnames():
        assert archive.extractfile(name).read() == b"linux payload\n"
        assert archive.getmember(name).mode & 0o111 == 0o111
with zipfile.ZipFile(out / "tool-windows.zip") as archive:
    assert archive.namelist() == ["tool.exe"]
    assert archive.read("tool.exe") == b"windows payload\n"
assert (out / "tool-linux.tar.gz").read_bytes() == (out / "tool-linux-alias.tar.gz").read_bytes()
PY
assert 'original producer contract and manifest remain independently retained' cmp -s \
    "$CASE/bundle/release/build-manifest.json" "$CASE/bundle/packaged/release/source/build-manifest.json"
BEFORE=$(snapshot)
mv "$CASE/artifacts" "$CASE/offline-artifacts"
mv "$CASE/build.json" "$CASE/offline-build.json"
run_code 'publication retry works after original producer files disappear' 0 package_flow
assert 'completed archives, producer checkpoints and manifests keep bytes and inodes' test "$BEFORE" = "$(snapshot)"
assert 'retry never signs another statement' test "$(count sign-provenance)" = 1
BEFORE_CALLS=$(wc -l < "$CASE/calls")
run_code 'omitting packaging on retry cannot publish raw files' 2 set_base
assert 'omitted packaging is rejected before another API call' test "$(wc -l < "$CASE/calls")" = "$BEFORE_CALLS"
cp "$CASE/recipe.json" "$CASE/recipe-original.json"
jq '.artifacts[0].aliases=["tool-other-alias.tar.gz"]' "$CASE/recipe-original.json" > "$CASE/recipe.json"
run_code 'changed recipe cannot select different assets during retry' 2 package_flow
assert 'conflicting packaging never reaches the remote release' test "$(wc -l < "$CASE/calls")" = "$BEFORE_CALLS"
jq '.artifacts|=reverse | .artifacts[1].members|=reverse' "$CASE/recipe-original.json" > "$CASE/recipe.json"
run_code 'equivalent recipe ordering preserves its canonical identity' 0 package_flow
assert 'canonical retry preserves completed files' test "$BEFORE" = "$(snapshot)"
run_code 'explicit promotion and downstream delivery consume packaged evidence' 0 package_flow --promote --dispatch-repos owner/checksums
assert 'downstream proof pins the packaged manifest' jq -e --arg hash "$(_rf_hash "$BUILD")" \
    '.payload.release_evidence.provenance.build_manifest_sha256==$hash' "$CASE/dispatch.json"
assert 'public retry never repeats promotion or signing' test "$(count promote)" = 1

package_case failed-publication
MODE=provenance-publish-fail
run_code 'proof publication failure retains completed packaging' 8 package_flow --promote
BEFORE=$(snapshot)
assert 'failed proof leaves the remote release a draft' jq -e '.release.draft' "$CASE/context.json"
MODE=''
run_code 'publication recovery reuses packages and the selected proof' 0 package_flow --promote
assert 'publication recovery does not recompress or replace files' test "$BEFORE" = "$(snapshot)"
assert 'publication recovery signs once' test "$(count sign-provenance)" = 1

package_case missing-producer
mv "$CASE/artifacts/tool-windows.exe" "$CASE/held.exe"
run_code 'missing companion holds the complete release before packaging' 1 package_flow
assert 'missing input creates neither packages nor publication calls' test ! -e "$CASE/bundle/packaged"
assert 'missing input emits the collection-stage incomplete result' jq -e '.stage=="collection" and .status=="waiting_for_builds"' "$CASE/result.json"
assert 'missing companion never starts authentication' test ! -s "$CASE/calls"
mv "$CASE/held.exe" "$CASE/artifacts/tool-windows.exe"
run_code 'restored pinned companion resumes collection and packaging' 0 package_flow

package_case runtime-contract
jq 'del(.required_assets)' "$CASE/set.json" > "$CASE/without-contract.json"
mv "$CASE/without-contract.json" "$CASE/set.json"
jq '.artifacts[0].members|=.[0:1]' "$CASE/recipe.json" > "$CASE/invalid-recipe.json"
mv "$CASE/invalid-recipe.json" "$CASE/recipe.json"
run_code 'actual producer completeness is enforced without optional plan assets' 4 package_flow
assert 'packaging error is a structured terminal stage, not success' jq -e \
    '.stage=="packaging" and .packaging.publishable==false and .packaging.exit_code==4' "$CASE/result.json"
assert 'failed package emits no complete package directory' test ! -e "$CASE/bundle/packaged/release"
assert 'failed packaging performs no remote access' test ! -s "$CASE/calls"

package_case corrupt-retained
run_code 'prepare completed immutable packages for drift check' 0 package_flow
BEFORE_CALLS=$(wc -l < "$CASE/calls")
printf 'corruption\n' >> "$CASE/bundle/packaged/release/artifacts/tool-linux-alias.tar.gz"
CORRUPT=$(_rf_hash "$CASE/bundle/packaged/release/artifacts/tool-linux-alias.tar.gz")
run_code 'retained alias drift is rejected instead of silently repaired' 7 package_flow
assert 'corrupt bytes remain untouched for diagnosis' test "$CORRUPT" = "$(_rf_hash "$CASE/bundle/packaged/release/artifacts/tool-linux-alias.tar.gz")"
assert 'retained drift blocks all further remote effects' test "$(wc -l < "$CASE/calls")" = "$BEFORE_CALLS"

printf '\nPackaged build-set finalization: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
