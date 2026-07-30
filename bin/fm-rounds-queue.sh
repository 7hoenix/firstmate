#!/usr/bin/env bash
# fm-rounds-queue.sh - the ordered, classified triage queue behind the /rounds skill.
#
# A thin projection OVER the canonical bin/fm-fleet-snapshot.sh, the same pattern
# fm-bearings-snapshot.sh and fm-fleet-view.sh use: it does not parse fleet state
# itself, it shells out to `fm-fleet-snapshot.sh --json` and projects that contract
# into one ordered walk. TOON by default (`--json` prints the same model), encoded
# through the shared bin/fm-toon-lib.sh.
#
# WHY A SCRIPT AND NOT SKILL PROSE: this file is the ONE owner of the mechanical
# actionable/not-actionable decision. A classification rule written as prose is a
# rule the model re-derives, differently, on every invocation. Here it is
# deterministic, testable (tests/fm-rounds-queue.test.sh), and costs no tokens.
# The /rounds skill owns only the conversation: how to present an item, how to
# record an answer, what it may not decide.
#
# THE SET. The live lane set and the backlog are NOT the same set - lanes run with
# no backlog row, and rows sit with no lane - so the queue is their UNION keyed by
# task id. A member missing from either side is itself a finding, not a filter.
#
# DROPPED, silently:
#   kind=secondmate      persistent supervisors are never work items (AGENTS.md s10)
#   done + no live lane  already landed and stood down
#   active hold          b.hold set AND (hold_until absent OR today < hold_until).
#                        A hold is the captain's own recorded "not now"; re-asking is
#                        the noise /rounds exists to remove. tasks-axi defines an
#                        --until gate as inactive ON and after that date, so an
#                        arrived gate is NOT a drop - it becomes a captain item,
#                        but only while the item has no lane yet. A dispatched
#                        item keeps its expired gate until it is unheld, and
#                        re-asking about work already underway is noise.
#                        EXEMPT: a hold never suppresses a lane with a LIVE PROBLEM -
#                        an open decision, or current_state blocked or failed. An
#                        undated hold never expires, so without this a "not now" on a
#                        lane that later parks on a captain decision would bury that
#                        decision permanently. The captain deferred the work, not a
#                        crew stuck waiting on them. A held row with no such live
#                        signal is dropped exactly as before.
#
# BUCKETS. `unreliable` is tested BEFORE `captain`, because a lane whose recorded
# state contradicts itself must never be presented as a state claim - see the
# contradiction detectors below. Then `captain` (present one at a time), then
# `dispatchable` (firstmate's own call under AGENTS.md s7, reported as one batched
# line, never asked about), then `quiet` (silent unless --all).
#
# CONTRADICTION DETECTORS. Each exists because it fired on real fleet state:
#   dead-lane-run    endpoint gone and current_state came from a run-step, AND
#                    EITHER this lane's workspace is still claimed by a LIVE lane,
#                    OR the run is not at a terminal outcome. A run is matched by
#                    the branch at the workspace HEAD, so only a slot a live lane
#                    now occupies can attribute that occupant's parked review to
#                    this landed lane; and a run still working or parked has no
#                    crew left to drive it whatever the workspace says. Neither
#                    narrowing is optional: a terminal run-step reading on a dead
#                    endpoint is the NORMAL state of a crew that finished and then
#                    exited (fm-crew-state.sh reads the run-step deliberately
#                    before any pane-liveness check), so firing on the dead
#                    endpoint alone hid every finished lane's real reason -
#                    pr-ready, ready-to-stand-down, report-ready - behind
#                    "go check".
#   failed-but-landed  current_state failed while the backlog records it merged.
#   paused-but-gone  a declared pause on a lane whose workspace is gone: abandoned,
#                    not waiting. Keying on the status log alone would skip this
#                    forever, because the log's last line still says paused.
#   no-backlog-row   running with nothing tracking it.
#   no-lane          recorded in flight with nothing running.
#   indeterminate    current_state unknown with no source at all.
# The first three are severity `contradiction` and walk first; the last three are
# `bookkeeping` - real drift, but it poisons no state claim, so it must never
# outrank a live decision waiting on the captain.
#
# A shared workspace is deliberately NOT a per-lane detector. Two live lanes
# claiming one path is ONE fleet-level fact, so it is reported once in conflicts[]
# and each affected lane carries workspace_ambiguous=true for the presenter to
# caveat. As a per-lane reason it fired on 8 of 19 walk items and buried the real
# work behind eight copies of the same finding.
#
# PRIORITY. Read from the backlog row's tasks-axi priority field (0-4, 0 highest);
# there is no second store. Unset sorts as 2 (medium) and is flagged priority_set
# false so the presenter can offer to set it rather than bury the item.
#
# SORT: priority ascending first, then tier - contradiction-severity items ahead of
# captain items, bookkeeping-severity items after them - then oldest first, then id.
#
# COUNTS: every count_* describes the same population, the FULL pre-limit set, so
# there is exactly one unambiguous total per surface. `shown` is the separate field
# for how many walk[] entries --limit actually left; walk[].pos runs 1..shown.
#
# Flags:
#   (default)      TOON, captain + unreliable + dispatchable
#   --json         the same model as JSON (parity form)
#   --all          also include the quiet bucket (debugging)
#   --limit <n>    bound the walk; truncation is disclosed in omitted[]
#   -h,--help      usage
#
# Output contract: `fm-rounds.v1`. Read-only: no lock, no wake drain, no watcher,
# no backlog mutation, no report file. Acting on the queue is the skill's job.
#
# Test-only overrides: FM_ROUNDS_TODAY pins today's date (hold gates are
# date-relative), FM_ROUNDS_SNAPSHOT substitutes the snapshot producer.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# FM_ROUNDS_SNAPSHOT overrides the snapshot producer so tests can drive every
# classification branch from a synthetic snapshot without a real worktree, backend,
# or no-mistakes install - the same override shape fm-classify-lib.sh uses for its
# crew-state reader. It must stay test-only; production always uses the sibling.
FLEET="${FM_ROUNDS_SNAPSHOT:-$SCRIPT_DIR/fm-fleet-snapshot.sh}"
# shellcheck source=bin/fm-toon-lib.sh
. "$SCRIPT_DIR/fm-toon-lib.sh"

