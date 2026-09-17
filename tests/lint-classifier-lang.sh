#!/usr/bin/env bash
# Prose file-type classifier language-table consistency (#1073, ADR 0002).
#
# WHAT THIS GATES, AND WHY IT IS ITS OWN FILE.
#
# Two PROSE tables classify a file by extension, and both are read by an LLM
# rather than executed:
#
#   plugins/dev-core/agents/code-reviewer.md          Step 2 "Classify Files"
#   plugins/review-audit/skills/codebase-audit/orchestration-protocol.md
#                                                     Step 1.5 classification
#
# By ADR 0002 each is required to be a SUBSET of the normative EXT_LANG in
# check-decomposition/loc_engine.py: it may cover FEWER extensions, never
# CONTRADICT them. Two gates already enforce that rule elsewhere —
# tests/lint-language-table-sync.sh (the four check-* scanners) and
# tests/lint-review-route-lang.sh (review-route.sh) — and NEITHER covers these
# two files: `grep -c code-reviewer` returns 0 in both. The scanner gate is
# shaped around a `patterns.{py,sh}` pair plus a `## Language Support` matrix,
# and these files have neither. Hence a third narrow sibling, exactly as #913
# added the second.
#
# WHY THESE TABLES ARE WORTH A GATE. Their failure direction is fail-open and
# silent, and it is the same shape in both:
#
#   code-reviewer.md — a file matching NO row classifies as no type at all.
#   DIMENSION_RELEVANT_TYPES (ship-issue/workflow.src/74-narrowing.js) gates
#   every delta-local dimension by type, and `security`, `correctness` and
#   `tests` all key on `source`. A narrowed re-review cycle whose delta is only
#   such a file matches NOTHING — and narrowing is explicitly not a partial
#   cycle, so the dimension "had nothing to read", never enters
#   dimensionsSkipped, and never sets budgetExhausted. The cycle returns
#   `clean` having reviewed none of it.
#
#   orchestration-protocol.md — Step 3 routes `Source files` to code-health,
#   security, architecture, lifecycle and decomposition. An unclassified file
#   reaches none of them, and the audit reports on a corpus it never read.
#
# That is the silence-reads-as-a-pass shape (#538, #571), landing on the `clean`
# verdict itself. `.swift` had it in both tables: five scanners ship Swift arms,
# EXT_LANG maps `swift`, review-route.sh routes `*.swift` source, and
# thresholds.yml carries swift budgets — the two prose copies were the only ones
# that missed it, and the only ones no gate covered.
#
# ---------------------------------------------------------------------------
# THE CONTRADICTION RULE, stated once.
#
#   EXT_LANG lang `md`  =>  the extension must be classified docs/doc
#   every other lang    =>  the extension must be classified source
#
# COARSER IS NOT CONTRADICTION. These tables answer "is this reviewable source",
# EXT_LANG answers "can check-decomposition segment this". The second question
# has a later answer, so a classifier legitimately lists extensions EXT_LANG does
# not model (.rb, .java, .kt, .c, .cpp, .h — all scanned today; see
# SPLIT_SHAPE_FALLBACK's comment in loc_engine.py). Those are permitted, but
# never SILENTLY: each must appear in UNSEGMENTED_SOURCE below, which is what
# turns "we kept it" into a stated claim. AC2 of #1073 is precisely this
# distinction.
#
# WHAT THIS GATE ASSERTS
#
#   1. ANTI-VACUITY: the normative EXT_LANG was found and is populated.
#   2. ANTI-VACUITY: both subject tables resolved and their source and doc rows
#      are non-empty. Without this, a renamed heading or a reshaped table makes
#      every assertion below compare against EMPTY SETS and pass for free —
#      the silence-reads-as-a-pass shape this gate exists to close, reappearing
#      inside the gate itself.
#   3. NO CONTRADICTION: every extension a table classifies that EXT_LANG also
#      knows lands in the class the rule above implies. Reported WITH ITS
#      DIRECTION: a source language classified docs is the FAIL-OPEN one (it
#      reaches `clean`); the inverse merely over-reviews. ADR 0002 forbids both,
#      so both are reported and the row says which.
#   4. COVERAGE: every extension EXT_LANG maps to a NON-`md` language appears in
#      the table's source row. This is the assertion that catches `.swift` —
#      and it is the one the sibling gates deliberately do NOT make (there,
#      "subset" means a scanner may cover fewer). It is correct HERE and wrong
#      there because these tables are not scanners: an extension absent from a
#      scanner falls through to the next scanner, while an extension absent from
#      the CLASSIFIER has no downstream at all. Absence here is the defect.
#   5. DECLARED UNSEGMENTED: every source-row extension EXT_LANG does NOT govern
#      must be listed in UNSEGMENTED_SOURCE. This is what keeps assertion 4's
#      inverse honest — the table may be coarser, but each coarsening is a
#      deliberate line in this file rather than drift nobody reviewed.
#
# THE RESIDUAL LIMIT, recorded rather than papered over: this gate reads the
# extension VOCABULARY of a prose table. It cannot verify that the agent reading
# that prose classifies as instructed — that is behavior, and the end-to-end
# assertion for it lives in tests/workflow-helpers/ship-issue/03-narrowing-selector.mjs
# (a .swift-only delta must select security/correctness/tests). The two are
# complementary: this gate catches a vocabulary that went stale, that one catches
# a routing table that stopped consuming it.
#
# Pure bash + coreutils + python3. No network. bash-3.2 clean and BSD-regex
# clean, per CLAUDE.md § Key conventions (runtime policy).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "prose classifier language-table consistency (#1073)"

