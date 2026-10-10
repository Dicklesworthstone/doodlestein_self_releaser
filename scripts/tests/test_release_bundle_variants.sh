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
# A platform/variant set does not bind a public basename to its compiler.
# Add typed required assets without altering producer bytes or receipts. The
# same API also supports typed names within a legacy platform-partitioned plan.
typed_asset_plan() {
    python3 - "$1" "$2" <<'PY'
import json
import pathlib
import sys

plan = json.loads(pathlib.Path(sys.argv[1]).read_text())
actual = {}
for build in plan["builds"]:
    manifest = json.loads(pathlib.Path(build["manifest"]).read_text())
    for artifact in manifest["artifacts"]:
        assert artifact["name"] not in actual
        actual[artifact["name"]] = artifact["target_triple"]
for asset in plan["required_assets"]:
    asset["target_triple"] = actual[asset["name"]]
pathlib.Path(sys.argv[2]).write_text(json.dumps(plan, sort_keys=True) + "\n")
PY
}
for arch in amd64 arm64; do
    for shape in split legacy; do
        directory="$WORK/typed-$shape-$arch"
        if [[ "$shape" == split ]]; then
            split_fixture "$directory" "$arch" || exit 1
            plan="$directory/split-plan.json"
        else
            fixture "$directory" "$arch" || exit 1
            plan="$directory/plan.json"
        fi
        typed_asset_plan "$plan" "$directory/typed-plan.json" || exit 1
        plan="$directory/typed-plan.json"
        output="$directory/bundle"
        run bundle --plan "$plan" --output-dir "$output" --dry-run
        check "$shape $arch admits typed public asset names without guessing a compiler" test "$status" -eq 0
        run bundle --plan "$plan" --output-dir "$output"
        check "$shape $arch collects every correctly bound public asset" test "$status" -eq 0
        if [[ "$status" -ne 0 ]]; then cat "$WORK/stderr" >&2; continue; fi
        manifest="$output/release/build-manifest.json"
        check "$shape $arch retains the exact operator-selected asset/compiler binding" jq -e --slurpfile plan "$plan" \
            '.required_assets == ($plan[0].required_assets|sort_by(.name)) and
             .summary == {total:3,success:3,failed:0} and (.artifacts|length)==4' "$manifest"
        original=$(hash "$manifest")
        run bundle --plan "$plan" --output-dir "$output"
        check "$shape $arch typed-asset retry preserves aggregate identity" bash -c \
            'test "$1" = 0 && test "$(sha256sum < "$2" | cut -d " " -f 1)" = "$3"' _ "$status" "$manifest" "$original"
        proof="$directory/typed.intoto.jsonl"
        run bash "$SLSA" generate-manifest "$manifest" "$output/release/artifacts" \
            --repository example/app --builder dsr/test --output "$proof"
        check "$shape $arch typed asset set reaches the public provenance API" test "$status" -eq 0
        run bash "$SLSA" verify-release "$proof" "$output/release/artifacts" --manifest "$manifest" \
            --repository example/app --builder dsr/test
        check "$shape $arch typed public provenance verifies every payload" test "$status" -eq 0
        # The output bytes, task counts, environment inventory and names stay
        # fixed; only the claimed required ABI for two names is exchanged.
        jq --arg gnu "app-$arch-gnu" --arg musl "app-$arch-musl" '
            (.required_assets[]|select(.name==$gnu)|.target_triple) as $g |
            (.required_assets[]|select(.name==$musl)|.target_triple) as $m |
            .required_assets |= map(if .name==$gnu then .target_triple=$m
                                    elif .name==$musl then .target_triple=$g else . end)' \
            "$manifest" > "$directory/swapped-manifest.json" || exit 1
        run bash "$SLSA" generate-manifest "$directory/swapped-manifest.json" "$output/release/artifacts" \
            --repository example/app --output "$directory/swapped-proof"
        check "$shape $arch swapped filename/ABI binding fails despite complete variant coverage" test "$status" -eq 4
        check "$shape $arch swapped binding publishes no proof" test ! -e "$directory/swapped-proof"
        # Optional means each individual name can retain the old 3-field
        # contract. Omitting one binding never disables another name binding.
        jq --arg alias "app-$arch-alias" '.required_assets |= map(if .name==$alias then del(.target_triple) else . end)' \
            "$plan" > "$directory/mixed-plan.json" || exit 1
        run bundle --plan "$directory/mixed-plan.json" --output-dir "$directory/mixed"
        check "$shape $arch mixed typed and legacy names keep their respective contracts" test "$status" -eq 0
        run bundle --plan "$directory/mixed-plan.json" --output-dir "$output"
        check "$shape $arch dropping a binding cannot change an existing frozen plan" test "$status" -eq 2
        check "$shape $arch rejected policy change preserves the published manifest" test "$(hash "$manifest")" = "$original"
    done
done

