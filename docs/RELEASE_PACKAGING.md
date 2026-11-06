# Package a pinned build for release

`src/release_packaging.sh` turns an admitted producer manifest into archives,
raw executable names and installer-compatible aliases. It consumes only files
named by that manifest, requires every producer asset to be represented, and
retains the exact original manifest and payloads beside its completed output.
It does not compile, sign, upload, create releases or promote drafts.

## Recipe

```json
{
  "schema_version": 1,
  "artifacts": [
    {
      "name": "demo-1.2.3-windows-arm64.zip",
      "target": "windows/arm64",
      "archive_format": "zip",
      "members": [
        {"source": "demo-aarch64-pc-windows-msvc.exe", "path": "demo.exe"},
        {"source": "helper-aarch64-pc-windows-msvc.exe", "path": "helper.exe"}
      ],
      "aliases": ["demo-windows-arm64.zip"]
    },
    {
      "name": "demo.exe",
      "target": "windows/arm64",
      "archive_format": "binary",
      "source": "demo-aarch64-pc-windows-msvc.exe"
    }
  ]
}
```

Each artifact selects either `members` or `source`. `members` builds an archive
from explicitly mapped regular files, preserving which files are executable.
Destinations may be nested relative paths such as `bin/demo` and
`libexec/helper`; their parent directories are created inside the private
payload. The sources must be manifest-declared raw payloads, not archives. Known
archive signatures masquerading as raw members are also refused. Every member
must have the same target as its output; packaging cannot relabel platforms.

`source` copies a raw payload or copies/converts a prebuilt archive. The
same-format prebuilt archive is copied **byte-for-byte**, without recompression.
A different archive format is built from the extracted original members, never
by putting one archive inside another. Both paths validate the archive's actual
compression, member safety, file bytes and executable bits using the existing
`packaging.sh` helpers. ZIP, tar.gz (including `.tgz` names), and tar.xz are
supported. `binary` and `none` represent raw files.

`aliases` creates separate byte-identical copies of its primary. It does not
point into a mutable producer directory. Producer, output and alias names are
safe basenames of at most 128 characters. Archive member destinations allow
up to 16 safe segments and 1,024 characters in total, with at most 128
characters per segment. Absolute paths, empty or dot segments, backslashes,
traversal and links are refused. Output/alias names are unique ignoring ASCII
case. Within each archive, binary members and source companions share one
namespace, including their implicit parent directories: `Bin/demo` and
`bin/helper`, or a file `share` and a file `share/LICENSE`, conflict. There are
at most 256 output names including aliases.
Suffixes must agree with declared archive formats. Unknown fields, duplicate
JSON keys, explicit null lists, missing input assets and unconsumed producer
assets are errors. A source may participate in several independent outputs.
The recipe is an exact inventory, not an instruction to glob a directory.

For a complete application layout, map verified executable outputs and pinned
Git source files explicitly:

```json
{
  "name": "demo-linux-amd64.tar.xz",
  "target": "linux/amd64",
  "archive_format": "tar.xz",
  "members": [
    {"source": "demo", "path": "bin/demo"},
    {"source": "helper", "path": "libexec/helper"}
  ],
  "source_files": [
    {"source": "LICENSE", "path": "share/demo/LICENSE"},
    {"source": "docs/README.md", "path": "share/demo/docs/README.md"}
  ]
}
```

