#!/usr/bin/env bash
# Canonical release platforms. Keep routing identities separate from compiler
# triples (including GNU/musl variants) and host architecture aliases. Every
# build, manifest, package and provenance consumer uses this same allowlist.
# This module is also bundled into standalone verified release installers;
# sourcing it must not load user configuration or change shell options.

dsr_platform_list() {
    printf '%s\n' \
        linux/amd64 linux/arm64 linux/386 linux/armv7 \
        darwin/amd64 darwin/arm64 \
        windows/amd64 windows/arm64 windows/386 \
        freebsd/amd64
}

# A common anchored pattern for Bash, jq and Python, derived from the list
# above instead of independently maintained OS/architecture cross products.
# jq users must also reject control characters: its $ can match before a final
# newline. Python consumers use fullmatch, Bash consumers the helper below.
dsr_platform_pattern() {
    local platforms
    platforms=$(dsr_platform_list) || return 4
    printf '^(%s)$\n' "${platforms//$'\n'/|}"
}

dsr_platform_is_supported() {
    local pattern
    pattern=$(dsr_platform_pattern) || return 4
    [[ "${1:-}" =~ $pattern ]]
}

# Validate configured/selected matrices before any source or build side
# effects. No aliases are silently rewritten: the same canonical identity
# must survive configuration, artifact naming, manifest and provenance.
dsr_platform_validate_targets_json() {
    local targets="${1:-}" context="${2:-build targets}" problem supported
    command -v jq >/dev/null || {
        printf '[platforms] jq is required to validate %s\n' "$context" >&2
        return 3
    }
    if ! problem=$(jq -sr --arg pattern "$(dsr_platform_pattern)" '
        if length != 1 then "expected one target array" else .[0] |
        if type != "array" then "expected a target array"
        elif length == 0 then "expected at least one target"
        elif any(.[]; type != "string") then "every target must be an os/arch string"
        elif any(.[]; test("[\u0000-\u001f\u007f]") or (test($pattern) | not)) then
            "unsupported target(s): " +
            ([.[] | select(test("[\u0000-\u001f\u007f]") or (test($pattern) | not)) | tojson] | join(", "))
        elif length != (unique | length) then "duplicate targets are not allowed"
        else "" end end
    ' <<< "$targets" 2>/dev/null); then
        problem="invalid target JSON"
    fi
    [[ -n "$problem" ]] || return 0
    supported=$(dsr_platform_list)
    printf '[platforms] Invalid %s: %s. Select supported targets: %s\n' \
        "$context" "$problem" "${supported//$'\n'/, }" >&2
    return 4
}

export -f dsr_platform_list dsr_platform_pattern dsr_platform_is_supported dsr_platform_validate_targets_json
