#!/usr/bin/env bash
# Full SLSA mapper, remote verifier and snapshot admission. GitHub transport and
# Minisign are explicit hash-bound fixtures, NOT live network/Ed25519 acceptance.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
source "$ROOT/src/slsa.sh"
source "$ROOT/src/slsa_remote.sh"
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/tmp"
export PATH="$WORK/bin:$PATH" TMPDIR="$WORK/tmp"
cat > "$WORK/bin/minisign" <<'SIGNER'
#!/usr/bin/env bash
set -uo pipefail
file='' signature='' token=''
while (($#)); do case "$1" in
    -V|-H|-q) shift ;; -m) file=$2; shift 2 ;; -x) signature=$2; shift 2 ;; -P) token=$2; shift 2 ;; *) exit 99 ;;
esac; done
hash=$(sha256sum < "$file") || exit 1
[[ $(cat "$signature") == "$token:${hash%% *}" ]]
SIGNER
chmod 755 "$WORK/bin/minisign"
TOKEN=$(printf 'A%.0s' {1..56})
PIN=$(printf 'a%.0s' {1..40})
PASS=0 FAIL=0 CODE=0 CASE='' MODE=normal
check() { local label=$1; shift; if "$@" > "$WORK/check.out" 2>&1; then
    PASS=$((PASS+1)); printf 'PASS %s\n' "$label"
    else FAIL=$((FAIL+1)); printf 'FAIL %s\n' "$label"; cat "$WORK/check.out"; fi; }
