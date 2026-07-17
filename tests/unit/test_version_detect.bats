#!/usr/bin/env bats
# test_version_detect.bats - Unit tests for version detection and auto-tagging
#
# bd-1jt.5.23: Tests for auto-tag version detection
#
# Coverage:
# - Parse Cargo.toml / package.json / VERSION / pyproject.toml
# - Detect existing tag with git plumbing
# - Dirty tree detection (should block)
# - --dry-run behavior
#
# Run: bats tests/unit/test_version_detect.bats

# Load test harness
load ../helpers/test_harness.bash

# ============================================================================
# Test Setup
# ============================================================================

setup() {
    harness_setup

    # Source the version module
    source "$PROJECT_ROOT/src/version.sh"

    # Create a mock repo directory
    MOCK_REPO="$TEST_TMPDIR/mock_repo"
    mkdir -p "$MOCK_REPO"

    # Initialize git repo for tag tests
    git -C "$MOCK_REPO" init --quiet
    git -C "$MOCK_REPO" config user.email "test@test.com"
    git -C "$MOCK_REPO" config user.name "Test User"

    # Create initial commit (needed for tags and dirty tree detection)
    echo "# Test Repo" > "$MOCK_REPO/README.md"
    git -C "$MOCK_REPO" add README.md
    git -C "$MOCK_REPO" commit -m "Initial commit" --quiet

    # Create stub logging functions if not defined
    if ! declare -f log_info &>/dev/null; then
        log_info() { :; }
        log_debug() { :; }
        log_warn() { :; }
        log_error() { echo "ERROR: $*" >&2; }
        log_ok() { :; }
        export -f log_info log_debug log_warn log_error log_ok
    fi
}

teardown() {
    harness_teardown
}

add_workspace_member() {
    local name="$1"
    local version="$2"
    local publish_line=""
    [[ "${3:-}" == "false" ]] && publish_line="publish = false"
    local member_dir="$MOCK_REPO/crates/$name"
    mkdir -p "$member_dir/src"
    cat > "$member_dir/Cargo.toml" << EOF
[package]
name = "$name"
version = "$version"
edition = "2021"
$publish_line

[lib]
path = "src/lib.rs"
EOF
    printf 'pub fn marker() {}\n' > "$member_dir/src/lib.rs"
}

lock_workspace() {
    cargo generate-lockfile --offline --manifest-path "$MOCK_REPO/Cargo.toml" >/dev/null
}

# ============================================================================
# Rust (Cargo.toml) Tests
# ============================================================================

@test "rust: detect version from Cargo.toml" {
    cat > "$MOCK_REPO/Cargo.toml" << 'EOF'
[package]
name = "test-tool"
version = "1.2.3"
edition = "2021"
EOF

    local version
    version=$(version_detect "$MOCK_REPO")

    assert_equal "1.2.3" "$version" "Should detect version from Cargo.toml"
}

@test "rust: detect version with spaces around =" {
    cat > "$MOCK_REPO/Cargo.toml" << 'EOF'
[package]
name = "test-tool"
version   =   "2.0.0"
edition = "2021"
EOF

    local version
    version=$(version_detect "$MOCK_REPO")

    assert_equal "2.0.0" "$version"
}

@test "rust: detect semver with prerelease" {
    cat > "$MOCK_REPO/Cargo.toml" << 'EOF'
[package]
version = "1.0.0-alpha.1"
EOF

    local version
    version=$(version_detect "$MOCK_REPO")

    assert_equal "1.0.0-alpha.1" "$version"
}

@test "rust: detect semver with build metadata" {
    cat > "$MOCK_REPO/Cargo.toml" << 'EOF'
[package]
version = "1.0.0+build.123"
EOF

    local version
    version=$(version_detect "$MOCK_REPO")

    assert_equal "1.0.0+build.123" "$version"
}

@test "rust: detect an inherited workspace package version" {
    cat > "$MOCK_REPO/Cargo.toml" << 'EOF'
[workspace]
members = ["crates/tool"]
resolver = "2"

[workspace.package]
version = "0.1.0"
EOF
    mkdir -p "$MOCK_REPO/crates/tool/src"
    cat > "$MOCK_REPO/crates/tool/Cargo.toml" << 'EOF'
[package]
name = "tool"
version.workspace = true
edition = "2021"

[lib]
path = "src/lib.rs"
EOF
    printf 'pub fn marker() {}\n' > "$MOCK_REPO/crates/tool/src/lib.rs"
    lock_workspace

    local version
    version=$(version_detect "$MOCK_REPO")

    assert_equal "0.1.0" "$version"
}

