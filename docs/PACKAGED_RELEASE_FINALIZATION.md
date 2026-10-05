# Build, package and finalize a release

The build-set and build-plan finalizer can turn a verified producer bundle into
installer-ready archives and aliases before applying its existing publication
policy. Supply the same recipe accepted by [release packaging](RELEASE_PACKAGING.md):

```bash
bash src/release_finalize.sh \
  --build-set /srv/build-set.json --bundle-dir /srv/release-bundle \
  --packaging-recipe /srv/packaging.json \
  --require-signatures --public-key /srv/keys/release.pub \
  --secret-key /srv/keys/release.key \
  --require-provenance --provenance-builder https://example.org/builders/dsr
```

Use the reviewed build-set pins, recipe and key paths. The release must already
exist unless `--create-draft` is explicitly selected. This example leaves the
release a draft: packaging never implies `--promote`, signing, or downstream
delivery. Existing prepared-signature, provenance and promotion rules still
apply. The ordinary artifact-directory finalizer is unchanged.

## Execute a build plan and package its outputs

The same option works with the existing native, Windows ARM64 and import jobs:

```bash
bash src/release_finalize.sh \
  --build-plan /srv/release-plan.json --build-dir /srv/release-run \
  --build-jobs 2 --packaging-recipe /srv/packaging.json \
  --require-signatures --public-key /srv/keys/release.pub \
  --secret-key /srv/keys/release.key \
  --require-provenance --provenance-builder https://example.org/builders/dsr
```

The recipe is normalized and frozen into the invocation's private workspace
before any compiler starts. Its target matrix and declared producer asset
requirements must match the build plan. Windows ARM64 jobs additionally expose
their exact binary selection: a recipe missing a selected companion is rejected
even without a global `required_assets` list. These failures occur before build
state, compiler/toolchain access or release API calls. Live packaging still
verifies the actual completed producer inventory and every payload hash.

The existing build coordinator controls concurrency, timeouts and native resume.
An unsuccessful job yields `stage: "build"` with the coordinator's receipt;
successful independent jobs retain their verified checkpoints. Packaging starts
only after the complete matrix has been admitted and collected. Retrying the
same plan reuses completed jobs and retries incomplete jobs under the existing
resume policy. A packaging or publication failure does not discard compilation.

In build-plan mode, `BUNDLE` below means `BUILD_DIR/bundle`. Final results retain
`builds`, `bundle` and `packaging` as separate stages. Even a packaging-stage
error retains the successful build and collection receipts. Interrupting the
combined invocation cancels its owned build or packaging process; it does not
claim to cancel remote work after a network partition.

## Two contracts, one publication input

The plan's optional `required_assets` describes the **producer** namespace,
including raw companion executables. The packaging recipe describes the final
namespace: renamed binaries, independent archives, and byte-identical aliases.
Do not replace the producer requirements with archive names the compiler does
not emit. The finalizer checks the recipe's target matrix and, when declared,
its input names, target assignments and raw/archive compatibility before
collection or compilation. The packager independently requires every producer asset
and admits its bytes using the shared successful-release profile.

`--dry-run` describes both contracts in one result and creates no persistent
bundle, packages, signatures or release. It is structural planning, not proof
of compiler execution, cryptographic validity or remote policy.

Live execution follows:

```text
pinned producer manifests -> verified bundle -> verified packages
    -> signature/provenance preparation -> payload/evidence publication
    -> remote verification -> explicit promotion -> explicit delivery
```

The bundle remains unchanged under `BUNDLE/release/` and `BUNDLE/inputs/`.
Packaging owns `BUNDLE/packaged/`, with its exact source manifest, copied source
payloads, canonical recipe and completed outputs under `packaged/release/`.
Metadata and finalization state keep their existing defaults, `BUNDLE/metadata`
and `BUNDLE/finalization`; custom output/state/integrity/delivery directories
cannot occupy the immutable packaged namespace.

Only `BUNDLE/packaged/release/artifacts/` and its derived `build-manifest.json`
are supplied to the core finalizer. Payload signatures, SBOM selection,
manifest-backed provenance and downstream receipts therefore cover the new
archive bytes and every alias, not the original raw compiler outputs. The
packaged manifest retains its original manifest hash and the canonical recipe
hash; both are checked at the handoff. Source SHA, tool, version and the complete
target matrix must still match the selected build set.

