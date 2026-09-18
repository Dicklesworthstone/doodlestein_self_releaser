# Verified release finalization

`src/release_finalize.sh` connects the existing local SBOM inventory, GitHub
metadata publisher, remote verifier, draft publication and persistent downstream
handoff into one recoverable operation. With `--upload-payloads`, it first uploads
the exact binary/archive set from a successful build manifest. Without that flag,
release payloads must already be uploaded. The release and its tag must already
exist; this command does not build binaries or create tags/releases.
`--require-signatures` additionally prepares and authenticates signed payloads
and checksums, with a frozen operator-selected key, before allowing promotion.

```bash
bash src/release_finalize.sh /path/to/artifacts \
  --repo owner/tool --tag v1.2.3 --sha FULL_40_CHARACTER_COMMIT \
  --output-dir /path/to/sbom-metadata --promote
```

The SHA is an independently selected expected source commit. The command checks
the remote tag against it before scanning or uploading metadata. It does not infer
the commit from the working directory. This explicit pin is an operator assertion;
SBOM metadata is not an authenticated build attestation.

Without `--promote`, the command generates or reuses a complete local inventory,
publishes its SBOM documents and aggregate, verifies all selected remote payloads
and SBOMs, and retains the release's draft/public mode. A draft result is labeled
`ready`, not `published`. `--promote` explicitly authorizes publishing a verified
draft. Promotion changes only `draft` and sets `make_latest` to `false`; title,
notes, tag, target, prerelease mode and latest-release selection are not changed.

`--format spdx|cyclonedx` selects the inventory format. `--output-dir` defaults to
the artifact directory. The generator's verified retry path reuses finished SBOMs
without requiring another Syft scan. `--dry-run` (or `DRY_RUN=true`) validates
arguments and prints a plan without authentication, API calls, scans or persistent
state creation. A plan is not a verification result.

## Optional manifest-bound payload uploads

The complete upload-to-publication flow uses the existing finalization entry point:

```bash
bash src/release_finalize.sh /path/to/artifacts \
  --repo owner/tool --tag v1.2.3 --sha FULL_40_CHARACTER_COMMIT \
  --upload-payloads --build-manifest /path/to/build-manifest.json \
  --output-dir /path/to/sbom-metadata --promote \
  --tool tool --dispatch-repos owner/checksums,owner/formulas,owner/canaries
```

`--upload-payloads` requires `--build-manifest`. A build manifest can also be
supplied with `--require-signatures` when payloads already exist. The manifest
must satisfy the existing complete successful DSR build profile: schema `1.0.0`,
`status: success`, expected source commit and version, unique named artifacts with
SHA256 and positive sizes, and consistent successful target coverage. Recorded
host results, when present, must agree with that coverage. The manifest's tool
must also match `--tool` when dispatch is requested. Arbitrary embedded artifact
paths are ignored: files are selected only by validated flat names under the
explicit artifact directory.

The local top-level payload namespace must match the manifest exactly. Versioned
and installer-compatible hardlink names remain distinct assets. Selection uses
the existing SBOM payload policy, excluding text/JSON/checksum/signature metadata.
This stage uploads only those manifest-selected binaries/archives, **not** the
private build manifest, local upload state, checksum files, or signature sidecars.
Use the explicit `--require-signatures` policy below to prepare, publish and
verify the signed checksum/payload bundle in the same finalization invocation.
The payload-upload option alone is not a substitute for that policy.

Before the first upload, every selected file is hashed and copied into a private
snapshot. Temporary free space must accommodate the complete selected payload
set, including separate copies of aliases. All occupied remote payload names are
then checked before any write. A mismatching digest, size, incomplete `starter`
asset, extra payload, or orphan signature is a conflict, never clobber permission.
A present GitHub SHA256 digest must match; only a missing/null digest permits the
immutable-asset-ID download fallback. A claimed successful upload must subsequently
appear with the returned ID and matching bytes in a fresh remote inventory.

