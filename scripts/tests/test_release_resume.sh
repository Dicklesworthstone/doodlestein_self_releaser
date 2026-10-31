#!/usr/bin/env bash
# Command-level release recovery tests. GitHub's network boundary is replaced;
# the production release command, upload reconciler, and byte hashing are real.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/src/github.sh"
source "$PROJECT_ROOT/src/config.sh"
source "$PROJECT_ROOT/src/artifact_naming.sh"
# cmd_release uses the runner's retained native inventory admission. Keep
# that production gate available even though lazy module loading is replaced
# below; only the existing network and configuration boundaries are fixtures.
source "$PROJECT_ROOT/src/act_runner.sh"
source "$PROJECT_ROOT/src/signing.sh"
source "$PROJECT_ROOT/src/sbom.sh"
# Exercise the production outbox even though lazy module loading below is a
# fixture. Only its HTTP boundary is replaced, alongside release asset uploads.
# shellcheck source=/dev/null
source "${DISPATCH_TEST_MODULE:-$PROJECT_ROOT/src/dispatch.sh}"
# Load the real command without dispatching the CLI or contacting build hosts.
# shellcheck source=/dev/null
source <(awk '/^cmd_release\(\) \{/{copy=1} copy{print} copy && /^\}/{exit}' "${DSR_TEST_COMMAND_FILE:-$PROJECT_ROOT/dsr}")
# shellcheck source=/dev/null
source <(awk '/^_source_release_read_private_receipt\(\) \{/{copy=1} copy{print} copy && /^\}/{exit}' "${DSR_TEST_COMMAND_FILE:-$PROJECT_ROOT/dsr}")
# shellcheck source=/dev/null
source <(awk '/^_release_prepare_ordinary_checksums\(\) \(/{copy=1} copy{print} copy && /^\)/{exit}' "${DSR_TEST_COMMAND_FILE:-$PROJECT_ROOT/dsr}")
# shellcheck source=/dev/null
source <(awk '/^_release_prepare_ordinary_sbom\(\) \(/{copy=1} copy{print} copy && /^\)/{exit}' "${DSR_TEST_HELPERS_FILE:-$PROJECT_ROOT/dsr}")
# shellcheck source=/dev/null
source <(awk '/^_release_sbom_policy\(\) \{/{copy=1} copy{print} copy && /^\}/{exit}' "${DSR_TEST_HELPERS_FILE:-$PROJECT_ROOT/dsr}")
# shellcheck source=/dev/null
source <(awk '/^_release_file_size\(\) \{/{copy=1} copy{print} copy && /^\}/{exit}' "${DSR_TEST_COMMAND_FILE:-$PROJECT_ROOT/dsr}")
# shellcheck source=/dev/null
source <(awk '/^_dispatch_[a-z_]+\(\) \{/{copy=1} copy{print} copy && /^\}/{copy=0}' "${DSR_TEST_COMMAND_FILE:-$PROJECT_ROOT/dsr}")
# shellcheck source=/dev/null
source <(awk '/^cmd_release_dispatch\(\) \{/{copy=1} copy{print} copy && /^\}/{exit}' "${DSR_TEST_COMMAND_FILE:-$PROJECT_ROOT/dsr}")

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dsr-release-resume-tests.XXXXXXXX") || exit 4
# Retain the isolated fixtures and request logs for failure diagnosis.
printf 'Fixtures: %s\n' "$TEST_ROOT"
PASS=0 FAIL=0
log_info() { printf 'INFO: %s\n' "$*" >&2; }
log_ok() { log_info "$@"; }
log_warn() { printf 'WARN: %s\n' "$*" >&2; }
log_error() { printf 'ERROR: %s\n' "$*" >&2; }
log_debug() { :; }
log_set_tool() { :; }
_dsr_require() { :; }
act_load_repo_config() { return 0; }
act_get_repo() { printf 'owner/repo\n'; }
act_get_local_path() { printf '\n'; }
config_validate_release_contract() { return 0; }
config_get_release_contract_json() { printf '%s\n' "${STRICT_CONTRACT:-null}"; }
git_ops_version_to_tag() { printf 'v%s\n' "${1#v}"; }
gh_check() { return 0; }
gh_check_token() { return 0; }
_gh_resolve_token() { printf 'fixture-token\n'; }
_gh_response_header() { :; }
_gh_retry_pause() { printf 'PAUSE\n' >> "$CALLS"; }
_gh_is_rate_limited() { return 1; }
_release_require_publishable_artifacts() { return 0; }
_release_contract_create_nonce() { printf '%064d\n' 1; }
_release_contract_preflight() { printf 'STRICT-PREFLIGHT\n' >> "$CALLS"; return 4; }
gh_resolve_tag_sha() {
    if [[ -n "${STAGED_SOURCE_SHA:-}" ]]; then
        case "$STAGED_REMOTE_MODE" in
            unavailable) return 8 ;;
            moved) printf '%040d\n' 1; return 0 ;;
            after-publish)
                if [[ "$(jq -r '.draft' "$CASE/release.json")" == false ]]; then
                    printf '%040d\n' 1; return 0
                fi ;;
            absent-*)
                [[ "$(jq -r '.draft' "$CASE/release.json")" == false ]] || return 8
                if [[ "$STAGED_REMOTE_MODE" == absent-wrong-created ]]; then
                    printf '%040d\n' 1; return 0
                fi ;;
        esac
        printf '%s\n' "$STAGED_SOURCE_SHA"
    else
        printf '%040d\n' 1
    fi
}
upgrade_verify_tool() { printf 'UPGRADE\n' >> "$CALLS"; }
json_envelope() {
    jq -nc --arg command "$1" --arg status "$2" --argjson exit_code "$3" \
        --argjson details "$4" '{command:$command,status:$status,exit_code:$exit_code,details:$details}'
}
artifact_naming_generate_dual_for_tool() {
    local arch="$4"
    [[ "${COLLIDE_NAMES:-false}" == true ]] && arch=amd64
    jq -nc --arg versioned "tool-${2#v}-$3-$arch.$5" --arg compat "tool-$3-$arch.$5" \
        '{versioned:$versioned,compat:$compat,same:($versioned==$compat)}'
}

setup() {
    CASE="$TEST_ROOT/$1"
    mkdir -p "$CASE/artifacts" "$CASE/remote" "$CASE/state/releases" "$CASE/tmp" "$CASE/config/repos.d" "$CASE/dispatch"
    export DSR_STATE_DIR="$CASE/state" TMPDIR="$CASE/tmp" NO_COLOR=1
    export DSR_CONFIG_DIR="$CASE/config" DSR_REPOS_FILE="$CASE/config/repos.yaml"
    export DSR_CONFIG_FILE="$CASE/config/config.yaml"
    export ACT_REPOS_DIR="$CASE/config/repos.d"
    # The real retained-inventory gate consults the configured execution
    # lane. These fixtures describe local native artifacts, not an act job.
    printf 'targets: [linux/amd64]\n' > "$ACT_REPOS_DIR/tool.yaml"
    CALLS="$CASE/calls"
    : > "$CALLS"
    : > "$CASE/dispatch-calls.jsonl"
    printf '[]\n' > "$CASE/inventory.json"
    jq -nc '{id:9,tag_name:"v1.2.3",draft:false,prerelease:false,
      upload_url:"https://uploads.github.com/repos/owner/repo/releases/9/assets{?name,label}",
      html_url:"https://github.com/owner/repo/releases/tag/v1.2.3",assets:[]}' > "$CASE/release.json"
    printf 'real payload\n' > "$CASE/artifacts/payload.bin"
    export JSON_MODE=true DRY_RUN=false
    export DSR_GH_TOKEN=fixture-token DSR_RUN_ID=fixture-process
    export DSR_DISPATCH_ENABLED=true DSR_DISPATCH_EVENT=release-ready DSR_DISPATCH_REPOS=owner/downstream
    export DISPATCH_MAX_RETRIES=2 DISPATCH_RETRY_DELAY=0 DISPATCH_MAX_WAIT=0 DISPATCH_TIMEOUT=2
    unset DISPATCH_STATE_DIR
    DISPATCH_MODE=success DISPATCH_FAILURE_REPO=owner/b RELEASE_TEST_VERSION=1.2.3
    # Read by config_get and the command functions sourced dynamically above.
    # shellcheck disable=SC2034
    DSR_CONFIG=()
    STRICT_CONTRACT=null COLLIDE_NAMES=false
    LOOKUP_FAIL=false INVENTORY_FAIL=false UPLOAD_FAIL=false LOST_RESPONSE=false
    CREATE_FAIL=true FINAL_DRIFT=false VISIBILITY_DRIFT=false FAIL_NAME=""
    LOST_CREATE_RESPONSE=false PUBLISH_FAIL=false LOST_PUBLISH_RESPONSE=false
    PUBLISH_ASSET_DRIFT=false PUBLISH_METADATA_DRIFT=false UPLOAD_METADATA_DRIFT=false
    UPLOAD_DESTINATION_DRIFT=false PUBLISH_DESTINATION_DRIFT=false
    EXTRA_ASSET=false DROP_SIDECAR="" CREATE_INTENT_DRIFT=false
    CONCURRENT_PUBLISH=false STAGED_SOURCE_SHA="" STAGED_REMOTE_MODE=valid
    export DSR_RELEASE_STATE_RETRY_DELAY_SECONDS=0
    export GH_MAX_RETRIES=2 GH_RETRY_DELAY=0
}

remote_put() {
    local name="$1" file="$2" digest="${3:-true}" id sha size
    id=$(jq 'length + 100' "$CASE/inventory.json") || return 1
    sha=$(_gh_asset_sha256 "$file") || return 1
    size=$(wc -c < "$file")
    cp "$file" "$CASE/remote/$id" || return 1
    jq --arg name "$name" --argjson id "$id" --argjson size "$size" \
        --arg sha "$sha" --argjson digest "$digest" \
        '. + [{id:$id,name:$name,state:"uploaded",size:$size,
               digest:(if $digest then "sha256:"+$sha else null end)}]' \
        "$CASE/inventory.json" > "$CASE/inventory.next" && \
        mv "$CASE/inventory.next" "$CASE/inventory.json"
}

journal() {
    jq -nc --arg name "$1" '{uploaded:[{name:$name,status:"uploaded"}]}' > \
        "$DSR_STATE_DIR/releases/tool-v1.2.3-upload.json"
}

manifest() {
    local name="$1" target="${2:-}" format="${3:-none}" sha size
    sha=$(_gh_asset_sha256 "$CASE/artifacts/$name") || return 1
    size=$(wc -c < "$CASE/artifacts/$name") || return 1
    jq -nc --arg name "$name" --arg sha "$sha" --arg target "$target" --arg format "$format" \
        --argjson size "$size" \
        '{tool:"tool",version:"v1.2.3",status:"success",
          artifacts:[{name:$name,sha256:$sha,size_bytes:$size,target:$target,archive_format:$format}]}' > \
        "$CASE/artifacts/tool-v1.2.3-manifest.json"
}

# Build packaging materializes every final alias before the manifest is
# frozen. Preserve the owning artifact's bytes, size and target identity.
manifest_alias() {
    local original="$1" alias="$2" manifest_file="$CASE/artifacts/tool-v1.2.3-manifest.json"
    cp "$CASE/artifacts/$original" "$CASE/artifacts/$alias" || return 1
    jq --arg original "$original" --arg alias "$alias" \
        '.artifacts += [.artifacts[] | select(.name == $original) | .name=$alias]' \
        "$manifest_file" > "$CASE/manifest.next" &&
        mv "$CASE/manifest.next" "$manifest_file"
}

_release_contract_scan_release_by_tag() {
    printf 'SCAN %s %s\n' "$1" "$2" >> "$CALLS"
    $LOOKUP_FAIL && return 8
    jq -nc --slurpfile release "$CASE/release.json" '{count:1,release:$release[0]}'
}

gh_create_release() (
    { printf 'CREATE'; printf ' %q' "$@"; printf '\n'; } >> "$CALLS"
    $CREATE_FAIL && return 22
    # Exercise the real POST builder, transport response file and private
    # retention validator. Only GitHub's actual network boundary is replaced.
    source "$PROJECT_ROOT/src/github.sh"
    gh_check() { return 0; }
    _gh_api_with_gh() {
        [[ "$1" == repos/owner/repo/releases && "$2" == POST ]] || return 8
        printf '%s\n' "$3" > "$CASE/create-request.json"
        jq --argjson request "$3" '. + $request | .assets=[] |
            .html_url="https://github.com/owner/repo/releases/tag/untagged-0123456789abcdef0123"' \
            "$CASE/release.json" > "$CASE/release.next" || return 8
        mv "$CASE/release.next" "$CASE/release.json" || return 8
        if [[ -n "$DROP_SIDECAR" ]]; then
            mv "$CASE/artifacts/$DROP_SIDECAR" "$CASE/dropped-sidecar" || return 8
        fi
        if $CREATE_INTENT_DRIFT; then
            jq '.publish=(.publish|not)' "$TMPDIR/intent.json" > "$TMPDIR/intent.next" || return 8
            chmod 600 "$TMPDIR/intent.next" || return 8
            mv "$TMPDIR/intent.next" "$TMPDIR/intent.json" || return 8
        fi
        $LOST_CREATE_RESPONSE && return 8
        cat "$CASE/release.json"
    }
    gh_create_release "$@"
)

