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
#   [--feature cargo_feature ...] [--no-default-features] (Rust only)
# Timeout applies to each fetch/compiler command, including its children.
# stdout: one receipt JSON after a successful build; stderr: progress/errors.
# Exit: 3 missing dependency, 4 invalid input, 5 timeout/interruption,
#       6 build failure, 7 distribution verification, 8 retrieval failure,
#       1 local I/O failure.

_isb_log() { printf '[source-build] %s\n' "$*" >&2; }

_isb_name() {
    [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ ]]
}

# Cargo accepts one feature or a package/feature selector per argument. Keep
# the configured list explicit: separators, option syntax and shell code are
# not feature names, and a repeated selection is an ambiguous recipe.
_isb_cargo_features_valid() {
    local feature LC_ALL=C
    local pattern='^[A-Za-z0-9_][A-Za-z0-9_.+-]*(/[A-Za-z0-9_][A-Za-z0-9_.+-]*)?$'
    local -A cargo_features_seen=()
    (($# <= 64)) || return 1
    for feature in "$@"; do
        [[ ${#feature} -le 128 && "$feature" =~ $pattern && -z "${cargo_features_seen[$feature]:-}" ]] || return 1
        cargo_features_seen[$feature]=1
    done
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
    # The embedded engine must parse before the installer can require Bash 4
    # for source execution. Early Bash 3.2 parsers need grouped EREs in variables.
    local reference_pattern='^refs/(heads|tags)/[A-Za-z0-9_][A-Za-z0-9._+/-]*$'
    [[ "$1" == HEAD || "$1" =~ ^[0-9a-fA-F]{40}$ || "$1" =~ ^[0-9a-fA-F]{64}$ ]] && return 0
    case "$1" in refs/heads/*|refs/tags/*) ;; *) return 1 ;; esac
    [[ "$1" =~ $reference_pattern ]] &&
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
    unset GIT_IMPLICIT_WORK_TREE GIT_PREFIX GIT_SHALLOW_FILE GIT_GRAFT_FILE
    unset GIT_NAMESPACE GIT_REPLACE_REF_BASE GIT_TEMPLATE_DIR
    export GIT_TERMINAL_PROMPT=0 GIT_NO_REPLACE_OBJECTS=1
    git -c core.hooksPath=/dev/null -c core.fsmonitor=false -c submodule.recurse=false "$@"
)

_isb_checkout() (
    set +x
    local repo="$1" ref="$2" dir="$3" token='' token_status=0 trace_name authorization
    # A global core.worktree or template must not redirect this checkout into
    # another directory, even when ordinary user credentials remain enabled.
    local -a git_options=(-c "core.worktree=$dir")
    token=$(_installer_github_token) || token_status=$?
    # With no selected GitHub credential, retain the existing Git-only path:
    # anonymous HTTPS, user credential helpers and configured URL policy.
    # A malformed explicit credential must not fall through to that path.
    ((token_status != 5)) || return 5
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
        git_options+=(-c credential.helper= -c credential.interactive=false -c core.askPass=
            -c http.extraHeader= "--config-env=http.https://github.com/$repo.git.extraHeader=DSR_INSTALLER_GIT_AUTHORIZATION"
            -c http.followRedirects=false -c http.sslVerify=true)
    fi
    _isb_git "${git_options[@]}" init -q --template= "$dir" || return 8
    # Compiler subprocesses (including Go's VCS stamping) invoke Git directly,
    # without this helper's -c override. Bind every acquired repository's own
    # worktree so a global core.worktree cannot select an unrelated checkout.
    _isb_git "${git_options[@]}" -C "$dir" config --local core.worktree "$dir" || return 8
    _isb_git ${git_options[@]+"${git_options[@]}"} -C "$dir" remote add origin "https://github.com/$repo.git" || return 8
    _isb_git ${git_options[@]+"${git_options[@]}"} -C "$dir" fetch -q --depth=1 --no-tags --recurse-submodules=no origin "$ref" || return 8
    local commit
    commit=$(_isb_git ${git_options[@]+"${git_options[@]}"} -C "$dir" rev-parse --verify 'FETCH_HEAD^{commit}') || return 8
    [[ "$commit" =~ ^[0-9a-f]{40}$ || "$commit" =~ ^[0-9a-f]{64}$ ]] || return 8
    if [[ "$ref" =~ ^[0-9a-fA-F]{40}$ || "$ref" =~ ^[0-9a-fA-F]{64}$ ]]; then
        [[ "$commit" == "${ref,,}" ]] || return 8
    fi
    _isb_git ${git_options[@]+"${git_options[@]}"} -C "$dir" -c advice.detachedHead=false checkout -q --detach "$commit" || return 8
    [[ "$(_isb_git ${git_options[@]+"${git_options[@]}"} -C "$dir" rev-parse --verify 'HEAD^{commit}')" == "$commit" ]] || return 8
)

# Resolve only GitHub repository identities, never arbitrary submodule URLs.
# A relative URL is relative to the parent repository, as in Git's .gitmodules
# convention. Acquisition always uses the existing scoped HTTPS/account path.
_isb_submodule_repo() {
    local parent="$1" url="$2" repo
    case "$url" in
        https://github.com/*) repo="${url#https://github.com/}" ;;
        ../../*) repo="${url#../../}" ;;
        ../*) repo="${parent%%/*}/${url#../}" ;;
        *) _isb_log "Submodule URL must select a GitHub HTTPS repository: $url"; return 4 ;;
    esac
    repo="${repo%.git}"
    [[ "$repo" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || {
        _isb_log "Unsafe or unsupported submodule repository: $url"; return 4;
    }
    printf '%s\n' "$repo"
}

_isb_submodule_path() {
    local path="$1"
    [[ "$path" != . && ${#path} -le 4096 ]] && _isb_relative_path "$path" || return 4
    case "/${path,,}/" in *'/.git/'*) return 4 ;; esac
}

# All graph scratch files live outside source. Fetch each child by its parent
# gitlink, with an independent .git directory: no submodule update procedures,
# branch selectors, inherited child checkouts or submodule URL fetching by Git.
# The outer _isb_run deadline covers the complete recursive acquisition.
_isb_acquire_submodules() {
    local repo="$1" tree="$2" prefix="$3" depth="$4" number="$_ISB_SOURCE_REPO_COUNT"
    local record mode type oid path metadata key field name value child_repo full_path
    local commit entries_file="$_ISB_SOURCE_GRAPH_DIR/tree-$number" config_file="$_ISB_SOURCE_GRAPH_DIR/modules-$number"
    local -a paths=() pins=() context=(-C "$tree" -c "core.worktree=$tree")
    local -A declarations=() urls=() names_by_path=() folded_paths=()
    commit=$(_isb_git "${context[@]}" rev-parse --verify 'HEAD^{commit}') || return 8
    jq -nc --arg path "$prefix" --arg repo "$repo" --arg commit "$commit" \
        '{path:$path,repository:$repo,source_commit:$commit}' >> "$_ISB_SOURCE_GRAPH_DIR/repositories.jsonl" || return 1
    _isb_git "${context[@]}" ls-tree -r -z --full-tree "$commit" > "$entries_file" || return 8
    while IFS= read -r -d '' record; do
        _ISB_SOURCE_ENTRY_COUNT=$((_ISB_SOURCE_ENTRY_COUNT + 1))
        ((_ISB_SOURCE_ENTRY_COUNT <= 100000)) || { _isb_log 'Source graph exceeds 100000 tracked entries'; return 4; }
        [[ "$record" == *$'\t'* ]] || return 4
        metadata="${record%%$'\t'*}"; path="${record#*$'\t'}"
        IFS=' ' read -r mode type oid <<< "$metadata"
        [[ "$mode" == 160000 ]] || continue
        [[ "$type" == commit && ( "$oid" =~ ^[0-9a-f]{40}$ || "$oid" =~ ^[0-9a-f]{64}$ ) ]] &&
            _isb_submodule_path "$path" || { _isb_log "Unsafe source submodule path: $path"; return 4; }
        paths+=("$path"); pins+=("$oid")
    done < "$entries_file"
    ((${#paths[@]})) || return 0
    ((depth < 16 && _ISB_SOURCE_REPO_COUNT + ${#paths[@]} <= 256)) || {
        _isb_log 'Source submodules exceed 16 levels or 256 repositories'; return 4;
    }
    _isb_source_committed_file "$tree" "$tree/.gitmodules" >/dev/null || {
        _isb_log "Submodules require an unchanged committed regular .gitmodules: ${prefix:-.}"; return 4;
    }
    # --no-includes prevents local/global files named by .gitmodules from
    # becoming dependency authority. Other fields (update, branch, ignore)
    # are never executed or used to relax commit/content verification.
    _isb_git "${context[@]}" config --no-includes --null --file "$tree/.gitmodules" \
        --get-regexp '^submodule\..*\.(path|url)$' > "$config_file" || return 4
    while IFS= read -r -d '' record; do
        [[ "$record" == *$'\n'* ]] || return 4
        key="${record%%$'\n'*}"; value="${record#*$'\n'}"
        field="${key##*.}"; name="${key#submodule.}"; name="${name%.*}"
        [[ "$name" =~ ^[A-Za-z0-9_][A-Za-z0-9._/-]*$ ]] || {
            _isb_log 'Unsafe or unsupported submodule name'; return 4;
        }
        case "$field" in
            path)
                _isb_submodule_path "$value" && [[ -z "${declarations[$name]:-}" &&
                    -z "${folded_paths[${value,,}]:-}" ]] || {
                    _isb_log "Duplicate or unsafe submodule path: $value"; return 4;
                }
                declarations[$name]="$value"; names_by_path[$value]="$name"; folded_paths[${value,,}]=1
                ;;
            url)
                [[ -z "${urls[$name]:-}" ]] || { _isb_log "Repeated submodule URL: $name"; return 4; }
                child_repo=$(_isb_submodule_repo "$repo" "$value") || return 4
                urls[$name]="$child_repo"
                ;;
            *) return 4 ;;
        esac
    done < "$config_file"
    [[ ${#declarations[@]} -eq ${#paths[@]} && ${#urls[@]} -eq ${#paths[@]} ]] || {
        _isb_log 'Submodule declarations must match every pinned gitlink exactly'; return 4;
    }
    local index
    # Validate the entire parent's declaration set before fetching any child.
    for path in "${paths[@]}"; do
        name="${names_by_path[$path]:-}"
        [[ -n "$name" && -n "${urls[$name]:-}" ]] &&
            _isb_path_in_tree "$tree" "$path" && [[ -d "$tree/$path" && ! -e "$tree/$path/.git" && ! -L "$tree/$path/.git" ]] || {
            _isb_log "Missing, linked or ambiguous submodule declaration: $path"; return 4;
        }
    done
    for index in "${!paths[@]}"; do
        path="${paths[$index]}"; name="${names_by_path[$path]}"; child_repo="${urls[$name]}"
        _ISB_SOURCE_REPO_COUNT=$((_ISB_SOURCE_REPO_COUNT + 1))
        ((_ISB_SOURCE_REPO_COUNT <= 256)) || { _isb_log 'Source graph exceeds 256 repositories'; return 4; }
        full_path="${prefix:+$prefix/}$path"
        _isb_log "Fetching submodule $full_path at ${pins[$index]} ($child_repo)"
        _isb_checkout "$child_repo" "${pins[$index]}" "$tree/$path" || return $?
        [[ "$(_isb_git -C "$tree/$path" -c "core.worktree=$tree/$path" rev-parse --verify 'HEAD^{commit}')" == "${pins[$index]}" ]] || return 8
        _isb_acquire_submodules "$child_repo" "$tree/$path" "$full_path" "$((depth + 1))" || return $?
    done
}

_isb_checkout_source() {
    local repo="$1" ref="$2" tree="$3" _ISB_SOURCE_GRAPH_DIR="$4"
    local _ISB_SOURCE_REPO_COUNT=1 _ISB_SOURCE_ENTRY_COUNT=0
    mkdir -- "$_ISB_SOURCE_GRAPH_DIR" || return 1
    _isb_checkout "$repo" "$ref" "$tree" || return $?
    _isb_acquire_submodules "$repo" "$tree" '' 0 || return $?
    jq -s '.' "$_ISB_SOURCE_GRAPH_DIR/repositories.jsonl" > "$_ISB_SOURCE_GRAPH_DIR/repositories.json" || return 1
}

# Authenticate the acquired bytes against the pinned Git tree before retaining
# their raw fingerprint across compilation. Git EOL/encoding conversion is
# allowed, but an external filter cannot supply the authenticated content.
# Batching raw hashes avoids a subprocess for every ordinary source file.
_isb_verify_source_repository() (
    local tree="$1" commit="$2" inventory="$3" record metadata mode type oid path
    local phase="${4:-verify}" cursor remaining component target executable actual
    local -a files=() oids=() modes=()
    [[ "$phase" == initial || "$phase" == verify ]] || return 6
    [[ ! -e "$inventory" && ! -L "$inventory" && -d "$tree/.git" && ! -L "$tree/.git" &&
       -f "$tree/.git/index" && ! -L "$tree/.git/index" ]] || return 6
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
    unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
    unset GIT_IMPLICIT_WORK_TREE GIT_PREFIX GIT_SHALLOW_FILE GIT_GRAFT_FILE
    unset GIT_NAMESPACE GIT_REPLACE_REF_BASE GIT_TEMPLATE_DIR
    export GIT_DIR="$tree/.git" GIT_WORK_TREE="$tree" GIT_COMMON_DIR="$tree/.git"
    export GIT_INDEX_FILE="$tree/.git/index" GIT_OBJECT_DIRECTORY="$tree/.git/objects"
    export GIT_NO_REPLACE_OBJECTS=1 GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
    local -a git_options=(-C "$tree" -c core.hooksPath=/dev/null -c core.fsmonitor=false -c submodule.recurse=false
        --git-dir="$tree/.git" --work-tree="$tree")
    [[ "$(git "${git_options[@]}" rev-parse --verify 'HEAD^{commit}')" == "$commit" ]] || return 6
    git "${git_options[@]}" diff-index --cached --quiet --no-ext-diff --no-textconv \
        --ignore-submodules=none "$commit" -- || return 6
    if [[ "$phase" == initial ]]; then
        # A checkout filter can leave extra compiler inputs without changing
        # any tracked blob. Include ignored files here. Later compiler output
        # and dependency materialization are allowed by the post-build pass.
        [[ ! -e "$inventory.untracked" && ! -L "$inventory.untracked" ]] || return 6
        git "${git_options[@]}" -c core.ignorecase=false ls-files --others -z > "$inventory.untracked" || return 6
        if [[ -s "$inventory.untracked" ]]; then
            _isb_log 'Fetched source contains untracked files, including ignored compiler inputs'
            return 6
        fi
    fi
    [[ ! -e "$inventory.attributes" && ! -L "$inventory.attributes" &&
       ! -e "$inventory.expected" && ! -L "$inventory.expected" ]] || return 6
    _isb_verify_source_batch() {
        local hashes index=0 observed relative attribute filter conversion matched
        local -a attributes=()
        hashes=$(git "${git_options[@]}" hash-object --no-filters -- "${files[@]}") || return 6
        while IFS= read -r observed; do
            ((index < ${#files[@]})) &&
                [[ "$observed" =~ ^[0-9a-f]{40}$ || "$observed" =~ ^[0-9a-f]{64}$ ]] || return 6
            if [[ "$observed" != "${oids[index]}" ]]; then
                # Link stubs contain literal link text, never normalized text.
                [[ "${modes[index]}" != 120000 ]] || return 6
                relative="${files[index]#"$tree"/}"
                git "${git_options[@]}" --literal-pathspecs check-attr -z filter -- "$relative" \
                    > "$inventory.attributes" || return 6
                attributes=()
                while IFS= read -r -d '' attribute; do attributes+=("$attribute"); done < "$inventory.attributes"
                [[ ${#attributes[@]} -eq 3 && "${attributes[0]}" == "$relative" &&
                   "${attributes[1]}" == filter ]] || return 6
                filter="${attributes[2]}"
                [[ "$filter" =~ ^[A-Za-z0-9_/-][A-Za-z0-9._/-]*$ ]] || return 6
                # Compare the actual bytes with a forward checkout of the
                # pinned blob. Reverse cleaning is not proof: for example,
                # ident cleaning discards arbitrary text inside an Id marker.
                # Admit normal LF/CRLF checkouts while retaining tracked
                # text, encoding and canonical ident expansion. Never execute
                # an external filter to manufacture the expected content.
                matched=false
                for conversion in false true; do
                    git "${git_options[@]}" -c core.autocrlf="$conversion" -c core.eol=lf \
                        -c core.safecrlf=false -c "filter.$filter.clean=" \
                        -c "filter.$filter.smudge=" -c "filter.$filter.process=" \
                        -c "filter.$filter.required=false" cat-file --filters \
                        --path="$relative" "${oids[index]}" > "$inventory.expected" || return 6
                    if cmp -s "${files[index]}" "$inventory.expected"; then
                        matched=true
                        break
                    fi
                done
                $matched || return 6
            fi
            index=$((index + 1))
        done <<< "$hashes"
        [[ $index -eq ${#files[@]} ]] || return 6
        # Keep the actual acquired bytes in the before/after fingerprint.
        printf '%s\n' "$hashes"
    }
    git "${git_options[@]}" ls-tree -r -z --full-tree "$commit" > "$inventory" || return 6
    while IFS= read -r -d '' record; do
        [[ "$record" == *$'\t'* ]] || return 6
        metadata="${record%%$'\t'*}"; path="${record#*$'\t'}"
        IFS=' ' read -r mode type oid <<< "$metadata"
        [[ "$oid" =~ ^[0-9a-f]{40}$ || "$oid" =~ ^[0-9a-f]{64}$ ]] || return 6
        [[ -n "$path" && "$path" != /* ]] || return 6
        # Ordinary tracked filenames may contain spaces, tabs or newlines.
        # Only directory boundaries need validation; NUL frames the records.
        cursor="$tree"; remaining="$path"
        while [[ "$remaining" == */* ]]; do
            component="${remaining%%/*}"; remaining="${remaining#*/}"
            case "${component,,}" in ''|.|..|.git) return 6 ;; esac
            cursor="$cursor/$component"
            [[ -d "$cursor" && ! -L "$cursor" ]] || return 6
        done
        case "${remaining,,}" in ''|.|..|.git) return 6 ;; esac
        cursor="$cursor/$remaining"
        printf '%s\0%s\0' "$metadata" "$path" || return 6
        case "$mode:$type" in
            100644:blob|100755:blob|120000:blob)
                if [[ "$mode" == 120000 && -L "$cursor" ]]; then
                    # Preserve target newlines, then remove exactly the one
                    # newline emitted by readlink rather than stored in Git.
                    target=$(readlink "$cursor" && printf '.') || return 6
                    target="${target%.}"
                    [[ "$target" == *$'\n' ]] || return 6
                    target="${target%$'\n'}"
                    actual=$(printf '%s' "$target" | git "${git_options[@]}" hash-object --stdin) || return 6
                    [[ "$actual" == "$oid" ]] || return 6
                    printf 'symlink\0%s\0' "$target" || return 6
                else
                    # core.symlinks=false materializes tracked links as regular
                    # target-text files. Preserve that initial representation;
                    # a later link/file conversion changes this fingerprint.
                    [[ -f "$cursor" && ! -L "$cursor" ]] || return 6
                    executable=0; [[ ! -x "$cursor" ]] || executable=1
                    printf 'regular:%s\0' "$executable" || return 6
                    files+=("$cursor"); oids+=("$oid"); modes+=("$mode")
                    if ((${#files[@]} == 128)); then
                        _isb_verify_source_batch || return 6
                        files=(); oids=(); modes=()
                    fi
                fi
                ;;
            160000:commit)
                [[ -d "$cursor" && ! -L "$cursor" ]] || return 6
                printf 'submodule\0' || return 6
                ;;
            *) return 6 ;;
        esac
    done < "$inventory"
    if ((${#files[@]})); then
        _isb_verify_source_batch || return 6
    fi
)

_isb_verify_source_graph() {
    local tree="$1" graph="$2" directory="$3" rows path commit index=0 manifest
    local phase="${4:-verify}"
    [[ "$phase" == initial || "$phase" == verify ]] || return 6
    [[ -d "$directory" && ! -L "$directory" ]] || return 6
    directory=$(umask 077; mktemp -d "$directory/verify.XXXXXXXX") || return 6
    manifest="$directory/source-state"
    rows=$(jq -r '.[] | [(if .path == "" then "." else .path end),.source_commit] | @tsv' <<< "$graph") || return 6
    : > "$manifest" || return 6
    while IFS=$'\t' read -r path commit; do
        printf '%s\0%s\0' "$path" "$commit" >> "$manifest" || return 6
        _isb_path_in_tree "$tree" "$path" &&
            _isb_verify_source_repository "$tree/$path" "$commit" "$directory/tree-$index" "$phase" >> "$manifest" || {
            _isb_log "Source does not match its pinned Git content or identity: $path"; return 6;
        }
        index=$((index + 1))
    done <<< "$rows"
    _isb_sha256 "$manifest"
}

_isb_in_dir() ( cd "$1" && shift && "$@" )

# Shared by Git source checkout, release acquisition and freshness in generated
# installers, and usable when this source module is loaded alone. Match DSR's token order;
# gh otherwise prefers GH_TOKEN and may inherit an unrelated enterprise host.
# Resolve only one account. An invalid explicit token must not try a stored
# login. Keep credentials and tracing changes confined to this child process.
_installer_github_token() (
    set +x
    local token='' status=0
    if [[ -n "${DSR_GH_TOKEN:-}" ]]; then
        token="$DSR_GH_TOKEN"
    elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
        token="$GITHUB_TOKEN"
    elif [[ -n "${GH_TOKEN:-}" ]]; then
        token="$GH_TOKEN"
    else
        command -v gh >/dev/null 2>&1 || return 3
        token=$(GH_HOST=github.com gh auth token --hostname github.com 2>/dev/null) || status=$?
        case "$status" in
            0) ;;
            2|129|130|131|143) return 5 ;;
            *) return 3 ;;
        esac
    fi
    [[ -n "$token" ]] || return 3
    [[ "$token" != *$'\r'* && "$token" != *$'\n'* ]] || return 4
    printf '%s\n' "$token"
)

# Bound the whole GitHub CLI request, including stored-token lookup. Curl's
# network timeout does not cover a blocked gh credential helper. Keep stdout
# streaming to the caller and credentials off disk; only the timeout marker is
# stored. Job control gives this request and watchdog separate owned groups,
# using syntax supported by release installers on stock macOS Bash 3.2.
# Match the curl acquisition budgets: 30s metadata, 300s release payloads.
_installer_run_gh() (
    set +x
    local limit="${DSR_INSTALLER_GH_TIMEOUT:-}" directory child='' guard='' status=0 interrupted=false
    local destination='' maximum=''
    if [[ "${1:-}" == --bounded-output ]]; then
        [[ $# -ge 4 && -n "$2" && "$3" =~ ^[1-9][0-9]{0,9}$ ]] || return 4
        destination="$2"; maximum="$3"; shift 3
        ((maximum <= 2147483648)) || return 4
        [[ ! -L "$destination" && ( ! -e "$destination" || -f "$destination" ) ]] || return 8
        command -v head >/dev/null 2>&1 && command -v ps >/dev/null 2>&1 || return 3
    fi
    if [[ -z "$limit" ]]; then
        if [[ "${1:-} ${2:-}" == 'release download' ]]; then limit=300
        else limit=30; fi
    fi
    [[ "$limit" =~ ^[1-9][0-9]{0,2}$ ]] && ((limit <= 300)) || {
        printf '[installer] DSR_INSTALLER_GH_TIMEOUT must be 1 through 300 seconds\n' >&2
        return 4
    }
    command -v gh >/dev/null 2>&1 || return 3
    directory=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/dsr-gh.XXXXXXXX") || return 8
    _installer_gh_dispose() {
        trap '' HUP INT TERM
        [[ -z "$child" ]] || kill -TERM -- "-$child" 2>/dev/null || true
        [[ -z "$guard" ]] || kill -TERM -- "-$guard" 2>/dev/null || true
        [[ -z "$child" ]] || kill -KILL -- "-$child" 2>/dev/null || true
        [[ -z "$child" ]] || wait "$child" 2>/dev/null || true
        [[ -z "$guard" ]] || wait "$guard" 2>/dev/null || true
        rm -f -- "$directory/timeout" "$directory/output-limit" "$directory/output-error" 2>/dev/null || true
        rmdir -- "$directory" 2>/dev/null || true
    }
    _installer_gh_cancel() {
        _installer_gh_dispose
        exit 5
    }
    # Record setup signals until both launched process IDs are available.
    # A trap between starting a job and reading $! must not lose that child.
    trap 'interrupted=true' HUP INT TERM
    set -m
    (
        set +m
        token=$(_installer_github_token) || exit $?
        request_status=0
        if [[ -n "$maximum" ]]; then
            # An external shell observes this worker's actual process group
            # on Bash 3.2 too, where BASHPID is unavailable. The reader can
            # stop the entire owned request as soon as its byte bound is hit;
            # it must not wait for a CLI that ignores SIGPIPE or holds stdout.
            request_group=$(sh -c 'ps -o pgid= -p "$$"') || exit 3
            request_group="${request_group//[[:space:]]/}"
            [[ "$request_group" =~ ^[1-9][0-9]*$ ]] || exit 3
            local -a output_statuses=()
            GH_HOST=github.com GH_TOKEN="$token" gh "$@" | (
                bytes=''
                if head -c "$((maximum + 1))" > "$destination" &&
                   bytes=$(wc -c < "$destination") && [[ "$bytes" =~ ^[[:space:]]*[0-9]+[[:space:]]*$ ]]; then
                    if ((bytes <= maximum)); then exit 0; fi
                    printf 'limit\n' > "$directory/output-limit"
                else
                    printf 'write\n' > "$directory/output-error"
                fi
                kill -TERM -- "-$request_group" 2>/dev/null || true
                exit 8
            )
            output_statuses=("${PIPESTATUS[@]}")
            request_status=${output_statuses[0]}
            [[ "${output_statuses[1]}" == 0 ]] || request_status=8
        else
            GH_HOST=github.com GH_TOKEN="$token" gh "$@" || request_status=$?
        fi
        case "$request_status" in
            0) exit 0 ;;
            # gh uses 1 for both unavailable assets and other request failures.
            # Only the acquisition caller can combine it with independent HTTP
            # evidence; it must never authorize source execution by itself.
            1) exit 1 ;;
            2|129|130|131|143) exit 5 ;;
            *) exit 8 ;;
        esac
    ) </dev/null &
    child=$!
    $interrupted && _installer_gh_cancel
    (
        set +m
        timer=''
        _installer_gh_stop_timer() {
            trap '' HUP INT TERM
            [[ -z "$timer" ]] || kill "$timer" 2>/dev/null || true
            [[ -z "$timer" ]] || wait "$timer" 2>/dev/null || true
            exit 0
        }
        trap _installer_gh_stop_timer HUP INT TERM
        sleep "$limit" & timer=$!
        wait "$timer" || exit 0
        printf 'timeout\n' > "$directory/timeout"
        kill -TERM -- "-$child" 2>/dev/null || true
        sleep 2 & timer=$!
        wait "$timer" || exit 0
        kill -KILL -- "-$child" 2>/dev/null || true
    ) &
    guard=$!
    trap _installer_gh_cancel HUP INT TERM
    $interrupted && _installer_gh_cancel
    wait "$child" 2>/dev/null || status=$?
    if [[ -f "$directory/output-limit" ]]; then
        # Observed oversized bytes stay an integrity refusal even if the
        # deadline fires concurrently; another transport must not retry them.
        printf '[installer] GitHub CLI asset exceeds its %s-byte limit\n' "$maximum" >&2
        status=7
    elif [[ -f "$directory/timeout" ]]; then
        printf '[installer] GitHub CLI request exceeded %ss\n' "$limit" >&2
        # A credential/CLI timeout is ambiguous, never proof that a release
        # is absent and therefore never permission to compile source.
        status=8
    elif [[ -f "$directory/output-error" ]]; then
        printf '[installer] Cannot retain the bounded GitHub CLI asset\n' >&2
        status=8
    fi
    _installer_gh_dispose
    return "$status"
)

