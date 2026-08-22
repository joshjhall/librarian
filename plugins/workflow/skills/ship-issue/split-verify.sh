#!/usr/bin/env bash
# ship-issue — non-lossy split verification (portable bash fallback)
#
# A reviewer that suggests a decomposition is cheap to ignore; a reviewer that
# suggests one AND can PROVE the split lost nothing is cheap to accept. This tool
# is that proof (issue #695, AC8). Four mechanical checks:
#
#   1. LOC CONSERVATION  — production LOC across results ~= original, modulo new
#      import/mod/__init__ boilerplate (SPLIT_LOC_TOLERANCE, default 40).
#   2. UNIT PRESERVATION — every top-level unit present before is present after.
#   3. FAN-IN RESOLUTION — a unit referenced before is still defined-or-referenced
#      somewhere after, so no call site dangles.
#   4. MARKDOWN REACHABILITY — every heading that MOVED out is reachable by a link
#      from the post-split original. A split that moves prose out but leaves no
#      link has LOST content, not decomposed it.
#
# Usage: split-verify.sh <original-file> <post-split-original> [<result-file> ...]
#
# ARGUMENT CONTRACT. <original-file> is the PRE-split snapshot (typically
# `git show HEAD:path > /tmp/before.ext`). The FIRST result argument is the
# POST-split original — the same logical file after the split. Remaining results
# are the files content moved INTO. The first/rest distinction is load-bearing
# for the markdown check: a file linking to itself proves nothing about
# reachability, so only the "moved into" files count as link destinations.
#
# Output: TSV to stdout: file\tline\tcategory\tevidence\tcertainty
#
# Exit codes:
#   0 = verification ran (findings may or may not exist)
#   1 = usage error, or a named file is missing
#   2 = required runtime absent (fail loud — never a silent "no findings")
#
# Note: Uses full paths for commands per project shell-scripting conventions.
#
# Runtime: Python 3.11+ primary (split-verify.py) with this bash script as the
# portable fallback. SPLIT_VERIFY_FORCE_BASH=1 forces this bash body.
# See CLAUDE.md § Key conventions (runtime policy).
set -euo pipefail

# --- runtime selection: prefer python3>=3.11, else this bash fallback --------
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${SPLIT_VERIFY_FORCE_BASH:-0}" != "1" ] && [ -f "$_here/split-verify.py" ] &&
    command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    exec python3 "$_here/split-verify.py" "$@"
fi

if [ "$#" -lt 2 ]; then
    echo "Usage: split-verify.sh <original-file> <post-split-original> [<result-file> ...]" >&2
    exit 1
fi

if ! command -v awk >/dev/null 2>&1; then
    echo "Error: ship-issue split verification requires either python3>=3.11 or awk; found neither." >&2
    echo "  Install python3.11+ (preferred), or a POSIX awk (gawk/mawk/nawk)." >&2
    echo "  This tool refuses to report 'verified' when it cannot verify." >&2
    exit 2
fi

ORIGINAL="$1"
shift
POST_ORIGINAL="$1"
# An ARRAY, not a space-joined string: a result path containing a space or glob
# character (`docs/getting started.md` is entirely plausible for prose, which is
# what this tool's markdown arm exists for) would otherwise word-split into two
# nonexistent paths. bash 3.2 has indexed arrays — only ASSOCIATIVE arrays are
# off-limits under the portability policy.
RESULTS=("$@")

for f in "$ORIGINAL" "${RESULTS[@]}"; do
    if [ ! -f "$f" ]; then
        echo "Error: file not found: $f" >&2
        exit 1
    fi
done

SPLIT_LOC_TOLERANCE="${SPLIT_LOC_TOLERANCE:-40}"

