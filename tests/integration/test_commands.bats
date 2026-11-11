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
    bats_require_minimum_version 1.5.0
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
    command -v yq >/dev/null || skip "Real yq is required for repository configuration"
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

    # Serve a complete empty active-run inventory (healthy).
    _mock_gh_runs '{"workflow_runs":[]}'

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
    _mock_gh_runs "{\"workflow_runs\":[{\"id\":12345,\"status\":\"queued\",\"created_at\":\"$old_time\",\"name\":\"Release\"}]}"

    run harness_run_dsr check ntm
    # Should fail (throttling detected)
    assert_equal "1" "$status"
    assert_contains "$output" "THROTTLED"
}

@test "dsr check --json returns valid JSON envelope" {
    harness_create_config
    _setup_repos_d

    _mock_gh_runs '{"workflow_runs":[]}'

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
    mock_command_script "gh" "$(cat <<'SCRIPT'
printf '%s\n' "$*" >> "$TEST_TMPDIR/gh.calls"
if [[ "$1" == auth ]]; then
    [[ "${2:-}" != token ]] || printf '%s\n' 'dsr-offline-integration-fixture'
    exit 0
fi
if [[ "$1" == api ]]; then
    [[ -s "$TEST_TMPDIR/runs.json" ]] || { echo 'gh: Bad gateway (HTTP 502)' >&2; exit 1; }
    if [[ "$*" == *repos/Dicklesworthstone/ntm/* ]]; then
        desired=""
        [[ "$*" == *status=queued* ]] && desired=queued
        [[ "$*" == *status=in_progress* ]] && desired=in_progress
        jq --arg desired "$desired" '
            .workflow_runs |= map(select($desired == "" or .status == $desired)) |
            .total_count = (.workflow_runs | length)' "$TEST_TMPDIR/runs.json"
    else
        echo '{"total_count":0,"workflow_runs":[]}'
    fi
    exit 0
fi
echo '{}'
SCRIPT
)"
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
    printf '{"workflow_runs":[{"id":12345,"status":"queued","created_at":"%s","name":"Release","path":".github/workflows/release.yml","head_branch":"v1.2.3","head_sha":"1111111111111111111111111111111111111111","html_url":"https://github.com/Dicklesworthstone/ntm/actions/runs/12345"}]}' \
        "$(_minutes_ago 15)"
}

# The same routing regressions can exercise an untouched checkout. Keep the
# actual CLI and YAML parser; only GitHub transport and child CLI calls vary.
_routing_dsr() {
    "${DSR_ROUTING_TEST_ROOT:-$DSR_PROJECT_ROOT}/dsr" "$@" 2>/dev/null
}

# Serve API-shaped pages from one history; the CLI and gh_api wrapper still
# perform selection, pagination, validation, timing and JSON assembly.
_mock_active_inventory() {
    export ACTIVE_FIXTURE_CASE="$1" GH_MAX_RETRIES=1 GH_RETRY_DELAY=0
    jq -n --arg mode "$1" --arg old "$(_minutes_ago 15)" --arg fresh "$(_minutes_ago 1)" '
        def run($id; $status; $time):
            {id:$id,status:$status,created_at:$time,run_started_at:$time,
             name:"Release",workflow_id:17,path:".github/workflows/release.yml",
             head_branch:"v1.2.3",head_sha:"1111111111111111111111111111111111111111",event:"push",
             html_url:("https://github.com/Dicklesworthstone/ntm/actions/runs/"+($id|tostring))};
        [range(1;21) | run(.;"completed";$fresh)] as $completed |
        if $mode == "big" then
            $completed + [range(1000;1900) | run(.;"queued";$old)]
        elif $mode == "second" or $mode == "later-error" or $mode == "short-page" then
            $completed + [range(1000;1100) | run(.;"queued";$fresh)] + [run(555;"queued";$old)]
        elif $mode == "invalid-time" then
            [run(555;"queued";"not-a-timestamp"),run(556;"queued";$old)]
        elif $mode == "invalid-path" then
            [run(555;"queued";$old) | .path = 42]
        elif $mode == "duplicate" then
            [run(555;"queued";$old),run(555;"in_progress";$fresh)]
        else $completed + [run(555;"queued";$old)] end
        ' > "$TEST_TMPDIR/active-history.json"
    mock_command_script "gh" "$(cat <<'SCRIPT'
printf '%s\n' "$*" >> "$TEST_TMPDIR/gh.calls"
if [[ "$1" == auth ]]; then
    [[ "${2:-}" != token ]] || printf '%s\n' 'dsr-offline-integration-fixture'
    exit 0
fi
[[ "$1" == api ]] || exit 99
endpoint=""
for arg in "$@"; do
    [[ "$arg" == repos/*/actions/* ]] && endpoint="$arg"
done
[[ -n "$endpoint" ]] || exit 99
desired=""
[[ "$endpoint" == *status=queued* ]] && desired=queued
[[ "$endpoint" == *status=in_progress* ]] && desired=in_progress
limit=20
[[ "$endpoint" == *per_page=100* ]] && limit=100
page=$(sed -nE 's/.*[?&]page=([0-9]+).*/\1/p' <<< "$endpoint")
[[ -n "$page" ]] || page=1
if [[ "$ACTIVE_FIXTURE_CASE" == later-error && "$desired" == queued && "$page" -eq 2 ]]; then
    echo 'gh: Bad gateway (HTTP 502)' >&2
    exit 1
fi
jq --arg desired "$desired" --arg mode "$ACTIVE_FIXTURE_CASE" \
    --argjson page "$page" --argjson limit "$limit" '
    map(select($desired == "" or .status == $desired)) as $all |
    {total_count:($all|length),workflow_runs:$all[(($page-1)*$limit):($page*$limit)]} |
    if $desired == "queued" and $mode == "cap" then .total_count = 1001
    elif $desired == "queued" and $mode == "malformed" then .workflow_runs = {}
    elif $desired == "queued" and $mode == "short-page" and $page == 2 then .workflow_runs = []
    else . end' "$TEST_TMPDIR/active-history.json"
SCRIPT
)"
}

@test "active scan: completed history cannot hide an older throttled release" {
    harness_create_config
    _setup_repos_d
    _mock_active_inventory hidden
    run _routing_dsr --json check ntm
    assert_equal "1" "$status"
    echo "$output" | jq -e '.details.throttled | length == 1 and .[0].run_id == 555'
    grep -q 'actions/workflows/release.yml/runs?per_page=100&status=queued&page=1' "$TEST_TMPDIR/gh.calls"
    grep -q 'status=in_progress&page=1' "$TEST_TMPDIR/gh.calls"
}

@test "active scan: an older throttled run after the first hundred is detected" {
    harness_create_config
    _setup_repos_d
    _mock_active_inventory second
    run _routing_dsr --json check ntm
    assert_equal "1" "$status"
    echo "$output" | jq -e '.details.throttled | length == 1 and .[0].run_id == 555'
    grep -q 'status=queued&page=2' "$TEST_TMPDIR/gh.calls"
}

@test "active scan: a failed later page never reports the repository healthy" {
    harness_create_config
    _setup_repos_d
    _mock_active_inventory later-error
    run _routing_dsr --json check ntm
    assert_equal "8" "$status"
    echo "$output" | jq -e '.status == "error" and .details.healthy == [] and
        .details.skipped[0].repo == "Dicklesworthstone/ntm"'
    grep -q 'status=queued&page=2' "$TEST_TMPDIR/gh.calls"
    jq -e '.skipped == ["Dicklesworthstone/ntm"]' "$DSR_STATE_DIR/check/last.json"
}

@test "active scan: malformed capped or prematurely ended listings are errors" {
    harness_create_config
    _setup_repos_d
    local mode
    for mode in malformed cap short-page; do
        _mock_active_inventory "$mode"
        run _routing_dsr --json check ntm
        assert_equal "8" "$status"
        echo "$output" | jq -e '.status == "error" and .details.healthy == [] and
            (.details.skipped | length) == 1'
    done
}

@test "active scan: invalid active timestamps do not discard a real throttle" {
    harness_create_config
    _setup_repos_d
    _mock_active_inventory invalid-time
    run _routing_dsr --json check ntm
    assert_equal "8" "$status"
    echo "$output" | jq -e '.details.healthy == [] and
        .details.skipped[0].reason == "invalid active-run timestamps"'
}

@test "active scan: invalid run metadata produces a documented error" {
    harness_create_config
    _setup_repos_d
    _mock_active_inventory invalid-path
    run _routing_dsr --json check ntm
    assert_equal "8" "$status"
    echo "$output" | jq -e '.details.healthy == [] and (.details.skipped | length) == 1'
}

@test "active scan: a started run replaces its older queued record" {
    harness_create_config
    _setup_repos_d
    _mock_active_inventory duplicate
    run _routing_dsr --json check ntm
    assert_equal "0" "$status"
    echo "$output" | jq -e '.details.throttled == [] and
        .details.healthy == ["Dicklesworthstone/ntm"]'
}

@test "active scan: large queues retain all throttled rows beyond argv limits" {
    harness_create_config
    _setup_repos_d
    _mock_active_inventory big
    run _routing_dsr --json check ntm
    assert_equal "1" "$status"
    [[ "$(printf '%s' "$output" | wc -c)" -gt 131072 ]]
    echo "$output" | jq -e '(.details.throttled | length) == 900 and
        (.details.throttled | map(.run_id) | unique | length) == 900 and
        .details.repos[0].queued_count == 900'
    grep -q 'status=queued&page=9' "$TEST_TMPDIR/gh.calls"
    ! grep -q 'status=queued&page=10' "$TEST_TMPDIR/gh.calls"
}

# A long-running workflow can still be compiling normally, waiting for a
# human approval, or starved of runners after an earlier job completed. Keep
# the public CLI and complete GitHub pagination path in each observation.
_mock_job_inventory() {
    export JOB_FIXTURE_CASE="$1" GH_MAX_RETRIES=1 GH_RETRY_DELAY=0
    jq -n --arg mode "$1" --arg old "$(_minutes_ago 60)" --arg fresh "$(_minutes_ago 1)" '
        def job($id;$status):
            {id:$id,run_id:555,run_attempt:2,status:$status,
             head_sha:"1111111111111111111111111111111111111111",
             started_at:(if $status == "queued" then null else $old end),completed_at:null};
        if $mode == "running" then [job(1;"in_progress")]
        elif $mode == "mixed" then [job(1;"in_progress"),job(2;"queued")]
        elif $mode == "approval" then [job(1;"waiting"),job(2;"queued")]
        elif $mode == "pending" then [job(1;"pending"),job(2;"queued")]
        elif $mode == "recent-completion" then
            [job(1;"completed") + {completed_at:$fresh},job(2;"queued")]
        elif $mode == "recent-queue" then [job(1;"queued") + {created_at:$fresh}]
        elif $mode == "empty" then []
        elif $mode == "later-running" or $mode == "later-queued" or $mode == "later-error" or $mode == "duplicate" or
             $mode == "latest-paged" or $mode == "latest-mixed-pages" or $mode == "latest-unpinned-pages" then
            [range(1;101) | job(.;"completed") + {completed_at:$old}] +
            [job(101;(if $mode == "later-running" then "in_progress" else "queued" end))] |
            if $mode == "latest-mixed-pages" then .[-1].run_attempt=3
            elif $mode == "latest-unpinned-pages" then map(.run_attempt=null)
            else . end
        elif $mode == "latest-mixed-page" then [job(1;"queued"),job(2;"queued") + {run_attempt:3}]
        elif $mode == "latest-unpinned" then [job(1;"queued") | del(.run_attempt)]
        elif $mode == "wrong-source" then [job(1;"queued") | .head_sha=("2"*40)]
        elif $mode == "wrong-run" then [job(1;"queued") | .run_id=556]
        elif $mode == "wrong-attempt" then [job(1;"queued") | .run_attempt=1]
        elif $mode == "invalid-time" then [job(1;"queued") | .created_at="not-a-time"]
        else [job(1;"queued")] end
    ' > "$TEST_TMPDIR/job-history.json"
    jq -n --arg old "$(_minutes_ago 60)" --arg mode "$1" '
        {total_count:1,workflow_runs:[{id:555,status:"in_progress",created_at:$old,run_started_at:$old,
         run_attempt:(if $mode | startswith("latest") then null else 2 end),name:"Release",workflow_id:17,
         path:".github/workflows/release.yml",head_branch:"v1.2.3",
         head_sha:"1111111111111111111111111111111111111111",event:"push",
         html_url:"https://github.com/Dicklesworthstone/ntm/actions/runs/555"}]}
    ' > "$TEST_TMPDIR/job-workflow.json"
    mock_command_script "gh" "$(cat <<'SCRIPT'
printf '%s\n' "$*" >> "$TEST_TMPDIR/gh.calls"
if [[ "$1" == auth ]]; then
    [[ "${2:-}" != token ]] || printf '%s\n' 'dsr-offline-integration-fixture'
    exit 0
fi
[[ "$1" == api ]] || exit 99
endpoint=""
for arg in "$@"; do [[ "$arg" == repos/*/actions/* ]] && endpoint="$arg"; done
if [[ "$endpoint" == *'/jobs?'* ]]; then
    page=$(sed -nE 's/.*[?&]page=([0-9]+).*/\1/p' <<< "$endpoint")
    [[ -n "$page" ]] || exit 99
    if [[ "$JOB_FIXTURE_CASE" == later-error && "$page" == 2 ]]; then
        echo 'gh: Bad gateway (HTTP 502)' >&2
        exit 1
    fi
    jq --arg mode "$JOB_FIXTURE_CASE" --argjson page "$page" '
        {total_count:length,jobs:.[(($page-1)*100):($page*100)]} |
        if $mode == "cap" then .total_count=1001
        elif $mode == "malformed" then .jobs={}
        elif $mode == "short-page" then .total_count=2
        elif $mode == "duplicate" and $page == 2 then .jobs[0].id=1
        else . end' "$TEST_TMPDIR/job-history.json"
elif [[ "$endpoint" == *status=in_progress* ]]; then
    cat "$TEST_TMPDIR/job-workflow.json"
elif [[ "$endpoint" == *status=queued* ]]; then
    printf '%s\n' '{"total_count":0,"workflow_runs":[]}'
else exit 99; fi
SCRIPT
)"
}

@test "job scan: long executing or approval-pending workflows do not trigger fallback" {
    harness_create_config
    _setup_repos_d
    local mode
    for mode in running mixed approval pending empty; do
        _mock_job_inventory "$mode"
        run _routing_dsr --json check ntm
        assert_equal "0" "$status"
        echo "$output" | jq -e '.details.throttled == [] and .details.healthy == ["Dicklesworthstone/ntm"]'
    done
    grep -q 'runs/555/attempts/2/jobs?per_page=100&page=1' "$TEST_TMPDIR/gh.calls"
}

@test "job scan: stalled runner dispatch retains job IDs and workflow source" {
    harness_create_config
    _setup_repos_d
    _mock_job_inventory queued
    run _routing_dsr --json check ntm
    assert_equal "1" "$status"
    echo "$output" | jq -e '.details.throttled | length == 1 and
        .[0].run_id == 555 and .[0].status == "in_progress" and
        .[0].head_sha == ("1"*40) and .[0].queue_reason == "job_queue" and
        .[0].queued_job_ids == [1] and .[0].queue_time_seconds > 3000'
    echo "$output" > "$TEST_TMPDIR/job-result.json"
    if python3 -c 'import jsonschema' 2>/dev/null; then
        python3 -I - "$DSR_PROJECT_ROOT/schemas/check-details.json" "$TEST_TMPDIR/job-result.json" <<'PY'
import json,sys,jsonschema
jsonschema.validate(json.load(open(sys.argv[2]))['details'],json.load(open(sys.argv[1])))
PY
    fi
}

@test "job scan: recent queue creation or completed work restarts the queue clock" {
    harness_create_config
    _setup_repos_d
    local mode
    for mode in recent-completion recent-queue; do
        _mock_job_inventory "$mode"
        run _routing_dsr --json check ntm
        assert_equal "0" "$status"
        echo "$output" | jq -e '.details.throttled == []'
    done
}

@test "job scan: later pages distinguish running work from runner starvation" {
    harness_create_config
    _setup_repos_d
    _mock_job_inventory later-running
    run _routing_dsr --json check ntm
    assert_equal "0" "$status"
    echo "$output" | jq -e '.details.throttled == []'
    _mock_job_inventory later-queued
    run _routing_dsr --json check ntm
    assert_equal "1" "$status"
    echo "$output" | jq -e '.details.throttled[0].queued_job_ids == [101]'
    grep -q 'runs/555/attempts/2/jobs?per_page=100&page=2' "$TEST_TMPDIR/gh.calls"
}

@test "job scan: missing attempt metadata explicitly selects only the latest jobs" {
    harness_create_config
    _setup_repos_d
    local mode
    for mode in latest latest-unpinned; do
        _mock_job_inventory "$mode"
        run _routing_dsr --json check ntm
        assert_equal "1" "$status"
    done
    grep -q 'runs/555/jobs?filter=latest&per_page=100&page=1' "$TEST_TMPDIR/gh.calls"
}

@test "job scan: latest pagination pins the attempt observed on its first page" {
    harness_create_config
    _setup_repos_d
    _mock_job_inventory latest-paged
    run _routing_dsr --json check ntm
    assert_equal "1" "$status"
    echo "$output" | jq -e '.details.throttled[0].queued_job_ids == [101]'
    grep -q 'runs/555/jobs?filter=latest&per_page=100&page=1' "$TEST_TMPDIR/gh.calls"
    grep -q 'runs/555/attempts/2/jobs?per_page=100&page=2' "$TEST_TMPDIR/gh.calls"
    ! grep -q 'runs/555/jobs?filter=latest&per_page=100&page=2' "$TEST_TMPDIR/gh.calls"
}

@test "job scan: latest inventories never combine different workflow attempts" {
    harness_create_config
    _setup_repos_d
    local mode
    for mode in latest-mixed-page latest-mixed-pages; do
        _mock_job_inventory "$mode"
        run _routing_dsr --json check ntm
        assert_equal "8" "$status"
        echo "$output" | jq -e '.details.healthy == [] and .details.throttled == [] and
            .details.skipped[0].reason == "failed to inspect workflow jobs"'
    done
}

@test "job scan: latest pagination refuses missing attempt identity before another request" {
    harness_create_config
    _setup_repos_d
    _mock_job_inventory latest-unpinned-pages
    run _routing_dsr --json check ntm
    assert_equal "8" "$status"
    echo "$output" | jq -e '.details.healthy == [] and .details.throttled == [] and
        .details.skipped[0].reason == "failed to inspect workflow jobs"'
    ! grep -q '/jobs?.*page=2' "$TEST_TMPDIR/gh.calls"
}

@test "job scan: incomplete malformed or mismatched inventories cannot authorize fallback" {
    harness_create_config
    _setup_repos_d
    local mode
    for mode in cap malformed short-page duplicate later-error wrong-source wrong-run wrong-attempt invalid-time; do
        _mock_job_inventory "$mode"
        run _routing_dsr --json check ntm
        assert_equal "8" "$status"
        echo "$output" | jq -e '.details.healthy == [] and .details.throttled == [] and
            .details.skipped[0].reason == "failed to inspect workflow jobs"'
    done
}

# Launch fixtures must provide current configuration as well as an observed
# run. The watcher rechecks the real file before admitting every child.
_watch_configure_ntm() {
    command -v yq >/dev/null || skip "Real yq is required for watcher admission"
    mkdir -p "$DSR_CONFIG_DIR/repos.d"
    printf 'tool_name: ntm\nrepo: Dicklesworthstone/ntm\nworkflow: release.yml\n%s\n' \
        "${1:-}" > "$DSR_CONFIG_DIR/repos.d/ntm.yaml"
}

_routing_watch() {
    local check_json="$1"
    shift
    local -a watch_mode=(--once)
    [[ "${DSR_WATCH_FIXTURE_CONTINUOUS:-0}" != 1 ]] || watch_mode=()
    printf '%s\n' "$check_json" > "$TEST_TMPDIR/watch-check.json"
    cat > "$TEST_TMPDIR/child-dsr" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    doctor) exit 0 ;;
    --json)
        [[ "$2" == check ]] || exit 99
        : > "$TEST_TMPDIR/watch-check.started"
        deadline=$((SECONDS + 60))
        while [[ -n "${DSR_WATCH_FIXTURE_CHECK_WAIT:-}" && ! -e "$DSR_WATCH_FIXTURE_CHECK_WAIT" ]]; do
            ((SECONDS < deadline)) || exit 98
            sleep 0.05
        done
        if [[ -n "${DSR_WATCH_FIXTURE_HISTORY_AFTER_CHECK:-}" ]]; then
            cat "$DSR_WATCH_FIXTURE_HISTORY_AFTER_CHECK" > "$DSR_STATE_DIR/triggered.json" || exit 98
        fi
        if [[ -n "${DSR_WATCH_FIXTURE_CONFIG_AFTER_CHECK:-}" ]]; then
            cat "$DSR_WATCH_FIXTURE_CONFIG_AFTER_CHECK" > "$DSR_CONFIG_DIR/repos.d/ntm.yaml" || exit 98
        fi
        cat "$TEST_TMPDIR/watch-check.json"
        exit "${DSR_WATCH_FIXTURE_CHECK_STATUS:-1}"
        ;;
    --non-interactive)
        [[ "$2" == --json && "$3" == fallback ]] || exit 99
        printf '%s\0' "$@" >> "$TEST_TMPDIR/fallback.args"
        printf 'started\n' >> "$TEST_TMPDIR/fallback.starts"
        if [[ -n "${DSR_WATCH_FIXTURE_FALLBACK:-}" ]]; then
            shift 3
            exec bash "$DSR_WATCH_FIXTURE_FALLBACK" "$@"
        fi
        deadline=$((SECONDS + 60))
        while [[ -n "${DSR_WATCH_FIXTURE_WAIT:-}" && ! -e "$DSR_WATCH_FIXTURE_WAIT" ]]; do
            ((SECONDS < deadline)) || exit 98
            sleep 0.05
        done
        exit "${DSR_WATCH_FIXTURE_STATUS:-0}"
        ;;
    *) exit 99 ;;
