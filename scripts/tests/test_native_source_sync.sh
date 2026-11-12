#!/usr/bin/env bash
# Real Git/Cargo/rsync through ordinary source sync, build checkpoints and
# resume. Only SSH/SCP transport stays local; a receiver disconnect is real
# transfer failure. No compiler, source gate, scheduler or receipt is mocked.
# Use --strict-publication-only for the successful strict build and seal case.
# Use --strict-variants-only for genuine GNU/musl failure, resume and publication.
# Use --strict-mixed-protocol-only for mixed-platform receipt/selection controls;
# this mode never claims a Darwin compiler or artifact execution.
# Use --git-selection-only for genuine Git/rsync selection without a compiler.
# Use --ownership-only for actual rsync/tar/Git source ownership checks. Running
# as root with a full UID map also covers UID 501 and a non-root SSH receiver.
# Use --windows-source-links-only for real Git archives and PowerShell regular
# copy materialization. On Unix this proves the receiver logic, not NTFS.
# Use --ordinary-inputs-only for actual source selection and immutable resume
# bindings; --ordinary-resume-only exercises a real Go matrix through cmd_build.
# Use --go-siblings-only for real parallel Go replacements and workspaces,
# including the source selection and receipts of private output stages.
# Use --windows-strict-go-only for genuine PowerShell source staging and Go
# Windows PE collection; Unix transport adapters do not qualify native NTFS.
# Use --windows-strict-bun-only for the same source custody with real Bun and
# TypeScript Windows PE builds, including pinned sibling imports and retries.
# Use --strict-go-siblings-only for pinned Go replacements/workspaces through
# strict snapshots, private output stages, publication and tamper refusals.
# Use --strict-go-admission-only for conservative parallel-output admission,
# sibling drift and layout refusal checks; --strict-go-matrix-only proves
# simultaneous pinned amd64/386 Go builds with private verified stages.
# Use --strict-go-context-only for actual Go policy and retained-output admission.
# Use --strict-go-paths-only for pinned local Go dependency boundaries.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
ROOT="${DSR_TEST_ROOT:-$ROOT}"

test_strict_go_source_paths() (
    local dependency work sha dep_sha config status=0 checks=0 failures=0 item expected
    local selection="${1:-all}"
    for dependency in bash git jq yq python3 go tar; do
        command -v "$dependency" >/dev/null || { printf 'SKIP: strict Go paths require %s\n' "$dependency"; return 77; }
    done
    [[ $(uname -s)/$(uname -m) == Linux/x86_64 && $(go version) == 'go version go'* ]] || return 77
    work=$(mktemp -d "${DSR_TEST_DISK_ROOT:-${TMPDIR:-/tmp}}/dsr-go-paths.XXXXXXXX") || return 1
    printf 'Strict Go source path evidence: %s\n' "$work"
    mkdir -p "$work/config/repos.d" "$work/source" "$work/dep" "$work/outside" "$work/stages" || return 1
    export DSR_CONFIG_DIR="$work/config" ACT_CONFIG_DIR="$work/config" ACT_REPOS_DIR="$work/config/repos.d"
    export DSR_STATE_DIR="$work/state" DSR_CACHE_DIR="$work/cache"
    export DSR_HOSTS_FILE="$work/config/hosts.yaml" DSR_REPOS_FILE="$work/config/repos.yaml"
    export DSR_DISABLE_HOST_SELECTOR=1 NO_COLOR=1 GOMAXPROCS=1
    printf 'module example.local/dep\n\ngo 1.19\n' > "$work/dep/go.mod"
    printf 'package dep\nfunc Value() string { return "pinned-input" }\n' > "$work/dep/dep.go"
    printf 'module example.local/dep\n\ngo 1.19\n' > "$work/outside/go.mod"
    printf 'package dep\nfunc Value() string { return "UNPINNED-EXTERNAL-INPUT" }\n' > "$work/outside/dep.go"
    printf 'module example.local/paths\n\ngo 1.19\nrequire example.local/dep v0.0.0\nreplace example.local/dep => %s\n' \
        "$work/outside" > "$work/source/go.mod"
    printf 'package main\nimport "example.local/dep"\nfunc main() { println(dep.Value()) }\n' > "$work/source/main.go"
    for item in source dep; do
        git -C "$work/$item" init -q -b main || return 1
        git -C "$work/$item" add . || return 1
        git -C "$work/$item" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm pinned || return 1
    done
    git -C "$work/source" tag v1.0.0 || return 1
    dep_sha=$(git -C "$work/dep" rev-parse HEAD) || return 1
    jq -n --arg work "$work" '{schema_version:"1.0.0",hosts:{localnative:{
        platform:"linux/amd64",connection:"local",concurrency:1,build_root:($work+"/stages")}},
        platform_mapping:{"linux/amd64":"localnative"}}' > "$DSR_HOSTS_FILE" || return 1
    config="$ACT_REPOS_DIR/paths.yaml"
    jq -n --arg work "$work" --arg path "$PATH" --arg sha "$dep_sha" \
        --arg cache "${DSR_TEST_GOCACHE:-$work/go-cache}" '{
        tool_name:"paths",repo:"example/paths",local_path:($work+"/source"),language:"go",binary_name:"paths",
        targets:["linux/amd64"],act_job_map:{"linux/amd64":null},hosts:{"linux/amd64":"localnative"},
        sibling_crates:[{local_path:($work+"/dep"),relative_path:"dep",revision:$sha}],
        build_cmd:"printf compiler\\n >> \"$PROBE_EVENTS\"; go build -p=1 -buildvcs=false -o paths .",
        env:{PATH:$path,PROBE_EVENTS:($work+"/compiler-events"),GOCACHE:$cache,GOMAXPROCS:"1",
          CGO_ENABLED:"0",GOPROXY:"off",GOSUMDB:"off"},
        release_contract:{checksum_sidecar:"sha256",exact_primary_assets:{"linux/amd64":"paths-linux-amd64"}}}
        ' > "$config" || return 1
    # shellcheck source=../../src/logging.sh
    source "$ROOT/src/logging.sh"
    # shellcheck source=../../src/config.sh
    source "$ROOT/src/config.sh"
    # shellcheck source=../../src/build_state.sh
    source "$ROOT/src/build_state.sh"
    # shellcheck source=../../src/act_runner.sh
    source "${DSR_TEST_ACT_RUNNER:-$ROOT/src/act_runner.sh}"
    # shellcheck source=../../src/artifact_naming.sh
    source "$ROOT/src/artifact_naming.sh"
    # shellcheck source=../../src/host_selector.sh
    source "$ROOT/src/host_selector.sh"
    # shellcheck source=../../src/host_health.sh
    source "$ROOT/src/host_health.sh"
    # shellcheck source=../../src/git_ops.sh
    source "$ROOT/src/git_ops.sh"
    # shellcheck source=../../src/packaging.sh
    source "$ROOT/src/packaging.sh"
    host_health_is_ready() { return 0; }
    selector_acquire_slot() { return 0; }
    selector_release_slot() { return 0; }
    build_state_init || return 1
    export SCRIPT_DIR="$ROOT" JSON_MODE=true DRY_RUN=false VERBOSE=false DSR_VERSION=fixture DSR_KEEP_BUILD_STAGES=1
    declare -A _DSR_LOADED_MODULES=([packaging]=1 [artifact_naming]=1)
    # shellcheck disable=SC1090 # Actual public build and publication consumers.
    source <(awk '/^(_dsr_require|cmd_build|_release_sha256|_release_require_publishable_artifacts)\(\) \{/{copy=1} copy{print} copy && /^\}/{copy=0}' "$ROOT/dsr") || return 1
    # shellcheck disable=SC1090
    source <(awk '/^json_envelope\(\) \{/{copy=1} copy{print} copy && /^# ====/{exit}' "$ROOT/dsr") || return 1
    check_go_path() {
        local label="$1"; shift
        checks=$((checks + 1))
        if "$@"; then printf 'PASS: Go source paths: %s\n' "$label"
        else failures=$((failures + 1)); printf 'FAIL: Go source paths: %s\n' "$label" >&2; fi
    }
    parse_go_path_fixture() {
        GOENV=off GOFLAGS='' GOWORK=off GOTOOLCHAIN=local GOTELEMETRY=off go "$@" >/dev/null
    }
    printf 'BOUNDARY: fixture host health/capacity only; real pinned Git, cmd_build, Go compilation, collection and publication admission\n'
    if [[ "$selection" != pinned ]]; then
    cmd_build paths --version 1.0.0 --output-dir "$work/external-output" \
        > "$work/external.json" 2> "$work/external.log" || status=$?
    check_go_path 'public strict build refuses an absolute unpinned replacement' test "$status" -ne 0
    check_go_path 'local source refusal identifies the Go path boundary' grep -q 'Strict Go source paths' "$work/external.log"
    check_go_path 'unpinned replacement never reaches the compiler' test ! -e "$work/compiler-events"
    if [[ -x "$work/external-output/paths-linux-amd64" ]]; then
        printf 'COUNTEREXAMPLE: genuine strict executable says %s\n' "$("$work/external-output/paths-linux-amd64" 2>&1)"
        _release_require_publishable_artifacts "$work/external-output" "$work/external-output/paths-v1.0.0-manifest.json" true &&
            printf 'COUNTEREXAMPLE: unpinned executable passed actual release admission\n'
    fi
    if [[ "$selection" == external ]]; then
        printf 'Strict Go source paths: %s checks, %s failures; evidence %s\n' "$checks" "$failures" "$work"
        [[ "$failures" -eq 0 ]]; return $?
    fi
    fi
    printf 'module example.local/paths\n\ngo 1.19\nrequire example.local/dep v0.0.0\nreplace example.local/dep => ../dep\n' > "$work/source/go.mod"
    git -C "$work/source" add go.mod || return 1
    git -C "$work/source" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm pinned-replacement || return 1
    git -C "$work/source" tag v1.0.1 || return 1
    sha=$(git -C "$work/source" rev-parse HEAD) || return 1
    status=0
    cmd_build paths --version 1.0.1 --output-dir "$work/pinned-output" \
        > "$work/pinned.json" 2> "$work/pinned.log" || status=$?
    check_go_path 'public strict build preserves a pinned sibling replacement' test "$status" -eq 0
    if [[ "$status" -ne 0 ]]; then cat "$work/pinned.log" >&2; return 1; fi
    check_go_path 'actual admitted binary executes pinned dependency bytes' \
        test "$("$work/pinned-output/paths-linux-amd64" 2>&1)" = pinned-input
    check_go_path 'pinned output passes the actual release admission consumer' \
        _release_require_publishable_artifacts "$work/pinned-output" "$work/pinned-output/paths-v1.0.1-manifest.json" true
    act_load_repo_config paths || return 1
    for item in '../dep' '"\x2e\x2e/dep"' 'example.local/versioned v1.2.3' '../outside' '../../outside' \
        '"\u002foutside"' '"C:/outside"' '../dep/../../outside' './linked'; do
        expected=4
        case "$item" in '../dep'|'"\x2e\x2e/dep"'|'example.local/versioned v1.2.3') expected=0 ;; esac
        if [[ "$item" == ./linked ]]; then ln -s ../dep "$work/source/linked" || return 1; fi
        printf 'module example.local/paths\n\ngo 1.19\nrequire example.local/dep v0.0.0\nreplace (\n example.local/dep => %s // path\n)\n' \
            "$item" > "$work/source/go.mod"
        git -C "$work/source" add . || return 1
        git -C "$work/source" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm path-control || return 1
        sha=$(git -C "$work/source" rev-parse HEAD) || return 1
        status=0
        _act_strict_go_build_env paths "$sha" v1.0.1 '/private/stage/source' '' \
            > "$work/path-result.json" 2> "$work/path-result.log" || status=$?
        check_go_path "replacement $item observes pinned graph boundaries" test "$status" -eq "$expected"
        if [[ "$expected" -eq 0 ]]; then
            check_go_path "actual Go parser accepts replacement $item" \
                parse_go_path_fixture mod edit -json "$work/source/go.mod"
        fi
    done
    printf 'module example.local/paths\n\ngo 1.19\nrequire example.local/dep v0.0.0\nreplace example.local/dep => ../dep\n' > "$work/source/go.mod"
    for item in '../dep' '"\x2e\x2e/dep"' '../outside' '"\u002foutside"' './linked' '../dep/../../outside'; do
        expected=4
        case "$item" in '../dep'|'"\x2e\x2e/dep"') expected=0 ;; esac
        printf 'go 1.19\nuse (\n .\n %s // workspace module\n)\n' "$item" > "$work/source/go.work"
        git -C "$work/source" add . || return 1
        git -C "$work/source" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm workspace-control || return 1
        sha=$(git -C "$work/source" rev-parse HEAD) || return 1
        status=0
        _act_strict_go_build_env paths "$sha" v1.0.1 'C:/private/stage/source' '' \
            > "$work/workspace-result.json" 2> "$work/workspace-result.log" || status=$?
        check_go_path "workspace $item observes the same Windows source graph boundary" test "$status" -eq "$expected"
        if [[ "$expected" -eq 0 ]]; then
            check_go_path "actual Go parser accepts workspace $item" \
                parse_go_path_fixture work edit -json "$work/source/go.work"
        fi
    done
    printf 'go 1.19\nuse (\n .\n ../dep\n)\nreplace example.local/dep => %s\n' "$work/outside" > "$work/source/go.work"
    git -C "$work/source" add go.work || return 1
    git -C "$work/source" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm workspace-replacement || return 1
    sha=$(git -C "$work/source" rev-parse HEAD) || return 1
    status=0
    _act_strict_go_build_env paths "$sha" v1.0.1 '/private/stage/source' '' \
        > "$work/workspace-result.json" 2> "$work/workspace-result.log" || status=$?
    check_go_path 'workspace replacement cannot escape otherwise pinned use entries' test "$status" -eq 4
    printf 'Strict Go source paths: %s checks, %s failures; evidence %s\n' "$checks" "$failures" "$work"
    [[ "$failures" -eq 0 ]]
)

test_strict_go_context() (
    local dependency work runtime config sha status checks=0 failures=0 stage result
    local run state_file sidecar original_state original_sidecar before_state before_events kind
    for dependency in bash git jq yq python3 go tar; do
        command -v "$dependency" >/dev/null || { printf 'SKIP: strict Go policy requires %s\n' "$dependency"; return 77; }
    done
    [[ $(uname -s)/$(uname -m) == Linux/x86_64 && $(go version) == 'go version go'* ]] || return 77
    work=$(mktemp -d "${DSR_TEST_DISK_ROOT:-${TMPDIR:-/tmp}}/dsr-go-policy.XXXXXXXX") || return 1
    runtime=$(mktemp -d "${TMPDIR:-/tmp}/dsr-go-policy-runtime.XXXXXXXX") || return 1
    printf 'Strict Go policy source: %s; evidence: %s\n' "$work" "$runtime"
    mkdir -p "$runtime/config/repos.d" "$work/source" "$work/stages" "$runtime/outside" || return 1
    export DSR_CONFIG_DIR="$runtime/config" ACT_CONFIG_DIR="$runtime/config" ACT_REPOS_DIR="$runtime/config/repos.d"
    export DSR_STATE_DIR="$runtime/state" DSR_CACHE_DIR="$runtime/cache"
    export DSR_HOSTS_FILE="$runtime/config/hosts.yaml" DSR_REPOS_FILE="$runtime/config/repos.yaml"
    export DSR_DISABLE_HOST_SELECTOR=1 RCH_DISABLED=1 RCH_CARGO_WRAPPER_BYPASS=1 NO_COLOR=1 GOMAXPROCS=1
    export DSR_GO_RECIPE_MARKER=recipe-env-expanded
    printf 'module example.local/context\n\ngo 1.19\n' > "$work/source/go.mod"
    printf 'package main\nvar message = "pinned-default"\nfunc main() { println(message) }\n' > "$work/source/main.go"
    git -C "$work/source" init -q -b main || return 1
    git -C "$work/source" add . || return 1
    git -C "$work/source" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm pinned-module || return 1
    git -C "$work/source" tag v1.0.0 || return 1
    sha=$(git -C "$work/source" rev-parse HEAD) || return 1
    jq -n --arg work "$work" '{schema_version:"1.0.0",hosts:{localnative:{
        platform:"linux/amd64",connection:"local",concurrency:1,build_root:($work+"/stages")}},
        platform_mapping:{"linux/amd64":"localnative","linux/386":"localnative"}}' > "$DSR_HOSTS_FILE" || return 1
    config="$ACT_REPOS_DIR/context.yaml"
    jq -n --arg work "$work" --arg runtime "$runtime" --arg path "$PATH" \
        --arg cache "${DSR_TEST_GOCACHE:-$runtime/go-cache}" '{
        tool_name:"context",repo:"example/context",local_path:($work+"/source"),language:"go",binary_name:"context",
        targets:["linux/amd64"],act_job_map:{"linux/amd64":null},hosts:{"linux/amd64":"localnative"},
        build_cmd:"printf \"%s\\n\" \"$DSR_TARGET_ARCH\" >> \"$PROBE_EVENTS\"; printf %s \"$PROBE_EXPANDED\" > \"$PROBE_EXPANSION_FILE\"; go build -p=1 -buildvcs=false -o context .",
        env:{PATH:$path,PROBE_EVENTS:($runtime+"/compiler-events"),GOCACHE:$cache,GOMAXPROCS:"1",
          PROBE_EXPANDED:"$DSR_GO_RECIPE_MARKER",PROBE_EXPANSION_FILE:($runtime+"/recipe-expansion"),
          CGO_ENABLED:"0",GOPROXY:"off",GOSUMDB:"off"},
        release_contract:{checksum_sidecar:"sha256",exact_primary_assets:{"linux/amd64":"context-linux-amd64"}}}
        ' > "$config" || return 1
    # shellcheck source=../../src/logging.sh
    source "$ROOT/src/logging.sh"
    # shellcheck source=../../src/config.sh
    source "$ROOT/src/config.sh"
    # shellcheck source=../../src/build_state.sh
    source "$ROOT/src/build_state.sh"
    # shellcheck source=../../src/act_runner.sh
    source "${DSR_TEST_ACT_RUNNER:-$ROOT/src/act_runner.sh}"
    # shellcheck source=../../src/artifact_naming.sh
    source "$ROOT/src/artifact_naming.sh"
    # shellcheck source=../../src/host_selector.sh
    source "$ROOT/src/host_selector.sh"
    # shellcheck source=../../src/host_health.sh
    source "$ROOT/src/host_health.sh"
    # shellcheck source=../../src/git_ops.sh
    source "$ROOT/src/git_ops.sh"
    # shellcheck source=../../src/packaging.sh
    source "$ROOT/src/packaging.sh"
    host_health_is_ready() { return 0; }
    selector_acquire_slot() { return 0; }
    selector_release_slot() { return 0; }
    build_state_init || return 1
    export SCRIPT_DIR="$ROOT" JSON_MODE=true DRY_RUN=false VERBOSE=false DSR_VERSION=fixture DSR_KEEP_BUILD_STAGES=1
    declare -A _DSR_LOADED_MODULES=([packaging]=1 [artifact_naming]=1)
    # shellcheck disable=SC1090 # Actual public command and publication consumer.
    source <(awk '/^(_dsr_require|cmd_build|_release_sha256|_release_require_publishable_artifacts)\(\) \{/{copy=1} copy{print} copy && /^\}/{copy=0}' "$ROOT/dsr") || return 1
    # shellcheck disable=SC1090
    source <(awk '/^json_envelope\(\) \{/{copy=1} copy{print} copy && /^# ====/{exit}' "$ROOT/dsr") || return 1
    check_go_policy() {
        local label="$1"; shift
        checks=$((checks + 1))
        if "$@"; then printf 'PASS: Go policy: %s\n' "$label"
        else failures=$((failures + 1)); printf 'FAIL: Go policy: %s\n' "$label" >&2; fi
    }
    printf 'BOUNDARY: fixture host health/capacity only; real cmd_build, pinned Git snapshots, compiler, collection, checkpoint and publication\n'
    printf 'GOFLAGS=-ldflags=-X=main.message=persistent-override\n' > "$runtime/go-env"
    printf 'go 1.19\nuse .\n' > "$runtime/outside/go.work"
    printf 'module example.local/outside\n\ngo 1.19\n' > "$runtime/outside/go.mod"
    export GOENV="$runtime/go-env" GOWORK="$runtime/outside/go.work"
    export GOFLAGS='-ldflags=-X=main.message=ambient-override' GOAMD64=v99 GOTOOLCHAIN=go0.0.1
    status=0
    cmd_build context --version 1.0.0 --output-dir "$runtime/no-workfile" \
        > "$runtime/no-workfile.json" 2> "$runtime/no-workfile.log" || status=$?
    check_go_policy 'public strict build ignores inherited selectors and persistent GOENV' test "$status" -eq 0
    if [[ "$status" -ne 0 ]]; then cat "$runtime/no-workfile.log" >&2; return 1; fi
    check_go_policy 'real binary retains pinned bytes despite ambient linker flags' \
        test "$("$runtime/no-workfile/context-linux-amd64" 2>&1)" = pinned-default
    check_go_policy 'unrelated recipe environment keeps its existing shell expansion' \
        test "$(cat "$runtime/recipe-expansion")" = recipe-env-expanded
    check_go_policy 'manifest records the actual no-workfile compiler policy' jq -e --arg sha "$sha" '
        .publishable==true and .source.git_sha==$sha and
        (.build_environments[0].build_influence_env |
         .DSR_GO_ENV_POLICY=="2" and .GOENV=="off" and .GOFLAGS=="" and .GOWORK=="off" and
         .GOTOOLCHAIN=="local" and .GO111MODULE=="on" and .GOOS=="linux" and .GOARCH=="amd64" and
         .DSR_GO_WORKFILE=="" and .DSR_GO_WORKFILE_SHA256=="" and (has("GOAMD64")|not))
        ' "$runtime/no-workfile/context-v1.0.0-manifest.json"
    check_go_policy 'isolated output passes actual publication admission' \
        _release_require_publishable_artifacts "$runtime/no-workfile" "$runtime/no-workfile/context-v1.0.0-manifest.json" true
    jq '.build_environments[0].build_influence_env={}' "$runtime/no-workfile/context-v1.0.0-manifest.json" \
        > "$runtime/old-manifest.json" || return 1
    status=0
    _act_validate_contract_variant_inventory context "$(cat "$runtime/old-manifest.json")" \
        "$(jq -c '.release_contract' "$config")" > "$runtime/old-manifest.out" 2> "$runtime/old-manifest.log" || status=$?
    check_go_policy 'release consumer refuses an old strict Go manifest without policy receipt' test "$status" -ne 0
    check_go_policy 'legacy manifest refusal names the missing compiler policy' \
        grep -q 'compiler environment policy receipt' "$runtime/old-manifest.log"
    jq '.build_environments[0].build_influence_env.DSR_GO_ENV_POLICY="1"' \
        "$runtime/no-workfile/context-v1.0.0-manifest.json" > "$runtime/policy-one-manifest.json" || return 1
    status=0
    _act_validate_contract_variant_inventory context "$(cat "$runtime/policy-one-manifest.json")" \
        "$(jq -c '.release_contract' "$config")" > "$runtime/policy-one.out" 2> "$runtime/policy-one.log" || status=$?
    check_go_policy 'release consumer refuses policy one without pkg-config isolation evidence' test "$status" -ne 0
    check_go_policy 'obsolete policy refusal requires a fresh build, not receipt migration' \
        grep -q 'DSR_GO_ENV_POLICY=2.*start a fresh release build' "$runtime/policy-one.log"
    for kind in empty relabelled duplicated; do
        case "$kind" in
            empty) jq '.build_environments=[]' "$runtime/no-workfile/context-v1.0.0-manifest.json" ;;
            relabelled) jq '.build_environments[].method="act"' "$runtime/no-workfile/context-v1.0.0-manifest.json" ;;
            duplicated) jq '.build_environments += .build_environments' "$runtime/no-workfile/context-v1.0.0-manifest.json" ;;
        esac > "$runtime/$kind-manifest.json" || return 1
        status=0
        _act_validate_contract_variant_inventory context "$(cat "$runtime/$kind-manifest.json")" \
            "$(jq -c '.release_contract' "$config")" > "$runtime/$kind-manifest.out" 2> "$runtime/$kind-manifest.log" || status=$?
        check_go_policy "$kind inventory cannot hide a configured native Go target" test "$status" -ne 0
        check_go_policy "$kind inventory reaches the native policy coverage gate" \
            grep -q 'exactly one native policy receipt' "$runtime/$kind-manifest.log"
    done

    printf 'go 1.19\nuse .\n' > "$work/source/go.work"
    git -C "$work/source" add go.work || return 1
    git -C "$work/source" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm pinned-workspace || return 1
    git -C "$work/source" tag v1.0.1 || return 1
    sha=$(git -C "$work/source" rev-parse HEAD) || return 1
    jq '.env.GOFLAGS="-ldflags=-X=main.message=reviewed-policy" | .env.GOWORK=""' \
        "$config" > "$runtime/workspace-config.json" || return 1
    command cp "$runtime/workspace-config.json" "$config" || return 1
    status=0
    cmd_build context --version 1.0.1 --output-dir "$runtime/workspace" \
        > "$runtime/workspace.json" 2> "$runtime/workspace.log" || status=$?
    check_go_policy 'public workspace build honors reviewed linker flags' test "$status" -eq 0
    if [[ "$status" -ne 0 ]]; then cat "$runtime/workspace.log" >&2; return 1; fi
    check_go_policy 'actual workspace executable contains the reviewed override' \
        test "$("$runtime/workspace/context-linux-amd64" 2>&1)" = reviewed-policy
    check_go_policy 'workspace receipt binds pinned bytes and private selection' jq -e \
        --arg digest "$(_act_sha256 "$work/source/go.work")" --arg sha "$sha" --arg original "$work/source/go.work" '
        .build_environments[0].build_influence_env |
        .GOFLAGS=="-ldflags=-X=main.message=reviewed-policy" and .GOENV=="off" and
        .DSR_GO_WORKFILE=="source/go.work" and .DSR_GO_WORKFILE_SHA256==$digest and
        .DSR_GO_WORKFILE_GIT_SHA==$sha and .GOWORK!=$original and (.GOWORK|endswith("/source/go.work"))
        ' "$runtime/workspace/context-v1.0.1-manifest.json"
    check_go_policy 'workspace output passes actual publication admission' \
        _release_require_publishable_artifacts "$runtime/workspace" "$runtime/workspace/context-v1.0.1-manifest.json" true
    stage="$work/stages/test-policy/source"
    result=$(_act_strict_go_workfile_json context "$sha" "$work/source/go.work" "$stage") || return 1
    check_go_policy 'explicit original workfile is rebased into the private stage' \
        test "$(jq -r '.gowork' <<< "$result")" = "$stage/go.work"
    status=0
    _act_strict_go_workfile_json context "$sha" "$runtime/outside/go.work" "$stage" \
        > "$runtime/external-workfile.out" 2> "$runtime/external-workfile.log" || status=$?
    check_go_policy 'an explicitly unpinned external workspace is refused' test "$status" -ne 0
    status=0
    _act_strict_go_build_env context "$sha" v1.0.1 "$stage" "GOENV=$runtime/go-env" \
        > "$runtime/persistent-env.out" 2> "$runtime/persistent-env.log" || status=$?
    check_go_policy 'explicit persistent GOENV must become reviewed recipe entries' test "$status" -ne 0
    for kind in pkg_config_path PKG_CONFIG_LIBDIR_x86_64-unknown-linux-gnu; do
        status=0
        _act_strict_go_build_env context "$sha" v1.0.1 "$stage" "$kind=/unreviewed" \
            > "$runtime/invalid-$kind.out" 2> "$runtime/invalid-$kind.log" || status=$?
        check_go_policy "configured $kind must use a portable uppercase identifier" test "$status" -ne 0
        check_go_policy "$kind is refused at the compiler selector boundary" \
            grep -q 'portable uppercase identifier' "$runtime/invalid-$kind.log"
    done

    # Genuine partial release: amd64 succeeds; the configured 386 command
    # fails before Go starts. Both retained authorities must keep the policy.
    jq '.targets=["linux/amd64","linux/386"] |
        .act_job_map["linux/386"]=null | .hosts["linux/386"]="localnative" |
        .release_contract.exact_primary_assets["linux/386"]="context-linux-386" |
        .build_cmd="printf \"%s\\n\" \"$DSR_TARGET_ARCH\" >> \"$PROBE_EVENTS\"; if [ \"$DSR_TARGET_ARCH\" = 386 ]; then exit 7; fi; go build -p=1 -buildvcs=false -o context ."
        ' "$config" > "$runtime/mixed-config.json" || return 1
    command cp "$runtime/mixed-config.json" "$config" || return 1
    status=0
    cmd_build context --version 1.0.1 --output-dir "$runtime/mixed" \
        > "$runtime/mixed.json" 2> "$runtime/mixed.log" || status=$?
    check_go_policy 'real mixed release reports its configured command failure' test "$status" -ne 0
    build_state_get context 1.0.1 > "$runtime/mixed-state.json" || return 1
    check_go_policy 'mixed checkpoint retains a real successful Go target' jq -e '
        .target_statuses["linux/amd64"].status=="completed" and
        .target_statuses["linux/386"].status=="failed" and
        .target_statuses["linux/amd64"].result.build_influence_env.DSR_GO_ENV_POLICY=="2"
        ' "$runtime/mixed-state.json"
    run=$(jq -er '.run_id' "$runtime/mixed-state.json") || return 1
    state_file="$DSR_STATE_DIR/builds/context/1.0.1/$run/state.json"
    sidecar=$(jq -er '.target_statuses["linux/amd64"].result_path' "$state_file") || return 1
    original_state="$runtime/original-state.json"; original_sidecar="$runtime/original-sidecar.json"
    command cp "$state_file" "$original_state" || return 1
    command cp "$sidecar" "$original_sidecar" || return 1
    for kind in embedded sidecar embedded-policy-one sidecar-policy-one; do
        command cp "$original_state" "$state_file" || return 1
        command cp "$original_sidecar" "$sidecar" || return 1
        case "$kind" in
            embedded)
                jq '.target_statuses["linux/amd64"].result.build_influence_env={}' "$original_state" > "$state_file" || return 1 ;;
            sidecar)
                jq '.build_influence_env={}' "$original_sidecar" > "$sidecar" || return 1 ;;
            embedded-policy-one)
                jq '.target_statuses["linux/amd64"].result.build_influence_env.DSR_GO_ENV_POLICY="1"' \
                    "$original_state" > "$state_file" || return 1 ;;
            sidecar-policy-one)
                jq '.build_influence_env.DSR_GO_ENV_POLICY="1"' "$original_sidecar" > "$sidecar" || return 1 ;;
        esac
        before_state=$(_act_sha256 "$state_file") || return 1
        before_events=$(_act_sha256 "$runtime/compiler-events") || return 1
        status=0
        cmd_build context --version 1.0.1 --resume="$run" --output-dir "$runtime/mixed" \
            > "$runtime/old-$kind.json" 2> "$runtime/old-$kind.log" || status=$?
        check_go_policy "public resume refuses an old $kind Go policy receipt" test "$status" -ne 0
        check_go_policy "$kind refusal reaches the compiler policy consumer" \
            grep -q 'compiler environment policy receipt' "$runtime/old-$kind.log"
        check_go_policy "$kind refusal preserves the prior checkpoint" test "$before_state" = "$(_act_sha256 "$state_file")"
        check_go_policy "$kind refusal cannot launch another command" test "$before_events" = "$(_act_sha256 "$runtime/compiler-events")"
    done
    command cp "$original_state" "$state_file" || return 1
    command cp "$original_sidecar" "$sidecar" || return 1
    local amd64_before other_before retained_success
    amd64_before=$(grep -cx amd64 "$runtime/compiler-events") || return 1
    other_before=$(grep -cx 386 "$runtime/compiler-events") || return 1
    retained_success=$(jq -er '.target_statuses["linux/amd64"].result_path' "$original_state") || return 1
    status=0
    cmd_build context --version 1.0.1 --resume="$run" --output-dir "$runtime/mixed" \
        > "$runtime/valid-resume.json" 2> "$runtime/valid-resume.log" || status=$?
    check_go_policy 'valid policy resume retains the configured 386 failure' test "$status" -ne 0
    check_go_policy 'valid policy resume reuses successful amd64 without recompiling it' \
        test "$amd64_before" -eq "$(grep -cx amd64 "$runtime/compiler-events")"
    check_go_policy 'valid policy resume dispatches only the failed target again' \
        test "$((other_before + 1))" -eq "$(grep -cx 386 "$runtime/compiler-events")"
    check_go_policy 'valid resume preserves the successful immutable receipt' jq -e --arg path "$retained_success" '
        .target_statuses["linux/amd64"].status=="completed" and
        .target_statuses["linux/amd64"].attempts==1 and
        .target_statuses["linux/amd64"].result_path==$path and
        .target_statuses["linux/386"].status=="failed" and
        .target_statuses["linux/386"].attempts==2
        ' "$state_file"
    # Preserve the existing non-cgo checks on hosts without native C tooling,
    # but never report complete policy coverage without the real cgo case.
    for dependency in cc pkg-config printenv; do
        if ! command -v "$dependency" >/dev/null; then
            printf 'SKIP: strict Go pkg-config requires %s; prior checks %s, failures %s; evidence %s\n' \
                "$dependency" "$checks" "$failures" "$runtime"
            [[ "$failures" -eq 0 ]] || return 1
            return 77
        fi
    done
    # Real cgo uses pkg-config flags to choose the compiled value. The reviewed
    # directory contains a literal shell variable spelling; neither that path
    # nor other reviewed pkg-config selectors may be expanded by the launcher.
    local pkg_reviewed pkg_ambient pkg_program pkg_cc pkg_poison_flags
    pkg_reviewed="$work/pkg-config/"'$DSR_GO_RECIPE_MARKER'
    pkg_ambient="$work/pkg-config/ambient"
    pkg_program=$(command -v pkg-config) || return 1
    pkg_cc=$(command -v cc) || return 1
    mkdir -p "$pkg_reviewed" "$pkg_ambient" || return 1
    printf 'Name: dsrfixture\nDescription: reviewed cgo fixture\nVersion: 1.0\nCflags: -DDSR_PKG_ANSWER=41\nLibs:\n' \
        > "$pkg_reviewed/dsrfixture.pc"
    printf 'Name: dsrfixture\nDescription: ambient cgo fixture\nVersion: 1.0\nCflags: -DDSR_PKG_ANSWER=99\nLibs:\n' \
        > "$pkg_ambient/dsrfixture.pc"
    pkg_poison_flags=$(PKG_CONFIG_LIBDIR="$pkg_reviewed" PKG_CONFIG_PATH="$pkg_ambient" \
        "$pkg_program" --cflags dsrfixture) || return 1
    check_go_policy 'real pkg-config selects the ambient package before worker isolation' \
        grep -q -- '-DDSR_PKG_ANSWER=99' <<< "$pkg_poison_flags"
    cat > "$work/source/main.go" <<'GO'
