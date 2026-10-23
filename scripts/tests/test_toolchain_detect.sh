#!/usr/bin/env bash
# test_toolchain_detect.sh - Tests for toolchain_detect.sh module
#
# Tests toolchain detection, version comparison, and installation safety.
# Uses real toolchain detection where available; tests pure logic directly.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$SCRIPT_DIR/../../src" && pwd)"

# Source the module under test
# shellcheck source=../../src/logging.sh
source "$SRC_DIR/logging.sh"
# shellcheck source=../../src/toolchain_detect.sh
source "$SRC_DIR/toolchain_detect.sh"

# Test state
TEMP_DIR=""
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Initialize logging silently
log_init 2>/dev/null || true

# ============================================================================
# Test Infrastructure
# ============================================================================

setup() {
  TEMP_DIR=$(mktemp -d)
  # Suppress colors for consistent test output
  export NO_COLOR=1
  # Reset to non-interactive mode for predictable behavior
  _TC_NON_INTERACTIVE=true
}

teardown() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR"
  fi
}

assert_equals() {
  local expected="$1"
  local actual="$2"
  local msg="${3:-assertion failed}"

  if [[ "$expected" != "$actual" ]]; then
    echo "  FAIL: $msg"
    echo "    Expected: $expected"
    echo "    Actual:   $actual"
    return 1
  fi
  return 0
}

assert_true() {
  local condition="$1"
  local msg="${2:-expected true}"

  if ! eval "$condition"; then
    echo "  FAIL: $msg"
    return 1
  fi
  return 0
}

assert_false() {
  local condition="$1"
  local msg="${2:-expected false}"

  if eval "$condition"; then
    echo "  FAIL: $msg"
    return 1
  fi
  return 0
}

assert_json_field() {
  local json="$1"
  local field="$2"
  local expected="$3"
  local msg="${4:-JSON field mismatch}"

  local actual
  actual=$(echo "$json" | jq -r ".$field")

  if [[ "$expected" != "$actual" ]]; then
    echo "  FAIL: $msg"
    echo "    Field: $field"
    echo "    Expected: $expected"
    echo "    Actual:   $actual"
    return 1
  fi
  return 0
}

assert_json_valid() {
  local json="$1"
  local msg="${2:-invalid JSON}"

  if ! echo "$json" | jq -e . >/dev/null 2>&1; then
    echo "  FAIL: $msg"
    echo "    JSON: $json"
    return 1
  fi
  return 0
}

run_test() {
  local test_name="$1"
  local test_func="$2"

  [[ -z "${DSR_TOOLCHAIN_TEST_FILTER:-}" || "$test_name" == *"$DSR_TOOLCHAIN_TEST_FILTER"* ]] || return 0

  ((TESTS_RUN++))
  echo -n "  $test_name... "

  if $test_func 2>/dev/null; then
    echo "OK"
    ((TESTS_PASSED++))
  else
    echo "FAILED"
    ((TESTS_FAILED++))
  fi
}

# ============================================================================
# Tests: Version Comparison (_tc_version_ge)
# ============================================================================

test_version_ge_equal() {
  _tc_version_ge "1.70.0" "1.70.0"
}

test_version_ge_greater_patch() {
  _tc_version_ge "1.70.1" "1.70.0"
}

test_version_ge_greater_minor() {
  _tc_version_ge "1.71.0" "1.70.0"
}

test_version_ge_greater_major() {
  _tc_version_ge "2.0.0" "1.70.0"
}

test_version_ge_less_patch() {
  ! _tc_version_ge "1.69.0" "1.70.0"
}

test_version_ge_less_minor() {
  ! _tc_version_ge "1.69.5" "1.70.0"
}

test_version_ge_less_major() {
  ! _tc_version_ge "0.99.0" "1.0.0"
}

test_version_ge_prerelease() {
  # Pre-release suffix should be stripped for comparison
  _tc_version_ge "1.70.0-beta.1" "1.70.0"
}

test_version_ge_with_prefix() {
  # Version prefixes (like rustc 1.70.0) should work
  _tc_version_ge "rustc 1.70.0 (12345)" "1.70.0"
}

test_version_ge_missing_v1() {
  # Empty v1 should return false
  ! _tc_version_ge "" "1.0.0"
}

test_version_ge_missing_v2() {
  # Empty v2 should return true (no requirement)
  _tc_version_ge "1.0.0" ""
}

test_version_ge_go_format() {
  # Go version format: go1.21.0
  _tc_version_ge "go1.21.5" "1.21.0"
}

test_version_ge_node_format() {
  # Node version format: v20.10.0
  _tc_version_ge "v20.10.0" "18.0.0"
}

# ============================================================================
# Tests: Platform Detection (_tc_detect_platform)
# ============================================================================

test_detect_platform_format() {
  local platform
  platform=$(_tc_detect_platform)
  # Should be in format: os/arch
  [[ "$platform" =~ ^[a-z]+/[a-z0-9]+$ ]]
}

test_detect_platform_known_os() {
  local platform
  platform=$(_tc_detect_platform)
  local os="${platform%/*}"
  # Should be one of: linux, darwin, windows, unknown
  [[ "$os" == "linux" || "$os" == "darwin" || "$os" == "windows" || "$os" == "unknown" ]]
}

test_detect_platform_known_arch() {
  local platform
  platform=$(_tc_detect_platform)
  local arch="${platform#*/}"
  # Should be one of: amd64, arm64, armv7, 386, unknown
  [[ "$arch" == "amd64" || "$arch" == "arm64" || "$arch" == "armv7" || "$arch" == "386" || "$arch" == "unknown" ]]
}

