#!/usr/bin/env bash
# src/sbom.sh - Software Bill of Materials generation (bd-1jt.3.4)
#
# Syft inventories the selected files; a successful inventory does not establish
# build provenance, authenticity, absence of vulnerabilities, or package coverage.
# Validation below checks our supported document contract, not the entire SPDX or
# CycloneDX schema. File scans use a private snapshot and reject source drift.
# Directory scans are live observations, not immutable source attestations.

SBOM_DEFAULT_FORMAT="${SBOM_DEFAULT_FORMAT:-spdx}"
SBOM_OUTPUT_DIR="${SBOM_OUTPUT_DIR:-}"

_sbom_log() {
    local level="$1"
    shift
    if declare -F "log_$level" >/dev/null; then
        "log_$level" "$@" >&2
    else
        printf '[%s] %s\n' "${level^^}" "$*" >&2
    fi
}

_sbom_format() {
    case "$1" in
        spdx|spdx-json) printf '%s\n' spdx ;;
        cyclonedx|cdx|cyclonedx-json) printf '%s\n' cyclonedx ;;
        *) _sbom_log error "Unsupported SBOM format: $1"; return 4 ;;
    esac
}

_sbom_extension() {
    case "$1" in
        spdx) printf '%s\n' spdx.json ;;
        cyclonedx) printf '%s\n' cdx.json ;;
        *) return 4 ;;
    esac
}

_sbom_hash() {
    local digest
    [[ -f "$1" && ! -L "$1" ]] || return 4
    if command -v sha256sum >/dev/null; then
        digest=$(sha256sum -- "$1") || return 1
    elif command -v shasum >/dev/null; then
        digest=$(shasum -a 256 -- "$1") || return 1
    else
        _sbom_log error "sha256sum or shasum is required"
        return 3
    fi
    digest="${digest%% *}"
    [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$digest"
}

sbom_check() {
    command -v syft >/dev/null && return 0
    _sbom_log error "syft not installed - SBOM generation unavailable"
    return 3
}

sbom_version() {
    local text
    sbom_check || return $?
    text=$(syft version 2>/dev/null) || return 1
    [[ "$text" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]] || return 1
    printf '%s\n' "${BASH_REMATCH[1]}"
}

# Exactly one document, with typed required identity/creation fields and typed
# package collections when present. Empty package collections are valid; they
# are not evidence that Syft recognizes every package in the input.
_sbom_validate() {
    local file="$1" expected="${2:-}"
    [[ -f "$file" && ! -L "$file" ]] || return 4
    command -v jq >/dev/null || return 3
    jq -e -s --arg expected "$expected" '
        def text: type == "string" and length > 0 and
                  (test("[\\x00-\\x1f\\x7f]") | not);
        def positive_int: type == "number" and . >= 1 and . == floor;
        length == 1 and (.[0] |
            type == "object" and
            if has("spdxVersion") then
                ($expected == "" or $expected == "spdx") and
                (has("bomFormat") | not) and
                (.spdxVersion == "SPDX-2.2" or .spdxVersion == "SPDX-2.3") and
                .dataLicense == "CC0-1.0" and .SPDXID == "SPDXRef-DOCUMENT" and
                (.name | text) and
                (.documentNamespace | text and test("^[A-Za-z][A-Za-z0-9+.-]*:[^# ]+$")) and
                (.creationInfo | type == "object" and
                    (.creators | type == "array" and length > 0 and
                        all(.[]; text and test("^(Tool|Person|Organization): .+"))) and
                    (.created | type == "string" and
                        test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))) and
                (if has("packages") then .packages | type == "array" and
                    all(.[]; type == "object" and (.name | text) and
                        (.SPDXID | text and startswith("SPDXRef-")))
                 else true end)
            elif has("bomFormat") then
                ($expected == "" or $expected == "cyclonedx") and
                .bomFormat == "CycloneDX" and
                (.specVersion == "1.2" or .specVersion == "1.3" or
                 .specVersion == "1.4" or .specVersion == "1.5" or
                 .specVersion == "1.6" or .specVersion == "1.7") and
                (.version | positive_int) and
                (if has("components") then .components | type == "array" and
                    all(.[]; type == "object" and (.type | text) and (.name | text))
                 else true end)
            else false end)
    ' "$file" >/dev/null 2>&1
}

