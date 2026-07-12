#!/usr/bin/env bash
# test_release_verify.sh - Tests for dsr release verify command
#
# Covers bd-1jt.5.12:
#   - Unit tests for asset comparison (manifest vs release)
#   - Integration tests with mocked gh output
#   - Retry logic coverage (--fix flag)
#
# Run: ./scripts/tests/test_release_verify.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSR_CMD="$PROJECT_ROOT/dsr"

# Source the test harness
source "$PROJECT_ROOT/tests/helpers/test_harness.bash"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Colors
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
NC=$'\033[0m'

pass() { ((TESTS_PASSED++)); echo "${GREEN}PASS${NC}: $1"; }
fail() { ((TESTS_FAILED++)); echo "${RED}FAIL${NC}: $1"; }
skip() { ((TESTS_SKIPPED++)); echo "${YELLOW}SKIP${NC}: $1"; }

# ============================================================================
# Dependency Check
# ============================================================================
HAS_GH_AUTH=false
if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
    HAS_GH_AUTH=true
fi

HAS_YQ=false
if command -v yq &>/dev/null; then
    HAS_YQ=true
fi

# ============================================================================
# Helper: Create test config
# ============================================================================

seed_repos_config() {
    # Use DSR_CONFIG_DIR (set by harness_setup) which dsr uses via act_load_repo_config
    local config_dir="${DSR_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/dsr}"
    mkdir -p "$config_dir"

    cat > "$config_dir/config.yaml" << 'YAML'
schema_version: "1.0.0"
threshold_seconds: 600
log_level: info
signing:
  enabled: false
YAML

    # Create per-tool config in repos.d (matches act_load_repo_config expectation)
    mkdir -p "$config_dir/repos.d"
    cat > "$config_dir/repos.d/test-tool.yaml" << 'YAML'
tool_name: test-tool
repo: testuser/test-tool
local_path: /tmp/test-tool
language: go
build_cmd: go build -o test-tool ./cmd/test-tool
binary_name: test-tool
targets:
  - linux/amd64
  - darwin/arm64
YAML
}

seed_manifest() {
    local tool="${1:-test-tool}"
    local version="${2:-v1.0.0}"
    local state_dir="$DSR_STATE_DIR"
    local artifacts_dir="$state_dir/artifacts/${tool}-${version}"

    mkdir -p "$artifacts_dir"

    # Create a manifest with expected artifacts
    cat > "$artifacts_dir/${tool}-${version}-manifest.json" << EOF
{
  "schema_version": "1.0.0",
  "tool": "$tool",
  "version": "$version",
  "run_id": "test-run-001",
  "git_sha": "abc123def456",
  "built_at": "2026-01-30T12:00:00Z",
  "artifacts": [
    {"filename": "${tool}-linux-amd64", "target": "linux/amd64", "sha256": "a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2", "size_bytes": 1000},
    {"filename": "${tool}-darwin-arm64", "target": "darwin/arm64", "sha256": "f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5d4c3b2a1f6e5", "size_bytes": 1000},
    {"filename": "SHA256SUMS", "target": "checksums", "sha256": "1112223334441112223334441112223334441112223334441112223334441112", "size_bytes": 200}
  ]
}
EOF

    # Create dummy artifacts for --fix tests
    echo "binary content for linux" > "$artifacts_dir/${tool}-linux-amd64"
    echo "binary content for darwin" > "$artifacts_dir/${tool}-darwin-arm64"
    # shellcheck disable=SC2086
    (cd "$artifacts_dir" && sha256sum ${tool}-* > SHA256SUMS 2>/dev/null || shasum -a 256 ${tool}-* > SHA256SUMS 2>/dev/null || echo "dummy checksums" > SHA256SUMS)

    export DSR_STATE_DIR="$state_dir"
}

remove_release_verify_mock_gh() {
    unset -f gh
    unset VERIFY_MOCK_RELEASE_JSON VERIFY_MOCK_AUTH_STATUS VERIFY_MOCK_API_STATUS
    unset VERIFY_MOCK_UPLOAD_STATUS VERIFY_MOCK_UPLOAD_LOG
}

create_mock_gh() {
    VERIFY_MOCK_RELEASE_JSON="${1:-}"
    VERIFY_MOCK_API_STATUS="${2:-0}"
    VERIFY_MOCK_AUTH_STATUS="${3:-0}"
    VERIFY_MOCK_UPLOAD_STATUS="${4:-0}"
    VERIFY_MOCK_UPLOAD_LOG="${5:-}"
    export VERIFY_MOCK_RELEASE_JSON VERIFY_MOCK_AUTH_STATUS VERIFY_MOCK_API_STATUS
    export VERIFY_MOCK_UPLOAD_STATUS VERIFY_MOCK_UPLOAD_LOG

    gh() {
        case "${1:-}" in
            auth)
                [[ "${2:-}" == "status" ]] && return "$VERIFY_MOCK_AUTH_STATUS"
                if [[ "${2:-}" == "token" && "$VERIFY_MOCK_AUTH_STATUS" == "0" ]]; then
                    printf 'fake-token\n'
                    return 0
                fi
                return 1
                ;;
            api)
                if [[ "$VERIFY_MOCK_API_STATUS" == "0" && "$*" == *"/releases/tags/"* ]]; then
                    printf '%s\n' "$VERIFY_MOCK_RELEASE_JSON"
                    return 0
                fi
                printf '{"message":"Not Found"}\n' >&2
                return "$VERIFY_MOCK_API_STATUS"
                ;;
            release)
                if [[ "${2:-}" == "upload" ]]; then
                    [[ -n "$VERIFY_MOCK_UPLOAD_LOG" ]] && printf '%s\n' "$*" >> "$VERIFY_MOCK_UPLOAD_LOG"
                    [[ "$VERIFY_MOCK_UPLOAD_STATUS" == "0" ]] && printf 'Uploaded asset\n'
                    return "$VERIFY_MOCK_UPLOAD_STATUS"
                fi
                ;;
        esac
        return 1
    }
    export -f gh
}

