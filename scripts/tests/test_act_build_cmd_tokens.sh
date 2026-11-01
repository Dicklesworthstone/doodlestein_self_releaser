#!/usr/bin/env bash
# test_act_build_cmd_tokens.sh - Unit tests for act_substitute_build_cmd_tokens
#
# Regression coverage for beads_viewer#174: DSR must resolve ${version} (and the
# other documented build tokens) in build_cmd itself, rather than relying on the
# remote build shell to expand them. cmd.exe on a Windows native build host does
# not POSIX-expand ${version}, so the literal placeholder was being baked into
# the bv ldflag and shipped in the v0.17.0 Windows binary.
#
# --go-cross-build also runs real offline Go compilation through the production
# environment resolver and command substitution. It does not start a native
# host worker or bypass its readiness admission.
# Usage: ./scripts/tests/test_act_build_cmd_tokens.sh [--go-cross-build]
#
# Exit codes:
#   0 - All tests passed
#   1 - One or more tests failed
#
# shellcheck disable=SC2016 # Tests use literal ${var} patterns that must not expand

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GO_CROSS_BUILD=false
case "${1:-}" in
    '') ;;
    --go-cross-build) GO_CROSS_BUILD=true ;;
    *) printf 'Unknown test option: %s\n' "$1" >&2; exit 4 ;;
esac

# Source the module under test
# shellcheck source=../../src/act_runner.sh
source "$PROJECT_ROOT/src/act_runner.sh"

# Test counters
TEST_COUNT=0
PASS_COUNT=0
FAIL_COUNT=0

log_pass() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [PASS] $*" >&2; }
log_fail() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [FAIL] $*" >&2; }
log_info() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [INFO] $*" >&2; }

assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-assertion}"
    ((TEST_COUNT++))
    if [[ "$expected" == "$actual" ]]; then
        ((PASS_COUNT++))
        log_pass "$msg"
        return 0
    else
        ((FAIL_COUNT++))
        log_fail "$msg"
        log_fail "  expected: '$expected'"
        log_fail "  actual:   '$actual'"
        return 1
    fi
}

# --- Tests -----------------------------------------------------------------

# The exact bv build_cmd that produced beads_viewer#174. The version is given
# WITH a leading "v" (as DSR resolves it) and must be injected stripped, so the
# ldflag carries "0.17.1" (bv's normalizeVersion re-adds the "v").
test_bv_version_token() {
    local out
    out=$(act_substitute_build_cmd_tokens \
        'go build -ldflags="-s -w -X github.com/Dicklesworthstone/beads_viewer/pkg/version.version=${version}" -o bv ./cmd/bv' \
        'bv' 'v0.17.1' 'windows' 'amd64')
    assert_eq \
        'go build -ldflags="-s -w -X github.com/Dicklesworthstone/beads_viewer/pkg/version.version=0.17.1" -o bv ./cmd/bv' \
        "$out" \
        'bv ${version} token is resolved (and v-stripped), no literal placeholder remains'
}

# No DSR token at all -> command must be byte-for-byte unchanged (this is the
# overwhelming majority of fleet repos; they must not be perturbed).
test_no_token_unchanged() {
    local out
    out=$(act_substitute_build_cmd_tokens 'cargo build --release' 'xf' 'v1.2.3' 'linux' 'amd64')
    assert_eq 'cargo build --release' "$out" 'build_cmd with no DSR token is unchanged'
}

# Shell constructs that are NOT DSR tokens ($HOME, $PATH, unbraced $version)
# must be left untouched for the shell (cf. jfp_premium's build_cmd).
test_shell_vars_untouched() {
    local out
    out=$(act_substitute_build_cmd_tokens \
        'export PATH="$HOME/.bun/bin:$PATH" && bun install && ./build.sh' \
        'jfp' 'v2.0.0' 'linux' 'arm64')
    assert_eq \
        'export PATH="$HOME/.bun/bin:$PATH" && bun install && ./build.sh' \
        "$out" \
        '$HOME/$PATH (non-DSR shell vars) are left for the shell'
}

# os/arch/name tokens resolve from the platform (forward-looking; no current
# repo uses these in build_cmd, but the token set should be consistent).
test_os_arch_name_tokens() {
    local out
    out=$(act_substitute_build_cmd_tokens \
        'go build -o ${name}-${os}-${arch} .' \
        'mytool' '0.1.0' 'darwin' 'arm64')
    assert_eq 'go build -o mytool-darwin-arm64 .' "$out" 'name/os/arch tokens resolve'
}

