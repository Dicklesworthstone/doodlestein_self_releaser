# Independently selected signed-release contents

`src/slsa_remote.sh` accepts `--release-contract FILE` for `verify-release`,
`fetch-release`, `verify-snapshot`, and `publish-release`. This supplements the
existing repository, tag, source commit, builder, public key and complete
platform selection. It does not replace any signature, byte-integrity or remote
inventory check.

Without an independent content contract, a validly signed statement can define
its own payload subset within the selected platforms. A contract pins the
complete public asset names, platform assignments, archive formats, and optional
compiler identities. A complete platform set cannot conceal a missing GNU/musl
variant, missing compatibility alias, swapped filename/ABI assignment or changed
archive format.

## Contract format

The file is one JSON object with `schema_version: 1` and a nonempty
`required_assets` array. Each asset has `name`, `target`, and `archive_format`;
`target_triple` is optional. The names are a closed set, not minimum coverage.
The asset platforms must cover exactly the `--targets` selection.

```json
{
  "schema_version": 1,
  "required_assets": [
    {
      "name": "app-gnu.tar.gz",
      "target": "linux/amd64",
      "target_triple": "x86_64-unknown-linux-gnu",
      "archive_format": "tar.gz"
    },
    {
      "name": "app-musl.tar.xz",
      "target": "linux/amd64",
      "target_triple": "x86_64-unknown-linux-musl",
      "archive_format": "tar.xz"
    }
  ],
  "required_variants": [
    {"target": "linux/amd64", "target_triple": "x86_64-unknown-linux-gnu"},
    {"target": "linux/amd64", "target_triple": "x86_64-unknown-linux-musl"}
  ]
}
```

When `required_variants` is present, every asset must declare its compiler
identity and the complete set of pairs must match that matrix. Several names
may belong to one pair; aliases are assets, not additional compiler tasks.
Without this field, individual names can still pin their `target_triple`.
An untyped name keeps the platform/format contract without inventing a compiler
claim absent from older statements. This contract does not inspect binary ABIs
or establish whether a compiler actually executed.

Both arrays are bounded to 256 records. Files are bounded to one MiB, names and
compiler selectors to 128 ASCII characters. Duplicate JSON keys, unsafe paths,
unknown fields, explicit null selectors, case-colliding names, duplicate
variants, non-finite numbers, incomplete matrices and linked/special files are
rejected. Contract paths must be canonical absolute paths without symlinks.
Canonical array ordering gives equivalent selections the same contract hash.

## Inspect, verify and fetch

```bash
bash src/slsa_remote.sh describe-contract \
  --release-contract /srv/policy/app-content.json --targets linux/amd64

bash src/slsa_remote.sh fetch-release --output-dir /srv/app-snapshot \
  --repo owner/app --tag v1.2.3 --sha "$SOURCE_SHA" \
  --builder dsr/production --public-key /srv/keys/release.pub \
  --targets linux/amd64 --release-contract /srv/policy/app-content.json

bash src/slsa_remote.sh verify-snapshot /srv/app-snapshot \
  --repo owner/app --tag v1.2.3 --sha "$SOURCE_SHA" \
  --builder dsr/production --public-key /srv/keys/release.pub \
  --targets linux/amd64 --release-contract /srv/policy/app-content.json
```

`describe-contract` performs only bounded local validation and emits
`authenticated: false`, the canonical contract, its SHA256 and the original
input SHA256. It needs Python 3 but neither Minisign nor network access. Live
verification authenticates the statement before comparing signed content to
the independently selected contract. Remote fetch/verification rejects a
contract mismatch before downloading payloads. Local publication preflight
performs the same check before any upload; `publish-release --dry-run` remains
local-only.

A successful remote observation carries `release_contract_sha256`; an offline
result retains both that hash and the normalized contract in `policy`. The
snapshot byte identity remains a function of proof/signature/payload bytes, not
which policy verified them. Every offline invocation must supply its own policy;
`download.json` never supplies trusted contract authority.

The selected contract bytes are checked again before successful completion and
snapshot publication. A changed selection is a refusal, not permission to use
new requirements mid-operation. No command overwrites a pre-existing snapshot
or silently substitutes another release, proof, key, contract or asset.

The contract extends the explicit SLSA entry points only. It does not change the
root `dsr release verify` checksum path, authenticate checksum aggregates, or
supply the separate native/RCH execution acceptance evidence.

## Regression

Run `bash scripts/tests/test_slsa_release_contract.sh`. It exercises the actual
mapper, SLSA policy, payload hashing and snapshot publication with owned files.
Remote acquisition/API observations use explicitly defined local callbacks.
The suite requires Minisign by default; `DSR_TEST_MINISIGN_FIXTURE=1` explicitly
selects a deterministic key/hash boundary fixture, not cryptographic
qualification. No release is uploaded and no test payload is executed.