# With no compiler binding the exchanged selection is indistinguishable; the
# explicit contract must reject it before admitting even the first checkpoint.
directory="$WORK/typed-admission"
split_fixture "$directory" amd64 || exit 1
typed_asset_plan "$directory/split-plan.json" "$directory/typed-plan.json" || exit 1
for mutation in swapped-name missing-owned-asset wrong-format; do
    case "$mutation" in
        swapped-name) filter='.required_assets |= map(
            if .name=="app-amd64-gnu" then .target_triple="x86_64-unknown-linux-musl"
            elif .name=="app-amd64-musl" then .target_triple="x86_64-unknown-linux-gnu" else . end)' ;;
        missing-owned-asset) filter='.required_assets += [{name:"missing-gnu",target:"linux/amd64",
            target_triple:"x86_64-unknown-linux-gnu",archive_format:"binary"}]' ;;
        wrong-format) filter='.required_assets[0].archive_format="zip"' ;;
    esac
    jq "$filter" "$directory/typed-plan.json" > "$directory/$mutation.json" || exit 1
    run bundle --plan "$directory/$mutation.json" --output-dir "$directory/$mutation"
    check "typed admission refuses $mutation as an evidence mismatch" test "$status" -eq 7
    check "typed $mutation cannot admit a completed GNU checkpoint or publish a release" bash -c \
        'test ! -e "$1/inputs/linux-gnu" && test ! -e "$1/release" && test ! -s "$2"' \
        _ "$directory/$mutation" "$WORK/stdout"
done
for mutation in null empty number control unsafe too-long foreign extra-field; do
    case "$mutation" in
        null) filter='.required_assets[0].target_triple=null' ;;
        empty) filter='.required_assets[0].target_triple=""' ;;
        number) filter='.required_assets[0].target_triple=7' ;;
        control) filter='.required_assets[0].target_triple="gnu\n"' ;;
        unsafe) filter='.required_assets[0].target_triple="../gnu"' ;;
        too-long) filter='.required_assets[0].target_triple="x"*129' ;;
        foreign) filter='.required_assets[0].target_triple="aarch64-unknown-linux-gnu"' ;;
        extra-field) filter='.required_assets[0].compiler="unbound"' ;;
    esac
    jq "$filter" "$directory/typed-plan.json" > "$directory/bad-$mutation.json" || exit 1
    run bundle --plan "$directory/bad-$mutation.json" --output-dir "$directory/bad-$mutation" --dry-run
    check "invalid typed asset $mutation fails preflight" test "$status" -eq 4
    check "invalid typed asset $mutation creates no output or successful preview" bash -c \
        'test ! -e "$1" && test ! -s "$2"' _ "$directory/bad-$mutation" "$WORK/stdout"
done
# Exercise the untouched public CLI router and real collection/verification.
# As in test_release_bundle_finalize.sh, substitute only the network engine
# file in an owned runtime; never call GitHub or pretend to authenticate keys.
FINALIZER="${RELEASE_FINALIZE_TEST_MODULE:-$ROOT/src/release_finalize.sh}"
[[ -f "$FINALIZER" ]] || { printf 'Missing finalizer entry point: %s\n' "$FINALIZER" >&2; exit 3; }
directory="$WORK/typed-finalizer"
split_fixture "$directory" amd64 || exit 1
typed_asset_plan "$directory/split-plan.json" "$directory/typed-plan.json" || exit 1
mkdir "$directory/cli" || exit 1
cp "$FINALIZER" "$directory/cli/release_finalize.sh" || exit 1
cp "$BUNDLE" "$directory/cli/release_bundle.sh" || exit 1
cp "$SLSA" "$directory/cli/slsa.sh" || exit 1
export DSR_FINALIZE_FIXTURE_ROOT="$directory"
cat > "$directory/cli/release_finalize_core.sh" <<'SH'
#!/usr/bin/env bash
# Explicit network-engine boundary fixture, not a production signer/uploader.
_rf_log() { printf '[finalizer-fixture] %s\n' "$*" >&2; }
release_finalize() {
    local root=$1 manifest='' repo='' tag='' sha=''
    local evidence="${DSR_FINALIZE_FIXTURE_ROOT:?}"
    printf 'call\n' >> "$evidence/calls"
    jq -cn --args '$ARGS.positional' -- "$@" > "$evidence/engine-args.json" || return 99
    shift
    while (($#)); do
        case "$1" in
            --build-manifest) manifest=$2; shift 2 ;;
            --repo) repo=$2; shift 2 ;;
            --tag) tag=$2; shift 2 ;;
            --sha) sha=$2; shift 2 ;;
            *) shift ;;
        esac
    done
    [[ "$repo" == example/app && "$tag" == v1.2.3 && "$sha" == "$(printf '1%.0s' {1..40})" ]] || return 99
    _slsa_manifest_statement "$manifest" "$repo" dsr/fixture > "$evidence/handoff-proof.json" || return 99
    _slsa_release_assets "$evidence/handoff-proof.json" "$root" || return 99
    jq -e '.summary=={total:3,success:3,failed:0} and (.required_assets|length)==4 and
        all(.required_assets[]; has("target_triple")) and (.required_variants|length)==3' "$manifest" >/dev/null || return 99
    case "${DSR_FINALIZE_FIXTURE_MODE:-ready}" in
        fail) printf '{"kind":"dsr-release-finalization-result","status":"error","exit_code":7,"fixture":true,"error":"injected engine failure"}\n'; return 7 ;;
        malformed) printf '{}\n'; return 0 ;;
    esac
    printf '{"kind":"dsr-release-finalization-result","status":"ready","exit_code":0,"fixture":true,"authenticated":false}\n'
}
SH
finalize() {
    bash "$directory/cli/release_finalize.sh" --build-set "$directory/typed-plan.json" \
        --bundle-dir "$directory/bundle" "$@"
}
run finalize --dry-run
check 'typed finalizer dry-run emits one explicitly unverified planning envelope' jq -es \
    'length==1 and (.[0]|.status=="planned" and .policy_verified==false and .bundle.publishable==false)' "$WORK/stdout"
