#!/usr/bin/env bash
# Real GNU/musl executables, archives, configuration, build packaging, manifests,
# and release planning. Only the workflow runner and GitHub transport are
# fixtures; no Docker service or external release is used by this test.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
COMMAND_FILE="${DSR_TEST_COMMAND_FILE:-$ROOT/dsr}"
RUSTC_BIN="${DSR_VARIANT_RUSTC:-rustc}"
for dependency in bash git jq yq tar gzip xz python3 "$RUSTC_BIN"; do
    command -v "$dependency" >/dev/null 2>&1 || {
        printf 'SKIP: multi-variant release requires %s\n' "$dependency"
        exit 0
    }
done
if [[ $(uname -s) != Linux ]]; then
    printf 'SKIP: runnable GNU/musl release fixtures require Linux\n'
    exit 0
fi
case "$(uname -m)" in
    x86_64|amd64) PLATFORM=linux/amd64; TRIPLE_ARCH=x86_64 ;;
    aarch64|arm64) PLATFORM=linux/arm64; TRIPLE_ARCH=aarch64 ;;
    *) printf 'SKIP: no runnable GNU/musl fixture for this architecture\n'; exit 0 ;;
esac
GNU_TRIPLE="$TRIPLE_ARCH-unknown-linux-gnu"
MUSL_TRIPLE="$TRIPLE_ARCH-unknown-linux-musl"
for triple in "$GNU_TRIPLE" "$MUSL_TRIPLE"; do
    stdlib=$("$RUSTC_BIN" --print target-libdir --target "$triple") || exit 3
    if [[ ! -d "$stdlib" ]] || ! compgen -G "$stdlib/libstd-*.rlib" >/dev/null; then
        printf 'SKIP: multi-variant release needs the real Rust standard library for %s\n' "$triple"
        exit 0
    fi
done

WORK=$(mktemp -d "${TMPDIR:-/tmp}/dsr-multi-variant-release.XXXXXXXX") || exit 1
# Retain real binaries, original archives and refusal logs for diagnosis.
printf 'Fixtures: %s\n' "$WORK"
mkdir -p "$WORK/config/repos.d" "$WORK/source/.github/workflows" \
    "$WORK/producer" "$WORK/gnu" "$WORK/musl" "$WORK/state" || exit 1
export DSR_CONFIG_DIR="$WORK/config" DSR_CACHE_DIR="$WORK/cache" DSR_STATE_DIR="$WORK/state"
export DSR_REPOS_FILE="$WORK/config/repos.yaml" DSR_HOSTS_FILE="$WORK/config/hosts.yaml"
export ACT_CONFIG_DIR="$WORK/config" ACT_REPOS_DIR="$WORK/config/repos.d" NO_COLOR=1
export RCH_DISABLED=1 RCH_CARGO_WRAPPER_BYPASS=1

# shellcheck source=../../src/config.sh
source "$ROOT/src/config.sh"
# shellcheck source=../../src/act_runner.sh
source "$ROOT/src/act_runner.sh"
# shellcheck source=../../src/artifact_naming.sh
source "$ROOT/src/artifact_naming.sh"
# shellcheck source=../../src/packaging.sh
source "$ROOT/src/packaging.sh"
# shellcheck source=../../src/build_state.sh
source "$ROOT/src/build_state.sh"
# shellcheck source=../../src/git_ops.sh
source "$ROOT/src/git_ops.sh"
# shellcheck source=../../src/github.sh
source "$ROOT/src/github.sh"
# Load the complete production command functions without dispatching the CLI.
# shellcheck disable=SC1090
source <(awk '/^(cmd_build|cmd_release|_release_file_size|_release_sha256|_release_require_publishable_artifacts|_dispatch_load_config|_dispatch_is_true)\(\) \{/{copy=1} copy{print} copy && /^\}/{copy=0}' "$COMMAND_FILE") || exit 1
# The envelope contains a JSON heredoc whose closing brace is not a shell
# function boundary; its following section divider marks the end instead.
# shellcheck disable=SC1090
source <(awk '/^json_envelope\(\) \{/{copy=1} copy{print} copy && /^# ====/{exit}' "$COMMAND_FILE") || exit 1

PASS=0 FAIL=0 STATUS=0
export JSON_MODE=true DRY_RUN=false VERBOSE=false DSR_VERSION=fixture
export GH_MAX_RETRIES=2 GH_RETRY_DELAY=0
RUN=11111111-1111-4111-8111-111111111111
WORKFLOW_ARTIFACTS="$WORK/producer"
CALLS="$WORK/github-calls"
ORCHESTRATION_CALLS="$WORK/workflow-calls"
REMOTE_ENABLED=false
: > "$CALLS"
: > "$ORCHESTRATION_CALLS"
log_info() { printf '%s\n' "$*" >&2; }
log_ok() { log_info "$@"; }
log_warn() { log_info "$@"; }
log_error() { log_info "$@"; }
log_debug() { :; }
log_set_tool() { :; }
_dsr_require() {
    case "$1" in artifact_naming|packaging) return 0 ;; *) return 3 ;; esac
}
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
    "$@" > "$prefix.json" 2> "$prefix.log" || STATUS=$?
    check "$label (exit $STATUS)" test "$STATUS" -eq "$expected"
    if [[ "$STATUS" != "$expected" ]]; then cat "$prefix.log" >&2; fi
}

