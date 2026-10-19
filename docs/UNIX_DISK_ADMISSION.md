# Unix disk free-space admission

Unix host health now requires **20 GiB (21,474,836,480 bytes) available** in
addition to the existing usage thresholds. The comparison uses the raw available
KiB returned by `df -Pk`, not the rounded `available_gb` display. Exactly 20 GiB
passes the byte floor; percentages still warn above 90% and fail above 95%.

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

## Scope and remaining work

This change enforces capacity floors on the paths already probed. The default
Unix probe still reads `/`; the split contract additionally reads its configured
build root. Automatic discovery of every default writable role (Cargo home,
temporary storage, Data volume, source/target stages), APFS-container grouping,
and a fresh native macOS acceptance run remain follow-up work under issue #46.
Do not treat this patch or a cached health observation as a disk reservation,
per-build capacity estimate, or a substitute for the independent SBH/native
release gates. No storage is cleaned, reconfigured, or automatically expanded.

## Reproduction

Run `bash scripts/tests/test_disk_free_floor.sh`. It exercises the complete
sourceable host-health module, real Bash/jq/df, actual local filesystem capacity,
raw-count boundary cases, split-storage decisions, and public error propagation.
It initializes a sourceable consumer's config cache; the monolithic CLI and full
configuration initialization are not exercised. No production function or binary
is replaced. APFS root numbers are explicit incident fixtures, not a live APFS
filesystem. A small existing `/dev/shm` provides an optional real low-capacity
build-root control without filling a disk; that case skips if unavailable.

Set `DSR_TEST_DISK_BASELINE` to the unchanged prior `host_health.sh` to compare the
same supplied root counts and real build-root `df` in one invocation. The prior
split checker admits the 2.32 GiB root; the new checker refuses it. No network,
compiler, signing, or release upload is required. Tests retain their evidence.
