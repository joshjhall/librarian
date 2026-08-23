# shellcheck shell=bash
# workflow Python tools corpus — python coverage fixtures (issue #748).
#
# Fixtures for the five shipped Python tools that are NOT named patterns.py and
# so were never reached by the glob-driven corpus:
#
#   ship-issue/sizing.py             the review-lens size scanner
#   ship-issue/plan-lens.py          the plan-lens projection scanner (#756)
#   ship-issue/split-verify.py       proves a decomposition lost nothing
#   scripts/autonomy-resolve.py      resolves L1-L4 + the critical cap
#   scripts/golem-event-listener.py  the orchestrate feed receiver
#
# Sourced by tests/coverage-python.sh, which creates WORKDIR and its EXIT trap
# BEFORE this file. This fragment only BUILDS FIXTURES and exports the path-list
# variables the driver section then feeds to the tools under `coverage run`.
#
# The fixture SHAPES are deliberately the ones the behavioral gates already
# build — validate-sizing-scanner.sh's def-per-two-lines Python file and
# `added<TAB>0<TAB>path` numstat row, validate-split-verify.sh's parse_*/render_all
# original and its three splits, validate-plan-lens.sh's estimate sidecar. Same
# shapes, not a second drifting set (#748 AC3): a corpus that invents its own
# inputs stops resembling what the gates pin, and then measures code paths
# nothing asserts about.
#
# NOTE: unlike the tests/ fragments, nothing here asserts — coverage-python.sh is
# a Codecov driver, not a test suite. The behavioural gates for these tools are
# tests/validate-sizing-scanner.sh, tests/validate-plan-lens.sh,
# tests/validate-split-verify.sh, tests/validate-autonomy-resolve.sh and
# tests/validate-golem-event-listener.sh; this corpus is kept in lockstep with
# them.

# The path-list / fixture-path variables below are the corpus's EXPORT surface:
# they are read by the driver loop in tests/coverage-python.sh, which sources
# this file. shellcheck analyses one file at a time and so cannot see those uses.
# shellcheck disable=SC2034  # consumed by the driver in tests/coverage-python.sh

WFDIR="$WORKDIR/workflow-tools"
mkdir -p "$WFDIR/agents" "$WFDIR/skills/big" "$WFDIR/docs"

# --- helper: a Python file with N trivial top-level defs (~2 LOC each) -------
# Mirrors make_py_file in tests/validate-sizing-scanner.sh.
_wf_make_py() {
    _wf_path="$1"
    _wf_n="$2"
    _wf_i=0
    : >"$_wf_path"
    while [ "$_wf_i" -lt "$_wf_n" ]; do
        printf 'def unit_%d(x):\n    return x + %d\n' "$_wf_i" "$_wf_i" >>"$_wf_path"
        _wf_i=$((_wf_i + 1))
    done
    unset _wf_path _wf_n _wf_i
}

# =============================================================================
# sizing.py + plan-lens.py — the two size lenses
# =============================================================================
#
# Three sizes so both lenses reach every disposition:
#   OVER  (~640 LOC)  over the 500/700 py budget           -> flagged
#   NEAR  (~320 LOC)  UNDER budget today                   -> plan-lens only:
#                     silent for the review lens, but the row plan-lens exists
#                     to produce once an estimate pushes it over
#   SMALL (~20 LOC)   well under                           -> the early-return
_wf_make_py "$WFDIR/over.py" 320
_wf_make_py "$WFDIR/near.py" 160
_wf_make_py "$WFDIR/small.py" 10

# Classified prose (#724): an agents/*.md carries its OWN 250/400 budget, not the
# generic md pair — the bloat_spec classification arm. A skills/**/SKILL.md and a
# plain doc drive the other two classifications.
_wf_i=0
: >"$WFDIR/agents/big-agent.md"
while [ "$_wf_i" -lt 300 ]; do
    printf 'Line %d of an oversized agent definition.\n' "$_wf_i" >>"$WFDIR/agents/big-agent.md"
    _wf_i=$((_wf_i + 1))
done
: >"$WFDIR/skills/big/SKILL.md"
_wf_i=0
while [ "$_wf_i" -lt 120 ]; do
    printf 'Line %d of a skill body.\n' "$_wf_i" >>"$WFDIR/skills/big/SKILL.md"
    _wf_i=$((_wf_i + 1))
done
: >"$WFDIR/docs/guide.md"
_wf_i=0
while [ "$_wf_i" -lt 60 ]; do
    printf 'Line %d of ordinary documentation prose.\n' "$_wf_i" >>"$WFDIR/docs/guide.md"
    _wf_i=$((_wf_i + 1))
