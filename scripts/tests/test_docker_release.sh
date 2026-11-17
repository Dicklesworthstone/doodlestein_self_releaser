#!/usr/bin/env bash
# Real shell/files/JSON/hash/publication checks; Docker/Syft/Cosign are explicit
# executable fixtures. This suite does not build or publish live containers.
set -uo pipefail
# This harness runs executable Docker/Syft/Cosign substitutes, not compilation.
# Test local fixture behavior explicitly; strict RCH refusal and the mandatory
# published-release remote path are separate cases below, never native proof.
export RCH_REQUIRE_REMOTE=0
ROOT="${DSR_TEST_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
MODULE="${DOCKER_TEST_MODULE:-$ROOT/src/docker.sh}"
CLI="${DOCKER_TEST_CLI:-$ROOT/dsr}"
WORK=$(mktemp -d)
if [[ "${DSR_TEST_KEEP_TMP:-0}" == 1 ]]; then
    trap 'printf "Retained container fixtures: %s\n" "$WORK"' EXIT
else
    trap 'rm -rf -- "$WORK"' EXIT
fi
trap 'exit 5' HUP INT TERM
mkdir -p "$WORK/bin" "$WORK/cases"
export PATH="$WORK/bin:$PATH" DK_WORK="$WORK"
DK_DIGEST="sha256:$(printf 'a%.0s' {1..64})"
export DK_DIGEST
unset DSR_GH_TOKEN GITHUB_TOKEN GH_TOKEN DOCKER_OUTPUT_DIR
export DOCKER_REGISTRY=ghcr.io/acme DOCKER_BUILDER_NAME=dsr-test-builder
export DOCKER_PLATFORMS=linux/amd64,linux/arm64
export DOCKER_CERTIFICATE_IDENTITY=builder@example.test
export DOCKER_CERTIFICATE_OIDC_ISSUER=https://issuer.example.test
cat > "$WORK/bin/docker" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
jq -nc --args '$ARGS.positional' -- "$@" >> "$DK_CALLS"
case "$*" in
    info|buildx\ version) exit 0 ;;
    buildx\ inspect*)
        [[ "${DK_MODE:-}" != builder-absent || "$*" == *--bootstrap* ]] || exit 1
        [[ "${DK_MODE:-}" != bootstrap-fail || "$*" != *--bootstrap* ]]; exit $? ;;
    buildx\ create*) exit 0 ;;
    login*) cat > "$DK_WORK/token.stdin"; [[ "${DK_MODE:-}" != login-fail ]]; exit $? ;;
esac
if [[ "${1:-} ${2:-} ${3:-}" == 'buildx imagetools inspect' ]]; then
    ref="$4"
    [[ "${DK_MODE:-}" != registry-fail ]] || exit 19
    digest="${ref##*@sha256:}"
    if [[ "$ref" != *@* ]]; then
        if [[ "${DK_MODE:-}" == tag-drift || -f "$DK_REGISTRY/tag-moved" ]]; then echo changed; exit; fi
        if [[ -f "$DK_REGISTRY/tags.json" ]]; then
            digest=$(jq -er --arg ref "$ref" '.[$ref]' "$DK_REGISTRY/tags.json") || exit 19
            digest="${digest#sha256:}"
        else digest="${DK_DIGEST#sha256:}"; fi
    fi
    if [[ "$5" == --raw ]]; then
        [[ "${DK_MODE:-}" != raw-corrupt ]] || { printf corrupt; exit; }
        cat "$DK_REGISTRY/raw/$digest"
    elif [[ "$5" == --format && "$6" == '{{json .Image}}' ]]; then
        [[ "${DK_MODE:-}" != config-mismatch ]] || { echo '{"os":"linux","architecture":"s390x"}'; exit; }
        cat "$DK_REGISTRY/config/$digest"
    else exit 98; fi
    exit
fi
[[ "${1:-} ${2:-}" == 'buildx build' ]] || { echo "Unexpected Docker command: $*" >&2; exit 98; }
if [[ "${DK_PUBLISHED_CHECK:-0}" == 1 ]]; then
    # Explicit Docker boundary substitute: execute the extracted fixture
    # programs and validate build args. This is not a native image build.
    python3 -I - "$@" <<'PY' || exit 19
import os,subprocess,sys
from pathlib import Path
args=sys.argv[1:];context=Path(args[-1]);values={}
for i,a in enumerate(args[:-1]):
    if a=='--build-arg':
        key,value=args[i+1].split('=',1);values[key]=value
assert values=={'AM_VERSION':'1.2.3','AM_REVISION':os.environ['DK_RELEASE_SHA']},'wrong release build arguments'
for arch in ['amd64','arm64']:
    for binary in ['am','mcp-agent-mail']:
        value=subprocess.check_output([str(context/'dist'/arch/binary),'--version'],text=True).strip()
        assert value==binary+' 1.2.3','wrong binary version'
PY
fi
published_context="${*: -1}"
metadata='' dest=''
while [[ $# -gt 0 ]]; do
    case "$1" in
        --metadata-file) metadata="$2"; shift 2 ;;
        --output) dest="${2#type=oci,dest=}"; shift 2 ;;
        *) shift ;;
    esac
done
[[ "${DK_MODE:-}" != build-fail ]] || { echo 'compiler error' >&2; exit 19; }
case "${DK_MODE:-}" in
    no-metadata) exit 0 ;;
    malformed) echo broken > "$metadata" ;;
    empty-metadata) : > "$metadata" ;;
    no-digest) echo '{}' > "$metadata" ;;
    bad-digest) echo '{"containerimage.digest":"sha256:not-a-digest"}' > "$metadata" ;;
    conflict) jq -nc --arg digest "$DK_DIGEST" '{"containerimage.digest":$digest,"containerimage.descriptor":{"digest":"sha256:other"}}' > "$metadata" ;;
    multiple) printf '{}\n{}\n' > "$metadata" ;;
    *) jq -nc --arg digest "$DK_DIGEST" '{"containerimage.digest":$digest,"containerimage.descriptor":{"digest":$digest}}' > "$metadata" ;;
esac
if [[ -n "$dest" && "${DK_MODE:-}" != no-archive ]]; then
    if [[ "${DK_PUBLISHED_CHECK:-0}" == 1 ]]; then
        # Real OCI layout/blob/layer bytes, with fixture shell programs. Docker
        # build/execution is still substituted; this is never native-image proof.
        python3 -I - "$dest" "$metadata" "$published_context" <<'PY' || exit 19
import gzip,hashlib,io,json,os,sys,tarfile
from pathlib import Path
dest,metadata,context=map(Path,sys.argv[1:]);label=Path(os.environ['PUBLISHED_CASE']).name;blobs={};images=[]
def encoded(value):return json.dumps(value,separators=(',',':')).encode()
def blob(data,media):
    digest=hashlib.sha256(data).hexdigest();blobs[digest]=data
    return {'mediaType':media,'digest':'sha256:'+digest,'size':len(data)}
def layer(entries):
    output=io.BytesIO()
    with tarfile.open(fileobj=output,mode='w') as t:
        for name,data in entries:
            member=tarfile.TarInfo(name);member.mode=0o755
            if data is None:member.type=tarfile.SYMTYPE;member.linkname='elsewhere';t.addfile(member)
            else:member.size=len(data);t.addfile(member,io.BytesIO(data))
    raw=output.getvalue()
    return blob(gzip.compress(raw,mtime=0),'application/vnd.oci.image.layer.v1.tar+gzip'),'sha256:'+hashlib.sha256(raw).hexdigest()
for arch in ['amd64','arm64']:
    entries=[('usr/local/bin/'+name,(context/'dist'/arch/name).read_bytes()) for name in ['am','mcp-agent-mail']]
    if label=='publish-wrong-binary':entries[0]=(entries[0][0],entries[0][1]+b'\n# wrong packaged bytes\n')
    first,diff=layer(entries);layers=[first];diffs=[diff]
    if label in ['publish-whiteout','publish-parent-link']:
        extra,extra_diff=layer([('.wh.usr',b'')] if label=='publish-whiteout' else [('usr/local',None)])
        layers.append(extra);diffs.append(extra_diff)
    if label=='publish-wrong-diffid':diffs[0]='sha256:'+'0'*64
    config={'os':'linux','architecture':'amd64' if label=='publish-config' and arch=='arm64' else arch,
            'config':{'Labels':{'org.opencontainers.image.version':'9.9.9' if label=='publish-version' else '1.2.3',
              'org.opencontainers.image.revision':'e'*40 if label=='publish-source' else os.environ['DK_RELEASE_SHA']}},
            'rootfs':{'type':'layers','diff_ids':diffs}}
    cfg=blob(encoded(config),'application/vnd.oci.image.config.v1+json')
    if label=='publish-size':cfg['size']+=1
    manifest=blob(encoded({'schemaVersion':2,'mediaType':'application/vnd.oci.image.manifest.v1+json','config':cfg,'layers':layers}),
                  'application/vnd.oci.image.manifest.v1+json')
    images.append(dict(manifest,platform={'os':'linux','architecture':arch}))
if label=='publish-missing-platform':images=images[:1]
evidence=[]
for image in images:
    config=blob(encoded({'os':'unknown','architecture':'unknown','config':{},'rootfs':{'type':'layers','diff_ids':[]}}),'application/vnd.oci.image.config.v1+json')
    statement=blob(encoded({'subject':[{'digest':{'sha256':image['digest'][7:]}}]}),'application/vnd.in-toto+json')
    record=blob(encoded({'schemaVersion':2,'mediaType':'application/vnd.oci.image.manifest.v1+json','config':config,'layers':[statement]}),
                'application/vnd.oci.image.manifest.v1+json')
    evidence.append(dict(record,platform={'os':'unknown','architecture':'unknown'},annotations={
        'vnd.docker.reference.type':'attestation-manifest','vnd.docker.reference.digest':'sha256:'+'0'*64 if label=='publish-unbound-evidence' else image['digest']}))
