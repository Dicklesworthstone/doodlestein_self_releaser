#!/usr/bin/env bash
# Saved freshness/source safeguards rebased onto the existing installer routing.
# Real Git history, tag peeling and Go builds; HTTP and Rust proxy boundaries
# are fixtures. Exercise the generated script, not copied installer functions.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for tool in git jq go tar; do
    command -v "$tool" >/dev/null || { echo "SKIP: $tool required"; exit 0; }
done
REAL_GIT=$(command -v git); REAL_GO=$(command -v go)
export REAL_GIT REAL_GO
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/dsr-installer-freshness.XXXXXXXX") || exit 1
trap 'rm -rf -- "$TEMP"' EXIT
export HOME="$TEMP/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TEMP/gitconfig"
export GOCACHE="${DSR_TEST_GO_CACHE:-$TEMP/gocache}" GOPROXY=off GOSUMDB=off
mkdir -p "$HOME" "$TEMP/config/repos.d" "$TEMP/bin" "$TEMP/upstream" "$TEMP/release" "$TEMP/results"
export DSR_CONFIG_DIR="$TEMP/config" DSR_INSTALLER_DIR="$TEMP/installers"
export TEST_GIT_LOG="$TEMP/git.log" TEST_HTTP_LOG="$TEMP/http.log" TEST_GO_LOG="$TEMP/go.log"
export TEST_RELEASE_DIR="$TEMP/release" TEST_DELIVERY=valid TEST_LATEST=v1.0.0
export TEST_UPSTREAM="$TEMP/upstream" TEST_METADATA_FAULT='' TEST_COMPARISON_FAULT='' TEST_ADVANCE_ON_COMPARE=0
"$REAL_GIT" init -q -b main "$TEMP/upstream"
"$REAL_GIT" -C "$TEMP/upstream" config user.name 'DSR test'
"$REAL_GIT" -C "$TEMP/upstream" config user.email 'test@example.invalid'
printf 'module example.invalid/demo\n\ngo 1.20\n' > "$TEMP/upstream/go.mod"
cat > "$TEMP/upstream/main.go" <<'GO'
package main
import "fmt"
func main() { fmt.Println("tag-source-v1") }
GO
"$REAL_GIT" -C "$TEMP/upstream" add .
"$REAL_GIT" -C "$TEMP/upstream" commit -qm initial
"$REAL_GIT" -C "$TEMP/upstream" tag -a v1.0.0 -m release
"$REAL_GIT" -C "$TEMP/upstream" tag v1.0.0+build.1
TAG_PIN=$("$REAL_GIT" -C "$TEMP/upstream" rev-parse HEAD)
cat > "$TEMP/upstream/main.go" <<'GO'
package main
import "fmt"
func main() { fmt.Println("head-source-v2") }
GO
"$REAL_GIT" -C "$TEMP/upstream" commit -qam next
HEAD_PIN=$("$REAL_GIT" -C "$TEMP/upstream" rev-parse HEAD)
export TEST_TAG_PIN="$TAG_PIN" TEST_HEAD_PIN="$HEAD_PIN"
"$REAL_GIT" config --file "$GIT_CONFIG_GLOBAL" url."file://$TEMP/upstream".insteadOf https://github.com/example/demo.git
cat > "$TEMP/bin/git" <<'BIN'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_GIT_LOG"
exec "$REAL_GIT" "$@"
BIN
cat > "$TEMP/bin/go" <<'BIN'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_GO_LOG"
exec "$REAL_GO" "$@"
BIN
cat > "$TEMP/bin/curl" <<'BIN'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$TEST_HTTP_LOG"
dest='' url=''
while (($#)); do
    case "$1" in
        -o) dest="$2"; shift 2 ;;
        https:*) url="$1"; shift ;;
        *) shift ;;
    esac
done
emit_json() { if [[ -n "$dest" ]]; then cat > "$dest"; else cat; fi; }
if [[ "$url" == https://api.github.com/*/releases/latest ]]; then
    [[ "$TEST_LATEST" != unavailable ]] || exit 22
    printf '{"tag_name":"%s"}\n' "$TEST_LATEST"
    exit 0
fi
if [[ "$url" == https://api.github.com/*/commits\?* ]]; then
    case "$TEST_METADATA_FAULT" in
        unavailable) exit 22 ;;
        malformed) printf 'not-json\n' | emit_json; exit 0 ;;
        multiple) printf '[] []\n' | emit_json; exit 0 ;;
        missing) printf '[{}]\n' | emit_json; exit 0 ;;
        control) jq -nc --arg sha "$TEST_HEAD_PIN" '[{sha:($sha + "\n")}]' | emit_json; exit 0 ;;
    esac
    jq -nc --arg sha "$TEST_HEAD_PIN" '[{sha:$sha}]' | emit_json; exit 0
