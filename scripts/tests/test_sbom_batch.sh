#!/usr/bin/env bash
# Release-set regression tests: real files/SHA256/process contention, explicit
# Syft process fixture. No network, signing keys, or live releases are used.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
MODULE="${SBOM_TEST_MODULE:-$ROOT/src/sbom.sh}"
REAL_SYFT=$(command -v syft || true)
WORK=$(mktemp -d)
trap 'chmod -R u+w "$WORK"; rm -rf -- "$WORK"' EXIT
trap 'exit 5' HUP INT TERM
mkdir -p "$WORK/bin" "$WORK/cases"
export PATH="$WORK/bin:$PATH" SBOM_OUTPUT_DIR=""
cat > "$WORK/bin/syft" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
[[ "$1" != version ]] || { echo 'syft 1.0.0'; exit; }
source_path="" format=spdx
for arg in "$@"; do
    case "$arg" in file:*) source_path="${arg#file:}" ;; cyclonedx-json) format=cyclonedx ;; esac
done
name="${source_path##*/}"
printf '%s\n' "$name" >> "$SBOM_SCAN_LOG"
if [[ "$name" == "${SBOM_FAIL_ASSET:-never}" ]]; then
    printf '{"partial":'; echo "injected scan failure: $name" >&2; exit 17
fi
if [[ "$name" == "${SBOM_CHANGE_AT:-never}" ]]; then
    [[ -z "${SBOM_CHANGE_SOURCE:-}" ]] || printf changed >> "$SBOM_CHANGE_SOURCE"
    [[ -z "${SBOM_ADD_SOURCE:-}" ]] || printf extra > "$SBOM_ADD_SOURCE"
    if [[ -n "${SBOM_CHANGE_PROOF:-}" ]]; then
        jq '.name = "mutated"' "$SBOM_CHANGE_PROOF" > "$SBOM_CHANGE_PROOF.next"
        mv "$SBOM_CHANGE_PROOF.next" "$SBOM_CHANGE_PROOF"
    fi
    [[ -z "${SBOM_CHANGE_PLAN:-}" ]] || printf ' ' >> "$SBOM_CHANGE_PLAN"
fi
digest=$(sha256sum "$source_path"); digest="${digest%% *}"
if [[ "$format" == spdx ]]; then
    jq -nc --arg name "$name${SBOM_NONCE:-}" --arg sha "$digest" '
        {spdxVersion:"SPDX-2.3",dataLicense:"CC0-1.0",SPDXID:"SPDXRef-DOCUMENT",
         name:$name,documentNamespace:("https://example.test/"+$sha),
         creationInfo:{creators:["Tool: syft-fixture"],created:"2026-09-18T00:00:00Z"},packages:[]}'
else
    jq -nc --arg name "$name${SBOM_NONCE:-}" '
        {bomFormat:"CycloneDX",specVersion:"1.6",version:1,
         components:[{type:"application",name:$name}]}'
fi
SH
chmod +x "$WORK/bin/syft"
# shellcheck source=/dev/null
source "$MODULE"
checks=0 failures=0 status=0 CASE="" ART="" output=""
check() {
    local description="$1"
    shift
    checks=$((checks + 1))
    if "$@" >/dev/null 2>&1; then
        printf 'ok %d - %s\n' "$checks" "$description"
    else
        printf 'not ok %d - %s\n' "$checks" "$description"
        failures=$((failures + 1))
    fi
}
new_case() {
    CASE="$WORK/cases/$1"; ART="$CASE/artifacts"
    mkdir -p "$ART"
    printf 'first artifact\n' > "$ART/a.tar.gz"
    printf 'second artifact\n' > "$ART/b.tar.xz"
    export SBOM_SCAN_LOG="$CASE/scans"
    : > "$SBOM_SCAN_LOG"
    unset SBOM_FAIL_ASSET SBOM_NONCE SBOM_CHANGE_AT SBOM_CHANGE_SOURCE SBOM_ADD_SOURCE
    unset SBOM_CHANGE_PROOF SBOM_CHANGE_PLAN
    SBOM_OUTPUT_DIR=""
}
capture() {
    status=0
    "$@" > "$CASE/stdout" 2> "$CASE/stderr" || status=$?
    output=$(cat "$CASE/stdout")
}
nonzero() { [[ "$1" -ne 0 ]]; }
absent() { [[ ! -e "$1" && ! -L "$1" ]]; }
scan_count() { wc -l < "$SBOM_SCAN_LOG"; }
without_syft() {
    command() {
        [[ "${1:-}" != -v || "${2:-}" != syft ]] || return 1
        builtin command "$@"
    }
    "$@"
    local result=$?
    unset -f command
    return "$result"
}
partial() {
    export SBOM_FAIL_ASSET=b.tar.xz
    capture sbom_generate_artifacts "$ART"
    unset SBOM_FAIL_ASSET
}

