#!/usr/bin/env bash
# Prepared-only integration, reconciled with the signing flow in 80f79f1.
# Real Ed25519/BLAKE2b signatures, Bash, jq and filesystem state. GitHub,
# publication, SBOM and dispatch adapters are explicit fixtures; no live writes.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
NATIVE_MINISIGN=$(command -v minisign || true)
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
trap 'exit 5' HUP INT TERM
mkdir -p "$WORK/bin" "$WORK/cases"
if ! python3 -c 'from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey' >/dev/null 2>&1; then
    printf 'SKIP: signature fixtures require Python cryptography\n'
    exit 0
fi
CRYPTO_SITE=$(python3 -c 'import pathlib,cryptography; print(pathlib.Path(cryptography.__file__).parent.parent)') || exit 3
export CRYPTO_SITE
cat > "$WORK/crypto.py" <<'PY'
import base64, hashlib, json, pathlib, sys, os
sys.path.insert(0, os.environ['CRYPTO_SITE'])
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey

def encode(data): return base64.b64encode(data).decode()
def digest(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def record(path): return dict(name=path.name, sha256=digest(path), size=path.stat().st_size)
def sign(path, key, kid):
    sig=key.sign(hashlib.blake2b(path.read_bytes()).digest()); comment=('fixture '+path.name).encode()
    pathlib.Path(str(path)+'.minisig').write_text('untrusted comment: fixture\n'+encode(b'ED'+kid+sig)+'\ntrusted comment: '+comment.decode()+'\n'+encode(key.sign(sig+comment))+'\n')

if sys.argv[1]=='bundle':
    case=pathlib.Path(sys.argv[2]); root=case/'artifacts'; proofs=case/'proofs'
    seed=case/'seed'
    if not seed.exists():
        key=Ed25519PrivateKey.generate()
        seed.write_bytes(key.private_bytes(serialization.Encoding.Raw,serialization.PrivateFormat.Raw,serialization.NoEncryption()))
    key=Ed25519PrivateKey.from_private_bytes(seed.read_bytes())
    pub=key.public_key().public_bytes(serialization.Encoding.Raw,serialization.PublicFormat.Raw)
    kid=hashlib.sha256(pub).digest()[:8]; token=encode(b'Ed'+kid+pub)
    (case/'key.pub').write_text('untrusted comment: fixture\n'+token+'\n')
    records=[record(root/name) for name in ['a.tar.gz','b.zip','compat.tar.gz']]
    build=dict(schema_version='1.0.0',status='success',tool='tool',version='v1.0.0',run_id='fixture',built_at='2026-09-18T00:00:00Z',source=dict(git_sha='1'*40,git_ref='refs/tags/v1.0.0',dependencies=[]),summary=dict(total=1,success=1,failed=0),artifacts=[dict(name=r['name'],sha256=r['sha256'],size_bytes=r['size'],target='linux/amd64',archive_format='tar.gz') for r in records])
    (case/'build.json').write_text(json.dumps(build,sort_keys=True)+'\n')
    (proofs/'checksums.sha256').write_text(''.join(r['sha256']+'  '+r['name']+'\n' for r in records))
    for r in records:
        source=root/r['name']; sign(source,key,kid)
        (proofs/(source.name+'.minisig')).write_bytes(pathlib.Path(str(source)+'.minisig').read_bytes())
        r['signature']=record(proofs/(source.name+'.minisig'))
    sign(proofs/'checksums.sha256',key,kid)
    checksum=record(proofs/'checksums.sha256'); checksum['signature']=record(proofs/'checksums.sha256.minisig')
    manifest=dict(schema_version=1,kind='dsr-release-integrity',repository='owner/tool',tag='v1.0.0',source_sha='1'*40,tool='tool',build_manifest_sha256=digest(case/'build.json'),signer=dict(type='minisign',public_key=token),artifacts=records,checksums=checksum)
    (proofs/'release-integrity.json').write_text(json.dumps(manifest,sort_keys=True)+'\n')
    sign(proofs/'release-integrity.json',key,kid)
elif sys.argv[1]=='sign-master':
    case=pathlib.Path(sys.argv[2]); key=Ed25519PrivateKey.from_private_bytes((case/'seed').read_bytes())
    pub=key.public_key().public_bytes(serialization.Encoding.Raw,serialization.PublicFormat.Raw)
    sign(case/'proofs/release-integrity.json',key,hashlib.sha256(pub).digest()[:8])
else:
    try:
        args=sys.argv[1:]
        assert '-V' in args and '-H' in args and '-S' not in args
        pub=base64.b64decode(args[args.index('-P')+1],validate=True)
        lines=pathlib.Path(args[args.index('-x')+1]).read_text().splitlines()
        sig=base64.b64decode(lines[1],validate=True)
        assert len(pub)==42 and pub[:2]==b'Ed' and len(sig)==74 and sig[:2]==b'ED' and sig[2:10]==pub[2:10]
        assert len(lines)==4 and lines[2].startswith('trusted comment: ')
        key=Ed25519PublicKey.from_public_bytes(pub[10:])
        key.verify(sig[10:],hashlib.blake2b(pathlib.Path(args[args.index('-m')+1]).read_bytes()).digest())
        key.verify(base64.b64decode(lines[3],validate=True),sig[10:]+lines[2][17:].encode())
    except Exception:
        sys.exit(1)
PY
export SIGNED_FINALIZE_CRYPTO="$WORK/crypto.py"
if [[ -n "$NATIVE_MINISIGN" ]]; then
    ln -s "$NATIVE_MINISIGN" "$WORK/bin/minisign"
    printf 'Native Minisign verification enabled\n'
else
    cat > "$WORK/bin/minisign" <<'SH'
#!/usr/bin/env bash
exec python3 -S "$SIGNED_FINALIZE_CRYPTO" "$@"
SH
    chmod +x "$WORK/bin/minisign"
    printf 'Native Minisign unavailable; real Ed25519 verification uses a Python format adapter\n'
fi
export PATH="$WORK/bin:$PATH"
for module in signing slsa sbom sbom_release release_integrity release_finalize; do
    # shellcheck source=/dev/null
    source "$ROOT/src/$module.sh"
done
# Dependency resolution and external service boundaries are fixtures. Local
# bundle parsing, cryptographic verification and finalization gates are real.
_ri_require() { command -v jq >/dev/null; }
_sbr_require() { :; }
_sbr_run() { "$@"; }
_sbr_context() { printf 'read\n' >> "$CASE/reads"; cat "$CASE/context.json"; }
_sbr_inventory() { jq -cS 'sort_by(.name)' "$CASE/assets.json"; }
remote_add() {
    local path="$1" name="$2" asset id
    id=$(jq '([.[].id]|max // 100)+1' "$CASE/assets.json") || return 1
    asset=$(jq -nc --argjson r "$(_ri_file_record "$path" "$name")" --argjson id "$id" \
        '$r|{id:$id,name,size,state:"uploaded",digest:("sha256:"+.sha256)}') || return 1
    jq --argjson a "$asset" '.+[$a]|sort_by(.name)' "$CASE/assets.json" > "$CASE/next" || return 1
    mv "$CASE/next" "$CASE/assets.json"
    printf '%s\n' "$name" >> "$CASE/uploads"
}
_ri_remote_publish() {
    local root="$1" proofs="$2" repo="$4" tag="$5" sha="$6" token="$7" work="$8"
    local documents row name names asset
    if [[ "$MODE" == replace-before-publish ]]; then
        jq '.build_manifest_sha256=("c"*64)' "$PROOFS/release-integrity.json" > "$CASE/next"
        mv "$CASE/next" "$PROOFS/release-integrity.json"
        python3 -S "$SIGNED_FINALIZE_CRYPTO" sign-master "$CASE"
    fi
    _ri_verify_set "$root" "$proofs" "$repo" "$tag" "$sha" "$token" "$work" || return $?
    documents=$(_ri_documents "$proofs") || return $?
    while IFS= read -r row; do
        name=$(jq -r '.name' <<< "$row") || return 1
        if ! jq -e --arg name "$name" 'any(.[];.name==$name)' "$CASE/assets.json" >/dev/null; then
            if [[ "$MODE" == partial && "$name" == b.zip.minisig ]]; then return 8; fi
            remote_add "$proofs/$name" "$name" || return $?
        fi
    done < <(jq -c '.[]' <<< "$documents")
    names=$(jq -c --argjson docs "$documents" '[.artifacts[].name]+[$docs[].name]' "$proofs/release-integrity.json") || return 1
    asset=$(jq -c '.[]|select(.name=="release-integrity.json")' "$CASE/assets.json") || return 1
    jq -nc --argjson c "$(cat "$CASE/context.json")" --arg token "$token" \
        --arg hash "$(_slsa_sha256 "$proofs/release-integrity.json")" --argjson a "$asset" \
        --argjson assets "$(_ri_selected_assets "$(cat "$CASE/assets.json")" "$names")" \
        '{schema_version:1,kind:"dsr-release-integrity-verification",status:"verified",authenticated:true,
          verification_policy:"minisign-all-payloads-and-checksums",public_key:$token,
          repository:$c.repository,release:$c.release,tag_commit:$c.tag_commit,
          manifest:{name:"release-integrity.json",sha256:$hash,asset_id:$a.id},assets:$assets}' \
        | tee "$CASE/integrity-receipt.json"
}
# This is a remote-verification boundary fixture, not a second crypto verifier.
# The independently tested remote library owns downloading and authenticating
# remote bytes. Here it returns only the same observed asset IDs and source pin.
release_verify_remote_integrity() {
    local key='' expected='' current names
    while (($#)); do
        case "$1" in
            --public-key) key="$2"; shift 2 ;;
            --manifest-sha256) expected="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    names=$(jq -c '[.assets[].name]' "$CASE/integrity-receipt.json") || return 1
    current=$(_ri_selected_assets "$(cat "$CASE/assets.json")" "$names") || return 1
    jq -ce --arg key "$(signing_public_key_token "$key")" --arg expected "$expected" \
        --argjson current "$current" --argjson context "$(cat "$CASE/context.json")" '
        select(.public_key==$key and .manifest.sha256==$expected and .assets==$current) |
        .release=$context.release' "$CASE/integrity-receipt.json"
}
release_prepare_integrity() {
    if [[ "$MODE" == existing-signing-mode ]]; then
        fixture_prepare_existing "$@"
        return $?
    fi
    printf 'unexpected signer call\n' >> "$CASE/prepare-calls"
    return 99
}
release_publish_integrity() {
    local root="$1" manifest='' proofs='' public=''
    shift
    [[ "$MODE" == existing-signing-mode ]] || return 99
    while (($#)); do
        case "$1" in
            --build-manifest) manifest="$2"; shift 2 ;;
            --output-dir) proofs="$2"; shift 2 ;;
            --public-key) public="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    _ri_remote_publish "$root" "$proofs" '{}' owner/tool v1.0.0 "$PIN" \
        "$(signing_public_key_token "$public")" "$CASE"
}
# Smoke-test the preserved signing orchestrator using a pre-existing bundle.
# This fixture verifies real signatures but does not claim private-key loading
# or creation of new signatures by the production preparation module.
fixture_prepare_existing() {
    local root="$1" manifest='' public='' proofs="$PROOFS" dry=false selection
    shift
    while (($#)); do
        case "$1" in
            --build-manifest) manifest="$2"; shift 2 ;;
            --public-key) public="$2"; shift 2 ;;
            --output-dir) proofs="$2"; shift 2 ;;
            --dry-run) dry=true; shift ;;
            *) shift ;;
        esac
    done
    selection=$(jq -cS --arg hash "$(_slsa_sha256 "$manifest")" \
        '{tool,manifest_sha256:$hash,tag:.version,source_sha:.source.git_sha,
          artifacts:(.artifacts|map({name,sha256,size:.size_bytes})|sort_by(.name))}' "$manifest") || return 1
    if [[ "$dry" == true ]]; then
        jq -nc --arg token "$(signing_public_key_token "$public")" --argjson selection "$selection" \
            '{kind:"dsr-release-integrity-plan",status:"planned",dry_run:true,public_key:$token,selection:$selection}'
    else
        printf 'prepare\n' >> "$CASE/prepare-calls"
        _ri_verify_set "$root" "$proofs" owner/tool v1.0.0 "$PIN" \
            "$(signing_public_key_token "$public")" "$CASE"
    fi
}
sbom_generate_artifacts() {
    printf 'scan\n' >> "$CASE/scans"
    jq -c '{artifacts:[.artifacts[]|{artifact:{name,sha256}}]}' "$PROOFS/release-integrity.json" > "$CASE/metadata/sbom-manifest.spdx.json"
    if [[ "$MODE" == wrong-sbom ]]; then
        jq '.artifacts[0].artifact.sha256=("0"*64)' "$CASE/metadata/sbom-manifest.spdx.json" > "$CASE/next"
        mv "$CASE/next" "$CASE/metadata/sbom-manifest.spdx.json"
    fi
}
sbom_verify_artifacts() { :; }
sbom_publish_artifacts() {
    if ! jq -e 'any(.[];.name=="sbom-manifest.spdx.json")' "$CASE/assets.json" >/dev/null; then
        remote_add "$CASE/metadata/sbom-manifest.spdx.json" sbom-manifest.spdx.json || return $?
    fi
    if [[ "$MODE" == proof-during-sbom ]]; then
        jq 'map(if .name=="b.zip.minisig" then .id+=1000 else . end)' "$CASE/assets.json" > "$CASE/next"
        mv "$CASE/next" "$CASE/assets.json"
    fi
    printf '{"kind":"dsr-sbom-publication","status":"verified","dry_run":false}\n'
}
sbom_verify_release() {
    local asset fingerprint
    asset=$(jq -c '.[]|select(.name=="sbom-manifest.spdx.json")' "$CASE/assets.json") || return 1
    fingerprint=$(_sbr_inventory_sha256 "$(cat "$CASE/assets.json")" "$CASE") || return 1
    jq -nc --argjson c "$(cat "$CASE/context.json")" --argjson a "$asset" --arg fingerprint "$fingerprint" \
        --arg hash "$(_slsa_sha256 "$CASE/metadata/sbom-manifest.spdx.json")" \
        '$c+{schema_version:1,kind:"dsr-sbom-remote-verification",status:"verified",format:"spdx",
          manifest:{name:"sbom-manifest.spdx.json",asset_id:$a.id,sha256:$hash},artifact_count:3,
          asset_inventory_sha256:$fingerprint,verification_policy:"expected-manifest-sha256"}'
}
gh() {
    [[ "$*" == *'--method PATCH repos/owner/tool/releases/42'* ]] || return 99
    printf 'promote\n' >> "$CASE/promotions"
    jq '.release.draft=false' "$CASE/context.json" > "$CASE/next"; mv "$CASE/next" "$CASE/context.json"
    [[ "$MODE" != after-promotion ]] || printf changed >> "$ART/b.zip"
}
_dp_config() { :; }
_dp_repos() { printf '%s\n' "${1//,/$'\n'}" | LC_ALL=C sort -u; }
dispatch_check_auth() { :; }
_dp_release_plan() { jq -nc --arg source "$1" --arg selected "$2" --argjson payload "$3" '{source:$source,selected:$selected,payload:$payload}'; }
_rf_dispatch_preflight() { :; }
_dp_release_outbox() {
    local plan="$1" guard="$5" repo rc=0 results=''
    printf '%s\n' "$plan" > "$CASE/dispatch-plan.json"
    while IFS= read -r repo; do
        "$guard" || { rc=$?; break; }
        printf '%s\n' "$repo" >> "$CASE/dispatches"
        results+="$(jq -nc --arg repo "$repo" '{repo:$repo,outcome:"accepted"}')"$'\n'
        if [[ "$MODE" == proof-between-dispatches ]]; then
            jq 'map(if .name=="b.zip.minisig" then .id+=1000 else . end)' "$CASE/assets.json" > "$CASE/next"
            mv "$CASE/next" "$CASE/assets.json"
        elif [[ "$MODE" == key-between-dispatches ]]; then
            printf bad > "$CASE/key.pub"
        fi
    done < <(jq -r '.selected' <<< "$plan")
    jq -sc --argjson rc "$rc" '{status:(if $rc==0 then "accepted" else "incomplete" end),exit_code:$rc,results:.}' <<< "$results"
    return "$rc"
}
_rup_require() { :; }
_rup_check_files() {
    local root="$1" manifest="$2" plan="$3" work="$4" selected expected entries entry name size
    [[ "$(_slsa_sha256 "$manifest")" == "$(jq -r '.manifest_sha256' <<< "$plan")" ]] || return 2
    selected=$(_sbom_select_artifacts "$root" "$work/list") || return $?
    selected=$(jq -nc --arg names "$selected" '$names|split("\n")|sort') || return 1
    expected=$(jq -c '[.artifacts[].name]|sort' <<< "$plan") || return 1
    [[ "$selected" == "$expected" ]] || return 4
    entries=$(jq -c '.artifacts[]' <<< "$plan") || return 1
    while IFS= read -r entry; do
        name=$(jq -r '.name' <<< "$entry") || return 1
        size=$(wc -c < "$root/$name") || return 1
        [[ "${size//[[:space:]]/}" == "$(jq -r '.size' <<< "$entry")" &&
           "$(_slsa_sha256 "$root/$name")" == "$(jq -r '.sha256' <<< "$entry")" ]] || return 7
    done <<< "$entries"
}
_rup_preflight() {
    jq -en --argjson inventory "$2" --argjson pinned "$4" \
        'all($pinned[];. as $a|[$inventory[]|select(.name==$a.name)]==[$a])' >/dev/null
}
release_upload_payloads() {
    local root="$1" manifest='' dry=false selection
    shift
    while (($#)); do
        case "$1" in
            --build-manifest) manifest="$2"; shift 2 ;;
            --dry-run) dry=true; shift ;;
            *) shift ;;
        esac
    done
    selection=$(jq -cS --arg hash "$(_slsa_sha256 "$manifest")" \
        '{tool,manifest_sha256:$hash,tag:.version,source_sha:.source.git_sha,
          artifacts:(.artifacts|map({name,sha256,size:.size_bytes})|sort_by(.name))}' "$manifest") || return 1
    if [[ "$MODE" == mismatched-build ]]; then
        selection=$(jq -c '.manifest_sha256=("0"*64)' <<< "$selection") || return 1
    fi
    if [[ "$dry" == true ]]; then
        jq -nc --argjson p "$selection" '{kind:"dsr-release-payload-publication",status:"planned",dry_run:true,plan:$p}'
    else
        printf 'payloads\n' >> "$CASE/payload-calls"
        jq -nc --argjson c "$(cat "$CASE/context.json")" --argjson p "$selection" \
            --argjson a "$(_ri_selected_assets "$(cat "$CASE/assets.json")" "$(jq -c '[.artifacts[].name]' <<< "$selection")")" \
            '$c+{kind:"dsr-release-payload-publication",status:"verified",dry_run:false,tool:$p.tool,manifest_sha256:$p.manifest_sha256,assets:$a}'
    fi
}
PIN=1111111111111111111111111111111111111111
checks=0 failures=0 CASE='' ART='' PROOFS='' MODE='' status=0
check() {
    local label="$1"; shift; checks=$((checks+1))
    if "$@" > "$WORK/check.out" 2>&1; then printf 'ok %s - %s\n' "$checks" "$label"
    else printf 'not ok %s - %s\n' "$checks" "$label"; cat "$WORK/check.out"; failures=$((failures+1)); fi
}
new_case() {
    CASE="$WORK/cases/$1"; ART="$CASE/artifacts"; PROOFS="$CASE/proofs"; MODE=''
    mkdir -p "$ART" "$PROOFS" "$CASE/metadata"
    printf binary-one > "$ART/a.tar.gz"; printf binary-two > "$ART/b.zip"; ln "$ART/a.tar.gz" "$ART/compat.tar.gz"
    python3 -S "$SIGNED_FINALIZE_CRYPTO" bundle "$CASE" || exit 1
    printf '[]' > "$CASE/assets.json"
    : > "$CASE/uploads"; : > "$CASE/reads"; : > "$CASE/promotions"; : > "$CASE/dispatches"; : > "$CASE/scans"; : > "$CASE/payload-calls"
    for name in a.tar.gz b.zip compat.tar.gz; do remote_add "$ART/$name" "$name"; done
    : > "$CASE/uploads"
    export DSR_STATE_DIR="$CASE/state"
    jq -nc --arg sha "$PIN" '{repository:{id:1,node_id:"repo",full_name:"owner/tool"},tag_commit:$sha,
        release:{id:42,node_id:"release",tag_name:"v1.0.0",draft:true,prerelease:false,target_commitish:"main",
        upload_url:"https://uploads.github.com/repos/owner/tool/releases/42/assets{?name,label}"}}' > "$CASE/context.json"
}
capture() { status=0; "$@" > "$CASE/out" 2> "$CASE/err" || status=$?; }
base_finalize() { release_finalize "$ART" --repo owner/tool --tag v1.0.0 --sha "$PIN" --output-dir "$CASE/metadata" --state-dir "$CASE/state/finalize" "$@"; }
finalize() { base_finalize --prepared-signatures --integrity-dir "$PROOFS" --public-key "$CASE/key.pub" "$@"; }
count() { wc -l < "$CASE/uploads"; }
state_path() { find "$CASE/state/finalize" -name state.json -type f | head -1; }

