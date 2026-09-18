#!/usr/bin/env bash
# install_source.sh - pinned, opt-in source builds for standalone installers.
# Embedded by install_gen.sh; no DSR installation is needed on the client.
# Source builds execute repository/dependency build code. They are NOT signed
# release artifacts, and this module never installs or upgrades a toolchain.
#
# install_source_build owner/repo ref language binary new_directory --allow-build
#   [--subdir relative/path] [--entry relative/path] [--package cargo_package]
#   [--timeout seconds]
# Timeout applies to each fetch/compiler command, including its children.
# stdout: one receipt JSON after a successful build; stderr: progress/errors.
# Exit: 3 missing dependency, 4 invalid input, 5 timeout/interruption,
#       6 build failure, 8 source retrieval failure, 1 local I/O failure.

_isb_log() { printf '[source-build] %s\n' "$*" >&2; }

_isb_name() {
    [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]
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

_isb_checkout() {
    local repo="$1" ref="$2" dir="$3"
    _isb_git init -q "$dir" || return 8
    _isb_git -C "$dir" remote add origin "https://github.com/$repo.git" || return 8
    _isb_git -C "$dir" fetch -q --depth=1 --no-tags --recurse-submodules=no origin "$ref" || return 8
    local commit
    commit=$(_isb_git -C "$dir" rev-parse --verify 'FETCH_HEAD^{commit}') || return 8
    [[ "$commit" =~ ^[0-9a-f]{40}$ || "$commit" =~ ^[0-9a-f]{64}$ ]] || return 8
    if [[ "$ref" =~ ^[0-9a-fA-F]{40}$ || "$ref" =~ ^[0-9a-fA-F]{64}$ ]]; then
        [[ "$commit" == "${ref,,}" ]] || return 8
    fi
    _isb_git -C "$dir" -c advice.detachedHead=false checkout -q --detach "$commit" || return 8
}

_isb_in_dir() ( cd "$1" && shift && "$@" )

# Freshness is advisory release metadata, NOT artifact or commit-signature
# verification. Query only GitHub's API and do not inherit a GH_HOST override.
# Separate API bytes from diagnostic logs so warnings cannot become JSON.
_isb_freshness_request() {
    local transport="$1" endpoint="$2" destination="$3"
    if [[ "$transport" == gh ]]; then
        gh api --hostname github.com --method GET \
            -H 'Accept: application/vnd.github+json' -H 'Cache-Control: no-cache' \
            "$endpoint" > "$destination"
    else
        curl -sSf --proto '=https' --connect-timeout 10 --max-time 30 \
            -H 'Accept: application/vnd.github+json' -H 'Cache-Control: no-cache' \
            "https://api.github.com/$endpoint" -o "$destination"
    fi
}

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
        then .[0][0].sha | select(type == "string" and test("^([0-9a-f]{40}|[0-9a-f]{64})$"))
        else empty end' "$directory/head.json" 2>/dev/null); then
        _isb_freshness_unknown 'default branch revision unavailable'; return
    fi
    # tags/ disambiguates a same-named branch; Get a commit peels annotated tags.
    encoded_tag=$(jq -nr --arg tag "tags/$tag" '$tag | @uri') || return 1
    status=0
    _isb_freshness_get "repos/$repo/commits/$encoded_tag" "$directory/base.json" "$prefer" || status=$?
    [[ "$status" != 5 ]] || return 5
    if ((status != 0)) || ! base=$(jq -er -s '
        if length == 1 then .[0].sha | select(type == "string" and test("^([0-9a-f]{40}|[0-9a-f]{64})$"))
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

# Build only the requested executable, into a new private output directory.
# Never run arbitrary command strings from installer configuration.
_isb_compile() (
    local language="$1" tree="$2" output="$3" binary="$4" entry="$5" package="$6" limit="$7"
    local status=0 host target mod=readonly
    cd "$tree" || return 4
    case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) binary="${binary%.exe}.exe" ;; esac
    case "$language" in
        rust)
            [[ -f Cargo.toml && ! -L Cargo.toml ]] || return 4
            _isb_run "$limit" "$output/compiler.log" rustc -vV || { status=$?; [[ $status == 5 ]] && return 5; return 6; }
            host=$(sed -n 's/^host: //p' "$output/compiler.log")
            [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 6
            local -a args=(build --locked --release --target "$host" --target-dir "$output/target" --bin "${binary%.exe}")
            [[ -z "$package" ]] || args+=(--package "$package")
            _isb_run "$limit" "$output/build.log" cargo "${args[@]}" || { status=$?; [[ $status == 5 ]] && return 5; return 6; }
            target="$output/target/$host/release/$binary"
            ;;
        go)
            [[ -f go.mod && ! -L go.mod ]] || return 4
            # Build for this installer host, not an inherited cross target.
            export GOENV=off GOWORK=off GOTOOLCHAIN=local GOFLAGS='' GOOS='' GOARCH=''
            _isb_run "$limit" "$output/compiler.log" go version || { status=$?; [[ $status == 5 ]] && return 5; return 6; }
            _isb_run "$limit" "$output/platform.log" go env GOHOSTOS GOHOSTARCH || { status=$?; [[ $status == 5 ]] && return 5; return 6; }
            local host_os host_arch
            host_os=$(sed -n '1p' "$output/platform.log")
            host_arch=$(sed -n '2p' "$output/platform.log")
            [[ "$host_os" =~ ^[a-z0-9]+$ && "$host_arch" =~ ^[a-z0-9]+$ ]] || return 6
            export GOOS="$host_os" GOARCH="$host_arch"
            [[ ! -d vendor ]] || mod=vendor
            if [[ -z "$entry" ]]; then
                entry=.
                [[ ! -d "cmd/${binary%.exe}" ]] || entry="cmd/${binary%.exe}"
            fi
            _isb_path_in_tree "$tree" "$entry" || return 4
            _isb_run "$limit" "$output/package.log" go list "-mod=$mod" -f '{{.Name}}' "./$entry" || { status=$?; [[ $status == 5 ]] && return 5; return 6; }
            [[ "$(cat "$output/package.log")" == main ]] || { _isb_log 'Requested Go package is not one executable'; return 6; }
            target="$output/$binary"
            _isb_run "$limit" "$output/build.log" go build "-mod=$mod" -trimpath -o "$target" "./$entry" || { status=$?; [[ $status == 5 ]] && return 5; return 6; }
            ;;
        bun|typescript)
            [[ -f package.json && ! -L package.json ]] || return 4
            if [[ -z "$entry" ]]; then
                entry=$(jq -er --arg binary "${binary%.exe}" '.bin | if type == "string" then . elif type == "object" then .[$binary] else empty end | select(type == "string" and length > 0)' package.json) || {
                    _isb_log 'Bun source build needs source_entry or a matching package.json bin'; return 4;
                }
                entry="${entry#./}"
            fi
            _isb_path_in_tree "$tree" "$entry" && [[ -f "$entry" ]] || return 4
            if [[ ! -f bun.lock && ! -f bun.lockb ]]; then
                _isb_log 'A committed bun.lock or bun.lockb is required'; return 4
            fi
            [[ ! -L bun.lock && ! -L bun.lockb ]] || return 4
            _isb_run "$limit" "$output/compiler.log" bun --version || { status=$?; [[ $status == 5 ]] && return 5; return 6; }
            _isb_run "$limit" "$output/dependencies.log" bun install --frozen-lockfile || { status=$?; [[ $status == 5 ]] && return 5; return 6; }
            target="$output/$binary"
            _isb_run "$limit" "$output/build.log" bun build --compile --outfile "$target" "./$entry" || { status=$?; [[ $status == 5 ]] && return 5; return 6; }
            ;;
        *) return 4 ;;
    esac
    _isb_path_in_tree "$output" "${target#"$output"/}" && [[ -f "$target" && -s "$target" ]] || {
        _isb_log 'Build did not produce a nonempty regular executable'; return 6;
    }
    chmod 755 "$target" || return 1
    printf '%s\n' "$target"
)

