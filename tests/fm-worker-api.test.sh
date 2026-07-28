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
TMP_ROOT=$(fm_test_tmproot fm-worker-api)

# The port lock is machine-wide by design (concurrent `up`s in different repos
# must serialize); point it into the temp root so the suite never contends with a
# real worker or with a parallel test run.
export FM_WORKER_API_PORT_LOCK="$TMP_ROOT/portlock"

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

# cmux is out of v1 scope, and the worry was that it might be mis-detected as
# tmux. It cannot be: cmux marks its panes with CMUX_WORKSPACE_ID and never sets
# $TMUX (docs/cmux-backend.md). A $TMUX that IS present inside a cmux tab belongs
# to a real nested tmux, which is genuinely the innermost layer and correctly
# wins - the same order fm_backend_detect uses.
test_cmux_pane_is_not_mistaken_for_tmux() {
  local reg="$TMP_ROOT/state-cmux/task-cm.api-tabs" out rc=0
  mkdir -p "$(dirname "$reg")"
  out=$(clean_env CMUX_WORKSPACE_ID=ws-1 CMUX_TAB_ID=tab-1 \
    "$WAPI" up --registry "$reg" -- echo hi 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a cmux pane must refuse up in v1, not be treated as tmux"
  assert_contains "$out" "tmux or herdr" "the cmux refusal should name the v1 backends"
  assert_absent "$reg" "a refused up must not register anything"
  pass "fm-worker-api.sh: a cmux pane refuses up instead of being mis-detected as tmux"
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

# A date of the right SHAPE but an impossible value must be an error, on every
# find implementation. Two bugs converge here: the delete used to be `|| true`, so
# a date the local find rejected printed "pruned 0 log file(s)" and exited 0 - a
# false success that silently kept every log the captain asked to prune. And find
# flavors disagree: BSD rejects 2020-13-45 while a GNU-style find normalizes month
# 13 into the next year and prunes a WIDER range than was asked for. Since this
# deletes collected logs irreversibly, the components are validated directly.
test_prune_before_rejects_impossible_dates() {
  local reg="$TMP_ROOT/state-unparseable/task-u.api-tabs" logdir="$TMP_ROOT/logs-unparseable" log out rc d
  mkdir -p "$(dirname "$reg")" "$logdir"
  log="$logdir/task-u-api-2020-01-01-000000.log"
  : > "$log"
  for d in 9999-99-99 2020-13-45 2026-00-10 2026-08-32; do
    rc=0
    out=$(clean_env "$WAPI" logs --registry "$reg" --logdir "$logdir" --prune-before "$d" 2>&1) || rc=$?
    [ "$rc" -ne 0 ] || fail "prune date '$d' is impossible and must fail, got a success:"$'\n'"$out"
    assert_contains "$out" "impossible date" "the error for '$d' should say the date is impossible"
    assert_present "$log" "a failed prune must not delete anything (date '$d')"
  done
  pass "fm-worker-api.sh: logs --prune-before errors on shape-valid but impossible dates"
}

# Portable invariant across find flavors: BSD/macOS find REJECTS a far-future
# date that GNU find accepts. Either behavior is fine; reporting success without
# actually pruning is not.
test_prune_before_far_future_is_never_a_false_success() {
  local reg="$TMP_ROOT/state-future/task-f.api-tabs" logdir="$TMP_ROOT/logs-future" old rc=0
  mkdir -p "$(dirname "$reg")" "$logdir"
  old="$logdir/task-f-api-2020-01-01-000000.log"
  : > "$old"
  touch -t 202001010000 "$old"
  clean_env "$WAPI" logs --registry "$reg" --logdir "$logdir" --prune-before 2999-01-01 >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    assert_absent "$old" "prune reported success, so the older log must actually be gone"
  else
    assert_present "$old" "prune failed, so it must not have deleted anything"
  fi
  pass "fm-worker-api.sh: a far-future prune date either prunes or errors, never a false success"
}

test_sweep_leaves_a_live_task_alone() {
  local state="$TMP_ROOT/state-sweep-live" out
  mkdir -p "$state"
  printf 'api\tzellij\tses:p1\t8899\t/nonexistent.log\n' > "$state/alive.api-tabs"
  fm_write_meta "$state/alive.meta" "window=ses:w1" "backend=zellij"
  out=$(clean_env "$WAPI" sweep --state "$state" 2>&1) || fail "sweep exited non-zero"
  assert_present "$state/alive.api-tabs" "sweep must not touch a registry whose task is still live"
  [ -z "$out" ] || fail "sweep should stay silent for a healthy fleet, got: $out"
  pass "fm-worker-api.sh: sweep leaves a live task's registry alone and stays silent"
}

test_sweep_clears_an_orphaned_registry() {
  local state="$TMP_ROOT/state-sweep-orphan" out
  mkdir -p "$state"
  # No <id>.meta -> the task is gone, so nothing will ever reap this registry.
  printf 'api\tzellij\tses:p1\t8899\t/nonexistent.log\n' > "$state/ghost.api-tabs"
  out=$(clean_env "$WAPI" sweep --state "$state" 2>&1) || fail "sweep exited non-zero"
  assert_contains "$out" "ghost" "sweep should name the orphaned task"
  assert_absent "$state/ghost.api-tabs" "sweep should remove the orphaned registry"
  pass "fm-worker-api.sh: sweep closes and clears an orphaned task's registry"
}

test_sweep_dry_run_changes_nothing() {
  local state="$TMP_ROOT/state-sweep-dry" out
  mkdir -p "$state"
  printf 'api\tzellij\tses:p1\t8899\t/nonexistent.log\n' > "$state/ghost.api-tabs"
  out=$(clean_env "$WAPI" sweep --state "$state" --dry-run 2>&1) || fail "sweep --dry-run exited non-zero"
  assert_contains "$out" "would close" "dry-run should describe what it would do"
  assert_present "$state/ghost.api-tabs" "dry-run must not remove the registry"
  pass "fm-worker-api.sh: sweep --dry-run reports without changing anything"
}

test_status_all_spans_registries() {
  local state="$TMP_ROOT/state-status-all" out
  mkdir -p "$state"
  printf 'api\tzellij\tses:p1\t8899\t/nonexistent.log\n' > "$state/one.api-tabs"
  printf 'api\tzellij\tses:p2\t8898\t/nonexistent.log\n' > "$state/two.api-tabs"
  out=$(clean_env "$WAPI" status --registry "$state/one.api-tabs" --all 2>&1) || fail "status --all exited non-zero"
  assert_contains "$out" "one" "status --all should list the first task"
  assert_contains "$out" "two" "status --all should list the other task's registry too"
  pass "fm-worker-api.sh: status --all spans every registry in the state dir"
}

test_down_all_clears_the_registry() {
  local reg="$TMP_ROOT/state-downall/task-z.api-tabs" out
  mkdir -p "$(dirname "$reg")"
  printf 'api\tzellij\tses:p1\t8899\t/nonexistent.log\n' > "$reg"
  printf 'mock\tzellij\tses:p2\t8898\t/nonexistent.log\n' >> "$reg"
  out=$(clean_env "$WAPI" down --registry "$reg" --all 2>&1) || fail "down --all exited non-zero"
  assert_contains "$out" "'api' stopped" "down --all should report each stopped service"
  assert_contains "$out" "'mock' stopped" "down --all should report every label"
  [ ! -s "$reg" ] || fail "down --all should leave the registry empty, got: $(cat "$reg")"
  pass "fm-worker-api.sh: down --all stops every registered label and empties the registry"
}

# An unbreakable stale lock (a regular file, a non-empty dir, another user's lock
# in a shared /tmp) used to spin the acquire loop with no sleep and no timeout:
# `up` hung forever at full CPU. The contract is that a lock problem delays a
# launch at worst, never blocks it.
test_port_lock_never_hangs_on_an_unbreakable_stale_lock() {
  local reg="$TMP_ROOT/state-lockspin/task-l.api-tabs" lock="$TMP_ROOT/lockspin-lock" out rc=0 start elapsed
  mkdir -p "$(dirname "$reg")"
  # A regular FILE where the lock dir goes: mkdir always fails, rmdir can never
  # clear it, and it is old enough to read as stale.
  : > "$lock"
  touch -t 202001010000 "$lock"
  start=$(date +%s)
  out=$(clean_env FM_WORKER_API_PORT_LOCK="$lock" FM_WORKER_API_PORT_LOCK_WAIT=2 \
    "$WAPI" up --registry "$reg" -- echo hi 2>&1) || rc=$?
  elapsed=$(( $(date +%s) - start ))
  # It must reach the backend check (and refuse there) rather than spin in the lock.
  [ "$rc" -ne 0 ] || fail "expected the unsupported-backend refusal after the lock wait"
  assert_contains "$out" "tmux or herdr" "the run should have proceeded past the lock to the backend check"
  [ "$elapsed" -lt 30 ] || fail "acquiring an unbreakable stale lock took ${elapsed}s; it should bail out after the short wait"
  pass "fm-worker-api.sh: an unbreakable stale port lock bails out instead of spinning forever"
}

test_help_renders
test_port_lock_never_hangs_on_an_unbreakable_stale_lock
test_up_without_registry_dies
test_unsupported_backend_dies
test_cmux_pane_is_not_mistaken_for_tmux
test_down_when_nothing_registered
test_logs_prune_before
test_prune_before_rejects_bad_date
test_prune_before_rejects_impossible_dates
test_prune_before_far_future_is_never_a_false_success
test_sweep_leaves_a_live_task_alone
test_sweep_clears_an_orphaned_registry
test_sweep_dry_run_changes_nothing
test_status_all_spans_registries
test_down_all_clears_the_registry

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
# A window teardown will never kill, so the session (and this private server)
# outlives the teardown cases below. Without it the server exits when the last
# window dies and every later case fails to self-locate a container.
"$REAL_TMUX" -L "$SOCKET" new-window -d -t firstmate: -n keepalive \
  || fail "could not create the keepalive window"

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

# --- the startup banner survives on stdout -----------------------------------
# python3 -m http.server prints "Serving HTTP on ..." to STDOUT, which is fully
# buffered when it is a pipe: the banner sat in the process's own buffer and was
# lost when teardown killed it, so the log - firstmate's readiness source - never
# saw it. The launch line now runs the command line-buffered.
CURRENT_LOG=$(cut -f5 "$REG")   # the restart above rotated to a new dated log
banner_seen=0
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if grep -q "Serving HTTP" "$CURRENT_LOG" 2>/dev/null; then banner_seen=1; break; fi
  sleep 1
done
[ "$banner_seen" = 1 ] \
  || fail "the service's stdout banner never reached the log (lost to full buffering):"$'\n'"$(cat "$CURRENT_LOG")"
pass "real tmux: the service's stdout startup banner reaches the dated log"

# --- a pinned port that is already taken is refused --------------------------
# Readiness is "something is listening on the port", so launching onto an
# occupied port reported a healthy service while the real one died with
# "address already in use". :8894 is live from the up/restart above.
REG_TAKEN="$HOME_DIR/state/takenport.api-tabs"
taken_rc=0
taken_out=$(wapi_tmux FM_WORKER_API_LOGDIR="$LOGDIR" \
  "$WAPI" up --registry "$REG_TAKEN" --port 8894 -- python3 -m http.server 8894 2>&1) || taken_rc=$?
[ "$taken_rc" -ne 0 ] || fail "up onto an already-taken pinned port must refuse, got:"$'\n'"$taken_out"
assert_contains "$taken_out" "already in use" "the refusal should name the port conflict"
assert_absent "$REG_TAKEN" "a refused up must not register anything"
pass "real tmux: up refuses a pinned port that is already in use"

# --- a launch command that exits immediately fails fast ----------------------
# The command runs as a shell line, so a typo or a bad quote just exits. That
# used to stall the full readiness timeout and then report "not yet accepting".
REG_DEAD="$HOME_DIR/state/deadcmd.api-tabs"
dead_rc=0
dead_out=$(wapi_tmux FM_WORKER_API_LOGDIR="$LOGDIR" \
  "$WAPI" up --registry "$REG_DEAD" --port 8891 -- fm-no-such-binary-xyz 2>&1) || dead_rc=$?
[ "$dead_rc" -ne 0 ] || fail "up must fail when the launch command exits immediately, got:"$'\n'"$dead_out"
assert_contains "$dead_out" "API FAILED" "an immediately-exiting command should report a failure, not a slow start"
# A failed launch must leave NO residue: a registered-but-dead service would show
# up in status as down and consume the worker's single slot.
[ ! -s "$REG_DEAD" ] || fail "a failed up must not leave a registry line, got: $(cat "$REG_DEAD")"
sleep 1
if "$REAL_TMUX" -L "$SOCKET" list-windows -t firstmate -F '#{window_name}' 2>/dev/null | grep -qx "fm-deadcmd-api"; then
  fail "a failed up must close the tab it opened"
fi
pass "real tmux: up fails fast when the launch command exits, leaving no tab and no registry line"

# --- a service whose TAB was killed is cleared -------------------------------
# The tab-gone half of the liveness check. It needs a existence probe that can
# actually report a window as gone: `tmux display-message -t <dead window>` exits
# 0 and prints the session's current pane, so the generic target-exists check
# reports every tmux endpoint as alive.
REG_KILLED="$HOME_DIR/state/killedtab.api-tabs"
kt_out=$(wapi_tmux FM_WORKER_API_LOGDIR="$LOGDIR" \
  "$WAPI" up --registry "$REG_KILLED" --label alpha --port 8898 -- python3 -m http.server 8898 2>&1) \
  || fail "up failed for the killed-tab case"$'\n'"$kt_out"
KT_ENDPOINT=$(cut -f3 "$REG_KILLED")
"$REAL_TMUX" -L "$SOCKET" kill-window -t "${KT_ENDPOINT#*:}" 2>/dev/null || true
sleep 2
kt2_out=$(wapi_tmux FM_WORKER_API_LOGDIR="$LOGDIR" \
  "$WAPI" up --registry "$REG_KILLED" --label beta --port 8899 -- python3 -m http.server 8899 2>&1) \
  || fail "up should proceed after the prior service's tab was killed, got:"$'\n'"$kt2_out"
assert_contains "$kt2_out" "cleared stale service" "a service whose tab is gone should be cleared, not block the slot"
assert_contains "$kt2_out" "http://127.0.0.1:8899" "the new service should then start"
wapi_tmux FM_WORKER_API_LOGDIR="$LOGDIR" "$WAPI" down --registry "$REG_KILLED" --all >/dev/null 2>&1 || true
pass "real tmux: a service whose tab was killed is cleared instead of blocking the worker's slot"

# --- down actually STOPS the service, not just its tab -----------------------
# The feature's core guarantee. Closing the tab is not sufficient: verified on
# Debian with util-linux script 2.38.1 that the pty puts the service in its own
# session, so the pane's SIGHUP never reaches it and both the pty and the service
# keep running and holding the port. The registry therefore records the service's
# process-group leader, and reaping kills that group.
REG_KILL="$HOME_DIR/state/killproc.api-tabs"
wapi_tmux FM_WORKER_API_LOGDIR="$LOGDIR" \
  "$WAPI" up --registry "$REG_KILL" --port 8889 -- python3 -m http.server 8889 >/dev/null 2>&1 \
  || fail "up failed for the process-kill case"
KILL_PID=$(cut -f6 "$REG_KILL")
[ -n "$KILL_PID" ] || fail "up must record the service pid as the registry's sixth field"
case "$KILL_PID" in ''|*[!0-9]*) fail "recorded pid is not numeric: '$KILL_PID'" ;; esac
kill -0 "$KILL_PID" 2>/dev/null || fail "the recorded pid $KILL_PID is not a live process"
wapi_tmux FM_WORKER_API_LOGDIR="$LOGDIR" "$WAPI" down --registry "$REG_KILL" >/dev/null 2>&1 \
  || fail "down failed for the process-kill case"
proc_gone=0
for _ in 1 2 3 4 5 6 7 8; do
  kill -0 "$KILL_PID" 2>/dev/null || { proc_gone=1; break; }
  sleep 1
done
[ "$proc_gone" = 1 ] || fail "down closed the tab but left the service process $KILL_PID alive (the orphan bug)"
pass "real tmux: down stops the service PROCESS, not just its tab"

# --- an IPv6-only listener is not mistaken for a free port -------------------
# port_is_free probed only 127.0.0.1, so a service bound solely to ::1 read as
# free. That defeats both guarantees built on the probe: the pinned-port refusal
# never fires, and readiness can never observe an IPv6-only service.
if python3 -c "
import socket,sys
s=socket.socket(socket.AF_INET6)
try: s.bind(('::1',8878)); s.close()
except Exception: sys.exit(1)
" 2>/dev/null; then
  python3 -m http.server 8878 --bind ::1 >/dev/null 2>&1 &
  V6_PID=$!
  sleep 2
  REG_V6="$HOME_DIR/state/v6.api-tabs"
  v6_rc=0
  v6_out=$(wapi_tmux FM_WORKER_API_LOGDIR="$LOGDIR" \
    "$WAPI" up --registry "$REG_V6" --port 8878 -- python3 -m http.server 8878 2>&1) || v6_rc=$?
  kill "$V6_PID" 2>/dev/null || true
  [ "$v6_rc" -ne 0 ] || fail "up must refuse a port held by an IPv6-only listener, got:"$'\n'"$v6_out"
  assert_contains "$v6_out" "already in use" "the refusal should name the port conflict"
  assert_absent "$REG_V6" "a refused up must not register anything"
  pass "real tmux: a port held only on ::1 is seen as taken, not free"
else
  echo "skip: cannot bind ::1 - skipping the IPv6 port-probe check"
fi

# --- a stale exit marker cannot kill a healthy launch ------------------------
# Two runs of the same label inside one second share a log filename, and `tee -a`
# appends. If readiness grepped the whole file, the PREVIOUS run's exit marker
# would read as this run's failure - and the failure path now closes the tab and
# unregisters, so a stale match would actively kill a working service.
REG_STAMP="$HOME_DIR/state/stamp.api-tabs"
mkdir -p "$LOGDIR"
# Seed a stale-marker log for every second `up` could stamp, so the collision is
# deterministic rather than a race against the clock.
for _stamp in $(perl -e 'use POSIX; print strftime("%Y-%m-%d-%H%M%S", localtime(time()+$_)), "\n" for 0..20'); do
  printf 'old run output\n[fm-worker-api] service exited rc=1\n' > "$LOGDIR/stamp-api-$_stamp.log"
done
stamp_out=$(wapi_tmux FM_WORKER_API_LOGDIR="$LOGDIR" \
  "$WAPI" up --registry "$REG_STAMP" --port 8886 -- python3 -m http.server 8886 2>&1) \
  || fail "up must not treat a prior run's exit marker as its own failure:"$'\n'"$stamp_out"
assert_contains "$stamp_out" "http://127.0.0.1:8886" "the healthy service should come up despite a stale marker in an older log"
wapi_tmux FM_WORKER_API_LOGDIR="$LOGDIR" "$WAPI" down --registry "$REG_STAMP" --all >/dev/null 2>&1 || true
pass "real tmux: a previous run's exit marker in a shared log does not fail a healthy launch"

# --- a port another task has claimed is refused ------------------------------
# A socket probe cannot see a port claimed by a worker whose service has not bound
# yet, so the registries in the state dir are consulted as the durable claim record.
REG_CLAIM_A="$HOME_DIR/state/claimer.api-tabs"
REG_CLAIM_B="$HOME_DIR/state/claimee.api-tabs"
printf 'api\ttmux\tfirstmate:@900\t8887\t%s\n' "$LOGDIR/claim.log" > "$REG_CLAIM_A"
# Only a LIVE task's claim counts, so the claimer needs a meta.
fm_write_meta "$HOME_DIR/state/claimer.meta" "window=firstmate:@900" "backend=tmux" "kind=ship"
claim_rc=0
claim_out=$(wapi_tmux FM_WORKER_API_LOGDIR="$LOGDIR" \
  "$WAPI" up --registry "$REG_CLAIM_B" --port 8887 -- python3 -m http.server 8887 2>&1) || claim_rc=$?
[ "$claim_rc" -ne 0 ] || fail "up must refuse a port another task's registry already claims, got:"$'\n'"$claim_out"
assert_contains "$claim_out" "already claimed" "the refusal should say the port is claimed by another task"
assert_absent "$REG_CLAIM_B" "a refused up must not register anything"
# An ORPHANED task's claim must not reserve a port indefinitely: with the meta
# gone, the same port is available again (its registry is waiting for `sweep`).
rm -f "$HOME_DIR/state/claimer.meta"
orphan_claim_out=$(wapi_tmux FM_WORKER_API_LOGDIR="$LOGDIR" \
  "$WAPI" up --registry "$REG_CLAIM_B" --port 8887 -- python3 -m http.server 8887 2>&1) \
  || fail "an orphaned task's claim must not block the port, got:"$'\n'"$orphan_claim_out"
assert_contains "$orphan_claim_out" "http://127.0.0.1:8887" "the port should be usable once the claiming task is gone"
wapi_tmux FM_WORKER_API_LOGDIR="$LOGDIR" "$WAPI" down --registry "$REG_CLAIM_B" --all >/dev/null 2>&1 || true
rm -f "$REG_CLAIM_A"
pass "real tmux: up refuses a live task's port claim but not an orphaned task's"

# --- a provably dead service does not block the worker's one slot ------------
# The one-service-per-worker refusal used to be liveness-blind, so a crashed
# service blocked every later up until someone ran `down` by hand.
REG_STALE="$HOME_DIR/state/stale.api-tabs"
printf 'api\ttmux\tfirstmate:@999\t8892\t%s\n' "$LOGDIR/stale-marker.log" > "$REG_STALE"
mkdir -p "$LOGDIR"
echo "[fm-worker-api] service exited rc=1" > "$LOGDIR/stale-marker.log"
stale_out=$(wapi_tmux FM_WORKER_API_LOGDIR="$LOGDIR" \
  "$WAPI" up --registry "$REG_STALE" --label fresh --port 8893 -- python3 -m http.server 8893 2>&1) \
  || fail "up should proceed once the dead service is cleared, got:"$'\n'"$stale_out"
assert_contains "$stale_out" "cleared stale service" "up should say it cleared the dead entry"
assert_contains "$stale_out" "http://127.0.0.1:8893" "up should then start the new service"
assert_grep "fresh" "$REG_STALE" "the new label should be registered"
wapi_tmux FM_WORKER_API_LOGDIR="$LOGDIR" "$WAPI" down --registry "$REG_STALE" --all >/dev/null 2>&1 || true
pass "real tmux: a provably dead registered service is cleared instead of blocking a new up"


# --- sweep closes a real orphaned service window -----------------------------
# The recovery-side backstop: a task that never reaches teardown (crash, lost
# meta, --force discard) leaves a live tab nothing else will ever close.
SWEEPID=sweepme
SWEEPREG="$HOME_DIR/state/$SWEEPID.api-tabs"
sweep_up=$(wapi_tmux FM_WORKER_API_REGISTRY="$SWEEPREG" FM_WORKER_API_LOGDIR="$LOGDIR" \
  "$WAPI" up --port 8897 -- python3 -m http.server 8897) \
  || fail "up failed for the sweep case"$'\n'"$sweep_up"
"$REAL_TMUX" -L "$SOCKET" list-windows -t firstmate -F '#{window_name}' | grep -qx "fm-$SWEEPID-api" \
  || fail "precondition: the sweep task's service window should exist"
# No state/<id>.meta was ever written, so the task is gone as far as firstmate knows.
sweep_out=$(wapi_tmux "$WAPI" sweep --state "$HOME_DIR/state" 2>&1) || fail "sweep exited non-zero"
assert_contains "$sweep_out" "$SWEEPID" "sweep should name the orphaned task"
sleep 1
if "$REAL_TMUX" -L "$SOCKET" list-windows -t firstmate -F '#{window_name}' 2>/dev/null | grep -qx "fm-$SWEEPID-api"; then
  fail "sweep did not close the orphaned service window"
fi
assert_absent "$SWEEPREG" "sweep should remove the orphaned registry"
pass "real tmux: sweep closes an orphaned task's service window and clears its registry"

tmux_cleanup
trap - EXIT
exit 0
