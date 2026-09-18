#!/usr/bin/env bash
# Real local Git clone/commit/push end-to-end checksum sync. GitHub URLs are
# rewritten to bare fixture repositories; only curl/gh responses are fixtures.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODULE="${DSR_CHECKSUM_MODULE:-$ROOT/src/checksum_sync.sh}"
for dependency in git jq sha256sum; do
    command -v "$dependency" >/dev/null || { echo "SKIP: $dependency required"; exit 0; }
done
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/dsr-sync-test.XXXXXXXX") || exit 1
trap 'code=$?; if [[ $code != 0 && ${DSR_TEST_KEEP_TEMP:-0} == 1 ]]; then echo "Fixtures: $TEMP" >&2; else rm -rf -- "$TEMP"; fi' EXIT
export HOME="$TEMP/home" GIT_CONFIG_GLOBAL="$TEMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
export TMPDIR="$TEMP/tmp" DSR_STATE_DIR="$TEMP/state" NO_COLOR=1
mkdir -p "$HOME" "$TMPDIR" "$DSR_STATE_DIR" "$TEMP/remotes" "$TEMP/artifacts" "$TEMP/transports" "$TEMP/http" "$TEMP/results"
git config --file "$GIT_CONFIG_GLOBAL" user.name 'Checksum fixture'
git config --file "$GIT_CONFIG_GLOBAL" user.email 'checksum@example.invalid'
git config --file "$GIT_CONFIG_GLOBAL" url."file://$TEMP/remotes/".insteadOf 'https://github.com/example/'
for name in one two reject; do
    git init -q --bare -b main "$TEMP/remotes/$name.git"
    git init -q -b main "$TEMP/seed-$name"
    printf 'seed\n' > "$TEMP/seed-$name/README.md"
    printf '%064d  old-artifact\n' 0 > "$TEMP/seed-$name/SHA256SUMS.txt"
    git -C "$TEMP/seed-$name" add README.md SHA256SUMS.txt
    git -C "$TEMP/seed-$name" commit -qm initial
    git -C "$TEMP/seed-$name" remote add origin "$TEMP/remotes/$name.git"
    git -C "$TEMP/seed-$name" push -q origin main
 done
printf 'artifact contents\n' > "$TEMP/artifacts/tool-1.2.3-linux-amd64.tar.gz"
ln "$TEMP/artifacts/tool-1.2.3-linux-amd64.tar.gz" "$TEMP/artifacts/tool-linux-amd64.tar.gz"
source "$MODULE" || exit 1
CONTENT=$(checksum_generate "$TEMP/artifacts") || exit 1
printf '%s\n' "$CONTENT" > "$TEMP/good-manifest"
INITIAL=$(git --git-dir="$TEMP/remotes/one.git" rev-parse HEAD)
passed=0 failed=0 status=0 result='' sequence=0
check() {
    local label="$1"; shift
    if "$@"; then passed=$((passed + 1)); printf 'PASS: %s\n' "$label"
    else failed=$((failed + 1)); printf 'FAIL: %s\n' "$label" >&2; fi
}
equal() { [[ "$1" == "$2" ]]; }
run() {
    sequence=$((sequence + 1)); status=0
    result=$("$@" 2> "$TEMP/results/$sequence.err") || status=$?
    printf '%s\n' "$result" > "$TEMP/results/$sequence.json"
}
json_is() { jq -es "$1" <<< "$result" >/dev/null; }
run checksum_sync demo v1.2.3 --json --repo example/one --artifacts-dir "$TEMP/artifacts" --dry-run \
    --target-repo example/one --target-repo example/two --target-repo EXAMPLE/ONE
