# Complete, resumable multi-target release bundles

`src/release_bundle.sh` combines successful manifests from separate build
machines into one complete release. It accepts ordinary DSR build manifests
and the source-pinned Windows ARM64 manifests from `scripts/xwin-build.sh`.
It does not compile, create tags, contact GitHub, sign, or publish a release.

The operator selects the required target matrix and pins each input manifest's
SHA-256. An individual successful build cannot silently redefine the complete
release as its own subset of platforms. The selected manifests must agree on
tool, version, source commit and sibling dependency revisions. Every required
target must appear exactly once across the input manifests; aliases within one
manifest remain separate assets. Conflicting release filenames are rejected.

## Build-set plan

Create one JSON document with absolute local input paths. Each `targets` array
describes the exact targets in that input manifest; a native build manifest
may cover more than one target. The arrays must partition `required_targets`.

```json
{
  "schema_version": 1,
  "repo": "owner/tool",
  "tool": "tool",
  "tag": "v1.2.3",
  "source_sha": "<reviewed full 40-character source commit>",
  "required_targets": ["linux/amd64", "darwin/arm64", "windows/arm64"],
  "builds": [
    {
      "id": "native",
      "targets": ["linux/amd64", "darwin/arm64"],
      "manifest": "/srv/builds/native/build-manifest.json",
      "manifest_sha256": "<actual 64-character SHA-256 of that manifest>",
      "artifacts_dir": "/srv/builds/native/artifacts"
    },
    {
      "id": "windows",
      "targets": ["windows/arm64"],
      "manifest": "/srv/builds/windows/release/build-manifest.json",
      "manifest_sha256": "<actual 64-character SHA-256 of that manifest>",
      "artifacts_dir": "/srv/builds/windows/artifacts"
    }
  ]
}
```

Placeholders are deliberately invalid. Select manifest hashes from the build
outputs you intend to release, not by accepting whatever file happens to occupy
an input path during a retry. Hashes must be known before the first collection;
an unavailable input can represent a build whose manifest identity is already
known but whose files have not yet been transferred locally. A genuinely new
or rebuilt manifest requires a new plan and output directory.

## Collect and retry

```bash
bash src/release_bundle.sh --plan /srv/build-set.json \
  --output-dir /srv/release-bundle --dry-run

bash src/release_bundle.sh --plan /srv/build-set.json \
  --output-dir /srv/release-bundle > /srv/collection-result.json
```

The output directory's parent must already exist. The collector will create the
directory, or resume its own matching state, but will not adopt an unrelated
directory. Symlinks in selected input/output paths are rejected. Bash 4+, jq,
Python 3, flock, SHA-256 tooling and the usual filesystem utilities are required.

Missing manifests or payload files return exit `1` and an `incomplete` receipt
with `publishable: false`, imported-build count and missing input IDs. Other
valid shards are retained in `inputs/<id>/` through atomic directory renames.
No `release/` directory exists until the complete matrix is admitted. Malformed
manifests or changed bytes are errors, not evidence that a build is pending.

Repeat the same command after transferring the missing files. Completed
checkpoints are verified independently against their pinned manifests and named
payload hashes/sizes. Their original build directories need not remain online.
Changes to the selected plan are refused; ordering input/target arrays differently
does not change its canonical identity. Only one collector can hold the output
directory's lock at a time.

Each payload is copied rather than hardlinked to a build-host file. Executable
permissions are retained without setuid/setgid bits. Only explicitly named
manifest artifacts are imported; arbitrary paths embedded in the manifest are
never followed. Extra files in original build directories are not imported.
The collector rechecks the exact namespace in its retained and exported payload
directories, rejecting new files, directories, symlinks and missing payloads.

## Complete output and publication

The complete release is exposed through one directory rename:

```text
release-bundle/
  state.json                       # Frozen plan and stable run UUID
  inputs/<id>/build-manifest.json   # Byte-identical selected producer evidence
  inputs/<id>/artifacts/            # Verified checkpoints
  release/build-manifest.json       # Aggregate successful DSR manifest
  release/artifacts/                # Exact combined release payload namespace
  release/result.json              # Same receipt emitted on stdout
```

The aggregate preserves all recorded build environments, including the pinned
Windows ARM64 toolchain/source evidence, without passing large inventories in
process arguments. `component_builds` links each original run and target subset
to its manifest hash; the complete original manifests remain in `inputs/`, so
producer-specific extension fields are not lost. Its completion timestamp is
the latest recorded component-build completion, not a fabricated build time.

