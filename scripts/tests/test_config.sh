#!/usr/bin/env bash
# test_config.sh - Tests for config.sh module
#
# Tests XDG-compliant configuration management.
# Uses isolated temp directories for each test.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$SCRIPT_DIR/../../src" && pwd)"

# Source the module under test
# shellcheck source=../../src/logging.sh
source "$SRC_DIR/logging.sh"
# shellcheck source=../../src/config.sh
source "${DSR_CONFIG_MODULE:-$SRC_DIR/config.sh}"

# Test state
TEMP_DIR=""
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Original XDG values (to restore after tests)
_ORIG_XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-}"
_ORIG_XDG_CACHE_HOME="${XDG_CACHE_HOME:-}"
_ORIG_XDG_STATE_HOME="${XDG_STATE_HOME:-}"

# Initialize logging silently
log_init 2>/dev/null || true

# Suppress colors for consistent output
export NO_COLOR=1

# ============================================================================
# Test Infrastructure
# ============================================================================

setup() {
  TEMP_DIR=$(mktemp -d) || return 1
  # Publication targets use physical parents; keep boundary-injection paths
  # identical on systems where /tmp or TMPDIR is itself a symlink.
  TEMP_DIR=$(CDPATH='' cd -P -- "$TEMP_DIR" && pwd -P) || return 1

  # Set up isolated XDG directories
  export XDG_CONFIG_HOME="$TEMP_DIR/config"
  export XDG_CACHE_HOME="$TEMP_DIR/cache"
  export XDG_STATE_HOME="$TEMP_DIR/state"

  # Re-initialize config module paths
  DSR_CONFIG_DIR="$XDG_CONFIG_HOME/dsr"
  DSR_CACHE_DIR="$XDG_CACHE_HOME/dsr"
  DSR_STATE_DIR="$XDG_STATE_HOME/dsr"
  DSR_CONFIG_FILE="$DSR_CONFIG_DIR/config.yaml"
  DSR_REPOS_FILE="$DSR_CONFIG_DIR/repos.yaml"
  DSR_HOSTS_FILE="$DSR_CONFIG_DIR/hosts.yaml"

  # Reset config array
  DSR_CONFIG=()
}

teardown() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    if [[ "${DSR_TEST_KEEP_TMP:-0}" == "1" ]]; then
      echo "Retained test fixture: $TEMP_DIR" >&2
    else
      rm -rf "$TEMP_DIR"
    fi
  fi

  # Restore original XDG values
  export XDG_CONFIG_HOME="$_ORIG_XDG_CONFIG_HOME"
  export XDG_CACHE_HOME="$_ORIG_XDG_CACHE_HOME"
  export XDG_STATE_HOME="$_ORIG_XDG_STATE_HOME"
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

write_contract_tool_config() {
  mkdir -p "$DSR_CONFIG_DIR/repos.d"
  cat > "$DSR_CONFIG_DIR/repos.d/contract-tool.yaml"
}

release_contract_test_deps_available() {
  command -v yq &>/dev/null && command -v jq &>/dev/null
}

run_test() {
  local test_name="$1"
  local test_func="$2"

  ((TESTS_RUN++))
  echo -n "  $test_name... "

  setup

  if $test_func 2>/dev/null; then
    echo "OK"
    ((TESTS_PASSED++))
  else
    echo "FAILED"
    ((TESTS_FAILED++))
  fi

  teardown
}

# ============================================================================
# Tests: Initialization (config_init)
# ============================================================================

test_init_creates_config_dir() {
  config_init
  [[ -d "$DSR_CONFIG_DIR" ]]
}

test_init_creates_cache_dir() {
  config_init
  [[ -d "$DSR_CACHE_DIR" ]]
}

test_init_creates_state_dir() {
  config_init
  [[ -d "$DSR_STATE_DIR" ]]
}

test_init_creates_subdirs() {
  config_init
  [[ -d "$DSR_STATE_DIR/logs" ]] && \
  [[ -d "$DSR_STATE_DIR/artifacts" ]] && \
  [[ -d "$DSR_STATE_DIR/manifests" ]] && \
  [[ -d "$DSR_CACHE_DIR/act" ]] && \
  [[ -d "$DSR_CACHE_DIR/builds" ]]
}

test_init_creates_config_yaml() {
  config_init
  [[ -f "$DSR_CONFIG_FILE" ]]
}

test_init_creates_hosts_yaml() {
  config_init
  [[ -f "$DSR_HOSTS_FILE" ]]
}

test_init_creates_repos_yaml() {
  config_init
  [[ -f "$DSR_REPOS_FILE" ]]
}

test_init_no_overwrite() {
  config_init
  # Write custom content
  echo "custom: value" > "$DSR_CONFIG_FILE"
  config_init  # Should not overwrite
  grep -q "custom: value" "$DSR_CONFIG_FILE"
}

test_init_force_overwrites() {
  config_init
  # Write custom content
  echo "custom: value" > "$DSR_CONFIG_FILE"
  config_init --force  # Should overwrite
  ! grep -q "custom: value" "$DSR_CONFIG_FILE"
}

test_init_config_has_schema_version() {
  config_init
  grep -q "schema_version:" "$DSR_CONFIG_FILE"
}

test_init_hosts_has_hosts() {
  config_init
  grep -q "hosts:" "$DSR_HOSTS_FILE"
}

test_init_repos_has_tools() {
  config_init
  grep -q "tools:" "$DSR_REPOS_FILE"
}


_config_init_cli() {
  env DSR_CONFIG_DIR="$DSR_CONFIG_DIR" DSR_CONFIG_FILE="$DSR_CONFIG_FILE" \
    DSR_REPOS_FILE="$DSR_REPOS_FILE" DSR_HOSTS_FILE="$DSR_HOSTS_FILE" \
    DSR_CACHE_DIR="$DSR_CACHE_DIR" DSR_STATE_DIR="$DSR_STATE_DIR" \
    DSR_LOG_FILE="$DSR_STATE_DIR/custom.log" \
    bash "$SRC_DIR/../dsr" "$@" > "$TEMP_DIR/init.stdout" 2> "$TEMP_DIR/init.stderr"
}

_init_roots_absent() {
  [[ ! -e "$DSR_CONFIG_DIR" && ! -L "$DSR_CONFIG_DIR" &&
     ! -e "$DSR_CACHE_DIR" && ! -L "$DSR_CACHE_DIR" &&
     ! -e "$DSR_STATE_DIR" && ! -L "$DSR_STATE_DIR" ]]
}

test_init_dry_run_does_not_create_roots() {
  config_init --dry-run || return 1
  _init_roots_absent || return 1
  config_init -n --force || return 1
  _init_roots_absent || return 1
  config_init --force --dry-run || return 1
  _init_roots_absent || return 1
  # shellcheck disable=SC2034  # Read by the sourced configuration module.
  ( DRY_RUN=true; config_init --force ) || return 1
  _init_roots_absent
}

test_init_rejects_unknown_arguments_without_writes() {
  local status=0
  config_init --force --unknown-init-option || status=$?
  [[ "$status" == 4 ]] && _init_roots_absent || return 1
  status=0
  config_init unexpected || status=$?
  [[ "$status" == 4 ]] && _init_roots_absent
}

test_cli_init_dry_run_flag_orders() {
  local variant expected_force=false
  for variant in 1 2 3 4 5 6 7 8; do
    expected_force=false
    case "$variant" in
      1) set -- --dry-run config init ;;
      2) set -- -n config init ;;
      3) set -- config init --dry-run ;;
      4) set -- config init -n ;;
      5) set -- config init --dry-run --force; expected_force=true ;;
      6) set -- config init --force --dry-run; expected_force=true ;;
      7) set -- config init --force -n; expected_force=true ;;
      8) set -- -n config init --force; expected_force=true ;;
    esac
    _config_init_cli --json "$@" || return 1
    [[ ! -s "$TEMP_DIR/init.stderr" ]] || return 1
    _init_roots_absent || return 1
    jq -es --arg config "$DSR_CONFIG_FILE" --arg hosts "$DSR_HOSTS_FILE" \
      --arg repos "$DSR_REPOS_FILE" --argjson force "$expected_force" '
        length == 1 and (.[0] | .command == "config" and .exit_code == 0 and
          .details.action == "init" and .details.initialized == false and
          .details.dry_run == true and .details.force == $force and
          (.details.planned_files | sort) == ([$config,$hosts,$repos] | sort))
      ' "$TEMP_DIR/init.stdout" >/dev/null || return 1
  done
}

test_cli_init_forced_plan_preserves_existing_files() {
  mkdir -p "$DSR_CONFIG_DIR" || return 1
  printf 'schema_version: "1.0.0"\nthreshold_seconds: 1234\n' > "$DSR_CONFIG_FILE"
  printf 'hosts: {retained: {ssh_host: private-builder}}\n' > "$DSR_HOSTS_FILE"
  printf 'tools: {retained: {repo: example/retained}}\n' > "$DSR_REPOS_FILE"
  local before after paths
  before=$(cksum "$DSR_CONFIG_FILE" "$DSR_HOSTS_FILE" "$DSR_REPOS_FILE") || return 1
  paths=$(find "$DSR_CONFIG_DIR" -print | LC_ALL=C sort) || return 1
  config_init --force --dry-run || return 1
  [[ "$before" == "$(cksum "$DSR_CONFIG_FILE" "$DSR_HOSTS_FILE" "$DSR_REPOS_FILE")" &&
     "$paths" == "$(find "$DSR_CONFIG_DIR" -print | LC_ALL=C sort)" &&
     ! -e "$DSR_CACHE_DIR" && ! -e "$DSR_STATE_DIR" ]] || return 1
  _config_init_cli --json config init --force --dry-run || return 1
  after=$(cksum "$DSR_CONFIG_FILE" "$DSR_HOSTS_FILE" "$DSR_REPOS_FILE") || return 1
  [[ "$before" == "$after" && "$paths" == "$(find "$DSR_CONFIG_DIR" -print | LC_ALL=C sort)" &&
     ! -e "$DSR_CACHE_DIR" && ! -e "$DSR_STATE_DIR" ]] || return 1
  jq -e '.details.initialized == false and .details.dry_run == true and
    .details.force == true and (.details.planned_files | length) == 3' \
    "$TEMP_DIR/init.stdout" >/dev/null || return 1
  _config_init_cli --json config init --dry-run || return 1
  [[ "$before" == "$(cksum "$DSR_CONFIG_FILE" "$DSR_HOSTS_FILE" "$DSR_REPOS_FILE")" &&
     "$paths" == "$(find "$DSR_CONFIG_DIR" -print | LC_ALL=C sort)" &&
     ! -e "$DSR_CACHE_DIR" && ! -e "$DSR_STATE_DIR" ]] || return 1
  jq -e '.details.initialized == false and .details.dry_run == true and
    .details.force == false and .details.planned_files == []' "$TEMP_DIR/init.stdout" >/dev/null
}

test_cli_init_preview_preserves_explicit_log() {
  mkdir -p "$DSR_STATE_DIR" || return 1
  printf 'existing log must not be appended or rotated\n' > "$DSR_STATE_DIR/custom.log"
  local before paths variant status
  before=$(cksum "$DSR_STATE_DIR/custom.log") || return 1
  paths=$(find "$DSR_STATE_DIR" -print | LC_ALL=C sort) || return 1
  for variant in 1 2 3 4; do
    case "$variant" in
      1) set -- --dry-run config init --force ;;
      2) set -- config init --force -n ;;
      3) set -- --json config init --dry-run --force ;;
      4) set -- -n config init --json ;;
    esac
    _config_init_cli "$@" || return 1
    [[ "$before" == "$(cksum "$DSR_STATE_DIR/custom.log")" &&
       "$paths" == "$(find "$DSR_STATE_DIR" -print | LC_ALL=C sort)" &&
       ! -e "$DSR_CONFIG_DIR" && ! -e "$DSR_CACHE_DIR" ]] || return 1
  done
  status=0
  _config_init_cli --json config init --dry-run --force --unknown-init-option || status=$?
  [[ "$status" == 4 && "$before" == "$(cksum "$DSR_STATE_DIR/custom.log")" &&
     "$paths" == "$(find "$DSR_STATE_DIR" -print | LC_ALL=C sort)" &&
     ! -e "$DSR_CONFIG_DIR" && ! -e "$DSR_CACHE_DIR" ]] || return 1
  jq -e '.exit_code == 4 and .status == "error" and .details.initialized == false and
    .details.dry_run == true and .details.planned_files == []' "$TEMP_DIR/init.stdout" >/dev/null
}

test_cli_init_rejects_unknown_plan_arguments() {
  local status=0
  _config_init_cli config init --force --dry-run --unknown-init-option || status=$?
  [[ "$status" == 4 ]] && _init_roots_absent || return 1
  status=0
  _config_init_cli config init --dry-run unexpected || status=$?
  [[ "$status" == 4 ]] && _init_roots_absent
}

test_cli_init_real_run_creates_files() {
  # Quiet suppresses the existing session-start logger; JSON must also
  # suppress the initializer's independent informational diagnostics.
  _config_init_cli --quiet --json config init || return 1
  [[ ! -s "$TEMP_DIR/init.stderr" ]] || return 1
  [[ -f "$DSR_CONFIG_FILE" && -f "$DSR_HOSTS_FILE" && -f "$DSR_REPOS_FILE" &&
     -d "$DSR_CACHE_DIR" && -d "$DSR_STATE_DIR" ]] || return 1
  jq -e '.command == "config" and .exit_code == 0 and .details.action == "init" and
    .details.initialized == true and .details.dry_run == false and .details.force == false' \
    "$TEMP_DIR/init.stdout" >/dev/null
}


_init_custom_config_files() {
  mkdir -p "$DSR_CONFIG_DIR" || return 1
  printf 'schema_version: "1.0.0"\nretained: original-config\n' > "$DSR_CONFIG_FILE" || return 1
  printf 'hosts: {retained: {ssh_host: original-builder}}\n' > "$DSR_HOSTS_FILE" || return 1
  printf 'tools: {retained: {repo: example/original}}\n' > "$DSR_REPOS_FILE" || return 1
  chmod 640 "$DSR_CONFIG_FILE" "$DSR_HOSTS_FILE" "$DSR_REPOS_FILE"
}

_init_file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

test_init_force_preserves_complete_backup_generations() {
  _init_custom_config_files || return 1
  local index generation
  local -a paths=("$DSR_CONFIG_FILE" "$DSR_HOSTS_FILE" "$DSR_REPOS_FILE")
  local -a first_backups=()
  for ((index = 0; index < 3; index++)); do
    cp -p "${paths[index]}" "$TEMP_DIR/original.$index" || return 1
  done
  config_init --force || return 1
  [[ ${#_DSR_CONFIG_INIT_BACKUP_PATHS[@]} -eq 3 ]] || return 1
  first_backups=("${_DSR_CONFIG_INIT_BACKUP_PATHS[@]}")
  generation="${first_backups[0]#"${paths[0]}.bak."}"
  for ((index = 0; index < 3; index++)); do
    [[ "${first_backups[index]#"${paths[index]}.bak."}" == "$generation" ]] || return 1
    cmp -s "$TEMP_DIR/original.$index" "${first_backups[index]}" || return 1
    [[ ! "${paths[index]}" -ef "${first_backups[index]}" &&
       "$(_init_file_mode "${first_backups[index]}")" == 640 ]] || return 1
    grep -q '^schema_version:' "${paths[index]}" || return 1
    cp -p "${paths[index]}" "$TEMP_DIR/default.$index" || return 1
  done
  config_init --force || return 1
  [[ ${#_DSR_CONFIG_INIT_BACKUP_PATHS[@]} -eq 3 ]] || return 1
  for ((index = 0; index < 3; index++)); do
    [[ "${_DSR_CONFIG_INIT_BACKUP_PATHS[index]}" != "${first_backups[index]}" ]] || return 1
    cmp -s "$TEMP_DIR/original.$index" "${first_backups[index]}" || return 1
    cmp -s "$TEMP_DIR/default.$index" "${_DSR_CONFIG_INIT_BACKUP_PATHS[index]}" || return 1
  done
}

# Explicit copy-failure injection: the first original is really copied, while
# the second fails. None of the live configuration files may be replaced.
test_init_force_backup_failure_preserves_originals() (
  _init_custom_config_files || return 1
  local before status=0
  before=$(cksum "$DSR_CONFIG_FILE" "$DSR_HOSTS_FILE" "$DSR_REPOS_FILE") || return 1
  cp() {
    local arg
    for arg in "$@"; do
      [[ "$arg" != "$DSR_HOSTS_FILE" ]] || return 1
    done
    command cp "$@"
  }
  config_init --force > "$TEMP_DIR/reset.stdout" 2> "$TEMP_DIR/reset.stderr" || status=$?
  [[ "$status" == 1 &&
     "$before" == "$(cksum "$DSR_CONFIG_FILE" "$DSR_HOSTS_FILE" "$DSR_REPOS_FILE")" &&
     ${#_DSR_CONFIG_INIT_BACKUP_PATHS[@]} -eq 1 ]] || return 1
  cmp -s "$DSR_CONFIG_FILE" "${_DSR_CONFIG_INIT_BACKUP_PATHS[0]}" || return 1
  ! grep -q 'Configuration initialized' "$TEMP_DIR/reset.stderr"
)

test_init_directory_failure_propagates() {
  mkdir -p "$(dirname "$DSR_CACHE_DIR")" || return 1
  printf 'this is a file, not a cache directory\n' > "$DSR_CACHE_DIR" || return 1
  local status=0
  config_init > "$TEMP_DIR/reset.stdout" 2> "$TEMP_DIR/reset.stderr" || status=$?
  [[ "$status" == 1 && ! -e "$DSR_CONFIG_FILE" &&
     ! -e "$DSR_HOSTS_FILE" && ! -e "$DSR_REPOS_FILE" ]] || return 1
  ! grep -q 'Configuration initialized' "$TEMP_DIR/reset.stderr"
}

# Explicit second-write failure injection. Staging must fail before publishing
# any file, while every original also remains available in its verified backup.
test_init_write_failure_retains_all_backups() (
  _init_custom_config_files || return 1
  local index status=0 writes=0
  local -a paths=("$DSR_CONFIG_FILE" "$DSR_HOSTS_FILE" "$DSR_REPOS_FILE")
  for ((index = 0; index < 3; index++)); do
    cp -p "${paths[index]}" "$TEMP_DIR/original.$index" || return 1
  done
  cat() {
    writes=$((writes + 1))
    [[ $writes -ne 2 ]] || return 1
    command cat "$@"
  }
  config_init --force > "$TEMP_DIR/reset.stdout" 2> "$TEMP_DIR/reset.stderr" || status=$?
  [[ "$status" == 1 && ${#_DSR_CONFIG_INIT_BACKUP_PATHS[@]} -eq 3 ]] || return 1
  for ((index = 0; index < 3; index++)); do
    cmp -s "$TEMP_DIR/original.$index" "${_DSR_CONFIG_INIT_BACKUP_PATHS[index]}" || return 1
    cmp -s "$TEMP_DIR/original.$index" "${paths[index]}" || return 1
    [[ "$(_init_file_mode "${paths[index]}")" == 640 ]] || return 1
  done
  ! grep -q 'Configuration initialized' "$TEMP_DIR/reset.stderr" || return 1
  ! grep -Fq "Created $DSR_HOSTS_FILE" "$TEMP_DIR/reset.stderr"
)

test_init_force_refuses_unsafe_or_aliased_destinations() {
  local kind root before referent_before status
  for kind in symlink dangling fifo directory duplicate hardlink; do
    root="$TEMP_DIR/$kind"
    DSR_CONFIG_DIR="$root/config"
    DSR_CACHE_DIR="$root/cache"
    DSR_STATE_DIR="$root/state"
    DSR_CONFIG_FILE="$DSR_CONFIG_DIR/config.yaml"
    DSR_HOSTS_FILE="$DSR_CONFIG_DIR/hosts.yaml"
    DSR_REPOS_FILE="$DSR_CONFIG_DIR/repos.yaml"
    mkdir -p "$DSR_CONFIG_DIR" || return 1
    printf 'retained config\n' > "$DSR_CONFIG_FILE" || return 1
    printf 'retained repos\n' > "$DSR_REPOS_FILE" || return 1
    printf 'protected referent\n' > "$root/referent" || return 1
    case "$kind" in
      symlink) ln -s "$root/referent" "$DSR_HOSTS_FILE" || return 1 ;;
      dangling) ln -s "$root/missing" "$DSR_HOSTS_FILE" || return 1 ;;
      fifo) mkfifo "$DSR_HOSTS_FILE" || return 1 ;;
      directory) mkdir "$DSR_HOSTS_FILE" || return 1 ;;
      duplicate) DSR_HOSTS_FILE="$DSR_CONFIG_FILE" ;;
      hardlink) ln "$DSR_CONFIG_FILE" "$DSR_HOSTS_FILE" || return 1 ;;
    esac
    before=$(cksum "$DSR_CONFIG_FILE" "$DSR_REPOS_FILE") || return 1
    referent_before=$(cksum "$root/referent") || return 1
    status=0
    config_init --force || status=$?
    [[ "$status" == 4 && "$before" == "$(cksum "$DSR_CONFIG_FILE" "$DSR_REPOS_FILE")" &&
       "$referent_before" == "$(cksum "$root/referent")" && ! -e "$root/missing" &&
       ! -e "$DSR_CACHE_DIR" && ! -e "$DSR_STATE_DIR" ]] || return 1
    [[ -z "$(find "$DSR_CONFIG_DIR" -name '*.bak.*' -print)" ]] || return 1
  done
}

test_init_refuses_missing_aliased_destinations() (
  DSR_HOSTS_FILE="$DSR_CONFIG_DIR/./config.yaml"
  local status=0
  config_init || status=$?
  [[ "$status" == 4 && ! -e "$DSR_CONFIG_FILE" && ! -e "$DSR_REPOS_FILE" ]] || return 1
  [[ -z "$(find "$DSR_CONFIG_DIR" -name '*.bak.*' -print)" ]] || return 1

  # A caller's CDPATH must not redirect parent resolution to a decoy directory.
  CDPATH="$TEMP_DIR/decoys"
  mkdir -p "$CDPATH/relative-config" || return 1
  cd "$TEMP_DIR" || return 1
  DSR_CONFIG_DIR=relative-config
  DSR_CONFIG_FILE=relative-config/config.yaml
  DSR_HOSTS_FILE="$TEMP_DIR/relative-config/config.yaml"
  DSR_REPOS_FILE=relative-config/repos.yaml
  status=0
  config_init || status=$?
  [[ "$status" == 4 && ! -e "$DSR_CONFIG_FILE" && ! -e "$DSR_REPOS_FILE" &&
     ! -e "$CDPATH/relative-config/config.yaml" ]] || return 1
  [[ -z "$(find "$DSR_CONFIG_DIR" -name '*.bak.*' -print)" ]]
)

test_cli_init_force_reports_retained_backups() {
  _init_custom_config_files || return 1
  local index=0 backup
  local -a paths=("$DSR_CONFIG_FILE" "$DSR_HOSTS_FILE" "$DSR_REPOS_FILE")
  for ((index = 0; index < 3; index++)); do
    cp -p "${paths[index]}" "$TEMP_DIR/original.$index" || return 1
  done
  _config_init_cli --quiet --json config init --force || return 1
  [[ ! -s "$TEMP_DIR/init.stderr" ]] || return 1
  jq -e '.exit_code == 0 and .details.initialized == true and
    .details.dry_run == false and .details.force == true and
    (.details.backup_paths | length) == 3' "$TEMP_DIR/init.stdout" >/dev/null || return 1
  index=0
  while IFS= read -r backup; do
    [[ -f "$backup" && ! -L "$backup" ]] || return 1
    cmp -s "$TEMP_DIR/original.$index" "$backup" || return 1
    index=$((index + 1))
  done < <(jq -r '.details.backup_paths[]' "$TEMP_DIR/init.stdout")
  [[ $index -eq 3 ]]
}

test_cli_init_filesystem_failure_is_not_initialized() {
  mkdir -p "$(dirname "$DSR_CACHE_DIR")" || return 1
  printf 'blocking file\n' > "$DSR_CACHE_DIR" || return 1
  local status=0
  _config_init_cli --json config init || status=$?
  [[ "$status" == 1 && ! -e "$DSR_CONFIG_FILE" &&
     ! -e "$DSR_HOSTS_FILE" && ! -e "$DSR_REPOS_FILE" ]] || return 1
  jq -es --arg path "$DSR_CACHE_DIR" 'length == 1 and (.[0] |
    .status == "error" and .exit_code == 1 and .details.initialized == false and
    .details.dry_run == false and .details.backup_paths == [] and
    any(.details.errors[]; .message | contains($path)))' "$TEMP_DIR/init.stdout" >/dev/null
}

test_cli_init_invalid_globals_dry_run_preserves_log() {
  mkdir -p "$DSR_STATE_DIR" || return 1
  printf 'existing log must survive even early argument errors\n' > "$DSR_STATE_DIR/custom.log"
  local before paths variant status
  before=$(cksum "$DSR_STATE_DIR/custom.log") || return 1
  paths=$(find "$DSR_STATE_DIR" -print | LC_ALL=C sort) || return 1
  for variant in 1 2 3 4 5 6 7 8; do
    case "$variant" in
      1) set -- --dry-run --log-level invalid config init ;;
      2) set -- --log-level invalid config init --dry-run ;;
      3) set -- -n --state-dir ;;
      4) set -- --dry-run --config ;;
      5) set -- --json -n --log-level=invalid config init --force ;;
      6) set -- --config --dry-run config init --force ;;
      7) set -- --dry-run --config= config init ;;
      8) set -- --cache-dir -n config init ;;
    esac
    status=0
    _config_init_cli "$@" || status=$?
    [[ "$status" == 4 && -s "$TEMP_DIR/init.stderr" &&
       "$before" == "$(cksum "$DSR_STATE_DIR/custom.log")" &&
       "$paths" == "$(find "$DSR_STATE_DIR" -print | LC_ALL=C sort)" &&
       ! -e "$DSR_CONFIG_DIR" && ! -e "$DSR_CACHE_DIR" ]] || return 1
  done
}

