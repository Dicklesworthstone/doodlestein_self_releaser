#!/usr/bin/env bash
# Real Git objects/ref transport; fixtures are retained for inspection.
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
for dependency in git jq tar; do
  command -v "$dependency" >/dev/null 2>&1 || { printf 'SKIP: requires %s\n' "$dependency"; exit 0; }
done
# shellcheck source=../../src/git_ops.sh
source "$ROOT/src/git_ops.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/dsr-git-build-context.XXXXXXXX") || exit 1
printf 'Fixtures: %s\n' "$WORK"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
PASS=0 FAIL=0 STATUS=0
check() {
  local label="$1"; shift
  if "$@"; then PASS=$((PASS + 1)); printf 'PASS: %s\n' "$label"
  else FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$label" >&2; fi
}
equal() { [[ "$1" == "$2" ]]; }
copy_source() {
  mkdir "$2" || return 1
  tar -C "$1" --exclude=.git -cf - . | tar -C "$2" -xf -
}
restore() {
  local name="$1" context="$2"
  STATUS=0
  git_ops_restore_build_context "$WORK/$name" "$context" \
    > "$WORK/$name.receipt.json" 2> "$WORK/$name.log" || STATUS=$?
}
refused() {
  local name="$1" context="$2"
  mkdir "$WORK/$name" || exit 1
  restore "$name" "$context"
  check "$name refuses Git context admission" equal "$STATUS" 4
  check "$name emits no usable receipt" test ! -s "$WORK/$name.receipt.json"
  check "$name refuses before creating Git metadata" test ! -e "$WORK/$name/.git"
}
refuse_export() {
  local name="$1" source="$2" diagnostic="$3"
  STATUS=0
  git_ops_export_build_context "$source" "$WORK/$name-context" \
    > "$WORK/$name.export.json" 2> "$WORK/$name.export.log" || STATUS=$?
  check "$name source export refuses unsupported state" equal "$STATUS" 4
  check "$name gives an actionable diagnostic" grep -Fq -- "$diagnostic" "$WORK/$name.export.log"
  check "$name refusal emits no receipt or context directory" test ! -e "$WORK/$name-context"
  check "$name refusal emits no successful receipt" test ! -s "$WORK/$name.export.json"
}
mkdir "$WORK/source" "$WORK/template" || exit 1
git init -q --template="$WORK/template" -b main "$WORK/source" || exit 1
git -C "$WORK/source" config user.name 'DSR build context fixture'
git -C "$WORK/source" config user.email test@example.invalid
printf 'initial\n' > "$WORK/source/tracked.txt"
printf 'base\n' > "$WORK/source/staged.txt"
git -C "$WORK/source" add tracked.txt staged.txt || exit 1
git -C "$WORK/source" commit -qm initial || exit 1
git -C "$WORK/source" tag -a v1.0.0 -m release || exit 1
git clone -q --no-local "$WORK/source" "$WORK/private-host" || exit 1
printf 'host private edit\n' >> "$WORK/private-host/tracked.txt"
printf 'private untracked\n' > "$WORK/private-host/private.txt"
HOST_SHA=$(git -C "$WORK/private-host" rev-parse HEAD)
HOST_INDEX=$(_git_ops_build_sha256 "$WORK/private-host/.git/index")
HOST_BYTES=$(_git_ops_build_sha256 "$WORK/private-host/tracked.txt")
printf 'next commit\n' >> "$WORK/source/tracked.txt"
git -C "$WORK/source" commit -qam next || exit 1
git -C "$WORK/source" tag Release || exit 1
git -C "$WORK/source" tag -a release -m 'case-distinct annotated tag' || exit 1
git -C "$WORK/source" worktree add -qb feature "$WORK/linked" || exit 1
git -C "$WORK/source" config credential.helper 'do-not-copy-this'
mkdir "$WORK/source/.git/hooks" || exit 1
printf 'private hook\n' > "$WORK/source/.git/hooks/private-hook"
SHA=$(git -C "$WORK/linked" rev-parse HEAD)
TAG=$(git -C "$WORK/linked" rev-parse refs/tags/v1.0.0)
CONFIG=$(_git_ops_build_sha256 "$WORK/source/.git/config")
INDEX=$(git -C "$WORK/linked" rev-parse --git-path index)
CLEAN_INDEX=$(_git_ops_build_sha256 "$INDEX")
CLEAN_DESCRIBE=$(git -C "$WORK/linked" describe --tags --always --dirty)
STATUS=0
CONTEXT=$(git_ops_export_build_context "$WORK/linked" "$WORK/context") || STATUS=$?
check 'linked worktree exports a standalone context' equal "$STATUS" 0
if ((STATUS != 0)); then exit 1; fi
check 'export preserves the original clean index' equal "$(_git_ops_build_sha256 "$INDEX")" "$CLEAN_INDEX"
check 'receipt records raw annotated tag object and symbolic branch' jq -e --arg tag "$TAG" --arg sha "$SHA" \
  '.git_sha == $sha and .git_ref == "refs/heads/feature" and .tags["refs/tags/v1.0.0"] == $tag' <<< "$CONTEXT"
