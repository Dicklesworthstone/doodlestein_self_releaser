# Signed release integrity bundles

`src/release_integrity.sh` prepares, publishes and independently verifies the
checksum/signature assets needed by release consumers. It composes the existing
successful-build manifest validator, exact Minisign signer/verifier and GitHub
transport. It does not create releases or tags, build binaries, publish private
build manifests, or choose a trust key from a downloaded release.

## Prepare a complete signed set

```bash
bash src/release_integrity.sh prepare /path/to/artifacts \
  --build-manifest /path/to/build-manifest.json \
  --repo owner/tool --tag v1.2.3 --sha FULL_40_CHARACTER_COMMIT \
  --public-key /path/to/trusted-minisign.pub \
  --secret-key /path/to/minisign.key --output-dir /path/to/integrity
```

The successful DSR build manifest, exact source commit/version, complete named
payload set, positive file sizes and SHA256 hashes are checked before signing.
The source directory must contain exactly the selected top-level payloads; the
existing SBOM metadata exclusion policy applies. Versioned and installer-compatible
hardlink aliases remain distinct names. Embedded build-manifest filesystem paths
are ignored. The public key is mandatory; the secret key defaults to the existing
signing module's configured key when omitted. Minisign retains responsibility for
unlocking password-protected keys; the module never puts passwords in arguments.

The output contains a `.minisig` for every payload, canonical
`checksums.sha256` and its signature, and `release-integrity.json` plus its
signature. Checksum records use the entire artifact basename in stable order.
The signed JSON binds the repository, tag, source commit, tool, private build
manifest's SHA256, exact payload names/hashes/sizes, and every payload/checksum
signature's name/hash/size. It contains no private source paths or secret key.
Its public-key field is descriptive: verification always uses the independently
selected `--public-key`, and requires that field to match the selected key.

A secret-key file that is also a selected payload (including a hardlink alias)
is rejected before snapshotting or publication. Every input is copied to a
private snapshot. All retained signatures are checked before using the private
key, and all missing signatures are staged and verified
before new public outputs appear. Conflicting existing checksum/proof files are
not overwritten. Publication is no-clobber and per-file atomic, not an atomic
transaction over the whole bundle. The master manifest signature is published
last. Completed sidecars survive a late local failure and are verified on retry.
A completed identical bundle can be reused without accessing the private key.

`prepare --dry-run` validates the local build and public-key token and returns a
plan, without signing, network requests or public outputs. It does not establish
that the private key is usable or that remote assets exist.

## Verify locally and publish

```bash
bash src/release_integrity.sh verify /path/to/artifacts \
  --build-manifest /path/to/build-manifest.json \
  --repo owner/tool --tag v1.2.3 --sha FULL_40_CHARACTER_COMMIT \
  --public-key /path/to/trusted-minisign.pub --output-dir /path/to/integrity

bash src/release_integrity.sh publish /path/to/artifacts \
  --build-manifest /path/to/build-manifest.json \
  --repo owner/tool --tag v1.2.3 --sha FULL_40_CHARACTER_COMMIT \
  --public-key /path/to/trusted-minisign.pub --output-dir /path/to/integrity
```

Payloads must already exist on the selected GitHub release. Publication verifies
the local signatures and exact remote payload namespace, then preflights every
occupied proof name before any upload. Public proof bytes are privately frozen;
source files and metadata hashes are rechecked between uploads. Conflicting bytes,
unfinished assets, changed identities and an orphaned master signature are errors,
not authorization to clobber or delete anything.

Only missing assets are uploaded. The authenticated manifest signature is last,
after payload signatures and signed checksums. Completed uploads are retained
after failure. An identical retry observes existing bytes and sends only missing
work, including recovery after a lost acknowledgement. Missing integrity files
can be added only to a draft. A complete matching published release can be verified
on a read-only retry; an incomplete public release is not modified.

The publisher performs independent remote verification before reporting success.
Observed repository/release/tag and asset identities must remain unchanged during
the operation. A remote read and the next write are not a transaction: late changes
can leave partial public results, and those results are never silently rolled back.

`publish --dry-run` validates the local build selection and key and returns a local
plan without authentication or remote reads. It does not promise that publication
will pass remote preflight. `--manifest-sha256` can additionally pin the exact local
signed manifest for normal verification/publication.

## Independent remote verification

```bash
bash src/release_integrity.sh verify-release \
  --repo owner/tool --tag v1.2.3 --sha FULL_40_CHARACTER_COMMIT \
  --public-key /path/to/independently-trusted-minisign.pub
```

No local build manifest, payload directory or secret key is needed. An optional
`--manifest-sha256` adds an independently selected exact manifest pin. Remote-only
verification rejects `--dry-run` rather than producing a pretend verification.

The verifier first downloads and authenticates the master manifest using the
selected key, then checks its repository/tag/commit policy. It requires the exact
remote payload set, downloads all payloads and proof documents by immutable asset
ID, and checks their byte counts and SHA256 hashes. Every payload, checksum and
master detached signature is verified with Minisign's prehashed-only (`-H`) mode.
The checksum file must contain exactly the canonical records for that signed set.
API digests are consistency checks, never a substitute for these signature checks.
Missing API digests permit downloads; advertised mismatches or unsupported digest
algorithms are rejected. The final remote inventory and context are reread before
returning a verified receipt.

