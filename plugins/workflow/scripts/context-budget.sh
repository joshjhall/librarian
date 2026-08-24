#!/usr/bin/env bash
# context-budget.sh — print a session's CURRENT context size and a bounded-length
# verdict, scraped from its Claude Code session transcript (TTY-free, fail-loud).
#
# Context (issue #784). Sessions run to 500k+ context with almost no compaction.
# Every request re-sends the whole accumulated context, so the last decile of a
# long session costs ~3x the first decile for identical work (measured
# price-weighted across 28 local transcripts: decile-9/decile-0 ratios 2.2-5.3x,
# median ~3.0x). Bounding session length — hand off to a fresh session rather than
# running to exhaustion — is the largest single lever in the #782-#788 series.
# Acting on that needs the signal to be MECHANICAL: before this script there was
# no way to read a session's current context size without an operator eyeballing
# Claude Code's usage indicator in an attached pane.
#
# A POINT READING, NOT A SUM — the one thing to get right about this file.
# golem-token-scrape.sh sums `output_tokens` across the whole transcript: a
# CUMULATIVE measure of work produced. This script reads the LAST top-level
# record's input side and does NOT sum: the current context size is a property of
# the most recent request, not an accumulation over the session. The two are
# opposite contracts over the same file, which is exactly why this is a separate
# script rather than a flag on that one — a `--mode` switch would put a summing
# branch and a last-record branch in one body, and picking the wrong one yields a
# number that is wrong by orders of magnitude while still looking like a token
# count. Only the transcript-RESOLUTION idiom is shared (deliberately duplicated,
# ~10 lines; see that script's header for the slug rule).
#
# WHAT COUNTS AS CONTEXT. `input_tokens + cache_read_input_tokens +
# cache_creation_input_tokens` on the newest top-level record. All three are
# context the model read on that request; they differ only in what they COST
# (cache reads are ~0.10x base, cache creation ~1.25x). The verdict is about
# SIZE, so it sums them undiscounted — the cost weighting belongs to the
# derivation, not the reading.
#
# THE THRESHOLD IS DERIVED, NOT PICKED (issue #784 AC2). Full derivation and its
# reproduction recipe: docs/verification/context-threshold-tally-784.md.
# The short version, because the number invites second-guessing:
#
#   * Pure token accounting CANNOT yield a threshold — it is monotonic. Cycling
#     sooner always wins (45.3% modeled saving at 150k falling to 13.8% at 400k),
#     so sweeping it just pins the threshold to the floor.
#   * The counterweight is RE-DERIVATION WORK: each handoff buys R requests of
#     re-orientation (re-reading the state file, the plan, the files already
#     read) that produce nothing. Adding that term gives a real interior optimum.
#   * Sweeping R from 3 to 50, the best threshold moves only 150k -> 200k, and
#     175k minimizes WORST-CASE REGRET at 4.1% (vs 6.1% at 150k, 14.5% at 250k,
#     30.1% at 400k). So 175k is robust across the whole plausible range of
#     handoff costs rather than tuned to one guessed value.
#
# This SUPERSEDES the 250-300k figure in #784's body, which assumed a 78k floor;
# the measured floor is ~91k. Both knobs are env-overridable, so an operator who
# disagrees changes a variable rather than this file.
#
# Config (env-overridable; see config.sh for the authoritative documentation):
#   CONTEXT_BUDGET_THRESHOLD  Handoff threshold, tokens.        Default: 175000
#   CONTEXT_BUDGET_FLOOR      Measured session floor, tokens.   Default: 91000
#   CLAUDE_PROJECTS_DIR       Base dir holding per-project transcript dirs.
#                             Default: $HOME/.claude/projects
#
# Usage:
#   context-budget.sh check <worktree-dir>
#
# Output (`key=value` lines on stdout, the threshold-check.sh convention):
#   context_tokens     the newest top-level request's context size
#   floor              CONTEXT_BUDGET_FLOOR
#   threshold          CONTEXT_BUDGET_THRESHOLD
#   pct_of_threshold   context_tokens as a whole-number percent of threshold
#   verdict            ok | advise | handoff
#
#   verdicts:
#     ok       — under the advisory band; keep working.
#     advise   — at/over 80% of threshold. An INTERACTIVE session surfaces this and
#                nothing else (#784 AC5 — never force-cycle a human's session); a
#                golem uses it to prefer finishing the current step over starting
#                a new one.
#     handoff  — at/over threshold. A GOLEM session writes its checkpoint into the
#                existing next-issue-{N}.json and ends, so the resumed session
#                restarts at the floor instead of at 400k. Still advisory for an
#                interactive session.
#
# WHAT THIS DOES NOT DO: it cannot end a session. Like threshold-check.sh (whose
# convention this follows), a bundled script runs in the sandboxed shell runtime
# and has no handle on the model runtime. This owns the VERDICT; the caller
# performs the handoff — but on this script's arithmetic, not its own reading of
# prose. See next-issue/handoff-protocol.md.
#
# FAIL LOUD — never a silent 0. A bogus low reading is worse than no reading: it
# reports "plenty of headroom" for a session that is actually at 400k, silently
# suppressing a handoff that is due. So a missing transcript / missing jq is a
# non-zero exit with an actionable message, and the caller renders "unknown".
#
# Exit status (mirrors golem-token-scrape.sh — the two are read by the same
# caller, so divergent codes for the same conditions would be a trap):
#   0  reading + verdict written to stdout
#   1  usage error (bad/missing subcommand or worktree-dir)
#   2  no transcript directory, no *.jsonl session, or no parsable top-level
#      record in it
#   3  jq not on PATH (cannot parse the transcript)
#
# Portability: bash-3.2 clean (no declare -A / mapfile / namerefs / ${v,,}); all
# coreutils reached via the `command` builtin, never a hardcoded /usr/bin path
# (issue #228/#241 — a hardcoded path exits 127 off /usr/bin). shellcheck clean.
set -uo pipefail