On retry, the aggregate is reconstructed from verified checkpoints and compared
with the existing manifest and receipt. Payloads are rehashed. A completed
release is never silently repaired, overwritten or assigned a new identity.

The aggregate is admitted by the existing successful-build profile used by the
payload publisher and SLSA mapper. It can be handed to the existing finalizer:

```bash
bash src/release_finalize.sh /srv/release-bundle/release/artifacts \
  --repo owner/tool --tag v1.2.3 --sha "$SOURCE_SHA" \
  --create-draft --upload-payloads \
  --build-manifest /srv/release-bundle/release/build-manifest.json \
  --output-dir /srv/release-metadata
```

This leaves a draft; signing and promotion remain explicit finalizer policies.
Keep generated SBOM/signature metadata outside the immutable bundle payload
directory. See `RELEASE_FINALIZATION.md` for publication and recovery options.

## One-command finalization

The existing finalizer entry point also accepts a build set directly:

```bash
bash src/release_finalize.sh --build-set /srv/build-set.json \
  --bundle-dir /srv/release-bundle --create-draft \
  --require-signatures --public-key /srv/keys/release.pub \
  --secret-key /srv/keys/release.key
```

Collection must reach a verified complete matrix before the finalizer engine
is called. Missing inputs return a single finalization JSON envelope with
`status: waiting_for_builds` and exit `1`; ready checkpoints remain available.
Repeating the same invocation resumes ingestion and then enters the existing
manifest-bound payload upload, signing, SBOM and remote verification stages.
An engine failure retains its exit code and diagnostic together with the bundle
receipt; the same invocation reuses the stable aggregate on publication retry.

The plan owns `--repo`, `--tag`, `--sha`, `--tool`, `--build-manifest` and
`--upload-payloads`; do not supply those flags in build-set mode. Other supported
finalizer policies remain explicit. `--create-draft` is not implied, and neither
signing mode implies `--promote`. Add `--promote` only when publication of the
verified draft is intended. Prepared-signature mode and downstream dispatch
options pass through to the same existing engine and its checks.

Metadata defaults to `bundle-dir/metadata` and finalization state to
`bundle-dir/finalization`, outside the immutable `release/` and `inputs/`
directories. Explicit output/state/integrity paths must be absolute and must
stay outside those protected directories. This prevents a generated SBOM or
state file from changing the admitted payload namespace and breaking retries.

`--dry-run` validates the build-set plan and the option structure without
collecting payloads or invoking the finalizer. It reports `policy_verified:
false`: it has not authenticated a key, examined prepared signatures, contacted
GitHub, or verified remote publication policy. The live engine still performs
its full preflight before any release mutation.

The original artifacts-first CLI and sourced `release_finalize` API are
unchanged. A sourced caller uses `release_finalize_build_set --build-set FILE
--bundle-dir DIR ...` for the new flow. The existing engine is retained without
byte changes in `src/release_finalize_core.sh`; its source/signature/promotion
and persistent dispatch gates have not been replaced by a second implementation.

Run the handoff regression suite with:

```bash
bash scripts/tests/test_release_bundle_finalize.sh
```

This suite uses real bundle collection and manifest/payload validation, with a
finalizer function-boundary stand-in instead of live GitHub publication. It
checks that incomplete or corrupted sets cannot reach that boundary, that
publication retries preserve identity, and that policy arguments remain exact.

## Boundaries

This collects producer evidence; it does not authenticate it, recompile the
inputs, prove that a binary matches its claimed platform, or replace remote tag
verification. Its repository/source assertions and manifest pins are operator
selections. Unsigned local evidence is not signed provenance. Existing strict
build admission and finalizer signature policies are not weakened or bypassed.

Build shards must already pass DSR's complete successful-manifest profile.
Explicit debug/nonpublishable results are not accepted. The collector does not
merge multiple variants of the same `os/arch` target, additional-target metadata
assets, or incompatible sibling dependency graphs. Partial compiler execution
and native-host scheduling/resume remain responsibilities of the build runner.

Storage is trusted, private local filesystem state. Atomic renames and flock
coordinate cooperating collectors; they are not an adversarial filesystem
sandbox or a power-loss durability guarantee. Temporary staging needs space for
input copies and the final bundle. Interrupted staging directories are never
treated as verified checkpoints.

Run the offline regression suite with:

```bash
bash scripts/tests/test_release_bundle.sh
```
