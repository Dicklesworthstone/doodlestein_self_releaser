#!/usr/bin/env bash
# Repository dispatch (bd-1jt.3.7). Acceptance means HTTP 204, NOT that a
# downstream workflow ran. A lost POST acknowledgement is never blindly replayed.

_dp_log_error() { printf '[dispatch:ERROR] %s\n' "$*" >&2; }
_dp_log_info() { printf '[dispatch] %s\n' "$*" >&2; }

_dp_repo() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$ &&
       "${1#*/}" != . && "${1#*/}" != .. ]] || return 4
    printf '%s\n' "${1,,}"
}

_dp_int() { [[ "$1" =~ ^(0|[1-9][0-9]{0,5})$ ]] && (( $1 >= $2 && $1 <= $3 )); }

_dp_body() {
    local event="$1" payload="$2"
    [[ -n "$event" && "$event" != *[[:cntrl:]]* ]] || return 4
    command -v jq >/dev/null || return 3
    jq -ecn -s --arg event "$event" --arg payload "$payload" '
        ($payload | fromjson) as $p |
        if ($event | length) <= 100 and ($p | type) == "object" and
           ($p | length) <= 10 and ($p | tojson | utf8bytelength) < 65536
        then {event_type:$event,client_payload:$p} |
            if (tojson|utf8bytelength) < 65536 then . else error("Request too large") end
        else error("Invalid dispatch event or payload") end' 2>/dev/null || {
        _dp_log_error 'Invalid JSON dispatch payload or event limits'; return 4;
    }
}

_dp_get_token() (
    set +x
    local token="${DSR_GH_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-}}}"
    if [[ -z "$token" ]] && command -v secrets_get_gh_token >/dev/null; then
        token=$(secrets_get_gh_token 2>/dev/null) || return 3
    fi
    if [[ -z "$token" ]] && command -v gh >/dev/null; then
        token=$(GH_HOST=github.com gh auth token --hostname github.com 2>/dev/null) || return 3
    fi
    [[ "$token" =~ ^[A-Za-z0-9_.-]+$ ]] || return 3
    printf '%s' "$token"
)

dispatch_check_auth() {
    _dp_get_token >/dev/null && return 0
    _dp_log_error 'GitHub authentication required (DSR_GH_TOKEN, GITHUB_TOKEN, GH_TOKEN, or gh auth)'
    return 3
}

_dp_config() {
    _dp_int "${DISPATCH_MAX_RETRIES:-3}" 1 10 &&
    _dp_int "${DISPATCH_RETRY_DELAY:-5}" 0 60 &&
    _dp_int "${DISPATCH_TIMEOUT:-30}" 1 600 &&
    _dp_int "${DISPATCH_MAX_WAIT:-120}" 0 3600 &&
    _dp_int "${DISPATCH_PARALLELISM:-4}" 1 32 || {
        _dp_log_error 'Invalid dispatch retry/timeout/concurrency configuration'; return 4;
    }
}

# One POST, no redirects, no curlrc, no implicit retries and no auth in argv.
# Result files are private to the caller. Never log the response/error body: a
# proxy may echo request credentials or a sensitive client_payload back to us.
_dp_http() (
    set +x
    local repo="$1" body="$2" dir="$3" token
    token=$(_dp_get_token) || return 3
    printf 'header = "Authorization: Bearer %s"\n' "$token" |
        curl -q --config - --silent --show-error --proto '=https' \
            --connect-timeout 10 --max-time "${DISPATCH_TIMEOUT:-30}" \
            --retry 0 --max-redirs 0 --request POST \
            --header 'Accept: application/vnd.github+json' \
            --header 'X-GitHub-Api-Version: 2022-11-28' \
            --header 'Content-Type: application/json' \
            --data-binary "@$body" --output "$dir/response" \
            --dump-header "$dir/headers" --write-out '%{http_code}' \
            "https://api.github.com/repos/$repo/dispatches" \
            > "$dir/code" 2> "$dir/transport-error"
)