package main
/*
#cgo pkg-config: dsrfixture
static int dsr_pkg_answer(void) { return DSR_PKG_ANSWER; }
*/
import "C"
func main() { println(int(C.dsr_pkg_answer())) }
GO
    git -C "$work/source" add main.go || return 1
    git -C "$work/source" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm pinned-cgo || return 1
    git -C "$work/source" tag v1.0.2 || return 1
    sha=$(git -C "$work/source" rev-parse HEAD) || return 1
    jq --arg directory "$pkg_reviewed" --arg program "$pkg_program" --arg cc "$pkg_cc" --arg runtime "$runtime" '
        .env.GOFLAGS="" | .env.CGO_ENABLED="1" | .env.CC=$cc | .env.PKG_CONFIG=$program |
        .env.PKG_CONFIG_LIBDIR=$directory | .env.PKG_CONFIG_DSR_REVIEWED="$DSR_GO_RECIPE_MARKER" |
        .env.PROBE_PKG_REVIEWED=($runtime+"/pkg-reviewed") | .env.PROBE_PKG_AMBIENT=($runtime+"/pkg-ambient") |
        .build_cmd="printf \"%s\\n\" \"$PKG_CONFIG_LIBDIR\" \"$PKG_CONFIG_DSR_REVIEWED\" > \"$PROBE_PKG_REVIEWED\"; printenv PKG_CONFIG_PATH PKG_CONFIG_SYSROOT_DIR PKG_CONFIG_DSR_UNREVIEWED pkg_config_path > \"$PROBE_PKG_AMBIENT\" || true; go build -p=1 -buildvcs=false -o context ."
        ' "$runtime/workspace-config.json" > "$runtime/cgo-config.json" || return 1
    command cp "$runtime/cgo-config.json" "$config" || return 1
    export PKG_CONFIG_PATH="$pkg_ambient" PKG_CONFIG_SYSROOT_DIR="$work/ambient-sysroot"
    export PKG_CONFIG_DSR_UNREVIEWED=ambient-selector pkg_config_path="$pkg_ambient"
    status=0
    cmd_build context --version 1.0.2 --output-dir "$runtime/cgo" \
        > "$runtime/cgo.json" 2> "$runtime/cgo.log" || status=$?
    check_go_policy 'strict cgo build succeeds with reviewed literal pkg-config settings' test "$status" -eq 0
    if [[ "$status" -ne 0 ]]; then cat "$runtime/cgo.log" >&2; return 1; fi
    check_go_policy 'real cgo binary uses reviewed package flags instead of ambient flags' \
        test "$("$runtime/cgo/context-linux-amd64" 2>&1)" = 41
    check_go_policy 'child receives every reviewed pkg-config value literally' \
        test "$(cat "$runtime/pkg-reviewed")" = "$(printf '%s\n' "$pkg_reviewed" '$DSR_GO_RECIPE_MARKER')"
    check_go_policy 'child drops inherited path, sysroot, extension and lowercase selectors' \
        test ! -s "$runtime/pkg-ambient"
    check_go_policy 'cgo receipt retains reviewed pkg-config family and excludes ambient selectors' jq -e \
        --arg directory "$pkg_reviewed" --arg program "$pkg_program" --arg sha "$sha" '
        .publishable==true and .source.git_sha==$sha and
        (.build_environments[0].build_influence_env |
         .DSR_GO_ENV_POLICY=="2" and .CGO_ENABLED=="1" and .PKG_CONFIG==$program and
         .PKG_CONFIG_LIBDIR==$directory and .PKG_CONFIG_DSR_REVIEWED=="$DSR_GO_RECIPE_MARKER" and
         (has("PKG_CONFIG_PATH")|not) and (has("PKG_CONFIG_SYSROOT_DIR")|not) and
         (has("PKG_CONFIG_DSR_UNREVIEWED")|not) and (has("pkg_config_path")|not))
        ' "$runtime/cgo/context-v1.0.2-manifest.json"
    check_go_policy 'reviewed cgo output passes actual publication admission' \
        _release_require_publishable_artifacts "$runtime/cgo" "$runtime/cgo/context-v1.0.2-manifest.json" true
    jq --arg directory "$pkg_ambient" '.env.PKG_CONFIG_LIBDIR=$directory' "$runtime/cgo-config.json" \
        > "$config" || return 1
    status=0
    _act_validate_contract_variant_inventory context "$(cat "$runtime/cgo/context-v1.0.2-manifest.json")" \
        "$(jq -c '.release_contract' "$config")" > "$runtime/changed-pkg.out" 2> "$runtime/changed-pkg.log" || status=$?
    check_go_policy 'changed reviewed pkg-config search path invalidates retained output' test "$status" -ne 0
    check_go_policy 'changed pkg-config receipt requires a fresh build' \
        grep -q 'no longer matches the reviewed compiler selectors' "$runtime/changed-pkg.log"
    command cp "$runtime/cgo-config.json" "$config" || return 1

    printf 'Strict Go policy: %s checks, %s failures; evidence %s\n' "$checks" "$failures" "$runtime"
    [[ "$failures" -eq 0 ]]
)

test_ordinary_source_inputs() (
    local dependency work config contexts first next result state_file state failures=0 checks=0
    for dependency in bash git jq yq python3 rsync; do
        command -v "$dependency" >/dev/null || { printf 'SKIP: ordinary input tests require %s\n' "$dependency"; return 77; }
    done
    work=$(mktemp -d "${TMPDIR:-/tmp}/dsr-ordinary-inputs.XXXXXXXX") || return 1
    printf 'Ordinary source-input evidence: %s\n' "$work"
    mkdir -p "$work/source/ignored" "$work/source/target" "$work/sibling" "$work/config/repos.d" "$work/plain" || return 1
    export DSR_CONFIG_DIR="$work/config" ACT_CONFIG_DIR="$work/config" ACT_REPOS_DIR="$work/config/repos.d"
    export DSR_STATE_DIR="$work/state" DSR_CACHE_DIR="$work/cache" NO_COLOR=1
    # shellcheck source=../../src/logging.sh
    source "$ROOT/src/logging.sh"
    # shellcheck source=../../src/config.sh
    source "$ROOT/src/config.sh"
    # shellcheck source=../../src/git_ops.sh
    source "$ROOT/src/git_ops.sh"
    # shellcheck source=../../src/build_state.sh
    source "$ROOT/src/build_state.sh"
    # shellcheck source=../../src/act_runner.sh
    source "$ROOT/src/act_runner.sh"
    check_inputs() {
        local label="$1"; shift
        checks=$((checks + 1))
        if "$@"; then printf 'PASS: %s\n' "$label"
        else failures=$((failures + 1)); printf 'FAIL: %s\n' "$label" >&2; fi
    }
    printf 'tracked-original\n' > "$work/source/tracked"
    printf 'selected untracked\n' > "$work/source/untracked"
    printf '#!/bin/sh\nprintf original\\n\n' > "$work/source/script"
    chmod 755 "$work/source/script" || return 1
    printf 'ignored/\n' > "$work/source/.gitignore"
    printf 'ignored cache\n' > "$work/source/ignored/cache"
    printf 'compiled output\n' > "$work/source/target/output"
    printf 'custom excluded\n' > "$work/source/custom.drop"
    ln -s tracked "$work/source/link" || return 1
    printf 'sibling original\n' > "$work/sibling/input"
    printf '*.cache\n' > "$work/sibling/.gitignore"
    printf 'ignored sibling cache\n' > "$work/sibling/input.cache"
    printf '*.cache\n' > "$work/plain/.gitignore"
    printf 'selected plain cache\n' > "$work/plain/input.cache"
    for result in source sibling; do
        git -C "$work/$result" init -q -b main || return 1
        git -C "$work/$result" add .gitignore || return 1
        if [[ "$result" == source ]]; then
            git -C "$work/source" add tracked script link || return 1
        else
            git -C "$work/sibling" add input || return 1
        fi
        git -C "$work/$result" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm inputs || return 1
    done
    config="$ACT_REPOS_DIR/inputs.yaml"
    jq -n --arg work "$work" '{tool_name:"inputs",local_path:($work+"/source"),
        sync_excludes:["custom.drop"],sibling_crates:[
          {local_path:($work+"/sibling"),relative_path:"selected-sibling"},
          {local_path:($work+"/plain"),relative_path:"plain",respect_gitignore:null}]}' > "$config" || return 1
    capture_inputs() {
        local label="$1"
        mkdir "$work/contexts-$label" || return 1
        contexts=$(_act_export_ordinary_git_contexts "$config" "$work/source" "$work/contexts-$label") || return 1
        _act_project_ordinary_sources "$config" "$contexts" "$work/projection-$label" > "$work/$label.json"
    }
    capture_inputs original || return 1
    first=$(cat "$work/original.json") || return 1
    check_inputs 'projection keeps selected dirty/untracked bytes' cmp "$work/source/untracked" "$work/projection-original/source/untracked"
    check_inputs 'projection preserves executable mode' test -x "$work/projection-original/source/script"
    check_inputs 'projection preserves symlink text' test "$(readlink "$work/projection-original/source/link")" = tracked
    check_inputs 'projection excludes ambient Git administration' test ! -e "$work/projection-original/source/.git"
    check_inputs 'projection excludes default compiler outputs' test ! -e "$work/projection-original/source/target"
    check_inputs 'projection honors main Git ignore selection' test ! -e "$work/projection-original/source/ignored"
    check_inputs 'projection honors custom exclusions' test ! -e "$work/projection-original/source/custom.drop"
    check_inputs 'sibling default honors Git ignore selection' test ! -e "$work/projection-original/selected-sibling/input.cache"
    check_inputs 'explicit sibling null preserves prior no-ignore policy' cmp "$work/plain/input.cache" "$work/projection-original/plain/input.cache"
    check_inputs 'summary binds all selected roots and link count' jq -e \
        '.schema_version==1 and .policy=="ordinary-source-v1" and
         .roots==["plain","selected-sibling","source"] and .symlinks==1 and .files>0' "$work/original.json"
    printf 'changed ignored cache\n' > "$work/source/ignored/cache"
    printf 'changed output\n' > "$work/source/target/output"
    printf 'changed custom exclude\n' > "$work/source/custom.drop"
    printf 'changed ignored sibling cache\n' > "$work/sibling/input.cache"
    capture_inputs ignored || return 1
    check_inputs 'ignored/default/custom excluded changes do not invalidate inputs' test "$first" = "$(cat "$work/ignored.json")"
    printf 'tracked-modified\n' > "$work/source/tracked"
    capture_inputs changed || return 1
    next=$(cat "$work/changed.json") || return 1
    check_inputs 'same-HEAD tracked changes invalidate selected source identity' test "$first" != "$next"
    printf 'tracked-original\n' > "$work/source/tracked"
    capture_inputs restored || return 1
    check_inputs 'restoring source bytes restores identity independent of timestamps' test "$first" = "$(cat "$work/restored.json")"
    printf 'new selected input\n' > "$work/source/another-untracked"
    capture_inputs added || return 1
    check_inputs 'added selected untracked file changes identity' test "$first" != "$(cat "$work/added.json")"
    mv "$work/source/another-untracked" "$work/held-addition" || return 1
    mv "$work/source/untracked" "$work/held-untracked" || return 1
    capture_inputs removed || return 1
    check_inputs 'removed selected untracked file changes identity' test "$first" != "$(cat "$work/removed.json")"
    mv "$work/held-untracked" "$work/source/untracked" || return 1
    chmod 644 "$work/source/script" || return 1
    capture_inputs mode || return 1
    check_inputs 'execution permission changes invalidate identity' test "$first" != "$(cat "$work/mode.json")"
    chmod 755 "$work/source/script" || return 1
    mv "$work/source/link" "$work/held-link" || return 1
    ln -s untracked "$work/source/link" || return 1
    capture_inputs link || return 1
    check_inputs 'symlink retargeting invalidates identity' test "$first" != "$(cat "$work/link.json")"
    mv "$work/source/link" "$work/retargeted-link" || return 1
    mv "$work/held-link" "$work/source/link" || return 1
    printf 'changed sibling bytes\n' > "$work/sibling/input"
    capture_inputs sibling || return 1
    check_inputs 'selected sibling source bytes invalidate identity' test "$first" != "$(cat "$work/sibling.json")"
    printf 'sibling original\n' > "$work/sibling/input"
    git -C "$work/source" tag added-tag || return 1
    capture_inputs tags || return 1
    check_inputs 'Git tag namespace changes invalidate identity without HEAD movement' test "$first" != "$(cat "$work/tags.json")"

    # Use the real state writer and atomic refresh. The retained worker row is
    # explicitly fixture data; native compilation is covered by the other mode.
    build_state_init || return 1
    local run sha recipe receipt initial_context task
    run=$(build_state_create inputs 1.0.0 linux/amd64) || return 1
    sha=$(git -C "$work/source" rev-parse HEAD) || return 1
    recipe=$(_act_sha256 "$config") || return 1
    receipt=$(jq -nc --argjson inputs "$first" '{staged_ordinary:true,source_inputs:$inputs,
        source_roots:{host:"/retained/source"},target_hosts:{"linux/amd64":"host"}}') || return 1
    task='[{"key":"linux/amd64","platform":"linux/amd64","target_triple":"","method":"native"}]'
    build_state_set_context inputs 1.0.0 "$run" "$sha" main '{"host":"/retained/source"}' \
        "$work/output" 1 '{"linux/amd64":"host"}' release "$task" '' "$receipt" "$recipe" || return 1
    build_state_update_status inputs 1.0.0 running "$run" || return 1
    result=$(jq -nc --argjson inputs "$first" '{result:{method:"native",status:"success",source_sync:{source_inputs:$inputs}}}') || return 1
    build_state_update_target inputs 1.0.0 linux/amd64 completed "$result" "$run" || return 1
    state=$(build_state_get inputs 1.0.0 "$run") || return 1
    state_file="$DSR_STATE_DIR/builds/inputs/1.0.0/$run/state.json"
    initial_context=$(_act_sha256 "$state_file") || return 1
    check_inputs 'same inputs pass read-only resume admission' build_state_validate_source_inputs "$state" "$receipt"
    result=$(jq -c --argjson inputs "$next" '.source_inputs=$inputs' <<< "$receipt") || return 1
    if build_state_set_source_sync inputs 1.0.0 "$run" "$result" '{"host":"/retained/source"}' \
        '{"linux/amd64":"host"}' > "$work/refusal.out" 2> "$work/refusal.log"; then
        check_inputs 'changed input refresh is refused' false
    else check_inputs 'changed input refresh is refused' true; fi
    check_inputs 'refused refresh preserves checkpoint bytes' test "$initial_context" = "$(_act_sha256 "$state_file")"
    if build_state_validate_source_inputs "$state" null; then
        check_inputs 'no-sync cannot erase a staged source binding' false
    else check_inputs 'no-sync cannot erase a staged source binding' true; fi
    result=$(jq -c 'del(.context.source_sync.source_inputs)' <<< "$state") || return 1
    if build_state_validate_source_inputs "$result" "$receipt"; then
        check_inputs 'legacy missing binding cannot authorize reuse' false
    else check_inputs 'legacy missing binding cannot authorize reuse' true; fi
    result=$(jq -c '.target_statuses["linux/amd64"].result.source_sync.source_inputs.sha256=("0"*64)' <<< "$state") || return 1
    if build_state_validate_source_inputs "$result" "$receipt"; then
        check_inputs 'completed receipt must retain the original source binding' false
    else check_inputs 'completed receipt must retain the original source binding' true; fi
    result=$(jq -c 'del(.target_statuses["linux/amd64"].result.method) |
        del(.target_statuses["linux/amd64"].result.source_sync)' <<< "$state") || return 1
    if build_state_validate_source_inputs "$result" "$receipt"; then
        check_inputs 'missing result method cannot bypass native task binding' false
    else check_inputs 'missing result method cannot bypass native task binding' true; fi
    result=$(jq -c '.target_statuses["linux/amd64"].status="running" |
        .target_statuses["linux/amd64"].result.method="act" |
        del(.target_statuses["linux/amd64"].result.source_sync)' <<< "$state") || return 1
    if build_state_validate_source_inputs "$result" "$receipt"; then
        check_inputs 'running entry with successful mislabeled native result is refused' false
    else check_inputs 'running entry with successful mislabeled native result is refused' true; fi
    jq '.target_statuses["linux/amd64"].result | del(.source_sync)' <<< "$state" > "$work/unbound-sidecar.json" || return 1
    result=$(jq -c --arg path "$work/unbound-sidecar.json" '
        .target_statuses["linux/amd64"].status="running" |
        .target_statuses["linux/amd64"].result_path=$path |
        del(.target_statuses["linux/amd64"].result)' <<< "$state") || return 1
    if build_state_validate_source_inputs "$result" "$receipt"; then
        check_inputs 'successful recovery sidecar cannot bypass native input binding' false
    else check_inputs 'successful recovery sidecar cannot bypass native input binding' true; fi
    jq '.target_statuses["linux/amd64"].result' <<< "$state" > "$work/bound-sidecar.json" || return 1
    result=$(jq -c --arg path "$work/bound-sidecar.json" '
        .target_statuses["linux/amd64"].status="running" |
        .target_statuses["linux/amd64"].result_path=$path |
        del(.target_statuses["linux/amd64"].result)' <<< "$state") || return 1
    check_inputs 'successful recovery sidecar with original binding remains admissible' \
        build_state_validate_source_inputs "$result" "$receipt"
    if _act_result_source_inputs_match "$(cat "$work/unbound-sidecar.json")" "$receipt" native; then
        check_inputs 'reuse boundary rejects a sidecar changed after admission' false
    else check_inputs 'reuse boundary rejects a sidecar changed after admission' true; fi
    check_inputs 'reuse boundary admits original native sidecar' \
        _act_result_source_inputs_match "$(cat "$work/bound-sidecar.json")" "$receipt" native
    check_inputs 'matching atomic refresh succeeds' build_state_set_source_sync inputs 1.0.0 "$run" "$receipt" \
        '{"host":"/retained/source"}' '{"linux/amd64":"host"}'
    state=$(build_state_get inputs 1.0.0 "$run") || return 1
    check_inputs 'same-input refresh retains completed target' jq -e \
        '.target_statuses["linux/amd64"].status=="completed" and (.source_sync_history|length)==2' <<< "$state"
    printf 'Ordinary source inputs: %s checks, %s failures\n' "$checks" "$failures"
    [[ "$failures" == 0 ]]
)

test_ordinary_source_resume() (
    local dependency work first_status=0 status=0 run state_file marker before_state before_marker
    local prior_artifact prior_identity prior_digest checks=0 failures=0
    for dependency in bash git jq yq python3 rsync go tar; do
        command -v "$dependency" >/dev/null || { printf 'SKIP: ordinary resume requires %s\n' "$dependency"; return 77; }
    done
    [[ $(uname -s)/$(uname -m) == Linux/x86_64 && $(go version) == 'go version go'* ]] || {
        printf 'SKIP: ordinary resume requires Linux x86_64 and the Go compiler\n'; return 77;
    }
    work=$(mktemp -d "${DSR_TEST_DISK_ROOT:-${TMPDIR:-/tmp}}/dsr-ordinary-resume.XXXXXXXX") || return 1
    printf 'Ordinary native resume evidence: %s\n' "$work"
    mkdir -p "$work/config/repos.d" "$work/source" "$work/state" "$work/stages" || return 1
    export DSR_CONFIG_DIR="$work/config" ACT_CONFIG_DIR="$work/config" ACT_REPOS_DIR="$work/config/repos.d"
    export DSR_STATE_DIR="$work/state" DSR_CACHE_DIR="$work/cache"
    export DSR_HOSTS_FILE="$work/config/hosts.yaml" DSR_REPOS_FILE="$work/config/repos.yaml"
    export DSR_DISABLE_HOST_SELECTOR=1 RCH_DISABLED=1 RCH_CARGO_WRAPPER_BYPASS=1 NO_COLOR=1
    printf 'module example/ordinary\n\ngo 1.19\n' > "$work/source/go.mod"
    printf 'package main\nimport "fmt"\nfunc main() { fmt.Println("first-input") }\n' > "$work/source/main.go"
    git -C "$work/source" init -q -b main || return 1
    git -C "$work/source" add go.mod main.go || return 1
    git -C "$work/source" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm original || return 1
    jq -n --arg work "$work" '{schema_version:"1.0.0",hosts:{localnative:{
        platform:"linux/amd64",connection:"local",concurrency:2,build_root:($work+"/stages")}},
        platform_mapping:{"linux/amd64":"localnative","linux/386":"localnative"}}' > "$DSR_HOSTS_FILE" || return 1
    jq -n --arg source "$work/source" --arg path "$PATH" --arg work "$work" \
        --arg cache "${DSR_TEST_GOCACHE:-$work/go-cache}" '{
        tool_name:"ordinary",repo:"example/ordinary",local_path:$source,language:"go",binary_name:"ordinary",
        targets:["linux/amd64","linux/386"],act_job_map:{"linux/amd64":null,"linux/386":null},
        hosts:{"linux/amd64":"localnative","linux/386":"localnative"},
        build_cmd:"if [ \"$DSR_TARGET_ARCH\" = 386 ] && [ -e \"$PROBE_FAIL\" ]; then exit 6; fi; printf \"%s\\n\" \"$DSR_TARGET_ARCH\" >> \"$PROBE_EVENTS\"; go build -o ordinary .",
        env:{PATH:$path,PROBE_FAIL:($work+"/fail"),PROBE_EVENTS:($work+"/compiler-events"),GOCACHE:$cache,CGO_ENABLED:"0"},
        artifact_naming:"${name}-${version}-${os}-${arch}.${ext}",archive_format:{linux:"tar.gz"}}
        ' > "$ACT_REPOS_DIR/ordinary.yaml" || return 1
    : > "$work/fail"
    # shellcheck source=../../src/logging.sh
    source "$ROOT/src/logging.sh"
    # shellcheck source=../../src/config.sh
    source "$ROOT/src/config.sh"
    # shellcheck source=../../src/build_state.sh
    source "$ROOT/src/build_state.sh"
    # shellcheck source=../../src/act_runner.sh
    source "$ROOT/src/act_runner.sh"
    # shellcheck source=../../src/artifact_naming.sh
    source "$ROOT/src/artifact_naming.sh"
    # shellcheck source=../../src/host_selector.sh
    source "$ROOT/src/host_selector.sh"
    # shellcheck source=../../src/host_health.sh
    source "$ROOT/src/host_health.sh"
    # shellcheck source=../../src/git_ops.sh
    source "$ROOT/src/git_ops.sh"
    # shellcheck source=../../src/packaging.sh
    source "$ROOT/src/packaging.sh"
    printf 'BOUNDARY: controlled host health and capacity; actual disk-stage guard, source transfer, Git, Go, collection, checkpoints and publication remain production code\n'
    host_health_is_ready() { return 0; }
    selector_acquire_slot() { return 0; }
    selector_release_slot() { return 0; }
    build_state_init || return 1
    export SCRIPT_DIR="$ROOT" JSON_MODE=true DRY_RUN=false VERBOSE=false DSR_VERSION=fixture
    declare -A _DSR_LOADED_MODULES=([packaging]=1 [artifact_naming]=1)
    # shellcheck disable=SC1090 # Extract the actual public command; no compiler or source substitute.
    source <(awk '/^(_dsr_require|cmd_build)\(\) \{/{copy=1} copy{print} copy && /^\}/{copy=0}' "$ROOT/dsr") || return 1
    # shellcheck disable=SC1090
    source <(awk '/^json_envelope\(\) \{/{copy=1} copy{print} copy && /^# ====/{exit}' "$ROOT/dsr") || return 1
    check_resume_inputs() {
        local label="$1"; shift
        checks=$((checks + 1))
        if "$@"; then printf 'PASS: %s\n' "$label"
        else failures=$((failures + 1)); printf 'FAIL: %s\n' "$label" >&2; fi
    }
    cmd_build ordinary --version 1.0.0 --output-dir "$work/output" \
        > "$work/first.json" 2> "$work/first.log" || first_status=$?
    check_resume_inputs 'real first build retains one completed and one failed target' test "$first_status" -eq 1
    build_state_get ordinary 1.0.0 > "$work/first-state.json" || { cat "$work/first.log" >&2; return 1; }
    run=$(jq -r .run_id "$work/first-state.json") || return 1
    state_file="$DSR_STATE_DIR/builds/ordinary/1.0.0/$run/state.json"
    marker="$work/output/.dsr-build-purpose.json"
    prior_artifact=$(jq -r '.target_statuses["linux/amd64"].result.artifact_path // empty' "$work/first-state.json") || return 1
    [[ -x "$prior_artifact" ]] || { cat "$work/first.log" >&2; return 1; }
    check_resume_inputs 'completed original executable runs original source' test "$("$prior_artifact")" = first-input
    prior_digest=$(_act_sha256 "$prior_artifact") || return 1
    prior_identity=$(_act_file_identity "$prior_artifact") || return 1
    before_state=$(_act_sha256 "$state_file") || return 1
    before_marker=$(_act_sha256 "$marker") || return 1
    printf 'package main\nimport "fmt"\nfunc main() { fmt.Println("second-input") }\n' > "$work/source/main.go"
    mv "$work/fail" "$work/fail.disabled" || return 1
    status=0
    cmd_build ordinary --version 1.0.0 --allow-dirty --resume="$run" --output-dir "$work/output" \
        > "$work/changed.json" 2> "$work/changed.log" || status=$?
    check_resume_inputs 'same-HEAD dirty-source resume is refused' test "$status" -eq 4
    check_resume_inputs 'source refusal returns one typed command envelope' jq -es \
        'length==1 and .[0].command=="build" and .[0].exit_code==4 and
         (.[0].details.error|contains("source inputs"))' "$work/changed.json"
    check_resume_inputs 'source refusal preserves exact original checkpoint' test "$before_state" = "$(_act_sha256 "$state_file")"
    check_resume_inputs 'source refusal preserves publication-purpose receipt' test "$before_marker" = "$(_act_sha256 "$marker")"
    check_resume_inputs 'source refusal preserves completed artifact bytes and inode' test \
        "$prior_digest/$prior_identity" = "$(_act_sha256 "$prior_artifact")/$(_act_file_identity "$prior_artifact")"
    check_resume_inputs 'changed source never reaches the failed target compiler' test "$(wc -l < "$work/compiler-events")" -eq 1
    status=0
    cmd_build ordinary --version 1.0.0 --allow-dirty --no-sync --resume="$run" --output-dir "$work/output" \
        > "$work/no-sync.json" 2> "$work/no-sync.log" || status=$?
    check_resume_inputs 'no-sync cannot discard the original staged binding' test "$status" -eq 4
    check_resume_inputs 'no-sync refusal leaves the checkpoint untouched' test "$before_state" = "$(_act_sha256 "$state_file")"
    printf 'package main\nimport "fmt"\nfunc main() { fmt.Println("first-input") }\n' > "$work/source/main.go"
    status=0
    cmd_build ordinary --version 1.0.0 --resume="$run" --output-dir "$work/output" \
        > "$work/restored.json" 2> "$work/restored.log" || status=$?
    check_resume_inputs 'restored original source resumes successfully' test "$status" -eq 0
    check_resume_inputs 'only the previously failed target is compiled on retry' test \
        "$(cat "$work/compiler-events")" = $'amd64\n386'
    check_resume_inputs 'successful resume preserves completed artifact bytes and inode' test \
        "$prior_digest/$prior_identity" = "$(_act_sha256 "$prior_artifact")/$(_act_file_identity "$prior_artifact")"
    build_state_get ordinary 1.0.0 "$run" > "$work/restored-state.json" || return 1
    # Compare complete objects across actual state/result/source boundaries.
    check_resume_inputs 'all completed native targets retain the one selected namespace' jq -e '
        .context.source_sync.source_inputs as $inputs | .status=="completed" and
        ($inputs.sha256|length)==64 and
        all(.target_statuses[]; .status=="completed" and .result.source_sync.source_inputs==$inputs)
        ' "$work/restored-state.json"
    check_resume_inputs 'real 386 payload contains original source only (no 386 runtime claim)' python3 - "$work/restored-state.json" <<'PY'
import json, pathlib, sys
state = json.loads(pathlib.Path(sys.argv[1]).read_text())
payload = pathlib.Path(state['target_statuses']['linux/386']['result']['artifact_path']).read_bytes()
assert payload[:5] == b'\x7fELF\x01' and payload[18:20] == b'\x03\x00'
assert b'first-input' in payload and b'second-input' not in payload
PY
    printf 'Ordinary native resume: %s checks, %s failures\n' "$checks" "$failures"
    [[ "$failures" == 0 ]]
)

test_ordinary_go_siblings() (
    local layout="$1" dependency work config sha tree status=0 checks=0 failures=0
    local artifact shared_source private_source before_events before_state state_file run
    local go_work=off
    for dependency in bash git jq yq python3 rsync go tar; do
        command -v "$dependency" >/dev/null || { printf 'SKIP: Go siblings require %s\n' "$dependency"; return 77; }
    done
    [[ $(uname -s)/$(uname -m) == Linux/x86_64 && $(go version) == 'go version go'* ]] || {
        printf 'SKIP: Go siblings require Linux x86_64 and the Go compiler\n'; return 77;
    }
    work=$(mktemp -d "${DSR_TEST_DISK_ROOT:-${TMPDIR:-/tmp}}/dsr-go-$layout.XXXXXXXX") || return 1
    printf 'Ordinary Go %s evidence: %s\n' "$layout" "$work"
    mkdir -p "$work/config/repos.d" "$work/source" "$work/dep" "$work/stages" || return 1
    export DSR_CONFIG_DIR="$work/config" ACT_CONFIG_DIR="$work/config" ACT_REPOS_DIR="$work/config/repos.d"
    export DSR_STATE_DIR="$work/state" DSR_CACHE_DIR="$work/cache"
    export DSR_HOSTS_FILE="$work/config/hosts.yaml" DSR_REPOS_FILE="$work/config/repos.yaml"
    export DSR_DISABLE_HOST_SELECTOR=1 RCH_DISABLED=1 RCH_CARGO_WRAPPER_BYPASS=1 NO_COLOR=1
    printf 'module example.local/siblings\n\ngo 1.19\n\nrequire example.local/dep v0.0.0\n' > "$work/source/go.mod"
    printf 'package main\nimport("fmt"; "example.local/dep")\nfunc main() { fmt.Println(dep.Value()) }\n' > "$work/source/main.go"
    if [[ "$layout" == replace ]]; then
        printf 'replace example.local/dep => ../dep\n' >> "$work/source/go.mod"
    else
        printf 'go 1.19\n\nuse (\n  .\n  ../dep\n)\n' > "$work/source/go.work"
        go_work=""
    fi
    printf 'module example.local/dep\n\ngo 1.19\n' > "$work/dep/go.mod"
    printf 'package dep\nfunc Value() string { return Selected() }\n' > "$work/dep/dep.go"
    printf 'excluded.go\n' > "$work/dep/.gitignore"
    for tree in source dep; do
        git -C "$work/$tree" init -q -b main || return 1
        git -C "$work/$tree" add . || return 1
        git -C "$work/$tree" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm original || return 1
    done
    # Ordinary --allow-dirty must preserve selected untracked sibling source.
    printf 'package dep\nfunc Selected() string { return "selected-sibling-input" }\n' > "$work/dep/selected.go"
    GOWORK="$go_work" GOPROXY=off GOSUMDB=off CGO_ENABLED=0 \
        GOCACHE="${DSR_TEST_GOCACHE:-$work/go-cache}" \
        go -C "$work/source" build -o "$work/control" . || return 1
    [[ $("$work/control") == selected-sibling-input ]] || return 1
    # This invalid Go file must be excluded exactly once by ordinary sync.
    # Recopying ambient controller siblings would make the real build fail.
    printf 'this is not valid Go source\n' > "$work/dep/excluded.go"
    sha=$(git -C "$work/dep" rev-parse HEAD) || return 1
    jq -n --arg work "$work" '{schema_version:"1.0.0",hosts:{localnative:{
        platform:"linux/amd64",connection:"local",concurrency:2,build_root:($work+"/stages")}},
        platform_mapping:{"linux/amd64":"localnative","linux/386":"localnative"}}' > "$DSR_HOSTS_FILE" || return 1
    config="$ACT_REPOS_DIR/siblings.yaml"
    jq -n --arg work "$work" --arg path "$PATH" --arg sha "$sha" --arg layout "$layout" \
        --arg gowork "$go_work" --arg cache "${DSR_TEST_GOCACHE:-$work/go-cache}" '{
        tool_name:"siblings",repo:"example/siblings",local_path:($work+"/source"),language:"go",binary_name:"siblings",
        targets:["linux/amd64","linux/386"],act_job_map:{"linux/amd64":null,"linux/386":null},
        hosts:{"linux/amd64":"localnative","linux/386":"localnative"},
        sibling_crates:[({local_path:($work+"/dep"),revision:$sha} +
          (if $layout=="replace" then {relative_path:"dep"} else {} end))],
        build_cmd:"printf \"%s %s\\n\" \"$DSR_TARGET_ARCH\" \"$PWD\" >> \"$PROBE_EVENTS\"; if [ \"$DSR_TARGET_ARCH\" = 386 ]; then touch \"$PROBE_READY\"; else count=0; while [ ! -e \"$PROBE_READY\" ] && [ \"$count\" -lt 600 ]; do sleep 0.05; count=$((count+1)); done; test -e \"$PROBE_READY\" || exit 9; fi; go build -o siblings .",
        env:{PATH:$path,PROBE_READY:($work+"/second-ready"),PROBE_EVENTS:($work+"/compiler-events"),
          GOCACHE:$cache,CGO_ENABLED:"0",GOWORK:$gowork,GOPROXY:"off",GOSUMDB:"off"},
        artifact_naming:"${name}-${version}-${os}-${arch}.${ext}",archive_format:{linux:"tar.gz"}}
        ' > "$config" || return 1
    # shellcheck source=../../src/logging.sh
    source "$ROOT/src/logging.sh"
    # shellcheck source=../../src/config.sh
    source "$ROOT/src/config.sh"
    # shellcheck source=../../src/build_state.sh
    source "$ROOT/src/build_state.sh"
    # shellcheck source=../../src/act_runner.sh
    source "${DSR_TEST_ACT_RUNNER:-$ROOT/src/act_runner.sh}"
    # shellcheck source=../../src/artifact_naming.sh
    source "$ROOT/src/artifact_naming.sh"
    # shellcheck source=../../src/host_selector.sh
    source "$ROOT/src/host_selector.sh"
    # shellcheck source=../../src/host_health.sh
    source "$ROOT/src/host_health.sh"
    # shellcheck source=../../src/git_ops.sh
    source "$ROOT/src/git_ops.sh"
    # shellcheck source=../../src/packaging.sh
    source "$ROOT/src/packaging.sh"
    printf 'BOUNDARY: fixture host health/capacity; actual disk guard, Git, Go, rsync, parallel scheduler, output staging, collection, checkpoint and publication\n'
    host_health_is_ready() { return 0; }
    selector_acquire_slot() { return 0; }
    selector_release_slot() { return 0; }
    build_state_init || return 1
    export SCRIPT_DIR="$ROOT" JSON_MODE=true DRY_RUN=false VERBOSE=false DSR_VERSION=fixture DSR_KEEP_BUILD_STAGES=1
    declare -A _DSR_LOADED_MODULES=([packaging]=1 [artifact_naming]=1)
    # shellcheck disable=SC1090 # Exercise the actual public command and state writer.
    source <(awk '/^(_dsr_require|cmd_build)\(\) \{/{copy=1} copy{print} copy && /^\}/{copy=0}' "$ROOT/dsr") || return 1
    # shellcheck disable=SC1090
    source <(awk '/^json_envelope\(\) \{/{copy=1} copy{print} copy && /^# ====/{exit}' "$ROOT/dsr") || return 1
    check_go_siblings() {
        local label="$1"; shift
        checks=$((checks + 1))
        if "$@"; then printf 'PASS: %s: %s\n' "$layout" "$label"
        else failures=$((failures + 1)); printf 'FAIL: %s: %s\n' "$layout" "$label" >&2; fi
    }
    cmd_build siblings --version 1.0.0 --allow-dirty --parallel=2 --output-dir "$work/output" \
        > "$work/result.json" 2> "$work/build.log" || status=$?
    check_go_siblings 'public parallel Go matrix completes' test "$status" -eq 0
    build_state_get siblings 1.0.0 > "$work/state.json" || { cat "$work/build.log" >&2; return 1; }
    check_go_siblings 'both native results retain the admitted source namespace' jq -e '
        .context.source_sync.source_inputs as $inputs | .status=="completed" and
        $inputs.roots==["dep","source"] and ($inputs.sha256|length)==64 and
        all(.target_statuses[]; .status=="completed" and .result.source_sync.source_inputs==$inputs)
        ' "$work/state.json"
    check_go_siblings 'public envelope admits both artifacts' jq -es '
        length==1 and (.[0] | .details.source_sync.source_inputs as $inputs |
        .exit_code==0 and .details.success==2 and
        all(.details.targets[]; .status=="success" and .source_sync.source_inputs==$inputs))
        ' "$work/result.json"
    artifact=$(jq -r '.target_statuses["linux/amd64"].result.artifact_path // empty' "$work/state.json") || return 1
    if [[ -x "$artifact" ]]; then
        check_go_siblings 'actual amd64 executable uses selected untracked sibling source' test "$("$artifact")" = selected-sibling-input
    else
        check_go_siblings 'actual amd64 executable uses selected untracked sibling source' false
    fi
    check_go_siblings 'actual 386 ELF uses selected sibling source (no runtime claim)' python3 - "$work/state.json" <<'PY'