images+=evidence
root=encoded({'schemaVersion':2,'mediaType':'application/vnd.oci.image.index.v1+json','manifests':images})
if label=='publish-duplicate-json':root=root[:-1]+b',"schemaVersion":2}'
selected=blob(root,'application/vnd.oci.image.index.v1+json')
layout=encoded({'schemaVersion':2,'mediaType':'application/vnd.oci.image.index.v1+json','manifests':[selected]})
if label=='publish-direct-index':layout=root;blobs.pop(selected['digest'][7:])
with tarfile.open(dest,'w') as t:
    records={'oci-layout':encoded({'imageLayoutVersion':'1.0.0'}),'index.json':layout}
    records.update({'blobs/sha256/'+digest:data for digest,data in blobs.items()})
    if label=='publish-corrupt-blob':
        name=next(n for n in records if n.startswith('blobs/'));records[name]+=b'corrupt'
    for name,data in records.items():
        member=tarfile.TarInfo(name);member.size=len(data);t.addfile(member,io.BytesIO(data))
    if label=='publish-oci-link':
        member=tarfile.TarInfo('link');member.type=tarfile.SYMTYPE;member.linkname='/outside';t.addfile(member)
metadata.write_text(json.dumps({'containerimage.digest':selected['digest'],'containerimage.descriptor':{'digest':selected['digest']}}))
PY
    else
        tar -cf "$dest" -C "$DK_WORK" payload
    fi
fi
echo 'build progress on stdout'
SH
cat > "$WORK/bin/syft" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
jq -nc --args '$ARGS.positional' -- syft "$@" >> "$DK_CALLS"
[[ "${DK_SYFT_DISABLED:-false}" != true ]] || exit 99
[[ "${DK_MODE:-}" != second-scan-fail || "$1" != *"$DK_ARM64" ]] || exit 17
case "${DK_MODE:-}" in
    syft-fail) echo partial; exit 17 ;;
    syft-empty) exit 0 ;;
    syft-invalid) echo '{"spdxVersion":true}'; exit 0 ;;
    syft-multiple) printf '{}\n{}\n'; exit 0 ;;
esac
platform="${3:-default}"
jq --arg platform "$platform" --arg nonce "${DK_SCAN_NONCE:-}" '.name = ($platform + $nonce)' "$DK_WORK/spdx.json"
SH
cat > "$WORK/bin/cosign" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
jq -nc --args '$ARGS.positional' -- cosign "$@" >> "$DK_CALLS"
[[ "${DK_MODE:-}" != sign-fail || "$1" != sign ]] || exit 18
[[ "${DK_MODE:-}" != attest-fail || "$1" != attest ]] || exit 18
action="$1"; image="${*: -1}"; digest="${image##*@sha256:}"
identity='' issuer='' predicate=''
while [[ $# -gt 0 ]]; do
    case "$1" in
        --certificate-identity) identity="$2"; shift 2 ;;
        --certificate-oidc-issuer) issuer="$2"; shift 2 ;;
        --predicate) predicate="$2"; shift 2 ;;
        *) shift ;;
    esac
done
if [[ "$action" == verify || "$action" == verify-attestation ]]; then
    [[ "$identity" == builder@example.test && "$issuer" == https://issuer.example.test ]] || exit 18
fi
case "$action" in
    sign)
        [[ "${DK_MODE:-}" != false-sign ]] || exit 0
        printf signature > "$DK_REGISTRY/signed/$digest"
        echo 'signer diagnostic on stdout' ;;
    verify)
        [[ "${DK_MODE:-}" != verify-sign-fail ]] || exit 18
        [[ "${DK_MODE:-}" != empty-sign ]] || { echo '[]'; exit; }
        [[ -f "$DK_REGISTRY/signed/$digest" ]] || exit 18
        [[ "${DK_MODE:-}" != wrong-sign-digest ]] || digest="$(printf '0%.0s' {1..64})"
        jq -nc --arg digest "sha256:$digest" '[{critical:{image:{"docker-manifest-digest":$digest}}}]' ;;
    attest)
        [[ "${DK_MODE:-}" != false-attest ]] || exit 0
        [[ "${DK_MODE:-}" != second-attest-fail || "$image" != *"$DK_ARM64" ]] || exit 18
        jq -nc --arg name "${image%@*}" --arg digest "$digest" --slurpfile sbom "$predicate" \
            '{_type:"https://in-toto.io/Statement/v0.1",predicateType:"https://spdx.dev/Document",
              subject:[{name:$name,digest:{sha256:$digest}}],predicate:$sbom[0]}' > "$DK_REGISTRY/statement.json"
        filter='.'
        case "${DK_MODE:-}" in
            wrong-subject) filter='.subject[0].digest.sha256 = ("0"*64)' ;;
            wrong-subject-name) filter='.subject[0].name = "other/repository"' ;;
            wrong-predicate-type) filter='.predicateType = "https://example.test/wrong"' ;;
            changed-predicate) filter='.predicate.name = "not-what-was-scanned"' ;;
        esac
        jq -c "$filter" "$DK_REGISTRY/statement.json" | jq -Rnc 'input | {payloadType:"application/vnd.in-toto+json",payload:(. | @base64)}' \
            >> "$DK_REGISTRY/attestations/$digest.jsonl"
        [[ "${DK_MODE:-}" != late-tag-drift ]] || : > "$DK_REGISTRY/tag-moved"
        echo 'attester diagnostic on stdout' ;;
    verify-attestation)
        [[ "${DK_MODE:-}" != verify-attest-fail ]] || exit 18
        case "${DK_MODE:-}" in
            empty-attestation) echo '[]'; exit ;;
            malformed-envelope) echo '{"payload":"not base64","payloadType":"application/vnd.in-toto+json"}'; exit ;;
            wrong-envelope) echo '{"payload":"e30=","payloadType":"not-in-toto"}'; exit ;;
        esac
        cat "$DK_REGISTRY/attestations/$digest.jsonl" ;;
    *) echo "Unexpected Cosign operation: $action" >&2; exit 98 ;;
esac
SH
cat > "$WORK/bin/gh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
jq -nc --args '$ARGS.positional' -- gh "$@" >> "$DK_CALLS"
printf 'gh-config-token'
SH
chmod +x "$WORK/bin/docker" "$WORK/bin/syft" "$WORK/bin/cosign" "$WORK/bin/gh"
printf payload > "$WORK/payload"
cat > "$WORK/spdx.json" <<'JSON'
{"spdxVersion":"SPDX-2.3","dataLicense":"CC0-1.0","SPDXID":"SPDXRef-DOCUMENT","name":"fixture","documentNamespace":"https://example.test/sbom","creationInfo":{"created":"2026-09-18T00:00:00Z","creators":["Tool: fixture"]},"packages":[]}
JSON
# shellcheck source=/dev/null
source "$MODULE"
checks=0 failures=0 status=0 CASE='' REPO='' output=''
# The registry fixture serves exact serialized bytes addressed by their REAL
# SHA256. Malformed inventory tests can change the bytes and recompute the pin;
# raw-corruption tests deliberately serve different bytes for an existing pin.
freeze_index() {
    DK_DIGEST="sha256:$(_dk_hash "$DK_REGISTRY/index.json")"
    export DK_DIGEST
    cp "$DK_REGISTRY/index.json" "$DK_REGISTRY/raw/${DK_DIGEST#sha256:}"
}
edit_index() {
    jq "$1" "$DK_REGISTRY/index.json" > "$DK_REGISTRY/edited.json"
    cp "$DK_REGISTRY/edited.json" "$DK_REGISTRY/index.json"
    freeze_index
}
init_registry() {
    export DK_REGISTRY="$CASE/registry"
    mkdir -p "$DK_REGISTRY/raw" "$DK_REGISTRY/config" "$DK_REGISTRY/signed" "$DK_REGISTRY/attestations"
    local arch config_sha sha size
    : > "$DK_REGISTRY/descriptors.jsonl"
    for arch in amd64 arm64; do
        jq -nc --arg arch "$arch" '{os:"linux",architecture:$arch} +
            (if $arch == "arm64" then {variant:"v8"} else {} end)' > "$DK_REGISTRY/config-$arch.json"
        config_sha=$(_dk_hash "$DK_REGISTRY/config-$arch.json")
        jq -nc --arg sha "sha256:$config_sha" --argjson size "$(wc -c < "$DK_REGISTRY/config-$arch.json")" \
            '{schemaVersion:2,mediaType:"application/vnd.oci.image.manifest.v1+json",
              config:{mediaType:"application/vnd.oci.image.config.v1+json",digest:$sha,size:$size},layers:[]}' > "$DK_REGISTRY/image-$arch.json"
        sha=$(_dk_hash "$DK_REGISTRY/image-$arch.json")
        cp "$DK_REGISTRY/image-$arch.json" "$DK_REGISTRY/raw/$sha"
        cp "$DK_REGISTRY/config-$arch.json" "$DK_REGISTRY/config/$sha"
        [[ "$arch" != arm64 ]] || export DK_ARM64="$sha"
        [[ "$arch" != amd64 ]] || export DK_AMD64="$sha"
        size=$(wc -c < "$DK_REGISTRY/image-$arch.json")
        jq -nc --arg digest "sha256:$sha" --argjson size "$size" --arg arch "$arch" \
            '{mediaType:"application/vnd.oci.image.manifest.v1+json",digest:$digest,size:$size,
              platform:{os:"linux",architecture:$arch}}' >> "$DK_REGISTRY/descriptors.jsonl"
    done
    jq -sc '{schemaVersion:2,mediaType:"application/vnd.oci.image.index.v1+json",manifests:.}' \
        "$DK_REGISTRY/descriptors.jsonl" > "$DK_REGISTRY/index.json"
    freeze_index
}
new_case() {
    CASE="$WORK/cases/$1"; REPO="$CASE/project with spaces"
    mkdir -p "$REPO/docker"
    printf 'FROM scratch\nCOPY binary /binary\n' > "$REPO/docker/Dockerfile"
    printf binary > "$REPO/binary"
    export DK_CALLS="$CASE/calls.jsonl" DK_MODE=''
    : > "$DK_CALLS"
    export DOCKER_OUTPUT_DIR="$CASE/output"
    export DSR_CONFIG_DIR="$CASE/config" DSR_STATE_DIR="$CASE/state" DSR_CACHE_DIR="$CASE/cache"
    DRY_RUN=false
    export DK_SYFT_DISABLED=false DK_SCAN_NONCE=''
    export DOCKER_CERTIFICATE_IDENTITY=builder@example.test DOCKER_CERTIFICATE_OIDC_ISSUER=https://issuer.example.test
    unset DSR_GH_TOKEN GITHUB_TOKEN GH_TOKEN
    init_registry
}
capture() {
    status=0
    "$@" > "$CASE/stdout" 2> "$CASE/stderr" || status=$?
    output=$(cat "$CASE/stdout")
}
check() {
    local description="$1"; shift
    checks=$((checks+1))
    if "$@" >/dev/null 2>&1; then printf 'ok %d - %s\n' "$checks" "$description"
    else printf 'not ok %d - %s\n' "$checks" "$description"; failures=$((failures+1)); fi
}
nonzero() { [[ "$1" -ne 0 ]]; }
absent() { [[ ! -e "$1" && ! -L "$1" ]]; }
no_calls() { [[ ! -s "$DK_CALLS" ]]; }
no_call_kind() { jq -e -s --arg kind "$1" 'all(.[]; index($kind) == null)' "$DK_CALLS"; }
build() { docker_build tool 1.2.3 --repo-path "$REPO" "$@"; }
release() { docker_release tool 1.2.3 --repo-path "$REPO" "$@"; }