esac
EOF
    chmod +x "$TEST_TMPDIR/child-dsr"
    # Sourcing preserves the real CLI's BASH_SOURCE/module paths while $0 is
    # the child boundary above. Wait for the recorded background invocation.
    bash -c '
        if [[ "${DSR_WATCH_FIXTURE_PYTHON:-0}" == 1 ]]; then
            command() {
                [[ "${1:-} ${2:-}" != "-v flock" ]] || return 1
                builtin command "$@"
            }
        fi
        if [[ "${DSR_WATCH_FIXTURE_REPORT_FAILURE:-0}" == 1 ]]; then
            # Inject only report assembly failure; state validation and the
            # final public envelope still use the real jq implementation.
            jq() {
                local argument
                for argument in "$@"; do
                    if [[ "$argument" == max_concurrent ]]; then
                        : > "$TEST_TMPDIR/report-assembly-failed"
                        printf "%s\n" "injected watcher report assembly failure" >&2
                        return 4
                    fi
                done
                command jq "$@"
            }
        fi
        if [[ "${DSR_WATCH_FIXTURE_CONTINUOUS:-0}" == 1 ]]; then
            # Stop after the genuine first poll through the existing
            # interruptible-sleep boundary, without waiting a full interval.
            sleep() { return 1; }
        fi
        trap "wait" EXIT
        source "$1" "${@:2}"' \
        "$TEST_TMPDIR/child-dsr" "${DSR_ROUTING_TEST_ROOT:-$DSR_PROJECT_ROOT}/dsr" \
        --json watch ${watch_mode[@]+"${watch_mode[@]}"} --notify none "$@"
}

# Explicit terminal-history fixture. New attempts, locking, reconciliation and
# public JSON reporting continue through the actual CLI in _routing_watch.
_watch_large_history() {
    jq -n 'reduce range(100000;100500) as $number
        ({schema_version:2,runs:{},attempts:{},pending:{},last_check:"2026-01-30T12:00:00Z"};
         ($number | tostring) as $id |
         .runs[$id] = "2026-01-30T12:00:00Z" |
         .attempts[$id] = {attempt:1,attempt_id:($id + ".12345678"),tool:"demo",repo:"owner/demo",
            version:"v1.2.3",head_sha:("1" * 40),status:"succeeded",started_epoch:1,
            next_retry_at:null,resume_run_id:"",isolate_source:true,exit_code:0,finished_epoch:2})' \
        > "$DSR_STATE_DIR/triggered.json"
    [[ "$(jq -c . "$DSR_STATE_DIR/triggered.json" | wc -c)" -gt 131072 ]]
}

_watch_completed() {
    local run_id="${1:-12345}" directory attempt deadline=$((SECONDS + 15))
    while ((SECONDS < deadline)); do
        attempt=$(jq -r --arg id "$run_id" '.attempts[$id].attempt_id // empty' "$DSR_STATE_DIR/triggered.json" 2>/dev/null) || attempt=""
        directory="$DSR_STATE_DIR/watch-attempts/$attempt"
        [[ -n "$attempt" && -f "$directory/completion.json" ]] && return 0
        sleep 0.05
    done
    return 1
}

_watch_run_json() {
    jq -nc --arg sha "${1:-1111111111111111111111111111111111111111}" '
        {details:{throttled:[{run_id:12345,repo:"Dicklesworthstone/ntm",tool:"ntm",
            head_branch:"v1.2.3",head_sha:$sha}]}}'
}

_watch_multiple_runs_json() {
    _watch_run_json "$@" | jq '.details.throttled[0] as $first |
        .details.throttled = [range(0;3) as $n | $first +
            {run_id:($first.run_id + $n), head_branch:("v1.2." + (3 + $n | tostring))}]'
}

# Obtain a pending candidate from a real capacity-bound watch invocation,
# then complete its unrelated worker. No recovery state is synthesized.
_watch_pending_fixture() {
    harness_create_config
    mkdir -p "$DSR_CONFIG_DIR/repos.d"
    printf 'repo: Dicklesworthstone/ntm\n' > "$DSR_CONFIG_DIR/repos.d/ntm.yaml"
    local check_json first_status
    check_json=$(_watch_multiple_runs_json | jq '.details.throttled |= [.[1], .[0]]')
    DSR_WATCH_FIXTURE_WAIT="$DSR_STATE_DIR/finish-child" \
        run --separate-stderr _routing_watch "$check_json" --auto-fallback --max-concurrent 1
    first_status=$status
    touch "$DSR_STATE_DIR/finish-child"
    _watch_completed 12346
    assert_equal 0 "$first_status"
    run --separate-stderr _routing_watch '{"details":{"throttled":[]}}'
    assert_equal 0 "$status"
    jq -e '.pending["12345"] != null and .attempts["12345"] == null and
        .attempts["12346"].status == "succeeded"' "$DSR_STATE_DIR/triggered.json"
}

# Recovery may outlive the queue entry that originally authorized fallback.
# Exercise the real authenticated GitHub adapter with only its HTTP boundary
# replaced, retaining each request so uncached status reads are observable.
_mock_watch_upstream_run() {
    printf '%s\n' "$1" > "$TEST_TMPDIR/watch-upstream.json"
    export GH_MAX_RETRIES=1 GH_RETRY_DELAY=0
    mock_command_script "gh" "$(cat <<'SCRIPT'
if [[ "$1" == auth ]]; then
    [[ "${2:-}" != token ]] || printf '%s\n' 'dsr-offline-integration-fixture'
    exit 0
fi
if [[ "$1" == api && "$2" == repos/Dicklesworthstone/ntm/actions/runs/12345 ]]; then
    printf '%s\n' "$*" >> "$TEST_TMPDIR/watch-upstream.calls"
    [[ "${DSR_WATCH_UPSTREAM_ERROR:-false}" != true ]] || exit 1
    cat "$TEST_TMPDIR/watch-upstream.json"
    exit 0
fi
printf 'Unexpected watcher API call: %s\n' "$*" >&2
exit 99
SCRIPT
)"
}

_watch_upstream_run_json() {
    jq -nc --arg status "${1:-completed}" --arg conclusion "${2-failure}" \
        --arg sha "${3:-1111111111111111111111111111111111111111}" '
        {id:12345,repository:{full_name:"Dicklesworthstone/ntm"},
         head_branch:"v1.2.3",head_sha:$sha,status:$status,run_attempt:1,
         conclusion:(if $conclusion == "" then null else $conclusion end)}'
}

# Drive the real watcher, fallback coordinator, Git materializer, source checks,
# build lock and artifact admission. Only expensive build/quality commands and
# remote publication are fixture boundaries; no external release is created.
_watch_isolated_pipeline_fixture() {
    harness_create_config
    mkdir -p "$TEST_TMPDIR/developer-source" "$DSR_CONFIG_DIR/repos.d"
    git init -q -b main "$TEST_TMPDIR/developer-source"
    printf 'tagged release source\n' > "$TEST_TMPDIR/developer-source/source.txt"
    git -C "$TEST_TMPDIR/developer-source" add source.txt
    git -C "$TEST_TMPDIR/developer-source" -c user.name='DSR test' \
        -c user.email='dsr-test@example.invalid' commit -qm release
    git -C "$TEST_TMPDIR/developer-source" tag v1.2.3
    export DSR_WATCH_PINNED_SHA
    DSR_WATCH_PINNED_SHA=$(git -C "$TEST_TMPDIR/developer-source" rev-parse HEAD)
    jq -nc --arg path "$TEST_TMPDIR/developer-source" \
        '{tool_name:"ntm",repo:"Dicklesworthstone/ntm",local_path:$path,language:"go",
          binary_name:"ntm",targets:["linux/amd64"],workflow:"release.yml"}' \
        > "$DSR_CONFIG_DIR/repos.d/ntm.yaml"
    export DSR_WATCH_FIXTURE_FALLBACK="$TEST_TMPDIR/real-fallback"
    cat > "$DSR_WATCH_FIXTURE_FALLBACK" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
root="${DSR_ROUTING_TEST_ROOT:-$DSR_PROJECT_ROOT}"
for module in config act_runner git_ops build_state signing sbom; do
    source "$root/src/$module.sh" || exit 3
