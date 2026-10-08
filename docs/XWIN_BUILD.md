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
cache. Build execution also requires Python 3.9+, GNU timeout, and util-linux
setsid on a Linux host. Release mode additionally requires Git and Python
3.11+ for TOML-based lockfile authentication; Cargo.lock v3 and v4 are supported.

### Select Cargo features

The runner accepts Cargo's `--features`, `--all-features`, and
`--no-default-features` options in ordinary and source-pinned release modes.
Repeated `--features` options add to one selection; each value can contain
comma-separated or space-separated names. Workspace members can be addressed
with `package-name/feature-name`:

```bash
bash scripts/xwin-build.sh \
  --manifest /opt/pinned/windows-arm64-toolchain.json \
  --project /var/tmp/dsr-staged/project \
  --bin server --bin client \
  --features "server-package/tls,client-package/cli" \
  --no-default-features \
  --run-dir /var/tmp/dsr-runs/windows-arm64-features-001 --offline
```

Names retain case and support Cargo's Unicode identifier characters, digits,
underscores, and subsequent `-`, `+`, or `.`. Empty selections, control
characters, malformed qualifiers, shell expressions, and manifest-only
dependency expressions such as `dep:foo` or `foo?/bar` are refused before a run
is created. Cargo checks whether syntactically valid features actually exist.
The flags retain Cargo's additive semantics: `--all-features` can also enable
the feature named `default` when `--no-default-features` is present. See
[Cargo's feature selection rules](https://doc.rust-lang.org/cargo/reference/features.html#command-line-feature-options).

The runner sorts and deduplicates requested names once and records them in
`run/feature-selection.json`. The two locked metadata observations and the
pinned cargo-xwin invocation receive the same feature arguments. A binary with
`required-features` is admitted only when those features are active; all
selected workspace binaries must still produce matching compiler-artifact
records. A feature list cannot make an absent companion executable optional.

The requested selection is retained as `feature_selection` in the result and
release manifest's build environment, alongside the exact command and each
binary's resolved features. Changing its private receipt during preparation,
metadata, or compilation prevents release success. Metadata and actual
compiler feature sets must agree; incompatible workspace feature resolution
still fails admission.

`--offline` requests Cargo's offline behavior. Without it, Cargo may fetch
locked dependencies. `--cargo-cache` is optional. Source-pinned releases select
downloads using the staged, committed `Cargo.lock`: checksum-matching crate
archives, corresponding registry index records, and Git databases containing
locked commits. Ambient extracted registry sources and Git checkouts are never
copied. Cargo recreates them in the private home, and the existing source
authentication gate verifies them against locked archives and Git objects.
Unrelated cached links, archives, and working copies cannot become release
inputs or block preparation; a lockfile without Git dependencies does not open
the Git cache. Selection covers all packages in the lockfile rather than only
the chosen target/features; selected Git databases retain their full history.
Ordinary builds copy the supplied `registry/` and `git/` trees. Both modes create
a fresh, independently owned Cargo home before any Cargo invocation.
These are byte copies, not symlinks or source
hardlinks: deleting the original cache or writing its files in place cannot
change the prepared copy. Top-level Cargo configuration, credentials, binaries,
and unrelated files are not inherited. The runner intentionally does not inherit
proxy variables, registry credentials, or arbitrary environment overrides.
Projects requiring custom registries must supply reviewed project configuration.

The seed must be a real directory. Linked/special selected entries and Git
gitdir/commondir/alternate-object storage pointers are rejected rather than
retaining references outside the private home. Detected changes during copying
fail preparation; use a quiescent cache or omit `--cargo-cache` to start empty.
An empty cache normally needs network access, so combining it with `--offline`
requires dependencies already supplied by reviewed project configuration.
Preparation needs disk space for the selected downloads in release mode or
complete cache trees in ordinary mode; it does not use copy-on-write storage.
`--timeout` also bounds each cache preparation/inventory command separately.
Cancellation reaches its process group; diagnostics are retained in
`run/cargo-cache-seed.log` and `run/cargo-cache-final.log`.

Cargo can legitimately download, unpack, or maintain files in its private
home. The result's `cargo_cache` field therefore retains separate seed and
final inventory summaries, including receipt SHA-256, inventory SHA-256,
file count and byte count. Source-pinned seed summaries also retain `selection`,
including the lockfile SHA-256, registry-package count, and Git revisions; final
inventories describe the expanded private home without claiming that selection.
The release manifest retains the same field under
`build_environments`. Full inventories live in
`run/cargo-home/.dsr-cache-seed.json` and `run/cargo-cache-final.json`;
changing seed evidence during the build prevents success. Inventories describe
observed files, not proof of exactly which dependencies compiled, a frozen
filesystem, or protection from malicious build scripts.

The sourceable/directly runnable helper also supports independent preparation
and later verification (all paths must be absolute):

```bash
bash src/cargo_cache.sh snapshot /home/builder/.cargo /var/tmp/new-cargo-home
bash src/cargo_cache.sh inventory /var/tmp/new-cargo-home /var/tmp/cache-receipt.json
bash src/cargo_cache.sh verify /var/tmp/new-cargo-home /var/tmp/cache-receipt.json
```

Snapshot and inventory destinations must not exist. Verification requires exact
file/directory membership, bytes and executable bits; it does not rewrite a
receipt after drift. The pinned runner and the native orchestrator have
separate cache-isolation integrations and acceptance evidence; this section
describes the pinned runner, not completion of native Windows acceptance.

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

### Resolved dependency source integrity

Release mode also inventories the remote package sources reachable from every
selected binary's package in the platform-filtered Cargo resolution. Matching
package IDs, versions, features and dependency edges is no longer sufficient:
the same graph with changed dependency bytes fails the existing before/after
metadata and selection comparisons, before release export. This is always
enabled in release mode; ordinary mode does not acquire this source-equality
guarantee.

Registry packages cover their complete extracted crate directory. Git packages
cover the complete cached checkout, including shared workspace files outside a
particular member; packages in one checkout share one inventory. Cargo directory
sources, including unversioned `cargo vendor` registry and Git replacements,
are recognized by their checksum descriptor and cover the whole package
directory. The descriptor is itself hashed, not treated as an authenticity
proof. Local primary and pinned sibling sources keep their existing independent
committed-source checks.

Each inventory binds source identities and paths, file SHA-256 values, sizes,
executable bits, directory membership and empty directories. Missing files,
symlinks (including ancestors), special files and unsafe member names fail
admission. Files are read through non-following descriptors and checked for
changes while hashing. File timestamps are not part of the resulting identity.
Unrelated cached crates, registry indexes and compressed download caches are
not part of the source-equality inventory. For a Git checkout, the top-level
`.git` directory's presence and type are recorded but its administrative
contents are excluded: a harmless index refresh is not a source change, and
Git command output is not attested. Locked authentication separately reads the
required compressed archives and Git objects, as described below.

The complete inventories are embedded as `dsr_dependency_sources` in
`run/metadata-before.json` and `run/metadata-after.json`. These canonical DSR
metadata documents, unlike the separate raw Cargo output, include the source
evidence. The runner holds the before-document hash across compilation and
requires both complete documents to match. This binds the full inventory, not
just a mutable sidecar. Auxiliary `*.dependency-sources.json` files retain the
standalone inventories as well. The compact `dependency_sources` summary in
each selection contains the inventory SHA-256 and package/root/file/byte counts;
it survives in the release manifest at
`build_environments[].cargo_metadata.dependency_sources`.

#### Authenticate the initial cached bytes

Release metadata admission always supplies the committed workspace's
`Cargo.lock` to the source verifier. A cache already modified before the run
cannot become trusted merely by staying unchanged during compilation. Every
resolved remote package must match exactly one lockfile name/version/source
entry. Missing or ambiguous pins and malformed TOML fail closed.

For a registry source, the verifier requires its original `.crate` archive in
`registry/cache/<registry-id>/`, checks its SHA-256 against the lockfile, then
streams its members without extracting them. The extracted source tree must
match the authenticated archive's file bytes and directory namespace. Keep
these archives when preparing an offline release cache; extracted sources alone
are insufficient. There is no fallback that invents a new checksum from the
current cache. Refill a clean cache using the reviewed lockfile when an archive
is missing or corrupt.

For Git sources, the complete locked 40-character commit is read using one
batch object reader per checkout/source identity. Commit, tree, and blob hashes
are independently recomputed, and the complete working tree must match that
object chain. Mutable HEAD/index data, replacement refs, and ambient Git
redirection cannot authorize a different source tree. No checkout/reset/fetch
is performed. Missing objects, external object-storage pointers, symlinks and
submodules are refused. Git object reads have a 30-second per-read deadline;
this is not a deadline for the entire source-admission phase.

Initial executable-mode validation permits a restrictive extraction umask
(for example, an authentic 0755 executable copied as 0700), but refuses added
execute bits or a lost owner-executable bit. Once admitted, the two inventories
still require every observed executable bit to remain identical. Cargo's
bounded completion markers are distinguished from upstream files; an archive
or Git tree cannot supply the managed root `.cargo-ok` file.

Vendored directory sources use a different authority: they must be inside the
primary workspace whose complete Git snapshot the release runner already
verifies. Their proof explicitly says `caller-verified-workspace-snapshot`,
not upstream archive authentication. A directory outside that workspace is
refused even when its editable `.cargo-checksum.json` claims a matching hash.
Vendors under a separate sibling root are not admitted by this policy. Put
reviewed vendors inside the primary committed tree or use the verified Cargo
registry/Git cache layouts.

Full per-package proof records live in
`dsr_dependency_sources.authentication.packages` in the canonical metadata.
The compact selection/manifest summary adds an `authentication` object with
the lockfile SHA-256 and counts for locked archives, locked Git sources and
workspace-snapshot vendors. It does not pass the full proof list through argv.
The lockfile and source trees are rechecked while deriving authentication.
The selected release commit and its lockfile remain trust inputs; this is not
publisher-signature verification or proof that the selected dependencies are
benign. Previously completed/imported build manifests are not retroactively
re-authenticated by this new-build gate.

The standalone helper supports capture and independent verification using
absolute paths and an explicit JSON array of selected Cargo package IDs:

```bash
bash src/cargo_sources.sh capture /var/tmp/metadata.json \
  '["selected-package-id-from-metadata"]' /var/tmp/dependency-sources.json \
  /var/tmp/project/Cargo.lock
bash src/cargo_sources.sh verify /var/tmp/metadata.json \
  '["selected-package-id-from-metadata"]' /var/tmp/dependency-sources.json \
  /var/tmp/project/Cargo.lock
```

The final lockfile argument enables authentication and must identify the
metadata workspace's `Cargo.lock`. Omitting it gives observation-only behavior
for standalone callers, not the release-mode policy. Standalone users accepting
in-workspace vendors must independently verify the workspace snapshot; the
helper does not infer a trusted commit from a directory name.

Capture refuses an existing receipt; verification never rewrites it. Rejection
returns exit 7 without a successful summary. Observation-only mode needs Python
3.9+; locked authentication needs Python 3.11+ and reports dependency exit 3
when its standard TOML parser is unavailable. A Unix host with descriptor-relative
filesystem support is required. Inventories describe a conservative source
boundary, not proof that every recorded file compiled. They detect lasting
source drift between observations but do not prevent a malicious process from
changing and restoring inputs between observations. They are not a sandbox or
signed provenance.

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
the entire committed snapshot, authenticates cached dependencies, and compares
resolved dependency sources as described above. Neither mode attests every dynamic library,
standard-library component, nested tool or compiler-generated subprocess,
or proves publisher identity or that the selected source is benign. This is
not signed provenance. Automatic propagation through strict native build state
remains under `bd-10we`.

```bash
bash scripts/tests/test_cargo_cache.sh
bash scripts/tests/test_cargo_sources.sh
bash scripts/tests/test_cargo_sources_authentication.sh
bash scripts/tests/test_xwin_toolchain.sh
bash scripts/tests/test_xwin_build.sh
bash scripts/tests/test_xwin_toolchain_scale.sh
bash scripts/tests/test_xwin_source.sh
bash scripts/tests/test_xwin_release_build.sh
bash scripts/tests/test_xwin_metadata_workspace.sh
bash scripts/tests/test_xwin_multibin.sh
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

The workspace metadata suite separately runs genuine Windows-filtered Cargo
resolution and native Rust compilation for explicit feature selections,
default suppression, all-features, and multiple required-feature binaries.
Those native executables run on the test host; that evidence does not claim a
Rust Windows link. The multi-binary runner suite exercises the complete pinned
build and release handoff with real LLVM ARM64 linking and explicit Cargo
command-boundary fixtures, including feature-receipt drift refusal.
