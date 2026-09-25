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

_pkg_log_info() {
    if declare -F log_info &>/dev/null; then
        log_info "$@"
    else
        echo "INFO: $*" >&2
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
    # Backslashes are ambiguous in tar's quoted listings and Windows paths;
    # colons can denote drive-relative paths or alternate data streams.
    [[ "$member" != *[[:cntrl:]]* && "$member" != *\\* && "$member" != *:* ]] || return 1
    case "/${member%/}/" in
        *"/../"*|*"//"*|*"/./"*) return 1 ;;
    esac
    return 0
}

# Refuse links and special files at any existing component of a payload path.
# The root belongs to the caller; members cannot redirect writes outside it.
_pkg_path_has_no_links() {
    local root="$1" member="${2%/}" component path="$1"
    [[ -d "$root" && ! -L "$root" ]] || return 1
    while [[ -n "$member" ]]; do
        component="${member%%/*}"
        path="$path/$component"
        [[ ! -L "$path" ]] || return 1
        if [[ "$member" == */* ]]; then
            [[ ! -e "$path" || -d "$path" ]] || return 1
            member="${member#*/}"
        else
            [[ ! -e "$path" || -f "$path" || -d "$path" ]] || return 1
            break
        fi
    done
}

# BSD tar auto-detects compression even when the caller requests another format.
# Check the container signature before accepting members under a declared format.
_pkg_archive_matches_format() {
    local archive="$1" format="$2" magic
    [[ -f "$archive" && ! -L "$archive" ]] || return 4
    magic=$(head -c 6 "$archive" 2>/dev/null | od -An -tx1 2>/dev/null | tr -d '[:space:]')
    case "$format" in
        tar.gz|tgz) [[ "$magic" == 1f8b* ]] || return 4 ;;
        tar.xz) [[ "$magic" == fd377a585a00* ]] || return 4 ;;
        zip) [[ "$magic" == 504b0304* || "$magic" == 504b0506* || "$magic" == 504b0708* ]] || return 4 ;;
        *) return 4 ;;
    esac
}

# List archive members, one per line.
packaging_list_members() {
    local archive="$1"
    local format="$2"

    _pkg_archive_matches_format "$archive" "$format" || return $?
    case "$format" in
        tar.gz|tgz)
            command -v tar &>/dev/null || return 3
            tar -tzf "$archive" 2>/dev/null
            ;;
        tar.xz)
            command -v tar &>/dev/null || return 3
            tar -tJf "$archive" 2>/dev/null
            ;;
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

# Release payloads contain regular files and directories, not links, devices
# or FIFOs. Names alone cannot establish that invariant. Inspect the type
# column as well, never parse names from the human-readable verbose listing.
# Reject unknown listing formats rather than silently omitting a record.
packaging_validate_archive() {
    local archive="$1" format="$2" members member listing line
    local count=0 type_count=0
    local -A seen=()
    members=$(packaging_list_members "$archive" "$format") || return $?
    [[ -n "$members" ]] || return 4
    while IFS= read -r member; do
        if ! packaging_member_is_safe "$member"; then
            _pkg_log_error "Refusing unsafe archive member: $member"
            return 4
        fi
        member="${member%/}"
        if [[ -n "${seen[$member]:-}" ]]; then
            _pkg_log_error "Refusing duplicate archive member: $member"
            return 4
        fi
        seen["$member"]=1
        count=$((count + 1))
    done <<< "$members"
    case "$format" in
        tar.gz|tgz) listing=$(LC_ALL=C tar -tvzf "$archive" 2>/dev/null) || return 4 ;;
        tar.xz) listing=$(LC_ALL=C tar -tvJf "$archive" 2>/dev/null) || return 4 ;;
        zip) listing=$(LC_ALL=C unzip -Z -l "$archive" 2>/dev/null) || return 4 ;;
        *) return 4 ;;
    esac
    while IFS= read -r line; do
        if [[ "$format" == "zip" ]]; then
            case "$line" in
                'Archive: '*|'Zip file size: '*) continue ;;
            esac
            [[ "$line" =~ ^[0-9]+[[:space:]]files?, ]] && continue
        fi
        case "${line:0:1}" in
            -|d) type_count=$((type_count + 1)) ;;
            *)
                _pkg_log_error "Refusing non-regular or unrecognized archive entry in $archive"
                return 4
                ;;
        esac
    done <<< "$listing"
    [[ "$count" -eq "$type_count" ]] || return 4
}

