#!/usr/bin/env bash
# test_packaging.sh - Unit + regression tests for src/packaging.sh and the
# archive (re)packaging paths that consume it.
#
# Regression under test (mcp_agent_mail_rust v0.3.30/v0.3.31): when the
# configured archive_format (tar.xz) differed from the format the build
# produced (tar.gz), dsr wrapped the existing .tar.gz archive inside a fresh
# .tar.xz instead of building an independent .tar.xz of the payload, and
# include_files (README/LICENSE) could not be kept out of archives whose
# installers enforce an exact flat member contract.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SRC_DIR="$PROJECT_ROOT/src"

source "$SRC_DIR/packaging.sh"

# Colors
if [[ -z "${NO_COLOR:-}" ]]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[0;33m'
    NC=$'\033[0m'
else
    RED='' GREEN='' YELLOW='' NC=''
fi

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

log_pass() { echo -e "${GREEN}PASS${NC} $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
log_fail() { echo -e "${RED}FAIL${NC} $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }
log_skip() { echo -e "${YELLOW}SKIP${NC} $1"; SKIP_COUNT=$((SKIP_COUNT + 1)); }
log_test() { echo -e "\n== $1 =="; }

TEMP_DIR=$(mktemp -d)
trap 'rm -rf "$TEMP_DIR"' EXIT

sorted_members() {
    packaging_payload_members "$1" "$2"
}

make_payload() {
    # Creates a payload directory shaped like the mcp_agent_mail_rust
    # workspace collection: two executable binaries + two docs.
    local dir="$1"
    mkdir -p "$dir"
    printf 'fake-server-binary-bytes-%s\n' "$RANDOM" > "$dir/mcp-agent-mail"
    printf 'fake-cli-binary-bytes-%s\n' "$RANDOM" > "$dir/am"
    printf '# readme\n' > "$dir/README.md"
    printf 'license text\n' > "$dir/LICENSE"
    chmod 0755 "$dir/mcp-agent-mail" "$dir/am"
    chmod 0644 "$dir/README.md" "$dir/LICENSE"
}

# ---------------------------------------------------------------------------
log_test "packaging_format_for_name"

[[ "$(packaging_format_for_name foo.tar.gz)" == "tar.gz" ]] && \
    log_pass "tar.gz detected" || log_fail "tar.gz detected"
[[ "$(packaging_format_for_name foo.tgz)" == "tar.gz" ]] && \
    log_pass "tgz normalizes to tar.gz" || log_fail "tgz normalizes to tar.gz"
[[ "$(packaging_format_for_name foo.tar.xz)" == "tar.xz" ]] && \
    log_pass "tar.xz detected" || log_fail "tar.xz detected"
[[ "$(packaging_format_for_name foo.zip)" == "zip" ]] && \
    log_pass "zip detected" || log_fail "zip detected"
[[ "$(packaging_format_for_name mcp-agent-mail)" == "none" ]] && \
    log_pass "raw binary is none" || log_fail "raw binary is none"

# ---------------------------------------------------------------------------
log_test "packaging_member_is_safe"

packaging_member_is_safe "am" && \
    log_pass "flat member allowed" || log_fail "flat member allowed"
packaging_member_is_safe "docs/guide.md" && \
    log_pass "nested member allowed" || log_fail "nested member allowed"
packaging_member_is_safe "../escape" && \
    log_fail "dotdot rejected" || log_pass "dotdot rejected"
packaging_member_is_safe "/etc/passwd" && \
    log_fail "absolute rejected" || log_pass "absolute rejected"
packaging_member_is_safe "-flag" && \
    log_fail "leading dash rejected" || log_pass "leading dash rejected"
packaging_member_is_safe "a/../b" && \
    log_fail "interior dotdot rejected" || log_pass "interior dotdot rejected"

# ---------------------------------------------------------------------------
log_test "independent archives from one payload (tar.gz + tar.xz)"

PAYLOAD="$TEMP_DIR/payload"
make_payload "$PAYLOAD"

GZ="$TEMP_DIR/tool.tar.gz"
XZ="$TEMP_DIR/tool.tar.xz"

packaging_build_archive tar.gz "$GZ" "$PAYLOAD" mcp-agent-mail am README.md LICENSE && \
    log_pass "tar.gz built" || log_fail "tar.gz built"
packaging_build_archive tar.xz "$XZ" "$PAYLOAD" mcp-agent-mail am README.md LICENSE && \
    log_pass "tar.xz built" || log_fail "tar.xz built"

GZ_MEMBERS=$(sorted_members "$GZ" tar.gz)
XZ_MEMBERS=$(sorted_members "$XZ" tar.xz)
[[ -n "$GZ_MEMBERS" && "$GZ_MEMBERS" == "$XZ_MEMBERS" ]] && \
    log_pass "both formats carry identical payload members" || \
    log_fail "both formats carry identical payload members (gz='$GZ_MEMBERS' xz='$XZ_MEMBERS')"

case "$XZ_MEMBERS" in
    *".tar.gz"*) log_fail "tar.xz must not contain a tar.gz member (wrap bug)" ;;
    *) log_pass "tar.xz must not contain a tar.gz member (wrap bug)" ;;
esac

EXTRACT_XZ="$TEMP_DIR/extract-xz"
mkdir -p "$EXTRACT_XZ"
packaging_extract_payload "$XZ" tar.xz "$EXTRACT_XZ" && \
    log_pass "tar.xz payload extracts" || log_fail "tar.xz payload extracts"
cmp -s "$PAYLOAD/mcp-agent-mail" "$EXTRACT_XZ/mcp-agent-mail" && \
    log_pass "tar.xz binary bytes identical to payload" || \
    log_fail "tar.xz binary bytes identical to payload"
[[ -x "$EXTRACT_XZ/am" ]] && \
    log_pass "executable bit preserved through tar.xz" || \
    log_fail "executable bit preserved through tar.xz"

# ---------------------------------------------------------------------------
log_test "packaging_build_archive input validation"

packaging_build_archive tar.gz "$TEMP_DIR/bad.tar.gz" "$PAYLOAD" "../etc/passwd" 2>/dev/null && \
    log_fail "unsafe member refused" || log_pass "unsafe member refused"
packaging_build_archive tar.gz "$TEMP_DIR/bad2.tar.gz" "$PAYLOAD" "does-not-exist" 2>/dev/null && \
    log_fail "missing member refused" || log_pass "missing member refused"
packaging_build_archive tar.gz "$TEMP_DIR/bad3.tar.gz" "$PAYLOAD" 2>/dev/null && \
    log_fail "empty member list refused" || log_pass "empty member list refused"

# ---------------------------------------------------------------------------
log_test "packaging_repack_archive (the v0.3.31 regression shape)"

# The build produced a workspace tar.gz; the repo wants tar.xz as well.
# The old code path created a tar.xz WRAPPING the tar.gz. The fixed path
# must produce an independent tar.xz with the identical payload member set.
REPACK_XZ="$TEMP_DIR/mcp-agent-mail-x86_64-unknown-linux-gnu.tar.xz"
packaging_repack_archive "$GZ" tar.gz "$REPACK_XZ" tar.xz && \
    log_pass "repack tar.gz -> tar.xz succeeds" || log_fail "repack tar.gz -> tar.xz succeeds"

REPACK_MEMBERS=$(sorted_members "$REPACK_XZ" tar.xz)
[[ "$REPACK_MEMBERS" == "$GZ_MEMBERS" ]] && \
    log_pass "repacked tar.xz payload members match source tar.gz" || \
    log_fail "repacked tar.xz payload members match source tar.gz ('$REPACK_MEMBERS' vs '$GZ_MEMBERS')"

case "$REPACK_MEMBERS" in
    *".tar.gz"*) log_fail "repacked tar.xz does not wrap the tar.gz" ;;
    *) log_pass "repacked tar.xz does not wrap the tar.gz" ;;
