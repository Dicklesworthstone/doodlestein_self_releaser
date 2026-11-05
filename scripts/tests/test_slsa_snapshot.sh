#!/usr/bin/env bash
# Full SLSA mapper, remote verifier and snapshot admission. GitHub transport and
# Minisign are explicit hash-bound fixtures, NOT live network/Ed25519 acceptance.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
source "$ROOT/src/slsa.sh"
source "$ROOT/src/slsa_remote.sh"
WORK=$(mktemp -d) || exit 1
# macOS temporary roots may traverse /var; only canonicalize our owned fixture root.
WORK=$(cd "$WORK" && pwd -P) || exit 1
if [[ "${DSR_RETAIN_TEST_EVIDENCE:-0}" == 1 ]]; then
    trap 'printf "Retained test evidence: %s\n" "$WORK" >&2' EXIT
else
    trap 'rm -rf -- "$WORK"' EXIT
fi
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
    if [[ "$MODE" == parallel-* && "$2" =~ ^[123]$ ]]; then
        parallel_body "$2" "$3"
        return $?
    fi
    [[ "$MODE" != network-failure ]] || return 8
    [[ "$MODE" != interrupted ]] || return 5
    if [[ "$MODE" == late-failure && "$2" == 3 ]]; then
        printf 'incomplete transport bytes\n' > "$3"
        return 8
    fi
    if [[ "$MODE" == late-interrupted && "$2" == 3 ]]; then return 5; fi
    if [[ "$MODE" == blocked-body && "$2" == 3 ]]; then
        printf 'uncommitted transfer\n' > "$3"
        : > "$CASE/body-blocked"
        sleep 30
        return 8
    fi
    cp "$CASE/remote/$2" "$3" || return 8
    if [[ "$MODE" == changed-tag && "$2" == 3 ]]; then
        jq '.tag_commit=("b"*40)' "$CASE/context.json" > "$CASE/changed"
        cp "$CASE/changed" "$CASE/context.json"
    fi
    if [[ "$MODE" == changed-key && "$2" == 3 ]]; then printf 'changed\n' >> "$CASE/key.pub"; fi
    if [[ "$MODE" == corrupt-body && "$2" == 3 ]]; then printf corrupt >> "$3"; fi
}
parallel_body() {
    # Real concurrent child processes and filesystem barriers, with no timing
    # speedup assertion. Only this explicit transport fixture is substituted.
    python3 - "$CASE" "$MODE" "$1" "$2" <<'PY'
import fcntl
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

case, mode, asset, output = Path(sys.argv[1]), sys.argv[2], sys.argv[3], Path(sys.argv[4])
state = case / "parallel.json"

def record(event):
    with (case / "parallel.lock").open("a+") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        data = json.loads(state.read_text()) if state.exists() else dict(active=[], peak=0, events=[])
        if event == "start":
            data["active"].append(asset)
            data["peak"] = max(data["peak"], len(data["active"]))
        elif asset in data["active"]:
            data["active"].remove(asset)
        data["events"].append(dict(asset=asset, event=event, pid=os.getpid(), group=os.getpgrp()))
        state.write_text(json.dumps(data))

def until(path):
    deadline = time.monotonic() + 8
    while not path.exists():
        assert time.monotonic() < deadline, "parallel transport barrier was not satisfied: " + str(path)
        time.sleep(.01)

def interrupted(signum, frame):
    raise SystemExit(128 + signum)

for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(sig, interrupted)

record("start")
(case / ("started-" + asset)).touch()
try:
    if mode == "parallel-queue":
        if asset == "1":
            until(case / "started-3")
        elif asset == "2":
            until(case / "started-1")
        else:
            assert (case / "snapshot.partial/artifacts/demo-linux-alias").is_file(), "ready sibling was not retained before refilling its slot"
    elif mode in ("parallel-failure", "parallel-cancel"):
        if mode == "parallel-failure" and asset == "2":
            until(case / "resistant-1.ready")
            until(case / "resistant-1.active")
            raise SystemExit(8)
        if mode == "parallel-failure" or asset != "1":
            marker = case / ("resistant-" + asset)
            # This ordinary descendant deliberately ignores TERM and retains
            # inherited custody descriptors. The production anchor must reap
            # its entire group before the destination lock can be acquired.
            child = subprocess.Popen([sys.executable, "-c",
                "import os,signal,sys,time\nfrom pathlib import Path\n"
                "signal.signal(signal.SIGTERM,signal.SIG_IGN)\n"
                "Path(sys.argv[1]+'.group').write_text(str(os.getpgrp()))\n"
                "Path(sys.argv[1]+'.pid').write_text(str(os.getpid()))\n"
                "for counter in range(600):\n"
                " Path(sys.argv[1]+'.heartbeat').write_text(str(counter))\n"
                " if counter==0: Path(sys.argv[1]+'.ready').touch()\n"
                " if counter==2: Path(sys.argv[1]+'.active').touch()\n"
                " time.sleep(.05)\n", str(marker)], close_fds=False)
            until(Path(str(marker) + ".ready"))
            (case / ("blocked-" + asset)).touch()
            while True:
                time.sleep(.1)
    shutil.copyfile(case / "remote" / asset, output)
finally:
    record("end")
PY
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

if [[ "${DSR_SNAPSHOT_PARALLEL_ONLY:-0}" != 1 ]]; then
if [[ "${DSR_SNAPSHOT_RESUME_ONLY:-0}" != 1 ]]; then
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
fi

new_case resumable
MODE=late-failure
expect 'resumable fetch retains authenticated progress after a late transport failure' 8 fetch --resume
check 'interrupted fetch exposes no complete snapshot' test ! -e "$CASE/snapshot"
check 'checkpoint contains only complete first-platform payloads' bash -c \
    '[[ -f "$1/selection.json" && -f "$1/artifacts/demo-linux" && -f "$1/artifacts/demo-linux-alias" && ! -e "$1/artifacts/demo-windows.exe" ]]' \
    _ "$CASE/snapshot.partial"
check 'incomplete transfer bytes never enter the retained namespace' test \
    "$(find "$CASE/snapshot.partial/artifacts" -mindepth 1 -maxdepth 1 -type f | wc -l)" = 2
PARTIAL_BEFORE=$(stat -c %i "$CASE/snapshot.partial/artifacts/demo-linux")
SELECTION_HASH=$(_slsa_sha256 "$CASE/snapshot.partial/selection.json")
: > "$CASE/calls"
expect 'retained progress requires explicit resume mode' 2 fetch
check 'omitted resume causes no remote calls' test ! -s "$CASE/calls"
MODE=normal
expect 'retry authenticates the statement and downloads only missing payloads' 0 fetch --resume
check 'retry reuses both complete payloads and downloads the missing one' jq -e \
    '.resumable and .acquisition=={reused_payloads:2,downloaded_payloads:1}' "$CASE/result"
check 'retry downloads fresh proof/signature and only the unfinished target' bash -c \
    '[[ $(grep -c "^download " "$1") == 3 ]] && ! grep -Eq "^download [12]$" "$1"' _ "$CASE/calls"
check 'retry preserves the selected completed file inode' test "$PARTIAL_BEFORE" = "$(stat -c %i "$CASE/snapshot/artifacts/demo-linux")"
check 'retry preserves its original checkpoint selection bytes' test "$SELECTION_HASH" = "$(_slsa_sha256 "$CASE/snapshot.partial/selection.json")"
expect 'resumed snapshot remains independently verifiable offline' 0 verify
HASH=$(jq -r .snapshot_sha256 "$CASE/result")
BEFORE=$(stat -c %i "$CASE/snapshot")
DOWNLOAD_BEFORE=$(stat -c %i "$CASE/snapshot/download.json")
: > "$CASE/calls"
expect 'completed resume reauthenticates the same generation without payload downloads' 0 fetch --resume
check 'completed resume retains the same authenticated identity and reuses every payload' jq -e --arg hash "$HASH" \
    '.snapshot_sha256==$hash and .acquisition=={reused_payloads:3,downloaded_payloads:0}' "$CASE/result"
check 'completed retry still obtains current proof and signature' test "$(grep -c '^download ' "$CASE/calls")" = 2
check 'completed retry does not replace its snapshot or historical receipt' bash -c \
    '[[ $(stat -c %i "$1") == "$2" && $(stat -c %i "$1/download.json") == "$3" ]]' _ "$CASE/snapshot" "$BEFORE" "$DOWNLOAD_BEFORE"
chmod 600 "$CASE/snapshot/artifacts/demo-windows.exe" || exit 1
printf corrupt >> "$CASE/snapshot/artifacts/demo-windows.exe" || exit 1
: > "$CASE/calls"
expect 'completed resume refuses changed output without repair' 1 fetch --resume
check 'invalid completed output prevents all remote calls' test ! -s "$CASE/calls"

for drift in cached-bytes unexpected-file linked-file linked-directory linked-selection policy key inventory release statement signature tag; do
    new_case "resume-$drift"
    MODE=late-interrupted
    expect 'transport interruption retains only fully authenticated payloads' 5 fetch --resume
    MODE=normal
    PARTIAL_BEFORE=$(stat -c %i "$CASE/snapshot.partial/artifacts/demo-linux")
    extra=()
    case "$drift" in
        cached-bytes)
            chmod 600 "$CASE/snapshot.partial/artifacts/demo-linux-alias" || exit 1
            printf corrupt >> "$CASE/snapshot.partial/artifacts/demo-linux-alias" || exit 1 ;;
        unexpected-file) printf unrelated > "$CASE/snapshot.partial/artifacts/.unexpected" ;;
        linked-file)
            mv "$CASE/snapshot.partial/artifacts/demo-linux" "$CASE/held-payload"
            ln -s "$CASE/held-payload" "$CASE/snapshot.partial/artifacts/demo-linux" ;;
        linked-directory)
            mv "$CASE/snapshot.partial/artifacts" "$CASE/held-artifacts"
            ln -s "$CASE/held-artifacts" "$CASE/snapshot.partial/artifacts" ;;
        linked-selection)
            mv "$CASE/snapshot.partial/selection.json" "$CASE/held-selection.json"
            ln -s "$CASE/held-selection.json" "$CASE/snapshot.partial/selection.json" ;;
        policy) extra=(--manifest-sha256 "$(_slsa_sha256 "$CASE/build.json")") ;;
        key) printf 'another public comment\n' >> "$CASE/key.pub" ;;
        inventory)
            jq 'map(if .id==3 then .id=30 else . end)' "$CASE/inventory.json" > "$CASE/new-inventory"
            cp "$CASE/new-inventory" "$CASE/inventory.json" ;;
        release)
            jq '.release.draft=true' "$CASE/context.json" > "$CASE/new-context"
            cp "$CASE/new-context" "$CASE/context.json" ;;
        statement)
            jq '.predicate.runDetails.metadata.invocationId="22222222-2222-4222-8222-222222222222"' \
                "$CASE/remote/4" > "$CASE/new-proof"
            cp "$CASE/new-proof" "$CASE/remote/4"
            sign_fixture "$CASE/remote/4" "$CASE/remote/5"
            refresh_remote ;;
        signature) printf '\n' >> "$CASE/remote/5"; refresh_remote ;;
        tag)
            jq '.tag_commit=("b"*40)' "$CASE/context.json" > "$CASE/new-context"
            cp "$CASE/new-context" "$CASE/context.json" ;;
    esac
    : > "$CASE/calls"
    expect "resume refuses changed $drift before fetching missing payloads" 7 fetch --resume "${extra[@]}"
    check 'changed checkpoint or release never authorizes partial output' test ! -e "$CASE/snapshot"
    check 'checkpoint rejection requests no payload body' bash -c \
        '! grep -Eq "^download (1|2|3|30)$" "$1"' _ "$CASE/calls"
    if [[ "$drift" != linked-file ]]; then
        check 'refusal retains original payload instead of replacing it' test "$PARTIAL_BEFORE" = \
            "$(stat -c %i "$CASE/snapshot.partial/artifacts/demo-linux")"
    fi
