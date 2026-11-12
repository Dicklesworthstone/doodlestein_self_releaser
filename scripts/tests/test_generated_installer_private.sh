#!/usr/bin/env bash
# Generated Bash installers against a local HTTPS GitHub release API.
# Genuine curl/TLS, compiled executable families, Minisign and filesystem
# installation; the adapter changes DNS routing and trust for fixture origins.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for dependency in python3 openssl curl cc jq yq minisign git go; do
    command -v "$dependency" >/dev/null 2>&1 || {
        printf 'SKIP: %s required\n' "$dependency"; exit 3;
    }
done

python3 - "$ROOT" "${1:-}" <<'PY'
import base64
import hashlib
import http.server
import json
import os
import pathlib
import select
import shutil
import socket
import socketserver
import ssl
import subprocess
import sys
import tarfile
import tempfile
import threading
import urllib.parse

root = pathlib.Path(sys.argv[1])
freshness_only = sys.argv[2] == "--freshness-only"
if sys.argv[2] not in ("", "--freshness-only"):
    raise SystemExit("Usage: test_generated_installer_private.sh [--freshness-only]")
work = pathlib.Path(tempfile.mkdtemp(prefix="dsr-private-bash-"))
print(f"Private Bash installer fixtures retained at: {work}", flush=True)
for part in ("config/repos.d", "payload", "bin", "home", "tls"):
    (work / part).mkdir(parents=True, exist_ok=True)

passed = failed = 0


def check(label, condition):
    global passed, failed
    if condition:
        passed += 1
        print("ok - " + label, flush=True)
    else:
        failed += 1
        print("not ok - " + label, flush=True)


def command(arguments, **kwargs):
    result = subprocess.run(arguments, capture_output=True, text=True, timeout=60, **kwargs)
    if result.returncode:
        raise RuntimeError(f"Fixture command failed: {arguments[0]}\n{result.stderr}")
    return result.stdout


system = os.uname().sysname.lower()
architecture = {"x86_64": "amd64", "aarch64": "arm64", "arm64": "arm64"}.get(os.uname().machine)
if system not in ("linux", "darwin") or not architecture:
    print("SKIP: native Unix C compiler host required")
    sys.exit(3)

source = work / "fixture.c"
source.write_text('#include <stdio.h>\nint main(void) { puts(ROLE " 1.2.3"); return 0; }\n')
for name in ("demo", "demo-worker"):
    command([shutil.which("cc"), f'-DROLE="{name}"', str(source), "-o", str(work / "payload" / name)])
command([shutil.which("minisign"), "-G", "-W", "-p", str(work / "public.key"), "-s", str(work / "secret.key")])
public_key = (work / "public.key").read_text().splitlines()[-1]
(work / "config/repos.d/demo.yaml").write_text(
    "tool_name: demo\nrepo: example/demo\nbinary_name: demo\nlanguage: go\n"
    "workspace_binaries: [demo, demo-worker]\n"
    "artifact_naming: ${name}-${version}-${os}-${arch}\n"
    f"minisign_pubkey: {public_key}\n"
)
environment = os.environ.copy()
for name in ("DSR_GH_TOKEN", "GITHUB_TOKEN", "GH_TOKEN", "GH_HOST", "GH_REPO"):
    environment.pop(name, None)
environment.update(DSR_CONFIG_DIR=str(work / "config"), DSR_INSTALLER_DIR=str(work / "generated"),
                   HOME=str(work / "home"), NO_COLOR="1", GOMAXPROCS="2")
module = os.environ.get("DSR_INSTALL_GEN_MODULE", str(root / "src/install_gen.sh"))
installer = pathlib.Path(command(
    ["/bin/bash", "-c", 'source "$1"; install_gen_create demo', "bash", module], env=environment
).strip())
command(["/bin/bash", "-n", str(installer)])

# The stale release route fetches and compiles these actual Git commits. The
# tag is annotated, so freshness must compare its peeled commit, not a tag ID.
git = shutil.which("git")
go = shutil.which("go")
if not command([go, "version"]).startswith("go version go"):
    raise SystemExit("A genuine Go compiler is required for private source fixtures")
git_environment = environment.copy()
for name in list(git_environment):
    if name.startswith("GIT_") or name.lower().endswith("_proxy"):
        git_environment.pop(name)
git_environment.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null")
upstream = work / "upstream"
command([git, "init", "-q", "-b", "main", str(upstream)], env=git_environment)
(upstream / "go.mod").write_text("module example/demo\n\ngo 1.20\n")