import json, pathlib, sys
state = json.loads(pathlib.Path(sys.argv[1]).read_text())
payload = pathlib.Path(state['target_statuses']['linux/386']['result']['artifact_path']).read_bytes()
assert payload[:5] == b'\x7fELF\x01' and payload[18:20] == b'\x03\x00'
assert b'selected-sibling-input' in payload
PY
    shared_source=$(jq -r '.context.source_sync.source_roots.localnative' "$work/state.json") || return 1
    private_source=$(awk '$1=="386"{sub(/^[^ ]* /,"");print}' "$work/compiler-events") || return 1
    check_go_siblings 'overlapping target compiles inside its private output source' \
        test "${private_source%/*}" != "${shared_source%/*}"
    check_go_siblings 'private copy retains selected sibling bytes' \
        cmp "$work/dep/selected.go" "${private_source%/*}/dep/selected.go"
    check_go_siblings 'ignored ambient Go source is absent from private sibling' \
        test ! -e "${private_source%/*}/dep/excluded.go"
    check_go_siblings 'sibling Git identity survives private staging' test \
        "$(git -C "${private_source%/*}/dep" rev-parse HEAD)" = "$sha"
    check_go_siblings 'ordinary staging leaves the controller source free of compiler output' test ! -e "$work/source/siblings"

    # Exercise missing and substituted host siblings through the real backend.
    # The shared output from the earlier successful build cannot authorize
    # artifact collection when this attempt never reaches its Go command.
    if [[ "$layout" == replace ]]; then
        before_events=$(_act_sha256 "$work/compiler-events") || return 1
        run=$(jq -r .run_id "$work/state.json") || return 1
        state_file="$DSR_STATE_DIR/builds/siblings/1.0.0/$run/state.json"
        before_state=$(_act_sha256 "$state_file") || return 1
        mv "${shared_source%/*}/dep" "$work/retained-host-dep" || return 1
        for tree in missing linked; do
            if [[ "$tree" == linked ]]; then
                ln -s "$work/retained-host-dep" "${shared_source%/*}/dep" || return 1
            fi
            status=0
            DSR_NATIVE_OUTPUT_STAGE=1 act_run_native_build siblings linux/386 1.0.0 "refused-$tree" \
                '' '' '' localnative '' "$shared_source" > "$work/$tree.json" 2> "$work/$tree.log" || status=$?
            check_go_siblings "$tree sibling refuses the attempt" test "$status" -ne 0
            check_go_siblings "$tree sibling never reaches the compiler command" test \
                "$before_events" = "$(_act_sha256 "$work/compiler-events")"
            check_go_siblings "$tree sibling cannot collect the earlier successful binary" jq -e \
                '.status=="failed" and .artifact_paths==[]' "$work/$tree.json"
            check_go_siblings "$tree refusal reports the unavailable sibling" \
                grep -q 'required Go sibling is missing or linked' "$work/$tree.log"
        done
        check_go_siblings 'direct refused attempts preserve the public completed checkpoint' test \
            "$before_state" = "$(_act_sha256 "$state_file")"
    fi
    printf 'Ordinary Go %s: %s checks, %s failures\n' "$layout" "$checks" "$failures"
    [[ "$failures" == 0 ]]
)

test_strict_go_siblings() (
    local layout="$1" dependency work tree sha source_sha config status=0 checks=0 failures=0
    local artifact source_root private_source run state_file before_state before_events mutation
    local go_work=off
    for dependency in bash git jq yq python3 go tar; do
        command -v "$dependency" >/dev/null || { printf 'SKIP: strict Go siblings require %s\n' "$dependency"; return 77; }
    done
    [[ $(uname -s)/$(uname -m) == Linux/x86_64 && $(go version) == 'go version go'* ]] || {
        printf 'SKIP: strict Go siblings require Linux x86_64 and the Go compiler\n'; return 77;
    }
    work=$(mktemp -d "${DSR_TEST_DISK_ROOT:-${TMPDIR:-/tmp}}/dsr-strict-go-$layout.XXXXXXXX") || return 1
    printf 'Strict Go %s evidence: %s\n' "$layout" "$work"
    mkdir -p "$work/config/repos.d" "$work/source" "$work/dep" "$work/stages" || return 1
    export DSR_CONFIG_DIR="$work/config" ACT_CONFIG_DIR="$work/config" ACT_REPOS_DIR="$work/config/repos.d"
    export DSR_STATE_DIR="$work/state" DSR_CACHE_DIR="$work/cache"
    export DSR_HOSTS_FILE="$work/config/hosts.yaml" DSR_REPOS_FILE="$work/config/repos.yaml"
    export DSR_DISABLE_HOST_SELECTOR=1 RCH_DISABLED=1 RCH_CARGO_WRAPPER_BYPASS=1 NO_COLOR=1
    printf 'module example.local/strictgo\n\ngo 1.19\n\nrequire example.local/dep v0.0.0\n' > "$work/source/go.mod"
    printf 'package main\nimport "example.local/dep"\nfunc main() { println(dep.Value()) }\n' > "$work/source/main.go"
    if [[ "$layout" == replace ]]; then
        printf 'replace example.local/dep => ../dep\n' >> "$work/source/go.mod"
    else
        printf 'go 1.19\n\nuse (\n  .\n  ../dep\n)\n' > "$work/source/go.work"
        go_work=""
    fi
    printf 'module example.local/dep\n\ngo 1.19\n' > "$work/dep/go.mod"
    printf 'package dep\nfunc Value() string { return "pinned-sibling-input" }\n' > "$work/dep/dep.go"
    for tree in source dep; do
        git -C "$work/$tree" init -q -b main || return 1
        git -C "$work/$tree" add . || return 1
        git -C "$work/$tree" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm pinned || return 1
    done
    git -C "$work/source" tag v1.0.0 || return 1
    source_sha=$(git -C "$work/source" rev-parse HEAD) || return 1
    sha=$(git -C "$work/dep" rev-parse HEAD) || return 1
    jq -n --arg work "$work" '{schema_version:"1.0.0",hosts:{localnative:{
        platform:"linux/amd64",connection:"local",concurrency:2,build_root:($work+"/stages")}},
        platform_mapping:{"linux/amd64":"localnative","linux/386":"localnative"}}' > "$DSR_HOSTS_FILE" || return 1
    config="$ACT_REPOS_DIR/strictgo.yaml"
    # The source manifest supplies release Git identity. Archive-only roots
    # have no VCS metadata for Go's optional build stamp.
    jq -n --arg work "$work" --arg path "$PATH" --arg sha "$sha" \
        --arg gowork "$go_work" --arg cache "${DSR_TEST_GOCACHE:-$work/go-cache}" '{
        tool_name:"strictgo",repo:"example/strictgo",local_path:($work+"/source"),language:"go",binary_name:"strictgo",
        targets:["linux/amd64","linux/386"],act_job_map:{"linux/amd64":null,"linux/386":null},
        hosts:{"linux/amd64":"localnative","linux/386":"localnative"},
        sibling_crates:[{local_path:($work+"/dep"),relative_path:"dep",revision:$sha}],
        build_cmd:"printf \"%s %s\\n\" \"$DSR_TARGET_ARCH\" \"$PWD\" >> \"$PROBE_EVENTS\"; go build -buildvcs=false -o strictgo .",
        env:{PATH:$path,PROBE_EVENTS:($work+"/compiler-events"),GOENV:"off",GOFLAGS:"-p=1",GOMAXPROCS:"1",GOTOOLCHAIN:"local",
          GOCACHE:$cache,CGO_ENABLED:"0",GOWORK:$gowork,GOPROXY:"off",GOSUMDB:"off"},
        release_contract:{checksum_sidecar:"sha256",exact_primary_assets:{
          "linux/amd64":"strictgo-linux-amd64","linux/386":"strictgo-linux-386"}}}
        ' > "$config" || return 1
    # shellcheck source=../../src/logging.sh
    source "$ROOT/src/logging.sh"
    # shellcheck source=../../src/config.sh
    source "$ROOT/src/config.sh"
    # shellcheck source=../../src/build_state.sh
    source "$ROOT/src/build_state.sh"
    # shellcheck source=../../src/act_runner.sh
    source "${DSR_TEST_ACT_RUNNER:-$ROOT/src/act_runner.sh}"
    # shellcheck source=../../src/artifact_naming.sh
    source "$ROOT/src/artifact_naming.sh"
    # shellcheck source=../../src/host_selector.sh
    source "$ROOT/src/host_selector.sh"
    # shellcheck source=../../src/host_health.sh
    source "$ROOT/src/host_health.sh"
    # shellcheck source=../../src/git_ops.sh
    source "$ROOT/src/git_ops.sh"
    # shellcheck source=../../src/packaging.sh
    source "$ROOT/src/packaging.sh"
    printf 'BOUNDARY: fixture host health/capacity; real Git archives, snapshot verification, Go compiler, parallel stages, collection, checkpoint and publication admission\n'
    host_health_is_ready() { return 0; }
    selector_acquire_slot() { return 0; }
    selector_release_slot() { return 0; }
    build_state_init || return 1
    export SCRIPT_DIR="$ROOT" JSON_MODE=true DRY_RUN=false VERBOSE=false DSR_VERSION=fixture DSR_KEEP_BUILD_STAGES=1
    declare -A _DSR_LOADED_MODULES=([packaging]=1 [artifact_naming]=1)
    # shellcheck disable=SC1090 # Use the actual command/state/publication consumers.
    source <(awk '/^(_dsr_require|cmd_build|_release_sha256|_release_require_publishable_artifacts)\(\) \{/{copy=1} copy{print} copy && /^\}/{copy=0}' "$ROOT/dsr") || return 1
    # shellcheck disable=SC1090
    source <(awk '/^json_envelope\(\) \{/{copy=1} copy{print} copy && /^# ====/{exit}' "$ROOT/dsr") || return 1
    check_strict_go() {
        local label="$1"; shift
        checks=$((checks + 1))
        if "$@"; then printf 'PASS: strict %s: %s\n' "$layout" "$label"
        else failures=$((failures + 1)); printf 'FAIL: strict %s: %s\n' "$layout" "$label" >&2; fi
    }
    if [[ "$layout" == replace ]]; then
        command cp "$work/dep/dep.go" "$work/original-dep.go" || return 1
        printf '\n// uncommitted dependency input\n' >> "$work/dep/dep.go"
        cmd_build strictgo --version 1.0.0 --output-dir "$work/dirty-output" \
            > "$work/dirty.json" 2> "$work/dirty.log" || status=$?
        check_strict_go 'dirty controller sibling refuses a strict build' test "$status" -ne 0
        check_strict_go 'dirty controller sibling reaches its specific source refusal' \
            grep -q 'Strict release checkout is dirty: dep' "$work/dirty.log"
        check_strict_go 'dirty controller sibling cannot reach compilation' test ! -e "$work/compiler-events"
        command cp "$work/original-dep.go" "$work/dep/dep.go" || return 1
        status=0
    fi
    cmd_build strictgo --version 1.0.0 --parallel=2 --output-dir "$work/output" \
        > "$work/result.json" 2> "$work/build.log" || status=$?
    check_strict_go 'public strict Go matrix completes' test "$status" -eq 0
    if [[ "$status" -ne 0 ]]; then
        cat "$work/build.log" >&2
        printf 'Strict Go %s: %s checks, %s failures\n' "$layout" "$checks" "$failures"
        return 1
    fi
    # The public orchestrator loads configuration in its worker process.
    # Initialize the same context for the direct verification/refusal calls.
    act_load_repo_config strictgo || return 1
    build_state_get strictgo 1.0.0 > "$work/state.json" || return 1
    run=$(jq -er .run_id "$work/state.json") || return 1
    source_root=$(jq -er '.context.source_roots.localnative' "$work/state.json") || return 1
    state_file="$DSR_STATE_DIR/builds/strictgo/1.0.0/$run/state.json"
    before_state=$(_act_sha256 "$state_file") || return 1
    before_events=$(_act_sha256 "$work/compiler-events") || return 1
    check_strict_go 'both native tasks complete' jq -e '
        .status=="completed" and (.target_statuses|length)==2 and
        all(.target_statuses[]; .status=="completed" and .result.status=="success")' "$work/state.json"
    check_strict_go 'public result returns both successful target artifacts' jq -e \
        --slurpfile state "$work/state.json" '
        .exit_code==0 and .details.success==2 and
        .details.run_id==$state[0].run_id and (.details.targets|length)==2 and
        all(.details.targets[]; .status=="success" and (.artifact_path|length)>0)' "$work/result.json"
    check_strict_go 'checkpoint retains the exact original snapshot custody receipt' jq -e \
        --arg sha "$source_sha" --arg source "$source_root" '
        .run_id as $run | .context.snapshot_owners.localnative |
        .git_sha==$sha and .run_id==$run and .source_root==$source and
        (.receipt_sha256|test("^[0-9a-f]{64}$"))' "$work/state.json"
    check_strict_go 'sealed manifest binds both published artifacts to pinned sibling revision' jq -e \
        --arg sha "$source_sha" --arg dependency "$sha" '
        .publishable==true and .status=="success" and .source.git_sha==$sha and
        .source.dependencies==[{relative_path:"dep",git_sha:$dependency}] and
        ([.artifacts[].target]|sort)==["linux/386","linux/amd64"]' "$work/output/strictgo-v1.0.0-manifest.json"
    artifact="$work/output/strictgo-linux-amd64"
    check_strict_go 'actual amd64 executable consumes the pinned sibling' test "$("$artifact" 2>&1)" = pinned-sibling-input
    check_strict_go 'actual 386 ELF contains the pinned sibling (no runtime claim)' python3 - "$work/output/strictgo-linux-386" <<'PY'
import pathlib,sys
data=pathlib.Path(sys.argv[1]).read_bytes()
assert data[:5]==b'\x7fELF\x01' and data[18:20]==b'\x03\x00'
assert b'pinned-sibling-input' in data
PY
    check_strict_go 'each target uses a distinct private output stage' test \
        "$(awk '{print $2}' "$work/compiler-events" | sort -u | wc -l | tr -d ' ')" -eq 2
    while read -r tree private_source; do
        check_strict_go "$tree stage is separate from the original snapshot" test "$private_source" != "$source_root"
        check_strict_go "$tree stage retains exact pinned sibling bytes" cmp "$work/dep/dep.go" "${private_source%/*}/dep/dep.go"
    done < "$work/compiler-events"
    check_strict_go 'builds leave the original main snapshot unchanged' test ! -e "$source_root/strictgo"
    check_strict_go 'builds leave both controller repositories clean' test -z \
        "$(git -C "$work/source" status --porcelain --untracked-files=all)$(git -C "$work/dep" status --porcelain --untracked-files=all)"
    check_strict_go 'original snapshots pass the complete post-build verifier' \
        _act_verify_strict_source_roots strictgo "$source_sha" "$(jq -c .context.source_roots "$work/state.json")"
    check_strict_go 'completed output passes release publication admission' \
        _release_require_publishable_artifacts "$work/output" "$work/output/strictgo-v1.0.0-manifest.json" true

    if [[ "$layout" == replace ]]; then
        # The copied byte verification must run after cp, not only against
        # the immutable original. Inject faults in the copy operation while
        # still running the genuine cp, verifier and native backend.
        export DSR_STAGE_MUTATION_LOG="$work/mutations"
        cp() {
            command cp "$@" || return $?
            local destination="${!#}"
            if [[ "$destination" == */dsr-build-strictgo-*/dep/ ]]; then
                printf '%s\n' "$DSR_STAGE_MUTATION" >> "$DSR_STAGE_MUTATION_LOG"
                case "$DSR_STAGE_MUTATION" in
                    bytes) printf 'package dep\nfunc Value() string { return "poisoned-copy" }\n' > "${destination}dep.go" ;;
                    extra) printf 'unexpected\n' > "${destination}extra.txt" ;;
                    mode) chmod +x "${destination}dep.go" ;;
                esac
            fi
        }
        export -f cp
        for mutation in bytes extra mode; do
            export DSR_STAGE_MUTATION="$mutation"
            status=0
            act_run_native_build strictgo linux/amd64 1.0.0 "copy-$mutation" \
                "$source_root" "$source_sha" v1.0.0 localnative \
                > "$work/copy-$mutation.json" 2> "$work/copy-$mutation.log" || status=$?
            check_strict_go "$mutation copy fault was actually injected" grep -qx "$mutation" "$work/mutations"
            check_strict_go "$mutation copied sibling refuses the target" test "$status" -ne 0
            check_strict_go "$mutation copied sibling never reaches the compiler" test \
                "$before_events" = "$(_act_sha256 "$work/compiler-events")"
            check_strict_go "$mutation copied sibling yields no collected artifact" jq -e \
                '.status=="failed" and .artifact_paths==[]' "$work/copy-$mutation.json"
        done
        unset -f cp
        unset DSR_STAGE_MUTATION DSR_STAGE_MUTATION_LOG
        check_strict_go 'copy tampering leaves original snapshot admission intact' \
            _act_verify_strict_source_roots strictgo "$source_sha" "$(jq -c .context.source_roots "$work/state.json")"

        mv "${source_root%/*}/dep" "$work/retained-dep" || return 1
        for mutation in missing linked; do
            [[ "$mutation" != linked ]] || ln -s "$work/retained-dep" "${source_root%/*}/dep" || return 1
            status=0
            act_run_native_build strictgo linux/amd64 1.0.0 "host-$mutation" \
                "$source_root" "$source_sha" v1.0.0 localnative \
                > "$work/host-$mutation.json" 2> "$work/host-$mutation.log" || status=$?
            check_strict_go "$mutation host sibling refuses the target" test "$status" -ne 0
            check_strict_go "$mutation host sibling never reaches the compiler" test \
                "$before_events" = "$(_act_sha256 "$work/compiler-events")"
            check_strict_go "$mutation host sibling yields no collected artifact" jq -e \
                '.status=="failed" and .artifact_paths==[]' "$work/host-$mutation.json"
        done
        status=0
        _act_verify_strict_source_roots strictgo "$source_sha" \
            "$(jq -c .context.source_roots "$work/state.json")" > "$work/final-refusal.log" 2>&1 || status=$?
        check_strict_go 'changed original snapshot fails the final source gate' test "$status" -ne 0
        check_strict_go 'refused retries preserve the completed checkpoint' test \
            "$before_state" = "$(_act_sha256 "$state_file")"
    fi
    printf 'Strict Go %s: %s checks, %s failures\n' "$layout" "$checks" "$failures"
    [[ "$failures" == 0 ]]
)

test_windows_strict_native() (
    local compiler="$1" dependency work
    case "$compiler" in go|bun) ;; *) return 4 ;; esac
    for dependency in bash git jq yq python3 pwsh "$compiler"; do
        command -v "$dependency" >/dev/null || { printf 'SKIP: Windows %s staging requires %s\n' "$compiler" "$dependency"; return 77; }
    done
    [[ $(uname -s) == Linux ]] || { printf 'SKIP: portable Windows transport fixture requires Linux\n'; return 77; }
    work=$(mktemp -d "${TMPDIR:-/tmp}/dsr-windows-$compiler.XXXXXXXX") || return 1
    printf 'Windows %s staging evidence: %s\n' "$compiler" "$work"
    python3 - "$work" "$ROOT" "${DSR_TEST_ACT_RUNNER:-$ROOT/src/act_runner.sh}" "$compiler" <<'PY'
import base64
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import shlex
import struct
import subprocess
import sys
import threading

work, root, engine = map(Path, sys.argv[1:4])
compiler = sys.argv[4]
checks = failures = 0
check_lock = threading.Lock()

def check(label, passed):
    global checks, failures
    with check_lock:
        checks += 1
        failures += not passed
        print(('PASS: ' if passed else 'FAIL: ') + label, flush=True)

def run(args, env=None, cwd=None, timeout=120):
    return subprocess.run([str(arg) for arg in args], env=env, cwd=cwd,
                          text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)

def require(result):
    if result.returncode:
        raise RuntimeError(result.stdout + result.stderr)
    return result.stdout

