#!/usr/bin/env bash
# Pinned source installers must build the actual recursive Git dependency
# graph, including Go modules inside gitlinks. Git and Go execute normally;
# only GitHub transport is redirected to private local fixture repositories.
# Acquisition faults use real Git filters and files; compiler-side source/index
# changes occur after a genuine successful compilation. No release service or
# production key is used.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SOURCE_MODULE="${DSR_TEST_INSTALL_SOURCE_MODULE:-$ROOT/src/install_source.sh}"
TEST_MODE="${1:-}"
[[ $# -eq 0 || ( $# -eq 1 && ( "$TEST_MODE" == --shipped-only || "$TEST_MODE" == --admission-only ) ) ]] || {
    printf 'Usage: %s [--shipped-only|--admission-only]\n' "$0" >&2
    exit 4
}
dependencies=(git jq go ps tar cmp)
[[ "$TEST_MODE" != --admission-only ]] || dependencies=(git jq cmp)
[[ "$TEST_MODE" != --shipped-only ]] || dependencies+=(python3)
for dependency in "${dependencies[@]}"; do
    command -v "$dependency" >/dev/null 2>&1 || {
        printf 'SKIP: pinned source submodules require %s\n' "$dependency"
        exit 3
    }
done
REAL_GO=''
if [[ "$TEST_MODE" != --admission-only ]]; then
    REAL_GO=$(command -v go)
    "$REAL_GO" version >/dev/null 2>&1 || exit 3
fi
# shellcheck source=../../src/install_source.sh
source "$SOURCE_MODULE"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/dsr-source-submodules.XXXXXXXX") || exit 1
WORK=$(cd "$WORK" && pwd -P) || exit 1
printf 'Pinned source submodule fixtures retained at: %s\n' "$WORK"
PASS=0 FAIL=0 STATUS=0 CALLS='' MUTATION='' BUILD_SOURCE=''
WATCHDOG_ADAPTED=false

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

# This entrypoint also runs against DSR_TEST_INSTALL_SOURCE_MODULE from a frozen
# checkout. It proves acquisition/admission, independently of native compilers
# and the watchdog; a passing post-build drift check cannot substitute for it.
test_source_admission() (
    local PASS=0 FAIL=0 STATUS=0 base="$WORK/admission" pin graph digest path index
    local expected observed
    mkdir -p "$base/upstream/fixtures" || return 1
    export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$base/gitconfig"
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
    unset GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
    export DSR_GH_TOKEN='' GITHUB_TOKEN='' GH_TOKEN=''
    gh() { return 1; }
    git config --file "$GIT_CONFIG_GLOBAL" protocol.allow never &&
        git config --file "$GIT_CONFIG_GLOBAL" protocol.file.allow always &&
        git config --file "$GIT_CONFIG_GLOBAL" "url.file://$base/upstream.insteadOf" \
            https://github.com/example/source-admission.git || return 1
    git init -q -b main "$base/upstream" &&
        git -C "$base/upstream" config user.name 'DSR source admission fixture' &&
        git -C "$base/upstream" config user.email 'source@example.invalid' || return 1
    printf 'module example.invalid/source-admission\ngo 1.22\n' > "$base/upstream/go.mod"
    printf 'package main\nimport "fmt"\nfunc main() { fmt.Println("REVIEWED_SOURCE") }\n' > "$base/upstream/main.go"
    printf 'main.go filter=fixture\n*.txt text eol=crlf\nidentity.txt ident\n' > "$base/upstream/.gitattributes"
    printf 'source $Id$\n' > "$base/upstream/identity.txt"
    printf 'injected.go\n' > "$base/upstream/.gitignore"
    # More than one hash batch, with ordinary names and NUL-framed unusual
    # names that also require legitimate Git text conversion on checkout.
    for index in {1..129}; do
        printf -v path 'fixtures/%03d.data' "$index"
        printf 'reviewed fixture %s\n' "$index" > "$base/upstream/$path"
    done
    for path in 'space name.txt' $'tab\tname.txt' $'line\nname.txt'; do
        printf 'committed text\n' > "$base/upstream/$path"
    done
    printf 'last committed source\n' > "$base/upstream/zz-last.data"
    ln -s main.go "$base/upstream/source-link" &&
        ln -s $'main.go\n' "$base/upstream/newline-link" &&
        git -C "$base/upstream" add . &&
        git -c core.hooksPath=/dev/null -C "$base/upstream" commit -qm 'Pin acquisition source' || return 1
    pin=$(git -C "$base/upstream" rev-parse HEAD) || return 1
    admission_checkout() {
        local label="$1"
        mkdir "$base/$label" &&
            _isb_checkout_source example/source-admission "$pin" "$base/$label/source" "$base/$label/graph"
    }
    admission_verify() {
        local label="$1" phase="${2:-initial}" record="${3:-proof}"
        graph=$(cat "$base/$label/graph/repositories.json") || return 1
        STATUS=0
        _isb_verify_source_graph "$base/$label/source" "$graph" "$base/$label/graph" "$phase" \
            > "$base/$label/$record" 2> "$base/$label/$record.err" || STATUS=$?
    }

    admission_checkout pristine || return 1
    admission_verify pristine
    check 'pinned acquired source authenticates across multiple hash batches' equal "$STATUS" 0
    check 'unusual source names actually have converted CRLF bytes' \
        grep -q $'\r' "$base/pristine/source/"$'line\nname.txt'
    expected=$(git -C "$base/pristine/source" rev-parse "$pin:identity.txt") || return 1
    check 'canonical Git identity expansion remains an authenticated checkout' \
        grep -Fq "\$Id: $expected \$" "$base/pristine/source/identity.txt"
    digest=$(cat "$base/pristine/proof") || return 1
    printf 'legitimate compiler output\n' > "$base/pristine/source/compiler-output"
    admission_verify pristine verify after-output
    check 'post-build verification still admits untracked compiler output' equal "$STATUS" 0
    check 'untracked compiler output does not alter pinned source fingerprint' \
        equal "$(cat "$base/pristine/after-output")" "$digest"

    admission_checkout late-blob || return 1
    printf 'unreviewed bytes beyond the first hash batch\n' > "$base/late-blob/source/zz-last.data"
    admission_verify late-blob
    check 'a changed final-batch tracked blob cannot become the initial baseline' equal "$STATUS" 6
    check 'a changed final-batch blob produces no accepted source digest' test ! -s "$base/late-blob/proof"

    admission_checkout altered-identity || return 1
    printf 'source $Id: unrelated marker text $\r\n' > "$base/altered-identity/source/identity.txt"
    admission_verify altered-identity
    check 'noncanonical identity text cannot be hidden by reverse Git normalization' equal "$STATUS" 6
    check 'noncanonical identity text produces no accepted digest' test ! -s "$base/altered-identity/proof"

    admission_checkout case-hidden || return 1
    printf 'untracked alternate source bytes\n' > "$base/case-hidden/source/MAIN.go"
    git -C "$base/case-hidden/source" config core.ignorecase true || return 1
    if [[ ! "$base/case-hidden/source/MAIN.go" -ef "$base/case-hidden/source/main.go" ]]; then
        check 'case-insensitive Git indexing would hide the extra source' \
            equal "$(git -C "$base/case-hidden/source" ls-files --others)" ''
        admission_verify case-hidden
        check 'initial admission still detects case-distinct untracked source' equal "$STATUS" 6
    else
        printf 'BOUNDARY: case-distinct extra-file control requires a case-sensitive filesystem\n'
    fi

    git config --file "$GIT_CONFIG_GLOBAL" filter.fixture.smudge 'sed s/REVIEWED_SOURCE/UNPINNED_SOURCE/g' || return 1
    admission_checkout smudged || return 1
    check 'real Git smudge changed acquired compiler source' grep -q UNPINNED_SOURCE "$base/smudged/source/main.go"
    export DSR_TEST_SOURCE_CLEAN_MARKER="$base/clean-filter-executed"
    # Local drivers would be consulted even though admission ignores global
    # Git configuration. Neither kind of executable filter may authenticate it.
    git -C "$base/smudged/source" config filter.fixture.clean \
        'printf clean >> "$DSR_TEST_SOURCE_CLEAN_MARKER"; git show HEAD:main.go' &&
        git -C "$base/smudged/source" config filter.fixture.process \
            'printf process >> "$DSR_TEST_SOURCE_CLEAN_MARKER"; exit 97' || return 1
    admission_verify smudged
    check 'checkout-transformed compiler source is refused before an initial digest' equal "$STATUS" 6
    check 'smudged source cannot publish its own accepted baseline' test ! -s "$base/smudged/proof"
    check 'source authentication never executes configured clean or process drivers' \
        test ! -e "$DSR_TEST_SOURCE_CLEAN_MARKER"

    git config --file "$GIT_CONFIG_GLOBAL" filter.fixture.smudge \
        'cat; printf "package main\nfunc init() {}\n" > injected.go' || return 1
    admission_checkout injected || return 1
    expected=$(git -C "$base/injected/source" rev-parse "$pin:main.go") || return 1
    observed=$(git -C "$base/injected/source" hash-object --no-filters main.go) || return 1
    check 'injection control preserves every reviewed primary-source byte' equal "$observed" "$expected"
    check 'real Git filter planted an ignored compiler input' test -s "$base/injected/source/injected.go"
    check 'ordinary ignored-file exclusion would hide the injected input' \
        equal "$(git -C "$base/injected/source" ls-files --others --exclude-standard)" ''
    admission_verify injected
    check 'ignored untracked compiler input is refused at initial admission' equal "$STATUS" 6
    check 'ignored source injection produces no accepted digest' test ! -s "$base/injected/proof"
    git config --file "$GIT_CONFIG_GLOBAL" --unset filter.fixture.smudge || return 1

    admission_checkout changed-link || return 1
    mv "$base/changed-link/source/newline-link" "$base/changed-link/original-link" &&
        ln -s main.go "$base/changed-link/source/newline-link" || return 1
    admission_verify changed-link
    check 'literal symlink target preserves its committed trailing newline' equal "$STATUS" 6

    git config --file "$GIT_CONFIG_GLOBAL" core.symlinks false || return 1
    admission_checkout link-stub || return 1
    admission_verify link-stub
    check 'unmodified regular link stubs authenticate as their exact target blobs' equal "$STATUS" 0
    printf 'different-target' > "$base/link-stub/source/source-link"
    admission_verify link-stub initial changed
    check 'changed regular link stub cannot become an initial source baseline' equal "$STATUS" 6
    printf 'Pinned source admission tests: %s passed, %s failed\n' "$PASS" "$FAIL"
    [[ $FAIL -eq 0 ]]
)

if [[ "$TEST_MODE" != --shipped-only ]]; then
    test_source_admission || exit $?
    [[ "$TEST_MODE" != --admission-only ]] || exit 0
fi

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
    WATCHDOG_ADAPTED=true
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

# Exercise the committed client entrypoints, not a newly generated substitute
# or a sourced helper. Only GitHub transport is adapted; source acquisition,
# recursive checkout, watchdogs, native Go compilation and installation run
# unchanged. The existing direct-engine cases below remain independently useful.
test_shipped_installers() {
    if $WATCHDOG_ADAPTED; then
        printf 'SKIP: shipped entrypoints require a working native process watchdog\n' >&2
        return 3
    fi
    python3 - "$ROOT" "$WORK" "$REAL_GO" "$ROOT_PIN" "$SHARED_PIN" "$LEAF_PIN" <<'PY'
import base64
import hashlib
import io
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tarfile

root, fixture = map(pathlib.Path, sys.argv[1:3])
real_go, root_pin, shared_pin, leaf_pin = sys.argv[3:]
work = fixture / "shipped"
(work / "bin").mkdir(parents=True)
(work / "home").mkdir()
real_git = shutil.which("git")
passed = failed = 0


def check(label, condition):
    global passed, failed
    if condition:
        passed += 1
        print("PASS: " + label, flush=True)
    else:
        failed += 1
        print("FAIL: " + label, file=sys.stderr, flush=True)


def command(arguments, **kwargs):
    return subprocess.run(arguments, capture_output=True, text=True, timeout=60, **kwargs)


policies = {
    "bv": ("Dicklesworthstone/beads_viewer", "go", "${name}_${version}_${os}_${arch}",
           "a5aeb8877e4ac9b06e212493d775a5e2c44482248086586c5a96d010d4cf3553"),
    "cass": ("Dicklesworthstone/coding_agent_session_search", "rust", "${name}-${os}-${arch}",
             "3dd554a6601c19a0f2a4de558ac817959eccc15cb30b0bf77e4d21329f8389b5"),
    "ntm": ("Dicklesworthstone/ntm", "go", "${name}_${version}_${os}_${arch}",
            "9fd59c8eb5a56ce33113abf0be34484828bf0acce3c81ae4f78ae4c26ee9d9d3"),
}
engine = (root / "src/install_source.sh").read_bytes().rstrip(b"\n")
toolchain = (root / "src/toolchain_detect.sh").read_bytes().rstrip(b"\n")
for tool, (repository, language, naming, skill_hash) in policies.items():
    script = root / "installers" / tool / "install.sh"
    payload = script.read_bytes()
    text = payload.decode()
    check(f"{tool} ships the complete current source and toolchain engines byte for byte",
          payload.count(toolchain + b"\n" + engine) == 1)
    expected = {
        "TOOL_NAME": repr(tool), "REPO": repr(repository), "BINARY_NAME": repr(tool),
        "SOURCE_LANGUAGE": repr(language), "SOURCE_SUBDIR": "'.'", "SOURCE_ENTRY": "''",
        "SOURCE_PACKAGE": "''", "ARTIFACT_NAMING": repr(naming),
        "LINUX_LIBC_FALLBACK": "'none'", "STRICT_RELEASE_CONTRACT": "false", "MINISIGN_PUBKEY": '""',
        "ARCHIVE_FORMAT_LINUX": '"tar.gz"', "ARCHIVE_FORMAT_DARWIN": '"tar.gz"',
        "ARCHIVE_FORMAT_WINDOWS": '"zip"', "ARCHIVE_FORMAT_FREEBSD": '"tar.gz"',
        "SUPPORTED_PLATFORM_PATTERN": '"^(linux/amd64|linux/arm64|linux/386|linux/armv7|darwin/amd64|darwin/arm64|windows/amd64|windows/arm64|windows/386|freebsd/amd64)$"',
    }
    observed = {name: re.findall(r"^" + name + r"=(.*)$", text, re.M) for name in expected}
    check(f"{tool} preserves its published repository, release, platform and source policy",
          all(observed[name] == [value] for name, value in expected.items()))
    tables = {}
    for name in ("_resolve_arch_alias", "_configured_target_triples", "_libc_independent_go_platform",
                 "_contract_asset_plan", "_native_variant_platform", "_workspace_binary_names"):
        function = re.search(r"^" + name + r"\(\) \{\n(.*?)^\}", text, re.M | re.S)
        case = re.search(r"\bcase .*? in\n(.*?)    esac", function.group(1), re.S) if function else None
        tables[name] = case.group(1).strip() if case else None
    check(f"{tool} preserves all target, alias, libc, contract and executable-family cases",
          all(value == "" for name, value in tables.items() if name != "_workspace_binary_names") and
          tables["_workspace_binary_names"] == "*) printf '%s\\n' '" + tool + "' ;;")
    match = re.search(r"^_SKILL_ARCHIVE_B64='([^']*)'$", text, re.M)
    archive = base64.b64decode(match.group(1), validate=True) if match else b""
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r:gz") as bundle:
        members = bundle.getmembers()
        names = [str(pathlib.PurePosixPath(member.name)) for member in members]
        valid = names == [".", "SKILL.md"] and members[0].isdir() and members[0].mode == 0o755
        valid = valid and members[1].isfile() and members[1].mode == 0o644
        valid = valid and hashlib.sha256(bundle.extractfile(members[1]).read()).hexdigest() == skill_hash
    check(f"{tool} preserves the original embedded skill files, modes and content", valid)

if failed:
    raise SystemExit(1)

for tool in ("bv", "ntm"):
    repository = policies[tool][0]
    result = command([real_git, "config", "--file", os.environ["GIT_CONFIG_GLOBAL"], "--add",
                      f"url.file://{fixture / 'root'}.insteadOf", f"https://github.com/{repository}.git"])
    if result.returncode:
        raise RuntimeError(result.stderr)

# The branch moves beyond the annotated release while all dependency gitlinks
# remain pinned. A bad freshness response must not authorize this newer source.
result = command([real_git, "-c", "core.hooksPath=/dev/null", "-C", str(fixture / "root"),
                  "commit", "--allow-empty", "-qm", "Newer shipped-installer freshness fixture"])
if result.returncode:
    raise RuntimeError(result.stderr)
head_pin = command([real_git, "-C", str(fixture / "root"), "rev-parse", "HEAD"]).stdout.strip()

for name, executable in (("git", real_git), ("go", real_go)):
    wrapper = work / "bin" / name
    wrapper.write_text('#!/usr/bin/env bash\nprintf \'%s %s\\n\' "' + name +
                       '" "$*" >> "$DSR_SHIPPED_CALLS"\nexec "' + executable + '" "$@"\n')
    wrapper.chmod(0o755)
(work / "bin/gh").write_text('#!/usr/bin/env bash\nexit 1\n')
(work / "bin/gh").chmod(0o755)

# This deliberately does not enforce curl's --max-filesize: it qualifies the
# installer's independent stream limit, including unknown-length responses on
# older curl. Genuine curl/TLS and gh framing are covered by the private suite.
(work / "bin/curl").write_text(r'''#!/usr/bin/env python3
import json, os, pathlib, sys, urllib.parse
arguments = sys.argv[1:]
url = next((arg for arg in arguments if arg.startswith("https://")), "")
if "--config" in arguments and arguments[arguments.index("--config") + 1] == "-":
    for line in sys.stdin:
        if line.startswith("url = "):
            url = json.loads(line[6:])
def option(name):
    return arguments[arguments.index(name) + 1] if name in arguments else ""
destination = option("--output") or option("-o")
writeout = option("--write-out") or option("-w")
parsed = urllib.parse.urlsplit(url)
base, head = os.environ["DSR_SHIPPED_BASE"], os.environ["DSR_SHIPPED_HEAD"]
repository = os.environ["DSR_SHIPPED_REPOSITORY"]
mode = os.environ["DSR_SHIPPED_MODE"]
status = "200"
if url == "https://api.github.com/repos/" + repository + "/releases/latest":
    body = json.dumps({"id": 123, "tag_name": "v1.0.0", "draft": False}).encode()
elif url.startswith("https://github.com/" + repository + "/releases/download/v1.0.0/"):
    asset = pathlib.Path(parsed.path).name
    body = (pathlib.Path(os.environ["DSR_SHIPPED_RELEASES"]) / asset).read_bytes()
elif url == "https://api.github.com/repos/" + repository + "/commits?per_page=1":
    body = json.dumps([{"sha": head}]).encode()
    if mode in ("boundary", "oversized"):
        body += b" " * (8388608 + int(mode == "oversized") - len(body))
    if mode == "partial":
        status = "206"
elif url == "https://api.github.com/repos/" + repository + "/commits/tags%2Fv1.0.0":
    body = json.dumps({"sha": base}).encode()
elif url == "https://api.github.com/repos/" + repository + "/compare/" + base + "..." + head + "?per_page=1":
    body = json.dumps({"base_commit": {"sha": base}, "merge_base_commit": {"sha": base},
                       "status": "ahead", "ahead_by": 1, "behind_by": 0, "total_commits": 1,
                       "commits": [{"sha": head}]}).encode()
else:
    raise SystemExit(22)
with open(os.environ["DSR_SHIPPED_HTTP"], "a") as log:
    log.write(json.dumps({"url": url, "status": status, "bytes": len(body),
                          "maximum": option("--max-filesize"), "writeout": writeout,
                          "isolated_config": arguments[0] == "-q"}) + "\n")
try:
    if destination:
        with open(destination, "wb") as output:
            output.write(body)
    else:
        sys.stdout.buffer.write(body)
    if writeout:
        sys.stdout.write(writeout.replace("%{http_code}", status).replace("%{redirect_url}", "").replace("\\n", "\n"))
except BrokenPipeError:
    raise SystemExit(23)
''')
(work / "bin/curl").chmod(0o755)

environment = os.environ.copy()
environment.update(PATH=str(work / "bin") + os.pathsep + environment["PATH"], HOME=str(work / "home"),
                   DSR_GH_TOKEN="", GITHUB_TOKEN="", GH_TOKEN="", DSR_SHIPPED_BASE=root_pin,
                   DSR_SHIPPED_HEAD=head_pin, GOMAXPROCS="2", NO_COLOR="1")


def run(tool, label, options, mode="boundary"):
    case = work / f"{tool}-{label}"
    (case / "tmp").mkdir(parents=True)
    environment.update(DSR_SHIPPED_CALLS=str(case / "calls"), DSR_SHIPPED_HTTP=str(case / "http.jsonl"),
                       DSR_SHIPPED_MODE=mode, DSR_SHIPPED_REPOSITORY=policies[tool][0],
                       DSR_SHIPPED_RELEASES=str(work / f"{tool}-releases"), TMPDIR=str(case / "tmp"))
    arguments = ["bash", str(root / "installers" / tool / "install.sh"), "--json", "--non-interactive",
                 "--no-skills", "--cache-dir", str(case / "cache"), "--dir", str(case / "install"), *options]
    (case / "argv.json").write_text(json.dumps(arguments) + "\n")
    # Retain partial evidence even if the unchanged caller deadline expires.
    with (case / "stdout.json").open("w") as output, (case / "stderr.log").open("w") as diagnostics:
        result = subprocess.run(arguments, env=environment, stdout=output, stderr=diagnostics, timeout=60)
    try:
        receipt = json.loads((case / "stdout.json").read_text())
    except ValueError:
        receipt = {}
    return case, result, receipt


expected_graph = [{"path": "deps/shared", "repository": "example/shared", "source_commit": shared_pin},
                  {"path": "deps/shared/leaf", "repository": "example/leaf", "source_commit": leaf_pin}]
system = os.uname().sysname.lower()
architecture = {"x86_64": "amd64", "aarch64": "arm64", "arm64": "arm64"}.get(os.uname().machine)
for tool in ("bv", "ntm"):
    case, result, receipt = run(tool, "source", ["--from-source", "--version", "v1.0.0", "--source-timeout", "60"])
    binary = case / "install" / tool
    source = receipt.get("source", {})
    check(f"shipped {tool} entrypoint builds and installs with real Git and Go", result.returncode == 0 and binary.is_file())
    check(f"shipped {tool} source receipt binds the annotated tag and both pinned gitlinks",
          receipt.get("method") == "source" and receipt.get("signed_release") is False and
          source.get("repository") == policies[tool][0] and source.get("source_commit") == root_pin and
          source.get("requested_ref") == "refs/tags/v1.0.0" and source.get("submodules") == expected_graph)
    if result.returncode or not binary.is_file():
        continue
    check(f"shipped {tool} executable runs the pinned child and grandchild instead of their branch tips",
          command([str(binary)]).stdout.strip() == "app-shared-leaf-pinned")
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    check(f"shipped {tool} receipt hashes the installed native executable",
          source.get("sha256") == digest and source.get("size_bytes") == binary.stat().st_size and
          receipt.get("binaries", [{}])[0].get("sha256") == digest)
    releases = work / f"{tool}-releases"
    releases.mkdir()
    asset = f"{tool}_1.0.0_{system}_{architecture}.tar.gz"
    archive = releases / asset
    with tarfile.open(archive, "w:gz") as output:
        output.add(binary, arcname=tool)
    (releases / (asset + ".sha256")).write_text(hashlib.sha256(archive.read_bytes()).hexdigest() + "  " + asset + "\n")
    for mode in ("boundary", "oversized", "partial"):
        threshold = "1" if mode == "boundary" else "0"
        case, result, receipt = run(tool, "freshness-" + mode,
                                    ["--allow-source-build", "--source-if-stale", threshold, "--source-timeout", "60"], mode)
        selected = case / "install" / tool
        check(f"shipped {tool} {mode} freshness preserves the verified release bytes",
              result.returncode == 0 and selected.is_file() and hashlib.sha256(selected.read_bytes()).hexdigest() == digest and
              receipt.get("status") == "success" and "source" not in receipt)
        check(f"shipped {tool} {mode} freshness produces the exact admission decision",
              receipt.get("freshness", {}).get("status") == ("fresh" if mode == "boundary" else "unknown"))
        calls = (case / "calls").read_text() if (case / "calls").exists() else ""
        check(f"shipped {tool} {mode} freshness does not fetch or compile newer source",
              not any(line.startswith(("git ", "go ")) for line in calls.splitlines()))
        http = [json.loads(line) for line in (case / "http.jsonl").read_text().splitlines()]
        heads = [row for row in http if row["url"].endswith("/commits?per_page=1")]
        check(f"shipped {tool} {mode} freshness actually consumes the bounded-status transport control",
              len(heads) == 1 and heads[0]["bytes"] == (8388608 + (mode == "oversized") if mode != "partial" else len(json.dumps([{"sha": head_pin}]).encode())) and
              heads[0]["status"] == ("206" if mode == "partial" else "200") and
              heads[0]["maximum"] == "8388608" and heads[0]["writeout"] == "%{http_code}" and heads[0]["isolated_config"])

check("shipped recursive builds never execute ambient hooks or custom submodule update commands",
      not (fixture / "hook-executed").exists())
print(f"Shipped installer tests: {passed} passed, {failed} failed; evidence retained at {work}", flush=True)
raise SystemExit(1 if failed else 0)
PY
}

if [[ "$TEST_MODE" == --shipped-only ]]; then
    test_shipped_installers
    exit $?
fi

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

# The public source-build entrypoint must select initial admission before
# resolving packages or starting a compiler, not just compare two snapshots
# of the already-changed checkout. Existing tagged builds below stay pinned
# to their original commits while these controls use a new fixture commit.
printf 'main.go filter=source-admission\n' > "$WORK/root/.gitattributes"
printf 'injected.go\n' > "$WORK/root/.gitignore"
git -C "$WORK/root" add .gitattributes .gitignore &&
    fixture_commit "$WORK/root" 'Fixture source acquisition policy' || exit 1
git config --file "$GIT_CONFIG_GLOBAL" filter.source-admission.smudge \
    'sed s/app-/changed-/g' || exit 1
run_build initial-smudge HEAD
check 'public source acquisition actually changes the fixture program text' \
    grep -q changed- "$WORK/initial-smudge/source/main.go"
check 'public source build refuses substituted tracked source' equal "$STATUS" 6
check 'substituted source is refused before package resolution or compilation' no_compile
check 'substituted source cannot publish a successful build receipt' no_receipt initial-smudge
git config --file "$GIT_CONFIG_GLOBAL" filter.source-admission.smudge \
    'cat; printf "package main\nvar ExtraSource = true\n" > injected.go' || exit 1
run_build initial-extra HEAD
check 'public source acquisition actually plants the ignored fixture file' \
    test -s "$WORK/initial-extra/source/injected.go"
check 'public source build refuses an ignored extra source file' equal "$STATUS" 6
check 'ignored extra source is refused before package resolution or compilation' no_compile
check 'ignored extra source cannot publish a successful build receipt' no_receipt initial-extra
git config --file "$GIT_CONFIG_GLOBAL" --unset filter.source-admission.smudge || exit 1

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
