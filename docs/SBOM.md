# Release SBOM generation and verification

DSR supports single-path Syft scans and resumable, source-bound inventories for a
complete selected release artifact set. SPDX and CycloneDX are supported. The
module requires Bash 4+, jq and either sha256sum or shasum. Syft is required only
when an artifact actually needs scanning; verified retries and verification do
not need it.

## Commands

The existing `dsr sbom generate` and `dsr sbom verify` commands use the hardened
single-document library functions. The complete release-set operations and the
single-scan JSON wrapper are also available through the standalone module:

```bash
bash src/sbom.sh artifacts dist/v1.2.3 --format spdx
bash src/sbom.sh verify-artifacts dist/v1.2.3 --format spdx

bash src/sbom.sh artifacts dist/v1.2.3 \
  --format cyclonedx --output-dir release-metadata/v1.2.3
bash src/sbom.sh verify-artifacts dist/v1.2.3 \
  --format cyclonedx --output-dir release-metadata/v1.2.3

bash src/sbom.sh json dist/v1.2.3/tool.tar.gz --format spdx
```

For sourced usage, the corresponding APIs are `sbom_generate`,
`sbom_generate_project`, `sbom_generate_json`, `sbom_generate_artifacts`,
`sbom_verify`, and `sbom_verify_artifacts`. Batch calls print one absolute
**complete manifest path**, only on success. The JSON wrapper emits an error
object on failure and returns the failing process status. Single scans accept
`--output FILE` and `--quiet`. Batch calls accept `--output-dir DIRECTORY`;
`SBOM_OUTPUT_DIR` is the fallback when that option is omitted.

These new batch commands are not automatically invoked by `dsr release`, and the
monolithic CLI does not yet dispatch `dsr sbom artifacts` or
`dsr sbom verify-artifacts`. Use the module entry points shown above.

## Output identity and coverage

The entire artifact filename is retained. `tool.tar.gz` and `tool.tar.xz` produce
`tool.tar.gz.sbom.spdx.json` and `tool.tar.xz.sbom.spdx.json`, not one colliding
`tool.tar.sbom.spdx.json`. CycloneDX uses the suffix `.sbom.cdx.json`. Directory
scans retain the default `sbom.spdx.json` or `sbom.cdx.json` inside the project.
An explicit output path overrides these defaults.

Batch selection policy `top-level-artifacts-v1` selects top-level regular files,
not nested directories. It excludes checksum/signature/public-key files, known
text/JSON/JSONL/YAML/Markdown/SBOM metadata, and conventional README/LICENSE/NOTICE
names (see `_sbom_is_metadata` for the exact extension/name policy). In particular,
existing SLSA `.intoto.jsonl` statements are not scanned as binaries. A metadata-only
or empty directory is an error. Selected symlinks, special files and filenames
containing control characters or backslashes are rejected; spaces are supported.
Distinct versioned and installer-compatible hardlink names remain distinct assets.

The release metadata consists of:

- `sbom-plan.spdx.json`: the frozen intended artifact names and SHA256 digests.
- `<artifact>.sbom.spdx.json.dsr.json`: an individual scan receipt binding the
  exact artifact name/digest to its SBOM name/digest.
- `sbom-manifest.spdx.json`: a deterministic complete inventory containing all
  those bindings, published only after the entire set has been reverified.

The corresponding CycloneDX control files use `cdx.json` instead of `spdx.json`.
Plans, receipts and aggregate manifests are **DSR control documents**, not SPDX or
CycloneDX SBOM documents. `sbom_verify` checks an individual standards document;
`sbom_verify_artifacts` checks the complete inventory against the current files.

## Retry and failure behavior

File scans use private snapshots retaining the source basename and verify source
hashes before and after scanning. Scanner failure, empty/malformed output, the
wrong format, source drift, invalid destinations and publication failures cannot
be reported as successful scans. Existing documents survive failed attempts.
Unsigned valid single-scan outputs can be regenerated atomically; signed or
invalid retained outputs are rejected rather than overwritten.

Batch generation freezes the entire intended release before scanning. Completed
SBOM/receipt pairs survive a later failure. A retry verifies those pairs and scans
only missing work. Removing an unfinished artifact, adding a new one, or changing
its bytes does not silently redefine the saved release plan. Use a new release or
metadata directory when intentionally changing the release set.

An unsigned valid SBOM left without a receipt by an interrupted publication is
rescanned before it is bound. An invalid receipt, a receipt without its matching
SBOM, an altered bound document, or an unbound signed document is a conflict, not
permission to weaken verification. A complete valid manifest is byte-stable on
retry and needs no scanner. Its bindings are sufficient for complete verification
without the per-artifact cache receipts.

