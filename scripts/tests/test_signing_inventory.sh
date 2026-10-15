#!/usr/bin/env bash
# Discovered by scripts/run-all-tests.sh; never substitute fake compilers/signers.
set -uo pipefail
if (( BASH_VERSINFO[0] < 4 )); then
    echo 'SKIP: signing inventory tests require Bash 4+'
    exit 0
fi
for tool in python3 go jq find cmp wc; do
    if ! command -v "$tool" >/dev/null; then
        echo "SKIP: signing inventory tests require $tool"
        exit 0
    fi
done
if ! command -v sha256sum >/dev/null && ! command -v shasum >/dev/null; then
    echo 'SKIP: signing inventory tests require sha256sum or shasum'
    exit 0
fi
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || exit 1
# Keep the invoking Bash 4+ on macOS, where /bin/bash may still be 3.2.
export DSR_TEST_BASH="$BASH"
exec python3 "$SCRIPT_DIR/test_signing_inventory.py" "$@"
