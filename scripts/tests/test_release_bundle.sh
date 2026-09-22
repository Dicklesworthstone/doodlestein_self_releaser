#!/usr/bin/env bash
# Real manifest, hashing, checkpoint and publication-namespace tests. No API
# calls and no fabricated compiler claims: these are producer-manifest fixtures.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
source "$ROOT/src/release_bundle.sh"
_rb_require || exit $?
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
PASS=0 FAIL=0
ok() { printf 'PASS %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf 'FAIL %s\n' "$1" >&2; FAIL=$((FAIL+1)); }
assert() {
    local label=$1; shift
    if "$@" > "$WORK/assert.out" 2> "$WORK/assert.err"; then ok "$label"
    else bad "$label"; cat "$WORK/assert.err" >&2; fi
}
run_code() {
    local label=$1 wanted=$2 rc=0; shift 2
    "$@" > "$WORK/result.json" 2> "$WORK/error.log" || rc=$?
    if [[ "$rc" == "$wanted" ]]; then ok "$label"
    else bad "$label: expected $wanted, got $rc"; cat "$WORK/error.log" >&2; fi
}
SOURCE_SHA=$(printf 'a%.0s' {1..40})
make_fixture() {
    local dir=$1 id target file hash size
    mkdir -p "$dir"
    for id in linux darwin windows; do
        case "$id" in linux) target=linux/amd64 ;; darwin) target=darwin/arm64 ;; windows) target=windows/arm64 ;; esac
        mkdir -p "$dir/$id/artifacts"
        file="tool-$id"; [[ "$id" != windows ]] || file+=.exe
        printf 'verified producer bytes for %s\n' "$target" > "$dir/$id/artifacts/$file"
        chmod 755 "$dir/$id/artifacts/$file"
        hash=$(_slsa_sha256 "$dir/$id/artifacts/$file")
        size=$(wc -c < "$dir/$id/artifacts/$file")
        jq -cn --arg target "$target" --arg name "$file" --arg hash "$hash" --arg source "$SOURCE_SHA" --argjson size "$size" '
            {schema_version:"1.0.0",tool:"tool",version:"v1.2.3",run_id:($target+"-producer"),
             built_at:"2026-09-22T12:00:00Z",status:"success",build_purpose:"release",publishable:true,
             source:{repository:"owner/tool",git_sha:$source,git_ref:"refs/tags/v1.2.3",dependencies:[]},
             summary:{total:1,success:1,failed:0},requested_targets:[$target],
             artifacts:[{name:$name,target:$target,sha256:$hash,size_bytes:$size,archive_format:"binary"}],
             build_environments:[{target:$target,build_influence_env:{CC:"pinned-compiler",XWIN_CROSS_COMPILER:"clang"},
                 toolchain_evidence:{sha256:("c"*64)}}]}' > "$dir/$id/manifest.json" || exit 1
    done
    # Aliases are distinct release names even when they share the same bytes.
    cp "$dir/linux/artifacts/tool-linux" "$dir/linux/artifacts/tool-1.2.3-linux"
    jq '.artifacts += [.artifacts[0]+{name:"tool-1.2.3-linux"}]' "$dir/linux/manifest.json" > "$dir/linux/with-alias.json"
    cp "$dir/linux/with-alias.json" "$dir/linux/manifest.json"
}
make_plan() {
    local dir=$1 dest=$2 id target
    : > "$WORK/entries.jsonl"
    for id in linux darwin windows; do
        case "$id" in linux) target=linux/amd64 ;; darwin) target=darwin/arm64 ;; windows) target=windows/arm64 ;; esac
        jq -cn --arg dir "$dir" --arg id "$id" --arg target "$target" --arg hash "$(_slsa_sha256 "$dir/$id/manifest.json")" \
            '{id:$id,targets:[$target],manifest:($dir+"/"+$id+"/manifest.json"),manifest_sha256:$hash,
              artifacts_dir:($dir+"/"+$id+"/artifacts")}' >> "$WORK/entries.jsonl" || exit 1
    done
    jq -cs --arg source "$SOURCE_SHA" '{schema_version:1,repo:"owner/tool",tag:"v1.2.3",source_sha:$source,tool:"tool",
        required_targets:["linux/amd64","darwin/arm64","windows/arm64"],builds:.}' "$WORK/entries.jsonl" > "$dest" || exit 1
}
collect() { local plan=$1 output=$2; shift 2; release_bundle --plan "$plan" --output-dir "$output" "$@"; }
make_fixture "$WORK/builds"
make_plan "$WORK/builds" "$WORK/plan.json"
run_code 'dry run plans the entire target matrix' 0 collect "$WORK/plan.json" "$WORK/dry" --dry-run
run_code 'CLI dry run has no persistent side effects' 0 bash "$ROOT/src/release_bundle.sh" --plan "$WORK/plan.json" --output-dir "$WORK/dry-cli" --dry-run
assert 'dry output is a plan, never a verified release' jq -e '.status=="planned" and .publishable==false and .dry_run' "$WORK/result.json"
assert 'dry run does not create its output directory' test ! -e "$WORK/dry-cli"
run_code 'three target manifests assemble successfully' 0 collect "$WORK/plan.json" "$WORK/bundle"
BUNDLE="$WORK/bundle"
assert 'one success receipt covers the complete matrix' jq -es 'length==1 and .[0].status=="verified" and .[0].publishable and (.[0].targets|length)==3' "$WORK/result.json"
assert 'stdout equals the durable receipt' cmp -s "$WORK/result.json" "$BUNDLE/release/result.json"
assert 'aggregate counts targets, not aliases or input files' jq -e '.summary=={total:3,success:3,failed:0} and (.artifacts|length)==4' "$BUNDLE/release/build-manifest.json"
assert 'per-target compiler influence evidence is retained' jq -e '.build_environments|length==3 and all(.[];.build_influence_env.CC=="pinned-compiler" and (.toolchain_evidence.sha256|length)==64)' "$BUNDLE/release/build-manifest.json"
assert 'component run and manifest identities remain linked' jq -e '(.component_builds|length)==3 and all(.component_builds[];(.manifest_sha256|length)==64 and (.targets|length)==1)' "$BUNDLE/release/build-manifest.json"
assert 'aggregate is admitted by the real SLSA manifest profile' _slsa_manifest_statement "$BUNDLE/release/build-manifest.json" owner/tool test:bundle
assert 'copies do not alias mutable build-host inodes' test ! "$BUNDLE/inputs/linux/artifacts/tool-linux" -ef "$WORK/builds/linux/artifacts/tool-linux"
assert 'exported copies do not alias checkpoint inodes' test ! "$BUNDLE/release/artifacts/tool-linux" -ef "$BUNDLE/inputs/linux/artifacts/tool-linux"
assert 'executable permissions survive staging' test -x "$BUNDLE/release/artifacts/tool-windows.exe"
cp "$BUNDLE/release/build-manifest.json" "$WORK/first-manifest.json"
IDENTITY=$(stat -c '%d:%i' "$BUNDLE/release/build-manifest.json")
run_code 'complete retry revalidates without recomputing release identity' 0 collect "$WORK/plan.json" "$BUNDLE"
assert 'manifest bytes remain stable across retry' cmp -s "$WORK/first-manifest.json" "$BUNDLE/release/build-manifest.json"
assert 'manifest inode remains stable across retry' test "$IDENTITY" = "$(stat -c '%d:%i' "$BUNDLE/release/build-manifest.json")"
jq '.builds|=reverse | .required_targets|=reverse' "$WORK/plan.json" > "$WORK/reordered.json"
run_code 'input ordering does not create a conflicting plan' 0 collect "$WORK/reordered.json" "$BUNDLE"

