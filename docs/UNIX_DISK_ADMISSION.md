# Unix disk free-space admission

Host health budgets **20 GiB (21,474,836,480 bytes) per configured simultaneous
build** for each default writable storage location. The host's `concurrency`
setting supplies the build count and defaults to two when omitted, matching the
host scheduler. Two build slots require 40 GiB available; four slots require
80 GiB. An explicit `concurrency: 1` retains the 20 GiB single-build requirement.
The comparison uses the raw available capacity returned by the filesystem,
not the rounded `available_gb` display. Exactly the required byte floor passes.
Usage above 90% remains a visible warning, including values above
95%; a percentage alone does not refuse a host that meets its byte floor.
The explicit Unix split contract retains its `df -Pk` probes.

This closes the immediate false-green case in issue #46: an APFS System-volume
report of 84% used with 2,427,860 KiB available must not be `ok`. A percentage can
look acceptable while the shared APFS container has almost no writable capacity.
The JSON includes `available_bytes` and `min_free_bytes`; the human error names
the capacity floor instead of incorrectly claiming usage exceeds 95%.

This also fixes issue #51's opposite failure: 179 GiB free at 96% usage on a
large volume produces a warning and can pass readiness with room for up to
eight configured build slots. Nine slots require 180 GiB and refuse that same
179 GiB observation. Every required role must still meet its own floor;
2.32 GiB remains an error at any usage percentage.

The opt-in `unix_storage` split-volume contract retains its explicitly configured
`root_min_free_bytes`. Its root floor is enforced even when the root's reported
percentage is low. This host reserve is not multiplied by concurrency. The
separately probed build root must satisfy the 20 GiB-per-slot floor. A healthy
external build root cannot compensate for an internal root below the contract
floor, or vice versa. Both role verdicts
remain visible in the report.

Malformed, fractional, zero, negative, or excessive concurrency values refuse
admission. Multiplication must fit the exact integer range of JSON numbers;
overflow cannot reduce the required space. Malformed, excessive, or non-decimal
disk counts fail before shell arithmetic. An empty, invalid, or unsuccessful
disk-probe result cannot produce a healthy public
host verdict. The admission fingerprint changed, so cached results created by
an older policy cannot authorize a build under the new policy.

The unconfigured Windows system-drive probe uses the same 20 GiB-per-slot floor and
percentage-warning policy. It rounds free bytes down to KiB before transport,
so a value just below the floor cannot round up into admission. Its JSON now
retains `available_bytes`, `min_free_bytes`, and `concurrent_builds` alongside
the display value. The writable-role result also reports `concurrent_builds`.
Configured Windows split-storage keeps its source budget and source reserve.
The target must satisfy the greater of its configured `target_min_free_bytes`
and the default per-slot requirement; an explicit budget is never multiplied a
second time. Mapping identity and locking requirements remain unchanged.

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
host's configured default for native staging. This general health observation
is supplemented by the actual paths selected for each native operation below.

Each role has its own path, resolved probe path, filesystem identifier, available
and total byte counts, effective usage, free-byte floor, and verdict. Every role
must pass. Tight internal Cargo or temporary storage cannot hide behind a healthy
external build root, and a tight external build root cannot hide behind `/`.
Shared filesystem identifiers are grouped without summing their free bytes
or multiplying the slot budget by the number of roles; role attribution remains
complete. Separate `capacity_groups` additionally
group APFS volumes by container UUID, even when their filesystem identifiers
differ. Warnings name all observed roles, and errors identify failing locations.

The remote probe uses isolated Python 3 and `statvfs` in the receiving host's
environment. Available bytes use `f_bavail`, not privileged/reserved free space.
Effective usage is the ceiling of `100 * (total - available) / total`, rather
than the misleading System-volume used-block percentage. On macOS with an
existing `/System/Volumes/Data`, the root role probes that writable Data volume.
The actual user home and temporary paths are also independently observed.

For these default host roles, configured build roots and explicit environment
locations must exist as directories. The default, unconfigured `$HOME/.cargo`
may not exist yet: that implicit role probes its nearest existing parent and
reports both paths.
No directory is created by a probe. Relative paths, control characters, missing
required directories, missing remote Python, malformed inventories, or failed
filesystem reads produce an error, never an assumed healthy verdict. The simple
no-yq host reader retains `build_root`; a full checkout uses its production YAML
reader when available. Prior root-only cached admissions are invalidated.

## Paths selected for a native operation

A healthy default location does not admit a different source, output, cache or
temporary directory selected by a release recipe. Native operations therefore
pass an explicit writable-path inventory to host health in addition to the
default roles. The inventory contains role/path pairs for the receiving host;
the coordinator's filesystem does not stand in for the destination host.

