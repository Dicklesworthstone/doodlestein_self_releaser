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

## Executable target checks in Bash installers

After checksum and configured signature verification, the generated Bash
installer inspects every selected executable before considering a stale-release
source build or replacing any installed member. The same check runs again on
each private staged copy used by both release and source installation.

The check reads binary headers with `od`; it does not execute a payload to
decide whether to admit it. ELF class and machine must match the selected
Linux or FreeBSD CPU. Mach-O executables must contain the selected macOS CPU,
including a matching slice in a universal FAT32/FAT64 container. PE machine,
optional-header class, executable flags and application subsystem must match
the selected Windows CPU. Invalid or truncated headers, out-of-file header
tables, overlapping universal slices, DLLs, object files, unknown formats and
foreign CPU/format payloads are refused with exit 7 before the first executable
replacement. A rejected companion preserves the entire previous family.
Missing `od` reports dependency exit 3.

An explicit `#!` launcher with a nonblank absolute interpreter path remains
supported independently of the configured source language. DSR can distribute
script launchers as well as compiled programs; this exception does not prove
that the interpreter exists, or make a script a native Windows PE executable.

These are bounded header and CPU checks, **not a complete executable loader**.
They do not validate every segment body or instruction, dynamic-library
availability, libc symbol versions, CPU extensions or minimum operating-system
versions. ELF's unspecified System V OSABI can describe both Linux and FreeBSD
programs; an explicit incompatible OSABI is refused, but an unspecified value
does not establish runtime ABI compatibility. Individual files are bounded to
4 GiB minus one byte, and universal containers to 64 nonoverlapping slices.
Checksums and configured signatures still authenticate the published bytes.
A format refusal cannot become an automatic source fallback.

Regenerate existing installers to include these checks. The focused regression
builds genuine Go ELF, Mach-O and PE files for all supported platforms, signs
their archives with Minisign, and exercises the generated installer:

```bash
bash scripts/tests/test_generated_installer_integrity.sh --executable-targets-only
```

Host discovery is explicitly adapted to inspect foreign formats. These tests
cover selected-file admission and complete-family preservation; they do not
claim native execution on every target operating system.

## Public Bash acquisition and source fallback

`--allow-source-build` grants source fallback for proven release availability
failures. Anonymous HTTP 404/410, 408/429/5xx, supported DNS/connection/transfer
failures, and the installer's complete-transfer deadline may use the source
engine. An explicit or discovered version still builds its exact tag; only
unavailable latest discovery before a tag is known can select `HEAD`.

TLS trust failures, local write errors, unsafe redirects, malformed successful
release metadata, drafts, and invalid checksum/signature evidence stop the
installation. They never become permission to execute repository build code.
Cancellation returns 5, including cancellation during GitHub CLI credential
lookup. Source fallback preserves an existing installation until the complete
replacement executable family has been built and verified.

An anonymous latest-API 403 may still resolve a published public tag through
bounded HTTPS `HEAD` redirects within the exact repository. If that independent
discovery cannot identify a tag, the denial remains terminal. `--prefer-gh`
retains its transport preference, and a successful alternate download remains
usable. An unsuccessful actual `gh` request does not prove that a release is
absent, so its ambiguous failure cannot authorize source compilation. A machine
with no stored GitHub CLI login can continue using anonymous acquisition.
For optional checksum filenames, independently proven public unavailability
may still advance to the next supported manifest after an ambiguous `gh`
failure. The selected manifest must then verify the exact payload; this
exception never authorizes source compilation.

Public requests ignore ambient curl configuration, bound response streams and
the complete redirect chain, and keep signed object-store redirect URLs out of
curl arguments and shell tracing. Published release identity is validated
before selecting a latest tag. Existing verified cache entries retain their
precedence. Regenerate deployed installers to include these checks.

The focused regression exercises actual generated installers with real Git and
Go builds and explicit curl/gh response-boundary fixtures:

```bash
bash scripts/tests/test_generated_installer_source.sh --acquisition-fallback-only
```

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
failed checksum/signature downloads stop installation. All downloaded and cached bytes
still require exact checksum evidence and every configured Minisign signature.

