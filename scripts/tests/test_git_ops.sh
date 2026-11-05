#!/usr/bin/env bash
# test_git_ops.sh - Tests for git_ops.sh module
#
# Tests git plumbing operations for reproducible builds.
# Uses a temporary git repository for isolated testing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$SCRIPT_DIR/../../src" && pwd)"

# Source the module under test
# shellcheck source=../../src/logging.sh
source "$SRC_DIR/logging.sh"
# shellcheck source=../../src/git_ops.sh
source "$SRC_DIR/git_ops.sh"

# Actual Git object transfer and private working trees; no network, compiler,
# source deletion, or mutable checkout bytes stand in for the selected pins.
test_materialized_submodules() {
  python3 - "$SRC_DIR" "${DSR_TEST_GIT_OPS_MODULE:-$SRC_DIR/git_ops.sh}" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

modules, module = map(Path, sys.argv[1:])
work = Path(tempfile.mkdtemp(prefix='dsr-isolated-submodules-'))
print('Retained isolated submodule evidence: ' + str(work), flush=True)
checks = failures = 0

def check(label, valid):
    global checks, failures
    checks += 1
    failures += not valid
    print(('PASS: ' if valid else 'FAIL: ') + label, flush=True)

def git(root, *args):
    return subprocess.check_output(['git', '-c', 'user.name=DSR Fixture',
        '-c', 'user.email=fixture@example.invalid', '-c', 'commit.gpgsign=false',
        '-c', 'core.hooksPath=/dev/null', '-C', str(root), *args], stderr=subprocess.PIPE).decode().strip()

def repository(path, text):
    path.mkdir(parents=True)
    git(path, 'init', '-q', '-b', 'main')
    (path / 'source.txt').write_text(text + '\n')
    (path / '.gitignore').write_text('target/\n')
    git(path, 'add', '.')
    git(path, 'commit', '-qm', 'initial')
    return git(path, 'rev-parse', 'HEAD')

def link(parent, name, pin):
    with (parent / '.gitmodules').open('a') as stream:
        stream.write('[submodule "' + name + '"]\n\tpath = ' + name +
                     '\n\turl = https://must-not-fetch.invalid/' + name + '.git\n')
    git(parent, 'add', '.gitmodules')
    git(parent, 'update-index', '--add', '--cacheinfo', '160000,' + pin + ',' + name)
    git(parent, 'commit', '-qm', 'pin child')
    return git(parent, 'rev-parse', 'HEAD')

def fixture(label, absorbed=False):
    root = work / label / 'developer'
    repository(root, 'root release')
    child = root / 'vendor/library'
    repository(child, 'library release')
    leaf = child / 'nested/leaf'
    leaf_sha = repository(leaf, 'leaf release')
    child_sha = link(child, 'nested/leaf', leaf_sha)
    sha = link(root, 'vendor/library', child_sha)
    git(root, 'tag', '-a', 'v1.2.3', '-m', 'release')
    if absorbed:
        git(root, 'submodule', 'absorbgitdirs')
    return root, sha, child, child_sha, leaf, leaf_sha

def capture(root):
    result = {}
    for path in sorted(root.rglob('*')):
        if path.is_symlink():
            result[str(path.relative_to(root))] = ('link', os.readlink(path))
        elif path.is_file():
            info = path.stat()
            result[str(path.relative_to(root))] = (info.st_mode, info.st_size,
                hashlib.sha256(path.read_bytes()).hexdigest())
    return result

def call(root, label, *args):
    result = subprocess.run(['bash', '-c', 'source "$1/logging.sh"; source "$2"; shift 2; "$@"',
        '_', str(modules), str(module), *map(str, args)], text=True, capture_output=True, timeout=30)
    (root.parent / (label + '.stdout')).write_text(result.stdout)
    (root.parent / (label + '.stderr')).write_text(result.stderr)
    (root.parent / (label + '.exit')).write_text(str(result.returncode) + '\n')
    return result

def transport(root, private, sha, child_sha, leaf_sha, materialized):
    config = root.parent / 'config'
    (config / 'repos.d').mkdir(parents=True)
    stages = root.parent / 'stages'
    stages.mkdir()
    (config / 'hosts.yaml').write_text(json.dumps({'hosts': {'fixture': {
        'platform': 'linux/amd64', 'connection': 'local', 'enabled': True,
        'build_root': str(stages), 'capabilities': []}}}))
    (config / 'repos.d/tool.yaml').write_text(json.dumps(dict(repo='owner/tool',
        local_path=str(root), language='go', binary_name='tool', targets=['linux/amd64'],
        hosts={'linux/amd64': 'fixture'}, act_job_map={'linux/amd64': None})))
    identity = dict(git_sha=sha, submodules=materialized['submodules'], dependencies=[])
    env = dict(os.environ, ACT_CONFIG_DIR=str(config), DSR_CONFIG_DIR=str(config),
        ACT_REPOS_DIR=str(config / 'repos.d'), DSR_HOSTS_FILE=str(config / 'hosts.yaml'),
        DSR_STATE_DIR=str(root.parent / 'state'), DSR_DISABLE_HOST_SELECTOR='1',
        _ACT_ISOLATED_SOURCE_TOOL='tool', _ACT_ISOLATED_SOURCE_PATHS=json.dumps({str(root): str(private)}),
        _ACT_ISOLATED_SOURCE_IDENTITY=json.dumps(identity))
    program = '''source "$1/logging.sh"; source "$1/config.sh"; source "$1/act_runner.sh"; source "$2"
shift 2
# Machine capacity is a controlled boundary; source selection, rsync, Git
# context import, and final source-sync receipt admission are production code.
host_health_is_ready() { return 0; }
_act_native_writable_paths_ready() { return 0; }
"$@"
'''
    def run(label, *args):
        result = subprocess.run(['bash', '-c', program, '_', str(modules), str(module), *args],
            env=env, text=True, capture_output=True, timeout=45)
        (root.parent / (label + '.stdout')).write_text(result.stdout)
        (root.parent / (label + '.stderr')).write_text(result.stderr)
        return result
    result = run('ordinary-sync', 'act_sync_sources', 'tool', '--stage-ordinary')
    check('ordinary staging transports real nested child repositories', result.returncode == 0)
    if result.returncode:
        return
    receipt = json.loads(result.stdout)
    stage = Path(receipt['source_roots']['fixture'])
    expected = {'source/vendor/library': child_sha, 'source/vendor/library/nested/leaf': leaf_sha}
    check('source-sync receipt binds each child context separately from sibling dependencies',
          receipt.get('sibling_git_contexts') == {} and
          {name: context['git_sha'] for name, context in receipt.get('submodule_git_contexts', {}).items()} == expected)
    check('native synchronization retains the original path-independent graph for every target receipt',
          receipt.get('source_materialization') == identity and
          receipt['hosts'][0].get('source_materialization') == identity)
    check('native staged root and children retain exact pinned Git identities and clean source bytes',
          git(stage, 'rev-parse', 'HEAD') == sha and not git(stage, 'status', '--porcelain') and
          git(stage / 'vendor/library', 'rev-parse', 'HEAD') == child_sha and
          git(stage / 'vendor/library/nested/leaf', 'rev-parse', 'HEAD') == leaf_sha and
          (stage / 'vendor/library/nested/leaf/source.txt').read_text() == 'leaf release\n')
    tasks = json.dumps([dict(platform='linux/amd64', method='native')])
    result = run('admit-sync', '_act_validate_source_sync_receipt', json.dumps(receipt), tasks)
    check('actual native admission accepts the complete recursive transport receipt', result.returncode == 0)
    for mode in ('changed-pin', 'missing-child', 'escaped-child', 'wrong-root', 'changed-identity', 'missing-identity'):
        damaged = json.loads(json.dumps(receipt))
        if mode == 'changed-pin':
            damaged['hosts'][0]['submodule_git_contexts']['source/vendor/library']['git_sha'] = 'f' * 40
        elif mode == 'missing-child':
            damaged['hosts'][0]['submodule_git_contexts'].pop('source/vendor/library')
        elif mode == 'wrong-root':
            damaged['hosts'][0]['submodule_git_contexts']['source/vendor/library']['source_root'] = str(stage.parent / 'other')
        elif mode == 'changed-identity':
            for document in (damaged, damaged['hosts'][0]):
                document['source_materialization']['submodules'][0]['git_sha'] = 'f' * 40
        elif mode == 'missing-identity':
            damaged['hosts'][0].pop('source_materialization')
        else:
            for document in (damaged, damaged['hosts'][0]):
                document['submodule_git_contexts']['source/../outside'] = document['submodule_git_contexts'].pop('source/vendor/library')
        check(mode + ': actual native admission refuses altered child context evidence',
              run('admit-' + mode, '_act_validate_source_sync_receipt', json.dumps(damaged), tasks).returncode != 0)

for layout in ('self-contained', 'absorbed'):
    root, sha, child, child_sha, leaf, leaf_sha = fixture(layout, layout == 'absorbed')
    for source in (root, child, leaf):
        (source / 'source.txt').write_text('later committed work\n')
        git(source, 'add', 'source.txt')
        git(source, 'commit', '-qm', 'later work')
        (source / 'source.txt').write_text('staged developer work\n')
        git(source, 'add', 'source.txt')
        (source / 'source.txt').write_text('unstaged developer work\n')
        (source / 'private.txt').write_text('untracked developer work\n')
        git(source, 'config', 'credential.helper', '!must-not-copy-credentials')
    before = capture(root)
    private = root.parent / 'private'
    result = call(root, 'materialize', 'git_ops_materialize_source', root, sha, private, 'v1.2.3', 'owner/tool')
    check(layout + ': pinned root and nested children materialize from Git objects', result.returncode == 0)
    check(layout + ': every original object, ref, index, configuration and working byte remains unchanged', capture(root) == before)
    if result.returncode != 0:
        continue
    receipt = json.loads(result.stdout)
    check(layout + ': receipt records both parent-selected child commits',
          {(row['path'], row['git_sha']) for row in receipt.get('submodules', [])} ==
          {('vendor/library', child_sha), ('vendor/library/nested/leaf', leaf_sha)})
    for relative, pin, content in (('', sha, 'root release\n'), ('vendor/library', child_sha, 'library release\n'),
                                   ('vendor/library/nested/leaf', leaf_sha, 'leaf release\n')):
        selected = private / relative
        check(layout + ': independent pinned checkout ' + (relative or 'root'),
              (selected / '.git').is_dir() and not (selected / '.git').is_symlink()
              and git(selected, 'rev-parse', 'HEAD') == pin
              and (selected / 'source.txt').read_text() == content
              and not (selected / 'private.txt').exists()
              and 'must-not-copy-credentials' not in (selected / '.git/config').read_text())
    for name, selected, pin in (('plain', private / 'vendor/library/nested/leaf', leaf_sha),
                                ('recursive', private, sha)):
        check(layout + ': exported verification works in a fresh Bash child for ' + name + ' source',
              call(root, 'verify-exported-' + name, 'bash', '-c',
                   'set -uo pipefail; git_ops_verify_materialized_source "$@"',
                   '_', selected, pin).returncode == 0)
    if layout == 'absorbed':
        transport(root, private, sha, child_sha, leaf_sha, receipt)
    root.rename(root.parent / 'developer-unavailable')
    check(layout + ': recursive verification remains usable without the developer checkout',
          call(root, 'verify-independent', 'git_ops_verify_materialized_source', private, sha, 'v1.2.3').returncode == 0)
    original = private / 'vendor/library/nested/leaf/source.txt'
    info = original.stat()
    original.write_text('evil release\n')
    os.utime(original, ns=(info.st_atime_ns, info.st_mtime_ns))
    git(private, 'config', 'submodule.vendor/library.ignore', 'all')
    git(private / 'vendor/library', 'config', 'submodule.nested/leaf.ignore', 'all')
    git(private / 'vendor/library/nested/leaf', 'update-index', '--assume-unchanged', 'source.txt')
    check(layout + ': recursive boundary refuses hidden child byte drift despite ignored parent status',
          call(root, 'verify-tampered', 'git_ops_verify_materialized_source', private, sha, 'v1.2.3').returncode == 4)

for mode in ('missing-child', 'external-admin', 'alternates', 'linked-objects', 'wrong-object-type'):
    root, sha, child, child_sha, leaf, leaf_sha = fixture(mode)
    if mode == 'missing-child':
        leaf.rename(root.parent / 'missing-leaf')
    elif mode == 'external-admin':
        outside = root.parent / 'outside.git'
        (leaf / '.git').rename(outside)
        (leaf / '.git').write_text('gitdir: ' + str(outside) + '\n')
    elif mode == 'alternates':
        (leaf / '.git/objects/info/alternates').write_text(str(child / '.git/objects') + '\n')
    elif mode == 'linked-objects':
        outside = root.parent / 'objects'
        (leaf / '.git/objects').rename(outside)
        (leaf / '.git/objects').symlink_to(outside, target_is_directory=True)
    else:
        oid = git(child, 'rev-parse', 'HEAD:source.txt')
        git(root, 'update-index', '--cacheinfo', '160000,' + oid + ',vendor/library')
        git(root, 'commit', '-qm', 'invalid child type')
        sha = git(root, 'rev-parse', 'HEAD')
    before = capture(root)
    result = call(root, mode, 'git_ops_materialize_source', root, sha, root.parent / 'private')
    check(mode + ': refuses unusable child custody without changing the source',
          result.returncode == 4 and capture(root) == before)

root, sha, child, child_sha, leaf, leaf_sha = fixture('child-identity')
private = root.parent / 'private'
result = call(root, 'materialize', 'git_ops_materialize_source', root, sha, private)
if result.returncode == 0:
    selected = private / 'vendor/library/nested/leaf'
    git(selected, 'commit', '--allow-empty', '-qm', 'same bytes but another commit')
    git(private, 'config', 'submodule.vendor/library.ignore', 'all')
    git(private / 'vendor/library', 'config', 'submodule.nested/leaf.ignore', 'all')
    check('child HEAD cannot change even when its tree and visible parent status are unchanged',
          call(root, 'verify-head', 'git_ops_verify_materialized_source', private, sha).returncode == 4)
else:
    check('child identity fixture materializes', False)

print('Isolated submodules: checks=%d failures=%d' % (checks, failures), flush=True)
sys.exit(bool(failures))
PY
}

