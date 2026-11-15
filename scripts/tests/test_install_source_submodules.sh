#!/usr/bin/env bash
# Pinned source installers must build the actual recursive Git dependency
# graph, including Go modules inside gitlinks. Git and Go execute normally;
# only GitHub transport is redirected to private local fixture repositories.
# Compiler-side source/index changes below are explicit fault injections after
# a genuine successful compilation. No release service or production key is used.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SOURCE_MODULE="${DSR_TEST_INSTALL_SOURCE_MODULE:-$ROOT/src/install_source.sh}"
for dependency in git jq go ps tar; do
    command -v "$dependency" >/dev/null 2>&1 || {
        printf 'SKIP: pinned source submodules require %s\n' "$dependency"
        exit 3
    }
done
REAL_GO=$(command -v go)
"$REAL_GO" version >/dev/null 2>&1 || exit 3
# shellcheck source=../../src/install_source.sh
source "$SOURCE_MODULE"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/dsr-source-submodules.XXXXXXXX") || exit 1
WORK=$(cd "$WORK" && pwd -P) || exit 1
printf 'Pinned source submodule fixtures retained at: %s\n' "$WORK"
PASS=0 FAIL=0 STATUS=0 CALLS='' MUTATION='' BUILD_SOURCE=''

check() {
    local label="$1"; shift
    if "$@"; then
        PASS=$((PASS + 1)); printf 'PASS: %s\n' "$label"
    else
        FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$label" >&2
    fi
}
equal() { [[ "$1" == "$2" ]]; }
no_compile() { ! grep -Eq '^(list|build) ' "$CALLS"; }
no_receipt() { [[ ! -s "$WORK/$1.json" && ! -e "$WORK/$1/receipt.json" ]]; }

# A known hosted /proc view can expose host PIDs while Bash sees namespace
# PIDs. Substitute only the watchdog boundary after independently proving
# that discrepancy, retaining real commands, real logs and real exit codes.
# These cases qualify the source graph; watchdog qualification is separate.
_isb_run 3 "$WORK/watchdog-probe.log" printf 'watchdog-ready\n' \
    > "$WORK/watchdog-probe.out" 2> "$WORK/watchdog-probe.err" || STATUS=$?
