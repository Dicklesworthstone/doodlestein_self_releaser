#!/usr/bin/env bash
# Offline SBOM publication regressions. Files, hashing, jq, links and moves are
# real; the Syft executable is an explicit process fixture, not a real scan.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
MODULE="${SBOM_TEST_MODULE:-$ROOT/src/sbom.sh}"
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
trap 'exit 5' HUP INT TERM
mkdir -p "$WORK/bin" "$WORK/cases"
export PATH="$WORK/bin:$PATH" SBOM_FIXTURES="$WORK"
export SBOM_OUTPUT_DIR=""
cat > "$WORK/spdx.json" <<'JSON'
{"spdxVersion":"SPDX-2.3","dataLicense":"CC0-1.0","SPDXID":"SPDXRef-DOCUMENT","name":"fixture","documentNamespace":"https://example.test/sbom/fixture","creationInfo":{"creators":["Tool: syft-fixture"],"created":"2026-09-18T00:00:00Z"},"packages":[]}
JSON
cat > "$WORK/cyclonedx.json" <<'JSON'
{"bomFormat":"CycloneDX","specVersion":"1.6","version":1,"components":[]}
JSON
cat > "$WORK/bin/syft" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
[[ "$1" != version ]] || { echo 'syft 1.0.0'; exit; }
printf '%s\0' "$@" > "$SBOM_FIXTURES/args"
printf 'scan\n' >> "$SBOM_FIXTURES/scans"
format=spdx
[[ "$2" != cyclonedx-json ]] || format=cyclonedx
case "${SBOM_FIXTURE_MODE:-valid}" in
    fail) printf '{"partial":'; echo 'scanner failed' >&2; exit 17 ;;
    empty) exit 0 ;;
    malformed) echo '{broken'; exit 0 ;;
    scalar) echo true; exit 0 ;;
    multiple) cat "$SBOM_FIXTURES/$format.json" "$SBOM_FIXTURES/$format.json"; exit ;;
    wrong) [[ "$format" == spdx ]] && format=cyclonedx || format=spdx ;;
    thin) echo '{"spdxVersion":"SPDX-2.3"}'; exit 0 ;;
    drift) printf changed >> "$SBOM_MUTATE_SOURCE" ;;
    snapshot-drift)
        for arg in "$@"; do
            case "$arg" in file:*) printf changed >> "${arg#file:}" ;; esac
        done ;;
    destination-drift) printf changed >> "$SBOM_MUTATE_DEST" ;;
    late-signature) printf signed > "$SBOM_MUTATE_DEST.minisig" ;;
esac
[[ -z "${SBOM_FIXTURE_NOISE:-}" ]] || echo 'scanner progress' >&2
cat "$SBOM_FIXTURES/$format.json"
SH
chmod +x "$WORK/bin/syft"
# The baseline required an external logger. The current module has a fallback.
log_error() { printf '[ERROR] %s\n' "$*" >&2; }
log_warn() { printf '[WARN] %s\n' "$*" >&2; }
log_info() { printf '[INFO] %s\n' "$*" >&2; }
log_ok() { printf '[OK] %s\n' "$*" >&2; }
log_debug() { :; }
# shellcheck source=/dev/null
source "$MODULE"
checks=0 failures=0 status=0 output="" CASE=""
check() {
    local description="$1"
    shift
    checks=$((checks + 1))
    if "$@"; then
        printf 'ok %d - %s\n' "$checks" "$description"
    else
        printf 'not ok %d - %s\n' "$checks" "$description"
        failures=$((failures + 1))
    fi
}
new_case() {
    CASE="$WORK/cases/$1"
    mkdir -p "$CASE"
    printf 'artifact payload\n' > "$CASE/tool.tar.gz"
    unset SBOM_FIXTURE_MODE SBOM_MUTATE_SOURCE SBOM_MUTATE_DEST SBOM_FIXTURE_NOISE
}
capture() {
    status=0
    "$@" > "$CASE/stdout" 2> "$CASE/stderr" || status=$?
    output=$(cat "$CASE/stdout")
}
nonzero() { [[ "$1" -ne 0 ]]; }
absent() { [[ ! -e "$1" && ! -L "$1" ]]; }
contains() { grep -F -- "$2" "$1" >/dev/null; }

new_case formats
capture sbom_generate "$CASE/tool.tar.gz"
check 'SPDX generation succeeds' test "$status" -eq 0
check 'full archive basename is preserved' test "$output" = "$CASE/tool.tar.gz.sbom.spdx.json"
check 'published SPDX document validates' sbom_verify "$CASE/tool.tar.gz.sbom.spdx.json"
printf 'different archive\n' > "$CASE/tool.tar.xz"
capture sbom_generate "$CASE/tool.tar.xz"
check 'tar.xz generation succeeds independently' test "$status" -eq 0
check 'compression variants have distinct documents' test -f "$CASE/tool.tar.xz.sbom.spdx.json"
capture sbom_generate "$CASE/tool.tar.gz" --format cyclonedx
check 'CycloneDX generation succeeds' test "$status" -eq 0
check 'CycloneDX retains full basename' test "$output" = "$CASE/tool.tar.gz.sbom.cdx.json"
capture sbom_generate "$CASE/tool.tar.gz" --format cdx --output "$CASE/custom proof.json"
check 'format alias and custom output work' test "$status" -eq 0
check 'custom output path is not polluted by logs' test "$output" = "$CASE/custom proof.json"

