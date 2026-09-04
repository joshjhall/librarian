#!/usr/bin/env bash
# is_test_file basename anchoring, across every copy (#866).
#
# `is_test_file` decides whether a path is a test file. Every copy carries one
# invariant, and until this gate NOTHING enforced it across copies:
#
#     Directory arms match the FULL PATH  (they are meant to cross `/`).
#     Name arms match the BASENAME        (so a directory can never satisfy one).
#
# Violating it is not cosmetic. In a bash `case` glob `*` crosses `/`, so a name
# arm spelled `*/test_*.*` also matches a DIRECTORY named `test_helpers/` — and
# in a scanner that skips test files wholesale, that silences every finding for
# real source beneath that directory. The scan still exits 0, so the tree reads
# clean.
#
# The class has now been fixed TWICE, by a human reading the code both times:
#
#   - #568 — check-code-health/patterns.sh. Split into two `case` blocks.
#   - #836 — check-lifecycle/patterns.sh, carrying the identical pre-#568 form.
#            Two years of drift; found while planning something else.
#
# WHY NO EXISTING GATE COVERS IT. validate-shared-scanner-sync.sh pins
# byte-identity, but only for the declared SHARED_PAIRS (currently the
# check-code-health <-> pre-review-gates pair). #836 deliberately DECLINED to
# enroll check-lifecycle's copy, and that decision stands: that copy gates the
# WHOLE per-file scan while the pinned pair gates ONE category, so byte-identity
# between differently-purposed copies is the wrong contract. Declining was right,
# and it is exactly what left ANCHORING — the invariant the copies genuinely do
# share — enforced by nothing. A behavioral fixture covers one copy at a time;
# per-copy fixtures are 10x the work and each proves only its own site. So this
# gate reads the SOURCE and sweeps the class instead.
#
# NOT IN SCOPE, deliberately:
#   - Enrolling any copy in SHARED_PAIRS. #836 settled that, and this gate exists
#     because that decision was correct.
#   - WHICH names count as tests (hyphenated `test-*.sh`, `Tests/`). That is #833,
#     a question about the ARMS; this gate is only about what the arms are
#     matched AGAINST.
#
# DISCOVERY IS FILESYSTEM-DRIVEN, never a hardcoded list — an 11th copy is
# covered the moment it lands (#866 AC 4). It also keys the exemption off the
# code rather than a roster: a file that only IMPORTS or CALLS is_test_file
# defines nothing, so it can never be a defect site and can never be forgotten
# either. Measured 2026-09-03: 10 definitions — 3 bash `case`, 3 awk, 4 Python.
#
# KNOWN LIMITS, recorded rather than left for the next reader to rediscover
# (raised as deferrable in review; no current copy triggers either):
#
#   - The line-joining helpers count brackets and trailing backslashes as plain
#     text, with no knowledge of string literals. A future body whose glob
#     literal carried an unbalanced bracket, or a `#` inside a string, could
#     desync the fold. Keeping is_test_file bodies free of such literals is the
#     cheaper half of this bargain than teaching the gate to lex three languages.
#   - The basename check trusts the NAME of the variable a basename was assigned
#     to, not its provenance: `base = something_else.rsplit("/", 1)[-1]` would
#     register as anchored. Tightening it to require the slice come from the
#     function's own parameter is possible in all three languages and is left
#     undone deliberately — it is a pre-existing shape shared by every checker
#     here, not something one language regressed.
#
# Both would surface as a FALSE NEGATIVE (a defective copy reading COVERED),
# which is the failure mode this file exists to prevent — so they are limits to
# revisit if a copy ever comes near them, not settled design.
#
# Pure bash + coreutils + python3. No network.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "is_test_file basename anchoring (#866)"

# This gate parses three languages' function bodies with python3 (well beyond a
# portable grep). A missing runtime is an UNAVAILABLE LINTER, so it exits the
# reserved 77 sentinel rather than 0 — run-all.sh renders 77 as
# "[SKIP] ... did not run", because a silent skip is indistinguishable from a
# pass and is how a gate sits inert unnoticed (#538/#571).
if ! command -v python3 >/dev/null 2>&1; then
    skip_test "python3 not available (is_test_file anchoring not checked)"
    generate_report
    exit 77
