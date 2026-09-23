# Execute a release build plan

`src/release_builds.sh` starts builds that have not finished yet, retains verified
completed jobs, and passes their successful manifests to the existing release
bundle collector. Unlike a build set, a build plan pins **inputs**, not output
manifest hashes that cannot exist before compilation. No release API is called.

Three drivers are supported:

- `dsr`: run the existing `dsr --json --non-interactive build` command with a
  frozen configuration and private state/output directories; optionally resume
  the exact native run after a partial failure.
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
Native jobs can opt into exact-run resume as described below. Without that
option, failed native and xwin jobs restart in fresh state/output directories.

### Resume partial native jobs

Add `"resume": true` to a `driver: "dsr"` job before the first invocation to
retain successful native targets when another target fails. This is a boolean
job policy, not a global CLI flag, and belongs to the frozen input plan. Omitted
or `false` preserves fresh-attempt behavior. Xwin/import jobs do not accept it.

On retry the coordinator calls the existing `dsr build --resume=RUN_UUID` with
the same frozen configuration, private state root, output directory, version,
and target ordering as the original native run. It never follows the `latest`
symlink, selects a newer run by timestamp, or supplies `--no-sync` to bypass
source admission. DSR's existing resume checks still validate source roots,
host/configuration bindings and each retained target's artifact evidence.

Each coordinator attempt retains separate command/input receipts and stdout/
stderr logs. Its `native` state record identifies the owning `session_attempt`,
the observed `run_id`, and the explicit `resume_run_id` (null for a fresh run).
`native-before.json` and `native-after.json` preserve the underlying checkpoint
observations. The native backend may update its state and retry failed target
outputs in the original session; earlier coordinator logs are never overwritten.

The source SHA, tool, version, target list and output path must agree with the
input plan. Changed configuration snapshots, ambiguous/missing native runs,
modified invocation receipts, symlinked checkpoints, or diagnostic state fail
before execution. A backend rejection is not retried as a fresh build. The
original external configuration directory may go offline after admission;
resume revalidates and consumes the frozen copy. Required source checkouts and
remote hosts remain subject to the native builder's own availability checks.

A failure before any native checkpoint exists gets a new isolated session.
An already-observed checkpoint that disappears is an error. Native `completed`
or `cancelled` state cannot be resumed by DSR and is not automatically adopted
as a successful coordinator job. Retained output in that situation requires
inspection. Successful resume must bind its final manifest to the same native
run UUID and a completed native checkpoint before ordinary bundle admission.

This is native **target-level** resume, not a promise to reuse every failed
compiler's intermediate cache or to continue a remote process after a network
partition. Run `bash scripts/tests/test_release_builds_resume.sh` for exact-run
selection, target retention, state/configuration drift and failure-boundary
tests. Native compilation/SSH is an explicit command-boundary fixture; the
coordinator and full bundle/SLSA modules run unchanged apart from this feature.

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
no PID read from state is signaled. Owned process-group descendants are stopped
after timeout, cancellation, or normal driver exit. The coordinator retains logs.
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

## Build and finalize in one invocation

The existing finalizer can execute the input plan before collecting and publishing
the selected outputs. Supply `--build-plan` as the first option:

```bash
bash src/release_finalize.sh --build-plan /srv/release-plan.json \
  --build-dir /srv/release-run --build-jobs 2 \
  --create-draft --require-signatures \
  --public-key /srv/keys/release.pub --secret-key /srv/keys/release.key
```

This command does not imply `--promote`. Its publication stage uses the unchanged
finalizer engine, including its source, signature, SBOM, remote verification and
recovery checks. Add `--promote` only when publishing the verified draft is intended.
The sourced API is `release_finalize_build_plan` with the same arguments.

Build-plan mode is mutually exclusive with `--build-set` and `--bundle-dir`.
It owns repository, tag, source SHA, tool, manifest and payload-upload selection;
do not supply `--repo`, `--tag`, `--sha`, `--tool`, `--build-manifest`, or
`--upload-payloads` yourself. `--build-jobs` is the controller's job-concurrency
bound; native per-job target concurrency still comes from the input plan.

Before starting builders, the entry point validates option structure, signature
mode conflicts, local policy-file selections and output-directory constraints.
This is not cryptographic key validation or remote policy admission: the real
engine performs those checks after successful builds and before its release
mutations. A bad signing key can therefore fail finalization after compilation,
while leaving the completed build checkpoints available. Policy files are selected
again by the engine when publication begins; they are not attested build inputs.

Failed builds return one finalization envelope with `stage: build`,
`status: builds_incomplete`, exit `1`, and the controller's result. No finalizer
engine invocation occurs until every job passes manifest/payload admission.
Repeating the same command retries failed jobs, revalidates completed ones, and
then enters finalization. The generated build set is rechecked against the frozen
input plan's identity, job IDs, targets and manifest hashes before handoff.

Successful execution retains `builds` and `bundle` receipts alongside the engine's
finalization result. A publication failure preserves its exit code and diagnostic;
the same command retries without recompiling already-admitted jobs. CLI signal
handling forwards cancellation through the finalizer worker to the build
coordinator and its owned compiler process groups, returning exit `5` rather than
a completion claim. Attempt logs and recoverable checkpoints are retained.

Metadata defaults to `build-dir/bundle/metadata`, and finalization state to
`build-dir/bundle/finalization`. Explicit output/state/integrity paths under the
build directory must remain in its bundle namespace, outside `bundle/release`
and `bundle/inputs`. They cannot overlap build attempts or completed checkpoints.

Combined `--dry-run` validates the input plan and policy-option structure without
executing builders, creating build state, or invoking the publication engine.
It reports `policy_verified: false`. The existing artifacts-first and build-set
entry points continue to use their original result shapes.

Run `bash scripts/tests/test_release_builds_finalize.sh` for combined execution,
failed-target gating, publication retries, exact policy forwarding and cancellation
tests. Native compilation and the network finalizer are explicit boundary
stand-ins; the coordinator, bundle collector and local manifest/payload validation
run normally. No live GitHub publication or native-host execution is claimed.
