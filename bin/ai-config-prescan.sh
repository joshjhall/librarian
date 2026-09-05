#!/usr/bin/env bash
# ai-config pre-scan — the DETERMINISTIC half of the convention-audit cadence
# (issue #907, follow-up to #551).
#
# WHAT THIS IS, AND WHAT IT IS NOT. #551 demoted the `conventions` dimension out
# of the ship-issue review fan-out and documented its replacement as a biweekly
# `/review-audit:codebase-audit categories=ai-config` sweep. Nothing ran that
# sweep — this repo had no scheduled workflow at all — so #551's AC#2
# ("equivalent coverage runs on a documented scheduled cadence") held on the
# DOCUMENTED half only.
#
# The premise that blocked a fix was that only an LLM can run the sweep. That is
# incomplete: check-ai-config ships a deterministic patterns.py/patterns.sh that
# needs no LLM, no auth, and no API spend. This script runs exactly that, on a
# schedule (.github/workflows/ai-config-prescan.yml).
#
# So the name is deliberately narrow. This is the "ai-config pre-scan", NEVER the
# "convention audit": a job named for the full sweep while performing only its
# mechanical half is the gate-header-claims-an-unimplemented-check shape this
# repo files issues about. The LLM-judgment half of the cadence — cross-file
# consistency, prose conventions no detector models — remains an operator ritual
# and is documented as such in
# plugins/review-audit/skills/codebase-audit/convention-cadence.md.
#
# THE RATCHET, and why neither obvious alternative works. The tree already
# carries 11 real findings (all MEDIUM `skill-frontmatter`, measured 2026-09-05).
# Two failure modes to avoid:
#
#   fail on ANY finding  -> lands red on day one, gets muted, signals nothing
#   report only          -> nobody reads it, and it cannot distinguish a NEW
#                           violation from the 11 known ones — which is the
#                           entire signal the cadence exists to produce
#
# So findings are ratcheted against a checked-in baseline, the same idiom
# tests/lint-prose-budget.sh + tests/prose-budget.baseline already establish
# here:
#
#   finding present in the baseline    -> pass
#   finding NOT in the baseline        -> FAIL  (the central property)
#   baselined finding now absent       -> pass; --regen tightens the baseline
#
# Green on today's tree AND red on the 12th finding. Fixing the existing 11 is
# deliberately out of scope for #907 (per-skill prose work); the baseline records
# them as known-and-deferred rather than hiding them.
#
# THE BASELINE KEY EXCLUDES THE LINE NUMBER. A finding is keyed on
# file + category + evidence, not on the TSV's line field. Line numbers churn
# whenever anything else in the same file moves, and a line-keyed baseline would
# report the same 11 findings as "new" after any unrelated edit — noise that
# would get the job muted just as surely as failing red on day one.
#
# WHY THE LOGIC LIVES HERE RATHER THAN IN THE WORKFLOW'S `run:` BLOCK. A `run:`
# block's regressions are re-orderings and deletions that every grep-the-YAML
# test survives. Keeping the mechanism in a script means
# tests/validate-ai-config-prescan.sh can EXECUTE it against fixtures.
#
# NOT A PER-PR GATE. This is not registered in tests/run-all.sh. #551
# deliberately moved this coverage off the per-PR path; restoring it there would
# reverse that decision rather than follow it up. run-all.sh gates the TEST of
# this script's logic, not this script over the real corpus.
#
# Usage:
#   bash bin/ai-config-prescan.sh            scan; exit non-zero on new findings
#   bash bin/ai-config-prescan.sh --regen    rewrite the baseline from the tree
#
# Exit codes:
#   0 = no findings outside the baseline
#   1 = new findings, OR a usage error
#   2 = required runtime/input absent (fail loud — never a silent "no findings")
#
# Env overrides (for tests):
#   AI_CONFIG_PRESCAN_BASELINE   path to the baseline ledger
#   AI_CONFIG_PRESCAN_ROOT       repo root to scan
#
# bash-3.2 clean and BSD-regex clean (macOS target) per CLAUDE.md § Runtime
# policy. Uses the `command` builtin for coreutils per project convention.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${AI_CONFIG_PRESCAN_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
BASELINE_FILE="${AI_CONFIG_PRESCAN_BASELINE:-$REPO_ROOT/tests/ai-config-prescan.baseline}"
PRESCAN="$REPO_ROOT/plugins/review-audit/skills/check-ai-config/patterns.sh"

REGEN=0
if [ "${1:-}" = "--regen" ]; then
    REGEN=1
elif [ -n "${1:-}" ]; then
    command printf 'ai-config-prescan: unknown argument %s (expected --regen or none)\n' "$1" >&2
    exit 1
fi

# --- fail loud on a missing scanner -----------------------------------------
# Exit 2, not 0. A missing scanner emitting zero rows is indistinguishable from
# a clean tree, which is exactly how a gate sits inert unnoticed (#538/#571).
if [ ! -f "$PRESCAN" ]; then
    command printf 'ai-config-prescan: FATAL — check-ai-config pre-scan not found at\n' >&2
    command printf '  %s\n' "$PRESCAN" >&2
    command printf '  Refusing to report a clean scan that never ran.\n' >&2
    exit 2