# Extract every member of an archive into an existing destination directory,
# refusing unsafe members and conflicting destination files first. In
# particular, overwriting an existing hardlinked file could mutate a file
# outside the destination even though neither path contains a symlink.
packaging_extract_payload() (
    local archive="$1"
    local format="$2"
    local dest="$3"
    local members member

    [[ -f "$archive" && ! -L "$archive" ]] || return 4
    [[ -d "$dest" && ! -L "$dest" ]] || return 4

    packaging_validate_archive "$archive" "$format" || return $?
    members=$(packaging_list_members "$archive" "$format") || return $?
    while IFS= read -r member; do
        if ! _pkg_path_has_no_links "$dest" "$member"; then
            _pkg_log_error "Refusing unsafe extraction destination for: $member"
            return 4
        fi
        if [[ -e "$dest/${member%/}" && ! -d "$dest/${member%/}" ]]; then
            _pkg_log_error "Refusing to overwrite existing payload member: $member"
            return 4
        fi
    done <<< "$members"

    # A caller's restrictive umask must not silently strip executable bits.
    # Do not adopt the archive's user/group identities on a privileged host.
    umask 022
    case "$format" in
        tar.gz|tgz) tar --no-same-owner -xzf "$archive" -C "$dest" 2>/dev/null || return 4 ;;
        tar.xz) tar --no-same-owner -xJf "$archive" -C "$dest" 2>/dev/null || return 4 ;;
        zip)
            command -v unzip &>/dev/null || return 3
            unzip -q -o "$archive" -d "$dest" 2>/dev/null || return 4
            ;;
        *) return 4 ;;
    esac
)

# Expand selected directories without following links. This also establishes
# the exact expected file set, so zip cannot silently archive only a directory
# entry while tar recursively includes the files beneath it.
_pkg_selected_payload_members() (
    set -o pipefail
    local root="$1" member path name
    shift
    {
        for member in "$@"; do
            find "$root/$member" -print0 || return 4
        done
    } | while IFS= read -r -d '' path; do
        name="${path#"$root"/}"
        packaging_member_is_safe "$name" || return 4
        if [[ -L "$path" || ( ! -f "$path" && ! -d "$path" ) ]]; then
            _pkg_log_error "Refusing linked or special payload member: $name"
            return 4
        fi
        [[ ! -f "$path" ]] || printf '%s\n' "$name"
    done | LC_ALL=C sort -u
)

# Compare executable mode bits, not -x (which depends on the current user's
# identity). Support both GNU stat and the BSD stat shipped on macOS.
_pkg_executable_bits() {
    local mode
    mode=$(stat -c '%a' "$1" 2>/dev/null) || \
        mode=$(stat -f '%Lp' "$1" 2>/dev/null) || return 4
    [[ "$mode" =~ ^[0-7]{1,4}$ ]] || return 4
    printf '%s\n' "$((8#$mode & 0111))"
}

# Return 0 for equal file sets, contents and executable bits, 1 for a payload
# mismatch, or 3/4 for a dependency/validation failure. Archive timestamps,
# compression settings and ownership deliberately do not define equality.
_pkg_archive_matches_payload() (
    local archive="$1" format="$2" payload="$3" expected="$4"
    local actual workdir member source_bits archive_bits
    actual=$(packaging_payload_members "$archive" "$format") || return $?
    [[ -n "$expected" && "$actual" == "$expected" ]] || return 1
    workdir=$(mktemp -d "${TMPDIR:-/tmp}/dsr-payload-check.XXXXXXXX") || return 4
    trap 'rm -rf -- "$workdir"' EXIT
    trap 'exit 5' HUP INT TERM
    packaging_extract_payload "$archive" "$format" "$workdir" || return $?
    while IFS= read -r member; do
        _pkg_path_has_no_links "$payload" "$member" || return 4
        [[ -f "$payload/$member" && -f "$workdir/$member" ]] || return 1
        cmp -s "$payload/$member" "$workdir/$member" || return 1
        source_bits=$(_pkg_executable_bits "$payload/$member") || return $?
        archive_bits=$(_pkg_executable_bits "$workdir/$member") || return $?
        [[ "$source_bits" == "$archive_bits" ]] || return 1
    done <<< "$expected"
)