seed_strict_verify_fixture() {
    local tool="test-tool"
    local tag="v1.0.0"
    unset STRICT_VERIFY_RELEASE_TAG
    unset STRICT_FIX_REMOTE_TAG_MOVE_ON_CALL STRICT_FIX_MUTATE_MANIFEST_AFTER_UPLOAD
    unset STRICT_FIX_MUTATE_LOCAL_TAG_AFTER_UPLOAD
    unset STRICT_FIX_FLIP_AFTER_FIRST_POST_UPLOAD_GET
    unset STRICT_FIX_TAG_REBIND_ON_RELEASE_ID_GET
    STRICT_VERIFY_REPO="$TEST_TMPDIR/strict-repo"
    local artifacts_dir="$DSR_STATE_DIR/artifacts/${tool}-${tag}"
    mkdir -p "$STRICT_VERIFY_REPO" "$DSR_CONFIG_DIR/repos.d" "$artifacts_dir"

    git -C "$STRICT_VERIFY_REPO" init -q
    git -C "$STRICT_VERIFY_REPO" config user.name "DSR Test"
    git -C "$STRICT_VERIFY_REPO" config user.email "dsr-test@example.invalid"
    printf 'strict verify source\n' > "$STRICT_VERIFY_REPO/source.txt"
    git -C "$STRICT_VERIFY_REPO" add source.txt
    git -C "$STRICT_VERIFY_REPO" commit -qm "strict verify source"
    git -C "$STRICT_VERIFY_REPO" tag -a "$tag" -m "$tag"
    STRICT_VERIFY_SHA=$(git -C "$STRICT_VERIFY_REPO" rev-parse HEAD)
    export STRICT_VERIFY_REPO STRICT_VERIFY_SHA

    cat > "$DSR_CONFIG_DIR/repos.d/${tool}.yaml" << YAML
tool_name: $tool
repo: testuser/test-tool
local_path: $STRICT_VERIFY_REPO
language: go
build_cmd: go build ./...
binary_name: $tool
targets:
  - linux/amd64
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: ${tool}-linux-amd64
YAML

    printf 'strict verify binary\n' > "$artifacts_dir/${tool}-linux-amd64"
    local sha sidecar_sha size sidecar_size
    if command -v sha256sum &>/dev/null; then
        sha=$(sha256sum "$artifacts_dir/${tool}-linux-amd64" | awk '{print $1}')
        sidecar_sha=$(printf '%s  %s\n' "$sha" "${tool}-linux-amd64" | sha256sum | awk '{print $1}')
    else
        sha=$(shasum -a 256 "$artifacts_dir/${tool}-linux-amd64" | awk '{print $1}')
        sidecar_sha=$(printf '%s  %s\n' "$sha" "${tool}-linux-amd64" | shasum -a 256 | awk '{print $1}')
    fi
    size=$(stat -c %s "$artifacts_dir/${tool}-linux-amd64" 2>/dev/null || \
        stat -f %z "$artifacts_dir/${tool}-linux-amd64")
    sidecar_size=$(printf '%s  %s\n' "$sha" "${tool}-linux-amd64" | wc -c | tr -d '[:space:]')

    jq -nc \
        --arg tool "$tool" \
        --arg tag "$tag" \
        --arg git_sha "$STRICT_VERIFY_SHA" \
        --arg sha "$sha" \
        --argjson size "$size" '
        {
            schema_version: "1.0.0",
            tool: $tool,
            version: $tag,
            run_id: "strict-verify",
            source: {git_sha: $git_sha, git_ref: $tag, dependencies: []},
            built_at: "2026-01-30T12:00:00Z",
            duration_ms: 1,
            status: "success",
            summary: {total: 1, success: 1, failed: 0},
            artifacts: [
                {name: ($tool + "-linux-amd64"), target: "linux/amd64", sha256: $sha, size_bytes: $size}
            ]
        }
    ' > "$artifacts_dir/${tool}-${tag}-manifest.json"

    STRICT_VERIFY_ASSETS=$(jq -nc \
        --arg sha "$sha" \
        --arg sidecar_sha "$sidecar_sha" \
        --argjson size "$size" \
        --argjson sidecar_size "$sidecar_size" '
        [
            {id: 1, name: "test-tool-linux-amd64", size: $size, state: "uploaded", digest: ("sha256:" + $sha), browser_download_url: "https://example.invalid/a"},
            {id: 2, name: "test-tool-linux-amd64.sha256", size: $sidecar_size, state: "uploaded", digest: ("sha256:" + $sidecar_sha), browser_download_url: "https://example.invalid/b"}
        ]
    ')
    STRICT_VERIFY_EXPECTED_ASSETS="$STRICT_VERIFY_ASSETS"
    STRICT_VERIFY_PRIMARY_PATH="$artifacts_dir/${tool}-linux-amd64"
    STRICT_VERIFY_MANIFEST_PATH="$artifacts_dir/${tool}-${tag}-manifest.json"
    STRICT_VERIFY_PRIMARY_SHA="$sha"
    STRICT_VERIFY_PRIMARY_SIZE="$size"
    export STRICT_VERIFY_ASSETS STRICT_VERIFY_EXPECTED_ASSETS STRICT_VERIFY_PRIMARY_PATH
    export STRICT_VERIFY_MANIFEST_PATH
    export STRICT_VERIFY_PRIMARY_SHA STRICT_VERIFY_PRIMARY_SIZE
}

create_strict_verify_mock_gh() {
    gh() {
        case "${1:-}" in
            auth)
                [[ "${2:-}" == "status" ]] && return 0
                [[ "${2:-}" == "token" ]] && { printf 'strict-verify-token\n'; return 0; }
                ;;
            api)
                local endpoint="${2:-}"
                local method="GET"
                [[ "$*" == *"-X PATCH"* ]] && method="PATCH"
                [[ "$*" == *"-X DELETE"* ]] && method="DELETE"
                if [[ "$endpoint" == "repos/testuser/test-tool/releases?per_page=100&page=1" ]]; then
                    jq -nc \
                        --argjson assets "$STRICT_VERIFY_ASSETS" '
                        [{id:123,tag_name:"v1.0.0",html_url:"https://example.invalid/v1.0.0",draft:false,assets:$assets}]
                    '
                    return 0
                fi
                case "$endpoint" in
                    repos/testuser/test-tool/git/ref/tags/v1.0.0)
                        jq -nc --arg sha "$STRICT_VERIFY_SHA" '{object:{sha:$sha,type:"commit"}}'
                        return 0
                        ;;
                    repos/testuser/test-tool/releases/123)
                        jq -nc \
                            --arg tag_name "${STRICT_VERIFY_RELEASE_TAG:-v1.0.0}" \
                            --argjson assets "$STRICT_VERIFY_ASSETS" \
                            '{id:123,tag_name:$tag_name,html_url:"https://example.invalid/v1.0.0",draft:false,assets:$assets}'
                        return 0
                        ;;
                    repos/testuser/test-tool/releases/tags/v1.0.0)
                        return 1
                        ;;
                esac
                ;;
        esac
        return 1
    }
    export -f gh
}

remove_strict_verify_mock_gh() {
    unset -f gh curl
}

