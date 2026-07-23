# Workspace setup (config/workspace-setup.json)

Every task worktree ("workspace") should come up with its project's toolchain, dependencies, and secrets already in place, so a crewmate can build and run immediately.
This is done by a per-project, configurable setup step that runs on BOTH fresh worktree creation and re-lease of a pooled worktree, idempotently.

The mechanism is tracked in this repo (`bin/fm-workspace-setup.sh`).
The per-fleet project list and exact commands are LOCAL, gitignored config: `config/workspace-setup.json`.
`docs/examples/workspace-setup.json` is a copyable, valid starting point.

## Why a spawn-time step instead of treehouse hooks alone

treehouse runs a project clone's `treehouse.toml` `[hooks] post_create` ONLY when it BUILDS a new pool worktree.
`bin/fm-spawn.sh` normally RE-LEASES a pre-warmed pooled worktree, so `post_create` does not fire again and a re-leased worktree's installed deps drift stale against the moving default branch.
treehouse exposes no lease/get hook (`treehouse get --help`), so the run-on-every-lease step lives in `bin/fm-spawn.sh`, which invokes `bin/fm-workspace-setup.sh` after the worktree is final.

Running from firstmate's own config also means firstmate never writes into a project clone to configure setup, so no new never-write-to-a-project exception is introduced.
A clone's existing `post_create` hook (if any) still runs on a genuine fresh build and is harmless: this setup is idempotent, so any overlap is a no-op on the second run.

## Where the config lives and who inherits it

- `config/workspace-setup.json` - LOCAL, gitignored, firstmate-maintained and human-editable.
- Inherited into every secondmate home (it is in `FM_INHERITABLE_CONFIG`), so a secondmate's own crewmate worktrees come up with the same per-project setup.
- Validated at every session start; bootstrap prints a `WORKSPACE_SETUP:` line (see below).

## Schema

The file maps a project name (as it appears under `projects/`) to an ordered list of steps.
A project with NO entry is left exactly as before this mechanism existed: setup is a silent, instant no-op.
Top-level keys beginning with `_` are ignored, so a file may carry `"_comment"` documentation.

```json
{
  "<project-name>": {
    "steps": [
      {
        "name": "deps",
        "run": "pnpm install --frozen-lockfile",
        "phase": "both",
        "fingerprint": ["pnpm-lock.yaml"],
        "env": { "CI": "1" },
        "optional": false,
        "enabled": true,
        "mise": true
      }
    ]
  }
}
```

| Field | Required | Default | Meaning |
| --- | --- | --- | --- |
| `name` | yes | - | Unique within the project; the label in the log, summary, and state marker. |
| `run` | yes | - | Shell command, run with the worktree as the working directory. |
| `phase` | no | `both` | `create` runs once, until it first succeeds; `lease` runs only on a re-lease; `both` always runs (subject to `fingerprint`). |
| `fingerprint` | no | none | Worktree-relative files; an eligible step is SKIPPED when it already succeeded and the combined content hash of these files is unchanged. This is the lockfile short-circuit that keeps an unchanged re-lease fast. |
| `env` | no | none | Extra environment variables for the step. |
| `optional` | no | `false` | When true, a failure is a warning, not a run failure. |
| `enabled` | no | `true` | `false` = an opt-in extra left off until a captain flips it (e.g. iOS tuist steps that make no sense headless). |
| `mise` | no | `true` | When true and mise wrapping applies, the step runs under `mise exec --`; set false to opt a step out. |

## Create vs lease detection

A per-worktree state marker, `<worktree>/.fm-workspace-setup.json`, records each step's last success and fingerprint.
The marker's presence at run start distinguishes a re-lease (phase `lease` eligible) from a fresh create.
The marker is added to the worktree's `.git/info/exclude`, so it never shows as dirty or blocks teardown.
It shares fate with the deps it describes: if the workspace's `node_modules` is wiped, the marker usually goes with it and setup re-runs.

