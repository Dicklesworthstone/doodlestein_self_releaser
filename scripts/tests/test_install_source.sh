#!/usr/bin/env bash
# Real Git HTTPS credentials plus Git/Go source-build regressions. HTTPS uses
# a private loopback CONNECT service and fixture CA, never a public endpoint.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SOURCE_MODULE="${DSR_TEST_INSTALL_SOURCE_MODULE:-$ROOT/src/install_source.sh}"
case "$#:${1:-}" in
    0:|1:--credentials-only) ;;
    *) printf 'Usage: %s [--credentials-only]\n' "$0" >&2; exit 4 ;;
esac

test_source_credentials() {
    local dependency
    for dependency in python3 openssl git jq; do
        command -v "$dependency" >/dev/null 2>&1 || { printf 'SKIP: Git HTTPS credentials require %s\n' "$dependency"; return 3; }
    done
    python3 -I - "$SOURCE_MODULE" <<'PY'
import base64
from http.server import BaseHTTPRequestHandler
import json
import os
from pathlib import Path
import shutil
import socket
import socketserver
import ssl
import subprocess
import sys
import tempfile
import threading
from urllib.parse import urlsplit

module = Path(sys.argv[1]).resolve()
work = Path(tempfile.mkdtemp(prefix='dsr-source-git-credentials-')).resolve()
print('Git HTTPS source fixtures retained at: ' + str(work), flush=True)
git = shutil.which('git')
bash = shutil.which('bash')
passed = failed = 0

def check(label, condition):
    global passed, failed
    if condition:
        passed += 1
        print('PASS: ' + label, flush=True)
    else:
        failed += 1
        print('FAIL: ' + label, flush=True)

env = dict(os.environ)
for name in list(env):
    if (name.lower().endswith('_proxy') or name.startswith('GIT_') or
            name in ('DSR_GH_TOKEN', 'GITHUB_TOKEN', 'GH_TOKEN', 'GH_HOST',
                     'DSR_INSTALLER_GIT_TOKEN', 'DSR_INSTALLER_GIT_REPOSITORY')):
        env.pop(name)
env.update(HOME=str(work / 'home'), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null')
(work / 'home').mkdir()
upstream = work / 'upstream'
subprocess.run([git, 'init', '-q', '-b', 'main', str(upstream)], env=env, check=True)
(upstream / 'src').mkdir()
(upstream / 'Cargo.toml').write_text('[package]\nname="private_fixture"\nversion="1.0.0"\nedition="2021"\n')
(upstream / 'Cargo.lock').write_text('version = 4\n\n[[package]]\nname = "private_fixture"\nversion = "1.0.0"\n')
(upstream / 'src/main.rs').write_text('fn main() { println!("private-source-fixture"); }\n')
subprocess.run([git, '-C', str(upstream), 'add', '.'], env=env, check=True)
subprocess.run([git, '-C', str(upstream), '-c', 'user.name=DSR Fixture',
                '-c', 'user.email=dsr-fixture@example.invalid', 'commit', '-qm', 'private source'], env=env, check=True)
subprocess.run([git, '-C', str(upstream), '-c', 'user.name=DSR Fixture',
                '-c', 'user.email=dsr-fixture@example.invalid', 'tag', '-a', 'v1.0.0', '-m', 'source tag'], env=env, check=True)
pin = subprocess.check_output([git, '-C', str(upstream), 'rev-parse', 'HEAD'], env=env, text=True).strip()
remotes = work / 'remotes'
(remotes / 'example').mkdir(parents=True)
subprocess.run([git, 'clone', '-q', '--bare', str(upstream), str(remotes / 'example/source-fixture.git')], env=env, check=True)
backend = Path(subprocess.check_output([git, '--exec-path'], env=env, text=True).strip()) / 'git-http-backend'
if not backend.is_file():
    raise SystemExit('Real Git HTTP backend is required')
cert, key = work / 'certificate.pem', work / 'fixture-key.pem'
with (work / 'openssl.log').open('wb') as log:
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                    '-keyout', str(key), '-out', str(cert), '-subj', '/CN=github.com',
                    '-addext', 'subjectAltName=DNS:github.com,DNS:other.example.invalid'],
                   check=True, stdout=log, stderr=log)
