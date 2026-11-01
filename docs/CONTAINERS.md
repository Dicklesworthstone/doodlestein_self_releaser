# Container builds and releases

The public `dsr docker` commands and the standalone `src/docker.sh` module share
the container workflow tracked by `bd-1jt.3.8`. Docker, Buildx, Syft and Cosign
remain external tools. The workflow does not install toolchains, enable emulation,
or change your globally selected builder.

## Build outputs

```bash
# Plan without contacting Docker, the registry, or signing services.
dsr docker build tool 1.2.3 --repo-path /path/to/tool --push --dry-run

# Push a version tag. Add --tag latest explicitly when appropriate.
dsr docker build tool 1.2.3 --repo-path /path/to/tool --push

# Without --push or --local, export an OCI archive instead of a hidden cache-only result.
dsr docker build tool 1.2.3 --repo-path /path/to/tool --output /tmp/tool.oci.tar

# Load one platform into the local Docker image store.
dsr docker build tool 1.2.3 --repo-path /path/to/tool --local --platform linux/arm64
```

Defaults are `DOCKER_REGISTRY=ghcr.io/dicklesworthstone`,
`DOCKER_PLATFORMS=linux/amd64,linux/arm64`, and `DOCKER_BUILDER_NAME=dsr-builder`.
The source is `--repo-path`, the registered tool's `local_path`, or
`/data/projects/TOOL`, in that order. Dockerfiles are found in the repository root,
`docker/`, or `build/`; `--dockerfile` can select another file inside the source
repository. The **repository root** is always the context, including for nested
Dockerfiles. The source checkout and Docker daemon are trusted; this is not an
immutable-source or sandboxed build attestation.

`--local` without an explicit platform uses Buildx's single default platform;
its receipt records an empty requested-platform list rather than inventing a
host architecture. Multi-platform `--local` and contradictory exporters fail
before invoking Docker. The local Docker exporter disables BuildKit attestations
rather than claiming the classic Docker image store preserves them.

OCI outputs default to `DOCKER_OUTPUT_DIR/TOOL-VERSION.oci.tar`, or the DSR XDG
state `containers/` directory when that variable is unset. They are staged next
to the destination and published without replacing an existing file. Output
inside the build context is rejected. A receipt includes the archive's SHA256
and size. This hashes the exported bytes; it is not an OCI-layout validator.

Build stdout contains one JSON receipt with the exporter, requested platforms,
context, tags, builder, and Buildx `containerimage.digest`. Missing, malformed,
multiple, or inconsistent Buildx metadata is a failure even if the subprocess
exited zero. `reference` is `REPOSITORY@sha256:DIGEST`. Buildx/registry output is
sent to stderr. The metadata is a trusted-builder observation, not independent
registry or signature verification.

`latest` is no longer added implicitly. Repeating `--tag` deduplicates explicit
tags, and a version beginning with `v` is not double-prefixed. Version strings
must be valid Docker tags; unsupported syntax is rejected, not rewritten.

## Release failure behavior

```bash
# Use the exact identity and issuer expected in your Fulcio certificate.
dsr docker release tool 1.2.3 --repo-path /path/to/tool \
  --certificate-identity builder@example.com \
  --certificate-oidc-issuer https://oauth2.sigstore.dev/auth

# Planning does not require signing credentials or invoke external tools.
dsr --json docker release tool 1.2.3 --repo-path /path/to/tool --dry-run
```

Choose the identity and issuer from your own signing policy, not from whichever
certificate happens to be attached to the image. `DOCKER_CERTIFICATE_IDENTITY`
and `DOCKER_CERTIFICATE_OIDC_ISSUER` provide environment defaults. Missing policy
is rejected before building or pushing. No wildcard policy, disabled claim check,
or transparency-log bypass is added. The examples are placeholders, not a signer
recommendation or a claim that authentication is already configured.

Release checks the policy and the availability of Syft/Cosign before pushing,
obtains the image digest from its own build, and then performs these gates:

1. Fetch exact raw registry manifest bytes and rehash them against that digest.
   For an index, validate child descriptors, their content hashes and sizes, and
   cross-check each executable platform against Docker's resolved image config.
   Require the exact requested platform set, not merely one successful image.