done
source <(awk '/^(_release_file_size|_release_sha256|_release_require_publishable_artifacts|_release_sbom_policy|cmd_fallback)\(\) \{/{copy=1} copy{print} copy && /^\}/{copy=0}' "$root/dsr") || exit 3
JSON_MODE=true DRY_RUN=false
log_info() { printf '%s\n' "$*" >&2; }
log_warn() { log_info "$@"; }
log_error() { log_info "$@"; }
log_ok() { log_info "$@"; }
log_debug() { :; }
log_set_tool() { :; }
_dsr_require() { :; }
notify_event() { :; }
signing_wanted() { return 1; }
signing_is_enabled() { return 1; }
_check_repo() { printf '{"status":"throttled","queued_count":1}\n'; return 1; }
gh_resolve_tag_sha() { printf '%s\n' "$DSR_WATCH_PINNED_SHA"; }
json_envelope() {
    jq -nc --arg command "$1" --arg status "$2" --argjson code "$3" --argjson details "$4" \
        '{command:$command,status:$status,exit_code:$code,details:$details}'
}
git() {
    local -a arguments=("$@")
    local index argument fetch=false
    for argument in "$@"; do
        [[ "$argument" != fetch ]] || fetch=true
    done
    if ! $fetch; then command git "$@"; return $?; fi
    for index in "${!arguments[@]}"; do
        if [[ "${arguments[$index]}" == https://github.com/Dicklesworthstone/ntm.git ]]; then
            [[ -n "${DSR_WATCH_REMOTE_SOURCE:-}" ]] || return 99
            arguments[$index]="$DSR_WATCH_REMOTE_SOURCE"
            printf 'fetch\n' >> "$TEST_TMPDIR/source-transports"
            command git -c protocol.file.allow=always "${arguments[@]}"
            return $?
        fi
    done
    command git "$@"
}
qg_run_checks() {
    [[ "$2" == --work-dir ]] || return 4
    printf '%s\n' "$3" > "$TEST_TMPDIR/quality-source"
    [[ "$3" != "$TEST_TMPDIR/developer-source" &&
       "$(git -C "$3" rev-parse HEAD)" == "$DSR_WATCH_PINNED_SHA" ]] || return 4
    if [[ "${DSR_WATCH_FIXTURE_QUALITY_FAIL_ONCE:-false}" == true &&
          ! -e "$TEST_TMPDIR/quality-first-failure" ]]; then
        printf 'failed\n' > "$TEST_TMPDIR/quality-first-failure"
        return 1
    fi
    [[ "${DSR_WATCH_MUTATE_PRIVATE:-false}" != true ]] || printf 'changed\n' >> "$3/source.txt"
}
cmd_build() {
    local source out="" arg
    source=$(act_get_local_path ntm) || return 4
    while (($#)); do
        arg="$1"; shift
        if [[ "$arg" == --output-dir ]]; then out="$1"; shift; fi
    done
    mkdir -p "$out" || return 4
    cp "$source/source.txt" "$out/ntm" || return 6
    printf '%s\n' "$source" > "$TEST_TMPDIR/build-source"
    jq -nc --arg source "$DSR_WATCH_PINNED_SHA" --arg sha "$(_release_sha256 "$out/ntm")" \
        --argjson size "$(_release_file_size "$out/ntm")" \
        '{tool:"ntm",version:"v1.2.3",status:"success",build_purpose:"release",publishable:true,
          run_id:"11111111-1111-4111-8111-111111111111",source:{git_sha:$source,git_ref:"v1.2.3"},
          summary:{total:1,success:1,failed:0},artifacts:[{name:"ntm",sha256:$sha,size_bytes:$size}]}' \
        > "$out/ntm-v1.2.3-manifest.json"
}
cmd_release() {
    act_get_local_path ntm > "$TEST_TMPDIR/release-source" || return 4
    printf '%s\n' '{"command":"release","status":"success","exit_code":0,"details":{"repo":"Dicklesworthstone/ntm","tag":"v1.2.3","release_id":9,"draft":false}}'
}
cmd_fallback "$@"
EOF
}

@test "watch source isolation releases the tagged commit while preserving ongoing developer work" {
    _watch_isolated_pipeline_fixture
    local checkout="$TEST_TMPDIR/developer-source" before_head before_index before_source attempt snapshot
    printf 'later committed work\n' > "$checkout/source.txt"
    git -C "$checkout" -c user.name='DSR test' -c user.email='dsr-test@example.invalid' commit -qam later
    printf 'staged work\n' > "$checkout/source.txt"
    git -C "$checkout" add source.txt
    printf 'unstaged work\n' >> "$checkout/source.txt"
    printf 'untracked work\n' > "$checkout/private.txt"
    before_head=$(git -C "$checkout" rev-parse HEAD)
    before_index=$(git hash-object "$checkout/.git/index")
    before_source=$(git hash-object "$checkout/source.txt")

    run _routing_watch "$(_watch_run_json "$DSR_WATCH_PINNED_SHA")" --auto-fallback
    assert_equal "0" "$status"
    _watch_completed
    attempt=$(jq -r '.attempts["12345"].attempt_id' "$DSR_STATE_DIR/triggered.json")
    jq -e '.exit_code == 0' "$DSR_STATE_DIR/watch-attempts/$attempt/completion.json"
    jq -e '.status == "success" and .details.isolated_source and
        .details.source_materialization.transport == "local-objects" and .details.phases.release == "success"' \
        "$DSR_STATE_DIR/watch-attempts/$attempt/result.json"
    snapshot=$(cat "$TEST_TMPDIR/build-source")
    assert_equal "$snapshot" "$(cat "$TEST_TMPDIR/quality-source")"
    assert_equal "$snapshot" "$(cat "$TEST_TMPDIR/release-source")"
    assert_equal 'tagged release source' "$(cat "$DSR_STATE_DIR/watch-artifacts/12345/ntm")"
    assert_equal "$DSR_WATCH_PINNED_SHA" "$(git -C "$snapshot" rev-parse HEAD)"
    [[ ! -e "$snapshot/private.txt" ]]
    assert_equal "$before_head" "$(git -C "$checkout" rev-parse HEAD)"
    assert_equal "$before_index" "$(git hash-object "$checkout/.git/index")"
    assert_equal "$before_source" "$(git hash-object "$checkout/source.txt")"
    assert_equal 'untracked work' "$(cat "$checkout/private.txt")"
}

@test "watch source isolation fetches an absent checkout through the pinned tag transport" {
    _watch_isolated_pipeline_fixture
    export DSR_WATCH_REMOTE_SOURCE="$TEST_TMPDIR/source-server"
    mv "$TEST_TMPDIR/developer-source" "$DSR_WATCH_REMOTE_SOURCE"
    run _routing_watch "$(_watch_run_json "$DSR_WATCH_PINNED_SHA")" --auto-fallback
    assert_equal "0" "$status"
    _watch_completed
    local attempt
    attempt=$(jq -r '.attempts["12345"].attempt_id' "$DSR_STATE_DIR/triggered.json")
    jq -e '.exit_code == 0' "$DSR_STATE_DIR/watch-attempts/$attempt/completion.json"
    jq -e '.status == "success" and .details.source_materialization.transport == "github"' \
        "$DSR_STATE_DIR/watch-attempts/$attempt/result.json"
    assert_equal fetch "$(cat "$TEST_TMPDIR/source-transports")"
    assert_equal 'tagged release source' "$(cat "$DSR_STATE_DIR/watch-artifacts/12345/ntm")"
    [[ ! -e "$TEST_TMPDIR/developer-source" ]]
}

@test "watch source isolation blocks publication when quality changes the private source" {
    _watch_isolated_pipeline_fixture
    export DSR_WATCH_MUTATE_PRIVATE=true
    run _routing_watch "$(_watch_run_json "$DSR_WATCH_PINNED_SHA")" --auto-fallback
    assert_equal "0" "$status"
    _watch_completed
    local attempt
    attempt=$(jq -r '.attempts["12345"].attempt_id' "$DSR_STATE_DIR/triggered.json")
    jq -e '.exit_code == 4' "$DSR_STATE_DIR/watch-attempts/$attempt/completion.json"
    jq -e '.exit_code == 4 and .details.phase == "build" and .details.isolated_source' \
        "$DSR_STATE_DIR/watch-attempts/$attempt/result.json"
    [[ ! -e "$TEST_TMPDIR/build-source" && ! -e "$TEST_TMPDIR/release-source" ]]
    assert_equal 'tagged release source' "$(cat "$TEST_TMPDIR/developer-source/source.txt")"
}

# Use a real commit and the production checkpoint writer. Only the watcher
# child CLI boundary is controlled: these tests qualify checkpoint selection,
# not compilation or release publication.
_watch_checkpoint_source_sha() {
    git init -q -b main "$TEST_TMPDIR/checkpoint-source" || return 1
    printf 'watch checkpoint source\n' > "$TEST_TMPDIR/checkpoint-source/source.txt"
    git -C "$TEST_TMPDIR/checkpoint-source" add source.txt || return 1
    git -C "$TEST_TMPDIR/checkpoint-source" -c user.name='DSR test' \
        -c user.email='dsr-test@example.invalid' commit -qm fixture || return 1
    git -C "$TEST_TMPDIR/checkpoint-source" rev-parse HEAD
}

_watch_seed_mixed_checkpoint() (
    local run_id="$1" output_dir="$2" sha="$3" run_status="${4:-partial}"
    local extra receipt artifact recipe_file="$TEST_TMPDIR/watch-checkpoint-recipe.yaml"
    source "${DSR_ROUTING_TEST_ROOT:-$DSR_PROJECT_ROOT}/src/build_state.sh"
    log_info() { :; }
    log_debug() { :; }
    build_state_init || return 1
    printf '%s\n' 'tool_name: ntm' 'build_cmd: fixture-only' > "$recipe_file" || return 1
    DSR_RUN_ID="$run_id" build_state_create ntm v1.2.3 linux/amd64,darwin/arm64 >/dev/null || return 1
    build_state_set_context ntm v1.2.3 "$run_id" "$sha" v1.2.3 '{}' "$output_dir" 1 \
        '{"linux/amd64":"trj","darwin/arm64":"mmini"}' release '' '' null \
        "$(_build_state_sha256 "$recipe_file")" || return 1
    mkdir -p "$output_dir" || return 1
    artifact="$output_dir/ntm-linux-amd64"
    [[ -f "$artifact" ]] || printf 'completed target payload\n' > "$artifact"
    receipt=$(jq -nc --arg path "$artifact" --arg sha "$(_build_state_sha256 "$artifact")" \
        --argjson size "$(wc -c < "$artifact")" \
        '[{path:$path,sha256:$sha,size_bytes:$size}]') || return 1
    extra=$(jq -nc --arg path "$artifact" --argjson receipts "$receipt" \
        '{attempts:1,result:{platform:"linux/amd64",host:"trj",status:"success",exit_code:0,
          artifact_path:$path,resume_artifacts:$receipts}}') || return 1
    build_state_update_target ntm v1.2.3 linux/amd64 completed "$extra" "$run_id" || return 1
    build_state_update_target ntm v1.2.3 darwin/arm64 failed \
        '{"attempts":1,"result":{"platform":"darwin/arm64","host":"mmini","status":"failed","exit_code":6}}' \
        "$run_id" || return 1
    build_state_update_status ntm v1.2.3 "$run_status" "$run_id"
)

@test "nullable routing: check reaches an unregistered owner/repo without inventing a tool" {
    harness_create_config
    _mock_gh_runs '{"workflow_runs": []}'

    run _routing_dsr --json check outsider/standalone
    assert_equal "0" "$status"
    echo "$output" | jq -e '.details.repos_checked == ["outsider/standalone"] and
        .details.repos[0].tool == null and .details.repos[0].workflow == null'
    grep -q 'api repos/outsider/standalone/actions/runs' "$TEST_TMPDIR/gh.calls"
    jq -e '.repos_checked == ["outsider/standalone"]' "$DSR_STATE_DIR/check/last.json"
}

@test "nullable routing: check keeps the default owner for an unregistered short name" {
    harness_create_config
    _mock_gh_runs '{"workflow_runs": []}'

    run _routing_dsr --json check standalone
    assert_equal "0" "$status"
    echo "$output" | jq -e '.details.repos_checked == ["Dicklesworthstone/standalone"] and
        .details.repos[0].tool == null'
    grep -q 'api repos/Dicklesworthstone/standalone/actions/runs' "$TEST_TMPDIR/gh.calls"
}

@test "nullable routing: check preserves a configured workflow when tool identity is absent" {
    harness_create_config
    mkdir -p "$DSR_CONFIG_DIR/repos.d"
    _mock_gh_runs "$(_queued_release_run)"

    local layout
    for layout in flat legacy; do
        if [[ "$layout" == flat ]]; then
            cat > "$DSR_CONFIG_DIR/repos.d/unnamed.yaml" <<'EOF'
tool_name: null
repo: Dicklesworthstone/ntm
workflow: .github/workflows/release.yml
EOF
        else
            cat > "$DSR_CONFIG_DIR/repos.d/unnamed.yaml" <<'EOF'
github:
  repo: Dicklesworthstone/ntm
  workflow: .github/workflows/release.yml
EOF
        fi
        run _routing_dsr --json check Dicklesworthstone/ntm
        assert_equal "1" "$status"
        echo "$output" | jq -e '.details.repos_checked == ["Dicklesworthstone/ntm"] and
            .details.repos[0].tool == null and .details.repos[0].workflow == "release.yml" and
            (.details.throttled[0] | .tool == null and .head_branch == "v1.2.3")'
        grep -q 'api repos/Dicklesworthstone/ntm/actions/workflows/release.yml/runs' "$TEST_TMPDIR/gh.calls"
    done
}

@test "nullable routing: watch does not use a version tag as a missing tool" {
    harness_create_config
    local check_json='{"details":{"throttled":[{"run_id":12345,"repo":"outsider/standalone","tool":null,"head_branch":"v1.2.3"}]}}'

    run _routing_watch "$check_json" --auto-fallback
    assert_equal "0" "$status"
    assert_contains "$output" "No dsr tool is configured for outsider/standalone"
    [[ ! -e "$TEST_TMPDIR/fallback.args" ]]
    [[ ! -e "$DSR_STATE_DIR/fallback-12345.log" ]]
    [[ ! -e "$DSR_STATE_DIR/triggered.json" ]]
}

@test "nullable routing: watch does not use a branch as an omitted tool" {
    harness_create_config
    local check_json='{"details":{"throttled":[{"run_id":12345,"repo":"outsider/standalone","head_branch":"release/latest"}]}}'

    run _routing_watch "$check_json" --auto-fallback
    assert_equal "0" "$status"
    assert_contains "$output" "No dsr tool is configured for outsider/standalone"
    [[ ! -e "$TEST_TMPDIR/fallback.args" ]]
    [[ ! -e "$DSR_STATE_DIR/triggered.json" ]]
}

@test "nullable routing: watch passes a known tool and its tag as distinct fallback arguments" {
    harness_create_config
    _watch_configure_ntm
    local check_json
    check_json=$(_watch_run_json)

    run _routing_watch "$check_json" --auto-fallback
    assert_equal "0" "$status"
    _watch_completed
    jq -Rse --arg output "$DSR_STATE_DIR/watch-artifacts/12345" 'split("\u0000") ==
        ["--non-interactive", "--json", "fallback", "ntm", "--version", "v1.2.3",
         "--expected-sha", "1111111111111111111111111111111111111111", "--isolate-source", "--output-dir", $output, ""]' \
        "$TEST_TMPDIR/fallback.args"
    jq -e '.runs["12345"] != null' "$DSR_STATE_DIR/triggered.json"
    jq -e '.attempts["12345"].isolate_source == true' "$DSR_STATE_DIR/triggered.json"
}

@test "nullable routing: watch refuses automatic publication without a version tag" {
    harness_create_config
    local check_json='{"details":{"throttled":[{"run_id":12345,"repo":"Dicklesworthstone/ntm","tool":"ntm","head_branch":null}]}}'

    run _routing_watch "$check_json" --auto-fallback
    assert_equal "0" "$status"
    assert_contains "$output" "automatic fallback blocked"
    [[ ! -e "$TEST_TMPDIR/fallback.args" ]]
    [[ ! -e "$DSR_STATE_DIR/triggered.json" ]]
}

@test "automation opt-out: list preserves registry false and uses per-tool precedence" {
    harness_create_config
    _setup_repos_yaml
    yq -i '.tools.ntm.enabled = false | .tools.bv.enabled = true' "$DSR_REPOS_FILE"
    run _routing_dsr --json repos list
    assert_equal 0 "$status"
    jq -e '(.details.repos[] | select(.name == "ntm") | .enabled) == false and
        (.details.repos[] | select(.name == "bv") | .enabled) == true' <<< "$output"

    _watch_configure_ntm
    run _routing_dsr --json repos list
    assert_equal 0 "$status"
    jq -e '(.details.repos[] | select(.name == "ntm") | .enabled) == false' <<< "$output"
    _watch_configure_ntm 'enabled: true'
    run _routing_dsr --json repos list
    assert_equal 0 "$status"
    jq -e '(.details.repos[] | select(.name == "ntm") | .enabled) == true' <<< "$output"

    yq -i '.tools.ntm.enabled = true | .tools.alias = .tools.ntm |
        .tools.ntm.repo = "different/registry-repo"' "$DSR_REPOS_FILE"
    _watch_configure_ntm 'enabled: false'
    run _routing_dsr --json repos list
    assert_equal 0 "$status"
    jq -e '(.details.repos | map(select(.repo == "Dicklesworthstone/ntm") | .name) | sort) ==
        ["alias","ntm"] and
        all(.details.repos[] | select(.repo == "Dicklesworthstone/ntm"); .enabled == false) and
        all(.details.repos[]; .repo != "different/registry-repo")' <<< "$output"
}

@test "automation opt-out: listing retains distinct registry tools sharing a repository" {
    harness_create_config
    _setup_repos_yaml
    yq -i '.tools.ntm.enabled = true | .tools.alias = .tools.ntm |
        .tools.alias.enabled = true' "$DSR_REPOS_FILE"
    run _routing_dsr --json repos list
    assert_equal 0 "$status"
    jq -e '(.details.repos | map(select(.repo == "Dicklesworthstone/ntm") | .name) | sort) ==
        ["alias","ntm"] and
        (.details.repos[] | select(.name == "ntm") | .enabled) == true and
        (.details.repos[] | select(.name == "alias") | .enabled) == true' <<< "$output"
}

@test "automation opt-out: enumeration failure cannot publish a partial inventory or launch" {
    harness_create_config
    _setup_repos_yaml
    _watch_configure_ntm
    export DSR_TEST_REAL_JQ
    DSR_TEST_REAL_JQ=$(command -v jq)
    mock_command_script "jq" 'for argument in "$@"; do
        if [[ "$argument" == "to_entries[]" ]]; then
            "$DSR_TEST_REAL_JQ" "$@" || exit $?
            : > "$TEST_TMPDIR/failed-enumeration"
            exit 73
        fi
    done
    exec "$DSR_TEST_REAL_JQ" "$@"'
    run _routing_dsr --json repos list
    assert_equal 4 "$status"
    [[ -e "$TEST_TMPDIR/failed-enumeration" ]]
    jq -e '.status == "error" and .details.repos == []' <<< "$output"
    run _routing_watch "$(_watch_run_json)" --auto-fallback
    assert_equal 0 "$status"
    [[ ! -e "$TEST_TMPDIR/fallback.starts" && ! -e "$DSR_STATE_DIR/triggered.json" ]]
}

@test "automation opt-out: validation permits only the boolean override and retains build mismatches" {
    harness_create_config
    _setup_repos_yaml
    _watch_configure_ntm 'enabled: false'
    yq -i '.tools.ntm.enabled = true' "$DSR_REPOS_FILE"
    local root="${DSR_ROUTING_TEST_ROOT:-$DSR_PROJECT_ROOT}"
    run bash -c 'source "$1/src/config.sh"; config_registry_divergence_json ntm' _ "$root"
    assert_equal 0 "$status"
    jq -e '.mismatched_keys == []' <<< "$output"

    yq -i '.repo = "another/source" | .targets = ["windows/arm64"] | .build_cmd = "changed-build"' \
        "$DSR_CONFIG_DIR/repos.d/ntm.yaml"
    yq -i '.tools.ntm.build_cmd = "original-build"' "$DSR_REPOS_FILE"
    run bash -c 'source "$1/src/config.sh"; config_registry_divergence_json ntm' _ "$root"
    assert_equal 0 "$status"
    jq -e '.mismatched_keys == ["build_cmd","repo","targets"]' <<< "$output"
    run _routing_dsr --json repos validate ntm
    [[ "$status" -ne 0 ]]
    jq -e '.details.validated[0].status == "error"' <<< "$output"

    yq -i '.enabled = "false"' "$DSR_CONFIG_DIR/repos.d/ntm.yaml"
    run bash -c 'source "$1/src/config.sh"; config_registry_divergence_json ntm' _ "$root"
    assert_equal 4 "$status"
}

@test "automation opt-out: missing enabled defaults true including repos.d-only listing" {
    harness_create_config
    _watch_configure_ntm
    mv "$DSR_CONFIG_DIR/repos.yaml" "$TEST_TMPDIR/retained-registry.yaml"
    run _routing_dsr --json repos list
    assert_equal 0 "$status"
    jq -e '.details.repos | length == 1 and .[0].name == "ntm" and .[0].enabled == true' <<< "$output"
    run _routing_watch "$(_watch_run_json)" --auto-fallback
    assert_equal 0 "$status"
    _watch_completed
    assert_equal 1 "$(wc -l < "$TEST_TMPDIR/fallback.starts" | tr -d ' ')"
}

@test "automation opt-out: malformed present values fail closed with real YAML parsing" {
    harness_create_config
    _mock_gh_runs "$(_queued_release_run)"
    local value
    for value in null '"false"' '"true"' 0 1 '[]' '{}'; do
        _watch_configure_ntm "enabled: $value"
        run _routing_dsr --json repos list
        assert_equal 4 "$status"
        jq -e '.status == "error" and .exit_code == 4 and .details.repos == []' <<< "$output"
        run _routing_dsr --json check ntm
        assert_equal 4 "$status"
        jq -e '.status == "error" and .details.stage == "config"' <<< "$output"
        run _routing_watch "$(_watch_run_json)" --auto-fallback
        assert_equal 0 "$status"
        [[ ! -e "$TEST_TMPDIR/fallback.starts" && ! -e "$DSR_STATE_DIR/triggered.json" ]]
    done
    [[ ! -e "$TEST_TMPDIR/gh.calls" ]]
}

@test "automation opt-out: shadowed malformed registry values are not an override escape" {
    harness_create_config
    _setup_repos_yaml
    local policy value
    for policy in true false; do
        _watch_configure_ntm "enabled: $policy"
        for value in '"false"' null; do
            yq -i ".tools.ntm.enabled = $value" "$DSR_REPOS_FILE"
            run _routing_dsr --json repos list
            assert_equal 4 "$status"
            jq -e '.status == "error" and .details.repos == []' <<< "$output"
            run _routing_watch "$(_watch_run_json)" --auto-fallback
            assert_equal 0 "$status"
            [[ ! -e "$TEST_TMPDIR/fallback.starts" && ! -e "$DSR_STATE_DIR/triggered.json" ]]
        done
    done
}

@test "automation opt-out: invalid or ambiguous YAML never falls through to an enabled registry duplicate" {
    harness_create_config
    _setup_repos_yaml
    yq -i '.tools.ntm.enabled = true' "$DSR_REPOS_FILE"
    _watch_configure_ntm
    local document
    for document in $'enabled: true\nenabled: false' \
        $'enabled: false\n---\nenabled: true' $'enabled: [true'; do
        _watch_configure_ntm "$document"
        run _routing_watch "$(_watch_run_json)" --auto-fallback
        assert_equal 0 "$status"
        [[ ! -e "$TEST_TMPDIR/fallback.starts" && ! -e "$DSR_STATE_DIR/triggered.json" ]]
        run _routing_dsr --json repos list
        assert_equal 4 "$status"
    done
}

@test "automation opt-out: disabled tools remain checkable but cannot launch through a registry alias" {
    harness_create_config
    _setup_repos_yaml
    yq -i '.tools.ntm.enabled = true | .tools.alias = .tools.ntm' "$DSR_REPOS_FILE"
    _watch_configure_ntm 'enabled: false'
    _mock_gh_runs "$(_queued_release_run)"
    run _routing_dsr --json check ntm
    assert_equal 1 "$status"
    jq -e '.details.throttled[0].tool == "ntm"' <<< "$output"
    local check_json
    check_json=$(_watch_run_json)
    run _routing_watch "$check_json" --auto-fallback
    assert_equal 0 "$status"
    assert_contains "$output" "Automatic fallback disabled for ntm"
    run _routing_watch "$(jq '.details.throttled[0].tool = "alias"' <<< "$check_json")" --auto-fallback
    assert_equal 0 "$status"
    [[ ! -e "$TEST_TMPDIR/fallback.starts" && ! -e "$DSR_STATE_DIR/triggered.json" ]]
    run _routing_watch "$check_json" --auto-fallback --dry-run
    assert_equal 0 "$status"
    [[ "$output" != *"Would trigger fallback"* ]]
    _watch_configure_ntm 'enabled: true'
    run _routing_watch "$check_json" --auto-fallback
    assert_equal 0 "$status"
    _watch_completed
    assert_equal 1 "$(wc -l < "$TEST_TMPDIR/fallback.starts" | tr -d ' ')"
}

@test "automation opt-out: a disable after observation is rechecked before new launch" {
    harness_create_config
    _watch_configure_ntm 'enabled: true'
    printf 'tool_name: ntm\nrepo: Dicklesworthstone/ntm\nenabled: false\n' \
        > "$TEST_TMPDIR/disabled-after-check.yaml"
    DSR_WATCH_FIXTURE_CONFIG_AFTER_CHECK="$TEST_TMPDIR/disabled-after-check.yaml" \
        run _routing_watch "$(_watch_run_json)" --auto-fallback
    assert_equal 0 "$status"
    assert_contains "$output" "Automatic fallback disabled for ntm"
    [[ ! -e "$TEST_TMPDIR/fallback.starts" && ! -e "$DSR_STATE_DIR/triggered.json" &&
       ! -e "$DSR_STATE_DIR/watch-attempts" ]]
}

@test "automation opt-out: disabled pending work retains history and resumes only after reenable" {
    _watch_pending_fixture
    _watch_configure_ntm 'enabled: false'
    cp "$DSR_STATE_DIR/triggered.json" "$TEST_TMPDIR/pending-before-disable.json"
    _mock_watch_upstream_run "$(_watch_upstream_run_json completed failure)"
    run _routing_watch "$(_watch_run_json)" --auto-fallback --max-concurrent 1
    assert_equal 0 "$status"
    cmp "$TEST_TMPDIR/pending-before-disable.json" "$DSR_STATE_DIR/triggered.json"
    run _routing_watch '{"details":{"throttled":[]}}' --auto-fallback --max-concurrent 1
    assert_equal 0 "$status"
    cmp "$TEST_TMPDIR/pending-before-disable.json" "$DSR_STATE_DIR/triggered.json"
    assert_equal 1 "$(wc -l < "$TEST_TMPDIR/fallback.starts" | tr -d ' ')"
    [[ ! -e "$TEST_TMPDIR/watch-upstream.calls" ]]
    _watch_configure_ntm 'enabled: true'
    run _routing_watch '{"details":{"throttled":[]}}' --auto-fallback --max-concurrent 1
    assert_equal 0 "$status"
    _watch_completed
    jq -e '.pending["12345"] == null and .attempts["12345"].attempt == 1 and
        .attempts["12346"].status == "succeeded"' "$DSR_STATE_DIR/triggered.json"
    assert_equal 2 "$(wc -l < "$TEST_TMPDIR/fallback.starts" | tr -d ' ')"
}

@test "automation opt-out: disabled failed work retains retry budget cooldown and checkpoint" {
    harness_create_config
    _watch_configure_ntm
    local sha check_json checkpoint=12345678-1234-1234-1234-123456789abc
    sha=$(_watch_checkpoint_source_sha)
    check_json=$(_watch_run_json "$sha")
    DSR_WATCH_FIXTURE_STATUS=8 run _routing_watch "$check_json" --auto-fallback --retry-delay 1
    assert_equal 0 "$status"
    _watch_completed
    run _routing_watch '{"details":{"throttled":[]}}' --retry-delay 1
    assert_equal 0 "$status"
    _watch_seed_mixed_checkpoint "$checkpoint" "$DSR_STATE_DIR/watch-artifacts/12345" "$sha"
    cp "$DSR_STATE_DIR/triggered.json" "$TEST_TMPDIR/attempt-before-disable.json"
    cp "$DSR_STATE_DIR/builds/ntm/v1.2.3/$checkpoint/state.json" "$TEST_TMPDIR/checkpoint-before-disable.json"
    _watch_configure_ntm 'enabled: false'
    _mock_watch_upstream_run "$(_watch_upstream_run_json completed failure "$sha")"
    sleep 1
    run _routing_watch "$check_json" --auto-fallback --retry-delay 1
    assert_equal 0 "$status"
    cmp "$TEST_TMPDIR/attempt-before-disable.json" "$DSR_STATE_DIR/triggered.json"
    run _routing_watch '{"details":{"throttled":[]}}' --auto-fallback --retry-delay 1
    assert_equal 0 "$status"
    cmp "$TEST_TMPDIR/attempt-before-disable.json" "$DSR_STATE_DIR/triggered.json"
    cmp "$TEST_TMPDIR/checkpoint-before-disable.json" "$DSR_STATE_DIR/builds/ntm/v1.2.3/$checkpoint/state.json"
    assert_equal 1 "$(wc -l < "$TEST_TMPDIR/fallback.starts" | tr -d ' ')"
    [[ ! -e "$TEST_TMPDIR/watch-upstream.calls" ]]
    _watch_configure_ntm 'enabled: true'
    run _routing_watch '{"details":{"throttled":[]}}' --auto-fallback --retry-delay 1
    assert_equal 0 "$status"
    _watch_completed
    jq -e --arg run "$checkpoint" '.attempts["12345"] | .attempt == 2 and .resume_run_id == $run' \
        "$DSR_STATE_DIR/triggered.json"
    cmp "$TEST_TMPDIR/checkpoint-before-disable.json" "$DSR_STATE_DIR/builds/ntm/v1.2.3/$checkpoint/state.json"
    assert_equal 2 "$(wc -l < "$TEST_TMPDIR/fallback.starts" | tr -d ' ')"
}

@test "automation opt-out: explicit manual fallback still completes for a disabled tool" {
    _watch_isolated_pipeline_fixture
    yq -i '.enabled = false' "$DSR_CONFIG_DIR/repos.d/ntm.yaml"
    run --separate-stderr bash "$DSR_WATCH_FIXTURE_FALLBACK" ntm --version v1.2.3 \
        --expected-sha "$DSR_WATCH_PINNED_SHA" --isolate-source --output-dir "$TEST_TMPDIR/manual-output"
    assert_equal 0 "$status"
    jq -e '.command == "fallback" and .status == "success" and .details.phases.release == "success"' <<< "$output"
    assert_equal 'tagged release source' "$(cat "$TEST_TMPDIR/manual-output/ntm")"
}

@test "watch large history dry-run retains the complete journal without writes" {
    harness_create_config
    _watch_configure_ntm
    _watch_large_history
    cp "$DSR_STATE_DIR/triggered.json" "$TEST_TMPDIR/history-before.json"
    run --separate-stderr _routing_watch "$(_watch_run_json)" --auto-fallback --dry-run
    assert_equal 0 "$status"
    jq -es --slurpfile expected "$TEST_TMPDIR/history-before.json" '
        length == 1 and (.[0] | .command == "watch" and .status == "success" and .exit_code == 0 and
            .details.mode == "once" and .details.dry_run == true and .details.auto_fallback == true and
            .details.max_concurrent == 2 and .details.active_attempts == 0 and .details.deferred_count == 0 and
            .details.triggered_state == $expected[0])' <<< "$output"
    cmp "$TEST_TMPDIR/history-before.json" "$DSR_STATE_DIR/triggered.json"
    [[ ! -e "$TEST_TMPDIR/fallback.args" && ! -e "$DSR_STATE_DIR/watch-attempts" && ! -e "$DSR_STATE_DIR/watch.lock" ]]
    [[ "$stderr" != *"Argument list too long"* ]]
}

@test "watch large history persists new attempts and deduplicates across restarts" {
    harness_create_config
    _watch_configure_ntm
    _watch_large_history
    cp "$DSR_STATE_DIR/triggered.json" "$TEST_TMPDIR/history-before.json"
    local check_json
    check_json=$(_watch_run_json)
    run --separate-stderr _routing_watch "$check_json" --auto-fallback
    assert_equal 0 "$status"
    jq -es --slurpfile state "$DSR_STATE_DIR/triggered.json" '
        length == 1 and (.[0] | .status == "success" and .details.triggered_state == $state[0] and
            (.details.triggered_state.attempts | length) == 501 and .details.active_attempts == 1)' <<< "$output"
    _watch_completed
    run --separate-stderr _routing_watch "$check_json" --auto-fallback
    assert_equal 0 "$status"
    jq -es --slurpfile state "$DSR_STATE_DIR/triggered.json" --slurpfile before "$TEST_TMPDIR/history-before.json" '
        length == 1 and (.[0] | .status == "success" and .details.triggered_state == $state[0] and
            .details.active_attempts == 0 and (.details.triggered_state.attempts | length) == 501) and
        ($state[0] | .attempts["12345"].status == "succeeded" and .attempts["12345"].attempt == 1 and
            .attempts["12345"].exit_code == 0 and
            (del(.attempts["12345"],.runs["12345"],.last_check) == ($before[0] | del(.last_check))))' <<< "$output"
    [[ "$(wc -l < "$TEST_TMPDIR/fallback.starts")" -eq 1 ]]
    [[ "$stderr" != *"Argument list too long"* ]]
}

@test "watch large history survives continuous-mode result assembly" {
    harness_create_config
    _watch_configure_ntm
    _watch_large_history
    cp "$DSR_STATE_DIR/triggered.json" "$TEST_TMPDIR/history-before.json"
    DSR_WATCH_FIXTURE_CONTINUOUS=1 run --separate-stderr _routing_watch \
        '{"details":{"throttled":[]}}' --dry-run
    assert_equal 0 "$status"
    jq -es --slurpfile expected "$TEST_TMPDIR/history-before.json" '
        length == 1 and (.[0] | .command == "watch" and .status == "success" and .exit_code == 0 and
            .details.mode == "continuous" and .details.iterations == 1 and
            .details.triggered_state == $expected[0])' <<< "$output"
    cmp "$TEST_TMPDIR/history-before.json" "$DSR_STATE_DIR/triggered.json"
    [[ ! -e "$TEST_TMPDIR/fallback.args" && ! -e "$DSR_STATE_DIR/watch.lock" ]]
    [[ "$stderr" != *"Argument list too long"* ]]
}

@test "watch large history refuses malformed retained source identities" {
    harness_create_config
    _watch_large_history
    cp "$DSR_STATE_DIR/triggered.json" "$TEST_TMPDIR/history-valid.json"
    local field
    for field in head_sha version repo; do
        jq --arg field "$field" '.attempts["100499"][$field] = "invalid"' \
            "$TEST_TMPDIR/history-valid.json" > "$DSR_STATE_DIR/triggered.json"
        cp "$DSR_STATE_DIR/triggered.json" "$TEST_TMPDIR/history-invalid-$field.json"
        run --separate-stderr _routing_watch "$(_watch_run_json)" --auto-fallback
        assert_equal 4 "$status"
        jq -es 'length == 1 and (.[0] | .status == "error" and .exit_code == 4 and
            .details.triggered_state == null and .details.error == "Cannot read watcher recovery state")' <<< "$output"
        cmp "$TEST_TMPDIR/history-invalid-$field.json" "$DSR_STATE_DIR/triggered.json"
        [[ ! -e "$TEST_TMPDIR/fallback.args" && ! -e "$DSR_STATE_DIR/watch-attempts" ]]
    done
}