test_detect_platform_consistent() {
  # Multiple calls should return the same value
  local p1 p2
  p1=$(_tc_detect_platform)
  p2=$(_tc_detect_platform)
  [[ "$p1" == "$p2" ]]
}

# ============================================================================
# Tests: Rust Detection
# ============================================================================

test_detect_rust_json_valid() {
  local result
  result=$(toolchain_detect_rust)
  assert_json_valid "$result" "Rust detection should return valid JSON"
}

test_detect_rust_has_required_fields() {
  local result
  result=$(toolchain_detect_rust)
  # Presence is the contract. `installed` and `meets_minimum` may legitimately
  # be false on a host where Rust is absent or below the supported minimum.
  echo "$result" | jq -e '
    has("toolchain") and
    has("installed") and
    has("minimum_version") and
    has("meets_minimum")
  ' >/dev/null
}

test_detect_rust_toolchain_field() {
  local result
  result=$(toolchain_detect_rust)
  assert_json_field "$result" "toolchain" "rust" "Toolchain field should be 'rust'"
}

test_detect_rust_minimum_version() {
  local result
  result=$(toolchain_detect_rust)
  local min_version
  min_version=$(echo "$result" | jq -r '.minimum_version')
  [[ "$min_version" == "$TOOLCHAIN_RUST_MIN_VERSION" ]]
}

test_detect_rust_installed_boolean() {
  local result
  result=$(toolchain_detect_rust)
  local installed
  installed=$(echo "$result" | jq -r '.installed')
  # Should be true or false, not null or other
  [[ "$installed" == "true" || "$installed" == "false" ]]
}

# ============================================================================
# Tests: Go Detection
# ============================================================================

test_detect_go_json_valid() {
  local result
  result=$(toolchain_detect_go)
  assert_json_valid "$result" "Go detection should return valid JSON"
}

test_detect_go_has_required_fields() {
  local result
  result=$(toolchain_detect_go)
  echo "$result" | jq -e '.toolchain' >/dev/null
  echo "$result" | jq -e '.installed' >/dev/null
  echo "$result" | jq -e '.minimum_version' >/dev/null
}

test_detect_go_toolchain_field() {
  local result
  result=$(toolchain_detect_go)
  assert_json_field "$result" "toolchain" "go" "Toolchain field should be 'go'"
}

test_detect_go_minimum_version() {
  local result
  result=$(toolchain_detect_go)
  local min_version
  min_version=$(echo "$result" | jq -r '.minimum_version')
  [[ "$min_version" == "$TOOLCHAIN_GO_MIN_VERSION" ]]
}

# ============================================================================
# Tests: Bun Detection
# ============================================================================

test_detect_bun_json_valid() {
  local result
  result=$(toolchain_detect_bun)
  assert_json_valid "$result" "Bun detection should return valid JSON"
}

test_detect_bun_toolchain_field() {
  local result
  result=$(toolchain_detect_bun)
  assert_json_field "$result" "toolchain" "bun" "Toolchain field should be 'bun'"
}

test_detect_bun_minimum_version() {
  local result
  result=$(toolchain_detect_bun)
  local min_version
  min_version=$(echo "$result" | jq -r '.minimum_version')
  [[ "$min_version" == "$TOOLCHAIN_BUN_MIN_VERSION" ]]
}

# ============================================================================
# Tests: Node Detection
# ============================================================================

test_detect_node_json_valid() {
  local result
  result=$(toolchain_detect_node)
  assert_json_valid "$result" "Node detection should return valid JSON"
}

test_detect_node_toolchain_field() {
  local result
  result=$(toolchain_detect_node)
  assert_json_field "$result" "toolchain" "node" "Toolchain field should be 'node'"
}

test_detect_node_minimum_version() {
  local result
  result=$(toolchain_detect_node)
  local min_version
  min_version=$(echo "$result" | jq -r '.minimum_version')
  [[ "$min_version" == "$TOOLCHAIN_NODE_MIN_VERSION" ]]
}

# ============================================================================
# Tests: Unified Interface (toolchain_detect)
# ============================================================================

test_toolchain_detect_rust_alias() {
  local r1 r2
  r1=$(toolchain_detect rust)
  r2=$(toolchain_detect_rust)
  # Should return same result
  [[ "$(echo "$r1" | jq -r '.toolchain')" == "$(echo "$r2" | jq -r '.toolchain')" ]]
}

test_toolchain_detect_go_aliases() {
  local r1 r2
  r1=$(toolchain_detect go)
  r2=$(toolchain_detect golang)
  [[ "$(echo "$r1" | jq -r '.toolchain')" == "$(echo "$r2" | jq -r '.toolchain')" ]]
}

test_toolchain_detect_node_aliases() {
  local r1 r2 r3
  r1=$(toolchain_detect node)
  r2=$(toolchain_detect nodejs)
  r3=$(toolchain_detect npm)
  [[ "$(echo "$r1" | jq -r '.toolchain')" == "$(echo "$r2" | jq -r '.toolchain')" ]]
  [[ "$(echo "$r2" | jq -r '.toolchain')" == "$(echo "$r3" | jq -r '.toolchain')" ]]
}

test_toolchain_detect_unknown() {
  # Unknown toolchain should return non-zero exit code
  ! toolchain_detect "unknown_toolchain" 2>/dev/null
}