2. Scan each immutable child image separately, using `registry:` transport and
   the explicit platform. Validate all staged SPDX documents **before publishing
   any Cosign evidence**, so failure on ARM64 cannot leave a misleading complete
   set based only on AMD64.
3. Sign the immutable root index/image, then run `cosign verify` with the exact
   identity and issuer and validate the returned image digest. Unless explicitly
   skipped, failure to verify this signature stops the release.
4. Attest each architecture's SPDX document on that architecture's child digest.
   Run `cosign verify-attestation`, inspect only its verified DSSE statements,
   and require the correct repository, child digest, SPDX predicate type and
   the exact JSON predicate just scanned. An older valid attestation is not a
   substitute; multiple old and new attestations may coexist without clobbering.
5. Independently reread and verify the full signature/attestation set after all
   writes. Recheck the registry inventory and each published tag before returning
   a `status: "verified"` receipt with per-platform evidence digests.

A failed signing, scanning, attestation, verification or final tag check is a
failed release, not a warning followed by success. Invalid/partial scanner output
is never streamed into a concurrently running attester. False-success responses
from signing/upload commands cannot satisfy the later verification gates.

The supported registry shape is a Linux OCI image index or Docker manifest list
whose executable children are image manifests, or one image manifest with a
resolved Linux configuration. Nested indexes and unrecognized descriptors are
rejected. Recognized BuildKit `unknown/unknown` attestation descriptors must
reference a real child image; they are not counted as executable architectures.
Default `linux/arm64/v8` is normalized to `linux/arm64`, but distinct ARM variants
are not collapsed. Unsupported or duplicate platform sets fail explicitly.

`--skip-sign` explicitly skips the image signature only. It does not skip the
required SBOM attestation or the Cosign dependency needed for that attestation.
Receipts distinguish skipped signatures from verified ones. SBOM attestations
still require the configured trusted identity and issuer when image signing is
skipped.

## Verification and recovery without rebuilding

```bash
# The digest must be selected independently, not a mutable tag.
dsr docker verify ghcr.io/OWNER/tool@sha256:EXPECTED_DIGEST \
  --platform linux/amd64,linux/arm64 \
  --certificate-identity builder@example.com \
  --certificate-oidc-issuer https://oauth2.sigstore.dev/auth

# Complete attestations for an already-pushed image after a partial failure.
dsr docker attest ghcr.io/OWNER/tool@sha256:EXPECTED_DIGEST \
  --certificate-identity builder@example.com \
  --certificate-oidc-issuer https://oauth2.sigstore.dev/auth
```

`verify` requires Docker/Buildx and Cosign but no source checkout, Syft, builder
setup, build, login, signature publication or attestation upload. It verifies the
root signature and a valid SPDX attestation from the chosen signer for **every**
executable platform in the index. `--platform` additionally constrains the exact
expected platform set; without it, every observed executable child is covered.
`--skip-sign` is an explicit opt-out of root signature verification, not of
attestation verification. Standalone verification accepts any valid matching SPDX
from that signer; release completion additionally binds the freshly scanned
predicates, even when older attestations are present.

`attest` stages and validates all platform scans, submits the child attestations,
and verifies them without rebuilding or changing tags. It does not create or
check the root signature; its receipt says `signature: "not_checked"`. A later
`verify` checks that root signature as well. This is evidence recovery, not a
cached scan resume: scans run again and signature-service prompts may recur.

`sign`, `verify`, and `attest` accept immutable qualified references only. They
do not resolve mutable tags separately between scanning and signing. Global
`dsr --dry-run`, command-local `--dry-run`, and the sourced module's `DRY_RUN=true`
are honored before contacting Docker, scanning, signing, or creating outputs.
The setup command also honors planning before checking or bootstrapping a builder:

```bash
dsr --json --dry-run docker setup
dsr docker setup
```

Setup uses `DOCKER_BUILDER_NAME` without changing the globally selected builder.
Its receipt distinguishes `planned` from completed `ready` status. Standalone
signing returns `signed: true` only after Cosign accepts the operation, and always
reports `verified: false`: signing alone does not perform the independent policy
check available through `verify` and required by `release`.

## Public command receipts

All six public commands use the module's argument parser. `build` and `release`
accept the same source paths, nested Dockerfiles, repeated explicit tags, and
platform selections as the standalone module; OCI `--output` remains build-only.
Missing flag values, unsupported options, extra positional arguments, and mutable
verification/signing references fail with argument error 4. Verification retains
its evidence mismatch code 7 and registry-read code 8.

