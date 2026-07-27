# Worker-hosted services in a visible, self-reaped tab

`bin/fm-worker-api.sh` lets a crewmate stand up a long-lived service - a local API (`wrangler dev`), a dev server (`vite`), a mock backend - in a **visible, named tab in the worker's own terminal container**, instead of hiding it in a sub-agent or a background process.

A sub-agent is meant to do a task and return, not host a server; a background `&` is invisible to the captain and to firstmate.
This helper opens the service in a tab the captain can watch and hop into, gives firstmate a searchable log to supervise it cheaply, and registers it so teardown reaps it - no orphaned tabs or processes.

Design and empirical basis: `data/worker-api-tab-4d/rfc.md` and `data/worker-api-tab-4d/report.md`.

## How a worker uses it

```
fm-worker-api.sh up   [--label <suffix>] [--port <n>] [--] <launch command...>
fm-worker-api.sh down [--label <suffix>] [--all]
fm-worker-api.sh restart [--label <suffix>] [--port <n>] [--] <launch command...>
fm-worker-api.sh status [--all]
fm-worker-api.sh logs [--label <suffix>] [--follow]
fm-worker-api.sh logs --prune-before <YYYY-MM-DD>
fm-worker-api.sh sweep [--state <dir>] [--dry-run]
```

`up` self-locates the worker's own container, picks a free port, opens the service tab, launches the command with `PORT` exported, tees the output to a dated log, registers the tab, and prints the URL once the port is accepting connections.
Every ship and scout brief carries a one-line pointer to this helper (`bin/fm-brief.sh`), because the need for a live service is often discovered mid-task.

`sweep` is firstmate's verb, not the worker's - see "Orphan sweep" below.
`status --all` and `down --all` widen the same view across every label; v1 registers one, so they matter mainly to firstmate and to tests.

## How it works

### Self-location (no firstmate identity needed)

A crewmate pane carries no `FM_HOME` or task id, so the helper reads the container from the environment the backend injects into every pane:

- **herdr**: `HERDR_ENV=1` selects herdr; `HERDR_WORKSPACE_ID` is the worker's own workspace; the session is `${HERDR_SESSION:-default}` (herdr sets `HERDR_SESSION` in a named session, and omits it in the default one).
- **tmux**: a non-empty `$TMUX` selects tmux; the session comes from `tmux display-message -p '#{session_name}'`.

`$TMUX` is checked first: a tmux started inside a herdr pane sets both, and tmux then correctly wins for a nested tmux because the worker's shell lives in that tmux session (matching `fm_backend_detect`).
Any other backend (zellij, cmux, orca) refuses `up` with a clear message - v1 supports tmux and herdr.

cmux cannot be mis-detected as tmux, despite both being terminal hosts: cmux marks its panes with `CMUX_WORKSPACE_ID` and never sets `$TMUX` itself (`docs/cmux-backend.md`).
A `$TMUX` that *is* present inside a cmux tab belongs to a real nested tmux, which genuinely is the innermost layer and correctly wins.
`tests/fm-worker-api.test.sh` pins the refusal.

### The sibling tab

The tab-creation semantics live in the backend adapters (one owner), dispatched through `bin/fm-backend.sh`:

| Operation | tmux (`bin/backends/tmux.sh`) | herdr (`bin/backends/herdr.sh`) |
| --- | --- | --- |
| `fm_backend_sibling_up` | `new-window -dP -F '#{window_id}' -t <ses>: -n fm-<id>-<suffix>` then `send-keys "<cmd>" Enter` | `tab create --workspace $HERDR_WORKSPACE_ID --label fm-<id>-<suffix>` then `pane run <pane> "<cmd>"` |
| `fm_backend_sibling_down` | `kill-window` (kills every pane in the window, so the server dies with it) | `pane close` (closing a tab's only pane closes the tab and its server) |

This is **not** herdr lifecycle work: it only creates a tab in the worker's already-live workspace, exactly like `fm_backend_herdr_create_task`, so it needs no herdr-lab isolation.

### Reap registry - the teardown contract

`up` appends one TAB-separated line per live service to `state/<id>.api-tabs`:

```
<label>\t<backend>\t<endpoint>\t<port>\t<logfile>
```

- The endpoint is `<session>:<window_id>` (tmux) or `<session>:<pane_id>` (herdr).
- `down` removes the line and closes the tab; `bin/fm-teardown.sh` reads every line, closes each endpoint (killing the orphan), then deletes the registry file.
- **Load-bearing**: teardown, not the worker, is the guaranteed reaper - workers crash, teardown always runs. Without this, a service tab and its process survive teardown, still serving (reproduced on both backends: `data/worker-api-tab-4d/report.md`).

Teardown reaps the service tabs as soon as its safety gates have passed, **before** it returns the worktree.
The order is deliberate: a service tab is a separate terminal endpoint with no dependency on the worktree, and reaping it after the worktree return meant a failed return aborted teardown with the service still live - the very orphan this feature prevents.

`bin/fm-spawn.sh` exports `FM_WORKER_API_REGISTRY` and `FM_WORKER_API_LOGDIR` into the worker's pane (like `GOTMPDIR`); `--registry`/`--logdir` override them for manual use and tests.

### Orphan sweep - the recovery-side backstop

Teardown only reaps tasks that reach teardown.
A task that crashes, loses its `state/<id>.meta`, or is discarded with `--force` never gets there, and its service tab and server process would otherwise survive indefinitely.

`fm-worker-api.sh sweep --state <dir>` closes the endpoints in every `state/*.api-tabs` whose task no longer has a `state/<id>.meta`, removes the registry, and keeps the logs.
`bin/fm-bootstrap.sh` runs it as one of its locked mutating sweeps at session start and prefixes each line with `WORKER_API_SWEEP:`; a healthy fleet is silent.
A registry that was already emptied by `down` is cleaned up without printing anything, because the line means "a task died with a service still running" and would otherwise send firstmate chasing a task that shut down cleanly.
Registries belonging to live tasks are never touched, so the sweep cannot reap a running worker's service.

**The boundary is deliberately "no meta", not "no live pane".**
A task whose pane died but whose `state/<id>.meta` still exists is *not* swept, because a present meta means firstmate still tracks that task and reconciles it during recovery - a pane can be absent while the task is between agent restarts, and reaping its service on a transient probe failure would kill live work.
Teardown handles that task when it runs; this sweep only covers the case where the record itself is gone and nothing else ever will.

### Is the service tab still there?

`fm_backend_sibling_alive` (`bin/fm-backend.sh`) answers by exit status: `0` alive, `1` confidently gone, `2` unknown.
Only a confident `1` is ever acted on, so an unreadable backend server is never mistaken for a dead service.

It exists because the generic `fm_backend_target_exists` **cannot** answer this on tmux: `tmux display-message -p -t <killed or nonexistent window>` exits 0 and prints the session's current pane, so every tmux endpoint reads as alive.
`sibling_alive` enumerates real window ids with `list-windows` instead, and separates "window gone" from "cannot read the server" with `has-session`.
Without it, clearing a dead service so it stops blocking the worker's one slot would silently never fire on tmux.
`tests/fm-backend-tmux-smoke.test.sh` pins both the correct verdict and the `display-message` behavior that motivates it.

### Deterministic port

The port is a deterministic candidate from the worktree path (`FM_WORKER_API_PORT_BASE` default 8800, `+ cksum(worktree) mod FM_WORKER_API_PORT_RANGE` default 200), then the first free port at/above it, printed so it is targetable.
`--port` pins an explicit value.
`PORT` is exported into the service's shell; services that read a port from a flag should be passed one in the launch command (e.g. `wrangler dev --port "$PORT"`).
The launch command runs as a shell line, so `$PORT`, pipes, and `&&` work, and multi-word arguments must be quoted as they would be for a shell.

**The chosen port must be free before launch, and `up` refuses if it is not.**
Readiness is "something is now listening on the port", which only means *our* service is up if the port was ours to bind.
Launching onto an occupied port would otherwise report a healthy service while the real one died with `address already in use`.
A pinned `--port` that is taken is an error naming the conflict.
A `restart` whose old listener has not released the socket within 5s (a draining service, a forked child still holding it) falls back to a freshly derived port instead of failing: the old entry is already unregistered by then, so refusing would leave the worker with nothing at all.

Selection through **bind** runs under a machine-wide `mkdir` lock (`$TMPDIR/fm-worker-api-port.lock`, stale after a minute), so two concurrent `up`s - different workers, or different repos on the same machine - cannot both claim the same port.
Holding the lock only until *registration* is not enough, and that was measured: five concurrent `up`s produced two workers on port 8837, the loser dying with `Address already in use` while `up` reported `API up` and `status` showed `[serving]` - because the readiness probe was seeing the *other* worker's listener.
The lock therefore stays held until the service has actually bound.

The lock carries an owner token, so a holder that gets declared stale and superseded cannot later delete its successor's lock.
This is best-effort coordination between cooperating same-user workers, not a secure mutex.
Failing to take the lock never blocks a launch; it only forfeits the race protection, and an unwritable lock path says so immediately instead of burning the full wait.

A socket probe cannot see a port that another worker has *claimed* but whose service has not bound yet - the case where a slow service outlasts the readiness wait and the lock is released anyway.
So port selection also consults every `state/*.api-tabs` in the state dir as the durable claim record, and both the derived and the pinned path skip or refuse a port another task already records.
Only a **live** task's claim counts: a registry whose task has no `state/<id>.meta` is waiting for `sweep`, and honoring its claim would let a dead task reserve a port until the next session start.

**Residual risk**: an unrelated process (nothing to do with firstmate) can still grab the port between the free check and the service's own bind.
Readiness is a bare TCP connect, not a health check, so a service that binds the port but is not yet answering requests still reads as up.

### Logs are collected, not deleted

The service's stdout+stderr is teed to a dated file that **survives teardown**:

```
$FM_WORKER_API_LOGDIR/<id>-<label>-<YYYY-MM-DD-HHMMSS>.log   (default: data/api-logs/)
```

- **Visual stream** = the tab; **searchable stream** = this log. One source, two views, cannot drift.
- Firstmate greps it for readiness/errors instead of peeking the pane; the captain searches history after scrollback rolls off.
- Logs accumulate and are pruned in bulk later with `logs --prune-before <YYYY-MM-DD>` (or a plain `rm`), never per-task.
- The stamp carries seconds so an `up`/`restart` inside the same minute cannot interleave two runs into one file. Two runs inside the same *second* still can, so `up` records the log's byte offset before launching and only ever reads back its own output - otherwise a previous run's exit marker would be read as this run's failure, and the failure path closes the tab and unregisters, killing a healthy service.
- Pruning validates the date against the local `find` before deleting. BSD/macOS `find` rejects far-future dates that GNU `find` accepts, and the old code swallowed that error and printed `pruned 0 log file(s)` with exit 0 - a false success. An unparseable date is now an error.

#### Line buffering (why the launch line is wrapped)

A process's stdout is fully buffered when it is a pipe, so a startup banner (`Serving HTTP on ...`, `ready on :PORT`) can sit unflushed in the service's own buffer and be **lost** when teardown kills it.
Only line-buffered stderr survived, which broke the log as a readiness source - exactly what firstmate is meant to grep.

`up` therefore runs the command under a `script` pty, which every runtime line-buffers because stdout is a terminal.
`stdbuf` is only a fallback for a system with no `script`, because it does **not** work here: it overrides libc stdio, which Python's own io layer bypasses, and macOS SIP strips the injection for system binaries.
Measured on macOS, 2026-07-27, `python3 -m http.server` killed after 2s:

| Launch form | Banner in the log |
| --- | --- |
| plain pipe | lost |
| `stdbuf -oL -eL` | lost |
| `script -q /dev/null` | **present** |

The pty path writes CR line endings into the log; that is the accepted cost of not losing the output entirely.

Each `script` form is probed by actually running it on `true`, so the probe measures usability rather than just flavor: a `script` that exists but cannot work here (no pty available in a container, for instance) falls through to `stdbuf` or a plain pipeline instead of making every launch fail.
util-linux is tried with `-e` first, because without it `script` returns its own status and the exit marker would report `rc=0` for every failed command.
It is deliberately not probed with `script --version`: BSD `script` reads that as a typescript *filename* and would hang on an interactive session.

**The launch line is evaluated by `bash -c`, not by the tab's interactive shell.**
A pty needs a command to run, and the launch command is a shell *line*, so a shell has to evaluate it.
`$PORT`, pipes, `&&`, and quoting all work exactly as documented, because the whole line is handed to `bash -c` as one argument and re-parsed there.
The exported environment (including `PATH`) is inherited, so ordinary binaries resolve normally.
What does **not** apply is anything that only exists in an interactive login shell - a `zsh` alias, or a version-manager shell function defined in `.zshrc`.
Invoke those through their real binary, or wrap them in a script with a shebang.

#### The shell-line trap

Because the launch command is a shell *line*, the argument boundaries your own shell created are **not** preserved - the words are joined with spaces and re-parsed.
This is the documented consequence of the shell-line design, and it is easy to hit:

```sh
# WRONG - the quotes are consumed by your shell, and the tab runs: python3 -c print("hi there")
fm-worker-api.sh up -- python3 -c 'print("hi there")'

# RIGHT - quote it as it must appear on the far side
fm-worker-api.sh up -- python3 -c '"'"'print("hi there")'"'"'
fm-worker-api.sh up -- 'python3 -c "print(\"hi there\")"'
```

The same re-parsing means a literal argument containing `;`, `|`, `$`, backticks, or a glob is interpreted as shell syntax rather than passed through.
When a command needs exact argument boundaries, put it in a small script with a shebang and launch that.
A mis-quoted line usually exits immediately, which `up` now reports as `API FAILED` with the log tail rather than a silent stall.

The launch line also appends `[fm-worker-api] service exited rc=<n>` when the command returns.
`up` watches for it, so a command that dies immediately - a typo, a bad quote, a missing binary - is reported as `API FAILED` with the last log lines in about a second, instead of stalling the full readiness timeout and then blaming a slow start.
Because the launch command is a shell line, a mis-quoted argument is the most common way this fires.

## Scope (v1)

- tmux and herdr only; other backends refuse `up`.
- One service per worker (a second `up` with a new label refuses); the registry is label-keyed, so growing to several later is additive. A registered service that is *provably* dead - nothing listening on its port, and either its tab gone or its log carrying the exit marker - is cleared first, so a crashed service cannot permanently block the worker's one slot. "Port free" alone never counts, because a service that is still starting also has a free port.
- Terminal-hosted services only. An Android emulator / iOS simulator is a separate GUI process, already visible and torn down separately; firstmate does not reap those and this helper does not manage them.

## Verified

2026-07-24, macOS aarch64, herdr 0.7.5 (protocol 17), tmux 3.6a.

- herdr self-location: `HERDR_ENV=1`, `HERDR_WORKSPACE_ID`, `HERDR_PANE_ID`, `HERDR_TAB_ID`, `HERDR_SOCKET_PATH` injected into every pane; `HERDR_SESSION` present in a named session, absent in the default.
- tmux self-location: `$TMUX`, `$TMUX_PANE`, and `tmux display-message -p '#{session_name}:#{window_id}'`.
- End-to-end on both backends: `up` opened a labeled sibling tab, bound the port, registered the line, and printed the URL; `down`/teardown-reap closed the tab and killed the server (port went dark) while the dated log was kept; a second `up` with a different label refused.
- Teardown-orphan reproduction (the bug this closes): closing only the recorded agent endpoint left the service tab and process alive and serving on both backends until the registered endpoint was explicitly closed.

2026-07-27, macOS aarch64, tmux 3.6a, hardening pass. Each item is pinned by a test in `tests/fm-worker-api.test.sh`:

- Buffering, measured with `python3 -m http.server` killed after 2s: plain pipe and `stdbuf -oL -eL` both lost the stdout banner; `script -q /dev/null` kept it. The pty is now the default launch form.
- `script` flavor probe: `script -q -c true /dev/null` exits 1 immediately on BSD/macOS with no session and no stray file, so it is safe to use as the util-linux detector.
- Teardown ordering: with a worktree that fails `teardown_treehouse_return`, teardown aborts non-zero and the service window is still reaped.
- Pinned-but-taken port: `up --port <live port>` refuses and registers nothing, instead of reporting a healthy service whose real process died with `address already in use`.
- Immediate-exit launch command: reported as `API FAILED` with the exit marker and last log lines, in about a second rather than after the full readiness timeout.
- Provably dead registered service: cleared, with the new `up` proceeding, instead of blocking the worker's one slot forever.
- `--prune-before` with a shape-valid but unparseable date (`9999-99-99`) errors and deletes nothing, on both find flavors.
- Orphan sweep: a registry with no `state/<id>.meta` had its real tmux window closed and its registry removed; a registry whose task still has a meta was left untouched and the sweep stayed silent.
- cmux: a pane carrying `CMUX_WORKSPACE_ID` with no `$TMUX` refuses `up` rather than being mis-detected as tmux.
- Port race: five concurrent `up`s with the lock released at registration put two workers on port 8837, the loser dying with `Address already in use` while `up` printed `API up` and `status` showed `[serving]`. Holding the lock through bind, plus the cross-registry claim check, is what closes it.
- `tmux display-message -p -t firstmate:@99` prints the session's current pane and exits 0 for a window that never existed, while `list-windows` correctly omits it and `has-session` exits 1 - the basis for `fm_backend_sibling_alive`.
- A failed launch leaves no residue: the tab is closed and no registry line remains.
- herdr end-to-end in an isolated lab session (`bin/fm-herdr-lab.sh`): `up` created the labeled service tab in the worker's own workspace, bound the port, recorded a session-scoped endpoint, the stdout banner reached the log through `pane run`, `status` reported serving, and `down` closed the tab, killed the server, and kept the log.
- Port lock robustness: an unbreakable stale lock (a regular file, or a non-empty directory, older than the stale threshold) made the acquire loop retry with no sleep and no timeout - `up` hung at full CPU. It now falls through to the bounded wait, verified by a test that asserts the run reaches the backend check well inside the wait.
- Stale exit marker: a log pre-seeded with a previous run's `[fm-worker-api] service exited rc=1` no longer fails a healthy launch. Confirmed as a genuine regression test by reverting the byte-offset read, which makes the test fail.