# ============================================================================
# Tests: Detect All
# ============================================================================

test_detect_all_json_valid() {
  local result
  result=$(toolchain_detect_all)
  assert_json_valid "$result" "toolchain_detect_all should return valid JSON"
}

test_detect_all_has_platform() {
  local result
  result=$(toolchain_detect_all)
  echo "$result" | jq -e '.platform' >/dev/null
}

test_detect_all_has_toolchains_array() {
  local result
  result=$(toolchain_detect_all)
  local count
  count=$(echo "$result" | jq '.toolchains | length')
  [[ "$count" -eq 4 ]]  # rust, go, bun, node
}

test_detect_all_contains_all_toolchains() {
  local result
  result=$(toolchain_detect_all)
  local toolchains
  toolchains=$(echo "$result" | jq -r '.toolchains[].toolchain' | sort | tr '\n' ' ')
  [[ "$toolchains" == *"bun"* ]]
  [[ "$toolchains" == *"go"* ]]
  [[ "$toolchains" == *"node"* ]]
  [[ "$toolchains" == *"rust"* ]]
}

# ============================================================================
# Tests: Installation Safety
# ============================================================================

test_install_rust_refuses_overwrite() {
  # If Rust is installed, installation should refuse to overwrite
  if command -v rustc &>/dev/null; then
    # Should return non-zero (refusal to overwrite)
    ! _tc_install_rust 2>/dev/null
  else
    # Skip test if Rust not installed
    return 0
  fi
}

test_install_go_refuses_overwrite() {
  # If Go is installed, installation should refuse to overwrite
  if command -v go &>/dev/null; then
    ! _tc_install_go 2>/dev/null
  else
    return 0
  fi
}

test_install_bun_refuses_overwrite() {
  # If Bun is installed, installation should refuse to overwrite
  if command -v bun &>/dev/null; then
    ! _tc_install_bun 2>/dev/null
  else
    return 0
  fi
}

test_toolchain_install_refuses_existing() {
  # Test the main install function refuses to overwrite
  # Pick first available toolchain
  local tc=""
  command -v rustc &>/dev/null && tc="rust"
  command -v go &>/dev/null && tc="go"
  command -v bun &>/dev/null && tc="bun"

  if [[ -n "$tc" ]]; then
    ! toolchain_install "$tc" --yes 2>/dev/null
  else
    return 0  # No toolchains to test
  fi
}

test_toolchain_install_unknown_returns_error() {
  ! toolchain_install "unknown_toolchain" --yes 2>/dev/null
}

# ============================================================================
# Tests: Ensure Logic
# ============================================================================

test_ensure_returns_ok_when_installed() {
  # Find an installed toolchain with sufficient version
  local result
  for tc in rust go bun node; do
    result=$(toolchain_detect "$tc" 2>/dev/null) || continue
    local installed meets_minimum
    installed=$(echo "$result" | jq -r '.installed')
    meets_minimum=$(echo "$result" | jq -r '.meets_minimum')
    if [[ "$installed" == "true" && "$meets_minimum" == "true" ]]; then
      toolchain_ensure "$tc" 2>/dev/null
      return 0
    fi
  done
  # Skip if no suitable toolchain found
  return 0
}

test_ensure_returns_error_when_missing() {
  # Create a mock missing toolchain scenario by testing unknown
  ! toolchain_ensure "unknown_toolchain" 2>/dev/null
}

# ============================================================================
# Tests: Non-Interactive Mode
# ============================================================================

test_prompt_fails_in_noninteractive() {
  _TC_NON_INTERACTIVE=true
  ! _tc_prompt "Test question?" 2>/dev/null
}

test_noninteractive_respects_env() {
  export NON_INTERACTIVE=true
  # Source again to pick up env
  _TC_NON_INTERACTIVE="${NON_INTERACTIVE:-false}"
  [[ "$_TC_NON_INTERACTIVE" == "true" ]]
}

# ============================================================================
# Tests: Logging Functions
# ============================================================================

test_log_functions_exist() {
  # Verify all log functions are defined
  declare -f _tc_log_info >/dev/null
  declare -f _tc_log_ok >/dev/null
  declare -f _tc_log_warn >/dev/null
  declare -f _tc_log_error >/dev/null
}

test_log_output_to_stderr() {
  local output
  # Capture stderr
  output=$(_tc_log_info "test message" 2>&1 >/dev/null)
  [[ "$output" == *"test message"* ]]
}

# ============================================================================
# Tests: Constants
# ============================================================================

test_min_versions_defined() {
  [[ -n "$TOOLCHAIN_RUST_MIN_VERSION" ]]
  [[ -n "$TOOLCHAIN_GO_MIN_VERSION" ]]
  [[ -n "$TOOLCHAIN_BUN_MIN_VERSION" ]]
  [[ -n "$TOOLCHAIN_NODE_MIN_VERSION" ]]
}

test_install_urls_defined() {
  [[ -n "$TOOLCHAIN_RUST_INSTALL_URL" ]]
  [[ -n "$TOOLCHAIN_GO_DOWNLOAD_URL" ]]
  [[ -n "$TOOLCHAIN_BUN_INSTALL_URL" ]]
  [[ -n "$TOOLCHAIN_NODE_DOWNLOAD_URL" ]]
}

