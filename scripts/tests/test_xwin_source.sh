#!/usr/bin/env bash
# Real Git object snapshots and Cargo metadata admission. No SDK/network needed.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
source "$ROOT/src/xwin_source.sh"
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
PASS=0 FAIL=0
ok() { printf 'PASS %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf 'FAIL %s\n' "$1" >&2; FAIL=$((FAIL + 1)); }
assert() { local label=$1; shift; if "$@" > "$WORK/assert.out" 2> "$WORK/assert.err"; then ok "$label"; else bad "$label"; cat "$WORK/assert.err" >&2; fi; }
reject() {
    local label=$1 expected=$2 rc=0; shift 2
    "$@" > "$WORK/rejected.out" 2> "$WORK/rejected.err" || rc=$?
    if [[ "$rc" == "$expected" && ! -s "$WORK/rejected.out" ]]; then ok "$label"; else
        bad "$label (expected $expected, got $rc)"; cat "$WORK/rejected.err" >&2
    fi
}
PROJECT="$WORK/project"
mkdir -p "$PROJECT/src"
git -C "$PROJECT" init -q -b main || exit 1
git -C "$PROJECT" config user.name 'DSR Test'
git -C "$PROJECT" config user.email test@example.invalid
git -C "$PROJECT" remote add origin https://github.com/owner/demo.git
printf '[package]\nname = "demo"\nversion = "1.2.3"\n' > "$PROJECT/Cargo.toml"
printf 'version = 3\n' > "$PROJECT/Cargo.lock"
printf 'fn main() {}\n' > "$PROJECT/src/main.rs"
printf 'ignored.txt\n' > "$PROJECT/.gitignore"
printf 'src/main.rs export-ignore\nCargo.lock export-subst\n' > "$PROJECT/.gitattributes"
printf '#!/bin/sh\nexit 0\n' > "$PROJECT/build-helper"
chmod 755 "$PROJECT/build-helper"
git -C "$PROJECT" add . && git -C "$PROJECT" commit -qm fixture || exit 1
SHA=$(git -C "$PROJECT" rev-parse HEAD)
git -C "$PROJECT" tag v1.2.3
printf 'uncommitted ignored content\n' > "$PROJECT/ignored.txt"
SNAP="$WORK/source" RECEIPT="$WORK/source.json"
assert 'snapshot materializes the selected Git commit' xwin_source_snapshot "$PROJECT" "$SHA" v1.2.3 owner/demo "$SNAP" "$RECEIPT"
[[ -f "$RECEIPT" ]] || exit 1
assert 'export-ignore cannot omit a compiled source file' cmp -s "$PROJECT/src/main.rs" "$SNAP/src/main.rs"
assert 'untracked ignored input is not copied into the snapshot' test ! -e "$SNAP/ignored.txt"
assert 'executable mode is preserved' test -x "$SNAP/build-helper"
assert 'snapshot has no inherited Git configuration' test ! -e "$SNAP/.git"
assert 'receipt binds repository commit tag tree and inventory' jq -e --arg sha "$SHA" \
    '.git_sha==$sha and .git_ref=="refs/tags/v1.2.3" and .repository=="https://github.com/owner/demo" and (.git_tree|length)==40 and (.snapshot_sha256|length)==64 and (.files|length)==6' "$RECEIPT"
assert 'unchanged committed source revalidates' xwin_source_verify "$SNAP" "$RECEIPT"
reject 'existing snapshot is never overwritten' 4 xwin_source_snapshot "$PROJECT" "$SHA" v1.2.3 owner/demo "$SNAP" "$WORK/again.json"
reject 'repository substitution rejected' 4 xwin_source_snapshot "$PROJECT" "$SHA" v1.2.3 other/demo "$WORK/wrong-repo" "$WORK/wrong-repo.json"
reject 'missing tag rejected' 4 xwin_source_snapshot "$PROJECT" "$SHA" v9.9.9 owner/demo "$WORK/wrong-tag" "$WORK/wrong-tag.json"
WRONG_SHA="0${SHA:1}"
[[ "$WRONG_SHA" != "$SHA" ]] || WRONG_SHA="1${SHA:1}"
reject 'wrong explicit source commit rejected' 4 xwin_source_snapshot "$PROJECT" "$WRONG_SHA" v1.2.3 owner/demo "$WORK/wrong-sha" "$WORK/wrong-sha.json"
assert 'ambient Git repository overrides cannot select another checkout' env GIT_DIR=/nonexistent GIT_WORK_TREE=/nonexistent bash -c \
    'source "$1/src/xwin_source.sh"; xwin_source_snapshot "$2" "$3" v1.2.3 owner/demo "$4" "$5"' _ "$ROOT" "$PROJECT" "$SHA" "$WORK/ambient" "$WORK/ambient.json"
printf '// dirty\n' >> "$PROJECT/src/main.rs"
reject 'dirty tracked checkout refused' 4 xwin_source_snapshot "$PROJECT" "$SHA" v1.2.3 owner/demo "$WORK/dirty" "$WORK/dirty.json"
cp "$SNAP/src/main.rs" "$PROJECT/src/main.rs"
printf '// generated drift\n' >> "$SNAP/src/main.rs"
reject 'source changes during compilation invalidate receipt' 7 xwin_source_verify "$SNAP" "$RECEIPT"
cp "$PROJECT/src/main.rs" "$SNAP/src/main.rs"
chmod 644 "$SNAP/build-helper"
reject 'executable mode drift is rejected' 7 xwin_source_verify "$SNAP" "$RECEIPT"
chmod 755 "$SNAP/build-helper"
printf 'new implicit input\n' > "$SNAP/extra"
reject 'new source files invalidate receipt' 7 xwin_source_verify "$SNAP" "$RECEIPT"
mv "$SNAP/extra" "$WORK/extra"
ln -s /etc "$SNAP/linked-dir"
reject 'linked source directories are rejected' 7 xwin_source_verify "$SNAP" "$RECEIPT"
mv "$SNAP/linked-dir" "$WORK/linked-dir"
assert 'restored original snapshot revalidates' xwin_source_verify "$SNAP" "$RECEIPT"

# Model Cargo metadata v1 with a root binary and an external resolved crate.
python3 - "$SNAP" "$WORK/metadata.json" <<'PY'
import json, sys
root, output = sys.argv[1:]
a = {"id":"local-demo", "name":"demo", "version":"1.2.3", "source":None,
     "manifest_path":root+"/Cargo.toml", "targets":[{"name":"demo", "kind":["bin"], "src_path":root+"/src/main.rs"}]}
b = {"id":"registry-lib", "name":"lib", "version":"2.0.0", "source":"registry+https://example.invalid/index", "targets":[]}
nodes = [{"id":"local-demo", "dependencies":["registry-lib"], "features":["default"], "deps":[{"name":"lib", "pkg":"registry-lib", "dep_kinds":[{"kind":None, "target":None}]}]},
         {"id":"registry-lib", "dependencies":[], "features":[], "deps":[]}]
graph = {"version":1, "workspace_root":root, "workspace_members":["local-demo"], "workspace_default_members":["local-demo"], "packages":[a,b], "resolve":{"root":"local-demo", "nodes":nodes}, "target_directory":root+"/../target"}
with open(output, "w") as f: json.dump(graph, f)
PY
META="$WORK/metadata.json"
assert 'complete Cargo graph admits the committed binary' xwin_source_metadata "$META" "$SNAP" demo '' "$WORK/canonical.json" 1.2.3
assert 'explicit workspace package selection works' xwin_source_metadata "$META" "$SNAP" demo demo "$WORK/package.json" 1.2.3
cp "$WORK/assert.out" "$WORK/selection.json"
assert 'selection retains metadata and package identity' jq -e '.package=="demo" and .binary=="demo" and .resolved_packages==2 and (.metadata_sha256|length)==64' "$WORK/selection.json"
reject 'release version mismatch rejected' 7 xwin_source_metadata "$META" "$SNAP" demo '' "$WORK/version.json" 9.9.9
reject 'unknown binary rejected' 7 xwin_source_metadata "$META" "$SNAP" other '' "$WORK/binary.json" 1.2.3
reject 'unknown package rejected' 7 xwin_source_metadata "$META" "$SNAP" demo other "$WORK/package-other.json" 1.2.3
jq '.resolve=null' "$META" > "$WORK/bad.json"
reject 'no-deps metadata cannot admit a release' 7 xwin_source_metadata "$WORK/bad.json" "$SNAP" demo '' "$WORK/no-deps.json" 1.2.3
jq '.packages[1].source=null|.packages[1].manifest_path="/outside/Cargo.toml"' "$META" > "$WORK/bad.json"
reject 'external local dependency is not claimed as pinned' 7 xwin_source_metadata "$WORK/bad.json" "$SNAP" demo '' "$WORK/outside.json" 1.2.3
jq '.packages[0].targets[0]["required-features"]=["not-active"]' "$META" > "$WORK/bad.json"
reject 'inactive required binary features rejected' 7 xwin_source_metadata "$WORK/bad.json" "$SNAP" demo '' "$WORK/features.json" 1.2.3
jq '.resolve.nodes[0].dependencies=["absent"]' "$META" > "$WORK/bad.json"
reject 'dangling dependency graph edges rejected' 7 xwin_source_metadata "$WORK/bad.json" "$SNAP" demo '' "$WORK/edge.json" 1.2.3
jq '.packages += [.packages[0]]' "$META" > "$WORK/bad.json"
reject 'duplicate package identities rejected' 7 xwin_source_metadata "$WORK/bad.json" "$SNAP" demo '' "$WORK/duplicates.json" 1.2.3
jq '.workspace_root="/outside"' "$META" > "$WORK/bad.json"
reject 'workspace escape rejected' 7 xwin_source_metadata "$WORK/bad.json" "$SNAP" demo '' "$WORK/workspace.json" 1.2.3
cat "$META" "$META" > "$WORK/bad.json"
reject 'multiple metadata documents rejected' 7 xwin_source_metadata "$WORK/bad.json" "$SNAP" demo '' "$WORK/multiple.json" 1.2.3
jq '.packages|=reverse|.resolve.nodes|=reverse' "$META" > "$WORK/reordered.json"
assert 'equivalent package/node order canonicalizes identically' xwin_source_metadata "$WORK/reordered.json" "$SNAP" demo '' "$WORK/reordered-canonical.json" 1.2.3
assert 'canonical graph identity is stable' cmp -s "$WORK/reordered-canonical.json" "$WORK/canonical.json"

# Independently committed library repositories need not have the primary
# release tag or a Cargo.lock. These are real Git snapshots; Cargo JSON below
# remains an explicit metadata-boundary fixture, not a Rust compilation.
for sibling in helper types; do
    mkdir -p "$WORK/$sibling/src"
    git -C "$WORK/$sibling" init -q -b main || exit 1
    git -C "$WORK/$sibling" config user.name 'DSR Test'
    git -C "$WORK/$sibling" config user.email test@example.invalid
    git -C "$WORK/$sibling" remote add origin "https://github.com/owner/$sibling.git"
    printf '[package]\nname="%s"\nversion="0.1.0"\n' "$sibling" > "$WORK/$sibling/Cargo.toml"
    printf 'pub fn answer() -> u32 { 42 }\n' > "$WORK/$sibling/src/lib.rs"
    printf 'ignored\n' > "$WORK/$sibling/.gitignore"
    git -C "$WORK/$sibling" add . && git -C "$WORK/$sibling" commit -qm library || exit 1
    printf 'never stage these bytes\n' > "$WORK/$sibling/ignored"
done
HELPER_SHA=$(git -C "$WORK/helper" rev-parse HEAD)
TYPES_SHA=$(git -C "$WORK/types" rev-parse HEAD)
jq -cn --arg root "$WORK" --arg helper "$HELPER_SHA" --arg types "$TYPES_SHA" \
    '[{relative_path:"types",local_path:($root+"/types"),revision:$types,repo:"owner/types"},
      {relative_path:"helper",local_path:($root+"/helper"),revision:$helper,repo:"owner/helper"}]' > "$WORK/siblings.json"
