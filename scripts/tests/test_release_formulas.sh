#!/usr/bin/env bash
# Offline release-formula integration tests. Recipe parsing, downloads to real
# files, SHA256, Git clones/commits/pushes and workspace retention are exercised.
# Only GitHub API/transport boundaries are fixtures; no formula is evaluated.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/src/release_formulas.sh"

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dsr-formulas-tests.XXXXXXXX") || exit 1
# Retain fixtures and diagnostics for failed-test investigation.
printf 'Test workspace: %s\n' "$ROOT"
PASS=0 FAIL=0
check() {
    local name="$1"
    shift
    if "$@"; then printf 'PASS %s\n' "$name"; PASS=$((PASS + 1))
    else printf 'FAIL %s\n' "$name"; FAIL=$((FAIL + 1)); fi
}
equal() { [[ "$1" == "$2" ]]; }
nonzero() { [[ "$1" -ne 0 ]]; }
json_is() { jq -e "$2" "$1" >/dev/null; }
log_info() { printf 'INFO %s\n' "$*" >&2; }
log_error() { printf 'ERROR %s\n' "$*" >&2; }
json_envelope() { jq -nc --arg command "$1" --arg status "$2" --argjson code "$3" --argjson details "$4" \
    '{command:$command,status:$status,exit_code:$code,details:$details}'; }

export GIT_AUTHOR_NAME='DSR test' GIT_AUTHOR_EMAIL='dsr-test@example.invalid'
export GIT_COMMITTER_NAME='DSR test' GIT_COMMITTER_EMAIL='dsr-test@example.invalid'
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=/dev/null
export NO_COLOR=1

CASE="" SCENARIO="" API_CALLS="" GIT_CALLS="" TAG_CALLS=""
SHA=0123456789abcdef0123456789abcdef01234567
OLD_HASH=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HASH=""

seed() {
    CASE="$ROOT/$1" SCENARIO="$1"
    mkdir -p "$CASE/homebrew-source/Formula" "$CASE/scoop-source/bucket" "$CASE/config" "$CASE/tmp"
    API_CALLS="$CASE/api.calls" GIT_CALLS="$CASE/git.calls" TAG_CALLS="$CASE/tag.calls"
    : > "$API_CALLS"; : > "$GIT_CALLS"; : > "$TAG_CALLS"
    printf 'verified release bytes\n' > "$CASE/payload"
    HASH=$(sha256sum "$CASE/payload" | awk '{print $1}')
    cat > "$CASE/homebrew-source/Formula/tool.rb" <<'RUBY'
class Tool < Formula
  desc "An é tool"
  version "1.0.0"
  on_macos do
    on_arm do
      url "https://github.com/owner/tool/releases/download/v#{version}/tool-#{version}-aarch64-apple-darwin.tar.gz"
      # A comment between the matched URL and its hash is preserved.
      sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    end
    on_intel do
      url "https://github.com/owner/tool/releases/download/v1.0.0/tool-1.0.0-x86_64-apple-darwin.tar.gz"
      sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    end
  end
  on_linux do
    url "https://github.com/owner/tool/releases/download/v1.0.0/tool-linux-x86_64.tar.gz"
    sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  end
  resource "fixture" do
    url "https://example.org/old-resource.tar.gz"
    version "99.0.0"
    sha256 "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
  end
  bottle do
    sha256 cellar: :any_skip_relocation, arm64_sonoma: "unchanged-bottle"
  end
  def install
    bin.install "tool"
  end
  test do
    assert_match version.to_s, shell_output("#{bin}/tool --version")
  end
end
RUBY
    cat > "$CASE/scoop-source/bucket/tool.json" <<'JSON'
{
  "version":"1.0.0",
  "description":"Preserve all custom recipe fields",
  "architecture":{
    "64bit":{"url":"https://github.com/owner/tool/releases/download/v1.0.0/tool-1.0.0-x86_64-pc-windows-msvc.zip","hash":"old-intel","extract_dir":"tool-1.0.0"},
    "arm64":{"url":"https://github.com/owner/tool/releases/download/v1.0.0/tool-1.0.0-aarch64-pc-windows-msvc.zip#/tool.zip","hash":"old-arm"}
  },
  "bin":[["tool.exe","tool"]],
  "pre_install":"Write-Host 'preserved'",
  "autoupdate":{"architecture":{"64bit":{"url":"https://github.com/owner/tool/releases/download/v$version/tool-$version-x86_64-pc-windows-msvc.zip"}}}
}
JSON
    local name id=10 inventory='[]' size asset manager
    size=$(wc -c < "$CASE/payload"); size="${size//[[:space:]]/}"
    for name in tool-1.0.1-aarch64-apple-darwin.tar.gz tool-1.0.1-x86_64-apple-darwin.tar.gz \
        tool-linux-x86_64.tar.gz tool-1.0.1-x86_64-pc-windows-msvc.zip tool-1.0.1-aarch64-pc-windows-msvc.zip; do
        id=$((id + 1))
        asset=$(jq -nc --arg name "$name" --argjson id "$id" --argjson size "$size" --arg hash "$HASH" \
            '{id:$id,name:$name,size:$size,state:"uploaded",digest:("sha256:"+$hash),
              created_at:"2026-09-01T00:00:00Z",updated_at:"2026-09-01T00:00:00Z"}')
        inventory=$(jq -nc --argjson inventory "$inventory" --argjson asset "$asset" '$inventory+[$asset]')
    done
    printf '%s\n' "$inventory" > "$CASE/assets.json"
    for manager in homebrew scoop; do
        command git init -q -b main "$CASE/$manager-source" || return 1
        command git -C "$CASE/$manager-source" add . || return 1
        command git -C "$CASE/$manager-source" commit -qm seed || return 1
        command git clone -q --bare "$CASE/$manager-source" "$CASE/$manager.git" || return 1
    done
    export DSR_CONFIG_DIR="$CASE/config" DSR_STATE_DIR="$CASE/state" TMPDIR="$CASE/tmp"
}