if [[ "${SIGNED_FINALIZE_FIXTURES_ONLY:-false}" == true ]]; then return 0; fi

new_case complete
capture finalize
check 'prepared signed bundle produces a verified ready draft' test "$status" -eq 0
check 'ready result contains authenticated integrity evidence' jq -e '.status=="ready" and .integrity.authenticated==true' "$CASE/out"
check 'signed master manifest plus signatures and SBOM uploaded' test "$(count)" -eq 8
capture base_finalize --promote
check 'retry cannot omit frozen signature policy' test "$status" -eq 2
check 'policy omission cannot promote' test ! -s "$CASE/promotions"
capture finalize --promote
check 'ready signed release can be promoted explicitly' test "$status" -eq 0
check 'promotion preserves authenticated receipt' jq -e '.status=="published" and .integrity.manifest.name=="release-integrity.json"' "$CASE/out"
capture finalize --promote
check 'published signed retry succeeds' test "$status" -eq 0
check 'complete retry does not upload or promote again' test "$(count):$(wc -l < "$CASE/promotions")" = 8:1

for mode in bad-master bad-payload wrong-source extra-payload; do
    new_case "$mode"
    case "$mode" in
        bad-master) printf bad > "$PROOFS/release-integrity.json.minisig" ;;
        bad-payload) printf bad > "$PROOFS/b.zip.minisig" ;;
        wrong-source)
            jq '.source_sha=("2"*40)' "$PROOFS/release-integrity.json" > "$CASE/next"; mv "$CASE/next" "$PROOFS/release-integrity.json"
            python3 -S "$SIGNED_FINALIZE_CRYPTO" sign-master "$CASE" ;;
        extra-payload) printf extra > "$ART/extra.bin" ;;
    esac
    capture finalize --promote
    check "$mode blocks finalization" test "$status" -ne 0
    check "$mode fails before remote reads or writes" test "$(wc -l < "$CASE/reads"):$(count)" = 0:0
    check "$mode fails before scans or persistent state" test ! -e "$CASE/state"
