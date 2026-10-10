#!/usr/bin/env bash
# Exercise the real standalone SLSA commands with actual files and hashes.
# Manifests are recorded-producer-shape fixtures, NOT compiler execution proof.
# SLSA_TEST_MODULE permits replaying this unchanged test against an incumbent.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MODULE="${SLSA_TEST_MODULE:-$ROOT/src/slsa.sh}"
for dependency in jq sha256sum; do
    command -v "$dependency" >/dev/null || { printf 'Missing dependency: %s\n' "$dependency" >&2; exit 3; }
done
WORK=$(mktemp -d "${TMPDIR:-/tmp}/dsr-slsa-variants.XXXXXXXX") || exit 1
printf 'Retained test evidence: %s\n' "$WORK"
mkdir -p "$WORK/assets" "$WORK/proofs" "$WORK/manifests" || exit 1
PIN=1111111111111111111111111111111111111111
passed=0 failed=0 status=0
check() {
    local label="$1"; shift
    if "$@"; then passed=$((passed + 1)); printf 'PASS: %s\n' "$label"
    else failed=$((failed + 1)); printf 'FAIL: %s\n' "$label" >&2; fi
}
run() { status=0; "$@" > "$WORK/stdout" 2> "$WORK/stderr" || status=$?; }
hash() { sha256sum < "$1" | cut -d ' ' -f 1; }

