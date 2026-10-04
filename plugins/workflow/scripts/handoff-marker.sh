#!/usr/bin/env bash
# handoff-marker.sh — the READ side of checkpoint.handoff_marker (issue #1058).
#
# #1056 added the marker so a context handoff records R — the re-orientation
# requests the resumed session spends before its first file-modifying request.
# The write side was specified and schema-enforced; the read side was not. A
# resumed session had to NOTICE an open marker, count from its very first
# request, and freeze the count at its first edit — and nothing prompted any of
# it. The count is only obtainable WHILE re-orienting, so a session that did not
# know to count could never recover the number. #1056 got R=3 only because an
# operator hand-wrote a STEP 0 into `next_action`; absent that, the marker is
# written and never filled in.
#
# This script closes that gap from the read side. next-issue's Phase 0 resume
# runs it FIRST (before any other request, so the count starts at ~1), and on an
# open marker it emits the counting directive itself — so the instruction no
# longer depends on the handing-off session having written one.
#
# FAIL OPEN — the opposite contract to context-budget.sh, and the reason this is
# a separate script rather than a subcommand of that one. context-budget.sh must
# fail LOUD: a bogus low reading suppresses a handoff that is due. This reader
# observes telemetry riding on a checkpoint that has a job to do, so a missing
# file, malformed JSON, a malformed marker, or an absent jq must never error or
# block the resume (handoff-protocol.md § Recording R, step "Fail open"). Every
# such path prints a classification and exits 0. Putting both contracts in one
# body is the trap context-budget.sh's own header warns against.
#
# ONE DEFINITION OF "OPEN". The classification is the same jq expression
# golem-handoff-relaunch.sh keys its relaunch on (a non-object marker is none;
# a non-null r_measured is counted — 0 included, since `// null` only replaces
# null/false; anything else is open). tests/validate-handoff-marker.sh pins the
# two readers to agree, so the orchestrator and the resumed session cannot
# disagree about whether a handoff is still waiting on its count.
#
# Usage:
#   handoff-marker.sh status <state-file>
#
# Output (`key=value` lines on stdout, the context-budget.sh convention):
#   marker      none | open | counted | unreadable
#   at          (open only) the marker's ISO timestamp, empty if absent
#   directive   (open only) the counting instruction to follow before any
#               other request
#
# Exit status:
#   0  always, for every state of the file — including unreadable
#   1  usage error (bad/missing subcommand or argument) — the CALLER's bug,
#      never a resume condition
#
# Portability: bash-3.2 clean; coreutils via the `command` builtin. shellcheck
# clean.
set -uo pipefail

usage() {
    command cat >&2 <<'EOF'
usage: handoff-marker.sh status <state-file>

Classifies the state file's checkpoint.handoff_marker as none | open | counted |
unreadable, and on `open` prints the R-counting directive. Always exits 0 for a
readable-or-not state file: a missing or malformed marker never blocks a resume.
EOF
}

if [ "$#" -ne 2 ] || [ "$1" != "status" ] || [ -z "$2" ]; then
    usage
    exit 1
fi

state_file="$2"

unreadable() {
    command printf 'marker=unreadable\n'
    exit 0
}

[ -r "$state_file" ] || unreadable
command -v jq >/dev/null 2>&1 || unreadable

# Keep in step with golem-handoff-relaunch.sh's two marker reads — the parity
# case in tests/validate-handoff-marker.sh fails if they diverge. `at` is
# flattened to one line so a newline in it cannot forge a later key=value line.
classified="$(command jq -r '
    (.checkpoint.handoff_marker // null) as $m
    | if ($m | type) != "object" then "none"
      elif ($m.r_measured // null) != null then "counted"
      else "open\t\(($m.at // "") | tostring | gsub("[\n\r\t]"; " "))"
      end' "$state_file" 2>/dev/null)" || unreadable

case "$classified" in
    none | counted)
        command printf 'marker=%s\n' "$classified"
        ;;
    open*)
        command printf 'marker=open\n'
        command printf 'at=%s\n' "${classified#open?}"
        command printf '%s\n' "directive=STEP 0 — this session resumes a context handoff whose re-orientation cost R is uncounted. Count every request you make starting with your first, and freeze the count at your first file-modifying request. Then write it to checkpoint.handoff_marker.r_measured, with a one-line r_measured_note naming what the re-orientation consisted of. If you lose the count, write null and say so; never reconstruct it afterwards."
        ;;
    *)
        unreadable
        ;;
esac
exit 0