driver = work / 'driver.sh'
driver.write_text(r'''#!/usr/bin/env bash
set -uo pipefail
source "$PROBE_ROOT/src/logging.sh"
source "$PROBE_ROOT/src/config.sh"
source "$PROBE_ROOT/src/git_ops.sh"
source "$PROBE_ENGINE"
source "$PROBE_ROOT/src/artifact_naming.sh"
if [[ "$1" == native ]]; then
    shift
    # Explicit portable boundaries: host readiness, Windows launcher/JobObject
    # and SSH. Source planning/verification, compilation and collection are real.
    host_health_is_ready() { return 0; }
    _act_get_ssh_destination() { printf winfixture; }
    if [[ "${PROBE_FAULT:-}" == stage-collision ]]; then
        _act_generate_uuid() { printf 12345678-1234-4234-8234-123456789abc; }
    fi
    _act_windows_build_guard_script() {
        printf 'guard %s\n' "$1" >> "$PROBE_CASE/transport-events"
        printf '%s\n' "$2"
    }
    _act_windows_stage_build_script() {
        printf '%s\n' "$3" | python3 "$PROBE_WORK/transport.py" stage
    }
    _act_ssh_exec() { python3 "$PROBE_WORK/transport.py" execute "$2"; }
    act_load_repo_config strictwin || exit 4
    act_run_native_build strictwin "$1" 1.0.0 12345678-1234-4234-8234-123456789abc \
        C:/fixture/source "$(cat "$PROBE_CASE/source-sha")" v1.0.0 winfixture
else
    "$@"
fi
''', encoding='utf-8')
transport = work / 'transport.py'
transport.write_text(r"""import base64, json, os
from pathlib import Path
import re, shlex, subprocess, sys, uuid
case = Path(os.environ['PROBE_CASE'])
def mapped(value):
    return value.replace('C:/fixture', str(case / 'snapshot')).replace('C:\\fixture', str(case / 'snapshot')).replace('\\', '/')
operation = sys.argv[1]
if operation == 'stage':
    script = sys.stdin.read()
    fault = os.environ.get('PROBE_FAULT', '')
    if fault in ('stage-extra','stage-bytes','stage-link'):
        marker = "\n$ErrorActionPreference='Stop'\nAssert-DsrWindowsSourceRuntime"
        hook = r'''
$dsrOriginalExpand=(Get-Command Expand-DsrWindowsSourceSnapshot).ScriptBlock
function Expand-DsrWindowsSourceSnapshot {
    param($Plan,[string]$DestinationPath)
    & $dsrOriginalExpand -Plan $Plan -DestinationPath $DestinationPath
    if ($DestinationPath.EndsWith('/source')) {
        if ($env:PROBE_FAULT -ceq 'stage-extra') { [IO.File]::WriteAllText((Join-Path $DestinationPath 'unexpected.txt'),'untracked') }
        if ($env:PROBE_FAULT -ceq 'stage-bytes') { [IO.File]::AppendAllText((Join-Path $DestinationPath $env:PROBE_ENTRY),"`n// changed after authenticated expansion") }
        if ($env:PROBE_FAULT -ceq 'stage-link') { $null=[IO.File]::CreateSymbolicLink((Join-Path $DestinationPath 'unexpected-link'),(Join-Path $DestinationPath 'LICENSE')) }
    }
}
'''
        if marker not in script:
            raise RuntimeError('Missing real Windows staging boundary for fault injection')
        script = script.replace(marker, '\n' + hook + marker, 1)
    payload = case / ('payload-' + uuid.uuid4().hex + '.ps1')
    # Translate only the fixture's synthetic drive spelling. The production
    # PowerShell runtime, hashes, manifest rules and compiler program are kept.
    payload.write_text(script.replace('C:/fixture', str(case / 'snapshot')), encoding='utf-8')
    with (case / 'transport-events').open('a') as stream: stream.write('launcher\n')
    print(shlex.join(['pwsh','-NoLogo','-NoProfile','-NonInteractive','-File',str(payload)]))
    sys.exit(0)
command = sys.argv[-1]
parts = shlex.split(command)
if '-EncodedCommand' in parts:
    script = base64.b64decode(parts[parts.index('-EncodedCommand')+1]).decode('utf-16le')
    script = script.replace('C:/fixture', str(case / 'snapshot'))
    script = script.replace('C:\\fixture', str(case / 'snapshot')).replace('C:\fixture', str(case / 'snapshot'))
    if 'OpenStandardOutput' in script:
        with (case / 'transport-events').open('a') as stream: stream.write('collection\n')
    parts = ['pwsh','-NoLogo','-NoProfile','-NonInteractive','-Command',script]
sys.exit(subprocess.run(parts).returncode)
""", encoding='utf-8')
cmd = work / 'cmd-fixture'
cmd.write_text(r'''#!/usr/bin/env python3
import json, os
from pathlib import Path
import re, shlex, subprocess, sys
assert sys.argv[1:4] == ['/d','/s','/c'], sys.argv
command = ' '.join(sys.argv[4:])
case = Path(os.environ['PROBE_CASE'])
if os.environ.get('GOWORK','').startswith('C:/fixture/'):
    os.environ['GOWORK']=os.environ['GOWORK'].replace('C:/fixture',str(case/'snapshot'),1)
# The incumbent native command uses cmd's cd/set chain. Emulate precisely
# those fixture forms so the baseline also executes the genuine compiler.
match = re.match(r'^cd /d (?:"([^"]+)"|([^ &]+)) && ', command)
if match:
    path = (match[1] or match[2]).replace('\\','/').replace('C:/fixture',str(case/'snapshot'))
    os.chdir(path)
    command = command[match.end():]
while command.startswith('set '):
    match = re.match(r'^set (?:"([^"]*)"|(.+?)) && ',command)
    if not match: raise RuntimeError(command)
    name, equal, value = (match[1] or match[2]).partition('=')
    if equal != '=' or not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', name): raise RuntimeError(command)
    if value: os.environ[name] = value
    else: os.environ.pop(name,None)
    command = command[match.end():]
with (case / 'compiler-events').open('a') as stream:
    selected={name:os.getenv(name) for name in ('GOOS','GOARCH','GOENV','GOFLAGS','GOWORK','GOTOOLCHAIN',
              'GO111MODULE','GOAMD64','GOEXPERIMENT','GOROOT','GOCACHEPROG','PKG_CONFIG_PATH',
              'PKG_CONFIG_SYSROOT_DIR','PKG_CONFIG_DSR_UNREVIEWED','pkg_config_path',
              'PKG_CONFIG_LIBDIR','PKG_CONFIG_DSR_REVIEWED')}
    stream.write(json.dumps(dict(cwd=os.getcwd(),**selected)) + '\n')
result = subprocess.run(shlex.split(command))
if os.environ.get('PROBE_FAULT') == 'post-source':
    (case/'post-compiler-status.json').write_text(json.dumps(dict(exit_code=result.returncode,
        artifact=str(Path.cwd()/'strictwin.exe'))),encoding='utf-8')
    with (case/'snapshot'/'dep'/os.environ['PROBE_DEP_ENTRY']).open('a') as stream: stream.write('\n// changed by build process\n')
sys.exit(result.returncode)
''', encoding='utf-8')
cmd.chmod(0o700)
transports = work / 'transports'
transports.mkdir()
ssh = transports / 'ssh'
ssh.write_text('#!/bin/sh\nexec python3 "$PROBE_WORK/transport.py" ssh "$@"\n', encoding='utf-8')
ssh.chmod(0o700)
print(f'BOUNDARY: real PowerShell/Git archive verification/{compiler} PE compilation/held collection; fixture Windows drive, cmd, SSH, host-readiness and JobObject launcher; native Windows/NTFS are not qualified.', flush=True)
def run_layout(layout):
    case = work / layout
    language = 'go' if compiler == 'go' else ('bun' if layout == 'replace' else 'typescript')
    entry = 'main.go' if compiler == 'go' else 'main.ts'
    dep_entry = 'dep.go' if compiler == 'go' else 'dep.ts'
    for directory in ('source','dep','snapshot/source','snapshot/dep','config/repos.d','artifacts','logs','outside'):
        (case/directory).mkdir(parents=True, exist_ok=True)
    (case/'ambient-go-env').write_text('GOFLAGS=-this-persistent-flag-must-not-reach-go\n',encoding='utf-8')
    (case/'outside/go.work').write_text('go 1.19\nuse .\n',encoding='utf-8')
    (case/'outside/go.mod').write_text('module example.local/outside\n\ngo 1.19\n',encoding='utf-8')
    (case/'source'/'go.mod').write_text('module example.local/strictwin\n\ngo 1.19\n\nrequire example.local/dep v0.0.0\n' +
        ('replace example.local/dep => ../dep\n' if layout == 'replace' else ''), encoding='utf-8')
    if layout == 'workspace':
        (case/'source'/'go.work').write_text('go 1.19\n\nuse (\n .\n ../dep\n)\n', encoding='utf-8')
    (case/'source'/'main.go').write_text('package main\nimport "example.local/dep"\nfunc main(){println(dep.Value())}\n',encoding='utf-8')
    (case/'source'/'LICENSE').write_text('tracked materialized license\n',encoding='utf-8')
    (case/'source'/'license-copy.txt').symlink_to('LICENSE')
    (case/'dep'/'go.mod').write_text('module example.local/dep\n\ngo 1.19\n',encoding='utf-8')
    (case/'dep'/'dep.go').write_text('package dep\nfunc Value() string{return "pinned-windows-sibling"}\n',encoding='utf-8')
    if compiler == 'bun':
        (case/'source'/'package.json').write_text(json.dumps(dict(name='strictwin',version='1.0.0',type='module')),encoding='utf-8')
        (case/'source'/entry).write_text('import { value } from "../dep/dep.ts";\nconsole.log(value);\n',encoding='utf-8')
        (case/'dep'/dep_entry).write_text('export const value: string = "pinned-windows-sibling";\n',encoding='utf-8')
    shas = {}
    for name in ('source','dep'):
        require(run(['git','-C',case/name,'init','-q','-b','main']))
        require(run(['git','-C',case/name,'add','.']))
        require(run(['git','-C',case/name,'-c','user.name=Fixture','-c','user.email=fixture@example.invalid','commit','-qm','pinned']))
        shas[name] = require(run(['git','-C',case/name,'rev-parse','HEAD'])).strip()
    (case/'source-sha').write_text(shas['source'],encoding='utf-8')
    env = dict(os.environ, PROBE_WORK=str(work),PROBE_CASE=str(case),PROBE_ROOT=str(root),PROBE_ENGINE=str(engine),
        PROBE_ENTRY=entry,PROBE_DEP_ENTRY=dep_entry,
        DSR_CONFIG_DIR=str(case/'config'),ACT_CONFIG_DIR=str(case/'config'),ACT_REPOS_DIR=str(case/'config/repos.d'),
        DSR_HOSTS_FILE=str(case/'config/hosts.yaml'),DSR_REPOS_FILE=str(case/'config/repos.yaml'),
        ACT_ARTIFACTS_DIR=str(case/'artifacts'),ACT_LOGS_DIR=str(case/'logs'),DSR_CACHE_DIR=str(case/'cache'),
        DSR_STATE_DIR=str(case/'state'),DSR_KEEP_BUILD_STAGES='1',NO_COLOR='1',ComSpec=str(cmd),DOTNET_PROCESSOR_COUNT='1',
        PATH=str(transports)+os.pathsep+os.environ['PATH'],GOOS='linux',GOARCH='arm64',
        GOENV=str(case/'ambient-go-env'),GOWORK=str(case/'outside/go.work'),GO111MODULE='off',
        GOFLAGS='-this-ambient-flag-must-not-reach-go',GOTOOLCHAIN='go0.0.1',GOAMD64='v99',
        GOEXPERIMENT='dsr-invalid-experiment',GOROOT=str(case/'missing-toolchain'),
        GOCACHEPROG=str(case/'missing-cache-program'),PKG_CONFIG_PATH=str(case/'ambient-packages'),
        PKG_CONFIG_SYSROOT_DIR=str(case/'ambient-sysroot'),PKG_CONFIG_DSR_UNREVIEWED='ambient-selector',
        pkg_config_path=str(case/'lowercase-packages'))
    build_command = ('go build -o strictwin.exe .' if compiler == 'go' else
                     'bun build --compile --target=bun-windows-x64-baseline --outfile strictwin.exe main.ts')
    recipe = dict(tool_name='strictwin',repo='example/strictwin',language=language,binary_name='strictwin',
        local_path=str(case/'source'),targets=['windows/amd64'],hosts={'windows/amd64':'winfixture'},
        host_paths={'winfixture':'C:/fixture/source'},build_cmd=build_command,
        sibling_crates=[dict(local_path=str(case/'dep'),relative_path='dep',revision=shas['dep'])],
        env=dict(PATH=env['PATH'],GOENV='off',GOTOOLCHAIN='local',GOFLAGS='-p=1',GOMAXPROCS='1',
                 CGO_ENABLED='0',GOCACHE=str(work/'go-cache'),GOPROXY='off',GOSUMDB='off',
                 PKG_CONFIG_LIBDIR=str(case/'pkg-config'/'$DSR_GO_RECIPE_MARKER'),
                 PKG_CONFIG_DSR_REVIEWED='$DSR_GO_RECIPE_MARKER',GOWORK='off' if layout=='replace' else ''),
        release_contract=dict(checksum_sidecar='sha256',exact_primary_assets={'windows/amd64':'strictwin-windows-amd64.exe'}))
    config = case/'config/repos.d/strictwin.yaml'
    config.write_text(json.dumps(recipe),encoding='utf-8')
    (case/'config/hosts.yaml').write_text(json.dumps(dict(hosts={'winfixture':dict(platform='windows/amd64',connection='ssh')},
        platform_mapping={'windows/amd64':'winfixture'})),encoding='utf-8')
    def bash(*args): return run(['bash',driver,*args],env=env)
    evidence = []
    for name in ('source','dep'):
        prefix = 'source' if name=='source' else 'dependency-dep'
        archive = case/'snapshot'/('.'+prefix+'.tar')
        manifest = case/'snapshot'/('.'+prefix+'.manifest')
        require(bash('_act_write_git_archive_evidence',case/name,shas[name],archive))
        require(bash('_act_write_tracked_manifest',case/name,shas[name],manifest))
        archive_sha = hashlib.sha256(archive.read_bytes()).hexdigest()
        manifest_sha = hashlib.sha256(manifest.read_bytes()).hexdigest()
        count = require(bash('_act_tracked_manifest_object_count',manifest)).strip()
        program = require(bash('_act_windows_strict_snapshot_extract_script','winfixture',case/'snapshot'/name,
                               archive,manifest,archive_sha,manifest_sha,count))
        script = case/(name+'-extract.ps1'); script.write_text(program,encoding='utf-8')
        require(run(['pwsh','-NoLogo','-NoProfile','-NonInteractive','-File',script],env=env))
        evidence.append((name,archive,manifest,archive_sha,manifest_sha,count))
    def originals_valid():
        for name, archive, manifest, archive_sha, manifest_sha, count in evidence:
            program = require(bash('_act_windows_strict_snapshot_verify_script',case/'snapshot'/name,case/'snapshot',
                                   archive,manifest,manifest_sha,count,archive_sha))
            script = case/(name+'-verify.ps1'); script.write_text(program,encoding='utf-8')
            if run(['pwsh','-NoLogo','-NoProfile','-NonInteractive','-File',script],env=env).returncode: return False
        return True
    def events(name):
        path = case/name
        return path.read_text(encoding='utf-8').splitlines() if path.exists() else []
    def native(label):
        result = bash('native','windows/amd64')
        (case/(label+'.stdout')).write_text(result.stdout,encoding='utf-8')
        (case/(label+'.stderr')).write_text(result.stderr,encoding='utf-8')
        try: value = json.loads(result.stdout)
        except ValueError: value = {}
        return result,value
    def pe_amd64(path):
        data = path.read_bytes()
        offset = struct.unpack_from('<I',data,0x3c)[0]
        return data[:2]==b'MZ' and data[offset:offset+4]==b'PE\0\0' and struct.unpack_from('<H',data,offset+4)[0]==0x8664
    first,value = native('first')
    check(layout+': native build and held PE collection succeed',first.returncode==0 and value.get('status')=='success')
    artifacts = value.get('artifact_paths',[])
    check(layout+': collected bytes are real amd64 Windows PE',len(artifacts)==1 and pe_amd64(Path(artifacts[0])))
    observed = [json.loads(line) for line in events('compiler-events')]
    check(language+'/'+layout+': genuine compiler uses a private source directory',len(observed)==1 and
          '/dsr-build-' in observed[0]['cwd'])
    policy=value.get('build_influence_env',{})
    if compiler == 'go':
        check(layout+': configured target reaches real Go',len(observed)==1 and
              observed[0]['GOOS']=='windows' and observed[0]['GOARCH']=='amd64')
        check(layout+': normalized policy reaches Windows child and retained receipt',len(observed)==1 and
              observed[0]['GOENV']=='off' and observed[0]['GOFLAGS']=='-p=1' and observed[0]['GOTOOLCHAIN']=='local' and
              observed[0]['GO111MODULE']=='on' and
              observed[0]['GOWORK']==('off' if layout=='replace' else observed[0]['cwd']+'/go.work') and
              all(observed[0][name] is None for name in ('GOAMD64','GOEXPERIMENT','GOROOT','GOCACHEPROG')) and
              policy.get('DSR_GO_ENV_POLICY')=='2' and policy.get('GOENV')==observed[0]['GOENV'] and
              policy.get('GOFLAGS')==observed[0]['GOFLAGS'] and policy.get('GO111MODULE')==observed[0]['GO111MODULE'] and
              policy.get('GOOS')==observed[0]['GOOS'] and policy.get('GOARCH')==observed[0]['GOARCH'] and
              policy.get('DSR_GO_WORKFILE')==('' if layout=='replace' else 'source/go.work'))
        check(layout+': Windows child drops the entire ambient pkg-config selector family',len(observed)==1 and
              all(observed[0][name] is None and name not in policy for name in
                  ('PKG_CONFIG_PATH','PKG_CONFIG_SYSROOT_DIR','PKG_CONFIG_DSR_UNREVIEWED','pkg_config_path')))
        check(layout+': reviewed pkg-config values reach Windows child and receipt literally',len(observed)==1 and
              all(observed[0][name]==recipe['env'][name] and policy.get(name)==recipe['env'][name] for name in
                  ('PKG_CONFIG_LIBDIR','PKG_CONFIG_DSR_REVIEWED')))
    else:
        check(language+': native output does not claim the Go compiler policy','DSR_GO_ENV_POLICY' not in policy)
    originals_verified = originals_valid()
    check(layout+': original main and sibling snapshots still pass complete verifier',originals_verified)
    check(layout+': tracked file link is materialized in the private source',bool(observed) and
          not (Path(observed[0]['cwd'])/'license-copy.txt').is_symlink() and
          (Path(observed[0]['cwd'])/'license-copy.txt').read_bytes()==b'tracked materialized license\n')
    check(layout+': existing guarded launcher and stream collection remain in use',
          'launcher' in events('transport-events') and 'collection' in events('transport-events') and
          any(line.startswith('guard ') for line in events('transport-events')))
    if layout!='replace': return
    if first.returncode or value.get('status')!='success' or not originals_verified: return
    again,retry = native('retry')
    observed = [json.loads(line) for line in events('compiler-events')]
    check('same-target retry uses a fresh independent stage',again.returncode==0 and len(observed)==2 and
          observed[0]['cwd']!=observed[1]['cwd'] and len(retry.get('artifact_paths',[]))==1 and
          retry['artifact_paths'][0]!=artifacts[0])
    dep_path = case/'snapshot/dep'/dep_entry
    dep_bytes = dep_path.read_bytes()
    archive = case/'snapshot/.source.tar'; archive_bytes = archive.read_bytes()
    collision = case/'snapshot/dsr-build-strictwin-windows-amd64-12345678123442348234123456789abc'
    collision.mkdir()
    (collision/'sentinel').write_text('preexisting stage',encoding='utf-8')
    for fault in ('sibling-bytes','sibling-missing','archive-bytes','stage-extra','stage-bytes','stage-link','stage-collision','sibling-namespace'):
        before = len(events('compiler-events')); collections = events('transport-events').count('collection')
        env['PROBE_FAULT'] = fault
        if fault=='sibling-bytes': dep_path.write_bytes(dep_bytes+b'\n// changed\n')
        if fault=='sibling-missing': (case/'snapshot/dep').rename(case/'snapshot/held-dep')
        if fault=='archive-bytes': archive.write_bytes(archive_bytes+b'changed')
        if fault=='sibling-namespace':
            recipe['sibling_crates'][0]['relative_path']='Source'
            config.write_text(json.dumps(recipe),encoding='utf-8')
        rejected,result = native(fault)
        check(fault+': refused before compiler and collection',rejected.returncode!=0 and
              result.get('status')!='success' and len(events('compiler-events'))==before and
              events('transport-events').count('collection')==collections)
        if fault=='sibling-bytes': dep_path.write_bytes(dep_bytes)
        if fault=='sibling-missing': (case/'snapshot/held-dep').rename(case/'snapshot/dep')
        if fault=='archive-bytes': archive.write_bytes(archive_bytes)
        if fault=='sibling-namespace':
            recipe['sibling_crates'][0]['relative_path']='dep'
            config.write_text(json.dumps(recipe),encoding='utf-8')
    check('preexisting colliding stage remains intact',(collision/'sentinel').read_text(encoding='utf-8')=='preexisting stage' and
          sorted(path.name for path in collision.iterdir())==['sentinel'])
    env['PROBE_FAULT']=''
    recipe['build_cmd']=('go build -o strictwin.exe missing.go' if compiler == 'go' else
                         'bun build --compile --target=bun-windows-x64-baseline --outfile strictwin.exe missing.ts')
    config.write_text(json.dumps(recipe),encoding='utf-8')
    before=len(events('compiler-events')); collections=events('transport-events').count('collection')
    failed,result=native('compiler-failure')
    check('genuine '+compiler+' compilation failure retains failure and prevents collection',failed.returncode!=0 and
          result.get('status')=='failed' and len(events('compiler-events'))==before+1 and
          events('transport-events').count('collection')==collections)
    recipe['build_cmd']=build_command
    config.write_text(json.dumps(recipe),encoding='utf-8')
    env['PROBE_FAULT']='post-source'
    before=len(events('compiler-events')); collections=events('transport-events').count('collection')
    failed,result=native('post-source')
    completion_file=case/'post-compiler-status.json'
    completion=json.loads(completion_file.read_text(encoding='utf-8')) if completion_file.exists() else {}
    check('post-compiler source alteration prevents artifact collection',failed.returncode!=0 and
          result.get('status')!='success' and len(events('compiler-events'))==before+1 and
          events('transport-events').count('collection')==collections and completion.get('exit_code')==0 and
          pe_amd64(Path(completion['artifact'])))
    dep_path.write_bytes(dep_bytes); env['PROBE_FAULT']=''
    check('all original snapshots still verify after restored negative controls',originals_valid())
if compiler == 'bun':
    # Each language owns separate source/config/state/log/artifact directories;
    # the common transport programs are read-only. Keep the complete Bun fault
    # lifecycle and real TypeScript positive in the same bounded invocation.
    with ThreadPoolExecutor(max_workers=2) as executor:
        list(executor.map(run_layout, ('replace','workspace')))
else:
    for layout in ('replace','workspace'):
        run_layout(layout)
print(f'Windows strict {compiler} staging: {checks-failures} passed, {failures} failed',flush=True)
sys.exit(1 if failures else 0)
PY
)

test_strict_go_sibling_admission() (
    local layout="$1" dependency work config source_sha sibling_sha tree status=0 checks=0 failures=0
    local manifest shared_source private_source before_events original_config artifact run
    local go_work=off expected_targets=1
    local -a public_build_args=()
    for dependency in bash git jq yq python3 go tar; do
        command -v "$dependency" >/dev/null || { printf 'SKIP: strict Go siblings require %s\n' "$dependency"; return 77; }
    done
    [[ $(uname -s)/$(uname -m) == Linux/x86_64 && $(go version) == 'go version go'* ]] || {
        printf 'SKIP: strict Go siblings require Linux x86_64 and the Go compiler\n'; return 77;
    }
    work=$(mktemp -d "${DSR_TEST_DISK_ROOT:-${TMPDIR:-/tmp}}/dsr-strict-go-$layout.XXXXXXXX") || return 1
    printf 'Strict Go %s evidence: %s\n' "$layout" "$work"
    mkdir -p "$work/config/repos.d" "$work/source" "$work/dep" "$work/stages" "$work/tmp" || return 1
    export DSR_CONFIG_DIR="$work/config" ACT_CONFIG_DIR="$work/config" ACT_REPOS_DIR="$work/config/repos.d"
    export DSR_STATE_DIR="$work/state" DSR_CACHE_DIR="$work/cache"
    # Each parallel fixture owns its custody, artifacts, logs and temporary
    # files. Only the explicitly supplied compiled Go cache may be shared.
    export ACT_ARTIFACTS_DIR="$work/state/artifacts" ACT_LOGS_DIR="$work/state/logs" TMPDIR="$work/tmp"
    export DSR_HOSTS_FILE="$work/config/hosts.yaml" DSR_REPOS_FILE="$work/config/repos.yaml"
    export DSR_DISABLE_HOST_SELECTOR=1 RCH_DISABLED=1 RCH_CARGO_WRAPPER_BYPASS=1 NO_COLOR=1
    printf 'module example.local/strictsiblings\n\ngo 1.19\n\nrequire example.local/dep v0.0.0\n' > "$work/source/go.mod"
    printf 'package main\nimport("fmt"; "example.local/dep")\nfunc main() { fmt.Println(dep.Value()) }\n' > "$work/source/main.go"
    if [[ "$layout" == replace ]]; then
        printf 'replace example.local/dep => ../dep\n' >> "$work/source/go.mod"
    else
        printf 'go 1.19\n\nuse (\n  .\n  ../dep\n)\n' > "$work/source/go.work"
        go_work=""
    fi
    printf 'module example.local/dep\n\ngo 1.19\n' > "$work/dep/go.mod"
    printf 'package dep\nfunc Value() string { return "pinned-sibling-input" }\n' > "$work/dep/dep.go"
    for tree in source dep; do
        git -C "$work/$tree" init -q -b main || return 1
        git -C "$work/$tree" add . || return 1
        git -C "$work/$tree" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm pinned || return 1
    done
    git -C "$work/source" tag v1.0.0 || return 1
    source_sha=$(git -C "$work/source" rev-parse HEAD) || return 1
    sibling_sha=$(git -C "$work/dep" rev-parse HEAD) || return 1
    jq -n --arg work "$work" '{schema_version:"1.0.0",hosts:{localnative:{
        platform:"linux/amd64",connection:"local",concurrency:1,build_root:($work+"/stages")}},
        platform_mapping:{"linux/amd64":"localnative"}}' > "$DSR_HOSTS_FILE" || return 1
    config="$ACT_REPOS_DIR/strictsiblings.yaml"
    jq -n --arg work "$work" --arg path "$PATH" --arg sha "$sibling_sha" \
        --arg gowork "$go_work" --arg cache "${DSR_TEST_GOCACHE:-$work/go-cache}" '{
        tool_name:"strictsiblings",repo:"example/strictsiblings",local_path:($work+"/source"),
        language:"go",binary_name:"strictsiblings",targets:["linux/amd64"],
        act_job_map:{"linux/amd64":null},hosts:{"linux/amd64":"localnative"},
        sibling_crates:[{local_path:($work+"/dep"),relative_path:"dep",revision:$sha}],
        build_cmd:"printf \"%s\\n\" \"$PWD\" >> \"$PROBE_EVENTS\"; go build -buildvcs=false -o strictsiblings .",
        env:{PATH:$path,PROBE_EVENTS:($work+"/compiler-events"),GOCACHE:$cache,
          CGO_ENABLED:"0",GOENV:"off",GOTOOLCHAIN:"local",GOMAXPROCS:"2",
          GOWORK:$gowork,GOPROXY:"off",GOSUMDB:"off"},
        release_contract:{checksum_sidecar:"sha256",
          exact_primary_assets:{"linux/amd64":"strictsiblings-linux-amd64"}}}
        ' > "$config" || return 1
    if [[ "$layout" == matrix ]]; then
        expected_targets=2
        public_build_args=(--parallel=2)
        jq '.hosts.localnative.concurrency=2 |
            .platform_mapping["linux/386"]="localnative"' "$DSR_HOSTS_FILE" > "$work/matrix-hosts.json" || return 1
        mv "$work/matrix-hosts.json" "$DSR_HOSTS_FILE" || return 1
        jq --arg ready "$work/second-ready" '
            .targets += ["linux/386"] | .act_job_map["linux/386"]=null |
            .hosts["linux/386"]="localnative" |
            .release_contract.exact_primary_assets["linux/386"]="strictsiblings-linux-386" |
            .env.PROBE_READY=$ready |
            .build_cmd=("if [ \"$DSR_TARGET_ARCH\" = 386 ]; then touch \"$PROBE_READY\"; else count=0; while [ ! -e \"$PROBE_READY\" ] && [ \"$count\" -lt 600 ]; do sleep 0.05; count=$((count+1)); done; test -e \"$PROBE_READY\" || exit 9; fi; " + .build_cmd)
            ' "$config" > "$work/matrix-tool.json" || return 1
        mv "$work/matrix-tool.json" "$config" || return 1
    fi
    original_config=$(cat "$config") || return 1
    # shellcheck source=../../src/logging.sh
    source "$ROOT/src/logging.sh" || return 1
    # shellcheck source=../../src/config.sh
    source "$ROOT/src/config.sh" || return 1
    # shellcheck source=../../src/build_state.sh
    source "$ROOT/src/build_state.sh" || return 1
    # shellcheck source=../../src/act_runner.sh
    source "${DSR_TEST_ACT_RUNNER:-$ROOT/src/act_runner.sh}" || return 1
    # shellcheck source=../../src/artifact_naming.sh
    source "$ROOT/src/artifact_naming.sh" || return 1
    # shellcheck source=../../src/host_selector.sh
    source "$ROOT/src/host_selector.sh" || return 1
    # shellcheck source=../../src/host_health.sh
    source "$ROOT/src/host_health.sh" || return 1
    # shellcheck source=../../src/git_ops.sh
    source "$ROOT/src/git_ops.sh" || return 1
    # shellcheck source=../../src/packaging.sh
    source "$ROOT/src/packaging.sh" || return 1
    printf 'BOUNDARY: fixture host health/capacity; actual Git pins, snapshots, Go compiler, source verification, collection, checkpoint and publication\n'
    host_health_is_ready() { return 0; }
    selector_acquire_slot() { return 0; }
    selector_release_slot() { return 0; }
    build_state_init || return 1
    export SCRIPT_DIR="$ROOT" JSON_MODE=true DRY_RUN=false VERBOSE=false DSR_VERSION=fixture DSR_KEEP_BUILD_STAGES=1
    declare -A _DSR_LOADED_MODULES=([packaging]=1 [artifact_naming]=1)
    # shellcheck disable=SC1090 # Exercise the actual public command and state writer.
    source <(awk '/^(_dsr_require|cmd_build)\(\) \{/{copy=1} copy{print} copy && /^\}/{copy=0}' "$ROOT/dsr") || return 1
    # shellcheck disable=SC1090
    source <(awk '/^json_envelope\(\) \{/{copy=1} copy{print} copy && /^# ====/{exit}' "$ROOT/dsr") || return 1
    check_strict_go() {
        local label="$1"; shift
        checks=$((checks + 1))
        if "$@"; then printf 'PASS: strict %s: %s\n' "$layout" "$label"
        else failures=$((failures + 1)); printf 'FAIL: strict %s: %s\n' "$layout" "$label" >&2; fi
    }
    if [[ "$layout" == replace ]]; then
        check_strict_go 'default Go output permits private-stage concurrency' \
            _act_strict_go_output_stage_policy strictsiblings linux/amd64
        for tree in "$work/stages/source/bin" bin ../../shared; do
            jq --arg gobin "$tree" '.env.GOBIN=$gobin' <<< "$original_config" > "$config" || return 1
            status=0
            _act_strict_go_output_stage_policy strictsiblings linux/amd64 || status=$?
            check_strict_go "explicit GOBIN $tree retains conflict serialization" test "$status" -eq 1
        done
        jq '.env.GOBIN="global-output" | .cross_compile["linux/amd64"].env.GOBIN=""' \
            <<< "$original_config" > "$config" || return 1
        check_strict_go 'effective empty platform GOBIN restores private-stage eligibility' \
            _act_strict_go_output_stage_policy strictsiblings linux/amd64
        jq '.language="bun"' <<< "$original_config" > "$config" || return 1
        status=0
        _act_strict_go_output_stage_policy strictsiblings linux/amd64 || status=$?
        check_strict_go 'other strict languages retain conflict serialization' test "$status" -eq 1
        jq '.env="invalid"' <<< "$original_config" > "$config" || return 1
        status=0
        _act_strict_go_output_stage_policy strictsiblings linux/amd64 \
            > "$work/invalid-policy.out" 2> "$work/invalid-policy.log" || status=$?
        check_strict_go 'unreadable effective environment fails staging admission' test "$status" -eq 4
        mv "$config" "$work/retained-invalid-policy.json" || return 1
        status=0
        _act_strict_go_output_stage_policy strictsiblings linux/amd64 \
            > "$work/missing-policy.out" 2> "$work/missing-policy.log" || status=$?
        check_strict_go 'missing recipe cannot grant staging admission' test "$status" -eq 4
        printf '%s\n' "$original_config" > "$config" || return 1
        status=0
    fi
    cmd_build strictsiblings --version 1.0.0 "${public_build_args[@]}" --output-dir "$work/output" \
        > "$work/result.json" 2> "$work/build.log" || status=$?
    check_strict_go 'public pinned Go build completes' test "$status" -eq 0
    if [[ "$status" -ne 0 ]]; then cat "$work/build.log" >&2; return 1; fi
    manifest="$work/output/strictsiblings-v1.0.0-manifest.json"
    build_state_get strictsiblings 1.0.0 > "$work/state.json" || return 1
    check_strict_go 'manifest retains both exact Git identities and the completed artifact' jq -e \
        --arg source "$source_sha" --arg sibling "$sibling_sha" --argjson count "$expected_targets" '
        .status=="success" and .publishable==true and .source.git_sha==$source and
        .source.git_ref=="v1.0.0" and .source.dependencies==[{git_sha:$sibling,relative_path:"dep"}] and
        .summary.total==$count and .summary.success==$count and .summary.failed==0 and
        (.artifacts|length)==$count and
        ([.artifacts[].name]|sort)==(if $count==2 then
          ["strictsiblings-linux-386","strictsiblings-linux-amd64"] else ["strictsiblings-linux-amd64"] end)
        ' "$manifest"
    check_strict_go 'publication receipt seals the actual complete manifest' jq -e \
        --arg sha "$(_act_sha256 "$manifest")" '
        .publication_status=="completed" and .publishable==true and .manifest_sha256==$sha
        ' "$work/output/.dsr-build-purpose.json"
    artifact="$work/output/strictsiblings-linux-amd64"
    check_strict_go 'actual published executable consumes the pinned sibling' test "$("$artifact")" = pinned-sibling-input
    private_source=$(head -n 1 "$work/compiler-events") || return 1
    shared_source=$(jq -er '.context.source_roots.localnative' "$work/state.json") || return 1
    run=$(jq -er .run_id "$work/state.json") || return 1
    check_strict_go 'compiler runs outside the immutable source snapshot' test "$private_source" != "$shared_source"
    check_strict_go 'private sibling has the exact pinned bytes' cmp "$work/dep/dep.go" "${private_source%/*}/dep/dep.go"
    check_strict_go 'original source snapshot has no compiler output' test ! -e "$shared_source/strictsiblings"
    check_strict_go 'original sibling snapshot preserves its pinned bytes' cmp "$work/dep/dep.go" "${shared_source%/*}/dep/dep.go"
    check_strict_go 'controller source and dependency remain clean' test \
        -z "$(git -C "$work/source" status --porcelain --untracked-files=all)$(git -C "$work/dep" status --porcelain --untracked-files=all)"

    if [[ "$layout" == matrix ]]; then
        check_strict_go 'both parallel targets own distinct compiler source stages' test \
            "$(sort -u "$work/compiler-events" | wc -l | tr -d '[:space:]')" -eq 2
        while IFS= read -r private_source; do
            check_strict_go 'each target preserves the pinned private sibling' \
                cmp "$work/dep/dep.go" "${private_source%/*}/dep/dep.go"
            check_strict_go 'each target compiles outside the immutable source root' \
                test "$private_source" != "$shared_source"
        done < "$work/compiler-events"
        check_strict_go 'both artifacts have their actual ELF architecture and pinned input' python3 - "$work/output" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
for arch, elf_class, machine in [('amd64', 2, 62), ('386', 1, 3)]:
    payload = (root / ('strictsiblings-linux-' + arch)).read_bytes()
    assert payload[:4] == b'\x7fELF' and payload[4] == elf_class and payload[5] == 1
    assert int.from_bytes(payload[18:20], 'little') == machine
    assert b'pinned-sibling-input' in payload