For this direct authenticated API route, `--allow-source-build` also permits
source fallback when release discovery, exact release metadata, the asset
inventory or the primary payload is unavailable. Eligible failures are HTTP
408/429/5xx, DNS/connect/HTTP transfer failures and the installer's own transfer
deadline. The same selected credential authenticates the source checkout.
An explicit or discovered version builds `refs/tags/<version>`; only unavailable
latest discovery before a tag is known selects `HEAD`. A complete inventory
can prove that the primary is absent, while authenticated 404/410 responses
remain ambiguous and stop installation.

TLS trust failures, local I/O errors, unsafe redirects, malformed metadata,
corrupt cache entries and failed verification cannot authorize source execution.
A truncated HTTP denial keeps its denial status even if the transfer also
fails. Explicit cancellation returns 5 through discovery, payload and proof
acquisition. A failed source fetch or compilation remains terminal and preserves
the installed executable family; a missing selected tag never retries `HEAD`.
Existing verified cache entries retain precedence. Run the focused controls with
`bash scripts/tests/test_generated_installer_private.sh --fallback-only`.

Release downloads send credentials only to the configured repository's HTTPS release API.
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

Token-only clients can also use `--allow-source-build --source-if-stale N`
against a private repository. After verifying the complete release family,
the installer uses the same selected account to resolve the annotated release
tag and default-branch head to immutable commits and compare their distance.
When the release is more than `N` commits behind, it fetches and builds that
exact observed head, including every selected companion executable. Freshness
API requests remain within the configured repository, refuse redirects, ignore
ambient curl configuration, and bound each JSON body to 8 MiB. Unavailable or
invalid comparison metadata remains `unknown` and keeps the verified release;
it never grants source-build permission. A failed release checksum or signature
stops before freshness lookup. Source builds still require installed compilers
or separate `--install-toolchain` consent and produce explicitly unsigned local
build receipts.

The focused regression uses actual generated programs, compiled executable
families, Minisign, curl and a local HTTPS release service:

```bash
bash scripts/tests/test_generated_installer_private.sh
```

It covers token precedence, a real API page larger than 128 KiB, complete
pagination, redirect and credential behavior, checksum/signature failures,
latest and explicit tags, public installation and verified offline reuse.
Private freshness controls also exercise actual Git-over-HTTPS acquisition and
Go compilation of a complete executable family. Run those controls alone with
`bash scripts/tests/test_generated_installer_private.sh --freshness-only`.
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

ZIP, tar.gz and raw executable assets are supported. A raw asset supplies exactly one
executable; its strict release basename can differ from the installed `.exe`
name. Archives must contain exactly one regular member for every selected executable.
Per-target workspace lists replace the global family, and an empty list selects
the primary. The generated family is bounded to 64 executables. Duplicate or
case-colliding names, reserved Windows device names, unsafe paths, reparse/link
entries, and a wrong PE machine type are refused before installation. Unselected
archive members are not installed as additional executables.

Gzip-compressed TAR archives are read with the .NET runtime included in
PowerShell; no `tar`, `gzip` or archive extraction command is required on Windows.
USTAR, GNU long-name and PAX name records are supported. ZIP and TAR share the
same Windows path and case-collision checks. TAR links, sparse entries, special
files, ambiguous executable basenames, invalid header checksums and incomplete
archives are refused. A streaming reader bounds the complete expanded TAR stream
to 4 GiB, every regular member to 2 GiB, extended metadata to 1 MiB per record,
and the physical archive to 10,000 headers. It also checks the gzip trailer's
CRC and length against the actual decompressed bytes. Only selected executables
are written to private staging; the complete archive is admitted before any
installed file is replaced. `tar.xz` remains unsupported by this native installer.

The focused archive regression uses the real DSR packager, generated installers,
genuine Go-built x64/ARM64 PE files and Minisign signatures:

```bash
bash scripts/tests/test_install_gen_windows_archives.sh
```