# Freshness is advisory release metadata, NOT artifact or commit-signature
# verification. Query only GitHub's API and do not inherit a GH_HOST override.
# Separate API bytes from diagnostic logs so warnings cannot become JSON.
_isb_freshness_request() (
    set +x
    local transport="$1" endpoint="$2" destination="$3"
    local maximum=8388608 bytes status token='' escaped_token='' header header_bytes=0 headers_complete=false
    local status_pattern='^HTTP/[0-9]+(\.[0-9]+)? 200( .*)?$'
    local LC_ALL=C
    local -a transfer_statuses=()
    set -o pipefail
    if [[ "$transport" == gh ]]; then
        # The CLI's successful exit includes responses other than HTTP 200.
        # Bound its complete response before parsing, then admit exactly one
        # bounded header block and a separately bounded JSON body. The extra
        # 64 KiB is solely for headers, never a larger metadata allowance.
        _installer_run_gh --bounded-output "$destination.response" "$((maximum + 65536))" \
            api --hostname github.com --method GET --include \
            -H 'Accept: application/vnd.github+json' -H 'Cache-Control: no-cache' \
            "$endpoint" || return $?
        {
            IFS= read -r header || return 8
            header_bytes=$((${#header} + 1))
            header="${header%$'\r'}"
            [[ "$header" =~ $status_pattern ]] || return 8
            while IFS= read -r header; do
                header_bytes=$((header_bytes + ${#header} + 1))
                ((header_bytes <= 65536)) || return 8
                header="${header%$'\r'}"
                if [[ -z "$header" ]]; then headers_complete=true; break; fi
            done
            $headers_complete || return 8
            head -c "$((maximum + 1))" > "$destination" || return 8
        } < "$destination.response"
        bytes=$(wc -c < "$destination") || return 8
        [[ "$bytes" =~ ^[[:space:]]*[0-9]+[[:space:]]*$ ]] && ((bytes <= maximum)) || return 8
    elif [[ "$transport" == curl ]]; then
        # Keep the same selected-account rule as release acquisition. A
        # token-only installation authenticates without requiring the CLI;
        # anonymous metadata uses exactly the same status and byte limits.
        if ! command -v gh >/dev/null 2>&1 &&
           [[ -n "${DSR_GH_TOKEN:-}" || -n "${GITHUB_TOKEN:-}" || -n "${GH_TOKEN:-}" ]]; then
            token=$(_installer_github_token) || return $?
            [[ ${#token} -le 8192 && "$token" != *[[:cntrl:]]* ]] || return 4
            escaped_token="${token//\\/\\\\}"; escaped_token="${escaped_token//\"/\\\"}"
        fi
        # Do not trust Content-Length as the only bound: older curl versions
        # cannot enforce --max-filesize for unknown-length/chunked bodies.
        # Ignore .curlrc, do not follow redirects, and never put credentials
        # in argv. An unavailable advisory response cannot authorize source.
        if ! {
            [[ -z "$token" ]] || printf 'header = "Authorization: Bearer %s"\n' "$escaped_token"
        } |
            curl -q --config - --silent --globoff --proto '=https' \
                --connect-timeout 10 --max-time 30 --max-filesize "$maximum" \
                -H 'Accept: application/vnd.github+json' -H 'Cache-Control: no-cache' \
                -H 'X-GitHub-Api-Version: 2022-11-28' \
                --user-agent 'dsr-installer' \
                "https://api.github.com/$endpoint" --output /dev/fd/3 \
                --write-out '%{http_code}' 3>&1 > "$destination.http" 2>/dev/null |
            head -c "$((maximum + 1))" > "$destination"; then
            transfer_statuses=("${PIPESTATUS[@]}")
            case "${transfer_statuses[1]:-0}" in 42|129|130|131|143) return 5 ;; esac
            return 8
        fi
        bytes=$(wc -c < "$destination" | tr -d '[:space:]') || return 1
        status=$(cat -- "$destination.http") || return 1
        [[ "$status" == 200 && "$bytes" =~ ^[0-9]+$ ]] && ((bytes <= maximum)) || return 8
    else
        return 4
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
    local threshold_pattern='^(0|[1-9][0-9]{0,5})$'
    [[ $# -eq 4 || ( $# -eq 5 && "$5" == --prefer-gh ) ]] || return 4
    [[ $# -ne 5 ]] || prefer=true
    [[ "$repo" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9][A-Za-z0-9_.-]*$ &&
       "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ && "$tag" != null &&
       "$threshold" =~ $threshold_pattern ]] || return 4
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

_isb_probe_bun() (
    local expected="$2" observed
    cd "$1" || return 4
    observed=$(bun --version) || return $?
    [[ "$observed" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && ( -z "$expected" || "$observed" == "$expected" ) ]] || return 1
    _tc_bun_check_engine bun "$3"
)

# Activate an explicitly requested bootstrap when a compiler is unavailable,
# or when an installed compiler cannot satisfy the pinned source requirements.
# This runs inside _isb_compile's subshell, so PATH and language homes never
# escape the source attempt or replace the caller's installed toolchain.
_isb_prepare_toolchain() {
    local language="$1" tree="$2" output="$3" limit="$4" command root bin source_dir status=0
    local go_requirements="${5:-}" installed=false required observed version
    local go_version_pattern='^go version go([1-9][0-9]*\.[0-9]+\.[0-9]+|1\.([0-9]|1[0-9]|20)) [a-z0-9]+/[a-z0-9]+$'
    local -a bootstrap_options=(--allow-install)
    [[ -z "$go_requirements" || "$language" == go ]] || return 4
    [[ -z "$go_requirements" ]] || bootstrap_options+=(--go-requirements "$go_requirements")
    case "$language" in rust) command=cargo ;; go) command=go ;; *) command=bun ;; esac
    if command -v "$command" >/dev/null 2>&1 &&
       { [[ "$language" != rust ]] || command -v rustc >/dev/null 2>&1; }; then
        installed=true
        [[ "${_ISB_INSTALL_TOOLCHAIN:-false}" == true ]] || return 0
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
       { [[ "$language" == go ]] && ! declare -F _tc_go_required_version >/dev/null 2>&1; } ||
       { [[ "$command" == bun ]] && ! declare -F _tc_bun_requirements >/dev/null 2>&1; }; then
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
            if [[ "$observed" =~ $go_version_pattern ]]; then
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
    elif $installed && [[ "$command" == bun ]]; then
        local requirements engine
        requirements=$(_tc_bun_requirements "$tree") || return $?
        required=$(jq -r '.version' <<< "$requirements") || return 4
        engine=$(jq -r '.engine' <<< "$requirements") || return 4
        _isb_run "$limit" "$output/toolchain-probe.log" _isb_probe_bun "$output" "$required" "$engine" || status=$?
        ((status != 0)) || return 0
        ((status != 5 && status < 128)) || return 5
        _isb_log 'The existing Bun compiler cannot satisfy the selected package.json; preparing an isolated toolchain'
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

# The compiler supplies syntax and package identity. Git supplies authority:
# source manifests and locks must be unchanged regular blobs from the fetched
# commit, never ambient or generated inputs.
_isb_source_committed_file() {
    local root="$1" path="$2" relative row mode type oid rest actual hash attributes filter
    [[ "$path" == "$root/"* && -f "$path" && ! -L "$path" ]] || return 4
    relative="${path#"$root"/}"
    local reference=HEAD owner owner_path
    if [[ -n "${_ISB_SOURCE_GRAPH:-}" && "$root" == "${_ISB_CHECKOUT_ROOT:-}" ]]; then
        # ls-tree cannot walk through a gitlink. Resolve the longest recorded
        # parent path, and read metadata from that child's original commit,
        # never from a new repository or HEAD introduced by a build script.
        owner=$(jq -cer --arg path "$relative" '
            [.[] | .path as $prefix | select($prefix == "" or ($path | startswith($prefix + "/")))] |
            max_by(.path | length)' <<< "$_ISB_SOURCE_GRAPH") || return 4
        owner_path=$(jq -r '.path' <<< "$owner") || return 4
        reference=$(jq -r '.source_commit' <<< "$owner") || return 4
        if [[ -n "$owner_path" ]]; then
            _isb_path_in_tree "$root" "$owner_path" || return 4
            root="$root/$owner_path"; relative="${path#"$root"/}"
        fi
    fi
    local -a context=(-C "$root" -c "core.worktree=$root")
    row=$(_isb_git "${context[@]}" --literal-pathspecs ls-tree "$reference" -- "$relative") || return 4
    [[ -n "$row" && "$row" != *$'\n'* ]] || return 4
    IFS=$' \t' read -r mode type oid rest <<< "$row"
    [[ "$type" == blob && ( "$mode" == 100644 || "$mode" == 100755 ) &&
       ( "$oid" =~ ^[0-9a-f]{40}$ || "$oid" =~ ^[0-9a-f]{64}$ ) ]] || return 4
    actual=$(_isb_git "${context[@]}" hash-object --no-filters -- "$path") || return 4
    if [[ "$actual" != "$oid" ]]; then
        # A normal checkout can apply core.autocrlf or tracked text/eol
        # attributes. Let Git perform that normalization, but disable the
        # selected external filter driver before hashing: metadata admission
        # must not execute a clean/process hook. The receipt still hashes the
        # actual checkout bytes that Go parses, including their line endings.
        attributes=$(_isb_git "${context[@]}" --literal-pathspecs check-attr filter -- "$relative") || return 4
        [[ "$attributes" != *$'\n'* && "$attributes" == *': filter: '* ]] || return 4
        filter="${attributes#*: filter: }"
        [[ "$filter" =~ ^[A-Za-z0-9_/-][A-Za-z0-9._/-]*$ ]] || return 4
        actual=$(_isb_git "${context[@]}" -c "filter.$filter.clean=" -c "filter.$filter.process=" \
            -c "filter.$filter.required=false" hash-object --path="$relative" -- "$path") || return 4
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
    _isb_source_committed_file "$root" "$selected" >/dev/null || {
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
        work_hash=$(_isb_source_committed_file "$root" "$work") || return 4
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
        _isb_source_committed_file "$root" "$work.sum" >/dev/null || {
            _isb_log 'go.work.sum must be an unchanged committed regular file'; return 4;
        }
    fi
    : > "$output/go-modules.jsonl" || return 1
    : > "$output/go-replacements.jsonl" || return 1
    for module_root in "${module_roots[@]}"; do
        relative="${module_root#"$root"/}"; [[ "$module_root" != "$root" ]] || relative=.
        [[ -z "${seen_paths[$relative]:-}" ]] || { _isb_log 'Go workspace repeats a module directory'; return 4; }
        seen_paths[$relative]=1
        module_hash=$(_isb_source_committed_file "$root" "$module_root/go.mod") || {
            _isb_log "Go module requires an unchanged committed regular go.mod: $relative"; return 4;
        }
        sum_file="$module_root/go.sum"
        if [[ -e "$sum_file" || -L "$sum_file" ]]; then
            _isb_source_committed_file "$root" "$sum_file" >/dev/null || {
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
            [[ ! -e "$document" ]] || _isb_source_committed_file "$root" "$document" >/dev/null || return 4
            vendor=true; mod=vendor
        elif [[ -f "$document" ]] && head -c 512 "$document" | jq -eRs '
            split("\n")[0] | if startswith("## ") then .[3:] | split(";") |
            any(.[]; gsub("^[[:space:]]+|[[:space:]]+$"; "") == "workspace")
            else false end' >/dev/null; then
            # Go ignores a member module's vendor tree and a legacy module
            # vendor at the workspace root. Match its workspace annotation
            # before choosing vendor mode, rather than forcing an invalid one.
            vendor_hash=$(_isb_source_committed_file "$root" "$document") || return 4
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
            hash=$(_isb_source_committed_file "$root" "$replacement/go.mod") || {
                _isb_log "Local Go replacement requires a committed regular go.mod: $old"; return 4;
            }
            if [[ -e "$replacement/go.sum" || -L "$replacement/go.sum" ]]; then
                _isb_source_committed_file "$root" "$replacement/go.sum" >/dev/null || return 4
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

# Select a locked project without walking outside the fetched checkout. Bun
# itself subsequently confirms that the selected package belongs to this root;
# a nearby unrelated lockfile is not sufficient workspace authority.
_isb_bun_dependency_root() (
    local root="$1" tree="$2" cursor="$2" relative lock found=false
    relative="${tree#"$root"/}"; [[ "$tree" != "$root" ]] || relative=.
    _isb_path_in_tree "$root" "$relative" && [[ -d "$tree" ]] || return 4
    while :; do
        found=false
        for lock in bun.lock bun.lockb; do
            if [[ -e "$cursor/$lock" || -L "$cursor/$lock" ]]; then
                [[ -f "$cursor/$lock" && ! -L "$cursor/$lock" ]] || return 4
                [[ -z "${_ISB_CHECKOUT_ROOT:-}" ]] ||
                    _isb_source_committed_file "$root" "$cursor/$lock" >/dev/null || return 4
                found=true
            fi
        done
        if $found; then
            [[ -f "$cursor/package.json" && ! -L "$cursor/package.json" ]] || return 4
            [[ -z "${_ISB_CHECKOUT_ROOT:-}" ]] ||
                _isb_source_committed_file "$root" "$cursor/package.json" >/dev/null || return 4
            if [[ "$cursor" != "$tree" ]]; then
                jq -es 'length == 1 and (.[0].workspaces |
                    (if type == "object" then .packages else . end) |
                    type == "array" and length > 0 and all(.[]; type == "string" and length > 0))' \
                    "$cursor/package.json" >/dev/null || return 4
            fi
            printf '%s\n' "$cursor"
            return 0
        fi
        [[ "$cursor" != "$root" ]] || break
        cursor="${cursor%/*}"
    done
    _isb_log 'A committed bun.lock or bun.lockb is required in the selected package or its workspace'
    return 4
)

_isb_bun_context() (
    local root="$1" tree="$2" dependency_root="$3" output="$4" limit="$5" status=0
    local selected expected="$dependency_root/node_modules/.bin" lock hash size relative
    local package_hash root_hash root_relative member_relative
    local -a locks=()
    _isb_run "$limit" "$output/bun-project.log" bun pm bin || {
        status=$?; [[ "$status" != 5 ]] || return 5; return 4;
    }
    selected=$(cat "$output/bun-project.log") || return 1
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*)
            command -v cygpath >/dev/null 2>&1 || return 3
            expected=$(cygpath -am "$expected") || return 4
            selected="${selected%$'\r'}"; selected="${selected//\\//}"
            selected="${selected,,}"; expected="${expected,,}"
            ;;
    esac
    [[ "$selected" == "$expected" ]] || {
        _isb_log 'Bun did not select the committed dependency root for this source package'; return 4;
    }
    package_hash=$(_isb_sha256 "$tree/package.json") || return $?
    root_hash=$(_isb_sha256 "$dependency_root/package.json") || return $?
    for lock in bun.lock bun.lockb; do
        [[ -f "$dependency_root/$lock" && ! -L "$dependency_root/$lock" ]] || continue
        hash=$(_isb_sha256 "$dependency_root/$lock") || return $?
        size=$(wc -c < "$dependency_root/$lock") || return 1
        relative="${dependency_root#"$root"/}/$lock"
        [[ "$dependency_root" != "$root" ]] || relative="$lock"
        locks+=("$(jq -nc --arg path "$relative" --arg hash "$hash" --argjson size "$size" \
            '{path:$path,sha256:$hash,size_bytes:$size}')") || return 1
    done
    ((${#locks[@]} > 0)) || return 4
    root_relative="${dependency_root#"$root"/}"; [[ "$dependency_root" != "$root" ]] || root_relative=.
    member_relative="${tree#"$dependency_root"/}"; [[ "$tree" != "$dependency_root" ]] || member_relative=.
    printf '%s\n' "${locks[@]}" | jq -sc --arg package_hash "$package_hash" --arg root_hash "$root_hash" \
        --arg root "$root_relative" --arg member "$member_relative" \
        '{package_json_sha256:$package_hash,bun_lockfiles:.} +
         (if $member == "." then {} else {bun_workspace:{root:$root,member:$member,package_json_sha256:$root_hash}} end)' \
        > "$output/bun-context.json"
)

# RCH's explicit Cargo JSON mode advertises invocation-private delivered copies,
# not the mutable conventional Cargo output. Verify its retained producer records
# and fingerprints before admitting the complete family into our own staging tree.
# This establishes delivery identity, not remote source/compiler attestation.
_isb_rch_cargo_outputs() (
    local tree="$1" output="$2" host="$3" limit="$4"
    shift 4
    python3 -I - "$tree" "${_ISB_CHECKOUT_ROOT:-$tree}" "$output" "$host" "$limit" "$@" <<'PY'
import copy
import hashlib
import json
import os
from pathlib import PurePosixPath
import re
import stat
import subprocess
import sys

tree, checkout, output, host, limit, *names = sys.argv[1:]
limit = int(limit)
MAX_RECEIPT = 64 * 1024 * 1024  # RCH MAX_CARGO_OUTPUT_RECEIPT_BYTES
MAX_PAYLOAD = 4 * 1024 * 1024 * 1024
HEX = re.compile(r"[0-9a-f]{64}\Z")
UUID = r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}"
directories = {}
files = []

def require(ok, message):
    if not ok:
        raise ValueError(message)

def path(value):
    require(isinstance(value, str) and value.startswith("/") and
            not any(ord(c) < 32 or ord(c) == 127 for c in value) and
            "\\" not in value, "invalid absolute delivery path")
    parsed = PurePosixPath(value)
    require(str(parsed) == value and ".." not in parsed.parts, "noncanonical delivery path")
    return parsed

def below(value, root):
    relative = path(value).relative_to(path(root))
    require(relative.parts, "delivery path names a root")
    return relative

def identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_nlink,
            info.st_uid, info.st_gid, info.st_size, info.st_mtime_ns, info.st_ctime_ns)

def directory(value):
    value = str(path(value))
    if value in directories:
        return directories[value][0]
    if value == "/":
        fd = os.open(value, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        parent, name = None, None
    else:
        parent = directory(str(path(value).parent))
        name = path(value).name
        fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
    directories[value] = (fd, parent, name, os.fstat(fd))
    return fd

class File:
    def __init__(self, value, maximum, nonempty=False):
        self.path = path(value)
        self.parent = directory(str(self.path.parent))
        self.fd = os.open(self.path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                          dir_fd=self.parent)
        self.before = os.fstat(self.fd)
        files.append(self)
        require(stat.S_ISREG(self.before.st_mode) and self.before.st_size <= maximum and
                (not nonempty or self.before.st_size > 0), "invalid retained file size or type")
        self.check()

    def check(self):
        current = os.stat(self.path.name, dir_fd=self.parent, follow_symlinks=False)
        require(identity(current) == identity(self.before) == identity(os.fstat(self.fd)),
                "retained file changed during delivery validation")

    def chunks(self):
        self.check()
        os.lseek(self.fd, 0, os.SEEK_SET)
        remaining = self.before.st_size
        while remaining:
            data = os.read(self.fd, min(1024 * 1024, remaining))
            require(data, "retained file was truncated")
            remaining -= len(data)
            yield data
        require(not os.read(self.fd, 1), "retained file grew")
        self.check()

    def blake3(self, expected):
        require(isinstance(expected, str) and HEX.fullmatch(expected), "invalid BLAKE3 fingerprint")
        self.check()
        os.lseek(self.fd, 0, os.SEEK_SET)
        result = subprocess.run(["b3sum", "--no-names"], stdin=self.fd, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=limit, check=True)
        require(result.stdout.decode("ascii").strip() == expected, "retained BLAKE3 fingerprint mismatch")
        self.check()

def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON object key")
        result[key] = value
    return result

def records(source):
    # Cargo diagnostics may share the log. Only complete JSON records are data;
    # duplicate keys and nonfinite numbers are never accepted as producer data.
    pending = b""
    result = []
    telemetry = False
    for chunk in source.chunks():
        pending += chunk
        lines = pending.split(b"\n")
        pending = lines.pop()
        for line in lines:
            if line.rstrip(b"\r") == b"---RCH-TELEMETRY---":
                telemetry = True
            if telemetry:
                continue
            try:
                value = json.loads(line, object_pairs_hook=unique_object,
                                   parse_constant=lambda _: (_ for _ in ()).throw(ValueError("invalid JSON number")))
            except (json.JSONDecodeError, UnicodeDecodeError):
                continue
            if isinstance(value, dict):
                result.append(value)
    if pending.strip() and not telemetry:
        try:
            value = json.loads(pending, object_pairs_hook=unique_object,
                               parse_constant=lambda _: (_ for _ in ()).throw(ValueError("invalid JSON number")))
        except (json.JSONDecodeError, UnicodeDecodeError):
            value = None
        if isinstance(value, dict):
            result.append(value)
    finished = [record for record in result if record.get("reason") == "build-finished"]
    require(len(finished) == 1 and finished[0].get("success") is True and
            result[-1] is finished[0], "Cargo delivery lacks one successful terminal build record")
    return result

def selected(all_records):
    result = []
    for name in names:
        providers = [record for record in all_records if record.get("reason") == "compiler-artifact" and
                     record.get("target", {}).get("name") == name and
                     "bin" in record.get("target", {}).get("kind", [])]
        require(len(providers) == 1, "Cargo delivery has missing or ambiguous executable providers")
        record = providers[0]
        require(record["target"]["kind"] == ["bin"] and
                isinstance(record.get("package_id"), str) and record["package_id"] and
                record.get("profile", {}).get("test") is False, "invalid executable provider record")
        result.append(record)
    return result

def revalidate():
    for value, (fd, parent, name, before) in directories.items():
        current = os.fstat(fd)
        named = os.stat(name, dir_fd=parent, follow_symlinks=False) if parent is not None else os.lstat(value)
        require(stat.S_ISDIR(named.st_mode) and (before.st_dev, before.st_ino) ==
                (current.st_dev, current.st_ino) == (named.st_dev, named.st_ino),
                "delivery directory identity changed")
    for source in files:
        source.check()

try:
    require(names and len(set(names)) == len(names), "invalid requested executable family")
    target_root = str(path(output) / "target")
    caller_records = selected(records(File(output + "/build.log", 3 * MAX_RECEIPT)))
    receipt = caller_records[0].get("rch", {}).get("receipt")
    require(isinstance(receipt, dict) and set(receipt) == {
        "path", "blake3", "wrapper_id", "build_id", "published_output_root",
        "caller_output_root", "remote_project_root", "stderr"}, "unrecognized RCH receipt binding")
    wrapper = receipt["wrapper_id"]
    require(isinstance(wrapper, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,255}", wrapper),
            "invalid RCH wrapper identity")
    require(type(receipt["build_id"]) is int and receipt["build_id"] > 0, "invalid RCH build identity")
    caller_root = path(receipt["caller_output_root"])
    require(receipt["published_output_root"] == target_root and str(caller_root.parent) == target_root and
            re.fullmatch(r"\.rch-delivered-" + re.escape(wrapper) + "-" + UUID, caller_root.name),
            "RCH delivery is not bound to this invocation's target directory")
    remote_project = str(path(receipt["remote_project_root"]))
    stderr = receipt["stderr"]
    require(isinstance(stderr, dict) and set(stderr) == {"path", "blake3", "bytes", "exit_code"} and
            type(stderr["bytes"]) is int and 0 <= stderr["bytes"] <= MAX_RECEIPT and
            type(stderr["exit_code"]) is int and stderr["exit_code"] == 0, "invalid retained diagnostics receipt")
    stdout_file = File(receipt["path"], MAX_RECEIPT, True)
    stderr_file = File(stderr["path"], MAX_RECEIPT)
    for source, label in [(stdout_file, "stdout"), (stderr_file, "stderr")]:
        require(re.fullmatch(re.escape(wrapper) + r"\.cargo-" + label + "-" + UUID, source.path.name),
                "retained receipt path is not bound to its wrapper")
    require(stdout_file.path.parent == stderr_file.path.parent and
            stderr_file.before.st_size == stderr["bytes"], "retained diagnostics identity mismatch")
    stdout_file.blake3(receipt["blake3"])
    stderr_file.blake3(stderr["blake3"])
    original_records = records(stdout_file)
    original_selected = selected(original_records)
    candidates = []
    cursor = path(tree)
    while True:
        candidates.append(str(cursor))
        if str(cursor) == checkout:
            break
        require(cursor != cursor.parent and path(checkout) in cursor.parents, "source tree escapes checkout")
        cursor = cursor.parent
    projections, outputs, binary_evidence = [], [], []
    remote_output = None
    for name, record, original in zip(names, caller_records, original_selected):
        extension = record.get("rch")
        require(isinstance(extension, dict) and set(extension) == {"worker_record", "receipt", "executable_blake3"} and
                extension["receipt"] == receipt and extension["worker_record"] == original and
                sum(item == original for item in original_records) == 1 and "rch" not in original,
                "RCH executable lacks its exact shared producer record")
        relative = PurePosixPath(host) / "release" / name
        executable = str(caller_root / relative)
        require(record.get("executable") == executable, "RCH executable does not match selected host/name")
        worker_executable = path(original.get("executable"))
        require(worker_executable.parts[-3:] == relative.parts, "worker executable target/name mismatch")
        worker_root = str(worker_executable.parents[2])
        require(remote_output is None or remote_output == worker_root, "mixed worker output roots")
        remote_output = worker_root
        expected = copy.deepcopy(original)
        expected["executable"] = executable
        require(isinstance(original.get("filenames"), list) and original["executable"] in original["filenames"],
                "worker executable is absent from its output set")
        expected["filenames"] = [str(caller_root / below(item, worker_root)) for item in original["filenames"]]
        for old, new in [(original.get("manifest_path"), record.get("manifest_path")),
                         (original["target"].get("src_path"), record["target"].get("src_path"))]:
            path(old)
            below(new, checkout)
            File(new, MAX_PAYLOAD, True)
            projections.append((old, new))
        require(path(record["manifest_path"]).name == "Cargo.toml", "invalid projected Cargo manifest")
        expected["manifest_path"] = record["manifest_path"]
        expected["target"]["src_path"] = record["target"]["src_path"]
        expected["rch"] = extension
        require(record == expected, "RCH record changed fields outside the producer's path projection")
        payload = File(executable, MAX_PAYLOAD, True)
        payload.blake3(extension["executable_blake3"])
        outputs.append(payload)
        binary_evidence.append({"name": name, "blake3": extension["executable_blake3"],
            "worker_record_sha256": hashlib.sha256(json.dumps(original, sort_keys=True,
                separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()})
    # RCH can retain both a lexical worker source root and its physical root.
    # Its public binding names only the latter. Accept one consistent alias,
    # with all source-relative projections rooted in the pinned local checkout.
    def source_projection(local_root):
        aliases = set()
        for old, new in projections:
            try:
                relative = below(new, local_root)
            except ValueError:
                return False
            old_path = path(old)
            if old_path.parts[-len(relative.parts):] != relative.parts:
                return False
            aliases.add(str(old_path.parents[len(relative.parts) - 1]))
        return len(aliases - {remote_project}) <= 1
    require(any(source_projection(root) for root in candidates), "inconsistent worker-to-checkout source projection")
    revalidate()
    staged = path(output) / "bin"
    os.mkdir(str(staged), 0o700)
    stage_fd = directory(str(staged))
    paths = []
    for name, payload, evidence in zip(names, outputs, binary_evidence):
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o700, dir_fd=stage_fd)
        with os.fdopen(fd, "wb") as destination:
            for chunk in payload.chunks():
                destination.write(chunk)
            destination.flush()
            os.fsync(destination.fileno())
        copied = str(staged / name)
        File(copied, MAX_PAYLOAD, True).blake3(evidence["blake3"])
        paths.append(copied)
    revalidate()
    metadata = {"contract": "rch-cargo-json-delivery", "wrapper_id": wrapper, "build_id": receipt["build_id"],
        "compiler_identity_attested": False, "source_content_attested": False,
        "stdout_blake3": receipt["blake3"], "stderr_blake3": stderr["blake3"],
        "stdout_size_bytes": stdout_file.before.st_size, "stderr_size_bytes": stderr["bytes"],
        "binaries": binary_evidence}
    with open(output + "/rch-delivery.json", "x", encoding="utf-8") as destination:
        json.dump(metadata, destination, separators=(",", ":"))
        destination.write("\n")
    print("\n".join(paths))
except (OSError, ValueError, KeyError, TypeError, AttributeError, UnicodeError, subprocess.SubprocessError) as error:
    print("[source-build] RCH Cargo delivery validation failed: " + str(error), file=sys.stderr)
    sys.exit(6)
finally:
    for source in files:
        os.close(source.fd)
    for fd, _, _, _ in directories.values():
        os.close(fd)
PY
)

# Admit local Cargo executable providers before any build script runs. Metadata
# supplies Cargo's workspace/default-member selection; the fetched Git graph
# supplies authority for the workspace lock, package manifests and entry files.
# A --bin name alone can otherwise compile an absolute external source path
# while the resulting receipt still identifies the fetched repository commit.
_isb_cargo_source_context() (
    local root="$1" tree="$2" output="$3" limit="$4" package="$5" windows="$6" names="$7"
    local metadata="$output/cargo-metadata.json" cargo_sources="$output/cargo-sources.json"
    local manifest="$tree/Cargo.toml" workspace path status=0
    if $windows; then
        command -v cygpath >/dev/null 2>&1 || return 3
        manifest=$(cygpath -am "$manifest") || return 6
    fi
    _isb_cargo_metadata() {
        # Cargo warnings belong in the retained log, not in the JSON document.
        # --no-deps describes declared targets without resolving features.
        # In particular, a bare feature selected by build --package may not
        # belong to the current root package. Leave feature selection to the
        # unchanged build command and bind its actual artifact afterwards.
        cargo metadata --format-version=1 --no-deps --locked \
            --manifest-path "$manifest" > "$metadata"
    }
    _isb_run "$limit" "$output/cargo-metadata.log" _isb_cargo_metadata || {
        status=$?; [[ "$status" == 5 ]] && return 5; return 6;
    }
    if ! jq -e --arg manifest "$manifest" --arg package "$package" \
        --argjson windows "$windows" --argjson names "$names" '
        def native_path:
            if $windows then gsub("\\\\"; "/") | ascii_downcase else . end;
        def source_path:
            type == "string" and length > 0 and (test("[[:cntrl:]]") | not);
        select(type == "object" and .version == 1 and
            (.workspace_root | source_path) and
            (.workspace_members | type == "array" and length > 0) and
            (.packages | type == "array" and length > 0)) |
        . as $workspace |
        [.packages[] | select(.id as $id | $workspace.workspace_members | index($id) != null)] as $members |
        (if $package != "" then $members | map(select(.name == $package))
         elif ($names | length) > 1 then $members
         elif ($manifest | native_path) == (($workspace.workspace_root + "/Cargo.toml") | native_path) and
             ($workspace.workspace_default_members | type) == "array" then
             $members | map(select(.id as $id | $workspace.workspace_default_members | index($id) != null))
         else [$members[] | select((.manifest_path | native_path) == ($manifest | native_path))] as $current |
             if ($current | length) == 1 then $current
             elif ($workspace.workspace_default_members | type) == "array" then
                 $members | map(select(.id as $id | $workspace.workspace_default_members | index($id) != null))
             else $members end
         end) as $packages |
        select($package == "" or ($packages | length) == 1) |
        {workspace_root:$workspace.workspace_root,
         providers:[$names[] as $name | $packages[] as $package | $package.targets[] |
             select(.name == $name and (.kind | type == "array" and index("bin") != null)) |
             {name:$name,package_id:$package.id,manifest_path:$package.manifest_path,src_path:.src_path}]} |
        select(all(.providers[]; (.package_id | type == "string" and length > 0) and
            (.manifest_path | source_path) and (.src_path | source_path))) |
        .providers as $providers |
        select(all($names[]; . as $name | any($providers[]; .name == $name)))
    ' "$metadata" > "$cargo_sources"; then
        _isb_log 'Cargo did not identify the selected source executable providers'
        return 6
    fi
    _isb_cargo_source_file() {
        local file="$1" relative directory
        if $windows; then file=$(cygpath -au -- "$file") || return 1; fi
        [[ "$file" == "$root/"* ]] || return 1
        relative="${file#"$root"/}"
        directory=.
        [[ "$relative" != */* ]] || directory="${relative%/*}"
        # Reuse the checkout-bounded directory walker. It resolves harmless
        # dot components without following links or crossing the fetched root;
        # filenames themselves may contain spaces or other valid Git bytes.
        directory=$(_isb_go_directory "$root" "$root" "$directory") || return 1
        _isb_source_committed_file "$root" "$directory/${relative##*/}" >/dev/null
    }
    workspace=$(jq -r '.workspace_root' "$cargo_sources") || return 6
    if ! _isb_cargo_source_file "$manifest" ||
       ! _isb_cargo_source_file "$workspace/Cargo.toml" ||
       ! _isb_cargo_source_file "$workspace/Cargo.lock"; then
        _isb_log 'Rust source builds require a committed manifest and workspace Cargo.lock inside the pinned checkout'
        return 4
    fi
    jq -r '[.providers[] | .manifest_path, .src_path] | unique[]' "$cargo_sources" \
        > "$output/cargo-source-paths" || return 6
    while IFS= read -r path; do
        if ! _isb_cargo_source_file "$path"; then
            _isb_log "Cargo executable provider is outside the committed source graph: $path"
            return 6
        fi
    done < "$output/cargo-source-paths"
)

# Build only the requested executable family, into a new private output directory.
# Never run arbitrary command strings from installer configuration.
_isb_compile() (
    local language="$1" tree="$2" output="$3" binary="$4" entry="$5" package="$6" limit="$7"
    shift 7
    local -a binaries=() targets=() entries=() features=()
    local no_default_features=false cargo_selection=false feature
    while (($#)); do
        case "$1" in
            --feature)
                [[ $# -ge 2 ]] || return 4
                features+=("$2"); cargo_selection=true; shift 2 ;;
            --no-default-features)
                no_default_features=true; cargo_selection=true; shift ;;
            -*) return 4 ;;
            *) binaries+=("$1"); shift ;;
        esac
    done
    _isb_cargo_features_valid ${features[@]+"${features[@]}"} || return 4
    [[ "$language" == rust || "$cargo_selection" == false ]] || return 4
    ((${#binaries[@]})) || binaries=("$binary")
    local status=0 host target name mod=readonly resolved_entries selected_entry index log
    cd "$tree" || return 4
    binary=$(_isb_binary_name "$binary") || return 4
    case "$language" in
        rust)
            [[ -f Cargo.toml && ! -L Cargo.toml ]] || return 4
            local rustc_command rch_delivery=false dependency delivered_paths
            if [[ "${RCH_CARGO_JSON_STDOUT:-}" == 1 ]]; then
                rch_delivery=true
                [[ "${RCH_REQUIRE_REMOTE:-}" == 1 ]] || {
                    _isb_log 'Explicit RCH Cargo delivery requires RCH_REQUIRE_REMOTE=1; local fallback is not admitted'
                    return 4
                }
                for dependency in python3 b3sum cargo rustc; do
                    command -v "$dependency" >/dev/null 2>&1 || {
                        _isb_log "Explicit RCH Cargo delivery requires $dependency; install it before retrying"
                        case "$dependency" in cargo|rustc)
                            _isb_log 'Prepare the RCH Cargo shim and local Rust host probe; this mode does not bootstrap a plain local Cargo'
                            ;;
                        esac
                        return 3
                    }
                done
            fi
            # Bootstrap prepends a private plain Cargo, replacing the caller's
            # RCH shim. Explicit delivery requires an already usable client
            # route and host probe, even when local bootstrap was authorized.
            if ! $rch_delivery; then
                _isb_prepare_toolchain "$language" "$tree" "$output" "$limit" || return $?
            fi
            # rustup proxies may auto-install a missing repository-selected
            # toolchain. Any separately authorized bootstrap is already active;
            # never let a proxy modify an existing global installation.
            # https://rust-lang.github.io/rustup/environment-variables.html
            export RUSTUP_AUTO_INSTALL=0
            # Use the compiler whose identity is recorded below, not an
            # inherited Cargo-only RUSTC or build-cache wrapper. Preserve
            # compiler homes and dependency caches, as the Windows source
            # engine does, while keeping this attempt's outputs private.
            rustc_command=$(command -v rustc) || return 3
            # In RCH mode the local probe establishes the requested host, not
            # the remote compiler identity. Preserve caller RUSTC policy;
            # do not export a local absolute compiler path to the worker.
            if ! $rch_delivery; then
                export RUSTC="$rustc_command"
            fi
            export RUSTC_WRAPPER='' RUSTC_WORKSPACE_WRAPPER=''
            # Empty flag variables still suppress .cargo/config.toml. Remove
            # ambient overrides so the pinned project's cfg/link flags apply.
            unset RUSTFLAGS CARGO_ENCODED_RUSTFLAGS CARGO_BUILD_RUSTFLAGS
            _isb_run "$limit" "$output/compiler.log" "$rustc_command" -vV || {
                status=$?; [[ $status == 5 ]] && return 5
                if $rch_delivery; then
                    _isb_log 'RCH delivery requires a usable local Rust host probe; prepare it before retrying (isolated bootstrap would replace the RCH Cargo shim)'
                    return 3
                fi
                return 6
            }
            host=$(sed -n 's/^host: //p' "$output/compiler.log")
            [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 6
            export CARGO_BUILD_TARGET="$host" CARGO_TARGET_DIR="$output/target" CARGO_INCREMENTAL=0
            local artifact_path cargo_name windows_paths=false
            case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) windows_paths=true ;; esac
            local message_format=json-render-diagnostics
            if $rch_delivery; then
                $windows_paths && { _isb_log 'RCH Cargo delivery requires a POSIX installer host'; return 4; }
                message_format=json,json-render-diagnostics
            fi
            local -a args=(build --locked --release "--message-format=$message_format"
                --target "$host" --target-dir "$output/target")
            local -a cargo_names=()
            for feature in ${features[@]+"${features[@]}"}; do args+=(--features "$feature"); done
            $no_default_features && args+=(--no-default-features)
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
                cargo_names+=("$cargo_name")
                targets+=("$output/target/$host/release/$name")
            done
            local source_context=/dev/null requested_names
            if ! $rch_delivery && [[ -n "${_ISB_CHECKOUT_ROOT:-}" ]]; then
                requested_names=$(printf '%s\n' "${cargo_names[@]}" | jq -Rsc 'split("\n")[:-1]') || return 1
                _isb_cargo_source_context "$_ISB_CHECKOUT_ROOT" "$tree" "$output" "$limit" \
                    "$package" "$windows_paths" "$requested_names" || return $?
                source_context="$output/cargo-sources.json"
            fi
            _isb_run "$limit" "$output/build.log" cargo "${args[@]}" || { status=$?; [[ $status == 5 ]] && return 5; return 6; }
            if $rch_delivery; then
                delivered_paths=$(_isb_rch_cargo_outputs "$tree" "$output" "$host" "$limit" "${binaries[@]}") || return $?
                targets=()
                while IFS= read -r target; do targets+=("$target"); done <<< "$delivered_paths"
            else
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
                    --argjson windows "$windows_paths" --slurpfile sources "$source_context" '
                    def native_path:
                        if $windows then gsub("\\\\"; "/") | ascii_downcase else . end;
                    [split("\n")[] | fromjson? |
                        select(.reason == "compiler-artifact" and .target.name == $name and
                            (.target.kind | type == "array" and index("bin") != null))] |
                    length == 1 and (.[0].executable | type == "string") and
                    (.[0].executable | native_path) == ($path | native_path) and
                    (.[0].package_id | type == "string" and length > 0) and
                    (.[0] as $built | ($sources | length) == 0 or
                        any($sources[0].providers[]; .name == $name and .package_id == $built.package_id and
                            (.manifest_path | native_path) == ($built.manifest_path | native_path) and
                            (.src_path | native_path) == ($built.target.src_path | native_path)))
                ' "$output/build.log" >/dev/null; then
                    _isb_log "Cargo did not identify exactly one executable provider for: $name"
                    return 6
                fi
            done
            fi
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
            local bun_root checkout_root="${_ISB_CHECKOUT_ROOT:-$tree}"
            [[ -z "${_ISB_CHECKOUT_ROOT:-}" ]] ||
                _isb_source_committed_file "$checkout_root" "$tree/package.json" >/dev/null || return 4
            bun_root=$(_isb_bun_dependency_root "$checkout_root" "$tree") || return $?
            unset NODE_OPTIONS BUN_OPTIONS
            _isb_prepare_toolchain "$language" "$bun_root" "$output" "$limit" || return $?
            _isb_run "$limit" "$output/compiler.log" bun --version || { status=$?; [[ $status == 5 ]] && return 5; return 6; }
            _isb_bun_context "$checkout_root" "$tree" "$bun_root" "$output" "$limit" || return $?
            _isb_run "$limit" "$output/dependencies.log" _isb_in_dir "$bun_root" bun install --frozen-lockfile || {
                status=$?; [[ $status == 5 ]] && return 5; return 6;
            }
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
    # Acquisition helpers already isolate their own Git commands. Keep that
    # isolation for compilers and build scripts too: Go, for example, shells
    # out to Git when embedding its VCS revision. Inherited repository selectors
    # must not stamp a pinned build with the caller's HEAD or modify its index.
    # This function is a subshell; the caller's environment stays unchanged.
    # User credential/URL configuration remains available for dependencies.
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
    unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
    unset GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
    unset GIT_IMPLICIT_WORK_TREE GIT_PREFIX GIT_SHALLOW_FILE GIT_GRAFT_FILE
    unset GIT_NAMESPACE GIT_REPLACE_REF_BASE GIT_TEMPLATE_DIR
    local allow=false subdir=. entry='' package='' limit=3600 _ISB_INSTALL_TOOLCHAIN=false
    local no_default_features=false cargo_selection=false cargo_features_json='[]' feature
    local -a binaries=() features=() cargo_options=()
    while (($#)); do
        case "$1" in
            --allow-build) allow=true; shift ;;
            --install-toolchain) _ISB_INSTALL_TOOLCHAIN=true; shift ;;
            --no-default-features) no_default_features=true; cargo_selection=true; shift ;;
            --subdir|--entry|--package|--timeout|--bin|--feature)
                [[ $# -ge 2 && -n "$2" ]] || return 4
                case "$1" in
                    --subdir) subdir="$2" ;;
                    --entry) entry="$2" ;;
                    --package) package="$2" ;;
                    --timeout) limit="$2" ;;
                    --bin) binaries+=("$2") ;;
                    --feature) features+=("$2"); cargo_selection=true ;;
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
    [[ "$language" == rust || "$cargo_selection" == false ]] || {
        _isb_log 'Cargo feature selection is only supported for Rust'; return 4;
    }
    _isb_cargo_features_valid ${features[@]+"${features[@]}"} || {
        _isb_log 'Cargo features must be at most 64 unique feature or package/feature names, each at most 128 characters'; return 4;
    }
    for feature in ${features[@]+"${features[@]}"}; do cargo_options+=(--feature "$feature"); done
    $no_default_features && cargo_options+=(--no-default-features)
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
    for tool in git jq ps cmp; do
        command -v "$tool" >/dev/null 2>&1 || { _isb_log "Required source-build dependency missing: $tool"; return 3; }
    done
    if ((${#features[@]})); then
        cargo_features_json=$(printf '%s\n' "${features[@]}" | jq -Rsc 'split("\n")[:-1]') || return 1
    fi
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
    local _ISB_SOURCE_GRAPH='' graph_dir="$destination/source-graph" source_state final_source_state
    mkdir "$output" || return 1
    _isb_log "Fetching $repo at $ref into an isolated checkout"
    _isb_run "$limit" "$destination/fetch.log" _isb_checkout_source "$repo" "$ref" "$tree" "$graph_dir" || {
        status=$?; case "$status" in 1|3|4|5) return "$status" ;; *) return 8 ;; esac
    }
    commit=$(_isb_git -C "$tree" -c "core.worktree=$tree" rev-parse --verify 'HEAD^{commit}') || return 8
    _ISB_SOURCE_GRAPH=$(jq -ce '.' "$graph_dir/repositories.json") || return 8
    source_state=$(_isb_verify_source_graph "$tree" "$_ISB_SOURCE_GRAPH" "$graph_dir" initial) || return $?
    _isb_path_in_tree "$tree" "$subdir" && [[ -d "$tree/$subdir" ]] || return 4
    local build_root _ISB_CHECKOUT_ROOT="$tree"
    build_root=$(cd "$tree/$subdir" && pwd -P) || return 4
    _isb_log "Building ${binary_names[*]} from pinned commit $commit ($language)"
    payloads=$(_isb_compile "$language" "$build_root" "$output" "$binary" "$entry" "$package" "$limit" \
        ${cargo_options[@]+"${cargo_options[@]}"} "${binaries[@]}") || return $?
    # Preserve the source pin through compilation. Build scripts may not move
    # HEAD or modify tracked inputs and then claim they built the pinned tree.
    final_source_state=$(_isb_verify_source_graph "$tree" "$_ISB_SOURCE_GRAPH" "$graph_dir") || return $?
    [[ "$final_source_state" == "$source_state" ]] || {
        _isb_log 'Build changed tracked source bytes, links or executable modes'; return 6;
    }
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
    local toolchain_receipt=null go_context_file=/dev/null bun_context_file=/dev/null rch_context_file=/dev/null
    if [[ -f "$output/toolchain/receipt.json" ]]; then
        toolchain_receipt=$(jq -ce 'del(.root,.bin_dir)' "$output/toolchain/receipt.json") || return 7
    fi
    if [[ "$language" == go ]]; then
        go_context_file="$output/go-context.json"
        [[ -f "$go_context_file" && ! -L "$go_context_file" ]] || return 7
    fi
    if [[ "$language" == bun || "$language" == typescript ]]; then
        bun_context_file="$output/bun-context.json"
        [[ -f "$bun_context_file" && ! -L "$bun_context_file" ]] || return 7
    fi
    if [[ "$language" == rust && "${RCH_CARGO_JSON_STDOUT:-}" == 1 ]]; then
        rch_context_file="$output/rch-delivery.json"
        [[ -f "$rch_context_file" && ! -L "$rch_context_file" ]] || return 7
    fi
    receipt=$(jq -c --arg repo "$repo" --arg ref "$ref" --arg commit "$commit" \
        --arg language "$language" --arg path "$payload" --arg sha "$sha" --argjson size "$size" \
        --argjson binaries "$binaries_json" \
        --argjson cargo_features "$cargo_features_json" --argjson cargo_no_default_features "$no_default_features" \
        --argjson toolchain "$toolchain_receipt" \
        --slurpfile go_context "$go_context_file" \
        --slurpfile bun_context "$bun_context_file" \
        --slurpfile rch_context "$rch_context_file" \
        --arg compiler "$(cat "$output/compiler.log")" \
        '[.[] | select(.path != "")] as $submodules |
         {schema_version:1,method:"source",repository:$repo,requested_ref:$ref,source_commit:$commit,
          language:$language,path:$path,sha256:$sha,size_bytes:$size,
          compiler:(if $rch_context[0] == null then $compiler else "RCH remote compilation (compiler identity not attested)" end),
          binaries:$binaries,signed_release:false} +
          (if $language == "rust" then {cargo_features:$cargo_features,
            cargo_no_default_features:$cargo_no_default_features} else {} end) +
          (if $toolchain == null then {} else {toolchain:$toolchain} end) +
          (if $go_context[0].go_workspace == null then {} else {go_workspace:$go_context[0].go_workspace} end) +
          ($bun_context[0] // {}) +
          (if $rch_context[0] == null then {} else {rch_delivery:($rch_context[0] + {local_rustc_probe:$compiler})} end) +
          (if ($submodules | length) == 0 then {} else {submodules:$submodules} end)' <<< "$_ISB_SOURCE_GRAPH") || return 1
    (set -C; printf '%s\n' "$receipt" > "$destination/receipt.json") || return 1
    _isb_log "Built $binary from source; SHA256 $sha (not a signed release)"
    printf '%s\n' "$receipt"
)
