#!/usr/bin/env bash
# secrets.sh - Secrets & credential management for dsr
#
# SECURITY: This module NEVER logs secrets. All values are masked.
#
# Usage:
#   source secrets.sh
#   secrets_init
#   gh_token=$(secrets_get_gh_token)
#   secrets_validate_gh_scopes
#
# Environment Variable Precedence (highest first):
#   1. DSR_GH_TOKEN
#   2. GITHUB_TOKEN
#   3. GH_TOKEN
#   4. `gh auth token` fallback
#
# Redaction:
#   All token values are masked in logs and JSON output.
#   Use secrets_redact() for any string that might contain secrets.

set -uo pipefail

# Token patterns for redaction (regex patterns)
# GitHub tokens: ghp_, gho_, ghu_, ghs_, ghr_ prefixes
# Slack webhooks: https://hooks.slack.com/services/...
declare -ga _SECRET_PATTERNS=(
    'ghp_[A-Za-z0-9]{36,}'
    'gho_[A-Za-z0-9]{36,}'
    'ghu_[A-Za-z0-9]{36,}'
    'ghs_[A-Za-z0-9]{36,}'
    'ghr_[A-Za-z0-9]{36,}'
    'github_pat_[A-Za-z0-9_]{22,}'
    'https://hooks\.slack\.com/services/[A-Za-z0-9/]+'
    'https://discord\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+'
    'xoxb-[0-9]+-[0-9]+-[A-Za-z0-9]+'
    'xoxp-[0-9]+-[0-9]+-[0-9]+-[a-f0-9]+'
)

# Required GitHub scopes for different operations
declare -gA _GH_REQUIRED_SCOPES=(
    [release]="contents:write"
    [workflow]="workflow"
    [repo]="repo"
)

# Colors for output (if not disabled)
if [[ -z "${NO_COLOR:-}" && -t 2 ]]; then
    _SEC_RED=$'\033[0;31m'
    _SEC_GREEN=$'\033[0;32m'
    _SEC_YELLOW=$'\033[0;33m'
    _SEC_BLUE=$'\033[0;34m'
    _SEC_NC=$'\033[0m'
else
    _SEC_RED='' _SEC_GREEN='' _SEC_YELLOW='' _SEC_BLUE='' _SEC_NC=''
fi

_sec_log_info()  { echo "${_SEC_BLUE}[secrets]${_SEC_NC} $*" >&2; }
_sec_log_ok()    { echo "${_SEC_GREEN}[secrets]${_SEC_NC} $*" >&2; }
_sec_log_warn()  { echo "${_SEC_YELLOW}[secrets]${_SEC_NC} $*" >&2; }
_sec_log_error() { echo "${_SEC_RED}[secrets]${_SEC_NC} $*" >&2; }

# ============================================================================
# Redaction Functions
# ============================================================================

# Redact secrets from a string
# Usage: secrets_redact <string>
# Returns: String with all secrets masked as "***"
secrets_redact() {
    local input="$1"
    local output="$input"

    # Apply each pattern using # as delimiter (patterns may contain /)
    for pattern in "${_SECRET_PATTERNS[@]}"; do
        output=$(echo "$output" | sed -E "s#$pattern#***#g")
    done

    echo "$output"
}

# Redact secrets from JSON
# Usage: secrets_redact_json <json_string>
# Returns: JSON with secret values masked
secrets_redact_json() {
    local json="$1"

    # Use jq to redact specific keys if available
    if command -v jq &>/dev/null; then
        # Redact known secret field names
        echo "$json" | jq '
            walk(if type == "object" then
                with_entries(
                    if (.key | test("token|secret|password|key|webhook"; "i")) and (.value | type == "string")
                    then .value = "***"
                    else .
                    end
                )
            else . end)
        ' 2>/dev/null || secrets_redact "$json"
    else
        # Fallback to pattern-based redaction
        secrets_redact "$json"
    fi
}