make_fixture "$WORK/partial-builds"
make_plan "$WORK/partial-builds" "$WORK/partial-plan.json"
mv "$WORK/partial-builds/windows/manifest.json" "$WORK/held-windows.json"
run_code 'missing target imports ready builds and reports incomplete' 1 collect "$WORK/partial-plan.json" "$WORK/partial"
assert 'incomplete receipt identifies the missing input' jq -e '.status=="incomplete" and .publishable==false and .imported_builds==2 and .missing_builds==["windows"]' "$WORK/result.json"
assert 'partial collection has no publishable release directory' test ! -e "$WORK/partial/release"
assert 'completed shard is a durable checkpoint' test -f "$WORK/partial/inputs/linux/build-manifest.json"
mv "$WORK/partial-builds/linux" "$WORK/offline-linux"
mv "$WORK/partial-builds/darwin" "$WORK/offline-darwin"
mv "$WORK/held-windows.json" "$WORK/partial-builds/windows/manifest.json"
run_code 'resume uses checkpoints even when original hosts disappear' 0 collect "$WORK/partial-plan.json" "$WORK/partial"
assert 'completed resume retains the original Linux bytes' cmp -s "$WORK/offline-linux/artifacts/tool-linux" "$WORK/partial/release/artifacts/tool-linux"