_dp_header() {
    # Only the final response header block counts (ignore proxy/100 responses).
    awk -v key="$2" '
        /^HTTP\// {value=""}
        {line=$0; sub(/\r$/, "", line); p=index(line, ":")
         if (p && tolower(substr(line,1,p-1)) == key) {
             value=substr(line,p+1); sub(/^[ \t]+/, "", value); sub(/[ \t]+$/, "", value)
         }}
        END {print value}' "$1"
}

_dp_result() {
    jq -nc --arg repo "$1" --arg event "$2" --arg outcome "$3" \
        --argjson code "$4" --argjson attempts "$5" --arg http "$6" --argjson retry_at "${7:-null}" \
        '{repo:$repo,event_type:$event,outcome:$outcome,exit_code:$code,
          attempts:$attempts,http_status:(if $http=="" then null else $http end),retry_not_before:$retry_at}'
}

# Validated request transport. Retry only explicit rate-limit rejections; a
# timeout, 5xx or unrecognized acknowledgement may follow a completed POST.
_dp_deliver() (
    set -o pipefail
    local repo="$1" event="$2" body="$3" work attempt=0 rc=0 http=''
    local outcome=uncertain code=8 delay retry_after remaining reset now retry_at=null
    dispatch_check_auth || return $?
    command -v curl >/dev/null || { _dp_log_error 'curl is required'; return 3; }
    work=$(mktemp -d "${TMPDIR:-/tmp}/dsr-dispatch.XXXXXXXX") || return 1
    trap 'rm -rf -- "$work"' EXIT
    trap 'exit 5' HUP INT TERM
    printf '%s' "$body" > "$work/body" || return 1
    while (( attempt < ${DISPATCH_MAX_RETRIES:-3} )); do
        attempt=$((attempt + 1)); rc=0; http=''
        : > "$work/headers"; : > "$work/code"
        _dp_http "$repo" "$work/body" "$work" || rc=$?
        http=$(cat "$work/code")
        [[ "$http" =~ ^[0-9]{3}$ ]] || http=''
        if (( rc != 0 )); then
            if (( rc == 3 )); then outcome=rejected; code=3; else outcome=uncertain; code=8; fi
            break
        fi
        case "$http" in
            204) outcome=accepted; code=0; break ;;
            401) outcome=rejected; code=3; break ;;
            400|404|405|410|422) outcome=rejected; code=7; break ;;
            403|429)
                retry_after=$(_dp_header "$work/headers" retry-after) || return 1
                remaining=$(_dp_header "$work/headers" x-ratelimit-remaining) || return 1
                if [[ "$http" == 403 && -z "$retry_after" && "$remaining" != 0 ]]; then
                    outcome=rejected; code=3; break
                fi
                outcome=rate_limited; code=8
                delay=$(( ${DISPATCH_RETRY_DELAY:-5} * (1 << (attempt - 1)) ))
                now=$(date +%s) || return 1
                retry_at=null
                if [[ -n "$retry_after" ]]; then
                    # Unknown/HTTP-date delays are not guessed or shortened.
                    _dp_int "$retry_after" 0 999999 || break
                    (( retry_after <= delay )) || delay="$retry_after"
                elif [[ "$remaining" == 0 ]]; then
                    reset=$(_dp_header "$work/headers" x-ratelimit-reset) || return 1
                    [[ "$reset" =~ ^[0-9]{1,10}$ ]] || break
                    reset=$((10#$reset - now + 1))
                    (( reset <= delay )) || delay="$reset"
                else
                    # GitHub advises at least one minute on secondary limits.
                    (( delay >= 60 )) || delay=60
                fi
                retry_at=$((now + delay))
                (( attempt < ${DISPATCH_MAX_RETRIES:-3} )) || break
                (( delay <= ${DISPATCH_MAX_WAIT:-120} )) || break
                sleep "$delay" || return 5
                ;;
            *) outcome=uncertain; code=8; break ;;
        esac
    done
    _dp_log_info "$repo: $outcome (HTTP ${http:-unknown}, attempts $attempt)"
    [[ "$outcome" == rate_limited ]] || retry_at=null
    _dp_result "$repo" "$event" "$outcome" "$code" "$attempt" "$http" "$retry_at" || return 1
    return "$code"
)

