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
    "assets_uploaded": 6,
    "checksums_published": true,
    "signature_published": true,
    "sbom_published": true
  }
}
```

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

**Exit codes:**
- `0`: No throttling detected
- `1`: Throttling detected (triggers fallback recommendation)
- `3`: gh auth missing
- `8`: GitHub API error for a repo (listed in `details.skipped`), with no throttling seen elsewhere

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
| `--notify` | none | Notification: slack\|discord\|desktop\|none |

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
| `--resume[=RUN_ID]` | off | Reuse verified completed targets and retry incomplete targets |
| `--resume-target-host TARGET=HOST` | off | Relocate one failed native target during a strict release resume |
| `--resume-target-host-approval FILE` | required with relocation | Operator-reviewed JSON binding the run, target, replacement host and configuration hashes |
| `--output-dir` | state directory | Artifact collection directory, bound into resume state |
| `--no-sync` | false | Skip ordinary source sync (forbidden by strict release contracts) |
| `--sync-only` | false | Sync selected build hosts without compiling; exit 1 if any host fails |
| `--diagnostic-native` | false | Build explicit native targets under strict source/family checks, with non-publishable diagnostic provenance |

Target logs and result receipts are isolated by task and attempt. Aggregation
is deterministic in requested-platform order, then configured triple order.
For native Rust builds, a `target_triples` list expands one platform
into independent GNU/musl tasks. Each task records its selected `target_triple`
and a `task_key` such as `linux/amd64@x86_64-unknown-linux-musl`; singleton and
workflow tasks retain their platform as the task key. Platform routing and
`--targets` continue to use `linux/amd64`.

Each native variant has its own staging directory, Cargo home, output directory
and retained artifact receipts. Resume verifies and reuses completed variants
independently, and refuses a changed ordered task list or repository
configuration for a matrix run. Partial artifacts remain available for resume,
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

Run context and aggregate results retain the complete `source_sync` receipt.
Resume syncs again, updates the ordinary host/path bindings, and records the
new receipt in `source_sync_history`. It verifies completed artifact receipts
before deciding which targets still need work. `attempts` counts retained
target attempts, while `source_sync_failures` excludes transfers that never
reached compilation from the compiler retry limit. Direct orchestration resume
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
cancelled runs and diagnostic builds are refused.
Platform-level host relocation also requires the selected platform to have one
configured triple. A multi-variant platform uses the existing same-host resume,
which retries only failed variants and retains successful sibling receipts.
The approval file is a regular JSON file with these required fields:

```json
{
  "run_id": "<original-run-uuid>",
  "target": "windows/amd64",
  "new_host": "windows-backup",
  "prior_repo_config_path": "/path/to/retained-original-repo.yaml",
  "prior_repo_config_sha256": "<original-invocation-config-sha256>",
  "repo_config_sha256": "<reviewed-current-repo-config-sha256>",
  "hosts_config_sha256": "<reviewed-hosts.yaml-sha256>"
}
```

The operator must establish the prior config's provenance from the original
invocation receipt. DSR checks actual file hashes and permits only the selected
target's `cross_compile` host, build command, environment, and legacy `hosts`
entry to differ. Global settings and all other target settings must match.
The current recipe must resolve the selected target to the replacement host.
Its platform may differ from the artifact target when `cross_compile[TARGET].host`
explicitly selects it and the target has a nonempty build command, including an
inherited global `build_cmd`. This supports Linux-hosted Linux ARM64 and Windows
cross builds without mislabeling the build host. A platform-mapping fallback,
unknown host platform, or missing cross-build command is refused before staging.
The native worker still enforces the requested target's output and architecture.
Retained failed result/log files must agree with the old host and frozen source;
completed artifacts and result files must still verify. Replacement staging and
its pinned dependency closure are verified before an atomic state transition.
The run records the prior context, replacement host platform, configuration
delta, source archive/manifest hashes, and prior attempt hashes; the next worker
uses the next attempt number.
After an interrupted staging attempt, only an exactly verified canonical
snapshot may be reused. Partial snapshots are retained and refused, not merged
or overwritten. No successful target is rebuilt by relocation admission.

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
| `--draft` | false | Create as draft release |
| `--prerelease` | false | Mark as prerelease |
| `--artifacts` | auto | Artifact directory |
| `--dispatch` | false | Trigger repository dispatch hooks after release |
| `--no-dispatch` | false | Disable repository dispatch for this run |
| `--dispatch-event` | `dsr_release` | Override dispatch event type |
| `--dispatch-repos` | config/env | Comma-separated override of dispatch targets |
| `--no-manifest` | false | Upload an artifacts directory that has no build manifest, as-is |

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
Native targets build on the host their source was synced to. Manifest artifacts
and build-environment receipts retain the native task's selected triple; flat
raw payload names are qualified when needed, while archive members keep the
configured executable name.
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
independent Cargo homes. Strict Unix and Windows builds copy only downloads
selected by the committed `Cargo.lock`: checksum-matching archives, corresponding sparse index
records or matching legacy Git indexes, and Git databases containing pinned
commits. Cargo recreates extracted registry sources and Git checkouts offline;
ambient `registry/src` and `git/checkouts` trees are not opened or copied, and
unmatched crate archives do not enter the seed. Candidate Git databases are
examined for locked revisions, and selected index storage is validated; unsafe
download candidates can still refuse preparation. A lockfile without Git
dependencies does not inspect the Git cache. Selection conservatively covers
all lockfile packages, not a minimal
target/feature graph, and selected Git databases/indexes retain their history.
Ordinary native builds copy the `registry` and `git` caches.
Metadata and target attempts never compile through ambient cache symlinks or
Windows junctions. Strict metadata admits a retained seed only after successful
locked offline resolution and source authentication; retained seeds contain
only the selected downloads. Retries verify the retained inventory and original
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
Includes, dotted keys, inline tables, `cfg(...)` targets, general environment
injection, unstable selector environments and flags that can select another
linker/compiler/backend are refused before dependency admission. A positive
literal `RUST_MIN_STACK` is the supported `[env]` exception. Configured compiler
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
Explicit `RUSTC`/`CARGO_BUILD_RUSTC` executables and compiler wrappers retain
their own identities; arbitrary scripts are not mislabeled as rustup's
compiler. Proven rustup proxies and Apple `/usr/bin` compiler launchers also
record their resolved executable. Literal tracked Cargo configuration can
select the compiler, target and linker; those configuration files are hashed
into the receipt and require Python 3.11+ to parse. A tracked `[env]` table
that sets any `RUST*`, `CARGO_*`, `XWIN_*`, `PATH` or C toolchain variable is
refused, with one exception: `RUST_MIN_STACK` set to a plain positive integer
string. It only sizes rustc's and test/run threads' stacks, so it is admitted
and recorded under that file's `env_exemptions` (name and value) in every
receipt. Any other value form, or any other influencing name, still fails
closed.

Strict Unix source-closure validation runs locked, offline, all-features Cargo
metadata with each target's selected toolchain and configured environment.
Targets sharing a host keep their own command overrides. Every native attempt
rechecks metadata compatibility, including when it copies an already admitted
download seed; a successful check with one compiler does not authorize another.
The snapshot and retained seed remain unchanged when a later target refuses.

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
configuration includes/`cfg` selectors, and configuration-driven compiler
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

### `dsr installer`

Generate and validate standalone installers from registered tool configuration.

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
dsr prune [--dry-run] [--max-age <days>] [--keep-last <n>] [--force]
```

| Flag | Default | Description |
|------|---------|-------------|
| `--dry-run` | false | Show what would be deleted without deleting |
| `--max-age` | 30 | Delete items older than N days |
| `--keep-last` | 5 | Always keep the N most recent artifact sets per tool and build runs per tool/version |
| `--keep-releases` | true | Never delete artifacts for published releases (`--no-keep-releases` to include them) |
| `--force` | false | Skip confirmation prompt |

Artifact sets are `artifacts/<tool>-<tag>/` with their `<tool>-<tag>-manifest.json`;
a set is published when `releases/<tool>-<tag>-upload.json` exists. The build run
`latest` points to is always kept. The global `--dry-run` applies.

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
| `GITHUB_TOKEN` | | GitHub API token |
| `DSR_SLACK_WEBHOOK` | config `notifications.slack_webhook` | Slack incoming webhook for `--notify slack` |
| `DSR_DISCORD_WEBHOOK` | config `notifications.discord_webhook` | Discord webhook for `--notify discord` |
| `DSR_NOTIFY_TIMEOUT` | 20 | Seconds allowed per webhook delivery |

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
