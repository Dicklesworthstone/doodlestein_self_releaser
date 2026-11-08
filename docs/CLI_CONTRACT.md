# dsr CLI Contract

**Version:** 1.0.0
**Status:** Draft

This document defines the authoritative contract for the `dsr` (Doodlestein Self-Releaser) CLI tool. All subcommands MUST adhere to these specifications.

---

## Purpose

`dsr` is a fallback release infrastructure for when GitHub Actions is throttled (>10 min queue time). It:
- Detects GH Actions throttling via queue time monitoring
- Triggers local builds using `nektos/act` (reusing exact GH Actions YAML)
- Distributes builds across Linux (trj), macOS (mmini), Windows (wlap)
- Generates smart curl-bash installers with staleness detection
- Signs artifacts with minisign and generates SBOMs

---

## Global Flags

These flags apply to ALL subcommands:

| Flag | Short | Type | Default | Description |
|------|-------|------|---------|-------------|
| `--json` | `-j` | bool | false | Machine-readable JSON output only |
| `--non-interactive` | `-y` | bool | false | Disable all prompts (CI mode) |
| `--dry-run` | `-n` | bool | false | Show planned actions without executing |
| `--verbose` | `-v` | bool | false | Enable verbose logging |
| `--quiet` | `-q` | bool | false | Suppress non-error output |
| `--log-level` | | string | "info" | debug\|info\|warn\|error |
| `--config` | `-c` | path | ~/.config/dsr/config.yaml | Config file path |
| `--state-dir` | | path | ~/.local/state/dsr | State directory |
| `--cache-dir` | | path | ~/.cache/dsr | Cache directory |
| `--no-color` | | bool | false | Disable ANSI colors |

### Flag Precedence

1. CLI flags (highest)
2. Environment variables (`DSR_*`)
3. Config file
4. Defaults (lowest)

---

## Exit Codes

Exit codes are semantic and MUST be consistent across all commands:

| Code | Name | Meaning | Recovery |
|------|------|---------|----------|
| `0` | SUCCESS | Operation completed successfully | None needed |
| `1` | PARTIAL_FAILURE | Some targets/repos failed | Check per-target errors |
| `2` | CONFLICT | Blocked by pending run/lock | Wait or force with `--force` |
| `3` | DEPENDENCY_ERROR | Missing gh auth, docker, ssh, etc. | Run `dsr doctor` |
| `4` | INVALID_ARGS | Bad CLI options or config | Check help/docs |
| `5` | INTERRUPTED | User abort (Ctrl+C) or timeout | Retry operation |
| `6` | BUILD_FAILED | Build/compilation error | Check build logs |
| `7` | RELEASE_FAILED | Upload/signing failed | Check credentials |
| `8` | NETWORK_ERROR | Network connectivity issue | Check connection |

### Exit Code Usage

```bash
dsr build --repo ntm
case $? in
  0) echo "Success" ;;
  1) echo "Partial failure - check errors" ;;
  3) echo "Missing dependency - run: dsr doctor" ;;
  *) echo "Failed with code $?" ;;
esac
```

---

## Stream Separation

CRITICAL: All dsr commands MUST follow strict stream separation.

| Stream | Content | When |
|--------|---------|------|
| **stdout** | JSON data OR paths only | Always |
| **stderr** | Human-readable logs, progress, errors | Always |

### Rules

1. **Never mix** human output with data on stdout
2. **`--json` mode**: stdout = pure JSON, stderr = empty (unless error)
3. **Default mode**: stdout = paths/IDs, stderr = pretty output
4. **Errors**: Always to stderr with structured format

### Example

```bash
# Default mode
$ dsr build --repo ntm
Building ntm for linux/amd64...       # stderr
Compiling v1.2.3...                   # stderr
/tmp/dsr/artifacts/ntm-linux-amd64    # stdout (path only)

# JSON mode
$ dsr build --repo ntm --json 2>/dev/null
{"command":"build","status":"success",...}
```

---

## JSON Output Schema

All `--json` output MUST follow this envelope:

```json
{
  "command": "string",           // Subcommand name (build, release, check, etc.)
  "status": "success|partial|error",
  "exit_code": 0,
  "run_id": "uuid",              // Unique run identifier
  "started_at": "ISO8601",
  "completed_at": "ISO8601",
  "duration_ms": 12345,
  "tool": "dsr",
  "version": "1.0.0",
  "schema_version": "1.0.0",

  "artifacts": [                 // For build/release commands
    {
      "name": "ntm-linux-amd64",
      "path": "/tmp/dsr/artifacts/ntm-linux-amd64",
      "target": "linux/amd64",
      "sha256": "abc123...",
      "size_bytes": 12345678,
      "signed": true
    }
  ],

  "warnings": [
    {"code": "W001", "message": "..."}
  ],
  "errors": [
    {"code": "E001", "message": "...", "target": "linux/arm64"}
  ],

  "details": {}                  // Command-specific payload
}
```

### Required Fields

Every JSON response MUST include:
- `command`
- `status`
- `exit_code`
- `run_id`
- `started_at`
- `duration_ms`
- `tool`
- `version`

Recommended (additive, backwards compatible):
- `schema_version`

### Details Payload

The `details` field contains command-specific data:

#### `dsr check` details
```json
{
  "details": {
    "repos_checked": ["ntm", "bv", "cass"],
    "throttled": [
      {
        "repo": "ntm",
        "workflow": "release.yml",
        "run_id": 12345,
        "queue_time_seconds": 720,
        "threshold_seconds": 600
      }
    ],
    "healthy": ["bv", "cass"]
  }
}
```

#### `dsr build` details
```json
{
  "details": {
    "repo": "ntm",
    "version": "v1.2.3",
    "targets": [
      {
        "platform": "linux/amd64",
        "host": "trj",
        "method": "act",
        "workflow": ".github/workflows/release.yml",
        "job": "build-linux",
        "duration_ms": 45000,
        "status": "success"
      }
    ],
    "manifest_path": "/tmp/dsr/manifests/ntm-v1.2.3.json"
  }
}
```

#### `dsr release` details
```json
{
  "details": {
    "repo": "ntm",
    "version": "v1.2.3",
    "tag": "v1.2.3",
    "release_url": "https://github.com/owner/ntm/releases/tag/v1.2.3",
    "draft": true,
    "create_response": "/private/state/dsr/releases/dsr-create-custody.ABCDEF12/dsr-api-response.GHIJKLMN",
    "finalization_tmpdir": "/private/state/dsr/releases/dsr-create-custody.ABCDEF12",
    "artifacts_dir": "/srv/releases/ntm-v1.2.3",
    "assets_uploaded": [
      {
        "name": "ntm-linux-amd64.tar.gz",
        "size_bytes": 12345,
        "content_type": "application/gzip",
        "status": "uploaded",
        "download_url": "https://github.com/owner/ntm/releases/download/v1.2.3/ntm-linux-amd64.tar.gz"
      }
    ]
  }
}
```

Strict draft creation preserves the original successful POST response and its
frozen signed asset plan in an owner-only child of `$DSR_STATE_DIR/releases`.
This custody does not depend on the caller's temporary directory surviving a
reboot or cleanup. A missing state parent is created privately; a linked,
foreign-owned, or group/world-writable release-state directory is refused before
POST. Allocation failure never falls back to temporary storage. Strict fallback
keeps its existing private child beneath the build-bound publication handoff.
Pass
`details.create_response` to `dsr release finalize` and set `TMPDIR` to
`details.finalization_tmpdir`. Pass `--artifacts` with `details.artifacts_dir`
when the producer used a custom output directory. Finalization resolves that
existing directory to its physical path once, then repeats the same signed
artifact, source, contract, tag, and creation-custody checks against it. Without
`--artifacts`, it uses `$DSR_STATE_DIR/artifacts/<tool>-<tag>`.
`create_response` and `finalization_tmpdir` are null when this invocation has no
original creation custody; a later GET cannot replace that response. Asset
download URLs use the release tag and percent-encoded filenames; draft assets
remain subject to GitHub's draft access rules until publication.

#### `dsr fallback` details
Success:
```json
{
  "details": {
    "repo": "ntm",
    "version": "v1.2.3",
    "steps": [
      {"command": "check", "status": "success", "exit_code": 0, "run_id": "uuid-1", "duration_ms": 1200},
      {"command": "build", "status": "success", "exit_code": 0, "run_id": "uuid-2", "duration_ms": 45000},
      {"command": "release", "status": "success", "exit_code": 0, "run_id": "uuid-3", "duration_ms": 8000}
    ],
    "build_manifest": "/tmp/dsr/manifests/ntm-v1.2.3.json",
    "release_url": "https://github.com/owner/ntm/releases/tag/v1.2.3"
  }
}
```

Error:
```json
{
  "details": {
    "repo": "ntm",
    "version": "v1.2.3",
    "steps": [
      {"command": "check", "status": "success", "exit_code": 0, "run_id": "uuid-1", "duration_ms": 1200},
      {"command": "build", "status": "error", "exit_code": 6, "run_id": "uuid-2", "duration_ms": 45000, "error": "build failed"}
    ]
  }
}
```

#### `dsr status` details
Success:
```json
{
  "details": {
    "generated_at": "2026-01-30T15:00:00Z",
    "overall_status": "ok",
    "config": {"valid": true, "path": "~/.config/dsr/config.yaml", "schema_version": "1.0.0"},
    "hosts": [
      {"host": "trj", "status": "ok", "platform": "linux/amd64", "last_checked_at": "2026-01-30T14:59:30Z"},
      {"host": "mmini", "status": "warn", "platform": "darwin/arm64", "message": "ssh timeout"}
    ],
    "queue": {"throttled_count": 0, "threshold_seconds": 600},
    "last_run": {"command": "check", "status": "success", "exit_code": 0, "run_id": "uuid-1", "duration_ms": 1200}
  }
}
```

Error:
```json
{
  "details": {
    "generated_at": "2026-01-30T15:00:00Z",
    "overall_status": "error",
    "config": {"valid": false, "path": "~/.config/dsr/config.yaml"},
    "hosts": [{"host": "trj", "status": "error", "message": "disk full"}],
    "last_run": {"command": "build", "status": "error", "exit_code": 6, "run_id": "uuid-2", "duration_ms": 45000}
  }
}
```

#### `dsr report` details
Success:
```json
{
  "details": {
    "generated_at": "2026-01-30T15:00:00Z",
    "summary": {"runs_last_24h": 12, "failures_last_24h": 1, "throttled_repos": 0},
    "recent_runs": [
      {"repo": "ntm", "command": "build", "status": "success", "exit_code": 0, "duration_ms": 32000},
      {"repo": "bv", "command": "check", "status": "success", "exit_code": 0, "duration_ms": 900}
    ],
    "alerts": []
  }
}
```

Error:
```json
{
  "details": {
    "generated_at": "2026-01-30T15:00:00Z",
    "summary": {"runs_last_24h": 0, "failures_last_24h": 0, "throttled_repos": 0},
    "alerts": [{"code": "E060", "message": "report data unavailable"}]
  }
}
```

#### `dsr prune` details
Success:
```json
{
  "details": {
    "state_dir": "~/.local/state/dsr",
    "dry_run": true,
    "cutoff_days": 30,
    "pruned_count": 12,
    "bytes_freed": 104857600,
    "pruned_paths": [
      {"path": "~/.local/state/dsr/logs/2025-12-01/run.log", "size_bytes": 2048}
    ]
  }
}
```

Error:
```json
{
  "details": {
    "state_dir": "~/.local/state/dsr",
    "dry_run": true,
    "cutoff_days": 30,
    "pruned_count": 0,
    "bytes_freed": 0,
    "errors": [{"code": "E050", "message": "state directory not found"}]
  }
}
```

#### `dsr repos` details
Success:
```json
{
  "details": {
    "action": "list",
    "repos": [
      {"name": "ntm", "repo": "dicklesworthstone/ntm", "local_path": "/data/projects/ntm", "language": "go"}
    ]
  }
}
```

Error:
```json
{
  "details": {
    "action": "add",
    "repo": "dicklesworthstone/ntm",
    "errors": [{"code": "E052", "message": "repo already exists"}]
  }
}
```

#### `dsr config` details
Success:
```json
{
  "details": {
    "action": "migrate",
    "from_version": "0.9.0",
    "to_version": "1.0.0",
    "config_file": "~/.config/dsr/config.yaml",
    "backup_path": "~/.config/dsr/config.yaml.bak"
  }
}
```

Error:
```json
{
  "details": {
    "action": "validate",
    "config_file": "~/.config/dsr/config.yaml",
    "valid": false,
    "errors": [{"code": "E031", "message": "missing schema_version"}]
  }
}
```

---

## Subcommands

### `dsr check`

Detect throttled GitHub Actions runs.

```bash
dsr check [--repos <list>] [--threshold <seconds>] [--all]
```

| Flag | Default | Description |
|------|---------|-------------|
| `--repos` | all configured | Comma-separated repo list |
| `--threshold` | 600 | Queue time threshold (seconds) |
| `--all` | false | Check all workflows, not just releases |

A configured tool's `workflow` names its release workflow. The threshold
defaults to `threshold_seconds` (or `DSR_THRESHOLD`).

The check scans queued and in-progress runs separately and follows their
pages, rather than taking a sample of recent completed and active history.
Run IDs are deduplicated across the responses. A failed page, malformed
active-run timestamp, or incomplete listing at GitHub's filtered-result limit
makes that repository unreadable (`details.skipped`), never healthy. A known
throttled run in another successfully checked repository still takes exit-code
precedence over the unreadable repository.

An in-progress run is not throttled solely because it has run for a long
time. DSR reads the complete job inventory for that observed run attempt
(or explicitly requests the latest jobs if the attempt is unavailable).
Latest-job pagination requires every first-page job to identify the same
attempt; subsequent pages are pinned to it. Ambiguous attempts or missing
attempt evidence block pagination instead of combining separate reruns.
At least one job must be queued, every other job must be completed, and
the latest available run/job timestamp must exceed the threshold. Executing
jobs and approval-pending jobs suppress this automatic fallback decision.
Recent job creation or completion restarts the queue clock. Job inventories
that cannot be fully read within the 1,000-job safety bound, contain invalid
metadata, or disagree with the observed run/source/attempt are unreadable.

Each throttled row includes `queue_reason: "workflow_queue"` for a queued
workflow or `queue_reason: "job_queue"` for stalled job dispatch. The latter
also includes the nonempty `queued_job_ids` array and measures
`queue_time_seconds` from the latest available activity.

**Exit codes:**
- `0`: No throttling detected
- `1`: Throttling detected (triggers fallback recommendation)
- `3`: gh auth missing
- `4`: Invalid request deadline configuration
- `5`: Authentication interrupted
- `8`: GitHub API error for a repo (listed in `details.skipped`), with no throttling seen elsewhere

Authentication preflight is bounded by `GH_API_TIMEOUT` (60 seconds by default).
A stalled credential helper returns exit 8; interruption returns exit 5 without
trying another authentication transport. Each subsequent GitHub API attempt
has the same deadline, covering authentication, token lookup, and the request.

---

### `dsr watch`

Continuous monitoring daemon.

```bash
dsr watch [--interval <seconds>] [--auto-fallback] [--notify <method>]
```

| Flag | Default | Description |
|------|---------|-------------|
| `--interval` | 60 | Check interval in seconds |
| `--auto-fallback` | false | Auto-trigger fallback on throttle |
| `--max-attempts` | 3 | Maximum attempts per observed run, from 1 through 10 |
| `--retry-delay` | 60 | Initial retry cooldown in seconds, from 1 through 3600 |
| `--max-concurrent` | 2 | Active watcher fallback pipelines, from 1 through 32 |
| `--once` | false | Check once using the same exclusive lock and recovery journal |
| `--notify` | none | Notification: slack\|discord\|desktop\|none |

