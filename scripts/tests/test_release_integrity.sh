#!/usr/bin/env bash
# Real JSON, files, SHA256, Ed25519/Blake2b signatures, locks and publication.
# The Minisign CLI adapter is a Python reference fixture, not native Minisign;
# native interoperability runs additionally when the actual executable exists.
# GitHub is an explicit file-backed transport fixture. No production keys used.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
NATIVE_MINISIGN=$(command -v minisign || true)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
trap 'exit 5' HUP INT TERM
mkdir -p "$WORK/bin" "$WORK/cases"
if ! python3 -c 'from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey' 2>/dev/null; then
    printf 'SKIP: reference crypto fixture requires Python cryptography\n'; exit 0
fi
RI_CRYPTO_SITE=$(python3 -c 'import pathlib,cryptography; print(pathlib.Path(cryptography.__file__).parent.parent)')
export RI_CRYPTO_SITE
cat > "$WORK/bin/minisign.py" <<'PY'
#!/usr/bin/env python3
import base64, hashlib, json, os, sys
from pathlib import Path
sys.path.insert(0,os.environ['RI_CRYPTO_SITE'])
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives import serialization

def value(flag):
    return sys.argv[sys.argv.index(flag)+1]
def encoded(data):
    return base64.b64encode(data).decode()
try:
    if '-G' in sys.argv:
        key=Ed25519PrivateKey.generate()
        seed=key.private_bytes(serialization.Encoding.Raw,serialization.PrivateFormat.Raw,serialization.NoEncryption())
        public=key.public_key().public_bytes(serialization.Encoding.Raw,serialization.PublicFormat.Raw)
        kid=os.urandom(8)
        Path(value('-s')).write_text(json.dumps({'seed':encoded(seed),'id':encoded(kid)}))
        Path(value('-p')).write_text('untrusted comment: isolated reference test key\n'+encoded(b'Ed'+kid+public)+'\n')
    elif '-S' in sys.argv:
        comment=value('-t').encode()
        log=os.environ.get('RI_SIGN_LOG')
        if log:
            with open(log,'a') as stream: stream.write(comment.decode()+'\n')
        fail=os.environ.get('RI_SIGN_FAIL','')
        if fail and fail in comment.decode():
            mode=os.environ.get('RI_SIGN_MODE','fail')
            if mode=='empty': sys.exit(0)
            if mode=='corrupt': Path(value('-x')).write_text('invalid signature\n'); sys.exit(0)
            sys.exit(19)
        secret=json.loads(Path(value('-s')).read_text())
        key=Ed25519PrivateKey.from_private_bytes(base64.b64decode(secret['seed']))
        kid=base64.b64decode(secret['id'])
        signature=key.sign(hashlib.blake2b(Path(value('-m')).read_bytes()).digest())
        global_signature=key.sign(signature+comment)
        Path(value('-x')).write_text('untrusted comment: reference fixture\n'+encoded(b'ED'+kid+signature)+'\ntrusted comment: '+comment.decode()+'\n'+encoded(global_signature)+'\n')
        drift=os.environ.get('RI_SIGN_DRIFT')
        if drift:
            with open(drift,'ab') as stream: stream.write(b'changed')
    elif '-V' in sys.argv:
        assert '-H' in sys.argv
        public=base64.b64decode(value('-P'),validate=True)
        lines=Path(value('-x')).read_text().splitlines()
        assert len(lines)==4 and lines[0].startswith('untrusted comment: ') and lines[2].startswith('trusted comment: ')
        sig=base64.b64decode(lines[1],validate=True)
        assert len(public)==42 and public[:2]==b'Ed' and len(sig)==74 and sig[:2]==b'ED' and sig[2:10]==public[2:10]
        key=Ed25519PublicKey.from_public_bytes(public[10:])
        key.verify(sig[10:],hashlib.blake2b(Path(value('-m')).read_bytes()).digest())
        key.verify(base64.b64decode(lines[3],validate=True),sig[10:]+lines[2][len('trusted comment: '):].encode())
    else: sys.exit(4)
except Exception:
    sys.exit(1)
PY
cat > "$WORK/bin/minisign" <<'SHIM'
#!/usr/bin/env bash
# Avoid unrelated site-startup hooks in the isolated reference process.
exec python3 -S "${BASH_SOURCE[0]}.py" "$@"
SHIM
chmod +x "$WORK/bin/minisign"
export PATH="$WORK/bin:$PATH"
minisign -G -s "$WORK/private" -p "$WORK/public" || exit 1
minisign -G -s "$WORK/wrong-private" -p "$WORK/wrong-public" || exit 1
chmod 600 "$WORK/private" "$WORK/wrong-private"
for module in sbom slsa signing sbom_release release_payloads release_integrity; do
    # shellcheck source=/dev/null
    source "$ROOT/src/$module.sh"
