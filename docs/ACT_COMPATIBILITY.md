# Act Workflow Compatibility Matrix

This document defines which GitHub Actions workflow jobs can run locally via [nektos/act](https://github.com/nektos/act) and which require native build hosts.

## Overview

**act** runs GitHub Actions locally in Docker containers. It supports `ubuntu-*` runners but cannot run `macos-*` or `windows-*` runners natively. For cross-platform builds, dsr uses:

- **act** (Linux/Docker): `ubuntu-*` jobs
- **mmini** (SSH): macOS native builds
- **wlap** (SSH): Windows native builds

## Runner Compatibility

| Runner | act Support | Native Host | Notes |
|--------|-------------|-------------|-------|
| `ubuntu-latest` | Yes | - | Docker container |
| `ubuntu-22.04` | Yes | - | Docker container |
| `ubuntu-20.04` | Yes | - | Docker container |
| `macos-latest` | No | mmini | Requires Apple Silicon |
| `macos-14` | No | mmini | Requires Apple Silicon |
| `macos-13` | No | mmini | Intel or Rosetta |
| `windows-latest` | No | wlap | Requires Windows host |
| `windows-2022` | No | wlap | Requires Windows host |
| `self-hosted` + linux | Partial | varies | May need custom images |

## Tool Compatibility Matrix

Tools from the Dicklesworthstone toolchain with their workflow compatibility:

| Tool | Language | Linux (act) | macOS (mmini) | Windows (wlap) | Workflow |
|------|----------|-------------|---------------|----------------|----------|
| ntm | Go | Yes | Yes | Yes | release.yml |
| bv | Go | Yes | Yes | Yes | release.yml |
| br | Rust | Yes | Yes | Yes | release.yml |
| cass | Rust | Yes | Yes | Yes | release.yml |
| cm | Rust | Yes | Yes | Yes | release.yml |
| ubs | Go | Yes | Yes | Yes | release.yml |
| xf | Go | Yes | Yes | Yes | release.yml |
| ru | Go | Yes | Yes | Yes | release.yml |
| slb | Rust | Yes | Yes | Yes | release.yml |
| caam | Go | Yes | Yes | Yes | release.yml |
| dcg | Go | Yes | Yes | Yes | release.yml |
| ms | Go | Yes | Yes | Yes | release.yml |
| wa | Go | Yes | Yes | Yes | release.yml |
| pt | Go | Yes | Yes | Yes | release.yml |
| rch | Rust | Yes | Yes | Yes | release.yml |
| mcp_agent_mail | Python | Yes | Yes | N/A | release.yml |

## act Job Mapping

The `act_job_map` in repos.d/*.yaml maps target platforms to act jobs:

```yaml
act_job_map:
  linux/amd64: build-linux      # Runs via act
  linux/arm64: build-linux-arm  # Runs via act with QEMU
  darwin/arm64: null            # Native on mmini
  darwin/amd64: null            # Native on mmini (Rosetta)
  windows/amd64: null           # Native on wlap
```

- **Non-null values**: Job ID to run via act
- **null values**: Requires native build host (SSH)

## Per-Host Overrides

Different target platforms require different build strategies:

### linux/amd64 (trj - primary host)

Default act configuration. All Linux jobs run here via Docker.

```yaml
act_overrides:
  platform_image: catthehacker/ubuntu:act-latest
```

### linux/arm64 (trj via cross-compile or QEMU)

Two strategies for ARM64 Linux:

1. **Cross-compile** (preferred for Go/Rust):
   ```yaml
   cross_compile:
     linux/arm64:
       method: native  # Go
       env:
         GOOS: linux
         GOARCH: arm64
   ```

2. **QEMU emulation** (slower, full compatibility):
   ```yaml
   act_overrides:
     linux_arm64_flags:
       - "--container-architecture linux/arm64"
   ```

### darwin/arm64 (mmini)

Native builds via SSH. Required for macOS code signing.

```yaml
act_job_map:
  darwin/arm64: null  # Native build required

native_build:
  darwin/arm64:
    host: mmini
    connection: ssh
```

### windows/amd64 (wlap)

Native builds via SSH. Required for Windows code signing.

```yaml
act_job_map:
  windows/amd64: null  # Native build required

native_build:
  windows/amd64:
    host: wlap
    connection: ssh
```

---

## Common act Flags

| Flag | Purpose | Example |
|------|---------|---------|
| `-j <job>` | Run specific job | `-j build-linux` |
| `-W <workflow>` | Specify workflow file | `-W .github/workflows/release.yml` |
| `--artifact-server-path` | Artifact output | `--artifact-server-path /tmp/artifacts` |
| `-P ubuntu-latest=catthehacker/ubuntu:act-latest` | Custom image | Platform override |
| `--matrix key:value` | Filter job matrix to a specific value | `--matrix os:ubuntu-latest --matrix target:linux/amd64` |
| `--env-file` | Environment variables | `--env-file .env.act` |
| `-s GITHUB_TOKEN` | Pass secrets | `-s GITHUB_TOKEN` |
| `-e <event.json>` | Event payload | `-e event.json` |

## Known Limitations

### Jobs That Cannot Run in act

1. **macOS code signing**: Requires real macOS for codesign
2. **Windows native compilation**: MSVC, .NET Framework
3. **Docker-in-Docker**: Some act images have limited Docker support
4. **Hardware-specific tests**: GPU, network interfaces
5. **Service containers**: May need manual setup

### Workarounds

1. **Cross-compilation**: Use cargo-zigbuild for Windows/ARM targets on Linux
2. **Matrix splitting**: Separate Linux jobs from macOS/Windows in workflow
3. **Environment variables**: `ACT=true` to detect act environment

## Workflow Best Practices

### Separating Runners

```yaml
jobs:
  build-linux:
    runs-on: ubuntu-latest
    # ... (act compatible)

  build-macos:
    runs-on: macos-latest
    # ... (requires native)

  build-windows:
    runs-on: windows-latest
    # ... (requires native)
```

### Matrix Filtering for Targeted Builds

If your release job uses a build matrix (single job with multiple platform entries), dsr can
filter the matrix values it passes to act. Add `act_matrix` per target in your repo config:

```yaml
act_matrix:
  "linux/amd64":
    os: ubuntu-latest
    target: linux/amd64
```

dsr will pass each key/value as `--matrix key:value` when invoking act for that target.

#### Shared jobs with additional release assets

A single matrix job can produce the primary archive and typed companions for
several configured targets. Each owner needs its own `act_matrix` filters:

```yaml
act_job_map:
  linux/amd64: release
  linux/arm64: release
act_matrix:
  linux/amd64: {target: x86_64-unknown-linux-gnu}
  linux/arm64: {target: aarch64-unknown-linux-gnu}
workspace_additional_artifacts:
  linux/amd64:
    - {name: linux-amd64-metadata.json, format: json}
  linux/arm64:
    - {name: linux-arm64-metadata.json, format: json}
```

The workflow's `release` job must have a literal `strategy.matrix`, using
scalar axes, `include` rows, `exclude` rows, or an include-only matrix. DSR
expands that matrix before starting act and requires each configured owner to
select exactly one distinct cell. This check includes peers outside the
requested CLI subset and peers without additional artifacts. Strings, integers
and booleans are supported; dynamic expressions, nested values, missing filter
keys, overlapping owners, and selections that match zero or multiple cells
require a different configuration. One selected cell may produce several
compiler variants of its platform; the cell must upload every declared primary.

For example, a cell that builds both GNU and musl archives can use:

```yaml
target_triples:
  linux/amd64: [x86_64-unknown-linux-gnu, x86_64-unknown-linux-musl]
artifact_naming: '${name}-${version}-${target_triple}'
install_script_compat: '${name}-${target_triple}'
archive_format: tar.gz
workspace_additional_artifacts:
  linux/amd64:
    - {name: linux-amd64-metadata.json, format: json}
    - {name: linux-amd64-runtime.zip, format: zip}
```

Each variant owns a distinct required primary archive and optional installer
alias. Names must remain unique across variants, platforms and companions,
including case-insensitive comparisons. A supplied alias must contain the
same bytes as its corresponding primary. DSR validates every archive's
configured executables and architecture, retains the original compressed
bytes, and binds each primary, alias and checksum to its configured target
triple. Missing variants or contradictory aliases fail collection.

The metadata and runtime ZIP in this example remain platform-level assets,
collected once. As with native `workspace_additional_artifacts`, the ordinary
manifest assigns these shared assets to the platform's first configured
triple; that ownership does not describe the metadata's ABI. Manifest admission
reconstructs the complete plan, so changed variants, names, ordering or file
identities invalidate retained evidence. Strict multi-variant release contracts
continue to require their existing native compiler and source receipts.

Companions that differ by compiler variant can declare an exact selector in
the same array:

```yaml
workspace_additional_artifacts:
  linux/amd64:
    - {name: linux-metadata.json, format: json}
    - {name: runtime-gnu.zip, format: zip, target_triple: x86_64-unknown-linux-gnu}
    - {name: runtime-musl.zip, format: zip, target_triple: x86_64-unknown-linux-musl}
```

Each explicit `target_triple` must appear in that platform's configured
`target_triples`. Null, empty, unknown and foreign-platform selectors fail
before the producer starts. Names remain globally unique, including across
variants. Native tasks collect only their own declared files; untyped files
keep their first-variant producer. A workflow's selected cell must upload all
declared companions alongside every primary. The configured selector, literal
name, declared format, digest, size and file identity stay bound through
collection and manifest admission. A filename containing `gnu` or `musl`
cannot override the declaration.

For strict releases, list both runtime names in `exact_additional_assets` as
usual. Explicitly selected companions retain the physical platform and
`target_triple` in the manifest and upload plan. Untyped strict companions keep
`target: "additional"` without a compiler identity. Primary coverage is checked
against `exact_primary_assets`; an extra runtime file cannot satisfy a missing
primary. Signed installer recipes can select the matching runtime archive in
their `files` list, and the existing installer rejects a runtime owned by a
different compiler variant.

Peers that have no additional artifacts receive the same matrix and argument
binding with a primary-only payload plan. Selecting such a peer alone retains
the shared job's ownership checks and rejects undeclared uploads.

This follows [act's matrix selection rules](https://nektosact.com/usage/index.html#specifying-matrix),
including its treatment of missing keys and repeated filters. Keep shared-job
matrix filters in `act_matrix`: `--matrix` in a user or invocation `.actrc`
would broaden the CLI selection, so DSR refuses it for these jobs. Additional
platform flags cannot change their job, workflow, working directory or artifact
destination, or add matrix values.

Each worker retains its selected cell and a SHA-256 of the complete configured
argument vector in the existing payload plan. Manifest admission resolves the
plan again and refuses changed selections or arguments. Transport ZIPs, extracted
primaries and typed companions retain independent inventories for each target;
existing architecture, content, collision and resume checks still apply.

DSR passes image mappings, matrix values, secret-file paths and env-file paths
as literal arguments, including spaces and colons. `linux_arm64_flags` entries
use shell-style quoting only to group arguments; they never expand variables,
globs or command substitutions. For example:

```yaml
act_overrides:
  secrets_file: /opt/release keys/act.secrets
  env_file: /opt/release config/build.env
  linux_arm64_flags:
    - "--container-architecture linux/arm64"
    - "--container-options '--label=release lane'"
```

### Detecting act Environment

```yaml
- name: Check if running in act
  if: ${{ env.ACT }}
  run: echo "Running in act"
```

### Artifact Naming for Multi-Platform

```yaml
- name: Upload artifact
  uses: actions/upload-artifact@v4
  with:
    name: ${{ matrix.binary_name }}-${{ matrix.target }}
    path: target/release/${{ matrix.binary_name }}
```

## Pinned sibling sources in workflow builds

Ordinary Linux workflow targets can use the same pinned `sibling_crates`
configuration as isolated fallback and native source staging:

```yaml
sibling_crates:
  - local_path: /data/projects/shared_library
    relative_path: shared_library
    revision: 0123456789abcdef0123456789abcdef01234567 # replace with the exact commit
```

For each act attempt, DSR creates a fresh private repository at that commit,
including locally available submodules selected by authenticated parent
gitlinks. A dirty developer checkout or a child checked out at a different
commit cannot supply replacement bytes. The private repositories have their
own Git metadata and receive no developer configuration, credentials, hooks,
or shared object stores. Missing pinned objects are refused; submodule URLs
are not fetched.

DSR keeps the main repository's normal act working directory and mounts each
private sibling read-only at its configured `../relative_path`. On Unix, act
uses the absolute `--directory` path inside its container. DSR derives the
mount destination from that path. Cargo manifests and source files keep their
original relative paths.

The runner writes a per-attempt workflow projection outside the repository
and outside the artifact upload directory. It adds the sibling mounts to
`jobs.<job>.container.volumes` for the selected job and its local `needs`
dependencies. Act passes these volumes to both the job container and Docker
actions. Existing image, environment, credentials, and nonconflicting volumes
are preserved. For jobs without a container declaration, the projection keeps
the configured runner image and preserves the effective `--container-options`
from act's XDG, home, invocation-directory, and CLI argument order. Existing
job-level container options retain their precedence. Workflows must direct
writable build outputs outside the read-only sibling repositories.

Admission refuses layouts whose meaning cannot be preserved before running
act: selected reusable workflow jobs; expression-valued whole container
declarations, options, or volumes; volumes that overlap a source mount;
Docker mount, tmpfs, workdir, or privilege overrides; act directory, workflow,
job, bind, reuse, or checkout overrides; and `-self-hosted` execution that
would bypass container mounts. Main and mount paths must be canonical Unix
paths without colons, backslashes, or control characters. Spaces remain
literal path characters. Unrelated reusable jobs are allowed when the selected
job does not depend on them.

The scheduler's `workflow_source` task identity binds the original workflow
hash, effective act arguments and container configuration, selected jobs, and
sibling pins. Each result's `source_layout` receipt also retains the projected
workflow hash, literal read-only mounts, and complete private sibling/submodule
graph. DSR reconstructs the projection from the original workflow and verifies
the private graph before execution, after execution, at manifest admission,
and before reusing completed output. A changed plan refuses resume; missing or
changed retained source evidence cannot authorize reuse. Failed attempts and
their private sources remain available for inspection.

This projection targets act's container runner. Its Git selection, custody,
projection, scheduler, and resume boundaries have local fixture coverage;
real act parser/image-selection checks do not substitute for a live Docker
build on the configured host.

## Using the Compatibility Matrix

The `act_runner.sh` module provides functions to query the compatibility matrix:

```bash
source src/act_runner.sh

# Load a tool's configuration
act_load_repo_config ntm
# → [act] Loaded config for ntm: Dicklesworthstone/ntm

# Get the job to run for a platform
act_get_job_for_target ntm linux/amd64
# → build

act_get_job_for_target ntm darwin/arm64
# → (empty - native build required)

# Check if a platform uses act or native
act_platform_uses_act ntm linux/amd64 && echo "act" || echo "native"
# → act

act_platform_uses_act ntm darwin/arm64 && echo "act" || echo "native"
# → native

# Get the build strategy for a platform
act_get_build_strategy ntm linux/amd64
# → {"tool":"ntm","platform":"linux/amd64","method":"act","host":"trj","job":"build"}

act_get_build_strategy cass darwin/arm64
# → {"tool":"cass","platform":"darwin/arm64","method":"native","host":"mmini","job":""}

# Get all targets for a tool
act_get_targets ntm
# → linux/amd64 linux/arm64 darwin/arm64 darwin/amd64 windows/amd64

# List all configured tools
act_list_tools
# → br bv cass ntm

# Generate full build matrix
act_build_matrix ntm | jq .
# → [{"tool":"ntm","platform":"linux/amd64","method":"act",...}, ...]
```

---

## Testing act Compatibility

Use dsr's built-in analysis:

```bash
# Analyze a workflow
dsr check --analyze-workflow /path/to/repo/.github/workflows/release.yml

# Test run a specific job
act -j build-linux -W .github/workflows/release.yml --dryrun
```

## References

- [nektos/act GitHub](https://github.com/nektos/act)
- [act User Guide](https://nektosact.com/)
- [dsr CLI Contract](CLI_CONTRACT.md)
- [dsr act Setup](ACT_SETUP.md)