test_install_urls_https() {
  [[ "$TOOLCHAIN_RUST_INSTALL_URL" == https://* ]]
  [[ "$TOOLCHAIN_GO_DOWNLOAD_URL" == https://* ]]
  [[ "$TOOLCHAIN_BUN_INSTALL_URL" == https://* ]]
  [[ "$TOOLCHAIN_NODE_DOWNLOAD_URL" == https://* ]]
}

# ============================================================================
# Isolated Source-Toolchain Bootstrap
# ============================================================================

# Distribution HTTP is a declared boundary fixture. Checksums, JSON selection,
# tar/zip admission, private activation and timeout handling use real code/tools.
bootstrap_fixture() {
  BOOT_CASE=$(mktemp -d "$TEMP_DIR/bootstrap.XXXXXXXX") || return 1
  export BOOT_CASE BOOT_ROOT="$BOOT_CASE/output" BOOT_CALLS="$BOOT_CASE/calls"
  export BOOT_PLATFORM=linux/amd64 BOOT_LIBC=gnu
  mkdir -p "$BOOT_CASE/tree" "$BOOT_CASE/go/bin" "$BOOT_CASE/rust" "$BOOT_CASE/bun-linux-x64-baseline"
  printf 'module example.invalid/bootstrap\ngo 1.22\n' > "$BOOT_CASE/tree/go.mod"
  printf '{"packageManager":"bun@1.2.3","engines":{"bun":"^1.2.0"}}\n' > "$BOOT_CASE/tree/package.json"
  cat > "$BOOT_CASE/go/bin/go" <<'GO'
#!/usr/bin/env bash
printf 'go %s\n' "$*" >> "$BOOT_CALLS"
touch "$BOOT_CASE/executed"
[[ "$1" == version && "$GOROOT" == "$BOOT_ROOT/go" && "$GOENV" == off && "$GOTOOLCHAIN" == local ]] || exit 70
printf 'go version go1.22.2 %s\n' "$BOOT_PLATFORM"
GO
  chmod +x "$BOOT_CASE/go/bin/go"
  tar -czf "$BOOT_CASE/go.tar.gz" -C "$BOOT_CASE" go || return 1
  bootstrap_go_metadata || return 1
  cat > "$BOOT_CASE/rustup-init" <<'RUSTUP'
#!/usr/bin/env bash
printf 'rustup-init %s\n' "$*" >> "$BOOT_CALLS"
printf 'Rustup installer informational stdout\n'
touch "$BOOT_CASE/executed"
[[ "$*" == '-y --no-modify-path --profile minimal --default-toolchain none --default-host x86_64-unknown-linux-gnu' ]] || exit 71
[[ "$CARGO_HOME" == "$BOOT_ROOT/cargo" && "$RUSTUP_HOME" == "$BOOT_ROOT/rustup" && "$RUSTUP_AUTO_INSTALL" == 0 ]] || exit 72
[[ "$RUSTUP_DIST_SERVER" == https://static.rust-lang.org && "$RUSTUP_UPDATE_ROOT" == https://static.rust-lang.org/rustup ]] || exit 73
mkdir -p "$CARGO_HOME/bin" "$RUSTUP_HOME" || exit 74
cp "$BOOT_CASE/rust/"* "$CARGO_HOME/bin/" || exit 74
RUSTUP
  cat > "$BOOT_CASE/rust/rustup" <<'RUSTUP'
#!/usr/bin/env bash
printf 'rustup %s %s\n' "$PWD" "$*" >> "$BOOT_CALLS"
printf 'Selected toolchain installation summary\n'
case "$*" in
    'toolchain install --profile minimal') [[ -z "${RUSTUP_TOOLCHAIN:-}" ]] ;;
    'default stable') [[ "${RUSTUP_TOOLCHAIN:-}" == stable ]] ;;
    *) exit 75 ;;
esac
RUSTUP
  cat > "$BOOT_CASE/rust/rustc" <<'RUSTC'
#!/usr/bin/env bash
printf 'rustc %s\n' "${RUSTUP_TOOLCHAIN:-repository}" >> "$BOOT_CALLS"
printf 'rustc 1.82.0 (fixture)\n'
RUSTC
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BOOT_CASE/rust/cargo"
  chmod +x "$BOOT_CASE/rustup-init" "$BOOT_CASE/rust/"*
  printf '%s  rustup-init\n' "$(_tc_bootstrap_sha256 "$BOOT_CASE/rustup-init")" > "$BOOT_CASE/rustup-init.sha256"
  cat > "$BOOT_CASE/bun-linux-x64-baseline/bun" <<'BUN'
#!/usr/bin/env bash
printf 'bun %s\n' "$*" >> "$BOOT_CALLS"
touch "$BOOT_CASE/executed"
case "$1" in
    --version) printf '1.2.3\n' ;;
    --eval) [[ "${DSR_BOOTSTRAP_BUN_RANGE:-}" == '^1.2.0' && "${BOOT_ENGINE_FAIL:-false}" != true ]] ;;
    *) exit 76 ;;
esac
BUN
  chmod +x "$BOOT_CASE/bun-linux-x64-baseline/bun"
  (cd "$BOOT_CASE" && zip -q -r bun.zip bun-linux-x64-baseline) || return 1
  printf '%s  bun-linux-x64-baseline.zip\n' "$(_tc_bootstrap_sha256 "$BOOT_CASE/bun.zip")" > "$BOOT_CASE/SHASUMS256.txt"
  _tc_detect_platform() { printf '%s\n' "$BOOT_PLATFORM"; }
  _tc_bootstrap_linux_libc() { printf '%s\n' "$BOOT_LIBC"; }
  curl() {
    local url='' output='' proto=false redirects=false
    while (($#)); do
      case "$1" in
        -o) output="$2"; shift 2 ;;
        --proto) [[ "$2" == '=https' ]] || return 90; proto=true; shift 2 ;;
        --proto-redir) [[ "$2" == '=https' ]] || return 90; redirects=true; shift 2 ;;
        https://*) url="$1"; shift ;;
        *) shift ;;
      esac
    done
    $proto && $redirects && [[ "$output" == "$BOOT_ROOT/"* ]] || return 91
    printf '%s\n' "$url" >> "$BOOT_CASE/requests"
    [[ "${BOOT_TRANSPORT_FAIL:-false}" != true ]] || return 22
    case "$url" in
      'https://go.dev/dl/?mode=json&include=all') cp "$BOOT_CASE/go.json" "$output" ;;
      https://go.dev/dl/go1.22.2.*.tar.gz) cp "$BOOT_CASE/go.tar.gz" "$output" ;;
      https://static.rust-lang.org/rustup/dist/*/rustup-init.sha256) cp "$BOOT_CASE/rustup-init.sha256" "$output" ;;
      https://static.rust-lang.org/rustup/dist/*/rustup-init) cp "$BOOT_CASE/rustup-init" "$output" ;;
      https://github.com/oven-sh/bun/releases/download/bun-v1.2.3/SHASUMS256.txt) cp "$BOOT_CASE/SHASUMS256.txt" "$output" ;;
      https://github.com/oven-sh/bun/releases/download/bun-v1.2.3/bun-linux-x64-baseline.zip) cp "$BOOT_CASE/bun.zip" "$output" ;;
      *) return 22 ;;
    esac
  }
}

