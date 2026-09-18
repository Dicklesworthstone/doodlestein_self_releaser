#!/usr/bin/env bash
# Production SLSA API with real Git, hashing, files and publication primitives.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for tool in jq git sha256sum; do command -v "$tool" >/dev/null || { echo "SKIP: $tool required"; exit 0; }; done
source "${DSR_SLSA_MODULE:-$ROOT/src/slsa.sh}"
TEMP=$(mktemp -d "${TMPDIR:-/tmp}/dsr-slsa-test.XXXXXXXX") || exit 1
trap 'rm -rf -- "$TEMP"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TEMP/gitconfig"
mkdir -p "$TEMP/repo" "$TEMP/other" "$TEMP/dist" "$TEMP/proofs"
for repo in repo other; do
    git init -q -b main "$TEMP/$repo"
    git -C "$TEMP/$repo" config user.name 'DSR test'
    git -C "$TEMP/$repo" config user.email test@example.invalid
    git -C "$TEMP/$repo" remote add origin "https://github.com/example/$repo.git"
    printf 'source %s\n' "$repo" > "$TEMP/$repo/code"
    git -C "$TEMP/$repo" add code
    git -C "$TEMP/$repo" commit -qm initial
done
PIN=$(git -C "$TEMP/repo" rev-parse HEAD)
OTHER=$(git -C "$TEMP/other" rev-parse HEAD)
artifact="$TEMP/dist/tool-1.0-linux.tar.gz"
printf 'compiled artifact\n' > "$artifact"
passed=0 failed=0 status=0 output=''
check() {
    local label="$1"; shift
    if "$@"; then passed=$((passed + 1)); printf 'PASS: %s\n' "$label"
    else failed=$((failed + 1)); printf 'FAIL: %s\n' "$label" >&2; fi
}
equal() { [[ "$1" == "$2" ]]; }
run() { status=0; output=$("$@" 2> "$TEMP/last.err") || status=$?; }
run slsa_generate "$artifact" --builder dsr/v1 --repo-path "$TEMP/repo" --invocation-id run-1
check 'generate explicit source observation' equal "$status" 0
proof="$artifact.intoto.jsonl"
check 'stdout contains only the output path' equal "$output" "$proof"
check 'one statement document' jq -es 'length == 1' "$proof"
check 'records the explicit source commit' jq -e --arg sha "$PIN" '.predicate.buildDefinition.resolvedDependencies[0].digest.gitCommit == $sha' "$proof"
check 'observation is not invented build timing' jq -e '.dsr_evidence.kind == "post-build-observation" and (.dsr_evidence.observedOn | type == "string") and (.predicate.runDetails.metadata | has("startedOn") | not)' "$proof"
run slsa_verify "$artifact" "$proof" --builder dsr/v1 --source-repository https://github.com/example/repo.git --source-commit "$PIN" --invocation-id run-1
check 'named artifact and requested source policy match' equal "$status" 0
check 'verification does not mix logs onto stdout' equal "$output" ''
check 'unsigned verification does not claim authentication' grep -q 'not authenticated' "$TEMP/last.err"
before=$(_slsa_sha256 "$proof")
run slsa_generate "$artifact" --builder dsr/v1 --repo-path "$TEMP/repo" --invocation-id run-1
check 'generation retry retains valid proof' equal "$status" 0
check 'generation retry preserves exact proof bytes' equal "$before" "$(_slsa_sha256 "$proof")"
run slsa_generate "$artifact" --builder other --repo-path "$TEMP/repo"
check 'conflicting generator identity fails' test "$status" -ne 0
check 'conflict never replaces published proof' equal "$before" "$(_slsa_sha256 "$proof")"
for policy in builder repository commit invocation; do
    case "$policy" in
        builder) args=(--builder wrong) ;;
        repository) args=(--source-repository https://github.com/example/other.git --source-commit "$PIN") ;;
        commit) args=(--source-repository https://github.com/example/repo.git --source-commit "$OTHER") ;;
        invocation) args=(--invocation-id other-run) ;;
    esac
    run slsa_verify "$artifact" "$proof" "${args[@]}"
    check "wrong expected $policy fails" equal "$status" 1
