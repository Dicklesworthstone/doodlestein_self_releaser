#!/usr/bin/env bash
# Real naming/parsing APIs and the production JSONL logger. No network/builds.
set -uo pipefail
PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
NAMING_MODULE=${DSR_NAMING_MODULE:-$PROJECT_ROOT/src/artifact_naming.sh}
# shellcheck source=src/artifact_naming.sh
source "$NAMING_MODULE"
command -v jq >/dev/null && command -v yq >/dev/null || {
    printf 'jq and yq are required for the real naming/logging regressions\n' >&2
    exit 3
}
WORK=$(mktemp -d)
trap 'rm -rf -- "$WORK"' EXIT
an_checks=0 an_failures=0
check() {
    local label=$1
    shift
    an_checks=$((an_checks+1))
    if "$@"; then printf 'ok %d - %s\n' "$an_checks" "$label"; else
        printf 'not ok %d - %s\n' "$an_checks" "$label"
        an_failures=$((an_failures+1))
    fi
}
# Naming configuration is deliberately empty; the real renderer owns defaults.
config_get_arch_alias() { :; }
config_get_target_triple() { :; }
fixture="$PROJECT_ROOT/scripts/tests/fixtures/artifact_naming"
VERBOSE=false QUIET=false ARTIFACT_NAMING_DEBUG=0 LOG_LEVEL=info

artifact_naming_parse_install_script "$fixture/simple_install.sh" > "$WORK/install" 2> "$WORK/default.log"
check 'real installer pattern is found' test -s "$WORK/install"
check 'ordinary successful parsing is quiet' test ! -s "$WORK/default.log"
artifact_naming_generate_dual fixture v1.2.3 linux amd64 > "$WORK/names" 2> "$WORK/default-names.log"
check 'default names preserve their JSON contract' jq -e '.versioned == "fixture-1.2.3-linux-amd64.tar.gz" and .compat == "fixture-linux-amd64.tar.gz"' "$WORK/names"
check 'ordinary successful naming is quiet' test ! -s "$WORK/default-names.log"

# Execute outside a conditional/function call that would disable Bash errexit.
bash -e -c '
    source "$1"
    config_get_arch_alias() { :; }
    config_get_target_triple() { :; }
    VERBOSE=false QUIET=false ARTIFACT_NAMING_DEBUG=0 LOG_LEVEL=info
    artifact_naming_generate_dual fixture v1.2.3 linux amd64
    printf "continued\n"
' bash "$NAMING_MODULE" > "$WORK/errexit" 2> "$WORK/errexit.log"
an_errexit_status=$?
check 'disabled debug logging does not abort an errexit caller' test "$an_errexit_status" -eq 0
check 'errexit caller executes after successful naming' grep -qx continued "$WORK/errexit"

VERBOSE=true
artifact_naming_parse_install_script "$fixture/simple_install.sh" > "$WORK/verbose-install" 2> "$WORK/install.log"
check 'verbose installer parsing preserves output' cmp -s "$WORK/install" "$WORK/verbose-install"
check 'verbose parsing includes source selection' grep -q 'Parsing install script:' "$WORK/install.log"
check 'verbose parsing includes normalization' grep -q 'Normalized to:' "$WORK/install.log"
check 'standalone diagnostics carry ISO UTC time and module context' grep -Eq '^\[[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\] \[artifact_naming\] DEBUG:' "$WORK/install.log"
artifact_naming_parse_workflow "$fixture/sample_workflow.yml" > "$WORK/workflow" 2> "$WORK/workflow.log"
check 'real workflow parsing returns patterns' jq -e 'type == "array" and length > 0' "$WORK/workflow"
check 'workflow diagnostics identify the actual input' grep -q 'Parsing workflow:' "$WORK/workflow.log"
check 'workflow diagnostics identify discovered patterns' grep -q 'Found upload-artifact name:' "$WORK/workflow.log"
artifact_naming_generate_dual fixture v1.2.3 linux amd64 > "$WORK/verbose-names" 2> "$WORK/names.log"
check 'verbose dual naming preserves output' cmp -s "$WORK/names" "$WORK/verbose-names"
check 'verbose dual naming reports selected names' grep -q 'Versioned: fixture-1.2.3-linux-amd64.tar.gz' "$WORK/names.log"