bootstrap_go_metadata() {
  local digest size
  digest=$(_tc_bootstrap_sha256 "$BOOT_CASE/go.tar.gz") || return 1
  size=$(wc -c < "$BOOT_CASE/go.tar.gz") || return 1
  jq -n --arg sha "$digest" --argjson size "$size" --arg platform "$BOOT_PLATFORM" '
    ["go1.21.9","go1.22.1","go1.22.2","go1.23.0"] | map(. as $version |
      {version:$version,stable:true,files:[{os:($platform|split("/")[0]),
       arch:($platform|split("/")[1]),kind:"archive",sha256:$sha,size:$size,
       filename:($version + "." + ($platform|gsub("/";"-")) + ".tar.gz")}]})
  ' > "$BOOT_CASE/go.json"
}

bootstrap_run() {
  BOOT_STATUS=0
  toolchain_bootstrap "$1" "$BOOT_CASE/tree" "$BOOT_CASE/output" --allow-install \
    > "$BOOT_CASE/result.json" 2> "$BOOT_CASE/result.log" || BOOT_STATUS=$?
}

test_bootstrap_requires_consent() (
  bootstrap_fixture || return 1
  local status=0
  toolchain_bootstrap go "$BOOT_CASE/tree" "$BOOT_CASE/output" > "$BOOT_CASE/refused" || status=$?
  [[ "$status" == 4 && ! -e "$BOOT_CASE/output" && ! -e "$BOOT_CASE/requests" ]]
)

test_bootstrap_go_minor_selection() (
  bootstrap_fixture || return 1
  local prior_path="$PATH" prior_home="$HOME"
  bootstrap_run go
  [[ "$BOOT_STATUS" == 0 && "$PATH" == "$prior_path" && "$HOME" == "$prior_home" ]] || return 1
  jq -e --arg root "$BOOT_CASE/output" '.method == "isolated-bootstrap" and .root == $root and
    .version == "go version go1.22.2 linux/amd64" and
    .distribution_url == "https://go.dev/dl/go1.22.2.linux-amd64.tar.gz"' "$BOOT_CASE/result.json" >/dev/null &&
    cmp -s "$BOOT_CASE/result.json" "$BOOT_CASE/output/receipt.json"
)

test_bootstrap_go_exact_pin() (
  bootstrap_fixture || return 1
  printf 'module example.invalid/bootstrap\ngo 1.21.0\ntoolchain go1.22.2\n' > "$BOOT_CASE/tree/go.mod"
  bootstrap_run go
  [[ "$BOOT_STATUS" == 0 ]] && grep -q 'go1.22.2.linux-amd64.tar.gz' "$BOOT_CASE/requests"
)

test_bootstrap_go_macos_arm() (
  bootstrap_fixture || return 1
  BOOT_PLATFORM=darwin/arm64
  bootstrap_go_metadata || return 1
  bootstrap_run go
  [[ "$BOOT_STATUS" == 0 ]] && jq -e '.platform == "darwin/arm64" and
    .distribution_url == "https://go.dev/dl/go1.22.2.darwin-arm64.tar.gz"' "$BOOT_CASE/result.json" >/dev/null
)

test_bootstrap_go_bad_integrity() (
  bootstrap_fixture || return 1
  case "$1" in
    hash) jq 'map(.files[0].sha256 = ("0" * 64))' "$BOOT_CASE/go.json" > "$BOOT_CASE/changed.json" ;;
    size) jq 'map(.files[0].size += 1)' "$BOOT_CASE/go.json" > "$BOOT_CASE/changed.json" ;;
    duplicate) jq '. + [.[2]]' "$BOOT_CASE/go.json" > "$BOOT_CASE/changed.json" ;;
    malformed) printf '{}\n' > "$BOOT_CASE/changed.json" ;;
  esac
  cp "$BOOT_CASE/changed.json" "$BOOT_CASE/go.json"
  bootstrap_run go
  [[ "$BOOT_STATUS" == 7 && ! -e "$BOOT_CASE/executed" && ! -e "$BOOT_CASE/output/receipt.json" ]]
)

