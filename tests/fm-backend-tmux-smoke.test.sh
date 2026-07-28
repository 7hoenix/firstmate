#!/usr/bin/env bash
# tests/fm-backend-tmux-smoke.test.sh - real tmux smoke test for the tmux
# session-provider adapter (bin/backends/tmux.sh), the P1 checklist item
# "run a real tmux smoke test (create session, send text + Enter, capture,
# list, kill)" from data/fm-backend-design-d7/report.md. Every other suite in
# this repo fakes tmux; this one is the one place that talks to a REAL tmux
# server, isolated on a private socket (`-L`) so it never touches the host's
# actual sessions.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || { echo "skip: tmux not found"; exit 0; }
REAL_TMUX=$(command -v tmux)
SOCKET="fm-backend-smoke-$$"
SHIM_DIR=
trap cleanup_all EXIT

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${SHIM_DIR:-}" ] && rm -rf "$SHIM_DIR"
}

# A `tmux` shim on PATH that transparently redirects every call to the private
# socket, so bin/backends/tmux.sh's bare `tmux ...` invocations never touch the
# host's real sessions.
SHIM_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-backend-smoke.XXXXXX")
cat > "$SHIM_DIR/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$SHIM_DIR/tmux"
PATH="$SHIM_DIR:$PATH"
export PATH

# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

SESSION="smoke"
WINDOW="fm-smoke1"
TARGET="$SESSION:$WINDOW"

# --- create session ----------------------------------------------------------

tmux new-session -d -s "$SESSION" -x 200 -y 50 \
  || fail "real tmux: new-session failed"
fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" \
  || fail "fm_backend_tmux_create_task failed to create the task window"
tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "$WINDOW" \
  || fail "created window is not visible in the real session"

# A second create for the SAME window name must refuse (mirrors fm-spawn.sh's
# duplicate-window guard).
if fm_backend_tmux_create_task "$SESSION" "$WINDOW" "$HOME" 2>/dev/null; then
  fail "fm_backend_tmux_create_task should refuse an existing window name"
fi
pass "real tmux: fm_backend_tmux_create_task creates a window and refuses a duplicate"

# --- send text + Enter -------------------------------------------------------

tmux send-keys -t "$TARGET" "cd /tmp && PS1='smoke\$ '" Enter
sleep 0.3
tmux send-keys -t "$TARGET" -l "clear" ; tmux send-keys -t "$TARGET" Enter
sleep 0.3

fm_backend_tmux_send_text_line "$TARGET" "echo captain-on-deck-line" \
  || fail "fm_backend_tmux_send_text_line failed"
sleep 0.5
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_text_line"
case "$out" in
  *captain-on-deck-line*) : ;;
  *) fail "real tmux: fm_backend_tmux_send_text_line did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_text_line sends literal text and submits with Enter"

# --- send_literal + send_key(Enter), the two-step form fm-spawn.sh uses for the
# harness launch command (literal send, settle, then a separate Enter) --------

fm_backend_tmux_send_literal "$TARGET" 'echo literal-then-key-captain' \
  || fail "fm_backend_tmux_send_literal failed"
sleep 0.2
fm_backend_tmux_send_key "$TARGET" Enter || fail "fm_backend_tmux_send_key Enter failed"
sleep 0.5
out=$(fm_backend_tmux_capture "$TARGET" 20) || fail "fm_backend_tmux_capture failed after send_literal+send_key"
case "$out" in
  *literal-then-key-captain*) : ;;
  *) fail "real tmux: send_literal + send_key(Enter) did not submit and echo the line"$'\n'"$out" ;;
esac
pass "real tmux: fm_backend_tmux_send_literal + fm_backend_tmux_send_key Enter submit as two separate steps"

# --- capture bounds -----------------------------------------------------------
# Print enough numbered lines to overflow the pane's visible height, then
# confirm a small capture window (-S -N) surfaces only the RECENT tail (the
# earliest lines scroll out of a small window) while a large one reaches back
# far enough to still see the earliest line - the same -S -N bounding fm-peek.sh
# and fm-watch.sh rely on for a bounded, cheap pane read.
fm_backend_tmux_send_text_line "$TARGET" "for i in \$(seq 1 80); do echo tag-line-\$i; done"
sleep 0.6
small=$(fm_backend_tmux_capture "$TARGET" 3) || fail "fm_backend_tmux_capture (small window) failed"
case "$small" in
  *tag-line-1$'\n'*) fail "a 3-line capture should not still see the very first numbered line"$'\n'"$small" ;;
esac
case "$small" in
  *tag-line-80*) : ;;
  *) fail "a 3-line capture should still contain the most recent output"$'\n'"$small" ;;
esac
large=$(fm_backend_tmux_capture "$TARGET" 200) || fail "fm_backend_tmux_capture (large window) failed"
case "$large" in
  *tag-line-1$'\n'*) : ;;
  *) fail "a 200-line capture should reach back far enough to see the first numbered line"$'\n'"$large" ;;
