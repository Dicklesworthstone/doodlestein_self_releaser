# Release provenance

DSR supports in-toto statements with the SLSA v1 predicate. The sourceable
`src/slsa.sh` module also provides standalone commands, so release verification
does not need build-host configuration or a source checkout.

## Generate from the recorded build

Use a successful schema `1.0.0` DSR build manifest and a directory containing
its final artifacts under their release basenames:

```bash
bash src/slsa.sh generate-manifest /path/to/manifest.json /path/to/dist \
  --repository OWNER/REPO \
  --builder https://example.org/builders/dsr-production \
  --output /path/to/release.intoto.jsonl
```

Generation validates the manifest's source pin, source dependencies, successful
target counts, artifact records and any supplied host results. Every named file
must be regular, non-symlinked, and match both its recorded SHA256 and size. Both
versioned names and installer-compatible aliases are subjects, including when
they are hard links to identical bytes. Embedded artifact paths are never read.

The statement records the actual manifest completion timestamp, invocation ID,
DSR version when available, source commit, and pinned sibling dependencies. It
does not invent a build start time. The complete manifest is bound by SHA256;
private environment values and build-local paths are not copied into the public
statement. Retain the original manifest bytes to audit that evidence.

The core manifest schema does not require repository ownership. `--repository`
therefore supplies an explicit `owner/repo` binding, recorded as caller-supplied.
When `source.repository` is present, it must match that selection as either
`owner/repo` or `https://github.com/owner/repo`, using the same exact spelling.
A `manifest-bound-build-set` receipt's `bundle_evidence.repo` must agree too;
publishing an aggregate directly cannot discard its selected repository.
The producer remains responsible for correctness. No repository name is inferred
from the tool name, current directory, or artifact location.

This profile accepts UTC second-resolution `built_at` timestamps, the schema's
Linux/macOS/Windows targets, and tar.gz, tar.xz, ZIP, binary or none formats. It
rejects partial/failed builds, missing targets, duplicate names, invalid pins,
and metadata that disagrees with successful target coverage. This is validation
of the fields consumed by this profile, not a general JSON Schema validator.

Successful compilation alone does not make a build publishable. Explicit
`build_purpose` and `publishable` declarations, at both manifest and artifact
level, must be `"release"` and the JSON boolean `true`, respectively. Diagnostic,
debug, false, null and mistyped declarations are rejected. This includes aliases
that share an inode with an otherwise eligible payload. Older manifests may omit
these fields; explicit null is not equivalent to omission. `generate` remains
available for observation-only statements about non-release artifacts.

When `requested_targets` is present, it must be a nonempty array of distinct
valid targets matching the artifact target set exactly. Order does not matter;
aliases do not count as extra targets. A missing platform cannot be concealed
by reducing the summary counts to describe only the successful subset.

These checks live in the shared manifest admission used by direct payload
uploads, manifest-bound signature preparation, and the finalizer, not only
bundle collection. Rejected manifests return exit `4` before an upload selection
or final provenance file is emitted. This validates producer declarations, not
their authenticity: an unsigned manifest can still omit or falsify evidence.
Verification without an expected manifest cannot recover policy fields omitted
from a previously generated statement.

Identical retries retain existing statement bytes. Conflicting statements and
orphan detached signatures are never overwritten. Publication is atomic for a
single statement; trusted producer directories must remain stable while they
are read. A detected change after publication returns failure but does not
unsafely delete a published pathname that another process may be using.

## Authenticate and verify the release

Sign the statement using DSR's configured Minisign keypair:

```bash
dsr signing sign /path/to/release.intoto.jsonl
```

Then verify using an independently trusted public key and expected builder:

```bash
bash src/slsa.sh verify-release /path/to/release.intoto.jsonl /path/to/dist \
  --builder https://example.org/builders/dsr-production \
  --public-key /path/to/trusted-minisign.pub \
  --manifest /path/to/manifest.json --repository OWNER/REPO
```

`--public-key` requires `--builder`: neither the statement's self-declared
builder nor an embedded key may select the trust policy. The detached signature
is `<statement>.minisig` unless `--signature FILE` is given. The verifier requires
prehashed Minisign signatures and fails on a missing/rejected signature, missing
verifier, or changed authentication inputs. It never falls back to unsigned
verification. Public keys use the standard two-line Minisign file format.