cat > "$WORK/source/main.rs" <<'RUST'
#[cfg(target_env = "gnu")]
fn main() { println!("variantdemo GNU 1.2.3"); }
#[cfg(target_env = "musl")]
fn main() { println!("variantdemo musl 1.2.3"); }
RUST
printf 'Reviewed fixture license\n' > "$WORK/source/LICENSE"
cat > "$WORK/source/.github/workflows/release.yml" <<'YAML'
name: prebuilt release fixture
on: push
jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - run: cargo build --release
YAML
git -C "$WORK/source" init -q -b main || exit 1
git -C "$WORK/source" add main.rs LICENSE .github/workflows/release.yml || exit 1
git -C "$WORK/source" -c user.name=Fixture -c user.email=fixture@example.invalid \
    commit -qm 'real GNU and musl fixture source' || exit 1
git -C "$WORK/source" tag v1.2.3 || exit 1
SOURCE_SHA=$(git -C "$WORK/source" rev-parse HEAD) || exit 1
cat > "$WORK/config/repos.d/variantdemo.yaml" <<YAML
tool_name: variantdemo
repo: example/variantdemo
local_path: $WORK/source
language: rust
binary_name: variantdemo
workflow: .github/workflows/release.yml
targets: ["$PLATFORM"]
act_job_map:
  "$PLATFORM": release
target_triples:
  "$PLATFORM": ["$GNU_TRIPLE", "$MUSL_TRIPLE"]
artifact_naming: '\${name}-\${version}-\${target_triple}'
install_script_compat: '\${name}-\${target_triple}'
archive_format:
  linux: tar.gz
include_files: [LICENSE]
YAML
cp "$WORK/config/repos.d/variantdemo.yaml" "$WORK/reviewed-config.yaml" || exit 1

for variant in gnu musl; do
    triple="$TRIPLE_ARCH-unknown-linux-$variant"
    "$RUSTC_BIN" --edition=2021 --crate-name variantdemo --target "$triple" \
        -C debuginfo=0 "$WORK/source/main.rs" -o "$WORK/$variant/variantdemo" \
        > "$WORK/$variant/compiler.out" 2> "$WORK/$variant/compiler.log" || {
            cat "$WORK/$variant/compiler.log" >&2
            exit 1
        }
    cp "$WORK/source/LICENSE" "$WORK/$variant/LICENSE" || exit 1
    tar -czf "$WORK/producer/variantdemo-1.2.3-$triple.tar.gz" \
        -C "$WORK/$variant" variantdemo LICENSE || exit 1
done
check 'genuine GNU executable runs' test "$("$WORK/gnu/variantdemo")" = 'variantdemo GNU 1.2.3'
check 'genuine musl executable runs' test "$("$WORK/musl/variantdemo")" = 'variantdemo musl 1.2.3'
if cmp -s "$WORK/gnu/variantdemo" "$WORK/musl/variantdemo"; then
    check 'the two variants contain different executable bytes' false
else
    check 'the two variants contain different executable bytes' true
fi
GNU_NAME="variantdemo-1.2.3-$GNU_TRIPLE.tar.gz"
MUSL_NAME="variantdemo-1.2.3-$MUSL_TRIPLE.tar.gz"
GNU_COMPAT="variantdemo-$GNU_TRIPLE.tar.gz"
MUSL_COMPAT="variantdemo-$MUSL_TRIPLE.tar.gz"
GNU_SHA=$(_gh_asset_sha256 "$WORK/producer/$GNU_NAME") || exit 1
MUSL_SHA=$(_gh_asset_sha256 "$WORK/producer/$MUSL_NAME") || exit 1

