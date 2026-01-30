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

## Common act Flags

| Flag | Purpose | Example |
|------|---------|---------|
| `-j <job>` | Run specific job | `-j build-linux` |
| `-W <workflow>` | Specify workflow file | `-W .github/workflows/release.yml` |
| `--artifact-server-path` | Artifact output | `--artifact-server-path /tmp/artifacts` |
| `-P ubuntu-latest=catthehacker/ubuntu:act-latest` | Custom image | Platform override |
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
