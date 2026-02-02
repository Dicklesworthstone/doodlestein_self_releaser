#!/usr/bin/env bash
# e2e_release_parity.sh - E2E test for dsr release parity with GH Actions
#
# Run:
#   ./scripts/tests/e2e_release_parity.sh --repo owner/repo --local-path /path/to/repo
#
# Required environment (for real parity runs):
#   DSR_E2E_REPO          owner/repo (GitHub repo)
#   DSR_E2E_LOCAL_PATH    local clone path for the same repo
#
# Optional:
#   DSR_E2E_GHA_TAG       tag with GH Actions release (default: generated)
#   DSR_E2E_DSR_TAG       tag for dsr release (default: generated)
#   DSR_E2E_TARGETS       space-separated targets (default: linux/amd64 darwin/arm64 windows/amd64)
#   DSR_E2E_TRIGGER_GHA   set to 1 to push a tag and wait for GH Actions release
#   DSR_E2E_ALLOW_TAG_PUSH set to 1 to allow tag push
#   DSR_E2E_DRAFT         set to 1 to create dsr release as draft (default: 1)
#   DSR_E2E_KEEP_LOG      set to 1 to keep log file on success
#   DSR_E2E_KEEP_RELEASES set to 1 to keep created releases/tags
#   DSR_E2E_USE_FIXTURE   set to 1 to copy fixture into temp dir for local path

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSR_CMD="$PROJECT_ROOT/dsr"

VERBOSE=0
DEBUG=0
JSON_MODE=false

REPO="${DSR_E2E_REPO:-}"
LOCAL_PATH="${DSR_E2E_LOCAL_PATH:-}"
TOOL_NAME="${DSR_E2E_TOOL_NAME:-mock_release_tool}"
LANGUAGE="${DSR_E2E_LANGUAGE:-go}"
BUILD_CMD="${DSR_E2E_BUILD_CMD:-go build -o ${TOOL_NAME} ./cmd/${TOOL_NAME}}"
BINARY_NAME="${DSR_E2E_BINARY_NAME:-$TOOL_NAME}"
WORKFLOW_PATH="${DSR_E2E_WORKFLOW:-.github/workflows/release.yml}"
JOB_LINUX="${DSR_E2E_JOB_LINUX:-build-linux}"
JOB_DARWIN="${DSR_E2E_JOB_DARWIN:-build-darwin}"
JOB_WINDOWS="${DSR_E2E_JOB_WINDOWS:-build-windows}"
INSTALL_SCRIPT_PATH="${DSR_E2E_INSTALL_SCRIPT_PATH:-install.sh}"
TARGETS="${DSR_E2E_TARGETS:-linux/amd64 darwin/arm64 windows/amd64}"
GHA_TAG="${DSR_E2E_GHA_TAG:-}"
DSR_TAG="${DSR_E2E_DSR_TAG:-}"
TRIGGER_GHA="${DSR_E2E_TRIGGER_GHA:-0}"
ALLOW_TAG_PUSH="${DSR_E2E_ALLOW_TAG_PUSH:-0}"
DRAFT_RELEASE="${DSR_E2E_DRAFT:-1}"
KEEP_LOG="${DSR_E2E_KEEP_LOG:-0}"
KEEP_RELEASES="${DSR_E2E_KEEP_RELEASES:-0}"
USE_FIXTURE="${DSR_E2E_USE_FIXTURE:-0}"
WAIT_TIMEOUT="${DSR_E2E_WAIT_TIMEOUT:-900}"

LOG_FILE="${DSR_E2E_LOG_FILE:-/tmp/e2e_release_parity_$$.log}"
DSR_OUTPUT_LOG="${DSR_E2E_DSR_LOG_FILE:-/tmp/e2e_release_parity_dsr_$$.log}"

PHASE_RESULTS=()
TEST_START_MS=""
PHASE_START_MS=""
CURRENT_PHASE=""
CREATED_GHA_TAG=false
CREATED_DSR_RELEASE=false
checksum_details=()
compat_details=()

