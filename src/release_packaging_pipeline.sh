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
        (.required_assets|type=="array" and length>0) and (.inputs|type=="array" and length>0))
        then .[0].recipe else error("invalid packaging preview") end' \
        "$work/packaging-preview.json" | jq -cS . > "$work/packaging-recipe.json" || return 7
    [[ "$(_slsa_sha256 "$work/packaging-recipe.json")" == \
       "$(jq -r .recipe_sha256 "$work/packaging-preview.json")" ]] || return 7
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
         else true end)' >/dev/null || {
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
            .packaging_evidence.recipe_sha256==$r.recipe_sha256 and .packaging_evidence.recipe==$r.recipe)' \
        "$package/release/build-manifest.json" >/dev/null || return 7
    [[ "$(_slsa_sha256 "$package/release/build-manifest.json")" == "$hash" ]] || return 7
}
