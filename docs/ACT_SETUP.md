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

`workspace_additional_artifacts` accepts literal strings for opaque files, or
explicit `name` and `format` declarations when collection must check content:

```yaml
workspace_additional_artifacts:
  windows/amd64:
    - name: ui-1.6.0-x86_64.msi
      format: msi
    - name: manifest.json
      format: json
    - name: bundle.zip
      format: zip
    - name: helper.EXE
      format: binary
    - NOTICE
```

Put these declarations in `repos.d/<tool>.yaml`. When that file exists, it is
the native build authority; omitted declarations mean no additional files, and
are not filled from the repository registry during preflight.

These declarations also opt an ordinary `act` target into exact workflow
payload collection. Native targets read the files from their effective output
directory; workflow jobs upload them alongside their primary release archive.
Set a target's `act_job_map` entry to `null`, an empty string or the string
`"null"` when selecting a native build. Typed declarations reject malformed job
selectors, including Boolean values, before execution. A workflow target with
no additional declarations retains its existing artifact collection behavior.
Strict release contracts still require native producers.

Names remain literal for every format, including `binary`. For example,
`helper.EXE` is collected under that exact spelling. Each name has one configured
producer across the complete platform mapping; duplicates, including names
that differ only by case, are rejected. A platform with several target triples
collects its additional files from its first configured triple. Primary
executables and `workspace_binaries` retain their existing target architecture
and executable checks.

Ordinary `dsr release` also preserves these literal names. A declared companion
must belong to its configured platform and, when target triples are configured,
the first triple. Words such as `gnu` or `musl` in a companion name are ordinary
filename text; they do not identify its ABI. Archive companions keep their own
names instead of claiming the primary executable's archive aliases. The usual
explicit `target_triple` requirement still applies to platforms with multiple
configured variants, and primary executable names still undergo variant checks.
Manifest hashes, complete inventory validation and upload collision checks apply
to both primary artifacts and companions.

Checksum, signature, SBOM and provenance names belong to the existing release
metadata generators. Additional declarations cannot use `.sha256`, `.sha512`,
`.sig` or `.minisig` suffixes, `SHA256SUMS*`, `checksums.txt`, `*.sbom.*`, or
`*.intoto.jsonl` names, ignoring case. Configuration validation identifies such
a name as reserved before compilation.

| Format | Required content |
| --- | --- |
| `file`, or a plain string | Nonempty regular file; its bytes remain opaque. |
| `binary` | Native executable format and architecture matching the owning target. |
| `json` | One complete UTF-8 JSON document, at most 16 MiB, without duplicate keys or non-finite numbers. |
| `zip`, `tar.gz`, `tar.xz` | Correct container/compression, complete readable members, valid ZIP CRC/compressed trailers, and the existing archive path, entry-type and expansion limits. |
| `msi` | Structurally valid Windows Installer database compound file, including bounded allocation chains, directory and stream consistency, the Windows Installer database root class, and SummaryInformation metadata. |

