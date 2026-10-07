#!/usr/bin/env bash
# Public generator -> standalone installer -> genuine executable families.
# Archive verification, selection, staging, rollback and compilation are real;
# only GitHub release transport and a one-shot filesystem failure are fixtures.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
# Run the identical public integration against a retained baseline checkout.
ROOT="${DSR_TEST_ROOT:-$ROOT}"
for dependency in bash python3 rustc cargo git jq yq tar gzip ps; do
    command -v "$dependency" >/dev/null 2>&1 || {
        printf 'SKIP: generated workspace installer requires %s\n' "$dependency"
        exit 0
    }
done
case "$(uname -s)/$(uname -m)" in
    Linux/x86_64|Linux/amd64) PLATFORM=linux/amd64; TRIPLE=x86_64-unknown-linux-gnu ;;
    Linux/aarch64|Linux/arm64) PLATFORM=linux/arm64; TRIPLE=aarch64-unknown-linux-gnu ;;
    Darwin/x86_64) PLATFORM=darwin/amd64; TRIPLE=x86_64-apple-darwin ;;
    Darwin/arm64) PLATFORM=darwin/arm64; TRIPLE=aarch64-apple-darwin ;;
    *) printf 'SKIP: no native Rust fixture for this platform\n'; exit 0 ;;
esac
WORK=$(mktemp -d "${TMPDIR:-/tmp}/dsr-workspace-installer.XXXXXXXX") || exit 1
printf 'Evidence: %s\n' "$WORK"
python3 - "$ROOT" "$WORK" "$PLATFORM" "$TRIPLE" <<'PY'
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import time
import zipfile

root, work = map(Path, sys.argv[1:3])
platform, triple = sys.argv[3:5]
names = ["nativefamily", "family-helper", "family-agent"]
passed = failed = sequence = 0
env = os.environ.copy()
env.update(DSR_CONFIG_DIR=str(work / "config"), DSR_STATE_DIR=str(work / "state"),
           DSR_CACHE_DIR=str(work / "dsr-cache"), CARGO_HOME=str(work / "cargo-home"),
           GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=str(work / "gitconfig"),
           NO_COLOR="1", CARGO_NET_OFFLINE="true")
for directory in ["config/repos.d", "state", "cargo-home", "payloads", "archives", "transports"]:
    (work / directory).mkdir(parents=True)


def check(label, condition):
    global passed, failed
    if condition:
        passed += 1
        print("PASS: " + label, flush=True)
    else:
        failed += 1
        print("FAIL: " + label, flush=True)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def command(label, args, selected_env=None, timeout=90):
    global sequence
    sequence += 1
    result = subprocess.run([str(arg) for arg in args], env=selected_env or env,
                            cwd=work, capture_output=True, timeout=timeout)
    prefix = work / f"{sequence:03d}-{label}"
    prefix.with_suffix(".out").write_bytes(result.stdout)
    prefix.with_suffix(".log").write_bytes(result.stderr)
    return result


def required(label, args, **kwargs):
    result = command(label, args, **kwargs)
    if result.returncode:
        raise RuntimeError(f"{label} failed ({result.returncode}): {result.stderr.decode(errors='replace')}")
    return result


def document(label, result, success):
    # json.loads rejects logs or a second document on stdout.
    try:
        value = json.loads(result.stdout)
    except (ValueError, UnicodeDecodeError):
        value = {}
    check(label + " emits one JSON object", isinstance(value, dict) and bool(value))
    check(label + " reports matching status", value.get("status") == ("success" if success else "error"))
    return value


def snapshot(directory, inodes=False):
    result = {}
    if not directory.exists():
        return result
    for path in sorted(directory.rglob("*")):
        info = path.lstat()
        entry = [stat.S_IFMT(info.st_mode), stat.S_IMODE(info.st_mode)]
        if path.is_symlink():
            entry.append(os.readlink(path))
        elif path.is_file():
            entry.append(digest(path))
        if inodes:
            entry.append(info.st_ino)
        result[str(path.relative_to(directory))] = entry
    return result


