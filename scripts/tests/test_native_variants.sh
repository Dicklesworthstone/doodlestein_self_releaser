#!/usr/bin/env bash
# Real offline Cargo builds through the native launcher and scheduler. Both
# libc variants execute locally; compiler, staging, collection and state are
# production code. The fixture has no registry or network dependencies.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
for dependency in bash cargo rustc git jq yq python3 tar gzip; do
    command -v "$dependency" >/dev/null 2>&1 || {
        printf 'SKIP: native variant integration requires %s\n' "$dependency"
        exit 0
    }
done
[[ $(uname -s) == Linux ]] || { printf 'SKIP: GNU/musl native fixtures require Linux\n'; exit 0; }
case "$(uname -m)" in
    x86_64|amd64) PLATFORM=linux/amd64; TRIPLE_ARCH=x86_64 ;;
    aarch64|arm64) PLATFORM=linux/arm64; TRIPLE_ARCH=aarch64 ;;
    *) printf 'SKIP: no runnable GNU/musl fixture for this architecture\n'; exit 0 ;;
esac
GNU_TRIPLE="$TRIPLE_ARCH-unknown-linux-gnu"
MUSL_TRIPLE="$TRIPLE_ARCH-unknown-linux-musl"
for triple in "$GNU_TRIPLE" "$MUSL_TRIPLE"; do
    stdlib=$(rustc --print target-libdir --target "$triple") || exit 3
    if [[ ! -d "$stdlib" ]] || ! compgen -G "$stdlib/libstd-*.rlib" >/dev/null; then
        printf 'SKIP: native variant integration needs real Rust std for %s\n' "$triple"
        exit 0
    fi
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/dsr-native-variants.XXXXXXXX") || exit 1
printf 'Fixtures: %s\n' "$WORK"
mkdir -p "$WORK/config/repos.d" "$WORK/source/src" "$WORK/state" "$WORK/ambient-cargo" || exit 1
export DSR_CONFIG_DIR="$WORK/config" DSR_CACHE_DIR="$WORK/cache" DSR_STATE_DIR="$WORK/state"
export DSR_REPOS_FILE="$WORK/config/repos.yaml" DSR_HOSTS_FILE="$WORK/config/hosts.yaml"
export ACT_CONFIG_DIR="$WORK/config" ACT_REPOS_DIR="$WORK/config/repos.d" NO_COLOR=1
export DSR_DISABLE_HOST_SELECTOR=1 RCH_DISABLED=1 RCH_CARGO_WRAPPER_BYPASS=1
# This dependency-free fixture seeds the production private cache from an
# empty Cargo home, without copying an unrelated developer registry.
export CARGO_HOME="$WORK/ambient-cargo"
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

PASS=0 FAIL=0 STATUS=0
check() {
    local label="$1"; shift
    if "$@"; then
        PASS=$((PASS + 1)); printf 'PASS: %s\n' "$label"
    else
        FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$label" >&2
    fi
}
run_code() {
    local label="$1" expected="$2" prefix="$3"; shift 3
    STATUS=0
    "$@" > "$prefix.out" 2> "$prefix.log" || STATUS=$?
    check "$label (exit $STATUS)" test "$STATUS" -eq "$expected"
    if [[ "$STATUS" != "$expected" ]]; then cat "$prefix.log" >&2; fi
    # Native stdout includes the actual Cargo diagnostic stream, followed by
    # one compact production receipt. Keep both rather than mocking transport.
    grep '^{.*}$' "$prefix.out" | tail -1 > "$prefix.json"
}
event_count() {
    local target="$1"
    awk -v target="$target" '$0 == target {n++} END {print n+0}' "$WORK/build-events"
}
check_binary() {
    local label="$1" receipt="$2" triple="$3" marker="$4" artifact
    check "$label receipt records the selected target" jq -e --arg target "$triple" \
        '.status == "success" and .method == "native" and .target_triple == $target' "$receipt"
    artifact=$(jq -r '.artifact_path // empty' "$receipt")
    check "$label collected executable exists" test -x "$artifact"
    if [[ -x "$artifact" ]]; then
        check "$label executable has the correct compiled libc" test "$("$artifact")" = "nativevariants $marker"
    fi
}

