#!/usr/bin/env bash
# Scanner language-table consistency (#622 Phase 0, ADR 0002).
#
# The four check-* pre-scan scanners each dispatch on a file extension, and each
# carries its own idea of which extension is which language. ADR 0002 names ONE
# normative spelling of those lexical facts — EXT_LANG and COMMENT_RE in
# check-decomposition/loc_engine.py — and makes every other copy a SUBSET of it:
#
#   A scanner may cover FEWER extensions than the normative table. It may never
#   CONTRADICT it: an extension it dispatches on must map to the same language
#   key, and a comment marker it uses for a language must match.
#
# Subset-consistency rather than byte-identity is the point. Byte-identity would
# force every scanner to carry every language (check-lifecycle models 4, the
# docs scanner 8, and both are correct). A free-for-all permits exactly the drift
# ADR 0002 was written to stop — a dozen independent spellings of "`.mjs` is
# JavaScript", one of which will eventually disagree.
#
# WHY STRUCTURAL AND NOT BEHAVIORAL. Same argument as
# lint-scanner-case-dispatch.sh, which this gate is modelled on: the defect is
# silent (a scan just reports differently), it is per-arm, and it spreads by
# copy — a new scanner is written by copying a neighbour. A fixture corpus can
# only cover the languages it happens to contain; the source can be checked whole.
#
# WHAT THIS GATE ASSERTS
#
#   1. ANTI-VACUITY: the normative EXT_LANG was found and is populated.
#   2. ANTI-VACUITY: all four `## Language Support` matrices resolve and are
#      non-empty. extract_contract fails loud on a missing or duplicated id, so
#      a deleted marker aborts rather than silently passing an empty region.
#   3. NO CONTRADICTION: every extension a scanner dispatches on maps to the same
#      language key as the normative table. Extensions ABSENT from EXT_LANG are
#      silent here — the stricter "every dispatched extension must be covered"
#      form is Phase 1 work, because satisfying it today means extending
#      EXT_LANG, which is a BEHAVIOR change to check-decomposition (files with
#      those extensions would start being segmented).
#   4. MATRIX <-> SOURCE: every language marked `M` in a contract matrix has a
#      dispatch arm in BOTH runtimes; every language marked `—` has one in
#      neither.
#
# Assertion 4 is the load-bearing one. It converts each future phase's
# dual-runtime obligation from "remember to do both" into a gate — and it is the
# shape of check that would have caught #836, where check-lifecycle's bash half
# silently diverged from its Python twin.
#
# THE EXACT GRANULARITY OF ASSERTION 4, because it is easy to over-read. It is
# PER-LANGUAGE, not per-matrix-CELL:
#
#   - `have_py`/`have_sh` are unions of every extension dispatched ANYWHERE in
#     the file. check-code-health has THREE dispatch chains with genuinely
#     different coverage (debug-print excludes rb; debugger includes it), and
#     this check does not tell them apart.
#   - `parse_matrix` collapses a row to one state by OR-ing its category columns,
#     so a row that is `M` in one column and `—` in another reads as `M`.
#
# So it answers "is this LANGUAGE dispatched in both runtimes, as the matrix
# claims" — which is exactly the #836 shape — and NOT "is this CATEGORY's cell
# accurate". A wrong cell in one column can still pass while another column's arm
# for that extension exists. Narrowing to per-category means locating each
# detector family's source region, which is Phase 1 work, when the arms are being
# rewritten anyway. Recorded rather than silently accepted: see ADR 0002
# § Consequences, and the deferred finding it cites.
#
# Assertion 3 additionally covers a pair NOTHING checked before: the byte-identical
# ext->lang `case` blocks in check-decomposition/patterns.sh and
# ship-issue/sizing.sh sit OUTSIDE any `>>> shared:` region and are pinned by no
# sync pair. They are walked here like any other dispatch site.
#
# Pure bash + coreutils + python3. No network.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "Scanner language-table consistency (#622)"

