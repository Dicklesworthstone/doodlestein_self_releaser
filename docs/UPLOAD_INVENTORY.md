# Ordinary release inventory admission at upload

`gh_upload_asset` and `gh_upload_asset_named` now enforce the adjacent DSR
manifest inventory in the actual shared upload path. This does not depend on
signing being enabled, a new signing batch running, or the remote name being
absent. Ordinary `cmd_release` already uses this path.

Before resolving credentials, the uploader freezes the exact names and hashes
of adjacent non-hidden `*-manifest.json` files through the existing signing
inventory API. All selected payload files, sizes, hashes and existing checksum
inventories must agree. The requested published payload name must have a manifest
row with the source digest. A canonical archive can supply a listed identical
compatibility alias; the uploader cannot invent an unlisted raw/archive alias or
publish one target's bytes under another target's row. Metadata may be uploaded
under its own basename, not as an alternate name for a raw executable.

The same frozen context is revalidated before every POST and before successful
return on all three completion paths: new upload, reuse of a matching remote
asset, and reconciliation of an ambiguous POST response. Receipt JSON is held
until the final local inventory check succeeds. Manifest disappearance, source
or target metadata changes, new unlisted payloads, and a consistently rewritten
subset cannot become a successful upload receipt. Existing remote content
verification and retry/backoff remain in force; a matching name alone is not
proof that remote bytes match.

This is per-upload admission, not a transaction over an entire release. A late
failure may leave an uploaded asset in place; the code neither deletes it nor
claims rollback. Callers still own their original selected manifest/root,
release/tag identity, whole-release remote inventory and publication visibility.
A generic upload without adjacent manifests remains supported. Explicit strict
plans and separately staged payloads retain their caller-side checks.

Signature/SBOM/provenance membership is not cryptographic verification. The
existing signing and proof verification APIs retain that responsibility. In
particular, this change does not apply the separate candidate `dsr` checksum
writer or fallback manifest-signing patch, and it does not repair historical
release assets in place.

## Regression

Run `bash scripts/tests/test_upload_inventory.sh`. With the unified runner,
allow the genuine compilation/archive fixture enough time:

```bash
bash scripts/run-all-tests.sh --filter test_upload_inventory.sh --timeout 900
```

The suite loads the complete production GitHub and signing modules. It builds
two dependency-free Go programs for Linux/macOS amd64/arm64, verifies ELF/Mach-O
machine types, and creates real tar.xz/ZIP archives. The complete positive case
checks 12 payloads plus the manifest, SHA256SUMS and 12 per-asset checksums at
the upload boundary, comparing final remote-fixture names and bytes.

Only token resolution and GitHub transport are substituted; hashes, files,
archives, snapshots, upload source copies, retries and receipt checks are real.
Negative tests verify no token/HTTP boundary is reached for invalid initial
inventories and no success receipt is emitted after late context changes. This
is not native execution on Darwin/ARM, live GitHub publication, cryptographic
signing, a full CLI build/release invocation, or a full-repository test run.
