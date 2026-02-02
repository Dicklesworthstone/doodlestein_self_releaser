#!/usr/bin/env bash
# Install.sh fixture matching CASS pattern
set -euo pipefail

VERSION="${VERSION:-}"
OWNER="Dicklesworthstone"
REPO="coding_agent_session_search"
DEST="${DEST:-$HOME/.local/bin}"

OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
case "$ARCH" in
  x86_64|amd64) ARCH="amd64" ;;
  arm64|aarch64) ARCH="arm64" ;;
esac

TARGET="${OS}-${ARCH}"
EXT="tar.gz"

TAR="cass-${TARGET}.${EXT}"
URL="https://github.com/${OWNER}/${REPO}/releases/download/${VERSION}/${TAR}"

curl -fsSL "$URL" -o "/tmp/$TAR"
