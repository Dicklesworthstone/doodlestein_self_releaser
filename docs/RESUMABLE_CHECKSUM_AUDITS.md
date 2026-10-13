# Resume complete checksum audits

A failed download near the end of a release no longer requires downloading
all earlier verified payloads again. Select a previous audit with
`--resume-from` and a **new** output directory:

```bash
bash src/release_checksums.sh --repo owner/tool --tag v1.2.3 \
  --resume-from /srv/audits/first-attempt --output-dir /srv/audits/retry
```

The auditor reads the current complete release inventory and reacquires every
selected checksum aggregate or sidecar. Only previously verified payloads are
eligible for reuse. Each retained file is checked against the fresh checksum,
size, and available API digest, copied without hardlinks, and checked again.
Unverified partial files are downloaded anew. Altered previously verified files
are errors, not permission to silently replace earlier evidence.

The same release ID, complete inventory, and checksum policy must still match.
Replacing an asset, changing the selected aggregate, switching aggregate/sidecar
mode, or changing metadata inclusion requires a fresh audit. The original
attempt, including failures and partial downloads, is never rewritten. Output
and wrapper workspace paths must not overlap the retained audit directory.

Results distinguish `verified_count` from `resume.reused_count` and retain
`resume.reused_checksums` and `resume.reused_bytes`. Reuse does not bypass the
whole-release byte limits, final inventory check, or final proof/payload hashes.
A completed audit can also be reused, but checksum evidence is still fetched
again. Neither cached nor downloaded checksums authenticate the publisher.

`--preflight` validates local options, paths, dependencies, and retained selection
metadata without downloading or claiming that cached payloads have been checked.
The source directory must contain a valid `selection.json` and either a terminal
`result.json` or the append-only progress journal described below. Older audit
directories without a selection record remain unsupported.

Run `bash scripts/tests/test_release_checksum_resume.sh` for the focused
recovery regression. It executes the production auditor and checksum parser
with owned files and an explicit HTTP acquisition fixture. This is not live
GitHub or publisher-signature qualification.

## Release CLI and downstream synchronization

The regular CLI retains its original manifest and strict-release checks on both
sides of a resumed audit:

```bash
dsr --json release verify tool 1.2.3 --checksums \
  --checksum-resume-from /srv/audits/first-attempt \
  --checksum-output-dir /srv/audits/retry-cli
```

Use the audit directory reported as `details.checksums.evidence_dir`, not the
outer CLI workspace. The `checksums.resume` result records actual reuse.
`--fix` cannot be combined with resume, even under `--dry-run`: repair can
change the pinned inventory. Repair separately, then start a fresh audit.
Ordinary dry-run still checks downloaded bytes but prevents repair writes.

Audited downstream sync accepts the retained selection only with
`--verify-release`:

```bash
bash src/checksum_sync.sh sync tool 1.2.3 --repo owner/tool \
  --target-repo owner/installers --verify-release \
  --audit-resume-from /srv/audits/first-attempt --dry-run --json
```

The complete fresh audit and retained-proof/payload checks must pass before
any downstream clone, commit, issue, or push. Local manifests and artifact
caches cannot substitute for the audit. Removing `--dry-run` creates retained
local commits; pushing still requires explicit `--push`. Cancellation forwards
to owned download processes and cannot turn partial reuse into success.

The focused regression also exercises production command registration and the
CLI/sync handoffs. Its original metadata/repair command and HTTP acquisition are
explicit fixtures; full original-root startup and live release repair are not
qualified by that test. The broader retained validation suite separately tests
real Git operations against isolated local repositories and real curl with a
local TLS server.

## Recovery after forced termination

The auditor appends a bounded record to `verified.jsonl` after each payload's
bytes have passed checksum verification. Its header binds the exact
`selection.json`; each following record identifies the payload, numeric asset
ID, size, and observed SHA256. Appending one record avoids repeatedly rewriting
the full growing report for large release inventories.

When forced termination prevents `result.json` from being written, the same
`--resume-from` option can recover the journal's complete records. The earlier
attempt remains untouched and its terminal outcome is reported as **unknown**:

```json
{
  "source_kind": "progress-journal",
  "source_terminal_outcome": "unknown",
  "source_result_sha256": null,
  "source_progress_sha256": "<actual retained journal hash>",
  "reused_count": 4
}
```

These fields are inside the result's `resume` object. They describe recovery
from progress, not a fabricated successful or gracefully cancelled prior run.
The wrapper commands preserve the same distinction.

A final line lacking its terminating newline is an uncommitted tail, even if
its JSON is otherwise complete. The auditor ignores only that bounded tail and
reports `discarded_tail_bytes`; it does not rewrite the original journal. Any
payload without a complete progress record is downloaded again. Malformed
complete lines, duplicate/out-of-order names, wrong asset IDs or sizes, excluded
metadata, and a header bound to another inventory are errors. A present but
invalid `result.json` is never bypassed in favor of the journal.