esac

EXTRACT_REPACK="$TEMP_DIR/extract-repack"
mkdir -p "$EXTRACT_REPACK"
packaging_extract_payload "$REPACK_XZ" tar.xz "$EXTRACT_REPACK"
cmp -s "$PAYLOAD/am" "$EXTRACT_REPACK/am" && \
    log_pass "repacked binary bytes identical" || log_fail "repacked binary bytes identical"

packaging_repack_archive "$GZ" tar.gz "$GZ" tar.gz 2>/dev/null && \
    log_fail "repack refuses same source and destination" || \
    log_pass "repack refuses same source and destination"

# ---------------------------------------------------------------------------
log_test "transactional archive publication"

ATOMIC_DIR="$TEMP_DIR/atomic output"
mkdir -p "$ATOMIC_DIR"
printf 'previous release bytes\n' > "$ATOMIC_DIR/previous"
cp "$ATOMIC_DIR/previous" "$ATOMIC_DIR/release.tar.gz"

# Fault injection is limited to the compressor boundary; filesystem checks
# and publication run through the real packaging implementation.
if (
    tar() {
        if [[ "${1:-}" == "--no-xattrs" ]]; then
            printf 'partial archive\n' > "$3"
            return 42
        fi
        command tar "$@"
    }
    packaging_build_archive tar.gz "$ATOMIC_DIR/release.tar.gz" "$PAYLOAD" am
); then
    log_fail "compressor failure reported"
else
    [[ $? -eq 4 ]] && log_pass "compressor failure reported" || log_fail "compressor failure exit code"
fi
cmp -s "$ATOMIC_DIR/previous" "$ATOMIC_DIR/release.tar.gz" && \
    log_pass "compressor failure preserves previous release" || log_fail "compressor failure preserves previous release"

if (
    tar() {
        if [[ "${1:-}" == "--no-xattrs" ]]; then
            printf 'not an archive\n' > "$3"
            return 0
        fi
        command tar "$@"
    }
    packaging_build_archive tar.gz "$ATOMIC_DIR/release.tar.gz" "$PAYLOAD" am
); then
    log_fail "invalid compressor output refused"
else
    log_pass "invalid compressor output refused"
fi
cmp -s "$ATOMIC_DIR/previous" "$ATOMIC_DIR/release.tar.gz" && \
    log_pass "invalid output preserves previous release" || log_fail "invalid output preserves previous release"

cp "$ATOMIC_DIR/previous" "$ATOMIC_DIR/release.tar.xz"
if (
    packaging_build_archive() {
        # A valid archive with the wrong payload must not be promoted either.
        command tar -cJf "$2" -C "$3" am
    }
    packaging_repack_archive "$GZ" tar.gz "$ATOMIC_DIR/release.tar.xz" tar.xz
) 2>/dev/null; then
    log_fail "repack member mismatch refused"
else
    log_pass "repack member mismatch refused"
fi
cmp -s "$ATOMIC_DIR/previous" "$ATOMIC_DIR/release.tar.xz" && \
    log_pass "repack validation failure preserves previous release" || log_fail "repack validation failure preserves previous release"

ln -s "$ATOMIC_DIR/previous" "$ATOMIC_DIR/symlink.tar.gz"
if packaging_build_archive tar.gz "$ATOMIC_DIR/symlink.tar.gz" "$PAYLOAD" am; then
    log_fail "symlink destination refused"
else
    log_pass "symlink destination refused"
fi
if packaging_build_archive tar.gz "$PAYLOAD/am" "$PAYLOAD" am 2>/dev/null; then
    log_fail "payload cannot overwrite itself"
else
    log_pass "payload cannot overwrite itself"
fi

caller_trap=$(trap -p EXIT)
if packaging_build_archive tar.gz "$ATOMIC_DIR/release.tar.gz" "$PAYLOAD" am > "$ATOMIC_DIR/stdout"; then
    log_pass "successful archive atomically replaces previous release"
else
    log_fail "successful archive atomically replaces previous release"
fi
[[ ! -s "$ATOMIC_DIR/stdout" ]] && log_pass "packaging stdout stays clean" || log_fail "packaging stdout stays clean"
[[ "$(trap -p EXIT)" == "$caller_trap" ]] && log_pass "caller cleanup trap preserved" || log_fail "caller cleanup trap preserved"
[[ -z "$(find "$ATOMIC_DIR" -name '.dsr-*' -print)" ]] && \
    log_pass "staging directories cleaned after success and failure" || log_fail "staging directories cleaned after success and failure"

