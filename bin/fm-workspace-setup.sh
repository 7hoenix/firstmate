#!/usr/bin/env bash
# Per-project workspace setup: bring a freshly-leased task worktree up with its
# toolchain, dependencies, and secrets, idempotently, on BOTH fresh creation and
# re-lease of a pooled worktree.
#
# WHY THIS EXISTS
#   treehouse `post_create` hooks (in each project clone's treehouse.toml) fire
#   ONLY when treehouse BUILDS a new pool worktree. bin/fm-spawn.sh normally
#   RE-LEASES a pre-warmed pooled worktree, so post_create does not re-run and a
#   re-leased worktree's installed deps drift stale against the moving default
#   branch. treehouse exposes no lease/get hook (treehouse get --help), so the
#   run-on-every-lease step lives here, invoked by fm-spawn after the worktree is
#   final. Running from fm-spawn (reading firstmate's own config) also means
#   firstmate never writes into a project clone to configure setup - no new
#   never-write-to-a-project exception is needed.
#
# CONFIG (canonical mechanism tracked in this repo; per-captain values are LOCAL)
#   config/workspace-setup.json (gitignored, firstmate-maintained + human-editable)
#   maps a project name to an ordered list of setup steps. A project with NO entry
#   behaves exactly as before this script existed: `run` is a silent no-op.
#   docs/examples/workspace-setup.json is the tracked, copyable example, and
#   docs/workspace-setup.md owns the schema reference and manual verification plan.
#
#   Schema, per project name:
#     { "<project>": { "steps": [ <step>, ... ] } }
#   Each <step>:
#     name        required, unique within the project; the label used in the log,
#                 the summary line, and the per-worktree state marker.
#     run         required, a shell command run with the worktree as cwd.
#     phase       "create" | "lease" | "both" (default "both"). create runs once,
#                 until it first succeeds; lease runs only on a re-lease (a worktree
#                 that was set up before); both always runs (subject to fingerprint).
#     fingerprint optional list of worktree-relative files; when present, an eligible
#                 step is SKIPPED if it already succeeded and the combined content
#                 hash of those files is unchanged since that success. This is the
#                 lockfile-hash short-circuit that keeps an unchanged re-lease fast.
#     env         optional map of extra environment variables for the step.
#     optional    default false; when true a failure is a warning, not a run failure.
#     enabled     default true; false = an opt-in extra left off until the captain
#                 flips it (e.g. iOS tuist steps that make no sense headless).
#
# TOOLCHAIN
#   MISE_YES=1 is exported for the whole run so mise never prompts. When mise is on
#   PATH and the worktree carries a mise config (mise.toml, .mise.toml, or
#   .tool-versions), every config is `mise trust`ed and each step runs under
#   `mise exec --` so mise-managed tools (pnpm, bun, node, ...) resolve without a
#   manual activation. Set a step's "mise": false to opt it out of that wrapping.
#
# STATE MARKER
#   A per-worktree marker ($WT/.fm-workspace-setup.json) records each step's last
#   success and fingerprint. It is git-excluded (info/exclude) so it never dirties
#   the worktree or blocks teardown. It shares fate with the deps it describes: if
#   node_modules is wiped, the marker usually goes with it and setup re-runs. Its
#   presence at run start is what distinguishes a re-lease (phase "lease" eligible)
#   from a fresh create.
#
# FAILURE MODEL
#   A setup failure must never brick a spawn. `run` still leaves the worktree usable
#   and prints a concise summary; it exits non-zero ONLY so fm-spawn can surface the
#   failure loudly (fm-spawn warns and continues). Full step output goes to --log.
#
# USAGE
#   fm-workspace-setup.sh run --worktree <path> --project <name> [--log <file>]
#                             [--config <file>]
#   fm-workspace-setup.sh validate [--config <file>] [--config-dir <dir>]
#       Validate config/workspace-setup.json and print "WORKSPACE_SETUP:" lines for
#       bootstrap. Owns the schema check so bootstrap does not restate it.
#
# Exit: run -> 0 when there was nothing to do or every required step succeeded;
#       non-zero when a required step failed or the config could not be read.
#       validate -> always 0 (diagnostics are printed, never fatal), matching the
#       crew-dispatch bootstrap convention.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$SCRIPT_DIR/..}"

MARKER_NAME=".fm-workspace-setup.json"

die() { printf 'fm-workspace-setup: %s\n' "$1" >&2; exit 1; }

# --- shared helpers ---------------------------------------------------------

default_config_file() {
  printf '%s\n' "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/workspace-setup.json"
}

sha256_of_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

