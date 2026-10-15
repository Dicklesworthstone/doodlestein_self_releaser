#!/usr/bin/env bash
# Production collector + manifest + final-byte gate. Compiler/host metadata is
# a fixture; these payloads test custody/naming, not native execution or ABI.
# shellcheck disable=SC1090,SC2034 # Extracted production functions consume fixture variables through Bash dynamic scope.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORK=$(mktemp -d) || exit 1
printf 'Fixtures retained: %s\n' "$WORK"
source "$ROOT/src/act_runner.sh"
# Load the actual nested collector and publisher naming functions without
# invoking CLI startup, authentication, compilers or any network mutation.
source <(awk '
    /^    (_build_target_suffix_name|_build_collect_artifact_file|_build_verify_collected_manifest_coverage|_release_artifact_candidate_names)\(\)/ {copy=1}
    copy {print}
    copy && /^    }/ {copy=0}
' "$ROOT/dsr")
log_info() { :; }; log_warn() { :; }; log_error() { printf '%s\n' "$*" >&2; }
config_get_release_contract_json() { echo null; }
config_validate_target_triples() { return 0; }
config_get_target_triples_json() { echo '[]'; }
artifact_naming_artifact_variant() {
    case "$2/$3" in
        linux/amd64) printf 'x86_64-unknown-linux-gnu\tprimary\n' ;;
        linux/arm64) printf 'aarch64-unknown-linux-gnu\tprimary\n' ;;
        darwin/amd64) printf 'x86_64-apple-darwin\tprimary\n' ;;
        darwin/arm64) printf 'aarch64-apple-darwin\tprimary\n' ;;
        *) return 4 ;;
    esac
}
tool_name=sbh
version=1.2.3
local_path="$WORK"
build_release_contract_enabled=false
resume=false
collect_failed=false
collected_count=0
collision_count=0
declare -A collected_names=()
declare -a artifact_rename_pairs=()
output_dir="$WORK/output"
mkdir -p "$output_dir"
targets='[]'
for target in linux/amd64 linux/arm64 darwin/amd64 darwin/arm64; do
    dir="$WORK/${target/\//_}"
    mkdir -p "$dir"
    # Two raw executables with identical basenames across all four workers,
    # plus one archive with a repeated basename. No source is overwritten.
    printf 'executable fixture sbh %s\n' "$target" > "$dir/sbh"
    printf 'executable fixture inspector %s\n' "$target" > "$dir/inspector"
    tar -cJf "$dir/bundle.tar.xz" -C "$dir" sbh inspector || exit 1
    for name in sbh inspector bundle.tar.xz; do
        _build_collect_artifact_file "$dir/$name" "$target" '' true || exit 1
    done
    targets=$(jq -c --arg target "$target" --arg dir "$dir" '. + [{
        platform:$target,method:"native",status:"success",host:"fixture",
        artifact_paths:[$dir+"/sbh",$dir+"/inspector",$dir+"/bundle.tar.xz"]}]' <<< "$targets") || exit 1
done
with_receipts='[]'
while IFS= read -r row; do
    receipts=$(_act_result_artifact_receipts "$row") || exit 1
    with_receipts=$(jq -c --argjson row "$row" --argjson receipts "$receipts" \
        '. + [$row + {resume_artifacts:$receipts}]' <<< "$with_receipts") || exit 1