The MSI check distinguishes ordinary OLE documents and truncated compound files.
It does not establish that Windows Installer can install the database, or
authenticate its publisher. Microsoft documents that merge modules and patch
creation files share the database class identifier; Windows installation
semantics and Authenticode require their own tooling. SummaryInformation
admission supports the `I2`, `I4`, `LPSTR` and `FILETIME` property types used by
Installer databases and rejects other property types explicitly. See Microsoft's
[Windows Installer file type identifiers](https://devblogs.microsoft.com/setup/identifying-windows-installer-file-types/)
and [Compound File Binary Format specification](https://learn.microsoft.com/en-us/openspecs/windows_protocols/ms-cfb/).

Malformed declarations, unsupported formats and invalid platform owners fail
configuration validation before source staging or compilation, even on a
platform omitted from the current build selection. Content checks run after
collection and again before manifest admission, using the declared type from
the repository configuration. Each successful check is bound to the same
SHA-256, size and destination identity as the collection receipt. A failed
check identifies the file, expected format, host and literal source path;
its bytes receive no accepted additional-artifact receipt. Checksums,
signatures, provenance and publication gates continue to apply independently.

Run `bash scripts/tests/test_act_runner_native.sh --typed-companions-only` for
the focused collection and manifest regressions, and
`bash scripts/tests/test_artifact_formats.sh` for malformed JSON/compound-file
coverage. These use real file content and production validators with controlled
SSH/compiler transport; they do not claim a native Windows build or installer
execution.

### Typed companions from workflow jobs

An opted-in workflow job must belong to exactly one configured physical target,
with at most one configured target triple. Distinct targets need distinct job
names, including targets without additional declarations. DSR checks the whole
configuration before invoking `act`; a target subset cannot hide shared jobs,
multiple compiler variants or ambiguous primary names. This bounded contract
does not split a matrix-wide upload among several producers.

The job must upload the versioned primary name resolved by `artifact_naming`
and `archive_format`, together with every declared companion. The primary
format must be `tar.gz`, `tar.xz` or `zip`, and its root must contain
`binary_name` or every selected `workspace_binaries` executable. DSR checks the
archive's complete readable content and each configured executable's target
format and architecture. Ordinary regular-file notices inside the archive are
permitted. The distinct name resolved by `install_script_compat` is optional;
when supplied, it undergoes the same primary validation.

Upload ZIP wrappers may contain these files under safe nested paths. DSR
materializes their literal basenames into a private, flat payload directory,
rejecting missing, extra, foreign, repeated or case-colliding names. A declared
ZIP companion remains one complete ZIP file; it is not unpacked again by
manifest generation or CLI collection. Unversioned companions, including names
containing words such as `musl`, retain their configured owner and first target
triple without filename-based platform or ABI inference.

An optional `<owned-primary>.sha256` upload is accepted only when it names that
primary and contains its exact digest (a plain digest is also accepted).
Other undeclared files, including aggregate metadata, are refused. Normal DSR
checksum, signing, provenance and publication stages continue independently.

The original transport tree and materialized payload tree remain separate in
the worker result. Both complete inventories are frozen for resume checks;
changed, added, removed or replaced files invalidate reuse. Linked files,
linked directories and special entries are refused. Manifest admission repeats
the configuration ownership, required inventory, type, hash, size and file
identity checks before using the materialized paths.

Run `bash scripts/tests/test_act_runner.sh --typed-companions-only` for the
focused workflow tests. They launch the real worker and production collection,
manifest and provenance code, with controlled external `act`/Docker transport
and inert executable-header fixtures. They cover concurrent producer isolation
and malicious or contradictory uploads; they do not claim Docker execution or
a real compiler run.

For ordinary release planning, run
`DSR_RELEASE_RESUME_TEST_FILTER='^test_literal_companion_' bash scripts/tests/test_release_resume.sh`.
These dry-run command tests use byte-bound manifest fixtures and the production
configuration, naming and inventory validators, without remote requests.

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

Each workflow invocation reserves a new private upload directory and an
exclusive log file. The returned `run_id`, `artifact_dir`, and `log_file`
identify that invocation, including failed jobs and retries. Parallel targets
and retries started in the same second cannot reuse another invocation's
uploads or overwrite its log. Successful workers freeze the files from their
own directory into the existing resume receipts; a failed peer's output does
not invalidate those completed receipts.

Workflows that need to create sibling directories also receive separate
isolated HOME directories, so concurrent jobs cannot combine their generated
act configuration. Failure to allocate a run directory or reserve its log
stops the invocation before act starts.

Run `bash scripts/tests/test_act_runner.sh --workflow-isolation-only` to check
this boundary without Docker. The test runs real orchestration workers and
receipt validation with a controlled uploader that writes actual ZIP files;
it covers concurrent success and failure, a retry within the same clock
second, retained logs, and isolated HOME ownership. It does not execute a
GitHub Actions job inside a container.

The coordinator also owns the task stream used to dispatch targets. Target
workers start with empty stdin, so a compiler, transport or build command that
reads stdin cannot consume undispatched tasks. Explicit input streams used by
individual build helpers retain their existing behavior. Target failures still
produce attempt receipts, and resume reuses completed work only after checking
its recorded artifact bytes.

Run `bash scripts/tests/test_act_orchestration.sh --dispatch-stdin-only` for the
focused scheduler regression. It exercises six physical targets serially and
seven physical/variant tasks with two workers, including a failed task, changed
artifact bytes, and selective resume. Native execution is a controlled subprocess
that deliberately reads stdin; the planner, scheduler, worker supervision and
state/receipt validation are production code.

Every native invocation also reserves a private log directory before remote
preparation or compilation. Its `log_file` identifies that exact attempt,
including failures and retries. Native singleton and variant builds collect
each attempt into a fresh directory under the requested run and target; primary
and companion basenames remain literal. Consumers must use the returned
`artifact_paths`, `additional_artifacts` and `log_file` rather than deriving
paths from a run ID. A retry or concurrent caller cannot replace the bytes
referenced by an earlier result. Unavailable log storage stops execution before
the compiler is invoked.

Run `bash scripts/tests/test_act_runner_native.sh --attempt-isolation-only`
for this boundary. The test executes the production native function,
collection, resume checks and manifest admission with tiny inert executable
fixtures and explicitly controlled remote admission, transport and Cargo cache
responses. It checks sequential and concurrent calls, failed retries, retained
prior receipts, strict/variant log ownership and allocation failures. It does
not run a compiler or qualify a native Windows host.

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
