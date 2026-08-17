#!/usr/bin/env bash
# check-decomposition — Deterministic Pre-Scan (portable bash fallback)
#
# Sizing + language-aware segmentation: production-LOC counting with per-language
# test/comment exclusion, and per-language segmenters that emit actionable
# DECOMPOSITION SEAMS rather than a bare line count (issue #663).
#
# Input:  $1 = file containing paths to scan (one per line)
# Output: TSV to stdout: file\tline\tcategory\tevidence\tcertainty
#
# Exit codes:
#   0 = success (zero or more findings)
#   1 = usage error (missing argument) or file list not found
#   2 = required runtime absent (fail loud — never a silent "no findings")
#
# Note: Uses full paths for commands per project shell-scripting conventions.
#
# Runtime: Python 3.11+ primary (patterns.py) with this bash script as the
# portable fallback. The shim below exec's patterns.py when a python3>=3.11 is
# present (identical TSV contract); PATTERNS_FORCE_BASH=1 forces this bash body.
# See CLAUDE.md § Key conventions (runtime policy).
#
# WHY THE BODY IS ONE AWK PROGRAM. The algorithm is inherently multi-pass over a
# file (find units -> span them -> cluster by family -> measure fan-in of each
# cluster against every other line). A per-line shell loop would re-read each
# file once per unit — quadratic, and it would need associative arrays, which
# bash 3.2 does not have (see CLAUDE.md § Runtime policy: macOS ships bash 3.2).
# POSIX awk has associative arrays natively, so the whole per-file analysis runs
# in one pass-pair inside awk, stays bash-3.2 clean by construction, and is a
# near-literal transcription of patterns.py — which is what makes the byte-level
# parity in tests/validate-python-ports.sh maintainable.
#
# LC_ALL=C is set for the awk invocation on purpose: patterns.py restricts its
# character classes to ASCII ([A-Za-z0-9_], [ \t]) precisely so both impls agree
# on files containing exotic whitespace or non-ASCII identifiers. A UTF-8 locale
# here would make awk's [[:alnum:]]-adjacent behavior diverge from that.
set -euo pipefail

# --- runtime selection: prefer python3>=3.11, else this bash fallback --------
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${PATTERNS_FORCE_BASH:-0}" != "1" ] && [ -f "$_here/patterns.py" ] &&
    command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    exec python3 "$_here/patterns.py" "$@"
fi

FILE_LIST="${1:?Usage: patterns.sh <file-list>}"

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
    echo "Error: check-decomposition requires either python3>=3.11 or awk; found neither." >&2
    echo "  Install python3.11+ (preferred), or a POSIX awk (gawk/mawk/nawk)." >&2
    echo "  This scanner refuses to report 'no findings' when it cannot scan." >&2
    exit 2
fi

# Thresholds — env-overridable, defaults identical to patterns.py's _int_env
# fallbacks and to thresholds.yml.
DECOMP_LOC_WARN="${DECOMP_LOC_WARN:-300}"
DECOMP_LOC_HIGH="${DECOMP_LOC_HIGH:-500}"
DECOMP_SEAM_MIN_UNITS="${DECOMP_SEAM_MIN_UNITS:-3}"
DECOMP_SEAM_MIN_LINES="${DECOMP_SEAM_MIN_LINES:-40}"
DECOMP_SEAM_MAX_FANIN="${DECOMP_SEAM_MAX_FANIN:-3}"
DECOMP_GOD_UNITS="${DECOMP_GOD_UNITS:-12}"
DECOMP_GOD_CONCERNS="${DECOMP_GOD_CONCERNS:-3}"
DECOMP_COHESIVE_MAX_UNITS="${DECOMP_COHESIVE_MAX_UNITS:-2}"
# Bloat table — migrated from check-ai-config with its variable names intact so
# an operator's existing overrides keep working after the move.
CLAUDE_MD_WARN="${CLAUDE_MD_WARN:-400}"
CLAUDE_MD_HIGH="${CLAUDE_MD_HIGH:-600}"
SKILL_WARN="${SKILL_WARN:-300}"
SKILL_HIGH="${SKILL_HIGH:-500}"
AGENT_WARN="${AGENT_WARN:-250}"
AGENT_HIGH="${AGENT_HIGH:-400}"
DOC_WARN="${DOC_WARN:-500}"
DOC_HIGH="${DOC_HIGH:-800}"