done < <(jq -c '.[]' <<< "$targets")
targets="$with_receipts"
renames=$(printf '%s\n' "${artifact_rename_pairs[@]}" | jq -Rn '
    reduce inputs as $line ({}; ($line|split("\t")) as $p | .[$p[0]]=$p[1])') || exit 1
result=$(jq -nc --argjson targets "$targets" '{tool:"sbh",version:"1.2.3",
    run_id:"12345678-1234-1234-1234-123456789abc",git_sha:("a"*40),git_ref:"v1.2.3",
    status:"success",summary:{total:4,success:4,failed:0},targets:$targets}') || exit 1
manifest="$WORK/manifest.json"
act_generate_manifest "$result" "$manifest" "$renames" || exit 1
_act_verify_collected_manifest "$manifest" "$output_dir" || exit 1
_build_verify_collected_manifest_coverage "$manifest" || exit 1
omitted_manifest="$WORK/omitted-collected.json"
jq 'del(.artifacts[] | select(.name == "sbh_linux_arm64"))' "$manifest" > "$omitted_manifest" || exit 1
# Row-only verification cannot notice an omitted collected payload; the
# independent collection-coverage gate must reject it before sealing.
_act_verify_collected_manifest "$omitted_manifest" "$output_dir" || exit 1
if _build_verify_collected_manifest_coverage "$omitted_manifest"; then
    echo 'FAIL: collected payload omitted from manifest was accepted' >&2
    exit 1
fi
echo 'PASS: final sealing refuses a collected payload omitted from the manifest'
jq -e '.artifacts | length == 12 and
    ([.[]|select(.archive_format=="none")]|length==8) and
    ([.[].target]|unique|length==4)' "$manifest" >/dev/null || exit 1
for target in linux_amd64 linux_arm64 darwin_amd64 darwin_arm64; do
    for binary in sbh inspector; do
        test -s "$output_dir/${binary}_${target}" || exit 1
    done
done
echo 'PASS: all four targets and both raw executables retain final names and bytes'
# Reverse result arrival: retained collection decisions must give exactly the
# same inventory, with no basename deduplication before name resolution.
reversed=$(jq '.targets |= reverse' <<< "$result")
act_generate_manifest "$reversed" "$WORK/reversed.json" "$renames" || exit 1
jq -S '.artifacts|sort_by(.name)' "$manifest" > "$WORK/forward.rows"
jq -S '.artifacts|sort_by(.name)' "$WORK/reversed.json" > "$WORK/reverse.rows"
cmp "$WORK/forward.rows" "$WORK/reverse.rows" || exit 1
echo 'PASS: manifest row order cannot lose a target'
if act_generate_manifest "$result" "$WORK/unsafe.json"; then
    echo 'FAIL: unresolved duplicate basenames were silently accepted' >&2; exit 1
fi
echo 'PASS: unresolved duplicate basenames refuse instead of dropping rows'
missing=$(jq '.targets[0].artifact_paths += ["/nonexistent/dsr-artifact"]' <<< "$result")
if act_generate_manifest "$missing" "$WORK/missing.json" "$renames"; then exit 1; fi
if _build_collect_artifact_file "$WORK/missing" linux/arm64 '' true; then exit 1; fi
echo 'PASS: declared missing artifacts refuse both collection and manifest generation'
wrong_receipt=$(jq '.targets[0].resume_artifacts[0].sha256=("0"*64)' <<< "$result")
if act_generate_manifest "$wrong_receipt" "$WORK/receipt-mismatch.json" "$renames"; then exit 1; fi
echo 'PASS: worker checksum receipt mismatches refuse manifest generation'
cp "$manifest" "$WORK/bad.json"
jq '.artifacts[0].sha256=("0"*64)' "$manifest" > "$WORK/bad.json"
if _act_verify_collected_manifest "$WORK/bad.json" "$output_dir"; then exit 1; fi
jq '.artifacts += [.artifacts[0]]' "$manifest" > "$WORK/duplicate.json"
if _act_verify_collected_manifest "$WORK/duplicate.json" "$output_dir"; then exit 1; fi
echo 'PASS: final byte mismatches and duplicate published names refuse sealing'
for format in none binary; do
    test "$(_release_artifact_candidate_names sbh_darwin_arm64 darwin/arm64 "$format")" = sbh_darwin_arm64 || exit 1
done
echo 'PASS: publication cannot synthesize unmanifested raw names'
# Execute the production checksum-generation block with the resolved upload
# names, rather than reproducing its checksum logic in this test.
source <(printf '_test_generate_checksums() {\n'; awk '
    /^    # === Generate SHA256SUMS/ {section=1}
    section && /^    if \$manifest_exists/ {copy=1}
    copy && /^    # Build upload list/ {exit}
    copy {print}
' "$ROOT/dsr"; printf '}\n')
artifacts_dir="$output_dir"
manifest_file="$manifest"
manifest_exists=true
ordinary_manifest=$(cat "$manifest")
artifact_naming_generate_dual_for_variant() {
    printf '%s\n' '{"versioned":"bundle_linux_arm64.tar.xz","compat":"unlisted.tar.xz"}'
}
test "$(_release_artifact_candidate_names bundle_linux_arm64.tar.xz linux/arm64 tar.xz)" = \
    bundle_linux_arm64.tar.xz || exit 1
echo 'PASS: archive publication also refuses names absent from the signed inventory'
declare -A ordinary_upload_names=()
while IFS= read -r name; do ordinary_upload_names["$name"]="$name"; done < <(jq -r '.artifacts[].name' "$manifest")
log_ok() { :; }
_test_generate_checksums || exit 1
if command -v minisign >/dev/null; then
    source "$ROOT/src/signing.sh"
    minisign -G -W -s "$WORK/key" -p "$WORK/key.pub" > "$WORK/keygen.log" 2>&1 || exit 1
    token=$(sed -n '2p' "$WORK/key.pub")
    signing_sign_exact "$manifest" "$manifest.minisig" "$WORK/key" "$token" \
        'ordinary collection regression' || exit 1
    signing_verify_exact "$manifest" "$manifest.minisig" "$token" || exit 1
    echo 'PASS: production signing authenticates the complete final inventory with Minisign'
else
    echo 'SKIP: native Minisign check (Ed25519 inventory authentication still runs below)'
fi
# Real signed bytes and checksums; this exercises Ed25519 authentication, not
# the Minisign CLI/format (covered by the signing integration suites).
python3 - "$manifest" "$output_dir" "$WORK" <<'PY'
import hashlib, json, pathlib, sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
manifest, output, work = map(pathlib.Path, sys.argv[1:])
rows = json.loads(manifest.read_bytes())["artifacts"]
key = Ed25519PrivateKey.generate()
signature = key.sign(manifest.read_bytes())
key.public_key().verify(signature, manifest.read_bytes())
checksums = output / "SHA256SUMS"
signed = {r["name"]:r["sha256"] for r in rows}
unsigned = dict((line.split("  ",1)[1],line.split("  ",1)[0]) for line in checksums.read_text().splitlines())
actual = {p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in output.iterdir() if p.name != "SHA256SUMS" and not p.name.endswith(".sha256")}
assert actual == unsigned == signed
for name, digest in signed.items():
    assert (output / (name+".sha256")).read_text() == f"{digest}  {name}\n"
print("PASS: final payload namespace, SHA256SUMS and authenticated manifest match exactly")
PY
status=$?
[[ "$status" == 0 ]] || exit "$status"
printf 'post-collection mutation\n' >> "$output_dir/sbh_linux_amd64"
if _act_verify_collected_manifest "$manifest" "$output_dir"; then exit 1; fi
echo 'PASS: actual collected-byte mutation refuses final sealing'
printf 'post-worker mutation\n' >> "$WORK/linux_amd64/sbh"
if act_generate_manifest "$result" "$WORK/source-mutation.json" "$renames"; then exit 1; fi
echo 'PASS: source mutation cannot silently replace frozen worker bytes'
