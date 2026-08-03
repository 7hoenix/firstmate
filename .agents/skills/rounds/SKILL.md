---
name: rounds
description: Walk the outstanding work one item at a time, in captain-set priority order, skipping anything that needs nothing right now. Use when the captain invokes /rounds or asks to go through the open work, do a round of triage, "go through each one", "what needs me", a start-of-day pass, or a mid-day check-in. Reads the fleet through one deterministic projection, presents each actionable item alone with a recommendation, acts on the captain's answer, and defers the rest durably; it never merges, tears down, or resolves a captain-owned finding on its own authority.
user-invocable: true
metadata:
  internal: true
---

# rounds

Walk the outstanding work with the captain, one item at a time, stopping only where something actually needs them.
Making rounds is the whole metaphor: go down the line, look at each one, and move past the ones that need nothing.

This skill owns the CONVERSATION only.
`bin/fm-rounds-queue.sh` owns which items are actionable, in what order, and why; its header and `--help` are the authoritative contract for the set, the drop rules, the buckets, the contradiction detectors, and the sort.
Do not re-derive that classification in prose, and do not hand-probe fleet state to second-guess it.

Not a status report.
`/bearings` answers "where did I leave off" with a broadside read and a dated file, and is contractually read-mostly.
`/rounds` answers "let's go through these" and takes actions on the captain's word.
Never produce a bearings-style four-section digest from here, and never write a report file.

## The walk

1. **Get the queue.**
   Run `bin/fm-rounds-queue.sh`.
   Read `count_*` for the shape, `walk[]` for the ordered items, `conflicts[]` and `dispatchable[]` for the two batched surfaces.
   Every `count_*` describes the full queue before any `--limit`; `shown` is how many `walk[]` entries you actually have, and `walk[].pos` runs 1 to `shown`.

2. **Open with one orienting line, then the first item.**
   One sentence: how many things need them, and that everything else is handled.
   Then present `walk[]` position 1 and stop.

3. **Present exactly one item, then wait.**
   Use the contract below.
   Never present two items in one message, and never present an item plus a "and also..." preview of the next.

4. **Act on the answer, then present the next item in the same message.**
   Record the answer per the table below before moving on, so the next `bin/fm-rounds-queue.sh` run reflects it.
   Presenting the next item IS the continuation - never ask for permission to continue.
   A turn that acts on an answer must END with the next item already presented, so the captain returns to a decision waiting rather than to an offer.
   Banned closers, in every form: "ready for the next one", "say the word", "want me to carry on", "shall I pull item N".
   The only reasons to end a turn without the next item are the queue being empty (go to step 5) or the captain saying to stop.
   This also holds after a mid-walk wake: report the wake, then present the current position 1 in the same message.

5. **Close the walk.**
   Report what was actioned, then the batched surfaces: `dispatchable[]` as ONE confirm line the captain answers, and `conflicts[]` if non-empty.
   Name that work in plain language, recommend starting it, and wait for their word - the queue proves only that nothing is blocking those items on paper, never that they steer clear of work already under way, so starting them is the captain's call and not the walk's.
   If the walk produced a standing preference ("anything touching money is always urgent"), suggest `/stow` in one line and stop.

## Priority

Priority lives in the backlog and nowhere else, as the tasks-axi `priority` field (0-4, 0 highest).
Set it with `tasks-axi add ... --priority <n>` at dispatch or `tasks-axi update <id> --priority <n>` any time.
Speak the captain's words, never the number: **urgent** (0), **high** (1), **medium** (2), **low** (3), **someday** (4).
An item with `priority_set: false` sorts as medium and must be tagged `(no priority set)` in its line, with setting one offered among the actions - that is how the fleet converges on priorities without a backfill pass.

## Presentation contract

This is captain chat, so `AGENTS.md` section 9 applies in full: outcomes not mechanics, no task ids, no "crewmate"/"lane"/"workspace"/"status file"/"no-mistakes", every PR as its full `https://...` URL.
The bearings relaxation does NOT apply here, because that exists only for a gitignored file.

Each `bucket: captain` item renders these six lines and nothing else:

```
[<pos> of <shown>] <project> - <what this work is>       <priority word>
State:    <one sentence: where it actually stands>
Needs:    <one sentence: what is being asked of the captain>
Options:  <A / B / ... verbatim from the finding, when there is a real choice>
I'd say:  <the recommendation, and the one-line why>
Then:     <what happens once they answer>
```

- Omit `Options:` for a yes/no.
- `I'd say:` is mandatory. Presenting options without a recommendation moves work onto the captain instead of off.
- More than two findings, or a real tradeoff: replace the block with a `lavish-axi` board and one chat line pointing at it. The captain has a standing preference for rich review surfaces over chat summaries for anything with structure.
- When `workspace_ambiguous` is true, add one line: the state reading for this one may be attributed to other work, and offer the check. Never drop the caveat silently.
- When `drift` is set, the records disagree with reality on this item as well: add one line naming that gap and offer to close it, after the ask it was presented for.
- When `blocked_by_open` is set, say that the item is still waiting on other work, and how many pieces of that work are still open, and never present it as ready to start.
  Its values are machine-readable identifiers rather than captain-facing text, and the queue carries no title to translate them into, so never read them out.

