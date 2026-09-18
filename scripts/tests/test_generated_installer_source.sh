#!/usr/bin/env bash
# Exercise the generated installer and embedded source engine together.
# Git checkout/tag peeling and Go compilation are real. Only release HTTP
# transports and selected command failures are fixtures; no network is used.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for dependency in git jq go tar; do
    command -v "$dependency" >/dev/null || { echo "SKIP: $dependency required"; exit 0; }
done
GIT_REAL=$(command -v git)
GO_REAL=$(command -v go)
export GIT_REAL GO_REAL
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/dsr-installer-source.XXXXXXXX") || exit 1
trap 'rm -rf -- "$TEMP"' EXIT
export HOME="$TEMP/home" GIT_CONFIG_GLOBAL="$TEMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
export GOCACHE="${DSR_TEST_GO_CACHE:-/tmp/dsr-installer-source-go-cache}"
mkdir -p "$HOME" "$TEMP/upstream/project/cmd/app" "$TEMP/bin" "$TEMP/config/repos.d" "$TEMP/releases" "$TEMP/results"
export DSR_CONFIG_DIR="$TEMP/config" DSR_INSTALLER_DIR="$TEMP/installers"
export RELEASE_FIXTURES="$TEMP/releases"
"$GIT_REAL" init -q -b main "$TEMP/upstream"
"$GIT_REAL" -C "$TEMP/upstream" config user.name 'DSR test'
"$GIT_REAL" -C "$TEMP/upstream" config user.email 'test@example.invalid'
cat > "$TEMP/upstream/project/go.mod" <<'MOD'
module example.invalid/source-app

