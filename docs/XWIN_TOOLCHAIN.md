# Pinned Windows ARM64 toolchain views

`bash scripts/xwin-toolchain.sh prepare --manifest /absolute/toolchain.json`
materializes the LLVM system-header and case-normalized MSVC import-library
view tracked by `dsr-h4y0`. This is an explicit Linux-host preparation command,
not an automatic change to existing `dsr build` or release configurations.
It never renames files in an installed sysroot, installs a compiler, downloads
an unpinned latest release, or changes the source archives.

The prepared view supplies both `kernel32.lib` and `Kernel32.lib` with exactly
the same pinned bytes. It also supplies the complete selected LLVM header tree,
including `arm_neon.h` and its dependent headers. The emitted JSON contains
`CFLAGS`, `CXXFLAGS`, and `LIB` values for the clang backend. This addresses the
header/library compatibility inputs; it does not assert that a particular
Rust project has compiled successfully.

## Input manifest

The manifest must contain exactly one JSON document with `schema_version: 1`
and target `aarch64-pc-windows-msvc`. For example:

```json
{
  "schema_version": 1,
  "target": "aarch64-pc-windows-msvc",
  "sysroot": {
    "path": "/opt/pinned/windows-msvc-sysroot.tar.xz",
    "url": "https://artifacts.example.org/windows/pinned-sysroot.tar.xz",
    "sha256": "<actual SHA-256 of the complete archive>",
    "prefix": "windows-msvc-sysroot"
  },
  "headers": {
    "path": "/opt/pinned/llvm-system-headers.tar.xz",
    "url": "https://artifacts.example.org/llvm/pinned-system-headers.tar.xz",
    "sha256": "<actual SHA-256 of the complete archive>",
    "prefix": "llvm/lib/clang/20/include"
  },
  "aliases": {
    "Kernel32.lib": "kernel32.lib",
    "User32.lib": "user32.lib"
  },
  "tools": {
    "cargo": {"path": "/opt/rust/bin/cargo", "sha256": "<actual SHA-256>"},
    "cargo-xwin": {"path": "/opt/cargo/bin/cargo-xwin", "sha256": "<actual SHA-256>"},
    "rustc": {"path": "/opt/rust/bin/rustc", "sha256": "<actual SHA-256>"},
    "clang": {"path": "/opt/llvm/bin/clang-20", "sha256": "<actual SHA-256>"},
    "lld-link": {"path": "/opt/llvm/bin/lld", "sha256": "<actual SHA-256>"}
  }
}
```

The placeholders are deliberately invalid. Obtain pins from trusted,
independently reviewed release inputs; the command does not invent hashes or
claim the URL establishes provenance. URLs are retained evidence, not fetched.
Use immutable release URLs and preserve the exact pinned archives for later
verification. Query strings, credentials, and whitespace are not accepted in
source URLs.

`sysroot.prefix` selects a directory containing `include/` and
`lib/aarch64-unknown-windows-msvc/`. `headers.prefix` selects a directory
containing `arm_neon.h`. Both must be safe, nonempty, relative paths. Supported
containers are `tar.gz`, `tgz`, `tar.xz`, and `zip`; the existing packaging
validator rejects links, special files, duplicate members, traversal, and
mislabeled compression. Inputs must meet that regular-file archive contract;
this command does not silently dereference symlinks in an arbitrary SDK bundle.

Additional executable identities can be listed in `tools`, for example
`clang++`, `llvm-ar`, and `llvm-rc`. Paths must select actual executable files,
not rustup dispatch proxies or symlinks. An LLVM multicall binary can be pinned
under its intended role, such as `lld-link`; invoking it under that role is the
runner's responsibility. Tool hashes are checked before and after preparation.
The preparation step does not execute these files or collect version output.

Aliases must differ only in letter case from their lower-case source name.
`Kernel32.lib` is required. Missing libraries and two case-folded input names
with different contents are errors, never a last-writer-wins choice. A
case-sensitive cache filesystem is required.

## Prepare and verify

```bash
bash scripts/xwin-toolchain.sh prepare \
  --manifest /opt/pinned/windows-arm64-toolchain.json \
  --cache-dir /var/cache/dsr/xwin-toolchains > toolchain-result.json

bash scripts/xwin-toolchain.sh verify \
  --manifest /opt/pinned/windows-arm64-toolchain.json \
  --cache-dir /var/cache/dsr/xwin-toolchains > verified-toolchain.json
```

The default cache is `${XDG_CACHE_HOME:-$HOME/.cache}/dsr/xwin-toolchains`.
Linux, Bash 4+, jq, GNU coreutils/findutils, flock, and the archive reader for
the selected format are required. Cache and executable paths must not contain
whitespace, semicolons, or backslashes because downstream compiler flag
parsers do not agree on quoting. Archive input paths may contain spaces.

The canonical manifest hash chooses the view directory. Each view retains
`manifest.json`, `evidence.json`, the untouched selected sysroot payload, the
LLVM header tree, and the separate library alias view. Evidence binds source
URLs/archive hashes, all configured executable paths/hashes, and every
materialized file's path/hash/size. Cache reuse is checked against a fresh
reconstruction from pinned archive snapshots, not just a local receipt that
could have been edited alongside the files. Verification requires those
archives to remain available.

Publication is staged and serialized per manifest. A corrupt existing view is
refused, never silently repaired. Successful verification preserves its files
and inodes. Temporary reconstruction directories are cleaned after failures.
The cache is trusted, local, single-user build storage; it is not a defense
against a privileged concurrent filesystem writer.

Exit codes follow DSR conventions: `0` verified/prepared, `2` occupied or
conflicting cache, `3` missing dependency/unsupported host, `4` invalid input,
`5` interruption, and `7` changed pinned input or retained evidence.

## Scope of the evidence

This is not a signed provenance statement or proof of a fully hermetic build.
Executable hashes do not attest dynamically loaded libraries, every compiler
subprocess, the Rust standard library, or arbitrary build-script effects.
Integration with the strict native build manifest/public build JSON remains
part of `bd-10we`. Live BLAKE3 1.8.5 plus ring compilation, and native Windows
host verification, require the actual pinned toolchain and build hosts.

Run the offline archive/filesystem regression suite with:

```bash
bash scripts/tests/test_xwin_toolchain.sh
```
