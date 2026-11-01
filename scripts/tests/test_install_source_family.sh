#!/usr/bin/env bash
# Real locked offline Rust workspace builds through the installer source engine.
# Only Git's HTTPS transport is redirected to a local committed repository.
# The optional Bun contract mode substitutes the compiler boundary only; it is
# not evidence of native Bun compilation (the generated installer suite is).
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
case "$#:${1:-}" in
    0:|1:--bun-contracts-only) ;;
    *) printf 'Usage: %s [--bun-contracts-only]\n' "$0" >&2; exit 4 ;;
esac

test_bun_family_contracts() (
    for dependency in jq ps; do
        command -v "$dependency" >/dev/null 2>&1 || {
            printf 'SKIP: Bun compiler-boundary contracts require %s\n' "$dependency"; return 0;
        }
    done
    if ! declare -F _isb_compile >/dev/null; then
        # shellcheck source=../../src/install_source.sh
        source "$ROOT/src/install_source.sh"
    fi
    local fixtures good=0 bad=0 result fault
    fixtures=$(mktemp -d "${TMPDIR:-/tmp}/dsr-bun-family-contracts.XXXXXXXX") || return 1
    printf 'Bun compiler-boundary fixtures: %s\n' "$fixtures"
    contract_check() {
        local label="$1"; shift
        if "$@"; then good=$((good + 1)); printf 'PASS: %s\n' "$label"
        else bad=$((bad + 1)); printf 'FAIL: %s\n' "$label" >&2; fi
    }
    contract_equal() { [[ "$1" == "$2" ]]; }
    contract_case() (
        local fault="$1" base="$fixtures/$1" output code=0
        local -a selected=(fixture helper compiler.log)
        mkdir -p "$base/tree/src" "$base/output" || return 1
        printf '%s\n' '{"bin":{"fixture":"src/decoy.ts","helper":"src/helper.ts","compiler.log":"src/log.ts"}}' \
            > "$base/tree/package.json"
        for entry in primary helper log decoy; do
            printf 'console.log("%s");\n' "$entry" > "$base/tree/src/$entry.ts"
        done
        printf '{}\n' > "$base/tree/bun.lock"
        case "$fault" in
            ok) selected=(helper fixture compiler.log) ;;
            missing) printf '%s\n' '{"bin":{"fixture":"src/decoy.ts","compiler.log":"src/log.ts"}}' > "$base/tree/package.json" ;;
            scalar) printf '%s\n' '{"bin":"src/primary.ts"}' > "$base/tree/package.json" ;;
            unsafe) printf '%s\n' '{"bin":{"helper":"../outside.ts","compiler.log":"src/log.ts"}}' > "$base/tree/package.json" ;;
            input-link) ln -s primary.ts "$base/tree/src/linked.ts" || return 1
                printf '%s\n' '{"bin":{"helper":"src/linked.ts","compiler.log":"src/log.ts"}}' > "$base/tree/package.json" ;;
        esac
        bun() {
            printf '%s\n' "$*" >> "$base/bun.calls"
            case "$1" in
                --version) printf 'bun-contract-version\n' ;;
                install) [[ "$fault" != dependency ]] ;;
                build)
                    local target='' entry=''
                    shift
                    while (($#)); do
                        case "$1" in
                            --outfile) target="$2"; shift 2 ;;
                            --compile) shift ;;
                            *) entry="$1"; shift ;;
                        esac
                    done
                    [[ "$target" == "$base/output/bin/"* ]] || return 1
                    if [[ "${target##*/}" == helper ]]; then
                        case "$fault" in
                            compile) return 9 ;;
                            absent) return 0 ;;
                            empty) : > "$target"; return $? ;;
                            output-link) ln -s "$base/tree/src/helper.ts" "$target"; return $? ;;
                        esac
                    fi
                    printf '%s\n' "$entry" > "$target"
                    ;;
                *) return 1 ;;
            esac
        }
        output=$(_isb_compile bun "$base/tree" "$base/output" fixture src/primary.ts '' 5 "${selected[@]}") || code=$?
        printf '%s:%s\n' "$code" "$output"
    )
    result=$(contract_case ok)
    contract_check 'Bun family boundary returns every selected member in the requested order' contract_equal "$result" \
        "$(printf '0:%s/output/bin/helper\n%s/output/bin/fixture\n%s/output/bin/compiler.log' "$fixtures/ok" "$fixtures/ok" "$fixtures/ok")"
    contract_check 'Bun family uses the explicit primary entry even when primary is not first' \
        grep -qx './src/primary.ts' "$fixtures/ok/output/bin/fixture"
    contract_check 'Bun companion retains its own package bin mapping' \
        grep -qx './src/helper.ts' "$fixtures/ok/output/bin/helper"
    contract_check 'Bun diagnostic-shaped executable retains its own entry' \
        grep -qx './src/log.ts' "$fixtures/ok/output/bin/compiler.log"
    contract_check 'Bun executable cannot overwrite retained compiler identity' \
        grep -qx bun-contract-version "$fixtures/ok/output/compiler.log"
    contract_check 'Bun family installs locked dependencies exactly once' contract_equal \
        "$(grep -c '^install --frozen-lockfile$' "$fixtures/ok/bun.calls")" 1
    contract_check 'Bun family invokes one standalone compile per member' contract_equal \
        "$(grep -c '^build --compile ' "$fixtures/ok/bun.calls")" 3
    for fault in missing scalar unsafe input-link; do
        result=$(contract_case "$fault" 2> "$fixtures/$fault.log")
        contract_check "Bun $fault companion rejects the entire family" contract_equal "$result" '4:'
        contract_check "Bun $fault companion fails before compiler or dependency execution" \
            test ! -e "$fixtures/$fault/bun.calls"
    done
    for fault in dependency compile absent empty output-link; do
        result=$(contract_case "$fault" 2> "$fixtures/$fault.log")
        contract_check "Bun $fault failure returns no partial family" contract_equal "$result" '6:'
    done
    contract_check 'Bun dependency failure does not run a compiler' contract_equal \
        "$(grep -c '^build ' "$fixtures/dependency/bun.calls")" 0
    contract_check 'Bun later compiler failure occurs after a successful first member' \
        test -s "$fixtures/compile/output/bin/fixture"
    contract_check 'Bun later compiler failure never attempts the final member' contract_equal \
        "$(grep -c '^build ' "$fixtures/compile/bun.calls")" 2
    printf 'Bun family compiler-boundary contracts: %s passed, %s failed\n' "$good" "$bad"
    [[ $bad -eq 0 ]]
)

