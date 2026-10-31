# Explicit SBOM release inputs

The standalone `sbom.sh artifacts` and `verify-artifacts` commands accept
`--selection FILE`. Select every intended release payload by basename and
SHA256, including licenses and shared JSON data which ordinary scanner discovery
excludes. This is a caller-selected byte inventory, not a signed build claim.

```json
{"schema_version":1,"artifacts":[
  {"name":"tool-linux","sha256":"<64 lowercase hex characters>"},
  {"name":"LICENSE","sha256":"<64 lowercase hex characters>"}
]}
```

```bash
bash src/sbom.sh artifacts /srv/release/artifacts \
  --selection /srv/policy/inputs.json --output-dir /srv/release/sboms
bash src/sbom.sh verify-artifacts /srv/release/artifacts \
  --selection /srv/policy/inputs.json --output-dir /srv/release/sboms
bash src/sbom_release.sh publish /srv/release/artifacts \
  --repo owner/tool --tag v1.2.3 --selection /srv/policy/inputs.json \
  --output-dir /srv/release/sboms
```

Both SPDX and CycloneDX batch modes scan each selected file through the existing
private-snapshot scanner and bind its exact resulting document. A selection
cannot conceal an unselected binary. Unselected metadata remains excluded; no
private manifest, key or state file is automatically selected.

The selection must be one JSON object, at most 1 MiB, with 1..256 unique records.
Names use 1..128 ASCII letters, digits, dots, underscores, pluses or hyphens,
begin with a letter or digit, and cannot contain `..`. Duplicate keys, case
collisions, unsafe names, unknown fields, bad hashes and linked/special selection
files are refused. Selected payloads must be regular non-symlink files with the
exact hashes. Payload/derived-document/aggregate name collisions are refused.

The exact chosen selection bytes are checked during scanning and before success.
Array/key order is normalized across invocations. Completed scan pairs survive
an interruption; an identical retry verifies them instead of rescanning. Changed
payloads, a reduced selection or policy changes cannot reuse a frozen plan.
Existing output is never overwritten to accept a conflicting selection.

New plans and aggregate receipts identify `explicit-artifacts-v1`. Default
commands still use `top-level-artifacts-v1`; default discovery cannot silently
adopt an explicitly selected aggregate. The public SBOMs remain unauthenticated
scanner observations. Signature and complete-build qualification are separate.

Publication accepts the same `--selection FILE`. It verifies the complete local
inventory, pins the selection bytes, and rechecks them before and after each
upload. A lost upload acknowledgment can be reconciled by retrying the same
selection; existing document and inventory bytes are verified before reuse.
Independent remote verification still requires the caller-selected SBOM manifest
SHA-256. An explicit manifest's declared data/license files must actually exist
in the observed remote inventory and pass the same size, digest and byte checks
as executable payloads. Missing selected metadata, unexpected binaries and
changed assets remain errors.

Python 3 is required only for explicit selection parsing (standard library,
without site initialization). Syft is still required to create new documents;
verification and complete retries need no scanner. Run
`bash scripts/tests/test_sbom_selection.sh`. Tests execute the complete CLI,
real hashing, staging, receipts, publication and remote verification with explicit
Syft and GitHub transport fixtures. They do not qualify native Syft package
recognition or perform live publication.
