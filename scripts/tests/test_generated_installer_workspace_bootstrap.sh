#!/usr/bin/env bash
# Run the independent cold-compiler workspace cases under the same test-file
# deadline as the original source-routing suite. Each uses the genuine Go
# distribution supplied by DSR_TEST_GO_ARCHIVE or the installed Go runtime.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
exec bash "$ROOT/scripts/tests/test_generated_installer_source.sh" --go-workspace-bootstrap-only "$@"
