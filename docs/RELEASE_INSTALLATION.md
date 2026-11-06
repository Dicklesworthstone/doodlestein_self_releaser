# Install an authenticated application generation

`dsr installer install` installs explicitly selected executables and runtime data from a signed
[release snapshot](RELEASE_SNAPSHOTS.md). It authenticates the whole snapshot,
extracts selected archive members, verifies a complete installation generation,
and switches one managed `current` pointer. It does not publish, build,
run a downloaded executable, invoke an installation hook, or modify shell startup
files. This is an explicit consumer command, not a silent change to the generated
curl-bash installers or ordinary `dsr release` policy.

For a distributable per-release script with embedded engines, recipes and trust
policy, use `dsr installer generate-release` as described in
[generated release installers](GENERATED_RELEASE_INSTALLERS.md). Consumers can
then use online or offline installation without a DSR checkout or repeated
policy/key arguments.

## Download and install in one invocation

Use `--fetch` instead of `--snapshot DIR` to fetch the exact selected signed
release into private staging and install from those authenticated bytes:

```bash
dsr installer install --fetch \
  --recipe /srv/policies/demo-install.json --prefix /home/alice/.local/demo \
  --repo OWNER/REPO --tag v1.2.3 --sha "$REVIEWED_SOURCE_COMMIT" \
  --builder "$TRUSTED_BUILDER_ID" --public-key /srv/keys/release.pub \
  --targets linux/amd64,darwin/arm64,windows/arm64
```

The same explicit source, signer, builder and complete target-matrix policy is
required. Online mode runs the existing full `fetch-release` path, then performs
the same offline snapshot authentication and generation installation used by
`--snapshot`. The two receipts must agree on the exact snapshot, statement,
signature, build-manifest and invocation identities. No second download selects
different executable bytes after verification. The fetch needs the documented
GitHub transport dependencies and credentials; it is read-only and never creates
or promotes a release. There is no fallback to unsigned assets or source builds.

Online installation requires a published release by default. Add `--allow-draft`
to explicitly install an authenticated draft; this flag is valid only with
`--fetch`. Draft rejection occurs after authentication but before archive
extraction or installation-state changes. Prerelease tags remain explicit
caller selections. Offline mode makes no current-publication claim and does not
trust the historical download receipt to decide whether a release is public.

`--dry-run --fetch` **does use the network** and authenticates/downloads the
complete release, then extracts and verifies the installation generation without
creating a prefix, lock or active pointer. Private fetch staging is cleaned on
handled exits. `--timeout` also bounds the entire fetch helper, with the same
owned-process cancellation and cleanup limits as verification/extraction. A
failed fetch cannot alter the active generation.

Add `--download-jobs N` with `--fetch` to download up to **1..32** payload assets
at once; the default remains **1**. The shared fetch engine authenticates the
proof and validates the entire asset inventory before starting its bounded
worker pool. Changing this scheduling limit changes neither trust policy nor
generation identity. The same whole-release authentication and cancellation
rules still apply. `--download-jobs` is rejected with `--snapshot`.

### Retain downloads across attempts

Add `--download-cache DIR` to keep the exact snapshot and resume its acquisition
after a failed connection, timeout or interrupted installation:

```bash
dsr installer install --fetch \
  --download-cache /home/alice/.cache/dsr/demo-v1.2.3 --download-jobs 4 \
  --recipe /srv/policies/demo-install.json --prefix /home/alice/.local/demo \
  --repo OWNER/REPO --tag v1.2.3 --sha "$REVIEWED_SOURCE_COMMIT" \
  --builder "$TRUSTED_BUILDER_ID" --public-key /srv/keys/release.pub \
  --targets linux/amd64,darwin/arm64,windows/arm64
```

`DIR` is one exact retained snapshot destination, with an existing parent. It
is not a root under which the installer discovers or selects a release. On the
first attempt select a new path; the shared fetch engine manages `DIR.partial`
for completed payloads and `DIR.lock` for exclusive acquisition. All three
paths must be canonical absolute paths without symlinks and must not overlap
the installation prefix or its lock, recipe, public key or release contract.
New cache storage is private. The installer does not delete or repair an
existing cache or substitute a new release under the same path.

