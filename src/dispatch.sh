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
        then {event_type:$event,client_payload:$p}
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
        --argjson code "$4" --argjson attempts "$5" --arg http "$6" \
        '{repo:$repo,event_type:$event,outcome:$outcome,exit_code:$code,
          attempts:$attempts,http_status:(if $http=="" then null else $http end)}'
}

# Validated request transport. Retry only explicit rate-limit rejections; a
# timeout, 5xx or unrecognized acknowledgement may follow a completed POST.
_dp_deliver() (
    set -o pipefail
    local repo="$1" event="$2" body="$3" work attempt=0 rc=0 http=''
    local outcome=uncertain code=8 delay retry_after remaining reset now
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
                (( attempt < ${DISPATCH_MAX_RETRIES:-3} )) || break
                delay=$(( ${DISPATCH_RETRY_DELAY:-5} * (1 << (attempt - 1)) ))
                if [[ -n "$retry_after" ]]; then
                    # Unknown/HTTP-date delays are not guessed or shortened.
                    _dp_int "$retry_after" 0 3600 || break
                    (( retry_after <= delay )) || delay="$retry_after"
                elif [[ "$remaining" == 0 ]]; then
                    reset=$(_dp_header "$work/headers" x-ratelimit-reset) || return 1
                    [[ "$reset" =~ ^[0-9]{1,10}$ ]] || break
                    now=$(date +%s) || return 1
                    reset=$((10#$reset - now + 1))
                    (( reset <= delay )) || delay="$reset"
                else
                    # GitHub advises at least one minute on secondary limits.
                    (( delay >= 60 )) || delay=60
                fi
                (( delay <= ${DISPATCH_MAX_WAIT:-120} )) || break
                sleep "$delay" || return 5
                ;;
            *) outcome=uncertain; code=8; break ;;
        esac
    done
    _dp_log_info "$repo: $outcome (HTTP ${http:-unknown}, attempts $attempt)"
    _dp_result "$repo" "$event" "$outcome" "$code" "$attempt" "$http" || return 1
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

# Resolve source identity only from explicit input. Never attribute a release
# to the caller's unrelated PWD. Dry-run can preview an unresolved SHA as null.
dispatch_release() (
    set -o pipefail
    local tool='' version='' repos='' sha='' run_id='' path='' dry="${DRY_RUN:-false}"
    local payload tag material
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --tool|-t|--version|-V|--repos|-r|--sha|--run-id|--repo-path)
                [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || return 4
                case "$1" in
                    --tool|-t) tool="$2" ;; --version|-V) version="$2" ;; --repos|-r) repos="$2" ;;
                    --sha) sha="$2" ;; --run-id) run_id="$2" ;; --repo-path) path="$2" ;;
                esac
                shift 2 ;;
            --dry-run|-n) dry=true; shift ;;
            --help|-h)
                printf '%s\n' 'USAGE: dispatch_release TOOL VERSION --sha COMMIT [--repos OWNER/REPO,...]' \
                    'Use --repo-path DIR to resolve the exact release tag; --run-id ID selects a stable invocation.'
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
    [[ -n "$repos" ]] || repos="Dicklesworthstone/$tool"
    if [[ -z "$run_id" ]]; then run_id="$tool-$tag-${sha:-unresolved}"; fi
    [[ "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9_.:-]{0,199}$ ]] || return 4
    command -v jq >/dev/null || return 3
    payload=$(jq -nc --arg tool "$tool" --arg version "$tag" --arg sha "$sha" --arg run_id "$run_id" \
        '{tool:$tool,version:$version,sha:(if $sha=="" then null else $sha end),run_id:$run_id}') || return 1
    _dp_log_info "Run ID: $run_id; $tool $tag; SHA: ${sha:-unresolved}"
    local -a args=(dsr-release --repos "$repos" --payload "$payload")
    [[ "$dry" != true ]] || args+=(--dry-run)
    dispatch_batch "${args[@]}"
)

dispatch_release_json() (
    local start=$SECONDS result='' rc=0 work
    command -v jq >/dev/null || return 3
    umask 077
    work=$(mktemp -d "${TMPDIR:-/tmp}/dsr-dispatch-json.XXXXXXXX") || return 1
    trap 'rm -rf -- "$work"' EXIT
    trap 'exit 5' HUP INT TERM
    result=$(dispatch_release "$@" 2> "$work/diagnostics") || rc=$?
    [[ -n "$result" ]] || result=null
    jq -nc --argjson details "$result" --argjson rc "$rc" --argjson duration "$((SECONDS-start))" \
        '{status:(if $rc==0 then "success" else "error" end),exit_code:$rc,details:$details,duration_seconds:$duration}' || return 1
    return "$rc"
)

export -f _dp_log_error _dp_log_info _dp_repo _dp_int _dp_body _dp_get_token
export -f _dp_config _dp_http _dp_header _dp_result _dp_deliver _dp_repos
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