# Overridable so the negative fixtures can point the gate at a synthetic tree.
# Defaults to the real repo.
LANG_TABLE_ROOT="${LANG_TABLE_ROOT:-$REPO_ROOT}"

# This gate parses Python source and markdown tables with python3 (both grammars
# are beyond a portable grep). A missing runtime is an UNAVAILABLE LINTER, so it
# exits the reserved 77 sentinel rather than 0 — run-all.sh renders 77 as
# "[SKIP] ... did not run", because a silent skip is indistinguishable from a
# pass and is how a gate sits inert unnoticed (#538, #571).
if ! command -v python3 >/dev/null 2>&1; then
    skip_test "python3 not available (language-table consistency not checked)"
    generate_report
    exit 77
fi

# The analyzer prints one finding per line, each prefixed by a tag the tests
# below filter on. Run once; every assertion reads this one report, so the tree
# is walked a single time.
#
#   NORMATIVE <count>            — size of the normative EXT_LANG
#   MATRIX <skill> <count>       — languages parsed out of one contract matrix
#   CONTRADICTION <detail>       — assertion 3 violation
#   MISMATCH <detail>            — assertion 4 violation
LANG_REPORT="$(
    command python3 - "$LANG_TABLE_ROOT" <<'PY'
import os
import re
import sys

ROOT = sys.argv[1]
PLUGINS = os.path.join(ROOT, "plugins")
SKILLS = os.path.join(PLUGINS, "review-audit", "skills")

# The four scanners ADR 0002 governs. Explicit and ordered, not a glob: a fifth
# check-* skill is NOT automatically in scope (it may legitimately have no
# language dispatch at all), so enrolling one is a deliberate edit here — same
# reasoning as tests/lib/fragments.sh and the workflow.js fragment manifests.
GOVERNED = (
    "check-security",
    "check-code-health",
    "check-lifecycle",
    "check-docs-missing-api",
)

# --- the normative table -----------------------------------------------------
# Parsed out of loc_engine.py's EXT_LANG literal rather than imported: this gate
# must not execute scanner code, and the literal is a flat str->str dict by the
# column-zero rule that validate-shared-scanner-sync.sh already enforces.
NORMATIVE_SRC = os.path.join(SKILLS, "check-decomposition", "loc_engine.py")