gh_api() {
    printf 'API %s\n' "$*" >> "$CALLS"
    local endpoint="$1" method=GET data=""
    shift
    while (($#)); do
        case "$1" in
            --method) method="$2"; shift 2 ;;
            --data) data="$2"; shift 2 ;;
            --post) method=POST; data="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    if [[ "$method" == PATCH ]]; then
        [[ "$endpoint" == repos/owner/repo/releases/9 ]] || return 8
        if [[ "$data" == '{"draft":false}' ]]; then
            printf 'PUBLISH\n' >> "$CALLS"
            $PUBLISH_FAIL && return 8
        else
            [[ "$data" == '{"draft":true}' ]] || return 8
            printf 'RESTORE-DRAFT\n' >> "$CALLS"
        fi
        jq --argjson patch "$data" '. + $patch |
            .html_url=(if .draft then "https://github.com/owner/repo/releases/tag/untagged-fedcba9876543210"
                       else "https://github.com/owner/repo/releases/tag/v1.2.3" end)' \
            "$CASE/release.json" > "$CASE/release.next" &&
            mv "$CASE/release.next" "$CASE/release.json" || return 8
        if [[ "$data" == '{"draft":false}' ]]; then
            if $PUBLISH_ASSET_DRIFT; then
                jq 'map(.digest="sha256:"+("0"*64))' "$CASE/inventory.json" > "$CASE/inventory.next" &&
                    mv "$CASE/inventory.next" "$CASE/inventory.json" || return 8
            fi
            if $PUBLISH_METADATA_DRIFT; then
                jq '.body="Another publisher changed these notes"' "$CASE/release.json" > "$CASE/release.next" &&
                    mv "$CASE/release.next" "$CASE/release.json" || return 8
            fi
            if $PUBLISH_DESTINATION_DRIFT; then
                jq '.html_url="https://github.com/another/repo/releases/tag/v1.2.3"' \
                    "$CASE/release.json" > "$CASE/release.next" &&
                    mv "$CASE/release.next" "$CASE/release.json" || return 8
            fi
            $LOST_PUBLISH_RESPONSE && return 8
        fi
        cat "$CASE/release.json"
        return 0
    fi
    case "$endpoint" in
        repos/*/dispatches)
            # Keep the old network boundary usable as a negative control: an
            # adapter which still sends statelessly must expose real repeats.
            [[ "$method" == POST ]] || return 8
            local destination="${endpoint#repos/}" code
            destination="${destination%/dispatches}"
            code=$(dispatch_fixture_response "$destination" "$data") || return $?
            [[ "$code" == 204 ]] || return 7
            ;;
        repos/owner/repo/git/matching-refs/tags/v1.2.3)
            printf 'TAG-ABSENCE\n' >> "$CALLS"
            case "$STAGED_REMOTE_MODE" in
                absent-unavailable) return 8 ;;
                absent-malformed) printf '[{"ref":"refs/tags/v1.2.3-rc.1","object":{"sha":"short"}}]\n' ;;
                absent-nonarray) printf '{}\n' ;;
                absent-prefix|absent-exact|absent-wrong-realm)
                    local suffix='-rc.1' remote_repo='owner/repo'
                    [[ "$STAGED_REMOTE_MODE" != absent-exact ]] || suffix=''
                    [[ "$STAGED_REMOTE_MODE" != absent-wrong-realm ]] || remote_repo='another/repo'
                    jq -nc --arg ref "refs/tags/v1.2.3$suffix" --arg repo "$remote_repo" --arg sha "$STAGED_SOURCE_SHA" \
                        '[{ref:$ref,url:("https://api.github.com/repos/"+$repo+"/git/"+$ref),
                           object:{type:"commit",sha:$sha,url:("https://api.github.com/repos/"+$repo+"/git/commits/"+$sha)}}]' ;;
                absent-empty|absent-wrong-created) printf '[]\n' ;;
                *) return 8 ;;
            esac
            ;;
        repos/owner/repo/releases/9/assets\?per_page=100\&page=*)
            $INVENTORY_FAIL && return 8
            local page="${endpoint##*page=}"
            if $FINAL_DRIFT && [[ -f "$CASE/post-complete" ]]; then
                jq 'map(.digest="sha256:"+("0"*64))' "$CASE/inventory.json" > "$CASE/inventory.next"
                mv "$CASE/inventory.next" "$CASE/inventory.json"
            fi
            jq --argjson page "$page" '.[(($page-1)*100):($page*100)]' "$CASE/inventory.json"
            ;;
        repos/owner/repo/releases/tags/v1.2.3|repos/owner/repo/releases/9)
            if $VISIBILITY_DRIFT && [[ -f "$CASE/post-complete" ]]; then
                jq '.draft=true' "$CASE/release.json"
            else
                cat "$CASE/release.json"
            fi
            ;;
        repos/owner/repo/releases/assets/*)
            # Negative-control behavior: old cmd_release deletes valid assets.
            local id="${endpoint##*/}"
            jq --argjson id "$id" '[.[] | select(.id != $id)]' "$CASE/inventory.json" > "$CASE/inventory.next" &&
                mv "$CASE/inventory.next" "$CASE/inventory.json"
            ;;
        *) return 8 ;;
    esac
}

gh_download_release_asset() {
    printf 'DOWNLOAD %s %s\n' "$1" "$2" >> "$CALLS"
    [[ ! -e "$3" ]] && cp "$CASE/remote/$2" "$3"
}

dispatch_fixture_response() {
    local destination="$1" body="$2" code=204 rc=0
    printf 'DISPATCH\nDISPATCH-URL %s\n' "$(jq -r '.client_payload.release_url' <<< "$body")" >> "$CALLS"
    jq -c --arg destination "$destination" '. + {destination:$destination}' <<< "$body" >> "$CASE/dispatch-calls.jsonl" || return 4
    printf '%s' "$body" > "$CASE/dispatch/${destination//\//_}.json" || return 4
    if [[ "$destination" == "$DISPATCH_FAILURE_REPO" ]]; then
        case "$DISPATCH_MODE" in
            reject) code=422 ;;
            uncertain) code=000; rc=28 ;;
        esac
    fi
    if [[ "$DISPATCH_MODE" == draft-after-first && "$destination" == owner/a ]]; then
        jq '.draft=true' "$CASE/release.json" > "$CASE/dispatch-release.next" &&
            mv "$CASE/dispatch-release.next" "$CASE/release.json" || return 4
    fi
    printf '%s' "$code"
    return "$rc"
}

curl() {
    local response="" headers="" payload="" url="" arg name
    while (($#)); do
        arg="$1"; shift
        case "$arg" in
            -o|--output) response="$1"; shift ;;
            -D|--dump-header) headers="$1"; shift ;;
            --data-binary) payload="${1#@}"; shift ;;
            https://uploads.github.com/*) url="$arg" ;;
            https://api.github.com/repos/*/dispatches) url="$arg" ;;
        esac
    done
    [[ -n "$response" && -n "$headers" && -n "$payload" && -n "$url" ]] || return 4
    if [[ "$url" == https://api.github.com/repos/*/dispatches ]]; then
        local destination="${url#https://api.github.com/repos/}" body code rc=0
        destination="${destination%/dispatches}"
        # Dispatch passes private curl configuration on stdin. Consume it
        # without persisting credentials in request logs or assertion output.
        cat >/dev/null
        body=$(cat "$payload") || return 4
        code=$(dispatch_fixture_response "$destination" "$body") || rc=$?
        printf 'HTTP/2 %s\r\n\r\n' "$code" > "$headers"
        printf '{}' > "$response"
        printf '%s' "$code"
        return "$rc"
    fi
    name="${url##*?name=}"
    name="${name//%2B/+}"
    printf 'POST %s\n' "$name" >> "$CALLS"
    printf 'UPLOAD-VISIBILITY %s %s\n' "$name" "$(jq -r '.draft' "$CASE/release.json")" >> "$CALLS"
    printf 'HTTP/1.1 201 Created\r\n\r\n' > "$headers"
    if $UPLOAD_FAIL || [[ "$name" == "$FAIL_NAME" ]]; then printf '503'; return 0; fi
    remote_put "$name" "$payload" || return 4
    jq -c '.[-1]' "$CASE/inventory.json" > "$response"
    if $EXTRA_ASSET && ! jq -e 'any(.[]; .name=="unexpected.bin")' "$CASE/inventory.json" >/dev/null; then
        remote_put unexpected.bin "$payload" || return 4
    fi
    if $UPLOAD_METADATA_DRIFT; then
        jq '.body="Another publisher changed these notes"' "$CASE/release.json" > "$CASE/release.next" &&
            mv "$CASE/release.next" "$CASE/release.json" || return 4
    fi
    if $UPLOAD_DESTINATION_DRIFT; then
        jq '.html_url="https://github.com/another/repo/releases/tag/v1.2.3"' \
            "$CASE/release.json" > "$CASE/release.next" &&
            mv "$CASE/release.next" "$CASE/release.json" || return 4
    fi
    if $CONCURRENT_PUBLISH; then
        jq '.draft=false | .html_url="https://github.com/owner/repo/releases/tag/v1.2.3"' \
            "$CASE/release.json" > "$CASE/release.next" &&
            mv "$CASE/release.next" "$CASE/release.json" || return 4
    fi
    : > "$CASE/post-complete"
    if $LOST_RESPONSE; then printf '000'; return 28; fi
    printf '201'
}

run_release() {
    STATUS=0
    # Cases without a build manifest exercise the explicit --no-manifest
    # upload of a directory as-is.
    local -a manifest_args=()
    [[ -f "$CASE/artifacts/tool-v1.2.3-manifest.json" ]] || manifest_args=(--no-manifest)
    cmd_release tool "$RELEASE_TEST_VERSION" --artifacts "$CASE/artifacts" ${manifest_args[@]+"${manifest_args[@]}"} "$@" \
        > "$CASE/stdout" 2> "$CASE/stderr" || STATUS=$?
}

run_dispatch_recovery() {
    STATUS=0
    cmd_release_dispatch "$@" > "$CASE/stdout" 2> "$CASE/stderr" || STATUS=$?
}

run_test() {
    local name="$1"
    if ( "$name" ); then
        PASS=$((PASS+1)); printf 'PASS: %s\n' "$name"
    else
        FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$name"
    fi
}

test_saved_name_missing_remotely_is_uploaded() {
    setup missing
    journal payload.bin
    run_release --resume
    [[ $STATUS -eq 0 ]] && grep -Fxq 'POST payload.bin' "$CALLS" &&
        ! grep -q '^CREATE' "$CALLS" &&
        jq -es 'length == 1 and .[0].details.success == 1' "$CASE/stdout" >/dev/null
}

test_identical_remote_is_reused_without_deletion() {
    setup identical
    remote_put payload.bin "$CASE/artifacts/payload.bin"
    jq --slurpfile assets "$CASE/inventory.json" '.assets=$assets[0]' "$CASE/release.json" > "$CASE/release.next"
    mv "$CASE/release.next" "$CASE/release.json"
    run_release --resume
    [[ $STATUS -eq 0 ]] && ! grep -q '^POST\|--method DELETE' "$CALLS" &&
        grep -q 'assets?per_page=100&page=1 --no-cache' "$CALLS"
}

test_saved_name_with_changed_remote_fails_closed() {
    setup changed
    journal payload.bin
    printf 'fake payload\n' > "$CASE/different"
    remote_put payload.bin "$CASE/different"
    run_release --resume
    [[ $STATUS -eq 1 ]] && ! grep -q '^POST\|^DISPATCH\|--method DELETE' "$CALLS" &&
        [[ -s "$DSR_STATE_DIR/releases/tool-v1.2.3-upload.json" ]] &&
        jq -e '.status=="partial" and .details.failed==1' "$CASE/stdout" >/dev/null
}

test_legacy_digestless_assets_are_hashed() {
    setup digestless
    remote_put payload.bin "$CASE/artifacts/payload.bin" false
    journal payload.bin
    run_release --resume
    [[ $STATUS -eq 0 ]] && grep -q '^DOWNLOAD owner/repo 100$' "$CALLS" && ! grep -q '^POST' "$CALLS"
}

test_unavailable_inventory_is_not_success() {
    setup inventory
    journal payload.bin
    INVENTORY_FAIL=true
    run_release --resume
    [[ $STATUS -eq 1 ]] && ! grep -q '^POST\|^DISPATCH' "$CALLS"
}

test_failed_resume_lookup_never_creates() {
    setup lookup
    LOOKUP_FAIL=true
    run_release --resume
    [[ $STATUS -eq 7 ]] && ! grep -q '^CREATE\|^POST\|^DISPATCH' "$CALLS"
}

test_draft_resume_does_not_dispatch_or_verify_upgrade() {
    setup draft
    jq '.draft=true | .prerelease=true' "$CASE/release.json" > "$CASE/release.next"
    mv "$CASE/release.next" "$CASE/release.json"
    run_release --resume --verify-upgrade
    [[ $STATUS -eq 0 && ! -e "$DSR_STATE_DIR/dispatch" ]] && ! grep -q '^DISPATCH\|^UPGRADE' "$CALLS" &&
        jq -e '.details.draft==true and .details.prerelease==true and
            .details.dispatch.status=="skipped"' "$CASE/stdout" >/dev/null
}

test_named_upload_emits_one_json_envelope() {
    setup aliases
    mv "$CASE/artifacts/payload.bin" "$CASE/artifacts/tool-linux-amd64.tar.gz"
    manifest tool-linux-amd64.tar.gz linux/amd64 tar.gz
    manifest_alias tool-linux-amd64.tar.gz tool-1.2.3-linux-amd64.tar.gz || return 1
    manifest_alias tool-linux-amd64.tar.gz tool-linux-x86_64.tar.gz || return 1
    run_release --resume
    [[ $STATUS -eq 0 ]] && jq -es 'length==1 and .[0].command=="release"' "$CASE/stdout" >/dev/null &&
        grep -Fxq 'POST tool-1.2.3-linux-amd64.tar.gz' "$CALLS" &&
        grep -Fxq 'POST tool-linux-x86_64.tar.gz' "$CALLS"
}

test_missing_manifest_artifact_blocks_creation() {
    setup absent_local
    manifest missing.bin 2>/dev/null || true
    printf '{"artifacts":[{"name":"missing.bin","sha256":"%064d"}]}\n' 0 > "$CASE/artifacts/tool-v1.2.3-manifest.json"
    run_release
    [[ $STATUS -eq 4 ]] && [[ ! -s "$CALLS" ]]
}

test_changed_local_manifest_artifact_blocks_creation() {
    setup changed_local
    manifest payload.bin
    printf 'different\n' > "$CASE/artifacts/payload.bin"
    run_release
    [[ $STATUS -eq 4 ]] && [[ ! -s "$CALLS" ]]
}

test_wrong_release_identity_cannot_upload() {
    setup wrong_release
    jq '.tag_name="v9.9.9"' "$CASE/release.json" > "$CASE/release.next"
    mv "$CASE/release.next" "$CASE/release.json"
    run_release --resume
    [[ $STATUS -eq 7 ]] && ! grep -q '^POST\|^DISPATCH' "$CALLS"
}

test_lost_upload_response_reconciles_real_bytes() {
    setup lost
    LOST_RESPONSE=true
    run_release --resume
    [[ $STATUS -eq 0 ]] && [[ $(grep -c '^POST' "$CALLS") -eq 1 ]] &&
        jq -e '.details.success==1' "$CASE/stdout" >/dev/null
}

test_strict_preflight_remains_required() {
    setup strict
    STRICT_CONTRACT='{}'
    manifest payload.bin
    run_release --resume
    [[ $STATUS -eq 4 ]] && grep -Fxq 'STRICT-PREFLIGHT' "$CALLS" && ! grep -q '^SCAN\|^CREATE\|^POST' "$CALLS"
}

test_dry_run_has_no_network_or_checkpoint_writes() {
    setup dryrun
    manifest payload.bin
    DRY_RUN=true
    run_release --resume
    [[ $STATUS -eq 0 && ! -s "$CALLS" && ! -e "$CASE/artifacts/SHA256SUMS" ]] &&
        jq -e '.status=="dry_run"' "$CASE/stdout" >/dev/null
}

# bd-1tv.3.5: the plan lists every name each artifact is published under,
# the same list the upload loop uses, without touching GitHub or the disk.
test_dry_run_plans_every_upload_name() {
    setup dryrun_plan
    mv "$CASE/artifacts/payload.bin" "$CASE/artifacts/tool-linux-amd64.tar.gz"
    manifest tool-linux-amd64.tar.gz linux/amd64 tar.gz
    manifest_alias tool-linux-amd64.tar.gz tool-1.2.3-linux-amd64.tar.gz || return 1
    manifest_alias tool-linux-amd64.tar.gz tool-linux-x86_64.tar.gz || return 1
    DRY_RUN=true
    run_release --resume
    [[ $STATUS -eq 0 && ! -s "$CALLS" && ! -e "$CASE/artifacts/SHA256SUMS" ]] &&
        jq -e '.status=="dry_run" and .details.dry_run and .details.plan.strict==false and
            .details.plan.artifacts[0].upload_names ==
                ["tool-linux-amd64.tar.gz","tool-1.2.3-linux-amd64.tar.gz","tool-linux-x86_64.tar.gz"] and
            .details.plan.artifacts[0].target=="linux/amd64" and
            (.details.plan.artifacts[0].sha256 | test("^[0-9a-f]{64}$")) and
            (.details.plan.additional_files | index("tool-v1.2.3-manifest.json")) != null and
            .details.installer_check.status=="skipped"' "$CASE/stdout" >/dev/null &&
        grep -q 'also as: tool-1.2.3-linux-amd64.tar.gz, tool-linux-x86_64.tar.gz' "$CASE/stderr"
}

# bd-1tv.10: names the project's installer downloads are checked against
# the plan and, after upload, against the verified release. A mismatch warns
# with guidance but never turns a verified release into a failure.
installer_fixture() {
    git init -q "$CASE/checkout" &&
        git -C "$CASE/checkout" -c user.name=t -c user.email=t@example.invalid \
            commit -q --allow-empty -m fixture &&
        git -C "$CASE/checkout" tag v1.2.3 || return 1
    act_get_local_path() { printf '%s\n' "$CASE/checkout"; }
    git_ops_tag_exists() { git -C "$1" rev-parse -q --verify "refs/tags/$2" >/dev/null; }
    artifact_naming_installer_expected_name() {
        jq -nc --arg name "$INSTALLER_EXPECTS" \
            '{script:"install.sh",pattern:"x",name:$name,ext:"tar.gz",ext_mismatch:false}'
    }
    mv "$CASE/artifacts/payload.bin" "$CASE/artifacts/tool-linux-amd64.tar.gz"
    manifest tool-linux-amd64.tar.gz linux/amd64 tar.gz
    manifest_alias tool-linux-amd64.tar.gz tool-1.2.3-linux-amd64.tar.gz || return 1
    manifest_alias tool-linux-amd64.tar.gz tool-linux-x86_64.tar.gz || return 1
}

test_dry_run_reports_installer_mismatch() {
    setup installer_dry
    installer_fixture
    INSTALLER_EXPECTS=tool-x86_64-unknown-linux-gnu.tar.gz
    DRY_RUN=true
    run_release --resume
    [[ $STATUS -eq 0 && ! -s "$CALLS" ]] &&
        jq -e '.details.installer_check.status=="mismatch" and
            .details.installer_check.missing==["tool-x86_64-unknown-linux-gnu.tar.gz"]' \
            "$CASE/stdout" >/dev/null &&
        grep -q 'downloads tool-x86_64-unknown-linux-gnu.tar.gz, which this release does not publish' "$CASE/stderr" &&
        grep -q 'install_script_compat' "$CASE/stderr"
}

test_release_records_installer_check_after_upload() {
    setup installer_upload
    installer_fixture
    INSTALLER_EXPECTS=tool-linux-x86_64.tar.gz
    run_release --resume
    [[ $STATUS -eq 0 ]] && grep -Fxq 'POST tool-linux-x86_64.tar.gz' "$CALLS" &&
        jq -e '.details.installer_check.status=="ok" and
            .details.installer_check.expected==[{target:"linux/amd64",name:"tool-linux-x86_64.tar.gz",
                target_triple:"x86_64-unknown-linux-gnu",present:true,ext_mismatch:false}]' "$CASE/stdout" >/dev/null
}

test_installer_mismatch_does_not_fail_verified_release() {
    setup installer_mismatch
    installer_fixture
    INSTALLER_EXPECTS=tool-linux-x86_64.tar.xz
    run_release --resume
    [[ $STATUS -eq 0 ]] &&
        jq -e '.status=="success" and .details.installer_check.status=="mismatch"' "$CASE/stdout" >/dev/null &&
        grep -q 'downloads tool-linux-x86_64.tar.xz' "$CASE/stderr"
}

# bd-cdcz: gnu and musl builds of one platform. Each is published under the
# names of its own variant; a name both derive (naming without
# ${target_triple}) goes to the artifact it already names, else to the
# primary variant -- never to manifest order or a same-name upload failure.
variant_fixture() {
    artifact_naming_artifact_variant() {
        case "$4" in
            *musl*) printf 'x86_64-unknown-linux-musl\tlibc\n' ;;
            *) printf 'x86_64-unknown-linux-gnu\tprimary\n' ;;
        esac
    }
    config_get_target_triple() { printf 'x86_64-unknown-linux-gnu\n'; }
    config_get_target_triples_json() {
        printf '["x86_64-unknown-linux-gnu","x86_64-unknown-linux-musl"]\n'
    }
    artifact_naming_generate_dual_for_variant() {
        local platform="$3-$4"
        [[ "$TRIPLE_NAMING" == true ]] && platform="$7"
        jq -nc --arg versioned "tool-${2#v}-$platform.$5" --arg compat "tool-$platform.$5" \
            '{versioned:$versioned,compat:$compat,same:($versioned==$compat)}'
    }
    local name rows='[]' sha size triple primary=""
    mv "$CASE/artifacts/payload.bin" "$CASE/unselected-payload.bin" || return 1
    for name in "$@"; do
        printf '%s payload\n' "$name" > "$CASE/artifacts/$name"
        sha=$(_gh_asset_sha256 "$CASE/artifacts/$name") || return 1
        size=$(wc -c < "$CASE/artifacts/$name") || return 1
        triple=$(artifact_naming_artifact_variant tool linux amd64 "$name") || return 1
        triple="${triple%%$'\t'*}"
        [[ "$triple" != x86_64-unknown-linux-gnu ]] || primary="$name"
        rows=$(jq -c --arg name "$name" --arg sha "$sha" --arg triple "$triple" --argjson size "$size" \
            '. + [{name:$name,sha256:$sha,size_bytes:$size,target:"linux/amd64",target_triple:$triple,
                   archive_format:"tar.gz"}]' <<< "$rows")
    done
    jq -nc --argjson rows "$rows" '{tool:"tool",version:"v1.2.3",status:"success",artifacts:$rows}' > \
        "$CASE/artifacts/tool-v1.2.3-manifest.json" || return 1
    if [[ "$TRIPLE_NAMING" == true ]]; then
        for name in "$@"; do
            manifest_alias "$name" "${name/tool-1.2.3-/tool-}" || return 1
        done
    else
        [[ -n "$primary" ]] || return 1
        manifest_alias "$primary" tool-linux-amd64.tar.gz || return 1
        manifest_alias "$primary" tool-linux-x86_64.tar.gz || return 1
    fi
}

