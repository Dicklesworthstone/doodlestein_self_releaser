#!/usr/bin/env bash
# Real inventories, files, SHA256 and process deadlines. GitHub/Syft fixtures;
# no network calls, signing keys or live release mutations.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
source "$ROOT/src/sbom.sh"
source "$ROOT/src/sbom_release.sh"
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
trap 'exit 5' HUP INT TERM
CASE='' ART='' REMOTE='' PIN='' FORMAT=spdx checks=0 failures=0 status=0 output=''
export DSR_GH_TOKEN=dsr-test-credential GH_TOKEN=wrong-cli-credential GITHUB_TOKEN=wrong-token GH_HOST=enterprise.example.test
export SBOM_REMOTE_TIMEOUT=10 SBOM_REMOTE_MAX_DOCUMENT_BYTES=67108864 SBOM_OUTPUT_DIR=''
syft() {
    local format=spdx name=fixture arg
    for arg in "$@"; do
        case "$arg" in cyclonedx-json) format=cyclonedx ;; file:*) name="${arg##*/}" ;; esac
    done
    if [[ "$format" == spdx ]]; then
        jq -nc --arg name "$name" '{spdxVersion:"SPDX-2.3",dataLicense:"CC0-1.0",
          SPDXID:"SPDXRef-DOCUMENT",name:$name,documentNamespace:"https://example.test/sbom/fixture",
          creationInfo:{creators:["Tool: syft-fixture"],created:"2026-09-18T00:00:00Z"},packages:[]}'
    else
        jq -nc --arg name "$name" '{bomFormat:"CycloneDX",specVersion:"1.6",version:1,
          components:[{type:"application",name:$name}]}'
    fi
}
remote_add() {
    local name="$1" file="$2" digest="${3:-present}" id sha size
    id=$(jq '([.[].id] | max // 100) + 1' "$REMOTE/inventory.json") || return 1
    sha=$(_sbom_hash "$file") || return 1
    size=$(wc -c < "$file"); size="${size//[[:space:]]/}"
    cp "$file" "$REMOTE/bytes/$id" || return 1
    [[ "$digest" == missing ]] && digest='' || digest="sha256:$sha"
    jq --arg name "$name" --arg digest "$digest" --argjson id "$id" --argjson size "$size" \
       '. + [{id:$id,name:$name,state:"uploaded",size:$size,digest:(if $digest == "" then null else $digest end)}]' \
       "$REMOTE/inventory.json" > "$REMOTE/inventory.next" || return 1
    mv "$REMOTE/inventory.next" "$REMOTE/inventory.json"
}
new_case() {
    CASE="$WORK/$1"; ART="$CASE/artifacts"; REMOTE="$CASE/remote"
    mkdir -p "$ART" "$REMOTE/bytes"
    FORMAT="${2:-spdx}"
    printf 'first\0payload\n' > "$ART/a.tar.gz"
    printf 'second payload\n' > "$ART/b.tar.xz"
    sbom_generate_artifacts "$ART" --format "$FORMAT" > "$CASE/generated" 2> "$CASE/generation.log" || {
        cat "$CASE/generation.log" >&2; exit 1;
    }
    local ext name
    ext=$(_sbom_extension "$FORMAT")
    PIN=$(_sbom_hash "$ART/sbom-manifest.$ext")
    printf '[]\n' > "$REMOTE/inventory.json"
    for name in a.tar.gz b.tar.xz "a.tar.gz.sbom.$ext" "b.tar.xz.sbom.$ext" "sbom-manifest.$ext"; do
        remote_add "$name" "$ART/$name" || exit 1
    done
    printf '{"id":17,"node_id":"REPO17","full_name":"acme/tool"}\n' > "$REMOTE/repository.json"
    printf '[{"id":42,"tag_name":"v1.2.3"}]\n' > "$REMOTE/releases.json"
    cat > "$REMOTE/release.json" <<'JSON'
{"id":42,"node_id":"REL42","tag_name":"v1.2.3","draft":true,"prerelease":false,"target_commitish":"main","url":"https://api.github.com/repos/acme/tool/releases/42","upload_url":"https://uploads.github.com/repos/acme/tool/releases/42/assets{?name,label}"}
JSON
    printf '%040d\n' 1 > "$REMOTE/tag.sha"
    : > "$CASE/api.log"; : > "$CASE/downloads.log"
    MODE=''; DOWNLOAD_MODE=''; LATE_MODE=''
}
gh_api() {
    [[ $# -eq 2 && "$2" == --no-cache && "$GH_HOST" == github.com &&
       "$GH_TOKEN" == dsr-test-credential && "$GITHUB_TOKEN" == dsr-test-credential ]] || return 99
    printf '%s\n' "$1" >> "$CASE/api.log"
    local page
    case "$1" in
        repos/acme/tool)
            [[ "$MODE" != network ]] || return 8
            [[ "$MODE" != timeout ]] || { sleep 30; return 0; }
            cat "$REMOTE/repository.json"
            [[ "$MODE" != multiple-json ]] || cat "$REMOTE/repository.json" ;;
        'repos/acme/tool/releases?per_page=100&page='*)
            page="${1##*page=}"
            jq --argjson page "$page" '.[(($page-1)*100):($page*100)]' "$REMOTE/releases.json" ;;
        repos/acme/tool/releases/42) cat "$REMOTE/release.json" ;;
        'repos/acme/tool/releases/42/assets?per_page=100&page='*)
            page="${1##*page=}"
            [[ "$MODE" != second-page-failure || "$page" -ne 2 ]] || return 8
            if [[ "$MODE" == duplicate-page && "$page" -eq 2 ]]; then
                jq '.[0:3]' "$REMOTE/inventory.json"
            else
                jq --argjson page "$page" '.[(($page-1)*100):($page*100)]' "$REMOTE/inventory.json"
            fi ;;
        *) printf 'Unexpected fixture endpoint: %s\n' "$1" >&2; return 99 ;;
    esac
}
gh_resolve_tag_sha() {
    [[ "$1" == acme/tool && "$2" == v1.2.3 ]] || return 4
    cat "$REMOTE/tag.sha"
}
gh_download_release_asset() {
    local repo="$1" id="$2" path="$3" name
    [[ "$repo" == acme/tool && ! -e "$path" ]] || return 99
    printf '%s\n' "$id" >> "$CASE/downloads.log"
    case "$DOWNLOAD_MODE" in
        fail) return 8 ;;
        no-file) return 0 ;;
        corrupt) printf corrupt > "$path"; return 0 ;;
        symlink) ln -s "$REMOTE/bytes/$id" "$path"; return 0 ;;
        timeout)
            (trap '' TERM; sleep 30) &
            printf '%s\n' "$!" > "$CASE/descendant.pid"
            wait; return ;;
    esac
    cp "$REMOTE/bytes/$id" "$path" || return 1
    name=$(jq -r --argjson id "$id" '.[] | select(.id == $id) | .name' "$REMOTE/inventory.json")
    if [[ "$name" == b.tar.xz.sbom.* ]]; then
        case "$LATE_MODE" in
            tag) printf '%040d\n' 2 > "$REMOTE/tag.sha" ;;
            mode) jq '.draft = false' "$REMOTE/release.json" > "$REMOTE/release.next"; mv "$REMOTE/release.next" "$REMOTE/release.json" ;;
            repo) jq '.id = 99' "$REMOTE/repository.json" > "$REMOTE/repository.next"; mv "$REMOTE/repository.next" "$REMOTE/repository.json" ;;
            asset-id) jq '.[0].id = 9000' "$REMOTE/inventory.json" > "$REMOTE/inventory.next"; mv "$REMOTE/inventory.next" "$REMOTE/inventory.json" ;;
            extra) printf late > "$CASE/late.zip"; remote_add late.zip "$CASE/late.zip" ;;
        esac
    fi
}
check() {
    local description="$1"; shift
    checks=$((checks + 1))
    if "$@" >/dev/null 2>&1; then printf 'ok %d - %s\n' "$checks" "$description"; else
        printf 'not ok %d - %s\n' "$checks" "$description"
        failures=$((failures + 1))
        [[ ! -f "$CASE/stderr" ]] || tail -4 "$CASE/stderr" >&2
    fi
}
capture() {
    status=0
    "$@" > "$CASE/stdout" 2> "$CASE/stderr" || status=$?
    output=$(cat "$CASE/stdout")
}
verify() { sbom_verify_release --repo acme/tool --tag v1.2.3 --manifest-sha256 "$PIN" --format "$FORMAT" "$@"; }
nonzero() { [[ "$1" -ne 0 ]]; }
no_success() { [[ ! -s "$CASE/stdout" ]]; }
edit_inventory() {
    jq "$1" "$REMOTE/inventory.json" > "$REMOTE/inventory.next" && mv "$REMOTE/inventory.next" "$REMOTE/inventory.json"
}
set_remote_manifest() {
    local path="$1" id ext sha size
    ext=$(_sbom_extension "$FORMAT")
    id=$(jq -r --arg name "sbom-manifest.$ext" '.[] | select(.name == $name) | .id' "$REMOTE/inventory.json")
    cp "$path" "$REMOTE/bytes/$id"
    sha=$(_sbom_hash "$path"); PIN="$sha"
    size=$(wc -c < "$path")
    jq --argjson id "$id" --arg sha "$sha" --argjson size "$size" \
        'map(if .id == $id then .digest = ("sha256:" + $sha) | .size = $size else . end)' \
        "$REMOTE/inventory.json" > "$REMOTE/inventory.next" && mv "$REMOTE/inventory.next" "$REMOTE/inventory.json"
}
for format in spdx cyclonedx; do
    new_case "complete-$format" "$format"
    capture verify
    check "$format complete remote release verifies" test "$status" -eq 0
    check "$format verification returns one typed receipt" jq -es 'length == 1 and .[0].status == "verified" and .[0].artifact_count == 2' "$CASE/stdout"
    check "$format retains selected repository/tag identities" jq -e '.repository.id == 17 and .release.id == 42 and .release.tag_name == "v1.2.3"' "$CASE/stdout"
    check "$format downloads every document but uses API payload digests" test "$(wc -l < "$CASE/downloads.log")" -eq 3
    check "$format preserves caller token/host state" test "$GH_HOST" = enterprise.example.test
    check "$format output contains no authentication secrets" bash -c '! grep -F dsr-test-credential "$1"' bash "$CASE/stdout"