# This is a real kernel file-size limit, not a failing cat/cp substitute. The
# hosts default exceeds one KiB; all customized originals fit below the limit.
test_init_file_size_limit_preserves_live_files() {
  _init_custom_config_files || return 1
  local before status=0 index path
  local -a paths=("$DSR_CONFIG_FILE" "$DSR_HOSTS_FILE" "$DSR_REPOS_FILE") matches=() limited_status=()
  before=$(cksum "${paths[@]}") || return 1
  # Write diagnostics through an unrestricted parent. Bash may print the
  # entire failed heredoc; limiting that log too would kill the shell itself.
  (
    ulimit -c 0 || exit 1
    ulimit -f 1 || exit 1
    config_init --force
  ) 2>&1 | command cat > "$TEMP_DIR/limited.stderr"
  limited_status=("${PIPESTATUS[@]}")
  status="${limited_status[0]}"
  [[ "$status" == 1 && "${limited_status[1]}" == 0 &&
     "$before" == "$(cksum "${paths[@]}")" ]] || return 1
  for ((index = 0; index < 3; index++)); do
    path="${paths[index]}"
    matches=("$path".bak.*)
    [[ ${#matches[@]} -eq 1 && -f "${matches[0]}" ]] || return 1
    cmp -s "$path" "${matches[0]}" || return 1
    [[ "$(_init_file_mode "$path")" == 640 ]] || return 1
  done
  # A handled staging failure must release its leases so a normal retry works.
  config_init --force
}

test_init_force_preserves_unrelated_hardlink() {
  _init_custom_config_files || return 1
  cp -p "$DSR_HOSTS_FILE" "$TEMP_DIR/original-hosts" || return 1
  ln "$DSR_HOSTS_FILE" "$TEMP_DIR/unrelated-hardlink" || return 1
  config_init --force || return 1
  cmp -s "$TEMP_DIR/original-hosts" "$TEMP_DIR/unrelated-hardlink" || return 1
  [[ ! "$DSR_HOSTS_FILE" -ef "$TEMP_DIR/unrelated-hardlink" &&
     "$(_init_file_mode "$TEMP_DIR/unrelated-hardlink")" == 640 ]] || return 1
  grep -q '^schema_version:' "$DSR_HOSTS_FILE"
}

test_init_new_files_are_private() (
  umask 000
  config_init || return 1
  local path
  for path in "$DSR_CONFIG_FILE" "$DSR_HOSTS_FILE" "$DSR_REPOS_FILE"; do
    [[ "$(_init_file_mode "$path")" == 600 ]] || return 1
  done
)

test_init_partial_configuration_keeps_existing_file() {
  mkdir -p "$DSR_CONFIG_DIR" || return 1
  printf 'hosts: {custom: {ssh_host: retained-builder}}\n' > "$DSR_HOSTS_FILE" || return 1
  chmod 400 "$DSR_HOSTS_FILE" || return 1
  cp -p "$DSR_HOSTS_FILE" "$TEMP_DIR/original-hosts" || return 1
  ln "$DSR_HOSTS_FILE" "$TEMP_DIR/existing-hosts-inode" || return 1
  _config_init_cli --json config init --dry-run || return 1
  [[ ! -e "$DSR_CONFIG_FILE" && ! -e "$DSR_REPOS_FILE" &&
     ! -e "$DSR_CACHE_DIR" && ! -e "$DSR_STATE_DIR" ]] || return 1
  jq -e --arg config "$DSR_CONFIG_FILE" --arg repos "$DSR_REPOS_FILE" '
    .details.initialized == false and .details.backup_paths == [] and
    (.details.planned_files | sort) == ([$config,$repos] | sort)
    ' "$TEMP_DIR/init.stdout" >/dev/null || return 1
  config_init || return 1
  cmp -s "$TEMP_DIR/original-hosts" "$DSR_HOSTS_FILE" || return 1
  [[ "$DSR_HOSTS_FILE" -ef "$TEMP_DIR/existing-hosts-inode" &&
     "$(_init_file_mode "$DSR_HOSTS_FILE")" == 400 &&
     "$(_init_file_mode "$DSR_CONFIG_FILE")" == 600 &&
     "$(_init_file_mode "$DSR_REPOS_FILE")" == 600 &&
     ${#_DSR_CONFIG_INIT_BACKUP_PATHS[@]} -eq 0 ]]
}

test_init_force_partial_configuration_reports_only_real_backup() {
  mkdir -p "$DSR_CONFIG_DIR" || return 1
  printf 'hosts: {custom: {ssh_host: retained-builder}}\n' > "$DSR_HOSTS_FILE" || return 1
  chmod 400 "$DSR_HOSTS_FILE" || return 1
  cp -p "$DSR_HOSTS_FILE" "$TEMP_DIR/original-hosts" || return 1
  _config_init_cli --quiet --json config init --force || return 1
  jq -e '.details.initialized == true and .details.force == true and
    (.details.backup_paths | length) == 1' "$TEMP_DIR/init.stdout" >/dev/null || return 1
  local backup
  backup=$(jq -r '.details.backup_paths[0]' "$TEMP_DIR/init.stdout") || return 1
  cmp -s "$TEMP_DIR/original-hosts" "$backup" || return 1
  [[ "$(_init_file_mode "$backup")" == 400 &&
     "$(_init_file_mode "$DSR_HOSTS_FILE")" == 400 &&
     "$(_init_file_mode "$DSR_CONFIG_FILE")" == 600 &&
     "$(_init_file_mode "$DSR_REPOS_FILE")" == 600 ]]
}

test_init_force_preserves_restrictive_modes() (
  _init_custom_config_files || return 1
  chmod 400 "$DSR_CONFIG_FILE" || return 1
  chmod 600 "$DSR_REPOS_FILE" || return 1
  umask 077
  local index
  local -a paths=("$DSR_CONFIG_FILE" "$DSR_HOSTS_FILE" "$DSR_REPOS_FILE") modes=(400 640 600)
  for ((index = 0; index < 3; index++)); do
    cp -p "${paths[index]}" "$TEMP_DIR/original.$index" || return 1
  done
  config_init --force || return 1
  [[ ${#_DSR_CONFIG_INIT_BACKUP_PATHS[@]} -eq 3 ]] || return 1
  for ((index = 0; index < 3; index++)); do
    [[ "$(_init_file_mode "${paths[index]}")" == "${modes[index]}" &&
       "$(_init_file_mode "${_DSR_CONFIG_INIT_BACKUP_PATHS[index]}")" == "${modes[index]}" ]] || return 1
    cmp -s "$TEMP_DIR/original.$index" "${_DSR_CONFIG_INIT_BACKUP_PATHS[index]}" || return 1
    grep -q '^schema_version:' "${paths[index]}" || return 1
  done
)

# Explicit publication-boundary failure injection. The "after" case performs
# the real rename and then returns failure, exercising an ambiguous result.
_init_failed_publication_case() {
  local failure_point="$1" fail_once=true status=0 index
  local -a paths=("$DSR_CONFIG_FILE" "$DSR_HOSTS_FILE" "$DSR_REPOS_FILE")
  _init_custom_config_files || return 1
  for ((index = 0; index < 3; index++)); do
    cp -p "${paths[index]}" "$TEMP_DIR/original.$index" || return 1
  done
  mv() {
    local destination="${!#}"
    if [[ "$destination" == "$DSR_HOSTS_FILE" && "$fail_once" == true ]]; then
      fail_once=false
      [[ "$failure_point" != after ]] || command mv "$@" || return 1
      return 1
    fi
    command mv "$@"
  }
  config_init --force || status=$?
  [[ "$status" == 1 && ${#_DSR_CONFIG_INIT_BACKUP_PATHS[@]} -eq 3 &&
     "${_DSR_CONFIG_INIT_ROLLED_BACK:-false}" == true &&
     "${_DSR_CONFIG_INIT_RECOVERY_REQUIRED:-true}" == false ]] || return 1
  for ((index = 0; index < 3; index++)); do
    cmp -s "$TEMP_DIR/original.$index" "${paths[index]}" || return 1
    cmp -s "$TEMP_DIR/original.$index" "${_DSR_CONFIG_INIT_BACKUP_PATHS[index]}" || return 1
    [[ "$(_init_file_mode "${paths[index]}")" == 640 ]] || return 1
  done
  config_init --force
}

test_init_failed_publication_rolls_back() (
  _init_failed_publication_case before
)

test_init_ambiguous_publication_rolls_back() (
  _init_failed_publication_case after
)

# The injected scheduling boundary creates a real conflicting destination;
# the production ln must refuse it without overwriting the new file's bytes.
test_init_fresh_publication_never_clobbers_new_file() (
  local status=0 injected=false
  ln() {
    if [[ "${!#}" == "$DSR_HOSTS_FILE" && "$injected" == false ]]; then
      injected=true
      printf 'concurrent configuration\n' > "$DSR_HOSTS_FILE" || return 1
    fi
    command ln "$@"
  }
  config_init || status=$?
  [[ "$injected" == true && "$status" -ne 0 &&
     ! -e "$DSR_CONFIG_FILE" && ! -e "$DSR_REPOS_FILE" ]] || return 1
  [[ "$(cat "$DSR_HOSTS_FILE")" == 'concurrent configuration' ]]
)

# An external editor changes an already published file before the second
# rename fails. Recovery must preserve that newer edit and all old backups.
test_init_rollback_preserves_intervening_edit() (
  _init_custom_config_files || return 1
  local status=0 fail_once=true index
  local -a paths=("$DSR_CONFIG_FILE" "$DSR_HOSTS_FILE" "$DSR_REPOS_FILE")
  for ((index = 0; index < 3; index++)); do
    cp -p "${paths[index]}" "$TEMP_DIR/original.$index" || return 1
  done
  mv() {
    if [[ "${!#}" == "$DSR_HOSTS_FILE" && "$fail_once" == true ]]; then
      fail_once=false
      printf 'newer edit from another process\n' > "$DSR_CONFIG_FILE" || return 1
      return 1
    fi
    command mv "$@"
  }
  config_init --force || status=$?
  [[ "$status" -ne 0 && "${_DSR_CONFIG_INIT_RECOVERY_REQUIRED:-false}" == true &&
     "$(cat "$DSR_CONFIG_FILE")" == 'newer edit from another process' &&
     ${#_DSR_CONFIG_INIT_BACKUP_PATHS[@]} -eq 3 ]] || return 1
  for ((index = 0; index < 3; index++)); do
    cmp -s "$TEMP_DIR/original.$index" "${_DSR_CONFIG_INIT_BACKUP_PATHS[index]}" || return 1
  done
  cmp -s "$TEMP_DIR/original.1" "$DSR_HOSTS_FILE" &&
    cmp -s "$TEMP_DIR/original.2" "$DSR_REPOS_FILE"
)

test_cli_init_publication_failure_reports_rollback() (
  _init_custom_config_files || return 1
  local before status=0
  before=$(cksum "$DSR_CONFIG_FILE" "$DSR_HOSTS_FILE" "$DSR_REPOS_FILE") || return 1
  mv() {
    if [[ "${!#}" == "$DSR_HOSTS_FILE" && "${DSR_TEST_MV_FAILED:-false}" == false ]]; then
      DSR_TEST_MV_FAILED=true
      return 1
    fi
    command mv "$@"
  }
  export -f mv
  _config_init_cli --quiet --json config init --force || status=$?
  [[ "$status" == 1 && "$before" == "$(cksum "$DSR_CONFIG_FILE" "$DSR_HOSTS_FILE" "$DSR_REPOS_FILE")" ]] || return 1
  jq -es 'length == 1 and (.[0] | .status == "error" and .exit_code == 1 and
    .details.initialized == false and .details.dry_run == false and
    .details.rolled_back == true and .details.recovery_required == false and
    (.details.backup_paths | length) == 3 and
    any(.details.errors[]; (.message | type) == "string" and (.message | length) > 0))' \
    "$TEMP_DIR/init.stdout" >/dev/null
)

# Explicit restore-copy failure after a real first publication. Active files
# remain whole, originals stay in backups, and the retained lease blocks retry.
test_init_failed_rollback_retains_recovery_files() (
  local status=0 fail_once=true index path
  local -a paths=("$DSR_CONFIG_FILE" "$DSR_HOSTS_FILE" "$DSR_REPOS_FILE")
  config_init || return 1
  cp -p "$DSR_CONFIG_FILE" "$TEMP_DIR/default-config" || return 1
  _init_custom_config_files || return 1
  for ((index = 0; index < 3; index++)); do
    cp -p "${paths[index]}" "$TEMP_DIR/original.$index" || return 1
  done
  mv() {
    if [[ "${!#}" == "$DSR_HOSTS_FILE" && "$fail_once" == true ]]; then
      fail_once=false
      return 1
    fi
    command mv "$@"
  }
  cp() {
    [[ "${!#}" != */restore ]] || return 1
    command cp "$@"
  }
  config_init --force || status=$?
  [[ "$status" == 1 && "${_DSR_CONFIG_INIT_RECOVERY_REQUIRED:-false}" == true &&
     ${#_DSR_CONFIG_INIT_BACKUP_PATHS[@]} -eq 3 ]] || return 1
  cmp -s "$TEMP_DIR/default-config" "$DSR_CONFIG_FILE" || return 1
  cmp -s "$TEMP_DIR/original.1" "$DSR_HOSTS_FILE" || return 1
  cmp -s "$TEMP_DIR/original.2" "$DSR_REPOS_FILE" || return 1
  for ((index = 0; index < 3; index++)); do
    path="${paths[index]}"
    cmp -s "$TEMP_DIR/original.$index" "${_DSR_CONFIG_INIT_BACKUP_PATHS[index]}" || return 1
    [[ -d "$path.init.lock" ]] || return 1
  done
  status=0
  config_init --force || status=$?
  [[ "$status" == 2 ]]
)

# Explicit cleanup-boundary injection, after every real publication succeeds.
# The JSON result must not claim completion when a private lease is retained.
test_cli_init_failed_cleanup_reports_recovery() (
  local status=0 index path backup
  local -a paths=("$DSR_CONFIG_FILE" "$DSR_HOSTS_FILE" "$DSR_REPOS_FILE")
  config_init || return 1
  for ((index = 0; index < 3; index++)); do
    cp -p "${paths[index]}" "$TEMP_DIR/default.$index" || return 1
  done
  _init_custom_config_files || return 1
  for ((index = 0; index < 3; index++)); do
    cp -p "${paths[index]}" "$TEMP_DIR/original.$index" || return 1
  done
  rm() {
    local argument
    if [[ "${DSR_TEST_CLEANUP_FAILED:-false}" == false ]]; then
      for argument in "$@"; do
        if [[ "$argument" == */expected ]]; then
          DSR_TEST_CLEANUP_FAILED=true
          return 1
        fi
      done
    fi
    command rm "$@"
  }
  export -f rm
  _config_init_cli --quiet --json config init --force || status=$?
  [[ "$status" == 1 ]] || return 1
  jq -es 'length == 1 and (.[0] | .status == "error" and .exit_code == 1 and
    .details.initialized == false and .details.recovery_required == true and
    (.details.backup_paths | length) == 3 and (.details.errors | length) > 0)' \
    "$TEMP_DIR/init.stdout" >/dev/null || return 1
  [[ -d "$DSR_CONFIG_FILE.init.lock" ]] || return 1
  for ((index = 0; index < 3; index++)); do
    path="${paths[index]}"
    cmp -s "$TEMP_DIR/default.$index" "$path" || return 1
    backup=$(jq -r --argjson index "$index" '.details.backup_paths[$index]' "$TEMP_DIR/init.stdout") || return 1
    cmp -s "$TEMP_DIR/original.$index" "$backup" || return 1
  done
)

test_init_exported_function_can_preview_in_child() {
  env DSR_CONFIG_DIR="$DSR_CONFIG_DIR" DSR_CONFIG_FILE="$DSR_CONFIG_FILE" \
    DSR_HOSTS_FILE="$DSR_HOSTS_FILE" DSR_REPOS_FILE="$DSR_REPOS_FILE" \
    DSR_CACHE_DIR="$DSR_CACHE_DIR" DSR_STATE_DIR="$DSR_STATE_DIR" \
    DRY_RUN=true bash -u -c 'config_init --force' \
    > "$TEMP_DIR/exported.stdout" 2> "$TEMP_DIR/exported.stderr" || return 1
  [[ ! -s "$TEMP_DIR/exported.stdout" ]] && _init_roots_absent || return 1
  grep -q '\[dry-run\]' "$TEMP_DIR/exported.stderr" || return 1
  ! grep -Eq 'command not found|unbound variable' "$TEMP_DIR/exported.stderr"
}

test_cli_init_log_alias_cannot_modify_configuration() {
  local variant index root log_path backup
  local -a paths=() args=()
  config_init || return 1
  paths=("$DSR_CONFIG_FILE" "$DSR_HOSTS_FILE" "$DSR_REPOS_FILE")
  for ((index = 0; index < 3; index++)); do
    cp -p "${paths[index]}" "$TEMP_DIR/default.$index" || return 1
  done
  for variant in force-direct keep-direct force-hardlink keep-hardlink; do
    root="$TEMP_DIR/$variant"
    DSR_CONFIG_DIR="$root/config"
    DSR_CACHE_DIR="$root/cache"
    DSR_STATE_DIR="$root/state"
    DSR_CONFIG_FILE="$DSR_CONFIG_DIR/config.yaml"
    DSR_HOSTS_FILE="$DSR_CONFIG_DIR/hosts.yaml"
    DSR_REPOS_FILE="$DSR_CONFIG_DIR/repos.yaml"
    paths=("$DSR_CONFIG_FILE" "$DSR_HOSTS_FILE" "$DSR_REPOS_FILE")
    _init_custom_config_files || return 1
    for ((index = 0; index < 3; index++)); do
      cp -p "${paths[index]}" "$root/original.$index" || return 1
    done
    log_path="$DSR_HOSTS_FILE"
    if [[ "$variant" == *-hardlink ]]; then
      log_path="$root/inherited.log"
      ln "$DSR_HOSTS_FILE" "$log_path" || return 1
    fi
    args=()
    [[ "$variant" != force-* ]] || args+=(--force)
    env DSR_CONFIG_DIR="$DSR_CONFIG_DIR" DSR_CONFIG_FILE="$DSR_CONFIG_FILE" \
      DSR_HOSTS_FILE="$DSR_HOSTS_FILE" DSR_REPOS_FILE="$DSR_REPOS_FILE" \
      DSR_CACHE_DIR="$DSR_CACHE_DIR" DSR_STATE_DIR="$DSR_STATE_DIR" DSR_LOG_FILE="$log_path" \
      bash "$SRC_DIR/../dsr" --json config init ${args[@]+"${args[@]}"} \
      > "$root/result.json" 2> "$root/stderr" || return 1
    jq -es 'length == 1 and (.[0] | .status == "success" and .exit_code == 0 and
      .details.initialized == true and .details.dry_run == false)' "$root/result.json" >/dev/null || return 1
    for ((index = 0; index < 3; index++)); do
      if [[ "$variant" == force-* ]]; then
        cmp -s "$TEMP_DIR/default.$index" "${paths[index]}" || return 1
        backup=$(jq -r --argjson index "$index" '.details.backup_paths[$index]' "$root/result.json") || return 1
        cmp -s "$root/original.$index" "$backup" || return 1
      else
        cmp -s "$root/original.$index" "${paths[index]}" || return 1
        jq -e '.details.backup_paths == []' "$root/result.json" >/dev/null || return 1
      fi
    done
    if [[ "$variant" == *-hardlink ]]; then
      cmp -s "$root/original.1" "$log_path" || return 1
    fi
    # JSON init must be quiet without requiring the unrelated --quiet flag.
    [[ ! -s "$root/stderr" ]] || return 1
  done
}

test_init_preserves_callers_signal_traps() (
  trap ':' HUP INT TERM EXIT
  local before
  before=$(trap -p HUP INT TERM EXIT)
  config_init || return 1
  config_init --force --dry-run || return 1
  config_init --force || return 1
  [[ "$before" == "$(trap -p HUP INT TERM EXIT)" ]]
)

# The mv wrapper is only a timing barrier: publication uses the real mv, and
# the parent sends a genuine SIGKILL while the child blocks in a builtin read.
# This checks process interruption, not filesystem power-loss durability.
test_init_killed_publication_is_recoverable() (
  local index child_pid='' status=0 before attempt path restore
  local -a paths=("$DSR_CONFIG_FILE" "$DSR_HOSTS_FILE" "$DSR_REPOS_FILE") matches=() backups=()
  config_init || return 1
  for ((index = 0; index < 3; index++)); do
    cp -p "${paths[index]}" "$TEMP_DIR/default.$index" || return 1
  done
  _init_custom_config_files || return 1
  for ((index = 0; index < 3; index++)); do
    cp -p "${paths[index]}" "$TEMP_DIR/original.$index" || return 1
  done
  mkfifo "$TEMP_DIR/publication-barrier" || return 1
  trap 'if [[ -n "$child_pid" ]] && kill -0 "$child_pid" 2>/dev/null; then kill -KILL "$child_pid" 2>/dev/null; wait "$child_pid" 2>/dev/null || true; fi' EXIT
  (
    mv() {
      command mv "$@" || return $?
      if [[ "${!#}" == "$DSR_CONFIG_FILE" ]]; then
        printf 'published\n' > "$TEMP_DIR/publication-ready" || return 1
        local barrier_release
        IFS= read -r barrier_release < "$TEMP_DIR/publication-barrier" || return 1
        [[ "$barrier_release" == continue ]]
      fi
    }
    config_init --force
  ) > "$TEMP_DIR/killed.stdout" 2> "$TEMP_DIR/killed.stderr" &
  child_pid=$!
  for ((attempt = 0; attempt < 100; attempt++)); do
    [[ ! -f "$TEMP_DIR/publication-ready" ]] || break
    kill -0 "$child_pid" 2>/dev/null || return 1
    sleep 0.05
  done
  [[ -f "$TEMP_DIR/publication-ready" ]] || return 1
  # A simultaneous initializer must fail without stealing the active lease.
  before=$(cksum "${paths[@]}") || return 1
  config_init --force || status=$?
  [[ "$status" == 2 && "$before" == "$(cksum "${paths[@]}")" ]] || return 1
  kill -KILL "$child_pid" || return 1
  status=0
  wait "$child_pid" || status=$?
  child_pid=''
  [[ "$status" == 137 ]] || return 1
  cmp -s "$DSR_CONFIG_FILE" "$TEMP_DIR/default.0" || return 1
  cmp -s "$DSR_HOSTS_FILE" "$TEMP_DIR/original.1" || return 1
  cmp -s "$DSR_REPOS_FILE" "$TEMP_DIR/original.2" || return 1
  status=0
  config_init --force || status=$?
  [[ "$status" == 2 && "$before" == "$(cksum "${paths[@]}")" ]] || return 1
  status=0
  config_init || status=$?
  [[ "$status" == 2 && "$before" == "$(cksum "${paths[@]}")" ]] || return 1
  for ((index = 0; index < 3; index++)); do
    path="${paths[index]}"
    matches=("$path".bak.*)
    [[ ${#matches[@]} -eq 1 && -f "${matches[0]}" && -d "$path.init.lock" ]] || return 1
    backups+=("${matches[0]}")
    cmp -s "$TEMP_DIR/original.$index" "${matches[0]}" || return 1
    [[ "$(cat "$path.init.lock"/stage.*/backup-path)" == "${matches[0]}" ]] || return 1
    # Actually exercise documented manual recovery: copy to a sibling stage,
    # rename into place, and retain both the backup and interrupted evidence.
    restore=$(mktemp "$path.restore.XXXXXXXX") || return 1
    cp -p "${matches[0]}" "$restore" || return 1
    mv -f "$restore" "$path" || return 1
    mv "$path.init.lock" "$path.interrupted" || return 1
    cmp -s "$TEMP_DIR/original.$index" "$path" || return 1
    [[ "$(_init_file_mode "$path")" == 640 ]] || return 1
  done
  config_init --force || return 1
  for ((index = 0; index < 3; index++)); do
    cmp -s "$TEMP_DIR/original.$index" "${backups[index]}" || return 1
  done
)

# ============================================================================
# Tests: Loading (config_load)
# ============================================================================

test_load_sets_defaults() {
  config_load
  [[ -n "${DSR_CONFIG[threshold_seconds]:-}" ]] && \
  [[ -n "${DSR_CONFIG[log_level]:-}" ]]
}

test_load_default_threshold() {
  config_load
  [[ "${DSR_CONFIG[threshold_seconds]}" == "600" ]]
}

test_load_default_log_level() {
  config_load
  [[ "${DSR_CONFIG[log_level]}" == "info" ]]
}

test_load_reads_config_file() {
  config_init
  # Add custom value to config
  echo "custom_key: custom_value" >> "$DSR_CONFIG_FILE"
  config_load
  [[ "${DSR_CONFIG[custom_key]:-}" == "custom_value" ]]
}

test_load_env_overrides_file() {
  config_init
  config_load
  # Set env var override
  export DSR_LOG_LEVEL="debug"
  config_load
  local result="${DSR_CONFIG[log_level]}"
  unset DSR_LOG_LEVEL
  [[ "$result" == "debug" ]]
}

test_load_threshold_env_override() {
  config_init
  export DSR_THRESHOLD="1200"
  config_load
  local result="${DSR_CONFIG[threshold_seconds]}"
  unset DSR_THRESHOLD
  [[ "$result" == "1200" ]]
}

test_load_signing_disabled_by_env() {
  config_init
  export DSR_NO_SIGN="1"
  config_load
  local result="${DSR_CONFIG[signing_enabled]}"
  unset DSR_NO_SIGN
  [[ "$result" == "false" ]]
}

test_load_resets_config() {
  config_load
  # shellcheck disable=SC2154  # test_key is a literal associative array key, not a variable
  DSR_CONFIG[test_key]="test_value"
  config_load  # Should reset
  # shellcheck disable=SC2154
  [[ -z "${DSR_CONFIG[test_key]:-}" ]]
}

test_load_rejects_invalid_documents_without_changing_memory() {
  _init_custom_config_files || return 1
  config_load || return 1
  DSR_CONFIG[preserved_key]=$'retained\nvalue\n'
  local memory before status kind
  memory=$(declare -p DSR_CONFIG)
  for kind in malformed duplicate multiple_documents sequence scalar unsupported_schema schema_number nul_value nul_key flattened_collision; do
    case "$kind" in
      malformed) printf 'threshold_seconds: [\n' > "$DSR_CONFIG_FILE" ;;
      duplicate) printf 'threshold_seconds: 300\nthreshold_seconds: 900\n' > "$DSR_CONFIG_FILE" ;;
      multiple_documents) printf 'threshold_seconds: 300\n---\nthreshold_seconds: 900\n' > "$DSR_CONFIG_FILE" ;;
      sequence) printf '%s\n' '- threshold_seconds: 300' > "$DSR_CONFIG_FILE" ;;
      scalar) printf 'not-a-mapping\n' > "$DSR_CONFIG_FILE" ;;
      unsupported_schema) printf 'schema_version: "99.0.0"\nthreshold_seconds: 900\n' > "$DSR_CONFIG_FILE" ;;
      schema_number) printf 'schema_version: 1\nthreshold_seconds: 900\n' > "$DSR_CONFIG_FILE" ;;
      nul_value) printf '%s\n' 'value: "before\u0000after"' > "$DSR_CONFIG_FILE" ;;
      nul_key) printf '%s\n' '"before\u0000after": value' > "$DSR_CONFIG_FILE" ;;
      flattened_collision) printf '"signing.enabled": false\nsigning:\n  enabled: true\n' > "$DSR_CONFIG_FILE" ;;
    esac
    before=$(cksum "$DSR_CONFIG_FILE") || return 1
    status=0
    config_load || status=$?
    [[ "$status" == 4 && "$memory" == "$(declare -p DSR_CONFIG)" &&
       "$before" == "$(cksum "$DSR_CONFIG_FILE")" &&
       ! -e "$DSR_CACHE_DIR" && ! -e "$DSR_STATE_DIR" ]] || return 1
  done
}

# Run the genuine parser, then inject a failed exit after its output. A
# process-substitution reader must not mistake that output for a successful load.
test_load_parser_failure_preserves_memory() (
  _init_custom_config_files || return 1
  DSR_CONFIG[preserved_key]=original-memory
  local memory before status=0
  memory=$(declare -p DSR_CONFIG)
  before=$(cksum "$DSR_CONFIG_FILE") || return 1
  yq() {
    command yq "$@" || return $?
    return 17
  }
  config_load || status=$?
  [[ "$status" -ne 0 && "$memory" == "$(declare -p DSR_CONFIG)" &&
     "$before" == "$(cksum "$DSR_CONFIG_FILE")" ]]
)

# The final serializer really emits every value, then reports failure. The
# loader must require successful completion even if its caller disabled pipefail.
test_load_serializer_failure_preserves_memory_without_pipefail() (
  _init_custom_config_files || return 1
  DSR_CONFIG[preserved_key]=$'original\nmemory\n'
  local memory status=0
  memory=$(declare -p DSR_CONFIG)
  jq() {
    command jq "$@" || return $?
    [[ "${1:-}" != -j ]] || return 29
  }
  set +o pipefail
  config_load || status=$?
  [[ "$status" == 3 && "$memory" == "$(declare -p DSR_CONFIG)" ]]
)

test_load_missing_dependencies_preserve_memory() {
  _init_custom_config_files || return 1
  DSR_CONFIG[preserved_key]=original-memory
  local memory before tool_path status
  memory=$(declare -p DSR_CONFIG)
  before=$(cksum "$DSR_CONFIG_FILE") || return 1
  mkdir "$TEMP_DIR/only-jq" "$TEMP_DIR/only-yq" || return 1
  ln -s "$(command -v jq)" "$TEMP_DIR/only-jq/jq" || return 1
  ln -s "$(command -v yq)" "$TEMP_DIR/only-yq/yq" || return 1
  # Each parser is genuinely absent from PATH in turn; no replacement parser.
  for tool_path in "$TEMP_DIR/only-jq" "$TEMP_DIR/only-yq"; do
    status=0
    PATH="$tool_path" config_load || status=$?
    [[ "$status" == 3 && "$memory" == "$(declare -p DSR_CONFIG)" &&
       "$before" == "$(cksum "$DSR_CONFIG_FILE")" ]] || return 1
  done
}

test_load_missing_config_defaults_without_parsers() {
  DSR_CONFIG[preserved_key]=stale-memory
  PATH="$TEMP_DIR/no-installed-tools" config_load || return 1
  [[ "${DSR_CONFIG[threshold_seconds]:-}" == 600 &&
     "${DSR_CONFIG[schema_version]:-}" == "$DSR_SCHEMA_VERSION" &&
     -z "${DSR_CONFIG[preserved_key]+present}" ]] && _init_roots_absent
}

test_load_empty_config_defaults_without_parsers() {
  mkdir -p "$DSR_CONFIG_DIR" || return 1
  : > "$DSR_CONFIG_FILE"
  DSR_CONFIG[preserved_key]=stale-memory
  PATH="$TEMP_DIR/no-installed-tools" config_load || return 1
  [[ "${DSR_CONFIG[threshold_seconds]:-}" == 600 &&
     -z "${DSR_CONFIG[preserved_key]+present}" && ! -s "$DSR_CONFIG_FILE" &&
     ! -e "$DSR_CACHE_DIR" && ! -e "$DSR_STATE_DIR" ]]
}

test_load_legacy_schema_remains_readable() {
  mkdir -p "$DSR_CONFIG_DIR" || return 1
  local kind
  for kind in absent null empty; do
    case "$kind" in
      absent) printf 'threshold_seconds: 300\n' > "$DSR_CONFIG_FILE" ;;
      null) printf 'schema_version: null\nthreshold_seconds: 300\n' > "$DSR_CONFIG_FILE" ;;
      empty) printf 'schema_version: ""\nthreshold_seconds: 300\n' > "$DSR_CONFIG_FILE" ;;
    esac
    config_load || return 1
    [[ "${DSR_CONFIG[threshold_seconds]:-}" == 300 ]] || return 1
  done
}

test_load_scalar_values_are_preserved() {
  mkdir -p "$DSR_CONFIG_DIR" || return 1
  cat > "$DSR_CONFIG_FILE" <<'YAML'
schema_version: "1.0.0"
false_value: false
null_value: null
empty_value: ""
zero_value: 0
YAML
  config_load || return 1
  [[ "${DSR_CONFIG[false_value]:-}" == false &&
     "${DSR_CONFIG[null_value]:-}" == null &&
     -n "${DSR_CONFIG[empty_value]+present}" && "${DSR_CONFIG[empty_value]}" == '' &&
     "${DSR_CONFIG[zero_value]:-}" == 0 ]] || return 1
  _config_mutation_cli --json config show || return 1
  [[ ! -s "$TEMP_DIR/mutation.stderr" ]] || return 1
  jq -es 'length == 1 and (.[0] | .status == "success" and
    .details.values.false_value == "false" and .details.values.null_value == "null" and
    .details.values.empty_value == "" and .details.values.zero_value == "0")' \
    "$TEMP_DIR/mutation.stdout" >/dev/null
}

test_load_persisted_values_roundtrip() {
  _init_custom_config_files || return 1
  local index key value
  local -a values=('' '-n' 'left = right' 'C:\tools\bin\file' $'embedded\nline' $'trailing\n\n' $'tab\tcarriage\rreturn' ' leading and trailing ')
  for ((index = 0; index < ${#values[@]}; index++)); do
    key="roundtrip_$index"
    value="${values[index]}"
    config_set "$key" "$value" --persist || return 1
    DSR_CONFIG["$key"]=stale-memory
    config_load || return 1
    [[ -n "${DSR_CONFIG[$key]+present}" && "${DSR_CONFIG[$key]}" == "$value" ]] || return 1
    # File comparison retains trailing newlines and exposes echo's -n option.
    printf '%s\n' "$value" > "$TEMP_DIR/expected-value"
    config_get "$key" > "$TEMP_DIR/actual-value" || return 1
    cmp -s "$TEMP_DIR/expected-value" "$TEMP_DIR/actual-value" || return 1
    _config_mutation_cli --json config get "$key" || return 1
    [[ ! -s "$TEMP_DIR/mutation.stderr" ]] || return 1
    jq -es --arg key "$key" --arg value "$value" 'length == 1 and (.[0] |
      .status == "success" and .exit_code == 0 and .details.action == "get" and
      .details.key == $key and .details.value == $value)' "$TEMP_DIR/mutation.stdout" >/dev/null || return 1
  done
}

test_cli_set_values_roundtrip() {
  _init_custom_config_files || return 1
  local value
  for value in '' $'-n = C:\\tools\\file\nlast line\n\n'; do
    _config_mutation_cli --json config set "roundtrip_value=$value" || return 1
    [[ ! -s "$TEMP_DIR/mutation.stderr" ]] || return 1
    jq -es --arg value "$value" 'length == 1 and (.[0] |
      .status == "success" and .details.persisted == true and .details.value == $value)' \
      "$TEMP_DIR/mutation.stdout" >/dev/null || return 1
    _config_mutation_cli --json config get roundtrip_value || return 1
    [[ ! -s "$TEMP_DIR/mutation.stderr" ]] || return 1
    jq -es --arg value "$value" 'length == 1 and (.[0] |
      .status == "success" and .details.value == $value)' "$TEMP_DIR/mutation.stdout" >/dev/null || return 1
  done
}

test_load_signing_environment_flags_use_real_policy() (
  unset DSR_NO_SIGN DSR_SIGNING_ENABLED DSR_MINISIGN_KEY
  # shellcheck source=../../src/signing.sh
  source "$SRC_DIR/signing.sh"
  mkdir -p "$DSR_CONFIG_DIR" || return 1
  printf 'schema_version: "1.0.0"\nsigning:\n  enabled: true\n' > "$DSR_CONFIG_FILE"
  local flag status expected
  for flag in false 0 true 1; do
    export DSR_NO_SIGN="$flag"
    config_load || return 1
    expected=0
    [[ "$flag" != true && "$flag" != 1 ]] || expected=1
    status=0
    signing_wanted || status=$?
    [[ "$status" == "$expected" ]] || return 1
  done
)

test_load_signing_yaml_flags_use_real_policy() (
  unset DSR_NO_SIGN DSR_SIGNING_ENABLED DSR_MINISIGN_KEY
  # shellcheck source=../../src/signing.sh
  source "$SRC_DIR/signing.sh"
  mkdir -p "$DSR_CONFIG_DIR" || return 1
  local flag status expected
  for flag in false 0 true 1 False TRUE; do
    printf 'schema_version: "1.0.0"\nsigning:\n  enabled: %s\n' "$flag" > "$DSR_CONFIG_FILE"
    config_load || return 1
    expected=0
    [[ "$flag" != false && "$flag" != 0 && "$flag" != False ]] || expected=1
    status=0
    signing_wanted || status=$?
    [[ "$status" == "$expected" ]] || return 1
  done
)

test_cli_read_commands_report_config_errors() {
  mkdir -p "$DSR_CONFIG_DIR" || return 1
  printf 'threshold_seconds: [\n' > "$DSR_CONFIG_FILE" || return 1
  local action mode status before paths
  before=$(cksum "$DSR_CONFIG_FILE") || return 1
  paths=$(find "$DSR_CONFIG_DIR" -print | LC_ALL=C sort) || return 1
  for action in show get validate; do
    for mode in human json; do
      set -- config "$action"
      [[ "$action" != get ]] || set -- "$@" threshold_seconds
      [[ "$mode" != json ]] || set -- --json "$@"
      status=0
      _config_mutation_cli "$@" || status=$?
      [[ "$status" == 4 && "$before" == "$(cksum "$DSR_CONFIG_FILE")" &&
         "$paths" == "$(find "$DSR_CONFIG_DIR" -print | LC_ALL=C sort)" &&
         ! -e "$DSR_CACHE_DIR" && ! -e "$DSR_STATE_DIR" ]] || return 1
      if [[ "$mode" == json ]]; then
        jq -es --arg action "$action" --arg file "$DSR_CONFIG_FILE" 'length == 1 and (.[0] |
          .status == "error" and .exit_code == 4 and .details.action == $action and
          .details.config_file == $file and (.details.errors | length) > 0 and
          (if $action == "validate" then .details.valid == false else true end))' \
          "$TEMP_DIR/mutation.stdout" >/dev/null || return 1
      else
        [[ ! -s "$TEMP_DIR/mutation.stdout" && -s "$TEMP_DIR/mutation.stderr" ]] || return 1
      fi
    done
  done
}

# ============================================================================
# Tests: Get/Set (config_get, config_set)
# ============================================================================

test_get_returns_value() {
  config_load
  local result
  result=$(config_get "threshold_seconds")
  [[ "$result" == "600" ]]
}

test_get_returns_default() {
  config_load
  local result
  result=$(config_get "nonexistent_key" "default_value")
  [[ "$result" == "default_value" ]]
}

test_get_returns_empty_for_missing() {
  config_load
  local result
  result=$(config_get "nonexistent_key")
  [[ -z "$result" ]]
}

test_set_updates_value() {
  config_load
  config_set "threshold_seconds" "1800"
  local result
  result=$(config_get "threshold_seconds")
  [[ "$result" == "1800" ]]
}

test_set_creates_new_key() {
  config_load
  config_set "new_key" "new_value"
  local result
  result=$(config_get "new_key")
  [[ "$result" == "new_value" ]]
}

test_set_persist_requires_yq() {
  _init_custom_config_files || return 1
  DSR_CONFIG[test_key]=original-memory-value
  local before memory status=0
  before=$(cksum "$DSR_CONFIG_FILE") || return 1
  memory=$(declare -p DSR_CONFIG)
  # A genuinely empty command search path, not a substitute yq program.
  PATH="$TEMP_DIR/no-installed-tools" config_set test_key changed --persist || status=$?
  [[ "$status" == 3 && "$memory" == "$(declare -p DSR_CONFIG)" &&
     "$before" == "$(cksum "$DSR_CONFIG_FILE")" &&
     ! -e "$DSR_CONFIG_FILE.init.lock" ]]
}

_config_mutation_cli() {
  env DSR_CONFIG_DIR="$DSR_CONFIG_DIR" DSR_CONFIG_FILE="$DSR_CONFIG_FILE" \
    DSR_REPOS_FILE="$DSR_REPOS_FILE" DSR_HOSTS_FILE="$DSR_HOSTS_FILE" \
    DSR_CACHE_DIR="$DSR_CACHE_DIR" DSR_STATE_DIR="$DSR_STATE_DIR" \
    DSR_LOG_FILE="${DSR_TEST_CONFIG_LOG_FILE:-$DSR_STATE_DIR/custom.log}" \
    bash "${DSR_TEST_CONFIG_CLI:-$SRC_DIR/../dsr}" "$@" \
    > "$TEMP_DIR/mutation.stdout" 2> "$TEMP_DIR/mutation.stderr"
}

test_set_dry_run_preserves_disk_and_memory() {
  _init_custom_config_files || return 1
  DSR_CONFIG[threshold_seconds]=original-memory-value
  local before memory paths variant
  before=$(cksum "$DSR_CONFIG_FILE") || return 1
  memory=$(declare -p DSR_CONFIG)
  paths=$(find "$DSR_CONFIG_DIR" -print | LC_ALL=C sort) || return 1
  for variant in 1 2 3 4; do
    case "$variant" in
      1) config_set threshold_seconds changed --dry-run || return 1 ;;
      2) config_set threshold_seconds changed --persist --dry-run || return 1 ;;
      3) config_set threshold_seconds changed -n --persist || return 1 ;;
      4) DRY_RUN=true config_set threshold_seconds changed --persist || return 1 ;;
    esac
    [[ "$memory" == "$(declare -p DSR_CONFIG)" &&
       "$before" == "$(cksum "$DSR_CONFIG_FILE")" &&
       "$paths" == "$(find "$DSR_CONFIG_DIR" -print | LC_ALL=C sort)" &&
       ! -e "$DSR_CACHE_DIR" && ! -e "$DSR_STATE_DIR" ]] || return 1
  done
}

