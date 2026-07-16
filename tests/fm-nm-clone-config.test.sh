#!/usr/bin/env bash
# Behavior tests for fm-nm-clone-config.sh - unattended-credential hardening of a
# no-mistakes INTERNAL clone.
#
# These simulate the two failure surfaces the helper closes, entirely from fake
# fixtures (a fake global git config, a fake bare "internal clone", a fake project
# whose no-mistakes remote points at it) with no real no-mistakes daemon, gh auth, or
# network. gh is faked on a curated PATH so both the gh-present and gh-absent branches
# are exercised deterministically, and the host's real gh never leaks in.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELPER="$ROOT/bin/fm-nm-clone-config.sh"
BASH_BIN=$(command -v bash)
GIT_BIN=$(command -v git)
GREP_BIN=$(command -v grep)

TMP_ROOT=$(fm_test_tmproot fm-nm-clone-config)
mkdir -p "$TMP_ROOT"
fm_git_identity

# Hermetic git for every read in this suite: neuter the host system config (macOS ships
# a system credential.helper=osxkeychain that would otherwise aggregate into --get-all
# counts) and point the ambient global at an empty file. Per-case run_helper and the
# "global untouched" assertions override GIT_CONFIG_GLOBAL inline with a fake global.
export GIT_CONFIG_SYSTEM=/dev/null
export GIT_CONFIG_GLOBAL="$TMP_ROOT/host-neutral-global"
: > "$GIT_CONFIG_GLOBAL"

# --- fixture builders -------------------------------------------------------

# mk_global <file> <yes|no>: a temp global config forcing signing, optionally with the
# github HTTPS->SSH insteadOf rewrite that is the captain's actual situation.
mk_global() {
  local file=$1 with_rewrite=$2
  cat > "$file" <<EOF
[commit]
	gpgsign = true
[tag]
	gpgsign = true
EOF
  if [ "$with_rewrite" = yes ]; then
    cat >> "$file" <<EOF
[url "git@github.com:"]
	insteadOf = https://github.com/
EOF
  fi
}

# mk_clone <dir> <origin-url>: a bare repo standing in for ~/.no-mistakes/repos/<hash>.git.
mk_clone() {
  local dir=$1 origin=$2
  git init -q --bare "$dir"
  git -C "$dir" remote add origin "$origin"
}

# mk_proj <dir> <clone> <origin-url|->: a project whose no-mistakes remote points at the
# internal clone; origin '-' means no origin remote at all.
mk_proj() {
  local dir=$1 clone=$2 origin=$3
  git init -q "$dir"
  git -C "$dir" remote add no-mistakes "$clone"
  [ "$origin" = '-' ] || git -C "$dir" remote add origin "$origin"
}

# mk_shim <dir> <yes|no> [login]: a curated PATH holding only bash/git/grep (real) and,
# when requested, a fake gh answering just `gh api user -q .login`. Echoes the shim dir.
mk_shim() {
  local dir=$1 want_gh=$2 login=${3:-shimuser} shim="$1/shimbin"
  mkdir -p "$shim"
  ln -sf "$BASH_BIN" "$shim/bash"
  ln -sf "$GIT_BIN" "$shim/git"
  ln -sf "$GREP_BIN" "$shim/grep"
  if [ "$want_gh" = yes ]; then
    cat > "$shim/gh" <<SH
#!/usr/bin/env bash
if [ "\$1" = api ] && [ "\$2" = user ]; then printf '%s\n' "$login"; exit 0; fi
exit 1
SH
    chmod +x "$shim/gh"
  fi
  printf '%s\n' "$shim"
}

# run_helper <proj> <shim> <global>: run the helper with the host toolchain hidden,
# only the curated shim on PATH, and the fake global config in effect.
run_helper() {
  PATH="$2" GIT_CONFIG_GLOBAL="$3" GIT_CONFIG_SYSTEM=/dev/null \
    "$BASH_BIN" "$HELPER" "$1"
}

# --- tests ------------------------------------------------------------------

