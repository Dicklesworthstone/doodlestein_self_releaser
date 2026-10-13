# Recover an acknowledged checksum commit

`checksum_sync_recover.sh` recovers the delivery of **one existing, acknowledged
local checksum commit** from an audited synchronization result. It does not
start a new synchronization, clone a destination, create a commit, move a branch,
repair a checkout, or replay a review issue. It is useful when a push failed,
its acknowledgement was lost, or the original operation deliberately retained
local commits without pushing them.

Every handled sync completion now retains `WORKSPACE/result.json`, including
non-JSON invocations and failures. The path and SHA256 are printed to stderr;
JSON also identifies `result_file`. Select that original result and its
independently held digest, not a later recovery receipt. Captured older sync JSON
with complete acknowledged-commit and audit evidence is also accepted.

```bash
sha256sum < "$SYNC_WORKSPACE/result.json"

# Reconcile only: network reads, local logs and a local lock, no remote writes.
bash src/checksum_sync.sh recover \
  --result "$SYNC_WORKSPACE/result.json" \
  --result-sha256 "$REVIEWED_RESULT_SHA256" \
  --target-repo owner/installers \
  --output-dir /srv/recovery/check-1

# Explicitly permit one push of the already-validated checksum commit.
bash src/checksum_sync.sh recover \
  --result "$SYNC_WORKSPACE/result.json" \
  --result-sha256 "$REVIEWED_RESULT_SHA256" \
  --target-repo owner/installers \
  --output-dir /srv/recovery/push-1 \
  --push
```

Every invocation requires a new output directory with an existing parent,
outside the original sync workspace and result-file ancestry. The original
checkout, audit, payloads, export and result must remain available. Inputs and
output ancestry must be canonical, absolute and free of symlinks. Protected
project roots retain the checksum-sync prohibition. Generation/build hosts and
release assets are not modified. Python 3 on POSIX, Bash, Git, jq and the existing
bounded auditor transport are required. `--timeout` bounds each subprocess;
it does not change release policy or grant a retry.

Sync itself now requires Python 3 before any downstream effects, including
unaudited sync, to retain complete recovery results. The persistence helper
writes a private candidate and atomically creates the final name with a hardlink;
it never replaces an existing result. Candidates remain for diagnosis. Each
completed destination also retains `target-N.result.json` before the next one
starts. Failed persistence returns nonzero and stops later destinations; losing
stdout no longer discards an otherwise saved terminal result. These receipts
are bounded to 64 MiB. Per-target receipts without a terminal sync result are
diagnostics, not sufficient authorization for automatic recovery.

## What qualifies for recovery

The selected row must identify an acknowledged local commit, its previous
commit, branch, checksum path and DSR-owned `target-N` checkout. Unknown commit
outcomes, failed clones, uncommitted updates, unaudited inputs, planning results,
review issues and targets absent from the result are refused rather than guessed.
A digest selected from an untrusted replacement result is not an independent pin.
The caller remains responsible for selecting the original result they trust.

The actual checkout must still have that exact HEAD and symbolic branch, no
tracked edits, and a regular checksum file equal to the audited export. The
commit must have exactly the recorded parent and change **only** that checksum
file. Recovery accepts the existing HTTPS GitHub origin created by sync, with
one URL and no separate push URL. Existing operator credential helpers and URL
rewrites remain policy; effective URL changes observed during recovery fail.
HTTPS, SSH and local/file URL rewrites are supported; option-like strings and
arbitrary remote-helper transports are refused. Safe nested checksum paths,
including spaces, preserve the original sync path grammar.
URLs potentially containing credentials are not included in public result JSON.

The complete original audit, its selection and checksum evidence are verified
through the production auditor/shared admission functions. Retained payloads are
rehashed locally before delivery. Full remote release inventories are rechecked
before reconciliation, immediately before a permitted push, and afterward.
This makes **no additional release-payload or checksum-sidecar downloads**.
Historical verification is not converted into publisher authentication.

## Outcomes

- `ready`: the remote still equals the recorded parent; no push was requested.
- `already-applied`: the remote already equals the selected checksum commit;
  no push occurs even when `--push` was supplied.
- `pushed`: the one permitted push was acknowledged and the selected remote
  commit and release inventory were independently confirmed afterward.
- `reconciled`: the push returned nonzero but independent reads confirm the
  selected commit now exists at the exact destination branch. The receipt keeps
  `push_outcome: uncertain` and its nonzero `push_exit_code` instead of rewriting
  the observed process response as success.
- `error`: local evidence, remote state, freshness, transport or persistence
  could not satisfy the contract. Inspect `push_attempted`, `push_outcome`, the
  original commit and logs; a nonzero result never implies remote rollback.

Only the confirmed delivery outcomes set `delivery_confirmed: true`. A `ready`
result exits zero but explicitly states that delivery has not happened. A remote
branch at any third commit is a conflict; recovery does not infer ancestry,
fetch new objects, merge, reset, force-push, or recreate a missing branch.

An actual push uses the held SHA and branch, never a moving HEAD, and disables
implicit tag following and mirror behavior. A rejected/uncertain push is not
retried within the invocation. Repeat the explicit command into a new output
directory only after inspecting the evidence. A previously accepted push then
becomes `already-applied`, avoiding a duplicate commit or repeat push.

## Evidence and interruption

Each attempt retains the original input result, numbered stdout/stderr logs,
separate inventory-check receipts and `result.json`. Before a push, it also
retains `push-intent.json` with the selected SHA, destination and expected parent.
Original evidence and previous attempts are never overwritten. The original
workspace receives a persistent per-checkout `.recovery-target-N.lock`; kernel
locking serializes cooperating recovery processes and releases on exit. Do not
remove that file to recover a cancelled process.

Cancellation forwards TERM through the auditor so its separately grouped
transport is stopped, then escalates against owned processes when necessary.
An interrupted attempt can have an unknown delivery outcome. A new invocation
reconciles the original result against current state, rather than treating an
incomplete attempt log as success or authorization.

These are bounded observations on trusted local storage, not a durable outbox,
exactly-once protocol, hostile-host sandbox or power-loss filesystem guarantee.
Normal non-forced Git push protects against non-fast-forward updates, but the
release reads, remote branch reads and push are not one distributed transaction.
A concurrent writer may change state after an observation. Detected changes
stop recovery without pretending to undo an acknowledged external effect.

## Regression

```bash
bash scripts/tests/test_checksum_sync_recovery.sh
bash scripts/tests/test_checksum_sync_result.sh
```

The regression obtains its original result from the complete production audited
sync and uses real local Git repositories, commits, annotated tags, remote reads,
pushes and receive hooks. GitHub HTTP/authentication is an explicit fixture.
A lost-acknowledgement adapter executes a genuine successful local push and then
substitutes a nonzero process response; it is not a live Git protocol fault.
The tests preserve original files and failed-attempt evidence. They do not
qualify live GitHub delivery, full DSR startup or native compilation.