fi
if [[ "$url" == https://api.github.com/*/commits/tags%2F* ]]; then
    if [[ "$TEST_METADATA_FAULT" == base-control ]]; then
        jq -nc --arg sha "$TEST_TAG_PIN" '{sha:($sha + "\n")}' | emit_json
    else
        jq -nc --arg sha "$TEST_TAG_PIN" '{sha:$sha}' | emit_json
    fi
    exit 0
fi
if [[ "$url" == https://api.github.com/*/compare/* ]]; then
    pair="${url##*/}"; pair="${pair%%\?*}"
    base="${pair%%...*}"; head="${pair#*...}"
    [[ "$base" =~ ^[0-9a-f]{40}$ && "$head" =~ ^[0-9a-f]{40}$ ]] || exit 22
    ahead=$("$REAL_GIT" -C "$TEST_UPSTREAM" rev-list --count "$base..$head") || exit 22
    behind=$("$REAL_GIT" -C "$TEST_UPSTREAM" rev-list --count "$head..$base") || exit 22
    merge=$("$REAL_GIT" -C "$TEST_UPSTREAM" merge-base "$base" "$head") || exit 22
    state=ahead; [[ "$base" != "$head" ]] || state=identical
    # Real graph counts, but only one list entry to model API pagination.
    response=$(jq -nc --arg base "$base" --arg head "$head" --arg merge "$merge" \
        --arg state "$state" --argjson ahead "$ahead" --argjson behind "$behind" \
        '{base_commit:{sha:$base},merge_base_commit:{sha:$merge},status:$state,
          ahead_by:$ahead,behind_by:$behind,total_commits:$ahead,commits:[{sha:$head}]}')
    case "$TEST_COMPARISON_FAULT" in
        diverged) response=$(jq '.status="diverged" | .behind_by=2' <<< "$response") ;;
        behind) response=$(jq '.status="behind" | .ahead_by=0 | .behind_by=2' <<< "$response") ;;
        wrong-base) response=$(jq --arg sha "$head" '.base_commit.sha=$sha' <<< "$response") ;;
        wrong-merge) response=$(jq --arg sha "$head" '.merge_base_commit.sha=$sha' <<< "$response") ;;
        wrong-total) response=$(jq '.total_commits+=1' <<< "$response") ;;
        negative) response=$(jq '.ahead_by=-1 | .total_commits=-1' <<< "$response") ;;
        fractional) response=$(jq '.ahead_by=10.5 | .total_commits=10.5' <<< "$response") ;;
        string) response=$(jq '.ahead_by="12" | .total_commits="12"' <<< "$response") ;;
        empty) response='{}' ;;
    esac
    if [[ "$TEST_ADVANCE_ON_COMPARE" == 1 ]]; then
        printf 'package main\nimport "fmt"\nfunc main() { fmt.Println("uninspected-head") }\n' > "$TEST_UPSTREAM/main.go"
        "$REAL_GIT" -C "$TEST_UPSTREAM" add main.go
        "$REAL_GIT" -C "$TEST_UPSTREAM" commit -qm 'move head after assessment'
    fi
    printf '%s\n' "$response" | emit_json; exit 0
fi
[[ "$url" == */releases/download/* && "$TEST_DELIVERY" != missing ]] || exit 22
name="${url##*/}"
case "$name" in
    *.tar.gz) cp "$TEST_RELEASE_DIR/payload.tar.gz" "$dest" ;;
    *.sha256)
        if [[ "$TEST_DELIVERY" == corrupt ]]; then printf '%064d\n' 0 > "$dest"
        else cat "$TEST_RELEASE_DIR/hash" > "$dest"; fi ;;
    *) exit 22 ;;