def read(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def parse_ext_lang(src):
    m = re.search(r"^EXT_LANG\s*=\s*\{(.*?)^\}", src, re.M | re.S)
    if not m:
        return {}
    return dict(re.findall(r'"([A-Za-z0-9]+)"\s*:\s*"([A-Za-z0-9]+)"', m.group(1)))


normative = {}
if os.path.exists(NORMATIVE_SRC):
    normative = parse_ext_lang(read(NORMATIVE_SRC))
print("NORMATIVE %d" % len(normative))

# --- what each scanner dispatches on ----------------------------------------
# Python side: `ext == "x"` and `ext in ("x", "y")`. Bash side: `*.[Xx][Yy])`
# case arms, bracket classes collapsed. Both yield a set of lowercase extensions
# per file.
BRACKET = re.compile(r"\[([A-Za-z])[A-Za-z]\]")
ARM = re.compile(r"^\s*(\*\.[A-Za-z0-9\[\]]+(?:\s*\|\s*\*\.[A-Za-z0-9\[\]]+)*)\)", re.M)


def py_exts(src):
    out = set(re.findall(r'ext\s*==\s*"([a-z0-9]+)"', src))
    for grp in re.findall(r"ext\s+in\s*\(([^)]*)\)", src):
        out.update(re.findall(r'"([a-z0-9]+)"', grp))
    return out


def sh_exts(src):
    out = set()
    for arm in ARM.findall(src):
        for pat in arm.split("|"):
            pat = pat.strip()
            if not pat.startswith("*."):
                continue
            out.add(BRACKET.sub(lambda m: m.group(1).lower(), pat[2:]).lower())
    return out


# A bash `lang="x"` assignment names the language for an arm; when present it is
# a direct claim about the mapping and is checked against the normative table.
def sh_lang_pairs(src):
    pairs = []
    for arm, lang in re.findall(
        r"^\s*(\*\.[A-Za-z0-9\[\]|\s*.]+?)\)\s*lang=\"([a-z0-9]+)\"", src, re.M
    ):
        for pat in arm.split("|"):
            pat = pat.strip()
            if not pat.startswith("*."):
                continue
            ext = BRACKET.sub(lambda m: m.group(1).lower(), pat[2:]).lower()
            pairs.append((ext, lang))
    return pairs


# --- assertion 3: no contradiction ------------------------------------------
# Walk EVERY dispatch site under plugins/, not just the four governed scanners:
# the unpinned check-decomposition <-> sizing.sh bash tables are covered here.
for dirpath, _dirs, files in os.walk(PLUGINS):
    for name in sorted(files):
        if not name.endswith(".sh"):
            continue
        path = os.path.join(dirpath, name)
        rel = os.path.relpath(path, ROOT)
        for ext, lang in sh_lang_pairs(read(path)):
            want = normative.get(ext)
            if want is not None and want != lang:
                print(
                    "CONTRADICTION %s: .%s -> %r, normative says %r"
                    % (rel, ext, lang, want)
                )

# --- the contract matrices ---------------------------------------------------
# A row is `| Name | ext, ext | cell | cell |`. The language is column 2 (the
# extension list); a row whose cell set contains an `M` is modeled, a row whose
# cells are all `—` is unsupported. The catch-all row ("every other extension")
# names no extension and is skipped.
CELL_M = "M"
CELL_NONE = "—"  # em dash


def parse_matrix(md, skill):
    """Return {ext: 'M'|'-'} for one scanner's Language Support matrix."""
    start = md.find("<!-- contract: %s-language-support -->" % skill)
    if start < 0:
        return None
    end = md.find("<!-- contract: end-%s-language-support -->" % skill, start)
    if end < 0:
        return None
    out = {}
    for line in md[start:end].splitlines():
        line = line.strip()
        if not line.startswith("|") or line.startswith("| ---"):
            continue
        cols = [c.strip() for c in line.strip("|").split("|")]
        if len(cols) < 3 or cols[0] in ("Language",):
            continue
        exts = [e.strip() for e in cols[1].split(",") if e.strip()]
        if not exts:
            continue  # the catch-all row
        cells = cols[2:]
        state = CELL_M if any(CELL_M in c for c in cells) else "-"
        # A cell may carry a parenthetical narrowing ("M (js/jsx only)"); the
        # row-level state stays M and the narrowing is prose for the reader.
        for e in exts:
            if re.fullmatch(r"[a-z0-9]+", e):
                out[e] = state
    return out


# --- assertions 2 + 4 --------------------------------------------------------
for skill in GOVERNED:
    contract = os.path.join(SKILLS, skill, "contract.md")
    py = os.path.join(SKILLS, skill, "patterns.py")
    sh = os.path.join(SKILLS, skill, "patterns.sh")
    if not any(os.path.exists(p) for p in (contract, py, sh)):
        # The scanner is absent entirely. In the real tree that cannot happen;
        # in a negative fixture it is how a tree arms ONE assertion without
        # tripping its siblings as collateral. A PARTIALLY present scanner is
        # still a defect and falls through to the check below.
        continue
    if not (os.path.exists(contract) and os.path.exists(py) and os.path.exists(sh)):
        print("MISMATCH %s: missing contract.md/patterns.py/patterns.sh" % skill)
        continue

    matrix = parse_matrix(read(contract), skill)
    if matrix is None:
        print("NOMATRIX %s" % skill)
        continue
    print("MATRIX %s %d" % (skill, len(matrix)))

    have_py = py_exts(read(py))
    have_sh = sh_exts(read(sh))

    for ext, state in sorted(matrix.items()):
        in_py, in_sh = ext in have_py, ext in have_sh
        if state == CELL_M:
            if not in_py:
                print("MISMATCH %s: .%s marked M, no patterns.py arm" % (skill, ext))
            if not in_sh:
                print("MISMATCH %s: .%s marked M, no patterns.sh arm" % (skill, ext))
        else:
            if in_py:
                print(
                    "MISMATCH %s: .%s marked unsupported, patterns.py has an arm"
                    % (skill, ext)
                )
            if in_sh:
                print(
                    "MISMATCH %s: .%s marked unsupported, patterns.sh has an arm"
                    % (skill, ext)
                )

    # A language the matrix does not mention at all, but both runtimes dispatch
    # on, is an UNDECLARED arm — the drift the matrix exists to prevent.
    for ext in sorted(have_py & have_sh):
        if ext not in matrix and ext in normative:
            print("MISMATCH %s: .%s dispatched in both runtimes, not in matrix" % (skill, ext))
PY
)"

