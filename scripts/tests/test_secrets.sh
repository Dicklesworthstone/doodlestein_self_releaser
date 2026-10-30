#!/usr/bin/env bash
# test_secrets.sh - Unit tests for secrets.sh module
#
# Usage: ./test_secrets.sh
#
# Tests credential resolution and redaction without exposing real secrets

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC_DIR="$PROJECT_ROOT/src"

# Source the module under test
source "$SRC_DIR/secrets.sh"

# Colors
if [[ -z "${NO_COLOR:-}" ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    NC=$'\033[0m'
else
    RED='' GREEN='' YELLOW='' NC=''
fi

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

log_pass() { echo -e "${GREEN}✓${NC} $1"; ((PASS_COUNT++)); }
log_fail() { echo -e "${RED}✗${NC} $1"; ((FAIL_COUNT++)); }
log_skip() { echo -e "${YELLOW}○${NC} $1"; ((SKIP_COUNT++)); }
log_test() { echo -e "\n== $1 =="; }

# ============================================================================
# Redaction Tests
# ============================================================================

test_redact_github_tokens() {
    log_test "secrets_redact - GitHub tokens"

    local input output

    # Test ghp_ token
    input="Token: ghp_abcdefghijklmnopqrstuvwxyz123456789012"
    output=$(secrets_redact "$input")
    if [[ "$output" == "Token: ***" ]]; then
        log_pass "ghp_ token redacted"
    else
        log_fail "ghp_ token not redacted: $output"
    fi

    # Test github_pat_ token
    input="PAT: github_pat_11ABCDEFG0123456789012_abcdefghijklmnopqrstuvwxyz"
    output=$(secrets_redact "$input")
    if [[ ! "$output" == *"github_pat_"* ]]; then
        log_pass "github_pat_ token redacted"
    else
        log_fail "github_pat_ token not redacted: $output"
    fi

    # Test gho_ token
    input="OAuth: gho_abcdefghijklmnopqrstuvwxyz123456789012"
    output=$(secrets_redact "$input")
    if [[ "$output" == "OAuth: ***" ]]; then
        log_pass "gho_ token redacted"
    else
        log_fail "gho_ token not redacted: $output"
    fi
}

test_redact_slack_webhook() {
    log_test "secrets_redact - Slack webhook"

    local input output

    # Build the test URL dynamically to avoid GitHub secret scanner false positive
    local base="https://hooks.slack.com"
    local path="/services/TXXXXXXXX/BXXXXXXXX/xxxxxxxxxxxxxxxxxxxxxxxx"
    input="Webhook: ${base}${path}"
    output=$(secrets_redact "$input")
    if [[ "$output" == "Webhook: ***" ]]; then
        log_pass "Slack webhook redacted"
    else
        log_fail "Slack webhook not redacted: $output"
    fi
}

test_redact_discord_webhook() {
    log_test "secrets_redact - Discord webhook"

    local input output

    input="Discord: https://discord.com/api/webhooks/123456789012345678/abcdefghijklmnopqrstuvwxyz-_"
    output=$(secrets_redact "$input")
    if [[ "$output" == "Discord: ***" ]]; then
        log_pass "Discord webhook redacted"
    else
        log_fail "Discord webhook not redacted: $output"
    fi
}

test_redact_preserves_non_secrets() {
    log_test "secrets_redact - preserves non-secrets"

    local input output

    input="Normal text with no secrets"
    output=$(secrets_redact "$input")
    if [[ "$output" == "$input" ]]; then
        log_pass "Non-secret text preserved"
    else
        log_fail "Non-secret text modified: $output"
    fi

    # Test that short strings that look like tokens are preserved
    input="ghp_short"
    output=$(secrets_redact "$input")
    if [[ "$output" == "$input" ]]; then
        log_pass "Short token-like string preserved"
    else
        log_fail "Short string incorrectly redacted: $output"
    fi
}

# ============================================================================
# Token Masking Tests
# ============================================================================

test_secrets_mask() {
    log_test "secrets_mask"

    local output

    # Test normal token
    output=$(secrets_mask "ghp_abcdefghijklmnopqrstuvwxyz123456789012")
    if [[ "$output" == "ghp_abcd***" ]]; then
        log_pass "Normal token masked correctly"
    else
        log_fail "Token mask incorrect: $output (expected ghp_abcd***)"
    fi

    # Test short string
    output=$(secrets_mask "short")
    if [[ "$output" == "***" ]]; then
        log_pass "Short string fully masked"
    else
        log_fail "Short string mask incorrect: $output"
    fi
}

# ============================================================================
# Token Source Detection Tests
# ============================================================================

test_gh_source_detection() {
    log_test "secrets_get_gh_source"

    local source

    # Save current env
    local save_dsr="${DSR_GH_TOKEN:-}"
    local save_github="${GITHUB_TOKEN:-}"
    local save_gh="${GH_TOKEN:-}"

    # Test DSR_GH_TOKEN priority
    export DSR_GH_TOKEN="test_token"
    export GITHUB_TOKEN="other_token"
    source=$(secrets_get_gh_source)
    if [[ "$source" == "DSR_GH_TOKEN" ]]; then
        log_pass "DSR_GH_TOKEN has highest priority"
    else
        log_fail "Priority wrong: expected DSR_GH_TOKEN, got $source"
    fi

    # Test GITHUB_TOKEN
    unset DSR_GH_TOKEN
    source=$(secrets_get_gh_source)
    if [[ "$source" == "GITHUB_TOKEN" ]]; then
        log_pass "GITHUB_TOKEN second priority"
    else
        log_fail "Priority wrong: expected GITHUB_TOKEN, got $source"
    fi

    # Test GH_TOKEN
    unset GITHUB_TOKEN
    export GH_TOKEN="test_token"
    source=$(secrets_get_gh_source)
    if [[ "$source" == "GH_TOKEN" ]]; then
        log_pass "GH_TOKEN third priority"
    else
        log_fail "Priority wrong: expected GH_TOKEN, got $source"
    fi

    # Restore env
    if [[ -n "$save_dsr" ]]; then
        export DSR_GH_TOKEN="$save_dsr"
    else
        unset DSR_GH_TOKEN
    fi
    if [[ -n "$save_github" ]]; then
        export GITHUB_TOKEN="$save_github"
    else
        unset GITHUB_TOKEN
    fi
    if [[ -n "$save_gh" ]]; then
        export GH_TOKEN="$save_gh"
    else
        unset GH_TOKEN
    fi
}

# Exercise the exported command helper and diagnostics together. A fake gh
# observes child environment and arguments; all credentials are dummy values.
test_gh_credential_fixture() (
    local scenario="$1" expected=fixture-dsr expected_source=DSR_GH_TOKEN
    local evidence before after result status=0
    evidence=$(mktemp -d "${TMPDIR:-/tmp}/dsr-secret-routing.XXXXXXXX") || return 1
    export DSR_GH_TOKEN=fixture-dsr GITHUB_TOKEN=fixture-github GH_TOKEN=fixture-gh
    export GH_HOST=enterprise.fixture.invalid GH_REPO=enterprise.fixture.invalid/other/repo
    case "$scenario" in
        github) unset DSR_GH_TOKEN; expected=fixture-github; expected_source=GITHUB_TOKEN ;;
        gh) unset DSR_GH_TOKEN GITHUB_TOKEN; expected=fixture-gh; expected_source=GH_TOKEN ;;
        saved) unset DSR_GH_TOKEN GITHUB_TOKEN GH_TOKEN; expected=fixture-saved; expected_source=gh_auth ;;
        missing) unset DSR_GH_TOKEN GITHUB_TOKEN GH_TOKEN; expected_source=none ;;
        invalid) export DSR_GH_TOKEN=fixture-invalid; expected=fixture-invalid ;;
        dsr|scope-api) ;;
        *) return 4 ;;
    esac
    before="${DSR_GH_TOKEN-unset}|${GITHUB_TOKEN-unset}|${GH_TOKEN-unset}|$GH_HOST|$GH_REPO"
    gh() {
        local host="${GH_HOST:-github.com}" token="${GH_TOKEN:-${GITHUB_TOKEN:-fixture-saved}}" argument previous=''
        for argument in "$@"; do
            [[ "$previous" != --hostname ]] || host="$argument"
            previous="$argument"
        done
        if [[ "$1 ${2:-}" == 'auth token' ]]; then
            printf 'TOKEN %s\n' "$host" >> "$evidence/calls"
            [[ "$scenario" != missing ]] || return 1
            [[ "$host" == github.com ]] || { printf 'fixture-enterprise\n'; return 0; }
            printf 'fixture-saved\n'; return 0
        fi
        printf 'COMMAND %s %s %s\n' "$host" "$token" "$*" >> "$evidence/calls"
        [[ "$host" == github.com && "$token" == "$expected" ]] || return 91
        [[ "$scenario" != invalid ]] || return 23
        case "$1 ${2:-}" in
            'auth status')
                if [[ "$scenario" != scope-api ]]; then printf "Token scopes: 'repo', 'workflow'\n"; fi ;;
            'api user') printf 'fixture-release-account\n' ;;
            'api failure') return 19 ;;
            *) return 4 ;;
        esac
    }
    [[ "$(secrets_get_gh_source)" == "$expected_source" ]] || return 1
    if [[ "$scenario" == missing ]]; then
        secrets_run_gh api user --hostname github.com > "$evidence/stdout" 2> "$evidence/stderr" || status=$?
        [[ $status -eq 3 && ! -s "$evidence/stdout" ]] || return 1
        ! grep -q '^COMMAND ' "$evidence/calls" || return 1
        return 0
    fi
    if [[ "$scenario" == invalid ]]; then
        secrets_run_gh api user --hostname github.com > "$evidence/stdout" 2> "$evidence/stderr" || status=$?
        [[ $status -eq 23 && ! -s "$evidence/stdout" ]] || return 1
        ! secrets_validate_gh_scopes release || return 1
        ! grep -q '^TOKEN ' "$evidence/calls" || return 1
    else
        [[ "$(secrets_get_gh_token)" == "$expected" ]] || return 1
        secrets_validate_gh_scopes release || return 1
        result=$(secrets_check_gh_auth) || return 1
        jq -e '.status == "ok" and .user == "fixture-release-account"' <<< "$result" >/dev/null || return 1
        result=$(secrets_doctor_summary) || return 1
        jq -e --arg source "$expected_source" '.github.available == true and
            .github.user == "fixture-release-account" and .github.source == $source' <<< "$result" >/dev/null || return 1
        secrets_run_gh api failure --hostname github.com > "$evidence/stdout" 2> "$evidence/stderr" || status=$?
        [[ $status -eq 19 ]] || return 1
    fi
    after="${DSR_GH_TOKEN-unset}|${GITHUB_TOKEN-unset}|${GH_TOKEN-unset}|$GH_HOST|$GH_REPO"
    [[ "$before" == "$after" ]] || return 1
    ! grep -q '^TOKEN enterprise\.' "$evidence/calls" || return 1
    ! grep '^COMMAND ' "$evidence/calls" | grep -Fv "COMMAND github.com $expected "
)