The receipt includes `authenticated: true`, the selected public key, signed
manifest hash/asset ID, source commit and the verified assets. This means those
bytes and release identities were checked against that operator-chosen key. It
does **not** prove build execution, hermetic compilation, scanner completeness,
vulnerability freedom, key ownership, or a SLSA build level. The signing host,
selected key, build manifest and cryptographic executable remain trusted inputs.

For integrations, source the module and call `release_prepare_integrity`,
`release_verify_integrity`, `release_publish_integrity`, or
`release_verify_remote_integrity`. Success emits one JSON result on stdout;
diagnostics use stderr and failures return nonzero without a verified receipt.
This explicit API does not run implicitly from ordinary `dsr release`. The
finalizer can require the same bundle as part of its integrated release flow.

## Require signatures during finalization

```bash
bash src/release_finalize.sh /path/to/artifacts \
  --repo owner/tool --tag v1.2.3 --sha FULL_40_CHARACTER_COMMIT \
  --upload-payloads --build-manifest /path/to/build-manifest.json \
  --require-signatures --public-key /path/to/trusted-minisign.pub \
  --secret-key /path/to/minisign.key --integrity-dir /path/to/integrity \
  --output-dir /path/to/sbom-metadata --promote \
  --tool tool --dispatch-repos owner/checksums,owner/formulas
```

The release and tag must already exist. With this policy, the finalizer prepares
and verifies all local signatures **before uploading any payloads**, then uploads
and authenticates the public signature/checksum bundle, runs the existing SBOM
pipeline, and only then permits promotion. Omitting `--promote` keeps a verified
draft ready. Omitting `--upload-payloads` works when the selected payloads already
exist remotely; `--build-manifest` is still required by the signature policy.

`--require-signatures` must be selected with an explicit `--public-key`. The
`--secret-key` is optional as in standalone preparation, and completed retries
need no private key. The integrity directory defaults to `--output-dir` (or the
artifact directory), but `--integrity-dir` can separate signed proofs from SBOMs.
Signing options without `--require-signatures` are rejected, not silently ignored.

The selected public-key token, original successful build selection, canonical
proof directory, signed manifest hash and exact public document hashes become
part of the finalization's saved policy. Once selected, this requirement cannot
be omitted, weakened by choosing another key, or redirected to different proof
bytes on retry. The original build manifest is copied and hash-checked before
signing, preventing a different valid manifest appearing after planning from
changing the release. Only the public key is snapshotted; secret-key bytes are
never copied into state. Mutation of the original public-key file during the
operation cannot change the frozen token; a later invocation using a different
token conflicts with the saved policy.

Select the signing policy before evidence finalization. An already-bound
unsigned finalization cannot acquire new signature assets in place: its saved
complete asset inventory would change. Creating a deliberately new finalization
state is an operator action, not an automatic reset of the existing record.
Likewise, missing proofs are not added to an already-public release.

After signature publication, the finalizer keeps the exact verified payload and
proof asset IDs bound through SBOM verification, promotion and every guarded
downstream request. The SBOM's payload names and hashes must match the signed
selection, even when no payload upload was requested. Changed source files,
local signatures, remote signature IDs, or a malformed authenticated-verification
receipt block further progress. The finalizer independently downloads and checks
the complete signed release again after SBOM publication and any draft promotion.
Later handoff gates rehash the frozen local bytes and check the same remote asset
identities; they do not repeatedly fetch every binary before every POST.

An authenticated manifest reference and the chosen public-key token are included
in downstream `release_evidence.integrity`. Receivers must independently apply
their trust policy rather than automatically trusting the delivered key. Results
include an `integrity` receipt separately from the existing SBOM `verification`
receipt. The signature policy authenticates the selected payloads, checksum file
and release identity; **SBOM documents themselves are not signed by this bundle**,
and no authenticated build-execution/provenance claim is implied.

Partial uploads remain recoverable and no unsigned fallback is permitted when
the signature requirement is selected. A failure after promotion or after one
downstream acknowledgement returns nonzero without rolling back the already
public release or concealing earlier effects. Dry-run validates the local build
and public key and identifies signature stages without using the secret key,
creating persistent state, reading GitHub, signing, or uploading.

## Resources and tests

Preparation requires temporary space for all payload snapshots, including aliases.
Remote verification downloads every payload and may retain both transport files
and named verification copies. This deliberately prioritizes checking actual
signatures over trusting metadata-only comparisons. Intermediate upload gates
reuse verification of unchanged asset IDs/metadata and use hashes for frozen
local bytes, avoiding repeated public-key operations and repeated downloads of
all already verified proofs before each upload.

```bash
bash scripts/tests/test_release_integrity.sh
bash scripts/tests/test_release_integrity_finalize.sh
```

The regression harness uses real SHA256, Ed25519/Blake2b signatures, files and
publication operations. Its Minisign process is an explicitly labeled independent
Python reference adapter implementing the documented wire format, using the
`cryptography` package; it is not the native Minisign binary or its encrypted-key
loader. When native Minisign is installed, an additional interoperability check
verifies a reference-generated signature. GitHub operations are file-backed
fixtures. No test accesses production keys or a live release.

The integrated suite executes the production finalizer and integrity module,
including actual cryptographic checks through that reference adapter. SBOM
generation, binary-upload orchestration and downstream delivery are explicit
subsystem fixtures, not end-to-end runs of those external systems. It covers
policy downgrade rejection, private-key-free retry, signed-set/SBOM mismatch,
changes across promotion and guarded handoff, and competing finalizers.