fi

# --- build the corpus --------------------------------------------------------
# Tracked plugin markdown only: git ls-files, so untracked scratch files and
# anything gitignored stay out. `plugins/` is the same root lint-prose-budget.sh
# walks, and for the same reason — docs/verification/** transcripts are outside
# it by construction, not by a filter that could regress.
FILE_LIST="$(command mktemp)" || {
    command printf 'ai-config-prescan: FATAL — mktemp failed; cannot stage the file list.\n' >&2
    exit 2
}
RAW_TSV="$(command mktemp)" || {
    command rm -f "$FILE_LIST"
    command printf 'ai-config-prescan: FATAL — mktemp failed; cannot stage scan output.\n' >&2
    exit 2
}
# shellcheck disable=SC2064  # expand the paths now, at trap-registration time
trap "command rm -f '$FILE_LIST' '$RAW_TSV'" EXIT

(cd "$REPO_ROOT" && command git ls-files) 2>/dev/null |
    command grep -E '^plugins/.*\.md$' >"$FILE_LIST" || true

if [ ! -s "$FILE_LIST" ]; then
    command printf 'ai-config-prescan: FATAL — no tracked plugins/**/*.md files found under\n' >&2
    command printf '  %s\n' "$REPO_ROOT" >&2
    command printf '  An empty corpus scans clean for the wrong reason; refusing to pass.\n' >&2
    exit 2
fi

# --- run the deterministic pre-scan -----------------------------------------
# The scanner's own exit code is load-bearing. Both its runtimes (patterns.py and
# the patterns.sh fallback) exit only 0 or 1 -- 1 covering a usage error and the
# diff-shape rejection -- and every one of those failures emits ZERO rows.
# Treating that as "clean" is the inert-gate failure this script exists to avoid,
# so ANY non-zero from the scanner becomes our exit 2 ("could not scan"), kept
# distinct from our exit 1 ("scanned fine, found something new").
# Run from REPO_ROOT: the file list holds repo-relative paths, so a scan
# launched from any other cwd resolves none of them, emits zero rows, and exits
# 0 -- a clean-looking report from a scan that read nothing. The corpus guard
# above cannot catch it (the list is non-empty; the paths just do not resolve
# from here), so the cd is load-bearing, not tidiness.
SCAN_RC=0
(cd "$REPO_ROOT" && bash "$PRESCAN" "$FILE_LIST") >"$RAW_TSV" 2>/dev/null || SCAN_RC=$?
if [ "$SCAN_RC" -ne 0 ]; then
    command printf 'ai-config-prescan: FATAL — the check-ai-config pre-scan exited %s.\n' "$SCAN_RC" >&2
    command printf '  Zero findings from a failed scan is not a clean tree.\n' >&2
    exit 2
fi

# --- key each finding: file<TAB>category<TAB>evidence (NOT the line number) ---
# patterns.sh emits file\tline\tcategory\tevidence\tcertainty.
CURRENT_KEYS="$(command awk -F'\t' 'NF >= 5 { print $1 "\t" $3 "\t" $4 }' "$RAW_TSV" | command sort)"

# --- read the baseline -------------------------------------------------------
# Comments and blank lines are skipped. A MISSING baseline is fatal rather than
# an implicit empty one: an empty baseline would make every existing finding
# "new" and fail loudly, but a TYPO in the path would do the same thing while
# looking like a real regression — and the --regen path must not be able to
# manufacture its own input.
if [ "$REGEN" -eq 0 ] && [ ! -f "$BASELINE_FILE" ]; then
    command printf 'ai-config-prescan: FATAL — baseline not found at\n' >&2
    command printf '  %s\n' "$BASELINE_FILE" >&2
    command printf '  Create it with: bash bin/ai-config-prescan.sh --regen\n' >&2
    exit 2
fi

BASELINE_KEYS=""
if [ -f "$BASELINE_FILE" ]; then
    BASELINE_KEYS="$(command grep -v '^[[:space:]]*#' "$BASELINE_FILE" |
        command grep -v '^[[:space:]]*$' | command sort || true)"
fi