Automatic fallback requires an explicit `v`-prefixed version tag and the
workflow run's full source SHA. The watcher passes both to `fallback`; missing
or ambiguous source identity never falls back to detecting a version from the
current checkout. It also passes `--isolate-source`: quality checks, builds and
publication use a private materialization of that exact commit. A newer, dirty
or absent developer checkout does not prevent automatic fallback. Available
objects and the matching tag are copied without modifying the checkout; when
they are unavailable, the materializer fetches the exact tag from the configured
GitHub repository and refuses a mismatched commit. Configured sibling sources
must be locally available at their pinned revisions. Initialized project and
sibling submodules are copied recursively from their parent gitlink commits;
their pinned objects must also be available locally. The ordinary isolated-source
restrictions still apply, including the refusal of unpinned dependencies and
unsupported absolute Cargo paths. Every retry
materializes a fresh source tree; it does not reuse a modified prior copy.
The attempt journal records `isolate_source` and preserves it across retries.
Older attempts without that field retain the original checkout mode and still
require a clean checkout at the selected commit. This keeps existing native
checkpoints' branch/source bindings valid; retries never silently change them.

Each attempt retains its output and terminal exit status under
`watch-attempts/`, and its build outputs under `watch-artifacts/<run-id>/`.
`triggered.json` records running, succeeded, failed, or blocked outcomes across
watcher restarts. Failed attempts can retry while the same source run remains
throttled, with an exponential cooldown capped at one hour. They can also retry
after that upstream run leaves the queue and an uncached GitHub observation
confirms it completed with `failure`, `timed_out`, or `startup_failure`. This
recovery requires the original run ID, repository, version tag and source SHA,
and the tool must still be configured for that repository. A missing queue entry
alone never authorizes a retry. Active, successful, cancelled, approval-pending,
skipped or otherwise unverified upstream runs do not authorize this recovery;
failed reads and identity changes preserve the failed attempt without consuming
its retry budget. Report-only mode does not query or launch these retries, and
dry-run can describe an eligible retry without changing its journal or outputs.

A retry resumes only a unique build UUID matching the exact tool, tag, source SHA,
and private output directory. A `partial` build with both successful and failed targets is
eligible for this recovery; fallback validates and reuses successful target
artifacts while retrying the remaining targets. Cancelled, mismatched, or
ambiguous checkpoints block automatic recovery. When an earlier attempt failed
before creating either a checkpoint or its output directory, the retry may start
the same pinned build afresh. Successful runs are never
replayed. Legacy timestamp-only history and workers lost without a completion
receipt require manual recovery; their publication outcome cannot safely be
inferred.

Admission is bounded across the retained attempt journal, rather than separately
for each poll. A running attempt occupies its slot until its inherited kernel
lock is free and its terminal receipt is admitted. A still-running descendant
keeps that slot even when the parent has written a completion receipt. This
applies to workers surviving a watcher restart or `--once` invocation. Reducing
`--max-concurrent` does not cancel existing workers; it defers new admission
until the active count falls below the new limit. Existing per-host build limits
continue to apply independently.

Deferral does not create an attempt, reserve output, or consume a failed run's
retry budget. Never-started candidates persist in `triggered.json.pending`, bound
to their original run ID, tool, repository, version tag, source SHA and source
isolation mode. Older pending candidates take priority over newly observed work.
Once capacity is available, a pending run must be freshly observed as throttled
or independently confirmed as the same terminal upstream failure before its
first attempt starts. It uses no resume checkpoint. An existing unclaimed output
directory still blocks admission. Pending candidates absent from the throttle
inventory are not individually queried while all slots are occupied.

An uncached, identity-matching upstream success or cancellation retires a pending
candidate without creating an attempt. Active, unknown or unavailable observations
retain it; changed source identity, missing tool configuration or a remapped
repository cannot authorize a launch. Failed attempts retain their existing retry and
checkpoint rules. Report-only mode adds, admits and retires no pending candidates;
it retains the established reconciliation of already-started attempts. A dry run
budgets its planned starts against the same limit without writing recovery state.
JSON
once results include `details.max_concurrent`, `details.active_attempts` (the
retained active work), and `details.deferred_count` (eligible runs deferred for
capacity during this poll).

Terminal fallback notifications are sent only after the worker has saved its
completion receipt; detailed phase output remains in the attempt's `result.json`
and the run's `fallback-<run-id>.log`.

Stopping the watcher leaves its already started fallback workers running.
Their separate descriptor locks prevent overlapping attempts without holding
the watcher lock. Both continuous mode and `--once` require `flock` or Python 3
with `fcntl`; dry-run does not create locks, attempts, or recovery state.

---

### `dsr build`

Build artifacts locally using act or native compilation.

```bash
dsr build --repo <name> [--targets <list>] [--version <tag>]
          [--parallel[=N] | --jobs <N>] [--resume[=RUN_ID]] [--diagnostic-native]
```

| Flag | Default | Description |
|------|---------|-------------|
| `--repo` | (required) | Repository to build |
| `--targets` | all | Platforms: linux/amd64,darwin/arm64,windows/amd64 |
| `--version` | HEAD | Version/tag to build |
| `--parallel[=N]` | off (bound 2 when enabled) | Run independent targets concurrently |
| `--jobs` | 1 | Explicit concurrency bound from 1 through 32 |
| `--dry-run` | false | Validate local build inputs and print a plan; a requested relocation requires its approval and reports proposed task routes |
| `--resume[=RUN_ID]` | off | Reuse verified completed targets and retry incomplete targets |
| `--resume-target-host TARGET[@TRIPLE]=HOST` | off | Relocate one failed native task during a strict release resume; qualify a variant by its exact triple |
| `--resume-target-host-approval FILE` | required with relocation | Operator-reviewed JSON binding the run, target, replacement host and configuration hashes |
| `--output-dir` | state directory | Artifact collection directory, bound into resume state |
| `--no-sync` | false | Skip ordinary source sync (forbidden by strict release contracts) |
| `--sync-only` | false | Sync selected build hosts without compiling; exit 1 if any host fails |
| `--diagnostic-native` | false | Build explicit native targets under strict source/family checks, with non-publishable diagnostic provenance |

Every initialized build context records `repo_config_sha256`, the SHA-256 of
the exact `repos.d/<tool>.yaml` bytes captured before configuration-derived
planning. This applies to ordinary, strict, workflow, and singleton native
runs as well as variant matrices. Resume validates the retained binding and
the current bytes before source preparation or output reuse, and repeats
admission under the coordinator lock. The CLI passes its original digest
through synchronization to the scheduler; workers recheck it before execution
and before accepting results, and final packaging rechecks it before granting
publication authority.

A changed command, environment, packaging setting, or byte-only YAML edit
returns configuration error `4` at resume admission. Restore the exact saved
file or start a fresh run. Missing or malformed saved bindings, including
older checkpoints, also require a fresh run; current configuration is never
used to manufacture missing original evidence. A refusal preserves retained
artifacts, immutable receipts, and attempt counters. `--jobs` may change
between attempts because it is scheduling input outside the recipe file.
Explicit approved relocation is the only supported recipe transition and
must bind the prior digest to this saved value before advancing it atomically.

Native build environment lookup follows launcher export order: a platform's
`cross_compile.<platform>.env` overrides global `env`, including an explicit
empty value. Rust target derivation, glibc toolchain selection, and artifact
path resolution use that same effective value. An empty Cargo target still
uses the existing configured/default target derivation when enabled. Explicit
native variant conflicts continue to stop dispatch, and policy checks retain
all declarations so a later value cannot hide an earlier remote-build requirement.

Native Go builds derive `GOOS` and `GOARCH` from the requested platform;
the `armv7` alias resolves to `GOARCH=arm` and `GOARM=7`.
Platform-specific `cross_compile.<platform>.env` values override global `env`
values; the effective selectors must match the requested target or dispatch
stops with exit 4. Each launcher clears inherited selectors before exporting
the resolved pair. `CGO_ENABLED` remains under the repository's control, so
cross-compilation that requires C libraries still needs the configured C
toolchain.

Target logs and result receipts are isolated by task and attempt. Aggregation
is deterministic in requested-platform order, then configured triple order.
Targets that share a native output path use private source copies when supported.
When those outputs cannot be isolated, only the conflicting targets wait;
independent queued targets continue within the configured job limit. Deferral
does not reserve an attempt or change the target's log identity and result order.
The queue also prefers targets whose bound hosts have available capacity before
starting another worker that would wait on a saturated host. These observations
are scheduling hints: every worker still acquires its own exclusive host slot.
If no queued host is ready, workers use the existing bounded capacity wait;
host selection, retry budgets and successful-result reuse remain unchanged.
Workers start with stdin connected to the null device; only the coordinator
reads the queued task records. A worker failure or timeout does not discard
later tasks. Cancellation stops dispatch, drains started workers, and retains
their interrupted attempt receipts. Each worker keeps an owned local process-group
anchor alive until cleanup completes. Interrupt, termination and hangup signals
request cancellation, which allows five seconds for active
backends to terminate, then kills remaining members of that group before the live
worker releases capacity or writes an interruption receipt. Completed backends
drain without that grace delay. Losing the worker closes its control channel and
retires the group; a killed worker does not fabricate a completion receipt or claim
to have released its lease. Native remote builds retain their host-side supervisors.
Timed local commands also remain in an owned process group. A command leader
exiting does not abandon a descendant that ignored termination; cleanup finishes
before the timeout wrapper returns its actual command or deadline status.
The timed command retains its original stdin, including staged script input.
When neither `timeout` nor `gtimeout` is installed, a Bash watchdog enforces
the positive duration in seconds and the same five-second escalation. It
preserves shell functions, argument boundaries and inherited descriptors.
An unavailable timer or lost watchdog refuses the operation instead of
allowing it to continue without a deadline.
Host-health probes, installer canaries and upgrade verification use the same
owned deadline supervisor. Their configured time limits still apply without
GNU timeout, and a probe's early success text cannot override its timeout status.
Queued tasks that have never run report
`status: "skipped"` and `attempt: 0`, without a log or result path. They remain
pending in run state, so exact-run resume starts their first attempt while
reusing verified successful receipts and retrying interrupted attempts.
Per-target JSON includes the retained `attempt`, `exit_code`, `log_path`, and
`result_path` when available. When a live coordinator recovers a missing
receipt, it records the observed `worker_exit_code` and
`receipt_source: "coordinator"`; a missing receipt cannot turn a zero process
exit into a successful build.

Build exclusion is held by an inherited operating-system file lock for each
tool and version. If the coordinator dies while a worker remains active, an
immediate resume returns exit 2 until the last inherited holder closes its
descriptor. The saved PID and lock age are diagnostic information; neither a
dead coordinator nor an old timestamp permits overlapping attempts. Public
build and fallback commands retain this exclusion through collection and
publication. Build state requires a filesystem that supports local advisory
locks, with `flock` or Python 3's `fcntl` available on the coordinator.

The `.lock.lease` sidecar is a stable lock inode and must remain in place.
Legacy PID-only metadata or a missing, replaced or malformed lease identity
fails closed. For a retained legacy `.lock`, verify that the old coordinator
and all of its workers have stopped before moving that metadata aside; keep
any `.lock.lease` sidecar. Current lease-backed runs recover automatically once
their inherited holders finish.

After coordinator loss and release of that exclusion, resume reconciles valid
terminal worker receipts with their retained dispatch attempt and paths. The
original sidecars remain unchanged. Failed sidecars retain their observed error
and exit code, and a source-sync refusal is excluded from the compiler retry
budget exactly once, even across repeated crashes during reconciliation.
The retry limit applies to every non-reusable target, including one still
recorded as running or completed with unavailable artifacts. Verified completed
results remain reusable at the limit. Exhaustion does not launch another worker
or create an attempt receipt. When no valid failed result is available, run
state and aggregate output record a failed coordinator result with
`stage: "resume"` and exit code 6, without inventing an observed worker exit or
successful artifact evidence.
Native host-readiness refusals retain the requested platform, optional selected
triple, host, and attempt receipts. They report `stage: "host_readiness"` and
`exit_code: 4`; public target status is `failed`, even though no compiler ran.
Host-slot acquisition failures report `stage: "host_capacity"`, `exit_code: 2`,
and `backend_started: false`. They retain their own immutable attempt receipts
and remain eligible for resume after host capacity becomes available.
Receipt-write failures release the attempt's capacity lease before the worker
returns, preserving unrelated workers' slots and allowing a later retry.
The coordinator persists an attempt reservation before creating its log or
starting its worker. A failed reservation leaves no orphan log to block resume.
A later dispatch failure reports `stage: "dispatch"`, `exit_code: 4`, and
`execution_started: false`; any already started workers are cancelled and
drained. A saved reservation keeps its attempt number even if the coordinator
stops before launch, so resume uses a fresh number and preserves old receipts.
Receipt paths are reported only when the corresponding refusal receipt was
written. A recovered successful worker receipt regains its saved attempt and
log/result paths without changing the original receipt or rebuilding its output.
If the coordinator cannot persist a finished worker's outcome, dispatch stops
and active peers are cancelled and reaped. The run reports exit code 4 and
`details.error`, preserving the actual target outcome and attempt rather than
classifying the worker as unstarted. `execution_started: true` means the worker
was launched; it does not assert that a compiler ran. Worker receipts also
record the worker-owned `backend_started` flag. It becomes true
when the worker launches its build backend after capacity acquisition; native
host readiness can still refuse before compilation. Backend output cannot
override this flag to claim a capacity refusal after execution.
Existing immutable worker receipts remain available for exact-run resume, and a failed coordinator receipt
write does not create a reported `result_path`. A retained nonempty malformed
receipt still causes resume to refuse; it is not overwritten or accepted.
The same rule applies when resume cannot checkpoint an already verified
sidecar or a retry-budget decision. Its original outcome, attempt and existing
receipt remain observable while the coordinator stops and drains active peers.
Saved attempt counters and build purposes are checked before resumed dispatch;
later checkpoint-read failures return an explicit coordinator error without
inventing an unknown attempt count. A new durable reservation supersedes the
previous failed observation even if cancellation precedes worker launch.
Missing or unadmitted sidecars are not reported as result files, and a reserved
but unstarted attempt does not acquire a nonexistent build log on recovery.
Actual INT/TERM interruption retains exit code 130. These recovery boundaries
are exercised by `test_act_orchestration.sh --resume-persistence-only` and the
existing dispatch-reservation CI gate using real local processes and controlled
producer/checkpoint faults; they do not qualify native build hosts.
The aggregate failed count includes all unsuccessful requested tasks, including
skipped tasks. An interrupted run remains resumable and cannot publish an
authoritative manifest.

For native Rust builds, a `target_triples` list expands one platform
into independent GNU/musl tasks. Each task records its selected `target_triple`
and a `task_key` such as `linux/amd64@x86_64-unknown-linux-musl`; singleton and
workflow tasks retain their platform as the task key. Platform routing and
`--targets` continue to use `linux/amd64`.

Each native variant has its own staging directory, Cargo home, output directory
and retained artifact receipts. Resume verifies and reuses completed variants
independently, and refuses a changed ordered task list or repository
configuration. Partial artifacts remain available for resume,
but no authoritative manifest is emitted until all tasks succeed.

A strict `release_contract` requires one `exact_primary_assets` entry per
configured variant. A platform with multiple triples uses qualified keys such
as `linux/amd64@x86_64-unknown-linux-gnu` and
`linux/amd64@x86_64-unknown-linux-musl`; a singleton keeps its physical platform
key. The exact key set must match the configured matrix. Each primary keeps its
literal contracted filename and archive format, and its manifest row retains
physical `target` plus `target_triple`. The selected triple reaches strict
source admission, staging, compiler context, native result, and release
verification. Complete task and environment inventories are required before
publication; a successful GNU task cannot stand in for a missing musl task.
In a mixed matrix, singleton platforms also require the compiler triple
selected by their configuration and native environment. Diagnostic projections
retain that requirement even when they select only a singleton platform.
Platform-owned additional artifacts are collected once by the first configured
triple, while each variant can retain its own archive companion files.

