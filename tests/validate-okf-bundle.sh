#!/usr/bin/env bash
# OKF bundle conformance + graph-health gate for THIS repo's .claude/memory/
# (issue #697, OKF slice G).
#
# The epic (#664) shipped a portable validator that checks OTHER repos' memory
# bundles — slice A (#668, per-file conformance) and slice B (#669, whole-bundle
# graph health). Nothing ran it against OURS. Librarian was the one repo whose
# bundle drifted unchecked while it published the tool that would have caught it.
#
# WHY A GATE AND NOT A PERIODIC SWEEP. Every failure mode #632 recorded from the
# manual curation is silent by construction: a memory on disk but absent from an
# index is written and never recallable; a renamed slug leaves an index line
# pointing at nothing. None of them produce a symptom at write time. A periodic
# audit finds them weeks later, after the session that could have explained the
# intent is gone. A gate finds them in the PR that caused them.
#
# WHAT THIS GATE DOES NOT DO. It checks conformance and graph health — the
# deterministic half. The semantic pass (slice C, #670) is advisory and
# human-reviewed by nature; it does not belong in a gate and is not wired in.
# Index SIZING is likewise out of scope: check-decomposition already classifies
# memory_index and memory_concept with their own budgets (#700), and a second
# threshold table over the same files is exactly the duplication #663 exists to
# kill. See the PR for #697 for the measurements behind that decision.
#
# ---------------------------------------------------------------------------
# FOUR EXIT PATHS, DELIBERATELY DISTINCT
# ---------------------------------------------------------------------------
#
#   scanner unreachable        -> 77   `[SKIP] … did not run`
#   bundle absent              -> 0    "nothing to check"
#   findings within baseline   -> 0    advisory: printed, not fatal
#   findings above baseline,
#     or ANY finding in
#     blocking mode            -> 1    `[FAIL]`
#
# The 77 and the bundle-absent 0 are NOT the same thing, and conflating them is
# the #538/#571 failure mode one layer up: 77 means the gate's TOOL is missing
# so nothing was checked, while a bundle-absent 0 means the gate ran and the
# corpus was empty. A fresh clone of a consuming repo with no bundle must pass,
# not skip. tests/lint-markdown.sh draws the same line for the same reason.
#
# THE 77 KEYS OFF THE SCANNER, NOT OFF PYTHON. patterns.sh IS the portable bash
# fallback (it exec's patterns.py only when a python3>=3.11 is present), so its
# runtime is bash + coreutils. An absent python is not a skip condition here;
# an absent patterns.sh is.
#
# ---------------------------------------------------------------------------
# WHY ADVISORY IS THE DEFAULT, AND WHY IT STILL HAS TEETH
# ---------------------------------------------------------------------------
#
# Measured 2026-09-06 over 223 git-tracked bundle files: 302 findings (218
# okf-missing-type, 79 memory-missing-why, 5 okf-unparseable-frontmatter; ZERO
# orphans and ZERO dangling index lines — the graph is healthy, the schema floor
# is not). Blocking mode cannot land on that tree. Those 302 are what #631 (OKF
# adoption) exists to fix.
#
# But an advisory gate that only ever prints is not a gate — it cannot prevent
# NEW drift while #631 is in flight, which is the thing #697 actually asked for.
# So advisory mode is ADDITIVE-blocking: per-category counts are frozen in
# tests/okf-bundle.baseline, and a count ABOVE its entry fails. The 302
# pre-existing rows pass; one new non-conformant memory does not. That is the
# same ratchet tests/lint-prose-budget.sh uses for prose growth — a repo idiom,
# not a new invention. A count that DROPS auto-tightens on --regen, so #631's
# progress ratchets in and cannot silently regress.
#
# THE FLIP TO BLOCKING IS A TESTED SWITCH, NOT A TODO. $OKF_BUNDLE_GATE_MODE is
# `advisory` (default) or `blocking`; blocking fails on ANY finding, baseline
# ignored. Both modes are exercised by tests/validate-okf-bundle-gate.sh, so
# flipping the default once #631 lands is a one-line diff against green tests
# rather than a comment someone has to notice.
#
# ---------------------------------------------------------------------------
# THE GATE NEVER PRINTS MEMORY CONTENT
# ---------------------------------------------------------------------------
#
# Findings are rendered as `file<TAB>line<TAB>category` — the scanner's EVIDENCE
# column is dropped on purpose. memory-stale evidence quotes the memory's own
# `stale_check` sentence, and okf-* evidence can echo frontmatter; a CI log is a
# far wider audience than the bundle. Category + location is enough to act on.
#
# bash-3.2 clean and BSD-regex safe (no declare -A / mapfile / namerefs /
# ${v,,} / ;;&, no \s \w \b, no grep -P) — macOS ships bash 3.2 and BSD
# grep/sed. See CLAUDE.md § Runtime policy.
#
# Usage:
#   tests/validate-okf-bundle.sh            report + enforce (CI / pre-push)
#   tests/validate-okf-bundle.sh --regen    rewrite the baseline from the tree
#
#   OKF_BUNDLE_GATE_MODE=blocking tests/validate-okf-bundle.sh
#   OKF_BUNDLE_ROOT=path/to/bundle tests/validate-okf-bundle.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