# Overridable so the negative fixtures can point the gate at a synthetic tree.
# Defaults to the real repo. Same mechanism, and same reason, as
# REVIEW_ROUTE_LANG_ROOT in tests/lint-review-route-lang.sh and LANG_TABLE_ROOT
# in tests/lint-language-table-sync.sh.
CLASSIFIER_LANG_ROOT="${CLASSIFIER_LANG_ROOT:-$REPO_ROOT}"

# This gate parses a Python dict literal and two markdown tables with python3
# (the dict grammar is beyond a portable grep). A missing runtime is an
# UNAVAILABLE LINTER, so it exits the reserved 77 sentinel rather than 0 —
# run-all.sh renders 77 as "[SKIP] ... did not run", because a silent skip is
# indistinguishable from a pass and is how a gate sits inert unnoticed
# (#538, #571).
if ! command -v python3 >/dev/null 2>&1; then
    skip_test "python3 not available (prose classifier tables not checked)"
    generate_report
    exit 77
fi

# The analyzer prints one finding per line, each prefixed by a tag the tests
# below filter on. Run once; every assertion reads this one report.
#
#   NORMATIVE <count>            — size of the normative EXT_LANG
#   ROWS <subject> <cls> <count> — extensions found in one table row
#   NOTABLE <subject>            — assertion 2 violation (table unresolvable)
#   CONTRADICTION <detail>       — assertion 3 violation
#   MISSING <detail>             — assertion 4 violation
#   UNDECLARED <detail>          — assertion 5 violation
CLASSIFIER_REPORT="$(
    command python3 - "$CLASSIFIER_LANG_ROOT" <<'PY'
import os
import re
import sys

ROOT = sys.argv[1]
PLUGINS = os.path.join(ROOT, "plugins")

NORMATIVE_SRC = os.path.join(
    PLUGINS, "review-audit", "skills", "check-decomposition", "loc_engine.py"
)

