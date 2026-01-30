#!/usr/bin/env bash
# notify.sh - Notification system for dsr
#
# Provides:
#   - notify_event <event> <level> <title> <message> [run_id]
#   - notify_should_send <run_id> <event>
#   - notify_mark_sent <run_id> <event>
#
# Channels (comma-separated via DSR_NOTIFY_METHODS):
#   terminal, slack, discord, desktop, agent_mail, none, all
#
# Notes:
#   - No prompts; safe for --non-interactive
#   - Secrets are redacted from payloads
#   - Dedup by run_id + event to avoid spam

set -uo pipefail

_NOTIFY_STATE_DIR="${DSR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsr}/notifications"
_NOTIFY_SENT_FILE="$_NOTIFY_STATE_DIR/sent.jsonl"

_notify_log_info() {
  if command -v log_info &>/dev/null; then
    log_info "$1" "${2:-}"
  else
    echo "[notify] $1" >&2
  fi
}

_notify_log_warn() {
  if command -v log_warn &>/dev/null; then
    log_warn "$1" "${2:-}"
  else
    echo "[notify] WARN: $1" >&2
  fi
}

_notify_log_error() {
  if command -v log_error &>/dev/null; then
    log_error "$1" "${2:-}"
  else
    echo "[notify] ERROR: $1" >&2
  fi
}

_notify_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

_notify_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  echo -n "$s"
}

_notify_redact() {
  if command -v secrets_redact &>/dev/null; then
    secrets_redact "$1"
  else
    echo "$1"
  fi
}

notify_init() {
  if ! mkdir -p "$_NOTIFY_STATE_DIR" 2>/dev/null; then
    _notify_log_warn "Cannot create notifications directory: $_NOTIFY_STATE_DIR"
    return 1
  fi
  return 0
}

# Returns 0 if we should send, 1 if already sent
notify_should_send() {
  local run_id="$1"
  local event="$2"

  # If no run_id or event, allow sending (no dedup key)
  if [[ -z "$run_id" || -z "$event" ]]; then
    return 0
  fi

  [[ -f "$_NOTIFY_SENT_FILE" ]] || return 0

  if grep -F "\"run_id\":\"$run_id\",\"event\":\"$event\"" "$_NOTIFY_SENT_FILE" >/dev/null 2>&1; then
    return 1
  fi

  return 0
}

notify_mark_sent() {
  local run_id="$1"
  local event="$2"

  [[ -z "$run_id" || -z "$event" ]] && return 0

  notify_init >/dev/null 2>&1 || return 1

  local ts
  ts=$(_notify_now)
  printf '{"run_id":"%s","event":"%s","ts":"%s"}\n' "$run_id" "$event" "$ts" >> "$_NOTIFY_SENT_FILE"
}

_notify_terminal() {
  local level="$1"
  local title="$2"
  local message="$3"

  local line="$title - $message"
  case "$level" in
    error) _notify_log_error "$line" ;;
    warn) _notify_log_warn "$line" ;;
    success) _notify_log_info "$line" ;;
    *) _notify_log_info "$line" ;;
  esac
}

_notify_slack() {
  local title="$1"
  local message="$2"

  if ! command -v curl &>/dev/null; then
    _notify_log_warn "curl not available; cannot send Slack notification"
    return 1
  fi

  local webhook=""
  if command -v secrets_get_slack_webhook &>/dev/null; then
    webhook=$(secrets_get_slack_webhook 2>/dev/null || true)
  else
    webhook="${DSR_SLACK_WEBHOOK:-}"
  fi

  if [[ -z "$webhook" ]]; then
    _notify_log_warn "Slack webhook not configured"
    return 1
  fi

  local payload text
  text="$title - $message"
  text=$(_notify_redact "$text")
  payload="{\"text\":\"$(_notify_json_escape "$text")\"}"

  if ! curl -sS -X POST -H "Content-type: application/json" --data "$payload" "$webhook" >/dev/null 2>&1; then
    _notify_log_warn "Slack notification failed"
    return 1
  fi
  return 0
}