done

new_case resume-untrusted
printf invalid > "$CASE/remote/5"
refresh_remote
expect 'unauthenticated proof cannot establish a resumable checkpoint' 1 fetch --resume
check 'invalid proof persists no reusable payload selection' test ! -e "$CASE/snapshot.partial"
check 'invalid proof requests no payload bytes' bash -c '! grep -Eq "^download [123]$" "$1"' _ "$CASE/calls"
new_case resume-unowned
mkdir "$CASE/snapshot.partial"
printf unowned > "$CASE/snapshot.partial/operator-file"
expect 'resume never adopts an unrelated partial directory' 7 fetch --resume
check 'unrelated checkpoint content remains intact' test "$(cat "$CASE/snapshot.partial/operator-file")" = unowned
check 'unrelated checkpoint requests no payload bytes' bash -c '! grep -Eq "^download [123]$" "$1"' _ "$CASE/calls"
new_case resume-options
expect 'resume is not accepted as a remote verification flag' 4 policy slsa_verify_remote --resume
expect 'duplicate resume selection is rejected' 4 fetch --resume --resume
check 'invalid resume options make no remote calls' test ! -s "$CASE/calls"
new_case resume-cli
# Exercise the public executable entry point with the same explicit transport
# boundary fixtures. Only the isolated child receives these exported functions.
(
    export CASE MODE
    export -f trace _sbr_require _sbr_run _sbr_context _sbr_inventory _sbr_named_asset _sbr_payload_names \
        _sbr_asset_digest _sbr_inventory_sha256 _sbr_download gh_download_release_asset
    MODE=late-failure
    policy bash "$ROOT/src/slsa_remote.sh" fetch-release --resume --output-dir "$CASE/snapshot" \
        > "$CASE/cli-first.json" 2> "$CASE/cli-first.log"
    code=$?
    [[ "$code" == 8 ]] || exit 1
    MODE=normal
    policy bash "$ROOT/src/slsa_remote.sh" fetch-release --resume --output-dir "$CASE/snapshot" \
        > "$CASE/cli-second.json" 2> "$CASE/cli-second.log" || exit 1
) > "$CASE/cli-setup.log" 2>&1
CODE=$?
check 'standalone fetch CLI resumes a late transport failure' test "$CODE" = 0
check 'standalone CLI emits no partial success and reuses prior payloads' bash -c \
    '[[ ! -s "$1/cli-first.json" ]] && jq -e '\''.kind=="dsr-slsa-fetch" and .authenticated and .acquisition=={reused_payloads:2,downloaded_payloads:1}'\'' "$1/cli-second.json"' _ "$CASE"
