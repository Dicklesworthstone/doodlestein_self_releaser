# Download and reauthenticate complete signed releases

The provenance verifier can retain the exact verified release bytes for offline
use, distribution or installation. This is a consumer operation: it never
creates a release, uploads assets, signs a statement or runs a downloaded binary.

## Fetch a complete snapshot

```bash
bash src/slsa_remote.sh fetch-release \
  --repo OWNER/REPO --tag v1.2.3 --sha "$REVIEWED_SOURCE_COMMIT" \
  --builder "$TRUSTED_BUILDER_ID" --public-key /srv/keys/release.pub \
  --targets linux/amd64,darwin/arm64,windows/arm64 \
  --output-dir /srv/downloads/tool-v1.2.3
```

Supply the actual repository, full nonzero source commit, independently trusted
Minisign public key, builder identity and **complete** expected target matrix.
The public key must not be selected from the downloaded statement. Optional
`--statement-sha256`, `--manifest-sha256` and `--invocation-id` pin a particular
statement or build; `--statement-name` selects the remote provenance asset name.
No value is inferred from a purportedly successful producer receipt.

The existing remote verifier authenticates the statement before consuming its
payload names, downloads every subject (including aliases) by its numeric asset
ID, checks actual bytes even when API digests exist, and rechecks the release,
tag and complete inventory. Fetch retains those **same** downloaded bytes rather
than performing another unbound download after verification. It then separately
reauthenticates the local snapshot before making it visible:

```text
tool-v1.2.3/
  release.intoto.jsonl
  release.intoto.jsonl.minisig
  artifacts/                       # Every signed payload; no private build manifest
  download.json                    # Historical remote observation, not a trust anchor
```

Local proof names are fixed as shown, even when the remote statement uses a
custom name. Its original remote name, numeric IDs and observed release mode
remain in `download.json`. No signing key or credential is copied into the
snapshot. Fetch supports verified drafts as well as published releases; the
returned remote observation identifies which was read. Downloading a draft does
not publish it or assert that it is a public release.

The destination must be a new canonical absolute path with an existing parent.
Symlink path components and occupied destinations are rejected. Preparation is
private staging beside that path, and the complete directory is exposed with
one same-filesystem rename. An adjacent `DESTINATION.lock` serializes cooperating
writers and is intentionally retained. Never remove it to bypass a live owner.
Failures expose no complete snapshot. By default, repeating a failed fetch
downloads again. An existing snapshot is not overwritten or silently repaired:
use offline verification, or opt into the resumable fetch described below from
the first invocation.

Fetch needs Bash, jq, Minisign, Python 3, flock, the ordinary GitHub transport
dependencies and a usable GitHub credential. The source release must already
have manifest-backed signed provenance; unsigned releases cannot use this path.
The ordinary `verify-release` and `publish-release` operations are unchanged.

## Resume an interrupted download

For a large release, add `--resume` to the first fetch and repeat the identical
selection after a connection failure or interruption:

```bash
bash src/slsa_remote.sh fetch-release --resume \
  --repo OWNER/REPO --tag v1.2.3 --sha "$REVIEWED_SOURCE_COMMIT" \
  --builder "$TRUSTED_BUILDER_ID" --public-key /srv/keys/release.pub \
  --targets linux/amd64,darwin/arm64,windows/arm64 \
  --output-dir /srv/downloads/tool-v1.2.3
```

This mode retains verified progress in the private sibling directory
`/srv/downloads/tool-v1.2.3.partial`. Its `selection.json` binds the independently
selected policy and public-key bytes to the authenticated statement/signature,
repository, release, tag commit and complete numeric asset inventory. Its
`artifacts/` directory contains only fully downloaded payloads that match their
signed size and SHA-256. An incomplete individual transfer never enters that
namespace; its next attempt starts from byte zero.

Every retry reads the current release and tag, downloads and authenticates the
statement/signature again, and requires that same frozen release generation.
It rehashes **every** retained payload before downloading any missing payload.
It then downloads only the missing assets by their numeric IDs, repeats the
complete release and local snapshot verification, and exposes the finished
snapshot with the existing atomic directory rename. A failed last target can
therefore preserve all previously verified targets without accepting a partial
release as success.

Changed policy, key bytes, release mode, tag, statement, signature or asset
inventory refuses reuse. Corrupt, linked, extra or unrelated checkpoint files
are refused without repair or replacement. Use a different new output path for
a genuinely different release generation. The existing destination lock covers
both modes; leaving off `--resume` when a checkpoint exists is an error rather
than a second independent download into the same destination.

A successful resumable fetch retains its checkpoint. Repeating the same
`--resume` command authenticates the completed snapshot before contacting
GitHub, verifies current remote identity, and returns the same snapshot identity
without replacing its files or historical `download.json`. With an intact
checkpoint, no payload is downloaded again; the small statement and signature
are still fetched. The result's `acquisition.reused_payloads` and
`acquisition.downloaded_payloads` distinguish checked local bytes from new HTTP
body reads. All payload bytes are authenticated against the selected signed
statement, including reused bytes; reuse is not a fresh download claim.

Checkpoint payloads and the completed snapshot share private read-only file
inodes to avoid duplicating a multi-gigabyte release. Both namespaces remain
subject to byte verification on retry. Keep this managed storage private;
changing a shared inode invalidates both views. The checkpoint is cooperating
writer recovery storage, not a separate cryptographic trust anchor or protection
against arbitrary same-user filesystem changes.

## Download independent assets concurrently

Add `--jobs N` to `fetch-release` or `verify-release` to download up to `N`
signed payloads at once. The default is `1`; accepted values are `1` through
`32`. For example, a resumable four-worker acquisition uses:

