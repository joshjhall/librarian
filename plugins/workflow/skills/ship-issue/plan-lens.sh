#!/usr/bin/env bash
# next-issue — plan-lens sizing pre-scan (portable bash fallback)
#
# THE THIRD LENS (issue #756). See plan-lens.py's module docstring for the full
# rationale; the short form:
#
#     lens    | question                      | growth signal
#     --------|-------------------------------|--------------------
#     audit   | is this file too long?        | none
#     review  | did this diff make it worse?  | git diff --numstat
#     plan    | will this plan make it worse? | PLANNER ESTIMATE   <- this file
#
# WHY IT IS NOT A THRESHOLD TWEAK ON THE REVIEW LENS. Both existing lenses return
# early for a file UNDER its threshold, so the case that matters most produces no
# row at all today: a file at 640 lines against a 700 budget is silent, and it is
# exactly the file a planner needs warned about when the plan adds 200 lines to
# it. That requires projecting `current + estimate` against the budget — an
# arithmetic neither lens performs.
#
# THE LOC ENGINE IS NOT RE-DERIVED. This scanner shells out to
# `sizing.sh --measure`, which emits the 13-field metrics record computed by the
# SAME code the review lens uses (itself pinned byte-for-byte against
# check-decomposition through the `# >>> shared:loc-*` sentinel regions). A
# fourth hand-copy of the counting rules is what #663 was filed to kill, and a
# sentinel region cannot pin text in a file it does not cover.
#
# Input:  $1 = file containing paths to scan (one per line)
#         $2 = OPTIONAL estimate sidecar: `added<TAB>path` rows (the planner's
#              per-file estimate). Same shape numstat uses, so a real numstat
#              file is accepted unchanged. ABSENT => already-over files are
#              reported LOW/informational and NO headroom row is emitted.
# Output: TSV to stdout: file\tline\tcategory\tevidence\tcertainty
#
# Exit codes:
#   0 = success (zero or more findings)
#   1 = usage error (missing argument) or file list not found
#   2 = required runtime absent (fail loud — never a silent "no findings")
#
# Note: Uses full paths for commands per project shell-scripting conventions.
#
# Runtime: Python 3.11+ primary (plan-lens.py) with this bash script as the
# portable fallback. The shim below exec's plan-lens.py when a python3>=3.11 is
# present (identical TSV contract); PLAN_LENS_FORCE_BASH=1 forces this bash body.
# bash-3.2 clean and BSD-regex clean (macOS target) per CLAUDE.md.
set -euo pipefail

# --- runtime selection: prefer python3>=3.11, else this bash fallback --------
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${PLAN_LENS_FORCE_BASH:-0}" != "1" ] && [ -f "$_here/plan-lens.py" ] &&
    command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    exec python3 "$_here/plan-lens.py" "$@"
fi

FILE_LIST="${1:?Usage: plan-lens.sh <file-list> [estimate-sidecar]}"
ESTIMATES="${2:-}"

if [ ! -f "$FILE_LIST" ]; then
    echo "Error: file list not found: $FILE_LIST" >&2
    exit 1
fi

# Headroom band — mirrors DEFAULT_MIN_ESTIMATE in plan-lens.py and
# thresholds.yml § plan_size_thresholds. The floor exists so a file one line
# under budget does not fire on a 1-line estimate; that is noise, and noise is
# how a lens gets turned off.
PLAN_HEADROOM_MIN_ESTIMATE="${PLAN_HEADROOM_MIN_ESTIMATE:-25}"

# --- fail loud when the LOC engine is missing --------------------------------
# A scanner with no engine must NOT exit 0 with no findings: a clean "no
# findings" is indistinguishable from "everything is fine" and lets the gate sit
# inert unnoticed (the #538/#571 sentinel discipline). The PLANNER's tolerance
# for this failure is separate — it catches the non-zero exit and proceeds with
# a note (#756 AC12) — but the scanner itself refuses.
_ENGINE="${_here}/sizing.sh"
if [ ! -f "$_ENGINE" ]; then
    echo "Error: plan-lens requires the sibling sizing.sh LOC engine; not found." >&2
    echo "  This scanner refuses to report 'no findings' when it cannot scan." >&2
    exit 2
fi
if ! command -v awk >/dev/null 2>&1; then
    echo "Error: plan-lens requires either python3>=3.11 or awk; found neither." >&2
    exit 2
fi