# The captain's machine: global signing + HTTPS->SSH rewrite, an ssh-form internal
# origin, gh present. Both surfaces must be closed, scoped to the internal clone.
test_full_dodge_with_gh() {
  local d="$TMP_ROOT/full" g="$TMP_ROOT/full/global" clone="$TMP_ROOT/full/clone.git" proj="$TMP_ROOT/full/proj" shim
  mkdir -p "$d"
  mk_global "$g" yes
  mk_clone "$clone" 'git@github.com:owner/repo.git'
  mk_proj "$proj" "$clone" 'https://tuser@github.com/owner/repo.git'
  shim=$(mk_shim "$d" yes shimuser)

  run_helper "$proj" "$shim" "$g" || fail "helper returned non-zero on the full-dodge case"

  # Surface 3: signing off on the internal clone.
  [ "$(git -C "$clone" config commit.gpgsign)" = false ] || fail "internal clone commit.gpgsign not false"
  [ "$(git -C "$clone" config tag.gpgsign)" = false ] || fail "internal clone tag.gpgsign not false"

  # Surface 4: origin rewritten to gh's login (preferred over the origin's tuser),
  # reverse insteadOf added, credential helper reset to empty-then-gh.
  [ "$(git -C "$clone" remote get-url origin)" = 'https://shimuser@github.com/owner/repo.git' ] \
    || fail "internal clone origin not rewritten to the username-form URL"
  [ "$(git -C "$clone" config 'url.https://shimuser@github.com/.insteadOf')" = 'git@github.com:' ] \
    || fail "repo-local reverse insteadOf not set on the internal clone"
  local helpers
  mapfile -t helpers < <(git -C "$clone" config --get-all credential.helper)
  [ "${#helpers[@]}" -eq 2 ] || fail "expected 2 credential.helper entries, got ${#helpers[@]}"
  [ -z "${helpers[0]}" ] || fail "first credential.helper entry must be empty (reset), got '${helpers[0]}'"
  [ "${helpers[1]}" = '!gh auth git-credential' ] || fail "second credential.helper entry must route through gh"

  # Never touch the operator's global config, nor the project's own remote.
  GIT_CONFIG_GLOBAL="$g" GIT_CONFIG_SYSTEM=/dev/null git config --global commit.gpgsign | grep -qx true \
    || fail "global commit.gpgsign was altered"
  [ -z "$(GIT_CONFIG_GLOBAL="$g" GIT_CONFIG_SYSTEM=/dev/null git config --global --get-all credential.helper)" ] \
    || fail "a credential.helper leaked into the global config"
  [ "$(git -C "$proj" remote get-url origin)" = 'https://tuser@github.com/owner/repo.git' ] \
    || fail "the project's own origin was altered"

  pass "full dodge: signing off + username-URL + reverse insteadOf + gh credential helper, scoped to the internal clone"
}

# Idempotent: fm-spawn applies it, then the ship brief re-applies before validation.
test_idempotent() {
  local d="$TMP_ROOT/idem" g="$TMP_ROOT/idem/global" clone="$TMP_ROOT/idem/clone.git" proj="$TMP_ROOT/idem/proj" shim
  mkdir -p "$d"
  mk_global "$g" yes
  mk_clone "$clone" 'git@github.com:owner/repo.git'
  mk_proj "$proj" "$clone" 'https://tuser@github.com/owner/repo.git'
  shim=$(mk_shim "$d" yes shimuser)

  run_helper "$proj" "$shim" "$g" || fail "first run returned non-zero"
  run_helper "$proj" "$shim" "$g" || fail "second run returned non-zero"

  local helpers
  mapfile -t helpers < <(git -C "$clone" config --get-all credential.helper)
  [ "${#helpers[@]}" -eq 2 ] || fail "credential.helper entries doubled on re-run (${#helpers[@]})"
  [ "$(git -C "$clone" config --get-all 'url.https://shimuser@github.com/.insteadOf' | wc -l | tr -d ' ')" = 1 ] \
    || fail "reverse insteadOf became multi-valued on re-run"
  [ "$(git -C "$clone" remote get-url origin)" = 'https://shimuser@github.com/owner/repo.git' ] \
    || fail "origin drifted on re-run"

  pass "re-running the helper is a clean idempotent no-op"
}

