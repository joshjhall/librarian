#!/usr/bin/env bash
# golem-token-scrape.sh — print a golem's cumulative TOP-LEVEL token count,
# scraped from its Claude Code session transcript (TTY-free, fail-loud).
#
# Context (issue #371, feeding #369's slow-review takeover contract): the
# takeover offer gates on a "frozen top-level token counter for a 45–60 min
# window, sampled each status sweep". `golem-status.sh` had no way to observe
# that signal, forcing an operator to attach to each pane and read Claude Code's
# usage indicator by eye. This script makes the reading mechanical for a LOCAL
# worktree golem (Mode 2) whose transcript is host-readable.
#
# It resolves the golem worktree's Claude Code project directory
# (`<projects>/<slug>/`, where <slug> is the worktree's absolute path with every
# `/` and `.` replaced by `-`), picks the newest-mtime `*.jsonl` session
# transcript there, and sums `message.usage.output_tokens` over the TOP-LEVEL
# records only (`isSidechain == false` / absent). `output_tokens` is the
# "work produced" signal — cache-read/creation inputs balloon and are not work —
# and the isSidechain filter is exactly the contract's top-level-vs-sub-workflow
# distinction (a bare pane counter cannot express it): a sub-workflow review can
# churn tokens while the top level is genuinely wedged, and vice-versa.
#
# DEDUP BY message.id. Claude Code writes ONE transcript line per assistant
# CONTENT BLOCK (thinking / text / each tool_use), not one per turn, and every
# line of a turn repeats that turn's SAME `usage.output_tokens` value. Summing
# per line therefore multi-counts a turn by its block count (empirically ~2.7x on
# real transcripts: a 6-block turn repeats output_tokens=807 six times). We group
# by `message.id` and take one value per id so the total is the true cumulative
# top-level output — the number persisted to the cache and shown to the operator.
#
# MODE 2 ONLY. A Mode 3 container golem runs Claude Code INSIDE its container, so
# its transcript is not on the host — the caller (golem-status.sh) skips this
# script for a golem with a `.container` cache field. This scraper stays Mode 2
# only: for Mode 3 the container POSTs its own top-level usage back into the host
# cache (top_level_tokens/_at), and golem-status.sh READS those fields directly
# to render the same frozen-counter signal — no host-side scrape (issue #390).
#
# Config (env-overridable; defaults match Claude Code's on-disk layout):
#   CLAUDE_PROJECTS_DIR  Base dir holding per-project transcript dirs.
#                        Default: $HOME/.claude/projects
#
# Usage:
#   golem-token-scrape.sh <worktree-dir>
#
# Output: the integer token count on stdout (0 for a transcript with no top-level
# output yet). FAIL LOUD — the frozen-counter check must never act on a bogus
# reading, so a missing transcript / missing jq is a non-zero exit with an
# actionable message, NOT a silent 0. The caller renders "tokens unknown".
#
# Exit status:
#   0  count written to stdout
#   1  usage error (no worktree-dir argument)
#   2  no transcript directory or no *.jsonl session for this worktree
#   3  jq not on PATH (cannot parse the transcript)
#
# Portability: bash-3.2 clean (no declare -A / mapfile / namerefs / ${v,,}); all
# coreutils reached via the `command` builtin, never a hardcoded /usr/bin path
# (issue #228/#241 — a hardcoded path exits 127 off /usr/bin). shellcheck clean.
set -uo pipefail

usage() {
    command cat >&2 <<'EOF'
usage: golem-token-scrape.sh <worktree-dir>

Prints the golem's cumulative top-level token count (top-level output_tokens
summed from its Claude Code session transcript) to stdout. Exits non-zero (with
a message) when the transcript is missing/unreadable or jq is unavailable, so the
caller can render "tokens unknown" instead of a bogus frozen reading.
EOF
}

if [ "$#" -ne 1 ]; then
    usage
    exit 1
fi

worktree="$1"

if ! command -v jq >/dev/null 2>&1; then
    command echo "golem-token-scrape: jq not found on PATH — cannot parse transcript" >&2
    exit 3
fi

# Absolute worktree path → Claude Code project-dir slug. Claude Code names each
# project transcript dir after the absolute cwd with every `/` and `.` replaced
# by `-` (verified on-disk: /workspace/librarian/.worktrees/issue-254 →
# -workspace-librarian--worktrees-issue-254). Resolve to absolute first so a
# relative worktree arg maps to the same slug the golem's session produced.
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
    command echo "golem-token-scrape: no transcript dir for $worktree ($project_dir)" >&2
    exit 2
fi

# Newest-mtime *.jsonl is the active session. A post-/clear session is a fresh
# file, so a count DROP across sessions reads as "changed" to the caller — which
# is correct (the run advanced), never a false freeze. `ls -t` orders by mtime;
# nullglob keeps the loop empty (not a literal `*.jsonl`) when none exist.
shopt -s nullglob
newest=""
for f in "$project_dir"/*.jsonl; do
    if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then
        newest="$f"
    fi
done

if [ -z "$newest" ]; then
    command echo "golem-token-scrape: no *.jsonl session transcript in $project_dir" >&2
    exit 2
fi

# Sum output_tokens over TOP-LEVEL records, ONE value per assistant turn
# (deduped by message.id — see the header note). `-R` + `fromjson?` reads
# line-by-line and skips a malformed/partial trailing line (expected when a
# session is captured mid-write), mirroring recover-journal-partials.sh; `-s`
# then collects the stream so `group_by` can dedup. Records without a
# `message.usage.output_tokens` are dropped; each retained record keys on its
# `message.id` (a rare id-less usage record falls back to a unique key so it is
# never collapsed into another turn), and one representative value per key is
# summed — the values are identical across a turn's blocks, so `.[0]` is exact.
count="$(
    jq -R -s '
      [ split("\n")[]
        | select(length > 0)
        | (fromjson? // empty)
        | select((.isSidechain // false) == false)
        | select(.message.usage.output_tokens != null)
        | { id: .message.id, tok: .message.usage.output_tokens }
      ]
      | to_entries
      | group_by(.value.id // "__noid__\(.key)")
      | map(.[0].value.tok)
      | add // 0
    ' "$newest" 2>/dev/null
)"

case "$count" in
    '' | *[!0-9]*)
        command echo "golem-token-scrape: could not parse a token count from $newest" >&2
        exit 2
        ;;
esac

command printf '%s\n' "$count"