fi

# scan_root ROOT — emit the anchoring report for the plugins/ tree under ROOT.
# Parameterized on ROOT (rather than hardcoding REPO_ROOT) so the self-test below
# can run THIS EXACT parser against synthetic fixtures. One copy of the program,
# two callers: a second transcription would be free to drift from the one that
# actually gates the repo.
scan_root() {
    # Delimiter is PYEOF, not PY: inside `$( )` bash ends a heredoc at any line
    # STARTING WITH the delimiter, so a `PY_DEF = ...` line below would close a
    # `PY` heredoc mid-program (verified — it is a parse error, not silent).
    command python3 - "$1" <<'PYEOF'
import os
import re
import sys

ROOT = sys.argv[1]
PLUGINS = os.path.join(ROOT, "plugins")

# Definition openers, one per language. These three regexes ARE the discovery —
# if one stops matching, its language vanishes from the report and the
# language-coverage guard below fails rather than the gate passing vacuously.
BASH_DEF = re.compile(r"^is_test_file\(\)\s*\{")
AWK_DEF = re.compile(r"^\s*function\s+is_test_file\s*\(")
PY_DEF = re.compile(r"^def\s+is_test_file\s*\(")


def body_from(lines, start, closer):
    """Lines of a definition body, from the opener to its closing delimiter.

    `closer` is a predicate on (line, index). Brace languages close on a line
    whose indentation matches the opener's and which is just `}`; Python closes
    on the next top-level `def`/blank-separated dedent."""
    out = []
    for i in range(start + 1, len(lines)):
        if closer(lines[i]):
            break
        out.append((i + 1, lines[i]))
    return out


def join_continuations(body):
    """Fold `\\`-continued physical lines into one logical line.

    A `case` arm may spread its pattern list over several lines, and EVERY real
    is_test_file copy already writes its directory arms that way. A line-at-a-
    time scanner sees only the fragment carrying the closing `)`, so a
    path-crossing pattern parked on an earlier fragment is silently dropped and
    the copy reads COVERED — a false negative in precisely the gate's own
    subject matter. Join first, then match (the repo's "line scanner is blind to
    wrapped calls" lesson).

    The reported line number stays that of the FIRST physical line, so a defect
    points at where the arm begins."""
    out = []
    buf = None
    first = None
    for lineno, line in body:
        stripped = line.rstrip()
        if first is None:
            first = lineno
        piece = stripped[:-1] if stripped.endswith("\\") else stripped
        buf = piece if buf is None else buf + " " + piece.lstrip()
        if not stripped.endswith("\\"):
            out.append((first, buf))
            buf = None
            first = None
    if buf is not None:
        out.append((first, buf))
    return out


# The triple-quote delimiters, built with chr() so this program can name them
# without embedding a sequence that would terminate its own heredoc-borne
# source. Read at call time, but defined here so the reader meets them first.
TRIPLE_D = chr(34) * 3
TRIPLE_S = chr(39) * 3


def join_open_parens(body):
    """Flatten a Python body so a call wrapped across lines matches as one.

    Same purpose as join_continuations, different trigger: Python continues a
    line implicitly while brackets are open, so the depth of unclosed brackets
    decides where a logical line ends.

    DOCSTRINGS ARE SKIPPED FIRST, and that is not a nicety. Every real copy's
    docstring carries prose brackets — an unbalanced `(#851).`, a literal
    `#[cfg(test)]` — which are not code and drove the depth counter astray, so
    the real `_fnmatch(base, pat)` lines were folded away and both loc_engine
    copies reported UNKNOWN. The UNKNOWN guard is what caught it; the fix is to
    feed this only code."""
    out = []
    buf = None
    first = None
    depth = 0
    in_doc = False
    for lineno, line in body:
        stripped = line.strip()
        # Triple-quoted regions are prose, not code, and must be dropped BEFORE
        # any bracket counting. Note an even tick count is not "no docstring":
        # a one-line \"\"\"doc\"\"\" has TWO delimiters and still must be skipped,
        # while an unterminated opener has one and must set the state. Counting
        # parity alone got this wrong and fused the whole body into one line.
        ticks = stripped.count(TRIPLE_D) + stripped.count(TRIPLE_S)
        if in_doc:
            if ticks >= 1:
                in_doc = False
            continue
        if ticks >= 2:
            continue  # a complete one-line docstring
        if ticks == 1:
            in_doc = True
            continue
        code = line.split("#", 1)[0]
        piece = stripped if buf is not None else line
        buf = piece if buf is None else buf + " " + piece
        if first is None:
            first = lineno
        depth += code.count("(") + code.count("[") - code.count(")") - code.count("]")
        if depth <= 0:
            out.append((first, buf))
            buf = None
            first = None
            depth = 0
    if buf is not None:
        out.append((first, buf))
    return out


def bash_body(lines, start):
    indent = len(lines[start]) - len(lines[start].lstrip())
    return body_from(lines, start, lambda ln: ln.rstrip() == " " * indent + "}")


def awk_body(lines, start):
    indent = len(lines[start]) - len(lines[start].lstrip())
    return body_from(lines, start, lambda ln: ln.rstrip() == " " * indent + "}")


def py_body(lines, start):
    return body_from(lines, start, lambda ln: bool(ln.strip()) and not ln[:1].isspace())


CASE_OPEN = re.compile(r'^\s*case\s+(\S+)\s+in\b')
CASE_ARM = re.compile(r"^\s*([^\s;(][^;)]*?)\)\s")
# A basename slice in any of the spellings the copies use: "${1##*/}",
# "${path##*/}", `base=${p##*/}`. What matters is the `##*/` strip, not the name.
BASENAME_SLICE = re.compile(r"\$\{[A-Za-z_0-9]+##\*/\}")

sites = []


def add(path, lang, lineno, verdict, detail=""):
    sites.append((os.path.relpath(path, ROOT), lang, lineno, verdict, detail))


def check_bash(path, lines, start):
    """Name arms must sit under a BASENAME case subject; the raw-path case may
    carry directory arms only. The #568/#836 defect is precisely a name arm
    (`*/test_*.*`) living in the raw-path case, where its `*` crosses `/`."""
    body = join_continuations(bash_body(lines, start))
    subject = None
    saw_name_arm = False
    bad = []
    for lineno, line in body:
        m = CASE_OPEN.match(line)
        if m:
            subject = m.group(1)
            continue
        if subject is None:
            continue
        a = CASE_ARM.match(line)
        if not a:
            continue
        pats = [p.strip() for p in a.group(1).split("|")]
        # A directory arm is one that ends in `/*` — `tests/*`, `*/tests/*`.
        # Anything else in this predicate is a NAME arm.
        if all(p.endswith("/*") for p in pats):
            continue
        saw_name_arm = True
        anchored = bool(BASENAME_SLICE.search(subject))
        crossing = [p for p in pats if p.startswith("*/")]
        if not anchored:
            bad.append("L%d: name arm under raw subject %s -> %s"
                       % (lineno, subject, " | ".join(pats)))
        elif crossing:
            bad.append("L%d: path-crossing pattern in basename case -> %s"
                       % (lineno, " | ".join(crossing)))
    if bad:
        add(path, "bash", start + 1, "DEFECT", "; ".join(bad))
    elif not saw_name_arm:
        add(path, "bash", start + 1, "UNKNOWN", "no name arm recognized in body")
    else:
        add(path, "bash", start + 1, "COVERED")


AWK_SUB_BASENAME = re.compile(r'sub\(\s*/\^\.\*\\?/\s*/\s*,\s*""\s*,\s*([A-Za-z_][A-Za-z_0-9]*)\s*\)')
AWK_MATCH = re.compile(r"([A-Za-z_][A-Za-z_0-9]*)\s*~\s*/")


def check_awk(path, lines, start):
    """Name regexes must test the variable produced by `sub(/^.*\\//, "", base)`,
    never the raw parameter. A `~ /.../` against the parameter is the awk
    spelling of the same path-crossing defect."""
    body = join_continuations(awk_body(lines, start))
    param = re.search(r"function\s+is_test_file\s*\(\s*([A-Za-z_][A-Za-z_0-9]*)",
                      lines[start]).group(1)
    basevar = None
    saw_name_arm = False
    bad = []
    for lineno, line in body:
        s = AWK_SUB_BASENAME.search(line)
        if s:
            basevar = s.group(1)
            continue
        for m in AWK_MATCH.finditer(line):
            var = m.group(1)
            saw_name_arm = True
            if var == param:
                bad.append("L%d: name regex matched against raw parameter %s"
                           % (lineno, param))
            elif basevar is None or var != basevar:
                bad.append("L%d: name regex matched against %s, not a `sub(/^.*\\//)` basename"
                           % (lineno, var))
    if bad:
        add(path, "awk", start + 1, "DEFECT", "; ".join(bad))
    elif not saw_name_arm:
        add(path, "awk", start + 1, "UNKNOWN", "no name regex recognized in body")
    else:
        add(path, "awk", start + 1, "COVERED")


PY_RSPLIT = re.compile(r"([A-Za-z_][A-Za-z_0-9]*)\s*=\s*([A-Za-z_][A-Za-z_0-9]*)\.rsplit\(\s*[\"']/[\"']\s*,\s*1\s*\)\s*\[\s*-1\s*\]")
# Matches fnmatch / fnmatchcase AND the aliased `_fnmatch` the loc_engine
# copies import as. A leading-underscore alias is why this cannot use `\b`:
# there is no word boundary between `_` and `f`, so `\bfnmatch` silently
# missed both loc_engine copies — the UNKNOWN guard is what surfaced it.
PY_FNMATCH = re.compile(r"(?<![A-Za-z0-9])_?fnmatch[A-Za-z_0-9]*\(\s*([A-Za-z_][A-Za-z_0-9]*)\s*,")


def check_py(path, lines, start):
    """fnmatch name patterns must be applied to the `rsplit("/", 1)[-1]`
    basename, not to the full path.

    Python wraps on an OPEN PAREN, not on a backslash, so join_continuations
    (which the bash/awk readers use) does not help here: a formatter is free to
    emit a call whose first argument sits on the NEXT line, where a
    line-at-a-time scan sees only a bare `fnmatch(`. Measured: that
    spelling reported COVERED while passing the full path, the same class of
    false negative the backslash-continuation bug was. The body is flattened to one
    logical line before matching, exactly as the brace languages are."""
    body = join_open_parens(py_body(lines, start))
    param = re.search(r"def\s+is_test_file\s*\(\s*([A-Za-z_][A-Za-z_0-9]*)",
                      lines[start]).group(1)
    basevar = None
    saw_name_arm = False
    bad = []
    for lineno, line in body:
        code = line.split("#", 1)[0]
        r = PY_RSPLIT.search(code)
        if r:
            basevar = r.group(1)
        for m in PY_FNMATCH.finditer(code):
            var = m.group(1)
            saw_name_arm = True
            if var == param:
                bad.append("L%d: fnmatch applied to full path %s" % (lineno, param))
            elif basevar is None or var != basevar:
                bad.append("L%d: fnmatch applied to %s, not an rsplit basename"
                           % (lineno, var))
    if bad:
        add(path, "python", start + 1, "DEFECT", "; ".join(bad))
    elif not saw_name_arm:
        add(path, "python", start + 1, "UNKNOWN", "no fnmatch name arm recognized in body")
    else:
        add(path, "python", start + 1, "COVERED")


for dirpath, _dirs, files in os.walk(PLUGINS):
    for name in sorted(files):
        if not (name.endswith(".sh") or name.endswith(".py")):
            continue
        path = os.path.join(dirpath, name)
        lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
        for i, line in enumerate(lines):
            # A .sh may carry BOTH a bash definition and an awk one (the awk
            # copies live in heredoc'd AWKLIB regions), so all three openers are
            # tried against every line rather than dispatching on extension.
            if BASH_DEF.match(line):
                check_bash(path, lines, i)
            elif AWK_DEF.match(line):
                check_awk(path, lines, i)
            elif PY_DEF.match(line):
                check_py(path, lines, i)

for rel, lang, lineno, verdict, detail in sorted(sites):
    print("%s\t%s\t%s:%d\t%s" % (verdict, lang, rel, lineno, detail))
print("COUNT\t%d" % len(sites))
print("LANGS\t%s" % " ".join(sorted(set(s[1] for s in sites))))
PYEOF
}