check 'dry-run succeeds with a complete local release set' equal "$status" 0
check 'dry-run deduplicates target identities without pretending to sync' json_is 'length==1 and .[0].planned==2 and .[0].synced==0 and .[0].dry_run==true'
check 'dry-run does not change a remote branch' equal "$INITIAL" "$(git --git-dir="$TEMP/remotes/one.git" rev-parse HEAD)"
workspace=$(jq -r .workspace <<< "$result")
check 'dry-run creates no target checkouts' test -z "$(find "$workspace" -name .git -print)"
check 'manifest receipt binds the actual normalized bytes' equal "$(jq -r .source.manifest_sha256 <<< "$result")" "$(_cs_sha256 "$workspace/manifest")"
run checksum_sync_json demo 1.2.3 --repo example/one --artifacts-dir "$TEMP/artifacts"
check 'default sync creates a real local checksum commit' equal "$status" 0
check 'local-only sync reports actual update and no push' json_is 'length==1 and .[0].status=="success" and .[0].synced==1 and .[0].results[0].pushed==false'
check 'JSON wrapper retains human diagnostics inside output, not outside JSON' json_is 'length==1 and (.[0].output|contains("workspace retained"))'
checkout=$(jq -r '.results[0].checkout' <<< "$result")
commit=$(jq -r '.results[0].commit' <<< "$result")
check 'unpushed checkout is retained rather than deleted' test -d "$checkout/.git"
check 'retained commit is the checked-out HEAD' equal "$commit" "$(git -C "$checkout" rev-parse HEAD)"
check 'commit contains the complete dual-name manifest' equal "$CONTENT" "$(git -C "$checkout" show HEAD:SHA256SUMS.txt)"
check 'sync commit touches only the checksum path' equal "$(git -C "$checkout" diff-tree --no-commit-id --name-only -r HEAD)" SHA256SUMS.txt
check 'no-push sync leaves remote untouched' equal "$INITIAL" "$(git --git-dir="$TEMP/remotes/one.git" rev-parse HEAD)"
run _cs_update_repo_checksums "$checkout" "$CONTENT" --commit --push
check 'unchanged retry pushes an already-created local commit' equal "$status" 0
check 'unchanged push retry does not create another commit' equal "$commit" "$(git --git-dir="$TEMP/remotes/one.git" rev-parse HEAD)"
check 'retry receipt distinguishes unchanged bytes from a successful push' json_is 'length==1 and .[0].changed==false and .[0].pushed==true'
run checksum_sync_json demo v1.2.3 --repo example/two --manifest "$TEMP/good-manifest" --checksums-file 'evidence/release sums.txt' --push
check 'nested literal manifest path commits and pushes' equal "$status" 0
check 'nested path exists in actual remote commit' equal "$CONTENT" "$(git --git-dir="$TEMP/remotes/two.git" show 'HEAD:evidence/release sums.txt')"
check 'provided manifest is labeled syntax-only input' json_is '.[0].source.kind=="provided_manifest"'
# Unrelated staged work must not be included in a checksum commit.
printf 'user work\n' > "$checkout/README.md"
git -C "$checkout" add README.md
NEW_CONTENT="$(printf '%064d  newer-artifact\n' 1)"
run _cs_update_repo_checksums "$checkout" "$NEW_CONTENT" --commit
check 'checksum-only commit succeeds with unrelated staged work' equal "$status" 0
check 'only checksum file is committed' equal "$(git -C "$checkout" diff-tree --no-commit-id --name-only -r HEAD)" SHA256SUMS.txt
check 'unrelated staged change remains in index' equal "$(git -C "$checkout" diff --cached --name-only)" README.md
check 'unrelated committed README bytes stay unchanged' equal "$(git -C "$checkout" show HEAD:README.md)" seed
# Invalid input cannot touch the checkout, including before git add/commit.
old_head=$(git -C "$checkout" rev-parse HEAD)
old_manifest=$(cat "$checkout/SHA256SUMS.txt")
run _cs_update_repo_checksums "$checkout" '<html>not checksums</html>' --commit
check 'malformed manifest is rejected before repository mutation' equal "$status" 4
check 'malformed input preserves committed HEAD' equal "$old_head" "$(git -C "$checkout" rev-parse HEAD)"
check 'malformed input preserves working file' equal "$old_manifest" "$(cat "$checkout/SHA256SUMS.txt")"
for path in ../escape /tmp/escape .git/config evidence/../../escape .GIT/hooks/evil; do
    run _cs_update_repo_checksums "$checkout" "$CONTENT" --commit --checksums-file "$path"
    check "unsafe destination rejected before write: $path" equal "$status" 4