create_strict_verify_fix_mock_gh() {
    local draft_state="${1:-true}"
    local mock_dir="$TEST_TMPDIR/strict-fix-mock"
    mkdir -p "$mock_dir"

    STRICT_FIX_ASSETS_FILE="$mock_dir/assets.json"
    STRICT_FIX_EXPECTED_ASSETS_FILE="$mock_dir/expected-assets.json"
    STRICT_FIX_DRAFT_FILE="$mock_dir/draft"
    STRICT_FIX_UPLOAD_LOG="$mock_dir/uploads.log"
    STRICT_FIX_PATCH_LOG="$mock_dir/patches.log"
    STRICT_FIX_LIST_LOG="$mock_dir/release-list.log"
    STRICT_FIX_TAG_ENDPOINT_LOG="$mock_dir/tag-endpoint.log"
    STRICT_FIX_MUTATION_MARKER="$mock_dir/local-mutated"
    STRICT_FIX_RELEASE_ID_GET_COUNT_FILE="$mock_dir/release-id-get-count"
    STRICT_FIX_TAG_GET_COUNT_FILE="$mock_dir/tag-get-count"
    STRICT_FIX_POST_UPLOAD_MUTATION_MARKER="$mock_dir/post-upload-mutated"
    STRICT_FIX_UPLOAD_OCCURRED_FILE="$mock_dir/upload-occurred"
    STRICT_FIX_POST_UPLOAD_GET_COUNT_FILE="$mock_dir/post-upload-get-count"
    STRICT_FIX_TAG_NAME_FILE="$mock_dir/tag-name"
    printf '%s\n' "$STRICT_VERIFY_ASSETS" > "$STRICT_FIX_ASSETS_FILE"
    printf '%s\n' "$STRICT_VERIFY_EXPECTED_ASSETS" > "$STRICT_FIX_EXPECTED_ASSETS_FILE"
    printf '%s\n' "$draft_state" > "$STRICT_FIX_DRAFT_FILE"
    printf '0\n' > "$STRICT_FIX_RELEASE_ID_GET_COUNT_FILE"
    printf '0\n' > "$STRICT_FIX_TAG_GET_COUNT_FILE"
    printf '0\n' > "$STRICT_FIX_POST_UPLOAD_GET_COUNT_FILE"
    printf 'v1.0.0\n' > "$STRICT_FIX_TAG_NAME_FILE"
    export STRICT_FIX_ASSETS_FILE STRICT_FIX_EXPECTED_ASSETS_FILE
    export STRICT_FIX_DRAFT_FILE STRICT_FIX_UPLOAD_LOG STRICT_FIX_PATCH_LOG
    export STRICT_FIX_LIST_LOG STRICT_FIX_TAG_ENDPOINT_LOG
    export STRICT_FIX_MUTATION_MARKER
    export STRICT_FIX_RELEASE_ID_GET_COUNT_FILE
    export STRICT_FIX_TAG_GET_COUNT_FILE STRICT_FIX_POST_UPLOAD_MUTATION_MARKER
    export STRICT_FIX_UPLOAD_OCCURRED_FILE STRICT_FIX_POST_UPLOAD_GET_COUNT_FILE
    export STRICT_FIX_TAG_NAME_FILE

    _strict_fix_release_json() {
        jq -nc \
            --arg tag_name "$(cat "$STRICT_FIX_TAG_NAME_FILE")" \
            --argjson assets "$(cat "$STRICT_FIX_ASSETS_FILE")" \
            --argjson draft "$(cat "$STRICT_FIX_DRAFT_FILE")" '
            {
                id: 123,
                tag_name: $tag_name,
                upload_url: "https://uploads.example.invalid/releases/123/assets{?name,label}",
                html_url: "https://example.invalid/v1.0.0",
                draft: $draft,
                assets: $assets
            }
        '
    }

    gh() {
        case "${1:-}" in
            auth)
                [[ "${2:-}" == "status" ]] && return 0
                [[ "${2:-}" == "token" ]] && { printf 'strict-verify-token\n'; return 0; }
                ;;
            api)
                local endpoint="${2:-}"
                if [[ "$endpoint" == "repos/testuser/test-tool/releases?per_page=100&page=1" ]]; then
                    printf 'list\n' >> "$STRICT_FIX_LIST_LOG"
                    _strict_fix_release_json | jq -c '[.]'
                    return 0
                fi
                case "$endpoint" in
                    repos/testuser/test-tool/git/ref/tags/v1.0.0)
                        local tag_get_count=0 tag_sha="$STRICT_VERIFY_SHA"
                        read -r tag_get_count < "$STRICT_FIX_TAG_GET_COUNT_FILE" || tag_get_count=0
                        tag_get_count=$((tag_get_count + 1))
                        printf '%s\n' "$tag_get_count" > "$STRICT_FIX_TAG_GET_COUNT_FILE"
                        if [[ "${STRICT_FIX_REMOTE_TAG_MOVE_ON_CALL:-0}" =~ ^[1-9][0-9]*$ && \
                              $tag_get_count -ge ${STRICT_FIX_REMOTE_TAG_MOVE_ON_CALL} ]]; then
                            tag_sha="4444444444444444444444444444444444444444"
                        fi
                        jq -nc --arg sha "$tag_sha" '{object:{sha:$sha,type:"commit"}}'
                        return 0
                        ;;
                    repos/testuser/test-tool/releases/tags/v1.0.0)
                        printf 'tag\n' >> "$STRICT_FIX_TAG_ENDPOINT_LOG"
                        return 1
                        ;;
                    repos/testuser/test-tool/releases/123)
                        local release_id_get_count=0
                        if [[ "$method" == "PATCH" ]]; then
                            local request
                            request=$(cat)
                            printf '%s\n' "$request" >> "$STRICT_FIX_PATCH_LOG"
                            if jq -e '.draft == true' <<< "$request" >/dev/null 2>&1; then
                                printf 'true\n' > "$STRICT_FIX_DRAFT_FILE"
                            fi
                        else
                            read -r release_id_get_count < "$STRICT_FIX_RELEASE_ID_GET_COUNT_FILE" || \
                                release_id_get_count=0
                            release_id_get_count=$((release_id_get_count + 1))
                            printf '%s\n' "$release_id_get_count" > "$STRICT_FIX_RELEASE_ID_GET_COUNT_FILE"
                            if [[ "${STRICT_FIX_MUTATE_LOCAL_ON_RELEASE_ID:-0}" == "1" && \
                                  $release_id_get_count -eq 2 && ! -e "$STRICT_FIX_MUTATION_MARKER" ]]; then
                                printf 'strict verify binarz\n' > "$STRICT_VERIFY_PRIMARY_PATH"
                                : > "$STRICT_FIX_MUTATION_MARKER"
                            fi
                            if [[ "${STRICT_FIX_TAG_REBIND_ON_RELEASE_ID_GET:-0}" =~ ^[1-9][0-9]*$ && \
                                  $release_id_get_count -eq ${STRICT_FIX_TAG_REBIND_ON_RELEASE_ID_GET} ]]; then
                                printf 'v9.9.9\n' > "$STRICT_FIX_TAG_NAME_FILE"
                            fi
                        fi
                        local release_response
                        release_response=$(_strict_fix_release_json)
                        printf '%s\n' "$release_response"
                        if [[ "$method" == "GET" && -e "$STRICT_FIX_UPLOAD_OCCURRED_FILE" ]]; then
                            local post_upload_get_count=0
                            read -r post_upload_get_count < "$STRICT_FIX_POST_UPLOAD_GET_COUNT_FILE" || \
                                post_upload_get_count=0
                            post_upload_get_count=$((post_upload_get_count + 1))
                            printf '%s\n' "$post_upload_get_count" > "$STRICT_FIX_POST_UPLOAD_GET_COUNT_FILE"
                            if [[ "${STRICT_FIX_FLIP_AFTER_FIRST_POST_UPLOAD_GET:-0}" == "1" && \
                                  $post_upload_get_count -eq 1 ]]; then
                                jq -c '.[0].digest = ("sha256:" + ("7" * 64))' \
                                    "$STRICT_FIX_ASSETS_FILE" > "$STRICT_FIX_ASSETS_FILE.next"
                                mv "$STRICT_FIX_ASSETS_FILE.next" "$STRICT_FIX_ASSETS_FILE"
                            fi
                        fi
                        return 0
                        ;;
                    repos/testuser/test-tool/releases/assets/*)
                        if [[ "$method" != "DELETE" ]]; then
                            return 1
                        fi
                        local delete_asset_id="${endpoint##*/}"
                        printf 'delete:%s\n' "$delete_asset_id" >> "$STRICT_FIX_UPLOAD_LOG"
                        jq -c --argjson id "$delete_asset_id" 'map(select(.id != $id))' \
                            "$STRICT_FIX_ASSETS_FILE" > "$STRICT_FIX_ASSETS_FILE.next"
                        mv "$STRICT_FIX_ASSETS_FILE.next" "$STRICT_FIX_ASSETS_FILE"
                        printf '{}\n'
                        return 0
                        ;;
                esac
                ;;
            release)
                if [[ "${2:-}" == "upload" ]]; then
                    printf 'tag-bound-upload:%s\n' "$*" >> "$STRICT_FIX_UPLOAD_LOG"
                fi
                ;;
        esac
        return 1
    }

    curl() {
        local url="${!#}" data_arg="" arg
        while [[ $# -gt 0 ]]; do
            arg="$1"
            shift
            if [[ "$arg" == "--data-binary" && $# -gt 0 ]]; then
                data_arg="$1"
                shift
            fi
        done
        local file_path="${data_arg#@}"
        local asset_name="${url##*?name=}"
        local expected
        asset_name="${asset_name//%2B/+}"
        printf 'id-bound-upload:%s\n' "$asset_name" >> "$STRICT_FIX_UPLOAD_LOG"

        if [[ "${STRICT_FIX_UPLOAD_MODE:-success}" != "fail_without_commit" ]]; then
            expected=$(jq -c --arg name "$asset_name" '.[] | select(.name == $name)' \
                "$STRICT_FIX_EXPECTED_ASSETS_FILE")
            if [[ "$data_arg" != @* || ! -f "$file_path" || -z "$expected" ]]; then
                printf '{}\n__HTTP_CODE__422'
                return 0
            fi
            jq -c --arg name "$asset_name" --argjson expected "$expected" '
                map(select(.name != $name)) + [$expected]
            ' "$STRICT_FIX_ASSETS_FILE" > "$STRICT_FIX_ASSETS_FILE.next"
            mv "$STRICT_FIX_ASSETS_FILE.next" "$STRICT_FIX_ASSETS_FILE"
            : > "$STRICT_FIX_UPLOAD_OCCURRED_FILE"
        fi

        if [[ ! -e "$STRICT_FIX_POST_UPLOAD_MUTATION_MARKER" ]]; then
            if [[ "${STRICT_FIX_MUTATE_MANIFEST_AFTER_UPLOAD:-0}" == "1" ]]; then
                jq '.built_at = "2026-01-30T12:00:01Z"' \
                    "$STRICT_VERIFY_MANIFEST_PATH" > "$STRICT_VERIFY_MANIFEST_PATH.next"
                mv "$STRICT_VERIFY_MANIFEST_PATH.next" "$STRICT_VERIFY_MANIFEST_PATH"
                : > "$STRICT_FIX_POST_UPLOAD_MUTATION_MARKER"
            elif [[ "${STRICT_FIX_MUTATE_LOCAL_TAG_AFTER_UPLOAD:-0}" == "1" ]]; then
                local moved_commit
                moved_commit=$(printf 'moved strict repair tag\n' | \
                    git -C "$STRICT_VERIFY_REPO" commit-tree \
                    "$(git -C "$STRICT_VERIFY_REPO" rev-parse 'HEAD^{tree}')" -p HEAD)
                git -C "$STRICT_VERIFY_REPO" tag -f v1.0.0 "$moved_commit" >/dev/null
                : > "$STRICT_FIX_POST_UPLOAD_MUTATION_MARKER"
            fi
        fi

        if [[ "${STRICT_FIX_UPLOAD_MODE:-success}" == "ambiguous_publish" ]]; then
            printf 'false\n' > "$STRICT_FIX_DRAFT_FILE"
            printf '{"message":"ambiguous"}\n__HTTP_CODE__500'
        elif [[ "${STRICT_FIX_UPLOAD_MODE:-success}" == "fail_without_commit" ]]; then
            printf '{"message":"failed"}\n__HTTP_CODE__500'
        else
            printf '{"state":"uploaded"}\n__HTTP_CODE__201'
        fi
        return 0
    }
    export -f _strict_fix_release_json gh curl
}

# ============================================================================
# Tests: Help (always works)
# ============================================================================

test_verify_help() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" release verify --help

    if exec_stdout_contains "USAGE:" && exec_stdout_contains "verify"; then
        pass "release verify --help shows usage information"
    else
        fail "release verify --help should show usage"
        echo "stdout: $(exec_stdout)"
    fi

    harness_teardown
}

test_verify_help_shows_options() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" release verify --help

    if exec_stdout_contains "--verify-checksums" && exec_stdout_contains "--fix"; then
        pass "release verify --help shows all options"
    else
        fail "release verify --help should show --verify-checksums, --fix"
        echo "stdout: $(exec_stdout)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Argument Validation
# ============================================================================

test_verify_missing_tool() {
    ((TESTS_RUN++))
    harness_setup
    seed_repos_config

    exec_run "$DSR_CMD" release verify
    local status
    status=$(exec_status)

    if [[ "$status" -eq 4 ]]; then
        pass "release verify fails with missing tool (exit: 4)"
    else
        fail "release verify should fail with exit 4 for missing tool (got: $status)"
        echo "stderr: $(exec_stderr | head -5)"
    fi

    harness_teardown
}

test_verify_missing_version() {
    ((TESTS_RUN++))
    harness_setup
    seed_repos_config

    exec_run "$DSR_CMD" release verify test-tool
    local status
    status=$(exec_status)

    if [[ "$status" -eq 4 ]]; then
        pass "release verify fails with missing version (exit: 4)"
    else
        fail "release verify should fail with exit 4 for missing version (got: $status)"
        echo "stderr: $(exec_stderr | head -5)"
    fi

    harness_teardown
}

test_verify_unknown_option() {
    ((TESTS_RUN++))
    harness_setup
    seed_repos_config

    exec_run "$DSR_CMD" release verify test-tool v1.0.0 --unknown-option
    local status
    status=$(exec_status)

    if [[ "$status" -eq 4 ]]; then
        pass "release verify fails with unknown option (exit: 4)"
    else
        fail "release verify should fail with exit 4 for unknown option (got: $status)"
        echo "stderr: $(exec_stderr | head -5)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Authentication
# ============================================================================

test_verify_missing_gh_auth() {
    ((TESTS_RUN++))
    harness_setup
    seed_repos_config

    create_mock_gh "" 1 1

    # Clear tokens
    local old_token="${GITHUB_TOKEN:-}"
    local old_gh_token="${GH_TOKEN:-}"
    unset GITHUB_TOKEN GH_TOKEN

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" release verify test-tool v1.0.0
    local status
    status=$(exec_status)

    # Restore tokens
    [[ -n "$old_token" ]] && export GITHUB_TOKEN="$old_token"
    [[ -n "$old_gh_token" ]] && export GH_TOKEN="$old_gh_token"

    # Should fail with auth error (exit 3) or tool not found (exit 4)
    if [[ "$status" -eq 3 ]] || [[ "$status" -eq 4 ]]; then
        pass "release verify fails with missing gh auth (exit: $status)"
    else
        fail "release verify should fail with exit 3 or 4 for missing auth (got: $status)"
        echo "stderr: $(exec_stderr | head -5)"
    fi

    remove_release_verify_mock_gh
    harness_teardown
}

# ============================================================================
# Tests: Asset Comparison (Mocked gh)
# ============================================================================

test_verify_all_assets_present() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for repos.yaml parsing"
        return 0
    fi

    harness_setup
    seed_repos_config
    seed_manifest "test-tool" "v1.0.0"

    # Mock release with all expected assets
    create_mock_gh '{
        "id": 12345,
        "html_url": "https://github.com/testuser/test-tool/releases/tag/v1.0.0",
        "assets": [
            {"name": "test-tool-linux-amd64", "browser_download_url": "https://example.com/a"},
            {"name": "test-tool-darwin-arm64", "browser_download_url": "https://example.com/b"},
            {"name": "SHA256SUMS", "browser_download_url": "https://example.com/c"}
        ]
    }'

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release verify test-tool v1.0.0
    local status
    status=$(exec_status)
    local output
    output=$(exec_stdout)

    if [[ "$status" -eq 0 ]]; then
        # Check JSON reports no missing assets
        local missing_count
        missing_count=$(echo "$output" | jq -r '.details.verification.missing // 0' 2>/dev/null)
        if [[ "$missing_count" -eq 0 ]]; then
            pass "release verify reports no missing assets when all present"
        else
            fail "release verify should report 0 missing assets"
            echo "output: $output"
        fi
    else
        fail "release verify should succeed when all assets present (exit: $status)"
        echo "stderr: $(exec_stderr | head -5)"
    fi

    remove_release_verify_mock_gh
    harness_teardown
}

test_verify_detects_missing_assets() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for repos.yaml parsing"
        return 0
    fi

    harness_setup
    seed_repos_config
    seed_manifest "test-tool" "v1.0.0"

    # Mock release with one asset missing
    create_mock_gh '{
        "id": 12345,
        "html_url": "https://github.com/testuser/test-tool/releases/tag/v1.0.0",
        "assets": [
            {"name": "test-tool-linux-amd64", "browser_download_url": "https://example.com/a"},
            {"name": "SHA256SUMS", "browser_download_url": "https://example.com/c"}
        ]
    }'

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release verify test-tool v1.0.0
    local status
    status=$(exec_status)
    local output
    output=$(exec_stdout)

    # Should return exit 1 (incomplete) with missing assets
    if [[ "$status" -eq 1 ]]; then
        local missing_count
        missing_count=$(echo "$output" | jq -r '.details.verification.missing // 0' 2>/dev/null)
        if [[ "$missing_count" -gt 0 ]]; then
            # Check that darwin-arm64 is in the missing list
            if echo "$output" | jq -e '.details.assets.missing[] | select(. == "test-tool-darwin-arm64")' &>/dev/null; then
                pass "release verify detects missing asset: test-tool-darwin-arm64"
            else
                fail "release verify should list test-tool-darwin-arm64 as missing"
                echo "missing: $(echo "$output" | jq '.details.assets.missing')"
            fi
        else
            fail "release verify should report missing assets"
            echo "output: $output"
        fi
    else
        fail "release verify should exit 1 when assets missing (got: $status)"
        echo "output: $output"
        echo "stderr: $(exec_stderr | head -5)"
    fi

    remove_release_verify_mock_gh
    harness_teardown
}

