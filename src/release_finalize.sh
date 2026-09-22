#!/usr/bin/env bash
# Public entry point for existing finalization and complete build-set ingestion.
# The existing engine is retained byte-for-byte in release_finalize_core.sh.
_RELEASE_FINALIZE_ENTRY_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=src/release_finalize_core.sh
source "$_RELEASE_FINALIZE_ENTRY_DIR/release_finalize_core.sh" || { return 3 2>/dev/null || exit 3; }

# Build-set mode owns repo/tag/SHA/tool and the aggregate manifest. Publication
# policy remains explicit and is still checked by the existing engine.
_rf_build_set_execute() (
    set -uo pipefail
    local plan='' bundle='' dry="${DRY_RUN:-false}" option value work canonical
    local require_signatures=false prepared=false create=false promote=false dispatch=''
    local public='' secret='' integrity='' notes='' title='' prerelease=false retry_creation=false
    local dispatch_run='' dispatch_state='' retry_delivery=false format=spdx metadata='' state=''
    local -a forwarded=() collect_args=()
    local -A seen=()
    while (($#)); do
        option=$1
        [[ "$option" != -n ]] || option=--dry-run
        [[ -n "$option" && -z "${seen[$option]:-}" ]] || return 4
        seen[$option]=1
        case "$option" in
            --build-set|--bundle-dir|--format|--output-dir|--state-dir|--public-key|--secret-key|--integrity-dir|--release-name|--release-notes-file|--dispatch-repos|--dispatch-run-id|--dispatch-state-dir)
                [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || return 4
                value=$2
                case "$option" in
                    --build-set) plan=$value ;; --bundle-dir) bundle=$value ;;
                    --format) format=$value ;; --output-dir) metadata=$value ;; --state-dir) state=$value ;;
                    --public-key) public=$value ;; --secret-key) secret=$value ;; --integrity-dir) integrity=$value ;;
                    --release-name) title=$value ;; --release-notes-file) notes=$value ;;
                    --dispatch-repos) dispatch=$value ;; --dispatch-run-id) dispatch_run=$value ;; --dispatch-state-dir) dispatch_state=$value ;;
                esac
                case "$option" in --build-set|--bundle-dir) ;; *) forwarded+=("$option" "$value") ;; esac
                shift 2 ;;
            --dry-run) dry=true; shift ;;
            --require-signatures|--prepared-signatures|--create-draft|--promote|--prerelease|--retry-creation|--retry-uncertain)
                case "$option" in
                    --require-signatures) require_signatures=true ;; --prepared-signatures) prepared=true ;;
                    --create-draft) create=true ;; --promote) promote=true ;; --prerelease) prerelease=true ;;
                    --retry-creation) retry_creation=true ;; --retry-uncertain) retry_delivery=true ;;
                esac
                forwarded+=("$option"); shift ;;
            *) printf '[release-finalize] Unknown or plan-owned build-set option: %s\n' "$option" >&2; return 4 ;;
        esac
    done
    [[ -f "$plan" && ! -L "$plan" && "$dry" =~ ^(true|false)$ ]] || return 4
    case "$format" in spdx|spdx-json|cyclonedx|cdx|cyclonedx-json) ;; *) return 4 ;; esac
    if [[ "$prepared" == true ]]; then
        [[ "$require_signatures" == false && -z "$secret" && -n "$public" && -n "$integrity" ]] || return 4
    elif [[ "$require_signatures" == true ]]; then
        [[ -n "$public" ]] || return 4
    else
        [[ -z "$public$secret$integrity" ]] || return 4
    fi
    if [[ "$create" == false ]]; then
        [[ -z "$title$notes" && "$prerelease" == false && "$retry_creation" == false ]] || return 4
    elif [[ -n "$dispatch" && "$promote" != true ]]; then
        return 4
    fi
    if [[ -z "$dispatch" ]]; then
        [[ -z "$dispatch_run$dispatch_state" && "$retry_delivery" == false ]] || return 4
    fi
    # Validate local policy-file selections without executing or publishing them.
    for value in "$public" "$secret" "$notes"; do
        [[ -z "$value" || ( -f "$value" && ! -L "$value" ) ]] || return 4
    done
    # shellcheck source=src/release_bundle.sh
    source "$_RELEASE_FINALIZE_ENTRY_DIR/release_bundle.sh" || return 3
    _rb_require || return $?
    _rb_path "$bundle" || return 4
    [[ "$bundle" != / && "$bundle" != */ ]] || return 4
    for value in "$metadata" "$state" "$integrity" "$dispatch_state"; do
        [[ -n "$value" ]] || continue
        _rb_path "$value" || return 4
        case "$value" in
            "$bundle"|"$bundle/"|"$bundle/release"|"$bundle/release/"*|"$bundle/inputs"|"$bundle/inputs/"*)
                _rb_log 'Finalizer output/state must stay outside immutable release and input directories'; return 4 ;;
        esac
    done
    [[ -n "$metadata" ]] || forwarded+=(--output-dir "$bundle/metadata")
    [[ -n "$state" ]] || forwarded+=(--state-dir "$bundle/finalization")
    work=$(mktemp -d "${TMPDIR:-/tmp}/dsr-build-set-finalize.XXXXXXXX") || return 1
    trap 'rm -rf -- "$work"' EXIT
    trap 'exit 5' HUP INT TERM
    canonical=$(_rb_plan "$plan") || return $?
    printf '%s\n' "$canonical" > "$work/plan.json" || return 1
    local repo tag sha tool pin rc=0 result
    repo=$(jq -r .repo "$work/plan.json") || return 1
    tag=$(jq -r .tag "$work/plan.json") || return 1
    sha=$(jq -r .source_sha "$work/plan.json") || return 1
    tool=$(jq -r .tool "$work/plan.json") || return 1
    # --tool belongs to downstream dispatch in the existing engine, not its
    # generic release interface. Supplying it without dispatch is an error.
    [[ -z "$dispatch" ]] || forwarded+=(--tool "$tool")
    collect_args=(--plan "$work/plan.json" --output-dir "$bundle")
    if [[ "$dry" == true ]]; then
        release_bundle "${collect_args[@]}" --dry-run > "$work/collection.json" || return $?
        jq -cn --args '$ARGS.positional' -- "${forwarded[@]}" > "$work/options.json" || return 1
        jq -cn --slurpfile collection "$work/collection.json" --slurpfile options "$work/options.json" \
            '{kind:"dsr-release-finalization-result",status:"planned",exit_code:0,dry_run:true,
              stage:"build-set-plan",bundle:$collection[0],finalization_options:$options[0],
              policy_verified:false}'
        return $?
    fi
    release_bundle "${collect_args[@]}" > "$work/collection.json" || rc=$?
    if ((rc != 0)); then
        if [[ "$rc" == 1 ]] && jq -es 'length==1 and (.[0]|.kind=="dsr-release-bundle" and
            .status=="incomplete" and .publishable==false)' "$work/collection.json" >/dev/null 2>&1; then
            jq -cn --slurpfile bundle "$work/collection.json" \
                '{kind:"dsr-release-finalization-result",status:"waiting_for_builds",exit_code:1,
                  dry_run:false,stage:"collection",bundle:$bundle[0]}'
        fi
        return "$rc"
    fi
    pin=$(_slsa_sha256 "$work/plan.json") || return $?
    jq -es --arg output "$bundle" --arg pin "$pin" --slurpfile plan "$work/plan.json" '
        length==1 and (.[0]|.kind=="dsr-release-bundle" and .status=="verified" and
            .exit_code==0 and .publishable==true and .plan_sha256==$pin and
            .targets==$plan[0].required_targets and .manifest==($output+"/release/build-manifest.json") and
            .artifacts_dir==($output+"/release/artifacts") and (.manifest_sha256|test("^[0-9a-f]{64}$")))' \
        "$work/collection.json" >/dev/null || return 7
    pin=$(jq -r .manifest_sha256 "$work/collection.json") || return 1
    [[ "$(_slsa_sha256 "$bundle/release/build-manifest.json")" == "$pin" ]] || return 7
    # All previous signing, source, draft-creation, upload, promotion and outbox
    # gates still run in the unchanged engine. Never infer --promote or signing.
    release_finalize "$bundle/release/artifacts" --repo "$repo" --tag "$tag" --sha "$sha" \
        --upload-payloads --build-manifest "$bundle/release/build-manifest.json" \
        "${forwarded[@]}" > "$work/finalization.json" || rc=$?
    jq -es --argjson rc "$rc" 'length==1 and (.[0]|.kind=="dsr-release-finalization-result" and
        .exit_code==$rc and (if $rc==0 then (.status=="ready" or .status=="published" or .status=="complete") else true end))' \
        "$work/finalization.json" >/dev/null || return 7
    [[ "$(_slsa_sha256 "$bundle/release/build-manifest.json")" == "$pin" ]] || return 7
    result=$(jq -c --slurpfile bundle "$work/collection.json" '.+{bundle:$bundle[0]}' "$work/finalization.json") || return 1
    printf '%s\n' "$result"
    return "$rc"
)