ANCHOR_REPORT="$(scan_root "$REPO_ROOT")"

rows() { command printf '%s\n' "$ANCHOR_REPORT" | command grep "^$1	" || true; }
field() { command printf '%s\n' "$ANCHOR_REPORT" | command grep "^$1	" | command cut -f2- || true; }

# --- Vacuity guards ---------------------------------------------------------
# These exist so a broken parser cannot read as a clean tree. Without them, a
# typo in any discovery regex reports zero defects — identical output to a
# perfectly anchored repo.

# The walk found the copies. Measured 2026-09-03: 10 definitions. The floor is
# the count, not an exact match, so an 11th copy landing is covered (AC 4)
# rather than failing this guard.
test_definitions_are_discovered() {
    local count
    count="$(field COUNT)"
    assert_not_empty "$count" "the scan reported a definition count"
    if [ "${count:-0}" -lt 10 ]; then
        _fail "far fewer is_test_file definitions found than expected" \
            "10 definitions were measured across plugins/ (3 bash, 3 awk, 4 python); a count this low means a discovery regex stopped matching, not that the copies are gone." \
            "count: $count"
    fi
}

# All three languages are represented. A regex typo that killed only the awk
# opener would leave the count guard above satisfied by the other two.
test_all_three_languages_are_covered() {
    local langs
    langs="$(field LANGS)"
    assert_not_empty "$langs" "the scan reported which languages it found"
    local lang
    for lang in awk bash python; do
        case " $langs " in
            *" $lang "*) : ;;
            *) _fail "no $lang is_test_file definition was discovered" \
                "Each language has its own opener regex and its own anchoring rule; a missing language means that rule is enforcing nothing." \
                "discovered: $langs" ;;
        esac
    done
}