new_case filename
mkdir -p "$CASE/dotted.dir"
printf bytes > "$CASE/dotted.dir/plain"
capture sbom_generate "$CASE/dotted.dir/plain"
check 'dot in parent directory cannot truncate output path' test "$output" = "$CASE/dotted.dir/plain.sbom.spdx.json"
printf bytes > "$CASE/tool with spaces"
capture sbom_generate "$CASE/tool with spaces"
check 'space-containing artifact path works' test "$status" -eq 0
check 'space-containing basename remains exact' test "$output" = "$CASE/tool with spaces.sbom.spdx.json"

for mode in fail empty malformed scalar multiple wrong thin; do
    new_case "invalid-$mode"
    export SBOM_FIXTURE_MODE="$mode"
    capture sbom_generate "$CASE/tool.tar.gz"
    check "$mode scanner result cannot succeed" nonzero "$status"
    check "$mode scanner result leaves no final document" absent "$CASE/tool.tar.gz.sbom.spdx.json"
    check "$mode scanner result emits no success path" test -z "$output"
    cp "$WORK/spdx.json" "$CASE/retained.json"
    capture sbom_generate "$CASE/tool.tar.gz" --output "$CASE/retained.json"
    check "$mode failure preserves retained proof bytes" cmp -s "$WORK/spdx.json" "$CASE/retained.json"
done

new_case verify
for data in 'null' '[]' '{}' '{"spdxVersion":true}' '{"bomFormat":"not-cyclonedx","specVersion":"1.6","version":1}' '{"bomFormat":"CycloneDX","specVersion":"1.6","version":0}' '{"bomFormat":"CycloneDX","specVersion":"1.6","version":1,"components":{}}'; do
    printf '%s\n' "$data" > "$CASE/bad.json"
    capture sbom_verify "$CASE/bad.json"
    check "document contract rejects $data" nonzero "$status"
done
cat "$WORK/spdx.json" "$WORK/cyclonedx.json" > "$CASE/multiple.json"
capture sbom_verify "$CASE/multiple.json"
check 'verification rejects a stream of multiple documents' nonzero "$status"
capture sbom_verify "$WORK/cyclonedx.json" --format spdx
check 'verification enforces requested format' nonzero "$status"

new_case arguments
for flag in --format --output; do
    capture sbom_generate "$CASE/tool.tar.gz" "$flag"
    check "missing $flag value is invalid arguments" test "$status" -eq 4
    check "missing $flag value leaves no output" test -z "$output"
done
capture sbom_generate "$CASE/tool.tar.gz" --unknown
check 'unknown option rejected' test "$status" -eq 4
capture sbom_generate "$CASE/tool.tar.gz" --format unknown
check 'unknown format rejected' test "$status" -eq 4
capture sbom_generate
check 'missing target rejected' test "$status" -eq 4

new_case drift
export SBOM_FIXTURE_MODE=drift SBOM_MUTATE_SOURCE="$CASE/tool.tar.gz"
capture sbom_generate "$CASE/tool.tar.gz"
check 'source change during scan fails' nonzero "$status"
check 'source change leaves no unbound proof' absent "$CASE/tool.tar.gz.sbom.spdx.json"
export SBOM_FIXTURE_MODE=snapshot-drift
capture sbom_generate "$CASE/tool.tar.gz"
check 'snapshot change during scan fails' nonzero "$status"
check 'snapshot change leaves no proof' absent "$CASE/tool.tar.gz.sbom.spdx.json"

