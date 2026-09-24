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
