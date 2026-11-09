#!/usr/bin/env bash
# Real loopback HTTP, curl, pipes and private files exercise download bounds.
# Only GitHub authentication and URL routing are fixtures; no remote service,
# release, credential or executable payload is used.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
for dependency in bash python3 jq curl; do
    command -v "$dependency" >/dev/null || { printf 'Missing dependency: %s\n' "$dependency" >&2; exit 3; }
done
python3 - "$ROOT" <<'PY'
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time

root = Path(sys.argv[1])
work = Path(tempfile.mkdtemp(prefix='dsr-download-bounds-')).resolve()
print('Retained evidence: ' + str(work), flush=True)
cases = {}
passed = 0

def check(label, condition):
    global passed
    if not condition:
        raise AssertionError(label)
    passed += 1
    print('PASS: ' + label, flush=True)

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def do_GET(self):
        spec = cases[self.path]
        row = dict(sent=0, disconnected=False, headers=dict(self.headers), complete=False)
        spec['requests'].append(row)
        status = 503 if spec.get('retry') and len(spec['requests']) == 1 else spec.get('status', 200)
        body = b'' if status != 200 else spec['body']
        framing = spec.get('framing', 'length')
        self.send_response(status)
        if framing == 'chunked':
            self.send_header('Transfer-Encoding', 'chunked')
        elif framing == 'length':
            self.send_header('Content-Length', str(len(body) + spec.get('missing', 0)))
        self.send_header('Connection', 'close')
        self.end_headers()
        try:
            for offset in range(0, len(body), 4096):
                block = body[offset:offset + 4096]
                if framing == 'chunked':
                    self.wfile.write(('%x\r\n' % len(block)).encode())
                self.wfile.write(block)
                if framing == 'chunked':
                    self.wfile.write(b'\r\n')
                self.wfile.flush()
                row['sent'] += len(block)
                if spec.get('stall') and offset == 0:
                    time.sleep(2)
                if len(body) > 65536:
                    time.sleep(.001)
            if framing == 'chunked':
                self.wfile.write(b'0\r\n\r\n')
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            row['disconnected'] = True
        finally:
            self.close_connection = True
            row['complete'] = True

server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
script = work / 'invoke.sh'
script.write_text(r'''#!/usr/bin/env bash
set -uo pipefail
source "$BOUND_ROOT/src/guardrails.sh"
source "$BOUND_ROOT/src/secrets.sh"
source "$BOUND_GITHUB_MODULE"
source "$BOUND_ROOT/src/sbom.sh"
source "$BOUND_ROOT/src/sbom_release.sh"
source "$BOUND_ROOT/src/slsa.sh"
source "$BOUND_ROOT/src/slsa_remote.sh"
source "$BOUND_ROOT/src/release_integrity.sh"
export DSR_GH_TOKEN=bounded-download-fixture GH_DOWNLOAD_TIMEOUT="$BOUND_TIMEOUT" GH_DOWNLOAD_CONNECT_TIMEOUT=2
export GH_MAX_RETRIES="$BOUND_RETRIES" GH_RETRY_DELAY=0 SBOM_REMOTE_TIMEOUT=6
_gh_check_cli_auth() {
    printf 'auth\n' >> "$BOUND_CASE/auth.calls"
    [[ "$BOUND_TRANSPORT" == gh ]] && return 0
    return 1
}
_gh_resolve_token() { printf '%s' bounded-download-fixture; }
curl() {
    local arg
    local -a args=()
    for arg in "$@"; do
        if [[ "$arg" == https://api.github.com/repos/owner/repo/releases/assets/17 ]]; then
            arg="$BOUND_HTTP_URL"
        fi
        args+=("$arg")
    done
    command "$BOUND_CURL" --noproxy 127.0.0.1 "${args[@]}"
}
gh() {
    [[ "${1:-}" == api ]] || return 99
    printf 'transfer\n' >> "$BOUND_CASE/cli.calls"
    cat "$BOUND_CASE/body"
    return "$BOUND_CLI_STATUS"
}
# Observe the actual private file immediately after the production writer
# exits, before the downloader cleans its failed staging. No result is altered.
if declare -F _gh_copy_download_body >/dev/null; then
    definition=$(declare -f _gh_copy_download_body)
    eval "_bound_original_copy${definition#_gh_copy_download_body}"
    _gh_copy_download_body() {
        local rc=0
        _bound_original_copy "$@" || rc=$?
        python3 - "$1" "$2" "$rc" "$BOUND_CASE/copies.jsonl" <<'OBSERVE'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
with open(sys.argv[4], 'a') as output:
    output.write(json.dumps(dict(path=str(path), maximum=int(sys.argv[2]), code=int(sys.argv[3]),
                                size=path.stat().st_size if path.exists() else None))+'\n')
OBSERVE
        return "$rc"
    }
fi
if [[ "$BOUND_EXPORTED" == true ]]; then
    export -f _gh_check_cli_auth _gh_resolve_token curl gh
    if declare -F _bound_original_copy >/dev/null; then
        export -f _bound_original_copy _gh_copy_download_body
    fi
    bash -u -c 'gh_download_release_asset owner/repo 17 "$BOUND_CASE/destination" "$BOUND_LIMIT"'
    exit $?
fi
asset=$(jq -cn --argjson size "$BOUND_SIZE" --arg digest "$BOUND_DIGEST" \
    '{id:17,name:"release.json",state:"uploaded",size:$size,digest:(if $digest=="" then null else $digest end)}')
case "$BOUND_ACTION" in
    download)
        if [[ "$BOUND_LIMIT" == omitted ]]; then
            gh_download_release_asset owner/repo 17 "$BOUND_CASE/destination"
        else
            gh_download_release_asset owner/repo 17 "$BOUND_CASE/destination" "$BOUND_LIMIT"
        fi ;;
    sbom) _sbr_download owner/repo "$asset" "$BOUND_HASH" "$BOUND_CASE" true ;;
    slsa) _slr_document owner/repo "$asset" "$BOUND_CASE" 65536 ;;
    integrity) _ri_download_unpinned owner/repo "$asset" "$BOUND_CASE" ;;
    upload) _gh_verify_uploaded_asset owner/repo release.json "$BOUND_SIZE" "$BOUND_HASH" "$asset" "$BOUND_CASE" ;;
    *) exit 99 ;;
esac
''')
module = Path(os.environ.get('DSR_TEST_GITHUB_MODULE', str(root / 'src/github.sh'))).resolve()
payload = b'release\0payload\xff\n' * 33
large = b'x' * (2 * 1024 * 1024)

