# Execute a release build plan

`src/release_builds.sh` starts builds that have not finished yet, retains verified
completed jobs, and passes their successful manifests to the existing release
bundle collector. Unlike a build set, a build plan pins **inputs**, not output
manifest hashes that cannot exist before compilation. No release API is called.

Three drivers are supported:

- `dsr`: run the existing `dsr --json --non-interactive build` command with a
  frozen configuration and private per-attempt state/output directories.
- `xwin`: run the source-pinned Windows ARM64 runner, including its toolchain,
  Cargo metadata, committed source, optional siblings, and PE admission gates.
- `import`: accept an already-produced manifest selected by its explicit SHA-256.

All jobs must partition the exact `required_targets` matrix. No target can be
omitted, repeated across jobs, or added by a successful producer. Tool, version,
source SHA, sibling dependencies, artifact names, sizes and hashes still pass
the existing collector's admission rules. The coordinator does not substitute
its own weaker successful-build profile.

## Plan and execution

The following example combines native Linux/macOS builds and Windows ARM64.
Replace the deliberately invalid pin placeholders with reviewed SHA-256 values.
The native configuration must already define the requested targets and source;
this command does not rewrite a repository's release contract to admit a subset.

```json
{
  "schema_version": 1,
  "repo": "owner/demo",
  "tool": "demo",
  "tag": "v1.2.3",
  "source_sha": "<reviewed full 40-character source commit>",
  "required_targets": ["linux/amd64", "darwin/arm64", "windows/arm64"],
  "builds": [
    {
      "id": "native",
      "driver": "dsr",
      "targets": ["linux/amd64", "darwin/arm64"],
      "config_dir": "/srv/dsr-config",
      "config_files": {
        "config.yaml": "<actual SHA-256>",
        "repos.yaml": "<actual SHA-256>",
        "hosts.yaml": "<actual SHA-256>",
        "repos.d/demo.yaml": "<actual SHA-256>"
      },
      "jobs": 2,
      "timeout": 7200
    },
    {
      "id": "windows",
      "driver": "xwin",
      "targets": ["windows/arm64"],
      "project": "/srv/projects/demo",
      "toolchain_manifest": "/srv/pinned/windows-arm64.json",
      "toolchain_sha256": "<actual SHA-256 of the toolchain manifest>",
      "binary": "demo",
      "package": "demo",
      "asset_name": "demo-aarch64-pc-windows-msvc.exe",
      "offline": true,
      "cargo_cache": "/home/builder/.cargo",
      "cache_dir": "/srv/cache/xwin",
      "timeout": 7200
    }
  ]
}
```

```bash
bash src/release_builds.sh --plan /srv/release-plan.json \
  --output-dir /srv/release-run --jobs 2 --dry-run

bash src/release_builds.sh --plan /srv/release-plan.json \
  --output-dir /srv/release-run --jobs 2 > /srv/build-result.json
```

Planning validates the plan and returns `publishable: false` without spawning
builders, checking host credentials, creating persistent state, or validating
compiler installations. Live execution requires Linux, Python 3, Bash, jq,
flock, GNU timeout, SHA-256 tooling and the selected builders' dependencies.
The output parent must exist. Paths must be absolute and canonical; symlink
components are refused. Use a new output directory outside source checkouts.
Xwin run-directory restrictions still apply, including no whitespace in paths.

`--jobs` controls concurrent **jobs**, from 1 to 32, default 1. Each native job's
optional `jobs` controls its own target parallelism, also default 1. These bounds
multiply; select them for the actual build-host capacity. A job failure does not
cancel independent work. Every started command has a whole-job timeout (default
3600 seconds, range 1..86400), including preparation and final verification.

The native driver snapshots the explicitly named config files after checking
their hashes, then freezes all DSR config-file selectors and uses a private
`DSR_STATE_DIR`. `config.yaml`, `repos.yaml`, and `hosts.yaml` are required pins;
additional `repos.d/NAME.yaml` files may be named. Unlisted files are not copied.
The copied configuration's bytes and file namespace are checked after execution.
Native host authentication, cache defaults and toolchain environment otherwise
follow the existing builder. No `--allow-dirty`, `--no-sync`, diagnostic mode,
publication flag, or arbitrary shell command is synthesized.