new_case complete
ln "$ART/a.tar.gz" "$ART/compat-linux-amd64.tar.gz"
printf exe > "$ART/tool.exe"
printf zip > "$ART/tool.zip"
printf raw > "$ART/tool with spaces"
printf checksum > "$ART/SHA256SUMS"
printf metadata > "$ART/manifest.json"
printf provenance > "$ART/a.tar.gz.intoto.jsonl"
printf public-key > "$ART/minisign.pub"
printf signature > "$ART/a.tar.gz.minisig"
mkdir "$ART/unrelated-directory"
capture sbom_generate_artifacts "$ART"
check 'complete mixed-format release succeeds' test "$status" -eq 0
manifest="$ART/sbom-manifest.spdx.json"
check 'batch stdout is the complete manifest path' test "$output" = "$manifest"
check 'all six named artifacts have separate SBOM entries' jq -e '.status == "complete" and (.artifacts | length) == 6' "$manifest"
check 'named hardlink aliases both remain in inventory' jq -e '[.artifacts[].artifact.name] | index("a.tar.gz") != null and index("compat-linux-amd64.tar.gz") != null' "$manifest"
check 'metadata is not scanned as a binary' test "$(scan_count)" -eq 6
check 'each compression variant keeps its own sidecar' test -f "$ART/b.tar.xz.sbom.spdx.json"
check 'later publication cannot overwrite an earlier receipt' jq -e '.artifact.name == "a.tar.gz"' "$ART/a.tar.gz.sbom.spdx.json.dsr.json"
check 'receipt files never share a mutable staging inode' test "$(stat -c %i "$ART/a.tar.gz.sbom.spdx.json.dsr.json")" != "$(stat -c %i "$ART/b.tar.xz.sbom.spdx.json.dsr.json")"
cp "$manifest" "$CASE/manifest.before"
cp "$ART/a.tar.gz.sbom.spdx.json" "$CASE/proof.before"
inode=$(stat -c %i "$ART/a.tar.gz.sbom.spdx.json")
capture without_syft sbom_generate_artifacts "$ART"
check 'complete retry does not require Syft' test "$status" -eq 0
check 'complete retry performs zero new scans' test "$(scan_count)" -eq 6
check 'complete retry preserves manifest bytes' cmp -s "$manifest" "$CASE/manifest.before"
check 'complete retry preserves SBOM bytes' cmp -s "$ART/a.tar.gz.sbom.spdx.json" "$CASE/proof.before"
check 'complete retry preserves SBOM inode' test "$(stat -c %i "$ART/a.tar.gz.sbom.spdx.json")" = "$inode"
capture without_syft sbom_verify_artifacts "$ART"
check 'independent full-set verification needs no scanner' test "$status" -eq 0
capture bash -c 'sbom_verify_artifacts "$1"' bash "$ART"
check 'exported API has all helper dependencies' test "$status" -eq 0
chmod a-w "$ART"
capture sbom_verify_artifacts "$ART"
check 'verification does not write in the release directory' test "$status" -eq 0
chmod u+w "$ART"
capture sbom_generate_artifacts "$ART" --format cdx
check 'CycloneDX batch runs independently' test "$status" -eq 0
check 'CycloneDX has its own complete manifest' test "$output" = "$ART/sbom-manifest.cdx.json"
check 'SPDX manifest remains unchanged by another format' cmp -s "$manifest" "$CASE/manifest.before"
capture sbom_verify_artifacts "$ART" --format cyclonedx
check 'CycloneDX release set verifies' test "$status" -eq 0

