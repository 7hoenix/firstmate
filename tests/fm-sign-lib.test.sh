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

# $WT is a worktree of an ARBITRARY operator project repo, not just firstmate's own
# clone, so the documented core.bare footgun is reachable: a bare main repo with
# linked worktrees is an ordinary pool layout. git ignores core.bare in a linked
# worktree until extensions.worktreeConfig goes on, at which point every linked
# worktree of that repo dies with "this operation must be run in a work tree". The
# disable must refuse rather than inflict that on a repo firstmate does not own.
test_refuses_bare_common_config() {
  local bare="$TMP_ROOT/bare-pool.git" wt="$TMP_ROOT/bare-wt" before
  git clone -q --bare "$POOL" "$bare"
  git -C "$bare" worktree add -q --detach "$wt" HEAD
  before=$(cat "$bare/config")

  git -C "$wt" status --porcelain >/dev/null 2>&1 \
    || fail "setup: the linked worktree of a bare repo should work before the disable"

  disable_worktree_commit_signing "$wt" 2>/dev/null \
    && fail "disable should refuse a repo whose shared config sets core.bare=true"

  [ "$before" = "$(cat "$bare/config")" ] \
    || fail "shared config was modified despite the refusal"
  assert_absent "$bare/worktrees/bare-wt/config.worktree" \
    "a refused repo must not get a per-worktree config either"
  git -C "$wt" status --porcelain >/dev/null 2>&1 \
    || fail "the linked worktree was broken by the refused disable"

  pass "disable refuses a bare shared config instead of breaking every linked worktree"
}

# The other half of the same footgun: core.worktree in the shared config starts
# being honored in linked worktrees once the extension is on, so every pooled
# worktree of that repo silently resolves to the captain's primary working tree.
test_refuses_core_worktree_in_common_config() {
  local pool="$TMP_ROOT/cw-pool" wt="$TMP_ROOT/cw-wt" before
  git init -q "$pool"
  git -C "$pool" commit -q --allow-empty --no-gpg-sign -m init
  git -C "$pool" worktree add -q "$wt" HEAD
  git -C "$pool" config core.worktree "$pool"
  before=$(cat "$pool/.git/config")

  disable_worktree_commit_signing "$wt" 2>/dev/null \
    && fail "disable should refuse a repo whose shared config sets core.worktree"

  [ "$before" = "$(cat "$pool/.git/config")" ] \
    || fail "shared config was modified despite the refusal"
  assert_absent "$pool/.git/worktrees/cw-wt/config.worktree" \
    "a refused repo must not get a per-worktree config either"
  [ "$(git -C "$wt" rev-parse --show-toplevel)" = "$(cd "$wt" && pwd -P)" ] \
    || fail "the linked worktree was redirected at the primary checkout"

  pass "disable refuses a shared core.worktree instead of redirecting linked worktrees"
}

# The refusal is about the UNMIGRATED shape only. A repo whose owner already moved
# the footgun keys into config.worktree, exactly as git-config(1) prescribes, is
# safe and must still get its task worktree disabled.
test_allows_migrated_footgun_keys() {
  local bare="$TMP_ROOT/migrated.git" wt="$TMP_ROOT/migrated-wt"
  git clone -q --bare "$POOL" "$bare"
  git -C "$bare" worktree add -q --detach "$wt" HEAD
  git config --file "$bare/config.worktree" core.bare true
  git -C "$bare" config --unset core.bare

  disable_worktree_commit_signing "$wt" \
    || fail "disable should accept a repo whose footgun keys are already migrated"

  [ "$(git -C "$wt" config commit.gpgsign)" = false ] \
    || fail "worktree commit.gpgsign did not resolve to false"
  [ "$(git -C "$bare" rev-parse --is-bare-repository)" = true ] \
    || fail "the main repo stopped being bare"
  git -C "$wt" commit -q --allow-empty -m migrated \
    || fail "the linked worktree still blocks on the unavailable signer"

  pass "disable proceeds where the footgun keys are already scoped to config.worktree"
}

# A pool slot can leave firstmate's control still carrying the disable: teardown
# refuses on dirty work and the captain finishes with a manual `treehouse return
# --force`, or treehouse reclaims an expired lease. Re-leasing that slot must repair
# it, or its next human user commits unsigned under the operator's identity. The
# leftover also fools the gate - it resolves commit.gpgsign to the stale false - so
# the clear has to come BEFORE the gate, not after it.
test_stale_override_is_cleared_before_the_gate() {
  local pool="$TMP_ROOT/stale-pool" wt="$TMP_ROOT/stale-wt"
  git init -q "$pool"
  git -C "$pool" commit -q --allow-empty --no-gpg-sign -m init
  git -C "$pool" worktree add -q "$wt" HEAD
  # The slot as a manual --force return hands it back: override still in place.
  git -C "$wt" config extensions.worktreeConfig true
  git -C "$wt" config --worktree commit.gpgsign false
  git -C "$wt" config --worktree tag.gpgsign false
  # The captain has since turned signing off, so this task earns no disable at all
  # and the slot must come back clean rather than inheriting the previous one.
  git -C "$pool" config commit.gpgsign false
  git -C "$pool" config tag.gpgsign false

  disable_worktree_commit_signing "$wt" \
    || fail "disable returned non-zero for a slot carrying a stale override"

  assert_no_grep "gpgsign" "$pool/.git/worktrees/stale-wt/config.worktree" \
    "a re-leased slot must not keep a disable it did not earn from this task"

  pass "disable clears a stale override before the signing gate reads it"
}

# The same leftover, but this time the task really does need the disable: clearing
# first must not leave the worktree half-configured.
test_stale_override_is_reestablished_when_still_needed() {
  local pool="$TMP_ROOT/restale-pool" wt="$TMP_ROOT/restale-wt"
  git init -q "$pool"
  git -C "$pool" commit -q --allow-empty --no-gpg-sign -m init
  git -C "$pool" worktree add -q "$wt" HEAD
  git -C "$wt" config extensions.worktreeConfig true
  git -C "$wt" config --worktree commit.gpgsign false

  disable_worktree_commit_signing "$wt" \
    || fail "disable returned non-zero for a slot carrying a partial stale override"

  [ "$(git -C "$wt" config commit.gpgsign)" = false ] \
    || fail "commit.gpgsign was not re-established after the stale clear"
  [ "$(git -C "$wt" config tag.gpgsign)" = false ] \
    || fail "tag.gpgsign was not re-established after the stale clear"
  git -C "$wt" commit -q --allow-empty -m reestablished \
    || fail "worktree blocks on the unavailable signer after the stale clear"

  pass "a stale override is re-established from scratch when the task still needs it"
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
test_refuses_bare_common_config
test_refuses_core_worktree_in_common_config
test_allows_migrated_footgun_keys
test_stale_override_is_cleared_before_the_gate
test_stale_override_is_reestablished_when_still_needed
# Run last: these deliberately restore signing in $WT, which earlier assertions need.
test_teardown_cleanup_unsticks_pool_slot
test_cleanup_is_idempotent_and_best_effort
test_restore_puts_a_cleared_override_back
test_restore_is_best_effort
