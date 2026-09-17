#!/usr/bin/env bash
# Release-name contract regressions (bd-1tv / bd-1tv.12).
# Runs without network, yq, installed repo configs, or a build host.
# shellcheck disable=SC2016 # Literal naming templates are test inputs.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# The override allows the same regressions to be run against a baseline module.
# shellcheck source=../../src/artifact_naming.sh
source "${DSR_NAMING_MODULE:-$PROJECT_ROOT/src/artifact_naming.sh}"
command -v jq >/dev/null || { echo 'jq is required' >&2; exit 3; }

# Isolate config lookups, retaining the production normalizer and renderer.
# Config identity deliberately differs from the executable's naming identity.
config_get_arch_alias() {
    if [[ "$1" == "registered-app" && "$2" == "amd64" ]]; then
        printf '%s\n' x86_64
    fi
}
config_get_target_triple() {
    if [[ "$1" == "registered-app" && "$2" == "linux/amd64" ]]; then
        printf '%s\n' x86_64-unknown-linux-musl
    fi
}
config_get_tool_field() {
    case "$2" in tool_name) printf '%s\n' app ;; esac
}
config_get_install_script_compat() { :; }
config_get_install_script_path() { :; }
config_get_artifact_naming() { :; }

passed=0 failed=0
expect() {
    local label="$1" expected="$2" actual status=0
    shift 2
    actual=$("$@") || status=$?
    if [[ $status -eq 0 && "$actual" == "$expected" ]]; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        printf 'FAIL %s (exit %s)\n  expected: %s\n  actual:   %s\n' \
            "$label" "$status" "$expected" "$actual" >&2
    fi
}
reject() {
    local label="$1" actual status=0
    shift
    actual=$("$@" 2>/dev/null) || status=$?
    if [[ $status -eq 4 && -z "$actual" ]]; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        printf 'FAIL %s: expected exit 4 and empty stdout, got %s: %s\n' \
            "$label" "$status" "$actual" >&2
    fi
}
# Validate the entire output, not just the last JSON object in a stream.
names() {
    local result
    result=$(artifact_naming_generate_dual "$@") || return $?
    jq -ces 'if length == 1 and (.[0] | keys == ["compat","same","versioned"])
        then .[0] | [.versioned, .compat, .same] else error("invalid naming plan") end' <<< "$result"
}

expect 'whole target token' '${target_triple}-${target}' _an_normalize_pattern '$TARGET_TRIPLE-$TARGET'
expect 'unknown token is not a prefix match' '$NAME_SUFFIX-$OS_VERSION-$TARGET_TRIPLE_EXTRA' \
    _an_normalize_pattern '$NAME_SUFFIX-$OS_VERSION-$TARGET_TRIPLE_EXTRA'
expect 'canonical aliases' '${name}-${version}-${os}-${arch}-${target}-${target_triple}.${ext}' \
    _an_normalize_pattern '${APP}-$VERSION-${GOOS}-$GOARCH-${TARGET}-$TARGET_TRIPLE.$EXT'
expect 'lowercase bare variables' '${name}-${version}-${os}_${arch}' \
    _an_normalize_pattern '$name-$version-$platform'
expect 'workflow tokens' '${name}-${version}-${target_triple}-${os}-${arch}' \
    _an_normalize_pattern '${name}-${{ github.ref_name }}-${{ matrix.target }}-${{ matrix.goos }}-${{ matrix.goarch }}'
expect 'unknown expression stays intact' '${{ matrix.target || matrix.os }}' \
    _an_normalize_pattern '${{ matrix.target || matrix.os }}'
expect 'normalization is idempotent' '${name}-${version}-${os}_${arch}.${ext}' \
    _an_normalize_pattern "$(_an_normalize_pattern '$APP-$VERSION-$PLATFORM.$EXT')"