planned_names() {
    jq -c --arg name "$1" '.details.plan.artifacts[] | select(.name == $name) | .upload_names' "$CASE/stdout"
}

test_variants_publish_under_their_own_triple_names() {
    setup variant_triples
    TRIPLE_NAMING=true
    variant_fixture tool-1.2.3-x86_64-unknown-linux-musl.tar.gz tool-1.2.3-x86_64-unknown-linux-gnu.tar.gz
    DRY_RUN=true
    run_release --resume
    [[ $STATUS -eq 0 ]] &&
        [[ "$(planned_names tool-1.2.3-x86_64-unknown-linux-musl.tar.gz)" == \
            '["tool-1.2.3-x86_64-unknown-linux-musl.tar.gz","tool-x86_64-unknown-linux-musl.tar.gz"]' ]] &&
        [[ "$(planned_names tool-1.2.3-x86_64-unknown-linux-gnu.tar.gz)" == \
            '["tool-1.2.3-x86_64-unknown-linux-gnu.tar.gz","tool-x86_64-unknown-linux-gnu.tar.gz"]' ]]
}

test_shared_variant_names_go_to_the_primary_build() {
    setup variant_shared
    TRIPLE_NAMING=false
    # The musl row comes first: manifest order must not pick the bytes.
    variant_fixture tool-1.2.3-linux-amd64-musl.tar.gz tool-1.2.3-linux-amd64.tar.gz
    DRY_RUN=true
    run_release --resume
    local gnu_sha musl_sha alias
    gnu_sha=$(_gh_asset_sha256 "$CASE/artifacts/tool-1.2.3-linux-amd64.tar.gz") || return 1
    musl_sha=$(_gh_asset_sha256 "$CASE/artifacts/tool-1.2.3-linux-amd64-musl.tar.gz") || return 1
    [[ $STATUS -eq 0 ]] &&
        [[ "$gnu_sha" != "$musl_sha" ]] &&
        [[ "$(planned_names tool-1.2.3-linux-amd64-musl.tar.gz)" == '["tool-1.2.3-linux-amd64-musl.tar.gz"]' ]] || return 1
    # A frozen manifest has a real row for each final alias. The exact name
    # therefore owns itself; byte and target ownership must still be GNU,
    # irrespective of manifest order or which primary row derived the name.
    for alias in tool-linux-amd64.tar.gz tool-linux-x86_64.tar.gz; do
        [[ "$(_gh_asset_sha256 "$CASE/artifacts/$alias")" == "$gnu_sha" ]] || return 1
        jq -e --arg alias "$alias" --arg sha "$gnu_sha" --arg musl "$musl_sha" '
            [.details.plan.artifacts[] | select(.upload_names | index($alias))] as $owners |
            ($owners | length) == 1 and
            ($owners[0] | .name == $alias and .sha256 == $sha and .sha256 != $musl and
                .target_triple == "x86_64-unknown-linux-gnu" and
                ([.upload_names[] | select(. == $alias)] | length) == 1)
        ' "$CASE/stdout" >/dev/null || return 1
    done
}

test_shared_variant_names_upload_without_collision() {
    setup variant_upload
    TRIPLE_NAMING=false
    variant_fixture tool-1.2.3-linux-amd64-musl.tar.gz tool-1.2.3-linux-amd64.tar.gz
    run_release --resume
    local gnu_sha compat_sha alias remote_id
    gnu_sha=$(_gh_asset_sha256 "$CASE/artifacts/tool-1.2.3-linux-amd64.tar.gz")
    compat_sha=$(jq -r '.[] | select(.name == "tool-linux-amd64.tar.gz") | .digest' "$CASE/inventory.json")
    [[ $STATUS -eq 0 && "$compat_sha" == "sha256:$gnu_sha" ]] &&
        [[ "$(grep -c '^POST tool-linux-amd64.tar.gz$' "$CALLS")" == 1 ]] &&
        grep -Fxq 'POST tool-1.2.3-linux-amd64-musl.tar.gz' "$CALLS" &&
        grep -q "^$gnu_sha  tool-linux-amd64.tar.gz\$" "$CASE/artifacts/SHA256SUMS" &&
        ! grep -q 'Different artifact contents' "$CASE/stderr" || return 1
    for alias in tool-linux-amd64.tar.gz tool-linux-x86_64.tar.gz; do
        remote_id=$(jq -er --arg alias "$alias" '.[] | select(.name == $alias) | .id' "$CASE/inventory.json") || return 1
        [[ "$(grep -Fxc "POST $alias" "$CALLS")" == 1 ]] &&
            cmp -s "$CASE/remote/$remote_id" "$CASE/artifacts/tool-1.2.3-linux-amd64.tar.gz" &&
            ! cmp -s "$CASE/remote/$remote_id" "$CASE/artifacts/tool-1.2.3-linux-amd64-musl.tar.gz" || return 1
    done
    # An alias mentioned in the manifest but no longer materialized cannot be
    # claimed as verified GNU on retry. Retain the successful request evidence.
    mv "$CALLS" "$CASE/verified-upload.calls" &&
        mv "$CASE/stdout" "$CASE/verified-upload.stdout" &&
        mv "$CASE/stderr" "$CASE/verified-upload.stderr" &&
        mv "$CASE/artifacts/tool-linux-amd64.tar.gz" "$CASE/retained-gnu-alias.tar.gz" || return 1
    : > "$CALLS"
    run_release --resume
    [[ $STATUS -eq 4 && ! -s "$CALLS" ]]
}

test_remote_drift_after_upload_prevents_success() {
    setup final_drift
    FINAL_DRIFT=true
    run_release --resume
    [[ $STATUS -eq 1 && ! -e "$DSR_STATE_DIR/dispatch" ]] && ! grep -q '^DISPATCH' "$CALLS" &&
        jq -e '.details.verification=="incomplete" and .details.failed>0' "$CASE/stdout" >/dev/null
}

test_release_visibility_drift_prevents_dispatch() {
    setup visibility_drift
    VISIBILITY_DRIFT=true
    run_release --resume
    [[ $STATUS -eq 1 && ! -e "$DSR_STATE_DIR/dispatch" ]] && ! grep -q '^DISPATCH' "$CALLS" &&
        jq -e '.details.verification=="incomplete"' "$CASE/stdout" >/dev/null
}

test_checkpoint_symlink_failure_preserves_foreign_file() {
    setup journal_symlink
    printf 'foreign state\n' > "$CASE/sentinel"
    ln -s "$CASE/sentinel" "$DSR_STATE_DIR/releases/tool-v1.2.3-upload.json"
    run_release --resume
    [[ $STATUS -eq 1 && "$(cat "$CASE/sentinel")" == 'foreign state' ]] &&
        [[ -L "$DSR_STATE_DIR/releases/tool-v1.2.3-upload.json" ]] && ! grep -q '^DISPATCH' "$CALLS"
}

