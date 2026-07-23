#!/usr/bin/env bash
# Behavior tests for fm-workspace-setup.sh - per-project worktree setup that runs
# on both fresh creation and re-lease, idempotently, from config/workspace-setup.json.
#
# Every case is hermetic: scratch git repos as "worktrees", a temp config file, and
# fake commands (a fake mise, and step `run` commands that just append to a witness
# file or exit non-zero). No real mise, pnpm, bun, doppler, or network is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/bin/fm-workspace-setup.sh"
TMP_ROOT=$(fm_test_tmproot fm-workspace-setup)
mkdir -p "$TMP_ROOT"
fm_git_identity

# new_wt <name>: a fresh git repo standing in for a leased task worktree.
new_wt() {
  local wt="$TMP_ROOT/$1"
  git -C "$TMP_ROOT" init -q "$1"
  printf '%s\n' "$wt"
}

# write_config <path> <json>
write_config() { printf '%s\n' "$2" > "$1"; }

# run_setup <config> <wt> <project> [extra args...]: run the `run` subcommand,
# capturing combined output into REPLY_OUT and the exit code into REPLY_RC.
run_setup() {
  local cfg=$1 wt=$2 proj=$3
  shift 3
  REPLY_OUT=$("$HELPER" run --config "$cfg" --worktree "$wt" --project "$proj" "$@" 2>&1)
  REPLY_RC=$?
}

# ---------------------------------------------------------------------------
# 1. No config file: silent instant no-op, no marker (zero behavior change).
# ---------------------------------------------------------------------------
wt=$(new_wt no-config-wt)
run_setup "$TMP_ROOT/does-not-exist.json" "$wt" shelf
expect_code 0 "$REPLY_RC" "missing config exits 0"
[ -z "$REPLY_OUT" ] || fail "missing config must be silent, got: $REPLY_OUT"
assert_absent "$wt/.fm-workspace-setup.json" "missing config must not write a marker"
pass "no config file -> silent no-op"

# ---------------------------------------------------------------------------
# 2. Config present but no entry for this project: silent no-op.
# ---------------------------------------------------------------------------
cfg="$TMP_ROOT/basic.json"
write_config "$cfg" '{
  "shelf": { "steps": [ { "name": "deps", "run": "echo deps >> .witness" } ] }
}'
wt=$(new_wt no-entry-wt)
run_setup "$cfg" "$wt" other-project
expect_code 0 "$REPLY_RC" "unknown project exits 0"
[ -z "$REPLY_OUT" ] || fail "unknown project must be silent, got: $REPLY_OUT"
assert_absent "$wt/.fm-workspace-setup.json" "unknown project must not write a marker"
pass "config present, no entry for project -> silent no-op"

# ---------------------------------------------------------------------------
# 3. Fresh create: eligible steps run; marker written and git-excluded.
# ---------------------------------------------------------------------------
cfg="$TMP_ROOT/phases.json"
write_config "$cfg" '{
  "app": { "steps": [
    { "name": "mise",    "run": "echo mise >> .witness",    "phase": "both",   "fingerprint": [".tool-versions"] },
    { "name": "deps",    "run": "echo deps >> .witness",    "phase": "both",   "fingerprint": ["lockfile"] },
    { "name": "secrets", "run": "echo secrets >> .witness", "phase": "create" }
  ] }
}'
wt=$(new_wt fresh-wt)
printf 'tools-v1\n' > "$wt/.tool-versions"
printf 'lock-v1\n' > "$wt/lockfile"
run_setup "$cfg" "$wt" app
expect_code 0 "$REPLY_RC" "fresh create exits 0"
assert_grep "mise" "$wt/.witness" "mise ran on create"
assert_grep "deps" "$wt/.witness" "deps ran on create"
assert_grep "secrets" "$wt/.witness" "secrets ran on create"
assert_present "$wt/.fm-workspace-setup.json" "marker written after create"
assert_grep ".fm-workspace-setup.json" "$wt/.git/info/exclude" "marker added to info/exclude"
[ -z "$(git -C "$wt" status --porcelain -- .fm-workspace-setup.json)" ] \
  || fail "marker must not show as dirty in git status"
