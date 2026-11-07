# Ordinary installer generation

The sourced `install_gen_create` API generates the ordinary per-tool Bash
installer. This is separate from the pinned, authenticated installer generator
in `install_gen_release.sh`.

```bash
source src/install_gen.sh
install_gen_create ntm --config-dir "$HOME/.config/dsr"
```

The explicit configuration root selects `DIR/repos.d/TOOL.yaml` with no
fallback. Without it, generation retains the existing current-directory-first
configuration lookup and logs the selected file. Set `DSR_INSTALLER_DIR` before
sourcing the module to select an output root; the default is `./installers`.
Success prints only the generated installer path to stdout. Diagnostics and
retained-history paths go to stderr.

## Executable families from source

The ordinary installer uses the same effective `workspace_binaries` family for
verified release archives and explicitly authorized source builds. A
`workspace_binaries_by_target` entry replaces the global list for that platform;
an empty list selects only `binary_name`. Every nonempty family must include its
primary executable. Rust, Go, Bun, and TypeScript source builds produce every
selected member from one pinned checkout before installation begins.

```yaml
binary_name: app
language: go
workspace_binaries: [app, app-helper, app-worker]
source_subdir: project
source_entry: entry/main
```

For this Go configuration, the primary comes from `project/entry/main`, while
the companions come from `project/cmd/app-helper` and `project/cmd/app-worker`.
Without `source_entry`, the primary uses `cmd/app` when that path exists and
otherwise the module root. Each companion requires its own `cmd/<name>`
directory; it never falls back to the primary's package. DSR resolves all
selected paths and requires every selected Go package to be `main` before the
first build. It preserves the existing readonly/vendor dependency policy and
builds for the installing machine, regardless of inherited `GOOS`, `GOARCH`,
or `GOFLAGS`.

For Bun and TypeScript, each companion requires its exact name in the selected
project's `package.json` `bin` object:

```json
{
  "bin": {
    "app": "src/cli.ts",
    "app-helper": "src/helper.ts",
    "app-worker": "src/worker.ts"
  }
}
```

An explicit `source_entry` overrides only the primary. A scalar `bin` string
also selects only the primary and cannot supply companion roles. Every selected
entry must be a regular file inside the pinned project, with no symlink path
components. After resolving the complete family, DSR runs one
`bun install --frozen-lockfile` and then compiles each member separately. A
committed `bun.lock` or `bun.lockb` remains mandatory. Rust continues to select
the complete family through Cargo and verify each resolved executable provider.

Go and Bun payloads are kept in a separate `output/bin` directory, so an
executable named `compiler.log` cannot overwrite retained compiler evidence.
Every compiler command retains its own diagnostics and timeout. The receipt
binds all selected executable names, hashes and sizes to the pinned source
commit, and explicitly marks the result as locally built rather than a signed
release. Missing entries, invalid providers, a failed member, or source drift
prevent a success receipt and leave the installed family unchanged. Successful
families use the same verified installation transaction and directory lock as
release archives.

The focused integration executes genuine Go and, when installed, Bun compilers
through the public generator and standalone installer:

```bash
bash scripts/tests/test_generated_workspace_installer.sh --go-bun-source-only
```

It checks complete executable receipts, primary overrides, platform subsets,
dependency locking, missing and unsafe providers, later compiler failure,
tag-pinned fallback, and refusal to fall back after a failed release checksum.
The Bun cases explicitly report a skip when the real Bun compiler is absent.

## Optional source toolchain bootstrap

Generated installers can build a pinned source revision with `--from-source`,
or fall back to source when release discovery/download is unavailable with
`--allow-source-build`. Both options explicitly authorize execution of repository
and dependency build code. A failed release checksum or signature remains fatal;
source fallback cannot bypass artifact verification.

When a required compiler is missing, add **`--install-toolchain`** to prepare one
inside that source attempt's private build directory:

```bash
# Build this release tag, preparing a compiler only if required.
bash install.sh --from-source --version v1.2.3 --install-toolchain

# Prefer a verified release; permit source fallback and a missing compiler.
bash install.sh --allow-source-build --install-toolchain
```

`--install-toolchain` requires one of those source-consent options. `--yes` alone
does not authorize source execution or compiler setup. The option does not force
source compilation when a verified release is usable, and cannot be combined
with source modes that require offline operation or signed release artifacts.

Bootstrap supports Linux and macOS on amd64 and arm64. Source builds require
Bash 4+, Git, jq, ps and SHA-256 tooling; compiler acquisition additionally needs
curl, Go extraction needs tar, and Bun extraction needs unzip. System linkers and
project-specific native dependencies must already be available. The installer
does not install operating-system packages.

