#!/usr/bin/env bash
# ship-issue — review-lens sizing pre-scan (portable bash fallback)
#
# The adversarial pre-PR review had no size lens — a PR could add 900 lines to an
# already-oversized file and pass a clean review (issue #695). This scanner
# supplies the candidates the new `decomposition` dimension judges.
#
# WHY THIS IS NOT check-decomposition. The audit-lens scanner answers "is this
# file too long?" over a whole repo. A per-PR gate must answer a DIFFERENT
# question — "did THIS diff make it worse?" — because a one-line touch to a
# pre-existing 1,200-line file is not the author's debt to pay, and a reviewer
# that says otherwise gets turned off within a week. So this scanner is
# GROWTH-AWARE: it reads a numstat sidecar and dispositions by what the diff did.
#
# The LOC-counting rules are NOT re-derived. The two `# >>> shared:loc-*` awk
# regions below are kept byte-for-byte identical to
# check-decomposition/patterns.sh by tests/validate-shared-scanner-sync.sh. The
# plugins install independently (workflow without review-audit), so a sourced
# library is impossible — and a third drifting copy of the LOC rules is exactly
# what #663 was filed to kill.
#
# Input:  $1 = file containing paths to scan (one per line)
#         $2 = OPTIONAL numstat sidecar: `added<TAB>deleted<TAB>path` rows
#              (`git diff --numstat`). ABSENT => no growth signal, so every
#              over-threshold file is reported at LOW/informational only.
# Output: TSV to stdout: file\tline\tcategory\tevidence\tcertainty
#
# Exit codes:
#   0 = success (zero or more findings)
#   1 = usage error (missing argument) or file list not found
#   2 = required runtime absent (fail loud — never a silent "no findings")
#
# Note: Uses full paths for commands per project shell-scripting conventions.
#
# Runtime: Python 3.11+ primary (sizing.py) with this bash script as the portable
# fallback. The shim below exec's sizing.py when a python3>=3.11 is present
# (identical TSV contract); SIZING_FORCE_BASH=1 forces this bash body.
# See CLAUDE.md § Key conventions (runtime policy).
#
# LC_ALL=C is set for the awk invocation on purpose: sizing.py restricts its
# character classes to ASCII ([A-Za-z0-9_], [ \t]) precisely so both impls agree
# on files containing exotic whitespace or non-ASCII identifiers.
set -euo pipefail

# --- runtime selection: prefer python3>=3.11, else this bash fallback --------
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${SIZING_FORCE_BASH:-0}" != "1" ] && [ -f "$_here/sizing.py" ] &&
    command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    exec python3 "$_here/sizing.py" "$@"
fi

FILE_LIST="${1:?Usage: sizing.sh <file-list> [numstat-file]}"
NUMSTAT="${2:-}"

if [ ! -f "$FILE_LIST" ]; then
    echo "Error: file list not found: $FILE_LIST" >&2
    exit 1
fi

# --- fail loud when the fallback's own runtime is missing --------------------
# A scanner with no runtime must NOT exit 0 with no findings: a clean "no
# findings" is indistinguishable from "everything is fine" and lets the gate sit
# inert unnoticed (the #538/#571 sentinel discipline). awk is POSIX-mandated, so
# this fires only on a genuinely broken environment — but it fires loudly.
if ! command -v awk >/dev/null 2>&1; then
    echo "Error: ship-issue sizing requires either python3>=3.11 or awk; found neither." >&2
    echo "  Install python3.11+ (preferred), or a POSIX awk (gawk/mawk/nawk)." >&2
    echo "  This scanner refuses to report 'no findings' when it cannot scan." >&2
    exit 2
fi