new_case resume-cancelled
(
    export CASE MODE=blocked-body
    export -f trace _sbr_require _sbr_run _sbr_context _sbr_inventory _sbr_named_asset _sbr_payload_names \
        _sbr_asset_digest _sbr_inventory_sha256 _sbr_download gh_download_release_asset
    python3 - "$ROOT/src/slsa_remote.sh" "$CASE" "$PIN" <<'PY'
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

module, case, pin = sys.argv[1], Path(sys.argv[2]), sys.argv[3]
command = ["bash", module, "fetch-release", "--resume", "--output-dir", str(case / "snapshot"),
           "--repo", "owner/demo", "--tag", "v1.2.3", "--sha", pin, "--builder", "dsr:test",
           "--targets", "linux/amd64,windows/arm64", "--public-key", str(case / "key.pub")]
with (case / "cancelled.stdout").open("wb") as out, (case / "cancelled.stderr").open("wb") as err:
    process = subprocess.Popen(command, stdout=out, stderr=err, start_new_session=True)
    try:
        deadline = time.monotonic() + 15
        while not (case / "body-blocked").exists():
            assert process.poll() is None and time.monotonic() < deadline, "fetch did not reach the blocked final payload"
            time.sleep(.02)
        payload = case / "snapshot.partial/artifacts/demo-linux"
        assert payload.is_file() and not (case / "snapshot").exists(), "completed progress was not retained"
        before = (case / "calls").read_bytes()
        competing = subprocess.run(command, capture_output=True, timeout=10)
        assert competing.returncode == 2 and not competing.stdout, "competing resume escaped the destination lock"
        assert (case / "calls").read_bytes() == before, "competing resume performed remote work"
        # Signal this invocation's owned foreground process group, as terminal
        # cancellation would. No saved PID or unrelated process is selected.
        os.killpg(process.pid, signal.SIGTERM)
        code = process.wait(timeout=10)
        assert code in (-signal.SIGTERM, 5, 128 + signal.SIGTERM), "cancellation reported success"
        deadline = time.monotonic() + 5
        while True:
            with (case / "snapshot.lock").open("rb") as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    assert time.monotonic() < deadline, "cancelled transport retained the destination lock"
            time.sleep(.02)
        assert not (case / "cancelled.stdout").read_bytes(), "cancelled fetch emitted a success object"
        assert not (case / "snapshot.partial/artifacts/demo-windows.exe").exists(), "partial body entered checkpoint"
        (case / "interruption.json").write_text(json.dumps(dict(exit_code=code, inode=payload.stat().st_ino)))
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
PY
) > "$CASE/interruption.log" 2>&1
CODE=$?
check 'actual cancellation retains complete files and releases exclusive resume custody' test "$CODE" = 0
[[ "$CODE" == 0 ]] || cat "$CASE/interruption.log"
: > "$CASE/calls"
expect 'same selection resumes after actual process cancellation' 0 fetch --resume
check 'process-cancelled resume keeps completed inode and downloads only the unfinished payload' bash -c \
    '[[ $(stat -c %i "$1/snapshot/artifacts/demo-linux") == $(jq -r .inode "$1/interruption.json") ]] &&
     jq -e '\''.acquisition=={reused_payloads:2,downloaded_payloads:1}'\'' "$1/result"' _ "$CASE"