# Existing adapter contracts, stubbed at the authenticated GitHub boundary.
gh_check() { [[ "$SCENARIO" != no-auth ]]; }
gh_check_token() { [[ "$SCENARIO" != no-auth ]]; }
_gh_resolve_token() { [[ "$SCENARIO" != no-auth ]] && printf 'fixture-token\n'; }
act_load_repo_config() { [[ "$1" == tool ]]; }
act_get_repo() { printf 'owner/tool\n'; }
git_ops_version_to_tag() { printf 'v%s\n' "${1#v}"; }
_gh_asset_sha256() { sha256sum "$1" | awk '{print $1}'; }
gh_resolve_tag_sha() {
    printf 'tag\n' >> "$TAG_CALLS"
    if [[ "$SCENARIO" == moved-tag && $(wc -l < "$TAG_CALLS") -gt 1 ]]; then
        printf '1111111111111111111111111111111111111111\n'
    else printf '%s\n' "$SHA"; fi
}
_gh_find_release_asset() {
    printf 'asset %s %s %s\n' "$1" "$2" "$3" >> "$API_CALLS"
    local result
    [[ "$SCENARIO" != missing-arm || "$3" != *aarch64-pc-windows* ]] || return 1
    result=$(jq -c --arg name "$3" '[.[] | select(.name==$name)]' "$CASE/assets.json") || return 8
    [[ $(jq length <<< "$result") -eq 1 ]] || return 7
    jq -c '.[0]' <<< "$result"
}
gh_download_release_asset() {
    printf 'download %s %s\n' "$1" "$2" >> "$API_CALLS"
    [[ "$SCENARIO" != download-fails ]] || return 8
    [[ ! -e "$3" ]] || return 4
    if [[ "$SCENARIO" == wrong-bytes ]]; then printf 'altered release bytes!\n' > "$3"
    else cp "$CASE/payload" "$3"; fi
}
gh_api() {
    local endpoint="$1" path manager id
    printf 'api %s %s\n' "$endpoint" "${2:-}" >> "$API_CALLS"
    case "$endpoint" in
        repos/owner/tool/releases/tags/*|repos/owner/tool/releases/9)
            [[ "$SCENARIO" != missing-release ]] || return 8
            jq -nc --argjson draft "$([[ "$SCENARIO" == draft-release ]] && echo true || echo false)" \
                '{id:9,tag_name:"v1.0.1",draft:$draft,assets:[]}' ;;
        repos/owner/tool/releases/assets/*)
            id="${endpoint##*/}"
            if [[ "$SCENARIO" == changed-asset ]]; then
                jq -c --argjson id "$id" '.[] | select(.id==$id) | .name="changed-name"' "$CASE/assets.json"
            else jq -c --argjson id "$id" '.[] | select(.id==$id)' "$CASE/assets.json"; fi ;;
        repos/owner/homebrew-tap/contents/*|repos/owner/scoop-bucket/contents/*)
            path="${endpoint#*/contents/}"
            manager=homebrew
            [[ "$endpoint" != *scoop-bucket* ]] || manager=scoop
            jq -nc --arg path "$path" --arg content "$(base64 < "$CASE/$manager-source/$path")" \
                '{path:$path,type:"file",encoding:"base64",content:$content}' ;;
        *) printf 'Unexpected endpoint: %s\n' "$endpoint" >&2; return 8 ;;
    esac
}

