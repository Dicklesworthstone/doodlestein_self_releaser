#!/usr/bin/env bash
# release_formulas.sh - Publish content-verified Homebrew and Scoop updates.
# Recipes select exact assets; neither architecture nor checksums are guessed.
# Homebrew parsing uses Ruby's standard-library Ripper, never eval or brew load.

set -uo pipefail

_formulas_error() {
    local code="$1" message="$2"
    log_error "$message"
    if [[ "${JSON_MODE:-false}" == "true" ]]; then
        json_envelope "release-formulas" "error" "$code" \
            "$(jq -nc --arg error "$message" '{error: $error}')"
    fi
    return "$code"
}

# Git credentials are scoped to this invocation, not written to global config
# or embedded in URLs. Disable hooks so editing a recipe never executes it.
_formulas_git() {
    local token
    token=$(_gh_resolve_token) || return 3
    DSR_FORMULAS_GIT_TOKEN="$token" GIT_TERMINAL_PROMPT=0 \
        git -c core.hooksPath=/dev/null -c core.fsmonitor=false \
        -c credential.helper= \
        -c 'credential.helper=!f() { if [ "$1" = get ]; then printf "%s\n" "username=x-access-token" "password=$DSR_FORMULAS_GIT_TOKEN"; fi; }; f' \
        "$@"
}

# Read a recipe without cloning or creating commits (dry-run). The contents
# endpoint must identify the exact regular file requested, not a symlink/array.
_formulas_fetch_recipe() {
    local repo="$1" path="$2" destination="$3" response
    response=$(gh_api "repos/$repo/contents/$path" --no-cache) || return 8
    jq -es --arg path "$path" 'length == 1 and (.[0] |
        type == "object" and .type == "file" and .path == $path and
        .encoding == "base64" and (.content | type == "string"))' \
        <<< "$response" >/dev/null || return 8
    # GNU and BSD base64 use different switches. Never retry decoding into an
    # existing partial output; the caller's staging file is not a live recipe.
    if printf '' | base64 --decode >/dev/null 2>&1; then
        jq -r '.content' <<< "$response" | base64 --decode > "$destination"
    else
        jq -r '.content' <<< "$response" | base64 -D > "$destination"
    fi
}

