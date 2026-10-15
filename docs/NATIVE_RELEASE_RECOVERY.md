# Recover completed native raw builds

`src/release_recover_native.sh` imports a complete ordinary native build whose
compilers succeeded but whose coordinator failed during flat artifact collection
or packaging. It does not rerun the compilers, touch the original state or output,
create a Git tag, sign anything, upload assets or dispatch workflows.

This is a recovery path for issues #31 and #45, **not a replacement for the normal
build command's collector**. The normal collector's rename/manifest mismatch still
needs its own repair. Recovery requires all requested native targets to have
completed and exactly one raw executable per task. Workspace archives, additional
assets, mixed act/native runs and strict-contract builds are refused, not reduced
to a smaller release.

## Select the saved build

Use the run-specific `state.json` under the DSR build workspace, not public build
summary JSON or the incomplete top-level artifacts list. Select its SHA-256 before
invocation; a changed state must not be silently accepted during recovery.

```bash
STATE=/absolute/dsr-state/builds/demo/1.2.3/RUN-UUID/state.json
STATE_SHA=$(sha256sum "$STATE" | cut -d' ' -f1)

bash src/release_recover_native.sh \
  --state "$STATE" --state-sha256 "$STATE_SHA" \
  --source-repo /absolute/checkouts/demo \
  --repo owner/demo --tag v1.2.3 --sha FULL_TAG_COMMIT \
  --artifacts-root /absolute/dsr-state/artifacts \
  --output-dir /absolute/recovery/demo-1.2.3
```

All supplied paths must be absolute, existing ancestors must be directories and
symlink-free, and the output directory must be new and outside the original source,
state and artifact trees. On macOS, `shasum -a 256` can select the state digest.
`--dry-run` validates inputs and prints the planned names without writing output.
The command also honors `DRY_RUN=true`. Run this module as a command, not as a
sourceable library: its process becomes the recovery supervisor so signals go
directly to the operation instead of leaving an orphaned copier.

The original checkout is used only for local, network-disabled Git reads: its
origin must match the selected repository and the existing tag must resolve to the
selected commit. The checkout need not be at that tag and is not modified.

## Output and evidence

Successful stdout is one JSON result with `manifest`, `manifest_sha256`,
`artifacts_dir`, `state_sha256` and `recovered_targets`. The new `release/` directory
contains `build-manifest.json`, `artifacts/`, the original `inputs/state.json`, and
`result.json`. Only an entirely validated set is renamed into `release/`.
Interrupted or failed copies may retain private `.recovery-*` evidence; use a new
output directory for another attempt. An existing output is never overwritten.

Raw names are deterministic, independent of completion order: `demo-linux_amd64`,
`demo-darwin_arm64`, `demo-windows_amd64.exe`. A recorded compiler triple replaces
the platform suffix, for example `demo-x86_64-unknown-linux-musl`. Original filenames
and paths remain in the recovery evidence. Each new manifest row uses the actual
published name and that target's retained SHA-256 and size.

Recovery checks the complete planned task set, release purpose, completed worker
status, host and compiler identity, the authoritative `artifact_paths` array and
`resume_artifacts` receipts. It rechecks the recorded inode, exact bytes and size
before and after independent copying. Linked files, substituted paths, missing
workers and differing binaries fail. ELF, Mach-O and PE headers must agree with
the worker's OS/architecture; this does **not** attest ABI or minimum OS versions.

The manifest preserves each native environment and isolation object. `built_at`
is the latest recorded completed-target checkpoint, not the recovery time; the
latter is separately labeled. Recovery is an **ordinary producer-evidence import**:
it checks tag identity and retained artifact custody, not that a compiler actually
used that source. It does not assert pinned dependencies or strict source/toolchain
authentication. The entire selected state is retained; no cryptographic signer or
SLSA build level is implied. Strict builds must use their original strict path.

The returned manifest and artifact root are inputs to the existing
`src/release_packaging.sh` pipeline: a recipe can consume each raw asset as an
archive member named `demo`/`demo.exe`, or rename a raw output to a project's
published name. The packaging and finalization commands retain their own source,
coverage, checksum and signing gates. No automatic publication occurs here.

## Regression test

```bash
bash scripts/tests/test_native_release_recovery.sh
```

This compiles real Go executables for seven Linux/macOS/Windows targets, wraps
those bytes in explicit native-state fixtures using DSR's producer field names,
and tests complete recovery and refusal cases. It executes the host-compatible
Linux binary; it does not claim native macOS or Windows runtime execution. Git
objects, executable files, inode checks and digest checks are genuine. Test evidence
is retained in the printed temporary directory.
