#!/usr/bin/env bash
# Real Git + Go source-build regressions; no network or DSR config required.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/src/install_source.sh"
for tool in git jq go; do command -v "$tool" >/dev/null || { echo "SKIP: $tool required"; exit 0; }; done
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/dsr-source-test.XXXXXXXX") || exit 1
trap 'rm -rf -- "$TEMP"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TEMP/gitconfig" HOME="$TEMP/home"
export GOCACHE="${DSR_TEST_GO_CACHE:-/tmp/dsr-test-go-cache}"
mkdir -p "$HOME" "$TEMP/upstream" "$TEMP/results"
# The transport rewrite is the only remote boundary substitution. init,
# fetch, tag peeling, checkout and compilation use the real tools.
git init -q -b main "$TEMP/upstream"
git -C "$TEMP/upstream" config user.name 'DSR test'
git -C "$TEMP/upstream" config user.email 'test@example.invalid'
cat > "$TEMP/upstream/go.mod" <<'MOD'
module example.invalid/source-fixture

go 1.20
MOD
cat > "$TEMP/upstream/main.go" <<'GO'
package main
import "fmt"
func main() { fmt.Println("source-tag-v1") }
GO
git -C "$TEMP/upstream" add go.mod main.go
git -C "$TEMP/upstream" commit -qm initial
git -C "$TEMP/upstream" tag -a v1.0.0 -m release
PIN=$(git -C "$TEMP/upstream" rev-parse HEAD)
cat > "$TEMP/upstream/main.go" <<'GO'
package main
import "fmt"
func main() { fmt.Println("source-main-v2") }
GO
git -C "$TEMP/upstream" commit -qam next
HEAD_PIN=$(git -C "$TEMP/upstream" rev-parse HEAD)
git config --file "$GIT_CONFIG_GLOBAL" url."file://$TEMP/upstream".insteadOf https://github.com/example/source-fixture.git
passed=0 failed=0 seq=0
check() {
    local label="$1"; shift
    if "$@"; then passed=$((passed + 1)); printf 'PASS: %s\n' "$label"
    else failed=$((failed + 1)); printf 'FAIL: %s\n' "$label" >&2; fi
}
equal() { [[ "$1" == "$2" ]]; }
run_build() {
    local name="$1"; shift
    status=0
    install_source_build example/source-fixture "$@" > "$TEMP/results/$name.json" 2> "$TEMP/results/$name.log" || status=$?
}
reject() {
    local label="$1"; shift
    seq=$((seq + 1))
    local out code=0
    out=$(install_source_build "$@" 2>/dev/null) || code=$?
    check "$label" equal "$code:$out" '4:'
}
run_build tag refs/tags/v1.0.0 go fixture "$TEMP/tag-build" --allow-build --timeout 60
check 'annotated release tag builds successfully' equal "$status" 0
check 'one source receipt document' jq -es 'length == 1 and .[0].method == "source" and .[0].signed_release == false' "$TEMP/results/tag.json"
check 'annotated tag is peeled to the actual commit' equal "$(jq -r .source_commit "$TEMP/results/tag.json")" "$PIN"
PAYLOAD=$(jq -r .path "$TEMP/results/tag.json")
check 'tag build did not silently use main' equal "$("$PAYLOAD")" source-tag-v1
check 'receipt names the actual binary hash' equal "$(jq -r .sha256 "$TEMP/results/tag.json")" "$(_isb_sha256 "$PAYLOAD")"
check 'receipt persisted after successful build' cmp -s "$TEMP/results/tag.json" "$TEMP/tag-build/receipt.json"
check 'compiler version is recorded' jq -e '.compiler | startswith("go version ")' "$TEMP/results/tag.json"
check 'source worktree is detached at the pin' equal "$(git -C "$TEMP/tag-build/source" rev-parse HEAD)" "$PIN"
check 'no detached checkout branch created' bash -c '! git -C "$1" symbolic-ref -q HEAD' _ "$TEMP/tag-build/source"
run_build head HEAD go fixture "$TEMP/head-build" --allow-build --timeout 60
check 'default branch builds at an exact recorded commit' equal "$status" 0
check 'HEAD receipt uses current fetched revision' equal "$(jq -r .source_commit "$TEMP/results/head.json")" "$HEAD_PIN"
check 'default branch executable is current' equal "$("$(jq -r .path "$TEMP/results/head.json")")" source-main-v2
run_build sha "$PIN" go fixture "$TEMP/sha-build" --allow-build --timeout 60
check 'full commit pin is accepted' equal "$status" 0
check 'full pin is not redirected to current branch' equal "$(jq -r .source_commit "$TEMP/results/sha.json")" "$PIN"
run_build missing refs/tags/missing go fixture "$TEMP/missing-build" --allow-build --timeout 10
check 'missing explicit tag fails instead of building HEAD' equal "$status" 8
check 'failed fetch emits no success JSON' test ! -s "$TEMP/results/missing.json"
check 'failed fetch creates no completed receipt' test ! -e "$TEMP/missing-build/receipt.json"
reject 'source execution requires opt-in' example/source-fixture HEAD go fixture "$TEMP/no-consent"
check 'refused consent has no filesystem side effects' test ! -e "$TEMP/no-consent"
reject 'missing positional arguments' example/source-fixture HEAD
for ref in main v1.0.0 '--upload-pack=sh' 'HEAD:refs/heads/write' 'HEAD~1' 'refs/tags/a..b' 'refs/heads/x;echo'; do
    reject "invalid or ambiguous ref: $ref" example/source-fixture "$ref" go fixture "$TEMP/reject-ref" --allow-build
