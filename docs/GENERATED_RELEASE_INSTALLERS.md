# Generate a standalone authenticated release installer

The authenticated installation engine can generate one distributable `install.sh`
for a reviewed release. Consumers need no DSR checkout, policy file or separate
public-key file: the script embeds the exact verifier, transport and installation
engines together with the independently selected policy. It downloads no new
installer code at runtime. The release payloads are still authenticated by the
embedded policy before the complete executable generation is activated.

This is an explicit per-release generator, exposed through
`src/release_install.sh generate-installer`. It does not silently change the
older `install_gen_create` templates, their version discovery, or source-build
fallback. Those configurations do not supply the independent source/build and
complete-matrix policy this installer requires.

## Reviewed release policy

Create a JSON policy with exactly these required fields:

```json
{
  "schema_version": 1,
  "repo": "owner/demo",
  "tag": "v1.2.3",
  "source_sha": "<reviewed nonzero full 40-character source commit>",
  "builder": "https://example.org/builders/dsr-production",
  "targets": ["linux/amd64", "darwin/arm64", "windows/arm64"],
  "recipes": [
    {
      "schema_version": 1,
      "target": "linux/amd64",
      "executables": [
        {"name": "demo", "artifact": "demo-linux.tar.gz", "member": "demo"},
        {"name": "helper", "artifact": "demo-linux.tar.gz", "member": "helper"},
        {"name": "worker", "artifact": "worker-linux"}
      ]
    },
    {
      "schema_version": 1,
      "target": "darwin/arm64",
      "executables": [
        {"name": "demo", "artifact": "demo-darwin.tar.gz", "member": "demo"},
        {"name": "helper", "artifact": "demo-darwin.tar.gz", "member": "helper"},
        {"name": "worker", "artifact": "worker-darwin"}
      ]
    }
  ]
}
```

Replace the deliberately invalid source placeholder and example identities with
reviewed release values. Optional `statement_sha256`, `manifest_sha256` and
`invocation_id` restrict the accepted signed build further. They are selected by
the publisher, not inferred from the downloaded proof. Unknown fields, duplicate
JSON keys, null lists, invalid pins, duplicate targets and unsafe or colliding
executable selections fail generation.

`targets` is the **complete signed release matrix**, including platforms that
will not be installed on this machine. Supply exactly one installation recipe
for every declared POSIX target. Windows payloads are authenticated as part of
the snapshot but this generator does not provide Windows installation. At least
one supported POSIX recipe is required. Each recipe uses the exact same
normalizer as [authenticated installation](RELEASE_INSTALLATION.md); raw/archive
compatibility and actual signed artifact membership are checked during install.

## Generate and inspect

```bash
bash src/release_install.sh generate-installer \
  --policy /srv/policies/demo-release.json \
  --public-key /srv/keys/release.pub \
  --output /srv/installers/demo-v1.2.3.sh

bash /srv/installers/demo-v1.2.3.sh --inspect
```

The generator reads the existing DSR installation's `release_install.sh`,
`slsa_remote.sh`, `slsa.sh`, `packaging.sh`, `sbom_release.sh`, `sbom.sh`, and
`github.sh`. It snapshots and hashes their complete source files, validates each
recipe using that captured installation engine, checks generated Python/Bash
syntax, and refuses input drift. All policy and engine data are base64-encoded
JSON, not shell substitutions or executable policy text. Literal metacharacters
in a builder identity remain data.

Generation performs no GitHub requests, signing, snapshot authentication or
payload execution. The result reports `authenticated: false`, the generated
file hash, canonical policy hash and embedded engine hashes. `--inspect` prints
the embedded policy, public key and engine hashes without installing, using the
network or claiming authentication. It cannot be combined with install options.

Output paths must be canonical absolute paths, with an existing parent and no
symlink components. Generation uses an adjacent cooperating-writer lock and
same-filesystem staging. The identical canonical policy and engine bytes reuse
an existing executable installer without changing its inode. A different script
requires explicit generator `--replace`; no source module, key or policy file may
be selected as its output. Input paths and timestamps are not embedded in the
identity. Public-key comments are normalized; the key token remains exact.

