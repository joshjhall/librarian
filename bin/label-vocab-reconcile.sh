#!/usr/bin/env bash
# status/* label vocabulary reconciler — the ONLINE half of the #921 contract
# (issue #938, follow-up to #921 AC4).
#
# WHAT THIS EXISTS TO CATCH. tests/lint-status-label-refs.sh enforces one
# direction offline: prose in plugins/**/*.md may not name a `status/*` label
# that no metadata.yml declares. Being offline is right — run-all.sh runs in CI
# and in lefthook's pre-push, neither of which can assume `gh` auth, so a network
# gate there would live on the 77 skip sentinel and catch nothing — but it costs
# exactly the direction that caused #921:
#
#   prose names a label nothing declares    -> the offline gate
#   a declared label is DELETED or RENAMED  -> here, and nowhere else
#
# Nothing under plugins/** changes when someone renames a label in the GitHub UI.
# The offline gate stays green while every `gh issue edit --add-label` in the
# pipeline starts failing — and because a combined add+remove call applies the
# remove and then fails the add (measured on #921), an in-flight issue is left
# with NO status label and is briefly re-selectable by another golem (#636).
#
# ONE PARSER, NOT TWO. The declared side comes from bin/lib/label-vocab.sh, which
# tests/lint-status-label-refs.sh sources too. Two parsers over one vocabulary
# that must agree is the duplication #663 was filed to eliminate, and here the
# drift would be silent in the worst direction: a reconciler whose parser read
# narrow would report a perfectly-declared label as deleted — a false alarm on
# the one job whose entire value is being believed.
#
# WHY THE LOGIC IS HERE AND NOT IN THE WORKFLOW'S `run:` BLOCK. Same reason
# bin/ai-config-prescan.sh gives: a `run:` block's regressions are re-orderings
# and deletions that every grep-the-YAML test survives, whereas a script can be
# EXECUTED against fixtures — tests/validate-label-vocab-reconcile.sh does
# exactly that, with a stubbed `gh` on PATH, so the behavior is gated offline
# while the scan itself stays scheduled-only.
#
# NOT A MERGE GATE, STRUCTURALLY. This is not a run-all.sh stage and not part of
# ci.yml's merge-gate aggregation; it runs from
# .github/workflows/label-vocab-reconcile.yml on a schedule (+ workflow_dispatch)
# and cannot red a PR. Same posture as ai-config-prescan.yml and
# code-scanning.yml.
#
# NO BASELINE, DELIBERATELY. ai-config-prescan.sh ratchets against a checked-in
# baseline because its tree carries 11 known findings. Here the correct state is
# ZERO drift — measured true on 2026-09-09, all 5 declared labels present and no
# undeclared status/* label in the repo — so a baseline would be nothing but a
# mute button over a live-vocabulary break.
#
# THE `status/` FILTER ON THE LIVE SIDE IS LOAD-BEARING. `gh label list` returns
# the whole label set: severity/*, effort/*, type/*, component/*. Unfiltered,
# every one of them would report as present-but-undeclared, the job would be red
# from its first run, and it would be muted — which is the same end state as
# never having written it. This script reconciles the `status/*` vocabulary only,
# which is the vocabulary the pipeline's label calls actually depend on.
#
# Usage:
#   bash bin/label-vocab-reconcile.sh        reconcile; non-zero on drift
#
# Exit codes:
#   0 = declared and live vocabularies agree
#   1 = drift in either direction (the scheduled run goes red), OR a usage error
#   2 = required runtime/input absent (fail loud — never a silent "no drift")
#
# A usage error shares 1 with drift deliberately, matching
# bin/ai-config-prescan.sh's documented contract ("1 = new findings, OR a usage
# error") rather than diverging from its sibling. 2 is reserved for "this run
# could not compare anything", which is the distinction callers actually branch
# on; a bad argument is a caller bug, and no caller passes one twice.
#
# Env overrides (for tests):
#   LABEL_VOCAB_ROOT   repo root whose plugins/ supplies the declared side
#
# bash-3.2 clean and BSD clean (macOS target) per CLAUDE.md § Runtime policy: no
# `declare -A`/`mapfile`, no `\s`/`\w`/`grep -P`/BRE `\|`, no `grep -q` inside a
# pipeline under `pipefail`, and no GNU-only flags.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${LABEL_VOCAB_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
PLUGINS_DIR="$REPO_ROOT/plugins"
LABEL_VOCAB_LIB="$SCRIPT_DIR/lib/label-vocab.sh"

