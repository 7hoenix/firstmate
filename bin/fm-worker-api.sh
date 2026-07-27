#!/usr/bin/env bash
# fm-worker-api.sh - stand up a worker's on-demand service (an API, a dev server,
# a mock backend) in a VISIBLE, named sibling tab in the worker's OWN terminal
# container, instead of hiding it in a sub-agent or a background process.
#
# Why: a review/E2E crewmate often needs a long-lived service (e.g. `wrangler
# dev`) running while it works. A sub-agent is meant to do a task and return, not
# host a server; a background `&` is invisible to the captain and to firstmate.
# This helper opens the service in a tab the captain can watch and hop into, and
# registers it so teardown reaps it (no orphaned tabs or processes). Design +
# empirical basis: data/worker-api-tab-4d/rfc.md and .../report.md; docs/worker-api.md.
#
# The worker runs ONE clean command and never touches raw herdr/tmux:
#   fm-worker-api.sh up   [--label <suffix>] [--port <n>] [--] <launch command...>
#   fm-worker-api.sh down [--label <suffix>] [--all]
#   fm-worker-api.sh restart [--label <suffix>] [--port <n>] [--] <launch command...>
#   fm-worker-api.sh status [--all]
#   fm-worker-api.sh logs [--label <suffix>] [--follow]
#   fm-worker-api.sh logs --prune-before <YYYY-MM-DD>
#   fm-worker-api.sh sweep [--state <dir>] [--dry-run]     (firstmate, not the worker)
#
# Backend-agnostic. Self-locates its own container from the environment the
# backend injects into every pane - herdr's HERDR_WORKSPACE_ID/HERDR_SESSION, or
# tmux's $TMUX plus `display-message` - so it needs nothing from firstmate. v1
# supports tmux and herdr; any other backend refuses `up` with a clear message.
#
# Contracts owned here (one owner):
#   - Service tab label:  fm-<id>-<suffix>  (default suffix "api").
#   - Reap registry:      one TAB-separated line per live service in
#                         $FM_WORKER_API_REGISTRY:
#                             <label>\t<backend>\t<endpoint>\t<port>\t<logfile>
#                         Written on `up`, line removed on `down`. fm-teardown.sh
#                         reads it, closes each endpoint, and deletes the registry
#                         file - but KEEPS the log (see below).
#   - Port:               deterministic candidate from the worktree path, then the
#                         first free port at/above it, printed so it is targetable.
#                         --port pins an explicit value and REFUSES a port that is
#                         already in use, so "the port started accepting" stays a
#                         truthful readiness signal for the service we launched.
#                         Selection through BIND is serialized by a machine-wide
#                         lock so concurrent `up`s cannot race onto the same port.
#   - Logs (collected, not deleted): the service's stdout+stderr is teed to a
#                         dated file under $FM_WORKER_API_LOGDIR
#                         (<id>-<label>-<YYYY-MM-DD-HHMMSS>.log) that SURVIVES
#                         teardown. Bulk-pruned later via `logs --prune-before`.
#                         The service is run line-buffered under a `script` pty
#                         (stdbuf only as a no-`script` fallback; it does NOT work
#                         for every runtime) so a startup banner reaches the log
#                         before the process is killed, and the launch line appends an
#                         "[fm-worker-api] service exited rc=<n>" marker when the
#                         command returns, which `up` watches to fail fast.
#   - Orphan sweep:       `sweep` closes service tabs whose task is gone (no
#                         state/<id>.meta), the recovery-side backstop for tasks
#                         that never reached teardown. bin/fm-bootstrap.sh runs it.
#
# $FM_WORKER_API_REGISTRY and $FM_WORKER_API_LOGDIR are exported into the worker's
# pane by bin/fm-spawn.sh (like GOTMPDIR). --registry/--logdir override them for
# manual use and tests. v1 hosts ONE service per worker (a second `up` with a new
# label refuses, unless the registered one is provably dead, which is cleared
# first); the registry is label-keyed so growing to several later is additive.
set -u

PORT_BASE=${FM_WORKER_API_PORT_BASE:-8800}
PORT_RANGE=${FM_WORKER_API_PORT_RANGE:-200}
READY_TIMEOUT=${FM_WORKER_API_READY_TIMEOUT:-20}
PORT_LOCK=${FM_WORKER_API_PORT_LOCK:-${TMPDIR:-/tmp}/fm-worker-api-port.lock}
PORT_LOCK_WAIT=${FM_WORKER_API_PORT_LOCK_WAIT:-30}

# Appended by the launch line when the service command returns, so `up` can tell
# "still starting" from "already exited" on every backend without polling panes.
EXIT_MARKER='[fm-worker-api] service exited rc='

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