# report_lines TAG — echo the report rows carrying TAG, or nothing.
report_lines() {
    command printf '%s\n' "$LANG_REPORT" | command grep -E "^$1 " || true
}

# --- Assertion 1: anti-vacuity, the normative table ------------------------
test_normative_table_populated() {
    local count
    count="$(report_lines NORMATIVE | command sed -n 's/^NORMATIVE //p')"
    # No assert_true anywhere in this gate: it evals its command string, and
    # every value here is analyzer-derived. Compare in bash, report via a
    # parameter-taking assertion. See the NOTE above test_no_contradiction.
    # `case` on a quoted value, then assert_equals on the VERDICT — neither evals.
    # A non-digit or absent count is as much a failure as a zero one: it means the
    # analyzer did not report, which is precisely the vacuity this guards.
    local verdict="populated"
    case "$count" in
        '' | *[!0-9]*) verdict="unparseable (got: '${count:-<none>}')" ;;
        0) verdict="parsed but EMPTY" ;;
    esac
    assert_equals "populated" "$verdict" "normative EXT_LANG parsed and non-empty"
}

# --- Assertion 2: anti-vacuity, the matrices --------------------------------
# TWO halves, and both are needed.
#
# (a) A scanner that EXISTS but resolves no matrix is a defect — reported as
#     NOMATRIX by the analyzer. This is the half a negative fixture arms.
# (b) In the REAL tree, all four must be present. Guarded by NAME SET rather
#     than by count: a gate asserting "4 matrices" still passes when one skill's
#     matrix is silently swapped for a duplicate of another's (#596). Skipped
#     under a fixture root, where a tree deliberately carries a subset.
test_no_unmatched_scanner() {
    local bad
    bad="$(report_lines NOMATRIX)"
    assert_output_empty "$bad" \
        "every present scanner resolves a Language Support matrix"
}

test_matrices_present() {
    local found skill declared
    if [ "$LANG_TABLE_ROOT" != "$REPO_ROOT" ]; then
        skip_test "fixture root — the four-scanner roster applies to the real tree"
        return 0
    fi
    found="$(report_lines MATRIX | command awk '{print $2}' | command sort)"
    for skill in check-security check-code-health check-lifecycle check-docs-missing-api; do
        if command printf '%s\n' "$found" | command grep -qx "$skill"; then
            declared="yes"
        else
            declared="no"
        fi
        assert_equals "yes" "$declared" "$skill declares a Language Support matrix"
    done
}

test_matrices_non_empty() {
    local line skill count nonempty
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        skill="$(command printf '%s' "$line" | command awk '{print $2}')"
        count="$(command printf '%s' "$line" | command awk '{print $3}')"
        if [ "$count" -gt 0 ] 2>/dev/null; then
            nonempty="yes"
        else
            nonempty="no"
        fi
        assert_equals "yes" "$nonempty" \
            "$skill's matrix names at least one language (got $count)"
    done <<EOF
$(report_lines MATRIX)
EOF
}