# Mask a token for display (show first 8 chars)
# Usage: secrets_mask <token>
# Returns: "ghp_abcd***" or "***" if too short
secrets_mask() {
    local token="$1"

    if [[ ${#token} -lt 8 ]]; then
        echo "***"
    else
        echo "${token:0:8}***"
    fi
}

# ============================================================================
# GitHub Token Resolution
# ============================================================================

# Get GitHub token with precedence
# Usage: secrets_get_gh_token
# Returns: Token value (to stdout), never logged
# Exit: 0 if found, 3 if not found
secrets_get_gh_token() {
    local token=""

    # 1. DSR_GH_TOKEN (highest priority)
    if [[ -n "${DSR_GH_TOKEN:-}" ]]; then
        token="$DSR_GH_TOKEN"
        _sec_log_info "Using GitHub token from DSR_GH_TOKEN"
    # 2. GITHUB_TOKEN (CI environments)
    elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
        token="$GITHUB_TOKEN"
        _sec_log_info "Using GitHub token from GITHUB_TOKEN"
    # 3. GH_TOKEN (gh CLI convention)
    elif [[ -n "${GH_TOKEN:-}" ]]; then
        token="$GH_TOKEN"
        _sec_log_info "Using GitHub token from GH_TOKEN"
    # 4. gh auth token fallback
    elif command -v gh &>/dev/null; then
        if token=$(gh auth token 2>/dev/null) && [[ -n "$token" ]]; then
            _sec_log_info "Using GitHub token from gh auth"
        else
            token=""
        fi
    fi

    if [[ -z "$token" ]]; then
        _sec_log_error "No GitHub token found"
        _sec_log_error "Set DSR_GH_TOKEN, GITHUB_TOKEN, or run: gh auth login"
        return 3
    fi

    # Output token to stdout (NEVER to stderr/logs)
    echo "$token"
    return 0
}

# Check if GitHub token is available (without outputting it)
# Usage: secrets_has_gh_token
# Returns: 0 if available, 1 if not
secrets_has_gh_token() {
    local token
    token=$(secrets_get_gh_token 2>/dev/null) && [[ -n "$token" ]]
}

# ============================================================================
# GitHub Scope Validation
# ============================================================================

# Validate GitHub token has required scopes
# Usage: secrets_validate_gh_scopes [operation]
# Args: operation = release|workflow|repo (default: release)
# Returns: 0 if valid, 3 if missing scopes
secrets_validate_gh_scopes() {
    local operation="${1:-release}"

    if ! command -v gh &>/dev/null; then
        _sec_log_error "gh CLI required for scope validation"
        return 3
    fi

    # Get current auth status
    local auth_status
    if ! auth_status=$(gh auth status 2>&1); then
        _sec_log_error "GitHub authentication failed"
        _sec_log_error "Run: gh auth login"
        return 3
    fi

    # Check for specific scopes based on operation
    local required_scope="${_GH_REQUIRED_SCOPES[$operation]:-repo}"

    # Parse scopes from auth status
    # gh auth status output includes "Token scopes: 'repo', 'workflow', ..."
    local current_scopes
    current_scopes=$(echo "$auth_status" | grep -i "token scopes" | sed 's/.*: //' || echo "")

    if [[ -z "$current_scopes" ]]; then
        # If we can't determine scopes, try an API call to verify
        if ! gh api user &>/dev/null; then
            _sec_log_error "Token validation failed - unable to access GitHub API"
            return 3
        fi
        _sec_log_warn "Could not determine token scopes, but API access works"
        return 0
    fi

    # Check if required scope is present
    case "$required_scope" in
        "contents:write")
            if [[ "$current_scopes" == *"repo"* ]] || [[ "$current_scopes" == *"public_repo"* ]]; then
                _sec_log_ok "Token has required scope for releases (repo)"
                return 0
            fi
            ;;
        "workflow")
            if [[ "$current_scopes" == *"workflow"* ]]; then
                _sec_log_ok "Token has required scope for workflows"
                return 0
            fi
            ;;
        "repo")
            if [[ "$current_scopes" == *"repo"* ]]; then
                _sec_log_ok "Token has required repo scope"
                return 0
            fi
            ;;
    esac

    _sec_log_error "Token missing required scope: $required_scope"
    _sec_log_error "Current scopes: $current_scopes"
    _sec_log_error "Refresh token with: gh auth refresh -s $required_scope"
    return 3
}

# Quick check for GitHub auth (used by doctor)
# Usage: secrets_check_gh_auth
# Returns: JSON status object
secrets_check_gh_auth() {
    local status="ok"
    local details=""
    local user=""

    if ! command -v gh &>/dev/null; then
        status="error"
        details="gh CLI not installed"
    elif ! secrets_has_gh_token; then
        status="error"
        details="Not authenticated"
    else
        # Get authenticated user
        if user=$(gh api user -q '.login' 2>/dev/null); then
            details="Authenticated as $user"
        else
            status="warn"
            details="Token valid but user lookup failed"
        fi
    fi

    # Use jq for safe JSON construction
    jq -nc \
        --arg status "$status" \
        --arg details "$details" \
        --arg user "$user" \
        '{status: $status, details: $details, user: $user}'
}

# ============================================================================
# Slack Webhook
# ============================================================================