done
unset _wf_i

# The scan lists.
SIZING_LIST="$WFDIR/sizing-list.txt"
{
    printf '%s\n' "$WFDIR/over.py"
    printf '%s\n' "$WFDIR/near.py"
    printf '%s\n' "$WFDIR/small.py"
    printf '%s\n' "$WFDIR/agents/big-agent.md"
    printf '%s\n' "$WFDIR/skills/big/SKILL.md"
    printf '%s\n' "$WFDIR/docs/guide.md"
    # A leading-blank + ghost path drive the empty-token and isfile()==False
    # skip arms, the same way the loop-port lists do.
    printf '\n'
    printf '%s\n' "$WFDIR/ghost-never-created.py"
} >"$SIZING_LIST"

# An unreadable file that passes isfile() -> the per-file OSError read arm.
SIZING_UNREAD="$WFDIR/unreadable.py"
_wf_make_py "$SIZING_UNREAD" 12
chmod 000 "$SIZING_UNREAD" 2>/dev/null || true
SIZING_UNREAD_LIST="$WFDIR/sizing-unread-list.txt"
printf '%s\n' "$SIZING_UNREAD" >"$SIZING_UNREAD_LIST"

# A list PATH that does not exist -> the file-list-not-found (OSError) arm.
SIZING_NOFILE_LIST="$WFDIR/sizing-nonexistent-XYZ.txt"

# An EMPTY list -> the empty-list early-return arm.
SIZING_EMPTY_LIST="$WFDIR/sizing-empty.txt"
: >"$SIZING_EMPTY_LIST"

# numstat sidecar, `added<TAB>deleted<TAB>path` (make_numstat in the gate).
# BIG growth on the over-budget file -> the blocking/crossed disposition.
SIZING_NUMSTAT_BIG="$WFDIR/numstat-big.txt"
{
    printf '600\t0\t%s\n' "$WFDIR/over.py"
    printf '300\t0\t%s\n' "$WFDIR/agents/big-agent.md"
} >"$SIZING_NUMSTAT_BIG"

# TRIVIAL growth on the same file -> the "pre-existing debt, not this PR's" arm,
# which is the disposition that distinguishes this lens from check-decomposition.
SIZING_NUMSTAT_TRIVIAL="$WFDIR/numstat-trivial.txt"
printf '1\t0\t%s\n' "$WFDIR/over.py" >"$SIZING_NUMSTAT_TRIVIAL"

# A numstat naming a file NOT in the scan list -> the unmatched-row arm.
SIZING_NUMSTAT_ORPHAN="$WFDIR/numstat-orphan.txt"
printf '50\t0\t%s\n' "$WFDIR/not-in-list.py" >"$SIZING_NUMSTAT_ORPHAN"

# plan-lens estimate sidecar, `added<TAB>path` (one column fewer than numstat).
# The load-bearing row is near.py: UNDER budget now, OVER once the estimate
# lands. That projection is the row no other lens can produce (#756), so a
# corpus without it measures plan-lens without touching its reason to exist.
PLANLENS_EST_CROSS="$WFDIR/est-cross.txt"
{
    printf '400\t%s\n' "$WFDIR/near.py"
    printf '200\t%s\n' "$WFDIR/agents/big-agent.md"
} >"$PLANLENS_EST_CROSS"

# An estimate that leaves everything comfortably under -> the no-row arm.
PLANLENS_EST_SMALL="$WFDIR/est-small.txt"
printf '5\t%s\n' "$WFDIR/small.py" >"$PLANLENS_EST_SMALL"

# A malformed estimate row (no tab / non-numeric) -> the parse-skip arms.
PLANLENS_EST_BAD="$WFDIR/est-bad.txt"
{
    printf 'not-a-number\t%s\n' "$WFDIR/near.py"
    printf 'no-tab-at-all\n'
    printf '\n'
} >"$PLANLENS_EST_BAD"

# =============================================================================
# split-verify.py — <original> <post-split> [results...]
# =============================================================================
#
# The parse_*/render_all original from tests/validate-split-verify.sh, split
# three ways: soundly, with a unit dropped, and with the fan-in left dangling.
SPLIT_ORIG="$WFDIR/split-orig.py"
{
    printf 'def parse_entry(x):\n    return x + 1\n\n'
    printf 'def parse_header(x):\n    return x + 2\n\n'
    printf 'def parse_body(x):\n    return x + 3\n\n'
    printf 'def render_all(x):\n    return parse_entry(x) + parse_header(x) + parse_body(x)\n'
} >"$SPLIT_ORIG"