published_release_cases() {
local cohort="${1:-all}" cohort_work="$WORK/published-${1:-all}"
mkdir "$cohort_work" || return 1
python3 - "$ROOT" "$MODULE" "$cohort_work" "$cohort" "$CLI" <<'PY'
import hashlib,io,json,os,re,shutil,subprocess,sys,tarfile
from pathlib import Path
root,module,work=map(Path,sys.argv[1:4]);cohort=sys.argv[4];base=work/'published-base';base.mkdir()
repo=base/'repo';repo.mkdir();assets=base/'assets';assets.mkdir()
def run(args,**kwargs):return subprocess.run(args,check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,**kwargs)
run(['minisign','-G','-W','-p',str(repo/'minisign.pub'),'-s',str(base/'key')])
run(['minisign','-G','-W','-p',str(base/'other.pub'),'-s',str(base/'other.key')])
(repo/'Dockerfile.release').write_text('FROM scratch\nARG AM_VERSION\nARG AM_REVISION\n')
(repo/'Dockerfile').write_text('FROM scratch\n')
for args in [['init','-q'],['config','user.name','Container fixture'],['config','user.email','fixture@example.invalid'],
             ['add','.'],['commit','-qm','isolated release source'],['tag','v1.2.3']]:run(['git','-C',str(repo)]+args)
sha=run(['git','-C',str(repo),'rev-parse','HEAD']).stdout.decode().strip()
names={'linux/amd64':'tool-x86_64-unknown-linux-gnu.tar.xz','linux/arm64':'tool-aarch64-unknown-linux-gnu.tar.xz'}
def archive(path,version='1.2.3',special=None):
    with tarfile.open(path,'w:xz') as t:
        for binary in ['am','mcp-agent-mail']:
            data=f'#!/bin/sh\nprintf "%s\\n" "{binary} {version}"\n'.encode()
            info=tarfile.TarInfo(binary);info.size=len(data);info.mode=0o755;t.addfile(info,io.BytesIO(data))
        if special:
            info=tarfile.TarInfo('../outside' if special=='traversal' else 'link')
            if special=='link':info.type=tarfile.SYMTYPE;info.linkname='/outside'
            t.addfile(info)
for name in names.values():archive(assets/name)
manifest={'tool':'tool','version':'v1.2.3','source':{'git_sha':sha},'status':'success','publishable':True,
          'build_purpose':'release','summary':{'failed':0},'artifacts':[
              {'name':n,'sha256':hashlib.sha256((assets/n).read_bytes()).hexdigest(),'size_bytes':(assets/n).stat().st_size}
              for n in names.values()]}
(assets/'build-manifest.json').write_text(json.dumps(manifest))
contract={'checksum_sidecar':'sha256','minisign_public_key_file':'minisign.pub','exact_primary_assets':names,
          'exact_additional_assets':['SHA256SUMS','SHA256SUMS.minisig'],'build_manifest_assets':['build-manifest.json']}
config={'tool_name':'tool','repo':'owner/app','targets':['linux/amd64','linux/arm64'],
        'container_release_from_published_assets':True,'container_binaries':['am','mcp-agent-mail'],'release_contract':contract}
source=Path(sys.argv[5]).read_text();functions=work/'published-functions.sh'
functions.write_text('\n'.join(re.search(r'^'+n+r'\(\) \{\n.*?^\}',source,re.M|re.S).group(0)
    for n in ['_release_contract_verify_remote_tag_identity','_release_contract_observe_remote_inventory']))
with functions.open('a') as f:
    for name in ['json_envelope','_docker_command']:
        f.write('\n'+re.search(r'^'+name+r'\(\) \{\n.*?^\}\n(?=\n# =)',source,re.M|re.S).group(0))
version=re.search(r'^DSR_VERSION="([^"]+)"',source,re.M).group(1)
api=r'''
import json,os,sys
from pathlib import Path
c=Path(os.environ['PUBLISHED_CASE']);a=sys.argv[1:];r=json.loads((c/'release.json').read_text())
with (c/'api-calls').open('a') as f:f.write(json.dumps(a)+'\n')
label=c.name.removeprefix('publish-input-')
if label=='auth-denied':print('controlled authentication refusal',file=sys.stderr);sys.exit(1)
if a[0]=='download':
    asset=next(x for x in r['assets'] if x['id']==int(a[1]));p=Path(a[2]);assert not p.exists();p.write_bytes((c/'assets'/asset['name']).read_bytes());sys.exit(0)
e=a[0]
if '/git/ref/tags/' in e:print(json.dumps({'object':{'type':'commit','sha':'f'*40 if label=='wrong-source' or label=='publish-git-drift' and (c/'rch-args.json').exists() else os.environ['DK_RELEASE_SHA']}}))
elif '/releases/7/assets?' in e:print(json.dumps([] if 'page=2' in e else r['assets']))
elif '/releases/' in e:
    copies=[json.loads(x) for x in (c/'skopeo-calls').read_text().splitlines() if json.loads(x)[0]=='copy']
    if (label=='publish-release-before-upload' and (c/'rch-args.json').exists() or
        label=='publish-release-before-tags' and len(copies)>=1 or
        label=='publish-release-after-first-tag' and len(copies)>=2):r['body']='changed during publisher transition'
    if label=='publish-release-replaced' and (c/'rch-args.json').exists() and '/tags/' in e:r['id']=8
    if label=='changed-release' and len([x for x in (c/'api-calls').read_text().splitlines() if '/releases/7"' in x])>2:r['body']='changed after download'
    if label=='truncated-embedded':r['assets']=[]
    print(json.dumps(r))
else:raise AssertionError(e)
'''
rch=r'''#!/usr/bin/env python3
import hashlib,json,os,shutil,subprocess,sys
from pathlib import Path
c=Path(os.environ['PUBLISHED_CASE']);a=sys.argv[1:]
(c/'rch-args.json').write_text(json.dumps(a));label=c.name
assert Path(os.environ['RCH_CANONICAL_PROJECT_ROOT'])==Path.cwd(),'private job must have its exact canonical root'
assert all(x in a for x in ['--job','--require-remote','--require-tool','docker','--result-dir','.dsr-container-result'])
assert '--source-content-receipt' not in a,'the real RCH CLI rejects receipt mode for jobs'
if label=='rch-refused':print('controlled remote admission refusal',file=sys.stderr);sys.exit(103)
location='local' if label=='rch-local' else 'remote'
if True: # Even a false local-success receipt carries otherwise valid bytes.
    original=Path.cwd();worker=c/'worker';worker.mkdir()
    tracked=subprocess.run(['git','ls-files','-z'],cwd=original,capture_output=True)
    required=[f'context/dist/{arch}/{binary}'.encode() for arch in ['amd64','arm64'] for binary in ['am','mcp-agent-mail']]
    assert tracked.returncode==0 and all(p in tracked.stdout.split(b'\0') for p in required),'RCH source filter would omit required binaries'
    # Real rsync applies the same default dist exclusion and tracked-input
    # directory carveout; only SSH/admission delivery remains substituted.
    subprocess.run(['rsync','-a','--exclude=.git/','--exclude=.env','--include=/context/',
                    '--include=/context/dist/','--include=/context/dist/***','--exclude=dist/',
                    str(original)+'/',str(worker)+'/'],check=True,capture_output=True)
    if label in ['rch-corrupt-input','rch-corrupt-input-manifest']:
        p=worker/'context/dist/amd64/am';p.write_bytes(p.read_bytes()+b'\n# changed after transfer\n')
        if label=='rch-corrupt-input-manifest':
            manifest=worker/'.dsr-container-inputs.sha256'
            records=[line.split('  ',1) for line in manifest.read_text().splitlines()]
            manifest.write_text(''.join(hashlib.sha256((worker/name).read_bytes()).hexdigest()+'  '+name+'\n' for _,name in records))
    r=subprocess.run(a[a.index('--')+1:],cwd=worker,capture_output=True)
    (c/'worker.stdout').write_bytes(r.stdout);(c/'worker.stderr').write_bytes(r.stderr)
    if r.returncode:sys.stderr.buffer.write(r.stderr);sys.exit(r.returncode)
    shutil.copytree(worker/'.dsr-container-result',original/'.dsr-container-result')
    if label=='rch-corrupt':(original/'.dsr-container-result/image.tar').write_bytes(b'changed result')
    if label=='rch-wrong-platform':
        p=original/'.dsr-container-result/build.json';v=json.loads(p.read_text());v['platforms']=['linux/amd64'];p.write_text(json.dumps(v))
    if label=='rch-wrong-source-receipt':
        p=original/'.dsr-container-result/build.json';v=json.loads(p.read_text());v['release_source_revision']='e'*40;p.write_text(json.dumps(v))
print(json.dumps({'api_version':'1.0','outcome':'completed','location':location,'worker_id':'explicit-fixture',
    'admission':{'worker_id':'explicit-fixture','strict_remote':True,'terminal_acknowledged':label!='rch-unacknowledged'},
    'remote_exit_code':0,'result_dirs':[{'path':'.dsr-container-result','status':'missing' if label=='rch-missing' else 'ok','files':2,'bytes':1}]}))
'''
skopeo=r'''#!/usr/bin/env python3
import json,os,sys,tarfile
from pathlib import Path
c=Path(os.environ['PUBLISHED_CASE']);label=c.name;a=sys.argv[1:];registry=c/'registry'
with (c/'skopeo-calls').open('a') as f:f.write(json.dumps(a)+'\n')
def content(source):
    layout=Path(source.removeprefix('oci:'));index=json.loads((layout/'index.json').read_text());digest=index['manifests'][0]['digest']
    data={str(p.relative_to(layout)):p.read_bytes() for p in layout.rglob('*') if p.is_file()}
    return digest,data
if a[0]=='inspect':
    digest,data=content(a[-1]);sys.stdout.buffer.write(data['blobs/sha256/'+digest[7:]]+(b'corrupt' if label=='publish-inspect' else b''));sys.exit(0)
assert a[0]=='copy' and '--all' in a and '--preserve-digests' in a
source,dest=a[-2:];out=Path(a[a.index('--digestfile')+1]);dest=dest.removeprefix('docker://')
if source.startswith('oci:'):
    if label=='publish-upload-fail':print('controlled immutable upload failure',file=sys.stderr);sys.exit(19)
    digest,data=content(source);assert dest.endswith('@'+digest)
    root=json.loads(data['blobs/sha256/'+digest[7:]])
    for name,value in data.items():
        if name.startswith('blobs/sha256/'):(registry/'raw'/name.rsplit('/',1)[1]).write_bytes(value)
    for image in root['manifests']:
        manifest=json.loads(data['blobs/sha256/'+image['digest'][7:]])
        (registry/'config'/image['digest'][7:]).write_bytes(data['blobs/sha256/'+manifest['config']['digest'][7:]])
    if label=='publish-upload-digest':digest='sha256:'+'0'*64
else:
    digest=source.rsplit('@',1)[1]
    if label=='publish-promote-fail' or label=='publish-partial' and dest.endswith(':latest'):
        print('controlled tag promotion failure',file=sys.stderr);sys.exit(19)
    tags=json.loads((registry/'tags.json').read_text());tags[dest]=digest;(registry/'tags.json').write_text(json.dumps(tags))
out.write_text(digest+'\n')
'''
driver=r'''
set -uo pipefail
source "$ROOT/src/config.sh"
source "$ROOT/src/signing.sh"
source "$ROOT/src/github.sh"
source "$MODULE"
source "$PUBLISHED_FUNCTIONS"
_dsr_require() { :; } # All actual dependency modules are explicitly loaded above.
log_error() { printf '%s\n' "$*" >&2; }
gh_api() { python3 "$PUBLISHED_CASE/api.py" "$@"; }
gh_download_release_asset() { python3 "$PUBLISHED_CASE/api.py" download "$2" "$3"; }
if [[ "${PUBLISHED_OPERATION:-build}" == release ]]; then
    export DOCKER_OUTPUT_DIR="$PUBLISHED_CASE/output"
    if [[ "${PUBLISHED_ADAPTER:-0}" == 1 ]]; then
        JSON_MODE=true; DRY_RUN=false
        _docker_command release tool 1.2.3 --repo-path "$PUBLISHED_CASE/repo" --tag latest "$@"
    else docker_release tool 1.2.3 --repo-path "$PUBLISHED_CASE/repo" --tag latest "$@"; fi
else
    docker_build tool 1.2.3 --repo-path "$PUBLISHED_CASE/repo" --output "${PUBLISHED_OUTPUT:-$PUBLISHED_CASE/output/image.tar}" "$@"
fi
'''
checks=0
def check(label,condition):
    global checks
    assert condition,label
    checks+=1;print('PASS published '+label,flush=True)
negatives=['wrong-tag','wrong-source','missing-signature','empty-signature','tampered-manifest','untrusted-signer',
           'incomplete-manifest','tampered-archive','wrong-version','missing-platform','wrong-build-source',
           'missing-build-manifest','duplicate-entry','duplicate-build-source','bad-build-inventory','archive-link','archive-traversal','changed-release',
           'auth-denied','rch-refused','rch-local','rch-missing','rch-corrupt','rch-wrong-platform','rch-unacknowledged',
           'rch-corrupt-input','rch-corrupt-input-manifest','rch-wrong-source-receipt']
publication=['publish-valid','publish-direct-index','publish-unbound-evidence','publish-corrupt-blob','publish-missing-platform','publish-config','publish-version',
             'publish-source','publish-size','publish-wrong-binary','publish-wrong-diffid','publish-whiteout',
             'publish-parent-link','publish-duplicate-json','publish-oci-link','publish-inspect','publish-upload-fail',
             'publish-upload-digest','publish-scan-fail','publish-sign-fail','publish-evidence-fail','publish-promote-fail','publish-partial',
             'publish-release-before-upload','publish-release-before-tags','publish-release-after-first-tag',
             'publish-git-drift','publish-release-replaced',
             'publish-input-wrong-tag','publish-input-wrong-source','publish-input-missing-signature',
             'publish-input-empty-signature','publish-input-tampered-manifest','publish-input-untrusted-signer',
             'publish-input-incomplete-manifest','publish-input-wrong-version']
labels=(['valid','truncated-embedded','inherited-index','inherited-git-context']+negatives if cohort!='publisher' else [])
labels+=publication if cohort!='export' else []
assert labels,'empty published-release cohort'
for label in labels:
    c=work/('published-'+label);shutil.copytree(base,c)
    # The transport cases use the short label, independently of temp paths.
    case=c/label;case.mkdir()
    for entry in ['repo','assets','key','other.key']:shutil.move(str(c/entry),str(case/entry))
    c=case
    (c/'tmp').mkdir();(c/'config/repos.d').mkdir(parents=True);(c/'config/repos.d/tool.yaml').write_text(json.dumps(config))
    (c/'api.py').write_text(api);(c/'api-calls').write_text('');(c/'calls').write_text('')
    (c/'bin').mkdir();(c/'bin/rch').write_text(rch);(c/'bin/rch').chmod(0o700)
    (c/'bin/skopeo').write_text(skopeo);(c/'bin/skopeo').chmod(0o700);(c/'skopeo-calls').write_text('')
    (c/'registry').mkdir()
    for name in ['raw','config','signed','attestations']:(c/'registry'/name).mkdir()
    old_tags={'ghcr.io/acme/tool:v1.2.3':'sha256:'+'0'*64,'ghcr.io/acme/tool:latest':'sha256:'+'0'*64}
    (c/'registry/tags.json').write_text(json.dumps(old_tags))
    a=c/'assets'
    input_label=label.removeprefix('publish-input-')
    if input_label=='wrong-version':archive(a/names['linux/amd64'],version='9.9.9')
    if label in ['archive-link','archive-traversal']:archive(a/names['linux/amd64'],special=label.split('-')[1])
    current_manifest=dict(manifest,artifacts=[{'name':n,'sha256':hashlib.sha256((a/n).read_bytes()).hexdigest(),
        'size_bytes':(a/n).stat().st_size} for n in names.values()])
    if label=='wrong-build-source':current_manifest['source']={'git_sha':'e'*40}
    if label=='bad-build-inventory':current_manifest['artifacts'][0]['sha256']='0'*64
    (a/'build-manifest.json').write_text(json.dumps(current_manifest))
    if label=='duplicate-build-source':(a/'build-manifest.json').write_text(
        json.dumps(manifest)[:-1]+',"source":{"git_sha":"'+'e'*40+'"},"source":{"git_sha":"'+sha+'"}}')
    payloads=sorted(p for p in a.iterdir() if p.name not in ['SHA256SUMS','SHA256SUMS.minisig'])
    lines=[hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n' for p in payloads]
    if input_label=='incomplete-manifest':lines=lines[1:]
    if label=='duplicate-entry':lines+=lines[:1]
    (a/'SHA256SUMS').write_text(''.join(lines))
    run(['minisign','-S','-s',str(c/('other.key' if input_label=='untrusted-signer' else 'key')),
         '-m',str(a/'SHA256SUMS'),'-t','tool v1.2.3 SHA256SUMS'])
    if input_label=='tampered-manifest':(a/'SHA256SUMS').write_text((a/'SHA256SUMS').read_text()+'tampered\n')
    if label=='tampered-archive':(a/names['linux/amd64']).write_bytes(b'tampered archive')
    skipped={'SHA256SUMS.minisig'} if input_label=='missing-signature' else set()
    if input_label=='empty-signature':(a/'SHA256SUMS.minisig').write_bytes(b'')
    if label=='missing-platform':skipped.add(names['linux/arm64'])
    if label=='missing-build-manifest':skipped.add('build-manifest.json')
    release={'id':7,'tag_name':'v1.2.4' if input_label=='wrong-tag' else 'v1.2.3','draft':False,'name':'candidate','body':'fixture',
             'prerelease':False,'target_commitish':sha,'upload_url':'https://uploads.github.com/repos/owner/app/releases/7/assets',
             'assets':[{'id':i,'name':p.name,'size':p.stat().st_size,'state':'uploaded',
                        'digest':'sha256:'+hashlib.sha256(p.read_bytes()).hexdigest()}
                       for i,p in enumerate(sorted(a.iterdir()),100) if p.name not in skipped]}
    (c/'release.json').write_text(json.dumps(release))
    env=dict(os.environ,ROOT=str(root),MODULE=str(module),PUBLISHED_CASE=str(c),PUBLISHED_FUNCTIONS=str(functions),
             DK_RELEASE_SHA=sha,DK_PUBLISHED_CHECK='1',DK_CALLS=str(c/'calls'),DK_MODE='',
             DK_REGISTRY=str(c/'registry'),PUBLISHED_OPERATION='release' if label in publication else 'build',
             PUBLISHED_ADAPTER='1' if label in ['publish-valid','publish-direct-index'] else '0',DSR_VERSION=version,
             DSR_CONFIG_DIR=str(c/'config'),DSR_REPOS_FILE=str(c/'config/repos.yaml'),TMPDIR=str(c/'tmp'),
             PATH=str(c/'bin')+os.pathsep+os.environ['PATH'])
    env['DK_MODE']={'publish-scan-fail':'syft-fail','publish-sign-fail':'sign-fail','publish-evidence-fail':'attest-fail'}.get(label,'')
    if label.startswith('inherited-'):
        foreign=c/'foreign';foreign.mkdir();(foreign/'caller-only').write_text('preserve staged caller bytes\n')
        run(['git','-C',str(foreign),'init','--template=','-q','-b','main'])
        run(['git','-C',str(foreign),'add','--','caller-only'])
        index_before=(foreign/'.git/index').read_bytes()
        env['GIT_INDEX_FILE']=str(foreign/'.git/index')
        if label=='inherited-git-context':
            env.update(GIT_DIR=str(foreign/'.git'),GIT_COMMON_DIR=str(foreign/'.git'),
                       GIT_WORK_TREE=str(foreign),GIT_OBJECT_DIRECTORY=str(foreign/'.git/objects'))
    result=subprocess.run(['bash','-c',driver,'published','--published-release'],env=env,capture_output=True,text=True)
    (c/'stdout').write_text(result.stdout);(c/'stderr').write_text(result.stderr)
    if label.startswith('inherited-'):
        check(label+' preserves the caller index exactly',(foreign/'.git/index').read_bytes()==index_before)
    out=c/'output/image.tar';calls=[json.loads(x) for x in (c/'calls').read_text().splitlines()]
    if label in publication:
        tags=json.loads((c/'registry/tags.json').read_text())
        transport=[json.loads(x) for x in (c/'skopeo-calls').read_text().splitlines()]
        if label in ['publish-valid','publish-direct-index']:
            check(label+' completes the actual publisher',result.returncode==0)
            envelope=json.loads(result.stdout);receipt=envelope['details']['result'];image=receipt['reference']
            check(label+' reports actual publication through the public adapter',envelope['exit_code']==0 and envelope['details']['pushed'] is True)
            check(label+' promotes exactly the verified digest',set(tags.values())=={image.rsplit('@',1)[1]})
            check(label+' preserves both verified platform predicates',len(receipt['platforms'])==2 and receipt['signature']=='verified' and receipt['sbom']=='verified')
            check(label+' uploads the inspected layout before tag copies',len(transport)==4 and transport[1][-2].startswith('oci:') and '@sha256:' in transport[1][-1] and all(x[-2]=='docker://'+image for x in transport[2:]))
            before=(c/'api-calls').read_bytes();calls_before=(c/'calls').read_bytes();transport_before=(c/'skopeo-calls').read_bytes()
            planned=subprocess.run(['bash','-c',driver,'planned','--published-release','--dry-run'],env=env,capture_output=True,text=True)
            check('published release dry-run is side-effect free after a completed export',planned.returncode==0 and json.loads(planned.stdout)['details']['result']['kind']=='dsr-container-release' and
                  (c/'api-calls').read_bytes()==before and (c/'calls').read_bytes()==calls_before and (c/'skopeo-calls').read_bytes()==transport_before)
            unsigned=subprocess.run(['bash','-c',driver,'unsigned','--published-release','--skip-sign','--dry-run'],env=env,capture_output=True,text=True)
            check('published release cannot skip signatures even in a plan',unsigned.returncode!=0 and (c/'api-calls').read_bytes()==before and (c/'skopeo-calls').read_bytes()==transport_before)
        else:
            check(label+' returns failure',result.returncode!=0)
            if label in ['publish-partial','publish-release-after-first-tag']:
                check(label+' retains the acknowledged first tag',tags['ghcr.io/acme/tool:v1.2.3']!=old_tags['ghcr.io/acme/tool:v1.2.3'])
                check(label+' preserves the failed second tag',tags['ghcr.io/acme/tool:latest']==old_tags['ghcr.io/acme/tool:latest'])
            else:check(label+' leaves stable tags untouched',tags==old_tags)
            if label not in ['publish-upload-digest','publish-scan-fail','publish-sign-fail','publish-evidence-fail','publish-promote-fail','publish-partial',
                              'publish-release-before-tags','publish-release-after-first-tag']:
                check(label+' prevents registry publication',not any(x[0]=='copy' for x in transport) or label=='publish-upload-fail')
        continue
    if label in negatives:
        check(label+' returns failure',result.returncode!=0)
        check(label+' creates no exported image',not out.exists())
        late=label.startswith('rch-') or label=='wrong-version'
        check(label+' prevents stable-tag mutation and premature builds',
              all('--push' not in x for x in calls) and (late or (not calls and not (c/'rch-args.json').exists())))
        if label=='rch-corrupt-input':check(label+' refuses before Docker executes',not calls)
    else:
        check(label+' executes the actual container build path',result.returncode==0)
        receipt=json.loads(result.stdout)
        check(label+' exports exact collected bytes',out.is_file() and receipt['archive']['sha256']==hashlib.sha256(out.read_bytes()).hexdigest())
        check(label+' binds source, inputs and both platforms',receipt['release_source_revision']==sha and
              receipt['platforms']==['linux/amd64','linux/arm64'] and receipt['input_manifest_sha256']==
              hashlib.sha256((c/'worker/.dsr-container-inputs.sha256').read_bytes()).hexdigest())
        check(label+' requires remote completion',receipt['remote_execution']['location']=='remote' and (c/'rch-args.json').is_file())
        check(label+' supplies exact release arguments without pushing',any('--build-arg' in x for x in calls) and all('--push' not in x for x in calls))
    if label=='valid':
        policy_env=dict(env,PUBLISHED_OUTPUT=str(c/'policy-image.tar'))
        for args,expected in [(['--dry-run'],0),(['--dry-run','--tag','latest'],4),
                              (['--dry-run','--published-release','--push'],4)]:
            before=(c/'api-calls').read_bytes();r=subprocess.run(['bash','-c',driver,'policy']+args,env=policy_env,capture_output=True,text=True)
            (c/('policy-'+str(len(args))+'.stdout')).write_text(r.stdout)
            (c/('policy-'+str(len(args))+'.stderr')).write_text(r.stderr)
            check('policy '+str(args),r.returncode==expected and (c/'api-calls').read_bytes()==before)
            if args==['--dry-run']:check('source image is namespaced',json.loads(r.stdout)['tags']==['ghcr.io/acme/tool:source-v1.2.3'])
        for policy in ['1','f alse']:
            before=(c/'calls').read_bytes();e=dict(policy_env,RCH_REQUIRE_REMOTE=policy)
            r=subprocess.run(['bash','-c',driver,'policy'],env=e,capture_output=True,text=True)
            check('strict/invalid source policy '+policy+' refuses without local fallback',
                  r.returncode!=0 and (c/'calls').read_bytes()==before)
print(json.dumps({'cohort':cohort,'assertions':checks,'passed':True,'boundary':'R2 transport/RCH/Docker; real Git, Minisign, archives and processes'}),flush=True)
PY
}

if [[ "${1:-}" == --published-only ]]; then
    published_release_cases
    exit $?
fi
if [[ "${1:-}" == --publisher-only ]]; then
    published_release_cases publisher
    exit $?
fi

# Independent cases use their own directories and child environment. Run them
# alongside the original suite to retain the runner's unchanged 120s bound.
published_release_cases export &
published_export_pid=$!
published_release_cases publisher &
published_publisher_pid=$!

if [[ "${1:-}" != --cli-only ]]; then
new_case dry
capture build --push --dry-run
check 'dry run succeeds without Docker interaction' test "$status" -eq 0
check 'dry run invokes no external adapters' no_calls
check 'dry run is a plan, not built' jq -e '.status == "planned" and .dry_run == true and .digest == null' "$CASE/stdout"
check 'nested Dockerfile retains repository build context' jq -e --arg root "$REPO" '.context == $root and .dockerfile == ($root + "/docker/Dockerfile")' "$CASE/stdout"
check 'latest is not silently published' jq -e '.tags == ["ghcr.io/acme/tool:v1.2.3"]' "$CASE/stdout"
export DRY_RUN=true
capture release
check 'global dry run propagates through release' test "$status" -eq 0
check 'global dry run has no setup/push/sign/scan effects' no_calls
capture docker_setup_buildx
check 'direct builder setup honors global dry run' test "$status" -eq 0
check 'direct builder setup plan has no Docker effects' no_calls
capture docker_build_json tool 1.2.3 --repo-path "$REPO"
check 'JSON wrapper distinguishes planned status' jq -e '.status == "planned" and .exit_code == 0' "$CASE/stdout"
check 'dry run creates no OCI output directory' absent "$DOCKER_OUTPUT_DIR"

new_case registry
capture build --push --tag latest --tag latest
check 'registry build succeeds' test "$status" -eq 0
check 'build returns exactly one machine-readable receipt' jq -e -s 'length == 1 and .[0].status == "built"' "$CASE/stdout"
check 'receipt captures immutable build result' jq -e --arg digest "$DK_DIGEST" '.digest == $digest and .reference == ("ghcr.io/acme/tool@"+$digest)' "$CASE/stdout"
check 'explicit duplicate tags are deduplicated' jq -e '.tags == ["ghcr.io/acme/tool:v1.2.3","ghcr.io/acme/tool:latest"]' "$CASE/stdout"
check 'build explicitly selects named builder' jq -e -s 'any(.[]; .[0:2] == ["buildx","build"] and .[index("--builder")+1] == "dsr-test-builder")' "$DK_CALLS"
check 'build uses correct source root, not Dockerfile parent' jq -e -s --arg repo "$REPO" 'any(.[]; .[0:2] == ["buildx","build"] and .[-1] == $repo)' "$DK_CALLS"
check 'builder selection is not changed globally' no_call_kind use
check 'push enables build provenance and SBOM outputs' jq -e -s 'any(.[]; index("--push") != null and index("--provenance=true") != null and index("--sbom=true") != null)' "$DK_CALLS"

new_case oci
capture build
check 'default non-push build exports OCI archive' test "$status" -eq 0
check 'OCI archive actually exists' test -s "$DOCKER_OUTPUT_DIR/tool-v1.2.3.oci.tar"
check 'OCI receipt binds exported bytes' jq -e --arg sha "$(_dk_hash "$DOCKER_OUTPUT_DIR/tool-v1.2.3.oci.tar")" '.exporter == "oci" and .archive.sha256 == $sha and .archive.size > 0' "$CASE/stdout"
cp "$DOCKER_OUTPUT_DIR/tool-v1.2.3.oci.tar" "$CASE/before.tar"
: > "$DK_CALLS"
capture build
check 'existing OCI output is not overwritten' nonzero "$status"
check 'existing OCI output conflict occurs before build' no_calls
check 'existing archive survives byte-identically' cmp -s "$CASE/before.tar" "$DOCKER_OUTPUT_DIR/tool-v1.2.3.oci.tar"

new_case local
capture build --local --platform linux/arm64
check 'single requested local platform is honored' test "$status" -eq 0
check 'local load retains explicit architecture' jq -e -s 'any(.[]; index("--load") != null and .[index("--platform")+1] == "linux/arm64")' "$DK_CALLS"
capture build --local
check 'default local load is a single builder-default build' test "$status" -eq 0
check 'default local receipt does not invent platform coverage' jq -e '.platforms == [] and .exporter == "docker"' "$CASE/stdout"

for mode in build-fail no-metadata malformed empty-metadata no-digest bad-digest conflict multiple no-archive bootstrap-fail; do
    new_case "$mode"; DK_MODE="$mode"
    capture build
    check "$mode cannot yield success" nonzero "$status"
    check "$mode has no success receipt" test -z "$output"
    check "$mode leaves no final OCI output" absent "$DOCKER_OUTPUT_DIR/tool-v1.2.3.oci.tar"
done

new_case validation
for option in --tool --version --repo-path --dockerfile --platform --tag --output; do
    capture docker_build "$option"
    check "missing $option argument returns invalid arguments" test "$status" -eq 4
done
capture build --push --local
check 'push and local conflict before effects' test "$status" -eq 4
capture build --local --platform linux/amd64,linux/arm64
check 'multiarch load is explicitly rejected' test "$status" -eq 4
capture build --push --output "$CASE/ignored.tar"
check 'registry build cannot silently ignore OCI output' test "$status" -eq 4
capture build --platform linux/amd64,linux/amd64
check 'duplicate architecture rejected' test "$status" -eq 4
capture build --platform 'linux/amd64,'
check 'malformed platform list rejected' test "$status" -eq 4
capture build extra
check 'extra positional argument rejected' test "$status" -eq 4
capture docker_build '../escape' 1.0 --repo-path "$REPO"
check 'unsafe tool identity rejected' test "$status" -eq 4
capture docker_build tool '1.0+unsafe' --repo-path "$REPO"
check 'unsupported tag syntax is not silently normalized' test "$status" -eq 4
check 'all invalid options fail before Docker execution' no_calls

for mode in sign-fail attest-fail syft-fail syft-empty syft-invalid syft-multiple; do
    new_case "$mode"; DK_MODE="$mode"
    capture release
    check "$mode stops release completion" nonzero "$status"
    check "$mode emits no complete release receipt" test -z "$output"
    case "$mode" in syft-*) check "$mode cannot send an invalid attestation" no_call_kind attest ;; esac
