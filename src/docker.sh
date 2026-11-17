#!/usr/bin/env bash
# Multi-architecture container builds and releases (bd-1jt.3.8).
# stdout is JSON for builds/releases, stderr is diagnostics. External tool
# acknowledgements are not independent signature or registry verification.

DOCKER_REGISTRY="${DOCKER_REGISTRY:-ghcr.io/dicklesworthstone}"
DOCKER_PLATFORMS="${DOCKER_PLATFORMS:-linux/amd64,linux/arm64}"
DOCKER_BUILDER_NAME="${DOCKER_BUILDER_NAME:-dsr-builder}"
DOCKER_CONTAINERIZED_TOOLS="${DOCKER_CONTAINERIZED_TOOLS:-ubs,mcp_agent_mail,process_triage}"

_dk_log_info() { printf '[docker] %s\n' "$*" >&2; }
_dk_log_ok() { _dk_log_info "$@"; }
_dk_log_warn() { printf '[docker:warn] %s\n' "$*" >&2; }
_dk_log_error() { printf '[docker:error] %s\n' "$*" >&2; }
_dk_log_debug() { [[ "${DOCKER_DEBUG:-}" != 1 ]] || _dk_log_info "$@"; }

_dk_dependency() {
    command -v "$1" >/dev/null 2>&1 || {
        _dk_log_error "$1 is required"; return 3;
    }
}
docker_check() {
    _dk_dependency docker || return $?
    docker info >/dev/null 2>&1 || { _dk_log_error 'Docker daemon unavailable'; return 3; }
}
docker_check_buildx() {
    docker_check || return $?
    docker buildx version >/dev/null 2>&1 || { _dk_log_error 'Docker buildx unavailable'; return 3; }
}
docker_check_cosign() { _dk_dependency cosign; }
docker_version() {
    docker_check || return $?
    docker version --format '{{.Server.Version}}'
}

# Never change the operator's globally selected builder. Every build passes
# --builder explicitly. Inspect/bootstrap the named builder, including on reuse.
docker_setup_buildx() {
    local builder="${1:-${DOCKER_BUILDER_NAME:-dsr-builder}}"
    [[ $# -le 1 && "$builder" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || return 4
    [[ "${DRY_RUN:-false}" =~ ^(true|false)$ ]] || return 4
    if [[ "${DRY_RUN:-false}" == true ]]; then
        _dk_log_info "[dry-run] Would prepare builder $builder"
        return 0
    fi
    docker_check_buildx || return $?
    if ! docker buildx inspect "$builder" >/dev/null 2>&1; then
        if ! docker buildx create --name "$builder" --driver docker-container >&2; then
            # Another process may have created this same builder.
            docker buildx inspect "$builder" >/dev/null 2>&1 || return 1
        fi
    fi
    docker buildx inspect "$builder" --bootstrap >&2 || return 1
}

# Public setup has the same no-effects planning contract as builds. Keep the
# lower-level builder helper quiet on stdout for callers that produce receipts.
docker_setup() {
    local dry="${DRY_RUN:-false}" builder="${DOCKER_BUILDER_NAME:-dsr-builder}" status=ready
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run|-n) dry=true; shift ;;
            --help|-h)
                printf '%s\n' 'docker_setup - Prepare the named Buildx builder' \
                    'Usage: docker_setup [--dry-run]' \
                    'DOCKER_BUILDER_NAME selects the builder; the global selection is unchanged.' >&2
                return 0 ;;
            *) _dk_log_error "Unexpected setup argument: $1"; return 4 ;;
        esac
    done
    [[ "$builder" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ && "$dry" =~ ^(true|false)$ ]] || return 4
    _dk_dependency jq || return $?
    if [[ "$dry" == true ]]; then status=planned
    else docker_setup_buildx "$builder" || return $?; fi
    jq -nc --arg builder "$builder" --arg status "$status" --argjson dry "$dry" '
        {schema_version:1,kind:"dsr-container-setup",status:$status,builder:$builder,
         dry_run:$dry,ready:($status == "ready")}'
}

# Explicit environment choices win; do not accidentally prefer another account
# selected in gh's local config. Never expose the token in an argument or log.
_dk_resolve_gh_token() {
    local token="${DSR_GH_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-}}}"
    if [[ -z "$token" ]] && declare -F secrets_get_gh_token >/dev/null; then
        token=$(secrets_get_gh_token 2>/dev/null) || return 1
    fi
    if [[ -z "$token" ]] && command -v gh >/dev/null 2>&1; then
        token=$(gh auth token --hostname github.com 2>/dev/null) || return 1
    fi
    [[ -n "$token" && "$token" != *[[:cntrl:]]* ]] || return 1
    printf '%s' "$token"
}
# A token's presence is NOT proof of registry authorization. Login performs the
# check; builds can instead use the operator's existing Docker credential store.
docker_check_ghcr_auth() { docker_login_ghcr; }
docker_login_ghcr() (
    set +x
    set -o pipefail
    local token username="${GITHUB_USER:-${USER:-}}"
    [[ -n "$username" && "$username" != -* && "$username" != *[[:cntrl:]]* ]] || {
        _dk_log_error 'GITHUB_USER is required for GHCR login'; return 3;
    }
    token=$(_dk_resolve_gh_token) || { _dk_log_error 'No GitHub token available'; return 3; }
    printf '%s' "$token" | docker login ghcr.io -u "$username" --password-stdin >/dev/null 2>&1 || {
        _dk_log_error 'GHCR login failed'; return 3;
    }
)

docker_is_containerized() {
    [[ ",${DOCKER_CONTAINERIZED_TOOLS:-ubs,mcp_agent_mail,process_triage}," == *",$1,"* ]]
}
docker_find_dockerfile() {
    local tool="$1" root="${2:-/data/projects/$1}" path
    [[ -n "$tool" ]] || return 4
    for path in "$root/Dockerfile" "$root/docker/Dockerfile" "$root/build/Dockerfile"; do
        if [[ -f "$path" && ! -L "$path" ]]; then printf '%s\n' "$path"; return 0; fi
    done
    return 1
}
_dk_tag_valid() { [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]]; }
# Deliberately conservative qualified registry/repository grammar; no implicit
# Docker Hub namespace, URL, embedded credentials, option, or shell syntax.
_dk_repository_valid() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9.-]*(:[0-9]+)?(/[a-z0-9]+([._-][a-z0-9]+)*)+$ ]]
}
_dk_pinned_valid() {
    [[ "$1" == *@sha256:* ]] || return 4
    _dk_repository_valid "${1%@*}" && [[ "${1##*@}" =~ ^sha256:[0-9a-f]{64}$ ]]
}
_dk_platforms() {
    local value="$1" platform seen=','
    local -a entries=()
    [[ -n "$value" && "$value" != ,* && "$value" != *, && "$value" != *,,* ]] || return 4
    IFS=',' read -r -a entries <<< "$value"
    for platform in "${entries[@]}"; do
        [[ "$platform" =~ ^linux/[a-z0-9_]+(/[a-z0-9_.-]+)?$ && "$seen" != *",$platform,"* ]] || return 4
        seen+="$platform,"
    done
    printf '%s\n' "${entries[@]}" | jq -Rsc 'split("\n")[:-1]'
}
_dk_hash() {
    local value
    [[ -f "$1" && ! -L "$1" ]] || return 4
    if command -v sha256sum >/dev/null 2>&1; then value=$(sha256sum < "$1") || return 1
    elif command -v shasum >/dev/null 2>&1; then value=$(shasum -a 256 < "$1") || return 1
    else return 3; fi
    value="${value%% *}"
    [[ "$value" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$value"
}

# Parse/resolve a build plan without invoking Docker, login, Syft, or Cosign,
# creating directories, or writing an output. Also used for release preflight.
_dk_build_plan() {
    local tool='' version='' root='' dockerfile='' output='' mode=oci
    local push=false local_only=false explicit_platform=false published=false dry="${DRY_RUN:-false}"
    local platforms="${DOCKER_PLATFORMS:-linux/amd64,linux/arm64}" tags='[]' tag image builder artifact_policy=false
    local -a extra_tags=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tool|-t|--version|-V|--repo-path|--dockerfile|--platform|-p|--tag|--output)
                [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || { _dk_log_error "Missing value for $1"; return 4; }
                case "$1" in
                    --tool|-t) [[ -z "$tool" ]] || return 4; tool="$2" ;;
                    --version|-V) [[ -z "$version" ]] || return 4; version="$2" ;;
                    --repo-path) root="$2" ;;
                    --dockerfile) dockerfile="$2" ;;
                    --platform|-p) platforms="$2"; explicit_platform=true ;;
                    --tag) extra_tags+=("$2") ;;
                    --output) output="$2" ;;
                esac
                shift 2 ;;
            --push) push=true; shift ;;
            --published-release) published=true; shift ;;
            --local) local_only=true; shift ;;
            --dry-run|-n) dry=true; shift ;;
            -*) _dk_log_error "Unknown option: $1"; return 4 ;;
            *)
                if [[ -z "$tool" ]]; then tool="$1"
                elif [[ -z "$version" ]]; then version="$1"
                else _dk_log_error 'Unexpected positional argument'; return 4; fi
                shift ;;
        esac
    done
    [[ -n "$tool" ]] || { _dk_log_error 'Tool name required'; return 4; }
    [[ -n "$version" ]] || { _dk_log_error 'Version required'; return 4; }
    [[ "$tool" =~ ^[a-z0-9]+([._-][a-z0-9]+)*$ ]] || return 4
    tag="v${version#v}"
    _dk_tag_valid "$tag" || { _dk_log_error 'Version is not a valid container tag'; return 4; }
    image="${DOCKER_REGISTRY:-ghcr.io/dicklesworthstone}/$tool"
    _dk_repository_valid "$image" || { _dk_log_error 'Invalid container repository'; return 4; }
    builder="${DOCKER_BUILDER_NAME:-dsr-builder}"
    if declare -F config_get_tool_field >/dev/null; then
        artifact_policy=$(config_get_tool_field "$tool" container_release_from_published_assets false) || return 4
        [[ "$artifact_policy" == true || "$artifact_policy" == false ]] || return 4
    fi
    [[ "$builder" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ && "$dry" =~ ^(true|false)$ ]] || return 4
    $push && $local_only && { _dk_log_error '--push and --local conflict'; return 4; }
    if $push; then mode=registry; elif $local_only; then mode=docker; fi
    [[ "$mode" == oci || -z "$output" ]] || { _dk_log_error '--output is only for OCI export'; return 4; }
    _dk_dependency jq || return $?
    local platforms_json
    if $local_only && ! $explicit_platform; then
        platforms_json='[]'; platforms=''
    else
        platforms_json=$(_dk_platforms "$platforms") || { _dk_log_error 'Invalid or duplicate Linux platforms'; return 4; }
        [[ "$mode" != docker || "$platforms" != *,* ]] || { _dk_log_error '--local loads only one platform'; return 4; }
    fi
    for tag in "v${version#v}" "${extra_tags[@]}"; do
        if [[ "$artifact_policy" == true && "$published" == false ]]; then
            if [[ "$tag" == "v${version#v}" ]]; then tag="source-$tag"
            elif [[ "$tag" != source-* ]]; then
                _dk_log_error 'Source containers cannot overwrite stable release tags'; return 4
            fi
        fi
        _dk_tag_valid "$tag" || return 4
        tags=$(jq -c --arg tag "$image:$tag" 'if index($tag) then . else . + [$tag] end' <<< "$tags") || return 1
    done
    if [[ -z "$root" ]] && declare -F config_get_tool_field >/dev/null; then
        root=$(config_get_tool_field "$tool" local_path '' 2>/dev/null) || return 4
    fi
    [[ -n "$root" ]] || root="/data/projects/$tool"
    [[ -d "$root" && ! -L "$root" && "$root" != *[[:cntrl:]]* ]] || { _dk_log_error "Invalid repository path: $root"; return 4; }
    root=$(cd "$root" && pwd -P) || return 4
    if $published; then
        [[ "v${version#v}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$ &&
           "$mode" == oci && "$local_only" == false &&
           "$(jq -c 'sort' <<< "$platforms_json")" == '["linux/amd64","linux/arm64"]' &&
           ( -z "$dockerfile" || "$dockerfile" == Dockerfile.release || "$dockerfile" == "$root/Dockerfile.release" ) ]] || {
            _dk_log_error 'Published release builds require OCI export, an exact version, Dockerfile.release and both GNU Linux platforms'; return 4;
        }
        dockerfile="$root/Dockerfile.release"
    fi
    if [[ -z "$dockerfile" ]]; then
        dockerfile=$(docker_find_dockerfile "$tool" "$root") || { _dk_log_error 'No Dockerfile found'; return 7; }
    elif [[ "$dockerfile" != /* ]]; then dockerfile="$root/$dockerfile"; fi
    [[ -f "$dockerfile" && ! -L "$dockerfile" && "$dockerfile" != *[[:cntrl:]]* ]] || return 4
    dockerfile="$(cd "$(dirname "$dockerfile")" && pwd -P)/$(basename "$dockerfile")"
    [[ "$dockerfile" == "$root/"* ]] || { _dk_log_error 'Dockerfile must be inside the repository context'; return 4; }
    if [[ "$mode" == oci ]]; then
        [[ -n "$output" ]] || output="${DOCKER_OUTPUT_DIR:-${DSR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsr}/containers}/$tool-v${version#v}.oci.tar"
        [[ "$output" == /* ]] || output="$PWD/$output"
        [[ "$output" != *[[:cntrl:]]* && "$output" != *','* && "$output" != */ &&
           ! -e "$output" && ! -L "$output" ]] || { _dk_log_error 'OCI output already exists or is unsafe'; return 4; }
    fi
    jq -nc --arg tool "$tool" --arg version "v${version#v}" --arg repository "$image" \
        --arg root "$root" --arg dockerfile "$dockerfile" --arg builder "$builder" --arg exporter "$mode" \
        --arg output "$output" --argjson tags "$tags" --argjson platforms "$platforms_json" --argjson dry "$dry" \
        --argjson published "$published" '
        {schema_version:1,kind:"dsr-container-build",status:"planned",tool:$tool,version:$version,
         repository:$repository,tags:$tags,context:$root,dockerfile:$dockerfile,builder:$builder,
         exporter:$exporter,platforms:$platforms,dry_run:$dry,
         output_file:(if $output == "" then null else $output end)} +
        (if $published then {published_release:true} else {} end)'
}