if ((STATUS != 0)); then
    namespace_pid="$BASHPID" host_pid='' namespace_line='' observed_pid=''
    namespace_pids=()
    if [[ -r /proc/self/stat && -r /proc/self/status ]]; then
        read -r host_pid _ < /proc/self/stat
        while IFS= read -r line; do
            [[ "$line" != NSpid:* ]] || namespace_line="${line#NSpid:}"
        done < /proc/self/status
        observed_pid=$(ps -o pid= -p "$namespace_pid" 2> "$WORK/namespace-probe.err" || true)
        observed_pid="${observed_pid//[[:space:]]/}"
    fi
    read -r -a namespace_pids <<< "$namespace_line"
    if [[ $STATUS -ne 3 || -e "$WORK/watchdog-probe.log" ||
          ${#namespace_pids[@]} -lt 2 || "$host_pid" == "$namespace_pid" ||
          "${namespace_pids[0]:-}" != "$host_pid" ||
          "${namespace_pids[${#namespace_pids[@]}-1]:-}" != "$namespace_pid" ||
          "$observed_pid" == "$namespace_pid" ]]; then
        printf 'FAIL: watchdog failed without independent PID namespace evidence (status %s)\n' "$STATUS" >&2
        exit 1
    fi
    printf 'BOUNDARY: hosted PID namespace requires synchronous real commands with retained logs\n'
    _isb_run() {
        local limit="$1" log="$2"; shift 2
        [[ "$limit" =~ ^[1-9][0-9]{0,4}$ && ! -e "$log" && ! -L "$log" ]] || return 4
        "$@" </dev/null > "$log" 2>&1
    }
fi

export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$WORK/gitconfig"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
export DSR_GH_TOKEN='' GITHUB_TOKEN='' GH_TOKEN=''
export GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local GOTELEMETRY=off GOMAXPROCS=2
export GOCACHE="${DSR_TEST_GO_CACHE:-/tmp/dsr-test-go-submodule-cache}"
gh() { return 1; }
# Reject every non-file Git protocol after URL rewriting. A test cannot make
# an accidental public request even if a source-admission regression occurs.
git config --file "$GIT_CONFIG_GLOBAL" protocol.allow never || exit 1
git config --file "$GIT_CONFIG_GLOBAL" protocol.file.allow always || exit 1
fixture_init() {
    git init -q -b main "$1" &&
        git -C "$1" config user.name 'DSR pinned submodule fixture' &&
        git -C "$1" config user.email 'submodule@example.invalid'
}
fixture_commit() {
    git -c core.hooksPath=/dev/null -C "$1" commit -qm "$2"
}
fixture_url() {
    git config --file "$GIT_CONFIG_GLOBAL" "url.file://$WORK/$2.insteadOf" "https://github.com/example/$1.git"
}

mkdir -p "$WORK/leaf/cmd/leafapp" "$WORK/shared/cmd/childapp" \
    "$WORK/root/deps/shared" "$WORK/hooks" || exit 1
fixture_init "$WORK/leaf" && fixture_init "$WORK/shared" && fixture_init "$WORK/root" || exit 1
fixture_url leaf leaf && fixture_url shared shared && fixture_url root root || exit 1
printf 'module example.invalid/leaf\ngo 1.22\n' > "$WORK/leaf/go.mod"
printf 'package leaf\nconst Message = "leaf-pinned"\n' > "$WORK/leaf/leaf.go"
cat > "$WORK/leaf/cmd/leafapp/main.go" <<'GO'
package main
import ("fmt"; "example.invalid/leaf")
func main() { fmt.Println("leafapp-" + leaf.Message) }
GO
git -C "$WORK/leaf" add . && fixture_commit "$WORK/leaf" 'Pinned leaf dependency' || exit 1
LEAF_PIN=$(git -C "$WORK/leaf" rev-parse HEAD) || exit 1
# The branch deliberately differs from the parent gitlink. Recursive checkout
# must fetch the old reachable object rather than a submodule branch tip.
printf 'package leaf\nconst Message = "wrong-branch-tip"\n' > "$WORK/leaf/leaf.go"
git -C "$WORK/leaf" add leaf.go && fixture_commit "$WORK/leaf" 'Move leaf branch beyond its pin' || exit 1
LEAF_TIP=$(git -C "$WORK/leaf" rev-parse HEAD) || exit 1

cat > "$WORK/shared/go.mod" <<'MOD'
module example.invalid/shared
go 1.22
require example.invalid/leaf v0.0.0
replace example.invalid/leaf => ./leaf
MOD
cat > "$WORK/shared/shared.go" <<'GO'
package shared
import "example.invalid/leaf"
const Message = "shared-" + leaf.Message
GO
cat > "$WORK/shared/cmd/childapp/main.go" <<'GO'
package main
import ("fmt"; "example.invalid/shared")
func main() { fmt.Println("childapp-" + shared.Message) }
GO
cat > "$WORK/shared/.gitmodules" <<'CONFIG'
[submodule "leaf"]
    path = leaf
    url = ../leaf.git
    branch = main
CONFIG
git -C "$WORK/shared" add . &&
    git -C "$WORK/shared" update-index --add --cacheinfo "160000,$LEAF_PIN,leaf" &&
    fixture_commit "$WORK/shared" 'Pinned nested relative submodule' || exit 1
SHARED_PIN=$(git -C "$WORK/shared" rev-parse HEAD) || exit 1
printf '\n// branch-only change\n' >> "$WORK/shared/shared.go"
git -C "$WORK/shared" add shared.go && fixture_commit "$WORK/shared" 'Move shared branch beyond its pin' || exit 1
SHARED_TIP=$(git -C "$WORK/shared" rev-parse HEAD) || exit 1

cat > "$WORK/root/go.mod" <<'MOD'
module example.invalid/app
go 1.22
require (
    example.invalid/shared v0.0.0
    example.invalid/leaf v0.0.0
)
replace example.invalid/shared => ./deps/shared
replace example.invalid/leaf => ./deps/shared/leaf
MOD
cat > "$WORK/root/main.go" <<'GO'
package main
import ("fmt"; "example.invalid/shared")
func main() { fmt.Println("app-" + shared.Message) }
GO
cat > "$WORK/root/.gitmodules" <<'CONFIG'
[submodule "shared"]
    path = deps/shared
    url = https://github.com/example/shared.git
    branch = main
    ignore = all
CONFIG
git -C "$WORK/root" add go.mod main.go .gitmodules &&
    git -C "$WORK/root" update-index --add --cacheinfo "160000,$SHARED_PIN,deps/shared" &&
    fixture_commit "$WORK/root" 'Pinned recursive release source' || exit 1
ROOT_PIN=$(git -C "$WORK/root" rev-parse HEAD) || exit 1
git -C "$WORK/root" tag -a v1.0.0 -m 'Pinned recursive source release' || exit 1

# Any use of ambient hooks or custom update commands would leave evidence.
cat > "$WORK/hooks/post-checkout" <<'HOOK'
#!/usr/bin/env bash
printf 'hook executed\n' >> "$DSR_TEST_SUBMODULE_HOOK_MARKER"
HOOK
chmod +x "$WORK/hooks/post-checkout"
export DSR_TEST_SUBMODULE_HOOK_MARKER="$WORK/hook-executed"
git config --file "$GIT_CONFIG_GLOBAL" core.hooksPath "$WORK/hooks" || exit 1
git config --file "$GIT_CONFIG_GLOBAL" diff.ignoreSubmodules all || exit 1
git config --file "$GIT_CONFIG_GLOBAL" submodule.shared.update \
    '!printf "custom update executed\n" >> "$DSR_TEST_SUBMODULE_HOOK_MARKER"' || exit 1

# Every fault happens only after the real native compiler exits successfully.
# This distinguishes post-build custody refusal from a compilation failure.
go() {
    printf '%s\n' "$*" >> "$CALLS"
    local code=0 child="$BUILD_SOURCE/deps/shared" leaf="$BUILD_SOURCE/deps/shared/leaf" object
    "$REAL_GO" "$@" || code=$?
    if [[ "$1" == build && $code == 0 ]]; then
        printf 'REAL_BUILD_SUCCEEDED\n' >> "$CALLS"
        case "$MUTATION" in
            source) printf '\n// modified during compile\n' >> "$leaf/leaf.go" ;;
            assume-unchanged)
                git -C "$leaf" update-index --assume-unchanged leaf.go || return 91
                printf '\n// hidden modified source\n' >> "$leaf/leaf.go" ;;
            skip-worktree)
                git -C "$leaf" update-index --skip-worktree leaf.go || return 91
                printf '\n// hidden modified source\n' >> "$leaf/leaf.go" ;;
            index)
                object=$(printf 'different index bytes\n' | git -C "$leaf" hash-object -w --stdin) || return 91
                git -C "$leaf" update-index --cacheinfo "100644,$object,leaf.go" || return 91 ;;
            head)
                git -c core.hooksPath=/dev/null -c user.name=Fixture -c user.email=fixture@example.invalid \
                    -C "$child" commit --allow-empty -qm 'Injected HEAD drift after successful compile' || return 91 ;;
            metadata)
                git -C "$BUILD_SOURCE" update-index --assume-unchanged .gitmodules || return 91
                printf '\n# hidden graph change\n' >> "$BUILD_SOURCE/.gitmodules" ;;
            core-worktree)
                mkdir "$leaf/.git/pristine" || return 91
                git -C "$leaf" archive HEAD | tar -x -C "$leaf/.git/pristine" || return 91
                git -C "$leaf" config core.worktree "$leaf/.git/pristine" || return 91
                printf '\n// changed outside redirected worktree\n' >> "$leaf/leaf.go" ;;
            clean-filter)
                printf 'leaf.go filter=hide\n' > "$leaf/.git/info/attributes"
                git -C "$leaf" config filter.hide.clean 'git show HEAD:leaf.go' || return 91
                printf '\n// changed behind clean filter\n' >> "$leaf/leaf.go" ;;
            same-stat)
                cp -p "$leaf/leaf.go" "$leaf/.git/original-leaf.go" || return 91
                printf 'package leaf\nconst Message = "leaf-tamper"\n' > "$leaf/leaf.go"
                touch -r "$leaf/.git/original-leaf.go" "$leaf/leaf.go" || return 91
                [[ $(wc -c < "$leaf/leaf.go") -eq $(wc -c < "$leaf/.git/original-leaf.go") &&
                    ! "$leaf/leaf.go" -nt "$leaf/.git/original-leaf.go" &&
                    ! "$leaf/.git/original-leaf.go" -nt "$leaf/leaf.go" ]] || return 91
                ! cmp -s "$leaf/leaf.go" "$leaf/.git/original-leaf.go" || return 91
                printf 'SAME_SIZE_AND_MTIME_DIFFERENT_BYTES\n' >> "$CALLS" ;;
            untracked)
                mkdir "$leaf/compiler-output" || return 91
                printf 'legitimate compiler cache\n' > "$leaf/compiler-output/cache.bin" ;;
            emulated-link)
                printf 'changed-link-target' > "$BUILD_SOURCE/source-link" ;;
        esac
    fi
    return "$code"
}
run_build() {
    local name="$1" reference="$2" subdir="${3:-.}" binary="${4:-app}"
    CALLS="$WORK/$name.calls"; : > "$CALLS"
    BUILD_SOURCE="$WORK/$name/source"
    STATUS=0
    install_source_build example/root "$reference" go "$binary" "$WORK/$name" \
        --allow-build --subdir "$subdir" --timeout 60 > "$WORK/$name.json" 2> "$WORK/$name.log" || STATUS=$?
}
run_refusal() {
    local name="$1" label="$2" expected="${3:-4}"
    run_build "$name" HEAD
    check "$label" equal "$STATUS" "$expected"
    check "$label before any package resolution or compilation" no_compile
    check "$label without success receipt" no_receipt "$name"
}
set_root_module() {
    local key="$1" value="$2"
    git -C "$WORK/root" config --file .gitmodules "$key" "$value" &&
        git -C "$WORK/root" add .gitmodules && fixture_commit "$WORK/root" "Fixture $key=$value"
}

