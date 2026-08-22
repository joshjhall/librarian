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
# PROSE FILE-TYPE CLASSIFICATION is shared the same way (`shared:bloat-config`
# and `shared:bloat-spec`, #724). Before it, this lens sized every .md by the
# generic 700/1000 md pair, so an agents/*.md well over its own 250/400 budget
# — flagged HIGH by the audit lens — passed a per-PR review in silence.
# Strictness is a policy dial each lens owns; what a file IS is a fact about its
# path and must not fork. The disposition stays this lens's own: classified
# prose is still growth-graded, so a one-line touch is LOW, never blocking.
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

# Measure mode (#756) — emit one flat metrics row per file instead of findings,
# so the plan lens can reuse this lens's LOC engine rather than carrying a fourth
# hand-copy of the counting rules. See measure_record() in sizing.py for the
# 13-field contract. Opt-in and positional-first, so the default review-lens
# invocation is byte-for-byte the command it always was (AC6).
MEASURE_ONLY=0
if [ "${1:-}" = "--measure" ]; then
    MEASURE_ONLY=1
    shift
fi

FILE_LIST="${1:?Usage: sizing.sh [--measure] <file-list> [numstat-file]}"
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

# >>> shared:bloat-config (kept in sync with check-decomposition/patterns.sh by tests/validate-shared-scanner-sync.sh)
# Bloat table — migrated from check-ai-config with its variable names intact so
# an operator's existing overrides keep working after the move.
#
# SHARED WITH THE REVIEW LENS (#724). Both lenses apply these numbers verbatim;
# there is no review-lens prose override. The review lens is looser than the
# audit lens for CODE, where thresholds count production LOC and a per-PR gate
# that nags gets turned off — but that argument does not transfer here. These
# budgets count TOTAL lines because the files load WHOLE into context, and that
# cost does not depend on which lens is looking. The review lens stays
# survivable through its growth disposition instead (sizing.sh's awk END).
CLAUDE_MD_WARN="${CLAUDE_MD_WARN:-400}"
CLAUDE_MD_HIGH="${CLAUDE_MD_HIGH:-600}"
SKILL_WARN="${SKILL_WARN:-300}"
SKILL_HIGH="${SKILL_HIGH:-500}"
AGENT_WARN="${AGENT_WARN:-250}"
AGENT_HIGH="${AGENT_HIGH:-400}"
DOC_WARN="${DOC_WARN:-500}"
DOC_HIGH="${DOC_HIGH:-800}"
# Skill companion prose (#589) — the reference files a SKILL.md loads on demand.
# Before this arm they matched nothing and fell through to DECOMP_LOC_*, the code
# thresholds; same defect #700 fixed for the memory bundle.
COMPANION_WARN="${COMPANION_WARN:-400}"
COMPANION_HIGH="${COMPANION_HIGH:-650}"
# Memory-bundle budgets (#700) — index is a READ limit, concept is the cost of
# one recalled fact. Before #700 a bundle file matched no bloat arm and fell
# through to DECOMP_LOC_*, the code thresholds.
MEMORY_INDEX_WARN="${MEMORY_INDEX_WARN:-150}"
MEMORY_INDEX_HIGH="${MEMORY_INDEX_HIGH:-250}"
MEMORY_CONCEPT_WARN="${MEMORY_CONCEPT_WARN:-200}"
MEMORY_CONCEPT_HIGH="${MEMORY_CONCEPT_HIGH:-350}"

# Bundle root — configurable, EMPTY disables memory classification entirely
# (no bundle configured -> no findings, no error). Normalized so `.claude/memory`,
# `./.claude/memory` and `.claude/memory/` all decide alike; an unnormalized
# root would miss the glob, fall back to the code thresholds, and still exit 0.
# Mirrors _bundle_root() in patterns.py.
MEMORY_BUNDLE_ROOT="${MEMORY_BUNDLE_ROOT-.claude/memory}"
while :; do
    case "$MEMORY_BUNDLE_ROOT" in
        ./*) MEMORY_BUNDLE_ROOT="${MEMORY_BUNDLE_ROOT#./}" ;;
        */) MEMORY_BUNDLE_ROOT="${MEMORY_BUNDLE_ROOT%/}" ;;
        *) break ;;
    esac
