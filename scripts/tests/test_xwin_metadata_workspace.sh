#!/usr/bin/env bash
# Genuine Cargo metadata and host compilation for the xwin release selector.
# Windows-filtered metadata is checked; this test does not link Windows output.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
for dependency in cargo rustc jq python3 rg; do
    command -v "$dependency" >/dev/null 2>&1 || {
        printf 'SKIP: xwin workspace selection requires %s\n' "$dependency"
        exit 0
    }
done
# shellcheck source=../../src/xwin_source.sh
source "$ROOT/src/xwin_source.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/dsr-xwin-workspace.XXXXXXXX") || exit 1
printf 'Fixtures: %s\n' "$WORK"
printf 'BOUNDARY: genuine Windows-filtered Cargo metadata and Linux compilation; no Windows linkage proof\n'
mkdir -p "$WORK/project/src" "$WORK/project/helper/src" "$WORK/project/worker/src" "$WORK/cargo" || exit 1
export CARGO_HOME="$WORK/cargo" CARGO_NET_OFFLINE=true
export RUSTUP_AUTO_INSTALL=0 RCH_DISABLED=1 RCH_CARGO_WRAPPER_BYPASS=1
PASS=0 FAIL=0 STATUS=0
check() {
    local label="$1"; shift
    if "$@"; then PASS=$((PASS + 1)); printf 'PASS: %s\n' "$label"
    else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$label" >&2; fi
}
equal() { [[ "$1" == "$2" ]]; }
select_bins() {
    local name="$1" primary="$2" package="$3" binaries="$4" version="${5:-1.2.3}"
    STATUS=0
    xwin_source_metadata "$WORK/metadata.json" "$WORK/project" "$primary" "$package" \
        "$WORK/$name.graph.json" "$version" '' "$binaries" \
        > "$WORK/$name.selection.json" 2> "$WORK/$name.log" || STATUS=$?
}
reject_bins() {
    local name="$1" diagnostic="$2"; shift 2
    select_bins "$name" "$@"
    check "$name refuses the inadmissible selection" equal "$STATUS" 7
    check "$name preserves the selection diagnostic" rg -q -- "$diagnostic" "$WORK/$name.log"
    check "$name emits no admitted graph or receipt" test ! -s "$WORK/$name.selection.json"
    check "$name creates no canonical graph" test ! -e "$WORK/$name.graph.json"
}
cat > "$WORK/project/Cargo.toml" <<'TOML'
[package]
name = "family-package"
version = "1.2.3"
edition = "2021"
[workspace]
members = ["helper", "worker"]
default-members = ["."]
resolver = "2"
[[bin]]
name = "xwin-family"
path = "src/main.rs"
[[bin]]
name = "xwin-local"
path = "src/local.rs"
TOML
printf 'fn main() { println!("primary-package"); }\n' > "$WORK/project/src/main.rs"
printf 'fn main() { println!("local-package"); }\n' > "$WORK/project/src/local.rs"
cat > "$WORK/project/helper/Cargo.toml" <<'TOML'
[package]
name = "helper-package"
version = "1.2.3"
edition = "2021"
[features]
default = ["publish"]
publish = []
[[bin]]
name = "xwin-helper"
path = "src/main.rs"
required-features = ["publish"]
TOML
printf 'fn main() { println!("helper-package"); }\n' > "$WORK/project/helper/src/main.rs"
cat > "$WORK/project/worker/Cargo.toml" <<'TOML'
[package]
name = "worker-package"
version = "1.2.3"
edition = "2021"
[features]
hidden = []
[[bin]]
name = "xwin-worker"
path = "src/main.rs"
[[bin]]
name = "xwin-hidden"
path = "src/hidden.rs"
required-features = ["hidden"]
TOML
printf 'fn main() { println!("worker-package"); }\n' > "$WORK/project/worker/src/main.rs"
printf 'fn main() { println!("hidden-package"); }\n' > "$WORK/project/worker/src/hidden.rs"
cargo generate-lockfile --offline --manifest-path "$WORK/project/Cargo.toml" > "$WORK/lock.log" 2>&1 || exit 1
cargo metadata --locked --offline --format-version 1 --filter-platform aarch64-pc-windows-msvc \
    --manifest-path "$WORK/project/Cargo.toml" > "$WORK/metadata.json" 2> "$WORK/metadata.log" || exit 1
check 'real metadata distinguishes all members from the one default member' jq -e \
    '(.workspace_members | length) == 3 and (.workspace_default_members | length) == 1' "$WORK/metadata.json"

# Prove Cargo itself admits this explicit package/bin family before asking the
# selector. These are exactly the package arguments the xwin runner emits.
STATUS=0
cargo build --release --locked --offline --manifest-path "$WORK/project/Cargo.toml" \
    --target-dir "$WORK/host-target" --message-format=json \
    --bin xwin-family --bin xwin-helper --bin xwin-worker \
    --package family-package --package helper-package --package worker-package \
    > "$WORK/build.messages.jsonl" 2> "$WORK/build.log" || STATUS=$?
check 'genuine Cargo compiles the complete explicitly selected package family' equal "$STATUS" 0
for member in family helper worker; do
    case "$member" in family) expected='primary-package' ;; *) expected="$member-package" ;; esac
    check "$member executable contains its selected package implementation" equal \
        "$("$WORK/host-target/release/xwin-$member" 2>/dev/null)" "$expected"