cat > "$WORK/source/Cargo.toml" <<'TOML'
[package]
name = "nativevariants"
version = "1.2.3"
edition = "2021"
TOML
cat > "$WORK/source/src/main.rs" <<'RUST'
fn main() {
    println!("nativevariants {}", if cfg!(target_env = "musl") { "musl" } else { "gnu" });
}
RUST
printf 'Native variant fixture license\nRedistribution of these test binaries is permitted.\n' > "$WORK/source/LICENSE"
cat > "$WORK/source/build.rs" <<'RUST'
use std::{env, fs::OpenOptions, io::Write, path::Path};
fn main() {
    let target = env::var("TARGET").unwrap();
    assert_eq!(env::var("DSR_TARGET_TRIPLE").unwrap(), target);
    let mut events = OpenOptions::new().create(true).append(true)
        .open(env::var("DSR_NATIVE_EVENTS").unwrap()).unwrap();
    writeln!(events, "{target}").unwrap();
    if target.ends_with("-musl") && Path::new(&env::var("DSR_NATIVE_FAIL_MUSL").unwrap()).exists() {
        panic!("deliberate real musl build-script failure for resume");
    }
}
RUST
cargo generate-lockfile --offline --manifest-path "$WORK/source/Cargo.toml" || exit 1
git -C "$WORK/source" init -q -b main || exit 1
git -C "$WORK/source" add Cargo.toml Cargo.lock src/main.rs build.rs LICENSE || exit 1
git -C "$WORK/source" -c user.name=Fixture -c user.email=fixture@example.invalid \
    commit -qm 'real native variant crate' || exit 1
cat > "$DSR_HOSTS_FILE" <<YAML
schema_version: "1.0.0"
hosts:
  localnative:
    platform: $PLATFORM
    connection: local
    concurrency: 2
platform_mapping:
  "$PLATFORM": localnative
YAML
cat > "$ACT_REPOS_DIR/nativevariants.yaml" <<YAML
tool_name: nativevariants
repo: example/nativevariants
local_path: $WORK/source
language: rust
binary_name: nativevariants
build_cmd: cargo build --release --locked --offline
linux_glibc_floor: native
targets: ["$PLATFORM"]
act_job_map:
  "$PLATFORM": null
target_triples:
  "$PLATFORM": ["$GNU_TRIPLE", "$MUSL_TRIPLE"]
artifact_naming: '\${name}-\${version}-\${target_triple}'
install_script_compat: '\${name}-\${target_triple}'
archive_format:
  linux: tar.gz
include_files: [LICENSE]
env:
  PATH: "$PATH"
  CARGO_TARGET_DIR: "$WORK/shared-cargo-target"
  DSR_NATIVE_EVENTS: "$WORK/build-events"
  DSR_NATIVE_FAIL_MUSL: "$WORK/fail-musl"
YAML
: > "$WORK/build-events"

# Verify real host-slot custody where the execution environment permits it.
# Some hosted PID namespaces cannot attest a process start time. That narrow
# infrastructure boundary may be disabled, explicitly reported, without
# replacing any native compiler, worker, staging or state implementation.
capacity_status=0
(
    # The scheduler reserves in a background worker, whose BASHPID may be
    # hidden even when the top-level shell happens to have a visible PID.
    selector_acquire_slot localnative fixture-probe || exit $?
    selector_release_slot localnative fixture-probe
) > "$WORK/capacity.out" 2> "$WORK/capacity.log" &
capacity_pid=$!
wait "$capacity_pid" || capacity_status=$?
if [[ $capacity_status -eq 0 ]]; then
    printf 'Capacity: genuine local host reservation enabled\n'
else
    printf 'Capacity: unavailable (status %s); only reservation boundary disabled\n' "$capacity_status"
    cat "$WORK/capacity.log" >&2
    selector_acquire_slot() { return 0; }
    selector_release_slot() { return 0; }
fi

for variant in gnu musl; do
    triple="$TRIPLE_ARCH-unknown-linux-$variant"
    selected_env=$(act_get_build_env nativevariants "$PLATFORM" "$triple")
    check "$variant environment selects the requested compiler target" test \
        "$(act_get_build_env_value "$selected_env" CARGO_BUILD_TARGET)" = "$triple"
    run_code "direct native $variant build" 0 "$WORK/direct-$variant" \
        act_run_native_build nativevariants "$PLATFORM" 1.2.3 \
        11111111-1111-4111-8111-111111111111 '' '' '' localnative "$triple"
    check_binary "direct $variant" "$WORK/direct-$variant.json" "$triple" "$variant"
done
GNU_PATH=$(jq -r '.artifact_path // empty' "$WORK/direct-gnu.json")
MUSL_PATH=$(jq -r '.artifact_path // empty' "$WORK/direct-musl.json")
check 'same-run native variants have different artifact destinations' test "$GNU_PATH" != "$MUSL_PATH"
check 'same-run native variants have different log paths' test \
    "$(jq -r '.log_file' "$WORK/direct-gnu.json")" != "$(jq -r '.log_file' "$WORK/direct-musl.json")"
check 'configured Cargo target base keeps GNU and musl outputs separate' test \
    "$(jq -r '.cargo_isolation.target_dir' "$WORK/direct-gnu.json")" != \
    "$(jq -r '.cargo_isolation.target_dir' "$WORK/direct-musl.json")"
check 'both private target directories honor the configured base' jq -e --arg base "$WORK/shared-cargo-target/" \
    '.cargo_isolation.target_dir | startswith($base)' "$WORK/direct-gnu.json" "$WORK/direct-musl.json"
