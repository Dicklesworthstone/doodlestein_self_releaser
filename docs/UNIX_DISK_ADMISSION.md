# Unix disk free-space admission

Unix host health now requires **20 GiB (21,474,836,480 bytes) available** in
addition to the existing usage thresholds. The comparison uses the raw available
capacity returned by the filesystem, not the rounded `available_gb` display.
Exactly 20 GiB passes the byte floor; percentages still warn above 90% and fail
above 95%. The explicit split contract retains its `df -Pk` probes.

This closes the immediate false-green case in issue #46: an APFS System-volume
report of 84% used with 2,427,860 KiB available must not be `ok`. A percentage can
look acceptable while the shared APFS container has almost no writable capacity.
The JSON includes `available_bytes` and `min_free_bytes`; the human error names
the capacity floor instead of incorrectly claiming usage exceeds 95%.

The opt-in `unix_storage` split-volume contract retains its explicitly configured
`root_min_free_bytes` and its existing high-percentage warning exception. Its
root floor is now enforced even when the root's reported percentage is low.
The separately probed build root must satisfy both the standard percentage
thresholds and the 20 GiB floor. A healthy external build root cannot compensate
for an internal root below the contract floor, or vice versa. Both role verdicts
remain visible in the report.

Malformed, excessive, or non-decimal counts fail before shell arithmetic. An
empty, invalid, or unsuccessful disk-probe result cannot produce a healthy public
host verdict. The admission fingerprint changed, so cached results created by
the old percentage-only policy cannot authorize a build under the new policy.
Windows storage policy is unchanged.

## Default writable locations

Without a `unix_storage` opt-in, the host now checks all of these roles in its
own process environment: root, home, configured build root (or `/var/tmp`), Cargo
home (`CARGO_HOME` or `$HOME/.cargo`), and temporary storage (`TMPDIR` or `/tmp`).
An explicit `CARGO_TARGET_DIR` adds a required target role. The build root is the
base used by the native runner for its private source, target and Cargo stages;
this host-health observation does not inspect a particular uncreated build run.

Each role has its own path, resolved probe path, filesystem identifier, available
and total byte counts, effective usage, free-byte floor, and verdict. Every role
must pass. Tight internal Cargo or temporary storage cannot hide behind a healthy
external build root, and a tight external build root cannot hide behind `/`.
Shared filesystem identifiers are grouped without summing their free bytes;
role attribution remains complete. Warnings name all observed roles, and errors
identify the failing locations.

The remote probe uses isolated Python 3 and `statvfs` in the receiving host's
environment. Available bytes use `f_bavail`, not privileged/reserved free space.
Effective usage is the ceiling of `100 * (total - available) / total`, rather
than the misleading System-volume used-block percentage. On macOS with an
existing `/System/Volumes/Data`, the root role probes that writable Data volume.
The actual user home and temporary paths are also independently observed.

Configured build roots and explicit environment locations must exist as
directories. The default, unconfigured `$HOME/.cargo` may not exist yet: only
that implicit role probes its nearest existing parent and reports both paths.
No directory is created by a probe. Relative paths, control characters, missing
required directories, missing remote Python, malformed inventories, or failed
filesystem reads produce an error, never an assumed healthy verdict. The simple
no-yq host reader retains `build_root`; a full checkout uses its production YAML
reader when available. Prior root-only cached admissions are invalidated.

## Scope and remaining work

Default locations are host-level observations, not per-project command-environment
resolution. An explicit `unix_storage` contract retains its existing root and
build-root role policy with the corrected floors; it does not gain automatic
ambient-role discovery in this increment. Distinct APFS volumes sharing one
container are not yet grouped by container identity. Their capacities are never
summed, but full APFS-container inventory and a fresh native macOS acceptance run
remain follow-up work under issue #46. Do not treat a cached health observation as a disk reservation,
per-build capacity estimate, or a substitute for the independent SBH/native
release gates. No storage is cleaned, reconfigured, or automatically expanded.

## Reproduction

Run `bash scripts/tests/test_disk_free_floor.sh`. It exercises the complete
sourceable host-health module, real Bash/jq/df, actual local filesystem capacity,
raw-count boundary cases, split-storage decisions, and public error propagation.
In a complete checkout it loads the real configuration module; a partial
workspace may initialize a sourceable consumer's config cache and use the no-yq
reader. Real-yq integration requires the full module rather than a replacement.
The monolithic CLI is not exercised. No production function or binary is
replaced. APFS root numbers are explicit incident fixtures, not a live APFS
filesystem. A small existing `/dev/shm` provides an optional real low-capacity
build-root, Cargo and temporary-storage control without filling a disk; these
cases skip if unavailable. The public host-health comparison uses the identical
actual low-capacity temporary filesystem with the unchanged incumbent and the
new module, showing a healthy verdict versus rejection in the same invocation.

Set `DSR_TEST_DISK_BASELINE` to the unchanged prior `host_health.sh` to compare the
same supplied root counts and real build-root `df` in one invocation. The prior
split checker admits the 2.32 GiB root; the new checker refuses it. No network,
compiler, signing, or release upload is required. Tests retain their evidence.
