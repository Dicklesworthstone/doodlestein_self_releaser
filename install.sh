#!/usr/bin/env bash
#
# dsr installer — Doodlestein Self-Releaser
#
# Fallback release infrastructure for when GitHub Actions is throttled.
# Builds and releases tools locally via nektos/act with cross-platform SSH.
#
# One-liner install (with cache buster):
#   curl -fsSL "https://raw.githubusercontent.com/Dicklesworthstone/doodlestein_self_releaser/main/install.sh?$(date +%s)" | bash
#
# Or without cache buster:
#   curl -fsSL https://raw.githubusercontent.com/Dicklesworthstone/doodlestein_self_releaser/main/install.sh | bash
#
# Options:
#   --version vX.Y.Z   Install specific version (default: latest from main)
#   --dest DIR         Install to DIR (default: ~/.local/bin)
#   --system           Install to /usr/local/bin (requires sudo)
#   --easy-mode        Auto-update PATH in shell rc files + run doctor
#   --verify           Require the installed launcher to pass dsr doctor
#   --quiet            Suppress non-error output
#   --no-gum           Disable gum formatting even if available
#   --no-configure     Skip AI agent skill installation
#   --no-verify        Reserved for future checksum verification
#   --offline TARBALL  Install from pre-downloaded repo tarball
#   --repo-dir DIR     Clone repo to DIR (default: ~/.local/share/dsr/repo)
#   --force            Reinstall even if same version exists
#   --uninstall        Deactivate the selected launcher; retain source, skills and data
#   -h, --help         Show this help
#
# Updates are staged and validated before activation. Previous source checkouts
# are retained beside --repo-dir in .<name>.install.*/previous-repo. Handled
# activation failures and signals restore the prior source and launcher.
#

set -euo pipefail
shopt -s lastpipe 2>/dev/null || true
umask 022

# ============================================================
# Configuration Defaults
# ============================================================

OWNER="Dicklesworthstone"
REPO="doodlestein_self_releaser"
BINARY_NAME="dsr"
INSTALLER_VERSION="0.2.3"
GITHUB_RAW="https://raw.githubusercontent.com/${OWNER}/${REPO}"

DEST="${DSR_DEST:-$HOME/.local/bin}"
VERSION=""
VERSION_EXPLICIT=0
QUIET=0
NO_GUM=0
NO_CONFIGURE=0
FORCE_INSTALL=0
EASY=0
VERIFY=0
SYSTEM=0
UNINSTALL=0
OFFLINE_TARBALL=""
OFFLINE_PUBKEY=""

# Agent status tracking
CLAUDE_STATUS=""
CODEX_STATUS=""
GEMINI_STATUS=""
# Reserved for future use (version display in summary)
# shellcheck disable=SC2034
CLAUDE_BACKUP="" CLAUDE_VERSION="" CODEX_VERSION="" GEMINI_VERSION=""
DETECTED_AGENTS=()

# Lock management
LOCK_DIR=""
LOCKED=0
TMP=""
CLONE_REFS=()
INSTALL_COMMITTED=0
INSTALL_REPO_CANDIDATE=""
INSTALL_REPO_PREVIOUS=""
INSTALL_REPO_NEW_ID=""
INSTALL_REPO_OLD_ID=""
INSTALL_REPO_SWITCH=0
INSTALL_LINK_STAGE=""
INSTALL_LINK_NEW_ID=""
INSTALL_LINK_OLD_ID=""
INSTALL_LINK_SWITCH=0
INSTALL_LOCK_ID=""
INSTALL_REQUEST_DIR=""
INSTALL_REQUEST_CHILD=""
INSTALL_REQUEST_GUARD=""
INSTALL_REQUEST_STARTING=0
INSTALL_REQUEST_STOPPING=0
INSTALL_INTERRUPTED=0

# ============================================================
# Usage
# ============================================================

usage() {
  cat <<'EOF'
dsr installer — Doodlestein Self-Releaser

Usage:
  curl -fsSL "https://raw.githubusercontent.com/Dicklesworthstone/doodlestein_self_releaser/main/install.sh?$(date +%s)" | bash
  bash install.sh [OPTIONS]

Options:
  --version vX.Y.Z   Install specific version (default: latest from main)
  --dest DIR         Install to DIR (default: ~/.local/bin)
  --system           Install to /usr/local/bin (requires sudo)
  --easy-mode        Auto-update PATH + run doctor + install skills
  --verify           Require the installed launcher to pass dsr doctor
  --quiet            Suppress non-error output
  --no-gum           Disable gum formatting even if available
  --no-configure     Skip AI agent skill installation
  --no-verify        Reserved for future checksum verification
  --offline FILE     Install from pre-downloaded repo tarball
  --offline-pubkey FILE  Require FILE as the trusted Minisign public key for the
                         archive; read its detached signature from ARCHIVE.minisig
  --repo-dir DIR     Clone repo to DIR (default: ~/.local/share/dsr/repo)
  --force            Reinstall even if same version exists
  --uninstall        Deactivate the selected launcher; retain source, skills and data
  -h, --help         Show this help

Updates retain the previous source in a sibling .<repo-name>.install.*/previous-repo
directory and any replaced launcher in --dest/.dsr-launcher.*/previous. Acquisition
and validation do not change the active checkout. Handled activation failures and
signals restore prior entries; abrupt power loss or SIGKILL can require manual
recovery from the retained directories.

Uninstall uses the same --dest and --repo-dir as installation (or --system for
the system launcher). It retains the removed symlink in a recovery directory
beside the launcher. Source, skills and data may serve other installations.

With --verify, a failed or timed-out doctor check restores the previous launcher
and checkout. An already-installed requested tag is also checked. With only
--easy-mode, the same diagnostic is advisory.

Explicit versions select release tags (with or without a leading v), even when
a branch has the same name. Use --version main to select the main branch.

Environment:
  DSR_DEST           Override install directory (default: ~/.local/bin)
  DSR_DATA_DIR       Override data directory (default: ~/.local/share/dsr)
  DSR_REPO_DIR       Override repo clone directory (default: $DSR_DATA_DIR/repo)
  DSR_INSTALLER_TIMEOUT  Complete request budget, 1–3600 seconds (default:
                         30 for HTTP and doctor, 300 for Git; includes helpers)
  HTTPS_PROXY        Proxy for HTTPS connections
  HTTP_PROXY         Proxy for HTTP connections
EOF
}

# ============================================================
# Argument Parsing
# ============================================================

while [ $# -gt 0 ]; do
  case "$1" in
    --version)       VERSION="$2"; VERSION_EXPLICIT=1; shift 2 ;;
    --dest=*|--repo-dir=*)
      set -- "${1%%=*}" "${1#*=}" "${@:2}"
      continue ;;
    --dest|--repo-dir)
      if [[ -z "${2:-}" || "$2" == --* ]]; then
        printf '%s requires a directory\n' "$1" >&2
        exit 4
      fi
      if [[ "$1" == --dest ]]; then DEST="$2"; else REPO_DIR="$2"; fi
      shift 2 ;;
    --system)        SYSTEM=1; DEST="/usr/local/bin"; shift ;;
    --easy-mode)     EASY=1; shift ;;
    --verify)        VERIFY=1; shift ;;
    --quiet|-q)      QUIET=1; shift ;;
    --no-gum)        NO_GUM=1; shift ;;
    --no-configure)  NO_CONFIGURE=1; shift ;;
    --no-verify)     shift ;;  # reserved for future checksum verification
    --offline)       OFFLINE_TARBALL="$2"; shift 2 ;;
    --offline-pubkey=*)
      set -- --offline-pubkey "${1#*=}" "${@:2}"
      continue ;;
    --offline-pubkey)
      if [[ -z "${2:-}" || "$2" == --* || -n "$OFFLINE_PUBKEY" ]]; then
        printf '%s\n' '--offline-pubkey requires one trusted public key file' >&2
        exit 4
      fi
      OFFLINE_PUBKEY="$2"
      shift 2 ;;
    --force)         FORCE_INSTALL=1; shift ;;
    --uninstall)     UNINSTALL=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *)               printf 'Unknown installer argument: %s\n' "$1" >&2; exit 4 ;;
  esac
done

# ============================================================
# Gum Detection + ANSI Fallback
# ============================================================

HAS_GUM=0
if command -v gum &>/dev/null && [ -t 1 ]; then
  HAS_GUM=1
fi

info() {
  [ "$QUIET" -eq 1 ] && return 0
  if [ "$HAS_GUM" -eq 1 ] && [ "$NO_GUM" -eq 0 ]; then
    gum style --foreground 39 "→ $*"
  else
    echo -e "\033[0;34m→\033[0m $*"
  fi
}

