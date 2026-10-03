# Changelog

All notable changes to **dsr** (Doodlestein Self-Releaser) are documented here.

Beginning with v0.1.1, releases use annotated semantic-version tags and manually
published GitHub Releases. The platform-neutral distribution consists of the
`dsr` Bash entry point, its source modules, the installer, and the agent skill.

Commit links point to: `https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/<hash>`

---

## v0.2.2 -- 2026-10-02

- Strict release creation keeps adapter diagnostics separate from JSON. An
  already repaired strict draft can be published with `dsr release finalize`
  using its original private creation response. Finalization requires the same
  nonce-bound release ID and metadata, frozen explicit configuration, a clean
  tagged source, and every expected signed asset. Separate complete asset
  inventories and source checks run before and after publication; private
  pending and completion receipts preserve recovery evidence. This bounded
  route refuses inventories of 100 or more assets and never uploads, recreates,
  deletes, or dispatches a release.

- `dsr release source-only` publishes installer/source-only GitHub Releases with
  zero uploaded assets. It requires explicit configuration, reviewed notes,
  disabled dispatch, and a clean checkout whose peeled tag matches GitHub.
  Creation custody, metadata, tag identity, and both asset inventories are
  verified before publication; failures restore the newly owned release to
  draft. Source publication receipts remain separate from build manifests.
  Bounded read-only reconciliation tolerates delayed draft visibility. Explicit
  private pending-receipt recovery retains the original record and cannot
  recreate a release or adopt an unrelated draft.

- Strict source snapshots support direct contained relative symlinks, preserving
  their tracked target bytes and executable/file modes. Link admission and both
  local and generated Unix verification reject paths that traverse another
  symlink, including an alias followed by `..` that would escape the snapshot.
  Symlink chains are conservatively refused; use a direct contained target.

### Qualification

The changed recovery paths pass 95 strict-draft, 175 source-only and 23 binary
recovery checks through the required remote test lane, plus syntax and focused
warning-level ShellCheck. Actual GitHub recovery published FrankenRedis v0.1.1
and the source-only ACFS v0.10.0 release; independent public readback passed.
FrankenRedis published-artifact runtime and prior-release upgrade checks passed
91 assertions on an independent Linux host.

