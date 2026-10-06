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
for tool in rustc jq yq tar sha256sum; do
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
source "$ROOT/src/install_gen.sh"
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
url='' dest=''
while (($#)); do
    case "$1" in
        -o|--output) dest="$2"; shift 2 ;;
        --proto|--proto-redir|--connect-timeout|--max-time|--retry|--max-redirs|-w) shift 2 ;;
        https:*) url="$1"; shift ;;
        *) shift ;;
    esac
done
printf 'curl %s\n' "$url" >> "$CALLS"
name="${url##*/}"
[[ -z "$WITHHELD_TRIPLE" || "$name" != *"linux-$WITHHELD_TRIPLE"* ]] || exit 22
[[ -n "$dest" && -f "$REMOTE/$name" ]] || exit 22
cp "$REMOTE/$name" "$dest"
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
gnu_cache="$cache/demo/v1.2.3/linux-amd64-x86_64-unknown-linux-gnu.tar.gz"
musl_cache="$cache/demo/v1.2.3/linux-amd64-x86_64-unknown-linux-musl.tar.gz"
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
    "$cache/demo/v1.2.3/linux-amd64-x86_64-unknown-linux-musl.tar.gz" "$REMOTE/demo-1.2.3-x86_64-unknown-linux-musl.tar.gz"
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

# Shared aliases remain supported for the primary, but cannot represent two
# different ABIs. A nonprimary request must fail before fetching primary bytes.
jq -n --argjson valid "$valid" '$valid | .artifact_naming = "${name}-${version}-${os}-${arch}.${ext}"' \
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

printf '\nGNU/musl generated installer: %s passed, %s failed\nEvidence retained: %s\n' "$passed" "$failed" "$work"
[[ $failed -eq 0 ]]