# Public validation accepts an optional expected format, so a CycloneDX document
# can never satisfy a request to generate SPDX (or vice versa).
sbom_verify() {
    local file="${1:-}" expected="" status
    [[ $# -gt 0 ]] && shift
    if [[ $# -gt 0 ]]; then
        [[ $# -eq 2 && "$1" == --format ]] || return 4
        expected=$(_sbom_format "$2") || return $?
    fi
    if _sbom_validate "$file" "$expected"; then
        _sbom_log ok "SBOM document verified (SPDX/CycloneDX): $file"
    else
        status=$?
        _sbom_log error "Invalid, unsupported, or unreadable SBOM document: $file"
        return "$status"
    fi
}

# Quote literal paths for Syft's relative directory exclusion glob syntax.
_sbom_glob_literal() {
    local value="$1" char result="" i
    for ((i=0; i<${#value}; i++)); do
        char="${value:i:1}"
        case "$char" in '*'|'?'|'['|']'|'{'|'}'|'\') result+="\\" ;; esac
        result+="$char"
    done
    printf '%s' "$result"
}

_sbom_has_signature() {
    local suffix
    for suffix in minisig sig asc; do
        [[ ! -e "$1.$suffix" && ! -L "$1.$suffix" ]] || return 0
    done
    return 1
}

# Return a stable state for a destination; never follow a final symlink.
_sbom_output_state() {
    [[ ! -L "$1" ]] || return 4
    if [[ -e "$1" ]]; then
        _sbom_hash "$1"
    else
        printf '%s\n' absent
    fi
}

# Args: target [--format spdx|cyclonedx] [--output file] [--quiet]
# stdout: one absolute output path. Exit: 1 scan/I/O/validation, 2 conflict,
# 3 missing dependency, 4 invalid input. No partial output is published.
sbom_generate() (
    set -o pipefail
    local target="${1:-}" format="$SBOM_DEFAULT_FORMAT" output="" quiet=false
    [[ $# -gt 0 ]] && shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format|-f|--output|-o)
                [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || {
                    _sbom_log error "Missing value for $1"; return 4;
                }
                case "$1" in --format|-f) format="$2" ;; *) output="$2" ;; esac
                shift 2 ;;
            --quiet|-q) quiet=true; shift ;;
            *) _sbom_log error "Unknown SBOM option: $1"; return 4 ;;
        esac
    done
    format=$(_sbom_format "$format") || return $?
    [[ -n "$target" && ! -L "$target" && ( -f "$target" || -d "$target" ) &&
       "$target" != *[[:cntrl:]]* && "$target" != *\\* ]] || {
        _sbom_log error "Target must be a regular file or directory: $target"; return 4;
    }
    local target_dir
    if [[ -d "$target" ]]; then
        target=$(cd "$target" && pwd -P) || return 4
    else
        target_dir=$(cd "$(dirname -- "$target")" && pwd -P) || return 4
        target="$target_dir/$(basename -- "$target")"
    fi
    local extension output_dir prior current workdir staged input_hash="" snapshot="" relative
    extension=$(_sbom_extension "$format") || return $?
    if [[ -z "$output" ]]; then
        if [[ -n "$SBOM_OUTPUT_DIR" ]]; then
            output="$SBOM_OUTPUT_DIR/$(basename -- "$target").sbom.$extension"
        elif [[ -d "$target" ]]; then
            output="$target/sbom.$extension"
        else
            # Retain the ENTIRE name: foo.tar.gz and foo.tar.xz are distinct.
            output="$target.sbom.$extension"
        fi
    fi
    [[ "$output" != *[[:cntrl:]]* && "$output" != *\\* && "$output" != */ ]] || return 4
    command -v jq >/dev/null || { _sbom_log error "jq is required"; return 3; }
    sbom_check || return $?
    mkdir -p -- "$(dirname -- "$output")" || return 1
    output_dir=$(cd "$(dirname -- "$output")" && pwd -P) || return 4
    output="$output_dir/$(basename -- "$output")"
    [[ ! "$output" -ef "$target" ]] || {
        _sbom_log error "SBOM output overlaps its input"; return 4;
    }
    prior=$(_sbom_output_state "$output") || return $?
    if [[ "$prior" != absent ]] && ! _sbom_validate "$output" "$format"; then
        _sbom_log error "Refusing to replace an invalid retained SBOM: $output"
        return 2
    fi
    if _sbom_has_signature "$output"; then
        _sbom_log error "Refusing to regenerate a signed SBOM: $output"
        return 2
    fi
    workdir=$(mktemp -d "$output_dir/.dsr-sbom.XXXXXXXX") || return 1
    trap 'rm -rf -- "$workdir"' EXIT
    trap 'exit 5' HUP INT TERM
    staged="$workdir/result.json"
    local -a args=(-o "$format-json")
    if [[ -f "$target" ]]; then
        input_hash=$(_sbom_hash "$target") || return $?
        mkdir "$workdir/input" || return 1
        snapshot="$workdir/input/$(basename -- "$target")"
        cp -- "$target" "$snapshot" || return 1
        [[ "$(_sbom_hash "$snapshot")" == "$input_hash" ]] || return 1
        args+=("file:$snapshot")
    else
        args+=("dir:$target")
        # Never catalogue our own output or in-progress staging directory.
        if [[ "$output" == "${target%/}/"* ]]; then
            relative="${output#"${target%/}/"}"
            args+=(--exclude "./$(_sbom_glob_literal "$relative")")
        fi
        if [[ "$workdir" == "${target%/}/"* ]]; then
            relative="${workdir#"${target%/}/"}"
            args+=(--exclude "./$(_sbom_glob_literal "$relative")/**")
        fi
    fi
    $quiet || _sbom_log info "Generating $format SBOM for: $target"
    local status
    if syft "${args[@]}" > "$staged" 2> "$workdir/scanner.stderr"; then
        :
    else
        status=$?
        _sbom_log error "SBOM generation failed (syft exit $status): $(head -c 8192 "$workdir/scanner.stderr")"
        return 1
    fi
    if ! _sbom_validate "$staged" "$format"; then
        _sbom_log error "Syft did not produce one valid $format document"
        return 1
    fi
    if [[ -n "$input_hash" ]]; then
        [[ "$(_sbom_hash "$target")" == "$input_hash" &&
           "$(_sbom_hash "$snapshot")" == "$input_hash" ]] || {
            _sbom_log error "SBOM source changed during scanning: $target"; return 2;
        }
    fi
    current=$(_sbom_output_state "$output") || return $?
    [[ "$current" == "$prior" ]] && ! _sbom_has_signature "$output" || {
        _sbom_log error "SBOM destination changed during scanning: $output"; return 2;
    }
    # Cooperating first-time publishers cannot clobber one another. Replacement
    # is failure-atomic, not a transaction against non-cooperating local writers.
    if [[ "$prior" == absent ]]; then
        ln -- "$staged" "$output" 2>/dev/null || {
            _sbom_log error "SBOM publication conflict: $output"; return 2;
        }
    elif ! cmp -s "$staged" "$output"; then
        mv -f -- "$staged" "$output" || return 1
    fi
    $quiet || _sbom_log ok "SBOM generated: $output"
    printf '%s\n' "$output"
)

sbom_generate_project() {
    [[ $# -gt 0 && -d "$1" && ! -L "$1" ]] || {
        _sbom_log error "Project path must be a directory"; return 4;
    }
    # Syft discovers ecosystems; do not drop output/quiet flags at this layer.
    sbom_generate "$@"
}

_sbom_is_metadata() {
    case "$1" in
        *.txt|*.json|*.yaml|*.yml|*.md|*.minisig|*.sig|*.asc|*.sha256|*.sha512|*.sum|\
        SHA256SUMS|SHA512SUMS|CHECKSUMS|checksums|LICENSE|LICENSE.*|NOTICE|README)
            return 0 ;;
        *) return 1 ;;
    esac
}

# Checked enumeration, including rejection of linked/special selected inputs.
# Names with spaces are supported; control characters/backslashes are not.
_sbom_select_artifacts() (
    set -o pipefail
    local root="$1" listing="$2" path name
    find "$root" -mindepth 1 -maxdepth 1 -print0 > "$listing" || return 1
    while IFS= read -r -d '' path; do
        name="${path##*/}"
        [[ ! -d "$path" || -L "$path" ]] || continue
        _sbom_is_metadata "$name" && continue
        [[ -f "$path" && ! -L "$path" && "$name" != *[[:cntrl:]]* &&
           "$name" != *\\* ]] || {
            _sbom_log error "Unsafe release artifact: $path"; return 4;
        }
        printf '%s\n' "$name"
    done < "$listing" | LC_ALL=C sort
)

# Batch generation never trusts the mere existence of an old sidecar. Each
# selected input is scanned and each output validated; failures remain nonzero.
sbom_generate_artifacts() (
    local root="${1:-}" format="$SBOM_DEFAULT_FORMAT" workdir selected name
    [[ $# -gt 0 ]] && shift
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --format|-f)
                [[ $# -ge 2 && -n "$2" ]] || return 4
                format="$2"; shift 2 ;;
            *) _sbom_log error "Unknown SBOM batch option: $1"; return 4 ;;
        esac
    done
    format=$(_sbom_format "$format") || return $?
    [[ -d "$root" && ! -L "$root" ]] || return 4
    root=$(cd "$root" && pwd -P) || return 4
    workdir=$(mktemp -d "${TMPDIR:-/tmp}/dsr-sbom-batch.XXXXXXXX") || return 1
    trap 'rm -rf -- "$workdir"' EXIT
    trap 'exit 5' HUP INT TERM
    selected=$(_sbom_select_artifacts "$root" "$workdir/list") || return $?
    [[ -n "$selected" ]] || { _sbom_log error "No release artifacts selected"; return 4; }
    command -v jq >/dev/null || return 3
    sbom_check || return $?
    local generated=0 failed=0
    while IFS= read -r name; do
        if sbom_generate "$root/$name" --format "$format" --quiet; then
            generated=$((generated + 1))
        else
            failed=$((failed + 1))
        fi
    done <<< "$selected"
    _sbom_log info "SBOM generation complete: $generated generated, $failed failed"
    [[ "$failed" -eq 0 ]]
)

# JSON is emitted on failure too, but never changes a failing process exit code.
# Diagnostics are captured separately, not spliced into output_file.
sbom_generate_json() (
    local target="${1:-}" format="$SBOM_DEFAULT_FORMAT" arg previous="" status=0
    local start=$SECONDS workdir output="" error="" state=success
    for arg in "$@"; do
        case "$previous" in --format|-f) format="$arg" ;; esac
        previous="$arg"
    done
    command -v jq >/dev/null || return 3
    workdir=$(mktemp -d "${TMPDIR:-/tmp}/dsr-sbom-json.XXXXXXXX") || return 1
    trap 'rm -rf -- "$workdir"' EXIT
    trap 'exit 5' HUP INT TERM
    if [[ $# -eq 0 ]]; then
        status=4; error="Target path required"
    elif output=$(sbom_generate "$@" --quiet 2> "$workdir/error"); then
        :
    else
        status=$?
        output=""
        error=$(head -c 8192 "$workdir/error")
        [[ -n "$error" ]] || error="SBOM generation failed (exit $status)"
    fi
    [[ "$status" -eq 0 ]] || state=error
    jq -nc --arg target "$target" --arg format "$format" --arg status "$state" \
        --arg output "$output" --arg error "$error" --argjson exit_code "$status" \
        --argjson duration "$((SECONDS - start))" '
        {target:$target, format:$format, status:$status, exit_code:$exit_code,
         output_file:(if $output == "" then null else $output end),
         error:(if $error == "" then null else $error end), duration_seconds:$duration}' || return 1
    return "$status"
)

export -f sbom_check sbom_version sbom_generate sbom_generate_project
export -f sbom_generate_artifacts sbom_verify sbom_generate_json
export -f _sbom_log _sbom_format _sbom_extension _sbom_hash _sbom_validate
export -f _sbom_glob_literal _sbom_has_signature _sbom_output_state
export -f _sbom_is_metadata _sbom_select_artifacts
