# Resumable downstream release dispatch

`src/dispatch.sh` implements the handoff from a completed release to downstream
checksum, package-formula, and canary workflows (bead `bd-1jt.3.7`). The release
API now persists a local outbox rather than forgetting delivery results every
process invocation. The public `dsr release --dispatch` command uses the same
outbox engine after its publication checks succeed.

## Public release command

```bash
dsr release ntm 1.2.3 --dispatch --dispatch-repos owner/checksums,owner/formulas
```

The release command retains its `dsr_release` default event; select another with
`--dispatch-event NAME`. It preserves the `tool`, `version`, `tag`, `repo`, `sha`,
`run_id`, and `release_url` payload fields, and adds `source_repo` and
`delivery_id`. `version` omits the leading `v`, `tag` retains it, and `run_id` is
`release-<GitHub-release-ID>`. A verified source commit is required; an unresolved
commit never becomes an `unknown` source assertion.

The outbox namespace is the normalized source repository plus its GitHub release
ID. A different process ID or version spelling cannot start another delivery.
Changed events, destinations, source commits, tool aliases, or release evidence
conflict with the saved plan. An intentionally replaced release has a new ID.
Repository and global `dispatch.enabled: false` settings suppress delivery even
when destinations are configured; command-line and environment overrides retain
their precedence.

The saved plan binds the published release ID, tag commit, URL, prerelease mode,
and complete paginated asset inventory. Before each POST, including a rate-limit
retry, DSR rechecks that the release is still public and that its tag and assets
have not changed. Assets without a GitHub digest are downloaded by asset ID and
hashed again. Dispatch cannot turn a failed publication or an explicitly
retained draft into a downstream event.

Publication and delivery have separate outcomes: a successful release remains
successful when downstream delivery is incomplete. JSON reports
`details.dispatch.status`, `exit_code`, `outbox_file`, and per-destination
`results`. HTTP acceptance does not establish that a downstream workflow ran.

Recover the saved handoff directly, including after a strict release has already
been published:

```bash
dsr release dispatch --outbox /absolute/path/to/dispatch/RELEASE_KEY/state.json --status
dsr release dispatch --outbox /absolute/path/to/dispatch/RELEASE_KEY/state.json
dsr release dispatch --outbox /absolute/path/to/dispatch/RELEASE_KEY/state.json --retry-uncertain
```

Use the exact path returned in release JSON or diagnostics. Recovery needs no
local build artifacts and does not reread destination configuration, upload
assets, or publish the release again. It validates the saved request hashes,
delivery identities, history, private file ownership and canonical location,
then retries only eligible unfinished deliveries after the public-release gate.
Missing or corrupt state cannot be replaced with a fresh fan-out. Already
accepted destinations remain untouched.

`--status` is an offline, read-only inspection and returns the saved delivery
status, including nonzero for incomplete work. `--dry-run` is also offline and
read-only, returning a labeled preview with exit zero; it does not qualify the
current remote release. Ordinary recovery leaves uncertain deliveries alone.
After checking the receiver, use `--retry-uncertain` to authorize an exact-byte
resend, which can duplicate a previously accepted event. The original release
command also accepts `--dispatch-retry-uncertain` when resuming publication.

## Release fan-out

The standalone module can also receive an explicitly supplied source identity:

```bash
bash src/dispatch.sh release ntm v1.2.3 \
  --repo-path /path/to/ntm \
  --source-repo Dicklesworthstone/ntm \
  --repos owner/checksums,owner/formulas,owner/canaries
```

`--repo-path` resolves the exact `refs/tags/v1.2.3^{commit}`, including annotated
tags. It does not use the checkout's current HEAD. Alternatively, pass a full
40- or 64-character lowercase commit ID with `--sha`. With both options, the
explicit SHA must match the tag. The source checkout and supplied identity are
trusted operator inputs, not independent proof that a GitHub release exists or
that its artifacts were verified.

`--source-repo` identifies the release's owning repository, independently of the
downstream destinations. Without it, the sourced `act_get_repo` configuration
resolver is used when available, otherwise the default is
`Dicklesworthstone/<tool>`. Omitted `--repos` self-dispatches to that source repo.
Repository names are normalized case-insensitively and duplicate destinations are
coalesced. The complete destination list is validated before the first request.

A release event defaults to `event_type: dsr-release`. Use `--event NAME` to
select a receiver's event type; that event is retained in the request plan,
delivery receipts, and every retry. Changing it for an existing outbox is a
plan conflict. The default payload includes:

```json
{
  "tool": "ntm",
  "version": "v1.2.3",
  "sha": "1111111111111111111111111111111111111111",
  "run_id": "ntm-v1.2.3",
  "source_repo": "dicklesworthstone/ntm",
  "delivery_id": "<destination-specific SHA256 identity>"
}
```

Every retry uses the exact saved request bytes and the same `delivery_id`.
Receivers should validate the source and commit and persistently deduplicate
this ID before doing non-idempotent work. A workflow concurrency group alone
serializes execution; it is not persistent deduplication.

The default invocation ID is `<tool>-<normalized-version>`. Changing a commit or
adding/removing a destination conflicts with the saved plan for that invocation,
rather than silently redefining unfinished work. `--run-id` deliberately creates
a different invocation; using a new ID can repeat downstream effects.

## Recovery and inspection

Rerun the same release command after a partial failure. Already acknowledged
repositories are skipped. Definitively rejected destinations can be retried;
rate-limited destinations wait until their recorded deadline. A complete retry
needs neither credentials nor network requests and preserves the state bytes.

Use the same arguments plus `--status` for read-only inspection. An incomplete
outbox returns nonzero even when inspection itself succeeds. Inspecting a missing
outbox does not create one.