usage() {
  cat << 'USAGE'
Usage:
  e2e_release_parity.sh --repo owner/repo --local-path /path/to/repo [options]

Options:
  --repo <owner/repo>         GitHub repo
  --local-path <path>         Local clone path for repo
  --gha-tag <tag>             Tag for GH Actions release
  --dsr-tag <tag>             Tag for dsr release
  --targets <list>            Space-separated targets (default: linux/amd64 darwin/arm64 windows/amd64)
  --trigger-gha               Push tag and wait for GH Actions release
  --use-fixture               Copy fixture into temp dir (still requires --repo)
  --json                      Emit JSON output
  -v                          Verbose output
  -vv                         Debug output
  --keep-log                  Keep log file on success
  --keep-releases             Keep created releases/tags
  -h, --help                  Show help
USAGE
}

_now_ms() {
  local ms
  ms=$(date +%s%3N 2>/dev/null || true)
  if [[ "$ms" =~ ^[0-9]+$ ]]; then
    echo "$ms"
  else
    echo $(( $(date +%s) * 1000 ))
  fi
}

_json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

log_line() {
  local level="$1"
  shift
  local msg="$*"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if $JSON_MODE; then
    local esc_msg esc_level
    esc_msg=$(_json_escape "$msg")
    esc_level=$(_json_escape "$level")
    local line
    line=$(printf '{"ts":"%s","level":"%s","msg":"%s"}' "$ts" "$esc_level" "$esc_msg")
    echo "$line"
    echo "$line" >> "$LOG_FILE"
  else
    printf '[%s] E2E: %s\n' "$ts" "$msg" | tee -a "$LOG_FILE" >&2
  fi
}

phase_start() {
  CURRENT_PHASE="$1"
  PHASE_START_MS="$(_now_ms)"
  log_line "INFO" "Starting phase: $CURRENT_PHASE"
}

phase_end() {
  local status="$1"
  local extra_json="${2:-{}}"
  local end_ms duration_ms
  end_ms="$(_now_ms)"
  duration_ms=$((end_ms - PHASE_START_MS))

  log_line "INFO" "Phase $CURRENT_PHASE: $status (${duration_ms}ms)"

  local phase_json
  phase_json=$(jq -nc \
    --arg name "$CURRENT_PHASE" \
    --arg status "$status" \
    --argjson duration "$duration_ms" \
    --argjson extra "$extra_json" \
    '$extra + {name: $name, status: $status, duration_ms: $duration}')
  PHASE_RESULTS+=("$phase_json")
}