PY
    fi

    if [[ "$layout" == replace ]]; then
        # Re-enter the real native backend with the completed immutable source
        # binding. Corruption must stop before its command, even though both
        # the host and controller retain an earlier successful executable.
        act_load_repo_config strictsiblings || return 1
        before_events=$(_act_sha256 "$work/compiler-events") || return 1
        refuse_strict_go_host() {
            local label="$1" rc=0
            act_run_native_build strictsiblings linux/amd64 1.0.0 "$run" "$shared_source" \
                "$source_sha" v1.0.0 localnative > "$work/$label.json" 2> "$work/$label.log" || rc=$?
            check_strict_go "$label refuses the native attempt" test "$rc" -ne 0
            check_strict_go "$label never starts the compiler command" test \
                "$before_events" = "$(_act_sha256 "$work/compiler-events")"
            check_strict_go "$label cannot collect previous successful output" jq -es '
                all(.[]; (.status // "failed") != "success" and (.artifact_paths // [])==[])
                ' "$work/$label.json"
        }
        mv "${shared_source%/*}/dep" "$work/retained-host-dep" || return 1
        refuse_strict_go_host missing-sibling
        ln -s "$work/retained-host-dep" "${shared_source%/*}/dep" || return 1
        refuse_strict_go_host linked-sibling
        mv "${shared_source%/*}/dep" "$work/retained-link" || return 1
        mv "$work/retained-host-dep" "${shared_source%/*}/dep" || return 1
        cp "${shared_source%/*}/dep/dep.go" "$work/retained-dep.go" || return 1
        printf 'package dep\nfunc Value() string { return "changed-host-input" }\n' > "${shared_source%/*}/dep/dep.go"
        refuse_strict_go_host changed-sibling
        cp "$work/retained-dep.go" "${shared_source%/*}/dep/dep.go" || return 1
        chmod +x "${shared_source%/*}/dep/dep.go" || return 1
        refuse_strict_go_host changed-mode
        chmod -x "${shared_source%/*}/dep/dep.go" || return 1
        printf 'package dep\n' > "${shared_source%/*}/dep/extra.go"
        refuse_strict_go_host extra-sibling-input
        mv "${shared_source%/*}/dep/extra.go" "$work/retained-extra.go" || return 1

        for tree in '../dep' source SOURCE cargo-home; do
            jq --arg name "$tree" '.sibling_crates[0].relative_path=$name' \
                <<< "$original_config" > "$config" || return 1
            status=0
            act_run_native_build strictsiblings linux/amd64 1.0.0 "$run" "$shared_source" \
                "$source_sha" v1.0.0 localnative > "$work/layout.json" 2> "$work/layout.log" || status=$?
            check_strict_go "escaping or reserved layout $tree is refused" test "$status" -ne 0
            check_strict_go "layout $tree cannot reach the compiler" test \
                "$before_events" = "$(_act_sha256 "$work/compiler-events")"
        done
        jq '.sibling_crates += [.sibling_crates[0] + {relative_path:"DEP"}]' \
            <<< "$original_config" > "$config" || return 1
        status=0
        act_run_native_build strictsiblings linux/amd64 1.0.0 "$run" "$shared_source" \
            "$source_sha" v1.0.0 localnative > "$work/ambiguous.json" 2> "$work/ambiguous.log" || status=$?
        check_strict_go 'case-ambiguous pinned sibling names are refused' test "$status" -ne 0
        check_strict_go 'ambiguous layout never reaches the compiler' test \
            "$before_events" = "$(_act_sha256 "$work/compiler-events")"

        # Actual build-command mutation of the original pinned checkout must
        # still be caught after compilation; success of the private copy does
        # not authorize a publishable result with changed release inputs.
        jq --arg dep "$work/dep/dep.go" '
            .build_cmd=("printf mutation >> \"$PROBE_ORIGINAL\"; " + .build_cmd) |
            .env.PROBE_ORIGINAL=$dep' <<< "$original_config" > "$config" || return 1
        status=0
        cmd_build strictsiblings --version 1.0.0 --output-dir "$work/drift-output" \
            > "$work/drift.json" 2> "$work/drift.log" || status=$?
        check_strict_go 'post-compiler controller drift refuses public completion' test "$status" -ne 0
        check_strict_go 'post-compiler drift is detected after a real additional command' test \
            "$(wc -l < "$work/compiler-events" | tr -d '[:space:]')" -eq 2
        check_strict_go 'failed drift run retains non-publishable output custody' jq -e \
            '.publishable==false and .publication_status=="pending"' "$work/drift-output/.dsr-build-purpose.json"
        check_strict_go 'prior successful publication stays unchanged' test \
            "$("$artifact")" = pinned-sibling-input
    fi
    printf 'Strict Go %s: %s checks, %s failures\n' "$layout" "$checks" "$failures"
    [[ "$failures" == 0 ]]
)

test_windows_source_links() (
    local dependency work backend
    for dependency in bash git python3 pwsh yq jq; do
        command -v "$dependency" >/dev/null 2>&1 || {
            printf 'SKIP: Windows source links require %s\n' "$dependency"
            return 77
        }
    done
    work=$(mktemp -d "${TMPDIR:-/tmp}/dsr-windows-source-links.XXXXXXXX") || return 1
    printf 'Windows source-link evidence: %s\n' "$work"
    backend="${DSR_WINDOWS_SOURCE_BACKEND:-$ROOT/src/source_snapshot_windows.ps1}"
    [[ -f "$backend" ]] || return 3
    # Git index plumbing creates authentic 120000 blobs without creating an
    # origin filesystem link or requiring Windows symlink privileges.
    python3 - "$work" "$ROOT" "${DSR_TEST_ACT_RUNNER:-$ROOT/src/act_runner.sh}" <<'PY' || return 1
import hashlib
import base64
import copy
import io
import json
import os
from pathlib import Path, PurePosixPath
import shlex
import subprocess
import sys
import tarfile

work = Path(sys.argv[1])
root = Path(sys.argv[2])
runner = Path(sys.argv[3])
environment = {key: value for key, value in os.environ.items() if not key.upper().startswith('GIT_')}
environment.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
                   GIT_AUTHOR_NAME='DSR source fixture', GIT_AUTHOR_EMAIL='fixture@example.invalid',
                   GIT_COMMITTER_NAME='DSR source fixture', GIT_COMMITTER_EMAIL='fixture@example.invalid',
                   GIT_AUTHOR_DATE='2026-01-01T00:00:00Z', GIT_COMMITTER_DATE='2026-01-01T00:00:00Z')
cases = []

def git(repo, *args, data=None):
    return subprocess.run(['git', '-c', 'core.autocrlf=false', '-c', 'core.protectNTFS=false',
                           '-C', str(repo), *args], input=data, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, env=environment, check=True).stdout

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def fixture(name, files, links=None, accepted=False, gitlinks=()):
    directory = work / name
    repo = directory / 'repo'
    repo.mkdir(parents=True)
    git(repo, 'init', '-q', '--initial-branch=main', '--object-format=sha1')
    links = links or {}
    contents = {}
    for path, value in files.items():
        mode, data = value if isinstance(value, tuple) else ('100644', value)
        oid = git(repo, 'hash-object', '-w', '--stdin', data=data).decode().strip()
        git(repo, 'update-index', '--add', '--cacheinfo', mode + ',' + oid + ',' + path)
        contents[path] = dict(oid=oid, sha256=hashlib.sha256(data).hexdigest(), length=len(data))
    for path, target in links.items():
        oid = git(repo, 'hash-object', '-w', '--stdin', data=target.encode('ascii')).decode().strip()
        git(repo, 'update-index', '--add', '--cacheinfo', '120000,' + oid + ',' + path)
    for path in gitlinks:
        tree = git(repo, 'mktree', data=b'').decode().strip()
        revision = git(repo, 'commit-tree', tree, '-m', 'gitlink fixture').decode().strip()
        git(repo, 'update-index', '--add', '--cacheinfo', '160000,' + revision + ',' + path)
    git(repo, 'commit', '-qm', 'tracked source fixture')
    archive = directory / 'source.tar'
    archive.write_bytes(git(repo, 'archive', '--format=tar', 'HEAD'))
    manifest = directory / 'source.manifest'
    rows = []
    directories = set()
    for record in git(repo, 'ls-tree', '-rz', '--full-tree', 'HEAD').split(b'\0'):
        if not record:
            continue
        metadata, path = record.decode('ascii').split('\t', 1)
        mode, kind, oid = metadata.split(' ')
        assert kind == 'blob' or (kind == 'commit' and mode == '160000')
        rows.append((oid, mode, path))
        if mode == '160000':
            directories.add(path)
        parent = PurePosixPath(path).parent
        while str(parent) != '.':
            directories.add(str(parent))
            parent = parent.parent
    manifest.write_text(''.join('\t'.join(row) + '\n' for row in rows), encoding='ascii')
    materialized = 0
    if accepted:
        import posixpath
        for path, target in links.items():
            referent = posixpath.normpath(posixpath.join(posixpath.dirname(path), target))
            contents[path] = dict(contents[referent], referent=referent)
            materialized += contents[referent]['length']
    result = dict(name=name, archive=str(archive), manifest=str(manifest),
                  archive_sha256=digest(archive), manifest_sha256=digest(manifest),
                  object_count=len(rows) + len(directories) - len(gitlinks), accepted=accepted,
                  files=contents if accepted else {}, directories=sorted(directories), links=links,
                  expanded_bytes=sum(value['length'] for value in contents.values()),
                  materialized_bytes=materialized)
    cases.append(result)
    return result

safe = fixture('safe', {'source/input.txt': b'authenticated input\n',
    'source/run.ps1': ('100755', b'Write-Output "tracked executable"\n'),
    'source/empty.txt': b'', 'source/space name.txt': b'spaces are literal\n'},
    {'file-link': 'source/input.txt', 'nested/relative-link': '../source/input.txt',
     'executable-link': 'source/run.ps1', 'empty-link': 'source/empty.txt',
     'space-link': 'source/space name.txt', 'dot-link': './source/../source/input.txt'}, True)
long_name = 'long/' + 'a' * 200 + '.txt'
fixture('pax-long-path-and-link', {long_name: b'long Git PAX path\n'},
        {'long-link': long_name}, True)
expansion = fixture('expansion', {'source/payload.bin': bytes(range(256)) * 256},
                    {'copy-' + str(index): 'source/payload.bin' for index in range(12)}, True)
assert expansion['expanded_bytes'] > 2 * Path(expansion['archive']).stat().st_size
fixture('regular-only', {'plain.txt': b'unchanged regular source\n', 'nested/empty': b''}, accepted=True)
fixture('empty-gitlink', {'plain.txt': b'gitlink sibling\n'}, accepted=True, gitlinks=('vendor/dep',))

def submodule_fixture(name, specification, accepted=False):
    directory = work / name
    repo = directory / 'repo'
    rows, members, contents, links, directories = [], [], {}, {}, set()

    def populate(checkout, selected, prefix=''):
        checkout.mkdir(parents=True)
        git(checkout, 'init', '-q', '--initial-branch=main', '--object-format=sha1')
        children = selected.get('children', {})
        for path, child in children.items():
            revision = populate(checkout / path, child, prefix + path + '/')
            git(checkout, 'update-index', '--add', '--cacheinfo', '160000,' + revision + ',' + path)
        for path, value in selected.get('files', {}).items():
            mode, data = value if isinstance(value, tuple) else ('100644', value)
            oid = git(checkout, 'hash-object', '-w', '--stdin', data=data).decode().strip()
            git(checkout, 'update-index', '--add', '--cacheinfo', mode + ',' + oid + ',' + path)
            contents[prefix + path] = dict(oid=oid, sha256=hashlib.sha256(data).hexdigest(), length=len(data))
        for path, target in selected.get('links', {}).items():
            oid = git(checkout, 'hash-object', '-w', '--stdin', data=target.encode('ascii')).decode().strip()
            git(checkout, 'update-index', '--add', '--cacheinfo', '120000,' + oid + ',' + path)
            links[prefix + path] = target
        tree = git(checkout, 'write-tree').decode().strip()
        revision = git(checkout, 'commit-tree', tree, '-m', 'pinned project submodule fixture').decode().strip()
        git(checkout, 'update-ref', 'refs/heads/main', revision)
        for record in git(checkout, 'ls-tree', '-rz', '--full-tree', revision).split(b'\0'):
            if not record:
                continue
            metadata, path = record.decode('ascii').split('\t', 1)
            mode, kind, oid = metadata.split(' ')
            full = prefix + path
            rows.append((oid, mode, full))
            if mode == '160000':
                directories.add(full)
            parent = PurePosixPath(full).parent
            while str(parent) != '.':
                directories.add(str(parent))
                parent = parent.parent
        # Negative receiver controls retain genuine parent/child Git output.
        # They bypass only the controller's admission so the independent
        # receiver must still reject links that cross a repository boundary.
        if children or selected.get('files') or selected.get('links'):
            with tarfile.open(fileobj=io.BytesIO(git(checkout, 'archive', '--format=tar', revision))) as source:
                for member in source:
                    entry = copy.copy(member)
                    entry.name = prefix + entry.name
                    entry.pax_headers = {}
                    data = source.extractfile(member).read() if member.isfile() else None
                    members.append((entry, data))
        return revision

    revision = populate(repo, specification)
    archive, manifest = directory / 'source.tar', directory / 'source.manifest'
    if accepted:
        # These are the actual coordinator exporters, not a parallel fixture
        # implementation of their object authentication or archive format.
        program = 'source "$1" || exit; _act_write_git_archive_evidence "$2" "$3" "$4" && _act_write_tracked_manifest "$2" "$3" "$5"'
        exported = subprocess.run(['bash', '-c', program, 'fixture', str(runner), str(repo), revision,
                                   str(archive), str(manifest)], env=environment,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        (directory / 'controller-export.log').write_bytes(exported.stderr)
        if exported.returncode:
            raise RuntimeError('Native project-submodule export failed: ' + name + '\n' + exported.stderr.decode())
        actual_rows = [tuple(line.split('\t')) for line in manifest.read_text().splitlines()]
        assert sorted(actual_rows) == sorted(rows), (name, actual_rows, rows)
    else:
        with tarfile.open(archive, 'w', format=tarfile.PAX_FORMAT) as output:
            for entry, data in sorted(members, key=lambda item: item[0].name):
                output.addfile(entry, io.BytesIO(data) if data is not None else None)
        manifest.write_text(''.join('\t'.join(row) + '\n' for row in sorted(rows, key=lambda row: row[2])), encoding='ascii')
    materialized = 0
    if accepted:
        import posixpath
        for path, target in links.items():
            referent = posixpath.normpath(posixpath.join(posixpath.dirname(path), target))
            contents[path] = dict(contents[referent], referent=referent)
            materialized += contents[referent]['length']
    value = dict(name=name, archive=str(archive), manifest=str(manifest),
                 archive_sha256=digest(archive), manifest_sha256=digest(manifest),
                 object_count=len(directories) + sum(row[1] != '160000' for row in rows),
                 accepted=accepted, files=contents if accepted else {}, directories=sorted(directories),
                 links=links, expanded_bytes=sum(item['length'] for item in contents.values()),
                 materialized_bytes=materialized)
    cases.append(value)
    return value

submodule_spec = {'files': {'root.txt': b'parent repository\n'}, 'children': {
    'vendor/dep': {'files': {'data.txt': b'pinned child source\n', 'run.ps1': ('100755', b'Write-Output "child"\n')},
                   'links': {'copy.txt': 'data.txt', 'nested/local-link': '../data.txt'},
                   'children': {'inner': {'files': {'leaf.txt': b'pinned nested source\n'},
                                          'links': {'leaf-copy': 'leaf.txt'}}, 'empty': {}}},
    'vendor/other': {'files': {'other.txt': b'independent pinned child\n'}}}}
submodule_fixture('project-submodules', submodule_spec, True)
for name, owner, path, target in (
    ('parent-to-child', '', 'link', 'vendor/dep/data.txt'),
    ('parent-enters-and-leaves-child', '', 'link', 'vendor/dep/../../root.txt'),
    ('child-to-parent', 'vendor/dep', 'link', '../../root.txt'),
    ('child-leaves-and-reenters', 'vendor/dep', 'link', '../dep/data.txt'),
    ('child-to-sibling', 'vendor/dep', 'link', '../other/other.txt'),
    ('child-to-nested', 'vendor/dep', 'link', 'inner/leaf.txt'),
    ('child-enters-and-leaves-nested', 'vendor/dep', 'link', 'inner/../data.txt'),
    ('nested-to-parent', 'vendor/dep/inner', 'link', '../data.txt'),
):
    selected = copy.deepcopy(submodule_spec)
    destination = selected
    if owner:
        destination = destination['children']['vendor/dep']
        if owner.endswith('/inner'):
            destination = destination['children']['inner']
    destination.setdefault('links', {})[path] = target
    submodule_fixture(name, selected)

base = {'source/input.txt': b'authenticated input\n'}
for name, links in (
    ('absolute-posix', {'link': '/outside.txt'}),
    ('absolute-windows', {'link': 'C:/outside.txt'}),
    ('backslash-target', {'link': r'source\input.txt'}),
    ('unc-target', {'link': '//server/share/input.txt'}),
    ('escape', {'nested/link': '../../outside.txt'}),
    ('dangling', {'link': 'source/missing.txt'}),
    ('directory-link', {'link': 'source'}),
    ('self-cycle', {'link': 'link'}),
    ('two-link-cycle', {'left': 'right', 'right': 'left'}),
    ('link-chain', {'first': 'second', 'second': 'source/input.txt'}),
    ('wrong-referent-case', {'link': 'SOURCE/input.txt'}),
    ('file-as-parent', {'link': 'source/input.txt/../input.txt'}),
):
    fixture(name, base, links)
fixture('file-case-collision', {'Case.txt': b'one', 'case.txt': b'two'})
fixture('directory-case-collision', {'Dir/a.txt': b'one', 'dir/b.txt': b'two'})
fixture('file-directory-case-collision', {'node': b'one', 'NODE/child.txt': b'two'})
fixture('reserved-device-name', {'AUX.txt': b'not a Windows plain file'})
fixture('trailing-dot-name', {'source/file.': b'not a literal Windows name'})

for name, selected in (('link-oid-mismatch', 'file-link'), ('referent-oid-mismatch', 'source/input.txt')):
    value = fixture(name, base, {'file-link': 'source/input.txt'})
    manifest = Path(value['manifest'])
    rewritten = []
    for line in manifest.read_text().splitlines():
        oid, mode, path = line.split('\t')
        rewritten.append('\t'.join(('0' * 40 if path == selected else oid, mode, path)))
    manifest.write_text('\n'.join(rewritten) + '\n', encoding='ascii')
    value['manifest_sha256'] = digest(manifest)

# Both archives are genuine Git output. The second link has an equally sized,
# equally hashed referent, so only authentication of the link blob can reject it.
original = fixture('original-link-authority', {'a.txt': b'same', 'b.txt': b'same'}, {'link': 'a.txt'}, True)
changed = fixture('changed-link-target', {'a.txt': b'same', 'b.txt': b'same'}, {'link': 'b.txt'})
Path(changed['manifest']).write_bytes(Path(original['manifest']).read_bytes())
changed['manifest_sha256'] = digest(Path(changed['manifest']))

for name, field, replacement in (
    ('wrong-held-manifest', 'manifest_sha256', '0' * 64),
    ('wrong-held-archive', 'archive_sha256', '0' * 64),
    ('wrong-object-count', 'object_count', safe['object_count'] + 1),
):
    value = dict(safe, name=name, accepted=False)
    value[field] = replacement
    cases.append(value)

(work / 'cases.json').write_text(json.dumps(cases, indent=2) + '\n', encoding='utf-8')
# Execute the actual emitted receiver programs as well as the helper API.
# Only the host's optional split-storage configuration is absent here.
generator_env = dict(environment, DSR_CONFIG_DIR=str(work / 'config'),
                     DSR_HOSTS_FILE=str(work / 'no-hosts.yaml'), DSR_STATE_DIR=str(work / 'state'),
                     DSR_CACHE_DIR=str(work / 'cache'), NO_COLOR='1', POWERSHELL_TELEMETRY_OPTOUT='1',
                     DOTNET_CLI_TELEMETRY_OPTOUT='1', POWERSHELL_UPDATECHECK='Off')
generator = 'source "$1" || exit; shift; "$@"'
for case in cases:
    if case['name'] not in ('safe', 'pax-long-path-and-link', 'regular-only', 'empty-gitlink', 'changed-link-target', 'project-submodules', 'parent-to-child', 'child-to-parent'):
        continue
    destination = work / ('emitted-' + case['name'])
    destination.mkdir()
    for kind, arguments in (
        ('extract', ['_act_windows_strict_snapshot_extract_script', 'source-fixture', str(destination),
                     case['archive'], case['manifest'], case['archive_sha256'],
                     case['manifest_sha256'], str(case['object_count'])]),
        ('verify', ['_act_windows_strict_snapshot_verify_script', str(destination), str(work),
                    case['archive'], case['manifest'], case['manifest_sha256'],
                    str(case['object_count']), case['archive_sha256']]),
    ):
        result = subprocess.run(['bash', '-c', generator, 'fixture', str(runner), *arguments],
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=generator_env)
        (work / (case['name'] + '-' + kind + '-generation.log')).write_bytes(result.stderr)
        if result.returncode:
            raise RuntimeError('Receiver generation failed: ' + case['name'] + ' ' + kind + '\n' + result.stderr.decode())
        (work / (case['name'] + '-' + kind + '.ps1')).write_bytes(result.stdout)

# The production encoder is exercised unchanged. Only retained-file transport
# is a controlled boundary; no SSH, Windows launcher or NTFS proof is claimed.
short_program = "Write-Output 'source-command-short'"
long_program = (work / 'safe-verify.ps1').read_text().rstrip('\n')
transport_checks = []
boundary = '''source "$1" || exit; shift
program="$1"; mode="$2"; directory="$3"
_act_windows_stage_build_script() {
    printf '%s\\n%s\\n' "$1" "$2" > "$directory/arguments"
    printf '%s' "$3" > "$directory/program"
    [[ "$mode" != failure ]] || return 73
    printf 'retained-source-command'
}
_act_windows_source_command source-fixture C:/owned/source "$program"
'''
for name, program, mode in (('short', short_program, 'success'),
                            ('long', long_program, 'success'), ('long-failure', long_program, 'failure')):
    directory = work / ('transport-' + name)
    directory.mkdir()
    result = subprocess.run(['bash', '-c', boundary, 'fixture', str(runner), program, mode, str(directory)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=generator_env)
    (directory / 'out').write_bytes(result.stdout)
    (directory / 'err').write_bytes(result.stderr)
    if name == 'short':
        command = shlex.split(result.stdout.decode())
        decoded = base64.b64decode(command[-1]).decode('utf-16-le') if command else ''
        transport_checks.append(dict(label='short source command uses actual PowerShell encoding',
            passed=result.returncode == 0 and command[:4] == ['pwsh','-NoProfile','-NonInteractive','-EncodedCommand']
            and decoded == "$ProgressPreference='SilentlyContinue'; " + short_program))
        transport_checks.append(dict(label='short source command avoids retained staging', passed=not (directory / 'program').exists()))
        executed = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=generator_env) if command else None
        transport_checks.append(dict(label='short encoded source command executes in genuine PowerShell',
            passed=executed is not None and executed.returncode == 0 and executed.stdout.strip() == b'source-command-short'))
    else:
        transport_checks.append(dict(label=name + ' retains exact host/root/program at the transport boundary',
            passed=(directory / 'arguments').read_text() == 'source-fixture\nC:/owned/source\n'
            and (directory / 'program').read_text() == long_program))
        transport_checks.append(dict(label=name + ' preserves staging result',
            passed=(result.returncode == 73 and result.stdout == b'') if mode == 'failure'
            else result.returncode == 0 and result.stdout == b'retained-source-command'))
direct = subprocess.run(['bash', '-c', generator, 'fixture', str(runner),
                         '_act_windows_encoded_powershell', long_program, 'pwsh'],
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=generator_env)
transport_checks.append(dict(label='actual complete verifier exceeds the encoder limit and requires staging',
                             passed=direct.returncode != 0 and direct.stdout == b''))
(work / 'transport-checks.json').write_text(json.dumps(transport_checks), encoding='utf-8')

# Exercise both actual storage-admission programs against the same real plan
# and retained inputs. A temporary FileSystem PSDrive maps the drive spelling;
# only CIM's free-space observation is controlled to straddle the boundary.
drive_probe = subprocess.run(['pwsh','-NoLogo','-NoProfile','-NonInteractive','-Command',
    "@('Q','P','O','N','M','L','K') | Where-Object { -not (Get-PSDrive -Name $_ -ErrorAction SilentlyContinue) } | Select-Object -First 1"],
    stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=generator_env, check=True)
drive = drive_probe.stdout.decode().strip()
assert drive in 'QPONMLK' and len(drive) == 1
storage = dict(drive='Z', export='/fixture', server='fixture.invalid', source_budget_bytes=2147483648,
               source_drive=drive, source_reserve_bytes=8589934592, target_min_free_bytes=21474836480)
hosts = work / 'storage-hosts.json'
hosts.write_text(json.dumps({'hosts': {'source-fixture': {'windows_storage': storage}}}), encoding='utf-8')
budget_env = dict(generator_env, DSR_HOSTS_FILE=str(hosts))
for phase in ('archive', 'expansion'):
    result = subprocess.run(['bash','-c',generator,'fixture',str(runner),
        '_act_windows_source_budget_script','source-fixture',drive + ':/owned',
        str(Path(expansion['archive']).stat().st_size),str(expansion['object_count']),phase],
        stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=budget_env,check=True)
    assert result.stdout
    (work / ('budget-' + phase + '.ps1')).write_bytes(result.stdout)
(work / 'budget.json').write_text(json.dumps(dict(drive=drive, reserve=storage['source_reserve_bytes'])), encoding='utf-8')
print('Genuine Git source cases:', len(cases))
PY
    cat > "$work/check.ps1" <<'POWERSHELL'
param([string]$FixtureRoot, [string]$BackendPath)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. $BackendPath
$checks=0; $failures=0
function Check {
    param([string]$Label, [bool]$Condition)
    $script:checks++
    if ($Condition) { Write-Output ('PASS ' + $Label) }
    else { $script:failures++; [Console]::Error.WriteLine('FAIL ' + $Label) }
}
function Refused {
    param([string]$Label, [scriptblock]$Action, [string]$Pattern='')
    $failure=$null
    try { $null=& $Action } catch { $failure=$_ }
    Check $Label ($null -ne $failure -and (-not $Pattern -or $failure.Exception.Message -match $Pattern))
    if ($null -ne $failure) { Write-Output ('  refusal: ' + $failure.Exception.Message) }
}
function Plan {
    param($Case)
    Get-DsrWindowsSourcePlan -ArchivePath $Case.archive -ManifestPath $Case.manifest `
        -ExpectedManifestSha256 $Case.manifest_sha256 -ExpectedObjectCount $Case.object_count `
        -ExpectedArchiveSha256 $Case.archive_sha256
}
function Hash {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Empty-Root {
    param([string]$Name)
    $path=Join-Path $FixtureRoot ('output-' + $Name)
    $null=[IO.Directory]::CreateDirectory($path)
    return $path
}
Assert-DsrWindowsSourceRuntime
Write-Output ('Runtime: PowerShell ' + $PSVersionTable.PSVersion + '; platform ' + [Environment]::OSVersion.Platform)
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    Write-Output 'Unix execution: genuine PowerShell/IO/Git archives; native Windows and NTFS are not qualified.'
}
$cases=Get-Content -LiteralPath (Join-Path $FixtureRoot 'cases.json') -Raw | ConvertFrom-Json
foreach ($case in $cases) {
    if (-not $case.accepted) { Refused $case.name { Plan $case }; continue }
    try {
        $plan=Plan $case
        Check ($case.name + ' controller archive digest') ($plan.ArchiveSha256 -ceq $case.archive_sha256)
        Check ($case.name + ' controller manifest digest') ($plan.ManifestSha256 -ceq $case.manifest_sha256)
        Check ($case.name + ' exact physical object count') ($plan.ObjectCount -eq $case.object_count)
        Check ($case.name + ' expanded byte accounting') ($plan.ExpandedBytes -eq $case.expanded_bytes)
        Check ($case.name + ' materialized byte accounting') ($plan.MaterializedBytes -eq $case.materialized_bytes)
        Check ($case.name + ' link count') ($plan.SymlinkCount -eq @($case.links.PSObject.Properties).Count)
        $destination=Empty-Root $case.name
        $null=Expand-DsrWindowsSourceSnapshot -Plan $plan -DestinationPath $destination
        $items=@(Get-ChildItem -LiteralPath $destination -Force -Recurse)
        Check ($case.name + ' materializes exact inventory') ($items.Count -eq $case.object_count)
        Check ($case.name + ' creates no reparse nodes') (@($items | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 }).Count -eq 0)
        foreach ($directory in $case.directories) {
            Check ($case.name + ' directory ' + $directory) (Test-Path -LiteralPath (Join-Path $destination $directory) -PathType Container)
        }
        foreach ($property in $case.files.PSObject.Properties) {
            $path=Join-Path $destination $property.Name
            Check ($case.name + ' bytes ' + $property.Name) ((Test-Path -LiteralPath $path -PathType Leaf) -and (Hash $path) -ceq $property.Value.sha256)
            if ($null -ne $property.Value.PSObject.Properties['referent']) {
                $row=$plan.Rows[$property.Name]
                Check ($case.name + ' referent identity ' + $property.Name) `
                    ($row.ReferentPath -ceq $property.Value.referent -and $row.ReferentOid -ceq $property.Value.oid)
            }
        }
        $null=Test-DsrWindowsSourceSnapshot -Plan (Plan $case) -DestinationPath $destination
        Check ($case.name + ' fresh final verification') $true
    } catch {
        Check ($case.name + ' completes materialization') $false
        [Console]::Error.WriteLine($_.Exception.ToString())
    }
}
$safe=@($cases | Where-Object name -eq safe)[0]
foreach ($mutation in @('archive','manifest')) {
    $copy=$safe.PSObject.Copy()
    $copy.archive=Join-Path $FixtureRoot ('changed-' + $mutation + '.tar')
    $copy.manifest=Join-Path $FixtureRoot ('changed-' + $mutation + '.manifest')
    [IO.File]::Copy($safe.archive,$copy.archive)
    [IO.File]::Copy($safe.manifest,$copy.manifest)
    $plan=Plan $copy
    if ($mutation -eq 'archive') {
        $bytes=[IO.File]::ReadAllBytes($copy.archive); $bytes[0]=$bytes[0] -bxor 1
        [IO.File]::WriteAllBytes($copy.archive,$bytes)
    } else { [IO.File]::AppendAllText($copy.manifest,' ') }
    $destination=Empty-Root ('after-plan-' + $mutation)
    Refused ($mutation + ' change after planning is refused') { Expand-DsrWindowsSourceSnapshot -Plan $plan -DestinationPath $destination }
    Check ($mutation + ' change creates no payload') (@(Get-ChildItem -LiteralPath $destination -Force).Count -eq 0)
}
foreach ($mutation in @('link-copy','referent','extra-file')) {
    $plan=Plan $safe
    $destination=Empty-Root ('after-copy-' + $mutation)
    $null=Expand-DsrWindowsSourceSnapshot -Plan $plan -DestinationPath $destination
    $path=switch ($mutation) {
        'link-copy' { 'file-link' }
        'referent' { 'source/input.txt' }
        'extra-file' { 'unexpected.txt' }
    }
    [IO.File]::WriteAllText((Join-Path $destination $path),'changed after admission')
    Refused ($mutation + ' alteration fails fresh final verification') { Test-DsrWindowsSourceSnapshot -Plan (Plan $safe) -DestinationPath $destination }
}
$submodules=@($cases | Where-Object name -eq project-submodules)[0]
foreach ($mutation in @('child-file','nested-file','child-link-copy','extra-child-file')) {
    $destination=Empty-Root ('submodule-after-copy-' + $mutation)
    $null=Expand-DsrWindowsSourceSnapshot -Plan (Plan $submodules) -DestinationPath $destination
    $path=switch ($mutation) {
        'child-file' { 'vendor/dep/data.txt' }
        'nested-file' { 'vendor/dep/inner/leaf.txt' }
        'child-link-copy' { 'vendor/dep/copy.txt' }
        'extra-child-file' { 'vendor/dep/empty/untracked.txt' }
    }
    [IO.File]::WriteAllText((Join-Path $destination $path),'changed child after admission')
    Refused ($mutation + ' fails fresh project-submodule verification') {
        Test-DsrWindowsSourceSnapshot -Plan (Plan $submodules) -DestinationPath $destination
    }
}
$destination=Empty-Root 'nonempty'
$sentinel=Join-Path $destination 'sentinel.txt'
[IO.File]::WriteAllText($sentinel,'preserve prior bytes')
Refused 'nonempty destination is refused' { Expand-DsrWindowsSourceSnapshot -Plan (Plan $safe) -DestinationPath $destination }
Check 'nonempty destination remains unchanged' ([IO.File]::ReadAllText($sentinel) -ceq 'preserve prior bytes' -and @(Get-ChildItem -LiteralPath $destination -Force).Count -eq 1)
$expansion=@($cases | Where-Object name -eq expansion)[0]
Check 'materialization exceeds the previous two-archive-size assumption' ((Plan $expansion).ExpandedBytes -gt (2 * (Get-Item -LiteralPath $expansion.archive).Length))
foreach ($control in (Get-Content -LiteralPath (Join-Path $FixtureRoot 'transport-checks.json') -Raw | ConvertFrom-Json)) {
    Check $control.label $control.passed
}
$budget=Get-Content -LiteralPath (Join-Path $FixtureRoot 'budget.json') -Raw | ConvertFrom-Json
$volume=Join-Path $FixtureRoot 'budget-volume'
$owned=Join-Path $volume 'owned'
$null=[IO.Directory]::CreateDirectory($owned)
[IO.File]::Copy($expansion.archive,(Join-Path $owned 'source.tar'))
[IO.File]::Copy($expansion.manifest,(Join-Path $owned 'source.manifest'))
$null=New-PSDrive -Name $budget.drive -PSProvider FileSystem -Root $volume
$dsrSourcePlan=Plan $expansion
$overhead=([long]$expansion.object_count * 4096) + 16777216
$env:DSR_SOURCE_FIXTURE_FREE=[string]([long]$budget.reserve + (2 * (Get-Item -LiteralPath $expansion.archive).Length) + $overhead)
function Get-CimInstance {
    param([string]$ClassName,[string]$Filter)
    if ($ClassName -cne 'Win32_LogicalDisk' -or $Filter -cne ("DeviceID='" + $budget.drive + ":'")) { throw 'Unexpected storage observation' }
    return [pscustomobject]@{FreeSpace=[long]$env:DSR_SOURCE_FIXTURE_FREE}
}
try {
    & (Join-Path $FixtureRoot 'budget-archive.ps1')
    Check 'actual archive-budget phase admits the smaller transfer allocation' $true
} catch { Check 'actual archive-budget phase admits the smaller transfer allocation' $false; [Console]::Error.WriteLine($_) }
Refused 'actual expansion budget refuses link copies beyond the same free-space allowance' { & (Join-Path $FixtureRoot 'budget-expansion.ps1') } 'Source archives and sibling allocation exceed split-storage admission'
$env:DSR_SOURCE_FIXTURE_FREE=[string]([long]$budget.reserve + $dsrSourcePlan.ExpandedBytes + $overhead)
try {
    & (Join-Path $FixtureRoot 'budget-expansion.ps1')
    Check 'actual expansion budget admits sufficient materialized-byte headroom' $true
} catch { Check 'actual expansion budget admits sufficient materialized-byte headroom' $false; [Console]::Error.WriteLine($_) }
foreach ($case in @($cases | Where-Object { $_.name -in @('safe','pax-long-path-and-link','regular-only','empty-gitlink','changed-link-target','project-submodules','parent-to-child','child-to-parent') })) {
    $extract=Join-Path $FixtureRoot ($case.name + '-extract.ps1')
    $verify=Join-Path $FixtureRoot ($case.name + '-verify.ps1')
    $destination=Join-Path $FixtureRoot ('emitted-' + $case.name)
    if (-not $case.accepted) {
        Refused ($case.name + ' emitted receiver refuses inadmissible authenticated link') { & $extract }
        Check ($case.name + ' emitted receiver refusal creates no payload') (@(Get-ChildItem -LiteralPath $destination -Force).Count -eq 0)
        continue
    }
    try {
        $result=@(& $extract)
        Check ($case.name + ' emitted extraction digest') ($result.Count -eq 1 -and $result[0] -ceq $case.archive_sha256)
        $result=@(& $verify)
        Check ($case.name + ' emitted final verification digests') `
            ($result.Count -eq 1 -and $result[0] -ceq ($case.archive_sha256 + ' ' + $case.manifest_sha256))
        if ($case.name -eq 'safe') {
            [IO.File]::WriteAllText((Join-Path $destination 'file-link'),'altered copied link')
            Refused 'emitted final verifier refuses changed materialized source' { & $verify }
        } elseif ($case.name -eq 'project-submodules') {
            [IO.File]::WriteAllText((Join-Path $destination 'vendor/dep/inner/leaf.txt'),'altered pinned nested source')
            Refused 'emitted final verifier refuses changed project-submodule source' { & $verify }
        }
    } catch {
        Check ($case.name + ' emitted receiver completes') $false
        [Console]::Error.WriteLine($_.Exception.ToString())
    }
}
Write-Output ('Windows source links: ' + ($checks - $failures) + ' passed, ' + $failures + ' failed')
if ($failures -ne 0) { exit 1 }
POWERSHELL
    POWERSHELL_TELEMETRY_OPTOUT=1 DOTNET_CLI_TELEMETRY_OPTOUT=1 POWERSHELL_UPDATECHECK=Off \
        pwsh -NoLogo -NoProfile -NonInteractive -File "$work/check.ps1" \
        -FixtureRoot "$work" -BackendPath "$backend"
)

test_source_ownership() (
    local dependency work
    for dependency in bash git jq python3 rsync tar; do
        command -v "$dependency" >/dev/null 2>&1 || {
            printf 'SKIP: source ownership requires %s\n' "$dependency"
            return 77
        }
    done
    work=$(mktemp -d "${TMPDIR:-/tmp}/dsr-source-ownership.XXXXXXXX") || return 1
    printf 'Source ownership evidence: %s\n' "$work"
    python3 - "$work" "${DSR_TEST_ACT_RUNNER:-$ROOT/src/act_runner.sh}" "$ROOT" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import shlex
import stat
import subprocess
import sys

work = Path(sys.argv[1])
runner = Path(sys.argv[2])
root = Path(sys.argv[3])
os.umask(0o022)
work.chmod(0o755)
environment = {key: value for key, value in os.environ.items()
               if not key.upper().startswith(('GIT_', 'SUDO_'))}
environment.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=str(work / 'global.gitconfig'),
                   GIT_AUTHOR_NAME='Source ownership fixture', GIT_AUTHOR_EMAIL='fixture@example.invalid',
                   GIT_COMMITTER_NAME='Source ownership fixture', GIT_COMMITTER_EMAIL='fixture@example.invalid',
                   DSR_CONFIG_DIR=str(work / 'config'), DSR_STATE_DIR=str(work / 'state'),
                   DSR_CACHE_DIR=str(work / 'cache'), DSR_HOSTS_FILE=str(work / 'no-hosts.yaml'),
                   NO_COLOR='1')
(work / 'global.gitconfig').write_text('[user]\n\tname = Ownership fixture\n')
transport = work / 'transport'
transport.mkdir()
ssh = transport / 'ssh'
# Only the network is replaced: this executes the actual rsync server/tar,
# Git importer and build commands with the selected receiver's real UID.
ssh.write_text('''#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
while args and args[0].startswith('-'):
    args = args[2:] if args[0] in ('-o', '-p', '-l') else args[1:]
host, args = args[0], args[1:]
if host not in ('fixture-owned-rsync', 'fixture-owned-tar'):
    raise SystemExit(255)
uid, gid = int(os.environ['DSR_TEST_RECEIVER_UID']), int(os.environ['DSR_TEST_RECEIVER_GID'])
if uid != os.geteuid() or gid != os.getegid():
    os.setgroups([])
    os.setgid(gid)
    os.setuid(uid)
command = ' '.join(args)
if host == 'fixture-owned-tar' and command == 'command -v rsync >/dev/null 2>&1':
    raise SystemExit(1)
os.execv('/bin/sh', ['sh', '-c', command])
''')
ssh.chmod(0o755)
environment['PATH'] = str(transport) + os.pathsep + environment['PATH']
passes = failures = 0

def check(label, condition):
    global passes, failures
    print(('PASS: ' if condition else 'FAIL: ') + label, flush=True)
    if condition:
        passes += 1
    else:
        failures += 1

def run(argv, *, env=None, uid=None, gid=None, cwd=None):
    def receive_as():
        if uid is not None and (uid != os.geteuid() or gid != os.getegid()):
            os.setgroups([])
            os.setgid(gid)
            os.setuid(uid)
    return subprocess.run(argv, env=env or environment, cwd=cwd,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          text=True, preexec_fn=receive_as if uid is not None else None)

def module(body, *arguments, env=None):
    return run(['bash', '-c', 'source "$1" || exit; source "$2" || exit; shift 2; ' + body,
                'source-ownership', str(runner), str(root / 'src/git_ops.sh'), *map(str, arguments)], env=env)

source = work / 'controller-source'
source.mkdir()
(source / 'payload.txt').write_text('source bytes\n')
(source / 'build.sh').write_text('#!/bin/sh\nset -eu\ngit config --local dsr.fixture verified\n'
                                 'git rev-parse --verify HEAD\ncat payload.txt\n')
(source / 'build.sh').chmod(0o755)
(source / 'payload-link').symlink_to('payload.txt')
for args in [('init', '-q', '--initial-branch=main'), ('add', '.'), ('commit', '-qm', 'ownership fixture')]:
    result = run(['git', '-C', str(source), *args])
    if result.returncode:
        raise RuntimeError(result.stderr)
context_result = module('git_ops_export_build_context "$1" "$2"', source, work / 'context')
if context_result.returncode:
    raise RuntimeError(context_result.stderr)
context = json.loads(context_result.stdout)
context_path = work / 'context.json'
context_path.write_text(json.dumps(context))

current_uid, current_gid = os.geteuid(), os.getegid()
foreign_ids = False
if current_uid == 0:
    probe = work / 'uid-probe'
    probe.write_text('UID capability probe\n')
    try:
        os.chown(probe, 501, 501)
        switched = run(['id', '-u'], uid=502, gid=502)
        foreign_ids = switched.returncode == 0 and switched.stdout.strip() == '502'
    except (OSError, subprocess.SubprocessError) as error:
        print('SKIP: UID 501 and non-root receiver controls require chown/setuid capability: ' + str(error))
else:
    print('SKIP: root receiver and foreign ownership controls require running this mode as root')
if os.environ.get('DSR_TEST_REQUIRE_FOREIGN_IDS') == '1' and not foreign_ids:
    raise RuntimeError('Required UID 501/root/non-root ownership qualification is unavailable')

if foreign_ids:
    # Model the real macOS source account. The sender reads the ordinary
    # working bytes; the exported authenticated Git bundle remains separate.
    for path in [*source.rglob('*'), source]:
        os.chown(path, 501, 501, follow_symlinks=False)

def fingerprint(root):
    result = {}
    for path in [root, *sorted(root.rglob('*'))]:
        info = path.lstat()
        payload = os.readlink(path) if path.is_symlink() else (
            hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else '')
        result[str(path.relative_to(root))] = (info.st_uid, info.st_gid, stat.S_IMODE(info.st_mode), payload)
    return result

source_before = fingerprint(source)
global_before = (work / 'global.gitconfig').read_bytes()
receivers = [('root' if current_uid == 0 else 'worker', current_uid, current_gid)]
if foreign_ids:
    receivers.append(('nonroot', 502, 502))
for label, uid, gid in receivers:
    for host in ('fixture-owned-rsync', 'fixture-owned-tar'):
        name = label + '-' + host.rsplit('-', 1)[1]
        parent = work / name
        parent.mkdir()
        if uid != current_uid:
            os.chown(parent, uid, gid)
        destination = parent / 'source'
        selected = dict(environment, DSR_TEST_RECEIVER_UID=str(uid), DSR_TEST_RECEIVER_GID=str(gid))
        result = module('_act_sync_source "$1" "$2" "$3"', host, source, destination, env=selected)
        (work / (name + '.sync.log')).write_text(result.stdout + result.stderr)
        check(name + ' source transfer succeeds', result.returncode == 0)
        if result.returncode:
            continue
        check(name + ' source root belongs to receiving account', destination.stat().st_uid == uid)
        check(name + ' source root uses receiving group', destination.stat().st_gid == gid)
        check(name + ' regular inputs belong to receiving account',
              all((destination / p).stat().st_uid == uid for p in ('build.sh', 'payload.txt')))
        check(name + ' regular inputs use receiving group',
              all((destination / p).stat().st_gid == gid for p in ('build.sh', 'payload.txt')))
        check(name + ' executable permission is preserved', stat.S_IMODE((destination / 'build.sh').stat().st_mode) == 0o755)
        check(name + ' ordinary permission is preserved', stat.S_IMODE((destination / 'payload.txt').stat().st_mode) == 0o644)
        check(name + ' source bytes match', (destination / 'payload.txt').read_bytes() == (source / 'payload.txt').read_bytes())
        check(name + ' symlink remains a link with the original target',
              (destination / 'payload-link').is_symlink() and os.readlink(destination / 'payload-link') == 'payload.txt')
        check(name + ' symlink belongs to receiving account and group',
              ((destination / 'payload-link').lstat().st_uid, (destination / 'payload-link').lstat().st_gid) == (uid, gid))
        check(name + ' controller Git metadata is excluded', not (destination / '.git').exists())
        restored = module('context=$(cat "$4") || exit; _act_restore_ordinary_git_context "$1" "$2" "$context" "$3"',
                          host, destination, 'source', context_path, env=selected)
        (work / (name + '.restore.log')).write_text(restored.stdout + restored.stderr)
        check(name + ' authenticated Git context restores', restored.returncode == 0)
        built = run([str(destination / 'build.sh')], cwd=destination, env=selected, uid=uid, gid=gid)
        (work / (name + '.build.log')).write_text(built.stdout + built.stderr)
        check(name + ' build can use git config --local and exact source HEAD',
              built.returncode == 0 and built.stdout == context['git_sha'] + '\nsource bytes\n')
        safe = run(['git', '-C', str(destination), 'config', '--local', '--get-all', 'safe.directory'],
                   env=selected, uid=uid, gid=gid)
        check(name + ' no safe.directory exception is installed', safe.returncode == 1)

        # A retry must not follow an operator-selected destination link into
        # another project. Neither the link nor the foreign tree is modified.
        other = parent / 'unrelated'
        other.mkdir()
        (other / 'sentinel').write_text('unrelated project\n')
        alias = parent / 'alias'
        alias.symlink_to(other, target_is_directory=True)
        rejected = module('_act_sync_source "$1" "$2" "$3"', host, source, alias, env=selected)
        check(name + ' destination symlink refuses before transfer',
              rejected.returncode != 0 and 'Refusing source sync through symlink' in rejected.stderr)
        check(name + ' refused transfer preserves unrelated project',
              (other / 'sentinel').is_file() and (other / 'sentinel').read_text() == 'unrelated project\n'
              and not (other / 'payload.txt').exists())

        if foreign_ids:
            for entry_name in ('source-root', 'git-dir'):
                polluted = parent / ('polluted-' + entry_name)
                polluted.mkdir()
                (polluted / 'sentinel').write_text('must not change\n')
                os.chown(polluted, uid, gid)
                initialized = run(['git', '-C', str(polluted), 'init', '-q', '--initial-branch=main'],
                                  env=selected, uid=uid, gid=gid)
                configured = run(['git', '-C', str(polluted), 'config', '--local', 'dsr.fixture', 'owned'],
                                 env=selected, uid=uid, gid=gid)
                check(name + ' ' + entry_name + ' fixture is initially a usable owned repository',
                      initialized.returncode == 0 and configured.returncode == 0)
                foreign = polluted if entry_name == 'source-root' else polluted / '.git'
                os.chown(foreign, 501, 501)
                unsafe = run(['git', '-C', str(polluted), 'rev-parse', '--is-inside-work-tree'],
                             env=selected, uid=uid, gid=gid)
                check(name + ' Git itself rejects foreign-owned ' + entry_name,
                      unsafe.returncode != 0 and 'dubious ownership' in unsafe.stderr.lower())
                before = fingerprint(polluted)
                rejected = module('_act_sync_source "$1" "$2" "$3"', host, source, polluted, env=selected)
                check(name + ' refuses foreign-owned ' + entry_name + ' with UID/path diagnosis',
                      rejected.returncode != 0 and 'Source ownership mismatch' in rejected.stderr
                      and str(foreign) in rejected.stderr and 'UID 501' in rejected.stderr
                      and ('UID ' + str(uid)) in rejected.stderr)
                check(name + ' preserves foreign-owned ' + entry_name + ' without repair', fingerprint(polluted) == before)

check('all transfers preserve controller source ownership, modes and bytes', fingerprint(source) == source_before)
check('all transfers preserve global Git configuration', (work / 'global.gitconfig').read_bytes() == global_before)
print('Source ownership: %d passed, %d failed' % (passes, failures))
raise SystemExit(1 if failures else 0)
PY
)

test_git_source_selection() (
    local dependency work source_root destination mode output status
    local selection_passes=0 selection_failures=0
    for dependency in bash git rsync tar; do
        command -v "$dependency" >/dev/null 2>&1 || {
            printf 'SKIP: Git source selection requires %s\n' "$dependency"
            return 77
        }
    done
    work=$(mktemp -d "${TMPDIR:-/tmp}/dsr-git-source-selection.XXXXXXXX") || return 1
    printf 'Git source-selection evidence: %s\n' "$work"
    source_root="$work/source"
    mkdir -p "$source_root" "$work/transports" || return 1
    export DSR_CONFIG_DIR="$work/config" DSR_HOSTS_FILE="$work/no-hosts.yaml"
    export DSR_STATE_DIR="$work/state" DSR_CACHE_DIR="$work/cache" NO_COLOR=1
    # Only transport is local: the remote branch still runs the real rsync
    # server, and the no-rsync receiver still runs the real tar extractor.
    cat > "$work/transports/ssh" <<'SSH'
#!/usr/bin/env bash
set -uo pipefail
while (($#)); do
    case "$1" in -o|-p|-l) shift 2 ;; -n|-q|-T|-t) shift ;; *) break ;; esac
done
host="${1:-}"; shift
case "$host" in fixture-source-rsync|fixture-source-tar) ;; *) exit 255 ;; esac
if [[ "$host" == fixture-source-tar && "$*" == 'command -v rsync >/dev/null 2>&1' ]]; then
    exit 1