usage() {
  cat <<'EOF'
usage: fm-rounds-queue.sh [--json] [--all] [--limit <n>]

Print the ordered, classified triage queue projected from fm-fleet-snapshot.sh.
TOON by default; --json prints the same model. Read-only.

  --json        JSON parity form
  --all         include the quiet bucket too
  --limit <n>   bound the presented walk (default: unbounded)
EOF
}

FORMAT=toon
ALL=false
LIMIT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json) FORMAT=json; shift ;;
    --all) ALL=true; shift ;;
    --limit)
      shift
      [ $# -gt 0 ] || { echo "fm-rounds-queue: --limit needs a value" >&2; exit 2; }
      case "$1" in
        ''|*[!0-9]*) echo "fm-rounds-queue: --limit must be a non-negative integer" >&2; exit 2 ;;
      esac
      LIMIT=$1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "fm-rounds-queue: jq not found" >&2; exit 1; }
[ -x "$FLEET" ] || { echo "fm-rounds-queue: cannot execute $FLEET" >&2; exit 1; }

SNAP=$("$FLEET" --json) || { echo "fm-rounds-queue: fleet snapshot failed" >&2; exit 1; }

TODAY=${FM_ROUNDS_TODAY:-$(date -u +%Y-%m-%d)}
GENERATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)

