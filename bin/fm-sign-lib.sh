# shellcheck shell=bash
# Worktree-scoped commit-signing control for autonomous crewmates.
#
# Usage: . bin/fm-sign-lib.sh   (no FM_* setup required)
#
# The problem: a crewmate inherits the operator's global git config. When that
# sets commit.gpgsign=true backed by an INTERACTIVE signer (e.g. a GUI GPG or
# 1Password agent that needs a click to approve), every autonomous commit blocks
# forever - an unattended agent can never answer the prompt. Unsigned autonomous
# commits are standing policy, so fm-spawn disables signing for each task worktree
# it hands to a crewmate.
#
# The mechanism (git's only native per-worktree config namespace):
#   0. Do nothing at all unless signing actually resolves ON in this worktree
#   1. git config extensions.worktreeConfig true   -- on the SHARED pooled repo
#   2. git config --worktree commit.gpgsign false   -- in THIS worktree's own
#      $GIT_DIR/config.worktree
#      git config --worktree tag.gpgsign false
# Step 1 must run first: without the extension, `git config --worktree` silently
# falls back to writing the shared repo config, which would leak the override to
# every worktree. With the extension on, git ADDITIONALLY reads each worktree's
# own config.worktree; a worktree that has none (the primary checkout, sibling
# pooled worktrees, the captain's other repos) is behaviorally unchanged and keeps
# its normal signing. So the override is scoped to exactly the one worktree.
#
# Why touching the shared pooled clone at all is safe, and how narrow it stays:
#   - Step 0 keeps the whole mechanism off the repos that do not need it. A repo
#     where neither commit.gpgsign nor tag.gpgsign resolves true has nothing to
#     neutralize, so it is left byte-untouched: no extensions.worktreeConfig, no
#     config.worktree. Only clones whose inherited config would really block an
#     autonomous commit ever get the shared-config key.
#   - Where it does run, enabling the extension is idempotent and behaviorally
#     inert on its own: it only tells git to look for config.worktree files, which
#     none of the untouched worktrees have.
#   - The documented core.bare / core.worktree footgun (those keys in the common
#     config wrongly applying to all worktrees once the extension is on) does not
#     bite firstmate's clone: core.bare=false is harmless and correct for every
#     non-bare worktree, and core.worktree is unset. Verified: enabling the
#     extension migrates and duplicates nothing, and the primary keeps signing.
#   - extensions.worktreeConfig and `git config --worktree` have shipped since git
#     2.20 (2018). On a repositoryformatversion=0 repo (firstmate's clone is one)
#     an older git that predates the extension merely ignores it and reads no
#     config.worktree - signing stays on, degrading to today's behavior, never a
#     corruption.
#   - The override belongs to the TASK, not to the pool slot. Firstmate returns
#     worktrees to a reusable treehouse pool rather than deleting them, so nothing
#     ever removes config.worktree on its own; teardown therefore clears both keys
#     explicitly (clear_worktree_commit_signing_override, called from
#     bin/fm-teardown.sh's return path and bin/fm-home-seed.sh's rollback) before
#     the slot goes back. A recycled slot carries no override, so nothing leaks.

# worktree_signing_is_in_effect <worktree-path>
# True when commit.gpgsign or tag.gpgsign resolves true for <worktree-path>, i.e.
# when an autonomous commit or tag there would really reach the signer.
worktree_signing_is_in_effect() {
  local wt=$1 key
  for key in commit.gpgsign tag.gpgsign; do
    if [ "$(git -C "$wt" config --type=bool --get "$key" 2>/dev/null)" = true ]; then
      return 0
    fi
  done
  return 1
}

# disable_worktree_commit_signing <worktree-path>
# Scope commit.gpgsign=false and tag.gpgsign=false to <worktree-path> only, via
# the per-worktree config namespace described above. A worktree where signing is
# not in effect is left byte-untouched and reported as success, so repos that
# never sign never acquire extensions.worktreeConfig. Returns non-zero (without
# aborting the caller) when the path is empty, is not a git worktree, or a git
# config write fails, so the caller can warn rather than silently ship a worktree
# that will block on an interactive signer.
disable_worktree_commit_signing() {
  local wt=$1
  [ -n "$wt" ] || return 1
  git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  worktree_signing_is_in_effect "$wt" || return 0
  git -C "$wt" config extensions.worktreeConfig true || return 1
  git -C "$wt" config --worktree commit.gpgsign false || return 1
  git -C "$wt" config --worktree tag.gpgsign false || return 1
}

# clear_worktree_commit_signing_override <worktree-path>
# Remove this worktree's own commit.gpgsign / tag.gpgsign override so a pool slot
# handed back for reuse carries no leftover disable. Best-effort and idempotent by
# contract: an absent path, a non-worktree, a repo that never had the override, or
# a failing git call all return success so a cleanup problem can never block a
# teardown or rollback. The extensions.worktreeConfig guard is load-bearing -
# without the extension, `git config --worktree --unset` falls back to the SHARED
# repo config and would strip the operator's real signing setting.
clear_worktree_commit_signing_override() {
  local wt=$1 key
  [ -n "$wt" ] || return 0
  [ -d "$wt" ] || return 0
  git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  [ "$(git -C "$wt" config --type=bool --get extensions.worktreeConfig 2>/dev/null)" = true ] || return 0
  for key in commit.gpgsign tag.gpgsign; do
    git -C "$wt" config --worktree --unset-all "$key" >/dev/null 2>&1 || true
  done
  return 0
}
