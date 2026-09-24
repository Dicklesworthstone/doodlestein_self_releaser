#!/usr/bin/env bash
# Actual build coordinator, collector, packager and finalization engines.
# Only native compilation and signing/scanning/network boundaries are fixtures.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
DSR_PACKAGING_FIXTURES_ONLY=true source "$HERE/test_release_packaging_pipeline.sh"

plan_case() {
    package_case "$1"
    python3 - "$CASE" <<'PY'
import copy, hashlib, json, pathlib, shutil, sys
root = pathlib.Path(sys.argv[1])
plan = json.loads((root / "set.json").read_text())
source = json.loads((root / "build.json").read_text())
jobs = []
for identity, target in (("linux", "linux/amd64"), ("windows", "windows/arm64")):
    out = root / identity
    (out / "artifacts").mkdir(parents=True)
    manifest = copy.deepcopy(source)
    manifest["artifacts"] = [a for a in source["artifacts"] if a["target"] == target]
    manifest["requested_targets"] = [target]
    manifest["summary"] = {"total": 1, "success": 1, "failed": 0}
    for asset in manifest["artifacts"]:
        shutil.copy2(root / "artifacts" / asset["name"], out / "artifacts" / asset["name"])
    file = out / "manifest.json"
    file.write_text(json.dumps(manifest) + "\n")
    jobs.append(dict(id=identity, driver="import", targets=[target], manifest=str(file),
                     manifest_sha256=hashlib.sha256(file.read_bytes()).hexdigest(), artifacts_dir=str(out / "artifacts")))
plan["builds"] = jobs
(root / "plan.json").write_text(json.dumps(plan) + "\n")
PY
    BUILD="$CASE/builds/bundle/packaged/release/build-manifest.json"
}
plan_base() {
    release_finalize_build_plan --build-plan "$CASE/plan.json" --build-dir "$CASE/builds" --build-jobs 2 \
        --require-signatures --public-key "$CASE/key.pub" --secret-key "$CASE/key.key" \
        --integrity-dir "$CASE/proofs" --output-dir "$CASE/meta" --state-dir "$CASE/state" \
        --require-provenance --provenance-builder "$BUILDER" "$@"
}
plan_flow() { plan_base --packaging-recipe "$CASE/recipe.json" "$@"; }
file_identity() { stat -c '%i' "$1"; sha256sum < "$1"; }

plan_case preview
run_code 'actual build-plan preflight includes producer and packaged contracts' 0 plan_flow --dry-run
assert 'build-plan preview exposes packaging without claiming authentication' jq -e \
    '.stage=="build-plan" and .policy_verified==false and .builds.publishable==false and
     .packaging.required_assets[0].name=="tool-linux-alias.tar.gz" and
     (.builds.plan.builds|length)==2' "$CASE/result.json"
assert 'planning never starts build state or accesses a release' test ! -e "$CASE/builds"
assert 'planning has no signing or API calls' test ! -s "$CASE/calls"
cp "$CASE/recipe.json" "$CASE/original-recipe.json"
jq '.artifacts[0].members|=.[0:1]' "$CASE/original-recipe.json" > "$CASE/recipe.json"
run_code 'missing declared companion is rejected before any jobs run' 4 plan_flow
assert 'invalid recipe cannot create coordinator state' test ! -e "$CASE/builds"
cp "$CASE/original-recipe.json" "$CASE/recipe.json"
cp "$CASE/plan.json" "$CASE/import-plan.json"
jq --arg root "$CASE" 'del(.required_assets) | .builds[1]={id:"windows",driver:"xwin",targets:["windows/arm64"],
    project:($root+"/project"),toolchain_manifest:($root+"/toolchain.json"),toolchain_sha256:("a"*64),
    binaries:["tool","companion"]}' "$CASE/import-plan.json" > "$CASE/plan.json"
jq '.artifacts[1].members[0].source="tool-aarch64-pc-windows-msvc.exe"' "$CASE/original-recipe.json" > "$CASE/recipe.json"
run_code 'xwin companion omission fails even without global required_assets' 4 plan_flow
assert 'xwin rejection precedes toolchain or source access' test ! -e "$CASE/builds"
jq '.artifacts[1].members += [{source:"companion-aarch64-pc-windows-msvc.exe",path:"companion.exe"}]' \
    "$CASE/recipe.json" > "$CASE/full-recipe.json"
mv "$CASE/full-recipe.json" "$CASE/recipe.json"
run_code 'complete multi-binary xwin recipe can be planned without installed compilers' 0 plan_flow --dry-run
assert 'xwin preview preserves every selected executable' jq -e \
    '([.packaging.inputs[]|select(.target=="windows/arm64")]|length)==2' "$CASE/result.json"