esac
BIN
cat > "$TEMP/bin/gh" <<'BIN'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$TEST_HTTP_LOG"
exit 1
BIN
chmod +x "$TEMP/bin/"*
export PATH="$TEMP/bin:$PATH"
printf '#!/bin/sh\nprintf "verified-release-v1\\n"\n' > "$TEMP/release/demo"
chmod +x "$TEMP/release/demo"
tar -czf "$TEMP/release/payload.tar.gz" -C "$TEMP/release" demo
hash=$(sha256sum < "$TEMP/release/payload.tar.gz" 2>/dev/null || shasum -a 256 < "$TEMP/release/payload.tar.gz")
printf '%s\n' "${hash%% *}" > "$TEMP/release/hash"
source "$ROOT/src/install_gen.sh"
source "$ROOT/src/install_source.sh"
cat > "$TEMP/config/repos.d/demo.yaml" <<'YAML'
tool_name: demo
repo: example/demo
binary_name: demo
language: go
YAML
INSTALLER=$(install_gen_create demo) || exit 1
passed=0 failed=0
check() {
    local label="$1"; shift
    if "$@"; then passed=$((passed + 1)); printf 'PASS: %s\n' "$label"
    else failed=$((failed + 1)); printf 'FAIL: %s\n' "$label" >&2; fi
}
equal() { [[ "$1" == "$2" ]]; }
run_install() {
    local name="$1"; shift
    STATUS=0
    : > "$TEST_GIT_LOG"; : > "$TEST_HTTP_LOG"; : > "$TEST_GO_LOG"
    bash "$INSTALLER" --json --no-skills --non-interactive --dir "$TEMP/out-$name" \
        --cache-dir "$TEMP/cache-$name" "$@" > "$TEMP/results/$name.json" 2> "$TEMP/results/$name.log" || STATUS=$?
}
check 'generated script has valid Bash syntax' bash -n "$INSTALLER"
run_install plus --from-source --allow-build --version v1.0.0+build.1 --build-timeout 60
check 'saved CLI names work alongside current source flags' equal "$STATUS" 0
check 'semver metadata selects exact tag, not HEAD' equal "$(jq -r .source.source_commit "$TEMP/results/plus.json")" "$TAG_PIN"
check 'existing nested provenance shape is retained' jq -es 'length == 1 and .[0].source.signed_release == false and .[0].method == "source"' "$TEMP/results/plus.json"
run_install fresh --prefer-source-if-stale --allow-source-build --stale-threshold 1
check 'exact freshness threshold retains release' equal "$STATUS" 0
check 'fresh release avoids source compiler' test ! -s "$TEST_GO_LOG"
check 'freshness records the real graph count' jq -e '.freshness.commits_behind == 1 and .freshness.status == "fresh"' "$TEMP/results/fresh.json"
run_install canonical --source-if-stale 1 --allow-source-build
check 'canonical freshness flag keeps existing release-first behavior' equal "$STATUS" 0
check 'both freshness spellings retain the same receipt contract' jq -e '.freshness.status == "fresh" and .freshness.threshold == 1' "$TEMP/results/canonical.json"
run_install stale --prefer-source-if-stale --allow-build --stale-threshold 0 --build-timeout 60
check 'stale latest release selects source' equal "$STATUS" 0
check 'stale routing builds the assessed commit' equal "$(jq -r .source.source_commit "$TEMP/results/stale.json")" "$HEAD_PIN"
check 'new source is not labeled as old release version' jq -e '.version == "" and .freshness.release_version == "v1.0.0"' "$TEMP/results/stale.json"
check 'stale receipt hash matches installed source' equal "$(jq -r .source.sha256 "$TEMP/results/stale.json")" "$(_isb_sha256 "$TEMP/out-stale/demo")"
check 'stale source installs newer executable' equal "$("$TEMP/out-stale/demo")" head-source-v2
check 'source outputs stay outside release cache' test ! -e "$TEMP/cache-stale"
TEST_HEAD_PIN="$TAG_PIN" run_install identical --prefer-source-if-stale --allow-build --stale-threshold 0
check 'identical source and release retained as fresh' equal "$STATUS" 0
check 'identical comparison does not compile' test ! -s "$TEST_GO_LOG"
check 'identical evidence reports zero commits behind' jq -e '.freshness.commits_behind == 0 and .freshness.status == "fresh"' "$TEMP/results/identical.json"
for fault in unavailable malformed multiple missing control base-control; do
    TEST_METADATA_FAULT="$fault" run_install "metadata-$fault" --prefer-source-if-stale --allow-build --stale-threshold 0
    check "unknown metadata retains verified release: $fault" equal "$STATUS" 0
    check "unknown metadata does not compile: $fault" test ! -s "$TEST_GO_LOG"
    check "invalid metadata is explicitly unknown: $fault" jq -e '.freshness.status == "unknown"' "$TEMP/results/metadata-$fault.json"