fi

if [[ "${DSR_SNAPSHOT_RESUME_ONLY:-0}" != 1 ]]; then
# Retain the explicit GitHub/signature boundary fixtures, but run the genuine
# downloader with the pool's production process-group supervision.
# Load their exact declarations in isolation so fixture metadata APIs stay put.
production_transport=$(
    source "$ROOT/src/sbom.sh" || exit
    # shellcheck source=src/sbom_release.sh
    source "${DSR_SNAPSHOT_TRANSPORT_SOURCE:-$ROOT/src/sbom_release.sh}" || exit
    declare -f _sbr_run _sbr_download _sbr_asset_digest _sbom_hash _sbom_log
) || exit 1
eval "$production_transport"
new_case parallel-queue
MODE=parallel-queue
expect 'two transfer slots complete a shared-barrier release' 0 fetch --resume --jobs 2
check 'workers overlap, respect the cap, and refill a slot before the first asset completes' jq -e \
    '.peak==2 and .active==[] and
     ([.events[]|select(.event=="start")|.asset]|sort)==["1","2","3"] and
     ([.events[]|(.asset+":"+.event)] | index("3:start") < index("1:end"))' "$CASE/parallel.json"
check 'parallel acquisition preserves complete payload counts' jq -e \
    '.authenticated and .acquisition=={reused_payloads:0,downloaded_payloads:3}' "$CASE/result"