done

new_case release
capture release
check 'build/push/sign/attest flow succeeds' test "$status" -eq 0
check 'release refers to immutable built digest' jq -e --arg ref "ghcr.io/acme/tool@$DK_DIGEST" '.reference == $ref and .status == "verified" and .signature == "verified"' "$CASE/stdout"
check 'scanner uses registry transport with pinned child digests' jq -e -s --arg amd64 "registry:ghcr.io/acme/tool@sha256:$DK_AMD64" --arg arm64 "registry:ghcr.io/acme/tool@sha256:$DK_ARM64" \
    '[.[] | select(.[0] == "syft") | .[1]] | sort == ([$amd64,$arm64] | sort)' "$DK_CALLS"
check 'sign and attest never target a mutable tag' jq -e -s 'all(.[] | select(.[0] == "cosign"); .[-1] | test("^ghcr.io/acme/tool@sha256:[0-9a-f]{64}$"))' "$DK_CALLS"
: > "$DK_CALLS"
capture release --skip-sign
check 'explicit skip-sign works without skipping attestation' test "$status" -eq 0
check 'skip-sign is explicitly reported' jq -e '.signature == "skipped" and .sbom == "verified"' "$CASE/stdout"
check 'skip-sign does not invoke image signing' no_call_kind sign
check 'skip-sign still attaches required SBOM' jq -e -s 'any(.[]; index("attest") != null)' "$DK_CALLS"

