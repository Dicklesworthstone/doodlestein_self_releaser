#!/usr/bin/env bash
# git_ops.sh - Git operations for reproducible builds
#
# Provides git plumbing operations for dsr builds without parsing git status.
# All operations use `git -C <repo>` to avoid global cd.
#
# Usage:
#   source git_ops.sh
#   git_ops_resolve_ref "/path/to/repo" "v1.2.3"    # Returns commit SHA
#   git_ops_is_dirty "/path/to/repo"                 # Returns 0 if dirty
#   git_ops_tag_exists "/path/to/repo" "v1.2.3"     # Returns 0 if tag exists
#   git_ops_get_build_info "/path/to/repo" "v1.2.3" # Returns JSON with git info
#
# Safety:
#   - Uses git plumbing commands (no status parsing)
#   - Build-context export never modifies the source repository
#   - Build-context restore only initializes a previously absent .git directory

set -uo pipefail

# =========================================================================
# Helpers
# =========================================================================

# Validate repo path is a git repository
# Args: repo_path
# Returns: 0 if repo ok, 1 otherwise
git_ops_is_repo() {
  local repo_path="$1"

  if [[ -z "$repo_path" ]]; then
    log_error "Repository path is empty"
    return 1
  fi

  if [[ ! -d "$repo_path" ]]; then
    log_error "Repository path does not exist: $repo_path"
    return 1
  fi

  if ! git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1; then
    log_error "Not a git repository: $repo_path"
    return 1
  fi

  return 0
}