done
_sbr_require() { return 0; }
_sbr_run() { "$@"; }
_sbr_context() { cat "$CASE/context.json"; }
_sbr_inventory() {
    [[ "$1" == acme/tool && "$2" == 42 ]] || return 99
    jq -cS 'sort_by(.name)' "$CASE/remote/inventory.json"
}
gh_download_release_asset() {
    local repo="$1" id="$2" dest="$3"
    [[ "$repo" == acme/tool ]] || return 99
    printf '%s\n' "$id" >> "$CASE/downloads"
    cp -- "$CASE/remote/files/$id" "$dest" || return 8
    if [[ "${RI_DOWNLOAD_FAIL:-}" == "$id" ]]; then return 8; fi
    if [[ "${RI_DOWNLOAD_DRIFT:-}" == "$id" ]]; then
        jq '.tag_commit=("2"*40)' "$CASE/context.json" > "$CASE/context.next"
        mv "$CASE/context.next" "$CASE/context.json"
    fi
}
remote_add() (
    local file="$1" name="$2" id entry hash size
    exec 9>> "$CASE/remote/lock"; flock 9 || return 1
    if jq -e --arg name "$name" 'any(.[];.name==$name)' "$CASE/remote/inventory.json" >/dev/null; then return 7; fi
    id=$(jq '[.[].id]|max//100' "$CASE/remote/inventory.json"); id=$((id+1))
    cp -- "$file" "$CASE/remote/files/$id" || return 1
    hash=$(_slsa_sha256 "$CASE/remote/files/$id") || return 1
    size=$(wc -c < "$file")
    entry=$(jq -nc --arg name "$name" --arg hash "$hash" --argjson id "$id" --argjson size "$size" \
        '{id:$id,name:$name,size:$size,state:"uploaded",digest:("sha256:"+$hash)}')
    jq --argjson entry "$entry" '.+[$entry]|sort_by(.name)' "$CASE/remote/inventory.json" > "$CASE/remote/next"
    mv "$CASE/remote/next" "$CASE/remote/inventory.json"
    printf '%s\n' "$entry"
)
gh_upload_asset_named() {
    local url="$1" file="$2" name="$3" record
    [[ "$url" == 'https://uploads.github.com/repos/acme/tool/releases/42/assets{?name,label}' ]] || return 99
    printf '%s\n' "$name" >> "$CASE/uploads"
    if [[ "${RI_UPLOAD_FAIL:-}" == "$name" ]]; then return 8; fi
    record=$(remote_add "$file" "$name") || return $?
    if [[ "${RI_UPLOAD_LOST:-}" == "$name" ]]; then return 8; fi
    if [[ "${RI_UPLOAD_WRONG_ID:-}" == "$name" ]]; then
        jq '.id+=1' <<< "$record"; return 0
    fi
    if [[ "${RI_UPLOAD_DRIFT:-}" == "$name" ]]; then
        jq '.tag_commit=("2"*40)' "$CASE/context.json" > "$CASE/context.next"
        mv "$CASE/context.next" "$CASE/context.json"
    fi
    if [[ -n "${RI_LOCAL_DRIFT:-}" ]]; then printf changed >> "$RI_LOCAL_DRIFT"; fi
    printf '%s\n' "$record"
}
PIN=1111111111111111111111111111111111111111
checks=0 failures=0 CASE='' ART='' PROOFS='' MANIFEST='' status=0
check() {
    local label="$1"; shift; checks=$((checks+1))
    if "$@" > "$WORK/check.out" 2>&1; then printf 'ok %d - %s\n' "$checks" "$label"
    else printf 'not ok %d - %s\n' "$checks" "$label"; cat "$WORK/check.out"; failures=$((failures+1)); fi
}
new_case() {
    CASE="$WORK/cases/$1"; ART="$CASE/artifacts"; PROOFS="$CASE/proofs"; MANIFEST="$CASE/build.json"
    mkdir -p "$ART" "$PROOFS" "$CASE/remote/files"
    printf first > "$ART/a.tar.gz"; printf second > "$ART/b.tar.xz"; ln "$ART/a.tar.gz" "$ART/compat.tar.gz"
    : > "$CASE/records"
    local name target hash size
    for name in a.tar.gz b.tar.xz compat.tar.gz; do
        target=linux/amd64; [[ "$name" != b.tar.xz ]] || target=darwin/arm64
        hash=$(_slsa_sha256 "$ART/$name"); size=$(wc -c < "$ART/$name")
        jq -nc --arg name "$name" --arg target "$target" --arg sha "$hash" --argjson size "$size" \
            '{name:$name,target:$target,sha256:$sha,size_bytes:$size,archive_format:"tar.gz",path:"/private/should-never-publish"}' >> "$CASE/records"
    done
    jq -s --arg sha "$PIN" '{schema_version:"1.0.0",status:"success",tool:"tool",version:"v1.0.0",run_id:"test-build",
        built_at:"2026-09-18T00:00:00Z",source:{git_sha:$sha,git_ref:"refs/tags/v1.0.0",dependencies:[]},
        summary:{total:2,success:2,failed:0},artifacts:.}' "$CASE/records" > "$MANIFEST"
    jq -nc --arg sha "$PIN" '{repository:{id:1,node_id:"R_1",full_name:"acme/tool"},
        release:{id:42,node_id:"RE_42",tag_name:"v1.0.0",draft:true,prerelease:false,target_commitish:"main",
        upload_url:"https://uploads.github.com/repos/acme/tool/releases/42/assets{?name,label}"},tag_commit:$sha}' > "$CASE/context.json"
    echo '[]' > "$CASE/remote/inventory.json"
    : > "$CASE/uploads"; : > "$CASE/downloads"; : > "$CASE/signs"
    export RI_SIGN_LOG="$CASE/signs"
    unset RI_SIGN_FAIL RI_SIGN_MODE RI_SIGN_DRIFT RI_UPLOAD_FAIL RI_UPLOAD_LOST RI_UPLOAD_WRONG_ID RI_UPLOAD_DRIFT
    unset RI_DOWNLOAD_FAIL RI_DOWNLOAD_DRIFT RI_LOCAL_DRIFT DRY_RUN
}
call() {
    local action="$1"; shift
    _ri_execute "$action" "$ART" --repo acme/tool --tag v1.0.0 --sha "$PIN" \
        --build-manifest "$MANIFEST" --public-key "$WORK/public" --output-dir "$PROOFS" "$@"
}
prepare() { call prepare --secret-key "$WORK/private"; }
verify_remote() {
    release_verify_remote_integrity --repo acme/tool --tag v1.0.0 --sha "$PIN" --public-key "$WORK/public" "$@"
}
capture() { status=0; "$@" > "$CASE/out" 2> "$CASE/err" || status=$?; }
add_payloads() { local name; for name in a.tar.gz b.tar.xz compat.tar.gz; do remote_add "$ART/$name" "$name" >/dev/null || return; done; }
nonzero() { [[ "$1" -ne 0 ]]; }
no_public_proofs() { [[ "$(find "$PROOFS" -maxdepth 1 -type f | wc -l)" == 0 ]]; }