# The workflow boundary returns already-built archives from one act lane.
# Collection, packaging, naming, manifest construction and state writes below
# remain production implementations, including all local byte checks.
act_check() { return 0; }
act_check_prereqs() { return 0; }
act_orchestrate_build() {
    local tool="$1" version="$2" run result
    printf '%s\n' "$*" >> "$ORCHESTRATION_CALLS"
    [[ "$tool" == variantdemo && "$version" == 1.2.3 ]] || return 4
    run=$(DSR_RUN_ID="$RUN" build_state_create "$tool" "$version" "$PLATFORM") || return 4
    build_state_update_status "$tool" "$version" running "$run" || return 4
    result=$(jq -nc --arg tool "$tool" --arg version "$version" --arg run "$run" \
        --arg platform "$PLATFORM" --arg directory "$WORKFLOW_ARTIFACTS" --arg source "$SOURCE_SHA" '
        {tool:$tool,version:$version,run_id:$run,status:"success",git_sha:$source,git_ref:"v1.2.3",
         build_purpose:"release",publishable:true,summary:{total:1,success:1,failed:0},
         targets:[{platform:$platform,method:"act",host:"local",status:"success",artifact_dir:$directory}]}') || return 4
    build_state_update_target "$tool" "$version" "$PLATFORM" completed \
        "$(jq -c '{result:.targets[0]}' <<< "$result")" "$run" || return 4
    printf '%s\n' "$result"
}

# Authentication and every network/mutation boundary are explicit fixtures.
# A negative test cannot accidentally publish when a local preflight fails.
gh_check() { return 0; }
gh_check_token() { return 0; }
_gh_resolve_token() { printf 'fixture-token\n'; }
gh_create_release() {
    printf 'CREATE %s\n' "$*" >> "$CALLS"
    $REMOTE_ENABLED || return 8
    [[ "$1" == example/variantdemo && "$2" == v1.2.3 ]] || return 4
    cat "$WORK/release.json"
}
gh_api() {
    printf 'API %s\n' "$*" >> "$CALLS"
    $REMOTE_ENABLED || return 8
    case "$1" in
        repos/example/variantdemo/releases/9/assets\?per_page=100\&page=*)
            local page="${1##*page=}"
            [[ "$page" =~ ^[1-9][0-9]*$ ]] || return 4
            jq --argjson page "$page" '.[(($page-1)*100):($page*100)]' "$WORK/inventory.json"
            ;;
        repos/example/variantdemo/releases/9|repos/example/variantdemo/releases/tags/v1.2.3)
            [[ " $* " != *' --method '* ]] || return 8
            jq --slurpfile assets "$WORK/inventory.json" '.assets=$assets[0]' "$WORK/release.json"
            ;;
        *) return 8 ;;
    esac
}
gh_download_release_asset() {
    printf 'DOWNLOAD %s %s\n' "$1" "$2" >> "$CALLS"
    $REMOTE_ENABLED && [[ "$1" == example/variantdemo && ! -e "$3" ]] || return 8
    cp "$WORK/remote/$2" "$3"
}
gh() { printf 'GH %s\n' "$*" >> "$CALLS"; return 8; }
curl() {
    if ! $REMOTE_ENABLED; then printf 'CURL\n' >> "$CALLS"; return 8; fi
    local response='' headers='' payload='' url='' arg name id sha size
    while (($#)); do
        arg="$1"; shift
        case "$arg" in
            -o) response="$1"; shift ;;
            -D) headers="$1"; shift ;;
            --data-binary) payload="${1#@}"; shift ;;
            https://uploads.github.com/*) url="$arg" ;;
        esac
    done
    [[ -n "$response" && -n "$headers" && -f "$payload" &&
       "$url" == 'https://uploads.github.com/repos/example/variantdemo/releases/9/assets?name='* ]] || return 4
    name="${url#*name=}"
    name="${name//%2B/+}"
    printf 'POST %s\n' "$name" >> "$CALLS"
    # The transport stores exactly the staged request bytes. Production
    # gh_upload_asset_named verifies the returned digest and rechecks the
    # remote inventory; this fixture does not decide upload success.
    id=$(jq 'length+100' "$WORK/inventory.json") || return 4
    sha=$(_gh_asset_sha256 "$payload") || return 4
    size=$(_act_file_size "$payload") || return 4
    cp "$payload" "$WORK/remote/$id" || return 4
    jq --arg name "$name" --argjson id "$id" --argjson size "$size" --arg sha "$sha" \
        '. + [{name:$name,id:$id,state:"uploaded",size:$size,digest:("sha256:"+$sha)}]' \
        "$WORK/inventory.json" > "$WORK/inventory.next" || return 4
    mv "$WORK/inventory.next" "$WORK/inventory.json" || return 4
    jq '.[-1]' "$WORK/inventory.json" > "$response" || return 4
    printf 'HTTP/1.1 201 Created\r\n\r\n' > "$headers"
    printf '201'
}
_dispatch_send_all() { printf 'DISPATCH %s\n' "$*" >> "$CALLS"; return 8; }

OUTPUT="$WORK/output"
MANIFEST="$OUTPUT/variantdemo-v1.2.3-manifest.json"
run_code 'prebuilt GNU and musl workflow artifacts complete one build' 0 "$WORK/build" \
    cmd_build variantdemo --version 1.2.3 --no-sync --output-dir "$OUTPUT"
check 'build emits one successful JSON envelope' jq -es \
    'length==1 and .[0].command=="build" and .[0].status=="success" and .[0].details.publishable' "$WORK/build.json"