key.chmod(0o600)
tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
tls.load_cert_chain(cert, key)
state = {'expected': '', 'mode': 'private', 'requests': [], 'connects': [], 'errors': []}

class Endpoint(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def response(self, status, body=b'', headers=None):
        self.send_response(status)
        for name, value in (headers or {}).items():
            if name.lower() not in ('content-length', 'connection'):
                self.send_header(name, value)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def route(self):
        authorization = self.headers.get('Authorization', '')
        correct = authorization == 'Basic ' + base64.b64encode(('x-access-token:' + state['expected']).encode()).decode()
        state['requests'].append({'host': self.target_host, 'path': self.path,
                                  'has_authorization': bool(authorization), 'selected_account': correct})
        if self.target_host != 'github.com':
            return self.response(403)
        if state['mode'] != 'anonymous' and not correct:
            return self.response(401, headers={'WWW-Authenticate': 'Basic realm="owned Git fixture"'})
        if state['mode'] == 'redirect':
            return self.response(302, headers={'Location': 'https://other.example.invalid' + self.path})
        if state['mode'] == 'redirect-repository':
            return self.response(302, headers={'Location': 'https://github.com/unrelated/project.git/info/refs?service=git-upload-pack'})
        url = urlsplit(self.path)
        if not url.path.startswith('/example/source-fixture.git/'):
            return self.response(404)
        incoming = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        backend_env = dict(env, GIT_PROJECT_ROOT=str(remotes), GIT_HTTP_EXPORT_ALL='1',
                           REQUEST_METHOD=self.command, PATH_INFO=url.path, QUERY_STRING=url.query,
                           CONTENT_TYPE=self.headers.get('Content-Type', ''), CONTENT_LENGTH=str(len(incoming)),
                           SERVER_PROTOCOL='HTTP/1.1', REMOTE_USER='fixture',
                           HTTP_GIT_PROTOCOL=self.headers.get('Git-Protocol', ''))
        result = subprocess.run([str(backend)], env=backend_env, input=incoming, capture_output=True, timeout=15)
        if result.returncode:
            state['errors'].append('git-http-backend failed')
            return self.response(500)
        header, body = result.stdout.split(b'\r\n\r\n', 1)
        fields = dict(line.decode('iso-8859-1').split(': ', 1) for line in header.split(b'\r\n'))
        status = int(fields.pop('Status', '200 OK').split()[0])
        return self.response(status, body, fields)

    do_GET = route
    do_POST = route

class Proxy(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            self.request.settimeout(15)
            data = b''
            while not data.endswith(b'\r\n\r\n'):
                block = self.request.recv(1)
                if not block or len(data) > 8192:
                    return
                data += block
            fields = data.split(b'\r\n', 1)[0].split()
            if len(fields) != 3 or fields[0] != b'CONNECT':
                return
            host = fields[1].decode()
            state['connects'].append(host)
            if host not in ('github.com:443', 'other.example.invalid:443'):
                self.request.sendall(b'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n')
                return
            self.request.sendall(b'HTTP/1.1 200 Connection established\r\n\r\n')
            with tls.wrap_socket(self.request, server_side=True) as secure:
                class BoundEndpoint(Endpoint):
                    target_host = host.rsplit(':', 1)[0]
                BoundEndpoint(secure, self.client_address, self.server)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError, socket.timeout):
            pass  # Certificate and redirect refusals can close the client early.
        except Exception as error:
            state['errors'].append(type(error).__name__ + ': ' + str(error))

class Server(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True

server = Server(('127.0.0.1', 0), Proxy)
threading.Thread(target=server.serve_forever, daemon=True).start()
proxy = 'http://127.0.0.1:' + str(server.server_address[1])
env.update(HTTPS_PROXY=proxy, https_proxy=proxy, HTTP_PROXY=proxy, http_proxy=proxy,
           ALL_PROXY='', all_proxy='', NO_PROXY='', no_proxy='', GIT_SSL_CAINFO=str(cert))
bin_dir = work / 'bin'
git_only = work / 'git-only'
bin_dir.mkdir(); git_only.mkdir()
git_wrapper = '''#!/bin/sh
printf '%s\\n' "$@" >> "$DSR_TEST_GIT_ARGV"
exec "$DSR_TEST_REAL_GIT" "$@"
'''
for directory in (bin_dir, git_only):
    (directory / 'git').write_text(git_wrapper)
    (directory / 'git').chmod(0o755)
    (directory / 'jq').symlink_to(shutil.which('jq'))
(bin_dir / 'gh').write_text('''#!/bin/sh
printf '%s %s\\n' "${GH_HOST:-}" "$*" >> "$DSR_TEST_GH_LOG"
test "$*" = 'auth token --hostname github.com' && test "${GH_HOST:-}" = github.com || exit 1
test -n "${DSR_TEST_STORED_TOKEN:-}" || exit 1
printf '%s\\n' "$DSR_TEST_STORED_TOKEN"
''')
(bin_dir / 'gh').chmod(0o755)
ambient_helper = work / 'ambient-credential'
ambient_helper.write_text('''#!/bin/sh
test "$1" = get || exit 0
printf '%s\\n' 'username=x-access-token' 'password=ambient-fixture-secret'
''')
ambient_helper.chmod(0o755)
env.update(PATH=str(bin_dir) + os.pathsep + env['PATH'], DSR_TEST_REAL_GIT=git,
           GH_HOST='enterprise.example.invalid')
tokens = ('dsr-fixture-secret', 'ci-fixture-secret', 'cli-fixture-secret', 'stored-fixture-secret', 'ambient-fixture-secret')

def run(label, selected=None, expected='', mode='private', configuration='', no_gh=False, ref='refs/tags/v1.0.0', build=False, tracing=False, netrc=False):
    case = work / label
    case.mkdir()
    state.update(expected=expected, mode=mode, requests=[], connects=[], errors=[])
    config = case / 'gitconfig'
    config.write_text(configuration)
    selected_env = dict(env, GIT_CONFIG_GLOBAL=str(config), DSR_TEST_GIT_ARGV=str(case / 'git-argv'),
                        DSR_TEST_GH_LOG=str(case / 'gh-lookup'), DSR_GH_TOKEN='', GITHUB_TOKEN='', GH_TOKEN='',
                        DSR_TEST_STORED_TOKEN='', GIT_TRACE=str(case / 'git-trace'),
                        GIT_TRACE_CURL=str(case / 'git-curl-trace'), GIT_TRACE_REDACT='0', GIT_CURL_VERBOSE='1',
                        DSR_INSTALLER_GIT_TOKEN='caller-sentinel', DSR_INSTALLER_GIT_REPOSITORY='caller/repository')
    selected_env.update(selected or {})
    if netrc:
        credential_directory = case / 'credential-home'
        credential_directory.mkdir()
        netrc_file = credential_directory / '.netrc'
        netrc_file.write_text('machine github.com login x-access-token password ambient-fixture-secret\n')
        netrc_file.chmod(0o600)
        selected_env['HOME'] = str(credential_directory)
    if no_gh:
        selected_env['PATH'] = str(git_only)
    command = '''source "$1" || exit $?
if [[ "$4" == build ]]; then
    install_source_build example/source-fixture "$3" rust private_fixture "$2/build" --allow-build --timeout 60
else
    if [[ "$5" == tracing ]]; then set -x; fi
    _isb_checkout example/source-fixture "$3" "$2/source"
    checkout_status=$?
    if [[ "$5" == tracing ]]; then
        tracing_flags=$-; set +x
        [[ "$tracing_flags" == *x* && "$DSR_INSTALLER_GIT_TOKEN" == caller-sentinel &&
           "$DSR_INSTALLER_GIT_REPOSITORY" == caller/repository && "$GIT_CONFIG_GLOBAL" == "$2/gitconfig" &&
           "$GIT_TRACE_REDACT" == 0 && "$GH_HOST" == enterprise.example.invalid ]] || exit 99
        printf 'caller-state-preserved\\n'
    fi
    exit "$checkout_status"
fi
'''
    result = subprocess.run([bash, '-c', command, '_', str(module), str(case), ref,
                             'build' if build else 'checkout', 'tracing' if tracing else 'quiet'],
                            env=selected_env, capture_output=True, timeout=90)
    (case / 'stdout').write_bytes(result.stdout); (case / 'stderr').write_bytes(result.stderr)
    (case / 'transport.json').write_text(json.dumps({'requests': state['requests'], 'connects': state['connects'], 'errors': state['errors']}, indent=2))
    check(label + ': real Git HTTP backend has no fixture error', not state['errors'])
    return result, case

def pinned(result, case):
    if result.returncode or not (case / 'source/src/main.rs').is_file():
        return False
    current = subprocess.check_output([git, '-C', str(case / 'source'), 'rev-parse', 'HEAD'], env=env, text=True).strip()
    return current == pin and (case / 'source/src/main.rs').read_bytes() == (upstream / 'src/main.rs').read_bytes()

def no_persisted_token(case):
    needles = [value.encode() for value in tokens]
    needles += [base64.b64encode(('x-access-token:' + value).encode()) for value in tokens]
    paths = [path for name in ('source', 'build') for path in (case / name).rglob('*') if path.is_file()]
    paths += [case / name for name in ('stdout', 'stderr', 'git-argv', 'git-trace', 'git-curl-trace') if (case / name).is_file()]
    return not any(needle in path.read_bytes() for path in paths for needle in needles)

try:
    ambient = '[credential]\n\thelper = ' + json.dumps(str(ambient_helper)) + '\n'
    poison = '[url "https://other.example.invalid/"]\n\tinsteadOf = https://github.com/\n' + ambient
    for label, selected, expected in (
        ('dsr', dict(DSR_GH_TOKEN=tokens[0], GITHUB_TOKEN=tokens[1], GH_TOKEN=tokens[2], DSR_TEST_STORED_TOKEN=tokens[3]), tokens[0]),
        ('github', dict(GITHUB_TOKEN=tokens[1], GH_TOKEN=tokens[2], DSR_TEST_STORED_TOKEN=tokens[3]), tokens[1]),
        ('gh', dict(GH_TOKEN=tokens[2], DSR_TEST_STORED_TOKEN=tokens[3]), tokens[2]),
        ('stored', dict(DSR_TEST_STORED_TOKEN=tokens[3]), tokens[3]),
    ):
        result, case = run(label, selected, expected, configuration=poison)
        check(label + ': selected account fetches and peels the real annotated Git tag', pinned(result, case))
        check(label + ': credential reaches only the requested GitHub repository', bool(state['requests']) and
              all(row['host'] == 'github.com' and row['path'].startswith('/example/source-fixture.git/') and
                  (not row['has_authorization'] or row['selected_account']) for row in state['requests']))
        check(label + ': no token in checkout, logs, trace or real Git argv', no_persisted_token(case))
        lookup = (case / 'gh-lookup').read_text() if (case / 'gh-lookup').exists() else ''
        check(label + ': explicit tokens never probe a stored account',
              lookup == ('github.com auth token --hostname github.com\n' if label == 'stored' else ''))
    result, case = run('without-gh', dict(DSR_GH_TOKEN=tokens[0]), tokens[0], no_gh=True, ref=pin)
    check('explicit token works without gh and preserves the exact commit pin', pinned(result, case))
    result, case = run('invalid-explicit', dict(DSR_GH_TOKEN='invalid-fixture-token', GH_TOKEN=tokens[4]), tokens[4], configuration=ambient)
    check('invalid explicit token cannot fall back to ambient helper or GH_TOKEN', result.returncode == 8 and not (case / 'source/src/main.rs').exists())
    check('invalid explicit token never authenticates through another account', not any(row['selected_account'] for row in state['requests']))
    result, case = run('netrc-precedence', dict(DSR_GH_TOKEN=tokens[0]), tokens[0], netrc=True)
    check('selected source credential takes precedence over libcurl netrc credentials', pinned(result, case) and
          all(not row['has_authorization'] or row['selected_account'] for row in state['requests']))
    result, case = run('netrc-invalid-explicit', dict(DSR_GH_TOKEN='invalid-fixture-token'), tokens[4], netrc=True)
    check('invalid explicit token cannot install through a different netrc account', result.returncode == 8 and not (case / 'source/src/main.rs').exists())
    for label in ('redirect', 'redirect-repository'):
        result, case = run(label, dict(DSR_GH_TOKEN=tokens[0]), tokens[0], mode=label)
        check(label + ': authenticated redirect is refused before source checkout', result.returncode == 8 and not (case / 'source/src/main.rs').exists())
        check(label + ': no other origin or repository receives a request', all(
            row['host'] == 'github.com' and row['path'].startswith('/example/source-fixture.git/') for row in state['requests']))
    result, case = run('bad-certificate', dict(DSR_GH_TOKEN=tokens[0], GIT_SSL_CAINFO=str(work / 'missing-ca'), GIT_SSL_NO_VERIFY='1'), tokens[0])
    check('explicit token never disables HTTPS certificate validation', result.returncode == 8 and not any(row['has_authorization'] for row in state['requests']))
    result, case = run('malformed-token', dict(DSR_GH_TOKEN='bad\nusername=other'), tokens[0])
    check('credential protocol injection is refused before any Git network request', result.returncode == 8 and not state['requests'] and not state['connects'])
    result, case = run('anonymous', mode='anonymous', no_gh=True)
    check('Git-only anonymous checkout remains available', pinned(result, case))
    result, case = run('ambient-helper', expected=tokens[4], configuration=ambient, no_gh=True)
    check('Git-only custom credential helper remains available', pinned(result, case))
    rewrite = '[url "' + upstream.as_uri() + '"]\n\tinsteadOf = https://github.com/example/source-fixture.git\n'
    result, case = run('ambient-url-policy', configuration=rewrite, no_gh=True)
    check('Git-only URL policy still uses the real local Git transport', pinned(result, case) and not state['requests'])
    result, case = run('caller-state', dict(DSR_GH_TOKEN=tokens[0]), tokens[0], tracing=True)
    check('authenticated checkout preserves caller environment and tracing state', pinned(result, case) and result.stdout == b'caller-state-preserved\n')
    check('shell tracing cannot expose the selected source token', no_persisted_token(case))
    if shutil.which('cargo', path=env['PATH']) and shutil.which('rustc', path=env['PATH']):
        result, case = run('private-build', dict(DSR_GH_TOKEN=tokens[0]), tokens[0], build=True)
        check('private pinned source completes a genuine Rust source build', result.returncode == 0)
        receipt = json.loads(result.stdout) if result.returncode == 0 else {}
        payload = Path(receipt.get('path', str(case / 'missing')))
        check('private source receipt binds the fetched commit and locally built executable',
              receipt.get('source_commit') == pin and receipt.get('method') == 'source' and receipt.get('signed_release') is False and payload.is_file())
        check('private source executable actually runs', payload.is_file() and
              subprocess.check_output([str(payload)], env=env).strip() == b'private-source-fixture')
        check('private build evidence never stores the selected Git token', no_persisted_token(case))
    else:
        print('SKIP: genuine private Rust build requires cargo and rustc; Git HTTPS checks ran', flush=True)
finally:
    server.shutdown(); server.server_close()
print('Git HTTPS source credentials: %d passed, %d failed' % (passed, failed), flush=True)
sys.exit(0 if failed == 0 else 1)
PY
}

credential_status=0
test_source_credentials || credential_status=$?
[[ "$credential_status" == 0 ]] || exit "$credential_status"
[[ "${1:-}" != --credentials-only ]] || exit 0
# shellcheck source=../../src/install_source.sh
source "$SOURCE_MODULE"
# These retained local-transport cases deliberately have no GitHub account.
# The HTTPS fixture above covers every selected-credential route separately.
export DSR_GH_TOKEN='' GITHUB_TOKEN='' GH_TOKEN=''
gh() { return 1; }
for tool in git jq go; do command -v "$tool" >/dev/null || { echo "SKIP: $tool required"; exit 0; }; done
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/dsr-source-test.XXXXXXXX") || exit 1
trap '[[ "${DSR_TEST_KEEP_TEMP:-0}" == 1 ]] || rm -rf -- "$TEMP"' EXIT
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
        jq -nc --arg path "$base/output/target/x86_64-test-linux-gnu/release/fixture" \
            '{reason:"compiler-artifact",package_id:"fixture-package",target:{name:"fixture",kind:["bin"]},executable:$path}'
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
for _attempt in {1..50}; do [[ ! -f "$TEMP/term.log" ]] || break; sleep 0.02; done
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