test_cli_set_dry_run_flag_orders_preserve_files() {
  _init_custom_config_files || return 1
  local before paths variant
  before=$(cksum "$DSR_CONFIG_FILE" "$DSR_HOSTS_FILE" "$DSR_REPOS_FILE") || return 1
  paths=$(find "$DSR_CONFIG_DIR" -print | LC_ALL=C sort) || return 1
  for variant in 1 2 3 4 5 6; do
    case "$variant" in
      1) set -- --json --dry-run config set threshold_seconds=900 ;;
      2) set -- --json -n config set threshold_seconds=900 ;;
      3) set -- --json config set threshold_seconds=900 --dry-run ;;
      4) set -- --json config set -n threshold_seconds=900 ;;
      5) set -- config set threshold_seconds=900 --dry-run ;;
      6) set -- config set --dry-run threshold_seconds=900 ;;
    esac
    _config_mutation_cli "$@" || return 1
    [[ "$before" == "$(cksum "$DSR_CONFIG_FILE" "$DSR_HOSTS_FILE" "$DSR_REPOS_FILE")" &&
       "$paths" == "$(find "$DSR_CONFIG_DIR" -print | LC_ALL=C sort)" &&
       ! -e "$DSR_CACHE_DIR" && ! -e "$DSR_STATE_DIR" ]] || return 1
    if [[ "$variant" -le 4 ]]; then
      [[ ! -s "$TEMP_DIR/mutation.stderr" ]] || return 1
      jq -es 'length == 1 and (.[0] | .status == "success" and .exit_code == 0 and
        .details.action == "set" and .details.key == "threshold_seconds" and
        .details.value == "900" and .details.dry_run == true and
        .details.persisted == false and .details.backup_paths == [])' \
        "$TEMP_DIR/mutation.stdout" >/dev/null || return 1
    fi
  done
}