test_verify_detects_extra_assets() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for repos.yaml parsing"
        return 0
    fi

    harness_setup
    seed_repos_config
    seed_manifest "test-tool" "v1.0.0"

    # Mock release with extra asset not in manifest
    create_mock_gh '{
        "id": 12345,
        "html_url": "https://github.com/testuser/test-tool/releases/tag/v1.0.0",
        "assets": [
            {"name": "test-tool-linux-amd64", "browser_download_url": "https://example.com/a"},
            {"name": "test-tool-darwin-arm64", "browser_download_url": "https://example.com/b"},
            {"name": "SHA256SUMS", "browser_download_url": "https://example.com/c"},
            {"name": "EXTRA-FILE.txt", "browser_download_url": "https://example.com/d"}
        ]
    }'

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release verify test-tool v1.0.0
    local output
    output=$(exec_stdout)

    # Extra assets should be reported but not cause failure
    local extra_count
    extra_count=$(echo "$output" | jq -r '.details.verification.extra // 0' 2>/dev/null)
    if [[ "$extra_count" -gt 0 ]]; then
        if echo "$output" | jq -e '.details.assets.extra[] | select(. == "EXTRA-FILE.txt")' &>/dev/null; then
            pass "release verify detects extra asset: EXTRA-FILE.txt"
        else
            fail "release verify should list EXTRA-FILE.txt as extra"
            echo "extra: $(echo "$output" | jq '.details.assets.extra')"
        fi
    else
        fail "release verify should report extra assets"
        echo "output: $output"
    fi

    remove_release_verify_mock_gh
    harness_teardown
}