The result retains `bundle` for the producer aggregation and adds `packaging`
for the verified publication input. Packaging errors return a nonzero exit,
`stage: "packaging"`, and a nonpublishable packaging receipt. They never invoke
the core's release APIs. Missing producer bytes retain the existing
`waiting_for_builds` result before packaging begins.

## Recovery

Repeat the same command after interrupted collection or publication. Completed
producer imports and completed packages are independently reverified; they are
not recompressed, overwritten or silently repaired. Original producer paths
may go offline once their checkpoint imports are complete. Keep the selected
recipe available; equivalent JSON ordering preserves its canonical identity.

Once a packaging directory exists, omitting `--packaging-recipe` is an error,
not permission to publish raw files instead. A different recipe or producer
manifest pin conflicts with the retained packaging identity. Corrupt archives,
aliases or manifests block publication without replacing their bytes. The
existing finalization state additionally pins the selected signing/provenance
policy and supports its existing acknowledgement-recovery behavior.

Before packaging has begun, a failed build retains its build-plan identity but
does not persist the packaging recipe. A new invocation may select a new recipe
at that point, subject to the same preflight. This does not change compiler
inputs. Once packaging starts, its persistent identity prevents changing that
selection. Editing the external recipe during an active invocation cannot
change its already-frozen selection; keep or restore that recipe for retries.

These remain trusted local build-host operations, not a sandbox or a distributed
transaction. Read [finalization](RELEASE_FINALIZATION.md) and
[provenance](PROVENANCE.md) for the remote publication and authentication limits.

Run `bash scripts/tests/test_release_packaging_pipeline.sh` for actual archive,
collector, manifest and finalizer integration checks. Signing, SBOM scanning and
GitHub transport use the provenance suite's explicit file-backed fixtures. The
tests do not claim live GitHub publication, native Minisign, or Rust/Windows
compiler acceptance.

Run `bash scripts/tests/test_release_packaging_build_plan.sh` for the actual
coordinator's import/recovery path and native command dispatch, recipe freezing,
pre-compilation contract checks and interruption. Native compilation is an
explicit command-boundary fixture; the coordinator, collector, archive helpers,
manifest admission and finalizer remain the real implementations.

## Include LICENSE and other files from the exact release commit

An archive can explicitly add source companions without treating them as
compiler outputs. This is the manifest-bound derivative path for producers
that emitted only an executable, including the single-binary case in issue #29.
It does not change native `include_files` collection, automatically read a
`repos.d` recipe, edit a producer receipt, or bypass successful-build admission.
An incomplete producer without an admissible manifest must first finish its
existing build/source-verification gates.

Add `source_files` to an archive entry in the packaging recipe:

```json
{
  "schema_version": 1,
  "artifacts": [
    {
      "name": "demo-linux-amd64.tar.xz",
      "target": "linux/amd64",
      "archive_format": "tar.xz",
      "source": "producer-linux-amd64.tar.xz",
      "source_files": [
        {"source": "LICENSE", "path": "LICENSE"},
        {"source": "docs/README.md", "path": "README.md"},
        {"source": "install.sh", "path": "install.sh"},
        {"source": "minisign.pub", "path": "minisign.pub"}
      ]
    }
  ]
}
```

The example assumes a producer containing that single archive; the real recipe
must still consume **every** producer asset and cover the plan's entire matrix.
`source_files` also works beside `members` when constructing an archive from raw
compiler outputs. Companion sources are separate from the producer `inputs`
in the recipe preview, so adding a LICENSE never satisfies a missing binary or
permits dropping a target. A bundled `minisign.pub` is just a source file; it
never becomes the finalizer's independently selected signing trust key.

Supply the source checkout explicitly to either finalizer mode:

```bash
bash src/release_finalize.sh \
  --build-set /srv/build-set.json --bundle-dir /srv/release-bundle \
  --packaging-recipe /srv/packaging.json \
  --packaging-source-repo /srv/checkouts/demo \
  --require-signatures --public-key /srv/keys/release.pub \
  --secret-key /srv/keys/release.key \
  --require-provenance --provenance-builder https://example.org/builders/dsr
```

