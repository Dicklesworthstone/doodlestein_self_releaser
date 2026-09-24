# Package a build set before finalization

The build-set finalizer can turn a verified multi-target producer bundle into
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

## Two contracts, one publication input

The build set's optional `required_assets` describes the **producer** namespace,
including raw companion executables. The packaging recipe describes the final
namespace: renamed binaries, independent archives, and byte-identical aliases.
Do not replace the producer requirements with archive names the compiler does
not emit. The finalizer checks the recipe's target matrix and, when declared,
its input names, target assignments and raw/archive compatibility before
collection. The packager independently requires every actual producer asset
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

These remain trusted local build-host operations, not a sandbox or a distributed
transaction. Read [finalization](RELEASE_FINALIZATION.md) and
[provenance](PROVENANCE.md) for the remote publication and authentication limits.

Run `bash scripts/tests/test_release_packaging_pipeline.sh` for actual archive,
collector, manifest and finalizer integration checks. Signing, SBOM scanning and
GitHub transport use the provenance suite's explicit file-backed fixtures. The
tests do not claim live GitHub publication, native Minisign, or Rust/Windows
compiler acceptance.