if [[ "${1:-}" == --bun-contracts-only ]]; then
    test_bun_family_contracts
    exit $?
fi

for dependency in git jq cargo rustc ps; do
    command -v "$dependency" >/dev/null 2>&1 || {
        printf 'SKIP: source family integration requires %s\n' "$dependency"
        exit 0
    }
done
# shellcheck source=../../src/install_source.sh
source "$ROOT/src/install_source.sh"
# This fixture uses anonymous Git URL policy; authenticated HTTPS has its own
# real transport coverage in test_install_source.sh --credentials-only.
export DSR_GH_TOKEN='' GITHUB_TOKEN='' GH_TOKEN=''
gh() { return 1; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/dsr-source-family.XXXXXXXX") || exit 1
printf 'Fixtures: %s\n' "$WORK"
# Some hosted environments expose host PIDs to ps but namespace PIDs to Bash.
# Only bypass the unsupported watchdog boundary there; checkout, compiler argv,
# actual Cargo/rustc processes, source validation and receipts remain genuine.
watchdog_status=0
_isb_run 3 "$WORK/watchdog-probe.log" printf 'watchdog-ready\n' \
    > "$WORK/watchdog-probe.out" 2> "$WORK/watchdog-probe.err" || watchdog_status=$?
if ((watchdog_status != 0)); then
    namespace_pid="$BASHPID" host_pid='' namespace_line='' observed_pid=''
    if [[ -r /proc/self/stat && -r /proc/self/status ]]; then
        read -r host_pid _ < /proc/self/stat
        while IFS= read -r line; do
            [[ "$line" != NSpid:* ]] || namespace_line="${line#NSpid:}"
        done < /proc/self/status
        observed_pid=$(ps -o pid= -p "$namespace_pid" 2> "$WORK/namespace-probe.err" || true)
        observed_pid="${observed_pid//[[:space:]]/}"
    fi
    read -r -a namespace_pids <<< "$namespace_line"
    if [[ $watchdog_status -ne 3 || -e "$WORK/watchdog-probe.log" ||
          ${#namespace_pids[@]} -lt 2 || "$host_pid" == "$namespace_pid" ||
          "${namespace_pids[0]:-}" != "$host_pid" ||
          "${namespace_pids[${#namespace_pids[@]}-1]:-}" != "$namespace_pid" ||
          "$observed_pid" == "$namespace_pid" ]]; then
        printf 'FAIL: watchdog probe failed without independent PID namespace evidence (status %s)\n' "$watchdog_status" >&2
        cat "$WORK/watchdog-probe.err" >&2
        exit 1
    fi
    printf 'BOUNDARY: hosted PID namespace cannot run the watchdog; real commands run synchronously with retained logs\n'
    _isb_run() {
        local limit="$1" log="$2"
        shift 2
        [[ "$limit" =~ ^[1-9][0-9]{0,4}$ && ! -e "$log" && ! -L "$log" ]] || return 4
        "$@" </dev/null > "$log" 2>&1
    }
fi
mkdir -p "$WORK/cache" "$WORK/results" "$WORK/upstream/src" \
    "$WORK/upstream/helper/src" "$WORK/upstream/worker/src" || exit 1
export CARGO_HOME="$WORK/cache" CARGO_NET_OFFLINE=true
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$WORK/gitconfig"
export RUSTUP_AUTO_INSTALL=0 RCH_DISABLED=1 RCH_CARGO_WRAPPER_BYPASS=1
PASS=0 FAIL=0 STATUS=0
check() {
    local label="$1"; shift
    if "$@"; then PASS=$((PASS + 1)); printf 'PASS: %s\n' "$label"
    else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$label" >&2; fi
}
equal() { [[ "$1" == "$2" ]]; }
run_build() {
    local name="$1"; shift
    STATUS=0
    install_source_build example/source-family "$@" \
        > "$WORK/results/$name.json" 2> "$WORK/results/$name.log" || STATUS=$?
}
reject_family() {
    local name="$1" label="$2"; shift 2
    run_build "$name" refs/tags/v1.0.0 rust family "$WORK/$name" --allow-build "$@"
    check "$label" equal "$STATUS" 4
    check "$label before fetch" test ! -e "$WORK/$name"
}
reject_windows_family() {
    local name="$1" label="$2" code=0; shift 2
    # A platform-policy probe only: no Windows compiler/filesystem execution
    # is claimed. Refusal must happen before even creating a checkout.
    (
        uname() { printf 'MINGW64_NT-policy-probe\n'; }
        install_source_build example/source-family refs/tags/v1.0.0 rust family \
            "$WORK/$name" --allow-build "$@"
    ) > "$WORK/results/$name.json" 2> "$WORK/results/$name.log" || code=$?
    check "$label (Windows policy only)" equal "$code" 4
    check "$label before fetch" test ! -e "$WORK/$name"
}

cat > "$WORK/upstream/Cargo.toml" <<'TOML'
[package]
name = "family-package"
version = "1.0.0"
edition = "2021"
[workspace]
members = ["helper", "worker"]
default-members = ["."]
resolver = "2"
[[bin]]
name = "family"
path = "src/main.rs"
[[bin]]
name = "family-local"
path = "src/local.rs"
[[bin]]
name = "FAMILY"
path = "src/upper.rs"
[[bin]]
name = "family.exe"
path = "src/exe.rs"
TOML
printf 'fn main() { println!("family-tag-v1"); }\n' > "$WORK/upstream/src/main.rs"
printf 'fn main() { println!("local-tag-v1"); }\n' > "$WORK/upstream/src/local.rs"
printf 'fn main() { println!("uppercase-tag-v1"); }\n' > "$WORK/upstream/src/upper.rs"
printf 'fn main() { println!("literal-exe-tag-v1"); }\n' > "$WORK/upstream/src/exe.rs"
cat > "$WORK/upstream/helper/Cargo.toml" <<'TOML'
[package]
name = "helper-package"
version = "1.0.0"
edition = "2021"
[[bin]]
name = "family-helper"
path = "src/main.rs"
TOML
printf 'fn main() { println!("helper-tag-v1"); }\n' > "$WORK/upstream/helper/src/main.rs"
cat > "$WORK/upstream/worker/Cargo.toml" <<'TOML'
[package]
name = "worker-package"
version = "1.0.0"
edition = "2021"
[[bin]]
name = "family-worker"
path = "src/main.rs"
TOML
printf 'fn main() { println!("worker-tag-v1"); }\n' > "$WORK/upstream/worker/src/main.rs"
git init -q -b main "$WORK/upstream" || exit 1
git -C "$WORK/upstream" config user.name 'DSR test'
git -C "$WORK/upstream" config user.email 'test@example.invalid'
cargo generate-lockfile --offline --manifest-path "$WORK/upstream/Cargo.toml" || exit 1
git -C "$WORK/upstream" add Cargo.toml Cargo.lock src helper worker || exit 1
git -C "$WORK/upstream" commit -qm 'source family v1' || exit 1
git -C "$WORK/upstream" tag -a v1.0.0 -m 'source family release' || exit 1
PIN=$(git -C "$WORK/upstream" rev-parse HEAD) || exit 1
printf 'fn main() { println!("family-main-v2"); }\n' > "$WORK/upstream/src/main.rs"
git -C "$WORK/upstream" commit -qam 'later main' || exit 1
git config --file "$GIT_CONFIG_GLOBAL" \
    url."file://$WORK/upstream".insteadOf https://github.com/example/source-family.git || exit 1

run_build complete refs/tags/v1.0.0 rust family "$WORK/complete" --allow-build --timeout 60 \
    --bin family-helper --bin family --bin family-worker
check 'one build selects binaries across non-default workspace packages' equal "$STATUS" 0
if ((STATUS != 0)); then
    cat "$WORK/results/complete.log" >&2
    exit 1
fi
check 'complete family has one source receipt' jq -es 'length == 1 and .[0].method == "source"' "$WORK/results/complete.json"
check 'receipt preserves declared family order' jq -e \
    '[.binaries[].name] == ["family-helper","family","family-worker"]' "$WORK/results/complete.json"
check 'primary fields refer to the selected primary rather than the first member' jq -e \
    '.binaries[1] as $primary | .path == $primary.path and .sha256 == $primary.sha256 and .size_bytes == $primary.size_bytes' \
    "$WORK/results/complete.json"
check 'annotated tag remains the immutable family source pin' equal \
    "$(jq -r '.source_commit' "$WORK/results/complete.json")" "$PIN"
check 'the family receipt is persisted only after successful build' cmp -s \
    "$WORK/results/complete.json" "$WORK/complete/receipt.json"
for member in family-helper family family-worker; do
    path=$(jq -r --arg name "$member" '.binaries[] | select(.name == $name) | .path' "$WORK/results/complete.json")
    case "$member" in
        family-helper) expected=helper-tag-v1 ;;
        family) expected=family-tag-v1 ;;
        *) expected=worker-tag-v1 ;;
    esac
    check "$member is a real native executable from the selected tag" equal "$("$path" 2>/dev/null)" "$expected"
    check "$member receipt binds its actual bytes" equal "$(_isb_sha256 "$path" 2>/dev/null)" \
        "$(jq -r --arg name "$member" '.binaries[] | select(.name == $name) | .sha256' "$WORK/results/complete.json")"