for arch in amd64 arm64; do
    cpu=x86_64
    [[ "$arch" != arm64 ]] || cpu=aarch64
    platform="linux/$arch"
    gnu="$cpu-unknown-linux-gnu"
    musl="$cpu-unknown-linux-musl"
    for abi in gnu musl; do
        printf 'Owned %s %s payload\n' "$arch" "$abi" > "$WORK/assets/app-$arch-$abi"
    done
    cp "$WORK/assets/app-$arch-gnu" "$WORK/assets/app-$arch-alias" || exit 1
    printf 'Owned workflow output\n' > "$WORK/assets/other-windows.exe"
    manifest="$WORK/manifests/$arch.json"
    jq -n --arg platform "$platform" --arg gnu "$gnu" --arg musl "$musl" --arg arch "$arch" \
        --arg pin "$PIN" --arg ghash "$(hash "$WORK/assets/app-$arch-gnu")" \
        --arg mhash "$(hash "$WORK/assets/app-$arch-musl")" --arg whash "$(hash "$WORK/assets/other-windows.exe")" \
        --argjson gsize "$(wc -c < "$WORK/assets/app-$arch-gnu")" \
        --argjson msize "$(wc -c < "$WORK/assets/app-$arch-musl")" \
        --argjson wsize "$(wc -c < "$WORK/assets/other-windows.exe")" '
        def artifact($name;$target;$triple;$hash;$size):
            {name:$name,target:$target,target_triple:$triple,sha256:$hash,size_bytes:$size,archive_format:"binary"};
        def environment($triple):
            {target:$platform,target_triple:$triple,method:"native",host:"native-worker",
             build_influence_env:{CARGO_BUILD_TARGET:$triple,DSR_TARGET_TRIPLE:$triple,
                 DSR_RELEASE_GIT_SHA:$pin,DSR_RELEASE_GIT_REF:"v1.2.3",PRIVATE_SETTING:"must-not-leak"},
             cargo_isolation:{mode:"strict-release-snapshot",toolchain:{target_triple:$triple}}};
        {schema_version:"1.0.0",tool:"app",version:"v1.2.3",run_id:"550e8400-e29b-41d4-a716-446655440000",
         source:{git_sha:$pin,git_ref:"v1.2.3",dependencies:[]},status:"success",
         build_purpose:"release",publishable:true,built_at:"2026-10-09T01:02:03Z",
         requested_targets:[$platform,"windows/amd64"],summary:{total:3,success:3,failed:0},
         build_environments:[environment($gnu),environment($musl),
             {target:"windows/amd64",method:"act",host:"workflow-worker"}],
         artifacts:[artifact("app-"+$arch+"-gnu";$platform;$gnu;$ghash;$gsize),
                    artifact("app-"+$arch+"-alias";$platform;$gnu;$ghash;$gsize),
                    artifact("app-"+$arch+"-musl";$platform;$musl;$mhash;$msize),
                    artifact("other-windows.exe";"windows/amd64";"x86_64-pc-windows-msvc";$whash;$wsize)]}
    ' > "$manifest" || exit 1
    proof="$WORK/proofs/$arch.intoto.jsonl"
    run bash "$MODULE" generate-manifest "$manifest" "$WORK/assets" --repository example/app --builder dsr/test --output "$proof"
    check "$arch complete native ABI matrix plus workflow produces provenance" test "$status" -eq 0
    if [[ "$status" -eq 0 ]]; then
        check "$arch stdout contains only the published proof path" test "$(cat "$WORK/stdout")" = "$proof"
        check "$arch aliases remain subjects but do not become build tasks" jq -e \
            '.subject | length == 4' "$proof"
        check "$arch public task identities distinguish both ABIs" jq -e --arg platform "$platform" --arg gnu "$gnu" --arg musl "$musl" '
            .dsr_evidence.build_tasks == [{target:$platform,target_triple:$gnu},
                {target:$platform,target_triple:$musl},{target:"windows/amd64"}] and
            .predicate.buildDefinition.externalParameters.targets == [$platform,"windows/amd64"]' "$proof"
        check "$arch each subject retains its own compiler variant" jq -e --arg gnu "$gnu" --arg musl "$musl" --arg arch "$arch" '
            [.dsr_evidence.artifacts[] | select(.name == ("app-"+$arch+"-alias")) | .target_triple] == [$gnu] and
            [.dsr_evidence.artifacts[] | select(.name == ("app-"+$arch+"-musl")) | .target_triple] == [$musl]' "$proof"
        check "$arch manifest digest binds every original environment receipt" jq -e --arg digest "$(hash "$manifest")" \
            '.dsr_evidence.manifest_sha256 == $digest and .dsr_evidence.build_environment_count == 3' "$proof"
        check "$arch private environment is not exposed" bash -c '! grep -q must-not-leak "$1"' _ "$proof"
        original=$(hash "$proof")
        run bash "$MODULE" verify-release "$proof" "$WORK/assets" --manifest "$manifest" --repository example/app --builder dsr/test
        check "$arch every subject verifies against the exact source manifest" test "$status" -eq 0
        check "$arch verification does not pollute stdout" test ! -s "$WORK/stdout"
        run bash "$MODULE" generate-manifest "$manifest" "$WORK/assets" --repository example/app --builder dsr/test --output "$proof"
        check "$arch retry preserves the existing proof" test "$status" -eq 0
        check "$arch retry is byte identical" test "$(hash "$proof")" = "$original"
        jq '.build_environments[0].cargo_isolation.toolchain.compiler_sha256="changed"' "$manifest" > "$WORK/manifests/stale-$arch.json"
        run bash "$MODULE" verify-release "$proof" "$WORK/assets" --manifest "$WORK/manifests/stale-$arch.json" --repository example/app --builder dsr/test
        check "$arch changed compiler receipt cannot replay an existing proof" test "$status" -ne 0
        printf corrupt >> "$WORK/assets/app-$arch-musl"
        run bash "$MODULE" verify-release "$proof" "$WORK/assets"
        check "$arch corruption of the second ABI is refused" test "$status" -ne 0
        printf 'Owned %s musl payload\n' "$arch" > "$WORK/assets/app-$arch-musl"
    else
        cat "$WORK/stderr" >&2
    fi

    for mutation in missing-environment duplicate-environment extra-environment missing-triple \
        wrong-triple wrong-toolchain wrong-cargo-target wrong-source wrong-ref missing-artifact \
        mixed-method partial wrong-total wrong-success alias-count unrequested diagnostic \
        environment-null malformed-triple foreign-artifact duplicate-host missing-host-triple; do
        case "$mutation" in
            missing-environment) filter='del(.build_environments[1])' ;;
            duplicate-environment) filter='.build_environments[1]=.build_environments[0]' ;;
            extra-environment) filter='.build_environments += [{target:$platform,target_triple:"unconfigured",method:"native"}]' ;;
            missing-triple) filter='del(.artifacts[2].target_triple)' ;;
            wrong-triple) filter='.artifacts[2].target_triple="unconfigured"' ;;
            wrong-toolchain) filter='.build_environments[1].cargo_isolation.toolchain.target_triple=$gnu' ;;
            wrong-cargo-target) filter='.build_environments[1].build_influence_env.CARGO_BUILD_TARGET=$gnu' ;;
            wrong-source) filter='.build_environments[0].build_influence_env.DSR_RELEASE_GIT_SHA="2"*40' ;;
            wrong-ref) filter='.build_environments[0].build_influence_env.DSR_RELEASE_GIT_REF="v9.9.9"' ;;
            missing-artifact) filter='del(.artifacts[2])' ;;
            mixed-method) filter='.build_environments[1].method="act"' ;;
            partial) filter='.status="partial" | .summary.failed=1' ;;
            wrong-total) filter='.summary.total=2 | .summary.success=2' ;;
            wrong-success) filter='.summary.success=2' ;;
            alias-count) filter='.summary.total=4 | .summary.success=4' ;;
            unrequested) filter='.requested_targets=["windows/amd64"]' ;;
            diagnostic) filter='.build_purpose="diagnostic-native"' ;;
            environment-null) filter='.build_environments=null' ;;
            malformed-triple) filter='.artifacts[2].target_triple="../escape"' ;;
            foreign-artifact) filter='.artifacts[2].target="darwin/arm64"' ;;
            duplicate-host) filter='.hosts=[{platform:$platform,target_triple:$gnu,status:"success"},
                {platform:$platform,target_triple:$gnu,status:"success"},{platform:"windows/amd64",status:"success"}]' ;;
            missing-host-triple) filter='.hosts=[{platform:$platform,status:"success"},
                {platform:$platform,status:"success"},{platform:"windows/amd64",status:"success"}]' ;;
        esac
        candidate="$WORK/manifests/$arch-$mutation.json"
        jq --arg platform "$platform" --arg gnu "$gnu" "$filter" "$manifest" > "$candidate" || exit 1
        rejected="$WORK/proofs/$arch-$mutation.intoto.jsonl"
        run bash "$MODULE" generate-manifest "$candidate" "$WORK/assets" --repository example/app --output "$rejected"
        check "$arch refuses $mutation" test "$status" -eq 4
        check "$arch $mutation publishes no proof or path" bash -c 'test ! -e "$1" && test ! -s "$2"' _ "$rejected" "$WORK/stdout"
    done

    # Host rows are optional in the ordinary producer. When present, every
    # repeated platform must identify exactly one of the same compiler tasks.
    jq --arg p "$platform" --arg g "$gnu" --arg m "$musl" '.hosts=[
        {platform:$p,target_triple:$m,status:"success"},{platform:"windows/amd64",status:"success"},
        {platform:$p,target_triple:$g,status:"success"}]' "$manifest" > "$WORK/manifests/hosts-$arch.json"
    run bash "$MODULE" generate-manifest "$WORK/manifests/hosts-$arch.json" "$WORK/assets" --repository example/app --output "$WORK/proofs/hosts-$arch"
    check "$arch exact variant host results are accepted in any order" test "$status" -eq 0

    # The incumbent supports legacy singleton platforms with only a partial
    # environment inventory. Preserve that path and its statement bytes.
    jq 'del(.artifacts[2]) | .summary={total:2,success:2,failed:0} |
        .build_environments=[.build_environments[2]] | .artifacts |= map(del(.target_triple)) |
        .hosts=[{platform:.requested_targets[0],status:"success"},{platform:"windows/amd64",status:"success"}]' \
        "$manifest" > "$WORK/manifests/legacy-$arch.json"
    run bash "$MODULE" generate-manifest "$WORK/manifests/legacy-$arch.json" "$WORK/assets" --repository example/app --output "$WORK/proofs/legacy-$arch"
    check "$arch legacy singleton and partial environment remain supported" test "$status" -eq 0

    # Workflow-produced ABI families must not be relabeled as native builds.
    jq --arg p "$platform" '.summary={total:2,success:2,failed:0} |
        .build_environments=[{target:$p,method:"act"},.build_environments[2]]' \
        "$manifest" > "$WORK/manifests/workflow-$arch.json"
    run bash "$MODULE" generate-manifest "$WORK/manifests/workflow-$arch.json" "$WORK/assets" --repository example/app --output "$WORK/proofs/workflow-$arch"
    check "$arch one workflow producing both ABIs remains one task" test "$status" -eq 0
    if [[ "$status" -eq 0 ]]; then
        check "$arch workflow provenance invents no native task receipt" jq -e '.dsr_evidence | has("build_tasks") | not' "$WORK/proofs/workflow-$arch"
    fi
done
printf 'Results: %s passed, %s failed\nEvidence: %s\n' "$passed" "$failed" "$WORK"
[[ "$failed" -eq 0 ]]