ok() {
  [ "$QUIET" -eq 1 ] && return 0
  if [ "$HAS_GUM" -eq 1 ] && [ "$NO_GUM" -eq 0 ]; then
    gum style --foreground 42 "✓ $*"
  else
    echo -e "\033[0;32m✓\033[0m $*"
  fi
}

warn() {
  if [ "$HAS_GUM" -eq 1 ] && [ "$NO_GUM" -eq 0 ]; then
    gum style --foreground 214 "⚠ $*"
  else
    echo -e "\033[1;33m⚠\033[0m $*" >&2
  fi
}

err() {
  if [ "$HAS_GUM" -eq 1 ] && [ "$NO_GUM" -eq 0 ]; then
    gum style --foreground 196 "✗ $*"
  else
    echo -e "\033[0;31m✗\033[0m $*" >&2
  fi
}

run_with_spinner() {
  local title="$1"
  shift
  if [ "$HAS_GUM" -eq 1 ] && [ "$NO_GUM" -eq 0 ] && [ "$QUIET" -eq 0 ] && ! declare -F "$1" >/dev/null; then
    gum spin --spinner dot --title "$title" -- "$@"
  else
    info "$title"
    "$@"
  fi
}

# ============================================================
# Box Drawing
# ============================================================

draw_box() {
  local color="$1"
  shift
  local lines=("$@")
  local max_width=0
  local esc
  esc=$(printf '\033')
  local strip_ansi_sed="s/${esc}\\[[0-9;]*m//g"

  for line in "${lines[@]}"; do
    local stripped
    stripped=$(printf '%b' "$line" | LC_ALL=C sed "$strip_ansi_sed")
    local len=${#stripped}
    if [ "$len" -gt "$max_width" ]; then
      max_width=$len
    fi
  done

  local inner_width=$((max_width + 4))
  local border=""
  for ((i = 0; i < inner_width; i++)); do
    border+="═"
  done

  printf "\033[%sm╔%s╗\033[0m\n" "$color" "$border"

  for line in "${lines[@]}"; do
    local stripped
    stripped=$(printf '%b' "$line" | LC_ALL=C sed "$strip_ansi_sed")
    local len=${#stripped}
    local padding=$((max_width - len))
    local pad_str=""
    for ((j = 0; j < padding; j++)); do
      pad_str+=" "
    done
    printf "\033[%sm║\033[0m  %b%s  \033[%sm║\033[0m\n" "$color" "$line" "$pad_str" "$color"
  done

  printf "\033[%sm╚%s╝\033[0m\n" "$color" "$border"
}

status_path() {
  local path="$1"
  if [[ -n "${HOME:-}" && "$path" == "$HOME"/* ]]; then
    # shellcheck disable=SC2088 # This is display text, not an executable shell path.
    printf '~/%s\n' "${path#"$HOME"/}"
  else
    printf '%s\n' "$path"
  fi
}

# ============================================================
# Header Banner
# ============================================================

show_header() {
  [ "$QUIET" -eq 1 ] && return 0

  if [ "$HAS_GUM" -eq 1 ] && [ "$NO_GUM" -eq 0 ]; then
    gum style \
      --border normal \
      --border-foreground 208 \
      --padding "0 1" \
      --margin "1 0" \
      "$(gum style --foreground 208 --bold 'dsr installer')" \
      "$(gum style --foreground 245 'Fallback release infrastructure for throttled CI')"
  else
    echo ""
    draw_box "0;33" \
      "\033[1;33mdsr installer\033[0m" \
      "\033[0;90mFallback release infrastructure for throttled CI\033[0m"
    echo ""
  fi
}

# ============================================================
# Platform Detection
# ============================================================

detect_platform() {
  OS=$(uname -s | tr '[:upper:]' '[:lower:]')
  ARCH=$(uname -m)

  case "$ARCH" in
    x86_64 | amd64) ARCH="x86_64" ;;
    arm64 | aarch64) ARCH="aarch64" ;;
  esac

  # WSL detection
  if [[ "$OS" == "linux" ]] && grep -qi microsoft /proc/version 2>/dev/null; then
    warn "WSL detected — Docker and SSH features may need extra configuration"
  fi

  # Bash version check (dsr requires 4.0+)
  local bash_major="${BASH_VERSINFO[0]:-0}"
  local bash_minor="${BASH_VERSINFO[1]:-0}"; : "$bash_minor"  # reserved for future 4.x checks
  if [ "$bash_major" -lt 4 ]; then
    err "dsr requires Bash 4.0+ (found ${BASH_VERSION:-unknown})"
    err "On macOS: brew install bash"
    exit 1
  fi
}

# ============================================================
# Proxy Setup
# ============================================================

PROXY_ARGS=()

setup_proxy() {
  if [[ -n "${HTTPS_PROXY:-}" ]]; then
    PROXY_ARGS=(--proxy "$HTTPS_PROXY")
    info "Using HTTPS proxy: $HTTPS_PROXY"
  elif [[ -n "${HTTP_PROXY:-}" ]]; then
    PROXY_ARGS=(--proxy "$HTTP_PROXY")
    info "Using HTTP proxy: $HTTP_PROXY"
  fi
}

# A connect timeout does not bound a complete response, a redirect chain, or a
# Git credential helper. Supervise the whole acquisition in an owned process
# group. Keep this supervisor in the installer shell (never $(...)) so a signal
# sent only to the installer PID can stop every ordinary request descendant.
validate_request_timeout() {
  if [[ -n "${DSR_INSTALLER_TIMEOUT+x}" ]] &&
     { [[ ! "$DSR_INSTALLER_TIMEOUT" =~ ^[1-9][0-9]{0,3}$ ]] || ((DSR_INSTALLER_TIMEOUT > 3600)); }; then
    err "DSR_INSTALLER_TIMEOUT must be an integer from 1 through 3600 seconds"
    return 4
  fi
}

request_workspace() {
  [[ -z "$INSTALL_REQUEST_DIR" ]] || return 0
  INSTALL_REQUEST_DIR=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/dsr-installer-request.XXXXXXXX") || return 1
}

stop_request() {
  INSTALL_REQUEST_STOPPING=1
  [[ -z "$INSTALL_REQUEST_CHILD" ]] || kill -TERM -- "-$INSTALL_REQUEST_CHILD" 2>/dev/null || true
  [[ -z "$INSTALL_REQUEST_GUARD" ]] || kill -TERM -- "-$INSTALL_REQUEST_GUARD" 2>/dev/null || true
  [[ -z "$INSTALL_REQUEST_CHILD" ]] || kill -KILL -- "-$INSTALL_REQUEST_CHILD" 2>/dev/null || true
  [[ -z "$INSTALL_REQUEST_GUARD" ]] || kill -KILL -- "-$INSTALL_REQUEST_GUARD" 2>/dev/null || true
  [[ -z "$INSTALL_REQUEST_CHILD" ]] || wait "$INSTALL_REQUEST_CHILD" 2>/dev/null || true
  [[ -z "$INSTALL_REQUEST_GUARD" ]] || wait "$INSTALL_REQUEST_GUARD" 2>/dev/null || true
  INSTALL_REQUEST_CHILD="" INSTALL_REQUEST_GUARD=""
  INSTALL_REQUEST_STOPPING=0
}

installer_signal() {
  INSTALL_INTERRUPTED="$1"
  # Do not lose $! if a signal arrives between fork and PID registration.
  if ((INSTALL_REQUEST_STARTING || INSTALL_REQUEST_STOPPING)); then return; fi
  exit "$INSTALL_INTERRUPTED"
}

request_terminal_status() {
  case "$1" in 124|129|130|131|137|143) return 0 ;; *) return 1 ;; esac
}

run_request() {
  local limit="$1" status=0 monitor=0
  shift
  request_workspace || return 1
  rm -f -- "$INSTALL_REQUEST_DIR/timeout" || return 1
  [[ "$-" != *m* ]] || monitor=1
  INSTALL_REQUEST_STARTING=1
  set -m
  (
    set +m
    trap - EXIT HUP INT TERM
    "$@"
  ) </dev/null &
  INSTALL_REQUEST_CHILD=$!
  (
    set +m
    trap - EXIT HUP INT TERM
    sleep "$limit" & timer=$!
    wait "$timer" || exit 0
    printf 'timeout\n' > "$INSTALL_REQUEST_DIR/timeout" || true
    kill -TERM -- "-$INSTALL_REQUEST_CHILD" 2>/dev/null || true
    sleep 1 & timer=$!
    wait "$timer" || exit 0
    kill -KILL -- "-$INSTALL_REQUEST_CHILD" 2>/dev/null || true
  ) </dev/null >/dev/null 2>&1 &
  INSTALL_REQUEST_GUARD=$!
  ((monitor)) || set +m
  INSTALL_REQUEST_STARTING=0
  ((INSTALL_INTERRUPTED == 0)) || installer_signal "$INSTALL_INTERRUPTED"
  wait "$INSTALL_REQUEST_CHILD" 2>/dev/null || status=$?
  stop_request
  # Reap the watchdog before classifying the result: it cannot mark an expired
  # request after this check and turn a timeout into permission to try again.
  [[ ! -f "$INSTALL_REQUEST_DIR/timeout" ]] || status=124
  ((INSTALL_INTERRUPTED == 0)) || installer_signal "$INSTALL_INTERRUPTED"
  if ((status == 124)); then err "Acquisition exceeded its ${limit}s request budget"; fi
  return "$status"
}

request_curl() {
  curl -q --connect-timeout 5 --max-time "${DSR_INSTALLER_TIMEOUT:-30}" \
    --user-agent "doodlestein_self_releaser-installer" "${PROXY_ARGS[@]}" "$@" 2>/dev/null
}

http_request() {
  local status=0
  request_workspace || return 1
  run_request "${DSR_INSTALLER_TIMEOUT:-30}" request_curl "$@" > "$INSTALL_REQUEST_DIR/body" || status=$?
  # curl can reach its own connect/response deadline before the watchdog.
  # That remains terminal, not permission to try another acquisition.
  if ((status == 28)); then err "HTTP acquisition timed out"; return 124; fi
  return "$status"
}

# ============================================================
# Version Resolution
# ============================================================

resolve_version() {
  # 1. CLI flag
  [[ -n "$VERSION" ]] && return 0
  # An offline archive determines its own version after staging and validation.
  [[ -n "$OFFLINE_TARBALL" ]] && return 0

  # 2. GitHub API (latest release tag, if releases exist)
  local status=0
  http_request -fsSL "https://api.github.com/repos/${OWNER}/${REPO}/releases/latest" || status=$?
  request_terminal_status "$status" && return "$status"
  VERSION=""
  if ((status == 0)); then
    VERSION=$(grep -o '"tag_name": *"[^"]*"' "$INSTALL_REQUEST_DIR/body" \
      | head -n 1 | sed -E 's/.*"v?([^"]*)"$/\1/' || true)
  fi
  [[ "$VERSION" =~ ^[0-9] ]] || VERSION=""
  [[ -n "$VERSION" ]] && return 0

  # 3. Redirect URL parsing (fallback when API rate-limited)
  status=0
  http_request -fsSL -o /dev/null -w '%{url_effective}' \
    "https://github.com/${OWNER}/${REPO}/releases/latest" || status=$?
  request_terminal_status "$status" && return "$status"
  if ((status == 0)); then VERSION=$(sed -E 's|.*/tag/v?||' "$INSTALL_REQUEST_DIR/body"); fi
  # Reject HTML page (GitHub returns /releases if no releases exist)
  if [[ "$VERSION" == *"releases"* ]] || [[ -z "$VERSION" ]]; then
    VERSION=""
  fi
  [[ -n "$VERSION" ]] && return 0

  # 4. Parse from raw dsr script header on GitHub
  status=0
  http_request -fsSL "${GITHUB_RAW}/main/dsr" || status=$?
  request_terminal_status "$status" && return "$status"
  if ((status == 0)); then
    VERSION=$(grep -m1 'DSR_VERSION=' "$INSTALL_REQUEST_DIR/body" | sed -E 's/.*"([^"]+)".*/\1/' || true)
  fi
  [[ -n "$VERSION" ]] && return 0

  # 5. Installer-bundled version (last resort)
  VERSION="$INSTALLER_VERSION"
}

# ============================================================
# Preflight Checks
# ============================================================

check_disk_space() {
  local available_kb
  available_kb=$(df -Pk "$DEST" 2>/dev/null | awk 'NR==2{print $4}' || echo "0")
  if [ "${available_kb:-0}" -lt 1024 ]; then
    err "Insufficient disk space in $DEST (need at least 1 MB, have ${available_kb} KB)"
    exit 1
  fi
}

check_write_permissions() {
  if [ -d "$DEST" ]; then
    if [ ! -w "$DEST" ]; then
      if [ "$SYSTEM" -eq 1 ]; then
        info "System install requires sudo"
      else
        err "No write permission to $DEST"
        err "Try: --system (installs to /usr/local/bin with sudo)"
        exit 1
      fi
    fi
  else
    local parent
    parent=$(dirname "$DEST")
    if [ ! -w "$parent" ] && [ "$SYSTEM" -eq 0 ]; then
      err "Cannot create $DEST (parent $parent not writable)"
      exit 1
    fi
  fi
}

# A hook or wrapper can export Git's repository-local environment. Without
# isolation, even `git -C "$candidate" init/fetch/checkout` can mutate that
# caller's repository, worktree, index, or object storage. Keep user/system
# credential helpers and URL policy, but never import another repository's
# plumbing or execute its hooks/monitor while inspecting or acquiring source.
installer_git() (
  unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE
  unset GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
  unset GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
  unset GIT_IMPLICIT_WORK_TREE GIT_PREFIX GIT_SHALLOW_FILE GIT_GRAFT_FILE
  unset GIT_NAMESPACE GIT_REPLACE_REF_BASE GIT_TEMPLATE_DIR
  export GIT_TERMINAL_PROMPT=0 GIT_NO_REPLACE_OBJECTS=1
  git -c core.hooksPath=/dev/null -c core.fsmonitor=false -c submodule.recurse=false "$@"
)

installed_matches_requested_tag() {
  local top head tag ref
  local context=(-C "$REPO_DIR" -c "core.worktree=$REPO_DIR")
  top=$(installer_git "${context[@]}" rev-parse --show-toplevel 2>/dev/null) || return 1
  [[ "$top" == "$REPO_DIR" ]] || return 1
  head=$(installer_git "${context[@]}" rev-parse --verify HEAD 2>/dev/null) || return 1
  # Main can contain many newer commits with an unchanged DSR_VERSION. Only
  # an unchanged checkout of the requested local tag can satisfy a pinned
  # version without acquisition. Missing/unverifiable identities are misses.
  build_clone_refs
  for ref in "${CLONE_REFS[@]}"; do
    tag=$(installer_git "${context[@]}" rev-parse --verify "refs/tags/$ref^{commit}" 2>/dev/null) || continue
    if [[ "$tag" == "$head" ]] &&
       installer_git "${context[@]}" diff-index --cached --quiet HEAD -- &&
       installer_git "${context[@]}" diff-files --quiet --; then
      return 0
    fi
  done
  return 1
}

check_existing_install() {
  local installed="$DEST/$BINARY_NAME" current="" current_version=""
  if [[ -x "$installed" && ! -d "$installed" ]]; then
    # Inspect the selected destination, never an unrelated dsr earlier on PATH.
    # Capture the complete result first so head cannot turn SIGPIPE into a
    # false failure under pipefail.
    if command -v timeout >/dev/null 2>&1; then
      current=$(timeout 10 "$installed" --version 2>/dev/null) || current=""
    elif command -v gtimeout >/dev/null 2>&1; then
      current=$(gtimeout 10 "$installed" --version 2>/dev/null) || current=""
    else
      current=$("$installed" --version 2>/dev/null) || current=""
    fi
    if [[ "$current" =~ ^dsr[[:blank:]]version[[:blank:]]v?([0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?)$ ]]; then
      current_version="${BASH_REMATCH[1]}"
    fi
    # A version label cannot authenticate a newly supplied offline archive.
    # A different --repo-dir also requires installing that selected source.
    if [ "$FORCE_INSTALL" -eq 0 ] && [ "$VERSION_EXPLICIT" -eq 1 ] &&
       [[ -z "$OFFLINE_TARBALL" && -n "$current_version" && "$current_version" == "${VERSION#v}" &&
          -L "$installed" && "$(readlink "$installed")" == "$REPO_DIR/dsr" ]] &&
       installed_matches_requested_tag; then
      if ((VERIFY)); then run_doctor || return $?; fi
      ok "dsr $VERSION is already installed"
      info "Use --force to reinstall"
      INSTALL_COMMITTED=1
      # Still run agent configuration (idempotent)
      if [ "$NO_CONFIGURE" -eq 0 ]; then
        local configure_status=0
        configure_agents || configure_status=$?
        request_terminal_status "$configure_status" && return "$configure_status"
        ((configure_status == 0)) || warn "Agent configuration did not complete; the installed dsr is unchanged"
      fi
      show_summary
      exit 0
    fi
    if [ "$FORCE_INSTALL" -eq 0 ] && [ "$VERSION_EXPLICIT" -eq 0 ] &&
       [[ -n "$current_version" && "$current_version" == "${VERSION#v}" ]]; then
      info "Existing dsr version matches; checking the main-branch source clone for updates"
    fi
    info "Existing dsr at $installed: ${current:-version unavailable}"
  fi
}

check_network() {
  if [[ -n "$OFFLINE_TARBALL" ]]; then
    return 0
  fi
  local status=0
  http_request -fsSL "https://github.com/${OWNER}/${REPO}" -o /dev/null || status=$?
  request_terminal_status "$status" && return "$status"
  if ((status != 0)); then
    warn "Cannot reach github.com — install may fail"
    warn "Use --offline FILE to install from a pre-downloaded script"
  fi
}

preflight_checks() {
  info "Running preflight checks"

  mkdir -p "$DEST" 2>/dev/null || true
  check_disk_space
  check_write_permissions

  if [[ -z "$OFFLINE_TARBALL" ]]; then
    check_network || return $?
  fi

  # Check for curl (used for version resolution + skill downloads, but not required —
  # git clone is the primary install mechanism and all curl calls have fallbacks)
  if [[ -z "$OFFLINE_TARBALL" ]] && ! command -v curl >/dev/null 2>&1; then
    warn "curl not found — version resolution and skill downloads will use fallbacks"
  fi

  ok "Preflight checks passed"
}

# ============================================================
# Atomic Locking + Cleanup
# ============================================================

LOCK_FILE="/tmp/dsr-installer"

cleanup() {
  local status=$?
  trap - EXIT
  # Finish a handled rollback even if another interrupt arrives midway.
  trap '' HUP INT TERM
  stop_request
  if [ "$INSTALL_COMMITTED" -eq 0 ]; then
    if ! rollback_installation; then
      status=1
    fi
  fi
  # Workspaces can contain the previous checkout, a previous launcher, and
  # acquisition diagnostics. Keep them rather than recursively deleting them.
  if [[ -n "$TMP" && -d "$TMP" ]]; then
    if [ "$INSTALL_COMMITTED" -eq 1 ]; then
      info "Previous source and acquisition files retained at: $TMP"
    else
      warn "Installer staging retained for inspection: $TMP"
    fi
  fi
  if [[ -n "$INSTALL_LINK_STAGE" ]]; then
    info "Launcher recovery files retained at: $INSTALL_LINK_STAGE"
  fi
  if [ "$LOCKED" -eq 1 ]; then
    if [[ -n "$INSTALL_LOCK_ID" && ! -L "$LOCK_DIR" &&
          "$(install_path_identity "$LOCK_DIR")" == "$INSTALL_LOCK_ID" &&
          -f "$LOCK_DIR/pid" && ! -L "$LOCK_DIR/pid" &&
          "$(cat "$LOCK_DIR/pid")" == "$$" ]]; then
      # Only our own bookkeeping is removed; unexpected entries retain the
      # lock for inspection instead of being recursively discarded.
      if ! rm -- "$LOCK_DIR/pid" || ! rmdir -- "$LOCK_DIR"; then
        warn "Installation lock retained for inspection: $LOCK_DIR"
      fi
    else
      warn "Installation lock ownership changed; leaving it untouched: $LOCK_DIR"
    fi
  fi
  if [[ -n "$INSTALL_REQUEST_DIR" ]]; then
    rm -f -- "$INSTALL_REQUEST_DIR/body" "$INSTALL_REQUEST_DIR/timeout" || true
    rmdir -- "$INSTALL_REQUEST_DIR" 2>/dev/null || warn "Request workspace retained for inspection: $INSTALL_REQUEST_DIR"
  fi
  exit "$status"
}

acquire_lock() {
  LOCK_DIR="${LOCK_FILE}.d"
  if (umask 077; mkdir -- "$LOCK_DIR") 2>/dev/null; then
    LOCKED=1
    INSTALL_LOCK_ID=$(install_path_identity "$LOCK_DIR") || return 1
    (umask 077; printf '%s\n' "$$" >"$LOCK_DIR/pid") || return 1
  else
    err "Another dsr installer is running or its lock needs inspection: $LOCK_DIR"
    err "Wait for the active installer; inspect a stopped install before removing its lock."
    return 1
  fi
}

# ============================================================
# Download + Install
# ============================================================
# dsr is a modular bash project (dsr + src/*.sh modules).
# It must be cloned as a full repo, then symlinked into PATH.

DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
DSR_DATA_DIR="${DSR_DATA_DIR:-$DATA_HOME/dsr}"
REPO_DIR="${REPO_DIR:-${DSR_REPO_DIR:-$DSR_DATA_DIR/repo}}"

install_destination_command() {
  if [ "$SYSTEM" -eq 1 ]; then
    sudo -- "$@"
  else
    "$@"
  fi
}

# lstat identity works for both a checkout directory and a launcher symlink.
# Do not follow symlinks here: rollback must recognize the exact moved entry.
install_path_identity() {
  local path="$1" scope="${2:-source}" identity
  if [[ "$scope" == destination ]]; then
    identity=$(install_destination_command stat -c '%d:%i' -- "$path" 2>/dev/null) ||
      identity=$(install_destination_command stat -f '%d:%i' "$path" 2>/dev/null) || return 1
  else
    identity=$(stat -c '%d:%i' -- "$path" 2>/dev/null) ||
      identity=$(stat -f '%d:%i' "$path" 2>/dev/null) || return 1
  fi
  [[ "$identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
  printf '%s\n' "$identity"
}

# Resolve existing ancestors without creating missing children. Overlap checks
# can then reject an invalid destination before mkdir touches the live source.
install_absolute_directory() {
  local path="$1" suffix="" component parent
  while [[ ! -d "$path" ]]; do
    [[ ! -e "$path" && ! -L "$path" ]] || return 1
    component=$(basename -- "$path") || return 1
    suffix="$component/$suffix"
    parent=$(dirname -- "$path") || return 1
    [[ "$parent" != "$path" ]] || return 1
    path="$parent"
  done
  path=$(CDPATH='' cd -P -- "$path" && pwd -P) || return 1
  while [[ -n "$suffix" ]]; do
    component="${suffix%%/*}"; suffix="${suffix#*/}"
    case "$component" in
      ''|.) ;;
      ..) path="${path%/*}"; [[ -n "$path" ]] || path=/ ;;
      *) path="${path%/}/$component" ;;
    esac
    # A missing component followed by .. can expose an existing sibling
    # symlink. Resolve each newly reachable directory before the next step.
    if [[ -d "$path" ]]; then
      path=$(CDPATH='' cd -P -- "$path" && pwd -P) || return 1
    elif [[ -e "$path" || -L "$path" ]]; then
      return 1
    fi
  done
  printf '%s\n' "$path"
}

prepare_install_paths() {
  local leaf selected_repo selected_dest launcher
  [[ -n "$DEST" && -n "$REPO_DIR" && "$DEST" != *[[:cntrl:]]* &&
     "$REPO_DIR" != *[[:cntrl:]]* ]] || { err "Invalid installation path"; return 1; }
  while [[ "$REPO_DIR" == */ && "$REPO_DIR" != / ]]; do REPO_DIR="${REPO_DIR%/}"; done
  leaf=$(basename -- "$REPO_DIR") || return 1
  [[ "$leaf" != . && "$leaf" != .. && "$leaf" != / ]] || {
    err "--repo-dir must name a dedicated source directory"; return 1;
  }
  [[ ! -L "$REPO_DIR" ]] || {
    err "Install source directory is a symlink; select its real path with --repo-dir"; return 1;
  }
  selected_repo=$(install_absolute_directory "$REPO_DIR") || {
    err "Install source path is not a usable directory: $REPO_DIR"; return 1;
  }
  selected_dest=$(install_absolute_directory "$DEST") || {
    err "Launcher destination is not a usable directory: $DEST"; return 1;
  }
  launcher="${selected_dest%/}/$BINARY_NAME"
  if [[ "$selected_dest" == "$selected_repo" || "$selected_dest" == "$selected_repo/"* ||
        "$selected_repo" == "$launcher" || "$selected_repo" == "$launcher/"* ]]; then
    err "The launcher and source checkout paths must not overlap"
    return 1
  fi
  if [[ -d "$launcher" ]]; then
    err "Launcher destination is a directory: $launcher"
    return 1
  fi
  REPO_DIR="$selected_repo"; DEST="$selected_dest"
  if ((UNINSTALL)); then return 0; fi
  mkdir -p -- "$(dirname "$REPO_DIR")" || return 1
  if [[ ! -d "$DEST" ]]; then install_destination_command mkdir -p -- "$DEST" || return 1; fi
}

repo_dir_has_entries() {
  local first_entry
  first_entry=$(find "$1" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)
  [[ -n "$first_entry" ]]
}

ensure_repo_dir_available() {
  if [ ! -e "$REPO_DIR" ]; then
    return 0
  fi

  if [ ! -d "$REPO_DIR" ]; then
    err "Install source path exists but is not a directory: $REPO_DIR"
    err "Choose a different --repo-dir or set DSR_REPO_DIR to a dedicated source directory."
    return 1
  fi

  # A previous offline install has no .git directory. Its recognizable source
  # tree is also replaceable, and the entire old directory is always retained.
  if repo_dir_has_entries "$REPO_DIR" && [[ ! -d "$REPO_DIR/.git" && ! -f "$REPO_DIR/.git" ]] &&
     ! { [[ -f "$REPO_DIR/dsr" && ! -L "$REPO_DIR/dsr" && -d "$REPO_DIR/src" && ! -L "$REPO_DIR/src" ]] &&
         grep -q '^DSR_VERSION=' "$REPO_DIR/dsr"; }; then
    err "Install source path exists but is not a git clone: $REPO_DIR"
    err "dsr stores runtime data under $(status_path "$DSR_DATA_DIR"); the source checkout must be a dedicated directory."
    err "Use --repo-dir with an empty directory, or set DSR_REPO_DIR to a dedicated source directory."
    return 1
  fi
  INSTALL_REPO_OLD_ID=$(install_path_identity "$REPO_DIR") || return 1
}

build_clone_refs() {
  CLONE_REFS=()

  if [ "$VERSION_EXPLICIT" -eq 1 ] && [[ -n "$VERSION" && "$VERSION" != main ]]; then
    if [[ "$VERSION" == v* ]]; then
      CLONE_REFS+=("$VERSION")
      [[ "${VERSION#v}" != "$VERSION" ]] && CLONE_REFS+=("${VERSION#v}")
    else
      CLONE_REFS+=("v${VERSION}" "$VERSION")
    fi
  else
    CLONE_REFS+=("main")
  fi
}

clone_repo_ref() {
  local clone_ref="$1"
  local error_file="$2"
  local destination="$3"
  local context=(-C "$destination" -c "core.worktree=$destination")

  if [ "$VERSION_EXPLICIT" -eq 1 ] && [[ "$VERSION" != main ]]; then
    # A branch and a tag may have the same short name. Fetch only the exact
    # tag namespace so --version cannot install a same-labelled branch.
    # Each attempt has its own private destination and retained diagnostics.
    (
      local tag_ref="refs/tags/$clone_ref" commit
      installer_git check-ref-format "$tag_ref" || exit 1
      # A template may contain its own core.worktree or executable hooks.
      # The installer needs none; --template= also overrides init.templateDir.
      installer_git -c "core.worktree=$destination" init --quiet --template= "$destination" || exit $?
      installer_git "${context[@]}" remote add origin "https://github.com/${OWNER}/${REPO}.git" || exit $?
      installer_git "${context[@]}" fetch --quiet --depth 1 --no-tags origin "$tag_ref:$tag_ref" || exit $?
      commit=$(installer_git "${context[@]}" rev-parse --verify "$tag_ref^{commit}") || exit $?
      installer_git "${context[@]}" checkout --quiet --detach "$commit" || exit $?
      [[ "$(installer_git "${context[@]}" rev-parse --verify HEAD)" == "$commit" ]]
    ) 2>"$error_file"
  else
    installer_git -c "core.worktree=$destination" clone --quiet --template= --depth 1 --branch "$clone_ref" \
      "https://github.com/${OWNER}/${REPO}.git" "$destination" 2>"$error_file"
  fi
}

print_clone_error() {
  local error_file="$1"

  [ -s "$error_file" ] || return 0

  err "Git clone details:"
  while IFS= read -r line; do
    [ -n "$line" ] && err "  $line"
  done < <(sed -n '1,8p' "$error_file")
}

# Validate the offline transport before extracting anything. One top-level
# directory is stripped, matching GitHub repository archives. Links and special
# files cannot redirect extraction outside the private candidate directory.
validate_source_archive() {
  local archive="$1" member root="" component normalized line count=0 types=0 duplicates
  tar -tf "$archive" > "$TMP/archive.members" 2> "$TMP/archive.error" || return 1
  LC_ALL=C tar -tvf "$archive" > "$TMP/archive.types" 2>> "$TMP/archive.error" || return 1
  : > "$TMP/archive.paths" || return 1
  while IFS= read -r member; do
    count=$((count + 1))
    [[ -n "$member" && "$member" != /* && "$member" != *[[:cntrl:]]* &&
       "$member" != *\\* && "$member" != *:* ]] || return 1
    component="${member%%/*}"
    [[ -n "$component" && "$component" != .. && "$component" != -* ]] || return 1
    if [[ -z "$root" ]]; then root="$component"; fi
    [[ "$component" == "$root" ]] || return 1
    [[ "$member" == */* ]] || continue
    normalized="${member#*/}"; normalized="${normalized%/}"
    [[ -n "$normalized" ]] || continue
    [[ "$normalized" != -* ]] || return 1
    case "/$normalized/" in *'/../'*|*'/./'*|*'//'*) return 1 ;; esac
    printf '%s\n' "$normalized" >> "$TMP/archive.paths" || return 1
  done < "$TMP/archive.members"
  while IFS= read -r line; do
    case "${line:0:1}" in -|d) types=$((types + 1)) ;; *) return 1 ;; esac
  done < "$TMP/archive.types"
  ((count > 0 && count == types)) || return 1
  duplicates=$(LC_ALL=C sort "$TMP/archive.paths" | LC_ALL=C uniq -d) || return 1
  [[ -z "$duplicates" ]] || return 1
}

clone_or_update_repo() {
  ensure_repo_dir_available || return 1
  # Keep the candidate on the destination filesystem so activation/rollback
  # use directory renames, not recursive copies into the running installation.
  TMP=$(mktemp -d "$(dirname "$REPO_DIR")/.${REPO_DIR##*/}.install.XXXXXXXX") || return 1
  INSTALL_REPO_PREVIOUS="$TMP/previous-repo"
  if [[ -n "$OFFLINE_TARBALL" ]]; then
    if [[ ! -f "$OFFLINE_TARBALL" ]]; then
      err "Offline file not found: $OFFLINE_TARBALL"
      return 1
    fi
    # Freeze the supplied archive once. Listing and extraction must use the
    # same bytes, and a failed extraction must never be retried over its debris.
    cp -- "$OFFLINE_TARBALL" "$TMP/source.tar" || return 1
    if [[ -n "$OFFLINE_PUBKEY" ]]; then
      local signature="${OFFLINE_TARBALL}.minisig" verify_status=0
      command -v minisign >/dev/null 2>&1 || {
        err "Signed offline installation requires minisign"; return 3;
      }
      if [[ ! -f "$OFFLINE_PUBKEY" || ! -f "$signature" ]]; then
        err "Signed offline installation requires the trusted public key and $signature"
        return 7
      fi
      cp -- "$OFFLINE_PUBKEY" "$TMP/trusted.pub" || return 7
      cp -- "$signature" "$TMP/source.minisig" || return 7
      minisign -Vm "$TMP/source.tar" -p "$TMP/trusted.pub" -x "$TMP/source.minisig" \
        </dev/null >&2 || verify_status=$?
      if ((verify_status != 0)); then
        ((verify_status < 128)) || return "$verify_status"
        err "Offline archive signature verification failed"
        return 7
      fi
      ok "Verified the offline archive signature"
    fi
    if ! validate_source_archive "$TMP/source.tar"; then
      err "Offline archive is incomplete or contains unsafe source entries"
      return 1
    fi
    INSTALL_REPO_CANDIDATE="$TMP/candidate"
    mkdir -- "$INSTALL_REPO_CANDIDATE" || return 1
    if ! tar --no-same-owner --no-same-permissions -xf "$TMP/source.tar" \
         -C "$INSTALL_REPO_CANDIDATE" --strip-components=1 2> "$TMP/extract.error"; then
      err "Failed to extract tarball; the previous installation is unchanged"
      return 1
    fi
    ok "Staged offline source in $INSTALL_REPO_CANDIDATE"
    return 0
  fi

  info "Cloning dsr from ${OWNER}/${REPO}..."
  build_clone_refs
  local clone_ref clone_error attempt=0 last_clone_error="" status
  for clone_ref in "${CLONE_REFS[@]}"; do
    attempt=$((attempt + 1))
    INSTALL_REPO_CANDIDATE="$TMP/candidate-$attempt"
    clone_error="$TMP/git-clone-$attempt.err"
    last_clone_error="$clone_error"
    if run_with_spinner "Cloning repository ($clone_ref)..." \
      run_request "${DSR_INSTALLER_TIMEOUT:-300}" clone_repo_ref "$clone_ref" "$clone_error" "$INSTALL_REPO_CANDIDATE"; then
      ok "Staged dsr ($clone_ref) in $INSTALL_REPO_CANDIDATE"
      return 0
    else
      status=$?
    fi
    request_terminal_status "$status" && return "$status"
    if [ "$VERSION_EXPLICIT" -eq 0 ]; then
      break
    fi
  done

  if [ "$VERSION_EXPLICIT" -eq 1 ]; then
    err "Failed to clone dsr at requested version: $VERSION"
  else
    err "Failed to clone dsr from GitHub"
  fi
  print_clone_error "$last_clone_error"
  return 1
}

validate_repo() {
  local candidate="$INSTALL_REPO_CANDIDATE" version module size mod_count=0
  if [[ ! -d "$candidate" || -L "$candidate" || ! -f "$candidate/dsr" || -L "$candidate/dsr" ]]; then
    err "Cloned repo is missing dsr entry script"
    return 1
  fi

  if [[ ! -d "$candidate/src" || -L "$candidate/src" ]]; then
    err "Cloned repo is missing src/ module directory"
    return 1
  fi
  # These modules are required before any command can run. In particular,
  # config.sh imports platforms.sh even for --version and --help.
  for module in guardrails logging config platforms; do
    if [[ ! -s "$candidate/src/$module.sh" || -L "$candidate/src/$module.sh" ]]; then
      err "Cloned repo is missing required bootstrap module: $module.sh"
      return 1
    fi
  done

  if [[ "$(head -1 "$candidate/dsr")" != '#!/usr/bin/env bash' ]] || ! bash -n "$candidate/dsr"; then
    err "dsr entry script is not a valid bash script"
    return 1
  fi

  # Read the literal marker as data; never source a candidate to validate it.
  version=$(sed -n 's/^DSR_VERSION="\([^"]*\)"[[:space:]]*$/\1/p' "$candidate/dsr") || return 1
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
    err "dsr entry script is missing a valid DSR_VERSION marker"
    return 1
  fi
  if [ "$VERSION_EXPLICIT" -eq 1 ] && [[ "$VERSION" != main && "${VERSION#v}" != "$version" ]]; then
    err "Requested version $VERSION does not match staged dsr version $version"
    return 1
  fi
  for module in "$candidate"/src/*.sh; do
    [[ -e "$module" || -L "$module" ]] || continue
    if [[ ! -f "$module" || -L "$module" ]] || ! bash -n "$module"; then
      err "Invalid source module in staged checkout: ${module##*/}"
      return 1
    fi
    mod_count=$((mod_count + 1))
  done
  if ((mod_count == 0)); then
    err "Cloned repo has no shell modules in src/"
    return 1
  fi

  # Preserve the freshly checked-out file's stat identity when it already has
  # execute permission; a redundant chmod makes Git's next tag readback dirty.
  [[ -x "$candidate/dsr" ]] || chmod +x "$candidate/dsr" || return 1
  size=$(wc -c <"$candidate/dsr" | tr -d ' ') || return 1
  INSTALL_REPO_NEW_ID=$(install_path_identity "$candidate") || return 1
  if [ "$VERSION_EXPLICIT" -eq 0 ]; then VERSION="$version"; fi
  ok "Repo validation passed ($(( size / 1024 )) KB script, $mod_count modules)"
}