def archive(label, version, members=None, unsafe=None):
    path = work / "archives" / f"{label}.tar.gz"
    entries = members if members is not None else [(name, name) for name in names]
    with tarfile.open(path, "w:gz") as tar:
        for member, payload in entries:
            tar.add(work / "payloads" / version / payload, arcname=member, recursive=False)
        if unsafe:
            member = tarfile.TarInfo(unsafe)
            member.size = 7
            member.mode = 0o755
            tar.addfile(member, io.BytesIO(b"unsafe\n"))
    asset = f"nativefamily-{version}-{triple}.tar.gz"
    Path(str(path) + ".sha256").write_text(f"{digest(path)}  {asset}\n")
    return path


def config(override=None, family=None):
    value = {"tool_name": "nativefamily", "repo": "example/nativefamily",
             "binary_name": names[0], "language": "rust", "targets": [platform],
             "target_triples": {platform: triple},
             "artifact_naming": "${name}-${version}-${target_triple}.${ext}",
             "archive_format": {"linux": "tar.gz", "darwin": "tar.gz"},
             "workspace_binaries": names if family is None else family}
    if override is not None:
        value["workspace_binaries_by_target"] = {platform: override}
    # JSON is YAML and preserves exact scalar/list types for the real parser.
    (work / "config/repos.d/nativefamily.yaml").write_text(json.dumps(value) + "\n")


def generate(label):
    destination = work / ("generated-" + label)
    result = command("generate-" + label,
                     ["bash", root / "dsr", "--json", "installer", "generate", "nativefamily",
                      "--output-dir", destination])
    check(label + " public generator succeeds", result.returncode == 0)
    value = document(label + " generator", result, result.returncode == 0)
    check(label + " generator envelope names public command", value.get("command") == "installer"
          and value.get("exit_code") == result.returncode)
    script = destination / "nativefamily/install.sh"
    check(label + " generated standalone script exists", script.is_file())
    if not script.is_file():
        raise RuntimeError(result.stderr.decode(errors="replace"))
    required("syntax-" + label, ["bash", "-n", script])
    return script


def install(label, script, destination, version="1.2.3", payload=None,
            cache=None, extra=(), selected_env=None, success=True):
    args = ["bash", script, "--dir", destination,
            "--cache-dir", cache or work / "cache", "--non-interactive", "--json", "--no-skills"]
    if version is not None:
        args.extend(["--version", "v" + version])
    if payload is not None:
        args.extend(["--offline", payload])
    result = command(label, [*args, *extra], selected_env=selected_env, timeout=120)
    check(label + " exit status", (result.returncode == 0) == success)
    value = document(label, result, success)
    if (result.returncode == 0) != success:
        print(result.stderr.decode(errors="replace"), file=sys.stderr)
    return value


def family(label, destination, version, expected=names, receipt=None):
    for name in expected:
        path = destination / name
        check(label + " installs executable " + name, path.is_file() and os.access(path, os.X_OK))
        if path.is_file() and os.access(path, os.X_OK):
            result = command(label + "-version-" + name, [path, "--version"])
            check(label + " executes selected " + name,
                  result.returncode == 0 and result.stdout.decode().strip() == f"{name} {version}")
    if receipt is None:
        return
    binaries = receipt.get("binaries", [])
    check(label + " reports exact executable family",
          isinstance(binaries, list) and [entry.get("name") for entry in binaries] == list(expected))
    check(label + " retains primary path", receipt.get("path") == str(destination / names[0]))
    for name in expected:
        matches = [entry for entry in binaries if isinstance(entry, dict) and entry.get("name") == name]
        path = destination / name
        check(label + " receipt binds installed bytes of " + name,
              len(matches) == 1 and path.is_file() and matches[0].get("path") == str(path)
              and matches[0].get("sha256") == digest(path)
              and matches[0].get("size_bytes") == path.stat().st_size)