# The two subjects, each as (label, path, source-row-name, doc-row-name).
#
# EXPLICIT AND HAND-MAINTAINED, never a glob over plugins/**/*.md — same
# discipline and same reason as GOVERNED in tests/lint-language-table-sync.sh
# and UNGOVERNED_DOC in tests/lint-review-route-lang.sh. A glob would make the
# gate's coverage depend on what happens to be on disk, so a subject that was
# RENAMED would silently stop being checked while the gate stayed green. The row
# names differ per file (`source` vs `Source`) and are matched case-insensitively
# below, but they are named here rather than guessed.
SUBJECTS = (
    (
        "code-reviewer",
        os.path.join(PLUGINS, "dev-core", "agents", "code-reviewer.md"),
        "source",
        "docs",
    ),
    (
        "orchestration-protocol",
        os.path.join(
            PLUGINS, "review-audit", "skills", "codebase-audit",
            "orchestration-protocol.md",
        ),
        "source",
        "doc",
    ),
)

# Extensions a classifier may list that EXT_LANG does not model. See the header:
# these tables answer a coarser question than the LOC engine, so listing an
# unsegmented language is correct — but it must be DECLARED, never silently
# retained. Adding an entry here is a deliberate edit that says "this is source,
# and EXT_LANG has no opinion because nothing segments it yet".
#
# `h` is orchestration-protocol.md's alone; carried in one shared tuple because
# the claim ("source, unsegmented") is identical and a per-subject split would
# invite the two lists to drift — the exact duplication ADR 0002 forbids.
UNSEGMENTED_SOURCE = ("rb", "java", "kt", "c", "cpp", "h")


def read(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


# --- the normative table -----------------------------------------------------
# Parsed out of loc_engine.py's EXT_LANG literal rather than imported: this gate
# must not execute scanner code, and the literal is a flat str->str dict closed
# by a column-zero `}` — a shape tests/validate-shared-scanner-sync.sh already
# enforces. Same recipe as BOTH sibling gates, deliberately, so all three read
# the normative table identically.
def parse_ext_lang(src):
    m = re.search(r"^EXT_LANG\s*=\s*\{(.*?)^\}", src, re.M | re.S)
    if not m:
        return {}
    return dict(re.findall(r'"([A-Za-z0-9]+)"\s*:\s*"([A-Za-z0-9]+)"', m.group(1)))


normative = {}
if os.path.exists(NORMATIVE_SRC):
    normative = parse_ext_lang(read(NORMATIVE_SRC))
print("NORMATIVE %d" % len(normative))


# --- the subjects: a markdown table row's backticked extensions --------------
# A row is `| <name> | `.a`, `.b`, ... |`. Extensions are read from BACKTICKED
# tokens only, so prose in the same cell (`docs/`, `README*`, `Makefile`) is
# ignored unless it is itself a dotted extension — which is what we want: this
# gate has opinions about extensions, not about path globs.
EXT_TOKEN = re.compile(r"`\.([A-Za-z0-9]+)`")


def table_row_exts(src, row_name):
    """The set of extensions in the markdown table row labelled ROW_NAME.

    Returns None when no such row resolves — which assertion 2 reports, rather
    than letting an empty set read as a table that legitimately lists nothing.
    The distinction is the whole point of the anti-vacuity assertion: a renamed
    heading and an empty row are different defects, and only one of them is
    'someone deleted the table'.

    The row is matched on its FIRST cell, case-insensitively and
    whitespace-tolerant, so `| source |` and `| Source         |` both resolve
    without the gate hardcoding either file's column padding.
    """
    pat = re.compile(r"^\|\s*%s\s*\|(.*)$" % re.escape(row_name), re.M | re.I)
    m = pat.search(src)
    if not m:
        return None
    return set(EXT_TOKEN.findall(m.group(1)))


tables = {}
for label, path, src_row, doc_row in SUBJECTS:
    if not os.path.exists(path):
        print("NOTABLE %s" % label)
        continue
    src = read(path)
    source_exts = table_row_exts(src, src_row)
    doc_exts = table_row_exts(src, doc_row)
    if source_exts is None or doc_exts is None:
        print("NOTABLE %s" % label)
        continue
    tables[label] = {"source": source_exts, "doc": doc_exts}
    print("ROWS %s source %d" % (label, len(source_exts)))
    print("ROWS %s doc %d" % (label, len(doc_exts)))

# --- assertion 3: no contradiction with the normative table ------------------
IMPLIED_DOC = "md"

for label in sorted(tables):
    rows = tables[label]
    for cls in ("source", "doc"):
        for ext in sorted(rows[cls]):
            lang = normative.get(ext)
            if lang is None:
                continue  # EXT_LANG has no opinion; assertions 4/5 bound this
            want = "doc" if lang == IMPLIED_DOC else "source"
            if want == cls:
                continue
            # Name the DIRECTION. A source language classified docs is the
            # fail-open one: the delta-relevance test drops security,
            # correctness and tests, and the cycle stays eligible for `clean`.
            # The inverse only costs review budget. A reader triaging this row
            # needs to know which they are looking at.
            #
            # DERIVED from the two classes, never hardcoded per branch — the
            # sibling gate shipped a hardcoded label that mislabelled the one
            # cell no fixture drove, and this is the same computation.
            if want == "source":
                direction = (
                    "FAIL-OPEN (source classified %s — drops security/correctness/tests "
                    "on a narrowed cycle)" % cls
                )
            else:
                direction = "over-review (%s classified %s)" % (want, cls)
            print(
                "CONTRADICTION %s .%s classified %r, normative lang %r implies %r — %s"
                % (label, ext, cls, lang, want, direction)
            )

# --- assertion 4: every segmented source language is covered -----------------
# The assertion that catches `.swift`. See the header for why absence is a
# defect HERE and permitted in the sibling gates.
for label in sorted(tables):
    source_exts = tables[label]["source"]
    for ext in sorted(normative):
        if normative[ext] == IMPLIED_DOC:
            continue
        if ext not in source_exts:
            print(
                "MISSING %s .%s is a source language in the normative EXT_LANG "
                "(lang %r) but absent from the source row — a delta of only such "
                "files classifies as NO type and drops out of every "
                "delta-relevance test" % (label, ext, normative[ext])
            )

# --- assertion 5: every ungoverned source extension is declared --------------
for label in sorted(tables):
    for ext in sorted(tables[label]["source"]):
        if ext in normative:
            continue
        if ext in UNSEGMENTED_SOURCE:
            continue
        print(
            "UNDECLARED %s .%s is in the source row, is absent from the "
            "normative EXT_LANG, and is not listed in UNSEGMENTED_SOURCE — "
            "nothing states whether it is deliberately coarser or stale drift"
            % (label, ext)
        )
PY
)"

