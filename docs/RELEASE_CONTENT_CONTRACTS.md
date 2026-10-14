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
The platform-owned assets must cover exactly the `--targets` selection. Shared
assets use the existing native-manifest `target: "additional"` label, omit
`target_triple`, and do not count as a platform or compiler variant.

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
    },
    {
      "name": "LICENSE",
      "target": "additional",
      "archive_format": "binary"
    }
  ],
  "required_variants": [
    {"target": "linux/amd64", "target_triple": "x86_64-unknown-linux-gnu"},
    {"target": "linux/amd64", "target_triple": "x86_64-unknown-linux-musl"}
  ]
}
```

When `required_variants` is present, every platform-owned asset must declare its compiler
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

## Shared release assets

The SLSA manifest producer, signed-release policy, contract normalizer and
snapshot verifier all retain `target: "additional"` assets as full signed
subjects. Licenses, notices and shared data need not be mislabeled as Linux or
assigned a fabricated compiler target to pass provenance generation. Both hash
passes and the complete byte budget include these assets. Their sizes, formats,
names and hashes remain bound to the manifest and signed statement.

Shared assets do not enter `requested_targets`, `required_variants`, native task
counts, host results or build-environment coverage. A shared-only manifest is
not a successful platform build. Missing platforms or GNU/musl variants still
fail, and even a null `target_triple` is invalid on a shared asset. A contract
that lists a shared asset requires that exact name, target and format; a valid
signature on a statement omitting it cannot satisfy that independent contract.

Remote SLSA payload admission includes explicitly signed shared names even when
the separate SBOM scanner classifies them as metadata, such as `LICENSE`,
`NOTICE.txt`, or `runtime.json`. Those names must exist in the actual inventory,
pass numeric-ID/size/digest checks, and be downloaded and hashed normally.
This does not globally reclassify SBOM metadata or permit unexpected binaries.
Unselected metadata keeps its existing policy; it does not become verified
release content merely by being present.

This uses the existing manifest schema and SLSA subject format. It does not
create new native compiler evidence, broaden installation executable recipes,
or qualify unrelated build, scanner or release-command entry points.

### Assembly from independent build shards

`release_bundle.sh` accepts the same `target: "additional"` entries in its
optional `required_assets` contract. Every shared file belongs to exactly one
of the selected, SHA256-pinned component manifests. Its shard imports and hashes
the file normally; the aggregate enforces the complete required asset set before
the final release directory is published. Shared files never enter shard
`targets`, the plan's `required_targets`, or any compiler `variants` array.

Platform-partitioned and same-platform GNU/musl shards both retain their exact
platform/variant admission checks. Each shard must supply its required platform
assets and may only supply shared names allowed by the exact asset contract.
Shared assets need not be repeated by every shard. Two shards declaring the
same shared name are a conflict, even with identical bytes; there is no implicit
first-writer selection or deduplication. Without `required_assets`, the selected
manifest hashes still bind every imported name and its sole owner.

Incomplete collection retains verified shared-file checkpoints along with the
other completed shard data. Resume can use them after the original build
directory disappears, but rechecks all retained bytes before assembly. Missing
required shared assets, changed checkpoint/export bytes, and ambiguous owners
block a successful result without rewriting the earlier evidence. This is
local build-set assembly, not compiler or signature authentication. Run the
`SharedBundleTests` class in `scripts/tests/test_slsa_shared_assets.sh` for the
complete local collector lifecycle and unchanged-baseline counterexamples.

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

The contract extends the explicit SLSA and installation entry points. It does not change the
root `dsr release verify` checksum path, authenticate checksum aggregates, or
supply the separate native/RCH execution acceptance evidence.

## Installation and standalone distribution

Direct installation accepts the same optional `--release-contract FILE` with
either `--fetch` or `--snapshot`:

```bash
bash src/release_install.sh --snapshot /srv/app-snapshot \
  --recipe /srv/policy/app-install.json --prefix /home/alice/.local/app \
  --repo owner/app --tag v1.2.3 --sha "$SOURCE_SHA" \
  --builder dsr/production --public-key /srv/keys/release.pub \
  --targets linux/amd64 --release-contract /srv/policy/app-content.json
```

The engine freezes and normalizes the independently selected contract, checks
recipe names/formats/compiler selections against it before acquisition, and
passes that exact policy through remote fetch and local reauthentication. A
signed GNU-only snapshot cannot satisfy a contract also requiring musl, even
when the installation recipe selects only GNU. No download receipt supplies
policy authority and no selector narrows complete-release byte verification.

The generation receipt retains the normalized `release_contract` and its hash;
the public result includes `release_contract_sha256`. Equivalent contract
ordering reuses the same generation. Changing or dropping the contract changes
installation identity and requires the existing explicit `--replace` consent.
Previous generations remain available for reauthenticated rollback. Changes to
the original selected contract during installation block successful activation.
Without a contract, existing generation identity and output shape are unchanged.

For standalone distribution, add an optional `release_contract` **object** to
the reviewed JSON policy consumed by `install_gen_release.sh`. Its value is the
complete contract above, not a path, URL, or downloaded object. The generator
normalizes it with the captured SLSA engine and validates every recipe through
the same production installation normalizer. Invalid/missing recipe assets,
contradictory formats/triples, incomplete platforms and explicit null contracts
fail before an installer is written. Generation and `--inspect` still report
`authenticated: false` because they have not authenticated any release bytes.

The generated script embeds the normalized contract and supplies it to its
captured installation engine. Runtime `--target-triple` only chooses an embedded
recipe; it does not reduce the content contract. There is **no runtime
`--release-contract` override** on the standalone script. Streamed and offline
execution need neither the original policy/contract file nor the generator
checkout, and produce the same content-bound generation as direct installation.

## Regression

`bash scripts/tests/test_slsa_shared_assets.sh` tests shared-asset production,
exact contracts, snapshot policy, hashing, and post-authentication payload
acquisition. Build metadata is synthetic; archives and shared file bytes are
real. Remote tests read the actual SBOM taxonomy and download functions, with
only the HTTP acquisition boundary replaced by local files. Snapshot tests use
real Minisign when installed; without it they explicitly skip. Selecting
`DSR_TEST_MINISIGN_FIXTURE=1` runs their policy/bytes checks with an external
signer fixture and is not cryptographic qualification. Individual unittest
classes or method names may be supplied for bounded runs.

Run `bash scripts/tests/test_slsa_release_contract.sh`. It exercises the actual
mapper, SLSA policy, payload hashing and snapshot publication with owned files.
Remote acquisition/API observations use explicitly defined local callbacks.
The suite requires Minisign by default; `DSR_TEST_MINISIGN_FIXTURE=1` explicitly
selects a deterministic key/hash boundary fixture, not cryptographic
qualification. No release is uploaded and no test payload is executed.

`scripts/tests/test_release_install_variants.sh` additionally covers direct and
generated contract enforcement, real streamed-script execution, policy-bound
generation identity, consent/retry/rollback, input drift, and complete fetch to
local reauthentication. Acquisition/API observations use explicit local-file
callbacks, not live HTTP. Its explicit signer-fixture and partial-checkout
offline-sentinel options are described in `GENERATED_RELEASE_INSTALLERS.md`.
