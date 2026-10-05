#!/usr/bin/env bash
# GH #26: the config-aware resolver used by native workspace collection must
# honor exact Full/Lite names, not infer a different family after compilation.
# JSON-boundary unit tests use explicit config accessors below; the optional
# production YAML section uses the real config module and Mike Farah yq.
# No GitHub calls or release publication. All archive operations are real.
# shellcheck disable=SC2016
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
MODULE="${DSR_NAMING_TEST_MODULE:-$ROOT/src/artifact_naming.sh}"
command -v jq >/dev/null || { echo 'SKIP: jq required' >&2; exit 3; }
TEMP=$(mktemp -d) || exit 1
trap 'rm -rf -- "$TEMP"' EXIT
export DSR_CONFIG_DIR="$TEMP/config" DSR_REPOS_FILE="$TEMP/config/repos.yaml"
mkdir -p "$DSR_CONFIG_DIR/repos.d" "$TEMP/checkout" || exit 1
source "$MODULE"
PASSED=0 FAILED=0 SKIPPED=0

fixture() {
    cat > "$DSR_CONFIG_DIR/repos.d/search.yaml" <<'JSON'
{
  "tool_name": "fsfs", "binary_name": "fsfs",
  "artifact_naming": "${name}-${version}-${target_triple}.${ext}",
  "install_script_compat": "${name}-${target_triple}.${ext}",
  "release_contract": {
    "checksum_sidecar": "sha256",
    "exact_primary_assets": {
      "darwin/arm64": "fsfs-1.12.1-aarch64-apple-darwin.tar.xz",
      "darwin/amd64": "fsfs-lite-1.12.1-x86_64-apple-darwin.tar.xz",
      "linux/amd64": "fsfs-1.12.1-x86_64-unknown-linux-gnu.tar.xz",
      "linux/arm64": "fsfs-lite-1.12.1-aarch64-unknown-linux-gnu.tar.xz",
      "windows/amd64": "fsfs-1.12.1-x86_64-pc-windows-msvc.zip",
      "windows/arm64": "fsfs-1.12.1-aarch64-pc-windows-msvc.zip"
    },
    "exact_additional_assets": ["SHA256SUMS", "SHA256SUMS.minisig"],
    "minisign_public_key_file": "minisign.pub"
  }
}
JSON
    printf '{"tools":{}}\n' > "$DSR_REPOS_FILE"
}

# Explicit configuration-boundary fixture, not a fake yq executable. This
# isolates naming decisions from YAML parsing. Production-parser tests below
# run in a separate shell and do not inherit any of these functions.
config_get_release_contract_json() {
    jq -c '.release_contract' "$DSR_CONFIG_DIR/repos.d/$1.yaml"
}
config_get_tool_field() {
    jq -r --arg field "$2" --arg fallback "${3:-}" \
        '.[$field] // $fallback' "$DSR_CONFIG_DIR/repos.d/$1.yaml"
}
config_get_artifact_naming() { config_get_tool_field "$1" artifact_naming; }
config_get_install_script_compat() { config_get_tool_field "$1" install_script_compat; }
config_get_install_script_path() { printf '\n'; }
config_get_arch_alias() { printf '\n'; }
config_get_target_triple() { _an_default_target_triple "${2%/*}" "${2#*/}"; }

run_test() {
    local label="$1"
    shift
    if (fixture && "$@") > "$TEMP/test.stdout" 2> "$TEMP/test.stderr"; then
        PASSED=$((PASSED + 1))
        printf 'PASS: %s\n' "$label"
    else
        FAILED=$((FAILED + 1))
        printf 'FAIL: %s\n' "$label"
        cat "$TEMP/test.stdout" "$TEMP/test.stderr"
    fi
}

contract() { jq -c .release_contract "$DSR_CONFIG_DIR/repos.d/search.yaml"; }
expect_plan() {
    local expected="$1" target="$2" ext="$3" result
    result=$(artifact_naming_generate_dual_for_tool search v1.12.1 \
        "${target%/*}" "${target#*/}" "$ext" "$TEMP/checkout") || return 1
    jq -se --arg expected "$expected" 'length==1 and (.[0] |
        keys==["compat","same","versioned"] and .versioned==$expected and
        .compat==$expected and .same==true)' <<< "$result" >/dev/null
}