fi
exec bash -c "$*"
SSH
    chmod 755 "$work/transports/ssh" || return 1
    export PATH="$work/transports:$PATH"
    # Selecting the unchanged incumbent permits an honest before/after replay
    # of exactly these assertions, without replacing a production predicate.
    # shellcheck source=src/act_runner.sh
    source "${DSR_TEST_ACT_RUNNER:-$ROOT/src/act_runner.sh}" || return 1
    git -c init.defaultBranch=main init -q "$source_root" || return 1
    mkdir -p "$source_root/internal/webui/dist" "$source_root/dist" \
        "$source_root/ignored" "$source_root/nested" "$source_root/src" || return 1
    cat > "$source_root/.gitignore" <<'IGNORE'
dist/
!internal/webui/dist/
ignored/
*.cache
literal\*.bin
literal\?.bin
literal\[x\].bin
slash\\name.bin
slash\\literal\*.bin
IGNORE
    printf 'drop.txt\n' > "$source_root/nested/.gitignore"
    printf 'embedded web assets\n' > "$source_root/internal/webui/dist/index.html"
    printf 'tracked despite ignored parent\n' > "$source_root/ignored/tracked-input.txt"
    printf 'source bytes\n' > "$source_root/src/main.go"
    printf 'explicitly excluded\n' > "$source_root/omit-me.txt"
    git -C "$source_root" add -f -- .gitignore nested/.gitignore \
        internal/webui/dist/index.html ignored/tracked-input.txt src/main.go omit-me.txt || return 1
    printf 'untracked build input\n' > "$source_root/new-input.txt"
    printf 'nested selected input\n' > "$source_root/nested/keep.txt"
    printf 'nested ignored input\n' > "$source_root/nested/drop.txt"
    printf 'ignored output\n' > "$source_root/dist/output.txt"
    printf 'ignored sibling\n' > "$source_root/ignored/drop.txt"
    printf 'local-only.txt\n' > "$source_root/.git/info/exclude"
    printf 'machine-only.txt\n' > "$work/global-ignore"
    git -C "$source_root" config core.excludesFile "$work/global-ignore" || return 1
    printf 'local ignored\n' > "$source_root/local-only.txt"
    printf 'global ignored\n' > "$source_root/machine-only.txt"
    printf 'secret\n' > "$source_root/.env"
    local name
    for name in 'literal*.bin' 'literal?.bin' 'literal[x].bin' $'line\nbreak.cache' \
        'slash\name.bin' 'slash\literal*.bin' 'slashname.bin' 'slash\literalZ.bin' \
        'literalZ.bin' 'literalx.bin' 'file with spaces.txt'; do
        printf 'literal filename\n' > "$source_root/$name"
    done

    selection_check() {
        local description="$1"; shift
        if "$@"; then
            printf 'PASS: %s\n' "$description"
            selection_passes=$((selection_passes + 1))
        else
            printf 'FAIL: %s\n' "$description" >&2
            selection_failures=$((selection_failures + 1))
        fi
    }

    for mode in act fixture-source-rsync fixture-source-tar; do
        destination="$work/$mode"
        mkdir -p "$destination/src" || return 1
        printf 'wrong! bytes\n' > "$destination/src/main.go"
        touch -r "$source_root/src/main.go" "$destination/src/main.go" || return 1
        printf 'stale receiver input\n' > "$destination/stale-input.txt"
        status=0
        output=$(_act_sync_source "$mode" "$source_root" "$destination" omit-me.txt 2>&1) || status=$?
        printf '%s\n' "$output" > "$work/$mode.log"
        selection_check "$mode completes source transfer" test "$status" -eq 0
        selection_check "$mode retains tracked gitignore-negated embedded content" \
            cmp -s "$source_root/internal/webui/dist/index.html" "$destination/internal/webui/dist/index.html"
        selection_check "$mode retains tracked files under an ignored parent" \
            cmp -s "$source_root/ignored/tracked-input.txt" "$destination/ignored/tracked-input.txt"
        for name in new-input.txt nested/keep.txt 'literalZ.bin' 'literalx.bin' \
            'slashname.bin' 'slash\literalZ.bin' 'file with spaces.txt'; do
            selection_check "$mode retains selected $name" cmp -s "$source_root/$name" "$destination/$name"
        done
        for name in dist/output.txt ignored/drop.txt nested/drop.txt local-only.txt machine-only.txt \
            'literal*.bin' 'literal?.bin' 'literal[x].bin' 'slash\name.bin' 'slash\literal*.bin' \
            $'line\nbreak.cache' .env .git omit-me.txt; do
            selection_check "$mode excludes $name" test ! -e "$destination/$name"
        done
        selection_check "$mode replaces same-size/same-time stale source bytes" \
            cmp -s "$source_root/src/main.go" "$destination/src/main.go"
        if [[ "$mode" != fixture-source-tar ]]; then
            # Tar's existing fallback does not prune; retain rsync's deletion
            # behavior instead of hiding a regression behind fresh stages.
            selection_check "$mode deletes stale receiver-only input" test ! -e "$destination/stale-input.txt"
        fi
    done

    destination="$work/ignore-opt-out"
    status=0
    _act_sync_source act "$source_root" "$destination" --no-gitignore-excludes > "$work/opt-out.log" 2>&1 || status=$?
    selection_check 'explicit ignore opt-out succeeds' test "$status" -eq 0
    for name in dist/output.txt ignored/drop.txt nested/drop.txt local-only.txt machine-only.txt; do
        selection_check "ignore opt-out retains $name" cmp -s "$source_root/$name" "$destination/$name"
    done
    selection_check 'ignore opt-out still excludes secrets' test ! -e "$destination/.env"
    selection_check 'ignore opt-out still excludes Git administration' test ! -e "$destination/.git"

    destination="$work/nested-source"
    status=0
    _act_sync_source act "$source_root/nested" "$destination" > "$work/nested.log" 2>&1 || status=$?
    selection_check 'source subdirectory selection succeeds' test "$status" -eq 0
    selection_check 'source subdirectory retains relative selected paths' \
        cmp -s "$source_root/nested/keep.txt" "$destination/keep.txt"
    selection_check 'source subdirectory honors its nested ignore file' test ! -e "$destination/drop.txt"

    destination="$work/refused-index"
    mkdir -p "$destination" || return 1
    printf 'preserved receiver bytes\n' > "$destination/sentinel"
    printf 'not a Git index\n' > "$work/bad-index"
    status=0
    GIT_INDEX_FILE="$work/bad-index" _act_sync_source act "$source_root" "$destination" \
        > "$work/bad-index.log" 2>&1 || status=$?
    selection_check 'unreadable Git inventory refuses transfer' test "$status" -ne 0
    selection_check 'inventory refusal preserves prior receiver bytes' \
        grep -qx 'preserved receiver bytes' "$destination/sentinel"
    selection_check 'inventory refusal creates no source payload' test ! -e "$destination/src"
    printf 'Git source selection: %s passed, %s failed\n' "$selection_passes" "$selection_failures"
    [[ "$selection_failures" -eq 0 ]]
)

if [[ "${1:-}" == --strict-go-paths-only ]]; then
    test_strict_go_source_paths
    exit $?
fi
if [[ "${1:-}" == --strict-go-paths-external-only ]]; then
    test_strict_go_source_paths external
    exit $?
fi
if [[ "${1:-}" == --strict-go-paths-pinned-only ]]; then
    test_strict_go_source_paths pinned
    exit $?
fi
if [[ "${1:-}" == --strict-go-context-only ]]; then
    test_strict_go_context
    exit $?
fi
if [[ "${1:-}" == --ordinary-inputs-only ]]; then
    test_ordinary_source_inputs
    exit $?
fi
if [[ "${1:-}" == --ordinary-resume-only ]]; then
    test_ordinary_source_resume
    exit $?
fi
if [[ "${1:-}" == --go-siblings-only ]]; then
    go_sibling_status=0
    test_ordinary_go_siblings replace || go_sibling_status=$?
    test_ordinary_go_siblings workspace || go_sibling_status=$?
    exit "$go_sibling_status"
fi
if [[ "${1:-}" == --strict-go-siblings-only ]]; then
    strict_go_status=0
    test_strict_go_siblings replace || strict_go_status=$?
    test_strict_go_siblings workspace || strict_go_status=$?
    exit "$strict_go_status"
fi
if [[ "${1:-}" == --windows-strict-go-only ]]; then
    test_windows_strict_native go
    exit $?
fi
if [[ "${1:-}" == --windows-strict-bun-only ]]; then
    test_windows_strict_native bun
    exit $?
fi
if [[ "${1:-}" == --strict-go-admission-only ]]; then
    strict_go_admission_status=0
    test_strict_go_sibling_admission replace &
    strict_go_replace_pid=$!
    test_strict_go_sibling_admission workspace &
    strict_go_workspace_pid=$!
    wait "$strict_go_replace_pid" || strict_go_admission_status=$?
    wait "$strict_go_workspace_pid" || strict_go_admission_status=$?
    exit "$strict_go_admission_status"
fi
if [[ "${1:-}" == --strict-go-matrix-only ]]; then
    test_strict_go_sibling_admission matrix
    exit $?
fi
if [[ "${1:-}" == --windows-source-links-only ]]; then
    test_windows_source_links
    exit $?
fi
if [[ "${1:-}" == --git-selection-only ]]; then
    test_git_source_selection
    exit $?
fi
if [[ "${1:-}" == --ownership-only ]]; then
    test_source_ownership
    exit $?
fi
if [[ $# -eq 0 ]]; then
    ordinary_input_status=0
    test_ordinary_source_inputs || ordinary_input_status=$?
    [[ "$ordinary_input_status" == 0 || "$ordinary_input_status" == 77 ]] || exit "$ordinary_input_status"
    windows_links_status=0
    test_windows_source_links || windows_links_status=$?
    [[ "$windows_links_status" == 0 || "$windows_links_status" == 77 ]] || exit "$windows_links_status"
    git_selection_status=0
    test_git_source_selection || git_selection_status=$?
    [[ "$git_selection_status" == 0 || "$git_selection_status" == 77 ]] || exit "$git_selection_status"
    ownership_status=0
    test_source_ownership || ownership_status=$?
    [[ "$ownership_status" == 0 || "$ownership_status" == 77 ]] || exit "$ownership_status"
fi

for dependency in bash rustc cargo git jq yq rsync python3 tar; do
    command -v "$dependency" >/dev/null 2>&1 || {
        printf 'SKIP: source-sync integration requires %s\n' "$dependency"
        exit 0
    }
done
[[ $(uname -s)/$(uname -m) == Linux/x86_64 ]] || {
    printf 'SKIP: source-sync fixture requires Linux x86_64\n'; exit 0;
}
GNU=x86_64-unknown-linux-gnu
MUSL=x86_64-unknown-linux-musl
ARM=aarch64-unknown-linux-gnu
stdlib=$(rustc --print target-libdir --target "$MUSL") || exit 1
compgen -G "$stdlib/libstd-*.rlib" >/dev/null || {
    printf 'SKIP: real musl standard library needed for recovered matrix\n'; exit 0;
}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/dsr-native-source-sync.XXXXXXXX") || exit 1
printf 'Evidence: %s\n' "$WORK"
mkdir -p "$WORK/config/repos.d" "$WORK/source/src" "$WORK/transports" \
    "$WORK/state" "$WORK/cargo-home" "$WORK/stages" "$WORK/hosts" || exit 1
export PATH="$WORK/transports:$PATH"
export DSR_CONFIG_DIR="$WORK/config" DSR_STATE_DIR="$WORK/state" DSR_CACHE_DIR="$WORK/cache"
export DSR_HOSTS_FILE="$WORK/config/hosts.yaml" DSR_REPOS_FILE="$WORK/config/repos.yaml"
export ACT_CONFIG_DIR="$WORK/config" ACT_REPOS_DIR="$WORK/config/repos.d"
export CARGO_HOME="$WORK/cargo-home" CARGO_NET_OFFLINE=true
export DSR_DISABLE_HOST_SELECTOR=1 RCH_DISABLED=1 RCH_CARGO_WRAPPER_BYPASS=1 NO_COLOR=1
export SYNC_TEST_WORK="$WORK"

# A named local transport executes exactly the production SSH commands and
# genuine rsync server. Refuse every other destination instead of networking.
cat > "$WORK/transports/ssh" <<'SSH'
#!/usr/bin/env bash
set -uo pipefail
while (($#)); do
    case "$1" in -o|-p|-l) shift 2 ;; -n|-q|-T|-t) shift ;; *) break ;; esac
done
host="$1"; shift
case "$host" in fixture-healthy|fixture-bad|fixture-repair|fixture-unsynced) ;; *) exit 255 ;; esac
printf '%s %s\n' "$host" "$*" >> "$SYNC_TEST_WORK/ssh.log"
receiver=false
[[ "$*" != rsync\ --server* ]] || receiver=true
if $receiver; then
    case "$host" in
        fixture-bad) marker="$SYNC_TEST_WORK/drop-bad" ;;
        fixture-repair) marker="$SYNC_TEST_WORK/drop-repair" ;;
        *) marker="$SYNC_TEST_WORK/never-drop" ;;
    esac
    if [[ -e "$marker" ]]; then
        printf 'intentional rsync receiver connection loss on %s\n' "$host" >&2
        exit 12
    fi