# report_lines TAG — echo the report rows carrying TAG, or nothing.
report_lines() {
    command printf '%s\n' "$CLASSIFIER_REPORT" | command grep -E "^$1( |$)" || true
}

# --- Assertion 1: anti-vacuity, the normative table --------------------------
test_normative_table_populated() {
    local count
    count="$(report_lines NORMATIVE | command sed -n 's/^NORMATIVE //p')"
    # No assert_true anywhere in this gate — see the NOTE above
    # test_no_contradiction. `case` on a quoted value, then assert_equals on the
    # VERDICT; neither evals. A non-digit or absent count fails exactly as a zero
    # one does: it means the analyzer did not report, which is the vacuity this
    # guards.
    local verdict="populated"
    case "$count" in
        '' | *[!0-9]*) verdict="unparseable (got: '${count:-<none>}')" ;;
        0) verdict="parsed but EMPTY" ;;
    esac
    assert_equals "populated" "$verdict" "normative EXT_LANG parsed and non-empty"
}

# --- Assertion 2: anti-vacuity, the subjects --------------------------------
# TWO halves, mirroring the sibling gate. Every subject table must RESOLVE, and
# each resolved row must be non-empty. Either failure leaves assertions 3-5
# comparing against empty sets — green for the worst possible reason.
test_tables_resolve() {
    local bad
    bad="$(report_lines NOTABLE)"
    assert_output_empty "$bad" \
        "both classifier tables resolve (anti-vacuity)"
}