test_cli_edit_dry_run_never_launches_editor() (
  _init_custom_config_files || return 1
  local before paths variant
  export EDITOR="$TEMP_DIR/editor-probe" DSR_TEST_EDITOR_MARKER="$TEMP_DIR/editor-called"
  cat > "$EDITOR" <<'EDITOR'
#!/usr/bin/env bash
printf 'editor was executed\n' > "$DSR_TEST_EDITOR_MARKER"
printf 'editor changed configuration\n' >> "$1"
EDITOR
  chmod 700 "$EDITOR" || return 1
  before=$(cksum "$DSR_CONFIG_FILE") || return 1
  paths=$(find "$DSR_CONFIG_DIR" -print | LC_ALL=C sort) || return 1
  for variant in 1 2 3 4; do
    case "$variant" in
      1) set -- --json --dry-run config edit ;;
      2) set -- --json config edit -n ;;
      3) set -- --dry-run config edit ;;
      4) set -- config edit --dry-run ;;
    esac
    _config_mutation_cli "$@" || return 1
    [[ ! -e "$DSR_TEST_EDITOR_MARKER" && "$before" == "$(cksum "$DSR_CONFIG_FILE")" &&
       "$paths" == "$(find "$DSR_CONFIG_DIR" -print | LC_ALL=C sort)" &&
       ! -e "$DSR_CACHE_DIR" && ! -e "$DSR_STATE_DIR" ]] || return 1
    if [[ "$variant" -le 2 ]]; then
      [[ ! -s "$TEMP_DIR/mutation.stderr" ]] || return 1
      jq -es --arg editor "$EDITOR" 'length == 1 and (.[0] |
        .status == "success" and .details.action == "edit" and
        .details.dry_run == true and .details.editor_opened == false and
        .details.editor == $editor)' "$TEMP_DIR/mutation.stdout" >/dev/null || return 1
    fi
  done
)

test_config_mutations_reject_extra_arguments() {
  _init_custom_config_files || return 1
  DSR_CONFIG[threshold_seconds]=original-memory-value
  local before memory paths status variant
  before=$(cksum "$DSR_CONFIG_FILE") || return 1
  memory=$(declare -p DSR_CONFIG)
  paths=$(find "$DSR_CONFIG_DIR" -print | LC_ALL=C sort) || return 1
  status=0
  config_set threshold_seconds changed --persist --unknown-option || status=$?
  [[ "$status" == 4 && "$memory" == "$(declare -p DSR_CONFIG)" &&
     "$before" == "$(cksum "$DSR_CONFIG_FILE")" ]] || return 1
  for variant in 1 2 3 4 5; do
    case "$variant" in
      1) set -- config set threshold_seconds=900 threshold_seconds=901 ;;
      2) set -- config set threshold_seconds=900 --unknown-option ;;
      3) set -- config set missing_assignment ;;
      4) set -- config migrate --unknown-option ;;
      5) set -- config edit --unknown-option ;;
    esac
    status=0
    _config_mutation_cli --json "$@" || status=$?
    [[ "$status" == 4 && "$before" == "$(cksum "$DSR_CONFIG_FILE")" &&
       "$paths" == "$(find "$DSR_CONFIG_DIR" -print | LC_ALL=C sort)" &&
       ! -e "$DSR_CACHE_DIR" && ! -e "$DSR_STATE_DIR" ]] || return 1
    jq -es 'length == 1 and (.[0] | .exit_code == 4 and .status == "error" and
      (.details.persisted // false) == false and (.details.errors | length) > 0)' \
      "$TEMP_DIR/mutation.stdout" >/dev/null || return 1
  done
}

test_set_invalid_inputs_preserve_disk_and_memory() {
  _init_custom_config_files || return 1
  DSR_CONFIG[threshold_seconds]=original-memory-value
  local before memory status variant
  before=$(cksum "$DSR_CONFIG_FILE") || return 1
  memory=$(declare -p DSR_CONFIG)
  status=0
  config_set 'unsafe | .other_key' changed --persist || status=$?
  [[ "$status" == 4 && "$memory" == "$(declare -p DSR_CONFIG)" &&
     "$before" == "$(cksum "$DSR_CONFIG_FILE")" ]] || return 1
  for variant in malformed duplicate multiple_documents sequence; do
    case "$variant" in
      malformed) printf 'unfinished: [\n' > "$DSR_CONFIG_FILE" ;;
      duplicate) printf 'threshold_seconds: 1\nthreshold_seconds: 2\n' > "$DSR_CONFIG_FILE" ;;
      multiple_documents) printf 'threshold_seconds: 1\n---\nthreshold_seconds: 2\n' > "$DSR_CONFIG_FILE" ;;
      sequence) printf '%s\n' '- not-a-mapping' > "$DSR_CONFIG_FILE" ;;
    esac
    before=$(cksum "$DSR_CONFIG_FILE") || return 1
    status=0
    config_set threshold_seconds changed --persist || status=$?
    [[ "$status" -ne 0 && "$memory" == "$(declare -p DSR_CONFIG)" &&
       "$before" == "$(cksum "$DSR_CONFIG_FILE")" &&
       ! -e "$DSR_CONFIG_FILE.init.lock" ]] || return 1
  done
}

test_set_persist_preserves_original_metadata_and_hardlink() {
  _init_custom_config_files || return 1
  chmod 400 "$DSR_CONFIG_FILE" || return 1
  cp -p "$DSR_CONFIG_FILE" "$TEMP_DIR/original" || return 1
  ln "$DSR_CONFIG_FILE" "$TEMP_DIR/unrelated-hardlink" || return 1
  local value=$'quoted "value"\nsecond line: [literal]' backup restoration
  config_set custom_value "$value" --persist || return 1
  [[ "${DSR_CONFIG[custom_value]}" == "$value" &&
     "$(yq -r '.custom_value' "$DSR_CONFIG_FILE")" == "$value" &&
     "$(_init_file_mode "$DSR_CONFIG_FILE")" == 400 &&
     ${#_DSR_CONFIG_INIT_BACKUP_PATHS[@]} -eq 1 ]] || return 1
  backup="${_DSR_CONFIG_INIT_BACKUP_PATHS[0]}"
  cmp -s "$TEMP_DIR/original" "$backup" || return 1
  cmp -s "$TEMP_DIR/original" "$TEMP_DIR/unrelated-hardlink" || return 1
  [[ "$(_init_file_mode "$backup")" == 400 &&
     ! "$DSR_CONFIG_FILE" -ef "$TEMP_DIR/unrelated-hardlink" &&
     ! -e "$DSR_CONFIG_FILE.init.lock" ]] || return 1
  restoration=$(mktemp "$DSR_CONFIG_FILE.restore.XXXXXXXX") || return 1
  cp -p "$backup" "$restoration" && mv -f "$restoration" "$DSR_CONFIG_FILE" || return 1
  cmp -s "$TEMP_DIR/original" "$DSR_CONFIG_FILE" &&
    [[ "$(_init_file_mode "$DSR_CONFIG_FILE")" == 400 ]]
}

# Real file-size exhaustion while rendering a value larger than the limit.
# Diagnostics are collected by an unrestricted process, as in the init probe.
test_set_file_size_limit_preserves_disk_and_memory() {
  _init_custom_config_files || return 1
  DSR_CONFIG[custom_value]=original-memory-value
  local before value status memory
  local -a limited_status=()
  before=$(cksum "$DSR_CONFIG_FILE") || return 1
  memory=$(declare -p DSR_CONFIG)
  printf -v value '%4096s' ''
  value="${value// /x}"
  (
    ulimit -c 0
    ulimit -f 1
    config_set custom_value "$value" --persist
    status=$?
    [[ "$status" -ne 0 && "$memory" == "$(declare -p DSR_CONFIG)" ]]
  ) 2>&1 | command cat > "$TEMP_DIR/set-limited.stderr"
  limited_status=("${PIPESTATUS[@]}")
  [[ "${limited_status[0]}" == 0 && "${limited_status[1]}" == 0 &&
     "$before" == "$(cksum "$DSR_CONFIG_FILE")" &&
     ! -e "$DSR_CONFIG_FILE.init.lock" ]]
}

# The real rename succeeds before the injected error is returned. Memory
# must not advance when the ambiguous publication has to be rolled back.
test_set_failed_publication_rolls_back_memory_and_file() (
  _init_custom_config_files || return 1
  DSR_CONFIG[threshold_seconds]=original-memory-value
  cp -p "$DSR_CONFIG_FILE" "$TEMP_DIR/original" || return 1
  local memory status=0 fail_once=true
  memory=$(declare -p DSR_CONFIG)
  mv() {
    command mv "$@" || return $?
    if [[ "${!#}" == "$DSR_CONFIG_FILE" && "$fail_once" == true ]]; then
      fail_once=false
      return 1
    fi
  }
  config_set threshold_seconds 900 --persist || status=$?
  [[ "$status" == 1 && "$memory" == "$(declare -p DSR_CONFIG)" &&
     "${_DSR_CONFIG_INIT_ROLLED_BACK:-false}" == true &&
     "${_DSR_CONFIG_INIT_RECOVERY_REQUIRED:-true}" == false &&
     ${#_DSR_CONFIG_INIT_BACKUP_PATHS[@]} -eq 1 ]] || return 1
  cmp -s "$TEMP_DIR/original" "$DSR_CONFIG_FILE" || return 1
  cmp -s "$TEMP_DIR/original" "${_DSR_CONFIG_INIT_BACKUP_PATHS[0]}" || return 1
  [[ "$(_init_file_mode "$DSR_CONFIG_FILE")" == 640 && ! -e "$DSR_CONFIG_FILE.init.lock" ]]
)

# Cleanup fails after a real commit. The caller must receive a failure and
# retain its previous memory view while reporting that recovery is required.
test_set_cleanup_failure_keeps_memory_and_recovery_evidence() (
  _init_custom_config_files || return 1
  DSR_CONFIG[threshold_seconds]=original-memory-value
  cp -p "$DSR_CONFIG_FILE" "$TEMP_DIR/original" || return 1
  local memory status=0 fail_once=true argument
  memory=$(declare -p DSR_CONFIG)
  rm() {
    if [[ "$fail_once" == true ]]; then
      for argument in "$@"; do
        if [[ "$argument" == */expected ]]; then
          fail_once=false
          return 1
        fi
      done
    fi
    command rm "$@"
  }
  config_set threshold_seconds 900 --persist || status=$?
  [[ "$status" == 1 && "$memory" == "$(declare -p DSR_CONFIG)" &&
     "$(yq -r '.threshold_seconds' "$DSR_CONFIG_FILE")" == 900 &&
     "${_DSR_CONFIG_INIT_RECOVERY_REQUIRED:-false}" == true &&
     ${#_DSR_CONFIG_INIT_BACKUP_PATHS[@]} -eq 1 &&
     -d "$DSR_CONFIG_FILE.init.lock" ]] || return 1
  cmp -s "$TEMP_DIR/original" "${_DSR_CONFIG_INIT_BACKUP_PATHS[0]}" || return 1
  status=0
  config_set threshold_seconds 901 --persist || status=$?
  [[ "$status" == 2 && "$memory" == "$(declare -p DSR_CONFIG)" ]]
)

test_set_refuses_unsafe_destinations_without_memory_changes() {
  local kind before memory status
  DSR_CONFIG[threshold_seconds]=original-memory-value
  memory=$(declare -p DSR_CONFIG)
  printf 'threshold_seconds: 600\n' > "$TEMP_DIR/protected-referent" || return 1
  before=$(cksum "$TEMP_DIR/protected-referent") || return 1
  for kind in symlink dangling fifo directory; do
    DSR_CONFIG_FILE="$TEMP_DIR/$kind"
    case "$kind" in
      symlink) ln -s "$TEMP_DIR/protected-referent" "$DSR_CONFIG_FILE" || return 1 ;;
      dangling) ln -s "$TEMP_DIR/missing-referent" "$DSR_CONFIG_FILE" || return 1 ;;
      fifo) mkfifo "$DSR_CONFIG_FILE" || return 1 ;;
      directory) mkdir "$DSR_CONFIG_FILE" || return 1 ;;
    esac
    status=0
    config_set threshold_seconds 900 --persist || status=$?
    [[ "$status" == 4 && "$memory" == "$(declare -p DSR_CONFIG)" &&
       "$before" == "$(cksum "$TEMP_DIR/protected-referent")" &&
       ! -e "$TEMP_DIR/missing-referent" && ! -e "$DSR_CONFIG_FILE.init.lock" ]] || return 1
  done
}

test_cli_mutation_log_aliases_preserve_original_backups() {
  local action alias_kind log_path backup
  for action in set migrate; do
    for alias_kind in direct hardlink; do
      DSR_CONFIG_DIR="$TEMP_DIR/$action-$alias_kind"
      DSR_CONFIG_FILE="$DSR_CONFIG_DIR/config.yaml"
      DSR_HOSTS_FILE="$DSR_CONFIG_DIR/hosts.yaml"
      DSR_REPOS_FILE="$DSR_CONFIG_DIR/repos.yaml"
      mkdir -p "$DSR_CONFIG_DIR" || return 1
      printf 'threshold_seconds: 600\nretained: original\n' > "$DSR_CONFIG_FILE" || return 1
      cp -p "$DSR_CONFIG_FILE" "$TEMP_DIR/original-$action-$alias_kind" || return 1
      log_path="$DSR_CONFIG_FILE"
      if [[ "$alias_kind" == hardlink ]]; then
        log_path="$DSR_CONFIG_DIR/log-hardlink"
        ln "$DSR_CONFIG_FILE" "$log_path" || return 1
      fi
      if [[ "$action" == set ]]; then
        DSR_TEST_CONFIG_LOG_FILE="$log_path" _config_mutation_cli --json config set threshold_seconds=900 || return 1
        [[ "$(yq -r '.threshold_seconds' "$DSR_CONFIG_FILE")" == 900 ]] || return 1
      else
        DSR_TEST_CONFIG_LOG_FILE="$log_path" _config_mutation_cli --json config migrate || return 1
        [[ "$(yq -r '.schema_version' "$DSR_CONFIG_FILE")" == "$DSR_SCHEMA_VERSION" ]] || return 1
      fi
      [[ ! -s "$TEMP_DIR/mutation.stderr" && ! -e "$DSR_STATE_DIR" ]] || return 1
      jq -es --arg action "$action" 'length == 1 and (.[0] |
        .status == "success" and .exit_code == 0 and .details.action == $action and
        .details.dry_run == false and .details.persisted == true and
        (.details.backup_paths | length) == 1)' "$TEMP_DIR/mutation.stdout" >/dev/null || return 1
      backup=$(jq -r '.details.backup_paths[0]' "$TEMP_DIR/mutation.stdout") || return 1
      cmp -s "$TEMP_DIR/original-$action-$alias_kind" "$backup" || return 1
      if [[ "$alias_kind" == hardlink ]]; then
        cmp -s "$TEMP_DIR/original-$action-$alias_kind" "$log_path" || return 1
      fi
    done
  done
}

test_cli_migrate_dry_run_preserves_files() {
  mkdir -p "$DSR_CONFIG_DIR" || return 1
  local form variant before paths
  for form in missing null empty; do
    case "$form" in
      missing) printf 'threshold_seconds: 600\n' > "$DSR_CONFIG_FILE" ;;
      null) printf 'schema_version: null\nthreshold_seconds: 600\n' > "$DSR_CONFIG_FILE" ;;
      empty) printf 'schema_version: ""\nthreshold_seconds: 600\n' > "$DSR_CONFIG_FILE" ;;
    esac
    before=$(cksum "$DSR_CONFIG_FILE") || return 1
    paths=$(find "$DSR_CONFIG_DIR" -print | LC_ALL=C sort) || return 1
    for variant in 1 2 3; do
      case "$variant" in
        1) set -- --json --dry-run config migrate ;;
        2) set -- --json config migrate --dry-run ;;
        3) set -- config migrate -n ;;
      esac
      _config_mutation_cli "$@" || return 1
      [[ "$before" == "$(cksum "$DSR_CONFIG_FILE")" &&
         "$paths" == "$(find "$DSR_CONFIG_DIR" -print | LC_ALL=C sort)" &&
         ! -e "$DSR_STATE_DIR" && ! -e "$DSR_CACHE_DIR" ]] || return 1
      if [[ "$variant" -le 2 ]]; then
        [[ ! -s "$TEMP_DIR/mutation.stderr" ]] || return 1
        jq -es 'length == 1 and (.[0] | .status == "success" and .details.action == "migrate" and
          .details.dry_run == true and .details.persisted == false and
          .details.backup_paths == [] and .details.changed_keys == ["schema_version"])' \
          "$TEMP_DIR/mutation.stdout" >/dev/null || return 1
      fi
    done
  done
}