MODEL=$(printf '%s\n' "$SNAP" | jq \
  --arg today "$TODAY" \
  --arg generated "$GENERATED" \
  --argjson limit "$LIMIT" \
  --argjson all "$ALL" '

  # ---- inputs -------------------------------------------------------------
  . as $snap
  | ($snap.tasks // []) as $tasks
  | ($snap.backlog.records // []) as $recs
  | ($recs | map(select(.structured == true))) as $rows
  | ($rows | map(select(.state == "in_flight" or .state == "queued"))) as $open
  | (reduce $rows[] as $r ({}; .[$r.id] = $r)) as $bmap
  | (reduce $tasks[] as $t ({}; .[$t.id] = $t)) as $tmap

  # Workspace paths a lane whose endpoint is STILL ALIVE currently claims.
  # $live_wt is every such path: a DEAD lane recorded at one of them is sitting on
  # a recycled slot a live lane now occupies, which is the only way a run matched
  # by workspace-HEAD branch can be attributed to the wrong lane (dead-lane-run).
  # $shared_wt is the subset TWO live lanes claim at once, which is the only way
  # two lanes genuinely contend for one path. A dead lane sharing a slot with a
  # live one is not that kind of conflict - the live lane owns it - so requiring
  # two live claimants keeps workspace_ambiguous rare and meaningful; without that
  # filter it fired on 11 of 18 lanes and drowned the real work.
  | ( $tasks
      | map(select(.endpoint.exists == true and .paths.worktree.path != null)
            | .paths.worktree.path) ) as $live_wt_all
  | ($live_wt_all | unique) as $live_wt
  | ($live_wt_all | group_by(.) | map(select(length > 1) | .[0])) as $shared_wt

  # ---- helpers ------------------------------------------------------------
  | def hold_active($b):
      $b != null and $b.hold != null
      and (($b.hold_until == null) or ($today < $b.hold_until));
    # A live problem outranks a captain-recorded deferral. An undated hold never
    # expires, so suppressing on hold alone would bury an open decision - or a
    # blocked/failed lane, the same class of live problem - for good.
    def live_problem($t):
      $t != null
      and (((($t.hints.open_decisions // []) | length) > 0)
           or ($t.current_state.state == "blocked")
           or ($t.current_state.state == "failed"));
    def suppressed($m):
      hold_active($m.b) and (live_problem($m.t) | not);
    def gate_arrived($b):
      $b != null and $b.hold != null
      and $b.hold_until != null and ($today >= $b.hold_until);
    def landed($b):
      $b != null and ($b.state == "done" or $b.completion.verb == "merged");
    def prio($b):
      if $b == null or $b.priority == null then null
      else ($b.priority | tonumber? // null) end;
    def prio_word($p):
      if $p == 0 then "urgent" elif $p == 1 then "high" elif $p == 2 then "medium"
      elif $p == 3 then "low" elif $p == 4 then "someday" else "medium" end;
    def blocker_open($b):
      $b != null and $b.blocked_by != null
      and ($open | map(.id) | index($b.blocked_by)) != null;

  # ---- the union set ------------------------------------------------------
    ((($tasks | map(.id)) + ($open | map(.id))) | unique) as $ids
  | [ $ids[] | { id: ., t: $tmap[.], b: $bmap[.] } ] as $members

  # ---- drops -------------------------------------------------------------
  | ($members | map(select(.t != null and .t.kind == "secondmate"))) as $d_sub
  | ( $members
      | map(select((.t == null or .t.kind != "secondmate") and suppressed(.))) ) as $d_held
  | ( $rows
      | map(select(.state == "done" and ($tmap[.id] == null))) ) as $d_done
  | ( $members
      | map(select(
          (.t == null or .t.kind != "secondmate")
          and (suppressed(.) | not))) ) as $live

  # ---- classification ----------------------------------------------------
  | ( $live
      | map(
          . as $m
          | .t as $t | .b as $b
          | ($t.current_state.state // null) as $st
          | ($t.current_state.source // null) as $src
          | (($t.hints.open_decisions // []) | length) as $ndec
          | (if $t == null then null else $t.paths.worktree.path end) as $wt
          | ((($t.current_state.detail // "")
              | index("PR merged/closed")) != null) as $pr_landed

          # unreliable first: a contradiction taints every claim below it.
          # dead-lane-run needs one of its two narrowing conditions too: without
          # them every crew that finished and exited reads as a contradiction and
          # loses its real actionable reason. The exemption covers ONLY a run that
          # reported a terminal outcome - a run still working or parked has no crew
          # left to drive it, which is a contradiction whatever the workspace says.
          | ( if $t != null and $t.endpoint.exists == false and $src == "run-step"
                 and (($wt != null and ($live_wt | index($wt)) != null)
                      or ($st != "done" and $st != "failed"))
                then "dead-lane-run"
              elif $t != null and $st == "failed" and landed($b)
                then "failed-but-landed"
              elif $t != null and $st == "paused" and $t.endpoint.exists == false
                then "paused-but-gone"
              elif $t != null and $b == null
                then "no-backlog-row"
              elif $t == null and $b != null and $b.state == "in_flight"
                then "no-lane"
              elif $t != null and $st == "unknown" and $src == "none"
                then "indeterminate"
              else null end ) as $bad

          # then the captain-owned reasons
          | ( if $ndec > 0 then "decision-waiting"
              elif $st == "blocked" then "blocked"
              # A failure the crew could not recover from is captain-owned under
              # AGENTS.md s9. Without this it falls through to the no-signal
              # default in the quiet bucket and is never presented at all.
              elif $st == "failed" then "failed"
              # fm-crew-state.sh maps BOTH terminal run outcomes to state done and
              # separates them only in detail: `passed` means the PR is already
              # merged or closed, `checks-passed` means it is green and awaiting
              # review. Without this branch a landed PR is presented as needing a
              # merge the captain already gave.
              elif $st == "done" and $pr_landed then "ready-to-stand-down"
              elif $st == "done" and ($t.pr.url // null) != null then "pr-ready"
              elif $st == "done" and $t.mode == "local-only" then "review-diff"
              elif $st == "done" and $t.kind == "scout"
                   and ($t.paths.report.present // false) then "report-ready"
              elif $st == "done" then "finished-unseen"
              elif $st == "paused" and landed($b) then "ready-to-stand-down"
              # An arrived gate is only actionable while nothing is working the
              # item yet: `tasks-axi start` does NOT strip hold tokens, so a
              # dispatched item keeps its expired gate until someone unholds it.
              # Ungated, that expired gate would re-present a running item to the
              # captain on every round for the rest of its life.
              elif $t == null and gate_arrived($b) then "gate-arrived"
              else null end ) as $ask

          # then the quiet reasons, with the action /rounds takes silently
          | ( if $st == "working" then ["progressing", "none"]
              elif $st == "parked" and $ndec == 0 then ["parked-on-itself", "steer"]
              elif $st == "paused" then ["declared-wait", "pause-ack"]
              elif $b != null and $b.state == "queued" and blocker_open($b)
                then ["waiting-on-another", "none"]
              elif $b != null and $b.state == "queued" then ["dispatchable", "dispatch"]
              else ["no-signal", "none"] end ) as $quiet

          | ( if $bad != null then "unreliable"
              elif $ask != null then "captain"
              elif $quiet[0] == "dispatchable" then "dispatchable"
              else "quiet" end ) as $bucket

          # Sort tier, distinct from the bucket. A CONTRADICTION makes a state
          # claim untrustworthy, so it is worth resolving before anything that
          # depends on state - it walks first. BOOKKEEPING drift (a row with no
          # lane, a lane with no row) is real and worth surfacing, but it poisons
          # nothing, so it must not outrank a live decision waiting on the captain.
          | ( if $bad == "dead-lane-run" or $bad == "failed-but-landed"
                 or $bad == "paused-but-gone"
                then 0
              elif $bucket == "captain" then 1
              elif $bad != null then 2
              else 3 end ) as $tier

          | { id: $m.id,
              bucket: $bucket,
              tier: $tier,
              severity: (if $tier == 0 then "contradiction"
                         elif $tier == 2 then "bookkeeping" else "-" end),
              why: ($bad // $ask // $quiet[0]),
              action: (if $bucket == "quiet" then $quiet[1] else "ask" end),
              priority: prio($b),
              priority_set: (prio($b) != null),
              priority_word: prio_word(prio($b) // 2),
              sort_priority: (prio($b) // 2),
              workspace_ambiguous: ($wt != null and ($shared_wt | index($wt)) != null),
              # The project recorded on the lane itself backs repo up, because the
              # one finding with no backlog row to read it from - no-backlog-row -
              # is exactly the one whose handling needs a project name to render
              # and a --repo value to file the missing row with.
              repo: (if $b != null and $b.repo != null then $b.repo
                     else (($t.project // "") | if . == "" then null else . end)
                     end),
              kind: ($t.kind // (if $b != null then $b.kind else null end)),
              title: (if $b != null then $b.title else null end),
              state: $st,
              source: $src,
              since: (if $b != null then $b.since else null end),
              decisions: $ndec,
              pr: ($t.pr.url // (if $b != null then $b.pr_url else null end)),
              report: (if $t != null and ($t.paths.report.present // false)
                       then $t.paths.report.path else null end),
              detail: ($t.current_state.detail // (if $b != null then $b.hold else null end)) }
        ) ) as $classified

  # ---- ordering ----------------------------------------------------------
  | ( $classified
      | map(select(.bucket == "unreliable" or .bucket == "captain"))
      | sort_by([ .sort_priority, .tier, (.since // "0000-00-00"), .id ]) ) as $walk_all
  | (if $limit > 0 then ($walk_all[:$limit]) else $walk_all end) as $walk
  | ($classified | map(select(.bucket == "dispatchable"))) as $dispatchable
  | ($classified | map(select(.bucket == "quiet"))) as $quiet_items

  # ---- output model ------------------------------------------------------
  | { schema: "fm-rounds.v1",
      home: ($snap.fm_home // null),
      generated: $generated,
      today: $today,
      # Counts are flat top-level scalars, not a nested object: the shared TOON
      # encoder implements scalars and uniform-object arrays only (fm-toon-lib.sh).
      # Every count_* is over the FULL pre-limit set, so they never disagree about
      # the population they describe. `shown` alone reflects --limit truncation,
      # and walk[].pos runs 1..shown.
      count_walk: ($walk_all | length),
      shown: ($walk | length),
      count_captain: ($walk_all | map(select(.bucket == "captain")) | length),
      count_contradiction: ($walk_all | map(select(.tier == 0)) | length),
      count_bookkeeping: ($walk_all | map(select(.tier == 2)) | length),
      count_dispatchable: ($dispatchable | length),
      count_quiet: ($quiet_items | length),
      count_held: ($d_held | length),
      count_landed: ($d_done | length),
      count_secondmate: ($d_sub | length),
      count_conflicts: ($shared_wt | length),
      walk: [ $walk | to_entries[]
              | { pos: (.key + 1) } + (.value | { id, bucket, severity, why,
                    priority_word, priority_set, workspace_ambiguous, repo, kind,
                    state, source, decisions, pr, report, since, title, detail }) ],
      # A shared workspace is one fleet-level fact, not N separate walk items:
      # reported once here, with every affected lane flagged workspace_ambiguous so
      # the presenter caveats its state rather than repeating the finding per lane.
      conflicts: [ $shared_wt[] as $w
                   | { workspace: $w,
                       lanes: ( $tasks
                                | map(select(.endpoint.exists == true
                                             and .paths.worktree.path == $w) | .id)
                                | join(" ") ) } ],
      dispatchable: [ $dispatchable[] | { id, repo, kind, priority_word, title } ],
      quiet: (if $all then [ $quiet_items[] | { id, why, action, state } ] else [] end),
      omitted: [
        (if $all or ($quiet_items | length) == 0 then empty
         else {surface: "quiet lanes (\($quiet_items | length))", reveal: "--all"} end),
        (if $limit > 0 and ($walk_all | length) > $limit
         then {surface: "walk showing \($limit) of \($walk_all | length)",
               reveal: "raise or drop --limit"} else empty end),
        (if ($d_held | length) > 0
         then {surface: "held under an active hold (\($d_held | length))",
               reveal: "tasks-axi list --state held"} else empty end),
        (if ($d_done | length) > 0
         then {surface: "landed and stood down (\($d_done | length))",
               reveal: "the Done section of data/backlog.md"} else empty end) ] }
') || { echo "fm-rounds-queue: projection failed" >&2; exit 1; }

if [ "$FORMAT" = json ]; then
  printf '%s\n' "$MODEL"
  exit 0
fi

TOON=$(printf '%s\n' "$MODEL" | fm_toon_encode) ||
  { echo "fm-rounds-queue: TOON rendering failed" >&2; exit 1; }
printf '%s\n' "$TOON"
