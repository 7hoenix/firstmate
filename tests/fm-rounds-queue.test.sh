#!/usr/bin/env bash
# Behavior tests for the /rounds triage-queue projection.
#
# Every case drives fm-rounds-queue.sh from a SYNTHETIC snapshot via
# FM_ROUNDS_SNAPSHOT, so each classification branch is exercised exactly without a
# real worktree, backend, or no-mistakes install. Covers the union set, the three
# drop rules, both hold-gate directions, every contradiction detector, the
# captain-owned reasons, the severity tiers that keep bookkeeping drift from
# outranking a live decision, priority ordering with unset treated as medium, the
# fleet-level workspace-conflict surface, --limit disclosure, and TOON/JSON parity.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROUNDS="$ROOT/bin/fm-rounds-queue.sh"
TMP_ROOT=$(fm_test_tmproot fm-rounds)
# fm_test_tmproot registers its EXIT-trap cleanup inside the command-substitution
# subshell, so the directory is removed as that subshell exits. Existing suites
# survive it only because they mkdir -p a subdirectory before every write; this
# suite writes fixture files into the root directly, so recreate it explicitly.
mkdir -p "$TMP_ROOT"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# --- fixture plumbing --------------------------------------------------------

# snapshot_stub <json-file> writes an executable that prints that snapshot,
# standing in for bin/fm-fleet-snapshot.sh --json.
snapshot_stub() {  # <json-file>
  local stub="$TMP_ROOT/stub-$$-${RANDOM}.sh"
  cat > "$stub" <<SH
#!/usr/bin/env bash
cat '$1'
SH
  chmod +x "$stub"
  printf '%s\n' "$stub"
}

# run_rounds <json-file> [args...] echoes the JSON model for that snapshot.
run_rounds() {  # <json-file> [args...]
  local snap=$1 stub
  shift
  stub=$(snapshot_stub "$snap")
  FM_ROUNDS_SNAPSHOT="$stub" FM_ROUNDS_TODAY=2026-07-30 "$ROUNDS" --json "$@"
}

# task <id> <kind> <state> <source> <endpoint-exists> <ndecisions> [worktree] [mode] [pr] [report-present]
task() {
  local id=$1 kind=$2 st=$3 src=$4 ep=$5 nd=$6
  local wt=${7:-/wt/$1} mode=${8:-no-mistakes} pr=${9:-null} rep=${10:-false}
  local decs='[]'
  [ "$nd" -eq 0 ] || decs='[{"key":"default","verb":"needs-decision","summary":"pick A or B"}]'
  jq -n --arg id "$id" --arg kind "$kind" --arg st "$st" --arg src "$src" \
        --arg wt "$wt" --arg mode "$mode" --argjson ep "$ep" \
        --argjson decs "$decs" --argjson rep "$rep" \
        --argjson pr "$(if [ "$pr" = null ]; then echo null; else jq -n --arg p "$pr" '$p'; fi)" '
    { id:$id, kind:$kind, mode:$mode, harness:"claude", backend:"tmux",
      paths:{ meta:{path:"/m",present:true},
              status_log:{path:"/s",present:true,kind:"event_history",
                          last_event:{state:"working",note:"n",raw:"working: n"}},
              worktree:{path:$wt,present:true},
              home:{path:null,present:false},
              report:{path:"/r/report.md",present:$rep} },
      current_state:{ state:$st, source:$src, detail:"d", raw:"r" },
      endpoint:{ target:"s:w:p", exists:$ep, agent_alive:"not_checked" },
      pr:{ url:$pr, source:(if $pr==null then "absent" else "meta" end) },
      hints:{ pending_decision:(($decs|length)>0), blocked_event:false,
              open_decisions:$decs, scout_report_present:$rep, last_event_text:"t" } }'
}

