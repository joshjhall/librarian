#!/usr/bin/env bash
# Scanner extension-dispatch case parity (#754).
#
# Every ported scanner dispatches on a file extension twice — once in the Python
# primary, once in the bash fallback — and the TSV contract only holds while the
# two agree about which language a path IS. The Python side lowercases the
# extension before its lookup; the bash side matches with a `case` glob, which is
# case-SENSITIVE unless spelled with bracket classes. #754 fixed every site, but
# fixing a site is not the same as keeping it fixed:
#
#   - The defect is SILENT. A reverted arm emits no error and no diff in exit
#     code; the scan just reports less on one runtime than the other.
#   - It is PER-ARM. Eight dispatch sites carry ~8 arms each, and a mutation
#     round showed arms fail independently — `split-verify.sh`'s `py` arm was
#     pinned by a fixture while its `ts` arm reverted green. Pinning all ~68 with
#     per-arm fixtures does not scale, and the fixture corpus can only cover the
#     languages it happens to contain.
#   - It SPREADS BY COPY. The idiom lives in three plugins; a new scanner is
#     written by copying a neighbour, and copying a pre-#754 neighbour
#     reintroduces the bug in a file no existing fixture scans.
#
# So this gate asserts the property STRUCTURALLY, over the source, instead of
# behaviorally over one corpus. It is the backstop the fixtures cannot be.
#
# THE RULE. A `case` arm whose patterns are ALL bare `*.<ext>` globs, and whose
# every extension is a known LANGUAGE key, is a language-dispatch arm and must be
# spelled with bracket classes. Three deliberate narrowings, each load-bearing:
#
#   1. BARE patterns only. `*/agents/*.md` and `"$ROOT"/*.md` are path-prefixed
#      CLASSIFICATION arms, not extension dispatch, and both impls match them
#      literally on purpose. A rule that caught them would flag ~40 correct lines
#      and be turned off.
#   2. PURE language arms only. `*.md | *.txt | *.json | ... ) continue ;;` is a
#      SKIP glob — it mixes language and non-language extensions, and its job is
#      to drop the file, not to name its language. Both impls keep these literal
#      and agree, so converting one would CREATE drift.
#   3. Exempt when the twin does NOT lowercase. check-okf-conformance is the
#      worked example: its patterns.py uses a literal `endswith(".md")`, so its
#      bash `*.md)` already agrees. Converting it alone would be the very
#      divergence this gate exists to prevent — which is why the rule keys off
#      the PYTHON side rather than assuming every scanner lowercases.
#
# Pure bash + coreutils + python3. No network.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "Scanner extension-dispatch case parity (#754)"

# This gate parses source with python3 (the arm grammar is beyond a portable
# grep). A missing runtime is an UNAVAILABLE LINTER, so it exits the reserved
# 77 sentinel rather than 0 — run-all.sh renders 77 as "[SKIP] ... did not run",
# because a silent skip is indistinguishable from a pass and is how a gate sits
# inert unnoticed (#538/#571).
if ! command -v python3 >/dev/null 2>&1; then
    skip_test "python3 not available (extension-dispatch parity not checked)"
    generate_report
    exit 77
fi

SCANNER_REPORT="$(
    command python3 - "$REPO_ROOT" <<'PY'
import os
import re
import sys

ROOT = sys.argv[1]
PLUGINS = os.path.join(ROOT, "plugins")

# The language keys, derived from the Python impls rather than hardcoded: any
# extension a `.lower()`-using scanner treats as a language. Deriving it means a
# newly supported language is covered the moment its Python arm lands, instead of
# waiting for someone to remember this list.
LANG = set()
for dirpath, _dirs, files in os.walk(PLUGINS):
    for name in files:
        if not name.endswith(".py"):
            continue
        src = open(os.path.join(dirpath, name), encoding="utf-8", errors="replace").read()
        if ".lower()" not in src:
            continue
        LANG.update(re.findall(r'ext\s*==\s*"([a-z0-9]+)"', src))
        for grp in re.findall(r"ext\s+in\s*\(([^)]*)\)", src):
            LANG.update(re.findall(r'"([a-z0-9]+)"', grp))
        LANG.update(re.findall(r'^\s*"([a-z0-9]+)"\s*:\s*"[a-z]+"', src, re.M))