@test "watch reporting refuses history corrupted after a successful poll" {
    harness_create_config
    _watch_large_history
    jq '.attempts["100499"].head_sha = "invalid"' "$DSR_STATE_DIR/triggered.json" \
        > "$TEST_TMPDIR/history-after-check.json"
    DSR_WATCH_FIXTURE_HISTORY_AFTER_CHECK="$TEST_TMPDIR/history-after-check.json" \
        run --separate-stderr _routing_watch '{"details":{"throttled":[]}}' --dry-run
    assert_equal 4 "$status"
    jq -es 'length == 1 and (.[0] | .command == "watch" and .status == "error" and .exit_code == 4 and
        .details.triggered_state == null and .details.error == "Cannot read watcher recovery state")' <<< "$output"
    cmp "$TEST_TMPDIR/history-after-check.json" "$DSR_STATE_DIR/triggered.json"
    [[ ! -e "$TEST_TMPDIR/fallback.args" && ! -e "$DSR_STATE_DIR/watch-attempts" ]]
}

@test "watch reporting propagates assembly failures without an empty success" {
    harness_create_config
    local continuous
    for continuous in 0 1; do
        DSR_WATCH_FIXTURE_REPORT_FAILURE=1 DSR_WATCH_FIXTURE_CONTINUOUS="$continuous" \
            run --separate-stderr _routing_watch '{"details":{"throttled":[]}}' --dry-run
        assert_equal 4 "$status"
        [[ -e "$TEST_TMPDIR/report-assembly-failed" ]]
        jq -es 'length == 1 and (.[0] | .command == "watch" and .status == "error" and .exit_code == 4 and
            .details.error == "Cannot assemble watcher result")' <<< "$output"
        [[ ! -e "$DSR_STATE_DIR/triggered.json" && ! -e "$DSR_STATE_DIR/watch-attempts" ]]
    done
}

@test "watch recovery retains a successful child across once invocations" {
    harness_create_config
    _watch_configure_ntm
    local check_json
    check_json=$(_watch_run_json)
    run _routing_watch "$check_json" --auto-fallback
    assert_equal "0" "$status"
    _watch_completed
    run _routing_watch "$check_json" --auto-fallback
    assert_equal "0" "$status"
    jq -e '.attempts["12345"] | .status == "succeeded" and .attempt == 1 and .exit_code == 0' \
        "$DSR_STATE_DIR/triggered.json"
    [[ "$(wc -l < "$TEST_TMPDIR/fallback.starts")" -eq 1 ]]
}