# A copy whose name arms the parser could not classify is INVESTIGATED, not
# assumed covered (#866 AC 3). This is the guard that makes a novel spelling —
# a fourth language, a rewritten body — fail loudly instead of silently
# dropping out of enforcement.
test_no_definition_is_unclassifiable() {
    local unknown
    unknown="$(rows UNKNOWN)"
    if [ -n "$unknown" ]; then
        _fail "an is_test_file definition exposed no recognizable name arm" \
            "The gate could not find the arms it is meant to anchor, so this copy is enforcing nothing. Teach the parser this spelling — do not relax the assertion." \
            "$unknown"
    fi
}

# --- THE assertion ----------------------------------------------------------
test_every_name_arm_is_basename_anchored() {
    local defects
    defects="$(rows DEFECT)"
    if [ -n "$defects" ]; then
        _fail "an is_test_file name arm is matched against the full path" \
            "A name arm that crosses '/' also matches a DIRECTORY (test_helpers/), so every scanner skipping test files silences real source beneath it — silent, exit 0 (#568/#836). Match name arms against the basename: bash \`case \"\${1##*/}\"\`, awk \`sub(/^.*\\//, \"\", base)\`, python \`path.rsplit(\"/\", 1)[-1]\`." \
            "$defects"
    fi
}