# row <id> <state> <kind> [priority] [hold] [hold_until] [blocked_by] [completion-verb]
row() {
  local id=$1 st=$2 kind=$3 prio=${4:-} hold=${5:-} until=${6:-} blocked=${7:-} comp=${8:-}
  jq -n --arg id "$id" --arg st "$st" --arg kind "$kind" \
        --arg prio "$prio" --arg hold "$hold" --arg until "$until" \
        --arg blocked "$blocked" --arg comp "$comp" '
    def nn: if . == "" then null else . end;
    { order:1, state:$st, structured:true, id:$id, checked:false,
      title:("title of " + $id), repo:"demo", kind:$kind,
      priority:($prio|nn), blocked_by:($blocked|nn), blocked_reason:null,
      hold:($hold|nn), hold_kind:(if ($hold|nn)==null then null else "captain" end),
      hold_until:($until|nn),
      since:"2026-07-01", merged:null, reported:null, done:null,
      completion:{verb:($comp|nn),date:null}, links:[], pr_url:null,
      report_path:null, local_note:null, raw:("- [ ] " + $id), body_lines:[],
      body_excerpt:null }'
}

# snapshot <out-file> <tasks-json-array> <records-json-array>
snapshot() {  # <out> <tasks[]> <records[]>
  jq -n --argjson tasks "$2" --argjson recs "$3" '
    { schema:"fm-fleet-snapshot.v1", fm_home:"/home",
      roots:{}, backlog:{path:"/b",present:true,records:$recs},
      tasks:$tasks, scout_reports:[],
      secondmate_landed:{records:[],truncated:[],unreadable:[]},
      secondmate_guidance:null }' > "$1"
}

why_of() { jq -r --arg id "$2" '.walk[] | select(.id==$id) | .why' <<<"$1"; }
bucket_of() { jq -r --arg id "$2" '.walk[] | select(.id==$id) | .bucket' <<<"$1"; }
pos_of() { jq -r --arg id "$2" '.walk[] | select(.id==$id) | .pos' <<<"$1"; }

# --- drops -------------------------------------------------------------------

SNAP="$TMP_ROOT/drops.json"
snapshot "$SNAP" \
  "[$(task sub-1 secondmate working pane true 0)]" \
  "[$(row landed-1 'done' ship),
    $(row held-1 queued ship '' 'captain says wait' ''),
    $(row gated-future queued ship '' 'wait for it' 2026-08-05)]"
OUT=$(run_rounds "$SNAP")

[ "$(jq -r '.count_secondmate' <<<"$OUT")" = 1 ] || fail "secondmate not dropped"
[ "$(jq -r '.count_landed' <<<"$OUT")" = 1 ] || fail "landed-with-no-lane not dropped"
[ "$(jq -r '.count_held' <<<"$OUT")" = 2 ] || fail "active holds not dropped"
[ "$(jq -r '.count_walk' <<<"$OUT")" = 0 ] || fail "walk should be empty, all dropped"
assert_contains "$OUT" 'held under an active hold' "held drop is disclosed in omitted[]"
pass "secondmates, landed-and-gone rows, and active holds are dropped silently"

# A hold whose --until date has ARRIVED is not a drop: the gate fired.
SNAP="$TMP_ROOT/gate.json"
snapshot "$SNAP" "[]" "[$(row gated-now queued ship '' 'wait for it' 2026-07-30)]"
OUT=$(run_rounds "$SNAP")
[ "$(jq -r '.count_held' <<<"$OUT")" = 0 ] || fail "arrived gate must not count as held"
[ "$(why_of "$OUT" gated-now)" = gate-arrived ] || fail "arrived gate should surface"
pass "a hold gate that has arrived surfaces instead of suppressing (inactive ON the date)"

# --- contradiction detectors -------------------------------------------------

SNAP="$TMP_ROOT/contra.json"
snapshot "$SNAP" \
  "[$(task dead-run ship parked run-step false 0),
    $(task failed-landed ship failed run-step true 0),
    $(task paused-gone ship paused status-log false 0)]" \
  "[$(row dead-run in_flight ship),
    $(row failed-landed 'done' ship '' '' '' '' merged),
    $(row paused-gone in_flight ship)]"
OUT=$(run_rounds "$SNAP")