# scan: emit {version,urls}; apply: emit the edited formula on stdout. Ripper
# supplies syntax and byte locations, so comments/resources/bottles/install
# methods cannot be mistaken for the application's download metadata.
_formulas_homebrew() {
    local mode="$1" recipe="$2" plan="$3" version="$4"
    ruby - "$mode" "$recipe" "$plan" "$version" <<'RUBY'
require "json"
require "ripper"
mode, path, plan_path, new_version = ARGV
begin
  source = File.binread(path)
  ast = Ripper.sexp(source)
  raise "invalid Ruby formula" unless ast && ast[0] == :program
  classes = ast[1].select { |n| n.is_a?(Array) && n[0] == :class }
  superclass = classes.first&.[](2)
  raise "expected one Formula subclass" unless classes.length == 1 &&
    superclass && superclass[0] == :var_ref && superclass[1][0..1] == [:@const, "Formula"]
  # Ruby's superclass AST is a var_ref; reject other inheritance forms rather
  # than loading Homebrew or executing a formula to discover its structure.
  root = classes[0][3]
  raise "unsupported class body" unless root[0] == :bodystmt && root[2..4].all?(&:nil?)
  lines = source.lines
  offsets = [0]
  lines.each { |line| offsets << offsets[-1] + line.bytesize }
  tokens = Ripper.lex(source)
  edits = []
  downloads = []
  versions = []
  simple_call = lambda do |node, name|
    node.is_a?(Array) && node[0] == :command && node[1][0] == :@ident && node[1][1] == name
  end
  string_arg = lambda do |node|
    args = node[2]
    raise "metadata must have one string argument" unless args[0] == :args_add_block &&
      args[2] == false && args[1].length == 1 && args[1][0][0] == :string_literal
    ident_pos = node[1][2]
    start_index = tokens.index { |t| t[0] == ident_pos && t[1] == :on_ident }
    raise "missing metadata token" unless start_index
    first = start_index + 1
    first += 1 while tokens[first] && tokens[first][1] == :on_sp
    raise "unsupported string delimiter" unless tokens[first] &&
      tokens[first][1] == :on_tstring_beg && ["\"", "'"].include?(tokens[first][2])
    last = first + 1
    last += 1 while tokens[last] && tokens[last][1] != :on_tstring_end
    raise "unterminated metadata string" unless tokens[last]
    start = offsets[tokens[first][0][0] - 1] + tokens[first][0][1]
    finish = offsets[tokens[last][0][0] - 1] + tokens[last][0][1] + tokens[last][2].bytesize
    [args[1][0][1], start, finish]
  end
  decode = lambda do |content, version|
    raise "unsupported string syntax" unless content[0] == :string_content
    content.drop(1).map do |part|
      if part[0] == :@tstring_content
        raise "escaped metadata strings are unsupported" if part[1].include?("\\")
        part[1]
      elsif version && part[0] == :string_embexpr && part[1].length == 1 &&
          part[1][0][0] == :vcall && part[1][0][1][0..1] == [:@ident, "version"]
        version
      else
        raise "only literal strings and the version interpolation are supported"
      end
    end.join
  end
  block_name = lambda do |call|
    call = call[1] if call[0] == :method_add_arg
    [:fcall, :vcall, :command].include?(call[0]) ? call[1][1] : nil
  end
  metadata = lambda do |node|
    next false unless node.is_a?(Array)
    (node[0] == :@ident && %w[url sha256 version].include?(node[1])) ||
      node.any? { |child| metadata.call(child) if child.is_a?(Array) }
  end
  walk = nil
  walk = lambda do |statements|
    return unless statements
    statements.each_with_index do |node, index|
      next unless node.is_a?(Array)
      if simple_call.call(node, "version")
        value = string_arg.call(node)
        versions << [decode.call(value[0], nil), value[1], value[2]]
      elsif simple_call.call(node, "url")
        following = statements[index + 1]
        raise "each application URL must be followed by its literal sha256" unless simple_call.call(following, "sha256")
        downloads << [string_arg.call(node), string_arg.call(following)]
      elsif simple_call.call(node, "sha256")
        raise "unpaired application sha256" unless index > 0 && simple_call.call(statements[index - 1], "url")
      elsif node[0] == :method_add_block
        name = block_name.call(node[1])
        # Ignore resource, bottle, head, livecheck, service and test blocks.
        if %w[on_macos on_linux on_arm on_intel stable].include?(name)
          body = node[2]
          raise "unsupported platform block" unless body[0] == :do_block && body[2][0] == :bodystmt && body[2][2..4].all?(&:nil?)
          walk.call(body[2][1])
        elsif !%w[resource bottle head livecheck service test].include?(name) && metadata.call(node[2])
          raise "unsupported download block: #{name}"
        end
      elsif [:if, :unless, :elsif].include?(node[0])
        walk.call(node[2])
        branch = node[3]
        if branch && branch[0] == :else
          walk.call(branch[1])
        elsif branch
          walk.call([branch])
        end
      elsif node[0] == :case
        walk.call([node[2]]) if node[2]
      elsif node[0] == :when
        walk.call(node[2])
        branch = node[3]
        if branch && branch[0] == :else
          walk.call(branch[1])
        elsif branch
          walk.call([branch])
        end
      elsif ![:def, :defs].include?(node[0]) && metadata.call(node)
        raise "unsupported application metadata syntax"
      end
    end
  end
  walk.call(root[1])
  raise "no supported application download URLs" if downloads.empty?
  old_versions = versions.map(&:first).uniq
  raise "conflicting application versions" if old_versions.length > 1
  old_version = old_versions.first
  urls = downloads.map { |pair| decode.call(pair[0][0], old_version) }
  downloads.each do |pair|
    hash = decode.call(pair[1][0], nil)
    raise "application sha256 must be a 64-digit literal" unless hash.match?(/\A[0-9a-fA-F]{64}\z/)
  end
  if mode == "scan"
    puts JSON.generate({version: old_version, urls: urls})
  elsif mode == "apply"
    plan = JSON.parse(File.read(plan_path))
    downloads.zip(urls).each do |pair, url|
      asset = plan.fetch(url) { raise "no verified replacement for #{url}" }
      raise "invalid verified asset" unless asset["url"].is_a?(String) &&
        asset["sha256"].is_a?(String) && asset["sha256"].match?(/\A[0-9a-f]{64}\z/)
      edits << [pair[0][1], pair[0][2], asset["url"].dump]
      edits << [pair[1][1], pair[1][2], asset["sha256"].dump]
    end
    versions.each { |_, start, finish| edits << [start, finish, new_version.dump] }
    edits.sort_by(&:first).reverse_each { |start, finish, value| source[start...finish] = value }
    raise "updated formula is invalid Ruby" unless Ripper.sexp(source)
    print source
  else
    raise "unknown formula operation"
  end
rescue StandardError => error
  warn "Homebrew update refused: #{error.message}"
  exit 4
end
RUBY
}