Missing payloads may be uploaded only to a draft. A complete matching public
release can be verified on a read-only retry, but an incomplete public release is
not modified. Uploads do not publish the draft: `--promote` remains a separate
explicit choice. The ordinary no-promotion result is `ready`.

The finalizer passes a private copy of the selected build manifest to the uploader
and checks its hash against the original plan. A different valid manifest appearing
after planning cannot silently select a new build for upload.

The frozen upload plan records the exact manifest hash, source/version, full
artifact set, repository/release identities, and confirmed payload IDs. Completed
uploads survive later failures. The same invocation resumes only missing work;
a lost acknowledgement is reconciled by observing retained remote bytes rather
than blindly repeating the upload. A retry cannot omit an unfinished target,
change the manifest, or silently accept replacement IDs for previously verified
payloads. No release assets are deleted or replaced.

Integrated payload state lives inside the finalization's private session under
`payloads/`. The original upload selection is also frozen in finalization state
and cannot be changed or omitted on retry. Local build hashes and uploaded asset
IDs remain bound through SBOM verification, promotion, and every guarded dispatch
attempt. An SBOM inventory describing different payload bytes blocks promotion.
Changing source files after promotion returns failure without rolling back the
already-public release. Results that reach finalization include a `payloads`
receipt alongside the release verification and dispatch outcomes. Earlier failures
retain completed upload state for the next identical invocation.

The payload stage is independently usable without scanning or promotion:

```bash
bash src/release_payloads.sh /path/to/artifacts \
  --build-manifest /path/to/build-manifest.json \
  --repo owner/tool --tag v1.2.3 --sha FULL_40_CHARACTER_COMMIT
```

Its sourced API is `release_upload_payloads`. Standalone state defaults to
`${DSR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsr}/release-payloads`, with
`--state-dir` available to select another root. Success prints one verified JSON
receipt; failures preserve nonzero process status and do not print a verified
receipt. `--dry-run` validates the local manifest and file set without credentials,
remote operations, scans or persistent state. It does not validate remote state.

The build manifest is trusted producer input, not cryptographic proof of build
execution. Upload state is trusted local recovery information. Local and remote
checks narrow observed change windows; they cannot form a transaction across the
filesystem, GitHub, and downstream receivers. Existing signature/provenance trust
boundaries below still apply.

## Required payload and checksum signatures

```bash
bash src/release_finalize.sh /path/to/artifacts \
  --repo owner/tool --tag v1.2.3 --sha FULL_40_CHARACTER_COMMIT \
  --upload-payloads --build-manifest /path/to/build-manifest.json \
  --require-signatures --public-key /path/to/trusted-minisign.pub \
  --secret-key /path/to/minisign.key --integrity-dir /path/to/integrity \
  --output-dir /path/to/sbom-metadata --promote
```

This policy signs every payload, canonical `checksums.sha256`, and a sanitized
`release-integrity.json` binding repository/tag/commit and the complete named
signature set. All signatures are staged and verified before any binary upload.
After payloads exist, missing integrity assets are uploaded to the draft, and an
independent verifier downloads and authenticates every payload and signature.
The master manifest signature is published last. Complete local bundles can be
reused without the private key; partial remote publication resumes missing work.

The selected public-key token, build selection and proof hashes are frozen in
finalization state. A retry cannot remove the requirement, switch keys, change
the signed set or reinterpret damaged signed state as unsigned. The same payload
set must appear in the SBOM inventory. Signature assets and local proof hashes
remain pinned through promotion and guarded dispatch; the complete remote signed
set is independently verified again after any promotion. Downstream evidence
includes the selected key and signed manifest reference, but receivers must use
their own trusted-key policy rather than trusting a delivered key automatically.