check 'unchanged controller identity verifies without another export' git_ops_verify_build_context "$WORK/linked" "$CONTEXT"
check 'unset line-ending configuration records explicit defaults' jq -e \
  '.core_autocrlf == "false" and .core_eol == "native"' <<< "$CONTEXT"
STATUS=0
git_ops_verify_build_context "$WORK/linked" "{} $CONTEXT" > "$WORK/multiple-verify.out" 2> "$WORK/multiple-verify.log" || STATUS=$?
check 'verification requires exactly one JSON context object' equal "$STATUS" 4
copy_source "$WORK/linked" "$WORK/clean" || exit 1
restore clean "$CONTEXT"
check 'fresh clean source imports real Git history' equal "$STATUS" 0
check 'restored symbolic branch is the controller branch' equal "$(git -C "$WORK/clean" symbolic-ref HEAD)" refs/heads/feature
check 'restored clean describe has no false dirty suffix' equal \
  "$(git -C "$WORK/clean" describe --tags --always --dirty)" "$(git -C "$WORK/linked" describe --tags --always --dirty)"
check 'restored context contains independent Git objects' git -C "$WORK/clean" fsck --full
check 'controller credentials are not copied' equal "$(git -C "$WORK/clean" config --get credential.helper || true)" ''
check 'controller hooks are not copied' test ! -e "$WORK/clean/.git/hooks/private-hook"
check 'restored Git metadata is a directory rather than a linked-worktree pointer' test -d "$WORK/clean/.git"

printf 'staged edit\n' >> "$WORK/linked/staged.txt"
git -C "$WORK/linked" add staged.txt || exit 1
printf 'unstaged edit\n' >> "$WORK/linked/tracked.txt"
printf 'untracked bytes\n' > "$WORK/linked/untracked.txt"
DIRTY_INDEX=$(_git_ops_build_sha256 "$INDEX")
DIRTY_STATUS=$(git -C "$WORK/linked" status --porcelain=v1)
DIRTY_DESCRIBE=$(git -C "$WORK/linked" describe --tags --always --dirty)
DIRTY_CONTEXT=$(git_ops_export_build_context "$WORK/linked" "$WORK/dirty-context") || exit 1
copy_source "$WORK/linked" "$WORK/dirty" || exit 1
restore dirty "$DIRTY_CONTEXT"
check 'dirty source imports without checkout or reset' equal "$STATUS" 0
for name in tracked.txt staged.txt untracked.txt; do
  check "dirty source preserves $name bytes" cmp "$WORK/linked/$name" "$WORK/dirty/$name"
done
check 'dirty stage describes the controller commit and tag ancestry' equal \
  "$(git -C "$WORK/dirty" describe --tags --always --dirty)" "$DIRTY_DESCRIBE"
