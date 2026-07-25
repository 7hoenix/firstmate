#!/usr/bin/env bash
# Tests for bin/fm-worker-api.sh - the worker-hosted on-demand service helper
# (a visible, self-reaped sibling tab instead of a sub-agent/background process;
# data/worker-api-tab-4d/rfc.md, docs/worker-api.md).
#
# Pure-logic tests run with no backend. The real-tmux integration block (skipped
# when tmux/python3 are absent) drives a private tmux server on an isolated
# socket - never the host's real sessions - to exercise up/status/down, the
# one-service-per-worker refusal, port reuse on restart, dated-log retention, and
# the fm-teardown.sh reaping path that closes the registered tab while keeping the
# log. HERDR_* env is unset throughout so a herdr-launched test runner still
# takes the tmux path deterministically.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WAPI="$ROOT/bin/fm-worker-api.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-worker-api)

# Strip every backend-selecting env var so each test controls detection.
clean_env() {
  env -u HERDR_ENV -u HERDR_WORKSPACE_ID -u HERDR_SESSION -u HERDR_PANE_ID \
      -u HERDR_TAB_ID -u HERDR_SOCKET_PATH -u TMUX \
      -u FM_WORKER_API_REGISTRY -u FM_WORKER_API_LOGDIR "$@"
}

# --- pure-logic tests --------------------------------------------------------

test_help_renders() {
  local out
  out=$(clean_env "$WAPI" --help) || fail "fm-worker-api.sh --help exited non-zero"
  assert_contains "$out" "fm-worker-api.sh up" "help omitted the up synopsis"
  pass "fm-worker-api.sh: --help renders the synopsis"
}

