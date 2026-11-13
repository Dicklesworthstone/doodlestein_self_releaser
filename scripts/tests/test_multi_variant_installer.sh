#!/usr/bin/env bash
# Real GNU/musl Rust executables through the generated installer. Only libc
# discovery and release transports are fixtures; cache and verification are real.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work=$(mktemp -d "${TMPDIR:-/tmp}/dsr-libc-installer.XXXXXXXX") || exit 1
printf 'Evidence: %s\n' "$work"
passed=0 failed=0
check() {
    local label="$1"; shift
    if "$@"; then passed=$((passed + 1)); printf 'ok - %s\n' "$label"
    else failed=$((failed + 1)); printf 'not ok - %s\n' "$label"; fi
}
for tool in rustc jq yq tar xz zip unzip sha256sum; do
    if ! command -v "$tool" >/dev/null; then printf 'SKIP: required tool %s unavailable\n' "$tool"; exit 0; fi
done
if [[ $(uname -s) != Linux || $(uname -m) != x86_64 ]]; then
    printf 'SKIP: real GNU/musl fixture requires Linux x86_64\n'; exit 0
fi
musl_libdir=$(rustc --print target-libdir --target x86_64-unknown-linux-musl) || exit 1
if ! compgen -G "$musl_libdir/libstd-*.rlib" >/dev/null; then
    printf 'SKIP: x86_64-unknown-linux-musl Rust standard library unavailable\n'; exit 0
fi
mkdir -p "$work/config/repos.d" "$work/home" "$work/remote" "$work/transports" "$work/payload-gnu" "$work/payload-musl"
# Preserve the compiler installation when isolating the installer's home.
# Otherwise rustup looks for a new default toolchain in the empty fixture HOME.
export RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
export HOME="$work/home" DSR_CONFIG_DIR="$work/config" DSR_INSTALLER_DIR="$work/generated" NO_COLOR=1
export REMOTE="$work/remote" CALLS="$work/calls" MOCK_LIBC=gnu WITHHELD_TRIPLE=''
cat > "$work/demo.rs" <<'RUST'
fn main() {
    println!("demo 1.2.3 {}", if cfg!(target_env = "musl") { "musl" } else { "gnu" });
}
RUST
for libc in gnu musl; do
    rustc --edition=2021 --target "x86_64-unknown-linux-$libc" "$work/demo.rs" \
        -o "$work/payload-$libc/demo" || exit 1
    asset="demo-1.2.3-x86_64-unknown-linux-$libc.tar.gz"
    tar -czf "$REMOTE/$asset" -C "$work/payload-$libc" demo || exit 1
    digest=$(sha256sum < "$REMOTE/$asset"); digest="${digest%% *}"
    printf '%s  %s\n' "$digest" "$asset" > "$REMOTE/$asset.sha256"
done
check 'real GNU fixture executes' test "$("$work/payload-gnu/demo")" = 'demo 1.2.3 gnu'
check 'real musl fixture executes' test "$("$work/payload-musl/demo")" = 'demo 1.2.3 musl'

cat > "$work/config/repos.d/demo.yaml" <<'YAML'
tool_name: demo
repo: example/demo
binary_name: demo
language: rust
build_cmd: cargo build --release
targets: [linux/amd64]
target_triples:
  linux/amd64: [x86_64-unknown-linux-musl, x86_64-unknown-linux-gnu]
artifact_naming: ${name}-${version}-${target_triple}.${ext}
install_script_compat: ${name}-${target_triple}.${ext}
YAML
# shellcheck source=../../src/config.sh
source "$ROOT/src/config.sh"
# shellcheck source=../../src/install_gen.sh
source "${DSR_INSTALL_GEN_MODULE:-$ROOT/src/install_gen.sh}"
check 'ordered config triples remain ordered' test \
    "$(config_get_target_triples_json demo linux/amd64)" = '["x86_64-unknown-linux-musl","x86_64-unknown-linux-gnu"]'
check 'scalar accessor retains the configured primary' test \
    "$(config_get_target_triple demo linux/amd64)" = x86_64-unknown-linux-musl
installer=$(install_gen_create demo 2> "$work/generate.log") || exit 1
check 'generated variant installer parses' bash -n "$installer"

cat > "$work/transports/ldd" <<'SH'
#!/usr/bin/env bash
case "$MOCK_LIBC" in
    gnu) printf 'ldd (GNU libc) 2.36\n' ;;
    musl) printf 'musl libc (x86_64)\nVersion 1.2.5\n' >&2; exit 1 ;;
    *) exit 1 ;;
