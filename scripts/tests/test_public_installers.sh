#!/usr/bin/env bash
# Exercise the checked-in installers through their public entry points.
# Real curl/TLS, compiled executables, tar archives, hashes and cache writes;
# only GitHub routing is redirected to a private loopback release server.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALLERS="${DSR_PUBLIC_INSTALLER_ROOT:-$ROOT/installers}"
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
for arg in "$@"; do
    case "$arg" in
        https://github.com/Dicklesworthstone/*/releases/download/v1.2.3/*)
            printf '%s\n' "$arg" >> "$DSR_TEST_CALLS"
            [[ "$DSR_TEST_HTTP_VARIANT" != offline ]] || exit 22
            args+=("$DSR_TEST_ORIGIN/$DSR_TEST_HTTP_VARIANT/${arg#https://github.com/}")
            url_count=$((url_count + 1)) ;;
        *://*) printf 'REFUSED %s\n' "$arg" >> "$DSR_TEST_CALLS"; exit 22 ;;
        *) args+=("$arg") ;;
    esac
done
[[ "$url_count" == 1 ]] || exit 22
exec "$DSR_TEST_CURL" --noproxy '*' --cacert "$DSR_TEST_CA" "${args[@]}"
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
    cached="$cache/$tool/v1.2.3/$os-$arch.tar.gz"
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
    check "$tool never caches an unverified download" test ! -e "$work/$tool-missing-cache/$tool/v1.2.3/$os-$arch.tar.gz"

    run_install tampered "$work/$tool-tampered-cache" tampered
    check "$tool default installation rejects an altered valid archive" blocked
    check "$tool tampered download fails at checksum verification" grep -q 'Checksum mismatch' "$case_dir/err"
    check "$tool never caches a tampered download" test ! -e "$work/$tool-tampered-cache/$tool/v1.2.3/$os-$arch.tar.gz"

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
[[ "$failed" == 0 ]]