go 1.20
MOD
cat > "$TEMP/upstream/project/cmd/app/main.go" <<'GO'
package main
import "fmt"
func main() { fmt.Println("tagged-source-v1") }
GO
"$GIT_REAL" -C "$TEMP/upstream" add project
"$GIT_REAL" -C "$TEMP/upstream" commit -qm initial
"$GIT_REAL" -C "$TEMP/upstream" tag -a v1.0.0 -m release
"$GIT_REAL" -C "$TEMP/upstream" tag v1.0.0+build.1
TAG_PIN=$("$GIT_REAL" -C "$TEMP/upstream" rev-parse HEAD)
cat > "$TEMP/upstream/project/cmd/app/main.go" <<'GO'
package main
import "fmt"
func main() { fmt.Println("default-source-v2") }
GO
"$GIT_REAL" -C "$TEMP/upstream" commit -qam next
HEAD_PIN=$("$GIT_REAL" -C "$TEMP/upstream" rev-parse HEAD)
export TAG_PIN HEAD_PIN FRESHNESS_MODE=normal FRESHNESS_COUNT=1
export SOURCE_UPSTREAM="$TEMP/upstream"
"$GIT_REAL" config --file "$GIT_CONFIG_GLOBAL" url."file://$TEMP/upstream".insteadOf https://github.com/example/source-app.git
cat > "$TEMP/config/repos.d/app.yaml" <<'YAML'
tool_name: app
repo: example/source-app
binary_name: app
language: go
source_subdir: project
source_entry: cmd/app
artifact_naming: '${name}-${version}-${os}-${arch}'
YAML
cat > "$TEMP/releases/app" <<'APP'
#!/usr/bin/env bash
printf 'downloaded-release-v1\n'
APP
chmod +x "$TEMP/releases/app"
os=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$(uname -m)" in x86_64|amd64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) echo 'SKIP: unsupported test host'; exit 0 ;; esac
ASSET="app-1.0.0-$os-$arch.tar.gz"
export ASSET
COPYFILE_DISABLE=1 tar -czf "$TEMP/releases/$ASSET" -C "$TEMP/releases" app
hash=$(sha256sum < "$TEMP/releases/$ASSET" 2>/dev/null || shasum -a 256 < "$TEMP/releases/$ASSET")
printf '%s  %s\n' "${hash%% *}" "$ASSET" > "$TEMP/releases/$ASSET.sha256"
# API-boundary fixtures share response construction across curl and gh. The
# selected commits themselves exist in the real test repository above.
cat > "$TEMP/bin/freshness-response" <<'FRESHNESS'
#!/usr/bin/env bash
set -uo pipefail
endpoint="$1" mode="$FRESHNESS_MODE"
[[ "$mode" != unavailable ]] || exit 22
head="$HEAD_PIN"
[[ "$mode" != identical ]] || head="$TAG_PIN"
case "$endpoint" in
    */commits\?per_page=1)
        case "$mode" in
            bad-head) printf '[{"sha":"not-a-commit"}]\n' ;;
            multiple-heads) printf '[{"sha":"%s"},{"sha":"%s"}]\n' "$head" "$head" ;;
            *) printf '[{"sha":"%s"}]\n' "$head" ;;
        esac
        ;;
    */commits/tags%2Fv1.0.0)
        if [[ "$mode" == bad-tag ]]; then printf '{"sha":null}\n'
        else printf '{"sha":"%s"}\n' "$TAG_PIN"; fi
        ;;
    */compare/*)
        [[ "$endpoint" == *"/$TAG_PIN...$head?per_page=1" ]] || exit 22
        if [[ "$mode" == move-head ]]; then
            printf '\n// change after freshness observation\n' >> "$SOURCE_UPSTREAM/project/cmd/app/main.go"
            "$GIT_REAL" -C "$SOURCE_UPSTREAM" commit -qam 'advance after observation'
        fi
        body=$(jq -nc --arg base "$TAG_PIN" --arg head "$head" --argjson count "$FRESHNESS_COUNT" '
            {base_commit:{sha:$base}, merge_base_commit:{sha:$base}, status:"ahead",
             ahead_by:$count, behind_by:0, total_commits:$count,
             commits:[{sha:$base}]}')
        # The returned page deliberately does not end at head. Metadata count
        # and the separately pinned head, not this page, must drive selection.
        case "$mode" in
            identical) body=$(jq '.status="identical" | .ahead_by=0 | .total_commits=0 | .commits=[]' <<< "$body") ;;
            diverged) body=$(jq '.status="diverged" | .behind_by=1' <<< "$body") ;;
            behind) body=$(jq '.status="behind" | .behind_by=1 | .ahead_by=0 | .total_commits=0' <<< "$body") ;;
            wrong-base) body=$(jq --arg head "$head" '.base_commit.sha=$head' <<< "$body") ;;
            wrong-ancestor) body=$(jq --arg head "$head" '.merge_base_commit.sha=$head' <<< "$body") ;;
            wrong-total) body=$(jq '.total_commits += 1' <<< "$body") ;;
            negative) body=$(jq '.ahead_by=-1 | .total_commits=-1' <<< "$body") ;;
            fractional) body=$(jq '.ahead_by=1.5 | .total_commits=1.5' <<< "$body") ;;
            string-count) body=$(jq '.ahead_by="99" | .total_commits="99"' <<< "$body") ;;
            huge-count) body=$(jq '.ahead_by=1e30 | .total_commits=1e30' <<< "$body") ;;
            missing-count) body=$(jq 'del(.ahead_by)' <<< "$body") ;;
            zero-ahead) body=$(jq '.ahead_by=0 | .total_commits=0' <<< "$body") ;;
            bad-status) body=$(jq '.status="identical"' <<< "$body") ;;
            malformed) body='not json' ;;
            multiple-json) body="$body $body" ;;
        esac
        printf '%s\n' "$body"
        ;;
    *) exit 22 ;;
esac
FRESHNESS
cat > "$TEMP/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -uo pipefail
url='' dest=''
while (($#)); do
    case "$1" in
        -o|--output) dest="$2"; shift 2 ;;
        https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
printf 'curl %s\n' "$url" >> "$CALLS"
case "$url" in
    https://api.github.com/*/commits*|https://api.github.com/*/compare/*)
        [[ "$FRESHNESS_MODE" != private ]] || exit 22
        freshness-response "$url" > "$dest"
        ;;
    */releases/latest)
        [[ "$MODE" != discovery-fail ]] || exit 22
        printf '{"tag_name":"v1.0.0"}\n'
        ;;
    */releases/download/*)
        [[ "$MODE" != download-fail && "$MODE" != discovery-fail ]] || exit 22
        asset="${url##*/}"
        [[ -n "$dest" ]] || exit 22
        if [[ "$MODE" == checksum-bad && "$asset" == *.sha256 ]]; then
            printf '%064d  %s\n' 0 "$ASSET" > "$dest"
        elif [[ "$asset" == *.minisig ]]; then
            printf 'signature fixture\n' > "$dest"
        elif [[ -f "$RELEASE_FIXTURES/$asset" ]]; then
            cp "$RELEASE_FIXTURES/$asset" "$dest"
        else exit 22; fi
        ;;
    *) exit 22 ;;