esac
SH
cat > "$work/transports/getconf" <<'SH'
#!/usr/bin/env bash
exit 1
SH
cat > "$work/transports/curl" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
url='' dest='' write_out='' config_stdin=false
while (($#)); do
    case "$1" in
        -o|--output) dest="$2"; shift 2 ;;
        --proto|--proto-redir|--connect-timeout|--max-time|--retry|--max-redirs) shift 2 ;;
        -w|--write-out) write_out="$2"; shift 2 ;;
        --config) [[ "$2" != - ]] || config_stdin=true; shift 2 ;;
        https:*) url="$1"; shift ;;
        *) shift ;;
    esac
done
if $config_stdin; then
    while IFS= read -r line; do
        if [[ "$line" == 'url = "'*'"' ]]; then
            url="${line#'url = "'}"; url="${url%'"'}"
            url="${url//\\\"/\"}"; url="${url//\\\\/\\}"
        fi
    done
fi
printf 'curl %s\n' "$url" >> "$CALLS"
missing() {
    if [[ "$write_out" == *http_code* ]]; then printf '404\n'; return 0; fi
    return 22
}
name="${url##*/}"
[[ -n "$dest" ]] || exit 2
[[ -z "$WITHHELD_TRIPLE" || "$name" != *"linux-$WITHHELD_TRIPLE"* ]] || { missing; exit $?; }
[[ -f "$REMOTE/$name" ]] || { missing; exit $?; }
cp "$REMOTE/$name" "$dest" || exit 23
[[ "$write_out" != *http_code* ]] || printf '200\n'
SH
cat > "$work/transports/gh" <<'SH'
#!/usr/bin/env bash
printf 'gh unavailable\n' >> "$CALLS"
exit 1
SH
chmod +x "$work/transports/ldd" "$work/transports/getconf" "$work/transports/curl" "$work/transports/gh"
export PATH="$work/transports:$PATH"
case_id=0 case_dir='' cache="$work/cache" status=0
run_install() {
    case_id=$((case_id + 1)); case_dir="$work/case-$case_id"
    mkdir "$case_dir"
    status=0
    bash "$installer" --version v1.2.3 --dir "$case_dir/bin" --cache-dir "$cache" \
        --non-interactive --json --no-skills "$@" > "$case_dir/out" 2> "$case_dir/err" || status=$?
}
installed() {
    [[ $status -eq 0 && -x "$case_dir/bin/demo" ]] &&
        [[ $("$case_dir/bin/demo") == "demo 1.2.3 $1" ]] &&
        jq -e '.status == "success"' "$case_dir/out" >/dev/null
}
blocked() { [[ $status -ne 0 && ! -e "$case_dir/bin/demo" ]]; }
MOCK_LIBC=gnu run_install
check 'GNU host selects GNU although musl is listed first' installed gnu
MOCK_LIBC=musl run_install
check 'nonzero stderr musl ldd selects musl' installed musl
gnu_cache="$cache/demo/example/demo/v1.2.3/linux-amd64-x86_64-unknown-linux-gnu/tar.gz/demo-1.2.3-x86_64-unknown-linux-gnu.tar.gz/payload"
musl_cache="$cache/demo/example/demo/v1.2.3/linux-amd64-x86_64-unknown-linux-musl/tar.gz/demo-1.2.3-x86_64-unknown-linux-musl.tar.gz/payload"
check 'GNU cached under selected full triple' cmp -s "$gnu_cache" "$REMOTE/demo-1.2.3-x86_64-unknown-linux-gnu.tar.gz"
check 'musl cached independently under its full triple' cmp -s "$musl_cache" "$REMOTE/demo-1.2.3-x86_64-unknown-linux-musl.tar.gz"
before=$(wc -l < "$CALLS")
MOCK_LIBC=gnu run_install --offline
check 'GNU offline cache preserves its compiled variant' installed gnu
MOCK_LIBC=musl run_install --offline
check 'musl offline cache preserves its compiled variant' installed musl
MOCK_LIBC=gnu run_install --offline --libc musl
check 'explicit --libc musl keeps its own verified cache on GNU' installed musl
MOCK_LIBC=unknown run_install --offline --libc gnu
check 'explicit --libc gnu works when detection is unavailable' installed gnu
check 'all four offline installs perform zero transports' test "$(wc -l < "$CALLS")" -eq "$before"
printf 'corruption\n' >> "$gnu_cache"
MOCK_LIBC=gnu run_install --offline
check 'corrupt GNU cache refuses installation' blocked
MOCK_LIBC=musl run_install --offline
check 'GNU corruption does not poison the musl cache' installed musl