Receipt and manifest publication uses no-clobber hardlinks. Each receipt has its
own staging inode. Concurrent first-time generation can return a conflict to a
losing publisher; a verified retry converges without replacing retained records.
Publication is per-file atomic, **not an atomic transaction across every release
file**. A late change can leave already-published metadata behind while the command
returns failure. Verify the current complete set before consuming or uploading it.

## Trust and validation limits

The document validator checks exactly one supported JSON document, typed required
identity/creation fields, expected format, and typed package collections when
present. It is not a full SPDX/CycloneDX JSON-schema validator. Empty package
collections are allowed; a successful scan does not establish that Syft recognized
every dependency or that the artifact has no vulnerabilities.

DSR receipts and manifests are unsigned local observations. They detect mismatch
between the recorded bytes and the current selected release; they do not establish
builder identity, an attested toolchain, an authenticated scanner configuration,
or artifact provenance. They do not verify detached signatures. Use an independently
trusted signing/verification policy when authenticity is required.

Directory scans are live observations rather than immutable source attestations.
Their output and in-progress staging directory are excluded from the scan. The
filesystem and scanner host remain trusted; these checks are not a sandbox against
a malicious local writer. Source file checks detect observed drift, not every
possible transient change on an adversarial filesystem.

## Regression coverage

```bash
bash scripts/tests/test_sbom_release.sh
bash scripts/tests/test_sbom_batch.sh
bats tests/unit/test_sbom.bats
```

The standalone suites use real Bash, jq, SHA256, filesystem operations, publication
failures and concurrent processes. Their Syft executable is an explicit process
fixture, not a real inventory scan. The batch suite also has an optional real-Syft
archive integration case and reports a skip when Syft is unavailable. The Bats
suite contains real-Syft integration cases as well. None of these tests performs a
live GitHub release or accesses production signing keys.

## Verify the actual GitHub release

Local verification alone does not establish that the release serves the same
artifacts and SBOMs. The remote verifier checks both, against a manifest digest
chosen independently of the release being inspected:

```bash
bash src/sbom_release.sh verify --repo OWNER/REPO --tag v1.2.3 \
  --manifest-sha256 EXPECTED_64_HEX_SHA256 --format spdx
```

For sourced use, load `src/sbom_release.sh` and call `sbom_verify_release` with
the same options. Supply the digest from a separately verified local inventory
or another trusted channel; obtaining both the manifest and its purported
trusted digest from the same untrusted release is not authentication.

The verifier resolves the existing tag and freezes numeric repository/release
identities. It reads every asset page without caching, requires the exact payload
namespace under the local selection policy, and checks every recorded SHA256.
Older assets without GitHub SHA256 metadata are downloaded by immutable asset ID
and hashed. A present mismatching or unsupported digest is an error, not permission
to fall back to weaker checks. Every SBOM document and the aggregate manifest are
downloaded by asset ID; their bytes, sizes and document contracts are checked.

A second uncached observation rejects changed release identities/modes, moved
tags, deleted/recreated asset IDs, missing files and late additions. Success prints
one JSON verification receipt. Failure returns nonzero with no success receipt.
Drafts and published releases can both be verified. An existing unambiguous tag is
required; no release, tag or asset is created or modified by verification.

The public GitHub host and one credential are frozen for the operation. Credentials
follow `DSR_GH_TOKEN`, `GITHUB_TOKEN`, `GH_TOKEN`, then the existing adapter's token
resolution. Caller environment variables, traps, umask and job control are not
changed. Syft and local payloads are not required for remote verification.

`SBOM_REMOTE_TIMEOUT` bounds each adapter operation, including retries and child
processes (default 900 seconds). `SBOM_REMOTE_MAX_DOCUMENT_BYTES` limits advertised
SBOM/manifest size before downloading (default 67108864 bytes); downloaded length
must also match the advertised size. Binary payload fallback downloads are not
subject to the document-size limit. Deadlines return exit code 5, invalid options
4, missing dependencies/credentials 3, integrity failures 7, and failed GitHub
reads/downloads 8. This is a per-operation deadline, not a whole-release deadline.

Remote verification trusts GitHub's asset identity and advertised SHA256 when
present. It does not verify Minisign signatures, authenticate the scanner, prove
builder identity, or attest source/toolchain provenance. Its repository/tag binding
describes the release observed now; the local SBOM format does not contain a signed
repository/tag binding. Filesystem and API observations are not a multi-file or
multi-request atomic transaction.

`bash scripts/tests/test_sbom_remote.sh` exercises the local inventory implementation,
real hashing/files and process-group deadlines with explicit GitHub/Syft fixtures.
It includes both formats, digest-less assets, full pagination, malformed proofs,
missing/extra payloads, identity changes, and a TERM-resistant transfer descendant.
