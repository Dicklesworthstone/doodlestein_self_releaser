# Generate a standalone authenticated release installer

The authenticated installation engine can generate one distributable `install.sh`
for a reviewed release. Consumers need no DSR checkout, policy file or separate
public-key file: the script embeds the exact verifier, transport and installation
engines together with the independently selected policy. It downloads no new
installer code at runtime. The release payloads are still authenticated by the
embedded policy before the complete executable and runtime-data generation is activated.

This is an explicit per-release generator, exposed through
`dsr installer generate-release`. It does not silently change the
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
executable or runtime-file selections fail generation.

`targets` is the **complete signed release matrix**, including platforms that
will not be installed on this machine. Supply at least one installation recipe
for every declared POSIX target, with at most 64 recipes overall. A platform
with several recipes must give each a distinct explicit `target_triple`; an
untyped recipe cannot serve as a fallback beside typed recipes. Windows payloads are authenticated as part of
the snapshot but this generator does not provide Windows installation. At least
one supported POSIX recipe is required. Each recipe uses the exact same
normalizer as [authenticated installation](RELEASE_INSTALLATION.md); raw/archive
compatibility and actual signed artifact membership are checked during install.

## Include authenticated runtime files

Each recipe may include an optional `files` list alongside its `executables`:

```json
"files": [
  {"path": "share/demo/runtime.json", "artifact": "runtime.json"},
  {"path": "share/demo/docs/help.txt", "artifact": "demo-linux.tar.gz", "member": "docs/help.txt"}
]
```

The first file can come from a signed release-wide `additional` asset; the
second comes from an exact member of the selected platform archive. Both are
installed with fixed mode **0644**, and their required `share/` directories
receive **0755**. Executables keep mode **0755**. Select each file explicitly;
the installer does not copy unlisted archive content, generate configuration,
run hooks or provide a runtime destination override.