if [[ ! -f "$MANIFEST" ]]; then
    printf 'FAIL: build withheld the variant manifest; evidence is in %s\n' "$WORK" >&2
    exit 1
fi
check 'one workflow invocation supplies both variants' test "$(wc -l < "$ORCHESTRATION_CALLS")" -eq 1
check 'build completion is recorded through the real state writer' jq -e '.status=="completed"' \
    "$DSR_STATE_DIR/builds/variantdemo/1.2.3/$RUN/state.json"
check 'manifest has exactly both primaries and both compatibility aliases' jq -e \
    --arg gnu "$GNU_NAME" --arg musl "$MUSL_NAME" --arg gc "$GNU_COMPAT" --arg mc "$MUSL_COMPAT" \
    '(.artifacts|map(.name)|sort)==([$gnu,$musl,$gc,$mc]|sort)' "$MANIFEST"
check 'all manifest rows retain target triple and the correct producer digest' jq -e \
    --arg platform "$PLATFORM" --arg gnu "$GNU_TRIPLE" --arg musl "$MUSL_TRIPLE" \
    --arg gh "$GNU_SHA" --arg mh "$MUSL_SHA" '
    all(.artifacts[]; .target==$platform and .archive_format=="tar.gz" and
        (if .target_triple==$gnu then .sha256==$gh
         elif .target_triple==$musl then .sha256==$mh else false end)) and
    ([.artifacts[].target_triple]|unique|sort)==([$gnu,$musl]|sort)' "$MANIFEST"
for variant in gnu musl; do
    triple="$TRIPLE_ARCH-unknown-linux-$variant"
    for name in "variantdemo-1.2.3-$triple.tar.gz" "variantdemo-$triple.tar.gz"; do
        check "$name preserves original compressed bytes" cmp -s \
            "$WORK/producer/variantdemo-1.2.3-$triple.tar.gz" "$OUTPUT/$name"
    done
    mkdir -p "$WORK/extracted-$variant" || exit 1
    if tar -xzf "$OUTPUT/variantdemo-$triple.tar.gz" -C "$WORK/extracted-$variant"; then
        check "$variant archive retains the actual compiled executable" cmp -s \
            "$WORK/$variant/variantdemo" "$WORK/extracted-$variant/variantdemo"
        check "$variant archive retains configured license bytes" cmp -s \
            "$WORK/source/LICENSE" "$WORK/extracted-$variant/LICENSE"
    else
        check "$variant archive extracts" false
    fi
done

snapshot() {
    python3 - "$1" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
print(json.dumps({str(p.relative_to(root)): [p.stat().st_ino, hashlib.sha256(p.read_bytes()).hexdigest()]
                  for p in root.rglob('*') if p.is_file()}, sort_keys=True))
PY
}
BEFORE=$(snapshot "$OUTPUT") || exit 1
DRY_RUN=true
run_code 'release dry-run plans both variants without publishing' 0 "$WORK/plan" \
    cmd_release variantdemo 1.2.3 --artifacts "$OUTPUT"
check 'dry-run creates no GitHub request' test ! -s "$CALLS"
check 'dry-run preserves every artifact and manifest inode and digest' test "$BEFORE" = "$(snapshot "$OUTPUT")"
check 'dry-run does not generate checksum files' test ! -e "$OUTPUT/SHA256SUMS"
check 'dry-run preserves explicit per-artifact target triple and digest' jq -e \
    --arg gnu "$GNU_TRIPLE" --arg musl "$MUSL_TRIPLE" --arg gh "$GNU_SHA" --arg mh "$MUSL_SHA" '
    .status=="dry_run" and .details.plan.strict==false and (.details.plan.artifacts|length)==4 and
    all(.details.plan.artifacts[];
        if .target_triple==$gnu then .sha256==$gh
        elif .target_triple==$musl then .sha256==$mh else false end)' "$WORK/plan.json"
check 'upload names remain specific to one variant and one byte sequence' jq -e \
    --arg gnu "$GNU_TRIPLE" --arg musl "$MUSL_TRIPLE" '
    .details.plan.artifacts as $a |
    all($a[]; .target_triple as $t | all(.upload_names[]; contains($t))) and
    ([$a[]|.sha256 as $sha|.upload_names[]|{name:.,sha:$sha}] |
        group_by(.name)|all(.[]; (map(.sha)|unique|length)==1)) and
    ([$a[].upload_names[]]|unique|length)==4' "$WORK/plan.json"