check 'parallel collection retains exact signed bytes' cmp -s "$CASE/remote/3" "$CASE/snapshot/artifacts/demo-windows.exe"
MODE=normal
: > "$CASE/calls"
expect 'completed resume permits a different scheduling bound' 0 fetch --resume --jobs 3
check 'changed scheduling does not redownload completed assets' jq -e \
    '.acquisition=={reused_payloads:3,downloaded_payloads:0}' "$CASE/result"
check 'completed parallel resume requests only proof documents' bash -c \
    '[[ $(grep -c "^download " "$1") == 2 ]] && ! grep -Eq "^download [123]$" "$1"' _ "$CASE/calls"

new_case parallel-verify
expect 'remote verification uses the same bounded acquisition path' 0 policy slsa_verify_remote --jobs 2
check 'parallel remote verification returns a complete authenticated verdict' jq -e \
    '.kind=="dsr-slsa-remote-verification" and .authenticated and .artifact_count==3' "$CASE/result"
check 'parallel verification does not publish a snapshot' test ! -e "$CASE/snapshot"

new_case parallel-preflight
jq 'map(if .id==3 then .size+=1 else . end)' "$CASE/inventory.json" > "$CASE/bad-inventory"
cp "$CASE/bad-inventory" "$CASE/inventory.json"
expect 'parallel acquisition preflights every advertised asset before starting workers' 7 fetch --resume --jobs 3
check 'invalid final asset starts no payload worker' bash -c '! grep -Eq "^download [123]$" "$1"' _ "$CASE/calls"