refuse() {
    local expected="$1" output status=0
    shift
    output=$("$@") || status=$?
    [[ "$status" == "$expected" && -z "$output" ]]
}

matrix() {
    local target expected ext count=0
    while IFS=$'\t' read -r target expected; do
        ext=tar.xz
        [[ "$target" != windows/* ]] || ext=zip
        expect_plan "$expected" "$target" "$ext" || return 1
        count=$((count + 1))
    done < <(contract | jq -r '.exact_primary_assets | to_entries[] | [.key,.value] | @tsv')
    [[ "$count" -eq 6 ]]
}

native_naming_call() {
    # This is the resolver invocation used by act_run_native_build, including
    # its captured stdout. No simulated compiler or artifact receipt is used.
    local platform=darwin/amd64 archive_ext=tar.xz names_json archive_name
    # shellcheck disable=SC2034 # Purpose is consumed by the called resolver.
    local build_purpose=release
    names_json=$(artifact_naming_generate_dual_for_tool search v1.12.1 \
        "${platform%/*}" "${platform#*/}" "$archive_ext" "$TEMP/checkout" 2>/dev/null || echo '')
    archive_name=$(jq -r '.versioned // empty' <<< "$names_json") || return 1
    [[ "$archive_name" == fsfs-lite-1.12.1-x86_64-apple-darwin.tar.xz ]]
}

diagnostic() {
    # shellcheck disable=SC2034 # Exercise the native caller's dynamic scope.
    local build_purpose=diagnostic-native result
    result=$(artifact_naming_generate_dual_for_tool search v1.12.1 darwin amd64 tar.xz "$TEMP/checkout") || return 1
    jq -e '.versioned=="fsfs-1.12.1-x86_64-apple-darwin.tar.xz" and
        .compat=="fsfs-x86_64-apple-darwin.tar.xz" and .same==false' <<< "$result" >/dev/null || return 1
    # An explicit standalone purpose overrides its enclosing caller's purpose.
    result=$(artifact_naming_generate_dual_for_tool search v1.12.1 darwin amd64 tar.xz "$TEMP/checkout" release) || return 1
    jq -e '.versioned=="fsfs-lite-1.12.1-x86_64-apple-darwin.tar.xz" and .same==true' <<< "$result" >/dev/null
}

explicit_diagnostic() {
    # shellcheck disable=SC2034 # Explicit argument must override this scope.
    local build_purpose=release result
    result=$(artifact_naming_generate_dual_for_tool search v1.12.1 darwin amd64 tar.xz "$TEMP/checkout" diagnostic-native) || return 1
    jq -e '.versioned=="fsfs-1.12.1-x86_64-apple-darwin.tar.xz" and .same==false' <<< "$result" >/dev/null
}

legacy() {
    local result
    jq '.release_contract=null' "$DSR_CONFIG_DIR/repos.d/search.yaml" > "$TEMP/legacy.json" || return 1
    cp "$TEMP/legacy.json" "$DSR_CONFIG_DIR/repos.d/search.yaml" || return 1
    result=$(artifact_naming_generate_dual_for_tool search v1.12.1 darwin amd64 tar.xz "$TEMP/checkout") || return 1
    jq -e '.versioned=="fsfs-1.12.1-x86_64-apple-darwin.tar.xz" and
        .compat=="fsfs-x86_64-apple-darwin.tar.xz" and .same==false' <<< "$result" >/dev/null
}

absent_config() {
    DSR_CONFIG_DIR="$TEMP/absent"
    DSR_REPOS_FILE="$TEMP/absent/repos.yaml"
    # With no repository configuration, even an unavailable YAML reader must
    # not prevent the low-level unconfigured API from producing normal names.
    config_get_release_contract_json() { return 3; }
    config_get_tool_field() { printf '%s\n' "${3:-}"; }
    local result
    result=$(artifact_naming_generate_dual_for_tool search v1.12.1 linux amd64 tar.gz) || return 1
    jq -e '.versioned=="search-1.12.1-linux-amd64.tar.gz" and
        .compat=="search-linux-amd64.tar.gz" and .same==false' <<< "$result" >/dev/null
}

parser_failure() {
    local code="$1"
    config_get_release_contract_json() { return "$code"; }
    refuse "$code" artifact_naming_generate_dual_for_tool search v1.12.1 darwin amd64 tar.xz
}

bad_contract() {
    refuse 4 _an_contract_primary_plan "$1" linux/amd64 tar.xz
}

format_plan() {
    local filename="$1" ext="$2" selected result
    selected=$(jq -nc --arg name "$filename" \
        '{checksum_sidecar:"sha256",exact_primary_assets:{"linux/amd64":$name}}') || return 1
    result=$(_an_contract_primary_plan "$selected" linux/amd64 "$ext") || return 1
    jq -e --arg name "$filename" '.versioned==$name and .compat==$name and .same==true' <<< "$result" >/dev/null
}

real_archives() {
    for tool in cc tar xz zip unzip; do command -v "$tool" >/dev/null || return 3; done
    local payload_dir="$TEMP/payload" artifacts="$TEMP/artifacts" target ext selected name before after member mode
    local -a hash_command=(sha256sum)
    command -v sha256sum >/dev/null || hash_command=(shasum -a 256)
    mkdir -p "$payload_dir" "$artifacts" || return 1
    printf 'int main(void) { return 17; }\n' > "$TEMP/app.c"
    cc "$TEMP/app.c" -o "$payload_dir/fsfs" || return 1
    chmod 751 "$payload_dir/fsfs" || return 1
    printf 'Complete license and rider\n' > "$payload_dir/LICENSE"
    before=$("${hash_command[@]}" "$payload_dir/fsfs") || return 1
    for target in linux/amd64 linux/arm64 windows/amd64; do
        ext=tar.xz
        [[ "$target" != windows/* ]] || ext=zip
        selected=$(artifact_naming_generate_dual_for_tool search v1.12.1 "${target%/*}" "${target#*/}" "$ext") || return 1
        name=$(jq -r .versioned <<< "$selected") || return 1
        if [[ "$ext" == tar.xz ]]; then
            tar -cJf "$artifacts/$name" -C "$payload_dir" fsfs LICENSE || return 1
            member=$(tar -xOJf "$artifacts/$name" fsfs | "${hash_command[@]}") || return 1
        else
            (cd "$payload_dir" && zip -q "$artifacts/$name" fsfs LICENSE) || return 1
            member=$(unzip -p "$artifacts/$name" fsfs | "${hash_command[@]}") || return 1
        fi
        [[ "${member%% *}" == "${before%% *}" ]] || return 1
    done
    [[ -f "$artifacts/fsfs-lite-1.12.1-aarch64-unknown-linux-gnu.tar.xz" ]] || return 1
    [[ -f "$artifacts/fsfs-1.12.1-x86_64-unknown-linux-gnu.tar.xz" ]] || return 1
    after=$("${hash_command[@]}" "$payload_dir/fsfs") || return 1
    mode=$(stat -c %a "$payload_dir/fsfs" 2>/dev/null) || mode=$(stat -f %Lp "$payload_dir/fsfs") || return 1
    [[ "$before" == "$after" && "$mode" == 751 ]]
    # These test archives use one local binary to check naming/byte preservation;
    # they are NOT evidence of cross compilation or target-ABI qualification.
}

run_test 'native call selects the Lite name instead of the global Full family' native_naming_call
run_test 'all six target-specific names obey the closed contract' matrix
run_test 'diagnostic purpose retains old names; explicit release overrides it' diagnostic
run_test 'explicit diagnostic purpose overrides a release caller' explicit_diagnostic
run_test 'null contract preserves configured legacy dual naming' legacy
run_test 'absent configuration does not add a YAML dependency' absent_config
run_test 'unavailable configured parser propagates dependency error without a name' parser_failure 3
run_test 'invalid configured parser result never falls back to inferred names' parser_failure 4
run_test 'invalid purpose refuses output' refuse 4 artifact_naming_generate_dual_for_tool search v1.12.1 linux amd64 tar.xz '' invalid
run_test 'missing target is not guessed from a global pattern' refuse 4 _an_contract_primary_plan "$(fixture && contract)" linux/386 tar.xz
run_test 'archive compression cannot be relabeled by exact name' refuse 4 _an_contract_primary_plan "$(contract)" darwin/amd64 zip
for pair in 'demo.tar.gz tar.gz' 'demo.tgz tgz' 'demo.tgz tar.gz' 'demo.tar.xz tar.xz' 'demo.zip zip' 'demo binary' 'demo none' 'demo.exe exe'; do
    read -r filename extension <<< "$pair"
    run_test "format-compatible exact name: $pair" format_plan "$filename" "$extension"
done
run_test 'empty extension retains raw exact name' format_plan demo ''
for invalid in 'null' '[]' '{}' 'false' 'not-json' \
    '{"checksum_sidecar":"sha256","exact_primary_assets":{}}' \
    '{"checksum_sidecar":"md5","exact_primary_assets":{"linux/amd64":"demo.tar.xz"}}' \
    '{"checksum_sidecar":"sha256","exact_primary_assets":{"linux/amd64":false}}' \
    '{"checksum_sidecar":"sha256","exact_primary_assets":{"linux/amd64":"../demo.tar.xz"}}' \
    '{"checksum_sidecar":"sha256","exact_primary_assets":{"linux/amd64":"demo.tar.xz\n"}}' \
    '{"checksum_sidecar":"sha256","exact_primary_assets":{"linux/amd64":"-demo.tar.xz"}}' \
    '{"checksum_sidecar":"sha256","exact_primary_assets":{"linux/amd64":"demo.sha256"}}' \
    '{"checksum_sidecar":"sha256","exact_primary_assets":{"linux/amd64":"demo.minisig"}}' \
    '{"checksum_sidecar":"sha256","exact_primary_assets":{"linux/amd64":"demo.tar.xz","linux/arm64":"DEMO.tar.xz"}}' \
    '{"checksum_sidecar":"sha256","exact_primary_assets":{"linux/amd64":"demo.tar.xz"},"exact_additional_assets":null}' \
    '{"checksum_sidecar":"sha256","exact_primary_assets":{"linux/amd64":"demo.tar.xz"},"exact_additional_assets":["demo.tar.xz.sha256"]}' \
    '{"checksum_sidecar":"sha256","exact_primary_assets":{"linux/amd64":"demo.tar.xz"},"minisign_public_key_file":"release.pub","exact_additional_assets":["demo.tar.xz.minisig"]}' \
    $'{"checksum_sidecar":"sha256","exact_primary_assets":{"linux/amd64":"demo.tar.xz"}}\n{}'; do
    run_test "invalid contract refuses a naming plan: $invalid" bad_contract "$invalid"
done
run_test 'real tar.xz/ZIP construction uses exact names without changing binary bytes' real_archives

# Exercise the production YAML parser and its document/alias/precedence rules
# when installed. Missing dependencies are not converted into a green test.
if command -v yq >/dev/null && [[ -f "$ROOT/src/config.sh" ]]; then
    run_test 'production config parser selects exact names from YAML aliases and rejects duplicate keys' \
        bash -c '
            source "$1/src/config.sh" || exit 1
            source "$2" || exit 1
            cat > "$DSR_CONFIG_DIR/repos.d/search.yaml" <<YAML
common: &primaries
  linux/amd64: fsfs-lite-linux.tar.xz
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets: *primaries
YAML
            value=$(artifact_naming_generate_dual_for_tool search v1.12.1 linux amd64 tar.xz) || exit 1
            jq -e '\''.versioned=="fsfs-lite-linux.tar.xz" and .same==true'\'' <<< "$value" >/dev/null || exit 1
            printf "release_contract: null\nrelease_contract: {}\n" > "$DSR_CONFIG_DIR/repos.d/search.yaml"
            code=0
            value=$(artifact_naming_generate_dual_for_tool search v1.12.1 linux amd64 tar.xz) || code=$?
            [[ $code -eq 4 && -z "$value" ]]
        ' _ "$ROOT" "$MODULE"
else
    printf 'SKIP: production YAML integration requires Mike Farah yq v4 and src/config.sh\n'
    SKIPPED=$((SKIPPED + 1))
    if [[ "${DSR_TEST_REQUIRE_YQ:-0}" == 1 ]]; then FAILED=$((FAILED + 1)); fi
fi
printf '\nExact release naming: %s passed, %s failed, %s skipped\n' "$PASSED" "$FAILED" "$SKIPPED"
[[ $FAILED -eq 0 ]]
