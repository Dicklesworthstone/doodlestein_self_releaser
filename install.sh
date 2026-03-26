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
#   --verify           Run self-test after install
#   --quiet            Suppress non-error output
#   --no-gum           Disable gum formatting even if available
#   --no-configure     Skip AI agent skill installation
#   --no-verify        Reserved for future checksum verification
#   --offline TARBALL  Install from pre-downloaded repo tarball
#   --repo-dir DIR     Clone repo to DIR (default: ~/.local/share/dsr)
#   --force            Reinstall even if same version exists
#   --uninstall        Remove dsr and associated files
#   -h, --help         Show this help
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
INSTALLER_VERSION="0.1.0"
GITHUB_RAW="https://raw.githubusercontent.com/${OWNER}/${REPO}"

DEST="${DSR_DEST:-$HOME/.local/bin}"
VERSION=""
QUIET=0
NO_GUM=0
NO_CONFIGURE=0
FORCE_INSTALL=0
EASY=0
VERIFY=0
SYSTEM=0
UNINSTALL=0
OFFLINE_TARBALL=""

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
  --verify           Run self-test after install
  --quiet            Suppress non-error output
  --no-gum           Disable gum formatting even if available
  --no-configure     Skip AI agent skill installation
  --no-verify        Reserved for future checksum verification
  --offline FILE     Install from pre-downloaded repo tarball
  --repo-dir DIR     Clone repo to DIR (default: ~/.local/share/dsr)
  --force            Reinstall even if same version exists
  --uninstall        Remove dsr and associated files
  -h, --help         Show this help

Environment:
  DSR_DEST           Override install directory (default: ~/.local/bin)
  DSR_REPO_DIR       Override repo clone directory (default: ~/.local/share/dsr)
  HTTPS_PROXY        Proxy for HTTPS connections
  HTTP_PROXY         Proxy for HTTP connections
EOF
}

# ============================================================
# Argument Parsing
# ============================================================

while [ $# -gt 0 ]; do
  case "$1" in
    --version)       VERSION="$2"; shift 2 ;;
    --dest)          DEST="$2"; shift 2 ;;
    --system)        SYSTEM=1; DEST="/usr/local/bin"; shift ;;
    --easy-mode)     EASY=1; shift ;;
    --verify)        VERIFY=1; shift ;;
    --quiet|-q)      QUIET=1; shift ;;
    --no-gum)        NO_GUM=1; shift ;;
    --no-configure)  NO_CONFIGURE=1; shift ;;
    --no-verify)     shift ;;  # reserved for future checksum verification
    --offline)       OFFLINE_TARBALL="$2"; shift 2 ;;
    --repo-dir)      REPO_DIR="$2"; shift 2 ;;
    --force)         FORCE_INSTALL=1; shift ;;
    --uninstall)     UNINSTALL=1; shift ;;
    -h|--help)       usage; exit 0 ;;
    *)               shift ;;
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
  if [ "$HAS_GUM" -eq 1 ] && [ "$NO_GUM" -eq 0 ] && [ "$QUIET" -eq 0 ]; then
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

# ============================================================
# Version Resolution
# ============================================================