done
for fault in diverged behind wrong-base wrong-merge wrong-total negative fractional string empty; do
    TEST_COMPARISON_FAULT="$fault" run_install "compare-$fault" --prefer-source-if-stale --allow-build --stale-threshold 0
    check "untrustworthy comparison retains release: $fault" equal "$STATUS" 0
    check "untrustworthy comparison never compiles: $fault" test ! -s "$TEST_GO_LOG"
done
run_install private-metadata --prefer-gh --prefer-source-if-stale --allow-build --stale-threshold 1
check 'metadata transport fallback remains usable' equal "$STATUS" 0
check 'gh metadata transport attempted when preferred' grep -q '^gh api ' "$TEST_HTTP_LOG"
TEST_DELIVERY=corrupt run_install corrupt-fresh --prefer-source-if-stale --allow-build --stale-threshold 1
check 'fresh release with invalid checksum remains fatal' equal "$STATUS" 1
check 'freshness does not bypass failed integrity' test ! -s "$TEST_GO_LOG"
check 'bad checksum is rejected before any freshness query' bash -c '! grep -Eq "/commits|/compare/" "$1"' _ "$TEST_HTTP_LOG"
check 'bad fresh-release bytes are not installed' test ! -e "$TEMP/out-corrupt-fresh/demo"
run_install stale-no-consent --prefer-source-if-stale --yes
check 'freshness preference still needs build consent' equal "$STATUS" 4
check 'missing freshness consent makes no network call' test ! -s "$TEST_HTTP_LOG"
for conflict in --offline --require-signatures --from-source; do
    run_install "stale-conflict-$passed" --prefer-source-if-stale --allow-build "$conflict"
    check "stale preference rejects conflicting policy: $conflict" equal "$STATUS" 4
    check "stale policy conflict is pre-network: $conflict" test ! -s "$TEST_HTTP_LOG"
done
run_install stale-version --prefer-source-if-stale --allow-build --version v1.0.0
check 'explicit version cannot be overridden by freshness preference' equal "$STATUS" 4
run_install unused-threshold --stale-threshold 5
check 'unused threshold does not silently alter routing' equal "$STATUS" 4
run_install mixed-threshold --prefer-source-if-stale --allow-build --source-if-stale 0
check 'mixed freshness flags cannot silently override threshold' equal "$STATUS" 4
run_install reversed-mixed-threshold --source-if-stale 0 --allow-build --prefer-source-if-stale
check 'mixed freshness flags are rejected in either order' equal "$STATUS" 4
run_install reordered-threshold --stale-threshold 1 --allow-build --prefer-source-if-stale
check 'separate threshold works before the preference flag' equal "$STATUS" 0
for limit in 01 -1 '1+1' 1000000; do
    run_install "threshold-$passed" --prefer-source-if-stale --allow-build --stale-threshold "$limit"
    check "invalid freshness threshold rejected: $limit" equal "$STATUS" 4
