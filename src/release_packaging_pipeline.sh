#!/usr/bin/env bash
# Packaging handoff for the public build-set/build-plan finalizer. Paths come
# from its private workspace, never from a producer's embedded path fields.

_rf_packaging_preview() {
    local recipe="$1" work="$2"
    _rb_path "$recipe" && [[ -f "$recipe" && ! -L "$recipe" ]] || return 4
    bash "$_RELEASE_FINALIZE_ENTRY_DIR/release_packaging.sh" --recipe "$recipe" --describe \
        > "$work/packaging-preview.json" || return $?
    jq -ecs 'if length==1 and (.[0]|.kind=="dsr-release-packaging-plan" and
        (.recipe|type=="object") and (.recipe_sha256|type=="string" and test("^[0-9a-f]{64}$")) and
        (.required_assets|type=="array" and length>0) and (.inputs|type=="array" and length>0) and
        (.source_files|type=="array") and
        .source_files==([.recipe.artifacts[].source_files[]?.source]|unique|sort))
        then .[0].recipe else error("invalid packaging preview") end' \
        "$work/packaging-preview.json" | jq -cS . > "$work/packaging-recipe.json" || return 7
    [[ "$(_slsa_sha256 "$work/packaging-recipe.json")" == \
       "$(jq -r .recipe_sha256 "$work/packaging-preview.json")" ]] || return 7
}

# Validate the complete companion closure before launching builders, not after
# expensive target compilation. This performs only local Git object reads and
# temporary proof staging; neither producer success nor publication is claimed.
# build_worker belongs to the caller's cancellation handler, just like builders.
_rf_packaging_source_preflight() {
    local plan="$1" checkout="$2" package="$3" work="$4" count repo tag sha rc=0
    count=$(jq -er '.source_files|length' "$work/packaging-preview.json") || return 7
    if [[ "$count" == 0 ]]; then
        [[ -z "$checkout" ]] || { _rf_log 'Packaging source repository is unused by this recipe'; return 4; }
        return 0
    fi
    if [[ -z "$checkout" ]]; then
        # A completed package has retained commit/tree/blob objects. The full
        # packager will reverify them before any signing or release API call.
        # Directory existence alone is NOT proof and dry-run makes no such claim.
        if _rb_path "$package/release" && [[ -d "$package/release" && ! -L "$package/release" ]]; then
            _rf_log 'Retained source companions require full packaging revalidation before finalization'
            return 0
        fi
        _rf_log 'Source companions require --packaging-source-repo before builds or collection'; return 4
    fi
    _rb_path "$checkout" || return 4
    repo=$(jq -er .repo "$plan") || return 4
    tag=$(jq -er .tag "$plan") || return 4
    sha=$(jq -er .source_sha "$plan") || return 4
    bash "$_RELEASE_FINALIZE_ENTRY_DIR/release_packaging.sh" --recipe "$work/packaging-recipe.json" \
        --check-source --source-repo "$checkout" --repo "$repo" --tag "$tag" --sha "$sha" \
        > "$work/packaging-source.json" &
    build_worker=$!
    wait "$build_worker" || rc=$?
    build_worker=0
    ((rc == 0)) || return "$rc"
    jq -es --slurpfile preview "$work/packaging-preview.json" --arg repo "$repo" --arg tag "$tag" --arg sha "$sha" '
        length==1 and (.[0]|.kind=="dsr-release-packaging-source-check" and .status=="verified" and
            .exit_code==0 and .publishable==false and .repo==$repo and .tag==$tag and .source_sha==$sha and
            .recipe_sha256==$preview[0].recipe_sha256 and
            .source_companions.kind=="git-commit-source-files" and .source_companions.schema_version==1 and
            .source_companions.git_sha==$sha and
            ([.source_companions.files[].source]|sort)==$preview[0].source_files)' \
        "$work/packaging-source.json" >/dev/null || return 7
}