done

new_case partial
MODE=partial
capture finalize --promote
check 'partial integrity publication is nonzero' test "$status" -ne 0
check 'partial publication never promotes' test ! -s "$CASE/promotions"
MODE=''; capture finalize --promote
check 'same prepared bundle resumes partial publication' test "$status" -eq 0
check 'already uploaded proof is not repeated' test "$(grep -cx a.tar.gz.minisig "$CASE/uploads")" -eq 1

new_case proof-recreated
capture finalize
jq 'map(if .name=="b.zip.minisig" then .id+=1000 else . end)' "$CASE/assets.json" > "$CASE/next"; mv "$CASE/next" "$CASE/assets.json"
before=$(count); capture finalize --promote
check 'same bytes under a replacement proof ID are rejected' test "$status" -ne 0
check 'replacement conflict is detected before further publication' test "$(count)" -eq "$before"
check 'replacement proof ID cannot promote' test ! -s "$CASE/promotions"

new_case proof-during-sbom
MODE=proof-during-sbom
capture finalize --promote
check 'signature replacement during SBOM publication is rejected' test "$status" -ne 0
check 'cross-stage signature replacement causes zero promotions' test ! -s "$CASE/promotions"

new_case replace-before-publish
selected_hash=$(_slsa_sha256 "$PROOFS/release-integrity.json")
MODE=replace-before-publish
capture finalize --promote
check 'valid late bundle replacement cannot report completion' test "$status" -ne 0
check 'publisher receives frozen proof bytes rather than replacement' jq -e --arg sha "sha256:$selected_hash" \
    'any(.[];.name=="release-integrity.json" and .digest==$sha)' "$CASE/assets.json"
