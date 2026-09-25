# Install a complete authenticated executable set

`src/release_install.sh` installs explicitly selected executables from a signed
[release snapshot](RELEASE_SNAPSHOTS.md). It authenticates the whole snapshot,
extracts selected archive members, verifies a complete installation generation,
and switches one managed `current` pointer. It does not download, publish, build,
run a downloaded executable, invoke an installation hook, or modify shell startup
files. This is an explicit consumer command, not a silent change to the generated
curl-bash installers or ordinary `dsr release` policy.

## Select the executables

Create a reviewed installation recipe:

```json
{
  "schema_version": 1,
  "target": "linux/amd64",
  "executables": [
    {"name": "demo", "artifact": "demo-linux.tar.gz", "member": "demo"},
    {"name": "helper", "artifact": "demo-linux.tar.gz", "member": "helper"},
    {"name": "worker", "artifact": "worker-linux"}
  ]
}
```

`artifact` is an exact signed payload basename, not a URL or filesystem path.
Archive selections require a safe relative `member`; raw `binary`/`none` payloads
forbid it. A single archive can supply several companion binaries. Safe nested
members such as `bin/demo` are supported. Only the 1–64 explicitly selected names
are installed; the recipe is not a wildcard inventory. Names are unique ignoring
ASCII case, are limited to 128 characters, and cannot contain traversal. Unknown
fields, duplicate JSON keys, null lists, empty selections and ambiguous names
are errors. Member paths are limited to 1024 characters.

The recipe's target must equal the local host, and every selected artifact must
be signed for that target. The current installer supports Linux and macOS on
recognized amd64, arm64 or 386 hosts. Windows payloads may be present in a full
release snapshot but are not installed on POSIX hosts. This check authenticates
the producer's platform claim; it is not independent executable-format or loader
qualification. The installer does not execute a candidate to discover its platform.

## Authenticate and install

First fetch a complete snapshot using the independent trust policy documented in
[RELEASE_SNAPSHOTS.md](RELEASE_SNAPSHOTS.md). The destination prefix below must
have an existing parent and be new, empty, or already owned by this installer.
It must not overlap the snapshot, recipe or public key.

```bash
bash src/release_install.sh \
  --snapshot /srv/downloads/demo-v1.2.3 \
  --recipe /srv/policies/demo-install.json \
  --prefix /home/alice/.local/demo \
  --repo OWNER/REPO --tag v1.2.3 --sha "$REVIEWED_SOURCE_COMMIT" \
  --builder "$TRUSTED_BUILDER_ID" --public-key /srv/keys/release.pub \
  --targets linux/amd64,darwin/arm64,windows/arm64
```

Use the actual repository, full nonzero source commit, independently trusted
Minisign key, literal builder identity and **complete release target matrix**.
The target matrix is not just the local install target. The installer delegates
to the same full offline snapshot verifier: a missing or corrupt companion,
alias or different-platform payload blocks installation. The historical
`download.json` status and any embedded public key cannot authorize an install.
Optional `--statement-sha256`, `--manifest-sha256` and `--invocation-id` select an
exact statement or build using independently obtained pins.

After successful authentication, selected payloads and the exact signed proof
pair are copied into private staging and rehashed against the verified selection.
Archive extraction uses the existing packaging validator: declared compression
must match, and traversal, links, special files and duplicate members are refused.
No archive or raw payload is executed. The selected output files are installed
with mode **0755**, without setuid/setgid or unusual write permissions.

The result names both `bin_dir` (the active path) and `generation_bin_dir` (the
immutable-version path). Add the active directory to PATH explicitly, for example:

```bash
export PATH="/home/alice/.local/demo/current/bin:$PATH"
```

The installer never creates or replaces unrelated files in `~/.local/bin`.
Its managed prefix looks like:

```text
demo.lock                            # Adjacent cooperating-writer lock

demo/
  installation.json                  # Repository and host-target ownership
  generations/
    GENERATION_SHA256/
      bin/                           # Exactly the selected executable names
      receipt.json                   # Recipe, signer, source and binary hashes
      release.intoto.jsonl
      release.intoto.jsonl.minisig
  current -> generations/GENERATION_SHA256
```