if [[ -x "$GNU_PATH" ]]; then
    check 'collecting musl preserves the earlier GNU executable' test "$("$GNU_PATH")" = 'nativevariants gnu'
fi

# Configuration and literal command targets must agree with the selected
# variant before any compiler invocation, so no GNU output can be relabeled.
cp "$ACT_REPOS_DIR/nativevariants.yaml" "$WORK/reviewed-config.yaml" || exit 1
EVENTS_BEFORE=$(wc -l < "$WORK/build-events")
GNU_TARGET="$GNU_TRIPLE" yq -i '.env.CARGO_BUILD_TARGET = strenv(GNU_TARGET)' "$ACT_REPOS_DIR/nativevariants.yaml" || exit 1
run_code 'conflicting configured Cargo target is refused' 4 "$WORK/conflicting-env" \
    act_run_native_build nativevariants "$PLATFORM" 1.2.3 \
    22222222-2222-4222-8222-222222222222 '' '' '' localnative "$MUSL_TRIPLE"
cp "$WORK/reviewed-config.yaml" "$ACT_REPOS_DIR/nativevariants.yaml" || exit 1
GNU_TARGET="$GNU_TRIPLE" yq -i '.build_cmd = "cargo build --release --locked --offline --target " + strenv(GNU_TARGET)' \
    "$ACT_REPOS_DIR/nativevariants.yaml" || exit 1
run_code 'conflicting literal Cargo command target is refused' 4 "$WORK/conflicting-command" \
    act_run_native_build nativevariants "$PLATFORM" 1.2.3 \
    33333333-3333-4333-8333-333333333333 '' '' '' localnative "$MUSL_TRIPLE"
cp "$WORK/reviewed-config.yaml" "$ACT_REPOS_DIR/nativevariants.yaml" || exit 1
check 'target conflicts never reach the real build script' test "$(wc -l < "$WORK/build-events")" -eq "$EVENTS_BEFORE"

run_code 'parallel native matrix builds both configured variants' 0 "$WORK/parallel" \
    act_orchestrate_build nativevariants 1.2.3 --parallel-jobs 2 \
    --output-dir "$WORK/parallel-output" -- "$PLATFORM"
check 'parallel summary counts two independent tasks' jq -e \
    '.status == "success" and .summary == {total:2,success:2,failed:0}' "$WORK/parallel.json"
check 'parallel tasks retain one platform and two explicit triples' jq -e \
    --arg platform "$PLATFORM" --arg gnu "$GNU_TRIPLE" --arg musl "$MUSL_TRIPLE" \
    '([.targets[].platform] | unique) == [$platform] and
     ([.targets[].target_triple] | sort) == ([$gnu,$musl] | sort) and
     ([.targets[].task_key] | unique | length) == 2' "$WORK/parallel.json"
for variant in gnu musl; do
    triple="$TRIPLE_ARCH-unknown-linux-$variant"
    jq --arg target "$triple" '.targets[] | select(.target_triple == $target)' \
        "$WORK/parallel.json" > "$WORK/parallel-$variant.json"
    check_binary "parallel $variant" "$WORK/parallel-$variant.json" "$triple" "$variant"
done

# A genuine failing Cargo build script affects only musl. Resume must retain
# the GNU receipt and rebuild only the failed variant with its own attempt.
: > "$WORK/fail-musl"
run_code 'one variant may fail without losing the completed variant' 1 "$WORK/failed" \
    act_orchestrate_build nativevariants 1.2.4 --parallel-jobs 2 \
    --output-dir "$WORK/resume-output" -- "$PLATFORM"
check 'failed matrix records exactly one success and one failure' jq -e \
    '.summary == {total:2,success:1,failed:1}' "$WORK/failed.json"
FAILED_RUN=$(jq -r '.run_id // empty' "$WORK/failed.json")
GNU_BEFORE=$(event_count "$GNU_TRIPLE")
MUSL_BEFORE=$(event_count "$MUSL_TRIPLE")
GNU_COMPLETED_PATH=$(jq -r --arg target "$GNU_TRIPLE" \
    '.targets[] | select(.target_triple == $target) | .artifact_path' "$WORK/failed.json")
mv "$WORK/fail-musl" "$WORK/fail-musl.disabled" || exit 1
run_code 'resume completes the failed native variant' 0 "$WORK/resumed" \
    act_orchestrate_build nativevariants 1.2.4 --parallel-jobs 2 \
    --resume-run-id "$FAILED_RUN" --output-dir "$WORK/resume-output" -- "$PLATFORM"
check 'resume succeeds for both variants' jq -e \
    '.status == "success" and .summary == {total:2,success:2,failed:0}' "$WORK/resumed.json"