dispatch_event() (
    umask 077
    local repo='' event='' payload='{}' dry="${DRY_RUN:-false}" body
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --payload|-p)
                [[ $# -ge 2 ]] || return 4
                payload="$2"; shift 2 ;;
            --dry-run|-n) dry=true; shift ;;
            -*) _dp_log_error "Unknown option: $1"; return 4 ;;
            *)
                if [[ -z "$repo" ]]; then repo="$1"
                elif [[ -z "$event" ]]; then event="$1"
                else return 4; fi
                shift ;;
        esac
    done
    [[ -n "$repo" ]] || { _dp_log_error 'Repository required'; return 4; }
    [[ -n "$event" ]] || { _dp_log_error 'Event type required'; return 4; }
    repo=$(_dp_repo "$repo") || { _dp_log_error 'Invalid repository'; return 4; }
    body=$(_dp_body "$event" "$payload") || return $?
    _dp_config || return $?
    if [[ "$dry" == true ]]; then
        _dp_log_info "[dry-run] $event to $repo"
        _dp_result "$repo" "$event" planned 0 0 ''
        return $?
    fi
    _dp_deliver "$repo" "$event" "$body"
)

_dp_repos() (
    set -o pipefail
    local csv="$1" repo normalized
    [[ -n "$csv" && "$csv" != ,* && "$csv" != *, && "$csv" != *,,* ]] || return 4
    local -a values=()
    IFS=',' read -r -a values <<< "$csv"
    [[ "$csv" != *[[:cntrl:]]* ]] || return 4
    for repo in "${values[@]}"; do
        normalized=$(_dp_repo "$repo") || return 4
        printf '%s\n' "$normalized"
    done | LC_ALL=C sort -u
)