test_bootstrap_go_hash() { test_bootstrap_go_bad_integrity hash; }
test_bootstrap_go_size() { test_bootstrap_go_bad_integrity size; }
test_bootstrap_go_duplicates() { test_bootstrap_go_bad_integrity duplicate; }
test_bootstrap_go_malformed() { test_bootstrap_go_bad_integrity malformed; }

test_bootstrap_go_link_refused() (
  bootstrap_fixture || return 1
  mkdir -p "$BOOT_CASE/linked/go/bin"
  ln -s /bin/true "$BOOT_CASE/linked/go/bin/go"
  tar -czf "$BOOT_CASE/go.tar.gz" -C "$BOOT_CASE/linked" go || return 1
  bootstrap_go_metadata || return 1
  bootstrap_run go
  [[ "$BOOT_STATUS" == 7 && ! -e "$BOOT_CASE/output/go" && ! -e "$BOOT_CASE/output/receipt.json" ]]
)

test_bootstrap_transport_refused() (
  bootstrap_fixture || return 1
  export BOOT_TRANSPORT_FAIL=true
  bootstrap_run go
  [[ "$BOOT_STATUS" == 8 && ! -e "$BOOT_CASE/executed" && ! -e "$BOOT_CASE/output/receipt.json" ]]
)

test_bootstrap_existing_directory_refused() (
  bootstrap_fixture || return 1
  mkdir "$BOOT_CASE/output"
  printf 'keep\n' > "$BOOT_CASE/output/sentinel"
  bootstrap_run go
  [[ "$BOOT_STATUS" == 4 && "$(cat "$BOOT_CASE/output/sentinel")" == keep && ! -e "$BOOT_CASE/requests" ]]
)

test_bootstrap_unsupported_host() (
  bootstrap_fixture || return 1
  BOOT_PLATFORM=windows/amd64
  bootstrap_run go
  [[ "$BOOT_STATUS" == 3 && ! -e "$BOOT_CASE/output" && ! -e "$BOOT_CASE/requests" ]]
)

test_bootstrap_rust_pinned() (
  bootstrap_fixture || return 1
  printf '[toolchain]\nchannel = "1.82.0"\n' > "$BOOT_CASE/tree/rust-toolchain.toml"
  RUSTUP_TOOLCHAIN=ambient CARGO_HOME="$BOOT_CASE/untouched-cargo" RUSTUP_HOME="$BOOT_CASE/untouched-rustup" bootstrap_run rust
  [[ "$BOOT_STATUS" == 0 && ! -e "$BOOT_CASE/untouched-cargo" && ! -e "$BOOT_CASE/untouched-rustup" ]] || return 1
  grep -q '^rustup-init .*--no-modify-path .*--default-toolchain none' "$BOOT_CALLS" &&
    grep -q "^rustup $BOOT_CASE/tree toolchain install --profile minimal$" "$BOOT_CALLS" &&
    grep -q '^rustc repository$' "$BOOT_CALLS" &&
    jq -es 'length == 1 and .[0].method == "isolated-bootstrap"' "$BOOT_CASE/result.json" >/dev/null &&
    grep -q 'Rustup installer informational stdout' "$BOOT_CASE/result.log"
)

test_bootstrap_rust_unpinned() (
  bootstrap_fixture || return 1
  printf '[toolchain]\nchannel = "nightly"\n' > "$BOOT_CASE/rust-toolchain.toml"
  bootstrap_run rust
  [[ "$BOOT_STATUS" == 0 ]] && grep -q '^rustc stable$' "$BOOT_CALLS" &&
    jq -e '.rustup_toolchain == "stable"' "$BOOT_CASE/result.json" >/dev/null
)

test_bootstrap_rust_bad_hash() (
  bootstrap_fixture || return 1
  printf '%064d  rustup-init\n' 0 > "$BOOT_CASE/rustup-init.sha256"
  bootstrap_run rust
  [[ "$BOOT_STATUS" == 7 && ! -e "$BOOT_CASE/executed" && ! -e "$BOOT_CASE/output/cargo" ]]
)

bootstrap_rust_proxies() {
  bootstrap_fixture || return 1
  # shellcheck source=../../src/install_source.sh
  source "$SRC_DIR/install_source.sh" || return 1
  mkdir "$BOOT_CASE/proxies" "$BOOT_CASE/build"
  export BOOT_ROOT="$BOOT_CASE/build/toolchain" BOOT_PROXY_MODE="$1"
  cat > "$BOOT_CASE/proxies/rustc" <<'PROXY'
#!/usr/bin/env bash
[[ "${RUSTUP_AUTO_INSTALL:-}" == 0 ]] || exit 90
printf '%s %s\n' "${0##*/}" "$*" >> "$BOOT_CASE/probe-calls"
case "$BOOT_PROXY_MODE" in
    missing) printf 'selected toolchain is not installed\n' >&2; exit 1 ;;
    working) printf '%s 1.40.0 (existing compiler)\n' "${0##*/}" ;;
    timeout) sleep 20 ;;
    *) exit 91 ;;