Without `--json`, stdout is the module's single operation receipt. With `--json`,
`dsr` returns one standard envelope whose `details.result` preserves that entire
receipt. Diagnostics stay on stderr. Overall `status: "success"` means the
requested operation or plan completed; use `details.status` and `details.dry_run`
to distinguish planning from effects. A successful plan has
`details.status: "planned"` and `details.dry_run: true`. It never reports
`pushed: true`, `signed: true`, or `ready: true`.

Completed operations report `built`, `signed`, `ready`, or `verified` in
`details.status`, according to their evidence. Attestation recovery's
`details.result.signature` remains `not_checked`; verification and release report
the independently checked signature result. Failures return a nonzero process
status and a matching error envelope. Completion flags are omitted on failure,
because a failed registry/signing operation may already have partial effects.

`build-json` and `release-json` preserve the operation's nonzero exit status while
emitting a JSON error object. Diagnostics are separate from the structured
`result`. Sourced APIs are `docker_build`, `docker_release`, `docker_sign`,
`docker_attest_sbom`, `docker_verify_release`, `docker_build_json`, and
`docker_release_json`, and `docker_setup`. `docker_command` provides the shared
dispatch used by both `dsr docker` and `bash src/docker.sh`. The standalone
`build-json` and `release-json` convenience wrappers retain their existing module
envelope, including top-level `status: "planned"` for plans. Trust policy
environment variables work with both entry points.

Existing Docker credential configuration remains usable. For GHCR, explicitly
set `DSR_GH_TOKEN`, `GITHUB_TOKEN`, or `GH_TOKEN` (in that precedence order) to log
in before pushing; set `GITHUB_USER` when the local username is not the GitHub
username. Tokens are passed over stdin, never command arguments. Standalone login
can also use the secrets module or `gh auth token --hostname github.com`. A token's
presence alone is not treated as proof of registry authorization.

Individual external effects are not a transaction: a later failure can leave a
pushed image or signature. Nothing is deleted to hide failure. Do not assume
version tags are immutable merely because downstream operations use digests.

## Trust boundaries

Raw index and child manifest bytes are hashed independently. Docker's `.Image`
output is parsed configuration, not original config bytes; the Docker resolver
remains a trusted adapter for configuration/layer retrieval. Cosign remains the
cryptographic verification and Sigstore trust-root implementation, and Syft is
the trusted inventory scanner. DSR verifies their output contracts and the named
subjects; it does not reimplement their cryptography or sandbox a malicious local
process.

SPDX validation is a supported structural contract, not a full standards-schema
validator. Empty package sets are permitted and do not prove exhaustive dependency
detection or absence of vulnerabilities. This workflow does not assert immutable
source provenance, a certified SLSA level, reproducible builds, or security of the
image contents. A signature's selected certificate identity is not itself a policy
decision that the signer should be trusted.

The per-platform `sbom_sha256` hashes the exact scanner file. `predicate_sha256`
hashes the verified predicate serialized as compact, recursively key-sorted JSON
with a trailing newline. It binds the semantic document after Cosign's JSON
encoding, not the original whitespace of the scanner file. These receipts are
local observations, not independently signed release certificates.

## Validation

```bash
bash scripts/tests/test_docker_release.sh
# Only the actual public CLI contract, publication, verification, and recovery cases:
bash scripts/tests/test_docker_release.sh --cli-only
bats tests/unit/test_docker.bats
```

The standalone suite uses real Bash, jq, files, archive bytes, SHA256 and
publication operations with explicit Docker/Syft/Cosign process fixtures. It does
not perform native container builds, registry uploads, OIDC, or cryptographic
verification. Registry manifests in the fixture have real computed content
digests; bad-index, missing-platform, mismatched-config, moved-tag, false-success,
wrong-subject, wrong-predicate, multiple-attestation and interrupted-evidence
cases exercise the real orchestration and validation code. Public CLI cases also
cover both dry-run placements, exact argument forwarding, single truthful JSON
envelopes, read-only verification, and attestation repair followed by independent
verification. The suite additionally validates envelopes against the repository's
JSON Schema when Python's `jsonschema` package is available. Live tool integration
is a separate validation requirement.