# Each negative case has valid files and digest metadata. Publication must
# refuse uncertain identity or conflicting name ownership before creation,
# sidecar generation, uploads, remote repair, or downstream dispatch.
run_refusal() {
    local label="$1" directory="$2" prefix="$3" before
    before=$(snapshot "$directory") || return 1
    : > "$CALLS"
    DRY_RUN=false
    run_code "$label" 4 "$prefix" cmd_release variantdemo 1.2.3 --artifacts "$directory"
    check "$label makes no GitHub request" test ! -s "$CALLS"
    check "$label preserves local evidence" test "$before" = "$(snapshot "$directory")"
}
mkdir "$WORK/missing-triple" "$WORK/colliding-alias" || exit 1
cp -p "$OUTPUT/"* "$WORK/missing-triple/" || exit 1
jq 'del(.artifacts[].target_triple)' "$MANIFEST" > \
    "$WORK/missing-triple/variantdemo-v1.2.3-manifest.json" || exit 1
run_refusal 'missing variant receipt identity is refused' "$WORK/missing-triple" "$WORK/missing-triple-result"

mkdir "$WORK/unconfigured-triple" || exit 1
cp "$WORK/producer/$GNU_NAME" "$WORK/unconfigured-triple/variantdemo-1.2.3.tar.gz" || exit 1
jq --arg original "$GNU_NAME" --arg triple "$TRIPLE_ARCH-unknown-linux-uclibc" '
    .artifacts = [.artifacts[] | select(.name==$original) |
        .name="variantdemo-1.2.3.tar.gz" | .target_triple=$triple]' \
    "$MANIFEST" > "$WORK/unconfigured-triple/variantdemo-v1.2.3-manifest.json" || exit 1
run_refusal 'an unconfigured explicit variant cannot claim a generic artifact' \
    "$WORK/unconfigured-triple" "$WORK/unconfigured-triple-result"

# A legacy scalar receipt may omit target_triple, but that cannot suppress a
# real classifier error when its filename advertises contradictory libcs.
mkdir "$WORK/scalar-ambiguous" || exit 1
SCALAR_AMBIGUOUS="variantdemo-1.2.3-$GNU_TRIPLE-musl.tar.gz"
cp "$WORK/producer/$GNU_NAME" "$WORK/scalar-ambiguous/$SCALAR_AMBIGUOUS" || exit 1
jq --arg original "$GNU_NAME" --arg name "$SCALAR_AMBIGUOUS" '
    .artifacts = [.artifacts[] | select(.name==$original) | .name=$name | del(.target_triple)]' \
    "$MANIFEST" > "$WORK/scalar-ambiguous/variantdemo-v1.2.3-manifest.json" || exit 1
DSR_VARIANT_PLATFORM="$PLATFORM" DSR_VARIANT_PRIMARY="$GNU_TRIPLE" \
    yq '.target_triples[strenv(DSR_VARIANT_PLATFORM)]=strenv(DSR_VARIANT_PRIMARY)' \
    "$WORK/reviewed-config.yaml" > "$WORK/config/repos.d/variantdemo.yaml" || exit 1
run_refusal 'a legacy scalar receipt cannot suppress contradictory libc markers' \
    "$WORK/scalar-ambiguous" "$WORK/scalar-ambiguous-result"
cp "$WORK/reviewed-config.yaml" "$WORK/config/repos.d/variantdemo.yaml" || exit 1

cp -p "$OUTPUT/"* "$WORK/colliding-alias/" || exit 1
cp "$WORK/producer/$MUSL_NAME" "$WORK/colliding-alias/$GNU_COMPAT" || exit 1
jq --arg name "$GNU_COMPAT" --arg triple "$MUSL_TRIPLE" --arg sha "$MUSL_SHA" \
    --argjson size "$(_act_file_size "$WORK/producer/$MUSL_NAME")" '
    .artifacts |= map(if .name==$name then .target_triple=$triple | .sha256=$sha | .size_bytes=$size else . end)' \
    "$MANIFEST" > "$WORK/colliding-alias/variantdemo-v1.2.3-manifest.json" || exit 1
run_refusal 'different bytes cannot occupy another variant upload alias' \
    "$WORK/colliding-alias" "$WORK/colliding-alias-result"

DSR_SHARED_COMPAT='${name}-${os}-${arch}' yq '.install_script_compat=strenv(DSR_SHARED_COMPAT)' \
    "$WORK/reviewed-config.yaml" > "$WORK/config/repos.d/variantdemo.yaml" || exit 1
DRY_RUN=true
: > "$CALLS"
run_code 'a shared compatibility name belongs to the configured primary variant' 0 "$WORK/shared-compat-plan" \
    cmd_release variantdemo 1.2.3 --artifacts "$OUTPUT"
check 'shared compatibility planning never reaches GitHub' test ! -s "$CALLS"
check 'shared compatibility planning preserves artifact evidence' test "$BEFORE" = "$(snapshot "$OUTPUT")"
check 'GNU owns shared compatibility names and musl retains its own names' jq -e \
    --arg gnu "$GNU_TRIPLE" --arg musl "$MUSL_TRIPLE" \
    --arg shared "variantdemo-${PLATFORM//\//-}.tar.gz" '
    .details.plan.artifacts as $a |
    ([$a[]|select(.target_triple==$gnu)|.upload_names[]]|unique) as $gnu_names |
    ([$a[]|select(.target_triple==$musl)|.upload_names[]]|unique) as $musl_names |
    ($gnu_names|index($shared))!=null and ($musl_names|index($shared))==null and
    all($musl_names[]; contains($musl)) and
    ([$a[]|.sha256 as $sha|.upload_names[]|{name:.,sha:$sha}] |
        group_by(.name)|all(.[]; (map(.sha)|unique|length)==1))' "$WORK/shared-compat-plan.json"
