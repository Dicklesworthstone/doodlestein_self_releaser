# Add act matrix filtering support for targeted platform builds

## Implemented

Added two new flags to `dsr build` for matrix filtering:

### New Flags

- `--only-act`: Only build targets that use act (Docker-based, no SSH required)
- `--only-native`: Only build targets that require native SSH builds (macOS/Windows)

### Usage Examples

```bash
# Build only Linux targets (via act, no SSH needed)
dsr build ntm --only-act

# Build only native targets (macOS/Windows via SSH)
dsr build ntm --only-native

# Combine with other flags
dsr build ntm --only-act --parallel
dsr build br --only-native --no-sync
```

### How It Works

1. After targets are loaded from config or CLI, the filter is applied
2. Each target is checked via `act_platform_uses_act()` which looks at the `act_job_map` config
3. Targets with a job mapping → act targets
4. Targets without a job mapping → native targets
5. If filtering results in empty target list, returns error with helpful message
6. The flags are mutually exclusive (cannot specify both --only-act and --only-native)

### Files Modified

- `dsr`: Added `--only-act` and `--only-native` flags with filtering logic
- `scripts/tests/test_native_build_e2e.sh`: Added matrix filter tests

### Tests Added

- `test_only_act_flag()`: Verifies --only-act filters to act-compatible targets
- `test_only_native_flag()`: Verifies --only-native filters to native targets
- `test_only_act_and_native_mutual_exclusion()`: Verifies both flags cannot be specified together

### Test Results

All tests pass:
- test_act_runner.sh: 14/0
- test_act_runner_native.sh: 30/0
- test_native_build_e2e.sh: 23/0 (3 skipped live tests)