fi
if (($# == 1)) && [[ "$1" == bash\ -c\ * ]]; then
    # SSH passes its command through the account's login shell before the
    # explicit Bash interpreter. Exercise that outer boundary with POSIX sh.
    printf '%s\n' "$host" >> "$SYNC_TEST_WORK/posix-git-imports"
    /bin/sh -c "$1"; status=$?
elif (($# == 1)); then /bin/bash -c "$1"; status=$?
else "$@"; status=$?; fi
if [[ $status -eq 0 && -e "$SYNC_TEST_WORK/corrupt-git-bundle" &&
      "$*" == *"cat > '"*"/.dsr-context-source.bundle'" ]]; then
    # Corrupt only the actual newly received context bundle. The real Git
    # importer must detect this transfer damage before any Cargo invocation.
    command_text="$*"
    bundle="${command_text##*cat > }"
    bundle="${bundle#\'}"; bundle="${bundle%\'}"
    [[ "$bundle" == "$SYNC_TEST_WORK/stages/"* && -f "$bundle" ]] || exit 255
    printf '\nintentional transport corruption\n' >> "$bundle"
    printf '%s\n' "$bundle" >> "$SYNC_TEST_WORK/corrupted-bundles"
fi
if $receiver && [[ $status -eq 0 && "$host" == fixture-repair && -e "$SYNC_TEST_WORK/change-mapping-after-sync" ]]; then
    # The source receipt names fixture-repair. Change only the fixture's
    # subsequent selection policy after that real transfer has completed.
    yq -i '.platform_mapping."linux/amd64" = "unsyncedbox"' "$DSR_HOSTS_FILE" || exit 4
    printf 'changed-after-repair-sync\n' >> "$SYNC_TEST_WORK/mapping-events"
fi
exit "$status"
SSH
cat > "$WORK/transports/scp" <<'SCP'
#!/usr/bin/env bash
set -uo pipefail
while (($#)); do case "$1" in -o|-P) shift 2 ;; -q) shift ;; *) break ;; esac; done
source_path="$1" destination="$2"
case "$source_path" in
    fixture-healthy:*|fixture-bad:*|fixture-repair:*|fixture-unsynced:*) source_path="${source_path#*:}" ;;
    *) exit 255 ;;
esac
exec /bin/cp -- "$source_path" "$destination"
SCP
chmod +x "$WORK/transports/ssh" "$WORK/transports/scp" || exit 1

cat > "$WORK/source/Cargo.toml" <<'TOML'
[package]
name = "syncfixture"
version = "1.0.0"
edition = "2021"
TOML
cat > "$WORK/source/src/main.rs" <<'RUST'
fn main() { println!("OLD_SOURCE {}", if cfg!(target_env = "musl") { "musl" } else { "gnu" }); }
RUST
cat > "$WORK/source/build.rs" <<'RUST'
use std::{env, fs::{self, OpenOptions}, io::Write, path::Path};
fn main() {
    let target = env::var("TARGET").unwrap();
    if let Ok(selected) = env::var("DSR_TARGET_TRIPLE") {
        assert_eq!(selected, target, "the configured variant must reach real Cargo");
    }
    let mut file = OpenOptions::new().create(true).append(true)
        .open(env::var("SYNC_TEST_COMPILERS").unwrap()).unwrap();
    writeln!(file, "{target}").unwrap();
    if target.ends_with("-musl") && env::var("SYNC_TEST_FAIL_MUSL")
        .is_ok_and(|marker| Path::new(&marker).exists()) {
        panic!("deliberate genuine musl compilation failure for strict resume");
    }
    // Cargo's build-script directory depth is not a stable output contract.
    // Write the additional release artifact beside the selected executable.
    let target_dir = env::var("CARGO_TARGET_DIR").unwrap();
    let mut release = Path::new(&target_dir).to_path_buf();
    if env::var("CARGO_BUILD_TARGET").is_ok_and(|selected| !selected.is_empty()) {
        release.push(&target);
    }
    release.push(env::var("PROFILE").unwrap());
    fs::create_dir_all(&release).unwrap();
    fs::write(release.join("release-notes.txt"), "Reviewed strict variant release notes\n").unwrap();
}
RUST
printf 'Reviewed source fixture license\n' > "$WORK/source/LICENSE"
cargo generate-lockfile --offline --manifest-path "$WORK/source/Cargo.toml" || exit 1
git -C "$WORK/source" init -q -b main || exit 1
git -C "$WORK/source" add Cargo.toml Cargo.lock src/main.rs build.rs LICENSE || exit 1
git -C "$WORK/source" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm old || exit 1
for host in bad repair unsynced; do git clone -q "$WORK/source" "$WORK/hosts/$host" || exit 1; done
cat > "$WORK/source/src/main.rs" <<'RUST'
fn main() { println!("NEW_SOURCE {}", if cfg!(target_env = "musl") { "musl" } else { "gnu" }); }
RUST
git -C "$WORK/source" add src/main.rs || exit 1
git -C "$WORK/source" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm new || exit 1
git clone -q "$WORK/source" "$WORK/hosts/healthy" || exit 1
# Same-length source edits with unchanged timestamps defeat rsync's default
# quick check. A successful source receipt must still transfer the new bytes.
for host in bad repair unsynced; do
    touch -r "$WORK/source/src/main.rs" "$WORK/hosts/$host/src/main.rs" || exit 1
done
cat > "$DSR_HOSTS_FILE" <<YAML
schema_version: "1.0.0"
hosts:
  healthybox:
    platform: linux/amd64
    connection: ssh
    ssh_host: fixture-healthy
    concurrency: 2
    build_root: $WORK/stages
  badbox:
    platform: linux/amd64
    connection: ssh
    ssh_host: fixture-bad
    concurrency: 2
    build_root: $WORK/stages
  repairbox:
    platform: linux/amd64
    connection: ssh
    ssh_host: fixture-repair
    concurrency: 2
    build_root: $WORK/stages
  unsyncedbox:
    platform: linux/amd64
    connection: ssh
    ssh_host: fixture-unsynced
    concurrency: 2
    build_root: $WORK/stages
platform_mapping:
  linux/amd64: repairbox
  linux/arm64: badbox
YAML
jq -n --arg source "$WORK/source" --arg path "$PATH" --arg work "$WORK" '
    {tool_name:"syncmixed",repo:"example/syncmixed",local_path:$source,
     language:"rust",binary_name:"syncfixture",linux_glibc_floor:"native",
     build_cmd:"printf '\''%s\\n'\'' \"$CARGO_BUILD_TARGET\" >> \"$SYNC_TEST_COMMANDS\"; cargo build --release --locked --offline",
     targets:["linux/amd64","linux/arm64"],
     act_job_map:{"linux/amd64":null,"linux/arm64":null},
     target_triples:{"linux/amd64":"x86_64-unknown-linux-gnu","linux/arm64":"aarch64-unknown-linux-gnu"},
     hosts:{"linux/amd64":"healthybox","linux/arm64":"badbox"},
     host_paths:{healthybox:($work+"/hosts/healthy"),badbox:($work+"/hosts/bad"),
                 repairbox:($work+"/hosts/repair"),unsyncedbox:($work+"/hosts/unsynced")},
     artifact_naming:"${name}-${version}-${target_triple}.${ext}",archive_format:{linux:"tar.gz"},
     env:{PATH:$path,SYNC_TEST_COMMANDS:($work+"/build-commands"),SYNC_TEST_COMPILERS:($work+"/compiler-events")}}
' > "$ACT_REPOS_DIR/syncmixed.yaml" || exit 1
jq '.tool_name="syncrepair" | .repo="example/syncrepair" | .targets=["linux/amd64"] |
    .act_job_map={"linux/amd64":null} |
    .target_triples={"linux/amd64":["x86_64-unknown-linux-gnu","x86_64-unknown-linux-musl"]} |
    del(.hosts)' "$ACT_REPOS_DIR/syncmixed.yaml" > "$ACT_REPOS_DIR/syncrepair.yaml" || exit 1
: > "$WORK/drop-bad"
: > "$WORK/drop-repair"
: > "$WORK/build-commands"
: > "$WORK/compiler-events"

# shellcheck source=../../src/logging.sh
source "$ROOT/src/logging.sh"
# shellcheck source=../../src/config.sh
source "$ROOT/src/config.sh"
# shellcheck source=../../src/build_state.sh
source "$ROOT/src/build_state.sh"
# shellcheck source=../../src/act_runner.sh
source "$ROOT/src/act_runner.sh"
# shellcheck source=../../src/artifact_naming.sh
source "$ROOT/src/artifact_naming.sh"
# shellcheck source=../../src/host_selector.sh
source "$ROOT/src/host_selector.sh"
# Both ordinary and strict extracted consumers use real health admission over
# the fixture's local SSH transport before staging source or compiling.
# shellcheck source=../../src/host_health.sh
source "$ROOT/src/host_health.sh"
# shellcheck source=../../src/git_ops.sh
source "$ROOT/src/git_ops.sh"
# shellcheck source=../../src/packaging.sh
source "$ROOT/src/packaging.sh"
# State queries below run in this harness, independently of the CLI process.
build_state_init || exit 1

PASS=0 FAIL=0 STATUS=0 REAL_CAPACITY=true
check() {
    local label="$1"; shift
    if "$@"; then PASS=$((PASS + 1)); printf 'PASS: %s\n' "$label"
    else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$label" >&2; fi
}
count() { awk -v target="$2" '$0 == target {n++} END {print n+0}' "$1"; }
check 'stale source has exactly the current source size and timestamp' test \
    "$(stat -c '%s:%y' "$WORK/source/src/main.rs")" = "$(stat -c '%s:%y' "$WORK/hosts/repair/src/main.rs")"
check 'equal-metadata source fixture still has different actual bytes' \
    test "$(_act_sha256 "$WORK/source/src/main.rs")" != "$(_act_sha256 "$WORK/hosts/repair/src/main.rs")"

# Probe real reservation in the worker process context. Only a proven hosted
# PID namespace mismatch permits substituting this infrastructure boundary.
capacity_status=0
(
    printf '%s\n' "$BASHPID" > "$WORK/capacity-pid"
    cat /proc/self/status > "$WORK/capacity-proc-status"
    selector_acquire_slot healthybox source-sync-probe || exit $?
    selector_release_slot healthybox source-sync-probe
) > "$WORK/capacity.out" 2> "$WORK/capacity.log" &
capacity_pid=$!
wait "$capacity_pid" || capacity_status=$?
if [[ $capacity_status -ne 0 ]]; then
    namespace_pid=$(cat "$WORK/capacity-pid")
    # The recorded /proc reader is a child of the Bash probe. Independently
    # demonstrate that the invoking shell also sees inconsistent PID views.
    read -r host_pid _ < /proc/self/stat
    namespace_line=''
    while IFS= read -r line; do [[ "$line" != NSpid:* ]] || namespace_line="${line#NSpid:}"; done < /proc/self/status
    read -r -a namespace_pids <<< "$namespace_line"
    if [[ $capacity_status -ne 3 || ${#namespace_pids[@]} -lt 2 || "$host_pid" == "$BASHPID" ||
          "${namespace_pids[0]:-}" != "$host_pid" || "${namespace_pids[${#namespace_pids[@]}-1]:-}" != "$BASHPID" ]]; then
        printf 'FAIL: reservation failed without independent PID namespace evidence (status %s, worker %s)\n' \
            "$capacity_status" "$namespace_pid" >&2
        cat "$WORK/capacity.log" >&2
        exit 1
    fi
    REAL_CAPACITY=false
    printf 'BOUNDARY: host PID namespace blocks reservation; only slot acquisition/release substituted\n'
    selector_acquire_slot() { printf 'acquire %s %s\n' "$1" "$2" >> "$WORK/reservations.log"; return 0; }
    selector_release_slot() { printf 'release %s %s\n' "$1" "$2" >> "$WORK/reservations.log"; return 0; }
fi

export SCRIPT_DIR="$ROOT" JSON_MODE=true DRY_RUN=false VERBOSE=false DSR_VERSION=fixture
declare -A _DSR_LOADED_MODULES=([packaging]=1 [artifact_naming]=1)
# Actual public command definitions, used only where this host cannot reserve
# a process slot. Every sync, worker, native build and state operation is real.
# shellcheck disable=SC1090
source <(awk '/^(_dsr_require|cmd_build)\(\) \{/{copy=1} copy{print} copy && /^\}/{copy=0}' "$ROOT/dsr") || exit 1
# shellcheck disable=SC1090
source <(awk '/^json_envelope\(\) \{/{copy=1} copy{print} copy && /^# ====/{exit}' "$ROOT/dsr") || exit 1
run_build() {
    local label="$1" expected="$2"; shift 2
    STATUS=0
    if $REAL_CAPACITY; then
        bash "$ROOT/dsr" --json build "$@" > "$WORK/$label.json" 2> "$WORK/$label.log" || STATUS=$?
    else
        cmd_build "$@" > "$WORK/$label.json" 2> "$WORK/$label.log" || STATUS=$?
    fi
    check "$label command exits $expected (actual $STATUS)" test "$STATUS" -eq "$expected"
    check "$label emits one matching command envelope" jq -es --argjson status "$STATUS" \
        'length==1 and .[0].command=="build" and .[0].exit_code==$status' "$WORK/$label.json"
}

test_strict_publication() {
    local strict_output="$WORK/strict-output" strict_manifest strict_sha compilers_before
    strict_manifest="$strict_output/strictseal-v4.0.0-manifest.json"
    strict_sha=$(git -C "$WORK/source" rev-parse HEAD) || return 1
    compilers_before=$(count "$WORK/compiler-events" "$GNU")
    git -C "$WORK/source" tag v4.0.0 || return 1
    jq '.tool_name="strictseal" | .repo="example/strictseal" |
        .build_cmd="cargo build --release --locked --offline" |
        .targets=["linux/amd64"] | .act_job_map={"linux/amd64":null} |
        .target_triples={"linux/amd64":"x86_64-unknown-linux-gnu"} |
        .hosts={"linux/amd64":"healthybox"} |
        .release_contract={checksum_sidecar:"sha256",
            exact_primary_assets:{"linux/amd64":"syncfixture-x86_64-unknown-linux-gnu"}} |
        del(.archive_format,.artifact_naming)' "$ACT_REPOS_DIR/syncmixed.yaml" \
        > "$ACT_REPOS_DIR/strictseal.yaml" || return 1
    run_build strict-seal 0 strictseal --version 4.0.0 --jobs 1 --output-dir "$strict_output"
    if [[ $STATUS -ne 0 ]]; then
        cat "$WORK/strict-seal.log" >&2
        return 1
    fi
    build_state_get strictseal 4.0.0 > "$WORK/strict-state.json" || return 1
    check 'strict build persists completed state with its successful native target' jq -e '
        .status=="completed" and .target_statuses["linux/amd64"].status=="completed" and
        .target_statuses["linux/amd64"].result.status=="success"
        ' "$WORK/strict-state.json"
    check 'strict manifest binds exact source, target, artifact and completed run' jq -e \
        --arg sha "$strict_sha" --slurpfile state "$WORK/strict-state.json" \
        --arg artifact_sha "$(_act_sha256 "$strict_output/syncfixture-x86_64-unknown-linux-gnu")" '
        .run_id==$state[0].run_id and .source.git_sha==$sha and .source.git_ref=="v4.0.0" and
        .status=="success" and .build_purpose=="release" and .publishable==true and
        .summary.total==1 and .summary.success==1 and .summary.failed==0 and
        .requested_targets==["linux/amd64"] and (.artifacts|length)==1 and
        .artifacts[0].name=="syncfixture-x86_64-unknown-linux-gnu" and
        .artifacts[0].target=="linux/amd64" and .artifacts[0].publishable==true and
        .artifacts[0].sha256==$artifact_sha' "$strict_manifest"
    check 'public strict target retains its real source and compiler influence environment' jq -e \
        --arg sha "$strict_sha" --slurpfile manifest "$strict_manifest" \
        --slurpfile state "$WORK/strict-state.json" '
        .details.targets | length==1 and
        (.[0] as $target |
         $manifest[0].build_environments[0] as $environment |
         $state[0].target_statuses["linux/amd64"].result as $stored |
         $target.platform=="linux/amd64" and $target.method=="native" and
         $target.target_triple=="x86_64-unknown-linux-gnu" and
         ($target.build_influence_env | type)=="object" and
         $target.build_influence_env.DSR_RELEASE_GIT_SHA==$sha and
         $target.build_influence_env.DSR_RELEASE_GIT_REF=="v4.0.0" and
         $target.build_influence_env.CARGO_BUILD_TARGET=="x86_64-unknown-linux-gnu" and
         $target.build_influence_env==$environment.build_influence_env and
         $target.build_influence_env==$stored.build_influence_env)' "$WORK/strict-seal.json"
    check 'public strict target retains the same actual Cargo and rustc executable attestations' jq -e \
        --slurpfile manifest "$strict_manifest" --slurpfile state "$WORK/strict-state.json" '
        .details.targets[0].cargo_isolation as $isolation |
        ($isolation | type)=="object" and $isolation.mode=="strict-release-snapshot" and
        $isolation.toolchain.schema_version==1 and
        $isolation.toolchain.target_triple=="x86_64-unknown-linux-gnu" and
        ($isolation.toolchain.tools as $tools | all(("cargo","rustc");
            $tools[.] | (.selected_path | type=="string" and startswith("/")) and
            (.selected_sha256 | type=="string" and test("^[0-9a-f]{64}$")) and
            (.version | type=="string" and length>0))) and
        $isolation==$manifest[0].build_environments[0].cargo_isolation and
        $isolation==$state[0].target_statuses["linux/amd64"].result.cargo_isolation' "$WORK/strict-seal.json"
    check 'public strict target retains admitted and final private dependency cache evidence' jq -e '
        .details.targets[0].cargo_isolation as $isolation |
        $isolation.cache_reuse==[] and $isolation.dependency_cache.mode=="private-copy" and
        ($isolation.dependency_cache as $cache | all(("seed","final");
            $cache[.] | .schema_version==1 and
            (.receipt_sha256 | type=="string" and test("^[0-9a-f]{64}$")) and
            (.inventory_sha256 | type=="string" and test("^[0-9a-f]{64}$")) and
            (.cargo_home | type=="string" and startswith("/"))))' "$WORK/strict-seal.json"
    local strict_cargo_home
    strict_cargo_home=$(jq -er '.details.targets[0].cargo_isolation.cargo_home' "$WORK/strict-seal.json") || return 1
    check 'public strict target binds authenticated dependency evidence to actual metadata and lockfile bytes' jq -e \
        --arg metadata_sha "$(_act_sha256 "$strict_cargo_home/.dsr-cargo-metadata.json")" \
        --arg sources_sha "$(_act_sha256 "$strict_cargo_home/.dsr-cargo-sources.json")" \
        --arg lockfile_sha "$(_act_sha256 "$WORK/source/Cargo.lock")" '
        .details.targets[0].cargo_isolation as $isolation |
        $isolation.dependency_sources as $sources |
        $sources.schema_version==1 and $sources.kind=="dsr-cargo-dependency-sources" and
        $sources.metadata_sha256==$metadata_sha and $sources.sha256==$sources_sha and
        $sources.authentication.lockfile_sha256==$lockfile_sha and
        $sources.package_count==0 and $sources.root_count==0 and
        $sources.authentication.locked_archive_packages==0 and
        $sources.authentication.locked_git_packages==0 and
        $sources.authentication.workspace_snapshot_packages==0 and
        ($isolation.dependency_cache.seed | has("dependency_sources") | not)' "$WORK/strict-seal.json"
    check 'public strict target preserves its committed lockfile download selection through state and manifest' jq -e \
        --arg lockfile_sha "$(_act_sha256 "$WORK/source/Cargo.lock")" \
        --slurpfile manifest "$strict_manifest" --slurpfile state "$WORK/strict-state.json" '
        .details.targets[0].cargo_isolation.dependency_cache as $cache |
        $cache.seed.selection as $selection |
        $selection=={kind:"cargo-lock-downloads",lockfile_sha256:$lockfile_sha,
            registry_packages:0,git_revisions:[]} and
        $selection==$manifest[0].build_environments[0].cargo_isolation.dependency_cache.seed.selection and
        $selection==$state[0].target_statuses["linux/amd64"].result.cargo_isolation.dependency_cache.seed.selection and
        ($cache.final | has("selection") | not)' "$WORK/strict-seal.json"
    check 'strict publication receipt seals exact manifest bytes and source identity' jq -e \
        --arg sha "$strict_sha" --arg digest "$(_act_sha256 "$strict_manifest")" \
        --slurpfile state "$WORK/strict-state.json" '
        .publication_schema==1 and .publication_status=="completed" and
        .build_purpose=="release" and .publishable==true and .run_id==$state[0].run_id and
        .git_sha==$sha and .manifest_name=="strictseal-v4.0.0-manifest.json" and
        .manifest_sha256==$digest' "$strict_output/.dsr-build-purpose.json"
    check 'strict primary executes the current tagged source' test \
        "$("$strict_output/syncfixture-x86_64-unknown-linux-gnu")" = 'NEW_SOURCE gnu'
    check 'strict build compiles once using genuine Cargo build.rs' test \
        "$(count "$WORK/compiler-events" "$GNU")" -eq "$((compilers_before + 1))"
    check 'strict build leaves its tagged controller source clean' test \
        -z "$(git -C "$WORK/source" status --porcelain --untracked-files=all)"
    # shellcheck disable=SC1090
    source <(awk '/^(_release_sha256|_release_require_publishable_artifacts)\(\) \{/{copy=1} copy{print} copy && /^\}/{copy=0}' "$ROOT/dsr") || return 1
    check 'strict completed output passes real release publication admission' \
        _release_require_publishable_artifacts "$strict_output" "$strict_manifest" true
}

test_strict_variants() {
    # All source/metadata/compiler/collection/publication gates are production
    # code. The external failure marker changes no byte of the tagged source.
    # shellcheck source=../../src/host_health.sh
    source "$ROOT/src/host_health.sh" || return 1
    local output="$WORK/strict-variants-output" manifest config strict_sha run
    local gnu_key="linux/amd64@$GNU" musl_key="linux/amd64@$MUSL"
    local gnu_before musl_before gnu_path gnu_identity gnu_sha gnu_receipts
    config="$ACT_REPOS_DIR/strictvariants.yaml"
    manifest="$output/strictvariants-v4.1.0-manifest.json"
    strict_sha=$(git -C "$WORK/source" rev-parse HEAD) || return 1
    git -C "$WORK/source" tag v4.1.0 || return 1
    jq --arg work "$WORK" '.tool_name="strictvariants" | .repo="example/strictvariants" |
        .build_cmd="cargo build --release --locked --offline" |
        .targets=["linux/amd64"] | .act_job_map={"linux/amd64":null} |
        .target_triples={"linux/amd64":["x86_64-unknown-linux-gnu","x86_64-unknown-linux-musl"]} |
        .hosts={"linux/amd64":"healthybox"} |
        .include_files=["LICENSE"] |
        .workspace_additional_artifacts={"linux/amd64":["release-notes.txt"]} |
        .env.SYNC_TEST_FAIL_MUSL=($work+"/strict-fail-musl") |
        .release_contract={checksum_sidecar:"sha256",exact_primary_assets:{
            "linux/amd64@x86_64-unknown-linux-gnu":"syncfixture-standard.tar.gz",
            "linux/amd64@x86_64-unknown-linux-musl":"syncfixture-static"},
            exact_additional_assets:["release-notes.txt"]} |
        del(.archive_format,.artifact_naming)' "$ACT_REPOS_DIR/syncmixed.yaml" > "$config" || return 1
    cp "$config" "$WORK/strict-variants.original.json" || return 1
    gnu_before=$(count "$WORK/compiler-events" "$GNU")
    musl_before=$(count "$WORK/compiler-events" "$MUSL")
    : > "$WORK/strict-fail-musl"
    run_build strict-variants-partial 1 strictvariants --version 4.1.0 --jobs 2 --output-dir "$output"
    if [[ $STATUS -ne 1 ]]; then cat "$WORK/strict-variants-partial.log" >&2; return 1; fi
    check 'strict partial build reports two variant tasks on one physical platform' jq -e \
        --arg gnu "$GNU" --arg musl "$MUSL" '
        .status=="partial" and .details.total==2 and .details.success==1 and .details.failed==1 and
        ([.details.targets[].platform] | unique)==["linux/amd64"] and
        ([.details.targets[].target_triple] | sort)==([$gnu,$musl] | sort)
        ' "$WORK/strict-variants-partial.json"
    check 'strict partial build reaches genuine Cargo once per selected variant' test \
        "$(count "$WORK/compiler-events" "$GNU")/$(count "$WORK/compiler-events" "$MUSL")" = \
        "$((gnu_before + 1))/$((musl_before + 1))"
    check 'failed strict matrix does not expose a completed manifest' test ! -e "$manifest"
    build_state_get strictvariants 4.1.0 > "$WORK/strict-variants-partial-state.json" || return 1
    run=$(jq -er '.run_id' "$WORK/strict-variants-partial-state.json") || return 1
    check 'strict checkpoints retain independently keyed GNU success and musl failure' jq -e \
        --arg gnu "$gnu_key" --arg musl "$musl_key" '
        .context.build_tasks | length==2 and [.[].key]==[$gnu,$musl]
        ' "$WORK/strict-variants-partial-state.json"
    check 'strict checkpoint status belongs to each selected triple' jq -e \
        --arg gnu "$gnu_key" --arg musl "$musl_key" '
        .target_statuses[$gnu].status=="completed" and .target_statuses[$musl].status=="failed" and
        .target_statuses[$gnu].result.target_triple=="x86_64-unknown-linux-gnu" and
        .target_statuses[$musl].result.target_triple=="x86_64-unknown-linux-musl"
        ' "$WORK/strict-variants-partial-state.json"
    gnu_path=$(jq -er --arg key "$gnu_key" '.target_statuses[$key].result.artifact_path' \
        "$WORK/strict-variants-partial-state.json") || return 1
    gnu_identity=$(_act_file_identity "$gnu_path") || return 1
    gnu_sha=$(_act_sha256 "$gnu_path") || return 1
    gnu_receipts=$(jq -c --arg key "$gnu_key" '.target_statuses[$key].result.resume_artifacts' \
        "$WORK/strict-variants-partial-state.json") || return 1
    gnu_before=$(count "$WORK/compiler-events" "$GNU")
    musl_before=$(count "$WORK/compiler-events" "$MUSL")

    jq '.target_triples["linux/amd64"] |= reverse' "$WORK/strict-variants.original.json" > "$config" || return 1
    run_build strict-variants-reordered 4 strictvariants --version 4.1.0 --jobs 2 --resume="$run" --output-dir "$output"
    check 'changed primary ordering is refused before either compiler runs' test \
        "$(count "$WORK/compiler-events" "$GNU")/$(count "$WORK/compiler-events" "$MUSL")" = "$gnu_before/$musl_before"
    jq '.release_contract.exact_primary_assets["linux/amd64@x86_64-unknown-linux-musl"]="different-static-name"' \
        "$WORK/strict-variants.original.json" > "$config" || return 1
    run_build strict-variants-renamed 4 strictvariants --version 4.1.0 --jobs 2 --resume="$run" --output-dir "$output"
    check 'changed exact release name is refused before either compiler runs' test \
        "$(count "$WORK/compiler-events" "$GNU")/$(count "$WORK/compiler-events" "$MUSL")" = "$gnu_before/$musl_before"
    cp "$WORK/strict-variants.original.json" "$config" || return 1
    mv "$WORK/strict-fail-musl" "$WORK/strict-fail-musl.disabled" || return 1
    run_build strict-variants-resumed 0 strictvariants --version 4.1.0 --jobs 2 --resume="$run" --output-dir "$output"
    if [[ $STATUS -ne 0 ]]; then cat "$WORK/strict-variants-resumed.log" >&2; return 1; fi
    build_state_get strictvariants 4.1.0 "$run" > "$WORK/strict-variants-resumed-state.json" || return 1
    check 'strict resume compiles only the failed musl task' test \
        "$(count "$WORK/compiler-events" "$GNU")/$(count "$WORK/compiler-events" "$MUSL")" = "$gnu_before/$((musl_before + 1))"
    check 'strict resume retains the original GNU artifact path' test "$gnu_path" = \
        "$(jq -r --arg key "$gnu_key" '.target_statuses[$key].result.artifact_path' "$WORK/strict-variants-resumed-state.json")"
    check 'strict resume preserves the original GNU bytes and inode' test \
        "$(_act_file_identity "$gnu_path")/$(_act_sha256 "$gnu_path")" = "$gnu_identity/$gnu_sha"
    check 'strict resume preserves the entire original GNU artifact receipt inventory' test "$gnu_receipts" = \
        "$(jq -c --arg key "$gnu_key" '.target_statuses[$key].result.resume_artifacts' "$WORK/strict-variants-resumed-state.json")"
    check 'strict state completes the same run with exactly one musl retry' jq -e \
        --arg run "$run" --arg gnu "$gnu_key" --arg musl "$musl_key" '
        .run_id==$run and .status=="completed" and
        .target_statuses[$gnu].attempts==1 and .target_statuses[$musl].attempts==2
        ' "$WORK/strict-variants-resumed-state.json"
    check 'strict manifest keeps physical platform and exact per-triple artifact names and formats' jq -e \
        --arg sha "$strict_sha" --arg run "$run" '
        .run_id==$run and .source.git_sha==$sha and .source.git_ref=="v4.1.0" and
        .status=="success" and .build_purpose=="release" and .publishable==true and
        .requested_targets==["linux/amd64"] and .summary=={total:2,success:2,failed:0} and
        ([.artifacts[] | select(.target!="additional") | {name,target,target_triple,archive_format}] | sort_by(.name))==[
          {name:"syncfixture-standard.tar.gz",target:"linux/amd64",target_triple:"x86_64-unknown-linux-gnu",archive_format:"tar.gz"},
          {name:"syncfixture-static",target:"linux/amd64",target_triple:"x86_64-unknown-linux-musl",archive_format:"binary"}]
        ' "$manifest"
    check 'strict manifest retains two distinct native compiler environments' jq -e \
        --arg gnu "$GNU" --arg musl "$MUSL" '
        (.build_environments | length)==2 and
        ([.build_environments[].target_triple] | sort)==([$gnu,$musl] | sort) and
        all(.build_environments[]; .target=="linux/amd64" and .method=="native" and
            .build_influence_env.CARGO_BUILD_TARGET==.target_triple and
            .cargo_isolation.toolchain.target_triple==.target_triple and
            .cargo_isolation.mode=="strict-release-snapshot") and
        ([.build_environments[].cargo_isolation.target_dir] | unique | length)==2 and
        ([.build_environments[].cargo_isolation.cargo_home] | unique | length)==2
        ' "$manifest"
    local triple cargo_home
    for triple in "$GNU" "$MUSL"; do
        cargo_home=$(jq -er --arg triple "$triple" \
            '.build_environments[] | select(.target_triple==$triple) | .cargo_isolation.cargo_home' "$manifest") || return 1
        check "strict $triple receipt preserves actual metadata, lock and private cache evidence" jq -e \
            --arg triple "$triple" --arg sha "$strict_sha" \
            --arg metadata "$(_act_sha256 "$cargo_home/.dsr-cargo-metadata.json")" \
            --arg sources "$(_act_sha256 "$cargo_home/.dsr-cargo-sources.json")" \
            --arg lock "$(_act_sha256 "$WORK/source/Cargo.lock")" \
            --slurpfile state "$WORK/strict-variants-resumed-state.json" \
            --slurpfile public "$WORK/strict-variants-resumed.json" '
            .build_environments[] | select(.target_triple==$triple) as $env |
            $state[0].target_statuses["linux/amd64@"+$triple].result as $stored |
            ($public[0].details.targets[] | select(.target_triple==$triple)) as $target |
            $env.cargo_isolation as $isolation |
            $env.build_influence_env.DSR_RELEASE_GIT_SHA==$sha and
            $env.build_influence_env==$stored.build_influence_env and
            $env.build_influence_env==$target.build_influence_env and
            $isolation==$stored.cargo_isolation and $isolation==$target.cargo_isolation and
            $isolation.dependency_sources.metadata_sha256==$metadata and
            $isolation.dependency_sources.sha256==$sources and
            $isolation.dependency_sources.authentication.lockfile_sha256==$lock and
            $isolation.dependency_cache.mode=="private-copy" and
            $isolation.dependency_cache.seed.selection.lockfile_sha256==$lock and
            all(("seed","final"); $isolation.dependency_cache[.] |
                (.inventory_sha256 | test("^[0-9a-f]{64}$")) and
                (.receipt_sha256 | test("^[0-9a-f]{64}$")))
            ' "$manifest"
    done
    check 'GNU exact archive contains its executable and pinned license' test \
        "$(tar -tzf "$output/syncfixture-standard.tar.gz" | LC_ALL=C sort)" = $'LICENSE\nsyncfixture'
    check 'GNU exact archive retains pinned license bytes' test \
        "$(tar -xOzf "$output/syncfixture-standard.tar.gz" LICENSE)" = "$(cat "$WORK/source/LICENSE")"
    tar -xOzf "$output/syncfixture-standard.tar.gz" syncfixture > "$WORK/strict-variant-gnu" || return 1
    chmod +x "$WORK/strict-variant-gnu" || return 1
    check 'GNU exact archive contains an executable from the tagged GNU source' test \
        "$("$WORK/strict-variant-gnu")" = 'NEW_SOURCE gnu'
    check 'musl exact raw asset executes the tagged musl source' test \
        "$("$output/syncfixture-static")" = 'NEW_SOURCE musl'
    check 'shared additional asset is collected once by the primary GNU task' jq -e \
        --arg gnu "$gnu_key" --arg musl "$musl_key" --slurpfile manifest "$manifest" '
        ([.target_statuses[$gnu].result.additional_artifacts[].path | split("/")[-1]])==["release-notes.txt"] and
        (.target_statuses[$musl].result.additional_artifacts | length)==0 and
        ([$manifest[0].artifacts[] | select(.target=="additional") | .name])==["release-notes.txt"]
        ' "$WORK/strict-variants-resumed-state.json"
    check 'additional release notes retain actual build-produced bytes' test \
        "$(cat "$output/release-notes.txt")" = 'Reviewed strict variant release notes'
    check 'strict variant publication seal binds the completed manifest bytes' jq -e \
        --arg sha "$strict_sha" --arg digest "$(_act_sha256 "$manifest")" --arg run "$run" '
        .publication_status=="completed" and .publishable==true and .run_id==$run and
        .git_sha==$sha and .manifest_name=="strictvariants-v4.1.0-manifest.json" and
        .manifest_sha256==$digest' "$output/.dsr-build-purpose.json"
    check 'strict variants leave the tagged source tree clean' test \
        -z "$(git -C "$WORK/source" status --porcelain --untracked-files=all)"

    # Exercise the public release command and the real strict preflight. Only
    # GitHub authentication/HTTP is a named local fixture; every unexpected
    # endpoint, including any attempted mutation, fails and is recorded.
    # shellcheck source=../../src/github.sh
    source "$ROOT/src/github.sh" || return 1
    # shellcheck disable=SC1090
    source <(awk '/^(_release_[A-Za-z0-9_]+|cmd_release)\(\) \{/{copy=1} copy{print} copy && /^\}/{copy=0}' "$ROOT/dsr") || return 1
    gh_check() { return 0; }
    gh_check_token() { return 0; }
    gh_api() {
        printf '%s\n' "$*" >> "$WORK/strict-variant-http.log"
        [[ $# -eq 2 && "$1" == repos/example/strictvariants/git/ref/tags/v4.1.0 && "$2" == --no-cache ]] || return 89
        jq -n --arg sha "$strict_sha" '{object:{type:"commit",sha:$sha}}'
    }
    check 'completed strict variant output passes real publication admission' \
        _release_require_publishable_artifacts "$output" "$manifest" true
    local contract
    contract=$(config_get_release_contract_json strictvariants) || return 1
    STATUS=0
    _release_contract_preflight strictvariants v4.1.0 example/strictvariants "$WORK/source" \
        "$output" "$manifest" "$contract" plan > "$WORK/strict-variant-plan.json" \
        2> "$WORK/strict-variant-plan.log" || STATUS=$?
    check 'strict preflight admits the actual compiled and sealed variant output' test "$STATUS" -eq 0
    if [[ $STATUS -ne 0 ]]; then cat "$WORK/strict-variant-plan.log" >&2; return 1; fi
    check 'strict plan selects exactly both primaries, their sidecars and shared notes' jq -e '
        ([.assets[].name] | sort)==["release-notes.txt","syncfixture-standard.tar.gz",
            "syncfixture-standard.tar.gz.sha256","syncfixture-static","syncfixture-static.sha256"] and
        ([.assets[].name] | length)==([.assets[].name] | unique | length)
        ' "$WORK/strict-variant-plan.json"
    check 'strict primary and checksum upload rows retain physical platform and selected triple' jq -e '
        [.assets[] | select(.kind=="primary" or .kind=="checksum") |
            {name,target,target_triple}] == [
          {name:"syncfixture-standard.tar.gz",target:"linux/amd64",target_triple:"x86_64-unknown-linux-gnu"},
          {name:"syncfixture-standard.tar.gz.sha256",target:"linux/amd64",target_triple:"x86_64-unknown-linux-gnu"},
          {name:"syncfixture-static",target:"linux/amd64",target_triple:"x86_64-unknown-linux-musl"},
          {name:"syncfixture-static.sha256",target:"linux/amd64",target_triple:"x86_64-unknown-linux-musl"}]
        ' "$WORK/strict-variant-plan.json"
    STATUS=0
    DRY_RUN=true cmd_release strictvariants 4.1.0 --artifacts "$output" \
        > "$WORK/strict-variant-release.json" 2> "$WORK/strict-variant-release.log" || STATUS=$?
    check 'public strict release dry-run admits both real variants' test "$STATUS" -eq 0
    if [[ $STATUS -ne 0 ]]; then cat "$WORK/strict-variant-release.log" >&2; return 1; fi
    check 'public dry-run publishes the exact selected names without guessed aliases' jq -e \
        --slurpfile plan "$WORK/strict-variant-plan.json" '
        .command=="release" and .exit_code==0 and .details.plan.strict==true and
        .details.file_count==5 and (.details.plan.assets | sort)==([$plan[0].assets[].name] | sort)
        ' "$WORK/strict-variant-release.json"
    check 'strict dry-run leaves its planned checksum sidecars uncreated' test \
        ! -e "$output/syncfixture-static.sha256"
    check 'release HTTP fixture saw only read-only resolution of the pinned tag' \
        test "$(LC_ALL=C sort -u "$WORK/strict-variant-http.log")" = \
        'repos/example/strictvariants/git/ref/tags/v4.1.0 --no-cache'

    # Mutation controls keep bytes, artifact hashes and publication seals
    # self-consistent. They must fail the semantic variant checks, not merely
    # the outer manifest digest gate. The original completed output is intact.
    local label mutation directory bad_manifest before_requests
    while IFS=$'\t' read -r label mutation; do
        directory="$WORK/strict-variant-refuse-$label"
        cp -a "$output" "$directory" || return 1
        bad_manifest="$directory/${manifest##*/}"
        jq "$mutation" "$manifest" > "$bad_manifest" || return 1
        jq --arg digest "$(_act_sha256 "$bad_manifest")" '.manifest_sha256=$digest' \
            "$output/.dsr-build-purpose.json" > "$directory/.dsr-build-purpose.json" || return 1
        check "$label control retains a valid outer publication seal" \
            _release_require_publishable_artifacts "$directory" "$bad_manifest" true
        before_requests=$(wc -l < "$WORK/strict-variant-http.log")
        STATUS=0
        _release_contract_preflight strictvariants v4.1.0 example/strictvariants "$WORK/source" \
            "$directory" "$bad_manifest" "$contract" plan > "$WORK/strict-variant-refuse-$label.json" \
            2> "$WORK/strict-variant-refuse-$label.log" || STATUS=$?
        check "strict release refuses $label despite consistent bytes and seal" test "$STATUS" -eq 4
        check "$label refusal emits no upload plan" test ! -s "$WORK/strict-variant-refuse-$label.json"
        check "$label refusal happens before remote tag resolution" test \
            "$(wc -l < "$WORK/strict-variant-http.log")" -eq "$before_requests"
    done <<'CONTROLS'
missing-artifact-triple	del(.artifacts[] | select(.name=="syncfixture-static") | .target_triple)
swapped-artifact-triple	(.artifacts[] | select(.name=="syncfixture-static") | .target_triple)="x86_64-unknown-linux-gnu"
missing-environment	.build_environments |= map(select(.target_triple!="x86_64-unknown-linux-musl"))
contradictory-environment	(.build_environments[] | select(.target_triple=="x86_64-unknown-linux-musl") | .build_influence_env.CARGO_BUILD_TARGET)="x86_64-unknown-linux-gnu"
contradictory-toolchain	(.build_environments[] | select(.target_triple=="x86_64-unknown-linux-musl") | .cargo_isolation.toolchain.target_triple)="x86_64-unknown-linux-gnu"
CONTROLS
}

test_strict_mixed_protocol() {
    local config="$ACT_REPOS_DIR/mixedprotocol.yaml" protocol="$WORK/mixed-protocol.json"
    local contract projected rows sha mutation label status
    printf 'PROTOCOL: mixed GNU/musl plus Darwin receipts; no Darwin compilation or payload admission\n'
    sha=$(git -C "$WORK/source" rev-parse HEAD) || return 1
    git -C "$WORK/source" tag v4.2.0 || return 1
    jq '.tool_name="mixedprotocol" | .repo="example/mixedprotocol" |
        .build_cmd="cargo build --release --locked --offline" |
        .targets=["linux/amd64","darwin/arm64"] |
        .act_job_map={"linux/amd64":null,"darwin/arm64":null} |
        .target_triples={"linux/amd64":["x86_64-unknown-linux-gnu","x86_64-unknown-linux-musl"],
                         "darwin/arm64":"aarch64-apple-darwin"} |
        .workspace_additional_artifacts={"linux/amd64":["linux-notes.txt"],"darwin/arm64":["mac-notes.txt"]} |
        .release_contract={checksum_sidecar:"sha256",exact_primary_assets:{
            "linux/amd64@x86_64-unknown-linux-gnu":"standard",
            "linux/amd64@x86_64-unknown-linux-musl":"static",
            "darwin/arm64":"macos"},exact_additional_assets:["linux-notes.txt","mac-notes.txt"]} |
        del(.archive_format,.artifact_naming)' "$ACT_REPOS_DIR/syncmixed.yaml" > "$config" || return 1
    cp "$config" "$WORK/mixed-protocol-config.json" || return 1
    act_load_repo_config mixedprotocol >/dev/null || return 1
    contract=$(config_get_release_contract_json mixedprotocol) || return 1
    jq -n --arg sha "$sha" '
        [["linux/amd64","x86_64-unknown-linux-gnu","standard"],
         ["linux/amd64","x86_64-unknown-linux-musl","static"],
         ["darwin/arm64","aarch64-apple-darwin","macos"]] as $selected |
        {tool:"mixedprotocol",version:"v4.2.0",status:"success",
         source:{git_sha:$sha,git_ref:"v4.2.0",dependencies:[]},
         requested_targets:["linux/amd64","darwin/arm64"],summary:{total:3,success:3,failed:0},
         build_environments:[$selected[] | {target:.[0],target_triple:.[1],host:"protocol-only",method:"native",
            build_influence_env:{CARGO_BUILD_TARGET:.[1],DSR_TARGET_TRIPLE:.[1],
                DSR_RELEASE_GIT_SHA:$sha,DSR_RELEASE_GIT_REF:"v4.2.0"},
            cargo_isolation:{mode:"strict-release-snapshot",toolchain:{target_triple:.[1]}}}],
         artifacts:[$selected[] | {target:.[0],target_triple:.[1],name:.[2],
            sha256:("a"*64),size_bytes:1,archive_format:"binary"}]}
        ' > "$protocol" || return 1
    check 'protocol mixed matrix admits three compiler identities on two physical platforms' \
        _act_validate_contract_variant_inventory mixedprotocol "$(cat "$protocol")" "$contract"
    rows=$(_act_contract_target_rows mixedprotocol "$contract") || return 1
    check 'mixed identity rows bind singleton and variants without changing task keys' jq -e '
        length==3 and all(.[]; .require_triple==true) and
        [.[] | {key,platform,target_triple}]==[
          {key:"linux/amd64@x86_64-unknown-linux-gnu",platform:"linux/amd64",target_triple:"x86_64-unknown-linux-gnu"},
          {key:"linux/amd64@x86_64-unknown-linux-musl",platform:"linux/amd64",target_triple:"x86_64-unknown-linux-musl"},
          {key:"darwin/arm64",platform:"darwin/arm64",target_triple:"aarch64-apple-darwin"}]
        ' <<< "$rows"
    _act_build_task_plan mixedprotocol v4.2.0 '["linux/amd64","darwin/arm64"]' true \
        > "$WORK/mixed-protocol-tasks.json" || return 1
    check 'mixed scheduler keeps two qualified variants and one singleton task' jq -e '
        [.[].key]==["linux/amd64@x86_64-unknown-linux-gnu","linux/amd64@x86_64-unknown-linux-musl","darwin/arm64"] and
        all(.[]; .method=="native")' "$WORK/mixed-protocol-tasks.json"
    while IFS=$'\t' read -r label mutation; do
        jq "$mutation" "$protocol" > "$WORK/mixed-protocol-$label.json" || return 1
        status=0
        _act_validate_contract_variant_inventory mixedprotocol \
            "$(cat "$WORK/mixed-protocol-$label.json")" "$contract" \
            > "$WORK/mixed-protocol-$label.out" 2> "$WORK/mixed-protocol-$label.log" || status=$?
        check "mixed protocol refuses $label" test "$status" -eq 4
    done <<'MIXED_CONTROLS'
wrong-singleton-artifact	(.artifacts[] | select(.target=="darwin/arm64") | .target_triple)="x86_64-apple-darwin"
missing-singleton-artifact	del(.artifacts[] | select(.target=="darwin/arm64") | .target_triple)
wrong-singleton-environment	(.build_environments[] | select(.target=="darwin/arm64") | .target_triple)="x86_64-apple-darwin"
contradictory-singleton-cargo	(.build_environments[] | select(.target=="darwin/arm64") | .build_influence_env.CARGO_BUILD_TARGET)="x86_64-apple-darwin"
contradictory-singleton-toolchain	(.build_environments[] | select(.target=="darwin/arm64") | .cargo_isolation.toolchain.target_triple)="x86_64-apple-darwin"
relabeled-singleton	(.artifacts[] | select(.target=="darwin/arm64") | .target_triple)="x86_64-apple-darwin" | (.build_environments[] | select(.target=="darwin/arm64")) |= (.target_triple="x86_64-apple-darwin" | .build_influence_env.CARGO_BUILD_TARGET="x86_64-apple-darwin" | .build_influence_env.DSR_TARGET_TRIPLE="x86_64-apple-darwin" | .cargo_isolation.toolchain.target_triple="x86_64-apple-darwin")
collapsed-summary	.summary={total:2,success:2,failed:0}
MIXED_CONTROLS

    projected=$(_act_contract_for_build_purpose mixedprotocol "$contract" '["linux/amd64"]' diagnostic-native) || return 1
    check 'Linux diagnostic projection retains both variants and only Linux-owned notes' jq -e '
        (.exact_primary_assets | keys)==["linux/amd64@x86_64-unknown-linux-gnu","linux/amd64@x86_64-unknown-linux-musl"] and
        .exact_additional_assets==["linux-notes.txt"]' <<< "$projected"
    projected=$(_act_contract_for_build_purpose mixedprotocol "$contract" '["darwin/arm64"]' diagnostic-native) || return 1
    check 'singleton diagnostic projection retains only its exact primary and owned notes' jq -e '
        .exact_primary_assets=={"darwin/arm64":"macos"} and .exact_additional_assets==["mac-notes.txt"]' <<< "$projected"
    rows=$(_act_contract_target_rows mixedprotocol "$projected") || return 1
    check 'singleton projection still binds the parent matrix compiler triple' jq -e '
        .==[{key:"darwin/arm64",platform:"darwin/arm64",target_triple:"aarch64-apple-darwin",primary:true,require_triple:true}]
        ' <<< "$rows"
    jq '.requested_targets=["darwin/arm64"] | .summary={total:1,success:1,failed:0} |
        .artifacts |= map(select(.target=="darwin/arm64")) |
        .build_environments |= map(select(.target=="darwin/arm64"))' "$protocol" \
        > "$WORK/mixed-protocol-diagnostic.json" || return 1
    check 'correct singleton-only diagnostic receipt passes projected identity checks' \
        _act_validate_contract_variant_inventory mixedprotocol "$(cat "$WORK/mixed-protocol-diagnostic.json")" "$projected"
    status=0
    _act_validate_contract_variant_inventory mixedprotocol \
        "$(jq 'del(.artifacts[0].target_triple)' "$WORK/mixed-protocol-diagnostic.json")" "$projected" \
        > "$WORK/mixed-protocol-diagnostic-missing.out" 2> "$WORK/mixed-protocol-diagnostic-missing.log" || status=$?
    check 'singleton diagnostic cannot discard its triple after physical projection' test "$status" -eq 4
    status=0
    _act_contract_for_build_purpose mixedprotocol "$contract" '["darwin/arm64"]' release \
        > "$WORK/mixed-protocol-partial-release.out" 2> "$WORK/mixed-protocol-partial-release.log" || status=$?
    check 'release selection still requires the complete physical platform set' test "$status" -eq 4

    jq 'del(.target_triples["darwin/arm64"])' "$WORK/mixed-protocol-config.json" > "$config" || return 1
    rows=$(_act_contract_target_rows mixedprotocol "$contract") || return 1
    check 'omitted singleton mapping derives the native backend default' jq -e '
        .[] | select(.platform=="darwin/arm64") |
        .target_triple=="aarch64-apple-darwin" and .require_triple==true' <<< "$rows"
    check 'backend-derived singleton default admits matching protocol receipts' \
        _act_validate_contract_variant_inventory mixedprotocol "$(cat "$protocol")" "$contract"
    status=0
    _act_validate_contract_variant_inventory mixedprotocol \
        "$(cat "$WORK/mixed-protocol-relabeled-singleton.json")" "$contract" \
        > "$WORK/mixed-protocol-default-relabel.out" 2> "$WORK/mixed-protocol-default-relabel.log" || status=$?
    check 'observed singleton receipts cannot choose a different backend default' test "$status" -eq 4
    jq '.workspace_additional_artifacts["darwin/arm64"] += ["linux-notes.txt"]' \
        "$WORK/mixed-protocol-config.json" > "$config" || return 1
    status=0
    _act_contract_for_build_purpose mixedprotocol "$contract" '["darwin/arm64"]' diagnostic-native \
        > "$WORK/mixed-protocol-duplicate-owner.out" 2> "$WORK/mixed-protocol-duplicate-owner.log" || status=$?
    check 'a shared additional asset cannot be claimed by two physical platforms' test "$status" -eq 4
    cp "$WORK/mixed-protocol-config.json" "$config" || return 1

    # Exercise the real generator selector before artifact I/O. These protocol
    # rows intentionally have no executable bytes; no artifact gate is replaced.
    jq --arg sha "$sha" '
        {tool:"mixedprotocol",version:"v4.2.0",run_id:"11111111-1111-4111-8111-111111111111",
         git_sha:$sha,git_ref:"v4.2.0",source_dependencies:[],build_purpose:"release",publishable:true,
         requested_targets:.requested_targets,status:"success",summary:.summary,
         targets:[.build_environments[] | . + {platform:.target,status:"success",build_purpose:"release",publishable:true,
            task_key:(if .target=="linux/amd64" then .target+"@"+.target_triple else .target end),
            staged_sha256:("a"*64),staged_size_bytes:1,staged_identity:"gnu:1:1"} | del(.target)]}
        ' "$protocol" > "$WORK/mixed-protocol-results.json" || return 1
    for mutation in \
        '(.targets[] | select(.platform=="darwin/arm64") | .target_triple)="x86_64-apple-darwin"' \
        'del(.targets[] | select(.platform=="darwin/arm64") | .target_triple)'; do
        status=0
        _act_generate_contract_manifest "$(jq "$mutation" "$WORK/mixed-protocol-results.json")" \
            "$WORK/mixed-protocol-refused-manifest.json" "$contract" \
            > "$WORK/mixed-protocol-generator.out" 2> "$WORK/mixed-protocol-generator.log" || status=$?
        check 'mixed generator refuses an inconsistent singleton result identity' test "$status" -eq 4
        check 'mixed generator refusal comes from the exact result selector' \
            grep -q 'requires exact N/N successful target results' "$WORK/mixed-protocol-generator.log"
        check 'inconsistent singleton never produces a manifest' test ! -e "$WORK/mixed-protocol-refused-manifest.json"
    done
}

if [[ "${1:-}" == --strict-mixed-protocol-only ]]; then
    test_strict_mixed_protocol || exit 1
    printf 'Results: %s passed, %s failed; evidence %s\n' "$PASS" "$FAIL" "$WORK"
    [[ "$FAIL" -eq 0 ]]
    exit $?
fi

if [[ "${1:-}" == --strict-variants-only ]]; then
    test_strict_variants || exit 1
    printf 'Results: %s passed, %s failed; evidence %s\n' "$PASS" "$FAIL" "$WORK"
    [[ "$FAIL" -eq 0 ]]
    exit $?
fi

if [[ "${1:-}" == --strict-publication-only ]]; then
    test_strict_publication || exit 1
    printf 'Results: %s passed, %s failed; evidence %s\n' "$PASS" "$FAIL" "$WORK"
    [[ "$FAIL" -eq 0 ]]
    exit $?
fi

# Sync-only never invokes reservation, so both failure variants use the full
# public executable even when the isolated capacity boundary is unavailable.
for tool in syncmixed syncrepair; do
    STATUS=0
    bash "$ROOT/dsr" --json build "$tool" --version 1.2.3 --sync-only \
        --output-dir "$WORK/sync-only-$tool" > "$WORK/sync-only-$tool.json" \
        2> "$WORK/sync-only-$tool.log" || STATUS=$?
    check "$tool sync-only exits1 when any requested host fails" test "$STATUS" -eq 1
    if [[ "$tool" == syncmixed ]]; then
        check "$tool sync-only reports actual partial success and failure counts" jq -es \
            'length==1 and .[0].status=="partial" and .[0].exit_code==1 and
             .[0].details.status=="partial" and .[0].details.synced==1 and .[0].details.failed==1' "$WORK/sync-only-$tool.json"
    else
        check "$tool sync-only reports complete source failure" jq -es \
            'length==1 and .[0].status=="error" and .[0].exit_code==1 and
             .[0].details.status=="failed" and .[0].details.synced==0 and
             .[0].details.failed==1' "$WORK/sync-only-$tool.json"
    fi
done
check 'sync-only never reaches either real Cargo command' test ! -s "$WORK/build-commands"

MIXED_OUTPUT="$WORK/mixed-output"
run_build mixed 1 syncmixed --version 1.2.4 --jobs 2 --output-dir "$MIXED_OUTPUT"
check 'healthy host completes while failed source sync remains a failed task' jq -e \
    '.details.success==1 and .details.failed==1' "$WORK/mixed.json"
check 'public build JSON retains the complete partial source synchronization receipt' jq -e \
    --arg root "$WORK/stages/" '
    .details.source_sync | .status=="partial" and .synced==1 and .failed==1 and
    .target_hosts=={"linux/amd64":"healthybox","linux/arm64":"badbox"} and
    .staged_ordinary==true and
    (.source_roots.healthybox | startswith($root) and endswith("/source")) and
    any(.hosts[]; .host=="healthybox" and .status=="success" and
        (.path | startswith($root) and endswith("/source"))) and
    any(.hosts[]; .host=="badbox" and .status=="failed" and
        (.error | contains("intentional rsync receiver connection loss")))' "$WORK/mixed.json"
check 'public failed target exposes source stage, original host receipt, error and log path' jq -e '
    .details as $details |
    ($details.source_sync.hosts[] | select(.host=="badbox")) as $source |
    $details.targets[] | select(.platform=="linux/arm64") |
    .stage=="source_sync" and .source_sync==$source and
    (.error | type=="string" and length>0) and (.log_path | type=="string" and length>0)
    ' "$WORK/mixed.json"
check 'failed host never starts its configured build command' test "$(count "$WORK/build-commands" "$ARM")" -eq 0
check 'failed host never runs its genuine Cargo build script' test "$(count "$WORK/compiler-events" "$ARM")" -eq 0
build_state_get syncmixed 1.2.4 > "$WORK/mixed-state.json" || true
MIXED_RUN=$(jq -r '.run_id // empty' "$WORK/mixed-state.json")
check 'source sync failure has a persistent stage and selected host' jq -e \
    '.target_statuses["linux/arm64"].status=="failed" and
     .target_statuses["linux/arm64"].result.stage=="source_sync" and
     .target_statuses["linux/arm64"].result.host=="badbox"' "$WORK/mixed-state.json"
HEALTHY_PATH=$(jq -r '.target_statuses["linux/amd64"].result.artifact_path // empty' "$WORK/mixed-state.json")
HEALTHY_RECEIPTS=$(jq -c '.target_statuses["linux/amd64"].result.resume_artifacts // null' "$WORK/mixed-state.json")
HEALTHY_BEFORE=$(count "$WORK/build-commands" "$GNU")
if [[ -n "$HEALTHY_PATH" && -x "$HEALTHY_PATH" ]]; then
    check 'healthy artifact executes fresh source bytes' test "$("$HEALTHY_PATH")" = 'NEW_SOURCE gnu'
    HEALTHY_ID=$(_act_file_identity "$HEALTHY_PATH")
    HEALTHY_SHA=$(_act_sha256 "$HEALTHY_PATH")
else
    check 'healthy artifact exists' false
    HEALTHY_ID='' HEALTHY_SHA=''
fi
if [[ -n "$MIXED_RUN" ]]; then
    run_build mixed-resume 1 syncmixed --version 1.2.4 --jobs 2 --resume="$MIXED_RUN" --output-dir "$MIXED_OUTPUT"
    build_state_get syncmixed 1.2.4 "$MIXED_RUN" > "$WORK/mixed-resumed-state.json" || true
    check 'resume does not recompile the completed healthy target' test "$(count "$WORK/build-commands" "$GNU")" -eq "$HEALTHY_BEFORE"
    check 'resume does not compile the still-unsynced target' test "$(count "$WORK/build-commands" "$ARM")" -eq 0
    check 'resume keeps exact completed artifact custody receipts' test "$HEALTHY_RECEIPTS" = \
        "$(jq -c '.target_statuses["linux/amd64"].result.resume_artifacts // null' "$WORK/mixed-resumed-state.json")"
    if [[ -n "$HEALTHY_PATH" && -f "$HEALTHY_PATH" ]]; then
        check 'resume preserves completed artifact path/inode/bytes' test \
            "$HEALTHY_PATH/$HEALTHY_ID/$HEALTHY_SHA" = \
            "$(jq -r '.target_statuses["linux/amd64"].result.artifact_path' "$WORK/mixed-resumed-state.json")/$(_act_file_identity "$HEALTHY_PATH")/$(_act_sha256 "$HEALTHY_PATH")"
    fi
fi

# All-source-failed attempts also need a resumable checkpoint. Repeated
# receiver outages must not exhaust a compiler retry budget before Cargo runs.
REPAIR_OUTPUT="$WORK/repair-output"
GNU_BEFORE=$(count "$WORK/build-commands" "$GNU")
MUSL_BEFORE=$(count "$WORK/build-commands" "$MUSL")
run_build repair-blocked 6 syncrepair --version 1.2.5 --jobs 2 --output-dir "$REPAIR_OUTPUT"
build_state_get syncrepair 1.2.5 > "$WORK/repair-state.json" || true
REPAIR_RUN=$(jq -r '.run_id // empty' "$WORK/repair-state.json")
check 'complete source outage still records a resumable run' test -n "$REPAIR_RUN"
check 'all matrix variants record source_sync failures' jq -e \
    '(.target_statuses|length)==2 and all(.target_statuses[];
        .status=="failed" and .result.stage=="source_sync" and .result.host=="repairbox")' "$WORK/repair-state.json"
if [[ -n "$REPAIR_RUN" ]]; then
    for attempt in 1 2 3 4; do
        run_build "repair-still-blocked-$attempt" 6 syncrepair --version 1.2.5 --jobs 2 \
            --resume="$REPAIR_RUN" --output-dir "$REPAIR_OUTPUT"
    done
    build_state_get syncrepair 1.2.5 "$REPAIR_RUN" > "$WORK/repeated-sync-state.json" || true
    check 'repeated outages retain source_sync diagnosis rather than compiler retry exhaustion' jq -e \
        'all(.target_statuses[]; .status=="failed" and .result.stage=="source_sync")' "$WORK/repeated-sync-state.json"
    check 'repeated outages launch neither configured native command' test \
        "$(count "$WORK/build-commands" "$GNU")/$(count "$WORK/build-commands" "$MUSL")" = "$GNU_BEFORE/$MUSL_BEFORE"

    mv "$WORK/drop-repair" "$WORK/drop-repair.disabled" || exit 1
    : > "$WORK/change-mapping-after-sync"
    run_build repair-recovered 0 syncrepair --version 1.2.5 --jobs 2 \
        --resume="$REPAIR_RUN" --output-dir "$REPAIR_OUTPUT"
    check 'recovery completes both real GNU and musl tasks' jq -e \
        '.status=="success" and .details.success==2 and .details.failed==0' "$WORK/repair-recovered.json"
    check 'the transport actually changed host selection after syncing' test -s "$WORK/mapping-events"
    check 'current registry points to unsynced alternate after the race' test \
        "$(yq -r '.platform_mapping."linux/amd64"' "$DSR_HOSTS_FILE")" = unsyncedbox
    build_state_get syncrepair 1.2.5 "$REPAIR_RUN" > "$WORK/recovered-state.json" || true
    check 'recovery stays on source-receipt hosts despite later registry change' jq -e \
        'all(.target_statuses[]; .status=="completed" and .result.host=="repairbox")' "$WORK/recovered-state.json"
    for variant in gnu musl; do
        triple="x86_64-unknown-linux-$variant"
        jq --arg key "linux/amd64@$triple" '.target_statuses[$key].result' \
            "$WORK/recovered-state.json" > "$WORK/recovered-$variant.json"
        artifact=$(jq -r '.artifact_path // empty' "$WORK/recovered-$variant.json")
        check "recovered $variant retains exact selected target" jq -e --arg triple "$triple" \
            '.target_triple==$triple and .status=="success"' "$WORK/recovered-$variant.json"
        if [[ -n "$artifact" && -x "$artifact" ]]; then
            check "recovered $variant runs freshly synced source" test "$("$artifact")" = "NEW_SOURCE $variant"
        else
            check "recovered $variant has an executable" false
        fi
        check "recovered $variant compiles exactly once after outages" test \
            "$(count "$WORK/build-commands" "$triple")" -eq "$(( $( [[ "$variant" == gnu ]] && echo "$GNU_BEFORE" || echo "$MUSL_BEFORE" ) + 1 ))"
    done
    check 'recovery publishes final manifest only after both variants complete' test \
        -f "$REPAIR_OUTPUT/syncrepair-v1.2.5-manifest.json"
fi

# Exercise the independent local rsync branch with the same metadata trap.
mkdir -p "$WORK/local-source" "$WORK/local-copy" || exit 1
printf 'old contents\n' > "$WORK/local-copy/input"
printf 'new contents\n' > "$WORK/local-source/input"
touch -r "$WORK/local-source/input" "$WORK/local-copy/input" || exit 1
yq -i '.hosts.localcopy={"platform":"linux/amd64","connection":"local","concurrency":1}' "$DSR_HOSTS_FILE" || exit 1
STATUS=0
_act_sync_source localcopy "$WORK/local-source" "$WORK/local-copy" > "$WORK/local-sync.out" \
    2> "$WORK/local-sync.log" || STATUS=$?
check 'local source sync handles equal size/timestamp changes successfully' test "$STATUS" -eq 0
check 'local source sync actually transfers changed bytes' cmp -s "$WORK/local-source/input" "$WORK/local-copy/input"

# Malformed source receipts must be refused before any worker/capacity claim.
# These call the real orchestrator and derive adversarial receipts from the
# actual mixed-host transfer result above, not an invented success producer.
jq -c '.details' "$WORK/sync-only-syncmixed.json" > "$WORK/valid-sync.json" || exit 1
receipt_id=0
reject_receipt() {
    local label="$1" receipt="$2"; shift 2
    receipt_id=$((receipt_id + 1))
    local commands_before slots_before=0 status=0
    commands_before=$(wc -l < "$WORK/build-commands")
    [[ ! -f "$WORK/reservations.log" ]] || slots_before=$(wc -l < "$WORK/reservations.log")
    act_orchestrate_build syncmixed "2.0.$receipt_id" --source-sync-json "$receipt" \
        --output-dir "$WORK/invalid-$receipt_id" "$@" -- linux/amd64 linux/arm64 \
        > "$WORK/invalid-$receipt_id.out" 2> "$WORK/invalid-$receipt_id.log" || status=$?
    check "$label source receipt is rejected" test "$status" -eq 4
    check "$label rejection precedes any build command" test \
        "$(wc -l < "$WORK/build-commands")" -eq "$commands_before"
    if ! $REAL_CAPACITY; then
        check "$label rejection precedes the capacity boundary" test \
            "$(wc -l < "$WORK/reservations.log")" -eq "$slots_before"
    fi
}
valid=$(cat "$WORK/valid-sync.json")
reject_receipt missing-host "$(jq -c '.hosts |= .[:-1]' <<< "$valid")"
reject_receipt duplicate-host "$(jq -c '.hosts += [.hosts[0]]' <<< "$valid")"
reject_receipt extra-host "$(jq -c '.hosts += [{host:"unknownbox",path:"/not-selected",status:"failed"}] | .failed += 1' <<< "$valid")"
reject_receipt wrong-counts "$(jq -c '.synced=99' <<< "$valid")"
reject_receipt wrong-status "$(jq -c '.status="success"' <<< "$valid")"
reject_receipt mismatched-root "$(jq -c '.source_roots.healthybox += "/different"' <<< "$valid")"
reject_receipt failed-host-root "$(jq -c '.source_roots.badbox="/not-authorized"' <<< "$valid")"
reject_receipt missing-target "$(jq -c 'del(.target_hosts["linux/arm64"])' <<< "$valid")"
reject_receipt extra-target "$(jq -c '.target_hosts["darwin/amd64"]="healthybox"' <<< "$valid")"
reject_receipt multiple-documents "$valid"$'\n'"$valid"
reject_receipt conflicting-hosts "$valid" --target-hosts-json '{"linux/amd64":"badbox","linux/arm64":"badbox"}'
reject_receipt conflicting-roots "$valid" --source-roots-json '{"healthybox":"/not-the-synced-root"}'

# Ordinary builds need usable Git history as well as current worktree bytes.
# A linked controller worktree, a real sibling crate, and an unrelated dirty
# host checkout exercise this through the same public command/transport path.
mkdir -p "$WORK/git-source/src" "$WORK/gitdependency/src" || exit 1
cat > "$WORK/git-source/build.rs" <<'RUST'
use std::{env, fs::OpenOptions, io::Write, process::Command};
fn git(args: &[&str]) -> String {
    let result = Command::new("git").args(args).output().unwrap();
    assert!(result.status.success(), "Git metadata unavailable: {:?}: {}", args,
        String::from_utf8_lossy(&result.stderr));
    String::from_utf8(result.stdout).unwrap().trim().to_string()
}
fn main() {
    let mut events = OpenOptions::new().create(true).append(true)
        .open(env::var("SYNC_TEST_COMPILERS").unwrap()).unwrap();
    writeln!(events, "{}:{}", env::var("CARGO_PKG_NAME").unwrap(), env::var("TARGET").unwrap()).unwrap();
    println!("cargo:rustc-env=BUILD_GIT_SHA={}", git(&["rev-parse", "HEAD"]));
    println!("cargo:rustc-env=BUILD_GIT_DESCRIBE={}", git(&["describe", "--tags", "--always", "--dirty"]));
    println!("cargo:rustc-env=BUILD_GIT_BRANCH={}", git(&["symbolic-ref", "--short", "HEAD"]));
}
RUST
cp "$WORK/git-source/build.rs" "$WORK/gitdependency/build.rs" || exit 1
cat > "$WORK/gitdependency/Cargo.toml" <<'TOML'
[package]
name = "gitdependency"
version = "1.0.0"
edition = "2021"
TOML
cat > "$WORK/gitdependency/src/lib.rs" <<'RUST'
pub fn stamp() -> String {
    format!("{}|{}|{}|{}", env!("BUILD_GIT_SHA"), env!("BUILD_GIT_DESCRIBE"),
        env!("BUILD_GIT_BRANCH"), include_str!("message.txt").trim())
}
RUST
printf 'SIBLING_OLD\n' > "$WORK/gitdependency/src/message.txt"
git -C "$WORK/gitdependency" init -q -b main || exit 1
git -C "$WORK/gitdependency" add Cargo.toml build.rs src || exit 1
git -C "$WORK/gitdependency" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm old-sibling || exit 1
git clone -q "$WORK/gitdependency" "$WORK/hosts/gitdependency" || exit 1
printf 'SIBLING_NEW\n' > "$WORK/gitdependency/src/message.txt"
git -C "$WORK/gitdependency" add src/message.txt || exit 1
git -C "$WORK/gitdependency" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm current-sibling || exit 1
git -C "$WORK/gitdependency" -c user.name=Fixture -c user.email=fixture@example.invalid tag -a v1.1.0 -m sibling-release || exit 1
printf 'SIBLING_DIRTY\n' > "$WORK/gitdependency/src/message.txt"

cat > "$WORK/git-source/Cargo.toml" <<'TOML'
[package]
name = "gitfixture"
version = "1.0.0"
edition = "2021"
[dependencies]
gitdependency = { path = "../gitdependency" }
TOML
cat > "$WORK/git-source/src/main.rs" <<'RUST'
fn main() {
    println!("{}|{}|{}|{}|{}|{}|{}", include_str!("message.txt").trim(),
        env!("BUILD_GIT_SHA"), env!("BUILD_GIT_DESCRIBE"), env!("BUILD_GIT_BRANCH"),
        include_str!("../config.txt").trim(), include_str!("../untracked.txt").trim(),
        gitdependency::stamp());
}
RUST
printf 'OLD_SOURCE\n' > "$WORK/git-source/src/message.txt"
printf 'CLEAN_CONFIG\n' > "$WORK/git-source/config.txt"
cargo generate-lockfile --offline --manifest-path "$WORK/git-source/Cargo.toml" || exit 1
git -C "$WORK/git-source" init -q -b main || exit 1
git -C "$WORK/git-source" add Cargo.toml Cargo.lock build.rs src config.txt || exit 1
git -C "$WORK/git-source" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm git-metadata-base || exit 1
git -C "$WORK/git-source" -c user.name=Fixture -c user.email=fixture@example.invalid tag -a v3.0.0 -m main-release || exit 1
git clone -q "$WORK/git-source" "$WORK/hosts/git-stale" || exit 1
printf 'HOST_PRIVATE_EDIT\n' > "$WORK/hosts/git-stale/src/message.txt"
git -C "$WORK/hosts/git-stale" add src/message.txt || exit 1
printf 'HOST_PRIVATE_FILE\n' > "$WORK/hosts/git-stale/private.txt"
printf 'HOST_SIBLING_PRIVATE\n' > "$WORK/hosts/gitdependency/private.txt"
printf 'controller current commit\n' > "$WORK/git-source/current.txt"
git -C "$WORK/git-source" add current.txt || exit 1
git -C "$WORK/git-source" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm current-controller || exit 1
git -C "$WORK/git-source" worktree add -q --force "$WORK/controller-linked" main || exit 1
printf 'NEW_SOURCE\n' > "$WORK/controller-linked/src/message.txt"
git -C "$WORK/controller-linked" add src/message.txt || exit 1
printf 'DIRTY_CONFIG\n' > "$WORK/controller-linked/config.txt"
printf 'LOCAL_NOTE\n' > "$WORK/controller-linked/untracked.txt"
git -C "$WORK/git-source" config credential.helper 'fixture-private-do-not-copy'
printf 'private controller hook\n' > "$WORK/git-source/.git/hooks/dsr-private-fixture"

snapshot_git_tree() {
    local root="$1" index; shift
    git -C "$root" rev-parse HEAD || return 1
    git -C "$root" symbolic-ref HEAD || return 1
    index=$(git -C "$root" rev-parse --git-path index) || return 1
    [[ "$index" == /* ]] || index="$root/$index"
    _act_sha256 "$index" || return 1
    GIT_OPTIONAL_LOCKS=0 git -C "$root" status --porcelain=v1 || return 1
    local name
    for name in "$@"; do _act_sha256 "$root/$name" || return 1; done
}
GIT_SHA=$(git -C "$WORK/controller-linked" rev-parse HEAD) || exit 1
GIT_DESCRIBE=$(git -C "$WORK/controller-linked" describe --tags --always --dirty) || exit 1
GIT_BRANCH=$(git -C "$WORK/controller-linked" symbolic-ref --short HEAD) || exit 1
SIBLING_SHA=$(git -C "$WORK/gitdependency" rev-parse HEAD) || exit 1
SIBLING_DESCRIBE=$(git -C "$WORK/gitdependency" describe --tags --always --dirty) || exit 1
SIBLING_BRANCH=$(git -C "$WORK/gitdependency" symbolic-ref --short HEAD) || exit 1
EXPECTED_GIT_OUTPUT="NEW_SOURCE|$GIT_SHA|$GIT_DESCRIBE|$GIT_BRANCH|DIRTY_CONFIG|LOCAL_NOTE|$SIBLING_SHA|$SIBLING_DESCRIBE|$SIBLING_BRANCH|SIBLING_DIRTY"
# Finish fixture metadata reads before taking ownership fingerprints: Git
# describe --dirty refreshes its index even with GIT_OPTIONAL_LOCKS=0.
# Every subsequent DSR build and recovery must preserve these exact bytes.
CONTROLLER_BEFORE=$(snapshot_git_tree "$WORK/controller-linked" .git src/message.txt config.txt untracked.txt Cargo.toml) || exit 1
CONTROLLER_CONFIG=$(_act_sha256 "$WORK/git-source/.git/config") || exit 1
HOST_BEFORE=$(snapshot_git_tree "$WORK/hosts/git-stale" src/message.txt private.txt Cargo.toml) || exit 1
HOST_SIBLING_BEFORE=$(snapshot_git_tree "$WORK/hosts/gitdependency" src/message.txt private.txt Cargo.toml) || exit 1
SIBLING_BEFORE=$(snapshot_git_tree "$WORK/gitdependency" src/message.txt Cargo.toml) || exit 1
jq --arg source "$WORK/controller-linked" --arg sibling "$WORK/gitdependency" --arg work "$WORK" '
    .tool_name="gitstale" | .repo="example/gitstale" | .local_path=$source |
    .binary_name="gitfixture" | .targets=["linux/amd64"] |
    .act_job_map={"linux/amd64":null} |
    .target_triples={"linux/amd64":"x86_64-unknown-linux-gnu"} |
    .hosts={"linux/amd64":"healthybox"} |
    .host_paths={healthybox:($work+"/hosts/git-stale"),unsyncedbox:($work+"/hosts/git-fresh")} |
    .sibling_crates=[{local_path:$sibling,relative_path:"gitdependency"}] |
    .build_cmd="printf '\''gitfixture-start\\n'\'' >> \"$SYNC_TEST_COMMANDS\"; cargo build --release --locked --offline"
    ' "$ACT_REPOS_DIR/syncmixed.yaml" > "$ACT_REPOS_DIR/gitstale.yaml" || exit 1
jq '.tool_name="gitfresh" | .repo="example/gitfresh" | .hosts={"linux/amd64":"unsyncedbox"}' \
    "$ACT_REPOS_DIR/gitstale.yaml" > "$ACT_REPOS_DIR/gitfresh.yaml" || exit 1
check 'fixture preparation preserves controller and sibling ownership fingerprints' test \
    "$CONTROLLER_BEFORE/$SIBLING_BEFORE" = \
    "$(snapshot_git_tree "$WORK/controller-linked" .git src/message.txt config.txt untracked.txt Cargo.toml)/$(snapshot_git_tree "$WORK/gitdependency" src/message.txt Cargo.toml)"
for kind in stale fresh; do
    run_build "git-$kind" 0 "git$kind" --version 3.0.1 --allow-dirty --output-dir "$WORK/git-$kind-output"
    check "$kind Git build reports a fresh private source root and controller metadata" jq -e \
        --arg sha "$GIT_SHA" --arg root "$WORK/stages/" '
        .details.source_sync | .staged_ordinary==true and .git_context.git_sha==$sha and
        .git_context.git_ref=="refs/heads/main" and
        all(.hosts[]; .status=="success" and (.path | startswith($root) and endswith("/source")) and
            .git_context.git_sha==$sha and .git_context.source_root==.path)
        ' "$WORK/git-$kind.json"
    build_state_get "git$kind" 3.0.1 > "$WORK/git-$kind-state.json" || true
    git_artifact=$(jq -r '.target_statuses["linux/amd64"].result.artifact_path // empty' "$WORK/git-$kind-state.json")
    if [[ -n "$git_artifact" && -x "$git_artifact" ]]; then
        check "$kind executable embeds current Git HEAD/tag/branch and dirty main/sibling bytes" \
            test "$("$git_artifact")" = "$EXPECTED_GIT_OUTPUT"
    else
        check "$kind Git metadata build produces an executable" false
    fi
done
check 'Git imports pass through a real POSIX shell before explicit Bash' test -s "$WORK/posix-git-imports"
check 'normal fresh-host build never creates or imports into its configured checkout path' test ! -e "$WORK/hosts/git-fresh"
check 'normal builds preserve stale host HEAD/index/private files and worktree bytes' test \
    "$HOST_BEFORE" = "$(snapshot_git_tree "$WORK/hosts/git-stale" src/message.txt private.txt Cargo.toml)"
check 'normal builds preserve unrelated host sibling checkout and private files' test \
    "$HOST_SIBLING_BEFORE" = "$(snapshot_git_tree "$WORK/hosts/gitdependency" src/message.txt private.txt Cargo.toml)"
check 'normal builds preserve linked controller index/pointer/staged/unstaged/untracked bytes' test \
    "$CONTROLLER_BEFORE" = "$(snapshot_git_tree "$WORK/controller-linked" .git src/message.txt config.txt untracked.txt Cargo.toml)"
check 'normal builds preserve controller private Git configuration' test \
    "$CONTROLLER_CONFIG" = "$(_act_sha256 "$WORK/git-source/.git/config")"
check 'normal builds preserve dirty controller sibling Git state and bytes' test \
    "$SIBLING_BEFORE" = "$(snapshot_git_tree "$WORK/gitdependency" src/message.txt Cargo.toml)"

# A real bundle transfer damaged in transit must remain a source-stage error,
# with no compiler admission; repairing only that boundary permits resume.
: > "$WORK/corrupt-git-bundle"
GIT_COMMANDS_BEFORE=$(count "$WORK/build-commands" gitfixture-start)
GIT_COMPILERS_BEFORE=$(count "$WORK/compiler-events" "gitfixture:$GNU")
run_build git-corrupt 6 gitstale --version 3.0.2 --allow-dirty --output-dir "$WORK/git-corrupt-output"
check 'corruption fixture actually changes a transferred standalone Git bundle' test -s "$WORK/corrupted-bundles"
check 'failed Git import never invokes the configured native command' test \
    "$(count "$WORK/build-commands" gitfixture-start)" -eq "$GIT_COMMANDS_BEFORE"
check 'failed Git import never runs genuine Cargo build.rs' test \
    "$(count "$WORK/compiler-events" "gitfixture:$GNU")" -eq "$GIT_COMPILERS_BEFORE"
build_state_get gitstale 3.0.2 > "$WORK/git-corrupt-state.json" || true
GIT_RUN=$(jq -r '.run_id // empty' "$WORK/git-corrupt-state.json")
check 'Git import failure persists its source-stage receipt for resume' jq -e '
    .target_statuses["linux/amd64"] | .status=="failed" and .result.stage=="source_sync" and
    .result.source_sync.status=="failed" and (.result.error | length>0)
    ' "$WORK/git-corrupt-state.json"
if [[ -s "$WORK/corrupted-bundles" ]]; then
    while IFS= read -r corrupted; do
        check 'damaged bundle refuses before creating staged Git metadata' test ! -e "${corrupted%/*}/source/.git"
    done < "$WORK/corrupted-bundles"
fi
mv "$WORK/corrupt-git-bundle" "$WORK/corrupt-git-bundle.disabled" || exit 1
if [[ -n "$GIT_RUN" ]]; then
    run_build git-import-recovered 0 gitstale --version 3.0.2 --allow-dirty --resume="$GIT_RUN" --output-dir "$WORK/git-corrupt-output"
    build_state_get gitstale 3.0.2 "$GIT_RUN" > "$WORK/git-import-recovered-state.json" || true
    git_artifact=$(jq -r '.target_statuses["linux/amd64"].result.artifact_path // empty' "$WORK/git-import-recovered-state.json")
    if [[ -n "$git_artifact" && -x "$git_artifact" ]]; then
        check 'resumed Git import builds the exact current source and Git metadata' test \
            "$("$git_artifact")" = "$EXPECTED_GIT_OUTPUT"
    else
        check 'resumed Git import produces an executable' false
    fi
    check 'repaired Git import compiles exactly once after admission' test \
        "$(count "$WORK/build-commands" gitfixture-start)" -eq "$((GIT_COMMANDS_BEFORE + 1))"
    check 'repaired import uses a different private root from the refused attempt' jq -e \
        --slurpfile failed "$WORK/git-corrupt-state.json" '
        .target_statuses["linux/amd64"].result.source_sync.path !=
            $failed[0].target_statuses["linux/amd64"].result.source_sync.path
        ' "$WORK/git-import-recovered-state.json"
fi
check 'Git recovery still preserves controller state and original host checkout' test \
    "$CONTROLLER_BEFORE/$HOST_BEFORE" = \
    "$(snapshot_git_tree "$WORK/controller-linked" .git src/message.txt config.txt untracked.txt Cargo.toml)/$(snapshot_git_tree "$WORK/hosts/git-stale" src/message.txt private.txt Cargo.toml)"

test_strict_publication || exit 1
test_strict_variants || exit 1
test_strict_mixed_protocol || exit 1

printf 'Results: %s passed, %s failed; evidence %s\n' "$PASS" "$FAIL" "$WORK"
[[ "$FAIL" -eq 0 ]]