# Two genuinely compiled generations make partial upgrades observable.
for version in ["1.2.3", "1.2.4"]:
    directory = work / "payloads" / version
    directory.mkdir()
    for name in names:
        source = directory / (name + ".rs")
        source.write_text(f'fn main() {{ println!("{name} {version}"); }}\n')
        required("compile-" + version + "-" + name,
                 ["rustc", "--edition=2021", "--target", triple, source, "-o", directory / name])
        result = required("prove-" + version + "-" + name, [directory / name, "--version"])
        check("genuine Rust payload executes " + name + " " + version,
              result.stdout.decode().strip() == f"{name} {version}")

v1 = archive("complete-v1", "1.2.3")
v2 = archive("complete-v2", "1.2.4")
config()
script = generate("family")
destination = work / "installed"
destination.mkdir()
unrelated = destination / "user-managed.txt"
unrelated.write_text("keep this user's unrelated file\n")
unrelated_before = snapshot(destination, inodes=True)[unrelated.name]
receipt = install("verified-family", script, destination, payload=v1)
family("verified family", destination, "1.2.3", receipt=receipt)
check("initial install preserves unrelated file inode and bytes",
      snapshot(destination, inodes=True).get(unrelated.name) == unrelated_before)

# Every unsafe/incomplete archive has a correct checksum. Refusals exercise
# family selection after real verification, rather than stopping at bad hashes.
invalid_archives = [
    ("missing-companion", archive("missing", "1.2.4", [(name, name) for name in names[:-1]])),
    ("duplicate-companion", archive("duplicate", "1.2.4",
                                   [(name, name) for name in names] + [("other/family-helper", "family-helper")])),
    ("unsafe-companion", archive("unsafe", "1.2.4", [(name, name) for name in names[:-1]],
                                unsafe="../family-agent")),
]
for label, payload in invalid_archives:
    before = snapshot(destination, inodes=True)
    install(label, script, destination, version="1.2.4", payload=payload,
            extra=["--yes"], success=False)
    check(label + " leaves every existing file and inode unchanged",
          snapshot(destination, inodes=True) == before)
check("unsafe companion cannot escape extraction", not (work / "family-agent").exists())

# Refusal must include a pre-existing companion even when the primary is new.
companion_only = work / "companion-only"
companion_only.mkdir()
shutil.copy2(work / "payloads/1.2.3/family-helper", companion_only / "family-helper")
before = snapshot(companion_only, inodes=True)
install("companion-overwrite-needs-consent", script, companion_only, version="1.2.4", payload=v2,
        success=False)
check("existing companion preflight does not partially install primary",
      snapshot(companion_only, inodes=True) == before)
linked_companion = work / "linked-companion"
linked_companion.mkdir()
shutil.copy2(work / "payloads/1.2.3/nativefamily", linked_companion / "nativefamily")
(linked_companion / "family-helper").symlink_to(work / "payloads/1.2.3/family-helper")
before = snapshot(linked_companion, inodes=True)
install("linked-companion-refusal", script, linked_companion, version="1.2.4", payload=v2,
        extra=["--yes"], success=False)
check("linked companion refusal preserves primary and link before any replacement",
      snapshot(linked_companion, inodes=True) == before)

# A deterministic real rename failure after primary commit proves rollback of
# the transaction. The wrapper delegates every successful rename to real mv.
failure_tools = work / "failure-tools"
failure_tools.mkdir()
real_mv = shutil.which("mv")
(failure_tools / "mv").write_text("""#!/usr/bin/env bash
set -uo pipefail
argv=("$@")
source_path="${argv[${#argv[@]}-2]}"
destination_path="${argv[${#argv[@]}-1]}"
if [[ "$source_path" == */new/family-helper && "$destination_path" == "$FAMILY_FAILURE_DIR/family-helper" && ! -e "$FAMILY_FAILURE_MARKER" ]]; then
    printf 'failed-companion-commit\\n' > "$FAMILY_FAILURE_MARKER"
    printf 'failed family-helper\\n' >> "$FAMILY_RENAME_LOG"
    exit 73
fi
"$FAMILY_REAL_MV" "$@" || exit $?
if [[ "$source_path" == */new/* && "$destination_path" == "$FAMILY_FAILURE_DIR/"* ]]; then
    printf 'committed %s\\n' "${destination_path##*/}" >> "$FAMILY_RENAME_LOG"
fi
""")
(failure_tools / "mv").chmod(0o755)
failure_env = env | {"PATH": str(failure_tools) + os.pathsep + env["PATH"],
                     "FAMILY_FAILURE_DIR": str(destination), "FAMILY_REAL_MV": real_mv,
                     "FAMILY_FAILURE_MARKER": str(work / "failure-fired"),
                     "FAMILY_RENAME_LOG": str(work / "rename.log")}
