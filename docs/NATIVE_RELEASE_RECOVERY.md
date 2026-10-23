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
symlink-free, and the output directory must be outside (and not contain) the original
source, state and artifact trees. It must be new unless `--resume` explicitly selects
an existing recovery. On macOS, `shasum -a 256` can select the state digest.
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
The output root also holds an immutable `plan.json` and a private `.partial/`
directory. An interrupted operation retains its selected `.recovery-*` stage;
`--resume` can continue that same generation. An existing file is never overwritten.

## Retry completed or interrupted recovery

Repeat the same selected command with `--resume`. No compiler, archive repackaging,
signer, upload or original build-state mutation is involved. Every retry checks the
independently selected state SHA-256, local repository/tag, full worker matrix,
original inode/hash/size receipts and archive inventories again. The original
checkout, checkpoint and worker artifacts must still be available; the saved
success receipt is not a substitute for these inputs.

For a completed `release/`, resume reconstructs the expected manifest and result,
revalidates every copied payload and the exact output namespace, then returns the
original JSON receipt. It preserves the manifest digest, historical recovery time,
file/directory identities, modes and modification times. Missing, linked, changed,
extra or incorrectly permissioned outputs are refused, never repaired. A manifest
that consistently omits a target still fails because expected inventory comes from
the selected worker checkpoint. Legacy completed outputs with only `release/` are
supported without adding a plan or rewriting their files.

For an interrupted managed output, resume requires its exact pinned `plan.json`;
it never selects a different stage by recency. All existing committed payloads and
documents are checked before any missing file is copied. Valid completed copies
retain their bytes, inodes and modes. Only missing files are copied from their
original frozen worker paths. Existing but corrupt files cause refusal rather than
automatic replacement, even if another missing file could otherwise make progress.

Each new payload or document is written, flushed and checked under a fresh random
name in `.partial/`, then renamed into its committed staging name. File-size
exhaustion or cancellation cannot leave a truncated file masquerading as a completed
payload. A retry restarts an interrupted individual file; it does not continue from
a byte offset. Prior incomplete files remain private evidence and never enter
`release/artifacts/`. The complete staged namespace, input state, manifest, result
and payloads are rechecked before the final directory rename.

An exclusive, nonblocking lock on the recovery directory serializes cooperating
writers, including dry-run verification. An active recovery makes a competing
invocation fail rather than race or wait indefinitely. No persistent PID file is
trusted and no stored PID is signalled. A crash before the first plan is committed,
or an older interrupted output without a managed plan, still requires a new output
directory; such unbound directories are not adopted.

`--resume --dry-run` checks completed output or the retained partial subset without
creating missing files, changing checkpoints or publishing a release. The recovery
observation time is retained from local evidence, not asserted as an authenticated
build timestamp. This remains cooperating-writer recovery, not protection against
arbitrary same-user changes after the final observation or strict build provenance.

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

## Bounded parallel verification and copying

### Destination capacity before copying

Fresh recovery and interrupted `--resume` now check the destination's actual
available bytes before writing. The estimate includes every unique missing
payload, missing state/manifest/result/plan document, allocation-block rounding,
and a small directory-metadata allowance. Copy scratch files become their final
names by same-filesystem rename, so the estimate does not charge a second full
copy. Already completed files and retained failed scratch bytes are not counted
as future allocations: their existing consumption is already reflected in the
filesystem's available space. Finite reported inode capacity is checked too.

`--dry-run` performs the same capacity check without creating output. An
insufficient-capacity error reports available bytes, estimated additional bytes,
and the requested free-space reserve. An interrupted retry checks its existing
evidence first and refuses without changing it when capacity is insufficient.
Completed `--resume` is still a read-only verification and needs no copy budget.

Add `--reserve-free-bytes 21474836480` to require another 20 GiB free beyond the
estimated new allocations. The default is zero additional reserve, not a change
to the separate native-host 20 GiB admission floor or SBH policy. This option is
an execution constraint like `--jobs`; changing it on retry does not change the
frozen source selection, recovery plan, artifact manifest or success receipt.
No existing build, ownership or release gate is bypassed by this option.