check 'export and restore leave the original staging index unchanged' equal "$(_git_ops_build_sha256 "$INDEX")" "$DIRTY_INDEX"
check 'original staged/unstaged state remains unchanged' equal "$(git -C "$WORK/linked" status --porcelain=v1)" "$DIRTY_STATUS"
check 'controller Git configuration remains unchanged' equal "$(_git_ops_build_sha256 "$WORK/source/.git/config")" "$CONFIG"
check 'unrelated host checkout HEAD is untouched' equal "$(git -C "$WORK/private-host" rev-parse HEAD)" "$HOST_SHA"
check 'unrelated host index is untouched' equal "$(_git_ops_build_sha256 "$WORK/private-host/.git/index")" "$HOST_INDEX"
check 'unrelated host dirty bytes are untouched' equal "$(_git_ops_build_sha256 "$WORK/private-host/tracked.txt")" "$HOST_BYTES"
restore private-host "$DIRTY_CONTEXT"
check 'an existing checkout cannot receive replacement Git metadata' equal "$STATUS" 4
check 'refused checkout still keeps its old HEAD' equal "$(git -C "$WORK/private-host" rev-parse HEAD)" "$HOST_SHA"

git -C "$WORK/source" worktree add -q --detach "$WORK/detached" "$SHA" || exit 1
DETACHED=$(git_ops_export_build_context "$WORK/detached" "$WORK/detached-context") || exit 1
copy_source "$WORK/detached" "$WORK/detached-stage" || exit 1
restore detached-stage "$DETACHED"
check 'detached source restores successfully' equal "$STATUS" 0
check 'detached HEAD remains detached' equal "$(git -C "$WORK/detached-stage" symbolic-ref -q HEAD || true)" ''
check 'detached restore retains the exact commit' equal "$(git -C "$WORK/detached-stage" rev-parse HEAD)" "$SHA"

refused malformed '{"git_sha":"bad"}'
refused invalid-normalization "$(jq -c '.core_autocrlf="external-filter"' <<< "$CONTEXT")"
refused multiple-documents "$CONTEXT $CONTEXT"
refused wrong-head "$(jq -c '.git_sha=("a"*40)' <<< "$CONTEXT")"
refused missing-tags "$(jq -c '.tags={}' <<< "$CONTEXT")"
refused invalid-branch "$(jq -c '.git_ref="refs/heads/a..b"' <<< "$CONTEXT")"
printf 'corrupted bundle\n' > "$WORK/corrupt.bundle"
refused corrupt "$(jq -c --arg path "$WORK/corrupt.bundle" '.bundle_path=$path' <<< "$CONTEXT")"
mkdir "$WORK/git-file" || exit 1
printf 'gitdir: private-pointer\n' > "$WORK/git-file/.git"
restore git-file "$CONTEXT"
check 'linked-worktree pointer destination is never overwritten' equal "$STATUS" 4
check 'preexisting Git pointer retains its bytes' equal "$(cat "$WORK/git-file/.git")" 'gitdir: private-pointer'
mkdir "$WORK/linked/nested" || exit 1
STATUS=0
git_ops_export_build_context "$WORK/linked/nested" "$WORK/nested-context" > "$WORK/nested.receipt.json" 2> "$WORK/nested.log" || STATUS=$?
check 'subdirectory source is refused as an unsupported repository root' equal "$STATUS" 4
check 'subdirectory refusal creates no export' test ! -e "$WORK/nested-context"
git clone -q --depth 1 "file://$WORK/source" "$WORK/shallow" || exit 1
STATUS=0
git_ops_export_build_context "$WORK/shallow" "$WORK/shallow-context" > "$WORK/shallow.receipt.json" 2> "$WORK/shallow.log" || STATUS=$?
check 'shallow source is refused rather than exporting incomplete ancestry' equal "$STATUS" 4
check 'shallow refusal explains the required full checkout' grep -Fq 'complete checkout' "$WORK/shallow.log"
mkdir "$WORK/unborn" || exit 1
git init -qb main "$WORK/unborn" || exit 1
refuse_export unborn "$WORK/unborn" 'no committed HEAD'
git clone -q "$WORK/source" "$WORK/flagged" || exit 1
git -C "$WORK/flagged" update-index --assume-unchanged tracked.txt || exit 1
printf 'hidden modification\n' >> "$WORK/flagged/tracked.txt"
refuse_export assumed "$WORK/flagged" 'assume-unchanged'
git -C "$WORK/flagged" update-index --no-assume-unchanged tracked.txt || exit 1
git -C "$WORK/flagged" update-index --skip-worktree tracked.txt || exit 1
refuse_export skipped "$WORK/flagged" 'skip-worktree'
git -C "$WORK/flagged" update-index --no-skip-worktree tracked.txt || exit 1
git -C "$WORK/flagged" sparse-checkout init --cone || exit 1
refuse_export sparse "$WORK/flagged" 'Sparse checkout'
git -C "$WORK/linked" tag later-tag || exit 1
STATUS=0
git_ops_verify_build_context "$WORK/linked" "$CONTEXT" || STATUS=$?
check 'controller tag movement after export refuses transfer admission' equal "$STATUS" 4