activate_source() {
  if [[ -n "$INSTALL_REPO_OLD_ID" ]]; then
    [[ ! -L "$REPO_DIR" && "$(install_path_identity "$REPO_DIR")" == "$INSTALL_REPO_OLD_ID" ]] || {
      err "Existing checkout changed during acquisition; refusing replacement"; return 1;
    }
  elif [[ -e "$REPO_DIR" || -L "$REPO_DIR" ]]; then
    err "A source checkout appeared during acquisition; refusing replacement"
    return 1
  fi
  # Set the recovery phase before either rename; a signal can arrive after a
  # successful rename but before the following shell assignment.
  INSTALL_REPO_SWITCH=1
  if [[ -n "$INSTALL_REPO_OLD_ID" ]]; then
    mv -- "$REPO_DIR" "$INSTALL_REPO_PREVIOUS" || return 1
  fi
  [[ ! -e "$REPO_DIR" && ! -L "$REPO_DIR" ]] || return 1
  mv -- "$INSTALL_REPO_CANDIDATE" "$REPO_DIR" || return 1
  [[ "$(install_path_identity "$REPO_DIR")" == "$INSTALL_REPO_NEW_ID" ]] || return 1
}

install_binary() {
  local link_target="$DEST/$BINARY_NAME"
  if [[ -L "$link_target" && "$(readlink "$link_target")" == "$REPO_DIR/dsr" ]]; then
    ok "Kept existing launcher $link_target"
    return 0
  fi
  [[ ! -d "$link_target" ]] || return 1
  INSTALL_LINK_STAGE=$(install_destination_command mktemp -d "$DEST/.dsr-launcher.XXXXXXXX") || return 1
  install_destination_command ln -s -- "$REPO_DIR/dsr" "$INSTALL_LINK_STAGE/candidate" || return 1
  INSTALL_LINK_NEW_ID=$(install_path_identity "$INSTALL_LINK_STAGE/candidate" destination) || return 1
  if [[ -e "$link_target" || -L "$link_target" ]]; then
    INSTALL_LINK_OLD_ID=$(install_path_identity "$link_target" destination) || return 1
  fi
  INSTALL_LINK_SWITCH=1
  if [[ -n "$INSTALL_LINK_OLD_ID" ]]; then
    install_destination_command mv -- "$link_target" "$INSTALL_LINK_STAGE/previous" || return 1
  fi
  [[ ! -e "$link_target" && ! -L "$link_target" ]] || return 1
  install_destination_command mv -- "$INSTALL_LINK_STAGE/candidate" "$link_target" || return 1
  [[ "$(install_path_identity "$link_target" destination)" == "$INSTALL_LINK_NEW_ID" ]] || return 1
  ok "Linked $link_target → $REPO_DIR/dsr"
}