Compiler selection comes from the selected source tree:

| Language | Selection |
|----------|-----------|
| Go | An exact numeric `toolchain goX.Y.Z` takes precedence. Otherwise the `go` directive is used: an exact patch stays exact, while `X.Y` selects the newest stable patch in that minor. Unsupported or unavailable requirements fail. |
| Rust | Rustup reads the repository's `rust-toolchain.toml` or legacy `rust-toolchain` file. Without one, the private installation selects stable. Ambient parent overrides are not adopted as project requirements. |
| Bun / TypeScript | An exact numeric `packageManager: bun@X.Y.Z` is honored; otherwise an exact numeric `engines.bun` can pin the version. Unpinned recipes use the latest stable Bun release and must satisfy any declared engine range. Unsupported pins or incompatible ranges fail. |

A working compiler already on PATH is preserved, including an older compiler
that may subsequently fail the project's build requirements. Rustup proxies can
exist without the selected compiler: with bootstrap consent, a bounded probe
checks availability with automatic Rustup installation disabled. A missing
selected compiler permits a private bootstrap; a probe timeout or interruption
fails before downloading anything. Compiler upgrades are not implicit.

Downloads use official HTTPS endpoints and verified SHA-256 metadata before
execution. Go also verifies the advertised archive size and admits only regular
files/directories under its expected archive root. Rust verifies rustup-init and
then uses Rustup's official distribution handling. Bun verifies the selected
archive against the official release checksum inventory; its optional PGP
signature is not verified by this bootstrap. These checks trust the official
HTTPS metadata source and do not turn a local source build into a signed release.

The compiler, downloads and language homes stay under the new private build
directory. Profiles, global compiler homes and system installation prefixes are
not modified. Bootstrap uses the same per-command timeout and process-group
supervision as source compilation. Failures retain diagnostics and cannot replace
an installed application; successful temporary state follows the installer's
existing cleanup policy. Source code execution is not sandboxed.

Successful source receipts include a `toolchain` object when bootstrap was used,
recording the compiler version, platform, distribution URL and verified hash.
Temporary compiler paths are excluded from the public source receipt.

The shared sourced API uses a separate explicit consent argument:

```bash
source src/install_source.sh
install_source_build owner/repo refs/tags/v1.2.3 go app ./new-build \
  --allow-build --install-toolchain --timeout 3600
```

## Repository-bound release caches

Ordinary installers reuse a cached release only for the same configured tool,
repository, exact release tag, platform/compiler variant, archive format and
literal asset name. A checksum sidecar authenticates the cached bytes against
that sidecar; it cannot establish which repository originally supplied them.
Keeping these identities in separate cache paths prevents another repository
with the same tool name and version from supplying a cache hit. Changing an
exact asset name within the same release also selects a separate cache entry.
Each asset owns its payload and sidecars in a separate directory, including
when a literal payload name ends in `.sha256` or `.minisig`.

Verified archives and their checksum/signature evidence remain reusable with
`--offline --version TAG`. Different repositories and asset names can share
`--cache-dir` without replacing each other's entries. Every reuse still checks
the actual payload checksum and the configured Minisign policy, and a failed
integrity check remains terminal rather than triggering a different download.

Older tool/version/platform-only caches are retained but are not automatically
adopted because they do not record this origin selection. An online install
populates the bound cache; a subsequent offline install reuses it. An explicit
`--offline ARCHIVE` remains an independent local selection and requires its
matching checksum evidence and any configured signature.

The focused regression runs actual generated installers against distinct
archive bytes with a shared cache; only the remote transport is a fixture:

```bash
bash scripts/tests/test_generated_installer_integrity.sh --cache-identity-only
```

## Installation transactions and concurrent installers

Generated ordinary installers serialize changes to each installation directory.
They acquire a private `.dsr-install.lock` directory before checking overwrite
permission or backing up installed executables, and hold it through staging,
replacement, final verification, and any rollback. Release installation and
explicit source installation use the same transaction. Two tools sharing a
companion executable use the same directory lock, including when callers reach
that directory through different symlink paths. Independent installation
directories can proceed concurrently.

A competing installer fails with an actionable busy/retry message and leaves the
existing family unchanged. `--yes` authorizes replacement of executables; it does
not override an active installation lock. The lock uses atomic directory creation
on Linux, macOS, and FreeBSD, without requiring `flock` or Python on the installing
machine. Its owner record and directory identities are checked before cleanup,
which removes only the owning transaction's metadata and empty lock directory.