if command -v pwsh >/dev/null 2>&1; then
  printf 'BOUNDARY: generated PowerShell importer runs on this host; no Windows filesystem claim\n'
  copy_source "$WORK/detached" "$WORK/ps-stage" || exit 1
  git_ops_build_context_powershell "$WORK/ps-stage" "$DETACHED" > "$WORK/import.ps1" || exit 1
  STATUS=0
  pwsh -NoLogo -NoProfile -NonInteractive -File "$WORK/import.ps1" > "$WORK/ps.receipt.json" 2> "$WORK/ps.log" || STATUS=$?
  check 'generated PowerShell importer succeeds with genuine Git' equal "$STATUS" 0
  if ((STATUS != 0)); then cat "$WORK/ps.log" >&2; fi
  check 'PowerShell restored HEAD matches the exported source' equal "$(git -C "$WORK/ps-stage" rev-parse HEAD 2>/dev/null)" "$SHA"
  check 'PowerShell retains case-distinct raw tag identities on this filesystem' jq -e \
    --argjson actual "$(_git_ops_build_refs "$WORK/ps-stage")" \
    '.tags == $actual and .tags["refs/tags/Release"] != .tags["refs/tags/release"]' <<< "$DETACHED"
  check 'PowerShell restored tag ancestry preserves clean describe' equal \
    "$(git -C "$WORK/ps-stage" describe --tags --always --dirty 2>/dev/null)" "$CLEAN_DESCRIBE"
  copy_source "$WORK/dirty" "$WORK/ps-dirty" || exit 1
  git_ops_build_context_powershell "$WORK/ps-dirty" "$DIRTY_CONTEXT" > "$WORK/import-dirty.ps1" || exit 1
  STATUS=0
  pwsh -NoLogo -NoProfile -NonInteractive -File "$WORK/import-dirty.ps1" > "$WORK/ps-dirty.receipt.json" 2> "$WORK/ps-dirty.log" || STATUS=$?
  check 'PowerShell imports a symbolic branch with dirty source bytes' equal "$STATUS" 0
  if ((STATUS != 0)); then cat "$WORK/ps-dirty.log" >&2; fi
  check 'PowerShell preserves symbolic HEAD' equal "$(git -C "$WORK/ps-dirty" symbolic-ref HEAD 2>/dev/null)" refs/heads/feature
  check 'PowerShell preserves the correct dirty version stamp' equal \
    "$(git -C "$WORK/ps-dirty" describe --tags --always --dirty 2>/dev/null)" "$DIRTY_DESCRIBE"
  check 'PowerShell preserves staged source bytes' cmp "$WORK/dirty/staged.txt" "$WORK/ps-dirty/staged.txt"
  mkdir "$WORK/ps-corrupt" || exit 1
  git_ops_build_context_powershell "$WORK/ps-corrupt" \
    "$(jq -c --arg path "$WORK/corrupt.bundle" '.bundle_path=$path' <<< "$CONTEXT")" > "$WORK/import-corrupt.ps1" || exit 1
  STATUS=0
  pwsh -NoLogo -NoProfile -NonInteractive -File "$WORK/import-corrupt.ps1" > "$WORK/ps-corrupt.receipt.json" 2> "$WORK/ps-corrupt.log" || STATUS=$?
  check 'PowerShell refuses corrupt transport before initializing Git' equal "$STATUS" 4
  check 'PowerShell corruption refusal leaves no Git metadata' test ! -e "$WORK/ps-corrupt/.git"