The capacity observation is bound to an open directory descriptor. Managed
scratch and staging directories must share that filesystem; a spacious parent
cannot authorize copies onto a separate nested mount. Capacity is checked again
after workspace initialization, immediately before launching copy workers.
This is **not a reservation**: quotas, filesystem metadata overhead and competing
writers may still cause a later write failure. Existing cancellation, complete
inventory verification and retained-evidence resume rules still apply. Recovery
does not delete files, fill a disk to test it, reclaim space or lower other
storage policies. Original worker artifacts remain untouched.

Use `--jobs 4` to allow up to four concurrent artifact operations. The accepted
range is 1–32; omission keeps serial execution. The same budget now covers
initial input verification, preparation of missing payload copies, final input
verification, and final staged-byte verification. Shared companion paths with
identical frozen receipts are read once per verification phase while retaining
every worker attribution. Distinct physical paths are verified independently.

Copy workers write only private, randomly named scratch files. They validate the
original receipt and copied bytes before handing the file to the supervisor.
Only the supervisor renames a prepared file into its committed staging name,
revalidates its final bytes and mode, and records the copy. A preparation retains
its job slot through that acceptance; the supervisor's verification does not
create an extra operation above the selected budget. Documents and final release
publication remain serialized.

A copy failure stops further admission and drains the owned workers before the
workspace lock is released. Repeated signals cannot skip draining. Completed
files remain reusable; incomplete or unaccepted files remain private evidence,
never a smaller release. Retry with the same selection and `--resume --jobs 4`.
Changing the budget on retry does not change the frozen plan, manifest, receipt,
or previously completed files. Completed recovery retries start no copy workers.

Concurrency is an I/O scheduling control, not a guarantee of higher throughput:
storage contention may make a smaller budget faster. There is no new disk-space
reservation or protection against uninterruptible kernel I/O. The existing
hash, inode, mode, archive, full-inventory and source/tag checks still apply.

`test_native_recovery_resume.sh` observes real writable file descriptors on
Linux, exercises cancellation during simultaneous writes and a kernel-enforced
file-size failure, then resumes without replacing completed files. Set
`DSR_RECOVERY_COPY_BASELINE` to the unchanged serial-copy module to compare both
implementations in the same invocation. Reported timings are observations for
that fixture, not a general performance claim.

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
bash scripts/tests/test_native_recovery_resume.sh
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

The resume suite uses a genuine Go executable, a real compressed archive, an OS
file-size limit that interrupts a copy, a real directory lock and SIGTERM delivered
to the recovery supervisor after a genuine Git tag query. It checks that completed
copies and private failure evidence survive retries unchanged, that all missing
payloads are recovered, and that conflicting or corrupt retained state is refused
without repair. Saved worker envelopes are explicit fixtures, not a full scheduler
invocation. The interruption suite currently requires Linux. Set
`DSR_RECOVERY_PARTIAL_BASELINE` to the unchanged completed-only implementation for
an in-process comparison of partial refusal and legacy completed-output reuse.
`DSR_RECOVERY_RESUME_BASELINE` selects the older non-resumable module for the main
recovery suite's completed-retry counterexample. Neither suite claims native
macOS/Windows execution, signing or live release publication.

## Resume an interrupted strict fallback publication

`dsr fallback --resume=RUN_UUID` now continues its own interrupted strict release
after the build has completed. Select the original build UUID, version, source
commit and output directory:

```bash
dsr --json fallback demo --version 1.2.3 \
  --expected-sha FULL_TAG_COMMIT --resume=RUN_UUID \
  --output-dir '/absolute/build outputs/demo-v1.2.3'
```

