#!/usr/bin/env bash
# Behavior tests for fm-sign-lib.sh (disable_worktree_commit_signing).
#
# These reproduce the real block: a global commit.gpgsign=true backed by an
# UNAVAILABLE signer (gpg.program pointing at a nonexistent binary), exactly what
# an autonomous crewmate inherits from the operator's global git config. The test
# then asserts the worktree-scoped disable lets that worktree commit while the
# pooled clone / primary checkout keep their normal (blocking) signing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-sign-lib.sh
. "$ROOT/bin/fm-sign-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-sign-lib)
# fm_test_tmproot returns the path from a command-substitution subshell; ensure the
# dir itself exists in this shell before writing files directly into it (other
# suites mkdir -p their own subdirs, so they never depend on the bare root).
mkdir -p "$TMP_ROOT"
fm_git_identity

# Own the git config environment completely: a temp global config that forces
# signing with an unavailable signer, and no system config. This is the crewmate's
# inherited-config situation, isolated from the host.
export GIT_CONFIG_GLOBAL="$TMP_ROOT/globalconfig"
export GIT_CONFIG_SYSTEM=/dev/null
cat > "$GIT_CONFIG_GLOBAL" <<EOF
[commit]
	gpgsign = true
[tag]
	gpgsign = true
[gpg]
	program = $TMP_ROOT/nonexistent-signer
EOF

# A "pooled" repo mirroring firstmate's clone: core.bare=false in common config
# (the extensions.worktreeConfig footgun key) and a linked worktree like treehouse.
POOL="$TMP_ROOT/pool"
WT="$TMP_ROOT/wt-a"
SIBLING="$TMP_ROOT/wt-b"
git init -q "$POOL"
git -C "$POOL" config core.bare false
git -C "$POOL" commit -q --allow-empty --no-gpg-sign -m init
git -C "$POOL" worktree add -q "$WT" HEAD
git -C "$POOL" worktree add -q "$SIBLING" HEAD

# Baseline: signing is forced and the signer is unavailable, so a commit in the
# worktree must FAIL before the disable. If this ever passes, the test is not
# actually exercising the block and every later assertion is meaningless.
test_baseline_block_reproduces() {
  git -C "$WT" commit -q --allow-empty -m baseline 2>/dev/null \
    && fail "baseline: worktree commit unexpectedly succeeded (signer block not reproduced)"
  pass "baseline: forced signing with an unavailable signer blocks the worktree commit"
}

test_disable_scopes_to_worktree() {
  disable_worktree_commit_signing "$WT" || fail "disable returned non-zero for a valid worktree"

  # The acceptance criterion: the worktree resolves both keys to false...
  [ "$(git -C "$WT" config commit.gpgsign)" = false ] \
    || fail "worktree commit.gpgsign did not resolve to false"
  [ "$(git -C "$WT" config tag.gpgsign)" = false ] \
    || fail "worktree tag.gpgsign did not resolve to false"

  # ...while the pooled clone / primary checkout config is untouched.
  [ "$(git -C "$POOL" config commit.gpgsign)" = true ] \
    || fail "pooled clone commit.gpgsign was altered (isolation broken)"
  [ "$(git -C "$SIBLING" config commit.gpgsign)" = true ] \
    || fail "sibling worktree commit.gpgsign was altered (isolation broken)"

  # The override lives in the worktree's own config.worktree, not the shared config.
  assert_present "$POOL/.git/worktrees/wt-a/config.worktree" \
    "expected a per-worktree config.worktree for the task worktree"
  assert_no_grep "gpgsign" "$POOL/.git/config" \
    "shared pooled config must not carry a gpgsign override"

  pass "disable scopes commit/tag signing to the task worktree only"
}

# The end-to-end payoff: after the disable the worktree commits cleanly with the
# same unavailable signer, and the primary still blocks - no workaround needed.
test_disabled_worktree_commits_primary_still_blocks() {
  git -C "$WT" commit -q --allow-empty -m works \
    || fail "worktree commit still failed after disabling signing"
  git -C "$POOL" commit -q --allow-empty -m nope 2>/dev/null \
    && fail "pooled clone commit succeeded (signing wrongly disabled there too)"
  pass "task worktree commits under an unavailable signer; primary still signs"
}

# Idempotent: fm-spawn shares one pooled clone across many crewmate worktrees, so
# the extension gets enabled repeatedly. A second run must be a clean no-op.
test_idempotent() {
  disable_worktree_commit_signing "$WT" || fail "second disable returned non-zero"
  [ "$(git -C "$POOL" config --get-all extensions.worktreeConfig)" = true ] \
    || fail "extensions.worktreeConfig should be single-valued true after repeats"
  pass "repeated disable on a shared pooled clone is idempotent"
}

# A non-worktree path returns non-zero (so the caller warns) without side effects.
test_rejects_non_worktree() {
  disable_worktree_commit_signing "$TMP_ROOT/not-a-repo" 2>/dev/null \
    && fail "disable should return non-zero for a non-git path"
  disable_worktree_commit_signing "" 2>/dev/null \
    && fail "disable should return non-zero for an empty path"
  pass "disable rejects an empty or non-worktree path"
}