new_case complete
capture prepare
check 'all payloads and aliases produce a signed bundle' test "$status" -eq 0
check 'manifest names every payload and distinct alias signature' jq -e '(.artifacts|length)==3 and ([.artifacts[].signature.name]|unique|length)==3' "$PROOFS/release-integrity.json"
check 'private build paths are not published' bash -c '! grep -q /private "$1"' bash "$PROOFS/release-integrity.json"
check 'checksum manifest verifies with system sha256sum' bash -c 'cd "$1" && sha256sum -c "$2"' bash "$ART" "$PROOFS/checksums.sha256"
check 'all payload and checksum signatures plus master were generated' test "$(wc -l < "$CASE/signs")" -eq 5
cp "$PROOFS/release-integrity.json" "$CASE/before"
SIGNING_PRIVATE_KEY=/missing capture call prepare
check 'complete retry needs no private key' test "$status" -eq 0
check 'complete retry does not re-sign' test "$(wc -l < "$CASE/signs")" -eq 5
check 'complete retry preserves exact public manifest bytes' cmp -s "$CASE/before" "$PROOFS/release-integrity.json"
capture call verify
check 'independent local verification succeeds' test "$status" -eq 0
add_payloads
capture call publish
check 'all proofs publish after existing payloads' test "$status" -eq 0
check 'exactly seven public integrity assets uploaded' test "$(wc -l < "$CASE/uploads")" -eq 7
check 'master signature is the last uploaded file' test "$(tail -1 "$CASE/uploads")" = release-integrity.json.minisig
check 'publication receipt reports cryptographic verification' jq -e '.authenticated and .verification_policy=="minisign-all-payloads-and-checksums" and (.assets|length)==10' "$CASE/out"
capture verify_remote
check 'remote-only verifier authenticates all payloads and sidecars' test "$status" -eq 0
hash=$(_slsa_sha256 "$PROOFS/release-integrity.json")
capture verify_remote --manifest-sha256 "$hash"
check 'remote verifier accepts independently pinned signed manifest hash' test "$status" -eq 0
capture verify_remote --manifest-sha256 "$(printf '%064d' 0)"
check 'remote verifier rejects a mismatched manifest pin' nonzero "$status"
jq '.release.draft=false' "$CASE/context.json" > "$CASE/ctx"; mv "$CASE/ctx" "$CASE/context.json"
capture call publish
check 'complete public retry is read-only' test "$status" -eq 0
check 'complete public retry does not upload anything' test "$(wc -l < "$CASE/uploads")" -eq 7