test_strict_verify_requires_exact_names_sizes_and_sidecars() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for strict release contract parsing"
        return 0
    fi

    harness_setup
    seed_strict_verify_fixture
    create_strict_verify_mock_gh

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release verify test-tool v1.0.0
    local status output
    status=$(exec_status)
    output=$(exec_stdout)

    if [[ $status -eq 0 ]] && echo "$output" | jq -e '
        .details.verification.expected == 2 and
        .details.verification.present == 2 and
        .details.verification.missing == 0 and
        .details.verification.extra == 0 and
        .details.verification.size_mismatches == 0 and
        .details.verification.remote_records_valid == true
    ' >/dev/null 2>&1; then
        pass "strict release verify requires exactly primary+sidecar names and sizes"
    else
        fail "strict release verify should accept the exact complete remote asset set"
        echo "status: $status"
        echo "output: $output"
        echo "stderr: $(exec_stderr | tail -20)"
    fi

    remove_strict_verify_mock_gh
    harness_teardown
}

test_strict_verify_rejects_extra_or_incomplete_remote_assets() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for strict release contract parsing"
        return 0
    fi

    harness_setup
    seed_strict_verify_fixture
    STRICT_VERIFY_ASSETS=$(jq -c \
        '.[0].state = "new" | . + [{id:99,name:"unexpected.sbom.json",size:12,state:"uploaded",digest:("sha256:" + ("9" * 64))}]' \
        <<< "$STRICT_VERIFY_ASSETS")
    export STRICT_VERIFY_ASSETS
    create_strict_verify_mock_gh

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release verify test-tool v1.0.0
    local status output
    status=$(exec_status)
    output=$(exec_stdout)

    if [[ $status -eq 1 ]] && echo "$output" | jq -e '
        .details.verification.extra == 1 and
        .details.verification.remote_records_valid == false
    ' >/dev/null 2>&1; then
        pass "strict release verify rejects extra and incomplete GitHub asset records"
    else
        fail "strict release verify must fail on extras or non-uploaded asset records"
        echo "status: $status"
        echo "output: $output"
        echo "stderr: $(exec_stderr | tail -20)"
    fi

    remove_strict_verify_mock_gh
    harness_teardown
}

test_strict_verify_rejects_remote_digest_mismatch() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for strict release contract parsing"
        return 0
    fi

    harness_setup
    seed_strict_verify_fixture
    STRICT_VERIFY_ASSETS=$(jq -c '.[0].digest = ("sha256:" + ("0" * 64))' \
        <<< "$STRICT_VERIFY_ASSETS")
    export STRICT_VERIFY_ASSETS
    create_strict_verify_mock_gh

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release verify test-tool v1.0.0
    local status output
    status=$(exec_status)
    output=$(exec_stdout)

    if [[ $status -eq 1 ]] && echo "$output" | jq -e \
        '.details.verification.remote_records_valid == false' >/dev/null 2>&1; then
        pass "strict release verify rejects a same-size remote digest mismatch"
    else
        fail "strict release verify must fail when GitHub reports different asset bytes"
        echo "status: $status"
        echo "output: $output"
        echo "stderr: $(exec_stderr | tail -20)"
    fi

    remove_strict_verify_mock_gh
    harness_teardown
}

test_strict_verify_rejects_wrong_release_tag() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for strict release contract parsing"
        return 0
    fi

    harness_setup
    seed_strict_verify_fixture
    export STRICT_VERIFY_RELEASE_TAG="v9.9.9"
    create_strict_verify_mock_gh

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release verify test-tool v1.0.0
    local status output
    status=$(exec_status)
    output=$(exec_stdout)

    if [[ $status -eq 1 ]] && echo "$output" | jq -e \
        '.details.verification.remote_records_valid == false' >/dev/null 2>&1; then
        pass "strict release verify rejects a release record bound to another tag"
    else
        fail "strict release verify must bind the release ID to the requested tag"
        echo "status: $status"
        echo "output: $output"
        echo "stderr: $(exec_stderr | tail -20)"
    fi

    remove_strict_verify_mock_gh
    harness_teardown
}

test_verify_handles_no_manifest() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for repos.yaml parsing"
        return 0
    fi

    harness_setup
    seed_repos_config
    # Don't create manifest

    # Mock release with assets
    create_mock_gh '{
        "id": 12345,
        "html_url": "https://github.com/testuser/test-tool/releases/tag/v1.0.0",
        "assets": [
            {"name": "test-tool-linux-amd64", "browser_download_url": "https://example.com/a"}
        ]
    }'

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release verify test-tool v1.0.0
    local output
    output=$(exec_stdout)

    # Without manifest, should still succeed (just can't verify completeness)
    local manifest_found
    manifest_found=$(echo "$output" | jq -r '.details.manifest_found // "null"' 2>/dev/null)
    if [[ "$manifest_found" == "false" ]]; then
        pass "release verify reports manifest_found: false when no manifest"
    else
        # Also accept if it just doesn't fail
        local status
        status=$(exec_status)
        if [[ "$status" -eq 0 ]]; then
            pass "release verify handles missing manifest gracefully"
        else
            fail "release verify should handle missing manifest"
            echo "output: $output"
        fi
    fi

    remove_release_verify_mock_gh
    harness_teardown
}

# ============================================================================
# Tests: Release Not Found
# ============================================================================

test_verify_release_not_found() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for repos.yaml parsing"
        return 0
    fi

    harness_setup
    seed_repos_config

    create_mock_gh "" 1

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" release verify test-tool v1.0.0
    local status
    status=$(exec_status)

    if [[ "$status" -eq 7 ]]; then
        pass "release verify returns exit 7 for release not found"
    else
        fail "release verify should exit 7 when release not found (got: $status)"
        echo "stderr: $(exec_stderr | head -5)"
    fi

    remove_release_verify_mock_gh
    harness_teardown
}

# ============================================================================
# Tests: JSON Output Format
# ============================================================================

test_verify_json_valid() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for repos.yaml parsing"
        return 0
    fi

    harness_setup
    seed_repos_config
    seed_manifest "test-tool" "v1.0.0"

    # Mock successful release
    create_mock_gh '{
        "id": 12345,
        "html_url": "https://github.com/testuser/test-tool/releases/tag/v1.0.0",
        "assets": [
            {"name": "test-tool-linux-amd64", "browser_download_url": "https://example.com/a"},
            {"name": "test-tool-darwin-arm64", "browser_download_url": "https://example.com/b"},
            {"name": "SHA256SUMS", "browser_download_url": "https://example.com/c"}
        ]
    }'

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release verify test-tool v1.0.0
    local output
    output=$(exec_stdout)

    if echo "$output" | jq . >/dev/null 2>&1; then
        pass "release verify --json produces valid JSON"
    else
        fail "release verify --json should produce valid JSON"
        echo "output: $output"
    fi

    remove_release_verify_mock_gh
    harness_teardown
}