Every subject's bytes are checked, not just the first artifact. Supplying
`--manifest`, `--repository` and `--builder` additionally requires the exact
statement for that build, including its complete subject set and run identity.
Unrelated files in the distribution directory are not automatically subjects.
Without an expected manifest, the command checks every subject in the statement,
not that the producer declared every artifact the consumer expected.

A single artifact can be checked against a multi-subject statement:

```bash
bash src/slsa.sh verify /path/to/dist/ARTIFACT /path/to/release.intoto.jsonl \
  --builder https://example.org/builders/dsr-production \
  --public-key /path/to/trusted-minisign.pub \
  --source-repository https://github.com/OWNER/REPO --source-commit FULL_SHA
```

The same verifier accepts `--build-type URI` and `--invocation-id ID` policies.
Without `--public-key`, verification only checks structure, named bytes and
policy. It explicitly reports that the signer is not authenticated.

## Publish signed provenance and verify GitHub bytes

The remote companion, `src/slsa_remote.sh`, uses the existing uncached release
and numeric-asset-ID transport. It does not use statement-embedded download
URLs, infer a trust key from GitHub, or execute downloaded binaries.

After generating and signing the manifest-backed statement above, attach it
to an existing draft whose complete payload set has already been uploaded:

```bash
bash src/slsa_remote.sh publish-release /path/to/release.intoto.jsonl /path/to/dist \
  --repo OWNER/REPO --tag v1.2.3 --sha "$SOURCE_SHA" \
  --builder https://example.org/builders/dsr-production \
  --public-key /path/to/trusted-minisign.pub \
  --targets linux/amd64,windows/arm64
```

Use the actual full source commit and entire expected platform matrix. The
publisher first authenticates the local statement and checks every named local
payload. It then verifies the existing remote tag, complete payload namespace,
downloaded payload hashes/sizes, and any occupied provenance names before an
upload. It uploads only `release.intoto.jsonl` and its `.minisig` sidecar, from
frozen private copies, in that order. It does not upload binaries, the private
build manifest, keys, or working-state files. No private key is accepted and no
signing, tag/release creation, promotion, deletion or asset replacement occurs.

The default local signature is `<statement>.minisig`; `--signature FILE`
selects another already-prepared signature. `--statement-name NAME.intoto.jsonl`
selects the remote basename for both the statement and its signature.
`--dry-run` (also `DRY_RUN=true` for publication) authenticates local inputs but
makes no remote calls and reports `remote_verified: false`.

Only drafts may acquire missing provenance assets. An already-complete public
release can be reverified without writes. Conflicting occupied bytes, incomplete
`starter` assets, or an orphan `.minisig` are errors. Each missing name gets one
upload attempt. A lost acknowledgement returns failure; repeating the same
command re-reads existing assets and uploads only what is still missing. Keep
the exact signed input files for retry rather than signing a new pair. Accepted
uploads are not rolled back when a later operation fails.

Before success, the publisher independently downloads and authenticates the
remote statement and signature again and rechecks every payload. That result
must refer to the original repository/release identity and the expected final
asset inventory, not merely another release with matching names. Changes to
the original local statement/signature/payloads or selected public key also
prevent success. The success receipt includes upload count and the complete
remote verification receipt.

A consumer can verify the GitHub release without local artifacts, a source
checkout, or the private build manifest:

```bash
bash src/slsa_remote.sh verify-release \
  --repo OWNER/REPO --tag v1.2.3 --sha "$SOURCE_SHA" \
  --builder https://example.org/builders/dsr-production \
  --public-key /path/to/trusted-minisign.pub \
  --targets linux/amd64,windows/arm64
```

Every identity option shown is required. Both the signed target matrix and the
recorded artifact targets must equal the operator's matrix; a signed subset
cannot redefine success. All installer aliases remain separate subjects. The
complete remote non-metadata payload namespace must equal the signed subjects.
The profile requires DSR manifest-backed SLSA v1 statements, not observation-only
statements or an arbitrary producer's in-toto extension profile.

