#!/usr/bin/env bash
# Install.sh fixture with NAME/TOOL variables
set -euo pipefail

VERSION="${VERSION:-latest}"
NAME="namedtool"
TARGET="${OS:-linux}-${ARCH:-amd64}"

TAR="${NAME}-${TARGET}.tar.gz"
URL="https://github.com/example/${NAME}/releases/download/${VERSION}/${TAR}"

curl -fsSL "$URL" -o "$TAR"