check 'resume does not invoke the completed GNU compiler task again' test "$(event_count "$GNU_TRIPLE")" -eq "$GNU_BEFORE"
check 'resume invokes the failed musl compiler task exactly once' test "$(event_count "$MUSL_TRIPLE")" -eq "$((MUSL_BEFORE + 1))"
check 'resume retains the original completed GNU artifact' test "$GNU_COMPLETED_PATH" = \
    "$(jq -r --arg target "$GNU_TRIPLE" '.targets[] | select(.target_triple == $target) | .artifact_path' "$WORK/resumed.json")"
build_state_get nativevariants 1.2.4 "$FAILED_RUN" > "$WORK/resumed-state.json"
check 'checkpoint preserves distinct configured variant tasks' jq -e \
    --arg gnu "$GNU_TRIPLE" --arg musl "$MUSL_TRIPLE" \
    '(.context.build_tasks | length) == 2 and
     ([.context.build_tasks[].target_triple] | sort) == ([$gnu,$musl] | sort)' "$WORK/resumed-state.json"
for variant in gnu musl; do
    triple="$TRIPLE_ARCH-unknown-linux-$variant"
    jq --arg target "$triple" '.targets[] | select(.target_triple == $target)' \
        "$WORK/resumed.json" > "$WORK/resumed-$variant.json"
    check_binary "resumed $variant" "$WORK/resumed-$variant.json" "$triple" "$variant"
done

EVENTS_BEFORE=$(wc -l < "$WORK/build-events")
GNU_TARGET="$GNU_TRIPLE" MUSL_TARGET="$MUSL_TRIPLE" TARGET_PLATFORM="$PLATFORM" \
    yq -i '.target_triples[strenv(TARGET_PLATFORM)] = [strenv(MUSL_TARGET),strenv(GNU_TARGET)]' \
    "$ACT_REPOS_DIR/nativevariants.yaml" || exit 1
run_code 'resume refuses a changed primary and variant task plan' 4 "$WORK/changed-plan" \
    act_orchestrate_build nativevariants 1.2.4 --parallel-jobs 2 \
    --resume-run-id "$FAILED_RUN" --output-dir "$WORK/resume-output" -- "$PLATFORM"
check 'changed variant plan is refused before any compiler task' test "$(wc -l < "$WORK/build-events")" -eq "$EVENTS_BEFORE"
cp "$WORK/reviewed-config.yaml" "$ACT_REPOS_DIR/nativevariants.yaml" || exit 1

# Continue through the real command coordinator, native scheduler, manifest
# collector, archive packager and JSON response. Source command definitions
# without invoking CLI dispatch so the tested local capacity boundary remains
# the same one diagnosed above. There is no workflow or compiler substitute.
# shellcheck source=../../src/git_ops.sh
source "$ROOT/src/git_ops.sh"
# shellcheck source=../../src/packaging.sh
source "$ROOT/src/packaging.sh"
export SCRIPT_DIR="$ROOT"
declare -A _DSR_LOADED_MODULES=([packaging]=1 [artifact_naming]=1)
# shellcheck disable=SC1090
source <(awk '/^(_dsr_require|cmd_build)\(\) \{/{copy=1} copy{print} copy && /^\}/{copy=0}' "$ROOT/dsr") || exit 1
# The JSON envelope contains an unindented heredoc closing brace.
# shellcheck disable=SC1090
source <(awk '/^json_envelope\(\) \{/{copy=1} copy{print} copy && /^# ====/{exit}' "$ROOT/dsr") || exit 1
export JSON_MODE=true DRY_RUN=false VERBOSE=false DSR_VERSION=fixture
OUTPUT="$WORK/command-output"
STATUS=0
cmd_build nativevariants --version 1.2.5 --no-sync --jobs 2 --output-dir "$OUTPUT" \
    > "$WORK/command-build.json" 2> "$WORK/command-build.log" || STATUS=$?
check 'complete native command packages both real libc variants' test "$STATUS" -eq 0
if [[ $STATUS -ne 0 ]]; then cat "$WORK/command-build.log" >&2; fi
check 'native command emits one successful JSON envelope' jq -es \
    'length == 1 and .[0].command == "build" and .[0].status == "success" and
     .[0].details.total == 2 and .[0].details.success == 2 and .[0].details.failed == 0' "$WORK/command-build.json"
check 'command JSON preserves both variant result rows' jq -e \
    --arg platform "$PLATFORM" --arg gnu "$GNU_TRIPLE" --arg musl "$MUSL_TRIPLE" \
    '([.details.targets[].platform] | unique) == [$platform] and
     ([.details.targets[].target_triple] | sort) == ([$gnu,$musl] | sort)' "$WORK/command-build.json"
