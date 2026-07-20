#!/usr/bin/env bash
# Unattended-credential hardening for a no-mistakes internal clone.
#
# Usage: bin/fm-nm-clone-config.sh [<repo-or-worktree-path>]   (default: cwd)
#
# The problem: the no-mistakes pipeline does its commit/rebase/push work inside its
# own INTERNAL bare clone at ~/.no-mistakes/repos/<hash>.git (and worktrees of it),
# not in the task worktree fm-spawn hands the crewmate. That internal clone inherits
# the operator's GLOBAL git config, which on a machine like the captain's carries two
# unattended-hostile settings that fm-sign-lib's per-worktree override never reaches:
#
#   Surface 3 - signing: global commit.gpgsign=true drives a GUI signer (1Password,
#     gpg-agent) that an autonomous run can never click, so every pipeline commit hangs.
#   Surface 4 - HTTPS->SSH rewrite + hanging credential chain: a global
#     url."git@github.com:".insteadOf=https://github.com/ silently turns plain-HTTPS
#     git network ops into SSH (needs the same GUI agent), and the default macOS
#     credential chain (osxkeychain) also hangs when the keychain is locked.
#
# The fix (all repo-local to the internal clone; the operator's global config, the
# no-mistakes install, and every project clone are never touched):
#   - commit.gpgsign=false and tag.gpgsign=false, so pipeline commits never sign.
#   - When network ops would route through SSH (an ssh-form origin, or a global
#     github insteadOf rewrite is present): rewrite the internal clone's origin to the
#     username-form URL https://<user>@github.com/<owner>/<repo>.git. The <user>@
#     prefix does not match the global rewrite key "https://github.com/", so it escapes
#     the insteadOf and stays HTTPS. Add a repo-local reverse insteadOf as a belt so any
#     git@github.com: URL the pipeline generates internally is pulled back to that same
#     username-HTTPS form. Reset the credential helper (an empty first entry blocks the
#     inherited hanging keychain helper, then "!gh auth git-credential" supplies tokens).
# This is exactly the manual dodge used to recover ark PR #337 and dotfiles PR #4.
#
# Locating the clone: the project's own "no-mistakes" git remote points straight at the
# bare clone path, so no <hash> reproduction is needed. A repo with no such remote is
# not gated by no-mistakes (direct-PR, local-only, scout) and this is a silent no-op.
#
# Graceful degradation - every piece is a no-op on a machine that lacks the problem:
# no no-mistakes remote, no global gpgsign, no insteadOf rewrite, or no gh all shrink
# the work to nothing without error. Idempotent: safe to re-run at spawn and again
# right before validation (the internal clone can be created mid-run, after spawn).
#
# Best-effort: an individual git write that fails warns and sets a non-zero exit so a
# caller can surface it, but never aborts a live spawn.

set -u

REPO_PATH=${1:-.}
rc=0
warn() { echo "fm-nm-clone-config: $*" >&2; }

# The internal clone path is whatever the project's no-mistakes remote points at.
CLONE=$(git -C "$REPO_PATH" remote get-url no-mistakes 2>/dev/null || true)
if [ -z "$CLONE" ]; then
  # Not a no-mistakes-gated repo: nothing for the pipeline to hang on. Silent no-op.
  exit 0
fi
if ! git -C "$CLONE" rev-parse --git-dir >/dev/null 2>&1; then
  # The remote resolved to something that is not a local git repo (e.g. a future
  # remote-server form). Nothing we can configure locally.
  warn "no-mistakes remote '$CLONE' is not a local git repo; skipping"
  exit 0
fi

# Surface 3: never sign pipeline commits. Repo-local to the internal clone, applied to
# its shared config so every pipeline worktree of the bare repo inherits it. Harmless
# (and correct) even when the operator has no global signing configured.
git -C "$CLONE" config commit.gpgsign false || { warn "could not set commit.gpgsign=false in $CLONE"; rc=1; }
git -C "$CLONE" config tag.gpgsign false || { warn "could not set tag.gpgsign=false in $CLONE"; rc=1; }

# Surface 4 detection: would a push/fetch from the internal clone route through SSH?
# Yes if the clone's origin is already an ssh-form URL, or if a global insteadOf rule
# rewrites github HTTPS to SSH (the captain's url."git@github.com:".insteadOf case).
ORIGIN=$(git -C "$CLONE" remote get-url origin 2>/dev/null || true)
ssh_origin=false
case "$ORIGIN" in
  git@github.com:*|ssh://git@github.com/*) ssh_origin=true ;;
esac
global_rewrite=false
if git config --global --get-regexp 'url\..*\.insteadof' 2>/dev/null | grep -qi 'github\.com'; then
  global_rewrite=true
fi

if [ "$ssh_origin" = false ] && [ "$global_rewrite" = false ]; then
  # Plain-HTTPS origin and no rewrite: network ops already stay on HTTPS. Leave the
  # credential setup exactly as the operator has it (a clean machine that works).
  exit "$rc"
fi

# Parse owner/repo from the github origin. Only github.com is in scope (the rewrite and
# gh credential helper are github-specific); a non-github origin is left untouched.
OWNER_REPO=""
case "$ORIGIN" in
  *github.com:*) OWNER_REPO=${ORIGIN#*github.com:} ;;
  *github.com/*) OWNER_REPO=${ORIGIN#*github.com/} ;;
  *) warn "origin '$ORIGIN' is not on github.com; leaving remote/credentials untouched"; exit "$rc" ;;
esac
OWNER_REPO=${OWNER_REPO%.git}

# Resolve the GitHub username for the username-form URL. Prefer gh's authenticated
# login (it is the identity the "!gh auth git-credential" helper will serve); fall back
# to a user@ already embedded in the source repo's own origin URL.
USER=""
if command -v gh >/dev/null 2>&1; then
  USER=$(gh api user -q .login 2>/dev/null || true)
fi
if [ -z "$USER" ]; then
  SRC_ORIGIN=$(git -C "$REPO_PATH" remote get-url origin 2>/dev/null || true)
  case "$SRC_ORIGIN" in
    https://*@github.com/*) USER=${SRC_ORIGIN#https://}; USER=${USER%%@github.com/*} ;;
  esac
fi

if [ -n "$USER" ]; then
  NEW_URL="https://$USER@github.com/$OWNER_REPO.git"
  git -C "$CLONE" remote set-url origin "$NEW_URL" || { warn "could not rewrite origin to $NEW_URL in $CLONE"; rc=1; }
  # Belt: pull any internally-generated git@github.com: URL back to username-HTTPS.
  git -C "$CLONE" config "url.https://$USER@github.com/.insteadOf" 'git@github.com:' \
    || { warn "could not set repo-local insteadOf in $CLONE"; rc=1; }
else
  warn "could not resolve a GitHub username (no gh, no user@ in origin); leaving origin URL as-is"
fi

# Block the inherited hanging keychain helper and route credentials through gh. The
# empty first value resets the inherited helper list; gh then supplies tokens. Only
# meaningful when gh is present to actually answer the credential request.
if command -v gh >/dev/null 2>&1; then
  git -C "$CLONE" config --replace-all credential.helper '' || { warn "could not reset credential.helper in $CLONE"; rc=1; }
  git -C "$CLONE" config --add credential.helper '!gh auth git-credential' || { warn "could not add gh credential.helper in $CLONE"; rc=1; }
else
  warn "gh not found; leaving credential.helper as-is (pushes may hang on a locked keychain)"
fi

exit "$rc"