new_case interrupted
partial
check 'later scanner failure propagates' test "$status" -eq 1
check 'partial batch emits no success path' test -z "$output"
check 'partial batch cannot publish complete manifest' absent "$ART/sbom-manifest.spdx.json"
check 'completed source-bound receipt survives later failure' test -f "$ART/a.tar.gz.sbom.spdx.json.dsr.json"
check 'complete intended input set is frozen before scanning' jq -e '(.artifacts | length) == 2' "$ART/sbom-plan.spdx.json"
cp "$ART/a.tar.gz.sbom.spdx.json" "$CASE/first.before"
cp "$ART/sbom-plan.spdx.json" "$CASE/plan.before"
export SBOM_NONCE=second-run
capture sbom_generate_artifacts "$ART"
check 'interrupted batch resumes successfully' test "$status" -eq 0
check 'resume scans only the previously failed asset' test "$(scan_count)" -eq 3
check 'completed proof is reused byte-for-byte across resume' cmp -s "$ART/a.tar.gz.sbom.spdx.json" "$CASE/first.before"
check 'resume preserves the frozen plan' cmp -s "$ART/sbom-plan.spdx.json" "$CASE/plan.before"
capture sbom_verify_artifacts "$ART"
check 'resumed release verifies as a complete set' test "$status" -eq 0

new_case removed-unfinished
partial
mv "$ART/b.tar.xz" "$CASE/b.saved"
before=$(scan_count)
capture sbom_generate_artifacts "$ART"
check 'retry cannot silently drop an unfinished target' nonzero "$status"
check 'dropped target is rejected without rescanning' test "$(scan_count)" -eq "$before"
check 'dropped target cannot produce complete manifest' absent "$ART/sbom-manifest.spdx.json"

new_case changed-input
partial
printf changed >> "$ART/a.tar.gz"
before=$(scan_count)
capture sbom_generate_artifacts "$ART"
check 'cached scan cannot be reused for changed artifact bytes' nonzero "$status"
check 'changed frozen source fails before scans' test "$(scan_count)" -eq "$before"

new_case stale-complete
capture sbom_generate_artifacts "$ART"
cp "$ART/sbom-manifest.spdx.json" "$CASE/before"
printf new > "$ART/c.zip"
before=$(scan_count)
capture sbom_verify_artifacts "$ART"
check 'complete-set verification rejects an extra artifact' nonzero "$status"
capture sbom_generate_artifacts "$ART"
check 'stale completed inventory is not silently overwritten' nonzero "$status"
check 'stale inventory conflict performs no new scans' test "$(scan_count)" -eq "$before"
check 'stale inventory is preserved for diagnosis' cmp -s "$ART/sbom-manifest.spdx.json" "$CASE/before"

new_case proof-tamper
capture sbom_generate_artifacts "$ART"
jq '.name = "valid but changed"' "$ART/a.tar.gz.sbom.spdx.json" > "$CASE/changed.json"
cp "$CASE/changed.json" "$ART/a.tar.gz.sbom.spdx.json"
before=$(scan_count)
capture sbom_verify_artifacts "$ART"
check 'valid JSON with altered SBOM bytes fails binding' nonzero "$status"
capture sbom_generate_artifacts "$ART"
check 'retained altered SBOM is not repaired by blind regeneration' nonzero "$status"
check 'altered SBOM is rejected without scanner execution' test "$(scan_count)" -eq "$before"

new_case receipt-tamper
partial
receipt="$ART/a.tar.gz.sbom.spdx.json.dsr.json"
jq '.sbom.sha256 = ("0" * 64)' "$receipt" > "$CASE/changed.json"
cp "$CASE/changed.json" "$receipt"
before=$(scan_count)
capture sbom_generate_artifacts "$ART"
check 'invalid cached binding fails before new scans' nonzero "$status"
check 'bad receipt cannot fall back to weaker cache semantics' test "$(scan_count)" -eq "$before"