Normal completion, overwrite refusal, installation failure, and handled
interruptions release the lock after restoration finishes. If restoration fails,
the installer retains its recovery files and lock for inspection. A process
killed with an uncatchable signal or a machine interrupted during installation
can also leave a lock behind. Inspect the owner record and the installation
before manually removing an abandoned lock; installers never steal locks based
on their age or a possibly reused process ID. Unexpected lock replacement fails
closed and does not remove the replacement's resources.

This coordinates cooperating installers; it is not a transaction against
arbitrary same-user or privileged filesystem writers or a power-loss guarantee.
The focused regression uses real generated installers, checksum verification,
real filesystem renames and a signal to the public installer process:

```bash
bash scripts/tests/test_generated_installer_transactions.sh
```

## Publication, failure and concurrent generation

Generation validates the tool identifier before constructing configuration
paths and the configured tool/repository/binary identities before rendering.
It observes the selected output ancestry and any existing `install.sh` before
rendering starts. It then renders the complete installer in memory and checks
its Bash syntax without executing it. Rendering, help-text and skill-archive
failures stop generation; they cannot publish a truncated or incomplete script.

A POSIX Python 3 publisher stages the candidate on the destination filesystem,
checks the observed file and directory identities again, and activates it with
one atomic replacement. Existing readers retain the old complete inode; new
readers see the complete replacement. The published mode is `0755`.
An identical, already-executable installer is retained without changing its
inode, timestamps or history. ShellCheck, when installed, remains an advisory
check; Bash syntax validation is mandatory before publication.

Every output path component must be a real directory, not a symbolic link.
Relative roots, spaces, `.` and missing parents are supported; `..` components
are refused. Use a physical path for deliberately symlinked locations, such as
macOS temporary-directory aliases. A linked, hardlinked, directory or special
file at the `install.sh` destination is refused without following or modifying
its target. These rules also apply to the publisher's lock file.

The persistent `.install-gen.lock` serializes cooperating publishers. It is
released by the kernel when a process exits; do not delete it to recover a
failed invocation. Concurrent generators that observed the same prior version
cannot silently overwrite each other: a changed output/ancestry or busy lock
returns a conflict (exit 2). Regenerate against the current state after inspecting
that conflict. Do not reuse a private output-observation token to authorize a
later unrelated generation.

Each changed publication retains `.install-gen.<unique-id>/` under the tool's
output directory. It contains the original observation and candidate digest in
`selection.json`, a private byte-for-byte `previous.sh` when a prior installer
existed, and `completed.json` after successful publication. An interrupted or
failed staging write can leave `candidate.sh` there. Generation does not delete
this history or roll it back automatically. The original mode is recorded in
`selection.json`; the backup is deliberately stored privately as `0600`.
These runtime files are ignored by the repository's Git rules. Distribute the
selected `install.sh`, not a recursive copy of its private history directory.

A failure before replacement leaves the existing installer unchanged. A failure
after replacement, including failure to persist completion evidence, returns
nonzero and explicitly reports that replacement already occurred. It does not
claim rollback or overwrite an externally changed file to manufacture success.
An identical retry rechecks the actual installed bytes rather than inferring
completion from a previous receipt.

This is atomic local publication, not a filesystem power-loss durability
promise or a sandbox against a malicious privileged/same-user writer. Directory
handles prevent symlink redirection and repeated observations reject detected
changes; observations and replacement are not an atomic compare-and-swap with
arbitrary writers that ignore the lock. Generated content is bounded to 64 MiB,
and each syntax-validation subprocess is bounded to 30 seconds. This dependency
is on the generator host; the ordinary generated release installer has no new
Python requirement. No download, installation or compiler runs during generation.

## Regression coverage

```bash
bash scripts/tests/test_install_gen_publication.sh
bash scripts/tests/test_install_gen_identity.sh
```

The publication suite uses the complete generator, simple YAML configuration,
real POSIX files, locks, processes and an actual kernel file-size limit. Controlled
renderer barriers exercise competing writers and edits during rendering. A
clearly labelled interpreter-boundary adapter applies the write limit only after
Bash has delivered its here-document, so the test reaches the real staging write.
Generated scripts are syntax-checked, and only their `--help` path is executed.
All test files and failed-generation evidence are retained.

The optional identity-suite `--parser-fixture` adds typed-parser transport checks
using PyYAML; it does not qualify native yq interoperability. These focused
checks do not qualify a public installer, Windows generation, live downloads,
GNU/musl acquisition, or native builds. Existing committed installers are not
regenerated by this change.
