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

Both native source staging and native compilation require host-health admission,
including ordinary builds, explicit repository host pins, and static mapping
fallback after selector failure. Source planning checks every distinct native
host before exporting source contexts or staging on any host. The native runner
checks its final resolved host again before resolving transport or preparing a
build. Missing health support is an error. Act-only source handling is unchanged;
the earlier required-remote and strict source-binding checks still apply.

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
role attribution remains complete. Separate `capacity_groups` additionally
group APFS volumes by container UUID, even when their filesystem identifiers
differ. Warnings name all observed roles, and errors identify failing locations.

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
build-root checks and also requires the complete writable-role inspection
described below. Default and split-storage macOS probes now bind selected
APFS volumes to their container identities and capacity/volume-quota observations
as described below. A fresh native macOS acceptance run remains required under
issue #46. Do not treat a cached health observation as a disk reservation,
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

## APFS shared containers and volume limits

On macOS, the default writable-role probe uses `/bin/df -Pk` to identify each
selected path's mounted device, including paths reached through Data-volume
firmlinks. It calls the system `/usr/sbin/diskutil info -plist` once per observed
filesystem and obtains one `diskutil apfs list -plist` container inventory when
any selected volume is APFS. These are read-only commands; no volume is created,
mounted, resized, cleaned or reserved. The metadata phase has a shared 20-second
deadline inside the existing host-probe timeout.

Each selected APFS volume must occur in its claimed container. The result retains
the container reference and UUID, volume device, raw container capacity, volume
usage, quota, and reservation. Effective available bytes are the **minimum** of
the original `statvfs` availability, container free capacity, and remaining volume
quota when nonzero. Reservations are evidence, not extra free bytes. Neither
purgeable space nor another volume's reservation is added to available capacity.
The effective usage percentage is at least the filesystem, container and
quota-limited percentage. This can strengthen admission, never make a tighter
filesystem limit disappear.

`filesystems` retains the individual filesystem observations. `capacity_groups`
groups shared containers without summing capacity; `apfs_container` records the
raw shared pool, while the group's `available_bytes` is the minimum effective
availability of its selected roles. A volume quota may therefore make that
group's effective availability lower than the container's raw free space. All
original role paths and filesystem identifiers remain visible. Non-APFS and
network filesystems retain their `statvfs` limits and filesystem-based groups.

Missing, duplicate, contradictory or malformed required plist fields refuse
admission. Invalid counts, absent selected volumes and unresolvable disk devices
cannot fall back to a percentage-only result. A selected read-only APFS snapshot
not present in the volume inventory is unsupported and refused. Receipt profile
`unix-writable-roles-v2` and the new host-admission fingerprint prevent reuse of
the older, container-unaware admission result.

The existing test script now includes production plist parsing and full verdict
tests using explicit XML/binary plist observations, shared-container and quota
counterexamples, and Linux filesystem controls. `DSR_TEST_APFS_BASELINE` selects
the unchanged prior module for a same-invocation comparison of its actual jq
admission policy. Those fixture tests are **not native APFS proof**. The native
`diskutil` observation test runs only on macOS and skips elsewhere; no fake
`diskutil` or replaced production function is used.

The capacity model follows [Apple's APFS space-sharing and size-limit
documentation](https://support.apple.com/guide/disk-utility/dskua9e6a110/mac).
The plist container/volume vocabulary is also used by the
[Asahi installer diskutil integration](https://github.com/AsahiLinux/asahi-installer/blob/main/src/diskutil.py).

## Complete admission for explicit split storage

Configuring `unix_storage` no longer bypasses the Cargo-home, temporary-directory,
home, Cargo-target or APFS-container/volume-quota checks. The split path retains
its original root and build-root `df` decisions, then requires the same complete
receiving-host inspection used by default admission. The overall status is the
most restrictive of the original decisions and the complete role verdict.
Failure of the additional probe refuses admission, not a fallback to two paths.

The contract's `root_min_free_bytes` and high-percentage warning allowance apply
to root and ambient roles sharing its observed capacity group. This means the
same filesystem on ordinary Unix storage, or the same independently identified
APFS container on macOS. Every such role must still satisfy the configured byte
floor using its own effective availability, including its volume quota. A root
allowance never rescues an exhausted quota or applies to another capacity pool.

**Build-root and explicit Cargo-target roles always require the normal 20 GiB
floor and 90/95-percent policy**, even if they share root's storage. Ambient roles
on another pool use that normal policy too. This preserves usable split layouts
with a spacious external build drive and an explicitly admitted internal root,
without letting an unrelated tight temporary or Cargo filesystem disappear.

The `unix-split-storage-v2` result retains the original `df` observations under
`root` and `build_root`; `roles` contains the subsequent complete observations
and APFS-effective metrics. `filesystems` and `capacity_groups` retain their
individual identities. `unix_storage_contract` records the selected contract.
Each role records `capacity_policy`, `min_free_bytes`, `pressure_status` before
the explicit percentage allowance, and final `status`. Human diagnostics show
both original observations and every role, including probe-failure reasons.
The new host-admission fingerprint invalidates earlier two-path cached verdicts.

Explicit split probing now needs Python 3 and the same native macOS metadata
tools as the default path. All probes remain read-only, with the existing helper
deadlines. They are sequential observations, not an atomic capacity reservation.
No directory is created, storage cleaned, gate disabled or limit reduced.

The existing test script includes actual low-capacity `/dev/shm` observations
for split temp/Cargo/target roles and production policy tests with explicit APFS
plist observations. Set `DSR_TEST_SPLIT_BASELINE` to the unchanged pre-change
`host_health.sh`: in the same invocation the old split checker admits each
low-capacity ambient role while the candidate refuses it. Healthy split controls,
same-pool allowances, independent build limits and per-volume quotas remain
covered. Sourceable helper testing does not by itself qualify the complete
configuration/yq, monolithic CLI, live SSH or native macOS paths.