dispatch_batch() (
    set -o pipefail
    umask 077
    local event='' repos='' payload='{}' dry="${DRY_RUN:-false}" parallel=false selected body repo
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --event|-e|--repos|-r|--payload|-p)
                [[ $# -ge 2 ]] || return 4
                case "$1" in --event|-e) event="$2" ;; --repos|-r) repos="$2" ;; *) payload="$2" ;; esac
                shift 2 ;;
            --parallel) parallel=true; shift ;;
            --dry-run|-n) dry=true; shift ;;
            -*) return 4 ;;
            *) [[ -z "$event" ]] || return 4; event="$1"; shift ;;
        esac
    done
    [[ -n "$event" ]] || { _dp_log_error 'Event type required'; return 4; }
    [[ -n "$repos" ]] || { _dp_log_error 'Repos required'; return 4; }
    selected=$(_dp_repos "$repos") || return $?
    body=$(_dp_body "$event" "$payload") || return $?
    _dp_config || return $?
    # Validate all targets and the request before the first external operation.
    if [[ "$dry" == true ]]; then
        _dp_log_info "[dry-run] $event to ${selected//$'\n'/,}"
        jq -nc --arg repos "$selected" --arg event "$event" \
            '{status:"planned",results:($repos|split("\n")|map({repo:.,event_type:$event,outcome:"planned",exit_code:0}))}'
        return $?
    fi
    dispatch_check_auth || return $?
    command -v curl >/dev/null || return 3
    local work i=0 index rc=0 failed=0 limit=1
    local -a pids=()
    work=$(mktemp -d "${TMPDIR:-/tmp}/dsr-dispatch-batch.XXXXXXXX") || return 1
    trap 'rm -rf -- "$work"' EXIT
    trap 'for index in "${pids[@]}"; do kill "$index" 2>/dev/null || :; done; wait; exit 5' HUP INT TERM
    [[ "$parallel" != true ]] || limit="${DISPATCH_PARALLELISM:-4}"
    while IFS= read -r repo; do
        _dp_deliver "$repo" "$event" "$body" > "$work/$i.json" &
        pids+=("$!"); i=$((i + 1))
        if (( ${#pids[@]} >= limit )); then
            for index in "${pids[@]}"; do wait "$index" || failed=$((failed + 1)); done
            pids=()
        fi
    done <<< "$selected"
    for index in "${pids[@]}"; do wait "$index" || failed=$((failed + 1)); done
    (( failed == 0 )) || rc=1
    jq -sc --argjson rc "$rc" --argjson expected "$i" '
        if length == $expected and all(.[]; type=="object" and has("outcome"))
        then {status:(if $rc==0 then "accepted" else "incomplete" end),exit_code:$rc,results:sort_by(.repo)}
        else error("Missing dispatch outcomes") end' "$work/"*.json || return 1
    return "$rc"
)

# A local delivery outbox, not an exactly-once guarantee from GitHub. The request
# digest and receiver-visible delivery_id stay fixed across every retry.
_dp_digest_text() (
    set -o pipefail
    local digest
    if command -v sha256sum >/dev/null; then
        digest=$(printf '%s' "$1" | sha256sum) || return 1
    elif command -v shasum >/dev/null; then
        digest=$(printf '%s' "$1" | shasum -a 256) || return 1
    else
        _dp_log_error 'sha256sum or shasum is required'; return 3
    fi
    digest="${digest%% *}"
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$digest"
)

_dp_state_hash() {
    local content
    [[ ! -L "$1" ]] || return 2
    if [[ ! -e "$1" ]]; then printf '%s\n' absent; return 0; fi
    [[ -f "$1" ]] || return 2
    # Retain trailing newlines in the hash, unlike shell command substitution.
    if command -v sha256sum >/dev/null; then
        content=$(sha256sum < "$1") || return 1
    elif command -v shasum >/dev/null; then
        content=$(shasum -a 256 < "$1") || return 1
    else return 3; fi
    content="${content%% *}"
    [[ "$content" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$content"
}

_dp_release_plan() (
    set -o pipefail
    local source="$1" selected="$2" payload="$3" repo id body digest material row rows=''
    while IFS= read -r repo; do
        material=$(jq -Scn --arg source "$source" --arg repo "$repo" \
            --argjson payload "$payload" '{source_repo:$source,repo:$repo,event_type:"dsr-release",payload:$payload}') || return 1
        id=$(_dp_digest_text "$material") || return $?
        material=$(jq -c --arg source "$source" --arg id "$id" \
            '.+{source_repo:$source,delivery_id:$id}' <<< "$payload") || return 1
        body=$(_dp_body dsr-release "$material") || return $?
        digest=$(_dp_digest_text "$body") || return $?
        row=$(jq -nc --arg repo "$repo" --arg id "$id" --arg body "$body" --arg hash "$digest" \
            '{repo:$repo,delivery_id:$id,body:$body,request_sha256:$hash}') || return 1
        rows+="$row"$'\n'
    done <<< "$selected"
    jq -Scs --arg source "$source" --argjson payload "$payload" \
        '{source_repo:$source,payload:$payload,requests:sort_by(.repo)}' <<< "$rows"
)

_dp_state_valid() {
    local file="$1" plan="$2"
    [[ -f "$file" && ! -L "$file" ]] || return 2
    jq -e -s --argjson plan "$plan" '
        def integer: type=="number" and .>=0 and .==floor;
        def receipt($r; $t):
            type=="object" and .repo==$r.repo and .event_type=="dsr-release" and
            (.attempts|integer and .>=1 and .<=10) and
            (.http_status==null or (.http_status|type=="string" and test("^[0-9]{3}$"))) and
            (.retry_not_before==null or (.retry_not_before|integer and .<=9999999999)) and
            (.outcome=="rate_limited" or .retry_not_before==null) and .outcome==$t.outcome and
            (if .outcome=="accepted" then .exit_code==0 and .http_status=="204"
             elif .outcome=="rejected" then
                (.exit_code==3 and (.http_status=="401" or .http_status=="403" or .http_status==null)) or
                (.exit_code==7 and (["400","404","405","410","422"]|index($t.receipt.http_status))!=null)
             elif .outcome=="rate_limited" then .exit_code==8 and (.http_status=="403" or .http_status=="429")
             elif .outcome=="uncertain" then .exit_code==8 else false end);
        length==1 and (.[0] | . as $s |
            type=="object" and .schema_version==1 and .kind=="dsr-dispatch-outbox" and .plan==$plan and
            (.deliveries|type=="array" and length==($plan.requests|length)) and
            all(.deliveries|to_entries[];
                .key as $i | .value as $d | $plan.requests[$i] as $r |
                $d.repo==$r.repo and $d.delivery_id==$r.delivery_id and
                ($d.history|type=="array") and all($d.history|to_entries[];
                    .key as $j | .value as $t |
                    ($t|type=="object") and $t.sequence==($j+1) and
                    $t.request_sha256==$r.request_sha256 and
                    ($t.resend_uncertain|type=="boolean") and
                    (if $j==0 then $t.resend_uncertain==false
                     else $d.history[$j-1] as $previous |
                        $previous.outcome!="accepted" and
                        $t.resend_uncertain==($previous.outcome=="uncertain" or $previous.outcome=="sending") end) and
                    (if $t.outcome=="sending" then $t.receipt==null
                     else ($t.receipt|receipt($r;$t)) end))))
    ' "$file" >/dev/null 2>&1
}

# The advisory lock serializes cooperating senders. The hash also rejects
# observed edits by non-cooperating writers. No promise of power-loss durability.
_dp_state_write() {
    local file="$1" next="$2" expected="$3" work="$4" plan="$5" staged current
    staged=$(mktemp "$work/state.XXXXXXXX") || return 1
    printf '%s\n' "$next" > "$staged" || return 1
    _dp_state_valid "$staged" "$plan" || return 2
    current=$(_dp_state_hash "$file") || return $?
    [[ "$current" == "$expected" ]] || { _dp_log_error 'Outbox changed during dispatch'; return 2; }
    if [[ "$expected" == absent ]]; then
        ln -- "$staged" "$file" 2>/dev/null || return 2
    else
        mv -f -- "$staged" "$file" || return 1
    fi
    _dp_state_hash "$file"
}

_dp_outbox_summary() {
    local state="$1" file="$2" rc="$3"
    jq -nc --argjson s "$state" --arg file "$file" --argjson rc "$rc" '
        {status:(if $rc==0 then "accepted" else "incomplete" end),exit_code:$rc,
         outbox_file:$file,run_id:$s.plan.payload.run_id,source_repo:$s.plan.source_repo,
         results:[$s.deliveries[] | (.history[-1] // {}) as $last |
            {repo,delivery_id,invocations:(.history|length),
             outcome:(if $last.outcome=="sending" then "uncertain" else ($last.outcome // "pending") end),
             receipt:($last.receipt // null)}]}'
}

_dp_release_outbox() (
    set -o pipefail
    umask 077
    local plan="$1" root="$2" retry_uncertain="$3" inspect="$4" identity key session file
    local work='' state next oldhash current i indices repo body receipt outcome rc=0 retry_at now result
    identity=$(jq -Sc '{source_repo,tool:.payload.tool,version:.payload.version,run_id:.payload.run_id}' <<< "$plan") || return 1
    key=$(_dp_digest_text "$identity") || return $?
    [[ -n "$root" && "$root" != *[[:cntrl:]]* && "$root" != *\\* && ! -L "$root" ]] || return 4
    if [[ "$inspect" != true ]]; then
        command -v flock >/dev/null || { _dp_log_error 'flock is required for persistent dispatch'; return 3; }
        mkdir -p -- "$root" || return 1
    fi
    [[ -d "$root" ]] || return 4
    root=$(cd "$root" && pwd -P) || return 1
    session="$root/$key"; file="$session/state.json"
    [[ ! -L "$session" ]] || return 2
    if [[ "$inspect" != true ]]; then
        mkdir -p -- "$session" || return 1
        [[ ! -L "$session/lock" && ( ! -e "$session/lock" || -f "$session/lock" ) ]] || return 2
        # A fixed descriptor is confined to this subshell. Keep it inherited by
        # transport children: killing the parent must not unlock a live POST.
        exec 9>> "$session/lock" || return 1
        flock -n 9 || { _dp_log_error "Dispatch already active: $file"; return 2; }
        work=$(mktemp -d "$session/.work.XXXXXXXX") || return 1
    fi
    trap '[[ -z "$work" ]] || rm -rf -- "$work"' EXIT
    trap 'exit 5' HUP INT TERM
    oldhash=$(_dp_state_hash "$file") || return $?
    if [[ "$oldhash" == absent ]]; then
        [[ "$inspect" != true ]] || return 4
        state=$(jq -Scn --argjson plan "$plan" \
            '{schema_version:1,kind:"dsr-dispatch-outbox",plan:$plan,
              deliveries:[$plan.requests[]|{repo,delivery_id,history:[]}] }') || return 1
        oldhash=$(_dp_state_write "$file" "$state" absent "$work" "$plan") || return $?
    else
        _dp_state_valid "$file" "$plan" || { _dp_log_error "Invalid or conflicting outbox plan: $file"; return 2; }
        state=$(cat -- "$file") || return 1
        [[ "$(_dp_state_hash "$file")" == "$oldhash" ]] || return 2
    fi
    # Whole-state validation above precedes every external side effect.
    indices=$(jq -r '.requests|keys[]' <<< "$plan") || return 1
    [[ -n "$indices" ]] || return 4
    while IFS= read -r i; do
        outcome=$(jq -r --argjson i "$i" '.deliveries[$i].history[-1].outcome // "pending"' <<< "$state") || return 1
        [[ "$outcome" != accepted ]] || continue
        [[ "$inspect" != true ]] || continue
        case "$outcome" in
            sending|uncertain)
                [[ "$retry_uncertain" == true ]] || continue ;;
            rate_limited)
                retry_at=$(jq -r --argjson i "$i" '.deliveries[$i].history[-1].receipt.retry_not_before // "unknown"' <<< "$state") || return 1
                now=$(date +%s) || return 1
                if [[ "$retry_at" == unknown ]] || (( retry_at > now )); then
                    continue
                fi ;;
        esac
        # Missing credentials/dependencies cannot create an ambiguous sending
        # record, and complete accepted retries never need credentials at all.
        dispatch_check_auth || { rc=3; break; }
        command -v curl >/dev/null || { rc=3; break; }
        repo=$(jq -r --argjson i "$i" '.plan.requests[$i].repo' <<< "$state") || return 1
        body=$(jq -r --argjson i "$i" '.plan.requests[$i].body' <<< "$state") || return 1
        next=$(jq -Sc --argjson i "$i" '
            (.deliveries[$i].history[-1].outcome // "pending") as $previous |
            .deliveries[$i].history += [{sequence:((.deliveries[$i].history|length)+1),
                request_sha256:.plan.requests[$i].request_sha256,
                resend_uncertain:($previous=="sending" or $previous=="uncertain"),outcome:"sending",receipt:null}]' <<< "$state") || return 1
        oldhash=$(_dp_state_write "$file" "$next" "$oldhash" "$work" "$plan") || return $?
        state="$next"
        # Persist intent BEFORE crossing the POST boundary. Any interruption
        # after this point leaves a sending/uncertain state, not pending work.
        result=0
        receipt=$(_dp_deliver "$repo" dsr-release "$body") || result=$?
        if ! jq -e -s --arg repo "$repo" --argjson rc "$result" '
                length==1 and (.[0]|type=="object" and .repo==$repo and .event_type=="dsr-release" and
                .exit_code==$rc and (.attempts|type=="number" and .>=1) and
                ((.outcome=="accepted" and $rc==0 and .http_status=="204") or
                 (.outcome!="accepted" and $rc!=0)))' <<< "$receipt" >/dev/null 2>&1; then
            receipt=$(_dp_result "$repo" dsr-release uncertain 8 1 '') || return 1
        fi
        next=$(jq -Sc --argjson i "$i" --argjson receipt "$receipt" \
            '.deliveries[$i].history[-1] += {outcome:$receipt.outcome,receipt:$receipt}' <<< "$state") || return 1
        oldhash=$(_dp_state_write "$file" "$next" "$oldhash" "$work" "$plan") || return $?
        state="$next"
    done <<< "$indices"
    current=$(_dp_state_hash "$file") || return $?
    [[ "$current" == "$oldhash" ]] || return 2
    _dp_state_valid "$file" "$plan" || return 2
    if (( rc == 0 )); then
        if jq -e 'any(.deliveries[]; .history[-1].outcome=="sending" or .history[-1].outcome=="uncertain")' <<< "$state" >/dev/null; then rc=8
        elif ! jq -e 'all(.deliveries[]; .history[-1].outcome=="accepted")' <<< "$state" >/dev/null; then rc=1; fi
    fi
    _dp_outbox_summary "$state" "$file" "$rc" || return 1
    return "$rc"
)

# Resolve source identity only from explicit input. Never attribute a release
# to the caller's unrelated PWD. Dry-run can preview an unresolved SHA as null.
dispatch_release() (
    set -o pipefail
    local tool='' version='' repos='' sha='' run_id='' path='' dry="${DRY_RUN:-false}"
    local payload tag material source='' state_dir='' retry_uncertain=false inspect=false selected plan
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tool|-t|--version|-V|--repos|-r|--sha|--run-id|--repo-path|--source-repo|--state-dir)
                [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || return 4
                case "$1" in
                    --tool|-t) tool="$2" ;; --version|-V) version="$2" ;; --repos|-r) repos="$2" ;;
                    --sha) sha="$2" ;; --run-id) run_id="$2" ;; --repo-path) path="$2" ;;
                    --source-repo) source="$2" ;; --state-dir) state_dir="$2" ;;
                esac
                shift 2 ;;
            --dry-run|-n) dry=true; shift ;;
            --retry-uncertain) retry_uncertain=true; shift ;;
            --status) inspect=true; shift ;;
            --help|-h)
                printf '%s\n' 'USAGE: dispatch_release TOOL VERSION --sha COMMIT [--repos OWNER/REPO,...]' \
                    'Use --repo-path DIR to resolve the exact release tag; --run-id ID selects a stable invocation.' \
                    'Options: --source-repo OWNER/REPO --state-dir DIR --status --retry-uncertain --dry-run' \
                    'Uncertain delivery is not replayed without --retry-uncertain (duplicates are possible).'
                return 0 ;;
            -*) return 4 ;;
            *)
                if [[ -z "$tool" ]]; then tool="$1"
                elif [[ -z "$version" ]]; then version="$1"
                else return 4; fi
                shift ;;
        esac
    done
    [[ -n "$tool" ]] || { _dp_log_error 'Tool name required'; return 4; }
    [[ -n "$version" ]] || { _dp_log_error 'Version required'; return 4; }
    [[ "$tool" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || return 4
    tag="v${version#v}"
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([+-][A-Za-z0-9.+-]+)?$ ]] || return 4
    if [[ -n "$path" ]]; then
        command -v git >/dev/null || return 3
        material=$(git -C "$path" rev-parse --verify "refs/tags/$tag^{commit}" 2>/dev/null) || return 4
        [[ -z "$sha" || "$sha" == "$material" ]] || return 4
        sha="$material"
    fi
    [[ -z "$sha" || "$sha" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || return 4
    [[ -n "$sha" || "$dry" == true ]] || { _dp_log_error 'Explicit --sha or --repo-path required'; return 4; }
    if [[ -z "$source" ]] && command -v act_get_repo >/dev/null; then
        source=$(act_get_repo "$tool" 2>/dev/null) || source=''
    fi
    [[ -n "$source" ]] || source="Dicklesworthstone/$tool"
    source=$(_dp_repo "$source") || return 4
    [[ -n "$repos" ]] || repos="$source"
    # Do not include the SHA or destination set in the default identity: a
    # moved tag or dropped target must conflict with the same saved release.
    if [[ -z "$run_id" ]]; then run_id="$tool-$tag"; fi
    [[ "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9_.:-]{0,199}$ ]] || return 4
    command -v jq >/dev/null || return 3
    payload=$(jq -nc --arg tool "$tool" --arg version "$tag" --arg sha "$sha" --arg run_id "$run_id" \
        '{tool:$tool,version:$version,sha:(if $sha=="" then null else $sha end),run_id:$run_id}') || return 1
    _dp_log_info "Run ID: $run_id; $tool $tag; SHA: ${sha:-unresolved}"
    if [[ "$dry" == true ]]; then
        dispatch_batch dsr-release --repos "$repos" --payload "$payload" --dry-run
        return $?
    fi
    _dp_config || return $?
    selected=$(_dp_repos "$repos") || return $?
    plan=$(_dp_release_plan "$source" "$selected" "$payload") || return $?
    [[ -n "$state_dir" ]] || state_dir="${DISPATCH_STATE_DIR:-${DSR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsr}/dispatch}"
    _dp_release_outbox "$plan" "$state_dir" "$retry_uncertain" "$inspect"
)

dispatch_release_json() (
    local start=$SECONDS result='' rc=0 work error=''
    command -v jq >/dev/null || return 3
    umask 077
    work=$(mktemp -d "${TMPDIR:-/tmp}/dsr-dispatch-json.XXXXXXXX") || return 1
    trap 'rm -rf -- "$work"' EXIT
    trap 'exit 5' HUP INT TERM
    result=$(dispatch_release "$@" 2> "$work/diagnostics") || rc=$?
    [[ -n "$result" ]] || result=null
    if ! jq -e -s 'length==1 and (.[0]==null or (.[0]|type)=="object")' <<< "$result" >/dev/null 2>&1; then
        result=null
        (( rc != 0 )) || rc=1
    fi
    if (( rc != 0 )); then
        error=$(head -c 4096 "$work/diagnostics") || return 1
        [[ -n "$error" ]] || error="Dispatch failed (exit $rc)"
    fi
    jq -nc --argjson details "$result" --argjson rc "$rc" --argjson duration "$((SECONDS-start))" \
        --arg error "$error" \
        '{status:(if $rc==0 then "success" else "error" end),exit_code:$rc,details:$details,
          error:(if $error=="" then null else $error end),duration_seconds:$duration}' || return 1
    return "$rc"
)

export -f _dp_log_error _dp_log_info _dp_repo _dp_int _dp_body _dp_get_token
export -f _dp_config _dp_http _dp_header _dp_result _dp_deliver _dp_repos
export -f _dp_digest_text _dp_state_hash _dp_release_plan _dp_state_valid _dp_state_write
export -f _dp_outbox_summary _dp_release_outbox
export -f dispatch_check_auth dispatch_event dispatch_batch dispatch_release dispatch_release_json

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -uo pipefail
    _dp_command="${1:-help}"
    [[ $# -eq 0 ]] || shift
    case "$_dp_command" in
        event) dispatch_event "$@" ;;
        batch) dispatch_batch "$@" ;;
        release) dispatch_release "$@" ;;
        json) dispatch_release_json "$@" ;;
        help|--help|-h) printf '%s\n' 'Usage: bash src/dispatch.sh event|batch|release|json [arguments]' ;;
        *) exit 4 ;;
    esac
    exit $?
fi