Source planning derives the actual destination before requesting admission.
This includes the `DSR_STRICT_BUILD_ROOT` override, a configured host build root,
fresh ordinary source staging, and the configured destination used by an
in-place sync. Fresh snapshot parents and declared source-dependency destinations
are included as well; an in-place sibling can reside on a different filesystem
from the primary source. Sibling destinations use the same path and fallback
basename rules as the transfer, including configured trailing slashes.
The source plan also checks explicit absolute writable locations from each
target's effective recipe. All required host, capability and path
combinations must pass before source contexts are exported or any host receives
source files. Two targets on one host can require different writable locations.

Native execution resolves its final working directory and effective environment
before preparing private Cargo state or build stages. This inventory includes
the selected source and stage paths, private Cargo home and output destinations,
`strict_cargo_cache_root`, and applicable recipe `TMPDIR` and
`CARGO_BUILD_BUILD_DIR` locations. Ordinary Rust builds retain an absolute
configured `CARGO_TARGET_DIR` as a base for an exclusive per-attempt directory.
Strict Rust builds instead use their generated snapshot-relative Cargo paths;
the overwritten configuration values do not describe those writes. Relative
recipe locations are resolved against the final build working directory before
native admission. Harmless `.` components in relative locations are normalized;
parent traversal through `..` is refused. Duplicate environment assignments use
the launcher's effective last assignment, including when a relative ordinary
Cargo target setting is replaced by DSR's generated destination. Unresolved
shell expansions are refused rather than probed as literal paths that the
launcher would later interpret differently. Cargo's brace-based
`CARGO_BUILD_BUILD_DIR` templates likewise require a resolved literal path;
they cannot authorize a probe of the unexpanded template. Ordinary Rust clears
an inherited `CARGO_BUILD_BUILD_DIR` before applying any admitted recipe value.

Native Go recipes also admit explicitly configured `GOCACHE`, `GOMODCACHE`,
and `GOTMPDIR` destinations as `go_cache`, `go_modcache`, and `go_temp` roles.
Both cache paths must be absolute. `GOCACHE=off` is refused because Go requires
a build cache. Relative `GOTMPDIR` resolves against the actual build working
directory before preparation and compilation; source planning checks its
absolute form when supplied. Empty values retain Go's target-host defaults.
Admission does not infer a module cache from `GOPATH`: even `GOENV=off` leaves
toolchain-level defaults in `GOROOT/go.env` active. Unused `GOPATH` entries
and `GOBIN` do not add disk requirements for a build. These rules cover the
configured destinations; discovery of ambient, toolchain-level or persisted
target-host Go defaults remains separate. The coordinator never substitutes
its own Go environment for the builder's.

The internal `host_health_check` and `host_health_is_ready` APIs accept
`--writable-paths` with a bounded JSON array of objects containing exactly `role`
and `path`. Paths must be absolute Unix paths without control characters or
dot components. Exact duplicate role/path pairs are collapsed; distinct roles
and destinations are preserved. The request is encoded as data for the remote
Python probe. It is never evaluated as shell syntax.

An explicit future output directory may not exist yet. Its probe walks to the
nearest existing directory and retains both the selected `path` and observed
`probe_path`. Existing directory symlinks retain their normal filesystem
resolution. A dangling or looping link, a file where a directory is needed, an
inaccessible ancestor, or an unreadable filesystem refuses admission. The probe
does not create a directory to make its own check succeed. Existing source and
output custody checks still decide whether a path is acceptable for staging.

Requested rows carry `requested: true`; `requested_paths` records the exact
normalized request. Admission requires matching coverage in the returned
inventory. Each requested location must satisfy the normal **20 GiB per
configured build slot** floor and percentage-warning policy, including when
it shares the root's capacity group under
an explicit split-storage contract. Shared filesystems and APFS containers are
still grouped without adding their free space together.

Explicit path requests always perform a fresh probe. Their normalized inventory
also contributes to the admission fingerprint, so a cached default-host result
or a result for another path cannot authorize the operation. A refusal occurs
before native source transfer, cache preparation or compilation for that phase.
The host-health cache and diagnostic output are independent of build staging;
the probe does not reserve or modify destination storage.

Cached default-host admissions must also retain complete disk evidence. Before
reusing a successful cache entry, DSR recomputes the Unix role verdicts from
their raw capacity observations, including APFS container and volume limits,
and verifies the retained filesystem and capacity-group summaries. Split-storage
entries must additionally satisfy their original root/build-root observations
or Windows source/target budgets and mapping/locking evidence. The receipt must
agree with the current host platform, build root, concurrency and storage contract.
A matching configuration fingerprint alone cannot authorize missing disk data,
contradictory statuses or a reduced capacity budget. Invalid success entries cause
a fresh probe; cached failures remain refusals. Valid percentage-pressure
warnings with sufficient absolute space remain eligible for caching.