done
check 'unselected root binary was not built' test ! -e \
    "$(dirname "$(jq -r '.path' "$WORK/results/complete.json")")/family-local"

run_build singleton refs/tags/v1.0.0 rust family "$WORK/singleton" --allow-build --timeout 60
check 'legacy singleton source build succeeds' equal "$STATUS" 0
check 'singleton retains original primary fields and one additive member' jq -e \
    '.binaries | length == 1' "$WORK/results/singleton.json"
check 'singleton receipt member matches original path' jq -e \
    '.path == .binaries[0].path and .sha256 == .binaries[0].sha256 and .binaries[0].name == "family"' \
    "$WORK/results/singleton.json"

run_build package refs/tags/v1.0.0 rust family "$WORK/package" --allow-build --timeout 60 \
    --package family-package --bin family --bin family-local
check 'explicit package selects all requested binaries within that package' equal "$STATUS" 0
check 'explicit package receipt includes exactly its declared pair' jq -e \
    '[.binaries[].name] == ["family","family-local"]' "$WORK/results/package.json"
if [[ "$(uname -s)" == Linux ]]; then
    run_build literal-names refs/tags/v1.0.0 rust FAMILY "$WORK/literal-names" --allow-build --timeout 60 \
        --bin family --bin FAMILY
    check 'Unix Cargo family preserves case-distinct binary names' equal "$STATUS" 0
    check 'Unix literal binary receipt preserves exact declaration order' jq -e \
        '[.binaries[].name] == ["family","FAMILY"]' "$WORK/results/literal-names.json"
    check 'case-distinct primary remains tied to its exact output identity' jq -e \
        '.binaries[1] as $primary | .path == $primary.path and .sha256 == $primary.sha256 and .size_bytes == $primary.size_bytes' \
        "$WORK/results/literal-names.json"
    for member in FAMILY family; do
        path=$(jq -r --arg name "$member" '.binaries[] | select(.name == $name) | .path' "$WORK/results/literal-names.json")
        case "$member" in
            FAMILY) expected=uppercase-tag-v1 ;;
            *) expected=family-tag-v1 ;;
        esac
        check "Unix literal $member executes its own Cargo target" equal "$("$path" 2>/dev/null)" "$expected"
        check "Unix literal $member receipt binds its actual bytes" equal "$(_isb_sha256 "$path" 2>/dev/null)" \
            "$(jq -r --arg name "$member" '.binaries[] | select(.name == $name) | .sha256' "$WORK/results/literal-names.json")"
    done
    # Cargo passes a literal bin name ending in .exe to rustc, which rejects
    # the dot in its crate name. Preserve that real compiler failure rather
    # than silently building the different target named "family".
    run_build literal-exe refs/tags/v1.0.0 rust family.exe "$WORK/literal-exe" --allow-build --timeout 60 \
        --bin family --bin family.exe
    check 'literal Unix .exe target retains genuine Cargo failure' equal "$STATUS" 6
    check 'literal Unix .exe target is passed intact to the compiler' grep -Fq \
        'invalid character '\''.'\'' in crate name: `family.exe`' "$WORK/literal-exe/output/build.log"
    check 'literal Unix .exe failure never attests the differently named binary' test ! -e "$WORK/literal-exe/receipt.json"
