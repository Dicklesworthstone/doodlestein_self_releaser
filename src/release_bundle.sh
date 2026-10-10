#!/usr/bin/env bash
# Assemble independently completed builds into one manifest-bound release.
# The operator pins the complete target matrix and every input manifest before
# collection. Imported shards are immutable checkpoints, not success markers.
_RELEASE_BUNDLE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

_rb_log() { printf '[release-bundle] %s\n' "$*" >&2; }
_rb_require() {
    local tool
    for tool in jq flock python3 find cp mv mktemp; do
        command -v "$tool" >/dev/null || { _rb_log "Missing dependency: $tool"; return 3; }
    done
    if ! declare -F _slsa_manifest_statement >/dev/null; then
        # shellcheck source=src/slsa.sh
        source "$_RELEASE_BUNDLE_DIR/slsa.sh" || return 3
    fi
}

# Paths are local operator selections, never read out of a build manifest.
# Sorting makes argument/target order irrelevant to recovery identity.
_rb_plan() {
    jq -csSe '
        def text: type=="string" and length>0 and (test("[\u0000-\u001f\u007f]")|not);
        def name: text and test("^[A-Za-z0-9][A-Za-z0-9._+-]*$") and (contains("..")|not);
        def hash: type=="string" and test("^[0-9a-f]{64}$");
        def path: text and startswith("/") and (contains("\\")|not);
        def target: type=="string" and test("^(linux|darwin|windows)/(amd64|arm64|386)$");
        def targets: type=="array" and length>0 and all(.[];target) and (unique|length)==length;
        def triple: text and length<=128 and test("^[A-Za-z0-9][A-Za-z0-9._+-]*$") and (contains("..")|not);
        def variant: type=="object" and keys==["target","target_triple"] and
            (.target|target) and (.target_triple|triple);
        def variants: type=="array" and length>0 and length<=256 and
            all(.[];variant) and (unique|length)==length;
        def assets: type=="array" and length>0 and length<=256 and all(.[];
            type=="object" and (del(.target_triple)|keys)==["archive_format","name","target"] and
            (.name|name and length<=128) and (.target|target) and
            (if has("target_triple") then (.target_triple|triple) else true end) and
            (.archive_format|.=="tar.gz" or .=="tar.xz" or .=="zip" or .=="binary" or .=="none")) and
            (map(.name|ascii_downcase)|unique|length)==length;
        if length==1 then .[0] else error("expected one build-set plan") end |
        if type=="object" and
            (del(.required_assets,.required_variants)|keys)==["builds","repo","required_targets","schema_version","source_sha","tag","tool"] and
            .schema_version==1 and (.tool|name) and
            (.repo|text and test("^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$") and (contains("..")|not)) and
            (.tag|text and test("^v[0-9]+\\.[0-9]+\\.[0-9]+([+-][A-Za-z0-9.+-]+)?$")) and
            (.source_sha|type=="string" and test("^[0-9a-f]{40}$") and .!=("0"*40)) and
            (.required_targets|targets) and
            (if has("required_assets") then (.required_assets|assets) and
                ([.required_assets[].target]|unique|sort)==(.required_targets|sort) else true end) and
            (.builds|type=="array" and length>0 and length<=100 and all(.[];
                type=="object" and (del(.variants)|keys)==["artifacts_dir","id","manifest","manifest_sha256","targets"] and
                (.id|name) and (.manifest|path) and (.artifacts_dir|path) and
                (.manifest_sha256|hash) and (.targets|targets))) and
            ((.builds|map(.id)|unique|length)==(.builds|length)) and
            (if has("required_variants") then
                (.required_variants|variants) and
                ([.required_variants[].target]|unique|sort)==(.required_targets|sort) and
                all(.builds[]; (.variants|variants) and
                    ([.variants[].target]|unique|sort)==(.targets|sort)) and
                ([.builds[].variants[]]|sort_by(.target,.target_triple))==
                    (.required_variants|sort_by(.target,.target_triple)) and
                (.required_variants as $variants |
                    all(.required_assets[]? | select(has("target_triple"));
                        {target,target_triple} as $identity | any($variants[]; .==$identity)))
             else
                all(.builds[]; has("variants")|not) and
                (([.builds[].targets[]]|sort)==(.required_targets|sort))
             end)
        then .required_targets|=sort | .builds|= (map(.targets|=sort)|sort_by(.id)) |
            (if has("required_variants") then
                .required_variants|=sort_by(.target,.target_triple) |
                .builds|=map(.variants|=sort_by(.target,.target_triple))
             else . end) |
            if has("required_assets") then .required_assets|=sort_by(.name) else . end
        else error("invalid or incomplete build-set plan") end
    ' "$1" || return 4
}

