#!/usr/bin/env bash
# Real Git/Cargo/rsync through ordinary source sync, build checkpoints and
# resume. Only SSH/SCP transport stays local; a receiver disconnect is real
# transfer failure. No compiler, source gate, scheduler or receipt is mocked.
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
if (($# == 1)); then /bin/bash -c "$1"; status=$?
else "$@"; status=$?; fi
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
use std::{env, fs::OpenOptions, io::Write};
fn main() {
    let mut file = OpenOptions::new().create(true).append(true)
        .open(env::var("SYNC_TEST_COMPILERS").unwrap()).unwrap();
    writeln!(file, "{}", env::var("TARGET").unwrap()).unwrap();
}
RUST
cargo generate-lockfile --offline --manifest-path "$WORK/source/Cargo.toml" || exit 1
git -C "$WORK/source" init -q -b main || exit 1
git -C "$WORK/source" add Cargo.toml Cargo.lock src/main.rs build.rs || exit 1
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
    --arg healthy "$WORK/hosts/healthy" --arg bad "$WORK/hosts/bad" '
    .details.source_sync | .status=="partial" and .synced==1 and .failed==1 and
    .target_hosts=={"linux/amd64":"healthybox","linux/arm64":"badbox"} and
    .source_roots=={healthybox:$healthy} and
    any(.hosts[]; .host=="badbox" and .path==$bad and .status=="failed" and
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

printf 'Results: %s passed, %s failed; evidence %s\n' "$PASS" "$FAIL" "$WORK"
[[ "$FAIL" -eq 0 ]]
