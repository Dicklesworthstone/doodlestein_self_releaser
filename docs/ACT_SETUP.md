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

Create `~/.actrc` for consistent behavior. **The easiest way:**

```bash
cp /path/to/dsr/config/actrc.example ~/.actrc
```

Or create manually:

```bash
# Default runner images (pin for reproducibility)
-P ubuntu-latest=catthehacker/ubuntu:full-22.04
-P ubuntu-22.04=catthehacker/ubuntu:full-22.04
-P ubuntu-20.04=catthehacker/ubuntu:full-20.04

# Architecture settings
--container-architecture linux/amd64

# Bind mount for faster file access
--bind

# CRITICAL: Prevent UID mismatch!
# catthehacker images run as UID 1001 (user "runner")
# Without this, files created by act will have wrong ownership
--container-options --user=1000:1000

# Artifact collection
--artifact-server-path /tmp/dsr-act-artifacts
```

> **CRITICAL: The `--user` Line**
>
> Replace `1000:1000` with your actual UID:GID. Find yours with:
> ```bash
> id -u   # Your UID (usually 1000 on single-user systems)
> id -g   # Your GID (usually 1000)
> ```
>
> Without this line, **all files created by act will be owned by UID 1001**, making them inaccessible to your normal user. This breaks:
> - Git operations (permission denied on .git files)
> - Build tools (can't write to target directories)
> - Other processes accessing the same directories
>
> **Always run `dsr doctor` after configuration to verify.**

## Verifying Your Configuration

```bash
# Check actrc is properly configured
dsr doctor

# Should show:
#   actrc: configured correctly (--bind with --user)

# If you see this error, your actrc needs the --user line:
#   actrc: CRITICAL - --bind without --user flag
```

## Platform Mapping

| Workflow `runs-on` | dsr Action |
|-------------------|------------|
| `ubuntu-latest` | Run via act on css |
| `ubuntu-*` | Run via act on css |
| `macos-*` | Native SSH to mmini |
| `windows-*` | Native SSH to wlap |
| `self-hosted` | Check labels, route accordingly |

## Windows native source synchronization

Windows jobs run natively over SSH, not inside act's Linux containers. Configure
`windows_rsync_drive_prefix` for the Windows host in `hosts.yaml` when its rsync
uses a mount convention other than Cygwin's default:

```yaml
hosts:
  wlap:
    platform: windows/amd64
    connection: ssh
    ssh_host: wlap
    windows_rsync_drive_prefix: ""  # MSYS2: C:/d/app becomes /c/d/app
```

Omitting the setting preserves `/cygdrive`, so existing Cygwin hosts need no
change. An explicit `/cygdrive` has the same effect. A custom absolute prefix
such as `/drives` maps `C:/d/app` to `/drives/c/d/app`. Prefixes must have no
trailing slash, empty path components, `.`/`..` components or shell syntax.
The empty string is intentional and is distinct from null or a missing field;
booleans, numbers, collections and invalid strings fail rather than silently
selecting another runtime's path convention.

The setting is per host and is reread for each source transfer, including
sibling sources that use the same transfer path. It is resolved before remote
directory creation and reused for that transfer's bounded retries. It does not
change native `C:/...` paths passed to PowerShell/CMD, artifact streaming, or tar
fallback. Runtime autodetection is not performed: choose the prefix belonging
to the actual remote rsync installation.

Run `bash scripts/tests/test_windows_rsync_paths.sh`. Its YAML integration uses
real Mike Farah yq and the shared single-document/duplicate-key configuration
gate; those cases skip explicitly when yq is unavailable. The path-policy tests
use genuine Bash and jq. They do not simulate a Windows host or claim a native
Windows SSH/rsync acceptance run.

## Native companion artifact paths

`workspace_archive_files` and `workspace_additional_artifacts` name literal
files in the same effective output directory as the native binaries. For Rust,
this follows `CARGO_TARGET_DIR`, `CARGO_BUILD_TARGET`, and the build profile;
for Go it follows `GOBIN` when configured. The default Rust directory is
`<source>/target/<profile>`.

On Windows, a companion named `ui-1.6.0-x86_64.msi`, `manifest.json`,
`verify-components.sh`, or `NOTICE` is read from exactly that basename.
DSR does not append `.exe` or fall back to a differently named executable.
Actual workspace binaries retain their usual Windows `.exe` handling.
For an archive companion, `executable: true` sets its executable permissions;
it does not change its filename. Missing companions fail collection with the
host and exact attempted source path in the diagnostic.

The existing collection receipts bind the transferred bytes, SHA-256, size,
and destination identity. Literal filenames do not add format-specific MSI
or archive validation.

## Git-aware ordinary source synchronization

For ordinary source directories inside a Git worktree, rsync exclusions come
from Git's actual ignored, untracked paths. Tracked inputs remain available
even when an ignore pattern matches a parent directory. For example, a tracked
`internal/webui/dist/index.html` needed by `go:embed` is transferred when the
root `.gitignore` contains `dist/` and `!internal/webui/dist/`.

Git evaluates nested ignore files, `.git/info/exclude`, global excludes, and
negations. DSR passes the resulting literal paths to rsync with NUL delimiters,
so spaces, newlines, backslashes, and wildcard characters in filenames retain
their meaning. Existing build-cache/secret exclusions, explicit extra
exclusions, checksum-based replacement, and stale-file deletion still apply.
An unreadable Git inventory stops the transfer before destination writes.

Run `bash scripts/tests/test_native_source_sync.sh --git-selection-only` for
the focused Git, rsync, and tar regression without Rust compiler prerequisites.

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

### Files owned by wrong user (UID 1001)

**Symptom:** After running act, some files are owned by user ID 1001 instead of your user:

```bash
$ ls -la
drwx------ 1001 1001 310 Jan 31 14:24 .beads
-rw-r--r-- 1001 1001 4.0K Jan 25 16:18 some_file
```

**Cause:** The catthehacker runner images run as UID 1001 (user "runner"). When act bind-mounts your repo (`--bind`), files created inside the container get UID 1001 ownership.

**Fix:**

1. Add user mapping to `~/.actrc`:
   ```bash
   echo '--container-options --user=$(id -u):$(id -g)' >> ~/.actrc
   ```

2. Fix existing files:
   ```bash
   sudo chown -R $(id -un):$(id -gn) /path/to/repo
   ```

3. Verify the fix:
   ```bash
   dsr doctor
   # Should show: actrc: configured correctly (--bind with --user)
   ```

**Prevention:** Always use the example config:
```bash
cp /path/to/dsr/config/actrc.example ~/.actrc
```

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
