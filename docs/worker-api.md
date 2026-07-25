# Worker-hosted services in a visible, self-reaped tab

`bin/fm-worker-api.sh` lets a crewmate stand up a long-lived service - a local API (`wrangler dev`), a dev server (`vite`), a mock backend - in a **visible, named tab in the worker's own terminal container**, instead of hiding it in a sub-agent or a background process.

A sub-agent is meant to do a task and return, not host a server; a background `&` is invisible to the captain and to firstmate.
This helper opens the service in a tab the captain can watch and hop into, gives firstmate a searchable log to supervise it cheaply, and registers it so teardown reaps it - no orphaned tabs or processes.

Design and empirical basis: `data/worker-api-tab-4d/rfc.md` and `data/worker-api-tab-4d/report.md`.

## How a worker uses it

```
fm-worker-api.sh up   [--label <suffix>] [--port <n>] [--] <launch command...>
fm-worker-api.sh down [--label <suffix>]
fm-worker-api.sh restart [--label <suffix>] [--port <n>] [--] <launch command...>
fm-worker-api.sh status
fm-worker-api.sh logs [--label <suffix>] [--follow]
fm-worker-api.sh logs --prune-before <YYYY-MM-DD>
```

`up` self-locates the worker's own container, picks a free port, opens the service tab, launches the command with `PORT` exported, tees the output to a dated log, registers the tab, and prints the URL once the port is accepting connections.
Every ship and scout brief carries a one-line pointer to this helper (`bin/fm-brief.sh`), because the need for a live service is often discovered mid-task.

## How it works

### Self-location (no firstmate identity needed)

A crewmate pane carries no `FM_HOME` or task id, so the helper reads the container from the environment the backend injects into every pane:

- **herdr**: `HERDR_ENV=1` selects herdr; `HERDR_WORKSPACE_ID` is the worker's own workspace; the session is `${HERDR_SESSION:-default}` (herdr sets `HERDR_SESSION` in a named session, and omits it in the default one).
- **tmux**: a non-empty `$TMUX` selects tmux; the session comes from `tmux display-message -p '#{session_name}'`.

`$TMUX` is checked first: a tmux started inside a herdr pane sets both, and tmux then correctly wins for a nested tmux because the worker's shell lives in that tmux session (matching `fm_backend_detect`).
Any other backend (zellij, cmux, orca) refuses `up` with a clear message - v1 supports tmux and herdr.

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

`bin/fm-spawn.sh` exports `FM_WORKER_API_REGISTRY` and `FM_WORKER_API_LOGDIR` into the worker's pane (like `GOTMPDIR`); `--registry`/`--logdir` override them for manual use and tests.

### Deterministic port

The port is a deterministic candidate from the worktree path (`FM_WORKER_API_PORT_BASE` default 8800, `+ cksum(worktree) mod FM_WORKER_API_PORT_RANGE` default 200), then the first free port at/above it, printed so it is targetable.
`--port` pins an explicit value.
`PORT` is exported into the service's shell; services that read a port from a flag should be passed one in the launch command (e.g. `wrangler dev --port "$PORT"`).
The launch command runs as a shell line, so `$PORT`, pipes, and `&&` work, and multi-word arguments must be quoted as they would be for a shell.

### Logs are collected, not deleted

The service's stdout+stderr is teed to a dated file that **survives teardown**:

```
$FM_WORKER_API_LOGDIR/<id>-<label>-<YYYY-MM-DD-HHMM>.log   (default: data/api-logs/)
```

- **Visual stream** = the tab; **searchable stream** = this log. One source, two views, cannot drift.
- Firstmate greps it for readiness/errors instead of peeking the pane; the captain searches history after scrollback rolls off.
- Logs accumulate and are pruned in bulk later with `logs --prune-before <YYYY-MM-DD>` (or a plain `rm`), never per-task.

## Scope (v1)

- tmux and herdr only; other backends refuse `up`.
- One service per worker (a second `up` with a new label refuses); the registry is label-keyed, so growing to several later is additive.
- Terminal-hosted services only. An Android emulator / iOS simulator is a separate GUI process, already visible and torn down separately; firstmate does not reap those and this helper does not manage them.

## Verified

2026-07-24, macOS aarch64, herdr 0.7.5 (protocol 17), tmux 3.6a.

- herdr self-location: `HERDR_ENV=1`, `HERDR_WORKSPACE_ID`, `HERDR_PANE_ID`, `HERDR_TAB_ID`, `HERDR_SOCKET_PATH` injected into every pane; `HERDR_SESSION` present in a named session, absent in the default.
- tmux self-location: `$TMUX`, `$TMUX_PANE`, and `tmux display-message -p '#{session_name}:#{window_id}'`.
- End-to-end on both backends: `up` opened a labeled sibling tab, bound the port, registered the line, and printed the URL; `down`/teardown-reap closed the tab and killed the server (port went dark) while the dated log was kept; a second `up` with a different label refused.
- Teardown-orphan reproduction (the bug this closes): closing only the recorded agent endpoint left the service tab and process alive and serving on both backends until the registered endpoint was explicitly closed.
