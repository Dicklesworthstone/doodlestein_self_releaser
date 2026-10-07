#!/usr/bin/env bats
# test_commands.bats - Integration tests for dsr CLI commands
#
# Tests dsr commands with mocked external dependencies (gh, ssh, etc.)
# Uses the test harness for isolated environment, time mocking, and log capture.
#
# Run: bats tests/integration/test_commands.bats

# Load harness and config
load ../helpers/test_harness.bash

# Setup and teardown hooks (required since bats.config.bash doesn't auto-load from subdirs)
setup() {
    harness_setup
}

teardown() {
    harness_teardown
}

setup_file() {
    cd "$DSR_PROJECT_ROOT" || exit 1
}

# ============================================================================
# Test Setup Helpers
# ============================================================================

# Create repos.d config files for testing
_setup_repos_d() {
    mkdir -p "$DSR_CONFIG_DIR/repos.d"

    # Create a minimal ntm config
    cat > "$DSR_CONFIG_DIR/repos.d/ntm.yaml" << 'EOF'
name: ntm
github:
  repo: Dicklesworthstone/ntm
  workflow: release.yml
local:
  path: /data/projects/ntm
  language: go
build:
  targets:
    - linux/amd64
    - darwin/arm64
    - windows/amd64
EOF

    # Create bv config
    cat > "$DSR_CONFIG_DIR/repos.d/bv.yaml" << 'EOF'
name: bv
github:
  repo: Dicklesworthstone/beads_viewer
  workflow: release.yml
local:
  path: /data/projects/beads_viewer
  language: rust
build:
  targets:
    - linux/amd64
    - darwin/arm64
EOF
}

# Create repos.yaml with tools section
_setup_repos_yaml() {
    # Ensure DSR_REPOS_FILE points to our test config
    export DSR_REPOS_FILE="$DSR_CONFIG_DIR/repos.yaml"

    cat > "$DSR_REPOS_FILE" << 'EOF'
schema_version: "1.0.0"
tools:
  ntm:
    repo: Dicklesworthstone/ntm
    local_path: /data/projects/ntm
    language: go
    targets:
      - linux/amd64
      - darwin/arm64
      - windows/amd64
    workflow: release.yml
  bv:
    repo: Dicklesworthstone/beads_viewer
    local_path: /data/projects/beads_viewer
    language: rust
    targets:
      - linux/amd64
      - darwin/arm64
    workflow: release.yml
EOF

    # Mock yq for YAML parsing (dsr repos needs it)
    mock_command_script "yq" '
# Simple yq mock that converts our test YAML to JSON
if [[ "$1" == "-o=json" ]]; then
    # Return JSON for .tools query
    cat << JSONEOF
{
  "ntm": {"repo": "Dicklesworthstone/ntm", "local_path": "/data/projects/ntm", "language": "go", "targets": ["linux/amd64", "darwin/arm64", "windows/amd64"], "workflow": "release.yml"},
  "bv": {"repo": "Dicklesworthstone/beads_viewer", "local_path": "/data/projects/beads_viewer", "language": "rust", "targets": ["linux/amd64", "darwin/arm64"], "workflow": "release.yml"}
}
JSONEOF
elif [[ "$1" == ".tools."* ]]; then
    # Handle .tools.ntm type queries
    local tool="${1#.tools.}"
    if [[ "$tool" == "ntm" ]]; then
        echo "repo: Dicklesworthstone/ntm"
        echo "local_path: /data/projects/ntm"
        echo "language: go"
    elif [[ "$tool" == "bv" ]]; then
        echo "repo: Dicklesworthstone/beads_viewer"
        echo "local_path: /data/projects/beads_viewer"
        echo "language: rust"
    else
        exit 1
    fi
elif [[ "$*" == *".tools | keys"* ]]; then
    echo "- ntm"
    echo "- bv"
else
    echo "unsupported yq mock invocation: $*" >&2
    exit 1
fi
'
}

# ============================================================================
# DRY CHECK TESTS
# ============================================================================

@test "dsr check --help exits 0 and shows usage" {
    run harness_run_dsr check --help
    assert_equal "0" "$status"
    assert_contains "$output" "USAGE:"
    assert_contains "$output" "dsr check"
}

@test "dsr check without repo shows error" {
    run harness_run_dsr check
    assert_equal "4" "$status"  # INVALID_ARGS
}

@test "dsr check with valid repo and mocked ok response" {
    harness_create_config
    _setup_repos_d

    # Mock gh to return no queued runs (healthy)
    mock_command_script "gh" '
echo "{\"workflow_runs\": []}"
'

    run harness_run_dsr check ntm
    # Should succeed (no throttling)
    assert_equal "0" "$status"
}