plan_case recovery
mv "$CASE/windows/artifacts/tool-windows.exe" "$CASE/held.exe"
run_code 'one failed import keeps the plan incomplete before packaging' 1 plan_flow
assert 'incomplete result retains actual coordinator progress' jq -e \
    '.status=="builds_incomplete" and .stage=="build" and .builds.completed_builds==1 and
     .builds.failed_builds==["windows"] and (has("packaging")|not)' "$CASE/result.json"
assert 'incomplete target matrix performs no publication' test ! -s "$CASE/calls"
assert 'packaging cannot begin for a partial matrix' test ! -e "$CASE/builds/bundle/packaged"
RETAINED="$CASE/builds/completed/linux/build-manifest.json"
BEFORE=$(file_identity "$RETAINED")
mv "$CASE/linux" "$CASE/offline-linux"
mv "$CASE/held.exe" "$CASE/windows/artifacts/tool-windows.exe"
run_code 'restored target resumes the real coordinator and reaches signed packaging' 0 plan_flow
assert 'successful original job keeps its pinned bytes and inode' test "$BEFORE" = "$(file_identity "$RETAINED")"
assert 'completed target is never scheduled again' jq -e \
    '(.jobs.linux.attempts|length)==1 and (.jobs.windows.attempts|length)==2 and
     .jobs.windows.attempts[1].status=="completed"' "$CASE/builds/state.json"
assert 'result binds builder, aggregate, package and signed manifest identities' jq -e \
    '.builds.status=="verified" and .builds.bundle.manifest_sha256==.bundle.manifest_sha256 and
     .packaging.source_manifest_sha256==.bundle.manifest_sha256 and
     .provenance.build_manifest_sha256==.packaging.manifest_sha256 and .provenance.authenticated' "$CASE/result.json"
ARCHIVE="$CASE/builds/bundle/packaged/release/artifacts/tool-windows.zip"
BEFORE_ARCHIVE=$(file_identity "$ARCHIVE")
mv "$CASE/windows" "$CASE/offline-windows"
run_code 'all original producers may disappear after completed imports' 0 plan_flow
assert 'full retry preserves archive inode and bytes' test "$BEFORE_ARCHIVE" = "$(file_identity "$ARCHIVE")"
assert 'full retry reuses one signed statement' test "$(count sign-provenance)" = 1
BEFORE_STATE=$(file_identity "$CASE/builds/state.json")
run_code 'omitted packaging is rejected before the coordinator reruns' 2 plan_base
assert 'omitted recipe leaves build state untouched' test "$BEFORE_STATE" = "$(file_identity "$CASE/builds/state.json")"

plan_case package-failure
jq 'del(.required_assets)' "$CASE/plan.json" > "$CASE/loose-plan.json"
mv "$CASE/loose-plan.json" "$CASE/plan.json"
jq '.artifacts[0].members|=.[0:1]' "$CASE/recipe.json" > "$CASE/incomplete-recipe.json"
mv "$CASE/incomplete-recipe.json" "$CASE/recipe.json"
run_code 'runtime packaging failure retains completed build evidence' 4 plan_flow
assert 'packaging-stage failure keeps both coordinator and collector receipts' jq -e \
    '.stage=="packaging" and .builds.status=="verified" and .bundle.status=="verified" and
     .packaging.publishable==false and .exit_code==4' "$CASE/result.json"
assert 'runtime packaging failure never invokes remote policy' test ! -s "$CASE/calls"

# A temporary installation changes only the native compiler boundary. Every
# coordinating/admission/packaging module is copied byte-for-byte from source.
INSTALL="$WORK/install"
mkdir -p "$INSTALL/src"
for module in release_finalize release_finalize_core release_packaging_pipeline release_packaging release_builds release_bundle slsa packaging; do
    cp "$ROOT/src/$module.sh" "$INSTALL/src/" || exit 1
done
cat > "$INSTALL/dsr" <<'DRIVER'
#!/usr/bin/env bash
set -uo pipefail
python3 - "$@" <<'PY'
import json, os, pathlib, shutil, sys, time
root = pathlib.Path(os.environ["PACKAGE_PIPELINE_CASE"])
args = sys.argv[1:]
out = pathlib.Path(args[args.index("--output-dir") + 1])
with (root / "driver-calls").open("a") as f:
    f.write("start\n")
mode = (root / "driver-mode").read_text().strip()
if mode == "fail":
    sys.exit(1)
if mode == "wait":
    (root / "driver-pid").write_text(str(os.getpid()))
    time.sleep(120)
