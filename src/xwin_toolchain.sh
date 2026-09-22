#!/usr/bin/env bash
# Pinned Windows ARM64 compiler/header/library views (dsr-h4y0).
# Source archives and installed executables are inputs, never modified.
# Every cache admission is re-derived from the pinned archives, not trusted
# merely because a previous receipt or a cargo-xwin DONE marker exists.

_XWIN_TOOLCHAIN_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

_xwt_log() { printf '[xwin-toolchain] %s\n' "$*" >&2; }

_xwt_hash() {
    local digest
    digest=$(sha256sum -- "$1") || return 1
    digest=${digest%% *}
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$digest"
}

_xwt_require() {
    local tool
    [[ "$(uname -s)" == Linux ]] || {
        _xwt_log 'Toolchain preparation requires a Linux build host'; return 3;
    }
    for tool in jq sha256sum flock find sort cp mv stat; do
        command -v "$tool" >/dev/null || { _xwt_log "Required tool missing: $tool"; return 3; }
    done
    if ! declare -F packaging_extract_payload >/dev/null; then
        # shellcheck source=src/packaging.sh
        source "$_XWIN_TOOLCHAIN_DIR/packaging.sh" || return 3
    fi
}

# Keep flag-bearing paths whitespace-free: downstream CFLAGS/clang/CMake
# parsers do not share one quoting convention. Archive input paths may contain
# spaces; they are only ever passed as individual shell arguments.
_xwt_manifest() {
    jq -cSe 'def text: type=="string" and length>0 and (test("[\\x00-\\x1f\\x7f]")|not);
        def hash: type=="string" and test("^[0-9a-f]{64}$");
        def relative: text and (startswith("/")|not) and
            (split("/")|all(.!="" and .!="." and .!=".." and (startswith("-")|not))) and
            (test("[\\\\:]")|not);
        def archive: type=="object" and (keys==["path","prefix","sha256","url"]) and
            (.path|text and startswith("/")) and (.prefix|relative) and (.sha256|hash) and
            (.url|text and test("^https://[^/@?#]+/[^?#]+$") and (test("[[:space:]]")|not));
        if type=="object" and (keys==["aliases","headers","schema_version","sysroot","target","tools"]) and
            .schema_version==1 and .target=="aarch64-pc-windows-msvc" and
            (.sysroot|archive) and (.headers|archive) and
            (.aliases|type=="object" and length>0 and has("Kernel32.lib") and
                all(to_entries[];(.key|test("^[A-Za-z0-9_.+-]+\\.lib$")) and
                    (.value|type=="string" and test("^[a-z0-9_.+-]+\\.lib$")) and
                    (.key|ascii_downcase)==.value)) and
            (.tools|type=="object" and has("cargo") and has("cargo-xwin") and has("rustc") and
                has("clang") and has("lld-link") and all(to_entries[];
                    (.key|test("^[A-Za-z0-9][A-Za-z0-9+_.-]*$")) and
                    (.value|type=="object" and (keys==["path","sha256"]) and
                        (.path|text and startswith("/") and (test("[[:space:];\\\\]")|not)) and (.sha256|hash))))
        then . else error("invalid Windows ARM64 toolchain manifest") end' "$1" || return 4
}

_xwt_check_tools() {
    local plan="$1" entry path expected entries
    entries=$(jq -c '.tools|to_entries|sort_by(.key)[]' <<< "$plan") || return 1
    while IFS= read -r entry; do
        path=$(jq -r '.value.path' <<< "$entry") || return 1
        expected=$(jq -r '.value.sha256' <<< "$entry") || return 1
        if [[ ! -f "$path" || -L "$path" || ! -x "$path" ]] ||
           [[ "$(_xwt_hash "$path")" != "$expected" ]]; then
            _xwt_log "Missing or drifted executable: $path"
            return 7
        fi
    done <<< "$entries"
}

