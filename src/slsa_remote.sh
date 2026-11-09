#!/usr/bin/env bash
# Signed build-manifest provenance at the GitHub release boundary. Reuse the
# existing uncached/immutable-ID transport, never URLs embedded in a statement.
_SLSA_REMOTE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=src/platforms.sh
source "$_SLSA_REMOTE_DIR/platforms.sh" || { return 3 2>/dev/null || exit 3; }
if ! declare -F dsr_lock_fd >/dev/null || ! declare -F _dsr_timeout_group >/dev/null; then
    # shellcheck source=src/guardrails.sh
    source "$_SLSA_REMOTE_DIR/guardrails.sh" || { return 3 2>/dev/null || exit 3; }
fi

_slr_require() {
    # Public SLSA functions may be exported by a parent shell without their
    # private dependencies. A new CLI must still load a complete implementation.
    if ! declare -F slsa_verify_release >/dev/null || ! declare -F _slsa_sha256 >/dev/null ||
       ! declare -F _slsa_authenticate >/dev/null; then
        # shellcheck source=src/slsa.sh
        source "$_SLSA_REMOTE_DIR/slsa.sh" || return 3
    fi
    if [[ "${1:-remote}" != local ]] && ! declare -F _sbr_context >/dev/null; then
        # shellcheck source=src/sbom_release.sh
        source "$_SLSA_REMOTE_DIR/sbom_release.sh" || return 3
    fi
    command -v jq >/dev/null && command -v minisign >/dev/null || return 3
}

# Independently selected release contents, not policy copied from a statement.
# Canonicalize before any network operation and retain both the selected bytes
# and semantic identity. Duplicate JSON keys and linked/special files fail.
_slr_read_contract() {
    command -v python3 >/dev/null || return 3
    _slr_path "$1" || return 4
    python3 - "$1" "$2" "$(dsr_platform_pattern)" <<'PY'
import hashlib
import json
import os
import re
import stat
import sys

def need(ok, message):
    if not ok:
        raise ValueError(message)

def pairs(items):
    result = {}
    for key, value in items:
        need(key not in result, "duplicate contract key: " + key)
        result[key] = value
    return result

def name(value):
    return isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._+-]{0,127}", value) is not None and ".." not in value

try:
    targets = sys.argv[2].split(",")
    need(targets and len(set(targets)) == len(targets) and all(
        re.fullmatch(sys.argv[3], t) for t in targets), "invalid expected targets")
    with os.fdopen(os.open(sys.argv[1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), "rb") as stream:
        before = os.fstat(stream.fileno())
        need(stat.S_ISREG(before.st_mode) and before.st_size <= 1048576, "invalid or oversized contract file")
        raw = stream.read(1048577)
        after = os.fstat(stream.fileno())
    need(len(raw) <= 1048576 and (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
         (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns), "contract changed while reading")
    value = json.loads(raw.decode("utf-8"), object_pairs_hook=pairs,
                       parse_constant=lambda s: (_ for _ in ()).throw(ValueError("non-finite JSON number")))
    required = {"schema_version", "required_assets"}
    need(isinstance(value, dict) and required <= set(value) <= required | {"required_variants"} and
         type(value["schema_version"]) is int and value["schema_version"] == 1, "invalid release contract")
    assets = value["required_assets"]
    need(isinstance(assets, list) and 1 <= len(assets) <= 256, "expected 1..256 required assets")
    for asset in assets:
        fields = {"name", "target", "archive_format"}
        need(isinstance(asset, dict) and fields <= set(asset) <= fields | {"target_triple"} and name(asset["name"]) and
             isinstance(asset["target"], str) and (asset["target"] in targets or asset["target"] == "additional") and
             isinstance(asset["archive_format"], str) and asset["archive_format"] in ("tar.gz", "tar.xz", "zip", "binary", "none"),
             "invalid required asset")
        need("target_triple" not in asset or name(asset["target_triple"]), "invalid required compiler identity")
        need(asset["target"] != "additional" or "target_triple" not in asset,
             "shared assets cannot carry a compiler identity")
    need(len({a["name"].lower() for a in assets}) == len(assets), "colliding required asset names")
    platform_assets = [a for a in assets if a["target"] != "additional"]
    need({a["target"] for a in platform_assets} == set(targets), "asset contract must cover the complete target matrix")
    if "required_variants" in value:
        variants = value["required_variants"]
        need(isinstance(variants, list) and 1 <= len(variants) <= 256, "expected 1..256 required variants")
        for variant in variants:
            need(isinstance(variant, dict) and set(variant) == {"target", "target_triple"} and
                 isinstance(variant["target"], str) and variant["target"] in targets and name(variant["target_triple"]),
                 "invalid required variant")
        identities = {(v["target"], v["target_triple"]) for v in variants}
        need(len(identities) == len(variants) and all("target_triple" in a for a in platform_assets) and
             identities == {(a["target"], a["target_triple"]) for a in platform_assets}, "assets must cover each required variant exactly")
        variants.sort(key=lambda v: (v["target"], v["target_triple"]))
    assets.sort(key=lambda a: a["name"])
    encoded = (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n").encode()
    print(json.dumps(dict(kind="dsr-slsa-release-contract", authenticated=False, contract=value,
                         contract_sha256=hashlib.sha256(encoded).hexdigest(), input_sha256=hashlib.sha256(raw).hexdigest()),
                     sort_keys=True, separators=(",", ":")))
except (OSError, ValueError, TypeError, KeyError, RecursionError) as error:
    print("[slsa] Invalid release contract: " + str(error), file=sys.stderr)
    sys.exit(4)
PY
}

# Authentication precedes consumption of any statement-selected payload name.
# Require the caller's target matrix as well as signer/builder/source identity:
# a correctly signed subset must not redefine a complete multi-platform release.
_slr_policy() {
    local proof="$1" signature="$2" key="$3" policy="$4"
    _slsa_authenticate "$proof" "$key" "$signature" || return $?
    _slsa_validate "$proof" || return 7
    jq -es --slurpfile policy "$policy" '
        def text: type=="string" and length>0 and (test("[\u0000-\u001f\u007f]")|not);
        def hash: type=="string" and length==64 and test("^[0-9a-f]{64}$");
        def name: text and test("^[A-Za-z0-9][A-Za-z0-9._+-]*$") and (contains("..")|not);
        $policy[0] as $p | length==1 and (.[0] | . as $s |
        .predicateType=="https://slsa.dev/provenance/v1" and
        .predicate.buildDefinition.buildType=="https://github.com/Dicklesworthstone/doodlestein_self_releaser/buildtype/manifest-v1" and
        .predicate.runDetails.builder.id==$p.builder and
        (.predicate.runDetails.metadata.invocationId|text) and
        ($p.invocation_id=="" or .predicate.runDetails.metadata.invocationId==$p.invocation_id) and
        .predicate.buildDefinition.externalParameters.repository==("https://github.com/"+$p.repo) and
        .predicate.buildDefinition.externalParameters.version==$p.tag and
        (.predicate.buildDefinition.externalParameters.targets|sort)==$p.targets and
        ([.predicate.buildDefinition.resolvedDependencies[]? |
          select(.uri==("https://github.com/"+$p.repo))] |
            length==1 and .[0].digest.gitCommit==$p.source_sha) and
        .dsr_evidence.kind=="build-manifest" and (.dsr_evidence.manifest_sha256|hash) and
        ($p.manifest_sha256=="" or .dsr_evidence.manifest_sha256==$p.manifest_sha256) and
        ([.predicate.runDetails.byproducts[]? | select(.name=="dsr-build-manifest")] |
            length==1 and .[0].digest.sha256==$s.dsr_evidence.manifest_sha256) and
        (.dsr_evidence.artifacts|type=="array" and length>0 and all(.[];
            (.name|name) and (.target|type=="string") and
            (if .target=="additional" then (has("target_triple")|not)
             else (.target as $t | $p.targets | index($t)!=null) end) and
            (.size_bytes|type=="number" and .>0 and .<=9007199254740991 and .==floor)) and
            (map(.name)|sort)==($s.subject|map(.name)|sort) and
            (map(select(.target!="additional")|.target)|unique|sort)==$p.targets) and
        (if $p|has("release_contract") then
            $p.release_contract as $c |
            # A valid signature and complete platforms cannot authorize a
            # missing companion, a swapped ABI filename or a changed format.
            (.dsr_evidence.artifacts|map({name,target,archive_format})|sort_by(.name))==
                ($c.required_assets|map({name,target,archive_format})|sort_by(.name)) and
            all($c.required_assets[]; . as $a |
                (has("target_triple")|not) or any($s.dsr_evidence.artifacts[];
                    .name==$a.name and .target_triple==$a.target_triple)) and
            (if $c|has("required_variants") then
                ([.dsr_evidence.artifacts[]|select(.target!="additional")|{target,target_triple}]|unique|sort_by(.target,.target_triple))==$c.required_variants
             else true end)
         else true end))
    ' "$proof" >/dev/null 2>&1 || { _slsa_log 'Signed statement differs from the selected release policy'; return 7; }
}

# The signature is still untrusted at this stage. Restrict body size and digest
# syntax, download by numeric ID, then authenticate the exact downloaded bytes.
_slr_document() {
    local repo="$1" asset="$2" work="$3" limit="$4" dir body size hash expected rc=0
    jq -e --argjson limit "$limit" '
        .state=="uploaded" and (.id|type=="number" and .>0 and .==floor) and
        (.size|type=="number" and .>0 and .<=$limit and .==floor) and
        (.digest==null or .digest=="" or (.digest|type=="string" and length==71 and test("^sha256:[0-9a-f]{64}$")))
    ' <<< "$asset" >/dev/null || return 7
    dir=$(mktemp -d "$work/proof.XXXXXXXX") || return 1
    body="$dir/body"
    _sbr_run gh_download_release_asset "$repo" "$(jq -r .id <<< "$asset")" "$body" \
        "$(jq -r .size <<< "$asset")" >/dev/null || rc=$?
    case "$rc" in 0) ;; 3|5) return "$rc" ;; 63) return 7 ;; *) return 8 ;; esac
    hash=$(_slsa_sha256 "$body") || return $?
    size=$(wc -c < "$body") || return 1
    expected=$(jq -r '.digest // ""' <<< "$asset") || return 1
    [[ "${size//[[:space:]]/}" == "$(jq -r .size <<< "$asset")" &&
       ( -z "$expected" || "$expected" == "sha256:$hash" ) ]] || return 7
    printf '%s\n' "$body"
}

