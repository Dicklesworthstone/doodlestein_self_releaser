#!/usr/bin/env bash
# Public entry point for finalization, build-set ingestion and build execution.
# All release policy gates share the engine in release_finalize_core.sh.
_RELEASE_FINALIZE_ENTRY_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=src/release_finalize_core.sh
source "$_RELEASE_FINALIZE_ENTRY_DIR/release_finalize_core.sh" || { return 3 2>/dev/null || exit 3; }

# Build-plan/set mode owns repo/tag/SHA/tool and the aggregate manifest. Publication
# policy remains explicit and is still checked by the existing engine.
_rf_build_set_execute() {
    set -uo pipefail
    local plan='' bundle='' dry="${DRY_RUN:-false}" option value work canonical
    local require_signatures=false prepared=false create=false promote=false dispatch=''
    local require_provenance=false provenance_builder=''
    local public='' secret='' integrity='' notes='' title='' prerelease=false retry_creation=false
    local dispatch_run='' dispatch_state='' retry_delivery=false format=spdx metadata='' state=''
    local build_plan='' build_dir='' build_jobs=1 build_worker=0 cleanup
    local packaging_recipe='' package='' selected_manifest selected_artifacts selected_pin
    local -a forwarded=() collect_args=()
    local -A seen=()
    while (($#)); do
        option=$1
        [[ "$option" != -n ]] || option=--dry-run
        [[ -n "$option" && -z "${seen[$option]:-}" ]] || return 4
        seen[$option]=1
        case "$option" in
            --build-set|--bundle-dir|--build-plan|--build-dir|--build-jobs|--packaging-recipe|--format|--output-dir|--state-dir|--public-key|--secret-key|--integrity-dir|--release-name|--release-notes-file|--dispatch-repos|--dispatch-run-id|--dispatch-state-dir|--provenance-builder)
                [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || return 4
                value=$2
                case "$option" in
                    --build-set) plan=$value ;; --bundle-dir) bundle=$value ;;
                    --build-plan) build_plan=$value ;; --build-dir) build_dir=$value ;; --build-jobs) build_jobs=$value ;;
                    --packaging-recipe) packaging_recipe=$value ;;
                    --format) format=$value ;; --output-dir) metadata=$value ;; --state-dir) state=$value ;;
                    --public-key) public=$value ;; --secret-key) secret=$value ;; --integrity-dir) integrity=$value ;;
                    --provenance-builder) provenance_builder=$value ;;
                    --release-name) title=$value ;; --release-notes-file) notes=$value ;;
                    --dispatch-repos) dispatch=$value ;; --dispatch-run-id) dispatch_run=$value ;; --dispatch-state-dir) dispatch_state=$value ;;
                esac
                case "$option" in --build-set|--bundle-dir|--build-plan|--build-dir|--build-jobs|--packaging-recipe) ;; *) forwarded+=("$option" "$value") ;; esac
                shift 2 ;;
            --dry-run) dry=true; shift ;;
            --require-signatures|--prepared-signatures|--create-draft|--promote|--prerelease|--retry-creation|--retry-uncertain|--require-provenance)
                case "$option" in
                    --require-signatures) require_signatures=true ;; --prepared-signatures) prepared=true ;;
                    --require-provenance) require_provenance=true ;;
                    --create-draft) create=true ;; --promote) promote=true ;; --prerelease) prerelease=true ;;
                    --retry-creation) retry_creation=true ;; --retry-uncertain) retry_delivery=true ;;
                esac
                forwarded+=("$option"); shift ;;
            *) printf '[release-finalize] Unknown or plan-owned build-set option: %s\n' "$option" >&2; return 4 ;;
        esac
    done
    [[ "$dry" =~ ^(true|false)$ ]] || return 4
    if [[ -n "$build_plan" ]]; then
        [[ -z "$plan$bundle" && -f "$build_plan" && ! -L "$build_plan" && -n "$build_dir" &&
           "$build_jobs" =~ ^[0-9]{1,2}$ ]] || return 4
        build_jobs=$((10#$build_jobs))
        ((build_jobs >= 1 && build_jobs <= 32)) || return 4
        bundle="$build_dir/bundle"
    else
        [[ -f "$plan" && ! -L "$plan" && -z "$build_dir" && -z "${seen[--build-jobs]:-}" ]] || return 4
    fi
    case "$format" in spdx|spdx-json|cyclonedx|cdx|cyclonedx-json) ;; *) return 4 ;; esac
    if [[ "$prepared" == true ]]; then
        [[ "$require_signatures" == false && -z "$secret" && -n "$public" && -n "$integrity" ]] || return 4
    elif [[ "$require_signatures" == true ]]; then
        [[ -n "$public" ]] || return 4
    else
        [[ -z "$public$secret$integrity" ]] || return 4
    fi
    # Validate before starting builders. The complete manifest is selected by
    # collection; the core later binds its exact digest, targets and invocation.
    if [[ "$require_provenance" == true ]]; then
        [[ ( "$require_signatures" == true || "$prepared" == true ) &&
           -n "$provenance_builder" && "$provenance_builder" != *[[:cntrl:]]* ]] || {
            printf '%s\n' '[release-finalize] Provenance requires a signature policy and --provenance-builder' >&2
            return 4
        }
    elif [[ -n "$provenance_builder" ]]; then
        printf '%s\n' '[release-finalize] --provenance-builder requires --require-provenance' >&2
        return 4
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
    [[ -z "$build_plan" ]] || _rb_path "$build_dir" || return 4
    _rb_path "$bundle" || return 4
    [[ "$bundle" != / && "$bundle" != */ ]] || return 4
    package="$bundle/packaged"
    if [[ -z "$packaging_recipe" && ( -e "$package" || -L "$package" ) ]]; then
        _rf_log 'A retained packaging selection requires --packaging-recipe on retry'; return 2
    fi
    for value in "$metadata" "$state" "$integrity" "$dispatch_state"; do
        [[ -n "$value" ]] || continue
        _rb_path "$value" || return 4
        if [[ -n "$build_plan" && ( "$value" == "$build_dir" || "$value" == "$build_dir/"* ) &&
              "$value" != "$bundle/"* ]]; then
            _rb_log 'Finalizer outputs inside a build directory must stay in its bundle namespace'; return 4
        fi
        case "$value" in
            "$bundle"|"$bundle/"|"$bundle/release"|"$bundle/release/"*|"$bundle/inputs"|"$bundle/inputs/"*|"$package"|"$package/"*)
                _rb_log 'Finalizer output/state must stay outside immutable release and input directories'; return 4 ;;
        esac
    done
    [[ -n "$metadata" ]] || forwarded+=(--output-dir "$bundle/metadata")
    [[ -n "$state" ]] || forwarded+=(--state-dir "$bundle/finalization")
    work=$(mktemp -d "${TMPDIR:-/tmp}/dsr-build-set-finalize.XXXXXXXX") || return 1
    printf -v cleanup 'rm -rf -- %q' "$work"
    # shellcheck disable=SC2064
    trap "$cleanup" EXIT
    _rf_build_plan_cancel() {
        trap '' HUP INT TERM
        if ((build_worker > 0)); then
            kill -TERM "$build_worker" 2>/dev/null || true
            wait "$build_worker" 2>/dev/null || true
        fi
        exit 5
    }
    trap _rf_build_plan_cancel HUP INT TERM
    printf 'null\n' > "$work/build-result.json" || return 1
    printf 'null\n' > "$work/packaging-preview.json" || return 1
    printf 'null\n' > "$work/packaging-result.json" || return 1
    if [[ -n "$packaging_recipe" ]]; then
        # shellcheck source=src/release_packaging_pipeline.sh
        source "$_RELEASE_FINALIZE_ENTRY_DIR/release_packaging_pipeline.sh" || return 3
        _rf_packaging_preview "$packaging_recipe" "$work" || return $?
    fi
    if [[ -n "$build_plan" ]]; then
        # Validate policy syntax above before any expensive builds. The engine
        # still authenticates keys and checks live release policy afterward.
        bash "$_RELEASE_FINALIZE_ENTRY_DIR/release_builds.sh" --plan "$build_plan" \
            --output-dir "$build_dir" --jobs "$build_jobs" --dry-run > "$work/build-preview.json" || return $?
        jq -ecs 'if length==1 and (.[0]|.kind=="dsr-release-builds" and .status=="planned" and
            .exit_code==0 and .dry_run==true and .publishable==false)
            then .[0].plan else error("invalid build plan preview") end' \
            "$work/build-preview.json" > "$work/execution-plan.json" || return 7
        if [[ -n "$packaging_recipe" ]]; then
            _rf_packaging_contract "$work/execution-plan.json" "$work/packaging-preview.json" || return $?
        fi
        if [[ "$dry" == true ]]; then
            jq -cn --args '$ARGS.positional' -- "${forwarded[@]}" > "$work/options.json" || return 1
            jq -cn --slurpfile builds "$work/build-preview.json" --slurpfile options "$work/options.json" \
                --slurpfile packaging "$work/packaging-preview.json" \
                '{kind:"dsr-release-finalization-result",status:"planned",exit_code:0,dry_run:true,
                  stage:"build-plan",builds:$builds[0],finalization_options:$options[0],policy_verified:false} |
                 if $packaging[0]==null then . else .+{packaging:$packaging[0]} end'
            return $?
        fi
        local build_rc=0 build_set_pin
        bash "$_RELEASE_FINALIZE_ENTRY_DIR/release_builds.sh" --plan "$work/execution-plan.json" \
            --output-dir "$build_dir" --jobs "$build_jobs" > "$work/build-result.json" &
        build_worker=$!
        wait "$build_worker" || build_rc=$?
        build_worker=0
        jq -es --argjson rc "$build_rc" 'length==1 and (.[0]|.kind=="dsr-release-builds" and .exit_code==$rc)' \
            "$work/build-result.json" >/dev/null || return 7
        if ((build_rc != 0)); then
            jq -cn --argjson rc "$build_rc" --slurpfile builds "$work/build-result.json" \
                '{kind:"dsr-release-finalization-result",status:(if $rc==1 then "builds_incomplete" else "error" end),
                  exit_code:$rc,dry_run:false,stage:"build",builds:$builds[0]}'
            return "$build_rc"
        fi
        jq -es --arg root "$build_dir" --slurpfile preview "$work/build-preview.json" '
            length==1 and (.[0]|.status=="verified" and .publishable==true and .dry_run==false and
                .plan_sha256==$preview[0].plan_sha256 and .build_set==($root+"/build-set.json") and
                .bundle.status=="verified" and .bundle.targets==$preview[0].plan.required_targets and
                (.build_set_sha256|type=="string" and test("^[0-9a-f]{64}$")))' \
            "$work/build-result.json" >/dev/null || return 7
        build_set_pin=$(jq -r .build_set_sha256 "$work/build-result.json") || return 1
        [[ "$(_slsa_sha256 "$build_dir/build-set.json")" == "$build_set_pin" ]] || return 7
        canonical=$(_rb_plan "$build_dir/build-set.json") || return $?
        [[ "$(_slsa_sha256 "$build_dir/build-set.json")" == "$build_set_pin" ]] || return 7
        jq -en --slurpfile expected "$work/execution-plan.json" --argjson actual "$canonical" '
            $expected[0] as $p | all(["repo","tool","tag","source_sha","required_targets"][];
                . as $key | $actual[$key]==$p[$key]) and
            (($actual|has("required_assets"))==($p|has("required_assets"))) and
            (if $p|has("required_assets") then $actual.required_assets==$p.required_assets else true end) and
            ($actual.builds|map({id,targets}))==($p.builds|map({id,targets}))' >/dev/null || return 7
    else
        canonical=$(_rb_plan "$plan") || return $?
    fi
    printf '%s\n' "$canonical" > "$work/plan.json" || return 1
    if [[ -n "$packaging_recipe" ]]; then
        _rf_packaging_contract "$work/plan.json" "$work/packaging-preview.json" || return $?
    fi
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
            --slurpfile packaging "$work/packaging-preview.json" \
            '{kind:"dsr-release-finalization-result",status:"planned",exit_code:0,dry_run:true,
              stage:"build-set-plan",bundle:$collection[0],finalization_options:$options[0],
              policy_verified:false} | if $packaging[0]==null then . else .+{packaging:$packaging[0]} end'
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
    selected_manifest="$bundle/release/build-manifest.json"
    selected_artifacts="$bundle/release/artifacts"
    selected_pin="$pin"
    if [[ -n "$packaging_recipe" ]]; then
        bash "$_RELEASE_FINALIZE_ENTRY_DIR/release_packaging.sh" --recipe "$work/packaging-recipe.json" \
            --manifest "$selected_manifest" --manifest-sha256 "$pin" --artifacts-dir "$selected_artifacts" \
            --output-dir "$package" --repo "$repo" --tag "$tag" --sha "$sha" > "$work/packaging-result.json" &
        build_worker=$!
        wait "$build_worker" || rc=$?
        build_worker=0
        if ((rc != 0)); then
            jq -es --argjson rc "$rc" 'length==1 and (.[0]|.kind=="dsr-release-packaging" and
                .status=="error" and .publishable==false and .exit_code==$rc)' \
                "$work/packaging-result.json" >/dev/null || return 7
            jq -cn --argjson rc "$rc" --slurpfile bundle "$work/collection.json" \
                --slurpfile packaging "$work/packaging-result.json" --slurpfile builds "$work/build-result.json" \
                '{kind:"dsr-release-finalization-result",status:"error",exit_code:$rc,dry_run:false,
                  stage:"packaging",bundle:$bundle[0],packaging:$packaging[0]} |
                 if $builds[0]==null then . else .+{builds:$builds[0]} end'
            return "$rc"
        fi
        _rf_packaging_handoff "$package" "$pin" "$work/plan.json" "$work" || return $?
        selected_manifest="$package/release/build-manifest.json"
        selected_artifacts="$package/release/artifacts"
        selected_pin=$(jq -r .manifest_sha256 "$work/packaging-result.json") || return 1
    fi
    # All previous signing, source, draft-creation, upload, promotion and outbox
    # gates run in the shared engine, including explicit provenance admission.
    # Never infer --promote or signing.
    release_finalize "$selected_artifacts" --repo "$repo" --tag "$tag" --sha "$sha" \
        --upload-payloads --build-manifest "$selected_manifest" \
        "${forwarded[@]}" > "$work/finalization.json" || rc=$?
    jq -es --argjson rc "$rc" 'length==1 and (.[0]|.kind=="dsr-release-finalization-result" and
        .exit_code==$rc and (if $rc==0 then (.status=="ready" or .status=="published" or .status=="complete") else true end))' \
        "$work/finalization.json" >/dev/null || return 7
    [[ "$(_slsa_sha256 "$bundle/release/build-manifest.json")" == "$pin" ]] || return 7
    [[ "$(_slsa_sha256 "$selected_manifest")" == "$selected_pin" ]] || return 7
    result=$(jq -c --slurpfile bundle "$work/collection.json" --slurpfile builds "$work/build-result.json" \
        --slurpfile packaging "$work/packaging-result.json" \
        '.+{bundle:$bundle[0]} | (if $builds[0]==null then . else .+{builds:$builds[0]} end) |
         if $packaging[0]==null then . else .+{packaging:$packaging[0]} end' "$work/finalization.json") || return 1
    printf '%s\n' "$result"
    return "$rc"
}

