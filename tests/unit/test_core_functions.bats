#!/usr/bin/env bats
# test_core_functions.bats - Unit tests for platform detection and freshness checking
#
# bd-1jt.5.1: Unit tests for platform detection and freshness checking
#
# Coverage:
# - Platform detection (OS and architecture normalization)
# - Version freshness checking (compare installed vs available)
# - Archive format selection by platform
#
# Run: bats tests/unit/test_core_functions.bats

# Load test harness
load ../helpers/test_harness.bash

# ============================================================================
# Test Setup
# ============================================================================

setup() {
    harness_setup

    # Create a minimal version of the platform detection functions for testing
    # These mirror the functions in src/install_gen.sh and installers/*/install.sh

    # Override uname for testing
    _mock_uname_s=""
    _mock_uname_m=""

    mock_uname() {
        case "$1" in
            -s) echo "$_mock_uname_s" ;;
            -m) echo "$_mock_uname_m" ;;
            *) command uname "$@" ;;
        esac
    }

    # Platform detection function (mirrors install_gen.sh)
    _detect_platform() {
        local os arch

        os=$(mock_uname -s | tr '[:upper:]' '[:lower:]')
        case "$os" in
            darwin) os="darwin" ;;
            linux) os="linux" ;;
            mingw*|msys*|cygwin*) os="windows" ;;
            *) echo "unsupported"; return 1 ;;
        esac

        arch=$(mock_uname -m)
        case "$arch" in
            x86_64|amd64) arch="amd64" ;;
            aarch64|arm64) arch="arm64" ;;
            armv7*) arch="armv7" ;;
            i386|i686) arch="386" ;;
            *) echo "unsupported"; return 1 ;;
        esac

        echo "$os/$arch"
    }

    # Archive format selection (mirrors install_gen.sh)
    _get_archive_format() {
        local platform="$1"
        local os="${platform%/*}"

        case "$os" in
            linux) echo "tar.gz" ;;
            darwin) echo "tar.gz" ;;
            windows) echo "zip" ;;
            *) echo "tar.gz" ;;
        esac
    }

    # Version comparison for freshness checking
    # Returns: 0 if v1 >= v2, 1 if v1 < v2
    _version_gte() {
        local v1="$1"
        local v2="$2"

        # Strip 'v' prefix if present
        v1="${v1#v}"
        v2="${v2#v}"

        # Simple semver comparison using sort -V
        if printf '%s\n%s\n' "$v2" "$v1" | sort -V -C 2>/dev/null; then
            return 0
        fi
        return 1
    }

    # Check if installed version is fresh (>= available)
    _is_fresh() {
        local installed="$1"
        local available="$2"

        [[ -z "$installed" ]] && return 1
        [[ -z "$available" ]] && return 0  # No available version means fresh

        _version_gte "$installed" "$available"
    }
}

teardown() {
    harness_teardown
}

# ============================================================================
# Platform Detection Tests - Linux
# ============================================================================

@test "detect Linux x86_64" {
    _mock_uname_s="Linux"
    _mock_uname_m="x86_64"

    local result
    result=$(_detect_platform)

    assert_equal "linux/amd64" "$result" "Linux x86_64 should map to linux/amd64"
}

@test "detect Linux amd64 (alternate)" {
    _mock_uname_s="Linux"
    _mock_uname_m="amd64"

    local result
    result=$(_detect_platform)

    assert_equal "linux/amd64" "$result" "Linux amd64 should map to linux/amd64"
}

@test "detect Linux ARM64 (aarch64)" {
    _mock_uname_s="Linux"
    _mock_uname_m="aarch64"

    local result
    result=$(_detect_platform)

    assert_equal "linux/arm64" "$result" "Linux aarch64 should map to linux/arm64"
}

@test "detect Linux ARM64 (arm64)" {
    _mock_uname_s="Linux"
    _mock_uname_m="arm64"

    local result
    result=$(_detect_platform)

    assert_equal "linux/arm64" "$result" "Linux arm64 should map to linux/arm64"
}

@test "detect Linux ARMv7" {
    _mock_uname_s="Linux"
    _mock_uname_m="armv7l"

    local result
    result=$(_detect_platform)

    assert_equal "linux/armv7" "$result" "Linux armv7l should map to linux/armv7"
}

@test "detect Linux 386 (i686)" {
    _mock_uname_s="Linux"
    _mock_uname_m="i686"

    local result
    result=$(_detect_platform)

    assert_equal "linux/386" "$result" "Linux i686 should map to linux/386"
}

@test "detect Linux 386 (i386)" {
    _mock_uname_s="Linux"
    _mock_uname_m="i386"

    local result
    result=$(_detect_platform)

    assert_equal "linux/386" "$result" "Linux i386 should map to linux/386"
}

# ============================================================================
# Platform Detection Tests - macOS
# ============================================================================

@test "detect macOS ARM64 (Apple Silicon)" {
    _mock_uname_s="Darwin"
    _mock_uname_m="arm64"

    local result
    result=$(_detect_platform)

    assert_equal "darwin/arm64" "$result" "macOS arm64 should map to darwin/arm64"
}