`--secret-key` is optional and otherwise uses the signing module configuration.
`--integrity-dir` defaults to the SBOM output directory. A public-key file and
build manifest are mandatory when signatures are required, including when the
binary-upload stage is omitted. Select this policy before evidence finalization;
it cannot be bolted onto an already-bound unsigned finalization by changing the
saved inventory. Missing proofs are never added to a published release.

Successful results include a separate `integrity` receipt. This authenticates
payload bytes, checksums and the selected release identity, not build execution
or the contents of the unsigned SBOM documents. A late failure leaves existing
uploads or an already-public release intact and returns nonzero without unsigned
fallback. See [RELEASE_INTEGRITY.md](RELEASE_INTEGRITY.md) for standalone commands,
retry rules, resource requirements and the precise trust boundary.

## Verified downstream handoff

Add an explicit tool identity and destination list to deliver the release event
only after the same release has been verified as public:

```bash
bash src/release_finalize.sh /path/to/artifacts \
  --repo owner/tool --tag v1.2.3 --sha FULL_40_CHARACTER_COMMIT \
  --output-dir /path/to/sbom-metadata --promote \
  --tool tool --dispatch-repos owner/checksums,owner/formulas,owner/canaries
```

This uses the existing persistent dispatch outbox, not a second delivery system.
Each `dsr-release` event carries `tool`, `version`, `sha`, `run_id`, `source_repo`
and the destination-specific `delivery_id`, plus a `release_evidence` object with
the verified repository/release IDs, format, manifest name/asset ID/SHA256,
artifact count and complete asset-inventory fingerprint. The entire request is
frozen in the outbox. Receivers must apply their own source policy, independently
verify evidence when required, and deduplicate `delivery_id` before effects; the
payload is not itself a signature.

The finalizer checks the public release identity, tag, manifest pin, complete
asset-inventory fingerprint and finalization-state hash before each destination,
again after recording sending intent, and before every HTTP retry. A change after
the first acknowledgement stops later destinations without discarding that
acknowledgement. A final check after delivery prevents a late change from being
reported as overall completion. These observations narrow race windows; they
cannot make remote reads and a subsequent POST an atomic transaction.

A gate failure before a POST is recorded as `blocked` (or remains `pending` when
it precedes sending intent), rather than claiming that a known-unsent request was
accepted or uncertain. Restoring the selected release permits a normal retry.
If a POST actually loses its acknowledgement, the outbox retains `uncertain` and
ordinary retries do not replay it. `--retry-uncertain` explicitly authorizes that
replay with the identical request and delivery ID; duplicate receiver effects
remain possible. Existing rate-limit deadlines and acknowledgement recovery
continue to apply.

The result is `complete` only when release verification and all dispatch
acknowledgements succeed. Downstream rejection or uncertainty returns nonzero
`incomplete` JSON containing both the already-published release receipt and the
per-target dispatch outcomes. Rerun the same command to resume incomplete work;
accepted targets are not resent and the release is not promoted again. Completion
means GitHub accepted the events, not that downstream workflows ran successfully.
The release is never rolled back because a downstream delivery fails.

`--dispatch-run-id` defaults to `<tool>-<tag>`. `--dispatch-state-dir` overrides
the outbox root; otherwise the existing `DISPATCH_STATE_DIR`/DSR state defaults
apply. Once selected, the normalized destination set, tool, invocation ID and
outbox root cannot be changed or omitted from that finalization. A previously
ready/published finalization without a handoff may acquire one once. A preexisting
outbox with the same invocation but different request/evidence is a conflict,
detected before promotion, not permission to repeat earlier work. A deliberately
new invocation ID can cause new effects and must be selected intentionally.

The finalizer always rechecks remote release evidence, even when every dispatch
was previously acknowledged, so it still requires GitHub access on a completed
retry. The standalone outbox's credential-free status/retry behavior is unchanged.
The integrated command rejects dispatch from an unpromoted draft, malformed
destinations, missing `--tool`, and dispatch options without `--dispatch-repos`.
Dry-run validates the selected destinations without creating an outbox or sending.

