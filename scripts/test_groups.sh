#!/usr/bin/env bash
# Run independent integration scenarios under the caller's single deadline.
# WORK must contain only the pristine fixture; checks/failures are counters.

dsr_test_groups() {
    local fixture_root=$WORK group worker reports group_index rc counts child_checks child_failures
    local -a groups=("$@") workers=() pids=()
    ((${#groups[@]} > 0)) || return 1
    # Finish all copies before launching any scenario, so no worker inherits
    # another worker's mutable results. Each gets its own keys and shell state.
    for group in "${groups[@]}"; do
        worker=$(mktemp -d "${TMPDIR:-/tmp}/dsr-test-$group.XXXXXXXX") || return 1
        cp -a -- "$fixture_root/." "$worker/" || return 1
        workers+=("$worker")
    done
    reports=$(mktemp -d "$fixture_root/group-results.XXXXXXXX") || return 1
    for group_index in "${!groups[@]}"; do
        (
            WORK=${workers[group_index]}
            trap 'rm -rf -- "$WORK"' EXIT
            checks=0 failures=0
            "${groups[group_index]}"
            rc=$?
            printf '%d %d\n' "$checks" "$failures" > "$reports/group-$group_index.counts" || exit 1
            ((rc == 0 && failures == 0))
        ) > "$reports/group-$group_index.log" 2>&1 &
        pids+=("$!")
    done
    for group_index in "${!pids[@]}"; do
        rc=0; wait "${pids[group_index]}" || rc=$?
        if ! cat "$reports/group-$group_index.log"; then
            failures=$((failures+1))
        fi
        counts=''
        [[ ! -f "$reports/group-$group_index.counts" ]] || counts=$(< "$reports/group-$group_index.counts")
        if [[ "$counts" =~ ^([1-9][0-9]*)\ ([0-9]+)$ ]]; then
            child_checks=${BASH_REMATCH[1]}; child_failures=${BASH_REMATCH[2]}
            if ((child_failures <= child_checks)); then
                checks=$((checks+child_checks)); failures=$((failures+child_failures))
                if ((rc != 0 && child_failures == 0)); then failures=$((failures+1)); fi
            else
                printf 'FAIL: inconsistent counts from %s (exit %d)\n' "${groups[group_index]}" "$rc"
                failures=$((failures+1))
            fi
        else
            printf 'FAIL: missing or invalid counts from %s (exit %d)\n' "${groups[group_index]}" "$rc"
            failures=$((failures+1))
        fi
    done
    [[ "$failures" -eq 0 ]]
}