test_table_rows_non_empty() {
    local line label cls count nonempty
    # BOTH subjects must have reported. A subject that vanished from SUBJECTS —
    # or whose file is missing — emits NOTABLE and no ROWS at all, and a loop
    # over ROWS alone would then assert nothing and pass. Count first.
    local rows
    rows="$(report_lines ROWS | command grep -c . || true)"
    assert_equals "4" "$rows" \
        "both subjects reported both rows (2 subjects x source+doc)"
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        label="$(command printf '%s' "$line" | command awk '{print $2}')"
        cls="$(command printf '%s' "$line" | command awk '{print $3}')"
        count="$(command printf '%s' "$line" | command awk '{print $4}')"
        if [ "$count" -gt 0 ] 2>/dev/null; then
            nonempty="yes"
        else
            nonempty="no"
        fi
        assert_equals "yes" "$nonempty" \
            "$label's $cls row lists at least one extension (got $count)"
    done <<EOF
$(report_lines ROWS)
EOF
}

# --- Assertion 3: no contradiction with the normative table ------------------
# NOTE — these use assert_output_empty, NOT assert_true, and that is the same
# security property both sibling gates record: assert_true EVALs its command
# string (tests/lib/harness.sh: `eval "$cmd"`). Every value here is
# analyzer-derived, and assert_output_empty takes it as a PARAMETER.
test_no_contradiction() {
    local bad
    bad="$(report_lines CONTRADICTION)"
    assert_output_empty "$bad" \
        "no classifier row contradicts the normative EXT_LANG"
}

# --- Assertion 4: every segmented source language is covered -----------------
test_source_row_covers_normative() {
    local bad
    bad="$(report_lines MISSING)"
    assert_output_empty "$bad" \
        "every normative source language appears in each source row"
}

# --- Assertion 5: every ungoverned source extension is declared --------------
test_ungoverned_source_declared() {
    local bad
    bad="$(report_lines UNDECLARED)"
    assert_output_empty "$bad" \
        "every ungoverned source-row extension is declared in UNSEGMENTED_SOURCE"
}

run_test test_normative_table_populated "normative EXT_LANG is populated (anti-vacuity)"
run_test test_tables_resolve "both classifier tables resolve (anti-vacuity)"
run_test test_table_rows_non_empty "each classifier row lists something"
run_test test_no_contradiction "no classifier row contradicts the normative table"
run_test test_source_row_covers_normative "each source row covers the normative source languages"
run_test test_ungoverned_source_declared "every ungoverned source extension is declared"

# --- Self-tests: each assertion actually fires -------------------------------
#
# The five assertions above are green on this tree, which is necessary and proves
# nothing on its own — a detector that never fires is green too, and that is this
# repo's most-recorded failure mode (#596, #599, #600). AC4 of #1073 names this
# requirement directly. So each is re-run against a committed negative fixture
# that arms IT and only it.
#
# Committed trees under tests/fixtures/classifier-lang/, not transient mutations,
# for the reason tests/fixtures/review-route-lang/ is committed: the proof has to
# re-run on every future invocation, not only on the day it was written.
FIXROOT="$SCRIPT_DIR/fixtures/classifier-lang"

# selftest_report FIXTURE — this gate's own output against one fixture tree, via
# a recursive call with CLASSIFIER_LANG_ROOT redirected. Callers grep it for the
# specific failing assertion.
selftest_report() {
    CLASSIFIER_LANG_ROOT="$FIXROOT/$1" \
        command bash "$SCRIPT_DIR/$(command basename "${BASH_SOURCE[0]}")" 2>&1 || true
}