@test "rust: virtual workspace cannot fall through to unrelated package.json" {
    cat > "$MOCK_REPO/Cargo.toml" << 'EOF'
[workspace]
members = ["crates/core", "crates/cli"]
resolver = "2"
EOF
    add_workspace_member core 0.1.17
    add_workspace_member cli 0.1.17
    cat > "$MOCK_REPO/package.json" << 'EOF'
{
  "name": "website-tooling",
  "version": "1.0.0"
}
EOF
    lock_workspace

    run version_detect "$MOCK_REPO"

    assert_equal "0" "$status"
    assert_equal "0.1.17" "$output"
}

@test "rust: virtual workspace with no package version source fails closed" {
    cat > "$MOCK_REPO/Cargo.toml" << 'EOF'
[workspace]
members = []
resolver = "2"
EOF
    cat > "$MOCK_REPO/package.json" << 'EOF'
{
  "name": "unrelated-website",
  "version": "1.0.0"
}
EOF
    lock_workspace

    run version_detect "$MOCK_REPO"

    [[ "$status" -ne 0 ]]
    assert_contains "$output" "No Rust workspace package version source"
    [[ "$output" != *"1.0.0"* ]]
}

@test "rust: configured main package resolves a divergent virtual workspace" {
    cat > "$MOCK_REPO/Cargo.toml" << 'EOF'
[workspace]
members = ["crates/core", "crates/cli"]
resolver = "2"
EOF
    add_workspace_member core 0.4.0
    add_workspace_member cli 0.5.0
    lock_workspace

    run version_detect "$MOCK_REPO" rust cli

    assert_equal "0" "$status"
    assert_equal "0.5.0" "$output"
}

@test "rust: divergent publishable workspace fails closed without main package" {
    cat > "$MOCK_REPO/Cargo.toml" << 'EOF'
[workspace]
members = ["crates/core", "crates/cli"]
resolver = "2"
EOF
    add_workspace_member core 0.4.0
    add_workspace_member cli 0.5.0
    cat > "$MOCK_REPO/package.json" << 'EOF'
{"name":"unrelated","version":"9.9.9"}
EOF
    lock_workspace

    run version_detect "$MOCK_REPO"

    [[ "$status" -ne 0 ]]
    assert_contains "$output" "Ambiguous Rust workspace versions"
    [[ "$output" != *"9.9.9"* ]]
}

@test "rust: unpublished member version does not make release version ambiguous" {
    cat > "$MOCK_REPO/Cargo.toml" << 'EOF'
[workspace]
members = ["crates/core", "crates/internal"]
resolver = "2"
EOF
    add_workspace_member core 0.4.0
    add_workspace_member internal 9.9.9 false
    lock_workspace

    run version_detect "$MOCK_REPO"

    assert_equal "0" "$status"
    assert_equal "0.4.0" "$output"
}

@test "rust: tag creation refuses an ambiguous workspace" {
    cat > "$MOCK_REPO/Cargo.toml" << 'EOF'
[workspace]
members = ["crates/core", "crates/cli"]
resolver = "2"
EOF
    add_workspace_member core 0.4.0
    add_workspace_member cli 0.5.0
    lock_workspace

    run version_create_tag "$MOCK_REPO" --dry-run

    [[ "$status" -ne 0 ]]
    [[ "$output" != *"Would create tag"* ]]
}

# ============================================================================
# Node.js (package.json) Tests
# ============================================================================

@test "node: detect version from package.json" {
    cat > "$MOCK_REPO/package.json" << 'EOF'
{
  "name": "test-package",
  "version": "3.4.5",
  "main": "index.js"
}
EOF

    local version
    version=$(version_detect "$MOCK_REPO")

    assert_equal "3.4.5" "$version"
}