[ "$(why_of "$OUT" dead-run)" = dead-lane-run ] || fail "dead-lane-run not detected"
[ "$(why_of "$OUT" failed-landed)" = failed-but-landed ] || fail "failed-but-landed not detected"
[ "$(why_of "$OUT" paused-gone)" = paused-but-gone ] || fail "paused-but-gone not detected"
for id in dead-run failed-landed paused-gone; do
  [ "$(bucket_of "$OUT" "$id")" = unreliable ] || fail "$id must be unreliable, never a state claim"
done
[ "$(jq -r '.count_contradiction' <<<"$OUT")" = 3 ] || fail "all three should be severity contradiction"
pass "every contradiction detector fires and lands in the unreliable bucket"

# The regression that motivated dead-lane-run: a landed lane sharing a recycled
# workspace slot inherits the live occupant's run-step, so a run-step reading on a
# lane whose endpoint is gone must never be presented as that lane's state.
[ "$(jq -r '.walk[0].id' <<<"$OUT")" = dead-run ] ||
  fail "contradictions must walk first"
pass "a run-step attributed to a lane with no endpoint is refused as a state claim"

# --- bookkeeping drift, and the tier that keeps it below live decisions -------

SNAP="$TMP_ROOT/tier.json"
snapshot "$SNAP" \
  "[$(task needs-me ship parked run-step true 1),
    $(task orphan-lane ship working pane true 0)]" \
  "[$(row needs-me in_flight ship),
    $(row ghost-row in_flight ship)]"
OUT=$(run_rounds "$SNAP")

[ "$(why_of "$OUT" orphan-lane)" = no-backlog-row ] || fail "lane with no row not detected"
[ "$(why_of "$OUT" ghost-row)" = no-lane ] || fail "row with no lane not detected"
[ "$(jq -r '.count_bookkeeping' <<<"$OUT")" = 2 ] || fail "both should be severity bookkeeping"
[ "$(pos_of "$OUT" needs-me)" -lt "$(pos_of "$OUT" orphan-lane)" ] ||
  fail "a live decision must outrank bookkeeping drift"
[ "$(pos_of "$OUT" needs-me)" -lt "$(pos_of "$OUT" ghost-row)" ] ||
  fail "a live decision must outrank bookkeeping drift"
pass "bookkeeping drift is surfaced but never outranks a decision waiting on the captain"

# --- captain-owned reasons ---------------------------------------------------

SNAP="$TMP_ROOT/captain.json"
snapshot "$SNAP" \
  "[$(task dec ship parked run-step true 1),
    $(task blk ship blocked pane true 0),
    $(task prr ship 'done' pane true 0 /wt/prr no-mistakes https://x/pull/1),
    $(task loc ship 'done' pane true 0 /wt/loc local-only),
    $(task rep scout 'done' pane true 0 /wt/rep no-mistakes null true),
    $(task reap ship paused status-log true 0)]" \
  "[$(row dec in_flight ship), $(row blk in_flight ship), $(row prr in_flight ship),
    $(row loc in_flight ship), $(row rep in_flight scout),
    $(row reap 'done' ship '' '' '' '' merged)]"
OUT=$(run_rounds "$SNAP")

[ "$(why_of "$OUT" dec)" = decision-waiting ] || fail "open decision not surfaced"
[ "$(why_of "$OUT" blk)" = blocked ] || fail "blocked not surfaced"
[ "$(why_of "$OUT" prr)" = pr-ready ] || fail "pr-ready not surfaced"
[ "$(why_of "$OUT" loc)" = review-diff ] || fail "local-only diff review not surfaced"
[ "$(why_of "$OUT" rep)" = report-ready ] || fail "scout report not surfaced"
[ "$(why_of "$OUT" reap)" = ready-to-stand-down ] || fail "landed-but-running not surfaced"
[ "$(jq -r '.count_captain' <<<"$OUT")" = 6 ] || fail "all six should be captain items"
pass "all six captain-owned reasons classify correctly"

# --- quiet bucket ------------------------------------------------------------