# Validate target dir is absolute and not under /data/projects
# Args: target_dir
# Returns: 0 if safe, 1 otherwise
git_ops_validate_build_dir() {
  local target_dir="$1"

  if [[ -z "$target_dir" ]]; then
    log_error "Target directory is empty"
    return 1
  fi

  if [[ "$target_dir" != /* ]]; then
    log_error "Target directory must be absolute: $target_dir"
    return 1
  fi

  if [[ "$target_dir" == /data/projects || "$target_dir" == /data/projects/* ]]; then
    log_error "Refusing to use worktree under /data/projects: $target_dir"
    return 1
  fi

  return 0
}

# ============================================================================
# Ref Resolution
# ============================================================================

# Resolve a ref (tag, branch, SHA) to full commit SHA
# Args: repo_path ref
# Returns: 0 on success (SHA on stdout), 1 on failure
git_ops_resolve_ref() {
  local repo_path="$1"
  local ref="$2"

  if ! git_ops_is_repo "$repo_path"; then
    return 1
  fi

  if [[ -z "$ref" ]]; then
    log_error "Ref is empty"
    return 1
  fi

  # Use git rev-parse to resolve to full SHA
  local sha
  if sha=$(git -C "$repo_path" rev-parse --verify "${ref}^{commit}" 2>/dev/null); then
    echo "$sha"
    return 0
  fi

  # Try with refs/tags/ prefix for tags
  if sha=$(git -C "$repo_path" rev-parse --verify "refs/tags/${ref}^{commit}" 2>/dev/null); then
    echo "$sha"
    return 0
  fi

  log_error "Cannot resolve ref: $ref"
  return 1
}

# Resolve version to tag name (adds 'v' prefix if needed)
# Args: version
# Returns: tag name
git_ops_version_to_tag() {
  local version="$1"

  if [[ -z "$version" ]]; then
    log_error "Version is empty"
    return 1
  fi

  # If already has 'v' prefix, use as-is
  if [[ "$version" == v* ]]; then
    echo "$version"
  else
    echo "v$version"
  fi
}

# ============================================================================
# Dirty Tree Detection
# ============================================================================

# Check if working tree has uncommitted changes
# Args: repo_path
# Returns: 0 if dirty, 1 if clean
git_ops_is_dirty() {
  local repo_path="$1"

  if ! git_ops_is_repo "$repo_path"; then
    return 1
  fi

  # Refresh index stat cache to avoid false positives when files have
  # updated mtime/ctime or after commit-tree/read-tree with identical content.
  git -C "$repo_path" update-index -q --ignore-submodules --refresh 2>/dev/null || true

  # git diff-index returns 0 if NO changes, 1 if changes exist
  # We invert: return 0 (true) if dirty, 1 (false) if clean
  if git -C "$repo_path" diff-index --quiet HEAD -- 2>/dev/null; then
    return 1  # Clean (no changes)
  else
    return 0  # Dirty (has changes)
  fi
}

# Check if there are untracked files
# Args: repo_path
# Returns: 0 if has untracked, 1 if no untracked
git_ops_has_untracked() {
  local repo_path="$1"

  local untracked
  if ! git_ops_is_repo "$repo_path"; then
    return 1
  fi

  if ! untracked=$(git -C "$repo_path" ls-files --others --exclude-standard 2>/dev/null); then
    log_error "Failed to list untracked files"
    return 1
  fi

  if [[ -n "$untracked" ]]; then
    return 0  # Has untracked files
  else
    return 1  # No untracked files
  fi
}

# Get human-readable dirty status
# Args: repo_path
# Returns: "clean", "modified", "untracked", "modified+untracked"
git_ops_dirty_status() {
  local repo_path="$1"
  local modified=false
  local untracked=false

  if ! git_ops_is_repo "$repo_path"; then
    echo "unknown"
    return 1
  fi

  if git_ops_is_dirty "$repo_path"; then
    modified=true
  fi

  if git_ops_has_untracked "$repo_path"; then
    untracked=true
  fi

  if $modified && $untracked; then
    echo "modified+untracked"
  elif $modified; then
    echo "modified"
  elif $untracked; then
    echo "untracked"
  else
    echo "clean"
  fi
}

# ============================================================================
# Tag Operations
# ============================================================================

# Check if a tag exists
# Args: repo_path tag
# Returns: 0 if exists, 1 if not
git_ops_tag_exists() {
  local repo_path="$1"
  local tag="$2"

  if ! git_ops_is_repo "$repo_path"; then
    return 1
  fi

  if [[ -z "$tag" ]]; then
    log_error "Tag is empty"
    return 1
  fi

  # Use show-ref --verify for exact match
  git -C "$repo_path" show-ref --tags --verify "refs/tags/$tag" >/dev/null 2>&1
}

# Get the commit SHA that a tag points to
# Args: repo_path tag
# Returns: SHA on stdout, or error
git_ops_tag_sha() {
  local repo_path="$1"
  local tag="$2"

  if [[ -z "$tag" ]]; then
    log_error "Tag is empty"
    return 1
  fi

  if ! git_ops_tag_exists "$repo_path" "$tag"; then
    log_error "Tag does not exist: $tag"
    return 1
  fi

  # Dereference tag to commit (handles annotated tags)
  git -C "$repo_path" rev-parse --verify "${tag}^{commit}" 2>/dev/null
}

# List tags matching a pattern
# Args: repo_path [pattern]
# Returns: tags, one per line
git_ops_list_tags() {
  local repo_path="$1"
  local pattern="${2:-}"

  if ! git_ops_is_repo "$repo_path"; then
    return 1
  fi

  if [[ -n "$pattern" ]]; then
    git -C "$repo_path" tag -l "$pattern" 2>/dev/null
  else
    git -C "$repo_path" tag -l 2>/dev/null
  fi
}

# ============================================================================
# Branch Operations
# ============================================================================

# Get current branch name (or HEAD if detached)
# Args: repo_path
# Returns: branch name or "HEAD"
git_ops_current_branch() {
  local repo_path="$1"

  if ! git_ops_is_repo "$repo_path"; then
    return 1
  fi

  local branch
  branch=$(git -C "$repo_path" symbolic-ref --short HEAD 2>/dev/null) || branch="HEAD"
  echo "$branch"
}

# Get current HEAD commit
# Args: repo_path
# Returns: full SHA
git_ops_head_sha() {
  local repo_path="$1"

  if ! git_ops_is_repo "$repo_path"; then
    return 1
  fi

  git -C "$repo_path" rev-parse HEAD 2>/dev/null
}

# ============================================================================
# Build Info
# ============================================================================

# Get complete git info for a build as JSON
# Args: repo_path ref [--allow-dirty]
# Returns: JSON object with git info, or error if dirty and not allowed
git_ops_get_build_info() {
  local repo_path="$1"
  local ref="$2"
  local allow_dirty="${3:-false}"

  # Validate repository
  if ! git_ops_is_repo "$repo_path"; then
    echo '{"error": "not a git repository"}'
    return 1
  fi

  if [[ -z "$ref" ]]; then
    log_error "Ref is empty"
    echo '{"error": "ref is empty"}'
    return 1
  fi

  # Check for dirty tree
  local dirty_status
  if ! dirty_status=$(git_ops_dirty_status "$repo_path"); then
    log_error "Failed to determine dirty status"
    echo '{"error": "cannot determine dirty status"}'
    return 1
  fi

  if [[ "$dirty_status" != "clean" && "$allow_dirty" != "--allow-dirty" && "$allow_dirty" != "true" ]]; then
    log_error "Working tree is $dirty_status. Use --allow-dirty to override."
    jq -nc \
        --arg dirty_status "$dirty_status" \
        '{
            error: "dirty working tree",
            dirty_status: $dirty_status,
            hint: "Commit or stash changes, or use --allow-dirty flag"
        }'
    return 1
  fi

  # Resolve ref to SHA
  local resolved_sha ref_type resolved_ref

  # Determine ref type and resolve
  if git_ops_tag_exists "$repo_path" "$ref"; then
    ref_type="tag"
    resolved_ref="$ref"
    if ! resolved_sha=$(git_ops_tag_sha "$repo_path" "$ref"); then
      log_error "Cannot resolve tag: $ref"
      jq -nc --arg ref "$ref" '{error: "cannot resolve tag", ref: $ref}'
      return 1
    fi
  elif git -C "$repo_path" show-ref --verify "refs/heads/$ref" >/dev/null 2>&1; then
    ref_type="branch"
    resolved_ref="$ref"
    if ! resolved_sha=$(git -C "$repo_path" rev-parse "refs/heads/$ref" 2>/dev/null); then
      log_error "Cannot resolve branch: $ref"
      jq -nc --arg ref "$ref" '{error: "cannot resolve branch", ref: $ref}'
      return 1
    fi
  elif [[ "$ref" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
    # Looks like a SHA
    ref_type="commit"
    if ! resolved_sha=$(git_ops_resolve_ref "$repo_path" "$ref"); then
      jq -nc --arg ref "$ref" '{error: "cannot resolve commit", ref: $ref}'
      return 1
    fi
    resolved_ref="$resolved_sha"
  else
    # Try as a generic ref
    if ! resolved_sha=$(git_ops_resolve_ref "$repo_path" "$ref"); then
      log_error "Cannot resolve ref: $ref"
      jq -nc --arg ref "$ref" '{error: "cannot resolve ref", ref: $ref}'
      return 1
    fi
    ref_type="ref"
    resolved_ref="$ref"
  fi

  # Get additional info
  local head_sha current_branch
  if ! head_sha=$(git_ops_head_sha "$repo_path"); then
    log_error "Cannot resolve HEAD"
    echo '{"error": "cannot resolve head"}'
    return 1
  fi

  if ! current_branch=$(git_ops_current_branch "$repo_path"); then
    log_error "Cannot resolve current branch"
    echo '{"error": "cannot resolve current branch"}'
    return 1
  fi

  # Build JSON response
  local at_head=false
  [[ "$resolved_sha" = "$head_sha" ]] && at_head=true

  jq -nc \
      --arg repo_path "$repo_path" \
      --arg requested_ref "$ref" \
      --arg resolved_ref "$resolved_ref" \
      --arg ref_type "$ref_type" \
      --arg git_sha "$resolved_sha" \
      --arg head_sha "$head_sha" \
      --arg current_branch "$current_branch" \
      --arg dirty_status "$dirty_status" \
      --argjson at_head "$at_head" \
      --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
      '{
          repo_path: $repo_path,
          requested_ref: $requested_ref,
          resolved_ref: $resolved_ref,
          ref_type: $ref_type,
          git_sha: $git_sha,
          head_sha: $head_sha,
          current_branch: $current_branch,
          dirty_status: $dirty_status,
          at_head: $at_head,
          timestamp: $timestamp
      }'
}

# Validate that a repo is ready for release build
# Args: repo_path version [--allow-dirty]
# Returns: 0 if ready, 1 if not (with error details on stderr)
git_ops_validate_for_build() {
  local repo_path="$1"
  local version="$2"
  local allow_dirty="${3:-false}"

  local errors=0

  # Check repository exists
  if ! git_ops_is_repo "$repo_path"; then
    ((errors++))
  fi

  # Convert version to tag
  local tag
  if ! tag=$(git_ops_version_to_tag "$version"); then
    ((errors++))
  fi

  # Check tag exists
  if [[ -n "$tag" ]] && ! git_ops_tag_exists "$repo_path" "$tag"; then
    log_error "Tag does not exist: $tag"
    log_info "Hint: Create tag with 'git tag $tag' or 'git tag -a $tag -m \"Release $version\"'"
    ((errors++))
  fi

  # Check for dirty tree (unless --allow-dirty)
  if [[ "$allow_dirty" != "--allow-dirty" && "$allow_dirty" != "true" ]]; then
    if git_ops_is_dirty "$repo_path"; then
      log_error "Working tree has uncommitted changes"
      log_info "Hint: Commit or stash changes, or use --allow-dirty"
      ((errors++))
    fi

    if git_ops_has_untracked "$repo_path"; then
      log_warn "Working tree has untracked files (build will proceed)"
    fi
  fi

  if [[ $errors -gt 0 ]]; then
    return 1
  fi

  log_info "Repository validated for build: $version ($tag)"
  return 0
}

# ============================================================================
# Checkout Operations (for isolated builds)
# ============================================================================

# Create a clean worktree for building at a specific ref
# Args: repo_path ref target_dir
# Returns: 0 on success, creates worktree at target_dir
git_ops_create_build_worktree() {
  local repo_path="$1"
  local ref="$2"
  local target_dir="$3"

  if ! git_ops_is_repo "$repo_path"; then
    return 1
  fi

  if ! git_ops_validate_build_dir "$target_dir"; then
    return 1
  fi

  if [[ -e "$target_dir" ]]; then
    log_error "Target directory already exists: $target_dir"
    return 1
  fi

  # Resolve ref first
  local sha
  sha=$(git_ops_resolve_ref "$repo_path" "$ref") || return 1

  # Create worktree
  if ! git -C "$repo_path" worktree add --detach "$target_dir" "$sha" 2>/dev/null; then
    log_error "Failed to create worktree at $target_dir"
    return 1
  fi

  log_info "Created build worktree at $target_dir (ref: $ref, sha: ${sha:0:12})"
  return 0
}

# Remove a build worktree
# Args: repo_path target_dir
git_ops_remove_build_worktree() {
  local repo_path="$1"
  local target_dir="$2"

  if ! git_ops_is_repo "$repo_path"; then
    return 1
  fi

  if ! git_ops_validate_build_dir "$target_dir"; then
    return 1
  fi

  if [[ ! -d "$target_dir" ]]; then
    log_warn "Worktree directory does not exist: $target_dir"
    return 0
  fi

  if git -C "$repo_path" worktree remove --force "$target_dir" 2>/dev/null; then
    log_debug "Removed build worktree: $target_dir"
    return 0
  fi

  log_error "Failed to remove build worktree: $target_dir"
  return 1
}

# Export a portable Git context without copying hooks, configuration, credentials
# or linked-worktree pointers. Only top-level, complete SHA-1 worktrees are
# supported. Working files are transported separately by the caller. Restore
# reconstructs an index from HEAD: staged/unstaged edits remain dirty bytes,
# while the original source index and host checkouts are never changed.
_git_ops_build_git() (
  local name
  for name in ${!GIT_@}; do unset "$name"; done
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
  export GIT_NO_REPLACE_OBJECTS=1 GIT_OPTIONAL_LOCKS=0 GIT_NO_LAZY_FETCH=1
  git -c core.hooksPath=/dev/null -c core.fsmonitor=false "$@"
)

# Read effective source settings, including normal system/global config, without
# inheriting a different repository or index through the caller's environment.
# This is used only for scalar reads, never to execute configured filters/hooks.
_git_ops_build_source_config() (
  local name
  for name in ${!GIT_@}; do
    case "$name" in
      GIT_CONFIG_GLOBAL|GIT_CONFIG_SYSTEM|GIT_CONFIG_NOSYSTEM|GIT_CONFIG_COUNT|GIT_CONFIG_KEY_*|GIT_CONFIG_VALUE_*|GIT_CONFIG_PARAMETERS) ;;
      *) unset "$name" ;;
    esac
  done
  export GIT_NO_REPLACE_OBJECTS=1 GIT_OPTIONAL_LOCKS=0 GIT_NO_LAZY_FETCH=1
  git -c core.hooksPath=/dev/null -c core.fsmonitor=false -C "$1" config --get "$2"
)

_git_ops_build_line_endings() {
  local source="$1" autocrlf eol status=0
  autocrlf=$(_git_ops_build_source_config "$source" core.autocrlf) || status=$?
  if [[ "$status" == 1 ]]; then autocrlf=false
  elif [[ "$status" != 0 ]]; then
    printf '[git-context] Cannot read effective source core.autocrlf\n' >&2; return 4
  fi
  autocrlf="${autocrlf,,}"
  case "$autocrlf" in true|false|input) ;; *)
    printf '[git-context] Unsupported core.autocrlf; set true, false, or input explicitly\n' >&2; return 4 ;;
  esac
  status=0
  eol=$(_git_ops_build_source_config "$source" core.eol) || status=$?
  if [[ "$status" == 1 ]]; then eol=native
  elif [[ "$status" != 0 ]]; then
    printf '[git-context] Cannot read effective source core.eol\n' >&2; return 4
  fi
  eol="${eol,,}"
  case "$eol" in lf|crlf|native) ;; *)
    printf '[git-context] Unsupported core.eol; set lf, crlf, or native explicitly\n' >&2; return 4 ;;
  esac
  jq -cn --arg autocrlf "$autocrlf" --arg eol "$eol" '{core_autocrlf:$autocrlf,core_eol:$eol}'
}

_git_ops_build_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$1" | awk '{print $1}'
  else
    shasum -a 256 -- "$1" | awk '{print $1}'
  fi
}

_git_ops_build_refs() {
  _git_ops_build_git -C "$1" for-each-ref --format='%(objectname) %(refname)' refs/tags/ |
    jq -Rn '[inputs | split(" ") | {key: .[1], value: .[0]}] | from_entries'
}

# Index flags and sparse checkouts hide missing/changed working files from
# Git's dirty checks. Rebuilding such an index from HEAD would change version
# stamps, so reject these source modes rather than silently changing semantics.
_git_ops_validate_build_context_source() {
  local source="$1" top sparse entry sparse_status=0
  top=$(_git_ops_build_git -C "$source" rev-parse --show-toplevel 2>/dev/null) || {
    printf '[git-context] Source must be a non-bare Git worktree\n' >&2; return 4;
  }
  [[ "$top" == "$source" ]] || {
    printf '[git-context] Source must be the repository top level, not a subdirectory\n' >&2; return 4;
  }
  [[ "$(_git_ops_build_git -C "$source" rev-parse --is-shallow-repository)" == false ]] || {
    printf '[git-context] Shallow source history is unsupported; provide a complete checkout\n' >&2; return 4;
  }
  [[ "$(_git_ops_build_git -C "$source" rev-parse --show-object-format)" == sha1 ]] || {
    printf '[git-context] Build context currently requires SHA-1 Git objects\n' >&2; return 4;
  }
  sparse=$(_git_ops_build_git -C "$source" config --bool core.sparseCheckout) || sparse_status=$?
  if [[ "$sparse_status" == 1 ]]; then sparse=false
  elif [[ "$sparse_status" != 0 ]]; then
    printf '[git-context] Cannot read source sparse-checkout configuration\n' >&2; return 4
  fi
  [[ "$sparse" == false ]] || {
    printf '[git-context] Sparse checkout is unsupported; provide a full working tree\n' >&2; return 4;
  }
  _git_ops_build_git -C "$source" ls-files -v -z | while IFS= read -r -d '' entry; do
    case "${entry:0:1}" in
      S|[a-z])
        printf '[git-context] Source index uses skip-worktree or assume-unchanged for %q; clear the flag or provide a full checkout\n' "${entry:2}" >&2
        return 4 ;;
    esac
  done || return 4
}

# Recheck the controller identity after a transfer without exporting again.
git_ops_verify_build_context() {
  [[ $# == 2 && -d "$1" && ! -L "$1" ]] || return 4
  local source context sha ref tags endings
  context=$(jq -cse 'if length == 1 and (.[0] | type == "object") then .[0] else error("exactly one Git context object required") end' <<< "$2") || return 4
  source=$(cd "$1" && pwd -P) || return 4
  _git_ops_validate_build_context_source "$source" || return 4
  sha=$(_git_ops_build_git -C "$source" rev-parse --verify 'HEAD^{commit}') || return 4
  ref=$(_git_ops_build_git -C "$source" symbolic-ref -q HEAD) || ref=''
  tags=$(_git_ops_build_refs "$source") || return 4
  endings=$(_git_ops_build_line_endings "$source") || return 4
  jq -e --arg sha "$sha" --arg ref "$ref" --argjson tags "$tags" --argjson endings "$endings" \
    '.git_sha == $sha and .git_ref == $ref and .tags == $tags and
     .core_autocrlf == $endings.core_autocrlf and .core_eol == $endings.core_eol' <<< "$context" >/dev/null || {
    printf '[git-context] Source HEAD, branch, tags, or line-ending settings changed after export; retry with a stable source\n' >&2; return 4;
  }
}

# git_ops_export_build_context SOURCE NEW_CONTEXT_DIR -> JSON receipt.
# No source locking/index refresh occurs; observed HEAD/ref/tag movement fails.
git_ops_export_build_context() (
  [[ $# == 2 ]] || { printf '[git-context] Export requires SOURCE and NEW_CONTEXT_DIR\n' >&2; return 4; }
  [[ -d "$1" && ! -L "$1" ]] || { printf '[git-context] Source must be an existing plain directory\n' >&2; return 4; }
  [[ "$2" == /* && ! -e "$2" && ! -L "$2" ]] || {
    printf '[git-context] Context destination must be an absent absolute directory\n' >&2; return 4;
  }
  local source destination sha ref tags bundle heads after_ref endings
  source=$(cd "$1" && pwd -P) || return 4
  _git_ops_validate_build_context_source "$source" || return 4
  sha=$(_git_ops_build_git -C "$source" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || {
    printf '[git-context] Source has no committed HEAD; commit the initial tree before building\n' >&2; return 4;
  }
  ref=$(_git_ops_build_git -C "$source" symbolic-ref -q HEAD) || ref=''
  [[ -z "$ref" || "$ref" == refs/heads/* ]] || {
    printf '[git-context] Symbolic HEAD must name a local branch\n' >&2; return 4;
  }
  tags=$(_git_ops_build_refs "$source") || return 4
  endings=$(_git_ops_build_line_endings "$source") || return 4
  mkdir -m 700 -- "$2" || return 4
  destination=$(cd "$2" && pwd -P) || return 4
  bundle="$destination/source.bundle"
  _git_ops_build_git -C "$source" bundle create "$bundle" HEAD --tags || {
    printf '[git-context] Cannot export complete HEAD/tag objects; source history must be locally available\n' >&2; return 4;
  }
  heads=$(_git_ops_build_git bundle list-heads "$bundle" |
    jq -Rn '[inputs | split(" ") | {key: .[1], value: .[0]}] | from_entries') || return 4
  jq -e --arg sha "$sha" --argjson tags "$tags" '. == ($tags + {HEAD: $sha})' <<< "$heads" >/dev/null || {
    printf '[git-context] Source HEAD or tags changed during bundle creation; retry with a stable source\n' >&2; return 4;
  }
  after_ref=$(_git_ops_build_git -C "$source" symbolic-ref -q HEAD) || after_ref=''
  [[ "$(_git_ops_build_git -C "$source" rev-parse --verify 'HEAD^{commit}')" == "$sha" &&
     "$after_ref" == "$ref" && "$(_git_ops_build_refs "$source")" == "$tags" &&
     "$(_git_ops_build_line_endings "$source")" == "$endings" ]] || {
    printf '[git-context] Source HEAD, branch, tags, or line-ending settings changed during export; retry with a stable source\n' >&2; return 4;
  }
  _git_ops_validate_build_context_source "$source" || return 4
  local digest
  digest=$(_git_ops_build_sha256 "$bundle") || return 4
  jq -cn --arg sha "$sha" --arg ref "$ref" --arg bundle "$bundle" --arg digest "$digest" --argjson tags "$tags" --argjson endings "$endings" \
    '{git_sha:$sha,git_ref:$ref,bundle_path:$bundle,bundle_sha256:$digest,tags:$tags} + $endings'
)

# git_ops_restore_build_context FRESH_SOURCE CONTEXT_JSON -> restored receipt.
# The destination must be a dedicated source directory, never an existing repo.
git_ops_restore_build_context() (
  [[ $# == 2 && -d "$1" && ! -L "$1" && ! -e "$1/.git" && ! -L "$1/.git" ]] || return 4
  local source context sha ref tags bundle digest heads tag refresh_status=0
  context=$(jq -cse 'if length == 1 and (.[0] | type == "object") then .[0] else error("exactly one Git context object required") end' <<< "$2") || return 4
  source=$(cd "$1" && pwd -P) || return 4
  jq -e 'type == "object" and (.git_sha | type == "string" and test("^[0-9a-f]{40}$")) and
    (.git_ref | type == "string") and (.bundle_path | type == "string" and startswith("/")) and
    (.bundle_sha256 | type == "string" and test("^[0-9a-f]{64}$")) and
    (.core_autocrlf | . == "false" or . == "true" or . == "input") and
    (.core_eol | . == "lf" or . == "crlf" or . == "native") and
    (.tags | type == "object" and all(to_entries[]; (.key | startswith("refs/tags/")) and
      (.value | type == "string" and test("^[0-9a-f]{40}$"))))' <<< "$context" >/dev/null || return 4
  sha=$(jq -r .git_sha <<< "$context"); ref=$(jq -r .git_ref <<< "$context")
  tags=$(jq -c .tags <<< "$context"); bundle=$(jq -r .bundle_path <<< "$context")
  digest=$(jq -r .bundle_sha256 <<< "$context")
  [[ -f "$bundle" && ! -L "$bundle" && "$(_git_ops_build_sha256 "$bundle")" == "$digest" ]] || return 4
  if [[ -n "$ref" ]]; then
    [[ "$ref" == refs/heads/* ]] && _git_ops_build_git check-ref-format "$ref" || return 4
  fi
  while IFS= read -r tag; do
    _git_ops_build_git check-ref-format "$tag" || return 4
  done < <(jq -r 'keys[]' <<< "$tags")
  heads=$(_git_ops_build_git bundle list-heads "$bundle" |
    jq -Rn '[inputs | split(" ") | {key: .[1], value: .[0]}] | from_entries') || return 4
  jq -e --arg sha "$sha" --argjson tags "$tags" '. == ($tags + {HEAD:$sha})' <<< "$heads" >/dev/null || return 4
  # Reserve .git exclusively before invoking init; concurrent restoration fails.
  mkdir -m 700 -- "$source/.git" || return 4
  mkdir -m 700 -- "$source/.git/dsr-empty-template" || return 4
  _git_ops_build_git -C "$source" init -q --template="$source/.git/dsr-empty-template" || return 4
  _git_ops_build_git -C "$source" config --local core.autocrlf "$(jq -r .core_autocrlf <<< "$context")" || return 4
  _git_ops_build_git -C "$source" config --local core.eol "$(jq -r .core_eol <<< "$context")" || return 4
  _git_ops_build_git -C "$source" -c fetch.fsckObjects=true -c transfer.fsckObjects=true \
    fetch -q --no-write-fetch-head "$bundle" HEAD '+refs/tags/*:refs/tags/*' || return 4
  if [[ -n "$ref" ]]; then
    _git_ops_build_git -C "$source" update-ref "$ref" "$sha" || return 4
    _git_ops_build_git -C "$source" symbolic-ref HEAD "$ref" || return 4
  else
    _git_ops_build_git -C "$source" update-ref --no-deref HEAD "$sha" || return 4
  fi
  _git_ops_build_git -C "$source" read-tree HEAD || return 4
  _git_ops_build_git -C "$source" update-index -q --refresh >/dev/null 2>&1 || refresh_status=$?
  [[ "$refresh_status" == 0 || "$refresh_status" == 1 ]] || return 4
  [[ "$(_git_ops_build_git -C "$source" rev-parse --verify 'HEAD^{commit}')" == "$sha" ]] || return 4
  jq -e --argjson tags "$tags" '. == $tags' <<< "$(_git_ops_build_refs "$source")" >/dev/null || return 4
  [[ "$(_git_ops_build_sha256 "$bundle")" == "$digest" ]] || return 4
  jq -c --arg root "$source" '. + {source_root:$root}' <<< "$context"
)

# Emit a self-contained PowerShell 7 importer for a host-local bundle path.
# This uses native Git and .NET hashing; Python/jq are not required on the host.
git_ops_build_context_powershell() {
  [[ $# == 2 ]] || return 4
  local payload
  payload=$(jq -cn --arg source "$1" --argjson context "$2" '{source:$source,context:$context}' |
    base64 | tr -d '\r\n') || return 4
  printf '$payload = "%s"\n' "$payload"
  cat <<'PS'
$ErrorActionPreference = 'Stop'
try {
  $request = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json -AsHashtable
  $c = $request.context
  $source = Get-Item -LiteralPath $request.source -Force
  if (!$source.PSIsContainer -or ($source.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Source must be a plain directory' }
  $root = $source.FullName
  $gitdir = Join-Path $root '.git'
  if (Get-Item -LiteralPath $gitdir -Force -ErrorAction SilentlyContinue) { throw 'Source already has Git metadata' }
  if ($c -isnot [System.Collections.IDictionary] -or $c.git_sha -isnot [string] -or $c.git_sha -cnotmatch '^[0-9a-f]{40}$' -or
      $c.git_ref -isnot [string] -or $c.bundle_path -isnot [string] -or ![IO.Path]::IsPathRooted($c.bundle_path) -or
      $c.bundle_sha256 -isnot [string] -or $c.bundle_sha256 -cnotmatch '^[0-9a-f]{64}$' -or
      $c.core_autocrlf -isnot [string] -or $c.core_autocrlf -cnotin @('false','true','input') -or
      $c.core_eol -isnot [string] -or $c.core_eol -cnotin @('lf','crlf','native') -or
      $c.tags -isnot [System.Collections.IDictionary]) { throw 'Invalid Git context receipt' }
  $bundle = Get-Item -LiteralPath $c.bundle_path -Force
  if ($bundle.PSIsContainer -or ($bundle.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
      (Get-FileHash -LiteralPath $bundle.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -cne $c.bundle_sha256) { throw 'Git bundle hash mismatch' }
  foreach ($entry in @(Get-ChildItem Env:)) { if ($entry.Name -like 'GIT_*') { [Environment]::SetEnvironmentVariable($entry.Name, $null, 'Process') } }
  $nullPath = if ($IsWindows) { 'NUL' } else { '/dev/null' }
  $env:GIT_CONFIG_NOSYSTEM='1'; $env:GIT_CONFIG_GLOBAL=$nullPath
  $env:GIT_NO_REPLACE_OBJECTS='1'; $env:GIT_OPTIONAL_LOCKS='0'; $env:GIT_NO_LAZY_FETCH='1'
  function Invoke-ContextGit {
    $output = @(& git -c "core.hooksPath=$nullPath" -c core.fsmonitor=false @args)
    if ($LASTEXITCODE -ne 0) { throw "Git context operation failed ($LASTEXITCODE)" }
    $output
  }
  if ($c.git_ref) {
    if (!$c.git_ref.StartsWith('refs/heads/', [StringComparison]::Ordinal)) { throw 'Invalid source branch' }
    Invoke-ContextGit check-ref-format $c.git_ref | Out-Null
  }
  foreach ($tag in $c.tags.Keys) {
    if (!$tag.StartsWith('refs/tags/', [StringComparison]::Ordinal) -or $c.tags[$tag] -isnot [string] -or
        $c.tags[$tag] -cnotmatch '^[0-9a-f]{40}$') { throw 'Invalid source tag' }
    Invoke-ContextGit check-ref-format $tag | Out-Null
  }
  $heads = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
  foreach ($line in @(Invoke-ContextGit bundle list-heads $bundle.FullName)) {
    $parts = $line.Split(' ', 2)
    if ($parts.Count -ne 2 -or $heads.ContainsKey($parts[1])) { throw 'Invalid bundle ref inventory' }
    $heads.Add($parts[1], $parts[0])
  }
  if ($heads.Count -ne ($c.tags.Count + 1) -or !$heads.ContainsKey('HEAD') -or $heads['HEAD'] -cne $c.git_sha) { throw 'Bundle HEAD mismatch' }
  foreach ($tag in $c.tags.Keys) { if (!$heads.ContainsKey($tag) -or $heads[$tag] -cne $c.tags[$tag]) { throw 'Bundle tag mismatch' } }
  New-Item -ItemType Directory -Path $gitdir | Out-Null
  $template = Join-Path $gitdir 'dsr-empty-template'
  New-Item -ItemType Directory -Path $template | Out-Null
  Invoke-ContextGit -C $root init -q "--template=$template" | Out-Null
  Invoke-ContextGit -C $root config --local core.autocrlf $c.core_autocrlf | Out-Null
  Invoke-ContextGit -C $root config --local core.eol $c.core_eol | Out-Null
  Invoke-ContextGit -C $root -c fetch.fsckObjects=true -c transfer.fsckObjects=true fetch -q --no-write-fetch-head $bundle.FullName HEAD '+refs/tags/*:refs/tags/*' | Out-Null
  if ($c.git_ref) {
    Invoke-ContextGit -C $root update-ref $c.git_ref $c.git_sha | Out-Null
    Invoke-ContextGit -C $root symbolic-ref HEAD $c.git_ref | Out-Null
  } else { Invoke-ContextGit -C $root update-ref --no-deref HEAD $c.git_sha | Out-Null }
  Invoke-ContextGit -C $root read-tree HEAD | Out-Null
  & git -c "core.hooksPath=$nullPath" -c core.fsmonitor=false -C $root update-index -q --refresh *> $null
  if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 1) { throw 'Unable to refresh private index' }
  if ((Invoke-ContextGit -C $root rev-parse --verify 'HEAD^{commit}') -cne $c.git_sha) { throw 'Restored HEAD mismatch' }
  $restored = @(Invoke-ContextGit -C $root for-each-ref '--format=%(objectname) %(refname)' refs/tags/)
  if ($restored.Count -ne $c.tags.Count) { throw 'Restored tag count mismatch' }
  foreach ($line in $restored) {
    $parts=$line.Split(' ', 2)
    if (!$c.tags.Contains($parts[1]) -or $c.tags[$parts[1]] -cne $parts[0]) { throw 'Restored tag mismatch' }
  }
  if ((Get-FileHash -LiteralPath $bundle.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -cne $c.bundle_sha256) { throw 'Bundle changed during import' }
  $c['source_root']=$root
  $c | ConvertTo-Json -Depth 10 -Compress
} catch { [Console]::Error.WriteLine('[git-context] ' + $_.Exception.Message); exit 4 }
PS
}

# Export functions
export -f git_ops_is_repo git_ops_validate_build_dir
export -f git_ops_resolve_ref git_ops_version_to_tag
export -f git_ops_is_dirty git_ops_has_untracked git_ops_dirty_status
export -f git_ops_tag_exists git_ops_tag_sha git_ops_list_tags
export -f git_ops_current_branch git_ops_head_sha
export -f git_ops_get_build_info git_ops_validate_for_build
export -f git_ops_create_build_worktree git_ops_remove_build_worktree
export -f _git_ops_build_git _git_ops_build_sha256 _git_ops_build_refs
export -f git_ops_export_build_context git_ops_restore_build_context git_ops_build_context_powershell
export -f git_ops_verify_build_context
export -f _git_ops_validate_build_context_source
export -f _git_ops_build_source_config _git_ops_build_line_endings