check 'original proof drift prevents promotion' test ! -s "$CASE/promotions"

new_case payload-upload
capture finalize --upload-payloads --build-manifest "$CASE/build.json" --promote
check 'signed bundle composes with manifest-bound payload stage' test "$status" -eq 0
check 'matching build invokes payload publisher once' test "$(wc -l < "$CASE/payload-calls")" -eq 1
check 'combined result retains payload and signature verification' jq -e \
    '.status=="published" and .payloads.status=="verified" and .integrity.authenticated==true' "$CASE/out"

new_case mismatched-build
MODE=mismatched-build
capture finalize --upload-payloads --build-manifest "$CASE/build.json" --promote
check 'different selected build cannot satisfy prepared signature bundle' test "$status" -eq 7
check 'build disagreement stops before actual payload publication' test ! -s "$CASE/payload-calls"
check 'build disagreement stops before remote reads' test ! -s "$CASE/reads"

new_case changed-signed-plan
capture finalize
jq '.build_manifest_sha256=("c"*64)' "$PROOFS/release-integrity.json" > "$CASE/next"; mv "$CASE/next" "$PROOFS/release-integrity.json"
python3 -S "$SIGNED_FINALIZE_CRYPTO" sign-master "$CASE"
capture finalize --promote
check 'different valid signed manifest conflicts with saved selection' test "$status" -eq 2
check 'signed selection change cannot promote' test ! -s "$CASE/promotions"