done
check 'unselected same-package binary is not compiled' test ! -e "$WORK/host-target/release/xwin-local"

select_bins complete xwin-family '' '["xwin-family","xwin-helper","xwin-worker"]'
check 'explicit family spans non-default workspace packages' equal "$STATUS" 0
if ((STATUS != 0)); then
    cat "$WORK/complete.log" >&2
    printf '%s passed, %s failed\n' "$PASS" "$FAIL"
    exit 1
fi
check 'receipt keeps declared binary order and exact package providers' jq -e \
    '[.binaries[] | [.binary,.package]] == [["xwin-family","family-package"],["xwin-helper","helper-package"],["xwin-worker","worker-package"]]' \
    "$WORK/complete.selection.json"
check 'default-enabled required features remain attached to the selected provider' jq -e \
    '.binaries[1].features == ["default","publish"]' "$WORK/complete.selection.json"
check 'selected package identities, source files and features match real compiler messages' \
    python3 - "$WORK/complete.selection.json" "$WORK/build.messages.jsonl" "$WORK/project" <<'PY'
import json
from pathlib import Path
import sys
selection = json.loads(Path(sys.argv[1]).read_text())
messages = [json.loads(line) for line in Path(sys.argv[2]).read_text().splitlines()]
artifacts = [m for m in messages if m.get("reason") == "compiler-artifact" and m.get("executable")]
assert len(artifacts) == len(selection["binaries"])
assert [m["success"] for m in messages if m.get("reason") == "build-finished"] == [True]
for selected in selection["binaries"]:
    matches = [m for m in artifacts if m["target"]["name"] == selected["binary"]]
    assert len(matches) == 1
    actual = matches[0]
    assert actual["package_id"] == selected["package_id"]
    assert Path(actual["target"]["src_path"]) == Path(sys.argv[3]) / selected["binary_source"]
    assert sorted(actual["features"]) == selected["features"]
    assert actual["profile"]["test"] is False
PY

select_bins nondefault xwin-helper '' '["xwin-helper"]'
check 'an explicitly named singleton can select a non-default package' equal "$STATUS" 0
select_bins default-primary xwin-family '' '["xwin-family"]'
check 'legacy singleton selection still admits the unique default-member binary' equal "$STATUS" 0
select_bins restricted xwin-family family-package '["xwin-family","xwin-local"]'
check 'explicit package selection still admits its complete local family' equal "$STATUS" 0
reject_bins package-restricted 'missing or ambiguous: xwin-helper' \
    xwin-family family-package '["xwin-family","xwin-helper"]'
reject_bins missing 'missing or ambiguous: nonexistent' xwin-family '' '["xwin-family","nonexistent"]'
reject_bins inactive-feature 'requires inactive features' xwin-family '' '["xwin-family","xwin-hidden"]'
reject_bins wrong-version 'differs from the release tag' xwin-family '' '["xwin-family"]' 9.9.9

# Add a second provider outside default-members using real Cargo metadata.
# Default membership must never silently break an explicitly named ambiguity.
mkdir -p "$WORK/project/shadow/src" || exit 1
cat > "$WORK/project/shadow/Cargo.toml" <<'TOML'
[package]
name = "shadow-package"
version = "1.2.3"
edition = "2021"
[[bin]]
name = "xwin-family"
path = "src/main.rs"
TOML
printf 'fn main() { println!("shadow-package"); }\n' > "$WORK/project/shadow/src/main.rs"
# Replacing this fixture manifest only changes explicit workspace membership.
cat > "$WORK/project/Cargo.toml" <<'TOML'
[package]
name = "family-package"
version = "1.2.3"
edition = "2021"
[workspace]
members = ["helper", "worker", "shadow"]
default-members = ["."]
resolver = "2"
[[bin]]
name = "xwin-family"
path = "src/main.rs"
[[bin]]
name = "xwin-local"
path = "src/local.rs"
TOML
cargo generate-lockfile --offline --manifest-path "$WORK/project/Cargo.toml" > "$WORK/shadow-lock.log" 2>&1 || exit 1
cargo metadata --locked --offline --format-version 1 --filter-platform aarch64-pc-windows-msvc \
    --manifest-path "$WORK/project/Cargo.toml" > "$WORK/metadata.json" 2> "$WORK/shadow-metadata.log" || exit 1
reject_bins ambiguous 'missing or ambiguous: xwin-family' xwin-family '' '["xwin-family"]'
select_bins disambiguated xwin-family shadow-package '["xwin-family"]'
check 'explicit package disambiguates an otherwise colliding binary' equal "$STATUS" 0
check 'disambiguated receipt names the non-default provider' jq -e \
    '.package == "shadow-package" and .binary_source == "shadow/src/main.rs"' "$WORK/disambiguated.selection.json"
STATUS=0
cargo build --release --locked --offline --manifest-path "$WORK/project/Cargo.toml" \
    --target-dir "$WORK/shadow-target" --bin xwin-family --package shadow-package \
    > "$WORK/shadow-build.log" 2>&1 || STATUS=$?
check 'genuine Cargo builds the explicitly disambiguated provider' equal "$STATUS" 0
check 'explicit package selection produces the requested provider bytes' equal \
    "$("$WORK/shadow-target/release/xwin-family" 2>/dev/null)" shadow-package
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
((FAIL == 0))