install_source_build() (
    local repo="${1:-}" ref="${2:-}" language="${3:-}" binary="${4:-}" destination="${5:-}"
    [[ $# -ge 5 ]] || return 4
    shift 5
    local allow=false subdir=. entry='' package='' limit=3600
    while (($#)); do
        case "$1" in
            --allow-build) allow=true; shift ;;
            --subdir|--entry|--package|--timeout)
                [[ $# -ge 2 && -n "$2" ]] || return 4
                case "$1" in
                    --subdir) subdir="$2" ;;
                    --entry) entry="$2" ;;
                    --package) package="$2" ;;
                    --timeout) limit="$2" ;;
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
    local tool
    for tool in git jq ps; do
        command -v "$tool" >/dev/null 2>&1 || { _isb_log "Required source-build dependency missing: $tool"; return 3; }
    done
    case "$language" in rust) tool=cargo ;; go) tool=go ;; *) tool=bun ;; esac
    command -v "$tool" >/dev/null 2>&1 || { _isb_log "Install $tool before building from source; existing toolchains are never modified"; return 3; }
    [[ "$language" != rust ]] || command -v rustc >/dev/null 2>&1 || return 3
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
    local tree="$destination/source" output="$destination/output" status=0 commit payload sha size receipt
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
    local build_root
    build_root=$(cd "$tree/$subdir" && pwd -P) || return 4
    _isb_log "Building $binary from pinned commit $commit ($language)"
    payload=$(_isb_compile "$language" "$build_root" "$output" "$binary" "$entry" "$package" "$limit") || return $?
    # Preserve the source pin through compilation. Build scripts may not move
    # HEAD or modify tracked inputs and then claim they built the pinned tree.
    [[ "$(_isb_git -C "$tree" rev-parse --verify 'HEAD^{commit}')" == "$commit" ]] || return 6
    _isb_git -C "$tree" diff --quiet HEAD -- || { _isb_log 'Build modified tracked source inputs'; return 6; }
    [[ "$payload" == "$output/"* && "$payload" != *$'\n'* ]] || return 6
    sha=$(_isb_sha256 "$payload") || return $?
    size=$(wc -c < "$payload") || return 1
    size="${size//[[:space:]]/}"
    receipt=$(jq -nc --arg repo "$repo" --arg ref "$ref" --arg commit "$commit" \
        --arg language "$language" --arg path "$payload" --arg sha "$sha" --argjson size "$size" \
        --arg compiler "$(cat "$output/compiler.log")" \
        '{schema_version:1,method:"source",repository:$repo,requested_ref:$ref,source_commit:$commit,
          language:$language,path:$path,sha256:$sha,size_bytes:$size,compiler:$compiler,
          signed_release:false}') || return 1
    (set -C; printf '%s\n' "$receipt" > "$destination/receipt.json") || return 1
    _isb_log "Built $binary; SHA256 $sha (locally built, not a signed release)"
    printf '%s\n' "$receipt"
)
