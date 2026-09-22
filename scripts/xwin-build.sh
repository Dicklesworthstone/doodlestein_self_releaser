#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=src/xwin_build.sh
source "$SCRIPT_DIR/../src/xwin_build.sh" || exit 3
if [[ "${1:-}" == --help || "${1:-}" == -h ]]; then
    printf '%s\n' 'Usage: xwin-build.sh --manifest FILE --project DIR --bin NAME --run-dir NEW_DIR' \
        '       [--package NAME] [--cache-dir DIR] [--cargo-cache DIR] [--offline] [--timeout SECONDS]' \
        'Build one release-profile Windows ARM64 executable; stdout is a verified JSON receipt.'
    exit 0
fi
_xwb_build "$@" &
worker=$!
cancel() {
    trap '' HUP INT TERM
    kill -TERM "$worker" 2>/dev/null || true
    wait "$worker" 2>/dev/null || true
    exit 5
}
trap cancel HUP INT TERM
status=0
wait "$worker" || status=$?
exit "$status"