`--packaging-source-repo` requires a companion-bearing recipe and cannot overlap
build, bundle, or finalization output. It is consumed by packaging, not forwarded
as release policy. Before build-plan compilation or build-set collection, the
finalizer verifies every selected companion against the plan's repository,
tag and full source commit. A missing file, tag mismatch, or foreign origin
therefore fails before the expensive work. `--dry-run` performs this local
source check too but still makes no compiler, signature, or remote-policy claim.

The direct packager has equivalent explicit options:

```bash
# Preflight only: no producer input, persistent package, signing or network.
bash src/release_packaging.sh --recipe /srv/packaging.json \
  --check-source --source-repo /srv/checkouts/demo \
  --repo owner/demo --tag v1.2.3 --sha "$SOURCE_COMMIT"

# Materialize a derivative of the admitted producer manifest.
bash src/release_packaging.sh --recipe /srv/packaging.json \
  --source-repo /srv/checkouts/demo \
  --manifest /srv/build/build-manifest.json \
  --manifest-sha256 "$REVIEWED_PRODUCER_MANIFEST_SHA256" \
  --artifacts-dir /srv/build/artifacts --output-dir /srv/packaged \
  --repo owner/demo --tag v1.2.3 --sha "$SOURCE_COMMIT"
```

The checkout must be the canonical Git worktree root, with a credential-free
GitHub origin matching the selected repository and an existing local tag
resolving to the selected source commit. HEAD may have advanced and the working
tree may be dirty: **only raw Git objects from that commit are read**. Export
attributes, Git replacement objects, ambient Git repository/config overrides,
untracked files, and working-copy edits cannot substitute companion bytes.
No tag is created or moved, no checkout is changed, and no object is downloaded.
Missing local objects require restoring the reviewed source first.

Companion source paths may have up to 16 safe segments and 1,024 characters;
archive destinations are safe flat basenames of at most 128 characters. There
are at most 256 distinct source companions. Links, submodules, directories,
traversal, case-colliding destinations, and collisions with explicit binary
members are refused. Regular Git modes `100644` and `100755` determine exact
non-executable/executable companion modes; empty regular files are supported.

For prebuilt archives, missing companions cause a new derivative archive.
An existing companion must match the selected Git blob bytes and executable
bits exactly; it is never overwritten. A matching complete same-format archive
is preserved byte-for-byte without recompression. Different formats are built
from extracted payload files, never by nesting the original archive. Producer
archive hashes, manifests, and binary contents remain unchanged. Derived
payloads are unsigned until the existing finalizer signs their new bytes.

Each completed package retains raw commit, ancestor-tree, and blob objects under
`release/source/companions/`. `packaging_evidence.source_companions` records the
selected commit, every source path/blob/Git mode/content hash/size, and the
retained object inventory. Retry recomputes Git object identities and traverses
the retained tree chain, rather than trusting a rewritten per-file receipt.
The proof is bounded to 2,048 objects, 64 MiB per object, and 256 MiB total;
individual Git reads have a 60-second timeout and owned process-group cleanup.

Once the package is complete, omit `--packaging-source-repo` (or the direct
packager's `--source-repo`) to reverify without the original source checkout.
The finalizer defers to full retained-proof validation before signing or any
release API call; a directory's existence alone never qualifies its contents.
Changed recipes, altered proof objects, missing/extra proof files, or modified
outputs fail without repair. Reverification preserves completed bytes and
inodes. The original compiler run and timestamps remain compiler evidence;
source companions are explicitly packaging evidence, not a new compilation.

The selected commit is the trust anchor. Hash-linked object membership does not
by itself authenticate the commit's author, prove legal license classification,
or defend against a malicious privileged build host. An incomplete companion
list cannot be inferred automatically; review it along with the release recipe.

Run `bash scripts/tests/test_release_source_companions.sh` for actual Git,
archive, manifest-admission, source-preflight, public build-set dry-run and
handoff regressions. These tests do not call live GitHub or sign a release.