# Move only entries still owned by this transaction. An unexpected replacement
# is retained untouched, and the previous version remains available for recovery.
rollback_installation() {
  local failed=0 current="" link_target="$DEST/$BINARY_NAME"
  if [ "$INSTALL_LINK_SWITCH" -eq 1 ]; then
    current=$(install_path_identity "$link_target" destination 2>/dev/null) || current=""
    if [[ -n "$INSTALL_LINK_NEW_ID" && "$current" == "$INSTALL_LINK_NEW_ID" ]]; then
      install_destination_command mv -- "$link_target" "$INSTALL_LINK_STAGE/uncommitted" || failed=1
    elif [[ -n "$current" && "$current" != "$INSTALL_LINK_OLD_ID" ]]; then
      err "Launcher changed outside this installation; recovery files remain at $INSTALL_LINK_STAGE"
      failed=1
    fi
    if [[ -n "$INSTALL_LINK_OLD_ID" ]] &&
       [[ "$(install_path_identity "$INSTALL_LINK_STAGE/previous" destination 2>/dev/null)" == "$INSTALL_LINK_OLD_ID" ]]; then
      if [[ ! -e "$link_target" && ! -L "$link_target" ]]; then
        install_destination_command mv -- "$INSTALL_LINK_STAGE/previous" "$link_target" || failed=1
      else
        failed=1
      fi
    fi
  fi
  if [ "$INSTALL_REPO_SWITCH" -eq 1 ]; then
    current=$(install_path_identity "$REPO_DIR" 2>/dev/null) || current=""
    if [[ "$current" == "$INSTALL_REPO_NEW_ID" ]]; then
      mv -- "$REPO_DIR" "$TMP/uncommitted-repo" || failed=1
    elif [[ -n "$current" && "$current" != "$INSTALL_REPO_OLD_ID" ]]; then
      err "Checkout changed outside this installation; previous source remains at $INSTALL_REPO_PREVIOUS"
      failed=1
    fi
    if [[ -n "$INSTALL_REPO_OLD_ID" ]] &&
       [[ "$(install_path_identity "$INSTALL_REPO_PREVIOUS" 2>/dev/null)" == "$INSTALL_REPO_OLD_ID" ]]; then
      if [[ ! -e "$REPO_DIR" && ! -L "$REPO_DIR" ]]; then
        mv -- "$INSTALL_REPO_PREVIOUS" "$REPO_DIR" || failed=1
      else
        failed=1
      fi
    fi
    if [ "$failed" -eq 0 ]; then warn "Restored the previous installation"; fi
  fi
  [ "$failed" -eq 0 ]
}

