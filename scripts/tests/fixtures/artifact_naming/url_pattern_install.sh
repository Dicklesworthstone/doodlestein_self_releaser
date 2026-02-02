#!/usr/bin/env bash
# Install.sh fixture with URL-based pattern extraction
set -euo pipefail

VERSION="${VERSION:-latest}"
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)

# No TAR or asset_name variable, pattern is extracted from URL
URL="https://github.com/example/urltool/releases/download/${VERSION}/urltool-${OS}-${ARCH}.tar.gz"

curl -fsSL "$URL" -o "urltool.tar.gz"
tar -xzf "urltool.tar.gz"