run_build nested refs/tags/v1.0.0
check 'recursive source graph builds with real Git and Go' equal "$STATUS" 0
check 'native executable runs pinned child and grandchild code' equal \
    "$("$WORK/nested/output/bin/app" 2>/dev/null)" app-shared-leaf-pinned
check 'source receipt binds the selected parent and complete nested graph' jq -e \
    --arg root "$ROOT_PIN" --arg shared "$SHARED_PIN" --arg leaf "$LEAF_PIN" '
    .method == "source" and .signed_release == false and .source_commit == $root and
    (.submodules | sort_by(.path)) == [
        {path:"deps/shared",repository:"example/shared",source_commit:$shared},
        {path:"deps/shared/leaf",repository:"example/leaf",source_commit:$leaf}]
    ' "$WORK/nested.json"
check 'source receipt exposes no local transport paths or credentials' jq -e --arg root "$WORK" \
    '.submodules | tostring | contains($root) | not' "$WORK/nested.json"
check 'child HEAD is the gitlink pin rather than branch tip' equal \
    "$(git -C "$WORK/nested/source/deps/shared" rev-parse HEAD 2>/dev/null)" "$SHARED_PIN"
check 'nested HEAD is the gitlink pin rather than branch tip' equal \
    "$(git -C "$WORK/nested/source/deps/shared/leaf" rev-parse HEAD 2>/dev/null)" "$LEAF_PIN"