cache="$work/legacy-cache"
mkdir -p "$cache/demo/v1.2.3"
cp "$REMOTE/demo-1.2.3-x86_64-unknown-linux-gnu.tar.gz" "$cache/demo/v1.2.3/linux-amd64.tar.gz"
digest=$(sha256sum < "$cache/demo/v1.2.3/linux-amd64.tar.gz"); digest="${digest%% *}"
printf '%s\n' "$digest" > "$cache/demo/v1.2.3/linux-amd64.tar.gz.sha256"
before=$(wc -l < "$CALLS")
MOCK_LIBC=musl run_install --offline
check 'variant installer never adopts legacy platform cache with raw digest' blocked
check 'legacy cache refusal remains offline' test "$(wc -l < "$CALLS")" -eq "$before"
cache="$work/no-fallback-cache"
MOCK_LIBC=gnu WITHHELD_TRIPLE=gnu run_install
check 'missing GNU payload does not silently fall back to musl' blocked
before=$(wc -l < "$CALLS")
MOCK_LIBC=unknown run_install
check 'unknown libc refuses instead of guessing first listed triple' blocked
check 'unknown libc refusal precedes every transport' test "$(wc -l < "$CALLS")" -eq "$before"

printf 'linux_libc_fallback: musl\n' >> "$work/config/repos.d/demo.yaml"
_IG_OUTPUT_DIR="$work/generated-fallback"
installer=$(install_gen_create demo 2> "$work/generate-fallback.log") || exit 1
cache="$work/explicit-fallback-cache"
MOCK_LIBC=gnu WITHHELD_TRIPLE=gnu run_install
check 'explicit GNU-to-musl availability fallback installs actual musl executable' installed musl
check 'fallback cache uses the selected musl identity' cmp -s \
    "$cache/demo/example/demo/v1.2.3/linux-amd64-x86_64-unknown-linux-musl/tar.gz/demo-1.2.3-x86_64-unknown-linux-musl.tar.gz/payload" "$REMOTE/demo-1.2.3-x86_64-unknown-linux-musl.tar.gz"
before=$(wc -l < "$CALLS")
MOCK_LIBC=gnu run_install --offline
check 'explicit fallback can reuse its own verified musl cache offline' installed musl
check 'offline fallback performs zero transports' test "$(wc -l < "$CALLS")" -eq "$before"
cache="$work/musl-never-gnu"
MOCK_LIBC=musl WITHHELD_TRIPLE=musl run_install
check 'musl host never falls back to a GNU executable' blocked
cache="$work/exact-request"
MOCK_LIBC=gnu WITHHELD_TRIPLE=gnu run_install --libc gnu
check 'explicit --libc request remains exact even when fallback policy allows musl' blocked

sidecar="$REMOTE/demo-1.2.3-x86_64-unknown-linux-gnu.tar.gz.sha256"
cp "$sidecar" "$work/gnu-sidecar.before"
printf '%064d  demo-1.2.3-x86_64-unknown-linux-gnu.tar.gz\n' 0 > "$sidecar"
cache="$work/integrity-never-fallback"
before=$(wc -l < "$CALLS")
MOCK_LIBC=gnu run_install
check 'GNU checksum failure never becomes a successful musl fallback' blocked
tail -n "+$((before + 1))" "$CALLS" > "$work/integrity-calls"
check 'integrity failure requests no musl payload' bash -c '! grep -q linux-musl "$1"' _ "$work/integrity-calls"
cp "$work/gnu-sidecar.before" "$sidecar"

valid=$(yq -o=json '.' "$work/config/repos.d/demo.yaml") || exit 1
invalid_id=0
while IFS= read -r invalid; do
    invalid_id=$((invalid_id + 1))
    printf '%s\n' "$invalid" > "$work/config/repos.d/invalid-$invalid_id.yaml"
    status=0
    config_validate_target_triples "invalid-$invalid_id" > "$work/invalid.out" 2>> "$work/invalid.err" || status=$?
    check 'malformed triple list or unsafe fallback policy is refused' test "$status" -eq 4
    status=0
    install_gen_create "invalid-$invalid_id" > "$work/invalid-installer.out" 2>> "$work/invalid-installer.err" || status=$?
    check 'installer generator applies the same validation' test "$status" -eq 4