esac
CURL
cat > "$TEMP/bin/gh" <<'GH'
#!/usr/bin/env bash
printf 'gh %s\n' "$*" >> "$CALLS"
if [[ "$1" == api ]]; then
    freshness-response "${!#}"
    exit $?
fi
exit 1
GH
cat > "$TEMP/bin/git" <<'GIT'
#!/usr/bin/env bash
printf 'git %s\n' "$*" >> "$CALLS"
exec "$GIT_REAL" "$@"
GIT
cat > "$TEMP/bin/go" <<'GOCMD'
#!/usr/bin/env bash
printf 'go %s\n' "$*" >> "$CALLS"
if [[ "${GO_FAILURE:-}" == build && "$1" == build ]]; then
    echo 'intentional compilation failure' >&2
    exit 23
fi
exec "$GO_REAL" "$@"
GOCMD
cat > "$TEMP/bin/minisign" <<'SIGN'
#!/usr/bin/env bash
printf 'minisign %s\n' "$*" >> "$CALLS"
exit 1
SIGN
chmod +x "$TEMP/bin/"*
# The generator runs normally with real YAML or its documented plain-key
# fallback; there is no test-only reimplementation of installer functions.
source "$ROOT/src/install_gen.sh"
source "$ROOT/src/install_source.sh"
INSTALLER=$(install_gen_create app) || exit 1
bash -n "$INSTALLER" || exit 1
export PATH="$TEMP/bin:$PATH"
passed=0 failed=0
check() {
    local label="$1"; shift
    if "$@"; then passed=$((passed + 1)); printf 'PASS: %s\n' "$label"
    else failed=$((failed + 1)); printf 'FAIL: %s\n' "$label" >&2; fi
}
equal() { [[ "$1" == "$2" ]]; }
no_source() { ! grep -Eq '^(git|go) ' "$CALLS"; }
no_http() { ! grep -Eq '^(curl|gh) ' "$CALLS"; }
source_json() {
    jq -es --arg commit "$1" --arg path "$CASE/install/app" '
        length == 1 and (.[0] | .status == "success" and .method == "source" and
        .signed_release == false and .path == $path and
        .source.source_commit == $commit and .source.repository == "example/source-app" and
        .source.signed_release == false and (.source | has("path") | not))' "$CASE/out.json" >/dev/null
}
error_json() { jq -es 'length == 1 and .[0].status == "error"' "$CASE/out.json" >/dev/null; }
run_case() {
    local name="$1"; export MODE="$2"; shift 2
    CASE="$TEMP/results/$name"
    mkdir -p "$CASE/tmp"
    export CALLS="$CASE/calls" TMPDIR="$CASE/tmp"
    if [[ "$name" == symlink-temp ]]; then
        ln -s "$CASE/tmp" "$CASE/tmp-alias"
        TMPDIR="$CASE/tmp-alias"
    fi
    : > "$CALLS"
    status=0
    bash "$INSTALLER" --json --non-interactive --no-skills --cache-dir "$CASE/cache" \
        --dir "$CASE/install" "$@" > "$CASE/out.json" 2> "$CASE/err" || status=$?
}
run_case force-head discovery-fail --from-source --source-timeout 60
check 'forced source works without release discovery' equal "$status" 0
check 'forced source makes no HTTP requests' no_http
check 'forced source receipt binds the default revision' source_json "$HEAD_PIN"
check 'actual source executable runs' equal "$("$CASE/install/app")" default-source-v2
check 'source build does not populate the release cache' test ! -e "$CASE/cache"
check 'successful source temp directory is cleaned' equal "$(find "$CASE/tmp" -mindepth 1 -print)" ''
check 'installed bytes match public receipt' equal "$(jq -r '.source.sha256' "$CASE/out.json")" "$(_isb_sha256 "$CASE/install/app")"
run_case force-tag discovery-fail --from-source --version v1.0.0 --source-timeout 60
check 'explicit source version builds its tag' equal "$status" 0
check 'explicit source version never silently builds HEAD' source_json "$TAG_PIN"
check 'tagged executable runs' equal "$("$CASE/install/app")" tagged-source-v1
run_case build-metadata discovery-fail --from-source --version v1.0.0+build.1 --source-timeout 60
check 'semver build metadata is accepted in source tag pins' equal "$status" 0
check 'build-metadata tag preserves its source commit' source_json "$TAG_PIN"
run_case symlink-temp discovery-fail --from-source --version v1.0.0 --source-timeout 60
check 'symlinked temporary root supports source receipts' equal "$status" 0
check 'physical temp path still binds the selected source' source_json "$TAG_PIN"
check 'physical temp tree is cleaned after success' equal "$(find "$CASE/tmp" -mindepth 1 -print)" ''
run_case pinned discovery-fail --from-source --source-ref "$TAG_PIN" --source-timeout 60
check 'explicit source commit is supported' equal "$status" 0
check 'commit receipt is pinned' source_json "$TAG_PIN"
run_case branch discovery-fail --from-source --source-ref refs/heads/main --source-timeout 60
check 'fully qualified source branch is supported' equal "$status" 0
check 'branch resolves to a recorded commit' source_json "$HEAD_PIN"
run_case latest-fallback discovery-fail --allow-source-build --source-timeout 60
check 'unresolvable latest release can fall back with consent' equal "$status" 0
check 'unresolvable latest builds default branch honestly' source_json "$HEAD_PIN"
check 'unknown release version is not invented' equal "$(jq -r '.version' "$CASE/out.json")" ''
run_case tag-fallback download-fail --allow-source-build --version v1.0.0 --source-timeout 60
check 'missing platform payload falls back to source' equal "$status" 0
check 'download fallback preserves the requested release tag' source_json "$TAG_PIN"
run_case discovered-tag download-fail --allow-source-build --source-timeout 60
check 'discovered version also pins fallback to its tag' equal "$status" 0
check 'discovered-version fallback never switches to HEAD' source_json "$TAG_PIN"
run_case release good --allow-source-build --version v1.0.0
check 'working release remains first choice' equal "$status" 0
check 'working release never invokes Git/compiler' no_source
check 'release is not mislabeled as source' jq -e '.status == "success" and (has("source") | not)' "$CASE/out.json"
check 'release binary is used' equal "$("$CASE/install/app")" downloaded-release-v1
run_case no-consent download-fail --version v1.0.0 --yes
check '--yes does not authorize source code execution' equal "$status" 1
check 'no-consent failure never invokes source' no_source
check 'no-consent failure emits one JSON object' error_json
run_case no-release-consent discovery-fail --yes
check 'failed discovery without consent does not build' equal "$status" 1
check 'failed discovery without consent has no Git/compiler calls' no_source
run_case checksum checksum-bad --allow-source-build --version v1.0.0
check 'bad release checksum is fatal even with source consent' equal "$status" 1
check 'checksum failure cannot downgrade into a source build' no_source
check 'checksum failure installs nothing' test ! -e "$CASE/install/app"
check 'checksum failure emits one JSON error' error_json
# A configured key does not pretend to sign locally compiled code, but on the
# release path a signature failure is always fatal, even with fallback consent.
printf 'minisign_pubkey: RWFIXTURE\n' >> "$TEMP/config/repos.d/app.yaml"
INSTALLER=$(install_gen_create app) || exit 1
run_case signature good --allow-source-build --version v1.0.0
check 'failed configured signature prevents fallback' equal "$status" 1
check 'signature failure does not invoke source' no_source
check 'signature failure leaves destination absent' test ! -e "$CASE/install/app"
run_case explicit-unsigned discovery-fail --from-source --version v1.0.0 --source-timeout 60
check 'explicit local source build is separate from configured release signing' equal "$status" 0
check 'local source never claims configured release signature' source_json "$TAG_PIN"
for options in offline required source-ref-conflict ref-without-source bad-ref bad-timeout missing-timeout invalid-version; do
    case "$options" in
        offline) args=(--from-source --offline --version v1.0.0) ;;
        required) args=(--allow-source-build --require-signatures --version v1.0.0) ;;
        source-ref-conflict) args=(--from-source --source-ref HEAD --version v1.0.0) ;;
        ref-without-source) args=(--source-ref HEAD --allow-source-build) ;;
        bad-ref) args=(--from-source --source-ref main) ;;
        bad-timeout) args=(--from-source --source-timeout '1+1') ;;
        missing-timeout) args=(--from-source --source-timeout) ;;
        invalid-version) args=(--from-source --version '../bad') ;;
    esac
    run_case "$options" good "${args[@]}"
    check "invalid source policy/argument rejected: $options" equal "$status" 4
    check "invalid invocation emits one JSON error: $options" error_json
    check "invalid invocation installs nothing: $options" test ! -e "$CASE/install/app"