log_block() {
  local header="$1"
  local body="$2"
  if $JSON_MODE; then
    local esc_header esc_body
    esc_header=$(_json_escape "$header")
    esc_body=$(_json_escape "$body")
    local line
    line=$(printf '{\"ts\":\"%s\",\"level\":\"ERROR\",\"section\":\"%s\",\"body\":\"%s\"}' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$esc_header" "$esc_body")
    echo "$line"
    echo "$line" >> "$LOG_FILE"
  else
    {
      echo ""
      echo "=== $header ==="
      echo "$body"
    } | tee -a "$LOG_FILE" >&2
  fi
}

dump_failure_context() {
  if [[ -f "$DSR_OUTPUT_LOG" ]]; then
    log_block "dsr output (last 50 lines)" "$(tail -50 "$DSR_OUTPUT_LOG" 2>/dev/null || true)"
  fi

  if [[ -n "$REPO" && -n "$DSR_TAG" ]]; then
    log_block "gh release view (DSR)" "$(gh release view "$DSR_TAG" --repo "$REPO" 2>/dev/null || echo 'release not found')"
    log_block "DSR release assets" "$(gh api "repos/$REPO/releases/tags/$DSR_TAG" --jq '.assets[] | \"\\(.name)  (\\(.size) bytes)\"' 2>/dev/null || echo 'release not found')"
  fi

  if [[ -n "$REPO" && -n "$GHA_TAG" ]]; then
    log_block "gh release view (GHA)" "$(gh release view "$GHA_TAG" --repo "$REPO" 2>/dev/null || echo 'release not found')"
    log_block "GHA release assets" "$(gh api "repos/$REPO/releases/tags/$GHA_TAG" --jq '.assets[] | \"\\(.name)  (\\(.size) bytes)\"' 2>/dev/null || echo 'release not found')"
  fi

  if [[ ${#checksum_details[@]} -gt 0 ]]; then
    log_block "Checksum mismatches" "$(printf '%s\n' "${checksum_details[@]}")"
  fi
  if [[ ${#compat_details[@]} -gt 0 ]]; then
    log_block "Compat checksum mismatches" "$(printf '%s\n' "${compat_details[@]}")"
  fi
}

fail_phase() {
  local extra_json="${1:-{}}"
  phase_end "fail" "$extra_json"
  dump_failure_context
  exit 1
}

skip_test() {
  log_line "WARN" "SKIP: $1"
  exit 0
}

require_cmd() {
  local cmd="$1"
  local desc="$2"
  if ! command -v "$cmd" &>/dev/null; then
    skip_test "$desc not installed (missing $cmd)"
  fi
}

run_logged() {
  local log_file="$1"
  shift

  if $JSON_MODE; then
    "$@" >>"$log_file" 2>&1
    return $?
  fi

  if [[ "$DEBUG" -eq 1 ]]; then
    "$@" 2>&1 | tee -a "$log_file"
    return "${PIPESTATUS[0]}"
  fi

  "$@" >>"$log_file" 2>&1
  return $?
}

sha256_file() {
  local file="$1"
  if command -v sha256sum &>/dev/null; then
    sha256sum "$file" | awk '{print $1}'
  else
    shasum -a 256 "$file" | awk '{print $1}'
  fi
}

parse_asset_name() {
  local tool="$1"
  local name="$2"

  local ext base
  if [[ "$name" == *.tar.gz ]]; then
    ext="tar.gz"
    base="${name%.tar.gz}"
  elif [[ "$name" == *.zip ]]; then
    ext="zip"
    base="${name%.zip}"
  else
    return 1
  fi

  if [[ "$base" != "${tool}-"* ]]; then
    return 1
  fi

  local rest os arch version_part
  rest="${base#"${tool}"-}"
  arch="${rest##*-}"
  rest="${rest%-"${arch}"}"
  os="${rest##*-}"
  version_part="${rest%-"${os}"}"

  echo "$os|$arch|$ext|$version_part"
}

fetch_release_assets() {
  local repo="$1"
  local tag="$2"
  gh api "repos/$repo/releases/tags/$tag" --jq '.assets'
}

download_release_assets() {
  local repo="$1"
  local tag="$2"
  local dest_dir="$3"
  local tool="$4"
  local failed=0

  mkdir -p "$dest_dir"

  local assets_json
  assets_json=$(fetch_release_assets "$repo" "$tag" 2>/dev/null) || return 1

  echo "$assets_json" | jq -c '.[]' | while IFS= read -r asset; do
    local name id
    name=$(echo "$asset" | jq -r '.name')
    id=$(echo "$asset" | jq -r '.id')

    if [[ "$name" == ${tool}-* || "$name" == SHA256* || "$name" == sha256* ]]; then
      if [[ "$DEBUG" -eq 1 ]]; then
        log_line "DEBUG" "Downloading asset $name"
      fi
      if ! gh api \
        -H "Accept: application/octet-stream" \
        "repos/$repo/releases/assets/$id" \
        > "$dest_dir/$name"; then
        failed=1
      fi
    fi
  done

  return "$failed"
}

wait_for_release() {
  local repo="$1"
  local tag="$2"
  local timeout="$3"
  local start
  start=$(date +%s)

  while true; do
    if gh api "repos/$repo/releases/tags/$tag" &>/dev/null; then
      return 0
    fi

    local now
    now=$(date +%s)
    if (( now - start > timeout )); then
      return 1
    fi

    sleep 10
  done
}

create_repos_config() {
  local repo="$1"
  local local_path="$2"
  local config_dir="$3"

  mkdir -p "$config_dir/repos.d"

  cat > "$config_dir/config.yaml" << 'YAML'
schema_version: "1.0.0"
threshold_seconds: 600
log_level: info
signing:
  enabled: false
YAML

  cat > "$config_dir/hosts.yaml" << 'YAML'
hosts:
  trj:
    platform: linux/amd64
    connection: local
    capabilities:
      - docker
      - act
YAML

  cat > "$config_dir/repos.d/${TOOL_NAME}.yaml" << YAML
tool_name: ${TOOL_NAME}
repo: ${repo}
local_path: ${local_path}
language: ${LANGUAGE}
build_cmd: ${BUILD_CMD}
binary_name: ${BINARY_NAME}
targets:
  - linux/amd64
  - darwin/arm64
  - windows/amd64
workflow: ${WORKFLOW_PATH}
act_job_map:
  linux/amd64: ${JOB_LINUX}
  darwin/arm64: ${JOB_DARWIN}
  windows/amd64: ${JOB_WINDOWS}
artifact_naming: "\${name}-\${version}-\${os}-\${arch}"
install_script_compat: "\${name}-\${os}-\${arch}"
install_script_path: ${INSTALL_SCRIPT_PATH}
YAML
}

# shellcheck disable=SC2317
cleanup() {
  local exit_code=$?

  if [[ "$exit_code" -ne 0 ]]; then
    log_line "ERROR" "Test failed. Log preserved at: $LOG_FILE"
  elif [[ "$KEEP_LOG" != "1" ]]; then
    rm -f "$LOG_FILE" 2>/dev/null || true
  fi

  if [[ "$KEEP_RELEASES" != "1" ]]; then
    if $CREATED_DSR_RELEASE; then
      gh release delete "$DSR_TAG" --repo "$REPO" --yes 2>/dev/null || true
    fi
    if $CREATED_GHA_TAG; then
      gh release delete "$GHA_TAG" --repo "$REPO" --yes 2>/dev/null || true
    fi
  fi

  if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR" 2>/dev/null || true
  fi

  if [[ -n "${FIXTURE_TMP_DIR:-}" && -d "$FIXTURE_TMP_DIR" ]]; then
    rm -rf "$FIXTURE_TMP_DIR" 2>/dev/null || true
  fi

  return "$exit_code"
}
trap cleanup EXIT

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO="$2"
      shift 2
      ;;
    --local-path)
      LOCAL_PATH="$2"
      shift 2
      ;;
    --gha-tag)
      GHA_TAG="$2"
      shift 2
      ;;
    --dsr-tag)
      DSR_TAG="$2"
      shift 2
      ;;
    --targets)
      TARGETS="$2"
      shift 2
      ;;
    --trigger-gha)
      TRIGGER_GHA=1
      shift
      ;;
    --use-fixture)
      USE_FIXTURE=1
      shift
      ;;
    --json)
      JSON_MODE=true
      shift
      ;;
    -v)
      VERBOSE=1
      shift
      ;;
    -vv)
      VERBOSE=1
      DEBUG=1
      shift
      ;;
    --keep-log)
      KEEP_LOG=1
      shift
      ;;
    --keep-releases)
      KEEP_RELEASES=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log_line "ERROR" "Unknown option: $1"
      usage
      exit 1
      ;;
  esac