def source_revision(revision):
    for name in ("demo", "demo-worker"):
        entry = upstream / "cmd" / name
        entry.mkdir(parents=True, exist_ok=True)
        (entry / "main.go").write_text(
            'package main\nimport "fmt"\nfunc main() { fmt.Println("' + name + '-' + revision + '") }\n')
    command([git, "-C", str(upstream), "add", "."], env=git_environment)
    command([git, "-C", str(upstream), "-c", "user.name=DSR Fixture", "-c",
             "user.email=dsr-fixture@example.invalid", "commit", "-qm", revision], env=git_environment)
    return command([git, "-C", str(upstream), "rev-parse", "HEAD"], env=git_environment).strip()


release_commit = source_revision("tagged")
command([git, "-C", str(upstream), "-c", "user.name=DSR Fixture", "-c",
         "user.email=dsr-fixture@example.invalid", "tag", "-a", "v1.2.3", "-m", "release tag"], env=git_environment)
head_commit = source_revision("observed-head")
remotes = work / "remotes"
(remotes / "example").mkdir(parents=True)
command([git, "clone", "-q", "--bare", str(upstream), str(remotes / "example/demo.git")], env=git_environment)
git_backend = pathlib.Path(command([git, "--exec-path"], env=git_environment).strip()) / "git-http-backend"
if not git_backend.is_file():
    raise SystemExit("The genuine Git HTTP backend is required")

archive = work / "fixture.tar.gz"
with tarfile.open(archive, "w:gz") as output:
    for name in ("demo", "demo-worker"):
        output.add(work / "payload" / name, arcname=name)
command([shutil.which("minisign"), "-S", "-s", str(work / "secret.key"),
         "-m", str(archive), "-x", str(work / "fixture.minisig")])
payload = archive.read_bytes()
signature = (work / "fixture.minisig").read_bytes()
tokens = {"dsr": "ghp_dsr_private_fixture", "github": "ghp_ci_private_fixture", "gh": "ghp_cli_private_fixture"}
requests = []
state = {"label": "", "mode": "", "tag": "v1.2.3", "token": tokens["dsr"], "public": False}


def asset_name():
    version = state["tag"]
    if version.startswith("v"):
        version = version[1:]
    return f"demo-{version}-{system}-{architecture}.tar.gz"


def bodies():
    checksum = hashlib.sha256(payload).hexdigest()
    if state["mode"] == "wrong-checksum":
        checksum = "0" * 64
    return {7: payload, 8: f"{checksum}  {asset_name()}\n".encode(),
            9: b"invalid Minisign signature\n" if state["mode"] == "wrong-signature" else signature,
            10: f"{hashlib.sha256(payload).hexdigest()}  {asset_name()}\n".encode()}