done
# More than ten real commits, despite a one-entry API page.
for unused in {1..11}; do "$REAL_GIT" -C "$TEMP/upstream" commit --allow-empty -qm history; done
TEST_HEAD_PIN=$("$REAL_GIT" -C "$TEMP/upstream" rev-parse HEAD)
run_install paged --prefer-source-if-stale --allow-build --build-timeout 60
check 'default ten-commit threshold detects stale history' equal "$STATUS" 0
check 'paginated list length does not replace aggregate graph count' jq -e '.method == "source" and .freshness.commits_behind == 12' "$TEMP/results/paged.json"
inspected="$TEST_HEAD_PIN"
TEST_ADVANCE_ON_COMPARE=1 run_install moving --prefer-source-if-stale --allow-build --build-timeout 60
check 'source selection survives subsequent default-branch movement' equal "$STATUS" 0
check 'built SHA equals inspected SHA, not later HEAD' equal "$(jq -r .source.source_commit "$TEMP/results/moving.json")" "$inspected"
check 'new uninspected branch content was not built' equal "$("$TEMP/out-moving/demo")" head-source-v2
check 'test actually moved upstream after comparison' test "$("$REAL_GIT" -C "$TEMP/upstream" rev-parse HEAD)" != "$inspected"
printf 'minisign_pubkey: RWfixturekey\n' >> "$TEMP/config/repos.d/demo.yaml"
INSTALLER=$(install_gen_create demo) || exit 1
printf '#!/bin/sh\nexit 1\n' > "$TEMP/bin/minisign"
chmod +x "$TEMP/bin/minisign"
run_install signed-stale --prefer-source-if-stale --allow-build
check 'configured signing key requires release signature before stale fallback' equal "$STATUS" 1
check 'missing signature prevents source compilation' test ! -s "$TEST_GO_LOG"
check 'missing signature prevents freshness queries' bash -c '! grep -Eq "/commits|/compare/" "$1"' _ "$TEST_HTTP_LOG"
# Preserve current main's explicitly opted-in unsigned source mode and receipt.
run_install explicit-signed --from-source --version v1.0.0 --source-timeout 60
check 'explicit source remains separate from configured release signing' equal "$STATUS" 0
check 'explicit source emits one complete result without temporary path' jq -es 'length == 1 and .[0].status == "success" and (.[0].source | has("path") | not)' "$TEMP/results/explicit-signed.json"
check 'explicit source keeps its exact tag and unsigned provenance' jq -e --arg pin "$TAG_PIN" '.signed_release == false and .source.source_commit == $pin' "$TEMP/results/explicit-signed.json"
# Rust proxy fixtures observe the environment passed by the real embedded
# source engine. They do not claim native Rust compilation was performed.
printf '[package]\nname="demo"\nversion="1.0.0"\n' > "$TEMP/upstream/Cargo.toml"
"$REAL_GIT" -C "$TEMP/upstream" add Cargo.toml
"$REAL_GIT" -C "$TEMP/upstream" commit -qm 'Rust compiler boundary fixture'
export TEST_RUST_ENV="$TEMP/rust.env"
cat > "$TEMP/bin/rustc" <<'BIN'
#!/usr/bin/env bash
printf 'rustc=%s\n' "${RUSTUP_AUTO_INSTALL:-unset}" >> "$TEST_RUST_ENV"
[[ "${RUSTUP_AUTO_INSTALL:-}" == 0 ]] || exit 23
printf 'rustc fixture\nhost: x86_64-unknown-linux-gnu\n'
BIN
cat > "$TEMP/bin/cargo" <<'BIN'
#!/usr/bin/env bash
printf 'cargo=%s\n' "${RUSTUP_AUTO_INSTALL:-unset}" >> "$TEST_RUST_ENV"
[[ "${RUSTUP_AUTO_INSTALL:-}" == 0 ]] || exit 23
output='' target='' binary=''
while (($#)); do
    case "$1" in
        --target-dir) output="$2"; shift 2 ;;
        --target) target="$2"; shift 2 ;;
        --bin) binary="$2"; shift 2 ;;
        *) shift ;;
    esac
done
[[ -n "$output" && -n "$target" && -n "$binary" ]] || exit 23
mkdir -p "$output/$target/release"
printf '#!/bin/sh\necho fixture-rust-payload\n' > "$output/$target/release/$binary"
BIN
chmod +x "$TEMP/bin/rustc" "$TEMP/bin/cargo"
cat > "$TEMP/config/repos.d/rust-demo.yaml" <<'YAML'
tool_name: demo
repo: example/demo
binary_name: demo
language: rust
YAML
INSTALLER=$(install_gen_create rust-demo) || exit 1
RUSTUP_AUTO_INSTALL=1 run_install rust-env --from-source --allow-build --build-timeout 60
check 'generated Rust installer reaches compiler boundary' equal "$STATUS" 0
check 'rustc proxy cannot implicitly install a toolchain' grep -qx 'rustc=0' "$TEST_RUST_ENV"
check 'cargo proxy cannot implicitly install a toolchain' grep -qx 'cargo=0' "$TEST_RUST_ENV"
check 'Rust fixture still uses nested source provenance' jq -e '.method == "source" and .source.language == "rust" and .signed_release == false' "$TEMP/results/rust-env.json"
printf 'Generated installer freshness: %s passed, %s failed\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