# Leave _formulas_git itself intact (including credential scoping and hook
# disabling). Only route its network clone URLs to private real bare repos.
git() {
    local -a args=()
    local arg manager=homebrew is_commit=false is_push=false
    for arg in "$@"; do
        case "$arg" in
            https://github.com/owner/homebrew-tap.git) arg="$CASE/homebrew.git" ;;
            https://github.com/owner/scoop-bucket.git) arg="$CASE/scoop.git" ;;
            *'/scoop') manager=scoop ;;
            commit) is_commit=true ;;
            push) is_push=true ;;
        esac
        args+=("$arg")
    done
    printf '%s\n' "${args[*]}" >> "$GIT_CALLS"
    [[ ! ( "$SCENARIO" == commit-fails && "$is_commit" == true ) ]] || return 1
    [[ ! ( "$SCENARIO" == push-fails && "$is_push" == true && "$manager" == scoop ) ]] || return 1
    command git "${args[@]}"
}

invoke() {
    local dry="$1"
    shift
    RESULT=0
    DRY_RUN="$dry" JSON_MODE=true cmd_release_formulas tool 1.0.1 \
        --homebrew-tap owner/homebrew-tap --scoop-bucket owner/scoop-bucket "$@" \
        > "$CASE/output.json" 2> "$CASE/stderr.log" || RESULT=$?
}
remote_sha() { command git --git-dir="$CASE/$1.git" rev-parse refs/heads/main; }
no_pushes() { ! grep -q ' push ' "$GIT_CALLS"; }

seed dry-run || exit 1
before_brew=$(remote_sha homebrew); before_scoop=$(remote_sha scoop)
invoke true --push
check 'dry run succeeds' equal "$RESULT" 0
check 'dry run output is a single JSON result' bash -c 'jq -es "length==1" "$1" >/dev/null' _ "$CASE/output.json"
check 'dry run plans five exact assets' json_is "$CASE/output.json" '.details.assets | length==5'
check 'dry run reports planned, not pushed' json_is "$CASE/output.json" '.details.homebrew.status=="planned" and .details.scoop.status=="planned" and .details.pushed==false and .details.work_dir==null'
check 'dry run creates no persistent workspace' test ! -e "$DSR_STATE_DIR/formulas"
check 'dry run never invokes Git' test ! -s "$GIT_CALLS"
check 'dry run cleans its temporary workspace' equal "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 | wc -l)" 0
check 'dry run leaves Homebrew remote unchanged' equal "$(remote_sha homebrew)" "$before_brew"
check 'dry run leaves Scoop remote unchanged' equal "$(remote_sha scoop)" "$before_scoop"
check 'release reads are uncached' bash -c '! grep "^api " "$1" | grep -v -- "--no-cache"' _ "$API_CALLS"

