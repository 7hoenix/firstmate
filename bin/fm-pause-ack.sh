#!/usr/bin/env bash
# fm-pause-ack.sh <task-id> - supervisor-side acknowledgment of a declared pause.
#
# When firstmate is woken by a declared-pause recheck ("paused Ns, awaiting external
# ...") and confirms the external wait still holds, it defers the NEXT recheck by one
# full pause window with this ack, instead of steering the crew to re-append a `paused:`
# line. That steer is otherwise a full-context turn on a resident, high-context crew
# session - the parked-lane recheck burn; this ack is a zero-token supervisor-side touch.
#
# It touches state/.paused-ack-<key>, a supervisor-owned dotfile the pause-recheck
# cadence in bin/fm-watch.sh (and, in away mode, bin/fm-supervise-daemon.sh) anchors on:
# the recheck age is measured from the NEWER of this marker and the crew's status-file
# mtime, so an ack resets the window exactly as a fresh crew re-append would.
#
# The crew's own append-only status file is deliberately NOT touched: changing its
# size:mtime signature would trip the watcher's signal scan and fire a spurious wake -
# the very cost this avoids. The <key> is derived from the task's recorded endpoint so it
# matches the watcher's window-derived key exactly. Idempotent; safe to run repeatedly.
# Usage: fm-pause-ack.sh <task-id>
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

id=${1:-}
if [ -z "$id" ]; then
  echo "usage: fm-pause-ack.sh <task-id>" >&2
  exit 2
fi

meta="$STATE/$id.meta"
if [ ! -e "$meta" ]; then
  echo "fm-pause-ack: no task metadata at $meta" >&2
  exit 1
fi

win=$(fm_backend_target_of_meta "$meta")
if [ -z "$win" ]; then
  echo "fm-pause-ack: no endpoint recorded for task $id" >&2
  exit 1
fi

last=$(last_status_line "$STATE/$id.status")
if ! status_is_paused "$last"; then
  echo "fm-pause-ack: task $id is not in a declared pause (last status: ${last:-none}); nothing to defer" >&2
  exit 1
fi

key=$(printf '%s' "$win" | tr ':/.' '___')
mkdir -p "$STATE"
: > "$STATE/.paused-ack-$key"
# Reset the watcher's re-surface throttle so the next window is measured from this ack.
rm -f "$STATE/.paused-resurfaced-$key"
echo "fm-pause-ack: deferred the next recheck for task $id ($win) by one pause window"
