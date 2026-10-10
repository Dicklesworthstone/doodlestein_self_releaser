#!/usr/bin/env bash
# Real release_bundle import/recovery and SLSA operations over owned fixtures.
# No compiler, transport, signing, GitHub publication or native ABI qualification.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUNDLE="${RELEASE_BUNDLE_TEST_MODULE:-$ROOT/src/release_bundle.sh}"
SLSA="${SLSA_TEST_MODULE:-$ROOT/src/slsa.sh}"
for dependency in jq python3 sha256sum flock; do
    command -v "$dependency" >/dev/null || { printf 'Missing dependency: %s\n' "$dependency" >&2; exit 3; }
done
WORK=$(mktemp -d "${TMPDIR:-/tmp}/dsr-bundle-variants.XXXXXXXX") || exit 1
printf 'Retained test evidence: %s\n' "$WORK"
passed=0 failed=0 status=0
check() {
    local label="$1"; shift
    if "$@"; then passed=$((passed + 1)); printf 'PASS: %s\n' "$label"
    else failed=$((failed + 1)); printf 'FAIL: %s\n' "$label" >&2; fi
}
run() { status=0; "$@" > "$WORK/stdout" 2> "$WORK/stderr" || status=$?; }
hash() { sha256sum < "$1" | cut -d ' ' -f 1; }
# Call the public API with real modules; override paths only select an
# incumbent revision for paired runs. No production function is substituted.
bundle() {
    bash -c 'source "$1" && source "$2" && shift 2 && release_bundle "$@"' _ "$SLSA" "$BUNDLE" "$@"
}
fixture() {
    python3 - "$1" "$2" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
arch = sys.argv[2]
platform = f"linux/{arch}"
cpu = "x86_64" if arch == "amd64" else "aarch64"
pin = "1" * 40

def write_json(path, value):
    path.write_text(json.dumps(value, sort_keys=True) + "\n")

def manifest(name, target, variants):
    directory = root / name
    directory.mkdir(parents=True)
    artifacts, environments = [], []
    for abi, triple in variants:
        filename = f"app-{arch}-{abi}" if name == "linux" else "app-windows.exe"
        payload = f"Owned {arch} {abi} test payload\n".encode()
        (directory / filename).write_bytes(payload)
        artifacts.append(dict(name=filename, target=target, target_triple=triple,
                              sha256=hashlib.sha256(payload).hexdigest(),
                              size_bytes=len(payload), archive_format="binary"))
        environments.append(dict(target=target, target_triple=triple, method="native", host=name,
            build_influence_env=dict(CARGO_BUILD_TARGET=triple, DSR_TARGET_TRIPLE=triple,
                                    DSR_RELEASE_GIT_SHA=pin, DSR_RELEASE_GIT_REF="v1.2.3"),
            cargo_isolation=dict(mode="strict-release-snapshot", toolchain=dict(target_triple=triple,
                                 compiler_sha256="a" * 64))))
    if name == "linux":
        alias = dict(artifacts[0], name=f"app-{arch}-alias")
        (directory / alias["name"]).write_bytes((directory / artifacts[0]["name"]).read_bytes())
        artifacts.append(alias)
    value = dict(schema_version="1.0.0", tool="app", version="v1.2.3",
        run_id="11111111-1111-4111-8111-111111111111" if name == "linux" else "22222222-2222-4222-8222-222222222222",
        source=dict(git_sha=pin, git_ref="v1.2.3", dependencies=[]),
        build_purpose="release", publishable=True, status="success", built_at="2026-10-09T01:02:03Z",
        summary=dict(total=len(variants), success=len(variants), failed=0), requested_targets=[target],
        artifacts=artifacts, build_environments=environments)
    path = directory / "manifest.json"
    write_json(path, value)
    return dict(id=name, manifest=str(path), artifacts_dir=str(directory),
                manifest_sha256=hashlib.sha256(path.read_bytes()).hexdigest(), targets=[target]), artifacts

linux, la = manifest("linux", platform, [("gnu", f"{cpu}-unknown-linux-gnu"), ("musl", f"{cpu}-unknown-linux-musl")])
windows, wa = manifest("windows", "windows/amd64", [("windows", "x86_64-pc-windows-msvc")])
write_json(root / "plan.json", dict(schema_version=1, tool="app", repo="example/app", tag="v1.2.3", source_sha=pin,
    required_targets=[platform, "windows/amd64"], builds=[linux, windows],
    required_assets=[{k: a[k] for k in ("name", "target", "archive_format")} for a in la + wa]))
PY
}

