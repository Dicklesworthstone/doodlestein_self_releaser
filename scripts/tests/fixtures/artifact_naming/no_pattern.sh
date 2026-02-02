#!/usr/bin/env bash
# Install.sh fixture with no recognizable pattern (builds from source)
set -euo pipefail

echo "This install script builds from source"
git clone https://github.com/example/tool.git
cd tool
make install
