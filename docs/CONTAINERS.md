# Container builds and releases

The `src/docker.sh` module implements the container workflow tracked by
`bd-1jt.3.8`. Docker, Buildx, Syft and Cosign remain external tools. It does not
install toolchains, enable emulation, or change your globally selected builder.

## Build outputs

```bash
# Plan without contacting Docker, the registry, or signing services.
bash src/docker.sh build tool 1.2.3 --repo-path /path/to/tool --push --dry-run

# Push a version tag. Add --tag latest explicitly when appropriate.
bash src/docker.sh build tool 1.2.3 --repo-path /path/to/tool --push

# Without --push or --local, export an OCI archive instead of a hidden cache-only result.
bash src/docker.sh build tool 1.2.3 --repo-path /path/to/tool --output /tmp/tool.oci.tar

# Load one platform into the local Docker image store.
bash src/docker.sh build tool 1.2.3 --repo-path /path/to/tool --local --platform linux/arm64
```

Defaults are `DOCKER_REGISTRY=ghcr.io/dicklesworthstone`,
`DOCKER_PLATFORMS=linux/amd64,linux/arm64`, and `DOCKER_BUILDER_NAME=dsr-builder`.
The source is `--repo-path`, the registered tool's `local_path`, or
`/data/projects/TOOL`, in that order. Dockerfiles are found in the repository root,
`docker/`, or `build/`; `--dockerfile` can select another file inside the source
repository. The **repository root** is always the context, including for nested
Dockerfiles. The source checkout and Docker daemon are trusted; this is not an
immutable-source or sandboxed build attestation.

`--local` without an explicit platform uses Buildx's single default platform;
its receipt records an empty requested-platform list rather than inventing a
host architecture. Multi-platform `--local` and contradictory exporters fail
before invoking Docker. The local Docker exporter disables BuildKit attestations
rather than claiming the classic Docker image store preserves them.

OCI outputs default to `DOCKER_OUTPUT_DIR/TOOL-VERSION.oci.tar`, or the DSR XDG
state `containers/` directory when that variable is unset. They are staged next
to the destination and published without replacing an existing file. Output
inside the build context is rejected. A receipt includes the archive's SHA256
and size. This hashes the exported bytes; it is not an OCI-layout validator.

Build stdout contains one JSON receipt with the exporter, requested platforms,
context, tags, builder, and Buildx `containerimage.digest`. Missing, malformed,
multiple, or inconsistent Buildx metadata is a failure even if the subprocess
exited zero. `reference` is `REPOSITORY@sha256:DIGEST`. Buildx/registry output is
sent to stderr. The metadata is a trusted-builder observation, not independent
registry or signature verification.

`latest` is no longer added implicitly. Repeating `--tag` deduplicates explicit
tags, and a version beginning with `v` is not double-prefixed. Version strings
must be valid Docker tags; unsupported syntax is rejected, not rewritten.

## Release failure behavior

```bash
bash src/docker.sh release tool 1.2.3 --repo-path /path/to/tool
bash src/docker.sh release-json tool 1.2.3 --repo-path /path/to/tool --dry-run
```

Release preflights Syft and Cosign before pushing, obtains the image digest from
its own build, and passes that exact immutable reference to subsequent steps.
A failed signing or SBOM operation is a failed release, not a warning followed
by success. The scanner writes into a private file, and its output is checked
before it can reach `cosign attest`. Invalid or partial scanner output is never
streamed into a concurrently running attester.

`--skip-sign` explicitly skips the image signature only. It does not skip the
required SBOM attestation or the Cosign dependency needed for that attestation.
Receipts distinguish skipped signatures from submitted ones. A successful tool
acknowledgement does not independently prove signature validity or complete
multi-architecture SBOM coverage. Single-reference Syft scanning chooses one
platform; callers must not interpret that observation as a complete inventory
of every architecture in an image index.

Standalone `sign` and `attest` accept immutable qualified references only. They
do not resolve mutable tags separately between scanning and signing. Global
`DRY_RUN=true` is honored by all entry points; plans are reported as `planned`,
not completed builds or releases.

`build-json` and `release-json` preserve the operation's nonzero exit status while
emitting a JSON error object. Diagnostics are separate from the structured
`result`. Sourced APIs are `docker_build`, `docker_release`, `docker_sign`,
`docker_attest_sbom`, `docker_build_json`, and `docker_release_json`. Existing
`dsr docker` dispatch uses these same library functions; the standalone commands
also expose all module options without the monolithic CLI's older argument parser.

Existing Docker credential configuration remains usable. For GHCR, explicitly
set `DSR_GH_TOKEN`, `GITHUB_TOKEN`, or `GH_TOKEN` (in that precedence order) to log
in before pushing; set `GITHUB_USER` when the local username is not the GitHub
username. Tokens are passed over stdin, never command arguments. Standalone login
can also use the secrets module or `gh auth token --hostname github.com`. A token's
presence alone is not treated as proof of registry authorization.

Individual external effects are not a transaction: a later failure can leave a
pushed image or signature. Nothing is deleted to hide failure. Do not assume
version tags are immutable merely because downstream operations use digests.

## Validation

```bash
bash scripts/tests/test_docker_release.sh
bats tests/unit/test_docker.bats
```

The standalone suite uses real Bash, jq, files, archive bytes, SHA256 and
publication operations with explicit Docker/Syft/Cosign process fixtures. It does
not perform native container builds, registry uploads, OIDC, or cryptographic
verification. Live tool integration is a separate validation requirement.