done

TEST_START_MS="$(_now_ms)"

# Prereqs
require_cmd gh "gh"
require_cmd jq "jq"
require_cmd yq "yq"
require_cmd git "git"
require_cmd act "act"
require_cmd docker "docker"
require_cmd curl "curl"

if [[ -z "$REPO" ]]; then
  skip_test "DSR_E2E_REPO not set"
fi

if [[ -z "$LOCAL_PATH" ]]; then
  if [[ "$USE_FIXTURE" == "1" ]]; then
    FIXTURE_TMP_DIR="$(mktemp -d)"
    cp -r "$SCRIPT_DIR/fixtures/mock_release_tool/." "$FIXTURE_TMP_DIR/" || {
      log_line "ERROR" "Failed to copy fixture"
      exit 1
    }
    git -C "$FIXTURE_TMP_DIR" init -q 2>/dev/null || true
    git -C "$FIXTURE_TMP_DIR" add . 2>/dev/null || true
    git -C "$FIXTURE_TMP_DIR" commit -q -m "fixture" 2>/dev/null || true
    LOCAL_PATH="$FIXTURE_TMP_DIR"
  else
    skip_test "DSR_E2E_LOCAL_PATH not set"
  fi
fi

if [[ ! -d "$LOCAL_PATH/.git" ]]; then
  skip_test "Local path is not a git repo: $LOCAL_PATH"