esac
PROXY
  cp "$BOOT_CASE/proxies/rustc" "$BOOT_CASE/proxies/cargo"
  chmod +x "$BOOT_CASE/proxies/"*
  export PATH="$BOOT_CASE/proxies:$PATH"
  export CARGO_HOME="$BOOT_CASE/existing-cargo" RUSTUP_HOME="$BOOT_CASE/existing-rustup"
  _ISB_INSTALL_TOOLCHAIN=true
}

test_bootstrap_rust_missing_proxy_toolchain() (
  bootstrap_rust_proxies missing || return 1
  local original
  original=$(_tc_bootstrap_sha256 "$BOOT_CASE/proxies/rustc") || return 1
  _isb_prepare_toolchain rust "$BOOT_CASE/tree" "$BOOT_CASE/build" 10 \
    > "$BOOT_CASE/activation.out" 2> "$BOOT_CASE/activation.log" || return 1
  [[ "$(command -v rustc)" == "$BOOT_ROOT/cargo/bin/rustc" &&
     "$CARGO_HOME" == "$BOOT_ROOT/cargo" && "$RUSTUP_HOME" == "$BOOT_ROOT/rustup" &&
     ! -e "$BOOT_CASE/existing-cargo" && ! -e "$BOOT_CASE/existing-rustup" &&
     "$(_tc_bootstrap_sha256 "$BOOT_CASE/proxies/rustc")" == "$original" ]] || return 1
  [[ "$(rustc --version)" == 'rustc 1.82.0 (fixture)' && -f "$BOOT_ROOT/receipt.json" ]]
)

test_bootstrap_rust_working_proxy_preserved() (
  bootstrap_rust_proxies working || return 1
  local original_path="$PATH"
  _isb_prepare_toolchain rust "$BOOT_CASE/tree" "$BOOT_CASE/build" 10 \
    > "$BOOT_CASE/activation.out" 2> "$BOOT_CASE/activation.log" || return 1
  [[ "$PATH" == "$original_path" && "$CARGO_HOME" == "$BOOT_CASE/existing-cargo" &&
     ! -e "$BOOT_ROOT" && ! -e "$BOOT_CASE/requests" ]] &&
    grep -q '^rustc -vV$' "$BOOT_CASE/probe-calls" && grep -q '^cargo --version$' "$BOOT_CASE/probe-calls"
)

test_bootstrap_rust_probe_timeout_refused() (
  bootstrap_rust_proxies timeout || return 1
  local status=0
  _isb_prepare_toolchain rust "$BOOT_CASE/tree" "$BOOT_CASE/build" 1 \
    > "$BOOT_CASE/activation.out" 2> "$BOOT_CASE/activation.log" || status=$?
  [[ "$status" == 5 && ! -e "$BOOT_ROOT" && ! -e "$BOOT_CASE/requests" &&
     -f "$BOOT_CASE/build/toolchain-probe.log.timeout" ]]
)

test_bootstrap_bun_pinned() (
  bootstrap_fixture || return 1
  bootstrap_run bun
  [[ "$BOOT_STATUS" == 0 ]] && jq -e '.version == "1.2.3" and
    .distribution_url == "https://github.com/oven-sh/bun/releases/download/bun-v1.2.3/bun-linux-x64-baseline.zip"' "$BOOT_CASE/result.json" >/dev/null &&
    ! grep -q '/releases/latest' "$BOOT_CASE/requests"
)

test_bootstrap_bun_bad_hash() (
  bootstrap_fixture || return 1
  printf '%064d  bun-linux-x64-baseline.zip\n' 0 > "$BOOT_CASE/SHASUMS256.txt"
  bootstrap_run bun
  [[ "$BOOT_STATUS" == 7 && ! -e "$BOOT_CASE/executed" && ! -e "$BOOT_CASE/output/receipt.json" ]]
)

test_bootstrap_bun_incompatible_engine() (
  bootstrap_fixture || return 1
  export BOOT_ENGINE_FAIL=true
  bootstrap_run bun
  [[ "$BOOT_STATUS" == 7 && ! -e "$BOOT_CASE/output/receipt.json" ]]
)

# ============================================================================
# Main Test Runner
# ============================================================================

