#!/usr/bin/env bash
# Install.sh fixture with commented pattern that should be ignored
# NOTE: Current parser limitation - grep doesn't filter comments on same line
set -euo pipefail

VERSION="${VERSION:-latest}"
TARGET="${OS:-linux}-${ARCH:-amd64}"

# Old pattern mentioned in comment (not a TAR= assignment):
# The old tool used: oldtool-deprecated-TARGET.tar.gz format

# Active pattern - this is the real TAR assignment
TAR="realtool-${TARGET}.tar.gz"
URL="https://github.com/example/realtool/releases/download/${VERSION}/${TAR}"

curl -fsSL "$URL" -o "$TAR"
