#!/usr/bin/env bash
# install_source.sh - pinned, opt-in source builds for standalone installers.
# Embedded by install_gen.sh; no DSR installation is needed on the client.
# Source builds execute repository/dependency build code. They are NOT signed
# release artifacts. A missing compiler is installed only with separate
# --install-toolchain consent, inside this source attempt's private directory.
# GitHub source fetches use the same chosen account as release downloads.
# Without a selected GitHub credential, ordinary Git authentication and URL
# policy remain available for anonymous or custom-helper installations.
#
# install_source_build owner/repo ref language binary new_directory --allow-build
#   [--subdir relative/path] [--entry relative/path] [--package cargo_package]
#   [--bin name ...] [--timeout seconds] [--install-toolchain]
# Timeout applies to each fetch/compiler command, including its children.
# stdout: one receipt JSON after a successful build; stderr: progress/errors.
# Exit: 3 missing dependency, 4 invalid input, 5 timeout/interruption,
#       6 build failure, 7 distribution verification, 8 retrieval failure,
#       1 local I/O failure.

_isb_log() { printf '[source-build] %s\n' "$*" >&2; }

_isb_name() {
    [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]
}

_isb_binary_name() {
    local name="$1"
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*)
            [[ "${name,,}" != *.exe ]] || name="${name%????}"
            name+=.exe ;;
    esac
    printf '%s\n' "$name"
}

_isb_relative_path() {
    [[ "$1" == . ]] && return 0
    [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9._+/-]*$ && "$1" != */ ]] || return 1
    case "/$1/" in *'/../'*|*'/./'*|*'//'*|*'/.git/'*) return 1 ;; esac
}

# Ref names are not revspecs, refspecs, options, or shell expressions. Tags
# requested by --version are passed as refs/tags/<version>, never as HEAD.
_isb_ref() {
    [[ "$1" == HEAD || "$1" =~ ^[0-9a-fA-F]{40}$ || "$1" =~ ^[0-9a-fA-F]{64}$ ]] && return 0
    case "$1" in refs/heads/*|refs/tags/*) ;; *) return 1 ;; esac
    [[ "$1" =~ ^refs/(heads|tags)/[A-Za-z0-9_][A-Za-z0-9._+/-]*$ ]] &&
        git check-ref-format "$1" >/dev/null 2>&1
}

_isb_path_in_tree() {
    local root="$1" path="$2" part cursor="$1"
    _isb_relative_path "$path" || return 1
    [[ -d "$root" && ! -L "$root" ]] || return 1
    [[ "$path" == . ]] && return 0
    while [[ -n "$path" ]]; do
        part="${path%%/*}"
        cursor="$cursor/$part"
        [[ ! -L "$cursor" ]] || return 1
        if [[ "$path" == */* ]]; then
            [[ -d "$cursor" ]] || return 1
            path="${path#*/}"
        else
            [[ -e "$cursor" ]] || return 1
            break
        fi
    done
}