done
run_case missing-tag download-fail --allow-source-build --version v9.9.9 --source-timeout 60
check 'missing requested tag never silently falls back to HEAD' equal "$status" 8
check 'missing tag has one error JSON' error_json
check 'missing tag cannot install' test ! -e "$CASE/install/app"
check 'failed source checkout retains diagnostics' test -n "$(find "$CASE/tmp" -name fetch.log -print)"
check 'failure reports retained diagnostics path' grep -q 'diagnostics retained at:' "$CASE/err"
export GO_FAILURE=build
run_case compile-fail discovery-fail --from-source --source-timeout 60
unset GO_FAILURE
check 'compiler failure survives installer routing' equal "$status" 6
check 'compiler failure has one JSON error' error_json
check 'compiler failure installs nothing' test ! -e "$CASE/install/app"
check 'compiler diagnostics retained' test -n "$(find "$CASE/tmp" -name build.log -print)"
# Source updates must obey the existing installer's replacement policy.
run_case overwrite-refused discovery-fail --from-source --source-timeout 60
prior=$(_isb_sha256 "$CASE/install/app")
status=0
bash "$INSTALLER" --json --non-interactive --no-skills --dir "$CASE/install" --from-source \
    --version v1.0.0 --source-timeout 60 > "$CASE/second.json" 2> "$CASE/second.err" || status=$?
