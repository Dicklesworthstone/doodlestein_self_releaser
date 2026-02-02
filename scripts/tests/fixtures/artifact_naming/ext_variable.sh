#!/usr/bin/env bash
# Install.sh fixture with EXT variable
set -euo pipefail

VERSION="${VERSION:-latest}"
TARGET="${OS:-linux}-${ARCH:-amd64}"
EXT="tar.gz"

TAR="exttool-${TARGET}.${EXT}"
URL="https://github.com/example/exttool/releases/download/${VERSION}/${TAR}"

curl -fsSL "$URL" -o "$TAR"
