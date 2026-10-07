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
# Load the real command without dispatching the CLI or contacting build hosts.
source <(awk '/^cmd_release\(\) \{/{copy=1} copy{print} copy && /^\}/{exit}' "${DSR_TEST_COMMAND_FILE:-$PROJECT_ROOT/dsr}")

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dsr-release-resume-tests.XXXXXXXX")
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
_dispatch_load_config() { printf 'true|release-ready|owner/downstream\n'; }
_dispatch_is_true() { [[ "$1" == true ]]; }
_dispatch_send_all() { printf 'DISPATCH\n' >> "$CALLS"; printf '[]\n'; }
gh_resolve_tag_sha() { printf '%040d\n' 1; }
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
    mkdir -p "$CASE/artifacts" "$CASE/remote" "$CASE/state/releases" "$CASE/tmp" "$CASE/config/repos.d"
    export DSR_STATE_DIR="$CASE/state" TMPDIR="$CASE/tmp" NO_COLOR=1
    export DSR_CONFIG_DIR="$CASE/config" DSR_REPOS_FILE="$CASE/config/repos.yaml"
    export ACT_REPOS_DIR="$CASE/config/repos.d"
    # The real retained-inventory gate consults the configured execution
    # lane. These fixtures describe local native artifacts, not an act job.
    printf 'targets: [linux/amd64]\n' > "$ACT_REPOS_DIR/tool.yaml"
    CALLS="$CASE/calls"
    : > "$CALLS"
    printf '[]\n' > "$CASE/inventory.json"
    jq -nc '{id:9,tag_name:"v1.2.3",draft:false,prerelease:false,
      upload_url:"https://uploads.github.com/repos/owner/repo/releases/9/assets{?name,label}",
      html_url:"https://github.com/owner/repo/releases/tag/v1.2.3",assets:[]}' > "$CASE/release.json"
    printf 'real payload\n' > "$CASE/artifacts/payload.bin"
    JSON_MODE=true DRY_RUN=false STRICT_CONTRACT=null COLLIDE_NAMES=false
    LOOKUP_FAIL=false INVENTORY_FAIL=false UPLOAD_FAIL=false LOST_RESPONSE=false
    CREATE_FAIL=true FINAL_DRIFT=false VISIBILITY_DRIFT=false FAIL_NAME=""
    GH_MAX_RETRIES=2 GH_RETRY_DELAY=0
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
    local name="$1" target="${2:-}" format="${3:-none}" sha
    sha=$(_gh_asset_sha256 "$CASE/artifacts/$name") || return 1
    jq -nc --arg name "$name" --arg sha "$sha" --arg target "$target" --arg format "$format" \
        '{tool:"tool",version:"v1.2.3",status:"success",
          artifacts:[{name:$name,sha256:$sha,target:$target,archive_format:$format}]}' > \
        "$CASE/artifacts/tool-v1.2.3-manifest.json"
}

_release_contract_scan_release_by_tag() {
    printf 'SCAN %s %s\n' "$1" "$2" >> "$CALLS"
    $LOOKUP_FAIL && return 8
    jq -nc --slurpfile release "$CASE/release.json" '{count:1,release:$release[0]}'
}

gh_create_release() {
    printf 'CREATE\n' >> "$CALLS"
    $CREATE_FAIL && return 22
    cat "$CASE/release.json"
}

gh_api() {
    printf 'API %s\n' "$*" >> "$CALLS"
    case "$1" in
        repos/owner/repo/releases/9/assets\?per_page=100\&page=*)
            $INVENTORY_FAIL && return 8
            local page="${1##*page=}"
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
            local id="${1##*/}"
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

curl() {
    local response="" headers="" payload="" url="" arg name
    while (($#)); do
        arg="$1"; shift
        case "$arg" in
            -o) response="$1"; shift ;;
            -D) headers="$1"; shift ;;
            --data-binary) payload="${1#@}"; shift ;;
            https://uploads.github.com/*) url="$arg" ;;
        esac
    done
    [[ -n "$response" && -n "$headers" && -n "$payload" && -n "$url" ]] || return 4
    name="${url##*?name=}"
    name="${name//%2B/+}"
    printf 'POST %s\n' "$name" >> "$CALLS"
    printf 'HTTP/1.1 201 Created\r\n\r\n' > "$headers"
    if $UPLOAD_FAIL || [[ "$name" == "$FAIL_NAME" ]]; then printf '503'; return 0; fi
    remote_put "$name" "$payload" || return 4
    jq -c '.[-1]' "$CASE/inventory.json" > "$response"
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
    cmd_release tool 1.2.3 --artifacts "$CASE/artifacts" ${manifest_args[@]+"${manifest_args[@]}"} "$@" \
        > "$CASE/stdout" 2> "$CASE/stderr" || STATUS=$?
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
    [[ $STATUS -eq 0 ]] && ! grep -q '^DISPATCH\|^UPGRADE' "$CALLS" &&
        jq -e '.details.draft==true and .details.prerelease==true' "$CASE/stdout" >/dev/null
}