else
    printf 'SKIP: case-distinct Unix Cargo output fixture requires Linux\n'
fi
run_build wrong-package refs/tags/v1.0.0 rust family "$WORK/wrong-package" --allow-build --timeout 60 \
    --package family-package --bin family --bin family-helper
check 'package restriction cannot silently widen to an unrelated member' equal "$STATUS" 6
check 'wrong package emits no partial success receipt' test ! -s "$WORK/results/wrong-package.json"
run_build missing refs/tags/v1.0.0 rust family "$WORK/missing" --allow-build --timeout 60 \
    --bin family --bin family-missing
check 'missing Cargo binary rejects the whole family' equal "$STATUS" 6
check 'missing binary cannot publish a partial receipt' test ! -e "$WORK/missing/receipt.json"

reject_family omit-primary 'explicit family must contain its primary' --bin family-helper
reject_family duplicate 'duplicate executable is rejected' --bin family --bin family
reject_windows_family case-collision 'case-folded executable collision is rejected' --bin family --bin FAMILY
reject_windows_family suffix-collision '.exe alias collision is rejected' --bin family --bin family.exe
reject_family unsafe 'path traversal executable name is rejected' --bin family --bin ../family-helper
reject_family option-name 'option-shaped executable name is rejected' --bin family --bin --workspace
run_build unsupported refs/tags/v1.0.0 ruby family "$WORK/unsupported" --allow-build --bin family --bin family-helper
check 'unsupported language does not silently install only the primary' equal "$STATUS" 4
check 'unsupported family is refused before any checkout or compiler' test ! -e "$WORK/unsupported"

