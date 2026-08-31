#!/usr/bin/env bash
# packaging.sh - independent archive construction helpers
#
# Regression context (mcp_agent_mail_rust v0.3.30/v0.3.31): when a repo's
# configured archive_format (tar.xz) differed from the format the build
# actually produced (the native workspace collector hardcodes tar.gz), the
# post-build packager treated the existing .tar.gz ARCHIVE as if it were the
# raw binary and wrapped it inside a fresh .tar.xz (plus include_files).
# Installers that enforce an exact flat member set then failed, and every
# archive had to be repacked by hand.
#
# The invariant this module enforces: every output archive format is built
# independently from an extracted payload directory. An archive is NEVER a
# member of another archive.

_pkg_log_error() {
    if declare -F log_error &>/dev/null; then
        log_error "$@"
    else
        echo "ERROR: $*" >&2
    fi
}

_pkg_log_warn() {
    if declare -F log_warn &>/dev/null; then
        log_warn "$@"
    else
        echo "WARN: $*" >&2
    fi
}

# Infer archive format from a file name. Mirrors _act_archive_format but is
# sourceable without the act_runner module.
packaging_format_for_name() {
    case "$1" in
        *.tar.gz|*.tgz) echo "tar.gz" ;;
        *.tar.xz) echo "tar.xz" ;;
        *.zip) echo "zip" ;;
        *) echo "none" ;;
    esac
}

