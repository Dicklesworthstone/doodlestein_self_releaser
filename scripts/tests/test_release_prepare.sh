#!/usr/bin/env bash
# Production draft state machine with file-backed GitHub transport fixtures.
# Bash, jq, hashing, locks, argument validation, atomic state and processes are real.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
# shellcheck source=src/release_prepare.sh
source "$ROOT/src/release_prepare.sh"
TMP=$(mktemp -d)
CASE='' OUT='' RC=0 PASSED=0 FAILED=0 TOTAL=0
SHA=1111111111111111111111111111111111111111
OTHER=2222222222222222222222222222222222222222
# These replace authentication, transport and the transport timeout only.
_sbr_require() { [[ ! -e "$CASE/auth-fail" ]]; }
_sbr_run() { "$@"; }
gh_resolve_tag_sha() {
    [[ ! -e "$CASE/tag-missing" ]] || return 7
    cat "$CASE/sha"
}
_sbr_api() {
    printf 'GET %s\n' "$1" >> "$CASE/calls"
    [[ ! -e "$CASE/read-fail" ]] || return 8
    case "$1" in
        repos/acme/tool) cat "$CASE/repository" ;;
        repos/acme/tool/releases\?*)
            if [[ -e "$CASE/list-bad" ]]; then printf '{}\n'; return; fi
            if [[ -e "$CASE/list-multiple-json" ]]; then printf '[]\n[]\n'; return; fi
            if [[ -e "$CASE/repeated-pages" ]]; then
                jq -n '[range(1;101)|{id:.,tag_name:"unrelated"}]'; return
            fi
            if [[ -e "$CASE/page-one" && "$1" == *'page=1' ]]; then cat "$CASE/page-one"; return; fi
            if [[ -e "$CASE/page-one" && "$1" == *'page=2' && -e "$CASE/page-two-fail" ]]; then return 8; fi
            if [[ -e "$CASE/duplicate" ]]; then
                jq -nc '[{id:41,tag_name:"v1.2.3"},{id:42,tag_name:"v1.2.3"}]'
            elif [[ -e "$CASE/release" ]]; then jq -c '[.]' "$CASE/release"
            else printf '[]\n'; fi ;;
        repos/acme/tool/releases/*) [[ -e "$CASE/release" ]] && cat "$CASE/release" ;;
        *) return 8 ;;
    esac
}
gh() {
    if [[ "${5:-}" == PATCH ]]; then
        [[ "$1 $2 $3 $4 $5 $6 $7" == 'api --hostname github.com --method PATCH repos/acme/tool/releases/42 --input' ]] || return 98
        jq -e '.=={draft:false,make_latest:"false"}' "$8" >/dev/null || return 98
        printf 'PATCH\n' >> "$CASE/calls"
        [[ ! -e "$CASE/patch-fail" ]] || return 8
        mutate "$CASE/release" '.draft=false' || return 1
        [[ ! -e "$CASE/patch-lost" ]] || return 8
        cat "$CASE/release"
        return
    fi
    [[ "$1 $2 $3 $4 $5 $6 $7" == 'api --hostname github.com --method POST repos/acme/tool/releases --input' ]] || return 98
    printf 'POST\n' >> "$CASE/calls"
    cp "$8" "$CASE/request"
    [[ ! -e "$CASE/post-slow" ]] || sleep 1
    [[ ! -e "$CASE/post-fail" ]] || return 22
    [[ ! -e "$CASE/false-success" ]] || { printf '{}\n'; return 0; }
    if [[ -e "$CASE/post-crash" ]]; then
        kill -KILL "$BASHPID"
        return 8
    fi
    jq -c '.+{id:42,node_id:"REL42",url:"https://api.github.com/repos/acme/tool/releases/42",
        upload_url:"https://uploads.github.com/repos/acme/tool/releases/42/assets{?name,label}"}' "$8" > "$CASE/release"
    [[ ! -e "$CASE/post-move-tag" ]] || printf '%s\n' "$OTHER" > "$CASE/sha"
    [[ ! -e "$CASE/post-duplicate" ]] || touch "$CASE/duplicate"
    [[ ! -e "$CASE/lost-ack" ]] || return 8
    if [[ -e "$CASE/wrong-id" ]]; then printf '{"id":99}\n'; else cat "$CASE/release"; fi
}
new_case() {
    CASE=$(mktemp -d "$TMP/case.XXXXXXXX")
    printf '%s\n' "$SHA" > "$CASE/sha"
    printf '{"id":11,"node_id":"REPO11","full_name":"acme/tool"}\n' > "$CASE/repository"
    : > "$CASE/calls"
}
run() {
    RC=0
    OUT=$(release_prepare --repo acme/tool --tag v1.2.3 --sha "$SHA" --state-dir "$CASE/state" "$@" 2> "$CASE/diagnostics") || RC=$?
}
check() {
    TOTAL=$((TOTAL+1))
    if "$@"; then PASSED=$((PASSED+1)); printf 'ok %s - %s\n' "$TOTAL" "$*"; else
        FAILED=$((FAILED+1)); printf 'FAIL %s: %s (rc=%s)\n%s\n' "$TOTAL" "$*" "$RC" "$OUT" >&2
        cat "$CASE/diagnostics" >&2 2>/dev/null || true
    fi
}
assert_rc() { [[ "$RC" -eq "$1" ]]; }
posts() { [[ $(grep -c '^POST$' "$CASE/calls" || true) -eq "$1" ]]; }
json() { jq -es "$1" <<< "$OUT" >/dev/null 2>&1; }
state_file() { find "$CASE/state" -name state.json -type f; }
mutate() {
    local file="$1" expression="$2" tmp
    tmp=$(mktemp "$CASE/mutation.XXXXXXXX")
    jq "$expression" "$file" > "$tmp" && mv "$tmp" "$file"
}

[[ "${DSR_PREPARE_FIXTURES_ONLY:-false}" != true ]] || return 0

new_case
run --existing-only
check assert_rc 2
check posts 0
run
check assert_rc 0
run --existing-only
check assert_rc 0
check posts 1
check json '.[0].plan.request.draft and .[0].plan.repo=="acme/tool"'

new_case
run --dry-run
check assert_rc 0
check json 'length==1 and (.[0]|.dry_run and .status=="planned" and .plan.request.draft and .plan.request.make_latest=="false")'
check test ! -e "$CASE/state"
check test ! -s "$CASE/calls"
run
check assert_rc 0
check posts 1
check json 'length==1 and (.[0]|.status=="prepared" and .context.release.id==42 and .context.release.draft and .creation_attempts==1)'
check jq -e '.target_commitish=="1111111111111111111111111111111111111111" and .draft==true and .make_latest=="false" and .name=="v1.2.3" and .body=="" and (.generate_release_notes|not)' "$CASE/request"
run
check assert_rc 0
check posts 1
check json '.[0].creation_attempts==1'
mutate "$CASE/release" '.draft=false'
run
check assert_rc 0
check json '.[0].context.release.draft==false'
check posts 1
mutate "$CASE/release" '.draft=true'
run
check assert_rc 2
check posts 1

new_case
touch "$CASE/lost-ack"
run
check assert_rc 0
check posts 1
run
check assert_rc 0
check posts 1

new_case
touch "$CASE/false-success"
run
check assert_rc 8
check posts 1
check jq -e '.phase=="uncertain" and .attempts==1' "$(state_file)"
run
check assert_rc 2
check posts 1
mv "$CASE/false-success" "$CASE/false-success.disabled"
run --retry-uncertain
check assert_rc 0
check posts 2
check json '.[0].creation_attempts==2'

new_case
touch "$CASE/post-fail"
run
check assert_rc 8
check posts 1
run
check assert_rc 2
check posts 1

new_case
touch "$CASE/post-crash"
run
check test "$RC" -ne 0
check posts 1
run
check assert_rc 2
check posts 1

for marker in read-fail list-bad list-multiple-json repeated-pages tag-missing; do
    new_case; touch "$CASE/$marker"; run
    check test "$RC" -ne 0
    check posts 0
done
new_case
printf '%s\n' "$OTHER" > "$CASE/sha"
run
check assert_rc 7
check posts 0
new_case
touch "$CASE/duplicate"
run
check assert_rc 2
check posts 0
new_case
touch "$CASE/post-move-tag"
run
check assert_rc 7
check posts 1
new_case
touch "$CASE/post-duplicate"
run
check assert_rc 2
check posts 1
new_case
touch "$CASE/wrong-id"
run
check assert_rc 2
check posts 1
run
check assert_rc 2
check posts 1

# Later pages must be read even if the first page contains no relevant tag.
new_case
jq -n '[range(100;200)|{id:.,tag_name:"other"}]' > "$CASE/page-one"
run
check assert_rc 0
check posts 1
new_case
jq -n '[range(100;200)|{id:.,tag_name:"other"}]' > "$CASE/page-one"
touch "$CASE/page-two-fail"
run
check assert_rc 8
check posts 0

# External release and repository replacements never become a fresh creation.
new_case; run
mv "$CASE/release" "$CASE/disappeared"
run --retry-uncertain
check assert_rc 2
check posts 1
new_case; run
mutate "$CASE/release" '.id=43|.node_id="REL43"|.url="https://api.github.com/repos/acme/tool/releases/43"|.upload_url="https://uploads.github.com/repos/acme/tool/releases/43/assets{?name,label}"'
run
check assert_rc 2
check posts 1
new_case; run
mutate "$CASE/repository" '.id=12'
run
check assert_rc 2
check posts 1
new_case; run
mutate "$CASE/release" '.body="changed notes"'
run
check assert_rc 2
check posts 1
new_case; run
run --name Different
check assert_rc 2
check posts 1
new_case; run
run --prerelease
check assert_rc 2
check posts 1
new_case; run
printf '{}\n' > "$(state_file)"
run
check assert_rc 2
check posts 1

# Adopt only a matching draft; preserve all existing fields and upload no data.
new_case
jq -n '{id:42,node_id:"REL42",tag_name:"v1.2.3",draft:true,prerelease:false,
    target_commitish:"main",name:"v1.2.3",body:null,
    url:"https://api.github.com/repos/acme/tool/releases/42",
    upload_url:"https://uploads.github.com/repos/acme/tool/releases/42/assets{?name,label}"}' > "$CASE/release"
run
check assert_rc 0
check posts 0
check json '.[0].creation_attempts==0 and .[0].context.release.target_commitish=="main"'
new_case
jq -n '{id:42,node_id:"REL42",tag_name:"v1.2.3",draft:false,prerelease:false,
    target_commitish:"main",name:"v1.2.3",body:null,
    url:"https://api.github.com/repos/acme/tool/releases/42",
    upload_url:"https://uploads.github.com/repos/acme/tool/releases/42/assets{?name,label}"}' > "$CASE/release"
run
check assert_rc 2
check posts 0

new_case
printf 'Notes with "quotes" and Unicode: λ\n\n' > "$CASE/notes"
run --name 'Release 1.2.3' --notes-file "$CASE/notes" --prerelease
check assert_rc 0
check jq -e '.name=="Release 1.2.3" and .body=="Notes with \"quotes\" and Unicode: λ\n\n" and .prerelease' "$CASE/request"
printf 'changed\n' >> "$CASE/notes"
run --name 'Release 1.2.3' --notes-file "$CASE/notes" --prerelease
check assert_rc 2
check posts 1

# Every known argument error and an offline dry run fail before auth/network.
for value in 'bad..tag' '-v1' 'bad tag' 'bad@{tag' ''; do
    new_case
    RC=0; OUT=$(release_prepare --repo acme/tool --tag "$value" --sha "$SHA" --state-dir "$CASE/state" 2> "$CASE/diagnostics") || RC=$?
    check assert_rc 4
    check posts 0
done
new_case; run --unknown
check assert_rc 4
check posts 0
new_case; run --name one --name two
check assert_rc 4
check posts 0
new_case
printf 'bad\0notes' > "$CASE/notes"
run --notes-file "$CASE/notes"
check assert_rc 4
check posts 0
new_case
mkdir "$CASE/real-state"; ln -s "$CASE/real-state" "$CASE/state"
run
check assert_rc 4
check posts 0
new_case; run
file=$(state_file); mv "$file" "$CASE/old-state"; ln -s "$CASE/old-state" "$file"
run
check assert_rc 2
check posts 1

# Saving the pre-POST intent must succeed before the HTTP call is allowed.
new_case
save_definition=$(declare -f _rp_save)
_rp_save() { return 1; }
run
check assert_rc 1
check posts 0
eval "$save_definition"

# Real cross-process flock: losers may retry, but never send another POST.
new_case; touch "$CASE/post-slow"
pids=()
for n in 1 2 3 4; do
    (release_prepare --repo acme/tool --tag v1.2.3 --sha "$SHA" --state-dir "$CASE/state" > "$CASE/out.$n" 2> "$CASE/err.$n"; printf '%s\n' "$?" > "$CASE/rc.$n") &
    pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid" || true; done
check posts 1
check test "$(grep -l '^0$' "$CASE"/rc.* | wc -l)" -ge 1
for n in 1 2 3 4; do
    check jq -es 'length==1 and (.[0].exit_code==0 or .[0].exit_code==2)' "$CASE/out.$n"
done
run
check assert_rc 0
check posts 1
printf '%s checks: %s passed, %s failed. Fixtures retained at %s\n' "$TOTAL" "$PASSED" "$FAILED" "$TMP"
((FAILED==0))
