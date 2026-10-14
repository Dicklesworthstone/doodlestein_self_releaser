# Bounded release archive admission

The shared `src/packaging.sh` archive APIs inspect binary tar/ZIP metadata
before admitting a release payload. `packaging_list_members` prints a complete
safe inventory or nothing; `packaging_validate_archive` additionally reads all
file content to check ZIP local headers/CRCs and compressed tar trailers.
Extraction calls this gate before writing destination members. Build/repack
parity and authenticated release installation use this same policy.

Archive admission requires Python 3.8 or newer with gzip, ZIP and, for tar.xz,
XZ support. It no longer relies on parsing a platform's verbose tar/unzip
listing. The legacy standalone installer templates have their own extraction
implementation; this change does not silently qualify or replace those.

## Resource limits

These environment variables select positive, finite limits. Invalid values
fail closed; zero, empty strings and `auto` do not disable the limits.

| Variable | Default | Scope |
| --- | ---: | --- |
| `DSR_ARCHIVE_MAX_BYTES` | 8 GiB | Sum of declared expanded regular-file bytes |
| `DSR_ARCHIVE_MAX_FILE_BYTES` | 2 GiB | Expanded bytes in any one file |
| `DSR_ARCHIVE_MAX_MEMBERS` | 100,000 | Declared members and total paths, including implicit directories |
| `DSR_ARCHIVE_MAX_PATH_DEPTH` | 64 | Components in a member path |
| `DSR_ARCHIVE_MAX_METADATA_BYTES` | 16 MiB | ZIP central directory and bounded tar metadata reads |

Member limits are capped at one million; path depth at 256. Byte limits are
bounded positive decimal integers no larger than 9,007,199,254,740,991.
Tar decompression also has a finite whole-stream allowance for declared payload,
headers and padding. These are archive admission limits, not a process-memory,
CPU-time or free-disk-space reservation guarantee. Keep the caller's helper
timeout and disk-capacity admission in place.

For an intentionally larger release, select a finite budget explicitly:

```bash
source src/packaging.sh
DSR_ARCHIVE_MAX_FILE_BYTES=4294967296 \
  packaging_validate_archive /srv/releases/model.tar.xz tar.xz
```

The same limits apply on extraction and repacking, including reuse checks.

## Refusal policy

Only regular files and directories are admitted. Links, devices, FIFOs,
sparse tar files, encrypted ZIPs, setuid/setgid/sticky modes, duplicate members,
file/directory prefix conflicts and unsafe paths are rejected. The path policy
rejects traversal, absolute/drive/alternate-stream names, control characters,
backslashes, excessive depth and overlong UTF-8 path components. Spaces and
ordinary Unicode names remain literal data.

ZIP64 payloads and single-disk ZIP64 directories are supported. Conflicting
classic/ZIP64 metadata, split ZIPs and ambiguous central-directory locations
are refused. A listing alone is not a payload-CRC verification. Validation does
not authenticate the publisher, source commit or compiler; signatures and
manifest-bound release checks remain independent requirements.

Run `bash scripts/tests/test_packaging_admission.sh`. The suite uses actual
archives, production APIs and retained owned files, without a network service,
compiler or replaced production function. Individual unittest method names may
be supplied to run bounded groups. Set `DSR_TEST_PACKAGING_MODULE` to an exact
older module to run unchanged counterexamples against the baseline.
