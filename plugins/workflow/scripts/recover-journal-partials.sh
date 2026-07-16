#!/usr/bin/env bash
# recover-journal-partials.sh — best-effort, schema-tolerant recovery of the
# finding-shaped results a fan-out review harness collected BEFORE it was stopped.
#
# Context (issue #224): a `workflow.js` review harness (e.g. ship-issue's
# `next-issue-review`) fans reviewer subagents under a shared token budget but
# has NO wall-clock bound — the sandbox bans clocks/timers (Date.now/new Date
# throw, no setTimeout/AbortSignal), so a harness cannot self-deadline. The
# caller (the ship-issue skill turn) bounds the wait instead and `TaskStop`s a
# run that overruns `LIBRARIAN_WORKFLOW_WALL_TIMEOUT`. When it does, the findings
# already produced live in the run's journal; the issue notes they "had to be
# recovered by hand". This script makes that recovery a defined step.
#
# It reads a Workflow-run journal (`<transcriptDir>/journal.jsonl`) and emits, as
# a JSON array on stdout, every object anywhere inside it that carries the
# harness FINDING_SCHEMA fingerprint (severity + file + line_start + category +
# title). The journal's line schema is owned by the Workflow-tool RUNTIME and is
# NOT documented in this repo, so this scan is deliberately structure-agnostic:
# it walks each record's nested values and keeps the finding-shaped ones,
# ignoring anything it cannot parse. Recovered findings are a PARTIAL cycle — the
# caller must treat the review as never-clean (same as `budget_exhausted`).
#
# Usage:
#   recover-journal-partials.sh <path/to/journal.jsonl>
#
# Exit status (fail loud — the caller degrades to its manual-recovery note on any
# non-zero, never silently emits an empty result):
#   0  journal read; a JSON array (possibly empty []) written to stdout
#   1  usage error (no path argument)
#   2  journal file missing or unreadable
#   3  `jq` not on PATH (cannot parse JSONL)
#
# Portability: bash-3.2 clean (no declare -A / mapfile / namerefs / ${v,,}); all
# coreutils reached via the `command` builtin, never a hardcoded /usr/bin path
# (issue #228/#241 — a hardcoded path exits 127 off /usr/bin). shellcheck clean.
set -euo pipefail

usage() {
    command cat >&2 <<'EOF'
usage: recover-journal-partials.sh <path/to/journal.jsonl>

Emits a JSON array of finding-shaped objects recovered from a Workflow-run
journal to stdout. Exits non-zero (with a message) when the journal is missing,
unreadable, or jq is unavailable, so the caller can fall back to manual recovery.
EOF
}

if [ "$#" -ne 1 ]; then
    usage
    exit 1
fi

journal="$1"

if [ ! -f "$journal" ] || [ ! -r "$journal" ]; then
    command echo "recover-journal-partials: journal not found or unreadable: $journal" >&2
    exit 2
fi

if ! command -v jq >/dev/null 2>&1; then
    command echo "recover-journal-partials: jq not found on PATH — cannot parse $journal" >&2
    exit 3
fi

# Recursively walk every value in every JSONL record and keep the objects that
# look like a harness finding. The fingerprint is the FINDING_SCHEMA's required
# scalar keys (severity + file + line_start + category + title); matching on the
# shape, not a fixed nesting depth, keeps this robust to a runtime journal schema
# this repo does not control. `fromjson? // empty` drops any malformed/non-JSON
# line without aborting (a truncated final line is expected when a run is killed
# mid-write). `..` recurses into nested arrays/objects so a finding wrapped in a
# result envelope is still found. `-s` collects the per-line streams into one
# array; the outer object-filter dedups nothing (the caller keys by `ref`).
jq -R -s '
  [ split("\n")[]
    | select(length > 0)
    | (fromjson? // empty)
    | ..
    | objects
    | select(
        (has("severity")   and (.severity   | type) == "string") and
        (has("file")       and (.file       | type) == "string") and
        (has("line_start") and (.line_start | type) == "number") and
        (has("category")   and (.category   | type) == "string") and
        (has("title")      and (.title      | type) == "string")
      )
  ]
' "$journal"