test_selftest_fixtures() {
    if [ "$CLASSIFIER_LANG_ROOT" != "$REPO_ROOT" ]; then
        skip_test "already under a fixture root — self-tests do not recurse"
        return 0
    fi

    local out

    out="$(selftest_report empty-normative)"
    assert_contains "$out" "normative EXT_LANG is populated (anti-vacuity) ... FAIL" \
        "empty-normative fixture must fail the normative-table assertion"

    out="$(selftest_report no-table)"
    assert_contains "$out" "both classifier tables resolve (anti-vacuity) ... FAIL" \
        "no-table fixture must fail the table-resolution assertion"

    # THE FIXTURE FOR THIS ISSUE'S OWN DEFECT. `.swift` removed from the source
    # row, everything else correct — the exact state of the tree before #1073.
    # If this fixture ever passes, the gate has stopped detecting the bug it was
    # written for.
    out="$(selftest_report missing-swift)"
    assert_contains "$out" "each source row covers the normative source languages ... FAIL" \
        "missing-swift fixture must fail the coverage assertion"
    assert_contains "$out" "MISSING code-reviewer .swift" \
        "missing-swift fixture must name the extension and the subject"
    # Exclusivity. A missing extension contradicts nothing (it is simply
    # absent), so assertion 3 must stay silent — otherwise one defect yields two
    # rows and a reader cannot tell which check found it.
    assert_contains "$out" "no classifier row contradicts the normative table ... PASS" \
        "missing-swift fixture must arm ONLY the coverage assertion"

    # The fail-open direction: a source language moved to the docs row. This is
    # the row that reaches `clean` having reviewed nothing.
    out="$(selftest_report contradiction-doc)"
    assert_contains "$out" "no classifier row contradicts the normative table ... FAIL" \
        "contradiction-doc fixture must fail the no-contradiction assertion"
    assert_contains "$out" "FAIL-OPEN (source classified doc" \
        "contradiction-doc fixture must name the direction as fail-open"

    # The SAFE direction is still a contradiction — ADR 0002 forbids it either
    # way. Asserting the direction label here is what keeps this fixture from
    # collapsing into a restatement of contradiction-doc: a gate that reported
    # every row as fail-open would satisfy that one and fail this.
    out="$(selftest_report contradiction-inverse)"
    assert_contains "$out" "no classifier row contradicts the normative table ... FAIL" \
        "contradiction-inverse fixture must fail the no-contradiction assertion"
    assert_contains "$out" "over-review (doc classified source)" \
        "contradiction-inverse fixture must name the direction as over-review"

    out="$(selftest_report undeclared-source)"
    assert_contains "$out" "every ungoverned source extension is declared ... FAIL" \
        "undeclared-source fixture must fail the declaration assertion"
    # Narrowness: the extension is absent from EXT_LANG, so assertion 3 has
    # nothing to say about it, and assertion 4 walks EXT_LANG rather than the
    # row, so it cannot see it either. Without this the fixture passes just as
    # well against a gate that flags every unknown extension everywhere.
    assert_contains "$out" "no classifier row contradicts the normative table ... PASS" \
        "undeclared-source fixture must arm ONLY the declaration assertion"

    # THE SECOND SUBJECT IS REALLY CHECKED. Every fixture above tampers with
    # code-reviewer.md, so all five assertions would be satisfied by a gate that
    # read only the first entry of SUBJECTS — and orchestration-protocol.md was
    # an ungated copy until this issue, which is exactly the hole being closed.
    # This fixture tampers with the SECOND file only.
    out="$(selftest_report second-subject)"
    assert_contains "$out" "each source row covers the normative source languages ... FAIL" \
        "second-subject fixture must fail — orchestration-protocol.md is genuinely read"
    assert_contains "$out" "MISSING orchestration-protocol .swift" \
        "second-subject fixture must name the SECOND subject, not the first"

    # ASSERTIONS 3 AND 5 NEED THE SAME PER-SUBJECT PROOF (found by this PR's own
    # review). The fixture above establishes the second subject is really read by
    # assertion 4 only; without the two below, 3 and 5 are proven to fire against
    # code-reviewer.md and nothing proves they fire against the second file —
    # the "enforced on the copy someone remembered" shape this issue exists to
    # end, recreated inside the gate that ends it.
    #
    # Not redundant with `second-subject`: the two subjects spell their doc row
    # differently (`docs` vs `Doc`), so a row-name error affecting only the
    # second tuple would be invisible to a source-row tamper.
    out="$(selftest_report second-subject-contradiction)"
    assert_contains "$out" "no classifier row contradicts the normative table ... FAIL" \
        "second-subject-contradiction must fail — assertion 3 reads the SECOND subject"
    assert_contains "$out" "CONTRADICTION orchestration-protocol .go" \
        "assertion 3 must name the second subject and the offending extension"
    assert_contains "$out" "FAIL-OPEN (source classified doc" \
        "assertion 3 must name the direction on the second subject too"

    out="$(selftest_report second-subject-undeclared)"
    assert_contains "$out" "every ungoverned source extension is declared ... FAIL" \
        "second-subject-undeclared must fail — assertion 5 reads the SECOND subject"
    assert_contains "$out" "UNDECLARED orchestration-protocol .lua" \
        "assertion 5 must name the second subject and the offending extension"
    assert_contains "$out" "no classifier row contradicts the normative table ... PASS" \
        "second-subject-undeclared must arm ONLY the declaration assertion"

    # THE ONE POSITIVE FIXTURE — it must PASS, where every other arms a failure.
    # That inversion is the point: it pins that a CORRECT pair of tables produces
    # no finding, so a gate that simply failed everything could not satisfy the
    # negatives above and this one at once. The reached-PASS line is what makes
    # it more than "did not crash".
    out="$(selftest_report clean)"
    assert_not_contains "$out" "FAIL" \
        "clean fixture must pass — correct tables must produce no finding"
    assert_contains "$out" "no classifier row contradicts the normative table ... PASS" \
        "clean fixture must actually REACH the no-contradiction assertion"
}