for platform in linux/amd64 linux/arm64 darwin/amd64 darwin/arm64 windows/amd64 windows/arm64; do
    os="${platform%/*}" arch="${platform#*/}"
    case "$platform" in
        linux/amd64) triple=x86_64-unknown-linux-gnu ;;
        linux/arm64) triple=aarch64-unknown-linux-gnu ;;
        darwin/amd64) triple=x86_64-apple-darwin ;;
        darwin/arm64) triple=aarch64-apple-darwin ;;
        windows/amd64) triple=x86_64-pc-windows-msvc ;;
        windows/arm64) triple=aarch64-pc-windows-msvc ;;
    esac
    expect "default names $platform" "[\"app-1.2.3-$os-$arch.tar.gz\",\"app-$os-$arch.tar.gz\",false]" \
        names app v1.2.3 "$os" "$arch"
    expect "bare triple $platform" "app-$triple.tar.xz" \
        artifact_naming_substitute '$APP-$TARGET_TRIPLE.$EXT' app v1.2.3 "$os" "$arch" tar.xz
    expect "workflow triple $platform" "app-1.2.3-$triple.zip" \
        artifact_naming_substitute '${name}-${{ github.ref_name }}-${{ matrix.target }}.${ext}' \
        app v1.2.3 "$os" "$arch" zip
    for ext in '' none; do
        expect "raw binary $platform ext=$ext" "[\"app-1.2.3-$triple\",\"app-$triple\",false]" \
            names app v1.2.3 "$os" "$arch" "$ext" \
            '$NAME-$TARGET_TRIPLE.$EXT' '$NAME-$VERSION-$TARGET_TRIPLE.$EXT'
    done
    expect "raw default $platform" "[\"app-1.2.3-$os-$arch\",\"app-$os-$arch\",false]" \
        names app v1.2.3 "$os" "$arch" none
 done

for ext in tar.gz tar.xz tgz zip exe; do
    expect "one extension $ext" "[\"app-1-linux-amd64.$ext\",\"app-linux-amd64.$ext\",false]" \
        names app v1 linux amd64 "$ext" '$NAME-$TARGET.$EXT' '$NAME-$VERSION-$TARGET.$EXT'
done
expect 'fixed extension preserved' '["app-1-linux-amd64.tar.xz","app-linux-amd64.tar.xz",false]' \
    names app v1 linux amd64 tar.gz '${name}-${target}.tar.xz' '${name}-${version}-${target}.tar.xz'
expect 'configured triple and arch alias' 'app-x86_64-linux-x86_64-x86_64-unknown-linux-musl' \
    artifact_naming_substitute '$APP-$ARCH-$TARGET-$TARGET_TRIPLE' app v1 linux amd64 none registered-app
expect 'default names honor config identity' '["app-1-linux-x86_64.tar.gz","app-linux-x86_64.tar.gz",false]' \
    names app v1 linux amd64 tar.gz '' '' registered-app
expect 'same alias is explicit' '["app-1-linux-amd64.tar.gz","app-1-linux-amd64.tar.gz",true]' \
    names app v1 linux amd64 tar.gz '$NAME-$VERSION-$TARGET' '$NAME-$VERSION-$TARGET'
expect 'literal v and prerelease metadata' 'app-v1.2.3-rc.1+build.2-linux_amd64' \
    artifact_naming_substitute '$APP-v${VERSION}-$PLATFORM' app v1.2.3-rc.1+build.2 linux amd64
expect 'literal name underscores' 'my__app-1-linux_amd64' \
    artifact_naming_substitute '${name}-${version}-${platform}' my__app v1 linux amd64

for pattern in '$UNKNOWN' '$TARGET_TRIPLE_EXTRA' '${name:-fallback}' \
    '${{ matrix.unsupported }}' '${name}/../asset' '../${name}' '.' '..' \
    '${name}"broken' '${name}\\broken' '${name} with spaces' '$(printf injected)' '`printf injected`'; do
    reject "unsafe or unresolved pattern $pattern" names app v1 linux amd64 tar.gz "$pattern"
done
reject 'unsafe tool' names 'app"bad' v1 linux amd64
reject 'unsafe version' names app 'v1/../../bad' linux amd64
reject 'empty version after prefix' names app v linux amd64
reject 'unsafe extension' names app v1 linux amd64 '../zip'
reject 'missing arguments' artifact_naming_generate_dual app
reject 'substitute missing arguments' artifact_naming_substitute '${name}'

printf 'Artifact naming contract: %s passed, %s failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
