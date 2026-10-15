# Ordinary release inventory admission at signing

The ordinary collector binds final release names before manifest deduplication.
Signing adds a separate, read-only check that those names still describe the
release directory. A valid Minisign signature on inconsistent JSON is not a
complete artifact inventory (issue #45).

## Enforced boundary

`signing_sign` and `signing_sign_batch` inspect adjacent `*-manifest.json` files,
including when fallback passes only payloads to the signer. Each manifest must
list unique, case-insensitively unambiguous final names, positive integer sizes,
and SHA-256 digests matching regular non-symlink files. Flat raw payloads and
archives cannot remain in the directory without manifest entries. Explicitly
listed companion files are also hashed; they are not silently discarded.

When `SHA256SUMS` exists, its names and hashes must equal the manifest artifact
set, without omissions, additional aliases, or duplicate lines. GNU text and
binary checksum records are accepted. Existing per-asset `.sha256` files must
match DSR's canonical `digest  final-name` record. The checks do not regenerate
or rename anything. Checksums may be absent before the release command generates
them; their presence is never mistaken for authoritative source selection.

Detached signatures, checksum documents, SBOM/provenance sidecars, DSR JSON
control files, and private staging directories are not additional payloads.
They are separate evidence, not new raw-binary names. This check does not claim
that every permitted metadata sidecar is cryptographically valid. The existing
signature verification and publication gates retain their responsibilities.

Admission runs before private-key use, again before publishing a signing batch,
and before successful completion. Exact signing of a DSR manifest also checks
its inventory immediately before its signature is exposed. An incomplete or
changed inventory returns an error; existing evidence is not rewritten. As in
the existing signing implementation, a late failure can leave already-published
valid sidecars in place rather than unsafely deleting shared paths.

`signing_verify` and `signing_verify_exact` remain byte/signature verification
APIs. A consumer can verify a downloaded manifest without downloading every
payload. This producer-side check neither proves native compiler provenance nor
changes the separate authenticated-release-integrity protocol.

## Verification

Run the production-module integration tests directly:

```bash
bash scripts/tests/test_signing_inventory.sh
```

The shell entry point is discovered by the repository test runner:

```bash
bash scripts/run-all-tests.sh --filter test_signing_inventory.sh --timeout 600
```

The fixture cross-compiles two dependency-free Go programs for Linux and macOS,
each on amd64 and arm64. It checks ELF/Mach-O machine types, retains target
triples and final raw names, and verifies duplicate archive-member basenames
without conflating their target-specific release names. This is cross-compiled
byte-custody coverage, not execution on all four operating-system/CPU pairs.

Tests cover omissions, renames, missing/linked files, changed bytes and sizes,
case collisions, checksum disagreement, malformed/concatenated manifests, and
pre-key refusal through the public signing entry points. Real Minisign tests
exercise signature verification, byte-identical resume, mutation of a payload
after signing a manifest, and a new unlisted payload arriving while a payload-only
batch is staged. The boundary-fault wrappers invoke the genuine signer; they do
not fake successful cryptography. These tests explicitly skip when Minisign is
unavailable. Missing Go/Bash/JQ/hash dependencies skip rather than substitute
text files for executables.

The collector/manifest integration regression remains
`test_ordinary_collection_inventory.sh`; these signing tests supplement it, not
replace the standard collection path or rely on native recovery.
