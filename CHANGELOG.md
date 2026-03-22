# Changelog

All notable changes to **dsr** (Doodlestein Self-Releaser) are documented here.

This project does not use semantic versioning tags or GitHub Releases. It ships as a single `dsr` Bash script (8 100+ lines) with 26 source modules under `src/`. Development history is recorded entirely through commits on the `main` branch.

Commit links point to: `https://github.com/Dicklesworthstone/doodlestein_self_releaser/commit/<hash>`

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