@test "node: detect version with private field" {
    cat > "$MOCK_REPO/package.json" << 'EOF'
{
  "name": "@scope/package",
  "version": "0.0.1",
  "private": true
}
EOF

    local version
    version=$(version_detect "$MOCK_REPO")

    assert_equal "0.0.1" "$version"
}

@test "node: handle version field not first" {
    cat > "$MOCK_REPO/package.json" << 'EOF'
{
  "name": "test",
  "description": "A test package",
  "version": "1.0.0",
  "dependencies": {}
}
EOF

    local version
    version=$(version_detect "$MOCK_REPO")

    assert_equal "1.0.0" "$version"
}

# ============================================================================
# Go (VERSION file, version.go) Tests
# ============================================================================

@test "go: detect version from VERSION file" {
    echo "1.5.0" > "$MOCK_REPO/VERSION"

    local version
    version=$(version_detect "$MOCK_REPO")

    assert_equal "1.5.0" "$version"
}

@test "go: detect version from VERSION file with v prefix" {
    echo "v2.0.0" > "$MOCK_REPO/VERSION"

    local version
    version=$(version_detect "$MOCK_REPO")

    # Should strip v prefix
    assert_equal "2.0.0" "$version"
}

@test "go: detect version from VERSION file with trailing newline" {
    printf "1.2.3\n" > "$MOCK_REPO/VERSION"

    local version
    version=$(version_detect "$MOCK_REPO")

    assert_equal "1.2.3" "$version"
}

@test "go: detect version from version.go" {
    cat > "$MOCK_REPO/version.go" << 'EOF'
package main

const Version = "4.0.0"
EOF

    local version
    version=$(version_detect "$MOCK_REPO")

    assert_equal "4.0.0" "$version"
}

@test "go: detect version from main.go" {
    cat > "$MOCK_REPO/main.go" << 'EOF'
package main

var version = "5.0.0"

func main() {
    println(version)
}
EOF

    local version
    version=$(version_detect "$MOCK_REPO")

    assert_equal "5.0.0" "$version"
}

@test "go: VERSION file takes priority over version.go" {
    echo "1.0.0" > "$MOCK_REPO/VERSION"
    cat > "$MOCK_REPO/version.go" << 'EOF'
package main
const Version = "2.0.0"
EOF

    local version
    version=$(version_detect "$MOCK_REPO")

    assert_equal "1.0.0" "$version" "VERSION file should take priority"
}

# ============================================================================
# Python (pyproject.toml) Tests
# ============================================================================

@test "python: detect version from pyproject.toml" {
    cat > "$MOCK_REPO/pyproject.toml" << 'EOF'
[project]
name = "test-package"
version = "0.1.0"
EOF

    local version
    version=$(version_detect "$MOCK_REPO")

    assert_equal "0.1.0" "$version"
}

@test "python: detect version from poetry pyproject.toml" {
    cat > "$MOCK_REPO/pyproject.toml" << 'EOF'
[tool.poetry]
name = "test-package"
version = "1.0.0"
description = "A test package"
EOF

    local version
    version=$(version_detect "$MOCK_REPO")

    assert_equal "1.0.0" "$version"
}

# ============================================================================
# Language Detection Priority Tests
# ============================================================================

@test "priority: Rust takes priority over Node" {
    cat > "$MOCK_REPO/Cargo.toml" << 'EOF'
[package]
version = "1.0.0"
EOF
    cat > "$MOCK_REPO/package.json" << 'EOF'
{"version": "2.0.0"}
EOF

    local version
    version=$(version_detect "$MOCK_REPO")

    assert_equal "1.0.0" "$version" "Rust should take priority"
}

@test "priority: Go takes priority over Node" {
    echo "1.5.0" > "$MOCK_REPO/VERSION"
    cat > "$MOCK_REPO/package.json" << 'EOF'
{"version": "2.0.0"}
EOF

    local version
    version=$(version_detect "$MOCK_REPO")

    assert_equal "1.5.0" "$version" "Go (VERSION) should take priority over Node"
}

@test "priority: specified language overrides auto-detect" {
    cat > "$MOCK_REPO/Cargo.toml" << 'EOF'
[package]
version = "1.0.0"
EOF
    cat > "$MOCK_REPO/package.json" << 'EOF'
{"version": "2.0.0"}
EOF

    local version
    version=$(version_detect "$MOCK_REPO" "node")

    assert_equal "2.0.0" "$version" "Specified language should override"
}