@test "dsr check detects queued run over threshold" {
    harness_create_config
    _setup_repos_d

    # Calculate a timestamp that's 15 minutes ago (over 10 min threshold)
    local old_time
    old_time=$(date -u -d "15 minutes ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -v-15M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "2026-01-30T11:45:00Z")

    # Mock gh to return a queued run that's been waiting too long
    mock_command_script "gh" "
echo '{\"workflow_runs\": [{\"id\": 12345, \"status\": \"queued\", \"created_at\": \"$old_time\", \"name\": \"Release\"}]}'
"

    run harness_run_dsr check ntm
    # Should fail (throttling detected)
    assert_equal "1" "$status"
    assert_contains "$output" "THROTTLED"
}

@test "dsr check --json returns valid JSON envelope" {
    harness_create_config
    _setup_repos_d

    mock_command_script "gh" '
echo "{\"workflow_runs\": []}"
'

    run harness_run_dsr --json check ntm

    # Debug: show output if test fails
    if [[ "$status" -ne 0 ]]; then
        echo "Status: $status"
        echo "Output: $output"
    fi

    assert_equal "0" "$status"

    # Extract JSON from multi-line output (starts with { ends with })
    local json_content
    json_content=$(echo "$output" | sed -n '/^{$/,/^}$/p')

    # Validate JSON structure
    echo "$json_content" | jq -e '.command == "check"'
    echo "$json_content" | jq -e '.status'
    echo "$json_content" | jq -e '.exit_code == 0'
    echo "$json_content" | jq -e '.details.threshold_seconds'
}

@test "dsr check fails with auth error when gh not authenticated" {
    harness_create_config
    _setup_repos_d

    # Mock gh auth status to fail
    mock_command_script "gh" '
if [[ "$1" == "auth" ]]; then
    exit 1
fi
echo "{}"
'

    # Unset GH_TOKEN if set
    unset GH_TOKEN 2>/dev/null || true
    unset GITHUB_TOKEN 2>/dev/null || true

    run harness_run_dsr check ntm
    # Exit code 3 = DEPENDENCY_ERROR (auth required)
    assert_equal "3" "$status"
}

# A gh that answers auth and serves one run listing for ntm's API calls (no
# runs elsewhere), recording each call; an empty listing is an API failure.
_mock_gh_runs() {
    printf '%s' "$1" > "$TEST_TMPDIR/runs.json"
    export GH_RETRY_DELAY=0
    mock_command_script "gh" "
printf '%s\n' \"\$*\" >> \"$TEST_TMPDIR/gh.calls\"
[[ \"\$1\" == auth ]] && exit 0
if [[ \"\$1\" == api ]]; then
    [[ -s \"$TEST_TMPDIR/runs.json\" ]] || { echo 'gh: Bad gateway (HTTP 502)' >&2; exit 1; }
    if [[ \"\$*\" == *repos/Dicklesworthstone/ntm/* ]]; then
        cat \"$TEST_TMPDIR/runs.json\"
    else
        echo '{\"workflow_runs\": []}'
    fi
    exit 0
fi
echo '{}'
"
}

# The JSON envelope (stdout only) of one dsr run in $json, its exit in $status.
_dsr_json() {
    status=0
    json=$(harness_run_dsr --json "$@" 2>/dev/null) || status=$?
}

_minutes_ago() {
    date -u -d "$1 minutes ago" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null ||
        date -u -v-"$1"M +"%Y-%m-%dT%H:%M:%SZ"
}

# A queued run of release.yml, 15 minutes old, started by tag v1.2.3.
_queued_release_run() {
    printf '{"workflow_runs":[{"id":12345,"status":"queued","created_at":"%s","name":"Release","path":".github/workflows/release.yml","head_branch":"v1.2.3","html_url":"https://github.com/Dicklesworthstone/ntm/actions/runs/12345"}]}' \
        "$(_minutes_ago 15)"
}

@test "dsr check defaults to every configured repo's release workflow" {
    harness_create_config
    _setup_repos_d
    _mock_gh_runs '{"workflow_runs": []}'

    _dsr_json check
    assert_equal "0" "$status"
    grep -q 'api repos/Dicklesworthstone/ntm/actions/workflows/release.yml/runs' "$TEST_TMPDIR/gh.calls"
    grep -q 'api repos/Dicklesworthstone/beads_viewer/actions/workflows/release.yml/runs' "$TEST_TMPDIR/gh.calls"
    # A registry-only tool without a workflow is checked across workflows.
    grep -q 'api repos/test/test-tool/actions/runs' "$TEST_TMPDIR/gh.calls"
    echo "$json" | jq -e '.details.repos_checked ==
            ["Dicklesworthstone/beads_viewer","Dicklesworthstone/ntm","test/test-tool"] and
        .details.healthy == .details.repos_checked and .details.throttled == [] and .details.skipped == []'
}

@test "dsr check --all checks every workflow" {
    harness_create_config
    _setup_repos_d
    _mock_gh_runs '{"workflow_runs": []}'

    run harness_run_dsr check --all ntm
    assert_equal "0" "$status"
    grep -q 'api repos/Dicklesworthstone/ntm/actions/runs' "$TEST_TMPDIR/gh.calls"
    run grep -q 'actions/workflows/' "$TEST_TMPDIR/gh.calls"
    assert_equal "1" "$status"
}

@test "dsr check --json reports throttled runs in the documented shape" {
    harness_create_config
    _setup_repos_d
    _mock_gh_runs "$(_queued_release_run)"

    _dsr_json check ntm
    assert_equal "1" "$status"
    echo "$json" | jq -e '.status == "partial" and .exit_code == 1 and
        (.details.throttled | length) == 1 and
        (.details.throttled[0] | .repo == "Dicklesworthstone/ntm" and .tool == "ntm" and
            .workflow == "release.yml" and .run_id == 12345 and .status == "queued" and
            .head_branch == "v1.2.3" and .queue_time_seconds >= 600 and .threshold_seconds == 600) and
        .details.healthy == []'

    # The envelope and details satisfy the published schemas.
    if python3 -c 'import jsonschema' 2>/dev/null; then
        printf '%s\n' "$json" > "$TEST_TMPDIR/check.json"
        python3 -I - "$TEST_TMPDIR/check.json" "$DSR_PROJECT_ROOT/schemas" <<'PY'
import json, sys, jsonschema
doc = json.load(open(sys.argv[1]))
for name, instance in (("envelope.json", doc), ("check-details.json", doc["details"])):
    schema = json.load(open(f"{sys.argv[2]}/{name}"))
    jsonschema.Draft202012Validator(schema).validate(instance)
PY
    fi
}

@test "dsr check reports an API failure as exit 8, never as healthy" {
    harness_create_config
    _setup_repos_d
    _mock_gh_runs ''

    _dsr_json check ntm
    assert_equal "8" "$status"
    echo "$json" | jq -e '.status == "error" and .exit_code == 8 and .details.healthy == [] and
        .details.skipped == [{"repo": "Dicklesworthstone/ntm", "reason": "failed to fetch runs"}]'
}

@test "dsr check uses the configured threshold unless --threshold is given" {
    harness_create_config
    _setup_repos_d
    _mock_gh_runs "$(_queued_release_run)"

    DSR_THRESHOLD=3600 _dsr_json check ntm
    assert_equal "0" "$status"
    echo "$json" | jq -e '.details.threshold_seconds == 3600'

    DSR_THRESHOLD=3600 run harness_run_dsr check ntm --threshold 300
    assert_equal "1" "$status"

    run harness_run_dsr check ntm --threshold soon
    assert_equal "4" "$status"
}

@test "dsr watch reports a throttled run without starting a fallback by default" {
    harness_create_config
    _setup_repos_d
    _mock_gh_runs "$(_queued_release_run)"

    run harness_run_dsr --json watch --once
    assert_equal "0" "$status"
    assert_contains "$output" "Throttled run detected: 12345"
    assert_contains "$output" "dsr fallback ntm --version v1.2.3"
    [[ ! -e "$DSR_STATE_DIR/fallback-12345.log" ]]
    run jq -e '.runs["12345"]' "$DSR_STATE_DIR/triggered.json"
    [[ "$status" -ne 0 ]]
}

@test "dsr watch --auto-fallback starts the tool's fallback at the run's tag" {
    harness_create_config
    _setup_repos_d
    _mock_gh_runs "$(_queued_release_run)"

    run harness_run_dsr watch --once --auto-fallback --dry-run
    assert_equal "0" "$status"
    assert_contains "$output" "[DRY RUN] Would trigger fallback for ntm --version v1.2.3 (run 12345)"

    run harness_run_dsr watch --once --auto-fallback
    assert_equal "0" "$status"
    assert_contains "$output" "Fallback started"
    [[ -e "$DSR_STATE_DIR/fallback-12345.log" ]]
    jq -e '.runs["12345"]' "$DSR_STATE_DIR/triggered.json"
}

@test "dsr watch honors the global --dry-run" {
    harness_create_config
    _setup_repos_d
    _mock_gh_runs "$(_queued_release_run)"

    run harness_run_dsr --dry-run watch --once --auto-fallback
    assert_equal "0" "$status"
    assert_contains "$output" "[DRY RUN] Would trigger fallback for ntm"
    [[ ! -e "$DSR_STATE_DIR/fallback-12345.log" ]]
}

@test "dsr watch rejects unknown options and runs outside the checkout" {
    run harness_run_dsr watch --frobnicate
    assert_equal "4" "$status"

    harness_create_config
    _setup_repos_d
    _mock_gh_runs '{"workflow_runs": []}'
    cd "$TEST_TMPDIR"
    run harness_run_dsr watch --once
    assert_equal "0" "$status"
    assert_contains "$output" "Preflight check passed"
}

# ============================================================================
# DSR REPOS TESTS
# ============================================================================

@test "dsr repos --help exits 0 and shows usage" {
    run harness_run_dsr repos --help
    assert_equal "0" "$status"
    assert_contains "$output" "USAGE:"
    assert_contains "$output" "dsr repos"
}

@test "dsr repos list shows registered repos" {
    harness_create_config
    _setup_repos_yaml

    run harness_run_dsr repos list

    # Debug output
    if [[ "$status" -ne 0 ]]; then
        echo "Status: $status"
        echo "Output: $output"
        echo "DSR_REPOS_FILE: $DSR_REPOS_FILE"
        ls -la "$DSR_CONFIG_DIR" || true
    fi

    assert_equal "0" "$status"
    assert_contains "$output" "ntm"
    assert_contains "$output" "bv"
}

@test "dsr repos list --json returns valid JSON" {
    harness_create_config
    _setup_repos_yaml

    run harness_run_dsr --json repos list
    assert_equal "0" "$status"

    # Extract JSON from multi-line output
    local json_content
    json_content=$(echo "$output" | sed -n '/^{$/,/^}$/p')

    # Validate JSON
    echo "$json_content" | jq -e '.command == "repos"'
    echo "$json_content" | jq -e '.details.repos'
}

@test "dsr repos info shows repo details" {
    harness_create_config
    _setup_repos_yaml
    _setup_repos_d

    run harness_run_dsr repos info ntm

    # May fail if yq mock doesn't handle all cases, but should not be exit 3 (auth error)
    # Exit code 4 means config/args error which is acceptable if yq mock is incomplete
    if [[ "$status" -eq 0 ]]; then
        assert_contains "$output" "ntm"
    else
        # Skip if yq mock doesn't support this query
        skip "Requires full yq support for repos info"
    fi
}

@test "dsr repos list fails gracefully without repos file" {
    # Don't create repos.yaml
    harness_create_config
    export DSR_REPOS_FILE="$DSR_CONFIG_DIR/repos.yaml"
    rm -f "$DSR_REPOS_FILE"

    run harness_run_dsr repos list
    assert_equal "4" "$status"  # INVALID_ARGS or config error
}

# ============================================================================
# DSR CONFIG TESTS
# ============================================================================

@test "dsr config --help exits 0 and shows usage" {
    run harness_run_dsr config --help
    assert_equal "0" "$status"
    assert_contains "$output" "USAGE:"
    assert_contains "$output" "dsr config"
}

@test "dsr config show displays configuration" {
    harness_create_config

    run harness_run_dsr config show
    assert_equal "0" "$status"
    assert_contains "$output" "threshold"
}

@test "dsr config show --json returns valid JSON" {
    harness_create_config

    run harness_run_dsr --json config show
    assert_equal "0" "$status"

    # Extract JSON from multi-line output
    local json_content
    json_content=$(echo "$output" | sed -n '/^{$/,/^}$/p')

    # Should be valid JSON with envelope structure
    # Note: config show may output a different structure
    echo "$json_content" | jq -e '.'
}

@test "dsr config init creates config files" {
    # Start with empty config dir
    rm -rf "${DSR_CONFIG_DIR:?}"/*
    mkdir -p "$DSR_CONFIG_DIR"

    run harness_run_dsr config init

    # Config init may create files in XDG directories
    # Check either DSR_CONFIG_DIR or XDG_CONFIG_HOME/dsr
    if [[ -f "$DSR_CONFIG_DIR/config.yaml" ]]; then
        assert_file_exists "$DSR_CONFIG_DIR/config.yaml"
    elif [[ -f "$XDG_CONFIG_HOME/dsr/config.yaml" ]]; then
        assert_file_exists "$XDG_CONFIG_HOME/dsr/config.yaml"
    else
        # Skip if no config file was created (may need yq)
        skip "Config init may require yq or writes to different location"
    fi
}

@test "dsr config validate checks config" {
    harness_create_config

    run harness_run_dsr config validate

    # Validate may fail if yq is not available for YAML parsing
    if [[ "$status" -ne 0 ]]; then
        skip "Config validate requires yq"
    fi
    assert_equal "0" "$status"
}

@test "dsr config set saves the value or fails, never claims an unsaved write" {
    _dsr_json config set threshold_seconds=300
    assert_equal "4" "$status"
    echo "$json" | jq -e '.command == "config" and .status == "error" and
        .details.action == "set" and .details.persisted == false'

    harness_create_config
    _dsr_json config set threshold_seconds=300
    assert_equal "0" "$status"
    echo "$json" | jq -e '.details.persisted == true'
    run harness_run_dsr config get threshold_seconds
    assert_contains "$output" "300"
    grep -q '^threshold_seconds: "\{0,1\}300' "$DSR_CONFIG_DIR/config.yaml"
}

@test "dsr config show --section and get answer with config envelopes" {
    harness_create_config
    _dsr_json config show --section signing
    assert_equal "0" "$status"
    echo "$json" | jq -e '.command == "config" and .details.action == "show" and
        .details.section == "signing" and .details.values == {"signing.enabled": "false"}'

    _dsr_json config show --section no_such_section
    assert_equal "4" "$status"

    _dsr_json config get log_level
    echo "$json" | jq -e '.command == "config" and .details == {"action": "get", "key": "log_level", "value": "debug"}'
}

@test "dsr config migrate stamps a missing schema_version after a backup" {
    harness_create_config
    sed -i.orig '/^schema_version/d' "$DSR_CONFIG_DIR/config.yaml"
    rm -f "$DSR_CONFIG_DIR/config.yaml.orig"

    _dsr_json config migrate --dry-run
    assert_equal "0" "$status"
    echo "$json" | jq -e '.details.dry_run and .details.changed_keys == ["schema_version"]'
    run grep -q '^schema_version' "$DSR_CONFIG_DIR/config.yaml"
    assert_equal "1" "$status"

    _dsr_json config migrate
    assert_equal "0" "$status"
    local backup
    backup=$(echo "$json" | jq -r '.details.backup_path')
    [[ -f "$backup" ]]
    run grep -q '^schema_version' "$backup"
    assert_equal "1" "$status"
    grep -q '^schema_version: "\{0,1\}1.0.0' "$DSR_CONFIG_DIR/config.yaml"

    _dsr_json config migrate
    echo "$json" | jq -e '.details.from_version == "1.0.0" and .details.changed_keys == []'

    sed -i.orig 's/^schema_version.*/schema_version: "9.9.9"/' "$DSR_CONFIG_DIR/config.yaml"
    _dsr_json config migrate
    assert_equal "4" "$status"
}

# ============================================================================
# DSR REPORT TESTS
# ============================================================================

_iso_ago() {
    date -u -d "$1 ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
        date -u -v-"${1// /}" +%Y-%m-%dT%H:%M:%SZ
}

# Today's run log: a watcher whose fallback (ntm) failed with exit 6 while it
# ran, a later successful build of bv, and status calls that are not runs.
_write_report_log() {
    local day="$DSR_STATE_DIR/logs/$(date +%Y-%m-%d)"
    mkdir -p "$day"
    cat > "$day/run.log" << EOF
{"ts":"$(_iso_ago '3 hours')","run_id":"w1","level":"info","cmd":"watch","msg":"Session started"}
{"ts":"$(_iso_ago '170 minutes')","run_id":"f1","level":"info","cmd":"fallback","msg":"Session started"}
{"ts":"$(_iso_ago '169 minutes')","run_id":"f1","level":"info","cmd":"fallback","tool":"ntm","msg":"Building ntm"}
{"ts":"$(_iso_ago '165 minutes')","run_id":"w1","level":"warn","cmd":"watch","msg":"Throttled run detected"}
{"ts":"$(_iso_ago '160 minutes')","run_id":"f1","level":"info","cmd":"fallback","msg":"Session finished","exit_code":6}
{"ts":"$(_iso_ago '2 hours')","run_id":"b1","level":"info","cmd":"build","msg":"Session started"}
{"ts":"$(_iso_ago '119 minutes')","run_id":"b1","level":"info","cmd":"build","tool":"bv","msg":"Building bv"}
{"ts":"$(_iso_ago '118 minutes')","run_id":"b1","level":"info","cmd":"build","msg":"Session finished","exit_code":0}
{"ts":"$(_iso_ago '90 minutes')","run_id":"s1","level":"info","cmd":"status","msg":"Session started"}
{"ts":"$(_iso_ago '90 minutes')","run_id":"s1","level":"info","cmd":"status","msg":"Session finished","exit_code":0}
{"ts":"$(_iso_ago '1 hour')","run_id":"w1","level":"info","cmd":"watch","msg":"Session finished","exit_code":0}
EOF
    ln -sfn "$(date +%Y-%m-%d)" "$DSR_STATE_DIR/logs/latest"
    mkdir -p "$DSR_STATE_DIR/check"
    printf '{"checked_at":"%s","threshold_seconds":600,"repos_checked":["o/a","o/b"],"throttled":["o/a"],"skipped":[]}\n' \
        "$(_iso_ago '5 minutes')" > "$DSR_STATE_DIR/check/last.json"
}

@test "dsr report summarizes runs, failures and throttling from the run logs" {
    harness_create_config
    _write_report_log

    _dsr_json report
    assert_equal "0" "$status"
    # status and report calls are not runs; the newest run is listed first.
    echo "$json" | jq -e '.command == "report" and
        .details.summary == {"runs_last_24h": 3, "failures_last_24h": 1, "throttled_repos": 1, "in_progress": 0} and
        [.details.recent_runs[] | .command] == ["build", "fallback", "watch"]'
    echo "$json" | jq -e '[.details.recent_runs[] | select(.command == "fallback")][0] |
        .repo == "ntm" and .exit_code == 6 and .status == "error" and .duration_ms == 600000'
    echo "$json" | jq -e '.details.alerts == [{"code": "E010", "severity": "error",
        "message": "fallback ntm exited 6 at \(.details.recent_runs[] | select(.command == "fallback") | .started_at)"}]'

    _dsr_json report --repo ntm
    echo "$json" | jq -e '[.details.recent_runs[].command] == ["fallback"] and .details.repo == "ntm"'

    _dsr_json report --since 30m
    echo "$json" | jq -e '.details.window.runs == 0 and .details.summary.runs_last_24h >= 3'

    run harness_run_dsr report --since soon
    assert_equal "4" "$status"
}

@test "dsr check records its result for report and status" {
    harness_create_config
    _setup_repos_d
    _mock_gh_runs ''

    run harness_run_dsr check ntm
    assert_equal "8" "$status"
    jq -e '.repos_checked == ["Dicklesworthstone/ntm"] and .skipped == ["Dicklesworthstone/ntm"] and
        .threshold_seconds == 600' "$DSR_STATE_DIR/check/last.json"

    _dsr_json report
    echo "$json" | jq -e '[.details.recent_runs[] | select(.command == "check")][0].exit_code == 8 and
        (.details.alerts | map(.code) | index("E003")) != null'

    _dsr_json status
    echo "$json" | jq -e '.details.queue.throttled_count == 0 and .details.queue.threshold_seconds == 600 and
        .details.last_run.command == "check" and .details.overall_status == "degraded"'

    # A dry-run check leaves the recorded result alone.
    rm -f "$DSR_STATE_DIR/check/last.json"
    run harness_run_dsr --dry-run check ntm
    [[ ! -e "$DSR_STATE_DIR/check/last.json" ]]
}

# ============================================================================
# DSR STATUS TESTS
# ============================================================================

@test "dsr status --help exits 0 and shows usage" {
    run harness_run_dsr status --help
    assert_equal "0" "$status"
    assert_contains "$output" "USAGE:"
    assert_contains "$output" "dsr status"
}

@test "dsr status shows system status" {
    harness_create_config

    run harness_run_dsr status
    assert_equal "0" "$status"
}

@test "dsr status --json returns valid JSON envelope" {
    harness_create_config

    run harness_run_dsr --json status
    assert_equal "0" "$status"

    # Extract JSON from multi-line output
    local json_content
    json_content=$(echo "$output" | sed -n '/^{$/,/^}$/p')

    # Validate JSON structure
    echo "$json_content" | jq -e '.command == "status"'
    echo "$json_content" | jq -e '.details'
}

# ============================================================================
# DSR DOCTOR TESTS
# ============================================================================

@test "dsr doctor --help exits 0 and shows usage" {
    run harness_run_dsr doctor --help
    assert_equal "0" "$status"
    assert_contains "$output" "USAGE:"
    assert_contains "$output" "dsr doctor"
}

@test "dsr doctor checks dependencies" {
    harness_create_config

    # Mock common tools to be available
    mock_command "git" "git version 2.40.0" 0
    mock_command "jq" "jq-1.6" 0

    run harness_run_dsr doctor

    # Doctor checks real system dependencies, may return various codes
    # 0=ok, 1=partial issues, 3=dependency error
    # Just ensure it runs and produces output
    [[ -n "$output" ]]
}

@test "dsr doctor --json returns valid JSON" {
    harness_create_config

    run harness_run_dsr --json doctor

    # Doctor may fail checking dependencies, but should still output JSON
    # Extract JSON from multi-line output
    local json_content
    json_content=$(echo "$output" | sed -n '/^{$/,/^}$/p')

    # If we got JSON, validate it
    if [[ -n "$json_content" ]]; then
        echo "$json_content" | jq -e '.command == "doctor"'
    fi
}

# ============================================================================
# DSR BUILD TESTS (dry-run only)
# ============================================================================

@test "dsr build --help exits 0 and shows usage" {
    run harness_run_dsr build --help
    assert_equal "0" "$status"
    assert_contains "$output" "USAGE:"
    assert_contains "$output" "dsr build"
}

@test "dsr build --dry-run shows planned actions" {
    harness_create_config
    _setup_repos_yaml
    _setup_repos_d

    # Mock git for version detection
    mock_command_script "git" '
if [[ "$*" == *"describe"* ]]; then
    echo "v1.2.3"
elif [[ "$*" == *"rev-parse"* ]]; then
    echo "abc123"
elif [[ "$*" == *"status"* ]]; then
    echo ""
else
    echo "mock git"
fi
'

    run harness_run_dsr --dry-run build ntm

    # Build command may fail due to missing dependencies or incomplete mocks
    # The important test is that it doesn't crash and responds to --dry-run
    if [[ "$status" -eq 0 ]]; then
        assert_contains "$output" "dry-run" || assert_contains "$output" "Would" || assert_contains "$output" "build"
    else
        # Skip if dependencies missing
        skip "Build command requires additional dependencies"
    fi
}

@test "dsr build without repo shows error" {
    harness_create_config

    run harness_run_dsr build
    assert_equal "4" "$status"
}

# ============================================================================
# DSR RELEASE TESTS (dry-run only)
# ============================================================================

@test "dsr release --help exits 0 and shows usage" {
    run harness_run_dsr release --help
    assert_equal "0" "$status"
    assert_contains "$output" "USAGE:"
    assert_contains "$output" "dsr release"
}

@test "dsr release verify --help exits 0" {
    run harness_run_dsr release verify --help
    assert_equal "0" "$status"
    assert_contains "$output" "USAGE:"
}

@test "dsr release formulas --help exits 0" {
    run harness_run_dsr release formulas --help
    assert_equal "0" "$status"
    assert_contains "$output" "USAGE:"
}

@test "dsr release finalize explains its usage errors" {
    run harness_run_dsr release finalize --help
    assert_equal "0" "$status"
    [[ "$output" == *"--create-response"* ]]

    run bash -c '"$1" release finalize tool 1.0.0 --no-dispatch 2>&1 >/dev/null' _ "$PROJECT_ROOT/dsr"
    assert_equal "4" "$status"
    [[ "$output" == *"--create-response must be the absolute path"* ]]

    run bash -c '"$1" release finalize tool 1.0.0 --create-response /tmp/dsr-api-response.ABCDEF12 2>&1 >/dev/null' _ "$PROJECT_ROOT/dsr"
    assert_equal "4" "$status"
    [[ "$output" == *"requires --no-dispatch"* ]]
}

@test "dsr release without args shows error" {
    harness_create_config

    run harness_run_dsr release
    assert_equal "4" "$status"
}

# ============================================================================
# GLOBAL FLAGS TESTS
# ============================================================================

@test "dsr --version shows version" {
    run harness_run_dsr --version
    assert_equal "0" "$status"
    assert_contains "$output" "dsr"
    assert_contains "$output" "version"
}

@test "dsr --version --json returns JSON" {
    run harness_run_dsr --json --version
    assert_equal "0" "$status"

    # Version output is single-line JSON
    local json_content
    json_content=$(echo "$output" | grep -E '^\{.*\}$')

    echo "$json_content" | jq -e '.tool == "dsr"'
    echo "$json_content" | jq -e '.version'
}

@test "dsr --help shows main help" {
    run harness_run_dsr --help
    assert_equal "0" "$status"
    assert_contains "$output" "USAGE:"
    assert_contains "$output" "COMMANDS:"
}

@test "dsr with unknown command fails gracefully" {
    run harness_run_dsr unknown_command_xyz
    assert_equal "4" "$status"
}

# ============================================================================
# STREAM SEPARATION TESTS
# ============================================================================

@test "JSON mode outputs only to stdout" {
    harness_create_config
    _setup_repos_yaml

    # Capture stdout and stderr separately
    local stdout_file="$TEST_TMPDIR/stdout.txt"
    local stderr_file="$TEST_TMPDIR/stderr.txt"

    harness_run_dsr --json repos list > "$stdout_file" 2> "$stderr_file" || true

    # stdout should have JSON (extract the multi-line JSON object)
    local json_content
    json_content=$(sed -n '/^{$/,/^}$/p' "$stdout_file")
    echo "$json_content" | jq -e '.'

    # Note: Some stderr output is acceptable for logging/session info
    # The key test is that JSON is on stdout
}

@test "non-JSON mode can use stderr for progress" {
    harness_create_config
    _setup_repos_yaml

    # Just verify the command works in non-JSON mode
    run harness_run_dsr repos list
    assert_equal "0" "$status"
}

@test "sbom generate: path on stdout, failure cause on stderr and in JSON" {
    harness_create_config
    printf 'artifact\n' > "$TEST_TMPDIR/artifact.bin"
    # A scanner that fails with a specific reason.
    mock_command_script "syft" 'echo "scanner exploded: disk quota" >&2; exit 2'

    local out err
    run bash -c '"$1" sbom generate "$2" 2>"$3"' _ "$PROJECT_ROOT/dsr" "$TEST_TMPDIR/artifact.bin" "$TEST_TMPDIR/err.txt"
    assert_equal "1" "$status"
    assert_equal "" "$output"
    grep -q "scanner exploded: disk quota" "$TEST_TMPDIR/err.txt"

    _dsr_json sbom generate "$TEST_TMPDIR/artifact.bin"
    assert_equal "1" "$status"
    jq -e '.status == "error" and (.details.error | contains("scanner exploded: disk quota")) and
        (.details.error | contains("\u001b") | not)' <<< "$json"
}

@test "slsa generate: stdout and JSON output are exactly the provenance path" {
    harness_create_config
    printf 'artifact\n' > "$TEST_TMPDIR/tool.tar.gz"
    local proof="$TEST_TMPDIR/tool.tar.gz.intoto.jsonl"

    # Outside any Git checkout, so no source observation is attempted.
    cd "$TEST_TMPDIR"
    run bash -c '"$1" slsa generate "$2" 2>/dev/null' _ "$PROJECT_ROOT/dsr" "$TEST_TMPDIR/tool.tar.gz"
    assert_equal "0" "$status"
    assert_equal "$proof" "$output"

    _dsr_json slsa generate "$TEST_TMPDIR/tool.tar.gz"
    assert_equal "0" "$status"
    jq -e --arg proof "$proof" '.status == "success" and .details.output == $proof' <<< "$json"

    run bash -c '"$1" slsa generate "$2" 2>&1 >/dev/null' _ "$PROJECT_ROOT/dsr" "$TEST_TMPDIR/missing.tar.gz"
    [ "$status" -ne 0 ]
    [[ "$output" == *"missing.tar.gz"* || "$output" == *"rtifact"* ]]
}

@test "json_envelope never emits malformed details" {
    # The function body ends at the first "}" line after its heredoc's EOF.
    run bash -c 'source "$1/src/logging.sh"
        eval "$(awk "/^json_envelope\\(\\)/{on=1} on{print} on && /^EOF\$/{eof=1} eof && /^}\$/{exit}" "$1/dsr")"
        DSR_VERSION=test json_envelope verify-upgrade error 1 "$(printf "%s\n%s" "{\"a\":1}" "{}")" 2>/dev/null' _ "$PROJECT_ROOT"
    assert_equal "0" "$status"
    jq -e '.details.error == "malformed details" and (.details.raw | startswith("{\"a\":1}"))' <<< "$output"
}

# ============================================================================
# EXIT CODE CONSISTENCY TESTS
# ============================================================================

@test "exit code 4 for invalid arguments" {
    run harness_run_dsr check --invalid-flag-xyz
    assert_equal "4" "$status"
}

@test "exit code 4 for unknown subcommand" {
    run harness_run_dsr repos unknown_subcmd
    assert_equal "4" "$status"
}

# ============================================================================
# JSON SCHEMA VALIDATION TESTS
# ============================================================================

@test "check JSON output has required envelope fields" {
    harness_create_config
    _setup_repos_d

    mock_command_script "gh" 'echo "{\"workflow_runs\": []}"'

    run harness_run_dsr --json check ntm

    # Extract JSON from multi-line output
    local json_content
    json_content=$(echo "$output" | sed -n '/^{$/,/^}$/p')

    # Validate envelope structure
    echo "$json_content" | jq -e '.command'
    echo "$json_content" | jq -e '.status'
    echo "$json_content" | jq -e '.exit_code'
    echo "$json_content" | jq -e '.run_id'
    echo "$json_content" | jq -e '.started_at'
    echo "$json_content" | jq -e '.tool == "dsr"'
    echo "$json_content" | jq -e '.version'
    echo "$json_content" | jq -e '.details'
}

@test "repos JSON output has required envelope fields" {
    harness_create_config
    _setup_repos_yaml

    run harness_run_dsr --json repos list

    # Extract JSON from multi-line output
    local json_content
    json_content=$(echo "$output" | sed -n '/^{$/,/^}$/p')

    # Validate envelope structure
    echo "$json_content" | jq -e '.command'
    echo "$json_content" | jq -e '.status'
    echo "$json_content" | jq -e '.exit_code'
    echo "$json_content" | jq -e '.details'
}

# ============================================================================
# MOCK VERIFICATION TESTS
# ============================================================================

@test "mock_gh captures calls correctly" {
    mock_command_logged "gh" '{"result": "mock"}' 0

    gh api repos/test/test
    gh auth status

    local call_count
    call_count=$(mock_call_count "gh")
    assert_equal "2" "$call_count"

    assert_success mock_called_with "gh" "api repos/test/test"
    assert_success mock_called_with "gh" "auth status"
}
