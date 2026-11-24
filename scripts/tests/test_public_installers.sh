#!/usr/bin/env bash
# Exercise the checked-in installers through their public entry points.
# Real curl/TLS, compiled executables, tar archives, hashes and cache writes;
# only GitHub routing is redirected to a private loopback release server.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLERS="${DSR_PUBLIC_INSTALLER_ROOT:-$ROOT/installers}"

test_skill_destinations() {
    python3 -I - "$ROOT" "$INSTALLERS" "${1:-}" <<'SKILL_TEST_PY'
import base64
import fcntl
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile

root, installers = map(Path, sys.argv[1:3])
limits_only = sys.argv[3] == '--limits-only'
work = Path(tempfile.mkdtemp(prefix='dsr-public-skills-')).resolve()
print('Public skill destination evidence retained: ' + str(work), flush=True)
environment = {key: value for key, value in os.environ.items()
               if key not in ('BASH_ENV', 'ENV') and not key.startswith('BASH_FUNC_')}
environment.update(NO_COLOR='1', DSR_GH_TOKEN='', GH_TOKEN='', GITHUB_TOKEN='')
system = {'Linux': 'linux', 'Darwin': 'darwin'}[platform.system()]
architecture = {'x86_64': 'amd64', 'aarch64': 'arm64', 'arm64': 'arm64'}[platform.machine()]
passed = failed = 0


def check(label, condition):
    global passed, failed
    if condition:
        passed += 1
        print('PASS: ' + label, flush=True)
    else:
        failed += 1
        print('FAIL: ' + label, flush=True)


def snapshot(directory):
    return {str(path.relative_to(directory)): (stat.S_IFMT(path.lstat().st_mode),
            stat.S_IMODE(path.lstat().st_mode), path.lstat().st_ino,
            os.readlink(path) if path.is_symlink() else path.read_bytes() if path.is_file() else None)
            for path in directory.rglob('*')}


def content_snapshot(directory):
    return {name: (value[0], value[1], value[3]) for name, value in snapshot(directory).items()}


def run(label, script, case, package, env=None):
    result = subprocess.run(['bash', str(script), '--version', 'v1.2.3', '--offline', str(package),
        '--yes', '--non-interactive', '--json', '--dir', str(case / 'bin'),
        '--cache-dir', str(case / 'cache')], cwd=case,
        env=env or dict(environment, HOME=str(case / 'home')), stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, timeout=30)
    (case / (label + '.out')).write_bytes(result.stdout)
    (case / (label + '.err')).write_bytes(result.stderr)
    try:
        receipt = json.loads(result.stdout)
    except (ValueError, UnicodeDecodeError):
        receipt = {}
    check(label + ' keeps verified binary installation successful',
          result.returncode == 0 and receipt.get('status') == 'success' and
          (case / 'bin' / script.parent.name).read_bytes() == executable)
    return result


def prepare(tool, scenario):
    case = work / (tool + '-' + scenario)
    home = case / 'home'
    skill = home / '.claude/skills' / tool
    skill.parent.mkdir(parents=True)
    (home / '.codex').mkdir()
    sentinel = case / 'outside'
    sentinel.mkdir()
    (sentinel / 'SKILL.md').write_bytes(b'unrelated original skill\n')
    if scenario == 'directory-symlink':
        skill.symlink_to(sentinel, target_is_directory=True)
    else:
        skill.mkdir()
        (skill / 'custom/nested').mkdir(parents=True)
        (skill / 'custom/nested/settings').write_bytes(b'private configuration\n')
        (skill / 'custom/nested/settings').chmod(0o640)
        if scenario == 'file-symlink':
            (skill / 'SKILL.md').symlink_to(sentinel / 'SKILL.md')
        elif scenario == 'hardlink':
            os.link(sentinel / 'SKILL.md', skill / 'SKILL.md')
        elif scenario == 'file-directory-conflict':
            (skill / 'SKILL.md').mkdir()
            (skill / 'SKILL.md/custom').write_bytes(b'conflicting custom directory\n')
        else:
            (skill / 'SKILL.md').write_bytes(b'previous skill text\n')
    return case, skill, sentinel


(work / 'payload.c').write_text('#include <stdio.h>\nint main(void) { puts("skill fixture 1.2.3"); return 0; }\n')
subprocess.run(['cc', str(work / 'payload.c'), '-o', str(work / 'fixture')], check=True)
executable = (work / 'fixture').read_bytes()
local = work / 'source'
(local / '.claude/skills/demo/references').mkdir(parents=True)
(local / '.claude/skills/demo/SKILL.md').write_bytes(b'# Generated fixture skill\n')
(local / '.claude/skills/demo/references/guide.md').write_bytes(b'Embedded nested reference\n')
config = work / 'config'
(config / 'repos.d').mkdir(parents=True)
(config / 'repos.d/demo.yaml').write_text('tool_name: demo\nrepo: example/demo\nbinary_name: demo\n'
    'language: go\narchive_format: tar.gz\nlocal_path: ' + str(local) + '\n')
generated_environment = dict(environment, DSR_CONFIG_DIR=str(config), DSR_INSTALLER_DIR=str(work / 'generated'))
generated = subprocess.run(['bash', '-c', 'source "$1/src/install_gen.sh"; install_gen_create demo --config-dir "$2"',
    '_', str(root), str(config)], cwd=work, env=generated_environment, stdout=subprocess.PIPE,
    stderr=subprocess.PIPE, timeout=30)
(work / 'generation.err').write_bytes(generated.stderr)
if generated.returncode:
    raise RuntimeError(generated.stderr.decode(errors='replace'))
scripts = [Path(generated.stdout.decode().strip())] + [installers / tool / 'install.sh' for tool in ('bv', 'cass', 'ntm')]

# Inject failures at actual filesystem syscalls in the optional Python process;
# the generated public installer and the production publisher stay unchanged.
tools = work / 'tools'
tools.mkdir()
wrapper = tools / 'python3'
wrapper.write_text('#!' + sys.executable + '\n' + '''
import os, sys
if sys.argv[1:3] == ['-I', '-']:
    program = sys.stdin.read()
    if program.startswith('# DSR optional skill publication:') and sys.argv[3] == os.environ.get('SKILL_FAULT_DEST'):
        prefix = ''' + repr('''import os
_skill_original_write = os.write
_skill_original_rename = os.rename
_skill_writes = 0
def _skill_write(fd, data):
    global _skill_writes
    _skill_writes += 1
    if os.environ['SKILL_FAULT'] == 'copy' and _skill_writes == 2:
        raise OSError('injected partial skill copy')
    return _skill_original_write(fd, data)
def _skill_rename(source, destination, **kwargs):
    if source == 'candidate':
        if os.environ['SKILL_FAULT'] == 'rename':
            raise OSError('injected skill publication failure')
        if os.environ['SKILL_FAULT'] == 'stop':
            os._exit(71)
    return _skill_original_rename(source, destination, **kwargs)
os.write = _skill_write
os.rename = _skill_rename
''') + '''
        program = prefix + program
    os.execv(''' + repr(sys.executable) + ''', [''' + repr(sys.executable) + ''', '-I', '-c', program, *sys.argv[3:]])
os.execv(''' + repr(sys.executable) + ''', [''' + repr(sys.executable) + ''', *sys.argv[1:]])
''')
wrapper.chmod(0o755)

for script in scripts:
    tool = script.parent.name
    b64 = re.search(r"^_SKILL_ARCHIVE_B64='([^']*)'$", script.read_text(), re.M).group(1)
    with tarfile.open(fileobj=io.BytesIO(base64.b64decode(b64)), mode='r:gz') as bundle:
        member = next(member for member in bundle if str(Path(member.name)) == 'SKILL.md')
        expected_skill = bundle.extractfile(member).read()
    asset = (f'cass-{system}-{architecture}.tar.gz' if tool == 'cass' else
             f'{tool}_1.2.3_{system}_{architecture}.tar.gz' if tool in ('bv', 'ntm') else
             f'demo-1.2.3-{system}-{architecture}.tar.gz')
    package = work / asset
    with tarfile.open(package, 'w:gz') as archive:
        member = tarfile.TarInfo(tool)
        member.size, member.mode = len(executable), 0o755
        archive.addfile(member, io.BytesIO(executable))
    Path(str(package) + '.sha256').write_text(hashlib.sha256(package.read_bytes()).hexdigest() + '  ' + asset + '\n')
    scenarios = ['normal', 'directory-symlink', 'file-symlink', 'hardlink', 'file-directory-conflict']
    if limits_only:
        scenarios = []
    if tool == 'demo' and not limits_only:
        scenarios += ['copy', 'rename', 'stop', 'locked', 'parent-symlink', 'special']
    for scenario in scenarios:
        case, skill, sentinel = prepare(tool, scenario)
        if scenario == 'parent-symlink':
            # Link a previously absent agent directory without moving user data.
            linked_home = case / 'linked-home'
            linked_home.mkdir()
            (linked_home / '.claude').symlink_to(case / 'home/.claude', target_is_directory=True)
            (linked_home / '.codex').mkdir()
            home = linked_home
        else:
            home = case / 'home'
        if scenario == 'special':
            os.mkfifo(skill / 'pipe')
        previous = snapshot(skill)
        custom = content_snapshot(skill / 'custom') if (skill / 'custom').is_dir() else None
        original_sentinel = snapshot(sentinel)
        env = dict(environment, HOME=str(home))
        if scenario in ('copy', 'rename', 'stop'):
            env.update(PATH=str(tools) + os.pathsep + environment['PATH'], SKILL_FAULT=scenario,
                       SKILL_FAULT_DEST=str(skill))
        held = None
        if scenario == 'locked':
            held = open(skill.parent / ('.' + tool + '.dsr-skill.lock'), 'wb')
            fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result = run(tool + '-' + scenario, script, case, package, env)
        if held is not None:
            held.close()
        check(tool + '-' + scenario + ' preserves unrelated sentinel bytes and inode', snapshot(sentinel) == original_sentinel)
        if scenario == 'normal':
            check(tool + ' updates the existing skill and preserves nested custom files',
                  (skill / 'SKILL.md').read_bytes() == expected_skill and content_snapshot(skill / 'custom') == custom)
            retained = list(skill.parent.glob('.' + tool + '.skill-update.*/previous'))
            check(tool + ' retains the exact previous skill tree', len(retained) == 1 and snapshot(retained[0]) == previous)
        elif scenario == 'stop':
            retained = list(skill.parent.glob('.' + tool + '.skill-update.*/previous'))
            check('uncatchable skill stop retains original tree', len(retained) == 1 and snapshot(retained[0]) == previous)
            retry = run('stopped-retry', script, case, package)
            check('retry refuses to abandon an unfinished skill publication', not skill.exists() and
                  b'Unfinished skill publication' in retry.stderr and snapshot(retained[0]) == previous)
        else:
            check(tool + '-' + scenario + ' refuses without changing the original skill tree', snapshot(skill) == previous and
                  (b'optional skill installation skipped' in result.stderr))
            if scenario in ('copy', 'rename', 'locked'):
                retry = run(scenario + '-retry', script, case, package)
                check(scenario + ' can retry safely after failure', (skill / 'SKILL.md').read_bytes() == expected_skill and
                      content_snapshot(skill / 'custom') == custom and retry.returncode == 0)
        check(tool + '-' + scenario + ' independently installs a fresh Codex skill',
              (home / '.codex/skills' / tool / 'SKILL.md').read_bytes() == expected_skill)

# Binary-only users need no Python dependency. Exercise the actual PATH lookup,
# not a fake Python command which would still appear installed to command -v.
case, skill, sentinel = prepare('demo', 'without-python')
without_python = case / 'tools'
without_python.mkdir()
for name in ('bash env uname tr sed grep mktemp mkdir cp chmod mv rm rmdir head tail cat wc '
             'sha256sum shasum openssl tar gzip unzip base64 readlink ps sleep date stat dirname '
             'basename find xargs sort cut od getconf ldd file flock awk tee dd touch uniq').split():
    executable_path = shutil.which(name)
    if executable_path:
        (without_python / name).symlink_to(executable_path)
previous = snapshot(skill)
result = run('without-python', scripts[0], case, work / f'demo-1.2.3-{system}-{architecture}.tar.gz',
             dict(environment, HOME=str(case / 'home'), PATH=str(without_python)))
check('missing Python preserves the complete existing skill tree', snapshot(skill) == previous)
check('missing Python skips fresh optional skills with an actionable warning',
      not (case / 'home/.codex/skills/demo').exists() and
      b'Python 3 is required for safe publication' in result.stderr)

# A GNU long-name header expands before tarfile yields an ordinary member.
# Compress it in bounded chunks and supply it through the generator's archive
# command, so this exercises a genuine standalone client with hostile metadata.
oversized_archive = work / 'oversized-metadata.tar.gz'
header = tarfile.TarInfo('././@LongLink')
header.type = tarfile.GNUTYPE_LONGNAME
header.size = 64 * 1024 * 1024 + 1
with open(oversized_archive, 'wb') as output, gzip.GzipFile(fileobj=output, mode='wb', mtime=0) as compressed:
    compressed.write(header.tobuf(format=tarfile.GNU_FORMAT))
    for unused in range(64):
        compressed.write(b'a' * (1024 * 1024))
    compressed.write(b'\0' + b'\0' * 511)
    member = tarfile.TarInfo('SKILL.md')
    member.size, member.mode = 5, 0o644
    compressed.write(member.tobuf(format=tarfile.GNU_FORMAT))
    compressed.write(b'skill' + b'\0' * 507 + b'\0' * 1024)
archive_tools = work / 'archive-tools'
archive_tools.mkdir()
(archive_tools / 'tar').write_text('#!/bin/sh\n'
    'if [ "$1" = -czf ] && [ "$2" = - ]; then exec cat "$SKILL_ARCHIVE_FIXTURE"; fi\n'
    'exec "$SKILL_REAL_TAR" "$@"\n')
(archive_tools / 'tar').chmod(0o755)
oversized_environment = dict(generated_environment, PATH=str(archive_tools) + os.pathsep + environment['PATH'],
    DSR_INSTALLER_DIR=str(work / 'oversized-generated'), SKILL_ARCHIVE_FIXTURE=str(oversized_archive),
    SKILL_REAL_TAR=shutil.which('tar'))
oversized_generation = subprocess.run(['bash', '-c',
    'source "$1/src/install_gen.sh"; install_gen_create demo --config-dir "$2"', '_', str(root), str(config)],
    cwd=work, env=oversized_environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
(work / 'oversized-generation.err').write_bytes(oversized_generation.stderr)
if oversized_generation.returncode:
    raise RuntimeError(oversized_generation.stderr.decode(errors='replace'))
case, skill, sentinel = prepare('demo', 'expanded-header')
previous = snapshot(skill)
original_sentinel = snapshot(sentinel)
result = run('expanded-header', Path(oversized_generation.stdout.decode().strip()), case,
             work / f'demo-1.2.3-{system}-{architecture}.tar.gz')
check('oversized compressed metadata is refused at the expanded byte limit',
      b'Expanded skill archive exceeds the byte limit' in result.stderr)
check('oversized metadata preserves every original skill and unrelated sentinel',
      snapshot(skill) == previous and snapshot(sentinel) == original_sentinel)
check('oversized metadata is rejected before staging or fresh destination creation',
      not list(skill.parent.glob('.demo.*')) and not (case / 'home/.codex/skills').exists())
print(f'Public skill destinations: {passed} passed, {failed} failed', flush=True)
raise SystemExit(1 if failed else 0)
SKILL_TEST_PY
}

if [[ "${1:-}" == --skills-only ]]; then
    test_skill_destinations
    exit $?
fi
if [[ "${1:-}" == --skills-limits-only ]]; then
    test_skill_destinations --limits-only
    exit $?
fi

for dependency in python3 openssl curl cc tar jq; do
    command -v "$dependency" >/dev/null || { printf 'SKIP: %s required\n' "$dependency"; exit 3; }
done
work=$(mktemp -d "${TMPDIR:-/tmp}/dsr-public-installers.XXXXXXXX") || exit 1
work=$(cd "$work" && pwd -P) || exit 1
printf 'Public installer fixtures retained at: %s\n' "$work"
server_pid=''
finish() {
    if [[ -n "$server_pid" ]]; then
        kill "$server_pid" 2>/dev/null || true
        wait "$server_pid" 2>/dev/null || true
    fi
}
trap finish EXIT
trap 'exit 5' HUP INT TERM
passed=0 failed=0
check() {
    local label="$1"; shift
    if "$@"; then passed=$((passed + 1)); printf 'ok - %s\n' "$label"
    else failed=$((failed + 1)); printf 'not ok - %s\n' "$label"; fi
}
mkdir -p "$work/tls" "$work/remote" "$work/transports" "$work/payload" "$work/results" || exit 1
cat > "$work/payload.c" <<'C'
#include <stdio.h>
int main(void) { puts("DSR public installer fixture 1.2.3"); return 0; }
C
cc "$work/payload.c" -o "$work/payload/fixture" > "$work/compile.log" 2>&1 || exit 1
os=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$os" in linux|darwin) ;; *) printf 'SKIP: Unix fixture compiler host required\n'; exit 3 ;; esac
case "$(uname -m)" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) printf 'SKIP: amd64 or arm64 host required\n'; exit 3 ;;
esac
sha256() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
fixture_hash=$(sha256 "$work/payload/fixture") || exit 1