done < <(jq -cn --argjson valid "$valid" '
    ($valid | .target_triples["linux/amd64"] = []),
    ($valid | .target_triples["linux/amd64"] = ["x86_64-unknown-linux-gnu", "x86_64-unknown-linux-gnu"]),
    ($valid | .target_triples = false),
    ($valid | .linux_libc_fallback = false),
    ($valid | .linux_libc_fallback = null),
    ($valid | .linux_libc_fallback = "gnu")
')

# A checksum proves bytes, not libc compatibility. A scalar GNU-only release
# cannot satisfy an explicit or detected musl request by installing GNU anyway.
jq -n --argjson valid "$valid" '$valid | .target_triples["linux/amd64"] = "x86_64-unknown-linux-gnu"' \
    > "$work/config/repos.d/gnu-only.yaml"
_IG_OUTPUT_DIR="$work/generated-gnu-only"
installer=$(install_gen_create gnu-only 2> "$work/generate-gnu-only.log") || exit 1
cache="$work/gnu-only"
before=$(wc -l < "$CALLS")
MOCK_LIBC=musl run_install
check 'detected musl cannot select the GNU-only primary' blocked
MOCK_LIBC=gnu run_install --libc musl
check 'explicit musl cannot silently install the GNU-only primary' blocked
check 'unavailable libc requests make no transport calls' test "$(wc -l < "$CALLS")" -eq "$before"

# Workflow-owned shared aliases cannot represent two different ABIs. A
# nonprimary request must still fail before fetching the primary's bytes.
jq -n --argjson valid "$valid" '$valid |
    .artifact_naming = "${name}-${version}-${os}-${arch}.${ext}" |
    .act_job_map = {"linux/amd64":"release"}' \
    > "$work/config/repos.d/shared.yaml"
cp "$REMOTE/demo-1.2.3-x86_64-unknown-linux-musl.tar.gz" "$REMOTE/demo-1.2.3-linux-amd64.tar.gz"
digest=$(sha256sum < "$REMOTE/demo-1.2.3-linux-amd64.tar.gz"); digest="${digest%% *}"
printf '%s  demo-1.2.3-linux-amd64.tar.gz\n' "$digest" > "$REMOTE/demo-1.2.3-linux-amd64.tar.gz.sha256"
_IG_OUTPUT_DIR="$work/generated-shared"
installer=$(install_gen_create shared 2> "$work/generate-shared.log") || exit 1
cache="$work/shared"
MOCK_LIBC=musl run_install
check 'generic shared asset name remains installable as the configured primary' installed musl
before=$(wc -l < "$CALLS")
MOCK_LIBC=gnu run_install
check 'nonprimary GNU cannot download musl bytes through a shared alias' blocked
check 'shared-alias mismatch is refused before transport or cache adoption' test "$(wc -l < "$CALLS")" -eq "$before"

# Native cmd_build already publishes colliding secondary names with the full
# compiler triple. Exercise those production names and archives with the real
# executables above, not a second copy of the producer's suffix algorithm.
native_name() {
    bash -c 'source "$1/src/config.sh" && source "$1/src/act_runner.sh" &&
        _act_native_variant_artifact_name "$2" linux/amd64 "$3" "$4"' \
        _ "$ROOT" "$@"
}
native_route() {
    bash -c 'source "$1/src/act_runner.sh" && ! act_platform_uses_act "$2" linux/amd64' \
        _ "$ROOT" "$1"
}
# shellcheck source=../../src/packaging.sh
source "$ROOT/src/packaging.sh"
REMOTE="$work/native-remote"
mkdir "$REMOTE" || exit 1
native_base=$(jq -cn --argjson valid "$valid" '$valid |
    .artifact_naming = "${name}-${version}-${os}-${arch}.${ext}" |
    .act_job_map = {"linux/amd64":null}') || exit 1
native_archive_installer='' native_archive_name='' native_case=0
for native_format in tar.gz tgz tar.xz zip none; do
    native_case=$((native_case + 1))
    native_tool="native-$native_case"
    native_config="$work/config/repos.d/$native_tool.yaml"
    jq -n --argjson base "$native_base" --arg format "$native_format" \
        '$base | .archive_format = (if $format == "none" then "binary" else $format end)' \
        > "$native_config" || exit 1
    primary_name=demo-1.2.3-linux-amd64
    [[ "$native_format" == none ]] || primary_name+=".$native_format"
    qualified_name=$(native_name "$native_tool" x86_64-unknown-linux-gnu "$primary_name") || exit 1
    check "$native_format producer qualifies the secondary separately from the shared primary" \
        test "$qualified_name" != "$primary_name"
    if [[ "$native_format" == none ]]; then
        cp "$work/payload-musl/demo" "$REMOTE/$primary_name" || exit 1
        cp "$work/payload-gnu/demo" "$REMOTE/$qualified_name" || exit 1
    else
        packaging_build_archive "$native_format" "$REMOTE/$primary_name" "$work/payload-musl" demo || exit 1
        packaging_build_archive "$native_format" "$REMOTE/$qualified_name" "$work/payload-gnu" demo || exit 1
    fi
    for name in "$primary_name" "$qualified_name"; do
        digest=$(sha256sum < "$REMOTE/$name"); digest="${digest%% *}"
        printf '%s  %s\n' "$digest" "$name" > "$REMOTE/$name.sha256"
    done
    _IG_OUTPUT_DIR="$work/generated-$native_tool"
    installer=$(install_gen_create "$native_tool" 2> "$work/generate-$native_tool.log") || exit 1
    [[ "$native_format" != tar.gz ]] || {
        native_archive_installer="$installer"
        native_archive_name="$qualified_name"
    }
    cache="$work/cache-$native_tool"
    before=$(wc -l < "$CALLS")
    MOCK_LIBC=gnu run_install
    check "$native_format secondary install consumes the native producer's real GNU payload" installed gnu
    check "$native_format secondary installed bytes match the compiled GNU executable" \
        cmp -s "$case_dir/bin/demo" "$work/payload-gnu/demo"
    tail -n "+$((before + 1))" "$CALLS" > "$work/$native_tool-calls"
    check "$native_format secondary requests its exact production asset name" grep -Fxq \
        "curl https://github.com/example/demo/releases/download/v1.2.3/$qualified_name" "$work/$native_tool-calls"
    check "$native_format secondary never acquires the primary's shared alias" \
        bash -c '! grep -Fxq "$1" "$2"' _ \
        "curl https://github.com/example/demo/releases/download/v1.2.3/$primary_name" "$work/$native_tool-calls"
    MOCK_LIBC=musl run_install
    check "$native_format configured primary still installs from its shared name" installed musl
    before=$(wc -l < "$CALLS")
    MOCK_LIBC=gnu run_install --offline
    check "$native_format secondary reuses only its own verified offline cache" installed gnu
    check "$native_format secondary cache use is offline" test "$(wc -l < "$CALLS")" -eq "$before"
done

# Freeze the same native routing as the build for every supported spelling,
# including a mapping whose only jobs are for another platform or a default
# key (the actual producer does not use such a key as a platform fallback).
routing_case=0
while IFS= read -r routed_config; do
    routing_case=$((routing_case + 1))
    native_tool="native-routing-$routing_case"
    printf '%s\n' "$routed_config" > "$work/config/repos.d/$native_tool.yaml"
    check "native routing spelling $routing_case agrees with the real build selector" native_route "$native_tool"
    _IG_OUTPUT_DIR="$work/generated-$native_tool"
    installer=$(install_gen_create "$native_tool" 2> "$work/generate-$native_tool.log") || exit 1
    cache="$work/cache-$native_tool"
    MOCK_LIBC=gnu run_install --libc gnu
    check "native routing spelling $routing_case installs the qualified secondary" installed gnu
done < <(jq -cn --argjson base "$native_base" '
    ($base | del(.act_job_map)),
    ($base | .act_job_map = null),
    ($base | .act_job_map = {}),
    ($base | .act_job_map = {"linux/amd64":""}),
    ($base | .act_job_map = {"linux/amd64":"null", "linux/arm64":"release-arm"}),
    ($base | .act_job_map = {"default":"release", "linux/arm64":"release-arm"})
')

installer="$native_archive_installer"
cache="$work/native-acquisition-fallback"
MOCK_LIBC=gnu WITHHELD_TRIPLE=gnu run_install
check 'missing qualified GNU asset permits only the configured availability fallback to musl' installed musl
cache="$work/native-exact-gnu"
before=$(wc -l < "$CALLS")
MOCK_LIBC=gnu WITHHELD_TRIPLE=gnu run_install --libc gnu
check 'explicit native GNU request cannot adopt the primary musl alias' blocked
tail -n "+$((before + 1))" "$CALLS" > "$work/native-exact-calls"
check 'explicit native selection never requests the other ABI shared asset' \
    bash -c '! grep -Fq demo-1.2.3-linux-amd64.tar.gz "$1"' _ "$work/native-exact-calls"

cp "$REMOTE/$native_archive_name.sha256" "$work/native-checksum.before" || exit 1
printf '%064d  %s\n' 0 "$native_archive_name" > "$REMOTE/$native_archive_name.sha256"
cache="$work/native-integrity-refusal"
before=$(wc -l < "$CALLS")
MOCK_LIBC=gnu run_install
check 'qualified native payload checksum failure is terminal' blocked
tail -n "+$((before + 1))" "$CALLS" > "$work/native-integrity-calls"
check 'qualified native integrity refusal cannot fall back to a different ABI' \
    bash -c '! grep -Fq demo-1.2.3-linux-amd64.tar.gz "$1"' _ "$work/native-integrity-calls"

# The usual GNU-first matrix must also preserve its primary alias and give
# musl its own native-produced name, including an explicitly supplied archive.
native_tool=native-gnu-primary
jq -n --argjson base "$native_base" '$base |
    .target_triples["linux/amd64"] |= reverse' \
    > "$work/config/repos.d/$native_tool.yaml" || exit 1
REMOTE="$work/gnu-primary-remote"
mkdir "$REMOTE" || exit 1
primary_name=demo-1.2.3-linux-amd64.tar.gz
qualified_name=$(native_name "$native_tool" x86_64-unknown-linux-musl "$primary_name") || exit 1
packaging_build_archive tar.gz "$REMOTE/$primary_name" "$work/payload-gnu" demo || exit 1
packaging_build_archive tar.gz "$REMOTE/$qualified_name" "$work/payload-musl" demo || exit 1
for name in "$primary_name" "$qualified_name"; do
    digest=$(sha256sum < "$REMOTE/$name"); digest="${digest%% *}"
    printf '%s  %s\n' "$digest" "$name" > "$REMOTE/$name.sha256"
done
_IG_OUTPUT_DIR="$work/generated-$native_tool"
installer=$(install_gen_create "$native_tool" 2> "$work/generate-$native_tool.log") || exit 1
cache="$work/cache-$native_tool"
MOCK_LIBC=gnu run_install
check 'GNU-first native matrix keeps the GNU payload under its primary alias' installed gnu
MOCK_LIBC=musl run_install
check 'GNU-first native matrix selects the real qualified musl payload' installed musl
check 'GNU-first secondary installed bytes match the compiled musl executable' \
    cmp -s "$case_dir/bin/demo" "$work/payload-musl/demo"
before=$(wc -l < "$CALLS")
MOCK_LIBC=gnu run_install --libc musl --offline "$REMOTE/$qualified_name"
check 'explicit offline native archive uses its own selected musl identity' installed musl
check 'explicit native archive installation performs no transports' test "$(wc -l < "$CALLS")" -eq "$before"

routing_case=0
while IFS= read -r invalid_routing; do
    routing_case=$((routing_case + 1))
    native_tool="native-invalid-$routing_case"
    printf '%s\n' "$invalid_routing" > "$work/config/repos.d/$native_tool.yaml"
    _IG_OUTPUT_DIR="$work/generated-$native_tool"
    status=0
    install_gen_create "$native_tool" > "$work/$native_tool.out" 2> "$work/$native_tool.err" || status=$?
    check 'malformed producer routing cannot grant native name qualification' test "$status" -eq 4
    check 'malformed producer routing writes no generated installer' test ! -e "$_IG_OUTPUT_DIR"
done < <(jq -cn --argjson base "$native_base" '
    ($base | .act_job_map = false),
    ($base | .act_job_map = []),
    ($base | .act_job_map["linux/amd64"] = false),
    ($base | .act_job_map["linux/amd64"] = ["release"]),
    ($base | .act_job_map["linux/amd64"] = "release\nother")
')

printf '\nGNU/musl generated installer: %s passed, %s failed\nEvidence retained: %s\n' "$passed" "$failed" "$work"
[[ $failed -eq 0 ]]