test_named_upload_emits_one_json_envelope() {
    setup aliases
    cp "$CASE/artifacts/payload.bin" "$CASE/artifacts/tool-linux-amd64.tar.gz"
    manifest tool-linux-amd64.tar.gz linux/amd64 tar.gz
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
    cp "$CASE/artifacts/payload.bin" "$CASE/artifacts/tool-linux-amd64.tar.gz"
    manifest tool-linux-amd64.tar.gz linux/amd64 tar.gz
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
    cp "$CASE/artifacts/payload.bin" "$CASE/artifacts/tool-linux-amd64.tar.gz"
    manifest tool-linux-amd64.tar.gz linux/amd64 tar.gz
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
    local name rows='[]' sha triple
    for name in "$@"; do
        printf '%s payload\n' "$name" > "$CASE/artifacts/$name"
        sha=$(_gh_asset_sha256 "$CASE/artifacts/$name") || return 1
        triple=$(artifact_naming_artifact_variant tool linux amd64 "$name") || return 1
        triple="${triple%%$'\t'*}"
        rows=$(jq -c --arg name "$name" --arg sha "$sha" --arg triple "$triple" \
            '. + [{name:$name,sha256:$sha,target:"linux/amd64",target_triple:$triple,
                   archive_format:"tar.gz"}]' <<< "$rows")
    done
    jq -nc --argjson rows "$rows" '{tool:"tool",version:"v1.2.3",status:"success",artifacts:$rows}' > \
        "$CASE/artifacts/tool-v1.2.3-manifest.json"
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
    [[ $STATUS -eq 0 ]] &&
        [[ "$(planned_names tool-1.2.3-linux-amd64-musl.tar.gz)" == '["tool-1.2.3-linux-amd64-musl.tar.gz"]' ]] &&
        [[ "$(planned_names tool-1.2.3-linux-amd64.tar.gz)" == \
            '["tool-1.2.3-linux-amd64.tar.gz","tool-linux-amd64.tar.gz","tool-linux-x86_64.tar.gz"]' ]] &&
        grep -q 'Upload name tool-linux-amd64.tar.gz is derived by several variants; publishing it as tool-1.2.3-linux-amd64.tar.gz' "$CASE/stderr"
}

test_shared_variant_names_upload_without_collision() {
    setup variant_upload
    TRIPLE_NAMING=false
    variant_fixture tool-1.2.3-linux-amd64-musl.tar.gz tool-1.2.3-linux-amd64.tar.gz
    run_release --resume
    local gnu_sha compat_sha
    gnu_sha=$(_gh_asset_sha256 "$CASE/artifacts/tool-1.2.3-linux-amd64.tar.gz")
    compat_sha=$(jq -r '.[] | select(.name == "tool-linux-amd64.tar.gz") | .digest' "$CASE/inventory.json")
    [[ $STATUS -eq 0 && "$compat_sha" == "sha256:$gnu_sha" ]] &&
        [[ "$(grep -c '^POST tool-linux-amd64.tar.gz$' "$CALLS")" == 1 ]] &&
        grep -Fxq 'POST tool-1.2.3-linux-amd64-musl.tar.gz' "$CALLS" &&
        grep -q "^$gnu_sha  tool-linux-amd64.tar.gz\$" "$CASE/artifacts/SHA256SUMS" &&
        ! grep -q 'Different artifact contents' "$CASE/stderr"
}

test_remote_drift_after_upload_prevents_success() {
    setup final_drift
    FINAL_DRIFT=true
    run_release --resume
    [[ $STATUS -eq 1 ]] && ! grep -q '^DISPATCH' "$CALLS" &&
        jq -e '.details.verification=="incomplete" and .details.failed>0' "$CASE/stdout" >/dev/null
}

test_release_visibility_drift_prevents_dispatch() {
    setup visibility_drift
    VISIBILITY_DRIFT=true
    run_release --resume
    [[ $STATUS -eq 1 ]] && ! grep -q '^DISPATCH' "$CALLS" &&
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
    local tagged head original_create
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
    original_create=$(declare -f gh_create_release)
    gh_create_release() { printf 'CREATE %s\n' "$*" >> "$CALLS"; cat "$CASE/release.json"; }
    run_release
    eval "$original_create"
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
    test_invalid_journal_is_not_upload_authority test_empty_artifacts_are_not_a_release \
    test_unmanifested_directory_is_refused test_artifacts_must_come_from_the_tagged_commit \
    test_draft_request_refuses_published_release \
    test_wrong_repository_upload_url_is_rejected; do
    run_test "$test"
done
printf 'Results: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
