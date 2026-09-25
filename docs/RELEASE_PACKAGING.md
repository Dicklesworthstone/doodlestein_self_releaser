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
from explicitly renamed **flat regular files**, preserving their executable
bits. The sources must be manifest-declared raw payloads, not archives. Known
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
point into a mutable producer directory. All names are safe basenames of at
most 128 characters; output/alias names and archive member names must be unique
ignoring ASCII case. There are at most 256 output names including aliases.
Suffixes must agree with declared archive formats. Unknown fields, duplicate
JSON keys, explicit null lists, missing input assets and unconsumed producer
assets are errors. A source may participate in several independent outputs.
The recipe is an exact inventory, not an instruction to glob a directory.

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
Executable bits are preserved while setuid/setgid and unusual write permissions
are not propagated. Archive container bytes are not promised to reproduce across
different hosts/tool versions; completed output hashes are pinned and verified.
Provide temporary space for source copies, extraction and final archives. There
is no streaming extraction quota or distributed/power-loss transaction guarantee.

Run `bash scripts/tests/test_release_packaging.sh`. It uses actual archives,
extraction, shared admission and filesystem operations. It compiles and executes
a tiny C fixture when `cc` is available (otherwise it uses a shell executable).
It tests all output formats, prebuilt preservation, independent repacking,
producer disappearance, drift, malicious archive entries and compressor failure.
No live GitHub, signing or Rust/Windows build acceptance is claimed.

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
and mode `0644 | original executable bits`. Gzip has a fixed compression level
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
added again. Missing includes trigger a new archive; conflicting includes fail
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