## Consumers: one file, one installation command

Distribute the generated script through a trusted channel. After obtaining it:

```bash
bash demo-v1.2.3.sh --prefix /home/alice/.local/demo
```

It also supports streamed execution, such as `cat demo-v1.2.3.sh | bash -s --
--prefix /home/alice/.local/demo`, or the equivalent trusted HTTPS download
pipeline. The selected prefix's parent must already exist. The generated script
selects the local host recipe automatically and installs all its selected
companions. Its runtime options are deliberately limited to:

- `--prefix DIR`, `--snapshot DIR`, and `--timeout SECONDS`.
- `--replace`, `--allow-draft`, `--dry-run`, `--inspect`, and `--help`.

The default is online `--fetch` behavior from the existing engine: authenticate
and download the complete selected release, reauthenticate the same snapshot
locally, extract the selected payloads, and activate one complete generation.
There is no runtime override for repository, version, source commit, builder,
key, target matrix, recipe, or build pins. A failed download or signature check
cannot fall back to unsigned binaries, a different release or source execution.

Use `--snapshot /absolute/snapshot` for offline operation. This option is exclusive
with draft consent and never requests network access, even to repair missing
payloads. Online mode requires a published release unless `--allow-draft` is
explicitly given. Online `--dry-run` still downloads and authenticates the full
release, but creates no installation prefix, persistent installation lock or
active pointer. `remote_current: false` retains the existing truthful freshness
contract; any online result includes a historical download observation instead.

The generated script needs Python 3 with POSIX support, Bash 4+, jq, Minisign and
the selected archive readers. Online operation additionally needs the existing
GitHub transport dependencies, `flock`, and a usable GitHub credential. No token
is embedded in the generated script. Offline operation needs neither `gh` nor a
GitHub credential. macOS hosts need a suitable Bash and, for online mode, flock;
the generator does not install dependencies or change shell startup files.

## Upgrade, rollback and trust boundaries

For a new release, generate a new script with its new reviewed policy. Run that
script with runtime `--replace` to permit changing an existing managed prefix.
The existing installation engine authenticates and stages every executable
before switching `current`; old generations remain available. To roll back,
run the original generated script with its matching snapshot or release and
`--replace`. Rollback is explicit and reauthenticated, not an automatic policy.
Online re-download and equivalent offline installation select the same generation.

Cancellation is forwarded to the installation engine, which owns its fetch and
archive-helper processes and reports whether activation happened. The wrapper
preserves that result, including a post-activation failure; an unavailable result
after launching the engine reports `activated: null`, not a false assurance that
nothing changed. Runtime temporary engine files are private and cleaned after
the child finishes. Existing limits on uninterruptible kernel I/O, escaped
process sessions and power-loss durability remain unchanged.

**Trust the generated script itself before executing it.** Embedded engine hashes
and the bundle checksum detect accidental damage; they cannot authenticate a
malicious bootstrap that changes both code and checksums. The embedded public
key authenticates release payloads only after the bootstrap is trusted. Use a
trusted distribution channel and an independently verified script checksum or
signature where appropriate. Generation does not sign the script or establish
that a producer's compilation claims are true. Existing installers do not
automatically adopt future engine fixes, key revocation or chronological
anti-rollback policy: regenerate and redistribute under the intended policy.

## Tests

Run `bash scripts/tests/test_generated_release_installer.sh`. The suite generates
and executes the actual standalone script, removes the original DSR/policy/key
paths, exercises streamed online and offline installation, validates frozen trust
options, preserves active files on failures and cancellation, and upgrades and
rolls back a complete native executable set. It checks canonical regeneration,
unsafe policy rejection and literal builder identities. Only the tests execute
installed payloads; they compile small C fixtures when `cc` is available.

The generator, complete SLSA/snapshot verifiers, archive helpers and installation
engine are real. GitHub transport and Minisign are explicit file/hash fixtures;
this is not live HTTP, native Ed25519, Rust release, Windows or macOS acceptance.