_notify_discord() {
  local title="$1"
  local message="$2"

  if ! command -v curl &>/dev/null; then
    _notify_log_warn "curl not available; cannot send Discord notification"
    return 1
  fi

  local webhook=""
  if command -v secrets_get_discord_webhook &>/dev/null; then
    webhook=$(secrets_get_discord_webhook 2>/dev/null || true)
  else
    webhook="${DSR_DISCORD_WEBHOOK:-}"
  fi

  if [[ -z "$webhook" ]]; then
    _notify_log_warn "Discord webhook not configured"
    return 1
  fi

  local payload text
  text="$title - $message"
  text=$(_notify_redact "$text")
  payload="{\"content\":\"$(_notify_json_escape "$text")\"}"

  if ! curl -sS -X POST -H "Content-type: application/json" --data "$payload" "$webhook" >/dev/null 2>&1; then
    _notify_log_warn "Discord notification failed"
    return 1
  fi
  return 0
}

_notify_desktop() {
  local title="$1"
  local message="$2"

  # macOS
  if command -v osascript &>/dev/null; then
    # Escape quotes for AppleScript
    local t m
    t="${title//\"/\\\"}"
    m="${message//\"/\\\"}"
    osascript -e "display notification \"$m\" with title \"$t\"" >/dev/null 2>&1 || {
      _notify_log_warn "Desktop notification failed (osascript)"
      return 1
    }
    return 0
  fi

  # Linux (notify-send)
  if command -v notify-send &>/dev/null; then
    notify-send "$title" "$message" >/dev/null 2>&1 || {
      _notify_log_warn "Desktop notification failed (notify-send)"
      return 1
    }
    return 0
  fi

  _notify_log_warn "Desktop notifications not available (osascript/notify-send missing)"
  return 1
}

_notify_agent_mail() {
  local payload="$1"
  local hook="${DSR_AGENT_MAIL_HOOK:-}"

  if [[ -z "$hook" ]]; then
    _notify_log_warn "Agent Mail hook not configured (set DSR_AGENT_MAIL_HOOK)"
    return 1
  fi

  if [[ ! -x "$hook" ]]; then
    _notify_log_warn "Agent Mail hook not executable: $hook"
    return 1
  fi

  if ! printf '%s' "$payload" | "$hook" >/dev/null 2>&1; then
    _notify_log_warn "Agent Mail hook failed"
    return 1
  fi

  return 0
}

notify_event() {
  local event="$1"
  local level="$2"
  local title="$3"
  local message="$4"
  local run_id="${5:-${DSR_RUN_ID:-}}"

  local methods="${DSR_NOTIFY_METHODS:-${DSR_NOTIFY_METHOD:-terminal}}"
  [[ -z "$methods" ]] && methods="terminal"

  if [[ "$methods" == "none" ]]; then
    return 0
  fi

  # Expand "all" to all supported methods
  if [[ "$methods" == "all" ]]; then
    methods="terminal,slack,discord,desktop,agent_mail"
  fi

  notify_init >/dev/null 2>&1 || true

  if ! notify_should_send "$run_id" "$event"; then
    _notify_log_info "Notification already sent for $event ($run_id)"
    return 0
  fi

  local clean_title clean_message
  clean_title=$(_notify_redact "$title")
  clean_message=$(_notify_redact "$message")

  local payload
  payload=$(
    printf '{"event":"%s","level":"%s","title":"%s","message":"%s","run_id":"%s","ts":"%s"}' \
      "$(_notify_json_escape "$event")" \
      "$(_notify_json_escape "$level")" \
      "$(_notify_json_escape "$clean_title")" \
      "$(_notify_json_escape "$clean_message")" \
      "$(_notify_json_escape "$run_id")" \
      "$(_notify_now)"
  )

  local any_sent=false
  local method
  IFS=',' read -ra _methods <<< "$methods"
  for method in "${_methods[@]}"; do
    case "$method" in
      terminal)
        _notify_terminal "$level" "$clean_title" "$clean_message"
        any_sent=true
        ;;
      slack)
        _notify_slack "$clean_title" "$clean_message" && any_sent=true
        ;;
      discord)
        _notify_discord "$clean_title" "$clean_message" && any_sent=true
        ;;
      desktop)
        _notify_desktop "$clean_title" "$clean_message" && any_sent=true
        ;;
      agent_mail)
        _notify_agent_mail "$payload" && any_sent=true
        ;;
      *)
        _notify_log_warn "Unknown notify method: $method"
        ;;
    esac

    if command -v log_debug &>/dev/null; then
      log_debug "notify method=$method event=$event run_id=$run_id"
    fi
  done

  if $any_sent; then
    notify_mark_sent "$run_id" "$event"
  fi

  return 0
}

export -f notify_event notify_should_send notify_mark_sent