new_case dry
capture call prepare --dry-run
check 'dry-run is an explicit plan' jq -e '.status=="planned" and .dry_run' "$CASE/out"
check 'dry-run does not sign or publish files' no_public_proofs
check 'dry-run does not invoke signing key' test ! -s "$CASE/signs"
for mode in fail empty corrupt; do
    new_case "sign-$mode"
    export RI_SIGN_FAIL=b.tar.xz RI_SIGN_MODE="$mode"
    capture prepare
    check "$mode signer cannot yield success" nonzero "$status"
    check "$mode signer cannot publish a partial local set" no_public_proofs
done
new_case wrong-key
capture call prepare --secret-key "$WORK/wrong-private"
check 'wrong private key rejected by real Ed25519 verification' nonzero "$status"
check 'wrong private key publishes nothing' no_public_proofs
new_case source-drift
export RI_SIGN_DRIFT="$ART/a.tar.gz"
capture prepare
check 'source mutation while signing prevents completion' nonzero "$status"
check 'source mutation is found before local proof publication' no_public_proofs
new_case checksum-conflict
echo wrong > "$PROOFS/checksums.sha256"
capture prepare
check 'existing wrong checksums are a conflict' nonzero "$status"
check 'retained checksum conflict is detected before private-key use' test ! -s "$CASE/signs"
check 'retained wrong checksums are not overwritten' grep -Fx wrong "$PROOFS/checksums.sha256"

new_case local-interrupt
ln() {
    [[ "${*: -1}" != "$PROOFS/b.tar.xz.minisig" ]] || return 19
    command ln "$@"
}
capture prepare
check 'local publication failure remains nonzero' nonzero "$status"
check 'completed local sidecar survives later publication failure' test -f "$PROOFS/a.tar.gz.minisig"
cp "$PROOFS/a.tar.gz.minisig" "$CASE/sidecar.before"
unset -f ln
capture prepare
check 'local partial set resumes successfully' test "$status" -eq 0
check 'resumed signature is byte-stable' cmp -s "$CASE/sidecar.before" "$PROOFS/a.tar.gz.minisig"

for file in a.tar.gz.minisig checksums.sha256 checksums.sha256.minisig release-integrity.json release-integrity.json.minisig; do
    new_case "tamper-$file"; prepare >/dev/null 2>&1
    printf changed >> "$PROOFS/$file"
    capture call verify
    check "tampered $file fails local verification" nonzero "$status"
    add_payloads
    capture call publish
    check "tampered $file cannot reach remote upload" test ! -s "$CASE/uploads"
done

new_case wrong-public
prepare >/dev/null 2>&1; add_payloads; call publish >/dev/null 2>&1
capture release_verify_remote_integrity --repo acme/tool --tag v1.0.0 --sha "$PIN" --public-key "$WORK/wrong-public"
check 'downloaded manifest key cannot override operator-selected key' nonzero "$status"
capture release_verify_remote_integrity --repo acme/tool --tag v1.0.0 --sha "$(printf '%040d' 2)" --public-key "$WORK/public"
check 'correctly signed release still must match expected source' nonzero "$status"

new_case partial-remote
prepare >/dev/null 2>&1; add_payloads
export RI_UPLOAD_FAIL=b.tar.xz.minisig
capture call publish
check 'partial remote upload returns failure' nonzero "$status"
check 'completed remote signature remains available' jq -e 'any(.[];.name=="a.tar.gz.minisig")' "$CASE/remote/inventory.json"
check 'incomplete remote set has no master signature' jq -e 'all(.[];.name!="release-integrity.json.minisig")' "$CASE/remote/inventory.json"
unset RI_UPLOAD_FAIL
capture call publish
check 'retry completes only missing remote work' test "$status" -eq 0
check 'already uploaded signature is not sent twice' test "$(grep -c '^a.tar.gz.minisig$' "$CASE/uploads")" -eq 1