test_cli_migrate_rejects_invalid_schema_without_changes() {
  mkdir -p "$DSR_CONFIG_DIR" || return 1
  local form before paths status
  for form in false number object sequence unknown duplicate multiple_documents malformed; do
    case "$form" in
      false) printf 'schema_version: false\n' > "$DSR_CONFIG_FILE" ;;
      number) printf 'schema_version: 1\n' > "$DSR_CONFIG_FILE" ;;
      object) printf 'schema_version: {version: "1.0.0"}\n' > "$DSR_CONFIG_FILE" ;;
      sequence) printf 'schema_version: ["1.0.0"]\n' > "$DSR_CONFIG_FILE" ;;
      unknown) printf 'schema_version: "99.0.0"\n' > "$DSR_CONFIG_FILE" ;;
      duplicate) printf 'schema_version: null\nschema_version: "1.0.0"\n' > "$DSR_CONFIG_FILE" ;;
      multiple_documents) printf 'threshold_seconds: 1\n---\nthreshold_seconds: 2\n' > "$DSR_CONFIG_FILE" ;;
      malformed) printf 'threshold_seconds: [\n' > "$DSR_CONFIG_FILE" ;;
    esac
    before=$(cksum "$DSR_CONFIG_FILE") || return 1
    paths=$(find "$DSR_CONFIG_DIR" -print | LC_ALL=C sort) || return 1
    status=0
    _config_mutation_cli --json config migrate || status=$?
    [[ "$status" == 4 && "$before" == "$(cksum "$DSR_CONFIG_FILE")" &&
       "$paths" == "$(find "$DSR_CONFIG_DIR" -print | LC_ALL=C sort)" &&
       ! -e "$DSR_STATE_DIR" ]] || return 1
    jq -es 'length == 1 and (.[0] | .status == "error" and .exit_code == 4 and
      .details.persisted == false and .details.backup_paths == [] and
      (.details.errors | length) > 0)' "$TEMP_DIR/mutation.stdout" >/dev/null || return 1
  done
}

# Keep the clock fixed to exercise repeated migration in one timestamp. Only
# the timestamp is controlled; real exclusive links must preserve every backup.
test_cli_migrate_preserves_colliding_backup_generations() (
  mkdir -p "$DSR_CONFIG_DIR" || return 1
  printf 'threshold_seconds: 600\nretained: original\n' > "$DSR_CONFIG_FILE" || return 1
  chmod 400 "$DSR_CONFIG_FILE" || return 1
  cp -p "$DSR_CONFIG_FILE" "$TEMP_DIR/original" || return 1
  local sentinel="$DSR_CONFIG_FILE.bak.20260101T000000Z" backup first_backup='' round restoration before
  printf 'an existing backup from another operation\n' > "$sentinel" || return 1
  before=$(cksum "$sentinel") || return 1
  date() {
    if [[ "$#" == 2 && "$1" == -u && "$2" == +%Y%m%dT%H%M%SZ ]]; then
      printf '20260101T000000Z\n'
    else
      command date "$@"
    fi
  }
  export -f date
  for round in 1 2; do
    _config_mutation_cli --json config migrate || return 1
    jq -es 'length == 1 and (.[0] | .status == "success" and .details.persisted == true and
      .details.changed_keys == ["schema_version"] and (.details.backup_paths | length) == 1 and
      .details.backup_path == .details.backup_paths[0])' "$TEMP_DIR/mutation.stdout" >/dev/null || return 1
    backup=$(jq -r '.details.backup_paths[0]' "$TEMP_DIR/mutation.stdout") || return 1
    [[ "$backup" != "$sentinel" && "$backup" != "$first_backup" &&
       "$before" == "$(cksum "$sentinel")" &&
       "$(_init_file_mode "$backup")" == 400 && "$(_init_file_mode "$DSR_CONFIG_FILE")" == 400 ]] || return 1
    cmp -s "$TEMP_DIR/original" "$backup" || return 1
    [[ "$(yq -r '.schema_version' "$DSR_CONFIG_FILE")" == "$DSR_SCHEMA_VERSION" ]] || return 1
    [[ "$round" == 1 ]] || cmp -s "$TEMP_DIR/original" "$first_backup" || return 1
    first_backup="$backup"
    # Restore each captured generation for real, including its original mode.
    restoration=$(mktemp "$DSR_CONFIG_FILE.restore.XXXXXXXX") || return 1
    cp -p "$backup" "$restoration" && mv -f "$restoration" "$DSR_CONFIG_FILE" || return 1
    cmp -s "$TEMP_DIR/original" "$DSR_CONFIG_FILE" || return 1
  done
)

test_cli_migrate_current_schema_is_read_only() {
  _init_custom_config_files || return 1
  local before paths
  before=$(cksum "$DSR_CONFIG_FILE") || return 1
  paths=$(find "$DSR_CONFIG_DIR" -print | LC_ALL=C sort) || return 1
  _config_mutation_cli --json config migrate || return 1
  [[ ! -s "$TEMP_DIR/mutation.stderr" && "$before" == "$(cksum "$DSR_CONFIG_FILE")" &&
     "$paths" == "$(find "$DSR_CONFIG_DIR" -print | LC_ALL=C sort)" &&
     ! -e "$DSR_STATE_DIR" ]] || return 1
  jq -es 'length == 1 and (.[0] | .status == "success" and .details.persisted == false and
    .details.dry_run == false and .details.changed_keys == [] and .details.backup_paths == [])' \
    "$TEMP_DIR/mutation.stdout" >/dev/null
}

# As with set, inject only the return status after a real successful rename.
test_cli_migrate_publication_failure_restores_original() (
  mkdir -p "$DSR_CONFIG_DIR" || return 1
  printf 'threshold_seconds: 600\n' > "$DSR_CONFIG_FILE" || return 1
  cp -p "$DSR_CONFIG_FILE" "$TEMP_DIR/original" || return 1
  local status=0 backup
  mv() {
    command mv "$@" || return $?
    if [[ "${!#}" == "$DSR_CONFIG_FILE" && "${DSR_TEST_MIGRATE_FAILED:-false}" == false ]]; then
      DSR_TEST_MIGRATE_FAILED=true
      return 1
    fi
  }
  export -f mv
  _config_mutation_cli --json config migrate || status=$?
  [[ "$status" == 1 && ! -e "$DSR_CONFIG_FILE.init.lock" ]] || return 1
  cmp -s "$TEMP_DIR/original" "$DSR_CONFIG_FILE" || return 1
  jq -es 'length == 1 and (.[0] | .status == "error" and .details.persisted == false and
    .details.rolled_back == true and .details.recovery_required == false and
    (.details.backup_paths | length) == 1 and (.details.errors | length) > 0)' \
    "$TEMP_DIR/mutation.stdout" >/dev/null || return 1
  backup=$(jq -r '.details.backup_paths[0]' "$TEMP_DIR/mutation.stdout") || return 1
  cmp -s "$TEMP_DIR/original" "$backup"
)

# Explicit scheduling boundary after real lock acquisition: another writer
# changes the schema before the backup is copied. Admission must be repeated
# against that locked original, not solely the earlier preview of the file.
test_cli_migrate_rechecks_schema_after_lock_acquisition() (
  mkdir -p "$DSR_CONFIG_DIR" || return 1
  printf 'threshold_seconds: 600\n' > "$DSR_CONFIG_FILE" || return 1
  printf 'schema_version: "9.0.0"\nthreshold_seconds: 901\n' > "$TEMP_DIR/external-edit" || return 1
  local status=0 backup
  mkdir() {
    command mkdir "$@" || return $?
    if [[ "${!#}" == "$DSR_CONFIG_FILE.init.lock" ]]; then
      printf 'schema_version: "9.0.0"\nthreshold_seconds: 901\n' > "$DSR_CONFIG_FILE"
    fi
  }
  export -f mkdir
  _config_mutation_cli --json config migrate || status=$?
  [[ "$status" == 4 && ! -e "$DSR_CONFIG_FILE.init.lock" ]] || return 1
  cmp -s "$TEMP_DIR/external-edit" "$DSR_CONFIG_FILE" || return 1
  jq -es 'length == 1 and (.[0] | .status == "error" and .details.persisted == false and
    .details.rolled_back == false and .details.recovery_required == false and
    (.details.backup_paths | length) == 1 and (.details.errors | length) > 0)' \
    "$TEMP_DIR/mutation.stdout" >/dev/null || return 1
  backup=$(jq -r '.details.backup_paths[0]' "$TEMP_DIR/mutation.stdout") || return 1
  cmp -s "$TEMP_DIR/external-edit" "$backup"
)

# Timing is controlled with a FIFO after a real publication; termination uses
# a genuine OS signal. A setter and initializer must honor the same leaf lock.
test_set_killed_publication_blocks_other_writers() (
  _init_custom_config_files || return 1
  cp -p "$DSR_CONFIG_FILE" "$TEMP_DIR/original" || return 1
  local child_pid='' attempt status=0 before backup restoration
  local -a matches=()
  mkfifo "$TEMP_DIR/set-publication-barrier" || return 1
  trap 'if [[ -n "$child_pid" ]] && kill -0 "$child_pid" 2>/dev/null; then kill -KILL "$child_pid" 2>/dev/null; wait "$child_pid" 2>/dev/null || true; fi' EXIT
  (
    mv() {
      command mv "$@" || return $?
      if [[ "${!#}" == "$DSR_CONFIG_FILE" ]]; then
        printf 'published\n' > "$TEMP_DIR/set-publication-ready" || return 1
        local barrier_release
        IFS= read -r barrier_release < "$TEMP_DIR/set-publication-barrier" || return 1
        [[ "$barrier_release" == continue ]]
      fi
    }
    config_set threshold_seconds 900 --persist
  ) > "$TEMP_DIR/killed-set.stdout" 2> "$TEMP_DIR/killed-set.stderr" &
  child_pid=$!
  for ((attempt = 0; attempt < 100; attempt++)); do
    [[ ! -f "$TEMP_DIR/set-publication-ready" ]] || break
    kill -0 "$child_pid" 2>/dev/null || return 1
    sleep 0.05
  done
  [[ -f "$TEMP_DIR/set-publication-ready" ]] || return 1
  before=$(cksum "$DSR_CONFIG_FILE" "$DSR_HOSTS_FILE" "$DSR_REPOS_FILE") || return 1
  config_init --force || status=$?
  [[ "$status" == 2 && "$before" == "$(cksum "$DSR_CONFIG_FILE" "$DSR_HOSTS_FILE" "$DSR_REPOS_FILE")" ]] || return 1
  kill -KILL "$child_pid" || return 1
  status=0
  wait "$child_pid" || status=$?
  child_pid=''
  [[ "$status" == 137 && "$(yq -r '.threshold_seconds' "$DSR_CONFIG_FILE")" == 900 ]] || return 1
  status=0
  config_set threshold_seconds 901 --persist || status=$?
  [[ "$status" == 2 && "$before" == "$(cksum "$DSR_CONFIG_FILE" "$DSR_HOSTS_FILE" "$DSR_REPOS_FILE")" ]] || return 1
  matches=("$DSR_CONFIG_FILE".bak.*)
  [[ ${#matches[@]} -eq 1 && -d "$DSR_CONFIG_FILE.init.lock" ]] || return 1
  backup="${matches[0]}"
  cmp -s "$TEMP_DIR/original" "$backup" || return 1
  [[ "$(cat "$DSR_CONFIG_FILE.init.lock"/stage.*/backup-path)" == "$backup" ]] || return 1
  restoration=$(mktemp "$DSR_CONFIG_FILE.restore.XXXXXXXX") || return 1
  cp -p "$backup" "$restoration" && mv -f "$restoration" "$DSR_CONFIG_FILE" || return 1
  mv "$DSR_CONFIG_FILE.init.lock" "$DSR_CONFIG_FILE.interrupted" || return 1
  cmp -s "$TEMP_DIR/original" "$DSR_CONFIG_FILE" || return 1
  config_set threshold_seconds 902 --persist || return 1
  cmp -s "$TEMP_DIR/original" "$backup"
)

# ============================================================================
# Tests: Validation (config_validate)
# ============================================================================

test_validate_passes_with_init() {
  config_init
  config_load
  config_validate
}

test_validate_fails_missing_dir() {
  # Don't init, dir doesn't exist
  ! config_validate
}

test_validate_checks_schema_version() {
  mkdir -p "$DSR_CONFIG_DIR" || return 1
  printf 'schema_version: "1.0.0"\n' > "$DSR_CONFIG_FILE" || return 1
  config_load || return 1
  local kind status before
  # A previously valid memory snapshot must not certify changed disk contents.
  for kind in missing_file empty_file absent null empty unknown false number sequence object; do
    case "$kind" in
      missing_file) mv "$DSR_CONFIG_FILE" "$TEMP_DIR/retained-valid-config" || return 1 ;;
      empty_file) : > "$DSR_CONFIG_FILE" ;;
      absent) printf 'threshold_seconds: 300\n' > "$DSR_CONFIG_FILE" ;;
      null) printf 'schema_version: null\n' > "$DSR_CONFIG_FILE" ;;
      empty) printf 'schema_version: ""\n' > "$DSR_CONFIG_FILE" ;;
      unknown) printf 'schema_version: "99.0.0"\n' > "$DSR_CONFIG_FILE" ;;
      false) printf 'schema_version: false\n' > "$DSR_CONFIG_FILE" ;;
      number) printf 'schema_version: 1\n' > "$DSR_CONFIG_FILE" ;;
      sequence) printf 'schema_version: ["1.0.0"]\n' > "$DSR_CONFIG_FILE" ;;
      object) printf 'schema_version: {version: "1.0.0"}\n' > "$DSR_CONFIG_FILE" ;;
    esac
    status=0
    config_validate || status=$?
    [[ "$status" == 4 ]] || return 1
  done
  printf 'schema_version: "1.0.0"\n' > "$DSR_CONFIG_FILE" || return 1
  DSR_CONFIG[schema_version]=stale-invalid-version
  config_validate || return 1
  # Loading legacy data remains possible, but explicit validation must report
  # its physically missing schema instead of validating the loaded default.
  printf 'threshold_seconds: 300\n' > "$DSR_CONFIG_FILE" || return 1
  before=$(cksum "$DSR_CONFIG_FILE") || return 1
  status=0
  _config_mutation_cli --json config validate || status=$?
  [[ "$status" == 4 && "$before" == "$(cksum "$DSR_CONFIG_FILE")" &&
     ! -e "$DSR_CACHE_DIR" && ! -e "$DSR_STATE_DIR" ]] || return 1
  jq -es 'length == 1 and (.[0] | .status == "error" and .exit_code == 4 and
    .details.action == "validate" and .details.valid == false and
    (.details.errors | length) > 0)' "$TEMP_DIR/mutation.stdout" >/dev/null
}

test_validate_rejects_unrepresentable_values() {
  mkdir -p "$DSR_CONFIG_DIR" || return 1
  DSR_CONFIG[schema_version]="$DSR_SCHEMA_VERSION"
  local kind status before
  for kind in nul_value nul_key flattened_collision; do
    case "$kind" in
      nul_value) printf '%s\n' 'schema_version: "1.0.0"' 'value: "before\u0000after"' > "$DSR_CONFIG_FILE" ;;
      nul_key) printf '%s\n' 'schema_version: "1.0.0"' '"before\u0000after": value' > "$DSR_CONFIG_FILE" ;;
      flattened_collision) printf 'schema_version: "1.0.0"\n"signing.enabled": false\nsigning:\n  enabled: true\n' > "$DSR_CONFIG_FILE" ;;
    esac
    before=$(cksum "$DSR_CONFIG_FILE") || return 1
    status=0
    config_validate || status=$?
    [[ "$status" == 4 && "$before" == "$(cksum "$DSR_CONFIG_FILE")" ]] || return 1
  done
}

# ============================================================================
# Tests: Show (config_show)
# ============================================================================

test_show_human_output() {
  config_init
  config_load
  local output
  output=$(config_show)
  [[ "$output" == *"dsr Configuration"* ]] && \
  [[ "$output" == *"Directories"* ]] && \
  [[ "$output" == *"Values"* ]]
}

test_show_json_output() {
  config_init
  config_load
  local output
  output=$(config_show --json)
  [[ "$output" == "{"* ]] && \
  [[ "$output" == *"config_dir"* ]] && \
  [[ "$output" == *"values"* ]]
}

test_show_specific_key() {
  config_init
  config_load
  local output
  output=$(config_show threshold_seconds)
  [[ "$output" == *"threshold_seconds"* ]] && \
  [[ "$output" == *"600"* ]]
}

test_show_json_specific_key() {
  config_init
  config_load
  local output
  output=$(config_show --json threshold_seconds)
  [[ "$output" == *"threshold_seconds"* ]]
}

# ============================================================================
# Tests: XDG Compliance
# ============================================================================

test_xdg_config_home_override() {
  local custom_config="$TEMP_DIR/custom_config"
  mkdir -p "$custom_config"
  export XDG_CONFIG_HOME="$custom_config"

  # Re-initialize paths
  DSR_CONFIG_DIR="$XDG_CONFIG_HOME/dsr"
  DSR_CONFIG_FILE="$DSR_CONFIG_DIR/config.yaml"

  config_init
  [[ -d "$custom_config/dsr" ]]
}

test_xdg_cache_home_override() {
  local custom_cache="$TEMP_DIR/custom_cache"
  mkdir -p "$custom_cache"
  export XDG_CACHE_HOME="$custom_cache"

  # Re-initialize paths
  DSR_CACHE_DIR="$XDG_CACHE_HOME/dsr"

  config_init
  [[ -d "$custom_cache/dsr" ]]
}