# ============================================================
# Uninstall
# ============================================================

do_uninstall() {
  local launcher="$DEST/$BINARY_NAME"
  if [[ ! -e "$launcher" && ! -L "$launcher" ]]; then
    info "No launcher installed at $launcher"
    return 0
  fi

  # install_binary publishes an absolute symlink to this exact checkout.
  # A shared source or skill directory can serve multiple destinations.
  if [[ ! -L "$launcher" || "$(readlink "$launcher")" != "$REPO_DIR/dsr" ]]; then
    err "Refusing to remove $launcher: it is not a launcher for $REPO_DIR/dsr"
    return 1
  fi

  INSTALL_LINK_OLD_ID=$(install_path_identity "$launcher" destination) || return 1
  INSTALL_LINK_STAGE=$(install_destination_command mktemp -d "$DEST/.dsr-launcher.XXXXXXXX") || return 1
  INSTALL_LINK_SWITCH=1
  install_destination_command mv -- "$launcher" "$INSTALL_LINK_STAGE/previous" || return 1
  [[ "$(install_path_identity "$INSTALL_LINK_STAGE/previous" destination)" == "$INSTALL_LINK_OLD_ID" ]] || {
    err "Launcher identity changed during uninstall; inspect $INSTALL_LINK_STAGE"
    return 1
  }
  INSTALL_COMMITTED=1
  ok "Uninstalled launcher $launcher"
  info "Source retained at $REPO_DIR. Agent skills and runtime data are preserved."
}