new_case dependencies
command() {
    [[ "${1:-}" != -v || "${2:-}" != cosign ]] || return 1
    builtin command "$@"
}
capture release
check 'missing signer is rejected before push' test "$status" -eq 3
check 'missing signer causes no external side effects' no_calls
unset -f command

new_case json
DK_MODE=build-fail
capture docker_build_json tool 1.2.3 --repo-path "$REPO" --push
check 'build JSON preserves failure process status' test "$status" -eq 1
check 'build JSON failure is valid structured data' jq -e '.status == "error" and .exit_code == 1 and .result == null' "$CASE/stdout"
DK_MODE=attest-fail
capture docker_release_json tool 1.2.3 --repo-path "$REPO"
check 'release JSON preserves failure process status' test "$status" -eq 1
check 'release JSON does not mix diagnostics into results' jq -e '.status == "error" and .exit_code == 1 and .result == null' "$CASE/stdout"
DK_MODE=''
capture bash "$MODULE" build tool 1.2.3 --repo-path "$REPO" --push
check 'standalone build entry point works' test "$status" -eq 0
capture bash -c 'docker_build tool 1.2.3 --repo-path "$1" --push' bash "$REPO"
check 'exported API carries its helper dependencies' test "$status" -eq 0
capture docker_sign ghcr.io/acme/tool:v1.2.3
check 'standalone signer refuses mutable tag' test "$status" -eq 4