# SOURCE_DATE_EPOCH is opt-in. Bound it to the common unsigned gzip timestamp
# range before arithmetic, even on a retry that would reuse existing bytes.
_pkg_validate_epoch() {
    [[ ${SOURCE_DATE_EPOCH+x} ]] || return 0
    if [[ ! "$SOURCE_DATE_EPOCH" =~ ^[0-9]{1,10}$ ]] || \
       ((10#$SOURCE_DATE_EPOCH > 4294967295)); then
        _pkg_log_error 'SOURCE_DATE_EPOCH must be an integer from 0 through 4294967295'
        return 4
    fi
}

# Canonical metadata and streaming compression without GNU/BSD tar flag
# differences. This writes only private staging; the normal extraction/parity
# gate and atomic publication below still admit the result. No source chmod,
# chown or touch is performed. Python is required only for an explicit epoch.
_pkg_reproducible_archive() {
    command -v python3 &>/dev/null || {
        _pkg_log_error 'Reproducible packaging requires Python 3.8 or newer'
        return 3
    }
    python3 -I - "$1" "$2" "$3" "$4" "$SOURCE_DATE_EPOCH" <<'PY'
import contextlib
import datetime
import os
import stat
import sys

if sys.version_info < (3, 8):
    print('ERROR: Reproducible packaging requires Python 3.8 or newer', file=sys.stderr)
    sys.exit(3)

try:
    import gzip
    import lzma
    import tarfile
    import zipfile
except ImportError as exc:
    print('ERROR: Missing Python archive support: ' + str(exc), file=sys.stderr)
    sys.exit(3)


@contextlib.contextmanager
def source_file(root, name):
    # Do not follow symlinks in any payload component. Nonblocking open also
    # prevents a replaced FIFO from hanging before the regular-file check.
    with contextlib.ExitStack() as stack:
        flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
        parent = os.open(root, flags)
        stack.callback(os.close, parent)
        for part in name.split('/')[:-1]:
            parent = os.open(part, flags, dir_fd=parent)
            stack.callback(os.close, parent)
        fd = os.open(name.split('/')[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                     dir_fd=parent)
        stream = stack.enter_context(os.fdopen(fd, 'rb'))
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode):
            raise ValueError('payload is not a regular file: ' + name)
        yield stream, before
        after = os.fstat(stream.fileno())
        identity = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns,
                              s.st_ctime_ns, s.st_mode)
        if identity(before) != identity(after):
            raise ValueError('payload changed while archiving: ' + name)


def write_tar(output, root, names, epoch):
    with tarfile.open(fileobj=output, mode='w|', format=tarfile.PAX_FORMAT) as archive:
        for name in names:
            with source_file(root, name) as (incoming, info):
                member = tarfile.TarInfo(name)
                member.size = info.st_size
                member.mode = 0o644 | (info.st_mode & 0o111)
                member.mtime = epoch
                member.uid = member.gid = 0
                member.uname = member.gname = ''
                archive.addfile(member, incoming)


def write_zip(output, root, names, epoch):
    # ZIP uses a UTC-derived DOS timestamp (1980 minimum, two-second precision).
    instant = datetime.datetime(1970, 1, 1) + datetime.timedelta(seconds=max(epoch, 315532800))
    date = (instant.year, instant.month, instant.day, instant.hour, instant.minute,
            instant.second - instant.second % 2)
    # Use the public streaming ZIP API and the selected zlib's default DEFLATE
    # level. Cross-toolchain byte identity requires pinning compression libraries.
    with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED, allowZip64=True) as archive:
        for name in names:
            with source_file(root, name) as (incoming, info):
                member = zipfile.ZipInfo(name, date_time=date)
                member.create_system = 3
                member.compress_type = zipfile.ZIP_DEFLATED
                member.external_attr = (stat.S_IFREG | 0o644 | (info.st_mode & 0o111)) << 16
                member.file_size = info.st_size
                with archive.open(member, 'w', force_zip64=info.st_size >= zipfile.ZIP64_LIMIT) as outgoing:
                    remaining = info.st_size
                    while remaining:
                        data = incoming.read(min(1048576, remaining))
                        if not data:
                            raise ValueError('payload truncated while archiving: ' + name)
                        outgoing.write(data)
                        remaining -= len(data)


try:
    fmt, destination, root, listing, timestamp = sys.argv[1:]
    epoch = int(timestamp)
    with open(listing, encoding='utf-8') as selected:
        names = selected.read().splitlines()
    if not names or names != sorted(set(names), key=os.fsencode):
        raise ValueError('invalid canonical member inventory')
    for name in names:
        if (name.startswith(('/', '-')) or any(ord(c) < 32 or ord(c) == 127 or c in '\\:' for c in name)
                or any(part in ('', '.', '..') for part in name.split('/'))):
            raise ValueError('unsafe payload member')
    with open(destination, 'xb') as output:
        if fmt in ('tar.gz', 'tgz'):
            with gzip.GzipFile(filename='', mode='wb', compresslevel=9,
                               fileobj=output, mtime=epoch) as compressed:
                write_tar(compressed, root, names, epoch)
        elif fmt == 'tar.xz':
            with lzma.LZMAFile(output, 'w', format=lzma.FORMAT_XZ,
                               check=lzma.CHECK_CRC64, preset=6) as compressed:
                write_tar(compressed, root, names, epoch)
        elif fmt == 'zip':
            write_zip(output, root, names, epoch)
        else:
            raise ValueError('unsupported reproducible archive format')
except (OSError, ValueError, EOFError, tarfile.TarError, lzma.LZMAError, zipfile.BadZipFile) as exc:
    print('ERROR: Reproducible archive failed: ' + str(exc), file=sys.stderr)
    sys.exit(4)
PY
}