# A resumable fetch retains only complete authenticated payloads. The checkpoint
# is bound to independently supplied policy/key bytes and one observed release
# generation; it never selects a different statement, inventory or output path.
# Scratch downloads stay outside it until their entire signed digest is checked.
_slr_fetch_checkpoint() {
    local operation="$1" cache="$2" selection="$3" proof="$4"
    _slr_path "$cache" && _slr_path "$cache/selection.json" && _slr_path "$cache/artifacts" || return 7
    python3 - "$operation" "$cache" "$selection" "$proof" "${5:-}" "${6:-}" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import stat
import sys
import tempfile

operation, selected, selection, proof, body, name = sys.argv[1:]
cache = Path(selected)

def need(ok, message):
    if not ok:
        raise ValueError(message)

def held_bytes(path, expected=None):
    before = path.lstat()
    need(stat.S_ISREG(before.st_mode) and (expected is not None or before.st_size <= 67108864),
         "checkpoint input is not a regular file or exceeds its size limit")
    identity = lambda s: (s.st_dev, s.st_ino, s.st_mode, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    h, chunks = hashlib.sha256(), []
    size = 0
    with os.fdopen(fd, "rb") as stream:
        need(identity(os.fstat(stream.fileno())) == identity(before), "checkpoint input changed before reading")
        for block in iter(lambda: stream.read(1048576), b""):
            size += len(block)
            need(size <= (expected["size_bytes"] if expected is not None else 67108864),
                 "checkpoint input grew beyond its selected size")
            h.update(block)
            if expected is None:
                chunks.append(block)
        need(identity(os.fstat(stream.fileno())) == identity(before) == identity(path.lstat()),
             "checkpoint input changed while reading")
    if expected is not None:
        need(before.st_size == expected["size_bytes"] and h.hexdigest() == expected["sha256"],
             "retained payload differs from authenticated bytes: " + path.name)
    return b"".join(chunks)

def sync_dir(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)

try:
    selection_bytes = held_bytes(Path(selection))
    frozen = json.loads(selection_bytes)
    statement = json.loads(held_bytes(Path(proof)))
    hashes = {a["name"]: a["digest"]["sha256"] for a in statement["subject"]}
    records = {a["name"]: dict(a, sha256=hashes[a["name"]]) for a in statement["dsr_evidence"]["artifacts"]}
    need(len(records) <= 256 and len({n.lower() for n in records}) == len(records) and
         all(len(n) <= 128 for n in records), "signed inventory exceeds snapshot bounds")
    lock = Path(frozen["output"] + ".lock")
    held, named = os.fstat(9), lock.lstat()
    need(stat.S_ISREG(named.st_mode) and (held.st_dev, held.st_ino) == (named.st_dev, named.st_ino),
         "fetch checkpoint lock changed")
    if operation == "prepare" and not cache.exists():
        stage = Path(tempfile.mkdtemp(prefix="checkpoint-", dir=Path(selection).parent))
        (stage / "artifacts").mkdir(mode=0o700)
        with (stage / "selection.json").open("xb") as stream:
            stream.write(selection_bytes)
            stream.flush()
            os.fchmod(stream.fileno(), 0o400)
            os.fsync(stream.fileno())
        sync_dir(stage / "artifacts")
        sync_dir(stage)
        need(not os.path.lexists(cache), "fetch checkpoint appeared during initialization")
        os.rename(stage, cache)
        sync_dir(cache.parent)
    need(cache.is_dir() and not cache.is_symlink() and
         {p.name for p in cache.iterdir()} == {"selection.json", "artifacts"}, "invalid fetch checkpoint namespace")
    need(held_bytes(cache / "selection.json") == selection_bytes, "fetch policy or remote release generation changed")
    payloads = cache / "artifacts"
    need(payloads.is_dir() and not payloads.is_symlink(), "invalid retained payload directory")
    for path in payloads.iterdir():
        need(path.name in records and stat.S_ISREG(path.lstat().st_mode), "unexpected retained payload: " + path.name)
        if operation == "prepare":
            held_bytes(path, records[path.name])
    if operation == "commit":
        need(name in records and not os.path.lexists(payloads / name), "retained payload is already occupied")
        source = Path(body)
        held_bytes(source, records[name])
        fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            os.fchmod(fd, 0o400)
            os.fsync(fd)
        finally:
            os.close(fd)
        # Exclusive hardlink publication keeps complete bytes atomic without
        # another multi-gigabyte copy. Both paths are private fetch staging.
        os.link(source, payloads / name, follow_symlinks=False)
        sync_dir(payloads)
    else:
        need(operation in ("prepare", "check"), "invalid fetch checkpoint operation")
except (OSError, ValueError, TypeError, KeyError) as error:
    print("[slsa] Cannot resume release fetch: " + str(error), file=sys.stderr)
    sys.exit(7)
PY
}

# A bounded set of independently supervised transfers. The existing timeout
# anchor owns each process group until its control channel closes and the group
# is drained. Only this coordinator publishes completed bodies into the fetch
# checkpoint; workers cannot race its inventory checks or expose partial files.
_slr_parallel_payloads() (
    local repo="$1" inventory="$2" rows="$3" work="$4" cache="$5" jobs="$6" proof="$7"
    local row name asset hash body pool="$4/transfers" reused=0 downloaded=0
    local next=0 active=0 index pid descriptor input_fd output_fd message status running ready
    local cancelled=false launch_pending=false
    local -a names=() assets=() hashes=() pids=() readers=() writers=()
    command -v mkfifo >/dev/null && command -v sleep >/dev/null || return 3
    [[ "${SBOM_REMOTE_TIMEOUT:-900}" =~ ^[1-9][0-9]{0,4}$ ]] || return 4
    mkdir "$pool" || return 1

    _slr_pool_drain() {
        local slot fd
        # Close every lifetime channel before waiting: all owned groups begin
        # cancellation together, rather than one grace period per transfer.
        for slot in "${!writers[@]}"; do
            fd=${writers[$slot]}
            eval "exec ${fd}>&-"
            unset 'writers[slot]'
        done
        for slot in "${!pids[@]}"; do
            wait "${pids[$slot]}" 2>/dev/null || true
            unset 'pids[slot]'
        done
        for slot in "${!readers[@]}"; do
            fd=${readers[$slot]}
            eval "exec ${fd}<&-"
            unset 'readers[slot]'
        done
    }
    _slr_pool_cancel() {
        cancelled=true
        # Do not lose ownership in the fork-to-$! assignment window.
        $launch_pending || exit 5
    }
    _slr_pool_fd() {
        local candidate
        for ((candidate=10; candidate<256; candidate++)); do
            if { : <&"$candidate"; } 2>/dev/null; then continue; fi
            eval "exec ${candidate}<>/dev/null" || return 1
            descriptor=$candidate
            return 0
        done
        _slsa_log 'No file descriptor available for parallel release acquisition'
        return 3
    }
    _slr_pool_transport() {
        # This function exists only in the pool's fork. Its caller must be the
        # command inside the selected live timeout anchor, not an environment
        # request to omit supervision. Avoid _sbr_run's separate nested groups:
        # the outer anchor already owns this whole download and its deadline.
        [[ "${_slr_transfer_anchor:-}" =~ ^[1-9][0-9]*$ &&
           "${group_pid:-}" == "$_slr_transfer_anchor" && "$BASHPID" != "$group_pid" ]] || return 4
        local transport_status=0
        "$@" || transport_status=$?
        ((transport_status < 128)) || transport_status=5
        return "$transport_status"
    }
    trap '_slr_pool_drain' EXIT
    trap '_slr_pool_cancel' HUP INT TERM PIPE
    # Scope job control to this subshell. Each background anchor has a distinct
    # group; its helper turns job control off for the command it supervises.
    set -m

    while IFS= read -r row; do
        name=$(jq -r .name <<< "$row") || return 1
        if [[ -n "$cache" && -e "$cache/artifacts/$name" ]]; then
            ln -- "$cache/artifacts/$name" "$work/payloads/$name" || return 1
            reused=$((reused+1))
            continue
        fi
        asset=$(_sbr_named_asset "$inventory" "$name") || return $?
        hash=$(jq -r .sha256 <<< "$row") || return 1
        names+=("$name"); assets+=("$asset"); hashes+=("$hash")
    done <<< "$rows"

    while ((next < ${#names[@]} || active > 0)); do
        while ((next < ${#names[@]} && active < jobs)); do
            index=$next
            mkfifo "$pool/$index.control" "$pool/$index.result" || return 1
            _slr_pool_fd || return $?; writers[$index]=$descriptor
            eval "exec ${descriptor}<>\"\$pool/\$index.control\"" || return 1
            _slr_pool_fd || return $?; readers[$index]=$descriptor
            eval "exec ${descriptor}<>\"\$pool/\$index.result\"" || return 1
            _slr_pool_fd || return $?; input_fd=$descriptor
            eval "exec ${input_fd}</dev/null" || return 1
            _slr_pool_fd || return $?; output_fd=$descriptor
            eval "exec ${output_fd}>\"\$pool/\$index.body\"" || return 1
            launch_pending=true
            (
                local _slr_transfer_anchor=$BASHPID
                # The anchor keeps only directional FIFO ends on stdin/stdout.
                # No worker may retain another worker's lifetime write end.
                for descriptor in "${writers[@]}" "${readers[@]}"; do
                    eval "exec ${descriptor}>&-"
                done
                _dsr_timeout_group "$input_fd" "$output_fd" '' "${SBOM_REMOTE_TIMEOUT:-900}" \
                    _sbr_download "$repo" "${assets[$index]}" "${hashes[$index]}" "$work" false _slr_pool_transport
            ) < "$pool/$index.control" > "$pool/$index.result" &
            pids[$index]=$!
            launch_pending=false
            eval "exec ${input_fd}<&- ${output_fd}>&-"
            $cancelled && return 5
            printf 'start\n' >&"${writers[$index]}" || return 1
            next=$((next+1)); active=$((active+1))
        done

        ready=false
        running=$(jobs -pr)
        for index in "${!pids[@]}"; do
            message=''
            if IFS= read -r -t 0 -u "${readers[$index]}"; then
                IFS= read -r -u "${readers[$index]}" message || return 7
                [[ "$message" =~ ^exit:([0-9]{1,3})$ ]] || return 7
                status=$((10#${BASH_REMATCH[1]}))
                ((status <= 255)) || return 7
            else
                # An anchor that exits without its completion message never
                # authorizes an artifact, even if a body file happens to exist.
                pid=${pids[$index]}
                case $'\n'"$running"$'\n' in *$'\n'"$pid"$'\n'*) continue ;; esac
                _slsa_log 'Parallel release transfer ended without a completion result'
                return 7
            fi
            ready=true
            descriptor=${writers[$index]}
            eval "exec ${descriptor}>&-"
            unset 'writers[index]'
            wait "${pids[$index]}" 2>/dev/null || true
            unset 'pids[index]'
            descriptor=${readers[$index]}
            eval "exec ${descriptor}<&-"
            unset 'readers[index]'
            active=$((active-1))
            if ((status != 0)); then
                ((status != 124 && status < 128)) || status=5
                return "$status"
            fi
            body=$(cat "$pool/$index.body") || return 7
            [[ "$body" == "$work/"* && "$body" != *$'\n'* && -f "$body" && ! -L "$body" ]] || return 7
            name=${names[$index]}
            if [[ -n "$cache" ]]; then
                _slr_fetch_checkpoint commit "$cache" "$work/fetch-selection.json" "$proof" "$body" "$name" || return $?
                body="$cache/artifacts/$name"
            fi
            ln -- "$body" "$work/payloads/$name" || return 1
            downloaded=$((downloaded+1))
        done
        # Completion channels avoid ordered waits: a slow first asset cannot
        # prevent another completed payload from being retained or its slot reused.
        $ready || sleep 0.02
    done
    jq -cn --argjson reused "$reused" --argjson downloaded "$downloaded" \
        '{reused_payloads:$reused,downloaded_payloads:$downloaded}' > "$work/acquisition.json"
)

# Always hash downloaded payload bytes, even when GitHub advertises a digest.
# The API digest remains a consistency check; a mismatch never downgrades to
# trusting a different read. No candidate executable is run.
_slr_payloads() {
    local repo="$1" inventory="$2" proof="$3" work="$4" names actual rows row name asset hash body
    local cache="${5:-}" jobs="${6:-1}" reused=0 downloaded=0
    names=$(jq -c '[.subject[].name]|sort' "$proof") || return 7
    actual=$(_sbr_payload_names "$inventory") || return $?
    # The SBOM scanner deliberately excludes LICENSE/text/JSON metadata.
    # Every authenticated subject is a mandatory payload, including a native
    # platform's JSON/NOTICE companions. Add only PRESENT subject names;
    # absent selected files and unlisted binaries still fail the exact set.
    actual=$(printf '%s\n' "$actual" "$inventory" | jq -cse --slurpfile proof "$proof" '
        select(length==2) | .[1] as $inventory |
        .[0] + [$proof[0].subject[] |
                .name as $name | select(any($inventory[]; .name==$name)) | .name] |
        unique | sort') || return 7
    [[ "$names" == "$actual" ]] || { _slsa_log 'Remote payload namespace differs from signed subjects'; return 7; }
    local limit="${SLSA_REMOTE_MAX_PAYLOAD_BYTES:-8589934592}"
    [[ "$limit" =~ ^[1-9][0-9]{0,15}$ ]] || return 4
    jq -e --argjson limit "$limit" '([.dsr_evidence.artifacts[].size_bytes]|add)<=$limit' "$proof" >/dev/null || {
        _slsa_log 'Signed payload set exceeds SLSA_REMOTE_MAX_PAYLOAD_BYTES'; return 7;
    }
    mkdir "$work/payloads" || return 1
    rows=$(jq -c '. as $s | .dsr_evidence.artifacts[] | . as $a |
        .+{sha256:($s.subject[]|select(.name==$a.name)|.digest.sha256)}' "$proof") || return 1
    # Preflight every name/size/digest before any potentially large body read.
    while IFS= read -r row; do
        name=$(jq -r .name <<< "$row") || return 1
        asset=$(_sbr_named_asset "$inventory" "$name") || return $?
        [[ "$(jq -r .size <<< "$asset")" == "$(jq -r .size_bytes <<< "$row")" ]] || return 7
        _sbr_asset_digest "$asset" "$(jq -r .sha256 <<< "$row")" || return $?
    done <<< "$rows"
    if [[ -n "$cache" ]]; then
        # Verify every retained payload before requesting ANY missing body.
        # A corrupt cache is evidence to inspect, never a repair instruction.
        _slr_fetch_checkpoint prepare "$cache" "$work/fetch-selection.json" "$proof" || return $?
    fi
    if ((jobs > 1)); then
        _slr_parallel_payloads "$repo" "$inventory" "$rows" "$work" "$cache" "$jobs" "$proof"
        return $?
    fi
    while IFS= read -r row; do
        name=$(jq -r .name <<< "$row") || return 1
        hash=$(jq -r .sha256 <<< "$row") || return 1
        asset=$(_sbr_named_asset "$inventory" "$name") || return $?
        if [[ -n "$cache" && -e "$cache/artifacts/$name" ]]; then
            body="$cache/artifacts/$name"
            reused=$((reused+1))
        else
            body=$(_sbr_download "$repo" "$asset" "$hash" "$work" false) || return $?
            if [[ -n "$cache" ]]; then
                _slr_fetch_checkpoint commit "$cache" "$work/fetch-selection.json" "$proof" "$body" "$name" || return $?
                body="$cache/artifacts/$name"
            fi
            downloaded=$((downloaded+1))
        fi
        # Private hardlinks avoid doubling temporary storage. Neither pathname
        # aliases the publisher's source files or any caller-owned artifact.
        ln -- "$body" "$work/payloads/$name" || return 1
    done <<< "$rows"
    jq -cn --argjson reused "$reused" --argjson downloaded "$downloaded" \
        '{reused_payloads:$reused,downloaded_payloads:$downloaded}' > "$work/acquisition.json" || return 1
}

_slr_verify_remote() {
    local policy="$1" key="$2" work="$3" repo tag sha builder name context inventory asset signature_asset proof signature
    local proof_hash signature_hash expected final_context final_inventory inventory_hash
    local cache="${5:-}" jobs="${6:-1}" resume_key
    repo=$(jq -r .repo "$policy"); tag=$(jq -r .tag "$policy"); sha=$(jq -r .source_sha "$policy")
    builder=$(jq -r .builder "$policy"); name=$(jq -r .statement_name "$policy")
    context=$(_sbr_context "$repo" "$tag" "$work") || return $?
    [[ "$(jq -r .tag_commit <<< "$context")" == "$sha" ]] || { _slsa_log 'Remote tag moved from the selected commit'; return 7; }
    inventory=$(_sbr_inventory "$repo" "$(jq -r .release.id <<< "$context")" "$work") || return $?
    asset=$(_sbr_named_asset "$inventory" "$name") || return $?
    signature_asset=$(_sbr_named_asset "$inventory" "$name.minisig") || return $?
    proof=$(_slr_document "$repo" "$asset" "$work" "${SBOM_REMOTE_MAX_DOCUMENT_BYTES:-67108864}") || return $?
    signature=$(_slr_document "$repo" "$signature_asset" "$work" 65536) || return $?
    proof_hash=$(_slsa_sha256 "$proof") || return $?
    signature_hash=$(_slsa_sha256 "$signature") || return $?
    expected=$(jq -r .statement_sha256 "$policy") || return 1
    [[ -z "$expected" || "$expected" == "$proof_hash" ]] || return 7
    _slr_policy "$proof" "$signature" "$key" "$policy" || return $?
    if [[ -n "$cache" ]]; then
        resume_key=$(_slsa_sha256 "$key") || return $?
        jq -csS --slurpfile policy "$policy" --arg key "$resume_key" \
            --arg output "${cache%.partial}" --argjson context "$context" \
            --arg proof "$proof_hash" --arg signature "$signature_hash" \
            'if length==1 and (.[0]|type=="array") then .[0] as $inventory |
             {schema_version:1,kind:"dsr-slsa-fetch-checkpoint",output:$output,policy:$policy[0],
              public_key_sha256:$key,context:$context,inventory:$inventory,
              statement_sha256:$proof,signature_sha256:$signature}
             else error("exactly one release inventory required") end' \
            <<< "$inventory" > "$work/fetch-selection.json" || return 1
    fi
    _slr_payloads "$repo" "$inventory" "$proof" "$work" "$cache" "$jobs" || return $?
    slsa_verify_release "$proof" "$work/payloads" --builder "$builder" --public-key "$key" --signature "$signature" \
        --source-repository "https://github.com/$repo" --source-commit "$sha" || return $?
    final_inventory=$(_sbr_inventory "$repo" "$(jq -r .release.id <<< "$context")" "$work") || return $?
    final_context=$(_sbr_context "$repo" "$tag" "$work") || return $?
    [[ "$inventory" == "$final_inventory" && "$context" == "$final_context" &&
       "$(_slsa_sha256 "$proof")" == "$proof_hash" && "$(_slsa_sha256 "$signature")" == "$signature_hash" ]] || {
        _slsa_log 'Release, tag, or provenance assets changed during verification'; return 7;
    }
    [[ -z "$cache" ]] || _slr_fetch_checkpoint check "$cache" "$work/fetch-selection.json" "$proof" || return $?
    inventory_hash=$(_sbr_inventory_sha256 "$inventory" "$work") || return $?
    # A fetch retains exactly the bytes verified above, never another download
    # selected from the receipt. Ordinary verification/publication is unchanged.
    if [[ "${4:-false}" == true ]]; then
        mkdir "$work/snapshot" || return 1
        ln -- "$proof" "$work/snapshot/release.intoto.jsonl" || return 1
        ln -- "$signature" "$work/snapshot/release.intoto.jsonl.minisig" || return 1
        mv -- "$work/payloads" "$work/snapshot/artifacts" || return 1
    fi
    jq -cn --argjson context "$context" --argjson asset "$asset" --argjson signature "$signature_asset" \
        --arg proof_hash "$proof_hash" --arg signature_hash "$signature_hash" --arg inventory_hash "$inventory_hash" \
        --slurpfile policy "$policy" --slurpfile proof "$proof" '
        {schema_version:1,kind:"dsr-slsa-remote-verification",status:"verified",authenticated:true,
         repository:$context.repository,release:$context.release,tag_commit:$context.tag_commit,
         builder:$policy[0].builder,targets:$policy[0].targets,
         statement:{name:$asset.name,asset_id:$asset.id,sha256:$proof_hash},
         signature:{name:$signature.name,asset_id:$signature.id,sha256:$signature_hash},
         build_manifest_sha256:$proof[0].dsr_evidence.manifest_sha256,
         invocation_id:$proof[0].predicate.runDetails.metadata.invocationId,
         artifact_count:($proof[0].subject|length),asset_inventory_sha256:$inventory_hash,
         verification_policy:"trusted-minisign-slsa-v1-all-payload-bytes"} +
         (if $policy[0]|has("release_contract") then
             {release_contract_sha256:$policy[0].release_contract_sha256} else {} end)'
}

# Canonical local selections cannot redirect snapshot reads or publication.
_slr_path() {
    local path="$1" rest component current=''
    [[ "$path" == /* && "$path" != / && "$path" != */ &&
       "$path" != *[[:cntrl:]]* && "$path" != *\\* ]] || return 4
    rest=${path#/}
    while [[ -n "$rest" ]]; do
        component=${rest%%/*}
        [[ -n "$component" && "$component" != . && "$component" != .. ]] || return 4
        current+="/$component"
        [[ ! -L "$current" ]] || return 4
        [[ "$rest" == */* ]] || break
        [[ ! -e "$current" || -d "$current" ]] || return 4
        rest=${rest#*/}
    done
}

_slr_snapshot_names() {
    local root="$1" proof="$2" listing="$3" file name names='[]'
    _slr_path "$root/artifacts" && [[ -d "$root/artifacts" ]] || return 7
    # Include dotfiles in exact-namespace admission; never glob to choose which
    # payloads are trusted. The signed statement chooses the complete set.
    find "$root/artifacts" -mindepth 1 -maxdepth 1 -print0 > "$listing" || return 7
    while IFS= read -r -d '' file; do
        name=${file##*/}
        [[ -f "$file" && ! -L "$file" ]] && _slsa_name "$name" || return 7
        names=$(jq -cn --argjson names "$names" --arg name "$name" '$names+[$name]') || return 1
    done < "$listing"
    jq -en --argjson names "$names" --slurpfile proof "$proof" \
        '($names|sort)==($proof[0].subject|map(.name)|sort)' >/dev/null || return 7
}

# Offline authentication does not inherit trust from download.json or from an
# embedded key/policy. Every invocation supplies its own complete trust policy.
_slr_verify_snapshot() {
    local policy="$1" key="$2" root="$3" work="$4" proof signature proof_hash signature_hash expected file count=0
    _slr_path "$root" && [[ -d "$root" ]] || return 4
    for file in "$root"/* "$root"/.[!.]* "$root"/..?*; do
        [[ -e "$file" || -L "$file" ]] || continue
        case "${file##*/}" in
            artifacts) [[ -d "$file" && ! -L "$file" ]] || return 7 ;;
            release.intoto.jsonl|release.intoto.jsonl.minisig|download.json)
                [[ -f "$file" && ! -L "$file" ]] || return 7 ;;
            *) return 7 ;;
        esac
        count=$((count+1))
    done
    [[ "$count" == 4 ]] || return 7
    proof="$root/release.intoto.jsonl"; signature="$proof.minisig"
    [[ $(wc -c < "$proof") -le 67108864 && $(wc -c < "$signature") -le 65536 ]] || return 7
    proof_hash=$(_slsa_sha256 "$proof") || return $?
    signature_hash=$(_slsa_sha256 "$signature") || return $?
    expected=$(jq -r .statement_sha256 "$policy") || return 1
    [[ -z "$expected" || "$expected" == "$proof_hash" ]] || return 7
    _slr_policy "$proof" "$signature" "$key" "$policy" || return $?
    local limit="${SLSA_REMOTE_MAX_PAYLOAD_BYTES:-8589934592}"
    [[ "$limit" =~ ^[1-9][0-9]{0,15}$ ]] || return 4
    jq -e --argjson limit "$limit" '.dsr_evidence.artifacts |
        length<=256 and (map(.name|ascii_downcase)|unique|length)==length and
        all(.[]; (.name|length<=128) and
            (.archive_format|.=="binary" or .=="none" or .=="tar.gz" or .=="tar.xz" or .=="zip")) and
        (map(.size_bytes)|add)<=$limit' "$proof" >/dev/null || return 7
    _slr_snapshot_names "$root" "$proof" "$work/snapshot-names" || return $?
    slsa_verify_release "$proof" "$root/artifacts" --builder "$(jq -r .builder "$policy")" \
        --public-key "$key" --signature "$signature" \
        --source-repository "https://github.com/$(jq -r .repo "$policy")" \
        --source-commit "$(jq -r .source_sha "$policy")" || return $?
    _slr_snapshot_names "$root" "$proof" "$work/snapshot-names" || return $?
    [[ "$(_slsa_sha256 "$proof")" == "$proof_hash" && "$(_slsa_sha256 "$signature")" == "$signature_hash" ]] || return 7
    jq -cnS --arg proof_hash "$proof_hash" --arg signature_hash "$signature_hash" --slurpfile proof "$proof" '
        $proof[0] as $s | {statement_sha256:$proof_hash,signature_sha256:$signature_hash,
        artifacts:($s.dsr_evidence.artifacts|sort_by(.name)|map(. as $a |
            .+{sha256:($s.subject[]|select(.name==$a.name)|.digest.sha256)}))}' > "$work/snapshot-identity.json" || return 1
    jq -cn --arg root "$root" --arg hash "$(_slsa_sha256 "$work/snapshot-identity.json")" \
        --slurpfile identity "$work/snapshot-identity.json" --slurpfile policy "$policy" --slurpfile proof "$proof" '
        {kind:"dsr-slsa-snapshot-verification",status:"verified",authenticated:true,remote_current:false,
         snapshot:$root,snapshot_sha256:$hash,policy:$policy[0],
         build_manifest_sha256:$proof[0].dsr_evidence.manifest_sha256,
         invocation_id:$proof[0].predicate.runDetails.metadata.invocationId} + $identity[0]'
}

# Present proof names must match the frozen pair before ANY upload. A signature
# without its statement is a conflict, not permission to attach different bytes.
_slr_existing() {
    local repo="$1" inventory="$2" records="$3" work="$4" row asset body
    while IFS= read -r row; do
        asset=$(jq -c --arg name "$(jq -r .name <<< "$row")" '[.[]|select(.name==$name)]' <<< "$inventory") || return 1
        [[ $(jq length <<< "$asset") -le 1 ]] || return 7
        [[ "$asset" != '[]' ]] || continue
        asset=$(jq -c '.[0]' <<< "$asset") || return 1
        [[ $(jq -r .size <<< "$asset") == "$(jq -r .size <<< "$row")" ]] || return 7
        body=$(_sbr_download "$repo" "$asset" "$(jq -r .sha256 <<< "$row")" "$work") || return $?
        [[ "$(_slsa_sha256 "$body")" == "$(jq -r .sha256 <<< "$row")" ]] || return 7
    done < "$records"
}

_slr_publish() {
    local policy="$1" key="$2" work="$3" original_proof="$4" original_signature="$5" root="$6"
    local repo tag sha name context inventory current names row asset receipt file proof_hash signature_hash verify_work
    local uploaded=0
    # One POST per missing name. Reconcile ambiguous outcomes by reading the
    # release on retry, not through the lower-level uploader's automatic POSTs.
    # shellcheck disable=SC2034 # Consumed by gh_upload_asset_named.
    local GH_MAX_RETRIES=1
    repo=$(jq -r .repo "$policy") || return 1
    tag=$(jq -r .tag "$policy") || return 1
    sha=$(jq -r .source_sha "$policy") || return 1
    name=$(jq -r .statement_name "$policy") || return 1
    proof_hash=$(_slsa_sha256 "$work/statement") || return $?
    signature_hash=$(_slsa_sha256 "$work/signature") || return $?
    names=$(jq -cn --arg name "$name" '[$name,($name+".minisig")]') || return 1
    # Freeze document records once; hashes may never be reselected during retry.
    : > "$work/documents.jsonl" || return 1
    for file in statement signature; do
        local remote_name="$name"
        [[ "$file" != signature ]] || remote_name+=.minisig
        jq -cn --arg name "$remote_name" --arg sha "$(_slsa_sha256 "$work/$file")" \
            --arg file "$file" --argjson size "$(wc -c < "$work/$file")" \
            '{name:$name,sha256:$sha,size:$size,file:$file}' >> "$work/documents.jsonl" || return 1
    done
    context=$(_sbr_context "$repo" "$tag" "$work") || return $?
    [[ $(jq -r .tag_commit <<< "$context") == "$sha" ]] || return 7
    inventory=$(_sbr_inventory "$repo" "$(jq -r .release.id <<< "$context")" "$work") || return $?
    if jq -e --arg name "$name" 'any(.[];.name==($name+".minisig")) and all(.[];.name!=$name)' <<< "$inventory" >/dev/null; then
        _slsa_log 'Orphan remote provenance signature'; return 7
    fi
    _slr_existing "$repo" "$inventory" "$work/documents.jsonl" "$work" || return $?
    # All payloads must already exist and match before provenance is attached.
    # This command uploads no binaries, private manifests, keys or local state.
    _slr_payloads "$repo" "$inventory" "$work/statement" "$work" || return $?
    current=$(_sbr_publication_gate "$repo" "$tag" "$context" "$inventory" "$names" "$work") || return $?
    if [[ $(jq -r .release.draft <<< "$context") != true ]] &&
       ! jq -es --argjson names "$names" \
            'length==1 and (.[0]|type=="array") and
             (.[0] as $inventory | all($names[];. as $n|any($inventory[];.name==$n)))' \
            <<< "$current" >/dev/null; then
        _slsa_log 'Missing provenance may only be attached to a draft'; return 4
    fi
    if ! declare -F gh_upload_asset_named >/dev/null; then
        # shellcheck source=src/github.sh
        source "$_SLSA_REMOTE_DIR/github.sh" || return 3
    fi
    while IFS= read -r row; do
        [[ "$(_slsa_sha256 "$original_proof")" == "$proof_hash" &&
           "$(_slsa_sha256 "$original_signature")" == "$signature_hash" ]] || return 7
        _slsa_release_assets "$work/statement" "$root" || return $?
        current=$(_sbr_publication_gate "$repo" "$tag" "$context" "$current" "$names" "$work") || return $?
        _slr_existing "$repo" "$current" "$work/documents.jsonl" "$work" || return $?
        file=$(jq -r .file <<< "$row") || return 1
        asset=$(jq -c --arg name "$(jq -r .name <<< "$row")" '[.[]|select(.name==$name)]' <<< "$current") || return 1
        [[ "$asset" == '[]' ]] || continue
        [[ "$(_slsa_sha256 "$work/$file")" == "$(jq -r .sha256 <<< "$row")" ]] || return 7
        # Upload statement first, detached signature last. A lost transport
        # acknowledgement returns failure; repeating the command reads and
        # verifies occupied names rather than deleting or clobbering them.
        receipt=$(_sbr_run gh_upload_asset_named "$(jq -r .release.upload_url <<< "$context")" \
            "$work/$file" "$(jq -r .name <<< "$row")" application/octet-stream) || return $?
        uploaded=$((uploaded+1))
        jq -es --argjson row "$row" 'length==1 and (.[0]|.name==$row.name and .size==$row.size and
            .state=="uploaded" and (.id|type=="number" and .>0 and .==floor) and
            (.digest==null or .digest=="" or .digest==("sha256:"+$row.sha256)))' <<< "$receipt" >/dev/null || return 7
        current=$(_sbr_publication_gate "$repo" "$tag" "$context" "$current" "$names" "$work") || return $?
        asset=$(_sbr_named_asset "$current" "$(jq -r .name <<< "$row")") || return $?
        [[ $(jq -r .id <<< "$asset") == "$(jq -r .id <<< "$receipt")" ]] || return 7
        _slr_existing "$repo" "$current" "$work/documents.jsonl" "$work" || return $?
    done < "$work/documents.jsonl"
    # Independent final download/signature/payload verification, constrained to
    # the original statement hash and the same complete release observation.
    verify_work=$(mktemp -d "$work/verify.XXXXXXXX") || return 1
    _slr_verify_remote "$policy" "$key" "$verify_work" > "$work/verification.json" || return $?
    jq -e --argjson context "$context" --arg inventory "$(_sbr_inventory_sha256 "$current" "$work")" '
        .repository==$context.repository and .release==$context.release and .tag_commit==$context.tag_commit and
        .asset_inventory_sha256==$inventory' "$work/verification.json" >/dev/null || return 7
    _sbr_publication_gate "$repo" "$tag" "$context" "$current" '[]' "$work" >/dev/null || return $?
    [[ "$(_slsa_sha256 "$original_proof")" == "$proof_hash" &&
       "$(_slsa_sha256 "$original_signature")" == "$signature_hash" &&
       $(jq -r .signature.sha256 "$work/verification.json") == "$signature_hash" ]] || return 7
    _slsa_release_assets "$work/statement" "$root" || return $?
    jq -cn --argjson uploaded "$uploaded" --slurpfile verification "$work/verification.json" \
        '{kind:"dsr-slsa-publication",status:"verified",dry_run:false,upload_attempts:$uploaded,
          verification:$verification[0]}'
}

# Public-GitHub only. Publishing consumes already-signed proof, not a private
# signing key. Both paths withhold stdout until local and remote gates finish.
_slr_execute() (
    set -uo pipefail
    umask 077
    local action="$1" local_proof='' local_signature='' root='' dry=false output=''
    local resume=false cache='' completed=false jobs=1
    shift
    if [[ "$action" == publish ]]; then
        [[ $# -ge 2 ]] || return 4
        local_proof=$1; root=$2; shift 2
        dry="${DRY_RUN:-false}"
        [[ -f "$local_proof" && ! -L "$local_proof" && -d "$root" && ! -L "$root" ]] || return 4
    fi
    if [[ "$action" == snapshot ]]; then
        [[ $# -ge 1 ]] || return 4
        root=$1; shift
        _slr_path "$root" && [[ -d "$root" ]] || return 4
    fi
    local repo='' tag='' sha='' builder='' public='' targets='' name=release.intoto.jsonl
    local expected='' manifest_hash='' invocation='' option work cleanup key_hash matrix
    local contract='' contract_record=null
    local -A seen=()
    while (($#)); do
        option=$1
        [[ -n "$option" && -z "${seen[$option]:-}" ]] || return 4
        seen[$option]=1
        if [[ "$option" == --dry-run && "$action" == publish ]]; then dry=true; shift; continue; fi
        if [[ "$option" == --resume && "$action" == fetch ]]; then resume=true; shift; continue; fi
        [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || return 4
        case "$option" in
            --repo) repo=$2 ;; --tag) tag=$2 ;; --sha) sha=$2 ;; --builder) builder=$2 ;;
            --public-key) public=$2 ;; --targets) targets=$2 ;; --statement-name) name=$2 ;;
            --statement-sha256) expected=$2 ;; --manifest-sha256) manifest_hash=$2 ;; --invocation-id) invocation=$2 ;;
            --release-contract) contract=$2 ;;
            --signature) [[ "$action" == publish ]] || return 4; local_signature=$2 ;;
            --output-dir) [[ "$action" == fetch ]] || return 4; output=$2 ;;
            --jobs) [[ "$action" == fetch || "$action" == verify ]] || return 4; jobs=$2 ;;
            *) return 4 ;;
        esac
        shift 2
    done
    [[ "$jobs" =~ ^([1-9]|[12][0-9]|3[0-2])$ ]] || return 4
    if [[ "$action" == contract ]]; then
        for option in "${!seen[@]}"; do
            case "$option" in --release-contract|--targets) ;; *) return 4 ;; esac
        done
        [[ -n "$contract" && -n "$targets" ]] || return 4
        _slr_read_contract "$contract" "$targets"
        return $?
    fi
    [[ "$repo" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ && "$repo" != *..* &&
       "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([+-][A-Za-z0-9.+-]+)?$ &&
       "$sha" =~ ^[0-9a-f]{40}$ && "$sha" != 0000000000000000000000000000000000000000 &&
       -n "$builder" && "$builder" != *[[:cntrl:]]* && "$invocation" != *[[:cntrl:]]* &&
       "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*\.intoto\.jsonl$ && "$name" != *..* &&
       ( -z "$expected" || "$expected" =~ ^[0-9a-f]{64}$ ) &&
       ( -z "$manifest_hash" || "$manifest_hash" =~ ^[0-9a-f]{64}$ ) &&
       -f "$public" && ! -L "$public" && "$dry" =~ ^(true|false)$ ]] || return 4
    command -v jq >/dev/null || return 3
    matrix=$(jq -cne --arg targets "$targets" --arg platform_pattern "$(dsr_platform_pattern)" '$targets|split(",")|
        if length>0 and all(.[];test($platform_pattern) and (test("[\u0000-\u001f\u007f]")|not)) and (unique|length)==length
        then sort else error("invalid expected targets") end') || return 4
    if [[ -n "$contract" ]]; then
        contract_record=$(_slr_read_contract "$contract" "$targets") || return $?
    fi
    if [[ "$action" == snapshot ]]; then _slr_require local || return $?; else _slr_require || return $?; fi
    if [[ "$action" == fetch ]]; then
        command -v python3 >/dev/null || return 3
        dsr_lock_available || return $?
        _slr_path "$output" && _slr_path "$output.lock" && [[ -d "${output%/*}/" ]] || return 4
        [[ ! -e "$output.lock" || -f "$output.lock" ]] || return 4
        exec 9>> "$output.lock" || return 1
        dsr_lock_fd 9 0 || return 2
        if [[ "$resume" == true ]]; then
            cache="$output.partial"
            _slr_path "$cache" || return 4
            [[ ! -e "$cache" || -d "$cache" ]] || return 2
            if [[ -e "$output" ]]; then
                [[ -d "$output" && -d "$cache" ]] || { _slsa_log 'Completed resume requires its retained fetch checkpoint'; return 2; }
                completed=true
            fi
        else
            [[ ! -e "$output" && ! -L "$output" ]] || { _slsa_log 'Snapshot already exists; use verify-snapshot or its original --resume selection'; return 2; }
            [[ ! -e "$output.partial" && ! -L "$output.partial" ]] || { _slsa_log 'Retained fetch checkpoint requires --resume'; return 2; }
        fi
        work=$(mktemp -d "${output%/*}/.dsr-fetch.XXXXXXXX") || return 1
    else
        work=$(mktemp -d "${TMPDIR:-/tmp}/dsr-slsa-remote.XXXXXXXX") || return 1
    fi
    printf -v cleanup 'rm -rf -- %q' "$work"
    # shellcheck disable=SC2064
    trap "$cleanup" EXIT
    trap 'exit 5' HUP INT TERM
    printf '%s\n' "$contract_record" > "$work/contract.json" || return 1
    [[ $(wc -c < "$public") -le 8192 ]] || return 4
    key_hash=$(_slsa_sha256 "$public") || return $?
    cp -- "$public" "$work/trusted.pub" || return 1
    [[ "$(_slsa_sha256 "$work/trusted.pub")" == "$key_hash" ]] || return 7
    local token
    token=$(sed -n '2{s/\r$//;p;}' "$work/trusted.pub") || return 4
    [[ "$token" =~ ^[A-Za-z0-9+/]{56}$ ]] || return 4
    if [[ "$action" == publish ]]; then
        [[ -n "$local_signature" ]] || local_signature="$local_proof.minisig"
        [[ -f "$local_signature" && ! -L "$local_signature" && $(wc -c < "$local_signature") -le 65536 &&
           $(wc -c < "$local_proof") -le 67108864 ]] || return 4
        local selected_proof selected_signature
        selected_proof=$(_slsa_sha256 "$local_proof") || return $?
        selected_signature=$(_slsa_sha256 "$local_signature") || return $?
        [[ -z "$expected" || "$expected" == "$selected_proof" ]] || return 7
        expected=$selected_proof
        cp -- "$local_proof" "$work/statement" || return 1
        cp -- "$local_signature" "$work/signature" || return 1
        [[ "$(_slsa_sha256 "$work/statement")" == "$selected_proof" &&
           "$(_slsa_sha256 "$work/signature")" == "$selected_signature" ]] || return 7
        chmod 400 "$work/statement" "$work/signature" || return 1
    fi
    jq -cnS --arg repo "$repo" --arg tag "$tag" --arg sha "$sha" --arg builder "$builder" \
        --argjson targets "$matrix" --arg name "$name" --arg expected "$expected" \
        --arg manifest "$manifest_hash" --arg invocation "$invocation" --slurpfile contract "$work/contract.json" \
        '{repo:$repo,tag:$tag,source_sha:$sha,builder:$builder,targets:$targets,statement_name:$name,
          statement_sha256:$expected,manifest_sha256:$manifest,invocation_id:$invocation} +
          (if $contract[0]==null then {} else {release_contract:$contract[0].contract,
              release_contract_sha256:$contract[0].contract_sha256} end)' > "$work/policy.json" || return 1
    if [[ -n "$contract" ]]; then
        [[ "$(_slsa_sha256 "$contract")" == "$(jq -r .input_sha256 "$work/contract.json")" ]] || return 7
    fi
    if [[ "$action" == publish ]]; then
        _slr_policy "$work/statement" "$work/signature" "$work/trusted.pub" "$work/policy.json" || return $?
        _slsa_release_assets "$work/statement" "$root" || return $?
        [[ "$(_slsa_sha256 "$local_proof")" == "$selected_proof" &&
           "$(_slsa_sha256 "$local_signature")" == "$selected_signature" ]] || return 7
        if [[ "$dry" == true ]]; then
            jq -cn --slurpfile policy "$work/policy.json" \
                '{kind:"dsr-slsa-publication",status:"planned",dry_run:true,local_statement_authenticated:true,
                  remote_verified:false,plan:$policy[0]}' > "$work/result.json" || return 1
        else
            _sbr_require || return $?
            _slr_publish "$work/policy.json" "$work/trusted.pub" "$work" "$local_proof" "$local_signature" "$root" \
                > "$work/result.json" || return $?
        fi
    elif [[ "$action" == snapshot ]]; then
        _slr_verify_snapshot "$work/policy.json" "$work/trusted.pub" "$root" "$work" > "$work/result.json" || return $?
    elif [[ "$action" == fetch ]]; then
        if [[ "$completed" == true ]]; then
            # Authenticate the occupied output before any network activity.
            # A saved checkpoint cannot authorize repairing a damaged snapshot.
            _slr_verify_snapshot "$work/policy.json" "$work/trusted.pub" "$output" "$work" > "$work/completed.json" || return $?
        fi
        _sbr_require || return $?
        _slr_verify_remote "$work/policy.json" "$work/trusted.pub" "$work" true "$cache" "$jobs" > "$work/remote.json" || return $?
        cp -- "$work/remote.json" "$work/snapshot/download.json" || return 1
        _slr_verify_snapshot "$work/policy.json" "$work/trusted.pub" "$work/snapshot" "$work" > "$work/local.json" || return $?
        if [[ "$completed" == true ]]; then
            _slr_verify_snapshot "$work/policy.json" "$work/trusted.pub" "$output" "$work" > "$work/completed-after.json" || return $?
            jq -e --slurpfile before "$work/completed.json" --slurpfile current "$work/completed-after.json" \
                '.snapshot_sha256==$before[0].snapshot_sha256 and .snapshot_sha256==$current[0].snapshot_sha256' \
                "$work/local.json" >/dev/null || return 7
        fi
        jq -cn --arg output "$output" --arg cache "$cache" --argjson resumed "$resume" \
            --slurpfile remote "$work/remote.json" --slurpfile local "$work/local.json" --slurpfile acquisition "$work/acquisition.json" \
            '{kind:"dsr-slsa-fetch",status:"verified",authenticated:true,snapshot:$output,
              snapshot_sha256:$local[0].snapshot_sha256,verification:$remote[0]} |
             if $resumed then .+{resumable:true,checkpoint:$cache,acquisition:$acquisition[0]} else . end' > "$work/result.json" || return 1
    else
        _sbr_require || return $?
        _slr_verify_remote "$work/policy.json" "$work/trusted.pub" "$work" false '' "$jobs" > "$work/result.json" || return $?
    fi
    [[ "$(_slsa_sha256 "$public")" == "$key_hash" && "$(_slsa_sha256 "$work/trusted.pub")" == "$key_hash" ]] || return 7
    if [[ -n "$contract" ]]; then
        _slr_path "$contract" &&
            [[ "$(_slsa_sha256 "$contract")" == "$(jq -r .input_sha256 "$work/contract.json")" ]] || return 7
    fi
    if [[ "$action" == fetch ]]; then
        _slr_path "$output" && _slr_path "$output.lock" || return 2
        # The cooperating-writer lock and same-filesystem staging protect the
        # single directory rename. Never adopt or overwrite an occupied path.
        python3 - "$work/snapshot" "$output" "$completed" <<'PY'