test_gh_credential_routing() {
    local scenario
    log_test 'GitHub command and diagnostic credential routing'
    for scenario in dsr github gh saved missing invalid scope-api; do
        if test_gh_credential_fixture "$scenario"; then
            log_pass "GitHub identity preserved: $scenario"
        else
            log_fail "GitHub identity mismatch: $scenario"
        fi
    done
}

# ============================================================================
# Webhook URL Validation Tests
# ============================================================================

test_slack_webhook_validation() {
    log_test "Slack webhook URL validation"

    local save_webhook="${DSR_SLACK_WEBHOOK:-}"

    # Valid webhook - build dynamically to avoid GitHub secret scanner
    local base="https://hooks.slack.com"
    local path="/services/TXXXXXXXX/BXXXXXXXX/xxxxxxxxxxxxxxxxxxxxxxxx"
    export DSR_SLACK_WEBHOOK="${base}${path}"
    if secrets_has_slack_webhook; then
        log_pass "Valid Slack webhook accepted"
    else
        log_fail "Valid Slack webhook rejected"
    fi

    # Invalid webhook (wrong domain)
    export DSR_SLACK_WEBHOOK="https://example.com/webhook"
    if ! secrets_get_slack_webhook 2>/dev/null; then
        log_pass "Invalid Slack webhook rejected"
    else
        log_fail "Invalid Slack webhook accepted"
    fi

    # Restore
    if [[ -n "$save_webhook" ]]; then
        export DSR_SLACK_WEBHOOK="$save_webhook"
    else
        unset DSR_SLACK_WEBHOOK
    fi
}