# Reserved exit code meaning "this gate did NOT run" (autotools SKIP convention).
SKIP_EXIT_CODE=77

# The scanner. Overridable so the meta-gate can point at a missing path to
# exercise the 77 branch without uninstalling anything.
SCANNER="${OKF_BUNDLE_SCANNER:-$REPO_ROOT/plugins/review-audit/skills/check-okf-conformance/patterns.sh}"

# The bundle. $OKF_BUNDLE_ROOT wins, mirroring the scanner's own discovery order
# so the gate and the tool it drives cannot disagree about what they scanned.
BUNDLE_ROOT="${OKF_BUNDLE_ROOT:-$REPO_ROOT/.claude/memory}"

BASELINE_FILE="${OKF_BUNDLE_BASELINE:-$SCRIPT_DIR/okf-bundle.baseline}"

GATE_MODE="${OKF_BUNDLE_GATE_MODE:-advisory}"

REGEN=0
if [ "${1:-}" = "--regen" ]; then
    REGEN=1
elif [ -n "${1:-}" ]; then
    command printf 'validate-okf-bundle: unknown argument %s (expected --regen or none)\n' \
        "${1:-}" >&2
    exit 2
fi

case "$GATE_MODE" in
    advisory | blocking) ;;
    *)
        # A typo'd mode must not silently become advisory — that is how a
        # blocking gate quietly stops blocking.
        command printf 'validate-okf-bundle: OKF_BUNDLE_GATE_MODE must be advisory or blocking, got %s\n' \
            "$GATE_MODE" >&2
        exit 2
        ;;
esac

test_suite "OKF bundle conformance + health (.claude/memory/) (#697)"

# --- the two non-running exits ----------------------------------------------

# Scanner missing => the gate did not run. 77, never 0.
if [ ! -f "$SCANNER" ]; then
    skip_test "GATE DID NOT RUN — check-okf-conformance scanner not found at $SCANNER"
    generate_report
    exit "$SKIP_EXIT_CODE"
fi

# Bundle missing => the gate RAN and found nothing to check. 0, never 77.
# A fresh clone of a consuming repo has no bundle and must not fail (AC3).
if [ ! -d "$BUNDLE_ROOT" ]; then
    command printf 'No memory bundle at %s — nothing to check.\n\n' "$BUNDLE_ROOT"
    generate_report
    exit 0
fi

# --- build the file list ----------------------------------------------------

WORKDIR="$(command mktemp -d)" || {
    command printf 'validate-okf-bundle: mktemp failed\n' >&2
    exit 2
}
trap 'command rm -rf "$WORKDIR"' EXIT

FILE_LIST="$WORKDIR/files.txt"
SCAN_OUT="$WORKDIR/findings.tsv"
SCAN_ERR="$WORKDIR/scan.err"

# GIT-TRACKED ONLY, and that is the scoping decision. `.gitignore` ignores
# `tmp/`, so `.claude/memory/tmp/` is per-session scratch — churny, disposable,
# and not reviewable repo content. Gating it would fail PRs over notes nobody
# ships. (Contrast tests/lint-markdown.sh, which deliberately reaches INTO the
# gitignored tree: a syntax lint over scratch prose is cheap and catches real
# rot, while a conformance gate over scratch is noise.)
#
# `git ls-files` is run from the bundle root so the paths come back relative to
# it and stay stable across checkouts. A non-git tree (a tarball export) falls
# back to `find`, since a gate that only works inside a git checkout would skip
# silently in exactly the environments least likely to notice.
if command git -C "$BUNDLE_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    command git -C "$BUNDLE_ROOT" ls-files -- '*.md' |
        command sed "s|^|$BUNDLE_ROOT/|" >"$FILE_LIST"