if command -v zip &>/dev/null && command -v unzip &>/dev/null; then
    packaging_build_archive zip "$ATOMIC_DIR/release.zip" "$PAYLOAD" am README.md && \
        log_pass "zip staged and published" || log_fail "zip staged and published"
    packaging_build_archive zip "$ATOMIC_DIR/release.zip" "$PAYLOAD" am && \
        log_pass "zip replaced with reduced member set" || log_fail "zip replaced with reduced member set"
    [[ "$(packaging_payload_members "$ATOMIC_DIR/release.zip" zip)" == "am" ]] && \
        log_pass "old zip entries cannot leak into new release" || log_fail "old zip entries cannot leak into new release"
else
    log_skip "zip tools unavailable for atomic zip tests"
fi

# ---------------------------------------------------------------------------
log_test "archive type and extraction boundary validation"

SAFE_DIR="$TEMP_DIR/safe-extraction"
mkdir -p "$SAFE_DIR/source/docs" "$SAFE_DIR/outside" "$SAFE_DIR/destination"
printf 'release payload\n' > "$SAFE_DIR/source/docs/payload"
printf 'do not touch\n' > "$SAFE_DIR/outside/payload"
cp "$SAFE_DIR/outside/payload" "$SAFE_DIR/expected"
ln -s "$SAFE_DIR/outside" "$SAFE_DIR/source/redirect"
tar -czf "$SAFE_DIR/link.tar.gz" -C "$SAFE_DIR/source" redirect docs/payload
if packaging_extract_payload "$SAFE_DIR/link.tar.gz" tar.gz "$SAFE_DIR/destination" 2>/dev/null; then
    log_fail "tar symlink rejected before extraction"
else
    [[ ! -e "$SAFE_DIR/destination/redirect" && ! -e "$SAFE_DIR/destination/docs" ]] && \
        log_pass "tar symlink rejected before extraction" || log_fail "tar symlink rejected before extraction"
fi

tar -czf "$SAFE_DIR/safe.tar.gz" -C "$SAFE_DIR/source" docs/payload
ln -s "$SAFE_DIR/outside" "$SAFE_DIR/destination/docs"
if packaging_extract_payload "$SAFE_DIR/safe.tar.gz" tar.gz "$SAFE_DIR/destination" 2>/dev/null; then
    log_fail "existing destination symlink rejected"
else
    log_pass "existing destination symlink rejected"
fi
cmp -s "$SAFE_DIR/expected" "$SAFE_DIR/outside/payload" && \
    log_pass "destination escape leaves outside file untouched" || log_fail "destination escape leaves outside file untouched"

mkdir -p "$SAFE_DIR/hard-destination/docs"
ln "$SAFE_DIR/outside/payload" "$SAFE_DIR/hard-destination/docs/payload"
if packaging_extract_payload "$SAFE_DIR/safe.tar.gz" tar.gz "$SAFE_DIR/hard-destination" 2>/dev/null; then
    log_fail "existing hardlinked destination file rejected"
else
    log_pass "existing hardlinked destination file rejected"
fi
cmp -s "$SAFE_DIR/expected" "$SAFE_DIR/outside/payload" && \
    log_pass "hardlink escape leaves outside file untouched" || log_fail "hardlink escape leaves outside file untouched"

ln "$SAFE_DIR/source/docs/payload" "$SAFE_DIR/source/hardlink"
tar -czf "$SAFE_DIR/hardlink.tar.gz" -C "$SAFE_DIR/source" docs/payload hardlink
if packaging_validate_archive "$SAFE_DIR/hardlink.tar.gz" tar.gz 2>/dev/null; then
    log_fail "tar hardlink rejected"
else
    log_pass "tar hardlink rejected"
fi
mkfifo "$SAFE_DIR/source/pipe"
tar -czf "$SAFE_DIR/fifo.tar.gz" -C "$SAFE_DIR/source" pipe
if packaging_validate_archive "$SAFE_DIR/fifo.tar.gz" tar.gz 2>/dev/null; then
    log_fail "FIFO rejected before extraction"
else
    log_pass "FIFO rejected before extraction"
fi
tar -czf "$SAFE_DIR/duplicate.tar.gz" -C "$SAFE_DIR/source" docs/payload docs/payload
if packaging_validate_archive "$SAFE_DIR/duplicate.tar.gz" tar.gz 2>/dev/null; then
    log_fail "duplicate members rejected"
else
    log_pass "duplicate members rejected"
fi
for unsafe in 'C:payload' 'docs\payload' $'docs/line\nbreak' $'docs/tab\tname'; do
    if packaging_member_is_safe "$unsafe"; then
        log_fail "nonportable path rejected"
    else
        log_pass "nonportable path rejected"
    fi
done

if command -v zip &>/dev/null && command -v unzip &>/dev/null; then
    (cd "$SAFE_DIR/source" && zip -q -y "$SAFE_DIR/link.zip" redirect docs/payload)
    if packaging_validate_archive "$SAFE_DIR/link.zip" zip 2>/dev/null; then
        log_fail "ZIP symlink rejected"
    else
        log_pass "ZIP symlink rejected"
    fi
fi

# ---------------------------------------------------------------------------
log_test "declared compression matches the archive container"
if packaging_validate_archive "$GZ" tar.xz 2>/dev/null; then
    log_fail "tar.gz rejected as tar.xz"
else
    log_pass "tar.gz rejected as tar.xz"
fi
if packaging_validate_archive "$XZ" tar.gz 2>/dev/null; then
    log_fail "tar.xz rejected as tar.gz"
else
    log_pass "tar.xz rejected as tar.gz"
fi

log_test "prebuilt reuse and byte-level payload parity"

PARITY_DIR="$TEMP_DIR/parity"
mkdir -p "$PARITY_DIR"
cp "$GZ" "$PARITY_DIR/original.gz"
if (
    packaging_build_archive() { return 99; }
    packaging_repack_archive "$GZ" tgz "$PARITY_DIR/copied.tar.gz" tar.gz
); then
    log_pass "same-format repack does not invoke compression"
else
    log_fail "same-format repack does not invoke compression"
fi
cmp -s "$GZ" "$PARITY_DIR/copied.tar.gz" && \
    log_pass "prebuilt compressed bytes preserved exactly" || log_fail "prebuilt compressed bytes preserved exactly"
ln "$PARITY_DIR/copied.tar.gz" "$PARITY_DIR/copied-inode"
packaging_repack_archive "$GZ" tar.gz "$PARITY_DIR/copied.tar.gz" tgz >/dev/null 2>&1 && \
    log_pass "same-format retry succeeds" || log_fail "same-format retry succeeds"