expect() {
    local label=$1 expected=$2; shift 2; CODE=0
    "$@" > "$CASE/result" 2> "$CASE/error" || CODE=$?
    check "$label" test "$CODE" = "$expected"
    [[ "$CODE" == "$expected" ]] || cat "$CASE/error" "$CASE/result"
    if ((expected)); then check 'failure emits no success object' test ! -s "$CASE/result"; fi
}
trace() { printf '%s\n' "$*" >> "$CASE/calls"; }
sign_fixture() { printf '%s:%s\n' "$TOKEN" "$(_slsa_sha256 "$1")" > "$2"; }
_sbr_require() { trace auth; }
_sbr_run() { "$@"; }
_sbr_context() { trace context; cat "$CASE/context.json"; }
_sbr_inventory() { jq -cS 'sort_by(.name)' "$CASE/inventory.json"; }
_sbr_named_asset() { jq -ce --arg name "$2" '[.[]|select(.name==$name)]|if length==1 then .[0] else error("missing/ambiguous") end' <<< "$1" || return 7; }
_sbr_payload_names() { jq -c '[.[]|select(.name|endswith(".jsonl") or endswith(".minisig")|not)|.name]|sort' <<< "$1"; }
_sbr_asset_digest() {
    local hash
    hash=$(jq -r '.digest // ""' <<< "$1") || return 7
    [[ $(jq -r .state <<< "$1") == uploaded && ( -z "$hash" || "$hash" == "sha256:$2" ) ]] || return 7
}
_sbr_inventory_sha256() { jq -cS 'sort_by(.name)' <<< "$1" > "$2/inventory-hash.json"; _slsa_sha256 "$2/inventory-hash.json"; }
_sbr_download() {
    local dir hash size
    _sbr_asset_digest "$2" "$3" || return 7
    dir=$(mktemp -d "$4/payload.XXXXXXXX") || return 1
    gh_download_release_asset "$1" "$(jq -r .id <<< "$2")" "$dir/body" || return $?
    hash=$(_slsa_sha256 "$dir/body") || return 7
    size=$(wc -c < "$dir/body")
    [[ "$hash" == "$3" && "${size//[[:space:]]/}" == "$(jq -r .size <<< "$2")" ]] || return 7
    printf '%s\n' "$dir/body"
}
gh_download_release_asset() {
    trace "download $2"
    [[ "$MODE" != network-failure ]] || return 8
    [[ "$MODE" != interrupted ]] || return 5
    cp "$CASE/remote/$2" "$3" || return 8
    if [[ "$MODE" == changed-tag && "$2" == 3 ]]; then
        jq '.tag_commit=("b"*40)' "$CASE/context.json" > "$CASE/changed"
        cp "$CASE/changed" "$CASE/context.json"
    fi
    if [[ "$MODE" == changed-key && "$2" == 3 ]]; then printf 'changed\n' >> "$CASE/key.pub"; fi
    if [[ "$MODE" == corrupt-body && "$2" == 3 ]]; then printf corrupt >> "$3"; fi
}
new_case() {
    CASE="$WORK/$1"; MODE=normal
    mkdir -p "$CASE/remote" "$CASE/assets"
    : > "$CASE/calls"
    printf 'untrusted comment: fixture\n%s\n' "$TOKEN" > "$CASE/key.pub"
    printf 'linux payload\n' > "$CASE/assets/demo-linux"
    cp "$CASE/assets/demo-linux" "$CASE/assets/demo-linux-alias"
    printf 'windows payload\n' > "$CASE/assets/demo-windows.exe"
    jq -cn --arg pin "$PIN" --arg l "$(_slsa_sha256 "$CASE/assets/demo-linux")" \
        --arg w "$(_slsa_sha256 "$CASE/assets/demo-windows.exe")" '
        {schema_version:"1.0.0",tool:"demo",version:"v1.2.3",run_id:"11111111-1111-4111-8111-111111111111",
         built_at:"2026-09-24T00:00:00Z",source:{git_sha:$pin,git_ref:"refs/tags/v1.2.3",dependencies:[]},
         status:"success",summary:{total:2,success:2,failed:0},requested_targets:["linux/amd64","windows/arm64"],
         artifacts:[{name:"demo-linux",target:"linux/amd64",sha256:$l,size_bytes:14,archive_format:"binary"},
          {name:"demo-linux-alias",target:"linux/amd64",sha256:$l,size_bytes:14,archive_format:"binary"},
          {name:"demo-windows.exe",target:"windows/arm64",sha256:$w,size_bytes:16,archive_format:"binary"}]}' > "$CASE/build.json"
    _slsa_manifest_statement "$CASE/build.json" owner/demo dsr:test > "$CASE/remote/4" || exit 1
    sign_fixture "$CASE/remote/4" "$CASE/remote/5"
    cp "$CASE/assets/demo-linux" "$CASE/remote/1"
    cp "$CASE/assets/demo-linux-alias" "$CASE/remote/2"
    cp "$CASE/assets/demo-windows.exe" "$CASE/remote/3"
    refresh_remote
    jq -cn --arg pin "$PIN" '{repository:{id:1,node_id:"repo",full_name:"owner/demo"},
        release:{id:10,node_id:"release",tag_name:"v1.2.3",draft:false,prerelease:false,target_commitish:$pin,
        upload_url:"https://uploads.github.com/repos/owner/demo/releases/10/assets{?name,label}"},tag_commit:$pin}' > "$CASE/context.json"
}
refresh_remote() {
    : > "$CASE/records"
    local id name
    for id in 1 2 3 4 5; do
        case "$id" in 1) name=demo-linux ;; 2) name=demo-linux-alias ;; 3) name=demo-windows.exe ;; 4) name=release.intoto.jsonl ;; 5) name=release.intoto.jsonl.minisig ;; esac
        jq -cn --argjson id "$id" --arg name "$name" --arg hash "$(_slsa_sha256 "$CASE/remote/$id")" \
            --argjson size "$(wc -c < "$CASE/remote/$id")" '{id:$id,name:$name,state:"uploaded",size:$size,digest:("sha256:"+$hash)}' >> "$CASE/records"
    done
    jq -cs 'sort_by(.name)' "$CASE/records" > "$CASE/inventory.json"
}
policy() { "$@" --repo owner/demo --tag v1.2.3 --sha "$PIN" --builder dsr:test \
    --targets linux/amd64,windows/arm64 --public-key "$CASE/key.pub"; }
fetch() { policy slsa_fetch_release --output-dir "$CASE/snapshot" "$@"; }
verify() { policy slsa_verify_snapshot "$CASE/snapshot" "$@"; }
[[ "${DSR_SNAPSHOT_FIXTURES_ONLY:-false}" != true ]] || return 0