SNAP="$TMP_ROOT/quiet.json"
snapshot "$SNAP" \
  "[$(task busy ship working pane true 0),
    $(task selfgate ship parked run-step true 0),
    $(task waiting ship paused status-log true 0)]" \
  "[$(row busy in_flight ship), $(row selfgate in_flight ship),
    $(row waiting in_flight ship), $(row blocked-q queued ship '' '' '' busy)]"
OUT=$(run_rounds "$SNAP")

[ "$(jq -r '.count_walk' <<<"$OUT")" = 0 ] || fail "no quiet lane may reach the walk"
[ "$(jq -r '.count_quiet' <<<"$OUT")" = 4 ] || fail "four lanes should be quiet"
[ "$(jq -r '.quiet | length' <<<"$OUT")" = 0 ] || fail "quiet must be hidden by default"
assert_contains "$OUT" 'quiet lanes (4)' "hidden quiet lanes are disclosed in omitted[]"

OUT_ALL=$(run_rounds "$SNAP" --all)
[ "$(jq -r '.quiet | length' <<<"$OUT_ALL")" = 4 ] || fail "--all must reveal quiet lanes"
[ "$(jq -r '.quiet[] | select(.id=="selfgate") | .action' <<<"$OUT_ALL")" = steer ] ||
  fail "a run parked with no decision is the crew's own gate: steer, do not ask"
[ "$(jq -r '.quiet[] | select(.id=="waiting") | .action' <<<"$OUT_ALL")" = pause-ack ] ||
  fail "a declared wait should be deferred with a pause-ack"
pass "working, self-gated, declared-wait, and blocked-queued lanes stay silent"

# --- dispatchable is batched, never walked -----------------------------------

SNAP="$TMP_ROOT/dispatch.json"
snapshot "$SNAP" "[]" \
  "[$(row ready-1 queued ship), $(row ready-2 queued ship),
    $(row blocked-on queued ship '' '' '' ready-1)]"
OUT=$(run_rounds "$SNAP")
[ "$(jq -r '.count_dispatchable' <<<"$OUT")" = 2 ] || fail "unblocked queued work is dispatchable"
[ "$(jq -r '.count_walk' <<<"$OUT")" = 0 ] || fail "dispatchable is firstmate's call, never walked"
[ "$(jq -r '.count_quiet' <<<"$OUT")" = 1 ] || fail "queued work behind an open blocker stays quiet"
pass "dispatchable work is batched and queued-behind-a-blocker stays quiet"

# --- priority ordering -------------------------------------------------------

SNAP="$TMP_ROOT/prio.json"
snapshot "$SNAP" \
  "[$(task p-urgent ship blocked pane true 0),
    $(task p-unset ship blocked pane true 0),
    $(task p-someday ship blocked pane true 0),
    $(task p-high ship blocked pane true 0)]" \
  "[$(row p-urgent in_flight ship 0), $(row p-unset in_flight ship),
    $(row p-someday in_flight ship 4), $(row p-high in_flight ship 1)]"
OUT=$(run_rounds "$SNAP")

[ "$(jq -r '[.walk[].id] | join(",")' <<<"$OUT")" = "p-urgent,p-high,p-unset,p-someday" ] ||
  fail "walk must sort by priority with unset between high and someday"
[ "$(jq -r '.walk[] | select(.id=="p-unset") | .priority_word' <<<"$OUT")" = medium ] ||
  fail "unset priority must present as medium"
[ "$(jq -r '.walk[] | select(.id=="p-unset") | .priority_set' <<<"$OUT")" = false ] ||
  fail "unset priority must be flagged so the presenter can offer to set it"
[ "$(jq -r '.walk[] | select(.id=="p-urgent") | .priority_word' <<<"$OUT")" = urgent ] ||
  fail "priority 0 must present as urgent"
pass "priority orders the walk, and unset sorts as medium while staying flagged"

# --- workspace conflicts are one fleet fact, not N items ---------------------

SNAP="$TMP_ROOT/conflict.json"
snapshot "$SNAP" \
  "[$(task live-a ship blocked pane true 0 /shared/slot),
    $(task live-b ship blocked pane true 0 /shared/slot),
    $(task dead-c ship unknown none false 0 /other/slot),
    $(task live-d ship blocked pane true 0 /other/slot)]" \
  "[$(row live-a in_flight ship), $(row live-b in_flight ship),
    $(row dead-c in_flight ship), $(row live-d in_flight ship)]"
