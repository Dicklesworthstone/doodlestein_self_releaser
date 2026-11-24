#!/usr/bin/env bash
# Production draft state machine with file-backed GitHub transport fixtures.
# Bash, jq, hashing, locks, argument validation, atomic state and processes are real.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
# Keep the real adapter status policy loaded before replacing transport only.
# shellcheck source=src/github.sh
source "$ROOT/src/github.sh"
# shellcheck source=src/release_prepare.sh
source "${PREPARE_TEST_MODULE:-$ROOT/src/release_prepare.sh}"
TMP=$(mktemp -d)
CASE='' OUT='' RC=0 PASSED=0 FAILED=0 TOTAL=0
SHA=1111111111111111111111111111111111111111
OTHER=2222222222222222222222222222222222222222
# A transport may finish its remote effect, print a complete response, and
# still return a terminal status. Inject one such result and record the exact
# boundary so every later request or write is independently observable.
fixture_stop() {
    local boundary="$1" selected='' occurrence=0 status=0 seen=0
    [[ -f "$CASE/stop-request" && ! -e "$CASE/stop-seen" ]] || return 0
    read -r selected occurrence status < "$CASE/stop-request" || return 1
    [[ "$boundary" == "$selected" ]] || return 0
    [[ ! -f "$CASE/stop-count" ]] || read -r seen < "$CASE/stop-count"
    seen=$((seen+1))
    printf '%s\n' "$seen" > "$CASE/stop-count"
    ((seen == occurrence)) || return 0
    printf 'STOP %s %s\n' "$boundary" "$status" >> "$CASE/calls"
    printf '%s\n' "$status" > "$CASE/stop-seen"
    return "$status"
}
# These replace authentication, transport and the transport timeout only.
_sbr_require() { [[ ! -e "$CASE/auth-fail" ]]; }
_sbr_run() { "$@"; }
gh_resolve_tag_sha() {
    [[ ! -e "$CASE/tag-missing" ]] || return 7
    cat "$CASE/sha" || return $?
    fixture_stop tag
}
_sbr_api() {
    local boundary=''
    printf 'GET %s\n' "$1" >> "$CASE/calls"
    [[ ! -e "$CASE/read-fail" ]] || return 8
    case "$1" in
        repos/acme/tool) boundary=repository; cat "$CASE/repository" ;;
        repos/acme/tool/releases\?*)
            boundary=listing
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
        repos/acme/tool/releases/*) boundary=context; [[ -e "$CASE/release" ]] && cat "$CASE/release" ;;
        *) return 8 ;;
    esac || return $?
    fixture_stop "$boundary"
}
gh() {
    if [[ "${5:-}" == PATCH ]]; then
        [[ "$1 $2 $3 $4 $5 $6 $7" == 'api --hostname github.com --method PATCH repos/acme/tool/releases/42 --input' ]] || return 98
        jq -e '.=={draft:false,make_latest:"false"}' "$8" >/dev/null || return 98
        printf 'PATCH\n' >> "$CASE/calls"
        fixture_stop promote-before || return $?
        [[ ! -e "$CASE/patch-fail" ]] || return 8
        mutate "$CASE/release" '.draft=false' || return 1
        [[ ! -e "$CASE/patch-lost" ]] || return 8
        cat "$CASE/release" || return $?
        fixture_stop promote || return $?
        return
    fi
    [[ "$1 $2 $3 $4 $5 $6 $7" == 'api --hostname github.com --method POST repos/acme/tool/releases --input' ]] || return 98
    printf 'POST\n' >> "$CASE/calls"
    cp "$8" "$CASE/request"
    fixture_stop create-before || return $?
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
    fixture_stop create
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
stopped_last() { [[ -f "$CASE/stop-seen" && "$(tail -n 1 "$CASE/calls")" == STOP\ * ]]; }
json() { jq -es "$1" <<< "$OUT" >/dev/null 2>&1; }
state_file() { find "$CASE/state" -name state.json -type f; }
mutate() {
    local file="$1" expression="$2" tmp
    tmp=$(mktemp "$CASE/mutation.XXXXXXXX")
    jq "$expression" "$file" > "$tmp" && mv "$tmp" "$file"
}

[[ "${DSR_PREPARE_FIXTURES_ONLY:-false}" != true ]] || return 0

# Sourceable consumers may receive their authentication and transport adapters
# from the caller. A pure cancellation policy must not load another transport
# over them or require github.sh in an otherwise complete narrow installation.
test_sourceable_transport() {
    local module lock_mode installed
    for module in release_prepare release_finalize_core; do
        for lock_mode in inherited fresh; do
            new_case
            installed="$CASE/installed"
            mkdir "$installed" || return 1
            case "$module" in
                release_prepare)
                    cp "${PREPARE_TEST_MODULE:-$ROOT/src/release_prepare.sh}" "$installed/$module.sh" || return 1 ;;
                release_finalize_core)
                    cp "${FINALIZE_CORE_TEST_MODULE:-$ROOT/src/release_finalize_core.sh}" "$installed/$module.sh" || return 1 ;;
            esac
            cp "$ROOT/src/guardrails.sh" "$installed/guardrails.sh" || return 1
            RC=0
            OUT=$(
                unset -f _gh_operation_interrupted
                [[ "$lock_mode" != fresh ]] || unset -f dsr_lock_fd
                gh_api() { printf '{"selected_transport":"caller"}\n'; }
                sbom_publish_artifacts() { return 97; }
                sbom_verify_release() { return 98; }
                # shellcheck source=/dev/null
                source "$installed/$module.sh" || exit $?
                case "$module" in
                    release_prepare) _rp_require || exit $? ;;
                    release_finalize_core) _rf_require || exit $? ;;
                esac
                gh_api repos/acme/tool || exit $?
                _rp_source "$(jq -nc --arg sha "$SHA" \
                    '{repo:"acme/tool",request:{tag_name:"v1.2.3",target_commitish:$sha}}')" || exit $?
                for stopped in 2 5 124 125 129 130 137 139 141 143 255; do
                    _gh_operation_interrupted "$stopped" || exit 1
                done
                for ordinary in 0 1 3 4 6 7 8 22 128; do
                    if _gh_operation_interrupted "$ordinary"; then exit 1; fi
                done
            ) 2> "$CASE/diagnostics" || RC=$?
            check assert_rc 0
            check json 'length==2 and .[0].selected_transport=="caller" and
                .[1].repository.full_name=="acme/tool" and .[1].tag_commit=="1111111111111111111111111111111111111111"'
            check posts 0
            check test ! -e "$CASE/state"
        done
    done
}

test_terminal_creation() {
    local status original_request selected="${1:-all}"
    case "$selected" in all|2|5|124|125|130|143) ;; *) return 4 ;; esac
    for status in 2 5 124 125 130 143; do
        [[ "$selected" == all || "$selected" == "$status" ]] || continue
        new_case
        printf 'create 1 %s\n' "$status" > "$CASE/stop-request"
        run
        check assert_rc 5
        check json 'length==1 and (.[0]|.status=="error" and .exit_code==5)'
        check stopped_last
        check posts 1
        check jq -e '.phase=="uncertain" and .attempts==1 and .candidate_id==null and .context==null' "$(state_file)"
        check jq -e '.id==42 and .draft==true' "$CASE/release"
        original_request=$(_rp_hash < "$CASE/request")
        # A new invocation may reconcile the accepted draft without another
        # POST. The stopped invocation may not make that decision itself.
        run
        check assert_rc 0
        check posts 1
        check json '.[0].context.release.id==42 and .[0].creation_attempts==1'
        check test "$(_rp_hash < "$CASE/request")" = "$original_request"
    done
    [[ "$selected" == all || "$selected" == 5 ]] || return 0
    new_case
    printf 'create-before 1 5\n' > "$CASE/stop-request"
    run
    check assert_rc 5
    check stopped_last
    check posts 1
    check test ! -e "$CASE/release"
    run
    check assert_rc 2
    check posts 1
    run --retry-uncertain
    check assert_rc 0
    check posts 2
}

test_terminal_preparation_reads() {
    local probe boundary occurrence selected="${1:-all}"
    case "$selected" in all|tag:2|tag:3|tag:4|tag:5|listing:3|context:2) ;; *) return 4 ;; esac
    # Pre-intent, pre-POST, post-POST and final source checks, followed by the
    # last listing and context checks that bind a preparation receipt.
    for probe in tag:2 tag:3 tag:4 tag:5 listing:3 context:2; do
        [[ "$selected" == all || "$selected" == "$probe" ]] || continue
        boundary="${probe%:*}"; occurrence="${probe#*:}"
        new_case
        printf '%s %s 5\n' "$boundary" "$occurrence" > "$CASE/stop-request"
        run
        check assert_rc 5
        check stopped_last
        check json '.[0].status=="error" and .[0].exit_code==5'
        check jq -e '.phase!="prepared"' "$(state_file)"
        run
        # Pre-POST uncertainty still requires explicit retry; once a draft
        # exists the same retained intent is sufficient to recover it.
        if [[ ! -e "$CASE/release" && "$RC" -eq 2 ]]; then run --retry-uncertain; fi
        check assert_rc 0
        check posts 1
        check json '.[0].context.release.id==42'
    done
}

case "${1:-}" in
    --sourceable-only)
        test_sourceable_transport || exit $?
        printf '%s checks: %s passed, %s failed. Fixtures retained at %s\n' "$TOTAL" "$PASSED" "$FAILED" "$TMP"
        ((FAILED==0))
        exit $? ;;
    --terminal-creation-only|--terminal-reads-only|--terminal-creation=*|--terminal-reads=*)
        case "$1" in
            --terminal-creation-only) test_terminal_creation ;;
            --terminal-reads-only) test_terminal_preparation_reads ;;
            --terminal-creation=*) test_terminal_creation "${1#*=}" || exit $? ;;
            --terminal-reads=*) test_terminal_preparation_reads "${1#*=}" || exit $? ;;
        esac
        printf '%s checks: %s passed, %s failed. Fixtures retained at %s\n' "$TOTAL" "$PASSED" "$FAILED" "$TMP"
        ((FAILED==0))
        exit $? ;;
esac

test_sourceable_transport || exit $?

test_large_notes() {
    new_case
    # The documented byte limit applies to the notes, not their larger JSON
    # representation. Exercise the entire create/reconcile/resume lifecycle.
    jq -nrj '"\\" * 65534 + "\n\n"' > "$CASE/notes"
    check test "$(wc -c < "$CASE/notes")" -eq 65536
    run --dry-run --notes-file "$CASE/notes"
    check assert_rc 0
    check test "${#OUT}" -gt 131072
    check cmp -s "$CASE/notes" <(jq -jr '.plan.request.body' <<< "$OUT")
    check test ! -e "$CASE/state"
    check posts 0
    touch "$CASE/lost-ack"
    run --notes-file "$CASE/notes"
    check assert_rc 0
    check posts 1
    check json '.[0].status=="prepared" and .[0].creation_attempts==1 and .[0].context.release.id==42'
    check cmp -s "$CASE/notes" <(jq -jr '.body' "$CASE/request")
    check cmp -s "$CASE/notes" <(jq -jr '.plan.request.body' "$(state_file)")
    run --existing-only --notes-file "$CASE/notes"
    check assert_rc 0
    check posts 1
    local original_state
    original_state=$(_rp_hash < "$(state_file)")
    cp "$CASE/notes" "$CASE/original-notes"
    printf 'different notes\n' > "$CASE/notes"
    run --notes-file "$CASE/notes"
    check assert_rc 2
    check posts 1
    check test "$(_rp_hash < "$(state_file)")" = "$original_state"
    cp "$CASE/original-notes" "$CASE/notes"
    printf '{}\n' >> "$CASE/release"
    local context_rc=0
    _rp_context "$(jq -c .plan "$(state_file)")" \
        "$(jq -c .source "$(state_file)")" 42 > "$CASE/context" 2> "$CASE/context-error" || context_rc=$?
    check test "$context_rc" -eq 2
    run --existing-only --notes-file "$CASE/notes"
    # The complete command rejects the malformed listing before context.
    check assert_rc 8
    check posts 1
    check test "$(_rp_hash < "$(state_file)")" = "$original_state"
    printf 'x' >> "$CASE/notes"
    run --dry-run --notes-file "$CASE/notes"
    check assert_rc 4
    check posts 1
}

if [[ "${1:-}" == --large-notes-only ]]; then
    test_large_notes
    printf '%s checks: %s passed, %s failed. Fixtures retained at %s\n' "$TOTAL" "$PASSED" "$FAILED" "$TMP"
    ((FAILED==0))
    exit $?
fi

test_terminal_creation
test_terminal_preparation_reads

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
test_large_notes

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

# Use an actual executable path without flock, not a replacement lock function.
portable_path="$TMP/portable-bin"
unavailable_path="$TMP/no-lock-bin"
mkdir "$portable_path" "$unavailable_path"
for tool in jq git python3 cat cp mkdir mktemp mv chmod sha256sum shasum wc sleep; do
    executable=$(type -P "$tool") || continue
    ln -s "$executable" "$portable_path/$tool"
    [[ "$tool" == python3 ]] || ln -s "$executable" "$unavailable_path/$tool"
done
new_case
PATH="$portable_path" run
check assert_rc 0
check posts 1
PATH="$portable_path" run
check assert_rc 0
check posts 1
new_case
PATH="$unavailable_path" run
check assert_rc 3
check test ! -e "$CASE/state"
check test ! -s "$CASE/calls"

# Real cross-process locks: losers may retry, but never send another POST.
# Repeat the same publication race using the macOS-compatible Python backend.
for backend_path in "$PATH" "$portable_path"; do
    new_case; touch "$CASE/post-slow"
    pids=()
    for n in 1 2 3 4; do
        (PATH="$backend_path" release_prepare --repo acme/tool --tag v1.2.3 --sha "$SHA" --state-dir "$CASE/state" > "$CASE/out.$n" 2> "$CASE/err.$n"; printf '%s\n' "$?" > "$CASE/rc.$n") &
        pids+=("$!")
    done
    for pid in "${pids[@]}"; do wait "$pid" || true; done
    check posts 1
    check test "$(grep -l '^0$' "$CASE"/rc.* | wc -l)" -ge 1
    for n in 1 2 3 4; do
        check jq -es 'length==1 and (.[0].exit_code==0 or .[0].exit_code==2)' "$CASE/out.$n"
    done
    PATH="$backend_path" run
    check assert_rc 0
    check posts 1
done
printf '%s checks: %s passed, %s failed. Fixtures retained at %s\n' "$TOTAL" "$PASSED" "$FAILED" "$TMP"
((FAILED==0))
