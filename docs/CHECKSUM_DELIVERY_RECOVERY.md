# Recover an acknowledged checksum commit

The `--result` mode of `checksum_sync_recover.sh` recovers the delivery of **one existing, acknowledged
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
are bounded to 64 MiB. Per-target receipts alone are not sufficient authorization
for recovery. A separately pinned full sync plan can bind them for the explicit
`--plan` continuation described below, without inventing a terminal result.

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

## Plans and interruption checkpoints

Every audited sync now publishes `WORKSPACE/sync-plan.json` before the first
downstream destination is attempted. The plan records the complete ordered,
case-deduplicated destination list, checksum-file path, source repository/tag,
push/review/dry-run policy, audit options, and SHA256 pins for the admitted
audit and checksum export. The exact plan path and digest are logged before
execution and retained under `sync_plan` in the terminal result. Keep that
independently selected digest when retaining a plan for later recovery.

Before starting a destination, sync publishes `target-N.intent.json`, bound to
the plan digest, target index, and repository. It saves `target-N.result.json`
after the destination finishes, including a before-target freshness refusal.
An intent without a complete result means the outcome is **unknown**, not
that a push failed or did not happen. Missing intent and outcome records mean
that the destination was not attempted under this plan. None of these records
fabricates a terminal `result.json` for a process killed by SIGKILL.

A private `.sync.lock` is held throughout the audited invocation, including
terminal-result persistence. Its kernel lock is released only after all owners
of the inherited open-file description exit; do not delete the file to recover
it. This lets a resumer distinguish retained evidence from an active sync even
when the original parent dies before one of its owned processes exits. These
are POSIX process-recovery controls, not a power-loss durability promise or a
sandbox against an arbitrary writer with access to the private workspace.

Run `bash scripts/tests/test_checksum_sync_plan.sh` for genuine local Git
fan-out, refused plan/intent publication, and forced-termination coverage. The
HTTP/authentication boundary is explicitly file-backed. Its controlled pause
occurs after the actual receipt publisher succeeds; the production admission
and publication predicates are unchanged.

## Continue an interrupted multi-repository synchronization

Plan-based recovery can reconcile the entire destination list and explicitly
continue the work that has a safe recorded outcome. It requires a plan produced
by the current audited sync, its independently retained SHA256, and a new output
directory outside the original workspace. Existing older results remain usable
with single-commit `--result` recovery; absence of a plan is not permission to
reconstruct one from the current repository configuration.

```bash
# Inspect current remote state and the remaining work. No clone, commit or push.
bash src/checksum_sync.sh recover \
  --plan "$SYNC_WORKSPACE/sync-plan.json" \
  --plan-sha256 "$REVIEWED_PLAN_SHA256" \
  --output-dir /srv/recovery/fanout-check

# Continue the plan that originally selected --push.
bash src/checksum_sync.sh recover \
  --plan "$SYNC_WORKSPACE/sync-plan.json" \
  --plan-sha256 "$REVIEWED_PLAN_SHA256" \
  --output-dir /srv/recovery/fanout-execute \
  --execute --push
```

For an originally local-only plan, use `--execute` without `--push`. Execution
must retain the original push policy; a local-only plan cannot be escalated by
adding `--push`. Review-issue and dry-run plans are not executable plans and are
refused. The plan format is versioned and closed, with at most 256 unique
repository destinations, validated relative checksum paths (including spaces),
and a fixed allowlist of checksum policy and acquisition-limit options.

The original `.sync.lock` must still exist and be available. Recovery holds it
through its final receipt, and passes the held descriptor to owned children.
Single-commit recovery also honors this lock when present. Removing the lock
cannot admit a plan, and an original sync or surviving owned process prevents
concurrent continuation. An arbitrary numeric inherited descriptor is checked
against the actual lock file before it can transfer that authority.

Before any continuation writes, the command validates all plan-bound intents
and target results, the original terminal result when one exists, the complete
retained audit and local payload bytes, and fresh remote release observations.
It also checks every already-created checksum commit against its real local
checkout and remote branch through the existing single-commit recovery engine.
Missing, malformed or contradictory evidence is not treated as empty state.

The selected work is handled as follows:

- An acknowledged checksum commit is reconciled, and optionally pushed as the
  **same exact commit** under the existing parent/branch/freshness rules. It is
  not cloned or committed again. An unchanged-checksum row can be reconciled
  without creating a commit; this case never authorizes another push.
- A destination with neither an intent nor any target evidence was not started
  under the plan. A complete recorded `before-target` freshness refusal also
  establishes that no downstream action began. Those destinations may be
  continued together in one new audited sync.
- An intent with no complete result is **unknown**, even when a remote push may
  actually have succeeded. Failed clone, uncertain commit and other unsupported
  partial states stop automatic continuation. Preserve the files and reconcile
  them explicitly; do not delete a record to make that destination look new.

All existing destinations are checked before a new one is executed. An actual
SIGKILL can leave no original `result.json`; the returned
`original_terminal_outcome` is then `unknown`. A derived `selection.json` is
explicitly labelled `dsr-checksum-sync-checkpoint-selection` with
`status: checkpointed` and `exit_code: null`. It is **not** a fabricated terminal
result. The single-commit engine independently binds its rows back to the fixed
original intent/result files and the selected plan digest.

### One-time delegation of remaining destinations

Before starting the new sync, recovery atomically publishes
`WORKSPACE/continuation.json` without overwriting any existing file. This records
the plan digest, remaining destinations, push policy and the new attempt's output
location. It is a claim of work, not a claim of successful delivery. An occupied
or invalid delegation record blocks execution.

The new sync uses the original audit as its `--audit-resume-from` source. It
reacquires and checks checksum proof files, rehashes/copies the prior verified
payloads, and enforces the same complete release inventory. It does not download
those already-verified payloads again. It creates its own workspace beneath
`OUTPUT/pending/`, with its own plan, intents, target results and terminal result.
The original checkouts, proof files, plan and outcome receipts are preserved.
Only the lock and one-time delegation metadata are added to the original root.

The parent retains the actual child result and its digest. It independently
reconciles each newly completed destination afterward and rechecks the original
completed destinations, so an earlier observation is not carried forward through
a later repository update. Any detected branch, evidence or release drift makes
the aggregate result nonzero without claiming rollback of completed work.

**Repeating the original plan never launches its delegated destinations again.**
It returns the existing delegation location with a nonzero result. Inspect the
attempt and recover the child sync's own plan instead. This remains true when a
parent was killed after delegation but before receiving a child result. A claim
with no child plan may require manual inspection; there is no automatic claim
expiry or unsafe retry that guesses whether a process performed an effect.

A read-only result can be `ready` with `delivery_confirmed: false`. Successful
executed push plans report `completed`; local-only completion reports
`completed-local` and does not claim remote delivery. Per-target observations
and the complete delegated result remain available after an aggregate failure.
`--timeout` bounds each child operation, including a complete delegated sync;
timeout/interruption is non-success and retains the delegation for inspection.

This is explicit, conservative continuation, not an automatically retried
exactly-once queue, a transaction across GitHub and all downstream repositories,
or a power-loss durability guarantee. The trusted local-storage and operator
Git URL-policy boundaries of the original sync and recovery engines still apply.
Native builds, installer consumers and releases themselves are not modified.

Run `bash scripts/tests/test_checksum_sync_plan.sh --resume` for plan continuation
using real local Git repositories, accepted/rejected pushes and forced process
termination. HTTP/authentication uses an explicit file-backed fixture. The
regression checks preservation, payload reuse, policy refusal, corruption,
unknown outcomes and cancellation without claiming live GitHub qualification.