new_case wrong-sbom
MODE=wrong-sbom; capture finalize --promote
check 'SBOM describing other bytes cannot satisfy signed bundle' test "$status" -ne 0
check 'SBOM disagreement blocks SBOM publication and promotion' test "$(grep -c '^sbom-' "$CASE/uploads"):$(wc -l < "$CASE/promotions")" = 0:0

new_case unsigned
capture base_finalize
check 'existing unsigned path remains available' test "$status" -eq 0
check 'unsigned result does not claim cryptographic authentication' jq -e '.integrity==null and .status=="ready"' "$CASE/out"
capture finalize --promote
check 'ready unsigned finalization cannot silently acquire a policy' test "$status" -eq 2

new_case handoff
capture finalize --promote --tool tool --dispatch-repos owner/a,owner/b
check 'signed release promotion and guarded handoff succeed' test "$status" -eq 0
check 'handoff includes authenticated manifest and independently selected key' jq -e --arg key "$(signing_public_key_token "$CASE/key.pub")" \
    '.payload.release_evidence.integrity.manifest.name=="release-integrity.json" and .payload.release_evidence.integrity.public_key==$key' "$CASE/dispatch-plan.json"
check 'both destinations are sent only after signed finalization' test "$(wc -l < "$CASE/dispatches")" -eq 2

