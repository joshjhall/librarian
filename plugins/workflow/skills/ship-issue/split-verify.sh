#!/usr/bin/env bash
# ship-issue — non-lossy split verification (portable bash fallback)
#
# A reviewer that suggests a decomposition is cheap to ignore; a reviewer that
# suggests one AND can PROVE the split lost nothing is cheap to accept. This tool
# is that proof (issue #695, AC8). Five mechanical checks:
#
#   1. LOC CONSERVATION  — production LOC across results ~= original, modulo new
#      import/mod/__init__ boilerplate (SPLIT_LOC_TOLERANCE, default 40).
#   2. UNIT PRESERVATION — every top-level unit present before is present after.
#   3. FAN-IN RESOLUTION — a unit referenced before is still defined-or-referenced
#      somewhere after, so no call site dangles.
#   4. MARKDOWN REACHABILITY — every heading that MOVED out is reachable by a link
#      from the post-split original. A split that moves prose out but leaves no
#      link has LOST content, not decomposed it.
#   5. MEMORY-BUNDLE INDEX LINE (#729) — a concept extracted from a memory bundle
#      is named by an index. This turns the scanner's "AND add its index line"
#      from advisory prose into a checkable rule: half-following it produces a
#      memory that is written but never recallable (#697), silently.
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
#   category is one of: split-loc-drift, split-unit-lost, split-fanin-dangling,
#   split-heading-unreachable, split-memory-orphan, split-verified
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
#
# CASE-INSENSITIVE, matching lang_of() in split-verify.py, which lowercases
# before the EXT_LANG lookup (#754). A literal `case` here classified `Upper.PY`
# as no-language under bash while python called it py, so the two runtimes
# disagreed about whether a split preserved the original's language at all.
# Same rule as is_decl_file (#726) — the same target must decide alike in every
# spelling. Bracket classes keep it fork-free and bash-3.2 clean (`${1,,}` is
# bash 4; this tree targets macOS's stock 3.2).
lang_of() {
    case "$1" in
        *.[Pp][Yy]) echo "py" ;;
        *.[Jj][Ss] | *.[Jj][Ss][Xx] | *.[Mm][Jj][Ss] | *.[Cc][Jj][Ss]) echo "js" ;;
        *.[Tt][Ss] | *.[Tt][Ss][Xx]) echo "ts" ;;
        *.[Rr][Ss]) echo "rs" ;;
        *.[Gg][Oo]) echo "go" ;;
        *.[Ss][Hh] | *.[Bb][Aa][Ss][Hh]) echo "sh" ;;
        *.[Mm][Dd] | *.[Mm][Aa][Rr][Kk][Dd][Oo][Ww][Nn]) echo "md" ;;
        *.[Ss][Ww][Ii][Ff][Tt]) echo "swift" ;;
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
        if (lang == "js") return line ~ /^((export[ \t]+)?(default[ \t]+)?(async[ \t]+)?(function|class|const|let|var)[ \t]+[A-Za-z_$][A-Za-z0-9_$]*|(describe|it|test|suite|context)[ \t]*\([ \t]*["\047`][A-Za-z_$][A-Za-z0-9_$]*)/
        if (lang == "ts") return line ~ /^((export[ \t]+)?(default[ \t]+)?(declare[ \t]+)?(async[ \t]+)?(const[ \t]+enum|abstract[ \t]+class|function|class|const|let|var|interface|type|enum|namespace|module)[ \t]+[A-Za-z_$][A-Za-z0-9_$]*|(describe|it|test|suite|context)[ \t]*\([ \t]*["\047`][A-Za-z_$][A-Za-z0-9_$]*)/
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
        else if (lang == "js") { if (s ~ /^(describe|it|test|suite|context)[ \t]*\(/) sub(/^(describe|it|test|suite|context)[ \t]*\([ \t]*["\047`]/, "", s); else sub(/^(export[ \t]+)?(default[ \t]+)?(async[ \t]+)?(function|class|const|let|var)[ \t]+/, "", s) }
        else if (lang == "ts") { if (s ~ /^(describe|it|test|suite|context)[ \t]*\(/) sub(/^(describe|it|test|suite|context)[ \t]*\([ \t]*["\047`]/, "", s); else sub(/^(export[ \t]+)?(default[ \t]+)?(declare[ \t]+)?(async[ \t]+)?(const[ \t]+enum|abstract[ \t]+class|function|class|const|let|var|interface|type|enum|namespace|module)[ \t]+/, "", s) }
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
    # is_test_file: a file whose TESTS ARE ITS CONTENT, by PATH convention alone
    # (#851). The awk half of is_test_file() in the .py primaries.
    #
    # NOT is_test_header above: that classifies a UNIT by its content, this
    # classifies a FILE by its path, and only the second decides whether the
    # classification SUBTRACTS from production LOC. In a separate-file ecosystem
    # (*.test.ts, test_*.py, *_test.go, tests/**) a test files test code IS its
    # production content, so subtracting it scored the file near zero and it
    # never appeared. The same-file conventions (rs cfg-test, py __name__, sh
    # banner) key off CONTENT and are untouched.
    #
    # Segment-anchored, so contest.py / latest.js / attestation.go are NOT
    # matched while tests/helper.py IS. Directory arms cross a slash on purpose;
    # the name arms are matched against the BASENAME so they cannot — without
    # that split a DIRECTORY named test_helpers/ would make real source under it
    # read as test code (#568).
    #
    # NB: no apostrophes in this region — the awk program is a single-quoted
    # shell string, so one would end it.
    function is_test_file(p,   base, i, seg, segs, n) {
        n = split("tests test __tests__ spec __pycache__", segs, " ")
        for (i = 1; i <= n; i++) {
            seg = segs[i]
            if (index(p, seg "/") == 1) return 1
            if (index(p, "/" seg "/") > 0) return 1
        }
        base = p
        sub(/^.*\//, "", base)
        if (base ~ /^test_[^\/]*\.[^\/]*$/) return 1
        if (base ~ /(_test|_spec|\.test|\.spec)\.[^\/]*$/) return 1
        return 0
    }
    # <<< shared:unit-segmenters-awk
AWKLIB
}

# production_loc FILE LANG — production LOC (total minus blank/comment/test).
production_loc() {
    # `-v path` (#851): is_test_file() decides whether test units SUBTRACT
    # from production LOC, and it keys off the PATH. Without it every file
    # would look like a non-test file here while sizing.sh saw the truth —
    # the two halves of one verification disagreeing, which is exactly what
    # the parity gate exists to catch.
    LC_ALL=C command awk -v lang="$2" -v path="$1" "$(awk_lib)"'
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
                # Column-zero guard (#727): both attribute patterns tolerate
                # indent, so an indented attribute inside a block would mark the
                # next TOP-LEVEL unit as test code. Must match the primaries or
                # this loop and production_loc() disagree.
                if (line !~ /^[ \t]/ && is_attr_test(line, lang)) { pending_test = 1; if (!is_unit_header(line, lang)) continue }
                if (!is_unit_header(line, lang)) continue
                if (unit_name(line, lang) == "") continue
                # See is_reserved_name: a keyword captured as a name means a
                # modifier was parsed as the unit keyword (#728). pending_test
                # MUST be cleared here — the dropped header is what the
                # attribute was marking, so leaving it set carries the mark onto
                # the NEXT genuine unit and counts a PRODUCTION unit as test.
                if (is_reserved_name(unit_name(line, lang), lang)) { pending_test = 0; continue }
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
            else if (lang == "rs" && L[i] ~ /^#\[cfg\(test\)\]/) hit = 1
            else if (lang == "sh" && L[i] ~ /^#[ \t]*-+[ \t]*tests?[ \t]*-+/) hit = 1
            # Bounded to the unit the marker INTRODUCES, not to EOF (#727) —
            # the same rule sizing.sh and the .py primaries apply. This loop
            # lives OUTSIDE the shared region, so the sync gate cannot see it:
            # it is the fourth sibling doing the identical LOC-exclusion job
            # ([[harden-one-knob-grep-every-sibling]]). Left unbounded, a
            # mid-file test module would exclude every production unit after it
            # and skew the LOC-conservation check either way.
            if (hit) {
                stop = total
                for (k = 1; k <= nu; k++) if (us[k] >= i) { stop = uend[k]; break }
                for (j = i; j <= stop; j++) tl[j] = 1
                break
            }
        }
        # tf (#851): a TEST FILE by path convention counts its test lines as
        # production — the same rule sizing.sh and the .py primaries apply, and
        # a divergence here surfaces as a parity failure. A test line still
        # falls through to the blank/comment tally when tf, or its blanks and
        # comments would be counted as code.
        tf = is_test_file(path)
        blank = 0; comment = 0; test_excluded = 0
        for (i = 1; i <= total; i++) {
            if (i in tl) { test_excluded++; if (!tf) continue }
            if (L[i] ~ /^[ \t]*$/) { blank++; continue }
            if (is_comment(L[i], lang)) { comment++; continue }
        }
        print total - blank - comment - (tf ? 0 : test_excluded)
    }
    ' "$1"
}

# unit_names FILE LANG — non-test top-level unit names, one per line.
unit_names() {
    [ -n "$2" ] && [ "$2" != "md" ] || return 0
    # `-v path` for is_test_file(), same reason as production_loc() above.
    LC_ALL=C command awk -v lang="$2" -v path="$1" "$(awk_lib)"'
    {
        # SECOND segmenter loop in this file — production_loc() above has its
        # own. Both must apply the same rules or the two halves of one
        # verification disagree about what a unit is. #728 updated this one to
        # match: table-driven attribute tests (was hardcoded to rs),
        # header-first ordering so a one-line `@Test func` still registers, and
        # the reserved-name filter so a keyword captured as a name never becomes
        # a phantom unit. Without the last one this loop counted 3 units where
        # production_loc() and the python port counted 2 — caught as a parity
        # failure ([[harden-one-knob-grep-every-sibling]]).
        is_hdr = is_unit_header($0, lang)
        # Column-zero guard (#727) — same rule as production_loc() above and the
        # .py primaries; a divergence here surfaces as a parity failure.
        if ($0 !~ /^[ \t]/ && is_attr_test($0, lang)) { pending = 1; if (!is_hdr) next }
        if (!is_hdr) next
        nm = unit_name($0, lang)
        if (nm == "") next
        # Clears `pending` for the same reason production_loc() does: the
        # dropped header is what the attribute was marking, so leaving it set
        # would carry the mark onto the next genuine unit.
        if (is_reserved_name(nm, lang)) { pending = 0; next }
        # `!tf` (#851): in a TEST FILE the suites ARE the units, so dropping
        # them would compare an empty name set against an empty one — LOC
        # conservation would flag a lost half while unit conservation reported
        # nothing missing. Both halves of one verification must agree about
        # what a unit is. Mirrors unit_names(lines, lang, test_file) in the
        # .py port.
        tf = is_test_file(path)
        if (pending) { pending = 0; if (!tf) next }
        else if (is_test_header($0, lang) && !tf) next
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

# ---- 5. memory-bundle index line (#729) ------------------------------------
# Mirrors the check-5 block in split-verify.py; see that comment for why the
# invariant needs to be mechanical rather than advisory prose (#697), and why
# whole-bundle orphan detection stays out of scope here. That whole-bundle pass
# now ships in check-okf-conformance (bundle_graph.py, #669); it audits the
# bundle as it stands, while this check judges one proposed split as it is made.
#
# Classified on POST_ORIGINAL, never on ORIGINAL: the latter is the PRE-split
# snapshot and is typically a temp path, which is never under the bundle root,
# so classifying it would make this check silently never fire.
#
# Bundle root normalization mirrors _bundle_root() — empty means classification
# is off, and every spelling of the same root must decide alike.
SV_BUNDLE_ROOT="${MEMORY_BUNDLE_ROOT-.claude/memory}"
while :; do
    case "$SV_BUNDLE_ROOT" in
        ./*) SV_BUNDLE_ROOT="${SV_BUNDLE_ROOT#./}" ;;
        */) SV_BUNDLE_ROOT="${SV_BUNDLE_ROOT%/}" ;;
        *) break ;;
    esac
done

# sv_bundle_kind PATH — "index", "concept", or empty. Mirrors bundle_kind().
sv_bundle_kind() {
    [ -n "$SV_BUNDLE_ROOT" ] || return 0
    case "$1" in
        "$SV_BUNDLE_ROOT"/*.md | */"$SV_BUNDLE_ROOT"/*.md) ;;
        *) return 0 ;;
    esac
    case "${1##*/}" in
        MEMORY.md | index.md | index-*) command printf 'index' ;;
        *) command printf 'concept' ;;
    esac
}

if [ "$(sv_bundle_kind "$POST_ORIGINAL")" = "concept" ]; then
    ORPHANS=""
    ORPHAN_N=0
    # Every index in the bundle, concatenated — the pointer line may live in any
    # of them (the root MEMORY.md or a topic sub-index).
    INDEX_TEXT=""
    if [ -d "$SV_BUNDLE_ROOT" ]; then
        for idx in "$SV_BUNDLE_ROOT"/MEMORY.md "$SV_BUNDLE_ROOT"/index.md "$SV_BUNDLE_ROOT"/index-*.md; do
            [ -f "$idx" ] || continue
            INDEX_TEXT="${INDEX_TEXT}
$(command cat "$idx")"
        done
    fi
    # RESULTS[0] is POST_ORIGINAL itself; only the files content moved INTO can
    # be orphaned by this split.
    sv_i=1
    while [ "$sv_i" -lt "${#RESULTS[@]}" ]; do
        sv_r="${RESULTS[$sv_i]}"
        sv_i=$((sv_i + 1))
        [ "$(sv_bundle_kind "$sv_r")" = "concept" ] || continue
        sv_base="${sv_r##*/}"
        command printf '%s\n' "$INDEX_TEXT" | command grep -qF -- "$sv_base" && continue
        ORPHAN_N=$((ORPHAN_N + 1))
        if [ -z "$ORPHANS" ]; then
            ORPHANS="$sv_base"
        elif [ "$ORPHAN_N" -le 3 ]; then
            ORPHANS="${ORPHANS}; ${sv_base}"
        fi
    done
    if [ "$ORPHAN_N" -gt 0 ]; then
        FINDINGS=$((FINDINGS + 1))
        more=""
        [ "$ORPHAN_N" -gt 3 ] && more=" (+$((ORPHAN_N - 3)) more)"
        emit "split-memory-orphan" \
            "${ORPHAN_N} extracted concept(s) with no index line: ${ORPHANS}${more} — an extracted concept absent from the index is written but never recallable; add its pointer line" \
            "HIGH"
    fi
fi

if [ "$FINDINGS" -eq 0 ]; then
    unit_total="$(command wc -l <"$ORIG_UNITS_FILE" | command tr -d ' ')"
    emit "split-verified" \
        "split is non-lossy: ${ORIG_PROD} -> ${RESULT_PROD} production LOC across ${RESULT_COUNT} file(s), all ${unit_total} top-level unit(s) preserved, no dangling references" \
        "HIGH"
fi
