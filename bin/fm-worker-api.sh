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
#   fm-worker-api.sh down [--label <suffix>]
#   fm-worker-api.sh restart [--label <suffix>] [--port <n>] [--] <launch command...>
#   fm-worker-api.sh status
#   fm-worker-api.sh logs [--label <suffix>] [--follow]
#   fm-worker-api.sh logs --prune-before <YYYY-MM-DD>
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
#                         --port pins an explicit value.
#   - Logs (collected, not deleted): the service's stdout+stderr is teed to a
#                         dated file under $FM_WORKER_API_LOGDIR
#                         (<id>-<label>-<YYYY-MM-DD-HHMM>.log) that SURVIVES
#                         teardown. Bulk-pruned later via `logs --prune-before`.
#
# $FM_WORKER_API_REGISTRY and $FM_WORKER_API_LOGDIR are exported into the worker's
# pane by bin/fm-spawn.sh (like GOTMPDIR). --registry/--logdir override them for
# manual use and tests. v1 hosts ONE service per worker (a second `up` with a new
# label refuses); the registry is label-keyed so growing to several later is
# additive.
set -u

PORT_BASE=${FM_WORKER_API_PORT_BASE:-8800}
PORT_RANGE=${FM_WORKER_API_PORT_RANGE:-200}
READY_TIMEOUT=${FM_WORKER_API_READY_TIMEOUT:-20}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

err() { echo "fm-worker-api: $*" >&2; }
die() { err "$*"; exit 1; }

usage() { sed -n '2,55p' "$0" | sed 's/^# \{0,1\}//'; }

# --- registry / log location -------------------------------------------------

REGISTRY=${FM_WORKER_API_REGISTRY:-}
LOGDIR=${FM_WORKER_API_LOGDIR:-}