pass "fresh create -> all eligible steps run; marker written and git-excluded"

# ---------------------------------------------------------------------------
# 4. Re-lease, nothing changed: fingerprinted steps short-circuit; create skips.
# ---------------------------------------------------------------------------
: > "$wt/.witness"
run_setup "$cfg" "$wt" app
expect_code 0 "$REPLY_RC" "unchanged re-lease exits 0"
assert_contains "$REPLY_OUT" "mise=skip:unchanged" "mise short-circuits on unchanged fingerprint"
assert_contains "$REPLY_OUT" "deps=skip:unchanged" "deps short-circuits on unchanged fingerprint"
assert_contains "$REPLY_OUT" "secrets=skip:phase" "create-only secrets skipped on re-lease"
[ ! -s "$wt/.witness" ] || fail "unchanged re-lease must run nothing, witness: $(cat "$wt/.witness")"
pass "re-lease unchanged -> everything short-circuits, nothing re-runs"

# ---------------------------------------------------------------------------
# 5. Re-lease with a changed lockfile: only deps re-runs.
# ---------------------------------------------------------------------------
: > "$wt/.witness"
printf 'lock-v2\n' > "$wt/lockfile"
run_setup "$cfg" "$wt" app
expect_code 0 "$REPLY_RC" "changed-lockfile re-lease exits 0"
assert_grep "deps" "$wt/.witness" "deps re-runs when its fingerprint changes"
assert_no_grep "mise" "$wt/.witness" "mise stays short-circuited (its fingerprint unchanged)"
assert_no_grep "secrets" "$wt/.witness" "secrets stays create-only on re-lease"
pass "re-lease with changed lockfile -> only the affected step re-runs"

# ---------------------------------------------------------------------------
# 6. Disabled step is skipped; enabling it makes it run.
# ---------------------------------------------------------------------------
cfg="$TMP_ROOT/toggle.json"
write_config "$cfg" '{
  "app": { "steps": [ { "name": "ios", "run": "echo ios >> .witness", "phase": "both", "enabled": false } ] }
}'
wt=$(new_wt toggle-wt)
run_setup "$cfg" "$wt" app
assert_contains "$REPLY_OUT" "ios=off" "disabled step reported off"
assert_absent "$wt/.witness" "disabled step must not run"
write_config "$cfg" '{
  "app": { "steps": [ { "name": "ios", "run": "echo ios >> .witness", "phase": "both", "enabled": true } ] }
}'
run_setup "$cfg" "$wt" app
assert_grep "ios" "$wt/.witness" "step runs once enabled"
pass "enabled=false skips the step; flipping it to true runs it"

# ---------------------------------------------------------------------------
# 7. Failure model: optional failure warns (rc 0), required failure -> rc!=0,
#    and the worktree is still usable either way.
# ---------------------------------------------------------------------------
cfg="$TMP_ROOT/fail-optional.json"
write_config "$cfg" '{
  "app": { "steps": [ { "name": "flaky", "run": "exit 5", "phase": "both", "optional": true } ] }
}'
wt=$(new_wt opt-fail-wt)
run_setup "$cfg" "$wt" app
expect_code 0 "$REPLY_RC" "optional failure keeps rc 0"
assert_contains "$REPLY_OUT" "flaky=fail:optional" "optional failure reported but non-fatal"

cfg="$TMP_ROOT/fail-hard.json"
write_config "$cfg" '{
  "app": { "steps": [
    { "name": "ok",   "run": "echo ok >> .witness", "phase": "both" },
    { "name": "boom", "run": "exit 7", "phase": "both" }
  ] }
}'
wt=$(new_wt hard-fail-wt)
run_setup "$cfg" "$wt" app
expect_code 1 "$REPLY_RC" "required failure exits non-zero"
assert_contains "$REPLY_OUT" "boom=FAIL" "required failure reported"
assert_grep "ok" "$wt/.witness" "earlier step still ran (worktree usable)"
assert_present "$wt/.fm-workspace-setup.json" "marker still written after a failure"
# The failed step keeps ok=false so it retries next lease; fix it and re-run.
write_config "$cfg" '{
  "app": { "steps": [
    { "name": "ok",   "run": "echo ok >> .witness", "phase": "both" },
    { "name": "boom", "run": "echo boom >> .witness", "phase": "both" }
  ] }
}'
: > "$wt/.witness"
run_setup "$cfg" "$wt" app
expect_code 0 "$REPLY_RC" "re-run after fixing the step succeeds"
assert_grep "boom" "$wt/.witness" "previously-failed step re-runs and now succeeds"
pass "optional failure warns; required failure exits non-zero but leaves the worktree usable"