Every destination is a safe relative path beneath `share/`, with at most 256
files per recipe. The captured installation engine rejects traversal, duplicate
or case-aliased paths, file/directory collisions, unknown fields and mode
overrides during generation. Empty archive members are permitted as data;
executables must remain nonempty. Omitting `files` or supplying `files: []`
preserves the original executable-only policy and generation identity. A null
list is invalid. See [runtime data selections](RELEASE_INSTALLATION.md#select-runtime-data)
for the complete recipe rules.

The embedded policy fixes these selections for each platform and compiler
variant. `--inspect` shows them for review. Installation authenticates the
whole signed snapshot, including unselected shared assets and other platforms,
before staging any generation. A shared asset can supply data but cannot stand
in for a platform executable. An embedded independent release contract is
checked against data selections during generation and again during installation.

Applications must locate their data in the installed `share/` tree themselves.
Successful results with data include `share_dir`, `generation_share_dir`, and a
`files` inventory with paths, signed targets, hashes, sizes and modes. All of
these selected contents belong to the same generation as the executable family.

## Select an authenticated compiler variant

GNU and musl are different compiler variants of the same `linux/amd64` routing
platform. The physical host check alone cannot choose between them. Add
`target_triple` at recipe level to bind **every executable and platform-owned runtime file** in that recipe to
one identity in the signed artifact records, including raw aliases and all
archives supplying workspace companions.
Release-wide data signed as `additional` remains independent of the compiler
choice and must not carry a target triple.

For a release containing both variants, replace the Linux recipe in the policy
above with two entries such as these. Retain the other recipes and the complete
release `targets` list; these are recipe fragments, not a complete policy:

```json
[
  {
    "schema_version": 1,
    "target": "linux/amd64",
    "target_triple": "x86_64-unknown-linux-gnu",
    "executables": [
      {"name": "demo", "artifact": "demo-gnu.tar.gz", "member": "demo"},
      {"name": "helper", "artifact": "demo-gnu.tar.gz", "member": "helper"}
    ]
  },
  {
    "schema_version": 1,
    "target": "linux/amd64",
    "target_triple": "x86_64-unknown-linux-musl",
    "executables": [
      {"name": "demo", "artifact": "demo-musl.tar.xz", "member": "demo"},
      {"name": "helper", "artifact": "demo-musl.tar.xz", "member": "helper"}
    ]
  }
]
```

When the embedded Linux recipes are the standard GNU/musl pair for the host
architecture, the generated installer automatically selects the recipe matching
the running host C library. This works for AMD64, ARM64, i686 and ARMv7 hard-float
triples. The shared installation engine observes GNU libc through `confstr`;
otherwise it reads the bounded ELF interpreter header of its running Python
process to recognize musl. It does not run a downloaded executable or `ldd`,
and the mere presence of an alternate loader cannot select a different ABI.

Inspect the same local observation without downloading or writing anything:

```bash
dsr installer describe-host
```

An unknown runtime or any other ambiguous compiler matrix still requires an
explicit selection. The consumer can always select an exact embedded recipe:

```bash
bash demo-v1.2.3.sh --prefix /home/alice/.local/demo \
  --target-triple x86_64-unknown-linux-musl
```

This option only chooses an already embedded recipe for the actual host. It
cannot rewrite the recipe, invent a compiler identity for an untyped recipe,
change its artifact names, or relax the embedded signer/source/build policy.
There is no filename-based guessing, first-entry default, or automatic libc
fallback after a missing or invalid asset. An unresolved ambiguous selection or
an unknown variant fails before payload staging or network acquisition. A sole
typed recipe selects its fixed variant by default; an untyped singleton
preserves legacy behavior. Runtime detection distinguishes GNU from musl; it
does not establish a minimum glibc version or every executable's ABI compatibility.
ARM64 uses `linux/arm64` and the corresponding `aarch64-unknown-linux-*` triples.

The standalone result's `selection` records whether the recipe was fixed,
explicitly chosen, or selected automatically, including the local libc evidence
for an automatic choice. An automatic choice and an explicit choice of the same
recipe produce the same authenticated generation. Detection does not weaken
the signed compiler identity or complete-release checks below.

The same optional recipe field works directly with `src/release_install.sh`.
After authenticating the **complete snapshot**, the engine requires an explicit
selection whenever the installed platform contains several signed compiler
identities, including mixed typed/untyped records. Every chosen platform artifact
must match the recipe's exact triple. Shared data does not add a compiler variant
to that selection. Missing signed identities, invalid explicit
triples, or a GNU executable mixed into a musl workspace are refused before
activation. Selecting GNU does not excuse corruption in an unselected musl
payload: whole-release snapshot verification still runs.

Explicit compiler selections are retained on executable and platform-data results, the generation
receipt and the top-level installation result. Switching between variants is a
new complete generation and requires runtime `--replace`; old generations stay
available for explicit, reauthenticated rollback. Equivalent recipe ordering
preserves canonical generation and installer identities.

For new manifest-backed statements, a producer's explicit `required_variants`
also preserves compiler identities for a singleton matrix. Older singleton
statements without that declaration keep their existing shape. An existing
statement lacking a signed triple cannot satisfy a typed installation recipe;
no local manifest, alias name or download receipt supplies the missing proof.
This binds the **producer's signed compiler claim** to the selected bytes. It
does not inspect the binary ABI, establish host libc compatibility, or prove
that the claimed compiler was executed. Select a compatible variant deliberately.

## Generate and inspect

```bash
dsr installer generate-release \
  --policy /srv/policies/demo-release.json \
  --public-key /srv/keys/release.pub \
  --output /srv/installers/demo-v1.2.3.sh

bash /srv/installers/demo-v1.2.3.sh --inspect
```

The public command uses the existing `install_gen_release.sh` engine. The
low-level `bash src/release_install.sh generate-installer ...` entry point and
sourceable `install_gen_release` API remain available with the same arguments.
`dsr --json installer generate-release ...` wraps the engine's complete result
in one standard envelope with `details.action: "generate-release"`; the engine
status and exit code remain authoritative. Without `--json`, it prints the
engine's JSON generation receipt directly.

The generator reads the existing DSR installation's `release_install.sh`,
`slsa_remote.sh`, `slsa.sh`, `platforms.sh`, `packaging.sh`, `sbom_release.sh`, `sbom.sh`,
`github.sh`, `guardrails.sh`, and `secrets.sh`. It snapshots and hashes their complete source files, validates each
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

Add generator `--dry-run`, or use the global `dsr --dry-run`, to review the exact
prospective installer without publishing it. The plan performs the same
policy/key/module admission, recipe normalization, Python/Bash syntax checks,
input-stability checks and existing-output replacement checks. Its
`status: "planned"` result includes the script hash, policy hash, embedded engine
hashes and whether an existing installer would be reused. Conflicting existing
output still requires `--replace`. Planning stages in private temporary storage;
it does not create or change the selected output or adjacent lock, and does not
reserve either against another writer. Real publication repeats the validation
and checks the selected output under its normal cooperating-writer lock.

## Consumers: one file, one installation command

Distribute the generated script through a trusted channel. After obtaining it:

```bash
bash demo-v1.2.3.sh --prefix /home/alice/.local/demo
```

It also supports streamed execution, such as `cat demo-v1.2.3.sh | bash -s --
--prefix /home/alice/.local/demo`, or the equivalent trusted HTTPS download
pipeline. The selected prefix's parent must already exist. The generated script
selects the physical host automatically and installs all companions from its
sole recipe or the explicit `--target-triple` choice. Its runtime options are deliberately limited to:

- `--prefix DIR`, `--snapshot DIR`, `--target-triple TRIPLE`, `--timeout SECONDS`, `--download-jobs N`, and `--download-cache DIR`.
- `--replace`, `--allow-draft`, `--dry-run`, `--inspect`, and `--help`.

The default is online `--fetch` behavior from the existing engine: authenticate
and download the complete selected release, reauthenticate the same snapshot
locally, extract the selected payloads, and activate one complete generation.
There is no runtime override for repository, version, source commit, builder,
key, target matrix, recipe contents, or build pins. Compiler selection only
chooses among fixed embedded recipes. A failed download or signature check
cannot fall back to unsigned binaries, a different release or source execution.

For online installation, `--download-jobs N` admits up to **1..32** concurrent
payload downloads after proof authentication and complete inventory preflight;
the default is **1**. The captured fetch engine owns and drains every worker on
failure or cancellation. This option changes only download scheduling, not the
embedded policy, signed asset checks or installed generation identity. It is
invalid with `--snapshot`.

For large releases or an unreliable connection, select persistent download
storage explicitly:

```bash
bash demo-v1.2.3.sh --prefix /home/alice/.local/demo \
  --download-cache /home/alice/.cache/dsr/demo-v1.2.3 --download-jobs 4
```

Repeat this command after interruption. `--download-cache DIR` selects one exact
snapshot destination with an existing parent; the engine retains its completed
verified payloads in `DIR.partial` and serializes acquisition through `DIR.lock`.
These paths must be canonical, free of symlinks, and separate from the managed
installation and selected policy inputs. The new cache is private. A completed
retry reauthenticates the cached snapshot and current remote proof, downloads
only missing payloads, and preserves the original snapshot files. A changed
release generation, policy, key or inventory, or corrupt cache, fails without
repair or replacement. Use a new cache destination for a different release.

The cache binds the embedded policy and key bytes, not the temporary directory
where the script unpacks its engines. It therefore works across streamed
executions and changes in `--download-jobs`. Its `download.acquisition` result
reports reused and newly downloaded payload counts. Cache storage and these
observations do not affect the installed generation identity. The engine still
authenticates every platform and compiler variant before installation.

Explicit `--download-cache` also persists completed downloads during
`--dry-run`, so a preview can prepare downloads for an installation. This can
write the cache, checkpoint and cache lock; it never creates the installation
prefix, installation lock or active pointer. Without the option, acquisition
remains temporary. A complete cache may later be selected as `--snapshot DIR`
for deliberate offline installation. The two options cannot be combined, and
online cache use never falls back to offline success after a network failure.
See [the installation cache contract](RELEASE_INSTALLATION.md#retain-downloads-across-attempts)
for the complete recovery and path rules.

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
The existing installation engine authenticates and stages every selected executable and runtime file
before switching `current`; old generations remain available. To roll back,
run the original generated script with its matching snapshot or release and
`--replace`. Rollback is explicit and reauthenticated, not an automatic policy.
Online re-download and equivalent offline installation select the same generation.
The retained generation must still have exactly its declared files and directories,
with the expected bytes and permissions and no links. A changed or extra runtime
file blocks reuse and rollback rather than being silently overwritten. For a
program that needs one version across separate executable and data lookups, use
`generation_bin_dir` and `generation_share_dir` from the same result; repeated
lookups through `current` can straddle an upgrade.

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

`bash scripts/tests/test_installer_release_cli.sh` exercises the public
`generate-release`, `describe-recipe` and `install` commands with real Minisign
signatures and inert payload fixtures. It covers planning without output or
lock changes, exact planned/published script hashes, invalid policy/key refusal,
replacement consent, public JSON envelopes, complete activation and rollback,
integrity failures, and cancellation. It uses no network or compiler.

Run `bash scripts/tests/test_generated_release_installer.sh`. The suite generates
and executes the actual standalone script, removes the original DSR/policy/key
paths, exercises streamed online and offline installation, validates frozen trust
options, preserves active files on failures and cancellation, and upgrades and
rolls back a complete native executable set. It also installs, runs, upgrades
and rolls back an application that requires both shared JSON and archive data,
with the original engine, key and policy paths detached. It checks fixed data
modes, empty data members, corrupt shared subjects, canonical regeneration,
unsafe policy rejection and literal builder identities. Only the tests execute
installed payloads; they compile small C fixtures when `cc` is available.

The generator, complete SLSA/snapshot verifiers, archive helpers and installation
engine are real. GitHub transport and Minisign are explicit file/hash fixtures;
this is not live HTTP, native Ed25519, Rust release, Windows or macOS acceptance.

The compiler-variant path has a separate focused regression:

```bash
bash scripts/tests/test_release_install_variants.sh
```

It uses real manifest projection, full snapshot verification, archive
construction/extraction, standalone generation, and installation pointer
switches. It checks GNU/musl selection, mixed-workspace refusal, stable retry,
explicit replacement, rollback, canonical regeneration, malformed selectors,
and operation without the original engine/key paths. Payloads are owned text
fixtures, not compiled GNU/musl binaries, and are never executed.

The focused suite requires real Minisign by default. An explicit
`DSR_TEST_MINISIGN_FIXTURE=1` opts into a deterministic test-only key/hash CLI
boundary; that mode is not cryptographic qualification. A partial validation
checkout may additionally use `DSR_TEST_OFFLINE_ENGINE_STUBS=1` for missing,
uninvoked online module bodies, which are then fail-if-sourced sentinels in
its private test runtime. That mode exercises offline installation only and
makes no online-engine claim. Full checkouts embed their real source modules.