test_checkpoint_receipt_is_bound_and_private() {
    setup journal_receipt
    printf 'second payload\n' > "$CASE/artifacts/second.bin"
    FAIL_NAME=second.bin
    local old_umask mode
    old_umask=$(umask)
    umask 000
    run_release --resume
    umask "$old_umask"
    mode=$(stat -c '%a' "$DSR_STATE_DIR/releases/tool-v1.2.3-upload.json" 2>/dev/null ||
        stat -f '%Lp' "$DSR_STATE_DIR/releases/tool-v1.2.3-upload.json")
    [[ $STATUS -eq 1 && "$mode" == 600 ]] &&
        jq -e '.schema=="dsr.release_upload_receipt.v1" and .repo=="owner/repo" and
          .tag=="v1.2.3" and .release_id==9 and (.uploaded|length)==1 and
          (.uploaded[0].sha256|test("^[0-9a-f]{64}$")) and .uploaded[0].remote_id==100' \
          "$DSR_STATE_DIR/releases/tool-v1.2.3-upload.json" >/dev/null
}

test_partial_release_resumes_only_missing_upload() {
    setup partial_retry
    printf 'second payload\n' > "$CASE/artifacts/second.bin"
    FAIL_NAME=second.bin
    run_release --resume
    [[ $STATUS -eq 1 ]] || return 1
    FAIL_NAME=""
    : > "$CALLS"
    run_release --resume
    [[ $STATUS -eq 0 ]] && ! grep -Fxq 'POST payload.bin' "$CALLS" &&
        [[ "$(grep -c '^POST ' "$CALLS")" == 1 ]] && grep -Fxq 'POST second.bin' "$CALLS" &&
        jq -e '.details.success==2 and .details.failed==0' "$CASE/stdout" >/dev/null
}

test_completed_release_resume_does_not_reupload() {
    setup repeat
    run_release --resume
    [[ $STATUS -eq 0 ]] || return 1
    : > "$CALLS"
    run_release --resume
    [[ $STATUS -eq 0 ]] && ! grep -q '^POST\|^CREATE\|--method DELETE' "$CALLS" &&
        jq -e '.details.success==1' "$CASE/stdout" >/dev/null
}

test_release_dispatch_accepted_outbox_survives_new_process_ids() {
    setup dispatch_stable_identity
    export DSR_DISPATCH_REPOS=owner/a,owner/b DSR_RUN_ID=first-process
    run_release --resume
    [[ $STATUS -eq 0 ]] || return 1
    local outbox
    outbox=$(jq -r '.details.dispatch.outbox_file // empty' "$CASE/stdout")
    if [[ -n "$outbox" && -f "$outbox" ]]; then
        cp "$outbox" "$CASE/outbox.before" || return 1
    fi
    cp "$CASE/dispatch/owner_a.json" "$CASE/a.before" || return 1
    cp "$CASE/dispatch/owner_b.json" "$CASE/b.before" || return 1
    export DSR_RUN_ID=another-process
    run_release --resume
    [[ $STATUS -eq 0 && -n "$outbox" && -f "$outbox" ]] &&
        jq -e -s 'length==2 and ([.[].destination]|sort)==["owner/a","owner/b"]' "$CASE/dispatch-calls.jsonl" >/dev/null &&
        cmp -s "$outbox" "$CASE/outbox.before" &&
        cmp -s "$CASE/a.before" "$CASE/dispatch/owner_a.json" &&
        cmp -s "$CASE/b.before" "$CASE/dispatch/owner_b.json" &&
        jq -e 'all(.deliveries[]; (.history|length)==1 and .history[0].outcome=="accepted")' "$outbox" >/dev/null &&
        jq -e --arg outbox "$outbox" '.details.dispatch.status=="completed" and
            .details.dispatch.exit_code==0 and .details.dispatch.outbox_file==$outbox and
            (.details.dispatch.results|length)==2 and
            all(.details.dispatch.results[]; .outcome=="accepted")' "$CASE/stdout" >/dev/null
}

test_release_dispatch_retries_only_rejected_destination() {
    setup dispatch_rejected
    export DSR_DISPATCH_REPOS=owner/a,owner/b DSR_RUN_ID=first-process
    DISPATCH_MODE=reject
    run_release --resume
    [[ $STATUS -eq 0 ]] || return 1
    cp "$CASE/stdout" "$CASE/first-result.json" || return 1
    cp "$CASE/dispatch/owner_b.json" "$CASE/b.before" || return 1
    DISPATCH_MODE=success
    export DSR_RUN_ID=retry-process
    run_release --resume
    local outbox
    outbox=$(jq -r '.details.dispatch.outbox_file // empty' "$CASE/stdout")
    [[ $STATUS -eq 0 && -f "$outbox" ]] &&
        jq -e '.status=="success" and .exit_code==0 and
            .details.dispatch.status=="failed" and .details.dispatch.exit_code==1 and
            [.details.dispatch.results[].outcome]==["accepted","rejected"]' "$CASE/first-result.json" >/dev/null &&
        jq -e -s 'length==3 and ([.[]|select(.destination=="owner/a")]|length)==1 and
            ([.[]|select(.destination=="owner/b")]|length)==2' "$CASE/dispatch-calls.jsonl" >/dev/null &&
        cmp -s "$CASE/b.before" "$CASE/dispatch/owner_b.json" &&
        jq -e '[.deliveries[].history|length]==[1,2] and
            .deliveries[1].history[1].resend_uncertain==false' "$outbox" >/dev/null &&
        jq -e '.details.dispatch.status=="completed" and .details.dispatch.exit_code==0' "$CASE/stdout" >/dev/null
}

test_release_dispatch_uncertain_requires_explicit_retry() {
    setup dispatch_uncertain
    export DSR_DISPATCH_REPOS=owner/a,owner/b
    DISPATCH_MODE=uncertain
    run_release --resume
    [[ $STATUS -eq 0 ]] || return 1
    cp "$CASE/dispatch/owner_b.json" "$CASE/b.before" || return 1
    DISPATCH_MODE=success
    export DSR_RUN_ID=retry-process
    run_release --resume
    [[ $STATUS -eq 0 ]] &&
        jq -e -s 'length==2' "$CASE/dispatch-calls.jsonl" >/dev/null &&
        jq -e '.details.dispatch.status=="failed" and .details.dispatch.exit_code==8 and
            [.details.dispatch.results[].outcome]==["accepted","uncertain"]' "$CASE/stdout" >/dev/null || return 1
    run_release --resume --dispatch-retry-uncertain
    local outbox
    outbox=$(jq -r '.details.dispatch.outbox_file // empty' "$CASE/stdout")
    [[ $STATUS -eq 0 && -f "$outbox" ]] &&
        jq -e -s 'length==3 and ([.[]|select(.destination=="owner/a")]|length)==1' "$CASE/dispatch-calls.jsonl" >/dev/null &&
        cmp -s "$CASE/b.before" "$CASE/dispatch/owner_b.json" &&
        jq -e '.deliveries[1].history[1].resend_uncertain==true and
            .deliveries[1].history[1].outcome=="accepted"' "$outbox" >/dev/null &&
        jq -e '.details.dispatch.status=="completed" and .details.dispatch.exit_code==0' "$CASE/stdout" >/dev/null
}

test_release_dispatch_custom_event_and_canonical_payload() {
    setup dispatch_custom_payload
    RELEASE_TEST_VERSION=v1.2.3
    run_release --resume --dispatch-event release.custom-ready
    [[ $STATUS -eq 0 ]] || return 1
    cp "$CASE/dispatch/owner_downstream.json" "$CASE/request.before" || return 1
    RELEASE_TEST_VERSION=1.2.3
    export DSR_RUN_ID=another-process
    run_release --resume --dispatch-event release.custom-ready
    local pin outbox
    printf -v pin '%040d' 1
    outbox=$(jq -r '.details.dispatch.outbox_file // empty' "$CASE/stdout")
    [[ $STATUS -eq 0 && -f "$outbox" ]] &&
        jq -e -s 'length==1' "$CASE/dispatch-calls.jsonl" >/dev/null &&
        cmp -s "$CASE/request.before" "$CASE/dispatch/owner_downstream.json" &&
        jq -e --arg pin "$pin" '.event_type=="release.custom-ready" and
            (.client_payload|type)=="object" and (.client_payload|length)<=10 and
            .client_payload.tool=="tool" and .client_payload.version=="1.2.3" and
            .client_payload.tag=="v1.2.3" and .client_payload.repo=="owner/repo" and
            .client_payload.source_repo=="owner/repo" and .client_payload.sha==$pin and
            .client_payload.run_id=="release-9" and
            .client_payload.release_url=="https://github.com/owner/repo/releases/tag/v1.2.3" and
            (.client_payload.delivery_id|test("^[0-9a-f]{64}$"))' "$CASE/dispatch/owner_downstream.json" >/dev/null &&
        jq -e 'all(.deliveries[]; .history[-1].receipt.event_type=="release.custom-ready")' "$outbox" >/dev/null &&
        jq -e '.details.dispatch.event=="release.custom-ready" and .details.dispatch.status=="completed"' "$CASE/stdout" >/dev/null
}

test_release_dispatch_plan_drift_preserves_original_work() {
    setup dispatch_plan_drift
    export DSR_DISPATCH_REPOS=owner/a,owner/b
    DISPATCH_MODE=reject
    run_release --resume
    local outbox
    outbox=$(jq -r '.details.dispatch.outbox_file // empty' "$CASE/stdout")
    [[ $STATUS -eq 0 && -f "$outbox" ]] || return 1
    cp "$outbox" "$CASE/outbox.before" || return 1
    DISPATCH_MODE=success
    local change
    for change in destination event; do
        case "$change" in
            destination) run_release --resume --dispatch-repos owner/a ;;
            event) run_release --resume --dispatch-event changed-event ;;
        esac
        [[ $STATUS -eq 0 ]] &&
            jq -e '.details.dispatch.status=="failed" and .details.dispatch.exit_code==2' "$CASE/stdout" >/dev/null &&
            jq -e -s 'length==2' "$CASE/dispatch-calls.jsonl" >/dev/null &&
            cmp -s "$outbox" "$CASE/outbox.before" || return 1
    done
    run_release --resume --dispatch-repos Owner/B,owner/A,owner/b
    [[ $STATUS -eq 0 ]] &&
        jq -e '.details.dispatch.status=="completed" and .details.dispatch.exit_code==0' "$CASE/stdout" >/dev/null &&
        jq -e -s 'length==3 and ([.[]|select(.destination=="owner/a")]|length)==1' "$CASE/dispatch-calls.jsonl" >/dev/null
}

test_release_dispatch_refuses_unresolved_source_without_sending() {
    setup dispatch_invalid_source
    STAGED_SOURCE_SHA=short
    run_release --resume
    [[ $STATUS -eq 0 && ! -s "$CASE/dispatch-calls.jsonl" && ! -e "$DSR_STATE_DIR/dispatch" ]] &&
        jq -e '.details.dispatch.status=="failed" and .details.dispatch.exit_code==4' "$CASE/stdout" >/dev/null
}

test_release_dispatch_explicit_config_false_prevents_delivery() {
    local scope config_file
    for scope in repo global; do
        setup "dispatch_disabled_$scope"
        unset DSR_DISPATCH_ENABLED DSR_DISPATCH_REPOS
        if [[ "$scope" == repo ]]; then config_file="$ACT_REPOS_DIR/tool.yaml"
        else config_file="$DSR_CONFIG_FILE"; fi
        printf 'targets: [linux/amd64]\ndispatch:\n  enabled: false\n  repos: [owner/downstream]\n' > "$config_file"
        run_release --resume
        [[ $STATUS -eq 0 && ! -s "$CASE/dispatch-calls.jsonl" && ! -e "$DSR_STATE_DIR/dispatch" ]] &&
            jq -e '.details.dispatch.status=="skipped"' "$CASE/stdout" >/dev/null || return 1
        # A real configuration reader must also enable the otherwise identical
        # positive case; missing yq cannot turn this into a false passing skip.
        printf 'targets: [linux/amd64]\ndispatch:\n  enabled: true\n  repos: [owner/downstream]\n' > "$config_file"
        run_release --resume
        [[ $STATUS -eq 0 ]] && jq -e -s 'length==1' "$CASE/dispatch-calls.jsonl" >/dev/null &&
            jq -e '.details.dispatch.status=="completed"' "$CASE/stdout" >/dev/null || return 1
    done
}

test_release_dispatch_rechecks_publication_between_destinations() {
    setup dispatch_between_destinations
    export DSR_DISPATCH_REPOS=owner/a,owner/b
    DISPATCH_MODE=draft-after-first
    run_release --resume
    local outbox
    outbox=$(jq -r '.details.dispatch.outbox_file // empty' "$CASE/stdout")
    [[ $STATUS -eq 0 && -f "$outbox" ]] &&
        jq -e -s 'length==1 and .[0].destination=="owner/a"' "$CASE/dispatch-calls.jsonl" >/dev/null &&
        jq -e '.details.dispatch.status=="failed" and .details.dispatch.exit_code==7 and
            [.details.dispatch.results[].outcome]==["accepted","pending"]' "$CASE/stdout" >/dev/null &&
        jq -e '[.deliveries[].history|length]==[1,0]' "$outbox" >/dev/null || return 1
    DISPATCH_MODE=success
    jq '.draft=false' "$CASE/release.json" > "$CASE/restored-release.json" &&
        mv "$CASE/restored-release.json" "$CASE/release.json" || return 1
    run_dispatch_recovery --outbox "$outbox"
    [[ $STATUS -eq 0 ]] &&
        jq -e -s 'length==2 and [.[].destination]==["owner/a","owner/b"]' "$CASE/dispatch-calls.jsonl" >/dev/null
}