# Firstmate returns pooled worktrees for REUSE (treehouse return) instead of
# deleting them, so the override must belong to the task, not the slot. Teardown's
# cleanup has to leave a recycled slot signing exactly as it did before.
test_teardown_cleanup_unsticks_pool_slot() {
  disable_worktree_commit_signing "$WT" || fail "setup: disable returned non-zero"
  [ "$(git -C "$WT" config commit.gpgsign)" = false ] \
    || fail "setup: worktree override was not in place"

  clear_worktree_commit_signing_override "$WT" \
    || fail "cleanup returned non-zero for a worktree carrying the override"

  [ "$(git -C "$WT" config commit.gpgsign)" = true ] \
    || fail "recycled slot still carries commit.gpgsign=false"
  [ "$(git -C "$WT" config tag.gpgsign)" = true ] \
    || fail "recycled slot still carries tag.gpgsign=false"
  assert_no_grep "gpgsign" "$POOL/.git/worktrees/wt-a/config.worktree" \
    "returned slot's config.worktree must not keep a gpgsign override"
  # The operator's real signing setting must survive the cleanup untouched.
  assert_no_grep "gpgsign" "$POOL/.git/config" \
    "cleanup must not write or strip gpgsign in the shared pooled config"
  git -C "$WT" commit -q --allow-empty -m nope 2>/dev/null \
    && fail "recycled slot commit succeeded (signing still disabled after cleanup)"

  pass "teardown cleanup returns a pool slot with its normal signing restored"
}

# Best-effort by contract: cleanup must never fail a teardown, whatever it is
# pointed at - including a repo that never had the override at all.
test_cleanup_is_idempotent_and_best_effort() {
  clear_worktree_commit_signing_override "$WT" \
    || fail "repeat cleanup returned non-zero"
  clear_worktree_commit_signing_override "$SIBLING" \
    || fail "cleanup returned non-zero for a worktree that never had the override"
  clear_worktree_commit_signing_override "$TMP_ROOT/not-a-repo" \
    || fail "cleanup returned non-zero for a non-git path"
  clear_worktree_commit_signing_override "" \
    || fail "cleanup returned non-zero for an empty path"
  [ "$(git -C "$SIBLING" config commit.gpgsign)" = true ] \
    || fail "cleanup altered signing for an untouched sibling worktree"
  pass "cleanup is idempotent and never fails a teardown"
}

# The blast-radius gate: a repo where signing is not in effect gets the whole
# mechanism skipped, so extensions.worktreeConfig stops accumulating across every
# project clone firstmate ever touches.
test_unsigned_repo_left_untouched() {
  local unsigned_pool="$TMP_ROOT/unsigned-pool" unsigned_wt="$TMP_ROOT/unsigned-wt" before after
  git init -q "$unsigned_pool"
  git -C "$unsigned_pool" config commit.gpgsign false
  git -C "$unsigned_pool" config tag.gpgsign false
  git -C "$unsigned_pool" commit -q --allow-empty --no-gpg-sign -m init
  git -C "$unsigned_pool" worktree add -q "$unsigned_wt" HEAD
  before=$(cat "$unsigned_pool/.git/config")

  disable_worktree_commit_signing "$unsigned_wt" \
    || fail "disable should succeed (as a no-op) where signing is not in effect"

  after=$(cat "$unsigned_pool/.git/config")
  [ "$before" = "$after" ] \
    || fail "shared config of a non-signing repo was modified"
  [ -z "$(git -C "$unsigned_wt" config --get extensions.worktreeConfig)" ] \
    || fail "extensions.worktreeConfig was written into a repo that never signs"
  assert_absent "$unsigned_pool/.git/worktrees/unsigned-wt/config.worktree" \
    "a non-signing worktree must not get a config.worktree"

  pass "a repo where signing is not in effect is left byte-untouched"
}

# The clear runs before the slot is handed back, so a hand-back that never happens
# (a refused treehouse return) leaves a worktree that is still ours and may still
# hold a live agent. The compensating restore has to make it whole again.
test_restore_puts_a_cleared_override_back() {
  disable_worktree_commit_signing "$WT" || fail "setup: disable returned non-zero"
  clear_worktree_commit_signing_override "$WT"
  [ "$(git -C "$WT" config commit.gpgsign)" = true ] \
    || fail "setup: the override was not cleared first"

  restore_worktree_commit_signing_override "$WT" \
    || fail "restore returned non-zero"

  [ "$(git -C "$WT" config commit.gpgsign)" = false ] \
    || fail "restore did not put commit.gpgsign back"
  [ "$(git -C "$WT" config tag.gpgsign)" = false ] \
    || fail "restore did not put tag.gpgsign back"
  [ "$(git -C "$SIBLING" config commit.gpgsign)" = true ] \
    || fail "restore leaked into a sibling worktree"
  git -C "$WT" commit -q --allow-empty -m restored \
    || fail "worktree still blocks on the unavailable signer after restore"

  pass "restore re-scopes the signing disable to a worktree that was never handed back"
}

# Best-effort by contract: the restore compensates a failure and must never become
# a second failure of its own, whatever it is pointed at.
test_restore_is_best_effort() {
  local not_a_repo="$TMP_ROOT/restore-not-a-repo"
  mkdir -p "$not_a_repo"
  restore_worktree_commit_signing_override "$not_a_repo" 2>/dev/null \
    || fail "restore returned non-zero for an existing non-git path"
  restore_worktree_commit_signing_override "$TMP_ROOT/restore-gone" \
    || fail "restore returned non-zero for a path that no longer exists"
  restore_worktree_commit_signing_override "" \
    || fail "restore returned non-zero for an empty path"
  pass "restore never fails a teardown, whatever it is pointed at"
}

test_baseline_block_reproduces
test_disable_scopes_to_worktree
test_disabled_worktree_commits_primary_still_blocks
test_idempotent
test_rejects_non_worktree
test_unsigned_repo_left_untouched
# Run last: these deliberately restore signing in $WT, which earlier assertions need.
test_teardown_cleanup_unsticks_pool_slot
test_cleanup_is_idempotent_and_best_effort
test_restore_puts_a_cleared_override_back
test_restore_is_best_effort