# --- Parser self-test (#866 review, HIGH) -----------------------------------
# The three guards above prove the parser SEES the real copies. They cannot prove
# it still has TEETH on a shape the repo does not currently contain — and it did
# not: the first version of this gate matched a `case` arm only on the physical
# line carrying the closing `)`, so a path-crossing pattern parked on a
# `\`-continued line above it was dropped from the arm and the copy read COVERED.
# Every real is_test_file writes its directory arms exactly that way, so a future
# name-arm edit in the house style would have walked straight through this gate.
#
# That is the failure this file exists to prevent, reproduced inside the file
# itself. So the shape is pinned here as a fixture rather than left to the next
# reviewer: the scanner is run over a synthetic plugins/ tree whose only copy is
# defective, and is required to SAY SO. It runs the same scan_root as the real
# scan — a transcribed second copy could drift from the one that gates the repo.
test_parser_catches_a_continuation_line_defect() {
    local sandbox
    sandbox="$(command mktemp -d 2>/dev/null)" || {
        skip_test "mktemp unavailable (parser self-test not run)"
        return 0
    }
    # shellcheck disable=SC2064  # expand $sandbox now, at trap-registration time
    trap "command rm -rf '$sandbox'" RETURN
    command mkdir -p "$sandbox/plugins/probe"
    # The DIVERGENT input: `*/test_*.*` is a name arm under a basename subject,
    # and it sits on a continuation line. A line-at-a-time parser sees only
    # `test_*.*` on the closing line and reports COVERED; a joining parser sees
    # both and reports DEFECT. Old and new disagree here — that is the point.
    command cat >"$sandbox/plugins/probe/patterns.sh" <<'FIXTURE'
is_test_file() {
    case "$1" in
        tests/* | */tests/*) return 0 ;;
    esac
    case "${1##*/}" in
        */test_*.* | \
            test_*.*) return 0 ;;
    esac
    return 1
}
FIXTURE
    local report want
    # Require the LINE too, not just the verdict: join_continuations promises the
    # reported line is the arm's FIRST physical line (where `*/test_*.*` sits,
    # not where the `)` closes). Matching only *DEFECT* would let a
    # line-attribution regression pass silently, and a defect pointing at the
    # wrong line is most of the value of reporting one at all.
    #
    # The expected line is DERIVED from the fixture, never hardcoded. A literal
    # would turn any future edit of the fixture above into a failure claiming the
    # parser regressed — a wrong diagnosis, and the kind that gets a test deleted
    # rather than read.
    want="$(command grep -n '\*/test_\*' "$sandbox/plugins/probe/patterns.sh" |
        command head -1 | command cut -d: -f1)"
    if [ -z "$want" ]; then
        _fail "the fixture no longer contains the path-crossing arm it is built around" \
            "This test derives its expected line from the fixture; an edit that removed the arm makes it vacuous." \
            "fixture: $sandbox/plugins/probe/patterns.sh"
        return 0
    fi
    report="$(scan_root "$sandbox" 2>/dev/null || true)"
    case "$report" in
        *DEFECT*"L${want}:"*)
            :
            ;;
        *DEFECT*)
            _fail "the defect was flagged, but attributed to the wrong line" \
                "join_continuations reports the arm's FIRST physical line (L${want} in this fixture). A different line means the attribution regressed." \
                "report: $report"
            ;;
        *)
            _fail "the parser did not flag a path-crossing arm on a continuation line" \
                "A \`case\` arm may spread over several lines, and every real copy already writes its directory arms that way. Matching only the line that carries the closing \`)\` drops the earlier patterns, so the defect this gate exists to catch reads as COVERED. Join continuations before matching." \
                "report: ${report:-(empty)}"
            ;;
    esac
}