for mode in proof-between-dispatches key-between-dispatches; do
    new_case "$mode"; MODE="$mode"
    capture finalize --promote --tool tool --dispatch-repos owner/a,owner/b
    check "$mode prevents false completion" test "$status" -ne 0
    check "$mode stops second destination" test "$(wc -l < "$CASE/dispatches")" -eq 1
    check "$mode preserves already-published integrity evidence" jq -e '.status=="incomplete" and .integrity.authenticated==true' "$CASE/out"
done

new_case after-promotion
MODE=after-promotion; capture finalize --promote
check 'post-promotion local mutation cannot report completion' test "$status" -ne 0
check 'post-promotion failure never rolls back the public release' jq -e '.release.draft==false' "$CASE/context.json"

new_case dry
capture finalize --dry-run
check 'signed dry-run is supported' test "$status" -eq 0
check 'signed dry-run explicitly describes a prepared-only plan' jq -e '.status=="planned" and .prepared_signatures==true and .require_signatures==true' "$CASE/out"
check 'signed dry-run makes no API reads or writes' test "$(wc -l < "$CASE/reads"):$(count)" = 0:0
check 'signed dry-run creates no persistent state' test ! -e "$CASE/state"
capture base_finalize --integrity-dir "$PROOFS"
check 'bundle without external public key is invalid' test "$status" -eq 4
capture base_finalize --public-key "$CASE/key.pub"
check 'public key without bundle is invalid' test "$status" -eq 4

