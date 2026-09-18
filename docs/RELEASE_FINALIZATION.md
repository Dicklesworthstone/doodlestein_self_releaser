# Verified release finalization

`src/release_finalize.sh` connects the existing local SBOM inventory, GitHub
metadata publisher, remote verifier, draft publication and persistent downstream
handoff into one recoverable operation. Release payloads must already be uploaded
to an existing release and
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

This regression suite uses the production finalizer and dispatch outbox with real
JSON, hashing, files, atomic state operations, locks and concurrent processes.
It covers partial recovery, uncertain acknowledgements, evidence changes between
destinations and rate-limit retries, and changes after persisted sending intent.
SBOM library calls and GitHub transport are
explicit file-backed fixtures. It does not exercise a live registry, real Syft,
GitHub authentication or native macOS/Windows operation.