OUT=$(run_rounds "$SNAP")

[ "$(jq -r '.count_conflicts' <<<"$OUT")" = 1 ] ||
  fail "only the path claimed by TWO LIVE lanes is a conflict"
[ "$(jq -r '.conflicts[0].lanes' <<<"$OUT")" = "live-a live-b" ] || fail "conflict lanes wrong"
[ "$(jq -r '.walk[] | select(.id=="live-a") | .workspace_ambiguous' <<<"$OUT")" = true ] ||
  fail "a lane in a conflict must be flagged workspace_ambiguous"
[ "$(jq -r '.walk[] | select(.id=="live-d") | .workspace_ambiguous' <<<"$OUT")" = false ] ||
  fail "sharing a path with a DEAD lane is not ambiguous: the live lane owns it"
[ "$(jq -r '[.walk[] | select(.why=="shared-workspace")] | length' <<<"$OUT")" = 0 ] ||
  fail "a shared workspace must never become a per-lane walk item"
pass "a shared workspace is reported once as a fleet fact, with affected lanes flagged"

# --- limit, parity, usage ----------------------------------------------------

OUT=$(run_rounds "$TMP_ROOT/captain.json" --limit 2)
[ "$(jq -r '.count_walk' <<<"$OUT")" = 2 ] || fail "--limit must bound the walk"
assert_contains "$OUT" 'walk showing 2 of 6' "truncation must be disclosed, never silent"
pass "--limit bounds the walk and discloses what it dropped"

STUB=$(snapshot_stub "$TMP_ROOT/captain.json")
TOON=$(FM_ROUNDS_SNAPSHOT="$STUB" FM_ROUNDS_TODAY=2026-07-30 "$ROUNDS")
assert_contains "$TOON" 'schema: fm-rounds.v1' "TOON is the default output"
assert_contains "$TOON" 'walk[6]{pos,id,bucket,severity,why,' "TOON renders the tabular walk"
assert_not_contains "$TOON" '"walk":' "TOON default must not emit JSON"
[ "$(jq -r '.count_captain' <<<"$(run_rounds "$TMP_ROOT/captain.json")")" = 6 ] ||
  fail "JSON parity form must carry the same model"
pass "TOON is the default and --json is the parity form of one model"

OUT=$(FM_ROUNDS_SNAPSHOT="$STUB" "$ROUNDS" --limit 2>&1) && fail "--limit with no value must exit non-zero"
assert_contains "$OUT" 'needs a value' "--limit with no value explains itself"
OUT=$(FM_ROUNDS_SNAPSHOT="$STUB" "$ROUNDS" --limit x 2>&1) && fail "non-numeric --limit must exit non-zero"
assert_contains "$OUT" 'non-negative integer' "non-numeric --limit explains itself"
OUT=$("$ROUNDS" --help)
assert_contains "$OUT" 'usage: fm-rounds-queue.sh' "--help prints usage"
pass "argument validation and --help behave"

# --- read-only ---------------------------------------------------------------

# Measure with the stub already in place, so only the projection is under test and
# not this harness writing its own fixtures.
inventory() { find "$TMP_ROOT" -type f -exec ls -ld {} \; | sort; }
STATE_BEFORE=$(inventory)
FM_ROUNDS_SNAPSHOT="$STUB" FM_ROUNDS_TODAY=2026-07-30 "$ROUNDS" --json >/dev/null
FM_ROUNDS_SNAPSHOT="$STUB" FM_ROUNDS_TODAY=2026-07-30 "$ROUNDS" >/dev/null
STATE_AFTER=$(inventory)
[ "$STATE_BEFORE" = "$STATE_AFTER" ] ||
  fail "the projection must not create, remove, or rewrite files"$'\n'"$(diff <(printf '%s\n' "$STATE_BEFORE") <(printf '%s\n' "$STATE_AFTER") || true)"
pass "the projection is read-only in both output modes"