test_release_dispatch_saved_outbox_recovers_without_local_artifacts() {
    setup dispatch_saved_recovery
    export DSR_DISPATCH_REPOS=owner/a,owner/b
    DISPATCH_MODE=reject
    # An older GitHub asset has no server digest. Recovery must prove its
    # actual remote bytes even after the producer's local artifacts disappear.
    remote_put payload.bin "$CASE/artifacts/payload.bin" false || return 1
    run_release --resume
    local outbox downloads_before remote_id
    outbox=$(jq -r '.details.dispatch.outbox_file // empty' "$CASE/stdout")
    [[ $STATUS -eq 0 && -f "$outbox" ]] || return 1
    cp "$CASE/dispatch/owner_b.json" "$CASE/b.before" || return 1
    cp "$outbox" "$CASE/outbox.before" || return 1
    mv "$CASE/artifacts" "$CASE/retained-artifacts" || return 1
    DISPATCH_MODE=success
    export DSR_RUN_ID=changed-process DSR_DISPATCH_REPOS=owner/unrelated DSR_DISPATCH_EVENT=changed-event
    remote_id=$(jq -r '.[]|select(.name=="payload.bin")|.id' "$CASE/inventory.json")
    cp "$CASE/remote/$remote_id" "$CASE/remote.before" || return 1
    printf 'evil payload\n' > "$CASE/remote/$remote_id"
    run_dispatch_recovery --outbox "$outbox"
    [[ $STATUS -eq 7 ]] &&
        jq -e -s 'length==2' "$CASE/dispatch-calls.jsonl" >/dev/null &&
        cmp -s "$outbox" "$CASE/outbox.before" || return 1
    cp "$CASE/remote.before" "$CASE/remote/$remote_id" || return 1
    downloads_before=$(grep -c '^DOWNLOAD ' "$CALLS")
    run_dispatch_recovery --outbox "$outbox"
    [[ $STATUS -eq 0 && $(grep -c '^DOWNLOAD ' "$CALLS") -gt "$downloads_before" ]] &&
        jq -e -s 'length==3 and ([.[]|select(.destination=="owner/a")]|length)==1 and
            ([.[]|select(.destination=="owner/b")]|length)==2' "$CASE/dispatch-calls.jsonl" >/dev/null &&
        cmp -s "$CASE/b.before" "$CASE/dispatch/owner_b.json" &&
        jq -e --arg outbox "$outbox" '.command=="release-dispatch" and .exit_code==0 and
            .details.status=="accepted" and .details.outbox_file==$outbox and
            all(.details.results[]; .outcome=="accepted")' "$CASE/stdout" >/dev/null
}

test_release_dispatch_saved_status_is_read_only_without_auth() {
    setup dispatch_saved_status
    export DSR_DISPATCH_REPOS=owner/a,owner/b
    DISPATCH_MODE=reject
    run_release --resume
    local outbox
    outbox=$(jq -r '.details.dispatch.outbox_file // empty' "$CASE/stdout")
    [[ $STATUS -eq 0 && -f "$outbox" ]] || return 1
    cp "$outbox" "$CASE/outbox.before" || return 1
    cp "$CALLS" "$CASE/calls.before" || return 1
    # A failed auth lookup is itself observable, even if it never sends HTTP.
    _dp_get_token() { printf 'AUTH-ATTEMPT\n' >> "$CALLS"; return 3; }
    unset DSR_GH_TOKEN GITHUB_TOKEN GH_TOKEN
    run_dispatch_recovery --outbox "$outbox" --status
    [[ $STATUS -eq 1 ]] &&
        cmp -s "$outbox" "$CASE/outbox.before" && cmp -s "$CALLS" "$CASE/calls.before" &&
        jq -e '.command=="release-dispatch" and .exit_code==1 and .details.status=="incomplete" and
            [.details.results[].outcome]==["accepted","rejected"]' "$CASE/stdout" >/dev/null || return 1
    run_dispatch_recovery --outbox "$outbox" --dry-run
    [[ $STATUS -eq 0 ]] &&
        cmp -s "$outbox" "$CASE/outbox.before" && cmp -s "$CALLS" "$CASE/calls.before" &&
        jq -e '.command=="release-dispatch" and .status=="dry_run" and .exit_code==0 and
            .details.mode=="dry_run" and [.details.results[].outcome]==["accepted","rejected"]' "$CASE/stdout" >/dev/null
}

test_release_dispatch_saved_uncertain_requires_explicit_retry() {
    setup dispatch_saved_uncertain
    export DSR_DISPATCH_REPOS=owner/a,owner/b
    DISPATCH_MODE=uncertain
    run_release --resume
    local outbox
    outbox=$(jq -r '.details.dispatch.outbox_file // empty' "$CASE/stdout")
    [[ $STATUS -eq 0 && -f "$outbox" ]] || return 1
    cp "$CASE/dispatch/owner_b.json" "$CASE/b.before" || return 1
    DISPATCH_MODE=success
    run_dispatch_recovery --outbox "$outbox"
    [[ $STATUS -eq 8 ]] && jq -e -s 'length==2' "$CASE/dispatch-calls.jsonl" >/dev/null || return 1
    run_dispatch_recovery --outbox "$outbox" --retry-uncertain
    [[ $STATUS -eq 0 ]] &&
        jq -e -s 'length==3 and ([.[]|select(.destination=="owner/a")]|length)==1' "$CASE/dispatch-calls.jsonl" >/dev/null &&
        cmp -s "$CASE/b.before" "$CASE/dispatch/owner_b.json" &&
        jq -e '.deliveries[1].history[1].resend_uncertain==true and
            .deliveries[1].history[1].outcome=="accepted"' "$outbox" >/dev/null &&
        jq -e '.command=="release-dispatch" and .exit_code==0 and .details.status=="accepted"' "$CASE/stdout" >/dev/null
}

test_release_dispatch_saved_recovery_refuses_remote_drift() {
    setup dispatch_saved_drift
    export DSR_DISPATCH_REPOS=owner/a,owner/b
    DISPATCH_MODE=reject
    run_release --resume
    local outbox change
    outbox=$(jq -r '.details.dispatch.outbox_file // empty' "$CASE/stdout")
    [[ $STATUS -eq 0 && -f "$outbox" ]] || return 1
    cp "$outbox" "$CASE/outbox.before" || return 1
    cp "$CASE/release.json" "$CASE/release.before" || return 1
    cp "$CASE/inventory.json" "$CASE/inventory.before" || return 1
    DISPATCH_MODE=success
    for change in draft tag assets identity; do
        cp "$CASE/release.before" "$CASE/release.json" || return 1
        cp "$CASE/inventory.before" "$CASE/inventory.json" || return 1
        STAGED_SOURCE_SHA=""
        case "$change" in
            draft) jq '.draft=true' "$CASE/release.before" > "$CASE/release.json" || return 1 ;;
            tag) STAGED_SOURCE_SHA=2222222222222222222222222222222222222222 ;;
            assets) jq 'map(.digest="sha256:"+("0"*64))' "$CASE/inventory.before" > "$CASE/inventory.json" || return 1 ;;
            identity) jq '.id=10' "$CASE/release.before" > "$CASE/release.json" || return 1 ;;
        esac
        run_dispatch_recovery --outbox "$outbox"
        [[ $STATUS -ne 0 ]] &&
            jq -e -s 'length==2' "$CASE/dispatch-calls.jsonl" >/dev/null &&
            cmp -s "$outbox" "$CASE/outbox.before" || return 1
    done
    # Prove the preceding refusals came from changed remote evidence, not an
    # unrelated failure to admit every saved plan or dispatch destination.
    cp "$CASE/release.before" "$CASE/release.json" || return 1
    cp "$CASE/inventory.before" "$CASE/inventory.json" || return 1
    STAGED_SOURCE_SHA=""
    run_dispatch_recovery --outbox "$outbox"
    [[ $STATUS -eq 0 ]] && jq -e -s 'length==3' "$CASE/dispatch-calls.jsonl" >/dev/null
}

test_release_dispatch_saved_state_is_validated_before_network() {
    setup dispatch_saved_invalid
    export DSR_DISPATCH_REPOS=owner/a,owner/b
    DISPATCH_MODE=reject
    run_release --resume
    local outbox filter
    outbox=$(jq -r '.details.dispatch.outbox_file // empty' "$CASE/stdout")
    [[ $STATUS -eq 0 && -f "$outbox" ]] || return 1
    cp "$outbox" "$CASE/outbox.before" || return 1
    cp "$CALLS" "$CASE/calls.before" || return 1
    DISPATCH_MODE=success
    run_dispatch_recovery --outbox "$outbox" --status
    [[ $STATUS -eq 1 ]] && cmp -s "$CALLS" "$CASE/calls.before" &&
        jq -e '.details.status=="incomplete" and
            [.details.results[].outcome]==["accepted","rejected"]' "$CASE/stdout" >/dev/null || return 1
    for filter in '.schema_version=99' '.plan.requests[1].request_sha256=("0"*64)' \
        '.plan.requests[1].body|=(fromjson|.event_type="changed-event"|tojson)' \
        '.deliveries[1].history[0].request_sha256=("0"*64)'; do
        jq "$filter" "$CASE/outbox.before" > "$outbox" || return 1
        cp "$outbox" "$CASE/tampered.before" || return 1
        run_dispatch_recovery --outbox "$outbox"
        [[ $STATUS -ne 0 ]] && cmp -s "$outbox" "$CASE/tampered.before" &&
            cmp -s "$CALLS" "$CASE/calls.before" || return 1
    done
    cp "$CASE/outbox.before" "$outbox" || return 1
    chmod 644 "$outbox" || return 1
    run_dispatch_recovery --outbox "$outbox"
    [[ $STATUS -ne 0 ]] && cmp -s "$outbox" "$CASE/outbox.before" &&
        cmp -s "$CALLS" "$CASE/calls.before"
}

test_invalid_journal_is_not_upload_authority() {
    setup invalid_journal
    printf 'not json' > "$DSR_STATE_DIR/releases/tool-v1.2.3-upload.json"
    run_release --resume
    [[ $STATUS -eq 0 ]] && grep -Fxq 'POST payload.bin' "$CALLS"
}

test_empty_artifacts_are_not_a_release() {
    setup empty
    mkdir "$CASE/empty"
    STATUS=0
    cmd_release tool 1.2.3 --artifacts "$CASE/empty" --no-manifest > "$CASE/stdout" 2> "$CASE/stderr" || STATUS=$?
    [[ $STATUS -eq 4 && ! -s "$CALLS" ]] && grep -q 'No release artifacts were selected' "$CASE/stderr"
}

# --draft cannot be honored by a release that is already public: nothing is
# uploaded into it.
test_draft_request_refuses_published_release() {
    setup draft_on_public
    manifest payload.bin
    run_release --resume --draft
    [[ $STATUS -eq 7 ]] && ! grep -q '^POST ' "$CALLS" &&
        grep -q 'already a published release; nothing uploaded' "$CASE/stderr"
}

# dsr build withholds the manifest after a partial build; a directory without
# one is published only on explicit request.
test_unmanifested_directory_is_refused() {
    setup no_manifest
    STATUS=0
    cmd_release tool 1.2.3 --artifacts "$CASE/artifacts" > "$CASE/stdout" 2> "$CASE/stderr" || STATUS=$?
    [[ $STATUS -eq 4 && ! -s "$CALLS" ]] && grep -q 'pass --no-manifest' "$CASE/stderr"
}

# Artifacts built from another commit than the tag are refused; a tag not yet
# on GitHub is created at the tagged commit, not the default branch head.
test_artifacts_must_come_from_the_tagged_commit() {
    setup tag_binding
    local tagged head
    git init -q "$CASE/checkout" &&
        git -C "$CASE/checkout" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m tagged &&
        git -C "$CASE/checkout" tag v1.2.3 &&
        git -C "$CASE/checkout" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m later ||
        return 1
    tagged=$(git -C "$CASE/checkout" rev-parse 'v1.2.3^{commit}')
    head=$(git -C "$CASE/checkout" rev-parse HEAD)
    act_get_local_path() { printf '%s\n' "$CASE/checkout"; }
    git_ops_tag_exists() { git -C "$1" rev-parse -q --verify "refs/tags/$2" >/dev/null; }
    git_ops_tag_sha() { git -C "$1" rev-parse --verify "$2^{commit}"; }
    manifest payload.bin
    local manifest_file="$CASE/artifacts/tool-v1.2.3-manifest.json"
    jq --arg sha "$head" '. + {source: {git_sha: $sha}}' "$manifest_file" > "$manifest_file.new" &&
        mv "$manifest_file.new" "$manifest_file"
    run_release
    [[ $STATUS -eq 4 && ! -s "$CALLS" ]] && grep -q "built from $head, but v1.2.3 is $tagged" "$CASE/stderr" ||
        return 1

    jq --arg sha "$tagged" '.source.git_sha = $sha' "$manifest_file" > "$manifest_file.new" &&
        mv "$manifest_file.new" "$manifest_file"
    CREATE_FAIL=false
    gh_resolve_tag_sha() { printf '%s\n' "$tagged"; }
    run_release
    [[ $STATUS -eq 0 ]] && grep -q -- "^CREATE .*--target-commitish $tagged" "$CALLS"
}

test_wrong_repository_upload_url_is_rejected() {
    setup wrong_url
    jq '.upload_url="https://uploads.github.com/repos/owner/other/releases/9/assets{?name,label}"' \
        "$CASE/release.json" > "$CASE/release.next"
    mv "$CASE/release.next" "$CASE/release.json"
    run_release --resume
    [[ $STATUS -eq 7 ]] && ! grep -q '^POST\|^DISPATCH' "$CALLS"
}

staged_manifest() {
    local name sha size rows='[]'
    for name in "$@"; do
        sha=$(_gh_asset_sha256 "$CASE/artifacts/$name") || return 1
        size=$(wc -c < "$CASE/artifacts/$name") || return 1
        rows=$(jq -c --arg name "$name" --arg sha "$sha" --argjson size "$size" \
            '. + [{name:$name,sha256:$sha,size_bytes:$size,target:"",archive_format:"none"}]' <<< "$rows") || return 1
    done
    jq -nc --argjson rows "$rows" '{tool:"tool",version:"v1.2.3",status:"success",artifacts:$rows}' > \
        "$CASE/artifacts/tool-v1.2.3-manifest.json"
}

test_staged_creation_publishes_only_after_private_uploads() {
    setup staged_success
    CREATE_FAIL=false
    run_release --verify-upgrade
    [[ $STATUS -eq 0 ]] && jq -e '.draft==true' "$CASE/create-request.json" >/dev/null &&
        grep -Fxq 'UPLOAD-VISIBILITY payload.bin true' "$CALLS" &&
        [[ $(grep -c '^PUBLISH$' "$CALLS") -eq 1 ]] && grep -Fxq DISPATCH "$CALLS" &&
        grep -Fxq UPGRADE "$CALLS" &&
        grep -Fxq 'DISPATCH-URL https://github.com/owner/repo/releases/tag/v1.2.3' "$CALLS" &&
        jq -e '.details.draft==false and (.details.staging_receipt|length>0) and
            .details.release_url=="https://github.com/owner/repo/releases/tag/v1.2.3"' "$CASE/stdout" >/dev/null &&
        [[ $(stat -c %a "$(jq -r '.details.staging_receipt' "$CASE/stdout")") == 600 ]]
}