The xwin driver requires a project, toolchain-manifest path/hash and binary.
`package`, `asset_name`, `cargo_cache`, `cache_dir`, and `offline` are optional.
Repository/tag/source SHA/tool come from the plan. To include pinned sibling
repositories, add `"siblings": {"path": "/srv/pinned/siblings.json",
"sha256": "<actual SHA-256>"}`. That file is frozen before being passed as
`--sibling-crates`; the existing runner enforces its individual repository pins.
Toolchain and sibling manifests are configuration, not executable script text.

An import job has exactly `id`, `driver: "import"`, `targets`, `manifest`,
`manifest_sha256`, and `artifacts_dir`. It can be combined with either build
driver. It never runs a compiler, and its output hash must be selected in advance.

## Recovery and publication

Each invocation reads the same canonical plan. Job and target ordering does not
change its identity; changing source, config pins or execution settings does.
`--jobs` may be changed on retry because it controls scheduling, not build inputs.

```text
release-run/
  plan.json                         # Frozen canonical input plan
  state.json                        # Job attempts and selected completion pins
  attempts/ID/000001/                # Command, private inputs, stdout/stderr, outputs
  attempts/ID/000002/                # Failed retries never overwrite earlier attempts
  completed/ID/build-manifest.json   # Verified, pinned producer manifest
  completed/ID/artifacts/            # Copied, not hardlinked, accepted payloads
  build-set.json                    # Created only when every job is admitted
  bundle/release/                    # Existing complete aggregate format
```

Nonzero builder exits, missing/ambiguous completion JSON, changed inputs, missing
manifests, wrong-source manifests and corrupt payloads cannot complete a job.
An incomplete invocation returns exit 1 and lists failed jobs; their specific
exit codes remain in `state.json`. The same command retries failed/interrupted
jobs in fresh attempt directories and independently revalidates completed jobs.
It does not transparently resume a failed compiler's intermediate build state;
the existing native `dsr build --resume` remains a separate operator workflow.

Successful checkpoints no longer depend on original compiler-output paths.
Losing the acknowledgement after atomic checkpoint import is reconciled using
the already-retained candidate manifest hash, never by adopting arbitrary files.
An existing completed checkpoint that is missing or corrupt is an error, not
permission to rebuild it and silently select a different output. Completed
bundle identity remains stable on publication retries.

A local advisory lock is held for the whole run and inherited by driver process
trees. Another coordinator cannot start while those owners still hold it, even
when the original coordinator dies. Do not unlink the lock to bypass a live
owner. SIGTERM/SIGINT/HUP cancel only the current invocation's process groups;
no PID read from state is signaled. Child processes are stopped after timeout,
cancellation, or normal driver exit. The coordinator retains attempt logs.
This does not guarantee cancellation of a remote host after a network partition.

The completed `build-set.json` feeds the existing finalizer without constructing
manifest pins by hand:

```bash
bash src/release_finalize.sh --build-set /srv/release-run/build-set.json \
  --bundle-dir /srv/release-run/bundle --create-draft
```

Signing, draft creation, promotion, SBOM generation and downstream delivery
remain the finalizer's explicit policies. A build-plan success does not publish
a release. See [RELEASE_BUNDLES.md](RELEASE_BUNDLES.md) and
[RELEASE_FINALIZATION.md](RELEASE_FINALIZATION.md).

The coordinator verifies producer evidence and local bytes; it is not a build
sandbox, platform authenticator, or signed provenance service. State and build
hosts remain trusted. The native builder's own source and release gates remain
responsible for how its claimed source was compiled. Atomic local checkpoints
are not a distributed exactly-once transaction or a remote durable-storage claim.

Run `bash scripts/tests/test_release_builds.sh` for subprocess, retry, timeout,
cancellation, configuration-pin and collector admission tests. The tests run real
processes and filesystem/hash operations, with explicit stand-ins at native and
xwin compiler-driver boundaries; they do not claim live host or Rust execution.