# Build one archive of the requested format from a payload directory and an
# explicit member list. This is the only sanctioned way to produce an archive
# from bytes that may have lived in another archive: the compression never
# sees the source archive, only the extracted payload files.
packaging_build_archive() (
    local format="$1"
    local archive_path="$2"
    local payload_dir="$3"
    shift 3

    [[ $# -gt 0 ]] || return 4
    [[ -d "$payload_dir" && ! -L "$payload_dir" ]] || return 4
    _pkg_validate_epoch || return $?

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
        if ! _pkg_path_has_no_links "$payload_dir" "$member"; then
            _pkg_log_error "Refusing linked or special payload member: $member"
            return 4
        fi
    done

    case "$archive_path" in
        /*) ;;
        *) archive_path="$PWD/$archive_path" ;;
    esac

    # Never let a failed compressor truncate an already published artifact.
    # Staging beside the destination keeps the final rename on one filesystem.
    [[ ! -L "$archive_path" && ( ! -e "$archive_path" || -f "$archive_path" ) ]] || return 4
    local archive_dir workdir staged members
    archive_dir=$(cd "$(dirname "$archive_path")" && pwd -P) || return 4
    archive_path="$archive_dir/$(basename "$archive_path")"
    payload_dir=$(cd "$payload_dir" && pwd -P) || return 4
    for member in "$@"; do
        if [[ "$archive_path" -ef "$payload_dir/$member" ]] || \
           [[ -d "$payload_dir/$member" && "$archive_path" == "$payload_dir/${member%/}/"* ]]; then
            _pkg_log_error "Archive destination overlaps its payload: $archive_path"
            return 4
        fi
    done
    case "$format" in
        tar.gz|tgz|tar.xz) command -v tar &>/dev/null || return 3 ;;
        zip) command -v zip &>/dev/null && command -v unzip &>/dev/null || return 3 ;;
        *) _pkg_log_error "Unsupported archive format: $format"; return 4 ;;
    esac

    members=$(_pkg_selected_payload_members "$payload_dir" "$@") || return $?
    [[ -n "$members" ]] || return 4
    if [[ -f "$archive_path" ]] && \
       _pkg_archive_matches_payload "$archive_path" "$format" "$payload_dir" "$members" 2>/dev/null; then
        _pkg_log_info "Reusing verified archive without recompression: $archive_path"
        return 0
    fi

    workdir=$(mktemp -d "$archive_dir/.dsr-package.XXXXXXXX") || return 4
    staged="$workdir/artifact.$format"
    trap 'rm -rf -- "$workdir"' EXIT
    trap 'exit 5' HUP INT TERM

    if [[ ${SOURCE_DATE_EPOCH+x} ]]; then
        printf '%s\n' "$members" > "$workdir/members" || return 4
        _pkg_reproducible_archive "$format" "$staged" "$payload_dir" "$workdir/members" || return $?
    else
        case "$format" in
            tar.gz|tgz)
                COPYFILE_DISABLE=1 tar --no-xattrs -czf "$staged" \
                    -C "$payload_dir" "$@" || return 4
                ;;
            tar.xz)
                COPYFILE_DISABLE=1 tar --no-xattrs -cJf "$staged" \
                    -C "$payload_dir" "$@" || return 4
                ;;
            zip)
                (cd "$payload_dir" && zip -q -r -X "$staged" "$@") || return 4
                ;;
        esac
    fi

    if ! _pkg_archive_matches_payload "$staged" "$format" "$payload_dir" "$members"; then
        _pkg_log_error "Archive payload verification failed: $archive_path"
        return 4
    fi
    [[ ! -L "$archive_path" && ( ! -e "$archive_path" || -f "$archive_path" ) ]] || return 4
    mv -f -- "$staged" "$archive_path" || return 4
)

# Rebuild an existing archive in a different format, independently: extract
# the source payload, build the destination format from the payload files,
# then prove both archives carry identical files, bytes and executable bits.
# Same-format source archives are authoritative and copied byte-for-byte,
# never recompressed. Equivalent existing cross-format destinations are reused.
# Optional trailing arguments `<include_root> <include>...` stage configured
# companion files (README/LICENSE style include_files) from <include_root>
# into the payload before the destination archive is built. Regression
# context (rano v0.2.1): the native staging lane wraps a lone binary into an
# archive, and a payload-preserving repack then shipped that archive without
# the LICENSE the previous release carried, silently. Includes are subject to
# the same member-safety rules as extracted payload members. An existing
# member satisfies an include only when its bytes and executable bits match;
# it is never overwritten. Only genuinely missing includes require rebuilding.
# Thus prebuilt archives that already satisfy the include contract retain their
# exact compressed bytes, including when the include list contains duplicates.
packaging_repack_archive() (
    local src="$1"
    local src_format="$2"
    local dest="$3"
    local dest_format="$4"
    local include_root="${5:-}"
    shift 4
    [[ $# -eq 0 ]] || shift
    local -a includes=("$@")

    _pkg_validate_epoch || return $?
    [[ -f "$src" && ! -L "$src" ]] || return 4
    if [[ ${#includes[@]} -gt 0 ]]; then
        [[ -n "$include_root" && -d "$include_root" && ! -L "$include_root" ]] || {
            _pkg_log_error "Include root is not a directory: ${include_root:-<empty>}"
            return 4
        }
    fi
    if [[ "$src" -ef "$dest" ]]; then
        _pkg_log_error "Repack source and destination are the same file: $src"
        return 4
    fi

    [[ ! -L "$dest" && ( ! -e "$dest" || -f "$dest" ) ]] || return 4
    [[ "$src_format" != "tgz" ]] || src_format="tar.gz"
    [[ "$dest_format" != "tgz" ]] || dest_format="tar.gz"
    local workdir payload dest_dir staged
    dest_dir=$(cd "$(dirname "$dest")" && pwd -P) || return 4
    dest="$dest_dir/$(basename "$dest")"
    workdir=$(mktemp -d "$dest_dir/.dsr-repack.XXXXXXXX") || return 4
    trap 'rm -rf -- "$workdir"' EXIT
    trap 'exit 5' HUP INT TERM
    payload="$workdir/payload"
    staged="$workdir/artifact.$dest_format"
    mkdir "$payload" || return 4

    local -a members=()
    local member src_members
    src_members=$(packaging_payload_members "$src" "$src_format") || return $?
    [[ -n "$src_members" ]] || return 4
    while IFS= read -r member; do
        [[ -n "$member" ]] && members+=("$member")
    done <<< "$src_members"

    packaging_extract_payload "$src" "$src_format" "$payload" || return $?

    local include include_parent include_bits payload_bits include_mode
    local added_includes=0
    for include in "${includes[@]}"; do
        if ! packaging_member_is_safe "$include"; then
            _pkg_log_error "Refusing unsafe include member: $include"
            return 4
        fi
        if ! _pkg_path_has_no_links "$include_root" "$include" || \
           [[ ! -f "$include_root/$include" ]]; then
            _pkg_log_error "Include is missing or not a regular non-symlink file: $include"
            return 4
        fi
        if ! _pkg_path_has_no_links "$payload" "$include"; then
            _pkg_log_error "Include collides with an archive payload member: $include"
            return 4
        fi
        include_bits=$(_pkg_executable_bits "$include_root/$include") || return $?
        if [[ -e "$payload/$include" ]]; then
            if [[ ! -f "$payload/$include" ]] || \
               ! cmp -s "$include_root/$include" "$payload/$include"; then
                _pkg_log_error "Include differs from the existing archive payload: $include"
                return 4
            fi
            payload_bits=$(_pkg_executable_bits "$payload/$include") || return $?
            if [[ "$include_bits" != "$payload_bits" ]]; then
                _pkg_log_error "Include executable bits differ from the archive payload: $include"
                return 4
            fi
            _pkg_log_info "Reusing verified include already present in the payload: $include"
            continue
        fi
        include_parent=$(dirname "$payload/$include")
        mkdir -p -- "$include_parent" || return 4
        cp -- "$include_root/$include" "$payload/$include" || return 4
        # Preserve the actual executable-bit contract, not -x (which depends
        # on the invoking user's identity). Strip privileged/write mode bits.
        printf -v include_mode '%o' "$((0644 | include_bits))"
        chmod "$include_mode" "$payload/$include" || return 4
        members+=("$include")
        added_includes=$((added_includes + 1))
    done
    if [[ "$added_includes" -gt 0 ]]; then
        # The parity contract now covers payload members plus includes.
        src_members=$(printf '%s\n' "${members[@]}" | LC_ALL=C sort)
    fi

    if [[ "$added_includes" -gt 0 ]]; then
        if [[ -f "$dest" ]] && \
           _pkg_archive_matches_payload "$dest" "$dest_format" "$payload" "$src_members" 2>/dev/null; then
            _pkg_log_info "Reusing verified archive that already carries the configured includes: $dest"
            return 0
        fi
        packaging_build_archive "$dest_format" "$staged" "$payload" "${members[@]}" || return $?
    elif [[ "$src_format" == "$dest_format" ]]; then
        if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
            _pkg_log_info "Reusing byte-identical prebuilt archive: $dest"
            return 0
        fi
        cp -- "$src" "$staged" || return 4
    elif [[ -f "$dest" ]] && \
         _pkg_archive_matches_payload "$dest" "$dest_format" "$payload" "$src_members" 2>/dev/null; then
        _pkg_log_info "Reusing verified cross-format archive without recompression: $dest"
        return 0
    else
        packaging_build_archive "$dest_format" "$staged" "$payload" "${members[@]}" || return $?
    fi
    if ! _pkg_archive_matches_payload "$staged" "$dest_format" "$payload" "$src_members"; then
        _pkg_log_error "Repacked archive payload does not match source: $dest"
        return 4
    fi
    [[ ! -L "$dest" && ( ! -e "$dest" || -f "$dest" ) ]] || return 4
    mv -f -- "$staged" "$dest" || return 4
)

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