# Review-lens thresholds — deliberately LOOSER than the audit lens
# (check-decomposition ships 300/500): an audit sweeps a whole repo and can
# afford to nag, a per-PR gate cannot. See check-decomposition/thresholds.yml
# § review_size_thresholds. Defaults identical to sizing.py's _int_env fallbacks.
REVIEW_LOC_WARN="${REVIEW_LOC_WARN:-500}"
REVIEW_LOC_HIGH="${REVIEW_LOC_HIGH:-800}"
REVIEW_GROWTH_MIN_ADDED="${REVIEW_GROWTH_MIN_ADDED:-50}"
REVIEW_COHESIVE_MAX_UNITS="${REVIEW_COHESIVE_MAX_UNITS:-2}"
# Per-language overrides. A 500-line Rust file and a 500-line shell script are
# not the same claim. A language absent here falls through to the pair above.
REVIEW_LOC_WARN_SH="${REVIEW_LOC_WARN_SH:-700}"
REVIEW_LOC_HIGH_SH="${REVIEW_LOC_HIGH_SH:-1000}"
REVIEW_LOC_WARN_MD="${REVIEW_LOC_WARN_MD:-700}"
REVIEW_LOC_HIGH_MD="${REVIEW_LOC_HIGH_MD:-1000}"
REVIEW_LOC_WARN_RS="${REVIEW_LOC_WARN_RS:-400}"
REVIEW_LOC_HIGH_RS="${REVIEW_LOC_HIGH_RS:-700}"
REVIEW_LOC_WARN_GO="${REVIEW_LOC_WARN_GO:-400}"
REVIEW_LOC_HIGH_GO="${REVIEW_LOC_HIGH_GO:-700}"

# added_for PATH — added-line count for PATH from the numstat sidecar, or 0.
# Binary files render as `-` in numstat and are skipped rather than crashing.
added_for() {
    [ -n "$NUMSTAT" ] && [ -f "$NUMSTAT" ] || {
        echo 0
        return 0
    }
    LC_ALL=C command awk -F'\t' -v want="$1" '
        NF >= 3 && $3 == want && $1 ~ /^[0-9]+$/ { print $1; found = 1; exit }
        END { if (!found) print 0 }
    ' "$NUMSTAT"
}

HAVE_GROWTH=0
if [ -n "$NUMSTAT" ] && [ -f "$NUMSTAT" ] &&
    LC_ALL=C command awk -F'\t' 'NF >= 3 && $1 ~ /^[0-9]+$/ { found = 1; exit } END { exit !found }' "$NUMSTAT"; then
    HAVE_GROWTH=1
fi

