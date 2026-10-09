#!/usr/bin/env bash
# Real Git/Cargo/rsync through ordinary source sync, build checkpoints and
# resume. Only SSH/SCP transport stays local; a receiver disconnect is real
# transfer failure. No compiler, source gate, scheduler or receipt is mocked.
# Use --strict-publication-only for the successful strict build and seal case.
# Use --strict-variants-only for genuine GNU/musl failure, resume and publication.
# Use --strict-mixed-protocol-only for mixed-platform receipt/selection controls;
# this mode never claims a Darwin compiler or artifact execution.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
ROOT="${DSR_TEST_ROOT:-$ROOT}"
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
    let out = env::var("OUT_DIR").unwrap();
    let release = Path::new(&out).ancestors().nth(3).unwrap();
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
    # The ordinary extraction path has no host-health dependency. Strict
    # workers must run the real readiness checks over the same local transport.
    # shellcheck source=../../src/host_health.sh
    source "$ROOT/src/host_health.sh" || return 1
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
