---
name: dsr
description: >-
  Doodlestein Self-Releaser - fallback release infrastructure for when GitHub
  Actions is throttled. Local builds, cross-platform releases, supply chain
  security. Use when: GH Actions slow, local release, build hosts, dsr command.
---

# dsr - Doodlestein Self-Releaser

Fallback release infrastructure for when GitHub Actions is throttled (>10 min queue time).

## When to Use

Use dsr when:
- GitHub Actions queue time exceeds 10 minutes
- You need to build/release a tool locally
- CI is down or unreliable
- You want to test builds across platforms before pushing

## Commands Reference

### Core Pipeline

```bash
dsr check <repo>              # Check if GH Actions is throttled
dsr check --all               # Check all configured repos
dsr build <tool>              # Build locally for all targets
dsr release <tool> <version>  # Upload artifacts to GitHub
dsr fallback <tool> <version> # Full pipeline: check -> build -> release
```

### System Management

```bash
dsr doctor                    # Check dependencies and auth
dsr doctor --fix              # Suggest fixes for issues
dsr health all                # Check all build hosts
dsr health check mmini        # Check specific host
dsr status                    # System + last run summary
dsr prune                     # Clean old artifacts/logs safely
```

### Configuration

```bash
dsr config init               # Initialize configuration
dsr config show               # Show current configuration
dsr config get <key>          # Get specific setting
dsr config set <key> <val>    # Update setting
dsr repos list                # List all registered repos
dsr repos add <repo>          # Add a repository
dsr repos info <tool>         # Show repo details
dsr repos validate            # Validate all configs
```

### Supply Chain Security

```bash
dsr signing init              # Generate minisign keypair
dsr signing sign <file>       # Sign a file
dsr signing verify <file>     # Verify signature
dsr sbom <project>            # Generate SBOM (SPDX/CycloneDX)
dsr slsa generate <artifact>  # Generate SLSA provenance
dsr slsa verify <artifact>    # Verify provenance
dsr quality <tool>            # Run pre-release quality checks
```

### Testing & Verification

```bash
dsr canary run <tool>         # Test installer in Docker
dsr canary run --all          # Test all installers
dsr verify upgrade <tool>     # Verify upgrade command works
dsr release verify <tool> <v> # Verify release assets
```

## Build Hosts

Hosts are whatever you define in `hosts.yaml`; the ids below are the
conventional ones used throughout these docs.

| Host | Platform | Connection | Purpose |
|------|----------|------------|---------|
| trj | Linux x64 | local | Primary build host, act runner |
| ts1 | Linux x64 | SSH | Secondary Linux builder |
| mmini | macOS arm64 | SSH | Native macOS builds |
| wlap | Windows x64 | SSH | Native Windows builds |

More than one host may share a platform — a second `windows/amd64` or
`linux/amd64` entry is picked up automatically by the selector below, giving
overflow capacity and failover when one host is unhealthy or asleep.

**`hosts.yaml` is per-machine.** Each machine that runs `dsr` reads its own
`~/.config/dsr/hosts.yaml`. If you drive releases from more than one
orchestrator, a host added on one is invisible to the other — edit both.

### Host selection

`act_get_native_host` resolves a platform to a host in this order:

1. Per-repo override: `cross_compile."<platform>".host` in `repos.d/<tool>.yaml`
2. **Health/capacity selector** — considers every host whose `platform` OS
   matches, drops those that are disabled or failing health checks (5-min cache),
   scores the rest by free build slots, and prefers the host named in
   `platform_mapping`
3. Static `platform_mapping["<platform>"]`
4. Compiled-in default

So a second same-platform host absorbs overflow and covers the first being
asleep, while `platform_mapping` still decides who goes first. Set
`DSR_DISABLE_HOST_SELECTOR=1` to bypass step 2 and use the static mapping only.

The first call after a cold health cache costs ~10-15s while hosts are probed;
subsequent calls are instant for 5 minutes.

