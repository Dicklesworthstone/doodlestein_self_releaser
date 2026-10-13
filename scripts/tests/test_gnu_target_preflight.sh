#!/usr/bin/env bash
# GH #37: refuse floor-qualified compiler targets at the configuration gate,
# not after an expensive native build. Uses the actual config module/validators.
# Default: real yq YAML parsing. --json-fixtures explicitly replaces only the
# unavailable yq/parser boundary with jq on JSON (a YAML subset); it is NOT a
# yq interoperability test or a native compiler/CLI end-to-end test.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
MODULE=${DSR_TEST_CONFIG_MODULE:-$ROOT/src/config.sh}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/dsr-gnu-preflight.XXXXXXXX") || exit 1
printf 'GNU target preflight evidence retained in %s\n' "$WORK" >&2
source "$MODULE" || exit 3
if [[ "${1:-}" == --json-fixtures ]]; then
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

case_check() {
    local label="$1" config="$2" expected="$3" where="${4:-file}" registry="${5:-}"
    local rc=0 hint="${6:-linux_glibc_floor}" case_dir
    [[ -n "$registry" ]] || registry='{"tools":{}}'
    checks=$((checks+1)); case_dir="$WORK/$checks"
    mkdir -p "$case_dir/config/repos.d" || exit 1
    export DSR_CONFIG_DIR="$case_dir/config" DSR_REPOS_FILE="$case_dir/config/repos.yaml"
    export DSR_HOSTS_FILE="$case_dir/no-hosts.yaml" DSR_STATE_DIR="$case_dir/no-state" DSR_CACHE_DIR="$case_dir/no-cache"
    if [[ "$where" == registry ]]; then
        jq -cn --argjson config "$config" '{tools:{example:$config}}' > "$DSR_REPOS_FILE" || exit 1
    else
        printf '%s\n' "$config" > "$DSR_CONFIG_DIR/repos.d/example.yaml"
        printf '%s\n' "$registry" > "$DSR_REPOS_FILE"
    fi
    if [[ "$where" == global ]]; then
        DSR_CONFIG[schema_version]=1.0.0
        config_validate > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    else
        config_validate_release_contract example > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    fi
    if [[ "$rc" == "$expected" && ! -s "$case_dir/stdout" &&
          ! -e "$DSR_STATE_DIR" && ! -e "$DSR_CACHE_DIR" && ! -e "$WORK/executed" ]] &&
       ! grep -F 'DO_NOT_LOG_THIS' "$case_dir/stderr" >/dev/null &&
       { [[ "$expected" == 0 ]] || grep -F -- "$hint" "$case_dir/stderr" >/dev/null; }; then
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

command_case 'issue 37 exact x86_64 selector is refused before building' "cargo zigbuild --release --target $BAD" 4
command_case 'issue 37 aarch64 equals selector is refused' "cargo zigbuild --release --target=$ARM" 4
command_case 'quoted target flag and value are refused' "cargo +nightly zigbuild '--target' '$BAD'" 4
command_case 'quoted whole equals argument is refused' "cargo zigbuild '--target=$BAD'" 4
command_case 'double-quoted equals value is refused' "cargo zigbuild --target=\"$BAD\"" 4
command_case 'line continuation does not conceal the selector' $'cargo zigbuild --target \\\n'"$BAD" 4
command_case 'concatenated quote fragments retain one literal word' "cargo zigbuild --target '$GOOD.'2.28" 4
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
command_case 'refusal does not execute surrounding commands' 'touch '"$WORK"'/executed; cargo zigbuild --target='"$BAD" 4
command_case 'diagnostics identify the field without exposing command secrets' "GITHUB_TOKEN=DO_NOT_LOG_THIS cargo zigbuild --target $BAD" 4

case_check 'global CARGO_BUILD_TARGET cannot carry the floor' "$(jq -c --arg bad "$BAD" '.env.CARGO_BUILD_TARGET=$bad' <<< "$BASE")" 4
case_check 'global DSR_TARGET_TRIPLE cannot carry the floor' "$(jq -c --arg bad "$BAD" '.env.DSR_TARGET_TRIPLE=$bad' <<< "$BASE")" 4
case_check 'an unrelated environment value is not a selector' "$(jq -c --arg bad "$BAD" '.env.DIAGNOSTIC=$bad' <<< "$BASE")" 0
case_check 'scalar target identity cannot carry the floor' "$(jq -c --arg bad "$BAD" '.target_triples["linux/amd64"]=$bad' <<< "$BASE")" 4
case_check 'secondary matrix target identity cannot carry the floor' "$(jq -c --arg bad "$BAD" '.target_triples["linux/amd64"] += [$bad]' <<< "$(jq -c '.target_triples["linux/amd64"]=[.target_triples["linux/amd64"]]' <<< "$BASE")")" 4
case_check 'cross-compilation command override is checked' "$(jq -c --arg bad "$ARM" '.cross_compile["linux/arm64"].build_cmd=("cargo zigbuild --target "+$bad)' <<< "$BASE")" 4
case_check 'cross-compilation environment override is checked' "$(jq -c --arg bad "$ARM" '.cross_compile["linux/arm64"].env.CARGO_BUILD_TARGET=$bad' <<< "$BASE")" 4
case_check 'cross-compilation target identity is checked' "$(jq -c --arg bad "$ARM" '.cross_compile["linux/arm64"].target=$bad' <<< "$BASE")" 4
case_check 'absent target mapping cannot bypass command validation' "$(jq -c --arg bad "$BAD" 'del(.target_triples)|.build_cmd=("cargo zigbuild --target "+$bad)' <<< "$BASE")" 4
case_check 'null target mapping cannot bypass command validation' "$(jq -c --arg bad "$BAD" '.target_triples=null|.build_cmd=("cargo zigbuild --target "+$bad)' <<< "$BASE")" 4
case_check 'registry-only build selector is checked' "$(jq -c --arg bad "$BAD" '.build_cmd=("cargo zigbuild --target "+$bad)' <<< "$BASE")" 4 registry
case_check 'per-tool build authority does not inherit obsolete registry command' "$BASE" 0 file "$(jq -cn --arg bad "$BAD" '{tools:{example:{build_cmd:("cargo zigbuild --target "+$bad)}}}')"
case_check 'unrelated registry tool does not block this build' "$BASE" 0 file "$(jq -cn --arg bad "$BAD" '{tools:{other:{build_cmd:("cargo zigbuild --target "+$bad)}}}')"
case_check 'effective target mapping fallback is still checked' "$(jq -c 'del(.target_triples)' <<< "$BASE")" 4 file "$(jq -cn --arg bad "$BAD" '{tools:{example:{target_triples:{"linux/amd64":$bad}}}}')"
case_check 'whole-configuration validation refuses the unsafe build' "$(jq -c --arg bad "$BAD" '.build_cmd=("cargo zigbuild --target "+$bad)' <<< "$BASE")" 4 global
case_check 'non-build documentation fields are not scanned' "$(jq -c --arg bad "$BAD" '.description=("cargo --target "+$bad)' <<< "$BASE")" 0
STRICT=$(jq -c '.release_contract={checksum_sidecar:"sha256",exact_primary_assets:{"linux/amd64":"example-linux.tar.gz"}}' <<< "$BASE")
case_check 'strict release contract with supported target is still admitted' "$STRICT" 0
case_check 'strict release also refuses the unsupported selector' "$(jq -c --arg bad "$BAD" '.build_cmd=("cargo zigbuild --target "+$bad)' <<< "$STRICT")" 4
case_check 'malformed literal target command cannot look like no problem' "$(jq -c --arg command "cargo zigbuild --target '$BAD" '.build_cmd=$command' <<< "$BASE")" 4 file '{"tools":{}}' 'malformed literal target command'
case_check 'existing duplicate-variant refusal remains intact' "$(jq -c '.target_triples["linux/amd64"]=[.target_triples["linux/amd64"],.target_triples["linux/amd64"]]' <<< "$BASE")" 4 file '{"tools":{}}' 'Invalid target_triples'
case_check 'existing invalid fallback refusal remains intact' "$(jq -c '.linux_libc_fallback=false' <<< "$BASE")" 4 file '{"tools":{}}' 'Invalid linux_libc_fallback'
case_check 'large unrelated evidence never travels through argv' "$(jq -c '.env.BUILD_EVIDENCE=("evidence"*50000)' <<< "$BASE")" 0

printf '%s checks, %s failures\n' "$checks" "$failures"
((failures == 0))
