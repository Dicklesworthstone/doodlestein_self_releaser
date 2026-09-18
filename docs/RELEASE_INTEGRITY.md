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

Every input is copied to a private snapshot. All retained signatures are checked
before using the private key, and all missing signatures are staged and verified
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
This explicit API does not yet run implicitly from ordinary `dsr release` or
from the finalizer; callers select the handoff after payload upload.

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
```

The regression harness uses real SHA256, Ed25519/Blake2b signatures, files and
publication operations. Its Minisign process is an explicitly labeled independent
Python reference adapter implementing the documented wire format, using the
`cryptography` package; it is not the native Minisign binary or its encrypted-key
loader. When native Minisign is installed, an additional interoperability check
verifies a reference-generated signature. GitHub operations are file-backed
fixtures. No test accesses production keys or a live release.