# Pin trust to this test's local CA. The adapter retains the installer's HTTPS
# restrictions and invokes genuine curl; no public host is contacted.
cat > "$work/tls/config" <<'TLS'
[req]
distinguished_name=dn
x509_extensions=extensions
prompt=no
[dn]
CN=localhost
[extensions]
subjectAltName=DNS:localhost,IP:127.0.0.1
basicConstraints=critical,CA:TRUE
TLS
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -config "$work/tls/config" \
    -keyout "$work/tls/key.pem" -out "$work/tls/cert.pem" > "$work/tls/generate.log" 2>&1 || exit 1
cat > "$work/server.py" <<'PY'
import functools
import http.server
import pathlib
import ssl
import sys

root, port_file, cert, key, log = sys.argv[1:]

class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, template, *args):
        with open(log, "a", encoding="utf-8") as output:
            output.write((template % args) + "\n")

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), functools.partial(Handler, directory=root))
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(cert, key)
server.socket = context.wrap_socket(server.socket, server_side=True)
pathlib.Path(port_file).write_text(str(server.server_address[1]), encoding="ascii")
server.serve_forever()
PY
python3 "$work/server.py" "$work/remote" "$work/port" "$work/tls/cert.pem" \
    "$work/tls/key.pem" "$work/requests.log" > "$work/server.log" 2>&1 &