new_case tokens
export GH_TOKEN=third GITHUB_TOKEN=second DSR_GH_TOKEN=first
capture _dk_resolve_gh_token
check 'DSR explicit token has highest precedence' test "$output" = first
unset DSR_GH_TOKEN
capture _dk_resolve_gh_token
check 'GITHUB_TOKEN precedes GH_TOKEN and gh config' test "$output" = second
unset GITHUB_TOKEN
capture _dk_resolve_gh_token
check 'GH_TOKEN precedes gh config' test "$output" = third
export GITHUB_USER=fixture-user
capture docker_login_ghcr
check 'GHCR login uses stdin' test "$status" -eq 0
check 'token bytes travel only over stdin' test "$(cat "$WORK/token.stdin")" = third
check 'token is absent from invocation log' bash -c '! grep -F third "$1"' bash "$DK_CALLS"
check 'token is absent from stdout and stderr' bash -c '! grep -F third "$1" "$2"' bash "$CASE/stdout" "$CASE/stderr"

new_case platform-evidence
capture release
check 'verified receipt covers the exact two requested platforms' jq -e '[.platforms[].platform] == ["linux/amd64","linux/arm64"]' "$CASE/stdout"
check 'each platform has a verified SPDX predicate digest' jq -e 'all(.platforms[]; .status == "verified" and (.predicate_sha256 | test("^[0-9a-f]{64}$")))' "$CASE/stdout"
check 'all platform scans complete before first signature publication' jq -e -s '
    [to_entries[] | select(.value[0] == "syft") | .key] as $scans |
    [to_entries[] | select(.value[0:2] == ["cosign","sign"]) | .key] as $signs |
    ($scans | max) < ($signs | min)' "$DK_CALLS"
check 'signature is on the exact built index, not one platform' jq -e -s --arg ref "ghcr.io/acme/tool@$DK_DIGEST" '
    all(.[] | select(.[0:2] == ["cosign","sign"]); .[-1] == $ref)' "$DK_CALLS"
check 'both attestations are on the platform child manifests' jq -e -s --arg a "ghcr.io/acme/tool@sha256:$DK_AMD64" --arg b "ghcr.io/acme/tool@sha256:$DK_ARM64" '
    [.[] | select(.[0:2] == ["cosign","attest"]) | .[-1]] | sort == ([$a,$b] | sort)' "$DK_CALLS"
check 'verification uses exact trust policy without insecure bypasses' jq -e -s '
    all(.[] | select(.[0] == "cosign" and (.[1] | startswith("verify")));
        .[index("--certificate-identity")+1] == "builder@example.test" and
        .[index("--certificate-oidc-issuer")+1] == "https://issuer.example.test" and
        all(.[]; startswith("--insecure") | not))' "$DK_CALLS"
: > "$DK_CALLS"
DK_SYFT_DISABLED=true
capture docker_verify_release "ghcr.io/acme/tool@$DK_DIGEST" --platform linux/amd64,linux/arm64
check 'standalone verification succeeds without scanner' test "$status" -eq 0
check 'read-only verifier does not scan' no_call_kind syft
check 'read-only verifier does not sign or attest' jq -e -s 'all(.[]; .[0:2] != ["cosign","sign"] and .[0:2] != ["cosign","attest"])' "$DK_CALLS"
check 'read-only verifier does not build, log in, or select builder' jq -e -s '
    all(.[]; .[0] != "login" and .[0:2] != ["buildx","build"] and .[0:2] != ["buildx","inspect"] and .[0:2] != ["buildx","create"])' "$DK_CALLS"