MANIFEST="$OUTPUT/nativevariants-v1.2.5-manifest.json"
check 'native command publishes a local manifest' test -f "$MANIFEST"
if [[ -f "$MANIFEST" ]]; then
    for variant in gnu musl; do
        triple="$TRIPLE_ARCH-unknown-linux-$variant"
        archive="nativevariants-1.2.5-$triple.tar.gz"
        compat="nativevariants-$triple.tar.gz"
        check "$variant package and alias retain their explicit triple" jq -e \
            --arg triple "$triple" --arg archive "$archive" --arg compat "$compat" \
            '[.artifacts[] | select(.name == $archive or .name == $compat)] |
             length == 2 and all(.[]; .target_triple == $triple and .archive_format == "tar.gz")' "$MANIFEST"
        check "$variant native archive contains the canonical binary and license" test \
            "$(tar -tzf "$OUTPUT/$archive" 2>/dev/null | sort)" = $'LICENSE\nnativevariants'
        check "$variant package preserves the configured license bytes" test \
            "$(tar -xOzf "$OUTPUT/$archive" LICENSE 2>/dev/null)" = "$(cat "$WORK/source/LICENSE")"
        if tar -xOzf "$OUTPUT/$archive" nativevariants > "$WORK/packaged-$variant"; then
            chmod +x "$WORK/packaged-$variant" || exit 1
            check "$variant packaged executable retains its libc bytes" test \
                "$("$WORK/packaged-$variant")" = "nativevariants $variant"
        else
            check "$variant packaged executable retains its libc bytes" false
        fi
        check "$variant compatibility archive keeps identical package bytes" cmp -s "$OUTPUT/$archive" "$OUTPUT/$compat"
        archive_sha=$(_act_sha256 "$OUTPUT/$archive")
        check "$variant manifest digest binds the packaged bytes" jq -e \
            --arg archive "$archive" --arg digest "$archive_sha" \
            'any(.artifacts[]; .name == $archive and .sha256 == $digest)' "$MANIFEST"
    done
fi

# A partially completed public build has already collected GNU into its
# output directory. Resume must preserve the original worker's exact byte and
# inode receipts while admitting only the newly successful musl attempt.
COMMAND_RESUME_OUTPUT="$WORK/command-resume-output"
: > "$WORK/fail-musl"
STATUS=0
cmd_build nativevariants --version 1.2.6 --no-sync --jobs 2 --output-dir "$COMMAND_RESUME_OUTPUT" \
    > "$WORK/command-partial.json" 2> "$WORK/command-partial.log" || STATUS=$?
check 'public command reports one genuine native variant failure' test "$STATUS" -eq 1
check 'public partial JSON identifies both variant tasks' jq -e \
    --arg gnu "$GNU_TRIPLE" --arg musl "$MUSL_TRIPLE" \
    '.status == "partial" and .details.total == 2 and .details.success == 1 and .details.failed == 1 and
     ([.details.targets[].target_triple] | sort) == ([$gnu,$musl] | sort)' "$WORK/command-partial.json"
build_state_get nativevariants 1.2.6 > "$WORK/command-partial-state.json" || exit 1
COMMAND_RUN=$(jq -r '.run_id' "$WORK/command-partial-state.json")
GNU_KEY="$PLATFORM@$GNU_TRIPLE"
MUSL_KEY="$PLATFORM@$MUSL_TRIPLE"
GNU_ORIGINAL_RECEIPTS=$(jq -c --arg key "$GNU_KEY" \
    '.target_statuses[$key].result.resume_artifacts' "$WORK/command-partial-state.json")
GNU_ORIGINAL_PATH=$(jq -r --arg key "$GNU_KEY" \
    '.target_statuses[$key].result.artifact_path' "$WORK/command-partial-state.json")
GNU_ORIGINAL_IDENTITY=$(_act_file_identity "$GNU_ORIGINAL_PATH") || exit 1
GNU_ORIGINAL_SHA=$(_act_sha256 "$GNU_ORIGINAL_PATH") || exit 1
GNU_BEFORE=$(event_count "$GNU_TRIPLE")
MUSL_BEFORE=$(event_count "$MUSL_TRIPLE")

STATUS=0
cmd_build nativevariants --version 1.2.6 --no-sync --jobs 2 --output-dir "$COMMAND_RESUME_OUTPUT" \
    > "$WORK/command-stale.json" 2> "$WORK/command-stale.log" || STATUS=$?
check 'fresh public build refuses output left by the partial attempt' test "$STATUS" -eq 1
check 'stale output refusal does not invoke either compiler task' test \
    "$(event_count "$GNU_TRIPLE")/$(event_count "$MUSL_TRIPLE")" = "$GNU_BEFORE/$MUSL_BEFORE"
check 'stale output refusal preserves the completed artifact inode' test \
    "$(_act_file_identity "$GNU_ORIGINAL_PATH")" = "$GNU_ORIGINAL_IDENTITY"
