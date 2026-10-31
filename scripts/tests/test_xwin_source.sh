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
# Create the cache and lock pin BEFORE committing the primary source. A
# receipt generated from today's cache bytes is not an upstream checksum.
python3 - "$WORK" "$PROJECT/Cargo.lock" <<'PY'
import hashlib, sys, tarfile
from pathlib import Path
work, lock = map(Path, sys.argv[1:])
dependency=work/'cargo-home/registry/src/example-123/lib-2.0.0'
dependency.mkdir(parents=True)
(dependency/'Cargo.toml').write_text('[package]\nname="lib"\nversion="2.0.0"\n')
(dependency/'lib.rs').write_text('pub fn value() -> u32 { 42 }\n')
archive=work/'cargo-home/registry/cache/example-123/lib-2.0.0.crate'
archive.parent.mkdir(parents=True)
with tarfile.open(archive,'w:gz') as output:
    for path in sorted(dependency.iterdir()):
        output.add(path,arcname='lib-2.0.0/'+path.name)
digest=hashlib.sha256(archive.read_bytes()).hexdigest()
lock.write_text('version = 3\n[[package]]\nname="demo"\nversion="1.2.3"\n'
    '[[package]]\nname="lib"\nversion="2.0.0"\nsource="registry+https://example.invalid/index"\n'
    'checksum="'+digest+'"\n')
PY
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
    '.git_sha==$sha and .git_ref=="refs/tags/v1.2.3" and .repository=="https://github.com/owner/demo" and (.git_tree|length)==40 and (.git_commit_object|length)>0 and (.snapshot_sha256|length)==64 and (.files|length)==6' "$RECEIPT"
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
from pathlib import Path
root, output = sys.argv[1:]
dependency=Path(output).parent/'cargo-home/registry/src/example-123/lib-2.0.0'
assert dependency.is_dir()
a = {"id":"local-demo", "name":"demo", "version":"1.2.3", "source":None,
     "manifest_path":root+"/Cargo.toml", "targets":[{"name":"demo", "kind":["bin"], "src_path":root+"/src/main.rs"}]}
b = {"id":"registry-lib", "name":"lib", "version":"2.0.0", "source":"registry+https://example.invalid/index",
     "manifest_path":str(dependency/'Cargo.toml'),
     "targets":[{"name":"lib","kind":["lib"],"src_path":str(dependency/'lib.rs')}]}
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

# Graph equality alone cannot admit unchanged dependency source. Exercise the
# production metadata boundary, including the full inventory held by the
# runner's metadata hash and the compact selection exported in the manifest.
assert 'metadata and selection bind the complete dependency inventory' python3 - "$WORK/canonical.json" "$WORK/selection.json" <<'PY'
import hashlib, json, sys
from pathlib import Path
raw=Path(sys.argv[1]).read_bytes()
graph=json.loads(raw); selection=json.loads(Path(sys.argv[2]).read_bytes())
sources=graph['dsr_dependency_sources']
encoded=(json.dumps(sources,sort_keys=True,separators=(',',':'))+'\n').encode()
assert selection['metadata_sha256']==hashlib.sha256(raw).hexdigest()
assert selection['dependency_sources']['sha256']==hashlib.sha256(encoded).hexdigest()
assert selection['dependency_sources']['package_count']==1
assert {entry['path'] for entry in sources['roots'][0]['files']}=={'Cargo.toml','lib.rs'}
assert selection['dependency_sources']['authentication']['locked_archive_packages']==1
assert sources['authentication']['packages'][0]['basis']=='lockfile-crate-sha256'
assert sources['authentication']['lockfile_sha256']==hashlib.sha256(Path(graph['workspace_root'],'Cargo.lock').read_bytes()).hexdigest()
PY
DEPENDENCY="$WORK/cargo-home/registry/src/example-123/lib-2.0.0"
cp "$META" "$WORK/unchanged-raw.json"
printf 'pub fn value() -> u32 { 43 }\n' > "$DEPENDENCY/lib.rs"
reject 'changed dependency is refused even on its first metadata observation' 7 xwin_source_metadata \
    "$META" "$SNAP" demo '' "$WORK/changed-sources.json" 1.2.3