done
# <<< shared:bloat-config

# added_for PATH — added-line count for PATH from the numstat sidecar, or 0.
# Binary files render as `-` in numstat and are skipped rather than crashing.
#
# RENAME-AWARE (mirrors numstat_path() in sizing.py). git does not print a plain
# path for a renamed file; it prints the rename in one of two shapes, and neither
# matches what `git diff --name-only` gives the caller:
#
#     old.py => new.py          (whole path changed)
#     a/{x => y}/f.py           (one path segment changed)
#
# An exact `$3 == want` match therefore misses every renamed file, its added
# count silently reads 0, and it can never be reported as crossing a threshold
# no matter how much the diff added — the one case the size lens most wants to
# see. Each row's path field is normalized to its POST-rename form before the
# comparison.
added_for() {
    [ -n "$NUMSTAT" ] && [ -f "$NUMSTAT" ] || {
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
        NF >= 3 && $1 ~ /^[0-9]+$/ && post_rename($3) == want { print $1; found = 1; exit }
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
        *.js | *.jsx | *.mjs | *.cjs) lang="js" ;;
        *.ts | *.tsx) lang="ts" ;;
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

    # >>> shared:bloat-spec (kept in sync with check-decomposition/patterns.sh by tests/validate-shared-scanner-sync.sh)
    # PROSE FILE-TYPE CLASSIFICATION — shared by BOTH lenses (#724). What a
    # markdown file IS is a fact about its PATH, and a fact must not fork.
    # Strictness is a policy dial each lens owns; classification is not.
    #
    # Memory-bundle classification (#700) — mirrors bundle_kind() in
    # patterns.py. Only *.md under the root is bundle prose; a .sh or .py in a
    # bundle is code and keeps the code thresholds. Computed BEFORE the bloat
    # case below because the bundle arm is first in the chain.
    b_kind=""
    if [ -n "$MEMORY_BUNDLE_ROOT" ]; then
        case "$file" in
            "$MEMORY_BUNDLE_ROOT"/*.md | */"$MEMORY_BUNDLE_ROOT"/*.md)
                case "${file##*/}" in
                    MEMORY.md | index.md | index-*) b_kind="index" ;;
                    *) b_kind="concept" ;;
                esac
                ;;
        esac
    fi

    # Bloat spec — mirrors bloat_spec() in patterns.py, in the same order (the
    # first matching arm wins, so */agents/*.md never reaches the docs arm, and
    # the memory-bundle arm above pre-empts all four).
    b_warn=0
    b_high=0
    b_type=""
    b_cat=""
    case "$b_kind" in
        index)
            b_warn=$MEMORY_INDEX_WARN
            b_high=$MEMORY_INDEX_HIGH
            b_type="memory index"
            b_cat="ai-file-bloat"
            ;;
        concept)
            b_warn=$MEMORY_CONCEPT_WARN
            b_high=$MEMORY_CONCEPT_HIGH
            b_type="memory concept"
            b_cat="ai-file-bloat"
            ;;
    esac
    [ -n "$b_kind" ] || case "$file" in
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
        # Skill COMPANION prose (#589). MUST stay below the */skills/*/SKILL.md
        # arm above, which is the narrower pattern: `case` takes the FIRST match,
        # so hoisting this would swallow every SKILL.md into the looser budget.
        */skills/*/*.md)
            b_warn=$COMPANION_WARN
            b_high=$COMPANION_HIGH
            b_type="skill companion"
            b_cat="ai-file-bloat"
            ;;
        */docs/*.md)
            b_warn=$DOC_WARN
            b_high=$DOC_HIGH
            b_type="documentation"
            b_cat="doc-file-bloat"
            ;;
    esac
    # <<< shared:bloat-spec

    added=$(added_for "$file")

    LC_ALL=C command awk \
        -v path="$file" -v lang="$lang" \
        -v loc_warn="$loc_warn" -v loc_high="$loc_high" \
        -v added="$added" -v have_growth="$HAVE_GROWTH" \
        -v min_added="$REVIEW_GROWTH_MIN_ADDED" \
        -v cohesive_max="$REVIEW_COHESIVE_MAX_UNITS" \
        -v b_warn="$b_warn" -v b_high="$b_high" \
        -v b_type="$b_type" -v b_cat="$b_cat" \
        -v measure_only="$MEASURE_ONLY" '
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
    # >>> shared:unit-segmenters-awk (kept in sync with ship-issue/split-verify.sh by tests/validate-shared-scanner-sync.sh)
    function is_unit_header(line, lang) {
        if (lang == "py") return line ~ /^(async[ \t]+)?(def|class)[ \t]+[A-Za-z_][A-Za-z0-9_]*/
        if (lang == "js") return line ~ /^(export[ \t]+)?(default[ \t]+)?(async[ \t]+)?(function|class|const|let|var)[ \t]+[A-Za-z_$][A-Za-z0-9_$]*/
        if (lang == "ts") return line ~ /^(export[ \t]+)?(default[ \t]+)?(declare[ \t]+)?(async[ \t]+)?(const[ \t]+enum|abstract[ \t]+class|function|class|const|let|var|interface|type|enum|namespace|module)[ \t]+[A-Za-z_$][A-Za-z0-9_$]*/
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
        else if (lang == "ts") { sub(/^(export[ \t]+)?(default[ \t]+)?(declare[ \t]+)?(async[ \t]+)?(const[ \t]+enum|abstract[ \t]+class|function|class|const|let|var|interface|type|enum|namespace|module)[ \t]+/, "", s) }
        else if (lang == "rs") { sub(/^(pub(\([a-z]+\))?[ \t]+)?(async[ \t]+)?(fn|struct|enum|trait|impl|mod)[ \t]+/, "", s) }
        else if (lang == "go") { sub(/^(func|type|var|const)[ \t]+/, "", s) }
        else if (lang == "sh") { sub(/^function[ \t]+/, "", s); sub(/[ \t]*\(.*$/, "", s) }
        if (match(s, /^[A-Za-z_$][A-Za-z0-9_$]*/)) return substr(s, 1, RLENGTH)
        return ""
    }
    function is_test_header(line, lang) {
        if (lang == "py") return line ~ /^(async[ \t]+)?def[ \t]+test_/ || line ~ /^class[ \t]+Test/
        if (lang == "js" || lang == "ts") return line ~ /^[ \t]*(describe|it|test)[ \t]*\(/
        if (lang == "go") return line ~ /^func[ \t]+(Test|Benchmark|Fuzz|Example)/
        if (lang == "sh") return line ~ /^(function[ \t]+)?test_[A-Za-z0-9_]*[ \t]*\([ \t]*\)/
        return 0
    }
    function is_comment(line, lang) {
        if (lang == "py" || lang == "sh") return line ~ /^[ \t]*#/
        if (lang == "js" || lang == "ts" || lang == "rs" || lang == "go") return line ~ /^[ \t]*(\/\/|\/\*|\*)/
        return 0
    }
    # <<< shared:unit-segmenters-awk
    function nest_unit(lang) {
        if (lang == "js" || lang == "ts" || lang == "md") return 2
        return 4
    }
    # is_decl_file: a TypeScript DECLARATION file (*.d.ts), type-level by
    # construction with no runtime units to extract (#726). Mirrors
    # is_decl_file() in patterns.py, including the case-insensitive match, so
    # Foo.D.TS classifies the same as foo.d.ts.
    #
    # NOT a skip: a skipped .d.ts would be indistinguishable from an unscanned
    # one. It is measured and sized as usual and only its SEAM is suppressed, so
    # it falls through to the reasoned decline.
    function is_decl_file(p) {
        return tolower(p) ~ /\.d\.ts$/
    }
    function unit_noun(lang) {
        if (lang == "py") return "def"
        if (lang == "js") return "function"
        if (lang == "ts") return "declaration"
        if (lang == "rs") return "fn"
        if (lang == "go") return "func"
        if (lang == "sh") return "function"
        if (lang == "md") return "section"
        return "unit"
    }
    # <<< shared:loc-helpers-awk

    # >>> shared:split-shape-awk (kept in sync with check-decomposition/patterns.sh by tests/validate-shared-scanner-sync.sh)
    # Language-shaped split guidance, shared by BOTH lenses (#725). This is the
    # awk-fallback half of SPLIT_SHAPE / split_shape() in the .py primaries.
    #
    # NB: no apostrophes anywhere in this region. The whole awk program is a
    # single-quoted shell string, so one would end it and the next line would be
    # parsed as shell.
    #
    # Names the SHAPE of the split, not a generic "consider splitting" — the
    # finding has to be actionable or it is noise. Keyed by the same language
    # keys the segmenters use, so advice and measurement can never disagree
    # about what a file IS.
    #
    # The final `return` is the shape for a language with no segmenter, and it
    # is INSIDE the region deliberately: as a bare literal at each call site it
    # was one more unpinned copy of the same fact.
    function split_shape(lang) {
        if (lang == "rs") return "new subdir module; mod.rs re-exports the decomposed units"
        if (lang == "py") return "package dir with __init__.py re-exporting the public surface"
        if (lang == "js") return "sibling modules + a barrel index.ts"
        if (lang == "ts") return "types/ dir split by domain + a re-exporting barrel index.ts"
        if (lang == "go") return "additional files in the same package (no import churn)"
        if (lang == "sh") return "sourced fragment + an explicit ordered list (split-suite convention)"
        if (lang == "md") return "progressive disclosure: move detail to linked files, leave a one-line pointer"
        return "extract a cohesive unit into a sibling module"
    }
    # <<< shared:split-shape-awk
    function emit(line_no, category, evidence, certainty) {
        printf "%s\t%d\t%s\t%s\t%s\n", path, line_no, category, evidence, certainty
    }

    # is_generated(n) — does a generated-file marker appear in the first 20 lines?
    #
    # ONE definition, two call sites: the decline-reason arm and measure mode
    # (#756). Each previously carried a literal copy of this alternation, kept in
    # sync by hand — an edit adding a marker to one and missing the other would
    # make the same file read as generated by one arm and not the other, inside
    # the same scanner. That is the #663 drift class, intra-file. Mirrors
    # GENERATED_RE in sizing.py; the sibling helpers above are factored the same
    # way.
    #
    # Deliberately OUTSIDE the shared:* regions: those are pinned byte-for-byte
    # against check-decomposition/patterns.sh, so a helper this file introduces
    # on its own cannot live inside one.
    function is_generated(n,   i) {
        for (i = 1; i <= n && i <= 20; i++) {
            if (toupper(L[i]) ~ /@GENERATED|CODE GENERATED BY|DO NOT EDIT|AUTOGENERATED|AUTO-GENERATED/) return 1
        }
        return 0
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

        # ---- measure mode: emit metrics, not findings (#756) ----------------
        # Placed immediately AFTER the shared region and outside it: the region
        # is pinned byte-for-byte against check-decomposition/patterns.sh by
        # tests/validate-shared-scanner-sync.sh, so a line added inside it would
        # register as drift. 13 fields, matching measure_record() in sizing.py.
        if (measure_only == 1) {
            generated = is_generated(total)
            printf "%s\t%d\t%d\t%d\t%d\t%d\t%s\t%d\t%d\t%d\t%d\t%s\t%s\n", \
                path, total, production, prod_units, comment_pct, generated, lang, \
                loc_warn, loc_high, b_warn, b_high, b_type, b_cat
            exit 0
        }

        # ---- classified prose: its own budget, never the code one (#724) ----
        # Mirrors scan_prose() in sizing.py. Checked BEFORE the production-LOC
        # early return below, which would otherwise swallow the whole branch: a
        # 580-line agent definition measures 501 production LOC, under the
        # generic md warning of 700, so it would return here and never be
        # classified at all. That early return IS the defect #724 reports, seen
        # from the inside.
        #
        # EXACTLY ONE size verdict per file (#701), as on the audit lens: a
        # b_type means "this file type has its own budget", so the generic
        # file-length row is skipped rather than emitted alongside.
        #
        # Thresholds and label come from the SHARED bloat-spec region above, so
        # the two lenses can never disagree about what the file is. The
        # DISPOSITION stays this lens own: the audit lens grades a bloat row
        # flat HIGH/MEDIUM on size alone, which for a per-PR gate would make a
        # one-line touch to a pre-existing 580-line agent file blocking — the
        # outcome AC4 exists to prevent, on the file type most likely to be
        # brushed against. Measured on TOTAL lines (these files load whole).
        if (b_type != "") {
            if (total <= b_warn) exit 0

            # PRIOR IS EXACT HERE, not the approximation the production-LOC
            # path needs. That path subtracts raw insertions from a count that
            # excludes blanks and comments, over-subtracts, and needs a clamp to
            # stop a whitespace-heavy reformat faking a crossing. This budget
            # already counts every line and numstat already counts every
            # inserted line, so the two are in the same unit and the
            # subtraction is the real pre-diff size. The clamp is absent
            # deliberately, not by oversight.
            b_prior = (have_growth == 1) ? total - added : total
            if (b_prior < 0) b_prior = 0
            b_crossed = (have_growth == 1 && b_prior <= b_warn) ? 1 : 0
            b_material = (have_growth == 1 && added >= min_added) ? 1 : 0

            b_band = (total > b_high) ? "high" : "warning"
            b_limit = (total > b_high) ? b_high : b_warn

            if (b_crossed) {
                certainty = (total > b_high) ? "HIGH" : "MEDIUM"
                evidence = sprintf("%s exceeds %s threshold: %d lines (>%d); this diff added %d lines and pushed it over the %d budget", \
                    b_type, b_band, total, b_limit, added, b_warn)
            } else if (b_material) {
                certainty = "MEDIUM"
                evidence = sprintf("%s exceeds %s threshold: %d lines (>%d); already over before this diff, which added %d more lines", \
                    b_type, b_band, total, b_limit, added)
            } else if (have_growth == 1) {
                certainty = "LOW"
                evidence = sprintf("%s exceeds %s threshold: %d lines (>%d); pre-existing size, this diff added only %d lines — informational, not this PR'"'"'s debt", \
                    b_type, b_band, total, b_limit, added)
            } else {
                certainty = "LOW"
                evidence = sprintf("%s exceeds %s threshold: %d lines (>%d); no diff growth data supplied — informational only", \
                    b_type, b_band, total, b_limit)
            }
            emit(1, b_cat, evidence, certainty)

            # Prose splits by progressive disclosure, never by a line range.
            # Emitted only for dispositions a reviewer should act on, mirroring
            # the seam rule on the LOC path.
            if (b_crossed || b_material) {
                emit(1, "decomposition-seam", sprintf("split shape for %s: %s", \
                    b_type, split_shape("md")), "MEDIUM")
            }
            exit 0
        }

        # ---- review lens: growth-aware disposition (AC4) --------------------
        # Only "crossed" and "material" are ever blocking-eligible. A one-line
        # touch to a pre-existing oversized file CANNOT produce a blocking row —
        # the property tests/validate-sizing-scanner.sh pins.
        if (production <= loc_warn) exit 0

        # Production LOC before this diff, approximated by removing the added
        # lines.
        #
        # THE APPROXIMATION ERRS LOW, NOT HIGH. numstat counts RAW insertions —
        # blanks and comments included — while `production` excludes them, so
        # subtracting one from the other over-subtracts and `prior` is a LOWER
        # bound on the pre-diff size. (An earlier comment claimed the opposite
        # and reasoned that erring high fails toward the quiet disposition; it
        # fails toward the LOUD one.) A reformat bundled with a small real change
        # — 900 blank lines and 5 production lines added to an already-851-LOC
        # file — drove `prior` negative, satisfied `prior <= loc_warn`, and
        # produced a HIGH "this diff pushed it over" on a file that was already
        # far past the threshold: the loudest disposition for exactly the case
        # AC4 exists to keep quiet.
        #
        # So `crossed` is CLAMPED: the added count cannot exceed the total
        # non-production content of the file, because those lines had to go
        # somewhere. (No apostrophes in this awk program — it is single-quoted,
        # so one would terminate the quote and break the script.)
        # `added` minus the blanks/comments/test lines present is a floor on how
        # many insertions were production; anything above it is what the diff
        # genuinely contributed to `production`.
        #
        # For the 900-blank reformat: non_production is 900, so at most 5 of the
        # 905 insertions were production, `prior` lands at 851 — the real value —
        # and the row takes the quiet `material` path instead of claiming a HIGH
        # crossing. For an ordinary diff, where insertions are mostly production,
        # non_production is small and the clamp changes nothing. `prior` floors
        # at 0: a negative value can never describe a real file.
        non_production = total - production
        added_production = added - non_production
        if (added_production < 0) added_production = 0
        prior = (have_growth == 1) ? production - added_production : production
        if (prior < 0) prior = 0
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
        #
        # NO `lang != ""` GUARD. A file whose extension has no segmenter (.rb,
        # .java, .c, .cpp, .kt — scanned, since none are skipped) yields an empty
        # lang, and gating on it dropped BOTH arms: the first false for want of a
        # language, the second false for want of a quiet disposition, so an
        # actionable over-threshold file emitted a file-length row and NO seam
        # row — withholding from the review dimension the one thing it consumes.
        #
        # `!is_decl_file(path)` (#726): a .d.ts has no runtime units to extract,
        # so a shape row would name a destination for a file with nothing to
        # move. It takes the decline branch instead. The audit lens reaches the
        # same outcome through `seams == 0` — the two lenses gate on different
        # quantities (growth vs seams), so each states the suppression itself.
        if ((crossed || material) && !is_decl_file(path)) {
            emit(1, "decomposition-seam", sprintf("split shape for %s: %s", \
                (lang != "" ? lang : "this file"), split_shape(lang)), "MEDIUM")
        } else {
            # ---- reasoned decline ------------------------------------------
            # A file over threshold with no actionable growth is a RESULT, not a
            # silence. Reasons reused verbatim from check-decomposition/contract.md
            # so a decline reads identically in both lenses.
            generated = is_generated(total)
            # Ahead of `generated` on purpose (#726) — matches the order in
            # sizing.py. A .d.ts is often ALSO banner-marked as generated, and
            # the declaration-file reason is the more specific fact.
            if (is_decl_file(path)) reason = "type declaration file — no runtime units to extract"
            else if (generated) reason = "generated file — regenerate rather than split"
            else if (prod_units <= cohesive_max) reason = "single cohesive unit — no internal seam to cut"
            else if (comment_pct >= 50) reason = "majority prose/comment — length is documentation, not logic"
            else reason = "no low-coupling seam found — units are mutually referential"
            emit(1, "decomposition-seam", sprintf("declined: %s (%d production LOC, %d top-level units)", \
                reason, production, prod_units), "LOW")
        }
    }
    ' "$file" || true

done <"$FILE_LIST"