ARM = re.compile(r"^\s*(\*\.[A-Za-z0-9\[\]]+(?:\s*\|\s*\*\.[A-Za-z0-9\[\]]+)*)\)")
BRACKET = re.compile(r"\[([A-Za-z])[A-Za-z]\]")


def ext_of(pattern):
    """The lower-case extension a `*.ext` pattern selects, bracket classes
    collapsed: `*.[Pp][Yy]` and `*.py` both yield `py`."""
    return BRACKET.sub(lambda m: m.group(1).lower(), pattern[2:]).lower()


def twin_lowercases(sh_path):
    """True when the Python side of this pair lowercases an extension.

    Checks the same-stem twin AND a same-dir loc_engine.py, because the
    decomposition pair keeps `lang_of` in the shared engine rather than in
    patterns.py/sizing.py."""
    candidates = [sh_path[:-3] + ".py", os.path.join(os.path.dirname(sh_path), "loc_engine.py")]
    for cand in candidates:
        if not os.path.exists(cand):
            continue
        if ".lower()" in open(cand, encoding="utf-8", errors="replace").read():
            return True
    return False


defects = []
exempt = 0
covered = 0
for dirpath, _dirs, files in os.walk(PLUGINS):
    for name in sorted(files):
        if not name.endswith(".sh"):
            continue
        path = os.path.join(dirpath, name)
        lowers = twin_lowercases(path)
        for lineno, line in enumerate(open(path, encoding="utf-8", errors="replace"), 1):
            m = ARM.match(line)
            if not m:
                continue
            patterns = [p.strip() for p in m.group(1).split("|")]
            if not all(ext_of(p) in LANG for p in patterns):
                continue  # narrowing 2: a skip glob, not a language dispatch
            if any("[" in p for p in patterns):
                covered += 1
                continue
            if not lowers:
                exempt += 1  # narrowing 3: the twin matches literally too
                continue
            defects.append(
                "%s:%d\t%s" % (os.path.relpath(path, ROOT), lineno, line.strip())
            )

print("LANGS\t%s" % " ".join(sorted(LANG)))
print("COVERED\t%d" % covered)
print("EXEMPT\t%d" % exempt)
for row in defects:
    print("DEFECT\t%s" % row)
PY
)"

field() { command printf '%s\n' "$SCANNER_REPORT" | command grep "^$1	" | command cut -f2- || true; }

# The scan actually found the language table. An empty LANG set would make every
# arm "not a language arm" and the gate would pass over a fully reverted tree —
# the vacuity this assertion exists to prevent.
test_language_table_is_populated() {
    local langs
    langs="$(field LANGS)"
    assert_not_empty "$langs" "the language-key table was derived from the Python impls"
    case " $langs " in
        *" py "*) : ;;
        *) _fail "derived language table is missing 'py'" \
            "Every ported scanner dispatches on .py; its absence means the derivation broke." \
            "derived: $langs" ;;
    esac
}

# The gate is looking at real arms. Without this, a regex typo that matched
# NOTHING would report zero defects and read exactly like a clean tree.
test_dispatch_arms_are_found() {
    local covered
    covered="$(field COVERED)"
    assert_not_empty "$covered" "the scan reported a covered-arm count"
    if [ "${covered:-0}" -lt 40 ]; then
        _fail "far fewer dispatch arms found than expected" \
            "#754 converted ~68 language arms across 8 sites; a count this low means the arm parser stopped matching, not that the arms are gone." \
            "covered: $covered"
    fi
}

# THE assertion.
test_every_language_arm_is_case_insensitive() {
    local defects
    defects="$(command printf '%s\n' "$SCANNER_REPORT" | command grep '^DEFECT	' | command cut -f2- || true)"
    if [ -n "$defects" ]; then
        _fail "a language-dispatch case arm is case-SENSITIVE" \
            "The Python twin lowercases the extension, so this arm makes a mixed-case file segment under python and not under bash — silent, exit 0 (#754). Spell it with bracket classes: *.[Pp][Yy]" \
            "$defects"
    fi
}

run_test test_language_table_is_populated "The language-key table is derived, non-empty, and includes py"
run_test test_dispatch_arms_are_found "The arm parser matches the real dispatch arms (not vacuous)"
run_test test_every_language_arm_is_case_insensitive "Every language-dispatch case arm is case-insensitive"

generate_report
