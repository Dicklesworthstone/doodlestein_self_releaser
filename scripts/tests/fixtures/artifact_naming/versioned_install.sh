#!/usr/bin/env bash
# Install.sh fixture with versioned asset name
set -euo pipefail

VERSION="${VERSION:-v1.0.0}"
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

# This pattern includes version in the filename
asset_name="mytool-${VERSION}-${OS}-${ARCH}.tar.gz"
URL="https://github.com/example/mytool/releases/download/${VERSION}/${asset_name}"

curl -fsSL "$URL" -o "$asset_name"
