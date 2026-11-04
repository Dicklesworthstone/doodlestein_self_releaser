#!/usr/bin/env bash
# GH #37/#53: distinguish an explicit, attested cargo-zigbuild ABI request from
# a Rust target identity at the public configuration gate. Uses the actual
# config and native command parsers, never a compiler or receipt stand-in.
# Default: real yq YAML parsing. --json-fixtures explicitly replaces only the
# unavailable yq/parser boundary with jq on JSON (a YAML subset); it is NOT a
# yq interoperability test or a native compiler/CLI end-to-end test.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
MODULE=${DSR_TEST_CONFIG_MODULE:-$ROOT/src/config.sh}
PROJECT=${DSR_TEST_CONFIG_PROJECT:-${MODULE%/src/config.sh}}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/dsr-gnu-preflight.XXXXXXXX") || exit 1
printf 'GNU target preflight evidence retained in %s\n' "$WORK" >&2
# shellcheck source=src/config.sh
source "$MODULE" || exit 3
json_fixtures=false
if [[ "${1:-}" == --json-fixtures ]]; then
    json_fixtures=true
    printf '%s\n' 'JSON-only parser fixtures selected; native yq integration is not exercised.' >&2
    _config_read_single_mapping_json() {
        jq -ces 'if length==1 and (.[0]|type=="object") then .[0] else error("invalid mapping") end' "$1" || return 4
    }
    yq() {
        [[ "$1" == -o=json ]] || return 99
        case "$2" in
            .target_triples) jq -c '.target_triples' "$3" ;;
            '.tools[strenv(DSR_TOOL)].target_triples')
                jq -c --arg tool "$DSR_TOOL" '.tools[$tool].target_triples' "$3" ;;
            *) printf 'Unsupported test parser query: %s\n' "$2" >&2; return 99 ;;
        esac
    }
    export -f yq _config_read_single_mapping_json