new_case lost-ack
prepare >/dev/null 2>&1; add_payloads
export RI_UPLOAD_LOST=a.tar.gz.minisig
capture call publish
check 'lost acknowledgement remains a failure for this invocation' nonzero "$status"
unset RI_UPLOAD_LOST
capture call publish
check 'lost acknowledgement reconciles on retry' test "$status" -eq 0
check 'lost-ack asset is not reuploaded' test "$(grep -c '^a.tar.gz.minisig$' "$CASE/uploads")" -eq 1

new_case remote-conflict
prepare >/dev/null 2>&1; add_payloads
echo wrong > "$CASE/wrong"; remote_add "$CASE/wrong" b.tar.xz.minisig >/dev/null
capture call publish
check 'later occupied conflicting name blocks entire upload set' nonzero "$status"
check 'later conflict is found before first upload' test ! -s "$CASE/uploads"

new_case public-incomplete
prepare >/dev/null 2>&1; add_payloads
jq '.release.draft=false' "$CASE/context.json" > "$CASE/ctx"; mv "$CASE/ctx" "$CASE/context.json"
capture call publish
check 'incomplete public release is not modified' test "$status" -eq 4
check 'public-mode rejection happens before upload' test ! -s "$CASE/uploads"

for mode in wrong-id drift; do
    new_case "$mode"; prepare >/dev/null 2>&1; add_payloads
    if [[ "$mode" == wrong-id ]]; then export RI_UPLOAD_WRONG_ID=a.tar.gz.minisig
    else export RI_UPLOAD_DRIFT=a.tar.gz.minisig; fi
    capture call publish
    check "$mode during upload prevents success" nonzero "$status"
    check "$mode stops subsequent uploads" test "$(wc -l < "$CASE/uploads")" -eq 1
done

new_case remote-byte-drift
prepare >/dev/null 2>&1; add_payloads; call publish >/dev/null 2>&1
id=$(jq -r '.[]|select(.name=="b.tar.xz")|.id' "$CASE/remote/inventory.json")
printf changed >> "$CASE/remote/files/$id"
capture verify_remote
check 'remote verifier reads actual payload bytes despite an unchanged API digest' nonzero "$status"

new_case source-late
prepare >/dev/null 2>&1; add_payloads
export RI_LOCAL_DRIFT="$ART/a.tar.gz"
capture call publish
check 'source changes between metadata uploads are detected' nonzero "$status"
check 'source changes stop remaining metadata uploads' test "$(wc -l < "$CASE/uploads")" -eq 1

new_case no-digest
prepare >/dev/null 2>&1; add_payloads; call publish >/dev/null 2>&1
jq 'map(.digest=null)' "$CASE/remote/inventory.json" > "$CASE/next"; mv "$CASE/next" "$CASE/remote/inventory.json"
capture verify_remote
check 'missing API digests use verified immutable-ID downloads' test "$status" -eq 0

new_case manifest-errors
for filter in '.status="failed"' '.summary.success=1' '.artifacts+= [.artifacts[0]]' '.source.git_sha=("2"*40)' '.version="v9.0.0"'; do
    cp "$MANIFEST" "$CASE/valid.json"
    jq "$filter" "$CASE/valid.json" > "$MANIFEST"
    capture prepare
    check "invalid build selection rejected: $filter" nonzero "$status"
    check 'invalid selection causes no signing' test ! -s "$CASE/signs"
    cp "$CASE/valid.json" "$MANIFEST"
done
printf extra > "$ART/extra.zip"
capture prepare
check 'unmanifested local payload is rejected' nonzero "$status"

new_case args
for option in --public-key --output-dir --manifest-sha256; do
    capture _ri_execute prepare "$ART" "$option"
    check "missing value rejected: $option" test "$status" -eq 4
done
capture verify_remote "$ART"
check 'remote-only verification rejects a stray artifact directory' test "$status" -eq 4

if [[ -n "$NATIVE_MINISIGN" ]]; then
    new_case native-interoperability
    prepare >/dev/null 2>&1
    token=$(signing_public_key_token "$WORK/public")
    capture "$NATIVE_MINISIGN" -V -H -P "$token" -m "$PROOFS/release-integrity.json" -x "$PROOFS/release-integrity.json.minisig"
    check 'native Minisign verifies reference-generated signature format' test "$status" -eq 0
else
    printf 'SKIP: native Minisign interoperability (binary unavailable)\n'
fi
printf '\nRelease integrity checks: %d; failures: %d\n' "$checks" "$failures"
[[ "$failures" -eq 0 ]]