# fingerprint_hash <worktree> <file>...: a stable hash over the named worktree
# files. Each file's path is mixed in alongside its content so a file appearing or
# disappearing changes the hash even when the remaining files are identical.
fingerprint_hash() {
  local wt=$1 f
  shift
  {
    for f in "$@"; do
      printf 'path:%s\n' "$f"
      if [ -f "$wt/$f" ]; then
        printf 'present\n'
        cat "$wt/$f"
      else
        printf 'absent\n'
      fi
      printf '\n--fm--\n'
    done
  } | sha256_of_stdin
}

# --- validate subcommand ----------------------------------------------------

cmd_validate() {
  local file="" config_dir=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --config) file=$2; shift 2 ;;
      --config-dir) config_dir=$2; shift 2 ;;
      *) die "validate: unknown arg '$1'" ;;
    esac
  done
  if [ -z "$file" ]; then
    if [ -n "$config_dir" ]; then
      file="$config_dir/workspace-setup.json"
    else
      file=$(default_config_file)
    fi
  fi
  [ -f "$file" ] || return 0

  local label="config/workspace-setup.json"
  if ! command -v jq >/dev/null 2>&1; then
    echo "WORKSPACE_SETUP: cannot validate $label - jq not installed"
    return 0
  fi
  if ! jq -e . "$file" >/dev/null 2>&1; then
    echo "WORKSPACE_SETUP: invalid $label - malformed JSON"
    return 0
  fi

  # Top-level keys starting with "_" are ignored so the file can carry JSON-style
  # "_comment" documentation; every other top-level key is a project name.
  local err
  err=$(jq -r '
    def is_phase($p): ($p == null) or (["create","lease","both"] | index($p));
    def projects: [to_entries[] | select(.key | startswith("_") | not)];
    if type != "object" then "top-level value must be an object mapping project -> config"
    elif [projects[] | select((.value | type) != "object")] | length > 0
      then "each project value must be an object"
    elif [projects[] | select((.value.steps? | type) != "array")] | length > 0
      then "each project needs a steps array"
    elif [projects[] | .value.steps[]? | select(type != "object")] | length > 0
      then "each step must be an object"
    elif [projects[] | .value.steps[]? | select((.name? | type) != "string" or (.name | length) == 0)] | length > 0
      then "each step needs a non-empty name"
    elif [projects[] | .value.steps[]? | select((.run? | type) != "string" or (.run | length) == 0)] | length > 0
      then "each step needs a non-empty run"
    elif [projects[] | .value.steps[]? | select(is_phase(.phase?) | not)] | length > 0
      then "phase must be one of create, lease, both"
    elif [projects[] | .value.steps[]? | select((.fingerprint? != null) and ((.fingerprint | type) != "array"))] | length > 0
      then "fingerprint must be an array of file paths"
    elif [projects[] | .value.steps[]? | .fingerprint? // [] | .[] | select(type != "string")] | length > 0
      then "fingerprint entries must be strings"
    elif [projects[] | .value.steps[]? | select((.env? != null) and ((.env | type) != "object"))] | length > 0
      then "env must be an object"
    elif [projects[] | .value.steps as $s | select(($s | map(.name) | length) != ($s | map(.name) | unique | length))] | length > 0
      then "step names must be unique within a project"
    else empty
    end
  ' "$file" 2>/dev/null || true)
  if [ -n "$err" ]; then
    echo "WORKSPACE_SETUP: invalid $label - $err"
    return 0
  fi

  jq -r '
    def phase_of($s): ($s.phase // "both");
    ["WORKSPACE_SETUP: active config/workspace-setup.json"]
    + [ to_entries[]
        | select(.key | startswith("_") | not)
        | .key as $proj
        | "  " + $proj + ": "
          + ([ .value.steps[]
               | .name
                 + "(" + phase_of(.)
                 + (if .enabled == false then ",off" else "" end)
                 + (if .optional == true then ",optional" else "" end)
                 + ")" ] | join(" ")) ]
    | .[]
  ' "$file"
}

# --- run subcommand ---------------------------------------------------------

# git_exclude_marker <worktree>: add the state marker to the worktree's
# info/exclude so it never shows as dirty (mirrors fm-spawn's exclude_path). Uses
# `rev-parse --git-path info/exclude`, the exclude file git actually honors: for a
# linked worktree that resolves to the shared common .git/info/exclude (git ignores
# the per-worktree admin dir's info/exclude), and for a plain-init repo it returns a
# relative path we resolve against the worktree.
git_exclude_marker() {
  local wt=$1 excl pat
  excl=$(git -C "$wt" rev-parse --git-path info/exclude 2>/dev/null || true)
  [ -n "$excl" ] || return 0
  case "$excl" in
    /*) : ;;
    *) excl="$wt/$excl" ;;
  esac
  mkdir -p "$(dirname "$excl")" 2>/dev/null || return 0
  for pat in "$MARKER_NAME" ".fm-wss-marker.*"; do
    grep -qxF "$pat" "$excl" 2>/dev/null || printf '%s\n' "$pat" >> "$excl"
  done
}

cmd_run() {
  local wt="" project="" log="" file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --worktree) wt=$2; shift 2 ;;
      --project) project=$2; shift 2 ;;
      --log) log=$2; shift 2 ;;
      --config) file=$2; shift 2 ;;
      *) die "run: unknown arg '$1'" ;;
    esac
  done
  [ -n "$wt" ] || die "run: --worktree is required"
  [ -n "$project" ] || die "run: --project is required"
  [ -d "$wt" ] || die "run: worktree '$wt' does not exist"
  [ -n "$file" ] || file=$(default_config_file)

  # No config, or no entry for this project: zero behavior change, silent success.
  [ -f "$file" ] || return 0
  command -v jq >/dev/null 2>&1 || { echo "workspace-setup $project: jq not installed; cannot run configured setup" >&2; return 1; }
  jq -e . "$file" >/dev/null 2>&1 || { echo "workspace-setup $project: config/workspace-setup.json is malformed JSON; skipping setup" >&2; return 1; }
  local nsteps
  nsteps=$(jq -r --arg p "$project" '(.[$p].steps // []) | length' "$file" 2>/dev/null || echo 0)
  [ "${nsteps:-0}" -gt 0 ] 2>/dev/null || return 0

  # The marker's presence distinguishes a re-lease (it was set up before) from a
  # fresh create. Per-step create tracking (below) is what actually makes a create
  # step run once until it first succeeds, so a partial first setup is not skipped.
  local marker="$wt/$MARKER_NAME" marker_existed=0 phase=create
  if [ -f "$marker" ]; then marker_existed=1; phase=lease; fi

  # Logging: everything runs through this, teeing to --log when given.
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown)
  logline() {
    if [ -n "$log" ]; then printf '%s\n' "$1" >> "$log"; fi
  }
  if [ -n "$log" ]; then
    mkdir -p "$(dirname "$log")" 2>/dev/null || true
    printf '=== workspace-setup %s (phase=%s) %s ===\n' "$project" "$phase" "$ts" >> "$log"
  fi

  export MISE_YES=1

  # mise wrapping: trust every present mise config once, then run steps under
  # `mise exec --` so tool shims resolve. A worktree without mise config, or a
  # host without mise, runs steps under plain bash.
  local mise_available=0 mise_config=0 cfg
  if command -v mise >/dev/null 2>&1; then
    mise_available=1
    for cfg in mise.toml .mise.toml .tool-versions; do
      if [ -f "$wt/$cfg" ]; then
        mise_config=1
        mise trust --quiet "$wt/$cfg" >>"${log:-/dev/null}" 2>&1 || true
      fi
    done
  fi

  git_exclude_marker "$wt"

  # Accumulate marker records as name<TAB>ok<TAB>fingerprint lines.
  local records
  records=$(mktemp "${TMPDIR:-/tmp}/fm-wss.XXXXXX") || die "run: mktemp failed"
  local summary="workspace-setup $project (phase=$phase):"
  local had_failure=0 i step_json name run step_phase enabled optional use_mise
  local -a fp_files
  local recorded_ok recorded_fp cur_fp eligible short_circuit

  for ((i=0; i<nsteps; i++)); do
    step_json=$(jq -c --arg p "$project" --argjson i "$i" '.[$p].steps[$i]' "$file")
    name=$(printf '%s' "$step_json" | jq -r '.name')
    run=$(printf '%s' "$step_json" | jq -r '.run')
    step_phase=$(printf '%s' "$step_json" | jq -r '.phase // "both"')
    enabled=$(printf '%s' "$step_json" | jq -r 'if .enabled == false then "no" else "yes" end')
    optional=$(printf '%s' "$step_json" | jq -r 'if .optional == true then "yes" else "no" end')
    use_mise=$(printf '%s' "$step_json" | jq -r 'if .mise == false then "no" else "yes" end')
    mapfile -t fp_files < <(printf '%s' "$step_json" | jq -r '.fingerprint // [] | .[]')

    # Prior state for this step from the marker (if any).
    recorded_ok=no
    recorded_fp=""
    if [ "$marker_existed" -eq 1 ]; then
      recorded_ok=$(jq -r --arg n "$name" '.steps[$n].ok // false | if . then "yes" else "no" end' "$marker" 2>/dev/null || echo no)
      recorded_fp=$(jq -r --arg n "$name" '.steps[$n].fingerprint // ""' "$marker" 2>/dev/null || echo "")
    fi

    # Carry the prior record forward by default; overwritten if the step runs.
    printf '%s\t%s\t%s\n' "$name" "$([ "$recorded_ok" = yes ] && echo 1 || echo 0)" "$recorded_fp" >> "$records"

    if [ "$enabled" = no ]; then
      summary="$summary $name=off"
      logline "-- $name: disabled (enabled=false), skipping"
      continue
    fi

    # Phase eligibility.
    eligible=no
    case "$step_phase" in
      both) eligible=yes ;;
      create) [ "$recorded_ok" = yes ] || eligible=yes ;;
      lease) [ "$marker_existed" -eq 1 ] && eligible=yes ;;
    esac
    if [ "$eligible" = no ]; then
      summary="$summary $name=skip:phase"
      logline "-- $name: not eligible in phase $phase (step phase=$step_phase), skipping"
      continue
    fi

    # Fingerprint short-circuit.
    cur_fp=""
    if [ "${#fp_files[@]}" -gt 0 ]; then
      cur_fp=$(fingerprint_hash "$wt" "${fp_files[@]}")
      short_circuit=no
      if [ "$recorded_ok" = yes ] && [ -n "$recorded_fp" ] && [ "$recorded_fp" = "$cur_fp" ]; then
        short_circuit=yes
      fi
      if [ "$short_circuit" = yes ]; then
        summary="$summary $name=skip:unchanged"
        logline "-- $name: fingerprint unchanged, skipping"
        continue
      fi
    fi

    # Run the step. Build the env-prefixed command, mise-wrapped when applicable.
    logline "-- $name: running: $run"
    local -a env_pairs
    mapfile -t env_pairs < <(printf '%s' "$step_json" | jq -r '.env // {} | to_entries[] | "\(.key)=\(.value)"')
    local rc=0
    (
      cd "$wt" || exit 127
      if [ "${#env_pairs[@]}" -gt 0 ]; then
        export "${env_pairs[@]}"
      fi
      if [ "$mise_available" -eq 1 ] && [ "$mise_config" -eq 1 ] && [ "$use_mise" = yes ]; then
        mise exec -- bash -c "$run"
      else
        bash -c "$run"
      fi
    ) >>"${log:-/dev/null}" 2>&1 </dev/null
    rc=$?

    # Rewrite this step's record (last line for $name) with the new result.
    if [ "$rc" -eq 0 ]; then
      sed_replace_record "$records" "$name" 1 "$cur_fp"
      summary="$summary $name=ran"
      logline "-- $name: ok"
    else
      sed_replace_record "$records" "$name" 0 "$recorded_fp"
      if [ "$optional" = yes ]; then
        summary="$summary $name=fail:optional"
        logline "-- $name: FAILED (rc=$rc) but optional; continuing"
      else
        summary="$summary $name=FAIL"
        logline "-- $name: FAILED (rc=$rc)"
        had_failure=1
      fi
    fi
  done

  # Write the marker atomically from the accumulated records.
  local marker_tmp
  marker_tmp=$(mktemp "$wt/.fm-wss-marker.XXXXXX") || die "run: mktemp marker failed"
  if jq -Rn '
      reduce inputs as $line ({};
        ($line | split("\t")) as $p
        | .[$p[0]] = {ok: ($p[1] == "1"), fingerprint: $p[2]})
      | {steps: .}
    ' < "$records" > "$marker_tmp" 2>/dev/null; then
    mv -f "$marker_tmp" "$marker"
  else
    rm -f "$marker_tmp"
    logline "-- warning: could not write state marker $marker"
  fi
  rm -f "$records"

  printf '%s\n' "$summary"
  [ -n "$log" ] && printf '=== end workspace-setup %s (failure=%s) ===\n' "$project" "$had_failure" >> "$log"
  return "$had_failure"
}

# sed_replace_record <records-file> <name> <ok01> <fp>: replace the LAST record
# line for <name> with the new ok/fingerprint. Records are name<TAB>ok<TAB>fp; a
# name is unique per project (validated), so there is exactly one line to replace.
sed_replace_record() {
  local rf=$1 name=$2 ok=$3 fp=$4 tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-wss-rec.XXXXXX") || return 1
  awk -F'\t' -v n="$name" -v ok="$ok" -v fp="$fp" '
    $1 == n { print n "\t" ok "\t" fp; next }
    { print }
  ' "$rf" > "$tmp" && mv -f "$tmp" "$rf"
}

# --- dispatch ---------------------------------------------------------------

case "${1:-}" in
  run) shift; cmd_run "$@" ;;
  validate) shift; cmd_validate "$@" ;;
  ""|-h|--help)
    sed -n '1,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    ;;
  *) die "unknown subcommand '$1' (expected: run, validate)" ;;
esac
