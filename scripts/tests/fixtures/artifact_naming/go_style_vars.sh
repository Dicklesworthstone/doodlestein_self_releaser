#!/usr/bin/env bash
# Install.sh fixture with Go-style GOOS/GOARCH variables
set -euo pipefail

VERSION="${VERSION:-latest}"
GOOS=$(uname -s | tr '[:upper:]' '[:lower:]')
GOARCH=$(uname -m)

case "${GOARCH}" in
    x86_64) GOARCH="amd64" ;;
    aarch64) GOARCH="arm64" ;;
esac

# Go-style naming
TAR="gotool-${GOOS}-${GOARCH}.tar.gz"
URL="https://github.com/example/gotool/releases/download/${VERSION}/${TAR}"

curl -fsSL "$URL" -o "$TAR"