server_pid=$!
for ((attempt=0; attempt<100; attempt++)); do
    [[ ! -s "$work/port" ]] || break
    kill -0 "$server_pid" 2>/dev/null || { cat "$work/server.log" >&2; exit 1; }
    sleep 0.05
done
[[ -s "$work/port" ]] || exit 1
DSR_TEST_CURL=$(command -v curl)
DSR_TEST_ORIGIN="https://localhost:$(cat "$work/port")"
DSR_TEST_CA="$work/tls/cert.pem"
export DSR_TEST_CURL DSR_TEST_ORIGIN DSR_TEST_CA
cat > "$work/transports/curl" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
args=() url_count=0
config_stdin=false expect_config=false config_line='' config_url='' routed_config=''
route_release_url() {
    case "$1" in
        https://github.com/Dicklesworthstone/*/releases/download/v1.2.3/*)
            printf '%s\n' "$1" >> "$DSR_TEST_CALLS"
            [[ "$DSR_TEST_HTTP_VARIANT" != offline ]] || return 22
            printf '%s/%s/%s' "$DSR_TEST_ORIGIN" "$DSR_TEST_HTTP_VARIANT" "${1#https://github.com/}" ;;
        *) printf 'REFUSED %s\n' "$1" >> "$DSR_TEST_CALLS"; return 22 ;;
    esac
}
for arg in "$@"; do
    if $expect_config; then
        [[ "$arg" == - ]] || exit 22
        args+=("$arg")
        config_stdin=true
        expect_config=false
        continue
    fi
    case "$arg" in
        --config|-K)
            $config_stdin && exit 22
            expect_config=true
            args+=("$arg") ;;
        --config=*|-K?*) exit 22 ;;
        https://github.com/Dicklesworthstone/*/releases/download/v1.2.3/*)
            routed=$(route_release_url "$arg") || exit $?
            args+=("$routed")
            url_count=$((url_count + 1)) ;;
        *://*) printf 'REFUSED %s\n' "$arg" >> "$DSR_TEST_CALLS"; exit 22 ;;
        *) args+=("$arg") ;;
    esac
