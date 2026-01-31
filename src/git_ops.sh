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
#   - Never modifies the repository
#   - All operations are read-only

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

# Export functions
export -f git_ops_is_repo git_ops_validate_build_dir
export -f git_ops_resolve_ref git_ops_version_to_tag
export -f git_ops_is_dirty git_ops_has_untracked git_ops_dirty_status
export -f git_ops_tag_exists git_ops_tag_sha git_ops_list_tags
export -f git_ops_current_branch git_ops_head_sha
export -f git_ops_get_build_info git_ops_validate_for_build
export -f git_ops_create_build_worktree git_ops_remove_build_worktree