# The Python twin of the guard above (#866 review cycle 2, found while probing
# the cycle-1 fix). Python wraps on an OPEN PAREN rather than a backslash, so
# join_continuations does nothing for it: measured, `fnmatch(` with its first
# argument on the next line reported COVERED while passing the full path — the
# same silent false negative in a different language. Both arms are pinned: the
# wrapped-DEFECTIVE form must be flagged (teeth) and the wrapped-CORRECT form
# must not (narrowness), since a parser that flagged everything would pass a
# teeth-only test while being useless.
test_parser_reads_a_wrapped_python_call() {
    local sandbox report
    sandbox="$(command mktemp -d 2>/dev/null)" || {
        skip_test "mktemp unavailable (python wrapped-call self-test not run)"
        return 0
    }
    # shellcheck disable=SC2064  # expand $sandbox now, at trap-registration time
    trap "command rm -rf '$sandbox'" RETURN
    command mkdir -p "$sandbox/plugins/probe"

    # Teeth. The docstring deliberately carries the prose brackets every real
    # copy has — an unbalanced `(#851)`, a literal `#[cfg(test)]` — because
    # counting those as code is what broke the first attempt at this parser.
    command cat >"$sandbox/plugins/probe/wrapped.py" <<'FIXTURE_BAD'
from fnmatch import fnmatch


def is_test_file(path: str) -> bool:
    """Prose brackets: (#851) and #[cfg(test)]."""
    base = path.rsplit("/", 1)[-1]
    if fnmatch(
        path, "test_*.*"
    ):
        return True
    return False
FIXTURE_BAD
    report="$(scan_root "$sandbox" 2>/dev/null || true)"
    case "$report" in
        *DEFECT*) : ;;
        *)
            _fail "the parser did not flag a wrapped fnmatch() applied to the full path" \
                "Python continues a line on an open bracket, so a formatter may put the first argument on the next line. Reading one physical line at a time misses it and the copy reads COVERED." \
                "report: ${report:-(empty)}"
            ;;
    esac

    # Narrowness. Same wrapping, correct argument — must NOT be flagged.
    command cat >"$sandbox/plugins/probe/wrapped.py" <<'FIXTURE_OK'