resolve_version() {
  # 1. CLI flag
  [[ -n "$VERSION" ]] && return 0

  # 2. GitHub API (latest release tag, if releases exist)
  VERSION=$(curl -fsSL --connect-timeout 5 "${PROXY_ARGS[@]}" \
    "https://api.github.com/repos/${OWNER}/${REPO}/releases/latest" 2>/dev/null \
    | grep '"tag_name":' | sed -E 's/.*"v?([^"]+)".*/\1/' || true)
  [[ -n "$VERSION" ]] && return 0

  # 3. Redirect URL parsing (fallback when API rate-limited)
  VERSION=$(curl -fsSL -o /dev/null -w '%{url_effective}' "${PROXY_ARGS[@]}" \
    "https://github.com/${OWNER}/${REPO}/releases/latest" 2>/dev/null \
    | sed -E 's|.*/tag/v?||' || true)
  # Reject HTML page (GitHub returns /releases if no releases exist)
  if [[ "$VERSION" == *"releases"* ]] || [[ -z "$VERSION" ]]; then
    VERSION=""
  fi
  [[ -n "$VERSION" ]] && return 0

  # 4. Parse from raw dsr script header on GitHub
  VERSION=$(curl -fsSL --connect-timeout 5 "${PROXY_ARGS[@]}" \
    "${GITHUB_RAW}/main/dsr" 2>/dev/null \
    | grep -m1 'DSR_VERSION=' | sed -E 's/.*"([^"]+)".*/\1/' || true)
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

check_existing_install() {
  if command -v dsr >/dev/null 2>&1; then
    local current
    current=$(dsr --version 2>/dev/null | head -1 || echo "unknown")
    if [ "$FORCE_INSTALL" -eq 0 ] && [[ "$current" == *"$VERSION"* ]] && [[ -n "$VERSION" ]]; then
      ok "dsr $VERSION is already installed"
      info "Use --force to reinstall"
      # Still run agent configuration (idempotent)
      if [ "$NO_CONFIGURE" -eq 0 ]; then
        configure_agents
      fi
      show_summary
      exit 0
    fi
    info "Existing dsr found: $current"
  fi
}

check_network() {
  if [[ -n "$OFFLINE_TARBALL" ]]; then
    return 0
  fi
  if ! curl -fsSL --connect-timeout 3 "${PROXY_ARGS[@]}" \
    "https://github.com/${OWNER}/${REPO}" -o /dev/null 2>/dev/null; then
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
    check_network
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
  rm -rf "$TMP" 2>/dev/null || true
  if [ "$LOCKED" -eq 1 ]; then
    rm -rf "${LOCK_FILE}.d" 2>/dev/null || true
  fi
}

acquire_lock() {
  LOCK_DIR="${LOCK_FILE}.d"
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    LOCKED=1
    echo $$ >"$LOCK_DIR/pid"
  else
    # Check for stale lock
    if [ -f "$LOCK_DIR/pid" ]; then
      local old_pid
      old_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || echo "")
      if [ -n "$old_pid" ] && ! kill -0 "$old_pid" 2>/dev/null; then
        rm -rf "$LOCK_DIR"
        if mkdir "$LOCK_DIR" 2>/dev/null; then
          LOCKED=1
          echo $$ >"$LOCK_DIR/pid"
        fi
      fi
    fi
    if [ "$LOCKED" -eq 0 ]; then
      err "Another dsr installer is running (lock: $LOCK_DIR)"
      exit 1
    fi
  fi
}

# ============================================================
# Download + Install
# ============================================================
# dsr is a modular bash project (dsr + src/*.sh modules).
# It must be cloned as a full repo, then symlinked into PATH.

REPO_DIR="${REPO_DIR:-${DSR_REPO_DIR:-$HOME/.local/share/dsr}}"

clone_or_update_repo() {
  if [[ -n "$OFFLINE_TARBALL" ]]; then
    # Offline mode: tarball contains the full repo tree
    if [ ! -f "$OFFLINE_TARBALL" ]; then
      err "Offline file not found: $OFFLINE_TARBALL"
      exit 1
    fi
    mkdir -p "$REPO_DIR"
    tar -xf "$OFFLINE_TARBALL" -C "$REPO_DIR" --strip-components=1 2>/dev/null \
      || tar -xzf "$OFFLINE_TARBALL" -C "$REPO_DIR" --strip-components=1 2>/dev/null \
      || { err "Failed to extract tarball"; exit 1; }
    ok "Extracted offline tarball to $REPO_DIR"
    return 0
  fi

  if [ -d "$REPO_DIR/.git" ]; then
    # Existing clone: pull latest
    info "Updating existing dsr installation..."
    if (cd "$REPO_DIR" && git pull --ff-only 2>/dev/null); then
      ok "Updated dsr to latest"
      return 0
    fi
    # Pull failed (dirty state, etc.) — re-clone
    warn "git pull failed; performing fresh clone..."
    local backup
    backup="${REPO_DIR}.bak.$(date +%Y%m%d%H%M%S)"
    mv "$REPO_DIR" "$backup" 2>/dev/null || rm -rf "$REPO_DIR"
  fi

  # Fresh clone
  mkdir -p "$(dirname "$REPO_DIR")"
  info "Cloning dsr from ${OWNER}/${REPO}..."

  local clone_ref="main"
  if [[ -n "$VERSION" ]] && [[ "$VERSION" != "$INSTALLER_VERSION" ]]; then
    clone_ref="v${VERSION}"
  fi

  if run_with_spinner "Cloning repository..." \
    git clone --depth 1 --branch "$clone_ref" \
      "https://github.com/${OWNER}/${REPO}.git" "$REPO_DIR" 2>/dev/null; then
    ok "Cloned dsr ($clone_ref) to $REPO_DIR"
    return 0
  fi

  # Fallback: clone main if tag didn't exist
  if [[ "$clone_ref" != "main" ]]; then
    if run_with_spinner "Cloning repository (main)..." \
      git clone --depth 1 "https://github.com/${OWNER}/${REPO}.git" "$REPO_DIR" 2>/dev/null; then
      ok "Cloned dsr (main) to $REPO_DIR"
      return 0
    fi
  fi

  err "Failed to clone dsr from GitHub"
  exit 1
}