test_xdg_state_home_override() {
  local custom_state="$TEMP_DIR/custom_state"
  mkdir -p "$custom_state"
  export XDG_STATE_HOME="$custom_state"

  # Re-initialize paths
  DSR_STATE_DIR="$XDG_STATE_HOME/dsr"

  config_init
  [[ -d "$custom_state/dsr" ]]
}

# ============================================================================
# Tests: Host/Tool Configuration
# ============================================================================

test_get_host_for_platform_linux() {
  config_init
  local host
  host=$(config_get_host_for_platform "linux/amd64")
  [[ "$host" == "trj" || "$host" == "\"trj\"" ]]
}

test_get_host_for_platform_darwin() {
  config_init
  local host
  host=$(config_get_host_for_platform "darwin/arm64")
  [[ "$host" == "mmini" || "$host" == "\"mmini\"" ]]
}

test_get_host_for_platform_windows() {
  config_init
  local amd64_host arm64_host
  amd64_host=$(config_get_host_for_platform "windows/amd64")
  arm64_host=$(config_get_host_for_platform "windows/arm64")
  [[ "$amd64_host" == "wlap" || "$amd64_host" == "\"wlap\"" ]] &&
    [[ "$arm64_host" == "wlap" || "$arm64_host" == "\"wlap\"" ]]
}

test_list_hosts_returns_hosts() {
  config_init
  # Skip if yq not available
  command -v yq &>/dev/null || return 0
  local output
  output=$(config_list_hosts)
  [[ "$output" == *"trj"* ]] && \
  [[ "$output" == *"mmini"* ]] && \
  [[ "$output" == *"wlap"* ]]
}

test_get_host_returns_config() {
  config_init
  # Skip if yq not available
  command -v yq &>/dev/null || return 0
  local output
  output=$(config_get_host "trj")
  [[ "$output" == *"linux/amd64"* ]] || [[ "$output" == *"local"* ]]
}

# ============================================================================
# Tests: Release Contract
# ============================================================================

test_release_contract_absent_is_legacy_compatible() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets:
  - linux/amd64
YAML

  [[ "$(config_get_release_contract_json contract-tool)" == "null" ]] &&
    config_validate_release_contract contract-tool
}

test_release_contract_null_is_legacy_compatible() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets:
  - linux/amd64
release_contract: null
YAML

  [[ "$(config_get_release_contract_json contract-tool)" == "null" ]] &&
    config_validate_release_contract contract-tool
}

test_release_contract_rejects_non_object() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets:
  - linux/amd64
release_contract: sha256
YAML

  ! config_get_release_contract_json contract-tool >/dev/null &&
    ! config_validate_release_contract contract-tool
}

test_release_contract_valid_is_canonical_json() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets:
  - linux/amd64
  - darwin/arm64
release_contract:
  exact_primary_assets:
    linux/amd64: contract-tool-x86_64-unknown-linux-gnu
    darwin/arm64: contract-tool-aarch64-apple-darwin
  exact_additional_assets:
    - contract-tool.sbom.spdx.json
    - SHA256SUMS.txt.minisig
  checksum_sidecar: sha256
YAML

  local expected
  expected='{"checksum_sidecar":"sha256","exact_additional_assets":["contract-tool.sbom.spdx.json","SHA256SUMS.txt.minisig"],"exact_primary_assets":{"darwin/arm64":"contract-tool-aarch64-apple-darwin","linux/amd64":"contract-tool-x86_64-unknown-linux-gnu"}}'
  [[ "$(config_get_release_contract_json contract-tool)" == "$expected" ]] &&
    config_validate_release_contract contract-tool
}

test_release_contract_accepts_pinned_minisign_key_file() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets:
  - linux/amd64
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: contract-tool-linux-amd64
  minisign_public_key_file: release/keys/contract-tool.pub
YAML

  local expected
  expected='{"checksum_sidecar":"sha256","exact_primary_assets":{"linux/amd64":"contract-tool-linux-amd64"},"minisign_public_key_file":"release/keys/contract-tool.pub"}'
  [[ "$(config_get_release_contract_json contract-tool)" == "$expected" ]] &&
    config_validate_release_contract contract-tool
}

test_release_contract_accepts_pinned_github_tag_ruleset() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets:
  - linux/amd64
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: contract-tool-linux-amd64
  github_tag_ruleset:
    repository_id: 1148330949
    ruleset_id: 20418963
YAML

  local expected
  expected='{"checksum_sidecar":"sha256","exact_primary_assets":{"linux/amd64":"contract-tool-linux-amd64"},"github_tag_ruleset":{"repository_id":1148330949,"ruleset_id":20418963}}'
  [[ "$(config_get_release_contract_json contract-tool)" == "$expected" ]] &&
    config_validate_release_contract contract-tool
}

test_release_contract_accepts_build_manifest_assets() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: eidetic_engine_cli
targets: [linux/amd64]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets: {linux/amd64: ee-x86_64-unknown-linux-gnu.tar.xz}
  build_manifest_assets: [ee-v0.17.0-manifest.json, eidetic_engine_cli-v0.17.0-manifest.json]
YAML
  # The fixture file is named contract-tool.yaml; its tool_name is unused here.
  config_validate_release_contract contract-tool
}

test_release_contract_rejects_invalid_build_manifest_assets() {
  release_contract_test_deps_available || return 0
  local names
  for names in '[]' '[a.json, b.json, c.json]' '[../ee-manifest.json]' '[ee-manifest.txt]' \
      '[ee-manifest.json.sha256]' '[EE-X86_64-UNKNOWN-LINUX-GNU.TAR.XZ.json, ee-x86_64-unknown-linux-gnu.tar.xz.json]' \
      '[ee-manifest.json, EE-MANIFEST.JSON]' '[ee-x86_64-unknown-linux-gnu.tar.xz]' '"ee-manifest.json"'; do
    write_contract_tool_config << YAML
tool_name: contract-tool
targets: [linux/amd64]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets: {linux/amd64: ee-x86_64-unknown-linux-gnu.tar.xz}
  exact_additional_assets: [ee-x86_64-unknown-linux-gnu.tar.xz.json]
  build_manifest_assets: $names
YAML
    if config_validate_release_contract contract-tool 2>/dev/null; then
      echo "accepted invalid build_manifest_assets: $names" >&2
      return 1
    fi
  done
}

test_release_contract_rejects_invalid_github_tag_ruleset() {
  release_contract_test_deps_available || return 0

  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets: {linux/amd64: contract-tool-linux-amd64}
  github_tag_ruleset: {ruleset_id: 20418963}
YAML
  ! config_validate_release_contract contract-tool || return 1

  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets: {linux/amd64: contract-tool-linux-amd64}
  github_tag_ruleset: {repository_id: "1148330949", ruleset_id: 20418963}
YAML
  ! config_validate_release_contract contract-tool || return 1

  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets: {linux/amd64: contract-tool-linux-amd64}
  github_tag_ruleset: {repository_id: 1148330949, ruleset_id: 0}
YAML
  ! config_validate_release_contract contract-tool || return 1

  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets: {linux/amd64: contract-tool-linux-amd64}
  github_tag_ruleset:
    repository_id: 1148330949
    ruleset_id: 20418963
    ref_include: refs/tags/v*
YAML
  ! config_validate_release_contract contract-tool
}

test_release_contract_rejects_unsafe_minisign_key_paths() {
  release_contract_test_deps_available || return 0
  local unsafe_path
  for unsafe_path in "/release.pub" "../release.pub" "release//key.pub" 'release\key.pub'; do
    write_contract_tool_config << YAML
tool_name: contract-tool
targets: [linux/amd64]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: contract-tool-linux-amd64
  minisign_public_key_file: $unsafe_path
YAML
    ! config_validate_release_contract contract-tool || return 1
  done
}

test_release_contract_rejects_minisign_asset_collisions() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: contract-tool
  minisign_public_key_file: release.pub
  exact_additional_assets: [CONTRACT-TOOL.MINISIG]
YAML
  ! config_validate_release_contract contract-tool || return 1

  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: contract-tool.minisig
  minisign_public_key_file: release.pub
YAML
  ! config_validate_release_contract contract-tool
}

test_release_contract_registry_fallback() {
  release_contract_test_deps_available || return 0
  mkdir -p "$DSR_CONFIG_DIR"
  cat > "$DSR_REPOS_FILE" << 'YAML'
tools:
  contract-tool:
    targets:
      - linux/amd64
    release_contract:
      checksum_sidecar: sha256
      exact_primary_assets:
        linux/amd64: contract-tool-x86_64-unknown-linux-gnu
YAML

  [[ "$(config_get_release_contract_json contract-tool)" != "null" ]] &&
    config_validate_release_contract contract-tool
}

test_release_source_dependencies_absent_or_null_are_empty() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
YAML
  [[ "$(config_get_release_source_dependencies_json contract-tool)" == "[]" ]] || return 1

  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
sibling_crates: null
YAML
  [[ "$(config_get_release_source_dependencies_json contract-tool)" == "[]" ]]
}

test_release_source_dependencies_are_canonical_and_sorted() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
sibling_crates:
  - local_path: /src/zeta
    relative_path: zeta
    revision: "ffffffffffffffffffffffffffffffffffffffff"
    respect_gitignore: true
  - local_path: /src/alpha
    relative_path: alpha-core
    revision: "1111111111111111111111111111111111111111"
YAML

  local expected
  expected='[{"git_sha":"1111111111111111111111111111111111111111","relative_path":"alpha-core"},{"git_sha":"ffffffffffffffffffffffffffffffffffffffff","relative_path":"zeta"}]'
  [[ "$(config_get_release_source_dependencies_json contract-tool)" == "$expected" ]] || return 1

  expected='[{"git_sha":"1111111111111111111111111111111111111111","local_path":"/src/alpha","relative_path":"alpha-core"},{"git_sha":"ffffffffffffffffffffffffffffffffffffffff","local_path":"/src/zeta","relative_path":"zeta"}]'
  [[ "$(_config_get_release_source_dependency_checkouts_json contract-tool)" == "$expected" ]]
}

test_release_source_dependencies_registry_fallback_and_repo_precedence() {
  release_contract_test_deps_available || return 0
  mkdir -p "$DSR_CONFIG_DIR"
  cat > "$DSR_REPOS_FILE" << 'YAML'
tools:
  contract-tool:
    targets: [linux/amd64]
    sibling_crates:
      - local_path: /src/registry
        relative_path: registry
        revision: "3333333333333333333333333333333333333333"
YAML

  local expected
  expected='[{"git_sha":"3333333333333333333333333333333333333333","relative_path":"registry"}]'
  [[ "$(config_get_release_source_dependencies_json contract-tool)" == "$expected" ]] || return 1

  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
sibling_crates: null
YAML
  [[ "$(config_get_release_source_dependencies_json contract-tool)" == "[]" ]]
}

test_release_source_dependencies_reject_missing_revision() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
sibling_crates:
  - local_path: /src/alpha
    relative_path: alpha
YAML

  ! config_get_release_source_dependencies_json contract-tool >/dev/null
}

test_release_source_dependencies_require_absolute_nonroot_local_path() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
sibling_crates:
  - local_path: relative/alpha
    relative_path: alpha
    revision: "1111111111111111111111111111111111111111"
YAML
  ! config_get_release_source_dependencies_json contract-tool >/dev/null || return 1

  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
sibling_crates:
  - local_path: /
    relative_path: alpha
    revision: "1111111111111111111111111111111111111111"
YAML
  ! config_get_release_source_dependencies_json contract-tool >/dev/null
}

test_release_source_dependencies_reject_unsafe_or_duplicate_paths() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
sibling_crates:
  - local_path: /src/alpha
    relative_path: ../alpha
    revision: "1111111111111111111111111111111111111111"
YAML
  ! config_get_release_source_dependencies_json contract-tool >/dev/null || return 1

  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
sibling_crates:
  - local_path: /src/alpha
    relative_path: shared
    revision: "1111111111111111111111111111111111111111"
  - local_path: /src/beta
    relative_path: shared
    revision: "2222222222222222222222222222222222222222"
YAML
  ! config_get_release_source_dependencies_json contract-tool >/dev/null
}

test_release_source_dependencies_reject_nonportable_path_aliases() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
sibling_crates:
  - local_path: /src/alpha-upper
    relative_path: Alpha
    revision: "1111111111111111111111111111111111111111"
  - local_path: /src/alpha-lower
    relative_path: alpha
    revision: "2222222222222222222222222222222222222222"
YAML
  ! config_get_release_source_dependencies_json contract-tool >/dev/null || return 1

  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
sibling_crates:
  - local_path: /src/trailing-dot
    relative_path: alias.
    revision: "1111111111111111111111111111111111111111"
YAML
  ! config_get_release_source_dependencies_json contract-tool >/dev/null || return 1

  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
sibling_crates:
  - local_path: /src/device
    relative_path: CON.txt
    revision: "1111111111111111111111111111111111111111"
YAML
  ! config_get_release_source_dependencies_json contract-tool >/dev/null
}

test_config_validate_rejects_invalid_strict_release_dependency() {
  release_contract_test_deps_available || return 0
  config_init
  config_load
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
sibling_crates:
  - local_path: /src/alpha
    relative_path: alpha
    revision: ABCDEF1111111111111111111111111111111111
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: contract-tool-linux-amd64
YAML

  ! config_validate
}

test_release_contract_registry_false_is_rejected() {
  mkdir -p "$DSR_CONFIG_DIR"
  cat > "$DSR_REPOS_FILE" << 'YAML'
tools:
  contract-tool:
    targets: [linux/amd64]
    release_contract: false
YAML

  ! config_get_release_contract_json contract-tool >/dev/null &&
    ! config_validate_release_contract contract-tool
}

test_release_contract_rejects_multiple_yaml_documents() {
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
---
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: contract-tool-linux-amd64
YAML

  ! config_get_release_contract_json contract-tool >/dev/null &&
    ! config_validate_release_contract contract-tool
}

test_release_contract_rejects_non_mapping_yaml_roots() {
  write_contract_tool_config << 'YAML'
contract-tool
YAML
  ! config_get_release_contract_json contract-tool >/dev/null || return 1

  write_contract_tool_config << 'YAML'
- contract-tool
- linux/amd64
YAML
  ! config_get_release_contract_json contract-tool >/dev/null
}

test_release_contract_rejects_duplicate_yaml_keys() {
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
release_contract: null
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: contract-tool-linux-amd64
YAML
  ! config_get_release_contract_json contract-tool >/dev/null || return 1

  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
release_contract:
  checksum_sidecar: sha256
  checksum_sidecar: sha512
  exact_primary_assets:
    linux/amd64: contract-tool-linux-amd64
YAML
  ! config_get_release_contract_json contract-tool >/dev/null
}

test_config_validate_rejects_invalid_repo_release_contract() {
  config_init
  config_load
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
release_contract: false
YAML

  ! config_validate
}

test_config_validate_rejects_invalid_registry_release_contract() {
  config_init
  config_load
  cat > "$DSR_REPOS_FILE" << 'YAML'
tools:
  contract-tool:
    targets: [linux/amd64]
    release_contract: false
YAML

  ! config_validate
}

test_config_validate_rejects_non_mapping_registry_tools() {
  config_init
  config_load
  cat > "$DSR_REPOS_FILE" << 'YAML'
tools: []
YAML

  ! config_validate
}

test_release_contract_rejects_non_mapping_registry_tool() {
  mkdir -p "$DSR_CONFIG_DIR"
  cat > "$DSR_REPOS_FILE" << 'YAML'
tools:
  contract-tool: false
YAML

  ! config_get_release_contract_json contract-tool >/dev/null &&
    ! config_validate_release_contract contract-tool
}

test_config_validate_rejects_shadowed_non_mapping_registry_tool() {
  config_init
  config_load
  cat > "$DSR_REPOS_FILE" << 'YAML'
tools:
  contract-tool: false
YAML
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
release_contract: null
YAML

  ! config_validate
}

test_release_contract_rejects_non_sha256_sidecar() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
release_contract:
  checksum_sidecar: sha512
  exact_primary_assets:
    linux/amd64: contract-tool-linux-amd64
YAML
  ! config_validate_release_contract contract-tool
}

test_release_contract_rejects_missing_target() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64, darwin/arm64]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: contract-tool-linux-amd64
YAML
  ! config_validate_release_contract contract-tool
}

test_release_contract_rejects_extra_target() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: contract-tool-linux-amd64
    windows/amd64: contract-tool-windows-amd64.exe
YAML
  ! config_validate_release_contract contract-tool
}

test_release_contract_rejects_duplicate_primary_names() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64, darwin/arm64]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: contract-tool
    darwin/arm64: contract-tool
YAML
  ! config_validate_release_contract contract-tool
}

test_release_contract_rejects_empty_primary_name() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: ""
YAML
  ! config_validate_release_contract contract-tool
}

test_release_contract_rejects_unsafe_primary_name() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: "contract-tool;touch"
YAML
  ! config_validate_release_contract contract-tool
}

test_release_contract_rejects_primary_path() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: dir/contract-tool
YAML
  ! config_validate_release_contract contract-tool
}

test_release_contract_rejects_dotdot_primary() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: contract-tool..exe
YAML
  ! config_validate_release_contract contract-tool
}

test_release_contract_rejects_checksum_as_primary() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: contract-tool.sha256
YAML
  ! config_validate_release_contract contract-tool
}

test_release_contract_rejects_non_array_additional_assets() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: contract-tool
  exact_additional_assets: contract-tool.sbom.json
YAML
  ! config_validate_release_contract contract-tool
}

test_release_contract_rejects_null_additional_assets() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: contract-tool
  exact_additional_assets: null
YAML
  ! config_validate_release_contract contract-tool
}

test_release_contract_rejects_false_additional_assets() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: contract-tool
  exact_additional_assets: false
YAML
  ! config_validate_release_contract contract-tool
}

test_release_contract_rejects_unsafe_additional_asset() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: contract-tool
  exact_additional_assets: [../contract-tool.sbom.json]
YAML
  ! config_validate_release_contract contract-tool
}

test_release_contract_rejects_additional_primary_sidecar_collision() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: contract-tool
  exact_additional_assets: [CONTRACT-TOOL.SHA256]
YAML
  ! config_validate_release_contract contract-tool
}

test_release_contract_rejects_casefold_duplicate_additional_assets() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: contract-tool
  exact_additional_assets: [SBOM.json, sbom.JSON]
YAML
  ! config_validate_release_contract contract-tool
}

test_release_contract_rejects_unsupported_mode() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
release_contract:
  mode: exact
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: contract-tool-linux-amd64
YAML
  ! config_validate_release_contract contract-tool
}

test_release_contract_rejects_duplicate_configured_target() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64, linux/amd64]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: contract-tool-linux-amd64
YAML
  ! config_validate_release_contract contract-tool
}

# ============================================================================
# Tests: Edge Cases
# ============================================================================

# ============================================================================
# Tests: target_triples variants (bd-cdcz)
# ============================================================================

test_target_triples_list_keeps_order_and_primary() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64, darwin/arm64]
target_triples:
  linux/amd64:
    - x86_64-unknown-linux-musl
    - x86_64-unknown-linux-gnu
  darwin/arm64: aarch64-apple-darwin
YAML

  [[ "$(config_get_target_triples contract-tool linux/amd64)" == $'x86_64-unknown-linux-musl\nx86_64-unknown-linux-gnu' ]] &&
    [[ "$(config_get_target_triple contract-tool linux/amd64)" == "x86_64-unknown-linux-musl" ]] &&
    [[ "$(config_get_target_triples contract-tool darwin/arm64)" == "aarch64-apple-darwin" ]] &&
    [[ -z "$(config_get_target_triples contract-tool windows/amd64)" ]] &&
    config_validate_release_contract contract-tool
}

test_target_triples_registry_list() {
  release_contract_test_deps_available || return 0
  mkdir -p "$DSR_CONFIG_DIR"
  cat > "$DSR_REPOS_FILE" << 'YAML'
tools:
  registry-tool:
    target_triples:
      linux/arm64: [aarch64-unknown-linux-gnu, aarch64-unknown-linux-musl]
YAML

  [[ "$(config_get_target_triples registry-tool linux/arm64)" == $'aarch64-unknown-linux-gnu\naarch64-unknown-linux-musl' ]]
}

test_target_triples_rejects_invalid_entries() {
  release_contract_test_deps_available || return 0
  local value
  for value in '[]' '[x86_64-unknown-linux-gnu, x86_64-unknown-linux-gnu]' '"x86 64"' '[ok-triple, "../up"]' '{a: b}'; do
    write_contract_tool_config << YAML
tool_name: contract-tool
targets: [linux/amd64]
target_triples:
  linux/amd64: $value
YAML
    config_get_target_triples contract-tool linux/amd64 >/dev/null && return 1
    config_validate_release_contract contract-tool && return 1
  done
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
target_triples: [x86_64-unknown-linux-gnu]
YAML
  ! config_validate_release_contract contract-tool
}