before = snapshot(destination)
install("rollback-after-first-commit", script, destination, version="1.2.4", payload=v2,
        extra=["--yes"], selected_env=failure_env, success=False)
renames = (work / "rename.log").read_text() if (work / "rename.log").exists() else ""
check("rollback fixture observes actual primary commit before companion failure",
      "committed nativefamily\n" in renames and "failed family-helper\n" in renames
      and renames.index("committed nativefamily\n") < renames.index("failed family-helper\n"))
check("failed family commit restores all prior bytes, modes and directory entries",
      snapshot(destination) == before)
family("rolled-back family", destination, "1.2.3")

# Send a real signal to only the public installer PID while its child is at
# the second commit. Returning from the wrapper then exercises actual rename
# and signal forwarding/rollback; there is no replacement installer engine.
signal_ready = work / "signal-probe-ready"
probe_process = subprocess.Popen([sys.executable, "-c",
    'import signal,sys,time; from pathlib import Path; '
    'signal.signal(signal.SIGTERM, lambda *args: sys.exit(42)); '
    'Path(sys.argv[1]).write_text("ready"); time.sleep(10)', str(signal_ready)], env=env)
deadline = time.monotonic() + 3
while not signal_ready.exists() and probe_process.poll() is None and time.monotonic() < deadline:
    time.sleep(0.01)
try:
    probe_process.send_signal(signal.SIGTERM)
    signal_status = probe_process.wait(timeout=3)
except (OSError, subprocess.TimeoutExpired):
    signal_status = None
