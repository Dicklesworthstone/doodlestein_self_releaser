# Build with the pinned Windows ARM64 view

`scripts/xwin-build.sh` consumes the manifest specified in
[XWIN_TOOLCHAIN.md](XWIN_TOOLCHAIN.md), runs the pinned cargo-xwin plugin, and
admits an executable only after toolchain revalidation and ARM64 PE verification.
The opt-in release mode stages an exact Git commit and emits DSR's existing
successful-build manifest for the verified publication pipeline. Ordinary mode
still accepts an already-staged project. Neither mode automatically changes
`dsr build` routing or publishes a GitHub release.

## Invocation

In addition to the preparation manifest's five required tool identities, build
execution requires `tools.llvm-ar` with an absolute regular-file path and its
actual SHA-256. The runner provides `llvm-lib` and `llvm-dlltool` invocation
names for that multicall binary, and `clang++` for clang. Explicitly pinned
entries for those roles override the defaults. Include any other required
build tools, such as cmake or ninja, in `tools` to select them before system
PATH. Executables must support their normal version flags.

```bash
bash scripts/xwin-build.sh \
  --manifest /opt/pinned/windows-arm64-toolchain.json \
  --project /var/tmp/dsr-staged/project \
  --bin example-tool \
  --run-dir /var/tmp/dsr-runs/windows-arm64-001 \
  --cargo-cache /home/builder/.cargo \
  --offline > windows-arm64-result.json
```

`--run-dir` must be a new absolute directory with an existing parent. No prior
run is overwritten or implicitly resumed. `--package NAME` selects a workspace
package; `--bin NAME` is mandatory. The build always uses `--release`,
`--locked`, and `--target aarch64-pc-windows-msvc`. The project must have a
regular `Cargo.toml` and `Cargo.lock`. `--timeout SECONDS` bounds compilation
(default 3600; range 1..86400). `--cache-dir DIR` selects the prepared-view
cache. Build execution also requires Python 3, GNU timeout, and util-linux
setsid on a Linux host. Release mode requires Python 3.9+ and Git.

`--offline` requests Cargo's offline behavior. Without it, Cargo may fetch
locked dependencies. `--cargo-cache` is optional: only its `registry/` and
`git/` download directories are linked into a fresh Cargo home. Configuration,
credentials, binaries, and unrelated files are not inherited. The linked
cache remains writable by Cargo; it is not a frozen source snapshot. The
runner intentionally does not inherit proxy variables, registry credentials,
or arbitrary environment overrides. Projects requiring custom registries
must supply appropriate reviewed project configuration.

## Source-pinned release mode

Supply all three identity flags together. `SOURCE_SHA` below is the reviewed,
full 40-character commit to release, not an inference from a produced binary.
The selected local tag must already exist and point to that commit; the runner
does not create, move, or push tags.

```bash
bash scripts/xwin-build.sh \
  --manifest /opt/pinned/windows-arm64-toolchain.json \
  --project /home/builder/projects/example-tool \
  --bin example-tool --package example-tool \
  --run-dir /var/tmp/dsr-runs/windows-arm64-release-001 \
  --release-repo owner/example-tool --release-tag v1.2.3 \
  --source-sha "$SOURCE_SHA" \
  --tool example-tool --asset-name example-tool-aarch64-pc-windows-msvc.exe \
  --cargo-cache /home/builder/.cargo --offline > windows-arm64-result.json
```

`--tool` defaults to the binary name. `--asset-name` defaults to
`<binary>-aarch64-pc-windows-msvc.exe`. These options require the complete release
identity and must produce safe basenames. The artifact directory contains only
that admitted executable; private evidence and the manifest live outside it.

The source checkout must be the clean Git worktree root, with HEAD and the local
release tag equal to `--source-sha`. Its origin must match `--release-repo` as a
credential-free GitHub HTTPS or git SSH URL. All compiled local inputs must be
committed, including `Cargo.lock`. Ignored/untracked files are not copied.

The runner materializes raw Git blobs into `run/source`, checking their Git
object hashes and preserving executable modes. It does not build directly from
the original checkout or use `git archive`: export-ignore/export-subst attributes
cannot silently alter the release source. Links, submodules, unsafe paths, and
local Cargo path dependencies outside the admitted source roots are rejected.
Sibling repositories require the explicit pins described below. The snapshot
must also live outside ancestor Cargo configurations. The primary commit's time
sets `SOURCE_DATE_EPOCH` in the controlled build environment.

Before and after compilation, the pinned Cargo runs complete, locked metadata
resolution with `--filter-platform aarch64-pc-windows-msvc`, in the same snapshot
and controlled top-level environment. The runner validates workspace membership,
local manifest/target paths, dependency edges, binary selection, active required
features, and package version equality with the release tag. Full canonical
metadata graphs and selection receipts must agree before/after. `--timeout`
bounds each metadata command as well as the build command, not the entire run.