check 'prepared-only cases never call the preparation API' test "$(find "$WORK/cases" -name prepare-calls | wc -l)" -eq 0

new_case no-private-build
mv "$CASE/build.json" "$CASE/build.withheld"
SIGNING_PRIVATE_KEY=/nonexistent/private-key capture finalize --promote
check 'prepared finalization needs no private key or private build manifest' test "$status" -eq 0
check 'prepared finalization never invokes signing preparation' test ! -e "$CASE/prepare-calls"
check 'prepared policy is explicitly persisted' jq -e '.integrity_policy.mode=="prepared"' "$(state_path)"

new_case mixed-modes
capture finalize --require-signatures --build-manifest "$CASE/build.json"
check 'prepared and signing modes are mutually exclusive' test "$status" -eq 4
capture finalize --secret-key /must/not/read
check 'prepared mode rejects secret-key input' test "$status" -eq 4
check 'mode conflicts stop before remote operations' test "$(wc -l < "$CASE/reads"):$(count)" = 0:0

new_case missing-prepared-proof
mv "$PROOFS/b.zip.minisig" "$CASE/withheld.minisig"
capture finalize --promote
check 'prepared mode cannot replace a missing signature by signing' test "$status" -ne 0
check 'missing prepared proof makes no preparation calls' test ! -e "$CASE/prepare-calls"
check 'missing proof stops before remote operations' test "$(wc -l < "$CASE/reads"):$(count)" = 0:0

