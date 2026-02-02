#!/usr/bin/env bash
# install.sh - Install mock_release_tool
#
# Usage:
#   ./install.sh --version v0.0.1
#   ./install.sh --version v0.0.1 --dir /tmp/bin
#
# Environment overrides:
#   MOCK_RELEASE_REPO=owner/repo
#   MOCK_RELEASE_CACHE_DIR=/tmp/cache

set -uo pipefail

TOOL_NAME="mock_release_tool"
REPO="${MOCK_RELEASE_REPO:-example/mock_release_tool}"
INSTALL_DIR="${HOME}/.local/bin"
CACHE_DIR="${MOCK_RELEASE_CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/dsr/installers}"
VERSION=""
JSON_MODE=false
VERBOSE=0

usage() {
  cat << 'USAGE'
Usage:
  install.sh --version <tag>
  install.sh --version <tag> --dir <path>

Options:
  -v, --version <tag>   Release tag (required)
  -d, --dir <path>      Install directory (default: ~/.local/bin)
  --json                Emit JSON status
  --verbose             Verbose output
  -h, --help             Show help
USAGE
}

_json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

log() {
  local level="$1"
  shift
  local msg="$*"
  if $JSON_MODE; then
    local esc_level esc_msg
    esc_level=$(_json_escape "$level")
    esc_msg=$(_json_escape "$msg")
    printf '{\"tool\":\"%s\",\"level\":\"%s\",\"msg\":\"%s\"}\n' "$TOOL_NAME" "$esc_level" "$esc_msg"
  else
    echo "[install] $msg" >&2
  fi
}

fail() {
  log "ERROR" "$*"
  exit 1
}

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--version)
      VERSION="$2"
      shift 2
      ;;
    -d|--dir)
      INSTALL_DIR="$2"
      shift 2
      ;;
    --json)
      JSON_MODE=true
      shift
      ;;
    --verbose)
      VERBOSE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  fail "--version is required"
fi

# Detect platform
os=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$os" in
  darwin) os="darwin" ;;
  linux) os="linux" ;;
  mingw*|msys*|cygwin*) os="windows" ;;
  *) fail "Unsupported OS: $os" ;;
esac

arch=$(uname -m)
case "$arch" in
  x86_64|amd64) arch="amd64" ;;
  aarch64|arm64) arch="arm64" ;;
  *) fail "Unsupported arch: $arch" ;;
esac

ext="tar.gz"
if [[ "$os" == "windows" ]]; then
  ext="zip"
fi

TARGET="${os}-${arch}"
EXT="$ext"
TAR="${TOOL_NAME}-${TARGET}.${EXT}"

version_tag="$VERSION"
asset_compat="$TAR"
asset_versioned="${TOOL_NAME}-${version_tag}-${os}-${arch}.${ext}"

mkdir -p "$INSTALL_DIR" "$CACHE_DIR"

# Download helper
_download() {
  local url="$1"
  local dest="$2"
  if command -v curl &>/dev/null; then
    curl -fsSL "$url" -o "$dest"
  elif command -v wget &>/dev/null; then
    wget -qO "$dest" "$url"
  else
    return 1
  fi
}

# Try compat asset first, then versioned
base_url="https://github.com/${REPO}/releases/download/${version_tag}"
archive_path="$CACHE_DIR/$asset_compat"
if ! _download "${base_url}/${asset_compat}" "$archive_path"; then
  archive_path="$CACHE_DIR/$asset_versioned"
  if ! _download "${base_url}/${asset_versioned}" "$archive_path"; then
    fail "Failed to download $asset_compat or $asset_versioned"
  fi
fi

if [[ "$VERBOSE" == "1" ]]; then
  log "INFO" "Downloaded $(basename "$archive_path")"
fi

# Extract
tmp_dir="$(mktemp -d)"
if [[ "$ext" == "tar.gz" ]]; then
  tar -xzf "$archive_path" -C "$tmp_dir"
else
  if ! command -v unzip &>/dev/null; then
    fail "unzip required for zip archives"
  fi
  unzip -q "$archive_path" -d "$tmp_dir"
fi

# Install binary
if [[ -f "$tmp_dir/$TOOL_NAME" ]]; then
  install -m 0755 "$tmp_dir/$TOOL_NAME" "$INSTALL_DIR/$TOOL_NAME"
elif [[ -f "$tmp_dir/${TOOL_NAME}.exe" ]]; then
  install -m 0755 "$tmp_dir/${TOOL_NAME}.exe" "$INSTALL_DIR/$TOOL_NAME"
else
  fail "Binary not found in archive"
fi

log "INFO" "Installed $TOOL_NAME to $INSTALL_DIR/$TOOL_NAME"

# Verify
"$INSTALL_DIR/$TOOL_NAME" >/dev/null 2>&1 || fail "Installed binary did not run"
log "INFO" "Binary verification passed"

exit 0