def inventory():
    data = bodies()
    selected = [
        {"id": 7, "name": asset_name(), "size": len(data[7]), "state": "uploaded"},
        {"id": 8, "name": "SHA256SUMS", "size": len(data[8]), "state": "uploaded"},
        {"id": 9, "name": asset_name() + ".minisig", "size": len(data[9]), "state": "uploaded"},
    ]
    mode = state["mode"]
    padding = 100
    if mode == "empty-last":
        padding = 97
    elif mode == "singleton-last":
        padding = 98
    if mode == "duplicate-name":
        selected.append({**selected[0], "id": 70})
    elif mode == "duplicate-id":
        selected.append({**selected[0], "name": "another-artifact"})
    elif mode == "missing-primary":
        selected = selected[1:]
    elif mode == "missing-checksum":
        selected = [row for row in selected if row["id"] != 8]
    elif mode == "missing-signature":
        selected = selected[:2]
    elif mode == "incomplete":
        selected[0]["state"] = "starter"
    elif mode == "zero-size":
        selected[0]["size"] = 0
    elif mode == "short-body":
        selected[0]["size"] += 1
    elif mode == "oversized-body":
        selected[0]["size"] -= 1
    elif mode == "string-id":
        selected[0]["id"] = "7"
    elif mode in ("checksum-403", "checksum-404"):
        # A valid later checksum must not hide a failed discovered member.
        selected.append({"id": 10, "name": "checksums.txt", "size": len(data[10]), "state": "uploaded"})
    # The actual first HTTP page exceeds a single-argument exec limit.
    rows = [{"id": 1000 + index, "name": f"unrelated-{index}", "size": 1,
             "state": "uploaded", "label": "fixture-metadata-" + "x" * 1800}
            for index in range(padding)]
    return rows + selected


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, status, body=b"", location=None, headers=None):
        self.record["response_bytes"] = len(body)
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        for name, value in (headers or {}).items():
            if name.lower() not in ("content-length", "connection"):
                self.send_header(name, value)
        if location is not None:
            self.send_header("Location", location)
        self.end_headers()
        if body:
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
                pass  # Deliberately oversized metadata is refused by the client.

    def do_GET(self):
        host = self.headers.get("Host", "").split(":")[0]
        parsed = urllib.parse.urlsplit(self.path)
        path = urllib.parse.unquote(parsed.path)
        authorization = self.headers.get("Authorization", "")
        self.record = {"label": state["label"], "host": host, "path": self.path,
                       "authorization_sha256": hashlib.sha256(authorization.encode()).hexdigest() if authorization else None,
                       "accept": self.headers.get("Accept"), "user_agent": self.headers.get("User-Agent"),
                       "ambient_header": self.headers.get("X-Fixture-Ambient")}
        requests.append(self.record)
        mode = state["mode"]
        if host in ("objects.fixture.example", "second.fixture.example", "elsewhere.fixture.example"):
            if authorization:
                self.reply(403)
            elif mode == "redirect-back":
                self.reply(302, location="https://api.github.com/repos/example/demo/releases/assets/7?returned=1")
            elif mode == "redirect-chain" and host == "objects.fixture.example":
                self.reply(302, location="https://second.fixture.example/payload?sig=private-object-signature")
            else:
                identity = int(urllib.parse.parse_qs(parsed.query).get("asset", ["7"])[0])
                self.reply(200, bodies()[identity])
            return
        if host == "github.com":
            if path.startswith("/example/demo.git/"):
                expected = "Basic " + base64.b64encode(("x-access-token:" + state["token"]).encode()).decode()
                if authorization != expected or mode == "freshness-git-denied":
                    self.reply(401, headers={"WWW-Authenticate": 'Basic realm="Git fixture"'})
                    return
                incoming = self.rfile.read(int(self.headers.get("Content-Length", "0")))
                backend_env = dict(git_environment, GIT_PROJECT_ROOT=str(remotes), GIT_HTTP_EXPORT_ALL="1",
                    REQUEST_METHOD=self.command, PATH_INFO=parsed.path, QUERY_STRING=parsed.query,
                    CONTENT_TYPE=self.headers.get("Content-Type", ""), CONTENT_LENGTH=str(len(incoming)),
                    SERVER_PROTOCOL="HTTP/1.1", REMOTE_USER="fixture",
                    HTTP_GIT_PROTOCOL=self.headers.get("Git-Protocol", ""))
                result = subprocess.run([str(git_backend)], env=backend_env, input=incoming,
                                        capture_output=True, timeout=15)
                if result.returncode:
                    self.reply(500)
                    return
                header, body = result.stdout.split(b"\r\n\r\n", 1)
                fields = dict(line.decode("iso-8859-1").split(": ", 1) for line in header.split(b"\r\n"))
                status = int(fields.pop("Status", "200 OK").split()[0])
                self.reply(status, body, headers=fields)
                return
            name = path.rsplit("/", 1)[-1]
            public = {asset_name(): 7, asset_name() + ".sha256": 8, "SHA256SUMS": 8,
                      asset_name() + ".minisig": 9}
            if state["public"] and name in public:
                self.reply(200, bodies()[public[name]])
            else:
                self.reply(404)
            return
        if host != "api.github.com":
            self.reply(404)
            return
        if mode == "redirect-back" and parsed.query == "returned=1":
            self.reply(200 if not authorization else 403, payload if not authorization else b"")
            return
        if mode == "auth-error" or authorization != "Bearer " + state["token"]:
            self.reply(403)
            return
        if path.startswith("/repos/example/demo/commits") or path.startswith("/repos/example/demo/compare/"):
            if path == "/repos/example/demo/commits":
                body = [{"sha": head_commit}]
            elif path == "/repos/example/demo/commits/tags/v1.2.3":
                body = {"sha": release_commit}
            elif path == f"/repos/example/demo/compare/{release_commit}...{head_commit}":
                body = {"base_commit": {"sha": release_commit}, "merge_base_commit": {"sha": release_commit},
                        "ahead_by": 1, "behind_by": 0, "total_commits": 1, "status": "ahead"}
                if mode == "freshness-mismatched-comparison":
                    body["base_commit"]["sha"] = "a" * 40
            else:
                self.reply(404)
                return
            encoded = json.dumps(body).encode()
            if mode == "freshness-auth-denied":
                self.reply(403)
            elif mode == "freshness-redirect-host":
                self.reply(302, encoded, location="https://elsewhere.fixture.example/commits")
            elif mode == "freshness-redirect-repository":
                self.reply(302, encoded, location="https://api.github.com/repos/other/project/commits")
            elif mode == "freshness-malformed":
                self.reply(200, encoded + b"\n{}")
            elif mode == "freshness-oversized":
                self.reply(200, encoded + b" " * (8 * 1024 * 1024))
            else:
                self.reply(200, encoded)
            return
        if path in ("/repos/example/demo/releases/latest", "/repos/example/demo/releases/tags/" + state["tag"]):
            if mode == "metadata-redirect":
                self.reply(302, location="https://elsewhere.fixture.example/release")
                return
            release = {"id": 42, "tag_name": state["tag"], "draft": False}
            if mode == "wrong-tag":
                release["tag_name"] = "v99.0.0"
            elif mode == "array-tag":
                release["tag_name"] = [state["tag"]]
            elif mode == "empty-array-tag":
                release["tag_name"] = []
            elif mode == "draft":
                release["draft"] = True
            elif mode == "missing-draft":
                release.pop("draft")
            elif mode == "string-release-id":
                release["id"] = "42"
            self.reply(200, json.dumps(release).encode())
            return
        if path == "/repos/example/demo/releases/42/assets":
            page = int(urllib.parse.parse_qs(parsed.query)["page"][0])
            rows = inventory()[(page - 1) * 100:page * 100]
            if mode == "object-page":
                rows = {"assets": rows}
            elif mode == "overfull-page":
                rows = inventory()[:101]
            elif mode == "second-page-error" and page == 2:
                self.reply(403)
                return
            self.reply(200, json.dumps(rows).encode())
            return
        if path.startswith("/repos/example/demo/releases/assets/"):
            identity = int(path.rsplit("/", 1)[-1])
            if self.headers.get("Accept") != "application/octet-stream":
                self.reply(406)
                return
            if mode in ("checksum-403", "checksum-404") and identity == 8:
                self.reply(int(mode[-3:]))
                return
            if mode == "payload-403" and identity == 7:
                self.reply(403)
                return
            if mode == "redirect-evidence":
                self.reply(302, b"<html>" + b"redirect " * 100 + b"</html>",
                    location=f"https://objects.fixture.example/payload?asset={identity}&sig=private-object-signature")
                return
            if identity == 7:
                locations = {
                    "redirect": "https://objects.fixture.example/payload?sig=private-object-signature",
                    "redirect-chain": "https://objects.fixture.example/payload?sig=private-object-signature",
                    "redirect-back": "https://objects.fixture.example/payload?sig=private-object-signature",
                    "redirect-other-repo": "https://api.github.com/repos/other/project/releases/assets/7",
                    "redirect-http": "http://objects.fixture.example/payload",
                    "redirect-userinfo": "https://user:password@objects.fixture.example/payload",
                    "redirect-port": "https://objects.fixture.example:444/payload",
                    "redirect-fragment": "https://objects.fixture.example/payload#fragment",
                }
                if mode in locations:
                    self.reply(302, location=locations[mode])
                    return
            if identity in bodies():
                self.reply(200, bodies()[identity])
            else:
                self.reply(404)
            return
        self.reply(404)

    do_POST = do_GET


