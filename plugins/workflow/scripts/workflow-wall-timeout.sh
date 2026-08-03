#!/usr/bin/env bash
# workflow-wall-timeout — deterministic wall-time stop DECISION for a bounded
# `Workflow` tool invocation (the ship-issue review / ci-fixer fan-out).
#
# Single source of truth for the "should I keep waiting on this Workflow run?"
# arithmetic (issue #327). #307 added LIBRARIAN_WORKFLOW_WALL_TIMEOUT to bound a
# hung review harness (#224), but wired it in as skill-instruction PROSE: the
# ship-issue *model* had to track cumulative wait, compare it to the threshold,
# count extensions, and TaskStop at the ceiling by hand. A model deep in a review
# cycle does not reliably do that arithmetic — three golems wedged unbounded
# (golem-266/252/263), same class as the pre-0.6 MAX_CYCLES-in-prose cap-drift.
# The skills now CALL this instead, so the threshold logic cannot drift.
#
# What this does NOT do: it does not (and cannot) forcibly stop the run. The
# `Workflow` / `TaskOutput` / `TaskStop` tools live in the model runtime; a
# bundled script runs in the sandboxed shell runtime and has no handle on a
# Workflow task. So this owns the DECISION (mirroring how autonomy-resolve.sh
# owns the L1-L4 disposition table); the caller still issues the actual TaskStop
# tool call — but on this script's verdict, not on its own reading of prose.
#
# The decision itself lives in threshold-check.sh, shared with ci-wait-timeout.sh
# (#588): the two loops differ only in env var names and defaults, so a second
# copy of the ceiling arithmetic would re-open exactly the drift this file closed.
# This wrapper owns the wall-timeout identity; that library owns the verdict.
#
# Subcommand (emits `key=value` lines to stdout):
#   check --elapsed-min N --level L [--extensions-used K]
#         -> verdict           continue | extend | stop | checkpoint
#            ceiling_min        TIMEOUT * (MAX_EXTENSIONS + 1)   (the hard cap)
#            next_deadline_min  the wall-time of the next checkpoint to poll to
#            extensions_used    K, or K+1 when the verdict is `extend`
#
#   verdicts:
#     continue   — still under the current checkpoint; keep polling.
#     extend     — crossed the checkpoint, extensions remain, L3-L4: auto-grant
#                  one more interval (extensions_used echoes K+1).
#     checkpoint — crossed the checkpoint, extensions remain, L1-L2: a human
#                  chooses cut-short vs extend (never auto-extend interactively).
#     stop       — the ceiling is reached (extensions exhausted, or elapsed is
#                  already past ceiling): TaskStop the run and recover partials.
#
# Env overrides (same vars #307 defined; defaults match ship-protocol.md):
#   LIBRARIAN_WORKFLOW_WALL_TIMEOUT         integer minutes, default 20
#   LIBRARIAN_WORKFLOW_WALL_MAX_EXTENSIONS  integer >= 0,     default 1
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

USAGE="Usage: workflow-wall-timeout check --elapsed-min N --level L [--extensions-used K]
  N = cumulative wall-minutes waited so far (non-negative integer)
  L = autonomy level 1-4
  K = extensions already granted (non-negative integer, default 0)
env: LIBRARIAN_WORKFLOW_WALL_TIMEOUT (default 20),
     LIBRARIAN_WORKFLOW_WALL_MAX_EXTENSIONS (default 1)"

threshold_check_main \
    "workflow-wall-timeout" \
    "LIBRARIAN_WORKFLOW_WALL_TIMEOUT" 20 \
    "LIBRARIAN_WORKFLOW_WALL_MAX_EXTENSIONS" 1 \
    "$USAGE" \
    "$@"