mv "$WORK/fail-musl" "$WORK/fail-musl-command.disabled" || exit 1
STATUS=0
cmd_build nativevariants --version 1.2.6 --no-sync --jobs 2 --resume="$COMMAND_RUN" \
    --output-dir "$COMMAND_RESUME_OUTPUT" > "$WORK/command-resumed.json" \
    2> "$WORK/command-resumed.log" || STATUS=$?
check 'public resume completes the existing native matrix and output' test "$STATUS" -eq 0
if [[ $STATUS -ne 0 ]]; then cat "$WORK/command-resumed.log" >&2; fi
check 'public resume reports both variants successful' jq -e \
    '.status == "success" and .details.total == 2 and .details.success == 2 and .details.failed == 0' \
    "$WORK/command-resumed.json"
check 'public resume leaves GNU compiler invocation count unchanged' test "$(event_count "$GNU_TRIPLE")" -eq "$GNU_BEFORE"
check 'public resume invokes only one additional musl compilation' test "$(event_count "$MUSL_TRIPLE")" -eq "$((MUSL_BEFORE + 1))"
build_state_get nativevariants 1.2.6 "$COMMAND_RUN" > "$WORK/command-resumed-state.json" || exit 1
check 'public resume retains the exact GNU byte and inode receipts' test "$GNU_ORIGINAL_RECEIPTS" = \
    "$(jq -c --arg key "$GNU_KEY" '.target_statuses[$key].result.resume_artifacts' "$WORK/command-resumed-state.json")"
check 'public resume retains the exact original GNU artifact path' test "$GNU_ORIGINAL_PATH" = \
    "$(jq -r --arg key "$GNU_KEY" '.target_statuses[$key].result.artifact_path' "$WORK/command-resumed-state.json")"
check 'public resume preserves actual GNU inode and bytes' test \
    "$(_act_file_identity "$GNU_ORIGINAL_PATH")/$(_act_sha256 "$GNU_ORIGINAL_PATH")" = "$GNU_ORIGINAL_IDENTITY/$GNU_ORIGINAL_SHA"
check 'public resume finalizes the original run only after packaging' jq -e \
    --arg run "$COMMAND_RUN" --arg gnu "$GNU_KEY" --arg musl "$MUSL_KEY" \
    '.run_id == $run and .status == "completed" and
     .target_statuses[$gnu].attempts == 1 and .target_statuses[$musl].attempts == 2' "$WORK/command-resumed-state.json"
COMMAND_RESUME_MANIFEST="$COMMAND_RESUME_OUTPUT/nativevariants-v1.2.6-manifest.json"
check 'public resume emits its final manifest' test -f "$COMMAND_RESUME_MANIFEST"
if [[ -f "$COMMAND_RESUME_MANIFEST" ]]; then
    for variant in gnu musl; do
        triple="$TRIPLE_ARCH-unknown-linux-$variant"
        archive="nativevariants-1.2.6-$triple.tar.gz"
        compat="nativevariants-$triple.tar.gz"
        check "resumed $variant has both manifest archive aliases" jq -e \
            --arg triple "$triple" --arg archive "$archive" --arg compat "$compat" \
            '[.artifacts[] | select(.name == $archive or .name == $compat)] |
             length == 2 and all(.[]; .target_triple == $triple)' "$COMMAND_RESUME_MANIFEST"
        check "resumed $variant archive preserves canonical members" test \
            "$(tar -tzf "$COMMAND_RESUME_OUTPUT/$archive" | sort)" = $'LICENSE\nnativevariants'
        check "resumed $variant archive preserves license bytes" test \
            "$(tar -xOzf "$COMMAND_RESUME_OUTPUT/$archive" LICENSE)" = "$(cat "$WORK/source/LICENSE")"
        tar -xOzf "$COMMAND_RESUME_OUTPUT/$archive" nativevariants > "$WORK/command-resumed-$variant" || exit 1
        chmod +x "$WORK/command-resumed-$variant" || exit 1
        check "resumed $variant archive contains the correct executable" test \
            "$("$WORK/command-resumed-$variant")" = "nativevariants $variant"
        check "resumed $variant compatibility alias retains exact archive bytes" \
            cmp -s "$COMMAND_RESUME_OUTPUT/$archive" "$COMMAND_RESUME_OUTPUT/$compat"
    done
fi

# Retry a previously successful direct musl lane with a real compiler failure.
# Existing collected bytes remain evidence, but a failed fresh attempt must
# not claim them as a new artifact or report stale success.
: > "$WORK/fail-musl"
MUSL_ORIGINAL_IDENTITY=$(_act_file_identity "$MUSL_PATH") || exit 1
MUSL_ORIGINAL_SHA=$(_act_sha256 "$MUSL_PATH") || exit 1
run_code 'failed fresh native attempt refuses its prior successful output' 6 "$WORK/direct-stale" \
    act_run_native_build nativevariants "$PLATFORM" 1.2.3 \
    11111111-1111-4111-8111-111111111111 '' '' '' localnative "$MUSL_TRIPLE"
