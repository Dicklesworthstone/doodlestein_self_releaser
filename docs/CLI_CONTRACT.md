# dsr CLI Contract

**Version:** 1.0.0
**Status:** Draft

This document defines the authoritative contract for the `dsr` (Doodlestein Self-Releaser) CLI tool. All subcommands MUST adhere to these specifications.

---

## Purpose

`dsr` is a fallback release infrastructure for when GitHub Actions is throttled (>10 min queue time). It:
- Detects GH Actions throttling via queue time monitoring
- Triggers local builds using `nektos/act` (reusing exact GH Actions YAML)
- Distributes builds across Linux (css), macOS (mmini), Windows (wlap)
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
        "host": "css",
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

**Exit codes:**
- `0`: No throttling detected
- `1`: Throttling detected (triggers fallback recommendation)
- `3`: gh auth or API error

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
```

| Flag | Default | Description |
|------|---------|-------------|
| `--repo` | (required) | Repository to build |
| `--targets` | all | Platforms: linux/amd64,darwin/arm64,windows/amd64 |
| `--version` | HEAD | Version/tag to build |
| `--workflow` | auto | Workflow file to use |
| `--sign` | true | Sign artifacts with minisign |

---

### `dsr release`

Upload artifacts to GitHub Release.

```bash
dsr release --repo <name> --version <tag> [--draft] [--prerelease]
```

| Flag | Default | Description |
|------|---------|-------------|
| `--repo` | (required) | Repository name |
| `--version` | (required) | Release version/tag |
| `--draft` | false | Create as draft release |
| `--prerelease` | false | Mark as prerelease |
| `--artifacts` | auto | Artifact directory |

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

---

### `dsr repos`

Manage repository registry.

```bash
dsr repos list [--format table|json]
dsr repos add <owner/repo> [--local-path <path>] [--language <lang>]
dsr repos remove <name>
dsr repos sync
```

---

### `dsr config`

View and modify configuration.

```bash
dsr config show
dsr config set <key> <value>
dsr config get <key>
dsr config init
```

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