SET="$WORK/source-set" SET_RECEIPT="$WORK/source-set.json"
assert 'pinned siblings and primary stage as one source set' xwin_source_snapshot_set \
    "$PROJECT" "$SHA" v1.2.3 owner/demo "$SET" "$SET_RECEIPT" "$WORK/siblings.json"
[[ -f "$SET_RECEIPT" ]] || exit 1
assert 'primary source stays byte-identical in the sibling layout' cmp -s "$SNAP/src/main.rs" "$SET/project/src/main.rs"
assert 'library without a tag or lockfile stages from its own pinned commit' cmp -s "$WORK/helper/src/lib.rs" "$SET/helper/src/lib.rs"
assert 'ignored sibling files never enter the source set' test ! -e "$SET/helper/ignored"
assert 'sibling checkout metadata never enters the source set' test ! -e "$SET/helper/.git"
assert 'source-set evidence contains every file and sorted independent pins' jq -e --arg helper "$HELPER_SHA" --arg types "$TYPES_SHA" \
    '.primary_path=="project" and (.primary_snapshot_sha256|length)==64 and
     (.dependencies|map({relative_path,git_sha}))==[{relative_path:"helper",git_sha:$helper},{relative_path:"types",git_sha:$types}] and
     all(.dependencies[];(.git_tree|length)==40 and (.snapshot_sha256|length)==64) and (.files|length)==12' "$SET_RECEIPT"