seed review || exit 1
before_brew=$(remote_sha homebrew); before_scoop=$(remote_sha scoop)
invoke false
workspace=$(jq -r '.details.work_dir' "$CASE/output.json")
check 'review mode succeeds' equal "$RESULT" 0
check 'review mode retains both real local commits' json_is "$CASE/output.json" '.details.homebrew.status=="committed" and .details.scoop.status=="committed" and .details.pushed==false'
check 'review workspace is retained' test -d "$workspace/homebrew/.git"
check 'review receipt is retained' test -s "$workspace/result.json"
check 'review workspace is private' equal "$(stat -c %a "$workspace")" 700
check 'review Homebrew remote is unchanged' equal "$(remote_sha homebrew)" "$before_brew"
check 'review Scoop remote is unchanged' equal "$(remote_sha scoop)" "$before_scoop"
check 'review creates no remote pushes' no_pushes
check 'Homebrew edits are valid Ruby' ruby -c "$workspace/homebrew/Formula/tool.rb"
check 'Homebrew all application hashes updated' equal "$(grep -c "sha256 \"$HASH\"" "$workspace/homebrew/Formula/tool.rb")" 3
check 'Homebrew resource version survives unchanged' grep -q 'version "99.0.0"' "$workspace/homebrew/Formula/tool.rb"
check 'Homebrew resource hash survives unchanged' grep -q 'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' "$workspace/homebrew/Formula/tool.rb"
check 'Homebrew bottle metadata survives unchanged' grep -q 'unchanged-bottle' "$workspace/homebrew/Formula/tool.rb"
check 'Homebrew install/test logic survives unchanged' grep -Fq 'assert_match version.to_s, shell_output("#{bin}/tool --version")' "$workspace/homebrew/Formula/tool.rb"
check 'Homebrew Unicode description survives unchanged' grep -q 'An é tool' "$workspace/homebrew/Formula/tool.rb"
check 'Scoop retains separate architecture URLs' json_is "$workspace/scoop/bucket/tool.json" '.architecture["64bit"].url | contains("x86_64-pc-windows-msvc")'
check 'Scoop ARM64 is not replaced by Intel' json_is "$workspace/scoop/bucket/tool.json" '.architecture.arm64.url | endswith("aarch64-pc-windows-msvc.zip#/tool.zip")'
check 'Scoop changes both architecture hashes' json_is "$workspace/scoop/bucket/tool.json" ".architecture[\"64bit\"].hash==\"$HASH\" and .architecture.arm64.hash==\"$HASH\""
check 'Scoop preserves autoupdate templates and scripts' json_is "$workspace/scoop/bucket/tool.json" '.autoupdate.architecture["64bit"].url | contains("$version")'
check 'Scoop updates a versioned extraction directory' json_is "$workspace/scoop/bucket/tool.json" '.architecture["64bit"].extract_dir=="tool-1.0.1"'
check 'Git hooks are disabled on every invocation' bash -c '! grep -v "core.hooksPath=/dev/null" "$1"' _ "$GIT_CALLS"
check 'credential token is absent from command logs' bash -c '! grep -q fixture-token "$1" "$2"' _ "$GIT_CALLS" "$CASE/output.json"

seed publish || exit 1
invoke false --push
check 'publishing succeeds' equal "$RESULT" 0
check 'publishing reports actual pushes' json_is "$CASE/output.json" '.details.homebrew.pushed and .details.scoop.pushed and .details.pushed'
check 'Homebrew remote points to recorded commit' equal "$(remote_sha homebrew)" "$(jq -r '.details.homebrew.commit' "$CASE/output.json")"
check 'Scoop remote points to recorded commit' equal "$(remote_sha scoop)" "$(jq -r '.details.scoop.commit' "$CASE/output.json")"
before_brew=$(remote_sha homebrew); before_scoop=$(remote_sha scoop)
invoke false --push
check 'identical publication succeeds without another commit' equal "$RESULT" 0
check 'identical publication is honestly unchanged' json_is "$CASE/output.json" '.details.homebrew.status=="unchanged" and .details.scoop.status=="unchanged" and .details.pushed==false'
check 'repeat leaves Homebrew commit identical' equal "$(remote_sha homebrew)" "$before_brew"
check 'repeat leaves Scoop commit identical' equal "$(remote_sha scoop)" "$before_scoop"

for scenario in missing-arm wrong-bytes download-fails changed-asset moved-tag draft-release missing-release commit-fails no-auth; do
    seed "$scenario" || exit 1
    before_brew=$(remote_sha homebrew); before_scoop=$(remote_sha scoop)
    invoke false --push
    check "$scenario returns failure" nonzero "$RESULT"
    check "$scenario cannot change Homebrew remote" equal "$(remote_sha homebrew)" "$before_brew"
    check "$scenario cannot change Scoop remote" equal "$(remote_sha scoop)" "$before_scoop"
    check "$scenario does not report a successful push" bash -c '! jq -e ".details.pushed==true" "$1" >/dev/null' _ "$CASE/output.json"
done

seed push-fails || exit 1
before_scoop=$(remote_sha scoop)
invoke false --push
check 'second remote push failure is nonzero' nonzero "$RESULT"
check 'partial publication identifies the real successful push' json_is "$CASE/output.json" '.status=="partial" and .details.homebrew.status=="pushed" and .details.scoop.status=="push_failed" and .details.scoop.pushed==false and .details.pushed==true'
check 'failed remote push leaves Scoop remote unchanged' equal "$(remote_sha scoop)" "$before_scoop"
workspace=$(jq -r '.details.work_dir' "$CASE/output.json")
check 'failed remote push retains its local commit' equal "$(command git -C "$workspace/scoop" rev-parse HEAD)" "$(jq -r '.details.scoop.commit' "$CASE/output.json")"