[[ "$PARITY_DIR/copied.tar.gz" -ef "$PARITY_DIR/copied-inode" ]] && \
    log_pass "same-format retry does not replace identical file" || log_fail "same-format retry does not replace identical file"

packaging_repack_archive "$GZ" tar.gz "$PARITY_DIR/converted.tar.xz" tar.xz
ln "$PARITY_DIR/converted.tar.xz" "$PARITY_DIR/converted-inode"
if (
    packaging_build_archive() { return 99; }
    packaging_repack_archive "$GZ" tar.gz "$PARITY_DIR/converted.tar.xz" tar.xz
) 2>/dev/null; then
    log_pass "cross-format retry reuses verified archive without compression"
else
    log_fail "cross-format retry reuses verified archive without compression"
fi
[[ "$PARITY_DIR/converted.tar.xz" -ef "$PARITY_DIR/converted-inode" ]] && \
    log_pass "cross-format retry preserves existing archive inode" || log_fail "cross-format retry preserves existing archive inode"

cp -R "$PAYLOAD" "$PARITY_DIR/build-payload"
packaging_build_archive tar.gz "$PARITY_DIR/built.tar.gz" "$PARITY_DIR/build-payload" am README.md
ln "$PARITY_DIR/built.tar.gz" "$PARITY_DIR/built-inode"
touch -t 202001010101 "$PARITY_DIR/build-payload/am"
if (
    tar() {
        [[ "${1:-}" != "--no-xattrs" ]] || return 99
        command tar "$@"
    }
    packaging_build_archive tar.gz "$PARITY_DIR/built.tar.gz" "$PARITY_DIR/build-payload" am README.md
) 2>/dev/null; then
    log_pass "metadata-only source changes do not force recompression"
else
    log_fail "metadata-only source changes do not force recompression"
fi
[[ "$PARITY_DIR/built.tar.gz" -ef "$PARITY_DIR/built-inode" ]] && \
    log_pass "idempotent archive build preserves original bytes and inode" || log_fail "idempotent archive build preserves original bytes and inode"

printf 'changed binary bytes\n' > "$PARITY_DIR/build-payload/am"
packaging_build_archive tar.gz "$PARITY_DIR/built.tar.gz" "$PARITY_DIR/build-payload" am README.md && \
    log_pass "changed binary invalidates prebuilt reuse" || log_fail "changed binary invalidates prebuilt reuse"
[[ ! "$PARITY_DIR/built.tar.gz" -ef "$PARITY_DIR/built-inode" ]] && \
    log_pass "changed payload publishes a new archive" || log_fail "changed payload publishes a new archive"

ln "$PARITY_DIR/built.tar.gz" "$PARITY_DIR/before-mode-change"
chmod 0644 "$PARITY_DIR/build-payload/am"
if packaging_build_archive tar.gz "$PARITY_DIR/built.tar.gz" "$PARITY_DIR/build-payload" am README.md && \
   [[ ! "$PARITY_DIR/built.tar.gz" -ef "$PARITY_DIR/before-mode-change" ]]; then
    log_pass "executable-only change invalidates prebuilt reuse"
else
    log_fail "executable-only change invalidates prebuilt reuse"
fi

cp -R "$PAYLOAD" "$PARITY_DIR/wrong-bytes"
printf 'corrupt binary\n' > "$PARITY_DIR/wrong-bytes/am"
cp -R "$PAYLOAD" "$PARITY_DIR/wrong-mode"
chmod 0644 "$PARITY_DIR/wrong-mode/am"
mkdir -p "$PARITY_DIR/prior-payload"
printf 'prior binary bytes\n' > "$PARITY_DIR/prior-payload/am"
chmod 0755 "$PARITY_DIR/prior-payload/am"
packaging_build_archive tar.xz "$PARITY_DIR/prior.tar.xz" "$PARITY_DIR/prior-payload" am
for mismatch in wrong-bytes wrong-mode; do
    cp "$PARITY_DIR/prior.tar.xz" "$PARITY_DIR/protected.tar.xz"
    ln "$PARITY_DIR/protected.tar.xz" "$PARITY_DIR/protected-inode-$mismatch"
    marker="$PARITY_DIR/invoked-$mismatch"
    if (
        packaging_build_archive() {
            touch "$marker"
            command tar -cJf "$2" -C "$PARITY_DIR/$mismatch" am mcp-agent-mail README.md LICENSE
        }
        packaging_repack_archive "$GZ" tar.gz "$PARITY_DIR/protected.tar.xz" tar.xz
    ) 2>/dev/null; then
        log_fail "same-name $mismatch output refused"
    else
        log_pass "same-name $mismatch output refused"
    fi
    [[ -f "$marker" ]] && \
        log_pass "$mismatch compressor actually invoked" || log_fail "$mismatch compressor actually invoked"
    cmp -s "$PARITY_DIR/prior.tar.xz" "$PARITY_DIR/protected.tar.xz" && \
        log_pass "$mismatch failure preserves previous artifact" || log_fail "$mismatch failure preserves previous artifact"
    [[ "$PARITY_DIR/protected.tar.xz" -ef "$PARITY_DIR/protected-inode-$mismatch" ]] && \
        log_pass "$mismatch failure preserves previous artifact inode" || log_fail "$mismatch failure preserves previous artifact inode"
done

mkdir -p "$PARITY_DIR/nested/docs"
printf 'nested file\n' > "$PARITY_DIR/nested/docs/guide with spaces"
for format in tar.gz tar.xz zip; do
    if [[ "$format" == "zip" ]] && ! command -v zip &>/dev/null; then
        log_skip "zip unavailable for nested parity"
        continue
    fi
    if packaging_build_archive "$format" "$PARITY_DIR/nested.$format" "$PARITY_DIR/nested" docs; then
        [[ "$(packaging_payload_members "$PARITY_DIR/nested.$format" "$format")" == 'docs/guide with spaces' ]] && \
            log_pass "$format recursively includes selected directory payload" || log_fail "$format recursively includes selected directory payload"
    else
        log_fail "$format recursively includes selected directory payload"
    fi
done