# ============================================================================
# Doctor Summary Tests
# ============================================================================

test_doctor_summary_structure() {
    log_test "secrets_doctor_summary JSON structure"

    local summary
    summary=$(secrets_doctor_summary 2>/dev/null)

    if command -v jq &>/dev/null; then
        if echo "$summary" | jq -e '.github' &>/dev/null; then
            log_pass "Summary has github field"
        else
            log_fail "Summary missing github field"
        fi

        if echo "$summary" | jq -e '.slack' &>/dev/null; then
            log_pass "Summary has slack field"
        else
            log_fail "Summary missing slack field"
        fi

        if echo "$summary" | jq -e '.discord' &>/dev/null; then
            log_pass "Summary has discord field"
        else
            log_fail "Summary missing discord field"
        fi
    else
        log_skip "jq not available for JSON validation"
    fi
}

# ============================================================================
# JSON Redaction Tests
# ============================================================================

test_json_redaction() {
    log_test "secrets_redact_json"

    if ! command -v jq &>/dev/null; then
        log_skip "jq required for JSON redaction tests"
        return
    fi

    local input output

    # Test with secret field
    input='{"name": "test", "token": "ghp_abcdefghijklmnopqrstuvwxyz123456789012"}'
    output=$(secrets_redact_json "$input")

    if echo "$output" | jq -e '.token == "***"' &>/dev/null; then
        log_pass "JSON token field redacted"
    else
        log_fail "JSON token field not redacted: $output"
    fi

    # Test that non-secret fields preserved
    if echo "$output" | jq -e '.name == "test"' &>/dev/null; then
        log_pass "JSON non-secret field preserved"
    else
        log_fail "JSON non-secret field modified"
    fi
}