Repeat the command with the same independent release policy and key bytes.
The existing [resumable fetch](RELEASE_SNAPSHOTS.md#resume-an-interrupted-download)
authenticates the current remote proof, checks the frozen release and complete
inventory, and rehashes every retained payload before requesting missing ones.
Only complete, verified payloads survive an interrupted transfer; a partially
downloaded individual file starts again from byte zero. Changed policy, key,
release identity or inventory, and corrupt or unrelated retained files, refuse
reuse. Choose another new destination for a different release generation;
`--replace` only authorizes changing the installed generation.

A completed retry still checks current GitHub state and fetches the small
statement/signature pair. It never treats a saved success receipt as
authentication or silently switches to offline mode after a network failure.
Installation then performs the same full offline authentication and private
payload staging as any other fetch. A new prefix or download worker count does
not change the cache's release selection or the authenticated generation.

With an explicitly selected cache, **`--dry-run` can create and update download
storage**, including its checkpoint and lock. It still creates no installation
prefix, installation lock or active pointer. Completed downloads remain useful
for the subsequent real install. Without `--download-cache`, fetch staging
remains temporary and each retry downloads again.

The online result's `download` object adds `cache`, `resumable: true`, and
`acquisition.reused_payloads` / `acquisition.downloaded_payloads`. Reused counts
describe locally reauthenticated payloads, not fresh HTTP body reads. Cache
paths and acquisition counts are excluded from generation identity. To use a
completed cache deliberately without network access, pass its exact `DIR` as
`--snapshot DIR`; `--download-cache` is rejected with `--snapshot`.

The result includes a `download` observation for online mode, without private
temporary paths or credentials. `remote_current` remains `false`: an observation
made during fetch is not a continuing promise that GitHub state has not changed.
Re-downloading the same release or selecting an equivalent offline snapshot
produces the same generation identity; transport receipts are not part of that
identity. The separate `fetch-release` command can also retain a snapshot without
installing it.

The public command delegates to the same strict `src/release_install.sh` engine.
Use `dsr installer install --help` for its complete argument list. It accepts no
release-discovery or source-build fallback options. Global `dsr --dry-run` and
installation `--dry-run` both authenticate and extract without activating a
generation; online mode still downloads the complete snapshot.

With `dsr --json installer install ...`, stdout contains one standard DSR
envelope. `details` retains the engine's complete result, including
`authenticated`, `status`, `generation`, selected files, and `activated` when
activation was attempted. The envelope's exit code agrees with the process and
the engine. `details.action` identifies `install`. A signal to the public DSR
process is forwarded to the engine, which finishes its cleanup and returns its
actual activation state. If activation already completed, that committed result
remains authoritative. Without `--json`, the engine's JSON receipt is printed
directly. `--help` prints usage, or one help envelope in JSON mode.

Run `bash scripts/tests/test_release_install_fetch.sh` for the full fetch,
offline authentication and installation handoff. GitHub transport and Minisign
are explicit fixtures, not live HTTP or native cryptographic acceptance tests.

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
fields, duplicate JSON keys, null lists, empty executable selections and ambiguous names
are errors. Member paths are limited to 1024 characters.

The recipe's target must equal the local host, and every executable artifact must
be signed for that target. Supported pairs are Linux on amd64, arm64, 386 or
armv7; macOS on amd64 or arm64; and FreeBSD on amd64. Windows payloads may be present in a full
release snapshot but are not installed on POSIX hosts. This check authenticates
the producer's platform claim; it is not independent executable-format or loader
qualification. The installer does not execute a candidate to discover its platform.

Review a recipe without downloading or authenticating a release:

```bash
dsr --json installer describe-recipe --recipe /srv/policies/demo-install.json
```

Add both `--release-contract FILE` and `--targets LIST` to validate it against an
independent complete release contract. This command uses the installation
engine's normalizer and always reports `authenticated: false`; a valid recipe
does not establish that the named release assets exist or are signed.

## Select runtime data

Applications that need schemas, templates, model metadata, notices or other
runtime files can add an explicit `files` list to the same recipe:

```json
{
  "schema_version": 1,
  "target": "linux/amd64",
  "executables": [
    {"name": "demo", "artifact": "demo-linux.tar.gz", "member": "bin/demo"}
  ],
  "files": [
    {"path": "share/demo/runtime.json", "artifact": "runtime.json"},
    {"path": "share/demo/docs/help.txt", "artifact": "demo-linux.tar.gz", "member": "docs/help.txt"}
  ]
}
```

Each `path` is a destination relative to the generation root and must begin
with exactly `share/`. The same safe components and 1024-character limit used
for archive members apply. There are at most 256 file selections. Duplicate
destinations, case aliases in any path component, file/directory prefix
collisions, traversal and unknown fields are rejected before acquisition. There
is no wildcard, directory-copy, destination outside `share/`, or mode override.
An absent or empty `files` list preserves the executable-only recipe and
generation identity; a null list is invalid.

An exact signed payload may supply a raw data file, or a safe archive `member`
may supply it. Its signed target must be either the recipe's physical platform
or `additional`, the release-wide shared asset namespace. A shared asset cannot
supply an executable or satisfy the platform matrix. When the recipe has an
explicit `target_triple`, platform-owned data must have that same signed
compiler identity. Shared data remains independent of the compiler variant and
must have no `target_triple`. An independently supplied release contract is also
checked against these selections before network acquisition.

Data files always receive mode **0644**, even when an archive marks the member
executable. Their required directories receive mode **0755**. Empty archive
members are valid data; executable members must remain nonempty, and existing
whole-snapshot subject admission still applies to raw assets. An archive used
by both executable and data selections is authenticated and extracted once.
No file is inferred from its extension or copied merely because it is present
beside a selected binary.

The application must know how to locate its data under the generation's
`share/` tree. The installer does not inject environment variables or rewrite
application configuration. Treat these installed files as immutable release
content; keep mutable application state outside the managed generations.

## Authenticate and install

First fetch a complete snapshot using the independent trust policy documented in
[RELEASE_SNAPSHOTS.md](RELEASE_SNAPSHOTS.md). The destination prefix below must
have an existing parent and be new, empty, or already owned by this installer.
It must not overlap the snapshot, recipe or public key.

```bash
dsr installer install \
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
No archive or raw payload is executed. Executables receive mode **0755** and
runtime data receives **0644**, without setuid/setgid or unusual write permissions.

The result names both `bin_dir` (the active path) and `generation_bin_dir` (the
immutable-version path). Add the active directory to PATH explicitly, for example:

```bash
export PATH="/home/alice/.local/demo/current/bin:$PATH"
```

The installer never creates or replaces unrelated files in `~/.local/bin`.
For a recipe with runtime files, the result also includes their selected paths,
signed ownership, hashes, sizes and modes in `files`, plus `share_dir` (the active
path) and `generation_share_dir` (the immutable-version path).
Its managed prefix looks like:

```text
demo.lock                            # Adjacent cooperating-writer lock

demo/
  installation.json                  # Repository and host-target ownership
  generations/
    GENERATION_SHA256/
      bin/                           # Exactly the selected executable names
      share/                         # Only when runtime files are selected
        demo/runtime.json            # Explicit destination, fixed mode 0644
        demo/docs/help.txt
      receipt.json                   # Recipe, signer, source and installed hashes
      release.intoto.jsonl
      release.intoto.jsonl.minisig
  current -> generations/GENERATION_SHA256
```

The generation identity covers the canonical installation receipt, including
the exact snapshot/proof identity, selected signing key, recipe, source/build
pins and every selected executable/data path, hash, size and mode. Required data
directories are derived exactly from those paths. Input paths and current time do not select a
new generation. Each retained proof is checked against the newly authenticated
snapshot on reuse; a saved `authenticated` field alone is never sufficient.
No private key, GitHub credential or private producer manifest is installed.

## Upgrades, retries and rollback

Changing an active installation requires explicit `--replace`. The new
executable and runtime-data set is fully prepared and verified first. One same-filesystem
symlink replacement activates it; the installer does not overwrite each live
binary in turn. A failure before activation leaves the old `current` pointer
unchanged. The failure JSON reports whether activation actually occurred, so a
handled signal after the pointer switch is not represented as a pre-activation
failure. Old generations are retained and are never pruned automatically.

Repeating the identical command reauthenticates the snapshot, reconstructs the
expected generation and verifies its retained binaries, data and proofs. The
complete `share/` file and directory namespace must match: missing or extra
files, undeclared empty directories, links, changed bytes and changed modes are
refused before reuse or activation. It reuses an
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
version across multiple launches or data reads should use the returned
`generation_bin_dir` and `generation_share_dir` from the same result. Repeated
lookups through `current` can straddle a pointer switch.
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

Run `bash scripts/tests/test_installer_release_cli.sh` for the public command
path. It uses the actual DSR executable, generator, archive handling and
installation engine with real Minisign signatures over small private fixtures.
It verifies dry-run output/lock/prefix preservation, standalone inspection,
complete executable/data activation, retry, replacement, rollback, exact
ownership and compiler selection, and refusal of signed-subject corruption.
Cancellation is tested through the public PID before activation and through an
explicit result-delivery boundary after the real engine has already committed.
No network, compiler or installed payload is executed by this suite. The
existing legacy installer commands remain separate regression controls.

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