done
for path in ../escape /tmp/escape a/../b a//b .git a/.git/config 'a b' '-flags' 'a/'; do
    reject "unsafe subdir: $path" example/source-fixture HEAD go fixture "$TEMP/reject-path" --allow-build --subdir "$path"
done
reject 'unsafe binary name' example/source-fixture HEAD go '../fixture' "$TEMP/reject-bin" --allow-build
reject 'unsafe repository path' '../example/repo' HEAD go fixture "$TEMP/reject-repo" --allow-build
reject 'unknown argument is not ignored' example/source-fixture HEAD go fixture "$TEMP/reject-opt" --allow-build --wat
reject 'missing flag value is rejected' example/source-fixture HEAD go fixture "$TEMP/reject-opt" --allow-build --timeout
reject 'zero timeout rejected' example/source-fixture HEAD go fixture "$TEMP/reject-timeout" --allow-build --timeout 0
reject 'shell expression timeout rejected' example/source-fixture HEAD go fixture "$TEMP/reject-timeout" --allow-build --timeout '1+1'
reject 'existing destination is not overwritten' example/source-fixture HEAD go fixture "$TEMP/tag-build" --allow-build
ln -s "$TEMP/tag-build" "$TEMP/linked"
reject 'linked destination refused' example/source-fixture HEAD go fixture "$TEMP/linked" --allow-build
# Native Go output is not accidentally cross-compiled by ambient settings.
GOOS=windows GOARCH=arm64 GOFLAGS='-buildmode=archive' run_build env HEAD go fixture "$TEMP/env-build" --allow-build --timeout 60
check 'ambient cross-compile target cannot produce a foreign executable' equal "$status" 0
check 'ambient override build runs on this host' equal "$("$(jq -r .path "$TEMP/results/env.json")")" source-main-v2
# git -C alone is insufficient when GIT_DIR/GIT_WORK_TREE are inherited.
GIT_DIR="$TEMP/upstream/.git" GIT_WORK_TREE="$TEMP/upstream" GIT_INDEX_FILE="$TEMP/unwanted-index" \
    run_build git-env refs/tags/v1.0.0 go fixture "$TEMP/git-env-build" --allow-build --timeout 60