# ============================================================================
# Main
# ============================================================================

main() {
    if [[ "${1:-}" == --credential-routing-only ]]; then
        test_gh_credential_routing
        printf 'Credential diagnostics: %s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
        [[ "$FAIL_COUNT" -eq 0 ]]
        exit $?
    fi
    echo "═══════════════════════════════════════════════════════════════"
    echo "  secrets.sh Unit Tests"
    echo "═══════════════════════════════════════════════════════════════"

    # Redaction tests
    test_redact_github_tokens
    test_redact_slack_webhook
    test_redact_discord_webhook
    test_redact_preserves_non_secrets

    # Masking tests
    test_secrets_mask

    # Source detection tests
    test_gh_source_detection
    test_gh_credential_routing

    # Webhook validation tests
    test_slack_webhook_validation

    # Doctor summary tests
    test_doctor_summary_structure

    # JSON redaction tests
    test_json_redaction

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Summary"
    echo "═══════════════════════════════════════════════════════════════"
    echo -e "  ${GREEN}Passed:${NC}  $PASS_COUNT"
    echo -e "  ${RED}Failed:${NC}  $FAIL_COUNT"
    echo -e "  ${YELLOW}Skipped:${NC} $SKIP_COUNT"

    if [[ $FAIL_COUNT -gt 0 ]]; then
        exit 1
    fi
    exit 0
}

main "$@"
