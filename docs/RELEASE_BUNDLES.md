# Complete, resumable multi-target release bundles

`src/release_bundle.sh` combines successful manifests from separate build
machines into one complete release. It accepts ordinary DSR build manifests
and the source-pinned Windows ARM64 manifests from `scripts/xwin-build.sh`.
It does not compile, create tags, contact GitHub, sign, or publish a release.

The operator selects the required target matrix and pins each input manifest's
SHA-256. An individual successful build cannot silently redefine the complete
release as its own subset of platforms. The selected manifests must agree on
tool, version, source commit and sibling dependency revisions. Every required
target must appear exactly once across the input manifests unless the plan
explicitly partitions native compiler variants as described below. Aliases
within one manifest remain separate assets. Conflicting release filenames,
including case-only collisions, are rejected.

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

## Independently built native variants

A GNU job and a musl job can now be collected independently even though both
use the canonical `linux/amd64` platform. Opt in by adding a complete
`required_variants` array to the plan and a `variants` array to **every** build
entry. Keep the existing source, manifest hashes, paths and platform fields.
For two Linux AMD64 inputs, the additional selection is:

```json
{
  "required_targets": ["linux/amd64"],
  "required_variants": [
    {"target": "linux/amd64", "target_triple": "x86_64-unknown-linux-gnu"},
    {"target": "linux/amd64", "target_triple": "x86_64-unknown-linux-musl"}
  ]
}
```

The GNU build entry contains:

```json
{
  "id": "linux-gnu",
  "targets": ["linux/amd64"],
  "variants": [
    {"target": "linux/amd64", "target_triple": "x86_64-unknown-linux-gnu"}
  ]
}
```

The musl entry similarly selects `x86_64-unknown-linux-musl`. These are plan
fragments, not complete plans: both entries still require their original
`manifest`, `manifest_sha256` and `artifacts_dir`. ARM64 uses the same shape
with `linux/arm64` and the corresponding `aarch64-unknown-linux-*` triples.
A shard can include several variants or platforms. The complete input variant
arrays must partition `required_variants` exactly, without overlaps or missing
pairs; every platform array must agree with its variants. Empty, malformed,
duplicate and mixed implicit/explicit selections fail before collection.

This mode requires exactly one original compiled build environment per selected
`(target, target_triple)` pair and exact artifact coverage of those pairs.
Native jobs retain `method: native`. A pinned xwin producer retains
`method: pinned-cargo-xwin`, with matching target fields in its environment,
toolchain and toolchain inputs. It must be the sole selected variant on its
Windows platform: `x86_64-pc-windows-msvc` for `windows/amd64`, or
`aarch64-pc-windows-msvc` for `windows/arm64`. Mixing native GNU/musl jobs with
those independently produced Windows outputs does not relabel xwin execution.
A missing environment or a workflow-only receipt cannot be relabeled as native
execution. Declared source and compiler selectors must still pass the existing
SLSA manifest profile. Compiler triples are recorded identities, not an
independent ABI inspection or proof that these builds were executed here.

Optional `required_assets` remains a closed set of `{name, target,
archive_format}` records. Add `target_triple` to an individual record to bind
that public filename to its exact compiler variant, rather than merely to the
platform. For example:

```json
{
  "name": "app-linux-musl.tar.gz",
  "target": "linux/amd64",
  "target_triple": "x86_64-unknown-linux-musl",
  "archive_format": "tar.gz"
}
```

A same-platform shard may own only a subset of the global asset set, but every
imported name must be allowed and the final combined set must match exactly.
Explicitly typed names are required from the shard owning that compiler pair;
a GNU payload cannot satisfy a musl filename even when both variants exist
elsewhere in the release. Missing owned names fail before checkpoint admission.
Typed names also work in ordinary platform-partitioned plans, and untyped
records keep their previous contract. An explicit null, empty, unsafe, or
unknown-to-the-selected-matrix triple is an error, not an untyped fallback.
Removing a binding changes the frozen plan and cannot alter an existing bundle.

An alias belongs to one producer; publishing it from two shards is a collision
even if its bytes match. No filename guessing decides variant ownership, and
aliases never add compiler tasks to the summary. The shared SLSA profile checks
the exact filename/format/platform/compiler correspondence before provenance or
payload publication. The binding is to producer-recorded identity; it is not an
independent compiler invocation or inspection of the executable ABI.

When one variant has not arrived, other complete variant checkpoints are kept,
but no `release/` directory is exposed. Retrying the same pinned plan can finish
after the original producer directories have gone offline. Reordering variant
arrays does not change the plan identity. Changing any selected pair or input
hash requires a new plan/output directory, not a rewrite of retained evidence.