```bash
bash src/slsa_remote.sh fetch-release --resume --jobs 4 \
  --repo OWNER/REPO --tag v1.2.3 --sha "$REVIEWED_SOURCE_COMMIT" \
  --builder "$TRUSTED_BUILDER_ID" --public-key /srv/keys/release.pub \
  --targets linux/amd64,darwin/arm64,windows/arm64 \
  --output-dir /srv/downloads/tool-v1.2.3
```

The statement and signature are authenticated first. All payload names, sizes
and advertised digests, plus every retained checkpoint payload, are checked
before any parallel payload transfer starts. Each worker downloads by the
selected numeric asset ID into private staging and verifies the full body.
The coordinator then retains each completed asset and fills its available
slot; a slow earlier asset does not hold up a completed sibling or an available
download slot. The existing complete local verification and final remote
identity checks still run before exposing a snapshot.

A failed worker stops new scheduling. Its remaining owned transfer groups are
cancelled and drained before acquisition returns. Interruption uses the same
group supervision, including ordinary descendants that ignore `TERM`; no
incomplete transfer is admitted to the checkpoint. `SBOM_REMOTE_TIMEOUT`
continues to bound transfers. Select concurrency for the available bandwidth,
disk throughput and API limits; it does not relax the signed payload-size limit.

Scheduling is not part of release identity. A retry can change `--jobs` while
retaining the same source, signer, policy, asset inventory and checkpoint.
The `acquisition` counts retain their existing meaning. Offline
`verify-snapshot` and publication do not accept this download scheduling option.

## Offline verification

```bash
bash src/slsa_remote.sh verify-snapshot /srv/downloads/tool-v1.2.3 \
  --repo OWNER/REPO --tag v1.2.3 --sha "$REVIEWED_SOURCE_COMMIT" \
  --builder "$TRUSTED_BUILDER_ID" --public-key /srv/keys/release.pub \
  --targets linux/amd64,darwin/arm64,windows/arm64
```

This command needs only the local SLSA modules, Bash, jq, Minisign and ordinary
filesystem/hash tools. It does not load the GitHub or SBOM scanner modules,
resolve credentials, query a tag, or fetch a missing file. Supply the same
independent trust policy and optional build pins again. It reauthenticates the
proof and every payload, rejects extra/missing files and symlinks, and checks
safe, case-unambiguous names and declared formats. Snapshots support at most 256
payloads with basenames of at most 128 characters. The default total signed
payload-size admission limit is 8 GiB, configurable using the existing
`SLSA_REMOTE_MAX_PAYLOAD_BYTES` setting; this limit also applies offline.

The result reports `authenticated: true` and **`remote_current: false`**. It
proves consistency with the selected signed statement, not that the tag, release,
asset IDs, public availability or signer policy remain unchanged on GitHub.
`download.json` is deliberately not an authentication input: editing its status
cannot authenticate changed bytes, and offline verification makes no claims
from that historical observation. Its JSON is not executed or used for paths.

`snapshot_sha256` identifies the exact statement, detached signature and sorted
signed payload records. It excludes the local directory and historical download
receipt, so moving a snapshot preserves that identity. Optional statement/build
pins can prevent accepting a different valid build; this is not an automatic
latest-version or chronological anti-rollback service.

The sourceable APIs are `slsa_fetch_release` and `slsa_verify_snapshot` with the
same arguments. Success emits one JSON object; failures return nonzero without
a success object, following the existing remote SLSA API contract.

For explicit multi-binary installation, [RELEASE_INSTALLATION.md](RELEASE_INSTALLATION.md)
describes `src/release_install.sh`. It reauthenticates the snapshot, stages the
selected archive members or raw executables, and activates one complete managed
generation. Fetching a snapshot alone never installs or executes its contents.

## Limits and validation

The host, tools, trusted-key selection and local cooperating-writer storage
remain trusted. This is not a sandbox against a privileged filesystem writer or
a power-loss/distributed transaction guarantee. The existing remote timeouts and
advertised-size admission limits apply; they are not streaming disk quotas
against a server lying about response sizes. Resumable fetch reuses complete
verified files; it does not continue an individual transfer from a byte offset.

Run `bash scripts/tests/test_slsa_snapshot.sh`. It exercises the complete SLSA
mapper, remote policy/verifier and local snapshot admission with real filesystem
operations and hashes. GitHub transport and Minisign are explicit hash-bound
fixtures, not live HTTP or native Ed25519 acceptance tests. It covers exact-byte
retention, offline CLI use, moved tags, drifted keys, incomplete downloads,
independent policy pins, corrupt last-target payloads, forged receipts, linked or
extra files, collisions, limits and occupied destinations. Its resumable cases
exercise a late transport failure, retained payload inodes, missing-only retries,
completed retries, and cache/policy/key/release/inventory drift. They also cancel
an actual fetch process group while its last transfer is blocked, exclude a
competing resume, and reuse the completed files after cancellation. Select just
those cases with `DSR_SNAPSHOT_RESUME_ONLY=1`; no live network or native Ed25519
claim is made by the transport and signer fixtures.

`DSR_SNAPSHOT_PARALLEL_ONLY=1` selects the concurrent acquisition cases. They
exercise the production downloader, process-group supervision, checkpointing
and final admission with explicit GitHub/signature fixtures. Filesystem barriers
prove actual worker overlap, the concurrency cap and reuse of a free slot while
an earlier transfer is blocked. Failure and cancellation cases include
`TERM`-resistant descendants and verify that they stop before destination custody
is released. These are scheduling and lifecycle checks, not a live-network
throughput benchmark.
