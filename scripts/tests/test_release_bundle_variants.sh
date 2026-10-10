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

# Separate native jobs can share a scheduling platform only under an explicit
# compiler-variant partition. These are manifest/file fixtures, not builds.
split_fixture() {
    fixture "$1" "$2" || return 1
    python3 - "$1" <<'PY'
import hashlib
import json
import pathlib
import shutil
import sys

root = pathlib.Path(sys.argv[1])
plan = json.loads((root / "plan.json").read_text())
original = json.loads((root / "linux/manifest.json").read_text())
entries = []
for abi in ("gnu", "musl"):
    value = json.loads(json.dumps(original))
    value["artifacts"] = [a for a in value["artifacts"] if a["target_triple"].endswith("-" + abi)]
    value["build_environments"] = [e for e in value["build_environments"] if e["target_triple"].endswith("-" + abi)]
    value["summary"] = dict(total=1, success=1, failed=0)
    value["run_id"] = ("3" if abi == "gnu" else "4") * 8 + "-1111-4111-8111-111111111111"
    dest = root / ("linux-" + abi)
    dest.mkdir()
    for artifact in value["artifacts"]:
        shutil.copy2(root / "linux" / artifact["name"], dest / artifact["name"])
    path = dest / "manifest.json"
    path.write_text(json.dumps(value, sort_keys=True) + "\n")
    entries.append(dict(id=dest.name, manifest=str(path), artifacts_dir=str(dest),
        manifest_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
        targets=value["requested_targets"], variants=[{k: value["artifacts"][0][k] for k in ("target", "target_triple")}]))
windows = plan["builds"][1]
windows["variants"] = [dict(target="windows/amd64", target_triple="x86_64-pc-windows-msvc")]
plan["builds"] = [*entries, windows]
plan["required_variants"] = [v for entry in plan["builds"] for v in entry["variants"]]
(root / "split-plan.json").write_text(json.dumps(plan, sort_keys=True) + "\n")
PY
}