err() { echo "fm-worker-api: $*" >&2; }
die() { err "$*"; exit 1; }
require_val() { [ "$#" -ge 2 ] || die "$1 needs a value"; }

# Print the leading comment block (everything between the shebang and the first
# line of code), so the usage text cannot drift out of a hardcoded line range.
usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }

# --- registry / log location -------------------------------------------------

REGISTRY=${FM_WORKER_API_REGISTRY:-}
LOGDIR=${FM_WORKER_API_LOGDIR:-}
STATE_DIR=

resolve_paths() {
  [ -n "$REGISTRY" ] || die "no registry path: set FM_WORKER_API_REGISTRY (exported by fm-spawn) or pass --registry"
  case "$REGISTRY" in
    */*) : ;;
    *) die "registry path must be absolute or contain a directory: $REGISTRY" ;;
  esac
  local home_dir
  STATE_DIR=$(dirname "$REGISTRY")
  home_dir=$(dirname "$STATE_DIR")
  ID=$(basename "$REGISTRY")
  ID=${ID%.api-tabs}
  [ -n "$ID" ] || die "cannot derive task id from registry path $REGISTRY"
  [ -n "$LOGDIR" ] || LOGDIR="$home_dir/data/api-logs"
  mkdir -p "$STATE_DIR" || die "cannot create registry dir $STATE_DIR"
}

# --- self-location -----------------------------------------------------------
#
# Reads the backend-injected pane environment. herdr sets HERDR_ENV=1 plus the
# pane-specific HERDR_WORKSPACE_ID (and HERDR_SESSION in a named session, absent
# in the default one -> "default"); tmux sets $TMUX and answers display-message.

detect_backend_container() {
  if [ -n "${TMUX:-}" ]; then
    BACKEND=tmux
    CONTAINER=$(tmux display-message -p '#{session_name}' 2>/dev/null) \
      || die "tmux display-message failed; cannot self-locate the container"
    [ -n "$CONTAINER" ] || die "tmux reported an empty session name"
  elif [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_WORKSPACE_ID:-}" ]; then
    BACKEND=herdr
    CONTAINER="${HERDR_SESSION:-default}:$HERDR_WORKSPACE_ID"
  else
    die "unsupported backend: on-demand service tabs need tmux or herdr (v1). No HERDR_ENV/HERDR_WORKSPACE_ID or \$TMUX in this pane."
  fi
}

# --- port selection ----------------------------------------------------------

port_is_free() {  # <port>  -> 0 when nothing is listening (connect refused)
  local p=$1
  ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null
}

# Port selection through BIND is one critical section: without it two concurrent
# `up`s (different workers, even different repos on this machine) can both see the
# same port free and both launch onto it. The section must stay held until the
# service has actually bound, not merely until it is registered - releasing at
# registration leaves exactly the window where the second worker sees the port
# still free and the first worker's readiness check then reads the SECOND
# service's listener as its own success.
#
# mkdir is the atomic primitive. The lock carries an owner token so a holder that
# was declared stale and superseded cannot later delete its successor's lock. A
# lock older than a minute is treated as abandoned; that is deliberate recovery
# for a killed holder, so it can still cut short a genuinely slow launch. This is
# same-user best-effort coordination between cooperating workers, not a secure
# mutex. Failing to take the lock never blocks a launch - it only forfeits the
# race protection.
PORT_LOCK_HELD=0
PORT_LOCK_TOKEN=

port_lock_acquire() {
  local waited=0 token dir
  # An uncreatable lock path can never yield to waiting: mkdir fails for a reason
  # that is not contention, and the stale-break finds nothing to break, so the
  # whole wait would burn before launching. Fail out of the lock immediately and
  # say what is actually wrong instead of reporting it as "still held".
  dir=$(dirname "$PORT_LOCK")
  if [ ! -d "$dir" ] || [ ! -w "$dir" ]; then
    err "port lock dir $dir is missing or not writable; continuing without the port lock"
    return 1
  fi
  token="$$-$(date +%s)-${RANDOM:-0}"
  while ! mkdir "$PORT_LOCK" 2>/dev/null; do
    if [ -n "$(find "$PORT_LOCK" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      rm -f "$PORT_LOCK/owner" 2>/dev/null || true
      # Only retry immediately when the stale lock was ACTUALLY removed. If it
      # cannot be (it is a regular file, a non-empty directory, or another user's
      # lock in a shared /tmp), retrying without sleeping never increments the
      # wait and spins forever at full CPU. Fall through to the bounded wait
      # instead, so a launch is delayed at worst, never hung.
      if rmdir "$PORT_LOCK" 2>/dev/null; then
        continue
      fi
    fi
    if [ "$waited" -ge "$PORT_LOCK_WAIT" ]; then
      err "port lock $PORT_LOCK could not be taken after ${PORT_LOCK_WAIT}s; continuing without it"
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  PORT_LOCK_TOKEN=$token
  printf '%s\n' "$token" > "$PORT_LOCK/owner" 2>/dev/null || true
  PORT_LOCK_HELD=1
  return 0
}

port_lock_release() {
  [ "$PORT_LOCK_HELD" = 1 ] || return 0
  PORT_LOCK_HELD=0
  # Only tear down a lock we still own. If we were declared stale and another
  # process took the lock, removing it here would free a lock that is genuinely
  # held and let a third `up` in. An ABSENT owner file still counts as ours: the
  # write is best-effort, and refusing to release then would leak the lock until
  # the stale break, stalling every concurrent `up` for a full minute.
  local owner
  owner=$(cat "$PORT_LOCK/owner" 2>/dev/null || true)
  [ -z "$owner" ] || [ "$owner" = "$PORT_LOCK_TOKEN" ] || return 0
  rm -f "$PORT_LOCK/owner" 2>/dev/null || true
  rmdir "$PORT_LOCK" 2>/dev/null || true
}

trap port_lock_release EXIT

# A live socket probe alone cannot see a port that another worker has claimed but
# whose service has not bound yet - the gap the port lock cannot cover once a slow
# service outlasts the readiness wait. The registries in this state dir are the
# durable record of those claims, so consult them too.
port_is_claimed() {  # <port> -> 0 when another LIVE task's registry already records it
  local p=$1 reg id
  [ -n "$STATE_DIR" ] || return 1
  for reg in "$STATE_DIR"/*.api-tabs; do
    [ -e "$reg" ] || continue
    [ "$reg" = "$REGISTRY" ] && continue
    # Ignore an orphaned task's claim. Its registry is waiting for `sweep`, and
    # honoring it would refuse this port until the next session start - a dead
    # task must not be able to reserve a port indefinitely.
    id=$(basename "$reg"); id=${id%.api-tabs}
    [ -f "$STATE_DIR/$id.meta" ] || continue
    cut -f4 "$reg" 2>/dev/null | grep -qx -- "$p" && return 0
  done
  return 1
}

derive_port() {  # <seed-string> -> first free port at/above a deterministic candidate
  local seed=$1 n i p
  n=$(printf '%s' "$seed" | cksum | awk '{print $1}')
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  for ((i = 0; i < PORT_RANGE; i++)); do
    p=$(( PORT_BASE + ( (n + i) % PORT_RANGE ) ))
    if port_is_free "$p" && ! port_is_claimed "$p"; then
      printf '%s' "$p"
      return 0
    fi
  done
  return 1
}

worktree_seed() {
  git rev-parse --show-toplevel 2>/dev/null || pwd -P
}

# --- registry helpers --------------------------------------------------------

registry_line_for_label() {  # <label>  -- matches field 1 as a literal, not a regex
  [ -f "$REGISTRY" ] || return 1
  awk -F'\t' -v l="$1" '$1==l {print; f=1; exit} END{exit !f}' "$REGISTRY" 2>/dev/null
}

registry_remove_label() {  # <label>  -- matches field 1 as a literal, not a regex
  [ -f "$REGISTRY" ] || return 0
  local tmp
  tmp="$REGISTRY.tmp.$$"
  if awk -F'\t' -v l="$1" '$1!=l' "$REGISTRY" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$REGISTRY"
  else
    rm -f "$tmp"
    err "could not rewrite $REGISTRY; left it unchanged"
  fi
}

registry_labels() {
  [ -f "$REGISTRY" ] || return 0
  cut -f1 "$REGISTRY" 2>/dev/null
}

# A registered service is provably dead when nothing is listening on its port AND
# either its tab is gone or its log records the command's exit. "Port free" alone
# is not enough: a service that is still starting up also has a free port, and
# clearing it would reap a healthy launch.
service_is_dead() {  # <backend> <endpoint> <port> <logfile>
  local b=$1 endpoint=$2 port=$3 logfile=$4 alive=2
  [ -n "$port" ] || return 0
  port_is_free "$port" || return 1
  if [ -n "$endpoint" ]; then
    fm_backend_sibling_alive "$b" "$endpoint" >/dev/null 2>&1 && alive=0 || alive=$?
    # Only a CONFIDENT "gone" counts. An unreadable server (2) must never be read
    # as a dead service, or a transient backend hiccup would reap live work.
    [ "$alive" = 1 ] && return 0
  fi
  [ -n "$logfile" ] && [ -f "$logfile" ] && grep -Fq "$EXIT_MARKER" "$logfile" 2>/dev/null
}

# Clear registry entries whose service is provably dead, closing any tab it left
# behind. Without this a crashed service blocks the worker's one `up` slot.
clear_dead_registry_entries() {
  [ -s "$REGISTRY" ] || return 0
  local label b endpoint port logfile cleared=0
  while IFS=$'\t' read -r label b endpoint port logfile; do
    [ -n "$label" ] || continue
    if service_is_dead "$b" "$endpoint" "$port" "$logfile"; then
      [ -z "$endpoint" ] || fm_backend_sibling_down "$b" "$endpoint" </dev/null 2>/dev/null || true
      registry_remove_label "$label"
      echo "cleared stale service '$label' (no longer serving on :$port; log kept)"
      cleared=1
    fi
  done < "$REGISTRY"
  [ "$cleared" = 1 ]
}

# --- launch line -------------------------------------------------------------

# Build the shell line the service tab runs. Three jobs beyond running the
# command: export PORT, tee the output to the dated log, and append an exit
# marker when the command returns.
#
# Line buffering matters: a service's stdout is fully buffered when it is a pipe,
# so a startup banner sits unflushed in the process's own buffer and is LOST when
# teardown kills it - the log then misses the very line firstmate would grep for
# readiness.
#
# A `script` pty is the fix that actually works. Measured on macOS 2026-07-27 with
# `python3 -m http.server`, killed after 2s (docs/worker-api.md "Verified"):
#   plain pipe            -> log empty, banner lost
#   stdbuf -oL -eL        -> log empty, banner lost
#   script -q /dev/null   -> banner present
# stdbuf fails here for two independent reasons: it works by overriding libc
# stdio, which Python's own io layer does not use, and macOS SIP strips the
# injection for system binaries anyway. A pty makes stdout a terminal, which every
# runtime line-buffers, so it is runtime-agnostic. stdbuf is kept only as a
# fallback for the (rare) system with no `script`.
#
# The pty path writes CR line endings into the log; that is the accepted cost of
# not losing the output entirely.
#
# Flavor probe: util-linux `script` wants `-c <cmd> <file>`, BSD/macOS wants
# `<file> <cmd...>`. Each form is probed by actually RUNNING it on `true`, which
# is safe on either flavor (the wrong form exits non-zero immediately) - unlike
# `script --version`, which BSD would read as a typescript FILENAME and hang on
# an interactive session. Probing for real success rather than just flavor also
# means a `script` that exists but cannot work here (no pty available in a
# container, for instance) falls through to stdbuf or a plain pipeline instead of
# making every launch fail.
#
# util-linux needs `-e` to return the child's exit status; without it the marker
# would report rc=0 for every failed command. It is probed with `-e` first so an
# older build without that flag still resolves.
build_launch_line() {  # <port> <logfile> -> prints the shell line
  local port=$1 logfile=$2 inner qinner wrapped=
  inner="export PORT=$port; $(printf '%s ' "${UP_CMD[@]}")"
  qinner=$(printf '%q' "$inner")
  if command -v script >/dev/null 2>&1; then
    if script -q -e -c true /dev/null </dev/null >/dev/null 2>&1; then
      wrapped="script -q -e -c $(printf '%q' "bash -c $qinner") /dev/null"
    elif script -q -c true /dev/null </dev/null >/dev/null 2>&1; then
      wrapped="script -q -c $(printf '%q' "bash -c $qinner") /dev/null"
    elif script -q /dev/null true </dev/null >/dev/null 2>&1; then
      wrapped="script -q /dev/null bash -c $qinner"
    fi
  fi
  if [ -z "$wrapped" ]; then
    if command -v stdbuf >/dev/null 2>&1; then
      wrapped="stdbuf -oL -eL bash -c $qinner"
    else
      wrapped="bash -c $qinner"
    fi
  fi
  printf '{ %s; echo "%s$?"; } 2>&1 | tee -a %s\n' \
    "$wrapped" "$EXIT_MARKER" "$(printf '%q' "$logfile")"
}

# Only the bytes THIS run appended, so a previous run's output in a shared log
# file (same label, same second) can never be read as this run's result.
run_log_tail() {  # <logfile> <byte-offset>
  [ -f "$1" ] || return 0
  tail -c "+$(( $2 + 1 ))" "$1" 2>/dev/null
}

run_log_has_exit_marker() {  # <logfile> <byte-offset>
  run_log_tail "$1" "$2" | grep -Fq "$EXIT_MARKER"
}

# --- commands ----------------------------------------------------------------

cmd_up() {  # <restart 0|1>
  local restart=${1:-0} label port pinned=0
  label=$UP_LABEL
  port=$UP_PORT
  [ -z "$port" ] || pinned=1
  [ "${#UP_CMD[@]}" -gt 0 ] || die "up needs a launch command, e.g. up -- wrangler dev"

  resolve_paths
  detect_backend_container

  local full_label="fm-$ID-$label"

  # v1: one service per worker. A same-label up is a restart; a different-label
  # up while one is live refuses - but only if that one is actually still alive.
  if [ -f "$REGISTRY" ]; then
    local existing
    existing=$(registry_labels)
    if printf '%s\n' "$existing" | grep -Fqx -- "$label"; then
      [ "$restart" = 1 ] || restart=1  # same label -> replace
    elif [ -n "$existing" ]; then
      clear_dead_registry_entries || true
      existing=$(registry_labels)
      if [ -n "$existing" ] && ! printf '%s\n' "$existing" | grep -Fqx -- "$label"; then
        die "a service is already up for this worker (label(s): $(printf '%s' "$existing" | tr '\n' ' ')); v1 hosts one per worker - 'down' it first"
      fi
    fi
  fi

  # Reuse the recorded port on a same-label restart unless --port overrides.
  if [ "$restart" = 1 ] && [ -z "$port" ]; then
    local prior
    prior=$(registry_line_for_label "$label" || true)
    [ -z "$prior" ] || port=$(printf '%s' "$prior" | cut -f4)
  fi
  # Close a prior same-label service before relaunching.
  if [ "$restart" = 1 ]; then
    local prior endpoint b reused_port
    prior=$(registry_line_for_label "$label" || true)
    if [ -n "$prior" ]; then
      b=$(printf '%s' "$prior" | cut -f2)
      endpoint=$(printf '%s' "$prior" | cut -f3)
      reused_port=$(printf '%s' "$prior" | cut -f4)
      [ -z "$endpoint" ] || fm_backend_sibling_down "$b" "$endpoint" </dev/null 2>/dev/null || true
      registry_remove_label "$label"
      # The tab is killed asynchronously; when we reuse its port, wait briefly for
      # the old listener to release the socket so the relaunch binds deterministically.
      if [ -n "$reused_port" ] && [ "$reused_port" = "$port" ]; then
        local freed=0
        for _ in 1 2 3 4 5; do
          if port_is_free "$port"; then freed=1; break; fi
          sleep 1
        done
        # A service with a slow shutdown (draining connections, a forked child
        # still holding the socket) must not turn a restart into a hard failure:
        # the old entry is already unregistered by this point, so refusing would
        # leave the worker with nothing. Fall back to a freshly derived port,
        # which is printed like any other. An explicitly pinned --port is the
        # caller's decision and still refuses below.
        if [ "$freed" != 1 ] && [ "$pinned" != 1 ]; then
          err "port $port still busy after 5s; picking a fresh port for this restart"
          port=
        fi
      fi
    fi
  fi

  # Hold the port lock from selection through bind: see port_lock_acquire.
  port_lock_acquire || true

  if [ -z "$port" ]; then
    port=$(derive_port "$(worktree_seed)") \
      || die "no free port in $PORT_BASE-$((PORT_BASE + PORT_RANGE - 1))"
  else
    case "$port" in ''|*[!0-9]*) die "invalid --port: $port" ;; esac
  fi

  # The readiness check below reads "something is listening on :$port" as "the
  # service is up". That is only true when the port was OURS to bind: launching
  # onto an already-occupied port would report a healthy service while the real
  # one died with "address already in use". Refuse instead of lying.
  if ! port_is_free "$port"; then
    if [ "$pinned" = 1 ]; then
      die "port $port is already in use; pick a free --port or omit --port to auto-derive one"
    fi
    die "port $port was taken between selection and launch; retry, or pass a free --port"
  fi
  # Another worker may hold a claim on this port whose service has not bound yet,
  # which no socket probe can see.
  if port_is_claimed "$port"; then
    die "port $port is already claimed by another task in $STATE_DIR; pick a free --port or omit --port to auto-derive one"
  fi

  mkdir -p "$LOGDIR" || die "cannot create log dir $LOGDIR"
  local stamp logfile
  # Seconds resolution: a restart within the same minute must not interleave two
  # runs into one log file.
  stamp=$(date +%Y-%m-%d-%H%M%S)
  logfile="$LOGDIR/$ID-$label-$stamp.log"

  # Tee the service output: the tab shows it live (visual stream) AND it appends
  # to a dated, searchable log (kept past teardown). PORT is exported so the
  # service binds the chosen port. The launch command is run as a shell line (so
  # $PORT, pipes, and && work), so multi-word arguments must be quoted as they
  # would be for a shell.
  local cwd launch endpoint log_offset
  cwd=$(pwd -P)
  launch=$(build_launch_line "$port" "$logfile")
  # Where THIS run's output starts. The stamp has seconds, but two runs of the
  # same label inside one second still share a filename, and `tee -a` appends. The
  # readiness loop must not see the PREVIOUS run's exit marker: it would conclude
  # the launch failed and close a perfectly healthy service.
  log_offset=0
  [ -f "$logfile" ] && log_offset=$(wc -c < "$logfile" 2>/dev/null | tr -d ' ')
  case "$log_offset" in ''|*[!0-9]*) log_offset=0 ;; esac

  endpoint=$(fm_backend_sibling_up "$BACKEND" "$CONTAINER" "$full_label" "$cwd" "$launch") \
    || die "failed to open the service tab on backend $BACKEND"

  # The tab is live; if we cannot register it, teardown cannot reap it - so on a
  # failed append, close the tab we just opened and fail loudly rather than leave
  # an orphaned service.
  if ! printf '%s\t%s\t%s\t%s\t%s\n' "$label" "$BACKEND" "$endpoint" "$port" "$logfile" >> "$REGISTRY"; then
    fm_backend_sibling_down "$BACKEND" "$endpoint" 2>/dev/null || true
    die "opened the service tab but failed to record it in $REGISTRY; closed the tab to avoid an orphan"
  fi

  # Bounded readiness wait: the port opening is the service-agnostic "it's up"
  # signal, and it is trustworthy because the port was free a moment ago and the
  # port lock is still held, so no other worker can be launching onto it. A
  # command that exits instead (a typo, a bad quote, a missing binary) writes the
  # exit marker, so we report the failure immediately instead of waiting out the
  # full timeout and then blaming a slow start.
  local waited=0 ready=0 exited=0
  while [ "$waited" -lt "$READY_TIMEOUT" ]; do
    if ! port_is_free "$port"; then ready=1; break; fi
    if run_log_has_exit_marker "$logfile" "$log_offset"; then exited=1; break; fi
    sleep 1
    waited=$((waited + 1))
  done
  port_lock_release

  if [ "$ready" = 1 ]; then
    echo "API up: http://127.0.0.1:$port  (tab $full_label, backend $BACKEND)"
  elif [ "$exited" = 1 ]; then
    # The launch failed, so leave no residue: an unreaped tab and a registered
    # but dead service would consume the worker's one slot and show up in status
    # as a down service. The log keeps everything that was printed.
    fm_backend_sibling_down "$BACKEND" "$endpoint" 2>/dev/null || true
    registry_remove_label "$label"
    echo "API FAILED: the launch command exited without binding :$port (tab closed, nothing registered)"
    echo "  $(run_log_tail "$logfile" "$log_offset" | grep -F "$EXIT_MARKER" | tail -n1)"
    echo "  the command runs as a shell line - check quoting; last log lines:"
    run_log_tail "$logfile" "$log_offset" | tail -n5 | sed 's/^/  /'
  else
    echo "API launched in tab $full_label on :$port (not yet accepting connections after ${READY_TIMEOUT}s; watch the tab / logs)"
  fi
  echo "logs: $logfile"
  [ "$exited" = 1 ] && return 1
  return 0
}

cmd_down() {
  resolve_paths
  if [ "$DOWN_ALL" = 1 ]; then
    if [ ! -s "$REGISTRY" ]; then
      echo "no services registered ($REGISTRY)"
      return 0
    fi
    local label b endpoint
    while IFS=$'\t' read -r label b endpoint _ _; do
      [ -n "$label" ] || continue
      [ -z "$endpoint" ] || fm_backend_sibling_down "$b" "$endpoint" </dev/null 2>/dev/null || true
      echo "service '$label' stopped (log kept)"
    done < "$REGISTRY"
    : > "$REGISTRY"
    return 0
  fi
  local prior endpoint b
  prior=$(registry_line_for_label "$DOWN_LABEL" || true)
  if [ -z "$prior" ]; then
    echo "no service registered for label '$DOWN_LABEL'"
    return 0
  fi
  b=$(printf '%s' "$prior" | cut -f2)
  endpoint=$(printf '%s' "$prior" | cut -f3)
  [ -z "$endpoint" ] || fm_backend_sibling_down "$b" "$endpoint" </dev/null 2>/dev/null || true
  registry_remove_label "$DOWN_LABEL"
  echo "service '$DOWN_LABEL' stopped (log kept)"
}

print_registry_status() {  # <registry-file> <prefix>
  local reg=$1 prefix=$2 label backend endpoint port logfile state last
  while IFS=$'\t' read -r label backend endpoint port logfile; do
    [ -n "$label" ] || continue
    if port_is_free "$port"; then state="down"; else state="serving"; fi
    last=""
    [ -f "$logfile" ] && last=$(tail -n1 "$logfile" 2>/dev/null)
    printf '%s%s  %s  %s  :%s  [%s]\n' "$prefix" "$label" "$backend" "$endpoint" "$port" "$state"
    printf '  log: %s\n' "$logfile"
    [ -z "$last" ] || printf '  last: %s\n' "$last"
  done < "$reg"
}

cmd_status() {
  resolve_paths
  if [ "$STATUS_ALL" = 1 ]; then
    local reg id found=0
    for reg in "$STATE_DIR"/*.api-tabs; do
      [ -e "$reg" ] || continue
      [ -s "$reg" ] || continue
      id=$(basename "$reg"); id=${id%.api-tabs}
      found=1
      print_registry_status "$reg" "$id  "
    done
    [ "$found" = 1 ] || echo "no services registered in $STATE_DIR"
    return 0
  fi
  if [ ! -s "$REGISTRY" ]; then
    echo "no services registered ($REGISTRY)"
    return 0
  fi
  print_registry_status "$REGISTRY" ""
}

# Close service tabs left behind by tasks that never reached teardown (a crash, a
# lost meta, a --force discard). Teardown is the normal reaper; this is the
# recovery-side backstop bin/fm-bootstrap.sh runs at session start. A registry
# whose task still has a state/<id>.meta belongs to a live task and is left alone.
cmd_sweep() {
  local state=$SWEEP_STATE
  if [ -z "$state" ]; then
    if [ -n "$REGISTRY" ]; then
      state=$(dirname "$REGISTRY")
    elif [ -n "${FM_HOME:-}" ]; then
      state="$FM_HOME/state"
    else
      die "sweep needs a state dir: pass --state <dir> or set FM_HOME/FM_WORKER_API_REGISTRY"
    fi
  fi
  [ -d "$state" ] || return 0
  local reg id b endpoint n
  for reg in "$state"/*.api-tabs; do
    [ -e "$reg" ] || continue
    id=$(basename "$reg"); id=${id%.api-tabs}
    [ -f "$state/$id.meta" ] && continue
    n=0
    while IFS=$'\t' read -r _ b endpoint _ _; do
      [ -n "$endpoint" ] || continue
      if [ "$SWEEP_DRY_RUN" = 1 ]; then
        n=$((n + 1))
        continue
      fi
      fm_backend_sibling_down "$b" "$endpoint" </dev/null 2>/dev/null || true
      n=$((n + 1))
    done < "$reg"
    # Say nothing when there was nothing to close (an emptied registry left by a
    # `down`). The line is a session-start diagnostic meaning "a task died with a
    # service still running"; printing it for zero tabs sends firstmate chasing a
    # task that shut down cleanly.
    if [ "$SWEEP_DRY_RUN" = 1 ]; then
      [ "$n" -gt 0 ] && echo "$id: would close $n orphaned service tab(s) (task gone)"
    else
      rm -f "$reg"
      [ "$n" -gt 0 ] && echo "$id: closed $n orphaned service tab(s) (task gone; logs kept)"
    fi
  done
}

cmd_logs() {
  resolve_paths
  if [ -n "$LOGS_PRUNE_BEFORE" ]; then
    case "$LOGS_PRUNE_BEFORE" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
      *) die "logs --prune-before wants a YYYY-MM-DD date, got '$LOGS_PRUNE_BEFORE'" ;;
    esac
    [ -d "$LOGDIR" ] || { echo "no log dir $LOGDIR"; return 0; }
    # Shape alone does not mean this system's find can parse it: BSD find rejects
    # far-future dates that GNU find accepts. Probe first so a rejected date is an
    # error, never a silent "pruned 0 log file(s)" that reads like success.
    find "$LOGDIR" -maxdepth 0 ! -newermt "$LOGS_PRUNE_BEFORE" >/dev/null 2>&1 \
      || die "logs --prune-before: this system's find cannot parse the date '$LOGS_PRUNE_BEFORE'"
    local n
    n=$(find "$LOGDIR" -type f -name '*.log' ! -newermt "$LOGS_PRUNE_BEFORE" -print 2>/dev/null | wc -l | tr -d ' ')
    find "$LOGDIR" -type f -name '*.log' ! -newermt "$LOGS_PRUNE_BEFORE" -delete 2>/dev/null \
      || die "logs --prune-before: deleting logs older than $LOGS_PRUNE_BEFORE from $LOGDIR failed"
    echo "pruned $n log file(s) older than $LOGS_PRUNE_BEFORE from $LOGDIR"
    return 0
  fi
  local prior logfile match
  prior=$(registry_line_for_label "$LOGS_LABEL" || true)
  if [ -n "$prior" ]; then
    logfile=$(printf '%s' "$prior" | cut -f5)
  else
    # Fall back to the newest log for this label. Filenames embed a zero-padded
    # YYYY-MM-DD-HHMMSS stamp, so the lexically-last glob match is the most recent.
    logfile=
    for match in "$LOGDIR/$ID-$LOGS_LABEL-"*.log; do
      [ -e "$match" ] && logfile=$match
    done
  fi
  [ -n "$logfile" ] && [ -f "$logfile" ] || die "no log found for label '$LOGS_LABEL'"
  if [ "$LOGS_FOLLOW" = 1 ]; then
    tail -f "$logfile"
  else
    cat "$logfile"
  fi
}

# --- argument parsing --------------------------------------------------------

UP_LABEL=api
UP_PORT=
UP_CMD=()
DOWN_LABEL=api
DOWN_ALL=0
STATUS_ALL=0
LOGS_LABEL=api
LOGS_FOLLOW=0
LOGS_PRUNE_BEFORE=
SWEEP_STATE=
SWEEP_DRY_RUN=0

parse_common_flag() {  # returns 0 if consumed; sets shift count in FLAG_SHIFT
  FLAG_SHIFT=0
  case "$1" in
    --registry) require_val "$@"; REGISTRY=${2:-}; FLAG_SHIFT=2 ;;
    --registry=*) REGISTRY=${1#--registry=}; FLAG_SHIFT=1 ;;
    --logdir) require_val "$@"; LOGDIR=${2:-}; FLAG_SHIFT=2 ;;
    --logdir=*) LOGDIR=${1#--logdir=}; FLAG_SHIFT=1 ;;
    *) return 1 ;;
  esac
  return 0
}

CMD=${1:-}
[ "$#" -gt 0 ] && shift || true
case "$CMD" in
  -h|--help|help|'') usage; [ -n "$CMD" ] && exit 0 || exit 2 ;;
  up|restart)
    while [ "$#" -gt 0 ]; do
      if parse_common_flag "$@"; then shift "$FLAG_SHIFT"; continue; fi
      case "$1" in
        --label) require_val "$@"; UP_LABEL=${2:-}; shift 2 ;;
        --label=*) UP_LABEL=${1#--label=}; shift ;;
        --port) require_val "$@"; UP_PORT=${2:-}; shift 2 ;;
        --port=*) UP_PORT=${1#--port=}; shift ;;
        --) shift; UP_CMD=("$@"); break ;;
        --*) die "unknown flag for $CMD: $1" ;;
        *) UP_CMD=("$@"); break ;;
      esac
    done
    [ -n "$UP_LABEL" ] || die "--label cannot be empty"
    if [ "$CMD" = restart ]; then cmd_up 1; else cmd_up 0; fi
    ;;
  down)
    while [ "$#" -gt 0 ]; do
      if parse_common_flag "$@"; then shift "$FLAG_SHIFT"; continue; fi
      case "$1" in
        --label) require_val "$@"; DOWN_LABEL=${2:-}; shift 2 ;;
        --label=*) DOWN_LABEL=${1#--label=}; shift ;;
        --all) DOWN_ALL=1; shift ;;
        *) die "unknown flag for down: $1" ;;
      esac
    done
    cmd_down
    ;;
  status)
    while [ "$#" -gt 0 ]; do
      if parse_common_flag "$@"; then shift "$FLAG_SHIFT"; continue; fi
      case "$1" in
        --all) STATUS_ALL=1; shift ;;
        *) die "unknown flag for status: $1" ;;
      esac
    done
    cmd_status
    ;;
  logs)
    while [ "$#" -gt 0 ]; do
      if parse_common_flag "$@"; then shift "$FLAG_SHIFT"; continue; fi
      case "$1" in
        --label) require_val "$@"; LOGS_LABEL=${2:-}; shift 2 ;;
        --label=*) LOGS_LABEL=${1#--label=}; shift ;;
        --follow|-f) LOGS_FOLLOW=1; shift ;;
        --prune-before) require_val "$@"; LOGS_PRUNE_BEFORE=${2:-}; shift 2 ;;
        --prune-before=*) LOGS_PRUNE_BEFORE=${1#--prune-before=}; shift ;;
        *) die "unknown flag for logs: $1" ;;
      esac
    done
    cmd_logs
    ;;
  sweep)
    while [ "$#" -gt 0 ]; do
      if parse_common_flag "$@"; then shift "$FLAG_SHIFT"; continue; fi
      case "$1" in
        --state) require_val "$@"; SWEEP_STATE=${2:-}; shift 2 ;;
        --state=*) SWEEP_STATE=${1#--state=}; shift ;;
        --dry-run) SWEEP_DRY_RUN=1; shift ;;
        *) die "unknown flag for sweep: $1" ;;
      esac
    done
    cmd_sweep
    ;;
  *)
    die "unknown command '$CMD' (use: up|down|restart|status|logs|sweep)"
    ;;
esac
