#!/usr/bin/env bash
# Compatibility source for real-Herdr tests.
# The production owner of the isolation, refuse-default, teardown, and
# fleet-state tripwire contract is bin/fm-herdr-lab.sh.
set -u

# Herdr backend tests drive the real fm-spawn/fm-teardown but do not source
# tests/lib.sh, so exempt them from the gate-lifecycle refusal here too (see
# tests/lib.sh and bin/fm-gate-refuse-lib.sh for why firstmate's own suite,
# which the no-mistakes gate runs from a gate worktree, must be exempt).
export FM_GATE_REFUSE_BYPASS=1

# Same reason: these tests do not source tests/lib.sh, so mirror its host git
# config isolation here. Fixture and fm-spawn/treehouse commits must never
# inherit the operator's global commit.gpgsign=true (a GUI/1Password signer that
# hangs or fails "failed to write commit object" in a non-interactive run) or a
# url.<ssh>.insteadOf rewrite. Suites needing a specific config re-export these
# after sourcing, which overrides the defaults.
: "${GIT_CONFIG_GLOBAL:=/dev/null}"
: "${GIT_CONFIG_SYSTEM:=/dev/null}"
export GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM

HERDR_TEST_SAFETY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bin/fm-herdr-lab.sh
. "$HERDR_TEST_SAFETY_DIR/bin/fm-herdr-lab.sh"

herdr_refuse_if_default() { # <session>
  fm_herdr_lab_refuse_if_default "$1"
}

herdr_safe_stop_and_delete() { # <session>
  fm_herdr_lab_teardown "$1"
}