It covers ordinary and literal strict asset names, verified offline cache reuse,
complete-family rollback and malformed signed archives. Linux adapts host
detection and HTTP delivery for this test; it does not establish native Windows
ACL/NTFS or live GitHub acceptance.

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
Without a selected token, an unavailable or rate-limited latest-release API
(HTTP 403, 408, 429, 5xx, or a transport failure) falls back to GitHub's documented
[public latest-release link](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases).
The installer follows at most five HTTPS `HEAD` redirects within the exact
repository, requires a successful `/releases/tag/TAG` destination, and pins all
subsequent payload and verification downloads to that tag. Login pages, another
repository, unsafe tags, URL credentials, queries, fragments and nonstandard
ports are refused before contacting their destinations. HTML content is never
parsed to guess a version. This discovery has its own 60-second deadline.
Authenticated failures, malformed successful API responses, and API identities
claiming a draft or prerelease remain errors; they cannot authorize an anonymous
fallback. The selected release still needs its exact checksums and every
configured signature before installation.

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
and validated before replacement. A cooperating-writer lock covers the update.
Before replacing the first executable, the installer publishes a private,
immutable transaction journal that records the complete family and the exact
previous and incoming bytes. Original backups remain available until the
transaction is completed. A handled replacement failure restores the previous
family; an interrupted process leaves enough local evidence for explicit
recovery. Ordinary installation refuses to replace a family with a pending
transaction.

To restore an interrupted installation, run the generated installer with the
same destination:

```powershell
.\install.ps1 -Recover -Yes
.\install.ps1 -Recover -Yes -Prefix C:\Tools\tool\bin -Json
```

Recovery requires `-Yes` and does not accept release, cache or source-build options.
It operates before release lookup or cache access and needs no network, token,
Minisign executable or downloaded release. The installer validates the journal's
tool, repository, native platform and destination; private staging ownership and
paths; every original backup; and the current executable family before restoring
any member. It refuses unknown destination bytes, malformed metadata, symbolic
links or reparse points, and changed backups. A file introduced by the interrupted
installation is removed only when it still contains that transaction's exact incoming bytes. Unrelated
files remain untouched.

Restoration copies from preserved backups, so another process interruption during
recovery can be retried with the same command. A completion marker binds the
exact journal after the entire installed or restored family is checked. If the
process stopped after that completion point, recovery finishes private-state
cleanup and preserves the completed installation. It does not undo a successful
update. The pending journal is removed before backup cleanup, so interrupted
cleanup cannot be mistaken for an unfinished replacement.

Recovery JSON reports `operation: "recover"`, `recovery_action: "rolled_back"`
or `"completed_cleanup"`, and `transaction_state: "rolled_back"` or
`"committed"`. An actual rollback includes each member's prior presence and
SHA-256/length evidence. These receipts describe locally retained prior bytes;
they do not assert that the previous installation was a signed release.

The journal protocol applies to installations started by a generated installer
that implements it. Staging left by earlier installers has no supported
automatic recovery record. A process stopped before publishing its journal can
leave private staging, but it has not started replacing executables. These are
cooperating installation and recovery transactions; the complete family does
not switch atomically, and file flushing does not establish a power-loss
durability guarantee.

`-Json` keeps stdout machine-readable and includes the installed executable
receipts; progress and `-Verbose` diagnostics go to stderr. `-Help` performs no
download or installation. Agent-skill installation remains outside this
generator's scope. The separate `generate-release`
authenticated snapshot engine remains a distinct command and policy format.

```bash
bash scripts/tests/test_install_gen_windows.sh
bash scripts/tests/test_install_gen_windows.sh --recovery-only
bash scripts/tests/test_install_gen_windows_policy.sh
```

The regression exercises actual generated programs, genuine Go-produced Windows
PE files, ZIP parsing, Minisign verification, cache and replacement operations.
Authenticated acquisition runs the actual HTTP request, redirect and streaming
implementation with a .NET response-handler fixture. It covers token priority,
paginated exact asset lookup, binary Accept headers, credential removal on signed
object-store redirects, refusal without anonymous fallback, and offline reuse
without credentials. Public latest discovery exercises API rate limits and
injected transport failures, exact relative/encoded tag redirects, redirect
limits, unsafe destination refusal, and draft/prerelease metadata refusal.
Portable PowerShell runs use explicit host/HTTP adapters
and a labelled move failure injection for rollback. The recovery controls also
forcibly terminate real PowerShell processes after actual replacements and after
completion-marker publication, then exercise refusal, exact restoration and
another interrupted recovery. The focused mode keeps the same per-command
deadlines; `--baseline-project DIR` can include a frozen pre-recovery checkout's
actual generated installer in the same comparison. These portable tests do not
establish native Windows ACL/NTFS behavior, power-loss durability or successful
live GitHub acquisition.
The policy regression exercises the actual configuration and publication naming
helpers, explicit signing-key scope, executable-family limits and refusal before
any existing installer or publication history changes.