new_case parallel-cache
MODE=late-failure
expect 'a failed parallel fetch retains earlier completed assets' 8 fetch --resume --jobs 2
check 'failed parallel fetch publishes no complete snapshot' test ! -e "$CASE/snapshot"
MODE=normal
retained_payloads=("$CASE/snapshot.partial/artifacts/"*)
check 'failed parallel fetch keeps at least one fully completed payload' test -f "${retained_payloads[0]}"
chmod 600 "${retained_payloads[0]}" || exit 1
printf corrupt >> "${retained_payloads[0]}" || exit 1
: > "$CASE/calls"
expect 'parallel resume checks every retained payload before requesting a missing body' 7 fetch --resume --jobs 3
check 'corrupt retained bytes start no parallel payload workers' bash -c '! grep -Eq "^download [123]$" "$1"' _ "$CASE/calls"

for scenario in failure cancel launch-window; do
    new_case "parallel-$scenario"
    (
        export CASE MODE="parallel-$scenario"
        [[ "$scenario" != launch-window ]] || MODE=parallel-cancel
        export -f trace _sbr_require _sbr_run _sbr_context _sbr_inventory _sbr_named_asset _sbr_payload_names \
            _sbr_asset_digest _sbr_inventory_sha256 _sbr_download gh_download_release_asset parallel_body _sbom_hash _sbom_log
        python3 - "$ROOT/src/slsa_remote.sh" "$CASE" "$PIN" "$scenario" <<'PY'
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

module, case, pin, scenario = sys.argv[1], Path(sys.argv[2]), sys.argv[3], sys.argv[4]
arguments = ["--resume", "--jobs", "2", "--output-dir", str(case / "snapshot"),
           "--repo", "owner/demo", "--tag", "v1.2.3", "--sha", pin, "--builder", "dsr:test",
           "--targets", "linux/amd64,windows/arm64", "--public-key", str(case / "key.pub")]
command = ["bash", module, "fetch-release", *arguments]
if scenario == "launch-window":
    # Freeze the old nested adapter after its transport fork but before its
    # cleanup trap. A correct pool reuses its existing anchor and never enters
    # this window for payloads; proof downloads still use the ordinary adapter.
    driver = r"""source "$1" || exit; shift
set -T
trap 'if [[ "$BASH_COMMAND" == "worker=\$!" && "${1-}" == gh_download_release_asset && "${3-}" =~ ^[123]$ ]]; then : > "$CASE/nested-window"; command sleep 8; fi' DEBUG
slsa_fetch_release "$@"
"""
    command = ["bash", "-c", driver, "snapshot-launch-window", module, *arguments]

with (case / "owned.stdout").open("wb") as out, (case / "owned.stderr").open("wb") as err:
    process = subprocess.Popen(command, stdout=out, stderr=err, start_new_session=True)
    try:
        if scenario != "failure":
            deadline = time.monotonic() + 12
            blocked = case / ("blocked-2" if scenario == "launch-window" else "blocked-3")
            while not blocked.exists():
                assert process.poll() is None and time.monotonic() < deadline, "parallel fetch never reached its blocked transport"
                time.sleep(.02)
            if scenario == "cancel":
                assert (case / "snapshot.partial/artifacts/demo-linux").is_file(), "completed progress was not retained"
            heartbeat = case / "resistant-2.heartbeat"
            before_beat = heartbeat.read_bytes()
            time.sleep(.2)
            assert heartbeat.read_bytes() != before_beat, "cancellation fixture never produced a live resistant writer"
            before = (case / "calls").read_bytes()
            competing = subprocess.run(command, capture_output=True, timeout=8)
            assert competing.returncode == 2 and not competing.stdout, "competing resume escaped the destination lock"
            assert before == (case / "calls").read_bytes(), "competing resume started remote work"
            os.killpg(process.pid, signal.SIGTERM)
        code = process.wait(timeout=15)
        assert code in ((8,) if scenario == "failure" else (-signal.SIGTERM, 5, 128 + signal.SIGTERM)), "unexpected parallel outcome: " + str(code)
        assert not (case / "owned.stdout").read_bytes(), "incomplete parallel fetch emitted success"
        assert not (case / "snapshot").exists(), "incomplete release became visible"
        if scenario == "failure":
            assert not (case / "started-3").exists(), "failed worker allowed another queued download to start"
        markers = list(case.glob("resistant-*.pid"))
        assert markers, "cancellation test did not create resistant descendants"
        deadline = time.monotonic() + 6
        while True:
            with (case / "snapshot.lock").open("rb") as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    beats = {p: p.with_suffix(".heartbeat").read_bytes() for p in markers}
                    time.sleep(.2)
                    assert all(p.with_suffix(".heartbeat").read_bytes() == beat for p, beat in beats.items()), "owned descendants kept writing after destination custody was released"
                    break
                except BlockingIOError:
                    assert time.monotonic() < deadline, "owned descendants retained destination custody"
            time.sleep(.02)
        assert not any(p.name.endswith(".exe") for p in (case / "snapshot.partial/artifacts").iterdir()), "interrupted body entered checkpoint"
        (case / "settled.json").write_text(json.dumps(dict(exit_code=code, descendants=len(markers),
                                                        legacy_fork_window=(case / "nested-window").exists())))
    finally:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
        # A broken implementation can escape into a separate transport group.
        # Stop only freshly created fixture writers proven still active by their
        # private heartbeat; never select an unrelated process via a census.
        beats = {p: p.read_bytes() for p in case.glob("resistant-*.heartbeat")}
        time.sleep(.15)
        for p, beat in beats.items():
            if p.read_bytes() != beat:
                try:
                    os.killpg(int(p.with_suffix(".group").read_text()), signal.SIGKILL)
                except ProcessLookupError:
                    pass
PY
    ) > "$CASE/owned-test.log" 2>&1
    CODE=$?
    check "parallel $scenario settles owned process groups before releasing custody" test "$CODE" = 0
    [[ "$CODE" == 0 ]] || cat "$CASE/owned-test.log" "$CASE/owned.stderr"
    MODE=normal
    : > "$CASE/calls"
    expect "same release resumes after parallel $scenario" 0 fetch --resume --jobs 2
    check 'recovery produces every authenticated asset' jq -e \
        '.authenticated and .acquisition.reused_payloads+.acquisition.downloaded_payloads==3' "$CASE/result"
done

new_case parallel-options
for value in 0 33 -1 01 1.5 invalid; do
    expect "invalid parallelism $value is rejected" 4 fetch --jobs "$value"
done
expect 'duplicate parallelism is rejected' 4 fetch --jobs 2 --jobs 3
expect 'offline verification rejects remote scheduling options' 4 policy slsa_verify_snapshot "$CASE/assets" --jobs 2
expect 'publishing rejects remote scheduling options' 4 policy slsa_publish_release "$CASE/remote/4" "$CASE/assets" --jobs 2
check 'invalid concurrency options perform no remote work' test ! -s "$CASE/calls"
expect 'download executor must be a declared function' 4 _sbr_download owner/demo \
    "$(jq -c '.[]|select(.id==1)' "$CASE/inventory.json")" "$(_slsa_sha256 "$CASE/remote/1")" "$CASE" false bash
check 'internal pool transport cannot be selected outside its owned scope' bash -c \
    'source "$1"; ! declare -F _slr_pool_transport >/dev/null' _ "$ROOT/src/slsa_remote.sh"
fi
printf '\nSLSA release snapshots: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