_isb_sha256() {
    local hash
    [[ -s "$1" && -f "$1" && ! -L "$1" ]] || return 1
    if command -v sha256sum >/dev/null 2>&1; then
        hash=$(sha256sum < "$1") || return 1
    elif command -v shasum >/dev/null 2>&1; then
        hash=$(shasum -a 256 < "$1") || return 1
    else
        return 3
    fi
    hash="${hash%% *}"
    [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$hash"
}

# A portable Bash watchdog, including on macOS without GNU timeout. Job
# control gives BOTH children their own process groups. Killing the group
# also stops compiler children; killing only cargo/go would orphan them.
# Each call owns a fresh log path and leaves diagnostics for the caller.
_isb_run() (
    local limit="$1" log="$2" child guard requester supervisor="$BASHPID" status=0
    shift 2
    [[ "$limit" =~ ^[1-9][0-9]{0,4}$ && ! -e "$log" && ! -L "$log" &&
       ! -e "$log.timeout" && ! -L "$log.timeout" ]] || return 4
    requester=$(ps -o ppid= -p "$supervisor") || return 3
    requester="${requester//[[:space:]]/}"
    [[ "$requester" =~ ^[1-9][0-9]*$ ]] || return 3
    set -m
    "$@" </dev/null > "$log" 2>&1 &
    child=$!
    (
        set +m
        timer=''
        _isb_timer_stop() {
            trap '' HUP INT TERM
            [[ -z "$timer" ]] || kill "$timer" 2>/dev/null || true
            [[ -z "$timer" ]] || wait "$timer" 2>/dev/null || true
            exit 0
        }
        trap _isb_timer_stop HUP INT TERM
        deadline=$((SECONDS + limit))
        # A caller killed by PID (rather than by foreground process group)
        # cannot forward signals through Bash command substitutions. Notice
        # its disappearance here instead of leaving an orphaned compiler.
        while ((SECONDS < deadline)) && kill -0 "$requester" 2>/dev/null && kill -0 "$$" 2>/dev/null; do
            sleep 1 & timer=$!
            wait "$timer" || exit 5
        done
        printf 'timeout-or-caller-exit\n' > "$log.timeout"
        kill -TERM -- "-$child" 2>/dev/null || true
        sleep 2 & timer=$!
        wait "$timer" || exit 5
        kill -KILL -- "-$child" 2>/dev/null || true
    ) &
    guard=$!
    _isb_cancel() {
        trap '' HUP INT TERM
        kill -TERM -- "-$child" "-$guard" 2>/dev/null || true
        wait "$guard" 2>/dev/null || true
        sleep 1
        kill -KILL -- "-$child" 2>/dev/null || true
        wait "$child" 2>/dev/null || true
        exit 5
    }
    trap _isb_cancel HUP INT TERM
    wait "$child" 2>/dev/null || status=$?
    # A timed-out process can exit while one of its descendants ignores TERM.
    # Always dispose of that process group before stopping the watchdog.
    kill -TERM -- "-$child" "-$guard" 2>/dev/null || true
    kill -KILL -- "-$child" 2>/dev/null || true
    wait "$guard" 2>/dev/null || true
    trap - HUP INT TERM
    if [[ -f "$log.timeout" ]]; then
        _isb_log "Command interrupted or exceeded ${limit}s; log: $log"
        return 5
    fi
    if ((status != 0)); then
        tail -n 40 "$log" >&2
        _isb_log "Command failed (exit $status); log: $log"
    fi
    return "$status"
)

_isb_git() (
    # Ambient repository plumbing must not redirect writes into a caller's
    # checkout. User credential helpers and URL policy remain available.
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
    unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
    unset GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
    export GIT_TERMINAL_PROMPT=0 GIT_NO_REPLACE_OBJECTS=1
    git -c core.hooksPath=/dev/null -c core.fsmonitor=false -c submodule.recurse=false "$@"
)

_isb_checkout() (
    set +x
    local repo="$1" ref="$2" dir="$3" token='' token_status=0 trace_name authorization
    local -a git_options=() init_options=()
    token=$(_installer_github_token) || token_status=$?
    # With no selected GitHub credential, retain the existing Git-only path:
    # anonymous HTTPS, user credential helpers and configured URL policy.
    # A malformed explicit credential must not fall through to that path.
    ((token_status == 0 || token_status == 3)) || return 8
    if [[ -n "$token" ]]; then
        # A header supplied before the first request also prevents libcurl's
        # ~/.netrc from authenticating as another account before a reactive
        # Git credential helper runs. jq is already a source-build dependency;
        # secret input reaches it only on stdin. Git reads the scoped header
        # from this process's environment, never an argv, URL or stored file.
        command -v jq >/dev/null 2>&1 || return 3
        authorization=$(printf 'x-access-token:%s' "$token" | jq -Rrs '@base64') || return 8
        export DSR_INSTALLER_GIT_AUTHORIZATION="Authorization: Basic $authorization"
        # A chosen account cannot be redirected by global/system insteadOf
        # rules, extra Authorization headers or another credential helper.
        # The fresh repository gets no ambient template/configuration either.
        export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_ALLOW_PROTOCOL=https
        unset GIT_TEMPLATE_DIR GIT_ASKPASS SSH_ASKPASS GIT_CURL_VERBOSE GIT_SSL_NO_VERIFY
        for trace_name in "${!GIT_TRACE@}"; do unset "$trace_name"; done
        # --config-env is supported by Git 2.31+. An older Git refuses this
        # command before network access rather than ignoring the credential
        # policy as an unknown -c option could.
        git_options=(-c credential.helper= -c credential.interactive=false -c core.askPass=
            -c http.extraHeader= "--config-env=http.https://github.com/$repo.git.extraHeader=DSR_INSTALLER_GIT_AUTHORIZATION"
            -c http.followRedirects=false -c http.sslVerify=true)
        init_options=(--template=)
    fi
    _isb_git ${git_options[@]+"${git_options[@]}"} init -q ${init_options[@]+"${init_options[@]}"} "$dir" || return 8
    _isb_git ${git_options[@]+"${git_options[@]}"} -C "$dir" remote add origin "https://github.com/$repo.git" || return 8
    _isb_git ${git_options[@]+"${git_options[@]}"} -C "$dir" fetch -q --depth=1 --no-tags --recurse-submodules=no origin "$ref" || return 8
    local commit
    commit=$(_isb_git ${git_options[@]+"${git_options[@]}"} -C "$dir" rev-parse --verify 'FETCH_HEAD^{commit}') || return 8
    [[ "$commit" =~ ^[0-9a-f]{40}$ || "$commit" =~ ^[0-9a-f]{64}$ ]] || return 8
    if [[ "$ref" =~ ^[0-9a-fA-F]{40}$ || "$ref" =~ ^[0-9a-fA-F]{64}$ ]]; then
        [[ "$commit" == "${ref,,}" ]] || return 8
    fi
    _isb_git ${git_options[@]+"${git_options[@]}"} -C "$dir" -c advice.detachedHead=false checkout -q --detach "$commit" || return 8
)

_isb_in_dir() ( cd "$1" && shift && "$@" )

# Shared by Git source checkout, release acquisition and freshness in generated
# installers, and usable when this source module is loaded alone. Match DSR's token order;
# gh otherwise prefers GH_TOKEN and may inherit an unrelated enterprise host.
# Resolve only one account. An invalid explicit token must not try a stored
# login. Keep credentials and tracing changes confined to this child process.
_installer_github_token() (
    set +x
    local token=''
    if [[ -n "${DSR_GH_TOKEN:-}" ]]; then
        token="$DSR_GH_TOKEN"
    elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
        token="$GITHUB_TOKEN"
    elif [[ -n "${GH_TOKEN:-}" ]]; then
        token="$GH_TOKEN"
    else
        command -v gh >/dev/null 2>&1 || return 3
        token=$(GH_HOST=github.com gh auth token --hostname github.com 2>/dev/null) || return 3
    fi
    [[ -n "$token" ]] || return 3
    [[ "$token" != *$'\r'* && "$token" != *$'\n'* ]] || return 4
    printf '%s\n' "$token"
)

_installer_run_gh() (
    set +x
    command -v gh >/dev/null 2>&1 || return 3
    local token
    token=$(_installer_github_token) || return $?
    GH_HOST=github.com GH_TOKEN="$token" gh "$@"
)

# Freshness is advisory release metadata, NOT artifact or commit-signature
# verification. Query only GitHub's API and do not inherit a GH_HOST override.
# Separate API bytes from diagnostic logs so warnings cannot become JSON.
_isb_freshness_request() (
    set +x
    local transport="$1" endpoint="$2" destination="$3"
    if [[ "$transport" == gh ]]; then
        _installer_run_gh api --hostname github.com --method GET \
            -H 'Accept: application/vnd.github+json' -H 'Cache-Control: no-cache' \
            "$endpoint" > "$destination"
    elif ! command -v gh >/dev/null 2>&1 &&
         [[ -n "${DSR_GH_TOKEN:-}" || -n "${GITHUB_TOKEN:-}" || -n "${GH_TOKEN:-}" ]]; then
        # Match token-only release acquisition without adding a gh dependency.
        # Keep credentials off argv and disk, ignore ambient curl options, and
        # never follow metadata redirects. These endpoints are assembled only
        # from the admitted repository/tag and the resolved immutable commits.
        local token escaped_token bytes status maximum=8388608
        token=$(_installer_github_token) || return $?
        [[ ${#token} -le 8192 && "$token" != *[[:cntrl:]]* ]] || return 4
        escaped_token="${token//\\/\\\\}"; escaped_token="${escaped_token//\"/\\\"}"
        set -o pipefail
        if ! printf 'header = "Authorization: Bearer %s"\n' "$escaped_token" |
            curl -q --config - --silent --globoff --proto '=https' \
                --connect-timeout 10 --max-time 30 --max-filesize "$maximum" \
                -H 'Accept: application/vnd.github+json' -H 'Cache-Control: no-cache' \
                -H 'X-GitHub-Api-Version: 2022-11-28' \
                "https://api.github.com/$endpoint" --output /dev/fd/3 \
                --write-out '%{http_code}' 3>&1 > "$destination.http" 2>/dev/null |
            head -c "$((maximum + 1))" > "$destination"; then
            return 8
        fi
        bytes=$(wc -c < "$destination" | tr -d '[:space:]') || return 1
        status=$(cat -- "$destination.http") || return 1
        [[ "$status" == 200 && "$bytes" =~ ^[0-9]+$ ]] && ((bytes <= maximum)) || return 8
    else
        curl -sSf --proto '=https' --connect-timeout 10 --max-time 30 \
            -H 'Accept: application/vnd.github+json' -H 'Cache-Control: no-cache' \
            "https://api.github.com/$endpoint" -o "$destination"
    fi
)

_isb_freshness_get() {
    local endpoint="$1" destination="$2" prefer="$3" transport status
    local transports=(curl gh)
    [[ "$prefer" != true ]] || transports=(gh curl)
    for transport in "${transports[@]}"; do
        command -v "$transport" >/dev/null 2>&1 || continue
        status=0
        _isb_run 35 "$destination.$transport.log" _isb_freshness_request \
            "$transport" "$endpoint" "$destination" 2>/dev/null || status=$?
        if ((status == 0)) && [[ -f "$destination" && ! -L "$destination" ]] &&
           jq -es 'length == 1' "$destination" >/dev/null 2>&1; then
            return 0
        fi
        # An actual cancellation is not an unavailable API. Watchdog timeouts
        # do count as unavailable; their marker distinguishes the two cases.
        if ((status == 5)) && [[ ! -e "$destination.$transport.log.timeout" ]]; then
            return 5
        fi
    done
    return 8
}

# Print one decision about the latest release's distance from the default
# branch. Resolve tag and head to immutable commits BEFORE comparing, and use
# ahead_by/total_commits, never the length/last entry of a paginated commit list.
# API docs: https://docs.github.com/en/rest/commits/commits#compare-two-commits
# Usage: install_source_freshness owner/repo tag threshold new_dir [--prefer-gh]
# Stale means strictly MORE than threshold commits behind an ancestral head.
# Unavailable, malformed or divergent history is "unknown", never permission
# to compile. This helper does not fetch Git objects or execute repository code.
install_source_freshness() (
    local repo="${1:-}" tag="${2:-}" threshold="${3:-}" directory="${4:-}" prefer=false
    [[ $# -eq 4 || ( $# -eq 5 && "$5" == --prefer-gh ) ]] || return 4
    [[ $# -ne 5 ]] || prefer=true
    [[ "$repo" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ &&
       "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ && "$tag" != null &&
       "$threshold" =~ ^(0|[1-9][0-9]{0,5})$ ]] || return 4
    command -v jq >/dev/null 2>&1 || return 3
    _isb_freshness_unknown() {
        jq -nc --arg repo "$repo" --arg tag "$tag" --argjson threshold "$threshold" --arg reason "$1" \
            '{status:"unknown", repository:$repo, release_version:$tag, threshold:$threshold, reason:$reason}'
    }
    command -v ps >/dev/null 2>&1 || { _isb_freshness_unknown 'process watchdog unavailable'; return; }
    [[ -n "$directory" && ! -e "$directory" && ! -L "$directory" && "$directory" != */ ]] || return 4
    local parent name status=0 head base encoded_tag decision
    parent=$(dirname "$directory"); name=$(basename "$directory")
    _isb_name "$name" && [[ -d "$parent" && ! -L "$parent" ]] || return 4
    parent=$(cd "$parent" && pwd -P) || return 4
    directory="$parent/$name"
    umask 077
    mkdir "$directory" || return 1
    trap 'exit 5' HUP INT TERM
    # Omitted sha on list-commits means the repository's default branch, not
    # a hard-coded branch name or the default branch of a different repo.
    _isb_freshness_get "repos/$repo/commits?per_page=1" "$directory/head.json" "$prefer" || status=$?
    [[ "$status" != 5 ]] || return 5
    if ((status != 0)) || ! head=$(jq -er -s '
        if length == 1 and (.[0] | type == "array" and length == 1)
        then .[0][0].sha | select(type == "string" and (length == 40 or length == 64)
            and (test("[^0-9a-f]") | not))
        else empty end' "$directory/head.json" 2>/dev/null); then
        _isb_freshness_unknown 'default branch revision unavailable'; return
    fi
    # tags/ disambiguates a same-named branch; Get a commit peels annotated tags.
    encoded_tag=$(jq -nr --arg tag "tags/$tag" '$tag | @uri') || return 1
    status=0
    _isb_freshness_get "repos/$repo/commits/$encoded_tag" "$directory/base.json" "$prefer" || status=$?
    [[ "$status" != 5 ]] || return 5
    if ((status != 0)) || ! base=$(jq -er -s '
        if length == 1 then .[0].sha | select(type == "string" and (length == 40 or length == 64)
            and (test("[^0-9a-f]") | not))
        else empty end' "$directory/base.json" 2>/dev/null); then
        _isb_freshness_unknown 'release tag revision unavailable'; return
    fi
    status=0
    _isb_freshness_get "repos/$repo/compare/$base...$head?per_page=1" "$directory/compare.json" "$prefer" || status=$?
    [[ "$status" != 5 ]] || return 5
    if ((status != 0)); then
        _isb_freshness_unknown 'commit comparison unavailable'; return
    fi
    if ! decision=$(jq -ce -s --arg repo "$repo" --arg tag "$tag" --arg base "$base" --arg head "$head" \
        --argjson threshold "$threshold" '
        def count: type == "number" and floor == . and . >= 0 and . <= 1000000000;
        if length != 1 then error("multiple comparisons") else .[0] end |
        if type != "object" or .base_commit.sha != $base or
           (.ahead_by | count | not) or (.behind_by | count | not) or
           (.total_commits | count | not) or .total_commits != .ahead_by or
           .behind_by != 0 or .merge_base_commit.sha != $base or
           (if $head == $base then .status != "identical" or .ahead_by != 0
            else .status != "ahead" or .ahead_by <= 0 end)
        then error("incomplete, inconsistent or non-ancestral comparison")
        else {status:(if .ahead_by > $threshold then "stale" else "fresh" end),
              repository:$repo, release_version:$tag, release_commit:$base,
              head_commit:$head, commits_behind:.ahead_by, threshold:$threshold}
        end' "$directory/compare.json" 2>/dev/null); then
        _isb_freshness_unknown 'comparison is invalid or history is not ancestral'; return
    fi
    printf '%s\n' "$decision"
)

# A rustup proxy can exist without its selected compiler. Probe that compiler
# without granting rustup permission to install into the user's existing home.
_isb_probe_rust() (
    export RUSTUP_AUTO_INSTALL=0
    cd "$1" || return 4
    rustc -vV && cargo --version
)

# Inspect the installed Go compiler without letting Go download another one,
# adopt an ambient workspace, or consult a user-written Go environment file.
_isb_probe_go() (
    export GOENV=off GOWORK=off GOTOOLCHAIN=local GOFLAGS='' GO111MODULE=on GOTELEMETRY=off
    cd "$1" || return 4
    go version
)

# Activate an explicitly requested bootstrap when a compiler is unavailable,
# or when an installed Go compiler is older than the pinned source requires.
# This runs inside _isb_compile's subshell, so PATH and language homes never
# escape the source attempt or replace the caller's installed toolchain.
_isb_prepare_toolchain() {
    local language="$1" tree="$2" output="$3" limit="$4" command root bin source_dir status=0
    local go_requirements="${5:-}" installed=false required observed version
    local -a bootstrap_options=(--allow-install)
    [[ -z "$go_requirements" || "$language" == go ]] || return 4
    [[ -z "$go_requirements" ]] || bootstrap_options+=(--go-requirements "$go_requirements")
    case "$language" in rust) command=cargo ;; go) command=go ;; *) command=bun ;; esac
    if command -v "$command" >/dev/null 2>&1 &&
       { [[ "$language" != rust ]] || command -v rustc >/dev/null 2>&1; }; then
        installed=true
        if [[ "${_ISB_INSTALL_TOOLCHAIN:-false}" != true ||
              ( "$language" != rust && "$language" != go ) ]]; then
            return 0
        fi
        if [[ "$language" == rust ]]; then
            # An unavailable rustup-selected compiler is a missing toolchain;
            # bootstrap privately instead of changing that rustup home.
            _isb_run "$limit" "$output/toolchain-probe.log" _isb_probe_rust "$tree" || status=$?
            ((status != 0)) || return 0
            ((status != 5 && status < 128)) || return 5
            _isb_log 'The existing Rust commands do not provide the selected compiler; preparing an isolated toolchain'
        fi
    fi
    if [[ "${_ISB_INSTALL_TOOLCHAIN:-false}" != true ]]; then
        _isb_log "Missing $command; --install-toolchain permits an isolated compiler for this build"
        return 3
    fi
    if ! declare -F toolchain_bootstrap >/dev/null 2>&1 ||
       { [[ "$language" == go ]] && ! declare -F _tc_go_required_version >/dev/null 2>&1; }; then
        source_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || return 3
        [[ -f "$source_dir/toolchain_detect.sh" && ! -L "$source_dir/toolchain_detect.sh" ]] || return 3
        # shellcheck source=SCRIPTDIR/toolchain_detect.sh
        source "$source_dir/toolchain_detect.sh" || return 3
    fi
    if $installed && [[ "$language" == go ]]; then
        # The same committed requirement selects both admission and bootstrap.
        # A toolchain preference is a minimum for an existing installation;
        # preserve a newer compiler rather than downloading a downgrade.
        required=$(_tc_go_required_version "${go_requirements:-$tree/go.mod}") || return $?
        _isb_run "$limit" "$output/toolchain-probe.log" _isb_probe_go "$tree" || status=$?
        ((status != 5 && status < 128)) || return 5
        if ((status == 0)); then
            observed=$(cat "$output/toolchain-probe.log") || return 1
            # Before Go 1.21 initial releases omitted the patch component.
            # A modern two-component version identifies an unreleased compiler.
            if [[ "$observed" =~ ^go\ version\ go([1-9][0-9]*\.[0-9]+\.[0-9]+|1\.([0-9]|1[0-9]|20))\ [a-z0-9]+/[a-z0-9]+$ ]]; then
                version="${BASH_REMATCH[1]}"
                required="${required#go}"
                [[ "$version" == *.*.* ]] || version+=.0
                [[ "$required" == *.*.* ]] || required+=.0
                if _tc_version_ge "$version" "$required"; then
                    return 0
                fi
                _isb_log "Installed Go $version is older than the pinned requirement $required; preparing an isolated toolchain"
            else
                _isb_log 'The existing Go command did not identify a released compiler; preparing an isolated toolchain'
            fi
        else
            _isb_log 'The existing Go command is unavailable; preparing an isolated toolchain'
        fi
    fi
    root="$output/toolchain"
    _isb_log "Preparing a private $language toolchain; existing installations and profiles are preserved"
    _isb_run "$limit" "$output/toolchain.log" toolchain_bootstrap \
        "$language" "$tree" "$root" "${bootstrap_options[@]}" || return $?
    [[ "$language" != typescript ]] || language=bun
    case "$language" in rust) bin="$root/cargo/bin" ;; go) bin="$root/go/bin" ;; bun) bin="$root/bun/bin" ;; esac
    [[ -f "$root/receipt.json" && ! -L "$root/receipt.json" && -d "$bin" && ! -L "$bin" ]] || return 7
    jq -es --arg root "$root" --arg bin "$bin" --arg language "$language" '
        length == 1 and (.[0] | .schema_version == 1 and .method == "isolated-bootstrap" and
        .root == $root and .bin_dir == $bin and .language == $language and
        (.version | type == "string" and length > 0) and
        (.distribution_url | type == "string" and startswith("https://")) and
        (.distribution_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
        ((.rustup_toolchain // "") == "" or .rustup_toolchain == "stable"))
    ' "$root/receipt.json" >/dev/null || return 7
    export PATH="$bin:$PATH"
    hash -r
    case "$language" in
        rust)
            export CARGO_HOME="$root/cargo" RUSTUP_HOME="$root/rustup" RUSTUP_AUTO_INSTALL=0
            unset RUSTUP_TOOLCHAIN
            if [[ "$(jq -r '.rustup_toolchain // ""' "$root/receipt.json")" == stable ]]; then
                export RUSTUP_TOOLCHAIN=stable
            fi
            ;;
        go)
            export GOROOT="$root/go" GOPATH="$root/go-work" GOCACHE="$root/go-cache"
            ;;
        bun)
            export BUN_INSTALL="$root/bun" BUN_INSTALL_CACHE_DIR="$root/bun/cache"
            ;;
    esac
}

# Resolve every Go/Bun entry before a compiler or dependency install can run.
# An explicit entry selects only the primary. Companions must have their own
# conventional Go command directory or package.json bin declaration; a missing
# companion must never fall back to building the primary a second time.
_isb_source_entries() (
    local language="$1" tree="$2" binary="$3" entry="$4"
    shift 4
    local name source_name selected primary windows=false
    local -a entries=()
    case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) windows=true ;; esac
    binary=$(_isb_binary_name "$binary") || return 4
    for name in "$@"; do
        name=$(_isb_binary_name "$name") || return 4
        primary=false
        if [[ "$name" == "$binary" ]] || { $windows && [[ "${name,,}" == "${binary,,}" ]]; }; then
            primary=true
        fi
        source_name="$name"
        $windows && source_name="${source_name%.exe}"
        selected=''
        $primary && selected="$entry"
        if [[ -z "$selected" ]]; then
            case "$language" in
                go)
                    selected="cmd/$source_name"
                    if $primary && [[ ! -e "$tree/$selected" && ! -L "$tree/$selected" ]]; then
                        selected=.
                    fi
                    ;;
                bun|typescript)
                    selected=$(jq -er --arg binary "$source_name" --argjson primary "$primary" '
                        .bin | if type == "object" then .[$binary]
                        elif type == "string" and $primary then . else empty end |
                        select(type == "string" and length > 0)
                    ' "$tree/package.json") || {
                        _isb_log "Bun source entry is missing for $name; declare package.json bin.$source_name"
                        return 4
                    }
                    selected="${selected#./}"
                    ;;
                *) return 4 ;;
            esac
        fi
        if ! _isb_path_in_tree "$tree" "$selected"; then
            _isb_log "Missing or unsafe source entry for $name: $selected"
            return 4
        fi
        case "$language" in
            go) [[ -d "$tree/$selected" ]] || {
                _isb_log "Go source entry for $name must be a package directory: $selected"; return 4;
            } ;;
            *) [[ -f "$tree/$selected" ]] || {
                _isb_log "Bun source entry for $name must be a regular file: $selected"; return 4;
            } ;;
        esac
        entries+=("$selected")
    done
    printf '%s\n' "${entries[@]}"
)