done
$expect_config && exit 22
if $config_stdin; then
    # Current installers put one public URL in curl's stdin config. Admit
    # only that exact record; retain every curl option and route only its URL.
    IFS= read -r config_line || exit 22
    config_url=${config_line#'url = "'}
    config_url=${config_url%'"'}
    [[ "$config_line" == "url = \"$config_url\"" &&
       "$config_url" != *[[:cntrl:]]* && "$config_url" != *\\* && "$config_url" != *\"* ]] || exit 22
    extra=''
    if IFS= read -r extra || [[ -n "$extra" ]]; then exit 22; fi
    routed=$(route_release_url "$config_url") || exit $?
    routed_config="url = \"$routed\""
    url_count=$((url_count + 1))
fi
[[ "$url_count" == 1 ]] || exit 22
if $config_stdin; then
    exec "$DSR_TEST_CURL" -q --noproxy '*' --cacert "$DSR_TEST_CA" "${args[@]}" <<< "$routed_config"
fi
exec "$DSR_TEST_CURL" -q --noproxy '*' --cacert "$DSR_TEST_CA" "${args[@]}"
SH
cat > "$work/transports/gh" <<'SH'
#!/usr/bin/env bash
printf 'REFUSED gh\n' >> "$DSR_TEST_CALLS"
exit 1
SH
chmod 755 "$work/transports/curl" "$work/transports/gh" || exit 1
export PATH="$work/transports:$PATH" NO_COLOR=1
installer_env=(env -u name -u version -u os -u arch -u target_triple)

status=0 case_dir=''
run_install() {
    local label="$1" cache="$2" variant="$3"; shift 3
    case_dir="$work/results/$tool-$label"
    mkdir -p "$case_dir" || exit 1
    : > "$case_dir/transport.log"
    status=0
    DSR_TEST_CALLS="$case_dir/transport.log" DSR_TEST_HTTP_VARIANT="$variant" \
        "${installer_env[@]}" bash "$installer" --version 1.2.3 --dir "$case_dir/bin" \
        --cache-dir "$cache" --non-interactive --json --no-skills "$@" \
        > "$case_dir/out" 2> "$case_dir/err" || status=$?
}
success_receipt() {
    [[ "$status" == 0 && -x "$case_dir/bin/$tool" ]] &&
        jq -e -s --arg tool "$tool" --arg hash "$fixture_hash" \
            'length == 1 and (.[0] | .status == "success" and .tool == $tool and
             .version == "v1.2.3" and (.binaries | length == 1) and
             .binaries[0].name == $tool and .binaries[0].sha256 == $hash)' "$case_dir/out" >/dev/null
}
blocked() {
    [[ "$status" != 0 && ! -e "$case_dir/bin/$tool" ]] &&
        jq -e -s 'length == 1 and .[0].status == "error"' "$case_dir/out" >/dev/null
}
help_matches() {
    [[ -s "$work/results/$tool-help/out" ]] &&
        cmp -s "$work/results/$tool-help/out" "$work/results/$tool-help/stdin.out"
}

for tool in bv cass ntm; do
    installer="$INSTALLERS/$tool/install.sh"
    mkdir -p "$work/results/$tool-help" "$work/payload/$tool" || exit 1
    check "$tool script parses" bash -n "$installer"
    status=0
    "${installer_env[@]}" bash "$installer" --help > "$work/results/$tool-help/out" \
        2> "$work/results/$tool-help/err" || status=$?
    check "$tool --help starts with all artifact placeholders unset" test "$status" -eq 0
    check "$tool help documents offline mode" grep -q -- --offline "$work/results/$tool-help/out"
    status=0
    "${installer_env[@]}" bash -s -- --help < "$installer" > "$work/results/$tool-help/stdin.out" \
        2> "$work/results/$tool-help/stdin.err" || status=$?
    check "$tool piped --help succeeds" test "$status" -eq 0
    check "$tool piped help matches file invocation" help_matches
    if [[ "$status" != 0 ]]; then continue; fi

    case "$tool" in
        bv) repository=beads_viewer; asset="bv_1.2.3_${os}_${arch}.tar.gz" ;;
        cass) repository=coding_agent_session_search; asset="cass-${os}-${arch}.tar.gz" ;;
        ntm) repository=ntm; asset="ntm_1.2.3_${os}_${arch}.tar.gz" ;;
    esac
    route="Dicklesworthstone/$repository/releases/download/v1.2.3"
    for variant in valid missing tampered; do mkdir -p "$work/remote/$variant/$route" || exit 1; done
    cp "$work/payload/fixture" "$work/payload/$tool/$tool" || exit 1
    archive="$work/remote/valid/$route/$asset"
    COPYFILE_DISABLE=1 tar -czf "$archive" -C "$work/payload/$tool" "$tool" || exit 1
    archive_hash=$(sha256 "$archive") || exit 1
    printf '%s  %s\n' "$archive_hash" "$asset" > "$archive.sha256"
    cp "$archive" "$work/remote/missing/$route/$asset" || exit 1
    # A different, still-valid executable and tar archive. Without verification
    # this payload would install successfully, so refusal proves the checksum gate.
    printf '\nchanged release bytes\n' >> "$work/payload/$tool/$tool"
    COPYFILE_DISABLE=1 tar -czf "$work/remote/tampered/$route/$asset" -C "$work/payload/$tool" "$tool" || exit 1
    cp "$archive.sha256" "$work/remote/tampered/$route/$asset.sha256" || exit 1
    cache="$work/$tool-cache"

    run_install https "$cache" valid
    check "$tool HTTPS installation succeeds with no --verify flag" success_receipt
    check "$tool installed executable matches verified payload" cmp -s "$work/payload/fixture" "$case_dir/bin/$tool"
    check "$tool installed executable runs" "$case_dir/bin/$tool" --version
    check "$tool downloads its preserved release asset name" grep -Fxq "https://github.com/$route/$asset" "$case_dir/transport.log"
    check "$tool downloads checksum evidence by default" grep -Fxq "https://github.com/$route/$asset.sha256" "$case_dir/transport.log"
    cached="$cache/$tool/Dicklesworthstone/$repository/v1.2.3/$os-$arch/tar.gz/$asset/payload"
    check "$tool caches the verified archive" cmp -s "$archive" "$cached"
    check "$tool caches checksum evidence" cmp -s "$archive.sha256" "$cached.sha256"

    run_install cache "$cache" offline --offline
    check "$tool offline cache installation succeeds" success_receipt
    check "$tool offline cache makes no transport calls" test ! -s "$case_dir/transport.log"
    check "$tool offline cache installs verified bytes" cmp -s "$work/payload/fixture" "$case_dir/bin/$tool"

    run_install local "$work/$tool-local-cache" offline --offline "$archive"
    check "$tool explicit offline archive succeeds" success_receipt
    check "$tool explicit offline archive makes no transport calls" test ! -s "$case_dir/transport.log"

    run_install missing "$work/$tool-missing-cache" missing
    check "$tool default installation rejects missing release checksums" blocked
    check "$tool missing-checksum failure identifies the integrity requirement" grep -q 'No release checksums available' "$case_dir/err"
    check "$tool never caches an unverified download" test ! -e "$work/$tool-missing-cache/$tool/Dicklesworthstone/$repository/v1.2.3/$os-$arch/tar.gz/$asset/payload"

    run_install tampered "$work/$tool-tampered-cache" tampered
    check "$tool default installation rejects an altered valid archive" blocked
    check "$tool tampered download fails at checksum verification" grep -q 'Checksum mismatch' "$case_dir/err"
    check "$tool never caches a tampered download" test ! -e "$work/$tool-tampered-cache/$tool/Dicklesworthstone/$repository/v1.2.3/$os-$arch/tar.gz/$asset/payload"

    run_install local-missing "$work/$tool-local-missing-cache" offline --offline "$work/remote/missing/$route/$asset"
    check "$tool offline archive requires checksum evidence" blocked
    check "$tool missing offline evidence never triggers network" test ! -s "$case_dir/transport.log"

    run_install signatures "$work/$tool-signature-cache" offline --offline "$archive" --require-signatures
    check "$tool explicit signature requirement rejects its unsigned configuration" blocked

    cp "$work/remote/tampered/$route/$asset" "$cached" || exit 1
    prior_install="$work/results/$tool-https/bin"
    run_install cache-tampered "$cache" offline --offline --yes --dir "$prior_install"
    check "$tool refuses altered cached bytes before replacing an existing install" test "$status" -ne 0
    check "$tool altered cache reports checksum failure" grep -q 'Checksum mismatch' "$case_dir/err"
    check "$tool preserves the previously installed executable" cmp -s "$work/payload/fixture" "$prior_install/$tool"
    check "$tool altered offline cache never triggers network" test ! -s "$case_dir/transport.log"
done
printf 'Public installers: %s passed, %s failed\n' "$passed" "$failed"
[[ "$failed" == 0 ]] || exit 1
test_skill_destinations