done
new_case no-pin
capture sbom_verify_release --repo acme/tool --tag v1.2.3
check 'missing manifest pin fails before reading GitHub' test "$status" -eq 4
check 'missing pin cannot make any API request' test ! -s "$CASE/api.log"
check 'missing pin emits no success receipt' no_success
capture verify --manifest-sha256 "$PIN"
check 'duplicate manifest pin rejected' test "$status" -eq 4
capture verify --repo evil/tool
check 'duplicate repository option rejected' test "$status" -eq 4
capture verify --format
check 'missing format value is invalid arguments' test "$status" -eq 4
capture verify --unknown
check 'unknown remote option is invalid arguments' test "$status" -eq 4
capture verify --format nonsense
check 'unsupported format is invalid arguments' test "$status" -eq 4
check 'invalid options made no API requests' test ! -s "$CASE/api.log"
new_case wrong-pin
PIN=$(printf '%064d' 0)
capture verify
check 'untrusted manifest digest cannot be substituted' test "$status" -eq 7
check 'digest mismatch is not weakened to a body download' test ! -s "$CASE/downloads.log"
check 'wrong pin emits no success receipt' no_success
new_case missing-digests
edit_inventory 'map(.digest = null)'
capture verify
check 'digest-less historical assets verify using immutable IDs' test "$status" -eq 0
check 'all digest-less payloads and documents are downloaded' test "$(wc -l < "$CASE/downloads.log")" -eq 5
for mutation in '.[:-1]' '.[0].state = "starter"' '.[0].digest = ("sha256:" + ("0" * 64))' '.[0].digest = "sha512:abc"' '.[0].size = -1' '. + [.[0]]' '.[0].name = "../escape"' '.[0].digest = {}'; do
    new_case "inventory-$checks"
    edit_inventory "$mutation"
    capture verify
    check "remote inventory rejects $mutation" nonzero "$status"
    check 'invalid remote inventory never emits success' no_success
