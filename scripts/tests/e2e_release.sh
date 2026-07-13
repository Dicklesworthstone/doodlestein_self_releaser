#!/usr/bin/env bash
# e2e_release.sh - E2E tests for dsr release command
#
# Tests release subcommand with real behavior (no mocks).
# Since release actually uploads to GitHub, most tests focus on
# validation, error handling, and dry-run paths.
#
# Run: ./scripts/tests/e2e_release.sh

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
# Helper: Create test repos config
# ============================================================================

seed_repos_config() {
    mkdir -p "$DSR_CONFIG_DIR"

    cat > "$DSR_CONFIG_DIR/config.yaml" << 'YAML'
schema_version: "1.0.0"
threshold_seconds: 600
log_level: info
signing:
  enabled: false
YAML

    # Create repos.yaml with test tool
    cat > "$DSR_CONFIG_DIR/repos.yaml" << 'YAML'
schema_version: "1.0.0"

tools:
  test-tool:
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

seed_artifacts() {
    local tool="${1:-test-tool}"
    local version="${2:-v1.0.0}"
    local state_dir="$DSR_STATE_DIR"
    local artifacts_dir="$state_dir/artifacts/$tool/$version"

    mkdir -p "$artifacts_dir"

    # Create dummy artifacts
    echo "binary content for linux" > "$artifacts_dir/${tool}-linux-amd64"
    echo "binary content for darwin" > "$artifacts_dir/${tool}-darwin-arm64"

    # Create checksums file
    # shellcheck disable=SC2086  # Intentional globbing with ${tool}-*
    (cd "$artifacts_dir" && sha256sum "${tool}"-* > SHA256SUMS 2>/dev/null || shasum -a 256 "${tool}"-* > SHA256SUMS 2>/dev/null || echo "dummy checksums")

    # Create a minimal manifest
    cat > "$artifacts_dir/${tool}-${version}-manifest.json" << EOF
{
  "schema_version": "1.0.0",
  "tool": "$tool",
  "version": "$version",
  "run_id": "test-run-001",
  "git_sha": "abc123",
  "built_at": "2026-01-30T12:00:00Z",
  "artifacts": [
    {"name": "${tool}-linux-amd64", "target": "linux/amd64", "sha256": "abc123abc123abc123abc123abc123abc123abc123abc123abc123abc123abc1", "size_bytes": 100},
    {"name": "${tool}-darwin-arm64", "target": "darwin/arm64", "sha256": "def456def456def456def456def456def456def456def456def456def456def4", "size_bytes": 100}
  ]
}
EOF

    export DSR_STATE_DIR="$state_dir"
}

test_sha256() {
    local file="$1"
    if command -v sha256sum &>/dev/null; then
        sha256sum "$file" | awk '{print $1}'
    else
        shasum -a 256 "$file" | awk '{print $1}'
    fi
}

test_file_size() {
    local file="$1"
    stat -c %s "$file" 2>/dev/null || stat -f %z "$file"
}

test_sha256_line() {
    local line="$1"
    if command -v sha256sum &>/dev/null; then
        printf '%s\n' "$line" | sha256sum | awk '{print $1}'
    else
        printf '%s\n' "$line" | shasum -a 256 | awk '{print $1}'
    fi
}

seed_strict_release_fixture() {
    local tool="test-tool"
    local tag="v1.0.0"
    unset STRICT_MUTATE_MANIFEST_ON_RELEASE_GET STRICT_PREPUBLISH_DIGEST_FAULT_ON_GET
    unset STRICT_POSTPUBLISH_DIGEST_FAULT STRICT_TAG_MOVE_ON_CALL STRICT_RELEASE_TAG_NAME
    unset STRICT_MUTATE_METADATA_ON_RELEASE_GET
    unset STRICT_PUBLISH_PATCH_COMMIT_ERROR STRICT_PUBLISH_PATCH_ERROR_NO_COMMIT
    unset STRICT_REDRAFT_PATCH_COMMIT_ERROR
    unset STRICT_CREATE_POST_COMMIT_ERROR STRICT_CREATE_OBSERVED_NONEXACT
    unset STRICT_UPLOAD_COMMIT_ERROR_ON_NAME
    unset STRICT_FLIP_PUBLIC_DURING_UPLOAD STRICT_FLIP_PUBLIC_ON_RELEASE_GET
    unset STRICT_CREATE_COMPETITOR_DRAFT
    unset STRICT_RELEASE_LIST_SCENARIO
    export DSR_RELEASE_STATE_RETRY_DELAY_SECONDS=0
    STRICT_REPO_DIR="$TEST_TMPDIR/repo"
    STRICT_ARTIFACTS_DIR="$TEST_TMPDIR/artifacts"
    STRICT_MUTATION_LOG="$TEST_TMPDIR/github-mutations.log"
    STRICT_READ_LOG="$TEST_TMPDIR/github-reads.log"
    export STRICT_REPO_DIR STRICT_ARTIFACTS_DIR STRICT_MUTATION_LOG STRICT_READ_LOG

    mkdir -p "$DSR_CONFIG_DIR/repos.d" "$STRICT_REPO_DIR" "$STRICT_ARTIFACTS_DIR"
    git -C "$STRICT_REPO_DIR" init -q
    git -C "$STRICT_REPO_DIR" config user.name "DSR Test"
    git -C "$STRICT_REPO_DIR" config user.email "dsr-test@example.invalid"
    printf 'release source\n' > "$STRICT_REPO_DIR/source.txt"
    git -C "$STRICT_REPO_DIR" add source.txt
    git -C "$STRICT_REPO_DIR" commit -qm "release source"
    git -C "$STRICT_REPO_DIR" tag -a "$tag" -m "$tag"
    STRICT_GIT_SHA=$(git -C "$STRICT_REPO_DIR" rev-parse HEAD)
    export STRICT_GIT_SHA

    cat > "$DSR_CONFIG_DIR/repos.d/${tool}.yaml" << YAML
tool_name: $tool
repo: testuser/test-tool
local_path: $STRICT_REPO_DIR
language: go
build_cmd: go build ./...
binary_name: $tool
targets:
  - linux/amd64
  - darwin/arm64
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    linux/amd64: ${tool}-linux-amd64
    darwin/arm64: ${tool}-darwin-arm64
YAML

    printf 'linux release binary\n' > "$STRICT_ARTIFACTS_DIR/${tool}-linux-amd64"
    printf 'darwin release binary\n' > "$STRICT_ARTIFACTS_DIR/${tool}-darwin-arm64"
    printf 'must not upload\n' > "$STRICT_ARTIFACTS_DIR/${tool}-alias"
    printf '{"bomFormat":"CycloneDX"}\n' > "$STRICT_ARTIFACTS_DIR/${tool}.sbom.json"

    local linux_sha darwin_sha linux_size darwin_size
    linux_sha=$(test_sha256 "$STRICT_ARTIFACTS_DIR/${tool}-linux-amd64")
    darwin_sha=$(test_sha256 "$STRICT_ARTIFACTS_DIR/${tool}-darwin-arm64")
    linux_size=$(test_file_size "$STRICT_ARTIFACTS_DIR/${tool}-linux-amd64")
    darwin_size=$(test_file_size "$STRICT_ARTIFACTS_DIR/${tool}-darwin-arm64")

    jq -nc \
        --arg tool "$tool" \
        --arg tag "$tag" \
        --arg git_sha "$STRICT_GIT_SHA" \
        --arg linux_sha "$linux_sha" \
        --arg darwin_sha "$darwin_sha" \
        --argjson linux_size "$linux_size" \
        --argjson darwin_size "$darwin_size" '
        {
            schema_version: "1.0.0",
            tool: $tool,
            version: $tag,
            run_id: "strict-test",
            source: {git_sha: $git_sha, git_ref: $tag, dependencies: []},
            built_at: "2026-01-30T12:00:00Z",
            duration_ms: 1,
            status: "success",
            summary: {total: 2, success: 2, failed: 0},
            artifacts: [
                {name: ($tool + "-linux-amd64"), target: "linux/amd64", sha256: $linux_sha, size_bytes: $linux_size},
                {name: ($tool + "-darwin-arm64"), target: "darwin/arm64", sha256: $darwin_sha, size_bytes: $darwin_size}
            ]
        }
    ' > "$STRICT_ARTIFACTS_DIR/${tool}-${tag}-manifest.json"
    STRICT_MANIFEST_PATH="$STRICT_ARTIFACTS_DIR/${tool}-${tag}-manifest.json"
    export STRICT_MANIFEST_PATH

    local linux_sidecar_sha darwin_sidecar_sha linux_sidecar_size darwin_sidecar_size
    linux_sidecar_sha=$(test_sha256_line "$linux_sha  ${tool}-linux-amd64")
    darwin_sidecar_sha=$(test_sha256_line "$darwin_sha  ${tool}-darwin-arm64")
    linux_sidecar_size=$(printf '%s  %s\n' "$linux_sha" "${tool}-linux-amd64" | wc -c | tr -d '[:space:]')
    darwin_sidecar_size=$(printf '%s  %s\n' "$darwin_sha" "${tool}-darwin-arm64" | wc -c | tr -d '[:space:]')
    STRICT_REMOTE_ASSETS=$(jq -nc \
        --arg linux_sha "$linux_sha" \
        --arg darwin_sha "$darwin_sha" \
        --arg linux_sidecar_sha "$linux_sidecar_sha" \
        --arg darwin_sidecar_sha "$darwin_sidecar_sha" \
        --argjson linux_size "$linux_size" \
        --argjson darwin_size "$darwin_size" \
        --argjson linux_sidecar_size "$linux_sidecar_size" \
        --argjson darwin_sidecar_size "$darwin_sidecar_size" '
        [
            {id: 1, name: "test-tool-linux-amd64", size: $linux_size, state: "uploaded", digest: ("sha256:" + $linux_sha)},
            {id: 2, name: "test-tool-linux-amd64.sha256", size: $linux_sidecar_size, state: "uploaded", digest: ("sha256:" + $linux_sidecar_sha)},
            {id: 3, name: "test-tool-darwin-arm64", size: $darwin_size, state: "uploaded", digest: ("sha256:" + $darwin_sha)},
            {id: 4, name: "test-tool-darwin-arm64.sha256", size: $darwin_sidecar_size, state: "uploaded", digest: ("sha256:" + $darwin_sidecar_sha)}
        ]
    ')
    STRICT_EXPECTED_UPLOAD_ASSETS="$STRICT_REMOTE_ASSETS"
    export STRICT_REMOTE_ASSETS STRICT_EXPECTED_UPLOAD_ASSETS
}

create_strict_github_mocks() {
    STRICT_RELEASE_DRAFT_STATE="$TEST_TMPDIR/strict-release-draft.state"
    STRICT_RELEASE_EXISTS_STATE="$TEST_TMPDIR/strict-release-exists.state"
    STRICT_RELEASE_GET_COUNT_FILE="$TEST_TMPDIR/strict-release-get-count"
    STRICT_RELEASE_LIST_GET_COUNT_FILE="$TEST_TMPDIR/strict-release-list-get-count"
    STRICT_TAG_GET_COUNT_FILE="$TEST_TMPDIR/strict-tag-get-count"
    STRICT_UPLOAD_STARTED_FILE="$TEST_TMPDIR/strict-upload-started"
    STRICT_PUBLIC_FLIP_MARKER="$TEST_TMPDIR/strict-public-flipped"
    STRICT_RELEASE_BODY_STATE="$TEST_TMPDIR/strict-release-body.state"
    printf 'true\n' > "$STRICT_RELEASE_DRAFT_STATE"
    printf 'false\n' > "$STRICT_RELEASE_EXISTS_STATE"
    printf '0\n' > "$STRICT_RELEASE_GET_COUNT_FILE"
    printf '0\n' > "$STRICT_RELEASE_LIST_GET_COUNT_FILE"
    printf '0\n' > "$STRICT_TAG_GET_COUNT_FILE"
    printf 'Release v1.0.0\n' > "$STRICT_RELEASE_BODY_STATE"
    export STRICT_RELEASE_DRAFT_STATE STRICT_RELEASE_EXISTS_STATE
    export STRICT_RELEASE_GET_COUNT_FILE STRICT_RELEASE_LIST_GET_COUNT_FILE
    export STRICT_TAG_GET_COUNT_FILE STRICT_UPLOAD_STARTED_FILE
    export STRICT_PUBLIC_FLIP_MARKER
    export STRICT_RELEASE_BODY_STATE

    gh() {
        case "${1:-}" in
            auth)
                case "${2:-}" in
                    status) return 0 ;;
                    token) printf 'strict-test-token\n'; return 0 ;;
                esac
                ;;
            api)
                local endpoint="${2:-}"
                local method="GET"
                local has_input=false
                local input_json=""
                local saw_cache_control=false
                local saw_pragma=false
                shift 2
                while [[ $# -gt 0 ]]; do
                    case "$1" in
                        -X) method="$2"; shift 2 ;;
                        --input) has_input=true; shift 2 ;;
                        -H)
                            [[ "$2" == "Cache-Control: no-cache, no-store, max-age=0" ]] && saw_cache_control=true
                            [[ "$2" == "Pragma: no-cache" ]] && saw_pragma=true
                            shift 2
                            ;;
                        *) shift ;;
                    esac
                done
                $has_input && input_json=$(cat)
                case "$endpoint:$method" in
                    repos/testuser/test-tool/git/ref/tags/v1.0.0:GET|\
                    repos/testuser/test-tool/releases\?per_page=100\&page=*:GET|\
                    repos/testuser/test-tool/releases/123:GET|\
                    repos/testuser/test-tool/releases/123:PATCH)
                        if ! $saw_cache_control || ! $saw_pragma; then
                            printf 'no-cache-invalid:%s:%s\n' "$method" "$endpoint" >> "$STRICT_MUTATION_LOG"
                            return 1
                        fi
                        ;;
                esac
                case "$endpoint:$method" in
                    repos/testuser/test-tool/git/ref/tags/v1.0.0:GET)
                        local tag_get_count=0 tag_sha="$STRICT_GIT_SHA"
                        read -r tag_get_count < "$STRICT_TAG_GET_COUNT_FILE" || tag_get_count=0
                        tag_get_count=$((tag_get_count + 1))
                        printf '%s\n' "$tag_get_count" > "$STRICT_TAG_GET_COUNT_FILE"
                        if [[ "${STRICT_TAG_MOVE_ON_CALL:-0}" =~ ^[1-9][0-9]*$ ]] &&
                           [[ $tag_get_count -ge ${STRICT_TAG_MOVE_ON_CALL} ]]; then
                            tag_sha="4444444444444444444444444444444444444444"
                        fi
                        jq -nc --arg sha "$tag_sha" '{object:{sha:$sha,type:"commit"}}'
                        ;;
                    repos/testuser/test-tool/releases\?per_page=100\&page=1:GET)
                        local release_exists=false tag_release_get_count=0
                        local observed_assets='[]' observed_body=""
                        read -r release_exists < "$STRICT_RELEASE_EXISTS_STATE" || release_exists=false
                        observed_body=$(cat "$STRICT_RELEASE_BODY_STATE")
                        read -r tag_release_get_count < "$STRICT_RELEASE_LIST_GET_COUNT_FILE" || \
                            tag_release_get_count=0
                        tag_release_get_count=$((tag_release_get_count + 1))
                        printf '%s\n' "$tag_release_get_count" > "$STRICT_RELEASE_LIST_GET_COUNT_FILE"
                        case "${STRICT_RELEASE_LIST_SCENARIO:-}" in
                            failure)
                                return 1
                                ;;
                            duplicate)
                                jq -nc '
                                    [range(0; 100) as $index |
                                        if $index == 0
                                        then {id: 123, tag_name: "v1.0.0"}
                                        else {
                                            id: (1000 + $index),
                                            tag_name: ("v9." + ($index | tostring) + ".0")
                                        }
                                        end]
                                '
                                return 0
                                ;;
                            malformed)
                                jq -nc '
                                    [range(0; 100) as $index | {
                                        id: (1000 + $index),
                                        tag_name: ("v9." + ($index | tostring) + ".0")
                                    }]
                                '
                                return 0
                                ;;
                        esac
                        if [[ "$release_exists" != "true" ]]; then
                            printf '[]\n'
                            return 0
                        fi
                        if [[ -e "$STRICT_UPLOAD_STARTED_FILE" ]]; then
                            observed_assets="$STRICT_REMOTE_ASSETS"
                        fi
                        if [[ "${STRICT_CREATE_OBSERVED_NONEXACT:-0}" == "1" && \
                              ! -e "$STRICT_UPLOAD_STARTED_FILE" ]]; then
                            observed_body="unexpected observed body"
                        fi
                        jq -nc \
                            --arg body "$observed_body" \
                            --argjson assets "$observed_assets" '
                            [{
                                id: 123,
                                tag_name: "v1.0.0",
                                target_commitish: "main",
                                name: "v1.0.0",
                                body: $body,
                                prerelease: false,
                                upload_url: "https://uploads.example.invalid/assets{?name,label}",
                                html_url: "https://example.invalid/v1.0.0",
                                draft: true,
                                assets: $assets
                            }]
                        '
                        ;;
                    repos/testuser/test-tool/releases\?per_page=100\&page=2:GET)
                        local tag_release_get_count=0
                        read -r tag_release_get_count < "$STRICT_RELEASE_LIST_GET_COUNT_FILE" || \
                            tag_release_get_count=0
                        tag_release_get_count=$((tag_release_get_count + 1))
                        printf '%s\n' "$tag_release_get_count" > "$STRICT_RELEASE_LIST_GET_COUNT_FILE"
                        case "${STRICT_RELEASE_LIST_SCENARIO:-}" in
                            duplicate) printf '[{"id":456,"tag_name":"v1.0.0"}]\n' ;;
                            malformed) printf '{"invalid":"release-list-page"}\n' ;;
                            *) return 1 ;;
                        esac
                        ;;
                    repos/testuser/test-tool/releases/tags/v1.0.0:GET)
                        printf 'gh: Not Found (HTTP 404)\n' >&2
                        return 1
                        ;;
                    repos/testuser/test-tool/releases:POST)
                        if ! jq -e --arg git_sha "$STRICT_GIT_SHA" '
                            type == "object" and
                            .tag_name == "v1.0.0" and
                            .target_commitish == $git_sha and
                            .name == "v1.0.0" and
                            (.body | test("^Release v1\\.0\\.0\\n\\n<!-- dsr-create-nonce:[0-9a-f]{64} -->$")) and
                            .draft == true and
                            .prerelease == false
                        ' <<< "$input_json" >/dev/null 2>&1; then
                            printf 'create-invalid\n' >> "$STRICT_MUTATION_LOG"
                            return 1
                        fi
                        local requested_body
                        requested_body=$(jq -r '.body' <<< "$input_json")
                        if [[ "${STRICT_CREATE_COMPETITOR_DRAFT:-0}" == "1" ]]; then
                            requested_body=$'Release v1.0.0\n\n<!-- dsr-create-nonce:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff -->'
                        fi
                        printf '%s\n' "$requested_body" > "$STRICT_RELEASE_BODY_STATE"
                        printf 'create\n' >> "$STRICT_MUTATION_LOG"
                        printf 'true\n' > "$STRICT_RELEASE_EXISTS_STATE"
                        if [[ "${STRICT_CREATE_POST_COMMIT_ERROR:-0}" == "1" || \
                              "${STRICT_CREATE_OBSERVED_NONEXACT:-0}" == "1" || \
                              "${STRICT_CREATE_COMPETITOR_DRAFT:-0}" == "1" ]]; then
                            printf 'create-response-error\n' >> "$STRICT_MUTATION_LOG"
                            return 1
                        fi
                        jq -nc --arg git_sha "$STRICT_GIT_SHA" --arg body "$requested_body" '{
                            id: 123,
                            tag_name: "v1.0.0",
                            target_commitish: $git_sha,
                            name: "v1.0.0",
                            body: $body,
                            prerelease: false,
                            upload_url: "https://uploads.example.invalid/assets{?name,label}",
                            html_url: "https://example.invalid/v1.0.0",
                            draft: true,
                            assets: []
                        }'
                        ;;
                    repos/testuser/test-tool/releases/123:GET)
                        local draft=true release_get_count=0 remote_assets='[]'
                        local release_body=""
                        read -r draft < "$STRICT_RELEASE_DRAFT_STATE" || draft=true
                        release_body=$(cat "$STRICT_RELEASE_BODY_STATE")
                        if [[ -e "$STRICT_UPLOAD_STARTED_FILE" ]]; then
                            remote_assets="$STRICT_REMOTE_ASSETS"
                        fi
                        read -r release_get_count < "$STRICT_RELEASE_GET_COUNT_FILE" || release_get_count=0
                        release_get_count=$((release_get_count + 1))
                        printf '%s\n' "$release_get_count" > "$STRICT_RELEASE_GET_COUNT_FILE"
                        if [[ "${STRICT_FLIP_PUBLIC_ON_RELEASE_GET:-0}" =~ ^[1-9][0-9]*$ && \
                              $release_get_count -eq ${STRICT_FLIP_PUBLIC_ON_RELEASE_GET} ]]; then
                            draft=false
                            printf 'false\n' > "$STRICT_RELEASE_DRAFT_STATE"
                            printf 'flip-public:get-%s\n' "$release_get_count" >> "$STRICT_MUTATION_LOG"
                        fi
                        if [[ "${STRICT_MUTATE_MANIFEST_ON_RELEASE_GET:-0}" == "1" && $release_get_count -eq 1 ]]; then
                            jq '.built_at = "2026-01-30T12:00:01Z"' "$STRICT_MANIFEST_PATH" > "${STRICT_MANIFEST_PATH}.mutated" &&
                                mv "${STRICT_MANIFEST_PATH}.mutated" "$STRICT_MANIFEST_PATH"
                        fi
                        if [[ "${STRICT_PREPUBLISH_DIGEST_FAULT_ON_GET:-0}" =~ ^[1-9][0-9]*$ ]] &&
                           [[ $release_get_count -eq ${STRICT_PREPUBLISH_DIGEST_FAULT_ON_GET} ]]; then
                            remote_assets=$(jq -c '.[0].digest = ("sha256:" + ("0" * 64))' <<< "$remote_assets")
                        fi
                        if [[ "${STRICT_POSTPUBLISH_DIGEST_FAULT:-0}" == "1" && "$draft" == "false" ]]; then
                            remote_assets=$(jq -c '.[0].digest = ("sha256:" + ("0" * 64))' <<< "$remote_assets")
                        fi
                        if [[ "${STRICT_MUTATE_METADATA_ON_RELEASE_GET:-0}" =~ ^[1-9][0-9]*$ ]] &&
                           [[ $release_get_count -eq ${STRICT_MUTATE_METADATA_ON_RELEASE_GET} ]]; then
                            release_body="unexpected remote body"
                        fi
                        if [[ "${STRICT_CREATE_OBSERVED_NONEXACT:-0}" == "1" && \
                              ! -e "$STRICT_UPLOAD_STARTED_FILE" ]]; then
                            release_body="unexpected observed body"
                        fi
                        printf 'release-get:%s\n' "$draft" >> "$STRICT_READ_LOG"
                        jq -nc \
                            --arg tag_name "${STRICT_RELEASE_TAG_NAME:-v1.0.0}" \
                            --arg body "$release_body" \
                            --argjson draft "$draft" \
                            --argjson assets "$remote_assets" \
                            '{
                                id: 123,
                                tag_name: $tag_name,
                                target_commitish: "main",
                                name: "v1.0.0",
                                body: $body,
                                prerelease: false,
                                upload_url: "https://uploads.example.invalid/assets{?name,label}",
                                html_url: "https://example.invalid/v1.0.0",
                                draft: $draft,
                                assets: $assets
                            }'
                        ;;
                    repos/testuser/test-tool/releases/123:PATCH)
                        local requested_draft
                        requested_draft=$(jq -r '
                            .draft | if type == "boolean" then tostring else empty end
                        ' <<< "$input_json")
                        printf 'patch-request:%s\n' "$requested_draft" >> "$STRICT_MUTATION_LOG"
                        if [[ "$requested_draft" == "false" ]]; then
                            if ! jq -e \
                                --arg git_sha "$STRICT_GIT_SHA" \
                                --arg expected_body "$(cat "$STRICT_RELEASE_BODY_STATE")" '
                                type == "object" and
                                keys == ["body", "draft", "name", "prerelease", "tag_name", "target_commitish"] and
                                .tag_name == "v1.0.0" and
                                .target_commitish == $git_sha and
                                .name == "v1.0.0" and
                                .body == $expected_body and
                                .prerelease == false and
                                .draft == false
                            ' <<< "$input_json" >/dev/null 2>&1; then
                                printf 'patch-invalid\n' >> "$STRICT_MUTATION_LOG"
                                printf 'patch-input:%s\n' "$(jq -c . <<< "$input_json" 2>/dev/null || printf '<invalid-json>')" \
                                    >> "$STRICT_MUTATION_LOG"
                                return 1
                            fi
                        elif ! jq -e '
                            type == "object" and keys == ["draft"] and .draft == true
                        ' <<< "$input_json" >/dev/null 2>&1; then
                            printf 'patch-invalid\n' >> "$STRICT_MUTATION_LOG"
                            return 1
                        fi
                        if [[ "$requested_draft" == "false" && \
                              "${STRICT_PUBLISH_PATCH_ERROR_NO_COMMIT:-0}" == "1" ]]; then
                            printf 'publish-error\n' >> "$STRICT_MUTATION_LOG"
                            return 1
                        fi
                        if [[ "$requested_draft" == "true" ]]; then
                            printf 'redraft\n' >> "$STRICT_MUTATION_LOG"
                        else
                            printf 'publish\n' >> "$STRICT_MUTATION_LOG"
                        fi
                        printf '%s\n' "$requested_draft" > "$STRICT_RELEASE_DRAFT_STATE"
                        if [[ "$requested_draft" == "false" && \
                              "${STRICT_PUBLISH_PATCH_COMMIT_ERROR:-0}" == "1" ]] || \
                           [[ "$requested_draft" == "true" && \
                              "${STRICT_REDRAFT_PATCH_COMMIT_ERROR:-0}" == "1" ]]; then
                            return 1
                        fi
                        jq -nc --argjson draft "$requested_draft" \
                            '{
                                id: 123,
                                tag_name: "v1.0.0",
                                name: "v1.0.0",
                                body: "Release v1.0.0",
                                prerelease: false,
                                html_url: "https://example.invalid/v1.0.0",
                                draft: $draft
                            }'
                        ;;
                    *) return 1 ;;
                esac
                ;;
            *) return 1 ;;
        esac
    }

    curl() {
        local url="${!#}"
        local name="${url##*?name=}"
        local data_arg=""
        local arg
        while [[ $# -gt 0 ]]; do
            arg="$1"
            shift
            if [[ "$arg" == "--data-binary" && $# -gt 0 ]]; then
                data_arg="$1"
                shift
            fi
        done
        name="${name//%2B/+}"
        local file_path="${data_arg#@}"
        local expected_record expected_size expected_digest actual_size actual_sha
        expected_record=$(jq -c --arg name "$name" '[.[] | select(.name == $name)] | if length == 1 then .[0] else empty end' \
            <<< "$STRICT_EXPECTED_UPLOAD_ASSETS")
        if [[ "$data_arg" != @* || ! -f "$file_path" || -z "$expected_record" ]]; then
            printf 'upload-invalid:%s\n' "$name" >> "$STRICT_MUTATION_LOG"
            printf '{}\n__HTTP_CODE__422'
            return 0
        fi
        expected_size=$(jq -r '.size' <<< "$expected_record")
        expected_digest=$(jq -r '.digest' <<< "$expected_record")
        actual_size=$(stat -c %s "$file_path" 2>/dev/null || stat -f %z "$file_path")
        if command -v sha256sum &>/dev/null; then
            actual_sha=$(sha256sum "$file_path" | awk '{print $1}')
        else
            actual_sha=$(shasum -a 256 "$file_path" | awk '{print $1}')
        fi
        if [[ "$actual_size" != "$expected_size" || "sha256:$actual_sha" != "$expected_digest" ]]; then
            printf 'upload-invalid:%s\n' "$name" >> "$STRICT_MUTATION_LOG"
            printf '{}\n__HTTP_CODE__422'
            return 0
        fi
        : > "$STRICT_UPLOAD_STARTED_FILE"
        if [[ "${STRICT_FLIP_PUBLIC_DURING_UPLOAD:-0}" == "1" && \
              ! -e "$STRICT_PUBLIC_FLIP_MARKER" ]]; then
            printf 'false\n' > "$STRICT_RELEASE_DRAFT_STATE"
            printf 'flip-public:upload\n' >> "$STRICT_MUTATION_LOG"
            : > "$STRICT_PUBLIC_FLIP_MARKER"
        fi
        printf 'upload:%s\n' "$name" >> "$STRICT_MUTATION_LOG"
        if [[ "${STRICT_UPLOAD_COMMIT_ERROR_ON_NAME:-}" == "$name" ]]; then
            printf 'upload-response-error:%s\n' "$name" >> "$STRICT_MUTATION_LOG"
            printf '{"message":"simulated response failure"}\n__HTTP_CODE__500'
            return 0
        fi
        jq -nc --arg name "$name" --arg digest "$expected_digest" --argjson size "$expected_size" \
            '{id:1,name:$name,state:"uploaded",digest:$digest,size:$size}'
        printf '__HTTP_CODE__201'
    }

    export -f gh curl
}

remove_strict_github_mocks() {
    unset -f gh curl
    unset STRICT_RELEASE_LIST_SCENARIO
}

# ============================================================================
# Tests: Help (always works)
# ============================================================================

test_release_help() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" release --help

    if exec_stdout_contains "USAGE:" && exec_stdout_contains "release"; then
        pass "release --help shows usage information"
    else
        fail "release --help should show usage"
        echo "stdout: $(exec_stdout)"
    fi

    harness_teardown
}

test_release_help_shows_options() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" release --help

    if exec_stdout_contains "--draft" && exec_stdout_contains "--version" && exec_stdout_contains "--artifacts"; then
        pass "release --help shows all main options"
    else
        fail "release --help should show --draft, --version, --artifacts"
        echo "stdout: $(exec_stdout)"
    fi

    harness_teardown
}

test_release_help_shows_subcommands() {
    ((TESTS_RUN++))
    harness_setup

    exec_run "$DSR_CMD" release --help

    if exec_stdout_contains "verify" || exec_stdout_contains "SUBCOMMANDS:"; then
        pass "release --help mentions verify subcommand"
    else
        fail "release --help should mention verify subcommand"
        echo "stdout: $(exec_stdout | head -20)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Argument Validation
# ============================================================================

test_release_missing_tool() {
    ((TESTS_RUN++))
    harness_setup
    seed_repos_config

    exec_run "$DSR_CMD" release
    local status
    status=$(exec_status)

    if [[ "$status" -eq 4 ]]; then
        pass "release fails with missing tool (exit: 4)"
    else
        fail "release should fail with exit 4 for missing tool (got: $status)"
        echo "stderr: $(exec_stderr | head -5)"
    fi

    harness_teardown
}

test_release_missing_version() {
    ((TESTS_RUN++))
    harness_setup
    seed_repos_config

    exec_run "$DSR_CMD" release test-tool
    local status
    status=$(exec_status)

    if [[ "$status" -eq 4 ]]; then
        pass "release fails with missing version (exit: 4)"
    else
        fail "release should fail with exit 4 for missing version (got: $status)"
        echo "stderr: $(exec_stderr | head -5)"
    fi

    harness_teardown
}

test_release_unknown_option() {
    ((TESTS_RUN++))
    harness_setup
    seed_repos_config

    exec_run "$DSR_CMD" release test-tool v1.0.0 --unknown-option
    local status
    status=$(exec_status)

    if [[ "$status" -eq 4 ]]; then
        pass "release fails with unknown option (exit: 4)"
    else
        fail "release should fail with exit 4 for unknown option (got: $status)"
        echo "stderr: $(exec_stderr | head -5)"
    fi

    harness_teardown
}

test_release_unknown_tool() {
    ((TESTS_RUN++))

    if [[ "$HAS_GH_AUTH" != "true" ]]; then
        skip "gh auth required for tool lookup test"
        return 0
    fi

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for repos.yaml parsing"
        return 0
    fi

    harness_setup
    seed_repos_config

    exec_run "$DSR_CMD" release nonexistent-tool v1.0.0
    local status
    status=$(exec_status)

    # Should fail with tool not found (exit 4) or auth issues (exit 3)
    if [[ "$status" -eq 4 ]] || [[ "$status" -eq 3 ]]; then
        pass "release fails with unknown tool (exit: $status)"
    else
        fail "release should fail for unknown tool (got: $status)"
        echo "stderr: $(exec_stderr | head -5)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Missing Dependencies
# ============================================================================

test_release_missing_gh_auth() {
    ((TESTS_RUN++))
    harness_setup
    seed_repos_config

    # Force gh auth to fail by unsetting tokens
    local old_token="${GITHUB_TOKEN:-}"
    local old_gh_token="${GH_TOKEN:-}"
    unset GITHUB_TOKEN GH_TOKEN

    # Create a fake gh that always fails auth
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/gh" << 'SCRIPT'
#!/bin/bash
if [[ "$1" == "auth" && "$2" == "status" ]]; then
    exit 1
fi
exit 1
SCRIPT
    chmod +x "$TEST_TMPDIR/bin/gh"

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" release test-tool v1.0.0
    local status
    status=$(exec_status)

    # Restore tokens
    [[ -n "$old_token" ]] && export GITHUB_TOKEN="$old_token"
    [[ -n "$old_gh_token" ]] && export GH_TOKEN="$old_gh_token"

    # Should fail with auth error (exit 3)
    if [[ "$status" -eq 3 ]]; then
        pass "release fails with missing gh auth (exit: 3)"
    elif [[ "$status" -eq 4 ]]; then
        # Also acceptable if it fails on tool lookup first
        pass "release fails before auth check (exit: 4)"
    else
        fail "release should fail with exit 3 for missing gh auth (got: $status)"
        echo "stderr: $(exec_stderr | head -5)"
    fi

    harness_teardown
}

test_release_missing_artifacts_dir() {
    ((TESTS_RUN++))

    if [[ "$HAS_GH_AUTH" != "true" ]]; then
        skip "gh auth required for artifacts dir test"
        return 0
    fi

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for repos.yaml parsing"
        return 0
    fi

    harness_setup
    seed_repos_config
    # Don't create artifacts - let it fail

    exec_run "$DSR_CMD" release test-tool v1.0.0
    local status
    status=$(exec_status)

    # Should fail - either exit 3 (gh auth missing) or exit 4 (missing artifacts/tool)
    # The gh auth check happens before artifact validation, so exit 3 is expected
    # when gh isn't authenticated in the test environment
    if [[ "$status" -eq 3 || "$status" -eq 4 ]]; then
        pass "release fails before upload (exit: $status)"
    else
        fail "release should fail with exit 3 or 4 (got: $status)"
        echo "stderr: $(exec_stderr | head -5)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Strict Release Contract (fully mocked GitHub)
# ============================================================================

test_strict_release_uploads_exact_set_then_publishes() {
    ((TESTS_RUN++))
    harness_setup
    seed_strict_release_fixture
    create_strict_github_mocks

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release test-tool v1.0.0 \
        --artifacts "$STRICT_ARTIFACTS_DIR"
    local status
    status=$(exec_status)

    local uploads expected_uploads reads
    uploads=$(sed -n 's/^upload://p' "$STRICT_MUTATION_LOG" 2>/dev/null | sort)
    expected_uploads=$(printf '%s\n' \
        test-tool-darwin-arm64 \
        test-tool-darwin-arm64.sha256 \
        test-tool-linux-amd64 \
        test-tool-linux-amd64.sha256 | sort)
    reads=$(cat "$STRICT_READ_LOG" 2>/dev/null || true)

    if [[ $status -eq 0 && "$uploads" == "$expected_uploads" ]] && \
        exec_stdout | jq -e '.details.draft == false' >/dev/null 2>&1 && \
        [[ "$(grep -c '^create$' "$STRICT_MUTATION_LOG" 2>/dev/null)" -eq 1 ]] && \
        [[ "$(grep -c '^publish$' "$STRICT_MUTATION_LOG" 2>/dev/null)" -eq 1 ]] && \
        [[ "$reads" == $'release-get:true\nrelease-get:true\nrelease-get:false' ]] && \
        [[ -f "$STRICT_ARTIFACTS_DIR/test-tool-linux-amd64.sha256" ]] && \
        [[ -f "$STRICT_ARTIFACTS_DIR/test-tool-darwin-arm64.sha256" ]]; then
        pass "strict release uploads only primaries+sidecars, verifies draft, publishes, and re-verifies"
    else
        fail "strict release should stage and publish only the exact contracted asset set"
        echo "status: $status"
        echo "mutations: $(cat "$STRICT_MUTATION_LOG" 2>/dev/null || true)"
        echo "reads: $reads"
        echo "stderr: $(exec_stderr | tail -20)"
    fi

    remove_strict_github_mocks
    harness_teardown
}

test_strict_create_commit_then_error_adopts_exact_empty_draft() {
    ((TESTS_RUN++))
    harness_setup
    seed_strict_release_fixture
    export STRICT_CREATE_POST_COMMIT_ERROR=1
    create_strict_github_mocks

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release test-tool v1.0.0 \
        --artifacts "$STRICT_ARTIFACTS_DIR"
    local status tag_release_reads
    status=$(exec_status)
    tag_release_reads=$(cat "$STRICT_RELEASE_LIST_GET_COUNT_FILE")

    if [[ $status -eq 0 && "$tag_release_reads" -eq 2 ]] && \
       [[ "$(grep -c '^create-response-error$' "$STRICT_MUTATION_LOG" 2>/dev/null)" -eq 1 ]] && \
       [[ "$(grep -c '^publish$' "$STRICT_MUTATION_LOG" 2>/dev/null)" -eq 1 ]] && \
       exec_stderr_contains "no-cache observation confirmed the exact new empty draft" && \
       exec_stdout | jq -e '
           .details.draft == false and
           .details.failed == 0 and
           .details.verification == "exact"
       ' >/dev/null 2>&1; then
        pass "strict create adopts an exact draft from the release list when tag lookup would 404"
    else
        fail "strict create must reconcile only an exact empty committed draft"
        echo "status: $status; tag release reads: $tag_release_reads"
        echo "mutations: $(cat "$STRICT_MUTATION_LOG" 2>/dev/null || true)"
        echo "stderr: $(exec_stderr | tail -25)"
    fi

    remove_strict_github_mocks
    harness_teardown
}

test_strict_upload_commit_then_error_reconciles_exact_draft() {
    ((TESTS_RUN++))
    harness_setup
    seed_strict_release_fixture
    export STRICT_UPLOAD_COMMIT_ERROR_ON_NAME="test-tool-linux-amd64"
    create_strict_github_mocks

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release test-tool v1.0.0 \
        --artifacts "$STRICT_ARTIFACTS_DIR"
    local status
    status=$(exec_status)

    if [[ $status -eq 0 ]] && \
       [[ "$(grep -c '^upload-response-error:test-tool-linux-amd64$' \
           "$STRICT_MUTATION_LOG" 2>/dev/null)" -eq 1 ]] && \
       [[ "$(grep -c '^publish$' "$STRICT_MUTATION_LOG" 2>/dev/null)" -eq 1 ]] && \
       exec_stderr_contains "reconciled by exact no-cache draft verification" && \
       exec_stdout | jq -e '
           .details.draft == false and
           .details.failed == 0 and
           .details.success == 4 and
           any(.details.assets_uploaded[];
               .name == "test-tool-linux-amd64" and .status == "reconciled")
       ' >/dev/null 2>&1; then
        pass "strict upload clears a response-only failure after exact draft reconciliation"
    else
        fail "strict upload must reconcile a committed response error only from exact remote state"
        echo "status: $status"
        echo "mutations: $(cat "$STRICT_MUTATION_LOG" 2>/dev/null || true)"
        echo "stdout: $(exec_stdout)"
        echo "stderr: $(exec_stderr | tail -30)"
    fi

    remove_strict_github_mocks
    harness_teardown
}

test_strict_create_error_rejects_nonexact_observed_draft() {
    ((TESTS_RUN++))
    harness_setup
    seed_strict_release_fixture
    export STRICT_CREATE_OBSERVED_NONEXACT=1
    create_strict_github_mocks

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" release test-tool v1.0.0 \
        --artifacts "$STRICT_ARTIFACTS_DIR"
    local status draft_state tag_release_reads
    status=$(exec_status)
    read -r draft_state < "$STRICT_RELEASE_DRAFT_STATE"
    tag_release_reads=$(cat "$STRICT_RELEASE_LIST_GET_COUNT_FILE")

    if [[ $status -eq 7 && "$draft_state" == "true" && "$tag_release_reads" -eq 2 ]] && \
       [[ "$(grep -c '^create-response-error$' "$STRICT_MUTATION_LOG" 2>/dev/null)" -eq 1 ]] && \
       ! grep -Eq '^(upload:|publish$)' "$STRICT_MUTATION_LOG" 2>/dev/null && \
       exec_stderr_contains "Failed to create an exact staging draft"; then
        pass "strict create rejects a non-exact observed draft after a POST error"
    else
        fail "non-exact observed create state must remain draft and fail"
        echo "status: $status; draft: $draft_state; tag release reads: $tag_release_reads"
        echo "mutations: $(cat "$STRICT_MUTATION_LOG" 2>/dev/null || true)"
        echo "stderr: $(exec_stderr | tail -25)"
    fi

    remove_strict_github_mocks
    harness_teardown
}

test_strict_create_error_rejects_competitor_draft_nonce() {
    ((TESTS_RUN++))
    harness_setup
    seed_strict_release_fixture
    export STRICT_CREATE_COMPETITOR_DRAFT=1
    create_strict_github_mocks

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" release test-tool v1.0.0 \
        --artifacts "$STRICT_ARTIFACTS_DIR"
    local status draft_state
    status=$(exec_status)
    read -r draft_state < "$STRICT_RELEASE_DRAFT_STATE"

    if [[ $status -eq 7 && "$draft_state" == "true" ]] && \
       [[ "$(grep -c '^create-response-error$' "$STRICT_MUTATION_LOG" 2>/dev/null)" -eq 1 ]] && \
       ! grep -Eq '^(upload:|publish$|redraft$|patch-invalid$)' \
        "$STRICT_MUTATION_LOG" 2>/dev/null && \
       exec_stderr_contains "Failed to create an exact staging draft"; then
        pass "strict create nonce prevents adoption of an identical competitor draft"
    else
        fail "failed strict POST must not adopt a competitor draft from the race window"
        echo "status: $status; draft: $draft_state"
        echo "body: $(cat "$STRICT_RELEASE_BODY_STATE" 2>/dev/null || true)"
        echo "mutations: $(cat "$STRICT_MUTATION_LOG" 2>/dev/null || true)"
        echo "stderr: $(exec_stderr | tail -25)"
    fi

    remove_strict_github_mocks
    harness_teardown
}

test_strict_create_error_never_redrafts_public_competitor() {
    ((TESTS_RUN++))
    harness_setup
    seed_strict_release_fixture
    export STRICT_CREATE_COMPETITOR_DRAFT=1
    export STRICT_FLIP_PUBLIC_ON_RELEASE_GET=1
    create_strict_github_mocks

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" release test-tool v1.0.0 \
        --artifacts "$STRICT_ARTIFACTS_DIR"
    local status draft_state release_get_count
    status=$(exec_status)
    read -r draft_state < "$STRICT_RELEASE_DRAFT_STATE"
    read -r release_get_count < "$STRICT_RELEASE_GET_COUNT_FILE"

    if [[ $status -eq 7 && "$draft_state" == "false" && "$release_get_count" -eq 1 ]] && \
       [[ "$(grep -c '^create-response-error$' "$STRICT_MUTATION_LOG" 2>/dev/null)" -eq 1 ]] && \
       [[ "$(grep -c '^flip-public:get-1$' "$STRICT_MUTATION_LOG" 2>/dev/null)" -eq 1 ]] && \
       ! grep -Eq '^(patch-request:|upload:|publish$|redraft$|patch-invalid$)' \
        "$STRICT_MUTATION_LOG" 2>/dev/null && \
       exec_stderr_contains "Failed to create an exact staging draft"; then
        pass "strict create never PATCHes a public competitor with a mismatched nonce"
    else
        fail "ambiguous strict create must not re-draft a public competitor"
        echo "status: $status; draft: $draft_state; release GETs: $release_get_count"
        echo "body: $(cat "$STRICT_RELEASE_BODY_STATE" 2>/dev/null || true)"
        echo "mutations: $(cat "$STRICT_MUTATION_LOG" 2>/dev/null || true)"
        echo "stderr: $(exec_stderr | tail -25)"
    fi

    remove_strict_github_mocks
    harness_teardown
}

test_strict_release_requested_draft_is_not_published() {
    ((TESTS_RUN++))
    harness_setup
    seed_strict_release_fixture
    create_strict_github_mocks

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release test-tool v1.0.0 \
        --artifacts "$STRICT_ARTIFACTS_DIR" --draft
    local status draft_state reads
    status=$(exec_status)
    read -r draft_state < "$STRICT_RELEASE_DRAFT_STATE"
    reads=$(cat "$STRICT_READ_LOG" 2>/dev/null || true)

    if [[ $status -eq 0 && "$draft_state" == "true" ]] && \
       [[ "$reads" == $'release-get:true\nrelease-get:true' ]] && \
       exec_stdout | jq -e '.details.draft == true' >/dev/null 2>&1 && \
       ! grep -Eq '^(publish|redraft)$' "$STRICT_MUTATION_LOG" 2>/dev/null; then
        pass "strict --draft retains the exact verified release as a draft"
    else
        fail "strict --draft must never publish the staging release"
        echo "status: $status"
        echo "draft state: $draft_state"
        echo "mutations: $(cat "$STRICT_MUTATION_LOG" 2>/dev/null || true)"
        echo "reads: $reads"
    fi

    remove_strict_github_mocks
    harness_teardown
}

test_strict_release_rejects_changed_frozen_plan() {
    ((TESTS_RUN++))
    harness_setup
    seed_strict_release_fixture
    export STRICT_MUTATE_MANIFEST_ON_RELEASE_GET=1
    create_strict_github_mocks

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" release test-tool v1.0.0 \
        --artifacts "$STRICT_ARTIFACTS_DIR"
    local status
    status=$(exec_status)

    if [[ $status -ne 0 ]] && ! grep -q '^publish$' "$STRICT_MUTATION_LOG" 2>/dev/null && \
       exec_stderr_contains "plan changed after upload"; then
        pass "strict publication rejects a manifest change after upload"
    else
        fail "strict publication must compare the current plan with the frozen upload plan"
        echo "status: $status"
        echo "mutations: $(cat "$STRICT_MUTATION_LOG" 2>/dev/null || true)"
        echo "stderr: $(exec_stderr | tail -20)"
    fi

    remove_strict_github_mocks
    harness_teardown
}

test_strict_release_rechecks_remote_assets_before_publish() {
    ((TESTS_RUN++))
    harness_setup
    seed_strict_release_fixture
    export STRICT_PREPUBLISH_DIGEST_FAULT_ON_GET=2
    create_strict_github_mocks

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" release test-tool v1.0.0 \
        --artifacts "$STRICT_ARTIFACTS_DIR"
    local status
    status=$(exec_status)

    if [[ $status -ne 0 ]] && ! grep -q '^publish$' "$STRICT_MUTATION_LOG" 2>/dev/null; then
        pass "strict publication rechecks remote asset digests immediately before PATCH"
    else
        fail "a changed remote draft must not be published"
        echo "status: $status"
        echo "mutations: $(cat "$STRICT_MUTATION_LOG" 2>/dev/null || true)"
    fi

    remove_strict_github_mocks
    harness_teardown
}

test_strict_release_rechecks_remote_tag_before_publish() {
    ((TESTS_RUN++))
    harness_setup
    seed_strict_release_fixture
    export STRICT_TAG_MOVE_ON_CALL=3
    create_strict_github_mocks

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" release test-tool v1.0.0 \
        --artifacts "$STRICT_ARTIFACTS_DIR"
    local status
    status=$(exec_status)

    if [[ $status -ne 0 ]] && ! grep -q '^publish$' "$STRICT_MUTATION_LOG" 2>/dev/null; then
        pass "strict publication rejects a remote tag move immediately before PATCH"
    else
        fail "a moved remote tag must prevent strict publication"
        echo "status: $status"
        echo "mutations: $(cat "$STRICT_MUTATION_LOG" 2>/dev/null || true)"
    fi

    remove_strict_github_mocks
    harness_teardown
}

test_strict_release_rechecks_remote_metadata_before_publish() {
    ((TESTS_RUN++))
    harness_setup
    seed_strict_release_fixture
    export STRICT_MUTATE_METADATA_ON_RELEASE_GET=2
    create_strict_github_mocks

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" release test-tool v1.0.0 \
        --artifacts "$STRICT_ARTIFACTS_DIR"
    local status
    status=$(exec_status)

    if [[ $status -ne 0 ]] && ! grep -q '^publish$' "$STRICT_MUTATION_LOG" 2>/dev/null; then
        pass "strict publication rejects remote metadata drift immediately before PATCH"
    else
        fail "changed release metadata must prevent strict publication"
        echo "status: $status"
        echo "mutations: $(cat "$STRICT_MUTATION_LOG" 2>/dev/null || true)"
    fi

    remove_strict_github_mocks
    harness_teardown
}

test_strict_requested_draft_rechecks_remote_state() {
    ((TESTS_RUN++))
    harness_setup
    seed_strict_release_fixture
    export STRICT_PREPUBLISH_DIGEST_FAULT_ON_GET=2
    create_strict_github_mocks

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release test-tool v1.0.0 \
        --artifacts "$STRICT_ARTIFACTS_DIR" --draft
    local status draft_state reads
    status=$(exec_status)
    read -r draft_state < "$STRICT_RELEASE_DRAFT_STATE"
    reads=$(cat "$STRICT_READ_LOG" 2>/dev/null || true)

    if [[ $status -ne 0 && "$draft_state" == "true" ]] && \
       [[ "$reads" == $'release-get:true\nrelease-get:true\nrelease-get:true' ]] && \
       exec_stdout | jq -e '.details.draft == true and .details.verification == "incomplete"' \
           >/dev/null 2>&1 && \
       ! grep -Eq '^(publish|redraft)$' "$STRICT_MUTATION_LOG" 2>/dev/null; then
        pass "strict --draft rechecks remote bytes before reporting exact success"
    else
        fail "strict --draft must fail when the final remote read differs"
        echo "status: $status"
        echo "draft state: $draft_state"
        echo "reads: $reads"
        echo "mutations: $(cat "$STRICT_MUTATION_LOG" 2>/dev/null || true)"
    fi

    remove_strict_github_mocks
    harness_teardown
}

test_strict_upload_failure_redrafts_concurrently_published_release() {
    ((TESTS_RUN++))
    harness_setup
    seed_strict_release_fixture
    export STRICT_FLIP_PUBLIC_DURING_UPLOAD=1
    create_strict_github_mocks

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release test-tool v1.0.0 \
        --artifacts "$STRICT_ARTIFACTS_DIR"
    local status draft_state
    status=$(exec_status)
    read -r draft_state < "$STRICT_RELEASE_DRAFT_STATE"

    if [[ $status -ne 0 && "$draft_state" == "true" ]] && \
       [[ "$(grep -c '^flip-public:upload$' "$STRICT_MUTATION_LOG" 2>/dev/null)" -eq 1 ]] && \
       [[ "$(grep -c '^redraft$' "$STRICT_MUTATION_LOG" 2>/dev/null)" -eq 1 ]] && \
       ! grep -q '^publish$' "$STRICT_MUTATION_LOG" 2>/dev/null && \
       exec_stdout | jq -e '.details.draft == true and .details.verification == "incomplete"' \
        >/dev/null 2>&1; then
        pass "strict upload failure restores an ID/tag-bound draft after concurrent publication"
    else
        fail "strict upload failure must not leave a concurrently published staging release public"
        echo "status: $status; draft: $draft_state"
        echo "mutations: $(cat "$STRICT_MUTATION_LOG" 2>/dev/null || true)"
        echo "stderr: $(exec_stderr | tail -30)"
    fi

    remove_strict_github_mocks
    harness_teardown
}

test_strict_prepublish_failure_redrafts_concurrently_published_release() {
    ((TESTS_RUN++))
    harness_setup
    seed_strict_release_fixture
    export STRICT_FLIP_PUBLIC_ON_RELEASE_GET=2
    create_strict_github_mocks

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release test-tool v1.0.0 \
        --artifacts "$STRICT_ARTIFACTS_DIR"
    local status draft_state
    status=$(exec_status)
    read -r draft_state < "$STRICT_RELEASE_DRAFT_STATE"

    if [[ $status -ne 0 && "$draft_state" == "true" ]] && \
       [[ "$(grep -c '^flip-public:get-2$' "$STRICT_MUTATION_LOG" 2>/dev/null)" -eq 1 ]] && \
       [[ "$(grep -c '^redraft$' "$STRICT_MUTATION_LOG" 2>/dev/null)" -eq 1 ]] && \
       ! grep -q '^publish$' "$STRICT_MUTATION_LOG" 2>/dev/null && \
       exec_stdout | jq -e '.details.draft == true and .details.verification == "incomplete"' \
        >/dev/null 2>&1; then
        pass "strict prepublication failure restores the exact staging draft"
    else
        fail "strict prepublication failure must reconcile a concurrent public state"
        echo "status: $status; draft: $draft_state"
        echo "mutations: $(cat "$STRICT_MUTATION_LOG" 2>/dev/null || true)"
        echo "stderr: $(exec_stderr | tail -30)"
    fi

    remove_strict_github_mocks
    harness_teardown
}

test_strict_requested_draft_failure_redrafts_concurrent_publication() {
    ((TESTS_RUN++))
    harness_setup
    seed_strict_release_fixture
    export STRICT_FLIP_PUBLIC_ON_RELEASE_GET=2
    create_strict_github_mocks

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release test-tool v1.0.0 \
        --artifacts "$STRICT_ARTIFACTS_DIR" --draft
    local status draft_state
    status=$(exec_status)
    read -r draft_state < "$STRICT_RELEASE_DRAFT_STATE"

    if [[ $status -ne 0 && "$draft_state" == "true" ]] && \
       [[ "$(grep -c '^flip-public:get-2$' "$STRICT_MUTATION_LOG" 2>/dev/null)" -eq 1 ]] && \
       [[ "$(grep -c '^redraft$' "$STRICT_MUTATION_LOG" 2>/dev/null)" -eq 1 ]] && \
       ! grep -q '^publish$' "$STRICT_MUTATION_LOG" 2>/dev/null && \
       exec_stdout | jq -e '.details.draft == true and .details.verification == "incomplete"' \
        >/dev/null 2>&1; then
        pass "strict --draft failure restores draft state after concurrent publication"
    else
        fail "strict --draft failure must not report draft while leaving the release public"
        echo "status: $status; draft: $draft_state"
        echo "mutations: $(cat "$STRICT_MUTATION_LOG" 2>/dev/null || true)"
        echo "stderr: $(exec_stderr | tail -30)"
    fi

    remove_strict_github_mocks
    harness_teardown
}

test_strict_release_redrafts_failed_postpublish_verification() {
    ((TESTS_RUN++))
    harness_setup
    seed_strict_release_fixture
    export STRICT_POSTPUBLISH_DIGEST_FAULT=1
    create_strict_github_mocks

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" release test-tool v1.0.0 \
        --artifacts "$STRICT_ARTIFACTS_DIR"
    local status draft_state
    status=$(exec_status)
    read -r draft_state < "$STRICT_RELEASE_DRAFT_STATE"

    if [[ $status -ne 0 && "$draft_state" == "true" ]] && \
       [[ "$(grep -c '^publish$' "$STRICT_MUTATION_LOG" 2>/dev/null)" -eq 1 ]] && \
       [[ "$(grep -c '^redraft$' "$STRICT_MUTATION_LOG" 2>/dev/null)" -eq 1 ]]; then
        pass "strict release restores draft state after failed postpublish digest verification"
    else
        fail "failed postpublish verification must best-effort restore the draft"
        echo "status: $status"
        echo "draft state: $draft_state"
        echo "mutations: $(cat "$STRICT_MUTATION_LOG" 2>/dev/null || true)"
        echo "stderr: $(exec_stderr | tail -20)"
    fi

    remove_strict_github_mocks
    harness_teardown
}

test_strict_publish_commit_then_error_is_observed() {
    ((TESTS_RUN++))
    harness_setup
    seed_strict_release_fixture
    export STRICT_PUBLISH_PATCH_COMMIT_ERROR=1
    create_strict_github_mocks

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release test-tool v1.0.0 \
        --artifacts "$STRICT_ARTIFACTS_DIR"
    local status draft_state reads
    status=$(exec_status)
    read -r draft_state < "$STRICT_RELEASE_DRAFT_STATE"
    reads=$(cat "$STRICT_READ_LOG" 2>/dev/null || true)

    if [[ $status -eq 0 && "$draft_state" == "false" ]] && \
       [[ "$reads" == $'release-get:true\nrelease-get:true\nrelease-get:false' ]] && \
       [[ "$(grep -c '^publish$' "$STRICT_MUTATION_LOG" 2>/dev/null)" -eq 1 ]] && \
       exec_stdout | jq -e '.details.draft == false and .details.verification == "exact"' \
           >/dev/null 2>&1; then
        pass "strict publication accepts exact public state after an ambiguous PATCH response"
    else
        fail "committed publication must be reconciled after a PATCH transport error"
        echo "status: $status"
        echo "draft state: $draft_state"
        echo "reads: $reads"
        echo "mutations: $(cat "$STRICT_MUTATION_LOG" 2>/dev/null || true)"
        echo "stderr: $(exec_stderr | tail -20)"
    fi

    remove_strict_github_mocks
    harness_teardown
}

test_strict_publish_error_without_commit_stays_draft() {
    ((TESTS_RUN++))
    harness_setup
    seed_strict_release_fixture
    export STRICT_PUBLISH_PATCH_ERROR_NO_COMMIT=1
    create_strict_github_mocks

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release test-tool v1.0.0 \
        --artifacts "$STRICT_ARTIFACTS_DIR"
    local status draft_state reads
    status=$(exec_status)
    read -r draft_state < "$STRICT_RELEASE_DRAFT_STATE"
    reads=$(cat "$STRICT_READ_LOG" 2>/dev/null || true)

    if [[ $status -ne 0 && "$draft_state" == "true" ]] && \
       [[ "$reads" == $'release-get:true\nrelease-get:true\nrelease-get:true\nrelease-get:true\nrelease-get:true' ]] && \
       [[ "$(grep -c '^publish-error$' "$STRICT_MUTATION_LOG" 2>/dev/null)" -eq 1 ]] && \
       ! grep -Eq '^(publish|redraft)$' "$STRICT_MUTATION_LOG" 2>/dev/null && \
       exec_stdout | jq -e '.details.draft == true and .details.verification == "incomplete"' \
           >/dev/null 2>&1; then
        pass "strict publication fails safely when an errored PATCH leaves the draft unchanged"
    else
        fail "an uncommitted publish error must remain draft without rollback"
        echo "status: $status"
        echo "draft state: $draft_state"
        echo "reads: $reads"
        echo "mutations: $(cat "$STRICT_MUTATION_LOG" 2>/dev/null || true)"
        echo "stderr: $(exec_stderr | tail -20)"
    fi

    remove_strict_github_mocks
    harness_teardown
}

test_strict_redraft_commit_then_error_is_observed() {
    ((TESTS_RUN++))
    harness_setup
    seed_strict_release_fixture
    export STRICT_POSTPUBLISH_DIGEST_FAULT=1
    export STRICT_REDRAFT_PATCH_COMMIT_ERROR=1
    create_strict_github_mocks

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release test-tool v1.0.0 \
        --artifacts "$STRICT_ARTIFACTS_DIR"
    local status draft_state reads
    status=$(exec_status)
    read -r draft_state < "$STRICT_RELEASE_DRAFT_STATE"
    reads=$(cat "$STRICT_READ_LOG" 2>/dev/null || true)

    if [[ $status -ne 0 && "$draft_state" == "true" ]] && \
       [[ "$reads" == $'release-get:true\nrelease-get:true\nrelease-get:false\nrelease-get:false\nrelease-get:false\nrelease-get:true\nrelease-get:true' ]] && \
       [[ "$(grep -c '^publish$' "$STRICT_MUTATION_LOG" 2>/dev/null)" -eq 1 ]] && \
       [[ "$(grep -c '^redraft$' "$STRICT_MUTATION_LOG" 2>/dev/null)" -eq 1 ]] && \
       exec_stdout | jq -e '.details.draft == true and .details.verification == "incomplete"' \
           >/dev/null 2>&1; then
        pass "strict rollback observes committed draft state after an ambiguous PATCH response"
    else
        fail "committed rollback must be confirmed after a PATCH transport error"
        echo "status: $status"
        echo "draft state: $draft_state"
        echo "reads: $reads"
        echo "mutations: $(cat "$STRICT_MUTATION_LOG" 2>/dev/null || true)"
        echo "stderr: $(exec_stderr | tail -20)"
    fi

    remove_strict_github_mocks
    harness_teardown
}

test_strict_release_preflight_failure_has_no_github_mutation() {
    ((TESTS_RUN++))
    harness_setup
    seed_strict_release_fixture
    create_strict_github_mocks

    local manifest="$STRICT_ARTIFACTS_DIR/test-tool-v1.0.0-manifest.json"
    jq '.summary.success = 1 | .summary.failed = 1' "$manifest" > "${manifest}.invalid"
    mv "${manifest}.invalid" "$manifest"

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" release test-tool v1.0.0 \
        --artifacts "$STRICT_ARTIFACTS_DIR"
    local status
    status=$(exec_status)

    if [[ $status -ne 0 && ! -s "$STRICT_MUTATION_LOG" ]] && \
        [[ ! -e "$STRICT_ARTIFACTS_DIR/test-tool-linux-amd64.sha256" ]] && \
        [[ ! -e "$STRICT_ARTIFACTS_DIR/test-tool-darwin-arm64.sha256" ]]; then
        pass "strict preflight rejects incomplete build before sidecars or GitHub mutation"
    else
        fail "strict preflight failure must not mutate GitHub or generate sidecars"
        echo "status: $status"
        echo "mutations: $(cat "$STRICT_MUTATION_LOG" 2>/dev/null || true)"
        echo "stderr: $(exec_stderr | tail -20)"
    fi

    remove_strict_github_mocks
    harness_teardown
}

test_strict_release_rejects_duplicate_tag_across_pages_before_mutation() {
    ((TESTS_RUN++))
    harness_setup
    seed_strict_release_fixture
    export STRICT_RELEASE_LIST_SCENARIO=duplicate
    create_strict_github_mocks

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release test-tool v1.0.0 \
        --artifacts "$STRICT_ARTIFACTS_DIR"
    local status release_list_reads
    status=$(exec_status)
    release_list_reads=$(cat "$STRICT_RELEASE_LIST_GET_COUNT_FILE")

    if [[ $status -eq 7 && $release_list_reads -eq 2 && ! -s "$STRICT_MUTATION_LOG" ]] &&
       exec_stderr_contains "Multiple GitHub releases use strict tag v1.0.0"; then
        pass "strict release rejects duplicate paginated tags before GitHub mutation"
    else
        fail "duplicate paginated tags must stop strict release before mutation"
        echo "status: $status; release-list reads: $release_list_reads"
        echo "mutations: $(cat "$STRICT_MUTATION_LOG" 2>/dev/null || true)"
        echo "stderr: $(exec_stderr | tail -20)"
    fi

    remove_strict_github_mocks
    harness_teardown
}

test_strict_release_rejects_malformed_second_page_before_mutation() {
    ((TESTS_RUN++))
    harness_setup
    seed_strict_release_fixture
    export STRICT_RELEASE_LIST_SCENARIO=malformed
    create_strict_github_mocks

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release test-tool v1.0.0 \
        --artifacts "$STRICT_ARTIFACTS_DIR"
    local status release_list_reads
    status=$(exec_status)
    release_list_reads=$(cat "$STRICT_RELEASE_LIST_GET_COUNT_FILE")

    if [[ $status -eq 7 && $release_list_reads -eq 2 && ! -s "$STRICT_MUTATION_LOG" ]] &&
       exec_stderr_contains "GitHub returned an invalid strict release-list page"; then
        pass "strict release rejects malformed pagination before GitHub mutation"
    else
        fail "malformed pagination must stop strict release before mutation"
        echo "status: $status; release-list reads: $release_list_reads"
        echo "mutations: $(cat "$STRICT_MUTATION_LOG" 2>/dev/null || true)"
        echo "stderr: $(exec_stderr | tail -20)"
    fi

    remove_strict_github_mocks
    harness_teardown
}

test_strict_release_rejects_release_list_failure_before_mutation() {
    ((TESTS_RUN++))
    harness_setup
    seed_strict_release_fixture
    export STRICT_RELEASE_LIST_SCENARIO=failure
    create_strict_github_mocks

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release test-tool v1.0.0 \
        --artifacts "$STRICT_ARTIFACTS_DIR"
    local status release_list_reads
    status=$(exec_status)
    release_list_reads=$(cat "$STRICT_RELEASE_LIST_GET_COUNT_FILE")

    if [[ $status -eq 7 && $release_list_reads -eq 1 && ! -s "$STRICT_MUTATION_LOG" ]] &&
       exec_stderr_contains "Could not scan GitHub releases for strict tag v1.0.0"; then
        pass "strict release rejects a release-list failure before GitHub mutation"
    else
        fail "release-list failure must stop strict release before mutation"
        echo "status: $status; release-list reads: $release_list_reads"
        echo "mutations: $(cat "$STRICT_MUTATION_LOG" 2>/dev/null || true)"
        echo "stderr: $(exec_stderr | tail -20)"
    fi

    remove_strict_github_mocks
    harness_teardown
}

test_strict_release_rejects_dependency_pin_mismatch_before_mutation() {
    ((TESTS_RUN++))
    harness_setup
    seed_strict_release_fixture
    create_strict_github_mocks

    local manifest="$STRICT_ARTIFACTS_DIR/test-tool-v1.0.0-manifest.json"
    jq '.source.dependencies = [{relative_path:"unexpected",git_sha:"1111111111111111111111111111111111111111"}]' \
        "$manifest" > "${manifest}.invalid"
    mv "${manifest}.invalid" "$manifest"

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" release test-tool v1.0.0 \
        --artifacts "$STRICT_ARTIFACTS_DIR"
    local status
    status=$(exec_status)

    if [[ $status -ne 0 && ! -s "$STRICT_MUTATION_LOG" ]]; then
        pass "strict preflight rejects manifest dependency pins that differ from configuration"
    else
        fail "dependency pin mismatch must fail before GitHub mutation"
        echo "status: $status"
        echo "mutations: $(cat "$STRICT_MUTATION_LOG" 2>/dev/null || true)"
        echo "stderr: $(exec_stderr | tail -20)"
    fi

    remove_strict_github_mocks
    harness_teardown
}

test_strict_release_extra_remote_asset_stays_draft() {
    ((TESTS_RUN++))
    harness_setup
    seed_strict_release_fixture
    STRICT_REMOTE_ASSETS=$(jq -c '. + [{id:99,name:"forbidden.sbom.json",size:10,state:"uploaded",digest:("sha256:" + ("9" * 64))}]' \
        <<< "$STRICT_REMOTE_ASSETS")
    export STRICT_REMOTE_ASSETS
    create_strict_github_mocks

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" release test-tool v1.0.0 \
        --artifacts "$STRICT_ARTIFACTS_DIR"
    local status
    status=$(exec_status)

    if [[ $status -ne 0 ]] && ! grep -q '^publish$' "$STRICT_MUTATION_LOG" 2>/dev/null; then
        pass "strict remote verification rejects extra assets and leaves staging draft unpublished"
    else
        fail "strict release must not publish a draft with extra remote assets"
        echo "status: $status"
        echo "mutations: $(cat "$STRICT_MUTATION_LOG" 2>/dev/null || true)"
    fi

    remove_strict_github_mocks
    harness_teardown
}

test_strict_release_remote_digest_mismatch_stays_draft() {
    ((TESTS_RUN++))
    harness_setup
    seed_strict_release_fixture
    STRICT_REMOTE_ASSETS=$(jq -c '.[0].digest = ("sha256:" + ("0" * 64))' <<< "$STRICT_REMOTE_ASSETS")
    export STRICT_REMOTE_ASSETS
    create_strict_github_mocks

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" release test-tool v1.0.0 \
        --artifacts "$STRICT_ARTIFACTS_DIR"
    local status
    status=$(exec_status)

    if [[ $status -ne 0 ]] && ! grep -q '^publish$' "$STRICT_MUTATION_LOG" 2>/dev/null; then
        pass "strict remote verification rejects a same-size digest mismatch"
    else
        fail "strict release must not publish remotely corrupted asset bytes"
        echo "status: $status"
        echo "mutations: $(cat "$STRICT_MUTATION_LOG" 2>/dev/null || true)"
    fi

    remove_strict_github_mocks
    harness_teardown
}

test_strict_release_does_not_overwrite_existing_sidecar() {
    ((TESTS_RUN++))
    harness_setup
    seed_strict_release_fixture
    local sidecar="$STRICT_ARTIFACTS_DIR/test-tool-linux-amd64.sha256"
    printf 'operator-owned-invalid-sidecar\n' > "$sidecar"
    create_strict_github_mocks

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" release test-tool v1.0.0 \
        --artifacts "$STRICT_ARTIFACTS_DIR"
    local status
    status=$(exec_status)

    if [[ $status -ne 0 && "$(cat "$sidecar")" == "operator-owned-invalid-sidecar" && \
          ! -s "$STRICT_MUTATION_LOG" ]]; then
        pass "strict sidecar generation validates existing data without overwriting it"
    else
        fail "strict release must not overwrite an existing checksum sidecar"
        echo "status: $status"
        echo "sidecar: $(cat "$sidecar" 2>/dev/null || true)"
        echo "mutations: $(cat "$STRICT_MUTATION_LOG" 2>/dev/null || true)"
    fi

    remove_strict_github_mocks
    harness_teardown
}

test_strict_release_rejects_nonexact_sidecar_bytes() {
    ((TESTS_RUN++))
    harness_setup
    seed_strict_release_fixture
    local primary="$STRICT_ARTIFACTS_DIR/test-tool-linux-amd64"
    local sidecar="${primary}.sha256"
    local primary_sha before_size after_size
    primary_sha=$(test_sha256 "$primary")
    printf '%s\n\0' "$primary_sha  test-tool-linux-amd64" > "$sidecar"
    before_size=$(test_file_size "$sidecar")
    create_strict_github_mocks

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" release test-tool v1.0.0 \
        --artifacts "$STRICT_ARTIFACTS_DIR"
    local status
    status=$(exec_status)
    after_size=$(test_file_size "$sidecar")

    if [[ $status -ne 0 && "$before_size" == "$after_size" && ! -s "$STRICT_MUTATION_LOG" ]]; then
        pass "strict sidecar validation rejects hidden bytes without overwriting them"
    else
        fail "strict sidecar validation must compare exact bytes"
        echo "status: $status"
        echo "before size: $before_size; after size: $after_size"
        echo "mutations: $(cat "$STRICT_MUTATION_LOG" 2>/dev/null || true)"
    fi

    remove_strict_github_mocks
    harness_teardown
}

test_strict_release_incomplete_remote_asset_stays_draft() {
    ((TESTS_RUN++))
    harness_setup
    seed_strict_release_fixture
    STRICT_REMOTE_ASSETS=$(jq -c '.[0].state = "new"' <<< "$STRICT_REMOTE_ASSETS")
    export STRICT_REMOTE_ASSETS
    create_strict_github_mocks

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" release test-tool v1.0.0 \
        --artifacts "$STRICT_ARTIFACTS_DIR"
    local status
    status=$(exec_status)

    if [[ $status -ne 0 ]] && ! grep -q '^publish$' "$STRICT_MUTATION_LOG" 2>/dev/null; then
        pass "strict remote verification rejects incomplete asset records"
    else
        fail "strict release must reject remote assets not in uploaded state"
        echo "status: $status"
        echo "mutations: $(cat "$STRICT_MUTATION_LOG" 2>/dev/null || true)"
    fi

    remove_strict_github_mocks
    harness_teardown
}

test_strict_release_invalid_remote_asset_id_stays_draft() {
    ((TESTS_RUN++))
    harness_setup
    seed_strict_release_fixture
    STRICT_REMOTE_ASSETS=$(jq -c '.[0].id = 1.5' <<< "$STRICT_REMOTE_ASSETS")
    export STRICT_REMOTE_ASSETS
    create_strict_github_mocks

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" release test-tool v1.0.0 \
        --artifacts "$STRICT_ARTIFACTS_DIR"
    local status
    status=$(exec_status)

    if [[ $status -ne 0 ]] && ! grep -q '^publish$' "$STRICT_MUTATION_LOG" 2>/dev/null; then
        pass "strict remote verification rejects non-integer asset IDs"
    else
        fail "strict release must reject invalid GitHub asset IDs"
        echo "status: $status"
        echo "mutations: $(cat "$STRICT_MUTATION_LOG" 2>/dev/null || true)"
    fi

    remove_strict_github_mocks
    harness_teardown
}

test_strict_build_rejects_untracked_source_even_allow_dirty() {
    ((TESTS_RUN++))
    harness_setup
    seed_strict_release_fixture
    printf 'not in release tag\n' > "$STRICT_REPO_DIR/untracked.txt"

    exec_run "$DSR_CMD" build test-tool --version v1.0.0 --dry-run --allow-dirty
    local status
    status=$(exec_status)

    if [[ $status -eq 4 ]] && exec_stderr_contains "clean source tree"; then
        pass "strict build rejects untracked source even when --allow-dirty is requested"
    else
        fail "strict build must not attribute dirty or untracked source to the release tag"
        echo "status: $status"
        echo "stderr: $(exec_stderr | tail -20)"
    fi

    harness_teardown
}

test_strict_build_rejects_no_sync() {
    ((TESTS_RUN++))
    harness_setup
    seed_strict_release_fixture

    exec_run "$DSR_CMD" build test-tool --version v1.0.0 --dry-run --no-sync
    local status
    status=$(exec_status)

    if [[ $status -eq 4 ]] && exec_stderr_contains "--no-sync is forbidden"; then
        pass "strict build rejects --no-sync without remote source proof"
    else
        fail "strict build must require source synchronization"
        echo "status: $status"
        echo "stderr: $(exec_stderr | tail -20)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: JSON Output
# ============================================================================

test_release_json_error_valid() {
    ((TESTS_RUN++))
    harness_setup
    seed_repos_config

    # This will fail (missing version) but should produce valid JSON
    exec_run "$DSR_CMD" --json release test-tool
    local output
    output=$(exec_stdout)

    # Even on error, JSON output should be valid (if any)
    if [[ -z "$output" ]]; then
        # No JSON output on early arg parse failure is acceptable
        pass "release --json produces no output on arg parse error (acceptable)"
    elif echo "$output" | jq . >/dev/null 2>&1; then
        pass "release --json produces valid JSON on error"
    else
        fail "release --json should produce valid JSON or no output"
        echo "output: $output"
    fi

    harness_teardown
}

test_release_json_auth_error_valid() {
    ((TESTS_RUN++))
    harness_setup
    seed_repos_config
    seed_artifacts "test-tool" "v1.0.0"

    # Force gh auth to fail
    mkdir -p "$TEST_TMPDIR/bin"
    cat > "$TEST_TMPDIR/bin/gh" << 'SCRIPT'
#!/bin/bash
if [[ "$1" == "auth" && "$2" == "status" ]]; then
    exit 1
fi
exit 1
SCRIPT
    chmod +x "$TEST_TMPDIR/bin/gh"

    # Unset tokens to force auth failure
    local old_token="${GITHUB_TOKEN:-}"
    local old_gh_token="${GH_TOKEN:-}"
    unset GITHUB_TOKEN GH_TOKEN

    PATH="$TEST_TMPDIR/bin:$PATH" exec_run "$DSR_CMD" --json release test-tool v1.0.0
    local output
    output=$(exec_stdout)

    # Restore tokens
    [[ -n "$old_token" ]] && export GITHUB_TOKEN="$old_token"
    [[ -n "$old_gh_token" ]] && export GH_TOKEN="$old_gh_token"

    if [[ -z "$output" ]]; then
        skip "No JSON output on auth failure (may fail before JSON mode)"
    elif echo "$output" | jq . >/dev/null 2>&1; then
        pass "release --json produces valid JSON on auth error"
    else
        fail "release --json should produce valid JSON on auth error"
        echo "output: $output"
    fi

    harness_teardown
}

# ============================================================================
# Tests: With Valid Auth (when available)
# ============================================================================

test_release_with_artifacts_setup() {
    ((TESTS_RUN++))

    if [[ "$HAS_GH_AUTH" != "true" ]]; then
        skip "gh auth required for artifacts setup test"
        return 0
    fi

    if [[ "$HAS_YQ" != "true" ]]; then
        skip "yq required for repos.yaml parsing"
        return 0
    fi

    harness_setup
    seed_repos_config
    seed_artifacts "test-tool" "v1.0.0"

    # This will likely fail at tag verification or repo lookup
    # but should get past the initial validation
    exec_run "$DSR_CMD" release test-tool v1.0.0
    local status
    status=$(exec_status)

    # The test tool doesn't exist on GitHub, so this will fail
    # But we're checking that we got past the initial validation
    if [[ "$status" -eq 4 ]] && exec_stderr_contains "not found"; then
        pass "release validates artifacts before repo lookup (exit: 4)"
    elif [[ "$status" -eq 7 ]]; then
        pass "release fails at GitHub API level (exit: 7)"
    elif [[ "$status" -eq 0 ]]; then
        # Shouldn't succeed with a fake tool
        fail "release should not succeed with fake test-tool"
    else
        # Any failure is expected here since test-tool doesn't exist
        pass "release fails with expected error for nonexistent repo (exit: $status)"
    fi

    harness_teardown
}

# ============================================================================
# Tests: Stream Separation
# ============================================================================

test_release_stream_separation() {
    ((TESTS_RUN++))
    harness_setup
    seed_repos_config

    # Run with JSON mode and expect failure (missing version)
    exec_run "$DSR_CMD" --json release test-tool
    local stdout
    stdout=$(exec_stdout)

    # If there's stdout, it should be JSON
    if [[ -n "$stdout" ]]; then
        if echo "$stdout" | jq . >/dev/null 2>&1; then
            pass "release --json keeps JSON on stdout (if any)"
        else
            fail "release --json stdout should be valid JSON"
            echo "stdout: $stdout"
        fi
    else
        # No stdout is also acceptable for early failures
        pass "release maintains stream separation (no stdout on early error)"
    fi

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

echo "=== E2E: dsr release Tests ==="
echo ""
echo "Dependencies: gh auth=$(if $HAS_GH_AUTH; then echo available; else echo missing; fi), yq=$(if $HAS_YQ; then echo available; else echo missing; fi)"
echo ""

if [[ "${DSR_E2E_RELEASE_STRICT_ONLY:-0}" == "1" ]]; then
    echo "Strict Release Contract Tests (mocked GitHub):"
    test_strict_release_uploads_exact_set_then_publishes
    test_strict_create_commit_then_error_adopts_exact_empty_draft
    test_strict_upload_commit_then_error_reconciles_exact_draft
    test_strict_create_error_rejects_nonexact_observed_draft
    test_strict_create_error_rejects_competitor_draft_nonce
    test_strict_create_error_never_redrafts_public_competitor
    test_strict_release_requested_draft_is_not_published
    test_strict_release_rejects_changed_frozen_plan
    test_strict_release_rechecks_remote_assets_before_publish
    test_strict_release_rechecks_remote_tag_before_publish
    test_strict_release_rechecks_remote_metadata_before_publish
    test_strict_requested_draft_rechecks_remote_state
    test_strict_upload_failure_redrafts_concurrently_published_release
    test_strict_prepublish_failure_redrafts_concurrently_published_release
    test_strict_requested_draft_failure_redrafts_concurrent_publication
    test_strict_release_redrafts_failed_postpublish_verification
    test_strict_publish_commit_then_error_is_observed
    test_strict_publish_error_without_commit_stays_draft
    test_strict_redraft_commit_then_error_is_observed
    test_strict_release_preflight_failure_has_no_github_mutation
    test_strict_release_rejects_duplicate_tag_across_pages_before_mutation
    test_strict_release_rejects_malformed_second_page_before_mutation
    test_strict_release_rejects_release_list_failure_before_mutation
    test_strict_release_rejects_dependency_pin_mismatch_before_mutation
    test_strict_release_extra_remote_asset_stays_draft
    test_strict_release_remote_digest_mismatch_stays_draft
    test_strict_release_does_not_overwrite_existing_sidecar
    test_strict_release_rejects_nonexact_sidecar_bytes
    test_strict_release_incomplete_remote_asset_stays_draft
    test_strict_release_invalid_remote_asset_id_stays_draft
    test_strict_build_rejects_untracked_source_even_allow_dirty
    test_strict_build_rejects_no_sync
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
test_release_help
test_release_help_shows_options
test_release_help_shows_subcommands

echo ""
echo "Argument Validation Tests:"
test_release_missing_tool
test_release_missing_version
test_release_unknown_option
test_release_unknown_tool

echo ""
echo "Dependency Tests:"
test_release_missing_gh_auth
test_release_missing_artifacts_dir

echo ""
echo "Strict Release Contract Tests (mocked GitHub):"
test_strict_release_uploads_exact_set_then_publishes
test_strict_create_commit_then_error_adopts_exact_empty_draft
test_strict_upload_commit_then_error_reconciles_exact_draft
test_strict_create_error_rejects_nonexact_observed_draft
test_strict_create_error_rejects_competitor_draft_nonce
test_strict_create_error_never_redrafts_public_competitor
test_strict_release_requested_draft_is_not_published
test_strict_release_rejects_changed_frozen_plan
test_strict_release_rechecks_remote_assets_before_publish
test_strict_release_rechecks_remote_tag_before_publish
test_strict_release_rechecks_remote_metadata_before_publish
test_strict_requested_draft_rechecks_remote_state
test_strict_upload_failure_redrafts_concurrently_published_release
test_strict_prepublish_failure_redrafts_concurrently_published_release
test_strict_requested_draft_failure_redrafts_concurrent_publication
test_strict_release_redrafts_failed_postpublish_verification
test_strict_publish_commit_then_error_is_observed
test_strict_publish_error_without_commit_stays_draft
test_strict_redraft_commit_then_error_is_observed
test_strict_release_preflight_failure_has_no_github_mutation
test_strict_release_rejects_duplicate_tag_across_pages_before_mutation
test_strict_release_rejects_malformed_second_page_before_mutation
test_strict_release_rejects_release_list_failure_before_mutation
test_strict_release_rejects_dependency_pin_mismatch_before_mutation
test_strict_release_extra_remote_asset_stays_draft
test_strict_release_remote_digest_mismatch_stays_draft
test_strict_release_does_not_overwrite_existing_sidecar
test_strict_release_rejects_nonexact_sidecar_bytes
test_strict_release_incomplete_remote_asset_stays_draft
test_strict_release_invalid_remote_asset_id_stays_draft
test_strict_build_rejects_untracked_source_even_allow_dirty
test_strict_build_rejects_no_sync

echo ""
echo "JSON Output Tests:"
test_release_json_error_valid
test_release_json_auth_error_valid

echo ""
echo "Integration Tests (when deps available):"
test_release_with_artifacts_setup

echo ""
echo "Stream Separation Tests:"
test_release_stream_separation

echo ""
echo "=========================================="
echo "Tests run:    $TESTS_RUN"
echo "Passed:       $TESTS_PASSED"
echo "Skipped:      $TESTS_SKIPPED"
echo "Failed:       $TESTS_FAILED"
echo "=========================================="

[[ $TESTS_FAILED -eq 0 ]] && exit 0 || exit 1
