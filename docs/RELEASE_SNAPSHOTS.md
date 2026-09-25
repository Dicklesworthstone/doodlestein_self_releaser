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
Failures expose no complete snapshot; repeating a failed fetch downloads again.
An existing snapshot is not overwritten or silently repaired: use offline
verification, or select a different new destination for another download.

Fetch needs Bash, jq, Minisign, Python 3, flock, the ordinary GitHub transport
dependencies and a usable GitHub credential. The source release must already
have manifest-backed signed provenance; unsigned releases cannot use this path.
The ordinary `verify-release` and `publish-release` operations are unchanged.

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

## Limits and validation

The host, tools, trusted-key selection and local cooperating-writer storage
remain trusted. This is not a sandbox against a privileged filesystem writer or
a power-loss/distributed transaction guarantee. The existing remote timeouts and
advertised-size admission limits apply; they are not streaming disk quotas
against a server lying about response sizes. Partial downloads are not resumed.

Run `bash scripts/tests/test_slsa_snapshot.sh`. It exercises the complete SLSA
mapper, remote policy/verifier and local snapshot admission with real filesystem
operations and hashes. GitHub transport and Minisign are explicit hash-bound
fixtures, not live HTTP or native Ed25519 acceptance tests. It covers exact-byte
retention, offline CLI use, moved tags, drifted keys, incomplete downloads,
independent policy pins, corrupt last-target payloads, forged receipts, linked or
extra files, collisions, limits and occupied destinations.
