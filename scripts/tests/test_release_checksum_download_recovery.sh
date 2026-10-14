#!/usr/bin/env bash
# Real curl/TLS integration for retained-download recovery. Only GitHub's
# service boundary is a loopback fixture; no production function/tool is mocked.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
for dependency in python3 curl openssl jq; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
        printf 'SKIP: install %s for HTTPS download recovery tests\n' "$dependency"
        exit 0
    fi
done
python3 -I - "${DSR_TEST_RELEASE_CHECKSUMS_MODULE:-$root/src/release_checksums.sh}" "$@" <<'PY'
import hashlib
from http.server import BaseHTTPRequestHandler
import json
import os
from pathlib import Path
import re
import signal
import socket
import socketserver
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest

MODULE = Path(sys.argv.pop(1)).resolve()
ROOT = Path(tempfile.mkdtemp(prefix='dsr-https-recovery-')).resolve()
TOKEN = 'dsr_fixture_token'

def sha(data):
    return hashlib.sha256(data).hexdigest()


def snapshot(root):
    # Include bytes, permissions and links; no cleanup or rewriting evidence.
    rows = {}
    for path in sorted(root.rglob('*')):
        key = str(path.relative_to(root))
        info = path.lstat()
        rows[key] = (info.st_mode, os.readlink(path) if path.is_symlink() else
                     sha(path.read_bytes()) if path.is_file() else None)
    return rows