if [ -n "${1:-}" ]; then
    command printf 'label-vocab-reconcile: unknown argument %s (expected none)\n' "$1" >&2
    exit 1
fi

# --- fail loud on a missing runtime -----------------------------------------
# Exit 2 throughout, never 0. Each of these produces an EMPTY comparison, and an
# empty comparison is indistinguishable from "no drift" — the inert-gate shape
# this repo keeps filing issues about (#538, #571, #906).
# EVERY runtime dependency, not just the interesting ones. The point of this loop
# is the curated FATAL diagnostic; a dependency missing from the list dies with a
# bare "command not found" at whatever line reaches it first, which is the one
# outcome the loop exists to prevent. sed/grep/mktemp are near-universal, but
# "near-universal" is not the contract this script claims for itself.
# `find` is used TRANSITIVELY, by declared_status_labels in bin/lib/label-vocab.sh
# — the sourced library is as much a dependency as a direct call, and omitting it
# meant an absent `find` died with a bare "find: command not found" and an
# undocumented exit code instead of the curated FATAL/2 this loop promises. `rm`
# runs in the EXIT trap, where a failure would silently skip cleanup.
for tool in gh sort comm awk sed grep mktemp find rm; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        command printf 'label-vocab-reconcile: FATAL — %s not found on PATH.\n' "$tool" >&2
        command printf '  This job needs network + gh auth by design; refusing to report no drift.\n' >&2
        exit 2
    fi
done

if [ ! -f "$LABEL_VOCAB_LIB" ]; then
    command printf 'label-vocab-reconcile: FATAL — the shared label parser is missing at\n' >&2
    command printf '  %s\n' "$LABEL_VOCAB_LIB" >&2
    exit 2
fi
# shellcheck source=bin/lib/label-vocab.sh
. "$LABEL_VOCAB_LIB"

if [ ! -d "$PLUGINS_DIR" ]; then
    command printf 'label-vocab-reconcile: FATAL — plugins/ not found at\n' >&2
    command printf '  %s\n' "$PLUGINS_DIR" >&2
    exit 2
fi

# --- the declared vocabulary -------------------------------------------------
DECLARED="$(declared_status_labels "$PLUGINS_DIR")"
if [ -z "$DECLARED" ]; then
    command printf 'label-vocab-reconcile: FATAL — no status/* labels declared in any metadata.yml under\n' >&2
    command printf '  %s\n' "$PLUGINS_DIR" >&2
    command printf '  An empty declared vocabulary would report every live label as undeclared;\n' >&2
    command printf '  that is a parser regression, not a finding.\n' >&2
    exit 2
fi