for arch in amd64 arm64; do
    case_dir="$WORK/$arch"
    fixture "$case_dir" "$arch" || exit 1
    plan="$case_dir/plan.json"
    output="$case_dir/bundle"
    run bundle --plan "$plan" --output-dir "$output" --dry-run
    check "$arch dry run is non-publishable and creates no destination" bash -c \
        'test ! -e "$1" && jq -e ".status == \"planned\" and .publishable == false" "$2" >/dev/null' _ "$output" "$WORK/stdout"
    mv "$case_dir/windows" "$case_dir/windows-held" || exit 1
    run bundle --plan "$plan" --output-dir "$output"
    check "$arch missing shard reports incomplete rather than success" test "$status" -eq 1
    check "$arch incomplete bundle has truthful coverage JSON" jq -e \
        '.status == "incomplete" and .publishable == false and .imported_builds == 1 and .missing_builds == ["windows"]' "$WORK/stdout"
    check "$arch incomplete collection exposes no release" test ! -e "$output/release"
    check "$arch native shard receipt is retained byte for byte" cmp -s "$case_dir/linux/manifest.json" "$output/inputs/linux/build-manifest.json"
    mv "$case_dir/linux" "$case_dir/linux-original-retained" || exit 1
    mv "$case_dir/windows-held" "$case_dir/windows" || exit 1
    run bundle --plan "$plan" --output-dir "$output"
    check "$arch resume assembles both native variants from the retained shard" test "$status" -eq 0
    if [[ "$status" -ne 0 ]]; then cat "$WORK/stderr" >&2; continue; fi
    check "$arch complete response remains explicit about authentication" jq -e \
        '.status == "verified" and .publishable == true and .authenticated == false and (.targets | length) == 2' "$WORK/stdout"
    manifest="$output/release/build-manifest.json"
    check "$arch aggregate counts three tasks, not two platforms or four assets" jq -e \
        '.summary == {total:3,success:3,failed:0} and (.artifacts | length) == 4 and (.build_environments | length) == 3' "$manifest"
    check "$arch original short tag receipts are preserved under the qualified bundle tag" jq -e \
        '.source.git_ref == "refs/tags/v1.2.3" and all(.build_environments[]; .build_influence_env.DSR_RELEASE_GIT_REF == "v1.2.3")' "$manifest"
    check "$arch bundle binds the original component manifest hash" jq -e \
        --arg digest "$(hash "$case_dir/linux-original-retained/manifest.json")" \
        'any(.component_builds[]; .id == "linux" and .manifest_sha256 == $digest)' "$manifest"
    original=$(hash "$manifest")
    receipt=$(hash "$output/release/result.json")
    run bundle --plan "$plan" --output-dir "$output"
    check "$arch complete retry succeeds with original Linux output unavailable" test "$status" -eq 0
    check "$arch complete retry preserves manifest and result bytes" bash -c \
        'test "$(sha256sum < "$1" | cut -d " " -f 1)" = "$2" && test "$(sha256sum < "$3" | cut -d " " -f 1)" = "$4"' \
        _ "$manifest" "$original" "$output/release/result.json" "$receipt"
    proof="$case_dir/bundle.intoto.jsonl"
    run bash "$SLSA" generate-manifest "$manifest" "$output/release/artifacts" --repository example/app --builder dsr/test --output "$proof"
    check "$arch complete bundle can produce release-set provenance" test "$status" -eq 0
    run bash "$SLSA" verify-release "$proof" "$output/release/artifacts" --manifest "$manifest" --repository example/app --builder dsr/test
    check "$arch all bundled variants and aliases verify against the aggregate" test "$status" -eq 0
    # Preserve the successfully published local bundle, then test retained-input
    # drift in a new owned collection. No original producer evidence is edited.
    drift="$case_dir/drift"
    run bundle --plan "$plan" --output-dir "$drift"
    check "$arch an unavailable unimported Linux source cannot be guessed" test "$status" -eq 1
    check "$arch a fresh incomplete collection has no release" test ! -e "$drift/release"
    cp -a "$output/inputs/linux" "$drift/inputs/linux" || exit 1
    cp "$drift/inputs/linux/artifacts/app-$arch-musl" "$case_dir/original-musl-retained" || exit 1
    printf corrupt >> "$drift/inputs/linux/artifacts/app-$arch-musl"
    run bundle --plan "$plan" --output-dir "$drift"
    check "$arch changed retained variant is refused on resume" test "$status" -eq 7
    check "$arch drift does not publish a release or successful JSON" bash -c \
        'test ! -e "$1/release" && test ! -s "$2"' _ "$drift" "$WORK/stdout"
    check "$arch independent completed bundle was not changed" test "$(hash "$manifest")" = "$original"
done

# All negatives start from new input/output directories. Where a fixture
# intentionally changes an input, bind the actual changed bytes in the plan;
# otherwise a simple hash mismatch would conceal coverage validation bugs.
for mutation in missing-environment failed-shard source-mismatch branch-ref missing-contract-asset duplicate-platform; do
    directory="$WORK/reject-$mutation"
    fixture "$directory" amd64 || exit 1
    input="$directory/linux/manifest.json"
    case "$mutation" in
        missing-environment) filter='del(.build_environments[1])' ;;
        failed-shard) filter='.summary.failed=1 | .status="partial"' ;;
        source-mismatch) filter='.source.git_sha="2"*40 | .build_environments |= map(.build_influence_env.DSR_RELEASE_GIT_SHA="2"*40)' ;;
        branch-ref) filter='.build_environments[0].build_influence_env.DSR_RELEASE_GIT_REF="refs/heads/v1.2.3"' ;;
        *) filter='.' ;;
    esac
    jq "$filter" "$input" > "$directory/changed-manifest.json" || exit 1
    jq --arg path "$directory/changed-manifest.json" --arg digest "$(hash "$directory/changed-manifest.json")" \
        '.builds[0].manifest=$path | .builds[0].manifest_sha256=$digest' "$directory/plan.json" > "$directory/changed-plan.json" || exit 1
    case "$mutation" in
        missing-contract-asset)
            jq '.required_assets |= map(select(.name != "app-amd64-musl"))' "$directory/changed-plan.json" > "$directory/final-plan.json" ;;
        duplicate-platform)
            jq '.builds += [.builds[0] + {id:"duplicate"}]' "$directory/changed-plan.json" > "$directory/final-plan.json" ;;
        *) cp "$directory/changed-plan.json" "$directory/final-plan.json" ;;
    esac
    run bundle --plan "$directory/final-plan.json" --output-dir "$directory/bundle"
    check "bundle refuses $mutation" test "$status" -ne 0
    check "$mutation publishes no complete release or path" bash -c \
        'test ! -e "$1/release" && test ! -s "$2"' _ "$directory/bundle" "$WORK/stdout"
done
printf 'Results: %s passed, %s failed\nEvidence: %s\n' "$passed" "$failed" "$WORK"
[[ "$failed" -eq 0 ]]