The admitted workspace package is passed explicitly to cargo-xwin. Its JSON
compiler-artifact message must identify the selected package, binary source,
feature set, non-test profile and exact target-directory executable, followed by
a successful build-finished result. A pre-existing filename or a valid ARM64 PE
header alone cannot satisfy these checks. Workspaces whose metadata and actual
build feature resolution differ are rejected, not silently treated as equivalent.

Every file in the committed snapshot is inventoried and rechecked after the
build. New/deleted source files, byte or executable-mode changes, altered source
receipts, dependency graphs, control files, toolchain pins or version evidence
prevent release success. Evidence is producer-controlled local state, not a
sandbox against malicious build scripts or a privileged concurrent writer.

### Pinned sibling repositories

Projects using `path = "../helper"` can include independently committed local
dependencies by adding `--sibling-crates /opt/pinned/siblings.json` to the
release-mode invocation. This flag requires the complete release identity; it
does not enable unpinned dependencies in ordinary mode. The input is a JSON
array, not a second toolchain manifest or an automatically loaded repos.d file:

```json
[
  {
    "relative_path": "helper",
    "local_path": "/home/builder/projects/helper",
    "revision": "<reviewed full 40-character helper commit>",
    "repo": "owner/helper"
  },
  {
    "relative_path": "types",
    "local_path": "/home/builder/projects/types",
    "revision": "<reviewed full 40-character types commit>",
    "repo": "owner/types"
  }
]
```

Replace the deliberately invalid placeholders with reviewed commit pins. Each
descriptor must contain exactly these four fields. Supply 1..32 repositories
with absolute checkout paths and unique safe destination basenames; `project`
is reserved, and case-insensitive name collisions are rejected. Each checkout
must be a clean Git worktree root with HEAD equal to its selected revision and
origin matching its selected GitHub repository. Sibling libraries need a
committed `Cargo.toml`, but do not need a lockfile or the primary's release tag.
All source-tree admissions finish before the source boundary is created.

The runner freezes the input plan in `run/sibling-crates.json`, and stages:

```text
run/source/
  project/   # primary release commit; actual Cargo working directory
  helper/    # separately pinned helper commit
  types/     # separately pinned transitive dependency commit
```

`../helper` from the primary and `../types` from helper therefore retain their
normal relative layout. Every repository is materialized from raw Git blobs,
not its mutable working directory. No Cargo manifest or dependency path is
rewritten. The primary lockfile must already describe the selected dependency
graph. Unlisted roots, absolute references back to the original checkout, and
dependencies escaping these sibling roots fail admission. Nested layouts that
cannot be represented by these sibling basenames are not supported.

Both metadata observations validate local manifests and target sources against
the admitted source set. Only the primary repository can supply the selected
release binary. Its reachable sibling names are recorded in `resolved_siblings`;
all explicitly staged dependency revisions are retained in `source_dependencies`
on the final result and in `source.dependencies` on the release manifest.
Declared but unused siblings remain identified as staged inputs, not asserted
to have compiled. The full per-repository Git tree, origin, commit, timestamp
and file-inventory evidence remains in the manifest's `source_snapshot`.

These compact dependency pins use the same `{relative_path, git_sha}` records
consumed by the existing SLSA mapper and release-bundle collector. A bundle can
therefore require matching sibling revisions across native and Windows shards;
it does not discard them when combining targets. See
[RELEASE_BUNDLES.md](RELEASE_BUNDLES.md) for aggregation.

The entire staged boundary is reverified before and after compilation and again
at release export, including sibling file bytes, executable modes and the
top-level source namespace. A changed private sibling plan, source receipt or
dependency graph prevents a successful release. Later changes to the original
checkout do not alter a previously completed snapshot. No original repository,
tag, lockfile, or installed toolchain is modified by this staging step.

## Existing DSR publication handoff

Successful release mode creates both files through one directory rename:

- `run/release/build-manifest.json`: DSR schema `1.0.0`, one successful
  `windows/arm64` target and its exact executable name/hash/size.
- `run/release/result.json`: the verified build receipt, including the manifest's
  path and SHA-256. Stdout contains this same receipt.

The manifest retains the pinned repository/tag/commit, complete source inventory,
Cargo graph digest and selection, toolchain/header/library evidence, tool version
hashes, command and normalized build-influence environment. Full metadata and
version output remain in the run directory. Large inventories are read through
files rather than passed as process arguments.

