#!/usr/bin/env bash
# Real shell/files/JSON/hash/publication checks; Docker/Syft/Cosign are explicit
# executable fixtures. This suite does not build or publish live containers.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
MODULE="${DOCKER_TEST_MODULE:-$ROOT/src/docker.sh}"
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
trap 'exit 5' HUP INT TERM
mkdir -p "$WORK/bin" "$WORK/cases"
export PATH="$WORK/bin:$PATH" DK_WORK="$WORK"
export DK_DIGEST="sha256:$(printf 'a%.0s' {1..64})"
unset DSR_GH_TOKEN GITHUB_TOKEN GH_TOKEN DOCKER_OUTPUT_DIR
export DOCKER_REGISTRY=ghcr.io/acme DOCKER_BUILDER_NAME=dsr-test-builder
export DOCKER_PLATFORMS=linux/amd64,linux/arm64
cat > "$WORK/bin/docker" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
jq -nc --args '$ARGS.positional' -- "$@" >> "$DK_CALLS"
case "$*" in
    info|buildx\ version) exit 0 ;;
    buildx\ inspect*) [[ "${DK_MODE:-}" != bootstrap-fail || "$*" != *--bootstrap* ]]; exit $? ;;
    buildx\ create*) exit 0 ;;
    login*) cat > "$DK_WORK/token.stdin"; [[ "${DK_MODE:-}" != login-fail ]]; exit $? ;;
esac
[[ "${1:-} ${2:-}" == 'buildx build' ]] || { echo "Unexpected Docker command: $*" >&2; exit 98; }
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
    # Real tar bytes exercise publication; this is not a real OCI image.
    tar -cf "$dest" -C "$DK_WORK" payload
fi
echo 'build progress on stdout'
SH
cat > "$WORK/bin/syft" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
jq -nc --args '$ARGS.positional' -- syft "$@" >> "$DK_CALLS"
case "${DK_MODE:-}" in
    syft-fail) echo partial; exit 17 ;;
    syft-empty) exit 0 ;;
    syft-invalid) echo '{"spdxVersion":true}'; exit 0 ;;
    syft-multiple) printf '{}\n{}\n'; exit 0 ;;
esac
cat "$DK_WORK/spdx.json"
SH
cat > "$WORK/bin/cosign" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
jq -nc --args '$ARGS.positional' -- cosign "$@" >> "$DK_CALLS"
[[ "${DK_MODE:-}" != sign-fail || "$1" != sign ]] || exit 18
[[ "${DK_MODE:-}" != attest-fail || "$1" != attest ]] || exit 18
echo 'signer diagnostic on stdout'
SH
cat > "$WORK/bin/gh" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
printf 'gh-config-token'
SH
chmod +x "$WORK/bin/docker" "$WORK/bin/syft" "$WORK/bin/cosign" "$WORK/bin/gh"
printf payload > "$WORK/payload"
cat > "$WORK/spdx.json" <<'JSON'
{"spdxVersion":"SPDX-2.3","dataLicense":"CC0-1.0","SPDXID":"SPDXRef-DOCUMENT","name":"fixture","documentNamespace":"https://example.test/sbom","creationInfo":{"created":"2026-09-18T00:00:00Z","creators":["Tool: fixture"]},"packages":[]}
JSON
source "$MODULE"
checks=0 failures=0 status=0 CASE='' REPO='' output=''
new_case() {
    CASE="$WORK/cases/$1"; REPO="$CASE/project with spaces"
    mkdir -p "$REPO/docker"
    printf 'FROM scratch\nCOPY binary /binary\n' > "$REPO/docker/Dockerfile"
    printf binary > "$REPO/binary"
    export DK_CALLS="$CASE/calls.jsonl" DK_MODE=''
    : > "$DK_CALLS"
    export DOCKER_OUTPUT_DIR="$CASE/output"
    DRY_RUN=false
    unset DSR_GH_TOKEN GITHUB_TOKEN GH_TOKEN
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

new_case dry
capture build --push --dry-run
check 'dry run succeeds without Docker interaction' test "$status" -eq 0
check 'dry run invokes no external adapters' no_calls
check 'dry run is a plan, not built' jq -e '.status == "planned" and .dry_run == true and .digest == null' "$CASE/stdout"
check 'nested Dockerfile retains repository build context' jq -e --arg root "$REPO" '.context == $root and .dockerfile == ($root + "/docker/Dockerfile")' "$CASE/stdout"
check 'latest is not silently published' jq -e '.tags == ["ghcr.io/acme/tool:v1.2.3"]' "$CASE/stdout"
DRY_RUN=true
capture release
check 'global dry run propagates through release' test "$status" -eq 0
check 'global dry run has no setup/push/sign/scan effects' no_calls
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
check 'release refers to immutable built digest' jq -e --arg ref "ghcr.io/acme/tool@$DK_DIGEST" '.reference == $ref and .status == "complete" and .signature == "submitted"' "$CASE/stdout"
check 'scanner uses registry transport with same pinned digest' jq -e -s --arg ref "registry:ghcr.io/acme/tool@$DK_DIGEST" 'any(.[]; .[0] == "syft" and .[1] == $ref)' "$DK_CALLS"
check 'sign and attest never target a mutable tag' jq -e -s --arg ref "ghcr.io/acme/tool@$DK_DIGEST" 'all(.[] | select(.[0] == "cosign"); .[-1] == $ref)' "$DK_CALLS"
: > "$DK_CALLS"
capture release --skip-sign
check 'explicit skip-sign works without skipping attestation' test "$status" -eq 0
check 'skip-sign is explicitly reported' jq -e '.signature == "skipped" and .sbom == "submitted"' "$CASE/stdout"
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

printf '\nContainer regression checks: %d; failures: %d\n' "$checks" "$failures"
[[ "$failures" -eq 0 ]]
