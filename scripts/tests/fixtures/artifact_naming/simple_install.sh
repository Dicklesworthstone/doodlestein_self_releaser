#!/usr/bin/env bash
# Simple install.sh fixture with TAR variable pattern
set -euo pipefail

VERSION="${VERSION:-latest}"
TARGET="${OS:-linux}-${ARCH:-amd64}"
EXT="tar.gz"

TAR="mytool-${TARGET}.${EXT}"
URL="https://github.com/example/mytool/releases/download/${VERSION}/${TAR}"

curl -fsSL "$URL" -o "$TAR"
tar -xzf "$TAR"