check 'source upgrade requires overwrite permission' equal "$status" 1
check 'refused source upgrade preserves installed bytes' equal "$prior" "$(_isb_sha256 "$CASE/install/app")"
status=0
bash "$INSTALLER" --json --non-interactive --no-skills --dir "$CASE/install" --from-source --yes \
    --version v1.0.0 --source-timeout 60 > "$CASE/third.json" 2> "$CASE/third.err" || status=$?
check 'authorized source replacement succeeds' equal "$status" 0
check 'replacement installs selected revision' equal "$("$CASE/install/app")" tagged-source-v1

# Opt-in latest-release freshness policy is evaluated AFTER integrity checks.
# Remove the signing fixture to exercise ordinary verified-release delivery.
cat > "$TEMP/config/repos.d/app.yaml" <<'YAML'
tool_name: app
repo: example/source-app
binary_name: app
language: go
source_subdir: project
source_entry: cmd/app
artifact_naming: '${name}-${version}-${os}-${arch}'
YAML
INSTALLER=$(install_gen_create app) || exit 1
run_case freshness-boundary good --allow-source-build --source-if-stale 1
check 'release exactly at threshold stays release-first' equal "$status" 0
check 'fresh comparison does not invoke compiler' no_source
check 'fresh decision retains both immutable pins and distance' jq -e \
    --arg base "$TAG_PIN" --arg head "$HEAD_PIN" \
    '.freshness.status == "fresh" and .freshness.release_commit == $base and
     .freshness.head_commit == $head and .freshness.commits_behind == 1 and .freshness.threshold == 1' "$CASE/out.json"
run_case freshness-stale good --allow-source-build --source-if-stale 0 --source-timeout 60
check 'release over threshold builds the observed default revision' equal "$status" 0
check 'stale source receipt binds the observed commit' source_json "$HEAD_PIN"
check 'source is not mislabeled with the stale release version' equal "$(jq -r '.version' "$CASE/out.json")" ''
check 'stale release identity is retained separately' jq -e \
    '.freshness.status == "stale" and .freshness.release_version == "v1.0.0"' "$CASE/out.json"