new_case legacy
cp "$WORK/cases/complete/proof.before" "$ART/a.tar.gz.sbom.spdx.json"
capture sbom_generate_artifacts "$ART"
check 'unbound but valid unsigned sidecar can be rescanned' test "$status" -eq 0
check 'unbound sidecar is not blindly treated as cached' test "$(scan_count)" -eq 2
check 'rescanned sidecar obtains a source-bound receipt' test -f "$ART/a.tar.gz.sbom.spdx.json.dsr.json"

new_case signed-unbound
cp "$WORK/cases/complete/proof.before" "$ART/a.tar.gz.sbom.spdx.json"
printf signature > "$ART/a.tar.gz.sbom.spdx.json.minisig"
capture sbom_generate_artifacts "$ART"
check 'unbound signed SBOM cannot be regenerated' nonzero "$status"
check 'signed conflict is detected before scans' test "$(scan_count)" -eq 0

for mutation in source addition proof plan; do
    new_case "late-$mutation"
    export SBOM_CHANGE_AT=b.tar.xz
    case "$mutation" in
        source) export SBOM_CHANGE_SOURCE="$ART/a.tar.gz" ;;
        addition) export SBOM_ADD_SOURCE="$ART/new.zip" ;;
        proof) export SBOM_CHANGE_PROOF="$ART/a.tar.gz.sbom.spdx.json" ;;
        plan) export SBOM_CHANGE_PLAN="$ART/sbom-plan.spdx.json" ;;
    esac
    capture sbom_generate_artifacts "$ART"
    check "late $mutation mutation cannot report completion" nonzero "$status"
    check "late $mutation mutation prevents aggregate publication" absent "$ART/sbom-manifest.spdx.json"
done

new_case publication-failure
ln() {
    [[ "${*: -1}" != */sbom-manifest.spdx.json ]] || return 19
    command ln "$@"
}
capture sbom_generate_artifacts "$ART"
check 'aggregate publication failure remains nonzero' nonzero "$status"
check 'failed aggregate publication does not discard completed pairs' test -f "$ART/b.tar.xz.sbom.spdx.json.dsr.json"
check 'failed aggregate publication leaves no final manifest' absent "$ART/sbom-manifest.spdx.json"
unset -f ln
before=$(scan_count)
capture without_syft sbom_generate_artifacts "$ART"
check 'completed pairs recover from aggregate publication failure' test "$status" -eq 0
check 'aggregate retry requires no rescans' test "$(scan_count)" -eq "$before"

new_case receipt-publication-failure
ln() {
    [[ "${*: -1}" != */a.tar.gz.sbom.spdx.json.dsr.json ]] || return 19
    command ln "$@"
}
capture sbom_generate_artifacts "$ART"
check 'receipt publication failure is visible' nonzero "$status"
check 'orphan document remains available after receipt failure' test -f "$ART/a.tar.gz.sbom.spdx.json"
check 'receipt failure cannot publish aggregate' absent "$ART/sbom-manifest.spdx.json"
unset -f ln
capture sbom_generate_artifacts "$ART"
check 'unsigned orphan document is recovered by rescanning' test "$status" -eq 0
check 'orphan recovery never claims an unperformed scan' test "$(scan_count)" -eq 3

new_case linked-source
ln -s "$ART/a.tar.gz" "$ART/linked.zip"
capture sbom_generate_artifacts "$ART"
check 'selected artifact symlink is rejected' nonzero "$status"
check 'unsafe selection fails before scans' test "$(scan_count)" -eq 0

new_case enumeration-failure
find() { command find "$@"; return 19; }
capture sbom_generate_artifacts "$ART"
check 'find error cannot become a successful partial selection' nonzero "$status"
check 'enumeration error prevents scans' test "$(scan_count)" -eq 0
unset -f find

new_case hash-failure
sha256sum() {
    [[ "$*" != *b.tar.xz* ]] || return 19
    command sha256sum "$@"
}
capture sbom_generate_artifacts "$ART"
check 'source hash error propagates' nonzero "$status"
check 'source hash error cannot produce a plan' absent "$ART/sbom-plan.spdx.json"
unset -f sha256sum

