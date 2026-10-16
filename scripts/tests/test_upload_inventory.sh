#!/usr/bin/env bash
# Production upload and inventory checks; only GitHub transport is substituted.
set -uo pipefail
if (( BASH_VERSINFO[0] < 4 )); then
    echo 'SKIP: upload inventory tests require Bash 4+'
    exit 0
fi
for tool in python3 go jq find cmp wc; do
    if ! command -v "$tool" >/dev/null; then
        echo "SKIP: upload inventory tests require $tool"
        exit 0
    fi
done
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P) || exit 1
export DSR_TEST_BASH="$BASH"
exec python3 "$ROOT/scripts/tests/test_upload_inventory.py" "$@"