# Input requirements describe the producer, not the renamed/archived output.
# Enforce compatibility before collection or compilation, without inferring
# producer success from a recipe. The packager still admits the actual bytes.
_rf_packaging_contract() {
    local plan="$1" preview="$2"
    jq -en --slurpfile plan "$plan" --slurpfile preview "$preview" '
        $plan[0] as $p | $preview[0] as $r |
        def raw: .=="binary" or .=="none";
        ([$r.required_assets[].target]|unique|sort)==($p.required_targets|sort) and
        (if $p|has("required_assets") then
            ($p.required_assets|map({name,target})|sort_by(.name,.target))==($r.inputs|sort_by(.name,.target)) and
            all($r.recipe.artifacts[]; . as $a |
                if has("members") then all(.members[]; .source as $n |
                    any($p.required_assets[]; .name==$n and (.archive_format|raw)))
                else any($p.required_assets[]; .name==$a.source and
                    ((.archive_format|raw)==($a.archive_format|raw))) end)
         else true end) and
        # Xwin advertises its exact binary inventory even without an optional
        # global asset contract. Do not start a compiler for an impossible
        # recipe that drops a selected companion or asks for another binary.
        all($p.builds[] | select(.driver?=="xwin"); . as $job |
            [($job.binaries // [$job.binary])[] |
                {name:($job.asset_name // (. + "-aarch64-pc-windows-msvc.exe")),target:"windows/arm64"}] as $expected |
            ([$r.inputs[]|select(.target=="windows/arm64")]|sort_by(.name))==($expected|sort_by(.name)) and
            all($r.recipe.artifacts[]|select(.target=="windows/arm64");
                has("members") or (.archive_format|raw)))' >/dev/null || {
        _rf_log 'Packaging recipe differs from the producer target/asset contract'; return 4;
    }
}

# Authenticate the selected local handoff, not just a status string. The core
# subsequently applies its own payload/signature/SBOM/provenance admission.
_rf_packaging_handoff() {
    local package="$1" source_pin="$2" plan="$3" work="$4" hash
    jq -es --arg root "$package" --arg source "$source_pin" --slurpfile preview "$work/packaging-preview.json" '
        length==1 and (.[0]|.kind=="dsr-release-packaging" and .status=="verified" and
            .exit_code==0 and .publishable==true and .source_manifest_sha256==$source and
            .recipe_sha256==$preview[0].recipe_sha256 and .manifest==($root+"/release/build-manifest.json") and
            .artifacts_dir==($root+"/release/artifacts") and
            (.manifest_sha256|type=="string" and test("^[0-9a-f]{64}$")))' \
        "$work/packaging-result.json" >/dev/null || return 7
    _rb_path "$package/release/build-manifest.json" || return 7
    hash=$(jq -r .manifest_sha256 "$work/packaging-result.json") || return 1
    [[ "$(_slsa_sha256 "$package/release/build-manifest.json")" == "$hash" ]] || return 7
    jq -es --arg source "$source_pin" --slurpfile plan "$plan" --slurpfile preview "$work/packaging-preview.json" '
        $plan[0] as $p | $preview[0] as $r | length==1 and (.[0]|
            .tool==$p.tool and .version==$p.tag and .source.git_sha==$p.source_sha and
            .requested_targets==$p.required_targets and .required_assets==$r.required_assets and
            .packaging_evidence.kind=="manifest-bound-packaging" and .packaging_evidence.schema_version==1 and
            .packaging_evidence.source_manifest_sha256==$source and
            .packaging_evidence.recipe_sha256==$r.recipe_sha256 and .packaging_evidence.recipe==$r.recipe and
            (if ($r.source_files|length)>0 then
                .packaging_evidence.source_companions.kind=="git-commit-source-files" and
                .packaging_evidence.source_companions.schema_version==1 and
                .packaging_evidence.source_companions.git_sha==$p.source_sha and
                ([.packaging_evidence.source_companions.files[].source]|sort)==$r.source_files
             else (.packaging_evidence|has("source_companions")|not) end))' \
        "$package/release/build-manifest.json" >/dev/null || return 7
    [[ "$(_slsa_sha256 "$package/release/build-manifest.json")" == "$hash" ]] || return 7
}