check 'failed fresh attempt returns no publishable artifact path' jq -e \
    '.status == "failed" and .artifact_path == "" and .artifact_paths == []' "$WORK/direct-stale.json"
check 'failed fresh attempt leaves earlier musl evidence unchanged' test \
    "$(_act_file_identity "$MUSL_PATH")/$(_act_sha256 "$MUSL_PATH")" = "$MUSL_ORIGINAL_IDENTITY/$MUSL_ORIGINAL_SHA"
mv "$WORK/fail-musl" "$WORK/fail-musl-stale.disabled" || exit 1

# Generic legacy names still need one archive for every configured variant.
# The primary owns shared names; the nonprimary needs an unambiguous triple
# name rather than being left as an unpackaged raw executable.
yq -i '.artifact_naming = "${name}-${version}-${os}-${arch}" |
       .install_script_compat = "${name}-${os}-${arch}"' "$ACT_REPOS_DIR/nativevariants.yaml" || exit 1
GENERIC_OUTPUT="$WORK/generic-output"
STATUS=0
cmd_build nativevariants --version 1.2.7 --no-sync --jobs 2 --output-dir "$GENERIC_OUTPUT" \
    > "$WORK/generic-build.json" 2> "$WORK/generic-build.log" || STATUS=$?
check 'generic naming packages the complete native variant matrix' test "$STATUS" -eq 0
if [[ $STATUS -ne 0 ]]; then cat "$WORK/generic-build.log" >&2; fi
GENERIC_MANIFEST="$GENERIC_OUTPUT/nativevariants-v1.2.7-manifest.json"
GENERIC_PRIMARY="nativevariants-1.2.7-${PLATFORM//\//-}.tar.gz"
GENERIC_COMPAT="nativevariants-${PLATFORM//\//-}.tar.gz"
check 'generic naming emits its complete variant manifest' test -f "$GENERIC_MANIFEST"
if [[ -f "$GENERIC_MANIFEST" ]]; then
    check 'generic naming retains a real archive for each libc variant' jq -e \
        --arg gnu "$GNU_TRIPLE" --arg musl "$MUSL_TRIPLE" \
        '([.artifacts[] | select(.archive_format == "tar.gz") | .target_triple] | unique | sort) ==
         ([$gnu,$musl] | sort)' "$GENERIC_MANIFEST"
    GNU_GENERIC_SHA=$(_act_sha256 "$GENERIC_OUTPUT/$GENERIC_PRIMARY") || exit 1
    check 'shared generic compatibility alias belongs to GNU with identical bytes' jq -e \
        --arg alias "$GENERIC_COMPAT" --arg gnu "$GNU_TRIPLE" --arg digest "$GNU_GENERIC_SHA" \
        '[.artifacts[] | select(.name == $alias)] |
         length == 1 and .[0].target_triple == $gnu and .[0].sha256 == $digest' "$GENERIC_MANIFEST"
    check 'shared generic alias contains the primary archive bytes' cmp -s \
        "$GENERIC_OUTPUT/$GENERIC_PRIMARY" "$GENERIC_OUTPUT/$GENERIC_COMPAT"
    MUSL_GENERIC_NAME=$(jq -r --arg musl "$MUSL_TRIPLE" \
        '[.artifacts[] | select(.target_triple == $musl and .archive_format == "tar.gz")][0].name // empty' "$GENERIC_MANIFEST")
    check 'nonprimary generic archive has a deterministic full target triple name' test \
        "$MUSL_GENERIC_NAME" = "nativevariants-1.2.7-${PLATFORM//\//-}-$MUSL_TRIPLE.tar.gz"
    if [[ -n "$MUSL_GENERIC_NAME" && -f "$GENERIC_OUTPUT/$MUSL_GENERIC_NAME" ]]; then
        check 'generic musl archive contains canonical binary and license members' test \
            "$(tar -tzf "$GENERIC_OUTPUT/$MUSL_GENERIC_NAME" | sort)" = $'LICENSE\nnativevariants'
        tar -xOzf "$GENERIC_OUTPUT/$MUSL_GENERIC_NAME" nativevariants > "$WORK/generic-musl" || exit 1
        chmod +x "$WORK/generic-musl" || exit 1
        check 'generic musl archive owns actual musl executable bytes' test "$("$WORK/generic-musl")" = 'nativevariants musl'
    fi
fi
cp "$WORK/reviewed-config.yaml" "$ACT_REPOS_DIR/nativevariants.yaml" || exit 1