jq '.builds[0].manifest_sha256=("0"*64)' "$WORK/plan.json" > "$WORK/changed-plan.json"
run_code 'a different pinned plan cannot reuse existing checkpoints' 2 collect "$WORK/changed-plan.json" "$BUNDLE"
assert 'conflicting retry does not alter a completed manifest' cmp -s "$WORK/first-manifest.json" "$BUNDLE/release/build-manifest.json"
for FILTER in '.required_targets += ["linux/arm64"]' '.builds[0].targets=["windows/arm64"]' \
    '.builds[0].id="../escape"' '.builds[0].manifest="relative.json"' '.unknown_option=true' \
    '.required_targets += [.required_targets[0]]' '.builds[1].id=.builds[0].id'; do
    jq "$FILTER" "$WORK/plan.json" > "$WORK/bad-plan.json"
    run_code "plan rejected: $FILTER" 4 collect "$WORK/bad-plan.json" "$WORK/invalid-plan"
    assert 'invalid plan creates no persistent directory' test ! -e "$WORK/invalid-plan"
done
cat "$WORK/plan.json" "$WORK/plan.json" > "$WORK/bad-plan.json"
run_code 'concatenated plan documents are rejected' 4 collect "$WORK/bad-plan.json" "$WORK/invalid-plan"

# Pin each semantically invalid manifest again, so rejection must come from
# admission checks rather than an unrelated changed input hash.
CASE=0
for FILTER in '.source.git_sha=("b"*40)' '.version="v9.9.9"' '.tool="other"' \
    '.source.repository="owner/other"' '.publishable=false' '.build_purpose="debug"' \
    '.artifacts[0].publishable=false' '.requested_targets=["linux/arm64"]' \
    '.status="failed"' '.summary.failed=1' '.artifacts[0].name="../escape"' \
    '.source.dependencies=[{relative_path:"core",git_sha:("b"*40)}]'; do
    CASE=$((CASE+1)); DIR="$WORK/case-$CASE"
    make_fixture "$DIR"
    jq "$FILTER" "$DIR/windows/manifest.json" > "$DIR/windows/changed.json"
    cp "$DIR/windows/changed.json" "$DIR/windows/manifest.json"
    make_plan "$DIR" "$DIR/plan.json"
    RC=0; collect "$DIR/plan.json" "$DIR/bundle" > "$WORK/result.json" 2> "$WORK/error.log" || RC=$?
    if [[ "$RC" == 4 || "$RC" == 7 ]]; then ok "manifest rejected: $FILTER"
    else bad "manifest accepted or unexpected exit $RC: $FILTER"; cat "$WORK/error.log" >&2; fi
    assert 'rejected shard cannot publish a release' test ! -e "$DIR/bundle/release"
done
make_fixture "$WORK/collision"
cp "$WORK/collision/windows/artifacts/tool-windows.exe" "$WORK/collision/windows/artifacts/tool-linux"
jq '.artifacts[0].name="tool-linux"' "$WORK/collision/windows/manifest.json" > "$WORK/collision/windows/changed.json"
cp "$WORK/collision/windows/changed.json" "$WORK/collision/windows/manifest.json"
make_plan "$WORK/collision" "$WORK/collision-plan.json"
run_code 'different targets cannot collide in the release namespace' 7 collect "$WORK/collision-plan.json" "$WORK/collision-bundle"
assert 'namespace collision leaves no release directory' test ! -e "$WORK/collision-bundle/release"