`--statement-sha256`, `--manifest-sha256`, and `--invocation-id` optionally pin an
exact statement, private manifest digest, and build invocation independently.
Without those optional pins, a trusted producer can issue another statement
for the selected repository/tag/commit/matrix; the verifier does not impose a
chronological anti-replay policy. The public receipt retains all these observed
identities, statement/signature asset IDs, and an inventory digest.

All payloads are downloaded and hashed even when the API advertises digests.
Conflicting or unsupported API digests are rejected, never downgraded to a
different trust path. Missing digests are acceptable only after byte verification.
The final uncached release/tag/inventory reads must equal the initial observation.
No success JSON is emitted on failure. Dependency, argument, interruption and
network failures preserve codes 3, 4, 5 and 8; policy/drift failures use 7 and
the existing local signature/asset verifier may return 1.

Live operations require Bash 4+, jq, Minisign, SHA-256 tools, normal filesystem
utilities, and the existing public-GitHub adapter with credentials. They do not
need Syft or build-host configuration. `SBOM_REMOTE_TIMEOUT` bounds adapter
operations. Remote statements default to the existing 64 MiB document limit;
signatures are limited to 64 KiB. `SLSA_REMOTE_MAX_PAYLOAD_BYTES` defaults to
8 GiB for the sum of declared payload sizes. Allow temporary space for the
complete set; publication performs payload verification both before and after
its uploads. These are admission limits and timeouts, not a streaming disk quota
against an HTTP server lying about its response size.

These standalone commands do not change the finalizer's default policy. Select
the integrated provenance policy below to gate promotion. Remote observations are not an atomic
GitHub transaction. Signatures authenticate the producer's statement, not the
truth of its compilation claim, every toolchain component, or a SLSA build level.
Sourceable APIs are `slsa_publish_release` and `slsa_verify_remote`.

Run `bash scripts/tests/test_slsa_remote.sh` for complete-set policy, byte drift,
remote identity changes, interrupted upload recovery and read-only retry tests.
The suite uses real statement generation, hashing and filesystem operations;
GitHub transport helpers and Minisign are explicit fixtures, not live API or
cryptographic acceptance tests.

## Require provenance during finalization

The existing finalizer can generate, sign, publish, and verify the exact
manifest-backed statement as a required stage before publishing a draft:

```bash
bash src/release_finalize.sh /srv/dist \
  --repo OWNER/REPO --tag v1.2.3 --sha "$SOURCE_SHA" \
  --upload-payloads --build-manifest /srv/build-manifest.json \
  --require-signatures --public-key /srv/keys/release.pub \
  --secret-key /srv/keys/release.key --integrity-dir /srv/integrity \
  --require-provenance \
  --provenance-builder https://example.org/builders/dsr-production \
  --output-dir /srv/sbom --promote
```

Use the actual repository, reviewed source commit, successful manifest, key
paths and expected builder identity. The tag and release must already exist
unless the existing `--create-draft` policy is also selected. This example
explicitly authorizes promotion; omitting `--promote` leaves the verified draft
unpublished. Provenance never implies signing, promotion, or downstream delivery.

`--require-provenance` requires `--provenance-builder`, a build manifest, and
either `--require-signatures` or `--prepared-signatures`. It uses the same
selected Minisign public key as the payload/checksum signature policy. Builder
identity is literal text, not a command or an inference from the statement.
Manifest `version` must equal the canonical selected tag, including its `v`
prefix, to satisfy the remote provenance profile. The successful manifest's
entire target matrix, every alias, invocation ID and SHA-256 become required
remote verification inputs; none may be selected from a downloaded statement.

Normal mode creates or reuses `release.intoto.jsonl` and its `.minisig` in the
integrity directory, before uploading build payloads. The statement binds the
exact private build manifest without publishing its raw environment values.
Conflicting local files and orphan signatures are never overwritten. Once
selected, the pair is copied into private staging for transport, and original
bytes remain guarded throughout finalization. Only the existing payload and
integrity publishers upload their own assets; the provenance publisher adds
the statement pair after payload verification and before SBOM finalization.