if [[ "${1:-}" == --materialized-source-tests ]]; then
  test_materialized_submodules
  exit $?
fi

# Test state
TEMP_DIR=""
TEST_REPO=""
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Initialize logging silently
log_init 2>/dev/null || true

# ============================================================================
# Test Infrastructure
# ============================================================================

setup() {
  TEMP_DIR=$(mktemp -d)
  TEST_REPO="$TEMP_DIR/test-repo"

  # Create a test repository
  mkdir -p "$TEST_REPO"
  git -C "$TEST_REPO" init --quiet --initial-branch=main
  git -C "$TEST_REPO" config user.email "test@example.com"
  git -C "$TEST_REPO" config user.name "Test User"

  # Create initial commit
  echo "initial content" > "$TEST_REPO/file.txt"
  git -C "$TEST_REPO" add file.txt
  git -C "$TEST_REPO" commit --quiet -m "Initial commit"

  # Create a tag
  git -C "$TEST_REPO" tag v1.0.0

  # Create another commit and tag
  echo "version 1.1" >> "$TEST_REPO/file.txt"
  git -C "$TEST_REPO" add file.txt
  git -C "$TEST_REPO" commit --quiet -m "Version 1.1"
  git -C "$TEST_REPO" tag -a v1.1.0 -m "Release v1.1.0"

  # Create a branch
  git -C "$TEST_REPO" checkout -b feature-branch --quiet
  echo "feature work" >> "$TEST_REPO/file.txt"
  git -C "$TEST_REPO" add file.txt
  git -C "$TEST_REPO" commit --quiet -m "Feature work"

  # Return to main branch
  git -C "$TEST_REPO" checkout main --quiet
}