ln -s "$PARITY_DIR/original.gz" "$PARITY_DIR/nested/docs/link"
if packaging_build_archive zip "$PARITY_DIR/linked.zip" "$PARITY_DIR/nested" docs 2>/dev/null; then
    log_fail "directory selection cannot follow a nested symlink"
else
    log_pass "directory selection cannot follow a nested symlink"
fi

mkdir "$PARITY_DIR/restrictive"
if (umask 077; packaging_extract_payload "$GZ" tar.gz "$PARITY_DIR/restrictive"); then
    [[ "$(_pkg_executable_bits "$PARITY_DIR/restrictive/am")" == "$(_pkg_executable_bits "$PAYLOAD/am")" ]] && \
        log_pass "restrictive caller umask does not strip executable bits" || log_fail "restrictive caller umask does not strip executable bits"
else
    log_fail "restrictive caller umask does not strip executable bits"
fi

if command -v zip &>/dev/null && command -v unzip &>/dev/null; then
    for format in tar.gz tar.xz zip; do
        packaging_build_archive "$format" "$PARITY_DIR/source.$format" "$PAYLOAD" am mcp-agent-mail README.md LICENSE
    done
    for src_format in tar.gz tar.xz zip; do
        for dest_format in tar.gz tar.xz zip; do
            [[ "$src_format" != "$dest_format" ]] || continue
            if packaging_repack_archive "$PARITY_DIR/source.$src_format" "$src_format" \
                "$PARITY_DIR/converted-$src_format.$dest_format" "$dest_format"; then
                log_pass "$src_format to $dest_format verified conversion"
            else
                log_fail "$src_format to $dest_format verified conversion"
            fi
        done
    done
    if (
        command() {
            if [[ "${1:-}" == "-v" && "${2:-}" == "unzip" ]]; then
                return 1
            fi
            builtin command "$@"
        }
        packaging_repack_archive "$PARITY_DIR/source.zip" zip "$PARITY_DIR/no-unzip.tar.gz" tar.gz
    ); then
        log_fail "missing source dependency reported"
    else
        [[ $? -eq 3 ]] && log_pass "missing source dependency exit code preserved" || log_fail "missing source dependency exit code preserved"
    fi
fi

# ---------------------------------------------------------------------------
log_test "packaging_include_files_in_archives flag"

FLAG_DIR="$TEMP_DIR/flags"
mkdir -p "$FLAG_DIR"
printf 'tool_name: t\ninclude_files:\n  - README.md\n' > "$FLAG_DIR/default.yaml"
printf 'tool_name: t\ninclude_extra_files: false\ninclude_files:\n  - README.md\n' > "$FLAG_DIR/optout.yaml"
printf 'tool_name: t\nflat_archive: true\ninclude_files:\n  - README.md\n' > "$FLAG_DIR/flat.yaml"

if command -v yq &>/dev/null; then
    [[ "$(packaging_include_files_in_archives "$FLAG_DIR/default.yaml")" == "true" ]] && \
        log_pass "default keeps include_files in archives" || \
        log_fail "default keeps include_files in archives"
    [[ "$(packaging_include_files_in_archives "$FLAG_DIR/optout.yaml")" == "false" ]] && \
        log_pass "include_extra_files: false disables extras" || \
        log_fail "include_extra_files: false disables extras"
    [[ "$(packaging_include_files_in_archives "$FLAG_DIR/flat.yaml")" == "false" ]] && \
        log_pass "flat_archive: true disables extras" || \
        log_fail "flat_archive: true disables extras"
    [[ "$(packaging_include_files_in_archives "$FLAG_DIR/missing.yaml")" == "true" ]] && \
        log_pass "missing config defaults to true" || \
        log_fail "missing config defaults to true"
else
    log_skip "yq not available for include-files flag tests"
fi

# ---------------------------------------------------------------------------
log_test "act_runner include_files gating"

if command -v yq &>/dev/null; then
    # act_runner needs its own logging shims when sourced standalone.
    declare -F _log_error &>/dev/null || _log_error() { :; }
    declare -F _log_warn &>/dev/null || _log_warn() { :; }
    declare -F _log_info &>/dev/null || _log_info() { :; }
    declare -F _log_ok &>/dev/null || _log_ok() { :; }
    declare -F log_error &>/dev/null || log_error() { :; }
    declare -F log_warn &>/dev/null || log_warn() { :; }
    declare -F log_info &>/dev/null || log_info() { :; }
    source "$SRC_DIR/act_runner.sh" 2>/dev/null

    [[ "$(_act_include_files_in_archives "$FLAG_DIR/default.yaml")" == "true" ]] && \
        log_pass "_act flag reader: default true" || log_fail "_act flag reader: default true"
    [[ "$(_act_include_files_in_archives "$FLAG_DIR/optout.yaml")" == "false" ]] && \
        log_pass "_act flag reader: include_extra_files false" || \
        log_fail "_act flag reader: include_extra_files false"
    [[ "$(_act_include_files_in_archives "$FLAG_DIR/flat.yaml")" == "false" ]] && \
        log_pass "_act flag reader: flat_archive true" || \
        log_fail "_act flag reader: flat_archive true"

    STAGE_SRC="$TEMP_DIR/stage-src"
    STAGE_ART_ON="$TEMP_DIR/stage-art-on"
    STAGE_ART_OFF="$TEMP_DIR/stage-art-off"
    mkdir -p "$STAGE_SRC" "$STAGE_ART_ON" "$STAGE_ART_OFF"
    printf '# readme\n' > "$STAGE_SRC/README.md"

    staged_on=$(_act_stage_workspace_include_files \
        "$FLAG_DIR/default.yaml" "$STAGE_SRC" "$STAGE_ART_ON" "")
    if [[ "$staged_on" == "README.md" && -f "$STAGE_ART_ON/README.md" ]]; then
        log_pass "include staging still works when enabled"
    else
        log_fail "include staging still works when enabled (staged='$staged_on')"
    fi

    staged_off=$(_act_stage_workspace_include_files \
        "$FLAG_DIR/optout.yaml" "$STAGE_SRC" "$STAGE_ART_OFF" "")
    stage_off_rc=$?
    if [[ $stage_off_rc -eq 0 && -z "$staged_off" && ! -e "$STAGE_ART_OFF/README.md" ]]; then
        log_pass "flat-archive repo stages no extras"
    else
        log_fail "flat-archive repo stages no extras (rc=$stage_off_rc staged='$staged_off')"
    fi