done
new_case extra-payload
printf extra > "$CASE/extra.zip"; remote_add extra.zip "$CASE/extra.zip"
capture verify
check 'additional payload cannot be omitted from coverage' test "$status" -eq 7
new_case missing-payload
edit_inventory 'map(select(.name != "b.tar.xz"))'
capture verify
check 'missing payload cannot pass inventory verification' test "$status" -eq 7
new_case missing-document
edit_inventory 'map(select(.name != "b.tar.xz.sbom.spdx.json"))'
capture verify
check 'missing SBOM cannot pass inventory verification' test "$status" -eq 7
for mode in fail no-file corrupt symlink; do
    new_case "download-$mode"
    DOWNLOAD_MODE="$mode"
    capture verify
    check "$mode download outcome fails closed" nonzero "$status"
    check "$mode download outcome has no success JSON" no_success
done
new_case length
edit_inventory 'map(if .name == "sbom-manifest.spdx.json" then .size += 1 else . end)'
capture verify
check 'download size must match immutable-ID inventory size' test "$status" -eq 7
new_case cap
SBOM_REMOTE_MAX_DOCUMENT_BYTES=1
capture verify
check 'document byte limit is enforced before download' test "$status" -eq 7
check 'oversized document is not downloaded' test ! -s "$CASE/downloads.log"
SBOM_REMOTE_MAX_DOCUMENT_BYTES=67108864
new_case invalid-manifest
jq '.artifacts += [.artifacts[0]]' "$ART/sbom-manifest.spdx.json" > "$CASE/invalid.json"
set_remote_manifest "$CASE/invalid.json"
capture verify
check 'pinned manifest must satisfy complete-set contract' test "$status" -eq 7
new_case document-contract
printf '{"spdxVersion":true}' > "$CASE/bad-sbom.json"
sha=$(_sbom_hash "$CASE/bad-sbom.json"); size=$(wc -c < "$CASE/bad-sbom.json")
cp "$CASE/bad-sbom.json" "$REMOTE/bytes/103"
jq --arg sha "$sha" '.artifacts[0].sbom.sha256 = $sha' "$ART/sbom-manifest.spdx.json" > "$CASE/manifest.json"
set_remote_manifest "$CASE/manifest.json"
jq --arg sha "$sha" --argjson size "$size" 'map(if .id == 103 then .digest = ("sha256:" + $sha) | .size = $size else . end)' \
    "$REMOTE/inventory.json" > "$REMOTE/inventory.next"; mv "$REMOTE/inventory.next" "$REMOTE/inventory.json"