Ordinary source synchronization returns a complete receipt for the selected
native targets, including target-to-host bindings, successful source paths,
and each host's transfer result. The coordinator validates coverage, unique
hosts, counts, status, and matching paths before admitting work. An unfinished
target on a failed host produces an immutable failed attempt with
`stage: "source_sync"` and the original host receipt in `source_sync`; no host
capacity slot or compiler is started for it. Other synced targets and workflow
targets can continue. The build command exits nonzero and withholds the
authoritative manifest while any target remains unsuccessful.
Both local and SSH rsync transfers use checksums to detect edited files whose
sizes and timestamps match the older destination files.

Native Unix admission checks the actual selected source, build, Cargo and recipe
temporary paths in addition to the host's default storage roles. Source planning
checks every required host/path combination before any source export or transfer;
native execution checks its effective paths before cache preparation, staging or
compilation. Planned directories are observed through their nearest existing
parent without creating them. Explicit path requests require fresh observations
and the normal 20 GiB floor, including on the root's split-storage capacity group.
An old healthy host-cache result cannot admit a new release destination.
See [Unix disk admission](UNIX_DISK_ADMISSION.md) for path resolution, receipt
coverage, split-storage behavior and the limits of this capacity check.

Run context and aggregate results retain the complete `source_sync` receipt.
Resume syncs again, updates the ordinary host/path bindings, and records the
new receipt in `source_sync_history`. It verifies completed artifact receipts
before deciding which targets still need work. `attempts` counts durable attempt
reservations. `source_sync_failures`, `host_readiness_failures`, and
`host_capacity_failures` count recorded transfer failures, native admission
refusals, and host-slot acquisition failures that never reached compilation;
these are excluded from the compiler retry limit. Readiness exemptions require
the explicit `host_readiness` stage and exit code 4. Capacity exemptions require
the explicit `host_capacity` stage, exit code 2, and the worker-owned
`backend_started: false` flag. Replaying the same failed attempt does not increase
the counters, and real build failures still consume the configured retry
allowance. Checkpoints without these counters retain
their prior conservative accounting; resume does not invent missing history.
Direct orchestration resume
without a new receipt retains the saved gate; the explicit CLI `--no-sync`
opt-out clears it while preserving recorded host/path bindings and history.
An ordinary sync receipt records transfer admission; strict releases continue
to require their frozen source snapshot.

Normal ordinary native builds request fresh source staging. Each distinct host
gets an exclusively created directory under `hosts.yaml` `build_root` (default
`/var/tmp` on Unix or the drive's `Users/Public` on Windows). The main source
and configured siblings are synchronized there; existing host checkouts remain
available independently. `--sync-only` retains its configured-path behavior.
Staged roots are retained for subsequent resume, including explicit `--no-sync`
resume. Windows Git-context import requires PowerShell 7 and Git; Unix import
requires Bash, Git, jq, and a SHA-256 utility.

Before any host transfer, DSR captures the main and Git-backed sibling HEADs,
symbolic branches, and exact tag object IDs in standalone bundles. A successful
staged sync has `staged_ordinary: true` and a top-level `git_context` containing
`git_sha`, `git_ref`, `bundle_sha256`, `tags`, `core_autocrlf`, and `core_eol`.
The top-level `sibling_git_contexts` records the captured contexts of Git-backed
siblings by directory name. Successful host rows retain their restored
`git_context` and `sibling_git_contexts`, with host-local `bundle_path` and
`source_root` in each context. Host/path receipts bind the build to these staged
locations and captured Git identity. Corrupt bundles, failed imports, or
changes to controller HEAD, branch, tags, or line-ending settings prevent admission.

The imported repository contains its own Git objects and index. Only the
validated line-ending settings `core.autocrlf` (`false`, `true`, or `input`) and
`core.eol` (`native`, `lf`, or `crlf`) are preserved from the effective controller
configuration; their defaults are `false` and `native`. Other Git configuration,
including custom filters, hooks, credentials, and linked-worktree pointers, is
not transported. Import initializes an absent `.git` and seeds its index from
HEAD without checking out or resetting working files. Staged and unstaged
controller edits retain their file contents but appear as unstaged edits in the private
index. This supports commit, branch, tag ancestry, and dirty version stamping
while preserving the controller index. Ordinary transfers are not an atomic
snapshot of concurrently edited working files.

Git context requires a top-level, non-shallow SHA-1 worktree. Sparse checkouts
and `assume-unchanged`/`skip-worktree` index entries are refused before host
transfer. Required sibling paths must exist, have safe unique directory names,
and stay beside the main source; Git-backed siblings meet the same context
requirements, while plain source directories can synchronize without Git.

Relocation requires the original controller to have released the build lock,
the selected target to be failed, and no target to be running. Completed or
cancelled runs and diagnostic builds are refused. Relocation cannot be combined
with `--sync-only`. After acquiring the build lock, the CLI rereads and validates
the checkpoint before preparing sources or changing output state; a checkpoint
that changed since the initial read is refused.
Platform-level host relocation requires the selected platform to have one
configured triple. For a multi-variant platform, select the failed task with
`TARGET@TRIPLE=HOST`, for example
`linux/amd64@x86_64-unknown-linux-musl=linux-backup`. The qualified selector must
match one retained native task exactly. A bare platform is ambiguous and is
refused for a variant matrix.
A failed singleton platform may relocate when other platforms in the run have
multiple variants. Every singleton relocation approval must bind the prior
configuration to the run's saved repository recipe digest; a matrix run also
requires its saved matrix digest to agree. The reviewed replacement digest advances
atomically with the host and source bindings; completed variant receipts and
the exact task inventory stay unchanged. Failed admission or staging cannot
advance that digest, and later resumes still refuse unapproved configuration
changes.
The approval file is a regular JSON file with these required fields:

```json
{
  "run_id": "<original-run-uuid>",
  "target": "windows/amd64",
  "new_host": "windows-backup",
  "prior_repo_config_path": "/path/to/retained-original-repo.yaml",
  "prior_repo_config_sha256": "<original-invocation-config-sha256>",
  "repo_config_sha256": "<reviewed-current-repo-config-sha256>",
  "hosts_config_sha256": "<reviewed-active-hosts-config-sha256>"
}
```

`hosts_config_sha256` binds the active host configuration selected by
`DSR_HOSTS_FILE`, falling back to `${DSR_CONFIG_DIR:-$HOME/.config/dsr}/hosts.yaml`
when that override is empty or unset. Relocation staging and subsequent retries
recheck this same configuration. Changed bytes prevent an ordinary resume.

The operator must establish the prior config's provenance from the original
invocation receipt. For a qualified variant, `target` in the approval is the
complete `TARGET@TRIPLE` key. The prior and current repository configuration
hashes must be identical: relocation changes only that task's host assignment,
not its recipe, environment, triple, or platform-wide default. The replacement
must be enabled and configured with the same physical platform as the selected task.
Completed siblings retain their original hosts, artifacts and attempt receipts.

For an unqualified singleton, DSR checks actual file hashes and permits only
the selected target's `cross_compile` host, build command, environment, and legacy
`hosts` entry to differ. Global settings and all other target settings must match.
The current recipe must resolve that singleton to the replacement host.
Its platform may differ from the artifact target when `cross_compile[TARGET].host`
explicitly selects it and the target has a nonempty build command, including an
inherited global `build_cmd`. This supports Linux-hosted Linux ARM64 and Windows
cross builds without mislabeling the build host. A platform-mapping fallback,
unknown host platform, or missing cross-build command is refused before staging.
The native worker still enforces the requested target's output and architecture.
Retained failed result/log files must agree with the old host and frozen source;
completed artifacts and result files must still verify. Replacement staging and
its pinned dependency closure are verified before an atomic state transition.

New strict native worker receipts carry `scheduled_source` with the original
`run_id`, `git_sha`, `git_ref`, assigned `host`, and snapshot `root`. Relocation
requires this exact object to match the retained run context. The assignment records
which frozen source the worker was given; it does not assert that source admission
or compilation ran. A host-capacity or host-readiness refusal, or a failed Go
backend, can therefore retain its truthful outcome and still move to an approved
replacement host. When either Rust source identity field is recorded, both
`DSR_RELEASE_GIT_SHA` and `DSR_RELEASE_GIT_REF` must match that assignment.
Older receipts without `scheduled_source` still require both source identity fields.

The retained worker receipt must report `failed`, `error`, or `timeout`, with an
integer exit code from 1 through 255, excluding interruption and termination
codes 130 and 143. Its target must be recorded as failed in run state. Its outcome
must match the saved result after accounting for coordinator-added attempt and
log/result path metadata. The coordinator annotations `execution_started`,
`resume_reused`, and `retry_limit_exceeded` must be absent or `true`; other outcome
fields must agree. Relocation preserves the original receipt and its refusal,
failure, or timeout classification.
The run records the prior context, replacement host platform, configuration
delta, source archive/manifest hashes, and prior attempt hashes; the next worker
uses the next attempt number.
Qualified assignments are saved in `context.task_host_overrides` and checked
against the complete approved relocation history on every resume. Source and
dependency checks, dispatch, public target results and manifest entries use each
task's effective host. An ordinary resume retains the approved assignment without
requiring the relocation flags again. Repeated relocation preserves every old
attempt and approval; hosts no longer assigned any task leave the active source
plan while their historical receipts remain available. Relocation does not reset
compiler retry budgets. Strict dry-run resumes report every retained task in its
original order, including variants before the first relocation, with its exact
triple and effective host. They use the checkpoint's task routes without selecting
platform defaults. Ordinary resume previews validate the source tag, current task
inventory and matrix recipe, plus the latest reviewed repository and active-host
configuration hashes after a relocation. A changed binding refuses the preview
without staging sources or starting workers.

Adding `--dry-run` to a relocation request runs local admission against the
observed checkpoint: exact task and run identity, complete configured task
inventory, valid attempt counters and relocation history, approval/configuration
hashes, failed receipt identity, and retained completed artifacts. Missing or
invalid local evidence refuses the request with exit 4; JSON reports a build
error. A successful JSON plan adds `details.relocation`:

```json
{
  "status": "planned",
  "validation": "local",
  "run_id": "<original-run-uuid>",
  "task_key": "linux/amd64@x86_64-unknown-linux-musl",
  "platform": "linux/amd64",
  "target_triple": "x86_64-unknown-linux-musl",
  "old_host": "linux-primary",
  "new_host": "linux-backup",
  "new_host_platform": "linux/amd64",
  "git_sha": "<retained-40-hex-source-sha>",
  "git_ref": "v1.2.3",
  "repo_config_sha256": "<reviewed-current-repo-config-sha256>",
  "hosts_config_sha256": "<reviewed-active-hosts-config-sha256>"
}
```

The target list projects all retained tasks with their `task_key`,
`target_triple` and proposed effective host; only the selected task changes.
For a singleton, the plan uses its platform task key and recorded target triple,
which may be empty. A preview does not acquire the build lock, change state or
receipts, stage sources, prepare Cargo, reserve capacity or start a worker.
Its Git checks disable optional index updates, lazy fetching, hooks and fsmonitor;
the initial cleanliness check avoids the live helper's explicit index refresh.
Host selection uses static configuration without health probes or cache updates.

Local planning observes files without a reservation. A later live resume rereads
and validates the checkpoint under the build lock, verifies all required source
snapshots, and performs remote admission before dispatch. A successful preview
does not prove remote availability, source/Cargo admission, or remaining retry
eligibility; the original attempt counts and compiler retry budget still apply.

After an interrupted staging attempt, only an exactly verified canonical
snapshot may be reused. Partial snapshots are retained and refused, not merged
or overwritten. Reuse repeats host capability and writable-path admission before
snapshot inspection or Cargo metadata preparation; an existing snapshot cannot
override a current host or storage refusal. No successful target is rebuilt by
relocation admission.

`--diagnostic-native` requires an enabled strict release contract and an explicit
nonempty, unique subset of its native targets. The clean tagged source, pinned
dependencies, immutable per-host snapshot, and executable/application family
checks remain mandatory. Required additional artifacts are selected from the
configured `workspace_additional_artifacts[target]` ownership, never from the
outputs that happen to exist. Normal strict release builds still require the
complete exact target set. Selecting a physical platform for diagnostics
includes every configured variant of that platform and retains their distinct
task identities.

Diagnostic output is isolated at
`$DSR_STATE_DIR/diagnostics/<tool>-<tag>/<run-id>` with a directory-purpose
receipt; `--output-dir`, `--no-sync`, `--sync-only`, and `--only-act` are
rejected. Build details, run context, target receipts, and the manifest carry
`build_purpose: "diagnostic-native"` and `publishable: false`. Same-purpose
resume retains its source/host/output binding; missing or mixed strict purpose
in state or target receipts is refused before worker admission.

Release and release verification reject diagnostic directories/manifests,
including `--fix`, even after strict configuration is removed. Diagnostic
artifacts cannot be reused by a release build. Strict release manifests require
explicit `build_purpose: "release"` and `publishable: true` at the root and on
every artifact; unclassified older strict manifests require a new build.
Neither a diagnostic build nor the `publishable` classification certifies
quality gates or measured native performance.

---

### `dsr release`

Upload artifacts to GitHub Release.

```bash
dsr release --repo <name> --version <tag> [--draft] [--prerelease] [--dispatch]
```

| Flag | Default | Description |
|------|---------|-------------|
| `--repo` | (required) | Repository name |
| `--version` | (required) | Release version/tag |
| `--draft` | false | Keep the verified release as a draft |
| `--prerelease` | false | Mark as prerelease |
| `--artifacts` | auto | Artifact directory |
| `--dispatch` | false | Trigger repository dispatch hooks after release |
| `--no-dispatch` | false | Disable repository dispatch for this run |
| `--dispatch-event` | `dsr_release` | Override dispatch event type |
| `--dispatch-repos` | config/env | Comma-separated override of dispatch targets |
| `--dispatch-retry-uncertain` | false | Enable dispatch and deliberately resend uncertain saved deliveries; duplicates are possible |
| `--no-manifest` | false | Upload an artifacts directory that has no build manifest, as-is |
| `--resume` | false | Reverify retained uploads and complete an owned interrupted publication |
| `--publish-draft` | false | With `--resume`, explicitly publish an ordinary draft using its original private creation custody |
| `--sbom` | `sbom.enabled`, default false | Generate and verify complete SBOM coverage before ordinary publication |
| `--no-sbom` | false | Disable automatic generation without discarding retained public metadata |
| `--sbom-format` | `sbom.format`, default `spdx` | Select `spdx` or `cyclonedx` and enable generation |

Binary publication, strict draft finalization, and `release verify --fix` hold
the same kernel leases used by build collection and artifact pruning, from
before the first artifact/manifest read through upload, repair or finalization
and final verification.
Both the canonical tag and possible original version
namespace are protected, such as `v1.2.3` and `1.2.3`. Another build, publisher or
inherited worker holding either lease blocks the operation with exit `2`;
unverifiable custody refuses with exit `4`. Tool/version components contain at
most 128 letters, digits, `.`, `_`, `+` or `-`, starting with a letter or digit.

Fallback may lend its existing lease through the inherited descriptor registry.
The release command verifies the descriptor, stable lease inode, owner record
and actual kernel custody; an environment flag alone cannot bypass acquisition.
It releases only leases it acquired itself, including on early errors, and
preserves the caller's ownership and traps. Checked cleanup occurs before the
final result; cleanup failure reports an error even if uploads completed.
Custody refusals and cleanup failures identify `details.stage: "build_custody"`
with an error message. Global `--dry-run` and verification without `--fix`
perform no lease creation, acquisition or borrowing, so their observations do
not reserve the artifact set.

Strict `dsr release finalize` supervises both its public command and its
lock-owning publication phase. HUP, INT and TERM stop new work, drain owned
local process groups, and return exit code `5`. JSON mode emits one
`release-finalize` error envelope after cleanup; partial or completed output
from an interrupted worker cannot become a success response. Build custody
remains held until publication descendants stop, including transports behind
nested timeout helpers. Loss of the waiting CLI also triggers cleanup, though
an already-killed caller cannot emit a result. Sourced callers retain their
signal traps and borrowed fallback leases.

Cancellation cannot recall a request GitHub has already accepted. The original
private creation response and pending finalization evidence remain available;
retrying the same command rechecks exact local and remote evidence before
reporting success or attempting promotion again.

New ordinary releases are created as private drafts. DSR freezes every selected
asset name, size, and SHA-256, including the manifest, generated checksums, and
selected metadata sidecars. It verifies the complete remote inventory and
release metadata before publishing the original release ID, then repeats the
verification against the public release. When creation pinned a source commit,
an existing remote tag must resolve to it. A missing tag is allowed before
publication only after an uncached, validated Git reference collection proves
that the exact tag is absent, including when similarly named tags exist.
Publishing creates the tag at the pinned commit; the public release must then
resolve to that exact commit. An unavailable or malformed absence check fails
closed.
An upload, inventory, source, or publication failure suppresses dispatch and
upgrade hooks. A failed publication can be returned to draft only while its
current nonce and metadata still prove ownership.

`dsr release verify TOOL VERSION --artifacts DIR` selects an existing local
artifact directory for manifest verification, `--fix` repair, and complete
`--checksums` / `--verify-checksums` audits. Directory aliases resolve to their
physical path. An explicit selection requires its own
`<tool>-<tag>-manifest.json`; it never falls back to a default-state manifest or
payload. Declared tool/version identity and successful-build fields must not
contradict the selected release. Omitting `--artifacts` retains the existing
default directory and legacy sidecar-manifest lookup.

For interrupted publication from custom output, use the same directory in
creation, repair, and finalization:

```bash
dsr release verify demo 1.2.3 --artifacts '/srv/build outputs/demo' --fix --dry-run
dsr release verify demo 1.2.3 --artifacts '/srv/build outputs/demo' --fix
```

The complete-checksum supervisor resolves the selection once and forwards that
same path to its metadata checks before and after auditing and to any requested
repair. Retargeting the original directory alias cannot redirect a later phase.
The selected artifact directory and the audit's `--checksum-output-dir` have
separate purposes: the former holds the original build output and manifest;
the latter holds downloaded verification evidence. Dry-run repair does not
create an artifact directory, materialize sidecars, or upload files.

Ordinary `dsr release verify TOOL VERSION --fix` binds repair to the observed
GitHub release ID and a validated local manifest. It uploads through the shared
verified upload helper and never clobbers existing assets. It verifies every
required name, size, hash, and uploaded asset ID against one complete, fresh
paginated inventory, including on reruns where no names appear missing.
Empty or invalid local manifests cannot authorize repair. Release identity and local
manifest or payload changes prevent success. A nominal upload acknowledgement
cannot remove an asset from the missing list. Ordinary and strict repair hold
artifact custody through the complete local and remote rechecks, including
strict checksum-sidecar materialization. Repair failures appear in
`details.repair.errors` when present; normal verification and dry-run output keep
their existing shape.

Downstream dispatch uses a persistent outbox keyed by the source repository and
GitHub release ID. Accepted destinations are skipped across process restarts;
definitively rejected destinations can retry, and uncertain POSTs require an
explicit resend decision. Authentication, dependency, and local preparation
failures known to occur before transport are recorded as `blocked` and can resume
normally. Their receipts count zero HTTP attempts, or only earlier definitive
rate-limit rejections if preparation fails before a later retry. Missing
receipts, interrupted transports, and unreadable transport outcomes remain
uncertain. The complete request plan and verified public release are retained.
Before each POST, DSR rechecks the release ID, visibility, tag
commit, and exact paginated asset inventory, downloading and hashing assets when
GitHub supplies no digest. Changed plans or publication evidence refuse delivery.
Explicit `dispatch.enabled: false` in repository or global configuration remains
disabled even when destination repositories are present.

Successful publication retains its successful exit status if a downstream hook
fails. Inspect `details.dispatch.status`, `exit_code`, `outbox_file`, and `results`
for the separate delivery outcome. The payload preserves the configured event
(`dsr_release` by default), uses `version` without a leading `v`, and uses the
stable `run_id: release-<GitHub-release-ID>` plus a per-destination `delivery_id`.

Use `dsr release dispatch --outbox /absolute/path/state.json` to recover only the
saved downstream handoff, including for an already-public strict release. It
uses the saved exact requests and requires the same public release; it does not
need local build artifacts or upload or publish again. Add `--retry-uncertain`
only to authorize resending unknown outcomes. `--status` reads the saved outcome
offline and preserves its exit code; `--dry-run` gives an offline preview with
exit zero. Both preserve the state bytes and make no network requests. Missing,
conflicting, corrupt, nonprivate, or relocated state is refused. See
[dispatch recovery](DISPATCH.md) for the full contract.

Ordinary creation requires Python 3 to preserve its original POST response and
immutable publication intent in a private directory under
`$DSR_STATE_DIR/releases`. `details.staging_receipt` identifies that intent;
`details.artifacts_dir` records the canonical artifact directory. Keep this
state directory when retrying with `dsr release TOOL VERSION --resume` and the
same `--artifacts` directory. Recovery rechecks the original response, the
complete frozen input plan, and actual GitHub bytes. It uploads only missing
assets and publishes an owned draft whose original intent was public, including
after an interrupted publish response. It refuses ambiguous, changed, or lost
creation custody. Upload journals alone never authorize publication.

Verified uploads and reused assets update a private, atomic upload receipt at
`$DSR_STATE_DIR/releases/<tool>-<tag>-upload.json`. Successful publication keeps
this receipt so `prune --keep-releases` continues to retain the local artifact
set. Drafts and partial uploads retain their receipts too, preserving inputs for
finalization or retry. Resume still verifies the actual remote assets; a saved
receipt never authorizes skipping verification or publishing a draft.

An explicitly requested draft remains private when a later `--resume` omits
`--draft`; an unrelated existing draft also remains private. Existing public
releases without staged creation custody retain ordinary upload behavior.
To explicitly publish a draft created by DSR, use:

```bash
dsr release TOOL VERSION --artifacts /absolute/path/to/artifacts --resume --publish-draft
```

This requires the original private creation response and frozen input plan.
It reuses matching uploads, completes missing uploads, and verifies the exact
release ID, metadata, pinned source, complete asset inventory and hashes before
publishing. The original receipt files retain their bytes and identities;
promotion authorization applies only to the invocation with `--publish-draft`.
If publication fails while the release is still private, retry with the same
flag. A plain `--resume` continues to honor the original draft request. If a
publish response is lost, an exact public verification can confirm success;
repeating the command verifies the public release without another publish.
`--publish-draft` conflicts with `--draft` and requires `--resume`. Strict
contracts continue to use `dsr release finalize` with their original creation
response. `details.promotion_requested` records the explicit flag; dry-run
reports the requested plan without contacting GitHub or asserting that remote
promotion admission has passed.

If a user subsequently publishes an explicitly requested draft on GitHub,
`--resume` verifies its original complete artifact plan without changing its
visibility, including on verification failure. Requesting `--draft` for an
already-public release still refuses before upload.
The same visibility protection applies when `--publish-draft` observes that
the owned release was already public at the start of recovery.
`--draft` on a retry can keep an owned public-intent draft private for that
invocation without changing its retained publication intent.

Automatic SBOM generation selects every payload from the exact build manifest,
including aliases and runtime metadata explicitly listed as artifacts. It
verifies all payload/document pairs before any remote mutation and publishes
the individual documents plus `sbom-manifest.spdx.json` or
`sbom-manifest.cdx.json`. Per-document `.dsr.json` receipts and the private
`sbom-plan` remain local. Completed verified scans survive interruption; changed
payloads, documents, or coverage block publication. A dry run reports the full
planned upload set without scanning or writing files.

`details.sbom` reports `enabled`, `status` (`disabled`, `planned`, or `verified`),
and `published`. Enabled reports include `format`, aggregate `filename`,
`artifact_count`, the complete public `files` list, and `manifest_sha256` (null
for a plan). Verified describes local coverage; `published` becomes true only
after a successful public-release verification. `--no-sbom` overrides configured
generation but cannot remove metadata frozen into a previous publication plan.
A format combined with `--no-sbom`, generation without a manifest, or generation
for a strict closed contract returns `4`. See [SBOM generation](SBOM.md).

An ordinary release publishes the build manifest's artifacts. `dsr build`
publishes the manifest only after every target, artifact collection, packaging,
manifest rewrite, and completion-state write succeeds. A run/source-bound
publication receipt blocks its output directory from the start of a real build
until that final commit; private manifest staging is also non-publishable.
Failed or interrupted builds remain blocked even with `--no-manifest`.
`--resume` revalidates retained target receipts and retries unfinished packaging
or publication without recompiling verified completed targets. A completed
build's receipt binds the final manifest name and SHA-256 as well as its run
and source identity; a missing or changed manifest is refused with exit 4.
Dry runs and `--sync-only` do not change existing publication state.

For an external artifact directory without a DSR publication receipt, a missing
manifest causes exit 4 unless `--no-manifest` is given (no completeness check,
no checksums).
The manifest's `source.git_sha` must be the commit the local tag names (exit 4
otherwise), origin must not hold a different commit under that tag, and a tag
GitHub does not have yet is created at that commit (`target_commitish`), not at
the default branch head. `dsr build --version` likewise exits 4 when the
version's tag exists and the checkout is at another commit. `--draft` against a
release that already exists and is published exits 7 without uploading
(dropping `--draft` adds the assets to it).