else
  printf 'SKIP: generated PowerShell importer requires pwsh\n'
fi
git clone -q --no-tags "$WORK/source" "$WORK/untagged" || exit 1
UNTAGGED=$(git_ops_export_build_context "$WORK/untagged" "$WORK/untagged-context") || exit 1
copy_source "$WORK/untagged" "$WORK/untagged-stage" || exit 1
restore untagged-stage "$UNTAGGED"
check 'repository with no tags restores its exact HEAD' equal "$STATUS" 0
check 'untagged context retains an empty tag inventory' jq -e '.tags == {}' <<< "$UNTAGGED"
git -C "$WORK/untagged" branch moved "$SHA" || exit 1
git -C "$WORK/untagged" symbolic-ref HEAD refs/heads/moved || exit 1
STATUS=0
git_ops_verify_build_context "$WORK/untagged" "$UNTAGGED" > "$WORK/branch-verify.out" 2> "$WORK/branch-verify.log" || STATUS=$?
check 'controller branch movement refuses transfer admission even at the same commit' equal "$STATUS" 4
MOVED=$(git_ops_export_build_context "$WORK/untagged" "$WORK/moved-context") || exit 1
git -C "$WORK/untagged" update-ref refs/heads/moved "$HOST_SHA" || exit 1
STATUS=0
git_ops_verify_build_context "$WORK/untagged" "$MOVED" > "$WORK/head-verify.out" 2> "$WORK/head-verify.log" || STATUS=$?
check 'controller HEAD movement refuses transfer admission' equal "$STATUS" 4

# Inject a real ref change immediately after Git writes the bundle. Every Git
# command still executes; this makes the otherwise racy transfer window exact.
STATUS=0
(
  git() {
    command git "$@" || return $?
    if [[ " $* " == *' bundle create '* ]]; then
      command git -C "$WORK/linked" tag during-export "$SHA" || return $?
    fi
  }
  git_ops_export_build_context "$WORK/linked" "$WORK/moving-context"
) > "$WORK/moving.receipt.json" 2> "$WORK/moving.log" || STATUS=$?
check 'tag movement during export refuses admission' equal "$STATUS" 4
check 'moving export emits no successful context receipt' test ! -s "$WORK/moving.receipt.json"

# Git's ordinary CRLF normalization must survive staging without copying the
# source config. Read an actual global setting, then exercise a local override.
git init -q --template="$WORK/template" -b main "$WORK/crlf-source" || exit 1
git -C "$WORK/crlf-source" config user.name 'DSR line-ending fixture'
git -C "$WORK/crlf-source" config user.email test@example.invalid
printf 'first line\r\nsecond line\r\n' > "$WORK/crlf-source/lines.txt"
git -C "$WORK/crlf-source" -c core.autocrlf=true add lines.txt || exit 1
git -C "$WORK/crlf-source" -c core.autocrlf=true commit -qm normalized || exit 1
git -C "$WORK/crlf-source" tag -a v2.0.0 -m normalized || exit 1
git config --file "$WORK/line-global" core.autocrlf true || exit 1
git config --file "$WORK/line-global" core.eol crlf || exit 1
CRLF_DESCRIBE=$(GIT_CONFIG_GLOBAL="$WORK/line-global" git -C "$WORK/crlf-source" describe --tags --always --dirty)
CRLF_INDEX=$(_git_ops_build_sha256 "$WORK/crlf-source/.git/index")
CRLF=$(GIT_CONFIG_GLOBAL="$WORK/line-global" GIT_DIR="$WORK/private-host/.git" \
  git_ops_export_build_context "$WORK/crlf-source" "$WORK/crlf-context") || exit 1