test_up_without_registry_dies() {
  local out rc=0
  out=$(clean_env "$WAPI" up -- echo hi 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "up without a registry path must fail"
  assert_contains "$out" "no registry path" "up without a registry should explain FM_WORKER_API_REGISTRY"
  pass "fm-worker-api.sh: up without a registry path fails with a clear message"
}

test_unsupported_backend_dies() {
  local reg="$TMP_ROOT/state-unsupported/task-a.api-tabs" out rc=0
  mkdir -p "$(dirname "$reg")"
  # No HERDR_* and no $TMUX -> neither backend detectable.
  out=$(clean_env "$WAPI" up --registry "$reg" -- echo hi 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "up with no detectable backend must fail"
  assert_contains "$out" "tmux or herdr" "unsupported-backend error should name the v1 backends"
  pass "fm-worker-api.sh: up refuses when neither tmux nor herdr is detectable"
}

test_down_when_nothing_registered() {
  local reg="$TMP_ROOT/state-empty/task-b.api-tabs" out
  mkdir -p "$(dirname "$reg")"
  out=$(clean_env "$WAPI" down --registry "$reg" 2>&1) || fail "down with no registry file should be a no-op success"
  assert_contains "$out" "no service registered" "down with nothing registered should say so"
  pass "fm-worker-api.sh: down is a clean no-op when nothing is registered"
}

test_logs_prune_before() {
  local reg="$TMP_ROOT/state-prune/task-c.api-tabs" logdir="$TMP_ROOT/logs-prune" out
  mkdir -p "$(dirname "$reg")" "$logdir"
  : > "$logdir/task-c-api-2020-01-01-0000.log"
  touch -t 202001010000 "$logdir/task-c-api-2020-01-01-0000.log"
  : > "$logdir/task-c-api-2999-01-01-0000.log"   # future mtime -> newer than the cutoff
  touch -t 299901010000 "$logdir/task-c-api-2999-01-01-0000.log"
  out=$(clean_env "$WAPI" logs --registry "$reg" --logdir "$logdir" --prune-before 2025-01-01 2>&1) \
    || fail "logs --prune-before exited non-zero"
  assert_absent "$logdir/task-c-api-2020-01-01-0000.log" "prune should remove a log older than the cutoff"
  assert_present "$logdir/task-c-api-2999-01-01-0000.log" "prune should keep a log newer than the cutoff"
  assert_contains "$out" "pruned" "prune should report what it removed"
  pass "fm-worker-api.sh: logs --prune-before removes only logs older than the cutoff"
}

test_prune_before_rejects_bad_date() {
  local reg="$TMP_ROOT/state-baddate/task-d.api-tabs" rc=0
  mkdir -p "$(dirname "$reg")"
  clean_env "$WAPI" logs --registry "$reg" --logdir "$TMP_ROOT/logs-bad" --prune-before nonsense >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "prune-before must reject a non-YYYY-MM-DD date"
  pass "fm-worker-api.sh: logs --prune-before rejects a malformed date"
}

test_help_renders
test_up_without_registry_dies
test_unsupported_backend_dies
test_down_when_nothing_registered
test_logs_prune_before
test_prune_before_rejects_bad_date

# --- real-tmux integration ---------------------------------------------------

if ! command -v tmux >/dev/null 2>&1; then
  echo "skip: tmux not found - skipping fm-worker-api real-tmux integration"
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "skip: python3 not found - skipping fm-worker-api real-tmux integration"
  exit 0
fi

REAL_TMUX=$(command -v tmux)
SOCKET="fm-worker-api-smoke-$$"

tmux_cleanup() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
}
# Only the private tmux server needs explicit teardown; the temp root is cleaned
# by fm_test_tmproot's own registered trap (and is a harmless /tmp leak either
# way, matching the rest of the suite).
trap tmux_cleanup EXIT

"$REAL_TMUX" -L "$SOCKET" new-session -d -s firstmate -n fm-inttask -x 200 -y 50 \
  || fail "could not start the private tmux server"

# The helper's backend issues bare `tmux ...`; point them (and backend detection)
# at the private server by exporting a $TMUX naming its socket. tmux -L uses a
# socket under a per-user dir, so resolve its actual path. $TMUX is
# "socket_path,server_pid,session_id"; session_id 0 selects the first session.
TMUX_PID=$("$REAL_TMUX" -L "$SOCKET" display-message -p '#{pid}')
TMUX_SOCK_PATH=$("$REAL_TMUX" -L "$SOCKET" display-message -p '#{socket_path}')
SOCKET_PATH_TMUX="$TMUX_SOCK_PATH,$TMUX_PID,0"

wapi_tmux() {  # run the helper on the tmux path against the private server
  clean_env "TMUX=$SOCKET_PATH_TMUX" "$@"
}

HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"
ID=inttask
REG="$HOME_DIR/state/$ID.api-tabs"
LOGDIR="$HOME_DIR/data/api-logs"

# --- up ----------------------------------------------------------------------
up_out=$(wapi_tmux FM_WORKER_API_REGISTRY="$REG" FM_WORKER_API_LOGDIR="$LOGDIR" \
  "$WAPI" up --port 8894 -- python3 -m http.server 8894) \
  || fail "up failed on real tmux"$'\n'"$up_out"
assert_contains "$up_out" "http://127.0.0.1:8894" "up should print the service URL"
"$REAL_TMUX" -L "$SOCKET" list-windows -t firstmate -F '#{window_name}' | grep -qx "fm-$ID-api" \
  || fail "up did not create the fm-$ID-api service window"
assert_grep "8894" "$REG" "up should record the port in the registry"
assert_grep "tmux" "$REG" "up should record the backend in the registry"
LOGFILE=$(cut -f5 "$REG")
assert_present "$LOGFILE" "up should create the dated log file"
pass "real tmux: up opens the service window, records the registry line, and creates the dated log"

# --- status ------------------------------------------------------------------
st_out=$(wapi_tmux FM_WORKER_API_REGISTRY="$REG" FM_WORKER_API_LOGDIR="$LOGDIR" "$WAPI" status) \
  || fail "status failed"
assert_contains "$st_out" "serving" "status should report the port as serving"
pass "real tmux: status reports the live service as serving"

# --- one service per worker --------------------------------------------------
sec_rc=0
sec_out=$(wapi_tmux FM_WORKER_API_REGISTRY="$REG" FM_WORKER_API_LOGDIR="$LOGDIR" \
  "$WAPI" up --label mock --port 8895 -- python3 -m http.server 8895 2>&1) || sec_rc=$?
[ "$sec_rc" -ne 0 ] || fail "a second service (different label) must refuse in v1"
assert_contains "$sec_out" "one per worker" "the refusal should explain the one-service-per-worker rule"
pass "real tmux: a second service with a new label is refused (one per worker)"

# --- restart reuses the recorded port ----------------------------------------
rs_out=$(wapi_tmux FM_WORKER_API_REGISTRY="$REG" FM_WORKER_API_LOGDIR="$LOGDIR" \
  "$WAPI" restart -- python3 -m http.server 8894) \
  || fail "restart failed"$'\n'"$rs_out"
assert_grep "8894" "$REG" "restart without --port should reuse the recorded port"
[ "$(wc -l < "$REG" | tr -d ' ')" = "1" ] || fail "restart should leave exactly one registry line"
pass "real tmux: restart reuses the recorded port and leaves one registry line"

# --- fm-teardown reaps the tab and keeps the log -----------------------------
# Minimal scout task so teardown skips landed-work/worktree machinery: a
# nonexistent worktree dir bypasses the treehouse return, and a present report
# satisfies the scout carve-out. window=/backend= drive the reap.
TASK_T=$("$REAL_TMUX" -L "$SOCKET" list-windows -t firstmate -F '#{session_name}:#{window_id}' | head -1)
fm_write_meta "$HOME_DIR/state/$ID.meta" \
  "window=$TASK_T" \
  "worktree=$HOME_DIR/no-such-worktree" \
  "project=$HOME_DIR/no-such-worktree" \
  "harness=echo" \
  "kind=scout" \
  "mode=no-mistakes" \
  "yolo=off" \
  "backend=tmux"
mkdir -p "$HOME_DIR/data/$ID"
: > "$HOME_DIR/data/$ID/report.md"
API_WINDOW_BEFORE=$("$REAL_TMUX" -L "$SOCKET" list-windows -t firstmate -F '#{window_name}' | grep -c "fm-$ID-api")
[ "$API_WINDOW_BEFORE" = "1" ] || fail "precondition: the api window should exist before teardown"

td_out=$(env -u TMUX FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" TMUX="$SOCKET_PATH_TMUX" \
  "$TEARDOWN" "$ID" 2>&1) || fail "teardown failed"$'\n'"$td_out"
sleep 1
if "$REAL_TMUX" -L "$SOCKET" list-windows -t firstmate -F '#{window_name}' 2>/dev/null | grep -qx "fm-$ID-api"; then
  fail "teardown did not reap the service window (orphan)"
fi
assert_absent "$REG" "teardown should remove the api-tabs registry file"
assert_present "$LOGFILE" "teardown must KEEP the dated log (collected, not deleted)"
pass "real tmux: fm-teardown reaps the registered service window and keeps the dated log"

tmux_cleanup
trap - EXIT
exit 0