# lang_of PATH — language key from the extension, mirroring sizing.sh.
lang_of() {
    case "$1" in
        *.py) echo "py" ;;
        *.js | *.jsx | *.mjs | *.cjs) echo "js" ;;
        *.ts | *.tsx) echo "ts" ;;
        *.rs) echo "rs" ;;
        *.go) echo "go" ;;
        *.sh | *.bash) echo "sh" ;;
        *.md | *.markdown) echo "md" ;;
        *.swift) echo "swift" ;;
        *) echo "" ;;
    esac
}

# The shared awk analysis library: production-LOC measurement plus unit-name and
# heading extraction. Emitted in one place and reused by each invocation below so
# the three modes cannot disagree about what a unit is.
awk_lib() {
    command cat <<'AWKLIB'
    # >>> shared:unit-segmenters-awk (kept in sync with ship-issue/sizing.sh by tests/validate-shared-scanner-sync.sh)
    function is_unit_header(line, lang) {
        if (lang == "py") return line ~ /^(async[ \t]+)?(def|class)[ \t]+[A-Za-z_][A-Za-z0-9_]*/
        if (lang == "js") return line ~ /^(export[ \t]+)?(default[ \t]+)?(async[ \t]+)?(function|class|const|let|var)[ \t]+[A-Za-z_$][A-Za-z0-9_$]*/
        if (lang == "ts") return line ~ /^(export[ \t]+)?(default[ \t]+)?(declare[ \t]+)?(async[ \t]+)?(const[ \t]+enum|abstract[ \t]+class|function|class|const|let|var|interface|type|enum|namespace|module)[ \t]+[A-Za-z_$][A-Za-z0-9_$]*/
        if (lang == "rs") return line ~ /^(pub(\([a-z]+\))?[ \t]+)?(async[ \t]+)?(fn|struct|enum|trait|impl|mod)[ \t]+[A-Za-z_][A-Za-z0-9_]*/
        if (lang == "go") return line ~ /^(func|type|var|const)[ \t]+[A-Za-z_][A-Za-z0-9_]*/
        if (lang == "swift") return line ~ /^((public|private|internal|fileprivate|open|final|static|class|override|indirect|@[A-Za-z_][A-Za-z0-9_]*)[ \t]+)*(func|class|struct|enum|protocol|extension|actor|typealias|associatedtype)[ \t]+[A-Za-z_][A-Za-z0-9_]*/
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
        # swift: `class` appears in BOTH the modifier group and the keyword
        # alternation (`class func` is a type method; `class Foo` is a type).
        # POSIX awk ERE is leftmost-LONGEST over the whole match, and only one
        # parse of each valid spelling reaches a trailing identifier, so the two
        # resolve without an ordering hack. A malformed spelling that captures a
        # KEYWORD as the name is rejected by is_reserved_name below.
        else if (lang == "swift") { sub(/^((public|private|internal|fileprivate|open|final|static|class|override|indirect|@[A-Za-z_][A-Za-z0-9_]*)[ \t]+)*(func|class|struct|enum|protocol|extension|actor|typealias|associatedtype)[ \t]+/, "", s) }
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
        if (lang == "go") return line ~ /^func[ \t]+(Test|Benchmark|Fuzz|Example)/
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
AWKLIB
}

# production_loc FILE LANG — production LOC (total minus blank/comment/test).
production_loc() {
    LC_ALL=C command awk -v lang="$2" "$(awk_lib)"'
    { L[NR] = $0 }
    END {
        total = NR
        nu = 0
        pending_test = 0
        if (lang != "" && lang != "md") {
            for (i = 1; i <= total; i++) {
                line = L[i]
                # Table-driven since #728 (was hardcoded to rs). Same
                # header-first ordering as the two scanners: a one-line
                # @Test func must still register as a unit, since the whole job
                # of this tool is proving no unit was lost in a split.
                #
                # NB: no apostrophes in this region — the awk program is a
                # single-quoted shell string, so one would end it and the rest
                # would be parsed as shell.
                if (is_attr_test(line, lang)) { pending_test = 1; if (!is_unit_header(line, lang)) continue }
                if (!is_unit_header(line, lang)) continue
                if (unit_name(line, lang) == "") continue
                # See is_reserved_name: a keyword captured as a name means a
                # modifier was parsed as the unit keyword (#728).
                if (is_reserved_name(unit_name(line, lang), lang)) continue
                nu++
                us[nu] = i
                if (pending_test) { ut[nu] = 1; pending_test = 0 }
                else if (is_test_header(line, lang)) ut[nu] = 1
                else ut[nu] = 0
            }
        }
        for (i = 1; i <= nu; i++) uend[i] = (i < nu) ? us[i + 1] - 1 : total
        for (i = 1; i <= nu; i++) {
            if (!ut[i]) continue
            for (j = us[i]; j <= uend[i]; j++) tl[j] = 1
        }
        for (i = 1; i <= total; i++) {
            hit = 0
            if (lang == "py" && L[i] ~ /^if[ \t]+__name__/) hit = 1
            else if (lang == "rs" && L[i] ~ /^[ \t]*#\[cfg\(test\)\]/) hit = 1
            else if (lang == "sh" && L[i] ~ /^#[ \t]*-+[ \t]*tests?[ \t]*-+/) hit = 1
            if (hit) { for (j = i; j <= total; j++) tl[j] = 1; break }
        }
        blank = 0; comment = 0; test_excluded = 0
        for (i = 1; i <= total; i++) {
            if (i in tl) { test_excluded++; continue }
            if (L[i] ~ /^[ \t]*$/) { blank++; continue }
            if (is_comment(L[i], lang)) { comment++; continue }
        }
        print total - blank - comment - test_excluded
    }
    ' "$1"
}

# unit_names FILE LANG — non-test top-level unit names, one per line.
unit_names() {
    [ -n "$2" ] && [ "$2" != "md" ] || return 0
    LC_ALL=C command awk -v lang="$2" "$(awk_lib)"'
    {
        if (lang == "rs" && $0 ~ /^[ \t]*#\[(cfg\(test\)|test)\]/) { pending = 1; next }
        if (!is_unit_header($0, lang)) next
        nm = unit_name($0, lang)
        if (nm == "") next
        if (pending) { pending = 0; next }
        if (lang != "rs" && is_test_header($0, lang)) next
        print nm
    }
    ' "$1"
}

# md_headings FILE — heading texts outside fenced code blocks.
md_headings() {
    LC_ALL=C command awk '
    /^```/ || /^~~~/ { fenced = !fenced; next }
    fenced { next }
    /^#+[ \t]+/ {
        t = $0
        sub(/^#+[ \t]+/, "", t)
        sub(/[ \t]+$/, "", t)
        if (t != "") print t
    }
    ' "$1"
}

# tokens FILE — identifier tokens, deduplicated.
tokens() {
    LC_ALL=C command awk '
    { gsub(/[^A-Za-z0-9_$]+/, " "); n = split($0, a, " "); for (i = 1; i <= n; i++) if (a[i] != "") seen[a[i]] = 1 }
    END { for (k in seen) print k }
    ' "$1"
}

emit() {
    command printf '%s\t%s\t%s\t%s\t%s\n' "$ORIGINAL" "1" "$1" "$2" "$3"
}

ORIG_LANG="$(lang_of "$ORIGINAL")"
ORIG_PROD="$(production_loc "$ORIGINAL" "$ORIG_LANG")"
ORIG_UNITS_FILE="$(command mktemp)"
RESULT_UNITS_FILE="$(command mktemp)"
RESULT_TOKENS_FILE="$(command mktemp)"
trap 'command rm -f "$ORIG_UNITS_FILE" "$RESULT_UNITS_FILE" "$RESULT_TOKENS_FILE"' EXIT

unit_names "$ORIGINAL" "$ORIG_LANG" | command sort -u >"$ORIG_UNITS_FILE"

RESULT_PROD=0
RESULT_COUNT=0
for f in "${RESULTS[@]}"; do
    flang="$(lang_of "$f")"
    p="$(production_loc "$f" "$flang")"
    RESULT_PROD=$((RESULT_PROD + p))
    RESULT_COUNT=$((RESULT_COUNT + 1))
    unit_names "$f" "$flang" >>"$RESULT_UNITS_FILE"
    tokens "$f" >>"$RESULT_TOKENS_FILE"
done
command sort -u -o "$RESULT_UNITS_FILE" "$RESULT_UNITS_FILE"
command sort -u -o "$RESULT_TOKENS_FILE" "$RESULT_TOKENS_FILE"

FINDINGS=0

# --- 1. LOC conservation -----------------------------------------------------
DELTA=$((RESULT_PROD - ORIG_PROD))
if [ "$DELTA" -lt "-$SPLIT_LOC_TOLERANCE" ]; then
    FINDINGS=$((FINDINGS + 1))
    emit "split-loc-drift" \
        "split lost $((-DELTA)) production LOC: ${ORIG_PROD} before, ${RESULT_PROD} across ${RESULT_COUNT} result file(s) (tolerance ${SPLIT_LOC_TOLERANCE}) — content may have been dropped rather than moved" \
        "HIGH"
fi

# --- 2. unit preservation ----------------------------------------------------
LOST="$(command comm -23 "$ORIG_UNITS_FILE" "$RESULT_UNITS_FILE")"
if [ -n "$LOST" ]; then
    FINDINGS=$((FINDINGS + 1))
    lost_n="$(command printf '%s\n' "$LOST" | command wc -l | command tr -d ' ')"
    shown="$(command printf '%s\n' "$LOST" | command head -5 | command tr '\n' ',' | command sed 's/,$//; s/,/, /g')"
    more=""
    [ "$lost_n" -gt 5 ] && more=" (+$((lost_n - 5)) more)"
    emit "split-unit-lost" \
        "${lost_n} top-level unit(s) present before the split are absent after: ${shown}${more}" \
        "HIGH"
fi

# --- 3. fan-in resolution ----------------------------------------------------
# A unit still CALLED in the result set but no longer DEFINED there has a
# dangling call site: the caller survived the split, the callee did not.
#
# THE PREDICATE IS "referenced AND NOT defined", not "neither defined nor
# referenced" (the shape this started as, which could never fire). A name that is
# neither defined nor referenced after the split is simply GONE — already
# reported by check 2 as a lost unit, with nothing dangling behind it. The
# dangerous case is the opposite: live callers pointing at a definition that no
# longer exists. Reported IN ADDITION to check 2's row; they say different things.
while IFS= read -r name; do
    [ -n "$name" ] || continue
    command grep -qxF -- "$name" "$RESULT_UNITS_FILE" && continue
    command grep -qxF -- "$name" "$RESULT_TOKENS_FILE" || continue
    FINDINGS=$((FINDINGS + 1))
    emit "split-fanin-dangling" \
        "unit '${name}' is still referenced after the split but is no longer defined in any result file — its callers dangle" \
        "HIGH"
done <"$ORIG_UNITS_FILE"

# --- 4. markdown reachability ------------------------------------------------
if [ "$ORIG_LANG" = "md" ]; then
    UNREACHABLE=""
    UNREACH_N=0
    # Link targets in the POST-split original — the pointers that make moved
    # content reachable. Only files content moved INTO count as destinations: a
    # file linking to itself proves nothing.
    LINKS="$(LC_ALL=C command grep -oE '\]\([^)]+\)' "$POST_ORIGINAL" 2>/dev/null | command sed 's/^](//; s/)$//' || true)"

    # PER-HEADING DESTINATIONS, not a flattened "does any link point at any
    # moved-into file?" flag. Reachability is a claim about ONE heading and the
    # ONE file it landed in, so it is resolved per heading: which file received
    # it, and does the post-split original link to THAT file?
    #
    # The flattened form passes a split where heading A moved into a linked file
    # and heading B moved into a file nothing points at — A's link vouches for B
    # and the tool reports `split-verified` while B is genuinely unreachable. It
    # needed TWO destination files to appear, which no fixture had, and BOTH
    # impls had it, so parity was green on a shared defect.
    #
    # `heading<TAB>destination-basename` rows; results[0] is the post-split
    # original itself and is excluded — a file linking to itself proves nothing.
    HEADING_DEST_FILE="$(command mktemp)"
    first=1
    for f in "${RESULTS[@]}"; do
        if [ "$first" = "1" ]; then
            first=0
            continue
        fi
        case "$(lang_of "$f")" in
            md)
                md_headings "$f" | while IFS= read -r h; do
                    [ -n "$h" ] && command printf '%s\t%s\n' "$h" "${f##*/}"
                done >>"$HEADING_DEST_FILE"
                ;;
        esac
    done

    SURVIVING="$(md_headings "$POST_ORIGINAL")"
    while IFS= read -r heading; do
        [ -n "$heading" ] || continue
        command printf '%s\n' "$SURVIVING" | command grep -qxF -- "$heading" && continue
        # Which file received this heading? The FIRST match wins, mirroring
        # python's setdefault.
        dest="$(LC_ALL=C command awk -F'\t' -v h="$heading" '$1 == h { print $2; exit }' "$HEADING_DEST_FILE" 2>/dev/null || true)"
        if [ -z "$dest" ]; then
            # Present in no result file at all — lost outright.
            UNREACH_N=$((UNREACH_N + 1))
            if [ -z "$UNREACHABLE" ]; then
                UNREACHABLE="$heading"
            elif [ "$UNREACH_N" -le 3 ]; then
                UNREACHABLE="${UNREACHABLE}; ${heading}"
            fi
            continue
        fi
        anchor="$(command printf '%s' "$heading" | LC_ALL=C command tr '[:upper:]' '[:lower:]' |
            LC_ALL=C command sed 's/[^a-z0-9 -]//g; s/^[ ]*//; s/[ ]*$//; s/ /-/g')"
        # Reachable only via a link to ITS OWN destination, or its anchor.
        if command printf '%s\n' "$LINKS" | command grep -qF -- "$dest"; then
            continue
        fi
        if command printf '%s\n' "$LINKS" | command grep -qF -- "#${anchor}"; then
            continue
        fi
        UNREACH_N=$((UNREACH_N + 1))
        if [ -z "$UNREACHABLE" ]; then
            UNREACHABLE="$heading"
        elif [ "$UNREACH_N" -le 3 ]; then
            UNREACHABLE="${UNREACHABLE}; ${heading}"
        fi
    done <<EOF
$(md_headings "$ORIGINAL")
EOF
    command rm -f "$HEADING_DEST_FILE"

    if [ "$UNREACH_N" -gt 0 ]; then
        FINDINGS=$((FINDINGS + 1))
        more=""
        [ "$UNREACH_N" -gt 3 ] && more=" (+$((UNREACH_N - 3)) more)"
        emit "split-heading-unreachable" \
            "${UNREACH_N} heading(s) moved out of the original with no link left behind: ${UNREACHABLE}${more} — progressive disclosure requires a one-line pointer, or the content is lost" \
            "HIGH"
    fi
fi

if [ "$FINDINGS" -eq 0 ]; then
    unit_total="$(command wc -l <"$ORIG_UNITS_FILE" | command tr -d ' ')"
    emit "split-verified" \
        "split is non-lossy: ${ORIG_PROD} -> ${RESULT_PROD} production LOC across ${RESULT_COUNT} file(s), all ${unit_total} top-level unit(s) preserved, no dangling references" \
        "HIGH"
fi