# Compiler selectors and release-routing names are distinct for ARMv7. The
# explicit command assignment must agree with act_get_build_env; otherwise it
# overrides GOARCH=arm with an unsupported Go architecture at execution time.
test_go_architecture_tokens() {
    local out arch
    out=$(act_substitute_build_cmd_tokens \
        'GOOS=${GOOS} GOARCH=${GOARCH} go build -o ${NAME}-${OS}-${ARCH} .' \
        'tool' 'v1.2.3' 'linux' 'armv7')
    assert_eq 'GOOS=linux GOARCH=arm go build -o tool-linux-armv7 .' "$out" \
        'uppercase Go selector is arm while the release-routing token remains armv7'
    out=$(act_substitute_build_cmd_tokens \
        'GOOS=${goos} GOARCH=${goarch} go build -o ${name}-${os}-${arch} .' \
        'tool' 'v1.2.3' 'linux' 'armv7')
    assert_eq 'GOOS=linux GOARCH=arm go build -o tool-linux-armv7 .' "$out" \
        'lowercase Go selector is arm while the release-routing token remains armv7'
    for arch in amd64 arm64 386; do
        out=$(act_substitute_build_cmd_tokens 'GOARCH=${GOARCH} go build -o tool-${arch} .' \
            'tool' 'v1.2.3' 'linux' "$arch")
        assert_eq "GOARCH=$arch go build -o tool-$arch ." "$out" \
            "$arch Go and routing selectors retain their existing values"
    done
    out=$(act_substitute_build_cmd_tokens 'GOARM=$GOARM go build -o tool-${arch} .' \
        'tool' 'v1.2.3' 'linux' 'armv7')
    assert_eq 'GOARM=$GOARM go build -o tool-armv7 .' "$out" \
        'the configured GOARM environment remains under the existing resolver'
}

test_go_armv7_cross_build() {
    local dependency
    for dependency in go yq jq; do
        if ! command -v "$dependency" >/dev/null; then
            assert_eq available missing "real Go command regression requires $dependency"
            return 1
        fi
    done
    local fixture
    fixture=$(mktemp -d "${TMPDIR:-/tmp}/dsr-go-command-tokens.XXXXXXXX") || return 1
    log_info "Retained real Go command evidence: $fixture"
    local ACT_REPOS_DIR="$fixture/config" environment pair mode template command artifact metadata status
    local -a environment_args=()
    mkdir -p "$ACT_REPOS_DIR" "$fixture/cache" "$fixture/tmp" "$fixture/uppercase" "$fixture/lowercase" || return 1
    cat > "$ACT_REPOS_DIR/fixture.yaml" <<'YAML'
tool_name: fixture
language: go
binary_name: fixture
targets: [linux/armv7]
env:
  CGO_ENABLED: "0"
YAML
    cat > "$fixture/main.go" <<'GO'
package main
import "runtime"
func main() { println(runtime.GOOS + "/" + runtime.GOARCH) }
GO
    environment=$(act_get_build_env fixture linux/armv7) || {
        assert_eq resolved failed 'production Go environment resolves the ARMv7 request'
        return 1
    }
    assert_eq arm "$(act_get_build_env_value "$environment" GOARCH)" 'real build resolves GOARCH=arm'
    assert_eq 7 "$(act_get_build_env_value "$environment" GOARM)" 'real build resolves GOARM=7'
    while IFS= read -r pair; do
        [[ -n "$pair" ]] && environment_args+=("$pair")
    done <<< "$environment"
    for mode in uppercase lowercase; do
        if [[ "$mode" == uppercase ]]; then
            template='GOOS=${GOOS} GOARCH=${GOARCH} go build -p 1 -trimpath -o "$DSR_GO_OUTPUT/${NAME}-${OS}-${ARCH}" "$DSR_GO_SOURCE"'
        else
            template='GOOS=${goos} GOARCH=${goarch} go build -p 1 -trimpath -o "$DSR_GO_OUTPUT/${name}-${os}-${arch}" "$DSR_GO_SOURCE"'
        fi
        command=$(act_substitute_build_cmd_tokens "$template" fixture v1.2.3 linux armv7) || return 1
        printf '%s\n' "$command" > "$fixture/$mode/command.txt"
        status=0
        # A private bounded fixture cache and an absolute single source file
        # keep this build offline and independent of repository dependencies.
        # Deliberately conflicting inherited selectors must lose to the real
        # resolver and the subsequently expanded command assignments.
        env GOOS=plan9 GOARCH=386 GOARM=5 GOENV=off GO111MODULE=off \
            GOTOOLCHAIN=local GOPROXY=off GOSUMDB=off GOMAXPROCS=2 \
            GOCACHE="$fixture/cache" GOTMPDIR="$fixture/tmp" \
            DSR_GO_OUTPUT="$fixture/$mode" DSR_GO_SOURCE="$fixture/main.go" \
            "${environment_args[@]}" bash -c "$command" \
            > "$fixture/$mode/stdout" 2> "$fixture/$mode/stderr" || status=$?
        assert_eq 0 "$status" "$mode command compiles the requested ARMv7 program with real Go"
        if [[ "$status" -ne 0 ]]; then
            cat "$fixture/$mode/stderr" >&2
            continue
        fi
        artifact="$fixture/$mode/fixture-linux-armv7"
        status=0
        _act_validate_target_binary "$artifact" linux/armv7 || status=$?
        assert_eq 0 "$status" "$mode output passes production Linux ARMv7 binary admission"
        metadata=$(GOENV=off go version -m "$artifact") || return 1
        printf '%s\n' "$metadata" > "$fixture/$mode/build-info.txt"
        assert_eq arm "$(awk '$1 == "build" && $2 ~ /^GOARCH=/ {sub(/^GOARCH=/,"",$2); print $2}' <<< "$metadata")" \
            "$mode embedded compiler metadata records GOARCH=arm"
        pair=$(awk '$1 == "build" && $2 ~ /^GOARM=/ {sub(/^GOARM=/,"",$2); print $2}' <<< "$metadata")
        assert_eq 7 "${pair%%,*}" "$mode embedded compiler metadata records the ARMv7 ISA"
    done
}