# Call only inside the private helper subshells. Hooks and callers may export
# repository selectors; even `git -C` would then use their index/object store.
_dk_clear_git_context() {
    local names name
    names=$(git rev-parse --local-env-vars) || return 7
    while IFS= read -r name; do
        [[ "$name" =~ ^GIT_[A-Z0-9_]+$ ]] || return 7
        unset "$name" || return 7
    done <<< "$names"
    export GIT_NO_REPLACE_OBJECTS=1
}

# Resolve the public release independently of local build state. Existing DSR
# transport and Minisign verification remain authoritative; never synthesize a
# build manifest to make an older public release look like a new native build.
_dk_published_release_context() (
    set -o pipefail
    umask 077
    _dk_clear_git_context || return $?
    local plan="$1" work="$2" tool tag root contract repo revision key_path token release release_id after id name context binary_names inventory_hash
    tool=$(jq -r '.tool' <<< "$plan") || return 4
    tag=$(jq -r '.version' <<< "$plan") || return 4
    root=$(jq -r '.context' <<< "$plan") || return 4
    declare -F _dsr_require >/dev/null || { _dk_log_error 'Published release preparation requires the DSR CLI'; return 4; }
    _dsr_require config && _dsr_require signing && _dsr_require github || return 3
    config_validate_release_contract "$tool" || return 4
    contract=$(config_get_release_contract_json "$tool") || return 4
    binary_names=$(config_get_tool_field "$tool" 'container_binaries | @json' '[]') || return 4
    jq -e 'type=="array" and length>0 and length<=64 and (unique|length)==length and
        all(.[];type=="string" and test("\\A[A-Za-z0-9][A-Za-z0-9._+-]*\\z") and (contains("..")|not))' \
        <<< "$binary_names" >/dev/null || { _dk_log_error 'Declare the exact container_binaries in the tool profile'; return 4; }
    contract=$(jq -c --argjson binaries "$binary_names" '. + {container_binaries:$binaries}' <<< "$contract") || return 4
    printf '%s\n' "$contract" > "$work/release-contract.json" || return 7
    repo=$(config_get_tool_field "$tool" repo '') || return 4
    [[ "$repo" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || return 4
    key_path=$(jq -er '.minisign_public_key_file' <<< "$contract") || return 4
    [[ "$key_path" =~ ^[A-Za-z0-9][A-Za-z0-9_./+-]*$ && "$key_path" != *..* ]] || return 4
    revision=$(git -C "$root" rev-parse --verify "refs/tags/$tag^{commit}") || return 7
    _release_contract_verify_remote_tag_identity "$repo" "$tag" "$revision" || return 7
    context="$work/release-context"
    (umask 077; mkdir "$context" "$work/release-assets") || return 7
    git -C "$root" show "HEAD:$key_path" > "$work/release-key.pub" || return 7
    token=$(signing_public_key_token "$work/release-key.pub") || return 7
    release=$(gh_api "repos/$repo/releases/tags/$tag" --no-cache) || return 8
    release_id=$(jq -er '.id | select(type=="number" and .>0 and .==floor)' <<< "$release") || return 7
    release=$(_release_contract_observe_remote_inventory "$repo" "$release_id") || return 8
    printf '%s\n' "$release" > "$work/release.json" || return 7
    # Validate before any names become paths, IDs become transport arguments,
    # or a partial asset list can become the signed-inventory denominator.
    python3 -I - "$work/release.json" "$tag" "$work/release-contract.json" <<'PY' > "$work/release-assets.tsv" || return 7
import json,re,sys
def unique(pairs):
    result={}
    for k,v in pairs:
        if k in result:raise ValueError('duplicate release JSON key')
        result[k]=v
    return result
r=json.load(open(sys.argv[1]),object_pairs_hook=unique)
assert r.get('tag_name')==sys.argv[2] and r.get('draft') is False and type(r.get('id')) is int and r['id']>0
a=r.get('assets');assert isinstance(a,list) and 0<len(a)<100
assert len({x['name'].lower() for x in a})==len(a) and len({x['id'] for x in a})==len(a)
assert sum(x['size'] for x in a)<=536870912
c=json.load(open(sys.argv[3]));assert c.get('build_manifest_assets'),'a source-bound build manifest is required'
required=set(c['exact_primary_assets'].values())|set(c.get('exact_additional_assets',[]))|set(c['build_manifest_assets'])
missing=required-{x['name'] for x in a}
assert not missing,'public release misses required assets: '+', '.join(sorted(missing))
for x in a:
    assert re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._+-]{0,254}',x['name']) and '..' not in x['name']
    assert type(x['id']) is int and x['id']>0 and x.get('state')=='uploaded'
    assert type(x['size']) is int and 0<x['size']<=268435456
    print(str(x['id'])+'\t'+x['name'])
PY
    while IFS=$'\t' read -r id name; do
        gh_download_release_asset "$repo" "$id" "$work/release-assets/$name" || return 8
    done < "$work/release-assets.tsv"
    signing_verify_exact "$work/release-assets/SHA256SUMS" "$work/release-assets/SHA256SUMS.minisig" "$token" || {
        _dk_log_error 'Release checksum signature verification failed'; return 7;
    }
    [[ "$(sed -n '3{s/\r$//;p;}' "$work/release-assets/SHA256SUMS.minisig")" == \
        "trusted comment: $tool $tag SHA256SUMS" ]] || { _dk_log_error 'Release signature belongs to another tool or tag'; return 7; }
    printf '%s\n' "$contract" > "$work/release-contract.json" || return 7
    # Build with the authenticated release revision's recipe, even if the
    # operator's checkout has advanced since that release was published.
    git -C "$root" show "$revision:Dockerfile.release" > "$context/Dockerfile.release" || return 7
    python3 -I - "$work" "$revision" "$tool" "$tag" <<'PY' || return 7
import hashlib,json,os,re,shutil,stat,sys,tarfile
from pathlib import Path
def unique(pairs):
    result={}
    for key,value in pairs:
        assert key not in result,'duplicate signed manifest key'
        result[key]=value
    return result
w=Path(sys.argv[1]);assets=w/'release-assets';context=w/'release-context'
r=json.loads((w/'release.json').read_text());contract=json.loads((w/'release-contract.json').read_text())
entries={}
for line in (assets/'SHA256SUMS').read_text().splitlines():
    match=re.fullmatch(r'([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._+-]*)',line)
    assert match and match[2] not in entries,'ambiguous checksum inventory'
    entries[match[2]]=match[1]
names={x['name']:x for x in r['assets']}
build_manifests=contract.get('build_manifest_assets',[])
assert build_manifests,'published containers require a signed source-bound build manifest'
required=set(contract['exact_primary_assets'].values())|set(contract.get('exact_additional_assets',[]))|set(build_manifests)
required-={'SHA256SUMS','SHA256SUMS.minisig'}
assert required<=entries.keys(),'signed inventory misses required payloads'
payloads={n for n in names if n not in ('SHA256SUMS','SHA256SUMS.minisig') and not n.endswith(('.sha256','.minisig'))}
assert entries.keys()==payloads,'signed inventory must cover every published payload'
for name,metadata in names.items():
    p=assets/name;s=p.lstat()
    assert stat.S_ISREG(s.st_mode) and s.st_size==metadata['size'],'download size/type mismatch'
for name,digest in entries.items():
    with (assets/name).open('rb') as f:assert hashlib.file_digest(f,'sha256').hexdigest()==digest,'payload digest mismatch'
    sidecar=assets/(name+'.sha256')
    if sidecar.exists():assert sidecar.read_bytes()==f'{digest}  {name}\n'.encode(),'sidecar mismatch'
for name in build_manifests:
    m=json.loads((assets/name).read_text(),object_pairs_hook=unique)
    assert (m.get('tool')==sys.argv[3] and m.get('version')==sys.argv[4] and
            m.get('source',{}).get('git_sha')==sys.argv[2] and m.get('status')=='success' and
            m.get('publishable') is True and m.get('build_purpose')=='release' and
            type(m.get('summary',{}).get('failed')) is int and
            m['summary']['failed']==0),'build manifest does not bind this release source'
    artifacts=m.get('artifacts');assert isinstance(artifacts,list) and artifacts,'build manifest lacks artifacts'
    by_name={x['name']:x for x in artifacts}
    assert len(by_name)==len(artifacts) and set(contract['exact_primary_assets'].values())<=by_name.keys(),'incomplete build inventory'
    for payload,record in by_name.items():
        assert (payload in names and type(record['size_bytes']) is int and
                record['size_bytes']==names[payload]['size']),'build inventory size/name mismatch'
        with (assets/payload).open('rb') as f:assert hashlib.file_digest(f,'sha256').hexdigest()==record['sha256'],'build inventory digest mismatch'
primaries=contract['exact_primary_assets']
selected={
    'amd64':primaries.get('linux/amd64@x86_64-unknown-linux-gnu',primaries.get('linux/amd64')),
    'arm64':primaries.get('linux/arm64@aarch64-unknown-linux-gnu',primaries.get('linux/arm64'))}
assert all(selected.values()) and len(set(selected.values()))==2,'both GNU archives are required'
for arch,name in selected.items():
    assert name in entries and name.endswith(('.tar.xz','.tar.gz')),'missing GNU archive'
    dest=context/'dist'/arch;dest.mkdir(parents=True,mode=0o700)
    with tarfile.open(assets/name,'r:*') as archive:
        seen=set();total=0
        for index,member in enumerate(archive):
            assert index<256,'too many archive entries'
            path=Path(member.name)
            assert not path.is_absolute() and '..' not in path.parts,'unsafe archive path'
            if member.isdir():continue
            assert member.isfile() and not member.issparse(),'links/special archive members are forbidden'
            assert member.name not in seen and 0<=member.size<=268435456,'duplicate or oversized archive member'
            seen.add(member.name);total+=member.size;assert len(seen)<=256 and total<=536870912,'oversized archive'
            if path.name not in contract['container_binaries']:continue
            target=dest/path.name;assert not target.exists(),'duplicate binary basename'
            with archive.extractfile(member) as source,target.open('xb') as output:shutil.copyfileobj(source,output)
            target.chmod(0o755)
    assert {p.name for p in dest.iterdir()}==set(contract['container_binaries']),'archive lacks required binaries'
PY
    _release_contract_verify_remote_tag_identity "$repo" "$tag" "$revision" || return 7
    after=$(_release_contract_observe_remote_inventory "$repo" "$release_id") || return 8
    [[ "$after" == "$release" ]] || { _dk_log_error 'Public release changed during artifact preparation'; return 7; }
    inventory_hash=$(_dk_hash "$work/release.json") || return 7
    jq -c --arg context "$context" --arg revision "$revision" --arg release_repo "$repo" \
        --arg inventory_hash "$inventory_hash" \
        --argjson release_id "$(jq -r '.id' <<< "$release")" '
        . + {context:$context,dockerfile:($context+"/Dockerfile.release"),
             release_source_revision:$revision,release_repository:$release_repo,release_id:$release_id,
             release_inventory_sha256:$inventory_hash,
             build_args:[("AM_VERSION="+(.version|ltrimstr("v"))),("AM_REVISION="+$revision)]}' <<< "$plan"
)

# Published-release contexts contain only authenticated assets and our frozen
# recipe/driver. RCH owns remote admission and result collection. Its job API
# cannot use Cargo's source-content-receipt mode, so verify every staged input
# on the worker before Docker and bind the returned result to that manifest.
_dk_build_remote_release() (
    set -o pipefail
    local plan="$1" root="$2" work="$3" result output envelope publication input_manifest_hash status=0
    _dk_clear_git_context || return $?
    _dk_dependency rch || return 3
    mkdir "$work/remote-job" || return 7
    cp -a -- "$root" "$work/remote-job/context" || return 7
    root="$work/remote-job"
    cp -- "${BASH_SOURCE[0]}" "$root/.dsr-container-module.sh" || return 7
    printf '%s\n' "$plan" > "$root/.dsr-container-plan.json" || return 7
    cat > "$root/.dsr-container-run.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
sha256sum --strict --check .dsr-container-inputs.sha256 >&2
input_manifest_hash=$(sha256sum .dsr-container-inputs.sha256)
input_manifest_hash="${input_manifest_hash%% *}"
source ./.dsr-container-module.sh
mkdir .dsr-container-result
plan=$(jq --arg root "$PWD" '
    .context=($root+"/context") | .dockerfile=($root+"/context/Dockerfile.release") |
    .output_file=(if .exporter=="oci" then $root+"/.dsr-container-result/image.tar" else null end) |
    .retain_work=true' .dsr-container-plan.json)
_dk_build_execute_local "$plan" | jq --arg inputs "$input_manifest_hash" \
    '. + {input_manifest_sha256:$inputs}' > .dsr-container-result/build.json
SH
    python3 -I - "$root" <<'PY' > "$root/.dsr-container-inputs.sha256" || return 7
import hashlib,stat,sys
from pathlib import Path
root=Path(sys.argv[1])
paths=[root/name for name in ['.dsr-container-module.sh','.dsr-container-plan.json','.dsr-container-run.sh']]
paths+=sorted((root/'context').rglob('*'))
for path in paths:
    mode=path.lstat().st_mode
    if stat.S_ISDIR(mode):continue
    assert stat.S_ISREG(mode),'only regular private inputs are allowed'
    relative=str(path.relative_to(root));assert '\n' not in relative and '\\' not in relative
    with path.open('rb') as source:digest=hashlib.file_digest(source,'sha256').hexdigest()
    print(digest+'  '+relative)
PY
    input_manifest_hash=$(_dk_hash "$root/.dsr-container-inputs.sha256") || return 7
    # RCH excludes generated dist/ trees, but preserves tracked input files.
    # Index only this private authenticated bundle; keep the normal credential
    # exclusions and every operator/source repository untouched. No commit or
    # source publication is manufactured by this transport-only index.
    git -C "$root" init --template= -q -b main || return 7
    GIT_ATTR_NOSYSTEM=1 git -C "$root" -c core.hooksPath=/dev/null -c core.attributesFile=/dev/null \
        -c core.autocrlf=false -c core.fsmonitor=false add -f -- context \
        .dsr-container-module.sh .dsr-container-plan.json .dsr-container-run.sh .dsr-container-inputs.sha256 || return 7
    (cd "$root" && RCH_REQUIRE_REMOTE=1 RCH_NO_SELF_HEALING=1 RCH_CANONICAL_PROJECT_ROOT="$root" \
        rch --json exec --job --require-remote --require-tool docker \
          --result-dir .dsr-container-result -- bash .dsr-container-run.sh \
          > "$work/rch.jsonl" 2> "$work/rch.stderr") || status=$?
    cat "$work/rch.stderr" >&2 || return 7
    (( status == 0 )) || { _dk_log_error "Remote container build did not complete (exit $status)"; return "$status"; }
    envelope=$(jq -cse '
        [.[] | select(.api_version == "1.0" and has("location"))] |
        if length==1 then .[0] else error("ambiguous RCH completion") end |
        select(.location=="remote" and .outcome=="completed" and .remote_exit_code==0 and
               (.worker_id | type=="string" and length>0) and
               .admission.strict_remote==true and .admission.terminal_acknowledged==true and
               .admission.worker_id==.worker_id and
               (.result_dirs | length==1 and .[0].path==".dsr-container-result" and .[0].status=="ok" and .[0].files>=2))
        ' "$work/rch.jsonl") || { _dk_log_error 'RCH did not prove remote completion and complete result collection'; return 7; }
    [[ -f "$root/.dsr-container-result/build.json" && ! -L "$root/.dsr-container-result/build.json" ]] || return 7
    result=$(jq -ce -s --argjson plan "$plan" --arg inputs "$input_manifest_hash" '
        if length==1 then .[0] else error("ambiguous build result") end |
        select(.status=="built" and .repository==$plan.repository and .tags==$plan.tags and
               .platforms==$plan.platforms and .exporter==$plan.exporter and .input_manifest_sha256==$inputs and
               .tool==$plan.tool and .version==$plan.version and .build_args==$plan.build_args and
               .release_source_revision==$plan.release_source_revision and
               .release_repository==$plan.release_repository and .release_id==$plan.release_id and
               .release_inventory_sha256==$plan.release_inventory_sha256 and
               (.digest | test("^sha256:[0-9a-f]{64}$")) and .reference==(.repository+"@"+.digest))
        ' "$root/.dsr-container-result/build.json") || return 7
    output=$(jq -r '.output_file // ""' <<< "$plan") || return 7
    if [[ $(jq -r '.exporter' <<< "$plan") == oci ]]; then
        [[ "$(_dk_hash "$root/.dsr-container-result/image.tar")" == "$(jq -r '.archive.sha256' <<< "$result")" &&
           "$(wc -c < "$root/.dsr-container-result/image.tar" | tr -d '[:space:]')" == "$(jq -r '.archive.size' <<< "$result")" ]] || return 7
        mkdir -p -- "$(dirname "$output")" || return 7
        [[ ! -e "$output" && ! -L "$output" ]] || return 7
        publication=$(mktemp -d "$(dirname "$output")/.dsr-remote-oci.XXXXXXXX") || return 7
        cp -- "$root/.dsr-container-result/image.tar" "$publication/image.tar" || return 7
        [[ "$(_dk_hash "$publication/image.tar")" == "$(jq -r '.archive.sha256' <<< "$result")" ]] || return 7
        ln -- "$publication/image.tar" "$output" || return 7
    fi
    jq -c --argjson plan "$plan" --argjson remote "$envelope" '
        . + {context:$plan.context,dockerfile:$plan.dockerfile,output_file:$plan.output_file,
             remote_execution:$remote}' <<< "$result"
)

_dk_build_execute() (
    local plan="$1" work root
    if [[ $(jq -r '.dry_run' <<< "$plan") == true ]]; then printf '%s\n' "$plan"; return 0; fi
    if [[ $(jq -r '.published_release // false' <<< "$plan") == true ]]; then
        root=$(jq -r '.context' <<< "$plan") || return 7
        [[ "$(jq -r '.output_file // ""' <<< "$plan")" != "$root/"* ]] || return 4
        work=$(mktemp -d "${TMPDIR:-/tmp}/dsr-published-container.XXXXXXXX") || return 7
        _dk_log_info "Retaining authenticated release context and remote build output: $work"
        plan=$(_dk_published_release_context "$plan" "$work") || return $?
        root=$(jq -r '.context' <<< "$plan") || return 7
        _dk_build_remote_release "$plan" "$root" "$work"
    else
        # The source-build backend has no strict remote adapter. Never let a
        # direct Docker invocation silently defeat a caller's RCH requirement.
        local remote_policy="${RCH_REQUIRE_REMOTE:-}"
        remote_policy="${remote_policy#"${remote_policy%%[![:space:]]*}"}"
        remote_policy="${remote_policy%"${remote_policy##*[![:space:]]}"}"
        case "${remote_policy,,}" in
            ''|0|false|no|off|disabled) ;;
            *) _dk_log_error 'Strict remote source-container builds are unavailable; no Docker build dispatched'; return 4 ;;
        esac
        _dk_build_execute_local "$plan"
    fi
)

_dk_build_execute_local() (
    set -o pipefail
    local plan="$1" work='' output_work='' root dockerfile builder mode output platforms digest start=$SECONDS retain=false
    root=$(jq -r '.context' <<< "$plan") || return 1
    dockerfile=$(jq -r '.dockerfile' <<< "$plan") || return 1
    builder=$(jq -r '.builder' <<< "$plan") || return 1
    mode=$(jq -r '.exporter' <<< "$plan") || return 1
    output=$(jq -r '.output_file // ""' <<< "$plan") || return 1
    platforms=$(jq -r '.platforms | join(",")' <<< "$plan") || return 1
    if [[ $(jq -r '.dry_run' <<< "$plan") == true ]]; then printf '%s\n' "$plan"; return 0; fi
    work=$(mktemp -d "${TMPDIR:-/tmp}/dsr-container.XXXXXXXX") || return 1
    [[ $(jq -r '.retain_work // false' <<< "$plan") != true ]] || retain=true
    if ! $retain; then
        trap '[[ -z "$output_work" ]] || rm -rf -- "$output_work"; rm -rf -- "$work"' EXIT
    fi
    trap 'exit 5' HUP INT TERM
    if [[ "$mode" == oci ]]; then
        mkdir -p -- "$(dirname "$output")" || return 1
        output="$(cd "$(dirname "$output")" && pwd -P)/$(basename "$output")"
        [[ "$output" != "$root/"* && ! -e "$output" && ! -L "$output" ]] || {
            _dk_log_error 'OCI output overlaps build context or exists'; return 4;
        }
        output_work=$(mktemp -d "$(dirname "$output")/.dsr-oci.XXXXXXXX") || return 1
    fi
    docker_setup_buildx "$builder" || return $?
    local tag tag_lines repository
    local -a args=(--builder "$builder" --file "$dockerfile" --metadata-file "$work/metadata.json" --progress plain)
    local build_arg
    local build_args
    build_args=$(jq -r '.build_args[]?' <<< "$plan") || return 7
    while IFS= read -r build_arg; do [[ -z "$build_arg" ]] || args+=(--build-arg "$build_arg"); done <<< "$build_args"
    [[ -z "$platforms" ]] || args+=(--platform "$platforms")
    tag_lines=$(jq -r '.tags[]' <<< "$plan") || return 1
    while IFS= read -r tag; do args+=(--tag "$tag"); done <<< "$tag_lines"
    case "$mode" in
        registry)
            repository=$(jq -r '.repository' <<< "$plan") || return 1
            if [[ "$repository" == ghcr.io/* && -n "${DSR_GH_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-}}}" ]]; then
                docker_login_ghcr || return $?
            fi
            args+=(--push --provenance=true --sbom=true) ;;
        docker) args+=(--load --provenance=false --sbom=false) ;;
        oci) args+=(--output "type=oci,dest=$output_work/image.tar" --provenance=true --sbom=true) ;;
        *) return 4 ;;
    esac
    # The repository, NOT dirname(Dockerfile), is the build context.
    docker buildx build "${args[@]}" "$root" >&2 || { _dk_log_error 'Container build/export failed'; return 1; }
    [[ -f "$work/metadata.json" && ! -L "$work/metadata.json" ]] || return 1
    digest=$(jq -er -s '
        if length == 1 and (.[0] | type == "object") then .[0] else error("metadata") end |
        .["containerimage.digest"] as $digest |
        if ($digest | type == "string" and test("^sha256:[0-9a-f]{64}$")) and
           (if has("containerimage.descriptor") then .["containerimage.descriptor"].digest == $digest else true end)
        then $digest else error("missing or conflicting image digest") end' "$work/metadata.json") || {
        _dk_log_error 'Build succeeded without a valid image digest receipt'; return 1;
    }
    local archive_hash='' archive_size=0
    if [[ "$mode" == oci ]]; then
        [[ -s "$output_work/image.tar" && ! -L "$output_work/image.tar" ]] || return 1
        archive_hash=$(_dk_hash "$output_work/image.tar") || return $?
        archive_size=$(wc -c < "$output_work/image.tar") || return 1
        [[ ! -d "$output" && ! -e "$output" && ! -L "$output" ]] || return 2
        ln -- "$output_work/image.tar" "$output" || return 2
        [[ -f "$output" && ! -L "$output" && "$(_dk_hash "$output")" == "$archive_hash" ]] || return 2
    fi
    jq -c --arg digest "$digest" --arg output "$output" --arg archive_sha256 "$archive_hash" \
        --argjson archive_size "$archive_size" --argjson duration "$((SECONDS-start))" '
        . + {status:"built",digest:$digest,reference:(.repository + "@" + $digest),duration_seconds:$duration,
             output_file:(if $output == "" then null else $output end),
             archive:(if $archive_sha256 == "" then null else {sha256:$archive_sha256,size:$archive_size} end)}' <<< "$plan"
)

docker_build() {
    case "${1:-}" in --help|-h)
        printf '%s\n' 'docker_build - Build multi-arch Docker image' \
            'Usage: docker_build TOOL VERSION [--repo-path DIR] [--dockerfile FILE]' \
            '  --published-release (authenticate complete public release assets and use Dockerfile.release)' \
            '  --push | --local | --output OCI_TAR (default: XDG state OCI archive)' \
            '  --platform linux/amd64,linux/arm64 --tag TAG --dry-run' \
            'No implicit latest tag. --local without --platform uses the builder default.' >&2
        return 0 ;;
    esac
    local plan
    plan=$(_dk_build_plan "$@") || return $?
    _dk_build_execute "$plan"
}

# These operations accept immutable qualified references only. A mutable tag
# must not be resolved independently by the scanner and signer.
docker_sign() {
    local image='' dry="${DRY_RUN:-false}" status=signed
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run|-n) dry=true; shift ;;
            --help|-h)
                printf '%s\n' 'docker_sign - Sign container image by immutable repository@sha256:digest' \
                    'Usage: docker_sign REPOSITORY@sha256:DIGEST [--dry-run]' >&2
                return 0 ;;
            -*) _dk_log_error "Unknown sign option: $1"; return 4 ;;
            *)
                [[ -z "$image" ]] || { _dk_log_error "Unexpected sign argument: $1"; return 4; }
                image="$1"; shift ;;
        esac
    done
    [[ -n "$image" ]] || { _dk_log_error 'Image reference required'; return 4; }
    _dk_pinned_valid "$image" || { _dk_log_error 'Use an immutable repository@sha256:digest'; return 4; }
    [[ "$dry" =~ ^(true|false)$ ]] || return 4
    _dk_dependency jq || return $?
    if [[ "$dry" == true ]]; then status=planned
    else
        docker_check_cosign || return $?
        cosign sign --yes "$image" >&2 || { _dk_log_error "Signing failed: $image"; return 1; }
    fi
    # Signing is an acknowledged write, not independent signature verification.
    # Release performs that verification separately against its trusted policy.
    jq -nc --arg image "$image" --arg status "$status" --argjson dry "$dry" '
        {schema_version:1,kind:"dsr-container-signature",status:$status,reference:$image,
         dry_run:$dry,signed:($status == "signed"),verified:false}'
}
_dk_spdx_valid() {
    [[ -f "$1" && ! -L "$1" ]] || return 1
    jq -e -s 'length == 1 and (.[0] | type == "object" and
        (.spdxVersion == "SPDX-2.2" or .spdxVersion == "SPDX-2.3") and
        .SPDXID == "SPDXRef-DOCUMENT" and .dataLicense == "CC0-1.0" and
        (.name | type == "string" and length > 0) and
        (.documentNamespace | type == "string" and length > 0) and
        (.creationInfo | type == "object") and
        (if has("packages") then .packages | type == "array" else true end))' "$1" >/dev/null 2>&1
}

# Buildx --raw preserves exact registry manifest bytes (no added newline).
# Hash BEFORE parsing, so a dishonest/mistaken digest field cannot satisfy a pin.
_dk_fetch_manifest() {
    local image="$1" file="$2"
    _dk_pinned_valid "$image" || return 4
    docker buildx imagetools inspect "$image" --raw > "$file" || return 8
    [[ "$(_dk_hash "$file")" == "${image##*@sha256:}" ]] || {
        _dk_log_error "Registry manifest digest mismatch: $image"; return 7;
    }
    jq -e -s 'length == 1 and (.[0] | type == "object" and .schemaVersion == 2)' "$file" >/dev/null || return 7
}

# Normalize the default arm64 variant without conflating arm/v6 and arm/v7.
# Only image manifests are executable platforms. BuildKit attestation entries
# must identify themselves AND reference a real executable manifest in the set.
_dk_registry_inventory() (
    local image="$1" expected="$2" work="$3" media rows row digest platform config actual size raw
    _dk_fetch_manifest "$image" "$work/root.json" || return $?
    media=$(jq -r '.mediaType' "$work/root.json") || return 7
    case "$media" in
        application/vnd.oci.image.index.v1+json|application/vnd.docker.distribution.manifest.list.v2+json)
            rows=$(jq -ec '
                def digest: type == "string" and test("^sha256:[0-9a-f]{64}$");
                def size: type == "number" and . > 0 and . == floor;
                def image: .mediaType == "application/vnd.oci.image.manifest.v1+json" or
                    .mediaType == "application/vnd.docker.distribution.manifest.v2+json";
                def evidence: .annotations["vnd.docker.reference.type"] == "attestation-manifest";
                def platform: .os + "/" + .architecture +
                    (if (.variant // "") == "" or (.architecture == "arm64" and .variant == "v8")
                     then "" else "/" + .variant end);
                .manifests as $all |
                if ($all | type != "array" or length == 0) then error("empty index") else . end |
                if all($all[]; image and (.digest | digest) and (.size | size) and
                    (if evidence then .platform.os == "unknown" and .platform.architecture == "unknown" and
                        (.annotations["vnd.docker.reference.digest"] | digest)
                     else .platform.os == "linux" and
                        (.platform.architecture | type == "string" and test("^[a-z0-9_]+$")) and
                        (.platform.variant // "" | type == "string" and test("^[a-z0-9_.-]*$")) end))
                then . else error("unsupported descriptor") end |
                [$all[] | select(evidence | not)] as $images |
                if ($images | length) == 0 or
                    any($all[] | select(evidence); .annotations["vnd.docker.reference.digest"] as $d |
                        [$images[].digest] | index($d) == null)
                then error("unbound index evidence") else . end |
                [$images[] | {digest,size,platform:(.platform | platform)}] |
                if (map(.platform) | unique | length) != length or
                   (map(.digest) | unique | length) != length
                then error("duplicate platform or image") else sort_by(.platform) end
            ' "$work/root.json") || return 7 ;;
        application/vnd.oci.image.manifest.v1+json|application/vnd.docker.distribution.manifest.v2+json)
            rows=$(jq -nc --arg digest "${image##*@}" --argjson size "$(wc -c < "$work/root.json")" \
                '[{digest:$digest,size:$size,platform:null}]') || return 7 ;;
        *) _dk_log_error 'Unsupported registry manifest type'; return 7 ;;
    esac
    : > "$work/inventory.jsonl" || return 1
    local lines reference
    lines=$(jq -c '.[]' <<< "$rows") || return 7
    while IFS= read -r row; do
        digest=$(jq -r '.digest' <<< "$row") || return 7
        platform=$(jq -r '.platform // ""' <<< "$row") || return 7
        size=$(jq -r '.size' <<< "$row") || return 7
        reference="${image%@*}@$digest"
        raw="$work/${digest#sha256:}.json"
        _dk_fetch_manifest "$reference" "$raw" || return $?
        [[ "$(wc -c < "$raw")" -eq "$size" ]] || return 7
        jq -e '
            def d: type == "string" and test("^sha256:[0-9a-f]{64}$");
            (.mediaType == "application/vnd.oci.image.manifest.v1+json" or
             .mediaType == "application/vnd.docker.distribution.manifest.v2+json") and
            (.config.digest | d) and (.config.size | type == "number" and . > 0 and . == floor) and
            (.layers | type == "array" and all(.[]; (.digest | d) and
                (.size | type == "number" and . >= 0 and . == floor)))
        ' "$raw" >/dev/null || return 7
        # .Image is loaded by Docker's content-addressed resolver. It is parsed
        # configuration, not original config bytes; Docker is a trusted adapter.
        docker buildx imagetools inspect "$reference" --format '{{json .Image}}' > "$work/config.json" || return 8
        config=$(jq -ec -s 'if length == 1 then .[0] else error("config stream") end |
            if type == "object" and .os == "linux" and
               (.architecture | type == "string" and test("^[a-z0-9_]+$")) and
               (.variant // "" | type == "string" and test("^[a-z0-9_.-]*$"))
            then .os + "/" + .architecture +
                (if (.variant // "") == "" or (.architecture == "arm64" and .variant == "v8")
                 then "" else "/" + .variant end)
            else error("invalid platform config") end' "$work/config.json") || return 7
        actual=$(jq -r . <<< "$config") || return 7
        [[ -z "$platform" || "$platform" == "$actual" ]] || {
            _dk_log_error "Index/config platform mismatch: $reference"; return 7;
        }
        jq -nc --arg reference "$reference" --arg digest "$digest" --arg platform "$actual" \
            '{reference:$reference,digest:$digest,platform:$platform}' >> "$work/inventory.jsonl" || return 1
    done <<< "$lines"
    rows=$(jq -sc 'sort_by(.platform)' "$work/inventory.jsonl") || return 7
    jq -e --argjson expected "$expected" '
        def normalize: if . == "linux/arm64/v8" then "linux/arm64" else . end;
        ($expected | length) == 0 or (map(.platform) | sort) == ($expected | map(normalize) | sort)
    ' <<< "$rows" >/dev/null || { _dk_log_error 'Registry platform set differs from requested build'; return 7; }
    printf '%s\n' "$rows"
)

_dk_verify_policy() {
    [[ -n "$1" && "$1" != *[[:cntrl:]]* && "$2" == https://* && "$2" != *[[:space:]]* ]] || {
        _dk_log_error 'Set an exact --certificate-identity and --certificate-oidc-issuer (or DOCKER_CERTIFICATE_IDENTITY / DOCKER_CERTIFICATE_OIDC_ISSUER)'; return 4;
    }
}
_dk_verify_signature() {
    local image="$1" identity="$2" issuer="$3" file="$4"
    cosign verify --certificate-identity "$identity" --certificate-oidc-issuer "$issuer" \
        --output json "$image" > "$file" || return 7
    jq -e -s --arg digest "${image##*@}" 'length == 1 and (.[0] | type == "array" and length > 0 and
        all(.[]; .critical.image["docker-manifest-digest"] == $digest))' "$file" >/dev/null || return 7
}

# Inspect only Cosign-VERIFIED DSSE payloads, never a download of unauthenticated
# attestations. Require a named subject and SPDX predicate; on publication also
# require that the authenticated predicate equals the document we just scanned.
_dk_verify_attestation() {
    local image="$1" identity="$2" issuer="$3" work="$4" expected="${5:-}" payload hash
    cosign verify-attestation --certificate-identity "$identity" --certificate-oidc-issuer "$issuer" \
        --type spdxjson --output json "$image" > "$work/attestations.jsonl" || return 7
    jq -ec -s --arg digest "${image##*@sha256:}" --arg repository "${image%@*}" '
        [.[] | if type == "array" then .[] else . end] |
        if length > 0 and all(.[]; type == "object" and .payloadType == "application/vnd.in-toto+json" and
            (.payload | type == "string" and length > 0)) then . else error("missing DSSE") end |
        map(.payload | @base64d | fromjson) |
        .[] | select((._type == "https://in-toto.io/Statement/v0.1" or ._type == "https://in-toto.io/Statement/v1") and
            .predicateType == "https://spdx.dev/Document" and
            (.subject | type == "array" and length > 0 and
                any(.[]; .name == $repository and .digest.sha256 == $digest))) | .predicate
    ' "$work/attestations.jsonl" > "$work/predicates.jsonl" || return 7
    [[ -s "$work/predicates.jsonl" ]] || return 7
    while IFS= read -r payload; do
        printf '%s\n' "$payload" > "$work/predicate.json" || return 1
        _dk_spdx_valid "$work/predicate.json" || continue
        if [[ -n "$expected" ]]; then
            jq -e --slurpfile expected "$expected" '. == $expected[0]' "$work/predicate.json" >/dev/null || continue
        fi
        jq -cS . "$work/predicate.json" > "$work/canonical.json" || return 1
        hash=$(_dk_hash "$work/canonical.json") || return $?
        printf '%s\n' "$hash"
        return 0
    done < "$work/predicates.jsonl"
    _dk_log_error "No matching verified SPDX attestation: $image"
    return 7
}

_dk_prepare_sboms() {
    local inventory="$1" work="$2" row reference platform file count=0 lines hash
    lines=$(jq -c '.[]' <<< "$inventory") || return 1
    : > "$work/scans.jsonl" || return 1
    while IFS= read -r row; do
        reference=$(jq -r '.reference' <<< "$row") || return 1
        platform=$(jq -r '.platform' <<< "$row") || return 1
        file="$work/sbom-$count.json"
        syft "registry:$reference" --platform "$platform" -o spdx-json > "$file" || return 1
        _dk_spdx_valid "$file" || { _dk_log_error "Invalid SPDX for $platform"; return 1; }
        hash=$(_dk_hash "$file") || return $?
        jq -c --arg file "$file" --arg hash "$hash" '. + {file:$file,sbom_sha256:$hash}' <<< "$row" \
            >> "$work/scans.jsonl" || return 1
        count=$((count+1))
    done <<< "$lines"
    jq -sc . "$work/scans.jsonl"
}
_dk_publish_sboms() {
    local scans="$1" identity="$2" issuer="$3" work="$4" lines row reference file hash predicate
    lines=$(jq -c '.[]' <<< "$scans") || return 1
    : > "$work/verified.jsonl" || return 1
    while IFS= read -r row; do
        reference=$(jq -r '.reference' <<< "$row") || return 1
        file=$(jq -r '.file' <<< "$row") || return 1
        hash=$(jq -r '.sbom_sha256' <<< "$row") || return 1
        [[ "$(_dk_hash "$file")" == "$hash" ]] || return 7
        cosign attest --yes --predicate "$file" --type spdxjson "$reference" >&2 || return 1
        [[ "$(_dk_hash "$file")" == "$hash" ]] || return 7
        predicate=$(_dk_verify_attestation "$reference" "$identity" "$issuer" "$work" "$file") || return $?
        [[ "$(_dk_hash "$file")" == "$hash" ]] || return 7
        jq -c --arg predicate "$predicate" 'del(.file) + {status:"verified",predicate_sha256:$predicate}' <<< "$row" \
            >> "$work/verified.jsonl" || return 1
    done <<< "$lines"
    jq -sc . "$work/verified.jsonl"
}

# Verify or attest an EXISTING immutable image without a source checkout/build.
# Verification needs no scanner, login, builder setup, upload, or tag mutation.
_dk_evidence_command() (
    local action="$1" image="${2:-}" expected='[]' skip=false dry="${DRY_RUN:-false}" work inventory after rows='[]'
    local identity="${DOCKER_CERTIFICATE_IDENTITY:-}" issuer="${DOCKER_CERTIFICATE_OIDC_ISSUER:-}" lines row ref hash scans
    local expected_scans='' expected_file='' expected_hash=''
    shift
    [[ $# -eq 0 ]] || shift
    case "$image" in --help|-h)
        printf '%s\n' "docker_$action - Check digest-pinned container evidence" \
            "Usage: docker_$action REPOSITORY@sha256:DIGEST [--platform PLATFORMS]" \
            '  --certificate-identity ID --certificate-oidc-issuer HTTPS_ISSUER' \
            '  --skip-sign --dry-run' >&2
        return 0 ;;
    esac
    # Internal release verification additionally binds the exact freshly scanned
    # predicates. The public read-only verifier accepts any valid matching SPDX
    # from the configured signer, so older attestations may coexist on an image.
    if [[ "$action" == verify-scans ]]; then
        [[ $# -gt 0 ]] || return 4
        expected_scans="$1"; shift
    fi
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --certificate-identity|--certificate-oidc-issuer|--platform|-p)
                [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || { _dk_log_error "Missing value for $1"; return 4; }
                case "$1" in
                    --certificate-identity) identity="$2" ;;
                    --certificate-oidc-issuer) issuer="$2" ;;
                    *) expected=$(_dk_platforms "$2") || return 4 ;;
                esac
                shift 2 ;;
            --skip-sign) skip=true; shift ;;
            --dry-run|-n) dry=true; shift ;;
            *) _dk_log_error "Unexpected $action argument: $1"; return 4 ;;
        esac
    done
    _dk_pinned_valid "$image" || { _dk_log_error 'Use an immutable repository@sha256:digest'; return 4; }
    [[ "$dry" =~ ^(true|false)$ ]] || return 4
    _dk_dependency jq || return $?
    if [[ "$dry" == true ]]; then
        jq -nc --arg image "$image" --arg action "$action" --argjson expected "$expected" \
            --arg identity "$identity" --arg issuer "$issuer" --argjson skip "$skip" '
            {schema_version:1,kind:"dsr-container-evidence",status:"planned",dry_run:true,
             reference:$image,operation:$action,platforms:$expected,
             certificate_identity:$identity,certificate_oidc_issuer:$issuer,
             signature:(if $action == "attest" then "not_checked" elif $skip then "skipped" else "planned" end),
             sbom:"planned"}'
        return $?
    fi
    _dk_verify_policy "$identity" "$issuer" || return $?
    _dk_dependency docker && docker_check_cosign || return 3
    [[ "$action" != attest ]] || _dk_dependency syft || return 3
    work=$(mktemp -d "${TMPDIR:-/tmp}/dsr-container-evidence.XXXXXXXX") || return 1
    trap 'rm -rf -- "$work"' EXIT
    trap 'exit 5' HUP INT TERM
    inventory=$(_dk_registry_inventory "$image" "$expected" "$work") || return $?
    if [[ "$action" == attest ]]; then
        scans=$(_dk_prepare_sboms "$inventory" "$work") || return $?
        rows=$(_dk_publish_sboms "$scans" "$identity" "$issuer" "$work") || return $?
    else
        $skip || _dk_verify_signature "$image" "$identity" "$issuer" "$work/signature.json" || return $?
        lines=$(jq -c '.[]' <<< "$inventory") || return 1
        while IFS= read -r row; do
            ref=$(jq -r '.reference' <<< "$row") || return 1
            if [[ -n "$expected_scans" ]]; then
                scans=$(jq -ec --arg ref "$ref" '[.[] | select(.reference == $ref)] |
                    if length == 1 then .[0] else error("missing or duplicate expected scan") end' <<< "$expected_scans") || return 7
                expected_file=$(jq -r '.file' <<< "$scans") || return 7
                expected_hash=$(jq -r '.sbom_sha256' <<< "$scans") || return 7
                [[ "$(_dk_hash "$expected_file")" == "$expected_hash" ]] || return 7
            fi
            hash=$(_dk_verify_attestation "$ref" "$identity" "$issuer" "$work" "$expected_file") || return $?
            [[ -z "$expected_file" || "$(_dk_hash "$expected_file")" == "$expected_hash" ]] || return 7
            rows=$(jq -c --argjson row "$row" --arg hash "$hash" '. + [$row + {predicate_sha256:$hash,status:"verified"}]' <<< "$rows") || return 1
        done <<< "$lines"
    fi
    after=$(_dk_registry_inventory "$image" "$expected" "$work") || return $?
    [[ "$inventory" == "$after" ]] || return 7
    jq -nc --arg image "$image" --arg identity "$identity" --arg issuer "$issuer" --arg action "$action" \
        --argjson skip "$skip" --argjson rows "$rows" '
        {schema_version:1,kind:"dsr-container-evidence",status:"verified",dry_run:false,operation:$action,
         reference:$image,platforms:$rows,
         certificate_identity:$identity,certificate_oidc_issuer:$issuer,
         signature:(if $action == "attest" then "not_checked" elif $skip then "skipped" else "verified" end)}'
)
docker_attest_sbom() { _dk_evidence_command attest "$@"; }
docker_verify_release() { _dk_evidence_command verify "$@"; }

_dk_check_tags() {
    local build="$1" work="$2" tags tag digest
    tags=$(jq -r '.tags[]' <<< "$build") || return 1
    digest=$(jq -r '.digest' <<< "$build") || return 1
    while IFS= read -r tag; do
        docker buildx imagetools inspect "$tag" --raw > "$work/tag.json" || return 8
        [[ "sha256:$(_dk_hash "$work/tag.json")" == "$digest" ]] || {
            _dk_log_error "Published tag no longer refers to this build: $tag"; return 7;
        }
    done <<< "$tags"
}

# Re-observe the same complete public release, never a locally reconstructed
# inventory. Call immediately before each external publication boundary.
_dk_public_release_unchanged() {
    local build="$1" work="$2" repo tag revision release_id current
    repo=$(jq -er '.release_repository' <<< "$build") || return 7
    tag=$(jq -er '.version' <<< "$build") || return 7
    revision=$(jq -er '.release_source_revision' <<< "$build") || return 7
    release_id=$(jq -er '.release_id' <<< "$build") || return 7
    _release_contract_verify_remote_tag_identity "$repo" "$tag" "$revision" || return 7
    current=$(gh_api "repos/$repo/releases/tags/$tag" --no-cache) || return 8
    jq -e --argjson id "$release_id" '.id==$id and .draft==false' <<< "$current" >/dev/null || return 7
    current=$(_release_contract_observe_remote_inventory "$repo" "$release_id") || return 8
    printf '%s\n' "$current" > "$work/current-release.json" || return 7
    [[ "$(_dk_hash "$work/current-release.json")" == "$(jq -r '.release_inventory_sha256' <<< "$build")" ]] || {
        _dk_log_error 'Public release changed before container publication'; return 7;
    }
}

# Inspect bytes before writing a private OCI layout. Both platform configs and
# final packaged binaries must match the signed input. Copy regular files with
# caller ownership; OCI-archive readers may otherwise attempt privileged chown.
_dk_oci_inventory() {
    local archive="$1" build="$2" work="$3"
    printf '%s\n' "$build" > "$work/oci-build.json" || return 7
    python3 -I - "$archive" "$work/oci-build.json" "$work/layout" <<'PY'
import gzip,hashlib,json,re,shutil,stat,sys,tarfile
from pathlib import Path,PurePosixPath
def unique(pairs):
    result={}
    for key,value in pairs:
        assert key not in result,'duplicate OCI JSON key'
        result[key]=value
    return result
build=json.load(open(sys.argv[2]));rows=[]
index_type='application/vnd.oci.image.index.v1+json'
manifest_type='application/vnd.oci.image.manifest.v1+json'
with tarfile.open(sys.argv[1],'r:*') as archive:
    members={};total=0
    for count,member in enumerate(archive):
        assert count<4096,'too many OCI archive entries'
        path=PurePosixPath(member.name)
        assert not path.is_absolute() and '..' not in path.parts,'unsafe OCI archive path'
        name=str(path)
        if member.isdir():continue
        assert member.isfile() and not member.issparse() and name not in members,'duplicate/link/special OCI entry'
        assert 0<=member.size<=8589934592,'oversized OCI blob'
        total+=member.size;assert total<=17179869184,'oversized OCI archive'
        assert name in ['oci-layout','index.json'] or re.fullmatch(r'blobs/sha256/[0-9a-f]{64}',name),'unsupported OCI entry'
        members[name]=member
        if name.startswith('blobs/'):
            with archive.extractfile(member) as source:
                assert hashlib.file_digest(source,'sha256').hexdigest()==name.rsplit('/',1)[1],'OCI blob hash mismatch'
    def data(name):
        member=members[name];assert member.size<=16777216,'oversized OCI metadata'
        return archive.extractfile(member).read()
    def obj(name):return json.loads(data(name),object_pairs_hook=unique)
    def blob(descriptor):
        digest=descriptor['digest'];assert re.fullmatch(r'sha256:[0-9a-f]{64}',digest)
        name='blobs/sha256/'+digest[7:]
        assert type(descriptor['size']) is int and descriptor['size']==members[name].size,'OCI descriptor size mismatch'
        assert not descriptor.get('urls'),'external OCI blobs are forbidden'
        return name
    assert obj('oci-layout')['imageLayoutVersion']=='1.0.0','unsupported OCI layout'
    layout=obj('index.json');digest=build['digest'];direct='sha256:'+hashlib.sha256(data('index.json')).hexdigest()==digest
    if direct:root=layout
    else:
        selected=[d for d in layout['manifests'] if d['digest']==digest]
        assert len(selected)==1,'OCI layout does not select the built digest'
        root=obj(blob(selected[0]))
    assert root['schemaVersion']==2 and root['mediaType']==index_type,'release needs an OCI index'
    descriptors=root['manifests'];assert isinstance(descriptors,list) and 2<=len(descriptors)<=64
    images=[d for d in descriptors if d.get('annotations',{}).get('vnd.docker.reference.type')!='attestation-manifest']
    assert len(images)==2 and len({d['digest'] for d in images})==2,'exactly two executable images are required'
    for descriptor in descriptors:
        assert descriptor['mediaType']==manifest_type,'unsupported OCI manifest type'
        manifest=obj(blob(descriptor));assert manifest['schemaVersion']==2 and manifest['mediaType']==manifest_type
        config=obj(blob(manifest['config']));layers=manifest['layers']
        assert isinstance(layers,list) and len(layers)<=256
        for layer in layers:blob(layer)
        if descriptor not in images:
            assert descriptor['platform']=={'architecture':'unknown','os':'unknown'},'unsupported evidence platform'
            assert descriptor['annotations']['vnd.docker.reference.digest'] in {d['digest'] for d in images},'unbound OCI evidence'
            continue
        platform=descriptor['platform'];arch=platform['architecture']
        assert platform['os']=='linux' and arch in ['amd64','arm64'] and platform.get('variant','') in ['', 'v8']
        assert config['os']=='linux' and config['architecture']==arch and config.get('variant','') in ['', 'v8'],'OCI platform config mismatch'
        assert arch=='arm64' or not platform.get('variant') and not config.get('variant'),'invalid amd64 variant'
        labels=config['config']['Labels']
        assert labels['org.opencontainers.image.version']==build['version'].removeprefix('v'),'OCI binary version label mismatch'
        assert labels['org.opencontainers.image.revision']==build['release_source_revision'],'OCI source label mismatch'
        expected={}
        for path in (Path(build['context'])/'dist'/arch).iterdir():
            assert stat.S_ISREG(path.lstat().st_mode),'nonregular authenticated binary'
            with path.open('rb') as source:expected['usr/local/bin/'+path.name]=hashlib.file_digest(source,'sha256').hexdigest()
        assert expected,'no authenticated binaries'
        parents={str(p) for name in expected for p in PurePosixPath(name).parents if str(p)!='.'}
        state={};diff_ids=config['rootfs']['diff_ids']
        assert config['rootfs']['type']=='layers' and len(diff_ids)==len(layers),'OCI layer configuration mismatch'
        class Reader:
            def __init__(self,source):self.source=source;self.hash=hashlib.sha256();self.size=0
            def read(self,size):
                value=self.source.read(size);self.size+=len(value)
                assert self.size<=8589934592,'oversized uncompressed OCI layer'
                self.hash.update(value);return value
        for index,layer in enumerate(layers):
            media=layer['mediaType']
            assert media in ['application/vnd.oci.image.layer.v1.tar','application/vnd.oci.image.layer.v1.tar+gzip'],'unsupported OCI layer compression'
            with archive.extractfile(members[blob(layer)]) as compressed:
                source=gzip.GzipFile(fileobj=compressed) if media.endswith('+gzip') else compressed
                reader=Reader(source);changes={};removed=set();size=0
                with tarfile.open(fileobj=reader,mode='r|') as files:
                    for count,member in enumerate(files):
                        assert count<100000 and member.size<=1073741824,'oversized layer entry set'
                        size+=member.size;assert size<=8589934592,'oversized layer payload'
                        path=PurePosixPath(member.name)
                        assert not path.is_absolute() and '..' not in path.parts,'unsafe layer path'
                        name=str(path);parent=str(path.parent);prefix='' if parent=='.' else parent+'/'
                        if path.name=='.wh..wh..opq':removed.update(n for n in expected if n.startswith(prefix))
                        elif path.name.startswith('.wh.'):removed.update(n for n in expected if n==prefix+path.name[4:] or n.startswith(prefix+path.name[4:]+'/'))
                        elif name in parents:assert member.isdir(),'packaged binary parent is not a directory'
                        elif name in expected:
                            assert member.isfile() and not member.issparse() and name not in changes and member.mode&0o111,'invalid packaged binary'
                            with files.extractfile(member) as binary:changes[name]=hashlib.file_digest(binary,'sha256').hexdigest()
                while reader.read(1048576):pass
                assert 'sha256:'+reader.hash.hexdigest()==diff_ids[index],'OCI uncompressed layer hash mismatch'
                for name in removed:state.pop(name,None)
                state.update(changes)
        assert state==expected,'packaged binaries differ from authenticated release archives'
        rows.append({'reference':build['repository']+'@'+descriptor['digest'],'digest':descriptor['digest'],'platform':'linux/'+arch})
    assert {row['platform'] for row in rows}=={'linux/amd64','linux/arm64'},'missing or duplicate OCI platform'
    destination=Path(sys.argv[3]);destination.mkdir(mode=0o700)
    for name,member in members.items():
        if name=='index.json':continue
        target=destination/name;target.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
        with archive.extractfile(member) as source,target.open('xb') as output:shutil.copyfileobj(source,output)
        if name.startswith('blobs/'):
            with target.open('rb') as copied:assert hashlib.file_digest(copied,'sha256').hexdigest()==name.rsplit('/',1)[1],'staged OCI blob changed'
    if direct:
        raw=data('index.json');target=destination/'blobs/sha256'/digest[7:]
        if not target.exists():
            with target.open('xb') as output:output.write(raw)
        layout={'schemaVersion':2,'mediaType':index_type,'manifests':[{'mediaType':index_type,'digest':digest,'size':len(raw)}]}
        index_bytes=json.dumps(layout,separators=(',',':')).encode()
    else:index_bytes=data('index.json')
    with (destination/'index.json').open('xb') as output:output.write(index_bytes)
print(json.dumps(sorted(rows,key=lambda row:row['platform']),separators=(',',':')))
PY
}

# Push only the collected, independently inspected OCI archive. Registry tags
# are the final mutation, after immutable upload, signatures and both SBOMs.
_dk_release_published() (
    umask 077
    local plan="$1" identity="$2" issuer="$3" skip="$4" build image archive work local_inventory inventory after scans evidence result tag tags
    _dk_verify_policy "$identity" "$issuer" || return $?
    [[ "$skip" == false ]] || { _dk_log_error 'Published-release containers require image signatures'; return 4; }
    docker_check_cosign && _dk_dependency syft && _dk_dependency skopeo || return 3
    build=$(_dk_build_execute "$plan") || return $?
    image=$(jq -er '.reference' <<< "$build") || return 7
    work=$(mktemp -d "${TMPDIR:-/tmp}/dsr-container-publish.XXXXXXXX") || return 7
    _dk_log_info "Retaining container publication inputs and evidence: $work"
    archive="$work/image.oci.tar"
    cp -- "$(jq -er '.output_file' <<< "$build")" "$archive" || return 7
    [[ "$(_dk_hash "$archive")" == "$(jq -r '.archive.sha256' <<< "$build")" ]] || return 7
    local_inventory=$(_dk_oci_inventory "$archive" "$build" "$work") || return 7
    skopeo inspect --raw "oci:$work/layout" > "$work/transport-manifest.json" || return 7
    [[ "sha256:$(_dk_hash "$work/transport-manifest.json")" == "${image##*@}" ]] || return 7
    if [[ "$image" == ghcr.io/* && -n "${DSR_GH_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-}}}" ]]; then docker_login_ghcr || return $?; fi
    _dk_public_release_unchanged "$build" "$work" || return $?
    skopeo copy --all --preserve-digests --digestfile "$work/upload.digest" \
        "oci:$work/layout" "docker://$image" >&2 || return 7
    [[ "$(cat "$work/upload.digest")" == "${image##*@}" ]] || return 7
    inventory=$(_dk_registry_inventory "$image" '["linux/amd64","linux/arm64"]' "$work") || return $?
    [[ "$inventory" == "$local_inventory" ]] || return 7
    scans=$(_dk_prepare_sboms "$inventory" "$work") || return $?
    docker_sign "$image" >/dev/null || return $?
    _dk_verify_signature "$image" "$identity" "$issuer" "$work/signature.json" || return $?
    evidence=$(_dk_publish_sboms "$scans" "$identity" "$issuer" "$work") || return $?
    result=$(_dk_evidence_command verify-scans "$image" "$scans" --certificate-identity "$identity" --certificate-oidc-issuer "$issuer") || return $?
    jq -e --argjson evidence "$evidence" '
        (.platforms|map({reference,predicate_sha256})|sort_by(.reference)) ==
        ($evidence|map({reference,predicate_sha256})|sort_by(.reference))' <<< "$result" >/dev/null || return 7
    tags=$(jq -r '.tags[]' <<< "$build") || return 7
    : > "$work/tag-transitions.jsonl" || return 7
    while IFS= read -r tag; do
        _dk_public_release_unchanged "$build" "$work" || return $?
        jq -nc --arg tag "$tag" --arg image "$image" '{tag:$tag,reference:$image,status:"attempting"}' >> "$work/tag-transitions.jsonl" || return 7
        skopeo copy --all --preserve-digests --digestfile "$work/tag.digest" "docker://$image" "docker://$tag" >&2 || return 7
        [[ "$(cat "$work/tag.digest")" == "${image##*@}" ]] || return 7
        jq -nc --arg tag "$tag" --arg image "$image" '{tag:$tag,reference:$image,status:"verified"}' >> "$work/tag-transitions.jsonl" || return 7
    done <<< "$tags"
    _dk_check_tags "$build" "$work" || return $?
    after=$(_dk_registry_inventory "$image" '["linux/amd64","linux/arm64"]' "$work") || return $?
    [[ "$inventory" == "$after" ]] || return 7
    _dk_public_release_unchanged "$build" "$work" || return $?
    result=$(_dk_evidence_command verify-scans "$image" "$scans" --certificate-identity "$identity" --certificate-oidc-issuer "$issuer") || return $?
    jq -e --argjson evidence "$evidence" '
        (.platforms|map({reference,predicate_sha256})|sort_by(.reference)) ==
        ($evidence|map({reference,predicate_sha256})|sort_by(.reference))' <<< "$result" >/dev/null || return 7
    jq -nc --argjson build "$build" --argjson evidence "$evidence" --argjson result "$result" '
        {schema_version:1,kind:"dsr-container-release",status:"verified",build:$build,
         reference:$build.reference,signature:"verified",sbom:"verified",platforms:$evidence,verification:$result}'
)

# Release failures are never downgraded to warnings. Dependencies are checked
# before push; completed external effects are not deleted to hide a late error.
docker_release() (
    local skip=false published=false plan build image work inventory after scans evidence expected result release_output
    local identity="${DOCKER_CERTIFICATE_IDENTITY:-}" issuer="${DOCKER_CERTIFICATE_OIDC_ISSUER:-}"
    local -a args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tool|-t|--version|-V|--repo-path|--dockerfile|--platform|-p|--tag)
                # Keep build values paired before removing release-only flags.
                # Otherwise a missing value could swallow --skip-sign or shift
                # a trust-policy option into the build plan's positional slots.
                [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || { _dk_log_error "Missing value for $1"; return 4; }
                args+=("$1" "$2"); shift 2 ;;
            --certificate-identity|--certificate-oidc-issuer)
                [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || { _dk_log_error "Missing value for $1"; return 4; }
                case "$1" in --certificate-identity) identity="$2" ;; *) issuer="$2" ;; esac
                shift 2 ;;
            --skip-sign) skip=true; shift ;;
            --published-release) published=true; args+=(--published-release); shift ;;
            --help|-h)
                printf '%s\n' 'docker_release - Build, push, sign, and attest container image' \
                    'Usage: docker_release TOOL VERSION [build options] [--skip-sign] [--dry-run]' \
                    '  --published-release (publish a collected, inspected signed-release OCI export)' \
                    '  --certificate-identity ID --certificate-oidc-issuer HTTPS_ISSUER' >&2
                return 0 ;;
            --push|--local|--output) _dk_log_error 'Release requires registry export'; return 4 ;;
            *) args+=("$1"); shift ;;
        esac
    done
    [[ ${#args[@]} -gt 0 ]] || { _dk_log_error 'Tool and version required'; return 4; }
    if $published; then
        $skip && { _dk_log_error 'Published-release containers require image signatures'; return 4; }
        # Every attempt retains its collected archive. A failed upload must not
        # make a retry collide with the previous attempt's successful export.
        release_output="${DOCKER_OUTPUT_DIR:-${DSR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsr}/containers}/release-${BASHPID}-${RANDOM}.oci.tar"
        plan=$(_dk_build_plan "${args[@]}" --output "$release_output") || return $?
    else
        plan=$(_dk_build_plan "${args[@]}" --push) || return $?
    fi
    if [[ $(jq -r '.dry_run' <<< "$plan") == true ]]; then
        jq -c --argjson skip "$skip" --arg identity "$identity" --arg issuer "$issuer" '
            . + {kind:"dsr-container-release",certificate_identity:$identity,certificate_oidc_issuer:$issuer,
                 signature:(if $skip then "skipped" else "planned" end),sbom:"planned"}' <<< "$plan"
        return $?
    fi
    if [[ $(jq -r '.published_release // false' <<< "$plan") == true ]]; then
        _dk_release_published "$plan" "$identity" "$issuer" "$skip"
        return $?
    fi
    _dk_verify_policy "$identity" "$issuer" || return $?
    docker_check_cosign && _dk_dependency syft || return 3
    build=$(_dk_build_execute "$plan") || return $?
    image=$(jq -er '.reference' <<< "$build") || return 1
    _dk_pinned_valid "$image" || return 1
    expected=$(jq -c '.platforms' <<< "$plan") || return 1
    work=$(mktemp -d "${TMPDIR:-/tmp}/dsr-container-release.XXXXXXXX") || return 1
    trap 'rm -rf -- "$work"' EXIT
    trap 'exit 5' HUP INT TERM
    inventory=$(_dk_registry_inventory "$image" "$expected" "$work") || return $?
    _dk_check_tags "$build" "$work" || return $?
    # Complete ALL scans before publishing any new Cosign evidence.
    scans=$(_dk_prepare_sboms "$inventory" "$work") || return $?
    _dk_check_tags "$build" "$work" || return $?
    if ! $skip; then
        docker_sign "$image" >/dev/null || return $?
        _dk_verify_signature "$image" "$identity" "$issuer" "$work/signature.json" || return $?
    fi
    evidence=$(_dk_publish_sboms "$scans" "$identity" "$issuer" "$work") || return $?
    # Independently reread the entire remote evidence set after all writes.
    local -a verify_args=("$image" --certificate-identity "$identity" --certificate-oidc-issuer "$issuer")
    $skip && verify_args+=(--skip-sign)
    result=$(_dk_evidence_command verify-scans "$image" "$scans" "${verify_args[@]:1}") || return $?
    # An older but valid attestation is not a substitute for the just-scanned one.
    jq -e --argjson published "$evidence" '
        (.platforms | map({reference,predicate_sha256}) | sort_by(.reference)) ==
        ($published | map({reference,predicate_sha256}) | sort_by(.reference))
    ' <<< "$result" >/dev/null || return 7
    after=$(_dk_registry_inventory "$image" "$expected" "$work") || return $?
    [[ "$inventory" == "$after" ]] || return 7
    _dk_check_tags "$build" "$work" || return $?
    jq -nc --argjson build "$build" --argjson skip "$skip" --argjson evidence "$evidence" --argjson result "$result" '
        {schema_version:1,kind:"dsr-container-release",status:"verified",build:$build,
         reference:$build.reference,signature:(if $skip then "skipped" else "verified" end),
         sbom:"verified",platforms:$evidence,verification:$result}'
)

_dk_json() (
    local operation="$1" status=0 output='' error='' work start=$SECONDS
    shift
    _dk_dependency jq || return $?
    work=$(mktemp -d "${TMPDIR:-/tmp}/dsr-container-json.XXXXXXXX") || return 1
    trap 'rm -rf -- "$work"' EXIT
    trap 'exit 5' HUP INT TERM
    output=$("$operation" "$@" 2> "$work/error") || status=$?
    error=$(head -c 8192 "$work/error")
    jq -nc --arg output "$output" --arg error "$error" --argjson code "$status" --argjson duration "$((SECONDS-start))" '
        ($output | fromjson? // null) as $result |
        {status:(if $code != 0 then "error" elif $result.status == "planned" then "planned" else "success" end),
         exit_code:$code,output:$output,result:$result,diagnostics:$error,duration_seconds:$duration}' || return 1
    return "$status"
)
docker_build_json() { _dk_json docker_build "$@"; }
docker_release_json() { _dk_json docker_release "$@"; }

# Both entry points use these exact parsers. The public dsr CLI adds only its
# common JSON envelope, never a second interpretation of operation arguments.
docker_command() {
    local command="${1:-help}"
    [[ $# -eq 0 ]] || shift
    case "$command" in
        build) docker_build "$@" ;;
        release) docker_release "$@" ;;
        sign) docker_sign "$@" ;;
        setup) docker_setup "$@" ;;
        attest) docker_attest_sbom "$@" ;;
        verify) docker_verify_release "$@" ;;
        build-json) docker_build_json "$@" ;;
        release-json) docker_release_json "$@" ;;
        help|--help|-h) printf '%s\n' 'Usage: bash src/docker.sh build|release|sign|setup|attest|verify|build-json|release-json [options]' ;;
        *) _dk_log_error "Unknown docker subcommand: $command"; return 4 ;;
    esac
}

export -f docker_check docker_check_buildx docker_check_cosign docker_version
export -f docker_setup_buildx docker_setup docker_command docker_check_ghcr_auth docker_login_ghcr
export -f docker_is_containerized docker_find_dockerfile docker_build docker_sign
export -f docker_attest_sbom docker_release docker_build_json docker_release_json
export -f _dk_build_execute_local _dk_build_remote_release _dk_published_release_context _dk_clear_git_context
export -f _dk_public_release_unchanged _dk_oci_inventory _dk_release_published
export -f _dk_log_info _dk_log_ok _dk_log_warn _dk_log_error _dk_log_debug
export -f _dk_dependency _dk_resolve_gh_token _dk_tag_valid _dk_repository_valid _dk_pinned_valid
export -f _dk_platforms _dk_hash _dk_build_plan _dk_build_execute _dk_spdx_valid _dk_json
export -f _dk_fetch_manifest _dk_registry_inventory _dk_verify_policy _dk_verify_signature
export -f _dk_verify_attestation _dk_prepare_sboms _dk_publish_sboms _dk_evidence_command
export -f docker_verify_release _dk_check_tags

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -uo pipefail
    docker_command "$@"
    exit $?
fi