done
mkdir "$TEMP/outside"
ln -s "$TEMP/outside" "$checkout/linked"
run _cs_update_repo_checksums "$checkout" "$CONTENT" --commit --checksums-file linked/sums.txt
check 'intermediate symlink cannot redirect checksum update' equal "$status" 4
check 'symlink target receives no checksum write' test ! -e "$TEMP/outside/sums.txt"
printf untracked > "$checkout/untracked.txt"
run _cs_update_repo_checksums "$checkout" "$CONTENT" --commit --checksums-file untracked.txt
check 'untracked target is not overwritten' equal "$status" 2
check 'untracked target bytes are preserved' equal "$(cat "$checkout/untracked.txt")" untracked
printf 'user edit\n' >> "$checkout/SHA256SUMS.txt"
run _cs_update_repo_checksums "$checkout" "$CONTENT" --commit
check 'modified checksum target causes an explicit conflict' equal "$status" 2
check 'conflicting target retains user edit' grep -q 'user edit' "$checkout/SHA256SUMS.txt"
# Use clean fresh checkouts for commit failure and ambient Git plumbing tests.
git clone -q "$TEMP/remotes/one.git" "$TEMP/hook-checkout"
printf '#!/bin/sh\nexit 23\n' > "$TEMP/hook-checkout/.git/hooks/pre-commit"
chmod +x "$TEMP/hook-checkout/.git/hooks/pre-commit"
hook_head=$(git -C "$TEMP/hook-checkout" rev-parse HEAD)
run _cs_update_repo_checksums "$TEMP/hook-checkout" "$NEW_CONTENT" --commit --push
check 'real commit hook rejection propagates failure' equal "$status" 1
check 'failed commit cannot be reported or pushed as success' equal "$hook_head" "$(git -C "$TEMP/hook-checkout" rev-parse HEAD)"
check 'failed commit preserves staged diagnostic data' equal "$(git -C "$TEMP/hook-checkout" show :SHA256SUMS.txt)" "$NEW_CONTENT"
git clone -q "$TEMP/remotes/one.git" "$TEMP/ambient-checkout"
GIT_DIR="$TEMP/seed-one/.git" GIT_WORK_TREE="$TEMP/seed-one" GIT_INDEX_FILE="$TEMP/unwanted-index" \
    run _cs_update_repo_checksums "$TEMP/ambient-checkout" "$NEW_CONTENT" --commit
check 'ambient Git plumbing cannot redirect the checksum commit' equal "$status" 0
check 'ambient index destination was never created' test ! -e "$TEMP/unwanted-index"
check 'foreign checkout HEAD did not move' equal "$INITIAL" "$(git -C "$TEMP/seed-one" rev-parse HEAD)"
# Literal Git pathspecs and staged publication errors use real checkout state.
GIT_GLOB_PATHSPECS=1 run _cs_update_repo_checksums "$TEMP/ambient-checkout" "$CONTENT" \
    --commit --checksums-file 'evidence/sums[1].txt'
check 'literal manifest filename is not reinterpreted as a Git glob' equal "$status" 0
check 'literal path reaches the exact committed tree entry' equal "$CONTENT" "$(git -C "$TEMP/ambient-checkout" show 'HEAD:evidence/sums[1].txt')"
prior=$(cat "$TEMP/ambient-checkout/SHA256SUMS.txt")
cp() {
    if [[ "${!#}" == *'/.dsr-checksum-output.'*'/manifest' ]]; then printf partial > "${!#}"; return 1; fi
    command cp "$@"
}
run _cs_update_repo_checksums "$TEMP/ambient-checkout" "$CONTENT" --commit
check 'failed final staging copy cannot report a completed update' equal "$status" 1
check 'failed staging copy preserves old working manifest' equal "$prior" "$(cat "$TEMP/ambient-checkout/SHA256SUMS.txt")"
unset -f cp
mv() { return 1; }
run _cs_update_repo_checksums "$TEMP/ambient-checkout" "$CONTENT" --commit
check 'failed checksum replacement propagates its error' equal "$status" 1
check 'failed checksum replacement does not truncate existing data' equal "$prior" "$(cat "$TEMP/ambient-checkout/SHA256SUMS.txt")"
unset -f mv
# Real non-fast-forward rejection must leave the completed local commit intact.
git clone -q "$TEMP/remotes/one.git" "$TEMP/stale-checkout"
git clone -q "$TEMP/remotes/one.git" "$TEMP/advance-checkout"
printf 'remote advance\n' >> "$TEMP/advance-checkout/README.md"
git -C "$TEMP/advance-checkout" commit -qam advance
git -C "$TEMP/advance-checkout" push -q origin main
advanced=$(git --git-dir="$TEMP/remotes/one.git" rev-parse HEAD)
run _cs_update_repo_checksums "$TEMP/stale-checkout" "$NEW_CONTENT" --commit --push
check 'non-fast-forward push is an explicit failure' equal "$status" 8
check 'remote concurrent commit is never overwritten' equal "$advanced" "$(git --git-dir="$TEMP/remotes/one.git" rev-parse HEAD)"
check 'unpushed checksum commit remains available for recovery' equal "$NEW_CONTENT" "$(git -C "$TEMP/stale-checkout" show HEAD:SHA256SUMS.txt)"
# Partial multi-repository sync: one real push accepted, one hook rejects it.
printf '#!/bin/sh\nexit 1\n' > "$TEMP/remotes/reject.git/hooks/pre-receive"
chmod +x "$TEMP/remotes/reject.git/hooks/pre-receive"
run checksum_sync_json demo v1.2.3 --repo example/one --manifest "$TEMP/good-manifest" --push \
    --target-repo example/one --target-repo example/reject