Recovery still obtains the fresh complete remote inventory and checksum proof
files, validates every reused source file and independent copy, and rechecks
the original selection/journal before success. A corrupted candidate is refused,
not silently repaired. Without an API digest, the freshly acquired checksum
records still have to match the actual payload bytes.

This covers process termination such as SIGKILL. It is **not a power-loss
filesystem durability guarantee**: incomplete or lost progress records may
reduce reuse or require a fresh audit. It does not authenticate a publisher,
resume partially downloaded byte ranges, or relax the trusted private-storage
boundary. The regression kills the real audit supervisor during the fifth
owned fixture download, then verifies both direct and wrapper recovery with
four reused payloads and no invented terminal receipt.

## Inventory freshness at the CLI handoff

A completed checksum audit proves equality for its observed release inventory.
A later names-only manifest check cannot establish that those same assets still
exist: an asset may have been replaced while retaining its filename. The regular
`dsr release verify ... --checksums` command now holds the completed audit's
SHA256 and rechecks its exact remote selection **after** the final read-only
manifest check, before reporting success. No extra opt-in flag is required.

This applies to fresh and resumed audits, aggregate and sidecar policies, and
verification following an explicitly requested repair. Repair is still invoked
at most once. A checksum or freshness success cannot override a failed original
manifest, source, strict-inventory, or repair gate.

The check compares every asset's numeric ID, name, size and advertised digest,
including excluded checksum/signature/provenance metadata. It also compares the
release ID, tag, draft/prerelease mode and target declaration. It reads the entire
paginated inventory twice, bracketed by release-context observations, using the
same bounded HTTPS/authentication path as the checksum auditor. An API failure,
malformed/truncated page, replacement, or inconsistent observation fails closed.
It does **not** redownload payloads or checksum proofs. With one inventory page,
this adds four metadata requests, not a second binary download pass.

The CLI then rechecks the retained checksum proofs, normalized records, and all
local payload hashes. Changing a local file or replacing the original audit
receipt during the handoff cannot be repaired by a matching remote filename.
The original audit remains untouched; the separate inventory observation is
retained under the outer verification workspace's `inventory-after/` directory.

`details.checksums.inventory_check` contains the separate freshness receipt.
`audit_inventory_stable` preserves the original auditor's observation, while
`inventory_stable` is true only after current inventory and local-evidence
admission both finish. If the original audit passed but current freshness fails
or remains unknown, checksum status is `stale-or-unconfirmed` (or `not-admitted`
when local admission fails), and the process returns nonzero. Historical verified
counts remain available for diagnosis; they do not make the current result green.

### Standalone inventory-only observation

A caller already holding and admitting a completed audit can request only the
metadata freshness observation:

```bash
bash src/release_checksums.sh --repo owner/tool --tag v1.2.3 \
  --release-id 42 --checksum-mode sidecars \
  --recheck-from /srv/audits/completed \
  --audit-sha256 "$PREVIOUSLY_HELD_RESULT_SHA256" \
  --output-dir /srv/audits/inventory-recheck
```

The pin is the independently retained SHA256 of the original `result.json`, not
its `selection_sha256`. Select the original checksum mode, exact aggregate when
applicable, and metadata-inclusion policy. `--recheck-from` and `--audit-sha256`
are required together and cannot be combined with `--resume-from`. The output
must be a new directory outside the prior audit. `--preflight` checks the local
selection and options without network access or persistent output.

A successful result has kind `dsr-release-checksum-inventory-check`, status
`unchanged`, and `payloads_reverified: false`. It is intentionally **not** a
`dsr-release-checksum-verification` receipt and cannot substitute for original
payload/evidence admission. It requires a pinned complete successful terminal
audit; a partial result or an unfinished progress journal is not eligible.
Original files are not changed, and a failure to persist the new result returns
nonzero. Cancellation terminates the owned acquisition process.

These are observations, not a transaction with GitHub: a later external writer
can still change a release after the last check. The original trusted-local-
storage boundary applies. Neither inventory equality nor downloaded checksums
authenticate a publisher, resolve source provenance, or certify a native build.
The automatic final-handoff gate is specific to release verification; it does
not silently change downstream synchronization or publication policies.

Run both paths of the focused regression:

```bash
bash scripts/tests/test_release_checksum_freshness.sh
bash scripts/tests/test_release_checksum_freshness.sh --cli
```

The first exercises the production auditor with actual payload/proof bytes,
retained state, two-page inventories and owned process cancellation. The second
also exercises the production CLI supervisor and shared checksum-admission
functions, including same-name changes after the first audit, failed manifest
gates, repair ordering, resume, local corruption and cancellation. HTTP and the
legacy manifest/repair command are explicit file-backed fixtures; these tests do
not establish live GitHub/curl behavior or full original `dsr` startup. Set
`DSR_TEST_VERIFY_MODULE` to an unchanged supervisor to run the same counterexamples
against the incumbent rather than weakening the corrected expectations.