for arch in amd64 arm64; do
    directory="$WORK/split-$arch"
    split_fixture "$directory" "$arch" || exit 1
    plan="$directory/split-plan.json"
    output="$directory/bundle"
    run bundle --plan "$plan" --output-dir "$output" --dry-run
    check "$arch explicit split-variant plan is admitted without publication" bash -c \
        'test "$1" = 0 && test ! -e "$2" && jq -e ".plan.required_variants | length == 3" "$3" >/dev/null' \
        _ "$status" "$output" "$WORK/stdout"
    mv "$directory/linux-musl" "$directory/linux-musl-held" || exit 1
    run bundle --plan "$plan" --output-dir "$output"
    check "$arch missing musl shard retains GNU but cannot publish a partial platform" test "$status" -eq 1
    check "$arch waiting set identifies the missing independent job" jq -e \
        '.missing_builds == ["linux-musl"] and .imported_builds == 2 and .publishable == false' "$WORK/stdout"
    check "$arch GNU receipt is byte-identical in its independent checkpoint" cmp -s \
        "$directory/linux-gnu/manifest.json" "$output/inputs/linux-gnu/build-manifest.json"
    check "$arch incomplete split matrix exposes no release" test ! -e "$output/release"
    mv "$directory/linux-gnu" "$directory/linux-gnu-original-retained" || exit 1
    mv "$directory/windows" "$directory/windows-original-retained" || exit 1
    mv "$directory/linux-musl-held" "$directory/linux-musl" || exit 1
    run bundle --plan "$plan" --output-dir "$output"
    check "$arch independent musl arrival completes the retained GNU/Windows set" test "$status" -eq 0
    if [[ "$status" -ne 0 ]]; then cat "$WORK/stderr" >&2; continue; fi
    manifest="$output/release/build-manifest.json"
    check "$arch independent jobs preserve three tasks and four assets including the owned alias" jq -e \
        '.summary == {total:3,success:3,failed:0} and (.artifacts | length) == 4 and
         (.required_variants | length) == 3 and (.component_builds | length) == 3 and
         all(.component_builds[]; (.variants | length) == 1)' "$manifest"
    check "$arch each component retains its exact planned variant and producer hash" jq -e --slurpfile plan "$plan" \
        'all(.component_builds[]; . as $c | any($plan[0].builds[];
            .id == $c.id and .manifest_sha256 == $c.manifest_sha256 and .variants == $c.variants))' "$manifest"
    original=$(hash "$manifest")
    receipt=$(hash "$output/release/result.json")
    jq '.builds |= reverse | .required_targets |= reverse | .required_variants |= reverse |
        .builds |= map(.targets |= reverse | .variants |= reverse) | .required_assets |= reverse' \
        "$plan" > "$directory/reordered-plan.json" || exit 1
    run bundle --plan "$directory/reordered-plan.json" --output-dir "$output"
    check "$arch reordering the explicit matrix reuses the same completed bundle" test "$status" -eq 0
    check "$arch reordered retry preserves exact result and manifest bytes" bash -c \
        'test "$(sha256sum < "$1" | cut -d " " -f 1)" = "$2" && test "$(sha256sum < "$3" | cut -d " " -f 1)" = "$4"' \
        _ "$manifest" "$original" "$output/release/result.json" "$receipt"
    proof="$directory/variants.intoto.jsonl"
    run bash "$SLSA" generate-manifest "$manifest" "$output/release/artifacts" \
        --repository example/app --builder dsr/test --output "$proof"
    check "$arch separately compiled variant records reach public provenance generation" test "$status" -eq 0
    run bash "$SLSA" verify-release "$proof" "$output/release/artifacts" --manifest "$manifest" \
        --repository example/app --builder dsr/test
    check "$arch complete provenance verifies every exact independently collected payload" test "$status" -eq 0
    for mutation in required-subset required-extra required-duplicate required-null required-mistyped required-unsafe; do
        case "$mutation" in
            required-subset) filter='.required_variants |= .[0:1]' ;;
            required-extra) filter='.required_variants += [{target:"darwin/arm64",target_triple:"aarch64-apple-darwin"}]' ;;
            required-duplicate) filter='.required_variants += [.required_variants[0]]' ;;
            required-null) filter='.required_variants=null' ;;
            required-mistyped) filter='.required_variants[0].target_triple=12' ;;
            required-unsafe) filter='.required_variants[0].target_triple="../gnu"' ;;
        esac
        jq "$filter" "$manifest" > "$directory/$mutation.json" || exit 1
        run bash "$SLSA" generate-manifest "$directory/$mutation.json" "$output/release/artifacts" \
            --repository example/app --output "$directory/$mutation-proof"
        check "$arch downstream provenance rejects $mutation despite successful task counts" test "$status" -eq 4
        check "$arch $mutation cannot produce a public proof" test ! -e "$directory/$mutation-proof"
    done
done

# Invalid matrices are rejected in dry-run before any manifest acquisition or
# output mutation. No live inventory is inferred from a filename or a count.
split_fixture "$WORK/split-invalid" amd64 || exit 1
for mutation in no-opt-in null-matrix empty-matrix duplicate-variant missing-variant extra-variant \
    wrong-platform no-shard-variants null-shard-variants empty-shard-variants duplicate-shard-variant \
    missing-shard-variant unsafe-triple non-string-triple extra-variant-field; do
    case "$mutation" in
        no-opt-in) filter='del(.required_variants)' ;;
        null-matrix) filter='.required_variants=null' ;;
        empty-matrix) filter='.required_variants=[]' ;;
        duplicate-variant) filter='.required_variants += [.required_variants[0]]' ;;
        missing-variant) filter='del(.required_variants[0])' ;;
        extra-variant) filter='.required_variants += [{target:"linux/amd64",target_triple:"x86_64-unknown-linux-other"}]' ;;
        wrong-platform) filter='.builds[0].targets=["darwin/arm64"]' ;;
        no-shard-variants) filter='del(.builds[0].variants)' ;;
        null-shard-variants) filter='.builds[0].variants=null' ;;
        empty-shard-variants) filter='.builds[0].variants=[]' ;;
        duplicate-shard-variant) filter='.builds[0].variants += [.builds[0].variants[0]]' ;;
        missing-shard-variant) filter='.builds |= .[1:]' ;;
        unsafe-triple) filter='.required_variants[0].target_triple="x86_64\n-gnu"' ;;
        non-string-triple) filter='.required_variants[0].target_triple=false' ;;
        extra-variant-field) filter='.required_variants[0].host="guessed"' ;;
    esac
    jq "$filter" "$WORK/split-invalid/split-plan.json" > "$WORK/split-invalid/$mutation.json" || exit 1
    run bundle --plan "$WORK/split-invalid/$mutation.json" --output-dir "$WORK/split-invalid/$mutation" --dry-run
    check "split plan refuses $mutation" test "$status" -eq 4
    check "invalid $mutation creates no output and emits no success receipt" bash -c \
        'test ! -e "$1" && test ! -s "$2"' _ "$WORK/split-invalid/$mutation" "$WORK/stdout"