validate_repo() {
  # Verify the cloned repo has required structure
  if [ ! -f "$REPO_DIR/dsr" ]; then
    err "Cloned repo is missing dsr entry script"
    exit 1
  fi

  if [ ! -d "$REPO_DIR/src" ]; then
    err "Cloned repo is missing src/ module directory"
    exit 1
  fi

  # Must be a bash script
  if ! head -1 "$REPO_DIR/dsr" | grep -q '#!/usr/bin/env bash'; then
    err "dsr entry script is not a valid bash script"
    exit 1
  fi

  # Must contain DSR_VERSION
  if ! grep -q 'DSR_VERSION=' "$REPO_DIR/dsr"; then
    err "dsr entry script is missing DSR_VERSION marker"
    exit 1
  fi

  # Ensure executable
  chmod +x "$REPO_DIR/dsr"

  local size
  size=$(wc -c <"$REPO_DIR/dsr" | tr -d ' ')
  local mod_count
  mod_count=$(find "$REPO_DIR/src" -name '*.sh' -type f 2>/dev/null | wc -l | tr -d ' ')

  ok "Repo validation passed ($(( size / 1024 )) KB script, $mod_count modules)"
}

install_binary() {
  mkdir -p "$DEST" 2>/dev/null || true

  local link_target="$DEST/$BINARY_NAME"

  # Remove existing file/link
  if [ -e "$link_target" ] || [ -L "$link_target" ]; then
    if [ "$SYSTEM" -eq 1 ]; then
      sudo rm -f "$link_target"
    else
      rm -f "$link_target"
    fi
  fi

  # Create symlink from DEST to the repo
  if [ "$SYSTEM" -eq 1 ]; then
    sudo ln -sf "$REPO_DIR/dsr" "$link_target"
  else
    ln -sf "$REPO_DIR/dsr" "$link_target"
  fi

  ok "Linked $link_target → $REPO_DIR/dsr"
}

# ============================================================
# Uninstall
# ============================================================

