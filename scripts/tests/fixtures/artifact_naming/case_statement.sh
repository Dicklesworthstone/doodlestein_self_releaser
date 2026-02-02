#!/usr/bin/env bash
# Install.sh fixture with case statement patterns
set -euo pipefail

VERSION="${VERSION:-latest}"
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

case "${ARCH}" in
    x86_64|amd64) ARCH="amd64" ;;
    arm64|aarch64) ARCH="arm64" ;;
esac

# Main pattern using TARGET
TARGET="${OS}-${ARCH}"
TAR="casetool-${TARGET}.tar.gz"

URL="https://github.com/example/casetool/releases/download/${VERSION}/${TAR}"
curl -fsSL "$URL" -o "$TAR"