### Optional source fallback on Windows

Prefer the selected release while permitting an unavailable release to fall back
to a source build with the existing Git and compiler installations:

```powershell
.\install.ps1 -AllowSourceBuild -Yes -Json
.\install.ps1 -AllowSourceBuild -Version v1.2.3 -Yes -Json
```

A known release uses its exact `refs/tags/TAG`; only unavailable latest-release
discovery without a selected tag uses `HEAD`. This includes transport failures,
owned request deadlines and HTTP 408/429/5xx at discovery, authenticated release
metadata or primary-payload acquisition. Public 404/410 can establish absence.
A complete authenticated inventory can also prove the primary is absent, while
an authenticated HTTP 404/410 remains ambiguous and is refused.

The same selected credential authenticates API and Git requests. HTTP 401/403,
malformed metadata, missing checksum/signature proof and invalid cached or
downloaded release bytes cannot authorize source execution. A complete verified
cache is used before fetching its release again. Freshness metadata failures
keep a verified release; they are not acquisition failures. Explicit interruption
returns exit `5` and does not install either source or the verified old release.

The existing pinned source compiler and complete-family transaction apply.
Source failure never retries `HEAD` for a selected tag or silently installs an
older release. JSON adds `source_fallback` with the acquisition stage, requested
ref and known release version, alongside durable unsigned source provenance.
`-Yes` grants replacement permission only; `-AllowSourceBuild` grants build
consent. Offline and recovery modes refuse this consent.

### Optional stale-release source upgrades on Windows

Generated Windows installers can verify the latest release and build a newer
source commit when it exceeds an explicitly chosen commit-distance threshold:

```powershell
.\install.ps1 -AllowSourceBuild -SourceIfStale 10 -Yes -Json
```

Both freshness flags are required for the staleness decision. The threshold is
a canonical integer from `0` through `999999`; equality keeps the release.
Empty, fractional, exponent and noncanonical string values are refused before
acquisition. Omit `-Version` for latest-release mode.
`-Offline`, `-Recover`, `-FromSource` and `-SourceRef` cannot be combined with this
mode. `-Yes` permits replacing existing executables and does not itself consent
to source execution. Existing Git and the configured compiler are required only
if a source build is selected; no compiler is provisioned automatically.

The installer completes release checksum, configured Minisign signature,
archive and PE validation before querying freshness. It then resolves the
release tag and the observed default-branch head and verifies their ancestral
comparison through bounded GitHub API requests. Private repositories use the
same selected token as release acquisition; metadata redirects are refused.
Unavailable, malformed, denied or divergent metadata reports unknown freshness
and installs the already verified release. A failed release integrity check
never selects source.

A stale decision builds the exact observed commit, preserving the pin if the
branch moves later. The existing source compiler and complete-family installation
transaction apply, including input rechecks, rollback and a durable unsigned
build receipt. JSON reports a `freshness` object and identifies a source result
with `method: "source"` and `signed_release: false`. Failed source compilation
does not replace the existing installation with a partial family. See the
explicit source mode below for language requirements and retained diagnostics.

### Explicit source installation on Windows

A generated installer for `language: rust`, `language: go`, `language: bun` or
`language: typescript` can build and install its complete configured executable
family using **existing Git and compiler installations**:

```powershell
.\install.ps1 -FromSource -SourceRef refs/tags/v1.2.3 -Yes -Json
.\install.ps1 -FromSource -SourceRef 0123456789abcdef0123456789abcdef01234567 -SourceTimeout 1800 -Yes
```

Replace the example commit with the intended full source SHA. `-SourceRef`
accepts `HEAD` (the default), a full commit SHA, `refs/heads/BRANCH`, or
`refs/tags/TAG`. Git resolves the selected ref once; the receipt records the exact
fetched commit, and an explicit commit must match it. Source selection uses the
configured repository. Go supports `source_subdir` plus the primary
`source_entry` override:

```yaml
language: go
source_subdir: project
source_entry: apps/primary
workspace_binaries: [app, helper]
```