else
    command find "$BUNDLE_ROOT" -type f -name '*.md' | command sort >"$FILE_LIST"
fi

FILE_COUNT="$(command wc -l <"$FILE_LIST" | command tr -d '[:space:]')"

# An empty bundle directory is the same claim as an absent one: the gate ran,
# the corpus was empty.
if [ "$FILE_COUNT" -eq 0 ]; then
    command printf 'Memory bundle at %s holds no markdown — nothing to check.\n\n' \
        "$BUNDLE_ROOT"
    generate_report
    exit 0
fi

# --- run the scanner --------------------------------------------------------

# MEMORY_BUNDLE_ROOT (not OKF_BUNDLE_ROOT) so an operator's OKF_BUNDLE_ROOT
# override, already folded into $BUNDLE_ROOT above, is not applied twice.
scan_rc=0
MEMORY_BUNDLE_ROOT="$BUNDLE_ROOT" command bash "$SCANNER" "$FILE_LIST" \
    >"$SCAN_OUT" 2>"$SCAN_ERR" || scan_rc=$?

# The scanner's own contract: a non-conformant BUNDLE is exit 0 with findings; a
# non-zero means the TOOL failed (unresolvable version pin, unreadable list).
# That is a broken gate, not a dirty bundle — fail loud, and do NOT report a
# clean bundle we never actually checked.
if [ "$scan_rc" -ne 0 ]; then
    SCANNER_RC="$scan_rc"
    SCANNER_STDERR="$(command sed 's/^/  /' <"$SCAN_ERR")"

    # Reported through run_test, NOT as a bare assert_true. An assertion outside
    # run_test prints FAIL but is never COUNTED: TESTS_RUN stays 0 and the
    # summary reads `Total: 0 / Failed: 0` under a printed failure — a red gate
    # that summarises as green to anyone reading the report rather than the exit
    # code. Found by mutation (deleting the assertion left `exit 1` behind and
    # the deletion survived), and it is the same silent-skip class this gate
    # exists to make visible.
    test_scanner_ran_successfully() {
        command printf 'validate-okf-bundle: scanner failed (exit %s):\n' "$SCANNER_RC"
        command printf '%s\n' "$SCANNER_STDERR"
        command printf 'The scanner reports a TOOL failure, not a dirty bundle: its own\n'
        command printf 'contract makes a non-conformant bundle exit 0 with findings. Do not\n'
        command printf 'read this as a clean bundle — nothing was actually checked.\n\n'
        assert_equals "0" "$SCANNER_RC" "the OKF scanner ran successfully"
    }
    run_test test_scanner_ran_successfully "the OKF scanner ran successfully"
    generate_report
    exit 1
fi

# --- per-category counts ----------------------------------------------------

# Field 3 is `category` in the scanner's file\tline\tcategory\tevidence\tcertainty
# contract. Fields 4-5 are never read here — see the no-memory-content rule.
COUNTS="$WORKDIR/counts.txt"
command awk -F'\t' 'NF >= 3 { print $3 }' <"$SCAN_OUT" |
    command sort | command uniq -c |
    command awk '{ print $2 " " $1 }' | command sort >"$COUNTS"

TOTAL="$(command awk -F'\t' 'NF >= 3' <"$SCAN_OUT" | command wc -l | command tr -d '[:space:]')"

# baseline_for CATEGORY — the frozen count, or empty when unlisted. Shaped after
# lint-prose-budget.sh's baseline_for, including the trailing-whitespace trim
# before the split: `cat 218 # why` leaves `cat 218 ` and a naive `${rest##* }`
# would yield the empty string, silently un-ratcheting the entry.
baseline_for() {
    local want="$1" line rest key count
    [ -f "$BASELINE_FILE" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            '#'* | '') continue ;;
        esac
        rest="${line%%#*}"
        while :; do
            case "$rest" in
                *' ' | *"$(command printf '\t')") rest="${rest%?}" ;;
                *) break ;;
            esac
        done
        key="${rest%% *}"
        count="${rest##* }"
        if [ "$key" = "$want" ]; then
            command printf '%s\n' "$count"
            return 0
        fi
    done <"$BASELINE_FILE"
    return 0
}