seed bad-digest || exit 1
jq '.[] |= (.digest="sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")' "$CASE/assets.json" > "$CASE/changed.json"
cp "$CASE/changed.json" "$CASE/assets.json"
invoke true
check 'valid-length wrong digest is rejected' nonzero "$RESULT"
seed no-digest || exit 1
jq '.[] |= del(.digest)' "$CASE/assets.json" > "$CASE/changed.json"
cp "$CASE/changed.json" "$CASE/assets.json"
invoke true
check 'legacy digest-less assets use downloaded bytes' equal "$RESULT" 0
check 'legacy asset plan records calculated hashes' json_is "$CASE/output.json" ".details.assets | all(.[]; .sha256==\"$HASH\")"

# Renderer-only negative controls use real files and complete plans; they must
# fail rather than partially changing a recipe or evaluating dynamic Ruby.
seed renderers || exit 1
printf '{}\n' > "$CASE/plan.json"
cat > "$CASE/dynamic.rb" <<'RUBY'
class Tool < Formula
  version "1.0.0"
  url "https://example.org/#{system('touch SHOULD_NOT_EXIST')}/tool"
  sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
end
RUBY
status=0
_formulas_homebrew scan "$CASE/dynamic.rb" "$CASE/plan.json" 1.0.1 > "$CASE/dynamic.out" 2> "$CASE/dynamic.err" || status=$?
check 'dynamic Ruby URL is rejected without execution' nonzero "$status"
check 'formula code is never evaluated' test ! -e SHOULD_NOT_EXIST
cat > "$CASE/unpaired.rb" <<'RUBY'
class Tool < Formula
  url "https://github.com/owner/tool/releases/download/v1.0.0/tool.zip"
  resource "x" do
    sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  end
end
RUBY
status=0
_formulas_homebrew scan "$CASE/unpaired.rb" "$CASE/plan.json" 1.0.1 > "$CASE/unpaired.out" 2> "$CASE/unpaired.err" || status=$?
check 'resource hash cannot satisfy an application URL' nonzero "$status"
cat > "$CASE/unknown.rb" <<'RUBY'
class Tool < Formula
  on_sonoma do
    url "https://github.com/owner/tool/releases/download/v1.0.0/tool.zip"
    sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  end
end
RUBY
status=0
_formulas_homebrew scan "$CASE/unknown.rb" "$CASE/plan.json" 1.0.1 > "$CASE/unknown.out" 2> "$CASE/unknown.err" || status=$?
check 'unsupported download scopes fail instead of leaving stale metadata' nonzero "$status"

cat > "$CASE/array.json" <<'JSON'
{"version":"1.0.0","url":["https://github.com/owner/tool/releases/download/v1.0.0/tool.zip","https://example.org/runtime.exe"],"hash":["old","auxiliary"],"bin":"tool.exe","autoupdate":{"url":"$version"}}
JSON
jq -nc --arg hash "$HASH" '{"https://github.com/owner/tool/releases/download/v1.0.0/tool.zip": {url:"https://github.com/owner/tool/releases/download/v1.0.1/tool.zip",sha256:$hash}}' > "$CASE/plan.json"
status=0
_formulas_scoop apply "$CASE/array.json" "$CASE/plan.json" 1.0.1 > "$CASE/array.updated" || status=$?
check 'Scoop URL arrays update successfully' equal "$status" 0
check 'Scoop URL/hash arrays preserve auxiliary correspondence' json_is "$CASE/array.updated" ".url[1]==\"https://example.org/runtime.exe\" and .hash==[\"$HASH\",\"auxiliary\"] and .bin==\"tool.exe\""
jq '.hash=["wrong-length"]' "$CASE/array.json" > "$CASE/array.bad.json"
status=0
_formulas_scoop apply "$CASE/array.bad.json" "$CASE/plan.json" 1.0.1 > "$CASE/array.bad.out" 2> "$CASE/array.bad.err" || status=$?
check 'Scoop mismatched URL/hash arrays are rejected' nonzero "$status"

for args in '--tool' '--version' '--homebrew-tap' '--scoop-bucket' '--unknown' 'tool' 'tool v1.0.1 extra' '../tool v1.0.1' 'tool ../../v1' 'tool v1.0.1 --skip-homebrew --skip-scoop'; do
    status=0
    # Intentional splitting: each fixture contains plain CLI words only.
    # shellcheck disable=SC2086
    JSON_MODE=true cmd_release_formulas $args > "$CASE/args.out" 2> "$CASE/args.err" || status=$?
    check "invalid arguments: $args" equal "$status" 4
done
status=0
JSON_MODE=false cmd_release_formulas --help > "$CASE/help.out" || status=$?
check 'help succeeds without authentication or network' equal "$status" 0
check 'help documents usage and manager options' grep -q -- '--homebrew-tap' "$CASE/help.out"

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