# --- --regen ------------------------------------------------------------------
# Staged then atomically renamed, so an interrupted regen leaves the previous
# baseline exactly as it was rather than truncated (the lesson
# lint-prose-budget.sh's own regen records).
if [ "$REGEN" -eq 1 ]; then
    STAGING="${BASELINE_FILE}.regen.$$"
    {
        command printf '# ai-config pre-scan ratchet baseline — issue #907.\n'
        command printf '#\n'
        command printf '# Findings from check-ai-config'"'"'s deterministic pre-scan that exist in the\n'
        command printf '# tree TODAY. The scheduled job (.github/workflows/ai-config-prescan.yml)\n'
        command printf '# fails on any finding NOT listed here, so this file is what keeps it green\n'
        command printf '# on the current tree while still catching the next one.\n'
        command printf '#\n'
        command printf '# THESE ARE REAL FINDINGS, NOT FALSE POSITIVES. They are recorded as\n'
        command printf '# known-and-deferred: fixing them is per-skill prose work, deliberately out\n'
        command printf '# of scope for #907 (which is about making the cadence RUN). Removing an\n'
        command printf '# entry by fixing its file is always welcome — --regen then tightens the\n'
        command printf '# ratchet. ADDING an entry is a deliberate, reviewable diff that wants a\n'
        command printf '# reason in the commit message.\n'
        command printf '#\n'
        command printf '# Format: file<TAB>category<TAB>evidence  (no line number — it churns on\n'
        command printf '# unrelated edits and would report known findings as new).\n'
        command printf '#\n'
        command printf '# Regenerate with: bash bin/ai-config-prescan.sh --regen\n'
        if [ -n "$CURRENT_KEYS" ]; then
            command printf '%s\n' "$CURRENT_KEYS"
        fi
    } >"$STAGING" || {
        command rm -f "$STAGING"
        command printf 'ai-config-prescan: FATAL — could not write the staged baseline.\n' >&2
        exit 2
    }
    command mv "$STAGING" "$BASELINE_FILE"
    _n=0
    [ -n "$CURRENT_KEYS" ] && _n="$(command printf '%s\n' "$CURRENT_KEYS" | command wc -l | command tr -d ' ')"
    command printf 'ai-config-prescan: baseline regenerated with %s finding(s).\n' "$_n"
    exit 0
fi

# --- diff current against baseline -------------------------------------------
# comm needs sorted input; both sides are sorted above.
CUR_F="$(command mktemp)" || exit 2
BASE_F="$(command mktemp)" || exit 2
# shellcheck disable=SC2064  # expand now, at trap-registration time
trap "command rm -f '$FILE_LIST' '$RAW_TSV' '$CUR_F' '$BASE_F'" EXIT
command printf '%s' "$CURRENT_KEYS" >"$CUR_F"
[ -n "$CURRENT_KEYS" ] && command printf '\n' >>"$CUR_F"
command printf '%s' "$BASELINE_KEYS" >"$BASE_F"
[ -n "$BASELINE_KEYS" ] && command printf '\n' >>"$BASE_F"

NEW_FINDINGS="$(command comm -23 "$CUR_F" "$BASE_F" || true)"
FIXED_FINDINGS="$(command comm -13 "$CUR_F" "$BASE_F" || true)"

count_lines() {
    [ -n "$1" ] || {
        command printf '0'
        return 0
    }
    command printf '%s\n' "$1" | command wc -l | command tr -d ' '
}

N_TOTAL="$(count_lines "$CURRENT_KEYS")"
N_NEW="$(count_lines "$NEW_FINDINGS")"
N_FIXED="$(count_lines "$FIXED_FINDINGS")"

# --- report -------------------------------------------------------------------
# Written to stdout AND, when running under Actions, to the step summary — a
# scheduled job's log is invisible unless someone goes looking for it.
emit() {
    command printf '%s\n' "$1"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        command printf '%s\n' "$1" >>"$GITHUB_STEP_SUMMARY"
    fi
}

emit "## ai-config pre-scan (deterministic half)"
emit ""
emit "Ran check-ai-config's deterministic pre-scan over $(command wc -l <"$FILE_LIST" | command tr -d ' ') tracked \`plugins/**/*.md\` files."
emit ""
emit "- findings in tree: **${N_TOTAL}**"
emit "- new (not baselined): **${N_NEW}**"
emit "- baselined but now absent: **${N_FIXED}**"
emit ""
emit "This job covers the **deterministic half only**. The LLM-judgment half of"
emit "the convention sweep (cross-file consistency, prose conventions no detector"
emit "models) is not run here and remains an operator ritual — see"
emit "\`plugins/review-audit/skills/codebase-audit/convention-cadence.md\`."

if [ "$N_FIXED" -gt 0 ]; then
    emit ""
    emit "### Baselined findings that no longer appear (${N_FIXED})"
    emit ""
    emit "Tighten the ratchet with \`bash bin/ai-config-prescan.sh --regen\`:"
    emit ""
    command printf '%s\n' "$FIXED_FINDINGS" | while IFS="$(command printf '\t')" read -r f c e; do
        emit "- \`${f}\` — ${c}: ${e}"
    done
fi

if [ "$N_NEW" -gt 0 ]; then
    emit ""
    emit "### NEW findings (${N_NEW}) — this run FAILS"
    emit ""
    command printf '%s\n' "$NEW_FINDINGS" | while IFS="$(command printf '\t')" read -r f c e; do
        emit "- \`${f}\` — ${c}: ${e}"
    done
    emit ""
    emit "Fix them, or record a deliberate exception with"
    emit "\`bash bin/ai-config-prescan.sh --regen\` and a reason in the commit message."
    exit 1
fi

emit ""
emit "No findings outside the baseline."
exit 0
