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
echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed, $SKIP_COUNT skipped"
[[ $FAIL_COUNT -eq 0 ]] || exit 1
exit 0