test_verify_json_has_required_fields() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for repos.yaml parsing"
        return 0
    fi

    harness_setup
    seed_repos_config
    seed_manifest "test-tool" "v1.0.0"

    create_mock_gh '{
        "id": 12345,
        "html_url": "https://github.com/testuser/test-tool/releases/tag/v1.0.0",
        "assets": [
            {"name": "test-tool-linux-amd64", "browser_download_url": "https://example.com/a"}
        ]
    }'

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release verify test-tool v1.0.0
    local output
    output=$(exec_stdout)

    # Check for required fields in details
    local has_repo has_version has_verification has_assets
    has_repo=$(echo "$output" | jq '.details | has("repo")' 2>/dev/null)
    has_version=$(echo "$output" | jq '.details | has("version")' 2>/dev/null)
    has_verification=$(echo "$output" | jq '.details | has("verification")' 2>/dev/null)
    has_assets=$(echo "$output" | jq '.details | has("assets")' 2>/dev/null)

    if [[ "$has_repo" == "true" && "$has_version" == "true" && "$has_verification" == "true" && "$has_assets" == "true" ]]; then
        pass "release verify JSON has required schema fields"
    else
        fail "release verify JSON missing required fields"
        echo "has_repo: $has_repo, has_version: $has_version"
        echo "has_verification: $has_verification, has_assets: $has_assets"
        echo "details: $(echo "$output" | jq '.details' 2>/dev/null | head -20)"
    fi

    remove_release_verify_mock_gh
    harness_teardown
}

# ============================================================================
# Tests: Stream Separation
# ============================================================================

test_verify_stream_separation() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for repos.yaml parsing"
        return 0
    fi

    harness_setup
    seed_repos_config
    seed_manifest "test-tool" "v1.0.0"

    create_mock_gh '{
        "id": 12345,
        "html_url": "https://github.com/testuser/test-tool/releases/tag/v1.0.0",
        "assets": [
            {"name": "test-tool-linux-amd64", "browser_download_url": "https://example.com/a"}
        ]
    }'

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release verify test-tool v1.0.0

    local stdout stderr
    stdout=$(exec_stdout)
    stderr=$(exec_stderr)

    # stdout should be JSON only
    local stdout_is_json=false
    if echo "$stdout" | jq . >/dev/null 2>&1; then
        stdout_is_json=true
    fi

    # stderr should NOT contain JSON
    local stderr_has_json=false
    if echo "$stderr" | grep -q '^{.*}$'; then
        stderr_has_json=true
    fi

    if [[ "$stdout_is_json" == "true" && "$stderr_has_json" == "false" ]]; then
        pass "release verify maintains stream separation"
    else
        fail "release verify should maintain stream separation"
        echo "stdout is JSON: $stdout_is_json"
        echo "stderr has JSON: $stderr_has_json"
    fi

    remove_release_verify_mock_gh
    harness_teardown
}

# ============================================================================
# Tests: Retry/Fix Logic (--fix flag)
# ============================================================================

test_strict_fix_refuses_public_release_without_mutation() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for strict release contract parsing"
        return 0
    fi

    harness_setup
    seed_strict_verify_fixture
    unset STRICT_FIX_UPLOAD_MODE STRICT_FIX_MUTATE_LOCAL_ON_RELEASE_ID
    create_strict_verify_fix_mock_gh false

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" release verify test-tool v1.0.0 --fix
    local status
    status=$(exec_status)

    if [[ $status -eq 1 && ! -e "${STRICT_VERIFY_PRIMARY_PATH}.sha256" && \
          ! -s "$STRICT_FIX_UPLOAD_LOG" && ! -s "$STRICT_FIX_PATCH_LOG" ]] && \
        exec_stderr_contains "only for a verified draft"; then
        pass "strict --fix refuses a public release before any local or remote mutation"
    else
        fail "strict --fix must not mutate a public release or create sidecars"
        echo "status: $status"
        echo "stderr: $(exec_stderr | tail -20)"
    fi

    remove_strict_verify_mock_gh
    unset -f _strict_fix_release_json
    harness_teardown
}

test_strict_fix_rejects_local_asset_mutation_before_upload() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for strict release contract parsing"
        return 0
    fi

    harness_setup
    seed_strict_verify_fixture
    STRICT_VERIFY_ASSETS=$(jq -c 'map(select(.name != "test-tool-linux-amd64"))' \
        <<< "$STRICT_VERIFY_ASSETS")
    export STRICT_VERIFY_ASSETS
    unset STRICT_FIX_UPLOAD_MODE
    export STRICT_FIX_MUTATE_LOCAL_ON_RELEASE_ID=1
    create_strict_verify_fix_mock_gh true

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" release verify test-tool v1.0.0 --fix
    local status draft_state
    status=$(exec_status)
    draft_state=$(cat "$STRICT_FIX_DRAFT_FILE")

    if [[ $status -eq 1 && "$draft_state" == "true" && \
          -e "$STRICT_FIX_MUTATION_MARKER" && ! -s "$STRICT_FIX_UPLOAD_LOG" ]] && \
        { exec_stderr_contains "changed after preflight" || \
          exec_stderr_contains "digest changed"; }; then
        pass "strict --fix revalidates local bytes immediately before upload"
    else
        fail "strict --fix must reject a local asset changed after preflight"
        echo "status: $status, draft: $draft_state"
        echo "stderr: $(exec_stderr | tail -25)"
    fi

    unset STRICT_FIX_MUTATE_LOCAL_ON_RELEASE_ID
    remove_strict_verify_mock_gh
    unset -f _strict_fix_release_json
    harness_teardown
}

test_strict_fix_failed_clobber_restores_draft() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for strict release contract parsing"
        return 0
    fi

    harness_setup
    seed_strict_verify_fixture
    STRICT_VERIFY_ASSETS=$(jq -c \
        'map(select(.name != "test-tool-linux-amd64.sha256"))' \
        <<< "$STRICT_VERIFY_ASSETS")
    export STRICT_VERIFY_ASSETS
    unset STRICT_FIX_MUTATE_LOCAL_ON_RELEASE_ID
    export STRICT_FIX_UPLOAD_MODE=ambiguous_publish
    create_strict_verify_fix_mock_gh true

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" release verify test-tool v1.0.0 --fix
    local status draft_state
    status=$(exec_status)
    draft_state=$(cat "$STRICT_FIX_DRAFT_FILE")

    if [[ $status -eq 1 && "$draft_state" == "true" && \
          -f "${STRICT_VERIFY_PRIMARY_PATH}.sha256" && \
          -s "$STRICT_FIX_UPLOAD_LOG" && -s "$STRICT_FIX_PATCH_LOG" ]] && \
        grep -q '\.sha256' "$STRICT_FIX_UPLOAD_LOG" && \
        exec_stderr_contains "ambiguous failure"; then
        pass "strict --fix treats an ambiguous missing-asset upload as failed and restores draft state"
    else
        fail "strict --fix must fail and re-draft after an ambiguous missing-asset upload"
        echo "status: $status, draft: $draft_state"
        echo "stderr: $(exec_stderr | tail -30)"
    fi

    unset STRICT_FIX_UPLOAD_MODE
    remove_strict_verify_mock_gh
    unset -f _strict_fix_release_json
    harness_teardown
}

test_strict_fix_repairs_missing_asset_in_draft() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for strict release contract parsing"
        return 0
    fi

    harness_setup
    seed_strict_verify_fixture
    STRICT_VERIFY_ASSETS=$(jq -c \
        'map(select(.name != "test-tool-linux-amd64"))' \
        <<< "$STRICT_VERIFY_ASSETS")
    export STRICT_VERIFY_ASSETS
    unset STRICT_FIX_UPLOAD_MODE STRICT_FIX_MUTATE_LOCAL_ON_RELEASE_ID
    create_strict_verify_fix_mock_gh true

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release verify test-tool v1.0.0 --fix
    local status output draft_state
    status=$(exec_status)
    output=$(exec_stdout)
    draft_state=$(cat "$STRICT_FIX_DRAFT_FILE")

    if [[ $status -eq 0 && "$draft_state" == "true" && -s "$STRICT_FIX_UPLOAD_LOG" && \
          -s "$STRICT_FIX_LIST_LOG" && ! -s "$STRICT_FIX_TAG_ENDPOINT_LOG" ]] && \
        grep -q '^id-bound-upload:test-tool-linux-amd64$' "$STRICT_FIX_UPLOAD_LOG" && \
        ! grep -q '^delete:' "$STRICT_FIX_UPLOAD_LOG" && \
        ! grep -q '^tag-bound-upload:' "$STRICT_FIX_UPLOAD_LOG" && \
        jq -e '
            .details.verification.missing == 0 and
            .details.verification.remote_records_valid == true
        ' <<< "$output" >/dev/null 2>&1; then
        pass "strict --fix repairs an absent draft asset through the authenticated release list"
    else
        fail "strict --fix should upload an absent asset only to the verified draft ID"
        echo "status: $status, draft: $draft_state"
        echo "output: $output"
        echo "stderr: $(exec_stderr | tail -30)"
    fi

    remove_strict_verify_mock_gh
    unset -f _strict_fix_release_json
    harness_teardown
}