check 'mixed downstream push results return nonzero' equal "$status" 1
check 'partial status identifies each actual outcome' json_is '.[0].status=="partial" and .[0].synced==1 and .[0].failed==1 and (.[0].results|map(.exit_code))==[0,8]'
rejected_checkout=$(jq -r '.results[1].checkout' <<< "$result")
check 'failed push checkout is retained' test -d "$rejected_checkout/.git"
check 'failed push commit contains the requested manifest' equal "$CONTENT" "$(git -C "$rejected_checkout" show HEAD:SHA256SUMS.txt)"
run checksum_sync_json demo v1.2.3 --repo example/missing --manifest "$TEMP/good-manifest"
check 'failed clone does not proceed to update or success' equal "$status" 1
check 'clone failure is explicit per target' json_is '.[0].status=="error" and .[0].results[0].action=="clone" and .[0].results[0].exit_code==8'
# Network boundaries: real parser consumes bytes produced by fixture transport.
export HTTP_ROOT="$TEMP/http" CALLS="$TEMP/calls" TRANSPORT_MODE=normal GH_MODE=normal
: > "$CALLS"
cat > "$TEMP/transports/curl" <<'CURL'
#!/usr/bin/env bash
url='' output=''
while (($#)); do
    case "$1" in -o) output="$2"; shift 2 ;; https://*) url="$1"; shift ;; *) shift ;; esac
done
printf 'curl %s\n' "$url" >> "$CALLS"
[[ "$TRANSPORT_MODE" != curl-fail ]] || exit 22
name="${url##*/}"
[[ -f "$HTTP_ROOT/$name" && -n "$output" ]] || exit 22
cp "$HTTP_ROOT/$name" "$output"
CURL
cat > "$TEMP/transports/gh" <<'GH'
#!/usr/bin/env bash
printf 'gh host=%s %s\n' "${GH_HOST:-}" "$*" >> "$CALLS"
[[ "$GH_MODE" != fail ]] || exit 1
if [[ "$1 $2" == 'issue create' ]]; then
    printf 'https://github.com/example/review/issues/1\n'; exit 0
fi
[[ "$1 $2" == 'release download' ]] || exit 1
asset='' output=''
while (($#)); do
    case "$1" in --pattern) asset="$2"; shift 2 ;; --output) output="$2"; shift 2 ;; *) shift ;; esac
done
[[ -f "$HTTP_ROOT/$asset" && -n "$output" ]] || exit 1
cp "$HTTP_ROOT/$asset" "$output"
GH
chmod +x "$TEMP/transports/"*
export PATH="$TEMP/transports:$PATH"
printf '%s\n' "$CONTENT" > "$HTTP_ROOT/checksums.sha256"
run checksum_sync_json demo v1.2.3 --repo example/one --dry-run
check 'release manifest download uses actual strict parser' equal "$status" 0
check 'download receipt records selected manifest name and source' json_is '.[0].source.kind=="release_manifest" and .[0].source.asset=="checksums.sha256"'
TRANSPORT_MODE=curl-fail
run checksum_sync_json demo v1.2.3 --repo example/one --dry-run
check 'authenticated transport can recover failed curl acquisition' equal "$status" 0
check 'gh transport explicitly pins the GitHub host' grep -q '^gh host=github.com release download' "$CALLS"
GH_HOST=elsewhere.example run checksum_sync_json demo v1.2.3 --repo example/one --prefer-gh --dry-run
check 'preferred authenticated transport ignores unrelated GH_HOST' equal "$status" 0
TRANSPORT_MODE=normal
for kind in html empty duplicate nul; do
    case "$kind" in
        html) printf '<html>unavailable</html>\n' > "$HTTP_ROOT/checksums.sha256" ;;
        empty) : > "$HTTP_ROOT/checksums.sha256" ;;
        duplicate) printf '%s\n%s\n' "$CONTENT" "$CONTENT" > "$HTTP_ROOT/checksums.sha256" ;;
        nul) printf '%064d  invalid\000name\n' 0 > "$HTTP_ROOT/checksums.sha256" ;;
    esac
    printf '%s\n' "$CONTENT" > "$HTTP_ROOT/SHA256SUMS.txt"
    before=$(wc -l < "$CALLS")
    run checksum_sync_json demo v1.2.3 --repo example/one --dry-run
    check "downloaded invalid manifest cannot become a sync plan: $kind" equal "$status" 4
    check "invalid present manifest cannot fall through to another file: $kind" equal "$((before + 1))" "$(wc -l < "$CALLS")"
    check "invalid manifest has one machine-readable failure: $kind" json_is 'length==1 and .[0].status=="error" and .[0].planned==0'