resolve_paths() {
  [ -n "$REGISTRY" ] || die "no registry path: set FM_WORKER_API_REGISTRY (exported by fm-spawn) or pass --registry"
  case "$REGISTRY" in
    */*) : ;;
    *) die "registry path must be absolute or contain a directory: $REGISTRY" ;;
  esac
  local state_dir home_dir
  state_dir=$(dirname "$REGISTRY")
  home_dir=$(dirname "$state_dir")
  ID=$(basename "$REGISTRY")
  ID=${ID%.api-tabs}
  [ -n "$ID" ] || die "cannot derive task id from registry path $REGISTRY"
  [ -n "$LOGDIR" ] || LOGDIR="$home_dir/data/api-logs"
}

# --- self-location -----------------------------------------------------------
#
# Reads the backend-injected pane environment. herdr sets HERDR_ENV=1 plus the
# pane-specific HERDR_WORKSPACE_ID (and HERDR_SESSION in a named session, absent
# in the default one -> "default"); tmux sets $TMUX and answers display-message.

detect_backend_container() {
  if [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_WORKSPACE_ID:-}" ]; then
    BACKEND=herdr
    CONTAINER="${HERDR_SESSION:-default}:$HERDR_WORKSPACE_ID"
  elif [ -n "${TMUX:-}" ]; then
    BACKEND=tmux
    CONTAINER=$(tmux display-message -p '#{session_name}' 2>/dev/null) \
      || die "tmux display-message failed; cannot self-locate the container"
    [ -n "$CONTAINER" ] || die "tmux reported an empty session name"
  else
    die "unsupported backend: on-demand service tabs need tmux or herdr (v1). No HERDR_ENV/HERDR_WORKSPACE_ID or \$TMUX in this pane."
  fi
}

# --- port selection ----------------------------------------------------------

port_is_free() {  # <port>  -> 0 when nothing is listening (connect refused)
  local p=$1
  ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null
}

derive_port() {  # <seed-string> -> first free port at/above a deterministic candidate
  local seed=$1 n i p
  n=$(printf '%s' "$seed" | cksum | awk '{print $1}')
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  for ((i = 0; i < PORT_RANGE; i++)); do
    p=$(( PORT_BASE + ( (n + i) % PORT_RANGE ) ))
    if port_is_free "$p"; then
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
  awk -F'\t' -v l="$1" '$1!=l' "$REGISTRY" > "$tmp" 2>/dev/null || true
  mv "$tmp" "$REGISTRY"
}

registry_labels() {
  [ -f "$REGISTRY" ] || return 0
  cut -f1 "$REGISTRY" 2>/dev/null
}

# --- commands ----------------------------------------------------------------

cmd_up() {  # <restart 0|1>
  local restart=${1:-0} label port
  label=$UP_LABEL
  port=$UP_PORT
  [ "${#UP_CMD[@]}" -gt 0 ] || die "up needs a launch command, e.g. up -- wrangler dev"

  resolve_paths
  detect_backend_container

  local full_label="fm-$ID-$label"

  # v1: one service per worker. A same-label up is a restart; a different-label
  # up while one is live refuses.
  if [ -f "$REGISTRY" ]; then
    local existing
    existing=$(registry_labels)
    if printf '%s\n' "$existing" | grep -Fqx -- "$label"; then
      [ "$restart" = 1 ] || restart=1  # same label -> replace
    elif [ -n "$existing" ]; then
      die "a service is already up for this worker (label(s): $(printf '%s' "$existing" | tr '\n' ' ')); v1 hosts one per worker - 'down' it first"
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
    local prior endpoint b
    prior=$(registry_line_for_label "$label" || true)
    if [ -n "$prior" ]; then
      b=$(printf '%s' "$prior" | cut -f2)
      endpoint=$(printf '%s' "$prior" | cut -f3)
      [ -z "$endpoint" ] || fm_backend_sibling_down "$b" "$endpoint" 2>/dev/null || true
      registry_remove_label "$label"
    fi
  fi

  if [ -z "$port" ]; then
    port=$(derive_port "$(worktree_seed)") \
      || die "no free port in $PORT_BASE-$((PORT_BASE + PORT_RANGE - 1))"
  else
    case "$port" in ''|*[!0-9]*) die "invalid --port: $port" ;; esac
  fi

  mkdir -p "$LOGDIR" || die "cannot create log dir $LOGDIR"
  local stamp logfile
  stamp=$(date +%Y-%m-%d-%H%M)
  logfile="$LOGDIR/$ID-$label-$stamp.log"

  # Tee the service output: the tab shows it live (visual stream) AND it appends
  # to a dated, searchable log (kept past teardown). PORT is exported so the
  # service binds the chosen port. The launch command is run as a shell line (so
  # $PORT, pipes, and && work), so multi-word arguments must be quoted as they
  # would be for a shell.
  local cwd launch endpoint
  cwd=$(pwd -P)
  launch="export PORT=$port; $(printf '%s ' "${UP_CMD[@]}")2>&1 | tee -a $(printf '%q' "$logfile")"

  endpoint=$(fm_backend_sibling_up "$BACKEND" "$CONTAINER" "$full_label" "$cwd" "$launch") \
    || die "failed to open the service tab on backend $BACKEND"

  printf '%s\t%s\t%s\t%s\t%s\n' "$label" "$BACKEND" "$endpoint" "$port" "$logfile" >> "$REGISTRY"

  # Bounded readiness wait: the port opening is the service-agnostic "it's up"
  # signal. Report either way (some services take longer to bind).
  local waited=0 ready=0
  while [ "$waited" -lt "$READY_TIMEOUT" ]; do
    if ! port_is_free "$port"; then ready=1; break; fi
    sleep 1
    waited=$((waited + 1))
  done
  if [ "$ready" = 1 ]; then
    echo "API up: http://127.0.0.1:$port  (tab $full_label, backend $BACKEND)"
  else
    echo "API launched in tab $full_label on :$port (not yet accepting connections after ${READY_TIMEOUT}s; watch the tab / logs)"
  fi
  echo "logs: $logfile"
}

cmd_down() {
  resolve_paths
  local prior endpoint b
  prior=$(registry_line_for_label "$DOWN_LABEL" || true)
  if [ -z "$prior" ]; then
    echo "no service registered for label '$DOWN_LABEL'"
    return 0
  fi
  b=$(printf '%s' "$prior" | cut -f2)
  endpoint=$(printf '%s' "$prior" | cut -f3)
  [ -z "$endpoint" ] || fm_backend_sibling_down "$b" "$endpoint" 2>/dev/null || true
  registry_remove_label "$DOWN_LABEL"
  echo "service '$DOWN_LABEL' stopped (log kept)"
}

cmd_status() {
  resolve_paths
  if [ ! -s "$REGISTRY" ]; then
    echo "no services registered ($REGISTRY)"
    return 0
  fi
  local label backend endpoint port logfile state last
  while IFS=$'\t' read -r label backend endpoint port logfile; do
    [ -n "$label" ] || continue
    if port_is_free "$port"; then state="down"; else state="serving"; fi
    last=""
    [ -f "$logfile" ] && last=$(tail -n1 "$logfile" 2>/dev/null)
    printf '%s  %s  %s  :%s  [%s]\n' "$label" "$backend" "$endpoint" "$port" "$state"
    printf '  log: %s\n' "$logfile"
    [ -z "$last" ] || printf '  last: %s\n' "$last"
  done < "$REGISTRY"
}

cmd_logs() {
  resolve_paths
  if [ -n "$LOGS_PRUNE_BEFORE" ]; then
    case "$LOGS_PRUNE_BEFORE" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) : ;;
      *) die "logs --prune-before wants a YYYY-MM-DD date, got '$LOGS_PRUNE_BEFORE'" ;;
    esac
    [ -d "$LOGDIR" ] || { echo "no log dir $LOGDIR"; return 0; }
    local n
    n=$(find "$LOGDIR" -type f -name '*.log' ! -newermt "$LOGS_PRUNE_BEFORE" -print | wc -l | tr -d ' ')
    find "$LOGDIR" -type f -name '*.log' ! -newermt "$LOGS_PRUNE_BEFORE" -delete 2>/dev/null || true
    echo "pruned $n log file(s) older than $LOGS_PRUNE_BEFORE from $LOGDIR"
    return 0
  fi
  local prior logfile match
  prior=$(registry_line_for_label "$LOGS_LABEL" || true)
  if [ -n "$prior" ]; then
    logfile=$(printf '%s' "$prior" | cut -f5)
  else
    # Fall back to the newest log for this label. Filenames embed a zero-padded
    # YYYY-MM-DD-HHMM stamp, so the lexically-last glob match is the most recent.
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
LOGS_LABEL=api
LOGS_FOLLOW=0
LOGS_PRUNE_BEFORE=

parse_common_flag() {  # returns 0 if consumed; sets shift count in FLAG_SHIFT
  FLAG_SHIFT=0
  case "$1" in
    --registry) REGISTRY=${2:-}; FLAG_SHIFT=2 ;;
    --registry=*) REGISTRY=${1#--registry=}; FLAG_SHIFT=1 ;;
    --logdir) LOGDIR=${2:-}; FLAG_SHIFT=2 ;;
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
        --label) UP_LABEL=${2:-}; shift 2 ;;
        --label=*) UP_LABEL=${1#--label=}; shift ;;
        --port) UP_PORT=${2:-}; shift 2 ;;
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
        --label) DOWN_LABEL=${2:-}; shift 2 ;;
        --label=*) DOWN_LABEL=${1#--label=}; shift ;;
        *) die "unknown flag for down: $1" ;;
      esac
    done
    cmd_down
    ;;
  status)
    while [ "$#" -gt 0 ]; do
      if parse_common_flag "$@"; then shift "$FLAG_SHIFT"; continue; fi
      die "unknown flag for status: $1"
    done
    cmd_status
    ;;
  logs)
    while [ "$#" -gt 0 ]; do
      if parse_common_flag "$@"; then shift "$FLAG_SHIFT"; continue; fi
      case "$1" in
        --label) LOGS_LABEL=${2:-}; shift 2 ;;
        --label=*) LOGS_LABEL=${1#--label=}; shift ;;
        --follow|-f) LOGS_FOLLOW=1; shift ;;
        --prune-before) LOGS_PRUNE_BEFORE=${2:-}; shift 2 ;;
        --prune-before=*) LOGS_PRUNE_BEFORE=${1#--prune-before=}; shift ;;
        *) die "unknown flag for logs: $1" ;;
      esac
    done
    cmd_logs
    ;;
  *)
    die "unknown command '$CMD' (use: up|down|restart|status|logs)"
    ;;
esac