The finalizer independently re-verifies remote provenance after SBOM publication
and before promotion, then again after any promotion and before downstream
delivery. The statement, signature, builder, source, manifest and invocation
identities must agree with the frozen policy, and both proof asset IDs must
remain unchanged. The full asset inventory fingerprint must equal the SBOM
verification's fingerprint. A boolean `authenticated: true` alone cannot pass.
The final `provenance` receipt describes the last remote observation; downstream
events retain the selected signer, builder, proof IDs/hashes and build identity.

The policy lives in persistent finalization state from the start. A retry cannot
add, omit or change it, select another builder or build manifest, regenerate a
missing retained signature, or adopt new proof asset IDs. A lost upload
acknowledgement is recovered by the existing publisher's exact-byte readback;
the same invocation reuses the selected signed pair without signing it again.
Keep the manifest, local proofs, key and finalization state available for retry.

Prepared mode must already contain the exact manifest-backed statement and
detached signature alongside the prepared payload/checksum proofs. It requires
the private build manifest even when payload upload is not requested, so the
finalizer can compare the exact statement rather than merely trusting its claim.
It authenticates local inputs before release creation and never generates or
signs provenance. Invalid prepared proof prevents remote effects and persistent
state creation. Normal-mode dry-run pins the planned statement but neither signs
nor verifies remote bytes; prepared-mode dry-run authenticates existing proofs.

### Build plans and build sets

The same two options are accepted by the existing combined entry points:

```bash
bash src/release_finalize.sh --build-plan /srv/release-plan.json \
  --build-dir /srv/release-run --build-jobs 2 \
  --require-signatures --public-key /srv/keys/release.pub \
  --secret-key /srv/keys/release.key \
  --require-provenance \
  --provenance-builder https://example.org/builders/dsr-production
```

`--build-set FILE --bundle-dir DIR` accepts the same provenance options. The
complete aggregate supplies the manifest and target matrix; do not override
those plan-owned inputs. Invalid option combinations are rejected before
builders or collection start. Successful builds alone do not bypass the core's
provenance gate. Combined dry-run reports `policy_verified: false`: it validates
the plan/option structure, not cryptographic inputs or remote policy. Default
integrity/provenance output stays with metadata outside immutable payloads.

A failure before promotion leaves the draft and completed assets available.
Failure after a promotion has occurred blocks successful finalization and
downstream sends, but does not delete assets or turn the release back into a
draft. Repeating the same policy rechecks the published release. This is not a
distributed transaction, chronological anti-replay service, or proof that a
trusted producer's compilation claims are true. Local state and build hosts
remain trusted, and no SLSA build-level certification is claimed.

Run `bash scripts/tests/test_release_provenance_finalize.sh` and
`bash scripts/tests/test_release_provenance_pipeline.sh`. They exercise the
actual finalizer, entry point, complete SLSA mapper/verifier and payload-manifest
admission functions. Signing, scanning, remote provenance/integrity transport
and dispatch are explicit file-backed fixtures; the pipeline suite additionally
uses deterministic producer/collector command fixtures. These are not live
compiler, GitHub, Minisign cryptographic, or full-repository acceptance runs.

## Observation-only statements

`generate ARTIFACT [--repo-path DIR]` remains available for inspection. It marks
its output as a post-build observation, not evidence that an arbitrary existing
artifact was built from that checkout. Source is omitted unless explicitly
supplied; an invalid supplied checkout is an error, not a reason to substitute
DSR's own repository. Dirty tracked source is marked as such. Observation time
is distinct from build time. `generate-json` reports the operation's real exit
code and keeps human logs off the JSON stream.

## Trust boundaries and testing

Provenance is optional unless the explicit finalizer policy above is selected;
it is not automatically attached to ordinary `dsr release`. A valid
signature authenticates the selected producer's claim. It does not independently
prove the truth of an untrusted manifest, toolchain identities, build isolation,
or a SLSA build level. This format is signed JSON with a detached Minisign
signature, not a DSSE envelope or Sigstore verification workflow.

Run `bash scripts/tests/test_slsa_contract.sh` and
`bash scripts/tests/test_slsa_release.sh`. Tests use real Git, SHA256, filesystem
operations and concurrent publishers. The release suite runs native Minisign
round-trip verification when available; otherwise it explicitly skips that
case and uses a process-boundary fixture for authentication failure routing.

Format references: https://slsa.dev/provenance/v1 and
https://jedisct1.github.io/minisign/.