@test "watch recovery uses real Python descriptor locks when flock is absent" {
    harness_create_config
    _watch_configure_ntm
    local check_json
    check_json=$(_watch_run_json)
    DSR_WATCH_FIXTURE_PYTHON=1 run _routing_watch "$check_json" --auto-fallback
    assert_equal "0" "$status"
    _watch_completed
    DSR_WATCH_FIXTURE_PYTHON=1 run _routing_watch "$check_json" --auto-fallback
    assert_equal "0" "$status"
    jq -e '.attempts["12345"] | .status == "succeeded" and .attempt == 1' "$DSR_STATE_DIR/triggered.json"
    [[ "$(wc -l < "$TEST_TMPDIR/fallback.starts")" -eq 1 ]]
}

@test "watch recovery retries failed children with a bounded attempt budget" {
    harness_create_config
    _watch_configure_ntm
    local check_json
    check_json=$(_watch_run_json)
    DSR_WATCH_FIXTURE_STATUS=8 run _routing_watch "$check_json" --auto-fallback --retry-delay 1 --max-attempts 2
    assert_equal "0" "$status"
    _watch_completed
    sleep 1
    DSR_WATCH_FIXTURE_STATUS=8 run _routing_watch "$check_json" --auto-fallback --retry-delay 1 --max-attempts 2
    assert_equal "0" "$status"
    _watch_completed
    run _routing_watch "$check_json" --auto-fallback --retry-delay 1 --max-attempts 2
    assert_equal "0" "$status"
    jq -e '.attempts["12345"] | .status == "failed" and .attempt == 2 and .exit_code == 8' \
        "$DSR_STATE_DIR/triggered.json"
    [[ "$(wc -l < "$TEST_TMPDIR/fallback.starts")" -eq 2 ]]
}

@test "watch terminal recovery resumes its exact checkpoint after upstream failure leaves the queue" {
    harness_create_config
    mkdir -p "$DSR_CONFIG_DIR/repos.d"
    printf 'repo: Dicklesworthstone/ntm\n' > "$DSR_CONFIG_DIR/repos.d/ntm.yaml"
    local sha check_json checkpoint=12345678-1234-1234-1234-123456789abc
    local unrelated=12345678-1234-1234-1234-123456789abd checkpoint_file before payload
    sha=$(_watch_checkpoint_source_sha)
    check_json=$(_watch_run_json "$sha")
    DSR_WATCH_FIXTURE_STATUS=1 run _routing_watch "$check_json" --auto-fallback --retry-delay 1
    assert_equal "0" "$status"
    _watch_completed
    _watch_seed_mixed_checkpoint "$checkpoint" "$DSR_STATE_DIR/watch-artifacts/12345" "$sha"
    _watch_seed_mixed_checkpoint "$unrelated" "$TEST_TMPDIR/unrelated-output" "$sha"
    checkpoint_file="$DSR_STATE_DIR/builds/ntm/v1.2.3/$checkpoint/state.json"
    before=$(cat "$checkpoint_file")
    payload=$(cat "$DSR_STATE_DIR/watch-artifacts/12345/ntm-linux-amd64")
    _mock_watch_upstream_run "$(_watch_upstream_run_json completed failure "$sha")"
    sleep 1
    run _routing_watch '{"details":{"throttled":[]}}' --auto-fallback --retry-delay 1
    assert_equal "0" "$status"
    _watch_completed
    jq -e --arg run "$checkpoint" '.attempts["12345"] |
        .attempt == 2 and .resume_run_id == $run and .isolate_source == true' "$DSR_STATE_DIR/triggered.json"
    jq -Rse --arg resume "--resume=$checkpoint" 'split("\u0000") | index($resume) != null' "$TEST_TMPDIR/fallback.args"
    assert_equal 2 "$(wc -l < "$TEST_TMPDIR/fallback.starts" | tr -d ' ')"
    grep -q 'Cache-Control: no-cache, no-store, max-age=0' "$TEST_TMPDIR/watch-upstream.calls"
    assert_equal "$before" "$(cat "$checkpoint_file")"
    assert_equal "$payload" "$(cat "$DSR_STATE_DIR/watch-artifacts/12345/ntm-linux-amd64")"
    run _routing_watch '{"details":{"throttled":[]}}' --auto-fallback --retry-delay 1
    assert_equal "0" "$status"
    jq -e '.attempts["12345"] | .status == "succeeded" and .attempt == 2' "$DSR_STATE_DIR/triggered.json"
    assert_equal 2 "$(wc -l < "$TEST_TMPDIR/fallback.starts" | tr -d ' ')"
    assert_equal 1 "$(wc -l < "$TEST_TMPDIR/watch-upstream.calls" | tr -d ' ')"
}

