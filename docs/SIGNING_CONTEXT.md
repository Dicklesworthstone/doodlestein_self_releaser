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

## Password input for encrypted keys

Every call that creates a signature owns its password input independently of
the caller's stdin. This includes strict primary, checksum, and manifest
inventory loops as well as ordinary batch signing. A protected key must not
consume the next artifact record as its password.

For automation, `DSR_MINISIGN_PASSWORD_FILE` names a caller-owned regular file
with one hard link, no final symlink, and no group/other permission bits.
The Python 3 provider opens it without following a symlink or blocking on a
special file, validates the descriptor against the pathname and checks its
metadata before and after reading. It accepts one password line with an
optional LF or CRLF terminator, at most 1022 password bytes, and no NUL or
embedded line breaks. An explicit blank line is allowed; an empty file is not.
Frozen bytes feed a private pipe to Minisign. No shell variable, argument,
environment value, log, or temporary file contains the password. The original
password file and private key are read-only inputs.

Without this provider, an interactive signer opens its controlling terminal
separately from the inventory stream. Noninteractive invocations use closed
input and therefore require the provider for encrypted keys. Existing valid
signatures remain reusable without credentials; wrong passwords cannot publish
a new signature. Exact input, pinned public key, manifest snapshot, and atomic
sidecar publication checks remain the same.

## Verification

Run `bash scripts/tests/test_signing_context.sh`. The key-free tests exercise the
full production signing module with small byte fixtures, not simulated native
executables. They reproduce the two-predicate counterexample and test frozen
context refusal, explicit-root admission, directory/path failures, shell state
isolation, and cleanup. Four additional tests use genuine Minisign for staged
manifest mutation/disappearance, retained-signature mutation, and unchanged
batch signing/verification/resume; these explicitly skip without Minisign.

Run `bash scripts/tests/test_signing.sh --encrypted-only` for real encrypted-key
coverage, or omit the flag to include the existing signing regression suite.
The encrypted checks cover inventory stdin, batch retries, credential-free
signature reuse, incorrect and unsafe password files, isolated Python startup,
and a real controlling-terminal session. They preserve and independently verify
the signed bytes; no GitHub publication is performed.