new_case destinations
ln -s "$CASE/tool.tar.gz" "$CASE/linked-input"
capture sbom_generate "$CASE/linked-input"
check 'linked input rejected' nonzero "$status"
mkfifo "$CASE/fifo"
capture sbom_generate "$CASE/fifo"
check 'special input rejected' nonzero "$status"
ln -s "$CASE/tool.tar.gz" "$CASE/linked-output"
cp "$CASE/tool.tar.gz" "$CASE/original"
capture sbom_generate "$CASE/tool.tar.gz" --output "$CASE/linked-output"
check 'linked output rejected' nonzero "$status"
check 'linked output cannot change artifact' cmp -s "$CASE/tool.tar.gz" "$CASE/original"
ln "$CASE/tool.tar.gz" "$CASE/hardlink-output"
capture sbom_generate "$CASE/tool.tar.gz" --output "$CASE/hardlink-output"
check 'hardlink input/output overlap rejected' nonzero "$status"
cp "$WORK/spdx.json" "$CASE/signed.json"
printf signature > "$CASE/signed.json.minisig"
capture sbom_generate "$CASE/tool.tar.gz" --output "$CASE/signed.json"
check 'signed proof is not regenerated' nonzero "$status"
check 'signed proof bytes preserved' cmp -s "$WORK/spdx.json" "$CASE/signed.json"
printf '{"existing":true}\n' > "$CASE/invalid.json"
cp "$CASE/invalid.json" "$CASE/invalid.before"
capture sbom_generate "$CASE/tool.tar.gz" --output "$CASE/invalid.json"
check 'invalid retained proof is not trusted' nonzero "$status"
check 'invalid retained proof preserved for diagnosis' cmp -s "$CASE/invalid.before" "$CASE/invalid.json"
cp "$WORK/spdx.json" "$CASE/changing.json"
export SBOM_FIXTURE_MODE=destination-drift SBOM_MUTATE_DEST="$CASE/changing.json"
capture sbom_generate "$CASE/tool.tar.gz" --output "$CASE/changing.json"
check 'concurrent destination mutation rejected' nonzero "$status"
check 'concurrent writer data not overwritten' contains "$CASE/changing.json" changed
export SBOM_FIXTURE_MODE=late-signature SBOM_MUTATE_DEST="$CASE/late.json"
capture sbom_generate "$CASE/tool.tar.gz" --output "$CASE/late.json"
check 'late signature prevents publication' nonzero "$status"
check 'late signature does not acquire unrelated proof' absent "$CASE/late.json"

new_case project
mkdir "$CASE/project[1]"
capture sbom_generate_project "$CASE/project[1]" --output "$CASE/project[1]/sbom[1].json" --quiet
check 'project wrapper preserves custom output' test "$output" = "$CASE/project[1]/sbom[1].json"
tr '\0' '\n' < "$WORK/args" > "$CASE/args.txt"
check 'directory scan excludes its output with literal glob quoting' contains "$CASE/args.txt" './sbom\[1\].json'
check 'directory scan excludes private staging tree' contains "$CASE/args.txt" './.dsr-sbom.'

new_case json
export SBOM_FIXTURE_NOISE=true
capture sbom_generate_json "$CASE/tool.tar.gz" --output "$CASE/custom.json" --format cyclonedx
check 'JSON wrapper succeeds' test "$status" -eq 0
check 'JSON wrapper preserves output option' jq -e --arg p "$CASE/custom.json" '.output_file == $p and .status == "success" and .exit_code == 0' "$CASE/stdout"
check 'JSON wrapper keeps diagnostics out of path' jq -e '.output_file | contains("scanner") | not' "$CASE/stdout"
export SBOM_FIXTURE_MODE=fail
capture sbom_generate_json "$CASE/tool.tar.gz"
check 'JSON wrapper preserves scanner failure status' test "$status" -eq 1
check 'JSON scanner failure has typed error and null output' jq -e '.status == "error" and .exit_code == 1 and .output_file == null and (.error | contains("scanner failed"))' "$CASE/stdout"
capture sbom_generate_json "$CASE/tool.tar.gz" --format
check 'JSON malformed option exit is invalid arguments' test "$status" -eq 4
check 'JSON malformed option still emits one JSON object' jq -e -s 'length == 1 and .[0].exit_code == 4' "$CASE/stdout"
capture sbom_generate_json
check 'JSON missing target exit is invalid arguments' test "$status" -eq 4
check 'JSON missing target is structured' jq -e '.output_file == null and .status == "error"' "$CASE/stdout"

new_case io
cp "$WORK/spdx.json" "$CASE/retained.json"
# Different valid scanner result forces the atomic replacement path.
jq '.name = "replacement"' "$WORK/spdx.json" > "$WORK/changed.json"
cp "$WORK/spdx.json" "$WORK/unchanged.json"
cp "$WORK/changed.json" "$WORK/spdx.json"
mv() { return 19; }
capture sbom_generate "$CASE/tool.tar.gz" --output "$CASE/retained.json"
check 'failed publication remains failure' nonzero "$status"
check 'failed publication preserves original document' cmp -s "$WORK/unchanged.json" "$CASE/retained.json"
unset -f mv
cp "$WORK/unchanged.json" "$WORK/spdx.json"
cp() { return 19; }
capture sbom_generate "$CASE/tool.tar.gz"
check 'snapshot copy failure cannot report success' nonzero "$status"
check 'snapshot copy failure publishes nothing' absent "$CASE/tool.tar.gz.sbom.spdx.json"
unset -f cp

printf '\nSBOM release regression checks: %d; failures: %d\n' "$checks" "$failures"
[[ "$failures" -eq 0 ]]