done

# Re-pin intentionally changed native receipts, so tests exercise semantic
# admission rather than stopping at a simple selected-manifest hash mismatch.
for mutation in wrong-compiler no-native-receipt wrong-method foreign-payload missing-global-asset case-collision; do
    directory="$WORK/split-reject-$mutation"
    split_fixture "$directory" amd64 || exit 1
    case "$mutation" in
        wrong-compiler) filter='.artifacts |= map(.target_triple="aarch64-unknown-linux-gnu") |
            .build_environments |= map(.target_triple="aarch64-unknown-linux-gnu" |
                .build_influence_env.CARGO_BUILD_TARGET=.target_triple |
                .build_influence_env.DSR_TARGET_TRIPLE=.target_triple |
                .cargo_isolation.toolchain.target_triple=.target_triple)' ;;
        no-native-receipt) filter='del(.build_environments)' ;;
        wrong-method) filter='.build_environments[0].method="act"' ;;
        foreign-payload) filter='.artifacts += [.artifacts[0] + {name:"unplanned"}]' ;;
        *) filter='.' ;;
    esac
    jq "$filter" "$directory/linux-gnu/manifest.json" > "$directory/changed-manifest.json" || exit 1
    jq --arg path "$directory/changed-manifest.json" --arg hash "$(hash "$directory/changed-manifest.json")" \
        '.builds[0].manifest=$path | .builds[0].manifest_sha256=$hash' \
        "$directory/split-plan.json" > "$directory/changed-plan.json" || exit 1
    case "$mutation" in
        missing-global-asset)
            jq '.required_assets += [{name:"unproduced",target:"linux/amd64",archive_format:"binary"}]' \
                "$directory/changed-plan.json" > "$directory/final-plan.json" ;;
        case-collision)
            cp "$directory/linux-musl/app-amd64-musl" "$directory/linux-musl/APP-amd64-gnu" || exit 1
            jq '.artifacts[0].name="APP-amd64-gnu"' "$directory/linux-musl/manifest.json" > "$directory/case-manifest.json" || exit 1
            jq --arg path "$directory/case-manifest.json" --arg hash "$(hash "$directory/case-manifest.json")" \
                'del(.required_assets) | .builds[1].manifest=$path | .builds[1].manifest_sha256=$hash' \
                "$directory/changed-plan.json" > "$directory/final-plan.json" ;;
        *) cp "$directory/changed-plan.json" "$directory/final-plan.json" ;;
    esac
    run bundle --plan "$directory/final-plan.json" --output-dir "$directory/bundle"
    check "split collection refuses $mutation" test "$status" -ne 0
    check "split $mutation exposes no complete release or successful receipt" bash -c \
        'test ! -e "$1/release" && test ! -s "$2"' _ "$directory/bundle" "$WORK/stdout"
done
printf 'Results: %s passed, %s failed\nEvidence: %s\n' "$passed" "$failed" "$WORK"
[[ "$failed" -eq 0 ]]