# estimate_for PATH — estimated added lines for PATH, or 0.
#
# RENAME-AWARE, mirroring sidecar_path() in plan-lens.py and added_for() in
# sizing.sh. Accepts both the 2-column plan shape (`added<TAB>path`) and the
# 3-column numstat shape (`added<TAB>deleted<TAB>path`) by reading the LAST
# field as the path, so a caller may hand this a real numstat file unchanged.
estimate_for() {
    [ -n "$ESTIMATES" ] && [ -f "$ESTIMATES" ] || {
        echo 0
        return 0
    }
    LC_ALL=C command awk -F'\t' -v want="$1" '
        function post_rename(f,   ob, cb, inner, arrow, after) {
            if (index(f, "=>") == 0) return f
            ob = index(f, "{")
            if (ob > 0) {
                cb = index(f, "}")
                if (cb > ob) {
                    inner = substr(f, ob + 1, cb - ob - 1)
                    arrow = index(inner, "=>")
                    after = (arrow > 0) ? substr(inner, arrow + 2) : inner
                    gsub(/^[ \t]+|[ \t]+$/, "", after)
                    f = substr(f, 1, ob - 1) after substr(f, cb + 1)
                    gsub(/\/\//, "/", f)
                    return f
                }
            }
            arrow = index(f, "=>")
            after = substr(f, arrow + 2)
            gsub(/^[ \t]+|[ \t]+$/, "", after)
            return after
        }
        NF >= 2 && $1 ~ /^[0-9]+$/ && post_rename($NF) == want { print $1; found = 1; exit }
        END { if (!found) print 0 }
    ' "$ESTIMATES"
}

HAVE_ESTIMATE=0
if [ -n "$ESTIMATES" ] && [ -f "$ESTIMATES" ] &&
    LC_ALL=C command awk -F'\t' 'NF >= 2 && $1 ~ /^[0-9]+$/ { found = 1; exit } END { exit !found }' "$ESTIMATES"; then
    HAVE_ESTIMATE=1
fi

# Measure every candidate once through the shared engine, then project.
# `comment_pct` and `generated` are POSITIONAL PLACEHOLDERS, not dead variables:
# the measure record is 13 ordered fields and every one must be consumed for the
# later fields to land in the right names. This lens projects on size and budget
# only — the decline-reason arms that read those two live in the review lens. A
# rename to `_unused` would be a lie about the contract; dropping them would
# silently shift `lang` into `generated`.
# shellcheck disable=SC2034
command bash "$_ENGINE" --measure "$FILE_LIST" | while IFS="$(printf '\t')" read -r \
    path total production units comment_pct generated lang \
    loc_warn loc_high b_warn b_high b_type b_cat; do

    [ -n "$path" ] || continue
    estimate="$(estimate_for "$path")"

    LC_ALL=C command awk \
        -v path="$path" -v total="$total" -v production="$production" \
        -v units="$units" -v lang="$lang" \
        -v loc_warn="$loc_warn" -v loc_high="$loc_high" \
        -v b_warn="$b_warn" -v b_high="$b_high" \
        -v b_type="$b_type" -v b_cat="$b_cat" \
        -v estimate="$estimate" -v have_estimate="$HAVE_ESTIMATE" \
        -v min_estimate="$PLAN_HEADROOM_MIN_ESTIMATE" '
    function emit(line_no, category, evidence, certainty) {
        printf "%s\t%d\t%s\t%s\t%s\n", path, line_no, category, evidence, certainty
    }
    BEGIN {
        # Classified prose is measured on TOTAL lines by its own per-type budget;
        # everything else on production LOC by the code thresholds. The choice is
        # made in sizing shared bloat-spec region, not re-derived here — what a
        # file IS is a fact about its path and must not fork (#724).
        if (b_warn > 0) {
            current = total; warn = b_warn; high = b_high
            category = b_cat; label = b_type; unit = "lines"
        } else {
            current = production; warn = loc_warn; high = loc_high
            category = "file-length"
            label = (lang != "") ? lang : "this file"
            unit = "production LOC"
        }

        # ---- already over budget today (AC3) ----------------------------
        # Reported REGARDLESS of estimate, the deliberate difference from the
        # review lens: there, a one-line touch to a pre-existing oversized file
        # is not the author debt. Here the planner is about to open the file
        # anyway, which is the cheapest moment the split will ever have.
        if (current > warn) {
            band = (current > high) ? "high" : "warning"
            limit = (current > high) ? high : warn
            if (have_estimate == 1 && estimate > 0) {
                certainty = (current > high) ? "HIGH" : "MEDIUM"
                evidence = sprintf("%s is already over its %s budget: %d %s (>%d); this plan adds ~%d more. Decompose before implementing — the seam is cheapest now, while the file is already open", \
                    label, band, current, unit, limit, estimate)
            } else if (have_estimate == 1) {
                # A sidecar EXISTS but names no growth for this file. Distinct
                # from the no-sidecar arm and must not borrow its wording.
                certainty = "LOW"
                evidence = sprintf("%s is already over its %s budget: %d %s (>%d); this plan does not add to it — informational only", \
                    label, band, current, unit, limit)
            } else {
                certainty = "LOW"
                evidence = sprintf("%s is already over its %s budget: %d %s (>%d); no plan estimate supplied — informational only", \
                    label, band, current, unit, limit)
            }
            emit(1, category, evidence, certainty)
            exit 0
        }

        # ---- headroom: under budget, but the plan would cross it (AC2) ---
        # THE ROW NEITHER OTHER LENS CAN PRODUCE. Both return early above their
        # threshold check; this arm exists for the file they skip.
        if (have_estimate != 1 || estimate < min_estimate) exit 0
        projected = current + estimate
        if (projected <= warn) exit 0

        band = (projected > high) ? "high" : "warning"
        limit = (projected > high) ? high : warn
        certainty = (projected > high) ? "HIGH" : "MEDIUM"
        headroom = warn - current
        evidence = sprintf("%s has %d %s of headroom (%d/%d); this plan adds ~%d, projecting %d — over the %d %s budget. Fold the decomposition into the plan before adding to this file (%d top-level units)", \
            label, headroom, unit, current, warn, estimate, projected, limit, band, units)
        emit(1, "size-headroom", evidence, certainty)
    }
    ' </dev/null
done