make_fixture "$WORK/corrupt"
make_plan "$WORK/corrupt" "$WORK/corrupt-plan.json"
printf 'changed bytes\n' >> "$WORK/corrupt/windows/artifacts/tool-windows.exe"
run_code 'artifact corruption is not confused with missing builds' 7 collect "$WORK/corrupt-plan.json" "$WORK/corrupt-bundle"
assert 'failed import preserves completed earlier shards' test -f "$WORK/corrupt-bundle/inputs/linux/build-manifest.json"
assert 'failed import never creates a checkpoint for corrupted bytes' test ! -e "$WORK/corrupt-bundle/inputs/windows"
printf 'verified producer bytes for windows/arm64\n' > "$WORK/corrupt/windows/artifacts/tool-windows.exe"
run_code 'fixed input resumes after earlier corruption' 0 collect "$WORK/corrupt-plan.json" "$WORK/corrupt-bundle"

cp "$BUNDLE/release/artifacts/tool-linux" "$WORK/saved-linux"
printf 'changed\n' > "$BUNDLE/release/artifacts/tool-linux"
run_code 'completed release payload drift is refused' 7 collect "$WORK/plan.json" "$BUNDLE"
cp "$WORK/saved-linux" "$BUNDLE/release/artifacts/tool-linux"
printf 'unplanned\n' > "$BUNDLE/release/artifacts/unplanned"
run_code 'unlisted output payload is refused' 7 collect "$WORK/plan.json" "$BUNDLE"
mv "$BUNDLE/release/artifacts/unplanned" "$WORK/held-unplanned"
printf 'changed checkpoint\n' > "$BUNDLE/inputs/linux/artifacts/tool-linux"
run_code 'checkpoint drift is independently refused on a complete retry' 7 collect "$WORK/plan.json" "$BUNDLE"
cp "$WORK/saved-linux" "$BUNDLE/inputs/linux/artifacts/tool-linux"
run_code 'valid restored checkpoint can be reverified' 0 collect "$WORK/plan.json" "$BUNDLE"

mkdir "$WORK/foreign"
printf 'must retain\n' > "$WORK/foreign/existing-file"
run_code 'foreign output directory is never adopted' 2 collect "$WORK/plan.json" "$WORK/foreign"
assert 'foreign data is preserved' grep -Fxq 'must retain' "$WORK/foreign/existing-file"
ln -s "$WORK" "$WORK/link"
run_code 'symlinked output ancestors are refused' 4 collect "$WORK/plan.json" "$WORK/link/redirected"
contended() (
    exec 9>> "$BUNDLE/lock"
    flock -n 9 || return 99
    collect "$WORK/plan.json" "$BUNDLE"
)
run_code 'concurrent collection refuses an occupied lock' 2 contended

make_fixture "$WORK/large"
jq '.build_environments[0].source_inventory=[range(0;2200)|{path:("src/file-"+(.|tostring)),sha256:("a"*64)}]' \
    "$WORK/large/windows/manifest.json" > "$WORK/large/windows/large.json"
cp "$WORK/large/windows/large.json" "$WORK/large/windows/manifest.json"
make_plan "$WORK/large" "$WORK/large-plan.json"
run_code 'large evidence is processed through files rather than argv' 0 collect "$WORK/large-plan.json" "$WORK/large-bundle"
assert 'large aggregate retains every source inventory entry' jq -e '[.build_environments[]|select(.target=="windows/arm64")][0].source_inventory|length==2200' "$WORK/large-bundle/release/build-manifest.json"
assert 'large aggregate exceeds the per-argument size boundary' test "$(wc -c < "$WORK/large-bundle/release/build-manifest.json")" -gt 131072
run_code 'large evidence also survives complete retry' 0 collect "$WORK/large-plan.json" "$WORK/large-bundle"
printf '\nRelease bundle: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