VERBOSE=false ARTIFACT_NAMING_DEBUG=1
artifact_naming_generate_dual fixture v1.2.3 linux amd64 > "$WORK/explicit-names" 2> "$WORK/explicit.log"
check 'existing module debug flag remains supported' grep -q 'Generating dual names:' "$WORK/explicit.log"
check 'module debug flag preserves naming output' cmp -s "$WORK/names" "$WORK/explicit-names"
QUIET=true
artifact_naming_generate_dual fixture v1.2.3 linux amd64 > "$WORK/quiet-names" 2> "$WORK/quiet.log"
check 'quiet takes precedence over module debug' test ! -s "$WORK/quiet.log"
artifact_naming_generate_dual '../unsafe' v1.2.3 linux amd64 > "$WORK/rejected" 2> "$WORK/rejected.log"
an_rejected_status=$?
check 'quiet preserves invalid-name refusal' test "$an_rejected_status" -eq 4
check 'quiet preserves actionable error diagnostics' grep -q 'ERROR: Invalid artifact naming input' "$WORK/rejected.log"

# The CLI selects its log level through this same API; no log_init/rotation.
# shellcheck source=src/logging.sh
source "$PROJECT_ROOT/src/logging.sh"
LOG_FILE="$WORK/structured.jsonl"
DSR_CURRENT_CMD=build DSR_CURRENT_TOOL=fixture
ARTIFACT_NAMING_DEBUG=0 VERBOSE=true QUIET=false
log_set_level_from_flags "$VERBOSE" "$QUIET"
artifact_naming_generate_dual fixture v1.2.3 linux amd64 > "$WORK/structured-names" 2> "$WORK/structured.stderr"
check 'shared logger preserves naming output' cmp -s "$WORK/names" "$WORK/structured-names"
check 'CLI verbose selection records actual naming context' jq -es 'length > 0 and all(.[]; .level == "debug" and .cmd == "build" and .tool == "fixture" and (.ts | test("Z$")) and (.msg | startswith("[artifact_naming]")))' "$LOG_FILE"
check 'shared JSONL includes actual selected name' jq -es 'any(.[]; .msg == "[artifact_naming] Versioned: fixture-1.2.3-linux-amd64.tar.gz")' "$LOG_FILE"
check 'structured records are confined to the log stream' jq -e 'type == "object" and has("versioned") and (has("ts") | not)' "$WORK/structured-names"

# Library callers may provide a logger that writes to its stdout. The naming
# API must still reserve stdout exclusively for its machine-readable result.
log_debug() { printf 'caller diagnostic: %s\n' "$*"; }
artifact_naming_generate_dual fixture v1.2.3 linux amd64 > "$WORK/caller-names" 2> "$WORK/caller.log"
check 'caller logger cannot contaminate naming stdout' cmp -s "$WORK/names" "$WORK/caller-names"
check 'caller logger diagnostics are routed to stderr' grep -q 'caller diagnostic:' "$WORK/caller.log"

# A failed optional diagnostic sink cannot turn valid names into a failure.
log_debug() { return 77; }
artifact_naming_generate_dual fixture v1.2.3 linux amd64 > "$WORK/sink-names" 2> "$WORK/sink.log"
an_sink_status=$?
check 'failed diagnostic sink preserves successful operation status' test "$an_sink_status" -eq 0
check 'failed diagnostic sink preserves exact output' cmp -s "$WORK/names" "$WORK/sink-names"

printf '\nArtifact naming logging checks: %d; failures: %d\n' "$an_checks" "$an_failures"
[[ "$an_failures" -eq 0 ]]