usage() {
    command cat >&2 <<'EOF'
usage: context-budget.sh check <worktree-dir>

Prints the session's current context size and a bounded-length verdict as
`key=value` lines: context_tokens, floor, threshold, pct_of_threshold, verdict
(ok | advise | handoff).

Exits non-zero (with a message) when the transcript is missing/unreadable or jq
is unavailable, so the caller renders "context unknown" rather than acting on a
bogus reading.
EOF
}

if [ "$#" -ne 2 ] || [ "$1" != "check" ]; then
    usage
    exit 1
fi

worktree="$2"

if [ -z "$worktree" ]; then
    usage
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    command echo "context-budget: jq not found on PATH — cannot parse transcript" >&2
    exit 3
fi

# Defaults live here as well as in config.sh so this script is runnable
# standalone (config.sh is sourced by the golem scripts, not by every caller).
# The two are pinned equivalent by tests/validate-context-budget.sh's drift
# guard — the same arrangement golem-notify.sh uses for its inlined sink
# defaults.
: "${CONTEXT_BUDGET_THRESHOLD:=175000}"
: "${CONTEXT_BUDGET_FLOOR:=91000}"

# Validate the knobs before use. An operator typo (`CONTEXT_BUDGET_THRESHOLD=175k`)
# must fail loud rather than silently compare against a string: under `[` a
# non-numeric operand is an "integer expression expected" error that would
# misclassify the verdict — the same octal/garbage hazard golem-status.sh guards
# its scraped counts against (`'' | 0* | *[!0-9]*`, at its :338 and :396).
#
# THE LEADING ZERO IS THE HALF THAT MATTERS, and it is why this guard copies that
# pattern rather than merely rejecting non-digits. A value like `0400000` is all
# digits, so a digits-only check passes it — and then the two spellings below
# disagree about what it means: `$(())` (advise_at, pct) reads a leading-`0`
# operand as OCTAL, while `[ ... -ge ... ]` compares it as DECIMAL. That
# disagreement is not theoretical; both arms were reproduced against this script:
#
#   * 0400000 -> `pct_of_threshold=231` beside `verdict=advise`. The percent says
#     the session is past the threshold and the verdict says it is not: two
#     outputs of one run contradicting each other, and a caller reading only the
#     verdict silently skips a handoff that is due. This is precisely the "bogus
#     reading that reads as right" the header forbids.
#   * 089000 -> an invalid octal literal, so `$(())` errors twice and the script
#     dies on `pct: unbound variable` under `set -u` — a crash rather than the
#     actionable message this guard exists to print.
#
# Rejecting `0*` also rejects a bare `0`, which is correct here: a zero threshold
# is separately refused below (it would divide by zero), and a zero floor is
# meaningless — the floor IS the cost of a fresh session.
for _cb_pair in "CONTEXT_BUDGET_THRESHOLD:$CONTEXT_BUDGET_THRESHOLD" \
    "CONTEXT_BUDGET_FLOOR:$CONTEXT_BUDGET_FLOOR"; do
    _cb_name="${_cb_pair%%:*}"
    _cb_val="${_cb_pair#*:}"
    case "$_cb_val" in
        '' | 0* | *[!0-9]*)
            command echo "context-budget: $_cb_name must be a positive integer with no leading zeros, got '$_cb_val'" >&2
            exit 1
            ;;
    esac
done