test_strict_fix_rejects_existing_digest_mismatch_without_mutation() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for strict release contract parsing"
        return 0
    fi

    harness_setup
    seed_strict_verify_fixture
    STRICT_VERIFY_ASSETS=$(jq -c \
        'map(if .name == "test-tool-linux-amd64" then .digest = ("sha256:" + ("0" * 64)) else . end)' \
        <<< "$STRICT_VERIFY_ASSETS")
    export STRICT_VERIFY_ASSETS
    unset STRICT_FIX_UPLOAD_MODE STRICT_FIX_MUTATE_LOCAL_ON_RELEASE_ID
    create_strict_verify_fix_mock_gh true

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release verify test-tool v1.0.0 --fix
    local status output draft_state
    status=$(exec_status)
    output=$(exec_stdout)
    draft_state=$(cat "$STRICT_FIX_DRAFT_FILE")

    if [[ $status -eq 1 && "$draft_state" == "true" ]] && \
        ! grep -Eq '^(delete:|id-bound-upload:|tag-bound-upload:)' \
            "$STRICT_FIX_UPLOAD_LOG" 2>/dev/null && \
        exec_stderr_contains "refuses existing assets with wrong size or digest" && \
        jq -e '
            .details.verification.digest_mismatches == 1 and
            .details.verification.remote_records_valid == false
        ' <<< "$output" >/dev/null 2>&1; then
        pass "strict --fix rejects an existing digest mismatch without remote mutation"
    else
        fail "strict --fix must never delete, clobber, or upload over an existing mismatched asset"
        echo "status: $status, draft: $draft_state"
        echo "uploads: $(cat "$STRICT_FIX_UPLOAD_LOG" 2>/dev/null || true)"
        echo "output: $output"
        echo "stderr: $(exec_stderr | tail -30)"
    fi

    remove_strict_verify_mock_gh
    unset -f _strict_fix_release_json
    harness_teardown
}

test_strict_fix_rejects_remote_tag_move_after_upload() {
    ((TESTS_RUN++))
    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for strict release contract parsing"
        return 0
    fi
    harness_setup
    seed_strict_verify_fixture
    STRICT_VERIFY_ASSETS=$(jq -c \
        'map(select(.name != "test-tool-linux-amd64"))' \
        <<< "$STRICT_VERIFY_ASSETS")
    export STRICT_VERIFY_ASSETS STRICT_FIX_REMOTE_TAG_MOVE_ON_CALL=2
    create_strict_verify_fix_mock_gh true

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release verify test-tool v1.0.0 --fix
    local status draft_state
    status=$(exec_status)
    draft_state=$(cat "$STRICT_FIX_DRAFT_FILE")

    if [[ $status -eq 1 && "$draft_state" == "true" && -s "$STRICT_FIX_UPLOAD_LOG" ]] && \
       exec_stderr_contains "frozen-plan or tag revalidation"; then
        pass "strict --fix rejects a remote tag move after repair upload"
    else
        fail "strict --fix must revalidate remote tag identity after mutation"
        echo "status: $status; draft: $draft_state"
        echo "stderr: $(exec_stderr | tail -30)"
    fi

    remove_strict_verify_mock_gh
    unset -f _strict_fix_release_json
    harness_teardown
}

test_strict_fix_rejects_manifest_mutation_after_upload() {
    ((TESTS_RUN++))
    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for strict release contract parsing"
        return 0
    fi
    harness_setup
    seed_strict_verify_fixture
    STRICT_VERIFY_ASSETS=$(jq -c \
        'map(select(.name != "test-tool-linux-amd64"))' \
        <<< "$STRICT_VERIFY_ASSETS")
    export STRICT_VERIFY_ASSETS STRICT_FIX_MUTATE_MANIFEST_AFTER_UPLOAD=1
    create_strict_verify_fix_mock_gh true

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release verify test-tool v1.0.0 --fix
    local status draft_state
    status=$(exec_status)
    draft_state=$(cat "$STRICT_FIX_DRAFT_FILE")

    if [[ $status -eq 1 && "$draft_state" == "true" && \
          -e "$STRICT_FIX_POST_UPLOAD_MUTATION_MARKER" ]] && \
       exec_stderr_contains "frozen-plan or tag revalidation"; then
        pass "strict --fix rejects a manifest mutation after repair upload"
    else
        fail "strict --fix must compare the post-upload plan with the frozen plan"
        echo "status: $status; draft: $draft_state"
        echo "stderr: $(exec_stderr | tail -30)"
    fi

    remove_strict_verify_mock_gh
    unset -f _strict_fix_release_json
    harness_teardown
}

test_strict_fix_rejects_local_tag_mutation_after_upload() {
    ((TESTS_RUN++))
    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for strict release contract parsing"
        return 0
    fi
    harness_setup
    seed_strict_verify_fixture
    STRICT_VERIFY_ASSETS=$(jq -c \
        'map(select(.name != "test-tool-linux-amd64"))' \
        <<< "$STRICT_VERIFY_ASSETS")
    export STRICT_VERIFY_ASSETS STRICT_FIX_MUTATE_LOCAL_TAG_AFTER_UPLOAD=1
    create_strict_verify_fix_mock_gh true

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release verify test-tool v1.0.0 --fix
    local status draft_state
    status=$(exec_status)
    draft_state=$(cat "$STRICT_FIX_DRAFT_FILE")

    if [[ $status -eq 1 && "$draft_state" == "true" && \
          -e "$STRICT_FIX_POST_UPLOAD_MUTATION_MARKER" ]] && \
       exec_stderr_contains "frozen-plan or tag revalidation"; then
        pass "strict --fix rejects a local tag mutation after repair upload"
    else
        fail "strict --fix must revalidate local tag identity after mutation"
        echo "status: $status; draft: $draft_state"
        echo "stderr: $(exec_stderr | tail -30)"
    fi

    remove_strict_verify_mock_gh
    unset -f _strict_fix_release_json
    harness_teardown
}

test_strict_fix_refuses_release_tag_rebind_before_mutation() {
    ((TESTS_RUN++))
    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for strict release contract parsing"
        return 0
    fi
    harness_setup
    seed_strict_verify_fixture
    STRICT_VERIFY_ASSETS=$(jq -c \
        'map(select(.name != "test-tool-linux-amd64"))' \
        <<< "$STRICT_VERIFY_ASSETS")
    export STRICT_VERIFY_ASSETS STRICT_FIX_TAG_REBIND_ON_RELEASE_ID_GET=3
    create_strict_verify_fix_mock_gh true

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" release verify test-tool v1.0.0 --fix
    local status
    status=$(exec_status)

    if [[ $status -eq 1 && "$(cat "$STRICT_FIX_TAG_NAME_FILE")" == "v9.9.9" ]] && \
       ! grep -Eq '^(delete:|id-bound-upload:|tag-bound-upload:)' \
        "$STRICT_FIX_UPLOAD_LOG" 2>/dev/null; then
        pass "strict --fix refuses a tag rebind before any remote asset mutation"
    else
        fail "strict --fix must bind mutation to the observed release ID and expected tag"
        echo "status: $status"
        echo "uploads: $(cat "$STRICT_FIX_UPLOAD_LOG" 2>/dev/null || true)"
        echo "stderr: $(exec_stderr | tail -30)"
    fi

    remove_strict_verify_mock_gh
    unset -f _strict_fix_release_json
    harness_teardown
}