check 'stale source does not populate release cache' test ! -e "$CASE/cache"
FRESHNESS_MODE=identical
run_case freshness-identical good --allow-source-build --source-if-stale 0
check 'identical revisions are fresh even with zero threshold' equal "$status" 0
check 'identical revisions have zero distance' jq -e '.freshness.status == "fresh" and .freshness.commits_behind == 0' "$CASE/out.json"
check 'identical comparison does not compile' no_source
for mode in unavailable bad-head multiple-heads bad-tag diverged behind wrong-base wrong-ancestor wrong-total \
    negative fractional string-count huge-count missing-count zero-ahead bad-status malformed multiple-json; do
    FRESHNESS_MODE="$mode"
    run_case "freshness-$mode" good --allow-source-build --source-if-stale 0
    check "unknown freshness keeps verified release: $mode" equal "$status" 0
    check "invalid freshness cannot authorize compilation: $mode" no_source
    check "unknown decision is explicit in JSON: $mode" jq -e '.freshness.status == "unknown" and (has("source") | not)' "$CASE/out.json"
done
FRESHNESS_MODE=private
GH_HOST=unrelated.example run_case freshness-private good --prefer-gh --allow-source-build --source-if-stale 1
check 'authenticated gh can provide private-repo freshness metadata' equal "$status" 0
check 'gh metadata transport is pinned to github.com' grep -q '^gh api --hostname github.com --method GET' "$CALLS"
check 'private comparison returns a fresh decision' jq -e '.freshness.status == "fresh"' "$CASE/out.json"
FRESHNESS_MODE=normal FRESHNESS_COUNT=1001
run_case freshness-large good --allow-source-build --source-if-stale 10 --source-timeout 60
check 'large comparison count is not truncated to page length' equal "$status" 0
check 'large comparison preserves full count' jq -e '.freshness.commits_behind == 1001 and .freshness.status == "stale"' "$CASE/out.json"
check 'last commit in page is not mistaken for head' source_json "$HEAD_PIN"
FRESHNESS_COUNT=1
run_case stale-integrity checksum-bad --allow-source-build --source-if-stale 0
check 'staleness policy cannot bypass bad checksum' equal "$status" 1
check 'staleness is not checked before artifact integrity' bash -c '! grep -Eq "/commits|/compare/" "$1"' _ "$CALLS"
check 'stale checksum failure does not compile' no_source
for policy in no-consent explicit-version forced-source negative fraction leading-zero too-large missing; do
    case "$policy" in
        no-consent) args=(--source-if-stale 0 --yes) ;;
        explicit-version) args=(--source-if-stale 0 --allow-source-build --version v1.0.0) ;;
        forced-source) args=(--source-if-stale 0 --from-source) ;;
        negative) args=(--source-if-stale -1 --allow-source-build) ;;
        fraction) args=(--source-if-stale 0.5 --allow-source-build) ;;
        leading-zero) args=(--source-if-stale 01 --allow-source-build) ;;
        too-large) args=(--source-if-stale 1000000 --allow-source-build) ;;
        missing) args=(--allow-source-build --source-if-stale) ;;
    esac
    run_case "stale-policy-$policy" good "${args[@]}"
    check "invalid stale policy rejected: $policy" equal "$status" 4
    check "invalid stale policy has no network calls: $policy" no_http
done
FRESHNESS_MODE=move-head
run_case freshness-racing-head good --allow-source-build --source-if-stale 0 --source-timeout 60
check 'moving default branch does not change the selected source revision' equal "$status" 0
check 'head race builds the original observed pin' source_json "$HEAD_PIN"
check 'race fixture really advanced the branch' test "$("$GIT_REAL" -C "$SOURCE_UPSTREAM" rev-parse HEAD)" != "$HEAD_PIN"

# Invalid embedded source config must not clobber an existing generated file.
original=$(_isb_sha256 "$INSTALLER")
printf 'source_package: bad-package\n' >> "$TEMP/config/repos.d/app.yaml"
status=0
install_gen_create app > "$TEMP/bad-generation.out" 2> "$TEMP/bad-generation.err" || status=$?
check 'inapplicable Cargo package is rejected for Go' equal "$status" 4
check 'invalid source config preserves previous installer' equal "$original" "$(_isb_sha256 "$INSTALLER")"
printf 'Generated installer source routing: %s passed, %s failed\n' "$passed" "$failed"
[[ "$failed" == 0 ]]