else
    log_skip "yq not available for act_runner gating tests"
fi

# ---------------------------------------------------------------------------
log_test "dsr _build_package_archive_for_target regression (extracted)"

# Extract the real nested function from the dsr entrypoint so the regression
# is tested against production code, not a copy.
EXTRACTED="$TEMP_DIR/extracted_build_package_archive_for_target.sh"
awk '/^    _build_package_archive_for_target\(\) \{/{flag=1} flag{print} flag && /^    \}$/ && !/_build_package_archive_for_target/{exit}' \
    "$PROJECT_ROOT/dsr" > "$EXTRACTED"

if ! bash -n "$EXTRACTED" 2>/dev/null || ! grep -q "packaging_repack_archive" "$EXTRACTED"; then
    log_fail "extract _build_package_archive_for_target from dsr"
else
    log_pass "extract _build_package_archive_for_target from dsr"

    run_build_package_for_target() {
        # $1 = configured archive format, $2 = artifact (override) path,
        # $3 = output dir, $4 = versioned name for that format
        local cfg_format="$1" override="$2" outdir="$3" versioned="$4"
        (
            set -uo pipefail
            log_info() { :; }
            log_warn() { :; }
            log_error() { echo "ERR: $*" >&2; }
            declare -A existing_archive_formats=()
            # Read by the production function sourced from EXTRACTED below.
            # shellcheck disable=SC2034
            existing_archive_formats["linux/amd64"]="tar.gz"
            _build_get_archive_format() { echo "$cfg_format"; }
            _build_detect_compat_ext() { echo ""; }
            _build_detect_install_ext() { return 0; }
            _build_find_binary() { return 0; }
            _build_get_include_files() { printf 'README.md\nLICENSE\n'; }
            _build_is_archive_ext() {
                case "$1" in
                    *.tar.gz|*.tgz|*.tar.xz|*.zip) return 0 ;;
                    *) return 1 ;;
                esac
            }
            artifact_naming_generate_dual_for_tool() {
                printf '{"versioned":"%s","compat":"%s"}\n' "$versioned" "$versioned"
            }
            _build_manifest_add_entry() {
                printf '%s\t%s\t%s\n' "$(basename "$1")" "$2" "$3" >> "$outdir/manifest_calls.tsv"
            }
            _build_emit_compat_alias() { :; }
            _build_emit_binary_alias() { :; }
            source "$PROJECT_ROOT/src/packaging.sh"
            # The production function is extracted and syntax-checked above.
            # shellcheck disable=SC1090
            source "$EXTRACTED"
            _build_package_archive_for_target "mcp-agent-mail" "0.3.31" "linux/amd64" \
                "$outdir" "" "mcp-agent-mail" "$override"
        )
    }

    # Scenario: the native build already produced the workspace tar.gz;
    # the repo config asks for tar.xz. Before the fix this wrapped the
    # tar.gz inside the tar.xz.
    DSR_OUT="$TEMP_DIR/dsr-out"
    mkdir -p "$DSR_OUT"
    BUILT_GZ="$DSR_OUT/mcp-agent-mail-x86_64-unknown-linux-gnu.tar.gz"
    cp "$GZ" "$BUILT_GZ"

    if run_build_package_for_target "tar.xz" "$BUILT_GZ" "$DSR_OUT" \
        "mcp-agent-mail-x86_64-unknown-linux-gnu.tar.xz"; then
        log_pass "packager runs on archive input"
    else
        log_fail "packager runs on archive input"
    fi

    PRODUCED_XZ="$DSR_OUT/mcp-agent-mail-x86_64-unknown-linux-gnu.tar.xz"
    if [[ -f "$PRODUCED_XZ" ]]; then
        log_pass "tar.xz asset produced"
        PROD_MEMBERS=$(sorted_members "$PRODUCED_XZ" tar.xz)
        SRC_MEMBERS=$(sorted_members "$BUILT_GZ" tar.gz)
        [[ -n "$PROD_MEMBERS" && "$PROD_MEMBERS" == "$SRC_MEMBERS" ]] && \
            log_pass "dsr tar.xz payload members identical to tar.gz" || \
            log_fail "dsr tar.xz payload members identical to tar.gz ('$PROD_MEMBERS' vs '$SRC_MEMBERS')"
        case "$PROD_MEMBERS" in
            *".tar.gz"*) log_fail "dsr tar.xz does not wrap the built tar.gz" ;;
            *) log_pass "dsr tar.xz does not wrap the built tar.gz" ;;
        esac
        grep -q "tar.xz" "$DSR_OUT/manifest_calls.tsv" 2>/dev/null && \
            log_pass "tar.xz recorded in manifest entries" || \
            log_fail "tar.xz recorded in manifest entries"
    else
        log_fail "tar.xz asset produced"
    fi

    # Same-format input must be left alone (no re-archiving, no wrap).
    DSR_OUT2="$TEMP_DIR/dsr-out2"
    mkdir -p "$DSR_OUT2"
    BUILT_GZ2="$DSR_OUT2/mcp-agent-mail-x86_64-unknown-linux-gnu.tar.gz"
    cp "$GZ" "$BUILT_GZ2"
    before_sha=$(shasum -a 256 "$BUILT_GZ2" | awk '{print $1}')
    run_build_package_for_target "tar.gz" "$BUILT_GZ2" "$DSR_OUT2" \
        "mcp-agent-mail-x86_64-unknown-linux-gnu.tar.gz" >/dev/null 2>&1
    after_sha=$(shasum -a 256 "$BUILT_GZ2" | awk '{print $1}')
    if [[ "$before_sha" == "$after_sha" ]]; then
        log_pass "same-format archive input is not re-wrapped"
    else
        log_fail "same-format archive input is not re-wrapped"
    fi
fi

# ---------------------------------------------------------------------------
log_test "packaging_repack_archive stages configured include_files (GH#16)"