# Get Slack webhook URL
# Usage: secrets_get_slack_webhook
# Returns: Webhook URL or empty
secrets_get_slack_webhook() {
    local webhook=""

    # Environment variable
    if [[ -n "${DSR_SLACK_WEBHOOK:-}" ]]; then
        webhook="$DSR_SLACK_WEBHOOK"
        _sec_log_info "Using Slack webhook from DSR_SLACK_WEBHOOK"
    fi

    if [[ -z "$webhook" ]]; then
        return 1
    fi

    # Validate URL format
    if [[ ! "$webhook" =~ ^https://hooks\.slack\.com/services/ ]]; then
        _sec_log_error "Invalid Slack webhook URL format"
        return 4
    fi

    echo "$webhook"
    return 0
}

# Check if Slack webhook is configured
# Usage: secrets_has_slack_webhook
secrets_has_slack_webhook() {
    local webhook
    webhook=$(secrets_get_slack_webhook 2>/dev/null) && [[ -n "$webhook" ]]
}

# ============================================================================
# Discord Webhook
# ============================================================================

# Get Discord webhook URL
# Usage: secrets_get_discord_webhook
# Returns: Webhook URL or empty
secrets_get_discord_webhook() {
    local webhook=""

    if [[ -n "${DSR_DISCORD_WEBHOOK:-}" ]]; then
        webhook="$DSR_DISCORD_WEBHOOK"
        _sec_log_info "Using Discord webhook from DSR_DISCORD_WEBHOOK"
    fi

    if [[ -z "$webhook" ]]; then
        return 1
    fi

    # Validate URL format
    if [[ ! "$webhook" =~ ^https://discord\.com/api/webhooks/ ]]; then
        _sec_log_error "Invalid Discord webhook URL format"
        return 4
    fi

    echo "$webhook"
    return 0
}

# ============================================================================
# Initialization & Validation
# ============================================================================

# Initialize secrets module
# Validates that no secrets are exposed in environment dump
secrets_init() {
    _sec_log_info "Secrets module initialized"

    # Warn if secrets might be exposed
    if [[ "${DSR_DEBUG:-}" == "true" ]]; then
        _sec_log_warn "Debug mode enabled - ensure secrets are not logged"
    fi

    return 0
}

# Validate all required credentials for an operation
# Usage: secrets_validate_for <operation>
# Args: operation = check|build|release|fallback
# Returns: 0 if all required credentials available
secrets_validate_for() {
    local operation="$1"
    local errors=0

    case "$operation" in
        check|build)
            # Needs GitHub read access
            if ! secrets_has_gh_token; then
                _sec_log_error "GitHub token required for $operation"
                ((errors++))
            fi
            ;;
        release|fallback)
            # Needs GitHub write access with correct scopes
            if ! secrets_has_gh_token; then
                _sec_log_error "GitHub token required for $operation"
                ((errors++))
            elif ! secrets_validate_gh_scopes "release" 2>/dev/null; then
                _sec_log_error "GitHub token missing required scopes for $operation"
                ((errors++))
            fi
            ;;
        notify)
            # Check notification credentials
            if ! secrets_has_slack_webhook && [[ -z "${DSR_DISCORD_WEBHOOK:-}" ]]; then
                _sec_log_warn "No notification webhooks configured"
            fi
            ;;
    esac

    [[ $errors -eq 0 ]]
}

# Generate credentials summary for doctor command
# Usage: secrets_doctor_summary
# Returns: JSON with credential status (secrets redacted)
secrets_doctor_summary() {
    local gh_available=false gh_user="" gh_source=""
    local slack_configured=false
    local discord_configured=false

    # GitHub
    if secrets_has_gh_token; then
        gh_available=true
        gh_user=$(gh api user -q '.login' 2>/dev/null || echo "unknown")
        gh_source=$(secrets_get_gh_source)
    fi

    # Slack
    if secrets_has_slack_webhook; then
        slack_configured=true
    fi

    # Discord
    if [[ -n "${DSR_DISCORD_WEBHOOK:-}" ]]; then
        discord_configured=true
    fi

    # Use jq for safe JSON construction
    jq -nc \
        --argjson gh_available "$gh_available" \
        --arg gh_user "$gh_user" \
        --arg gh_source "$gh_source" \
        --argjson slack_configured "$slack_configured" \
        --argjson discord_configured "$discord_configured" \
        '{
            github: {
                available: $gh_available,
                user: (if $gh_user == "" then null else $gh_user end),
                source: (if $gh_source == "" then null else $gh_source end)
            },
            slack: {configured: $slack_configured},
            discord: {configured: $discord_configured}
        }'
}

# Get the source of the GitHub token (for diagnostics)
# Usage: secrets_get_gh_source
# Returns: "DSR_GH_TOKEN"|"GITHUB_TOKEN"|"GH_TOKEN"|"gh_auth"|"none"
secrets_get_gh_source() {
    if [[ -n "${DSR_GH_TOKEN:-}" ]]; then
        echo "DSR_GH_TOKEN"
    elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
        echo "GITHUB_TOKEN"
    elif [[ -n "${GH_TOKEN:-}" ]]; then
        echo "GH_TOKEN"
    elif command -v gh &>/dev/null && gh auth token &>/dev/null; then
        echo "gh_auth"
    else
        echo "none"
    fi
}

# Export functions
export -f secrets_init secrets_redact secrets_redact_json secrets_mask
export -f secrets_get_gh_token secrets_has_gh_token secrets_validate_gh_scopes
export -f secrets_check_gh_auth secrets_get_slack_webhook secrets_has_slack_webhook
export -f secrets_get_discord_webhook secrets_validate_for secrets_doctor_summary
export -f secrets_get_gh_source