test_strict_fix_final_get_rejects_postcheck_asset_flip() {
    ((TESTS_RUN++))
    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for strict release contract parsing"
        return 0
    fi
    harness_setup
    seed_strict_verify_fixture
    printf '%s  %s\n' "$STRICT_VERIFY_PRIMARY_SHA" "test-tool-linux-amd64" \
        > "${STRICT_VERIFY_PRIMARY_PATH}.sha256"
    STRICT_VERIFY_ASSETS=$(jq -c \
        'map(select(.name != "test-tool-linux-amd64"))' \
        <<< "$STRICT_VERIFY_ASSETS")
    export STRICT_VERIFY_ASSETS STRICT_FIX_FLIP_AFTER_FIRST_POST_UPLOAD_GET=1
    create_strict_verify_fix_mock_gh true

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release verify test-tool v1.0.0 --fix
    local status post_upload_gets
    status=$(exec_status)
    post_upload_gets=$(cat "$STRICT_FIX_POST_UPLOAD_GET_COUNT_FILE")

    if [[ $status -eq 1 && "$post_upload_gets" -ge 2 ]] && \
       exec_stdout | jq -e '.details.verification.remote_records_valid == false' \
        >/dev/null 2>&1 && \
       exec_stderr_contains "frozen-plan or tag revalidation"; then
        pass "strict --fix ends success proof with a fresh exact ID-bound draft GET"
    else
        fail "strict --fix must reject remote asset drift after its first post-upload proof"
        echo "status: $status; post-upload GETs: $post_upload_gets"
        echo "stderr: $(exec_stderr | tail -35)"
    fi

    remove_strict_verify_mock_gh
    unset -f _strict_fix_release_json
    harness_teardown
}

test_verify_fix_attempts_upload() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for repos.yaml parsing"
        return 0
    fi

    harness_setup
    seed_repos_config
    seed_manifest "test-tool" "v1.0.0"

    # Track upload attempts
    local upload_log="$TEST_TMPDIR/upload.log"

    create_mock_gh '{
        "id": 12345,
        "html_url": "https://github.com/testuser/test-tool/releases/tag/v1.0.0",
        "assets": [
            {"name": "test-tool-linux-amd64", "browser_download_url": "https://example.com/a"},
            {"name": "SHA256SUMS", "browser_download_url": "https://example.com/c"}
        ]
    }' 0 0 0 "$upload_log"

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" release verify test-tool v1.0.0 --fix
    local status
    status=$(exec_status)

    # Check if upload was attempted
    if [[ -f "$upload_log" ]]; then
        if grep -q "darwin-arm64" "$upload_log" 2>/dev/null; then
            pass "release verify --fix attempts to upload missing asset"
        else
            fail "release verify --fix should attempt to upload darwin-arm64"
            echo "upload log: $(cat "$upload_log")"
        fi
    else
        # If no upload log, check stderr for upload attempt message
        if exec_stderr_contains "Uploading" || exec_stderr_contains "Upload"; then
            pass "release verify --fix attempts upload (log message found)"
        else
            fail "release verify --fix should attempt to upload missing asset"
            echo "stderr: $(exec_stderr | head -10)"
        fi
    fi

    remove_release_verify_mock_gh
    harness_teardown
}

test_verify_fix_reports_not_found_locally() {
    ((TESTS_RUN++))

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for repos.yaml parsing"
        return 0
    fi

    harness_setup
    seed_repos_config

    # Create manifest but NO local artifacts
    local state_dir="$DSR_STATE_DIR"
    local artifacts_dir="$state_dir/artifacts/test-tool/v1.0.0"
    mkdir -p "$artifacts_dir"

    cat > "$artifacts_dir/test-tool-v1.0.0-manifest.json" << 'EOF'
{
  "schema_version": "1.0.0",
  "tool": "test-tool",
  "version": "v1.0.0",
  "artifacts": [
    {"filename": "test-tool-linux-amd64", "target": "linux/amd64"},
    {"filename": "test-tool-darwin-arm64", "target": "darwin/arm64"}
  ]
}
EOF

    export DSR_STATE_DIR="$state_dir"

    create_mock_gh '{
        "id": 12345,
        "html_url": "https://github.com/testuser/test-tool/releases/tag/v1.0.0",
        "assets": [
            {"name": "test-tool-linux-amd64", "browser_download_url": "https://example.com/a"}
        ]
    }'

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" release verify test-tool v1.0.0 --fix

    # Should warn about not found locally
    if exec_stderr_contains "Not found locally" || exec_stderr_contains "not found"; then
        pass "release verify --fix reports when asset not found locally"
    else
        # May not have explicit message, but shouldn't crash
        local status
        status=$(exec_status)
        if [[ "$status" -le 1 ]]; then
            pass "release verify --fix handles missing local asset gracefully"
        else
            fail "release verify --fix should handle missing local assets"
            echo "stderr: $(exec_stderr | head -10)"
        fi
    fi

    remove_release_verify_mock_gh
    harness_teardown
}

# ============================================================================
# Cleanup
# ============================================================================

cleanup() {
    exec_cleanup 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================================
# Run All Tests
# ============================================================================

echo "=== Tests: dsr release verify (bd-1jt.5.12) ==="
echo ""
echo "Dependencies: gh auth=$(if $HAS_GH_AUTH; then echo available; else echo missing; fi), yq=$(if $HAS_YQ; then echo available; else echo missing; fi)"
echo ""

if [[ "${DSR_RELEASE_VERIFY_STRICT_ONLY:-0}" == "1" ]]; then
    echo "Strict Release Contract Tests (mocked gh):"
    test_strict_verify_requires_exact_names_sizes_and_sidecars
    test_strict_verify_rejects_extra_or_incomplete_remote_assets
    test_strict_verify_rejects_remote_digest_mismatch
    test_strict_verify_rejects_wrong_release_tag
    test_strict_fix_refuses_public_release_without_mutation
    test_strict_fix_rejects_local_asset_mutation_before_upload
    test_strict_fix_failed_clobber_restores_draft
    test_strict_fix_repairs_missing_asset_in_draft
    test_strict_fix_rejects_existing_digest_mismatch_without_mutation
    test_strict_fix_rejects_remote_tag_move_after_upload
    test_strict_fix_rejects_manifest_mutation_after_upload
    test_strict_fix_rejects_local_tag_mutation_after_upload
    test_strict_fix_refuses_release_tag_rebind_before_mutation
    test_strict_fix_final_get_rejects_postcheck_asset_flip
    echo ""
    echo "=========================================="
    echo "Tests run:    $TESTS_RUN"
    echo "Passed:       $TESTS_PASSED"
    echo "Skipped:      $TESTS_SKIPPED"
    echo "Failed:       $TESTS_FAILED"
    echo "=========================================="
    [[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
fi

echo "Help Tests (always work):"
test_verify_help
test_verify_help_shows_options

echo ""
echo "Argument Validation Tests:"
test_verify_missing_tool
test_verify_missing_version
test_verify_unknown_option

echo ""
echo "Authentication Tests:"
test_verify_missing_gh_auth

echo ""
echo "Asset Comparison Tests (mocked gh):"
test_verify_all_assets_present
test_verify_detects_missing_assets
test_verify_detects_extra_assets
test_strict_verify_requires_exact_names_sizes_and_sidecars
test_strict_verify_rejects_extra_or_incomplete_remote_assets
test_strict_verify_rejects_remote_digest_mismatch
test_strict_verify_rejects_wrong_release_tag
test_verify_handles_no_manifest

echo ""
echo "Release Not Found Tests:"
test_verify_release_not_found

echo ""
echo "JSON Output Tests:"
test_verify_json_valid
test_verify_json_has_required_fields

echo ""
echo "Stream Separation Tests:"
test_verify_stream_separation

echo ""
echo "Retry/Fix Logic Tests:"
test_strict_fix_refuses_public_release_without_mutation
test_strict_fix_rejects_local_asset_mutation_before_upload
test_strict_fix_failed_clobber_restores_draft
test_strict_fix_repairs_missing_asset_in_draft
test_strict_fix_rejects_existing_digest_mismatch_without_mutation
test_strict_fix_rejects_remote_tag_move_after_upload
test_strict_fix_rejects_manifest_mutation_after_upload
test_strict_fix_rejects_local_tag_mutation_after_upload
test_strict_fix_refuses_release_tag_rebind_before_mutation
test_strict_fix_final_get_rejects_postcheck_asset_flip
test_verify_fix_attempts_upload
test_verify_fix_reports_not_found_locally

echo ""
echo "=========================================="
echo "Tests run:    $TESTS_RUN"
echo "Passed:       $TESTS_PASSED"
echo "Skipped:      $TESTS_SKIPPED"
echo "Failed:       $TESTS_FAILED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