# The native staging lane wraps a lone binary into an archive; the repack
# must be able to add README/LICENSE style includes from the repo checkout
# instead of preserving the thinner member set silently.
INC_DIR="$TEMP_DIR/include-root"
INC_PAYLOAD="$TEMP_DIR/lone-payload"
mkdir -p "$INC_DIR" "$INC_PAYLOAD"
printf 'fake-rano-binary-%s\n' "$RANDOM" > "$INC_PAYLOAD/rano"
chmod 0755 "$INC_PAYLOAD/rano"
printf 'MIT license text\n' > "$INC_DIR/LICENSE"
printf '# rano\n' > "$INC_DIR/README.md"
chmod 0644 "$INC_DIR/LICENSE" "$INC_DIR/README.md"
LONE_GZ="$TEMP_DIR/rano-lone.tar.gz"
packaging_build_archive tar.gz "$LONE_GZ" "$INC_PAYLOAD" rano
[[ "$(sorted_members "$LONE_GZ" tar.gz)" == "rano" ]] && \
    log_pass "lone-binary fixture archive contains only the binary" || \
    log_fail "lone-binary fixture archive contains only the binary"

INC_XZ="$TEMP_DIR/rano-with-includes.tar.xz"
if packaging_repack_archive "$LONE_GZ" tar.gz "$INC_XZ" tar.xz "$INC_DIR" LICENSE README.md; then
    log_pass "repack with includes succeeds"
else
    log_fail "repack with includes succeeds"
fi
INC_MEMBERS=$(sorted_members "$INC_XZ" tar.xz 2>/dev/null)
EXPECTED_INC_MEMBERS=$(printf 'LICENSE\nREADME.md\nrano\n')
[[ "$INC_MEMBERS" == "$EXPECTED_INC_MEMBERS" ]] && \
    log_pass "repacked archive carries binary plus includes" || \
    log_fail "repacked archive carries binary plus includes ('$INC_MEMBERS')"
INC_EXTRACT="$TEMP_DIR/extract-includes"
mkdir -p "$INC_EXTRACT"
packaging_extract_payload "$INC_XZ" tar.xz "$INC_EXTRACT"
cmp -s "$INC_DIR/LICENSE" "$INC_EXTRACT/LICENSE" && cmp -s "$INC_PAYLOAD/rano" "$INC_EXTRACT/rano" && \
    log_pass "include and binary bytes preserved" || log_fail "include and binary bytes preserved"
[[ -x "$INC_EXTRACT/rano" && ! -x "$INC_EXTRACT/LICENSE" ]] && \
    log_pass "executable bits: binary kept, include not executable" || \
    log_fail "executable bits: binary kept, include not executable"

# Same-format repack with includes must rebuild rather than byte-copy.
INC_SAME="$TEMP_DIR/rano-same-format.tar.gz"
packaging_repack_archive "$LONE_GZ" tar.gz "$INC_SAME" tar.gz "$INC_DIR" LICENSE
[[ "$(sorted_members "$INC_SAME" tar.gz 2>/dev/null)" == "$(printf 'LICENSE\nrano\n')" ]] && \
    log_pass "same-format repack with includes rebuilds the archive" || \
    log_fail "same-format repack with includes rebuilds the archive"

# A verified destination that already carries the includes is reused.
before_inc_sha=$(shasum -a 256 "$INC_XZ" | awk '{print $1}')
packaging_repack_archive "$LONE_GZ" tar.gz "$INC_XZ" tar.xz "$INC_DIR" LICENSE README.md >/dev/null 2>&1
after_inc_sha=$(shasum -a 256 "$INC_XZ" | awk '{print $1}')
[[ "$before_inc_sha" == "$after_inc_sha" ]] && \
    log_pass "destination already carrying includes is reused unchanged" || \
    log_fail "destination already carrying includes is reused unchanged"

# Includes may never shadow a payload member, escape the root, or be links.
packaging_repack_archive "$LONE_GZ" tar.gz "$TEMP_DIR/bad-inc1.tar.xz" tar.xz "$INC_PAYLOAD" rano 2>/dev/null && \
    log_fail "include colliding with payload member refused" || \
    log_pass "include colliding with payload member refused"
packaging_repack_archive "$LONE_GZ" tar.gz "$TEMP_DIR/bad-inc2.tar.xz" tar.xz "$INC_DIR" ../LICENSE 2>/dev/null && \
    log_fail "include escaping the root refused" || log_pass "include escaping the root refused"
packaging_repack_archive "$LONE_GZ" tar.gz "$TEMP_DIR/bad-inc3.tar.xz" tar.xz "$INC_DIR" MISSING 2>/dev/null && \
    log_fail "missing include refused" || log_pass "missing include refused"
ln -s LICENSE "$INC_DIR/LINKED"
packaging_repack_archive "$LONE_GZ" tar.gz "$TEMP_DIR/bad-inc4.tar.xz" tar.xz "$INC_DIR" LINKED 2>/dev/null && \
    log_fail "symlink include refused" || log_pass "symlink include refused"
packaging_repack_archive "$LONE_GZ" tar.gz "$TEMP_DIR/bad-inc5.tar.xz" tar.xz "" LICENSE 2>/dev/null && \
    log_fail "empty include root refused" || log_pass "empty include root refused"
for bad in "$TEMP_DIR"/bad-inc*.tar.xz; do
    [[ -e "$bad" ]] && log_fail "refused repack left no artifact ($(basename "$bad"))"
done
ls "$TEMP_DIR"/.dsr-repack.* >/dev/null 2>&1 && \
    log_fail "refused repacks leave no workdir behind" || log_pass "refused repacks leave no workdir behind"

# ---------------------------------------------------------------------------
log_test "dsr packager adds missing include_files on the lone-binary lane (GH#16)"