# Resolve Go's relative use/replace directories without letting a lexical '..'
# cross the fetched checkout, or a symlink change what that boundary means.
# In particular, checking only realpath's final answer would admit a linked
# ancestor that happened to return to the checkout later in the path.
_isb_go_directory() (
    local root="$1" base="$2" reference="$3" cursor="$1" path part
    [[ -d "$root" && ! -L "$root" && "$root" == /* &&
       ( "$base" == "$root" || "$base" == "$root/"* ) &&
       -n "$reference" && "$reference" != /* && "$reference" != *\\* &&
       "$reference" != *:* && "$reference" != *[[:cntrl:]]* ]] || return 4
    path="${base#"$root"}"
    path="${path#/}"
    for path in "$path" "$reference"; do
        while [[ -n "$path" ]]; do
            part="${path%%/*}"
            if [[ "$path" == */* ]]; then path="${path#*/}"; else path=''; fi
            case "$part" in
                ''|.) continue ;;
                ..) [[ "$cursor" != "$root" ]] || return 4; cursor="${cursor%/*}" ;;
                *)
                    [[ "${part,,}" != .git ]] || return 4
                    cursor="$cursor/$part"
                    [[ -d "$cursor" && ! -L "$cursor" ]] || return 4
                    ;;
            esac
        done
    done
    printf '%s\n' "$cursor"
)