test_staged_dry_run_creates_no_custody() {
    setup staged_dry_run
    CREATE_FAIL=false DRY_RUN=true
    staged_manifest payload.bin || return 1
    run_release
    [[ $STATUS -eq 0 && ! -s "$CALLS" && ! -e "$CASE/artifacts/SHA256SUMS" ]] &&
        ! compgen -G "$CASE/state/releases/dsr-publication.*" >/dev/null &&
        jq -e '.status=="dry_run" and .details.dry_run' "$CASE/stdout" >/dev/null
}

test_staged_interrupted_upload_resumes_and_publishes() {
    setup staged_retry
    CREATE_FAIL=false FAIL_NAME=second.bin
    printf 'second payload\n' > "$CASE/artifacts/second.bin"
    run_release
    [[ $STATUS -eq 1 ]] && jq -e '.draft==true' "$CASE/release.json" >/dev/null &&
        jq -e '.details.verification=="incomplete"' "$CASE/stdout" >/dev/null &&
        ! grep -q '^PUBLISH\|^DISPATCH' "$CALLS" || return 1
    FAIL_NAME=""
    : > "$CALLS"
    run_release --resume
    [[ $STATUS -eq 0 ]] && ! grep -q '^CREATE\|^POST payload.bin$' "$CALLS" &&
        grep -Fxq 'POST second.bin' "$CALLS" && grep -Fxq PUBLISH "$CALLS" &&
        jq -e '.details.draft==false and .details.success==2' "$CASE/stdout" >/dev/null
}

test_staged_generated_checksums_remain_bound_across_retry() {
    setup staged_checksums
    CREATE_FAIL=false FAIL_NAME=payload.bin
    staged_manifest payload.bin || return 1
    run_release
    [[ $STATUS -eq 1 ]] || return 1
    local intent before
    intent=$(jq -r '.details.staging_receipt' "$CASE/stdout") || return 1
    before=$(_gh_asset_sha256 "$intent") || return 1
    FAIL_NAME=""
    : > "$CALLS"
    run_release --resume
    [[ $STATUS -eq 0 && "$(_gh_asset_sha256 "$intent")" == "$before" ]] &&
        [[ $(grep -c '^POST ' "$CALLS") -eq 1 ]] && grep -Fxq 'POST payload.bin' "$CALLS" &&
        jq -e '.assets | map(.name) == ["SHA256SUMS","payload.bin","payload.bin.sha256","tool-v1.2.3-manifest.json"]' "$intent" >/dev/null
}

test_staged_manifest_aliases_are_all_verified() {
    setup staged_aliases
    CREATE_FAIL=false
    cp "$CASE/artifacts/payload.bin" "$CASE/artifacts/tool-1.2.3-linux-amd64.tar.gz" &&
        cp "$CASE/artifacts/payload.bin" "$CASE/artifacts/tool-linux-amd64.tar.gz" &&
        cp "$CASE/artifacts/payload.bin" "$CASE/artifacts/tool-linux-x86_64.tar.gz" &&
        mv "$CASE/artifacts/payload.bin" "$CASE/fixture-payload.bin" || return 1
    staged_manifest tool-linux-amd64.tar.gz tool-1.2.3-linux-amd64.tar.gz tool-linux-x86_64.tar.gz || return 1
    jq '.artifacts |= map(.target="linux/amd64" | .archive_format="tar.gz")' \
        "$CASE/artifacts/tool-v1.2.3-manifest.json" > "$CASE/manifest.next" &&
        mv "$CASE/manifest.next" "$CASE/artifacts/tool-v1.2.3-manifest.json" || return 1
    run_release
    [[ $STATUS -eq 0 ]] && grep -Fxq PUBLISH "$CALLS" &&
        jq -e '.details.success==8 and .details.draft==false' "$CASE/stdout" >/dev/null &&
        [[ $(grep -c '^POST tool-linux-x86_64.tar.gz$' "$CALLS") -eq 1 ]]
}

test_staged_explicit_draft_stays_private_on_resume() {
    setup staged_explicit_draft
    CREATE_FAIL=false
    run_release --draft
    [[ $STATUS -eq 0 ]] && ! grep -q '^PUBLISH\|^DISPATCH' "$CALLS" || return 1
    : > "$CALLS"
    run_release --resume --verify-upgrade
    [[ $STATUS -eq 0 ]] && ! grep -q '^PUBLISH\|^DISPATCH\|^UPGRADE\|^CREATE\|^POST ' "$CALLS" &&
        jq -e '.details.draft==true' "$CASE/stdout" >/dev/null
}

staged_publish_explicit_draft() {
    setup "$1"
    CREATE_FAIL=false
    run_release --draft
    [[ $STATUS -eq 0 ]] || return 1
    jq '.draft=false | .html_url="https://github.com/owner/repo/releases/tag/v1.2.3"' \
        "$CASE/release.json" > "$CASE/release.next" &&
        mv "$CASE/release.next" "$CASE/release.json" || return 1
    : > "$CALLS"
}

test_staged_explicit_draft_published_manually_resumes() {
    staged_publish_explicit_draft staged_manual_public || return 1
    run_release --resume --verify-upgrade
    [[ $STATUS -eq 0 ]] && ! grep -q '^CREATE\|^POST \|^PUBLISH\|^RESTORE-DRAFT' "$CALLS" &&
        grep -Fxq DISPATCH "$CALLS" && grep -Fxq UPGRADE "$CALLS" &&
        jq -e '.details.draft==false and .details.release_url=="https://github.com/owner/repo/releases/tag/v1.2.3"' \
            "$CASE/stdout" >/dev/null
}

test_staged_manual_publication_drift_is_not_redrafted() {
    staged_publish_explicit_draft staged_manual_public_drift || return 1
    jq 'map(.digest="sha256:"+("0"*64))' "$CASE/inventory.json" > "$CASE/inventory.next" &&
        mv "$CASE/inventory.next" "$CASE/inventory.json" || return 1
    run_release --resume
    [[ $STATUS -eq 1 ]] && ! grep -q '^CREATE\|^POST \|^PUBLISH\|^RESTORE-DRAFT\|^DISPATCH' "$CALLS" &&
        jq -e '.draft==false' "$CASE/release.json" >/dev/null
}

test_staged_manual_publication_rejects_draft_request() {
    staged_publish_explicit_draft staged_manual_public_draft_request || return 1
    run_release --resume --draft
    [[ $STATUS -eq 7 ]] && ! grep -q '^CREATE\|^POST \|^PUBLISH\|^RESTORE-DRAFT\|^DISPATCH' "$CALLS" &&
        jq -e '.draft==false' "$CASE/release.json" >/dev/null
}

test_staged_lost_publish_response_requires_public_proof() {
    setup staged_lost_publish
    CREATE_FAIL=false LOST_PUBLISH_RESPONSE=true
    run_release
    [[ $STATUS -eq 0 ]] && [[ $(grep -c '^PUBLISH$' "$CALLS") -eq 1 ]] &&
        [[ $(grep -c '^DISPATCH$' "$CALLS") -eq 1 ]] && ! grep -q '^RESTORE-DRAFT' "$CALLS" &&
        grep -Fxq 'DISPATCH-URL https://github.com/owner/repo/releases/tag/v1.2.3' "$CALLS" &&
        jq -e '.details.draft==false and .details.release_url=="https://github.com/owner/repo/releases/tag/v1.2.3"' \
            "$CASE/stdout" >/dev/null
}

test_staged_failed_publish_retries_without_reupload() {
    setup staged_publish_retry
    CREATE_FAIL=false PUBLISH_FAIL=true
    run_release
    [[ $STATUS -eq 1 ]] && jq -e '.draft==true' "$CASE/release.json" >/dev/null &&
        ! grep -q '^DISPATCH' "$CALLS" || return 1
    PUBLISH_FAIL=false
    : > "$CALLS"
    run_release --resume
    [[ $STATUS -eq 0 ]] && ! grep -q '^CREATE\|^POST ' "$CALLS" && grep -Fxq PUBLISH "$CALLS"
}

test_staged_already_public_retry_verifies_original_plan() {
    setup staged_public_retry
    CREATE_FAIL=false PUBLISH_FAIL=true
    run_release
    [[ $STATUS -eq 1 ]] || return 1
    # Model a PATCH committed just before the old controller stopped.
    jq '.draft=false | .html_url="https://github.com/owner/repo/releases/tag/v1.2.3"' \
        "$CASE/release.json" > "$CASE/release.next" &&
        mv "$CASE/release.next" "$CASE/release.json" || return 1
    PUBLISH_FAIL=false
    : > "$CALLS"
    run_release --resume
    [[ $STATUS -eq 0 ]] && ! grep -q '^CREATE\|^POST \|^PUBLISH\|^RESTORE-DRAFT' "$CALLS" &&
        grep -Fxq 'DISPATCH-URL https://github.com/owner/repo/releases/tag/v1.2.3' "$CALLS" &&
        jq -e '.details.staging_receipt!=null and .details.release_url=="https://github.com/owner/repo/releases/tag/v1.2.3"' \
            "$CASE/stdout" >/dev/null
}

test_staged_already_public_retry_refuses_extra_asset() {
    setup staged_public_extra
    CREATE_FAIL=false PUBLISH_FAIL=true
    run_release
    [[ $STATUS -eq 1 ]] || return 1
    jq '.draft=false | .html_url="https://github.com/owner/repo/releases/tag/v1.2.3"' \
        "$CASE/release.json" > "$CASE/release.next" &&
        mv "$CASE/release.next" "$CASE/release.json" || return 1
    remote_put unexpected.bin "$CASE/artifacts/payload.bin" || return 1
    PUBLISH_FAIL=false
    : > "$CALLS"
    run_release --resume
    [[ $STATUS -eq 1 ]] && ! grep -q '^PUBLISH\|^DISPATCH' "$CALLS" &&
        grep -Fxq RESTORE-DRAFT "$CALLS" && jq -e '.draft==true' "$CASE/release.json" >/dev/null
}

test_staged_extra_asset_blocks_first_publication() {
    setup staged_extra
    CREATE_FAIL=false EXTRA_ASSET=true
    run_release
    [[ $STATUS -eq 1 ]] && ! grep -q '^PUBLISH\|^DISPATCH' "$CALLS" &&
        jq -e '.draft==true' "$CASE/release.json" >/dev/null
}

test_staged_missing_selected_sidecar_blocks_publication() {
    setup staged_missing_sidecar
    CREATE_FAIL=false DROP_SIDECAR=payload.bin.sbom.json
    staged_manifest payload.bin || return 1
    printf '{"name":"payload"}\n' > "$CASE/artifacts/payload.bin.sbom.json"
    run_release
    [[ $STATUS -eq 1 ]] && ! grep -q '^PUBLISH\|^DISPATCH' "$CALLS" &&
        jq -e '.draft==true' "$CASE/release.json" >/dev/null
}

test_staged_changed_notes_are_not_published_or_overwritten() {
    setup staged_notes
    CREATE_FAIL=false UPLOAD_METADATA_DRIFT=true
    run_release
    [[ $STATUS -eq 1 ]] && ! grep -q '^PUBLISH\|^RESTORE-DRAFT\|^DISPATCH' "$CALLS" &&
        jq -e '.body=="Another publisher changed these notes"' "$CASE/release.json" >/dev/null
}

test_staged_changed_destination_is_not_published() {
    setup staged_wrong_destination
    CREATE_FAIL=false UPLOAD_DESTINATION_DRIFT=true
    run_release
    [[ $STATUS -eq 1 ]] && ! grep -q '^PUBLISH\|^RESTORE-DRAFT\|^DISPATCH' "$CALLS" &&
        jq -e '.draft==true' "$CASE/release.json" >/dev/null
}

test_staged_postpublish_destination_drift_is_not_overwritten() {
    setup staged_postpublish_destination
    CREATE_FAIL=false PUBLISH_DESTINATION_DRIFT=true
    run_release
    [[ $STATUS -eq 1 ]] && grep -Fxq PUBLISH "$CALLS" &&
        ! grep -q '^RESTORE-DRAFT\|^DISPATCH' "$CALLS" &&
        jq -e '.draft==false and .html_url=="https://github.com/another/repo/releases/tag/v1.2.3"' \
            "$CASE/release.json" >/dev/null
}

test_staged_postpublish_asset_drift_restores_owned_draft() {
    setup staged_postpublish_asset
    CREATE_FAIL=false PUBLISH_ASSET_DRIFT=true
    run_release
    [[ $STATUS -eq 1 ]] && grep -Fxq PUBLISH "$CALLS" && grep -Fxq RESTORE-DRAFT "$CALLS" &&
        ! grep -q '^DISPATCH' "$CALLS" && jq -e '.draft==true' "$CASE/release.json" >/dev/null &&
        jq -e '.details.draft==true and
            .details.release_url=="https://github.com/owner/repo/releases/tag/untagged-fedcba9876543210"' \
            "$CASE/stdout" >/dev/null
}

test_staged_postpublish_metadata_drift_is_not_overwritten() {
    setup staged_postpublish_metadata
    CREATE_FAIL=false PUBLISH_METADATA_DRIFT=true
    run_release
    [[ $STATUS -eq 1 ]] && grep -Fxq PUBLISH "$CALLS" &&
        ! grep -q '^RESTORE-DRAFT\|^DISPATCH' "$CALLS" &&
        jq -e '.draft==false and .body=="Another publisher changed these notes"' "$CASE/release.json" >/dev/null
}

test_staged_lost_original_post_is_never_adopted() {
    setup staged_lost_creation
    CREATE_FAIL=false LOST_CREATE_RESPONSE=true
    run_release
    [[ $STATUS -eq 7 ]] && ! grep -q '^POST \|^PUBLISH' "$CALLS" || return 1
    LOST_CREATE_RESPONSE=false
    : > "$CALLS"
    run_release --resume
    [[ $STATUS -eq 7 ]] && ! grep -q '^CREATE\|^POST \|^PUBLISH\|^DISPATCH' "$CALLS" &&
        jq -e '.draft==true' "$CASE/release.json" >/dev/null
}

test_staged_changed_inputs_are_not_adopted_on_resume() {
    setup staged_changed_inputs
    CREATE_FAIL=false UPLOAD_FAIL=true
    run_release
    [[ $STATUS -eq 1 ]] || return 1
    printf 'different bytes\n' > "$CASE/artifacts/payload.bin"
    UPLOAD_FAIL=false
    : > "$CALLS"
    run_release --resume
    [[ $STATUS -eq 7 ]] && ! grep -q '^POST \|^PUBLISH\|^DISPATCH' "$CALLS"
}