`create`-phase steps additionally track per-step success, so a `create` step that FAILED on the first run still retries on the next lease until it first succeeds - a partial first setup does not permanently skip it.

## Toolchain (mise)

`MISE_YES=1` is exported for the whole run so mise never prompts.
When `mise` is on PATH and the worktree carries a mise config (`mise.toml`, `.mise.toml`, or `.tool-versions`), every config is `mise trust`ed and each step runs under `mise exec --` so mise-managed tools (pnpm, bun, node, ...) resolve without manual activation.
A worktree without mise config, or a host without mise, runs steps under plain `bash`.

## Failure model

A setup failure never bricks a spawn.
`bin/fm-workspace-setup.sh run` still leaves the worktree usable, prints a concise per-step summary, and writes full step output to its log (`state/<id>.setup.log`).
It exits non-zero only when a required (non-`optional`) step failed, so `bin/fm-spawn.sh` can surface the failure loudly (it prints a warning and continues); the agent still launches.

## How it runs

- Spawn: `bin/fm-spawn.sh` calls `fm-workspace-setup.sh run --worktree <wt> --project <name> --log state/<id>.setup.log` for every ship and scout task, after the worktree is final and before the agent launches.
  A secondmate home is a firstmate repo worktree, not a project, so it is skipped.
- Session start: `bin/fm-bootstrap.sh` calls `fm-workspace-setup.sh validate` and relays its `WORKSPACE_SETUP:` lines.
  `bootstrap-diagnostics` owns the per-line handling.

## Manual verification plan for the real repos

The automated tests (`tests/fm-workspace-setup.test.sh`) prove the mechanism with scratch repos and fake commands, because live secrets tooling (Doppler, Vercel) and real installs cannot run in CI.
Verify the real repos manually once, on a machine with the projects cloned and their secrets tooling authenticated:

1. Populate `config/workspace-setup.json` from `docs/examples/workspace-setup.json`; confirm the exact per-project commands (see the shelf note below).
2. `bin/fm-workspace-setup.sh validate` - expect a `WORKSPACE_SETUP: active` line listing shelf and insights-app steps, no `invalid` line.
3. Fresh create: spawn a task for the project into a brand-new pool worktree; confirm from `state/<id>.setup.log` that mise install, the dependency install, and the secrets pull all ran, and that the app's toolchain and `.env`/secrets are present in the worktree.
4. Re-lease unchanged: tear down and re-spawn without changing the lockfile; confirm the summary shows `mise=skip:unchanged deps=skip:unchanged` and the re-lease is fast.
5. Re-lease with a changed lockfile: land a dependency change on the default branch, re-spawn, and confirm the dependency step re-runs while unaffected steps stay short-circuited.
6. Failure path: temporarily point a step's `run` at a failing command; confirm the spawn still completes, the crewmate still launches, and firstmate sees the loud warning naming `state/<id>.setup.log`.

Record the date, commands, and output in this doc (or a dated note) as evidence, per the repo's backend-verification convention.

## Note: shelf has no `pnpm run secrets`

shelf's `package.json` (`packageManager: pnpm@9.15.4`) has NO `secrets` script.
Its Next.js env is pulled with `pnpm pull-env` (`npx vercel env pull ...`), which needs Vercel auth.
The warehouse/dbt `.envrc` is a separate concern already handled by shelf's own `treehouse.toml` `post_create` hook (it writes `warehouse/shelf/.envrc` sourcing `~/.config/shelf/dbt.env`), so this setup does not duplicate it.
The example config uses `pnpm pull-env` for shelf's `secrets` step; confirm that is the intended command for this fleet before relying on it.
insights-app's `secrets` script IS `bun run scripts/pull-secrets.ts` (Doppler-backed); the example passes `-- --fallback` so a headless worktree without Doppler auth degrades to sample files instead of failing.
