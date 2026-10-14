# Resume complete checksum audits

A failed download near the end of a release no longer requires downloading
all earlier verified payloads again. Select a previous audit with
`--resume-from` and a **new** output directory:

```bash
bash src/release_checksums.sh --repo owner/tool --tag v1.2.3 \
  --resume-from /srv/audits/first-attempt --output-dir /srv/audits/retry
```

The auditor reads the current complete release inventory and reacquires every
selected checksum aggregate or sidecar. Previously verified files and complete
downloads that never reached a checkpoint are checked against fresh checksums,
size, and available API digests, copied without hardlinks, and checked again.
Partial downloads can continue from their retained byte offset as described
below. Altered complete files are errors, not permission to silently replace
earlier evidence. No retained bytes are trusted merely because they exist.

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

## Recover interrupted payload transfers

The same `--resume-from` option handles three distinct cases. Previously verified
payloads contribute to `resume.reused_count`; complete but uncheckpointed files
contribute to `resume.recovered_count`, `recovered_checksums`, and
`recovered_bytes` only after a fresh full-file check. This recovers a transfer
whose bytes finished arriving before a connection error or a killed supervisor
could record success, without downloading that payload again.

A nonempty shorter file is copied to the new audit directory, then continued
with an HTTP byte range. The prior audit is never opened for writing. A valid
continuation requires HTTP 206 and exactly one `Content-Range` naming the
expected start, final byte, and complete size. Encoded, ambiguous, incorrect,
or excessive responses are refused. The received suffix has its own remaining-
byte limit; the full reconstructed file must still match the freshly acquired
checksum, exact size, and any API digest before it enters `verified.jsonl`.

When a server ignores the range and curl refuses before changing the copied
prefix, the auditor preserves that prefix under `requests/` and restarts once
into a new payload file. This is not fallback after a checksum or range-identity
failure. Missing or empty retained files use the normal full download. Linked,
special, oversized, or changing retained candidates are refused.

`resume.partial_transfers` records the payload name, selected offset, prefix
SHA256, transfer outcome (`pending`, `continued`, or `restarted`), and whether
the completed bytes passed verification. `continued_count` counts completed
range continuations, and `continued_bytes` counts their reused prefix bytes,
not downloaded suffix bytes. `restarted_count` counts verified full restarts.
These counters do not override a later final inventory or evidence failure.

A second connection failure or forced termination leaves the growing payload
in the new attempt's `artifacts/` directory. Resume from that newer directory
to continue from its larger offset; retain the earlier directories as evidence.
No new completion is recorded until the entire reconstructed payload passes.
Malformed terminal receipts still fail rather than falling back to journals.

Run `bash scripts/tests/test_release_checksum_download_recovery.sh` for the
download recovery regression. It uses genuine curl, OpenSSL TLS, actual files,
and process signals against a loopback GitHub/CDN service fixture, including
cross-origin credential stripping, ignored ranges, corrupt prefixes/suffixes,
invalid ranges, repeated interruption, and final inventory drift. It does not
qualify live GitHub releases, native builds, or publisher signatures.

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
reports `discarded_tail_bytes`; it does not rewrite the original journal. A
payload without a complete progress record remains unverified: a complete file
can be freshly checked, or a partial file continued as described above. Malformed
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
reduce reuse or require a fresh audit. It does not authenticate a publisher or
relax the trusted private-storage boundary. The original journal regression
kills the real audit supervisor during the fifth
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

## Guard audited downstream writes

`checksum_sync ... --verify-release` now applies the same pinned inventory
recheck to downstream synchronization, not just the release verification CLI.
No extra opt-in is needed:

```bash
bash src/checksum_sync.sh sync tool 1.2.3 --repo owner/tool \
  --verify-release --checksum-mode sidecars \
  --target-repo owner/installers --target-repo owner/checksums --push --json
```

After the full audit and local payload handoff, synchronization checks the exact
release context and complete remote asset inventory before each destination,
immediately before replacing its checksum file, before committing, before
pushing, and after that destination completes. Review-issue delivery is checked
before its request and afterward. An unchanged local-commit retry still checks
before pushing. All rechecks pin the newly completed audit, including when that
audit reused payloads from `--audit-resume-from`; the old resume source is never
mistaken for the current audit.