# Go's own parser supplies syntax and module identity. Git supplies authority:
# a go.work, go.mod, checksum file or vendor manifest must be an unchanged
# regular blob from the fetched commit, never an ambient or generated input.
_isb_go_committed_file() {
    local root="$1" path="$2" relative row mode type oid rest actual hash attributes filter
    [[ "$path" == "$root/"* && -f "$path" && ! -L "$path" ]] || return 4
    relative="${path#"$root"/}"
    row=$(_isb_git --literal-pathspecs -C "$root" ls-tree HEAD -- "$relative") || return 4
    [[ -n "$row" && "$row" != *$'\n'* ]] || return 4
    IFS=$' \t' read -r mode type oid rest <<< "$row"
    [[ "$type" == blob && ( "$mode" == 100644 || "$mode" == 100755 ) &&
       ( "$oid" =~ ^[0-9a-f]{40}$ || "$oid" =~ ^[0-9a-f]{64}$ ) ]] || return 4
    actual=$(_isb_git -C "$root" hash-object --no-filters -- "$path") || return 4
    if [[ "$actual" != "$oid" ]]; then
        # A normal checkout can apply core.autocrlf or tracked text/eol
        # attributes. Let Git perform that normalization, but disable the
        # selected external filter driver before hashing: metadata admission
        # must not execute a clean/process hook. The receipt still hashes the
        # actual checkout bytes that Go parses, including their line endings.
        attributes=$(_isb_git --literal-pathspecs -C "$root" check-attr filter -- "$relative") || return 4
        [[ "$attributes" != *$'\n'* && "$attributes" == *': filter: '* ]] || return 4
        filter="${attributes#*: filter: }"
        [[ "$filter" =~ ^[A-Za-z0-9_/-][A-Za-z0-9._/-]*$ ]] || return 4
        actual=$(_isb_git -c "filter.$filter.clean=" -c "filter.$filter.process=" \
            -c "filter.$filter.required=false" -C "$root" hash-object --path="$relative" -- "$path") || return 4
    fi
    [[ "$actual" == "$oid" ]] || return 4
    # Empty committed go.sum files are valid; payload hashing intentionally
    # requires nonempty executables, so use the metadata boundary here.
    if command -v sha256sum >/dev/null 2>&1; then hash=$(sha256sum < "$path") || return 1
    elif command -v shasum >/dev/null 2>&1; then hash=$(shasum -a 256 < "$path") || return 1
    else return 3; fi
    hash="${hash%% *}"
    [[ "$hash" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$hash"
}

# Compiler-independent selection is shared with isolated bootstrap: a fresh
# machine must choose its compiler from the same committed workfile that the
# eventual Go invocation will use. Never inspect an ambient parent workspace.
# Go itself still parses the complete file after a compiler is available.
_isb_go_requirements() (
    local root="$1" tree="$2" cursor="$2" relative selected=''
    relative="${tree#"$root"/}"; [[ "$tree" != "$root" ]] || relative=.
    _isb_go_directory "$root" "$root" "$relative" >/dev/null 2>&1 || {
        _isb_log 'Go build directory escapes the fetched checkout'; return 4;
    }
    while :; do
        if [[ -e "$cursor/go.work" || -L "$cursor/go.work" ]]; then
            selected="$cursor/go.work"
            break
        fi
        [[ "$cursor" != "$root" ]] || break
        cursor="${cursor%/*}"
    done
    [[ -n "$selected" ]] || selected="$tree/go.mod"
    _isb_go_committed_file "$root" "$selected" >/dev/null || {
        _isb_log "The selected ${selected##*/} must be an unchanged committed regular file"; return 4;
    }
    printf '%s\n' "$selected"
)

# Select one committed workspace, or the existing standalone module. Only
# main modules contribute replacement rules: Go ignores replace directives in
# dependency modules, including modules selected by a local replacement.
_isb_go_context() (
    set -o pipefail
    local root="$1" tree="$2" output="$3" limit="$4" requirements work='' work_dir=''
    local work_hash='' parsed paths module_root relative module_path module_hash sum_file status=0
    local index=0 document scope row old version replacement replacement_version key identity hash
    local replacement_module replacement_relative vendor=false vendor_hash='' mod=readonly
    local -a module_roots=() documents=() scopes=()
    local -A seen_paths=() seen_modules=() workspace_replaces=() replacements=()
    export GOENV=off GOFLAGS='' GOWORK=off GOTOOLCHAIN=local GO111MODULE=on GOTELEMETRY=off
    requirements=$(_isb_go_requirements "$root" "$tree") || return $?
    if [[ "${requirements##*/}" == go.work ]]; then
        work="$requirements"; work_dir="${work%/*}"
        work_hash=$(_isb_go_committed_file "$root" "$work") || return 4
        _isb_run "$limit" "$output/go-workspace.log" go work edit -json "$work" || {
            status=$?; [[ "$status" != 5 ]] || return 5; return 4;
        }
        if ! jq -es 'length == 1 and (.[0] | type == "object" and
            (.Use | type == "array" and length > 0 and all(.[];
                type == "object" and (.DiskPath | type == "string" and length > 0 and
                (test("[[:cntrl:]]") | not)))))' "$output/go-workspace.log" >/dev/null; then
            _isb_log 'Go workspace must select at least one literal module directory'; return 4
        fi
        paths=$(jq -r '.Use[].DiskPath' "$output/go-workspace.log") || return 4
        while IFS= read -r relative; do
            module_root=$(_isb_go_directory "$root" "$work_dir" "$relative") || {
                _isb_log "Go workspace module escapes the checkout or traverses a link: $relative"; return 4;
            }
            module_roots+=("$module_root")
        done <<< "$paths"
        documents+=("$output/go-workspace.log"); scopes+=("$work_dir")
    fi
    if [[ -z "$work" ]]; then
        module_roots=("$tree")
        work_dir="$tree"
    elif [[ -e "$work.sum" || -L "$work.sum" ]]; then
        _isb_go_committed_file "$root" "$work.sum" >/dev/null || {
            _isb_log 'go.work.sum must be an unchanged committed regular file'; return 4;
        }
    fi
    : > "$output/go-modules.jsonl" || return 1
    : > "$output/go-replacements.jsonl" || return 1
    for module_root in "${module_roots[@]}"; do
        relative="${module_root#"$root"/}"; [[ "$module_root" != "$root" ]] || relative=.
        [[ -z "${seen_paths[$relative]:-}" ]] || { _isb_log 'Go workspace repeats a module directory'; return 4; }
        seen_paths[$relative]=1
        module_hash=$(_isb_go_committed_file "$root" "$module_root/go.mod") || {
            _isb_log "Go module requires an unchanged committed regular go.mod: $relative"; return 4;
        }
        sum_file="$module_root/go.sum"
        if [[ -e "$sum_file" || -L "$sum_file" ]]; then
            _isb_go_committed_file "$root" "$sum_file" >/dev/null || {
                _isb_log "Go module checksum file is not an unchanged committed regular file: $relative"; return 4;
            }
        fi
        parsed="$output/go-module-$index.log"; index=$((index + 1))
        _isb_run "$limit" "$parsed" go mod edit -json "$module_root/go.mod" || {
            status=$?; [[ "$status" != 5 ]] || return 5; return 4;
        }
        module_path=$(jq -ers 'if length == 1 then .[0].Module.Path |
            select(type == "string" and length > 0 and (test("[[:cntrl:]]") | not))
            else empty end' "$parsed") || { _isb_log "Invalid Go module identity: $relative"; return 4; }
        [[ -z "${seen_modules[$module_path]:-}" ]] || { _isb_log "Go workspace repeats module identity: $module_path"; return 4; }
        seen_modules[$module_path]=1
        jq -nc --arg path "$relative" --arg module "$module_path" --arg hash "$module_hash" \
            '{path:$path,module_path:$module,go_mod_sha256:$hash}' >> "$output/go-modules.jsonl" || return 1
        documents+=("$parsed"); scopes+=("$module_root")
    done
    if [[ -e "$work_dir/vendor" || -L "$work_dir/vendor" ]]; then
        _isb_go_directory "$root" "$work_dir" vendor >/dev/null || {
            _isb_log 'Selected Go vendor directory must stay inside the checkout without links'; return 4;
        }
        document="$work_dir/vendor/modules.txt"
        [[ ! -L "$document" && ( ! -e "$document" || -f "$document" ) ]] || return 4
        if [[ -z "$work" ]]; then
            # Preserve standalone module vendoring, including legacy vendor
            # directories without a modules.txt when Go itself admits them.
            [[ ! -e "$document" ]] || _isb_go_committed_file "$root" "$document" >/dev/null || return 4
            vendor=true; mod=vendor
        elif [[ -f "$document" ]] && head -c 512 "$document" | jq -eRs '
            split("\n")[0] | if startswith("## ") then .[3:] | split(";") |
            any(.[]; gsub("^[[:space:]]+|[[:space:]]+$"; "") == "workspace")
            else false end' >/dev/null; then
            # Go ignores a member module's vendor tree and a legacy module
            # vendor at the workspace root. Match its workspace annotation
            # before choosing vendor mode, rather than forcing an invalid one.
            vendor_hash=$(_isb_go_committed_file "$root" "$document") || return 4
            vendor=true; mod=vendor
        fi
    fi
    # Explicit vendor mode reads the committed vendor tree, not the original
    # directories named by replace rules. Those originals need not exist in a
    # self-contained clone. Go still checks vendor consistency before building;
    # the caller rechecks all tracked source bytes after the complete family.
    if [[ "$mod" != vendor ]]; then
    for index in "${!documents[@]}"; do
        document="${documents[$index]}"; scope="${scopes[$index]}"
        if ! jq -es 'length == 1 and (.[0] | (.Replace // []) | type == "array" and all(.[];
            (.Old.Path | type == "string" and length > 0 and (test("[[:cntrl:]]") | not)) and
            ((.Old.Version // "") | type == "string" and (test("[[:cntrl:]]") | not)) and
            (.New.Path | type == "string" and length > 0 and (test("[[:cntrl:]]") | not)) and
            ((.New.Version // "") | type == "string" and (test("[[:cntrl:]]") | not))))' "$document" >/dev/null; then
            _isb_log 'Invalid Go replacement selection'; return 4
        fi
        paths=$(jq -c '(.Replace // [])[]' "$document") || return 4
        while IFS= read -r row; do
            [[ -n "$row" ]] || continue
            old=$(jq -r '.Old.Path' <<< "$row") || return 4
            version=$(jq -r '.Old.Version // ""' <<< "$row") || return 4
            replacement=$(jq -r '.New.Path' <<< "$row") || return 4
            replacement_version=$(jq -r '.New.Version // ""' <<< "$row") || return 4
            key="$old@$version"
            if [[ -n "$work" && "$document" == "$output/go-workspace.log" ]]; then
                [[ -z "${workspace_replaces[$key]:-}" ]] || { _isb_log 'Repeated Go workspace replacement'; return 4; }
                workspace_replaces[$key]=1
            elif [[ -n "${workspace_replaces[$old@]:-}" || -n "${workspace_replaces[$key]:-}" ]]; then
                continue
            fi
            # An exact workspace override does not erase a module wildcard:
            # other dependency versions could still select that directory.
            # Keep it confined even when the current graph might not use it;
            # admission does not resolve an external graph to prove absence.
            if [[ -n "$replacement_version" ]]; then
                identity="module:$replacement@$replacement_version"
            else
                replacement=$(_isb_go_directory "$root" "$scope" "$replacement") || {
                    _isb_log "Local Go replacement escapes the checkout or traverses a link: $old"; return 4;
                }
                identity="directory:$replacement"
            fi
            if [[ -n "${replacements[$key]:-}" ]]; then
                [[ "${replacements[$key]}" == "$identity" ]] || { _isb_log "Conflicting Go replacement: $old"; return 4; }
                continue
            fi
            replacements[$key]="$identity"
            [[ -z "$replacement_version" ]] || continue
            hash=$(_isb_go_committed_file "$root" "$replacement/go.mod") || {
                _isb_log "Local Go replacement requires a committed regular go.mod: $old"; return 4;
            }
            if [[ -e "$replacement/go.sum" || -L "$replacement/go.sum" ]]; then
                _isb_go_committed_file "$root" "$replacement/go.sum" >/dev/null || return 4
            fi
            parsed="$output/go-replacement-${#replacements[@]}.log"
            _isb_run "$limit" "$parsed" go mod edit -json "$replacement/go.mod" || {
                status=$?; [[ "$status" != 5 ]] || return 5; return 4;
            }
            replacement_module=$(jq -ers 'if length == 1 then .[0].Module.Path |
                select(type == "string" and length > 0 and (test("[[:cntrl:]]") | not))
                else empty end' "$parsed") || return 4
            replacement_relative="${replacement#"$root"/}"; [[ "$replacement" != "$root" ]] || replacement_relative=.
            jq -nc --arg module "$old" --arg version "$version" --arg path "$replacement_relative" \
                --arg replacement "$replacement_module" --arg hash "$hash" \
                '{module_path:$module,version:$version,path:$path,replacement_module_path:$replacement,go_mod_sha256:$hash}' \
                >> "$output/go-replacements.jsonl" || return 1
        done <<< "$paths"
    done
    fi
    relative="${work#"$root"/}"
    jq -nc --arg work "${work:-off}" --arg path "$relative" --arg hash "$work_hash" --arg mod "$mod" \
        --argjson vendor "$vendor" --arg vendor_hash "$vendor_hash" --slurpfile modules "$output/go-modules.jsonl" \
        --slurpfile replacements "$output/go-replacements.jsonl" \
        '{gowork:$work,mod:$mod,go_workspace:(if $work == "off" then null else
          {path:$path,sha256:$hash,modules:$modules,local_replacements:$replacements,vendor:$vendor} +
          (if $vendor then {vendor_modules_sha256:$vendor_hash} else {} end) end)}' \
        > "$output/go-context.json"
)

# Build only the requested executable family, into a new private output directory.
# Never run arbitrary command strings from installer configuration.
_isb_compile() (
    local language="$1" tree="$2" output="$3" binary="$4" entry="$5" package="$6" limit="$7"
    shift 7
    local -a binaries=("$@") targets=() entries=()
    ((${#binaries[@]})) || binaries=("$binary")
    local status=0 host target name mod=readonly resolved_entries selected_entry index log
    cd "$tree" || return 4
    binary=$(_isb_binary_name "$binary") || return 4
    case "$language" in
        rust)
            [[ -f Cargo.toml && ! -L Cargo.toml ]] || return 4
            _isb_prepare_toolchain "$language" "$tree" "$output" "$limit" || return $?
            # rustup proxies may auto-install a missing repository-selected
            # toolchain. Any separately authorized bootstrap is already active;
            # never let a proxy modify an existing global installation.
            # https://rust-lang.github.io/rustup/environment-variables.html
            export RUSTUP_AUTO_INSTALL=0
            # Use the compiler whose identity is recorded below, not an
            # inherited Cargo-only RUSTC or build-cache wrapper. Preserve
            # compiler homes and dependency caches, as the Windows source
            # engine does, while keeping this attempt's outputs private.
            local rustc_command
            rustc_command=$(command -v rustc) || return 3
            export RUSTC="$rustc_command" RUSTC_WRAPPER='' RUSTC_WORKSPACE_WRAPPER=''
            # Empty flag variables still suppress .cargo/config.toml. Remove
            # ambient overrides so the pinned project's cfg/link flags apply.
            unset RUSTFLAGS CARGO_ENCODED_RUSTFLAGS CARGO_BUILD_RUSTFLAGS
            _isb_run "$limit" "$output/compiler.log" "$rustc_command" -vV || { status=$?; [[ $status == 5 ]] && return 5; return 6; }
            host=$(sed -n 's/^host: //p' "$output/compiler.log")
            [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 6
            export CARGO_BUILD_TARGET="$host" CARGO_TARGET_DIR="$output/target" CARGO_INCREMENTAL=0
            local artifact_path cargo_name windows_paths=false
            case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) windows_paths=true ;; esac
            local -a args=(build --locked --release --message-format=json-render-diagnostics
                --target "$host" --target-dir "$output/target")
            if [[ -n "$package" ]]; then
                args+=(--package "$package")
            elif ((${#binaries[@]} > 1)); then
                # A package-root workspace defaults to building only its root
                # package. Explicit family members can live in other packages.
                args+=(--workspace)
            fi
            for name in "${binaries[@]}"; do
                name=$(_isb_binary_name "$name") || return 4
                cargo_name="$name"
                $windows_paths && cargo_name="${cargo_name%.exe}"
                args+=(--bin "$cargo_name")
                targets+=("$output/target/$host/release/$name")
            done
            _isb_run "$limit" "$output/build.log" cargo "${args[@]}" || { status=$?; [[ $status == 5 ]] && return 5; return 6; }
            for target in "${targets[@]}"; do
                name="${target##*/}"
                cargo_name="$name"
                artifact_path="$target"
                if $windows_paths; then
                    cargo_name="${cargo_name%.exe}"
                    command -v cygpath >/dev/null 2>&1 || {
                        _isb_log 'cygpath is required to validate native Windows Cargo output paths'; return 3;
                    }
                    artifact_path=$(cygpath -am "$target") || return 6
                fi
                # A workspace can contain several packages providing the same
                # --bin name. Cargo can exit zero after warning that their
                # executable paths collide. Only one actual compiler artifact
                # may provide each requested output, using Cargo's resolved
                # package/default-feature/required-feature selection.
                if ! jq -eRs --arg name "$cargo_name" --arg path "$artifact_path" \
                    --argjson windows "$windows_paths" '
                    def native_path:
                        if $windows then gsub("\\\\"; "/") | ascii_downcase else . end;
                    [split("\n")[] | fromjson? |
                        select(.reason == "compiler-artifact" and .target.name == $name and
                            (.target.kind | type == "array" and index("bin") != null))] |
                    length == 1 and (.[0].executable | type == "string") and
                    (.[0].executable | native_path) == ($path | native_path) and
                    (.[0].package_id | type == "string" and length > 0)
                ' "$output/build.log" >/dev/null; then
                    _isb_log "Cargo did not identify exactly one executable provider for: $name"
                    return 6
                fi
            done
            ;;
        go)
            resolved_entries=$(_isb_source_entries "$language" "$tree" "$binary" "$entry" "${binaries[@]}") || return $?
            while IFS= read -r selected_entry; do entries+=("$selected_entry"); done <<< "$resolved_entries"
            export GOENV=off GOWORK=off GOTOOLCHAIN=local GOFLAGS='' GO111MODULE=on GOTELEMETRY=off
            local go_requirements
            go_requirements=$(_isb_go_requirements "${_ISB_CHECKOUT_ROOT:-$tree}" "$tree") || return $?
            _isb_prepare_toolchain "$language" "$tree" "$output" "$limit" "$go_requirements" || return $?
            # Build for this installer host, not an inherited cross target.
            export GOOS='' GOARCH=''
            _isb_run "$limit" "$output/compiler.log" go version || { status=$?; [[ $status == 5 ]] && return 5; return 6; }
            _isb_run "$limit" "$output/platform.log" go env GOHOSTOS GOHOSTARCH || { status=$?; [[ $status == 5 ]] && return 5; return 6; }
            local host_os host_arch
            host_os=$(sed -n '1p' "$output/platform.log")
            host_arch=$(sed -n '2p' "$output/platform.log")
            [[ "$host_os" =~ ^[a-z0-9]+$ && "$host_arch" =~ ^[a-z0-9]+$ ]] || return 6
            export GOOS="$host_os" GOARCH="$host_arch"
            _isb_go_context "${_ISB_CHECKOUT_ROOT:-$tree}" "$tree" "$output" "$limit" || return $?
            GOWORK=$(jq -er .gowork "$output/go-context.json") || return 4
            mod=$(jq -er .mod "$output/go-context.json") || return 4
            export GOWORK
            # Check all providers before compiling the first member. A library
            # can make go build succeed with an archive, not an executable.
            for index in "${!entries[@]}"; do
                log="$output/package.log"
                ((${#entries[@]} == 1)) || log="$output/package-$index.log"
                _isb_run "$limit" "$log" go list "-mod=$mod" -f '{{.Name}}' "./${entries[$index]}" || {
                    status=$?; [[ $status == 5 ]] && return 5; return 6;
                }
                [[ "$(cat "$log")" == main ]] || {
                    _isb_log "Requested Go package is not one executable: ${binaries[$index]} (${entries[$index]})"; return 6;
                }
            done
            # Executable names may legally be compiler.log or dependencies.log.
            # Keep payloads separate from retained diagnostics and toolchains.
            mkdir "$output/bin" || return 1
            for index in "${!entries[@]}"; do
                name=$(_isb_binary_name "${binaries[$index]}") || return 4
                _isb_path_in_tree "$tree" "${entries[$index]}" || return 6
                target="$output/bin/$name"
                log="$output/build.log"
                ((${#entries[@]} == 1)) || log="$output/build-$index.log"
                _isb_run "$limit" "$log" go build "-mod=$mod" -trimpath -o "$target" "./${entries[$index]}" || {
                    status=$?; [[ $status == 5 ]] && return 5; return 6;
                }
                targets+=("$target")
            done
            ;;
        bun|typescript)
            [[ -f package.json && ! -L package.json ]] || return 4
            resolved_entries=$(_isb_source_entries "$language" "$tree" "$binary" "$entry" "${binaries[@]}") || return $?
            while IFS= read -r selected_entry; do entries+=("$selected_entry"); done <<< "$resolved_entries"
            if [[ ! -f bun.lock && ! -f bun.lockb ]]; then
                _isb_log 'A committed bun.lock or bun.lockb is required'; return 4
            fi
            [[ ! -L bun.lock && ! -L bun.lockb ]] || return 4
            _isb_prepare_toolchain "$language" "$tree" "$output" "$limit" || return $?
            _isb_run "$limit" "$output/compiler.log" bun --version || { status=$?; [[ $status == 5 ]] && return 5; return 6; }
            _isb_run "$limit" "$output/dependencies.log" bun install --frozen-lockfile || { status=$?; [[ $status == 5 ]] && return 5; return 6; }
            mkdir "$output/bin" || return 1
            for index in "${!entries[@]}"; do
                name=$(_isb_binary_name "${binaries[$index]}") || return 4
                _isb_path_in_tree "$tree" "${entries[$index]}" && [[ -f "${entries[$index]}" ]] || return 6
                target="$output/bin/$name"
                log="$output/build.log"
                ((${#entries[@]} == 1)) || log="$output/build-$index.log"
                _isb_run "$limit" "$log" bun build --compile --outfile "$target" "./${entries[$index]}" || {
                    status=$?; [[ $status == 5 ]] && return 5; return 6;
                }
                targets+=("$target")
            done
            ;;
        *) return 4 ;;
    esac
    for target in "${targets[@]}"; do
        _isb_path_in_tree "$output" "${target#"$output"/}" && [[ -f "$target" && -s "$target" ]] || {
            _isb_log "Build did not produce a nonempty regular executable: ${target##*/}"; return 6;
        }
        chmod 755 "$target" || return 1
    done
    printf '%s\n' "${targets[@]}"
)

install_source_build() (
    local repo="${1:-}" ref="${2:-}" language="${3:-}" binary="${4:-}" destination="${5:-}"
    [[ $# -ge 5 ]] || return 4
    shift 5
    local allow=false subdir=. entry='' package='' limit=3600 _ISB_INSTALL_TOOLCHAIN=false
    local -a binaries=()
    while (($#)); do
        case "$1" in
            --allow-build) allow=true; shift ;;
            --install-toolchain) _ISB_INSTALL_TOOLCHAIN=true; shift ;;
            --subdir|--entry|--package|--timeout|--bin)
                [[ $# -ge 2 && -n "$2" ]] || return 4
                case "$1" in
                    --subdir) subdir="$2" ;;
                    --entry) entry="$2" ;;
                    --package) package="$2" ;;
                    --timeout) limit="$2" ;;
                    --bin) binaries+=("$2") ;;
                esac
                shift 2 ;;
            *) return 4 ;;
        esac
    done
    if ! $allow; then
        _isb_log 'Source builds execute repository code; explicit --allow-build consent is required'
        return 4
    fi
    [[ "$repo" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || return 4
    _isb_name "$binary" && _isb_relative_path "$subdir" || return 4
    [[ -z "$entry" ]] || _isb_relative_path "$entry" || return 4
    [[ -z "$package" ]] || _isb_name "$package" || return 4
    [[ "$limit" =~ ^[1-9][0-9]{0,4}$ ]] || return 4
    case "$language" in rust|go|bun|typescript) ;; *) _isb_log "Unsupported source language: $language"; return 4 ;; esac
    [[ "$language" != rust || -z "$entry" ]] || { _isb_log 'Rust selects the configured binary, not --entry'; return 4; }
    [[ "$language" == rust || -z "$package" ]] || { _isb_log '--package is only supported for Rust'; return 4; }
    ((${#binaries[@]})) || binaries=("$binary")
    local -A binary_keys=()
    local -a binary_names=()
    local selected key primary_name primary_index=-1 index=0 windows=false
    case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) windows=true ;; esac
    primary_name=$(_isb_binary_name "$binary") || return 4
    for selected in "${binaries[@]}"; do
        _isb_name "$selected" || { _isb_log "Unsafe executable name: $selected"; return 4; }
        key="$selected"
        if $windows; then
            key="${key,,}"
            key="${key%.exe}"
        fi
        if [[ -n "${binary_keys[$key]:-}" ]]; then
            _isb_log "Duplicate or colliding executable name: $selected"
            return 4
        fi
        binary_keys[$key]=1
        selected=$(_isb_binary_name "$selected") || return 4
        binary_names+=("$selected")
        if [[ "$selected" == "$primary_name" ]] ||
           { $windows && [[ "${selected,,}" == "${primary_name,,}" ]]; }; then
            primary_index=$index
        fi
        index=$((index + 1))
    done
    if ((primary_index < 0)); then
        _isb_log "Requested executable family must include primary binary: $binary"
        return 4
    fi
    local tool
    for tool in git jq ps; do
        command -v "$tool" >/dev/null 2>&1 || { _isb_log "Required source-build dependency missing: $tool"; return 3; }
    done
    case "$language" in rust) tool=cargo ;; go) tool=go ;; *) tool=bun ;; esac
    if ! $_ISB_INSTALL_TOOLCHAIN; then
        command -v "$tool" >/dev/null 2>&1 || { _isb_log "Install $tool first, or opt in with --install-toolchain"; return 3; }
        [[ "$language" != rust ]] || command -v rustc >/dev/null 2>&1 || return 3
    fi
    if ! command -v sha256sum >/dev/null 2>&1 && ! command -v shasum >/dev/null 2>&1; then return 3; fi
    _isb_ref "$ref" || { _isb_log 'Use HEAD, a full commit SHA, refs/heads/<branch>, or refs/tags/<tag>'; return 4; }
    [[ -n "$destination" && ! -e "$destination" && ! -L "$destination" && "$destination" != */ ]] || return 4
    local parent name
    parent=$(dirname "$destination")
    name=$(basename "$destination")
    _isb_name "$name" && [[ -d "$parent" && ! -L "$parent" ]] || return 4
    parent=$(cd "$parent" && pwd -P) || return 4
    destination="$parent/$name"
    umask 077
    mkdir "$destination" || return 1
    local tree="$destination/source" output="$destination/output" status=0 commit payload sha size receipt payloads
    mkdir "$output" || return 1
    _isb_log "Fetching $repo at $ref into an isolated checkout"
    _isb_run "$limit" "$destination/fetch.log" _isb_checkout "$repo" "$ref" "$tree" || {
        status=$?; [[ $status == 5 ]] && return 5; return 8;
    }
    commit=$(_isb_git -C "$tree" rev-parse --verify 'HEAD^{commit}') || return 8
    # An incomplete checkout cannot masquerade as a supported source build.
    local entries
    entries=$(_isb_git -C "$tree" ls-files --stage) || return 8
    if grep -q '^160000 ' <<< "$entries"; then
        _isb_log 'Submodule source builds require a project-specific dependency setup'; return 4
    fi
    _isb_path_in_tree "$tree" "$subdir" && [[ -d "$tree/$subdir" ]] || return 4
    local build_root _ISB_CHECKOUT_ROOT="$tree"
    build_root=$(cd "$tree/$subdir" && pwd -P) || return 4
    _isb_log "Building ${binary_names[*]} from pinned commit $commit ($language)"
    payloads=$(_isb_compile "$language" "$build_root" "$output" "$binary" "$entry" "$package" "$limit" "${binaries[@]}") || return $?
    # Preserve the source pin through compilation. Build scripts may not move
    # HEAD or modify tracked inputs and then claim they built the pinned tree.
    [[ "$(_isb_git -C "$tree" rev-parse --verify 'HEAD^{commit}')" == "$commit" ]] || return 6
    _isb_git -C "$tree" diff --quiet HEAD -- || { _isb_log 'Build modified tracked source inputs'; return 6; }
    local -a binary_receipts=()
    local primary_payload='' primary_sha='' primary_size='' binaries_json
    index=0
    while IFS= read -r payload; do
        [[ $index -lt ${#binary_names[@]} && "$payload" == "$output/"* &&
           "${payload##*/}" == "${binary_names[$index]}" ]] || return 6
        _isb_path_in_tree "$output" "${payload#"$output"/}" || return 6
        sha=$(_isb_sha256 "$payload") || return $?
        size=$(wc -c < "$payload") || return 1
        size="${size//[[:space:]]/}"
        binary_receipts+=("$(jq -nc --arg name "${binary_names[$index]}" --arg path "$payload" \
            --arg sha "$sha" --argjson size "$size" \
            '{name:$name,path:$path,sha256:$sha,size_bytes:$size}')") || return 1
        if ((index == primary_index)); then
            primary_payload="$payload"; primary_sha="$sha"; primary_size="$size"
        fi
        index=$((index + 1))
    done <<< "$payloads"
    [[ $index -eq ${#binary_names[@]} && -n "$primary_payload" ]] || return 6
    payload="$primary_payload"; sha="$primary_sha"; size="$primary_size"
    binaries_json=$(printf '%s\n' "${binary_receipts[@]}" | jq -sc '.') || return 1
    local toolchain_receipt=null go_context_file=/dev/null
    if [[ -f "$output/toolchain/receipt.json" ]]; then
        toolchain_receipt=$(jq -ce 'del(.root,.bin_dir)' "$output/toolchain/receipt.json") || return 7
    fi
    if [[ "$language" == go ]]; then
        go_context_file="$output/go-context.json"
        [[ -f "$go_context_file" && ! -L "$go_context_file" ]] || return 7
    fi
    receipt=$(jq -nc --arg repo "$repo" --arg ref "$ref" --arg commit "$commit" \
        --arg language "$language" --arg path "$payload" --arg sha "$sha" --argjson size "$size" \
        --argjson binaries "$binaries_json" \
        --argjson toolchain "$toolchain_receipt" \
        --slurpfile go_context "$go_context_file" \
        --arg compiler "$(cat "$output/compiler.log")" \
        '{schema_version:1,method:"source",repository:$repo,requested_ref:$ref,source_commit:$commit,
          language:$language,path:$path,sha256:$sha,size_bytes:$size,compiler:$compiler,
          binaries:$binaries,signed_release:false} +
          (if $toolchain == null then {} else {toolchain:$toolchain} end) +
          (if $go_context[0].go_workspace == null then {} else {go_workspace:$go_context[0].go_workspace} end)') || return 1
    (set -C; printf '%s\n' "$receipt" > "$destination/receipt.json") || return 1
    _isb_log "Built $binary; SHA256 $sha (locally built, not a signed release)"
    printf '%s\n' "$receipt"
)