# --- the live vocabulary -----------------------------------------------------
# `gh`'s exit code is load-bearing: an auth failure, a rate limit and a network
# error all emit nothing, and treating any of them as an empty label set would
# report EVERY declared label as deleted — a maximally alarming false positive.
# GH_LABEL_LIMIT is a page size, and a page size that is silently reached is a
# TRUNCATION, not a smaller repo. `gh label list` gives no "more results exist"
# signal in this shape, so a label sorted past the cutoff would simply be missing
# from LIVE_RAW and read as "declared but absent from the repo" — the same
# maximally-alarming false positive this script refuses to emit for an auth
# failure, arriving by a different route. Every other incomplete-comparison path
# here exits 2; this one must too, so the count is checked against the limit
# below rather than assumed to be under it.
GH_LABEL_LIMIT=500
LIVE_RAW=""
GH_RC=0
# STDOUT AND STDERR ARE CAPTURED SEPARATELY, not merged with `2>&1`. A merged
# capture puts any incidental gh warning (a deprecation notice, a redirect note)
# into LIVE_RAW on the SUCCESS path, where it is then counted by the truncation
# guard and fed to the status/ filter as though it were a label name. A warning is
# not a label, and the guard whose whole job is "is this list complete?" must not
# be reading diagnostics as data. Stderr is kept aside and used only where it is
# actually wanted: the failure diagnostic below.
GH_ERR="$(command mktemp)" || exit 2
# shellcheck disable=SC2064  # expand the path now, at trap-registration time
trap "command rm -f '$GH_ERR'" EXIT
LIVE_RAW="$(command gh label list --limit "$GH_LABEL_LIMIT" --json name --jq '.[].name' 2>"$GH_ERR")" || GH_RC=$?
if [ "$GH_RC" -ne 0 ]; then
    command printf 'label-vocab-reconcile: FATAL — `gh label list` exited %s.\n' "$GH_RC" >&2
    command printf '  Output was:\n' >&2
    command sed 's/^/    /' "$GH_ERR" >&2
    command printf '%s\n' "$LIVE_RAW" | command sed 's/^/    /' >&2
    command printf '  Zero labels from a failed query is not an empty repo.\n' >&2
    exit 2
fi

if [ -z "$LIVE_RAW" ]; then
    command printf 'label-vocab-reconcile: FATAL — `gh label list` succeeded but returned no labels.\n' >&2
    command printf '  A repo with zero labels is not a state this reconciler can distinguish from\n' >&2
    command printf '  a query that silently read the wrong repo.\n' >&2
    exit 2
fi

# Truncation guard, before any filtering: if the RAW count reached the page size
# we cannot rule out that labels were dropped, so refuse rather than compare a
# possibly-partial set. Counted on the unfiltered list because that is what the
# limit applies to.
N_RAW="$(command printf '%s\n' "$LIVE_RAW" | command grep -c . || true)"
if [ "$N_RAW" -ge "$GH_LABEL_LIMIT" ]; then
    command printf 'label-vocab-reconcile: FATAL — `gh label list` returned %s labels, at or above\n' "$N_RAW" >&2
    command printf '  the --limit of %s, so the list may be TRUNCATED.\n' "$GH_LABEL_LIMIT" >&2
    command printf '  A truncated live vocabulary reports present labels as deleted. Raise\n' >&2
    command printf '  GH_LABEL_LIMIT in this script, or paginate with `gh api --paginate`.\n' >&2
    exit 2
fi

# Filter to the status/* vocabulary — see the header on why this is load-bearing.
# `|| true` absorbs a legitimate no-match; the emptiness is then diagnosed below,
# where it is a real finding (every declared label deleted) rather than a runtime
# failure.
LIVE="$({ command printf '%s\n' "$LIVE_RAW" |
    command grep -E '^status/' || true; } | command sort -u)"

# --- compare, both directions ------------------------------------------------
# THE TRAP IS ARMED BEFORE THE SECOND mktemp CAN FAIL. Creating both files and
# then trapping leaks the first one whenever the second `|| exit 2` fires (a full
# /tmp, an fd or quota limit between the two calls) — the exit path runs with no
# trap registered at all. So arm after the first, then RE-arm to cover the second.
DECL_F="$(command mktemp)" || exit 2
# shellcheck disable=SC2064  # expand the paths now, at trap-registration time
trap "command rm -f '$GH_ERR' '$DECL_F'" EXIT
LIVE_F="$(command mktemp)" || exit 2
# shellcheck disable=SC2064  # expand the paths now, at trap-registration time
trap "command rm -f '$GH_ERR' '$DECL_F' '$LIVE_F'" EXIT

command printf '%s\n' "$DECLARED" >"$DECL_F"
if [ -n "$LIVE" ]; then
    command printf '%s\n' "$LIVE" >"$LIVE_F"
else
    : >"$LIVE_F"
fi