# A member path is safe when it is relative, cannot escape the extraction
# root, and cannot be confused with a tar/zip option.
packaging_member_is_safe() {
    local member="$1"
    [[ -n "$member" && "$member" != /* && "$member" != -* ]] || return 1
    [[ "$member" != *$'\n'* ]] || return 1
    case "/${member%/}/" in
        *"/../"*|*"//"*|*"/./"*) return 1 ;;
    esac
    return 0
}

# List archive members, one per line.
packaging_list_members() {
    local archive="$1"
    local format="$2"

    [[ -f "$archive" && ! -L "$archive" ]] || return 4
    case "$format" in
        tar.gz|tgz) tar -tzf "$archive" 2>/dev/null ;;
        tar.xz) tar -tJf "$archive" 2>/dev/null ;;
        zip)
            command -v unzip &>/dev/null || return 3
            unzip -Z1 "$archive" 2>/dev/null
            ;;
        *) return 4 ;;
    esac
}

# List archive members excluding pure directory entries, sorted with a stable
# collation, so two archives can be compared for payload parity.
packaging_payload_members() {
    local archive="$1"
    local format="$2"
    local members

    members=$(packaging_list_members "$archive" "$format") || return $?
    printf '%s\n' "$members" | { grep -v '/$' || true; } | LC_ALL=C sort
}

# Extract every member of an archive into an existing destination directory,
# refusing unsafe member paths first.
packaging_extract_payload() {
    local archive="$1"
    local format="$2"
    local dest="$3"
    local members member

    [[ -f "$archive" && ! -L "$archive" ]] || return 4
    [[ -d "$dest" && ! -L "$dest" ]] || return 4

    members=$(packaging_list_members "$archive" "$format") || return 4
    [[ -n "$members" ]] || return 4
    while IFS= read -r member; do
        [[ -z "$member" ]] && continue
        if ! packaging_member_is_safe "$member"; then
            _pkg_log_error "Refusing unsafe archive member: $member"
            return 4
        fi
    done <<< "$members"

    case "$format" in
        tar.gz|tgz) tar -xzf "$archive" -C "$dest" 2>/dev/null || return 4 ;;
        tar.xz) tar -xJf "$archive" -C "$dest" 2>/dev/null || return 4 ;;
        zip)
            command -v unzip &>/dev/null || return 3
            unzip -q -o "$archive" -d "$dest" 2>/dev/null || return 4
            ;;
        *) return 4 ;;
    esac
}

# Build one archive of the requested format from a payload directory and an
# explicit member list. This is the only sanctioned way to produce an archive
# from bytes that may have lived in another archive: the compression never
# sees the source archive, only the extracted payload files.
packaging_build_archive() {
    local format="$1"
    local archive_path="$2"
    local payload_dir="$3"
    shift 3

    [[ $# -gt 0 ]] || return 4
    [[ -d "$payload_dir" && ! -L "$payload_dir" ]] || return 4

    local member
    for member in "$@"; do
        if ! packaging_member_is_safe "$member"; then
            _pkg_log_error "Refusing unsafe archive member: $member"
            return 4
        fi
        if [[ ! -e "$payload_dir/$member" ]]; then
            _pkg_log_error "Archive member missing from payload directory: $member"
            return 4
        fi
    done

    case "$archive_path" in
        /*) ;;
        *) archive_path="$PWD/$archive_path" ;;
    esac

    case "$format" in
        tar.gz|tgz)
            COPYFILE_DISABLE=1 tar --no-xattrs -czf "$archive_path" \
                -C "$payload_dir" "$@" || return 4
            ;;
        tar.xz)
            COPYFILE_DISABLE=1 tar --no-xattrs -cJf "$archive_path" \
                -C "$payload_dir" "$@" || return 4
            ;;
        zip)
            command -v zip &>/dev/null || return 3
            (cd "$payload_dir" && zip -q -X -FS "$archive_path" "$@") || return 4
            ;;
        *)
            _pkg_log_error "Unsupported archive format: $format"
            return 4
            ;;
    esac
}

# Rebuild an existing archive in a different format, independently: extract
# the source payload, build the destination format from the payload files,
# then prove both archives carry the identical member set. The destination is
# never a wrapper around the source.
packaging_repack_archive() {
    local src="$1"
    local src_format="$2"
    local dest="$3"
    local dest_format="$4"

    [[ -f "$src" && ! -L "$src" ]] || return 4
    if [[ "$src" -ef "$dest" ]]; then
        _pkg_log_error "Repack source and destination are the same file: $src"
        return 4
    fi

    local workdir payload status=0
    workdir=$(mktemp -d "${TMPDIR:-/tmp}/dsr-repack.XXXXXXXX") || return 4
    payload="$workdir/payload"
    if ! mkdir "$payload"; then
        rm -rf "$workdir"
        return 4
    fi

    local -a members=()
    local member src_members dest_members
    if ! src_members=$(packaging_payload_members "$src" "$src_format") || \
       [[ -z "$src_members" ]]; then
        rm -rf "$workdir"
        return 4
    fi
    while IFS= read -r member; do
        [[ -n "$member" ]] && members+=("$member")
    done <<< "$src_members"

    if ! packaging_extract_payload "$src" "$src_format" "$payload"; then
        rm -rf "$workdir"
        return 4
    fi

    if ! packaging_build_archive "$dest_format" "$dest" "$payload" "${members[@]}"; then
        status=4
    elif ! dest_members=$(packaging_payload_members "$dest" "$dest_format") || \
         [[ "$dest_members" != "$src_members" ]]; then
        _pkg_log_error "Repacked archive member set does not match source: $dest"
        status=4
    fi

    rm -rf "$workdir"
    return "$status"
}

# Read the per-repo switch that controls whether configured include_files
# (README/LICENSE style extras) are added INSIDE release archives. Consumers
# whose installers enforce an exact flat member contract (payload binaries
# only) set either:
#   include_extra_files: false
#   flat_archive: true
# in their repos.d yaml. Default (absent/any other value) keeps the historic
# behavior: include_files are packaged into archives.
# Prints "true" (include extras) or "false" (flat payload only).
packaging_include_files_in_archives() {
    local config_file="$1"
    local extra flat

    [[ -n "$config_file" && -f "$config_file" && ! -L "$config_file" ]] || {
        echo "true"
        return 0
    }
    command -v yq &>/dev/null || {
        echo "true"
        return 0
    }
    # NOTE: `.key // ""` would swallow a boolean false (false // "" -> ""),
    # so read the raw value and compare its string form.
    extra=$(yq -r '.include_extra_files' "$config_file" 2>/dev/null)
    flat=$(yq -r '.flat_archive' "$config_file" 2>/dev/null)
    if [[ "$extra" == "false" || "$flat" == "true" ]]; then
        echo "false"
    else
        echo "true"
    fi
}
