# nektos/act Setup for dsr

`act` allows running GitHub Actions workflows locally in Docker containers. dsr uses act to build Linux targets when GitHub Actions is throttled.

## Installation

### macOS (Homebrew)
```bash
brew install act
```

### Linux (Go)
```bash
go install github.com/nektos/act@latest
```

### Linux (Nix)
```bash
nix-env -iA nixpkgs.act
```

### Linux (Binary)
```bash
curl -sfL https://raw.githubusercontent.com/nektos/act/master/install.sh | sudo bash -s -- -b /usr/local/bin
```

## Initial Configuration

On first run, act prompts for default runner image. Select based on your needs:

| Choice | Image | Size | Use Case |
|--------|-------|------|----------|
| Large | `catthehacker/ubuntu:full-*` | ~12GB | Full compatibility (recommended) |
| Medium | `catthehacker/ubuntu:act-*` | ~500MB | Good balance |
| Micro | `node:16-buster-slim` | ~200MB | Node-only workflows |

For dsr, use **Large** for maximum compatibility with complex workflows.

## ~/.actrc Configuration

Create `~/.actrc` for consistent behavior:

```bash
# Default runner images (pin for reproducibility)
-P ubuntu-latest=catthehacker/ubuntu:full-22.04
-P ubuntu-22.04=catthehacker/ubuntu:full-22.04
-P ubuntu-20.04=catthehacker/ubuntu:full-20.04

# Always use these settings
--container-architecture linux/amd64
--artifact-server-path /tmp/act-artifacts
--env ACTIONS_CACHE_URL=
--env ACTIONS_RUNTIME_URL=
```

## Platform Mapping

| Workflow `runs-on` | dsr Action |
|-------------------|------------|
| `ubuntu-latest` | Run via act on css |
| `ubuntu-*` | Run via act on css |
| `macos-*` | Native SSH to mmini |
| `windows-*` | Native SSH to wlap |
| `self-hosted` | Check labels, route accordingly |

## Common act Commands

### List workflows and jobs
```bash
act -l                              # List all workflows/jobs
act -l -W .github/workflows/ci.yml  # List jobs in specific workflow
```

### Run specific workflow/job
```bash
act -W .github/workflows/release.yml           # Run release workflow
act -j build-linux -W .github/workflows/release.yml  # Run specific job
```

### Dry-run mode
```bash
act -n -W .github/workflows/release.yml        # Show what would run
```

### Event simulation
```bash
act push                            # Simulate push event
act workflow_dispatch               # Simulate manual trigger
act release -e event.json           # Simulate release with payload
```

### Secrets and environment
```bash
act --secret-file .secrets          # Load secrets from file
act -s GITHUB_TOKEN=$GITHUB_TOKEN   # Pass specific secret
act --env-file .env                 # Load environment variables
```

### Offline mode (after images cached)
```bash
act --pull=false --action-offline-mode
```

### Artifact collection
```bash
act --artifact-server-path /tmp/artifacts
# Artifacts appear in /tmp/artifacts/<run-id>/
```

## dsr Integration

dsr wraps act with additional features:

1. **Auto-detection**: Parses workflow files to identify targets
2. **Routing**: Sends Linux to act, macOS/Windows to native SSH
3. **Artifact collection**: Consolidates artifacts from all sources
4. **Logging**: Structured logs with timing and error tracking

### dsr build flow (Linux via act)

```
dsr build --repo ntm --targets linux/amd64
    │
    ├─→ Parse .github/workflows/release.yml
    ├─→ Identify Linux jobs (runs-on: ubuntu-*)
    ├─→ Run: act -j build-linux -W .github/workflows/release.yml
    ├─→ Collect artifacts from act artifact server
    └─→ Sign artifacts, generate checksums
```

## Troubleshooting

### "Cannot connect to Docker daemon"
```bash
# Check Docker is running
docker info
# On Linux, add user to docker group
sudo usermod -aG docker $USER
newgrp docker
```

### "Image pull failed"
```bash
# Pre-pull images
docker pull catthehacker/ubuntu:full-22.04
# Or use offline mode after first run
act --pull=false
```

### "Container architecture mismatch"
```bash
# Force amd64 on ARM hosts
act --container-architecture linux/amd64
```

### "Action not found"
```bash
# Some actions need network; disable offline for first run
act --action-offline-mode=false
```

### "Resource exhausted"
```bash
# Increase Docker resources or use smaller image
act -P ubuntu-latest=catthehacker/ubuntu:act-22.04
```

## Performance Tips

1. **Pre-pull images**: Run `docker pull` for runner images before heavy use
2. **Use --pull=false**: Skip image check after first successful run
3. **Cache actions**: Enable `--action-offline-mode` after actions are cached
4. **SSD storage**: Docker storage on SSD significantly improves build times
5. **Parallel jobs**: act respects `jobs.*.needs`, runs independent jobs in parallel
