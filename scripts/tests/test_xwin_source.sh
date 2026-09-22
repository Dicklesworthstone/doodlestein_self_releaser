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
# The input Git tree itself must not contain an unbound symlink/submodule.
ln -s src/main.rs "$PROJECT/linked-source"
git -C "$PROJECT" add linked-source && git -C "$PROJECT" commit -qm linked || exit 1
LINK_SHA=$(git -C "$PROJECT" rev-parse HEAD)
git -C "$PROJECT" tag v1.2.4
reject 'committed symlinks are rejected before source creation' 4 xwin_source_snapshot "$PROJECT" "$LINK_SHA" v1.2.4 owner/demo "$WORK/linked" "$WORK/linked.json"
assert 'unsafe Git tree left no release snapshot' test ! -e "$WORK/linked"
printf '\nWindows ARM64 source admission: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