# ---------------------------------------------------------------------------
# 8. mise wrapping: a fake mise on PATH is used (trust + exec passthrough) when a
#    mise config is present; steps still run correctly. env vars reach the step.
# ---------------------------------------------------------------------------
fakebin=$(fm_fakebin "$TMP_ROOT/mise-case")
cat > "$fakebin/mise" <<'SH'
#!/usr/bin/env bash
# Record that mise was invoked, then behave: trust=no-op, exec=passthrough.
echo "$@" >> "$FAKE_MISE_LOG"
case "$1" in
  trust) exit 0 ;;
  exec) shift; [ "$1" = "--" ] && shift; exec "$@" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$fakebin/mise"

cfg="$TMP_ROOT/mise.json"
# $SETUP_FLAG is intentionally literal: the step command expands it at run time
# from the step's own env, not here in the test.
# shellcheck disable=SC2016
write_config "$cfg" '{
  "app": { "steps": [
    { "name": "toolchain", "run": "mise install", "phase": "both" },
    { "name": "deps",      "run": "echo flag=$SETUP_FLAG >> .witness", "phase": "both", "env": { "SETUP_FLAG": "on" } }
  ] }
}'
wt=$(new_wt mise-wt)
printf 'nodejs 22\n' > "$wt/.tool-versions"
export FAKE_MISE_LOG="$TMP_ROOT/mise-case/mise.log"
: > "$FAKE_MISE_LOG"
REPLY_OUT=$(PATH="$fakebin:$PATH" "$HELPER" run --config "$cfg" --worktree "$wt" --project app 2>&1)
REPLY_RC=$?
expect_code 0 "$REPLY_RC" "mise-wrapped run exits 0"
assert_grep "trust" "$FAKE_MISE_LOG" "mise trust called on the worktree's mise config"
assert_grep "exec --" "$FAKE_MISE_LOG" "steps run under mise exec when a mise config is present"
assert_grep "flag=on" "$wt/.witness" "step env vars reach the command"
unset FAKE_MISE_LOG
pass "mise wrapping: trust + exec passthrough used with a mise config; env vars delivered"

# ---------------------------------------------------------------------------
# 9. A create-phase step that never succeeded still runs on a re-lease (per-step
#    create tracking), so a partial first setup is not permanently skipped.
# ---------------------------------------------------------------------------
cfg="$TMP_ROOT/retry.json"
write_config "$cfg" '{
  "app": { "steps": [ { "name": "secrets", "run": "echo s >> .witness", "phase": "create" } ] }
}'
wt=$(new_wt retry-wt)
# A marker exists (re-lease), but it has no successful record for secrets - e.g. an
# earlier create run failed here. The create step must still run.
printf '{"steps":{}}\n' > "$wt/.fm-workspace-setup.json"
run_setup "$cfg" "$wt" app
assert_grep "s" "$wt/.witness" "unfinished create step re-runs on re-lease"
# Once it has succeeded, a later re-lease skips it as a completed create step.
: > "$wt/.witness"
run_setup "$cfg" "$wt" app
assert_contains "$REPLY_OUT" "secrets=skip" "completed create step is skipped on the next re-lease"
[ ! -s "$wt/.witness" ] || fail "completed create step must not re-run"
pass "create step runs until it first succeeds, then stops"

