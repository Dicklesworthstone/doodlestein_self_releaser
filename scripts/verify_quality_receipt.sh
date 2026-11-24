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

# Never feed receipt text to Bash arithmetic before validating its type and
# range. Arithmetic variables can otherwise be recursively interpreted as
# expressions, including array subscripts containing command substitutions.
# Older receipts may omit the newer counts, but explicit invalid values must
# not silently become zero through jq's // fallback.
if ! jq -es '
    def count: type == "number" and . >= 0 and . <= 2147483647 and floor == .;
    length == 1 and (.[0] | . as $receipt |
    type == "object" and (.status | type == "string") and
    (.checks | type == "array") and all(.checks[]; type == "object") and
    (if has("dry_run") then (.dry_run | type == "boolean") else true end) and
    all(["total", "passed", "failed", "planned"][];
        . as $key | $receipt[$key] | count) and
    all(["interrupted", "not_run", "observed", "executed"][];
        . as $key | if $receipt | has($key) then ($receipt[$key] | count) else true end))
' "$receipt" >/dev/null 2>&1; then
    echo "FAIL: receipt has invalid counts or inventory types" >&2
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
interrupted=$(jq -r '.interrupted // 0' "$receipt")
not_run=$(jq -r '.not_run // 0' "$receipt")
dry_run=$(jq -r '.dry_run' "$receipt")
config_sha=$(jq -r '.config_sha256 // empty' "$receipt")
config_sha_after=$(jq -r '.config_sha256_after // empty' "$receipt")

# 1. Count arithmetic must close.
if [[ $((passed + failed + planned + interrupted + not_run)) -ne "$total" ]]; then
    flunk "counts do not close: $passed+$failed+$planned+$interrupted+$not_run != $total"
fi
if [[ "$total" -eq 0 && "$status" != "config-error" && "$status" != "skipped" ]]; then
    flunk "zero checks with status=$status (vacuous aggregate)"
fi

# 2. Status must follow the counts.
if [[ "$dry_run" == "true" ]]; then
    [[ "$status" == "planned" || "$status" == "invalidated-config" ]] || flunk "dry_run receipt has status=$status"
    [[ "$passed" -eq 0 ]] || flunk "dry_run receipt claims $passed passed checks"
else
    if [[ "$failed" -gt 0 && "$status" == "passed" ]]; then
        flunk "status=passed with $failed failed checks"
    fi
    if [[ "$status" == "passed" && "$passed" -ne "$total" ]]; then
        flunk "status=passed but only $passed/$total passed"
    fi
fi

# An interrupted receipt binds the complete ordered inventory: exactly one
# stopped command and a suffix of commands that never ran. These cannot be
# presented as ordinary failures, planned dry-run work, or successful checks.
if [[ "$status" == interrupted ]]; then
    if ! jq -e '
        ([.checks[].status] | index("interrupted")) as $stop |
        .dry_run == false and .interrupted == 1 and .planned == 0 and
        .observed == .total and (.checks | length) == .total and
        .executed == (.passed + .failed + .interrupted) and
        ([.checks[] | select(.status == "passed")] | length) == .passed and
        ([.checks[] | select(.status == "failed")] | length) == .failed and
        ([.checks[] | select(.status == "interrupted")] | length) == 1 and
        ([.checks[] | select(.status == "not_run")] | length) == .not_run and
        all(.checks[:$stop][]; .executed == true and
            (.status == "passed" or .status == "failed")) and
        (.checks[$stop] | .executed == true and .passed == false and
            (.exit_code | type == "number" and . > 128 and . <= 255 and floor == .)) and
        all(.checks[$stop + 1:][]; .status == "not_run" and .executed == false and
            .passed == false and .exit_code == null and .duration_ms == 0 and
            .log_path == null and .log_sha256 == null)
    ' "$receipt" >/dev/null; then
        flunk "interrupted receipt does not bind one stopped check and its unexecuted suffix"
    fi
elif [[ "$interrupted" -ne 0 || "$not_run" -ne 0 ]] ||
     jq -e 'any(.checks[]; .status == "interrupted" or .status == "not_run")' "$receipt" >/dev/null; then
    flunk "interrupted or unexecuted checks require status=interrupted"
fi

# Configuration invalidation is a failed gate with verifiable evidence, not a
# claim that the old command inventory passed under the replacement registry.
if [[ "$status" == "invalidated-config" ]]; then
    [[ "$config_sha" =~ ^[0-9a-f]{64}$ && -n "$config_sha_after" && "$config_sha" != "$config_sha_after" ]] \
        || flunk "invalidated-config receipt does not bind different original/final configuration observations"
elif [[ "$status" != interrupted && -n "$config_sha_after" && "$config_sha" != "$config_sha_after" ]]; then
    flunk "configuration changed but status=$status"
fi

# 3. Moving-source invariant.
before=$(jq -r '.source_before // empty' "$receipt")
after=$(jq -r '.source_after // empty' "$receipt")
if [[ "$dry_run" != "true" && -n "$before" && "$before" != "$after" \
      && "$status" != "invalidated-moving-source" && "$status" != "invalidated-config" \
      && "$status" != interrupted ]]; then
    flunk "source moved (before != after) but status=$status"
fi

# 4. Retained original configuration rehashes even after the registry changes.
# Compare the current registry against the final observation for an invalidated
# gate, and against the original observation for a stable gate.
config_path=$(jq -r '.config_path // empty' "$receipt")
config_snapshot=$(jq -r '.config_snapshot_path // empty' "$receipt")
if [[ -n "$config_snapshot" ]]; then
    if [[ ! -f "$config_snapshot" || ! -r "$config_snapshot" ]]; then
        flunk "retained quality configuration is unavailable"
    elif [[ "$(sha "$config_snapshot")" != "$config_sha" ]]; then
        flunk "retained quality configuration does not match its original hash"
    fi
elif [[ "$status" == "invalidated-config" || "$status" == interrupted ]]; then
    flunk "invalidated-config receipt has no retained original configuration"
fi
expected_config_sha="$config_sha"
if [[ "$status" == "invalidated-config" || "$status" == interrupted ]]; then
    expected_config_sha="$config_sha_after"
fi
if [[ -n "$config_path" && -f "$config_path" && -n "$config_sha" ]]; then
    actual=$(sha "$config_path")
    [[ "$actual" == "$expected_config_sha" ]] \
        || flunk "config hash mismatch: receipt $expected_config_sha, file $actual (config changed since the run)"
elif [[ "$status" == "invalidated-config" || "$status" == interrupted ]]; then
    [[ "$expected_config_sha" == "absent" && -n "$config_path" && ! -e "$config_path" && ! -L "$config_path" ]] \
        || flunk "final quality configuration observation cannot be independently verified"
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
echo "receipt verified: $status, $passed/$total passed, $planned planned, $interrupted interrupted, $not_run not run, evidence complete"
exit 0