check 'typed finalizer dry-run never reaches the engine or creates a bundle' bash -c \
    'test ! -e "$1/calls" && test ! -e "$1/bundle"' _ "$directory"
mv "$directory/linux-musl" "$directory/musl-pending" || exit 1
run finalize --create-draft
check 'public finalizer waits for a missing independent ABI' test "$status" -eq 1
check 'public finalizer exposes the actual missing job without a successful release claim' jq -es \
    'length==1 and (.[0]|.status=="waiting_for_builds" and .bundle.missing_builds==["linux-musl"] and .bundle.publishable==false)' "$WORK/stdout"
check 'incomplete ABI inventory cannot reach the publication engine' test ! -e "$directory/calls"
mv "$directory/linux-gnu" "$directory/gnu-offline" || exit 1
mv "$directory/windows" "$directory/windows-offline" || exit 1
mv "$directory/musl-pending" "$directory/linux-musl" || exit 1
run finalize --create-draft
check 'public finalizer resumes retained variants and reaches the engine with a complete typed set' test "$status" -eq 0
check 'completed handoff has one envelope and distinguishes fixture evidence from authentication' jq -es \
    'length==1 and (.[0]|.status=="ready" and .fixture==true and .authenticated==false and .bundle.status=="verified")' "$WORK/stdout"
check 'engine receives exact plan-owned identity and immutable manifest paths' jq -e --arg root "$directory/bundle" \
    '.[0]==($root+"/release/artifacts") and .[index("--repo")+1]=="example/app" and
     .[index("--tag")+1]=="v1.2.3" and .[index("--build-manifest")+1]==($root+"/release/build-manifest.json") and
     index("--upload-payloads")!=null and index("--promote")==null and index("--require-signatures")==null' "$directory/engine-args.json"
original=$(hash "$directory/bundle/release/build-manifest.json")
export DSR_FINALIZE_FIXTURE_MODE=fail
run finalize --create-draft
check 'engine failure is retained as failure, not a successful collection result' test "$status" -eq 7
check 'engine error preserves completed bundle evidence for retry' jq -e \
    '.status=="error" and .error=="injected engine failure" and .bundle.status=="verified"' "$WORK/stdout"
export DSR_FINALIZE_FIXTURE_MODE=ready
run finalize --create-draft
check 'typed finalization retries without rebuilding or changing the aggregate' bash -c \
    'test "$1" = 0 && test "$(sha256sum < "$2" | cut -d " " -f 1)" = "$3"' \
    _ "$status" "$directory/bundle/release/build-manifest.json" "$original"
printf 'not a real public key; argument-boundary fixture only\n' > "$directory/key.pub"
run finalize --require-signatures --public-key "$directory/key.pub" --require-provenance --provenance-builder dsr/test
check 'explicit signature and provenance policy reaches the unchanged engine boundary' test "$status" -eq 0
check 'typed collection neither strips signing policy nor implies promotion' jq -e --arg key "$directory/key.pub" \
    'index("--require-signatures")!=null and index("--require-provenance")!=null and
     .[index("--public-key")+1]==$key and .[index("--provenance-builder")+1]=="dsr/test" and index("--promote")==null' \
    "$directory/engine-args.json"
export DSR_FINALIZE_FIXTURE_MODE=malformed
run finalize
check 'malformed engine success cannot authorize typed finalization' test "$status" -eq 7
export DSR_FINALIZE_FIXTURE_MODE=ready
calls=$(wc -l < "$directory/calls")
run finalize --output-dir "$directory/bundle/release/artifacts"
check 'typed finalization still protects its immutable payload namespace' test "$status" -eq 4
check 'invalid output policy never reaches the engine' test "$calls" = "$(wc -l < "$directory/calls")"
cp "$directory/bundle/release/artifacts/app-amd64-musl" "$directory/original-musl-retained" || exit 1
printf corrupt >> "$directory/bundle/release/artifacts/app-amd64-musl"
run finalize
check 'corrupt completed musl payload blocks finalization on retry' test "$status" -eq 7
check 'corrupt typed set cannot reach the engine again' test "$calls" = "$(wc -l < "$directory/calls")"
unset DSR_FINALIZE_FIXTURE_ROOT DSR_FINALIZE_FIXTURE_MODE
printf 'Results: %s passed, %s failed\nEvidence: %s\n' "$passed" "$failed" "$WORK"
[[ "$failed" -eq 0 ]]