# --- --regen ----------------------------------------------------------------

if [ "$REGEN" -eq 1 ]; then
    {
        command printf '# OKF bundle finding baseline — issue #697.\n'
        command printf '#\n'
        command printf '# Per-category finding counts frozen at their present value. The gate fails\n'
        command printf '# a category whose count is ABOVE its entry here, so the existing findings\n'
        command printf '# pass while NEW drift does not. A count that drops is tightened by the\n'
        command printf '# next --regen; RAISING an entry is a deliberate, reviewable diff that\n'
        command printf '# wants a reason in the commit message.\n'
        command printf '#\n'
        command printf '# These are not targets. The listed findings are what #631 (OKF adoption)\n'
        command printf '# exists to drive to zero; this file only stops them growing meanwhile.\n'
        command printf '#\n'
        command printf '# Regenerate with: tests/validate-okf-bundle.sh --regen\n'
        command printf '\n'
        command cat "$COUNTS"
    } >"$BASELINE_FILE"
    command printf 'Baseline regenerated: %s (%s categories, %s findings over %s files)\n\n' \
        "$BASELINE_FILE" "$(command wc -l <"$COUNTS" | command tr -d '[:space:]')" \
        "$TOTAL" "$FILE_COUNT"
    generate_report
    exit 0
fi

# --- report -----------------------------------------------------------------

command printf 'Bundle: %s (%s files, %s findings)\n' "$BUNDLE_ROOT" "$FILE_COUNT" "$TOTAL"
command printf 'Mode:   %s\n\n' "$GATE_MODE"

if [ "$TOTAL" -gt 0 ]; then
    command printf 'Findings by category:\n'
    while IFS=' ' read -r category count; do
        [ -n "$category" ] || continue
        base="$(baseline_for "$category")"
        if [ -z "$base" ]; then
            command printf '  %-32s %5s  (no baseline entry)\n' "$category" "$count"
        else
            command printf '  %-32s %5s  (baseline %s)\n' "$category" "$count" "$base"
        fi
    done <"$COUNTS"
    command printf '\n'

    # file/line/category ONLY. Fields 4-5 (evidence, certainty) are dropped:
    # memory-stale evidence quotes the memory's own stale_check text, and a CI
    # log is a far wider audience than the bundle (AC7).
    command printf 'Locations (file, line, category — never content):\n'
    command awk -F'\t' 'NF >= 3 { printf "  %s\t%s\t%s\n", $1, $2, $3 }' <"$SCAN_OUT"
    command printf '\n'
fi

# --- enforce ----------------------------------------------------------------

VIOLATIONS=""

if [ "$GATE_MODE" = "blocking" ]; then
    # Blocking ignores the baseline entirely — the whole point of the flip is
    # that pre-existing findings stop being grandfathered.
    if [ "$TOTAL" -gt 0 ]; then
        VIOLATIONS="blocking mode: $TOTAL finding(s) in the bundle"
    fi
else
    # Advisory: fail only on GROWTH above the frozen per-category count. An
    # unlisted category has an implicit baseline of 0, so a brand-new category
    # of finding fails rather than sliding in unnoticed.
    while IFS=' ' read -r category count; do
        [ -n "$category" ] || continue
        base="$(baseline_for "$category")"
        [ -n "$base" ] || base=0
        if [ "$count" -gt "$base" ]; then
            VIOLATIONS="$VIOLATIONS  $category: $count > $base (baseline)
"
        fi
    done <"$COUNTS"
fi

test_bundle_has_no_new_findings() {
    if [ -n "$VIOLATIONS" ]; then
        command printf 'OKF bundle findings exceed the allowance:\n'
        command printf '%s\n' "$VIOLATIONS"
        if [ "$GATE_MODE" = "advisory" ]; then
            command printf 'Fix the new finding(s), or — if the growth is deliberate and\n'
            command printf 'justified — raise the entry in %s\n' "$BASELINE_FILE"
            command printf 'with a reason in the commit message.\n\n'
        fi
    fi
    assert_equals "" "$VIOLATIONS" \
        "no OKF bundle findings beyond the $GATE_MODE allowance"
}

run_test test_bundle_has_no_new_findings \
    "the memory bundle introduces no new OKF findings ($GATE_MODE mode)"

generate_report