import os, stat, sys
source, dest, completed = sys.argv[1:]
held, named = os.fstat(9), os.lstat(dest + ".lock")
if not stat.S_ISREG(named.st_mode) or (held.st_dev, held.st_ino) != (named.st_dev, named.st_ino):
    sys.exit(2)
if completed == "true":
    if not stat.S_ISDIR(os.lstat(dest).st_mode):
        sys.exit(2)
else:
    if os.path.lexists(dest):
        sys.exit(2)
    os.rename(source, dest)
PY
        [[ $? == 0 ]] || return 2
    fi
    cat "$work/result.json"
)

slsa_verify_remote() { _slr_execute verify "$@"; }
slsa_publish_release() { _slr_execute publish "$@"; }
slsa_fetch_release() { _slr_execute fetch "$@"; }
slsa_verify_snapshot() { _slr_execute snapshot "$@"; }
slsa_describe_contract() { _slr_execute contract "$@"; }

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-help}" in
        verify-release) shift; slsa_verify_remote "$@"; exit $? ;;
        publish-release) shift; slsa_publish_release "$@"; exit $? ;;
        fetch-release) shift; slsa_fetch_release "$@"; exit $? ;;
        verify-snapshot) shift; slsa_verify_snapshot "$@"; exit $? ;;
        describe-contract) shift; slsa_describe_contract "$@"; exit $? ;;
        help|--help|-h)
            printf '%s\n' 'Usage: bash src/slsa_remote.sh verify-release --repo OWNER/REPO --tag vVERSION --sha COMMIT' \
                '       --builder ID --public-key FILE --targets linux/amd64,windows/arm64' \
                '       [--statement-name release.intoto.jsonl] [--statement-sha256 SHA256]' \
                '       [--manifest-sha256 SHA256] [--invocation-id ID]' \
                '       [--release-contract FILE] (exact independently selected assets and compiler variants)' \
                '       [--jobs 1..32] (verify-release/fetch-release only; default: 1)' \
                'Publish: publish-release STATEMENT ARTIFACTS (same required policy options)' \
                '         [--signature FILE] [--dry-run]' \
                'Fetch: fetch-release --output-dir DIR [--resume] [--jobs 1..32] (same required policy options)' \
                '       --resume retains complete authenticated payloads and rechecks the same release on retry' \
                'Offline: verify-snapshot DIR (same required policy options; no network)' \
                'Describe: describe-contract --release-contract FILE --targets PLATFORM,... (no authentication or writes)' \
                'Verify performs no writes. Publish adds only a signed statement pair to an existing draft.' ;;
        *) exit 4 ;;
    esac
fi