new_case empty
mv "$ART/a.tar.gz" "$CASE/a.saved"
mv "$ART/b.tar.xz" "$CASE/b.saved"
echo metadata > "$ART/checksums.txt"
capture sbom_generate_artifacts "$ART"
check 'metadata-only selection is not a successful batch' test "$status" -eq 4
check 'empty selection has no complete inventory' absent "$ART/sbom-manifest.spdx.json"

new_case manifest-validation
capture sbom_generate_artifacts "$ART"
cp "$ART/sbom-manifest.spdx.json" "$CASE/original.json"
for filter in '.artifacts += [.artifacts[0]]' '.artifacts[0].sbom.name = "../escape.json"' '.status = "partial"' '.format = "cyclonedx"' '.artifacts = []'; do
    jq "$filter" "$CASE/original.json" > "$ART/sbom-manifest.spdx.json"
    capture sbom_verify_artifacts "$ART"
    check "manifest contract rejects $filter" nonzero "$status"
done
cat "$CASE/original.json" "$CASE/original.json" > "$ART/sbom-manifest.spdx.json"
capture sbom_verify_artifacts "$ART"
check 'multiple manifest documents are rejected' nonzero "$status"

new_case output-directory
capture sbom_generate_artifacts "$ART" --output-dir "$CASE/proofs"
check 'separate output directory is supported' test "$status" -eq 0
check 'complete manifest stays in selected output directory' test "$output" = "$CASE/proofs/sbom-manifest.spdx.json"
check 'separate output does not add artifacts to the input directory' test "$(find "$ART" -type f | wc -l)" -eq 2
capture sbom_verify_artifacts "$ART" --output-dir "$CASE/proofs"
check 'separate output directory verification works' test "$status" -eq 0

new_case cli
capture bash "$MODULE" artifacts "$ART"
check 'standalone batch CLI succeeds' test "$status" -eq 0
capture bash "$MODULE" verify-artifacts "$ART"
check 'standalone verification CLI succeeds' test "$status" -eq 0
capture bash "$MODULE" unknown "$ART"
check 'unknown CLI command returns invalid arguments' test "$status" -eq 4
capture bash "$MODULE" artifacts "$ART" --output-dir
check 'missing batch option value returns invalid arguments' test "$status" -eq 4
capture bash "$MODULE" json "$ART/a.tar.gz" --format
check 'standalone JSON CLI preserves failure exit' test "$status" -eq 4
check 'standalone JSON failure is still structured' jq -e '.exit_code == 4 and .status == "error"' "$CASE/stdout"

new_case concurrent
pids=()
for i in 1 2 3 4 5 6; do
    bash "$MODULE" artifacts "$ART" > "$CASE/worker-$i.out" 2> "$CASE/worker-$i.err" &
    pids+=("$!")
done
succeeded=0
for pid in "${pids[@]}"; do
    if wait "$pid"; then succeeded=$((succeeded + 1)); fi
done
check 'at least one real concurrent publisher completes' test "$succeeded" -ge 1
capture sbom_verify_artifacts "$ART"
check 'concurrent publication leaves a fully verifiable set' test "$status" -eq 0
before=$(scan_count)
capture without_syft sbom_generate_artifacts "$ART"
check 'concurrent conflicts recover by verified retry' test "$status" -eq 0
check 'verified retry after contention has no scanner calls' test "$(scan_count)" -eq "$before"

if [[ -n "$REAL_SYFT" ]]; then
    new_case real-syft
    syft() { "$REAL_SYFT" "$@"; }
    mkdir "$CASE/payload"
    echo 'module example.test/native' > "$CASE/payload/go.mod"
    tar -czf "$ART/a.tar.gz" -C "$CASE/payload" go.mod
    tar -cJf "$ART/b.tar.xz" -C "$CASE/payload" go.mod
    capture sbom_generate_artifacts "$ART"
    check 'optional real Syft release generation succeeds' test "$status" -eq 0
    capture sbom_verify_artifacts "$ART"
    check 'optional real Syft release inventory verifies' test "$status" -eq 0
    unset -f syft
else
    printf 'SKIP - native Syft integration (syft is not installed)\n'
fi
printf '\nSBOM batch regression checks: %d; failures: %d\n' "$checks" "$failures"
[[ "$failures" -eq 0 ]]
