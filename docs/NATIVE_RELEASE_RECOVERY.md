# Recover completed native builds

`src/release_recover_native.sh` imports a complete ordinary native build whose
compilers succeeded but whose coordinator failed during flat artifact collection
or packaging. It does not rerun the compilers, touch the original state or output,
create a Git tag, sign anything, upload assets or dispatch workflows.

This is a recovery path for issues #31 and #45, **not a replacement for the normal
build command's collector**. The ordinary collector now passes its resolved names
into manifest generation before basename deduplication and checks every final
payload against that manifest before sealing a publishable build. Recovery
remains useful for older retained runs. Recovery requires all requested native targets to have
completed, with one or more primary payloads per task: raw executables or
`tar.gz`, `tgz`, `tar.xz`, or ZIP workspace archives. Explicitly recorded companion
assets are also preserved. Mixed act/native runs, directory-discovered inventories
and strict-contract builds are refused, not reduced to a smaller release.

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
`artifacts_dir`, `state_sha256`, `recovered_targets`, `recovered_artifacts` and
`companion_artifacts`. Target counts describe worker tasks; artifact counts describe
unique output files, not repeated references to a shared companion. The new `release/` directory
contains `build-manifest.json`, `artifacts/`, the original `inputs/state.json`, and
`result.json`. Only an entirely validated set is renamed into `release/`.
Interrupted or failed copies may retain private `.recovery-*` evidence; use a new
output directory for another attempt. An existing output is never overwritten.

Raw names are deterministic, independent of completion order: `demo-linux_amd64`,
`demo-darwin_arm64`, `demo-windows_amd64.exe`. A recorded compiler triple replaces
the platform suffix, for example `demo-x86_64-unknown-linux-musl`. Original filenames
and paths remain in the recovery evidence. Each new manifest row uses the actual
published name and that target's retained SHA-256 and size. Archive suffixes stay
intact: `demo.tar.xz` becomes `demo-linux_arm64.tar.xz`, not an executable or a
mislabeled gzip file.

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

## Multiple primary outputs and shared companions

The worker's `artifact_paths` array is authoritative. A task can retain multiple
raw executables, multiple archives, or both; each primary is qualified by its own
worker platform/triple before entering the flat output directory. Parent directory
names containing commas are supported because recovery never splits that array's
paths. The legacy display scalar must still equal the array's comma-joined form.

The complete union of primary paths and `additional_artifacts` must match the
worker's frozen `resume_artifacts` exactly. Every additional descriptor must agree
with its corresponding resume receipt, including the original inode, digest and
size. Duplicate paths, missing receipts, contradictory descriptors and primary/
companion role overlaps refuse the entire operation. Per task, at most 256 primary
and 256 additional paths are admitted. No unlisted file is discovered or imported.

Additional assets retain their safe original basenames. Same-named companions
from different workers can share one output only when spelling, bytes, size and
executable bits agree; their original source receipts remain individually listed
in `recovery_evidence.artifacts`. Both separately copied inputs and one shared
physical companion are supported, without hardlinking the recovered output.
Case collisions and unequal content or modes fail rather than choosing a winner.
Executable bits are retained exactly. Empty standalone companions are refused
because the release manifest requires nonzero asset sizes; empty files inside
primary archives remain supported.

Companions are opaque bytes, not verified native executables or authenticated
source files. They receive `target: "additional"`, `archive_format: "none"`, and no
compiler triple. Even when their filename is an archive, no extraction or archive
member claim is made for an opaque companion; the archive admission rules below
apply to primary outputs. Recognized native executable bytes and `.exe` companions
are refused: declare them as primary outputs to retain their target checks.

Conventional filename-bearing checksums, signatures, SBOMs, provenance files and
manifests are refused as companions because primary names change during recovery.
Recovery neither signs new metadata nor copies those known stale attestations as
valid ones. Generate fresh metadata through the downstream release pipeline.

After independent copying, recovery re-reads every staged output against its held
digest, size, inode and metadata. It verifies the exact staging namespace and the
held bytes/identities of the saved state, manifest and result. Persistent copy
corruption, replacement, mode changes, document edits or added output files fail
before the final directory rename. This extends the existing original-input and
Git rechecks; it is not a claim of tamper resistance against arbitrary concurrent
same-user writes after the final observation or of strict build authentication.

## Workspace archives

Recovery preserves the original compressed bytes, including every bundled binary,
nested document, executable mode and empty companion file. It never extracts an
archive to disk or repackages it. The compressed digest and filesystem identity
must match the frozen worker receipt before inspection and copying. Each archive
also retains a sorted member inventory under its `recovery_evidence.artifacts[]`
entry, including member hashes, sizes, executable bits, native executable names
and an inventory SHA-256.

At least one native executable must be present. Every recognized ELF, Mach-O or PE
executable (and every `.exe` member) must match the worker platform. Unix native
executables must retain executable bits. This is not a complete executable-format
validator or an ABI attestation; in particular, the ELF header check does not
distinguish every shared-library form from an executable. Scripts-only packages,
universal Mach-O payloads, sparse tar members, links, special files,
privileged modes, encrypted ZIPs and ZIP64/split ZIPs are unsupported and refused.
ZIP supports stored and deflated members. PAX and GNU long-name tar metadata are
supported within a 64 KiB per-header budget.

Member traversal, absolute or drive-qualified paths, case collisions, duplicate
members, file/parent conflicts, nonzero data after a tar terminator, corrupt
compression trailers and invalid ZIP directory metadata are refused. Directory
records and a conventional `./` tar root are allowed. Member contents are streamed;
inspection does not load entire executables into memory.

`--max-artifact-bytes` bounds each stored payload (default 4 GiB).
`--max-unpacked-bytes` bounds each archive's total regular-file content (default
4 GiB), and `--max-archive-members` bounds its member count (default 10,000).
Tar padding and extended metadata have an additional bounded stream allowance;
ZIP central-directory metadata is capped at 16 MiB before its member list is read.
Exceeding a limit refuses the complete recovery instead of omitting members.
These budgets are per archive, not a claim of a global memory or CPU bound.

## Regression test

```bash
bash scripts/tests/test_native_release_recovery.sh
```

This compiles real Go executables for seven Linux/macOS/Windows targets, wraps
those bytes in explicit native-state fixtures using DSR's producer field names,
and tests complete recovery and refusal cases. It also constructs actual gzip,
xz and ZIP archives containing multiple executables and nested companions, verifies
byte-for-byte recovery and executes a recovered Linux archive member. It does not
claim native macOS or Windows runtime execution. Git objects, executable files,
archive parsers, inode checks and digest checks are genuine. Test evidence is
retained in the printed temporary directory.

The multi-file cases retain fourteen primary payloads and three shared companions
across seven workers, including mode-sensitive scripts and refusal of empty
standalone assets that cannot satisfy the release manifest. The
staging tests forward to the genuine Git executable, then deliberately mutate a
private recovery output after the final tag query; an explicit marker is required
so an unrelated early failure cannot count as a successful refusal. No Git identity
response or source verifier is mocked by that fault injector.

For a controlled comparison, `DSR_RECOVERY_BASELINE` may name the unchanged
incumbent script: the same test invocation demonstrates its refusal of the exact
workspace archive input. `DSR_RECOVERY_TEST_GOCACHE` optionally selects a shared Go
compilation cache; output binaries and release evidence remain unique to each run.
`DSR_RECOVERY_MULTI_BASELINE` may name the unchanged archive-only implementation to
reproduce both its multi-file refusal and its publication of an altered staged
copy, using the same real inputs and fault injector in the same test invocation.