## Common Workflows

### Release When GH Actions is Throttled

```bash
# 1. Check throttling status
dsr check --all

# 2. Build locally if throttled
dsr build ntm --version 1.5.2

# 3. Upload to GitHub
dsr release ntm 1.5.2

# Or use fallback for full pipeline:
dsr fallback ntm 1.5.2
```

### Health Check Before Building

```bash
# Check system dependencies
dsr doctor

# Check all build hosts are reachable
dsr health all

# Check specific host
dsr health check mmini
```

### Configure a New Tool

```bash
# Add repository
dsr repos add dicklesworthstone/my-tool --local-path /data/projects/my-tool

# Validate configuration
dsr repos validate

# Test build
dsr build my-tool --dry-run
```

### Clean Up Old Artifacts

```bash
# See what would be cleaned
dsr prune --dry-run

# Clean artifacts older than 30 days
dsr prune --age 30d

# Clean specific tool's artifacts
dsr prune --tool ntm
```

## Exit Codes

| Code | Name | Meaning |
|------|------|---------|
| 0 | SUCCESS | Operation completed |
| 1 | PARTIAL_FAILURE | Some targets/repos failed |
| 2 | CONFLICT | Blocked by lock |
| 3 | DEPENDENCY_ERROR | Missing gh auth, docker, ssh |
| 4 | INVALID_ARGS | Bad options or config |
| 5 | INTERRUPTED | User abort or timeout |
| 6 | BUILD_FAILED | Compilation error |
| 7 | RELEASE_FAILED | Upload/signing failed |
| 8 | NETWORK_ERROR | Connectivity issue |

## JSON Output

All commands support `--json` for machine-readable output:

```bash
dsr check ntm --json | jq '.status'
dsr health all --json | jq '.hosts[] | select(.status == "unhealthy")'
dsr status --json | jq '.last_run'
```

## Troubleshooting

### SSH Connection Fails

```bash
# Check Tailscale status
tailscale status

# Test SSH manually
ssh -o ConnectTimeout=5 mmini "echo ok"

# Clear health cache and retry
dsr health clear-cache
dsr health check mmini
```

### Builds land on the wrong host (or an unexpected one)

The selector can legitimately pick a host other than the one in
`platform_mapping` — that is the failover working. To see why:

```bash
dsr health all --json | jq '.hosts[] | {hostname, status, healthy}'
DSR_DISABLE_HOST_SELECTOR=1 dsr build <tool>   # force the static mapping
```

A host is dropped from consideration when it is `enabled: false`, unhealthy
(disk >95% used is an *error*; >90% is only a warning), or has no free slots.
`hosts.yaml` is per-machine — confirm you edited the one belonging to the
machine you are running `dsr` on.

### Build Fails

```bash
# Check toolchain versions
dsr doctor --fix

# Check host-specific toolchain
dsr health check trj --json | jq '.toolchains'

# Try building with verbose output
dsr build ntm --verbose
```

### Release Upload Fails

```bash
# Check gh authentication
gh auth status

# Verify release doesn't already exist
gh release view v1.5.2 --repo Dicklesworthstone/ntm

# Resume interrupted upload
dsr release ntm 1.5.2 --resume
```

### Docker/Act Issues

```bash
# Check Docker is running
docker info

# Check act installation
act --version

# On macOS, ensure Colima is running
colima status
```

## Configuration Files

```
~/.config/dsr/
├── config.yaml           # Main configuration
└── repos.d/
    └── *.yaml            # Per-repo build configs

~/.local/state/dsr/
├── logs/                 # Run logs
├── artifacts/            # Build artifacts
└── manifests/            # Build manifests

~/.cache/dsr/
├── act/                  # Act Docker layer cache
└── builds/               # Cached build artifacts
```

## Integration with Beads

When working on dsr-related beads:

```bash
# Check for ready dsr tasks
br ready | grep dsr

# Update status
br update bd-1jt.x.y --status in_progress
```