# ============================================================================
# Error Cases
# ============================================================================

@test "error: no version file returns failure" {
    # Empty repo with just README
    run version_detect "$MOCK_REPO"

    assert_equal "1" "$status" "Should return non-zero for no version"
}

@test "error: invalid repo path returns failure" {
    run version_detect "/nonexistent/path"

    assert_equal "1" "$status"
}

@test "error: invalid version format in Cargo.toml" {
    cat > "$MOCK_REPO/Cargo.toml" << 'EOF'
[package]
version = "not-a-version"
EOF

    run version_detect "$MOCK_REPO"

    assert_equal "1" "$status" "Invalid version format should fail"
}

@test "error: empty VERSION file" {
    touch "$MOCK_REPO/VERSION"

    run version_detect "$MOCK_REPO"

    assert_equal "1" "$status" "Empty VERSION file should fail"
}

# ============================================================================
# Tag Existence Tests
# ============================================================================

@test "tag: version_needs_tag returns 0 for untagged version" {
    cat > "$MOCK_REPO/Cargo.toml" << 'EOF'
[package]
version = "1.0.0"
EOF
    git -C "$MOCK_REPO" add Cargo.toml
    git -C "$MOCK_REPO" commit -m "Add Cargo.toml" --quiet

    assert_success version_needs_tag "$MOCK_REPO"
}

@test "tag: version_needs_tag returns 1 for already tagged version" {
    cat > "$MOCK_REPO/Cargo.toml" << 'EOF'
[package]
version = "1.0.0"
EOF
    git -C "$MOCK_REPO" add Cargo.toml
    git -C "$MOCK_REPO" commit -m "Add Cargo.toml" --quiet

    # Create the tag
    git -C "$MOCK_REPO" tag -a "v1.0.0" -m "Release 1.0.0"

    assert_failure version_needs_tag "$MOCK_REPO"
}

@test "tag: version_needs_tag returns 1 for no version file" {
    assert_failure version_needs_tag "$MOCK_REPO"
}

# ============================================================================
# Dirty Tree Detection Tests
# ============================================================================

@test "dirty: version_create_tag blocks on dirty tree" {
    cat > "$MOCK_REPO/Cargo.toml" << 'EOF'
[package]
version = "1.0.0"
EOF
    git -C "$MOCK_REPO" add Cargo.toml
    git -C "$MOCK_REPO" commit -m "Add Cargo.toml" --quiet

    # Make tree dirty
    echo "uncommitted" >> "$MOCK_REPO/README.md"

    run version_create_tag "$MOCK_REPO"

    assert_equal "1" "$status" "Should fail on dirty tree"
}

@test "dirty: version_create_tag succeeds on clean tree" {
    cat > "$MOCK_REPO/Cargo.toml" << 'EOF'
[package]
version = "2.0.0"
EOF
    git -C "$MOCK_REPO" add Cargo.toml
    git -C "$MOCK_REPO" commit -m "Add Cargo.toml" --quiet

    run version_create_tag "$MOCK_REPO"

    assert_equal "0" "$status" "Should succeed on clean tree"

    # Verify tag was created
    run git -C "$MOCK_REPO" show-ref --tags --verify "refs/tags/v2.0.0"
    assert_equal "0" "$status" "Tag should exist"
}

# ============================================================================
# Dry-Run Tests
# ============================================================================

@test "dry-run: version_create_tag --dry-run does not create tag" {
    cat > "$MOCK_REPO/Cargo.toml" << 'EOF'
[package]
version = "3.0.0"
EOF
    git -C "$MOCK_REPO" add Cargo.toml
    git -C "$MOCK_REPO" commit -m "Add Cargo.toml" --quiet

    run version_create_tag "$MOCK_REPO" --dry-run

    assert_equal "0" "$status" "Dry-run should succeed"

    # Verify tag was NOT created (git show-ref returns non-zero if not found)
    run git -C "$MOCK_REPO" show-ref --tags --verify "refs/tags/v3.0.0"
    [[ "$status" -ne 0 ]] || {
        echo "Tag should not exist after dry-run" >&2
        return 1
    }
}