check 'export reads real global normalization despite an inherited Git-directory redirect' jq -e \
  '.core_autocrlf == "true" and .core_eol == "crlf"' <<< "$CRLF"
copy_source "$WORK/crlf-source" "$WORK/crlf-stage" || exit 1
restore crlf-stage "$CRLF"
check 'CRLF source restores successfully' equal "$STATUS" 0
check 'global CRLF policy produces the same clean version stamp after staging' equal \
  "$(git -C "$WORK/crlf-stage" describe --tags --always --dirty)" "$CRLF_DESCRIBE"
check 'CRLF bytes are never rewritten during restore' cmp "$WORK/crlf-source/lines.txt" "$WORK/crlf-stage/lines.txt"
check 'CRLF export leaves the original index unchanged' equal \
  "$(_git_ops_build_sha256 "$WORK/crlf-source/.git/index")" "$CRLF_INDEX"
git -C "$WORK/crlf-source" config core.autocrlf input || exit 1
git -C "$WORK/crlf-source" config core.eol lf || exit 1
STATUS=0
GIT_CONFIG_GLOBAL="$WORK/line-global" git_ops_verify_build_context "$WORK/crlf-source" "$CRLF" \
  > "$WORK/normalization-verify.out" 2> "$WORK/normalization-verify.log" || STATUS=$?
check 'normalization changes after export refuse transfer admission' equal "$STATUS" 4
INPUT=$(GIT_CONFIG_GLOBAL="$WORK/line-global" \
  git_ops_export_build_context "$WORK/crlf-source" "$WORK/input-context") || exit 1
check 'local input/lf scalars override real global true/crlf settings' jq -e \
  '.core_autocrlf == "input" and .core_eol == "lf"' <<< "$INPUT"
copy_source "$WORK/crlf-source" "$WORK/input-stage" || exit 1
restore input-stage "$INPUT"
check 'input normalization restores successfully' equal "$STATUS" 0
check 'input policy keeps the staged CRLF source clean' equal \
  "$(git -C "$WORK/input-stage" describe --tags --always --dirty)" "$CRLF_DESCRIBE"
check 'input policy preserves the original CRLF bytes' cmp "$WORK/crlf-source/lines.txt" "$WORK/input-stage/lines.txt"
if command -v pwsh >/dev/null 2>&1; then
  copy_source "$WORK/crlf-source" "$WORK/ps-crlf" || exit 1
  git_ops_build_context_powershell "$WORK/ps-crlf" "$CRLF" > "$WORK/import-crlf.ps1" || exit 1
  STATUS=0
  pwsh -NoLogo -NoProfile -NonInteractive -File "$WORK/import-crlf.ps1" > "$WORK/ps-crlf.receipt.json" 2> "$WORK/ps-crlf.log" || STATUS=$?
  check 'PowerShell importer restores the captured CRLF scalars' equal "$STATUS" 0
  check 'PowerShell CRLF staging retains the clean version stamp' equal \
    "$(git -C "$WORK/ps-crlf" describe --tags --always --dirty 2>/dev/null)" "$CRLF_DESCRIBE"
  check 'PowerShell CRLF staging preserves source bytes' cmp "$WORK/crlf-source/lines.txt" "$WORK/ps-crlf/lines.txt"
fi
printf '%s passed, %s failed\n' "$PASS" "$FAIL"
((FAIL == 0))