# Existing components cannot redirect checkpoint/publication paths. Canonical
# directory resolution is not enough: it would silently accept a symlink.
_rb_path() {
    local path="$1" component current='/' rest
    [[ "$path" == /* && "$path" != *[[:cntrl:]]* && "$path" != *\\* ]] || return 4
    rest=${path#/}
    while [[ -n "$rest" ]]; do
        component=${rest%%/*}
        [[ -n "$component" && "$component" != . && "$component" != .. ]] || return 4
        current="${current%/}/$component"
        [[ ! -L "$current" ]] || return 4
        [[ "$rest" == */* ]] || break
        [[ ! -e "$current" || -d "$current" ]] || return 4
        rest=${rest#*/}
    done
}

_rb_exact_payloads() {
    local root="$1" manifest="$2" listing="$3" file name
    [[ -d "$root" && ! -L "$root" ]] || return 7
    find "$root" -mindepth 1 -maxdepth 1 -print0 > "$listing.paths" || return 1
    : > "$listing" || return 1
    while IFS= read -r -d '' file; do
        name=${file##*/}
        _slsa_name "$name" && [[ -f "$file" && ! -L "$file" ]] || return 7
        printf '%s\n' "$name" >> "$listing" || return 1
    done < "$listing.paths"
    jq -en --slurpfile manifest "$manifest" --rawfile names "$listing" \
        '($names|split("\n")|map(select(length>0))|sort)==($manifest[0].artifacts|map(.name)|sort)' \
        >/dev/null || { _rb_log 'Retained payload namespace changed'; return 7; }
}

_rb_shard_manifest() {
    local manifest="$1" entry="$2" plan="$3" proof="$4" repo
    [[ "$(_slsa_sha256 "$manifest")" == "$(jq -r .manifest_sha256 <<< "$entry")" ]] || {
        _rb_log 'Input manifest does not match the selected SHA-256'; return 7;
    }
    repo=$(jq -r .repo "$plan") || return 1
    _slsa_manifest_statement "$manifest" "$repo" dsr:release-bundle > "$proof" || return $?
    jq -e --slurpfile plan "$plan" --argjson input "$entry" '
        . as $m | $plan[0] as $p |
        def matches_asset($required; $actual):
            ($required|{name,target,archive_format})==($actual|{name,target,archive_format}) and
            (if $required|has("target_triple") then $required.target_triple==$actual.target_triple else true end);
        def compiled_environment:
            .method=="native" or
            (.method=="pinned-cargo-xwin" and
             ((.target=="windows/amd64" and .target_triple=="x86_64-pc-windows-msvc") or
              (.target=="windows/arm64" and .target_triple=="aarch64-pc-windows-msvc")) and
             .toolchain.target==.target_triple and .toolchain.inputs.target==.target_triple and
             (.target as $t | [$p.required_variants[]|select(.target==$t)]|length)==1);
        .tool==$p.tool and ("v"+(.version|ltrimstr("v")))==$p.tag and .source.git_sha==$p.source_sha and
        (.source.repository==null or .source.repository==$p.repo or .source.repository==("https://github.com/"+$p.repo)) and
        (if has("build_purpose") then .build_purpose=="release" else true end) and
        (if has("publishable") then .publishable==true else true end) and
        ([.artifacts[].target]|unique|sort)==$input.targets and
        (if has("requested_targets") then (.requested_targets|sort)==$input.targets else true end) and
        # Explicit variant plans partition compiler identities, not platform
        # labels. Every shard must carry its real native environment rows;
        # artifact names and success counts cannot invent missing receipts.
        (if $p|has("required_variants") then
            ([.artifacts[]|{target,target_triple}]|unique|sort_by(.target,.target_triple))==$input.variants and
            (.build_environments|type=="array" and all(.[];compiled_environment)) and
            ([.build_environments[]|{target,target_triple}]|sort_by(.target,.target_triple))==$input.variants and
            .summary.total==($input.variants|length)
         else true end) and
        (if $p|has("required_assets") then
            if $p|has("required_variants") then
                # Same-platform shards own disjoint variants. Their combined
                # exact asset contract is enforced again before publication.
                # A typed public name belongs to its selected compiler, never
                # another shard with the same scheduling platform.
                all(.artifacts[]; . as $asset |
                    any($p.required_assets[]; matches_asset(.; $asset))) and
                all($p.required_assets[] | select(has("target_triple")) |
                    select({target,target_triple} as $identity | any($input.variants[]; .==$identity));
                    . as $required | any($m.artifacts[]; matches_asset($required; .)))
            else
                (.artifacts|map({name,target,archive_format})|sort_by(.name))==
                ([$p.required_assets[]|select(.target as $t|$input.targets|index($t)!=null)|
                    {name,target,archive_format}]|sort_by(.name)) and
                all(.artifacts[]; . as $asset |
                    any($p.required_assets[]; matches_asset(.; $asset)))
            end
         else true end) and
        all(.artifacts[];
            (if has("build_purpose") then .build_purpose=="release" else true end) and
            (if has("publishable") then .publishable==true else true end))
    ' "$manifest" >/dev/null || { _rb_log 'Shard source, purpose, targets, or required assets differ from the build set'; return 7; }
}

_rb_verify_shard() {
    local dir="$1" entry="$2" plan="$3" work="$4"
    _rb_path "$dir" && [[ -d "$dir" ]] || return 7
    _rb_shard_manifest "$dir/build-manifest.json" "$entry" "$plan" "$work/proof.json" || return $?
    _rb_exact_payloads "$dir/artifacts" "$dir/build-manifest.json" "$work/names" || return $?
    _slsa_release_assets "$work/proof.json" "$dir/artifacts" || return 7
}

# No hardlinks to mutable build output. Validate copied bytes before the atomic
# checkpoint rename; a lost acknowledgement is recovered by validating it again.
_rb_import() {
    local entry="$1" plan="$2" dest="$3" work="$4" manifest root name stage
    manifest=$(jq -r .manifest <<< "$entry") || return 1
    root=$(jq -r .artifacts_dir <<< "$entry") || return 1
    _rb_path "$manifest" && _rb_path "$root" || return 4
    if [[ ! -e "$manifest" || ! -e "$root" ]]; then return 10; fi
    [[ -f "$manifest" && -d "$root" ]] || return 4
    stage=$(mktemp -d "$work/import.XXXXXXXX") || return 1
    mkdir "$stage/artifacts" || return 1
    cp -- "$manifest" "$stage/build-manifest.json" || return 1
    _rb_shard_manifest "$stage/build-manifest.json" "$entry" "$plan" "$work/proof.json" || return $?
    jq -r '.artifacts[].name' "$stage/build-manifest.json" > "$work/selected" || return 1
    while IFS= read -r name; do
        [[ ! -L "$root/$name" ]] || return 7
        [[ -e "$root/$name" ]] || return 10
        [[ -f "$root/$name" ]] || return 7
        cp -p -- "$root/$name" "$stage/artifacts/$name" || return 1
        # Never carry setuid/setgid bits from a build host into the bundle.
        if [[ -x "$root/$name" ]]; then chmod 755 "$stage/artifacts/$name"; else chmod 644 "$stage/artifacts/$name"; fi || return 1
    done < "$work/selected"
    _rb_verify_shard "$stage" "$entry" "$plan" "$work" || return $?
    [[ "$(_slsa_sha256 "$manifest")" == "$(jq -r .manifest_sha256 <<< "$entry")" ]] || return 7
    chmod 400 "$stage/build-manifest.json" || return 1
    [[ ! -e "$dest" && ! -L "$dest" ]] || return 2
    mv -- "$stage" "$dest" || return 1
}

# Assemble from retained, validated checkpoints only. Original machine-local
# paths can disappear after import. Every extension field remains available in
# the byte-pinned component manifests retained under inputs/.
_rb_aggregate_manifest() {
    local output="$1" work="$2" entry id
    : > "$work/manifests.jsonl" || return 1
    while IFS= read -r entry; do
        id=$(jq -r .id <<< "$entry") || return 1
        jq -c . "$output/inputs/$id/build-manifest.json" >> "$work/manifests.jsonl" || return 1
    done < "$work/entries"
    jq -csS --slurpfile state "$output/state.json" '
        $state[0] as $s | $s.plan as $p | . as $builds |
        ($builds|map(.source.dependencies|sort_by(.relative_path))|unique) as $deps |
        ($builds|map(.artifacts[])|sort_by(.name)) as $artifacts |
        # Shards are already validated against their exact task receipts.
        # Two native ABIs on one routing platform are two successful builds,
        # not one; compatibility aliases are never additional builds.
        ($builds|map(.summary.total)|add) as $task_count |
        if ($deps|length)!=1 or ($artifacts|map(.name|ascii_downcase)|unique|length)!=($artifacts|length)
        then error("different dependency commits or colliding release asset names") else
        {schema_version:"1.0.0",build_purpose:"release",publishable:true,
         tool:$p.tool,version:$p.tag,run_id:$s.run_id,built_at:($builds|map(.built_at)|max),
         source:{git_sha:$p.source_sha,git_ref:("refs/tags/"+$p.tag),dependencies:$deps[0]},
         requested_targets:$p.required_targets,status:"success",
         summary:{total:$task_count,success:$task_count,failed:0},
         artifacts:$artifacts,build_environments:[$builds[]|.build_environments[]?],
         component_builds:[$p.builds|to_entries[]|. as $e |
             {id:$e.value.id,targets:$e.value.targets,manifest_sha256:$e.value.manifest_sha256,
              run_id:$builds[$e.key].run_id} +
             (if $p|has("required_variants") then {variants:$e.value.variants} else {} end)],
         bundle_evidence:{kind:"manifest-bound-build-set",repo:$p.repo,plan_sha256:$s.plan_sha256,
             authenticated:false,repository_binding:"operator-selected"}} |
        (if $p|has("required_assets") then .required_assets=$p.required_assets else . end) |
        if $p|has("required_variants") then .required_variants=$p.required_variants else . end
        end' "$work/manifests.jsonl" > "$work/build-manifest.json" || return 7
}

_rb_check_release() {
    local output="$1" work="$2" repo
    _rb_path "$output/release" && [[ -d "$output/release" ]] || return 7
    cmp -s "$work/build-manifest.json" "$output/release/build-manifest.json" || return 7
    repo=$(jq -r .repo "$work/plan.json") || return 1
    _slsa_manifest_statement "$output/release/build-manifest.json" "$repo" dsr:release-bundle > "$work/proof.json" || return $?
    _rb_exact_payloads "$output/release/artifacts" "$output/release/build-manifest.json" "$work/names" || return $?
    _slsa_release_assets "$work/proof.json" "$output/release/artifacts" || return 7
    [[ -f "$output/release/result.json" && ! -L "$output/release/result.json" ]] || return 7
    cmp -s "$work/result.json" "$output/release/result.json" || return 7
}

# release_bundle --plan FILE --output-dir DIR [--dry-run]
# Exit 1: imports retained but some planned inputs are not yet available.
# Exit 2: conflicting state/lock; 3: dependency; 4: invalid plan; 7: drift.
release_bundle() (
    set -uo pipefail
    umask 077
    local plan='' output='' dry="${DRY_RUN:-false}" option
    local -A seen=()
    while (($#)); do
        option=$1
        [[ -n "$option" && -z "${seen[$option]:-}" ]] || return 4
        seen[$option]=1
        case "$option" in
            --plan|--output-dir)
                [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || return 4
                case "$option" in --plan) plan=$2 ;; *) output=$2 ;; esac
                shift 2 ;;
            --dry-run) dry=true; shift ;;
            *) _rb_log "Unknown option: $option"; return 4 ;;
        esac
    done
    [[ -f "$plan" && ! -L "$plan" && "$dry" =~ ^(true|false)$ ]] || return 4
    _rb_require || return $?
    _rb_path "$output" || return 4
    [[ "$output" != / && "$output" != */ ]] || return 4
    local canonical hash work state id entry imported=0 missing=0 rc path name expected
    canonical=$(_rb_plan "$plan") || return $?
    if [[ "$dry" == true ]]; then
        jq -cn --argjson plan "$canonical" --arg output "$output" \
            '{kind:"dsr-release-bundle",status:"planned",dry_run:true,publishable:false,plan:$plan,output_dir:$output}'
        return $?
    fi
    [[ -d "${output%/*}/" ]] || return 4
    if [[ ! -e "$output" ]]; then mkdir -- "$output" || [[ -d "$output" ]] || return 2; fi
    [[ -d "$output" ]] || return 4
    _rb_path "$output/lock" || return 2
    [[ ! -e "$output/lock" || -f "$output/lock" ]] || return 2
    exec 8>> "$output/lock" || return 1
    flock -n 8 || { _rb_log 'Build-set collection is already active'; return 2; }
    work=$(mktemp -d "$output/.collect.XXXXXXXX") || return 1
    trap 'rm -rf -- "$work"' EXIT
    trap 'exit 5' HUP INT TERM
    printf '%s\n' "$canonical" > "$work/plan.json" || return 1
    hash=$(_slsa_sha256 "$work/plan.json") || return $?
    state="$output/state.json"
    if [[ -e "$state" || -L "$state" ]]; then
        [[ -f "$state" && ! -L "$state" ]] || return 2
        jq -es --arg hash "$hash" --argjson plan "$canonical" '
            length==1 and (.[0]|.schema_version==1 and .kind=="dsr-release-bundle-state" and
            .plan_sha256==$hash and .plan==$plan and
            (.run_id|type=="string" and test("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")))' \
            "$state" >/dev/null || { _rb_log 'Build-set plan changed or state is damaged'; return 2; }
    else
        # Do not adopt another directory, or orphaned imported/published data.
        find "$output" -mindepth 1 -maxdepth 1 -print0 > "$work/existing" || return 1
        while IFS= read -r -d '' path; do
            [[ "$path" == "$output/lock" || "$path" == "$work" ]] || return 2
        done < "$work/existing"
        id=$(python3 -c 'import uuid; print(uuid.uuid4())') || return 3
        jq -cnS --arg id "$id" --arg hash "$hash" --slurpfile plan "$work/plan.json" \
            '{schema_version:1,kind:"dsr-release-bundle-state",run_id:$id,plan_sha256:$hash,plan:$plan[0]}' \
            > "$work/state.json" || return 1
        chmod 400 "$work/state.json" || return 1
        ln -- "$work/state.json" "$state" || return 2
    fi
    expected=$(_slsa_sha256 "$state") || return $?
    _rb_path "$output/inputs" || return 2
    mkdir -p -- "$output/inputs" || return 1
    jq -c '.builds[]' "$work/plan.json" > "$work/entries" || return 1
    : > "$work/missing" || return 1
    while IFS= read -r entry; do
        id=$(jq -r .id <<< "$entry") || return 1
        if [[ -e "$output/inputs/$id" || -L "$output/inputs/$id" ]]; then
            _rb_verify_shard "$output/inputs/$id" "$entry" "$work/plan.json" "$work" || return $?
        else
            rc=0
            _rb_import "$entry" "$work/plan.json" "$output/inputs/$id" "$work" || rc=$?
            case "$rc" in
                0) _rb_log "Retained verified build: $id" ;;
                10) printf '%s\n' "$id" >> "$work/missing"; missing=$((missing+1)); continue ;;
                *) return "$rc" ;;
            esac
        fi
        imported=$((imported+1))
    done < "$work/entries"
    [[ "$(_slsa_sha256 "$state")" == "$expected" ]] || return 2
    if ((missing > 0)); then
        [[ ! -e "$output/release" && ! -L "$output/release" ]] || return 7
        jq -cn --arg output "$output" --arg hash "$hash" --argjson count "$imported" --rawfile missing "$work/missing" \
            '{kind:"dsr-release-bundle",status:"incomplete",exit_code:1,publishable:false,
              output_dir:$output,plan_sha256:$hash,imported_builds:$count,missing_builds:($missing|split("\n")|map(select(length>0)))}'
        return 1
    fi
    _rb_aggregate_manifest "$output" "$work" || return $?
    hash=$(_slsa_sha256 "$work/build-manifest.json") || return $?
    jq -cnS --arg output "$output" --arg hash "$hash" --slurpfile state "$state" \
        '{kind:"dsr-release-bundle",status:"verified",exit_code:0,publishable:true,
          output_dir:$output,plan_sha256:$state[0].plan_sha256,targets:$state[0].plan.required_targets,
          manifest:($output+"/release/build-manifest.json"),manifest_sha256:$hash,
          artifacts_dir:($output+"/release/artifacts"),authenticated:false}' > "$work/result.json" || return 1
    if [[ ! -e "$output/release" && ! -L "$output/release" ]]; then
        mkdir "$work/release" "$work/release/artifacts" || return 1
        cp -- "$work/build-manifest.json" "$work/release/build-manifest.json" || return 1
        cp -- "$work/result.json" "$work/release/result.json" || return 1
        while IFS= read -r entry; do
            id=$(jq -r .id <<< "$entry") || return 1
            _rb_verify_shard "$output/inputs/$id" "$entry" "$work/plan.json" "$work" || return $?
            jq -r '.artifacts[].name' "$output/inputs/$id/build-manifest.json" > "$work/selected" || return 1
            while IFS= read -r name; do
                cp -p -- "$output/inputs/$id/artifacts/$name" "$work/release/artifacts/$name" || return 1
            done < "$work/selected"
        done < "$work/entries"
        _rb_check_release "$work" "$work" || return $?
        [[ "$(_slsa_sha256 "$state")" == "$expected" ]] || return 2
        mv -- "$work/release" "$output/release" || return 1
    fi
    _rb_check_release "$output" "$work" || return $?
    cat "$output/release/result.json"
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        --help|-h|'') printf '%s\n' 'Usage: bash src/release_bundle.sh --plan BUILD_SET.json --output-dir DIR [--dry-run]' \
            'Import pinned build manifests, resume missing targets, and assemble a complete release. No network writes.' ;;
        *) release_bundle "$@"; exit $? ;;
    esac
fi