check 'ambient Git plumbing does not redirect source operations' equal "$status" 0
check 'original checkout HEAD is preserved' equal "$(git -C "$TEMP/upstream" rev-parse HEAD)" "$HEAD_PIN"
check 'original checkout remains on main' equal "$(git -C "$TEMP/upstream" symbolic-ref --short HEAD)" main
check 'foreign index path was never created' test ! -e "$TEMP/unwanted-index"
# Nested Go commands use a native argv entry and real compiler.
mkdir -p "$TEMP/upstream/cmd/fixture"
cat > "$TEMP/upstream/cmd/fixture/main.go" <<'GO'
package main
import "fmt"
func main() { fmt.Println("nested-command") }
GO
git -C "$TEMP/upstream" add cmd && git -C "$TEMP/upstream" commit -qm nested
run_build nested HEAD go fixture "$TEMP/nested-build" --allow-build --timeout 60
check 'cmd/binary layout detected' equal "$status" 0
check 'nested command selected instead of root command' equal "$("$(jq -r .path "$TEMP/results/nested.json")")" nested-command
run_build explicit HEAD go fixture "$TEMP/explicit-build" --allow-build --entry . --timeout 60
check 'explicit source entry overrides command layout' equal "$status" 0
check 'explicit root command selected' equal "$("$(jq -r .path "$TEMP/results/explicit.json")")" source-main-v2
# A library may make go build exit zero with an archive at -o. It is not an executable.
mkdir "$TEMP/upstream/library"
printf 'package library\nconst Value = 1\n' > "$TEMP/upstream/library/lib.go"
ln -s . "$TEMP/upstream/linked-source"
git -C "$TEMP/upstream" add library linked-source && git -C "$TEMP/upstream" commit -qm library
run_build library HEAD go fixture "$TEMP/library-build" --allow-build --entry library --timeout 60
check 'Go library is rejected before install' equal "$status" 6
check 'non-executable build has no success receipt' test ! -e "$TEMP/library-build/receipt.json"
run_build symlink HEAD go fixture "$TEMP/symlink-build" --allow-build --subdir linked-source --timeout 60
check 'linked build root cannot escape pinned source selection' equal "$status" 4
# Watchdog tests use real process groups, not a fake timeout executable.
status=0
_isb_run 1 "$TEMP/watchdog.log" bash -c 'sleep 20 & wait' 2> "$TEMP/watchdog.err" || status=$?
check 'portable watchdog reports timeout' equal "$status" 5
check 'portable watchdog leaves a timeout diagnostic' test -f "$TEMP/watchdog.log.timeout"
status=0
_isb_run 5 "$TEMP/fail.log" bash -c 'printf "intentional diagnostic\n"; exit 23' 2> "$TEMP/fail.err" || status=$?
check 'command status survives watchdog' equal "$status" 23
check 'failed command diagnostics retained' grep -q 'intentional diagnostic' "$TEMP/fail.log"
status=0
_isb_run 5 "$TEMP/fail.log" true || status=$?
check 'command log cannot overwrite prior evidence' equal "$status" 4