elif [[ $# -gt 0 ]] || ! command -v yq >/dev/null; then
    printf '%s\n' 'Usage: test_gnu_target_preflight.sh [--json-fixtures]; default requires Mike Farah yq.' >&2
    exit 3
fi
checks=0 failures=0
BASE='{"tool_name":"example","repo":"owner/example","language":"rust","targets":["linux/amd64"],"target_triples":{"linux/amd64":"x86_64-unknown-linux-gnu"},"linux_glibc_floor":"2.28","build_cmd":"cargo build --release --target x86_64-unknown-linux-gnu"}'
GOOD=x86_64-unknown-linux-gnu
BAD=$GOOD.2.28
ARM=aarch64-unknown-linux-gnu.2.28

write_yaml() {
    if $json_fixtures; then cat; else yq -P; fi
}

case_check() {
    local label="$1" config="$2" expected="$3" where="${4:-file}" registry="${5:-}"
    local rc=0 hint="${6:-linux_glibc_floor}" case_dir output_ok=false
    [[ -n "$registry" ]] || registry='{"tools":{}}'
    checks=$((checks+1)); case_dir="$WORK/$checks"
    mkdir -p "$case_dir/config/repos.d" || exit 1
    export DSR_CONFIG_DIR="$case_dir/config" DSR_REPOS_FILE="$case_dir/config/repos.yaml"
    export DSR_HOSTS_FILE="$case_dir/no-hosts.yaml" DSR_STATE_DIR="$case_dir/no-state" DSR_CACHE_DIR="$case_dir/no-cache"
    if [[ "$where" == registry ]]; then
        jq -cn --argjson config "$config" '{tools:{example:$config}}' | write_yaml > "$DSR_REPOS_FILE" || exit 1
    else
        printf '%s\n' "$config" | write_yaml > "$DSR_CONFIG_DIR/repos.d/example.yaml" || exit 1
        printf '%s\n' "$registry" | write_yaml > "$DSR_REPOS_FILE" || exit 1
    fi
    printf 'schema_version: "1.0.0"\n' > "$DSR_CONFIG_DIR/config.yaml"
    export DSR_CONFIG_FILE="$DSR_CONFIG_DIR/config.yaml"
    if [[ "$where" == global ]]; then
        DSR_CONFIG[schema_version]=1.0.0
        config_validate > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    elif [[ "$where" == public-config ]]; then
        bash "$PROJECT/dsr" --json --dry-run config validate > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
        if jq -e --argjson code "$expected" '.command == "config" and .exit_code == $code and
            .details.valid == ($code == 0)' "$case_dir/stdout" >/dev/null; then output_ok=true; fi
    elif [[ "$where" == public-build ]]; then
        bash "$PROJECT/dsr" --json --dry-run build example --version 1.0.0 \
            > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
        if [[ "$expected" == 0 ]] && jq -e '.command == "build" and .exit_code == 0 and
            .details.mode == "dry_run" and .details.publishable == true' "$case_dir/stdout" >/dev/null; then output_ok=true; fi
    elif [[ "$where" == exported || "$where" == private-parser ]]; then
        mkdir "$case_dir/cwd" || exit 1
        export DSR_TEST_GNU_EXECUTION_MARKER="$WORK/executed"
        printf '%s\n' 'printf poisoned > "$DSR_TEST_GNU_EXECUTION_MARKER"; exit 99' > "$case_dir/cwd/act_runner.sh"
        printf '%s\n' 'printf poisoned > "$DSR_TEST_GNU_EXECUTION_MARKER"; exit 99' > "$case_dir/shell-startup"
        (
            cd "$case_dir/cwd" || exit 1
            if [[ "$where" == exported ]]; then
                # Forward its actual private YAML/logging dependencies too;
                # this is function transport, never a substitute validator.
                export -f _config_read_single_mapping_json _cfg_log_error
                bash -c 'config_validate_gnu_target_suffixes example'
            else
                # A caller cannot replace the native selection helper or run
                # a startup hook inside configuration's private parser shell.
                _act_explicit_zigbuild_selection() { printf poisoned > "$DSR_TEST_GNU_EXECUTION_MARKER"; return 99; }
                export -f _act_explicit_zigbuild_selection
                export BASH_ENV="$case_dir/shell-startup" ENV="$case_dir/shell-startup"
                config_validate_release_contract example
            fi
        ) > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    else
        config_validate_release_contract example > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    fi
    if [[ "$where" != public-config && ( "$where" != public-build || "$expected" != 0 ) &&
          ! -s "$case_dir/stdout" ]]; then output_ok=true; fi
    if [[ "$rc" == "$expected" && "$output_ok" == true &&
          ! -e "$DSR_STATE_DIR" && ! -e "$DSR_CACHE_DIR" && ! -e "$WORK/executed" ]] &&
       ! grep -F 'DO_NOT_LOG_THIS' "$case_dir/stderr" >/dev/null &&
       { [[ "$expected" == 0 || "$where" == public-config ]] || grep -F -- "$hint" "$case_dir/stderr" >/dev/null; }; then
        printf 'ok %s - %s\n' "$checks" "$label"
    else
        printf 'not ok %s - %s (expected %s, received %s)\n' "$checks" "$label" "$expected" "$rc"
        cat "$case_dir/stderr"; failures=$((failures+1))
    fi
}
command_case() {
    local label="$1" command="$2" expected="$3"
    case_check "$label" "$(jq -c --arg command "$command" '.build_cmd=$command' <<< "$BASE")" "$expected"
}

command_case 'explicit x86_64 Zig request is admitted without changing its Rust identity' "cargo zigbuild --release --target $BAD" 0
case_check 'explicit aarch64 equals request is admitted' "$(jq -c --arg arm "$ARM" '.targets=["linux/arm64"]|.target_triples={"linux/arm64":"aarch64-unknown-linux-gnu"}|.build_cmd=("cargo zigbuild --release --target="+$arm)' <<< "$BASE")" 0
command_case 'quoted target flag and value preserve explicit toolchain selection' "cargo +nightly zigbuild '--target' '$BAD'" 0
command_case 'quoted whole equals argument is admitted' "cargo zigbuild '--target=$BAD'" 0
command_case 'double-quoted equals value is admitted' "cargo zigbuild --target=\"$BAD\"" 0
command_case 'line continuation preserves the literal selector' $'cargo zigbuild --target \\\n'"$BAD" 0
command_case 'concatenated quote fragments cannot bypass native parser limitations' "cargo zigbuild --target '$GOOD.'2.28" 4
command_case 'later repeated target is still inspected' "cargo zigbuild --target $GOOD --target $BAD" 4
command_case 'command-scoped Cargo target assignment is refused' "CARGO_BUILD_TARGET='$BAD' cargo build --release" 4
command_case 'command-scoped DSR target assignment is refused' "env DSR_TARGET_TRIPLE=$ARM cargo build --release" 4
command_case 'plain cargo build with separately configured floor remains valid' "cargo build --release --target $GOOD" 0
command_case 'plain quoted target remains valid' "cargo build --target=\"$GOOD\" --release" 0
command_case 'quoted diagnostic is not interpreted as a target command' "printf '%s\\n' 'cargo zigbuild --target $BAD'; cargo build --target $GOOD" 0
command_case 'commented target is not a command selector' $'# cargo zigbuild --target '"$BAD"$'\ncargo build --release' 0
command_case 'inline shell comment is ignored' "cargo build --release # --target $BAD" 0
command_case 'lookalike option name is not a target selector' "cargo build --target-directory $BAD" 0
command_case 'archive and path spellings are not compiler targets' "cargo build --target $GOOD > /tmp/$BAD.log" 0
command_case 'other ABI and operating-system targets are unchanged' 'cargo build --target x86_64-unknown-linux-musl; cargo build --target aarch64-apple-darwin' 0
command_case 'substitutions are never executed by validation' 'cargo build --target x86_64-unknown-linux-gnu; echo "$(touch '"$WORK"'/executed)"' 0
command_case 'admission never executes surrounding commands' 'touch '"$WORK"'/executed; cargo zigbuild --target='"$BAD" 0
command_case 'diagnostics identify the field without exposing command secrets' "GITHUB_TOKEN=DO_NOT_LOG_THIS cargo build --target $BAD" 4

case_check 'global CARGO_BUILD_TARGET cannot carry the floor' "$(jq -c --arg bad "$BAD" '.env.CARGO_BUILD_TARGET=$bad' <<< "$BASE")" 4
case_check 'global DSR_TARGET_TRIPLE cannot carry the floor' "$(jq -c --arg bad "$BAD" '.env.DSR_TARGET_TRIPLE=$bad' <<< "$BASE")" 4
case_check 'an unrelated environment value is not a selector' "$(jq -c --arg bad "$BAD" '.env.DIAGNOSTIC=$bad' <<< "$BASE")" 0
case_check 'scalar target identity cannot carry the floor' "$(jq -c --arg bad "$BAD" '.target_triples["linux/amd64"]=$bad' <<< "$BASE")" 4
case_check 'secondary matrix target identity cannot carry the floor' "$(jq -c --arg bad "$BAD" '.target_triples["linux/amd64"] += [$bad]' <<< "$(jq -c '.target_triples["linux/amd64"]=[.target_triples["linux/amd64"]]' <<< "$BASE")")" 4
case_check 'cross-compilation command override uses the same explicit selection parser' "$(jq -c --arg bad "$ARM" '.cross_compile["linux/arm64"].build_cmd=("cargo zigbuild --target "+$bad)' <<< "$BASE")" 0
case_check 'cross-compilation environment override is checked' "$(jq -c --arg bad "$ARM" '.cross_compile["linux/arm64"].env.CARGO_BUILD_TARGET=$bad' <<< "$BASE")" 4
case_check 'cross-compilation target identity is checked' "$(jq -c --arg bad "$ARM" '.cross_compile["linux/arm64"].target=$bad' <<< "$BASE")" 4
case_check 'absent target mapping permits separately attested explicit selection' "$(jq -c --arg bad "$BAD" 'del(.target_triples)|.build_cmd=("cargo zigbuild --target "+$bad)' <<< "$BASE")" 0
case_check 'null target mapping permits separately attested explicit selection' "$(jq -c --arg bad "$BAD" '.target_triples=null|.build_cmd=("cargo zigbuild --target "+$bad)' <<< "$BASE")" 0
case_check 'registry-only build uses the same explicit selection parser' "$(jq -c --arg bad "$BAD" '.build_cmd=("cargo zigbuild --target "+$bad)' <<< "$BASE")" 0 registry
case_check 'per-tool build authority does not inherit obsolete registry command' "$BASE" 0 file "$(jq -cn --arg bad "$BAD" '{tools:{example:{build_cmd:("cargo zigbuild --target "+$bad)}}}')"
case_check 'unrelated registry tool does not block this build' "$BASE" 0 file "$(jq -cn --arg bad "$BAD" '{tools:{other:{build_cmd:("cargo zigbuild --target "+$bad)}}}')"
case_check 'effective target mapping fallback is still checked' "$(jq -c 'del(.target_triples)' <<< "$BASE")" 4 file "$(jq -cn --arg bad "$BAD" '{tools:{example:{target_triples:{"linux/amd64":$bad}}}}')"
case_check 'whole-configuration validation admits the explicit Zig request' "$(jq -c --arg bad "$BAD" '.build_cmd=("cargo zigbuild --target "+$bad)' <<< "$BASE")" 0 global
case_check 'non-build documentation fields are not scanned' "$(jq -c --arg bad "$BAD" '.description=("cargo --target "+$bad)' <<< "$BASE")" 0
STRICT=$(jq -c '.release_contract={checksum_sidecar:"sha256",exact_primary_assets:{"linux/amd64":"example-linux.tar.gz"}}' <<< "$BASE")
case_check 'strict release contract with supported target is still admitted' "$STRICT" 0
case_check 'strict release admits the explicit request with canonical asset identity' "$(jq -c --arg bad "$BAD" '.build_cmd=("cargo zigbuild --target "+$bad)' <<< "$STRICT")" 0
case_check 'malformed literal target command cannot look like no problem' "$(jq -c --arg command "cargo zigbuild --target '$BAD" '.build_cmd=$command' <<< "$BASE")" 4 file '{"tools":{}}' 'malformed literal target command'
case_check 'existing duplicate-variant refusal remains intact' "$(jq -c '.target_triples["linux/amd64"]=[.target_triples["linux/amd64"],.target_triples["linux/amd64"]]' <<< "$BASE")" 4 file '{"tools":{}}' 'Invalid target_triples'
case_check 'existing invalid fallback refusal remains intact' "$(jq -c '.linux_libc_fallback=false' <<< "$BASE")" 4 file '{"tools":{}}' 'Invalid linux_libc_fallback'
case_check 'large unrelated evidence never travels through argv' "$(jq -c '.env.BUILD_EVIDENCE=("evidence"*50000)' <<< "$BASE")" 0

# The old blanket refusal becomes an exact capability gate. The worker parser
# itself decides which Cargo invocations can share the same receipt; these
# controls prevent a string containing "zigbuild" from granting admission.
command_case 'ordinary Cargo cannot consume a Zig-qualified target' "cargo build --target $BAD" 4
command_case 'cargo rustc cannot consume a Zig-qualified target' "cargo rustc --target $BAD" 4
command_case 'matching compound Zig invocations share one explicit selection' "cargo zigbuild --target $BAD && cargo zigbuild --target=$BAD" 0
command_case 'compound Zig invocations with different floors are refused' "cargo zigbuild --target $BAD && cargo zigbuild --target $GOOD.2.27" 4
command_case 'compound Zig invocations with different canonical targets are refused' "cargo zigbuild --target $BAD && cargo zigbuild --target $ARM" 4
command_case 'compound Zig invocations with different toolchains are refused' "cargo +nightly zigbuild --target $BAD && cargo +stable zigbuild --target $BAD" 4
command_case 'changing influential command environment is refused' "RUSTFLAGS=-Cdebuginfo=0 cargo zigbuild --target $BAD && RUSTFLAGS=-Cdebuginfo=1 cargo zigbuild --target $BAD" 4
command_case 'reviewed Cargo global flags and command prefix remain valid' "command -- cargo +nightly --quiet --locked zigbuild --target=$BAD" 0
command_case 'opaque env options cannot conceal the Cargo invocation' "env -u RUSTUP_TOOLCHAIN cargo zigbuild --target $BAD" 4
command_case 'shell wrapper cannot claim a direct Cargo invocation' "bash -c cargo zigbuild --target $BAD" 4
command_case 'background Zig invocations cannot share a bounded final receipt' "cargo zigbuild --target $BAD & wait" 4
command_case 'malformed GNU floor with a third component is refused' "cargo zigbuild --target $BAD.1" 4
command_case 'malformed GNU floor without a minor version is refused' "cargo zigbuild --target $GOOD.2" 4
command_case 'empty GNU floor is refused' "cargo zigbuild --target $GOOD." 4
command_case 'unreviewed GNU ABI suffix is refused' 'cargo zigbuild --target armv7-unknown-linux-gnueabihf.2.28' 4
command_case 'stricter requested ABI is independent of the collected ELF ceiling' "cargo zigbuild --target $GOOD.2.17" 0
EXPLICIT=$(jq -c --arg bad "$BAD" '.build_cmd=("cargo zigbuild --target "+$bad)' <<< "$BASE")
case_check 'large unrelated evidence also stays out of explicit selection transport' "$(jq -c '.env.BUILD_EVIDENCE=("evidence"*50000)' <<< "$EXPLICIT")" 0
case_check 'configured higher ELF ceiling does not rewrite the explicit Zig request' "$(jq -c '.linux_glibc_floor="2.39"' <<< "$EXPLICIT")" 0
case_check 'per-platform overrides preserve their distinct explicit requests' "$(jq -c --arg bad "$BAD" --arg arm "$ARM" '.targets=["linux/amd64","linux/arm64"]|.target_triples["linux/arm64"]="aarch64-unknown-linux-gnu"|.cross_compile["linux/amd64"].build_cmd=("cargo zigbuild --target "+$bad)|.cross_compile["linux/arm64"].build_cmd=("cargo zigbuild --target "+$arm)' <<< "$BASE")" 0
OVERRIDDEN=$(jq -c --arg bad "$BAD" --arg arm "$ARM" '.targets=["linux/amd64","linux/arm64"]|.target_triples["linux/arm64"]="aarch64-unknown-linux-gnu"|.build_cmd=("cargo zigbuild --target "+$bad+" && cargo zigbuild --target "+$arm)|.cross_compile["linux/amd64"].build_cmd=("cargo zigbuild --target "+$bad)|.cross_compile["linux/arm64"].build_cmd=("cargo zigbuild --target "+$arm)' <<< "$BASE")
case_check 'fully explicit matrix does not validate an inactive global recipe' "$OVERRIDDEN" 0
case_check 'partially overridden matrix still validates its active global recipe' "$(jq -c 'del(.cross_compile["linux/arm64"].build_cmd)' <<< "$OVERRIDDEN")" 4
case_check 'exported GNU validator loads the original parser instead of caller cwd' "$EXPLICIT" 0 exported
case_check 'private parser refuses inherited helper and shell-startup substitution' "$EXPLICIT" 0 private-parser

if ! $json_fixtures; then
    # These are actual CLI/config entry points with real YAML and a tagged Git
    # source. --dry-run bounds them before host staging or compilation; the
    # separate genuine native integration test covers execution and receipts.
    mkdir -p "$WORK/source/src" || exit 1
    printf '[package]\nname="example"\nversion="1.0.0"\nedition="2021"\n' > "$WORK/source/Cargo.toml"
    printf 'version = 3\n[[package]]\nname="example"\nversion="1.0.0"\n' > "$WORK/source/Cargo.lock"
    printf 'fn main() {}\n' > "$WORK/source/src/main.rs"
    git init -q "$WORK/source" && git -C "$WORK/source" add . &&
        git -C "$WORK/source" -c user.name='DSR Fixture' -c user.email=dsr-fixture@example.invalid \
            -c commit.gpgsign=false commit -qm fixture && git -C "$WORK/source" tag v1.0.0 || exit 1
    PUBLIC=$(jq -c --arg source "$WORK/source" '.local_path=$source' <<< "$EXPLICIT")
    case_check 'public config validate admits the supported explicit floor' "$PUBLIC" 0 public-config
    case_check 'public build reaches its plan with the supported explicit floor' "$PUBLIC" 0 public-build
    case_check 'public config validate still refuses qualified target identities' "$(jq -c --arg bad "$BAD" '.env.CARGO_BUILD_TARGET=$bad' <<< "$PUBLIC")" 4 public-config
    case_check 'public build rejects conflicting requests before any build side effect' "$(jq -c '.build_cmd += " && cargo zigbuild --target x86_64-unknown-linux-gnu.2.27"' <<< "$PUBLIC")" 4 public-build
else
    printf '%s\n' 'Public CLI/YAML cases require the default real-yq mode; not executed in JSON-fixture mode.' >&2
fi

printf '%s checks, %s failures\n' "$checks" "$failures"
((failures == 0))
