# Prepared signed bundles in release finalization

The finalizer can now consume the authenticated bundle produced by
`src/release_integrity.sh prepare`. It reuses that module's existing verification
and publication implementations; it does not introduce another signer, publisher,
or integrity-manifest format.

```bash
bash src/release_finalize.sh /path/to/artifacts \
  --repo owner/tool --tag v1.2.3 --sha FULL_40_CHARACTER_COMMIT \
  --upload-payloads --build-manifest /path/to/build-manifest.json \
  --prepared-signatures --integrity-dir /path/to/prepared-proofs \
  --public-key /path/to/independently-trusted-minisign.pub \
  --output-dir /path/to/sbom-metadata --promote \
  --tool tool --dispatch-repos owner/checksums,owner/formulas
```

`--prepared-signatures` requires both `--integrity-dir` and `--public-key`. It is
mutually exclusive with `--require-signatures` and rejects `--secret-key`. The prepared
proof directory contains `release-integrity.json`, its detached signature,
canonical `checksums.sha256`, the checksum signature, and every named payload
signature. The caller selects the trusted public key independently of the release
and bundle. In this mode, finalization never reads a private signing key,
generates keys, or signs anything. Prepare the bundle separately using the
existing integrity API. The separate `--require-signatures` mode on current main
still prepares missing signatures when authorized; this change does not remove it.

The signed bundle is optional; the existing unsigned finalization path remains
unchanged. The option works both with manifest-bound payload uploads and with
already-uploaded payloads. Already-uploaded payloads do not require the private
build-manifest file: the signed bundle supplies its hash and named payload set.
With `--upload-payloads`, the build manifest is required and the bundle must match the
exact selected build-manifest hash, tool, artifact names, sizes, and hashes.
With a downstream handoff, its tool must also match the selected tool identity.

## Authentication before external operations

The master signature authenticates the bundle's repository, tag, source-commit
claim, and all named payload/checksum/signature records. Each individual payload
and checksum signature is verified as well, using the existing Minisign `-H`
verification path. Local verification happens before any GitHub read, payload
upload, SBOM scan, promotion, or dispatch. The selected local payload namespace
must match exactly; compatibility aliases remain distinct names.

The finalizer freezes the selected public-key token, build selection, prepared-only
mode and proof directory in `integrity_policy`, with the signed manifest hash and
every checksum/signature record retained beside it in finalization state.
A repeated invocation cannot drop the policy, replace it with another valid key,
or substitute a newly signed bundle. Switching between prepared-only and signing
modes conflicts with the existing policy rather than permitting new signing on
retry. A ready or published unsigned finalization
cannot acquire a different policy after its release inventory was frozen. Choose
the intended policy at the start.

These signatures authenticate the signer's statements and selected bytes, not
independent evidence that a build actually ran as claimed. SBOM scan completeness,
build-environment identity and build execution remain separate policies. The
SBOM itself is not signed by this operation.

## Publication, promotion and recovery

The finalizer authenticates the bundle, optionally uploads the selected binaries,
publishes the authenticated proofs, then generates or reuses the SBOM inventory
and checks that the SBOM describes the same authenticated payloads. Before
signature publication it copies the frozen
proof set into a private staging directory and checks every copy against the
recorded size and hash. A different valid bundle appearing after planning cannot
silently become the bundle passed to the publisher.

The existing integrity publisher handles draft-only additive uploads, retained
proof verification and partial-upload recovery. Its complete receipt is validated
against the frozen signer, manifest hash, full asset namespace, sizes, digests
and unique asset IDs. Missing or incomplete publisher output cannot authorize a
promotion. A previously verified payload or proof asset that has been removed or
recreated is rejected before further integrity publication on retry.

After SBOM publication, the finalizer still requires exactly the payload/proof
IDs whose downloaded bytes were authenticated earlier. This prevents a signature
replacement during the SBOM stage from being silently absorbed into a later
successful inventory check. The same local byte and remote identity bindings are
checked before promotion and every guarded downstream handoff. The current
pipeline's independent remote signature verification after promotion is retained.
The final gate
also catches a local change after promotion without rolling back the public
release or pretending a previous acknowledgement did not happen.

The result includes an `integrity` verification receipt. Downstream evidence adds
`release_evidence.integrity` containing the verification policy, selected public
key and authenticated manifest identity. The full verified asset records remain
in the result's `integrity.assets`; the existing compact dispatch format is
preserved. The
public key carried in a dispatch is evidence of the sender's selection, not an
independent receiver trust anchor. Receivers must enforce their own trust policy
and retain the existing persistent delivery-ID deduplication behavior.

Rerun the identical finalization command after a failure to reuse completed work.
No signature file is overwritten and no remote asset is deleted. A transport or
late validation failure may leave completed uploads or an already-public release
in place; it remains a nonzero result, not a false successful transaction.

## Dry-run and scope

`--dry-run` authenticates the local prepared bundle and reports a plan without
GitHub requests, scans or persistent state. It still requires Minisign and valid
local signatures. It does not claim remote verification.

State is trusted local recovery data. The proof directory, verifier executable,
GitHub adapters and their credentials remain trusted. Hash/identity checks narrow
observed race windows, but they do not make local filesystem reads, remote asset
publication and downstream delivery a single atomic transaction or guarantee
power-loss durability. Existing draft promotion, latest-release selection and
no-clobber policies remain unchanged.

This extends the explicit `src/release_finalize.sh` command. It does not silently
replace ordinary `dsr release`, create tags/releases, or change signing policy for
existing unsigned calls.

## Tests

```bash
bash scripts/tests/test_release_signed_finalization.sh
```

The integration suite uses real Ed25519/BLAKE2b signatures, hashes, Bash, jq and
filesystem state. Native Minisign is used when installed; otherwise an explicitly
labeled Python `cryptography` adapter verifies the signature format. Production
adds no Python dependency. The test requires Python and `cryptography`.

GitHub, integrity publication, binary publication, SBOM and downstream delivery
are explicit fixture boundaries in the integration test. Bundle verification,
policy freezing and the production finalizer/gates are exercised directly. The
dispatch fixture invokes the guard but not the entire persistent outbox. Run the
existing integrity, payload-publication and dispatch suites separately for those
components; these tests do not claim live GitHub or full-checkout validation.
