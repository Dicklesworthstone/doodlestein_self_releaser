# Complete release checksum audits

Use the read-only audit command when a release needs complete payload coverage,
not a checksum-file syntax check or a three-file spot check:

```bash
bash src/release_checksums.sh --repo owner/tool --tag v1.2.3 \
  --output-dir /srv/audits/tool-v1.2.3-attempt-1
```

The output directory must be new, absolute, and have an existing parent. Omit
`--output-dir` to allocate a private temporary directory. Every attempt retains
its downloaded evidence and JSON result, including failed attempts. Repeat an
audit in a new directory; the auditor never repairs or overwrites prior evidence.

This command is also sourceable as `release_verify_checksums`. Bash, Python 3,
jq, and curl 8.4.0 or newer are required. The curl minimum ensures that the
maximum download size applies during a transfer even without Content-Length.
It is not a claim that arbitrary old curl installations are security-qualified.

## Coverage and evidence

The auditor enumerates every page of uploaded assets for the exact version tag,
rejecting malformed pages, duplicate IDs, duplicate/case-colliding names, unsafe
paths and incomplete acquisitions. It downloads and hashes **every eligible
payload**. There is no implicit sampling or success for an empty selection.

Default aggregate names are `SHA256SUMS`, `SHA256SUMS.txt`, `checksums.sha256` and
`checksums.txt`. When several are present, every one must be valid, cover every
eligible name, and agree on those names' digests. Use `--checksum-asset NAME`
to select one exact authority, including a nonconventional name. This deliberate
selection is not inferred from a partial filename match or from a sidecar.

Aggregate parsing uses the same `checksum_manifest_normalize` implementation as
local checksum generation and sync. Text/binary SHA256 modes, uppercase digests,
CRLF, comments and a final line without a newline are supported. Malformed or
empty content, HTML responses, duplicate entries, NULs and unsafe paths are
errors. Release members must have flat names. An aggregate entry naming an asset
absent from the release is an error, even when the payload selection is complete.

Checksum aggregates/sidecars and detached signature files are explicitly excluded
from payload coverage. Known build manifests, SBOMs and provenance documents are
also excluded by default. `--include-metadata` adds those documents to the set
that must have checksum entries and be downloaded and hashed; it does not verify
their semantic claims or include checksum/signature cycles. Every exclusion and
its reason is listed in the result. Other text/JSON assets are not silently
excluded simply because of their format.

The audit checks advertised sizes and available GitHub API SHA256 digests as
well as the aggregate. It repeats the complete asset listing and release context
after download, and rehashes the retained payloads and aggregate evidence before
reporting success. Changed release identity, asset inventory or local bytes
produces an error rather than a verified receipt.

A successful receipt includes:

```json
{
  "kind": "dsr-release-checksum-verification",
  "status": "verified",
  "exit_code": 0,
  "verification_policy": "sha256-all-eligible-release-assets",
  "eligible_count": 5,
  "verified_count": 5,
  "inventory_stable": true,
  "authenticated": false,
  "source_verified": false
}
```

`checksums.normalized` contains **only actually verified records**. Unchecked
metadata rows in a downloaded aggregate do not become audited output. The result
binds the exact normalized file's SHA256 and names the evidence directory,
verified files, exclusions and selected checksum assets. Errors report both
actual progress counts and coverage/download failures. A nonzero exit code or
`status: error` must never be interpreted as complete coverage, even if some
payloads were successfully checked before the failure.

## Authentication, limits and trust

Set `GH_TOKEN` or `GITHUB_TOKEN`, or authenticate the GitHub CLI. Token lookup is
explicitly for `github.com`, regardless of `GH_HOST`. Without a token the auditor
can still read public releases. API credentials are not signing credentials:
`authenticated: false` means no trusted publisher signature was checked.

Downloads use the repository's GitHub asset-ID API, not an arbitrary
`browser_download_url` from a metadata field. Requests are GET-only, use HTTPS
for initial and redirected requests, disable curl's rc file, bound redirects,
and supply authorization through stdin rather than command arguments or retained
configuration. Cross-origin redirects do not enable credential forwarding.
Operator proxy and certificate settings remain operator policy.

Default limits are 120 seconds per operation, 2 GiB per payload, 8 GiB total for
selected payloads and checksum aggregates, 8 MiB per metadata/aggregate response,
and 10,000 release assets. Configure `--timeout`, `--max-asset-bytes`, and
`--max-total-bytes` explicitly for larger intended downloads. Listing metadata
is separately bounded per page. The command retains downloaded files, so the
operator must budget storage for the full selected set and failed attempts.
Cancellation terminates the auditor's owned subprocess group and retains failure
evidence; no PID loaded from a receipt is signaled.

Downloaded checksums and API hashes establish byte consistency, **not publisher
authentication, native ABI correctness, source/tag commit verification, or build
provenance**. Use the existing trusted-key integrity/provenance verification for
those independent policies. Local storage and installed executables are trusted;
this is not an adversarial-filesystem sandbox or a power-loss durability claim.

The older `dsr release verify --checksums` path has not yet been routed through
this auditor. Do not infer that its historical spot-check result now provides
these full-coverage guarantees. This entry point is the explicit full audit.

## Regression tests

```bash
bash scripts/tests/test_release_checksums.sh
```

The suite runs the real command, aggregate parser, file hashing and receipt
persistence against explicitly substituted curl/gh transport boundaries. It
covers more than three payloads, later asset-list pages, credentials, malformed
and missing evidence, payload corruption, inventory drift, byte/time limits,
metadata policy and preservation of prior evidence. Those fixture runs are not
live GitHub, TLS/redirect or cryptographic signing qualification.