# Two real packages can emit the same executable path successfully. Require
# Cargo's selected compiler-artifact identity, rather than trusting that path.
mkdir -p "$WORK/upstream/duplicate/src" || exit 1
cat > "$WORK/upstream/Cargo.toml" <<'TOML'
[package]
name = "family-package"
version = "1.0.0"
edition = "2021"
[workspace]
members = ["helper", "worker", "duplicate"]
default-members = ["."]
resolver = "2"
[[bin]]
name = "family"
path = "src/main.rs"
[[bin]]
name = "family-local"
path = "src/local.rs"
TOML
cat > "$WORK/upstream/duplicate/Cargo.toml" <<'TOML'
[package]
name = "duplicate-helper-package"
version = "1.0.0"
edition = "2021"
[features]
alternate = []
[[bin]]
name = "family-helper"
path = "src/main.rs"
required-features = ["alternate"]
TOML
printf 'fn main() { println!("wrong-helper-provider"); }\n' > "$WORK/upstream/duplicate/src/main.rs"
cargo generate-lockfile --offline --manifest-path "$WORK/upstream/Cargo.toml" || exit 1
git -C "$WORK/upstream" add Cargo.toml Cargo.lock duplicate || exit 1
git -C "$WORK/upstream" commit -qm 'inactive same-name provider' || exit 1
run_build gated HEAD rust family "$WORK/gated" --allow-build --timeout 60 \
    --bin family --bin family-helper