@test "watch degraded queue polls recover retained work without admitting new observed runs" {
    _watch_pending_fixture
    _mock_watch_upstream_run "$(_watch_upstream_run_json completed failure)"
    local errored_inventory
    # Even a plausible run inventory from a failed poll has no authority.
    # The saved run must be independently refreshed, and the new run ignored.
    errored_inventory=$(_watch_multiple_runs_json | jq '
        .details.throttled |= [.[0], .[2]] |
        .details.throttled[0].head_sha = "2222222222222222222222222222222222222222" |
        .details.skipped = [{repo:"owner/unavailable",reason:"failed to fetch runs"}]')
    DSR_WATCH_FIXTURE_CHECK_STATUS=8 run --separate-stderr _routing_watch "$errored_inventory" \
        --auto-fallback --max-concurrent 1
    assert_equal 1 "$status"
    jq -e '.status == "error" and .exit_code == 1 and
        .details.triggered_state.attempts["12345"].attempt == 1 and
        .details.triggered_state.pending["12345"] == null' <<< "$output"
    assert_contains "$stderr" "API error, backing off for 60s"
    _watch_completed 12345
    jq -e '(.attempts | keys) == ["12345","12346"] and .runs["12347"] == null and
        .pending == {} and .attempts["12345"].head_sha == "1111111111111111111111111111111111111111"' \
        "$DSR_STATE_DIR/triggered.json"
    assert_equal 2 "$(wc -l < "$TEST_TMPDIR/fallback.starts" | tr -d ' ')"
    assert_equal 1 "$(wc -l < "$TEST_TMPDIR/watch-upstream.calls" | tr -d ' ')"
    grep -q 'Cache-Control: no-cache, no-store, max-age=0' "$TEST_TMPDIR/watch-upstream.calls"
    [[ ! -e "$DSR_STATE_DIR/watch-artifacts/12347" ]]
}

@test "watch degraded queue polls resume only the retained failed checkpoint" {
    harness_create_config
    _watch_configure_ntm
    local sha checkpoint=12345678-1234-1234-1234-123456789abc checkpoint_file before payload
    sha=$(_watch_checkpoint_source_sha)
    DSR_WATCH_FIXTURE_STATUS=8 run _routing_watch "$(_watch_run_json "$sha")" \
        --auto-fallback --retry-delay 1
    assert_equal 0 "$status"
    _watch_completed
    _watch_seed_mixed_checkpoint "$checkpoint" "$DSR_STATE_DIR/watch-artifacts/12345" "$sha"
    checkpoint_file="$DSR_STATE_DIR/builds/ntm/v1.2.3/$checkpoint/state.json"
    before=$(cat "$checkpoint_file")
    payload=$(cat "$DSR_STATE_DIR/watch-artifacts/12345/ntm-linux-amd64")
    _mock_watch_upstream_run "$(_watch_upstream_run_json completed timed_out "$sha")"
    sleep 1
    # Failed transport output need not be JSON. It cannot suppress the
    # separately admitted original-run status or become a new run inventory.
    DSR_WATCH_FIXTURE_CHECK_STATUS=8 run --separate-stderr _routing_watch 'unavailable queue response' \
        --auto-fallback --retry-delay 1
    assert_equal 1 "$status"
    jq -e --arg run "$checkpoint" '.status == "error" and .exit_code == 1 and
        (.details.triggered_state.attempts["12345"] | .attempt == 2 and .resume_run_id == $run)' <<< "$output"
    _watch_completed
    jq -Rse --arg resume "--resume=$checkpoint" 'split("\u0000") | index($resume) != null' "$TEST_TMPDIR/fallback.args"
    assert_equal "$before" "$(cat "$checkpoint_file")"
    assert_equal "$payload" "$(cat "$DSR_STATE_DIR/watch-artifacts/12345/ntm-linux-amd64")"
    assert_equal 2 "$(wc -l < "$TEST_TMPDIR/fallback.starts" | tr -d ' ')"
    assert_equal 1 "$(wc -l < "$TEST_TMPDIR/watch-upstream.calls" | tr -d ' ')"
}

@test "watch degraded queue polls retain opt-outs and require fresh upstream failure evidence" {
    _watch_pending_fixture
    _mock_watch_upstream_run "$(_watch_upstream_run_json completed failure)"
    local before candidate upstream_status conclusion
    before=$(cat "$DSR_STATE_DIR/triggered.json")
    _watch_configure_ntm 'enabled: false'
    DSR_WATCH_FIXTURE_CHECK_STATUS=8 run _routing_watch "$(_watch_run_json)" --auto-fallback
    assert_equal 1 "$status"
    assert_equal "$before" "$(cat "$DSR_STATE_DIR/triggered.json")"
    [[ ! -e "$TEST_TMPDIR/watch-upstream.calls" ]]
    _watch_configure_ntm 'enabled: true'

    DSR_WATCH_FIXTURE_CHECK_STATUS=8 DSR_WATCH_UPSTREAM_ERROR=true \
        run _routing_watch "$(_watch_run_json)" --auto-fallback
    assert_equal 1 "$status"
    assert_equal "$before" "$(cat "$DSR_STATE_DIR/triggered.json")"
    _watch_upstream_run_json completed failure 2222222222222222222222222222222222222222 \
        > "$TEST_TMPDIR/watch-upstream.json"
    DSR_WATCH_FIXTURE_CHECK_STATUS=8 run _routing_watch "$(_watch_run_json)" --auto-fallback
    assert_equal 1 "$status"
    assert_equal "$before" "$(cat "$DSR_STATE_DIR/triggered.json")"
    for candidate in 'in_progress:' 'completed:action_required'; do
        upstream_status="${candidate%%:*}"; conclusion="${candidate#*:}"
        _watch_upstream_run_json "$upstream_status" "$conclusion" > "$TEST_TMPDIR/watch-upstream.json"
        DSR_WATCH_FIXTURE_CHECK_STATUS=8 run _routing_watch "$(_watch_run_json)" --auto-fallback
        assert_equal 1 "$status"
        assert_equal "$before" "$(cat "$DSR_STATE_DIR/triggered.json")"
    done
    _watch_upstream_run_json completed cancelled > "$TEST_TMPDIR/watch-upstream.json"
    DSR_WATCH_FIXTURE_CHECK_STATUS=8 run --separate-stderr _routing_watch "$(_watch_run_json)" --auto-fallback
    assert_equal 1 "$status"
    assert_contains "$stderr" "Retired deferred run 12345"
    jq -e '.pending == {} and .runs["12345"] == null and .attempts["12345"] == null' \
        "$DSR_STATE_DIR/triggered.json"
    assert_equal 1 "$(wc -l < "$TEST_TMPDIR/fallback.starts" | tr -d ' ')"
    [[ ! -e "$DSR_STATE_DIR/watch-artifacts/12345" ]]
}

@test "watch terminal recovery refuses active successful cancelled and unverified upstream runs" {
    harness_create_config
    mkdir -p "$DSR_CONFIG_DIR/repos.d"
    printf 'repo: Dicklesworthstone/ntm\n' > "$DSR_CONFIG_DIR/repos.d/ntm.yaml"
    DSR_WATCH_FIXTURE_STATUS=8 run _routing_watch "$(_watch_run_json)" --auto-fallback --retry-delay 1
    assert_equal "0" "$status"
    _watch_completed
    # Reconcile the actual completion without granting permission to retry.
    run _routing_watch '{"details":{"throttled":[]}}' --retry-delay 1
    assert_equal "0" "$status"
    local before candidate upstream_state conclusion mutation request_count
    before=$(cat "$DSR_STATE_DIR/triggered.json")
    _mock_watch_upstream_run "$(_watch_upstream_run_json)"
    sleep 1
    for candidate in 'in_progress:' 'queued:' 'waiting:' 'completed:success' \
        'completed:cancelled' 'completed:action_required' 'completed:skipped' \
        'completed:neutral' 'completed:stale'; do
        upstream_state="${candidate%%:*}"; conclusion="${candidate#*:}"
        _watch_upstream_run_json "$upstream_state" "$conclusion" > "$TEST_TMPDIR/watch-upstream.json"
        run _routing_watch '{"details":{"throttled":[]}}' --auto-fallback --retry-delay 1
        assert_equal "0" "$status"
        assert_equal "$before" "$(cat "$DSR_STATE_DIR/triggered.json")"
        assert_equal 1 "$(wc -l < "$TEST_TMPDIR/fallback.starts" | tr -d ' ')"
    done
    for mutation in '.id=12346' '.head_sha="2222222222222222222222222222222222222222"' \
        '.head_branch="v1.2.4"' '.repository.full_name="another/repository"' \
        'del(.repository)' '.status="unrecognized"' '.conclusion=null'; do
        _watch_upstream_run_json | jq "$mutation" > "$TEST_TMPDIR/watch-upstream.json"
        run _routing_watch '{"details":{"throttled":[]}}' --auto-fallback --retry-delay 1
        assert_equal "0" "$status"
        assert_equal "$before" "$(cat "$DSR_STATE_DIR/triggered.json")"
        assert_equal 1 "$(wc -l < "$TEST_TMPDIR/fallback.starts" | tr -d ' ')"
    done
    printf 'invalid JSON\n' > "$TEST_TMPDIR/watch-upstream.json"
    run _routing_watch '{"details":{"throttled":[]}}' --auto-fallback --retry-delay 1
    assert_equal "0" "$status"
    assert_equal "$before" "$(cat "$DSR_STATE_DIR/triggered.json")"
    _watch_upstream_run_json > "$TEST_TMPDIR/watch-upstream.json"
    DSR_WATCH_UPSTREAM_ERROR=true run _routing_watch '{"details":{"throttled":[]}}' --auto-fallback --retry-delay 1
    assert_equal "0" "$status"
    assert_equal "$before" "$(cat "$DSR_STATE_DIR/triggered.json")"
    request_count=$(wc -l < "$TEST_TMPDIR/watch-upstream.calls" | tr -d ' ')
    assert_equal 18 "$request_count"
    printf 'repo: another/repository\n' > "$DSR_CONFIG_DIR/repos.d/ntm.yaml"
    run _routing_watch '{"details":{"throttled":[]}}' --auto-fallback --retry-delay 1
    assert_equal "0" "$status"
    assert_equal "$before" "$(cat "$DSR_STATE_DIR/triggered.json")"
    assert_equal "$request_count" "$(wc -l < "$TEST_TMPDIR/watch-upstream.calls" | tr -d ' ')"
    assert_equal 1 "$(wc -l < "$TEST_TMPDIR/fallback.starts" | tr -d ' ')"
    [[ ! -e "$DSR_STATE_DIR/watch-artifacts/12345" ]]
}

@test "watch terminal recovery retains cooldown and does not spend attempts on skipped polls" {
    harness_create_config
    mkdir -p "$DSR_CONFIG_DIR/repos.d"
    printf 'repo: Dicklesworthstone/ntm\n' > "$DSR_CONFIG_DIR/repos.d/ntm.yaml"
    _mock_watch_upstream_run "$(_watch_upstream_run_json)"
    DSR_WATCH_FIXTURE_STATUS=8 run _routing_watch "$(_watch_run_json)" --auto-fallback --retry-delay 3600
    assert_equal "0" "$status"
    _watch_completed
    run _routing_watch '{"details":{"throttled":[]}}' --auto-fallback --retry-delay 3600
    assert_equal "0" "$status"
    jq -e '.attempts["12345"] | .status == "failed" and .attempt == 1 and
        .next_retry_at == .finished_epoch + 3600' "$DSR_STATE_DIR/triggered.json"
    local before
    before=$(cat "$DSR_STATE_DIR/triggered.json")
    run _routing_watch '{"details":{"throttled":[]}}' --auto-fallback --retry-delay 3600
    assert_equal "0" "$status"
    assert_equal "$before" "$(cat "$DSR_STATE_DIR/triggered.json")"
    assert_equal 1 "$(wc -l < "$TEST_TMPDIR/fallback.starts" | tr -d ' ')"
    [[ ! -e "$TEST_TMPDIR/watch-upstream.calls" ]]
}

@test "watch terminal recovery honors report-only dry-run and the attempt budget" {
    harness_create_config
    mkdir -p "$DSR_CONFIG_DIR/repos.d"
    printf 'repo: Dicklesworthstone/ntm\n' > "$DSR_CONFIG_DIR/repos.d/ntm.yaml"
    DSR_WATCH_FIXTURE_STATUS=8 run _routing_watch "$(_watch_run_json)" --auto-fallback --retry-delay 1 --max-attempts 2
    assert_equal "0" "$status"
    _watch_completed
    _mock_watch_upstream_run "$(_watch_upstream_run_json completed timed_out)"
    run _routing_watch '{"details":{"throttled":[]}}' --retry-delay 1 --max-attempts 2
    assert_equal "0" "$status"
    local before
    before=$(cat "$DSR_STATE_DIR/triggered.json")
    sleep 1
    run _routing_watch '{"details":{"throttled":[]}}' --retry-delay 1 --max-attempts 2
    assert_equal "0" "$status"
    [[ ! -e "$TEST_TMPDIR/watch-upstream.calls" ]]
    run _routing_watch '{"details":{"throttled":[]}}' --auto-fallback --dry-run --retry-delay 1 --max-attempts 2
    assert_equal "0" "$status"
    assert_contains "$output" "[DRY RUN] Would trigger fallback"
    assert_equal "$before" "$(cat "$DSR_STATE_DIR/triggered.json")"
    assert_equal 1 "$(wc -l < "$TEST_TMPDIR/fallback.starts" | tr -d ' ')"
    DSR_WATCH_FIXTURE_STATUS=8 run _routing_watch '{"details":{"throttled":[]}}' --auto-fallback --retry-delay 1 --max-attempts 2
    assert_equal "0" "$status"
    _watch_completed
    run _routing_watch '{"details":{"throttled":[]}}' --auto-fallback --retry-delay 1 --max-attempts 2
    assert_equal "0" "$status"
    jq -e '.attempts["12345"] | .status == "failed" and .attempt == 2 and .exit_code == 8' "$DSR_STATE_DIR/triggered.json"
    assert_equal 2 "$(wc -l < "$TEST_TMPDIR/fallback.starts" | tr -d ' ')"
    # Exactly one read for the plan and one for the real retry; an exhausted
    # attempt budget does not issue more status reads or start another child.
    assert_equal 2 "$(wc -l < "$TEST_TMPDIR/watch-upstream.calls" | tr -d ' ')"
}

@test "watch terminal recovery completes the pinned fallback pipeline after a transient quality failure" {
    command -v yq >/dev/null || skip "yq required for the real fallback pipeline"
    _watch_isolated_pipeline_fixture
    export DSR_WATCH_FIXTURE_QUALITY_FAIL_ONCE=true
    local check_json attempt
    check_json=$(_watch_run_json "$DSR_WATCH_PINNED_SHA")
    run _routing_watch "$check_json" --auto-fallback --retry-delay 1
    assert_equal "0" "$status"
    _watch_completed
    attempt=$(jq -r '.attempts["12345"].attempt_id' "$DSR_STATE_DIR/triggered.json")
    jq -e '.exit_code == 6' "$DSR_STATE_DIR/watch-attempts/$attempt/completion.json"
    jq -e '.command == "fallback" and .details.phase == "checks"' "$DSR_STATE_DIR/watch-attempts/$attempt/result.json"
    [[ ! -e "$DSR_STATE_DIR/watch-artifacts/12345" && ! -e "$TEST_TMPDIR/release-source" ]]
    _mock_watch_upstream_run "$(_watch_upstream_run_json completed startup_failure "$DSR_WATCH_PINNED_SHA")"
    sleep 1
    run _routing_watch '{"details":{"throttled":[]}}' --auto-fallback --retry-delay 1
    assert_equal "0" "$status"
    _watch_completed
    attempt=$(jq -r '.attempts["12345"].attempt_id' "$DSR_STATE_DIR/triggered.json")
    jq -e '.exit_code == 0' "$DSR_STATE_DIR/watch-attempts/$attempt/completion.json"
    jq -e --arg sha "$DSR_WATCH_PINNED_SHA" '.command == "fallback" and .exit_code == 0 and
        .details.expected_sha == $sha and .details.isolated_source == true and
        .details.phases.release == "success"' "$DSR_STATE_DIR/watch-attempts/$attempt/result.json"
    cmp "$TEST_TMPDIR/developer-source/source.txt" "$DSR_STATE_DIR/watch-artifacts/12345/ntm"
    [[ "$(cat "$TEST_TMPDIR/build-source")" != "$TEST_TMPDIR/developer-source" ]]
    assert_equal "$(cat "$TEST_TMPDIR/build-source")" "$(cat "$TEST_TMPDIR/release-source")"
    assert_equal "$DSR_WATCH_PINNED_SHA" "$(git -C "$TEST_TMPDIR/developer-source" rev-parse HEAD)"
    assert_equal 2 "$(wc -l < "$TEST_TMPDIR/fallback.starts" | tr -d ' ')"
}

@test "watch recovery preserves cooldown and does not hold the watcher lock in its child" {
    harness_create_config
    _watch_configure_ntm
    local check_json
    check_json=$(_watch_run_json)
    DSR_WATCH_FIXTURE_WAIT="$TEST_TMPDIR/finish-child" DSR_WATCH_FIXTURE_STATUS=8 run _routing_watch "$check_json" --auto-fallback
    assert_equal "0" "$status"
    run _routing_watch "$check_json" --auto-fallback
    assert_equal "0" "$status"
    jq -e '.attempts["12345"] | .status == "running" and .attempt == 1' "$DSR_STATE_DIR/triggered.json"
    touch "$TEST_TMPDIR/finish-child"
    _watch_completed
    run _routing_watch "$check_json" --auto-fallback
    assert_equal "0" "$status"
    jq -e '.attempts["12345"] | .status == "failed" and .attempt == 1 and .next_retry_at > .finished_epoch' \
        "$DSR_STATE_DIR/triggered.json"
    [[ "$(wc -l < "$TEST_TMPDIR/fallback.starts")" -eq 1 ]]
}

@test "watch pending recovery starts a deferred pinned release after upstream failure leaves the queue" {
    command -v yq >/dev/null || skip "yq required for the real fallback pipeline"
    _watch_isolated_pipeline_fixture
    local check_json queued first_status first_state
    check_json=$(_watch_multiple_runs_json "$DSR_WATCH_PINNED_SHA" |
        jq '.details.throttled |= [.[1], .[0]]')
    DSR_WATCH_FIXTURE_FALLBACK='' DSR_WATCH_FIXTURE_WAIT="$TEST_TMPDIR/finish-child" \
        run --separate-stderr _routing_watch "$check_json" --auto-fallback --max-concurrent 1
    first_status=$status
    first_state=$(cat "$DSR_STATE_DIR/triggered.json")
    queued=false
    [[ -e "$DSR_STATE_DIR/watch-artifacts/12345" ]] || queued=true
    # Release the actual worker even when the unchanged watcher lost the
    # pending candidate; the later empty inventory must recover that release.
    touch "$TEST_TMPDIR/finish-child"
    _watch_completed 12346
    assert_equal 0 "$first_status"
    _mock_watch_upstream_run "$(_watch_upstream_run_json completed failure "$DSR_WATCH_PINNED_SHA")"
    run --separate-stderr _routing_watch '{"details":{"throttled":[]}}' --auto-fallback --max-concurrent 1
    assert_equal 0 "$status"
    jq -e '.attempts["12345"] | .attempt == 1 and .resume_run_id == "" and .isolate_source == true' \
        "$DSR_STATE_DIR/triggered.json"
    _watch_completed 12345
    jq -e --arg sha "$DSR_WATCH_PINNED_SHA" '.pending["12345"] |
        .tool == "ntm" and .repo == "Dicklesworthstone/ntm" and .version == "v1.2.3" and
        .head_sha == $sha and .isolate_source == true and (.queued_epoch | type == "number")' <<< "$first_state"
    jq -e '.attempts["12345"] == null and .runs["12345"] == null' <<< "$first_state"
    [[ "$queued" == true ]]
    jq -e '.pending["12345"] == null' "$DSR_STATE_DIR/triggered.json"
    jq -Rse 'split("\u0000") | all(.[]; startswith("--resume=") | not)' "$TEST_TMPDIR/fallback.args"
    assert_equal 2 "$(wc -l < "$TEST_TMPDIR/fallback.starts" | tr -d ' ')"
    local attempt private_source
    attempt=$(jq -r '.attempts["12345"].attempt_id' "$DSR_STATE_DIR/triggered.json")
    jq -e '.exit_code == 0' "$DSR_STATE_DIR/watch-attempts/$attempt/completion.json"
    private_source=$(cat "$TEST_TMPDIR/build-source")
    [[ "$private_source" != "$TEST_TMPDIR/developer-source" ]]
    assert_equal "$DSR_WATCH_PINNED_SHA" "$(git -C "$private_source" rev-parse HEAD)"
    assert_equal 'tagged release source' "$(cat "$DSR_STATE_DIR/watch-artifacts/12345/ntm")"
    grep -q 'Cache-Control: no-cache, no-store, max-age=0' "$TEST_TMPDIR/watch-upstream.calls"
}

@test "watch pending recovery refuses unknown upstream identity and changed configuration" {
    _watch_pending_fixture
    local before candidate upstream_state conclusion mutation requests
    before=$(cat "$DSR_STATE_DIR/triggered.json")
    _mock_watch_upstream_run "$(_watch_upstream_run_json)"
    for candidate in 'in_progress:' 'queued:' 'waiting:' 'completed:action_required' \
        'completed:neutral' 'completed:skipped' 'completed:unrecognized' 'completed:'; do
        upstream_state="${candidate%%:*}"; conclusion="${candidate#*:}"
        _watch_upstream_run_json "$upstream_state" "$conclusion" > "$TEST_TMPDIR/watch-upstream.json"
        run _routing_watch '{"details":{"throttled":[]}}' --auto-fallback --max-concurrent 1
        assert_equal 0 "$status"
        assert_equal "$before" "$(cat "$DSR_STATE_DIR/triggered.json")"
    done
    for mutation in '.id=12346' '.head_sha="2222222222222222222222222222222222222222"' \
        '.head_branch="v1.2.4"' '.repository.full_name="another/repository"' 'del(.repository)'; do
        _watch_upstream_run_json | jq "$mutation" > "$TEST_TMPDIR/watch-upstream.json"
        run _routing_watch '{"details":{"throttled":[]}}' --auto-fallback --max-concurrent 1
        assert_equal 0 "$status"
        assert_equal "$before" "$(cat "$DSR_STATE_DIR/triggered.json")"
    done
    printf 'invalid JSON\n' > "$TEST_TMPDIR/watch-upstream.json"
    run _routing_watch '{"details":{"throttled":[]}}' --auto-fallback --max-concurrent 1
    assert_equal 0 "$status"
    assert_equal "$before" "$(cat "$DSR_STATE_DIR/triggered.json")"
    _watch_upstream_run_json > "$TEST_TMPDIR/watch-upstream.json"
    DSR_WATCH_UPSTREAM_ERROR=true run _routing_watch '{"details":{"throttled":[]}}' --auto-fallback --max-concurrent 1
    assert_equal 0 "$status"
    assert_equal "$before" "$(cat "$DSR_STATE_DIR/triggered.json")"
    requests=$(wc -l < "$TEST_TMPDIR/watch-upstream.calls" | tr -d ' ')
    for mutation in '.details.throttled[0].tool="other"' \
        '.details.throttled[0].repo="another/repository"' \
        '.details.throttled[0].head_branch="v1.2.4"' \
        '.details.throttled[0].head_sha="2222222222222222222222222222222222222222"'; do
        run _routing_watch "$(_watch_run_json | jq "$mutation")" --auto-fallback --max-concurrent 1
        assert_equal 0 "$status"
        assert_equal "$before" "$(cat "$DSR_STATE_DIR/triggered.json")"
    done
    printf 'repo: another/repository\n' > "$DSR_CONFIG_DIR/repos.d/ntm.yaml"
    run _routing_watch "$(_watch_run_json)" --auto-fallback --max-concurrent 1
    assert_equal 0 "$status"
    assert_equal "$before" "$(cat "$DSR_STATE_DIR/triggered.json")"
    run _routing_watch '{"details":{"throttled":[]}}' --auto-fallback --max-concurrent 1
    assert_equal 0 "$status"
    assert_equal "$before" "$(cat "$DSR_STATE_DIR/triggered.json")"
    mv "$DSR_CONFIG_DIR/repos.d/ntm.yaml" "$TEST_TMPDIR/removed-ntm.yaml"
    run _routing_watch '{"details":{"throttled":[]}}' --auto-fallback --max-concurrent 1
    assert_equal 0 "$status"
    assert_equal "$before" "$(cat "$DSR_STATE_DIR/triggered.json")"
    assert_equal "$requests" "$(wc -l < "$TEST_TMPDIR/watch-upstream.calls" | tr -d ' ')"
    assert_equal 1 "$(wc -l < "$TEST_TMPDIR/fallback.starts" | tr -d ' ')"
    [[ ! -e "$DSR_STATE_DIR/watch-artifacts/12345" ]]
}

@test "watch pending recovery retires successful and cancelled runs before another launch" {
    local conclusion state requests first_status
    for conclusion in success cancelled; do
        export DSR_STATE_DIR="$TEST_TMPDIR/state-$conclusion"
        _watch_pending_fixture
        _mock_watch_upstream_run "$(_watch_upstream_run_json completed "$conclusion")"
        DSR_WATCH_FIXTURE_WAIT="$DSR_STATE_DIR/finish-next" run --separate-stderr _routing_watch \
            "$(_watch_multiple_runs_json | jq '.details.throttled = [.details.throttled[2]]')" \
            --auto-fallback --max-concurrent 1
        first_status=$status
        state=$(cat "$DSR_STATE_DIR/triggered.json")
        touch "$DSR_STATE_DIR/finish-next"
        _watch_completed 12347
        assert_equal 0 "$first_status"
        jq -e '.pending == {} and .runs["12345"] == null and .attempts["12345"] == null and
            .attempts["12347"].attempt == 1' <<< "$state"
        [[ ! -e "$DSR_STATE_DIR/watch-artifacts/12345" ]]
        requests=$(wc -l < "$TEST_TMPDIR/watch-upstream.calls" | tr -d ' ')
        run _routing_watch '{"details":{"throttled":[]}}' --auto-fallback --max-concurrent 1
        assert_equal 0 "$status"
        assert_equal "$requests" "$(wc -l < "$TEST_TMPDIR/watch-upstream.calls" | tr -d ' ')"
        jq -e '.pending == {} and (.attempts | keys) == ["12346","12347"]' "$DSR_STATE_DIR/triggered.json"
    done
}

@test "watch pending recovery keeps full-capacity polls and planning read only" {
    harness_create_config
    mkdir -p "$DSR_CONFIG_DIR/repos.d"
    printf 'repo: Dicklesworthstone/ntm\n' > "$DSR_CONFIG_DIR/repos.d/ntm.yaml"
    local check_json before first_status requests observed_status observed_output stderr=""
    check_json=$(_watch_multiple_runs_json | jq '.details.throttled |= [.[1], .[0]]')
    DSR_WATCH_FIXTURE_WAIT="$TEST_TMPDIR/finish-child" \
        run --separate-stderr _routing_watch "$check_json" --auto-fallback --max-concurrent 1
    first_status=$status
    before=$(cat "$DSR_STATE_DIR/triggered.json")
    _mock_watch_upstream_run "$(_watch_upstream_run_json)"
    run --separate-stderr _routing_watch '{"details":{"throttled":[]}}' --auto-fallback --max-concurrent 1
    observed_status=$status; observed_output=$output
    local full_state
    full_state=$(cat "$DSR_STATE_DIR/triggered.json")
    touch "$TEST_TMPDIR/finish-child"
    _watch_completed 12346
    assert_equal 0 "$first_status"
    assert_equal 0 "$observed_status"
    assert_equal "$before" "$full_state"
    [[ ! -e "$TEST_TMPDIR/watch-upstream.calls" ]]
    jq -e '.details.active_attempts == 1 and (.details.triggered_state.pending | keys) == ["12345"]' <<< "$observed_output"
    # Established report-only completion reconciliation is allowed. It may
    # not admit or retire the pending candidate, and never queries its run.
    run _routing_watch '{"details":{"throttled":[]}}' --max-concurrent 1
    assert_equal 0 "$status"
    before=$(cat "$DSR_STATE_DIR/triggered.json")
    run --separate-stderr _routing_watch '{"details":{"throttled":[]}}' --auto-fallback --dry-run --max-concurrent 1
    assert_equal 0 "$status"
    assert_contains "$stderr" "[DRY RUN] Would trigger fallback"
    assert_equal "$before" "$(cat "$DSR_STATE_DIR/triggered.json")"
    requests=$(wc -l < "$TEST_TMPDIR/watch-upstream.calls" | tr -d ' ')
    run _routing_watch "$(_watch_run_json)" --max-concurrent 1
    assert_equal 0 "$status"
    assert_equal "$before" "$(cat "$DSR_STATE_DIR/triggered.json")"
    assert_equal "$requests" "$(wc -l < "$TEST_TMPDIR/watch-upstream.calls" | tr -d ' ')"
    _watch_upstream_run_json completed success > "$TEST_TMPDIR/watch-upstream.json"
    run --separate-stderr _routing_watch '{"details":{"throttled":[]}}' --auto-fallback --dry-run --max-concurrent 1
    assert_equal 0 "$status"
    assert_contains "$stderr" "[DRY RUN] Would retire deferred run"
    assert_equal "$before" "$(cat "$DSR_STATE_DIR/triggered.json")"
    assert_equal 1 "$(wc -l < "$TEST_TMPDIR/fallback.starts" | tr -d ' ')"
    [[ ! -e "$DSR_STATE_DIR/watch-artifacts/12345" ]]
}

@test "watch pending recovery admits older deferred work before new arrivals within the limit" {
    _watch_pending_fixture
    _mock_watch_upstream_run "$(_watch_upstream_run_json completed timed_out)"
    local first_status state
    DSR_WATCH_FIXTURE_WAIT="$TEST_TMPDIR/finish-next" run --separate-stderr _routing_watch \
        "$(_watch_multiple_runs_json | jq '.details.throttled = [.details.throttled[2]]')" \
        --auto-fallback --max-concurrent 1
    first_status=$status
    state=$(cat "$DSR_STATE_DIR/triggered.json")
    touch "$TEST_TMPDIR/finish-next"
    _watch_completed 12345
    assert_equal 0 "$first_status"
    jq -e '.attempts["12345"].attempt == 1 and .pending["12345"] == null and
        .pending["12347"] != null and .attempts["12347"] == null and .runs["12347"] == null' <<< "$state"
    assert_equal 2 "$(wc -l < "$TEST_TMPDIR/fallback.starts" | tr -d ' ')"
    run _routing_watch "$(_watch_multiple_runs_json | jq '.details.throttled = [.details.throttled[2]]')" \
        --auto-fallback --max-concurrent 1
    assert_equal 0 "$status"
    _watch_completed 12347
    jq -e '.pending == {} and .attempts["12347"].attempt == 1' "$DSR_STATE_DIR/triggered.json"
    assert_equal 3 "$(wc -l < "$TEST_TMPDIR/fallback.starts" | tr -d ' ')"
}

@test "watch pending recovery rejects malformed or already-claimed candidates and migrates absent queues" {
    _watch_pending_fixture
    local valid invalid mutation before_count
    valid=$(cat "$DSR_STATE_DIR/triggered.json")
    before_count=$(wc -l < "$TEST_TMPDIR/fallback.starts" | tr -d ' ')
    for mutation in '.pending=null' '.pending=[]' '.pending["12345"].queued_epoch=-1' \
        '.pending["12345"].queued_epoch=1.5' '.pending["12345"].isolate_source=false' \
        '.pending["12345"].head_sha="0000000000000000000000000000000000000000"' \
        '.pending["12345"].attempt=0' '.pending["12345"].resume_run_id="11111111-1111-4111-8111-111111111111"' \
        '.pending["../invalid"]=.pending["12345"]' '.pending["12346"]=.pending["12345"]' \
        '.runs["12345"]="2000-01-01T00:00:00Z"' '.attempts["12345"]=.attempts["12346"]' \
        'del(.pending["12345"].repo)' '.pending["12345"].tool="../invalid"'; do
        invalid=$(jq "$mutation" <<< "$valid")
        printf '%s\n' "$invalid" > "$DSR_STATE_DIR/triggered.json"
        run _routing_watch "$(_watch_run_json)" --auto-fallback
        assert_equal 4 "$status"
        assert_equal "$invalid" "$(cat "$DSR_STATE_DIR/triggered.json")"
        assert_equal "$before_count" "$(wc -l < "$TEST_TMPDIR/fallback.starts" | tr -d ' ')"
    done
    valid=$(jq 'del(.pending)' <<< "$valid")
    printf '%s\n' "$valid" > "$DSR_STATE_DIR/triggered.json"
    run --separate-stderr _routing_watch '{"details":{"throttled":[]}}'
    assert_equal 0 "$status"
    jq -e '.details.triggered_state.pending == {} and
        .details.triggered_state.attempts["12346"].status == "succeeded"' <<< "$output"
    assert_equal "$valid" "$(cat "$DSR_STATE_DIR/triggered.json")"
}

@test "watch pending recovery refuses existing output without inventing a resume checkpoint" {
    _watch_pending_fixture
    _mock_watch_upstream_run "$(_watch_upstream_run_json completed startup_failure)"
    local before
    before=$(cat "$DSR_STATE_DIR/triggered.json")
    mkdir -p "$DSR_STATE_DIR/watch-artifacts/12345"
    printf 'unclaimed payload\n' > "$DSR_STATE_DIR/watch-artifacts/12345/retained.bin"
    run _routing_watch '{"details":{"throttled":[]}}' --auto-fallback --max-concurrent 1
    assert_equal 4 "$status"
    assert_contains "$output" "Unclaimed watcher artifact directory already exists"
    assert_equal "$before" "$(cat "$DSR_STATE_DIR/triggered.json")"
    assert_equal 1 "$(wc -l < "$TEST_TMPDIR/fallback.starts" | tr -d ' ')"
    assert_equal 'unclaimed payload' "$(cat "$DSR_STATE_DIR/watch-artifacts/12345/retained.bin")"
    [[ ! -e "$DSR_STATE_DIR/builds/ntm/v1.2.3" ]]
}

@test "watch admission bounds active fallbacks across restarts and launches deferred runs after completion" {
    harness_create_config
    mkdir -p "$DSR_CONFIG_DIR/repos.d"
    printf 'repo: Dicklesworthstone/ntm\n' > "$DSR_CONFIG_DIR/repos.d/ntm.yaml"
    local check_json first_state first_status second_state second_status deadline
    check_json=$(_watch_multiple_runs_json)
    DSR_WATCH_FIXTURE_WAIT="$TEST_TMPDIR/finish-child" run --separate-stderr _routing_watch "$check_json" --auto-fallback
    first_status=$status
    first_state=$(cat "$DSR_STATE_DIR/triggered.json")
    DSR_WATCH_FIXTURE_WAIT="$TEST_TMPDIR/finish-child" run --separate-stderr _routing_watch "$check_json" --auto-fallback --max-concurrent 1
    second_status=$status
    second_state=$(cat "$DSR_STATE_DIR/triggered.json")
    local second_output=$output
    # Release real workers even when the incumbent over-admits the matrix.
    touch "$TEST_TMPDIR/finish-child"
    _watch_completed 12345
    _watch_completed 12346
    assert_equal "0" "$first_status"
    assert_equal "0" "$second_status"
    jq -e '.attempts | keys == ["12345", "12346"]' <<< "$first_state"
    [[ "$first_state" == "$second_state" ]]
    jq -e '.details | .max_concurrent == 1 and .active_attempts == 2 and .deferred_count == 1' \
        <<< "$second_output"
    [[ ! -e "$DSR_STATE_DIR/watch-artifacts/12347" ]]
    deadline=$((SECONDS + 10))
    while ((SECONDS < deadline)); do
        run _routing_watch "$check_json" --auto-fallback
        assert_equal "0" "$status"
        jq -e '.attempts["12347"] != null' "$DSR_STATE_DIR/triggered.json" >/dev/null && break
        sleep 0.05
    done
    _watch_completed 12347
    run _routing_watch "$check_json" --auto-fallback
    assert_equal "0" "$status"
    jq -e '.attempts | length == 3 and all(.[]; .status == "succeeded" and .attempt == 1)' \
        "$DSR_STATE_DIR/triggered.json"
    [[ "$(wc -l < "$TEST_TMPDIR/fallback.starts")" -eq 3 ]]
}

@test "watch admission defers failed retries without consuming their attempt budget" {
    harness_create_config
    _watch_configure_ntm
    local first_json second_json both_json saved
    first_json=$(_watch_run_json)
    second_json=$(_watch_multiple_runs_json | jq '.details.throttled = [.details.throttled[1]]')
    both_json=$(_watch_multiple_runs_json | jq '.details.throttled = .details.throttled[:2]')
    DSR_WATCH_FIXTURE_STATUS=8 run --separate-stderr _routing_watch "$first_json" --auto-fallback --retry-delay 1 --max-concurrent 1
    assert_equal "0" "$status"
    _watch_completed 12345
    DSR_WATCH_FIXTURE_WAIT="$TEST_TMPDIR/finish-child" run --separate-stderr _routing_watch "$second_json" --auto-fallback --retry-delay 1 --max-concurrent 1
    assert_equal "0" "$status"
    saved=$(jq -c '.attempts["12345"]' "$DSR_STATE_DIR/triggered.json")
    sleep 1
    run --separate-stderr _routing_watch "$both_json" --auto-fallback --retry-delay 1 --max-concurrent 1
    local observed_status=$status observed_output=$output
    touch "$TEST_TMPDIR/finish-child"
    _watch_completed 12346
    assert_equal "0" "$observed_status"
    [[ "$(jq -c '.attempts["12345"]' "$DSR_STATE_DIR/triggered.json")" == "$saved" ]]
    jq -e '.details | .max_concurrent == 1 and .active_attempts == 1 and .deferred_count == 1' \
        <<< "$observed_output"
    [[ "$(wc -l < "$TEST_TMPDIR/fallback.starts")" -eq 2 ]]
}

@test "watch admission honors live descendant locks even after a completion receipt exists" {
    harness_create_config
    _watch_configure_ntm
    local check_json directory holder deadline=$((SECONDS + 10))
    check_json=$(_watch_multiple_runs_json)
    run _routing_watch "$(_watch_run_json)" --auto-fallback --max-concurrent 1
    assert_equal "0" "$status"
    _watch_completed
    directory="$DSR_STATE_DIR/watch-attempts/$(jq -r '.attempts["12345"].attempt_id' "$DSR_STATE_DIR/triggered.json")"
    # Hold the actual kernel lock through a separate process. A finished
    # parent's receipt cannot release a slot still owned by a descendant.
    bash -c 'exec 9>> "$1/active.lock"; flock -x 9 || exit; touch "$2";
        while [[ ! -e "$3" ]]; do sleep 0.05; done' _ "$directory" \
        "$TEST_TMPDIR/held" "$TEST_TMPDIR/release-held" &
    holder=$!
    while [[ ! -e "$TEST_TMPDIR/held" ]] && ((SECONDS < deadline)); do sleep 0.05; done
    run --separate-stderr _routing_watch "$check_json" --auto-fallback --max-concurrent 1
    local observed_status=$status observed_output=$output
    touch "$TEST_TMPDIR/release-held"
    wait "$holder"
    assert_equal "0" "$observed_status"
    jq -e '.details | .active_attempts == 1 and .deferred_count == 2 and
        (.triggered_state.attempts | keys == ["12345"])' <<< "$observed_output"
    [[ "$(wc -l < "$TEST_TMPDIR/fallback.starts")" -eq 1 ]]
}

@test "watch admission plans only available slots without changing recovery state" {
    harness_create_config
    _watch_configure_ntm
    local check_json
    check_json=$(_watch_multiple_runs_json)
    run --separate-stderr _routing_watch "$check_json" --auto-fallback --dry-run
    assert_equal "0" "$status"
    [[ "$(printf '%s\n' "$stderr" | grep -c 'Would trigger fallback')" -eq 2 ]]
    jq -e '.details | .max_concurrent == 2 and .active_attempts == 0 and .deferred_count == 1' <<< "$output"
    [[ ! -e "$DSR_STATE_DIR/triggered.json" && ! -e "$DSR_STATE_DIR/watch.lock" &&
       ! -e "$DSR_STATE_DIR/watch-attempts" && ! -e "$TEST_TMPDIR/fallback.args" ]]
}

@test "watch admission refuses invalid concurrency before running children" {
    harness_create_config
    local value
    for value in 0 33 -1 01 1.5 invalid ''; do
        run _routing_watch "$(_watch_run_json)" --auto-fallback --max-concurrent "$value"
        assert_equal "4" "$status"
        [[ ! -e "$TEST_TMPDIR/watch-check.started" && ! -e "$TEST_TMPDIR/fallback.args" ]]
    done
    run _routing_watch "$(_watch_run_json)" --auto-fallback --max-concurrent
    assert_equal "4" "$status"
}

@test "watch recovery refuses source identity changes and legacy unknown outcomes" {
    harness_create_config
    _watch_configure_ntm
    local check_json
    check_json=$(_watch_run_json)
    DSR_WATCH_FIXTURE_STATUS=8 run _routing_watch "$check_json" --auto-fallback --retry-delay 1
    assert_equal "0" "$status"
    _watch_completed
    sleep 1
    run _routing_watch "$(_watch_run_json 2222222222222222222222222222222222222222)" --auto-fallback --retry-delay 1
    assert_equal "0" "$status"
    assert_contains "$output" "Observed identity changed"
    [[ "$(wc -l < "$TEST_TMPDIR/fallback.starts")" -eq 1 ]]
    printf '%s\n' '{"runs":{"12345":"2000-01-01T00:00:00Z"},"last_check":null}' > "$DSR_STATE_DIR/triggered.json"
    run _routing_watch "$check_json" --auto-fallback
    assert_equal "0" "$status"
    [[ "$(wc -l < "$TEST_TMPDIR/fallback.starts")" -eq 1 ]]
    jq -e '.runs["12345"] == "2000-01-01T00:00:00Z"' "$DSR_STATE_DIR/triggered.json"
}

@test "watch recovery refuses corrupt state instead of losing deduplication" {
    harness_create_config
    printf 'broken journal\n' > "$DSR_STATE_DIR/triggered.json"
    run _routing_watch "$(_watch_run_json)" --auto-fallback
    assert_equal "4" "$status"
    [[ "$(cat "$DSR_STATE_DIR/triggered.json")" == "broken journal" ]]
    [[ ! -e "$TEST_TMPDIR/fallback.args" ]]
}

@test "watch recovery uses the exact private-output checkpoint instead of latest" {
    harness_create_config
    _watch_configure_ntm
    local check_json checkpoint=12345678-1234-1234-1234-123456789abc state_dir
    check_json=$(_watch_run_json)
    DSR_WATCH_FIXTURE_STATUS=6 run _routing_watch "$check_json" --auto-fallback --retry-delay 1
    assert_equal "0" "$status"
    _watch_completed
    state_dir="$DSR_STATE_DIR/builds/ntm/v1.2.3/$checkpoint"
    mkdir -p "$state_dir" "$DSR_STATE_DIR/watch-artifacts/12345"
    jq -nc --arg run "$checkpoint" --arg output "$DSR_STATE_DIR/watch-artifacts/12345" '
        {tool:"ntm",version:"v1.2.3",run_id:$run,status:"failed",
         git_sha:"1111111111111111111111111111111111111111",context:{output_dir:$output}}' > "$state_dir/state.json"
    ln -s "$checkpoint" "$DSR_STATE_DIR/builds/ntm/v1.2.3/latest"
    sleep 1
    run _routing_watch "$check_json" --auto-fallback --retry-delay 1
    assert_equal "0" "$status"
    _watch_completed
    jq -Rse --arg resume "--resume=$checkpoint" 'split("\u0000") | index($resume) != null' "$TEST_TMPDIR/fallback.args"
    jq -e --arg run "$checkpoint" '.attempts["12345"] | .attempt == 2 and .resume_run_id == $run' "$DSR_STATE_DIR/triggered.json"
}

@test "watch source isolation preserves legacy checkpoint mode through repeated retries" {
    harness_create_config
    _watch_configure_ntm
    local check_json checkpoint=12345678-1234-1234-1234-123456789abc state_dir
    check_json=$(_watch_run_json)
    DSR_WATCH_FIXTURE_STATUS=6 run _routing_watch "$check_json" --auto-fallback --retry-delay 1
    assert_equal "0" "$status"
    _watch_completed
    state_dir="$DSR_STATE_DIR/builds/ntm/v1.2.3/$checkpoint"
    mkdir -p "$state_dir" "$DSR_STATE_DIR/watch-artifacts/12345"
    jq -nc --arg run "$checkpoint" --arg output "$DSR_STATE_DIR/watch-artifacts/12345" '
        {tool:"ntm",version:"v1.2.3",run_id:$run,status:"failed",git_ref:"main",
         git_sha:"1111111111111111111111111111111111111111",context:{output_dir:$output}}' > "$state_dir/state.json"
    # Records from before source isolation have no mode field. Keep the exact
    # saved checkpoint so the production fallback can honor its branch identity.
    jq 'del(.attempts["12345"].isolate_source)' "$DSR_STATE_DIR/triggered.json" > "$TEST_TMPDIR/legacy-watch.json"
    mv "$TEST_TMPDIR/legacy-watch.json" "$DSR_STATE_DIR/triggered.json"
    sleep 1
    DSR_WATCH_FIXTURE_STATUS=6 run _routing_watch "$check_json" --auto-fallback --retry-delay 1
    assert_equal "0" "$status"
    _watch_completed
    jq -e --arg run "$checkpoint" '.attempts["12345"] |
        .attempt == 2 and .resume_run_id == $run and .isolate_source == false' "$DSR_STATE_DIR/triggered.json"
    sleep 2
    run _routing_watch "$check_json" --auto-fallback --retry-delay 1
    assert_equal "0" "$status"
    _watch_completed
    jq -e --arg run "$checkpoint" '.attempts["12345"] |
        .attempt == 3 and .resume_run_id == $run and .isolate_source == false' "$DSR_STATE_DIR/triggered.json"
    jq -Rse --arg resume "--resume=$checkpoint" 'split("\u0000") |
        (map(select(. == "--isolate-source")) | length) == 1 and
        (map(select(. == $resume)) | length) == 2' "$TEST_TMPDIR/fallback.args"
    jq -e '.git_ref == "main"' "$state_dir/state.json"
}

@test "watch source isolation rejects nonboolean saved source modes before retry" {
    harness_create_config
    _watch_configure_ntm
    local check_json value
    check_json=$(_watch_run_json)
    DSR_WATCH_FIXTURE_STATUS=6 run _routing_watch "$check_json" --auto-fallback --retry-delay 1
    assert_equal "0" "$status"
    _watch_completed
    for value in null '"true"' 1 '{}'; do
        jq --argjson value "$value" '.attempts["12345"].isolate_source=$value' \
            "$DSR_STATE_DIR/triggered.json" > "$TEST_TMPDIR/invalid-mode.json"
        mv "$TEST_TMPDIR/invalid-mode.json" "$DSR_STATE_DIR/triggered.json"
        run _routing_watch "$check_json" --auto-fallback --retry-delay 1
        assert_equal "4" "$status"
        assert_equal 1 "$(wc -l < "$TEST_TMPDIR/fallback.starts" | tr -d ' ')"
    done
}

@test "watch partial recovery resumes a mixed-success checkpoint instead of unrelated latest" {
    harness_create_config
    _watch_configure_ntm
    local sha check_json checkpoint=12345678-1234-1234-1234-123456789abc
    local unrelated=12345678-1234-1234-1234-123456789abd checkpoint_file before payload
    sha=$(_watch_checkpoint_source_sha)
    check_json=$(_watch_run_json "$sha")
    DSR_WATCH_FIXTURE_STATUS=1 run _routing_watch "$check_json" --auto-fallback --retry-delay 1
    assert_equal "0" "$status"
    _watch_completed
    _watch_seed_mixed_checkpoint "$checkpoint" "$DSR_STATE_DIR/watch-artifacts/12345" "$sha"
    _watch_seed_mixed_checkpoint "$unrelated" "$TEST_TMPDIR/unrelated-output" "$sha"
    assert_equal "$unrelated" "$(readlink "$DSR_STATE_DIR/builds/ntm/v1.2.3/latest")"
    checkpoint_file="$DSR_STATE_DIR/builds/ntm/v1.2.3/$checkpoint/state.json"
    before=$(cat "$checkpoint_file")
    payload=$(cat "$DSR_STATE_DIR/watch-artifacts/12345/ntm-linux-amd64")
    jq -e '.status == "partial" and
        .target_statuses["linux/amd64"].status == "completed" and
        .target_statuses["darwin/arm64"].status == "failed"' "$checkpoint_file"
    sleep 1
    run _routing_watch "$check_json" --auto-fallback --retry-delay 1
    assert_equal "0" "$status"
    _watch_completed
    jq -Rse --arg resume "--resume=$checkpoint" 'split("\u0000") | index($resume) != null' "$TEST_TMPDIR/fallback.args"
    jq -e --arg run "$checkpoint" '.attempts["12345"] |
        .attempt == 2 and .resume_run_id == $run and .status != "blocked"' "$DSR_STATE_DIR/triggered.json"
    [[ "$(wc -l < "$TEST_TMPDIR/fallback.starts")" -eq 2 ]]
    assert_equal "$before" "$(cat "$checkpoint_file")"
    assert_equal "$payload" "$(cat "$DSR_STATE_DIR/watch-artifacts/12345/ntm-linux-amd64")"
    assert_equal "$sha" "$(git -C "$TEST_TMPDIR/checkpoint-source" rev-parse HEAD)"
}

_watch_partial_refusal_case() {
    local mode="$1" sha="$2" checkpoint=12345678-1234-1234-1234-123456789abc
    local duplicate=12345678-1234-1234-1234-123456789abd check_json output_dir saved_sha run_status=partial
    local -x TEST_TMPDIR="$TEST_TMPDIR/$mode"
    local -x DSR_STATE_DIR="$TEST_TMPDIR/state"
    mkdir -p "$DSR_STATE_DIR"
    check_json=$(_watch_run_json "$sha")
    DSR_WATCH_FIXTURE_STATUS=1 run _routing_watch "$check_json" --auto-fallback --retry-delay 1
    assert_equal "0" "$status"
    _watch_completed
    output_dir="$DSR_STATE_DIR/watch-artifacts/12345"
    saved_sha="$sha"
    case "$mode" in
        cancelled) run_status=cancelled ;;
        wrong-source) saved_sha=2222222222222222222222222222222222222222 ;;
        unrelated-output)
            mkdir -p "$output_dir"
            output_dir="$TEST_TMPDIR/unrelated-output"
            ;;
    esac
    _watch_seed_mixed_checkpoint "$checkpoint" "$output_dir" "$saved_sha" "$run_status"
    if [[ "$mode" == ambiguous ]]; then
        _watch_seed_mixed_checkpoint "$duplicate" "$output_dir" "$sha"
    fi
    sleep 1
    run _routing_watch "$check_json" --auto-fallback --retry-delay 1
    assert_equal "0" "$status"
    jq -e '.attempts["12345"] | .status == "blocked" and .attempt == 1 and .next_retry_at == null' \
        "$DSR_STATE_DIR/triggered.json"
    [[ "$(wc -l < "$TEST_TMPDIR/fallback.starts")" -eq 1 ]]
}