teardown() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    rm -rf "$TEMP_DIR"
  fi
}

assert_equals() {
  local expected="$1"
  local actual="$2"
  local msg="${3:-assertion failed}"

  if [[ "$expected" != "$actual" ]]; then
    echo "  FAIL: $msg"
    echo "    Expected: $expected"
    echo "    Actual:   $actual"
    return 1
  fi
  return 0
}

assert_true() {
  local condition="$1"
  local msg="${2:-expected true}"

  if ! eval "$condition"; then
    echo "  FAIL: $msg"
    return 1
  fi
  return 0
}

assert_false() {
  local condition="$1"
  local msg="${2:-expected false}"

  if eval "$condition"; then
    echo "  FAIL: $msg"
    return 1
  fi
  return 0
}

run_test() {
  local test_name="$1"
  local test_func="$2"

  ((TESTS_RUN++))
  echo -n "  $test_name... "

  if $test_func 2>/dev/null; then
    echo "OK"
    ((TESTS_PASSED++))
  else
    echo "FAILED"
    ((TESTS_FAILED++))
  fi
}

# ============================================================================
# Tests: Ref Resolution
# ============================================================================

test_resolve_tag() {
  local sha
  sha=$(git_ops_resolve_ref "$TEST_REPO" "v1.0.0")
  [[ -n "$sha" ]] && [[ ${#sha} -eq 40 ]]
}

test_resolve_annotated_tag() {
  local sha
  sha=$(git_ops_resolve_ref "$TEST_REPO" "v1.1.0")
  [[ -n "$sha" ]] && [[ ${#sha} -eq 40 ]]
}

test_resolve_branch() {
  local sha
  sha=$(git_ops_resolve_ref "$TEST_REPO" "feature-branch")
  [[ -n "$sha" ]] && [[ ${#sha} -eq 40 ]]
}

test_resolve_sha() {
  local head_sha short_sha resolved
  head_sha=$(git -C "$TEST_REPO" rev-parse HEAD)
  short_sha="${head_sha:0:12}"
  resolved=$(git_ops_resolve_ref "$TEST_REPO" "$short_sha")
  [[ "$resolved" == "$head_sha" ]]
}

test_resolve_invalid_ref() {
  ! git_ops_resolve_ref "$TEST_REPO" "nonexistent-ref" 2>/dev/null
}

test_version_to_tag() {
  local tag
  tag=$(git_ops_version_to_tag "1.2.3")
  assert_equals "v1.2.3" "$tag" "Should add v prefix"

  tag=$(git_ops_version_to_tag "v1.2.3")
  assert_equals "v1.2.3" "$tag" "Should not double v prefix"
}

# ============================================================================
# Tests: Dirty Tree Detection
# ============================================================================

test_clean_repo_not_dirty() {
  ! git_ops_is_dirty "$TEST_REPO"
}

test_modified_file_is_dirty() {
  echo "modified" >> "$TEST_REPO/file.txt"
  git_ops_is_dirty "$TEST_REPO"
  local result=$?
  git -C "$TEST_REPO" checkout -- file.txt 2>/dev/null  # Cleanup
  [[ $result -eq 0 ]]
}

test_staged_file_is_dirty() {
  echo "new content" >> "$TEST_REPO/file.txt"
  git -C "$TEST_REPO" add file.txt
  git_ops_is_dirty "$TEST_REPO"
  local result=$?
  git -C "$TEST_REPO" reset HEAD -- file.txt 2>/dev/null
  git -C "$TEST_REPO" checkout -- file.txt 2>/dev/null
  [[ $result -eq 0 ]]
}

test_untracked_file_detection() {
  echo "untracked" > "$TEST_REPO/untracked.txt"
  git_ops_has_untracked "$TEST_REPO"
  local result=$?
  rm -f "$TEST_REPO/untracked.txt"
  [[ $result -eq 0 ]]
}

test_commit_tree_stat_identical_not_dirty() {
  local tree commit
  tree=$(git -C "$TEST_REPO" write-tree)
  commit=$(git -C "$TEST_REPO" commit-tree "$tree" -p HEAD -m "Commit tree test")
  git -C "$TEST_REPO" update-ref HEAD "$commit"
  sleep 1
  touch "$TEST_REPO/file.txt"
  ! git_ops_is_dirty "$TEST_REPO"
}

test_read_tree_content_identical_not_dirty() {
  git -C "$TEST_REPO" read-tree HEAD
  ! git_ops_is_dirty "$TEST_REPO"
}

test_dirty_status_clean() {
  local status
  status=$(git_ops_dirty_status "$TEST_REPO")
  assert_equals "clean" "$status"
}

test_dirty_status_modified() {
  echo "modified" >> "$TEST_REPO/file.txt"
  local status
  status=$(git_ops_dirty_status "$TEST_REPO")
  git -C "$TEST_REPO" checkout -- file.txt 2>/dev/null
  assert_equals "modified" "$status"
}

test_dirty_status_untracked() {
  echo "untracked" > "$TEST_REPO/new.txt"
  local status
  status=$(git_ops_dirty_status "$TEST_REPO")
  rm -f "$TEST_REPO/new.txt"
  assert_equals "untracked" "$status"
}

test_dirty_status_both() {
  echo "modified" >> "$TEST_REPO/file.txt"
  echo "untracked" > "$TEST_REPO/new.txt"
  local status
  status=$(git_ops_dirty_status "$TEST_REPO")
  git -C "$TEST_REPO" checkout -- file.txt 2>/dev/null
  rm -f "$TEST_REPO/new.txt"
  assert_equals "modified+untracked" "$status"
}

# ============================================================================
# Tests: Tag Operations
# ============================================================================

test_tag_exists() {
  git_ops_tag_exists "$TEST_REPO" "v1.0.0"
}

test_tag_not_exists() {
  ! git_ops_tag_exists "$TEST_REPO" "v9.9.9"
}

test_tag_sha() {
  local sha
  sha=$(git_ops_tag_sha "$TEST_REPO" "v1.0.0")
  [[ -n "$sha" ]] && [[ ${#sha} -eq 40 ]]
}

test_annotated_tag_sha() {
  local sha
  sha=$(git_ops_tag_sha "$TEST_REPO" "v1.1.0")
  [[ -n "$sha" ]] && [[ ${#sha} -eq 40 ]]
}

test_list_tags() {
  local tags
  tags=$(git_ops_list_tags "$TEST_REPO")
  [[ "$tags" == *"v1.0.0"* ]] && [[ "$tags" == *"v1.1.0"* ]]
}

test_list_tags_pattern() {
  local tags
  tags=$(git_ops_list_tags "$TEST_REPO" "v1.0*")
  [[ "$tags" == *"v1.0.0"* ]] && [[ "$tags" != *"v1.1.0"* ]]
}

# ============================================================================
# Tests: Branch Operations
# ============================================================================

test_current_branch() {
  local branch
  branch=$(git_ops_current_branch "$TEST_REPO")
  [[ "$branch" == "main" ]]
}

test_head_sha() {
  local sha
  sha=$(git_ops_head_sha "$TEST_REPO")
  [[ -n "$sha" ]] && [[ ${#sha} -eq 40 ]]
}

# ============================================================================
# Tests: Build Info
# ============================================================================

test_get_build_info_tag() {
  local info
  info=$(git_ops_get_build_info "$TEST_REPO" "v1.0.0")
  echo "$info" | jq -e '.git_sha' >/dev/null
  echo "$info" | jq -e '.ref_type == "tag"' >/dev/null
}

test_get_build_info_sha() {
  local head_sha info
  head_sha=$(git -C "$TEST_REPO" rev-parse HEAD)
  info=$(git_ops_get_build_info "$TEST_REPO" "$head_sha")
  echo "$info" | jq -e '.ref_type == "commit"' >/dev/null
}

test_get_build_info_dirty_fails() {
  echo "modified" >> "$TEST_REPO/file.txt"
  local result
  git_ops_get_build_info "$TEST_REPO" "v1.0.0" 2>/dev/null
  result=$?
  git -C "$TEST_REPO" checkout -- file.txt 2>/dev/null
  [[ $result -ne 0 ]]
}

test_get_build_info_allow_dirty() {
  echo "modified" >> "$TEST_REPO/file.txt"
  local info
  info=$(git_ops_get_build_info "$TEST_REPO" "v1.0.0" "--allow-dirty")
  local result=$?
  git -C "$TEST_REPO" checkout -- file.txt 2>/dev/null
  [[ $result -eq 0 ]] && echo "$info" | jq -e '.dirty_status == "modified"' >/dev/null
}

# ============================================================================
# Tests: Validation
# ============================================================================

test_validate_for_build_success() {
  git_ops_validate_for_build "$TEST_REPO" "v1.0.0" 2>/dev/null
}

test_validate_for_build_missing_tag() {
  ! git_ops_validate_for_build "$TEST_REPO" "v9.9.9" 2>/dev/null
}

test_validate_for_build_dirty() {
  echo "modified" >> "$TEST_REPO/file.txt"
  local result
  git_ops_validate_for_build "$TEST_REPO" "v1.0.0" 2>/dev/null
  result=$?
  git -C "$TEST_REPO" checkout -- file.txt 2>/dev/null
  [[ $result -ne 0 ]]
}

test_validate_for_build_allow_dirty() {
  echo "modified" >> "$TEST_REPO/file.txt"
  git_ops_validate_for_build "$TEST_REPO" "v1.0.0" "--allow-dirty" 2>/dev/null
  local result=$?
  git -C "$TEST_REPO" checkout -- file.txt 2>/dev/null
  [[ $result -eq 0 ]]
}

# ============================================================================
# Main Test Runner
# ============================================================================

main() {
  echo "=== git_ops.sh Tests ==="
  echo ""

  setup

  echo "Ref Resolution:"
  run_test "resolve_tag" test_resolve_tag
  run_test "resolve_annotated_tag" test_resolve_annotated_tag
  run_test "resolve_branch" test_resolve_branch
  run_test "resolve_sha" test_resolve_sha
  run_test "resolve_invalid_ref" test_resolve_invalid_ref
  run_test "version_to_tag" test_version_to_tag

  echo ""
  echo "Dirty Tree Detection:"
  run_test "clean_repo_not_dirty" test_clean_repo_not_dirty
  run_test "modified_file_is_dirty" test_modified_file_is_dirty
  run_test "staged_file_is_dirty" test_staged_file_is_dirty
  run_test "untracked_file_detection" test_untracked_file_detection
  run_test "commit_tree_stat_identical_not_dirty" test_commit_tree_stat_identical_not_dirty
  run_test "read_tree_content_identical_not_dirty" test_read_tree_content_identical_not_dirty
  run_test "dirty_status_clean" test_dirty_status_clean
  run_test "dirty_status_modified" test_dirty_status_modified
  run_test "dirty_status_untracked" test_dirty_status_untracked
  run_test "dirty_status_both" test_dirty_status_both

  echo ""
  echo "Tag Operations:"
  run_test "tag_exists" test_tag_exists
  run_test "tag_not_exists" test_tag_not_exists
  run_test "tag_sha" test_tag_sha
  run_test "annotated_tag_sha" test_annotated_tag_sha
  run_test "list_tags" test_list_tags
  run_test "list_tags_pattern" test_list_tags_pattern

  echo ""
  echo "Branch Operations:"
  run_test "current_branch" test_current_branch
  run_test "head_sha" test_head_sha

  echo ""
  echo "Build Info:"
  run_test "get_build_info_tag" test_get_build_info_tag
  run_test "get_build_info_sha" test_get_build_info_sha
  run_test "get_build_info_dirty_fails" test_get_build_info_dirty_fails
  run_test "get_build_info_allow_dirty" test_get_build_info_allow_dirty

  echo ""
  echo "Validation:"
  run_test "validate_for_build_success" test_validate_for_build_success
  run_test "validate_for_build_missing_tag" test_validate_for_build_missing_tag
  run_test "validate_for_build_dirty" test_validate_for_build_dirty
  run_test "validate_for_build_allow_dirty" test_validate_for_build_allow_dirty

  echo ""
  run_test "materialized_submodules" test_materialized_submodules

  teardown

  echo ""
  echo "=== Results ==="
  echo "Tests run:    $TESTS_RUN"
  echo "Tests passed: $TESTS_PASSED"
  echo "Tests failed: $TESTS_FAILED"

  if [[ $TESTS_FAILED -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

main "$@"