run_test test_selftest_fixtures "self-test: each assertion fires on its fixture"

# --- The fixtures match their generator --------------------------------------
#
# `.build.sh` regenerates every committed tree from hardcoded GOOD_SOURCE /
# GOOD_DOCS / NORMATIVE_BODY strings and is deliberately NOT run by the suite.
# That leaves a drift window (found by this PR's own review): edit the generator,
# forget to re-run it, and the committed fixtures keep proving something the
# generator no longer says — with every test green, because the gate only ever
# compares the fixtures ON DISK against its own logic.
#
# Same shape, and same remedy, as lint-workflow-js-generated.sh: a committed
# artifact whose freshness is checked locally. Regenerate into a temp dir and
# diff. The failure names the recipe, because "fixtures are stale" is only
# actionable with the command that fixes it.
test_fixtures_match_generator() {
    if [ "$CLASSIFIER_LANG_ROOT" != "$REPO_ROOT" ]; then
        skip_test "already under a fixture root — generator check does not recurse"
        return 0
    fi
    if [ ! -x "$FIXROOT/.build.sh" ] && [ ! -f "$FIXROOT/.build.sh" ]; then
        # FAIL LOUD rather than skip: a missing generator is not an unavailable
        # linter, it is a deleted file the README still points at.
        assert_equals "present" "missing" "fixtures/.build.sh exists"
        return 0
    fi

    local tmp
    tmp="$(command mktemp -d)"
    # The generator derives its output root from its OWN location, so copy it
    # into the temp tree and run it there — pointing it at $FIXROOT would
    # regenerate the committed fixtures in place, which is the one thing a
    # freshness check must never do (it would make drift unobservable by
    # erasing it: dry-run-against-real-data).
    command cp "$FIXROOT/.build.sh" "$tmp/.build.sh"
    command bash "$tmp/.build.sh" >/dev/null 2>&1

    # Compare only the generated trees. `.build.sh` and README.md are hand-written
    # and are not regenerated, so they are excluded rather than expected to match.
    local drift
    drift="$(command diff -r \
        --exclude='.build.sh' --exclude='README.md' \
        "$FIXROOT" "$tmp" 2>&1 || true)"
    command rm -rf "$tmp"

    assert_output_empty "$drift" \
        "committed fixtures match .build.sh (re-run: bash tests/fixtures/classifier-lang/.build.sh)"
}

run_test test_fixtures_match_generator "committed fixtures are in sync with their generator"

generate_report
