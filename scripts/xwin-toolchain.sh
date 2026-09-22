#!/usr/bin/env bash
# Prepare or revalidate the pinned Windows ARM64 closure described in
# docs/XWIN_TOOLCHAIN.md. No source/toolchain installation is modified.
set -uo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=src/xwin_toolchain.sh
source "$SCRIPT_DIR/../src/xwin_toolchain.sh" || exit 3

main() {
    local command="${1:-}" manifest='' cache='' option
    [[ $# -gt 0 ]] && shift
    case "$command" in
        --help|-h|help|'')
            printf '%s\n' 'Usage: xwin-toolchain.sh prepare|verify --manifest FILE [--cache-dir DIR]' \
                'Inputs are SHA-256-pinned local archives and executable files. stdout is JSON.'
            return 0 ;;
        prepare|verify) ;;
        *) _xwt_log "Unknown command: $command"; return 4 ;;
    esac
    local -A seen=()
    while (($#)); do
        option=$1
        [[ -z "${seen[$option]:-}" && $# -ge 2 && -n "$2" && "$2" != --* ]] || return 4
        seen[$option]=1
        case "$option" in
            --manifest) manifest=$2 ;;
            --cache-dir) cache=$2 ;;
            *) _xwt_log "Unknown option: $option"; return 4 ;;
        esac
        shift 2
    done
    xwin_toolchain_prepare "$manifest" "$cache" "$command"
}
main "$@"