class Endpoint(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def response(self, status, body=b'', headers=None):
        self.send_response(status)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Connection', 'close')
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()
        self.close_connection = True

    def do_GET(self):
        state = self.server.state
        state.requests.append(dict(host=self.target_host, path=self.path,
                                   authorization=self.headers.get('Authorization'),
                                   range=self.headers.get('Range')))
        if self.target_host == 'api.github.com':
            if self.headers.get('Authorization') != 'Bearer ' + TOKEN:
                return self.response(401)
            if self.path == '/repos/owner/repo/releases/tags/v1.0.0':
                return self.response(200, json.dumps(state.context).encode())
            if self.path == '/repos/owner/repo/releases/7/assets?per_page=100&page=1':
                state.inventory_reads += 1
                if state.inventory_reads == 2 and state.change_after_download:
                    state.context['prerelease'] = True
                return self.response(200, json.dumps(state.assets()).encode())
            prefix = '/repos/owner/repo/releases/assets/'
            if self.path.startswith(prefix):
                return self.response(302, headers={'Location': 'https://release-assets.githubusercontent.com/asset/' + self.path[len(prefix):]})
        if self.target_host != 'release-assets.githubusercontent.com' or not self.path.startswith('/asset/'):
            return self.response(404)
        # Cross-origin asset redirects must never inherit the API credential.
        if self.headers.get('Authorization') is not None:
            return self.response(403)
        try:
            identifier = int(self.path.rsplit('/', 1)[1])
            data = state.contents()[identifier]
        except (KeyError, ValueError):
            return self.response(404)
        behavior = state.behaviors.get(identifier)
        if behavior == 'blocked':
            return self.response(503)
        requested_range = self.headers.get('Range')
        if behavior == 'require-range' and not requested_range:
            return self.response(503)
        if requested_range and behavior != 'ignore-range':
            match = re.fullmatch(r'bytes=([0-9]+)-', requested_range)
            if match is None or int(match[1]) >= len(data):
                return self.response(416)
            offset = int(match[1])
            suffix = data[offset:]
            content_range = 'bytes %d-%d/%d' % (offset, len(data) - 1, len(data))
            if behavior == 'wrong-range':
                content_range = 'bytes %d-%d/%d' % (offset, len(data) - 1, len(data) + 1)
            if behavior == 'wrong-start':
                content_range = 'bytes %d-%d/%d' % (offset + 1, len(data) - 1, len(data))
            if behavior == 'corrupt-suffix':
                suffix = b'x' * len(suffix)
            self.send_response(206)
            if behavior != 'missing-range':
                self.send_header('Content-Range', content_range)
            if behavior == 'duplicate-range':
                self.send_header('Content-Range', content_range)
            if behavior == 'encoded-range':
                self.send_header('Content-Encoding', 'gzip')
            self.send_header('Connection', 'close')
            chunked = behavior in ('partial-disconnect', 'hold-range', 'excessive-range')
            self.send_header('Transfer-Encoding' if chunked else 'Content-Length',
                             'chunked' if chunked else str(len(suffix)))
            self.end_headers()
            if chunked:
                suffix = suffix + b'x' * 65536 if behavior == 'excessive-range' else suffix[:len(suffix) // 2]
                for start in range(0, len(suffix), 32768):
                    block = suffix[start:start + 32768]
                    self.wfile.write(('%x\r\n' % len(block)).encode() + block + b'\r\n')
                    self.wfile.flush()
                if behavior == 'excessive-range':
                    self.wfile.write(b'0\r\n\r\n')
                elif behavior == 'hold-range':
                    state.holding.set()
                    state.release.wait(timeout=15)
            else:
                self.wfile.write(suffix)
            self.wfile.flush()
            self.close_connection = True
            return
        if behavior in ('complete-disconnect', 'partial-disconnect', 'hold-complete'):
            self.send_response(200)
            self.send_header('Transfer-Encoding', 'chunked')
            self.send_header('Connection', 'close')
            self.end_headers()
            sent = data if behavior != 'partial-disconnect' else data[:len(data) // 2]
            for offset in range(0, len(sent), 32768):
                block = sent[offset:offset + 32768]
                self.wfile.write(('%x\r\n' % len(block)).encode() + block + b'\r\n')
                self.wfile.flush()
            if behavior == 'hold-complete':
                state.holding.set()
                state.release.wait(timeout=15)
            # Deliberately omit the terminating chunk: genuine curl retains
            # downloaded bytes but refuses to certify a completed transfer.
            self.close_connection = True
            return
        return self.response(200, data)


class Proxy(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(20)
        header = b''
        while not header.endswith(b'\r\n\r\n'):
            byte = self.request.recv(1)
            if not byte or len(header) > 8192:
                return
            header += byte
        first = header.split(b'\r\n', 1)[0].split()
        allowed = (b'api.github.com:443', b'release-assets.githubusercontent.com:443')
        if len(first) != 3 or first[0] != b'CONNECT' or first[1] not in allowed:
            self.request.sendall(b'HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n')
            return
        self.request.sendall(b'HTTP/1.1 200 Connection established\r\n\r\n')
        try:
            with self.server.tls.wrap_socket(self.request, server_side=True) as secure:
                class BoundEndpoint(Endpoint):
                    target_host = first[1].decode().rsplit(':', 1)[0]
                BoundEndpoint(secure, self.client_address, self.server)
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError, socket.timeout):
            pass


class Service(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self):
        super().__init__(('127.0.0.1', 0), Proxy)
        self.state = self
        self.tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        self.tls.load_cert_chain(str(ROOT / 'cert.pem'), str(ROOT / 'key.pem'))
        self.payloads = {'a.bin': bytes(range(256)) * 2048, 'b.bin': b'other real payload\n' * 257,
                         'c.bin': b'third payload\0', 'd.bin': b'fourth payload\n'}
        self.context = dict(id=7, tag_name='v1.0.0', draft=False, prerelease=False, target_commitish='a' * 40)
        self.behaviors = {}
        self.requests = []
        self.inventory_reads = 0
        self.change_after_download = False
        self.holding = threading.Event()
        self.release = threading.Event()
        self.thread = threading.Thread(target=self.serve_forever, daemon=True)
        self.thread.start()

    def contents(self):
        result = {}
        for index, (_, data) in enumerate(sorted(self.payloads.items())):
            result[100 + index] = data
            result[200 + index] = (sha(data) + '\n').encode()
        return result

    def assets(self):
        result = []
        for index, (name, data) in enumerate(sorted(self.payloads.items())):
            for identifier, filename in ((100 + index, name), (200 + index, name + '.sha256')):
                content = self.contents()[identifier]
                result.append(dict(id=identifier, name=filename, size=len(content), state='uploaded', digest=None))
        return result

    def close(self):
        self.release.set()
        self.shutdown()
        self.server_close()
        self.thread.join(timeout=5)


class Recovery(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2',
                        '-keyout', str(ROOT / 'key.pem'), '-out', str(ROOT / 'cert.pem'),
                        '-subj', '/CN=api.github.com', '-addext',
                        'subjectAltName=DNS:api.github.com,DNS:release-assets.githubusercontent.com'],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)

    def setUp(self):
        self.work = Path(tempfile.mkdtemp(prefix=self._testMethodName + '-', dir=ROOT))
        self.service = Service()
        self.addCleanup(self.service.close)
        self.env = os.environ.copy()
        for key in list(self.env):
            if key.lower().endswith('_proxy') or key in ('DSR_GH_TOKEN', 'GH_TOKEN', 'GITHUB_TOKEN', 'CURL_CA_BUNDLE', 'SSL_CERT_FILE'):
                self.env.pop(key)
        self.env.update(HTTPS_PROXY='http://127.0.0.1:%d' % self.service.server_address[1],
                        NO_PROXY='', CURL_CA_BUNDLE=str(ROOT / 'cert.pem'), DSR_GH_TOKEN=TOKEN)

    def command(self, output, *extra):
        return ['bash', str(MODULE), '--repo', 'owner/repo', '--tag', 'v1.0.0',
                '--checksum-mode', 'sidecars', '--output-dir', str(output), '--timeout', '10', *map(str, extra)]

    def invoke(self, label, *extra):
        output = self.work / label
        process = subprocess.run(self.command(output, *extra), env=self.env, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, timeout=30)
        (self.work / (label + '.stdout')).write_bytes(process.stdout)
        (self.work / (label + '.stderr')).write_bytes(process.stderr)
        try:
            result = json.loads(process.stdout)
        except ValueError:
            self.fail(process.stderr.decode(errors='replace') + '\n' + repr(process.stdout))
        self.assertEqual(result['exit_code'], process.returncode)
        if (output / 'result.json').exists():
            self.assertEqual(json.loads((output / 'result.json').read_bytes()), result)
        return process.returncode, result, output

    def failed_complete(self, label='original'):
        self.service.behaviors[100] = 'complete-disconnect'
        code, result, output = self.invoke(label)
        self.assertEqual(code, 8, result)
        self.assertEqual(result['verified_count'], 0)
        self.assertEqual((output / 'artifacts/a.bin').read_bytes(), self.service.payloads['a.bin'])
        self.service.behaviors[100] = 'blocked'
        self.service.requests.clear()
        return output

    def assert_complete(self, code, result, output):
        self.assertEqual(code, 0, result)
        self.assertEqual(result['status'], 'verified')
        self.assertIs(result['inventory_stable'], True)
        self.assertIs(result['authenticated'], False)
        self.assertIs(result['source_verified'], False)
        self.assertEqual(result['eligible_count'], 4)
        self.assertEqual(result['verified_checksums'], sorted(self.service.payloads))
        self.assertEqual(result['verified_count'], 4)
        for name, data in self.service.payloads.items():
            self.assertEqual((output / 'artifacts' / name).read_bytes(), data)
        self.assertEqual((output / 'checksums.normalized').read_text(),
                         ''.join(sha(data) + '  ' + name + '\n' for name, data in sorted(self.service.payloads.items())))

    def assert_fresh_evidence(self):
        requested = [r['path'] for r in self.service.requests if r['host'] == 'release-assets.githubusercontent.com']
        for number in range(200, 204):
            self.assertIn('/asset/%d' % number, requested)
        for request in self.service.requests:
            self.assertEqual(request['authorization'], 'Bearer ' + TOKEN if request['host'] == 'api.github.com' else None)

    def test_ordinary_complete_transport(self):
        self.assert_complete(*self.invoke('fresh'))
        self.assert_fresh_evidence()

    def test_terminal_uncheckpointed_download_recovers_without_redownload(self):
        old = self.failed_complete()
        before = snapshot(old)
        code, result, output = self.invoke('resumed', '--resume-from', old)
        self.assert_complete(code, result, output)
        self.assertEqual(result['resume']['recovered_checksums'], ['a.bin'])
        self.assertEqual(result['resume']['recovered_count'], 1)
        self.assertEqual(result['resume']['recovered_bytes'], len(self.service.payloads['a.bin']))
        self.assertEqual(result['resume']['reused_count'], 0)
        self.assertFalse(any(r['path'].endswith('/100') for r in self.service.requests))
        self.assert_fresh_evidence()
        self.assertEqual(snapshot(old), before)

    def test_sigkill_after_full_body_before_checkpoint_recovers(self):
        old = self.work / 'killed'
        self.service.behaviors[100] = 'hold-complete'
        process = subprocess.Popen(self.command(old), env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.assertTrue(self.service.holding.wait(timeout=10), 'curl never reached the held payload')
            # Pause the supervisor while curl is still active, then let the
            # real transfer fail and flush its last stdio buffer. Killing the
            # paused supervisor now leaves an actual full, uncheckpointed
            # download, not a hand-written progress/terminal fixture.
            os.kill(process.pid, signal.SIGSTOP)
            self.service.release.set()
            deadline = time.monotonic() + 5
            payload = old / 'artifacts/a.bin'
            while time.monotonic() < deadline and (not payload.exists() or payload.stat().st_size != len(self.service.payloads['a.bin'])):
                time.sleep(0.01)
            self.assertEqual(payload.stat().st_size, len(self.service.payloads['a.bin']))
            process.kill()
            process.communicate(timeout=5)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=5)
            self.service.release.set()
        self.assertFalse((old / 'result.json').exists())
        self.assertEqual(len((old / 'verified.jsonl').read_bytes().splitlines()), 1)
        before = snapshot(old)
        self.service.behaviors[100] = 'blocked'
        self.service.requests.clear()
        code, result, output = self.invoke('resumed', '--resume-from', old)
        self.assert_complete(code, result, output)
        self.assertEqual(result['resume']['source_terminal_outcome'], 'unknown')
        self.assertEqual(result['resume']['recovered_checksums'], ['a.bin'])
        self.assertFalse(any(r['path'].endswith('/100') for r in self.service.requests))
        self.assertEqual(snapshot(old), before)

    def test_corrupt_uncheckpointed_download_is_not_silently_replaced(self):
        old = self.failed_complete()
        payload = old / 'artifacts/a.bin'
        payload.write_bytes(b'x' * payload.stat().st_size)
        before = snapshot(old)
        self.service.behaviors.clear()
        code, result, output = self.invoke('refused', '--resume-from', old)
        self.assertNotEqual(code, 0, result)
        self.assertIn('Retained', result['error'])
        self.assertEqual(result['verified_count'], 0)
        self.assertFalse((output / 'checksums.normalized').exists())
        self.assertEqual(snapshot(old), before)

    def test_linked_uncheckpointed_download_is_refused(self):
        old = self.failed_complete()
        payload = old / 'artifacts/a.bin'
        payload.rename(old / 'retained-original.bin')
        payload.symlink_to('../retained-original.bin')
        before = snapshot(old)
        self.service.behaviors.clear()
        code, result, _ = self.invoke('refused', '--resume-from', old)
        self.assertNotEqual(code, 0, result)
        self.assertEqual(snapshot(old), before)

    def test_oversized_uncheckpointed_download_is_refused(self):
        old = self.failed_complete()
        with (old / 'artifacts/a.bin').open('ab') as stream:
            stream.write(b'x')
        before = snapshot(old)
        self.service.behaviors.clear()
        code, result, _ = self.invoke('refused', '--resume-from', old)
        self.assertNotEqual(code, 0, result)
        self.assertEqual(snapshot(old), before)

    def test_partial_transfer_is_not_counted_as_complete_recovery(self):
        self.service.behaviors[100] = 'partial-disconnect'
        code, result, old = self.invoke('original')
        self.assertEqual(code, 8, result)
        self.assertLess((old / 'artifacts/a.bin').stat().st_size, len(self.service.payloads['a.bin']))
        before = snapshot(old)
        self.service.behaviors.clear()
        code, result, output = self.invoke('resumed', '--resume-from', old)
        self.assert_complete(code, result, output)
        self.assertEqual(result['resume'].get('recovered_count', 0), 0)
        self.assertEqual(result['resume']['continued_count'], 1)
        self.assertEqual(result['resume']['continued_bytes'], len(self.service.payloads['a.bin']) // 2)
        self.assertEqual(snapshot(old), before)

    def failed_partial(self):
        self.service.behaviors[100] = 'partial-disconnect'
        code, result, old = self.invoke('original')
        self.assertEqual(code, 8, result)
        self.assertEqual((old / 'artifacts/a.bin').stat().st_size, len(self.service.payloads['a.bin']) // 2)
        self.service.behaviors.clear()
        self.service.requests.clear()
        return old

    def test_range_fetches_only_suffix_through_authenticated_redirect(self):
        old = self.failed_partial()
        before = snapshot(old)
        self.service.behaviors[100] = 'require-range'
        code, result, output = self.invoke('resumed', '--resume-from', old)
        self.assert_complete(code, result, output)
        transfers = result['resume']['partial_transfers']
        self.assertEqual(transfers, [dict(name='a.bin', offset=262144, outcome='continued', verified=True,
                                        prefix_sha256=sha(self.service.payloads['a.bin'][:262144]))])
        requests = [r for r in self.service.requests if r['path'].endswith('/100')]
        self.assertEqual(len(requests), 2)
        self.assertTrue(all(r['range'] == 'bytes=262144-' for r in requests))
        self.assert_fresh_evidence()
        self.assertEqual(snapshot(old), before)

    def test_server_ignoring_range_restarts_once_without_overwriting_prefix(self):
        old = self.failed_partial()
        before = snapshot(old)
        self.service.behaviors[100] = 'ignore-range'
        code, result, output = self.invoke('resumed', '--resume-from', old)
        self.assert_complete(code, result, output)
        self.assertEqual(result['resume']['continued_count'], 0)
        self.assertEqual(result['resume']['continued_bytes'], 0)
        self.assertEqual(result['resume']['restarted_count'], 1)
        requested = [r['range'] for r in self.service.requests if r['path'] == '/asset/100']
        self.assertEqual(requested, ['bytes=262144-', None])
        retained = list((output / 'requests').glob('*.unused-prefix'))
        self.assertEqual(len(retained), 1)
        self.assertEqual(retained[0].read_bytes(), self.service.payloads['a.bin'][:262144])
        self.assertEqual(snapshot(old), before)

    def test_repeated_transfer_failure_continues_from_new_longer_prefix(self):
        old = self.failed_partial()
        before = snapshot(old)
        self.service.behaviors[100] = 'partial-disconnect'
        code, result, middle = self.invoke('interrupted-again', '--resume-from', old)
        self.assertEqual(code, 8, result)
        self.assertEqual(result['verified_count'], 0)
        self.assertEqual(result['resume']['continued_count'], 0)
        self.assertFalse((middle / 'checksums.normalized').exists())
        self.assertEqual((middle / 'artifacts/a.bin').stat().st_size, 393216)
        self.assertEqual(snapshot(old), before)
        middle_before = snapshot(middle)
        self.service.behaviors.clear()
        self.service.requests.clear()
        code, result, output = self.invoke('complete', '--resume-from', middle)
        self.assert_complete(code, result, output)
        self.assertEqual(result['resume']['continued_bytes'], 393216)
        requested = [r['range'] for r in self.service.requests if r['path'] == '/asset/100']
        self.assertEqual(requested, ['bytes=393216-'])
        self.assertEqual(snapshot(middle), middle_before)

    def test_invalid_range_responses_never_fall_back_or_claim_coverage(self):
        old = self.failed_partial()
        before = snapshot(old)
        for behavior in ('wrong-range', 'wrong-start', 'missing-range', 'duplicate-range',
                         'encoded-range', 'corrupt-suffix', 'excessive-range'):
            with self.subTest(behavior=behavior):
                self.service.behaviors[100] = behavior
                self.service.requests.clear()
                code, result, output = self.invoke(behavior, '--resume-from', old)
                self.assertNotEqual(code, 0, result)
                self.assertEqual(result['verified_count'], 0)
                self.assertEqual(result['resume']['continued_count'], 0)
                self.assertFalse((output / 'checksums.normalized').exists())
                requests = [r for r in self.service.requests if r['path'] == '/asset/100']
                self.assertEqual(len(requests), 1)
                self.assertEqual(requests[0]['range'], 'bytes=262144-')
                self.assertEqual(snapshot(old), before)
                if (output / 'artifacts/a.bin').exists():
                    self.assertLessEqual((output / 'artifacts/a.bin').stat().st_size, 524288)

    def test_killed_range_continuation_retains_growing_prefix_for_next_resume(self):
        old = self.failed_partial()
        before = snapshot(old)
        middle = self.work / 'killed-range'
        self.service.behaviors[100] = 'hold-range'
        process = subprocess.Popen(self.command(middle, '--resume-from', old), env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.assertTrue(self.service.holding.wait(timeout=10))
            os.kill(process.pid, signal.SIGSTOP)
            self.service.release.set()
            deadline = time.monotonic() + 5
            payload = middle / 'artifacts/a.bin'
            while time.monotonic() < deadline and (not payload.exists() or payload.stat().st_size != 393216):
                time.sleep(0.01)
            self.assertEqual(payload.stat().st_size, 393216)
            process.kill()
            process.communicate(timeout=5)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=5)
            self.service.release.set()
        self.assertFalse((middle / 'result.json').exists())
        middle_before = snapshot(middle)
        self.service.behaviors.clear()
        self.service.requests.clear()
        code, result, output = self.invoke('completed', '--resume-from', middle)
        self.assert_complete(code, result, output)
        self.assertEqual(result['resume']['continued_bytes'], 393216)
        self.assertEqual(result['resume']['source_terminal_outcome'], 'unknown')
        self.assertEqual(snapshot(middle), middle_before)
        self.assertEqual(snapshot(old), before)

    def test_modified_partial_prefix_is_never_admitted_by_valid_suffix(self):
        old = self.failed_partial()
        payload = old / 'artifacts/a.bin'
        payload.write_bytes(b'x' * payload.stat().st_size)
        before = snapshot(old)
        code, result, output = self.invoke('refused', '--resume-from', old)
        self.assertNotEqual(code, 0, result)
        self.assertIn('checksum mismatch', result['error'])
        self.assertEqual(result['verified_count'], 0)
        self.assertFalse((output / 'checksums.normalized').exists())
        self.assertEqual(snapshot(old), before)

    def test_verified_resume_still_rehashes_without_payload_requests(self):
        code, result, old = self.invoke('original')
        self.assert_complete(code, result, old)
        before = snapshot(old)
        self.service.behaviors.update({n: 'blocked' for n in range(100, 104)})
        self.service.requests.clear()
        code, result, output = self.invoke('resumed', '--resume-from', old)
        self.assert_complete(code, result, output)
        self.assertEqual(result['resume']['reused_count'], 4)
        self.assertFalse(any(r['path'].endswith('/%d' % n) for r in self.service.requests for n in range(100, 104)))
        self.assert_fresh_evidence()
        self.assertEqual(snapshot(old), before)

    def test_inventory_change_prevents_recovery(self):
        old = self.failed_complete()
        before = snapshot(old)
        self.service.context['id'] = 9
        code, result, _ = self.invoke('refused', '--resume-from', old)
        self.assertNotEqual(code, 0, result)
        self.assertEqual(result['verified_count'], 0)
        self.assertEqual(snapshot(old), before)

    def test_post_download_inventory_drift_withholds_success(self):
        old = self.failed_complete()
        self.service.inventory_reads = 0
        self.service.change_after_download = True
        code, result, output = self.invoke('refused', '--resume-from', old)
        self.assertNotEqual(code, 0, result)
        self.assertEqual(result['verified_count'], 4)
        self.assertEqual(result['resume']['recovered_count'], 1)
        self.assertIn('changed during verification', result['error'])
        self.assertFalse(result['inventory_stable'])
        self.assertFalse((output / 'checksums.normalized').exists())


print('HTTPS recovery fixtures retained at ' + str(ROOT), file=sys.stderr)
unittest.main(argv=[sys.argv[0], *sys.argv[1:]], verbosity=2)
PY