signal_capable = signal_ready.exists() and signal_status == 42
check("actual parent-to-child TERM capability probe succeeds", signal_capable)
if signal_capable:
    interrupted_dest = work / "interrupted-installed"
    interrupted_dest.mkdir()
    for name in names:
        shutil.copy2(work / "payloads/1.2.3" / name, interrupted_dest / name)
    (interrupted_dest / "unrelated.txt").write_text("preserve through interruption\n")
    before = snapshot(interrupted_dest)
    signal_tools = work / "signal-tools"
    signal_tools.mkdir()
    (signal_tools / "mv").write_text("""#!/usr/bin/env bash
set -uo pipefail
argv=("$@")
source_path="${argv[${#argv[@]}-2]}"
destination_path="${argv[${#argv[@]}-1]}"
if [[ "$source_path" == */new/family-helper && "$destination_path" == "$FAMILY_SIGNAL_DIR/family-helper" ]]; then
    printf 'ready\\n' > "$FAMILY_SIGNAL_READY"
    while [[ ! -e "$FAMILY_SIGNAL_RELEASE" ]]; do sleep 0.01; done
fi
"$FAMILY_REAL_MV" "$@" || exit $?
if [[ "$source_path" == */new/* && "$destination_path" == "$FAMILY_SIGNAL_DIR/"* ]]; then
    printf '%s\\n' "${destination_path##*/}" >> "$FAMILY_SIGNAL_LOG"
fi
""")
    (signal_tools / "mv").chmod(0o755)
    ready = work / "signal-commit-ready"
    release = work / "signal-commit-release"
    signal_log = work / "signal-renames.log"
    signal_env = env | {"PATH": str(signal_tools) + os.pathsep + env["PATH"],
                        "FAMILY_SIGNAL_DIR": str(interrupted_dest), "FAMILY_REAL_MV": real_mv,
                        "FAMILY_SIGNAL_READY": str(ready), "FAMILY_SIGNAL_RELEASE": str(release),
                        "FAMILY_SIGNAL_LOG": str(signal_log)}
    args = ["bash", str(script), "--version", "v1.2.4", "--dir", str(interrupted_dest),
            "--cache-dir", str(work / "signal-cache"), "--non-interactive", "--json",
            "--no-skills", "--offline", str(v2), "--yes"]
    process = subprocess.Popen(args, env=signal_env, cwd=work, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    deadline = time.monotonic() + 10
    while not ready.exists() and process.poll() is None and time.monotonic() < deadline:
        time.sleep(0.01)
    reached = ready.exists() and signal_log.exists() and signal_log.read_text() == "nativefamily\n"
    check("real interruption reaches second commit after replacing only primary", reached)
    if reached:
        process.send_signal(signal.SIGTERM)
        # Give the parent its own scheduling opportunity to forward TERM.
        time.sleep(0.1)
    release.write_text("continue real rename\n")
    out, err = process.communicate(timeout=15)
    (work / "signal-installer.out").write_bytes(out)
    (work / "signal-installer.log").write_bytes(err)
    result = subprocess.CompletedProcess(args, process.returncode, out, err)
    check("parent-only TERM makes the actual installer fail", result.returncode != 0)
    document("parent-only TERM", result, False)
    check("parent-only TERM restores every family member and unrelated file", snapshot(interrupted_dest) == before)
    family("interrupted family", interrupted_dest, "1.2.3")
else:
    print("SKIP: no parent-only installer interruption claim; actual TERM capability unavailable", flush=True)

receipt = install("full-family-upgrade", script, destination, version="1.2.4", payload=v2, extra=["--yes"])
family("full upgrade", destination, "1.2.4", receipt=receipt)
check("full upgrade preserves unrelated file inode and bytes",
      snapshot(destination, inodes=True).get(unrelated.name) == unrelated_before)

# An override is the complete selected set; an archive containing extra
# workspace members must not silently install the excluded global member.
override = [names[0], names[2]]
config(override=override)
override_script = generate("override")
override_dest = work / "override-installed"
receipt = install("platform-override", override_script, override_dest, payload=v1)
family("platform override", override_dest, "1.2.3", expected=override, receipt=receipt)
check("platform override excludes global-only companion", not (override_dest / names[1]).exists())
config(override=[])
singleton_script = generate("empty-override")
singleton_dest = work / "singleton-installed"
receipt = install("empty-override-singleton", singleton_script, singleton_dest, payload=v1)
family("empty override", singleton_dest, "1.2.3", expected=[names[0]], receipt=receipt)
check("empty override installs only primary", set(snapshot(singleton_dest)) == {names[0]})

# All online traffic is resolved at the named GitHub release boundary; cache
# writes and later offline acquisition/verification use unchanged production.
remote = work / "remote"
remote.mkdir()
asset = f"nativefamily-1.2.3-{triple}.tar.gz"
shutil.copy2(v1, remote / asset)
shutil.copy2(Path(str(v1) + ".sha256"), remote / (asset + ".sha256"))
transports = work / "transports"
(transports / "curl").write_text("""#!/usr/bin/env python3
import os
from pathlib import Path
import shutil
import sys
args = iter(sys.argv[1:])
destination = url = ''
for arg in args:
    if arg in ('-o', '--output'):
        destination = next(args, '')
    elif arg in ('--proto', '--proto-redir', '--connect-timeout', '--max-time', '--retry', '--max-redirs', '-w'):
        next(args, '')
    elif arg.startswith('https:'):
        url = arg
with open(os.environ['FAMILY_TRANSPORT_LOG'], 'a') as log:
    log.write(url + '\\n')
prefix = 'https://github.com/example/nativefamily/releases/download/v1.2.3/'
if not url.startswith(prefix) or not destination:
    sys.exit(22)
name = url[len(prefix):]
if '/' in name or not name:
    sys.exit(22)
source = Path(os.environ['FAMILY_REMOTE']) / name
if not source.is_file():
    sys.exit(22)
shutil.copyfile(source, destination)
""")
(transports / "gh").write_text("#!/usr/bin/env bash\nprintf 'gh unavailable\\n' >> \"$FAMILY_TRANSPORT_LOG\"\nexit 1\n")
for name in ["curl", "gh"]:
    (transports / name).chmod(0o755)
transport_log = work / "transport.log"
online_env = env | {"PATH": str(transports) + os.pathsep + env["PATH"],
                    "FAMILY_TRANSPORT_LOG": str(transport_log), "FAMILY_REMOTE": str(remote)}
cache = work / "verified-cache"
cached_dest = work / "online-installed"
receipt = install("online-cache-population", script, cached_dest, cache=cache, selected_env=online_env)
family("cache population", cached_dest, "1.2.3", receipt=receipt)
before_calls = transport_log.read_bytes() if transport_log.exists() else b""
check("online boundary fetched the real archive", asset.encode() in before_calls)
offline_dest = work / "offline-cache-installed"
receipt = install("verified-offline-cache", script, offline_dest, cache=cache,
                  extra=["--offline"], selected_env=online_env)
family("verified offline cache", offline_dest, "1.2.3", receipt=receipt)
check("verified offline cache makes no transport calls",
      (transport_log.read_bytes() if transport_log.exists() else b"") == before_calls)

# A local Git URL policy replaces only the transport. The generated source
# engine must fetch the pinned commit and compile all three real workspace
# members, including two outside Cargo's default-members.
source_tree = work / "source-repository"
source_tree.mkdir()
(source_tree / "Cargo.toml").write_text(
    '[workspace]\nresolver = "2"\nmembers = ["primary", "helper", "agent"]\ndefault-members = ["primary"]\n')
for package, name in zip(["primary", "helper", "agent"], names):
    package_dir = source_tree / package
    (package_dir / "src").mkdir(parents=True)
    (package_dir / "Cargo.toml").write_text(
        f'[package]\nname = "{name}"\nversion = "1.2.5"\nedition = "2021"\n')
    (package_dir / "src/main.rs").write_text(f'fn main() {{ println!("{name} 1.2.5"); }}\n')
required("source-init", ["git", "init", "-q", "-b", "main", source_tree])
required("source-author", ["git", "-C", source_tree, "config", "user.name", "DSR integration"])
required("source-email", ["git", "-C", source_tree, "config", "user.email", "test@example.invalid"])
required("source-lock", ["cargo", "generate-lockfile", "--offline", "--manifest-path", source_tree / "Cargo.toml"])
required("source-add", ["git", "-C", source_tree, "add", "Cargo.toml", "Cargo.lock", "primary", "helper", "agent"])
required("source-commit", ["git", "-C", source_tree, "commit", "-qm", "real executable family"])
required("source-tag", ["git", "-C", source_tree, "tag", "v1.2.5"])
pin = required("source-pin", ["git", "-C", source_tree, "rev-parse", "HEAD"]).stdout.decode().strip()
required("source-transport", ["git", "config", "--file", env["GIT_CONFIG_GLOBAL"],
                              "url." + source_tree.as_uri() + ".insteadOf", "https://github.com/example/nativefamily.git"])
probe = command("source-watchdog-capability", ["bash", "-c",
                'source "$1"; _isb_run 3 "$2" printf watchdog-probe', "_",
                root / "src/install_source.sh", work / "watchdog-probe.log"])
source_script = script
source_env = online_env
if probe.returncode != 0:
    host_pid = ""
    namespace_pids = []
    if Path("/proc/self/stat").is_file() and Path("/proc/self/status").is_file():
        host_pid = Path("/proc/self/stat").read_text().split()[0]
        namespace_pids = next((line.split()[1:] for line in Path("/proc/self/status").read_text().splitlines()
                               if line.startswith("NSpid:")), [])
    observed = command("independent-pid-namespace", ["ps", "-o", "pid=", "-p", str(os.getpid())])
    mismatch = (probe.returncode == 3 and not (work / "watchdog-probe.log").exists()
                and len(namespace_pids) >= 2 and host_pid != str(os.getpid())
                and namespace_pids[0] == host_pid and namespace_pids[-1] == str(os.getpid())
                and observed.stdout.decode().strip() != str(os.getpid()))
    check("watchdog boundary has independent host/namespace PID mismatch evidence", mismatch)
    if not mismatch:
        raise RuntimeError("source watchdog failed without independent PID namespace evidence")
    # This host exposes /proc from a different PID namespace. Run the actual
    # generated main with only its process-supervision boundary substituted;
    # this phase proves real Git/Cargo/family installation, not the watchdog.
    print("BOUNDARY FIXTURE: source watchdog unavailable; real Git/Cargo run without production supervision", flush=True)
    source_script = work / "source-watchdog-launcher.sh"
    source_script.write_text("""#!/usr/bin/env bash
set -uo pipefail
source <(awk '/^# Emit one machine-readable result on every failure/{exit} {print}' "$FAMILY_STANDALONE_INSTALLER")
_isb_run() {
    local limit="$1" log="$2"
    shift 2
    [[ "$limit" =~ ^[1-9][0-9]{0,4}$ && ! -e "$log" && ! -L "$log" ]] || return 4
    "$@" </dev/null > "$log" 2>&1
}
for arg in "$@"; do [[ "$arg" != --json ]] || _JSON_MODE=true; done
if main "$@"; then
    :
else
    status=$?
    if ! $_JSON_EMITTED; then _json_result error "Installation failed (exit $status)" "$_VERSION" ""; fi
    exit "$status"
fi
""")
    source_env = online_env | {"FAMILY_STANDALONE_INSTALLER": str(script)}
if source_script is not None:
    source_dest = work / "source-installed"
    receipt = install("generated-source-family", source_script, source_dest, version=None,
                      extra=["--from-source", "--source-ref", pin, "--source-timeout", "60"],
                      selected_env=source_env)
    family("generated source family", source_dest, "1.2.5", receipt=receipt)
    source_receipt = receipt.get("source", {})
    check("source family receipt binds the fetched commit and trust mode",
          receipt.get("method") == "source" and receipt.get("signed_release") is False
          and source_receipt.get("source_commit") == pin)
    source_binaries = source_receipt.get("binaries", [])
    check("source family retains complete provenance without temporary paths",
          [entry.get("name") for entry in source_binaries] == names
          and all(entry.get("path") in (None, str(source_dest / entry["name"])) for entry in source_binaries))
    check("source family leaves verified release cache unchanged",
          (transport_log.read_bytes() if transport_log.exists() else b"") == before_calls)
    fallback_dest = work / "source-fallback-installed"
    receipt = install("unavailable-release-source-fallback", source_script, fallback_dest, version="1.2.5",
                      extra=["--allow-source-build", "--source-timeout", "60"], selected_env=source_env)
    family("source fallback family", fallback_dest, "1.2.5", receipt=receipt)
    check("unavailable release fallback resolves its explicit release tag",
          receipt.get("method") == "source" and receipt.get("source", {}).get("source_commit") == pin
          and receipt.get("source", {}).get("requested_ref") == "refs/tags/v1.2.5")
    check("source fallback was triggered by actual release acquisition failure",
          b"/releases/download/v1.2.5/" in transport_log.read_bytes()[len(before_calls):])

# These are Windows selection-policy tests on the current filesystem, not
# native Windows execution or NTFS acceptance. Load unchanged generated
# functions, select their real Windows policy, and inspect real ZIP members.
if shutil.which("unzip"):
    print("POLICY BOUNDARY: Windows archive naming/extraction on this host; no native Windows claim", flush=True)
    windows_names = [name + ".EXE" for name in names]
    config(family=windows_names)
    config_path = work / "config/repos.d/nativefamily.yaml"
    windows_config = json.loads(config_path.read_text())
    windows_config.update(binary_name=windows_names[0], targets=["windows/amd64"],
                          target_triples={"windows/amd64": "x86_64-pc-windows-msvc"},
                          archive_format={"windows": "zip"})
    config_path.write_text(json.dumps(windows_config) + "\n")
    windows_script = generate("windows-policy")
    windows_launcher = work / "windows-policy-launcher.sh"
    windows_launcher.write_text("""#!/usr/bin/env bash
set -uo pipefail
source <(awk '/^# Emit one machine-readable result on every failure/{exit} {print}' "$1")
_select_install_family windows/amd64 || exit $?
_extract_archive "$2" "$3" zip || exit $?
_select_archive_binaries "$3" || exit $?
selected_names=$(printf '%s\\n' "${_INSTALL_NAMES[@]}" | jq -Rsc 'split("\\n")[:-1]') || exit $?
selected_paths=$(printf '%s\\n' "${_INSTALL_PATHS[@]}" | jq -Rsc 'split("\\n")[:-1]') || exit $?
jq -nc --argjson names "$selected_names" --argjson paths "$selected_paths" '{names:$names, paths:$paths}'
""")

    def windows_archive(label, extra=()):
        path = work / "archives" / (label + ".zip")
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive_file:
            for name in names:
                archive_file.write(work / "payloads/1.2.3" / name, "release/" + name.upper() + ".EXE")
            for member, name in extra:
                archive_file.write(work / "payloads/1.2.3" / name, member)
        return path

    windows_zip = windows_archive("windows-uppercase")
    windows_extract = work / "windows-selected"
    result = command("windows-uppercase-members",
                     ["bash", windows_launcher, windows_script, windows_zip, windows_extract])
    check("Windows policy selects uppercase .EXE archive members", result.returncode == 0)
    try:
        selected = json.loads(result.stdout)
    except (ValueError, UnicodeDecodeError):
        selected = {}
    check("Windows policy normalizes configured .EXE suffix exactly once",
          selected.get("names") == [name + ".exe" for name in names])
    paths = selected.get("paths", [])
    for index, name in enumerate(names):
        selected_path = Path(paths[index]) if index < len(paths) else None
        check("Windows case-insensitive selection preserves actual bytes of " + name,
              selected_path is not None and selected_path.is_file()
              and selected_path.name == name.upper() + ".EXE"
              and digest(selected_path) == digest(work / "payloads/1.2.3" / name))

    case_collision = windows_archive("windows-casefold-collision", [("RELEASE/nativefamily.exe", names[0])])
    collision_extract = work / "windows-collision-extract"
    result = command("windows-pre-extraction-collision",
                     ["bash", windows_launcher, windows_script, case_collision, collision_extract])
    check("Windows casefold path collision is refused", result.returncode != 0)
    check("Windows casefold collision refuses before creating extraction directory", not collision_extract.exists())
    check("Windows casefold refusal identifies the duplicate archive member",
          b"Duplicate archive member:" in result.stderr)

    ambiguous = windows_archive("windows-ambiguous-member", [("other/NativeFamily.exe", names[0])])
    ambiguous_extract = work / "windows-ambiguous-extract"
    result = command("windows-ambiguous-required-member",
                     ["bash", windows_launcher, windows_script, ambiguous, ambiguous_extract])
    check("Windows casefold member ambiguity across directories is refused", result.returncode != 0)
    check("Windows ambiguity refusal comes from actual member selection",
          ambiguous_extract.is_dir() and b"exactly one matching binary" in result.stderr)
else:
    print("SKIP: Windows archive-policy fixtures require unzip; no Windows policy claim", flush=True)

print(f"Results: {passed} passed, {failed} failed; evidence {work}", flush=True)
sys.exit(1 if failed else 0)
PY
