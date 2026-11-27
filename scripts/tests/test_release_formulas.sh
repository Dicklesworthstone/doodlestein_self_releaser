#!/usr/bin/env bash
# Offline release-formula integration tests. Recipe parsing, downloads to real
# files, SHA256, Git clones/commits/pushes and workspace retention are exercised.
# Only GitHub API/transport boundaries are fixtures; no formula is evaluated.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$PROJECT_ROOT/src/github.sh"
# shellcheck source=src/release_formulas.sh
source "${FORMULAS_TEST_MODULE:-$PROJECT_ROOT/src/release_formulas.sh}"

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
FORMULA_INTERRUPT_STAGE='' FORMULA_INTERRUPT_CODE=130
SHA=0123456789abcdef0123456789abcdef01234567
HASH=""

seed() {
    CASE="$ROOT/$1" SCENARIO="$1"
    mkdir -p "$CASE/homebrew-source/Formula" "$CASE/scoop-source/bucket" "$CASE/config" "$CASE/tmp"
    API_CALLS="$CASE/api.calls" GIT_CALLS="$CASE/git.calls" TAG_CALLS="$CASE/tag.calls"
    : > "$API_CALLS"; : > "$GIT_CALLS"; : > "$TAG_CALLS"
    : > "$CASE/operations"
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
    case "$SCENARIO" in
        package-alias)
            cp "$CASE/homebrew-source/Formula/tool.rb" "$CASE/homebrew-source/Formula/ee.rb" || return 1
            cp "$CASE/scoop-source/bucket/tool.json" "$CASE/scoop-source/bucket/ee.json" || return 1 ;;
        flat-bucket|linked-bucket|truncated-bucket)
            mv "$CASE/scoop-source/bucket/tool.json" "$CASE/scoop-source/tool.json" || return 1
            if [[ "$SCENARIO" == linked-bucket ]]; then
                mv "$CASE/scoop-source/bucket" "$CASE/scoop-source/elsewhere" || return 1
                ln -s elsewhere "$CASE/scoop-source/bucket" || return 1
            fi ;;
        shadowed-root) printf 'inactive root copy\n' > "$CASE/scoop-source/tool.json" ;;
        missing-nested)
            mv "$CASE/scoop-source/bucket/tool.json" "$CASE/scoop-source/tool.json" || return 1
            printf '{}\n' > "$CASE/scoop-source/bucket/another.json" ;;
        linked-manifest)
            mv "$CASE/scoop-source/bucket/tool.json" "$CASE/scoop-source/tool.json" || return 1
            ln -s ../tool.json "$CASE/scoop-source/bucket/tool.json" || return 1 ;;
    esac
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
    formula_interrupt initial-tag || return $?
    if [[ $(wc -l < "$TAG_CALLS") -gt 1 ]]; then
        formula_interrupt revalidate-tag || return $?
    fi
    if [[ "$SCENARIO" == moved-tag && $(wc -l < "$TAG_CALLS") -gt 1 ]]; then
        printf '1111111111111111111111111111111111111111\n'
    else printf '%s\n' "$SHA"; fi
}
_gh_find_release_asset() {
    printf 'asset %s %s %s\n' "$1" "$2" "$3" >> "$API_CALLS"
    formula_interrupt find-asset || return $?
    local result
    [[ "$SCENARIO" != missing-arm || "$3" != *aarch64-pc-windows* ]] || return 1
    result=$(jq -c --arg name "$3" '[.[] | select(.name==$name)]' "$CASE/assets.json") || return 8
    [[ $(jq length <<< "$result") -eq 1 ]] || return 7
    jq -c '.[0]' <<< "$result"
}
gh_download_release_asset() {
    printf 'download %s %s\n' "$1" "$2" >> "$API_CALLS"
    formula_interrupt download || return $?
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
            formula_interrupt release-read || return $?
            [[ "$SCENARIO" != missing-release ]] || return 8
            jq -nc --argjson draft "$([[ "$SCENARIO" == draft-release ]] && echo true || echo false)" \
                '{id:9,tag_name:"v1.0.1",draft:$draft,assets:[]}' ;;
        repos/owner/tool/releases/assets/*)
            formula_interrupt asset-read || return $?
            id="${endpoint##*/}"
            if [[ "$SCENARIO" == changed-asset ]]; then
                jq -c --argjson id "$id" '.[] | select(.id==$id) | .name="changed-name"' "$CASE/assets.json"
            else jq -c --argjson id "$id" '.[] | select(.id==$id)' "$CASE/assets.json"; fi ;;
        repos/owner/scoop-bucket/git/trees/*)
            formula_interrupt recipe-read || return $?
            id=$(command git --git-dir="$CASE/scoop.git" rev-parse "${endpoint##*/}^{tree}") || return 8
            command git --git-dir="$CASE/scoop.git" ls-tree "$id" |
                jq -Rn --arg id "$id" --arg scenario "$SCENARIO" '
                    {sha:$id, truncated:($scenario=="truncated-bucket"),
                     tree:[inputs | capture("^(?<mode>[^ ]+) (?<type>[^ ]+) (?<sha>[^\\t]+)\\t(?<path>.+)$")]}' ;;
        repos/owner/scoop-bucket/git/blobs/*)
            formula_interrupt scoop-blob-read || return $?
            id="${endpoint##*/}"
            command git --git-dir="$CASE/scoop.git" cat-file blob "$id" | base64 |
                jq -Rs --arg id "$id" '{sha:$id,type:"blob",encoding:"base64",content:.}' ;;
        repos/owner/homebrew-tap/contents/*|repos/owner/scoop-bucket/contents/*)
            formula_interrupt recipe-read || return $?
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
    local arg manager=homebrew is_commit=false is_push=false operation=''
    for arg in "$@"; do
        case "$arg" in
            https://github.com/owner/homebrew-tap.git) arg="$CASE/homebrew.git" ;;
            https://github.com/owner/scoop-bucket.git) arg="$CASE/scoop.git" ;;
            *'/scoop') manager=scoop ;;
            commit) is_commit=true ;;
            push) is_push=true ;;
        esac
        case "$arg" in clone|symbolic-ref|add|commit|rev-parse|push) operation="$arg" ;; esac
        args+=("$arg")
    done
    printf '%s\n' "${args[*]}" >> "$GIT_CALLS"
    formula_interrupt "$manager-$operation" || return $?
    [[ ! ( "$SCENARIO" == commit-fails && "$is_commit" == true ) ]] || return 1
    [[ ! ( "$SCENARIO" == push-fails && "$is_push" == true && "$manager" == scoop ) ]] || return 1
    command git "${args[@]}" || return $?
    formula_interrupt "$manager-$operation-accepted"
}

formula_interrupt() {
    local stage="$1"
    printf '%s\n' "$stage" >> "$CASE/operations"
    if [[ "$FORMULA_INTERRUPT_STAGE" == "$stage" ]]; then
        printf 'interrupted %s %s\n' "$stage" "$FORMULA_INTERRUPT_CODE" >> "$CASE/operations"
        return "$FORMULA_INTERRUPT_CODE"
    fi
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

formula_scoop_layout_cases() {
    local original published scenario dry
    seed flat-bucket || return 1
    original=$(remote_sha scoop)
    invoke true --skip-homebrew --push
    check 'flat bucket preview succeeds' equal "$RESULT" 0
    check 'preview selects the root manifest and verifies both downloads' json_is "$CASE/output.json" \
        '.details.scoop.path=="tool.json" and .details.scoop.status=="planned" and (.details.assets|length)==2'
    check 'flat preview leaves the remote unchanged' equal "$(remote_sha scoop)" "$original"
    check 'flat preview never clones or commits the bucket' test ! -s "$GIT_CALLS"
    invoke false --skip-homebrew --push
    check 'flat bucket publication succeeds' equal "$RESULT" 0
    published=$(remote_sha scoop)
    check 'receipt names the actual updated file and pushed commit' json_is "$CASE/output.json" \
        ".details.scoop.path==\"tool.json\" and .details.scoop.commit==\"$published\" and .details.scoop.pushed"
    command git --git-dir="$CASE/scoop.git" show main:tool.json > "$CASE/published.json" || return 1
    check 'root package contains verified hashes and new URLs' json_is "$CASE/published.json" \
        ".version==\"1.0.1\" and all(.architecture[]; .hash==\"$HASH\" and (.url|contains(\"/v1.0.1/\")))"
    invoke false --skip-homebrew --push
    check 'root package retry is unchanged' json_is "$CASE/output.json" '.details.scoop.status=="unchanged"'
    check 'retry retains exact root package commit' equal "$(remote_sha scoop)" "$published"

    seed shadowed-root || return 1
    for dry in true false; do
        invoke "$dry" --skip-homebrew --push
        check "nested manifest takes precedence (dry=$dry)" equal "$RESULT" 0
        check "receipt records nested manifest (dry=$dry)" json_is "$CASE/output.json" '.details.scoop.path=="bucket/tool.json"'
    done
    check 'inactive root copy is preserved' equal "$(command git --git-dir="$CASE/scoop.git" show main:tool.json)" 'inactive root copy'
    for scenario in missing-nested linked-bucket linked-manifest; do
        seed "$scenario" || return 1
        original=$(remote_sha scoop)
        for dry in true false; do
            invoke "$dry" --skip-homebrew --push
            check "$scenario cannot select a different package (dry=$dry)" nonzero "$RESULT"
            check "$scenario leaves remote intact (dry=$dry)" equal "$(remote_sha scoop)" "$original"
        done
    done
    seed truncated-bucket || return 1
    invoke true --skip-homebrew
    check 'incomplete layout evidence cannot select the root manifest' nonzero "$RESULT"
    check 'incomplete layout stops before the payload download' bash -c '! grep -q "^download " "$1"' _ "$API_CALLS"
    seed flat-bucket-cancel || return 1
    FORMULA_INTERRUPT_STAGE=scoop-blob-read FORMULA_INTERRUPT_CODE=143
    invoke true --skip-homebrew
    check 'interrupted immutable recipe read is terminal' equal "$RESULT" 5
    check 'interrupted reader records original signal' json_is "$CASE/output.json" '.details.operation_exit_code==143'
    FORMULA_INTERRUPT_STAGE=''
}

# Real bare repositories make an accepted-but-interrupted push distinguishable
# from an ordinary failure. The stopped invocation must never advance to the
# next manager, and an explicit new invocation must reconcile the actual branch.
formula_cancellation_cases() {
    local stage code before_brew before_scoop workspace count_before
    for stage in release-read initial-tag recipe-read find-asset download asset-read revalidate-tag; do
        seed "cancel-$stage" || return 1
        before_brew=$(remote_sha homebrew); before_scoop=$(remote_sha scoop)
        FORMULA_INTERRUPT_STAGE="$stage" FORMULA_INTERRUPT_CODE=130
        invoke true
        check "$stage preserves public interruption status" equal "$RESULT" 5
        check "$stage retains original interruption evidence" json_is "$CASE/output.json" \
            '.exit_code==5 and .details.operation_exit_code==130'
        check "$stage stops before another adapter operation" equal "$(tail -1 "$CASE/operations")" "interrupted $stage 130"
        check "$stage cannot change Homebrew" equal "$(remote_sha homebrew)" "$before_brew"
        check "$stage cannot change Scoop" equal "$(remote_sha scoop)" "$before_scoop"
        FORMULA_INTERRUPT_STAGE=''
    done
    for stage in homebrew-clone homebrew-add homebrew-commit-accepted homebrew-push homebrew-push-accepted scoop-push-accepted; do
        seed "cancel-$stage" || return 1
        before_brew=$(remote_sha homebrew); before_scoop=$(remote_sha scoop)
        FORMULA_INTERRUPT_STAGE="$stage" FORMULA_INTERRUPT_CODE=143
        invoke false --push
        check "$stage preserves public interruption status" equal "$RESULT" 5
        check "$stage retains original interruption evidence" json_is "$CASE/output.json" \
            '.exit_code==5 and .details.operation_exit_code==143'
        check "$stage stops before another adapter operation" equal "$(tail -1 "$CASE/operations")" "interrupted $stage 143"
        if [[ "$stage" != scoop-push-accepted ]]; then
            check "$stage never publishes the next manager" equal "$(remote_sha scoop)" "$before_scoop"
        else
            check 'terminal interruption preserves the first confirmed push without a partial-success envelope' \
                json_is "$CASE/output.json" '.status=="error" and .exit_code==5 and
                    .details.pushed==true and .details.homebrew.status=="pushed" and .details.scoop.status=="interrupted"'
        fi
        if [[ "$stage" == *push-accepted ]]; then
            check "$stage fixture performed a real remote push" test "$(remote_sha homebrew)" != "$before_brew"
            check "$stage reports the unacknowledged push honestly" json_is "$CASE/output.json" \
                '(.details.homebrew.status=="interrupted" and .details.homebrew.push_outcome=="uncertain") or
                 (.details.scoop.status=="interrupted" and .details.scoop.push_outcome=="uncertain")'
        fi
        if [[ "$stage" != homebrew-clone ]]; then
            workspace=$(jq -r '.details.work_dir' "$CASE/output.json")
            check "$stage retains its private working evidence" test -s "$workspace/result.json"
        fi
        FORMULA_INTERRUPT_STAGE=''
        count_before=$(grep -c ' push ' "$GIT_CALLS" || true)
        invoke false --push
        check "$stage explicit recovery succeeds" equal "$RESULT" 0
        check "$stage recovery publishes complete recipes" bash -c \
            'git --git-dir="$1" show main:Formula/tool.rb | grep -q "version \"1.0.1\"" &&
             git --git-dir="$2" show main:bucket/tool.json | jq -e ".version==\"1.0.1\"" >/dev/null' \
            _ "$CASE/homebrew.git" "$CASE/scoop.git"
        if [[ "$stage" == homebrew-push-accepted ]]; then
            check 'accepted interrupted Homebrew push is not repeated on explicit retry' \
                equal "$(grep -c ' push ' "$GIT_CALLS")" "$((count_before+1))"
        fi
    done
    # Distinguish cancelled/supervisor statuses from ordinary Git 128 and
    # network failure; ordinary errors retain the existing partial behavior.
    for code in 2 5 124 125 129 137 141; do
        seed "cancel-download-$code" || return 1
        FORMULA_INTERRUPT_STAGE=download FORMULA_INTERRUPT_CODE="$code"
        invoke true --skip-homebrew
        check "download status $code remains terminal" equal "$RESULT" 5
        check "download status $code is retained" json_is "$CASE/output.json" \
            ".details.operation_exit_code==$code"
        check "download status $code stops later calls" equal "$(tail -1 "$CASE/operations")" "interrupted download $code"
        FORMULA_INTERRUPT_STAGE=''
    done
}

formula_partial_inventory_cases() {
    local phase before after result
    for phase in recipe push stale push-error; do
        seed "partial-$phase" || return 1
        before=$(remote_sha scoop)
        # Keep the real Git repositories and the real renderer. The only
        # added fault is an inventory reader that emits a valid first record
        # and then dies (or reports an ordinary jq runtime error).
        (
            jq() {
                if [[ "$phase" == recipe && "${2:-}" == '.urls[]' ]]; then
                    command jq -r '.urls[0]' "$3" || return 1
                elif [[ "$phase" != recipe && "${2:-}" == '[.[] | .asset] | unique_by(.id)[]' ]]; then
                    printf 'read\n' >> "$CASE/row-reads"
                    if [[ $(wc -l < "$CASE/row-reads") -lt 2 ]]; then
                        command jq "$@"; return $?
                    fi
                    if [[ "$phase" == stale ]]; then
                        # Remote ARM64 changed after the first full check, just
                        # before push. The emitted prefix covers x86_64 only.
                        command jq 'map(if .name|contains("aarch64-pc-windows") then .size+=1 else . end)' \
                            "$CASE/assets.json" > "$CASE/drift.json" || return 1
                        cp "$CASE/drift.json" "$CASE/assets.json" || return 1
                    fi
                    command jq -c '[.[] | .asset] | unique_by(.id)[0]' "$3" || return 1
                else
                    command jq "$@"; return $?
                fi
                printf 'partial\n' >> "$CASE/parser-stopped"
                if [[ "$phase" == push-error ]]; then return 5; fi
                bash -c 'kill -KILL "$$"'
            }
            invoke false --skip-homebrew --push
            printf '%s\n' "$RESULT" > "$CASE/command-status"
        )
        result=$(cat "$CASE/command-status") || return 1
        after=$(remote_sha scoop)
        check "$phase exercised the partial reader" test -s "$CASE/parser-stopped"
        check "$phase never advanced the package remote" equal "$after" "$before"
        check "$phase never attempted a push" no_pushes
        if [[ "$phase" == push-error ]]; then
            check 'jq semantic error prevents push with an ordinary failure' equal "$result" 1
        else
            check "$phase preserves public cancellation" equal "$result" 5
            check "$phase retains the stopped parser status" json_is "$CASE/output.json" '.details.operation_exit_code==137'
        fi
        if [[ "$after" != "$before" ]]; then
            command git --git-dir="$CASE/scoop.git" show main:bucket/tool.json > "$CASE/incorrectly-published.json"
            printf 'Unexpected publication: %s\n' "$(command jq -c '{version,urls:[.architecture[].url]}' "$CASE/incorrectly-published.json")"
        fi
    done
}

formula_package_alias_cases() {
    local before_homebrew before_scoop status
    seed package-alias || return 1
    before_homebrew=$(remote_sha homebrew); before_scoop=$(remote_sha scoop)
    invoke true --package-name ee
    check 'alias preview selects both published package names' json_is "$CASE/output.json" \
        '.details.tool=="tool" and .details.package_name=="ee" and .details.repo=="owner/tool" and
         .details.homebrew.path=="Formula/ee.rb" and .details.scoop.path=="bucket/ee.json" and (.details.assets|length)==5'
    invoke false --push --package-name ee
    check 'aliased package publication succeeds' equal "$RESULT" 0
    check 'alias publishes both verified files' json_is "$CASE/output.json" '.details.homebrew.pushed and .details.scoop.pushed'
    check 'only the named Homebrew recipe changes' equal \
        "$(command git --git-dir="$CASE/homebrew.git" diff --name-only "$before_homebrew" HEAD)" "Formula/ee.rb"
    check 'only the named Scoop manifest changes' equal \
        "$(command git --git-dir="$CASE/scoop.git" diff --name-only "$before_scoop" HEAD)" "bucket/ee.json"
    invoke false --push --package-name ee
    check 'retry of an aliased package preserves both commits' json_is "$CASE/output.json" \
        '.details.homebrew.status=="unchanged" and .details.scoop.status=="unchanged"'
    : > "$API_CALLS"
    invoke false --push --package-name ../ee
    check 'CLI refuses path-like package identities' equal "$RESULT" 4
    check 'invalid package name stops before release discovery' test ! -s "$API_CALLS"
    if command -v yq >/dev/null; then
        mkdir -p "$DSR_CONFIG_DIR/repos.d" || return 1
        printf 'formulas: {package_name: ee}\n' > "$DSR_CONFIG_DIR/repos.d/tool.yaml"
        invoke true
        check 'configured alias selects both recipes from the same release' json_is "$CASE/output.json" \
            '.details.repo=="owner/tool" and .details.homebrew.path=="Formula/ee.rb" and .details.scoop.path=="bucket/ee.json"'
        invoke true --package-name tool
        check 'explicit selector overrides the configured alias' json_is "$CASE/output.json" \
            '.details.package_name=="tool" and .details.homebrew.path=="Formula/tool.rb" and .details.scoop.path=="bucket/tool.json"'
        for status in 'null' '["ee"]' '"ee\n"' '"../ee"'; do
            printf 'formulas: {package_name: %s}\n' "$status" > "$DSR_CONFIG_DIR/repos.d/tool.yaml"
            : > "$API_CALLS"
            invoke false --push
            check "invalid configured package identity fails: $status" equal "$RESULT" 4
            check "invalid name stops before release discovery: $status" test ! -s "$API_CALLS"
        done
    fi
}

formula_routing_cases() {
    local caller before_index before_ref sentinel work
    seed routing || return 1
    caller="$CASE/caller"
    mkdir -p "$caller/bucket" "$CASE/ambient-template"
    command git init -q -b main "$caller" || return 1
    printf 'caller work must survive\n' > "$caller/bucket/tool.json"
    command git -C "$caller" add . || return 1
    command git -C "$caller" commit -qm caller || return 1
    printf 'unstaged caller edit\n' >> "$caller/bucket/tool.json"
    before_index=$(sha256sum "$caller/.git/index")
    before_ref=$(command git -C "$caller" rev-parse HEAD)
    sentinel=$(sha256sum "$caller/bucket/tool.json")
    printf '[core]\nworktree = %s\n' "$caller" > "$CASE/ambient-template/config"
    # All variables are scoped to the command's existing subshell. Local test
    # setup and independent observations retain their real repository routing.
    (
        export GIT_DIR="$caller/.git" GIT_COMMON_DIR="$caller/.git" GIT_WORK_TREE="$caller"
        export GIT_INDEX_FILE="$caller/.git/index" GIT_OBJECT_DIRECTORY="$caller/.git/objects"
        export GIT_TEMPLATE_DIR="$CASE/ambient-template" GIT_CONFIG_COUNT=1
        export GIT_CONFIG_KEY_0=core.worktree GIT_CONFIG_VALUE_0="$caller"
        invoke false --skip-homebrew --push
        printf '%s\n' "$RESULT" > "$CASE/routing-status"
    )
    check 'formula publication ignores caller Git routing' equal "$(cat "$CASE/routing-status")" 0
    check 'caller Git index is byte-identical after formula publication' equal "$(sha256sum "$caller/.git/index")" "$before_index"
    check 'caller branch is unchanged after formula publication' equal "$(command git -C "$caller" rev-parse HEAD)" "$before_ref"
    check 'caller working file is untouched after formula publication' equal "$(sha256sum "$caller/bucket/tool.json")" "$sentinel"
    check 'only the selected Scoop repository receives the new recipe' bash -c \
        'git --git-dir="$1" show main:bucket/tool.json | jq -e ".version==\"1.0.1\"" >/dev/null' _ "$CASE/scoop.git"
    work=$(jq -r '.details.work_dir' "$CASE/output.json")
    if [[ -d "$work/scoop/.git" ]]; then
        check 'private formula repository owns its index and objects' bash -c \
            'test -f "$1/.git/index" && test -d "$1/.git/objects" && test ! -e "$1/.git/objects/info/alternates"' _ "$work/scoop"
    else check 'private formula repository owns its index and objects' false; fi
}

case "${FORMULAS_TEST_SCOPE:-all}" in
    partial-rows) formula_partial_inventory_cases || exit 1; printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"; [[ "$FAIL" -eq 0 ]]; exit $? ;;
    package-alias) formula_package_alias_cases || exit 1; printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"; [[ "$FAIL" -eq 0 ]]; exit $? ;;
    scoop-layout) formula_scoop_layout_cases || exit 1; printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"; [[ "$FAIL" -eq 0 ]]; exit $? ;;
    cancellation) formula_cancellation_cases; printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"; [[ "$FAIL" -eq 0 ]]; exit $? ;;
    routing) formula_routing_cases; printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"; [[ "$FAIL" -eq 0 ]]; exit $? ;;
    all) ;;
    *) printf 'Unknown formula test scope\n' >&2; exit 4 ;;
esac

seed dry-run || exit 1
before_brew=$(remote_sha homebrew); before_scoop=$(remote_sha scoop)
invoke true --push
check 'dry run succeeds' equal "$RESULT" 0
check 'dry run output is a single JSON result' bash -c 'jq -es "length==1" "$1" >/dev/null' _ "$CASE/output.json"
check 'dry run plans five exact assets' json_is "$CASE/output.json" '.details.assets | length==5'
check 'dry run reports planned, not pushed' json_is "$CASE/output.json" '.details.homebrew.status=="planned" and .details.scoop.status=="planned" and .details.pushed==false and .details.work_dir==null'
check 'each dry-run receipt names its own recipe' json_is "$CASE/output.json" '.details.homebrew.path=="Formula/tool.rb" and .details.scoop.path=="bucket/tool.json"'
check 'dry run creates no persistent workspace' test ! -e "$DSR_STATE_DIR/formulas"
check 'dry run never invokes Git' test ! -s "$GIT_CALLS"
check 'dry run cleans its temporary workspace' equal "$(find "$TMPDIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d '[:space:]')" 0
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
check 'review workspace is private' equal "$(stat -c '%a' "$workspace" 2>/dev/null || stat -f '%Lp' "$workspace" 2>/dev/null)" 700
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

# Scoop resolves URL and hash overrides independently. In particular a hash-
# only architecture must follow the updated inherited URL, while an URL-only
# architecture must not inherit the newly calculated hash of a different file.
cat > "$CASE/inherited.json" <<'JSON'
{"version":"1.0.0","url":"https://github.com/owner/tool/releases/download/v1.0.0/tool.zip","hash":"old-root","extract_dir":"tool-1.0.0","architecture":{"64bit":{"hash":"old-override","extract_dir":"intel-1.0.0"},"arm64":{"url":"https://github.com/owner/tool/releases/download/v1.0.0/tool-arm64.zip","bin":"arm.exe"},"32bit":{"bin":"generic.exe"}}}
JSON
ARM_HASH=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
jq -nc --arg hash "$HASH" --arg arm "$ARM_HASH" '{
  "https://github.com/owner/tool/releases/download/v1.0.0/tool.zip":
    {url:"https://github.com/owner/tool/releases/download/v1.0.1/tool.zip",sha256:$hash},
  "https://github.com/owner/tool/releases/download/v1.0.0/tool-arm64.zip":
    {url:"https://github.com/owner/tool/releases/download/v1.0.1/tool-arm64.zip",sha256:$arm}
}' > "$CASE/inherited.plan.json"
status=0
_formulas_scoop apply "$CASE/inherited.json" "$CASE/inherited.plan.json" 1.0.1 \
    > "$CASE/inherited.updated" 2> "$CASE/inherited.err" || status=$?
check 'Scoop independent inheritance renders successfully' equal "$status" 0
check 'inherited URL gets the new architecture checksum' json_is "$CASE/inherited.updated" ".architecture[\"64bit\"].hash==\"$HASH\" and (.architecture[\"64bit\"] | has(\"url\") | not)"
check 'URL-only ARM64 override gets its own verified hash' json_is "$CASE/inherited.updated" ".architecture.arm64.hash==\"$ARM_HASH\" and (.architecture.arm64.url | endswith(\"tool-arm64.zip\"))"
check 'inherited extraction directories update without explicit URL' json_is "$CASE/inherited.updated" '.extract_dir=="tool-1.0.1" and .architecture["64bit"].extract_dir=="intel-1.0.1"'
check 'architecture with no download overrides keeps inheritance' json_is "$CASE/inherited.updated" '.architecture["32bit"]=={bin:"generic.exe"}'

jq '.extract_dir=["tool-1.0.0",null] |
    .architecture={"64bit":{"hash":["old-arch","arch-auxiliary"],"extract_dir":["intel-1.0.0",null]}}' \
    "$CASE/array.json" > "$CASE/inherited-array.json"
status=0
_formulas_scoop apply "$CASE/inherited-array.json" "$CASE/inherited.plan.json" 1.0.1 \
    > "$CASE/inherited-array.updated" 2> "$CASE/inherited-array.err" || status=$?
check 'inherited URL arrays render successfully' equal "$status" 0
check 'inherited arrays preserve the architecture auxiliary hash' json_is "$CASE/inherited-array.updated" ".architecture[\"64bit\"].hash==[\"$HASH\",\"arch-auxiliary\"] and .hash==[\"$HASH\",\"auxiliary\"]"
check 'extraction arrays retain null placeholders and update versions' json_is "$CASE/inherited-array.updated" '.extract_dir==["tool-1.0.1",null] and .architecture["64bit"].extract_dir==["intel-1.0.1",null]'
jq '.architecture["64bit"].hash=["only-one"]' "$CASE/inherited-array.json" > "$CASE/inherited-bad.json"
status=0
_formulas_scoop apply "$CASE/inherited-bad.json" "$CASE/inherited.plan.json" 1.0.1 \
    > "$CASE/inherited-bad.out" 2> "$CASE/inherited-bad.err" || status=$?
check 'inherited URL/hash length mismatch is rejected' nonzero "$status"

# The shared verified plan is a performance cache, not permission to skip the
# second recipe's independent version-to-tag consistency validation.
printf '{}\n' > "$CASE/plan.json"
printf '{"version":"1.0.0","urls":["https://github.com/owner/tool/releases/download/v1.0.0/tool-linux-x86_64.tar.gz"]}\n' > "$CASE/consistent.scan.json"
status=0
_formulas_plan_assets owner/tool v1.0.1 9 "$CASE/consistent.scan.json" "$CASE" \
    > "$CASE/consistent.out" 2> "$CASE/consistent.err" || status=$?
check 'exact shared URL creates a verified plan entry' equal "$status" 0
jq '.version="2.0.0"' "$CASE/consistent.scan.json" > "$CASE/inconsistent.scan.json"
status=0
_formulas_plan_assets owner/tool v1.0.1 9 "$CASE/inconsistent.scan.json" "$CASE" \
    > "$CASE/inconsistent.out" 2> "$CASE/inconsistent.err" || status=$?
check 'shared cached URL cannot bypass recipe version validation' equal "$status" 4

seed inherited-publish || exit 1
cat > "$CASE/scoop-source/bucket/tool.json" <<'JSON'
{"version":"1.0.0","url":"https://github.com/owner/tool/releases/download/v1.0.0/tool-1.0.0-x86_64-pc-windows-msvc.zip","hash":"old-root","extract_dir":"tool-1.0.0","architecture":{"64bit":{"hash":"old-override","extract_dir":"intel-1.0.0"},"arm64":{"url":"https://github.com/owner/tool/releases/download/v1.0.0/tool-1.0.0-aarch64-pc-windows-msvc.zip#/tool.zip","bin":"arm.exe"}}}
JSON
command git -C "$CASE/scoop-source" add bucket/tool.json || exit 1
command git -C "$CASE/scoop-source" commit -qm 'seed independent inheritance' || exit 1
command git -C "$CASE/scoop-source" push -q "$CASE/scoop.git" HEAD:refs/heads/main || exit 1
before_brew=$(remote_sha homebrew)
invoke false --push --skip-homebrew
check 'Scoop-only inherited recipe publishes through the command' equal "$RESULT" 0
check 'Scoop-only command reports skipped Homebrew and actual push' json_is "$CASE/output.json" '.details.homebrew.status=="skipped" and .details.scoop.status=="pushed"'
check 'Scoop-only command never changes Homebrew' equal "$(remote_sha homebrew)" "$before_brew"
command git --git-dir="$CASE/scoop.git" show main:bucket/tool.json > "$CASE/published.json" || exit 1
check 'published inherited hash and extraction directory are current' json_is "$CASE/published.json" ".architecture[\"64bit\"].hash==\"$HASH\" and .architecture[\"64bit\"].extract_dir==\"intel-1.0.1\" and (.architecture[\"64bit\"] | has(\"url\") | not)"
before_scoop=$(remote_sha scoop)
invoke false --push --skip-homebrew
check 'inherited publication is idempotent' equal "$RESULT" 0
check 'inherited retry produces no new commit' equal "$(remote_sha scoop)" "$before_scoop"

seed inherited-invalid-publish || exit 1
cat > "$CASE/scoop-source/bucket/tool.json" <<'JSON'
{"version":"1.0.0","url":["https://github.com/owner/tool/releases/download/v1.0.0/tool-1.0.0-x86_64-pc-windows-msvc.zip","https://example.org/runtime.exe"],"hash":["old-app","auxiliary"],"architecture":{"64bit":{"hash":["missing-auxiliary"]}}}
JSON
command git -C "$CASE/scoop-source" add bucket/tool.json || exit 1
command git -C "$CASE/scoop-source" commit -qm 'seed invalid inherited hash array' || exit 1
command git -C "$CASE/scoop-source" push -q "$CASE/scoop.git" HEAD:refs/heads/main || exit 1
before_brew=$(remote_sha homebrew); before_scoop=$(remote_sha scoop)
invoke false --push
check 'command refuses an inconsistent inherited checksum array' nonzero "$RESULT"
check 'inherited preflight failure prevents Homebrew publication' equal "$(remote_sha homebrew)" "$before_brew"
check 'inherited preflight failure prevents Scoop publication' equal "$(remote_sha scoop)" "$before_scoop"

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

formula_routing_cases
formula_cancellation_cases
formula_scoop_layout_cases || exit 1
formula_package_alias_cases || exit 1
formula_partial_inventory_cases || exit 1

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