A `bucket: unreliable` item renders a DIFFERENT block, and never asserts a state:

```
[<pos> of <shown>] <project> - <work>       ⚠ state unclear
What I can see:  <the contradiction, plainly>
What I don't:    <what cannot be determined without checking>
I'd say:         <the specific check to run>
```

Verify with `bin/fm-peek.sh <endpoint>`, `bin/fm-crew-state.sh <id>`, or `gh-axi pr view` for a merge question.
`severity: contradiction` means a state claim is untrustworthy and is worth resolving before items that depend on state.
`severity: bookkeeping` means the records drifted - real, but it poisons nothing, so keep it brief.
Drift never takes this block away from a live piece of work that also needs the captain: that item stays a `bucket: captain` item and carries its gap in `drift`.
Drift on work that is not actually running stays here, because there is nothing under way for an ask to be about until the records and reality agree.

## Recording the answer

The walk keeps NO cursor and no session state.
"Handled" is recorded where the handling belongs, and the queue is recomputed from that.
This is what makes the walk survive an interruption, a context reset, and a restart.

| Captain's answer | Record it as |
| --- | --- |
| Answers a decision | relay through the gate the finding came from, so the crew closes it with its `resolved [key=...]` line |
| "Merge it" | `bin/fm-pr-merge.sh <id> <full PR URL>` |
| "Not now" | `tasks-axi hold <id> --reason "<their words>" --kind captain --until <YYYY-MM-DD>`, dating it far enough out to be a real deferral and saying the date back to them |
| "Not until Friday" | `tasks-axi hold <id> --reason "<their words>" --until <YYYY-MM-DD>` |
| "Leave it running" | `bin/fm-pause-ack.sh <id>` |
| "That's urgent" / "that's low" | `tasks-axi update <id> --priority <n>` |
| "Stand it down" | peek the endpoint for running processes FIRST, then `bin/fm-teardown.sh <id>` |
| Missing backlog row | `tasks-axi add <id> "<title>" --kind <k> --repo <r> --start` |
| Acts on a `gate-arrived` item | `tasks-axi unhold <id>` FIRST, then take the action they asked for |

Never record a skip with no reason - that silently loses the item.
Every recorded hold is visible in the backlog, but only a dated one comes back on its own: a `--until` hold stops suppressing the item on and after that date, and the item returns to the walk as `gate-arrived`.
A hold recorded with no `--until` never expires, so it suppresses the item until someone lifts it by hand - which is why "Not now" gets a date.
An arrived gate is not self-clearing either: dispatching the item leaves its hold tokens on the row, so `tasks-axi unhold <id>` is what actually closes a `gate-arrived` item.
Either way a hold never hides a live problem: an item with an open decision, or one that goes blocked or failed, walks anyway.

## Surviving interruption

The supervision watcher injects wakes into this same conversation, constantly, and a wake may well concern an item still in the queue.

- **A wake arrives mid-walk:** handle it per `AGENTS.md` section 8 first, then resume by re-running `bin/fm-rounds-queue.sh` and presenting the new position 1. If the wake resolved the item that was on screen, it is simply gone from the recomputed queue - nothing to reconcile.
- **The captain answers out of order:** act on what they said, record it, recompute, present the new first item. Out-of-order is input, not an error.
- **The captain goes quiet:** stop presenting further items, but leave the current one standing. Do not check in, do not nag, and do not replace it with a summary or a "let me know" - the captain should come back to a decision already waiting, not to an offer to resume. Supervision stays live per section 8; the next message or wake resumes normally.
- **Re-invoked later:** identical to being resumed. There is no session to be inside or outside of.

## What this skill must never do

Automating triage must not automate consent.
This skill changes which question is asked and in what order; it changes no approval authority.

1. Never merge without the captain's word in this walk (`AGENTS.md` prime directive 2). Under a project's `yolo=on` the existing relaxation applies unchanged - but `yolo` is read from the project's recorded posture, never inferred because the captain is answering decisively.
2. Never resolve an ask-user finding on the captain's behalf under `yolo=off`. Relay it verbatim.
3. Never tear down anything without asking, and never treat a merge as teardown consent. A pane may host captain-driven work long after its task looks finished, so the pre-teardown peek is mandatory even after a yes.
4. Never dispatch work the captain has held, and never start the batch of ready work without their yes - that batch is a proposal, not a decision.
5. Never change a priority the captain did not ask to change. Propose, do not assign.
6. Never end a turn blind: if work is in flight, the harness supervision protocol must be live behind every message that waits on the captain.
7. Never act on an item the captain was not shown. The `quiet` bucket's `action` field is descriptive - it names what an item is waiting on, not a licence to act on it. In particular, do not acknowledge a declared wait and do not steer a self-parked crew from inside a walk. Acknowledging a wait has exactly one route, through the recording table: the captain sees the item, says "leave it running", and only then does `bin/fm-pause-ack.sh` run. That ack resets the pause window and clears the throttle that eventually forces a forgotten external wait back to the supervisor's attention, so a blanket ack across every paused lane - twice a day, on a start-of-day and a mid-day pass - would retire that safety net entirely. `AGENTS.md` section 8 scopes the ack to a confirmed recheck for that reason, and a silent steer repeats without bound in the same way.