(work / "tls/config").write_text(
    "[req]\ndistinguished_name=dn\nx509_extensions=extensions\nprompt=no\n"
    "[dn]\nCN=api.github.com\n[extensions]\n"
    "subjectAltName=DNS:api.github.com,DNS:github.com,DNS:objects.fixture.example,"
    "DNS:second.fixture.example,DNS:elsewhere.fixture.example\nbasicConstraints=critical,CA:TRUE\n"
)
command([shutil.which("openssl"), "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
         "-config", str(work / "tls/config"), "-keyout", str(work / "tls/key.pem"),
         "-out", str(work / "tls/cert.pem")])
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(work / "tls/cert.pem", work / "tls/key.pem")
server.socket = context.wrap_socket(server.socket, server_side=True)
threading.Thread(target=server.serve_forever, daemon=True).start()

# Git uses the same TLS service through an explicit loopback CONNECT tunnel.
# It retains the github.com URL, certificate and repository-scoped auth header;
# no Git response, ref resolution or compiler command is mocked.
class GitTunnel(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(15)
        try:
            request = b""
            while not request.endswith(b"\r\n\r\n"):
                block = self.request.recv(1)
                if not block or len(request) >= 8192:
                    return
                request += block
            if request.split(b"\r\n", 1)[0].split()[:2] != [b"CONNECT", b"github.com:443"]:
                self.request.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
                return
            with socket.create_connection(server.server_address, timeout=15) as upstream_socket:
                self.request.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
                sockets = (self.request, upstream_socket)
                while True:
                    readable, _, _ = select.select(sockets, [], [], 15)
                    if not readable:
                        return
                    for connection in readable:
                        data = connection.recv(65536)
                        if not data:
                            return
                        other = upstream_socket if connection is self.request else self.request
                        other.sendall(data)
        except (OSError, TimeoutError):
            pass  # Refused credentials and completed Git requests close early.


class GitProxy(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


git_proxy = GitProxy(("127.0.0.1", 0), GitTunnel)
threading.Thread(target=git_proxy.serve_forever, daemon=True).start()
proxy_url = "http://127.0.0.1:" + str(git_proxy.server_address[1])

# A genuine client PATH without gh. The adapter forwards config stdin and
# file descriptor 3 unchanged; it never fabricates an API response or a header.
for name in ("bash", "env", "uname", "tr", "getconf", "ldd", "awk", "sed", "mktemp", "rm",
             "mkdir", "rmdir", "cp", "mv", "cat", "stat", "chmod", "tar", "gzip", "head",
             "tail", "wc", "od", "cut", "sort", "grep", "sha256sum", "shasum", "readlink",
             "realpath", "date", "sleep", "jq", "printf", "touch", "tee", "ln", "id", "uniq",
             "dirname", "basename", "cmp", "file", "ps", "find", "xargs", "dd", "base64", "minisign", "git", "go"):
    executable = shutil.which(name)
    if executable:
        (work / "bin" / name).symlink_to(executable)
adapter = work / "bin/curl"
adapter.write_text("#!" + sys.executable + "\n" + r'''
import json, os, pathlib, re, subprocess, sys, urllib.parse
arguments = sys.argv[1:]
configuration = sys.stdin.buffer.read() if "--config" in arguments else None
urls = [value for value in arguments if "://" in value]
if configuration is not None:
    for line in configuration.decode().splitlines():
        match = re.fullmatch(r'url = "(.*)"', line)
        if match:
            urls.append(match[1].replace(r'\"', '"').replace("\\\\", "\\"))
hosts = ("api.github.com", "github.com", "objects.fixture.example",
         "second.fixture.example", "elsewhere.fixture.example")
if len(urls) != 1 or urllib.parse.urlsplit(urls[0]).hostname not in hosts:
    sys.exit(22)
with open(os.environ["DSR_TEST_CURL_ARGV"], "a") as output:
    output.write(json.dumps(arguments) + "\n")
options = ["--noproxy", "*", "--cacert", os.environ["DSR_TEST_CA"]]
for host in hosts:
    options += ["--connect-to", host + ":443:127.0.0.1:" + os.environ["DSR_TEST_PORT"]]
result = subprocess.run([os.environ["DSR_TEST_REAL_CURL"], *arguments, *options],
                        input=configuration, close_fds=False)
sys.exit(result.returncode)
''')
adapter.chmod(0o755)
environment.update(PATH=str(work / "bin"), DSR_TEST_REAL_CURL=shutil.which("curl"),
                   DSR_TEST_CA=str(work / "tls/cert.pem"), DSR_TEST_PORT=str(server.server_address[1]),
                   HTTPS_PROXY=proxy_url, https_proxy=proxy_url, HTTP_PROXY=proxy_url, http_proxy=proxy_url,
                   ALL_PROXY="", all_proxy="", NO_PROXY="", no_proxy="", GIT_SSL_CAINFO=str(work / "tls/cert.pem"))
check("fixture PATH genuinely lacks gh", shutil.which("gh", path=environment["PATH"]) is None)
results = {}


def run(label, mode="", *, tag="v1.2.3", latest=False, selected="dsr", options=(),
        cache=None, public=False, tracing=False, token_override=None, curlrc=False):
    state.update(label=label, mode=mode, tag=tag, token=tokens[selected or "dsr"], public=public)
    directory = work / label
    directory.mkdir()
    argv_log = directory / "curl-argv.jsonl"
    env = environment.copy()
    env["DSR_TEST_CURL_ARGV"] = str(argv_log)
    if selected:
        env["GH_TOKEN"] = tokens["gh"]
        if selected in ("dsr", "github"):
            env["GITHUB_TOKEN"] = tokens["github"]
        if selected == "dsr":
            env["DSR_GH_TOKEN"] = tokens["dsr"]
    if token_override is not None:
        env["DSR_GH_TOKEN"] = token_override
    if curlrc:
        home = directory / "home"
        home.mkdir()
        (home / ".curlrc").write_text('header = "X-Fixture-Ambient: applied"\nverbose\n')
        env["HOME"] = str(home)
    cache = pathlib.Path(cache) if cache else directory / "cache"
    args = ["/bin/bash"]
    if tracing:
        args.append("-x")
    args += [str(installer), "--dir", str(directory / "bin"), "--cache-dir", str(cache),
             "--non-interactive", "--json", "--no-skills"]
    if "--allow-source-build" not in options:
        args.append("--require-signatures")
    if not latest:
        args += ["--version", tag]
    args += list(options)
    offset = len(requests)
    result = subprocess.run(args, env=env, text=True, capture_output=True, timeout=30)
    (directory / "stdout").write_text(result.stdout)
    (directory / "stderr").write_text(result.stderr)
    selected_requests = requests[offset:]
    (directory / "requests.json").write_text(json.dumps(selected_requests, indent=2))
    complete = result.returncode == 0 and all(
        (directory / "bin" / name).is_file() and
        (directory / "bin" / name).read_bytes() == (work / "payload" / name).read_bytes()
        for name in ("demo", "demo-worker"))
    blocked = result.returncode != 0 and not (directory / "bin/demo").exists() and not any(cache.rglob("payload"))
    results[label] = {"exit": result.returncode, "complete": complete, "blocked": blocked}
    return result, selected_requests, directory, cache, complete, blocked


def freshness_requests(calls):
    return [call for call in calls if "/commits" in call["path"] or "/compare/" in call["path"]]


def source_requests(calls):
    return [call for call in calls if call["host"] == "github.com" and call["path"].startswith("/example/demo.git/")]


try:
    for selected in ("dsr", "github", "gh"):
        options = ("--allow-source-build", "--source-if-stale", "1")
        if selected == "github":
            options += ("--prefer-gh",)
        result, calls, directory, cache, complete, blocked = run("freshness-" + selected,
            latest=True, selected=selected, options=options, tracing=True, curlrc=True)
        receipt = json.loads(result.stdout) if result.returncode == 0 else {}
        freshness = receipt.get("freshness", {})
        check(selected + " token checks private freshness without gh and keeps a release at the threshold",
              complete and freshness.get("status") == "fresh" and not source_requests(calls))
        check(selected + " token resolves the annotated release tag and immutable default head before comparing",
              freshness.get("release_commit") == release_commit and freshness.get("head_commit") == head_commit and
              freshness.get("commits_behind") == 1 and freshness.get("threshold") == 1 and
              [urllib.parse.unquote(call["path"]) for call in freshness_requests(calls)] == [
                  "/repos/example/demo/commits?per_page=1", "/repos/example/demo/commits/tags/v1.2.3",
                  f"/repos/example/demo/compare/{release_commit}...{head_commit}?per_page=1"])
        expected = hashlib.sha256(("Bearer " + tokens[selected]).encode()).hexdigest()
        check(selected + " token authenticates every freshness request as the selected account",
              len(freshness_requests(calls)) == 3 and
              all(call["authorization_sha256"] == expected and call["ambient_header"] is None
                  for call in freshness_requests(calls)))
        logs = result.stdout + result.stderr + (directory / "curl-argv.jsonl").read_text()
        check(selected + " freshness credentials remain absent from tracing and curl argv",
              all(token not in logs for token in tokens.values()))

    stale_options = ("--allow-source-build", "--source-if-stale", "0", "--source-timeout", "20")
    result, calls, directory, cache, complete, blocked = run("freshness-stale", latest=True,
        options=stale_options, tracing=True)
    receipt = json.loads(result.stdout) if result.returncode == 0 else {}
    check("private stale release compiles and installs both actual Go executables from the observed head",
          result.returncode == 0 and all((directory / "bin" / name).is_file() and
              command([str(directory / "bin" / name)]).strip() == name + "-observed-head"
              for name in ("demo", "demo-worker")))
    check("private stale source receipt binds the exact comparison head and complete unsigned family",
          receipt.get("method") == "source" and receipt.get("signed_release") is False and receipt.get("version") == "" and
          receipt.get("source", {}).get("source_commit") == head_commit and
          receipt.get("source", {}).get("requested_ref") == head_commit and
          sorted(row["name"] for row in receipt.get("source", {}).get("binaries", [])) == ["demo", "demo-worker"] and
          receipt.get("freshness", {}).get("release_commit") == release_commit and
          receipt.get("freshness", {}).get("status") == "stale")
    git_authorization = "Basic " + base64.b64encode(("x-access-token:" + tokens["dsr"]).encode()).decode()
    expected_git = hashlib.sha256(git_authorization.encode()).hexdigest()
    check("private freshness and real Git acquisition share the selected account without a second login",
          len(freshness_requests(calls)) == 3 and bool(source_requests(calls)) and
          all(call["authorization_sha256"] == expected_git for call in source_requests(calls)))
    check("private source output never masquerades as a verified release cache", not any(cache.rglob("payload")))
    logs = result.stdout + result.stderr + (directory / "curl-argv.jsonl").read_text()
    check("selected credentials remain absent from stale-source diagnostics and request argv",
          all(token not in logs for token in tokens.values()) and git_authorization not in logs)

    for mode in ("freshness-auth-denied", "freshness-redirect-host", "freshness-redirect-repository",
                 "freshness-malformed", "freshness-oversized", "freshness-mismatched-comparison"):
        result, calls, directory, cache, complete, blocked = run(mode, mode, latest=True, options=stale_options)
        receipt = json.loads(result.stdout) if result.returncode == 0 else {}
        check(mode + " remains unknown and retains the complete verified release",
              complete and receipt.get("freshness", {}).get("status") == "unknown" and "source" not in receipt)
        expected = hashlib.sha256(("Bearer " + tokens["dsr"]).encode()).hexdigest()
        check(mode + " neither changes account nor follows redirects nor starts a source fetch",
              bool(freshness_requests(calls)) and not source_requests(calls) and all(
                  call["host"] == "api.github.com" and call["path"].startswith("/repos/example/demo/") and
                  call["authorization_sha256"] == expected for call in calls))

    result, calls, directory, cache, complete, blocked = run("freshness-git-denied", "freshness-git-denied",
        latest=True, options=stale_options)
    check("a source authentication failure cannot install an incomplete family or stale release as source",
          blocked and result.returncode == 8 and bool(source_requests(calls)))
    check("a denied private source fetch never retries another GitHub account",
          all(call["authorization_sha256"] == expected_git for call in source_requests(calls)))

    for mode in ("wrong-checksum", "wrong-signature"):
        result, calls, directory, cache, complete, blocked = run("freshness-" + mode, mode,
            latest=True, options=stale_options)
        check(mode + " remains terminal before any private freshness or source request",
              blocked and not freshness_requests(calls) and not source_requests(calls))

    if freshness_only:
        print(f"Private Bash installer freshness: {passed} passed, {failed} failed", flush=True)
        sys.exit(0 if failed == 0 else 1)

    original_cache = None
    for selected in ("dsr", "github", "gh"):
        result, calls, directory, cache, complete, blocked = run("token-" + selected, selected=selected)
        check(selected + " token installs the complete signed executable family without gh", complete)
        expected = hashlib.sha256(("Bearer " + tokens[selected]).encode()).hexdigest()
        check(selected + " token priority is shared by release, pages, checksum and signature",
              len(calls) == 6 and all(call["authorization_sha256"] == expected for call in calls))
        check(selected + " token downloads exact later-page assets with binary Accept",
              [call["path"] for call in calls if call["accept"] == "application/octet-stream"] ==
              [f"/repos/example/demo/releases/assets/{identity}" for identity in (7, 8, 9)])
        check(selected + " token streams a real API page larger than 128 KiB",
              any(call.get("response_bytes", 0) > 131072 for call in calls if "page=1" in call["path"]))
        if selected == "dsr":
            original_cache = cache

    for mode in ("empty-last", "singleton-last"):
        result, calls, directory, cache, complete, blocked = run(mode, mode)
        check(mode + " paginated inventory installs", complete)
        check(mode + " reads the terminating second page",
              any(call["path"].endswith("page=2") for call in calls))

    result, calls, directory, cache, complete, blocked = run("latest", latest=True)
    check("latest private release installs without gh", complete)
    check("latest uses authenticated discovery before exact tag lookup",
          len(calls) >= 2 and calls[0]["path"] == "/repos/example/demo/releases/latest" and
          calls[1]["path"] == "/repos/example/demo/releases/tags/v1.2.3")
    for tag in ("release-2026.11", "v1.2.3+build.4"):
        result, calls, directory, cache, complete, blocked = run("tag-" + tag, tag=tag)
        check("explicit tag is preserved: " + tag, complete and json.loads(result.stdout)["version"] == tag)
        check("exact tag URL is encoded: " + tag,
              bool(calls) and calls[0]["path"] == "/repos/example/demo/releases/tags/" + urllib.parse.quote(tag, safe=""))

    result, calls, directory, cache, complete, blocked = run("prefer-gh-without-gh", options=("--prefer-gh",))
    check("--prefer-gh remains usable when only a token and curl are installed", complete)
    for label, options in (("offline", ("--offline",)), ("cached-online", ())):
        result, calls, directory, cache, complete, blocked = run(label, selected=None,
            cache=original_cache, options=options)
        check(label + " reuses verified private bytes without a credential", complete)
        check(label + " performs no release, checksum or signature HTTP request", not calls)

    result, calls, directory, cache, complete, blocked = run("public-no-token", selected=None, public=True)
    check("no-token public installation keeps the existing anonymous transport", complete)
    check("public requests never acquire or send credentials",
          bool(calls) and all(call["host"] == "github.com" and call["authorization_sha256"] is None for call in calls))

    for mode in ("redirect", "redirect-chain", "redirect-back", "redirect-evidence"):
        result, calls, directory, cache, complete, blocked = run(mode, mode, tracing=True)
        check(mode + " installs signed bytes through actual curl redirects", complete)
        redirected = [call for call in calls if call["host"] != "api.github.com" or "returned=1" in call["path"]]
        check(mode + " strips credentials permanently when leaving the API", bool(redirected) and
              all(call["authorization_sha256"] is None for call in redirected))
        logs = result.stdout + result.stderr + (directory / "curl-argv.jsonl").read_text()
        check(mode + " keeps account and signed-URL tokens out of tracing and curl argv",
              all(token not in logs for token in tokens.values()) and "private-object-signature" not in logs)
        if mode == "redirect-evidence":
            check("checksum and signature redirects may carry HTML larger than their payloads",
                  len(redirected) == 3 and all(call["response_bytes"] > 800 for call in calls
                      if call["host"] == "api.github.com" and "/assets/" in call["path"]))

    for mode in ("wrong-tag", "array-tag", "empty-array-tag", "draft", "missing-draft",
                 "string-release-id", "object-page", "overfull-page", "duplicate-name", "duplicate-id",
                 "missing-primary", "missing-checksum", "missing-signature", "incomplete", "zero-size",
                 "short-body", "oversized-body", "string-id", "wrong-checksum", "wrong-signature",
                 "second-page-error", "checksum-403", "checksum-404", "payload-403", "auth-error",
                 "metadata-redirect", "redirect-other-repo", "redirect-http", "redirect-userinfo",
                 "redirect-port", "redirect-fragment"):
        result, calls, directory, cache, complete, blocked = run(mode, mode, public=True,
            options=("--allow-source-build",) if mode in ("auth-error", "payload-403") else ())
        check(mode + " cannot install or publish a verified cache", blocked)
        check(mode + " cannot fall back to anonymous download",
              all(call["host"] == "api.github.com" for call in calls))
        if mode in ("checksum-403", "checksum-404"):
            check(mode + " does not hide a failed member with the later checksum format",
                  all(not call["path"].endswith("/assets/10") for call in calls))
        if mode in ("auth-error", "payload-403"):
            check(mode + " does not authorize a source fallback",
                  result.returncode == 8 and "[source-build]" not in result.stderr)

    result, calls, directory, cache, complete, blocked = run("latest-auth-error", "auth-error",
        latest=True, public=True, options=("--allow-source-build",))
    check("latest authentication failure stops before source fallback", blocked and result.returncode == 8 and
          "[source-build]" not in result.stderr and len(calls) == 1)
    result, calls, directory, cache, complete, blocked = run("invalid-token",
        token_override=tokens["dsr"] + "\nX-Injected: value", tracing=True)
    check("malformed selected credential is rejected before HTTP", blocked and result.returncode == 4 and not calls)
    check("malformed selected credential is absent from error and trace output",
          tokens["dsr"] not in result.stdout + result.stderr and "X-Injected" not in result.stdout + result.stderr)
    result, calls, directory, cache, complete, blocked = run("curl-config", curlrc=True)
    check("private requests ignore ambient curl configuration", complete and
          all(call["ambient_header"] is None for call in calls))
finally:
    git_proxy.shutdown()
    git_proxy.server_close()
    server.shutdown()
    server.server_close()
    (work / "requests.json").write_text(json.dumps(requests, indent=2))
    (work / "results.json").write_text(json.dumps(results, indent=2))

print(f"Private Bash installer: {passed} passed, {failed} failed", flush=True)
sys.exit(0 if failed == 0 else 1)
PY