new_case success
expect 'existing remote verification keeps its original behavior' 0 policy slsa_verify_remote
check 'ordinary verification retains no caller snapshot' test ! -e "$CASE/snapshot"
: > "$CASE/calls"
expect 'fetch authenticates and retains a complete release' 0 fetch
check 'all payloads and proofs are downloaded once' test "$(grep -c '^download ' "$CASE/calls")" = 5
check 'fetch result identifies the published local snapshot' jq -e --arg root "$CASE/snapshot" \
    '.kind=="dsr-slsa-fetch" and .authenticated and .snapshot==$root and .verification.artifact_count==3' "$CASE/result"
check 'exact proof bytes are retained' cmp -s "$CASE/remote/4" "$CASE/snapshot/release.intoto.jsonl"
check 'exact detached signature is retained' cmp -s "$CASE/remote/5" "$CASE/snapshot/release.intoto.jsonl.minisig"
for pair in '1 demo-linux' '2 demo-linux-alias' '3 demo-windows.exe'; do
    read -r id name <<< "$pair"
    check 'retained payload equals authenticated immutable-ID download' cmp -s "$CASE/remote/$id" "$CASE/snapshot/artifacts/$name"
done
HASH=$(jq -r .snapshot_sha256 "$CASE/result")
BEFORE=$(stat -c %i "$CASE/snapshot/artifacts/demo-linux")
: > "$CASE/calls"
MODE=network-failure
expect 'offline verification needs no remote service' 0 verify
check 'offline result never claims current remote verification' jq -e --arg hash "$HASH" \
    '.kind=="dsr-slsa-snapshot-verification" and .authenticated and .remote_current==false and
     .snapshot_sha256==$hash and (.artifacts|length)==3' "$CASE/result"
check 'offline verification performs no network or authentication-to-GitHub calls' test ! -s "$CASE/calls"
expect 'existing publication dry-run remains local authentication only' 0 policy slsa_publish_release \
    "$CASE/remote/4" "$CASE/assets" --signature "$CASE/remote/5" --dry-run
check 'publication planning makes no network calls' test ! -s "$CASE/calls"
expect 'occupied snapshot is never overwritten or redownloaded' 2 fetch
check 'occupied snapshot retains its inode' test "$BEFORE" = "$(stat -c %i "$CASE/snapshot/artifacts/demo-linux")"
check 'occupied snapshot blocks remote calls' test ! -s "$CASE/calls"
# The public CLI itself must work with only slsa.sh and slsa_remote.sh installed.
expect 'standalone offline CLI does not load GitHub or scanner modules' 0 policy bash "$ROOT/src/slsa_remote.sh" verify-snapshot "$CASE/snapshot"
printf '{"authenticated":true,"tag_commit":"forged"}\n' > "$CASE/snapshot/download.json"
expect 'offline verification does not treat download receipt as authority' 0 verify
check 'offline claims still come only from authenticated bytes' jq -e --arg pin "$PIN" '.policy.source_sha==$pin and .remote_current==false' "$CASE/result"
expect 'independent manifest and invocation pins bind the offline snapshot' 0 verify \
    --manifest-sha256 "$(_slsa_sha256 "$CASE/build.json")" --invocation-id 11111111-1111-4111-8111-111111111111 \
    --statement-sha256 "$(_slsa_sha256 "$CASE/snapshot/release.intoto.jsonl")"
for option in --statement-sha256 --manifest-sha256; do
    expect 'wrong independent build pin fails offline' 7 verify "$option" "$(printf 'b%.0s' {1..64})"