new_case frozen-prepared-mode
capture finalize
MODE=existing-signing-mode
capture base_finalize --require-signatures --build-manifest "$CASE/build.json" \
    --public-key "$CASE/key.pub" --integrity-dir "$PROOFS" --promote
check 'prepared retry cannot acquire signing permission' test "$status" -eq 2
check 'mode change is rejected before preparation or promotion' test ! -e "$CASE/prepare-calls"
check 'mode change leaves draft intact' test ! -s "$CASE/promotions"

new_case signing-mode-preserved
MODE=existing-signing-mode
capture base_finalize --require-signatures --build-manifest "$CASE/build.json" \
    --public-key "$CASE/key.pub" --integrity-dir "$PROOFS" --promote
check 'existing require-signatures orchestration still succeeds' test "$status" -eq 0
check 'existing signing mode retains its preparation stage' test "$(wc -l < "$CASE/prepare-calls")" -eq 1
check 'existing signing mode retains authenticated completion' jq -e '.status=="published" and .integrity.authenticated==true' "$CASE/out"
check 'existing policy shape is preserved' jq -e '.integrity_policy.required==true and (.integrity_policy|has("mode")|not)' "$(state_path)"

new_case false-receipt
_ri_remote_publish() { printf '{"kind":"dsr-release-integrity-verification","status":"verified","authenticated":true}\n'; }
capture finalize --promote
check 'incomplete publication receipt cannot authorize promotion' test "$status" -ne 0
check 'false-success adapter does not cause promotion' test ! -s "$CASE/promotions"

printf '\nPrepared-bundle finalization checks: %d; failures: %d\n' "$checks" "$failures"
[[ "$failures" -eq 0 ]]