This is one entry in the recipe's `artifacts` array. Supply `--source-repo` to
the packaging command (or `--packaging-source-repo` to the finalizer) when
selecting source companions. Source files come from the selected release
commit, including their executable bits; working-copy contents never supply
these bytes. Nested layouts use the same archive admission, complete output
inventory and retained retry evidence as flat layouts. A complete prebuilt
archive whose selected companions already match keeps its exact compressed
bytes. See [source companion custody](PACKAGED_RELEASE_FINALIZATION.md#include-license-and-other-files-from-the-exact-release-commit)
for the source selection and retry contract.

## Shared release payloads

Recipes can consume explicitly declared shared producer assets with
`target: "additional"`. For example, preserve a release notice unchanged:

```json
{
  "name": "NOTICE",
  "source": "NOTICE",
  "target": "additional",
  "archive_format": "none"
}
```

Raw shared files retain their selected names and exact bytes. A shared archive
may instead select `members`, or use `source` to preserve or convert an admitted
shared archive through the normal extraction and parity checks. All its producer
inputs must also belong to `additional`; packaging cannot relabel a physical
executable as shared data or assign a shared file to a physical platform.
Aliases are created only when explicitly listed in the recipe.

Shared assets must omit `target_triple`, including explicit null. They never
stand in for a physical target or compiler variant. All physical outputs must
still cover the original platform and variant matrix, while the derived manifest
preserves the actual build environments and successful-task count. Every producer
asset, including each selected shared file, must be consumed. The public
build-plan finalizer checks that complete input selection before starting work
and checks the actual bytes and resulting manifest before downstream finalization.
An execution plan containing only xwin jobs cannot supply shared recipe inputs,
even when the plan omits the optional `required_assets` selection. Such a recipe
is rejected before compilation. Mixed DSR/import plans and completed build sets
remain subject to their actual pinned producer manifests and exact ownership.

These files remain payloads in the exact release inventory. This feature does
not reclassify arbitrary metadata or weaken checksum, signature, provenance or
publication checks. Retained shared files and archives undergo the same
completed-output verification on retry as physical-platform outputs.

## Companion archives in ordinary builds

The packaging step in `dsr build` also preserves the ownership declared by
`workspace_additional_artifacts`. A validated companion ZIP or tar archive
keeps its literal name and exact bytes in the final inventory. Sharing a target
and archive format with the primary executable does not make that companion
eligible to supply the primary release archive or its installer alias.
Companion names are reserved across the flat output directory, ignoring case.
A primary or installer name that collides with one is refused before packaging,
including a compiler variant's name or a companion with identical bytes.

Primary selection excludes the configured companions whose collection receipts
were verified, then matches the requested platform and compiler variant. DSR
packages a raw primary, converts a primary archive when needed, or reuses an
already complete primary archive without changing its bytes. A missing or
invalid primary prevents publication even when every companion is valid.

`bash scripts/tests/test_ordinary_collection_inventory.sh --companion-packaging-only`
exercises the complete build command with real small host ELF files and archives.
Its producer and scheduler responses are controlled fixtures; receipt validation,
collection, packaging, manifest admission and completion writes run unchanged.
The cases cover gzip and ZIP companions, conversion, preserved prebuilt bytes,
raw binaries, compiler variant selection, reserved-name collisions and unusable primaries. They do not
claim native compiler, GNU/musl ABI or remote-host qualification.

## Complete native workspace archives

A native workspace build succeeds only after its ZIP, tar.gz or tar.xz archive
contains every configured workspace binary, `workspace_archive_files` entry and
enabled include file, with no unexpected members. The runner records each
collected or staged member's bytes and permissions before packaging, then checks
the actual archive against those records. Nested include paths and empty include
files remain valid. Ordinary builds use their working-tree includes; strict
release builds retain the additional checks against the selected Git commit.

Archive creation reserves a fresh output file and checks the compressor's exit
status, the complete member inventory, each member's bytes and mode, and the
final archive receipt. A missing tool, incomplete collection, partial archive or
changed member fails the target with exit code `7`. Raw binaries and partial
archives are not returned as successful substitutes. Retained files from a
failed attempt remain diagnostic evidence, and retries use a separate attempt
directory so they cannot overwrite an earlier completed archive or its resume
receipt.

Script payloads are supported for ordinary noncompiled workspaces. Rust and Go
payloads still undergo native target validation, and strict release callers
retain their architecture checks.

Run `bash scripts/tests/test_act_runner_native.sh --workspace-archives-only`
for this boundary. It executes the production native build and collection path
with local shell builds and real ZIP and tar tools. Faults include archivers
that leave readable but incomplete output, changed collected members, failed
collection and unavailable output paths. The test also checks failed-result
resume refusal and preservation of completed bytes across retries. Host
readiness and slot admission are controlled; this test does not qualify a remote
host or a compiler toolchain.

## Published archive metadata

Newly constructed native and generic release archives use explicit public
permissions. A regular file with any executable bit becomes `0755`; every
other regular file becomes `0644`. Setuid, setgid and sticky bits are removed.
Tar members have numeric owner/group IDs `0/0` and empty user/group names.
ZIP members carry the same normalized Unix permissions and omit host ownership
extra fields. This applies to gzip, XZ and ZIP creation, including singleton
contract staging, format conversion and `SOURCE_DATE_EPOCH` builds.

Private collection files keep their original permissions, bytes and inode
identities. The archive writer makes fresh copies behind a `0700` staging
directory, normalizes those copies, then runs GNU tar or macOS bsdtar with
explicit ownership options. It does not depend on bsdtar supporting GNU
`--mode`. Full source receipts still match exactly; the separate archive check
requires the canonical published permissions and ownership.

Strict native packaging retains the original member receipts for binaries,
generated workspace companions and staged includes. Each private file must
still match its frozen identity, contents and permissions when its public
archive representation is admitted. Singleton contract staging also retains
the original exclusive output receipt and rechecks it after validation, so a
replacement archive cannot establish a new accepted identity or digest.

Existing prebuilt archives reused without reconstruction retain their exact
compressed bytes. This change does not rewrite previously published assets.
Checksums, manifests and signatures for newly created archives bind the final
normalized bytes through the existing release pipeline.

Run the real archive implementation regressions and signed installer check:

```bash
DSR_TEST_TAR=gnu bash scripts/tests/test_native_single_archives.sh
DSR_TEST_TAR=bsd bash scripts/tests/test_native_single_archives.sh
bash scripts/tests/test_act_runner_native.sh --archive-delivery-only
```

The archive tests inspect stored header fields, extract and execute payloads,
verify private source metadata is unchanged, and reject archiver failures.
The delivery check uses a temporary Minisign key and generated offline-cache
installers; it exercises checksum and signature rejection without publishing.

## Describe and execute

```bash
bash src/release_packaging.sh --recipe /srv/packaging.json --describe

bash src/release_packaging.sh --recipe /srv/packaging.json \
  --manifest /srv/build/build-manifest.json \
  --manifest-sha256 "$REVIEWED_PRODUCER_MANIFEST_SHA256" \
  --artifacts-dir /srv/build/artifacts --output-dir /srv/packaged \
  --repo OWNER/REPO --tag v1.2.3 --sha "$SOURCE_COMMIT"
```

Use the actual manifest hash and full nonzero source commit. Description only
normalizes the recipe and reports its expanded output requirements and source
name/target pairs; it neither reads a producer nor creates persistent state.
Execution first runs the shared successful-release manifest and byte admission.
The repository/version/commit must match the explicit selection. Neither a
successful diagnostic build nor an incomplete producer can be packaged around
those checks.

All filesystem selections must be canonical absolute paths without symlink
components. The output parent must exist and the output must not overlap the
producer directory or contain its manifest. The output namespace is serialized
by a local advisory lock. Only a complete, verified set becomes visible at:

```text
packaged/
  identity.json                   # Frozen recipe/source/release selection
  lock
  release/
    recipe.json
    source/build-manifest.json     # Exact input bytes, including old requirements
    source/artifacts/              # Verified producer snapshots
    artifacts/                     # New release names only
    build-manifest.json
    result.json
```

Repeat the same command to reverify an existing package. It checks the retained
producer pin, recipe, source bytes, exact output namespace, aliases, archive
contents, derived manifest and receipt without rewriting completed files.
Original producer paths may then be offline. Changed recipes/pins and corrupt
completed outputs are conflicts, not permission to repair or select new bytes.
Failed preparation leaves no `release/`; retry can rebuild from the originally
selected producer files. Private temporary staging is cleaned on handled exits.

The derived manifest preserves source/dependency/build-environment evidence,
run ID and the original build completion timestamp. `packaging_evidence` binds
the original manifest hash, canonical recipe hash, member mappings and observed
source executable bits. Its `required_assets` describes the new exact namespace.
Old checksum/signature/SBOM pointers are removed, and output artifacts are marked
unsigned. They must pass the normal signing, SBOM, provenance and publication
pipeline for these new bytes. Keep the retained producer manifest to audit its
original asset contract; packaging does not erase it from the evidence chain.

## Boundaries and tests

Use a POSIX build host with Python 3, Bash, jq, and the existing archive tools.
Helpers have a 900-second timeout and their owned process groups are terminated
on interruption or failure. Common ambient compressor-option variables are
scrubbed. Tools, host and local storage remain trusted: compressor executables
are not attested, and this is neither a sandbox nor a signed provenance service.
Executability is preserved with canonical `0755`/`0644` member permissions;
setuid/setgid and unusual write permissions are not propagated. Archive container
bytes are not promised to reproduce across
different hosts/tool versions; completed output hashes are pinned and verified.
Provide temporary space for source copies, extraction and final archives. There
is no streaming extraction quota or distributed/power-loss transaction guarantee.

Run `bash scripts/tests/test_release_packaging.sh`. It uses actual archives,
extraction, shared admission and filesystem operations. It compiles and executes
a tiny C fixture when `cc` is available (otherwise it uses a shell executable).
It tests all output formats, prebuilt preservation, independent repacking,
producer disappearance, drift, malicious archive entries and compressor failure.
No live GitHub, signing or Rust/Windows build acceptance is claimed.

`bash scripts/tests/test_release_packaging_variants.sh` also exercises exact
plans with shared raw files and archives alongside GNU, musl and Windows compiler
identities. It uses the real coordinator, pinned imports, collection, archive
construction, manifest/SLSA admission and public finalizer CLI. The imported
producer evidence and the final network/signing engine are fixtures; this test
does not claim actual compilation or authenticated build provenance. Its shared
payload group can run alone with `DSR_PACKAGING_SHARED_ONLY=1`. Controls cover
invalid physical/triple selections, missing and unselected payloads, duplicate
owners, unchanged offline retries, and refusal of changed completed outputs.

## Reproducible new archives

Export `SOURCE_DATE_EPOCH` before packaging to make **newly constructed**
archives independent of filesystem mtimes, member selection/creation order,
user/group identities, time zone, umask and non-executable permission bits:

```bash
# Select a stable timestamp from the reviewed source, not the current clock.
SOURCE_DATE_EPOCH=$(git -C /srv/source show -s --format=%ct "$SOURCE_COMMIT")
export SOURCE_DATE_EPOCH

bash src/release_packaging.sh --recipe /srv/packaging.json \
  --manifest /srv/build/build-manifest.json \
  --manifest-sha256 "$REVIEWED_PRODUCER_MANIFEST_SHA256" \
  --artifacts-dir /srv/build/artifacts --output-dir /srv/packaged \
  --repo OWNER/REPO --tag v1.2.3 --sha "$SOURCE_COMMIT"
```

The same environment selection works with sourced `packaging_build_archive`
and with cross-format `packaging_repack_archive`. It is opt-in: an unset
variable retains the existing native archive-tool behavior. A set value must
contain 1–10 decimal digits and be in `0..4294967295`, the common unsigned gzip
timestamp range. Invalid values return `4` from the packaging helpers even if
an existing archive could otherwise be reused. A new reproducible archive needs
Python 3.8+ with standard gzip, lzma, tarfile and zipfile support; a missing
interpreter or archive module returns dependency code `3`.

The reproducible writer streams regular payload files in byte-sorted name
order. It emits only the selected files, with parent directories implicit.
Tar uses PAX format, uid/gid zero, empty owner/group names, the selected epoch,
and mode `0755` for executable files or `0644` for other files. Gzip has a fixed compression level
and no embedded temporary filename; XZ has a fixed preset and checksum mode.
ZIP uses DEFLATE, Unix file modes, and a UTC-derived DOS timestamp rounded down
to two-second precision; epochs before 1980 are represented as 1980-01-01.
Source timestamps, ownership and modes are never changed. Long safe paths and
spaces are supported, while links, special files and unsafe names remain
invalid. Every generated archive must pass the existing real extraction,
file-set, byte and executable-bit parity checks before atomic publication.

**Preserving producer bytes takes precedence over recompression.** Same-format
prebuilt archives remain byte-for-byte copies. Verified completed archives
remain unchanged, including their inodes, when only the epoch changes. To compare
independent builds, use separate fresh output locations; this option does not
rewrite previously admitted or signed bytes. Matching configured include files
already present in a producer are verified by content and executable bits, not
added again. A fully normalized archive may represent a private executable
include as `0755`; its bytes must still match exactly. Legacy archives retain
exact execution-mask equality. Missing includes trigger a new archive; conflicting includes fail
without overwriting either producer or prior destination.

This is reproducible *packaging*, not proof of reproducible compilation or native
platform qualification. Python and compression-library versions must be pinned
for byte comparisons across toolchains. The environment timestamp is not added
to the recipe or attested as build provenance: retain it with the build command
and use the same value on fresh attempts. Existing output digests and the frozen
completed package remain authoritative on resume.

Run `bash scripts/tests/test_packaging_reproducible.sh` and
`bash scripts/tests/test_packaging_prebuilt.sh`. The reproducibility suite builds
independent tar.gz, tar.xz and ZIP files from differently ordered/timestamped
source trees, checks archive metadata with independent readers, exercises
invalid/boundary epochs, and verifies source preservation and failure atomicity.
The prebuilt suite covers matching/missing/conflicting includes and byte/inode
preservation. These are real local archive tests, not live release acceptance.