if [[ -f "$EXTRACTED" ]] && bash -n "$EXTRACTED" 2>/dev/null; then
    run_build_package_with_repo() {
        # $1 = configured format, $2 = artifact path, $3 = output dir,
        # $4 = versioned name, $5 = repo_path, $6 = warn log file
        local cfg_format="$1" override="$2" outdir="$3" versioned="$4" repo="$5" warnlog="$6"
        (
            set -uo pipefail
            log_info() { :; }
            log_warn() { echo "$*" >> "$warnlog"; }
            log_error() { echo "ERR: $*" >&2; }
            declare -A existing_archive_formats=()
            # shellcheck disable=SC2034
            existing_archive_formats["linux/amd64"]="tar.gz"
            _build_get_archive_format() { echo "$cfg_format"; }
            _build_detect_compat_ext() { echo ""; }
            _build_detect_install_ext() { return 0; }
            _build_find_binary() { return 0; }
            _build_get_include_files() { printf 'LICENSE\nREADME.md\nCHANGELOG.md\n'; }
            _build_is_archive_ext() {
                case "$1" in
                    *.tar.gz|*.tgz|*.tar.xz|*.zip) return 0 ;;
                    *) return 1 ;;
                esac
            }
            artifact_naming_generate_dual_for_tool() {
                printf '{"versioned":"%s","compat":"%s"}\n' "$versioned" "$versioned"
            }
            _build_manifest_add_entry() { :; }
            _build_emit_compat_alias() { :; }
            _build_emit_binary_alias() { :; }
            source "$PROJECT_ROOT/src/packaging.sh"
            # shellcheck disable=SC1090
            source "$EXTRACTED"
            _build_package_archive_for_target "rano" "0.2.1" "linux/amd64" \
                "$outdir" "$repo" "rano" "$override"
        )
    }

    # The rano v0.2.1 shape: lane produced a lone-binary tar.gz, config wants
    # tar.xz, LICENSE and README.md exist in the checkout, CHANGELOG.md does
    # not (must warn, not fail).
    RANO_OUT="$TEMP_DIR/rano-out"
    mkdir -p "$RANO_OUT"
    RANO_GZ="$RANO_OUT/rano-lone.tar.gz"
    cp "$LONE_GZ" "$RANO_GZ"
    RANO_WARN="$RANO_OUT/warnings.log"
    : > "$RANO_WARN"
    run_build_package_with_repo "tar.xz" "$RANO_GZ" "$RANO_OUT" \
        "rano-0.2.1-x86_64-unknown-linux-gnu.tar.xz" "$INC_DIR" "$RANO_WARN" >/dev/null 2>&1
    RANO_XZ="$RANO_OUT/rano-0.2.1-x86_64-unknown-linux-gnu.tar.xz"
    [[ "$(sorted_members "$RANO_XZ" tar.xz 2>/dev/null)" == "$EXPECTED_INC_MEMBERS" ]] && \
        log_pass "lone-binary tar.gz -> tar.xz gains LICENSE and README.md" || \
        log_fail "lone-binary tar.gz -> tar.xz gains LICENSE and README.md ('$(sorted_members "$RANO_XZ" tar.xz 2>/dev/null)')"
    grep -q "Include file not found for rano: CHANGELOG.md" "$RANO_WARN" && \
        log_pass "missing configured include is warned about" || \
        log_fail "missing configured include is warned about"

    # Same-format lane archive already occupying the release name: bytes are
    # left alone (receipts may bind to them) but the omission is reported.
    RANO_OUT2="$TEMP_DIR/rano-out2"
    mkdir -p "$RANO_OUT2"
    RANO_GZ2="$RANO_OUT2/rano-0.2.1-x86_64-unknown-linux-gnu.tar.gz"
    cp "$LONE_GZ" "$RANO_GZ2"
    RANO_WARN2="$RANO_OUT2/warnings.log"
    : > "$RANO_WARN2"
    before_rano_sha=$(shasum -a 256 "$RANO_GZ2" | awk '{print $1}')
    run_build_package_with_repo "tar.gz" "$RANO_GZ2" "$RANO_OUT2" \
        "rano-0.2.1-x86_64-unknown-linux-gnu.tar.gz" "$INC_DIR" "$RANO_WARN2" >/dev/null 2>&1
    after_rano_sha=$(shasum -a 256 "$RANO_GZ2" | awk '{print $1}')
    [[ "$before_rano_sha" == "$after_rano_sha" ]] && \
        log_pass "same-format release-named archive is not mutated" || \
        log_fail "same-format release-named archive is not mutated"
    grep -q "lacks configured include_files: LICENSE README.md" "$RANO_WARN2" && \
        log_pass "same-format omission is reported loudly" || \
        log_fail "same-format omission is reported loudly"

    # Same-format lane archive under a non-release name is rebuilt with the
    # includes into the release name.
    RANO_OUT3="$TEMP_DIR/rano-out3"
    mkdir -p "$RANO_OUT3"
    RANO_GZ3="$RANO_OUT3/rano-lone.tar.gz"
    cp "$LONE_GZ" "$RANO_GZ3"
    RANO_WARN3="$RANO_OUT3/warnings.log"
    : > "$RANO_WARN3"
    run_build_package_with_repo "tar.gz" "$RANO_GZ3" "$RANO_OUT3" \
        "rano-0.2.1-x86_64-unknown-linux-gnu.tar.gz" "$INC_DIR" "$RANO_WARN3" >/dev/null 2>&1
    [[ "$(sorted_members "$RANO_OUT3/rano-0.2.1-x86_64-unknown-linux-gnu.tar.gz" tar.gz 2>/dev/null)" == "$EXPECTED_INC_MEMBERS" ]] && \
        log_pass "same-format lane archive is rebuilt with includes under the release name" || \
        log_fail "same-format lane archive is rebuilt with includes under the release name"

    # Unresolved local_path with configured includes: warn, never silent.
    RANO_OUT4="$TEMP_DIR/rano-out4"
    mkdir -p "$RANO_OUT4"
    RANO_GZ4="$RANO_OUT4/rano-lone.tar.gz"
    cp "$LONE_GZ" "$RANO_GZ4"
    RANO_WARN4="$RANO_OUT4/warnings.log"
    : > "$RANO_WARN4"
    run_build_package_with_repo "tar.xz" "$RANO_GZ4" "$RANO_OUT4" \
        "rano-0.2.1-x86_64-unknown-linux-gnu.tar.xz" "" "$RANO_WARN4" >/dev/null 2>&1
    grep -q "local_path is unresolved" "$RANO_WARN4" && \
        log_pass "unresolved local_path with include_files is warned about" || \
        log_fail "unresolved local_path with include_files is warned about"
    [[ "$(sorted_members "$RANO_OUT4/rano-0.2.1-x86_64-unknown-linux-gnu.tar.xz" tar.xz 2>/dev/null)" == "rano" ]] && \
        log_pass "unresolved local_path still produces the payload-only archive" || \
        log_fail "unresolved local_path still produces the payload-only archive"
else
    log_skip "dsr include_files packager scenarios (extraction unavailable)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed, $SKIP_COUNT skipped"
[[ $FAIL_COUNT -eq 0 ]] || exit 1
exit 0