from fnmatch import fnmatch


def is_test_file(path: str) -> bool:
    """Prose brackets: (#851) and #[cfg(test)]."""
    base = path.rsplit("/", 1)[-1]
    if fnmatch(
        base, "test_*.*"
    ):
        return True
    return False
FIXTURE_OK
    report="$(scan_root "$sandbox" 2>/dev/null || true)"
    case "$report" in
        *DEFECT* | *UNKNOWN*)
            _fail "the parser flagged a correctly basename-anchored wrapped call" \
                "A gate that reports every wrapped call would pass a teeth-only test while being useless. The basename-anchored form must read COVERED." \
                "report: ${report:-(empty)}"
            ;;
        *) : ;;
    esac
}

# The awk twin of the guard above (#866 review cycle 2). check_awk calls the
# SAME join_continuations, so it carries the same exposure — but a shared helper
# is not shared coverage: an awk-specific regression (in how a fragment is
# stripped or rejoined) would be caught here only by luck, since whether a real
# plugins/ awk copy happens to contain a continuation-line arm is not something
# this gate controls. So the shape is synthesized rather than hoped for.
test_parser_catches_an_awk_continuation_defect() {
    local sandbox report
    sandbox="$(command mktemp -d 2>/dev/null)" || {
        skip_test "mktemp unavailable (awk continuation self-test not run)"
        return 0
    }
    # shellcheck disable=SC2064  # expand $sandbox now, at trap-registration time
    trap "command rm -rf '$sandbox'" RETURN
    command mkdir -p "$sandbox/plugins/probe"
    # `p` is the raw parameter, and the name regex testing it is parked on a
    # continuation line. Unjoined, the scanner sees neither fragment as a match.
    command cat >"$sandbox/plugins/probe/awkprobe.sh" <<'FIXTURE_AWK'
read_awklib() {
    command cat <<'AWKLIB'
    function is_test_file(p,   base, i, seg, segs, n) {
        n = split("tests test", segs, " ")
        for (i = 1; i <= n; i++) {
            if (index(p, segs[i] "/") == 1) return 1
        }
        if (p ~ \
            /^test_[^\/]*\.[^\/]*$/) return 1
        return 0
    }
AWKLIB
}
FIXTURE_AWK
    report="$(scan_root "$sandbox" 2>/dev/null || true)"
    case "$report" in
        *DEFECT*)
            :
            ;;
        *)
            _fail "the parser did not flag an awk name regex split across a continuation line" \
                "check_awk shares join_continuations with check_bash, but sharing a helper is not sharing coverage — an awk-side regression must fail an awk fixture." \
                "report: ${report:-(empty)}"
            ;;
    esac
}

run_test test_definitions_are_discovered "Every is_test_file definition is discovered from the filesystem"
run_test test_all_three_languages_are_covered "All three languages (bash, awk, python) are represented"
run_test test_no_definition_is_unclassifiable "No definition's name arms are unclassifiable (investigate, never assume)"
run_test test_parser_catches_a_continuation_line_defect "The parser has teeth on a multi-line (continuation) case arm"
run_test test_parser_catches_an_awk_continuation_defect "The parser has teeth on a multi-line (continuation) awk name regex"
run_test test_parser_reads_a_wrapped_python_call "The parser has teeth (and narrowness) on a wrapped Python call"
run_test test_every_name_arm_is_basename_anchored "Every is_test_file name arm is basename-anchored"

generate_report
