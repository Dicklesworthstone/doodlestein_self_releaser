# Frozen manifest context during signing

The ordinary collector and signing inventory predicate prevent incomplete raw
artifact lists (issue #45). A predicate evaluated twice is not a frozen context:
two individually consistent manifests may still disagree about source commit,
targets, filenames, or which payloads belong to the release.

`signing_sign` and `signing_sign_batch` now retain the exact names and SHA-256
hashes of all adjacent non-hidden `*-manifest.json` files before key use. The
snapshot is deterministic across repeated input paths and directory traversal
order. A later check must find the same manifest set and bytes, and each
manifest must still match its actual payload/checksum inventory.

This refuses manifest removal, rename, addition, source/target changes, and a
consistent subset formed by removing an unselected payload together with its
manifest row. A vanished manifest cannot turn a release signing attempt into
unconstrained generic signing. A failed directory traversal is an error, never
an empty manifest set. Generic signing in a directory without release manifests
continues to work and does not require jq merely for an empty snapshot.

Batch signing checks the original context after all signatures are staged but
before exposing any new sidecar, and again before returning success. Retained
signature verification follows the same context checks. The single-file API
checks its context before successful return on both new and retained signatures.
As with existing signing races, a late failure can leave an already-published
sidecar in place; shared destination paths are not unsafely unlinked. This is
not a transaction against a non-cooperating writer or a proof of native compiler
provenance. Consumer `signing_verify` and `signing_verify_exact` still authenticate
bytes without requiring an adjacent payload directory.

The read-only API `signing_validate_release_inventory MANIFEST DIRECTORY
[EXPECTED_SHA256]` admits an explicitly selected manifest, even with a
nonstandard filename or separate storage directory. Supplying a digest prevents
reselecting different JSON after a caller freezes its release plan. It needs no
private signing key. The prepared ordinary command follow-up uses this API, but
that command patch must be activated separately; adding the API alone does not
make unsigned publication or fallback's skipped-batch path invoke it.

Run `bash scripts/tests/test_signing_context.sh`. The key-free tests exercise the
full production signing module with small byte fixtures, not simulated native
executables. They reproduce the two-predicate counterexample and test frozen
context refusal, explicit-root admission, directory/path failures, shell state
isolation, and cleanup. Four additional tests use genuine Minisign for staged
manifest mutation/disappearance, retained-signature mutation, and unchanged
batch signing/verification/resume; these explicitly skip without Minisign.