## Gates and recovery

The finalizer freezes repository/release IDs, tag commit, prerelease mode and
target, local inventory digest, remote manifest asset ID, and the complete remote
asset-inventory fingerprint. All identity fields must remain unchanged apart from
the explicitly authorized draft-to-public transition. A late asset replacement,
moved tag, malformed success receipt, changed source, or conflicting saved plan
prevents promotion or completion.

Each invocation checks actual local and remote evidence again. Saved state alone
can never establish success. Promotion intent is stored before the PATCH. A lost
acknowledgement is reconciled by re-reading and independently verifying the same
release; it is not blindly retried. If publication occurred but saving the local
completion failed, rerunning the same command recognizes the verified public
release and does not send another PATCH. A still-draft release after an unsuccessful
promotion remains a failure and can be retried after diagnosis.

State is private under `${DSR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsr}/release-finalize`.
`--state-dir` overrides that root. A kernel-released `flock` serializes cooperating
finalizers for the same repository and tag. State replacement is atomic on the
local filesystem; it is not a transaction with GitHub or a power-loss durability
guarantee. Corrupt, linked or conflicting state is rejected, not silently repaired.
Local storage, scanner, GitHub adapters and their credentials remain trusted.

Both success and failure print one JSON result and preserve the process status.
Successful results include the independent verification receipt, state path and
whether promotion was attempted. A reconciled transport failure is recorded even
when re-reading proves the release was successfully published. Errors do not copy
raw promotion API responses or credentials into diagnostics.

## Scope and requirements

This is an explicit finalization entry point, not an implicit change to `dsr release`.
It composes the existing library APIs; manifest-bound payload uploading is opt-in.
A complete local inventory requires Syft only when scans are missing. Runtime
requirements include Bash 4+, jq, SHA256 tooling, `flock`, and the existing GitHub
transport dependencies. Publishing a draft requires the GitHub CLI (`gh`).

Without `--require-signatures`, evidence establishes equality with the selected
inventory, not cryptographic authenticity. With it, the signed payload/checksum
bundle is authenticated against the independently selected Minisign key. Neither
mode establishes scanner completeness, freedom from vulnerabilities, or build
provenance; SBOM documents are not signed by this bundle. A published
release can remain published even when a later check fails; the finalizer never
deletes assets, rolls back the release, or conceals a partial external outcome.

```bash
bash scripts/tests/test_release_finalize.sh
bash scripts/tests/test_release_payloads.sh
bash scripts/tests/test_release_payload_pipeline.sh
bash scripts/tests/test_release_integrity.sh
bash scripts/tests/test_release_integrity_finalize.sh
```

This regression suite uses the production finalizer and dispatch outbox with real
JSON, hashing, files, atomic state operations, locks and concurrent processes.
It covers partial recovery, uncertain acknowledgements, evidence changes between
destinations and rate-limit retries, and changes after persisted sending intent.
SBOM library calls and GitHub transport are
explicit file-backed fixtures. It does not exercise a live registry, real Syft,
GitHub authentication or native macOS/Windows operation.

The additional payload suites exercise real build-manifest validation, hashing,
private snapshots, state publication and competing publishers. The integrated
suite runs the production uploader and finalizer, including the build-binding
guard used by dispatch. GitHub transport, SBOM creation/publication and downstream
delivery are explicit fixtures; the existing finalizer suite separately exercises
the production dispatch outbox. These tests do not assert live GitHub behavior or
cryptographic verification.

The integrity suites exercise real Ed25519/Blake2b verification through an
explicit Python reference Minisign adapter, with optional native interoperability
when Minisign is installed. The signed finalization suite runs the production
finalizer and integrity module; SBOM generation, payload-upload orchestration,
dispatch and GitHub transport are explicit subsystem fixtures. It verifies
policy preservation, stage-change rejection, partial recovery and competing
finalizers without accessing production keys or live releases.
