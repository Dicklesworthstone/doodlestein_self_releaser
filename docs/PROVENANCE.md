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

## Observation-only statements

`generate ARTIFACT [--repo-path DIR]` remains available for inspection. It marks
its output as a post-build observation, not evidence that an arbitrary existing
artifact was built from that checkout. Source is omitted unless explicitly
supplied; an invalid supplied checkout is an error, not a reason to substitute
DSR's own repository. Dirty tracked source is marked as such. Observation time
is distinct from build time. `generate-json` reports the operation's real exit
code and keeps human logs off the JSON stream.

## Trust boundaries and testing

These are standalone release operations; this change does not automatically
attach provenance generation or authentication to `dsr release`. A valid
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
