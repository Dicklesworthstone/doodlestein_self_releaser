#!/usr/bin/env bash
# verify_quality_receipt.sh — standalone verifier for dsr quality
# aggregate receipts (frankensim bead oxmp).
#
# Recomputes, from the receipt and the durable artifacts it names,
# everything the aggregate binds: per-check log hashes, the config
# hash, the count arithmetic (passed/failed/planned vs total and
# status), and the moving-source invariant. Independent of any dsr
# in-memory state: if this passes, an external consumer can trust the
# receipt from its bytes alone.
#
# Usage: verify_quality_receipt.sh <receipt.json>
# Exit:  0 verified; 1 any recomputation mismatch; 4 unusable receipt.
set -uo pipefail

receipt="${1:-}"
if [[ -z "$receipt" || ! -r "$receipt" ]]; then
    echo "usage: verify_quality_receipt.sh <receipt.json>" >&2
    exit 4
fi
if ! jq -e '.' "$receipt" >/dev/null 2>&1; then
    echo "FAIL: receipt is not valid JSON" >&2
    exit 4
fi

sha() {
    if command -v sha256sum &>/dev/null; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'; fi
}

fails=0
flunk() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }

status=$(jq -r '.status' "$receipt")
total=$(jq -r '.total' "$receipt")
passed=$(jq -r '.passed' "$receipt")
failed=$(jq -r '.failed' "$receipt")
planned=$(jq -r '.planned' "$receipt")
dry_run=$(jq -r '.dry_run' "$receipt")

# 1. Count arithmetic must close.
if [[ $((passed + failed + planned)) -ne "$total" ]]; then
    flunk "counts do not close: $passed+$failed+$planned != $total"
fi
if [[ "$total" -eq 0 && "$status" != "config-error" && "$status" != "skipped" ]]; then
    flunk "zero checks with status=$status (vacuous aggregate)"
fi

# 2. Status must follow the counts.
if [[ "$dry_run" == "true" ]]; then
    [[ "$status" == "planned" ]] || flunk "dry_run receipt has status=$status"
    [[ "$passed" -eq 0 ]] || flunk "dry_run receipt claims $passed passed checks"
else
    if [[ "$failed" -gt 0 && "$status" == "passed" ]]; then
        flunk "status=passed with $failed failed checks"
    fi
    if [[ "$status" == "passed" && "$passed" -ne "$total" ]]; then
        flunk "status=passed but only $passed/$total passed"
    fi
fi

# 3. Moving-source invariant.
before=$(jq -r '.source_before // empty' "$receipt")
after=$(jq -r '.source_after // empty' "$receipt")
if [[ "$dry_run" != "true" && -n "$before" && "$before" != "$after" \
      && "$status" != "invalidated-moving-source" ]]; then
    flunk "source moved (before != after) but status=$status"
fi

# 4. Config hash recomputes (when the config file still exists).
config_path=$(jq -r '.config_path // empty' "$receipt")
config_sha=$(jq -r '.config_sha256 // empty' "$receipt")
if [[ -n "$config_path" && -f "$config_path" && -n "$config_sha" ]]; then
    actual=$(sha "$config_path")
    [[ "$actual" == "$config_sha" ]] \
        || flunk "config hash mismatch: receipt $config_sha, file $actual (config changed since the run)"
fi

# 5. Every executed check's durable log rehashes to its bound value.
while IFS=$'\t' read -r cmd log_path log_sha executed; do
    [[ "$executed" != "true" ]] && continue
    if [[ -z "$log_path" || ! -f "$log_path" ]]; then
        flunk "executed check '$cmd' has no durable log at '$log_path'"
        continue
    fi
    actual=$(sha "$log_path")
    [[ "$actual" == "$log_sha" ]] \
        || flunk "log hash mismatch for '$cmd': receipt $log_sha, file $actual"
    grep -q '^# exit_code: ' "$log_path" \
        || flunk "log for '$cmd' lacks the exit_code trailer (truncated?)"
done < <(jq -r '.checks[] | [.command, (.log_path // ""), (.log_sha256 // ""), (.executed | tostring)] | @tsv' "$receipt")

if [[ $fails -gt 0 ]]; then
    echo "receipt verification FAILED: $fails finding(s)" >&2
    exit 1
fi
echo "receipt verified: $status, $passed/$total passed, $planned planned, evidence complete"
exit 0