# The sourced legacy release_finalize API is unchanged. The build-set API is
# explicit and returns exactly one envelope, including collection failures.
_rf_build_set_result() {
    local work rc=0 worker cleanup interrupted=false
    command -v jq >/dev/null || return 3
    umask 077
    work=$(mktemp -d "${TMPDIR:-/tmp}/dsr-build-set-result.XXXXXXXX") || return 1
    printf -v cleanup 'rm -rf -- %q' "$work"
    # shellcheck disable=SC2064
    trap "$cleanup" EXIT
    _rf_build_set_execute "$@" > "$work/result.json" 2> "$work/diagnostics" &
    worker=$!
    _rf_build_set_cancel() {
        trap '' HUP INT TERM
        interrupted=true
        kill -TERM "$worker" 2>/dev/null || true
    }
    trap _rf_build_set_cancel HUP INT TERM
    wait "$worker" || rc=$?
    if [[ "$interrupted" == true ]]; then
        wait "$worker" 2>/dev/null || true
        rc=5
    fi
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
}

release_finalize_build_set() ( _rf_build_set_result "$@"; )
release_finalize_build_plan() ( _rf_build_set_result "$@"; )

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        --help|-h|'')
            bash "$_RELEASE_FINALIZE_ENTRY_DIR/release_finalize_core.sh" --help || exit $?
            printf '\n%s\n' 'Build set: --build-set PLAN.json --bundle-dir DIR [existing finalizer policy options]' \
                'Collect the complete pinned target matrix before any release API call; retry resumes verified imports.' \
                'Identity, manifest and --upload-payloads come from the plan. Signing and --promote remain explicit.'
            printf '%s\n' 'Add --packaging-recipe RECIPE.json to either mode to package before signing and finalization.'
            printf '\n%s\n' 'Build plan: --build-plan PLAN.json --build-dir DIR [--build-jobs N] [finalizer policy options]' \
                'Execute native/xwin jobs, retain completed checkpoints, assemble every target, then finalize.' ;;
        --build-set|--build-plan) _rf_build_set_result "$@"; exit $? ;;
        *) release_finalize "$@"; exit $? ;;
    esac
fi