`dsr build --json` reports `repo`, `run_id` (the build run that `--resume=`
takes), `manifest_path` (set only when every task succeeded) and one object
per build task: `platform`, `host`, `method`, `status`
(`success`/`failed`/`timeout`, or `skipped` when not attempted), and when known
`target_triple`, `task_key`, `artifact_path`, `artifact_paths`, `error` and
`duration_ms`. A native matrix therefore reports multiple rows with the same
platform, preserving each variant's result; `total`, `success` and `failed`
count tasks. `artifact_paths` is authoritative when present and nonempty.
Each target also retains its `build_influence_env` and complete `cargo_isolation`
object when the worker produced them. This includes dependency-cache receipts,
available toolchain identities, and the strict Windows Cargo context summary.
The values agree with the durable target result and manifest build-environment
receipt. Failed attempts retain the evidence available before failure;
unattempted targets do not receive fabricated provenance.

Native results also retain `native_execution`: the observed `phase`, configured
`timeout_seconds` and `transport_timeout_seconds`, original `command_exit_code`,
`failure_kind` (`command`, `validation`, or null), and
`build_program_dispatched`. The source-verification and toolchain-observation
phases use the sync budget; the final build program uses the build budget, with
transport cleanup grace recorded separately. A successful observation whose
receipt fails validation retains command exit zero and a `failure_kind` of
`"validation"`. A timeout return is still normalized to target status `timeout`
and DSR exit 5, with raw exit 124 retained. That code alone does not prove that
the host supervisor fired: inspect the private native attempt `log_file`, which
is distinct from the coordinator worker transcript at `log_path`.

`build_program_dispatched: false` means the final build transport was not called.
True records dispatch only; source/toolchain checks inside the guarded program
can still refuse execution before Cargo or rustc starts. Successful post-build
verification leaves the build-command observation intact; failed post-build
verification records its own phase. A later archive or collection failure does
not turn a successful command into a compiler failure. Earlier admission
refusals without an execution observation omit this object.
Native per-target `duration_seconds` is converted to `duration_ms` in public
JSON when a millisecond measurement is absent; an existing millisecond value,
including zero, takes precedence. This elapsed time includes native preparation
and verification and is not a compiler-only timing.

Native targets build on the host their source was synced to. Manifest artifacts
and build-environment receipts retain the native task's selected triple; flat
raw payload names are qualified when needed, while archive members keep the
configured executable name.

Every native Unix compiler program runs inside a host-side process supervisor
requiring Python 3.9+ with POSIX process-group support. Its private group is
retired on completion, timeout, cancellation, or output-transport loss; an
independent anchor also enforces the deadline or notices a killed supervisor.
The normal build exit status and stdout/stderr are preserved. Timeout returns
124 from the host guard. The outer transport receives ten extra seconds for
cleanup, while the host deadline remains the configured build timeout. Builds
receive EOF on stdin. A missing host runtime returns dependency error 3 before
the compiler runs. Commands that deliberately detach into a new session are
outside this process-group boundary. Strict Rust still requires Python 3.11+.

Native Windows guards retain the complete compiler program as `payload.ps1`
beside the staged launcher and start PowerShell with a quoted `-File` path.
The program's size therefore does not become a child command-line argument.
The payload is created exclusively, flushed, scanned with the existing Defender
policy, and checked against its original bytes under a held read handle before
launch. Directory-chain handles prevent ancestor substitution during execution;
linked files, reparses, conflicting existing payloads and changed bytes are
refused. The file preserves Unicode with a UTF-8 BOM and remains as attempt
evidence. The child still starts suspended, enters its owned kill-on-close Job
Object, and only then resumes. Normal exit status is preserved; the host-side
deadline returns 124 after stopping the job.

The manifest also retains `requested_targets` when supplied by the orchestrator.
For native matrices, both generation and release admission reconcile selected
triples, environment receipts and retained payloads. A missing or duplicate
variant is refused before any GitHub mutation; explicit act receipts continue
to support one workflow job producing cross-platform assets.

When a repository opts into `release_contract`, DSR creates a new empty draft,
uploads only the contracted primaries, their checksum sidecars, the regular
files explicitly listed by the optional `exact_additional_assets` array, and
the generated build manifest under the one or two literal `.json` names in the
optional `build_manifest_assets` array (bound to the frozen manifest's SHA-256
and size; the build manifest is not published otherwise). Every
planned file is bound by exact basename, byte size, and SHA-256 before upload;
unsafe names, case-fold collisions, symlinks, missing files, and unlisted remote
assets fail closed. Publication occurs only after exact no-cache asset,
metadata, and tag-SHA verification. `--draft` keeps that verified draft
unpublished and suppresses dispatch and upgrade hooks.

Strict native builds trust the configured build host and its installed
compiler, linker, and Cargo subcommands. DSR isolates Cargo configuration and
records the explicit build-influence environment. Native Rust builds use
independent Cargo homes. Strict Unix and Windows builds copy dependency inputs
selected by the committed `Cargo.lock`: checksum-matching archives, corresponding sparse index
records or matching legacy Git indexes, and Git databases containing pinned
commits. Cargo recreates extracted registry sources and ordinary Git checkouts
offline; ambient `registry/src` trees and unrelated Git checkouts are not opened
or copied, and unmatched crate archives do not enter the seed. A locked Git
commit with submodules additionally retains only its matching checkout, selected
by its exact HEAD, including self-contained nested Git stores needed for offline
resolution. Source authentication subsequently binds every child commit to its
parent's authenticated gitlink before seed admission. Candidate Git databases are
examined for locked revisions, and selected index storage is validated; unsafe
download candidates can still refuse preparation. A lockfile without Git
dependencies does not inspect the Git cache. Selection conservatively covers
all lockfile packages, not a minimal
target/feature graph, and selected Git databases/indexes retain their history.
Ordinary native Unix and Windows builds also select downloads from the source
workspace's `Cargo.lock` when it exists. An existing malformed or linked lockfile
refuses preparation; only an absent lockfile permits the unscoped private cache
snapshot. The selected lockfile digest is retained in the seed receipt. Ordinary
builds may fetch missing dependencies into their private home and do not gain
strict source-authentication authority from this cache selection.
Metadata and target attempts never compile through ambient cache symlinks or
Windows junctions. Strict metadata admits a retained seed only after successful
locked offline resolution and source authentication; retained seeds contain
the selected downloads and any necessary locked submodule checkouts. Ordinary
sources unpacked by metadata do not enter the seed. Retries verify the retained
inventory and original
lockfile selection before making another private copy. Windows holds the physical
lockfile against replacement or writes through metadata and seed admission.
The selected lockfile hash must match the authenticated source lockfile hash
before seed publication and controller admission. The selection kind,
lockfile hash, registry-package count and Git revisions are retained in the
seed summary under `cargo_isolation.dependency_cache.seed.selection`.
Collection requires the original seed-receipt digest and a valid final inventory,
retained under `cargo_isolation.dependency_cache` with `cache_reuse: []`.
Windows uses PowerShell 7 and native NTFS handles, rejects reparses and external
private-cache hardlinks, and records drive-qualified forward-slash paths.