check 'required-feature-disabled selection retains Cargo refusal' equal "$STATUS" 6
check 'missing required features are not silently enabled' grep -q \
    'requires the features: `alternate`' "$WORK/gated/output/build.log"
cat > "$WORK/upstream/duplicate/Cargo.toml" <<'TOML'
[package]
name = "duplicate-helper-package"
version = "1.0.0"
edition = "2021"
[features]
default = ["alternate"]
alternate = []
[[bin]]
name = "family-helper"
path = "src/main.rs"
required-features = ["alternate"]
TOML
git -C "$WORK/upstream" add duplicate/Cargo.toml || exit 1
git -C "$WORK/upstream" commit -qm 'active same-name provider' || exit 1
run_build collision HEAD rust family "$WORK/collision" --allow-build --timeout 60 \
    --bin family --bin family-helper
check 'two active package providers cannot overwrite one admitted executable' equal "$STATUS" 6
check 'provider collision emits no successful family receipt' test ! -s "$WORK/results/collision.json"
check 'provider collision retains Cargo identity diagnostic' grep -q \
    'exactly one executable provider' "$WORK/results/collision.log"
run_build collision-package HEAD rust family "$WORK/collision-package" --allow-build --timeout 60 \
    --package family-package --bin family --bin family-local
check 'explicit package excludes unrelated ambiguous workspace providers' equal "$STATUS" 0
run_build default-features HEAD rust family-helper "$WORK/default-features" --allow-build --timeout 60 \
    --package duplicate-helper-package --bin family-helper
check 'configured package retains its normal default features' equal "$STATUS" 0
check 'package and default features select the actual intended provider' equal \
    "$("$(jq -r '.path' "$WORK/results/default-features.json")" 2>/dev/null)" wrong-helper-provider

# Use an actual Cargo build script to mutate a tracked input after checkout.
# Successful compiler output still must not claim the original source pin.
cat > "$WORK/upstream/build.rs" <<'RUST'
fn main() {
    std::fs::write("src/local.rs", "fn main() { println!(\"modified-source\"); }\n").unwrap();
}
RUST
git -C "$WORK/upstream" add build.rs || exit 1
git -C "$WORK/upstream" commit -qm 'source mutation fixture' || exit 1
run_build mutation HEAD rust family "$WORK/mutation" --allow-build --timeout 60 \
    --package family-package --bin family --bin family-local
check 'real Cargo build script source mutation rejects complete family' equal "$STATUS" 6
check 'source drift cannot emit a successful family receipt' test ! -s "$WORK/results/mutation.json"
check 'source drift leaves no admitted receipt on disk' test ! -e "$WORK/mutation/receipt.json"

printf 'Source family tests: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]] || exit 1
test_bun_family_contracts