test_staged_nonprivate_receipt_cannot_authorize_resume() {
    setup staged_nonprivate
    CREATE_FAIL=false UPLOAD_FAIL=true
    run_release
    [[ $STATUS -eq 1 ]] || return 1
    chmod 644 "$(jq -r '.details.staging_receipt' "$CASE/stdout")" || return 1
    UPLOAD_FAIL=false
    : > "$CALLS"
    run_release --resume
    [[ $STATUS -eq 7 ]] && ! grep -q '^POST \|^PUBLISH\|^DISPATCH' "$CALLS"
}

test_staged_ambiguous_receipts_cannot_authorize_resume() {
    setup staged_ambiguous
    CREATE_FAIL=false UPLOAD_FAIL=true
    run_release
    [[ $STATUS -eq 1 ]] || return 1
    local intent directory duplicate
    intent=$(jq -r '.details.staging_receipt' "$CASE/stdout") || return 1
    directory="${intent%/*}"
    duplicate="${directory%.*}.duplicate"
    mkdir -m 700 "$duplicate" && cp "$directory/intent.json" "$directory"/dsr-api-response.???????? "$duplicate/" || return 1
    UPLOAD_FAIL=false
    : > "$CALLS"
    run_release --resume
    [[ $STATUS -eq 7 ]] && ! grep -q '^POST \|^PUBLISH\|^DISPATCH' "$CALLS"
}

test_staged_intent_drift_during_create_blocks_upload() {
    setup staged_intent_drift
    CREATE_FAIL=false CREATE_INTENT_DRIFT=true
    run_release
    [[ $STATUS -eq 7 ]] && ! grep -q '^POST \|^PUBLISH\|^DISPATCH' "$CALLS"
}

test_staged_storage_refusal_precedes_creation() {
    setup staged_storage
    CREATE_FAIL=false
    mv "$CASE/state/releases" "$CASE/original-releases" &&
        ln -s "$CASE/original-releases" "$CASE/state/releases" || return 1
    run_release
    [[ $STATUS -eq 4 ]] && ! grep -q '^CREATE\|^POST \|^PUBLISH' "$CALLS"
}

test_staged_concurrent_complete_publication_is_preserved() {
    setup staged_concurrent_publication
    CREATE_FAIL=false CONCURRENT_PUBLISH=true
    run_release
    [[ $STATUS -eq 0 ]] && ! grep -q '^PUBLISH\|^RESTORE-DRAFT' "$CALLS" &&
        grep -Fxq DISPATCH "$CALLS" && jq -e '.details.draft==false' "$CASE/stdout" >/dev/null
}

staged_tag_case() {
    setup "staged_tag_$1"
    CREATE_FAIL=false STAGED_REMOTE_MODE="$1"
    git init -q "$CASE/checkout" &&
        git -C "$CASE/checkout" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m tagged &&
        git -C "$CASE/checkout" tag v1.2.3 || return 1
    STAGED_SOURCE_SHA=$(git -C "$CASE/checkout" rev-parse HEAD) || return 1
    act_get_local_path() { printf '%s\n' "$CASE/checkout"; }
    git_ops_tag_exists() { git -C "$1" rev-parse -q --verify "refs/tags/$2" >/dev/null; }
    git_ops_tag_sha() { git -C "$1" rev-parse --verify "$2^{commit}"; }
    run_release
    if [[ "$1" == valid || "$1" == absent-empty || "$1" == absent-prefix ]]; then
        [[ $STATUS -eq 0 ]] && grep -Fxq PUBLISH "$CALLS" && grep -Fxq DISPATCH "$CALLS" || return 1
    elif [[ "$1" == after-publish || "$1" == absent-wrong-created ]]; then
        [[ $STATUS -eq 1 ]] && grep -Fxq PUBLISH "$CALLS" && grep -Fxq RESTORE-DRAFT "$CALLS" &&
            ! grep -q '^DISPATCH' "$CALLS" && jq -e '.draft==true' "$CASE/release.json" >/dev/null || return 1
    else
        [[ $STATUS -eq 1 ]] && ! grep -q '^PUBLISH\|^DISPATCH' "$CALLS" &&
            jq -e '.draft==true' "$CASE/release.json" >/dev/null || return 1
    fi
    [[ "$1" != absent-* ]] || grep -Fxq TAG-ABSENCE "$CALLS"
}
test_staged_pinned_tag_is_verified() { staged_tag_case valid; }
test_staged_moved_tag_blocks_publication() { staged_tag_case moved; }
test_staged_unavailable_tag_blocks_publication() { staged_tag_case unavailable; }
test_staged_postpublish_tag_drift_restores_draft() { staged_tag_case after-publish; }
test_staged_absent_tag_is_created_at_pinned_commit() { staged_tag_case absent-empty; }
test_staged_absent_tag_with_prefix_sibling_can_publish() { staged_tag_case absent-prefix; }
test_staged_absent_tag_probe_unavailable_is_refused() { staged_tag_case absent-unavailable; }
test_staged_absent_tag_probe_malformed_is_refused() { staged_tag_case absent-malformed; }
test_staged_absent_tag_probe_nonarray_is_refused() { staged_tag_case absent-nonarray; }
test_staged_absent_tag_probe_exact_ref_is_refused() { staged_tag_case absent-exact; }
test_staged_absent_tag_probe_wrong_repository_is_refused() { staged_tag_case absent-wrong-realm; }
test_staged_absent_tag_created_at_wrong_commit_is_redrafted() { staged_tag_case absent-wrong-created; }

sbom_setup() {
    setup "$1"
    CREATE_FAIL=false
    staged_manifest payload.bin || return 1
    mkdir -p "$CASE/bin"
    export PATH="$CASE/bin:$PATH" SBOM_TEST_LOG="$CASE/scans" SBOM_TEST_CALLS="$CALLS"
    export SBOM_TEST_FAIL="" SBOM_TEST_CHANGE_SOURCE="" SBOM_TEST_CHANGE_MANIFEST=""
    : > "$SBOM_TEST_LOG"
    cat > "$CASE/bin/syft" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
source_path="" format=spdx
for arg in "$@"; do
    case "$arg" in file:*) source_path="${arg#file:}" ;; cyclonedx-json) format=cyclonedx ;; esac
done
[[ -f "$source_path" ]] || exit 4
name="${source_path##*/}"
printf '%s\n' "$name" >> "$SBOM_TEST_LOG"
printf 'SCAN-SBOM %s\n' "$name" >> "$SBOM_TEST_CALLS"
if [[ "$name" == "$SBOM_TEST_FAIL" ]]; then
    printf '{"incomplete":'; exit 17
fi
[[ -z "$SBOM_TEST_CHANGE_SOURCE" ]] || printf 'changed by scanner\n' >> "$SBOM_TEST_CHANGE_SOURCE"
[[ -z "$SBOM_TEST_CHANGE_MANIFEST" ]] || printf ' ' >> "$SBOM_TEST_CHANGE_MANIFEST"
digest=$(sha256sum "$source_path"); digest="${digest%% *}"
if [[ "$format" == spdx ]]; then
    jq -nc --arg name "$name" --arg digest "$digest" '
      {spdxVersion:"SPDX-2.3",dataLicense:"CC0-1.0",SPDXID:"SPDXRef-DOCUMENT",name:$name,
       documentNamespace:("https://example.test/"+$digest),
       creationInfo:{creators:["Tool: controlled-syft"],created:"2026-10-23T00:00:00Z"},packages:[]}'
else
    jq -nc --arg name "$name" '{bomFormat:"CycloneDX",specVersion:"1.6",version:1,
      components:[{type:"application",name:$name}]}'
fi
SH
    chmod +x "$CASE/bin/syft"
}

sbom_remote_matches() {
    local name="$1" id
    id=$(jq -er --arg name "$name" '.[] | select(.name==$name) | .id' "$CASE/inventory.json") || return 1
    cmp -s "$CASE/artifacts/$name" "$CASE/remote/$id"
}

sbom_no_publication() {
    ! grep -Eq '^(CREATE|POST|PUBLISH|DISPATCH)' "$CALLS"
}

test_sbom_complete_release_publishes_exact_documents() {
    sbom_setup sbom_complete || return 1
    run_release --sbom
    [[ $STATUS -eq 0 && $(wc -l < "$SBOM_TEST_LOG") -eq 1 ]] &&
        sbom_remote_matches payload.bin.sbom.spdx.json && sbom_remote_matches sbom-manifest.spdx.json &&
        jq -e --arg sha "$(_gh_asset_sha256 "$CASE/artifacts/sbom-manifest.spdx.json")" '
          .details.sbom | .enabled and .published and .status=="verified" and .format=="spdx" and
          .artifact_count==1 and .manifest_sha256==$sha and
          .files==["payload.bin.sbom.spdx.json","sbom-manifest.spdx.json"] and
          keys==["artifact_count","enabled","filename","files","format","manifest_sha256","published","status"]' \
            "$CASE/stdout" >/dev/null &&
        jq -e 'length==6 and all(.[]; (.name | endswith(".dsr.json") or startswith("sbom-plan.") | not))' \
            "$CASE/inventory.json" >/dev/null
}

test_sbom_manifest_selects_aliases_and_runtime_metadata() {
    sbom_setup sbom_selection || return 1
    cp "$CASE/artifacts/payload.bin" "$CASE/artifacts/payload-compat.bin"
    printf 'license bytes\n' > "$CASE/artifacts/LICENSE"
    printf '{"runtime":"required"}\n' > "$CASE/artifacts/runtime.json"
    staged_manifest payload.bin payload-compat.bin LICENSE runtime.json || return 1
    run_release --sbom
    [[ $STATUS -eq 0 && $(wc -l < "$SBOM_TEST_LOG") -eq 4 ]] &&
        jq -e '[.artifacts[].artifact.name]==["LICENSE","payload-compat.bin","payload.bin","runtime.json"]' \
            "$CASE/artifacts/sbom-manifest.spdx.json" >/dev/null &&
        sbom_remote_matches runtime.json.sbom.spdx.json && sbom_remote_matches LICENSE.sbom.spdx.json
}

test_sbom_cyclonedx_format_implies_generation() {
    sbom_setup sbom_cyclonedx || return 1
    run_release --sbom-format cyclonedx-json
    [[ $STATUS -eq 0 ]] && sbom_remote_matches sbom-manifest.cdx.json &&
        jq -e '.bomFormat=="CycloneDX"' "$CASE/artifacts/payload.bin.sbom.cdx.json" >/dev/null &&
        jq -e '.details.sbom.format=="cyclonedx" and .details.sbom.published' "$CASE/stdout" >/dev/null
}

test_sbom_configured_policy_generates_coverage() {
    sbom_setup sbom_configured || return 1
    printf 'sbom:\n  enabled: true\n  format: spdx-json\n' > "$DSR_CONFIG_FILE"
    run_release
    [[ $STATUS -eq 0 ]] && sbom_remote_matches sbom-manifest.spdx.json
}

test_sbom_explicit_disable_overrides_configuration() {
    sbom_setup sbom_disabled || return 1
    printf 'sbom:\n  enabled: true\n' > "$DSR_CONFIG_FILE"
    run_release --no-sbom
    [[ $STATUS -eq 0 && ! -s "$SBOM_TEST_LOG" && ! -e "$CASE/artifacts/sbom-manifest.spdx.json" ]] &&
        jq -e '.details.sbom=={enabled:false,status:"disabled",published:false}' "$CASE/stdout" >/dev/null
}

test_sbom_scan_failure_resumes_completed_pairs() {
    sbom_setup sbom_failed_scan || return 1
    printf 'second payload\n' > "$CASE/artifacts/z.bin"
    staged_manifest payload.bin z.bin || return 1
    SBOM_TEST_FAIL=z.bin
    run_release --sbom
    [[ $STATUS -ne 0 && ! -e "$CASE/artifacts/sbom-manifest.spdx.json" ]] &&
        sbom_no_publication && [[ $(wc -l < "$SBOM_TEST_LOG") -eq 2 ]] || return 1
    cp "$CASE/artifacts/payload.bin.sbom.spdx.json" "$CASE/completed.before"
    SBOM_TEST_FAIL=""
    run_release --sbom
    [[ $STATUS -eq 0 && $(wc -l < "$SBOM_TEST_LOG") -eq 3 ]] &&
        cmp -s "$CASE/completed.before" "$CASE/artifacts/payload.bin.sbom.spdx.json" &&
        sbom_remote_matches z.bin.sbom.spdx.json
}

test_sbom_missing_scanner_blocks_release() {
    sbom_setup sbom_missing_scanner || return 1
    command() {
        [[ "${1:-}" != -v || "${2:-}" != syft ]] || return 1
        builtin command "$@"
    }
    run_release --sbom
    [[ $STATUS -eq 3 && ! -s "$SBOM_TEST_LOG" ]] && sbom_no_publication
}

test_sbom_changed_payload_blocks_release() {
    sbom_setup sbom_payload_drift || return 1
    SBOM_TEST_CHANGE_SOURCE="$CASE/artifacts/payload.bin"
    run_release --sbom
    [[ $STATUS -ne 0 ]] && sbom_no_publication
}

test_sbom_changed_manifest_blocks_release() {
    sbom_setup sbom_manifest_drift || return 1
    SBOM_TEST_CHANGE_MANIFEST="$CASE/artifacts/tool-v1.2.3-manifest.json"
    run_release --sbom
    [[ $STATUS -ne 0 ]] && sbom_no_publication
}

# Mutate only after the real generation/verification helper has succeeded.
# Publication must retain its complete verified names and digests instead of
# blessing whatever a later directory discovery happens to find.
sbom_handoff_drift_case() {
    local sbom_handoff_name="$1" sbom_handoff_action="$2"
    sbom_setup "sbom_handoff_${sbom_handoff_action}_${sbom_handoff_name//./_}" || return 1
    # shellcheck source=/dev/null
    source <(
        printf 'sbom_prepare_before_handoff_drift() (\n'
        awk '/^_release_prepare_ordinary_sbom\(\) \(/{copy=1; next}
            copy{print} copy && /^\)/{exit}' "${DSR_TEST_HELPERS_FILE:-$PROJECT_ROOT/dsr}"
    ) || return 1
    _release_prepare_ordinary_sbom() {
        local sbom_handoff_report sbom_handoff_path="$CASE/artifacts/$sbom_handoff_name"
        sbom_handoff_report=$(sbom_prepare_before_handoff_drift "$@") || return $?
        case "$sbom_handoff_action" in
            changed)
                cp "$sbom_handoff_path" "$CASE/verified.before" || return 1
                printf ' ' >> "$sbom_handoff_path" || return 1 ;;
            missing)
                mv "$sbom_handoff_path" "$CASE/verified.before" || return 1 ;;
            *) return 1 ;;
        esac
        printf 'SBOM-HANDOFF-MUTATION\n' >> "$CALLS"
        printf '%s\n' "$sbom_handoff_report"
    }
    run_release --sbom
    [[ $STATUS -ne 0 && -s "$CASE/verified.before" && $(wc -l < "$SBOM_TEST_LOG") -eq 1 ]] &&
        grep -Fxq SBOM-HANDOFF-MUTATION "$CALLS" && sbom_no_publication
}

