#!/usr/bin/env bash
# test_act_orchestration.sh - Tests for hybrid build orchestration functions
#
# These tests verify the orchestration layer that coordinates act + SSH builds

set -uo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

pass() { echo -e "${GREEN}✓${NC} $1"; ((PASS++)); }
fail() { echo -e "${RED}✗${NC} $1"; ((FAIL++)); }
skip() { echo -e "${YELLOW}○${NC} $1"; ((SKIP++)); }

# Setup test environment BEFORE sourcing (critical for config path resolution)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEMP_DIR=$(mktemp -d)

# These MUST be set before sourcing act_runner.sh as it calculates paths at load time
export DSR_STATE_DIR="$TEMP_DIR/state"
export DSR_CACHE_DIR="$TEMP_DIR/cache"
export DSR_CONFIG_DIR="$TEMP_DIR/config"

mkdir -p "$DSR_STATE_DIR" "$DSR_CACHE_DIR" "$DSR_CONFIG_DIR/repos.d"

# Source the modules (order matters - config dirs must be set first)
source "$SCRIPT_DIR/src/logging.sh"
source "$SCRIPT_DIR/src/build_state.sh"
source "$SCRIPT_DIR/src/act_runner.sh"

# Verify ACT_REPOS_DIR is correctly set from DSR_CONFIG_DIR
ACT_REPOS_DIR="$DSR_CONFIG_DIR/repos.d"

# Initialize logging (suppress output)
export LOG_LEVEL=0  # shellcheck: used by logging.sh
log_init >/dev/null 2>&1

echo "═══════════════════════════════════════════════════════════════"
echo "  Hybrid Build Orchestration Tests"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Check if yq is available (required for YAML parsing)
if ! command -v yq &>/dev/null; then
    skip "yq not installed - skipping YAML-dependent tests"
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Summary"
    echo "═══════════════════════════════════════════════════════════════"
    echo -e "  ${GREEN}Passed:${NC}  $PASS"
    echo -e "  ${RED}Failed:${NC}  $FAIL"
    echo -e "  ${YELLOW}Skipped:${NC} $SKIP"
    echo ""
    echo "Note: Install yq to run full test suite: sudo snap install yq"
    exit 0
fi

# Create a test config
cat > "$ACT_REPOS_DIR/testool.yaml" << 'EOF'
tool_name: testool
repo: Test/testool
local_path: /tmp/testool
language: go
binary_name: testool
build_cmd: echo "building testool"
targets:
  - linux/amd64
  - darwin/arm64
  - windows/amd64
workflow: .github/workflows/release.yml
act_job_map:
  linux/amd64: build
  darwin/arm64: null
  windows/amd64: null
env:
  CGO_ENABLED: "0"
cross_compile:
  darwin/arm64:
    method: native
    env:
      GOOS: darwin
      GOARCH: arm64
EOF

echo "== act_get_build_cmd =="

# Test get_build_cmd
build_cmd=$(act_get_build_cmd "testool")
if [[ "$build_cmd" == 'echo "building testool"' ]]; then
    pass "act_get_build_cmd returns correct command"
else
    fail "act_get_build_cmd returned: $build_cmd"
fi

# Test missing tool
if ! act_get_build_cmd "nonexistent" &>/dev/null; then
    pass "act_get_build_cmd returns error for missing tool"
else
    fail "act_get_build_cmd should fail for missing tool"
fi

echo ""
echo "== act_get_build_env =="

# Test global env
env_vars=$(act_get_build_env "testool" "linux/amd64")
if [[ "$env_vars" == *"CGO_ENABLED=0"* ]]; then
    pass "act_get_build_env returns global env vars"
else
    fail "act_get_build_env missing global env: $env_vars"
fi

# Test platform-specific env
env_vars=$(act_get_build_env "testool" "darwin/arm64")
if [[ "$env_vars" == *"GOOS=darwin"* ]] && [[ "$env_vars" == *"GOARCH=arm64"* ]]; then
    pass "act_get_build_env returns platform-specific env vars"
else
    fail "act_get_build_env missing platform env: $env_vars"
fi

echo ""
echo "== act_get_local_path =="

local_path=$(act_get_local_path "testool")
if [[ "$local_path" == "/tmp/testool" ]]; then
    pass "act_get_local_path returns correct path"
else
    fail "act_get_local_path returned: $local_path"
fi

echo ""
echo "== act_get_build_strategy =="

# Test act strategy
strategy=$(act_get_build_strategy "testool" "linux/amd64")
method=$(echo "$strategy" | jq -r '.method')
job=$(echo "$strategy" | jq -r '.job')
if [[ "$method" == "act" ]] && [[ "$job" == "build" ]]; then
    pass "act_get_build_strategy returns act method for linux"
else
    fail "act_get_build_strategy returned: $strategy"
fi

# Test native strategy
strategy=$(act_get_build_strategy "testool" "darwin/arm64")
method=$(echo "$strategy" | jq -r '.method')
host=$(echo "$strategy" | jq -r '.host')
if [[ "$method" == "native" ]] && [[ "$host" == "mmini" ]]; then
    pass "act_get_build_strategy returns native method for darwin"
else
    fail "act_get_build_strategy returned: $strategy"
fi

echo ""
echo "== act_build_matrix =="

matrix=$(act_build_matrix "testool")
count=$(echo "$matrix" | jq 'length')
if [[ "$count" -eq 3 ]]; then
    pass "act_build_matrix returns all 3 targets"
else
    fail "act_build_matrix returned $count targets"
fi

echo ""
echo "== act_generate_manifest =="

# Test manifest generation
test_result='{"tool":"testool","version":"v1.0.0","run_id":"test-run","status":"success","targets":[{"platform":"linux/amd64","host":"trj","method":"act","status":"success","artifact_path":"/tmp/testool","duration_seconds":10}]}'
manifest=$(act_generate_manifest "$test_result" "")
schema_ver=$(echo "$manifest" | jq -r '.schema_version')
artifacts_count=$(echo "$manifest" | jq '.artifacts | length')

if [[ "$schema_ver" == "1.0.0" ]] && [[ "$artifacts_count" -eq 1 ]]; then
    pass "act_generate_manifest generates valid manifest"
else
    fail "act_generate_manifest returned invalid manifest"
fi

# Cleanup
rm -rf "$TEMP_DIR"

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Summary"
echo "═══════════════════════════════════════════════════════════════"
echo -e "  ${GREEN}Passed:${NC}  $PASS"
echo -e "  ${RED}Failed:${NC}  $FAIL"
echo -e "  ${YELLOW}Skipped:${NC} $SKIP"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