Strict native Unix and Windows builds authenticate resolved dependency sources against
the workspace's committed `Cargo.lock` before admitting a reusable seed. Registry
archives must match their locked SHA-256 checksums, and their extracted files must
match the archive. Git checkout files must match the locked commit's Git objects.
Git submodules are authenticated recursively against the commit recorded in the
parent tree, with a maximum depth of 16 and a shared 500000-entry limit on Windows.
Every nested checkout must have its own regular `.git` directory and internal
object store. External administrative pointers, alternates, missing commits,
unlisted nested repositories and modified source bytes are refused. Windows
dependency symlinks and reparse points remain unsupported.
The gate follows the all-features metadata graph from every workspace member,
including members outside the default selection; unrelated cached packages do
not become source inputs. Vendored sources must remain inside the primary
workspace and use its separately verified committed snapshot as their authority.
This requires Python 3.11 or newer on Unix, or PowerShell 7.4 or newer on native
Windows. Windows uses .NET archive/JSON readers and held NTFS handles, refuses
reparse points, ambiguous paths and case-colliding archive members, and supports
Cargo-generated version 3/4 lockfiles. Unused patch records are parsed but never
contribute resolved-package authority. No Python installation is needed on the
Windows build host.

Strict native source export checks the ordinary Git tar stream against the
selected committed tree before choosing the transfer bytes. Complete archives
retain their existing bytes and hashes, including when export attributes have
no effect. When Git export attributes omit or substitute committed content,
the coordinator uses its authenticated raw-object exporter to retain the
complete source inventory and original blob bytes. Archive generation or
parsing failures refuse export; they do not authorize a fallback. The comparison
streams file contents without an additional archive spool. Staging, relocation,
final verification and exact-run resume derive the same selected archive hash.

Strict native project snapshots expand initialized submodules recursively from
the gitlink commits in their parent trees. The coordinator's shared Git object
reader authenticates every commit, tree and blob, then streams a deterministic
tar archive without copying mutable working-tree bytes or applying Git export
attributes. The original three-column manifest retains each `160000` repository
boundary and includes every selected child file. The coordinator-held archive
and manifest hashes continue to bind staging, independent final verification
and recovery; recovery reconstructs the same bytes from the pinned objects.

Self-contained child `.git` directories and ordinary absorbed submodules whose
administration remains inside their parent's `modules` directory are supported.
External administration pointers, alternates, linked object stores, missing or
wrong-type objects and configuration includes are refused. No submodule URL is
fetched, and a child HEAD cannot override its parent's selected commit. Each
source archive has a shared limit of 100000 Git tree entries, 256 repositories
and 16 nested submodule levels. Archive selection and recursive export require
Python 3.9+ on the coordinator; they add no Python requirement to Windows build
hosts.

The Unix and Windows receivers admit only the manifest's exact directory and
file inventory, including empty nested submodules. Links cannot leave their
nearest repository or enter another submodule, even temporarily before `..`.
Unix retains contained tracked file or directory links; Windows retains its
regular-file materialization policy. Unlisted descendants and changed blobs
refuse staging or artifact collection, as do changed executable modes on Unix.

Strict native Windows project snapshots also support tracked file symlinks
such as `CLAUDE.md -> AGENTS.md`. A relative link must resolve, with exact
case, to a regular file present in the same tracked manifest. The extractor
authenticates both the original Git link blob and its referent, then creates a
regular file copy. It never creates an NTFS reparse point or requires symbolic
link privileges. The original archive and three-column Git manifest remain
the source authority; the derived materialization plan records the link path,
link blob, target text, referent path/blob and copied byte count.

Absolute links, links escaping the source root, directory links, link chains,
cycles, missing referents and ambiguous Windows names are refused with the
offending path. Every extraction and independent source verification uses the
same PowerShell 7.4+ archive reader and checks all file contents and the exact
directory inventory. Configured split-storage admission charges the full
expanded size, including each link copy, before writing source payloads.
Changing either the original evidence or a materialized copy refuses the
build or artifact collection. This project-source support does not relax the
separate Cargo dependency-cache reparse policy.

The coordinator retains metadata and source-evidence SHA-256 hashes under
`cargo_isolation.dependency_sources`, together with the lockfile hash and counts
of archive, Git, and workspace-snapshot authenticated packages. Full inventories
remain in each attempt's private Cargo home. Verification checks both held
hashes and the current authenticated source trees before project compilation and in an
independent invocation before artifact collection. Rewriting a remote receipt,
changing metadata, or modifying a dependency during the build refuses collection,
independently of the build shell's postamble. Failed first admission does not
publish a seed or start project compilation; a later attempt can use repaired
ambient downloads. An already admitted seed is verified and never replaced in place.

Strict Windows Cargo metadata and compilation share a native system CMD
launcher (`/d /v:off /s /c`), working directory, and sanitized configured
environment. Configured names are case-insensitive with last-assignment
precedence; the private `CARGO_HOME` and both RCH bypass flags are enforced.
The same SDK cleanup applies to both operations. CMD performs executable
lookup for both, including current-directory and `PATHEXT` behavior.

The supported Windows command is one foreground literal invocation of Cargo's
`build` or `rustc` subcommand, optionally preceded by `+toolchain`. The literal
toolchain reaches metadata as well as compilation. An explicit `--target`
overrides `CARGO_BUILD_TARGET` and becomes metadata's `--filter-platform`;
without an explicit command/environment target, metadata conservatively leaves
the graph unfiltered. Metadata always retains `--locked --offline --all-features`
for source closure. This is command/toolchain-context agreement, not a claim
that the build and metadata have identical feature graphs.

Whole-argument double quotes support literal paths and values containing spaces.
Shell chains, expansions, redirection, metacharacters (including parentheses),
quote concatenation such as `--features="a b"`, `--config`/`-C`/`-Z`, Cargo
plugins, a non-root manifest, and `rustc` argument tails after `--` are refused
before a dependency seed is admitted. Use `--features "a b"` and put compiler
configuration in the configured build environment or tracked Cargo configuration.

Each successful metadata attempt retains `.dsr-cargo-context.json` inside its
private Cargo home. It binds the original build command, selected metadata
command, source/home paths, relevant environment (including lookup controls and
all configured names), Cargo manifests/configuration, toolchain selection files,
rustup settings, and the measured executable identities through hashes.
Environment values and command text are not stored in the context receipt.
The coordinator holds the context fingerprint and receipt digest; the native
build checks them before and after compilation. An independent final request
constructs the same context and checks it before and after source/cache admission.
Drift refuses artifact collection. The three-field summary survives in target
state and `build_environments[].cargo_isolation.cargo_context`.

`cargo_isolation.toolchain` retains the selected Cargo, rustc and linker paths,
SHA-256 hashes, executable kinds and reported versions, selected target, rustup
selection and tracked Cargo configuration hashes. Rustup proxies also retain
their resolved executable paths and hashes. A selected proxy must be byte-identical
to a separately located Rustup manager. A matching host installation reference
can recognize a copied proxy whose manager is hidden by the configured build
PATH; reference discovery does not alter executable lookup for the build.
Version responses or a renamed copy cannot independently prove Rustup identity.
A sibling copy named `rustup` alone is not a host installation reference.
The manager's resolved file must also be named `rustup` or `rustup.exe` so its
own program name selects manager dispatch. An unrecognized program cannot claim
Rustup resolution evidence, and explicit `+toolchain` commands require that
evidence before dependency admission. The full identity is part of
the retained context receipt and survives public build JSON, completed state
and manifest projection. Windows paths use drive-qualified `C:/...` spelling.
An absent or malformed executable identity refuses project compilation. Before
dependency metadata, the selected rustc performs a small link outside the source snapshot to identify its default
linker; a Windows linker that does not resolve to an absolute path requires an
explicit target linker. These probe files remain beside the private Cargo home.

Windows attestation requires native executable Cargo/compiler/linker selectors;
script wrappers and Cargo plugins are outside this boundary. Tracked Cargo
configuration uses a bounded literal grammar for build/compiler settings,
literal target settings, ordinary source/registry settings and Rust flags.
Includes, dotted keys, general inline tables, unsupported `cfg(...)` predicates, general environment
injection, unstable selector environments and flags that can select another
linker/compiler/backend are refused before dependency admission. The supported
`[env]` exceptions are positive-integer strings for `RUST_MIN_STACK` and
`RUST_TEST_THREADS`, and exactly the string `"0"` for `CARGO_INCREMENTAL`.
These accept a literal string or a single-line inline table with `value`,
optional Boolean `force`, and absent or false `relative`:

```toml
[env]
RUST_MIN_STACK = { value = "16777216", force = true }
RUST_TEST_THREADS = { value = "4", force = false, relative = false }
CARGO_INCREMENTAL = "0"
```

Existing configured environment values take precedence unless `force=true`.
Both configured and effective values must satisfy the same name-specific
restriction. For `CARGO_INCREMENTAL`, numeric zero, `"1"`, whitespace,
invisible suffixes and alternate zero spellings are refused. Cargo
reads its own incremental mode before applying `[env]` to children, so a
nonzero or malformed incoming `CARGO_INCREMENTAL` refuses admission even when
the tracked table says `force=true`. A tracked `"0"` alone does not override
the profile's incremental setting; set `CARGO_INCREMENTAL=0` in the build
environment to disable incremental compilation in Cargo itself. The observer
uses the same effective settings as Cargo's children and retains the configured
value, force flag, effective value and origin in
`toolchain.selection.cargo_config[].env_exemptions`. Metadata, compilation and
independent collection bind this evidence. Unknown or duplicate attributes,
relative-path expansion, non-Boolean flags, multiline tables and trailing
commas are refused; this exception does not admit compiler environment changes.

