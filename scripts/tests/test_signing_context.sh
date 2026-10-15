#!/usr/bin/env bash
# Production signing context tests; genuine Minisign is optional and never faked.
set -uo pipefail
if (( BASH_VERSINFO[0] < 4 )); then
    echo 'SKIP: signing context requires Bash 4+'
    exit 0
fi
for tool in python3 jq find; do
    if ! command -v "$tool" >/dev/null; then
        echo "SKIP: signing context requires $tool"
        exit 0
    fi
done
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
export DSR_TEST_BASH="$BASH"
exec python3 "$SCRIPT_DIR/test_signing_context.py" "$@"