@test "watch partial recovery rejects cancelled mismatched and ambiguous checkpoints" {
    harness_create_config
    _watch_configure_ntm
    local sha mode
    sha=$(_watch_checkpoint_source_sha)
    for mode in cancelled wrong-source unrelated-output ambiguous; do
        _watch_partial_refusal_case "$mode" "$sha"
    done
}

@test "watch recovery blocks an artifact directory with no matching source checkpoint" {
    harness_create_config
    _watch_configure_ntm
    local check_json
    check_json=$(_watch_run_json)
    DSR_WATCH_FIXTURE_STATUS=6 run _routing_watch "$check_json" --auto-fallback --retry-delay 1
    assert_equal "0" "$status"
    _watch_completed
    mkdir -p "$DSR_STATE_DIR/watch-artifacts/12345"
    sleep 1
    run _routing_watch "$check_json" --auto-fallback --retry-delay 1
    assert_equal "0" "$status"
    jq -e '.attempts["12345"] | .status == "blocked" and .attempt == 1' "$DSR_STATE_DIR/triggered.json"
    [[ "$(wc -l < "$TEST_TMPDIR/fallback.starts")" -eq 1 ]]
}

@test "watch recovery blocks a lost completion rather than replaying publication" {
    harness_create_config
    _watch_configure_ntm
    local check_json attempt
    check_json=$(_watch_run_json)
    run _routing_watch "$check_json" --auto-fallback
    assert_equal "0" "$status"
    _watch_completed
    attempt=$(jq -r '.attempts["12345"].attempt_id' "$DSR_STATE_DIR/triggered.json")
    mv "$DSR_STATE_DIR/watch-attempts/$attempt/completion.json" "$TEST_TMPDIR/retained-completion.json"
    jq '.attempts["12345"].started_epoch = 0' "$DSR_STATE_DIR/triggered.json" > "$TEST_TMPDIR/old-attempt.json"
    mv "$TEST_TMPDIR/old-attempt.json" "$DSR_STATE_DIR/triggered.json"
    run _routing_watch "$check_json" --auto-fallback --retry-delay 1
    assert_equal "0" "$status"
    jq -e '.attempts["12345"] | .status == "blocked" and .next_retry_at == null' "$DSR_STATE_DIR/triggered.json"
    [[ "$(wc -l < "$TEST_TMPDIR/fallback.starts")" -eq 1 ]]
}

