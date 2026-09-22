# Build with the pinned Windows ARM64 view

The standalone `scripts/xwin-build.sh` entry point consumes the manifest
specified in [XWIN_TOOLCHAIN.md](XWIN_TOOLCHAIN.md), runs the pinned cargo-xwin
plugin, and admits a release-profile executable only after toolchain
revalidation and ARM64 PE verification. It is suitable for a project already
staged by DSR. It does not replace the existing source, publication, signing,
or native-host release gates, or automatically change `dsr build` routing.

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
setsid on a Linux host.

`--offline` requests Cargo's offline behavior. Without it, Cargo may fetch
locked dependencies. `--cargo-cache` is optional: only its `registry/` and
`git/` download directories are linked into a fresh Cargo home. Configuration,
credentials, binaries, and unrelated files are not inherited. The linked
cache remains writable by Cargo; it is not a frozen source snapshot. The
runner intentionally does not inherit proxy variables, registry credentials,
or arbitrary environment overrides. Projects requiring custom registries
must supply appropriate reviewed project configuration.

## What is enforced and retained

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
`Cargo.toml` and `Cargo.lock`. Configurations in ancestor directories are
rejected; use DSR's existing source isolation before invoking this entry
point. A local target JSON file cannot shadow the selected built-in target.

Required tool paths/hashes, generated tool-selection links, and captured
version-output hashes are checked before and after execution. Full verbose
Cargo/rustc versions and normal cargo-xwin/LLVM versions are retained under
`versions-before/` and `versions-after/`. Cache admission is rederived from
the pinned archives after the build, rejecting missing or changed headers and
libraries even when a local receipt has been edited to agree with them.

On success, `result.json` and stdout contain the same JSON receipt with the
artifact SHA-256/size, manifest identity, full toolchain evidence, source
configuration hashes, command arguments, normalized invocation environment,
version-output hashes, and build-log path. The artifact is copied into the
run's `artifacts/` directory before verification. It must be a PE32+ executable
with machine `IMAGE_FILE_MACHINE_ARM64` (`0xAA64`), valid bounded headers and
section data, and a file-backed executable entry point. Wrong architectures,
DLLs, truncated files, and symlink outputs are rejected without executing them.
This validates the executable container, not every Windows loader semantic.

Failure retains logs and `failure.json`, emits no success receipt, and never
creates `result.json`. Partial files can remain in the failed run directory;
only a successful receipt admits the artifact. Compiler exit codes are
preserved; timeout returns 124 (or 137 for forced termination), cancellation
returns 5, and validation drift returns 7. Cancellation propagates from the
CLI to its owned compiler process group and does not signal unrelated builds.

## Evidence limits and tests

This receipt records the controlled top-level invocation, not every environment
change performed by Cargo configuration or a build script. It does not attest
every source file, dynamic library, standard-library component, nested tool,
or compiler-generated subprocess. It is not signed provenance. Automatic
propagation through strict native build state/public manifests remains under
`bd-10we`.

```bash
bash scripts/tests/test_xwin_toolchain.sh
bash scripts/tests/test_xwin_build.sh
bash scripts/tests/test_xwin_toolchain_scale.sh
```

The build tests use command-boundary stand-ins for Cargo, rustc, and cargo-xwin,
but real installed clang headers, NEON compilation, ARM64 import-library
construction, and lld-link executable generation. They require Linux and LLVM
and report a skip when those tools are absent. No actual BLAKE3 1.8.5 plus
ring Rust build or Windows-host execution is claimed. That production
acceptance check remains necessary before closing `dsr-h4y0`.
