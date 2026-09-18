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
export DOCKER_CERTIFICATE_IDENTITY=builder@example.test
export DOCKER_CERTIFICATE_OIDC_ISSUER=https://issuer.example.test
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
if [[ "${1:-} ${2:-} ${3:-}" == 'buildx imagetools inspect' ]]; then
    ref="$4"
    [[ "${DK_MODE:-}" != registry-fail ]] || exit 19
    digest="${ref##*@sha256:}"
    if [[ "$ref" != *@* ]]; then
        if [[ "${DK_MODE:-}" == tag-drift || -f "$DK_REGISTRY/tag-moved" ]]; then echo changed; exit; fi
        digest="${DK_DIGEST#sha256:}"
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
printf 'gh-config-token'
SH
chmod +x "$WORK/bin/docker" "$WORK/bin/syft" "$WORK/bin/cosign" "$WORK/bin/gh"
printf payload > "$WORK/payload"
cat > "$WORK/spdx.json" <<'JSON'
{"spdxVersion":"SPDX-2.3","dataLicense":"CC0-1.0","SPDXID":"SPDXRef-DOCUMENT","name":"fixture","documentNamespace":"https://example.test/sbom","creationInfo":{"created":"2026-09-18T00:00:00Z","creators":["Tool: fixture"]},"packages":[]}
JSON
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

printf '\nContainer regression checks: %d; failures: %d\n' "$checks" "$failures"
[[ "$failures" -eq 0 ]]