# Sound split: the parse_* family moved out, the original keeps render_all and
# imports what it moved -> split-verified.
SPLIT_KEPT="$WFDIR/split-kept.py"
{
    printf 'from parse import parse_entry, parse_header, parse_body\n\n'
    printf 'def render_all(x):\n    return parse_entry(x) + parse_header(x) + parse_body(x)\n'
} >"$SPLIT_KEPT"
SPLIT_MOVED="$WFDIR/split-parse.py"
{
    printf 'def parse_entry(x):\n    return x + 1\n\n'
    printf 'def parse_header(x):\n    return x + 2\n\n'
    printf 'def parse_body(x):\n    return x + 3\n'
} >"$SPLIT_MOVED"

# Lossy split: parse_body vanished entirely -> split-unit-lost (+ loc-drift).
SPLIT_LOSSY="$WFDIR/split-lossy.py"
{
    printf 'def parse_entry(x):\n    return x + 1\n\n'
    printf 'def parse_header(x):\n    return x + 2\n'
} >"$SPLIT_LOSSY"

# Dangling fan-in: render_all still CALLS parse_entry but nothing defines or
# imports it in the result set -> split-fanin-dangling.
SPLIT_DANGLE="$WFDIR/split-dangle.py"
printf 'def render_all(x):\n    return parse_entry(x)\n' >"$SPLIT_DANGLE"

# Markdown: a heading moved out WITHOUT a link back -> split-heading-unreachable;
# and the same split WITH the link -> the reachable arm.
SPLIT_MD_ORIG="$WFDIR/split-orig.md"
{
    printf '# Guide\n\n'
    printf '## Setup\n\nSetup prose.\n\n'
    printf '## Advanced\n\nAdvanced prose.\n'
} >"$SPLIT_MD_ORIG"
SPLIT_MD_KEPT_NOLINK="$WFDIR/split-kept-nolink.md"
{
    printf '# Guide\n\n'
    printf '## Setup\n\nSetup prose.\n'
} >"$SPLIT_MD_KEPT_NOLINK"
SPLIT_MD_KEPT_LINK="$WFDIR/split-kept-link.md"
{
    printf '# Guide\n\n'
    printf '## Setup\n\nSetup prose.\n\n'
    printf 'See [Advanced](split-advanced.md).\n'
} >"$SPLIT_MD_KEPT_LINK"
SPLIT_MD_MOVED="$WFDIR/split-advanced.md"
{
    printf '# Advanced\n\n'
    printf '## Advanced\n\nAdvanced prose.\n'
} >"$SPLIT_MD_MOVED"

# Memory bundle (#729): a concept extracted from a bundle must be named by an
# index. Both arms — orphaned (no index line) and indexed.
SPLIT_MEM_ROOT="$WFDIR/membundle"
mkdir -p "$SPLIT_MEM_ROOT/.claude/memory"
SPLIT_MEM_ORIG="$SPLIT_MEM_ROOT/.claude/memory/big-concept.md"
{
    printf '# Big concept\n\n'
    printf '## First idea\n\nFirst prose.\n\n'
    printf '## Second idea\n\nSecond prose.\n'
} >"$SPLIT_MEM_ORIG"
SPLIT_MEM_KEPT="$SPLIT_MEM_ROOT/.claude/memory/big-concept-kept.md"
{
    printf '# Big concept\n\n'
    printf '## First idea\n\nFirst prose.\n'
} >"$SPLIT_MEM_KEPT"
SPLIT_MEM_MOVED="$SPLIT_MEM_ROOT/.claude/memory/second-idea.md"
{
    printf '# Second idea\n\n'
    printf '## Second idea\n\nSecond prose.\n'
} >"$SPLIT_MEM_MOVED"
SPLIT_MEM_INDEX="$SPLIT_MEM_ROOT/.claude/memory/MEMORY.md"
printf '# Memory index\n\n- [Second idea](second-idea.md) — hook\n' >"$SPLIT_MEM_INDEX"

# A named file that does not exist -> the missing-file usage arm.
SPLIT_GHOST="$WFDIR/split-ghost-never-created.py"

# =============================================================================
# golem-event-listener.py — feed receiver
# =============================================================================
#
# A status dir holding feed.jsonl, laid out the way the readers expect
# (GOLEM_STATUS_DIR is repo-root-relative; the driver cds into this sandbox).
LISTENER_SB="$WFDIR/listener-sandbox"
mkdir -p "$LISTENER_SB/.worktrees/.status"
LISTENER_FEED="$LISTENER_SB/.worktrees/.status/feed.jsonl"
: >"$LISTENER_FEED"