# A real Cargo workspace exercises native-side packaging before cmd_build
# collects anything: both binaries, their libc, the configured include file,
# and the variant identity must survive that extra archive boundary.
mkdir -p "$WORK/workspace-source/src" "$WORK/workspace-source/helper/src" || exit 1
cp "$WORK/source/src/main.rs" "$WORK/workspace-source/src/main.rs" || exit 1
cp "$WORK/source/build.rs" "$WORK/workspace-source/build.rs" || exit 1
cp "$WORK/source/LICENSE" "$WORK/workspace-source/LICENSE" || exit 1
cat > "$WORK/workspace-source/Cargo.toml" <<'TOML'
[package]
name = "nativevariants"
version = "1.2.3"
edition = "2021"
[workspace]
members = ["helper"]
resolver = "2"
TOML
cat > "$WORK/workspace-source/helper/Cargo.toml" <<'TOML'
[package]
name = "nativehelper"
version = "1.2.3"
edition = "2021"
TOML
cat > "$WORK/workspace-source/helper/src/main.rs" <<'RUST'
fn main() {
    println!("nativehelper {}", if cfg!(target_env = "musl") { "musl" } else { "gnu" });
}
RUST
cargo generate-lockfile --offline --manifest-path "$WORK/workspace-source/Cargo.toml" || exit 1
git -C "$WORK/workspace-source" init -q -b main || exit 1
git -C "$WORK/workspace-source" add Cargo.toml Cargo.lock src/main.rs build.rs LICENSE \
    helper/Cargo.toml helper/src/main.rs || exit 1
git -C "$WORK/workspace-source" -c user.name=Fixture -c user.email=fixture@example.invalid \
    commit -qm 'real two-binary native workspace' || exit 1
WORKSPACE_SOURCE="$WORK/workspace-source" yq \
    '.tool_name = "nativeworkspace" | .repo = "example/nativeworkspace" |
     .local_path = strenv(WORKSPACE_SOURCE) | .workspace_binaries = ["nativevariants","nativehelper"] |
     .build_cmd = "cargo build --workspace --release --locked --offline"' \
    "$WORK/reviewed-config.yaml" > "$ACT_REPOS_DIR/nativeworkspace.yaml" || exit 1
WORKSPACE_OUTPUT="$WORK/workspace-output"
STATUS=0
cmd_build nativeworkspace --version 1.2.8 --no-sync --jobs 2 --output-dir "$WORKSPACE_OUTPUT" \
    > "$WORK/workspace-build.json" 2> "$WORK/workspace-build.log" || STATUS=$?
check 'real two-binary workspace packages both native libc variants' test "$STATUS" -eq 0
if [[ $STATUS -ne 0 ]]; then cat "$WORK/workspace-build.log" >&2; fi
WORKSPACE_MANIFEST="$WORKSPACE_OUTPUT/nativeworkspace-v1.2.8-manifest.json"
check 'workspace command retains both explicit native results' jq -e \
    --arg gnu "$GNU_TRIPLE" --arg musl "$MUSL_TRIPLE" \
    '.status == "success" and .details.total == 2 and
     ([.details.targets[].target_triple] | sort) == ([$gnu,$musl] | sort)' "$WORK/workspace-build.json"
check 'workspace produces its final manifest' test -f "$WORKSPACE_MANIFEST"
if [[ -f "$WORKSPACE_MANIFEST" ]]; then
    for variant in gnu musl; do
        triple="$TRIPLE_ARCH-unknown-linux-$variant"
        archive="nativeworkspace-1.2.8-$triple.tar.gz"
        compat="nativeworkspace-$triple.tar.gz"
        check "workspace $variant primary and compatibility retain triple identity" jq -e \
            --arg triple "$triple" --arg archive "$archive" --arg compat "$compat" \
            '[.artifacts[] | select(.name == $archive or .name == $compat)] |
             length == 2 and all(.[]; .target_triple == $triple and .archive_format == "tar.gz")' "$WORKSPACE_MANIFEST"
        check "workspace $variant archive contains both binaries and configured license" test \
            "$(tar -tzf "$WORKSPACE_OUTPUT/$archive" | sort)" = $'LICENSE\nnativehelper\nnativevariants'
        for binary in nativevariants nativehelper; do
            tar -xOzf "$WORKSPACE_OUTPUT/$archive" "$binary" > "$WORK/workspace-$variant-$binary" || exit 1
            chmod +x "$WORK/workspace-$variant-$binary" || exit 1
            check "workspace $variant $binary has the correct compiled libc" test \
                "$("$WORK/workspace-$variant-$binary")" = "$binary $variant"
        done
        check "workspace $variant includes the exact configured license" test \
            "$(tar -xOzf "$WORKSPACE_OUTPUT/$archive" LICENSE)" = "$(cat "$WORK/workspace-source/LICENSE")"
        check "workspace $variant compatibility alias preserves all archive bytes" \
            cmp -s "$WORKSPACE_OUTPUT/$archive" "$WORKSPACE_OUTPUT/$compat"
    done
fi

printf '\nNative variant integration: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