@test "detect macOS x86_64 (Intel)" {
    _mock_uname_s="Darwin"
    _mock_uname_m="x86_64"

    local result
    result=$(_detect_platform)

    assert_equal "darwin/amd64" "$result" "macOS x86_64 should map to darwin/amd64"
}

# ============================================================================
# Platform Detection Tests - Windows
# ============================================================================

@test "detect Windows via MINGW64" {
    _mock_uname_s="MINGW64_NT-10.0-19045"
    _mock_uname_m="x86_64"

    local result
    result=$(_detect_platform)

    assert_equal "windows/amd64" "$result" "MINGW64 should map to windows/amd64"
}

@test "detect Windows via MSYS" {
    _mock_uname_s="MSYS_NT-10.0"
    _mock_uname_m="x86_64"

    local result
    result=$(_detect_platform)

    assert_equal "windows/amd64" "$result" "MSYS should map to windows/amd64"
}

@test "detect Windows via Cygwin" {
    _mock_uname_s="CYGWIN_NT-10.0"
    _mock_uname_m="x86_64"

    local result
    result=$(_detect_platform)

    assert_equal "windows/amd64" "$result" "Cygwin should map to windows/amd64"
}

# ============================================================================
# Platform Detection Tests - Unsupported
# ============================================================================

@test "detect unsupported OS returns error" {
    _mock_uname_s="FreeBSD"
    _mock_uname_m="x86_64"

    run _detect_platform
    assert_equal "1" "$status" "Unsupported OS should return error"
}

@test "detect unsupported architecture returns error" {
    _mock_uname_s="Linux"
    _mock_uname_m="ppc64le"

    run _detect_platform
    assert_equal "1" "$status" "Unsupported arch should return error"
}

# ============================================================================
# Archive Format Tests
# ============================================================================

@test "archive format for Linux is tar.gz" {
    local format
    format=$(_get_archive_format "linux/amd64")
    assert_equal "tar.gz" "$format"
}

@test "archive format for macOS is tar.gz" {
    local format
    format=$(_get_archive_format "darwin/arm64")
    assert_equal "tar.gz" "$format"
}

@test "archive format for Windows is zip" {
    local format
    format=$(_get_archive_format "windows/amd64")
    assert_equal "zip" "$format"
}

@test "archive format for unknown defaults to tar.gz" {
    local format
    format=$(_get_archive_format "unknown/arch")
    assert_equal "tar.gz" "$format"
}

# ============================================================================
# Version Freshness Tests
# ============================================================================

@test "version comparison: equal versions are fresh" {
    assert_success _is_fresh "1.2.3" "1.2.3"
}

@test "version comparison: newer installed is fresh" {
    assert_success _is_fresh "1.2.4" "1.2.3"
}

@test "version comparison: older installed is stale" {
    assert_failure _is_fresh "1.2.2" "1.2.3"
}

@test "version comparison: major version difference (fresh)" {
    assert_success _is_fresh "2.0.0" "1.9.9"
}

@test "version comparison: major version difference (stale)" {
    assert_failure _is_fresh "1.9.9" "2.0.0"
}

@test "version comparison: handles v prefix" {
    assert_success _is_fresh "v1.2.3" "1.2.3"
    assert_success _is_fresh "1.2.3" "v1.2.3"
    assert_success _is_fresh "v1.2.4" "v1.2.3"
}

@test "version comparison: empty installed is stale" {
    assert_failure _is_fresh "" "1.2.3"
}

@test "version comparison: empty available is fresh" {
    assert_success _is_fresh "1.2.3" ""
}

@test "version comparison: both empty is stale" {
    assert_failure _is_fresh "" ""
}

@test "version comparison: prerelease versions" {
    # Note: sort -V does NOT strictly follow semver for prereleases
    # It treats 1.0.0-alpha as "newer" than 1.0.0 alphabetically
    # This is a known limitation - we verify the actual behavior
    # For strict semver comparison, a dedicated library would be needed

    # sort -V treats hyphens as separators, so 1.0.0-alpha > 1.0.0 lexically
    # This test documents actual behavior rather than ideal semver
    assert_success _is_fresh "1.0.0-beta" "1.0.0-alpha"  # beta > alpha
    assert_success _is_fresh "1.0.1" "1.0.0-anything"    # 1.0.1 > 1.0.0-*
}

# ============================================================================
# Real Platform Detection Test (uses actual uname)
# ============================================================================

@test "real platform detection returns valid format" {
    # Use actual system uname
    unset -f mock_uname

    # Redefine with real uname
    _detect_platform_real() {
        local os arch

        os=$(uname -s | tr '[:upper:]' '[:lower:]')
        case "$os" in
            darwin) os="darwin" ;;
            linux) os="linux" ;;
            mingw*|msys*|cygwin*) os="windows" ;;
            *) echo "unsupported"; return 1 ;;
        esac

        arch=$(uname -m)
        case "$arch" in
            x86_64|amd64) arch="amd64" ;;
            aarch64|arm64) arch="arm64" ;;
            armv7*) arch="armv7" ;;
            i386|i686) arch="386" ;;
            *) echo "unsupported"; return 1 ;;
        esac

        echo "$os/$arch"
    }

    local result
    result=$(_detect_platform_real)

    # Should match format: os/arch
    [[ "$result" =~ ^(linux|darwin|windows)/(amd64|arm64|armv7|386)$ ]]
}