Resume continues to verify completed artifact receipts before deciding what
needs execution. An unfinished native task must pass admission for its current
effective paths before it can prepare or compile. Storage admission does not
fabricate an execution receipt, repeat a completed target, or override the
separate source, toolchain, retry and publication checks. Windows retains its
existing storage contracts, and workflow execution through `act` is unchanged.

## Scope and remaining work

Default health reports remain host-level observations; native operations add
the effective paths described above. The inventory covers DSR's staging and
supported recipe storage settings. It cannot predict arbitrary filesystem writes
inside a custom build command or reserve space against other processes.
An explicit `unix_storage` contract retains its existing root and build-root
checks and also requires the complete writable-role inspection
described below. Default and split-storage macOS probes now bind selected
APFS volumes to their container identities and capacity/volume-quota observations
as described below. A fresh native macOS acceptance run remains required under
issue #46. Do not treat a cached health observation as a disk reservation,
a measured capacity estimate for a particular build, or a substitute for the
independent SBH/native release gates. No storage is cleaned, reconfigured,
or automatically expanded.

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

Run `bash scripts/tests/test_host_health.sh --disk-capacity-only` for the
concurrent-build cases. They cover the 179 GiB/96% incident, exact and one-KiB
below-floor boundaries, shared APFS containers with distinct volume identities,
volume quotas, and malformed or overflowing concurrency. The Bash controller
uses deterministic probe observations for Windows; these cases do not claim
native PowerShell execution or allocate large test files. An omitted-concurrency
case compares the actual scheduler and health defaults. The existing 20 GiB
free-floor fixtures explicitly select one build slot.

The writable-path cases exercise future-directory ancestor resolution, literal
path transport, ordinary directory symlinks, rejected dangling links and file
ancestors, requested-role floors, exact receipt coverage and stale-cache refusal.
The APFS policy cases also cover requested locations sharing a container with
ambient roles and the split-root allowance. Run
`bash scripts/tests/test_act_runner_native.sh --host-writable-path-tests` for the
native admission boundaries and effective recipe-path selection. Those tests
identify their host/compiler boundaries explicitly; they do not establish native
APFS or production release qualification.

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
its root and build-root `df` observations, then requires the same complete
receiving-host inspection used by default admission. The overall status is the
most restrictive of the original decisions and the complete role verdict.
Failure of the additional probe refuses admission, not a fallback to two paths.

The contract's `root_min_free_bytes` applies
to root and ambient roles sharing its observed capacity group. This means the
same filesystem on ordinary Unix storage, or the same independently identified
APFS container on macOS. Every such role must still satisfy the configured byte
floor using its own effective availability, including its volume quota. A root
allowance never rescues an exhausted quota or applies to another capacity pool.

**Build-root and explicit Cargo-target roles always require the normal 20 GiB
per configured build slot floor**, even if they share root's storage. Ambient roles
on another pool use that normal policy too. This preserves usable split layouts
with a spacious external build drive and an explicitly admitted internal root,
without letting an unrelated tight temporary or Cargo filesystem disappear.

The `unix-split-storage-v2` result retains the original `df` observations under
`root` and `build_root`; `roles` contains the subsequent complete observations
and APFS-effective metrics. `filesystems` and `capacity_groups` retain their
individual identities. `unix_storage_contract` records the selected contract.
Each role records `capacity_policy`, `min_free_bytes`, `pressure_status` under
the default 20 GiB-per-slot policy, and final `status` under its applicable floor. A
configured root floor can be lower or higher than the default; both verdicts
remain visible. All roles retain percentage warnings above 90%. Human diagnostics show
both original observations and every role, including probe-failure reasons.
The new host-admission fingerprint invalidates earlier two-path cached verdicts.

Explicit split probing now needs Python 3 and the same native macOS metadata
tools as the default path. All probes remain read-only, with the existing helper
deadlines. They are sequential observations, not an atomic capacity reservation.
No directory is created or storage cleaned. The configured root reserve stays
fixed while default build floors account for the host's configured slots.

The existing test script includes actual low-capacity `/dev/shm` observations
for split temp/Cargo/target roles and production policy tests with explicit APFS
plist observations. Set `DSR_TEST_SPLIT_BASELINE` to the unchanged pre-change
`host_health.sh`: in the same invocation the old split checker admits each
low-capacity ambient role while the candidate refuses it. Healthy split controls,
same-pool allowances, independent build limits and per-volume quotas remain
covered. Sourceable helper testing does not by itself qualify the complete
configuration/yq, monolithic CLI, live SSH or native macOS paths.

For the percentage correction, set `DSR_TEST_CAPACITY_BASELINE` to the unchanged
`host_health.sh` from before the fix when running `test_disk_free_floor.sh`.
The same invocation compares both actual classifiers: spacious high-usage
volumes change from refusal to warning; low-space cases retain their refusals,
and unchanged boundary cases retain their original verdicts. APFS fixtures also
verify that effective container usage stays visible, quotas and individual role
floors still refuse, and split contracts cannot relax unrelated write locations.