This selects `project/apps/primary` for `app.exe` and `project/cmd/helper` for
`helper.exe`. Without an override, the primary uses `cmd/<name>` when present
and otherwise the module root. Every companion requires its own `cmd/<name>`
directory. The selected project must contain `go.mod` or belong to a committed
workspace selected by the nearest `go.work` inside the fetched repository. A
moduleless workspace root can select separate `cmd/<name>` command modules.
The [committed Go workspace rules](#committed-go-workspaces) apply to both source
engines, including local replacements, workspace vendoring and receipt fields.
Source paths must be relative and Windows-safe. The installer rejects tracked symlinks, submodules,
case aliases and file/directory collisions before checkout. It resolves every
selected package and requires `package main` before the first build. Per-target
workspace lists also apply to source builds, including ARM64-specific families.

For Rust, `source_subdir` selects the directory containing `Cargo.toml`:

```yaml
language: rust
source_subdir: project
workspace_binaries: [app, helper]
target_triples:
  windows/amd64: x86_64-pc-windows-msvc
```

The selected workspace must contain a committed `Cargo.lock`. Before compiling,
the installer reads Cargo metadata and requires exactly one workspace package
and binary target to provide each selected executable. A complete family may
span packages outside the workspace's default members. Set `source_package` to
restrict all selected binaries to one named package; a companion cannot silently
come from another package. For a singleton without `source_package`, Cargo's
current package or default workspace members apply. Rust uses binary names,
so `source_entry` must be unset.

One `cargo build --locked --release` invocation builds the selected family for
the configured Windows `target_triple` into a new private target directory.
The target must match the installation architecture; the caller must already
have its Rust standard library and native linker installed. GNU and MSVC target
selectors remain distinct. The command explicitly selects its target and target
directory and removes inherited `RUSTFLAGS`, `CARGO_ENCODED_RUSTFLAGS`, and
`CARGO_BUILD_RUSTFLAGS` while preserving committed Cargo configuration, including
project-specific cfg and linker flags. Inherited compiler wrappers are cleared.
`RUSTUP_AUTO_INSTALL=0`
prevents repository toolchain files from implicitly installing a compiler.
Cargo's actual compiler-artifact messages must name exactly the selected
providers and private executable paths before PE architecture checks and
installation proceed. Missing or stale locks, ambiguous providers and partial
compilation failures leave the existing installation unchanged.

For Bun and TypeScript, `source_subdir` selects the project containing a committed
`package.json` and `bun.lock` or `bun.lockb`:

```yaml
language: typescript
source_subdir: project
source_entry: src/primary.ts
workspace_binaries: [app, helper]
```

The generated Bun/TypeScript source policy contains `language`, `subdir` and
`entry`; the latter two retain the configured `source_subdir` and `source_entry`.
The optional `source_entry` selects only the primary executable. Otherwise the
primary uses the project's `package.json` `bin` string or its exact entry in the
`bin` object. Every companion requires its own exact `bin` object key, using the
selected executable name without `.exe`; a scalar `bin` cannot supply companions.
For the example above, `helper.exe` requires a `helper` entry in that object.
Entries may begin with `./`, but must resolve to regular committed relative
files inside the selected project. The complete family is resolved before
installation or compilation; missing entries, linked files and unsafe paths are
refused.

The installer uses the existing Bun executable, clears inherited `NODE_OPTIONS`
and `BUN_OPTIONS`, and preserves other dependency/cache settings. It runs one
`bun install --frozen-lockfile` for the family, then `bun build --compile` for
each selected entry into a private output directory. Windows x64 selects
`bun-windows-x64-baseline`; Windows ARM64 selects `bun-windows-arm64`. Every output
must pass PE machine validation for the installing architecture. The shared
pinned-commit and tracked-source checks still apply after dependency installation
and compilation, including the committed manifest and lockfile. A failed member
or changed input prevents activation of the entire family.

`-FromSource` explicitly authorizes execution of repository and dependency build
code under the caller's account. It is separate from release acquisition:
`-Version`, `-Offline` and `-Recover` cannot be combined with it, and a failed
release checksum or signature never invokes it. `-Yes` only permits replacement;
it does not select source execution. Other language configurations continue to
generate normal release installers but have no Windows source route.
The installer does not provision compilers or native dependencies. For Go it forces
`GOTOOLCHAIN=local`, disables user Go configuration and workspace selection,
clears inherited Go flags, and builds for the detected Windows architecture.
Go uses readonly module resolution, or the selected project's vendor directory.
Normal dependency/cache settings otherwise apply; this is not a hermetic build
or a pinned compiler/dependency authentication contract.

Source fetches use HTTPS Git at the configured GitHub repository. Private fetches
use the same token priority as release downloads, supplied through a
repository-scoped environment header with Git 2.31 or newer. The token is not put
in Git arguments, remote URLs or retained Git configuration. Redirects, user Git
configuration, credential helpers, hooks and submodule fetching are disabled for
the fetch. A failed credential does not authorize anonymous retry. Source code
execution is not sandboxed, and ordinary caller environment variables remain
available to compiler processes.

Every selected executable must compile and pass the same Windows PE architecture
admission as a release payload. The installer rechecks the pinned commit and all
tracked source bytes after compilation. It binds each compiled executable's
SHA-256 and length again when copying into the private installation transaction.
Source builds then use the same complete-family lock, journal, rollback and
`-Recover -Yes` behavior as release installation. A missing provider, compilation
failure or changed source/output leaves the previous family intact.

Source JSON reports `method: "source"`, `signed_release: false` and
`signature_verified: false`. Its `source` receipt includes the requested ref,
resolved commit, tracked-source digest, compiler identity, source selectors,
per-executable entries and byte evidence. For Rust, `cargo_target` records the
explicit compilation triple, `cargo_version` identifies Cargo, and each
`source_entries` row retains its Cargo binary, package ID, manifest and source
path. For Go, `go_target` records the actual `windows` OS and Go architecture;
`release_target_triple` is labeled as the configured release selector rather
than a claimed Go compiler ABI. Bun and TypeScript receipts retain the compiler
identity, explicit `bun_target`, each selected `source_entries` path, the committed
lockfile's SHA-256 and byte length, and the package manifest's SHA-256. These
receipts bind the complete locally compiled family to its source inputs; they
do not claim a signed release or a fully authenticated dependency graph. A small
private receipt remains at `CacheDir/source-receipts/TOOL/COMMIT-UNIQUE.json`, and
`source_receipt` returns its path, hash and length. This receipt describes verified
compiled bytes and is written before activation; its existence alone does not
claim a successful installation.

Successful temporary source work is cleaned up. A failure retains its private
source, compiler output and per-command stdout/stderr logs; JSON includes the
`source_diagnostics` directory. `-SourceTimeout` bounds each Git/compiler command and
its output draining, defaults to 3600 seconds, and accepts 1–86400 seconds. On
timeout, the installer attempts to terminate a live parent and its descendants. A child already
orphaned by an exited parent cannot be reliably identified through that process
handle; the installer closes its pipes and returns a timeout without claiming
that orphaned children were stopped.

The focused regression uses the public generator, real Git commits and annotated
tags, the installed Go and Rust compilers, genuine Windows PE files, and real
Minisign verification on the ordinary release route. The portable Rust fixture
requires the `x86_64-pc-windows-gnu` standard library and a working MinGW linker;
`DSR_TEST_WINDOWS_RUST_TARGET` can select another installed x64 Windows target:

```bash
bash scripts/tests/test_install_source_windows.sh
# Optionally compare the same source caller flow against a frozen older checkout:
bash scripts/tests/test_install_source_windows.sh --baseline-project /absolute/old-checkout
# Compare Rust support with a checkout that already has Go source installation:
bash scripts/tests/test_install_source_windows.sh --rust-baseline-project /absolute/pre-rust-checkout
```

It covers complete-family builds and updates, source/output binding, later
compiler failure, missing/stale Cargo locks, ambiguous Cargo providers, explicit
package selection, rollback, durable receipts, inherited output-pipe deadlines,
and preserved signed release generation. Portable runs adapt native host detection
and the Git/HTTP remote boundaries to local repositories and signed fixtures.
They do not establish live GitHub, native Windows ACL/NTFS, or Windows descendant
process qualification.

The focused Bun/TypeScript source-family regression uses genuine PowerShell,
Git and Bun, with Bun producing actual Windows PE executables:

```bash
bash scripts/tests/test_install_source_windows.sh --bun-only
```

Its Linux run adapts native host detection and source/download transport
boundaries while exercising the generated installer, entry and lock admission,
compilation, receipts and complete-family installation transaction. Native
Windows filesystem and process qualification remains pending; the portable
result does not establish it. The ordinary signed release route remains
separate, and a signature failure never authorizes source compilation.

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

Rust source builds use the installed compiler they probe, a private Cargo output
directory, and the installing machine's target. Ambient `RUSTC`,
`RUSTC_WRAPPER`, and `RUSTC_WORKSPACE_WRAPPER` cannot substitute a different
compiler or wrapper. Inherited `RUSTFLAGS`, `CARGO_ENCODED_RUSTFLAGS`, and
`CARGO_BUILD_RUSTFLAGS` are removed so the pinned project's committed
`.cargo/config.toml` can supply its own compiler flags. Existing compiler homes
and dependency caches remain available; this is a locally built source result,
not a hermetic or signed release.

### Committed Go workspaces

Bash and native Windows source installers support tools whose commands depend on sibling
modules through a committed `go.work`. Starting at `source_subdir`, the installer
selects the nearest `go.work` within the fetched repository. A workspace outside
that checkout, including the caller's `GOWORK`, cannot select source inputs.
Without a selected workfile, the existing standalone-module behavior applies.

For example, this repository layout needs no `replace` directives in the
application's `go.mod`:

```text
go.work                 # use (./app ./shared)
app/go.mod
app/cmd/app/main.go      # imports the shared module
app/cmd/helper/main.go
shared/go.mod
shared/shared.go
```

Use `source_subdir: app` and `workspace_binaries: [app, helper]`. A repository
root containing only `go.work` is supported as well: `use ./cmd/app` and
`use ./cmd/helper` can select separate command modules with the ordinary
`cmd/<binary>` entry selection. The workfile and every selected module's
`go.mod` must be committed regular files. Relative sibling paths such as
`../shared` are accepted when their entire path stays inside the fetched
checkout; outside paths and symlink traversal are refused before package
resolution or compilation.

The installed Go toolchain parses the workspace and module files. Workspace
`replace` directives take precedence over module directives. Active local
replacements must resolve to committed modules inside the same checkout;
replacement dependencies do not contribute their own `replace` directives.
This follows Go's [workspace and replacement rules](https://go.dev/ref/mod#workspaces)
without fetching another local checkout or running `go work sync`.
An outside-root wildcard replacement is still refused when only some of its
versions are overridden by the workfile: the installer does not infer that all
other versions are unreachable. Remove that local rule or override its complete
selection in `go.work`.

Workspace builds use `-mod=readonly`, or `-mod=vendor` when the workspace root
contains a committed `vendor/modules.txt` marked as a workspace inventory by Go.
A legacy single-module vendor inventory and a member module's own vendor
directory do not select workspace vendoring. In vendor mode, replacement
dependencies come from the committed vendor tree; their original local
directories need not exist or lie inside the checkout because Go does not read
them. The main workspace modules still require committed, in-checkout files.
Ambient `GO111MODULE`, `GOWORK`,
`GOFLAGS`, and persisted Go configuration cannot override this selection, and
`GOTOOLCHAIN=local` prevents an implicit compiler download.

On a machine without Go, Bash installers can build these workspaces with the
existing `--from-source --install-toolchain` consent. The private bootstrap reads
compiler requirements from the same committed workfile, including when the
workspace root has no `go.mod` or a member module specifies an older Go version.
It then uses the installed compiler to parse and validate the complete workspace
before resolving packages or building any executable.

Successful source receipts add `go_workspace`, containing the checkout-relative
workfile path and SHA-256, each main module's path, module identity and `go.mod`
SHA-256, active local replacement identities, and the vendor selection. A
vendored workspace also records `vendor_modules_sha256` for its inventory. The
existing source-commit, complete-family, output-hash and tracked-input checks
still apply. A successful compiler exit cannot publish a receipt after a
tracked workspace or module file changes.

The focused regression builds and executes a real offline Go executable family:

```bash
bash scripts/tests/test_install_source.sh --go-workspaces-only
```

The generated PowerShell installer has matching Go workspace coverage, including
genuine Windows x64 and ARM64 PE compilation and the complete installation
transaction:

```bash
bash scripts/tests/test_install_source_windows.sh --go-workspace-only
```

That portable caller fixture uses PowerShell, real Git and Go, and local
transport. It does not claim native Windows filesystem, ACL or process testing.
Pass `--workspace-baseline-project /path/to/earlier/checkout` to exercise the same
committed sibling source through an earlier generated installer.

It covers ancestor and nested workfiles, moduleless roots, local replacement
precedence, self-contained workspace vendoring, Git line-ending conversion,
inherited environment overrides, empty checksum files, and refused outside,
missing or linked modules. The optional
`DSR_TEST_INSTALL_SOURCE_MODULE` selects an earlier source engine for the same
before/after fixture; it does not replace the Git parser or compiler.

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

On Linux, source fallback also covers a known native libc with no compatible
configured release target. For example, a GNU-only release installer can build
natively on a musl host when `--allow-source-build` is present. It still resolves
the selected version first: an explicit or discovered release version builds
that exact tag; unavailable latest-release discovery follows the existing
default-branch policy. No release payload for another ABI is downloaded.
Installation still refuses before discovery when source consent is absent,
libc is unknown, or an explicit `--libc` request cannot be satisfied. An
unsupported host also remains an error.

The focused regression adapts libc discovery while using real local Git tags,
Go compilation and installed executables. It is also included in the full
generated-source installer suite:

```bash
bash scripts/tests/test_generated_installer_source.sh --libc-source-fallback-only
```

When a required compiler is missing, or the installed Go compiler cannot run or
is older than the pinned source requires, add **`--install-toolchain`** to prepare
a compatible compiler inside that source attempt's private build directory:

```bash
# Build this release tag, preparing a compiler only if required.
bash install.sh --from-source --version v1.2.3 --install-toolchain

# Prefer a verified release; permit source fallback and private compiler setup.
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
| Go | Requirements come from the nearest committed `go.work` within the fetched checkout, or the selected module's `go.mod` when no workspace applies. The higher of a numeric `toolchain` preference and the mandatory `go` version selects the compiler. An omitted `go` directive means 1.18 for `go.work` and 1.16 for `go.mod`, following Go's defaults. An exact patch stays exact, while `X.Y` selects the newest stable patch in that minor. Unsupported or unavailable requirements fail. |
| Rust | Rustup reads the repository's `rust-toolchain.toml` or legacy `rust-toolchain` file. Without one, the private installation selects stable. Ambient parent overrides are not adopted as project requirements. |
| Bun / TypeScript | An exact numeric `packageManager: bun@X.Y.Z` is honored; otherwise an exact numeric `engines.bun` can pin the version. Unpinned recipes use the latest stable Bun release and must satisfy any declared engine range. Unsupported pins or incompatible ranges fail. |

With explicit bootstrap consent, the installer probes an existing Go compiler
with automatic Go toolchain downloads disabled, outside any ambient workspace
or user Go environment file. Its released version must meet the selected
committed `go` requirement and any numeric `toolchain` preference. A compatible
compiler remains in use, including one newer than the preference; the installer
does not download a downgrade. An older, unavailable or unidentifiable Go
compiler selects the same verified private bootstrap used when Go is absent.
A numeric `toolchain` preference older than the file's `go` requirement cannot
lower that mandatory requirement. This is a compiler-selection safeguard; Go
still validates the complete module or workspace and can reject it. Malformed
or duplicate version directives are refused before downloading anything. A probe
timeout or interruption is terminal.

Without `--install-toolchain`, no compiler download or replacement is authorized:
an existing incompatible compiler can still fail the source build. Global Go
executables, homes and profiles remain untouched even when a private compiler
is selected. Rust and Bun retain their existing working compilers. Rustup
proxies can exist without the selected compiler: with bootstrap consent, a
bounded probe checks availability with automatic Rustup installation disabled.
A missing selected Rust compiler permits a private bootstrap; its probe timeout
or interruption also fails before downloading anything.

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

The workspace bootstrap regression runs the generated installer both with no Go
on PATH and with an explicitly simulated older compiler. It extracts a genuine
distribution, builds the pinned workspace, then executes and verifies the
installed family. Only distribution delivery and the old compiler probe are
adapted; the private compiler and generated programs are real. It has its own
test entrypoint so cold compiler setup retains the ordinary per-file deadline:

```bash
bash scripts/tests/test_generated_installer_workspace_bootstrap.sh
```

Set `DSR_TEST_GO_ARCHIVE` to reuse a matching genuine Go distribution archive;
otherwise the fixture packages the installed Go runtime. `DSR_TEST_ROOT` can
select a frozen earlier checkout for the same caller's before/after comparison.

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