assert 'the raw Cargo dependency graph did not change' cmp -s "$META" "$WORK/unchanged-raw.json"
assert 'committed primary source is unchanged during dependency mutation' xwin_source_verify "$SNAP" "$RECEIPT"
assert 'poisoned source has no admitted dependency sidecar' test ! -e "$WORK/changed-sources.json.dependency-sources.json"
assert 'poisoned source produces no successful selection' test ! -s "$WORK/rejected.out"
printf 'pub fn value() -> u32 { 42 }\n' > "$DEPENDENCY/lib.rs"
assert 'restored dependency bytes regain their original source identity' xwin_source_metadata \
    "$META" "$SNAP" demo '' "$WORK/restored-sources.json" 1.2.3
assert 'source identity is independent of cache timestamps' cmp -s "$WORK/canonical.json" "$WORK/restored-sources.json"
mkdir -p "$WORK/cargo-home/registry/index"
printf 'updated index\n' > "$WORK/cargo-home/registry/index/cache"
assert 'unrelated registry maintenance does not change admitted sources' xwin_source_metadata \
    "$META" "$SNAP" demo '' "$WORK/index-maintenance.json" 1.2.3
assert 'unrelated registry changes preserve release metadata identity' cmp -s "$WORK/canonical.json" "$WORK/index-maintenance.json"
ln -s "$PROJECT/src/main.rs" "$DEPENDENCY/linked-input"
reject 'linked remote source fails without a successful selection receipt' 7 xwin_source_metadata \
    "$META" "$SNAP" demo '' "$WORK/linked-dependency.json" 1.2.3
mv "$DEPENDENCY/linked-input" "$WORK/retained-link"
mv "$DEPENDENCY/lib.rs" "$WORK/retained-dependency.rs"
reject 'missing resolved source fails before release admission' 7 xwin_source_metadata \
    "$META" "$SNAP" demo '' "$WORK/missing-dependency.json" 1.2.3
mv "$WORK/retained-dependency.rs" "$DEPENDENCY/lib.rs"
jq '.dsr_dependency_sources={forged:true}' "$META" > "$WORK/forged-metadata.json"
reject 'raw metadata cannot supply DSR dependency evidence' 7 xwin_source_metadata \
    "$WORK/forged-metadata.json" "$SNAP" demo '' "$WORK/forged-canonical.json" 1.2.3
jq '.packages[0].targets += [(.packages[0].targets[0]|.name="companion")]' "$META" > "$WORK/companion-metadata.json"
assert 'multiple binaries in one package share its dependency inventory' xwin_source_metadata \
    "$WORK/companion-metadata.json" "$SNAP" demo '' "$WORK/companion-canonical.json" 1.2.3 '' '["demo","companion"]'
cp "$WORK/assert.out" "$WORK/companion-selection.json"
assert 'companion selection preserves one resolved package boundary' jq -e \
    '(.binaries|length)==2 and .dependency_sources.package_count==1' "$WORK/companion-selection.json"

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
ln -s ../outside.rs "$WORK/helper/link"
git -C "$WORK/helper" add link && git -C "$WORK/helper" commit -qm unsafe || exit 1
UNSAFE_SHA=$(git -C "$WORK/helper" rev-parse HEAD)
jq --arg sha "$UNSAFE_SHA" 'map(if .relative_path=="helper" then .revision=$sha else . end)' "$WORK/siblings.json" > "$WORK/linked-siblings.json"
reject 'escaping committed sibling symlinks are refused before staging' 4 xwin_source_snapshot_set "$PROJECT" "$SHA" v1.2.3 owner/demo \
    "$WORK/unsafe-sibling-set" "$WORK/unsafe-sibling-set.json" "$WORK/linked-siblings.json"