esac
pass "real tmux: fm_backend_tmux_capture's -S -N bound trims old history for a small window and reaches it for a large one"

# --- resolve_bare_selector (live-window-listing) -----------------------------

resolved=$(fm_backend_tmux_resolve_bare_selector "$WINDOW") \
  || fail "fm_backend_tmux_resolve_bare_selector failed to find the live window"
[ "$resolved" = "$TARGET" ] || fail "fm_backend_tmux_resolve_bare_selector resolved to '$resolved', expected '$TARGET'"
pass "real tmux: fm_backend_tmux_resolve_bare_selector (list-live) finds the created window by name"

if fm_backend_tmux_resolve_bare_selector "no-such-window-xyz" 2>/dev/null; then
  fail "fm_backend_tmux_resolve_bare_selector should fail for a nonexistent window"
fi
pass "real tmux: fm_backend_tmux_resolve_bare_selector fails for a window that does not exist"

# --- kill ---------------------------------------------------------------------

fm_backend_tmux_kill "$TARGET"
if tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "$WINDOW"; then
  fail "fm_backend_tmux_kill did not remove the window"
fi
# Best-effort contract: killing an already-gone window must not error.
fm_backend_tmux_kill "$TARGET" || fail "fm_backend_tmux_kill on an already-dead target must stay best-effort (never fail)"
pass "real tmux: fm_backend_tmux_kill removes the window and is idempotent/best-effort"

# --- sibling_up / sibling_down (bin/fm-worker-api.sh's on-demand service tab) --
# A separate labeled window next to a worker, launching a command, then reaped.
SIB=$(fm_backend_tmux_sibling_up "$SESSION" "fm-smoke1-api" "$HOME" "echo sibling-up-ok") \
  || fail "fm_backend_tmux_sibling_up failed"
case "$SIB" in "$SESSION":*) : ;; *) fail "sibling_up should print a session:window_id endpoint, got '$SIB'" ;; esac
tmux list-windows -t "$SESSION" -F '#{window_name}' | grep -qx "fm-smoke1-api" \
  || fail "sibling_up did not create the labeled service window"
sleep 0.3
sib_out=$(fm_backend_tmux_capture "$SIB" 20) || fail "capture of the sibling window failed"
case "$sib_out" in
  *sibling-up-ok*) : ;;
  *) fail "sibling_up did not run the launch command"$'\n'"$sib_out" ;;
esac
fm_backend_tmux_sibling_down "$SIB"
if tmux list-windows -t "$SESSION" -F '#{window_name}' 2>/dev/null | grep -qx "fm-smoke1-api"; then
  fail "sibling_down did not close the service window"
fi
fm_backend_tmux_sibling_down "$SIB" || fail "sibling_down on an already-gone window must stay best-effort"
pass "real tmux: sibling_up opens a labeled service window and runs the command; sibling_down closes it (best-effort)"

# --- sibling_alive (the existence probe that can actually say "gone") ---------
# Regression guard for the reason this exists at all: `tmux display-message -t
# <killed or nonexistent window>` EXITS 0 and prints the session's current pane,
# so fm_backend_target_exists can never report a tmux window as gone. Anything
# built on it (clearing a dead service so it stops blocking a worker's one slot)
# silently never fires. sibling_alive enumerates real window ids instead.
SIB2=$(fm_backend_tmux_sibling_up "$SESSION" "fm-smoke1-alive" "$HOME" "sleep 60") \
  || fail "sibling_up failed for the liveness case"
fm_backend_tmux_sibling_alive "$SIB2" \
  || fail "sibling_alive should report a live service window as alive (0)"
# The primitive it replaces reports this same live window as alive too - that is
# not the interesting half.
fm_backend_tmux_sibling_down "$SIB2"
sleep 0.3
fm_backend_tmux_sibling_alive "$SIB2" && alive_rc=0 || alive_rc=$?
[ "$alive_rc" = 1 ] \
  || fail "sibling_alive must report a killed window as CONFIDENTLY gone (1), got $alive_rc"
fm_backend_tmux_sibling_alive "$SESSION:@99999" && ghost_rc=0 || ghost_rc=$?
[ "$ghost_rc" = 1 ] || fail "sibling_alive must report a never-existed window as gone (1), got $ghost_rc"
if tmux display-message -p -t "$SIB2" '#{pane_id}' >/dev/null 2>&1; then
  pass "real tmux: sibling_alive reports a killed window as gone, where display-message still reports success"
else
  pass "real tmux: sibling_alive reports a killed window as gone"
fi
fm_backend_tmux_sibling_alive "no-such-session-$$:@1" && miss_rc=0 || miss_rc=$?
[ "$miss_rc" = 2 ] \
  || fail "sibling_alive must report an unreadable session as UNKNOWN (2), never as gone, got $miss_rc"
pass "real tmux: sibling_alive reports an unreadable session as unknown rather than gone"

cleanup_all
trap - EXIT