capture bash "$MODULE" verify "ghcr.io/acme/tool@$DK_DIGEST"
check 'standalone verification CLI dispatch works' test "$status" -eq 0
capture bash -c 'docker_verify_release "$1"' bash "ghcr.io/acme/tool@$DK_DIGEST"
check 'exported verifier has all required helper functions' test "$status" -eq 0
capture docker_verify_release "ghcr.io/acme/tool@$DK_DIGEST" --platform linux/amd64
check 'verifier enforces explicitly requested complete platform set' test "$status" -eq 7
capture docker_verify_release "ghcr.io/acme/tool@$DK_DIGEST" --certificate-identity stranger@example.test
check 'wrong signer identity cannot verify' test "$status" -eq 7
capture docker_verify_release "ghcr.io/acme/tool@$DK_DIGEST" --certificate-oidc-issuer https://wrong.example.test
check 'wrong OIDC issuer cannot verify' test "$status" -eq 7

new_case missing-policy
unset DOCKER_CERTIFICATE_IDENTITY DOCKER_CERTIFICATE_OIDC_ISSUER
capture release
check 'missing trust policy stops release before push' test "$status" -eq 4
check 'missing trust policy invokes no external adapters' no_calls
capture release --dry-run
check 'planning does not require live authentication policy' test "$status" -eq 0
check 'policy-free planning still has no external effects' no_calls
capture release --certificate-identity builder@example.test --certificate-oidc-issuer https://issuer.example.test
check 'explicit trust policy flags work without environment defaults' test "$status" -eq 0

for mode in registry-fail raw-corrupt config-mismatch tag-drift; do
    new_case "registry-$mode"; DK_MODE="$mode"
    capture release
    check "$mode prevents release completion" nonzero "$status"
    check "$mode is rejected before scanning" no_call_kind syft
    check "$mode is rejected before signing" no_call_kind cosign
done

for shape in missing extra duplicate unknown unbound-evidence bad-size bad-digest empty; do
    new_case "index-$shape"
    case "$shape" in
        missing) edit_index '.manifests = [.manifests[0]]' ;;
        extra) edit_index '.manifests += [(.manifests[0] | .platform.architecture = "s390x")]' ;;
        duplicate) edit_index '.manifests += [.manifests[0]]' ;;
        unknown) edit_index '.manifests[0].platform = {os:"unknown",architecture:"unknown"}' ;;
        unbound-evidence) edit_index '.manifests += [(.manifests[0] | .platform = {os:"unknown",architecture:"unknown"} |
            .annotations = {"vnd.docker.reference.type":"attestation-manifest","vnd.docker.reference.digest":("sha256:"+("0"*64))})]' ;;
        bad-size) edit_index '.manifests[0].size += 1' ;;
        bad-digest) edit_index '.manifests[0].digest = "sha256:bad"' ;;
        empty) edit_index '.manifests = []' ;;
    esac
    capture release
    check "$shape registry inventory is not a complete release" test "$status" -eq 7
    check "$shape inventory cannot produce Cosign evidence" no_call_kind cosign
done

new_case buildkit-evidence
edit_index '.manifests += [(.manifests[0] | .platform = {os:"unknown",architecture:"unknown"} |
    .annotations = {"vnd.docker.reference.type":"attestation-manifest","vnd.docker.reference.digest":.digest})]'
capture release
check 'recognized BuildKit evidence does not invent an executable platform' test "$status" -eq 0
check 'BuildKit evidence is not scanned as an extra architecture' jq -e '.platforms | length == 2' "$CASE/stdout"

new_case arm64-variant
edit_index '.manifests[1].platform.variant = "v8"'
capture release --platform linux/amd64,linux/arm64/v8
check 'default arm64 variant is normalized without losing coverage' test "$status" -eq 0
check 'arm64 variant receipt has stable platform identity' jq -e '[.platforms[].platform] == ["linux/amd64","linux/arm64"]' "$CASE/stdout"

new_case single-image
export DK_DIGEST="sha256:$DK_AMD64"
capture release --platform linux/amd64
check 'single image manifest works without an index' test "$status" -eq 0
check 'single manifest uses platform from its configuration' jq -e '[.platforms[].platform] == ["linux/amd64"]' "$CASE/stdout"
capture release
check 'single manifest cannot satisfy two-platform release' test "$status" -eq 7

for mode in false-sign empty-sign wrong-sign-digest verify-sign-fail false-attest empty-attestation malformed-envelope wrong-envelope verify-attest-fail wrong-subject wrong-subject-name wrong-predicate-type changed-predicate; do
    new_case "$mode"; DK_MODE="$mode"
    capture release
    check "$mode cannot masquerade as verified release" test "$status" -eq 7
    check "$mode has no completion receipt" test -z "$output"
done

new_case second-scan-fail
DK_MODE=second-scan-fail
capture release
check 'second architecture scan failure propagates' test "$status" -eq 1
check 'second scan failure publishes no partial Cosign evidence' no_call_kind cosign

new_case interrupted-evidence
DK_MODE=second-attest-fail
capture release
check 'second architecture upload failure propagates' test "$status" -eq 1
check 'already-published first-platform attestation is retained' test -s "$DK_REGISTRY/attestations/$DK_AMD64.jsonl"
check 'interrupted evidence publication emits no complete receipt' test -z "$output"
DK_MODE=''
: > "$DK_CALLS"
capture docker_attest_sbom "ghcr.io/acme/tool@$DK_DIGEST"
check 'existing digest can finish attestations without rebuilding' test "$status" -eq 0
check 'evidence recovery never invokes a build' jq -e -s 'all(.[]; .[0:2] != ["buildx","build"])' "$DK_CALLS"
capture docker_verify_release "ghcr.io/acme/tool@$DK_DIGEST"
check 'recovered multiarch release independently verifies' test "$status" -eq 0

new_case old-attestations
capture release
check 'initial attestation set succeeds' test "$status" -eq 0
cp "$CASE/stdout" "$CASE/first-receipt.json"
DK_SCAN_NONCE=-new-scan
capture release
check 'old valid attestations do not prevent verifying a new matching scan' test "$status" -eq 0
check 'release receipt binds new predicates rather than retained old ones' jq -e --slurpfile old "$CASE/first-receipt.json" '
    [.platforms[].predicate_sha256] != [$old[0].platforms[].predicate_sha256]' "$CASE/stdout"
check 'existing attestations are not deleted on a newer scan' test "$(wc -l < "$DK_REGISTRY/attestations/$DK_AMD64.jsonl")" -eq 2

new_case late-tag-drift
DK_MODE=late-tag-drift
capture release
check 'tag drift after evidence publication prevents completion' test "$status" -eq 7
check 'late tag drift does not delete already-published attestations' test -s "$DK_REGISTRY/attestations/$DK_ARM64.jsonl"
check 'late tag drift emits no misleading success receipt' test -z "$output"
fi

# Exercise the actual public executable, not sourced forwarding functions.
# External tools remain explicit recording fixtures; no live container build,
# registry, OIDC service, or cryptographic signature is claimed by these tests.
cli_receipts=0
cli_capture() {
    capture bash "$CLI" --json "$@"
    cli_receipts=$((cli_receipts+1))
    cp "$CASE/stdout" "$CASE/cli-$cli_receipts.json"
    check "public invocation $cli_receipts emits exactly one envelope" jq -e -s \
        'length == 1 and (.[0] | type == "object" and
         (.status == "success" or .status == "error") and
         (.exit_code | type == "number") and (.details | type == "object"))' "$CASE/stdout"
}

for placement in global local; do
    for operation in build release sign setup verify attest; do
        new_case "cli-plan-$placement-$operation"
        args=()
        case "$operation" in
            build|release)
                args=(tool v1.2.3 --repo-path "$REPO" --dockerfile docker/Dockerfile --tag stable --platform linux/amd64)
                [[ "$operation" != build ]] || args+=(--push) ;;
            sign|verify|attest) args=("ghcr.io/acme/tool@$DK_DIGEST") ;;
        esac
        if [[ "$placement" == global ]]; then
            cli_capture --dry-run docker "$operation" "${args[@]}"
        else
            cli_capture docker "$operation" "${args[@]}" --dry-run
        fi
        check "$operation $placement dry run succeeds" test "$status" -eq 0
        check "$operation $placement plan never claims completed work" jq -e \
            '.status == "success" and .details.status == "planned" and .details.dry_run == true and
             .details.result.status == "planned" and .details.pushed != true and
             .details.signed != true and .details.ready != true' "$CASE/stdout"
        check "$operation $placement plan invokes no external adapters" no_calls
        check "$operation $placement plan creates no output or state" bash -c \
            '[[ ! -e "$1" && ! -e "$2" && ! -e "$3" ]]' bash "$DOCKER_OUTPUT_DIR" "$DSR_STATE_DIR" "$DSR_CACHE_DIR"
    done
done

new_case cli-custom-oci
cli_capture docker build tool v1.2.3 --repo-path "$REPO" --dockerfile docker/Dockerfile \
    --output "$CASE/custom output/image.tar" --tag stable --tag stable --platform linux/amd64
check 'public OCI build succeeds with explicit paths and tags' test "$status" -eq 0
check 'public OCI receipt binds actual exported bytes' jq -e \
    --arg sha "$(_dk_hash "$CASE/custom output/image.tar")" --arg root "$REPO" \
    '.details.status == "built" and .details.dry_run == false and .details.pushed == false and
     .details.result.context == $root and .details.result.dockerfile == ($root + "/docker/Dockerfile") and
     .details.result.archive.sha256 == $sha and .details.result.archive.size > 0 and
     .details.result.platforms == ["linux/amd64"] and
     .details.result.tags == ["ghcr.io/acme/tool:v1.2.3","ghcr.io/acme/tool:stable"]' "$CASE/stdout"
check 'public build forwards nested Dockerfile and root context as separate arguments' jq -e -s --arg root "$REPO" \
    'any(.[]; .[0:2] == ["buildx","build"] and .[-1] == $root and
     .[index("--file")+1] == ($root + "/docker/Dockerfile"))' "$DK_CALLS"