def execute(label, body=payload, limit=None, expected=0, framing='length', action='download',
            transport='curl', status=200, retry=False, missing=0, selected=None, hash_value=None,
            digest=None, cli_status=0, occupied=False, exported=False, stall=False):
    directory = work / label
    directory.mkdir()
    (directory / 'body').write_bytes(body)
    selected = len(body) if selected is None else selected
    pin = hashlib.sha256(body).hexdigest() if hash_value is None else hash_value
    case = dict(body=body, framing=framing, status=status, retry=retry, missing=missing, stall=stall, requests=[])
    cases['/' + label] = case
    environment = {k:v for k,v in os.environ.items() if not k.startswith('BASH_FUNC_') and k not in ('BASH_ENV','ENV')}
    environment.update(BOUND_ROOT=str(root), BOUND_GITHUB_MODULE=str(module), BOUND_CASE=str(directory),
        BOUND_CURL=shutil.which('curl'), BOUND_HTTP_URL='http://127.0.0.1:%d/%s' % (server.server_port, label),
        BOUND_LIMIT=str(selected if limit is None else limit), BOUND_ACTION=action, BOUND_TRANSPORT=transport,
        BOUND_SIZE=str(selected), BOUND_HASH=pin, BOUND_DIGEST=('sha256:' + pin) if digest is None else digest,
        BOUND_CLI_STATUS=str(cli_status), BOUND_EXPORTED=str(exported).lower(),
        BOUND_TIMEOUT='1' if stall else '4', BOUND_RETRIES='1' if stall else '2')
    before = None
    if occupied:
        (directory / 'destination').write_bytes(b'previous owned bytes')
        before = (directory / 'destination').stat().st_ino
    started = time.monotonic()
    result = subprocess.run(['bash', str(script)], env=environment, capture_output=True, timeout=12)
    elapsed = time.monotonic() - started
    (directory / 'stdout').write_bytes(result.stdout)
    (directory / 'stderr').write_bytes(result.stderr)
    deadline = time.monotonic() + 2
    while any(not r['complete'] for r in case['requests']) and time.monotonic() < deadline:
        time.sleep(.01)
    observations = dict(returncode=result.returncode, duration_seconds=elapsed, requests=case['requests'])
    (directory / 'result.json').write_text(json.dumps(observations, sort_keys=True) + '\n')
    check(label + ' preserves expected status', result.returncode in (expected if isinstance(expected, tuple) else (expected,)))
    copies = [json.loads(line) for line in (directory / 'copies.jsonl').read_text().splitlines()] \
        if (directory / 'copies.jsonl').exists() else []
    if limit != 'omitted' and copies:
        check(label + ' never retains more than admitted bytes',
              all(row['size'] is None or row['size'] <= row['maximum'] for row in copies))
    if expected == 0:
        if action == 'download':
            check(label + ' preserves exact binary bytes', (directory / 'destination').read_bytes() == body)
            check(label + ' emits no body or metadata on stdout', not result.stdout)
        elif action != 'upload':
            check(label + ' returns exact verified file', Path(os.fsdecode(result.stdout).strip()).read_bytes() == body)
    else:
        check(label + ' emits no success receipt', not result.stdout)
        if occupied:
            check(label + ' preserves occupied destination bytes and inode',
                  (directory / 'destination').read_bytes() == b'previous owned bytes' and
                  (directory / 'destination').stat().st_ino == before)
        else:
            check(label + ' publishes no destination', not (directory / 'destination').exists())
            if any(row['code'] == 63 for row in copies):
                check(label + ' never admits oversized private body',
                      not list(directory.glob('download.*/body')) and not list(directory.glob('proof.*/body')) and
                      not list(directory.glob('unsigned.*/body')) and not (directory / 'verified').exists())
    check(label + ' leaves no transport staging', not list(directory.rglob('.dsr-asset-download.*')))
    for row in case['requests']:
        check(label + ' keeps authenticated octet-stream request',
              row['headers'].get('Authorization') == 'Bearer bounded-download-fixture' and
              row['headers'].get('Accept') == 'application/octet-stream')
    return directory, case, copies