The earlier symlink-candidate Bats comparison reported 288 passed/10 failed at
v0.2.1 and 298 passed/the same 10 failed before the later release-recovery
additions; all 10 added symlink assertions passed.
A complete lint or native Rust-fixture pass is not claimed. Existing strict
Unix audit performance and future RCH-native routing work remain tracked in
[#22](https://github.com/Dicklesworthstone/doodlestein_self_releaser/issues/22)
and [#17](https://github.com/Dicklesworthstone/doodlestein_self_releaser/issues/17).
The distribution remains the existing signed, platform-neutral Bash bundle. The legacy
SPDX license label does not represent the bundled license rider; complete
license bytes remain in both source archives, and metadata classification is
tracked in [#24](https://github.com/Dicklesworthstone/doodlestein_self_releaser/issues/24).

## v0.2.1 -- 2026-10-01

- Rerunning `install.sh` never upgraded an install made with `--version`:
  that clone is a shallow, detached checkout of a tag whose fetch refspec
  only re-fetches the same tag, so `git pull` reported "Already up to date"
  and the installer printed "Updated dsr to latest" while the old version
  stayed in place. An explicit `--version` was likewise ignored whenever a
  clone already existed. The installer now fetches and checks out the
  requested tag in place, moves a pinned clone back onto `main` when no
  version is given (the default), and pulls only a clone that is on a
  branch. If a fresh clone fails after an in-place update could not be
  done (for example a mistyped `--version`), the previous clone is restored
  instead of leaving `dsr` pointing at a missing checkout.

## v0.2.0 -- 2026-10-01

A large hardening release: strict release contracts, reproducible packaging,
health/capacity-aware host scheduling, Windows cross builds via cargo-xwin with
private Cargo caches, and fail-closed generated installers. Minor version bump
because several defaults changed (see the upgrade notes).

### Upgrade notes

- Strict (release-contract) Linux Rust builds with no `linux_glibc_floor`
  configured now build at the 2.28 default floor via `cargo zigbuild`, which
  needs cargo-zigbuild >= 0.23 and zig on the Linux build host (a clear
  exit-4 error names this otherwise). Repos that must link the host glibc set
  `linux_glibc_floor: native` for that platform.
- `dsr release` never replaces a published asset. v0.1.2 deleted and
  re-uploaded a same-name asset; now an asset whose bytes differ fails that
  upload (exit 1) and leaves the published bytes untouched. The error names
  the asset and the `gh release delete-asset` command to use when it is stale.
- Selector slot files written by v0.1.2 (a bare run id in
  `~/.local/state/dsr/selector/locks/<host>/*.lock`) are treated as occupied
  until inspected. If no v0.1.2 build is still running, remove leftovers
  before the first v0.2.0 build, or that host stays at capacity.
- `dsr docker release` publishes signed, SBOM-attested images and verifies
  them against a keyless policy: pass `--certificate-identity` and
  `--certificate-oidc-issuer` (or set `DOCKER_CERTIFICATE_IDENTITY` /
  `DOCKER_CERTIFICATE_OIDC_ISSUER`); syft is required, and `:latest` is not
  pushed.
- Generated installers require `minisign` on the client when the repo
  configures a public key, refuse a symlinked existing binary, and build from
  source only under Bash 4+.

### Fixed in the v0.2.0 release review

- Generated `curl | bash` installers aborted on stock macOS Bash 3.2 for every
  archived release, right after the checksum passed: archive extraction used
  an associative array, and empty-array expansions tripped `set -u` before
  Bash 4.4. Duplicate-member detection is now portable, and source builds
  (which need Bash 4) refuse with a clear message instead of failing midway.
  The integrity suite runs the generated installer under `/bin/bash` 3.2 when
  one exists (or `DSR_TEST_LEGACY_BASH`).
- `install_gen_create` printed ShellCheck findings on stdout ahead of the
  installer path, so callers received a garbage path whenever the generated
  script had a finding (it always had two: the deliberate early-expanded
  cleanup traps, now annotated).
- Generated installers exited 1 with no message when the install directory
  was a symlink (common with dotfile managers); they now install into the
  directory it resolves to.
- `--skip-checks` failed with exit 4 for tools configured only in `repos.d`
  (no `repos.yaml` entry), so `dsr fallback --skip-checks` could not release
  them. Such tools have no required set and skip as before; a `repos.yaml`
  that exists but cannot be read still fails closed.
- Host capacity acquisition failed every build when the state directory was a
  symlink; the selector now works through the physical path.
- Minisign's password prompt was hidden, so signing with an encrypted key
  looked hung. Its stderr is visible again.
- Two concurrent xwin builds of the same target on one host: the second gave
  up immediately (at verify time, discarding a finished compile). It now waits
  up to `DSR_XWIN_TOOLCHAIN_LOCK_TIMEOUT` seconds (default 1800).
- `dsr build --sync-only` quarantined the existing artifacts without building
  anything, so a following `dsr release` found an empty directory.
- `dsr docker release` rejected the `--certificate-*` options its module
  requires, and `dsr --json docker build|release` wrote two JSON documents to
  stdout; the module result now sits inside the envelope as `.result`.
- Release build plans pinned an xwin output as the selected candidate before
  checking that it contained exactly the selected executables, so a retry
  into the same `--output-dir` re-imported the bad output forever instead of
  compiling again. The inventory is now checked before anything is pinned;
  import failures of a valid selection still recover without recompiling.
- Several drift/corruption test cases appended to fixture files that dsr
  stages read-only (0400). Run as a non-root user they corrupted nothing, so
  dsr rightly succeeded and the cases failed; the fixtures now unlock their
  copy first, and dsr's detection is exercised again.
- `shellcheck -S warning` is clean again across `dsr`, `src/`, `scripts/` and
  `install.sh` (16 warnings had accumulated since v0.1.2; the intentional
  early-expanded cleanup traps are now annotated).

### Known issues

- `dsr --dry-run release` of a strict contract that uses minisign fails when
  the signatures do not exist yet (plan mode cannot sign). Real releases are
  unaffected.
- On a macOS dispatcher, slot ownership compares `ps`/`sysctl` timestamps that
  follow `TZ`; concurrent dsr runs with different `TZ` values can reclaim each
  other's slots.
- Native (non-xwin) Rust builds still symlink the host's `~/.cargo/registry`
  into the release snapshot (#15); xwin builds use private cache snapshots.

### Changes since v0.1.2

- A cancelled build (Ctrl-C, or TERM to the orchestrator) left its per-target
  source copy behind: the worker TERMs the build's process group, which never
  reaches the removals after the build command, so each interrupted run kept a
  full repo copy (`dsr-build-*`) in `/var/tmp` or the host's build_root. The
  native build now removes its stage roots on INT/TERM as well. Test suites
  no longer touch the operator's `~/.config/dsr/repos.d` (act_runner.sh reset
  the fixture's `ACT_REPOS_DIR` when sourced, so the native suite created an
  empty `repos.d/tool.yaml` there).

- `dsr doctor` (full mode) now runs the artifact-naming consistency check
  from `dsr repos validate --naming` and reports drifting repos by name, so a
  config/install.sh/workflow naming mismatch shows up in routine health
  checks instead of at release time (bd-1tv.5).

- Release checksum generation always failed on macOS dispatchers: the
  default (empty) exclusion regex was compiled for validation, and macOS
  regcomp rejects an empty pattern. An empty exclusion is now never compiled.
  The checksum-sync protected-root guard also compares against the
  symlink-resolved protected paths, so a protected projects root reached
  through a symlinked ancestor is still refused.

- A non-interactive run whose act had no runner-image mapping (no `-P` and
  no actrc) died inside act's first-run image survey on EOF. dsr now stops
  before launching act with dependency exit 3 and the remedy
  (`act_overrides.platform_image` or a `-P` line in `~/.actrc`); repo
  overrides and operator actrc files keep precedence (bd-1d26).

- Strict release-contract builds skipped the Linux glibc floor entirely, so
  focr v0.9.1 first came out needing GLIBC_2.39 despite a configured 2.17
  floor. Strict Linux Rust builds now get the same floor as ordinary builds:
  the zigbuild cargo shim is staged beside the snapshot (never inside it),
  the floor is recorded in the build-influence receipt, and a collected
  binary above the floor fails the target with a message naming the fix. An
  explicitly configured floor is also enforced when the build_cmd or a cross
  linker owns the toolchain.

- `--parallel` targets on one host whose build writes the same in-tree file
  (`go build -o ntm ./cmd/ntm`) overwrote each other, and one lane collected
  the other's binary (ntm 1.36.0 linux/arm64 received an amd64 build; the
  architecture check caught it). The orchestrator now detects the shared
  output: the later target builds in a private source copy that is removed
  after collection, or, where a copy cannot help (strict snapshots, Windows
  hosts, an absolute shared GOBIN), waits for the conflicting build.

- A target whose host was at its concurrency limit failed with "Host
  capacity acquisition failed" after a fixed 300s while a peer build held the
  slot for hours. Build workers now queue for one build timeout
  (`DSR_BUILD_TIMEOUT`, or `DSR_SELECTOR_WAIT_TIMEOUT`), poll with capped
  backoff, report their wait every minute, and name the host, wait and fix
  when the budget really expires.

- Strict source verification ran each host's source-snapshot check inside a
  `while read` host loop without closing stdin, so a stdin-reading transfer
  could skip verifying later hosts (the same drain that made Windows sync
  copy only the first sibling crate, fixed in 1b45cf7). The call and the
  remaining Windows manifest transfers now close stdin, and a regression test
  covers every sibling on every host.

- Configured `include_files` (LICENSE, README.md, ...) were silently dropped
  from release archives whenever the build lane had already wrapped the
  payload in an archive: the payload-preserving repack kept the lane's exact
  member set, and a same-format lane archive was reused untouched, so
  `rano` v0.2.1 built without the MIT notice v0.2.0 carried and no warning
  ever fired (#16). The packager now compares the lane archive's members
  against the configured includes, stages any missing ones from the repo
  checkout into the rebuilt archive (same safety rules as payload members:
  no path escapes, no links, no shadowing of a payload member), warns about
  a configured include that is absent from the checkout, warns instead of
  mutating when the lane archive already occupies the release name, and
  warns when `local_path` cannot be resolved at all.

- Windows hosts whose OpenSSH `DefaultShell` is PowerShell could not run any
  generated command: a command sent as `powershell -Command "..."` is parsed
  by that outer PowerShell first, which expands every `$variable` inside the
  double quotes to nothing before the inner powershell sees the script
  (observed as "Missing variable name after foreach" parse errors within
  seconds on wlap), and cmd-style lines (`cmd /c "if not exist ..."`,
  `where rsync >NUL`, `rmdir /s /q`, `cd /d ... && set ...`) were re-parsed
  by PowerShell too, so source sync failed at `mkdir` and the rsync probe was
  always negative. Every PowerShell script now travels as `-EncodedCommand`
  (UTF-16LE base64, `_act_windows_encoded_powershell`), and every cmd.exe
  line goes through `_act_windows_cmd_via_powershell`, which hands the
  base64-decoded line to `cmd.exe /d /s /c` verbatim and propagates its exit
  code. Both work under cmd.exe and PowerShell login shells. Note: a
  PowerShell 5.1 login shell reports any non-zero remote exit as 1 over
  OpenSSH; dsr's Windows paths rely on zero/non-zero only. Test mocks decode
  encoded commands before asserting on them. rsync to Windows receivers now
  uses `--blocking-io` on a dedicated (non-ControlMaster) ssh transport:
  over a multiplexed channel the Windows rsync failed intermittently with
  "safe_write ... Resource temporarily unavailable (11)" (exit 12); a
  Windows receiver that still drops the stream is retried up to three times
  (rsync is idempotent).
- Test mocks in `test_act_runner_native.sh` and `test_act_orchestration.sh`
  decode `-EncodedCommand` payloads so assertions see the script the host
  would run.

- Post-build archive packaging never wraps an existing archive inside
  another archive. When the build already produced an archive for a target
  (the native workspace collector always emits tar.gz/zip) and the repo's
  `archive_format` asks for a different format, the new `src/packaging.sh`
  module extracts the payload and rebuilds the requested format
  independently, then proves member-set parity between both archives.
  Previously the packager treated the built `.tar.gz` as a raw binary and
  shipped a `.tar.xz` that contained the `.tar.gz` plus `include_files`
  (observed on the published mcp_agent_mail_rust v0.3.30 and v0.3.31
  assets, which had to be repacked by hand). Repos whose installers enforce
  an exact flat member contract (payload binaries only) can now also set
  `include_extra_files: false` (or `flat_archive: true`) in their repos.d
  yaml to keep configured `include_files` out of release archives entirely
  — staging, packaging, and the strict workspace-archive validators all
  honor the flag. Default behavior is unchanged: `include_files` continue
  to ship inside archives unless a repo opts out.
- `dsr repos validate` now cross-checks `repos.yaml` against
  `repos.d/<tool>.yaml` and fails on divergence: mismatched keys, build keys
  present only in the registry (the build runner ignores them), `repos.d`
  files not registered in `repos.yaml`, and `repos.d` files whose name does
  not match their declared `tool_name`. Registry-only tools (no `repos.d`
  file) validate with a warning, and `dsr repos add` now warns that the tool
  is not buildable until a `repos.d` file exists. Precedence is documented in
  the README: repos.d is the build authority, repos.yaml the registry (#12,
  #13).
- Rust builds derive `CARGO_BUILD_TARGET` from `target_triples.<platform>`
  (or the platform's standard triple) when the platform env does not set one,
  and every collected native artifact is validated against the requested
  platform's executable format before packaging — a native-classified build
  can no longer publish a wrong-architecture binary or lose a successful
  compile to a `target/release` vs `target/<triple>/release` path mismatch.
  Build commands receive `DSR_TARGET_OS/ARCH/PLATFORM/TRIPLE`; opt out with
  `derive_cargo_build_target: false` (#7).
- Ordinary Linux Rust builds targeting `*-linux-gnu` default to a portable
  glibc floor of 2.28: a staged cargo shim routes `cargo build` through
  `cargo zigbuild --target <triple>.<floor>` and the collected binary's
  versioned glibc symbols are asserted against the floor, so released amd64
  binaries no longer inherit the build host's glibc. Configure or disable
  with `linux_glibc_floor` (#9). The shim refuses cargo-zigbuild older than
  0.23.0, whose zig wrapper mishandles rustc's aarch64
  `--fix-cortex-a53-843419` erratum flag (#10).
- `dsr build` refuses to reuse a non-empty output directory: pre-existing
  artifacts are quarantined to a `.stale-<timestamp>` sibling (default
  tool-version directories) or the build aborts (custom `--output-dir`), so a
  rebuild for the same version can never republish a previous build's
  binaries under fresh names and checksums (#11).
- Windows build hosts fail fast — at sync, at build, and in
  `dsr repos validate` — when the resolved source root is not drive-qualified
  (`C:/...` or `/c/...`), instead of rsyncing to the wrong location and dying
  mid-build with an unexplained path validator error (#8).

- Strict release snapshots now default to `/var/tmp/.dsr-release-snapshots`
  instead of `/tmp`, matching the isolated Rust build root. On hosts where
  `/tmp` is a RAM-backed tmpfs a release wave could stage multi-GB source
  trees into memory and wedge the host (#6).
- `hosts.yaml` gains an optional per-host `build_root` that roots both strict
  snapshots and isolated Rust builds; unsafe values (relative, `..`, or under
  `$HOME` on the local host) fail closed. `DSR_STRICT_BUILD_ROOT` still wins.
- Remote and local staging now probe the root's filesystem (`findmnt` / GNU
  `stat`) and refuse to stage onto tmpfs/ramfs with an actionable error.
- Compat (unversioned) asset names derived from an `artifact_naming` pattern
  no longer keep a literal `v` when the pattern uses `v${version}`; previously
  `sbh-v${version}-${target_triple}` produced `sbh-vx86_64-unknown-linux-gnu`.

- Multi-binary native archives now honor configured `include_files`, including
  README, license, and notice files. Companion paths are validated and staged
  without allowing a missing file, symlinked path component, traversal, or
  binary-name collision to produce an incomplete archive.

## v0.1.2 -- 2026-08-02

- Host selection is health- and capacity-aware: `act_get_native_host`
  consults the selector between the per-repo `cross_compile` override and the
  static `platform_mapping`, so a second same-platform host absorbs overflow
  and covers an unhealthy, disabled, or sleeping primary. Every selector
  failure falls back to the previous behavior; `DSR_DISABLE_HOST_SELECTOR=1`
  opts out.
- Disabled hosts are no longer silently re-selected through the compiled-in
  default.
- Quality-check durations are measured in milliseconds on BSD/macOS instead
  of whole seconds (sub-second checks were recorded as `0ms`).

## v0.1.1 -- 2026-07-20

First formally tagged release of Doodlestein Self-Releaser.

### Bounded, Resumable Build Orchestration

- `dsr build --parallel[=N]` and `--jobs N` now run independent targets with a
  bounded, work-conserving scheduler instead of silently building serially.
- Target logs and result receipts are isolated by target and attempt, while
  final aggregation remains deterministic in requested-target order.
- Interrupted and partial runs preserve useful artifacts. Resume reuses only
  artifacts whose exact path, digest, size, and filesystem identity still
  match; failed, incomplete, or mutated targets rebuild.
- Cancellation drains descendant process groups and preserves exit 130. A
  partial run cannot publish an authoritative manifest or enter signing.
- Successful live builds now persist the parent coordinator state as
  `completed` before reporting success.

### Release and Quality-Gate Hardening

- Rust builds run with isolated Cargo configuration, target, and home state on
  native build hosts.
- Rust workspace version detection fails closed on ambiguous package versions.
- Quality-gate receipts require complete evidence and cannot turn missing or
  malformed result records into a false green.
- Strict source, artifact, manifest, and release-verification paths retain the
  existing fail-closed race and identity checks across Linux, macOS, and
  Windows build targets.

### Verification

- 85 orchestration assertions, 52 native-runner assertions, 28 SBOM tests, and
  the 16-case live build E2E pass, including durable completion-state and
  manifest verification.

## 2026-07-17 -- Fail-Closed Rust Workspace Version Detection

- Virtual Cargo workspaces now resolve versions through read-only Cargo metadata.
  A configured `main_package` selects that exact package; otherwise every
  publishable workspace member must agree on one version.
- A present but ambiguous or unreadable `Cargo.toml` no longer falls through to
  an unrelated root `package.json` or `VERSION` file. Version detection and tag
  creation fail closed instead of suggesting a fictitious release tag.
- Human, JSON, build, fallback, single-tool tag, and batch-tag paths share the
  same configured language/package authority and ambiguity checks.

---

## 2026-03-12 -- Curl|Bash Self-Installer for dsr Itself

Added a standalone `install.sh` so users can install dsr with a single `curl | bash` command and SHA256 checksum verification.

### Self-Installation

- `install.sh` -- curl|bash installer for dsr with verified checksum support ([c3f5715](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/c3f57152b44303265a9efc907971be98e8a7de3c))

---

## 2026-02-21 / 2026-02-22 -- License and Branding

### License

- License changed to MIT with OpenAI/Anthropic Rider ([1887257](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/18872575ce04e7379268dfe9119ef74496dd7b29))
- README license references updated to match ([3da6a58](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/3da6a583d7c644449ab0e5f4c1d3ffae366dba07))

### Branding

- GitHub social preview image (1280x640) added ([f4ccb37](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/f4ccb37d4a399d92794a61a7de1b79f46bdf8a2a))

---

## 2026-02-18 -- Remote Build Checksum Sync

### Build Infrastructure

- Auto-generate `SHA256SUMS` for remote builds and sync sibling crates so multi-crate Rust workspaces build correctly on remote hosts ([409bd5b](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/409bd5b252fbfd9706402a8274c0a7d7843201bc))

---

## 2026-02-03 / 2026-02-04 -- Multi-Binary Workspaces and Build Stabilization

Focused on making act-based builds and release uploads reliable for Rust workspace projects that produce more than one binary per crate.

### Multi-Binary Rust Workspace Support

- `workspace_binaries` support in act runner lets dsr build projects that produce multiple binaries from a single Cargo workspace ([028c75b](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/028c75b5934130643126a446397f249baa7cd728))
- Address review issues in workspace_binaries support ([c307162](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/c307162c4185cb8b98e00a7bc920d4dc4be6fd0b))

### Build Reliability

- Stabilize act runs and release uploads ([c41a8bb](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/c41a8bb3d5781765ec6d0845bf151bbff1898a3e))
- Escape tab literal in rename pairs and isolate per-target artifact dirs ([31018e7](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/31018e7aec2f6d70534606892d3ed748b825fa27))
- Resolve artifact name collisions in multi-target builds ([bdc6459](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/bdc6459ae9f04bc218744c77dc310f4d24c73a3d))
- Align artifact naming with workflow outputs ([be11876](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/be1187637de94f8ab3f7b0c099f020896206fd93))

### Env Var and Artifact Handling

- Fix three bugs in artifact handling and env var parsing ([18ef701](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/18ef701bd404423216c30d82831fe82cbc87eae6))
- Quote `env_pair` in Unix export to handle values with spaces ([7f23f88](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/7f23f88215c7af12891da3a9069c385c5a3babb6))

### Testing

- Scenario-based E2E release parity testing with target-triple and tar.xz support ([d1ed523](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/d1ed523a95d6f302c711ba77d0dfb14e3cb692cd))

---

## 2026-02-02 -- Artifact Naming, Cross-Platform Portability, and Release Hardening

Major push on GitHub Actions parity: dual-name assets, portable shell patterns, and hardened release uploads to ensure dsr-produced releases are indistinguishable from GH Actions-produced ones.

### Artifact Naming and Dual-Name Assets

- Package installer archives for native builds ([04293c5](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/04293c5f201da49af19515ac5bb7e0bcf9377efa))
- Arch alias assets and improved JSON escaping ([21c7e68](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/21c7e6821b94cbc1a32b25bbdeefca486c83d82d))
- Upload dual-name assets during release ([a9f460f](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/a9f460feaff9fb86698a93017193a3d4f53b26a2))
- Overwrite existing release assets and follow manifest ([d8c1248](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/d8c1248338ab976590d64c66dbb492211ed284f5), [46c9c69](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/46c9c693bced1b54b6735e968b98b28613abed97))
- Fix release artifact extraction and naming ([17e40be](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/17e40be17fa6a658ccdf2c463101b46a3483fb0a))

### Cross-Platform Portability

- Replace `grep -P` (GNU-only) with portable `sed` patterns for macOS compatibility ([3340f75](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/3340f75043561fc96cbb220354936f3ec6610597), [6e3762f](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/6e3762fd80138bbaf94554ec9f29c2a319ad8f52))
- Detect BSD `date`'s literal `%3N` output on macOS ([8c203ed](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/8c203ed173d1f4b7e780e13bd24cbd546990389c))
- Windows compatibility for host health checks ([a7939ef](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/a7939ef36cf5afbf9f7f05cdc187ec1f66ff0667))

### Robustness and Bug Fixes

- Guardrails path normalization and artifact naming substitution ([039f262](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/039f2621e06a3c8c516e56fd274b29db2052cd4b))
- `upgrade_verify_json` timeout fallback ([10c478f](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/10c478fc7acb17c0dad7f3359fbe1deb2bf64a53))
- Harden timeouts and path handling ([3b412a3](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/3b412a3ef3bac09238f4af21e719deaa37bf0833))
- Path traversal and jq validation bugs in `checksum_sync` and `build_state` ([ed17e01](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/ed17e014d7bbef05d7ce6f6d8f640c99bc5e50ae))
- Multiple bug fixes and portability improvements ([b840e4c](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/b840e4c4a12fb1eb23fddc48e9b2caa2ff10a35c))

### Artifact Naming Test Suites

- Install script parsing tests ([2e03b26](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/2e03b2605f72d232b282783e0d712ead8af81c34))
- Workflow YAML parsing tests ([f14258b](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/f14258b6b2d2a7db92398de0fddc45961f3e96dd))
- Dual-name generation tests ([7920c28](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/7920c28d6c844e8d52efa4cc833ca14088f82b03))
- Naming validation tests ([34d07df](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/34d07dfc54600b56c96bc17ed2965c530766a093))

---

## 2026-02-01 -- Artifact Naming Module and Watch Auto-Fallback

Introduced `src/artifact_naming.sh` for GitHub Actions parity (dual naming conventions) and wired `watch --auto-fallback` into a functioning pipeline.

### GH Actions Parity -- Artifact Naming

- `src/artifact_naming.sh` module -- canonical artifact naming with dual-name support for install script compatibility ([bb7cab8](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/bb7cab84dce85a3157a495a73fda892203f62808))
- `install_script_compat` schema fields in repo config ([5c4f3a6](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/5c4f3a609b3bb1f2222219c049efa16809103f3a))
- Artifact naming consistency validation in `dsr repos validate` ([6281d59](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/6281d59247347a5b5d04ed6ac8500bbcb3ca75dd))
- Dual-name asset upload functions in GitHub module ([0d7664b](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/0d7664bef1f8986837b454cdabae6d750b9bb3e5))
- Dual naming documentation for install script compatibility ([8c51e1c](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/8c51e1ce820cb4db8445dbd1dc11a17456a73604))

### Remote Build Validation

- Remote repo validation and auto-repair in act runner ([11a4579](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/11a45798b13c255d189f92433f19bc1066e17ca4))

### Watch Auto-Fallback

- `watch --auto-fallback` wired up to trigger `dsr fallback` pipeline ([d64e9fd](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/d64e9fd145d5212b40db872d9e9849d483bfa71b))
- Fix 3 bugs in watch auto-fallback implementation ([16b7fcd](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/16b7fcde49d26359767dd76ea12ae6d71be2f637))

### Reliability Fixes

- Safe jq updates, mkdir error checks, artifact copying ([b457706](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/b457706504ae7b8cd3dab4072fd835699bf12bad))
- Race conditions, portability, and JSON escaping bugs ([93f699d](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/93f699d02c116cc4c8e95578e2a222bb033a176c))
- Empty SHA256 handling and double extension bug ([2611877](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/2611877f3839747a789256158ff91b538cddd52a))
- Extract single-line JSON from act output correctly ([b839ed9](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/b839ed98feda5ac76f722909cb88e0b910ce3c8d))
- Handle empty arrays in artifact naming validation JSON output ([23c2f30](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/23c2f308407910df827823133279486c4ee498c4))
- Resolve test failures from XDG/DSR_CONFIG_DIR path mismatches ([e25eaf7](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/e25eaf737740a2ce5140fe44f727c9a9317d6496))
- Correct exit code 4 for `--no-sync`/`--sync-only` conflict ([3ad9bb8](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/3ad9bb81a178e45d36c9f4446752991bd71eb30c))
- Mutual exclusivity check and yq query syntax fix ([88977cc](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/88977cc0462babd2ab1f0842a602075fb97f9e55))
- Prevent `--only-act` and `--only-native` from being used together ([6776dbb](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/6776dbb990684aea808f9cfa7370a897d3b8429b))
- Resolve 3 test failures and add portable SHA256/ETag improvements ([e0e49dd](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/e0e49ddd79979b38282f761ad785f9d76309fcb0))

---

## 2026-01-31 -- Security Hardening, Build Matrix Filtering, and Native Builds

Systematic JSON injection audit across all 26 modules, act UID mismatch prevention, build matrix filtering flags, and native SSH build support.

### Security -- JSON Injection Audit

Replaced unsafe heredoc JSON construction with `jq` across the entire codebase to eliminate injection vectors:

- Umbrella fix: race condition, JSON injection, and input validation ([4d4dcd1](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/4d4dcd17a8f0e3f298611fa57a60a400b0170390), [892408b](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/892408b1a3a043c6b8e12a2456fca5ab8c48ed4c))
- `canary.sh`, `upgrade_verify.sh` -- results arrays ([9b6ca6e](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/9b6ca6e781e2455c0e98fd76f1a2f3bdd8462a2a))
- `git_ops.sh`, `build_state.sh` -- heredocs ([21a8f7f](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/21a8f7fb3ee2335cfbf62097d95ae0607079d378))
- `quality_gates.sh`, `install_gen.sh` ([376df29](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/376df29975cf2cf5ef1ad78030c3794aa68edf79))
- `logging.sh` -- context fields ([203fbd4](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/203fbd4a86003aedc2ca033365853447e1b61c51))
- `act_runner.sh`, `host_health.sh`, `signing.sh` -- heredocs ([86ecab4](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/86ecab40627fc3cee1f26245ab723a78befc4e1f))
- `notify.sh` -- jq-based safe JSON construction ([10c9c1b](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/10c9c1bfb656bb8dd127594d69886e0f72480d53))
- `version.sh` -- jq for `version_tag_all` JSON output ([9cce422](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/9cce422524b511d92eac48c8ba7aae9042f06a5b))

### Act Runner UID Mismatch Prevention

catthehacker runner images run as UID 1001. Without `--user` mapping in `~/.actrc`, files created inside containers get wrong ownership.

- Prevent UID mismatch when catthehacker act images create files ([dc70487](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/dc704879ef444890337d1e42becbf5df9a4e77b9), [30f8559](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/30f85597ed338344bfa6a606ee33b90179a4c7e7))
- Clarify that actrc does not evaluate shell expressions ([a480c60](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/a480c60bc41954161999da9275b82b0cf528dc72))
- `grep` pattern for actrc `--bind` detection handles leading whitespace ([acf536e](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/acf536eab37dab7662a6b84c124e13a4d26aa2ce))

### Build Matrix Filtering

- `--only-act` and `--only-native` build matrix filtering flags ([cae2bf6](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/cae2bf6a6d0b9eb9eead63e8726c6208a5064cd9))
- `--no-sync` and `--sync-only` flags for `dsr build` ([9c3c098](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/9c3c09835356c6431ac92381d462fbdd5ad7224f))
- `act_matrix` config documentation for targeted builds ([dd3d5eb](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/dd3d5eb8a370ece9dda4187f1bfced14ad9a339b))

### Native SSH Builds

- Source sync to remote build hosts via SCP in act runner ([5b32f8c](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/5b32f8c2bafe92e83f94a429302ccdda71f110d3))
- Windows native builds, build counter, and ShellCheck warnings ([7bef70b](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/7bef70b122c2d2bcf3a0fa1c9e0607ab88323670))
- Extract JSON from native build output ([20852a2](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/20852a22f672e61edb3b7ff9084b4f77f98b8485))
- Filter null/empty values from matrix entries ([fdf4777](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/fdf477718f12fa731b0186a5feffadb79bcbb9c4))

### Testing

- E2E tests for multi-platform native builds ([896a4db](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/896a4db6bd78b3d54fdefa1052ac7018ed7c5bfb))
- Test fixes for `quality_gates` and `test_harness` ([b447554](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/b4475543cdd1a2578f0a832018ef42331b861d04))

---

## 2026-01-30 -- Project Genesis (163 commits)

The entire project was built in a single day using heavily parallelized multi-agent development. Every core command, all 26 source modules, the full test suite, documentation, schemas, and supply-chain security tooling were created from scratch.

### CLI Commands

Thirteen commands covering the full release fallback lifecycle:

| Command | Purpose | Key Commit |
|---------|---------|------------|
| `dsr check` | Detect throttled GitHub Actions runs via queue-time monitoring | [ecc5092](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/ecc5092df70c01b67c93340f1df0b76d82de3f35) |
| `dsr build` | Build artifacts locally via act (Linux) or SSH (macOS/Windows) | [024e555](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/024e555b6c73b42de18ea79643012bf291f0cecb), [4d01ba8](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/4d01ba8f42a448523eaa1ae534ec65716f65ce13) |
| `dsr release` | Upload artifacts to GitHub Releases with checksums and signatures | [bb2a29e](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/bb2a29eae9037b76c15cec309549f5e70c1f04fd) |
| `dsr release verify` | Verify release upload integrity post-upload | [9c1d8b8](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/9c1d8b8fa20e31799aa66b0c95870cc5ce3dded9) |
| `dsr release formulas` | Release formula dispatch to package managers | [e65858b](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/e65858bbc6878762aec609cc827b9506d885a95e) |
| `dsr fallback` | Full pipeline: check -> build -> release in one command | [03be265](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/03be2652b9091a0ec2290921f4072c74b454dabf) |
| `dsr watch` | Continuous monitoring daemon with optional auto-fallback | [93489b1](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/93489b16354a0414f6500fcf7213e6486ff3c933) |
| `dsr repos` | Manage repository registry (add, remove, list, validate) | [7e1ca6c](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/7e1ca6c0a78d31171ff7158111717dc745900b0d) |
| `dsr config` | View and modify YAML configuration | [7c31bd2](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/7c31bd2a02473fde0bc6f2441a9e1e193dfe72e4) |
| `dsr doctor` | System diagnostics: check dependencies, hosts, and configuration | [830f09f](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/830f09f0c581cff0f479dfee83de7d7660cd6d7c), [23aaf6f](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/23aaf6f83573dd7c151f40f9dc558b0ae7171f46) |
| `dsr status` | System and last-run summary with optional host refresh | [2ceebdd](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/2ceebdd1e637bf17aa08a3cd251e54b940d587cd) |
| `dsr signing` | Manage minisign key pairs for artifact signing | [6ee4e0f](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/6ee4e0f4af9ac5cf84a020dcb282e0ba47408617) |
| `dsr quality` | Pre-release quality gates (configurable per-repo checks) | [5f6ce9f](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/5f6ce9f8f91cd7cb4dc10f9cede035e8c8ab4667) |

### Build Infrastructure (act + SSH)

Local builds reusing existing GitHub Actions YAML via nektos/act for Linux, with native SSH builds for macOS and Windows:

- Act runner integration: run GH Actions workflows locally in Docker ([25d8d4d](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/25d8d4df9f26e48c327604413cdbde4f46a0b05f))
- Build command orchestration across multi-platform targets ([4d01ba8](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/4d01ba8f42a448523eaa1ae534ec65716f65ce13))
- Build workspace isolation with lock files and state tracking ([f19e114](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/f19e114515605ac6bb7a838bb8ae266cd03432d7))
- Host selection engine with concurrency limits ([a03d465](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/a03d46558a9d2b7c7c359d545036621ba3f64b01))
- Act compatibility matrix config loading ([f058b6e](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/f058b6e31e0c6bd9bf8448af55b6d6ca73715cfd), [92d3431](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/92d34311fdd2852effeec2901de3f5044de52a26))
- Docker buildx module for multi-arch container builds ([12c1fe2](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/12c1fe23f71c97f3ee4f3b409e7a241f57bae60b))
- Host-specific path mapping and automatic artifact download ([0457a3b](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/0457a3b826793da8d87cf2d580babec5bfa6a166))
- GoReleaser validation and config environment variable support ([348dc56](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/348dc5624ae80ab5217c23205f90c124657a0b4f))

### Supply Chain Security

Signing, attestation, and integrity verification built in from day one:

- Minisign key management for artifact signing ([6ee4e0f](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/6ee4e0f4af9ac5cf84a020dcb282e0ba47408617))
- SLSA provenance attestation module ([25083e3](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/25083e3b2e0ce0f61d6e0d81de0416be43834f9d))
- SBOM generation via syft in SPDX-JSON format ([faf7934](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/faf7934920ac99f7cb1475f0915c32eff16dd803))
- Checksum auto-sync module ([528c9ac](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/528c9aca9f8fd1ab2d86e0e1847364ea751bac54))
- Pre-release quality gates ([5f6ce9f](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/5f6ce9f8f91cd7cb4dc10f9cede035e8c8ab4667))
- Secrets and credential loading module ([0b839d8](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/0b839d831b42f29a9adc32ae79400645a8bdd283))

### Installer Generation

Per-tool curl|bash installers with platform detection, caching, and canary testing:

- Install script generator for per-tool curl|bash installers ([37bb6b4](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/37bb6b4b8fa89a123b994e71b30292419fce3570))
- Generated installers for ntm, bv, and cass ([5dcd091](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/5dcd091a8f82ed0ba8b386b40ee4a65fc5c7e99d), [fbde1e4](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/fbde1e423d194b42198bee0b16bba26527689831))
- Installer cache/offline mode ([91d4ec8](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/91d4ec8cd57072f56306453fcae82295b41004af))
- AI coding agent skill auto-installation via curl installer ([ef95c5d](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/ef95c5d2068e4085a217a0d1185e048ad5b5b482))
- PowerShell installer for Windows ([bc5c577](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/bc5c577b0e14fc9622a922722c8e04e7977364f3))
- Installer canary testing in Docker ([72737e6](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/72737e6f21c91fb3c1703dea8a50244a6335e8c9))
- Upgrade command verification after release ([29ae2c6](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/29ae2c678706fcc5437de1e4df6702b0ac8c5384))
- `--verify-upgrade` flag for `dsr release` ([17cbfc5](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/17cbfc5328b402d99ee80e4b6a01f729f6cdf17d))

### Cross-Repo Coordination

- Repository dispatch module for cross-repo coordination ([7b0e7c7](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/7b0e7c716dc4e5bd8c07a83b2b1725eaf6316db2))
- Release formulas subcommand dispatch ([e65858b](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/e65858bbc6878762aec609cc827b9506d885a95e))

### Monitoring and Notifications

- Notification system for release pipeline events (ntfy.sh, desktop) ([447af6d](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/447af6dadc95497176419d097745a714fe9b742c))
- Notification system integration into watch mode ([93489b1](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/93489b16354a0414f6500fcf7213e6486ff3c933))
- Host health checking with yq fallback ([830f09f](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/830f09f0c581cff0f479dfee83de7d7660cd6d7c), [9c033ca](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/9c033ca0fbf7a520e18fbe4242936459f84d3fcd))

### Version Detection and Toolchains

Automatic version extraction from project files so tags can be inferred without manual input:

- Version detection module: Cargo.toml, go.mod, package.json, VERSION files ([bb5c8cc](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/bb5c8cc6d7af2e17a925ea379d8aa13520e51e2c))
- Toolchain detection module for cross-platform installers (Rust, Go, Bun) ([65ed169](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/65ed169b41ae1d50efd88d542894f6ffaf7a9d2c))
- Dependency checks and portable version comparison ([a1e8d6d](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/a1e8d6def7043b8f735ddb243caeee205b5fedf4))

### Core Infrastructure

Shared modules that underpin every command:

- GitHub API adapter with caching ([a887269](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/a88726943164f3539a0db3b3280e07e8f44b835e))
- Structured logging infrastructure ([740b8d9](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/740b8d9db2acbaf7b8b4e8c321d72c08b9a179d8))
- Runtime safety guardrails: Bash 4.0+ enforcement, input validation ([a426083](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/a42608368c63516488c1459be0ac1efcc1b76fd8), [2bc6cc8](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/2bc6cc8523f64006e836ad468fd87594d328e52f))
- Git operations with validation helpers and error handling ([119b0da](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/119b0da760694d8f377ac77143e06b953ede9413))

### Schemas and CLI Contract

- CLI contract and JSON envelope spec (`docs/CLI_CONTRACT.md`) with structured exit codes 0-8 ([f83b414](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/f83b41404468f9d4bcf9e1caa6084efde146163d))
- JSON schemas for all command responses (`schemas/`) ([f83b414](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/f83b41404468f9d4bcf9e1caa6084efde146163d))
- Artifact naming convention and manifest schema ([60eeb6f](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/60eeb6fe18eca7ac99a8a1923a2612dcd4dccff5))

### Testing Infrastructure

Bats-based test suite with real-behavior harness (no mocks for external tools), structured logging, and function-level coverage:

- Real-behavior test harness with skip protocol and time/random mocking ([7da456f](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/7da456f940614c1ec87ef228d56ab6474a4eb583), [650393d](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/650393d7749a87d07db813ae416e401fa215dc9d))
- Unified test runner script ([e06f9c3](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/e06f9c337fcac92e0c77d555d8c0649b7c9c5805))
- Function-level coverage reporting ([fe7ded5](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/fe7ded514dfdceef15008a953590a68823ff4aa1))
- Structured test logging infrastructure ([64a3b69](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/64a3b690d5a9b82086358cbe7879ecd079c369fc))

**Unit tests:**
- `config.sh` ([160925e](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/160925e1136a05fc7b5b3ba9b9a66a717fdaf38e))
- `github.sh` ([3d4d42a](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/3d4d42a81daa58cab287822d29c23e583c95a701))
- `version.sh` ([86ffd70](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/86ffd70bd0b585e2400f1170d4eab2fdf940f2ee))
- `act_runner.sh` native build logic ([f5569d6](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/f5569d6bc632588c2660c2c615890e5d6abb40ed))

**E2E tests:**
- `dsr doctor` ([bae35a2](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/bae35a2388b0cbf778f4437d9650ed158547f82d))
- `dsr repos` ([8f0e6a1](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/8f0e6a1abfee07f1e5fef1130d91afdefcc84a04))
- `dsr status` ([595b524](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/595b524f9bcbe11048f1ead348bc7ded86a9528c))
- `dsr signing` ([aa148e0](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/aa148e0cd01cf9099d613bd3feabdcc1a6535b77))
- `dsr quality` ([2c64d71](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/2c64d718b1465640056b96660556c63434eb9587))
- `dsr watch` ([3e13b85](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/3e13b856bc560e4be199644c5500008be6518a7a))
- `dsr fallback` ([cc28bc0](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/cc28bc07e9c284482e11f5bc3389c8abb3246b95))
- `dsr health` ([43bac01](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/43bac0142d8b5e1f5c2c80402698f1df4f235d7b))
- `help`/`version` smoke tests ([11c504f](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/11c504f6db07b9d5a62ca42d86931da282f7d252))

**Specialized tests:**
- Supply chain security tests for SLSA, SBOM, and quality gates ([446af67](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/446af67bdc8cf1f02445ebf8a7a3a82f4cc57fbd))
- Docker installer E2E tests ([ed94e18](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/ed94e18ca885d743ba9d5d1014af11a84da10015))
- Installer signature and cache/offline tests ([72bde20](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/72bde20025d13dc2668e525e453b24d470e9fa4b))
- Platform detection and freshness checking tests ([c8952e7](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/c8952e7d51e62dfa9ec0a473e55556808e062f3e))
- Throttling tests and JSON schema validation ([5ff535e](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/5ff535e1a3d3d1d8b6c98e8acf9adcbd8f5f01bc))
- Release verify and release formulas tests ([c72a451](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/c72a451f1d9456bb19333baad83fae508cc58fd0), [64a675b](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/64a675ba7e9ef5aa17dbd03c73d246d6f200b06c))
- Notification E2E tests ([2dcf04a](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/2dcf04a13222305e8b73a2e6838439f202190ffa))
- Auto-tag version detection tests ([bd8e673](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/bd8e67358ec6a92a370fd37314e87b18f6c2b35d), [f3a1626](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/f3a1626d4fb731b8985e298b11e98a071ffcddc6))
- Integration tests for dsr commands ([afa3033](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/afa3033e591a806ce352885c24feebe2c6809a72))
- Status/report, host selection, and prune tests ([ac4aafb](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/ac4aafb4114d1cf30f16a4b4b290b1884b7fa0f2))
- XDG layout tests for date-based log directory structure ([eea7f45](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/eea7f4503d8fe1ab41c769828897737068c487bf))
- Repos validate test suite ([c1d0fa4](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/c1d0fa4520addc466fb77ffcf81c2704a3b3f583))

### Documentation

- Comprehensive README with architecture diagram, comparison table, and FAQ ([ced193e](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/ced193eb500b41b6bd77d7091ed840692b0a4d08))
- CLI contract and JSON envelope spec (`docs/CLI_CONTRACT.md`) ([f83b414](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/f83b41404468f9d4bcf9e1caa6084efde146163d))
- Act setup guide (`docs/ACT_SETUP.md`) ([a480c60](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/a480c60bc41954161999da9275b82b0cf528dc72))
- Illustration and quick install added to README ([cc0bb91](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/cc0bb91abe304c358d108fdfd35f4dac62612106))

### Notable Day-1 Bug Fixes

- Race condition in slot acquisition ([a4b647f](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/a4b647f14b4978e30099e8012f0af26a4144439b))
- Exit code capture in pipelines using `PIPESTATUS` ([e83c18b](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/e83c18b7cd73c98ae6e64785ac630b0193f43af3))
- Empty array JSON serialization and SC2015 patterns ([808564a](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/808564a9ccd3aeb21f70d928086f43f2462e624f))
- Multiple bugs in release command ([8887273](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/88872733a7e9eebace87b722acb9824749839c70))
- JSON extraction and manifest generation in build pipeline ([1313d53](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/1313d534b60c994fd927a5b19514fb8cf549dafa))
- Correct `--json` flag position in doctor test assertions ([289d25e](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/289d25e9153f612681d986b45f68931daced55c0))
- Improve exit code capture and token handling ([caafe6a](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/caafe6abbd7aba3b672738d9aec4609a3f9b311b))
- Deprecation warnings for unimplemented `--resume` flag ([b16277c](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/b16277cdf4de41bb1c2f3a24366a106f6032ecdd))
- Correct skill installation tracking in `install_gen.sh` ([b6065bb](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/b6065bbaa459e8606b156881aed3eed0ff49728e))
- Alternate path checks for mmini Go and Bun toolchains ([1fa6f06](https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/1fa6f060dc9dc56541e07247e6d1a8a500aafddb))

---

## Source Modules

The 26 source modules under `src/`, organized by capability:

### Build and Execution

| Module | Lines | Purpose |
|--------|------:|---------|
| `act_runner.sh` | 2 236 | Run GH Actions workflows locally via nektos/act, SSH native builds |
| `build_state.sh` | 1 080 | Workspace isolation, lock files, build state tracking |
| `host_selector.sh` | 464 | Select build hosts with concurrency limits |
| `host_health.sh` | 951 | Health checking for build hosts (Linux, macOS, Windows) |
| `docker.sh` | 744 | Docker buildx for multi-arch container builds |

### Release and Distribution

| Module | Lines | Purpose |
|--------|------:|---------|
| `github.sh` | 952 | GitHub API adapter with response caching |
| `install_gen.sh` | 1 265 | Generate per-tool curl|bash installers |
| `artifact_naming.sh` | 918 | Canonical + dual-name artifact naming for GH Actions parity |
| `release_formulas.sh` | 450 | Release formula dispatch (Homebrew, etc.) |
| `dispatch.sh` | 514 | Repository dispatch for cross-repo coordination |
| `checksum_sync.sh` | 711 | Auto-sync checksums across build artifacts |

### Security and Integrity

| Module | Lines | Purpose |
|--------|------:|---------|
| `signing.sh` | 468 | Minisign key management and artifact signing |
| `slsa.sh` | 378 | SLSA provenance attestation generation |
| `sbom.sh` | 368 | SBOM generation via syft (SPDX-JSON) |
| `secrets.sh` | 458 | Secrets and credential loading |
| `quality_gates.sh` | 312 | Pre-release quality gate checks |

### Verification and Testing

| Module | Lines | Purpose |
|--------|------:|---------|
| `canary.sh` | 540 | Installer canary testing in Docker |
| `upgrade_verify.sh` | 419 | Verify upgrade works after release |

### Configuration and Detection

| Module | Lines | Purpose |
|--------|------:|---------|
| `config.sh` | 660 | Configuration management and YAML parsing |
| `version.sh` | 474 | Auto-detect version from Cargo.toml, go.mod, package.json, VERSION |
| `toolchain_detect.sh` | 660 | Detect installed toolchains (Rust, Go, Bun) across platforms |

### Core Plumbing

| Module | Lines | Purpose |
|--------|------:|---------|
| `logging.sh` | 316 | Structured logging with JSON context |
| `guardrails.sh` | 431 | Runtime safety: Bash 4.0+ enforcement, input validation |
| `git_ops.sh` | 551 | Git operations with validation helpers |
| `notify.sh` | 345 | Notification delivery (ntfy.sh, desktop) |

---

## Summary Statistics

| Metric | Value |
|--------|-------|
| Total commits | 254 |
| Source modules (`src/`) | 26 |
| Source module lines | 16 665 |
| Main script (`dsr`) | 8 133 lines |
| Active development span | 2026-01-30 to 2026-03-12 |
| Day-1 commits (2026-01-30) | 163 |
| Language | Bash 4.0+ |
| Test framework | bats |
| Tags / GitHub Releases | None |
| License | MIT with OpenAI/Anthropic Rider |
