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
# >>> shared:bloat-config (kept in sync with ship-issue/sizing.sh by tests/validate-shared-scanner-sync.sh)
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
        *.js | *.jsx | *.mjs | *.cjs) lang="js" ;;
        *.ts | *.tsx) lang="ts" ;;
        *.rs) lang="rs" ;;
        *.go) lang="go" ;;
        *.sh | *.bash) lang="sh" ;;
        *.md | *.markdown) lang="md" ;;
        *.swift) lang="swift" ;;
    esac

    # >>> shared:bloat-spec (kept in sync with ship-issue/sizing.sh by tests/validate-shared-scanner-sync.sh)
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

    LC_ALL=C command awk \
        -v path="$file" -v lang="$lang" \
        -v loc_warn="$DECOMP_LOC_WARN" -v loc_high="$DECOMP_LOC_HIGH" \
        -v seam_min_units="$DECOMP_SEAM_MIN_UNITS" \
        -v seam_min_lines="$DECOMP_SEAM_MIN_LINES" \
        -v seam_max_fanin="$DECOMP_SEAM_MAX_FANIN" \
        -v god_units="$DECOMP_GOD_UNITS" -v god_concerns="$DECOMP_GOD_CONCERNS" \
        -v cohesive_max="$DECOMP_COHESIVE_MAX_UNITS" \
        -v b_warn="$b_warn" -v b_high="$b_high" \
        -v b_type="$b_type" -v b_cat="$b_cat" \
        -v b_kind="$b_kind" -v b_root="$MEMORY_BUNDLE_ROOT" '
    # ---- helpers -----------------------------------------------------------
    # family_prefix: snake_case splits at the first underscore; camel/Pascal at
    # the first internal A-Z. A leading RUN of uppercase is an acronym and stays
    # whole (#778): HTTPServer -> http, PARSE -> parse. Lowercased. Mirrors
    # family_prefix() in patterns.py (ASCII-only on both sides so the two agree
    # on non-ASCII identifiers).
    function family_prefix(name,   cut, i, n) {
        cut = index(name, "_")
        if (cut > 1) return tolower(substr(name, 1, cut - 1))
        n = length(name)
        i = 1
        while (i <= n && substr(name, i, 1) ~ /[A-Z]/) i++
        if (i > 2) {
            # Back off only when a lowercase follows; past end-of-name the run
            # IS the whole name and there is nothing to give back.
            if (i <= n) i--
            return tolower(substr(name, 1, i - 1))
        }
        if (i < 2) i = 2
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
    # >>> shared:unit-segmenters-awk (kept in sync with ship-issue/split-verify.sh by tests/validate-shared-scanner-sync.sh)
    function is_unit_header(line, lang) {
        if (lang == "py") return line ~ /^(async[ \t]+)?(def|class)[ \t]+[A-Za-z_][A-Za-z0-9_]*/
        if (lang == "js") return line ~ /^(export[ \t]+)?(default[ \t]+)?(async[ \t]+)?(function|class|const|let|var)[ \t]+[A-Za-z_$][A-Za-z0-9_$]*/
        if (lang == "ts") return line ~ /^(export[ \t]+)?(default[ \t]+)?(declare[ \t]+)?(async[ \t]+)?(const[ \t]+enum|abstract[ \t]+class|function|class|const|let|var|interface|type|enum|namespace|module)[ \t]+[A-Za-z_$][A-Za-z0-9_$]*/
        if (lang == "rs") return line ~ /^((pub(\([a-z:_ ]+\))?|default|async|unsafe|const|extern([ \t]+"[^"]*")?)[ \t]+)*(macro_rules![ \t]+[A-Za-z_][A-Za-z0-9_]*|impl(<([^<>]|<([^<>]|<[^<>]*>)*>)*>)?[ \t]+([^ \t].*[ \t]for[ \t]+)?(&[ \t]*)?([\047][A-Za-z_][A-Za-z0-9_]*[ \t]+)?(mut[ \t]+)?(dyn[ \t]+)?([A-Za-z_][A-Za-z0-9_]*::)*[A-Za-z_][A-Za-z0-9_]*|extern[ \t]+crate[ \t]+[A-Za-z_][A-Za-z0-9_]*|(fn|struct|enum|trait|mod|type|static|const|union)[ \t]+[A-Za-z_][A-Za-z0-9_]*)/
        if (lang == "go") return line ~ /^func[ \t]*\([ \t]*([A-Za-z_][A-Za-z0-9_]*[ \t]+)?\*?[ \t]*[A-Za-z_][A-Za-z0-9_]*(\[[^\]]*\])?[ \t]*\)[ \t]*[A-Za-z_][A-Za-z0-9_]*/ || line ~ /^(func|type|var|const)[ \t]+[A-Za-z_][A-Za-z0-9_]*/ || line ~ /^(var|const|type)[ \t]*\(/
        if (lang == "swift") return line ~ /^((public|private|internal|fileprivate|open|final|static|class|override|indirect|@[A-Za-z_][A-Za-z0-9_]*)[ \t]+)*(func|class|struct|enum|protocol|extension|actor|typealias)[ \t]+[A-Za-z_][A-Za-z0-9_]*/
        if (lang == "sh") return line ~ /^(function[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]*\([ \t]*\)/ || line ~ /^function[ \t]+[A-Za-z_][A-Za-z0-9_]*/
        return 0
    }
    # unit_name: the captured identifier. POSIX awk has no capture groups, so the
    # keyword prefix is stripped and the leading identifier read off directly —
    # equivalent to patterns.py group(1) for every arm above.
    function unit_name(line, lang,   s, r, recv) {
        s = line
        if (lang == "py") { sub(/^(async[ \t]+)?(def|class)[ \t]+/, "", s) }
        else if (lang == "js") { sub(/^(export[ \t]+)?(default[ \t]+)?(async[ \t]+)?(function|class|const|let|var)[ \t]+/, "", s) }
        else if (lang == "ts") { sub(/^(export[ \t]+)?(default[ \t]+)?(declare[ \t]+)?(async[ \t]+)?(const[ \t]+enum|abstract[ \t]+class|function|class|const|let|var|interface|type|enum|namespace|module)[ \t]+/, "", s) }
        else if (lang == "rs") {
            # Strip modifiers, then the item keyword. `impl` additionally drops
            # its generics, an optional `Trait for`, and a leading `&`, so the
            # captured identifier is the TYPE — mirroring the impl arm of
            # UNIT_RE["rs"] in patterns.py (#727).
            #
            # `extern crate` is stripped BEFORE the modifier pass: that pass
            # would otherwise consume the `extern` as a modifier and leave
            # `crate foo`, whose leading identifier reads as `crate` rather
            # than the crate name.
            sub(/^(pub(\([a-z:_ ]+\))?[ \t]+)?extern[ \t]+crate[ \t]+/, "", s)
            sub(/^((pub(\([a-z:_ ]+\))?|default|async|unsafe|const|extern([ \t]+"[^"]*")?)[ \t]+)*/, "", s)
            if (s ~ /^macro_rules![ \t]+/) { sub(/^macro_rules![ \t]+/, "", s) }
            else if (s ~ /^impl/) {
                sub(/^impl(<([^<>]|<([^<>]|<[^<>]*>)*>)*>)?[ \t]+/, "", s)
                sub(/^[^ \t].*[ \t]for[ \t]+/, "", s)
                sub(/^&[ \t]*/, "", s)
                # Borrow markers before the type: a lifetime (\047 is an
                # apostrophe — a literal one would end this single-quoted awk
                # program) and/or `mut`. Without these, `for &mut Foo` yields
                # the keyword `mut` as the unit name.
                sub(/^[\047][A-Za-z_][A-Za-z0-9_]*[ \t]+/, "", s)
                sub(/^mut[ \t]+/, "", s)
                sub(/^dyn[ \t]+/, "", s)
                # Path prefix: capture the LAST segment, so crate::bar::Baz
                # clusters with an unqualified Baz rather than under `crate`.
                sub(/^([A-Za-z_][A-Za-z0-9_]*::)+/, "", s)
            }
            else { sub(/^(fn|struct|enum|trait|mod|type|static|const|union)[ \t]+/, "", s) }
        }
        else if (lang == "go") {
            # A METHOD is named Receiver_Method (#727). awk has no capture
            # groups, so the receiver type is read off the parenthesized clause
            # and re-joined to the method name by hand — the same string
            # patterns.py builds by joining its two groups.
            if (s ~ /^func[ \t]*\(/) {
                r = s
                sub(/^func[ \t]*\([ \t]*/, "", r)
                sub(/^[A-Za-z_][A-Za-z0-9_]*[ \t]+/, "", r)   # binder, if named
                sub(/^\*[ \t]*/, "", r)                        # pointer receiver
                if (!match(r, /^[A-Za-z_][A-Za-z0-9_]*/)) return ""
                recv = substr(r, 1, RLENGTH)
                r = substr(r, RLENGTH + 1)
                sub(/^\[[^\]]*\]/, "", r)                      # generic params
                sub(/^[ \t]*\)[ \t]*/, "", r)
                if (!match(r, /^[A-Za-z_][A-Za-z0-9_]*/)) return ""
                return recv "_" substr(r, 1, RLENGTH)
            }
            # A GROUPED declaration is named for its keyword.
            if (match(s, /^(var|const|type)[ \t]*\(/)) {
                match(s, /^(var|const|type)/)
                return substr(s, 1, RLENGTH)
            }
            sub(/^(func|type|var|const)[ \t]+/, "", s)
        }
        # swift: `class` appears in BOTH the modifier group and the keyword
        # alternation (`class func` is a type method; `class Foo` is a type).
        # POSIX awk ERE is leftmost-LONGEST over the whole match, and only one
        # parse of each valid spelling reaches a trailing identifier, so the two
        # resolve without an ordering hack. A malformed spelling that captures a
        # KEYWORD as the name is rejected by is_reserved_name below.
        else if (lang == "swift") { sub(/^((public|private|internal|fileprivate|open|final|static|class|override|indirect|@[A-Za-z_][A-Za-z0-9_]*)[ \t]+)*(func|class|struct|enum|protocol|extension|actor|typealias)[ \t]+/, "", s) }
        else if (lang == "sh") { sub(/^function[ \t]+/, "", s); sub(/[ \t]*\(.*$/, "", s) }
        if (match(s, /^[A-Za-z_$][A-Za-z0-9_$]*/)) return substr(s, 1, RLENGTH)
        return ""
    }
    # is_reserved_name: NM is a keyword that must never be accepted as a unit
    # name. The awk half of RESERVED_UNIT_NAME in the .py primaries (#728).
    #
    # Swift `class` sits in BOTH the modifier group and the keyword alternation,
    # so `open class override Foo` parses `class` as the keyword and yields
    # `override` as the name — which would become a seam family and a
    # god-module concern in human-read evidence. A post-match filter rather than
    # a negative lookahead because POSIX awk ERE has NO lookahead: a
    # Python-only construct there would make the two impls disagree on exactly
    # these lines. A fixed-string membership test transcribes verbatim.
    function is_reserved_name(nm, lang) {
        if (lang != "swift") return 0
        return index(" public private internal fileprivate open final static class override indirect func struct enum protocol extension actor typealias associatedtype ", " " nm " ") > 0
    }
    function is_test_header(line, lang) {
        if (lang == "py") return line ~ /^(async[ \t]+)?def[ \t]+test_/ || line ~ /^class[ \t]+Test/
        if (lang == "js" || lang == "ts") return line ~ /^[ \t]*(describe|it|test)[ \t]*\(/
        if (lang == "go") return line ~ /^func[ \t]+(Test|Benchmark|Fuzz|Example)([A-Z_]|[ \t]*\()/ || line ~ /^func[ \t]*\([^)]*\)[ \t]*(Test|Benchmark|Fuzz|Example)([A-Z_]|[ \t]*\()/
        if (lang == "swift") return line ~ /^((public|private|internal|fileprivate|open|final|static|class|override|indirect|@[A-Za-z_][A-Za-z0-9_]*)[ \t]+)*(func[ \t]+test|class[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*:[^{]*XCTestCase)/
        if (lang == "sh") return line ~ /^(function[ \t]+)?test_[A-Za-z0-9_]*[ \t]*\([ \t]*\)/
        return 0
    }
    # is_attr_test: an ATTRIBUTE line marking the NEXT unit as test code —
    # Rust #[test]/#[cfg(test)], swift-testing @Test. The awk half of
    # ATTR_TEST_RE in the .py primaries (#728), replacing what was a hardcoded
    # `lang == "rs"` test inline in the segmenter loop.
    #
    # `@Test\b` has no POSIX ERE spelling (no \b), so the boundary is written
    # explicitly as "not an identifier character" — with an end-of-string
    # alternative, since a bare `@Test` line has nothing after it.
    function is_attr_test(line, lang) {
        if (lang == "rs") return line ~ /^[ \t]*#\[(cfg\(test\)|test)\]/
        if (lang == "swift") return line ~ /^[ \t]*@Test([^A-Za-z0-9_]|$)/
        return 0
    }
    function is_comment(line, lang) {
        if (lang == "py" || lang == "sh") return line ~ /^[ \t]*#/
        if (lang == "js" || lang == "ts" || lang == "rs" || lang == "go" || lang == "swift") return line ~ /^[ \t]*(\/\/|\/\*|\*)/
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
        if (lang == "swift") return "declaration"
        return "unit"
    }
    # <<< shared:loc-helpers-awk

    # >>> shared:split-shape-awk (kept in sync with ship-issue/sizing.sh by tests/validate-shared-scanner-sync.sh)
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
        if (lang == "swift") return "extensions in separate files (Type+Concern.swift), same module"
        if (lang == "sh") return "sourced fragment + an explicit ordered list (split-suite convention)"
        if (lang == "md") return "progressive disclosure: move detail to linked files, leave a one-line pointer"
        return "extract a cohesive unit into a sibling module"
    }
    # <<< shared:split-shape-awk

    # >>> shared:bundle-seam-awk (kept in sync with ship-issue/sizing.sh by tests/validate-shared-scanner-sync.sh)
    # Bundle-shaped split guidance, shared by BOTH lenses (#729). This is the
    # awk-fallback half of bundle_seam_rows()/concept_dir() in the .py primaries.
    #
    # An index splits by TOPIC CLUSTER and a concept by extracting its second
    # lesson; neither is a line range, so the generic markdown heading-cluster
    # seam is wrong guidance rather than merely vague, and is SUPPRESSED for a
    # bundle file. The concept row REQUIRES the index line in the same breath:
    # extracting the lesson without it is #697 exactly — written, never
    # recallable, and nothing errors.
    #
    # Rows are BUFFERED into bs_cat/bs_ev/bs_cert rather than emitted, because
    # the two lenses differ on which survive: the audit lens emits every row
    # including the LOW declined ones (a backlog reader must be able to tell
    # examined-and-unsplittable from not-scanned), while the review lens drops
    # those. awk has no return-a-list, so the caller reads the globals and the
    # count comes back as the return value.
    #
    # NB: no apostrophes anywhere in this region. The whole awk program is a
    # single-quoted shell string, so one would end it and the next line would be
    # parsed as shell.
    #
    # NB: the extra parameters after the real ones are awk-LOCAL scratch (the
    # extra-parameter idiom) — awk has no block scope, and these run inside
    # loops that already use i/d as counters.
    function concept_dir(p,   slash, i) {
        slash = 0
        for (i = length(p); i >= 1; i--) if (substr(p, i, 1) == "/") { slash = i; break }
        if (slash) return substr(p, 1, slash - 1)
        return b_root
    }
    function bundle_seam_rows(kind,   d, i, bn, bchosen, bns, bsec, clist, s) {
        # Topic clusters — mirrors bundle_sections() in the .py primary, NOT the
        # top-level units: those are the shallowest depth, which for a
        # `# Title` + `## topics` file is the lone title, so every index would
        # decline. Pick the shallowest depth with >= 2 headings, falling back to
        # the shallowest.
        bchosen = 0
        for (d = 1; d <= 6; d++) {
            bn = 0
            for (i = 1; i <= nh; i++) if (hd[i] == d) bn++
            if (bn > 0 && bchosen == 0) bchosen = d
            if (bn >= 2) { bchosen = d; break }
        }
        bns = 0
        for (i = 1; i <= nh; i++) {
            if (hd[i] != bchosen) continue
            s = md_slug(ht[i]); if (s == "") s = "section"
            bns++; bsec[bns] = s
        }
        clist = ""
        for (i = 1; i <= bns && i <= 5; i++) clist = (i == 1) ? bsec[i] : clist ", " bsec[i]
        bs_cat[1] = "decomposition-seam"
        if (kind == "index") {
            if (bns >= 2) {
                bs_ev[1] = sprintf("index split: %d topic clusters (%s) -> index-<topic>.md; root keeps one pointer line per sub-index", bns, clist)
                bs_cert[1] = "HIGH"
            } else {
                bs_ev[1] = sprintf("declined: index has no topic clusters to split on (%d sections) — trim entries instead", bns)
                bs_cert[1] = "LOW"
            }
        } else if (bns >= 2) {
            bs_ev[1] = sprintf("concept split: extract %s to %s/%s.md AND add its index line (an extracted concept with no index line is an orphan)", bsec[2], concept_dir(path), bsec[2])
            bs_cert[1] = "HIGH"
        } else {
            bs_ev[1] = sprintf("declined: single lesson — no second concept to extract (%d sections); tighten the prose instead", bns)
            bs_cert[1] = "LOW"
        }
        return 1
    }
    # <<< shared:bundle-seam-awk

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
                is_hdr = is_unit_header(line, lang)
                # An attribute line marks the NEXT unit as test code (Rust
                # #[test], swift-testing @Test). Table-driven since #728.
                #
                # The header check runs FIRST and the attribute only consumes
                # the line when it is NOT itself a unit header: swift-testing
                # writes `@Test func foo()` on ONE line, which under a
                # continue-first shape would swallow the unit and mark the next
                # (production) one as a test. Rust `#[test]` always stands
                # alone, so its behavior is unchanged. Mirrors find_units() in
                # the .py primaries.
                #
                # Only a COLUMN-ZERO attribute may set the flag (#727). Both
                # attribute patterns tolerate indent — rs because the same
                # spelling doubles as the test-REGION marker below — so an
                # indented attribute inside a block (#[test] within
                # `mod tests { ... }`, @Test within an XCTestCase body) used to
                # mark the next TOP-LEVEL unit, a production declaration after
                # the block, as test code. Language-agnostic because the
                # invariant is: units are column-zero anchored, so an indented
                # attribute cannot be marking one.
                #
                # NB: no apostrophes in this awk program — it is one
                # single-quoted shell string, so one would end it.
                if (line !~ /^[ \t]/ && is_attr_test(line, lang)) {
                    pending_test = 1
                    if (!is_hdr) continue
                }
                if (!is_hdr) continue
                nm = unit_name(line, lang)
                if (nm == "") continue
                # See is_reserved_name: a keyword captured as a name means a
                # modifier was parsed as the unit keyword. Drop the phantom
                # unit; the line is still counted by the sizing layer.
                #
                # pending_test MUST be cleared here. The dropped header is what
                # the attribute was marking, so leaving the flag set carries it
                # onto the NEXT genuine unit and marks a PRODUCTION unit as
                # test, removing its lines from production LOC.
                if (is_reserved_name(nm, lang)) { pending_test = 0; continue }
                nu++
                un[nu] = nm; us[nu] = i
                if (pending_test) { ut[nu] = 1; pending_test = 0 }
                else if (is_test_header(line, lang)) ut[nu] = 1
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
        # Whole-file test-region markers. The region runs to the end of the unit
        # the marker INTRODUCES, not unconditionally to EOF (#727). For the
        # conventional TRAILING placement those are the same line, so this is a
        # no-op there; it differs only for a marker in the MIDDLE of a file,
        # where running to EOF excluded every production unit that followed.
        # Falling back to EOF when no unit follows preserves a trailing marker
        # with no unit after it (py `if __name__`, sh `# --- tests ---`).
        for (i = 1; i <= total; i++) {
            hit = 0
            if (lang == "py" && L[i] ~ /^if[ \t]+__name__/) hit = 1
            else if (lang == "rs" && L[i] ~ /^#\[cfg\(test\)\]/) hit = 1
            else if (lang == "sh" && L[i] ~ /^#[ \t]*-+[ \t]*tests?[ \t]*-+/) hit = 1
            if (hit) {
                stop = total
                for (k = 1; k <= nu; k++) if (us[k] >= i) { stop = uend[k]; break }
                for (j = i; j <= stop; j++) tl[j] = 1
                break
            }
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

        # ---- bundle-aware split guidance (#700, shared #729) ----------------
        # The ROWS come from the shared bundle-seam-awk region so both lenses
        # agree on the shape; this lens emits every one of them, including the
        # LOW declined rows — a backlog reader needs to see that a file was
        # examined and found unsplittable, since silence here would be
        # indistinguishable from not-scanned. Gated on `over`, so a bundle file
        # inside its budget emits nothing.
        if (b_kind != "") {
            if (over) {
                bs_n = bundle_seam_rows(b_kind)
                for (bs_i = 1; bs_i <= bs_n; bs_i++) emit(1, bs_cat[bs_i], bs_ev[bs_i], bs_cert[bs_i])
            }
            exit 0
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
        # A .d.ts yields no seam, and therefore no shape row either (that emit
        # is gated on seams > 0). It still reaches the decline below — examined
        # and found unsplittable, not skipped. Mirrors the `[] if is_decl_file`
        # loop guard in patterns.py.
        for (i = 1; !is_decl_file(path) && i <= nc; i++) {
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

        # ---- the split SHAPE (#725) -----------------------------------------
        # Mirrors the shape emit in scan_file() (patterns.py). The seam rows
        # above say WHERE to cut; this says what the result should LOOK LIKE.
        #
        # Gated on `seams > 0`, NOT merely `over`: the decline arm below covers
        # `over && seams == 0`, and a shape row beside a decline would
        # contradict its own neighbour — telling the reader to build a package
        # dir out of a file the scanner just said has nothing to cut.
        #
        # Unreachable for a memory bundle by CONSTRUCTION (the bundle branch
        # above exits before this point), so an index/concept never receives
        # generic md advice. Fixtured anyway.
        if (seams > 0) {
            emit(1, "decomposition-seam", sprintf("split shape for %s: %s", \
                lang, split_shape(lang)), "MEDIUM")
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
            # Ahead of `generated` on purpose (#726) — matches the order in
            # patterns.py. A .d.ts is often ALSO banner-marked as generated, and
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