# ============================================================
# Dependency Checking
# ============================================================

check_dependencies() {
  info "Checking dependencies..."

  local missing_required=()
  local missing_optional=()

  # Required for dsr core
  command -v git >/dev/null 2>&1 || missing_required+=("git")
  command -v curl >/dev/null 2>&1 || missing_required+=("curl")

  # Strongly recommended
  command -v gh >/dev/null 2>&1 || missing_optional+=("gh (GitHub CLI — needed for releases)")
  command -v jq >/dev/null 2>&1 || missing_optional+=("jq (JSON processing — needed for --json output)")

  # Optional for build features
  command -v docker >/dev/null 2>&1 || missing_optional+=("docker (container builds via act)")
  command -v act >/dev/null 2>&1 || missing_optional+=("act (nektos/act — local GitHub Actions runner)")
  command -v minisign >/dev/null 2>&1 || missing_optional+=("minisign (artifact signing)")
  command -v syft >/dev/null 2>&1 || missing_optional+=("syft (SBOM generation)")

  if [ ${#missing_required[@]} -gt 0 ]; then
    err "Missing required dependencies:"
    for dep in "${missing_required[@]}"; do
      err "  • $dep"
    done
    exit 1
  fi

  if [ ${#missing_optional[@]} -gt 0 ] && [ "$QUIET" -eq 0 ]; then
    warn "Optional dependencies not found (some features will be limited):"
    for dep in "${missing_optional[@]}"; do
      warn "  • $dep"
    done
  fi

  ok "Core dependencies satisfied"
}

# ============================================================
# Config Directory Setup
# ============================================================

setup_config_dirs() {
  mkdir -p "$HOME/.config/dsr/repos.d" 2>/dev/null || true
  mkdir -p "$HOME/.local/state/dsr/logs" 2>/dev/null || true
  mkdir -p "$HOME/.cache/dsr" 2>/dev/null || true
  ok "Configuration directories created"
}

# ============================================================
# Agent Detection
# ============================================================

try_version() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || return 0
  if command -v timeout >/dev/null 2>&1; then
    timeout 1 "$cmd" --version 2>/dev/null | head -1 || true
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout 1 "$cmd" --version 2>/dev/null | head -1 || true
  else
    "$cmd" --version 2>/dev/null | head -1 || true
  fi
}

detect_agents() {
  DETECTED_AGENTS=()

  # shellcheck disable=SC2034  # versions reserved for summary display
  if [[ -d "$HOME/.claude" ]] || command -v claude &>/dev/null; then
    DETECTED_AGENTS+=("claude-code")
    CLAUDE_VERSION=$(try_version claude)
  fi

  # shellcheck disable=SC2034
  if [[ -d "$HOME/.codex" ]] || command -v codex &>/dev/null; then
    DETECTED_AGENTS+=("codex-cli")
    CODEX_VERSION=$(try_version codex)
  fi

  # shellcheck disable=SC2034
  if [[ -d "$HOME/.gemini" ]] || [[ -d "$HOME/.gemini-cli" ]] || command -v gemini &>/dev/null; then
    DETECTED_AGENTS+=("gemini-cli")
    GEMINI_VERSION=$(try_version gemini)
  fi
}

print_detected_agents() {
  local count=${#DETECTED_AGENTS[@]}
  [[ $count -eq 0 ]] && { info "No AI coding agents detected"; return; }

  local plural=""
  [[ $count -gt 1 ]] && plural="s"

  if [ "$HAS_GUM" -eq 1 ] && [ "$NO_GUM" -eq 0 ]; then
    gum style --foreground 39 --bold "Detected AI Coding Agent${plural}:"
    for agent in "${DETECTED_AGENTS[@]}"; do
      gum style --foreground 42 "  ✓ ${agent}"
    done
  else
    echo -e "\033[1;34mDetected AI Coding Agent${plural}:\033[0m"
    for agent in "${DETECTED_AGENTS[@]}"; do
      echo -e "  \033[0;32m✓\033[0m ${agent}"
    done
  fi
}

# ============================================================
# Skill Installation
# ============================================================

install_skill() {
  local dest_dir="$1"
  local agent_name="$2"
  local local_skill_path=""
  local skill_md_url="${GITHUB_RAW}/main/SKILL.md"
  local script_dir status=0

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  mkdir -p "$dest_dir" 2>/dev/null || {
    warn "Cannot create skill directory: $dest_dir"
    return 1
  }

  if [[ -f "$REPO_DIR/SKILL.md" ]]; then
    local_skill_path="$REPO_DIR/SKILL.md"
  elif [[ -f "${script_dir}/SKILL.md" ]]; then
    local_skill_path="${script_dir}/SKILL.md"
  fi

  if [[ -n "$local_skill_path" ]] && cp "$local_skill_path" "$dest_dir/SKILL.md"; then
    ok "Installed dsr skill for $agent_name (from local repository source)"
    return 0
  fi

  # Secondary: download SKILL.md directly from repo
  if [[ -z "$OFFLINE_TARBALL" ]]; then
    http_request -fsSL "$skill_md_url" || status=$?
    request_terminal_status "$status" && return "$status"
    if ((status == 0)) && cp -- "$INSTALL_REQUEST_DIR/body" "$dest_dir/SKILL.md"; then
      ok "Installed dsr skill for $agent_name (from repo)"
      return 0
    fi
  fi

  # Tertiary: download skill tarball from releases (requires TMP dir)
  local skill_url="https://github.com/${OWNER}/${REPO}/releases/latest/download/skill.tar.gz"
  if [[ -z "$OFFLINE_TARBALL" && -n "$TMP" ]]; then
    status=0
    http_request -fsSL "$skill_url" || status=$?
    request_terminal_status "$status" && return "$status"
    if ((status == 0)) && tar -xzf "$INSTALL_REQUEST_DIR/body" -C "$dest_dir" 2>/dev/null; then
      ok "Installed dsr skill for $agent_name (from release)"
      return 0
    fi
  fi

  # Final fallback: inline skill
  info "Creating minimal skill for $agent_name (network download failed)..."
  cat >"$dest_dir/SKILL.md" <<'SKILL_EOF'
---
name: dsr
description: >-
  Doodlestein Self-Releaser - fallback release infrastructure for when GitHub
  Actions is throttled. Local builds, cross-platform releases, supply chain
  security. Use when: GH Actions slow, local release, build hosts, dsr command.
---

# dsr - Doodlestein Self-Releaser

Fallback release infrastructure for when GitHub Actions is throttled (>10 min queue time).

## Core Commands

```bash
dsr check <repo>              # Check if GH Actions is throttled
dsr check --all               # Check all configured repos
dsr build <tool>              # Build locally for all targets
dsr release <tool> <version>  # Upload artifacts to GitHub
dsr fallback <tool> <version> # Full pipeline: check -> build -> release
dsr doctor                    # System diagnostics
dsr doctor --fix              # Suggest and apply fixes
dsr health all                # Check all build hosts
dsr status                    # System and last run summary
dsr prune                     # Clean old artifacts/logs safely
```

## Configuration

```bash
dsr config init               # Initialize configuration
dsr config show               # Show current configuration
dsr repos list                # List registered repos
dsr repos add <repo>          # Add a repository
```

## Supply Chain Security

```bash
dsr signing init              # Generate minisign keypair
dsr signing sign <file>       # Sign artifact
dsr sbom <project>            # Generate SBOM
dsr slsa generate <artifact>  # Generate SLSA provenance
dsr quality <tool>            # Pre-release quality checks
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Partial failure |
| 3 | Missing dependency |
| 4 | Invalid arguments |
| 6 | Build failed |
| 7 | Release failed |
| 8 | Network error |

## Common Workflows

### Release When GH Actions is Throttled
```bash
dsr check --all
dsr build ntm --version 1.5.2
dsr release ntm 1.5.2
# Or full pipeline:
dsr fallback ntm 1.5.2
```

### Health Check
```bash
dsr doctor
dsr health all
```

### JSON Output
All commands support `--json` for machine-readable output:
```bash
dsr check ntm --json | jq '.status'
dsr health all --json | jq '.hosts[] | select(.status == "unhealthy")'
```
SKILL_EOF

  ok "Installed minimal dsr skill for $agent_name"
}

# ============================================================
# Agent Configuration (Skills Only — dsr has no hooks)
# ============================================================

configure_agents() {
  if [ "$NO_CONFIGURE" -eq 1 ]; then
    info "Agent configuration skipped (--no-configure)"
    return 0
  fi

  info "Scanning for AI coding agents..."
  detect_agents
  print_detected_agents

  local count=${#DETECTED_AGENTS[@]} status
  [[ $count -eq 0 ]] && return 0

  for agent in "${DETECTED_AGENTS[@]}"; do
    case "$agent" in
      claude-code)
        local claude_skill_dir="$HOME/.claude/skills/dsr"
        if [ -d "$claude_skill_dir" ] && [ -f "$claude_skill_dir/SKILL.md" ]; then
          CLAUDE_STATUS="already"
          ok "Claude Code skill already installed"
        else
          if install_skill "$claude_skill_dir" "Claude Code"; then
            CLAUDE_STATUS="created"
          else
            status=$?
            request_terminal_status "$status" && return "$status"
            CLAUDE_STATUS="failed"
          fi
        fi
        ;;
      codex-cli)
        local codex_skill_dir="$HOME/.codex/skills/dsr"
        if [ -d "$codex_skill_dir" ] && [ -f "$codex_skill_dir/SKILL.md" ]; then
          CODEX_STATUS="already"
          ok "Codex CLI skill already installed"
        else
          if install_skill "$codex_skill_dir" "Codex CLI"; then
            CODEX_STATUS="created"
          else
            status=$?
            request_terminal_status "$status" && return "$status"
            CODEX_STATUS="failed"
          fi
        fi
        ;;
      gemini-cli)
        GEMINI_STATUS="manual"
        info "Gemini CLI: detected; no automatic skill setup"
        ;;
    esac
  done
}

# ============================================================
# PATH Setup
# ============================================================

maybe_add_path() {
  case ":$PATH:" in
    *":$DEST:"*)
      return 0 ;; # Already in PATH
  esac

  if [ "$EASY" -eq 1 ]; then
    local path_line="export PATH=\"$DEST:\$PATH\""
    for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
      if [ -f "$rc" ] && [ -w "$rc" ]; then
        if ! grep -qF "$DEST" "$rc" 2>/dev/null; then
          { echo ""; echo "# Added by dsr installer"; echo "$path_line"; } >>"$rc"
          ok "Added $DEST to PATH in $(basename "$rc")"
        fi
      fi
    done
    export PATH="$DEST:$PATH"
  else
    warn "$DEST is not in your PATH"
    info "Add to your shell profile:  export PATH=\"$DEST:\$PATH\""
    info "Or re-run with --easy-mode to auto-configure"
  fi
}

# ============================================================
# Post-Install Diagnostics
# ============================================================

run_doctor() {
  local dsr_bin="$DEST/$BINARY_NAME" status=0
  if [[ ! -x "$dsr_bin" ]]; then
    err "Cannot run diagnostics: $dsr_bin is not executable"
    return 1
  fi
  info "Running dsr doctor through $dsr_bin"
  run_request "${DSR_INSTALLER_TIMEOUT:-30}" "$dsr_bin" doctor >&2 || status=$?
  if ((status != 0)); then warn "dsr doctor exited with status $status"; fi
  return "$status"
}

# ============================================================
# Final Summary
# ============================================================

show_summary() {
  [ "$QUIET" -eq 1 ] && return 0

  local summary_lines=()

  # Version info
  local installed_version
  if [ -x "$DEST/$BINARY_NAME" ]; then
    installed_version=$("$DEST/$BINARY_NAME" --version 2>/dev/null | head -1 || echo "$VERSION")
  else
    installed_version="${VERSION:-unknown}"
  fi
  summary_lines+=("Version:  $installed_version")
  summary_lines+=("Managed paths:")
  summary_lines+=("  Binary: $(status_path "$DEST/$BINARY_NAME")")
  summary_lines+=("  Repo:   $(status_path "$REPO_DIR")")
  summary_lines+=("")

  # Agent status
  if [ -n "$CLAUDE_STATUS" ]; then
    case "$CLAUDE_STATUS" in
      created) summary_lines+=("Claude Code: Skill installed") ;;
      already) summary_lines+=("Claude Code: Skill already present") ;;
      failed)  summary_lines+=("Claude Code: Skill installation failed") ;;
    esac
  fi
  if [ -n "$CODEX_STATUS" ]; then
    case "$CODEX_STATUS" in
      created) summary_lines+=("Codex CLI:   Skill installed") ;;
      already) summary_lines+=("Codex CLI:   Skill already present") ;;
      failed)  summary_lines+=("Codex CLI:   Skill installation failed") ;;
    esac
  fi
  if [ -n "$GEMINI_STATUS" ]; then
    case "$GEMINI_STATUS" in
      manual) summary_lines+=("Gemini CLI:  Detected; no automatic skill setup") ;;
    esac
  fi

  summary_lines+=("")
  summary_lines+=("Get started:  dsr doctor")
  summary_lines+=("Quick check:  dsr check --all")

  echo ""
  if [ "$HAS_GUM" -eq 1 ] && [ "$NO_GUM" -eq 0 ]; then
    {
      gum style --foreground 42 --bold "dsr is ready!"
      echo ""
      for line in "${summary_lines[@]}"; do
        if [ -n "$line" ]; then
          gum style --foreground 245 "  $line"
        else
          echo ""
        fi
      done
    } | gum style --border normal --border-foreground 42 --padding "1 2"
  else
    draw_box "0;32" \
      "\033[1;32mdsr is ready!\033[0m" \
      "" \
      "${summary_lines[@]}"
  fi

}

# ============================================================
# Main
# ============================================================

main() {
  validate_request_timeout || return $?
  if [[ -n "$OFFLINE_PUBKEY" && ( -z "$OFFLINE_TARBALL" || "$UNINSTALL" == 1 ) ]]; then
    err "--offline-pubkey requires --offline FILE for an installation"
    return 4
  fi
  show_header

  # Cover metadata discovery too: cancellation must own requests even before
  # the installation lock and source transaction have been created.
  trap cleanup EXIT
  trap 'installer_signal 129' HUP
  trap 'installer_signal 130' INT
  trap 'installer_signal 143' TERM

  if ((UNINSTALL)); then
    prepare_install_paths
    acquire_lock
    do_uninstall
    return
  fi

  # Platform + proxy
  detect_platform
  setup_proxy
  prepare_install_paths

  # Version
  resolve_version
  info "Target version: ${VERSION:-latest}"

  # Recovery was armed before acquiring ownership or performing any rename.
  acquire_lock

  # Check the selected installation under the writer lock.
  check_existing_install
  preflight_checks
  check_dependencies

  # Acquire and validate a complete replacement without modifying live source.
  clone_or_update_repo
  validate_repo

  # Keep both previous entries until the source and launcher are installed.
  activate_source
  install_binary
  setup_config_dirs
  if ((VERIFY)); then run_doctor || return $?; fi
  INSTALL_COMMITTED=1

  # Agent detection + skill installation
  local status=0
  configure_agents || status=$?
  request_terminal_status "$status" && return "$status"
  ((status == 0)) || warn "Agent configuration did not complete; dsr is installed"

  # PATH setup
  maybe_add_path || warn "PATH configuration did not complete; dsr is installed at $DEST/$BINARY_NAME"

  if ((EASY && ! VERIFY)); then
    run_doctor || warn "Post-install diagnostics did not complete; dsr is installed"
  fi

  # Summary
  show_summary
}

main "$@"
