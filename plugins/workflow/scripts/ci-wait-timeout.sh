#!/usr/bin/env bash
# ci-wait-timeout — deterministic stop DECISION for the ship-issue CI-wait poll
# loop (`gh pr checks` every 30 s while checks are pending).
#
# Issue #588. LIBRARIAN_CI_WAIT_TIMEOUT and LIBRARIAN_CI_WAIT_MAX_EXTENSIONS were
# documented across six prose files with stated defaults and specific operational
# semantics — and read by NO code in any language. The bound existed only as an
# instruction the shipping model was expected to carry out by hand: track
# cumulative wait, compare it to the threshold, count extensions, STOP at the
# ceiling. An operator who set LIBRARIAN_CI_WAIT_TIMEOUT=5 had no guarantee it
# took effect and no way to tell whether it had.
#
# That is the same shape as #307/#327 one layer up: the Workflow wall-timeout was
# also prose the model had to interpret, and three golems (266/252/263) wedged
# unbounded before workflow-wall-timeout.sh mechanized it. This file closes the
# same gap for the CI-wait loop — which, unlike the review fan-out, runs on every
# single ship.
#
# What this does NOT do: it does not poll and cannot stop anything. `gh pr checks`
# runs in the model runtime; a bundled script runs in the sandboxed shell runtime.
# So this owns the DECISION and the caller polls on its verdict, rather than on
# its own reading of prose. The verdict arithmetic itself is shared with
# workflow-wall-timeout.sh via threshold-check.sh.
#
# Subcommand (emits `key=value` lines to stdout):
#   check --elapsed-min N --level L [--extensions-used K]
#         -> verdict           continue | extend | stop | checkpoint
#            ceiling_min        TIMEOUT * (MAX_EXTENSIONS + 1)   (the hard cap)
#            next_deadline_min  the wall-time of the next checkpoint to poll to
#            extensions_used    K, or K+1 when the verdict is `extend`
#
#   verdicts:
#     continue   — still under the current checkpoint; keep polling every 30 s.
#     extend     — crossed the checkpoint, extensions remain, L3-L4: auto-grant
#                  one more interval (extensions_used echoes K+1).
#     checkpoint — crossed the checkpoint, extensions remain, L1-L2: prompt the
#                  human for cut-short vs extend (never auto-extend interactively).
#     stop       — the ceiling is reached: stop waiting and proceed to the
#                  completion summary with a "CI still pending" note. This is a
#                  machine timer for PENDING CI, not a human gate — the
#                  never-time-out-a-human-gate rule does not apply to it.
#
# Env overrides (defaults match ship-protocol.md § Environment Variables):
#   LIBRARIAN_CI_WAIT_TIMEOUT         integer minutes, default 15
#   LIBRARIAN_CI_WAIT_MAX_EXTENSIONS  integer >= 0,     default 2
# Default ceiling is therefore 15 * (2 + 1) = 45 minutes.
#
# Exit codes: 0 = success; 2 = usage error (bad subcommand / flag / value).
#
# Runtime: bash-only (no python port — precedent: recover-journal-partials.sh).
# bash-3.2 clean (no associative arrays / mapfile / namerefs / case-conversion),
# clean under shellcheck, all coreutils reached via the `command` builtin, and
# fails loud on any bad input rather than emitting a wrong verdict. See CLAUDE.md
# § Key conventions (runtime policy).
set -euo pipefail

SCRIPT_DIR="$(cd "$(command dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./threshold-check.sh
. "$SCRIPT_DIR/threshold-check.sh"

USAGE="Usage: ci-wait-timeout check --elapsed-min N --level L [--extensions-used K]
  N = cumulative minutes spent waiting on CI so far (non-negative integer)
  L = autonomy level 1-4
  K = extensions already granted (non-negative integer, default 0)
env: LIBRARIAN_CI_WAIT_TIMEOUT (default 15),
     LIBRARIAN_CI_WAIT_MAX_EXTENSIONS (default 2)"

threshold_check_main \
    "ci-wait-timeout" \
    "LIBRARIAN_CI_WAIT_TIMEOUT" 15 \
    "LIBRARIAN_CI_WAIT_MAX_EXTENSIONS" 2 \
    "$USAGE" \
    "$@"