test_sbom_changed_document_at_handoff_blocks_creation() {
    sbom_handoff_drift_case payload.bin.sbom.spdx.json changed
}

test_sbom_missing_document_at_handoff_blocks_creation() {
    sbom_handoff_drift_case payload.bin.sbom.spdx.json missing
}

test_sbom_changed_aggregate_at_handoff_blocks_creation() {
    sbom_handoff_drift_case sbom-manifest.spdx.json changed
}

test_sbom_missing_aggregate_at_handoff_blocks_creation() {
    sbom_handoff_drift_case sbom-manifest.spdx.json missing
}

test_sbom_aggregate_changes_after_verification_blocks_creation() {
    sbom_setup sbom_aggregate_after_verification || return 1
    # Preserve the loaded production verifier body; do not replace validation.
    # shellcheck source=/dev/null
    source <(
        printf 'sbom_verify_before_aggregate_drift()\n'
        declare -f sbom_verify_artifacts | awk 'NR > 1 {print}'
    ) || return 1
    sbom_verify_artifacts() {
        local sbom_verified_output
        sbom_verified_output=$(sbom_verify_before_aggregate_drift "$@") || return $?
        [[ "$sbom_verified_output" == "$CASE/artifacts/sbom-manifest.spdx.json" ]] || return 1
        cp "$sbom_verified_output" "$CASE/verified.before" || return 1
        printf ' ' >> "$sbom_verified_output" || return 1
        printf 'SBOM-VERIFIER-MUTATION\n' >> "$CALLS"
        printf '%s\n' "$sbom_verified_output"
    }
    run_release --sbom
    [[ $STATUS -ne 0 && -s "$CASE/verified.before" && $(wc -l < "$SBOM_TEST_LOG") -eq 1 ]] &&
        grep -Fxq SBOM-VERIFIER-MUTATION "$CALLS" && sbom_no_publication
}

test_sbom_changed_document_cannot_be_regenerated_on_resume() {
    sbom_setup sbom_document_drift || return 1
    run_release --sbom
    [[ $STATUS -eq 0 ]] || return 1
    printf ' ' >> "$CASE/artifacts/payload.bin.sbom.spdx.json"
    cp "$CASE/artifacts/payload.bin.sbom.spdx.json" "$CASE/changed.before"
    : > "$CALLS"
    run_release --resume --sbom
    [[ $STATUS -ne 0 && $(wc -l < "$SBOM_TEST_LOG") -eq 1 ]] && sbom_no_publication &&
        cmp -s "$CASE/changed.before" "$CASE/artifacts/payload.bin.sbom.spdx.json"
}

test_sbom_publication_resume_reuses_verified_scans() {
    sbom_setup sbom_resume || return 1
    PUBLISH_FAIL=true
    run_release --sbom
    [[ $STATUS -ne 0 ]] && jq -e '.draft==true' "$CASE/release.json" >/dev/null || return 1
    cp "$CASE/artifacts/sbom-manifest.spdx.json" "$CASE/aggregate.before"
    mv "$CASE/bin/syft" "$CASE/syft.retained"
    PUBLISH_FAIL=false
    : > "$CALLS"
    run_release --resume --sbom
    [[ $STATUS -eq 0 && $(wc -l < "$SBOM_TEST_LOG") -eq 1 ]] &&
        ! grep -Eq '^POST |^CREATE|^SCAN-SBOM' "$CALLS" && grep -Fxq PUBLISH "$CALLS" &&
        cmp -s "$CASE/aggregate.before" "$CASE/artifacts/sbom-manifest.spdx.json" &&
        jq -e '.details.sbom.published and .details.sbom.status=="verified"' "$CASE/stdout" >/dev/null
}

test_sbom_retained_public_inventory_survives_disabled_generation() {
    sbom_setup sbom_disabled_retry || return 1
    PUBLISH_FAIL=true
    run_release --sbom
    [[ $STATUS -ne 0 ]] || return 1
    PUBLISH_FAIL=false
    : > "$CALLS"
    run_release --resume --no-sbom
    [[ $STATUS -eq 0 && $(wc -l < "$SBOM_TEST_LOG") -eq 1 ]] &&
        ! grep -Eq '^POST |^CREATE|^SCAN-SBOM' "$CALLS" && grep -Fxq PUBLISH "$CALLS" &&
        sbom_remote_matches sbom-manifest.spdx.json && sbom_remote_matches payload.bin.sbom.spdx.json
}

test_sbom_dry_run_has_complete_plan_without_scanning() {
    sbom_setup sbom_dry_run || return 1
    DRY_RUN=true
    run_release --sbom
    [[ $STATUS -eq 0 && ! -s "$CALLS" && ! -s "$SBOM_TEST_LOG" &&
       ! -e "$CASE/artifacts/sbom-plan.spdx.json" && ! -e "$CASE/artifacts/SHA256SUMS" ]] &&
        jq -e '.details | .file_count==6 and .sbom.enabled and (.sbom.published|not) and
          .sbom.status=="planned" and .sbom.manifest_sha256==null and
          (.sbom | keys==["artifact_count","enabled","filename","files","format","manifest_sha256","published","status"]) and
          (.plan.additional_files | index("sbom-manifest.spdx.json")!=null and
              index("payload.bin.sbom.spdx.json")!=null)' "$CASE/stdout" >/dev/null
}

test_sbom_strict_contract_rejects_automatic_extra_assets() {
    sbom_setup sbom_strict || return 1
    STRICT_CONTRACT='{}'
    run_release --sbom
    [[ $STATUS -eq 4 && ! -s "$CALLS" && ! -s "$SBOM_TEST_LOG" ]]
}

test_sbom_requires_manifested_release() {
    sbom_setup sbom_no_manifest || return 1
    mv "$CASE/artifacts/tool-v1.2.3-manifest.json" "$CASE/manifest.saved"
    run_release --sbom
    [[ $STATUS -eq 4 ]] && sbom_no_publication
}

test_sbom_invalid_options_fail_before_scanning() {
    sbom_setup sbom_bad_options || return 1
    local option
    for option in missing invalid contradictory; do
        case "$option" in
            missing) run_release --sbom-format ;;
            invalid) run_release --sbom-format unknown ;;
            contradictory) run_release --no-sbom --sbom-format spdx ;;
        esac
        [[ $STATUS -eq 4 && ! -s "$CALLS" && ! -s "$SBOM_TEST_LOG" ]] || return 1
    done
    printf 'sbom:\n  enabled: sometimes\n' > "$DSR_CONFIG_FILE"
    run_release
    [[ $STATUS -eq 4 && ! -s "$CALLS" ]]
}

test_sbom_derived_name_collision_refuses_before_scanning() {
    sbom_setup sbom_name_collision || return 1
    printf 'payload occupying a metadata name\n' > "$CASE/artifacts/sbom-manifest.spdx.json"
    staged_manifest payload.bin sbom-manifest.spdx.json || return 1
    run_release --sbom
    [[ $STATUS -eq 4 && ! -s "$CALLS" && ! -s "$SBOM_TEST_LOG" ]]
}

test_sbom_linked_document_preserves_external_target() {
    sbom_setup sbom_linked_document || return 1
    printf 'unrelated file\n' > "$CASE/external"
    cp "$CASE/external" "$CASE/external.before"
    ln -s "$CASE/external" "$CASE/artifacts/payload.bin.sbom.spdx.json"
    run_release --sbom
    [[ $STATUS -ne 0 && ! -s "$SBOM_TEST_LOG" ]] && sbom_no_publication &&
        cmp -s "$CASE/external" "$CASE/external.before"
}

test_sbom_missing_aggregate_blocks_publication() {
    sbom_setup sbom_missing_aggregate || return 1
    DROP_SIDECAR=sbom-manifest.spdx.json
    run_release --sbom
    [[ $STATUS -ne 0 ]] && ! grep -Eq '^PUBLISH|^DISPATCH' "$CALLS" &&
        jq -e '.draft==true' "$CASE/release.json" >/dev/null
}

for test in test_saved_name_missing_remotely_is_uploaded test_identical_remote_is_reused_without_deletion \
    test_saved_name_with_changed_remote_fails_closed test_legacy_digestless_assets_are_hashed \
    test_unavailable_inventory_is_not_success test_failed_resume_lookup_never_creates \
    test_draft_resume_does_not_dispatch_or_verify_upgrade test_named_upload_emits_one_json_envelope \
    test_missing_manifest_artifact_blocks_creation test_changed_local_manifest_artifact_blocks_creation \
    test_wrong_release_identity_cannot_upload test_lost_upload_response_reconciles_real_bytes \
    test_strict_preflight_remains_required test_dry_run_has_no_network_or_checkpoint_writes \
    test_dry_run_plans_every_upload_name test_dry_run_reports_installer_mismatch \
    test_release_records_installer_check_after_upload test_installer_mismatch_does_not_fail_verified_release \
    test_variants_publish_under_their_own_triple_names test_shared_variant_names_go_to_the_primary_build \
    test_shared_variant_names_upload_without_collision \
    test_remote_drift_after_upload_prevents_success test_release_visibility_drift_prevents_dispatch \
    test_checkpoint_symlink_failure_preserves_foreign_file test_checkpoint_receipt_is_bound_and_private \
    test_partial_release_resumes_only_missing_upload test_completed_release_resume_does_not_reupload \
    test_release_dispatch_accepted_outbox_survives_new_process_ids \
    test_release_dispatch_retries_only_rejected_destination \
    test_release_dispatch_uncertain_requires_explicit_retry \
    test_release_dispatch_custom_event_and_canonical_payload \
    test_release_dispatch_plan_drift_preserves_original_work \
    test_release_dispatch_refuses_unresolved_source_without_sending \
    test_release_dispatch_explicit_config_false_prevents_delivery \
    test_release_dispatch_rechecks_publication_between_destinations \
    test_release_dispatch_saved_outbox_recovers_without_local_artifacts \
    test_release_dispatch_saved_status_is_read_only_without_auth \
    test_release_dispatch_saved_uncertain_requires_explicit_retry \
    test_release_dispatch_saved_recovery_refuses_remote_drift \
    test_release_dispatch_saved_state_is_validated_before_network \
    test_invalid_journal_is_not_upload_authority test_empty_artifacts_are_not_a_release \
    test_unmanifested_directory_is_refused test_artifacts_must_come_from_the_tagged_commit \
    test_draft_request_refuses_published_release test_wrong_repository_upload_url_is_rejected \
    test_staged_creation_publishes_only_after_private_uploads test_staged_dry_run_creates_no_custody \
    test_staged_interrupted_upload_resumes_and_publishes test_staged_generated_checksums_remain_bound_across_retry \
    test_staged_manifest_aliases_are_all_verified test_staged_explicit_draft_stays_private_on_resume \
    test_staged_explicit_draft_published_manually_resumes test_staged_manual_publication_drift_is_not_redrafted \
    test_staged_manual_publication_rejects_draft_request \
    test_staged_lost_publish_response_requires_public_proof test_staged_failed_publish_retries_without_reupload \
    test_staged_already_public_retry_verifies_original_plan test_staged_already_public_retry_refuses_extra_asset \
    test_staged_extra_asset_blocks_first_publication test_staged_missing_selected_sidecar_blocks_publication \
    test_staged_changed_notes_are_not_published_or_overwritten test_staged_postpublish_asset_drift_restores_owned_draft \
    test_staged_changed_destination_is_not_published test_staged_postpublish_destination_drift_is_not_overwritten \
    test_staged_postpublish_metadata_drift_is_not_overwritten test_staged_lost_original_post_is_never_adopted \
    test_staged_changed_inputs_are_not_adopted_on_resume test_staged_nonprivate_receipt_cannot_authorize_resume \
    test_staged_ambiguous_receipts_cannot_authorize_resume test_staged_intent_drift_during_create_blocks_upload \
    test_staged_storage_refusal_precedes_creation test_staged_concurrent_complete_publication_is_preserved \
    test_staged_pinned_tag_is_verified test_staged_moved_tag_blocks_publication \
    test_staged_unavailable_tag_blocks_publication test_staged_postpublish_tag_drift_restores_draft \
    test_staged_absent_tag_is_created_at_pinned_commit test_staged_absent_tag_with_prefix_sibling_can_publish \
    test_staged_absent_tag_probe_unavailable_is_refused test_staged_absent_tag_probe_malformed_is_refused \
    test_staged_absent_tag_probe_nonarray_is_refused test_staged_absent_tag_probe_exact_ref_is_refused \
    test_staged_absent_tag_probe_wrong_repository_is_refused test_staged_absent_tag_created_at_wrong_commit_is_redrafted \
    test_sbom_complete_release_publishes_exact_documents test_sbom_manifest_selects_aliases_and_runtime_metadata \
    test_sbom_cyclonedx_format_implies_generation test_sbom_configured_policy_generates_coverage \
    test_sbom_explicit_disable_overrides_configuration test_sbom_scan_failure_resumes_completed_pairs \
    test_sbom_missing_scanner_blocks_release test_sbom_changed_payload_blocks_release \
    test_sbom_changed_manifest_blocks_release test_sbom_changed_document_cannot_be_regenerated_on_resume \
    test_sbom_changed_document_at_handoff_blocks_creation test_sbom_missing_document_at_handoff_blocks_creation \
    test_sbom_changed_aggregate_at_handoff_blocks_creation test_sbom_missing_aggregate_at_handoff_blocks_creation \
    test_sbom_aggregate_changes_after_verification_blocks_creation \
    test_sbom_publication_resume_reuses_verified_scans test_sbom_retained_public_inventory_survives_disabled_generation \
    test_sbom_dry_run_has_complete_plan_without_scanning test_sbom_strict_contract_rejects_automatic_extra_assets \
    test_sbom_requires_manifested_release test_sbom_invalid_options_fail_before_scanning \
    test_sbom_derived_name_collision_refuses_before_scanning test_sbom_linked_document_preserves_external_target \
    test_sbom_missing_aggregate_blocks_publication; do
    [[ -z "${DSR_RELEASE_RESUME_TEST_FILTER:-}" || "$test" =~ $DSR_RELEASE_RESUME_TEST_FILTER ]] || continue
    run_test "$test"
done
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