fi

# Best-effort remote validation
remote_url=$(git -C "$LOCAL_PATH" remote get-url origin 2>/dev/null || true)
if [[ -n "$remote_url" && "$remote_url" != *"$REPO"* ]]; then
  log_line "WARN" "Local repo origin does not match $REPO (origin: $remote_url)"
fi

if [[ -z "$GHA_TAG" ]]; then
  if [[ "$TRIGGER_GHA" == "1" ]]; then
    GHA_TAG="v0.0.1-gha-$(date +%s)"
  else
    skip_test "GHA tag not provided and --trigger-gha not set"
  fi
fi

if [[ -z "$DSR_TAG" ]]; then
  DSR_TAG="v0.0.1-dsr-$(date +%s)"
fi

WORK_DIR="$(mktemp -d)"
export DSR_CONFIG_DIR="$WORK_DIR/config"
export DSR_STATE_DIR="$WORK_DIR/state"
export DSR_CACHE_DIR="$WORK_DIR/cache"

create_repos_config "$REPO" "$LOCAL_PATH" "$DSR_CONFIG_DIR"

log_line "INFO" "E2E release parity test starting"
log_line "INFO" "Repo: $REPO"
log_line "INFO" "Local path: $LOCAL_PATH"
log_line "INFO" "GH tag: $GHA_TAG"
log_line "INFO" "DSR tag: $DSR_TAG"
if [[ "$VERBOSE" -eq 1 ]]; then
  log_line "INFO" "Targets: $TARGETS"
  log_line "INFO" "Config dir: $DSR_CONFIG_DIR"
fi

# Ensure dsr tag exists locally (required by dsr release)
if ! git -C "$LOCAL_PATH" tag -l "$DSR_TAG" | grep -q "^${DSR_TAG}$"; then
  if git -C "$LOCAL_PATH" tag "$DSR_TAG" 2>/dev/null; then
    if [[ "$DEBUG" -eq 1 ]]; then
      log_line "DEBUG" "Created local tag $DSR_TAG"
    fi
  else
    log_line "ERROR" "Failed to create local tag $DSR_TAG"
    exit 1
  fi
fi

# Optional: trigger GH Actions release
if [[ "$TRIGGER_GHA" == "1" ]]; then
  if [[ "$ALLOW_TAG_PUSH" != "1" ]]; then
    skip_test "DSR_E2E_ALLOW_TAG_PUSH=1 required to push tags"
  fi

  phase_start "trigger_gha"

  if git -C "$LOCAL_PATH" tag "$GHA_TAG" 2>/dev/null; then
    if git -C "$LOCAL_PATH" push origin "$GHA_TAG" 2>/dev/null; then
      CREATED_GHA_TAG=true
      if wait_for_release "$REPO" "$GHA_TAG" "$WAIT_TIMEOUT"; then
        phase_end "pass" "{\"tag\": \"$GHA_TAG\"}"
      else
        fail_phase "{\"tag\": \"$GHA_TAG\", \"error\": \"timeout\"}"
      fi
    else
      fail_phase "{\"error\": \"failed to push tag\"}"
    fi
  else
    fail_phase "{\"error\": \"failed to create tag\"}"
  fi
fi

# Build with dsr
phase_start "build"
if run_logged "$DSR_OUTPUT_LOG" "$DSR_CMD" build --tool "$TOOL_NAME" --version "$DSR_TAG" --targets "$(echo "$TARGETS" | tr ' ' ',')"; then
  phase_end "pass" "{}"
else
  fail_phase "{}"
fi

# Release with dsr
phase_start "release"
if [[ "$DRAFT_RELEASE" == "1" ]]; then
  release_args=(--draft)
else
  release_args=()
fi