# gh absent: the username falls back to the user@ embedded in the project's own origin.
test_username_fallback_without_gh() {
  local d="$TMP_ROOT/fallback" g="$TMP_ROOT/fallback/global" clone="$TMP_ROOT/fallback/clone.git" proj="$TMP_ROOT/fallback/proj" shim
  mkdir -p "$d"
  mk_global "$g" yes
  mk_clone "$clone" 'git@github.com:owner/repo.git'
  mk_proj "$proj" "$clone" 'https://tuser@github.com/owner/repo.git'
  shim=$(mk_shim "$d" no)

  run_helper "$proj" "$shim" "$g" || fail "helper returned non-zero on the gh-absent fallback case"

  [ "$(git -C "$clone" remote get-url origin)" = 'https://tuser@github.com/owner/repo.git' ] \
    || fail "origin not rewritten from the parsed project username"
  # No gh means no credential helper can meaningfully be installed.
  [ -z "$(git -C "$clone" config --get-all credential.helper)" ] \
    || fail "a gh credential helper was installed with no gh present"

  pass "without gh, the username is recovered from the project origin and no gh credential helper is forced"
}

# Clean machine: plain-HTTPS origin, no insteadOf rewrite. Only signing is disabled;
# the remote and credentials are left exactly as the operator had them.
test_clean_machine_leaves_remote_alone() {
  local d="$TMP_ROOT/clean" g="$TMP_ROOT/clean/global" clone="$TMP_ROOT/clean/clone.git" proj="$TMP_ROOT/clean/proj" shim
  mkdir -p "$d"
  mk_global "$g" no
  mk_clone "$clone" 'https://github.com/owner/repo.git'
  mk_proj "$proj" "$clone" 'https://github.com/owner/repo.git'
  shim=$(mk_shim "$d" yes shimuser)

  run_helper "$proj" "$shim" "$g" || fail "helper returned non-zero on the clean-machine case"

  [ "$(git -C "$clone" config commit.gpgsign)" = false ] || fail "signing not disabled on the clean machine"
  [ "$(git -C "$clone" remote get-url origin)" = 'https://github.com/owner/repo.git' ] \
    || fail "origin was rewritten on a machine with no rewrite to dodge"
  [ -z "$(git -C "$clone" config --get-all credential.helper)" ] \
    || fail "credential helper was changed on a machine with no credential problem"

  pass "no rewrite present: only signing is disabled; remote and credentials untouched"
}

# Not a no-mistakes-gated project: no no-mistakes remote means a silent no-op.
test_no_nm_remote_is_noop() {
  local d="$TMP_ROOT/nogate" g="$TMP_ROOT/nogate/global" proj="$TMP_ROOT/nogate/proj" shim out
  mkdir -p "$d"
  mk_global "$g" yes
  git init -q "$proj"
  git -C "$proj" remote add origin 'https://tuser@github.com/owner/repo.git'
  shim=$(mk_shim "$d" yes shimuser)

  out=$(run_helper "$proj" "$shim" "$g") || fail "helper returned non-zero for a non-gated repo"
  [ -z "$out" ] || fail "helper was not silent for a non-gated repo: $out"

  pass "a repo with no no-mistakes remote is a silent no-op"
}

# gh absent AND no username to parse (ssh-form project origin): sign off, but the remote
# and credential dodge are skipped rather than half-applied.
test_no_username_skips_remote_dodge() {
  local d="$TMP_ROOT/nouser" g="$TMP_ROOT/nouser/global" clone="$TMP_ROOT/nouser/clone.git" proj="$TMP_ROOT/nouser/proj" shim
  mkdir -p "$d"
  mk_global "$g" yes
  mk_clone "$clone" 'git@github.com:owner/repo.git'
  mk_proj "$proj" "$clone" 'git@github.com:owner/repo.git'
  shim=$(mk_shim "$d" no)

  run_helper "$proj" "$shim" "$g" || fail "helper returned non-zero when no username was resolvable"

  [ "$(git -C "$clone" config commit.gpgsign)" = false ] || fail "signing not disabled when no username was resolvable"
  [ "$(git -C "$clone" remote get-url origin)" = 'git@github.com:owner/repo.git' ] \
    || fail "origin rewritten without a resolvable username"
  [ -z "$(git -C "$clone" config --get-all credential.helper)" ] \
    || fail "credential helper installed with no gh present"

  pass "no resolvable username: signing still off, but the remote/credential dodge is skipped, not half-applied"
}

test_full_dodge_with_gh
test_idempotent
test_username_fallback_without_gh
test_clean_machine_leaves_remote_alone
test_no_nm_remote_is_noop
test_no_username_skips_remote_dodge