do_uninstall() {
  show_header
  info "Uninstalling dsr..."

  local found=0

  # Remove binary/symlink
  for path in "$HOME/.local/bin/dsr" "/usr/local/bin/dsr"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      if [ -w "$(dirname "$path")" ]; then
        rm -f "$path"
        ok "Removed $path"
      else
        sudo rm -f "$path"
        ok "Removed $path (sudo)"
      fi
      found=1
    fi
  done

  # Remove repo clone
  local repo_dir="${DSR_REPO_DIR:-$HOME/.local/share/dsr}"
  if [ -d "$repo_dir" ]; then
    rm -rf "$repo_dir"
    ok "Removed repo: $repo_dir"
    found=1
  fi

  # Remove skill directories
  for skill_dir in "$HOME/.claude/skills/dsr" "$HOME/.codex/skills/dsr"; do
    if [ -d "$skill_dir" ]; then
      rm -rf "$skill_dir"
      ok "Removed skill directory: $skill_dir"
      found=1
    fi
  done

  if [ "$found" -eq 0 ]; then
    warn "dsr does not appear to be installed"
  else
    ok "dsr uninstalled"
    echo ""
    info "Config directories preserved (remove manually if desired):"
    info "  ~/.config/dsr/"
    info "  ~/.local/state/dsr/"
    info "  ~/.cache/dsr/"
  fi

  exit 0
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
  local script_dir

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  mkdir -p "$dest_dir" 2>/dev/null || {
    warn "Cannot create skill directory: $dest_dir"
    return 1
  }

  if [[ -f "${script_dir}/SKILL.md" ]]; then
    local_skill_path="${script_dir}/SKILL.md"
  fi

  if [[ -n "$local_skill_path" ]] && cp "$local_skill_path" "$dest_dir/SKILL.md"; then
    ok "Installed dsr skill for $agent_name (from local repository source)"
    return 0
  fi

  # Secondary: download SKILL.md directly from repo
  if curl -fsSL "${PROXY_ARGS[@]}" "$skill_md_url" -o "$dest_dir/SKILL.md" 2>/dev/null; then
    ok "Installed dsr skill for $agent_name (from repo)"
    return 0
  fi

  # Tertiary: download skill tarball from releases (requires TMP dir)
  local skill_url="https://github.com/${OWNER}/${REPO}/releases/latest/download/skill.tar.gz"
  if [[ -n "$TMP" ]] && curl -fsSL "${PROXY_ARGS[@]}" "$skill_url" -o "$TMP/skill.tar.gz" 2>/dev/null; then
    if tar -xzf "$TMP/skill.tar.gz" -C "$dest_dir" 2>/dev/null; then
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

  local count=${#DETECTED_AGENTS[@]}
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
            CODEX_STATUS="failed"
          fi
        fi
        ;;
      gemini-cli)
        GEMINI_STATUS="skipped"
        info "Gemini CLI: skill installation not yet supported"
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
  if [ "$VERIFY" -eq 0 ] && [ "$EASY" -eq 0 ]; then
    return 0
  fi

  local dsr_bin="$DEST/$BINARY_NAME"
  if [ ! -x "$dsr_bin" ]; then
    warn "Cannot run diagnostics: $dsr_bin not found"
    return 1
  fi

  info "Running post-install diagnostics..."
  echo ""

  if command -v timeout >/dev/null 2>&1; then
    timeout 30 "$dsr_bin" doctor 2>&1 || true
  else
    "$dsr_bin" doctor 2>&1 || true
  fi

  echo ""
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
  summary_lines+=("Binary:   $DEST/$BINARY_NAME")
  summary_lines+=("Repo:     $REPO_DIR")
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
      skipped) summary_lines+=("Gemini CLI:  Skill not yet supported") ;;
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

  # Uninstall instructions
  echo ""
  if [ "$HAS_GUM" -eq 1 ] && [ "$NO_GUM" -eq 0 ]; then
    gum style --foreground 245 --italic "To uninstall: bash install.sh --uninstall"
    gum style --foreground 245 --italic "              or: rm $DEST/$BINARY_NAME"
  else
    echo -e "\033[0;90mTo uninstall: bash install.sh --uninstall\033[0m"
    echo -e "\033[0;90m              or: rm $DEST/$BINARY_NAME\033[0m"
  fi
}

# ============================================================
# Main
# ============================================================

main() {
  # Handle uninstall early
  if [ "$UNINSTALL" -eq 1 ]; then
    do_uninstall
  fi

  show_header

  # Platform + proxy
  detect_platform
  setup_proxy

  # Version
  resolve_version
  info "Target version: ${VERSION:-latest}"

  # Preflight
  preflight_checks

  # Check existing install (may exit early if up-to-date)
  check_existing_install

  # Acquire lock
  acquire_lock

  # Create temp directory and set cleanup trap
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/dsr-install.XXXXXX")
  trap cleanup EXIT

  # Clone or update the repo
  clone_or_update_repo

  # Validate repo structure
  validate_repo

  # Install symlink
  install_binary

  # Check dependencies
  check_dependencies

  # Setup config directories
  setup_config_dirs

  # Agent detection + skill installation
  configure_agents

  # PATH setup
  maybe_add_path

  # Post-install diagnostics
  run_doctor

  # Summary
  show_summary
}

main "$@"