try:
    execute('exact-chunked', framing='chunked')
    execute('empty', body=b'', limit=0)
    execute('unbounded-compatibility', limit='omitted')
    for framing in ('length', 'chunked', 'close'):
        directory, case, copies = execute('overflow-' + framing, body=large, limit=8192, expected=63, framing=framing)
        check(framing + ' overflow stops real HTTP transfer early',
              len(case['requests']) == 1 and case['requests'][0]['disconnected'] and case['requests'][0]['sent'] < len(large))
        check(framing + ' overflow is a definitive bounded-writer refusal',
              len(copies) == 1 and copies[0]['code'] == 63 and copies[0]['size'] == 8192)
    execute('gh-exact', transport='gh')
    directory, _, copies = execute('gh-overflow', body=large, limit=8192, expected=63, transport='gh')
    check('gh overflow never retries an oversized body', (directory / 'cli.calls').read_text().splitlines() == ['transfer'])
    execute('gh-auth-failure', transport='gh', cli_status=4, expected=4)
    execute('gh-cancellation', transport='gh', cli_status=130, expected=130)
    execute('exported-curl-exact', exported=True)
    execute('exported-gh-overflow', body=large, limit=8192, expected=63, transport='gh', exported=True)
    directory, case, _ = execute('bounded-timeout', body=large, stall=True, expected=(28, 124))
    check('bounded timeout terminates its HTTP producer',
          len(case['requests']) == 1 and case['requests'][0]['complete'] and case['requests'][0]['disconnected'])
    directory, case, _ = execute('http-404', status=404, expected=22)
    check('HTTP 404 remains non-retryable', len(case['requests']) == 1)
    directory, case, copies = execute('http-retry', retry=True)
    check('transient HTTP read retries with distinct bounded staging',
          len(case['requests']) == len(copies) == 2 and copies[0]['path'] != copies[1]['path'])
    directory, case, _ = execute('short-http-body', missing=20, expected=18)
    check('truncated HTTP response retains bounded retry semantics', len(case['requests']) == 2)
    execute('occupied', occupied=True, expected=4)
    for index, limit in enumerate(('', '-1', '01', '1.5', '9007199254740992')):
        directory, case, _ = execute('invalid-limit-%d' % index, limit=limit, expected=4)
        check('invalid byte limit refuses before authentication', not case['requests'] and not (directory / 'auth.calls').exists())
    for action in ('sbom', 'slsa', 'integrity'):
        execute(action + '-exact', action=action)
        directory, case, copies = execute(action + '-oversized', body=large, selected=8192, action=action,
                                         expected=7, framing='chunked', digest='')
        check(action + ' maps overlong body to integrity failure without retry',
              len(case['requests']) == len(copies) == 1 and copies[0]['code'] == 63)
    execute('sbom-wrong-hash', action='sbom', hash_value='0' * 64, expected=7)
    execute('sbom-short-body', action='sbom', selected=len(payload) + 1, expected=7)
    execute('upload-legacy-exact', action='upload', digest='')
    execute('upload-legacy-oversized', body=large, selected=8192, action='upload', expected=7, digest='')
    print('Download bounds: %d checks passed' % passed, flush=True)
finally:
    server.shutdown()
    server.server_close()
    thread.join(timeout=2)
PY