# Produce a stable content inventory; links, devices, hidden additions and
# empty-directory changes cannot be hidden behind the previous evidence file.
_xwt_inventory() (
    local root="$1" index="$2" path name hash size type
    [[ -d "$root" && ! -L "$root" ]] || return 7
    find "$root" -mindepth 1 -print0 > "$index.paths" || return 1
    LC_ALL=C sort -z "$index.paths" > "$index.sorted" || return 1
    : > "$index" || return 1
    while IFS= read -r -d '' path; do
        name=${path#"$root"/}
        [[ "$name" != evidence.json ]] || continue
        packaging_member_is_safe "$name" || return 7
        [[ ! -L "$path" ]] || return 7
        if [[ -d "$path" ]]; then
            type=directory hash='' size=0
        elif [[ -f "$path" ]]; then
            type=file
            hash=$(_xwt_hash "$path") || return $?
            size=$(stat -c '%s' -- "$path") || return 1
        else
            return 7
        fi
        jq -cn --arg path "$name" --arg type "$type" --arg sha "$hash" --argjson size "$size" \
            '{path:$path,type:$type,sha256:$sha,size_bytes:$size}' >> "$index" || return 1
    done < "$index.sorted"
    jq -csS 'sort_by(.path)' "$index"
)

# Snapshot before hashing/extraction so a changing input cannot select members
# from one archive and provide their bytes from another.
_xwt_unpack() {
    local plan="$1" field="$2" work="$3" path expected format prefix
    path=$(jq -r --arg field "$field" '.[$field].path' <<< "$plan") || return 1
    expected=$(jq -r --arg field "$field" '.[$field].sha256' <<< "$plan") || return 1
    prefix=$(jq -r --arg field "$field" '.[$field].prefix' <<< "$plan") || return 1
    [[ -f "$path" && ! -L "$path" ]] || return 4
    format=$(packaging_format_for_name "$path") || return $?
    [[ "$format" != none ]] || return 4
    cp -- "$path" "$work/$field.archive" || return 1
    [[ "$(_xwt_hash "$work/$field.archive")" == "$expected" ]] || {
        _xwt_log "Pinned $field archive hash mismatch"; return 7;
    }
    mkdir "$work/$field" || return 1
    packaging_extract_payload "$work/$field.archive" "$format" "$work/$field" || return $?
    [[ -d "$work/$field/$prefix" && ! -L "$work/$field/$prefix" ]] || return 4
}

_xwt_materialize() {
    local plan="$1" work="$2" view prefix libdir path name lower alias source entries
    view="$work/view"
    local -A libraries=()
    mkdir "$view" "$view/include" "$view/lib" "$view/sysroot" || return 1
    prefix=$(jq -r '.headers.prefix' <<< "$plan") || return 1
    [[ -f "$work/headers/$prefix/arm_neon.h" ]] || {
        _xwt_log 'Pinned LLVM system headers do not contain arm_neon.h'; return 4;
    }
    cp -R -- "$work/headers/$prefix/." "$view/include/" || return 1
    prefix=$(jq -r '.sysroot.prefix' <<< "$plan") || return 1
    [[ -d "$work/sysroot/$prefix/include" ]] || return 4
    libdir="$work/sysroot/$prefix/lib/aarch64-unknown-windows-msvc"
    [[ -d "$libdir" ]] || { _xwt_log 'Missing ARM64 MSVC library directory'; return 4; }
    cp -R -- "$work/sysroot/$prefix/." "$view/sysroot/" || return 1
    # cargo-xwin clang backend recognizes this marker and never needs to
    # resolve a moving latest-release URL for a prepared sysroot.
    [[ ! -e "$view/sysroot/DONE" ]] || { _xwt_log 'Unexpected input DONE marker'; return 4; }
    jq -r '.sysroot.url' <<< "$plan" > "$view/sysroot/DONE" || return 1
    find "$libdir" -mindepth 1 -maxdepth 1 -type f -print0 > "$work/libraries" || return 1
    while IFS= read -r -d '' path; do
        name=${path##*/}
        lower=${name,,}
        [[ "$lower" == *.lib ]] || continue
        [[ "$lower" =~ ^[a-z0-9][a-z0-9_.+-]*\.lib$ ]] || return 4
        if [[ -n "${libraries[$lower]:-}" ]]; then
            cmp -s "$path" "$view/lib/$lower" || {
                _xwt_log "Conflicting case-insensitive MSVC library: $name"; return 4;
            }
        else
            cp -- "$path" "$view/lib/$lower" || return 1
            libraries[$lower]=1
        fi
    done < "$work/libraries"
    [[ ${#libraries[@]} -gt 0 ]] || return 4
    entries=$(jq -r '.aliases|to_entries|sort_by(.key)[]|[.key,.value]|@tsv' <<< "$plan") || return 1
    while IFS=$'\t' read -r alias source; do
        [[ -n "${libraries[$source]:-}" ]] || { _xwt_log "Alias source missing: $source"; return 4; }
        if [[ "$alias" != "$source" ]]; then
            # Fail on case-insensitive filesystems instead of mutating the
            # canonical input path or pretending two case variants exist.
            [[ ! -e "$view/lib/$alias" ]] || { _xwt_log 'A case-sensitive cache filesystem is required'; return 4; }
            cp -- "$view/lib/$source" "$view/lib/$alias" || return 1
        fi
    done <<< "$entries"
    printf '%s\n' "$plan" > "$view/manifest.json" || return 1
}

# stdout: one JSON receipt containing a verified view and pinned identities.
# Mode verify never repairs a damaged cache. prepare never replaces it either.
xwin_toolchain_prepare() (
    set -uo pipefail
    umask 077
    local manifest="${1:-}" root="${2:-}" mode="${3:-prepare}"
    [[ -f "$manifest" && ! -L "$manifest" && "$mode" =~ ^(prepare|verify)$ ]] || return 4
    _xwt_require || return $?
    [[ -n "$root" ]] || root="${XDG_CACHE_HOME:-$HOME/.cache}/dsr/xwin-toolchains"
    [[ "$root" == /* && "$root" != *[[:space:]]* && "$root" != *[\;\\:]* && ! -L "$root" ]] || return 4
    local work plan key view expected actual evidence status=prepared
    # Validate exactly one JSON document before the normal jq projection.
    jq -es 'length==1' "$manifest" >/dev/null 2>&1 || return 4
    plan=$(_xwt_manifest "$manifest") || return $?
    _xwt_check_tools "$plan" || return $?
    if [[ "$mode" == verify && ! -d "$root" ]]; then return 7; fi
    mkdir -p -- "$root" || return 1
    root=$(cd "$root" && pwd -P) || return 1
    [[ "$root" != *[[:space:]]* && "$root" != *[\;\\:]* ]] || return 4
    work=$(mktemp -d "$root/.prepare.XXXXXXXX") || return 1
    trap 'rm -rf -- "$work"' EXIT
    trap 'exit 5' HUP INT TERM
    printf '%s\n' "$plan" > "$work/manifest.json" || return 1
    key=$(_xwt_hash "$work/manifest.json") || return $?
    view="$root/$key"
    [[ ! -L "$root/$key.lock" && ( ! -e "$root/$key.lock" || -f "$root/$key.lock" ) ]] || return 2
    exec 9>> "$root/$key.lock" || return 1
    flock -n 9 || { _xwt_log 'Toolchain preparation is already active'; return 2; }
    [[ ! -L "$view" && ( ! -e "$view" || -d "$view" ) ]] || return 2
    [[ "$mode" != verify || -d "$view" ]] || return 7
    _xwt_unpack "$plan" sysroot "$work" || return $?
    _xwt_unpack "$plan" headers "$work" || return $?
    _xwt_materialize "$plan" "$work" || return $?
    expected=$(_xwt_inventory "$work/view" "$work/expected") || return $?
    evidence=$(jq -cnS --arg key "$key" --argjson plan "$plan" --argjson files "$expected" \
        '{schema_version:1,kind:"dsr-xwin-toolchain",manifest_sha256:$key,target:$plan.target,
          inputs:$plan,files:$files}') || return 1
    printf '%s\n' "$evidence" > "$work/view/evidence.json" || return 1
    _xwt_check_tools "$plan" || return $?
    if [[ -d "$view" ]]; then
        [[ -f "$view/evidence.json" && ! -L "$view/evidence.json" ]] || return 7
        cmp -s "$work/view/evidence.json" "$view/evidence.json" || {
            _xwt_log 'Retained toolchain evidence differs from pinned inputs'; return 7;
        }
        actual=$(_xwt_inventory "$view" "$work/actual") || return $?
        [[ "$actual" == "$expected" ]] || { _xwt_log 'Retained toolchain files have drifted'; return 7; }
        status=verified
    else
        mv -T -- "$work/view" "$view" || return 2
    fi
    _xwt_check_tools "$plan" || return $?
    _xwt_log "$status Windows ARM64 toolchain: $key"
    jq -cn --arg status "$status" --arg view "$view" --arg key "$key" --argjson evidence "$evidence" \
        '{kind:"dsr-xwin-toolchain-result",status:$status,view:$view,manifest_sha256:$key,
          evidence:$evidence,environment:{XWIN_CROSS_COMPILER:"clang",
            XWIN_MSVC_SYSROOT_DOWNLOAD_URL:$evidence.inputs.sysroot.url,
            CFLAGS:("-nobuiltininc -isystem "+$view+"/include"),
            CXXFLAGS:("-nobuiltininc -isystem "+$view+"/include"),LIB:($view+"/lib")}}'
)