check 'upstream child branches are untouched' equal \
    "$(git -C "$WORK/shared" rev-parse HEAD):$(git -C "$WORK/leaf" rev-parse HEAD)" "$SHARED_TIP:$LEAF_TIP"
check 'submodule checkouts do not execute hooks or custom update commands' test ! -e "$DSR_TEST_SUBMODULE_HOOK_MARKER"
check 'successful source receipt is retained exactly' cmp -s "$WORK/nested.json" "$WORK/nested/receipt.json"

run_build child refs/tags/v1.0.0 deps/shared childapp
check 'a Go module inside a gitlink is a supported build root' equal "$STATUS" 0
check 'child module resolves its own pinned nested local replacement' equal \
    "$("$WORK/child/output/bin/childapp" 2>/dev/null)" childapp-shared-leaf-pinned
run_build grandchild refs/tags/v1.0.0 deps/shared/leaf leafapp
check 'a nested gitlink can provide the selected executable' equal "$STATUS" 0
check 'nested module executable uses the pinned source' equal \
    "$("$WORK/grandchild/output/bin/leafapp" 2>/dev/null)" leafapp-leaf-pinned

for MUTATION in source assume-unchanged skip-worktree index head metadata core-worktree clean-filter same-stat; do
    run_build "drift-$MUTATION" refs/tags/v1.0.0
    check "$MUTATION fault occurs after a genuine successful Go compile" grep -qx REAL_BUILD_SUCCEEDED "$CALLS"
    check "$MUTATION drift prevents a pinned-source success receipt" equal "$STATUS" 6
    check "$MUTATION drift leaves stdout and durable receipt unpublished" no_receipt "drift-$MUTATION"