# ---------------------------------------------------------------------------
# 10. validate: active listing, malformed JSON, schema errors, and absence.
# ---------------------------------------------------------------------------
cfg="$TMP_ROOT/valid.json"
write_config "$cfg" '{
  "_comment": "documentation is ignored",
  "shelf": { "steps": [
    { "name": "mise", "run": "mise install", "phase": "both" },
    { "name": "ios",  "run": "tuist install", "phase": "create", "enabled": false }
  ] }
}'
out=$("$HELPER" validate --config "$cfg")
assert_contains "$out" "WORKSPACE_SETUP: active config/workspace-setup.json" "valid config reported active"
assert_contains "$out" "shelf: mise(both) ios(create,off)" "active listing shows steps, phases, and off flag"
assert_not_contains "$out" "_comment" "underscore-prefixed doc keys are ignored"

printf '{oops' > "$TMP_ROOT/malformed.json"
out=$("$HELPER" validate --config "$TMP_ROOT/malformed.json")
assert_contains "$out" "invalid config/workspace-setup.json - malformed JSON" "malformed JSON flagged"

write_config "$TMP_ROOT/badphase.json" '{ "a": { "steps": [ { "name": "x", "run": "y", "phase": "monthly" } ] } }'
out=$("$HELPER" validate --config "$TMP_ROOT/badphase.json")
assert_contains "$out" "phase must be one of create, lease, both" "bad phase flagged"

write_config "$TMP_ROOT/dup.json" '{ "a": { "steps": [ { "name": "x", "run": "1" }, { "name": "x", "run": "2" } ] } }'
out=$("$HELPER" validate --config "$TMP_ROOT/dup.json")
assert_contains "$out" "step names must be unique within a project" "duplicate step names flagged"

out=$("$HELPER" validate --config "$TMP_ROOT/absent.json"); rc=$?
expect_code 0 "$rc" "absent config validate exits 0"
[ -z "$out" ] || fail "absent config validate must be silent, got: $out"
pass "validate: active listing, malformed JSON, schema errors, and absence handled"

# ---------------------------------------------------------------------------
# 11. The shipped example config validates cleanly (a captain copies it as-is).
# ---------------------------------------------------------------------------
out=$("$HELPER" validate --config "$ROOT/docs/examples/workspace-setup.json")
assert_contains "$out" "WORKSPACE_SETUP: active config/workspace-setup.json" "shipped example validates"
assert_not_contains "$out" "invalid" "shipped example has no validation errors"
pass "docs/examples/workspace-setup.json validates cleanly"

# ---------------------------------------------------------------------------
# 12. Linked worktree (the real production shape): the marker and its temp glob
#     must land in the exclude file git actually honors - the shared common
#     .git/info/exclude, not the per-worktree admin dir git ignores - so the
#     marker never shows as dirty. Plain-init repos masked this because their
#     admin dir and common dir are the same file.
# ---------------------------------------------------------------------------
main_repo="$TMP_ROOT/linked-main"
git -C "$TMP_ROOT" init -q linked-main
git -C "$main_repo" commit -q --allow-empty -m init
linked_wt="$TMP_ROOT/linked-wt"
git -C "$main_repo" worktree add -q --detach "$linked_wt" >/dev/null 2>&1
cfg="$TMP_ROOT/linked.json"
write_config "$cfg" '{
  "app": { "steps": [ { "name": "deps", "run": "echo deps >> .witness", "phase": "both" } ] }
}'
run_setup "$cfg" "$linked_wt" app
expect_code 0 "$REPLY_RC" "linked-worktree setup exits 0"
assert_present "$linked_wt/.fm-workspace-setup.json" "marker written in linked worktree"
common_excl=$(git -C "$linked_wt" rev-parse --git-path info/exclude)
case "$common_excl" in /*) : ;; *) common_excl="$linked_wt/$common_excl" ;; esac
assert_grep ".fm-workspace-setup.json" "$common_excl" "marker added to the exclude file git honors"
assert_grep "fm-wss-marker" "$common_excl" "temp glob added to the exclude file git honors"
[ -z "$(git -C "$linked_wt" status --porcelain -- .fm-workspace-setup.json)" ] \
  || fail "linked-worktree marker must not show as dirty: $(git -C "$linked_wt" status --porcelain -- .fm-workspace-setup.json)"
pass "linked worktree -> marker excluded via common .git/info/exclude; worktree stays clean"

pass "ALL fm-workspace-setup tests passed"
