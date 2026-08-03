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
# Why enabling the extension on the shared pooled clone is safe:
#   - It is idempotent and behaviorally inert on its own: it only tells git to
#     look for config.worktree files, which none of the untouched worktrees have.
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
#   - config.worktree lives under .git/worktrees/<name>/ and is removed with the
#     worktree by `git worktree remove`/`prune` (teardown), so nothing leaks.

# disable_worktree_commit_signing <worktree-path>
# Scope commit.gpgsign=false and tag.gpgsign=false to <worktree-path> only, via
# the per-worktree config namespace described above. Returns non-zero (without
# aborting the caller) when the path is empty, is not a git worktree, or a git
# config write fails, so the caller can warn rather than silently ship a worktree
# that will block on an interactive signer.
disable_worktree_commit_signing() {
  local wt=$1
  [ -n "$wt" ] || return 1
  git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  git -C "$wt" config extensions.worktreeConfig true || return 1
  git -C "$wt" config --worktree commit.gpgsign false || return 1
  git -C "$wt" config --worktree tag.gpgsign false || return 1
}