while IFS= read -r file; do
    [ -f "$file" ] || continue

    # Skip non-source files (lock files before generic extensions). Markdown is
    # deliberately NOT skipped — this scanner segments prose by heading
    # hierarchy and owns doc-file-bloat.
    case "$file" in
        *.lock | *lock.json | *go.sum) continue ;;
        *.txt | *.json | *.yaml | *.yml | *.toml | *.ini | *.cfg | *.conf) continue ;;
    esac

    # Language key from the extension — mirrors EXT_LANG in patterns.py. An
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

    # Bloat spec — mirrors bloat_spec() in patterns.py, in the same order (the
    # first matching arm wins, so */agents/*.md never reaches the docs arm).
    b_warn=0
    b_high=0
    b_type=""
    b_cat=""
    case "$file" in
        */CLAUDE.md | */AGENTS.md)
            b_warn=$CLAUDE_MD_WARN
            b_high=$CLAUDE_MD_HIGH
            b_type="CLAUDE.md"
            b_cat="ai-file-bloat"
            ;;
        */skills/*/SKILL.md)
            b_warn=$SKILL_WARN
            b_high=$SKILL_HIGH
            b_type="skill definition"
            b_cat="ai-file-bloat"
            ;;
        */agents/*/*.md | */agents/*.md)
            b_warn=$AGENT_WARN
            b_high=$AGENT_HIGH
            b_type="agent definition"
            b_cat="ai-file-bloat"
            ;;
        */docs/*.md)
            b_warn=$DOC_WARN
            b_high=$DOC_HIGH
            b_type="documentation"
            b_cat="doc-file-bloat"
            ;;
    esac

    LC_ALL=C command awk \
        -v path="$file" -v lang="$lang" \
        -v loc_warn="$DECOMP_LOC_WARN" -v loc_high="$DECOMP_LOC_HIGH" \
        -v seam_min_units="$DECOMP_SEAM_MIN_UNITS" \
        -v seam_min_lines="$DECOMP_SEAM_MIN_LINES" \
        -v seam_max_fanin="$DECOMP_SEAM_MAX_FANIN" \
        -v god_units="$DECOMP_GOD_UNITS" -v god_concerns="$DECOMP_GOD_CONCERNS" \
        -v cohesive_max="$DECOMP_COHESIVE_MAX_UNITS" \
        -v b_warn="$b_warn" -v b_high="$b_high" \
        -v b_type="$b_type" -v b_cat="$b_cat" '
    # ---- helpers -----------------------------------------------------------
    # family_prefix: snake_case splits at the first underscore; camel/Pascal at
    # the first internal A-Z. Lowercased. Mirrors family_prefix() in patterns.py
    # (ASCII-only on both sides so the two agree on non-ASCII identifiers).
    function family_prefix(name,   cut, i, n) {
        cut = index(name, "_")
        if (cut > 1) return tolower(substr(name, 1, cut - 1))
        n = length(name)
        i = 2
        while (i <= n && substr(name, i, 1) !~ /[A-Z]/) i++
        return tolower(substr(name, 1, i - 1))
    }
    # >>> shared:loc-helpers-awk (kept in sync with ship-issue/sizing.sh by tests/validate-shared-scanner-sync.sh)
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
    # target_path: sibling module named for the family, under a directory named
    # for the file it came from. Mirrors target_path() in patterns.py.
    # NB: `i` is declared LOCAL here (the extra-parameter idiom). awk has no
    # block scope, so an undeclared `i` would be GLOBAL and would clobber the
    # loop counter of whatever called this. It is called from inside the seam
    # loop, whose counter is also `i`, so omitting it resets that loop on every
    # call and hangs forever on any file with a seam.
    function target_path(p, prefix,   slash, dir, base, dot, stem, ext, i) {
        slash = 0
        for (i = length(p); i >= 1; i--) if (substr(p, i, 1) == "/") { slash = i; break }
        if (slash) { dir = substr(p, 1, slash - 1); base = substr(p, slash + 1) }
        else       { dir = ""; base = p }
        dot = 0
        for (i = length(base); i >= 1; i--) if (substr(base, i, 1) == ".") { dot = i; break }
        if (dot) { stem = substr(base, 1, dot - 1); ext = substr(base, dot) }
        else     { stem = base; ext = "" }
        if (dir != "") return dir "/" stem "/" prefix ext
        return stem "/" prefix ext
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

        # >>> shared:loc-measure-awk (kept in sync with ship-issue/sizing.sh by tests/validate-shared-scanner-sync.sh)

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

        # ---- size verdict: EXACTLY ONE per file (#701) ---------------------
        # Mirrors the same branch in patterns.py scan_file(). A classified file
        # (b_cat != "") gets its per-type budget and NOT the generic
        # production-LOC one: a bloat spec IS the statement "this file type has
        # its own budget". Before #701 both ran, so classified markdown emitted
        # two rows for one problem, and a docs page UNDER its own doc_md budget
        # was still flagged at the 300 code threshold.
        #
        # `over` is set by whichever branch fires, NOT by file-length alone —
        # it drives the reasoned-decline emit below, so keying it to one branch
        # would silently drop the decline for every classified file.
        over = 0
        if (b_cat != "") {
            # Per-type budget, measured on TOTAL lines — the deliberate choice
            # recorded in thresholds.yml § bloat_thresholds (#701).
            if (total > b_high) {
                over = 1
                emit(1, b_cat, sprintf("%s exceeds high threshold: %d lines (>%d)", b_type, total, b_high), "HIGH")
            } else if (total > b_warn) {
                over = 1
                emit(1, b_cat, sprintf("%s exceeds warning threshold: %d lines (>%d)", b_type, total, b_warn), "MEDIUM")
            }
        } else if (production > loc_high) {
            over = 1
            emit(1, "file-length", sprintf("%d production LOC (>%d high); %s", production, loc_high, metrics), "HIGH")
        } else if (production > loc_warn) {
            over = 1
            emit(1, "file-length", sprintf("%d production LOC (>%d warning); %s", production, loc_warn, metrics), "MEDIUM")
        }

        if (lang == "") exit 0

        # ---- cluster consecutive same-family units -------------------------
        nc = 0
        for (i = 1; i <= nu; i++) {
            if (ut[i]) continue
            p = family_prefix(un[i])
            if (nc > 0 && cp[nc] == p && clast[nc] == i - 1) {
                cn[nc]++; ce[nc] = uend[i]; clast[nc] = i
                cmem[nc, cn[nc]] = un[i]
            } else {
                nc++
                cp[nc] = p; cs[nc] = us[i]; ce[nc] = uend[i]
                cn[nc] = 1; clast[nc] = i
                cmem[nc, 1] = un[i]
            }
        }
        # Distinct concerns, in first-seen order.
        ncon = 0
        for (i = 1; i <= nc; i++) {
            if (!(cp[i] in seen_con)) { seen_con[cp[i]] = 1; ncon++; con[ncon] = cp[i] }
        }

        # ---- category: god-module ------------------------------------------
        # Size alone is not a god module: size AND many units AND several
        # distinct concerns. The coupling half stays with audit-architecture,
        # which now consumes this LOC number instead of re-deriving it.
        if (production > loc_warn && prod_units > god_units && ncon >= god_concerns) {
            clist = ""
            for (i = 1; i <= ncon && i <= 5; i++) clist = (i == 1) ? con[i] : clist ", " con[i]
            emit(1, "god-module", sprintf("%d production LOC, %d top-level units, %d concerns (%s)", \
                production, prod_units, ncon, clist), "MEDIUM")
        }

        # ---- category: decomposition-seam ----------------------------------
        # Tokenize each line ONCE, up front, rather than re-walking every line
        # for every cluster. The naive form (a substr walk nested inside the
        # per-cluster loop) is O(clusters x lines x len^2) because the substr in
        # awk copies the tail of the string on each step — measured at >20s on a
        # 1060-line file with 48 units, versus 14ms for the python primary.
        # Splitting once into a per-line token LIST makes the fan-in scan a set
        # membership test and keeps the fallback within a few ms of the primary.
        # TOK[j, t] holds the t-th token of line j; TOKN[j] its count.
        for (j = 1; j <= total; j++) {
            line = L[j]
            gsub(/[^A-Za-z0-9_$]+/, " ", line)
            TOKN[j] = split(line, _tk, " ")
            for (t = 1; t <= TOKN[j]; t++) TOK[j, t] = _tk[t]
        }

        noun = unit_noun(lang)
        seams = 0
        for (i = 1; i <= nc; i++) {
            span = ce[i] - cs[i] + 1
            if (cn[i] < seam_min_units || span < seam_min_lines) continue

            # fan-in: how much of the REST of the file reaches into this span.
            # Token membership (maximal [A-Za-z0-9_$] runs) is equivalent to a
            # \bNAME\b regex and matches TOKEN_RE in patterns.py exactly.
            for (k in ismem) delete ismem[k]
            for (k = 1; k <= cn[i]; k++) ismem[cmem[i, k]] = 1
            count = 0; ncall = 0
            for (k in seen_call) delete seen_call[k]
            for (j = 1; j <= total; j++) {
                if (j >= cs[i] && j <= ce[i]) continue
                found = 0
                for (t = 1; t <= TOKN[j]; t++) {
                    if (TOK[j, t] in ismem) { found = 1; break }
                }
                if (!found) continue
                count++
                for (m = 1; m <= nu; m++) {
                    if (j >= us[m] && j <= uend[m]) {
                        if (!(un[m] in seen_call)) { seen_call[un[m]] = 1; ncall++; calls[ncall] = un[m] }
                        break
                    }
                }
            }
            # Sort caller names (insertion sort — the list is tiny and this
            # matches the callers.sort() in patterns.py, before the 3-item cap).
            for (a = 2; a <= ncall; a++) {
                v = calls[a]; b = a - 1
                while (b >= 1 && calls[b] > v) { calls[b + 1] = calls[b]; b-- }
                calls[b + 1] = v
            }
            callstr = ""
            for (a = 1; a <= ncall && a <= 3; a++) callstr = (a == 1) ? calls[a] : callstr ", " calls[a]

            if (count == 0) fan = "no external references"
            else if (count <= seam_max_fanin && callstr != "") fan = sprintf("fan-in %d <- %s", count, callstr)
            else fan = sprintf("fan-in %d", count)

            emit(cs[i], "decomposition-seam", sprintf("seam %d-%d: %s %s_* family (%d units, %s) -> %s", \
                cs[i], ce[i], noun, cp[i], cn[i], fan, target_path(path, cp[i])), "HIGH")
            seams++
        }

        # ---- reasoned decline -----------------------------------------------
        # A file over threshold with no seam is a RESULT, not a silence. Record
        # WHY, so "no seam" is never mistaken for "not examined".
        if (over && seams == 0) {
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