The generation identity covers the canonical installation receipt, including
the exact snapshot/proof identity, selected signing key, recipe, source/build
pins and extracted binary hashes. Input paths and current time do not select a
new generation. Each retained proof is checked against the newly authenticated
snapshot on reuse; a saved `authenticated` field alone is never sufficient.
No private key, GitHub credential or private producer manifest is installed.

## Upgrades, retries and rollback

Changing an active installation requires explicit `--replace`. The new
executable set is fully prepared and verified first. One same-filesystem
symlink replacement activates it; the installer does not overwrite each live
binary in turn. A failure before activation leaves the old `current` pointer
unchanged. The failure JSON reports whether activation actually occurred, so a
handled signal after the pointer switch is not represented as a pre-activation
failure. Old generations are retained and are never pruned automatically.

Repeating the identical command reauthenticates the snapshot, reconstructs the
expected generation and verifies its retained binaries and proofs. It reuses an
identical generation without changing its file or pointer identities. Changed
or corrupted retained files are conflicts, not permission to silently repair
them. An incomplete copy or extraction is not an active installation. A complete
but inactive generation left before activation can be verified and reused on retry.

To roll back, select the original snapshot and recipe with their original trust
policy and add `--replace`. This repeats authentication rather than trusting an
old receipt. No automatic latest-version, revocation or chronological anti-rollback
policy is inferred. A valid signed older version is installable when explicitly
selected. Offline results always report **`remote_current: false`**: the installer
does not claim the release is still public, its tag is unchanged, or the signer
has not since been revoked.

A pointer switch is not a transaction spanning separate pathname lookups. Two
process launches straddling an upgrade can observe different generations, and
already-running processes continue independently. Applications needing one fixed
version across multiple launches should use the returned `generation_bin_dir`.
The prefix is single-user, trusted local installation storage, not a sandbox
against a privileged concurrent filesystem writer.

## Planning, cancellation and dependencies

Add `--dry-run` to perform real snapshot authentication, extraction and complete
staging validation without creating the prefix, generation or persistent lock.
It is not a network freshness check and does not claim an executable self-test.

`--timeout SECONDS` bounds each verification or archive-extraction subprocess;
the default is 900 seconds, with an accepted range of 1–86400. Cancellation and
timeout stop the invocation's owned process groups, including ordinary helper
descendants, before private staging is removed. Up to five seconds is allowed
for cleanup before force termination. No process ID from a saved receipt is
signalled. The timeout is not a whole-install deadline or a guarantee against
uninterruptible kernel I/O or a subprocess escaping into another session.

Requirements are Python 3 with POSIX `fcntl`, Bash 4+, jq, Minisign and the archive
reader appropriate for the selected format: tar/gzip, tar/xz or unzip. The
snapshot and SLSA modules must be installed beside this module, together with
`packaging.sh`. All selected paths are canonical absolute paths without symlink
components; the managed `current` pointer is the deliberate output exception.
The output parent must have room for authenticated copies, extraction, retained
generations and temporary staging. There is no streaming extraction quota or
power-loss transaction guarantee.

The sourceable API is `release_install` with the same arguments. After Python
starts, ordinary failures emit one JSON error object and a nonzero exit: `2`
for managed-state conflicts, `3` for dependencies/unsupported hosts, `4` for
invalid selections, `5` for interruption, and `7` for local evidence drift.
Snapshot/cryptographic failures preserve their underlying nonzero status.
Missing Python itself returns dependency exit `3` before the JSON engine starts.

## Validation

Run `bash scripts/tests/test_release_install.sh`. It starts with the actual
snapshot fetch/verification flow, then executes the real installer CLI and
archive validators. Tests cover multi-binary archives and raw executables,
all three archive formats, byte/inode-preserving retries, explicit upgrade and
rollback, incomplete companions, corrupted unused targets, false receipt claims,
unsafe signed archives, input drift, unmanaged prefixes, lock contention,
extraction deadlines and cancellation. When `cc` is available the test compiles
and executes a tiny native C fixture **after** installation; otherwise it uses
a shell executable. The installer never executes either fixture itself.

Minisign and GitHub transport are explicit hash-bound fixtures, not native
Ed25519 or live network acceptance. macOS execution and Windows installation are
not established by this Linux integration suite. Native Rust/Windows release
qualification and toolchain attestation remain separate work.
