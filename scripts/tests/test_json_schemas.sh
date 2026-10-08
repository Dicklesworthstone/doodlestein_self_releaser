#!/usr/bin/env bash
# test_json_schemas.sh - Validate JSON fixtures against schemas
#
# Usage: ./test_json_schemas.sh
#
# Full validation requires ajv-cli or Python jsonschema; jq checks only basic structure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCHEMAS_DIR="$PROJECT_ROOT/schemas"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"

# Colors (disable with NO_COLOR=1)
if [[ -z "${NO_COLOR:-}" ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

log_pass() { echo -e "${GREEN}✓${NC} $1"; ((PASS_COUNT++)); }
log_fail() { echo -e "${RED}✗${NC} $1"; ((FAIL_COUNT++)); }
log_skip() { echo -e "${YELLOW}○${NC} $1"; ((SKIP_COUNT++)); }
log_info() { echo -e "${BLUE}→${NC} $1"; }

# Check if ajv-cli is available
use_ajv=false
use_python=false
if command -v ajv &>/dev/null; then
    use_ajv=true
    log_info "Using ajv-cli for schema validation"
elif command -v python3 >/dev/null && python3 -c 'from jsonschema import Draft202012Validator, FormatChecker' >/dev/null 2>&1; then
    use_python=true
    log_info "Using Python jsonschema Draft 2020-12 for schema validation"
else
    log_info "ajv-cli not found, using jq for basic validation"
    log_info "Install ajv-cli for full schema validation: npm install -g ajv-cli"
fi

validate_with_python() {
    python3 - "$2" "$1" <<'PY'
import json
import sys
from jsonschema import Draft202012Validator, FormatChecker
with open(sys.argv[1]) as stream:
    schema = json.load(stream)
with open(sys.argv[2]) as stream:
    value = json.load(stream)
Draft202012Validator.check_schema(schema)
errors = list(Draft202012Validator(schema, format_checker=FormatChecker()).iter_errors(value))
for error in errors:
    print("/".join(map(str, error.absolute_path)) + ": " + error.message, file=sys.stderr)
sys.exit(1 if errors else 0)
PY
}

validate_with_schema() {
    if $use_ajv; then
        validate_with_ajv "$@"
    else
        validate_with_python "$@"
    fi
}

validate_with_ajv() {
    local fixture="$1"
    local schema="$2"
    local ajv_entry ajv_root module_path

    ajv_entry=$(command -v ajv) || return 1
    if command -v realpath >/dev/null 2>&1; then
        ajv_entry=$(realpath "$ajv_entry") || return 1
    fi
    ajv_root=$(cd "$(dirname "$ajv_entry")/.." && pwd -P) || return 1
    module_path="$ajv_root/node_modules:$(dirname "$ajv_root")"

    NODE_DISABLE_COMPILE_CACHE=1 \
    NODE_PATH="$module_path${NODE_PATH:+:$NODE_PATH}" \
        node - "$schema" "$fixture" <<'NODE'
const fs = require("fs");
const Ajv2020 = require("ajv/dist/2020").default;

const schema = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const data = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
const formats = {
    uuid: /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i,
    "date-time": /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/,
    uri: value => {
        try {
            return Boolean(new URL(value).protocol);
        } catch (_) {
            return false;
        }
    },
};
const ajv = new Ajv2020({ allErrors: true, strict: false, formats });
const validate = ajv.compile(schema);

if (!validate(data)) {
    console.error(ajv.errorsText(validate.errors, { separator: "\n" }));
    process.exit(1);
}
NODE
}

validate_with_jq() {
    local fixture="$1"
    # shellcheck disable=SC2034  # schema_name reserved for future validation logic
    local schema_name="$2"

    # Basic structural validation with jq
    local errors=()

    # Check required envelope fields
    local required_fields=("command" "status" "exit_code" "run_id" "started_at" "duration_ms" "tool" "version")
    for field in "${required_fields[@]}"; do
        if ! jq -e ".$field" "$fixture" &>/dev/null; then
            errors+=("Missing required field: $field")
        fi
    done

    # Validate status enum
    local status
    status=$(jq -r '.status' "$fixture" 2>/dev/null)
    if [[ ! "$status" =~ ^(success|partial|error)$ ]]; then
        errors+=("Invalid status: $status (expected success|partial|error)")
    fi

    # Validate exit_code is integer
    if ! jq -e '.exit_code | type == "number"' "$fixture" &>/dev/null; then
        errors+=("exit_code must be a number")
    fi

    # Validate tool is "dsr"
    local tool
    tool=$(jq -r '.tool' "$fixture" 2>/dev/null)
    if [[ "$tool" != "dsr" ]]; then
        errors+=("tool must be 'dsr', got '$tool'")
    fi

    # Validate artifacts array structure if present
    if jq -e '.artifacts | length > 0' "$fixture" &>/dev/null; then
        if ! jq -e '.artifacts[0].name and .artifacts[0].target and .artifacts[0].sha256' "$fixture" &>/dev/null; then
            errors+=("Artifacts missing required fields (name, target, sha256)")
        fi
    fi

    if [[ ${#errors[@]} -gt 0 ]]; then
        for err in "${errors[@]}"; do
            echo "  - $err" >&2
        done
        return 1
    fi
    return 0
}

validate_manifest_with_jq() {
    local fixture="$1"

    local errors=()

    # Required manifest fields
    local required_fields=("schema_version" "tool" "version" "run_id" "source" "built_at" "status" "summary" "artifacts")
    for field in "${required_fields[@]}"; do
        if ! jq -e ".$field" "$fixture" &>/dev/null; then
            errors+=("Missing required field: $field")
        fi
    done

    # Validate schema_version
    local schema_version
    schema_version=$(jq -r '.schema_version' "$fixture" 2>/dev/null)
    if [[ "$schema_version" != "1.0.0" ]]; then
        errors+=("schema_version must be 1.0.0 (got: $schema_version)")
    fi

    if ! jq -e '
        (.source | type == "object") and
        (.source.git_sha | type == "string" and test("^(?!0{40}$)[0-9a-f]{40}$")) and
        (.source.git_ref | type == "string" and length > 0) and
        (.source.dependencies | type == "array") and
        all(.source.dependencies[];
            (keys | sort) == ["git_sha", "relative_path"] and
            (.relative_path | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._+-]*$") and (contains("..") | not)) and
            (.git_sha | type == "string" and test("^(?!0{40}$)[0-9a-f]{40}$"))
        )
    ' "$fixture" &>/dev/null; then
        errors+=("source must contain exact git identity and canonical pinned dependencies")
    fi

    if ! jq -e '.status | type == "string" and test("^(success|partial|failed)$")' "$fixture" &>/dev/null; then
        errors+=("status must be success, partial, or failed")
    fi

    if ! jq -e '
        (.summary | type == "object") and
        ([.summary.total, .summary.success, .summary.failed] | all(type == "number" and floor == . and . >= 0)) and
        .summary.total == (.summary.success + .summary.failed)
    ' "$fixture" &>/dev/null; then
        errors+=("summary must contain coherent non-negative integer counts")
    fi

    # Validate artifacts structure
    if jq -e '.artifacts | length > 0' "$fixture" &>/dev/null; then
        if ! jq -e '
            all(.artifacts[];
                (.name | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._+\\-]*$") and (contains("..") | not) and (ascii_downcase | endswith(".sha256") | not)) and
                (.target | type == "string" and test("^(linux|darwin|windows)/(amd64|arm64|386)$")) and
                (.sha256 | type == "string" and test("^[a-f0-9]{64}$")) and
                (.size_bytes | type == "number" and floor == . and . > 0) and
                (.archive_format | IN("tar.gz", "tar.xz", "zip", "binary", "none"))
            )
        ' "$fixture" &>/dev/null; then
            errors+=("Artifacts violate required basename, target, checksum, size, or archive-format rules")
        fi
    else
        errors+=("artifacts must be a non-empty array")
    fi

    if [[ ${#errors[@]} -gt 0 ]]; then
        for err in "${errors[@]}"; do
            echo "  - $err" >&2
        done
        return 1
    fi
    return 0
}

test_manifest_schema_release_contract_fields() {
    echo ""
    log_info "Testing manifest release-contract schema fields..."

    if jq -e '
        (.required | index("source")) and
        (.required | index("status")) and
        (.required | index("summary")) and
        (."$defs".source.required | index("dependencies")) and
        (."$defs".source_dependency.required | index("relative_path")) and
        (."$defs".source_dependency.required | index("git_sha")) and
        (.properties.build_environments.items."$ref" == "#/$defs/build_environment") and
        (."$defs".build_environment.oneOf | any(."$ref" == "#/$defs/native_build_environment")) and
        (."$defs".native_build_environment.required | index("cargo_isolation")) and
        (."$defs".build_environment.oneOf | any(."$ref" == "#/$defs/xwin_build_environment")) and
        (."$defs".xwin_build_environment.required | index("toolchain")) and
        (."$defs".xwin_build_environment.required | index("cargo_metadata")) and
        (."$defs".xwin_build_environment.additionalProperties == false) and
        (."$defs".cargo_isolation.required | index("ancestor_config_policy")) and
        (."$defs".artifact.required | index("archive_format")) and
        (."$defs".artifact.properties.archive_format.enum | index("binary"))
    ' "$SCHEMAS_DIR/manifest.json" &>/dev/null; then
        log_pass "Manifest schema covers source pins, isolation receipts, and strict binary assets"
    else
        log_fail "Manifest schema is missing strict release-contract requirements"
    fi
}

test_xwin_manifest_schema() {
    echo ""
    log_info "Testing typed native and pinned cargo-xwin manifest evidence..."
    if ! command -v python3 >/dev/null || ! python3 -c 'from jsonschema import Draft202012Validator, FormatChecker' >/dev/null 2>&1; then
        log_skip "Typed producer mutation tests require Python jsonschema; jq is not schema validation"
        return
    fi
    # Optional newline-separated paths select actual retained producer outputs.
    # Without them, these are explicitly structural protocol fixtures, not
    # claims of compiler execution. The real source-pinned runner tests retain
    # manifests that can be supplied unchanged through this same validator.
    if python3 - "$SCHEMAS_DIR/manifest.json" "${DSR_XWIN_SCHEMA_MANIFESTS:-}" "${DSR_XWIN_SCHEMA_PACKAGED_MANIFESTS:-}" <<'PY'
import copy
import json
from pathlib import Path
import sys
from jsonschema import Draft202012Validator, FormatChecker

schema = json.loads(Path(sys.argv[1]).read_text())
Draft202012Validator.check_schema(schema)
validator = Draft202012Validator(schema, format_checker=FormatChecker())
checks = 0

def check(label, value, valid=True, selected=validator):
    global checks
    errors = list(selected.iter_errors(value))
    if bool(errors) == valid:
        details = "; ".join("/".join(map(str, e.absolute_path)) + ": " + e.message for e in errors[:3])
        raise AssertionError(label + (": " + details if errors else ": invalid producer accepted"))
    checks += 1
    print("PASS " + label, flush=True)

digest = "a" * 64
commit = "b" * 40
roles = ("cargo", "cargo-xwin", "rustc", "clang", "lld-link", "llvm-ar")

def protocol_fixture(platform, triple):
    archive = dict(path="/pinned/input.tar.xz", prefix="sdk", sha256=digest, url="https://example.invalid/pinned/input.tar.xz")
    toolchain = dict(schema_version=1, kind="dsr-xwin-toolchain", manifest_sha256=digest, target=triple,
        inputs=dict(schema_version=1, target=triple, sysroot=archive, headers=dict(archive, prefix="include"),
                    aliases={"Kernel32.lib":"kernel32.lib"},
                    tools={role:dict(path="/pinned/"+role, sha256=digest) for role in roles}),
        files=[dict(path="include", type="directory", sha256="", size_bytes=0),
               dict(path="include/header.h", type="file", sha256=digest, size_bytes=1)])
    source = dict(schema_version=1, kind="dsr-xwin-source", repository="https://github.com/owner/demo",
        git_sha=commit, git_ref="refs/tags/v1.2.3", git_tree="c"*40, source_date_epoch=1, snapshot_sha256=digest,
        files=[dict(path="src/main.rs", sha256=digest, size_bytes=1, executable=False)])
    binary = dict(package_id="path+file:///build/source#demo@1.2.3", package="demo", version="1.2.3", binary="demo",
                  manifest="Cargo.toml", binary_source="src/main.rs", features=[])
    dependency_sources = dict(schema_version=1, kind="dsr-cargo-dependency-sources", sha256=digest, metadata_sha256=digest,
        package_count=0, root_count=0, file_count=0, size_bytes=0,
        authentication=dict(lockfile_sha256=digest, locked_archive_packages=0, locked_git_packages=0, workspace_snapshot_packages=0))
    metadata = dict(binary, binaries=[copy.deepcopy(binary)], metadata_sha256=digest, source_dependencies=[],
                    resolved_siblings=[], resolved_packages=1, dependency_sources=dependency_sources)
    cache = dict(schema_version=1, cargo_home="/build/cargo-home", receipt_path="/build/receipt.json",
                 receipt_sha256=digest, inventory_sha256=digest, caches=[], file_count=0, size_bytes=0)
    environment = dict(target=platform, target_triple=triple, host="local", method="pinned-cargo-xwin", build_influence_env={},
        tool_versions={role:digest for role in roles}, toolchain=toolchain, cargo_metadata=metadata, source_snapshot=source,
        cargo_cache=dict(mode="private-copy", seed=dict(cache, mode="private-copy", selection=dict(kind="cargo-lock-downloads",
            lockfile_sha256=digest, registry_packages=0, git_revisions=[])), final=dict(cache, mode="inventory")),
        feature_selection=dict(features=[], all_features=False, no_default_features=False),
        command=["/build/bin/cargo-xwin", "xwin", "build", "--release", "--locked", "--target", triple])
    return dict(schema_version="1.0.0", tool="demo", version="v1.2.3", run_id="11111111-1111-4111-8111-111111111111",
        built_at="2026-10-08T00:00:00Z", status="success", summary=dict(total=1,success=1,failed=0),
        source=dict(git_sha=commit,git_ref="refs/tags/v1.2.3",dependencies=[],repository=source["repository"],
                    snapshot_sha256=digest,receipt_sha256=digest),
        requested_targets=[platform], hosts=[dict(host="local",platform=platform,status="success",method="local")],
        build_environments=[environment], artifacts=[dict(name="demo-"+triple+".exe",target=platform,target_triple=triple,
            sha256=digest,size_bytes=1,archive_format="binary")])

actual = [Path(p) for p in sys.argv[2].splitlines() if p]
fixtures = []
for path in actual:
    value = json.loads(path.read_text())
    check("actual source-pinned producer manifest " + str(path), value)
    fixtures.append(value)
if not fixtures:
    fixtures = [protocol_fixture(platform, triple) for platform, triple in (
        ("windows/amd64","x86_64-pc-windows-msvc"), ("windows/arm64","aarch64-pc-windows-msvc"))]
    for fixture in fixtures:
        check("explicit structural producer fixture " + fixture["build_environments"][0]["target"], fixture)

missing = object()
for fixture in fixtures:
    environment = fixture["build_environments"][0]
    platform, triple = environment["target"], environment["target_triple"]
    opposite = "aarch64-pc-windows-msvc" if triple == "x86_64-pc-windows-msvc" else "x86_64-pc-windows-msvc"
    other_platform = "windows/arm64" if platform == "windows/amd64" else "windows/amd64"
    env = ("build_environments",0)
    # The packager retains the build environment but projects new archive/raw
    # alias rows from its recipe. The coordinator requires raw producer triples;
    # the general manifest schema validates declared triples without requiring
    # a field that this established derived-manifest profile does not emit.
    derived = copy.deepcopy(fixture)
    for asset in derived["artifacts"]:
        asset.pop("target_triple", None)
    check(platform + " permits derived asset rows while retaining the complete build environment", derived)
    cases = [
        ("producer platform",env+("target",),other_platform),
        ("producer triple",env+("target_triple",),opposite),
        ("toolchain target",env+("toolchain","target"),opposite),
        ("pinned input target",env+("toolchain","inputs","target"),opposite),
        ("artifact target triple",("artifacts",0,"target_triple"),opposite),
        ("missing producer triple",env+("target_triple",),missing),
        ("native method cannot hide xwin evidence",env+("method",),"native"),
        ("unknown producer field",env+("unreviewed",),True),
        ("toolchain kind",env+("toolchain","kind"),"unverified"),
        ("missing executable pin",env+("toolchain","inputs","tools","rustc"),missing),
        ("malformed executable hash",env+("toolchain","inputs","tools","rustc","sha256"),"bad"),
        ("missing version role",env+("tool_versions","cargo-xwin"),missing),
        ("version text cannot replace its digest",env+("tool_versions","rustc"),"rustc 1.90.0"),
        ("unpinned archive URL",env+("toolchain","inputs","sysroot","url"),"http://example.invalid/sdk.tar.xz"),
        ("missing import library alias",env+("toolchain","inputs","aliases","Kernel32.lib"),missing),
        ("unsafe toolchain inventory path",env+("toolchain","files",0,"path"),"../outside"),
        ("missing lock-selected cache seed",env+("cargo_cache","seed","selection"),missing),
        ("final cache must be inventoried",env+("cargo_cache","final","mode"),"private-copy"),
        ("malformed cache receipt digest",env+("cargo_cache","seed","receipt_sha256"),"bad"),
        ("missing Cargo metadata",env+("cargo_metadata",),missing),
        ("missing binary selection",env+("cargo_metadata","binaries"),[]),
        ("unknown Cargo metadata field",env+("cargo_metadata","unreviewed"),True),
        ("missing source metadata binding",env+("cargo_metadata","dependency_sources","metadata_sha256"),missing),
        ("boolean package count",env+("cargo_metadata","dependency_sources","package_count"),True),
        ("missing dependency authentication",env+("cargo_metadata","dependency_sources","authentication"),missing),
        ("source receipt kind",env+("source_snapshot","kind"),"unverified"),
        ("unsafe source inventory path",env+("source_snapshot","files",0,"path"),"../outside"),
        ("malformed source inventory digest",env+("source_snapshot","files",0,"sha256"),"bad"),
        ("source executable bit must be boolean",env+("source_snapshot","files",0,"executable"),1),
        ("unbound sibling source layout",env+("source_snapshot","primary_path"),"elsewhere"),
        ("malformed public repository",("source","repository"),"https://example.invalid/owner/demo"),
        ("malformed public source receipt",("source","receipt_sha256"),"bad"),
        ("feature switch must be boolean",env+("feature_selection","all_features"),1),
        ("missing command",env+("command",),[]),
    ]
    for label, path, replacement in cases:
        changed = copy.deepcopy(fixture)
        selected = changed
        for key in path[:-1]:
            selected = selected[key]
        if replacement is missing:
            selected.pop(path[-1])
        else:
            selected[path[-1]] = replacement
        check(platform + " refuses " + label, changed, False)

for path in [Path(p) for p in sys.argv[3].splitlines() if p]:
    packaged = json.loads(path.read_text())
    check("actual packager manifest " + str(path), packaged)
    changed = copy.deepcopy(packaged)
    asset = changed["artifacts"][0]
    asset["target_triple"] = "aarch64-pc-windows-msvc" if asset["target"] == "windows/amd64" else "x86_64-pc-windows-msvc"
    check("packaged artifact cannot declare another platform's triple", changed, False)

# Resolve only the environment profile without inheriting top-level required fields.
native_validator = Draft202012Validator({"$schema":schema["$schema"],"$defs":schema["$defs"],
                                       "$ref":"#/$defs/build_environment"}, format_checker=FormatChecker())
native = dict(target="linux/amd64",host="local",method="native",build_influence_env={},cargo_isolation=None)
check("native profile retains its existing valid shape",native,selected=native_validator)
for label, mutation in (("missing isolation",lambda v:v.pop("cargo_isolation")),
                        ("xwin evidence injected",lambda v:v.update(toolchain={})),
                        ("unknown native method",lambda v:v.update(method="custom"))):
    changed = copy.deepcopy(native); mutation(changed)
    check("native profile still refuses "+label,changed,False,native_validator)
print("Typed producer schema checks: " + str(checks) + " passed",flush=True)
PY
    then
        log_pass "Draft 2020-12 validates typed native/xwin profiles and rejects contradictory evidence"
    else
        log_fail "Typed native/xwin manifest schema regression"
    fi
}

validate_fixture() {
    local fixture="$1"
    local fixture_name
    fixture_name=$(basename "$fixture")

    # Determine which detail schema to use based on command
    local command
    command=$(jq -r '.command // empty' "$fixture" 2>/dev/null)
    local is_manifest=false
    if [[ -z "$command" ]]; then
        if jq -e '.schema_version and .artifacts' "$fixture" &>/dev/null 2>&1; then
            is_manifest=true
        fi
    fi
    local detail_schema="$SCHEMAS_DIR/${command}-details.json"

    echo ""
    if $is_manifest; then
        log_info "Validating: $fixture_name (manifest schema)"
    else
        log_info "Validating: $fixture_name (command: $command)"
    fi

    # Validate against envelope schema
    if $use_ajv || $use_python; then
        if $is_manifest; then
            if validate_with_schema "$fixture" "$SCHEMAS_DIR/manifest.json"; then
                log_pass "Manifest schema validation"
            else
                log_fail "Manifest schema validation"
            fi
            return
        fi

        if validate_with_schema "$fixture" "$SCHEMAS_DIR/envelope.json"; then
            log_pass "Envelope schema validation"
        else
            log_fail "Envelope schema validation"
        fi

        # Validate details against command-specific schema
        if [[ -f "$detail_schema" ]]; then
            # Extract details and validate
            local details_tmp
            details_tmp=$(mktemp)
            jq '.details' "$fixture" > "$details_tmp"
            if validate_with_schema "$details_tmp" "$detail_schema"; then
                log_pass "Details schema validation ($command)"
            else
                log_fail "Details schema validation ($command)"
            fi
            rm -f "$details_tmp"
        else
            log_skip "No detail schema for command: $command"
        fi
    else
        # Fall back to jq validation
        if $is_manifest; then
            if validate_manifest_with_jq "$fixture"; then
                log_pass "Manifest structure validation"
            else
                log_fail "Manifest structure validation"
            fi
        else
            if validate_with_jq "$fixture" "envelope"; then
                log_pass "Basic structure validation"
            else
                log_fail "Basic structure validation"
            fi
        fi
    fi
}

# Test exit code consistency
test_exit_code_consistency() {
    echo ""
    log_info "Testing exit code consistency..."

    for fixture in "$FIXTURES_DIR"/*.json; do
        [[ -f "$fixture" ]] || continue
        local fixture_name
        fixture_name=$(basename "$fixture")

        local command
        command=$(jq -r '.command // empty' "$fixture")
        if [[ -z "$command" ]]; then
            log_skip "$fixture_name: no command field (not an envelope fixture)"
            continue
        fi

        local status exit_code
        status=$(jq -r '.status' "$fixture")
        exit_code=$(jq -r '.exit_code' "$fixture")

        # Verify exit code matches status
        case "$status" in
            "success")
                if [[ "$exit_code" -eq 0 ]]; then
                    log_pass "$fixture_name: status=success → exit_code=0"
                else
                    log_fail "$fixture_name: status=success but exit_code=$exit_code (expected 0)"
                fi
                ;;
            "partial"|"error")
                if [[ "$exit_code" -gt 0 ]]; then
                    log_pass "$fixture_name: status=$status → exit_code=$exit_code (non-zero)"
                else
                    log_fail "$fixture_name: status=$status but exit_code=0 (expected >0)"
                fi
                ;;
        esac
    done
}

# Test timestamp format
test_timestamp_format() {
    echo ""
    log_info "Testing ISO8601 timestamp format..."

    local iso8601_regex='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

    for fixture in "$FIXTURES_DIR"/*.json; do
        [[ -f "$fixture" ]] || continue
        local fixture_name
        fixture_name=$(basename "$fixture")

        local command
        command=$(jq -r '.command // empty' "$fixture")
        if [[ -z "$command" ]]; then
            log_skip "$fixture_name: no started_at field (not an envelope fixture)"
            continue
        fi

        local started_at
        started_at=$(jq -r '.started_at' "$fixture")

        if [[ "$started_at" =~ $iso8601_regex ]]; then
            log_pass "$fixture_name: started_at is valid ISO8601"
        else
            log_fail "$fixture_name: started_at '$started_at' is not valid ISO8601"
        fi
    done
}

# Test UUID format
test_uuid_format() {
    echo ""
    log_info "Testing UUID format for run_id..."

    local uuid_regex='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

    for fixture in "$FIXTURES_DIR"/*.json; do
        [[ -f "$fixture" ]] || continue
        local fixture_name
        fixture_name=$(basename "$fixture")

        local run_id
        run_id=$(jq -r '.run_id' "$fixture")

        if [[ "$run_id" =~ $uuid_regex ]]; then
            log_pass "$fixture_name: run_id is valid UUID"
        else
            log_fail "$fixture_name: run_id '$run_id' is not valid UUID"
        fi
    done
}

# Test SHA256 checksum format
test_sha256_format() {
    echo ""
    log_info "Testing SHA256 checksum format..."

    local sha256_regex='^[a-f0-9]{64}$'

    for fixture in "$FIXTURES_DIR"/*.json; do
        [[ -f "$fixture" ]] || continue
        local fixture_name
        fixture_name=$(basename "$fixture")

        # Check artifacts if present
        local artifact_count
        artifact_count=$(jq '.artifacts | length' "$fixture")

        if [[ "$artifact_count" -gt 0 ]]; then
            local all_valid=true
            while IFS= read -r sha; do
                if [[ ! "$sha" =~ $sha256_regex ]]; then
                    all_valid=false
                    log_fail "$fixture_name: Invalid SHA256 '$sha'"
                fi
            done < <(jq -r '.artifacts[].sha256' "$fixture")

            if $all_valid; then
                log_pass "$fixture_name: All artifact SHA256 checksums valid"
            fi
        else
            log_skip "$fixture_name: No artifacts to check"
        fi
    done
}

# Main
main() {
    echo "═══════════════════════════════════════════════════════════════"
    echo "  DSR JSON Schema Validation Tests"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
    echo "Schemas directory: $SCHEMAS_DIR"
    echo "Fixtures directory: $FIXTURES_DIR"

    # Verify directories exist
    if [[ ! -d "$SCHEMAS_DIR" ]]; then
        log_fail "Schemas directory not found: $SCHEMAS_DIR"
        exit 1
    fi

    if [[ ! -d "$FIXTURES_DIR" ]]; then
        log_fail "Fixtures directory not found: $FIXTURES_DIR"
        exit 1
    fi

    # Run schema validation on each fixture
    for fixture in "$FIXTURES_DIR"/*.json; do
        [[ -f "$fixture" ]] || continue
        validate_fixture "$fixture"
    done

    # Run additional tests
    test_exit_code_consistency
    test_timestamp_format
    test_uuid_format
    test_sha256_format
    test_manifest_schema_release_contract_fields
    test_xwin_manifest_schema

    # Summary
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  Summary"
    echo "═══════════════════════════════════════════════════════════════"
    echo -e "  ${GREEN}Passed:${NC}  $PASS_COUNT"
    echo -e "  ${RED}Failed:${NC}  $FAIL_COUNT"
    echo -e "  ${YELLOW}Skipped:${NC} $SKIP_COUNT"
    echo ""

    if [[ $FAIL_COUNT -gt 0 ]]; then
        echo -e "${RED}Some tests failed!${NC}"
        exit 1
    else
        echo -e "${GREEN}All tests passed!${NC}"
        exit 0
    fi
}

main "$@"