Cargo's `[build] incremental=false` also disables incremental compilation when
there is no overriding parent `CARGO_INCREMENTAL`.
The exemption and its receipt describe the effective child environment; they
do not certify that Cargo emitted no incremental artifacts. See Cargo's
[`env` configuration](https://doc.rust-lang.org/cargo/reference/config.html#env)
and [incremental setting](https://doc.rust-lang.org/cargo/reference/config.html#buildincremental).

Tracked target tables can use bounded `cfg(...)` expressions on Windows as well
as Unix. Supported predicates are `unix`, `windows`, and literal values for
`target_arch`, `target_os`, `target_env`, `target_vendor`, `target_family`,
`target_endian`, `target_pointer_width` and `target_abi`, combined with `all`,
`any` and `not`. DSR queries the selected, hashed native compiler with
`rustc --print=cfg --target <triple>` and records the compiler identity, target
facts, matching and nonmatching tables, and effective flags in
`toolchain.selection.cargo_target`. Tables for another platform are valid and
do not contribute flags. Custom, feature, profile and build-script predicates
remain outside this boundary; every expression and flag contribution is
validated, including inactive branches.

Cargo's effective flags retain their normal precedence: an existing
`CARGO_ENCODED_RUSTFLAGS` overrides `RUSTFLAGS`, which overrides target flags,
which override build flags. An explicitly empty encoded or ordinary flag
variable still overrides configuration. Target flags combine the exact target
table, its `CARGO_TARGET_<TRIPLE>_RUSTFLAGS` value, and matching cfg tables in
Cargo's ordinal order. Build flags combine the build table and
`CARGO_BUILD_RUSTFLAGS`. A target linker environment value overrides the exact
target table, which overrides a matching cfg linker; multiple matching cfg
linkers without a higher-priority selection are refused. Changing the cfg
configuration or selected compiler invalidates the held metadata receipt.

On both Unix and Windows, configure the linker through the explicit target key
so its selected executable is resolved and attested. Move a
`-C linker=cc` or `--codegen linker=cc` selection out of `rustflags`, for example:

```toml
[target.x86_64-unknown-linux-gnu]
linker = "cc"
rustflags = ["-Z", "threads=4", "-C", "link-arg=-B/usr/bin"]
```

The remaining flags still need the selected compiler's normal support. Linker
selection inside `rustflags` remains refused even when it spells the default
linker; naming `cc` alone does not establish its executable identity.

Configured compiler
or linker paths must be absolute, or project-relative paths in tracked Cargo
configuration. PATH entries must be drive-qualified absolute paths; known
ambiguous compiler lookup locations are refused. Configured
`RUSTUP_FORCE_ARG0` dispatch overrides are refused. Configure a nondefault
`RUSTUP_HOME` explicitly instead of relying on an ambient Rust selector.
Ambient MSVC `LINK` and `_LINK_` argument variables are removed before metadata
and compilation. Explicit build-environment values remain supported and are
included in the admitted context digest; changing either value prevents
collection. Executable probe failures retain their nonzero status and bounded
stdout/stderr diagnostics, including LINK errors emitted on stdout.
Evidence consists of selected Cargo, compiler and linker file hashes, versions,
and probe results, including recognized Rustup dispatch. The native host remains
trusted for launching those files; native executables remain trusted to honor
their arguments and selectors. Their complete loaded-library and subprocess
graphs, including forwarding hidden inside custom native executables, are not
measured.
These receipts assume the native host honestly executes DSR.

On Unix hosts, strict Rust
builds also attest their direct Cargo invocations. Inside the build's own
shell (same working directory, environment and PATH, including DSR's
glibc-floor shim), DSR reads the command's literal `+toolchain` and `--target`
selectors before probing. The command-line toolchain overrides
`RUSTUP_TOOLCHAIN`; the command-line target overrides `CARGO_BUILD_TARGET`.
Quoted literals, the effective `$CARGO_BUILD_TARGET`, and compound commands
with a common Cargo selection are supported. DSR records Cargo and rustc
paths, SHA-256 digests and verbose versions, the selected target linker,
named Cargo plugins, and `cargo-zigbuild`/`zig` when DSR routes through them.
Configuration validation uses this same command-selection parser for literal
GNU ABI requests, so `config validate`, build, and release admit the supported
explicit form before staging. Configured target maps and target environment
variables keep plain Rust identities; they never acquire a glibc suffix.
Explicit GNU ABI requests such as
`cargo +nightly zigbuild --target=x86_64-unknown-linux-gnu.2.28` retain
`x86_64-unknown-linux-gnu` as their Rust target, configuration lookup key and
artifact directory. The exact requested `zig_target`, `rust_target` and
`glibc_floor` are retained separately in `selection.cargo_zigbuild`, matching
`selection.dsr_cargo_shim`. Only a direct `zigbuild` command with a literal
GNU target and `MAJOR.MINOR` suffix receives this interpretation; other
subcommands, non-GNU targets, malformed versions and conflicting command-list
selections refuse admission. Both `--target VALUE` and `--target=VALUE` work.

Strict explicit Zig builds, including unversioned GNU and musl targets, use
the same generated Cargo dispatcher as managed glibc-floor builds.
An unversioned invocation retains the plain target in both `rust_target` and
`zig_target`, with `glibc_floor: null`; DSR adds no ABI suffix or floor.
Its exact generator bytes are verified before
tool lookup; it preserves explicit Zig arguments and pins the absolute Zig
executable selected on the delegated PATH. Caller `CARGO_ZIGBUILD_*` dispatch
overrides, including empty values, are refused. Cargo global-option prefixes
and `+toolchain` retain their argument boundaries. Record, cache and pre/post
build verification require this dispatcher; metadata-only admission uses
ordinary locked/offline Cargo metadata and does not compile through Zig.
Changing the requested target or floor, dispatcher, plugin or compiler
invalidates the held receipt. The exact request, including an absent floor,
also remains in the strict cache key. This binding prevents cargo-zigbuild's
Python-first discovery from executing an unobserved `ziglang` module even
when a different, hash-verified Zig executable is available on PATH.

The requested Zig version is separate from the configured
`linux_glibc_floor` ceiling on collected ELF requirements. A request for
2.17 may satisfy a configured 2.28 ceiling; the actual collected bytes must
still pass that ceiling. The
[cargo-zigbuild documentation](https://github.com/rust-cross/cargo-zigbuild/tree/v0.24.0#specify-glibc-version)
describes suffix handling and cautions that Zig can fall back for invalid
versions. An identity receipt therefore records the request and does not
claim that the final binary meets it without the existing artifact checks.

Explicit `RUSTC`/`CARGO_BUILD_RUSTC` executables and compiler wrappers retain
their own identities; arbitrary scripts are not mislabeled as rustup's
compiler. Proven rustup proxies and Apple `/usr/bin` compiler launchers also
record their resolved executable. Unix Rustup recognition requires byte equality
with the existing manager on the build PATH or at `$HOME/.cargo/bin/rustup`.
A mismatched PATH manager cannot hide a matching HOME reference. The physical
manager file and parent are held through dispatch resolution and checked before
and afterward; its path and hash remain in the toolchain receipt alongside the
actual delegated Cargo/rustc hashes. Missing or mismatched references cannot
authorize a receipt containing only proxy bytes. A Rustup dispatch response, or
an unsuccessful check for unresolved dispatch, refuses admission; neither a
version response nor `RUSTUP_FORCE_ARG0` grants identity authority. Configured
`RUSTUP_FORCE_ARG0` is refused. Direct native Cargo/rustc remain supported without
a manager, and the existing reviewed RCH launchers retain their specific dispatch
rules. Arbitrary custom native forwarding and complete subprocess graphs remain
outside this trusted-host entrypoint contract.

Literal tracked Cargo configuration can
select the compiler, target and linker; those configuration files are hashed
into the receipt and require Python 3.11+ to parse. A tracked `[env]` table
that sets any `RUST*`, `CARGO_*`, `XWIN_*`, `PATH` or C toolchain variable is
refused, with three bounded exceptions:
`RUST_MIN_STACK`, which only sizes rustc's and test/run threads' stacks, and
`RUST_TEST_THREADS`, which only sets libtest's default thread count, require
positive-integer strings. `CARGO_INCREMENTAL` accepts exactly the string `"0"`.
They are admitted as plain strings or tables containing `value`, optional Boolean `force`,
and absent or false `relative`. The receipt's `env_exemptions` retain the configured
value/force and effective value, force and origin. Other attributes, invalid
numeric values and other influencing names still fail closed.

For `CARGO_INCREMENTAL`, an incoming process value other than `0` is refused
even with `force=true`: Cargo selects its own incremental mode before applying
the child environment. The tracked setting does not override the selected
profile. A build environment value of `CARGO_INCREMENTAL=0` explicitly disables
incremental compilation. Unix and Windows use the same bounded exemption.

Linker overrides in Rust flags remain outside this exemption. Configure a
literal linker through `[target.<triple>].linker` instead of `-C linker=...`
so DSR can resolve, hash, and verify the selected executable. A program named
`cc` is not assumed to be the default linker merely because of its name.

Strict Unix source-closure validation runs locked, offline, all-features Cargo
metadata with each target's selected toolchain and configured environment.
Targets sharing a host keep their own command overrides. Every native attempt
rechecks metadata compatibility, including when it copies an already admitted
download seed; a successful check with one compiler does not authorize another.
The snapshot and retained seed remain unchanged when a later target refuses.

Unix metadata uses the selected Rust target and the attested compiler host.
For a cross build, both Cargo platform projections contribute to the admitted
dependency inventory, including dependencies used by host build scripts and
procedural macros. Shared package and workspace identities must agree; a
missing or changed host dependency refuses admission just like a target
dependency. The host projection can conservatively include extra host inputs.
An unrelated platform's registry download is no longer required solely to
populate an otherwise unused all-platform metadata graph.

The exact pinned-local-source check remains in force. If a local package in
`Cargo.lock` is absent from the projected inventory, DSR also obtains Cargo's
complete unfiltered metadata. Builds with nonempty Rust flags retain the full
graph: Cargo can apply flags differently to target code and host dependencies,
even when an explicit target matches the compiler host. Compiler wrappers or
effective script launchers, Cargo subcommands other than `build`, generated
Zig builds, and unstable or host-specific Cargo settings also retain the
complete graph. Nonempty Cargo configuration `paths` overrides and a Python
runtime without `tomllib` retain the original unfiltered behavior too. Those
cases still require the full offline dependency inventory. No local package
record is invented from the configured checkout list.

The opt-in `strict_cargo_cache_root` path uses the same selection for version
and capability checks, dependency metadata, and the cache namespace. Explicit
`+toolchain`, `RUSTC`, `CARGO_BUILD_RUSTC`, tracked compiler configuration, and
the effective target linker therefore reach the cache admission checks before
the build command starts. The cache still requires supported nightly
Cargo/rustc with content freshness, refuses build scripts and unsupported
compiler wrappers, and holds custody until fresh final outputs are detached.
Changing a source snapshot's path alone does not invalidate eligible reuse.
Command-scoped assignments cannot override the cache's intermediate directory
or content-freshness controls. Metadata and cache admission accept an explicit
root `Cargo.toml`; a different `--manifest-path` is refused because it would
select a dependency graph outside the validated root manifest.
The supported shell boundary is foreground simple commands joined by `;`,
`&&`, or `||`, with ordinary marker commands such as `printf` and `echo`.
Shell declarations, variable-writing builtins or expansions, append/array
assignments, lookup-changing builtins, compound control flow, and early shell
termination are refused instead of executing a selection the probe cannot
represent. Configure those selections outside `build_cmd`.

Conflicting toolchains/targets, dynamic selectors, Cargo `--config`/`-C`,
compiler-selecting shell context changes, opaque Cargo drivers, Cargo aliases,
configuration includes, unsupported `cfg` predicates, and configuration-driven compiler
environment changes cannot be represented by one proven selection and are
refused before compilation. Move those selections into the repository's
configured build environment or a supported literal Cargo invocation. The
same probe runs after the build; changed executables or configuration refuse
artifact collection. The receipt is bound into the target result and
the manifest as `build_environments[].cargo_isolation.toolchain`. It is
evidence recorded by the build host, not a defense against a host that
rewrites its own executables and receipts, and it does not cover dynamically
loaded libraries or every compiler subprocess. Native Windows hosts still
rely on the trusted-host contract. The tracked `rust-toolchain.toml`, source
revisions, and final artifact hashes remain part of the release evidence.

GitHub does not document a conditional compare-and-swap operation that covers a
release, its assets, and its tag in one transaction. A same-credential actor can
therefore mutate one of those resources between the final read and publish
PATCH. DSR bounds this residual with an exact post-PATCH observation and up to
three observe-after-write re-draft attempts, but a brief exposure or failed
rollback remains possible during a GitHub outage, immutable-release policy, or
concurrent privileged mutation.

---

### `dsr release source-only`

Publish or recover a release with exactly zero uploaded assets. The repository
must explicitly select `publication_mode: source-only` in its `repos.d` entry,
with `tool_name`, `repo` and `local_path`; binary build configuration and a
conflicting legacy registry entry are refused.

```bash
dsr release source-only <tool> <version> --notes-file <file> --no-dispatch
dsr release source-only <tool> --tag <exact-tag> --notes-file <file> --no-dispatch
dsr release source-only <tool> <version> --notes-file <file> --no-dispatch \
  --resume-receipt /absolute/path/to/receipt --publish-draft
```

Choose exactly one version or explicit tag. `--tag` preserves a single Git ref
component starting with a letter or digit and containing only letters, digits,
`.`, `_`, `+` or `-`. The clean checkout, local tag and peeled remote tag must
all identify the same commit. Explicit notes, the configuration and registry
identity remain bound throughout publication and recovery. `--prerelease`
selects prerelease metadata; a retry must supply the same selection.

New releases are created as private, uniquely marked drafts. DSR verifies
their metadata, source identity and empty inventory before publication and
again after publication. `--draft` keeps a verified draft private. Global
`--dry-run` performs admission and recovery checks without a POST, PATCH or
new receipt. Binary artifact, ordinary `--resume`, upgrade and dispatch
options remain unsupported; `--no-dispatch` is required.

`--resume-receipt` accepts a private pending or successful receipt from
`$DSR_STATE_DIR/source-only`. It requires the original creation nonce, inputs,
exact tag/SHA and, when present, exact release ID. The original receipt is
preserved byte for byte. A separate recovery receipt records the result and
its predecessor's digest. New checkpoints retain the verified release ID
before the publication PATCH; retry checkpoints retain a previously verified
ID from their first write. Receipt transitions are atomic and verify the
intended private file bytes and identity through replacement.

Plain recovery preserves a saved draft request. Add `--publish-draft` to
explicitly promote that draft; the option requires `--resume-receipt` and
cannot accompany `--draft`. A pending promotion retains that publication
request for the next retry. An already-public release with saved ID-bound
custody is verified without another creation or publication request, and
verification failure does not return that existing public release to draft.
A legacy pending receipt lacking the release ID can recover its nonce-owned
draft, but cannot establish custody of an already-public release from a tag
lookup. Changed IDs, metadata, source pins or nonempty assets refuse recovery.

Human output prints the recovery receipt path before remote mutation.
Successful JSON reports `details.receipt`, `release_id`, `tag`, `git_sha`,
`draft`, `asset_count: 0`, `requested_draft`, `publication_requested`, and the
predecessor receipt information. Retain these private receipts between attempts.

---

### `dsr installer`

Generate installers, or authenticate and install an exact signed release.

#### Authenticated release commands

```bash
dsr installer generate-release --policy /absolute/policy.json \
  --public-key /absolute/release.pub --output /absolute/install.sh

dsr installer describe-recipe --recipe /absolute/recipe.json

dsr installer describe-host

dsr installer install --snapshot /absolute/snapshot \
  --recipe /absolute/recipe.json --prefix /absolute/prefix \
  --repo OWNER/TOOL --tag v1.2.3 --sha "$SOURCE_SHA" \
  --builder "$BUILDER" --targets "$TARGETS" --public-key /absolute/release.pub
```

These commands use the authenticated release engines' strict argument parsing
and exact identity, target, compiler-variant and trust policy. `install` accepts
either a complete local `--snapshot` or explicit `--fetch`; it authenticates the
complete signed inventory before installing the recipe's executable and runtime
data set. Changing an existing managed generation requires `--replace`.
Recipe inspection validates policy and reports `authenticated: false`.
Host inspection reports the physical platform and, on Linux, GNU/musl runtime
evidence without reading credentials, downloading assets, or changing an installation. An
unknown C runtime is reported as `libc: "unknown"`. Generated release installers
use this shared observation to choose between an embedded standard GNU/musl
recipe pair; unresolved or nonstandard matrices require `--target-triple`.
See [authenticated installation](RELEASE_INSTALLATION.md) for the snapshot,
recipe, independent contract and activation requirements.

With `--fetch`, `--download-cache DIR` opts into the shared resumable acquisition
engine. `DIR` is the exact persistent snapshot destination and its parent must
exist. The destination, adjacent `.partial` checkpoint and `.lock` must be
canonical and disjoint from the installation and policy inputs. Retries authenticate current remote proof
and every retained payload before downloading missing assets. Changed policy,
key, release generation or inventory refuses reuse; no cache is silently
repaired or treated as offline authority. The result's `download.acquisition`
reports reused and newly downloaded payload counts outside generation identity.
The option is rejected with `--snapshot`; generated standalone release installers
accept the same runtime option. With explicit cache selection, `--dry-run` may
write download storage and its lock while leaving installation state unchanged.

Both global `--dry-run` and command-local `--dry-run` are supported for
`generate-release` and `install`. Generation validates the policy, key, captured
engines, recipes, resulting script and existing-output conflict before returning
a plan. It does not create the selected output or its adjacent lock. Installation
planning authenticates and extracts into private staging without activating a
generation or changing the managed prefix. With `--fetch`, planning still fetches
and authenticates the exact release. A plan is an observation, not a reservation;
execution repeats the validation and concurrency checks.

With global `--json`, the command emits one standard envelope with
`command: "installer"`. `details.action` identifies `generate-release`, `install`,
`describe-recipe` or `describe-host`; all authoritative engine fields remain in `details`,
including `status`, `activated`, `authenticated` and any reported error. The
envelope exit code matches the process result. A successful plan has outer
`status: "success"` and `details.status: "planned"`; it does not claim activation
or authenticated generation. Help is returned as help text within the envelope.
See [standalone release installers](GENERATED_RELEASE_INSTALLERS.md) for pinned
generator policy and distribution trust.

#### Registered-tool installer generation

```bash
dsr installer generate <tool>... [--output-dir DIR] [--dry-run]
dsr installer generate --all [--output-dir DIR] [--dry-run]
dsr installer validate <tool>... [--output-dir DIR]
```

Generation writes `<output-dir>/<tool>/install.sh`; the default directory is
`installers/` beside dsr, overridden by `DSR_INSTALLER_DIR` or `--output-dir`.
The generated script embeds the tool's artifact naming, targets, verification
key, source settings and executable selection. Regenerate it after changing
those settings. Validation checks syntax, ShellCheck and required safety
elements. Configuration errors exit 4; a failure affecting some tools exits 1.

When `release_contract` is present, generation validates and embeds the exact
platform/triple asset inventory. A selected variant resolves its literal
`exact_primary_assets` name before any cache lookup or download. The exact
extension selects gzip (`.tar.gz` or `.tgz`), xz (`.tar.xz`), ZIP (`.zip`), or
otherwise a raw executable. This selection is repeated for each permitted
libc fallback candidate, so an archive and a raw executable can coexist in one
matrix. Ordinary naming templates and compatibility aliases do not replace
these exact names. Checksums and configured signatures verify the selected
asset, and variant cache entries remain separate. Integrity failures never
trigger another candidate.

An omitted singleton target triple uses the standard platform default.
Singleton Rust compiler-target overrides must have a matching explicit
`target_triples` entry; conflicting overrides fail generation. The generated
runtime table requires no jq or yq on the installing machine.

For a generic native Go release, an effective `CGO_ENABLED` value of `"0"` or numeric
`0` declares a build without C-library dependencies. Generation merges global
`env` with `cross_compile.<platform>.env`, with the platform value taking
precedence. Only targets routed to native builds qualify: their `act_job_map`
entry must be absent, empty, or null. Mapped act jobs control their own workflow
environment and cannot inherit this declaration from native build settings;
a `cross_compile.<platform>.method` hint does not override that routing.
When there is no explicit target triple or strict release
contract, automatic installation can select that platform's release on GNU,
musl, or a host with unknown libc. An explicit `--libc` remains exact.
Inline CGO/GOFLAGS overrides and shared build modes disable this inference.
The archive, checksum and signature cache uses a separate `cgo-disabled`
platform suffix; existing generic cache entries are not adopted under the
new policy. Release integrity checks and source-build consent are unchanged.

The generated installer's executable selection follows `workspace_binaries`
and `workspace_binaries_by_target`. An explicit platform override replaces
the global list, including an empty override. An empty or absent effective
list selects only `binary_name`. Each nonempty list must contain that primary
executable. Names must be safe basenames; Windows names are normalized to one
`.exe` suffix and cannot collide when compared without case differences.
Release installation does not require jq to select or install the set.

After checksum and configured signature verification, the installer requires
exactly one nonempty regular archive member for every selected executable.
Missing, duplicate or unsafe members fail before any installed executable is
replaced. All new payloads and backups are staged on the destination filesystem
before replacement starts. A handled replacement failure restores the touched
destinations; unrelated files are preserved. This is a sequence of file
replacements with rollback, not one filesystem transaction over the entire
directory. If recovery itself fails, the installer reports failure and retains
its backup directory for recovery.

Successful installer `--json` output retains the primary `path` and adds
`binaries: [{name, path, sha256, size_bytes}]` for the complete installed set.
It emits one result object. Failed installation emits an error result and
does not report a partially installed set as success.

Rust source fallback selects the same executable set with repeated Cargo
`--bin` arguments in one locked build. Multiple selected binaries use the
workspace unless `source_package` restricts the build to one package. Each
selected output must have exactly one Cargo compiler-artifact provider;
successful Cargo exit status alone does not admit colliding package outputs.
All members share the verified source commit. Source receipts include every
member's hash and size while preserving the primary receipt fields. Source
builds require explicit consent through `--from-source` or
`--allow-source-build`; Go and Bun source fallback accepts only a singleton
selection. Integrity or installation failures never trigger source fallback.

Source checkout uses the same GitHub identity as release acquisition and
freshness: `DSR_GH_TOKEN`, `GITHUB_TOKEN`, `GH_TOKEN`, then stored GitHub.com
credentials. A selected credential is supplied only to the exact repository's
HTTPS requests through Git's process-local `--config-env` support, requiring
Git 2.31 or newer. Tokens never enter URLs, command arguments or persisted Git
configuration. Authenticated checkout disables ambient URL rewrites, competing
credential helpers, redirects and Git tracing, and an invalid token cannot use
another `.netrc` account. Without a selected GitHub credential, the existing
Git-only anonymous and custom-helper path remains available. The selected
source ref is still resolved to an exact commit before compilation.

`--install-toolchain` separately authorizes provisioning a missing compiler for
the selected source build. It requires `--from-source` or
`--allow-source-build`; `--yes` alone does not enable it. Rust, Go and Bun use
private toolchain directories and verified official distributions on Linux or
macOS, x64 or ARM64. Existing usable compilers remain in use. Windows source
builds require a preinstalled compiler. Safe, offline, and required-signature
source restrictions still apply. The source receipt records the selected
toolchain and distribution evidence when provisioning occurs. See
[installer generation](INSTALLER_GENERATION.md) for pinning and verification.

---

### `dsr docker`

Build, publish, sign, verify and repair container evidence through the shared
container module parser.

```bash
dsr docker build TOOL VERSION --repo-path /absolute/project \
  --dockerfile docker/Dockerfile --output /absolute/image.oci.tar
dsr docker release TOOL VERSION --repo-path /absolute/project \
  --platform linux/amd64,linux/arm64 \
  --certificate-identity "$SIGNER" --certificate-oidc-issuer "$ISSUER"
dsr docker verify "$PINNED_IMAGE" --platform linux/amd64,linux/arm64 \
  --certificate-identity "$SIGNER" --certificate-oidc-issuer "$ISSUER"
dsr docker attest "$PINNED_IMAGE" \
  --certificate-identity "$SIGNER" --certificate-oidc-issuer "$ISSUER"
dsr docker sign "$PINNED_IMAGE"
dsr docker setup --dry-run
```

`PINNED_IMAGE` is an independently selected `REPOSITORY@sha256:DIGEST`.
`build` forwards explicit context, Dockerfile, platform, repeated tag and output
options to the module. `release` uses registry export and retains every digest,
platform, signer, SPDX and final inventory verification gate. `verify` checks
published evidence without building, scanning, logging in, signing or uploading.
`attest` regenerates and verifies per-platform SBOM attestations, but reports the
root signature as `not_checked`; a subsequent `verify` checks that signature.
`sign` alone reports signing without claiming independent signature verification.

Global and command-local dry runs validate and return plans without Docker,
registry, scanning, signing, builder setup or output publication. In particular,
`setup --dry-run` does not inspect, create or bootstrap a builder. Planning does
not establish registry access or credential validity. Missing option values and
unexpected positional arguments fail with exit code 4.

Global `--json` returns exactly one standard envelope using the command name
`docker-build`, `docker-release`, `docker-sign`, `docker-setup`, `docker-verify`
or `docker-attest`. `details.result` preserves the complete module receipt;
`details.status` and `details.dry_run` identify its operation state. Successful
plans use outer `status: "success"` with `details.status: "planned"`; completion
fields such as `pushed`, `signed` and `ready` remain false. Failures preserve the
module's nonzero exit status and do not claim completed publication or verification.
See [container workflows](CONTAINERS.md) for the full exporter, evidence and trust
contracts and the standalone module entry points.

---

### `dsr fallback`

Full fallback pipeline: check -> build -> release.

```bash
dsr fallback --repo <name> [--version <tag>]
```

This is the main command for automated fallback. Equivalent to:
```bash
dsr check --repo $REPO && dsr build --repo $REPO && dsr release --repo $REPO
```

The check step records why the fallback ran (`details.trigger`, e.g. "release
workflow throttled: 1 run(s) over 600s"); it does not block a fallback that was
asked for, since `dsr check` itself exits 1 exactly when throttled. Its step
carries `throttled` and the check's own exit code. The build step covers the
quality gate, build, artifact verification and signing; `--build-only` runs
the build step alone. `details.steps[]` lists the steps that ran.

`--resume=RUN_UUID` accepts a saved `partial` build as well as failed or
interrupted builds. It retains the original run UUID and output directory,
validates the saved source and successful target artifacts, and retries only
targets that remain eligible under the existing attempt budget. A partial
checkpoint does not bypass the build step or authorize publication; release
still requires a complete, validated successful build. Cancelled or unknown
checkpoint states are refused before execution.

Completed-build reuse also requires the saved repository recipe digest before
isolated source materialization, quality hooks, signing, or publication. It
rechecks the same bytes after quality hooks and before the release handoff;
bypassing the worker scheduler does not bypass recipe admission.

The release step succeeds only when `dsr release` confirms the requested
repository and tag as public. An upload that correctly leaves an unrelated
or explicitly requested draft private returns fallback exit `7`, so an
automatic watch attempt cannot be marked complete while its downloads remain
unavailable. Retrying an ordinary publication with `--resume` uses its retained
creation intent to finish an owned interrupted draft; it cannot publish an
unrelated draft.

Strict fallback retains a private, build-bound publication handoff before draft
creation. `--resume=RUN_UUID` reuses its completed build, original creation
response, signed asset plan, and canonical output directory. It verifies fresh
release metadata and every existing asset before uploading only missing assets,
then invokes `release finalize --no-dispatch` and verifies its success receipt.
Already-public retries require complete verification. Changed or ambiguous
custody, changed source/configuration/artifacts, unexpected assets, or missing
original POST responses block recovery; no remote asset is replaced or deleted.

`details.publication_recovery` exposes the `build_run_id`, private `intent`,
creation custody when available, release ID, and finalization receipt. Its
status is `prepared`, `ready`, `blocked`, or `finalized`; `ready` identifies
recoverable custody and does not claim publication. Preserve the complete state
and original output directory. Automatic strict recovery inherits the
finalizer's configuration restrictions, documented in the
[recovery guide](NATIVE_RELEASE_RECOVERY.md#resume-an-interrupted-strict-fallback-publication).
Strict inventory verification and recovery paginate the complete assets
endpoint, including the terminal page after an exact multiple of 100 assets.
Later-page errors, malformed records, and duplicate IDs or case-insensitive names
block publication. The observation limit is 100 pages, with a required short
terminal page; the existing 1 MiB private receipt limit still bounds recoverable
plans.

Fallback accepts the same `--sbom`, `--no-sbom`, and `--sbom-format` policy as
ordinary release and forwards it to publication. Build-only runs do not scan.

`--expected-sha <full-commit>` binds a fallback to an observed workflow run.
It requires an explicit `--version` and a nonzero 40-character commit SHA.
By default, before creating build state, the checkout's HEAD and the exact local version
tag must both resolve to that commit, with no tracked or untracked changes.
The same source check runs after quality checks, after the build and before
publication; the successful build manifest must also name that commit.
Immediately before publication the GitHub tag must still resolve to the same
commit. An unavailable remote lookup returns `8`; a changed tag returns `7`.
Build-only runs omit this remote lookup and remain usable without GitHub access.
Replacement Git objects cannot change this identity. A mismatch prevents
publication and is reported with `details.expected_sha` in JSON output.
This option verifies an existing checkout; it does not switch branches or
discard local changes. Manual fallback retains source-version detection when
the option is omitted.

Add `--isolate-source` to recover a queued release even when the configured
checkout has advanced or contains work in progress:

```bash
dsr fallback tool --version v1.2.3 --expected-sha <full-commit> --isolate-source
```

The watcher can use this behavior without additional flags when the tool's
`repos.d/<tool>.yaml` contains:

```yaml
fallback:
  isolate_source: true
```

Isolation requires the explicit version and expected SHA. It creates a private
detached Git repository under `fallback-sources/` in the state directory,
copies the exact committed objects and annotated release tag when available
locally, and otherwise fetches that exact tag from the configured GitHub
repository into private storage. The fetched tag must peel to the expected
commit. Credentials, Git hooks, custom filters, and repository configuration
are not copied. The configured checkout's branch, refs, index, tracked edits,
and untracked files remain unchanged.

Quality checks, build workers, archive includes, and release verification all
use the private source. Configured sibling crates must have exact `revision`
pins and distinct `relative_path` names; their committed sources are copied
beside the main source and checked again at every fallback boundary. Unpinned
siblings are refused. Initialized Git submodules in the main repository or a
pinned sibling are supported recursively. Each parent's authenticated gitlink
selects the child commit; a newer or dirty child checkout cannot replace those
committed bytes. Ordinary absorbed submodules with administration contained in
their parent's `modules` directory and self-contained child `.git` directories
are accepted. Private children receive independent object stores, detached
HEADs and fresh configuration, preserving the developer's child refs, index,
configuration and work. Submodule URLs are never fetched, including when the
main release tag was fetched; absent child checkouts or missing pinned objects
remain errors. External administrative pointers, alternates and linked object
stores are refused. This uses the existing authenticated source reader with
Python 3.9+ and limits of 100000 tree entries, 256 repositories and 16 nested
submodule levels per source graph. Existing strict source and artifact admission
rules still apply.
Cargo manifests and configuration must use relative dependency/workspace
paths. Isolation parses committed TOML throughout the root and child repositories
with yq before quality checks and
refuses absolute paths, including escaped and multiline spellings, rather
than rewriting files covered by the pinned commit. A yq version with TOML
input support is required when these files are present.

Every fallback boundary verifies child HEADs, indexes and committed bytes
again, independently of parent submodule-ignore settings. Ordinary native
staging restores a separate Git context for each selected child, so child
build scripts can read their exact pinned Git metadata. Source-sync receipts
retain these contexts in `submodule_git_contexts`, separately from configured
sibling identities, and validate their paths and identities on every receiver.

Ordinary act workflow targets also receive configured pinned siblings. Each
attempt materializes independent private sibling repositories and projects the
workflow's selected job and local `needs` jobs with literal read-only container
volumes beside the main workspace. Docker actions inherit the same volumes.
The original workflow, Cargo manifests, and developer checkouts are unchanged.
Existing runner images and effective container options are preserved; ambiguous
container declarations, reusable selected jobs, conflicting path/mount options,
and host execution that bypasses mounts are refused before execution. See
[pinned workflow sources](ACT_COMPATIBILITY.md#pinned-sibling-sources-in-workflow-builds)
for the supported shapes.

The existing build checkpoint records a `workflow_source` identity in each
affected task, including the original workflow hash and sibling pins. Target
results retain `source_layout` evidence with the projected workflow hash and
recursive private graph. Both execution boundaries, manifest admission, and
resumed output reuse verify this evidence. Changing the pinned source or
workflow requires a new run; a successful receipt without its original layout
evidence cannot authorize reuse.

Each retry creates a fresh controller source copy while resuming the selected
build UUID and its original output directory. Source copies and partial failed
materializations are retained for inspection; `details.source_materialization`
records the private root, source/tag identities, transfer method, pinned
dependencies and selected submodule commits/trees. `--dry-run` plans isolation without creating directories or
fetching. `--build-only` remains offline when the pinned source objects are
available locally; otherwise source materialization itself requires GitHub.
For an ordinary build with pinned siblings or submodules, resume also requires
matching original synchronization evidence and successful target receipts,
including retained history and sidecars. Submodule-bearing runs retain their
path-independent main, sibling and recursive child identities in the existing
source-sync checkpoint and each target receipt, including act-only runs that
need no native transfer. Changed pins or older checkpoints without that graph
evidence require a new build and exit 4; existing artifacts cannot be relabeled
with a newly materialized dependency or child revision.

---

### `dsr repos`

Manage repository registry.

```bash
dsr repos list [--format table|json]
dsr repos add <owner/repo> [--local-path <path>] [--language <lang>] [--dry-run]
dsr repos remove <name> [--dry-run]
dsr repos validate [--repo <name>]
dsr repos discover [--org <name>] [--language <lang>]
dsr repos sync [--dry-run]
```

| Subcommand | Description |
|------------|-------------|
| `list` | List all registered repositories |
| `add` | Add a repository to the registry |
| `remove` | Remove a repository from the registry |
| `validate` | Validate repository configurations |
| `discover` | Discover repositories that could benefit from dsr |
| `sync` | Sync repository metadata from GitHub |

**validate subcommand:**
- Checks workflow file exists
- Validates local path accessibility
- Verifies build target compatibility

**discover subcommand:**
- Scans GitHub org/user for repos with releases
- Identifies repos with compatible release workflows
- Suggests appropriate build targets based on language

dsr builds from local checkouts, so discover scans `--path` (default
`/data/projects`) for Rust, Go and Node projects and reads each checkout's
GitHub `origin`. `--org` keeps checkouts whose GitHub owner matches
(case-insensitive), `--language` keeps one language, and `--apply` registers
each with its `owner/repo` and local path. `list --format json` is the JSON
envelope; unknown options and formats exit 4.

`add`, `remove` and `sync` write `repos.yaml`. With `--dry-run` (or the global
`-n`) they show the change and leave the file alone (`details.dry_run`). A
failed write exits 1 rather than reporting success. `validate` exits 1 when
any repository has errors (JSON mode included) and 4 when `--repo` names
nothing in `repos.yaml` or `repos.d`. `sync` needs GitHub access (exit 3
without it) and exits 1, `partial` or `error`, when some repositories could
not be synced.

---

### `dsr config`

View and modify configuration.

```bash
dsr config show [--section <name>]
dsr config set <key>=<value>
dsr config get <key>
dsr config init [--force]
dsr config validate
dsr config migrate [--dry-run]
dsr config edit
```

| Subcommand | Description |
|------------|-------------|
| `show` | Display current configuration |
| `set` | Set a configuration value |
| `get` | Get a specific configuration value |
| `init` | Initialize configuration with defaults |
| `validate` | Validate configuration files |
| `migrate` | Migrate config to latest schema version |
| `edit` | Open config file in $EDITOR |

**migrate subcommand:**
- Detects config schema version
- Applies necessary transformations
- Creates backup before migration
- Reports all changes made

Schema `1.0.0` is the only version so far: `migrate` stamps a missing
`schema_version` (after a timestamped `config.yaml.bak.*` backup) and refuses a
version it does not know (exit 4). `show --section <name>` selects a key or a
dotted section (`signing` shows `signing.enabled`). `set` saves to
`config.yaml` (requires yq) or fails; it never reports an unsaved value. Every
`--json` answer is a `config` envelope with `details.action`.

---

### `dsr doctor`

System diagnostics.

```bash
dsr doctor [--fix]
```

Checks:
- gh CLI installed and authenticated
- docker installed and running
- act installed and configured
- SSH access to build hosts (mmini, wlap)
- minisign key configured
- syft installed for SBOM generation

---

### `dsr status`

Show system status and recent activity summary.

```bash
dsr status [--watch] [--compact]
```

| Flag | Default | Description |
|------|---------|-------------|
| `--watch` | false | Continuously update status display (not with `--json`) |
| `--interval` | 5 | Seconds between `--watch` redraws |
| `--compact` | false | Minimal one-line summary |
| `--refresh` | false | Re-run host health checks instead of reading the cache |

`overall_status` is `error` without a valid configuration, `degraded` when a host
is unhealthy or the last command (other than status/help/version) failed — a
usage error (exit 4) or an interrupt does not count — and `ok` otherwise.

**Exit codes:**
- `0`: System healthy
- `1`: System degraded (some issues)
- `3`: System unhealthy (critical issues)

---

### `dsr report`

Generate a detailed status report.

```bash
dsr report [--since <duration>] [--limit <n>] [--repo <name>]
```

| Flag | Default | Description |
|------|---------|-------------|
| `--since` | 24h | Lookback window |
| `--limit` | 20 | Max recent runs in report |
| `--repo` | all | Scope report to a repo |

Runs come from the run logs (`Session started`/`Session finished` records,
rotated logs included); status, help, version and report invocations are not
runs, and usage errors (4) or interrupts are not failures. `summary` always
covers the last 24h; `window` covers `--since`. `throttled_repos` comes from
the last `dsr check` result (`state/check/last.json`) when it is under a day old.

**Exit codes:**
- `0`: Report generated
- `3`: Report failed (missing data or dependencies)

---

### `dsr prune`

Clean up old artifacts, logs, and cache to free disk space.

```bash
dsr prune [--snapshots] [--dry-run] [--max-age <days>] [--keep-last <n>] [--force]
```

| Flag | Default | Description |
|------|---------|-------------|
| `--dry-run` | false | Show what would be deleted without deleting |
| `--max-age` | 30 | Delete items older than N days |
| `--keep-last` | 5 | Always keep the N most recent artifact sets per tool and build runs per tool/version |
| `--keep-releases` | true | Never delete artifacts for published releases (`--no-keep-releases` to include them) |
| `--snapshots` | false | Reclaim only owned Unix snapshots of retired completed native builds, preserving ordinary artifacts, caches, logs and checkpoints |
| `--force` | false | Skip confirmation prompt |

Artifact sets are `artifacts/<tool>-<tag>/` with their `<tool>-<tag>-manifest.json`;
`--keep-releases` retains a set when `releases/<tool>-<tag>-upload.json` exists.
Publication keeps that private upload receipt after success. A partial upload
or completed draft also keeps its receipt, so this retention test conservatively
protects recovery inputs without asserting that the release is public. Prune
does not contact GitHub or reconstruct missing historical receipts. The build
run `latest` points to is always kept. The global `--dry-run` applies.

Artifact pruning requires a regular manifest that is not a symbolic link at
`artifacts/<tool>-<tag>/<tool>-<tag>-manifest.json` or the adjacent
`artifacts/<tool>-<tag>-manifest.json`. Its tool and canonical version must match
the set name; when both manifests exist, their owner and recorded run/source
identities must agree. Custom, quarantined, worker UUID and other unidentified
directories are retained. A build-purpose marker must describe completed,
publishable release output and bind the internal manifest's digest, run ID and
source commit. Pending or non-publishable output is retained even when an older
manifest remains in the directory. Legacy sets without a purpose marker remain
eligible when their manifest ownership is valid.

For an eligible artifact set, prune acquires both the canonical tag lease and
the possible unprefixed version lease, then verifies that the directory,
manifests and purpose marker still match its initial observation. The leases
remain held through removal of both the directory and adjacent manifest.
Busy or unverifiable leases and changed observations retain the complete set.
The age, per-tool keep-last and published-release retention policies still
apply. `retained_artifact_paths` reports additional exclusions as `{path, reason}`:
`build_custody` for unavailable leases, `publication_pending` for unfinished or
non-publishable output, and `artifact_ownership` for unknown, conflicting or
changed ownership evidence. The path identifies the directory, or the adjacent
manifest when the directory is absent.

Build checkpoint pruning acquires the same tool/version lease used by builds
and holds it through selection and removal. Both the stored version and its
canonical tag are covered when they differ, such as `1.2.3` and `v1.2.3`.
A busy lease, including one inherited by a worker after its coordinator exits,
or unverifiable lease metadata keeps that version's checkpoints. Dry-run only
probes existing leases; it creates no build lease or checkpoint and reports a
current observation, not a reservation for a later invocation.

Checkpoints with recorded source roots are retained, including roots in source
sync history and relocation evidence. Strict snapshots and their private Cargo
caches live outside the ordinary state/cache directories and may be protected
from external cleanup. Removing the checkpoint first would orphan those caches
and discard recovery evidence. The default mode does not reclaim snapshots;
their recorded paths alone do not establish the directory custody required for
automatic deletion. Malformed, mismatched or linked checkpoints and ambiguous
`latest` entries are also retained. These guards apply even with `--keep-last 0`
or `--force`.

JSON results report these additional exclusions in `retained_build_paths`, an
array of `{path, reason}` objects. `build_custody` identifies a busy or
unverifiable build lease, `source_roots` identifies retained source references,
and `invalid_state` identifies an unverifiable checkpoint or resume selection.
These exclusions are successful skips; deletion or lease-release errors still
produce a partial result. The build leases coordinate artifact/checkpoint
cleanup with builds, fallback runs and standalone binary `dsr release` calls.
Strict `dsr release finalize` and mutating `dsr release verify --fix` also hold
these leases, including while a concurrent prune uses `--no-keep-releases`:
that option changes retention policy and cannot override active custody.
Native recovery and the standalone
library finalizer use separate custody mechanisms. Custom outputs outside
`state/artifacts`, logs, files in `state/manifests` and ordinary cache entries
remain governed by their existing retention policies. These checks do not
establish that every recorded recovery input is reclaimable.

**Explicit snapshot retirement (`--snapshots`):**

This mode skips ordinary artifact, log, manifest, cache and checkpoint deletion.
It applies the same age, latest, per-version keep-last and published-release
retention policies to completed native build runs. Both the canonical tag and
stored-version leases remain held through host inspection, removal and the
checkpoint transaction. A descendant still holding either lease prevents
cleanup. `--force` skips confirmation only.

Every target must be completed and its original frozen artifact receipts must
still verify. The output directory must have a completed publishable release
marker and canonical manifest bound to that checkpoint's tool, version, run and
source commit. Missing, unfinished, diagnostic or corrupt output is retained.
Output/checkpoint/shared DSR paths that overlap a snapshot also prevent its
removal, even when source ownership itself is valid. Local checks compare
device/inode identities as well as paths, covering directory and single-file
bind aliases without relying on hardlink counts.

Fresh strict Unix source synchronization issues a private
`.dsr-snapshot-owner.json` beside `.sbh-protect`, outside authenticated source
bytes. `snapshot_owners` in the sync result and initial context binds the host,
run, source commit, logical and physical paths, actual configured route, owner
UID, directory device/inode, random nonce, and both original marker byte hashes
and file identities. The coordinator retains the original issuance pin and
rechecks it after staging. Relocation retains new host pins in its verified
source-sync receipt. Cleanup unions current and historical roots; an absent,
conflicting or unverifiable ownership pin is a successful retention, never
permission to adopt an existing directory. Native Windows and legacy snapshots
without producer pins remain retained.

The local and SSH workers use the same descriptor-relative implementation.
They revalidate ownership, reject changed directory/marker identities, unsafe
ancestors, mount boundaries, special entries and hardlinks outside the owned
tree, and unlink interior symlinks without following their targets. Source and
private cache contents are removed before the ownership/protection markers.
Every held descendant retains its parent/name chain through removal; moving
that directory outside the snapshot stops further deletion. Nested ownership,
protection and retirement markers are foreign custody boundaries, so an outer
run cannot reclaim another run or protected stage stored beneath it.
An interrupted final directory removal requires the private retirement receipt
issued by that cleanup attempt; a bare empty replacement is not eligible.

Each completed host removal is recorded in `snapshot_cleanup.roots`, with its
original owner pin, actual result and completion time. Original context,
source history, relocation receipts, artifact receipts and checkpoints remain.
The journal retains the original run-directory age so partial retries do not
reset retention ordering. A repeated invocation rechecks the host; an absent
root contributes zero bytes, and a replacement at the old path is retained.
No journal or lease metadata is written in either dry-run form. Dry-run checks
describe the current observation and do not reserve future cleanup.

JSON adds `snapshots_only`, `snapshot_results` and `retained_snapshot_paths`.
Each result contains `{host, source_root, path, status, size_bytes}`, where
`path` is the owned parent and `status` is `eligible` in dry-run, `removed`, or
`already_absent`. Only eligible/removed parents increase `pruned_count` and
`bytes_freed`. The byte count sums each remaining regular inode's apparent size
once, including the original markers; it excludes directory metadata and
symlink targets, and is not a filesystem free-space measurement.
Retained snapshots contain `{path, host, run_id, reason}`, with the source root
as `path`. Reasons are `snapshot_ownership`, `unsupported_host`,
`snapshot_transport`, or `cleanup_failed`. Whole-run exclusions add
`active_run`, `publication_pending`, and `release_retention` to
`retained_build_paths`. Unknown ownership is a successful skip. Transport,
removal and journal-write failures report `E053`, return partial status, and
preserve already completed per-host progress for the next invocation.

**Exit codes:**
- `0`: Prune completed successfully
- `1`: Partial cleanup (some files couldn't be deleted)
- `4`: Invalid arguments

---

## Error Codes

Structured error codes for programmatic handling:

| Code | Category | Description |
|------|----------|-------------|
| E001 | AUTH | GitHub authentication failed |
| E002 | AUTH | SSH key authentication failed |
| E003 | NETWORK | Network request timeout |
| E004 | NETWORK | Host unreachable |
| E010 | BUILD | Compilation failed |
| E011 | BUILD | Missing build dependencies |
| E012 | BUILD | act workflow failed |
| E020 | RELEASE | Asset upload failed |
| E021 | RELEASE | Tag already exists |
| E022 | RELEASE | Signing failed |
| E030 | CONFIG | Invalid configuration |
| E031 | CONFIG | Missing required config |
| E040 | SYSTEM | Docker not running |
| E041 | SYSTEM | Required tool missing |
| E050 | PRUNE | State directory not found |
| E051 | PRUNE | Prune failed or permissions blocked |
| E052 | REPOS | Repository registry error |
| E053 | PRUNE | Snapshot transport, removal or cleanup receipt failed |
| E060 | REPORT | Report generation failed |

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DSR_CONFIG` | ~/.config/dsr/config.yaml | Config file |
| `DSR_STATE_DIR` | ~/.local/state/dsr | State directory |
| `DSR_CACHE_DIR` | ~/.cache/dsr | Cache directory |
| `DSR_LOG_LEVEL` | info | Log level |
| `DSR_NO_COLOR` | false | Disable colors |
| `DSR_JSON` | false | Force JSON output |
| `DSR_THRESHOLD` | 600 | Default queue threshold |
| `DSR_MINISIGN_KEY` | | Path to minisign private key |
| `DSR_MINISIGN_PASSWORD_FILE` | | Private file containing one Minisign password line; used only when creating signatures, requires Python 3 |
| `DSR_GH_TOKEN` | | Highest-priority GitHub API token for DSR |
| `GITHUB_TOKEN` | | GitHub API token, after `DSR_GH_TOKEN` |
| `GH_TOKEN` | | GitHub API token, after `DSR_GH_TOKEN` and `GITHUB_TOKEN` |
| `GH_API_TIMEOUT` | 60 | Positive integer seconds per complete JSON API attempt or standalone authentication check (maximum 999999) |
| `DSR_SLACK_WEBHOOK` | config `notifications.slack_webhook` | Slack incoming webhook for `--notify slack` |
| `DSR_DISCORD_WEBHOOK` | config `notifications.discord_webhook` | Discord webhook for `--notify discord` |
| `DSR_NOTIFY_TIMEOUT` | 20 | Seconds allowed per webhook delivery |

`DSR_MINISIGN_PASSWORD_FILE` enables unattended signing with an encrypted
private key. It is a path, not a password value. The file must be a regular
non-symlink file owned by the current user, with one hard link and no
group/other permission bits (use `0600` or `0400`). Its single password line
may end in LF or CRLF and may contain at most 1022 password bytes. An empty
file, embedded line breaks or NUL bytes, and oversized input are refused; an
explicit blank line supplies an empty password. DSR validates the opened
file's identity and metadata, then supplies frozen bytes on a new private
pipe for each signature. It never consumes an artifact inventory from the
caller's stdin or places the password in a shell argument, environment value,
log, or temporary file.

Without a password file, interactive signing uses a separately opened
controlling terminal when stderr is a terminal and neither `--non-interactive`,
`--json`, `DSR_NON_INTERACTIVE=true`, nor `CI` prohibits prompting. Otherwise Minisign
receives closed input: unencrypted keys work, and encrypted keys fail without
waiting for terminal input. A valid retained signature is verified and reused
without opening a password file. Key generation and rotation retain their
existing input behavior; this variable is a signing credential provider.

DSR's GitHub adapter, release publisher, release repair and authentication
diagnostics use `DSR_GH_TOKEN`, then `GITHUB_TOKEN`, then `GH_TOKEN`, then
the stored `gh` credential for `github.com`. API requests, release asset
downloads and uploads, repairs, and authentication diagnostics use that same
selection. The selected token and `github.com` host are bound to each child
command; an ambient `GH_HOST` or another logged-in Enterprise account cannot
redirect these public-GitHub operations. The caller's environment and saved
logins are unchanged. A rejected explicit token is not replaced with another
account's credential. The sourceable `gh_api` adapter accepts relative API
paths rather than absolute URLs that could change the request's host.

The sourceable `gh_api` adapter returns 124 when its complete attempt exceeds
`GH_API_TIMEOUT`. A deadline, cancellation, or lost mutation response never
authorizes replaying that mutation. Confirmed rate-limit rejections retain the
existing bounded retry policy; each retry gets its own attempt deadline.
Successful draft creation still retains the original response bytes when
requested, while an interrupted attempt cannot leave an accepted creation
receipt or cached response.

A webhook delivery that fails (an HTTP error such as a revoked webhook's 404, or
a timeout) is reported and is not recorded as sent, so the next occurrence of
the event is delivered again. `watch --notify` passes its methods to the
fallbacks it starts; each fallback reports how it ended (`fallback.success`,
`fallback.build_failed`, `fallback.release_failed`, or `fallback.failed`).

---

## Backward Compatibility

### Schema Versioning

- JSON output includes schema version in tool metadata
- Schema changes are additive only (new fields, never remove)
- Breaking changes increment major version

### Deprecation Policy

1. Deprecated flags/commands emit warning to stderr
2. Deprecated features supported for 2 minor versions
3. Removal announced in CHANGELOG

---

## Examples

### CI Integration

```bash
#!/bin/bash
# GitHub Actions fallback in CI

result=$(dsr check --json 2>/dev/null)
if echo "$result" | jq -e '.details.throttled | length > 0' >/dev/null; then
  echo "Throttling detected, triggering fallback..."
  dsr fallback --repo "$REPO" --non-interactive
fi
```

### Monitoring Script

```bash
#!/bin/bash
# Watch for throttling and notify

dsr watch --interval 60 --notify slack --auto-fallback
```

### Build Matrix

```bash
#!/bin/bash
# Build specific targets

dsr build --repo ntm \
  --targets linux/amd64,darwin/arm64,windows/amd64 \
  --version v1.2.3 \
  --json
```

---

## Implementation Notes

### For Developers

1. Use `serde` for JSON serialization (Rust)
2. Use `clap` for argument parsing with derive macros
3. Implement `Display` for human output, `Serialize` for JSON
4. Always capture and report timing information
5. Use UUIDs for run_id (v4)
6. ISO8601 timestamps with timezone

### Testing Requirements

- Unit tests for each exit code path
- Integration tests for JSON schema compliance
- E2E tests for full command pipelines
- Test both success and failure scenarios