if run_logged "$DSR_OUTPUT_LOG" "$DSR_CMD" release --tool "$TOOL_NAME" --version "$DSR_TAG" "${release_args[@]}"; then
  CREATED_DSR_RELEASE=true
  phase_end "pass" "{}"
else
  fail_phase "{}"
fi

# Verify versioned assets exist
phase_start "verify_versioned"
assets_dsr=$(fetch_release_assets "$REPO" "$DSR_TAG" 2>/dev/null || true)
assets_gha=$(fetch_release_assets "$REPO" "$GHA_TAG" 2>/dev/null || true)

if [[ -z "$assets_dsr" || -z "$assets_gha" ]]; then
  fail_phase "{\"error\": \"missing release assets\"}"
fi

missing_versioned=()
for target in $TARGETS; do
  os="${target%/*}"
  arch="${target#*/}"
  expected="${TOOL_NAME}-${DSR_TAG}-${os}-${arch}"
  expected_gha="${TOOL_NAME}-${GHA_TAG}-${os}-${arch}"

  if [[ "$VERBOSE" -eq 1 ]]; then
    log_line "INFO" "Checking versioned asset: $expected"
  fi
  if ! echo "$assets_dsr" | jq -e --arg name "$expected" '.[] | select(.name | startswith($name))' >/dev/null 2>&1; then
    missing_versioned+=("$expected")
  fi

  if [[ "$VERBOSE" -eq 1 ]]; then
    log_line "INFO" "Checking GHA asset: $expected_gha"
  fi
  if ! echo "$assets_gha" | jq -e --arg name "$expected_gha" '.[] | select(.name | startswith($name))' >/dev/null 2>&1; then
    missing_versioned+=("$expected_gha")
  fi
done