# Preserve Scoop's per-architecture overrides, URL/hash array correspondence,
# auxiliary downloads, install scripts and autoupdate templates. Only exact
# verified URLs are replaced. Missing auxiliary hashes are never invented.
_formulas_scoop() {
    local mode="$1" recipe="$2" plan="$3" version="$4"
    jq -es --arg mode "$mode" --arg version "$version" --slurpfile plans "$plan" '
      def urls:
        if . == null then [] elif type == "string" then [.]
        elif type == "array" and length > 0 and all(.[]; type == "string") then .
        else error("invalid Scoop URL field") end;
      def scopes: [. ] + [(.architecture // {} | .[])];
      if length != 1 or (.[0] | type) != "object" then error("expected one Scoop manifest") else .[0] end |
      . as $original |
      if (.version | type) != "string" or
         ((.architecture // {} | type) != "object") or
         (any((.architecture // {} | to_entries[]);
              (.key != "32bit" and .key != "64bit" and .key != "arm64") or (.value | type) != "object"))
      then error("unsupported Scoop architecture/version") else . end |
      if $mode == "scan" then {version: .version, urls: [scopes[] | .url | urls[]]}
      elif $mode == "apply" then
        $plans[0] as $plan |
        def update_scope:
          if .url == null then . else
            (.url | urls) as $urls |
            (if .hash == null then [$urls[] | null]
             elif (.hash | type) == "string" and (.url | type) == "string" then [.hash]
             elif (.hash | type) == "array" and (.url | type) == "array" and
                  (.hash | length) == ($urls | length) then .hash
             else error("Scoop URL/hash shape mismatch") end) as $hashes |
            [range(0; $urls | length) as $i |
              if $plan[$urls[$i]] != null then
                {url: $plan[$urls[$i]].url, hash: $plan[$urls[$i]].sha256}
              elif ($hashes[$i] | type) == "string" and ($hashes[$i] | length) > 0 then
                {url: $urls[$i], hash: $hashes[$i]}
              else error("unverified auxiliary Scoop download") end
            ] as $updated |
            if (.url | type) == "array" then
              .url = [$updated[].url] | .hash = [$updated[].hash]
            else .url = $updated[0].url | .hash = $updated[0].hash end |
            if (.extract_dir | type) == "string" and ($original.version | length) > 0 then
              .extract_dir |= (split($original.version) | join($version))
            else . end
          end;
        if ([scopes[] | .url | urls[] | select($plan[.] != null)] | length) == 0
        then error("no verified Scoop application assets") else . end |
        .version = $version | update_scope |
        if .architecture != null then .architecture |= with_entries(.value |= update_scope) else . end
      else error("unknown Scoop operation") end
    ' "$recipe"
}

# Convert each existing download URL into an exact new asset name. Version
# substitution is literal and does not rescan newly inserted version text.
# Versionless compatibility names and all architecture/triple spellings remain
# intact. No first-match platform regex and no guessed checksum-sidecar name.
_formulas_plan_assets() {
    local repo="$1" tag="$2" release_id="$3" scan="$4" work="$5"
    local prefix="https://github.com/$repo/releases/download/"
    local url base rest old_tag old_name name fragment asset id size hash digest old_version new_tag
    local cached receipt actual_size after plan_json
    jq -es 'length == 1 and (.[0] | type == "object" and
        (.version == null or (.version | type) == "string") and
        (.urls | type == "array" and all(.[]; type == "string")))' \
        "$scan" >/dev/null || return 4
    old_version=$(jq -r '.version // ""' "$scan") || return 4
    while IFS= read -r url; do
        [[ -n "$url" ]] || continue
        [[ "${url,,}" == "${prefix,,}"* ]] || continue
        if jq -e --arg url "$url" 'has($url)' "$work/plan.json" >/dev/null; then
            continue
        fi
        base="${url%%#*}" fragment=""
        if [[ "$base" != "$url" ]]; then
            fragment="#${url#*#}"
            [[ "$fragment" =~ ^\#/[A-Za-z0-9._+-]+$ ]] || return 4
        fi
        rest="${base:${#prefix}}"
        old_tag="${rest%%/*}" old_name="${rest#*/}"
        old_tag="${old_tag//%2B/+}" old_tag="${old_tag//%2b/+}"
        old_name="${old_name//%2B/+}" old_name="${old_name//%2b/+}"
        if [[ "$rest" != */* || ! "$old_tag" =~ ^v?[0-9][A-Za-z0-9._+-]*$ ||
              ! "$old_name" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]; then
            log_error "Unsupported release URL in recipe: $url"
            return 4
        fi
        if [[ -n "$old_version" && "${old_version#v}" != "${old_tag#v}" ]]; then
            log_error "Recipe version and release URL disagree: $url"
            return 4
        fi
        new_tag="$tag"
        [[ "$old_tag" != v* ]] && new_tag="${tag#v}"
        name=$(jq -nr --arg name "$old_name" --arg oldtag "$old_tag" \
            --arg oldver "${old_tag#v}" --arg newtag "$new_tag" --arg ver "${tag#v}" \
            'def escaped: gsub("[.]"; "\\.") | gsub("[+]"; "\\+");
             ("(?<prefix>^|[-_.])(?<value>" + ($oldtag | escaped) + "|" +
                 ($oldver | escaped) + ")(?=$|[-_.])") as $pattern |
             $name | gsub($pattern; .prefix +
                 (if .value == $oldtag then $newtag else $ver end))') || return 4
        asset=$(_gh_find_release_asset "$repo" "$release_id" "$name") || {
            log_error "No unambiguous release asset for recipe: $name"
            return 7
        }
        jq -es --arg name "$name" 'length == 1 and (.[0] |
            .name == $name and .state == "uploaded" and
            (.id | type == "number" and floor == . and . > 0 and . <= 9007199254740991) and
            (.size | type == "number" and floor == . and . > 0 and . <= 9007199254740991))' \
            <<< "$asset" >/dev/null || return 7
        id=$(jq -r '.id' <<< "$asset") size=$(jq -r '.size' <<< "$asset")
        receipt="$work/asset-$id.json" cached="$work/asset-$id"
        if [[ ! -f "$receipt" ]]; then
            gh_download_release_asset "$repo" "$id" "$cached" || return 8
            [[ -f "$cached" && ! -L "$cached" ]] || return 7
            hash=$(_gh_asset_sha256 "$cached") || return 3
            actual_size=$(wc -c < "$cached") || return 4
            actual_size="${actual_size//[[:space:]]/}"
            digest=$(jq -r '.digest // ""' <<< "$asset") || return 7
            if [[ "$actual_size" != "$size" || ! "$hash" =~ ^[0-9a-f]{64}$ ||
                  ( -n "$digest" && "$digest" != "sha256:$hash" ) ]]; then
                log_error "Downloaded release asset does not match its receipt: $name"
                return 7
            fi
            jq -nc --argjson asset "$asset" --arg hash "$hash" \
                '{asset: $asset, sha256: $hash}' > "$receipt" || return 4
        fi
        hash=$(jq -r '.sha256' "$receipt") || return 4
        # An ID reused in another recipe must carry the same metadata, too.
        jq -e --argjson asset "$asset" '
            (.asset | {id,name,state,size,digest,created_at,updated_at}) ==
            ($asset | {id,name,state,size,digest,created_at,updated_at})' "$receipt" >/dev/null || return 7
        after=$(gh_api "repos/$repo/releases/assets/$id" --no-cache) || return 8
        jq -es --argjson asset "$asset" 'length == 1 and
            (.[0] | {id,name,state,size,digest,created_at,updated_at}) ==
            ($asset | {id,name,state,size,digest,created_at,updated_at})' <<< "$after" >/dev/null || return 7
        plan_json=$(jq -c --arg old "$url" \
            --arg url "$prefix$tag/$name$fragment" --arg hash "$hash" \
            --argjson asset "$asset" \
            '.[$old] = {url: $url, sha256: $hash, asset: $asset}' "$work/plan.json") || return 4
        printf '%s\n' "$plan_json" > "$work/plan.json" || return 4
    done < <(jq -r '.urls[]' "$scan")
}

# Recheck both tag binding and immutable asset identities before publication.
_formulas_revalidate() {
    local repo="$1" tag="$2" release_id="$3" sha="$4" plan="$5"
    local release current item id fresh
    jq -es 'length == 1 and (.[0] | type == "object" and length > 0)' \
        "$plan" >/dev/null || return 7
    current=$(gh_resolve_tag_sha "$repo" "$tag") || return 8
    [[ "$current" == "$sha" ]] || { log_error "Release tag moved during formula update"; return 7; }
    release=$(gh_api "repos/$repo/releases/$release_id" --no-cache) || return 8
    jq -es --arg tag "$tag" --argjson id "$release_id" 'length == 1 and
        (.[0] | .id == $id and .tag_name == $tag and .draft == false)' \
        <<< "$release" >/dev/null || return 7
    while IFS= read -r item; do
        id=$(jq -r '.id' <<< "$item") || return 7
        fresh=$(_gh_find_release_asset "$repo" "$release_id" "$(jq -r '.name' <<< "$item")") || return 7
        jq -es --argjson before "$item" 'length == 1 and
            (.[0] | {id,name,state,size,digest,created_at,updated_at}) ==
            ($before | {id,name,state,size,digest,created_at,updated_at})' \
            <<< "$fresh" >/dev/null || return 7
    done < <(jq -c '[.[] | .asset] | unique_by(.id)[]' "$plan")
}

cmd_release_formulas() (
    local tool_name="" version="" homebrew_tap="" scoop_bucket=""
    local skip_homebrew=false skip_scoop=false push_changes=false
    local dry_run="${DRY_RUN:-false}" start_time
    start_time=$(date +%s)
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tool|-t|--version|-V|--homebrew-tap|--scoop-bucket)
                if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
                    _formulas_error 4 "Missing value for $1"; return 4
                fi
                case "$1" in
                    --tool|-t) tool_name="$2" ;;
                    --version|-V) version="$2" ;;
                    --homebrew-tap) homebrew_tap="$2" ;;
                    --scoop-bucket) scoop_bucket="$2" ;;
                esac
                shift 2 ;;
            --skip-homebrew) skip_homebrew=true; shift ;;
            --skip-scoop) skip_scoop=true; shift ;;
            --push) push_changes=true; shift ;;
            --help|-h)
                cat <<'HELP'
dsr release formulas - Update Homebrew and Scoop manifests

USAGE:
    dsr release formulas <tool> <version> [options]

OPTIONS:
    -t, --tool <name>          Configured tool
    -V, --version <tag>        Published release tag
    --homebrew-tap <repo>      Override configured Homebrew repository
    --scoop-bucket <repo>      Override configured Scoop repository
    --skip-homebrew            Update Scoop only
    --skip-scoop               Update Homebrew only
    --push                     Push verified commits to the cloned branches

Global --dry-run validates recipes and downloads without commits or pushes.
Every configured download must resolve to its exact release asset; bytes,
size and available GitHub digests are verified. Homebrew requires Ruby for
non-evaluating syntax parsing. Scoop architecture overrides are preserved.
Local commits and evidence are retained under XDG state when not a dry run.
HELP
                return 0 ;;
            -*) _formulas_error 4 "Unknown option: $1"; return 4 ;;
            *)
                if [[ -z "$tool_name" ]]; then tool_name="$1"
                elif [[ -z "$version" ]]; then version="$1"
                else _formulas_error 4 "Unexpected argument: $1"; return 4; fi
                shift ;;
        esac
    done
    if [[ ! "$tool_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ||
          ! "$version" =~ ^v?[0-9][A-Za-z0-9._+-]*$ ]]; then
        _formulas_error 4 "A safe tool name and release version are required"; return 4
    fi
    if $skip_homebrew && $skip_scoop; then
        _formulas_error 4 "Both package managers were disabled"; return 4
    fi
    local dependency
    for dependency in jq git base64; do
        command -v "$dependency" >/dev/null || { _formulas_error 3 "Missing dependency: $dependency"; return 3; }
    done
    if ! $skip_homebrew && ! command -v ruby >/dev/null; then
        _formulas_error 3 "Ruby is required to safely parse Homebrew formulas"; return 3
    fi
    if ! gh_check 2>/dev/null && ! gh_check_token 2>/dev/null; then
        _formulas_error 3 "GitHub authentication required"; return 3
    fi
    act_load_repo_config "$tool_name" >/dev/null || { _formulas_error 4 "Tool not found: $tool_name"; return 4; }
    local repo tag release release_id source_sha config_file
    repo=$(act_get_repo "$tool_name") || return 4
    [[ "$repo" == */* ]] || repo="Dicklesworthstone/$repo"
    tag=$(git_ops_version_to_tag "$version") || return 4
    config_file="${DSR_CONFIG_DIR:-$HOME/.config/dsr}/config.yaml"
    if [[ -z "$homebrew_tap" ]] && command -v yq >/dev/null && [[ -f "$config_file" ]]; then
        homebrew_tap=$(yq -r '.formulas.homebrew_tap // ""' "$config_file") || return 4
    fi
    if [[ -z "$scoop_bucket" ]] && command -v yq >/dev/null && [[ -f "$config_file" ]]; then
        scoop_bucket=$(yq -r '.formulas.scoop_bucket // ""' "$config_file") || return 4
    fi
    homebrew_tap="${homebrew_tap:-Dicklesworthstone/homebrew-tap}"
    scoop_bucket="${scoop_bucket:-Dicklesworthstone/scoop-bucket}"
    for dependency in "$repo" "$homebrew_tap" "$scoop_bucket"; do
        [[ "$dependency" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || {
            _formulas_error 4 "Invalid repository: $dependency"; return 4
        }
    done
    release=$(gh_api "repos/$repo/releases/tags/$tag" --no-cache) || {
        _formulas_error 7 "Release not found: $repo $tag"; return 7
    }
    if ! jq -es --arg tag "$tag" 'length == 1 and (.[0] |
        .tag_name == $tag and .draft == false and
        (.id | type == "number" and floor == . and . > 0 and . <= 9007199254740991))' \
        <<< "$release" >/dev/null; then
        _formulas_error 7 "Expected a published release with the exact requested tag"; return 7
    fi
    release_id=$(jq -r '.id' <<< "$release") || return 7
    source_sha=$(gh_resolve_tag_sha "$repo" "$tag") || { _formulas_error 7 "Cannot bind release tag"; return 7; }
    [[ "$source_sha" =~ ^[0-9a-f]{40}$ ]] || return 7

    umask 077
    local work state_root cleanup
    if [[ "$dry_run" == "true" ]]; then
        work=$(mktemp -d "${TMPDIR:-/tmp}/dsr-formulas.XXXXXXXX") || return 4
        printf -v cleanup 'rm -rf -- %q' "$work"
        trap "$cleanup" EXIT
    else
        state_root="${DSR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsr}/formulas"
        mkdir -p "$state_root" || return 4
        work=$(mktemp -d "$state_root/${tool_name}-${tag}.XXXXXXXX") || return 4
        log_info "Formula workspace: $work"
    fi
    trap 'exit 5' INT TERM
    printf '{}\n' > "$work/plan.json" || return 4
    local -a managers=()
    $skip_homebrew || managers+=(homebrew)
    $skip_scoop || managers+=(scoop)
    local -A repositories=([homebrew]="$homebrew_tap" [scoop]="$scoop_bucket")
    local -A paths=([homebrew]="Formula/$tool_name.rb" [scoop]="bucket/$tool_name.json")
    local manager recipe path kind status=0
    # Complete preflight for EVERY requested manager before making any commit.
    for manager in "${managers[@]}"; do
        path="${paths[$manager]}"
        if [[ "$dry_run" == "true" ]]; then
            recipe="$work/$manager.original"
            _formulas_fetch_recipe "${repositories[$manager]}" "$path" "$recipe" || status=$?
        else
            recipe="$work/$manager/$path"
            _formulas_git clone --depth 1 -- "https://github.com/${repositories[$manager]}.git" \
                "$work/$manager" >&2 || status=$?
            if [[ $status -eq 0 && ( -L "$work/$manager/${path%%/*}" || -L "$recipe" || ! -f "$recipe" ) ]]; then
                status=4
            fi
        fi
        if [[ $status -ne 0 ]]; then
            _formulas_error 1 "Cannot load $manager recipe; no repositories were pushed (workspace: $work)"; return 1
        fi
        if ! "_formulas_$manager" scan "$recipe" "$work/plan.json" "${tag#v}" > "$work/$manager.scan.json" ||
           ! _formulas_plan_assets "$repo" "$tag" "$release_id" "$work/$manager.scan.json" "$work" ||
           ! "_formulas_$manager" apply "$recipe" "$work/plan.json" "${tag#v}" > "$work/$manager.updated"; then
            _formulas_error 1 "Cannot verify/render $manager recipe; no repositories were pushed (workspace: $work)"; return 1
        fi
    done
    if ! _formulas_revalidate "$repo" "$tag" "$release_id" "$source_sha" "$work/plan.json"; then
        _formulas_error 7 "Release changed during preflight; no repositories were pushed"; return 7
    fi

    local results='{}' result branch commit changed any_pushed=false failures=0 successes=0
    for manager in "${managers[@]}"; do
        status=0 changed=false branch="" commit="" kind=planned
        if [[ "$dry_run" != "true" ]]; then
            path="${paths[$manager]}" recipe="$work/$manager/${paths[$manager]}"
            branch=$(_formulas_git -C "$work/$manager" symbolic-ref --short HEAD) || status=$?
            if [[ $status -eq 0 ]]; then
                if ! cmp -s "$recipe" "$work/$manager.updated"; then
                    changed=true
                    cp "$work/$manager.updated" "$recipe" || status=$?
                    if [[ $status -eq 0 ]]; then
                        _formulas_git -C "$work/$manager" add -- "$path" >&2 || status=$?
                    fi
                    if [[ $status -eq 0 ]]; then
                        _formulas_git -C "$work/$manager" commit -m "Update $tool_name to ${tag#v}" >&2 || status=$?
                    fi
                fi
                if [[ $status -eq 0 ]]; then
                    commit=$(_formulas_git -C "$work/$manager" rev-parse HEAD) || status=$?
                fi
            fi
            if [[ $status -ne 0 ]]; then kind=commit_failed
            elif ! $changed; then kind=unchanged
            elif ! $push_changes; then kind=committed
            elif ! _formulas_revalidate "$repo" "$tag" "$release_id" "$source_sha" "$work/plan.json"; then
                kind=release_changed; status=7
            elif _formulas_git -C "$work/$manager" push origin "HEAD:refs/heads/$branch" >&2; then
                kind=pushed; any_pushed=true
            else kind=push_failed; status=1; fi
        fi
        if [[ $status -eq 0 ]]; then successes=$((successes + 1)); else failures=$((failures + 1)); fi
        result=$(jq -nc --arg status "$kind" --arg repo "${repositories[$manager]}" \
            --arg path "${paths[$manager]}" --arg branch "$branch" --arg commit "$commit" \
            --argjson code "$status" --argjson changed "$changed" \
            '{status:$status,repo:$repo,path:$path,branch:$branch,commit:$commit,
              updated:($changed and $code == 0),pushed:($status == "pushed"),exit_code:$code,
              error:(if $code == 0 then null else $status end)}') || return 4
        results=$(jq -nc --argjson results "$results" --arg manager "$manager" \
            --argjson result "$result" '$results + {($manager):$result}') || return 4
    done
    local exit_code=0 overall=success details duration workspace="$work"
    if [[ $failures -gt 0 ]]; then
        exit_code=1; overall=error
        [[ $successes -gt 0 ]] && overall=partial
    fi
    [[ "$dry_run" == "true" ]] && workspace=""
    duration=$(($(date +%s) - start_time))
    details=$(jq -nc --arg tool "$tool_name" --arg version "${tag#v}" --arg tag "$tag" \
        --arg repo "$repo" --arg sha "$source_sha" --argjson release_id "$release_id" \
        --arg work_dir "$workspace" --argjson results "$results" --slurpfile plan "$work/plan.json" \
        --argjson pushed "$any_pushed" --argjson dry_run "$dry_run" --argjson duration "$duration" \
        '{tool:$tool,version:$version,tag:$tag,repo:$repo,release_id:$release_id,git_sha:$sha,
          work_dir:(if $work_dir == "" then null else $work_dir end),
          homebrew:(($results.homebrew // {status:"skipped",updated:false,pushed:false,error:null}) |
            . + {tap: (.repo // null)}),
          scoop:(($results.scoop // {status:"skipped",updated:false,pushed:false,error:null}) |
            . + {bucket: (.repo // null)}),
          assets:$plan[0],pushed:$pushed,dry_run:$dry_run,duration_seconds:$duration}') || return 4
    printf '%s\n' "$details" > "$work/result.json" || return 4
    if [[ "${JSON_MODE:-false}" == "true" ]]; then
        json_envelope "release-formulas" "$overall" "$exit_code" "$details"
    else
        log_info "Formula update: $overall ($tag)"
        for manager in "${managers[@]}"; do
            log_info "$manager: $(jq -r --arg manager "$manager" '.[$manager].status' <<< "$results")"
        done
        [[ -z "$workspace" ]] || log_info "Commits and verification evidence retained: $workspace"
    fi
    return "$exit_code"
)

export -f cmd_release_formulas