# BACKSTOP, currently unreachable — and deliberately kept. The `0*` arm of the
# guard above already rejects a literal `0` (and `*[!0-9]*` rejects a leading
# `-`), so nothing can reach this with a non-positive value today. It stays
# because the division at `pct` below is only safe while the threshold is
# positive, and that safety should not depend on a case-pattern several lines up
# continuing to reject `0*` — a future edit that loosens the leading-zero rule
# (say, to normalize `0400000` instead of refusing it) would silently
# reintroduce a divide-by-zero. Cheap insurance against a non-local change.
if [ "$CONTEXT_BUDGET_THRESHOLD" -le 0 ]; then
    command echo "context-budget: CONTEXT_BUDGET_THRESHOLD must be greater than 0" >&2
    exit 1
fi

# Absolute worktree path → Claude Code project-dir slug. Claude Code names each
# project transcript dir after the absolute cwd with every `/` and `.` replaced
# by `-` (verified on-disk: /workspace/librarian/.worktrees/issue-784 →
# -workspace-librarian--worktrees-issue-784). Resolve to absolute first so a
# relative worktree arg maps to the same slug the session produced.
case "$worktree" in
    /*) abs="$worktree" ;;
    *) abs="$(command pwd)/$worktree" ;;
esac
# Pattern substitution (`${v//[set]/repl}`) is bash-3.2 available — NOT a banned
# case-conversion (${v,,}/${v^^}); see tests/lint-shell-portability.sh.
slug="${abs//[\/.]/-}"

base="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
project_dir="$base/$slug"

if [ ! -d "$project_dir" ]; then
    command echo "context-budget: no transcript dir for $worktree ($project_dir)" >&2
    exit 2
fi

# Newest-mtime *.jsonl is the active session — and for THIS script that choice is
# load-bearing in a way it is not for the cumulative scraper: after a handoff the
# fresh session is a new file, so reading the newest is what makes the context
# size DROP back to the floor. Reading an older file would report the pre-handoff
# size forever and re-trigger a handoff that already happened.
shopt -s nullglob
newest=""
for f in "$project_dir"/*.jsonl; do
    if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then
        newest="$f"
    fi
done

if [ -z "$newest" ]; then
    command echo "context-budget: no *.jsonl session transcript in $project_dir" >&2
    exit 2
fi

# The LAST top-level record carrying an input side. `-R` + `fromjson?` reads
# line-by-line and skips a malformed/partial trailing line (expected when a
# session is captured mid-write), mirroring golem-token-scrape.sh and
# recover-journal-partials.sh; `-s` then collects the stream so `last` can pick
# the tail. Sub-workflow records are excluded for the same reason they are in the
# cumulative scrape: a sub-agent's context is its own, not this session's, and a
# large review fan-out would otherwise masquerade as top-level growth.
#
# NOTE `last(...)` over the filtered stream — NOT `.[-1]` over all records, whose
# tail is routinely a summary or a user record with no usage at all. A record
# with a `usage` object but no input fields contributes 0 through the `// 0`
# defaults, which is correct: that is a real request that read no context.
context="$(
    jq -R -s '
      [ split("\n")[]
        | select(length > 0)
        | (fromjson? // empty)
        | select((.isSidechain // false) == false)
        | select(.message.usage != null)
        | ((.message.usage.input_tokens // 0)
           + (.message.usage.cache_read_input_tokens // 0)
           + (.message.usage.cache_creation_input_tokens // 0))
      ]
      | last // empty
    ' "$newest" 2>/dev/null
)"

case "$context" in
    '' | *[!0-9]*)
        command echo "context-budget: no parsable top-level context reading in $newest" >&2
        exit 2
        ;;
esac

# The advisory band opens at 80% of threshold. It exists so a session gets a
# warning while it still has room to finish the step it is on: firing the
# advisory AT the threshold would make it simultaneous with the handoff and
# therefore useless. 80% of 175k is 140k — roughly 8-10 requests of headroom at
# the observed per-request growth, which is about one work step.
#
# Integer arithmetic throughout (no bc/awk): threshold is validated > 0 above, so
# the division is safe, and percent is floored — a floored 79 cannot cross into
# the advisory band early.
advise_at=$((CONTEXT_BUDGET_THRESHOLD * 80 / 100))
pct=$((context * 100 / CONTEXT_BUDGET_THRESHOLD))

if [ "$context" -ge "$CONTEXT_BUDGET_THRESHOLD" ]; then
    verdict="handoff"
elif [ "$context" -ge "$advise_at" ]; then
    verdict="advise"
else
    verdict="ok"
fi

command printf 'context_tokens=%s\n' "$context"
command printf 'floor=%s\n' "$CONTEXT_BUDGET_FLOOR"
command printf 'threshold=%s\n' "$CONTEXT_BUDGET_THRESHOLD"
command printf 'pct_of_threshold=%s\n' "$pct"
command printf 'verdict=%s\n' "$verdict"