while IFS= read -r file; do
    [ -f "$file" ] || continue

    # Skip non-source files (lock files before generic extensions). Markdown is
    # deliberately NOT skipped — prose is this repo's largest surface (#589).
    case "$file" in
        *.lock | *lock.json | *go.sum) continue ;;
        *.txt | *.json | *.yaml | *.yml | *.toml | *.ini | *.cfg | *.conf) continue ;;
    esac

    # Language key from the extension — mirrors EXT_LANG in sizing.py. An
    # unrecognized extension yields "" (metrics only, no segmenter).
    lang=""
    case "$file" in
        *.py) lang="py" ;;
        *.js | *.jsx | *.mjs | *.cjs | *.ts | *.tsx) lang="js" ;;
        *.rs) lang="rs" ;;
        *.go) lang="go" ;;
        *.sh | *.bash) lang="sh" ;;
        *.md | *.markdown) lang="md" ;;
    esac

    # Per-language threshold selection, mirroring PER_LANG_THRESHOLDS.
    loc_warn=$REVIEW_LOC_WARN
    loc_high=$REVIEW_LOC_HIGH
    case "$lang" in
        sh)
            loc_warn=$REVIEW_LOC_WARN_SH
            loc_high=$REVIEW_LOC_HIGH_SH
            ;;
        md)
            loc_warn=$REVIEW_LOC_WARN_MD
            loc_high=$REVIEW_LOC_HIGH_MD
            ;;
        rs)
            loc_warn=$REVIEW_LOC_WARN_RS
            loc_high=$REVIEW_LOC_HIGH_RS
            ;;
        go)
            loc_warn=$REVIEW_LOC_WARN_GO
            loc_high=$REVIEW_LOC_HIGH_GO
            ;;
    esac

    added=$(added_for "$file")

    LC_ALL=C command awk \
        -v path="$file" -v lang="$lang" \
        -v loc_warn="$loc_warn" -v loc_high="$loc_high" \
        -v added="$added" -v have_growth="$HAVE_GROWTH" \
        -v min_added="$REVIEW_GROWTH_MIN_ADDED" \
        -v cohesive_max="$REVIEW_COHESIVE_MAX_UNITS" '
    # >>> shared:loc-helpers-awk (kept in sync with check-decomposition/patterns.sh by tests/validate-shared-scanner-sync.sh)
    # md_slug: heading text -> identifier-shaped slug, so family_prefix applies
    # unchanged. Mirrors md_slug() in patterns.py.
    function md_slug(text,   i, ch, out, prev_us, n) {
        sub(/[ \t]+$/, "", text)
        text = tolower(text)
        n = length(text); out = ""; prev_us = 0
        for (i = 1; i <= n; i++) {
            ch = substr(text, i, 1)
            if (ch ~ /[a-z0-9]/) { out = out ch; prev_us = 0 }
            else if (!prev_us)   { out = out "_"; prev_us = 1 }
        }
        sub(/^_+/, "", out); sub(/_+$/, "", out)
        return out
    }
    function is_unit_header(line, lang) {
        if (lang == "py") return line ~ /^(async[ \t]+)?(def|class)[ \t]+[A-Za-z_][A-Za-z0-9_]*/
        if (lang == "js") return line ~ /^(export[ \t]+)?(default[ \t]+)?(async[ \t]+)?(function|class|const|let|var)[ \t]+[A-Za-z_$][A-Za-z0-9_$]*/
        if (lang == "rs") return line ~ /^(pub(\([a-z]+\))?[ \t]+)?(async[ \t]+)?(fn|struct|enum|trait|impl|mod)[ \t]+[A-Za-z_][A-Za-z0-9_]*/
        if (lang == "go") return line ~ /^(func|type|var|const)[ \t]+[A-Za-z_][A-Za-z0-9_]*/
        if (lang == "sh") return line ~ /^(function[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]*\([ \t]*\)/ || line ~ /^function[ \t]+[A-Za-z_][A-Za-z0-9_]*/
        return 0
    }
    # unit_name: the captured identifier. POSIX awk has no capture groups, so the
    # keyword prefix is stripped and the leading identifier read off directly —
    # equivalent to patterns.py group(1) for every arm above.
    function unit_name(line, lang,   s) {
        s = line
        if (lang == "py") { sub(/^(async[ \t]+)?(def|class)[ \t]+/, "", s) }
        else if (lang == "js") { sub(/^(export[ \t]+)?(default[ \t]+)?(async[ \t]+)?(function|class|const|let|var)[ \t]+/, "", s) }
        else if (lang == "rs") { sub(/^(pub(\([a-z]+\))?[ \t]+)?(async[ \t]+)?(fn|struct|enum|trait|impl|mod)[ \t]+/, "", s) }
        else if (lang == "go") { sub(/^(func|type|var|const)[ \t]+/, "", s) }
        else if (lang == "sh") { sub(/^function[ \t]+/, "", s); sub(/[ \t]*\(.*$/, "", s) }
        if (match(s, /^[A-Za-z_$][A-Za-z0-9_$]*/)) return substr(s, 1, RLENGTH)
        return ""
    }
    function is_test_header(line, lang) {
        if (lang == "py") return line ~ /^(async[ \t]+)?def[ \t]+test_/ || line ~ /^class[ \t]+Test/
        if (lang == "js") return line ~ /^[ \t]*(describe|it|test)[ \t]*\(/
        if (lang == "go") return line ~ /^func[ \t]+(Test|Benchmark|Fuzz|Example)/
        if (lang == "sh") return line ~ /^(function[ \t]+)?test_[A-Za-z0-9_]*[ \t]*\([ \t]*\)/
        return 0
    }
    function is_comment(line, lang) {
        if (lang == "py" || lang == "sh") return line ~ /^[ \t]*#/
        if (lang == "js" || lang == "rs" || lang == "go") return line ~ /^[ \t]*(\/\/|\/\*|\*)/
        return 0
    }
    function nest_unit(lang) {
        if (lang == "js" || lang == "md") return 2
        return 4
    }
    function unit_noun(lang) {
        if (lang == "py") return "def"
        if (lang == "js") return "function"
        if (lang == "rs") return "fn"
        if (lang == "go") return "func"
        if (lang == "sh") return "function"
        if (lang == "md") return "section"
        return "unit"
    }
    # <<< shared:loc-helpers-awk

    # Language-shaped split guidance (AC7). Mirrors SPLIT_SHAPE in sizing.py.
    # Names the SHAPE of the split, not a generic "consider splitting" — the
    # finding has to be actionable or it is noise.
    function split_shape(lang) {
        if (lang == "rs") return "new subdir module; mod.rs re-exports the decomposed units"
        if (lang == "py") return "package dir with __init__.py re-exporting the public surface"
        if (lang == "js") return "sibling modules + a barrel index.ts"
        if (lang == "go") return "additional files in the same package (no import churn)"
        if (lang == "sh") return "sourced fragment + an explicit ordered list (split-suite convention)"
        if (lang == "md") return "progressive disclosure: move detail to linked files, leave a one-line pointer"
        return "extract a cohesive unit into a sibling module"
    }
    function emit(line_no, category, evidence, certainty) {
        printf "%s\t%d\t%s\t%s\t%s\n", path, line_no, category, evidence, certainty
    }

    # ---- pass 1: buffer the file ------------------------------------------
    { L[NR] = $0 }

    END {
        total = NR
        nu = 0            # unit count
        min_head = 99     # markdown: shallowest heading depth present

        # >>> shared:loc-measure-awk (kept in sync with check-decomposition/patterns.sh by tests/validate-shared-scanner-sync.sh)

        if (lang == "md") {
            fenced = 0
            nh = 0
            for (i = 1; i <= total; i++) {
                line = L[i]
                if (line ~ /^```/ || line ~ /^~~~/) { fenced = !fenced; continue }
                if (fenced) continue
                if (match(line, /^#+[ \t]+/)) {
                    d = 0
                    while (substr(line, d + 1, 1) == "#") d++
                    if (d >= 1 && d <= 6) {
                        nh++
                        hd[nh] = d; hl[nh] = i
                        t = line; sub(/^#+[ \t]+/, "", t)
                        ht[nh] = t
                        if (d < min_head) min_head = d
                    }
                }
            }
            for (i = 1; i <= nh; i++) {
                if (hd[i] == min_head) {
                    nu++
                    s = md_slug(ht[i])
                    if (s == "") s = "section"
                    un[nu] = s; us[nu] = hl[i]; ut[nu] = 0
                }
            }
        } else if (lang != "") {
            pending_test = 0
            for (i = 1; i <= total; i++) {
                line = L[i]
                # Rust: an attribute line marks the NEXT unit as test code.
                if (lang == "rs" && line ~ /^[ \t]*#\[(cfg\(test\)|test)\]/) {
                    pending_test = 1
                    continue
                }
                if (!is_unit_header(line, lang)) continue
                nm = unit_name(line, lang)
                if (nm == "") continue
                nu++
                un[nu] = nm; us[nu] = i
                if (pending_test) { ut[nu] = 1; pending_test = 0 }
                else if (lang != "rs" && is_test_header(line, lang)) ut[nu] = 1
                else ut[nu] = 0
            }
        }
        # Unit spans: header line to the line before the next header (or EOF).
        for (i = 1; i <= nu; i++) uend[i] = (i < nu) ? us[i + 1] - 1 : total

        # ---- generic sizing layer -----------------------------------------
        # Lines belonging to a test unit.
        for (i = 1; i <= nu; i++) {
            if (!ut[i]) continue
            for (j = us[i]; j <= uend[i]; j++) tl[j] = 1
        }
        # Whole-file test-region markers: match to EOF.
        for (i = 1; i <= total; i++) {
            hit = 0
            if (lang == "py" && L[i] ~ /^if[ \t]+__name__/) hit = 1
            else if (lang == "rs" && L[i] ~ /^[ \t]*#\[cfg\(test\)\]/) hit = 1
            else if (lang == "sh" && L[i] ~ /^#[ \t]*-+[ \t]*tests?[ \t]*-+/) hit = 1
            if (hit) { for (j = i; j <= total; j++) tl[j] = 1; break }
        }

        blank = 0; comment = 0; test_excluded = 0; max_depth = 0
        nunit = nest_unit(lang)
        for (i = 1; i <= total; i++) {
            if (i in tl) { test_excluded++; continue }
            line = L[i]
            if (line ~ /^[ \t]*$/) { blank++; continue }
            if (is_comment(line, lang)) { comment++; continue }
            match(line, /^[ \t]*/)
            d = int(RLENGTH / nunit)
            if (d > max_depth) max_depth = d
        }
        production = total - blank - comment - test_excluded
        prod_units = 0
        for (i = 1; i <= nu; i++) if (!ut[i]) prod_units++
        comment_pct = (total > 0) ? int(comment * 100 / total) : 0

        metrics = sprintf("%d total, %d comment (%d%%), %d blank, %d test-excluded, max nesting %d, %d top-level units", \
            total, comment, comment_pct, blank, test_excluded, max_depth, prod_units)
        # <<< shared:loc-measure-awk

        # ---- review lens: growth-aware disposition (AC4) --------------------
        # Only "crossed" and "material" are ever blocking-eligible. A one-line
        # touch to a pre-existing oversized file CANNOT produce a blocking row —
        # the property tests/validate-sizing-scanner.sh pins.
        if (production <= loc_warn) exit 0

        # Production LOC before this diff, approximated by removing the added
        # lines. Honest approximation: numstat counts RAW added lines while
        # `production` excludes blanks/comments, so `prior` is an UPPER bound on
        # the pre-diff size. Erring high under-claims "the diff crossed it",
        # failing toward the quieter, non-blocking disposition.
        prior = (have_growth == 1) ? production - added : production
        crossed = (have_growth == 1 && prior <= loc_warn) ? 1 : 0
        material = (have_growth == 1 && added >= min_added) ? 1 : 0

        band = (production > loc_high) ? "high" : "warning"
        limit = (production > loc_high) ? loc_high : loc_warn

        if (crossed) {
            certainty = (production > loc_high) ? "HIGH" : "MEDIUM"
            evidence = sprintf("%d production LOC (>%d %s); this diff added %d lines and pushed it over the %d review threshold; %s", \
                production, limit, band, added, loc_warn, metrics)
        } else if (material) {
            certainty = "MEDIUM"
            evidence = sprintf("%d production LOC (>%d %s); already over before this diff, which added %d more lines; %s", \
                production, limit, band, added, metrics)
        } else if (have_growth == 1) {
            certainty = "LOW"
            evidence = sprintf("%d production LOC (>%d %s); pre-existing size, this diff added only %d lines — informational, not this PR'"'"'s debt; %s", \
                production, limit, band, added, metrics)
        } else {
            certainty = "LOW"
            evidence = sprintf("%d production LOC (>%d %s); no diff growth data supplied — informational only; %s", \
                production, limit, band, metrics)
        }
        emit(1, "file-length", evidence, certainty)

        # The split SHAPE, so the finding names a concrete destination rather
        # than bare advice. Only for dispositions a reviewer should act on.
        if ((crossed || material) && lang != "") {
            emit(1, "decomposition-seam", sprintf("split shape for %s: %s", lang, split_shape(lang)), "MEDIUM")
        } else if (!crossed && !material) {
            # ---- reasoned decline ------------------------------------------
            # A file over threshold with no actionable growth is a RESULT, not a
            # silence. Reasons reused verbatim from check-decomposition/contract.md
            # so a decline reads identically in both lenses.
            generated = 0
            for (i = 1; i <= total && i <= 20; i++) {
                if (toupper(L[i]) ~ /@GENERATED|CODE GENERATED BY|DO NOT EDIT|AUTOGENERATED|AUTO-GENERATED/) {
                    generated = 1; break
                }
            }
            if (generated) reason = "generated file — regenerate rather than split"
            else if (prod_units <= cohesive_max) reason = "single cohesive unit — no internal seam to cut"
            else if (comment_pct >= 50) reason = "majority prose/comment — length is documentation, not logic"
            else reason = "no low-coupling seam found — units are mutually referential"
            emit(1, "decomposition-seam", sprintf("declined: %s (%d production LOC, %d top-level units)", \
                reason, production, prod_units), "LOW")
        }
    }
    ' "$file" || true

done <"$FILE_LIST"
