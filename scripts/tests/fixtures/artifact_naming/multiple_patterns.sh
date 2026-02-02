#!/usr/bin/env bash
# Install.sh fixture with multiple patterns (first should be taken)
set -euo pipefail

VERSION="${VERSION:-latest}"
TARGET="${OS:-linux}-${ARCH:-amd64}"

# First TAR pattern - should be extracted
TAR="firsttool-${TARGET}.tar.gz"

# Second TAR pattern - should be ignored (first one wins)
TAR="secondtool-${TARGET}.zip"

URL="https://github.com/example/tool/releases/download/${VERSION}/${TAR}"
curl -fsSL "$URL" -o "$TAR"