done
expect 'wrong invocation fails offline' 7 verify --invocation-id another-run
printf corrupt >> "$CASE/snapshot/artifacts/demo-windows.exe"
expect 'last-platform corruption cannot hide behind valid first payload or receipt' 1 verify
cp "$CASE/remote/3" "$CASE/snapshot/artifacts/demo-windows.exe"
printf extra > "$CASE/snapshot/artifacts/.unexpected"
expect 'extra hidden payload blocks exact namespace admission' 7 verify
mv "$CASE/snapshot/artifacts/.unexpected" "$CASE/held-extra"
mv "$CASE/snapshot/artifacts/demo-linux" "$CASE/held-linux"
ln -s "$CASE/held-linux" "$CASE/snapshot/artifacts/demo-linux"
expect 'even a byte-correct linked payload is rejected' 7 verify
mv "$CASE/snapshot/artifacts/demo-linux" "$CASE/held-link"
mv "$CASE/held-linux" "$CASE/snapshot/artifacts/demo-linux"
expect 'restoring original regular payload permits verification without repair logic' 0 verify
for field in '.predicate.buildDefinition.externalParameters.version="v9.9.9"' \
    '.predicate.buildDefinition.resolvedDependencies[0].digest.gitCommit=("b"*40)' \
    '.predicate.buildDefinition.externalParameters.targets=["linux/amd64"]' \
    '.dsr_evidence.artifacts[0].archive_format="unknown"' \
    '.subject[1].name="DEMO-LINUX"|.dsr_evidence.artifacts[1].name="DEMO-LINUX"'; do
    jq "$field" "$CASE/remote/4" > "$CASE/snapshot/release.intoto.jsonl"
    sign_fixture "$CASE/snapshot/release.intoto.jsonl" "$CASE/snapshot/release.intoto.jsonl.minisig"
    expect 'correct signature cannot waive the selected policy or safe snapshot inventory' 7 verify
 done
cp "$CASE/remote/4" "$CASE/snapshot/release.intoto.jsonl"
cp "$CASE/remote/5" "$CASE/snapshot/release.intoto.jsonl.minisig"
cp "$CASE/snapshot/release.intoto.jsonl" "$CASE/original-proof"
jq '.predicate.runDetails.builder.id="attacker"' "$CASE/original-proof" > "$CASE/snapshot/release.intoto.jsonl"
expect 'forged receipt cannot authenticate edited statement bytes' 1 verify
sign_fixture "$CASE/snapshot/release.intoto.jsonl" "$CASE/snapshot/release.intoto.jsonl.minisig"
expect 'even signed different builder is rejected by caller policy' 7 verify
cp "$CASE/remote/4" "$CASE/snapshot/release.intoto.jsonl"
cp "$CASE/remote/5" "$CASE/snapshot/release.intoto.jsonl.minisig"
expect 'payload budget also applies to offline snapshots' 7 env SLSA_REMOTE_MAX_PAYLOAD_BYTES=1 bash "$ROOT/src/slsa_remote.sh" \
    verify-snapshot "$CASE/snapshot" --repo owner/demo --tag v1.2.3 --sha "$PIN" --builder dsr:test \
    --targets linux/amd64,windows/arm64 --public-key "$CASE/key.pub"

for mode in network-failure interrupted changed-tag corrupt-body changed-key; do
    new_case "$mode"; MODE=$mode
    expected=7
    [[ "$mode" != network-failure ]] || expected=8
    [[ "$mode" != interrupted ]] || expected=5
    expect 'failed remote admission publishes no snapshot' "$expected" fetch
    check 'incomplete download never becomes visible as a snapshot' test ! -e "$CASE/snapshot"
    check 'handled failure cleans private fetch staging' bash -c '[[ -z $(find "$1" -maxdepth 1 -name ".dsr-fetch.*" -print) ]]' _ "$CASE"
done
new_case bad-proof
printf invalid > "$CASE/remote/5"
refresh_remote
expect 'invalid detached signature cannot be made a reusable snapshot' 1 fetch
check 'unauthenticated proof never requests payload bodies' bash -c '! grep -Eq "^download [123]$" "$1"' _ "$CASE/calls"
new_case lock
exec 7>> "$CASE/snapshot.lock"
flock -n 7 || exit 1
expect 'concurrent snapshot writer is excluded' 2 fetch
check 'occupied snapshot lock blocks all network calls' test ! -s "$CASE/calls"
exec 7>&-
expect 'released lock permits a complete snapshot' 0 fetch
new_case paths
mkdir "$CASE/real"
ln -s "$CASE/real" "$CASE/link"
expect 'symlink output ancestor is rejected' 4 policy slsa_fetch_release --output-dir "$CASE/link/out"
expect 'relative output path is rejected' 4 policy slsa_fetch_release --output-dir relative
expect 'duplicate output selections are rejected' 4 fetch --output-dir "$CASE/other"
check 'invalid output selections perform no network reads' test ! -s "$CASE/calls"
printf '\nSLSA release snapshots: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