if mode == "mutate":
    (root / "recipe.json").write_text('{"changed":true}\n')
out.mkdir(parents=True)
manifest = json.loads((root / "build.json").read_text())
for asset in manifest["artifacts"]:
    shutil.copy2(root / "artifacts" / asset["name"], out / asset["name"])
file = out / "tool-v1.0.0-manifest.json"
file.write_text(json.dumps(manifest) + "\n")
print(json.dumps(dict(command="build", status="success", exit_code=0, details=dict(manifest=str(file)))))
PY
DRIVER
native_case() {
    plan_case "$1"
    export PACKAGE_PIPELINE_CASE="$CASE"
    mkdir "$CASE/config"
    printf '{}\n' | tee "$CASE/config/config.yaml" "$CASE/config/repos.yaml" > "$CASE/config/hosts.yaml"
    jq --arg root "$CASE" --arg hash "$(_rf_hash "$CASE/config/config.yaml")" \
        '.builds=[{id:"native",driver:"dsr",targets:.required_targets,config_dir:($root+"/config"),
            config_files:{"config.yaml":$hash,"repos.yaml":$hash,"hosts.yaml":$hash},timeout:30}]' \
        "$CASE/plan.json" > "$CASE/native.json"
    mv "$CASE/native.json" "$CASE/plan.json"
    _RELEASE_FINALIZE_ENTRY_DIR="$INSTALL/src"
}

native_case snapshot
printf 'mutate\n' > "$CASE/driver-mode"
cp "$CASE/recipe.json" "$CASE/reviewed-recipe.json"
run_code 'native build consumes the recipe frozen before compilation' 0 plan_flow
assert 'fixture changed the external recipe during the actual build command' jq -e '.changed' "$CASE/recipe.json"
assert 'derived manifest retains the original reviewed output names' jq -e \
    '(.required_assets|map(.name))==["tool-linux-alias.tar.gz","tool-linux.tar.gz","tool-windows.zip"]' "$BUILD"
assert 'native execution occurred once through the production coordinator' test "$(wc -l < "$CASE/driver-calls")" = 1
cp "$CASE/reviewed-recipe.json" "$CASE/recipe.json"
run_code 'retry never repeats the completed native build' 0 plan_flow
assert 'native compiler boundary is not rerun on publication retry' test "$(wc -l < "$CASE/driver-calls")" = 1

native_case cancellation
printf 'wait\n' > "$CASE/driver-mode"
# Signal the public CLI itself, not an extra test-function subshell. No remote
# policy is reached before this compiler marker; the actual coordinator owns
# and cancels the compiler group.
bash "$INSTALL/src/release_finalize.sh" --build-plan "$CASE/plan.json" --build-dir "$CASE/builds" \
    --packaging-recipe "$CASE/recipe.json" > "$CASE/cancel-result.json" 2> "$CASE/cancel-error.log" &
OWNER=$!
READY=false
for ((attempt=0; attempt<200; attempt++)); do
    if [[ -s "$CASE/driver-pid" ]]; then READY=true; break; fi
    kill -0 "$OWNER" 2>/dev/null || break
    sleep 0.05
done
assert 'native command reached the cancellation boundary' test "$READY" = true
if [[ "$READY" != true ]]; then kill -TERM "$OWNER" 2>/dev/null || true; wait "$OWNER" || true; exit 1; fi
kill -TERM "$OWNER"
STATUS=0
wait "$OWNER" || STATUS=$?
assert 'cancellation exits with the interrupted status' test "$STATUS" = 5
assert 'cancellation returns one non-success envelope' jq -es \
    'length==1 and .[0].exit_code==5 and .[0].status=="error"' "$CASE/cancel-result.json"
assert 'cancellation blocks packages and release effects' test ! -e "$CASE/builds/bundle/packaged"
assert 'cancelled compiler cannot reach publication' test ! -s "$CASE/calls"
assert 'owned native process is no longer running' python3 - "$CASE/driver-pid" <<'PY'
import pathlib, sys
pid = int(pathlib.Path(sys.argv[1]).read_text())
status = pathlib.Path(f"/proc/{pid}/stat")
assert not status.exists() or status.read_text().split()[2] == "Z"
PY
printf 'success\n' > "$CASE/driver-mode"
run_code 'interrupted native plan restarts safely and completes packaged finalization' 0 plan_flow
assert 'retry retains the interrupted attempt and one successful replacement' jq -e \
    '(.jobs.native.attempts|length)==2 and .jobs.native.attempts[0].status=="interrupted" and
     .jobs.native.attempts[1].status=="completed"' "$CASE/builds/state.json"

printf '\nPackaged build-plan finalization: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