capture verify
check 'hash-consistent invalid SBOM is rejected' test "$status" -eq 7
for mutation in tag mode repo asset-id extra; do
    new_case "late-$mutation"
    LATE_MODE="$mutation"
    capture verify
    check "late $mutation change invalidates verification" test "$status" -eq 7
    check "late $mutation change has no success JSON" no_success
done
new_case published-release
jq '.draft = false | .prerelease = true' "$REMOTE/release.json" > "$REMOTE/release.next"; mv "$REMOTE/release.next" "$REMOTE/release.json"
capture verify
check 'published prereleases can be verified' test "$status" -eq 0
check 'verification reports actual release mode' jq -e '.release.draft == false and .release.prerelease == true' "$CASE/stdout"
new_case duplicate-tag
jq '. + [{id:43,tag_name:"v1.2.3"}]' "$REMOTE/releases.json" > "$REMOTE/releases.next"; mv "$REMOTE/releases.next" "$REMOTE/releases.json"
capture verify
check 'ambiguous release tag is not guessed' test "$status" -eq 7
new_case no-tag
printf '[]' > "$REMOTE/releases.json"
capture verify
check 'absent release fails rather than creating one' test "$status" -eq 7
new_case pagination
jq '[range(1;101) | {id:(1000+.),name:("extra-" + tostring + ".json"),state:"uploaded",size:0,digest:null}] + .' \
    "$REMOTE/inventory.json" > "$REMOTE/inventory.next"; mv "$REMOTE/inventory.next" "$REMOTE/inventory.json"
jq '[range(1;101) | {id:(1000+.),tag_name:("v0.0." + tostring)}] + .' \
    "$REMOTE/releases.json" > "$REMOTE/releases.next"; mv "$REMOTE/releases.next" "$REMOTE/releases.json"
capture verify
check 'release and asset pagination reach the selected complete set' test "$status" -eq 0
MODE=second-page-failure
capture verify
check 'failed later page is not interpreted as absence' test "$status" -eq 8
check 'failed later page emits no success' no_success
MODE=duplicate-page
capture verify
check 'repeated IDs across inventory pages fail closed' test "$status" -eq 7
for mode in network multiple-json; do
    new_case "$mode"
    MODE="$mode"
    capture verify
    check "$mode API response cannot be accepted" test "$status" -eq 8
    check "$mode API response emits no success" no_success
done
new_case api-deadline
MODE=timeout; SBOM_REMOTE_TIMEOUT=1; start=$SECONDS
capture verify
elapsed=$((SECONDS-start))
check 'blocked API terminates with interrupted/timeout status' test "$status" -eq 5
check 'API deadline bounds a stalled transport' test "$elapsed" -le 5
new_case download-deadline
DOWNLOAD_MODE=timeout; start=$SECONDS
capture verify
elapsed=$((SECONDS-start))
check 'blocked binary transfer terminates with interrupted/timeout status' test "$status" -eq 5
check 'binary deadline bounds the stalled child' test "$elapsed" -le 6
if [[ -f "$CASE/descendant.pid" ]]; then
    pid=$(cat "$CASE/descendant.pid")
    state=$(ps -o stat= -p "$pid" 2>/dev/null || true)
    check 'timeout leaves no running TERM-resistant transfer descendant' bash -c '[[ -z "$1" || "$1" == Z* ]]' bash "$state"
fi
SBOM_REMOTE_TIMEOUT=10
new_case caller-state
before_umask=$(umask); before_monitor=$(set +o | grep monitor)
capture verify
check 'verification preserves caller umask' test "$(umask)" = "$before_umask"
check 'verification preserves caller job-control policy' test "$(set +o | grep monitor)" = "$before_monitor"
check 'verification preserves caller credential precedence' test "$GH_TOKEN" = wrong-cli-credential
printf '\nRemote SBOM checks: %d; failures: %d\n' "$checks" "$failures"
[[ "$failures" -eq 0 ]]
