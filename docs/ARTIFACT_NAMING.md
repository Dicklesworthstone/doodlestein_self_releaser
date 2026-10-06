# Artifact Naming Convention

This document defines the standard artifact naming scheme for dsr builds.

## Naming Format

```
{tool}-{version}-{os}-{arch}[.exe][.archive]
```

Note: dsr can derive naming from workflows (GoReleaser `name_template`, GitHub Actions `matrix.target`). Underscores and target triples are supported; the default format above is a fallback. An explicit release contract takes precedence over these patterns for release output, as described below.

### Exact per-target release names

When `release_contract` is configured, its `exact_primary_assets` mapping owns
release filenames. Native workspace collection uses the same config-aware
resolver, so a mixed Full/Lite matrix no longer chooses the global Full pattern
for a target whose authoritative basename says Lite (issue #26).

```yaml
binary_name: fsfs
workspace_binaries: [fsfs]
artifact_naming: '${name}-${version}-${target_triple}.${ext}'
archive_format:
  darwin: tar.xz
targets: [darwin/arm64, darwin/amd64]
release_contract:
  checksum_sidecar: sha256
  exact_primary_assets:
    darwin/arm64: fsfs-1.12.1-aarch64-apple-darwin.tar.xz
    darwin/amd64: fsfs-lite-1.12.1-x86_64-apple-darwin.tar.xz
```

Exact names are literal basenames, not templates: the resolver does not rewrite
an embedded version or infer an architecture from the name. Keep the contract
consistent with the reviewed release. Missing target entries, unsafe names,
control characters, collisions with other primaries or their declared/implicit
sidecars, and invalid configuration are errors. A `.tar.xz` name cannot be
returned for a gzip writer or vice versa. `.tgz` and `.tar.gz` both designate
gzip; ZIP and raw binary names are handled explicitly.

A closed release contract does not authorize extra inferred installer aliases.
The existing dual-name result therefore returns the same exact primary in
`versioned` and `compat`, with `same: true`. This does not create aliases listed
as additional assets or relax their existing collection/verification checks.
Without a release contract (including an explicit `null` opt-out), the existing
pattern precedence and dual naming below remain unchanged.

Diagnostic-native builds keep their existing pattern-derived names and remain
nonpublishable. The resolver inherits the native orchestrator's `build_purpose`;
standalone callers can pass an explicit seventh argument:

```bash
artifact_naming_generate_dual_for_tool \
  search v1.12.1 darwin amd64 tar.xz /srv/search diagnostic-native
```

The six-argument API defaults to release naming outside a build context. Naming
selection is not source, binary-architecture, signature, or publication proof.
Native collection receipts, member validation, strict staging, and source/tag
checks remain separate and unchanged. In particular, this fixes target-specific
names, not automatic single-binary companion collection (issue #29).

Run `bash scripts/tests/test_artifact_naming_exact_primary.sh` for JSON-boundary
naming tests and actual archive-byte checks. The production configuration-parser
section runs when Mike Farah yq v4 and `src/config.sh` are available;
`DSR_TEST_REQUIRE_YQ=1` makes a missing parser a failing prerequisite. Local
archive fixtures do not claim cross-compilation or native ABI qualification.

### Components

| Component | Format | Examples |
|-----------|--------|----------|
| tool | lowercase alphanumeric | `ntm`, `bv`, `cass` |
| version | semver with v prefix | `v1.2.3`, `v0.1.0-beta.1` |
| os | lowercase | `linux`, `darwin`, `windows` |
| arch | lowercase | `amd64`, `arm64`, `386` |
| .exe | Windows only | (suffix for Windows binaries) |
| .archive | optional | `.tar.gz`, `.tar.xz`, `.zip` |

### Examples

**Raw binaries:**
```
ntm-v1.2.3-linux-amd64
ntm-v1.2.3-darwin-arm64
ntm-v1.2.3-windows-amd64.exe
```

**Archived releases:**
```
ntm-v1.2.3-linux-amd64.tar.gz
ntm-v1.2.3-darwin-arm64.tar.gz
ntm-v1.2.3-windows-amd64.zip
```

**Target triple / underscore variants (workflow-derived):**
```
br-v1.2.3-linux_amd64.tar.gz
dcg-x86_64-unknown-linux-gnu.tar.xz
```

### GNU and musl variants from one workflow

An ordinary release may retain both libc variants under the same scheduling
platform. List their triples in order; the first entry is the primary for native
builds and for filenames that do not identify a variant:

```yaml
targets: [linux/amd64]
target_triples:
  linux/amd64:
    - x86_64-unknown-linux-gnu
    - x86_64-unknown-linux-musl
artifact_naming: '${name}-${version}-${target_triple}.${ext}'
install_script_compat: '${name}-${target_triple}.${ext}'
linux_libc_fallback: none
```

Workflow collection retains each artifact's `target_triple` alongside its
`target: linux/amd64`. A full triple or a separate `gnu`/`musl` word identifies
the variant; an unmarked name uses the configured primary. Conflicting triples
or libc markers are errors. This field records the declared naming identity;
it does not attest the executable's ABI. Packaging and release naming use the
retained triple, so a musl artifact does not become GNU when configuration order
changes or when both artifacts arrive through one act job.

Shared installer aliases remain supported and have one deterministic owner.
Use a target-qualified pattern when installers must select both variants. The
generated installer refuses to install a nonprimary variant through an alias
whose name is also used by the primary, and rejects literal libc markers that
contradict the selected triple.

Generated installers inspect the host libc before selecting an artifact. They
recognize musl even when `ldd --version` writes to stderr and exits nonzero, and
do not guess GNU if libc discovery is inconclusive. `--libc gnu` and
`--libc musl` select exactly that configured variant; an unavailable explicit
request fails. Configured target triples also become part of each cache key, so
GNU and musl archives and their checksum/signature evidence remain independent.
These installers do not adopt older platform-only cache entries.

The default `linux_libc_fallback: none` requires the detected variant. Setting
`linux_libc_fallback: musl` permits an automatic GNU host to use a configured
musl variant when GNU is unconfigured or its payload/cache entry is unavailable.
This is appropriate only for a musl build the project supports on GNU hosts.
The policy never substitutes GNU on musl, never overrides an explicit `--libc`
request, and never retries another libc after checksum, signature, extraction,
or binary-selection failure. Offline fallback follows the same policy and reads
only the selected variant's verified cache entry.

Native builds still compile the primary only; workflow-produced artifacts can
carry the full list. A strict `release_contract` continues to admit one primary
per platform. These paths do not yet implement a native GNU-plus-musl build
matrix. `scripts/tests/test_multi_variant_installer.sh` compiles and executes
real GNU and musl Rust fixtures when both standard libraries are installed, and
checks selection, isolated offline caches, corruption refusal, and the fallback
policy using fixture release transports.

## Checksum Files

### SHA256SUMS

All checksums are stored in a single file:
```
{tool}-{version}-checksums.sha256
```

Format (BSD-style, compatible with `sha256sum -c`):
```
abc123def456...  ntm-v1.2.3-linux-amd64.tar.gz
def456abc789...  ntm-v1.2.3-darwin-arm64.tar.gz
789abc123def...  ntm-v1.2.3-windows-amd64.zip
```

## Signatures

### minisign signatures

Each artifact can have a corresponding signature:
```
ntm-v1.2.3-linux-amd64.tar.gz.minisig
ntm-v1.2.3-darwin-arm64.tar.gz.minisig
ntm-v1.2.3-windows-amd64.zip.minisig
```

The checksums file is also signed:
```
ntm-v1.2.3-checksums.sha256.minisig
```

## Build Manifest

Every build produces a manifest JSON file:
```
{tool}-{version}-manifest.json
```

The manifest contains:
- Tool name and version
- Git SHA and ref
- Build timestamp and duration
- List of all artifacts with checksums
- Host status for each build target
- SBOM and signature file references

See `schemas/manifest.json` for the full schema.

### Example Manifest

```json
{
  "schema_version": "1.0.0",
  "tool": "ntm",
  "version": "v1.2.3",
  "run_id": "550e8400-e29b-41d4-a716-446655440000",
  "git_sha": "abc123def456789...",
  "git_ref": "v1.2.3",
  "built_at": "2026-01-30T15:00:00Z",
  "duration_ms": 180000,
  "builder": {
    "tool": "dsr",
    "version": "0.1.0",
    "trigger": "throttle-fallback"
  },
  "artifacts": [
    {
      "name": "ntm-v1.2.3-linux-amd64.tar.gz",
      "target": "linux/amd64",
      "sha256": "abc123...",
      "size_bytes": 5242880,
      "archive_format": "tar.gz",
      "signed": true,
      "signature_file": "ntm-v1.2.3-linux-amd64.tar.gz.minisig"
    }
  ],
  "hosts": [
    {
      "host": "trj",
      "platform": "linux/amd64",
      "status": "success",
      "method": "act",
      "duration_ms": 60000,
      "workflow": ".github/workflows/release.yml",
      "job": "build-linux"
    },
    {
      "host": "mmini",
      "platform": "darwin/arm64",
      "status": "success",
      "method": "native-ssh",
      "duration_ms": 45000
    }
  ],
  "checksums_file": "ntm-v1.2.3-checksums.sha256",
  "signature_file": "ntm-v1.2.3-checksums.sha256.minisig",
  "sbom_file": "ntm-v1.2.3-sbom.json"
}
```

## SBOM (Software Bill of Materials)

Generated using `syft`:
```
{tool}-{version}-sbom.json
```

Format: SPDX JSON or CycloneDX JSON.

## Directory Structure

Release artifacts are organized as:
```
~/.local/state/dsr/artifacts/{tool}/{version}/
├── ntm-v1.2.3-linux-amd64.tar.gz
├── ntm-v1.2.3-linux-amd64.tar.gz.minisig
├── ntm-v1.2.3-darwin-arm64.tar.gz
├── ntm-v1.2.3-darwin-arm64.tar.gz.minisig
├── ntm-v1.2.3-windows-amd64.zip
├── ntm-v1.2.3-windows-amd64.zip.minisig
├── ntm-v1.2.3-checksums.sha256
├── ntm-v1.2.3-checksums.sha256.minisig
├── ntm-v1.2.3-manifest.json
└── ntm-v1.2.3-sbom.json
```

## Platform Targets

Standard targets supported by dsr:

| Target | OS | Arch | Archive | Host |
|--------|-----|------|---------|------|
| linux/amd64 | Linux | x86_64 | tar.gz | trj (act) |
| linux/arm64 | Linux | ARM64 | tar.gz | trj (act/QEMU) |
| darwin/arm64 | macOS | Apple Silicon | tar.gz | mmini |
| darwin/amd64 | macOS | Intel | tar.gz | mmini (Rosetta) |
| windows/amd64 | Windows | x86_64 | zip | wlap |

## Dual Naming for Install Script Compatibility

Without a closed release contract, dsr uploads artifacts with TWO naming conventions to ensure compatibility with both explicit version downloads and install.sh scripts:

1. **Versioned name**: `{tool}-{version}-{os}-{arch}.{ext}` — For explicit version downloads
2. **Compat name**: `{tool}-{os}-{arch}.{ext}` — For install.sh scripts expecting unversioned names

### Configuration

Configure dual naming in `repos.d/{tool}.yaml`:

```yaml
tool_name: cass

# Versioned naming (for explicit downloads)
artifact_naming: "${name}-${version}-${os}_${arch}"

# Option 1: Explicit compat pattern (recommended for edge cases)
install_script_compat: "${name}-${os}-${arch}"

# Optional: target triple overrides (for workflows using matrix.target).
# A list ships several variants of one platform, primary first: each artifact
# is named for its own variant and installers pick gnu or musl at run time
# (see "gnu and musl variants of one platform" in the README).
target_triples:
  linux/amd64:
    - x86_64-unknown-linux-gnu
    - x86_64-unknown-linux-musl
  darwin/arm64: aarch64-apple-darwin

# Optional: arch aliases for install.sh compat (amd64 -> x86_64)
arch_aliases:
  amd64: x86_64

# Option 2: Auto-detect from install.sh (recommended for most cases)
install_script_path: install.sh
```

### Precedence Rules

When generating compat names without a release contract, dsr uses this precedence:

1. **install_script_compat** — Explicit override, highest priority
2. **install_script_path** — Parse the script to auto-detect the expected pattern
3. **Fallback heuristic** — Strip version from artifact_naming

### Variable Substitution

Patterns support these variables:

| Variable | Description | Example |
|----------|-------------|---------|
| `${name}` | Tool name | `cass` |
| `${version}` | Version (stripped of 'v' prefix) | `0.1.64` |
| `${os}` | Operating system | `darwin` |
| `${arch}` | Architecture | `arm64` |
| `${target}` | Combined os-arch (after arch aliases) | `darwin-arm64` |
| `${target_triple}` | Full target triple | `x86_64-unknown-linux-gnu` |
| `${ext}` | File extension | `.tar.gz` |

### Examples

**Versioned downloads (explicit version):**
```
cass-0.1.64-darwin_arm64.tar.gz
rch-1.0.1-x86_64-unknown-linux-gnu.tar.gz
```

**Install.sh compatible (unversioned):**
```
cass-darwin-arm64.tar.gz
rch-linux-x86_64.tar.gz
```

If the compat pattern has **no archive extension**, dsr treats it as a raw binary alias
(e.g., `ntm_darwin_arm64`), copying the built binary instead of an archive.

### Checksums

Checksum files include entries for BOTH naming variants:
```
abc123...  cass-0.1.64-darwin_arm64.tar.gz
abc123...  cass-darwin-arm64.tar.gz
```

### Validation

Use `dsr repos validate` to check naming consistency:
```bash
# Validate all registered repos
dsr repos validate

# Validate specific repo
dsr repos validate --repo cass
```

## Validation

Artifact names can be validated against the regex below for the default hyphenated pattern.
Workflow-derived patterns (underscores, target triples) may not match this regex.
```regex
^[a-z][a-z0-9_-]+-v[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?-(linux|darwin|windows)-(amd64|arm64|386)(\.exe)?(\.tar\.gz|\.zip)?$
```

Example validation in bash:
```bash
validate_artifact_name() {
    local name="$1"
    local pattern='^[a-z][a-z0-9_-]+-v[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?-(linux|darwin|windows)-(amd64|arm64|386)(\.exe)?(\.tar\.gz|\.zip)?$'
    [[ "$name" =~ $pattern ]]
}
```