assert 'entire source set revalidates together' xwin_source_verify "$SET" "$SET_RECEIPT"
jq reverse "$WORK/siblings.json" > "$WORK/siblings-reordered.json"
assert 'sibling plan order does not change staged evidence' xwin_source_snapshot_set \
    "$PROJECT" "$SHA" v1.2.3 owner/demo "$WORK/reordered-set" "$WORK/reordered-set.json" "$WORK/siblings-reordered.json"
assert 'source-set receipt is independent of input ordering and stage path' cmp -s "$SET_RECEIPT" "$WORK/reordered-set.json"
reject 'existing source set is never overwritten' 4 xwin_source_snapshot_set \
    "$PROJECT" "$SHA" v1.2.3 owner/demo "$SET" "$WORK/set-again.json" "$WORK/siblings.json"

SET_CASE=0
reject_sibling_plan() {
    local label=$1 filter=$2
    SET_CASE=$((SET_CASE + 1))
    jq "$filter" "$WORK/siblings.json" > "$WORK/bad-siblings.json" || exit 1
    reject "$label" 4 xwin_source_snapshot_set "$PROJECT" "$SHA" v1.2.3 owner/demo \
        "$WORK/refused-set-$SET_CASE" "$WORK/refused-set-$SET_CASE.json" "$WORK/bad-siblings.json"
    assert "$label leaves no admitted source set" test ! -e "$WORK/refused-set-$SET_CASE"
}
reject_sibling_plan 'unreviewed sibling repository rejected' '.[0].repo="someone/else"'
reject_sibling_plan 'unreviewed sibling commit rejected' '.[0].revision=("1"*40)'
reject_sibling_plan 'sibling path traversal rejected' '.[0].relative_path="../escape"'
reject_sibling_plan 'sibling cannot overwrite the primary' '.[0].relative_path="project"'
reject_sibling_plan 'case-insensitive sibling collision rejected' '.[0].relative_path="HELPER"'
reject_sibling_plan 'one checkout cannot masquerade as multiple siblings' '.[0].local_path=.[1].local_path|.[0].repo=.[1].repo|.[0].revision=.[1].revision'
reject_sibling_plan 'incomplete sibling pin rejected' '.[0]|=del(.revision)'
reject_sibling_plan 'unrecognized sibling fields rejected' '.[0].optional=true'
reject_sibling_plan 'empty sibling plan rejected' '[]'
cat "$WORK/siblings.json" "$WORK/siblings.json" > "$WORK/bad-siblings.json"
reject 'concatenated sibling plans rejected' 4 xwin_source_snapshot_set "$PROJECT" "$SHA" v1.2.3 owner/demo \
    "$WORK/multiple-set" "$WORK/multiple-set.json" "$WORK/bad-siblings.json"
