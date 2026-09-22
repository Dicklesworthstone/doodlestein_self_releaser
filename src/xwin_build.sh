#!/usr/bin/env bash
# Execute one release-profile cargo-xwin binary build with the prepared
# dsr-h4y0 inputs. This is not a replacement for DSR's source/release gates.
_XWIN_BUILD_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=src/xwin_toolchain.sh
source "$_XWIN_BUILD_DIR/xwin_toolchain.sh"

# Validate headers AND bounded section data; a .exe suffix or MZ prefix alone
# cannot establish the target. Never execute the candidate binary.
xwin_validate_arm64_pe() {
    command -v python3 >/dev/null || return 3
    python3 - "$1" <<'PY'
import hashlib
import json
import os
import stat
import struct
import sys

try:
    fd = os.open(sys.argv[1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as image:
        before = os.fstat(image.fileno())
        if not stat.S_ISREG(before.st_mode):
            raise ValueError("not a regular file")
        size = before.st_size

        def read(offset, count):
            if offset < 0 or count < 0 or offset + count > size:
                raise ValueError("truncated PE data")
            image.seek(offset)
            data = image.read(count)
            if len(data) != count:
                raise ValueError("short PE read")
            return data

        dos = read(0, 64)
        if dos[:2] != b"MZ":
            raise ValueError("missing DOS signature")
        pe = struct.unpack_from("<I", dos, 60)[0]
        if pe < 64 or read(pe, 4) != b"PE\0\0":
            raise ValueError("invalid PE signature/offset")
        machine, count, _, _, _, opt_size, flags = struct.unpack("<HHIIIHH", read(pe + 4, 20))
        if machine != 0xAA64 or not 1 <= count <= 96 or not flags & 2 or flags & 0x2000:
            raise ValueError("not an ARM64 executable image")
        opt = read(pe + 24, opt_size)
        if opt_size < 112 or struct.unpack_from("<H", opt)[0] != 0x20B:
            raise ValueError("not PE32+")
        entry = struct.unpack_from("<I", opt, 16)[0]
        image_size, headers_size = struct.unpack_from("<II", opt, 56)
        directories = struct.unpack_from("<I", opt, 108)[0]
        table = pe + 24 + opt_size
        if (directories > (opt_size - 112) // 8 or
                not table + count * 40 <= headers_size <= size or
                not 0 < entry < image_size or
                struct.unpack_from("<H", opt, 68)[0] not in (2, 3)):
            raise ValueError("invalid image/optional-header bounds")
        ranges = []
        entry_backed = False
        for number in range(count):
            section = read(table + number * 40, 40)
            virtual_size, address, raw_size, raw_offset = struct.unpack_from("<IIII", section, 8)
            section_flags = struct.unpack_from("<I", section, 36)[0]
            if address + max(virtual_size, raw_size) > image_size:
                raise ValueError("section exceeds virtual image")
            if raw_size:
                if raw_offset < headers_size or raw_offset + raw_size > size:
                    raise ValueError("section exceeds file")
                ranges.append((raw_offset, raw_offset + raw_size))
            if section_flags & 0x20000000 and address <= entry < address + min(virtual_size, raw_size):
                entry_backed = True
        ranges.sort()
        if any(left[1] > right[0] for left, right in zip(ranges, ranges[1:])) or not entry_backed:
            raise ValueError("overlapping sections or unbacked entry point")
        image.seek(0)
        digest = hashlib.sha256()
        for block in iter(lambda: image.read(1024 * 1024), b""):
            digest.update(block)
        after = os.fstat(image.fileno())
        if (before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
            raise ValueError("image changed during verification")
        print(json.dumps({"format": "PE32+", "machine": "IMAGE_FILE_MACHINE_ARM64",
                          "machine_code": machine, "sha256": digest.hexdigest(), "size_bytes": size}))
except (OSError, ValueError, struct.error) as error:
    print("[xwin-build] " + str(error), file=sys.stderr)
    sys.exit(7)
PY
}

# Each command owns a session. Cancellation kills only its process group,
# including descendants; timeout --foreground avoids creating a nested group.
_xwb_run() {
    local saved_traps monitor="$-"
    saved_traps=$(trap -p HUP INT TERM)
    set +m
    local cwd="$1" log="$2" seconds="$3" pid rc=0 capture=''
    shift 3
    if [[ "${1:-}" == --stdout ]]; then
        [[ $# -ge 3 && -n "$2" ]] || return 4
        capture=$2
        shift 2
        [[ ! -e "$capture" && ! -L "$capture" ]] || return 2
    fi
    _xwb_cancel() {
        trap '' HUP INT TERM
        kill -TERM -- "-$pid" 2>/dev/null || true
        sleep 1
        kill -KILL -- "-$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        exit 5
    }
    if [[ -n "$capture" ]]; then
        (cd "$cwd" && exec setsid --wait timeout --foreground --kill-after=5s "${seconds}s" "$@") > "$capture" 2> "$log" &
    else
        (cd "$cwd" && exec setsid --wait timeout --foreground --kill-after=5s "${seconds}s" "$@") > "$log" 2>&1 &
    fi
    pid=$!
    trap _xwb_cancel HUP INT TERM
    wait "$pid" || rc=$?
    # Finished commands must not leave background compiler children behind,
    # whether they succeeded, failed, or hit the deadline.
    kill -KILL -- "-$pid" 2>/dev/null || true
    trap - HUP INT TERM
    # Only Bash's own trap serialization is evaluated, never input arguments.
    eval "$saved_traps"
    [[ "$monitor" != *m* ]] || set -m
    return "$rc"
}

# Verify the paths actually selected by PATH, including LLVM multicall roles.
# Matching --version text cannot bless a shim replaced during a build.
_xwb_check_shims() {
    local plan="$1" bin="$2" entries name path
    [[ -d "$bin" && ! -L "$bin" ]] || return 7
    entries=$(jq -r '.tools as $t | $t + {
        "clang++":($t["clang++"]//$t.clang),
        "llvm-lib":($t["llvm-lib"]//$t["llvm-ar"]),
        "llvm-dlltool":($t["llvm-dlltool"]//$t["llvm-ar"])
        } | to_entries[] | [.key,.value.path] | @tsv' <<< "$plan") || return 1
    while IFS=$'\t' read -r name path; do
        [[ -L "$bin/$name" && "$(readlink -- "$bin/$name")" == "$path" ]] || return 7
    done <<< "$entries"
}

_xwb_source_inputs() {
    local project="$1" name hash entries='{}'
    for name in Cargo.toml Cargo.lock .cargo/config .cargo/config.toml; do
        hash=null
        if [[ -e "$project/$name" || -L "$project/$name" ]]; then
            _pkg_path_has_no_links "$project" "$name" || return 7
            [[ -f "$project/$name" ]] || return 7
            hash=$(_xwt_hash "$project/$name") || return $?
        fi
        entries=$(jq -cnS --argjson entries "$entries" --arg name "$name" --arg hash "$hash" \
            '$entries+{($name):(if $hash=="null" then null else $hash end)}') || return 1
    done
    printf '%s\n' "$entries"
}

# Hash identities and capture versions under exactly the build cwd/environment.
# stdout is a deterministic map; verbose version text is retained in files.
_xwb_versions() {
    local plan="$1" project="$2" dir="$3" envfile="$4" tool argument hash
    local -a environment=()
    while IFS= read -r -d '' argument; do environment+=("$argument"); done < "$envfile"
    _xwb_check_shims "$plan" "${dir%/*}/bin" || return $?
    mkdir "$dir" || return 1
    for tool in cargo cargo-xwin rustc clang lld-link llvm-ar; do
        argument=--version
        [[ "$tool" != cargo && "$tool" != rustc ]] || argument=-vV
        _xwb_run "$project" "$dir/$tool.txt" 30 env -i "${environment[@]}" "$tool" "$argument" || return $?
        [[ -s "$dir/$tool.txt" ]] || return 7
        hash=$(_xwt_hash "$dir/$tool.txt") || return $?
        printf '%s\t%s\n' "$tool" "$hash"
    done > "$dir/index.tsv"
    _xwb_check_shims "$plan" "${dir%/*}/bin" || return $?
    _xwt_check_tools "$plan" || return $?
    jq -RcsS 'split("\n")|map(select(length>0)|split("\t")|{key:.[0],value:.[1]})|from_entries' "$dir/index.tsv"
}

xwin_toolchain_build() ( _xwb_build "$@"; )

# Validate the actual build cwd, including a newly staged release snapshot.
_xwb_source_location() {
    local project="$1" target="$2" parent name
    for name in Cargo.toml Cargo.lock; do [[ -f "$project/$name" && ! -L "$project/$name" ]] || return 4; done
    parent=${project%/*}; [[ -n "$parent" ]] || parent=/
    while :; do
        for name in config config.toml; do
            [[ ! -e "$parent/.cargo/$name" && ! -L "$parent/.cargo/$name" ]] || {
                _xwt_log 'Stage the project outside ancestor Cargo configurations'; return 4;
            }
        done
        [[ "$parent" != / ]] || break
        parent=${parent%/*}; [[ -n "$parent" ]] || parent=/
    done
    [[ ! -e "$project/$target.json" && ! -L "$project/$target.json" ]] || return 4
}

# Reuse the same controlled cwd/environment for both dependency observations.
# Cargo-xwin's internal subprocess environment is not asserted by this receipt.
_xwb_metadata() {
    local project="$1" run="$2" phase="$3" binary="$4" package="$5" version="$6" offline="$7" seconds="$8" argument
    local -a environment=() command=("$run/bin/cargo" metadata --locked --format-version 1
        --filter-platform aarch64-pc-windows-msvc --manifest-path "$project/Cargo.toml")
    while IFS= read -r -d '' argument; do environment+=("$argument"); done < "$run/environment.nul"
    [[ "$offline" == false ]] || command+=(--offline)
    _xwb_run "$project" "$run/metadata-$phase.log" "$seconds" --stdout "$run/metadata-$phase.raw.json" \
        env -i "${environment[@]}" "${command[@]}" || return $?
    xwin_source_metadata "$run/metadata-$phase.raw.json" "$project" "$binary" "$package" \
        "$run/metadata-$phase.json" "$version" > "$run/selection-$phase.json"
}

# Emit the established DSR manifest profile, not a parallel release format.
# The manifest and its receipt become visible together through one directory
# rename. No successful release manifest is left behind by a validation failure.
_xwb_export_release() {
    local run="$1" repo="$2" tag="$3" tool="$4" asset="$5" source_hash="$6" uuid="$7" started="$8"
    local finished duration manifest_sha
    # shellcheck source=src/slsa.sh
    source "$_XWIN_BUILD_DIR/slsa.sh" || return 3
    finished=$(date -u +'%Y-%m-%dT%H:%M:%SZ') || return 1
    duration=$(( $(date +%s) - started ))
    ((duration >= 0)) || return 7
    mkdir "$run/.release-ready" || return 2
    jq -cn --arg tag "$tag" --arg tool "$tool" --arg asset "$asset" --arg uuid "$uuid" \
        --arg finished "$finished" --argjson duration "$duration" --arg source_hash "$source_hash" \
        --slurpfile result "$run/.result.json" --slurpfile source "$run/release-source.json" \
        --slurpfile selection "$run/selection-after.json" '
        $result[0] as $r | $source[0] as $s |
        {schema_version:"1.0.0",tool:$tool,version:$tag,run_id:$uuid,
         build_purpose:"release",publishable:true,requested_targets:["windows/arm64"],
         source:{git_sha:$s.git_sha,git_ref:$s.git_ref,repository:$s.repository,dependencies:[],
             snapshot_sha256:$s.snapshot_sha256,receipt_sha256:$source_hash},
         built_at:$finished,duration_ms:($duration*1000),status:"success",
         summary:{total:1,success:1,failed:0},
         hosts:[{platform:"windows/arm64",status:"success"}],
         build_environments:[{target:"windows/arm64",method:"pinned-cargo-xwin",
             build_influence_env:$r.build_influence_env,tool_versions:$r.tool_versions,
             toolchain:$r.toolchain,cargo_metadata:$selection[0],source_snapshot:$s,
             command:$r.command}],
         artifacts:[{name:$asset,target:"windows/arm64",sha256:$r.artifact.sha256,
             size_bytes:$r.artifact.size_bytes,archive_format:"binary",signed:false,
             signature_file:"",build_purpose:"release",publishable:true}]}' \
        > "$run/.release-ready/build-manifest.json" || return 1
    _slsa_manifest_statement "$run/.release-ready/build-manifest.json" "$repo" dsr:pinned-cargo-xwin >/dev/null || return $?
    [[ "$(_xwt_hash "$run/release-source.json")" == "$source_hash" ]] || return 7
    xwin_source_verify "$run/source" "$run/release-source.json" || return $?
    [[ "$(_xwt_hash "$run/artifacts/$asset")" == "$(jq -r '.artifact.sha256' "$run/.result.json")" ]] || return 7
    manifest_sha=$(_xwt_hash "$run/.release-ready/build-manifest.json") || return $?
    jq -c --arg path "$run/release/build-manifest.json" --arg sha "$manifest_sha" \
        '.+{release_manifest:{path:$path,sha256:$sha}}' "$run/.result.json" \
        > "$run/.release-ready/result.json" || return 1
    [[ ! -e "$run/release" && ! -L "$run/release" ]] || return 2
    mv -T -- "$run/.release-ready" "$run/release" || return 1
    cat "$run/release/result.json"
}

# The CLI backgrounds this non-subshell worker directly so $! is the process
# with the signal trap, not an intermediate asynchronous function wrapper.
_xwb_build() {
    set -uo pipefail
    umask 077
    local manifest='' project='' run='' binary='' package='' cache='' cargo_cache='' seconds=3600 offline=false
    local release_repo='' release_tag='' release_tool='' source_sha='' asset_name='' release=false
    local -A seen=()
    while (($#)); do
        [[ -n "$1" && -z "${seen[$1]:-}" ]] || return 4
        seen[$1]=1
        case "$1" in
            --offline) offline=true; shift ;;
            --manifest|--project|--run-dir|--bin|--package|--cache-dir|--cargo-cache|--timeout|--release-repo|--release-tag|--source-sha|--tool|--asset-name)
                [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || return 4
                case "$1" in
                    --manifest) manifest=$2 ;; --project) project=$2 ;; --run-dir) run=$2 ;;
                    --bin) binary=$2 ;; --package) package=$2 ;; --cache-dir) cache=$2 ;;
                    --cargo-cache) cargo_cache=$2 ;; --timeout) seconds=$2 ;;
                    --release-repo) release_repo=$2 ;; --release-tag) release_tag=$2 ;;
                    --source-sha) source_sha=$2 ;; --tool) release_tool=$2 ;; --asset-name) asset_name=$2 ;;
                esac
                shift 2 ;;
            *) _xwt_log "Unknown build option: $1"; return 4 ;;
        esac
    done
    [[ -f "$manifest" && ! -L "$manifest" && -d "$project" && ! -L "$project" &&
       "$binary" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ &&
       ( -z "$package" || "$package" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ) &&
       "$run" == /* && "$run" != *[[:space:][:cntrl:]]* && "$run" != *[\;\\:]* &&
       "$seconds" =~ ^[0-9]{1,5}$ ]] || return 4
    seconds=$((10#$seconds))
    ((seconds > 0 && seconds <= 86400)) || return 4
    if [[ -n "$release_repo$release_tag$source_sha$release_tool$asset_name" ]]; then
        [[ -n "$release_repo" && -n "$release_tag" && "$source_sha" =~ ^[0-9a-f]{40}$ ]] || return 4
        release=true
        [[ -n "$release_tool" ]] || release_tool=$binary
        [[ "$release_tool" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*$ && "$release_tool" != *..* ]] || return 4
        [[ -n "$asset_name" ]] || asset_name="$binary-aarch64-pc-windows-msvc.exe"
        [[ "$asset_name" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]*\.exe$ && "$asset_name" != *..* ]] || return 4
        # shellcheck source=src/xwin_source.sh
        source "$_XWIN_BUILD_DIR/xwin_source.sh" || return 3
        python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))' || return 3
    else
        asset_name="$binary.exe"
    fi
    _xwt_require || return $?
    local tool plan view entry name path key rustc target=aarch64-pc-windows-msvc manifest_hash lock_hash child=0 exit_trap
    local source_hash='' metadata_hash='' selection_hash='' controls='' uuid='' started
    started=$(date +%s) || return 1
    for tool in python3 setsid timeout readlink env; do command -v "$tool" >/dev/null || return 3; done
    project=$(cd "$project" && pwd -P) || return 4
    [[ "$project" != *[[:cntrl:]]* && "$project" != *\\* ]] || return 4
    if [[ "$release" == false ]]; then _xwb_source_location "$project" "$target" || return $?; fi
    plan=$(_xwt_manifest "$manifest") || return $?
    jq -e '.tools|has("llvm-ar")' <<< "$plan" >/dev/null || {
        _xwt_log 'Build execution additionally requires a pinned llvm-ar'; return 4;
    }
    _xwt_check_tools "$plan" || return $?
    # mkdir is the ownership boundary: no prior artifacts or receipts reused.
    [[ ! -e "$run" && ! -L "$run" ]] || return 2
    mkdir -- "$run" || return 2
    run=$(cd "$run" && pwd -P) || return 4
    [[ "$run" != *[[:space:][:cntrl:]]* && "$run" != *[\;\\:]* ]] || return 4
    mkdir "$run/bin" "$run/home" "$run/tmp" "$run/cargo-home" "$run/xwin" "$run/artifacts" || return 1
    _xwb_finish() {
        local rc=$? directory="$1"
        if ((rc != 0)); then
            jq -cn --argjson rc "$rc" '{kind:"dsr-xwin-build",status:"failed",exit_code:$rc}' > "$directory/failure.json"
        fi
    }
    _xwb_interrupt() {
        trap '' HUP INT TERM
        if ((child > 0)); then kill -TERM "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; fi
        exit 5
    }
    # Freeze the path for source callers whose worker locals have unwound
    # before the containing subshell runs its EXIT trap.
    printf -v exit_trap '_xwb_finish %q' "$run"
    trap "$exit_trap" EXIT
    trap _xwb_interrupt HUP INT TERM
    if [[ "$release" == true ]]; then
        xwin_source_snapshot "$project" "$source_sha" "$release_tag" "$release_repo" \
            "$run/source" "$run/release-source.json" || return $?
        source_hash=$(_xwt_hash "$run/release-source.json") || return $?
        project="$run/source"
        _xwb_source_location "$project" "$target" || return $?
        uuid=$(python3 -c 'import uuid; print(uuid.uuid4())') || return 1
    fi
    # Freeze the supplied manifest before both admission passes.
    printf '%s\n' "$plan" > "$run/manifest.json" || return 1
    xwin_toolchain_prepare "$run/manifest.json" "$cache" > "$run/toolchain.json" || return $?
    view=$(jq -r '.view' "$run/toolchain.json") || return 1
    key=$(jq -r '.manifest_sha256' "$run/toolchain.json") || return 1
    cache=${view%/*}
    ln -s -- "$view/sysroot" "$run/xwin/windows-msvc-sysroot" || return 1
    entry=$(jq -r '.tools|to_entries[]|[.key,.value.path]|@tsv' <<< "$plan") || return 1
    while IFS=$'\t' read -r name path; do
        ln -s -- "$path" "$run/bin/$name" || return 1
    done <<< "$entry"
    for name in llvm-lib llvm-dlltool clang++; do
        [[ ! -L "$run/bin/$name" ]] || continue
        tool=llvm-ar; [[ "$name" != clang++ ]] || tool=clang
        path=$(jq -r --arg tool "$tool" '.tools[$tool].path' <<< "$plan") || return 1
        ln -s -- "$path" "$run/bin/$name" || return 1
    done
    if [[ -n "$cargo_cache" ]]; then
        [[ -d "$cargo_cache" ]] || return 4
        cargo_cache=$(cd "$cargo_cache" && pwd -P) || return 4
        for name in registry git; do
            [[ ! -d "$cargo_cache/$name" ]] || ln -s -- "$cargo_cache/$name" "$run/cargo-home/$name" || return 1
        done
    fi
    rustc=$(jq -r '.tools.rustc.path' <<< "$plan") || return 1
    local -a environment=("HOME=$run/home" "PATH=$run/bin:/usr/bin:/bin" "TMPDIR=$run/tmp" "LC_ALL=C" "TZ=UTC"
        "CARGO_HOME=$run/cargo-home" "CARGO_TARGET_DIR=$run/target" "CARGO_INCREMENTAL=0" "RUSTC=$rustc"
        "CARGO=$run/bin/cargo" "RUSTC_WRAPPER=" "RUSTC_WORKSPACE_WRAPPER="
        "XWIN_CACHE_DIR=$run/xwin" "XWIN_CROSS_COMPILER=clang"
        "XWIN_MSVC_SYSROOT_DOWNLOAD_URL=$(jq -r '.sysroot.url' <<< "$plan")"
        "CFLAGS=-nobuiltininc -isystem $view/include" "CXXFLAGS=-nobuiltininc -isystem $view/include" "LIB=$view/lib")
    if [[ "$release" == true ]]; then
        environment+=("SOURCE_DATE_EPOCH=$(jq -r '.source_date_epoch' "$run/release-source.json")")
    fi
    printf '%s\0' "${environment[@]}" > "$run/environment.nul" || return 1
    jq -cn --args '$ARGS.positional|map(capture("^(?<key>[^=]+)=(?<value>.*)$"))|from_entries' \
        -- "${environment[@]}" > "$run/environment.json" || return 1
    manifest_hash=$(_xwt_hash "$project/Cargo.toml") || return $?
    lock_hash=$(_xwt_hash "$project/Cargo.lock") || return $?
    _xwb_source_inputs "$project" > "$run/source-before.json" || return $?
    _xwb_versions "$plan" "$project" "$run/versions-before" "$run/environment.nul" > "$run/versions-before.json" || return $?
    if [[ "$release" == true ]]; then
        _xwb_metadata "$project" "$run" before "$binary" "$package" "${release_tag#v}" "$offline" "$seconds" || return $?
        metadata_hash=$(_xwt_hash "$run/metadata-before.json") || return $?
        selection_hash=$(_xwt_hash "$run/selection-before.json") || return $?
        # Make Cargo build the very package admitted by metadata, even for a
        # virtual workspace with multiple default members.
        package=$(jq -r '.package' "$run/selection-before.json") || return 7
        xwin_source_verify "$project" "$run/release-source.json" || return $?
    fi
    # Invoke the pinned plugin directly: a project's Cargo alias named xwin
    # must not substitute a different executable for the attested plugin.
    local -a command=("$run/bin/cargo-xwin" xwin build --release --locked --target "$target" --bin "$binary"
        --manifest-path "$project/Cargo.toml" --target-dir "$run/target")
    [[ -z "$package" ]] || command+=(--package "$package")
    [[ "$offline" == false ]] || command+=(--offline)
    [[ "$release" == false ]] || command+=(--message-format=json)
    jq -cn --args '$ARGS.positional' -- "${command[@]}" > "$run/command.json" || return 1
    controls=$(sha256sum -- "$run/environment.nul" "$run/environment.json" "$run/command.json" \
        "$run/source-before.json" "$run/versions-before.json" "$run/manifest.json") || return 1
    _xwt_log "Building $binary for Windows ARM64; log: $run/build.log"
    local rc=0
    local -a capture=()
    [[ "$release" == false ]] || capture=(--stdout "$run/build.messages.jsonl")
    _xwb_run "$project" "$run/build.log" "$seconds" "${capture[@]}" env -i "${environment[@]}" "${command[@]}" &
    child=$!
    wait "$child" || rc=$?
    child=0
    ((rc == 0)) || { _xwt_log "Build exited $rc; retained $run/build.log"; return "$rc"; }
    [[ "$controls" == "$(sha256sum -- "$run/environment.nul" "$run/environment.json" "$run/command.json" \
        "$run/source-before.json" "$run/versions-before.json" "$run/manifest.json")" ]] || return 7
    if [[ "$release" == true ]]; then
        [[ "$source_hash" == "$(_xwt_hash "$run/release-source.json")" &&
           "$metadata_hash" == "$(_xwt_hash "$run/metadata-before.json")" &&
           "$selection_hash" == "$(_xwt_hash "$run/selection-before.json")" ]] || return 7
        _xwb_metadata "$project" "$run" after "$binary" "$package" "${release_tag#v}" "$offline" "$seconds" || return $?
        cmp -s "$run/metadata-before.json" "$run/metadata-after.json" || { _xwt_log 'Cargo dependency graph changed'; return 7; }
        cmp -s "$run/selection-before.json" "$run/selection-after.json" || return 7
        xwin_source_verify "$project" "$run/release-source.json" || return $?
        jq -es --slurpfile selected "$run/selection-after.json" \
            --arg path "$run/target/$target/release/$binary.exe" --arg project "$project" '
            all(.[];type=="object") and
            ([.[]|select(.reason=="build-finished")]|length==1 and .[0].success==true) and
            ([.[]|select(.reason=="compiler-artifact" and .package_id==$selected[0].package_id and
                .target.name==$selected[0].binary and (.target.kind|index("bin")!=null) and
                .target.src_path==($project+"/"+$selected[0].binary_source) and
                (.features|sort)==($selected[0].features|sort) and
                .profile.test==false and .executable==$path)]|length)==1' \
            "$run/build.messages.jsonl" >/dev/null || { _xwt_log 'Cargo did not attest the selected binary output'; return 7; }
    fi
    _xwb_versions "$plan" "$project" "$run/versions-after" "$run/environment.nul" > "$run/versions-after.json" || return $?
    cmp -s "$run/versions-before.json" "$run/versions-after.json" || return 7
    _xwb_source_inputs "$project" > "$run/source-after.json" || return $?
    cmp -s "$run/source-before.json" "$run/source-after.json" || return 7
    [[ "$manifest_hash" == "$(_xwt_hash "$project/Cargo.toml")" && "$lock_hash" == "$(_xwt_hash "$project/Cargo.lock")" ]] || return 7
    [[ "$(_xwt_hash "$run/manifest.json")" == "$key" ]] || return 7
    xwin_toolchain_prepare "$run/manifest.json" "$cache" verify > "$run/toolchain-after.json" || return $?
    _pkg_path_has_no_links "$run/target" "$target/release/$binary.exe" || return 7
    path="$run/target/$target/release/$binary.exe"
    [[ -f "$path" && ! -L "$path" ]] || return 7
    cp -- "$path" "$run/artifacts/$asset_name" || return 1
    xwin_validate_arm64_pe "$run/artifacts/$asset_name" > "$run/artifact.json" || return $?
    jq -cn --arg run "$run" --arg project "$project" --arg asset "$asset_name" --arg key "$key" \
        --arg manifest "$manifest_hash" --arg lock "$lock_hash" --slurpfile artifact "$run/artifact.json" \
        --slurpfile environment "$run/environment.json" --slurpfile command "$run/command.json" \
        --slurpfile source "$run/source-after.json" \
        --slurpfile versions "$run/versions-after.json" --slurpfile toolchain "$run/toolchain-after.json" \
        '{schema_version:1,kind:"dsr-xwin-build",status:"verified",exit_code:0,
          project:$project,target:"aarch64-pc-windows-msvc",cargo_manifest_sha256:$manifest,cargo_lock_sha256:$lock,
          manifest_sha256:$key,source_inputs:$source[0],artifact:($artifact[0]+{path:($run+"/artifacts/"+$asset)}),
          build_influence_env:$environment[0],command:$command[0],tool_versions:$versions[0],
          toolchain:$toolchain[0].evidence,build_log:($run+"/build.log")}' > "$run/.result.json" || return 1
    if [[ "$release" == true ]]; then
        _xwb_export_release "$run" "$release_repo" "$release_tag" "$release_tool" "$asset_name" "$source_hash" "$uuid" "$started"
        return $?
    fi
    mv -- "$run/.result.json" "$run/result.json" || return 1
    cat "$run/result.json"
}