The usual fallback checks still run: source identity, quality checks, the complete
build manifest, every artifact and its original checkpoint. A completed build is
reused without compilation. Add `--isolate-source` when the configured checkout
has advanced or contains user changes; the finalizer uses that same verified
private source copy and leaves the original checkout untouched.

Automatic recovery inherits the strict finalizer's configuration admission:
the tool needs an explicit regular `repos.d/<tool>.yaml` under `DSR_CONFIG_DIR`,
with an absolute source path and release contract, without `extends` or
`publication_mode`, and without a same-tool entry in `repos.yaml`. The tool name
may contain letters, digits, `_` and `-`, and the version must be semantic.
Arrange that configuration before the original attempt; changing frozen
configuration after an interruption invalidates its recovery intent. Fresh
fallback publication continues to support its existing configuration surface,
but an interrupted attempt outside these finalizer restrictions requires
operator recovery.

Before creating a strict draft, fallback writes an owner-only publication intent
under `$DSR_STATE_DIR/releases/dsr-fallback.RUN_UUID.XXXXXXXX/`. It binds the exact
build UUID, repository, tag, source SHA, canonical artifact directory, manifest
digest, and repository/registry configuration bytes. The strict producer keeps
its complete signed asset plan and nonce-bound request in a private child
directory, alongside the original empty-draft POST response. Fallback retains
descriptor identities and digests for that original custody; neither a later
tag lookup nor a successful upload journal can replace it.

On retry, recovery accepts only one matching private handoff. It verifies the
original creation response, fresh nonce-bound release metadata, and the complete
ID-bound asset inventory. Every existing asset must have the planned name, size
and SHA-256, and its downloaded bytes must agree. Missing assets are uploaded
additively. Existing assets with wrong bytes, incomplete uploads, duplicate names,
unexpected assets, changed ownership metadata, or changed local inputs cause
refusal. Recovery never deletes or replaces a remote asset and never repairs a
public release. An already-public release can succeed only after full verification.

Repair retains one downloaded copy per immutable asset ID for the current
attempt. Each subsequent inventory check rehashes those bytes and requires the
same ID/name/size/digest; an observed asset disappearing or changing identity
stops the attempt. The existing strict finalizer independently downloads and
cryptographically verifies complete signed pairs again before and after
publication. This automatic route requires fewer than 100 contracted assets,
including signatures and checksum sidecars, matching the finalizer's bounded
inventory proof.

Publication happens only through `release finalize --no-dispatch` using the
original POST response and canonical artifact directory. Fallback validates the
retained finalization success receipt before reporting a completed release. A
lost upload or publication response is accepted only when fresh observations
prove the exact resulting state. Recovery does not dispatch downstream workflows
again: the interrupted original invocation may already have dispatched them.

JSON results expose `details.publication_recovery`, including `build_run_id` for
the exact `--resume` selector, the private intent,
proven creation response and custody directory when available, release ID, and
the finalization receipt after recovery. Its status is `prepared`, `ready`,
`blocked`, or `finalized`; `ready` means custody is available for retry, not that
publication succeeded. Preserve the complete directory and the original artifacts.

A process interruption after the original POST was retained but before fallback
recorded its final handoff remains recoverable from the two pre-POST intents and
that original response. If GitHub accepted a creation request but the original
response was never retained, automatic recovery is blocked. It also refuses
ambiguous custody or a draft created by another publisher. Those cases require
operator inspection; they are not permission to create another release or adopt
a matching tag. Watch's separate unknown-process-outcome protection still applies:
a killed attempt that it marks blocked requires an explicit recovery decision.

The focused integration coverage uses real Git repositories, private descriptor
checks, Minisign signatures, complete manifest/asset validation, and the actual
strict producer/finalizer. Quality/build execution and GitHub's HTTP/download
boundary are controlled fixtures. It covers partial uploads, lost responses,
failed publication, already-public idempotence, a killed process group after
creation, custom output directories, isolated source, and custody/input/remote
drift. It does not claim live GitHub publication or native compilation.