printf '// dirty\n' >> "$WORK/helper/src/lib.rs"
reject 'dirty sibling checkout rejected before any snapshot' 4 xwin_source_snapshot_set "$PROJECT" "$SHA" v1.2.3 owner/demo \
    "$WORK/dirty-set" "$WORK/dirty-set.json" "$WORK/siblings.json"
assert 'dirty sibling did not create a primary-only snapshot' test ! -e "$WORK/dirty-set"
cp "$SET/helper/src/lib.rs" "$WORK/helper/src/lib.rs"

# The primary's reachable graph now includes two transitive local libraries.
jq --arg root "$SET" '
    .workspace_root=($root+"/project") |
    .packages[0].manifest_path=($root+"/project/Cargo.toml") |
    .packages[0].targets[0].src_path=($root+"/project/src/main.rs") |
    .packages += (["helper","types"]|map(. as $n|
      {id:("local-"+$n),name:$n,version:"0.1.0",source:null,manifest_path:($root+"/"+$n+"/Cargo.toml"),
       targets:[{name:$n,kind:["lib"],src_path:($root+"/"+$n+"/src/lib.rs")}]})) |
    .resolve.nodes[0].dependencies += ["local-helper"] |
    .resolve.nodes[0].deps += [{name:"helper",pkg:"local-helper",dep_kinds:[]}] |
    .resolve.nodes += [{id:"local-helper",dependencies:["local-types"],features:[],deps:[{name:"types",pkg:"local-types",dep_kinds:[]}]},
                      {id:"local-types",dependencies:[],features:[],deps:[]}]' "$META" > "$WORK/set-metadata.json"