# comm needs sorted input; declared_status_labels sorts, and LIVE is sorted above.
MISSING="$(command comm -23 "$DECL_F" "$LIVE_F" || true)" # declared, not in repo
EXTRA="$(command comm -13 "$DECL_F" "$LIVE_F" || true)"   # in repo, not declared

count_lines() {
    [ -n "$1" ] || {
        command printf '0'
        return 0
    }
    command printf '%s\n' "$1" | command grep -c . || true
}

N_DECLARED="$(count_lines "$DECLARED")"
N_LIVE="$(count_lines "$LIVE")"
N_MISSING="$(count_lines "$MISSING")"
N_EXTRA="$(count_lines "$EXTRA")"

# --- report ------------------------------------------------------------------
# stdout AND the step summary: a scheduled job's log is invisible unless someone
# goes looking for it.
emit() {
    command printf '%s\n' "$1"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        command printf '%s\n' "$1" >>"$GITHUB_STEP_SUMMARY"
    fi
}

# md_safe - neutralize a LIVE label name for the markdown report.
#
# The declared side is repo content and trusted; the live side comes from
# `gh label list`, and label creation is a triage-level permission. The step
# summary renders as GFM, so a name carrying a backtick escapes its code span and
# one carrying `[...](...)` becomes a link — enough to misrepresent the report
# even though GitHub's renderer blocks script execution. A report whose whole
# value is being believed should not be reshapeable by the thing it reports on.
# Backtick, brackets and parens are replaced rather than stripped, so evidence of
# an odd name survives instead of vanishing.
md_safe() {
    command printf '%s' "$1" | command tr '`[]()' '?????'
}

emit "## status/* label vocabulary reconciliation"
emit ""
emit "- declared in \`plugins/**/metadata.yml\`: **${N_DECLARED}**"
emit "- live \`status/*\` labels in the repo: **${N_LIVE}**"
emit "- declared but ABSENT from the repo: **${N_MISSING}**"
emit "- present in the repo but UNDECLARED: **${N_EXTRA}**"
emit ""
emit "This job covers the **online half only** — that the declared vocabulary and"
emit "the repo's real labels agree. The offline half (prose may not name an"
emit "undeclared label; no recipe may combine an add and a remove in one call) is"
emit "\`tests/lint-status-label-refs.sh\`, a per-PR gate. Both read the same"
emit "declared vocabulary through \`bin/lib/label-vocab.sh\`."

# Each direction is reported SEPARATELY and names EVERY label. Collapsing them to
# a count, or to the first hit, re-creates the suppression bug: the second
# deleted label is exactly the one nobody would notice.
if [ "$N_MISSING" -gt 0 ]; then
    emit ""
    emit "### Declared but absent from the repo (${N_MISSING}) — this run FAILS"
    emit ""
    emit "Every \`gh issue edit --add-label\` naming one of these fails, and a failed"
    emit "add after a landed remove leaves an in-flight issue with no status label at"
    emit "all (#636/#921). Either recreate the label, or update the \`labels:\` block"
    emit "in the owning \`metadata.yml\` and the prose that names it."
    emit ""
    command printf '%s\n' "$MISSING" | while IFS= read -r lbl; do
        [ -n "$lbl" ] || continue
        emit "- \`$(md_safe "$lbl")\`"
    done
fi

if [ "$N_EXTRA" -gt 0 ]; then
    emit ""
    emit "### Present in the repo but undeclared (${N_EXTRA}) — this run FAILS"
    emit ""
    emit "A \`status/*\` label exists that no \`metadata.yml\` declares, so the offline"
    emit "gate cannot validate references to it and no skill documents what it means."
    emit "Either declare it, or delete it from the repo."
    emit ""
    command printf '%s\n' "$EXTRA" | while IFS= read -r lbl; do
        [ -n "$lbl" ] || continue
        emit "- \`$(md_safe "$lbl")\`"
    done
fi

if [ "$N_MISSING" -gt 0 ] || [ "$N_EXTRA" -gt 0 ]; then
    exit 1
fi

emit ""
emit "Declared and live \`status/*\` vocabularies agree. No drift."
exit 0
