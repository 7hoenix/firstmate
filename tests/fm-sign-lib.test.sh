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

test_baseline_block_reproduces
test_disable_scopes_to_worktree
test_disabled_worktree_commits_primary_still_blocks
test_idempotent
test_rejects_non_worktree