done
check 'same-stat fault changed bytes while preserving source size and mtime' \
    grep -qx SAME_SIZE_AND_MTIME_DIFFERENT_BYTES "$WORK/drift-same-stat.calls"
MUTATION=untracked
run_build untracked refs/tags/v1.0.0
check 'untracked compiler output is permitted' equal "$STATUS" 0
check 'untracked output was genuinely produced in the nested source tree' \
    test -s "$WORK/untracked/source/deps/shared/leaf/compiler-output/cache.bin"
check 'allowed untracked output preserves the pinned executable' equal \
    "$("$WORK/untracked/output/bin/app" 2>/dev/null)" app-shared-leaf-pinned
MUTATION=''

# Raw-byte custody is relative to the acquired checkout, so normal Git EOL
# conversion must remain valid even when the on-disk bytes differ from blobs.
git config --file "$GIT_CONFIG_GLOBAL" core.autocrlf true || exit 1
run_build crlf refs/tags/v1.0.0
git config --file "$GIT_CONFIG_GLOBAL" --unset core.autocrlf || exit 1
check 'normal CRLF checkout builds without weakening source custody' equal "$STATUS" 0
check 'CRLF control genuinely contains converted tracked source bytes' \
    grep -q $'\r' "$WORK/crlf/source/deps/shared/leaf/leaf.go"
check 'CRLF checkout produces the pinned native executable' equal \
    "$("$WORK/crlf/output/bin/app" 2>/dev/null)" app-shared-leaf-pinned
check 'CRLF receipt retains both original dependency commits' jq -e \
    --arg shared "$SHARED_PIN" --arg leaf "$LEAF_PIN" '
    (.submodules | sort_by(.path) | map(.source_commit)) == [$shared,$leaf]
    ' "$WORK/crlf.json"

for invalid in 'file:///tmp/untrusted-source' 'ssh://git@github.com/example/shared.git' \
    'https://github.com.evil.invalid/example/shared.git' 'https://user:secret@github.com/example/shared.git' \
    'https://github.com/example/shared.git?download=1' 'https://github.com/example/../shared.git'; do
    set_root_module submodule.shared.url "$invalid" || exit 1
    seq=$(( ${seq:-0} + 1 ))
    run_refusal "unsafe-url-$seq" "unsafe child URL $seq is refused"