# The sourced legacy release_finalize API is unchanged. The build-set API is
# explicit and returns exactly one envelope, including collection failures.
release_finalize_build_set() (
    local work rc=0
    command -v jq >/dev/null || return 3
    umask 077
    work=$(mktemp -d "${TMPDIR:-/tmp}/dsr-build-set-result.XXXXXXXX") || return 1
    trap 'rm -rf -- "$work"' EXIT
    trap 'exit 5' HUP INT TERM
    _rf_build_set_execute "$@" > "$work/result.json" 2> "$work/diagnostics" || rc=$?
    if jq -es --argjson rc "$rc" 'length==1 and (.[0]|.kind=="dsr-release-finalization-result" and .exit_code==$rc)' \
        "$work/result.json" >/dev/null 2>&1; then
        cat "$work/result.json"
    else
        ((rc != 0)) || rc=7
        head -c 8192 "$work/diagnostics" > "$work/error" || return 1
        jq -cn --argjson rc "$rc" --rawfile error "$work/error" \
            '{kind:"dsr-release-finalization-result",status:"error",exit_code:$rc,stage:"build-set",
              error:(if $error=="" then "Build-set finalization failed" else $error end)}' || return 1
    fi
    return "$rc"
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        --help|-h|'')
            bash "$_RELEASE_FINALIZE_ENTRY_DIR/release_finalize_core.sh" --help || exit $?
            printf '\n%s\n' 'Build set: --build-set PLAN.json --bundle-dir DIR [existing finalizer policy options]' \
                'Collect the complete pinned target matrix before any release API call; retry resumes verified imports.' \
                'Identity, manifest and --upload-payloads come from the plan. Signing and --promote remain explicit.' ;;
        --build-set) release_finalize_build_set "$@"; exit $? ;;
        *) release_finalize "$@"; exit $? ;;
    esac
fi