done
mv "$HTTP_ROOT/checksums.sha256" "$TEMP/invalid-download.saved"
run checksum_sync_json demo v1.2.3 --repo example/one --dry-run
check 'missing generic manifest falls back to SHA256SUMS.txt' equal "$status" 0
check 'selected fallback manifest name is recorded' json_is '.[0].source.asset=="SHA256SUMS.txt"'
GH_MODE=fail TRANSPORT_MODE=curl-fail
run checksum_sync_json demo v1.2.3 --repo example/one --dry-run
check 'all transport failures return missing-release-data status' equal "$status" 7
check 'JSON wrapper propagates failed acquisition instead of returning jq success' json_is '.[0].exit_code==7 and .[0].status=="error"'
GH_MODE=normal TRANSPORT_MODE=normal
run checksum_sync_json demo v1.2.3 --repo example/one --manifest "$TEMP/good-manifest" --external --push
check 'external tool path creates review request instead of committing' equal "$status" 0
check 'review path has no repository checkout and no pushed claim' json_is '.[0].issues_opened==1 and .[0].synced==0 and .[0].results[0].checkout==null and (.[0].results[0]|has("pushed")|not)'
GH_MODE=fail
run checksum_sync_json demo v1.2.3 --repo example/one --manifest "$TEMP/good-manifest" --external
check 'review creation failure is not reported as a successful update' equal "$status" 1
GH_MODE=normal
before=$(wc -l < "$CALLS")
for kind in missing-dir conflicting-inputs traversal-file invalid-repo bad-version missing-option extra-arg unknown-option; do
    args=(demo v1.2.3 --repo example/one)
    case "$kind" in
        missing-dir) args+=(--artifacts-dir "$TEMP/missing") ;;
        conflicting-inputs) args+=(--artifacts-dir "$TEMP/artifacts" --manifest "$TEMP/good-manifest") ;;
        traversal-file) args+=(--checksums-file ../escape) ;;
        invalid-repo) args+=(--target-repo '../bad') ;;
        bad-version) args+=(--version '../bad') ;;
        missing-option) args+=(--target-repo) ;;
        extra-arg) args+=(extra) ;;
        unknown-option) args+=(--not-a-flag) ;;
    esac
    run checksum_sync_json "${args[@]}"
    check "invalid sync input rejected before network: $kind" equal "$status" 4
    check "invalid sync input emits one JSON result: $kind" json_is 'length==1 and .[0].exit_code==4 and .[0].workspace==null'
done
check 'preflight failures make no network requests' equal "$before" "$(wc -l < "$CALLS")"
run bash "$MODULE" sync demo v1.2.3 --json --repo example/one --artifacts-dir "$TEMP/artifacts" --dry-run
check 'standalone sync entry point uses the same pipeline' equal "$status" 0
check 'standalone JSON is one structured result' json_is 'length==1 and .[0].planned==1'
run bash "$MODULE" generate "$TEMP/artifacts"
check 'standalone manifest generator returns the verified release records' equal "$result" "$CONTENT"
run bash "$MODULE" verify "$TEMP/good-manifest" "$TEMP/artifacts" --strict
check 'standalone strict verifier succeeds' equal "$status" 0
check 'standalone verifier stdout stays empty' equal "$result" ''
mkdir -p "$HOME/projects"
ln -s "$HOME/projects" "$TEMP/protected-tmp"
TMPDIR="$TEMP/protected-tmp" run checksum_sync_json demo v1.2.3 --repo example/one --manifest "$TEMP/good-manifest"
check 'symlinked protected temporary root is refused' equal "$status" 4
check 'protected root receives no workspace or wrapper staging' test -z "$(find "$HOME/projects" -mindepth 1 -print)"
check 'all in-repository update staging directories cleaned' test -z "$(find "$TEMP" -name '.dsr-checksum-update.*' -print)"
check 'all final-path staging directories cleaned' test -z "$(find "$TEMP" -name '.dsr-checksum-output.*' -print)"
printf 'Checksum sync pipeline: %s passed, %s failed\n' "$passed" "$failed"
[[ "$failed" == 0 ]]