The aggregate retains `required_variants` and each component's exact variant
selection alongside its manifest hash. The shared SLSA/payload-publication
profile enforces the required variant matrix downstream, so a successful
summary alone cannot authorize a subset. Run the collector/provenance/recovery
regressions with `bash scripts/tests/test_release_bundle_variants.sh`.
The same test exercises the unmodified public build-set finalizer entry point,
with only the network/signing engine replaced by an explicit fixture: incomplete
variant collection cannot reach that boundary, and completed typed selections
retain their manifest identity and explicit signing/provenance options on retry.
This is handoff coverage, not live publication or cryptographic qualification.

## Execute the variant jobs before collection

The same compiler matrix is supported by the execution coordinator in
`src/release_builds.sh`, not just by the collector of already completed inputs.
An execution plan uses the same release identity, `required_targets`, optional
typed `required_assets`, and complete `required_variants`. Each job declares its
exact `variants` alongside the existing driver-specific inputs documented in
`RELEASE_BUILDS.md`.

For example, a native GNU job has this shape:

```json
{
  "id": "linux-gnu",
  "driver": "dsr",
  "targets": ["linux/amd64"],
  "variants": [
    {"target": "linux/amd64", "target_triple": "x86_64-unknown-linux-gnu"}
  ],
  "config_dir": "/srv/release-config/gnu",
  "config_files": {
    "config.yaml": "<reviewed SHA-256 of config.yaml>",
    "repos.yaml": "<reviewed SHA-256 of repos.yaml>",
    "hosts.yaml": "<reviewed SHA-256 of hosts.yaml>",
    "repos.d/app.yaml": "<reviewed SHA-256 of repos.d/app.yaml>"
  },
  "jobs": 1,
  "timeout": 3600
}
```

This is a job fragment with deliberately invalid placeholder hashes, not an
executable plan. A separate musl job selects the musl triple and a separately
pinned configuration directory. **The native configuration must actually build
the selected variants.** The coordinator does not rewrite recipes, inject an
extra target selector, change compiler routing, or bypass build admission.
It invokes the ordinary DSR command with the job's immutable configuration and
checks the resulting manifest against the planned variants. Native resume
retains the existing source/configuration/run checks and terminal-state rules.

Existing `driver: import` jobs may declare variants with their pinned manifests.
`driver: xwin` jobs may join the matrix only with their exact sole MSVC variant
on the selected Windows platform. The full original xwin binary inventory and
toolchain/feature checks remain in force. A plan cannot substitute a Windows
compiler target merely by changing its routing platform or public filename.

Run the coordinator, or drive it through packaging and finalization:

```bash
bash src/release_builds.sh --plan /srv/execution-plan.json \
  --output-dir /srv/executed-release --jobs 3 --dry-run

bash src/release_finalize.sh --build-plan /srv/execution-plan.json \
  --build-dir /srv/executed-release --build-jobs 3 \
  --packaging-recipe /srv/packaging.json --create-draft \
  --require-signatures --public-key /srv/keys/release.pub \
  --secret-key /srv/keys/release.key
```

Signing and promotion remain explicit. Packaging recipes must select a
`target_triple` for every output in a variant matrix; every member must belong
to that compiler identity. The finalizer rejects a changed global matrix,
per-job variant selection, or public-asset binding at the coordinator handoff.
The completed build set carries the original selections rather than collapsing
them back to platform counts.

Failures remain resumable without discarding useful work. A missing import or
failed job leaves independently completed variants in immutable checkpoints;
retrying the same plan revalidates those checkpoints instead of rerunning their
builders. Failed attempt files remain separate. Recovery distinguishes two
important cases:

* A zero-exit driver whose manifest violates the selected source, purpose,
  compiler matrix or asset contract fails **before** acquiring a durable import
  candidate. A normal retry can start another attempt, subject to the native
  driver's existing resume/terminal-state policy.
* A valid selected manifest whose payload could not be imported stays pinned.
  Retry reattempts that exact import and never rebuilds to hide unavailable or
  damaged bytes. Restoring the original selected payload permits completion;
  changing the manifest or invocation does not.

The additional manifest preflight uses the collector's actual admission parser,
not a second predicate. Previously retained candidates are not silently
 discarded or reinterpreted. Run
`bash scripts/tests/test_release_build_plan_variants.sh` for coordinator,
recovery, archive packaging and public-finalizer handoff coverage. It exercises
real scheduling, hashes and archive operations with explicit compiler-driver
and remote-engine fixtures; it does not qualify native execution or signing.

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
merge same-platform shards without an explicit native variant partition,
additional-target metadata assets, or incompatible sibling dependency graphs. Partial compiler execution
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