assert 'unsafe sibling prevents creating the entire source set' test ! -e "$WORK/unsafe-sibling-set"

# Exercise real local Git children, including ordinary absorbed administration
# stores. Every successful fixture pins commit objects before mutating checkouts.
assert 'recursive project submodule custody regressions' python3 - "$WORK" "$ROOT" <<'PY'
import base64
import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

WORK, ROOT = map(Path, sys.argv[1:])
MODULE = ROOT / "src/xwin_source.sh"
ENV = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
ENV.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, GIT_TERMINAL_PROMPT="0",
           GIT_TEMPLATE_DIR="", LC_ALL="C")

class ProjectSubmodules(unittest.TestCase):
    def setUp(self):
        self.work = WORK / self._testMethodName
        self.work.mkdir()
        self.project = self.work / "project"
        self.snapshot = self.work / "snapshot"
        self.receipt = self.work / "source.json"
        self.tag = "v1.2.3"

    def git(self, path, *args, data=None, raw=False):
        result = subprocess.run(["git", "-c", "protocol.file.allow=always", "-c", "init.templateDir=",
                                 "-C", str(path), *args], input=data, env=ENV,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        return result.stdout if raw else result.stdout.decode().strip()

    def repository(self, path, primary=False, empty=False):
        path.mkdir(parents=True, exist_ok=True)
        self.git(path, "init", "-q", "-b", "main", "--template=")
        self.git(path, "config", "user.name", "DSR submodule test")
        self.git(path, "config", "user.email", "test@example.invalid")
        if primary:
            self.git(path, "remote", "add", "origin", "https://github.com/owner/demo.git")
            (path / "Cargo.toml").write_text('[package]\nname="demo"\nversion="1.2.3"\n')
            (path / "Cargo.lock").write_text("version = 3\n")
        if not empty:
            (path / "value").write_text("locked " + path.name + "\n")
        return path

    def seal(self, path):
        self.git(path, "add", ".")
        self.git(path, "commit", "--allow-empty", "-qm", "pinned fixture")
        return self.git(path, "rev-parse", "HEAD")

    def fixture(self, escape=False, empty=False):
        leaf = self.repository(self.work / "leaf", empty=empty)
        if escape:
            (leaf / "escape").symlink_to("../value")
        elif not empty:
            (leaf / "link").symlink_to("value")
        self.leaf_sha = self.seal(leaf)
        child = self.repository(self.work / "child")
        self.git(child, "submodule", "add", "-q", str(leaf), "nested")
        self.child_sha = self.seal(child)
        self.repository(self.project, primary=True)
        self.git(self.project, "submodule", "add", "-q", str(child), "vendor/child")
        self.git(self.project, "submodule", "update", "--init", "--recursive", "-q")
        self.sha = self.seal(self.project)
        self.git(self.project, "tag", self.tag)
        self.child = self.project / "vendor/child"
        self.leaf = self.child / "nested"
        self.admin = Path(self.git(self.child, "rev-parse", "--absolute-git-dir"))

    def call(self, function, *args):
        result = subprocess.run(["bash", "-c", 'source "$1"; shift; "$@"', "submodule-test",
                                 str(MODULE), function, *map(str, args)], env=ENV,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        self.assertEqual(result.stdout, b"")
        self.assertNotIn(b"Traceback", result.stderr)
        return result

    def capture(self, expected=0):
        result = self.call("xwin_source_snapshot", self.project, self.sha, self.tag,
                           "owner/demo", self.snapshot, self.receipt)
        self.assertEqual(result.returncode, expected, result.stderr.decode())
        if expected:
            self.assertFalse(self.snapshot.exists())
            self.assertFalse(self.receipt.exists())
            return None
        self.verify()
        return json.loads(self.receipt.read_text())

    def verify(self, expected=0, receipt=None):
        result = self.call("xwin_source_verify", self.snapshot, receipt or self.receipt)
        self.assertEqual(result.returncode, expected, result.stderr.decode())

    def rewritten_flat_receipt(self, original):
        # Build the attacker's substituted tree with real Git, independently
        # of the production tree reconstruction. The staged child files are
        # now ordinary files in that tree, with no authenticated gitlinks.
        store = self.work / "forged-tree.git"
        store.mkdir()
        self.git(store, "init", "--bare", "-q", "-b", "main", "--template=")
        self.git(store, "--git-dir=" + str(store), "--work-tree=" + str(self.snapshot),
                 "add", "--all", "--force")
        tree = self.git(store, "--git-dir=" + str(store), "write-tree")
        files = []
        for path in sorted(self.snapshot.rglob("*")):
            if not path.is_file():
                continue
            raw = path.read_bytes()
            files.append({"path": path.relative_to(self.snapshot).as_posix(),
                          "sha256": hashlib.sha256(raw).hexdigest(), "size_bytes": len(raw),
                          "executable": bool(path.stat().st_mode & 0o111)})
        files.sort(key=lambda row: row["path"])
        proof = copy.deepcopy(original)
        proof.pop("git_commit_object", None)
        proof.pop("submodules", None)
        proof["git_tree"] = tree
        proof["files"] = files
        canonical = (json.dumps(files, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n").encode()
        proof["snapshot_sha256"] = hashlib.sha256(canonical).hexdigest()
        self.assertNotEqual(proof["git_tree"], original["git_tree"])
        self.assertEqual(proof["git_sha"], original["git_sha"])
        self.assertEqual(proof["git_ref"], original["git_ref"])
        return proof

    def test_plain_root_requires_its_exact_raw_commit_authority(self):
        self.repository(self.project, primary=True)
        self.sha = self.seal(self.project)
        self.git(self.project, "tag", self.tag)
        original = self.capture()
        self.assertNotIn("submodules", original)
        self.assertEqual(base64.b64decode(original["git_commit_object"]),
                         self.git(self.project, "cat-file", "commit", self.sha, raw=True))
        # A second real commit keeps exactly the same tree. Accepting its
        # valid object would therefore prove only the tree, not the pin.
        self.git(self.project, "commit", "--allow-empty", "-qm", "same tree, different commit")
        other = self.git(self.project, "rev-parse", "HEAD")
        self.assertNotEqual(other, self.sha)
        self.assertEqual(self.git(self.project, "rev-parse", other + "^{tree}"), original["git_tree"])
        substitute = base64.b64encode(self.git(self.project, "cat-file", "commit", other, raw=True)).decode()
        mutations = {
            "omitted": lambda p: p.pop("git_commit_object"),
            "null": lambda p: p.update(git_commit_object=None),
            "invalid": lambda p: p.update(git_commit_object="Zm9yZ2Vk"),
            "different-valid-commit": lambda p: p.update(git_commit_object=substitute),
        }
        self.project.rename(self.work / "primary-unavailable")
        self.verify()
        for name, mutate in mutations.items():
            with self.subTest(mutation=name):
                proof = copy.deepcopy(original)
                mutate(proof)
                receipt = self.work / (name + ".json")
                receipt.write_text(json.dumps(proof))
                self.verify(7, receipt)
        (self.snapshot / "value").write_text("forged ordinary source bytes\n")
        forged = self.rewritten_flat_receipt(original)
        receipt = self.work / "forged-root-tree.json"
        receipt.write_text(json.dumps(forged))
        self.verify(7, receipt)

    def test_absorbed_nested_children_verify_after_originals_disappear(self):
        self.fixture()
        proof = self.capture()
        child = proof["submodules"][0]
        self.assertEqual((child["path"], child["commit"]), ("vendor/child", self.child_sha))
        self.assertEqual(child["tree"], self.git(self.child, "rev-parse", self.child_sha + "^{tree}"))
        self.assertEqual(child["submodules"][0]["commit"], self.leaf_sha)
        self.assertEqual((self.snapshot / "vendor/child/nested/link").read_text(), "locked leaf\n")
        self.assertFalse((self.snapshot / "vendor/child/nested/link").is_symlink())
        self.assertFalse(any(path.name == ".git" for path in self.snapshot.rglob("*")))
        row = next(row for row in proof["files"] if row["path"] == "vendor/child/nested/link")
        self.assertEqual(row["symlink"]["resolved_path"], "value")
        destination = os.environ.get("DSR_XWIN_SUBMODULE_TEST_RECEIPT")
        if destination:
            Path(destination).write_text(json.dumps(proof))
        for name in ("project", "child", "leaf"):
            (self.work / name).rename(self.work / (name + "-unavailable"))
        self.verify()

    def test_self_contained_child_repository_is_supported(self):
        self.repository(self.project, primary=True)
        child = self.repository(self.project / "child")
        pinned = self.seal(child)
        self.git(self.project, "add", "Cargo.toml", "Cargo.lock", "value")
        self.git(self.project, "update-index", "--add", "--cacheinfo", "160000," + pinned + ",child")
        self.git(self.project, "commit", "-qm", "parent gitlink")
        self.sha = self.git(self.project, "rev-parse", "HEAD")
        self.git(self.project, "tag", self.tag)
        evidence = self.capture()
        self.assertEqual(evidence["submodules"][0]["commit"], pinned)

    def test_mutable_child_head_worktree_and_url_cannot_select_bytes(self):
        self.fixture()
        self.git(self.project, "config", "submodule.vendor/child.ignore", "all")
        self.git(self.child, "config", "user.name", "DSR submodule test")
        self.git(self.child, "config", "user.email", "test@example.invalid")
        (self.child / "value").write_text("new HEAD must not be selected\n")
        advanced = self.seal(self.child)
        self.assertNotEqual(advanced, self.child_sha)
        (self.child / "value").write_text("uncommitted bytes must not be copied\n")
        self.git(self.child, "remote", "set-url", "origin", "https://unreachable.invalid/changed")
        self.assertEqual(self.git(self.project, "status", "--porcelain=v1"), "")
        evidence = self.capture()
        self.assertEqual(evidence["submodules"][0]["commit"], self.child_sha)
        self.assertEqual((self.snapshot / "vendor/child/value").read_text(), "locked child\n")

    def test_missing_pinned_child_commit_is_refused_before_staging(self):
        self.fixture()
        loose = self.admin / "objects" / self.child_sha[:2] / self.child_sha[2:]
        self.assertTrue(loose.is_file())
        loose.rename(self.work / "retained-missing-commit")
        self.capture(4)

    def test_gitlink_to_present_blob_is_refused_as_wrong_object_type(self):
        self.fixture()
        blob = self.git(self.child, "rev-parse", self.child_sha + ":value")
        self.git(self.project, "update-index", "--cacheinfo", "160000," + blob + ",vendor/child")
        self.git(self.project, "commit", "-qm", "wrong object type")
        self.sha = self.git(self.project, "rev-parse", "HEAD")
        self.tag = "v1.2.4"
        self.git(self.project, "tag", self.tag)
        self.capture(4)

    def test_external_administration_pointer_is_refused(self):
        self.fixture()
        (self.child / ".git").write_text("gitdir: " + str(self.work / "child/.git") + "\n")
        self.capture(4)

    def test_linked_administration_store_is_refused(self):
        self.fixture()
        alias = self.admin.parent / "alias"
        alias.symlink_to(self.admin, target_is_directory=True)
        (self.child / ".git").write_text("gitdir: " + str(alias) + "\n")
        self.capture(4)

    def test_alternates_and_configuration_includes_are_refused(self):
        for index, name in enumerate(("alternates", "include")):
            if index:
                self.work = WORK / (self._testMethodName + "-include")
                self.work.mkdir()
                self.project = self.work / "project"
            self.fixture()
            if name == "alternates":
                (self.admin / "objects/info/alternates").write_text(str(self.work / "child/.git/objects") + "\n")
            else:
                self.git(self.child, "config", "include.path", str(self.work / "outside-config"))
            with self.subTest(kind=name):
                self.capture(4)

    def test_child_symlink_cannot_escape_into_parent(self):
        self.fixture(escape=True)
        self.capture(4)

    def test_parent_symlink_cannot_enter_a_child_repository(self):
        self.fixture()
        (self.project / "cross-link").symlink_to("vendor/child/value")
        self.sha = self.seal(self.project)
        self.tag = "v1.2.4"
        self.git(self.project, "tag", self.tag)
        self.capture(4)

    def test_receipt_chain_mutations_and_missing_authority_are_refused(self):
        self.fixture()
        original = self.capture()
        mutations = {
            "root-proof-omitted": lambda p: p.pop("git_commit_object"),
            "children-omitted": lambda p: p.pop("submodules"),
            "entire-proof-omitted": lambda p: (p.pop("git_commit_object"), p.pop("submodules")),
            "empty-children": lambda p: p.update(submodules=[]),
            "commit": lambda p: p["submodules"][0].update(commit="1" * 40),
            "tree": lambda p: p["submodules"][0].update(tree="2" * 40),
            "path": lambda p: p["submodules"][0].update(path="vendor/other"),
            "object": lambda p: p["submodules"][0].update(commit_object="Zm9yZ2Vk"),
            "root-object": lambda p: p.update(git_commit_object="Zm9yZ2Vk"),
            "unknown-field": lambda p: p["submodules"][0].update(head=self.child_sha),
            "duplicate-child": lambda p: p["submodules"].append(copy.deepcopy(p["submodules"][0])),
            "escaping-path": lambda p: p["submodules"][0].update(path="../child"),
            "cycle": lambda p: p["submodules"][0].update(commit=p["git_sha"], commit_object=p["git_commit_object"]),
            "nested-empty-set": lambda p: p["submodules"][0]["submodules"][0].update(submodules=[]),
        }
        for name, mutate in mutations.items():
            with self.subTest(mutation=name):
                proof = copy.deepcopy(original)
                mutate(proof)
                receipt = self.work / (name + ".json")
                receipt.write_text(json.dumps(proof))
                self.verify(7, receipt)

    def test_rewritten_child_bytes_tree_and_receipt_cannot_erase_commit_authority(self):
        self.fixture()
        original = self.capture()
        (self.snapshot / "vendor/child/value").write_text("attacker replacement child source\n")
        self.verify(7)
        forged = self.rewritten_flat_receipt(original)
        receipt = self.work / "forged-without-authority.json"
        receipt.write_text(json.dumps(forged))
        self.verify(7, receipt)
        # Supplying the original commit cannot authorize the substituted
        # flattened tree either, even with fully refreshed file digests.
        forged["git_commit_object"] = original["git_commit_object"]
        receipt = self.work / "forged-with-original-authority.json"
        receipt.write_text(json.dumps(forged))
        self.verify(7, receipt)
        # Replacing the raw commit's tree line changes its object ID, so that
        # apparently self-consistent commit also cannot retain the old pin.
        raw = base64.b64decode(original["git_commit_object"])
        _, suffix = raw.split(b"\n", 1)
        forged["git_commit_object"] = base64.b64encode(
            ("tree " + forged["git_tree"] + "\n").encode() + suffix).decode()
        receipt = self.work / "forged-with-rewritten-authority.json"
        receipt.write_text(json.dumps(forged))
        self.verify(7, receipt)

    def test_child_file_and_empty_directory_drift_are_refused(self):
        self.fixture()
        self.capture()
        path = self.snapshot / "vendor/child/value"
        original = path.read_bytes()
        path.write_text("compiler drift\n")
        self.verify(7)
        path.write_bytes(original)
        (self.snapshot / "vendor/child/untracked-empty").mkdir()
        self.verify(7)

    def test_empty_nested_child_remains_a_pinned_directory(self):
        self.fixture(empty=True)
        proof = self.capture()
        nested = self.snapshot / "vendor/child/nested"
        self.assertTrue(nested.is_dir())
        self.assertEqual(list(nested.iterdir()), [])
        self.assertEqual(proof["submodules"][0]["submodules"][0]["commit"], self.leaf_sha)
        nested.rename(self.work / "retained-empty-child")
        self.verify(7)

    def test_source_set_retains_sibling_submodule_proofs_and_boundaries(self):
        self.fixture()
        sibling = self.project
        sibling_sha = self.sha
        self.git(sibling, "remote", "set-url", "origin", "https://github.com/owner/helper.git")
        primary = self.repository(self.work / "primary", primary=True)
        primary_sha = self.seal(primary)
        self.git(primary, "tag", self.tag)
        plan = self.work / "siblings.json"
        plan.write_text(json.dumps([{"relative_path": "helper", "local_path": str(sibling),
                                    "revision": sibling_sha, "repo": "owner/helper"}]))
        result = self.call("xwin_source_snapshot_set", primary, primary_sha, self.tag, "owner/demo",
                           self.snapshot, self.receipt, plan)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.verify()
        evidence = json.loads(self.receipt.read_text())
        self.assertNotIn("submodules", evidence)
        dependency = evidence["dependencies"][0]
        self.assertEqual(dependency["submodules"][0]["commit"], self.child_sha)
        self.assertIn("git_commit_object", dependency)
        self.assertEqual((self.snapshot / "helper/vendor/child/nested/link").read_text(), "locked leaf\n")
        sibling.rename(self.work / "sibling-unavailable")
        primary.rename(self.work / "primary-unavailable")
        self.verify()
        dependency.pop("submodules")
        dependency.pop("git_commit_object")
        bad = self.work / "sibling-proof-omitted.json"
        bad.write_text(json.dumps(evidence))
        self.verify(7, bad)

    def test_plain_source_set_requires_primary_and_sibling_commit_authority(self):
        self.repository(self.project, primary=True)
        self.sha = self.seal(self.project)
        self.git(self.project, "tag", self.tag)
        sibling = self.repository(self.work / "helper", primary=True)
        self.git(sibling, "remote", "set-url", "origin", "https://github.com/owner/helper.git")
        sibling_sha = self.seal(sibling)
        plan = self.work / "siblings.json"
        plan.write_text(json.dumps([{"relative_path": "helper", "local_path": str(sibling),
                                    "revision": sibling_sha, "repo": "owner/helper"}]))
        result = self.call("xwin_source_snapshot_set", self.project, self.sha, self.tag, "owner/demo",
                           self.snapshot, self.receipt, plan)
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.verify()
        original = json.loads(self.receipt.read_text())
        self.assertNotIn("submodules", original)
        self.assertNotIn("submodules", original["dependencies"][0])
        for name, path, selected, pin in (
                ("primary", self.project, original, self.sha),
                ("sibling", sibling, original["dependencies"][0], sibling_sha)):
            self.assertEqual(base64.b64decode(selected["git_commit_object"]),
                             self.git(path, "cat-file", "commit", pin, raw=True))
            self.git(path, "commit", "--allow-empty", "-qm", "another real commit with the same tree")
            other = self.git(path, "rev-parse", "HEAD")
            self.assertNotEqual(other, pin)
            self.assertEqual(self.git(path, "rev-parse", other + "^{tree}"), selected["git_tree"])
            substitute = base64.b64encode(self.git(path, "cat-file", "commit", other, raw=True)).decode()
            for mutation in ("omitted", "invalid", "different-valid-commit"):
                with self.subTest(repository=name, mutation=mutation):
                    proof = copy.deepcopy(original)
                    identity = proof if name == "primary" else proof["dependencies"][0]
                    if mutation == "omitted":
                        identity.pop("git_commit_object")
                    else:
                        identity["git_commit_object"] = substitute if mutation == "different-valid-commit" else "Zm9yZ2Vk"
                    receipt = self.work / (name + "-" + mutation + ".json")
                    receipt.write_text(json.dumps(proof))
                    self.verify(7, receipt)
        self.project.rename(self.work / "primary-unavailable")
        sibling.rename(self.work / "sibling-unavailable")
        self.verify()

    def test_recursive_depth_is_bounded_on_real_git_children(self):
        self.repository(self.project, primary=True)
        paths = [self.project]
        for _ in range(17):
            paths.append(paths[-1] / "child")
            self.repository(paths[-1])
        child_commit = None
        for path in reversed(paths):
            self.git(path, "add", "value")
            if path == self.project:
                self.git(path, "add", "Cargo.toml", "Cargo.lock")
            if child_commit:
                self.git(path, "update-index", "--add", "--cacheinfo", "160000," + child_commit + ",child")
            self.git(path, "commit", "-qm", "real nested Git boundary")
            child_commit = self.git(path, "rev-parse", "HEAD")
        self.sha = child_commit
        self.git(self.project, "tag", self.tag)
        self.capture(4)
        # The immediate child has exactly sixteen nested repository edges.
        # Give it a primary identity without changing any of its child pins.
        self.project = paths[1]
        self.git(self.project, "remote", "add", "origin", "https://github.com/owner/demo.git")
        (self.project / "Cargo.toml").write_text('[package]\nname="demo"\nversion="1.2.3"\n')
        (self.project / "Cargo.lock").write_text("version = 3\n")
        self.sha = self.seal(self.project)
        self.git(self.project, "tag", self.tag)
        self.capture()

    def test_one_aggregate_budget_is_shared_across_repository_admissions(self):
        self.repository(self.project, primary=True)
        self.sha = self.seal(self.project)
        self.git(self.project, "tag", self.tag)
        other = self.repository(self.work / "other", primary=True)
        other_sha = self.seal(other)
        self.git(other, "tag", self.tag)
        text = MODULE.read_text()
        source = text.split("<<'PY'\n", 1)[1].split("\nPY\n}", 1)[0]
        definitions = source.split('\ntry:\n    mode = sys.argv[1]', 1)[0]
        scope = {}
        exec(compile(definitions, str(MODULE), "exec"), scope)
        budget = {"entries": scope["MAX_ENTRIES"] - 4}
        scope["inspect_project"](str(self.project), self.sha, self.tag, "owner/demo", budget)
        with self.assertRaisesRegex(scope["Rejected"], "aggregate entries limit"):
            scope["inspect_project"](str(other), other_sha, self.tag, "owner/demo", budget)
        budget = {"repositories": scope["MAX_REPOSITORIES"] - 1}
        scope["inspect_project"](str(self.project), self.sha, self.tag, "owner/demo", budget)
        with self.assertRaisesRegex(scope["Rejected"], "aggregate repositories limit"):
            scope["inspect_project"](str(other), other_sha, self.tag, "owner/demo", budget)

suite = unittest.defaultTestLoader.loadTestsFromTestCase(ProjectSubmodules)
result = unittest.TextTestRunner(verbosity=2).run(suite)
sys.exit(0 if result.wasSuccessful() else 1)
PY
cat "$WORK/assert.err" >&2

# The input Git tree itself must not contain an unbound escaping symlink.
ln -s ../outside.rs "$PROJECT/linked-source"
git -C "$PROJECT" add linked-source && git -C "$PROJECT" commit -qm linked || exit 1
LINK_SHA=$(git -C "$PROJECT" rev-parse HEAD)
git -C "$PROJECT" tag v1.2.4
reject 'escaping committed symlinks are rejected before source creation' 4 xwin_source_snapshot "$PROJECT" "$LINK_SHA" v1.2.4 owner/demo "$WORK/linked" "$WORK/linked.json"
assert 'unsafe Git tree left no release snapshot' test ! -e "$WORK/linked"
printf '\nWindows ARM64 source admission: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