mkdir "$WORK/reversed-manifest" || exit 1
cp -p "$OUTPUT/"* "$WORK/reversed-manifest/" || exit 1
jq '.artifacts|=reverse' "$MANIFEST" > "$WORK/reversed-manifest/variantdemo-v1.2.3-manifest.json" || exit 1
run_code 'manifest ordering cannot reassign shared compatibility ownership' 0 "$WORK/reversed-plan" \
    cmd_release variantdemo 1.2.3 --artifacts "$WORK/reversed-manifest"
check 'shared names keep the same digest after manifest reversal' jq -e \
    --slurpfile original "$WORK/shared-compat-plan.json" '
    def owners: [.details.plan.artifacts[]|.sha256 as $sha|.upload_names[]|{name:.,sha:$sha}] |
        unique | sort_by(.name);
    owners==($original[0]|owners)' "$WORK/reversed-plan.json"
cp "$WORK/reviewed-config.yaml" "$WORK/config/repos.d/variantdemo.yaml" || exit 1

# Filename inference belongs to collection, before a manifest is published.
# A generic workflow filename has the documented configured-primary meaning;
# the manifest must make that identity explicit for later publication.
mkdir "$WORK/primary-name" || exit 1
cp "$WORK/producer/$GNU_NAME" "$WORK/primary-name/variantdemo-1.2.3.tar.gz" || exit 1
result=$(jq -nc --arg directory "$WORK/primary-name" --arg platform "$PLATFORM" \
    --arg source "$SOURCE_SHA" --arg run "$RUN" '
    {tool:"variantdemo",version:"1.2.3",run_id:$run,status:"success",git_sha:$source,git_ref:"v1.2.3",
     summary:{total:1,success:1,failed:0},targets:[{platform:$platform,method:"act",status:"success",artifact_dir:$directory}]}') || exit 1
run_code 'a generic workflow filename records the configured primary variant' 0 "$WORK/primary-name-result" \
    act_generate_manifest "$result" "$WORK/primary-name-manifest.json"
check 'primary-name inference preserves explicit identity and actual bytes' jq -e \
    --arg triple "$GNU_TRIPLE" --arg sha "$GNU_SHA" '
    (.artifacts|length)==1 and .artifacts[0].target_triple==$triple and .artifacts[0].sha256==$sha' \
    "$WORK/primary-name-manifest.json"
for case_name in two-name-triples contradictory-marker; do
    directory="$WORK/$case_name"
    mkdir "$directory" || exit 1
    name="variantdemo-1.2.3-$GNU_TRIPLE-musl.tar.gz"
    [[ "$case_name" != two-name-triples ]] || name="variantdemo-1.2.3-$GNU_TRIPLE-$MUSL_TRIPLE.tar.gz"
    cp "$WORK/producer/$GNU_NAME" "$directory/$name" || exit 1
    result=$(jq -nc --arg directory "$directory" --arg platform "$PLATFORM" \
        --arg source "$SOURCE_SHA" --arg run "$RUN" '
        {tool:"variantdemo",version:"1.2.3",run_id:$run,status:"success",git_sha:$source,git_ref:"v1.2.3",
         summary:{total:1,success:1,failed:0},targets:[{platform:$platform,method:"act",status:"success",artifact_dir:$directory}]}') || exit 1
    run_code "$case_name cannot become a publishable manifest" 4 "$WORK/$case_name-result" \
        act_generate_manifest "$result" "$WORK/$case_name-manifest.json"
    check "$case_name leaves no completed manifest" test ! -e "$WORK/$case_name-manifest.json"
done

mkdir "$WORK/remote" || exit 1
printf '[]\n' > "$WORK/inventory.json"
jq -nc '{id:9,tag_name:"v1.2.3",draft:false,prerelease:false,
    upload_url:"https://uploads.github.com/repos/example/variantdemo/releases/9/assets{?name,label}",
    html_url:"https://github.com/example/variantdemo/releases/tag/v1.2.3",assets:[]}' > "$WORK/release.json" || exit 1
REMOTE_ENABLED=true DRY_RUN=false
: > "$CALLS"
run_code 'ordinary publication verifies both variants through the real uploader' 0 "$WORK/publish" \
    cmd_release variantdemo 1.2.3 --artifacts "$OUTPUT" --no-dispatch
check 'publication emits one successful content-verified envelope' jq -es \
    'length==1 and .[0].status=="success" and .[0].details.verification=="ok" and .[0].details.failed==0' \
    "$WORK/publish.json"
check 'published names exactly match the earlier dry-run and its generated sidecars' jq -e \
    --slurpfile plan "$WORK/plan.json" '
    ($plan[0].details.plan) as $p |
    ([$p.artifacts[].upload_names[]]|unique) as $payloads |
    ($payloads + ($payloads|map(.+".sha256")) + $p.additional_files + ["SHA256SUMS"] | unique | sort) as $expected |
    (map(.name)|sort)==$expected and length==$plan[0].details.file_count' "$WORK/inventory.json"
check 'one release creation uploads each selected name exactly once' test \
    "$(awk '$1=="CREATE"{n++} END{print n+0}' "$CALLS")" -eq 1
check 'all planned names reach POST exactly once' test \
    "$(awk '$1=="POST"{n++} END{print n+0}' "$CALLS")" -eq "$(jq 'length' "$WORK/inventory.json")"
check 'remote archives and generated checksum evidence retain the correct variant bytes' \
    python3 - "$WORK" "$GNU_TRIPLE" "$MUSL_TRIPLE" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
inventory = json.loads((root / 'inventory.json').read_text())
remote = {entry['name']: (root / 'remote' / str(entry['id'])).read_bytes() for entry in inventory}
assert len(remote) == len(inventory), 'duplicate remote asset name'
for entry in inventory:
    data = remote[entry['name']]
    assert entry['digest'] == 'sha256:' + hashlib.sha256(data).hexdigest()
    assert entry['size'] == len(data)
expected_lines = []
for triple in sys.argv[2:]:
    primary = f'variantdemo-1.2.3-{triple}.tar.gz'
    original = (root / 'producer' / primary).read_bytes()
    sha = hashlib.sha256(original).hexdigest()
    for name in (primary, f'variantdemo-{triple}.tar.gz'):
        assert remote[name] == original, f'wrong producer bytes under {name}'
        line = f'{sha}  {name}\n'.encode()
        assert remote[name + '.sha256'] == line, f'wrong checksum sidecar for {name}'
        expected_lines.append(line)
assert sorted(remote['SHA256SUMS'].splitlines(keepends=True)) == sorted(expected_lines)
assert remote['variantdemo-v1.2.3-manifest.json'] == (root / 'output/variantdemo-v1.2.3-manifest.json').read_bytes()
PY

# One lane may return different archive formats for its variants. Resolve the
# source by target triple and genuinely repack it; copying xz bytes under a
# gzip name would publish an installer asset that cannot be decompressed.
verify_mixed_archives() {
    python3 - "$WORK" "$GNU_TRIPLE" "$MUSL_TRIPLE" "$1" "$2" <<'PY'
import hashlib, json, pathlib, sys, tarfile
root = pathlib.Path(sys.argv[1])
gnu, musl = sys.argv[2:4]
output = pathlib.Path(sys.argv[4])
original_variant = sys.argv[5]
manifest = json.loads((output / 'variantdemo-v1.2.3-manifest.json').read_text())
rows = {row['name']: row for row in manifest['artifacts']}
expected = {
    f'variantdemo-1.2.3-{gnu}.tar.gz': (gnu, 'gnu', 'tar.gz', 'r:gz'),
    f'variantdemo-{gnu}.tar.gz': (gnu, 'gnu', 'tar.gz', 'r:gz'),
    f'variantdemo-1.2.3-{musl}.tar.gz': (musl, 'musl', 'tar.gz', 'r:gz'),
    f'variantdemo-{musl}.tar.gz': (musl, 'musl', 'tar.gz', 'r:gz'),
}
original_triple = gnu if original_variant == 'gnu' else musl
expected[f'variantdemo-1.2.3-{original_triple}.tar.xz'] = (original_triple, original_variant, 'tar.xz', 'r:xz')
assert len(rows) == len(manifest['artifacts']), 'duplicate artifact receipt'
assert set(rows) == set(expected), f'missing artifacts: {set(expected)-set(rows)}; unexpected: {set(rows)-set(expected)}'
for name, (triple, variant, archive_format, mode) in expected.items():
    path = output / name
    row = rows[name]
    assert row['target_triple'] == triple, f'wrong target identity for {name}'
    assert row['archive_format'] == archive_format, f'wrong archive format for {name}'
    assert row['sha256'] == hashlib.sha256(path.read_bytes()).hexdigest()
    assert row['size_bytes'] == path.stat().st_size
    with tarfile.open(path, mode) as archive:
        members = {(member.name[2:] if member.name.startswith('./') else member.name): member
                   for member in archive.getmembers() if member.isfile()}
        assert set(members) == {'variantdemo', 'LICENSE'}, f'wrong payload members in {name}'
        assert archive.extractfile(members['variantdemo']).read() == (root / variant / 'variantdemo').read_bytes()
        assert archive.extractfile(members['LICENSE']).read() == (root / 'source/LICENSE').read_bytes()
PY
}

WORKFLOW_ARTIFACTS="$WORK/mixed-producer"
MIXED_OUTPUT="$WORK/mixed-output"
MUSL_XZ_NAME="variantdemo-1.2.3-$MUSL_TRIPLE.tar.xz"
mkdir "$WORKFLOW_ARTIFACTS" || exit 1
cp "$WORK/producer/$GNU_NAME" "$WORKFLOW_ARTIFACTS/$GNU_NAME" || exit 1
tar -cJf "$WORKFLOW_ARTIFACTS/$MUSL_XZ_NAME" -C "$WORK/musl" variantdemo LICENSE || exit 1
RUN=22222222-2222-4222-8222-222222222222
DRY_RUN=false REMOTE_ENABLED=false
: > "$CALLS"
run_code 'mixed GNU gzip and musl xz workflow archives complete one build' 0 "$WORK/mixed-build" \
    cmd_build variantdemo --version 1.2.3 --no-sync --output-dir "$MIXED_OUTPUT"
check 'mixed-format build emits one successful publishable envelope' jq -es \
    'length==1 and .[0].command=="build" and .[0].status=="success" and .[0].details.publishable' \
    "$WORK/mixed-build.json"
check 'mixed-format packaging retains the original GNU gzip bytes' cmp -s \
    "$WORKFLOW_ARTIFACTS/$GNU_NAME" "$MIXED_OUTPUT/$GNU_NAME"
check 'mixed-format packaging retains the original musl xz bytes' cmp -s \
    "$WORKFLOW_ARTIFACTS/$MUSL_XZ_NAME" "$MIXED_OUTPUT/$MUSL_XZ_NAME"
check 'repacked musl primary contains genuine gzip bytes' gzip -t "$MIXED_OUTPUT/$MUSL_NAME"
check 'repacked musl compatibility name contains genuine gzip bytes' gzip -t "$MIXED_OUTPUT/$MUSL_COMPAT"
check 'repacked musl primary and compatibility archive bytes agree' cmp -s \
    "$MIXED_OUTPUT/$MUSL_NAME" "$MIXED_OUTPUT/$MUSL_COMPAT"
check 'every mixed-format receipt and archive retains its own compiled variant' \
    verify_mixed_archives "$MIXED_OUTPUT" musl

# Reverse the formats and remove include_files so a platform-wide format
# shortcut cannot accidentally hide the primary variant's required repack.
WORKFLOW_ARTIFACTS="$WORK/inverted-producer"
INVERTED_OUTPUT="$WORK/inverted-output"
GNU_XZ_NAME="variantdemo-1.2.3-$GNU_TRIPLE.tar.xz"
mkdir "$WORKFLOW_ARTIFACTS" || exit 1
cp "$WORK/producer/$MUSL_NAME" "$WORKFLOW_ARTIFACTS/$MUSL_NAME" || exit 1
tar -cJf "$WORKFLOW_ARTIFACTS/$GNU_XZ_NAME" -C "$WORK/gnu" variantdemo LICENSE || exit 1
yq '.include_files=[]' "$WORK/reviewed-config.yaml" > "$WORK/config/repos.d/variantdemo.yaml" || exit 1
RUN=33333333-3333-4333-8333-333333333333
run_code 'GNU xz and musl gzip complete the primary repack without configured includes' 0 "$WORK/inverted-build" \
    cmd_build variantdemo --version 1.2.3 --no-sync --output-dir "$INVERTED_OUTPUT"
check 'inverted-format build emits one successful publishable envelope' jq -es \
    'length==1 and .[0].command=="build" and .[0].status=="success" and .[0].details.publishable' \
    "$WORK/inverted-build.json"
check 'inverted-format packaging retains the original GNU xz bytes' cmp -s \
    "$WORKFLOW_ARTIFACTS/$GNU_XZ_NAME" "$INVERTED_OUTPUT/$GNU_XZ_NAME"
check 'inverted-format packaging retains the original musl gzip bytes' cmp -s \
    "$WORKFLOW_ARTIFACTS/$MUSL_NAME" "$INVERTED_OUTPUT/$MUSL_NAME"
check 'repacked GNU primary contains genuine gzip bytes' gzip -t "$INVERTED_OUTPUT/$GNU_NAME"
check 'repacked GNU compatibility name contains genuine gzip bytes' gzip -t "$INVERTED_OUTPUT/$GNU_COMPAT"
check 'repacked GNU primary and compatibility archive bytes agree' cmp -s \
    "$INVERTED_OUTPUT/$GNU_NAME" "$INVERTED_OUTPUT/$GNU_COMPAT"
check 'every inverted-format receipt and archive retains its own compiled variant' \
    verify_mixed_archives "$INVERTED_OUTPUT" gnu

printf '\nMulti-variant release: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
