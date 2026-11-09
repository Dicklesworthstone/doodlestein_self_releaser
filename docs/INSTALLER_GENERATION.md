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

## Private Bash releases without the GitHub CLI

A generated Bash installer can download a private release when the client has
**curl, jq and a repository token**, without installing or logging into `gh`.
Provide the credential through the environment: selection is `DSR_GH_TOKEN`,
then `GITHUB_TOKEN`, then `GH_TOKEN`. The token needs **Contents: read** access
to the configured GitHub repository. An explicit version and latest-release
discovery both support this path:

```bash
# The token is supplied by your environment or CI secret configuration.
bash install.sh --version v1.2.3 --yes --no-skills
bash install.sh --yes --no-skills
```

The direct API path is selected when an explicit token is available and `gh`
is absent. Clients with `gh` retain the existing anonymous-first download and
`--prefer-gh` behavior. Clients without a token retain public HTTPS downloads.
The extra jq requirement applies to this direct authenticated API path;
ordinary public release downloads do not acquire a new dependency.

The installer resolves the exact published release ID and tag, reads the
complete asset inventory in pages of 100, then downloads the selected payload,
checksum and configured signature by their exact asset IDs. It handles an empty
or singleton final page and rejects malformed release objects, drafts, duplicate
names or IDs, incomplete selected assets and changed download sizes. Inventories
are limited to 10,000 records. API pages are bounded to 8 MiB and processed from
private files, so large inventories do not become shell command arguments.
The implementation follows GitHub's [release-tag lookup](https://docs.github.com/en/rest/releases/releases#get-a-release-by-tag-name)
and [asset listing and binary-download APIs](https://docs.github.com/en/rest/releases/assets).

An absent checksum filename can select the next supported format, including
the canonical `SHA256SUMS`. A discovered asset that returns an HTTP error
cannot be treated as absent. Authentication failures, invalid metadata and
failed discovered downloads stop installation; they do not select an anonymous
download, another account or a source build. All downloaded and cached bytes
still require exact checksum evidence and every configured Minisign signature.

Credentials are sent only to the configured repository's HTTPS release API.
Binary redirects may reach HTTPS object storage, where the Authorization header
is removed permanently for that transfer. Metadata redirects outside the
repository, redirects to a different GitHub API repository, URL credentials,
fragments, HTTP and nonstandard ports are refused. Curl receives credentials and
signed object-store URLs through stdin, and ignores ambient curl configuration.
Neither secret enters curl arguments, installer diagnostics or cached evidence.
Each transfer has a deadline covering its redirects and a bounded response
stream, including on older curl versions.

Verified private releases remain usable without a token from the exact cache,
both with `--offline` and during an explicit-version online install. Offline
mode makes no release, checksum or signature request. Regenerate deployed
installers to include the new acquisition path.

The focused regression uses actual generated programs, compiled executable
families, Minisign, curl and a local HTTPS release service:

```bash
bash scripts/tests/test_generated_installer_private.sh
```

It covers token precedence, a real API page larger than 128 KiB, complete
pagination, redirect and credential behavior, checksum/signature failures,
latest and explicit tags, public installation and verified offline reuse.
Only DNS routing and certificate trust are adapted for the local service;
the regression does not establish successful live GitHub acquisition.

## Native Windows installers

Generate a standalone PowerShell installer using the same per-tool configuration:

```bash
dsr installer generate tool --shell powershell --output-dir ./installers
dsr installer validate tool --shell powershell --output-dir ./installers
dsr --json installer generate tool --shell powershell --dry-run
```

The output is `installers/tool/install.ps1`. The sourced APIs are
`install_gen_create_powershell tool [--config-dir DIR] [--dry-run]` and
`install_gen_validate_powershell tool`. An explicit configuration root also owns
fallback signing configuration and `minisign.pub`; it cannot silently borrow a
key from another registry. The generator requires `yq`, `jq`, Python 3 and
PowerShell (`pwsh`). It parses the complete generated program before publication
and uses the same held-directory, concurrent-writer and previous-file preservation
rules as the Bash generator. A dry run validates policy and observes the output
without creating a directory, installer or lock.

At least one Windows target must be declared. Supported targets are
`windows/amd64`, `windows/arm64` and `windows/386`, with one compiler triple per
platform. Ordinary release names use DSR's actual publication naming functions,
including architecture aliases and target triples. Strict contracts select the
literal `exact_primary_assets` name and its declared format. Configuration is
embedded as base64-encoded JSON data, never evaluated as PowerShell code.

```yaml
tool_name: tool
repo: owner/tool
binary_name: tool
targets: [windows/amd64, windows/arm64]
archive_format: {windows: zip}
artifact_naming: '${name}-v${version}-${target_triple}'
workspace_binaries: [tool, tool-worker]
workspace_binaries_by_target:
  windows/arm64: [tool]
```

ZIP and raw executable assets are supported. A raw asset supplies exactly one
executable; its strict release basename can differ from the installed `.exe`
name. ZIPs must contain exactly one regular member for every selected executable.
Per-target workspace lists replace the global family, and an empty list selects
the primary. The generated family is bounded to 64 executables. Duplicate or
case-colliding names, reserved Windows device names, unsafe paths, reparse/link
entries, and a wrong PE machine type are refused before installation. Unselected
archive members are not installed as additional executables.

Run the generated script in native Windows with PowerShell 7.4 or newer:

```powershell
.\install.ps1 -Version v1.2.3 -Yes
.\install.ps1 -Version v1.2.3 -Prefix C:\Tools\tool\bin -CacheDir C:\ToolCache -Yes
.\install.ps1 -Version v1.2.3 -Prefix C:\Tools\tool\bin -CacheDir C:\ToolCache -Offline -Yes
```

Online acquisition supports public and private GitHub release assets. With a
selected credential, the installer uses GitHub's release and asset APIs. Token
selection is `DSR_GH_TOKEN`, then `GITHUB_TOKEN`, then `GH_TOKEN`; use a credential
with **Contents: read** access to the configured repository. A selected token
that fails authentication is not replaced by another account or an anonymous
download. Without a token, public release assets retain their direct HTTPS
download path. No GitHub CLI installation or stored CLI login is required.

The authenticated path resolves the exact published release ID, reads its
complete asset listing in pages of 100, and selects the payload, checksum and
configured signature by their exact names. Empty and singleton final pages are
handled explicitly; duplicate asset names or IDs, malformed pages, draft or
mismatched releases, and incomplete assets fail before installation. Inventories
are bounded to 10,000 assets. Downloads use the selected asset IDs and
`Accept: application/octet-stream`, and their lengths must match the discovered
records before checksum and signature verification. Remote asset URLs and
pagination links cannot redirect selection to another repository.
This uses GitHub's documented [release-tag lookup](https://docs.github.com/en/rest/releases/releases#get-a-release-by-tag-name)
and [release asset listing and binary-download APIs](https://docs.github.com/en/rest/releases/assets).

Credentials are sent only to the configured repository's `api.github.com`
release endpoints. Binary redirects may reach HTTPS object storage, where the
Authorization header is removed and cannot be restored by a later redirect.
Metadata redirects outside the configured repository, HTTP redirects and
nonstandard ports are refused. Tokens are not written to installer results,
diagnostics or cached receipts. Each transfer retains the complete-transfer
deadline and size limit used by public downloads.

Omitting `-Version` selects the latest release online. Explicit nonnumeric tags
such as `release-2026.11` are preserved; a bare numeric `1.2.3` selects `v1.2.3`.
Offline mode requires an explicit version and makes no release lookup, checksum request or signature
download. The cache binds repository, version, platform, selected asset and
embedded policy; cached bytes and evidence are rechecked on every installation.
Verified private assets can be reused offline without a token, while all checksum
and configured signature requirements remain in force. An already complete exact
cache also needs no authenticated discovery during an explicit-version install.
Cache locations must belong to the current user and reject modification by
untrusted principals. Payloads and evidence are copied into private staging and
verified there before extraction. Downloads have a complete-transfer deadline;
redirects cannot forward credentials to a different host.
A missing checksum entry, malformed or duplicate checksum record, changed
payload, missing signature or signature failure stops the attempt. When the
policy contains a Minisign key, a missing Minisign executable is an error.
There is no unsigned fallback from a configured key.

The default prefix is `%LOCALAPPDATA%\Programs\TOOL\bin`; it needs no administrator
installation and does not edit PATH or shell profiles. `-Yes` permits replacing
existing selected executables. Without it, interactive use asks first, while
noninteractive CI refuses an overwrite. The complete executable family is staged
and validated before replacement. A cooperating-writer lock covers the update;
if a later replacement fails, the transaction restores the earlier files and
retains failed recovery evidence when it cannot complete restoration. Unrelated
files in the prefix are preserved. This is a cooperating installation transaction,
not an atomic switch of every executable or a power-loss durability guarantee.

`-Json` keeps stdout machine-readable and includes the installed executable
receipts; progress and `-Verbose` diagnostics go to stderr. `-Help` performs no
download or installation. Windows source builds and agent-skill installation are
outside this generator's release-asset path. The separate `generate-release`
authenticated snapshot engine remains a distinct command and policy format.

```bash
bash scripts/tests/test_install_gen_windows.sh
bash scripts/tests/test_install_gen_windows_policy.sh
```

The regression exercises actual generated programs, genuine Go-produced Windows
PE files, ZIP parsing, Minisign verification, cache and replacement operations.
Authenticated acquisition runs the actual HTTP request, redirect and streaming
implementation with a .NET response-handler fixture. It covers token priority,
paginated exact asset lookup, binary Accept headers, credential removal on signed
object-store redirects, refusal without anonymous fallback, and offline reuse
without credentials. Portable PowerShell runs use explicit host/HTTP adapters
and a labelled move failure injection for rollback; they do not establish native
NTFS behavior or successful live GitHub acquisition.
The policy regression exercises the actual configuration and publication naming
helpers, explicit signing-key scope, executable-family limits and refusal before
any existing installer or publication history changes.

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