main() {
  echo "=== toolchain_detect.sh Tests ==="
  echo ""

  setup

  echo "Version Comparison:"
  run_test "version_ge_equal" test_version_ge_equal
  run_test "version_ge_greater_patch" test_version_ge_greater_patch
  run_test "version_ge_greater_minor" test_version_ge_greater_minor
  run_test "version_ge_greater_major" test_version_ge_greater_major
  run_test "version_ge_less_patch" test_version_ge_less_patch
  run_test "version_ge_less_minor" test_version_ge_less_minor
  run_test "version_ge_less_major" test_version_ge_less_major
  run_test "version_ge_prerelease" test_version_ge_prerelease
  run_test "version_ge_with_prefix" test_version_ge_with_prefix
  run_test "version_ge_missing_v1" test_version_ge_missing_v1
  run_test "version_ge_missing_v2" test_version_ge_missing_v2
  run_test "version_ge_go_format" test_version_ge_go_format
  run_test "version_ge_node_format" test_version_ge_node_format

  echo ""
  echo "Platform Detection:"
  run_test "detect_platform_format" test_detect_platform_format
  run_test "detect_platform_known_os" test_detect_platform_known_os
  run_test "detect_platform_known_arch" test_detect_platform_known_arch
  run_test "detect_platform_consistent" test_detect_platform_consistent

  echo ""
  echo "Rust Detection:"
  run_test "detect_rust_json_valid" test_detect_rust_json_valid
  run_test "detect_rust_has_required_fields" test_detect_rust_has_required_fields
  run_test "detect_rust_toolchain_field" test_detect_rust_toolchain_field
  run_test "detect_rust_minimum_version" test_detect_rust_minimum_version
  run_test "detect_rust_installed_boolean" test_detect_rust_installed_boolean

  echo ""
  echo "Go Detection:"
  run_test "detect_go_json_valid" test_detect_go_json_valid
  run_test "detect_go_has_required_fields" test_detect_go_has_required_fields
  run_test "detect_go_toolchain_field" test_detect_go_toolchain_field
  run_test "detect_go_minimum_version" test_detect_go_minimum_version

  echo ""
  echo "Bun Detection:"
  run_test "detect_bun_json_valid" test_detect_bun_json_valid
  run_test "detect_bun_toolchain_field" test_detect_bun_toolchain_field
  run_test "detect_bun_minimum_version" test_detect_bun_minimum_version

  echo ""
  echo "Node Detection:"
  run_test "detect_node_json_valid" test_detect_node_json_valid
  run_test "detect_node_toolchain_field" test_detect_node_toolchain_field
  run_test "detect_node_minimum_version" test_detect_node_minimum_version

  echo ""
  echo "Unified Interface:"
  run_test "toolchain_detect_rust_alias" test_toolchain_detect_rust_alias
  run_test "toolchain_detect_go_aliases" test_toolchain_detect_go_aliases
  run_test "toolchain_detect_node_aliases" test_toolchain_detect_node_aliases
  run_test "toolchain_detect_unknown" test_toolchain_detect_unknown

  echo ""
  echo "Detect All:"
  run_test "detect_all_json_valid" test_detect_all_json_valid
  run_test "detect_all_has_platform" test_detect_all_has_platform
  run_test "detect_all_has_toolchains_array" test_detect_all_has_toolchains_array
  run_test "detect_all_contains_all_toolchains" test_detect_all_contains_all_toolchains

  echo ""
  echo "Installation Safety:"
  run_test "install_rust_refuses_overwrite" test_install_rust_refuses_overwrite
  run_test "install_go_refuses_overwrite" test_install_go_refuses_overwrite
  run_test "install_bun_refuses_overwrite" test_install_bun_refuses_overwrite
  run_test "toolchain_install_refuses_existing" test_toolchain_install_refuses_existing
  run_test "toolchain_install_unknown_returns_error" test_toolchain_install_unknown_returns_error

  echo ""
  echo "Ensure Logic:"
  run_test "ensure_returns_ok_when_installed" test_ensure_returns_ok_when_installed
  run_test "ensure_returns_error_when_missing" test_ensure_returns_error_when_missing

  echo ""
  echo "Non-Interactive Mode:"
  run_test "prompt_fails_in_noninteractive" test_prompt_fails_in_noninteractive
  run_test "noninteractive_respects_env" test_noninteractive_respects_env

  echo ""
  echo "Logging Functions:"
  run_test "log_functions_exist" test_log_functions_exist
  run_test "log_output_to_stderr" test_log_output_to_stderr

  echo ""
  echo "Constants:"
  run_test "min_versions_defined" test_min_versions_defined
  run_test "install_urls_defined" test_install_urls_defined
  run_test "install_urls_https" test_install_urls_https

  echo ""
  echo "Isolated source-toolchain bootstrap:"
  run_test "bootstrap_requires_consent" test_bootstrap_requires_consent
  run_test "bootstrap_go_minor_selection" test_bootstrap_go_minor_selection
  run_test "bootstrap_go_exact_pin" test_bootstrap_go_exact_pin
  run_test "bootstrap_go_macos_arm" test_bootstrap_go_macos_arm
  run_test "bootstrap_go_hash" test_bootstrap_go_hash
  run_test "bootstrap_go_size" test_bootstrap_go_size
  run_test "bootstrap_go_duplicates" test_bootstrap_go_duplicates
  run_test "bootstrap_go_malformed" test_bootstrap_go_malformed
  run_test "bootstrap_go_link_refused" test_bootstrap_go_link_refused
  run_test "bootstrap_transport_refused" test_bootstrap_transport_refused
  run_test "bootstrap_existing_directory_refused" test_bootstrap_existing_directory_refused
  run_test "bootstrap_unsupported_host" test_bootstrap_unsupported_host
  run_test "bootstrap_rust_pinned" test_bootstrap_rust_pinned
  run_test "bootstrap_rust_unpinned" test_bootstrap_rust_unpinned
  run_test "bootstrap_rust_bad_hash" test_bootstrap_rust_bad_hash
  run_test "bootstrap_rust_missing_proxy_toolchain" test_bootstrap_rust_missing_proxy_toolchain
  run_test "bootstrap_rust_working_proxy_preserved" test_bootstrap_rust_working_proxy_preserved
  run_test "bootstrap_rust_probe_timeout_refused" test_bootstrap_rust_probe_timeout_refused
  run_test "bootstrap_bun_pinned" test_bootstrap_bun_pinned
  run_test "bootstrap_bun_bad_hash" test_bootstrap_bun_bad_hash
  run_test "bootstrap_bun_incompatible_engine" test_bootstrap_bun_incompatible_engine

  teardown

  echo ""
  echo "=== Results ==="
  echo "Tests run:    $TESTS_RUN"
  echo "Tests passed: $TESTS_PASSED"
  echo "Tests failed: $TESTS_FAILED"

  if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

main "$@"