done
for mutation in wrong-name duplicate no-predicate no-definition no-builder bad-builder bad-digest control-digest no-subjects bad-params; do
    case "$mutation" in
        wrong-name) filter='.subject[0].name="different-file"' ;;
        duplicate) filter='.subject += [.subject[0]]' ;;
        no-predicate) filter='del(.predicate)' ;;
        no-definition) filter='del(.predicate.buildDefinition)' ;;
        no-builder) filter='del(.predicate.runDetails.builder)' ;;
        bad-builder) filter='.predicate.runDetails.builder.id=42' ;;
        bad-digest) filter='.subject[0].digest.sha256=""' ;;
        control-digest) filter='.subject[0].digest.sha256 += "\n"' ;;
        no-subjects) filter='.subject=[]' ;;
        bad-params) filter='.predicate.buildDefinition.externalParameters=[]' ;;
    esac
    jq "$filter" "$proof" > "$TEMP/proofs/$mutation"
    run slsa_verify "$artifact" "$TEMP/proofs/$mutation"
    check "invalid statement rejected: $mutation" equal "$status" 1
done
cat "$proof" "$proof" > "$TEMP/proofs/multiple"
run slsa_verify "$artifact" "$TEMP/proofs/multiple"
check 'multiple JSON statements are not one verified document' equal "$status" 1
jq '.subject = [{name:"unrelated",digest:{sha256:("0" * 64)}}] + .subject' "$proof" > "$TEMP/proofs/multi-subject"
run slsa_verify "$artifact" "$TEMP/proofs/multi-subject"
check 'matching named subject may occur after the first subject' equal "$status" 0
jq '.subject[0].digest.sha256="0" * 64' "$proof" > "$TEMP/proofs/wrong-hash"
run slsa_verify "$artifact" "$TEMP/proofs/wrong-hash"
check 'wrong artifact digest fails' equal "$status" 1
ln -s "$proof" "$TEMP/proofs/link"
run slsa_verify "$artifact" "$TEMP/proofs/link"
check 'linked statement rejected' test "$status" -ne 0
ln -s "$artifact" "$TEMP/dist/linked"
run slsa_generate "$TEMP/dist/linked"
check 'linked artifact cannot get a statement' equal "$status" 4
run slsa_generate "$artifact" --output "$artifact"
check 'output cannot overwrite its own artifact' equal "$status" 4
check 'artifact bytes preserved after overlap rejection' equal "$(cat "$artifact")" 'compiled artifact'
run slsa_generate "$artifact" --output "$TEMP/proofs/link"
check 'linked output cannot overwrite its target' equal "$status" 4
check 'linked output target bytes preserved' equal "$before" "$(_slsa_sha256 "$proof")"
run slsa_generate "$artifact" --repo-path "$TEMP/missing" --output "$TEMP/proofs/bad-repo"
check 'bad explicit repository is not replaced by PWD discovery' equal "$status" 4
check 'bad repository creates no statement' test ! -e "$TEMP/proofs/bad-repo"
run bash -c 'source "$1"; cd "$2"; slsa_generate "$3" --output "$4"' _ "$ROOT/src/slsa.sh" "$TEMP/other" "$artifact" "$TEMP/proofs/no-repo"
check 'artifact generation works without source evidence' equal "$status" 0
check 'unrelated current directory is not claimed as source' jq -e '.predicate.buildDefinition.resolvedDependencies == [] and .dsr_evidence.source == {}' "$TEMP/proofs/no-repo"
GIT_DIR="$TEMP/other/.git" GIT_WORK_TREE="$TEMP/other" run slsa_generate "$artifact" --repo-path "$TEMP/repo" --output "$TEMP/proofs/env"
check 'ambient Git plumbing cannot redirect source selection' equal "$status" 0
check 'explicit repository remains selected despite ambient Git settings' jq -e --arg sha "$PIN" '.predicate.buildDefinition.resolvedDependencies[0].digest.gitCommit == $sha' "$TEMP/proofs/env"
# Detect source changes honestly, not as a clean immutable build claim.
printf 'dirty input\n' >> "$TEMP/repo/code"
run slsa_generate "$artifact" --repo-path "$TEMP/repo" --output "$TEMP/proofs/dirty"
check 'dirty checkout observation is explicitly marked' jq -e '.dsr_evidence.source.tracked_dirty == true' "$TEMP/proofs/dirty"
git -C "$TEMP/repo" remote set-url origin https://secret@example.invalid/repo.git
run slsa_generate "$artifact" --repo-path "$TEMP/repo" --output "$TEMP/proofs/credentials"
check 'credentials cannot leak into a public source URI' equal "$status" 4
check 'credential-bearing origin creates no proof' test ! -e "$TEMP/proofs/credentials"
for flag in --builder --output --repo-path --invocation-id --build-type; do
    run slsa_generate "$artifact" "$flag"
    check "missing argument rejected: $flag" equal "$status" 4