Same-name payload replacement, changed sidecar/signature IDs, size/digest drift,
changed release mode, failed reads, and changed retained checksum proofs or
exports stop the audited fan-out. A failure during clone or another downstream
operation also stops later audited destinations. The unaudited local-manifest
and local-artifact routes retain their previous behavior and do not acquire a
remote freshness guarantee.

These checks do not download payloads or checksum files again, or rehash all
large local payloads once per Git operation. The initial full audit already did
that work. Each later gate hashes the selected audit, checksum proofs and export,
binds the actual staged checksum manifest when writing a repository, and uses
the auditor's inventory-only mode. A one-page inventory requires four metadata
reads per gate; more pages add inventory requests. The configured audit time
limits still apply to each acquisition. This is additional network work, not a
performance-speedup claim.

The original `release_verification` remains the historical full-audit receipt.
`release_verification_sha256` pins that receipt, while `release_freshness`
separately reports the current handoff result, `inventory_stable`, and the ordered
per-boundary checks with their retained evidence directories. A failed or
interrupted handoff is `stale-or-unconfirmed`, never a fresh success merely
because the historical audit was green. If the historical receipt itself was
changed, it is not embedded as trusted evidence in the final result.

A block after a successful local commit retains the checkout, commit SHA,
`committed: true`, `pushed: false`, and `blocked_phase: before-push`. A change
observed after a completed push or review issue returns nonzero **partial**
status while retaining the already-completed effect in the per-target result.
No commit is discarded, no branch is reset, no push is forced, and no release,
asset or issue is removed. Inspect retained partial work before retrying; this
is not an outbox or exactly-once delivery facility, and an ordinary new invocation
may repeat an earlier successful issue request.

Remote reads and a subsequent Git/HTTP write cannot form an atomic transaction.
A change inside a Git hook or during transport may be detected only by the next
gate; already-completed writes are not rolled back. The trusted private-storage
and unauthenticated-checksum boundaries remain unchanged. Cancellation of the
public sync process is forwarded to its owned inventory-recheck transport.

Run `bash scripts/tests/test_checksum_sync_freshness.sh` for the complete sync
module and auditor regression. It uses genuine Git cloning, commits and pushes
to new, retained local bare repositories. Git hooks change a file-backed release
inventory during actual Git stages. Only GitHub HTTP/authentication and issue
creation are transport fixtures. It is not live GitHub, full root-CLI startup,
native build, or publisher-signature qualification.

### Preserve outcomes after Git failures

Each admitted repository update now reports its known local effects even when
file preparation, commit, push, or a release guard fails. A failed Git command
does not discard the checkout or turn an already-created commit into an empty
result. The outer sync reports `partial` when a checksum file was changed or a
commit/push was acknowledged, and stops later audited destinations.

The per-target receipt includes `previous_commit`, the selected `commit`,
`commit_attempted`, `commit_outcome`, `commit_exit_code`, `push_attempted`,
`push_outcome`, and `push_exit_code`. Outcomes are `not-attempted`, `acknowledged`,
or `uncertain`. `committed` and `pushed` are true for acknowledged commands,
false when the command was not attempted, and null for an unacknowledged attempt.
On an unsuccessful commit command, `commit` is null rather than presenting the
old HEAD as the newly created commit. `previous_commit` still identifies the
original checkout. An unchanged retry can report `committed: false` while naming
and pushing a commit retained from an earlier invocation.

A nonzero push, including a rejected push, is conservatively `uncertain`: its
exit status alone does not prove that no configured destination was updated.
There is no automatic retry or rollback. Inspect the retained checkout/logs and
remote refs before deciding whether to retry. A failed push retains the exact
acknowledged local commit SHA. Loss of the process itself before it writes a
receipt is not covered by this reporting contract; this is not a durable outbox.

Before pushing, the updater rechecks that HEAD and the branch still match the
commit it validated. It sends that explicit commit SHA rather than a moving
HEAD ref, and disables automatic `push.followTags` publication so the checksum
update cannot implicitly send unselected annotated tags. A concurrent local
change is a conflict, not permission to discard either commit. A later
freshness failure keeps the downstream effect but owns the final per-target
nonzero exit code; a helper's earlier successful receipt cannot overwrite it.

The freshness regression includes real server-side Git rejection, a failing
commit hook, an explicit unchanged-checkout retry, concurrent local commits,
and annotated-tag policy. Its lost-acknowledgement case performs a genuine
push to a local bare repository, then injects a nonzero process response. That
is an explicit process-status fault adapter, not a live Git protocol/network
qualification. No production Git predicate is replaced in these checks.