# --- Assertion 3: no contradiction with the normative table ------------------
# NOTE — these use assert_output_empty, NOT assert_true, and that is a security
# property rather than a style choice. assert_true EVALs its command string
# (tests/lib/harness.sh: `eval "$cmd"`), and a CONTRADICTION row embeds `rel`,
# the on-disk relative path of any *.sh the walk finds under plugins/. That path
# is attacker-controlled in the only sense that matters here: a PR can add a file
# whose NAME contains `$(...)` or backticks without touching this gate at all,
# and the substitution would then execute when CI or pre-push runs it. The
# extension/language tokens are `[a-z0-9]+`-constrained; the path is not.
# assert_output_empty takes the value as a PARAMETER and never evals it.
test_no_contradiction() {
    local bad
    bad="$(report_lines CONTRADICTION)"
    assert_output_empty "$bad" \
        "no dispatch site contradicts the normative EXT_LANG"
}

# --- Assertion 4: the matrix matches both runtimes ---------------------------
test_matrix_matches_source() {
    local bad
    bad="$(report_lines MISMATCH)"
    assert_output_empty "$bad" \
        "every matrix cell matches both runtimes"
}

run_test test_normative_table_populated "normative EXT_LANG is populated (anti-vacuity)"
run_test test_no_unmatched_scanner "a present scanner resolves its matrix (anti-vacuity)"
run_test test_matrices_present "all four governed scanners declare a matrix (anti-vacuity)"
run_test test_matrices_non_empty "each matrix names at least one language"
run_test test_no_contradiction "no dispatch site contradicts the normative table"
run_test test_matrix_matches_source "matrix M/unsupported cells match both runtimes"

# --- Self-tests: each assertion actually fires -------------------------------
#
# The five checks above are green on this tree, which is necessary and proves
# nothing on its own — a detector that never fires is green too, and that is this
# repo's most-recorded failure mode (#596, #599, #600). So each assertion is
# re-run against a committed negative fixture that arms IT and only it.
#
# Committed trees under tests/fixtures/language-table/, not transient mutations,
# for the reason tests/fixtures/category-parity/ is committed: the proof has to
# re-run on every future invocation, not only on the day it was written.
#
# Fixtures are only run when the gate is pointed at the real tree — a nested
# self-test under a fixture root would recurse.
FIXROOT="$SCRIPT_DIR/fixtures/language-table"

# selftest_report FIXTURE — the analyzer's findings for one fixture tree, via a
# recursive call to this script with LANG_TABLE_ROOT redirected. Prints the
# harness output; callers grep it for the specific failing assertion.
selftest_report() {
    LANG_TABLE_ROOT="$FIXROOT/$1" command bash "$SCRIPT_DIR/$(command basename "${BASH_SOURCE[0]}")" 2>&1 || true
}

test_selftest_fixtures() {
    if [ "$LANG_TABLE_ROOT" != "$REPO_ROOT" ]; then
        skip_test "already under a fixture root — self-tests do not recurse"
        return 0
    fi

    local out

    out="$(selftest_report empty-normative)"
    assert_contains "$out" "normative EXT_LANG is populated (anti-vacuity) ... FAIL" \
        "empty-normative fixture must fail the normative-table assertion"

    out="$(selftest_report no-marker)"
    assert_contains "$out" "a present scanner resolves its matrix (anti-vacuity) ... FAIL" \
        "no-marker fixture must fail the matrix-resolution assertion"

    out="$(selftest_report contradiction)"
    assert_contains "$out" "no dispatch site contradicts the normative table ... FAIL" \
        "contradiction fixture must fail the no-contradiction assertion"

    out="$(selftest_report one-runtime)"
    assert_contains "$out" "matrix M/unsupported cells match both runtimes ... FAIL" \
        "one-runtime fixture must fail the matrix<->source assertion"
    assert_contains "$out" "no patterns.sh arm" \
        "one-runtime fixture must name the missing bash arm specifically"
}

run_test test_selftest_fixtures "self-test: each assertion fires on its fixture"

generate_report