done
run slsa_generate "$artifact" --unsupported value
check 'unknown arguments are not ignored' equal "$status" 4
run slsa_verify "$artifact" "$proof" --source-commit "$PIN"
check 'source policy requires repository and commit together' equal "$status" 4
run slsa_generate_json "$artifact" --output "$TEMP/proofs/json" --builder dsr/json
check 'JSON wrapper forwards output and builder options' equal "$status" 0
check 'JSON output path is not contaminated by logs' jq -ne --argjson value "$output" --arg path "$TEMP/proofs/json" '$value.output_file == $path and $value.authenticated == false and $value.exit_code == 0'
run slsa_generate_json "$TEMP/no-artifact"
check 'JSON generation failure preserves nonzero process status' equal "$status" 4
check 'failure JSON contains no success path' jq -ne --argjson value "$output" '$value.status == "error" and $value.output_file == null and $value.exit_code == 4'
# Local fault injection: compressors/network/cryptographic tools are not involved.
ln() { return 23; }
run slsa_generate "$artifact" --output "$TEMP/proofs/failed-publication"
unset -f ln
check 'publication failure propagates' test "$status" -ne 0
check 'failed publication leaves no partial final output' test ! -e "$TEMP/proofs/failed-publication"
check 'private statement staging is cleaned' test -z "$(find "$TEMP/proofs" -name '.dsr-provenance.*' -print)"
sha256sum() { return 19; }
run slsa_verify "$artifact" "$proof"
check 'hash failure can never equal a claimed empty digest' test "$status" -ne 0
run slsa_generate "$artifact" --output "$TEMP/proofs/failed-hash"
unset -f sha256sum
check 'failed hashing generates no output' test ! -e "$TEMP/proofs/failed-hash"
mkdir "$TEMP/batch"
printf first > "$TEMP/batch/first"
printf second > "$TEMP/batch/second"
run slsa_generate_batch "$TEMP/batch"
check 'batch produces proof for each artifact' equal "$status" 0
check 'first batch proof matches' slsa_verify "$TEMP/batch/first"
check 'second batch proof matches' slsa_verify "$TEMP/batch/second"
batch_hash=$(_slsa_sha256 "$TEMP/batch/first.intoto.jsonl")
run slsa_generate_batch "$TEMP/batch"
check 'batch retry checks and retains proof bytes' equal "$batch_hash" "$(_slsa_sha256 "$TEMP/batch/first.intoto.jsonl")"
printf '{"existing":true}\n' > "$TEMP/batch/second.intoto.jsonl"
run slsa_generate_batch "$TEMP/batch"
check 'invalid existing proof cannot count as batch success' test "$status" -ne 0
check 'invalid proof remains available for inspection' equal "$(cat "$TEMP/batch/second.intoto.jsonl")" '{"existing":true}'
mkdir "$TEMP/empty"
run slsa_generate_batch "$TEMP/empty"
check 'empty batch is not a completed release' equal "$status" 7
printf 'SLSA contract: %s passed, %s failed\n' "$passed" "$failed"
[[ "$failed" == 0 ]]