if [[ ${#missing_versioned[@]} -gt 0 ]]; then
  fail_phase "{\"missing\": $(printf '%s\n' "${missing_versioned[@]}" | jq -R . | jq -sc '.') }"
fi
assets_checked=$(echo "$TARGETS" | wc -w | tr -d ' ')
phase_end "pass" "{\"assets_checked\": ${assets_checked}}"

# Verify compat assets exist in dsr release
phase_start "verify_compat"
missing_compat=()
for target in $TARGETS; do
  os="${target%/*}"
  arch="${target#*/}"
  expected="${TOOL_NAME}-${os}-${arch}"
  if [[ "$VERBOSE" -eq 1 ]]; then
    log_line "INFO" "Checking compat asset: $expected"
  fi
  if ! echo "$assets_dsr" | jq -e --arg name "$expected" '.[] | select(.name | startswith($name))' >/dev/null 2>&1; then
    missing_compat+=("$expected")
  fi
done

if [[ ${#missing_compat[@]} -gt 0 ]]; then
  fail_phase "{\"missing\": $(printf '%s\n' "${missing_compat[@]}" | jq -R . | jq -sc '.') }"
fi
phase_end "pass" "{\"assets_checked\": ${assets_checked}}"

# Verify install.sh works
phase_start "verify_install"
INSTALL_DIR="$WORK_DIR/install"
mkdir -p "$INSTALL_DIR"

install_script="$LOCAL_PATH/$INSTALL_SCRIPT_PATH"
if [[ ! -f "$install_script" ]]; then
  fail_phase "{\"error\": \"install script not found\"}"
fi

MOCK_RELEASE_REPO="$REPO" run_logged "$DSR_OUTPUT_LOG" bash "$install_script" --version "$DSR_TAG" --dir "$INSTALL_DIR" || {
  fail_phase "{\"error\": \"install failed\"}"
}

if [[ -x "$INSTALL_DIR/$TOOL_NAME" ]]; then
  "$INSTALL_DIR/$TOOL_NAME" >/dev/null 2>&1 || {
    fail_phase "{\"error\": \"installed binary failed to run\"}"
  }
fi
phase_end "pass" "{\"binary_works\": true}"

# Compare checksums between GH Actions and dsr releases
phase_start "verify_checksums"
DSR_ASSET_DIR="$WORK_DIR/dsr_assets"
GHA_ASSET_DIR="$WORK_DIR/gha_assets"

if ! download_release_assets "$REPO" "$DSR_TAG" "$DSR_ASSET_DIR" "$TOOL_NAME"; then
  fail_phase "{\"error\": \"failed to download dsr assets\"}"
fi
if ! download_release_assets "$REPO" "$GHA_TAG" "$GHA_ASSET_DIR" "$TOOL_NAME"; then
  fail_phase "{\"error\": \"failed to download gha assets\"}"
fi

declare -A dsr_versioned
declare -A dsr_compat
declare -A gha_versioned

for file in "$DSR_ASSET_DIR"/*; do
  [[ -f "$file" ]] || continue
  name=$(basename "$file")
  parsed=$(parse_asset_name "$TOOL_NAME" "$name" || true)
  [[ -z "$parsed" ]] && continue
  IFS='|' read -r os arch ext version_part <<< "$parsed"
  key="${os}/${arch}"
  if [[ -n "$version_part" ]]; then
    dsr_versioned[$key]="$file"
  else
    dsr_compat[$key]="$file"
  fi
done

for file in "$GHA_ASSET_DIR"/*; do
  [[ -f "$file" ]] || continue
  name=$(basename "$file")
  parsed=$(parse_asset_name "$TOOL_NAME" "$name" || true)
  [[ -z "$parsed" ]] && continue
  IFS='|' read -r os arch ext version_part <<< "$parsed"
  key="${os}/${arch}"
  if [[ -n "$version_part" ]]; then
    gha_versioned[$key]="$file"
  fi
done

checksum_mismatches=()
compat_mismatches=()
checksum_details=()
compat_details=()
for target in $TARGETS; do
  key="$target"
  if [[ "$VERBOSE" -eq 1 ]]; then
    log_line "INFO" "Comparing checksums for $key"
  fi
  if [[ -n "${dsr_versioned[$key]:-}" && -n "${gha_versioned[$key]:-}" ]]; then
    dsr_sum=$(sha256_file "${dsr_versioned[$key]}")
    gha_sum=$(sha256_file "${gha_versioned[$key]}")
    if [[ "$dsr_sum" != "$gha_sum" ]]; then
      checksum_mismatches+=("$key")
      checksum_details+=("$key dsr=$dsr_sum gha=$gha_sum")
    fi
  fi

  if [[ -n "${dsr_versioned[$key]:-}" && -n "${dsr_compat[$key]:-}" ]]; then
    dsr_sum=$(sha256_file "${dsr_versioned[$key]}")
    compat_sum=$(sha256_file "${dsr_compat[$key]}")
    if [[ "$dsr_sum" != "$compat_sum" ]]; then
      compat_mismatches+=("$key")
      compat_details+=("$key dsr=$dsr_sum compat=$compat_sum")
    fi
  fi
done

if [[ ${#checksum_mismatches[@]} -gt 0 || ${#compat_mismatches[@]} -gt 0 ]]; then
  fail_phase "{\"checksum_mismatches\": $(printf '%s\n' "${checksum_mismatches[@]}" | jq -R . | jq -sc '.'), \"compat_mismatches\": $(printf '%s\n' "${compat_mismatches[@]}" | jq -R . | jq -sc '.'), \"checksum_details\": $(printf '%s\n' "${checksum_details[@]}" | jq -R . | jq -sc '.'), \"compat_details\": $(printf '%s\n' "${compat_details[@]}" | jq -R . | jq -sc '.') }"
fi
phase_end "pass" "{\"all_match\": true}"

# Summary
TOTAL_DURATION_MS=$(( $(_now_ms) - TEST_START_MS ))

if $JSON_MODE; then
  phases_json=$(printf '%s\n' "${PHASE_RESULTS[@]}" | jq -s '.')
  jq -nc \
    --arg test "e2e_release_parity" \
    --arg version "$DSR_TAG" \
    --argjson phases "$phases_json" \
    --arg result "PASS" \
    --argjson total_duration_ms "$TOTAL_DURATION_MS" \
    '{test: $test, version: $version, phases: $phases, result: $result, total_duration_ms: $total_duration_ms}'
else
  log_line "INFO" "E2E: PASSED (${TOTAL_DURATION_MS}ms total)"
fi

exit 0