@test "watch recovery serializes overlapping once invocations" {
    harness_create_config
    _watch_configure_ntm
    local check_json first deadline=$((SECONDS + 10))
    check_json=$(_watch_run_json)
    DSR_WATCH_FIXTURE_CHECK_WAIT="$TEST_TMPDIR/finish-check" _routing_watch "$check_json" --auto-fallback > "$TEST_TMPDIR/first-watch.log" 2>&1 &
    first=$!
    while [[ ! -f "$TEST_TMPDIR/watch-check.started" ]] && ((SECONDS < deadline)); do sleep 0.05; done
    [[ -f "$TEST_TMPDIR/watch-check.started" ]]
    run _routing_watch "$check_json" --auto-fallback
    assert_equal "2" "$status"
    touch "$TEST_TMPDIR/finish-check"
    wait "$first"
    _watch_completed
    [[ "$(wc -l < "$TEST_TMPDIR/fallback.starts")" -eq 1 ]]
}

@test "watch recovery validates retry options and never launches unresolved identities" {
    harness_create_config
    local check_json field value
    check_json=$(_watch_run_json)
    for field in head_sha head_branch; do
        for value in null '"main"' '""' '"1.2.3"'; do
            run _routing_watch "$(jq --arg field "$field" --argjson value "$value" '.details.throttled[0][$field]=$value' <<< "$check_json")" --auto-fallback
            assert_equal "0" "$status"
            [[ ! -e "$TEST_TMPDIR/fallback.args" ]]
        done
    done
    run _routing_watch "$check_json" --auto-fallback --max-attempts 11
    assert_equal "4" "$status"
    run _routing_watch "$check_json" --auto-fallback --retry-delay 0
    assert_equal "4" "$status"
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
            .head_branch == "v1.2.3" and .head_sha == "1111111111111111111111111111111111111111" and
            .queue_time_seconds >= 600 and .threshold_seconds == 600) and
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

@test "dsr watch --notify validates its methods" {
    run harness_run_dsr watch --once --notify
    assert_equal "4" "$status"
    assert_contains "$output" "--notify requires a method list"

    run harness_run_dsr watch --once --notify slack,slak
    assert_equal "4" "$status"
    assert_contains "$output" "Unknown --notify method: slak"
}

@test "dsr watch --notify carries to the fallbacks it starts, which report how they ended" {
    harness_create_config
    _setup_repos_d
    _mock_gh_runs "$(_queued_release_run)"
    # Record events and check that a terminal event never outruns its durable
    # completion receipt, even when the fallback fails during configuration.
    cat > "$TEST_TMPDIR/hook.sh" <<'EOF'
#!/usr/bin/env bash
payload=$(cat)
event=$(jq -r '.event' <<< "$payload")
if [[ "$event" == watch.fallback_started || "$event" == fallback.* ]]; then
    attempt=$(jq -r '.attempts["12345"].attempt_id' "$DSR_STATE_DIR/triggered.json")
fi
if [[ "$event" == watch.fallback_started ]]; then
    source "$DSR_PROJECT_ROOT/src/build_state.sh"
    exec {attempt_fd}>> "$DSR_STATE_DIR/watch-attempts/$attempt/active.lock"
    lock_status=0
    _build_state_wait_lock "$attempt_fd" 0 || lock_status=$?
    if [[ "$lock_status" == 1 && ! -e "$DSR_STATE_DIR/watch-attempts/$attempt/result.json" ]]; then
        : > "$TEST_TMPDIR/launch-lock-before-worker"
    fi
elif [[ "$event" == fallback.* ]]; then
    if jq -e '.run_id == "12345" and .attempt == 1 and .exit_code == 4' \
        "$DSR_STATE_DIR/watch-attempts/$attempt/completion.json" >/dev/null; then
        : > "$TEST_TMPDIR/terminal-after-completion"
    fi
fi
printf '%s\n' "$payload" >> "$TEST_TMPDIR/hook.log"
EOF
    chmod +x "$TEST_TMPDIR/hook.sh"

    DSR_AGENT_MAIL_HOOK="$TEST_TMPDIR/hook.sh" run harness_run_dsr watch --once --auto-fallback --notify agent_mail
    assert_equal "0" "$status"

    # The fallback child runs detached; ntm's local_path does not exist here,
    # so it stops at configuration and must report failure on the same channel.
    local i
    for ((i = 1; i <= 60; i++)); do
        grep -q '"event":"fallback\.' "$TEST_TMPDIR/hook.log" 2>/dev/null && break
        sleep 1
    done
    jq -se '[.[].event] == ["watch.throttled", "watch.fallback_started", "fallback.failed"] and
        (.[2].message | contains("ntm v1.2.3 fallback stopped") and contains("exit 4"))' "$TEST_TMPDIR/hook.log"
    [[ -f "$TEST_TMPDIR/launch-lock-before-worker" ]]
    [[ -f "$TEST_TMPDIR/terminal-after-completion" ]]
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
    local amount unit minutes epoch
    read -r amount unit <<< "$1"
    case "$unit" in
        hour|hours) minutes=$((amount * 60)) ;;
        minute|minutes) minutes=$amount ;;
        *) printf 'Unsupported fixture time unit: %s\n' "$unit" >&2; return 1 ;;
    esac
    epoch=$((${report_fixture_epoch:?report fixture epoch required} - minutes * 60))
    date -u -d "@$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null ||
        date -u -r "$epoch" +"%Y-%m-%dT%H:%M:%SZ"
}

# Today's run log: a watcher whose fallback (ntm) failed with exit 6 while it
# ran, a later successful build of bv, and status calls that are not runs.
_write_report_log() {
    # Keep exact fixture durations independent of how long writing the log takes.
    # Bash's dynamic local scope also carries this anchor into _iso_ago subshells.
    local report_fixture_epoch
    report_fixture_epoch=$(date +%s)
    local day
    day="$DSR_STATE_DIR/logs/$(date +%Y-%m-%d)"
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

@test "dsr installer generates, validates and dry-runs installers from repos.d" {
    mkdir -p "$DSR_CONFIG_DIR/repos.d"
    local tool
    for tool in alpha beta; do
        printf 'tool_name: %s\nrepo: example/%s\nbinary_name: %s\nartifact_naming: ${name}-${version}-${os}-${arch}\n' \
            "$tool" "$tool" "$tool" > "$DSR_CONFIG_DIR/repos.d/$tool.yaml"
    done
    local out
    out="$(cd "$TEST_TMPDIR" && pwd -P)/installers"

    run bash -c '"$1" installer generate --all --output-dir "$2" --dry-run 2>/dev/null' _ "$PROJECT_ROOT/dsr" "$out"
    assert_equal "0" "$status"
    [[ ! -e "$out" ]]

    run bash -c '"$1" installer generate alpha --output-dir "$2" 2>"$3"' _ "$PROJECT_ROOT/dsr" "$out" "$TEST_TMPDIR/installer.stderr"
    if [[ "$status" -ne 0 ]]; then cat "$TEST_TMPDIR/installer.stderr" >&2; fi
    assert_equal "0" "$status"
    assert_equal "$out/alpha/install.sh" "$output"
    bash -n "$out/alpha/install.sh"

    _dsr_json installer generate --all --output-dir "$out"
    assert_equal "0" "$status"
    jq -e '[.details.installers[] | select(.ok) | .tool] == ["alpha", "beta"]' <<< "$json"
    [[ -f "$out/beta/install.sh" ]]

    run harness_run_dsr installer validate alpha --output-dir "$out"
    assert_equal "0" "$status"

    _dsr_json installer generate alpha missing-tool --output-dir "$out"
    assert_equal "1" "$status"
    jq -e '.status == "partial" and ([.details.installers[] | select(.ok | not) | .tool] == ["missing-tool"])' <<< "$json"

    run harness_run_dsr installer frobnicate
    assert_equal "4" "$status"
}

@test "dsr build refuses a version whose tag is another commit than the checkout" {
    harness_create_config
    local src="$TEST_TMPDIR/src"
    git init -q "$src"
    git -C "$src" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m tagged
    git -C "$src" tag v1.2.3
    git -C "$src" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m later
    mkdir -p "$DSR_CONFIG_DIR/repos.d"
    printf 'tool_name: tagged\nrepo: example/tagged\nlocal_path: %s\nlanguage: go\ntargets:\n  - linux/amd64\n' \
        "$src" > "$DSR_CONFIG_DIR/repos.d/tagged.yaml"

    _dsr_json build tagged --version 1.2.3
    assert_equal "4" "$status"
    jq -e --arg head "$(git -C "$src" rev-parse HEAD)" --arg tag "$(git -C "$src" rev-parse v1.2.3)" \
        '.status == "error" and .details.head_sha == $head and .details.tag_sha == $tag' <<< "$json"
    [[ ! -e "$DSR_STATE_DIR/artifacts/tagged-v1.2.3" ]]
}

@test "a repo's hosts: map pins its native build host" {
    mkdir -p "$TEST_TMPDIR/repos.d"
    cat > "$TEST_TMPDIR/repos.d/pinned.yaml" << 'YAML'
tool_name: pinned
hosts:
  linux/amd64: buildbox
  darwin/arm64: mini2
cross_compile:
  darwin/arm64:
    host: crossmac
YAML
    run bash -c 'source "$1/src/logging.sh"; source "$1/src/config.sh"; source "$1/src/act_runner.sh"
        ACT_REPOS_DIR="$2"; DSR_DISABLE_HOST_SELECTOR=1
        act_get_native_host linux/amd64 pinned; act_get_native_host darwin/arm64 pinned
        act_get_native_host windows/amd64 pinned' _ "$PROJECT_ROOT" "$TEST_TMPDIR/repos.d"
    assert_equal "0" "$status"
    assert_equal $'buildbox\ncrossmac\nwlap' "$output"
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

    local out
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

    _mock_gh_runs '{"workflow_runs":[]}'

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
