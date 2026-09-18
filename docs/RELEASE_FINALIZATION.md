# Verified release finalization

`src/release_finalize.sh` connects the existing local SBOM inventory, GitHub
metadata publisher, remote verifier and draft publication into one recoverable
operation. Release payloads must already be uploaded to an existing release and
its tag must already exist. It does not build or upload binaries.

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
It composes the existing library APIs rather than replacing payload publication.
A complete local inventory requires Syft only when scans are missing. Runtime
requirements include Bash 4+, jq, SHA256 tooling, `flock`, and the existing GitHub
transport dependencies. Publishing a draft requires the GitHub CLI (`gh`).

The evidence establishes equality with the selected inventory, not cryptographic
signature validity, scanner completeness, freedom from vulnerabilities, or build
provenance. Do the required signing/provenance checks separately. A published
release can remain published even when a later check fails; the finalizer never
deletes assets, rolls back the release, or conceals a partial external outcome.

```bash
bash scripts/tests/test_release_finalize.sh
```

This regression suite uses real JSON, hashing, files, atomic state operations,
locks and concurrent processes. SBOM library calls and GitHub transport are
explicit file-backed fixtures. It does not exercise a live registry, real Syft,
GitHub authentication or native macOS/Windows operation.