@test "dry-run: allows dirty tree" {
    cat > "$MOCK_REPO/Cargo.toml" << 'EOF'
[package]
version = "4.0.0"
EOF
    git -C "$MOCK_REPO" add Cargo.toml
    git -C "$MOCK_REPO" commit -m "Add Cargo.toml" --quiet

    # Make tree dirty
    echo "uncommitted" >> "$MOCK_REPO/README.md"

    run version_create_tag "$MOCK_REPO" --dry-run

    assert_equal "0" "$status" "Dry-run should succeed even with dirty tree"
}

# ============================================================================
# JSON Output Tests
# ============================================================================

@test "json: version_info_json returns valid JSON" {
    cat > "$MOCK_REPO/Cargo.toml" << 'EOF'
[package]
version = "1.2.3"
EOF

    local json
    json=$(version_info_json "$MOCK_REPO")

    # Verify it's valid JSON
    echo "$json" | jq . >/dev/null 2>&1 || {
        echo "Invalid JSON: $json" >&2
        return 1
    }
}

@test "json: version_info_json has correct fields" {
    cat > "$MOCK_REPO/Cargo.toml" << 'EOF'
[package]
version = "1.2.3"
EOF
    git -C "$MOCK_REPO" add Cargo.toml
    git -C "$MOCK_REPO" commit -m "Add Cargo.toml" --quiet

    local json version tag needs_tag language
    json=$(version_info_json "$MOCK_REPO")

    version=$(echo "$json" | jq -r '.version')
    tag=$(echo "$json" | jq -r '.tag')
    needs_tag=$(echo "$json" | jq -r '.needs_tag')
    language=$(echo "$json" | jq -r '.language')

    assert_equal "1.2.3" "$version"
    assert_equal "v1.2.3" "$tag"
    assert_equal "true" "$needs_tag"
    assert_equal "rust" "$language"
}

@test "json: tag_exists is true when tag exists" {
    cat > "$MOCK_REPO/Cargo.toml" << 'EOF'
[package]
version = "5.0.0"
EOF
    git -C "$MOCK_REPO" add Cargo.toml
    git -C "$MOCK_REPO" commit -m "Add Cargo.toml" --quiet
    git -C "$MOCK_REPO" tag -a "v5.0.0" -m "Release"

    local json tag_exists needs_tag
    json=$(version_info_json "$MOCK_REPO")

    tag_exists=$(echo "$json" | jq -r '.tag_exists')
    needs_tag=$(echo "$json" | jq -r '.needs_tag')

    assert_equal "true" "$tag_exists"
    assert_equal "false" "$needs_tag"
}

# ============================================================================
# Edge Cases
# ============================================================================

@test "edge: version with many decimal places is accepted" {
    cat > "$MOCK_REPO/Cargo.toml" << 'EOF'
[package]
version = "1.2.3.4"
EOF

    # The regex ^[0-9]+\.[0-9]+\.[0-9]+ matches "1.2.3" portion
    # This is lenient - strictly it's not semver but we accept it
    local version
    version=$(version_detect "$MOCK_REPO")

    # Documents actual behavior: the full string is captured
    assert_equal "1.2.3.4" "$version"
}

@test "edge: version 0.0.0 is valid" {
    cat > "$MOCK_REPO/Cargo.toml" << 'EOF'
[package]
version = "0.0.0"
EOF

    local version
    version=$(version_detect "$MOCK_REPO")

    assert_equal "0.0.0" "$version"
}

@test "edge: large version numbers" {
    cat > "$MOCK_REPO/Cargo.toml" << 'EOF'
[package]
version = "999.888.777"
EOF

    local version
    version=$(version_detect "$MOCK_REPO")

    assert_equal "999.888.777" "$version"
}

@test "edge: idempotent tag creation" {
    cat > "$MOCK_REPO/Cargo.toml" << 'EOF'
[package]
version = "6.0.0"
EOF
    git -C "$MOCK_REPO" add Cargo.toml
    git -C "$MOCK_REPO" commit -m "Add Cargo.toml" --quiet

    # Create tag first time
    run version_create_tag "$MOCK_REPO"
    assert_equal "0" "$status"

    # Create tag second time (should succeed, not error)
    run version_create_tag "$MOCK_REPO"
    assert_equal "0" "$status" "Should be idempotent"
}
