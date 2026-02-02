#!/usr/bin/env bash
# Install.sh fixture with uppercase ASSET_NAME variable
set -euo pipefail

VERSION="${VERSION:-latest}"
TARGET="${OS:-linux}-${ARCH:-amd64}"

ASSET_NAME="uppertool-${TARGET}.tar.gz"
URL="https://github.com/example/uppertool/releases/download/${VERSION}/${ASSET_NAME}"

curl -fsSL "$URL" -o "$ASSET_NAME"
