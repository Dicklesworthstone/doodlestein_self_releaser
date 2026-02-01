# dsr — Doodlestein Self-Releaser

<div align="center">
  <img src="dsr_illustration.webp" alt="dsr - Fallback release infrastructure for when GitHub Actions is throttled">
</div>

<div align="center">

**Fallback release infrastructure for when GitHub Actions is throttled.**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Bash 4.0+](https://img.shields.io/badge/Bash-4.0%2B-green.svg)](https://www.gnu.org/software/bash/)

</div>

<div align="center">
<h3>Quick Install</h3>

```bash
curl -fsSL "https://raw.githubusercontent.com/Dicklesworthstone/doodlestein_self_releaser/main/install.sh?$(date +%s)" | bash
```

</div>

When GitHub Actions queue times exceed 10 minutes, `dsr` takes over — reusing your existing workflow YAML to build locally via [nektos/act](https://github.com/nektos/act), then uploads artifacts to GitHub Releases.

---

## TL;DR

**The Problem**: GitHub Actions gets throttled during peak times. Your release sits in queue for 20+ minutes while users wait.

**The Solution**: `dsr` detects throttling, builds locally using your existing workflow files, and uploads to GitHub Releases — same artifacts, no queue.

### Why Use dsr?

| Feature | What It Does |
|---------|--------------|
| **Zero config builds** | Reuses your `.github/workflows/release.yml` — no parallel build system to maintain |
| **Multi-platform** | Builds on Linux (act), macOS (native), Windows (native) via SSH |
| **Signed releases** | Minisign signatures + SBOM generation built in |
| **Queue detection** | Monitors GH Actions queue time, triggers fallback automatically |

---

## Quick Example

```bash
# Check if any repos are throttled
$ dsr check --all
Checking ntm... queued 12m (threshold: 10m) ⚠️
Checking bv... ok ✓
Checking cass... ok ✓

# Build locally when throttled
$ dsr build --repo ntm --version v1.2.3
Building ntm v1.2.3 for linux/amd64, darwin/arm64, windows/amd64...
  linux/amd64   [act on trj]     ✓ 45s
  darwin/arm64  [native on mmini] ✓ 32s
  windows/amd64 [native on wlap]  ✓ 51s
Artifacts: /tmp/dsr/artifacts/ntm-v1.2.3/

# Upload to GitHub Release
$ dsr release --repo ntm --version v1.2.3
Uploading 6 assets to ntm v1.2.3...
  ntm-linux-amd64           ✓
  ntm-linux-amd64.minisig   ✓
  ntm-darwin-arm64          ✓
  ntm-darwin-arm64.minisig  ✓
  ntm-windows-amd64.exe     ✓
  ntm-windows-amd64.exe.minisig ✓
Release: https://github.com/Dicklesworthstone/ntm/releases/tag/v1.2.3

# Or do it all in one command
$ dsr fallback --repo ntm --version v1.2.3
```

---

## Design Philosophy

1. **Reuse, don't reinvent** — Your GitHub Actions workflow is the source of truth. `dsr` runs it locally via `act`, not a parallel build system.

2. **Detect, don't guess** — Queue time monitoring tells you exactly when to fall back. No manual threshold tuning.

3. **Same artifacts, different path** — Users get identical binaries whether built by GH Actions or `dsr`.

4. **Fail loudly, recover gracefully** — Structured exit codes (0-8) and JSON output for scripting. Partial failures are reported, not hidden.

5. **Local-first, cloud-optional** — Works offline. SSH to your Mac Mini and Windows laptop for native builds.

---

## Comparison

| Feature | dsr | Manual builds | GoReleaser | GitHub-hosted runners |
|---------|-----|---------------|------------|----------------------|
| Uses existing workflow | ✅ | ❌ | ❌ Config needed | ✅ |
| Multi-platform builds | ✅ Linux/macOS/Windows | Manual | ✅ | ✅ |
| Queue detection | ✅ Automatic | ❌ | ❌ | N/A |
| Signing | ✅ Minisign | Manual | ✅ GPG/cosign | ✅ |
| SBOM generation | ✅ syft | Manual | ✅ | ✅ |
| Cost | Free | Free | Free | $$/min |

**When to use dsr:**
- You have existing GH Actions release workflows
- You want a fallback for throttled queues
- You have SSH access to macOS/Windows machines for native builds

**When dsr might not be ideal:**
- You don't use GitHub Actions
- You need builds on platforms you don't have machines for
- You want a full CI/CD replacement (dsr is a fallback, not a replacement)

---

## Installation

### From Source

```bash
git clone https://github.com/Dicklesworthstone/doodlestein_self_releaser.git
cd doodlestein_self_releaser
chmod +x dsr
sudo ln -s "$(pwd)/dsr" /usr/local/bin/dsr
```

### Dependencies

Required:
- **Bash 4.0+** (macOS ships with 3.x — `brew install bash`)
- **git** — Version control
- **gh** — GitHub CLI for API access
- **jq** — JSON parsing

For local builds:
- **docker** — Required for nektos/act containers
- **act** — `brew install act` or [nektos/act releases](https://github.com/nektos/act/releases)

> **CRITICAL: act Configuration Required**
>
> The default act runner images (catthehacker/ubuntu) run as UID 1001. If you use `--bind` in your `~/.actrc` without proper user mapping, **files created by act will have wrong ownership**, breaking access for other processes.
>
> After installing act, copy the example config:
> ```bash
> cp config/actrc.example ~/.actrc
> ```
>
> Or add this line to your `~/.actrc` (replace 1000:1000 with your UID:GID from `id`):
> ```
> --container-options --user=1000:1000
> ```
>
> Run `dsr doctor` to verify your configuration.
>
> See [docs/ACT_SETUP.md](docs/ACT_SETUP.md) for complete setup instructions.

For multi-platform builds:
- **ssh** — Access to macOS/Windows build machines

For signing:
- **minisign** — `brew install minisign`
- **syft** — For SBOM generation

### Verify Installation

```bash
dsr doctor
```

---

## Quick Start

### 1. Initialize Configuration

```bash
dsr config init
```

This creates `~/.config/dsr/config.yaml` with defaults.

### 2. Add Repositories

```bash
dsr repos add Dicklesworthstone/ntm --local-path /data/projects/ntm --language go
```

### 3. Configure Build Hosts (Optional)

Edit `~/.config/dsr/hosts.yaml`:

```yaml
hosts:
  trj:
    platform: linux/amd64
    connection: local
  mmini:
    platform: darwin/arm64
    connection: ssh
    ssh_host: mmini
  wlap:
    platform: windows/amd64
    connection: ssh
    ssh_host: wlap
```

Ensure hosts have required toolchains for your repos (rust/go/bun) and that `trj` has Docker + act for Linux builds.

### 4. Set Up Signing (Recommended)

```bash
dsr signing init
```

This generates a minisign key pair at `~/.config/dsr/secrets/minisign.key`.

### 5. Check System Health

```bash
dsr doctor
```

### 6. Check Status Summary

```bash
dsr status
dsr status --refresh   # refresh host health checks
```

---

## Commands

### Global Flags

```bash
--json, -j           # Machine-readable JSON output
--non-interactive, -y # Disable prompts (CI mode)
--dry-run, -n        # Show planned actions without executing
--verbose, -v        # Verbose logging
--quiet, -q          # Suppress non-error output
--no-color           # Disable ANSI colors
```

**Stream separation:** human-readable output goes to stderr, structured JSON goes to stdout. For scripting, use `--json` and capture stdout (or redirect stderr to `/dev/null`).

### `dsr check`

Detect throttled GitHub Actions runs.

```bash
dsr check                           # Check all configured repos
dsr check --repos ntm,bv            # Check specific repos
dsr check --threshold 300           # Custom threshold (5 min)
dsr check --all                     # Check all workflows, not just releases
dsr check --json                    # JSON output for scripting
```

### `dsr build`

Build artifacts locally.

```bash
dsr build --repo ntm                            # Build all targets
dsr build --repo ntm --targets linux/amd64      # Specific target
dsr build --repo ntm --version v1.2.3           # Specific version
dsr build --repo ntm --no-sign                  # Skip signing
```

### `dsr release`

Upload artifacts to GitHub Release.

```bash
dsr release --repo ntm --version v1.2.3         # Upload to release
dsr release --repo ntm --version v1.2.3 --draft # Create draft release
dsr release --repo ntm --version v1.2.3 --dispatch # Trigger repository dispatch hooks
```

### `dsr fallback`

Full pipeline: check → build → release.

```bash
dsr fallback --repo ntm --version v1.2.3        # One command does it all
```

### `dsr watch`

Continuous monitoring daemon.

```bash
dsr watch                                       # Default: check every 60s
dsr watch --interval 30 --auto-fallback         # Auto-trigger on throttle
dsr watch --notify desktop                      # Desktop notifications
```

### `dsr repos`

Manage repository registry.

```bash
dsr repos list                                  # List registered repos
dsr repos add owner/repo --local-path /path     # Add a repo
dsr repos remove repo-name                      # Remove a repo
dsr repos validate                              # Validate all configs
```

### `dsr config`

Configuration management.

```bash
dsr config show                                 # Show current config
dsr config get threshold_seconds                # Get specific value
dsr config set threshold_seconds=300            # Set value
dsr config validate                             # Validate config files
```

### `dsr doctor`

System diagnostics.

```bash
dsr doctor                                      # Check all dependencies
dsr doctor --fix                                # Auto-fix issues where possible
```

### `dsr status`

System + last run summary.

```bash
dsr status                                      # Show cached summary
dsr status --refresh                            # Refresh host health checks
dsr status --json                               # JSON output
```

---

## Exit Codes

| Code | Name | Meaning |
|------|------|---------|
| `0` | SUCCESS | Operation completed successfully |
| `1` | PARTIAL_FAILURE | Some targets/repos failed |
| `2` | CONFLICT | Blocked by pending run/lock |
| `3` | DEPENDENCY_ERROR | Missing gh auth, docker, ssh, etc. |
| `4` | INVALID_ARGS | Bad CLI options or config |
| `5` | INTERRUPTED | User abort (Ctrl+C) or timeout |
| `6` | BUILD_FAILED | Build/compilation error |
| `7` | RELEASE_FAILED | Upload/signing failed |
| `8` | NETWORK_ERROR | Network connectivity issue |

---

## Configuration

### Main Config (`~/.config/dsr/config.yaml`)

```yaml
schema_version: "1.0.0"

# Queue time threshold before triggering fallback (seconds)
threshold_seconds: 600

# Default build targets
default_targets:
  - linux/amd64
  - darwin/arm64
  - windows/amd64

# Artifact signing
signing:
  enabled: true
  key_path: ~/.config/dsr/secrets/minisign.key

# SBOM generation
sbom:
  enabled: true
  format: spdx-json

# Logging
log_level: info  # debug|info|warn|error
```

### Repository Config (`~/.config/dsr/repos.d/ntm.yaml`)

```yaml
repo: Dicklesworthstone/ntm
local_path: /data/projects/ntm
language: go

targets:
  - linux/amd64
  - darwin/arm64
  - windows/amd64

workflow: .github/workflows/release.yml

# Override default hosts for this repo
hosts:
  linux/amd64: trj
  darwin/arm64: mmini
  windows/amd64: wlap
```

---

## Logging and State

dsr stores run logs and build artifacts under XDG state/cache directories:

```
~/.local/state/dsr/
  logs/YYYY-MM-DD/run.log
  logs/YYYY-MM-DD/builds/*.log
  artifacts/
  manifests/

~/.cache/dsr/
  act/
  builds/
```

When a command fails, start with the latest `run.log`, then per-build logs under `logs/YYYY-MM-DD/builds/`.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        dsr CLI                                   │
│   check │ build │ release │ fallback │ watch │ doctor           │
└─────────────────────────────────────────────────────────────────┘
                            │
        ┌───────────────────┼───────────────────┐
        ▼                   ▼                   ▼
┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐
│ GitHub API       │ │ Build Dispatch   │ │ Release Upload   │
│ - Queue monitor  │ │ - act (Linux)    │ │ - gh release     │
│ - Workflow runs  │ │ - SSH (macOS)    │ │ - Checksums      │
│                  │ │ - SSH (Windows)  │ │ - Signatures     │
└──────────────────┘ └──────────────────┘ └──────────────────┘
                            │
        ┌───────────────────┼───────────────────┐
        ▼                   ▼                   ▼
┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐
│ trj (Linux)      │ │ mmini (macOS)    │ │ wlap (Windows)   │
│ - Docker + act   │ │ - Native build   │ │ - Native build   │
│ - x86_64         │ │ - arm64          │ │ - x86_64         │
└──────────────────┘ └──────────────────┘ └──────────────────┘
```

---

## Troubleshooting

### "gh: command not found"

```bash
# macOS
brew install gh

# Linux
sudo apt install gh  # Debian/Ubuntu
sudo dnf install gh  # Fedora

# Then authenticate
gh auth login
```

### "act: command not found"

```bash
brew install act
# or download from https://github.com/nektos/act/releases
```

### "Error: Bash 4.0+ required"

macOS ships with Bash 3.x. Install newer Bash:

```bash
brew install bash
# Add to shells
sudo bash -c 'echo /opt/homebrew/bin/bash >> /etc/shells'
# Change default (optional)
chsh -s /opt/homebrew/bin/bash
# Or run dsr explicitly
/opt/homebrew/bin/bash dsr check
```

### "SSH connection to mmini failed"

1. Verify SSH access: `ssh mmini echo ok`
2. Check Tailscale is running: `tailscale status`
3. Verify host is in `~/.config/dsr/hosts.yaml`

### "Docker is not running"

```bash
# Start Docker Desktop, or:
sudo systemctl start docker  # Linux
```

### Files owned by wrong user (UID 1001) after running act

This happens when `~/.actrc` has `--bind` but is missing the `--user` flag. The catthehacker runner images run as UID 1001 (user "runner"), so files they create get that ownership.

**Fix:**

```bash
# Add user mapping to actrc
echo '--container-options --user=$(id -u):$(id -g)' >> ~/.actrc

# Fix existing files
sudo chown -R $(id -un):$(id -gn) /path/to/affected/repo
```

**Prevention:**

```bash
# Copy the example config (already has the fix)
cp /path/to/dsr/config/actrc.example ~/.actrc

# Verify configuration
dsr doctor
```

See [docs/ACT_SETUP.md](docs/ACT_SETUP.md) for complete act setup instructions.

---

## Installers and Verification

Installers generated by dsr can verify SHA256 checksums and minisign signatures when available. Use `dsr signing init` to generate signing keys for your artifacts.

---

## Further Reading

- `docs/CLI_CONTRACT.md` — authoritative CLI spec, JSON envelope, and exit codes
- `docs/ACT_SETUP.md` — nektos/act installation and setup guidance

---

## Limitations

### What dsr Doesn't Do

- **Not a CI/CD replacement** — It's a fallback for when GH Actions is slow, not a complete build system
- **No hosted runners** — You need your own machines for macOS/Windows builds
- **No caching** — Each build starts fresh (act has some layer caching)

### Known Limitations

| Capability | Current State | Notes |
|------------|---------------|-------|
| Linux builds | ✅ Full support | Via act in Docker |
| macOS builds | ✅ Full support | Requires SSH access to Mac |
| Windows builds | ✅ Full support | Requires SSH access to Windows |
| ARM Linux | ⚠️ Experimental | QEMU emulation via act |
| Container caching | ⚠️ Basic | Docker layer cache only |

---

## FAQ

### Why "Doodlestein Self-Releaser"?

It's part of the Dicklesworthstone tool ecosystem. The name is intentionally whimsical.

### Does it work with private repos?

Yes, as long as `gh` is authenticated with access to the repo.

### Can I use it without nektos/act?

Yes, for macOS and Windows targets that build natively via SSH. Linux builds currently require act.

### How does it compare to self-hosted runners?

Self-hosted runners require always-on infrastructure. `dsr` uses your existing machines on-demand when GH Actions is slow.

### Can I use it in CI?

Yes. Use `--json --non-interactive` for scripted usage:

```bash
if dsr check --json | jq -e '.details.throttled | length > 0'; then
  dsr fallback --repo $REPO --non-interactive
fi
```

---

## About Contributions

Please don't take this the wrong way, but I do not accept outside contributions for any of my projects. I simply don't have the mental bandwidth to review anything, and it's my name on the thing, so I'm responsible for any problems it causes; thus, the risk-reward is highly asymmetric from my perspective. I'd also have to worry about other "stakeholders," which seems unwise for tools I mostly make for myself for free. Feel free to submit issues, and even PRs if you want to illustrate a proposed fix, but know I won't merge them directly. Instead, I'll have Claude or Codex review submissions via `gh` and independently decide whether and how to address them. Bug reports in particular are welcome. Sorry if this offends, but I want to avoid wasted time and hurt feelings. I understand this isn't in sync with the prevailing open-source ethos that seeks community contributions, but it's the only way I can move at this velocity and keep my sanity.

---

## License

MIT