done
set_root_module submodule.shared.url https://github.com/example/shared.git || exit 1
set_root_module submodule.shared.path ../outside || exit 1
run_refusal traversal 'submodule metadata cannot escape its parent checkout'
set_root_module submodule.shared.path .git/injected || exit 1
run_refusal git-path 'submodule metadata cannot enter Git administrative files'
set_root_module submodule.shared.path deps/shared || exit 1

# Duplicate mappings must not let one child source win by iteration order.
git -C "$WORK/root" config --file .gitmodules submodule.other.path deps/shared &&
    git -C "$WORK/root" config --file .gitmodules submodule.other.url https://github.com/example/leaf.git &&
    git -C "$WORK/root" add .gitmodules && fixture_commit "$WORK/root" 'Duplicate submodule path' || exit 1
run_refusal duplicate-path 'duplicate child path ownership is refused'
git -C "$WORK/root" config --file .gitmodules --remove-section submodule.other &&
    git -C "$WORK/root" add .gitmodules && fixture_commit "$WORK/root" 'Restore unique child path' || exit 1

git -C "$WORK/root" update-index --cacheinfo "160000,1111111111111111111111111111111111111111,deps/shared" &&
    fixture_commit "$WORK/root" 'Unavailable child commit' || exit 1
run_refusal missing-pin 'unavailable gitlink commit does not fall back to child branch' 8
git -C "$WORK/root" update-index --cacheinfo "160000,$SHARED_PIN,deps/shared" &&
    fixture_commit "$WORK/root" 'Restore pinned child commit' || exit 1
set_root_module submodule.shared.url ../shared.git || exit 1
run_build parent-relative HEAD
check 'parent-relative GitHub child URL builds successfully' equal "$STATUS" 0
check 'parent-relative URL preserves canonical receipt repository identity' jq -e \
    '.submodules | any(.path == "deps/shared" and .repository == "example/shared")' "$WORK/parent-relative.json"
check 'no hook or custom submodule update executed in any case' test ! -e "$DSR_TEST_SUBMODULE_HOOK_MARKER"

# Git can materialize committed symlinks as ordinary target-text files on
# systems without native symlinks. Preserve that checkout representation while
# rejecting any post-compilation change to its exact target bytes.
ln -s main.go "$WORK/root/source-link" || exit 1
git -C "$WORK/root" add source-link &&
    fixture_commit "$WORK/root" 'Committed source link for emulated checkout' || exit 1
[[ "$(git -C "$WORK/root" ls-tree HEAD -- source-link)" == '120000 blob '* ]] || exit 1
git config --file "$GIT_CONFIG_GLOBAL" core.symlinks false || exit 1
run_build emulated-link HEAD
check 'emulated symlink checkout builds successfully' equal "$STATUS" 0
check 'emulated link is genuinely an ordinary file rather than a symlink' \
    bash -c '[[ -f "$1" && ! -L "$1" ]]' _ "$WORK/emulated-link/source/source-link"
check 'emulated link contains the exact committed target bytes' \
    cmp -s "$WORK/emulated-link/source/source-link" <(printf '%s' main.go)
check 'emulated link checkout preserves the pinned native executable' equal \
    "$("$WORK/emulated-link/output/bin/app" 2>/dev/null)" app-shared-leaf-pinned
MUTATION=emulated-link
run_build drift-emulated-link HEAD
check 'emulated link fault occurs after a genuine successful Go compile' \
    grep -qx REAL_BUILD_SUCCEEDED "$CALLS"
check 'changed emulated link target prevents a pinned-source success receipt' equal "$STATUS" 6
check 'changed emulated link target leaves stdout and durable receipt unpublished' \
    no_receipt drift-emulated-link
MUTATION=''
git config --file "$GIT_CONFIG_GLOBAL" --unset core.symlinks || exit 1

printf 'Pinned source submodule tests: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