If the POST times out, returns a server error, or has an unrecognized response,
the result is **uncertain**: the receiver may already have been triggered. A
process killed after saving its sending intent is treated the same way. Ordinary
retries leave that destination alone while still processing other pending work.
After checking the receiver and its deduplication policy, an operator can select
`--retry-uncertain` to resend only the uncertain work. The explicit decision is
recorded in attempt history. This option can cause duplicate downstream effects;
it does not make the GitHub dispatch endpoint exactly-once.

State lives under `DISPATCH_STATE_DIR`, otherwise
`${DSR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/dsr}/dispatch`. An explicit
`--state-dir` overrides that root. Each invocation has a digest-named directory
containing `state.json` and an advisory lock file. The state binds the source,
complete request plan, request hashes, and each target's attempt history.

Persistent sends require `flock`, jq, and SHA256 tooling (`sha256sum` or `shasum`).
The lock is released by the kernel on process exit, including a crash. It is kept
open in transport children so another sender cannot start while an orphaned POST
is still active. State is published by same-filesystem atomic replacement; intent
is saved before the POST, and its acknowledgement is saved afterward. If saving
an acknowledgement fails, the retained sending state prevents blind replay.

The state directory is trusted local storage. These records are not authenticated
against a malicious local writer. Deleting, rolling back, or relocating state can
remove the information needed to prevent duplicates. Atomic publication is not a
promise of power-loss durability or a transaction with GitHub. A corrupt state,
linked state file, mismatched plan, or observed concurrent state modification is
an error, not a reason to regenerate the outbox silently.

## Transport behavior

Only HTTP **204** is an acknowledgement. It means GitHub accepted the dispatch,
not that a workflow was present, started, completed, or updated a downstream repo.
Authentication and validation rejections are returned directly. Lost responses,
5xx responses, and unexpected response codes are not automatically replayed.
Redirects are not followed automatically; use the canonical destination repo.

Explicit rate-limit responses can be retried with bounded backoff. Numeric
`Retry-After` and `X-RateLimit-Reset` deadlines are respected; a wait exceeding the
configured budget returns instead of retrying early. The deadline survives a
release process restart. Unrecognized delay formats are not guessed: such a
persisted rate-limited outcome remains blocked for operator reconciliation.

Settings (all validated before requests):

| Variable | Default | Meaning |
| --- | --- | --- |
| `DISPATCH_MAX_RETRIES` | `3` | Total attempts per transport invocation, from 1 to 10. |
| `DISPATCH_RETRY_DELAY` | `5` | Base backoff in seconds, from 0 to 60. |
| `DISPATCH_MAX_WAIT` | `120` | Maximum individual retry wait, from 0 to 3600 seconds. |
| `DISPATCH_TIMEOUT` | `30` | Curl request deadline, from 1 to 600 seconds. |
| `DISPATCH_PARALLELISM` | `4` | Maximum workers for explicit generic batch `--parallel`, from 1 to 32. |

Release outbox sends are serial. Generic batch concurrency is opt-in. The token
cascade is `DSR_GH_TOKEN`, `GITHUB_TOKEN`, `GH_TOKEN`, then the configured secrets
helper or `gh auth token --hostname github.com`. Explicit tokens are never
replaced by a different authenticated `gh` account. Requests are pinned to
`api.github.com`; curl configuration files, redirects, and implicit curl retries
are disabled. Credentials are passed through stdin configuration, not argv.
Response and transport-error bodies are not copied into diagnostics because an
upstream server can echo credentials or sensitive payload data.

## API and structured output

The sourced APIs are `dispatch_event`, `dispatch_batch`, `dispatch_release`, and
`dispatch_release_json`. Standalone commands are `event`, `batch`, `release`, and
`json`. For example:

```bash
bash src/dispatch.sh json ntm v1.2.3 --repo-path /path/to/ntm \
  --repos owner/checksums,owner/formulas --status
bash src/dispatch.sh event owner/repo custom-event --payload '{"key":"value"}'
bash src/dispatch.sh batch custom-event --repos owner/a,owner/b --parallel
```

Generic event/batch calls do not use the persistent release outbox. Their JSON
results classify each target as accepted, rejected, rate-limited, or uncertain.
The release JSON includes the outbox path and all per-target outcomes, including
pending work and invocation counts. JSON wrappers preserve nonzero process exits
and keep diagnostics separate from structured details.

Explicit `--dry-run` and global `DRY_RUN=true` perform no authentication, POST, or
outbox creation. An unresolved SHA can be previewed in dry-run only and is labeled
unresolved, never substituted with an unrelated PWD commit.

Typical exits are 0 for acknowledged completion or an explicitly labeled plan,
1 for incomplete fan-out or local I/O failure, 2 for plan/state/lock conflict,
3 for missing credentials/dependencies, 4 for invalid arguments, 7 for a single
request's definitive rejection, and 8 for uncertain delivery or an exhausted
single-request rate limit. These are also the saved-handoff recovery command's
exits; the publishing command separately reports downstream failure in its
dispatch details without changing successful publication into an upload error.

## Regression tests

```bash
bash scripts/tests/test_dispatch_delivery.sh
bash scripts/tests/test_dispatch_outbox.sh
bash scripts/tests/test_release_resume.sh
bats tests/unit/test_dispatch.bats
```

The shell suites use real Bash, jq, Git tags, hashes, filesystem operations,
`flock`, six competing senders, and an injected actual worker `SIGKILL`. Curl and
GitHub authentication responses are executable fixtures, and selected I/O errors
are injected. They do not exercise live GitHub workflows or establish downstream
exactly-once execution. Native macOS/Windows and network-filesystem locking need
separate integration validation.