# Version without a leading "v" is passed through as-is.
test_version_without_v() {
    local out
    out=$(act_substitute_build_cmd_tokens 'echo ${version}' 'x' '3.4.5' 'linux' 'amd64')
    assert_eq 'echo 3.4.5' "$out" 'version without leading v is preserved'
}

# --- Shell-injection hardening (defense in depth) --------------------------
#
# The substituted build_cmd is later run by a shell (local bash and/or a remote
# login shell). A token value carrying shell metacharacters must be REJECTED
# (non-zero exit, no output) rather than spliced in. These values are passed
# single-quoted so the test harness itself never expands them; the function only
# pattern-matches and string-substitutes, so nothing here can execute them.

# assert_rejects <msg> <name> <version> <os> <arch>
assert_rejects() {
    local msg="$1"; shift
    local name="$1" version="$2" os="$3" arch="$4"
    local out rc
    out=$(act_substitute_build_cmd_tokens 'go build ${version}' "$name" "$version" "$os" "$arch" 2>/dev/null)
    rc=$?
    ((TEST_COUNT++))
    if [[ "$rc" -ne 0 && -z "$out" ]]; then
        ((PASS_COUNT++))
        log_pass "$msg"
        return 0
    fi
    ((FAIL_COUNT++))
    log_fail "$msg (rc=$rc out='$out')"
    return 1
}

test_rejects_command_substitution_in_version() {
    assert_rejects 'version with $(...) command substitution is rejected' \
        'bv' '1.0.0$(touch pwned)' 'linux' 'amd64'
}
test_rejects_backtick_in_version() {
    assert_rejects 'version with backticks is rejected' \
        'bv' '1.0.0`id`' 'linux' 'amd64'
}
test_rejects_semicolon_in_version() {
    assert_rejects 'version with ; command separator is rejected' \
        'bv' '1.0.0; rm -rf /' 'linux' 'amd64'
}
test_rejects_pipe_in_name() {
    assert_rejects 'name with a pipe is rejected' \
        'bv|cat' '1.0.0' 'linux' 'amd64'
}
test_rejects_newline_in_arch() {
    assert_rejects 'arch with an embedded newline is rejected' \
        'bv' '1.0.0' 'linux' "$(printf 'amd64\nwhoami')"
}
test_rejects_space_in_os() {
    assert_rejects 'os with whitespace is rejected' \
        'bv' '1.0.0' 'lin ux' 'amd64'
}

# A real, complex-but-clean semver (pre-release + build metadata) must PASS so
# the guard never blocks a legitimate release.
test_accepts_clean_semver_with_build_metadata() {
    local out
    out=$(act_substitute_build_cmd_tokens 'echo ${version}' 'bv' 'v1.2.3-rc.1+build.5' 'linux' 'amd64')
    assert_eq 'echo 1.2.3-rc.1+build.5' "$out" \
        'clean semver with pre-release+build metadata is accepted (and v-stripped)'
}

# --- Run -------------------------------------------------------------------

log_info "Running act_substitute_build_cmd_tokens unit tests"
test_bv_version_token
test_no_token_unchanged
test_shell_vars_untouched
test_os_arch_name_tokens
test_go_architecture_tokens
test_version_without_v
test_rejects_command_substitution_in_version
test_rejects_backtick_in_version
test_rejects_semicolon_in_version
test_rejects_pipe_in_name
test_rejects_newline_in_arch
test_rejects_space_in_os
test_accepts_clean_semver_with_build_metadata
if $GO_CROSS_BUILD; then
    test_go_armv7_cross_build || assert_eq complete aborted 'real Go regression completes every requested check'
fi

log_info "Results: $PASS_COUNT/$TEST_COUNT passed, $FAIL_COUNT failed"
[[ "$FAIL_COUNT" -eq 0 ]]