The runner validates its manifest using the same successful-build profile that
DSR's manifest-bound payload publisher and SLSA mapper consume. The following is
an explicit, separate publication step using the existing finalizer:

```bash
bash src/release_finalize.sh /var/tmp/dsr-runs/windows-arm64-release-001/artifacts \
  --repo owner/example-tool --tag v1.2.3 --sha "$SOURCE_SHA" \
  --create-draft --upload-payloads \
  --build-manifest /var/tmp/dsr-runs/windows-arm64-release-001/release/build-manifest.json \
  --output-dir /var/tmp/dsr-runs/windows-arm64-release-001/sbom
```

This example intentionally does not promote the draft. Signing, promotion,
repository authentication, remote tag verification and downstream delivery remain
the finalizer's explicit policies; see [RELEASE_FINALIZATION.md](RELEASE_FINALIZATION.md).
A one-target manifest does not claim completion of a multi-platform release
contract. Native orchestration state/resume and multi-target aggregation are not
added by this standalone handoff. No GitHub API is called during the build.

## What is enforced in both modes

The runner uses a fresh HOME, Cargo home, target directory, and cargo-xwin
working cache. The latter selects the verified sysroot using the clang
backend's `windows-msvc-sysroot/DONE` layout. Generated CMake files and helper
links live in the run directory, never in the immutable input archives.
LLVM header flags and the separate `LIB` alias directory are set explicitly.
Ambient `RUSTFLAGS`, compiler overrides, Rust compiler wrappers, and unrelated
secrets are not inherited. The pinned plugin is invoked directly so a Cargo
alias called `xwin` cannot substitute a different command.

A project's own `.cargo/config` and `.cargo/config.toml` remain meaningful:
their presence and bytes are captured before and after the build, alongside
`Cargo.toml` and `Cargo.lock`. Configurations in ancestors of the actual build
snapshot are rejected. A local target JSON cannot shadow the built-in target.

Required tool paths/hashes, generated tool-selection links, and captured
version-output hashes are checked before and after execution. Full verbose
Cargo/rustc versions and normal cargo-xwin/LLVM versions are retained under
`versions-before/` and `versions-after/`. Cache admission is rederived from
the pinned archives after the build, rejecting missing or changed headers and
libraries even when a local receipt has been edited to agree with them.

Ordinary mode returns `run/result.json`; release mode returns the manifest-bound
pair described above. Both retain the artifact SHA-256/size, manifest identity,
full toolchain evidence, source configuration hashes, command arguments,
normalized invocation environment, version-output hashes and build-log path.
The artifact is copied into `run/artifacts/` before verification. It must be a
PE32+ executable with machine `IMAGE_FILE_MACHINE_ARM64` (`0xAA64`), bounded
headers and section data, and a file-backed executable entry point. Wrong
architectures, DLLs, truncated files and symlink outputs are rejected without
executing them. This validates the container, not every Windows loader semantic.

Failure retains logs and `failure.json` and emits no success receipt. Release
validation failures do not publish `run/release/`. Partial files and private
staging can remain; only the final receipt admits the artifact. Compiler exit
codes are preserved; timeout returns 124 (or 137 for forced termination),
cancellation returns 5, and validation drift returns 7. Cancellation propagates
from the CLI to its owned compiler process group, not unrelated builds.

## Evidence limits and tests

The receipts record the controlled top-level invocation, not every environment
change performed by cargo-xwin, Cargo configuration or a build script. Metadata
parity does not attest the plugin's internal compiler environment. Ordinary
mode observes only source configuration files; release mode additionally pins
the entire committed snapshot. Neither mode attests every dynamic library,
standard-library component, remote dependency's bytes, nested tool or
compiler-generated subprocess. This is not signed provenance. Automatic
propagation through strict native build state remains under `bd-10we`.

```bash
bash scripts/tests/test_xwin_toolchain.sh
bash scripts/tests/test_xwin_build.sh
bash scripts/tests/test_xwin_toolchain_scale.sh
bash scripts/tests/test_xwin_source.sh
bash scripts/tests/test_xwin_release_build.sh
```

The build tests use command-boundary stand-ins for Cargo, rustc, and cargo-xwin,
but real Git source snapshots, installed clang headers, NEON compilation, ARM64
import-library construction and lld-link executable generation. They require
Linux and LLVM and report a skip when those tools are absent. Sibling integration
tests additionally compile C from one committed sibling with a header from a
second, verify that a changed reviewed header pin changes the linked bytes,
and reject staged sibling/plan/metadata drift without emitting a release.
These are not actual Cargo path-dependency compilation tests. No actual BLAKE3
1.8.5 plus ring Rust build or Windows-host execution is claimed. That production
acceptance check remains necessary before closing `dsr-h4y0`.