test_target_triples_contract_requires_exact_variants() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
target_triples:
  linux/amd64: [x86_64-unknown-linux-gnu, x86_64-unknown-linux-musl]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: contract-tool-x86_64-unknown-linux-gnu
YAML
  ! config_validate_release_contract contract-tool || return 1

  # One listed triple is a single variant and stays admissible.
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
target_triples:
  linux/amd64: [x86_64-unknown-linux-musl]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: contract-tool-x86_64-unknown-linux-musl
YAML
  config_validate_release_contract contract-tool
}

test_target_triples_contract_preserves_variant_identity() {
  release_contract_test_deps_available || return 0
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64, darwin/arm64]
target_triples:
  linux/amd64: [x86_64-unknown-linux-musl, x86_64-unknown-linux-gnu]
  darwin/arm64: aarch64-apple-darwin
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64@x86_64-unknown-linux-musl: app-static
    linux/amd64@x86_64-unknown-linux-gnu: app-standard.tar.gz
    darwin/arm64: app-macos.zip
YAML
  config_validate_release_contract contract-tool || return 1
  local identities
  identities=$(config_get_release_contract_targets_json contract-tool) || return 1
  jq -e '. == [
    {key:"linux/amd64@x86_64-unknown-linux-musl",platform:"linux/amd64",
     target_triple:"x86_64-unknown-linux-musl",primary:true},
    {key:"linux/amd64@x86_64-unknown-linux-gnu",platform:"linux/amd64",
     target_triple:"x86_64-unknown-linux-gnu",primary:false},
    {key:"darwin/arm64",platform:"darwin/arm64",target_triple:"aarch64-apple-darwin",primary:true}
  ]' <<< "$identities" >/dev/null || return 1
  [[ $(config_get_release_contract_target_key contract-tool linux/amd64 x86_64-unknown-linux-gnu) == \
      linux/amd64@x86_64-unknown-linux-gnu ]] || return 1
  [[ $(config_get_release_contract_target_key contract-tool linux/amd64 x86_64-unknown-linux-musl) == \
      linux/amd64@x86_64-unknown-linux-musl ]] || return 1
  [[ $(config_get_release_contract_target_key contract-tool darwin/arm64) == darwin/arm64 ]] || return 1
  ! config_get_release_contract_target_key contract-tool linux/amd64 >/dev/null || return 1
  ! config_get_release_contract_target_key contract-tool linux/amd64 x86_64-unknown-linux-gnux32 >/dev/null || return 1
  ! config_get_release_contract_target_key contract-tool darwin/arm64 x86_64-apple-darwin >/dev/null
}

test_target_triples_contract_rejects_mixed_missing_or_extra_keys() {
  release_contract_test_deps_available || return 0
  local assets
  for assets in \
    '{"linux/amd64@x86_64-unknown-linux-gnu":"app-standard"}' \
    '{"linux/amd64":"app-standard","linux/amd64@x86_64-unknown-linux-musl":"app-static"}' \
    '{"linux/amd64@x86_64-unknown-linux-gnu":"app-standard","linux/amd64@x86_64-unknown-linux-musl":"app-static","linux/amd64":"app-ambiguous"}' \
    '{"linux/amd64@x86_64-unknown-linux-gnu":"app-standard","linux/amd64@x86_64-unknown-linux-musl":"app-static","linux/amd64@x86_64-unknown-linux-gnux32":"app-unknown"}' \
    '{"linux/amd64@x86_64-unknown-linux-gnu":"app-standard","linux/arm64@aarch64-unknown-linux-musl":"app-other-platform"}'; do
    write_contract_tool_config << YAML
tool_name: contract-tool
targets: [linux/amd64]
target_triples:
  linux/amd64: [x86_64-unknown-linux-gnu, x86_64-unknown-linux-musl]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets: $assets
YAML
    ! config_validate_release_contract contract-tool || return 1
  done
  # A singleton keeps its physical key even when its triple was an array.
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
target_triples:
  linux/amd64: [x86_64-unknown-linux-musl]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64@x86_64-unknown-linux-musl: app-static
YAML
  ! config_validate_release_contract contract-tool
}

test_config_validate_rejects_invalid_target_triples() {
  release_contract_test_deps_available || return 0
  config_init
  config_load
  write_contract_tool_config << 'YAML'
tool_name: contract-tool
targets: [linux/amd64]
target_triples:
  linux/amd64: []
YAML

  ! config_validate
}

test_additional_artifact_declarations_normalize() {
  local value
  value=$(config_normalize_additional_artifacts_json '{
    "windows/amd64":[{"name":"setup.msi","format":"msi"},{"name":"app.exe","format":"binary"}],
    "linux/armv7":["NOTICE.txt",{"name":"index.json","format":"json"},{"name":"docs.zip","format":"zip"}],
    "freebsd/amd64":[{"name":"sources.tar.gz","format":"tar.gz"},{"name":"data.tar.xz","format":"tar.xz"}]
  }' fixture) || return 1
  jq -e '
    .["windows/amd64"][0] == {name:"setup.msi",format:"msi"} and
    .["linux/armv7"][0] == {name:"NOTICE.txt",format:"file"} and
    ([.[][]] | length) == 7
  ' <<< "$value" >/dev/null || return 1
  [[ "$(config_normalize_additional_artifacts_json null)" == '{}' ]] || return 1
  [[ "$(config_normalize_additional_artifacts_json '{}')" == '{}' ]]
}

test_additional_artifact_declarations_reject_invalid_shapes() {
  local raw
  for raw in false '[]' '"file"' '{} {}' \
    '{"linux/amd64":false}' \
    '{"linux/amd64":[{"name":"a.json"}]}' \
    '{"linux/amd64":[{"name":"a.json","format":"json","skip":true}]}' \
    '{"linux/amd64":[{"name":"a.json","format":"unknown"}]}' \
    '{"linux/amd64":[{"name":"a.json","format":false}]}' \
    '{"linux/amd64":[{"name":7,"format":"json"}]}' \
    '{"linux/amd64":["../escape"]}' \
    '{"linux/amd64":["a/b"]}' \
    '{"linux/amd64":["a.sha256"]}' \
    '{"linux/amd64":["a.json\n"]}' \
    '{"linux/amd64":["a\u0000.json"]}' \
    '{"plan9/amd64":["a.json"]}' \
    '{"linux/amd64\n":[]}'; do
    if config_normalize_additional_artifacts_json "$raw" fixture >/dev/null 2>&1; then
      echo "  FAIL: accepted invalid additional artifact declarations: $raw"
      return 1
    fi
  done
}

test_additional_artifact_declarations_require_single_owner() {
  local raw
  for raw in '{"linux/amd64":["notes.txt","notes.txt"]}' \
    '{"linux/amd64":["notes.txt",{"name":"NOTES.TXT","format":"file"}]}' \
    '{"linux/amd64":["notes.txt"],"freebsd/amd64":["NOTES.txt"]}'; do
    if config_normalize_additional_artifacts_json "$raw" fixture > "$TEMP_DIR/output" 2> "$TEMP_DIR/error"; then
      return 1
    fi
    [[ ! -s "$TEMP_DIR/output" ]] || return 1
    grep -q 'one producer' "$TEMP_DIR/error" || return 1
  done
}

test_additional_artifact_declarations_preserve_metadata_namespace() {
  local name raw
  for name in SHA256SUMS SHA256SUMS.txt SHA256SUMS.custom checksums.txt \
      app.sha256 app.minisig app.sig app.sha512 release.intoto.jsonl app.sbom.cdx.json \
      APP.MINISIG CHECKSUMS.TXT APP.SBOM.JSON; do
    raw=$(jq -nc --arg name "$name" '{"linux/amd64":[{name:$name,format:"file"}]}') || return 1
    if config_normalize_additional_artifacts_json "$raw" fixture > "$TEMP_DIR/output" 2> "$TEMP_DIR/error"; then
      return 1
    fi
    [[ ! -s "$TEMP_DIR/output" ]] || return 1
    grep -q 'reserved release metadata name' "$TEMP_DIR/error" || return 1
  done
}

test_additional_artifact_registry_and_explicit_repo_precedence() {
  release_contract_test_deps_available || return 0
  config_init >/dev/null
  cat > "$DSR_REPOS_FILE" <<'YAML'
tools:
  contract-tool:
    workspace_additional_artifacts:
      windows/amd64: [{name: setup.msi, format: msi}]
YAML
  local value
  value=$(config_get_additional_artifacts_json contract-tool) || return 1
  jq -e '.["windows/amd64"] == [{name:"setup.msi",format:"msi"}]' <<< "$value" >/dev/null || return 1
  # The native reader uses repos.d as a complete authority. Preflight must not
  # promise registry companions that collection will never be configured to read.
  write_contract_tool_config <<'YAML'
targets: [linux/armv7]
YAML
  [[ "$(config_get_additional_artifacts_json contract-tool)" == '{}' ]] || return 1
  write_contract_tool_config <<'YAML'
targets: [linux/armv7]
workspace_additional_artifacts:
  linux/armv7: [notes.txt]
YAML
  value=$(config_get_additional_artifacts_json contract-tool) || return 1
  jq -e '. == {"linux/armv7":[{name:"notes.txt",format:"file"}]}' <<< "$value" >/dev/null || return 1
  write_contract_tool_config <<'YAML'
workspace_additional_artifacts: null
YAML
  [[ "$(config_get_additional_artifacts_json contract-tool)" == '{}' ]] || return 1
  write_contract_tool_config <<'YAML'
workspace_additional_artifacts: false
YAML
  ! config_get_additional_artifacts_json contract-tool >/dev/null 2>&1
}

test_additional_artifact_configuration_rejects_duplicate_yaml_keys() {
  release_contract_test_deps_available || return 0
  config_init >/dev/null
  write_contract_tool_config <<'YAML'
workspace_additional_artifacts:
  windows/amd64:
    - name: setup.msi
      format: msi
      format: file
YAML
  ! config_get_additional_artifacts_json contract-tool >/dev/null 2>&1
}

test_additional_artifact_variant_ownership() {
  release_contract_test_deps_available || return 1
  config_init >/dev/null
  write_contract_tool_config <<'YAML'
targets: [linux/amd64]
target_triples:
  linux/amd64: [x86_64-unknown-linux-gnu, x86_64-unknown-linux-musl]
workspace_additional_artifacts:
  linux/amd64:
    - {name: notes.json, format: json}
    - {name: runtime.zip, format: zip, target_triple: x86_64-unknown-linux-musl}
YAML
  local normalized owners
  normalized=$(config_get_additional_artifacts_json contract-tool) || return 1
  jq -e '.["linux/amd64"] == [
      {name:"notes.json",format:"json"},
      {name:"runtime.zip",format:"zip",target_triple:"x86_64-unknown-linux-musl"}]' \
      <<< "$normalized" >/dev/null || return 1
  owners=$(config_resolve_additional_artifact_owners_json \
      "$normalized" '{"linux/amd64":["x86_64-unknown-linux-gnu","x86_64-unknown-linux-musl"]}') || return 1
  jq -e '.["linux/amd64"] | .[0].owner_target_triple == "x86_64-unknown-linux-gnu" and
      (.[0] | has("target_triple") | not) and
      .[1].owner_target_triple == "x86_64-unknown-linux-musl" and
      .[1].target_triple == "x86_64-unknown-linux-musl"' <<< "$owners" >/dev/null || return 1
  owners=$(config_resolve_additional_artifact_owners_json \
      "$normalized" '{"linux/amd64":["x86_64-unknown-linux-musl","x86_64-unknown-linux-gnu"]}') || return 1
  jq -e 'all(.["linux/amd64"][]; .owner_target_triple == "x86_64-unknown-linux-musl")' \
      <<< "$owners" >/dev/null
}

test_additional_artifact_variant_rejects_unconfigured_selectors() {
  release_contract_test_deps_available || return 1
  config_init >/dev/null
  local selector status
  for selector in null false '""' '"unknown-linux-musl"' '"aarch64-unknown-linux-musl"' \
      '["x86_64-unknown-linux-musl"]' '"x86_64-unknown-linux-musl\n"'; do
    write_contract_tool_config <<YAML
targets: [linux/amd64]
target_triples:
  linux/amd64: [x86_64-unknown-linux-gnu, x86_64-unknown-linux-musl]
workspace_additional_artifacts:
  linux/amd64:
    - {name: runtime.zip, format: zip, target_triple: $selector}
YAML
    status=0
    config_get_additional_artifacts_json contract-tool > "$TEMP_DIR/output" 2> "$TEMP_DIR/error" || status=$?
    [[ "$status" == 4 && ! -s "$TEMP_DIR/output" ]] || return 1
  done
  write_contract_tool_config <<'YAML'
targets: [linux/amd64]
workspace_additional_artifacts:
  linux/amd64:
    - {name: runtime.zip, format: zip, target_triple: x86_64-unknown-linux-musl}
YAML
  ! config_get_additional_artifacts_json contract-tool >/dev/null 2>&1 || return 1
  write_contract_tool_config <<'YAML'
targets: [linux/amd64]
target_triples: {linux/amd64: [x86_64-unknown-linux-gnu, x86_64-unknown-linux-musl]}
workspace_additional_artifacts:
  linux/amd64:
    - {name: Runtime.zip, format: zip, target_triple: x86_64-unknown-linux-gnu}
    - {name: runtime.zip, format: zip, target_triple: x86_64-unknown-linux-musl}
YAML
  ! config_get_additional_artifacts_json contract-tool >/dev/null 2>&1
}

test_additional_artifact_configuration_accepts_native_and_act_producers() {
  release_contract_test_deps_available || return 0
  config_init >/dev/null
  config_load >/dev/null
  write_contract_tool_config <<'YAML'
targets: [linux/amd64, windows/amd64]
act_job_map:
  windows/amd64: build-windows
workspace_additional_artifacts:
  windows/amd64: [{name: setup.msi, format: msi}]
YAML
  config_validate > "$TEMP_DIR/validation.out" 2> "$TEMP_DIR/validation.err" || return 1
  local value jobs
  value=$(config_get_additional_artifacts_json contract-tool) || return 1
  jq -e '. == {"windows/amd64":[{name:"setup.msi",format:"msi"}]}' <<< "$value" >/dev/null || return 1
  write_contract_tool_config <<'YAML'
targets: [linux/amd64, windows/amd64]
act_job_map:
  linux/amd64: build-linux
  windows/amd64: null
workspace_additional_artifacts:
  linux/amd64: []
  windows/amd64: [{name: setup.msi, format: msi}]
YAML
  config_validate >/dev/null || return 1
  # Explicit native selectors and real workflow job arguments preserve the
  # same ownership mapping; the producer cannot change the declared format.
  for jobs in null '{}' '{"windows/amd64":null}' '{"windows/amd64":""}' \
      '{"windows/amd64":"null"}' '{"windows/amd64":"build-windows"}'; do
    value=$(config_normalize_additional_artifacts_json \
      '{"windows/amd64":[{"name":"setup.msi","format":"msi"}]}' \
      fixture "$jobs") || return 1
    jq -e '. == {"windows/amd64":[{name:"setup.msi",format:"msi"}]}' <<< "$value" >/dev/null || return 1
  done
  # Registry-only validation must admit the same exact typed declaration.
  cat > "$DSR_REPOS_FILE" <<'YAML'
tools:
  registry-only:
    targets: [linux/amd64]
    act_job_map: {linux/amd64: build-linux}
    workspace_additional_artifacts:
      linux/amd64: [notes.txt]
YAML
  value=$(config_get_additional_artifacts_json registry-only) || return 1
  jq -e '. == {"linux/amd64":[{name:"notes.txt",format:"file"}]}' <<< "$value" >/dev/null
}

test_additional_artifact_configuration_rejects_malformed_producer() {
  local jobs status
  for jobs in false true 0 '[]' '"build-windows"' \
      '{"windows/amd64":false}' '{"windows/amd64":true}' '{"windows/amd64":0}' \
      '{"windows/amd64":[]}' '{"windows/amd64":{}}' \
      '{"windows/amd64":"build\nwindows"}' '{"windows/amd64":"build\twindows"}' \
      '{"windows/amd64":"build\u007fwindows"}'; do
    status=0
    config_normalize_additional_artifacts_json \
      '{"windows/amd64":[{"name":"setup.msi","format":"msi"}]}' \
      fixture "$jobs" > "$TEMP_DIR/output" 2> "$TEMP_DIR/error" || status=$?
    [[ "$status" == 4 && ! -s "$TEMP_DIR/output" ]] || return 1
    grep -Eq 'act_job_map|act job selector' "$TEMP_DIR/error" || return 1
  done
  release_contract_test_deps_available || return 0
  config_init >/dev/null
  config_load >/dev/null
  write_contract_tool_config <<'YAML'
targets: [linux/amd64, windows/amd64]
act_job_map:
  linux/amd64: build-linux
  windows/amd64: false
workspace_additional_artifacts:
  windows/amd64: [{name: setup.msi, format: msi}]
YAML
  status=0
  config_validate > "$TEMP_DIR/validation.out" 2> "$TEMP_DIR/validation.err" || status=$?
  [[ "$status" == 4 ]] || return 1
  grep -q 'windows/amd64' "$TEMP_DIR/validation.err" || return 1
  grep -Eq 'act_job_map|act job selector' "$TEMP_DIR/validation.err"
}

test_config_validate_checks_all_additional_artifact_declarations() {
  release_contract_test_deps_available || return 0
  config_init >/dev/null
  config_load >/dev/null
  write_contract_tool_config <<'YAML'
targets: [linux/amd64, windows/amd64]
workspace_additional_artifacts:
  linux/amd64: [notes.txt]
  windows/amd64: [{name: setup.msi, format: unknown}]
YAML
  local status=0
  config_validate > "$TEMP_DIR/validation.out" 2> "$TEMP_DIR/validation.err" || status=$?
  [[ "$status" == 4 ]] || return 1
  grep -q 'windows/amd64.*setup.msi' "$TEMP_DIR/validation.err" || return 1
  write_contract_tool_config <<'YAML'
targets: [linux/amd64, windows/amd64]
workspace_additional_artifacts:
  linux/amd64: [notes.txt]
  windows/amd64: [{name: setup.msi, format: msi}]
YAML
  config_validate >/dev/null
}

test_platform_contract_exact_pairs() {
  local target matrix
  for target in linux/amd64 linux/arm64 linux/386 linux/armv7 darwin/amd64 \
      darwin/arm64 windows/amd64 windows/arm64 windows/386 freebsd/amd64; do
    dsr_platform_is_supported "$target" || return 1
    matrix=$(jq -nc --arg target "$target" '[$target]') || return 1
    dsr_platform_validate_targets_json "$matrix" || return 1
  done
  for target in linux/arm linux/ppc64le darwin/386 darwin/armv7 windows/armv7 \
      freebsd/arm64 freebsd/386 plan9/amd64 linux/x86_64 linux/amd64/extra \
      ' linux/amd64' 'linux/amd64 ' $'linux/amd64\n'; do
    dsr_platform_is_supported "$target" && return 1
    matrix=$(jq -nc --arg target "$target" '["linux/amd64",$target]') || return 1
    dsr_platform_validate_targets_json "$matrix" && return 1
  done
  for matrix in '' 'null' '{}' '[]' '[1]' '["linux/amd64","linux/amd64"]' \
      '["linux/amd64"] ["linux/arm64"]'; do
    dsr_platform_validate_targets_json "$matrix" && return 1
  done
  return 0
}

test_platform_contract_matches_json_schemas() {
  local platforms schemas_dir="$SRC_DIR/../schemas"
  platforms=$(dsr_platform_list | jq -Rsc 'split("\n") | map(select(length > 0)) | sort') || return 1
  jq -e --argjson platforms "$platforms" \
    '(."$defs".platform.enum | sort) == $platforms and
     .properties.requested_targets.items."$ref" == "#/$defs/platform" and
     ."$defs".native_build_environment.properties.target."$ref" == "#/$defs/platform" and
     (."$defs".artifact.properties.target.oneOf | any(."$ref" == "#/$defs/platform"))' \
    "$schemas_dir/manifest.json" >/dev/null || return 1
  jq -e --argjson platforms "$platforms" \
    '(."$defs".build_target.properties.platform.enum | sort) == $platforms' \
    "$schemas_dir/build-details.json" >/dev/null || return 1
  jq -e --argjson platforms "$platforms" \
    '(."$defs".artifact.properties.target.enum | sort) == $platforms' \
    "$schemas_dir/envelope.json" >/dev/null
}