capture bash "$CLI" docker build tool 1.2.3 --repo-path "$REPO" --local --platform linux/arm64
check 'non-JSON public build retains one module receipt' jq -e -s \
    'length == 1 and .[0].status == "built" and .[0].exporter == "docker" and .[0].platforms == ["linux/arm64"]' "$CASE/stdout"
check 'public local exporter preserves honest attestation capabilities' jq -e -s \
    'any(.[]; index("--load") != null and index("--provenance=false") != null and index("--sbom=false") != null)' "$DK_CALLS"

new_case cli-setup
DK_MODE=builder-absent
cli_capture docker setup
check 'public setup creates and bootstraps an absent named builder' test "$status" -eq 0
check 'public setup reports completed readiness' jq -e \
    '.details.status == "ready" and .details.ready == true and .details.dry_run == false and
     .details.result.builder == "dsr-test-builder"' "$CASE/stdout"
check 'public setup uses explicit builder without changing global selection' jq -e -s \
    'any(.[]; .[0:2] == ["buildx","create"] and .[index("--name")+1] == "dsr-test-builder") and
     any(.[]; .[0:2] == ["buildx","inspect"] and index("--bootstrap") != null) and
     all(.[]; index("--use") == null and index("use") == null)' "$DK_CALLS"

new_case cli-sign
cli_capture docker sign "ghcr.io/acme/tool@$DK_DIGEST"
check 'public standalone sign reports acknowledged write without verification' jq -e \
    '.details.status == "signed" and .details.signed == true and .details.verified == false and
     .details.result.verified == false and .details.dry_run == false' "$CASE/stdout"
check 'signer diagnostics stay on stderr' bash -c \
    '[[ "$(cat "$1")" == *"signer diagnostic on stdout"* ]]' bash "$CASE/stderr"

new_case cli-release-verify
unset DOCKER_CERTIFICATE_IDENTITY DOCKER_CERTIFICATE_OIDC_ISSUER
cli_capture docker release tool v1.2.3 --repo-path "$REPO" --dockerfile docker/Dockerfile \
    --platform linux/amd64,linux/arm64 --tag stable --certificate-identity builder@example.test \
    --certificate-oidc-issuer https://issuer.example.test
check 'public release completes all existing verification gates' test "$status" -eq 0
check 'public release preserves verified physical inventory and immutable reference' jq -e \
    --arg ref "ghcr.io/acme/tool@$DK_DIGEST" \
    '.details.status == "verified" and .details.pushed == true and .details.dry_run == false and
     .details.result.reference == $ref and .details.result.signature == "verified" and
     .details.result.sbom == "verified" and
     [.details.result.platforms[].platform] == ["linux/amd64","linux/arm64"]' "$CASE/stdout"
: > "$DK_CALLS"
DK_SYFT_DISABLED=true
cli_capture docker verify "ghcr.io/acme/tool@$DK_DIGEST" --platform linux/amd64,linux/arm64 \
    --certificate-identity builder@example.test --certificate-oidc-issuer https://issuer.example.test
check 'public verifier works with scanner disabled and explicit trust policy' test "$status" -eq 0
check 'public verifier returns independently checked signature and per-platform evidence' jq -e \
    '.details.status == "verified" and .details.result.signature == "verified" and
     (.details.result.platforms | length == 2) and
     all(.details.result.platforms[]; .status == "verified" and (.predicate_sha256 | test("^[0-9a-f]{64}$")))' "$CASE/stdout"
check 'public verifier has no build, login, scan, sign, attest, or builder effects' jq -e -s \
    'all(.[]; .[0] != "syft" and .[0] != "gh" and .[0] != "login" and
     .[0:2] != ["buildx","build"] and .[0:2] != ["buildx","create"] and .[0:2] != ["buildx","inspect"] and
     .[0:2] != ["cosign","sign"] and .[0:2] != ["cosign","attest"])' "$DK_CALLS"
export DOCKER_CERTIFICATE_IDENTITY=builder@example.test DOCKER_CERTIFICATE_OIDC_ISSUER=https://issuer.example.test
for mode in raw-corrupt registry-fail verify-sign-fail empty-attestation wrong-sign-digest; do
    DK_MODE="$mode"
    cli_capture docker verify "ghcr.io/acme/tool@$DK_DIGEST"
    expected_code=7
    [[ "$mode" != registry-fail ]] || expected_code=8
    check "public verifier preserves $mode exit code" test "$status" -eq "$expected_code"
    check "public verifier cannot claim success for $mode" jq -e --argjson code "$expected_code" \
        '.status == "error" and .exit_code == $code and .details.status == "error" and .details.result == null' "$CASE/stdout"
done
DK_MODE=''
for mismatch in platform identity issuer; do
    case "$mismatch" in
        platform) args=(--platform linux/amd64) ;;
        identity) args=(--certificate-identity stranger@example.test) ;;
        issuer) args=(--certificate-oidc-issuer https://wrong.example.test) ;;
    esac
    cli_capture docker verify "ghcr.io/acme/tool@$DK_DIGEST" "${args[@]}"
    check "public verifier rejects mismatched $mismatch" test "$status" -eq 7
done

new_case cli-evidence-recovery
DK_MODE=second-attest-fail
cli_capture docker release tool 1.2.3 --repo-path "$REPO"
check 'public release reports partial attestation failure' test "$status" -eq 1
check 'failed release does not invent completion or absence of partial writes' jq -e \
    '.status == "error" and .details.status == "error" and .details.result == null and
     (.details | has("pushed") | not)' "$CASE/stdout"
check 'public failed release retains already-published child evidence' test -s "$DK_REGISTRY/attestations/$DK_AMD64.jsonl"
DK_MODE=''
: > "$DK_CALLS"
cli_capture docker attest "ghcr.io/acme/tool@$DK_DIGEST" --platform linux/amd64,linux/arm64
check 'public attestation recovery succeeds without rebuilding' test "$status" -eq 0
check 'public recovery reports the root signature as not checked' jq -e \
    '.details.status == "verified" and .details.result.signature == "not_checked" and
     [.details.result.platforms[].platform] == ["linux/amd64","linux/arm64"]' "$CASE/stdout"
check 'public recovery never rebuilds or signs the root' jq -e -s \
    'all(.[]; .[0:2] != ["buildx","build"] and .[0:2] != ["cosign","sign"])' "$DK_CALLS"
cli_capture docker verify "ghcr.io/acme/tool@$DK_DIGEST"
check 'public recovered release independently verifies its full evidence set' test "$status" -eq 0
check 'public post-recovery verification establishes the root signature' jq -e \
    '.details.result.signature == "verified" and .details.result.operation == "verify"' "$CASE/stdout"

new_case cli-invalid-arguments
for option in --tool --version --repo-path --dockerfile --platform --tag --output; do
    cli_capture --dry-run docker build "$option"
    check "public build diagnoses missing $option value" test "$status" -eq 4
    check "public build reports $option as an argument error" jq -e \
        '.status == "error" and .exit_code == 4 and .details.status == "error"' "$CASE/stdout"
done
for operation in release verify attest; do
    for option in --certificate-identity --certificate-oidc-issuer; do
        if [[ "$operation" == release ]]; then args=(tool 1.2.3 --repo-path "$REPO")
        else args=("ghcr.io/acme/tool@$DK_DIGEST"); fi
        cli_capture --dry-run docker "$operation" "${args[@]}" "$option"
        check "public $operation diagnoses missing $option value" test "$status" -eq 4
    done
done
for option in --tag --repo-path --platform; do
    case "$option" in
        --tag) missing_value=stable ;;
        --repo-path) missing_value="$REPO" ;;
        --platform) missing_value=linux/amd64 ;;
    esac
    for policy in --skip-sign --certificate-identity; do
        args=(tool 1.2.3 --repo-path "$REPO" "$option" "$policy")
        [[ "$policy" != --certificate-identity ]] || args+=(builder@example.test)
        args+=("$missing_value")
        cli_capture --dry-run docker release "${args[@]}"
        check "public release rejects $option interrupted by $policy" test "$status" -eq 4
        check "missing $option cannot change policy interpretation" bash -c \
            '[[ "$(cat "$1")" == *"$2"* ]]' bash "$CASE/stderr" "Missing value for $option"
    done
done
for operation in build release sign setup verify attest; do
    case "$operation" in
        build|release) args=(tool 1.2.3 --repo-path "$REPO") ;;
        sign|verify|attest) args=("ghcr.io/acme/tool@$DK_DIGEST") ;;
        setup) args=() ;;
    esac
    cli_capture --dry-run docker "$operation" "${args[@]}" extra
    check "public $operation refuses excess positional arguments" test "$status" -eq 4
done
for operation in sign verify attest; do
    cli_capture --dry-run docker "$operation" ghcr.io/acme/tool:v1.2.3
    check "public $operation refuses a mutable tag even in plans" test "$status" -eq 4
done
cli_capture --dry-run docker unknown-command
check 'unknown public container command returns argument error' test "$status" -eq 4
check 'all malformed public invocations fail before external operations' no_calls
check 'invalid public dry runs do not create state' absent "$DSR_STATE_DIR"

# JSON Schema is an additional contract check when its test-only dependency is
# installed. The executable assertions above always run and remain decisive.
if python3 -c 'import jsonschema' >/dev/null 2>&1; then
    check 'all public envelopes satisfy the published JSON schema' python3 - "$ROOT/schemas/envelope.json" "$WORK/cases" <<'PY'
import json
import pathlib
import sys
import jsonschema
schema = json.loads(pathlib.Path(sys.argv[1]).read_text())
receipts = list(pathlib.Path(sys.argv[2]).glob('*/cli-*.json'))
assert receipts
for receipt in receipts:
    jsonschema.validate(json.loads(receipt.read_text()), schema)
PY
else
    printf 'NOTE: optional envelope JSON Schema validation unavailable (python3 jsonschema missing).\n'
fi

printf '\nContainer regression checks: %d; failures: %d\n' "$checks" "$failures"
wait "$published_export_pid" || failures=$((failures+1))
wait "$published_publisher_pid" || failures=$((failures+1))
[[ "$failures" -eq 0 ]]