# Compiler-boundary fixtures cover argv contracts where this test host has
# no Rust or Bun installation. They do not substitute for native builds.
compiler_contracts() (
    local kind="$1" fault="${2:-}" base="$TEMP/$1-${2:-ok}"
    mkdir -p "$base/tree" "$base/output"
    printf '[package]\nname="fixture"\nversion="1.0.0"\n' > "$base/tree/Cargo.toml"
    printf '{"bin":{"fixture":"src/cli.ts"}}\n' > "$base/tree/package.json"
    mkdir "$base/tree/src"
    printf 'console.log("fixture");\n' > "$base/tree/src/cli.ts"
    printf '{}\n' > "$base/tree/bun.lock"
    rustc() { printf 'rustc fixture\nhost: x86_64-test-linux-gnu\n'; }
    cargo() {
        printf '%s\n' "$@" > "$base/cargo.args"
        mkdir -p "$base/output/target/x86_64-test-linux-gnu/release"
        case "$fault" in
            missing) return 0 ;;
            empty) : > "$base/output/target/x86_64-test-linux-gnu/release/fixture" ;;
            link) ln -s "$base/tree/Cargo.toml" "$base/output/target/x86_64-test-linux-gnu/release/fixture" ;;
            *) printf 'fixture executable\n' > "$base/output/target/x86_64-test-linux-gnu/release/fixture" ;;
        esac
    }
    bun() {
        printf '%s\n' "$@" >> "$base/bun.args"
        if [[ "$1" == --version ]]; then printf 'bun fixture\n'
        elif [[ "$1" == build ]]; then printf 'fixture executable\n' > "$base/output/fixture"; fi
    }
    local output code=0
    if [[ "$kind" == rust ]]; then
        output=$(_isb_compile rust "$base/tree" "$base/output" fixture '' app-package 5) || code=$?
    else
        output=$(_isb_compile bun "$base/tree" "$base/output" fixture '' '' 5) || code=$?
    fi
    printf '%s:%s\n' "$code" "$output"
)
result=$(compiler_contracts rust)
check 'Rust compiler boundary returns its selected payload' equal "$result" "0:$TEMP/rust-ok/output/target/x86_64-test-linux-gnu/release/fixture"
check 'Cargo lockfile is enforced' grep -qx -- --locked "$TEMP/rust-ok/cargo.args"
check 'Cargo receives an explicit native target' grep -qx x86_64-test-linux-gnu "$TEMP/rust-ok/cargo.args"
check 'Cargo selects the requested package' grep -qx app-package "$TEMP/rust-ok/cargo.args"
check 'Cargo target directory is private to this build' grep -qx "$TEMP/rust-ok/output/target" "$TEMP/rust-ok/cargo.args"
for fault in missing empty link; do
    check "Cargo success without a usable output is rejected: $fault" equal "$(compiler_contracts rust "$fault" 2>/dev/null)" '6:'
done
result=$(compiler_contracts bun)
check 'Bun resolves the package bin entry' equal "$result" "0:$TEMP/bun-ok/output/fixture"
check 'Bun dependency lockfile is enforced' grep -qx -- --frozen-lockfile "$TEMP/bun-ok/bun.args"
check 'Bun compiles an executable rather than JS output' grep -qx -- --compile "$TEMP/bun-ok/bun.args"
check 'Bun uses its literal selected entry' grep -qx './src/cli.ts' "$TEMP/bun-ok/bun.args"
reject 'irrelevant Rust entry cannot be silently ignored' example/source-fixture HEAD rust fixture "$TEMP/rust-entry" --allow-build --entry ignored
reject 'irrelevant Go package cannot be silently ignored' example/source-fixture HEAD go fixture "$TEMP/go-package" --allow-build --package ignored

# A compiler changing the pinned checkout must not produce a success receipt.
mutated_build() (
    _isb_compile() {
        printf 'changed\n' >> "$2/go.mod"
        printf 'payload\n' > "$3/fixture"
        printf 'fixture\n' > "$3/compiler.log"
        printf '%s/fixture\n' "$3"
    }
    install_source_build example/source-fixture HEAD go fixture "$TEMP/mutated" --allow-build --timeout 10
)
status=0
mutated_build > "$TEMP/mutated.json" 2> "$TEMP/mutated.err" || status=$?
check 'tracked source drift blocks successful attestation' equal "$status" 6
check 'source drift emits no receipt' test ! -s "$TEMP/mutated.json"

# TERM must cancel a running command without altering the caller's traps.
( _isb_run 30 "$TEMP/term.log" bash -c 'echo "$$"; exec sleep 30' ) > "$TEMP/term.out" 2> "$TEMP/term.err" &
runner=$!
for attempt in {1..50}; do [[ ! -f "$TEMP/term.log" ]] || break; sleep 0.02; done
kill -TERM "$runner"
status=0
wait "$runner" || status=$?
check 'TERM cancellation does not report success' bash -c '[[ "$1" != 0 ]]' _ "$status"
sleep 3
command_pid=$(head -1 "$TEMP/term.log")
check 'a killed calling shell does not orphan its compiler' bash -c '! kill -0 "$1" 2>/dev/null' _ "$command_pid"
check 'watchdog does not replace caller EXIT trap' bash -c '[[ "$1" == *"rm -rf"* ]]' _ "$(trap -p EXIT)"
printf 'Source build tests: %s passed, %s failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
