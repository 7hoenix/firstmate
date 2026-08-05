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
#   0. Clear any override this worktree still carries from an earlier task, then do
#      nothing further unless signing actually resolves ON in this worktree
#   1. Refuse outright if enabling the extension would change what core.bare and
#      core.worktree mean for this repo's other worktrees
#   2. git config extensions.worktreeConfig true   -- on the SHARED pooled repo
#   3. git config --worktree commit.gpgsign false   -- in THIS worktree's own
#      $GIT_DIR/config.worktree
#      git config --worktree tag.gpgsign false
# Step 2 must run first: without the extension, `git config --worktree` silently
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
#   - The documented core.bare / core.worktree footgun is real and is NOT confined
#     to firstmate's own clone: for a ship or scout task $WT is a worktree of an
#     arbitrary operator project repo. git ignores those two keys in a linked
#     worktree, but honors them there once the extension is on, so enabling it on a
#     repo whose COMMON config still carries them silently redirects every linked
#     worktree at the main working tree (core.worktree) or breaks them outright with
#     "this operation must be run in a work tree" (core.bare=true) - repo-wide
#     damage to a repo firstmate does not own, outliving the task. git documents
#     that they must be moved into config.worktree before the extension goes on, so
#     step 1 refuses on exactly that shape instead of writing the extension: the
#     caller warns, signing stays on, and the repo is left byte-untouched. Doing the
#     migration for the operator is deliberately not attempted - rewriting the
#     config of somebody else's repo is a bigger act than declining to sign.
#     firstmate's clone and ordinary project repos are unaffected and behave exactly
#     as before: core.bare=false is harmless and correct for every non-bare
#     worktree, and core.worktree is unset.
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
#     The clear must happen BEFORE the return, while the caller still owns the
#     slot - clearing afterwards would race a concurrent lease that had already
#     taken the slot and written its own override. A return that then fails leaves
#     a worktree that is still ours and may still have a live agent in it, so every
#     such path puts the override back with
#     restore_worktree_commit_signing_override.
#   - A slot can still leave firstmate's control carrying an override, because that
#     teardown clear is not the only way out: teardown can exit before its return
#     (a dirty-or-landed-work refusal it deliberately leaves for the operator), and
#     the captain's manual `treehouse return --force` or treehouse reclaiming an
#     expired lease then recycles the slot with commit.gpgsign=false still in it.
#     Any later human use of that slot would produce silently unsigned commits under
#     the operator's identity. Step 0 therefore clears unconditionally, and does so
#     BEFORE the gate reads the resolved values. The order is the whole point:
#     clearing after the gate would never happen, because the gate resolves
#     commit.gpgsign to the stale false, concludes signing is not in effect, and
#     returns success without ever touching the leftover. Clearing first means a
#     slot only ever carries a disable it earned from the current task.

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

# worktree_common_config_dir <worktree-path>
# Absolute $GIT_COMMON_DIR: the directory holding the config SHARED by every
# worktree of the repo. rev-parse may answer with a relative path, and it answers
# relative to the worktree it was asked from.
worktree_common_config_dir() {
  local wt=$1 dir
  dir=$(git -C "$wt" rev-parse --git-common-dir 2>/dev/null) || return 1
  [ -n "$dir" ] || return 1
  case $dir in
    /*) ;;
    *) dir=$wt/$dir ;;
  esac
  [ -d "$dir" ] || return 1
  printf '%s\n' "$dir"
}

# worktree_config_extension_is_safe <worktree-path>
# True when turning extensions.worktreeConfig on for this repo cannot change how
# its OTHER worktrees behave. git ignores core.worktree and core.bare from the
# common config while reading config for a linked worktree, but honors them there
# once the extension is on, so a common config that still carries either key has to
# be migrated into config.worktree by its owner first (git-config(1),
# extensions.worktreeConfig). Unreadable or unlocatable common config is treated as
# unsafe: this gate only ever says yes on a repo it could actually inspect.
worktree_config_extension_is_safe() {
  local wt=$1 common shared_worktree shared_bare
  common=$(worktree_common_config_dir "$wt") || return 1
  [ -f "$common/config" ] || return 1
  shared_worktree=$(git config --file "$common/config" --get-all core.worktree 2>/dev/null | tail -n 1 || true)
  shared_bare=$(git config --file "$common/config" --type=bool --get-all core.bare 2>/dev/null | tail -n 1 || true)
  if [ -n "$shared_worktree" ] && [ -z "$(git config --file "$common/config.worktree" --get-all core.worktree 2>/dev/null | tail -n 1 || true)" ]; then
    return 1
  fi
  if [ "$shared_bare" = true ] && [ -z "$(git config --file "$common/config.worktree" --type=bool --get-all core.bare 2>/dev/null | tail -n 1 || true)" ]; then
    return 1
  fi
  return 0
}

# disable_worktree_commit_signing <worktree-path>
# Scope commit.gpgsign=false and tag.gpgsign=false to <worktree-path> only, via
# the per-worktree config namespace described above. Any override the worktree
# still carries from an earlier task is cleared first, so the outcome depends only
# on the current task and never on what a pool slot came back with. A worktree
# where signing is not in effect is then left byte-untouched and reported as
# success, so repos that never sign never acquire extensions.worktreeConfig.
# Returns non-zero (without aborting the caller) when the path is empty, is not a
# git worktree, has a common config where enabling the extension would break its
# other worktrees, or a git config write fails, so the caller can warn rather than
# silently ship a worktree that will block on an interactive signer.
disable_worktree_commit_signing() {
  local wt=$1
  [ -n "$wt" ] || return 1
  git -C "$wt" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  clear_worktree_commit_signing_override "$wt"
  worktree_signing_is_in_effect "$wt" || return 0
  if ! worktree_config_extension_is_safe "$wt"; then
    echo "warning: not enabling extensions.worktreeConfig for $wt: its shared git config still sets core.worktree or core.bare=true, and the extension would apply those to every worktree of that repo; move them into config.worktree first" >&2
    return 1
  fi
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

# restore_worktree_commit_signing_override <worktree-path>
# Compensating action for a cleared override whose slot was NOT actually handed
# back: the worktree is still ours and may still hold a live agent, which must
# keep its unsigned-commit guarantee. Re-applies the same gated disable, and is
# a no-op wherever the disable itself is (a gone path, a non-worktree, a repo
# that never signs). Best-effort by contract: it warns at most, always returns
# success, and never becomes the reason a caller reports failure - the caller's
# own return failure stays the reported outcome.
restore_worktree_commit_signing_override() {
  local wt=$1
  [ -n "$wt" ] || return 0
  [ -d "$wt" ] || return 0
  if ! disable_worktree_commit_signing "$wt" 2>/dev/null; then
    echo "warning: could not restore the worktree-scoped commit-signing disable in $wt; an agent still running there may block on an interactive signer" >&2
  fi
  return 0
}