test_seven_target_configuration_without_strict_contract() {
  config_init
  config_load
  write_contract_tool_config <<'YAML'
tool_name: contract-tool
targets: [linux/amd64, linux/arm64, linux/armv7, darwin/amd64, darwin/arm64, windows/amd64, freebsd/amd64]
target_triples:
  linux/armv7: armv7-unknown-linux-gnueabihf
  freebsd/amd64: x86_64-unknown-freebsd
YAML
  config_validate_release_contract contract-tool && config_validate
}

test_unsupported_configuration_names_target_without_strict_contract() {
  config_init
  config_load
  local output status=0
  # A registry-only tool must be rejected too; no strict-contract opt-in is
  # needed to prevent a successful compile with an unpublishable inventory.
  cat > "$DSR_REPOS_FILE" <<'YAML'
tools:
  contract-tool:
    targets: [linux/amd64, freebsd/arm64]
YAML
  output=$(config_validate 2>&1) || status=$?
  [[ "$status" == 4 && "$output" == *freebsd/arm64* &&
     "$output" == *'Select supported targets'* ]] || return 1
  printf 'tools: {}\n' > "$DSR_REPOS_FILE"
  write_contract_tool_config <<'YAML'
tool_name: contract-tool
targets: [linux/amd64, windows/armv7]
YAML
  status=0
  output=$(config_validate 2>&1) || status=$?
  [[ "$status" == 4 && "$output" == *windows/armv7* &&
     "$output" == *'Select supported targets'* ]]
}

test_load_handles_empty_config() {
  config_init
  # Create empty config file
  : > "$DSR_CONFIG_FILE"
  config_load  # Should not crash
  [[ -n "${DSR_CONFIG[threshold_seconds]:-}" ]]  # Defaults still applied
}

test_load_handles_comments() {
  config_init
  cat > "$DSR_CONFIG_FILE" << 'EOF'
# This is a comment
schema_version: "1.0.0"
# Another comment
threshold_seconds: 300
EOF
  config_load
  [[ "${DSR_CONFIG[threshold_seconds]}" == "300" ]]
}

test_load_handles_quoted_values() {
  config_init
  cat > "$DSR_CONFIG_FILE" << 'EOF'
schema_version: "1.0.0"
quoted_key: "quoted value"
single_quoted: 'single quoted'
EOF
  config_load
  [[ "${DSR_CONFIG[quoted_key]}" == "quoted value" ]] && \
  [[ "${DSR_CONFIG[single_quoted]}" == "single quoted" ]]
}

test_config_file_env_override() {
  config_init
  local custom_config="$TEMP_DIR/custom.yaml"
  cat > "$custom_config" << 'EOF'
schema_version: "1.0.0"
threshold_seconds: 9999
EOF
  export DSR_CONFIG_FILE="$custom_config"
  config_load
  local result="${DSR_CONFIG[threshold_seconds]}"
  unset DSR_CONFIG_FILE
  [[ "$result" == "9999" ]]
}

# ============================================================================
# Main Test Runner
# ============================================================================

main() {
  echo "=== config.sh Tests ==="
  echo ""

  if ! release_contract_test_deps_available; then
    echo "ERROR: release-contract tests require both yq and jq"
    return 1
  fi

  echo "Initialization Tests:"
  run_test "init_creates_config_dir" test_init_creates_config_dir
  run_test "init_creates_cache_dir" test_init_creates_cache_dir
  run_test "init_creates_state_dir" test_init_creates_state_dir
  run_test "init_creates_subdirs" test_init_creates_subdirs
  run_test "init_creates_config_yaml" test_init_creates_config_yaml
  run_test "init_creates_hosts_yaml" test_init_creates_hosts_yaml
  run_test "init_creates_repos_yaml" test_init_creates_repos_yaml
  run_test "init_no_overwrite" test_init_no_overwrite
  run_test "init_force_overwrites" test_init_force_overwrites
  run_test "init_config_has_schema_version" test_init_config_has_schema_version
  run_test "init_hosts_has_hosts" test_init_hosts_has_hosts
  run_test "init_repos_has_tools" test_init_repos_has_tools
  run_test "init_dry_run_does_not_create_roots" test_init_dry_run_does_not_create_roots
  run_test "init_rejects_unknown_arguments_without_writes" test_init_rejects_unknown_arguments_without_writes
  run_test "cli_init_dry_run_flag_orders" test_cli_init_dry_run_flag_orders
  run_test "cli_init_forced_plan_preserves_existing_files" test_cli_init_forced_plan_preserves_existing_files
  run_test "cli_init_preview_preserves_explicit_log" test_cli_init_preview_preserves_explicit_log
  run_test "cli_init_rejects_unknown_plan_arguments" test_cli_init_rejects_unknown_plan_arguments
  run_test "cli_init_real_run_creates_files" test_cli_init_real_run_creates_files
  run_test "init_force_preserves_complete_backup_generations" test_init_force_preserves_complete_backup_generations
  run_test "init_force_backup_failure_preserves_originals" test_init_force_backup_failure_preserves_originals
  run_test "init_directory_failure_propagates" test_init_directory_failure_propagates
  run_test "init_write_failure_retains_all_backups" test_init_write_failure_retains_all_backups
  run_test "init_force_refuses_unsafe_or_aliased_destinations" test_init_force_refuses_unsafe_or_aliased_destinations
  run_test "init_refuses_missing_aliased_destinations" test_init_refuses_missing_aliased_destinations
  run_test "cli_init_force_reports_retained_backups" test_cli_init_force_reports_retained_backups
  run_test "cli_init_filesystem_failure_is_not_initialized" test_cli_init_filesystem_failure_is_not_initialized
  run_test "cli_init_invalid_globals_dry_run_preserves_log" test_cli_init_invalid_globals_dry_run_preserves_log
  run_test "init_file_size_limit_preserves_live_files" test_init_file_size_limit_preserves_live_files
  run_test "init_force_preserves_unrelated_hardlink" test_init_force_preserves_unrelated_hardlink
  run_test "init_new_files_are_private" test_init_new_files_are_private
  run_test "init_partial_configuration_keeps_existing_file" test_init_partial_configuration_keeps_existing_file
  run_test "init_force_partial_configuration_reports_only_real_backup" test_init_force_partial_configuration_reports_only_real_backup
  run_test "init_force_preserves_restrictive_modes" test_init_force_preserves_restrictive_modes
  run_test "init_failed_publication_rolls_back" test_init_failed_publication_rolls_back
  run_test "init_ambiguous_publication_rolls_back" test_init_ambiguous_publication_rolls_back
  run_test "init_fresh_publication_never_clobbers_new_file" test_init_fresh_publication_never_clobbers_new_file
  run_test "init_rollback_preserves_intervening_edit" test_init_rollback_preserves_intervening_edit
  run_test "cli_init_publication_failure_reports_rollback" test_cli_init_publication_failure_reports_rollback
  run_test "init_failed_rollback_retains_recovery_files" test_init_failed_rollback_retains_recovery_files
  run_test "cli_init_failed_cleanup_reports_recovery" test_cli_init_failed_cleanup_reports_recovery
  run_test "init_exported_function_can_preview_in_child" test_init_exported_function_can_preview_in_child
  run_test "cli_init_log_alias_cannot_modify_configuration" test_cli_init_log_alias_cannot_modify_configuration
  run_test "init_preserves_callers_signal_traps" test_init_preserves_callers_signal_traps
  run_test "init_killed_publication_is_recoverable" test_init_killed_publication_is_recoverable

  echo ""
  echo "Loading Tests:"
  run_test "load_sets_defaults" test_load_sets_defaults
  run_test "load_default_threshold" test_load_default_threshold
  run_test "load_default_log_level" test_load_default_log_level
  run_test "load_reads_config_file" test_load_reads_config_file
  run_test "load_env_overrides_file" test_load_env_overrides_file
  run_test "load_threshold_env_override" test_load_threshold_env_override
  run_test "load_signing_disabled_by_env" test_load_signing_disabled_by_env
  run_test "load_resets_config" test_load_resets_config
  run_test "load_rejects_invalid_documents_without_changing_memory" test_load_rejects_invalid_documents_without_changing_memory
  run_test "load_parser_failure_preserves_memory" test_load_parser_failure_preserves_memory
  run_test "load_serializer_failure_preserves_memory_without_pipefail" test_load_serializer_failure_preserves_memory_without_pipefail
  run_test "load_missing_dependencies_preserve_memory" test_load_missing_dependencies_preserve_memory
  run_test "load_missing_config_defaults_without_parsers" test_load_missing_config_defaults_without_parsers
  run_test "load_empty_config_defaults_without_parsers" test_load_empty_config_defaults_without_parsers
  run_test "load_legacy_schema_remains_readable" test_load_legacy_schema_remains_readable
  run_test "load_scalar_values_are_preserved" test_load_scalar_values_are_preserved
  run_test "load_persisted_values_roundtrip" test_load_persisted_values_roundtrip
  run_test "cli_set_values_roundtrip" test_cli_set_values_roundtrip
  run_test "load_signing_environment_flags_use_real_policy" test_load_signing_environment_flags_use_real_policy
  run_test "load_signing_yaml_flags_use_real_policy" test_load_signing_yaml_flags_use_real_policy
  run_test "cli_read_commands_report_config_errors" test_cli_read_commands_report_config_errors

  echo ""
  echo "Get/Set Tests:"
  run_test "get_returns_value" test_get_returns_value
  run_test "get_returns_default" test_get_returns_default
  run_test "get_returns_empty_for_missing" test_get_returns_empty_for_missing
  run_test "set_updates_value" test_set_updates_value
  run_test "set_creates_new_key" test_set_creates_new_key
  run_test "set_persist_requires_yq" test_set_persist_requires_yq
  run_test "set_dry_run_preserves_disk_and_memory" test_set_dry_run_preserves_disk_and_memory
  run_test "cli_set_dry_run_flag_orders_preserve_files" test_cli_set_dry_run_flag_orders_preserve_files
  run_test "cli_edit_dry_run_never_launches_editor" test_cli_edit_dry_run_never_launches_editor
  run_test "config_mutations_reject_extra_arguments" test_config_mutations_reject_extra_arguments
  run_test "set_invalid_inputs_preserve_disk_and_memory" test_set_invalid_inputs_preserve_disk_and_memory
  run_test "set_persist_preserves_original_metadata_and_hardlink" test_set_persist_preserves_original_metadata_and_hardlink
  run_test "set_file_size_limit_preserves_disk_and_memory" test_set_file_size_limit_preserves_disk_and_memory
  run_test "set_failed_publication_rolls_back_memory_and_file" test_set_failed_publication_rolls_back_memory_and_file
  run_test "set_cleanup_failure_keeps_memory_and_recovery_evidence" test_set_cleanup_failure_keeps_memory_and_recovery_evidence
  run_test "set_refuses_unsafe_destinations_without_memory_changes" test_set_refuses_unsafe_destinations_without_memory_changes
  run_test "cli_mutation_log_aliases_preserve_original_backups" test_cli_mutation_log_aliases_preserve_original_backups
  run_test "cli_migrate_dry_run_preserves_files" test_cli_migrate_dry_run_preserves_files
  run_test "cli_migrate_rejects_invalid_schema_without_changes" test_cli_migrate_rejects_invalid_schema_without_changes
  run_test "cli_migrate_preserves_colliding_backup_generations" test_cli_migrate_preserves_colliding_backup_generations
  run_test "cli_migrate_current_schema_is_read_only" test_cli_migrate_current_schema_is_read_only
  run_test "cli_migrate_publication_failure_restores_original" test_cli_migrate_publication_failure_restores_original
  run_test "cli_migrate_rechecks_schema_after_lock_acquisition" test_cli_migrate_rechecks_schema_after_lock_acquisition
  run_test "set_killed_publication_blocks_other_writers" test_set_killed_publication_blocks_other_writers

  echo ""
  echo "Validation Tests:"
  run_test "validate_passes_with_init" test_validate_passes_with_init
  run_test "validate_fails_missing_dir" test_validate_fails_missing_dir
  run_test "validate_checks_schema_version" test_validate_checks_schema_version
  run_test "validate_rejects_unrepresentable_values" test_validate_rejects_unrepresentable_values
  run_test "platform_contract_exact_pairs" test_platform_contract_exact_pairs
  run_test "platform_contract_matches_json_schemas" test_platform_contract_matches_json_schemas
  run_test "additional_artifact_declarations_normalize" test_additional_artifact_declarations_normalize
  run_test "additional_artifact_declarations_reject_invalid_shapes" test_additional_artifact_declarations_reject_invalid_shapes
  run_test "additional_artifact_declarations_require_single_owner" test_additional_artifact_declarations_require_single_owner
  run_test "additional_artifact_declarations_preserve_metadata_namespace" test_additional_artifact_declarations_preserve_metadata_namespace
  run_test "additional_artifact_registry_and_explicit_repo_precedence" test_additional_artifact_registry_and_explicit_repo_precedence
  run_test "additional_artifact_configuration_rejects_duplicate_yaml_keys" test_additional_artifact_configuration_rejects_duplicate_yaml_keys
  run_test "additional_artifact_variant_ownership" test_additional_artifact_variant_ownership
  run_test "additional_artifact_variant_rejects_unconfigured_selectors" test_additional_artifact_variant_rejects_unconfigured_selectors
  run_test "additional_artifact_configuration_accepts_native_and_act_producers" test_additional_artifact_configuration_accepts_native_and_act_producers
  run_test "additional_artifact_configuration_rejects_malformed_producer" test_additional_artifact_configuration_rejects_malformed_producer
  run_test "config_validate_checks_all_additional_artifact_declarations" test_config_validate_checks_all_additional_artifact_declarations
  run_test "seven_target_configuration_without_strict_contract" test_seven_target_configuration_without_strict_contract
  run_test "unsupported_configuration_names_target_without_strict_contract" test_unsupported_configuration_names_target_without_strict_contract

  echo ""
  echo "Show Tests:"
  run_test "show_human_output" test_show_human_output
  run_test "show_json_output" test_show_json_output
  run_test "show_specific_key" test_show_specific_key
  run_test "show_json_specific_key" test_show_json_specific_key

  echo ""
  echo "XDG Compliance Tests:"
  run_test "xdg_config_home_override" test_xdg_config_home_override
  run_test "xdg_cache_home_override" test_xdg_cache_home_override
  run_test "xdg_state_home_override" test_xdg_state_home_override

  echo ""
  echo "Host/Tool Configuration Tests:"
  run_test "get_host_for_platform_linux" test_get_host_for_platform_linux
  run_test "get_host_for_platform_darwin" test_get_host_for_platform_darwin
  run_test "get_host_for_platform_windows" test_get_host_for_platform_windows
  run_test "list_hosts_returns_hosts" test_list_hosts_returns_hosts
  run_test "get_host_returns_config" test_get_host_returns_config

  echo ""
  echo "Release Contract Tests:"
  run_test "release_contract_absent_is_legacy_compatible" test_release_contract_absent_is_legacy_compatible
  run_test "release_contract_null_is_legacy_compatible" test_release_contract_null_is_legacy_compatible
  run_test "release_contract_rejects_non_object" test_release_contract_rejects_non_object
  run_test "release_contract_valid_is_canonical_json" test_release_contract_valid_is_canonical_json
  run_test "release_contract_accepts_pinned_minisign_key_file" test_release_contract_accepts_pinned_minisign_key_file
  run_test "release_contract_accepts_pinned_github_tag_ruleset" test_release_contract_accepts_pinned_github_tag_ruleset
  run_test "release_contract_rejects_invalid_github_tag_ruleset" test_release_contract_rejects_invalid_github_tag_ruleset
  run_test "release_contract_rejects_unsafe_minisign_key_paths" test_release_contract_rejects_unsafe_minisign_key_paths
  run_test "release_contract_rejects_minisign_asset_collisions" test_release_contract_rejects_minisign_asset_collisions
  run_test "release_contract_registry_fallback" test_release_contract_registry_fallback
  run_test "release_source_dependencies_absent_or_null_are_empty" test_release_source_dependencies_absent_or_null_are_empty
  run_test "release_source_dependencies_are_canonical_and_sorted" test_release_source_dependencies_are_canonical_and_sorted
  run_test "release_source_dependencies_registry_fallback_and_repo_precedence" test_release_source_dependencies_registry_fallback_and_repo_precedence
  run_test "release_source_dependencies_reject_missing_revision" test_release_source_dependencies_reject_missing_revision
  run_test "release_source_dependencies_require_absolute_nonroot_local_path" test_release_source_dependencies_require_absolute_nonroot_local_path
  run_test "release_source_dependencies_reject_unsafe_or_duplicate_paths" test_release_source_dependencies_reject_unsafe_or_duplicate_paths
  run_test "release_source_dependencies_reject_nonportable_path_aliases" test_release_source_dependencies_reject_nonportable_path_aliases
  run_test "config_validate_rejects_invalid_strict_release_dependency" test_config_validate_rejects_invalid_strict_release_dependency
  run_test "release_contract_registry_false_is_rejected" test_release_contract_registry_false_is_rejected
  run_test "release_contract_rejects_multiple_yaml_documents" test_release_contract_rejects_multiple_yaml_documents
  run_test "release_contract_rejects_non_mapping_yaml_roots" test_release_contract_rejects_non_mapping_yaml_roots
  run_test "release_contract_rejects_duplicate_yaml_keys" test_release_contract_rejects_duplicate_yaml_keys
  run_test "config_validate_rejects_invalid_repo_release_contract" test_config_validate_rejects_invalid_repo_release_contract
  run_test "config_validate_rejects_invalid_registry_release_contract" test_config_validate_rejects_invalid_registry_release_contract
  run_test "config_validate_rejects_non_mapping_registry_tools" test_config_validate_rejects_non_mapping_registry_tools
  run_test "release_contract_rejects_non_mapping_registry_tool" test_release_contract_rejects_non_mapping_registry_tool
  run_test "config_validate_rejects_shadowed_non_mapping_registry_tool" test_config_validate_rejects_shadowed_non_mapping_registry_tool
  run_test "release_contract_rejects_non_sha256_sidecar" test_release_contract_rejects_non_sha256_sidecar
  run_test "release_contract_rejects_missing_target" test_release_contract_rejects_missing_target
  run_test "release_contract_rejects_extra_target" test_release_contract_rejects_extra_target
  run_test "release_contract_rejects_duplicate_primary_names" test_release_contract_rejects_duplicate_primary_names
  run_test "release_contract_rejects_empty_primary_name" test_release_contract_rejects_empty_primary_name
  run_test "release_contract_accepts_build_manifest_assets" test_release_contract_accepts_build_manifest_assets
  run_test "release_contract_rejects_invalid_build_manifest_assets" test_release_contract_rejects_invalid_build_manifest_assets
  run_test "release_contract_rejects_unsafe_primary_name" test_release_contract_rejects_unsafe_primary_name
  run_test "release_contract_rejects_primary_path" test_release_contract_rejects_primary_path
  run_test "release_contract_rejects_dotdot_primary" test_release_contract_rejects_dotdot_primary
  run_test "release_contract_rejects_checksum_as_primary" test_release_contract_rejects_checksum_as_primary
  run_test "release_contract_rejects_non_array_additional_assets" test_release_contract_rejects_non_array_additional_assets
  run_test "release_contract_rejects_null_additional_assets" test_release_contract_rejects_null_additional_assets
  run_test "release_contract_rejects_false_additional_assets" test_release_contract_rejects_false_additional_assets
  run_test "release_contract_rejects_unsafe_additional_asset" test_release_contract_rejects_unsafe_additional_asset
  run_test "release_contract_rejects_additional_primary_sidecar_collision" test_release_contract_rejects_additional_primary_sidecar_collision
  run_test "release_contract_rejects_casefold_duplicate_additional_assets" test_release_contract_rejects_casefold_duplicate_additional_assets
  run_test "release_contract_rejects_unsupported_mode" test_release_contract_rejects_unsupported_mode
  run_test "release_contract_rejects_duplicate_configured_target" test_release_contract_rejects_duplicate_configured_target

  echo ""
  echo "Target Triple Variant Tests:"
  run_test "target_triples_list_keeps_order_and_primary" test_target_triples_list_keeps_order_and_primary
  run_test "target_triples_registry_list" test_target_triples_registry_list
  run_test "target_triples_rejects_invalid_entries" test_target_triples_rejects_invalid_entries
  run_test "target_triples_contract_requires_exact_variants" test_target_triples_contract_requires_exact_variants
  run_test "target_triples_contract_preserves_variant_identity" test_target_triples_contract_preserves_variant_identity
  run_test "target_triples_contract_rejects_mixed_missing_or_extra_keys" test_target_triples_contract_rejects_mixed_missing_or_extra_keys
  run_test "config_validate_rejects_invalid_target_triples" test_config_validate_rejects_invalid_target_triples

  echo ""
  echo "Edge Case Tests:"
  run_test "load_handles_empty_config" test_load_handles_empty_config
  run_test "load_handles_comments" test_load_handles_comments
  run_test "load_handles_quoted_values" test_load_handles_quoted_values
  run_test "config_file_env_override" test_config_file_env_override

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