assert 'Cargo graph admits only the declared committed sibling roots' xwin_source_metadata \
    "$WORK/set-metadata.json" "$SET/project" demo '' "$WORK/set-canonical.json" 1.2.3 "$SET_RECEIPT"
cp "$WORK/assert.out" "$WORK/set-selection.json"
assert 'selection distinguishes declared pins and reachable siblings' jq -e --arg helper "$HELPER_SHA" --arg types "$TYPES_SHA" \
    '.source_dependencies==[{relative_path:"helper",git_sha:$helper},{relative_path:"types",git_sha:$types}] and
     .resolved_siblings==["helper","types"] and .binary_source=="src/main.rs"' "$WORK/set-selection.json"
reject 'siblings are still refused without an admitted receipt' 7 xwin_source_metadata \
    "$WORK/set-metadata.json" "$SET/project" demo '' "$WORK/unbound-set.json" 1.2.3
jq --arg root "$WORK/helper" '.packages[2].manifest_path=($root+"/Cargo.toml")' "$WORK/set-metadata.json" > "$WORK/bad-meta.json"
reject 'metadata cannot point back at the mutable original sibling checkout' 7 xwin_source_metadata \
    "$WORK/bad-meta.json" "$SET/project" demo '' "$WORK/original-sibling.json" 1.2.3 "$SET_RECEIPT"
jq --arg root "$SET" '.packages[0].targets[0].src_path=($root+"/helper/src/lib.rs")' "$WORK/set-metadata.json" > "$WORK/bad-meta.json"
reject 'release binary cannot substitute a sibling library source' 7 xwin_source_metadata \
    "$WORK/bad-meta.json" "$SET/project" demo '' "$WORK/sibling-binary.json" 1.2.3 "$SET_RECEIPT"
printf '// changed after admission\n' >> "$SET/types/src/lib.rs"
reject 'transitive sibling byte drift invalidates the entire source set' 7 xwin_source_verify "$SET" "$SET_RECEIPT"
reject 'metadata admission cannot bless a drifted sibling' 7 xwin_source_metadata \
    "$WORK/set-metadata.json" "$SET/project" demo '' "$WORK/drifted-sibling.json" 1.2.3 "$SET_RECEIPT"
cp "$WORK/types/src/lib.rs" "$SET/types/src/lib.rs"
chmod 755 "$SET/types/src/lib.rs"
reject 'sibling executable mode drift invalidates the source set' 7 xwin_source_verify "$SET" "$SET_RECEIPT"
chmod 644 "$SET/types/src/lib.rs"
mkdir "$SET/unplanned"
reject 'even an empty unplanned sibling root is refused' 7 xwin_source_verify "$SET" "$SET_RECEIPT"
mv "$SET/unplanned" "$WORK/unplanned-empty"
assert 'restored complete source set revalidates' xwin_source_verify "$SET" "$SET_RECEIPT"
ln -s src/lib.rs "$WORK/helper/link"
git -C "$WORK/helper" add link && git -C "$WORK/helper" commit -qm unsafe || exit 1
UNSAFE_SHA=$(git -C "$WORK/helper" rev-parse HEAD)
jq --arg sha "$UNSAFE_SHA" 'map(if .relative_path=="helper" then .revision=$sha else . end)' "$WORK/siblings.json" > "$WORK/linked-siblings.json"
reject 'committed sibling symlinks are refused before staging' 4 xwin_source_snapshot_set "$PROJECT" "$SHA" v1.2.3 owner/demo \
    "$WORK/unsafe-sibling-set" "$WORK/unsafe-sibling-set.json" "$WORK/linked-siblings.json"
assert 'unsafe sibling prevents creating the entire source set' test ! -e "$WORK/unsafe-sibling-set"

# The input Git tree itself must not contain an unbound symlink/submodule.
ln -s src/main.rs "$PROJECT/linked-source"
git -C "$PROJECT" add linked-source && git -C "$PROJECT" commit -qm linked || exit 1
LINK_SHA=$(git -C "$PROJECT" rev-parse HEAD)
git -C "$PROJECT" tag v1.2.4
reject 'committed symlinks are rejected before source creation' 4 xwin_source_snapshot "$PROJECT" "$LINK_SHA" v1.2.4 owner/demo "$WORK/linked" "$WORK/linked.json"
assert 'unsafe Git tree left no release snapshot' test ! -e "$WORK/linked"
printf '\nWindows ARM64 source admission: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
