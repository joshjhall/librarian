#!/usr/bin/env bash
# review-route.sh extension-table consistency (#913, ADR 0002).
#
# WHAT THIS GATES, AND WHY IT IS ITS OWN FILE.
#
# `plugins/workflow/scripts/review-route.sh` carries a `classify()` whose
# extension table is, by ADR 0002, required to be a SUBSET of the normative
# EXT_LANG in check-decomposition/loc_engine.py: it may cover FEWER extensions,
# never CONTRADICT them. `tests/lint-language-table-sync.sh` is the gate for that
# drift class, but its GOVERNED tuple names the four `check-*` scanners only, and
# its machinery is shaped around a `patterns.{py,sh}` pair plus a
# `## Language Support` contract matrix. review-route.sh has neither, so
# enrolling it there means bolting a second shape onto an already-large gate.
# Hence a narrow sibling — the issue's Option 2.
#
# WHY THIS TABLE IS WORTH A GATE OF ITS OWN. review-route.sh decides whether the
# ship-issue review fan-out RUNS AT ALL, and its failure direction is fail-open
# and silent. An extension EXT_LANG calls a source language, misclassified `doc`
# here, routes the diff `cheap` (R7), drops the `security` and `correctness`
# dimensions — and the cycle stays eligible to return `clean: true` and merge.
# PR #908's history is the argument rather than a hypothetical: four separate
# review cycles each found a different disguise of that one class.
#
# ---------------------------------------------------------------------------
# THE CONTRADICTION RULE, stated once.
#
#   EXT_LANG lang `md`  =>  classify() must return `doc`
#   every other lang    =>  classify() must return `source`
#
# `unknown` is NEVER a contradiction. It is review-route.sh's documented
# fail-safe: R3 treats an unrecognized extension as POSSIBLY SOURCE and forces
# the full fan-out. A gate that punished `unknown` would pressure an author
# toward classifying a doubtful extension `doc` or `config` — i.e. toward the
# fail-open direction this gate exists to close. So `unknown` is silent here.
#
# WHAT THIS GATE ASSERTS
#
#   1. ANTI-VACUITY: the normative EXT_LANG was found and is populated.
#   2. ANTI-VACUITY: classify() resolved and its source/doc/config arms are all
#      non-empty. Without this, a renamed function or a reshaped `case` makes
#      every assertion below compare against EMPTY SETS and pass for free —
#      which is the silence-reads-as-a-pass shape (#538, #571) this repo keeps
#      filing issues about.
#   3. NO CONTRADICTION: every extension classify() dispatches on that EXT_LANG
#      also knows lands in the class the rule above implies. Reported WITH ITS
#      DIRECTION, because the two directions are not equally dangerous: a source
#      language classified doc/config is the FAIL-OPEN one (it reaches
#      `clean: true`); the inverse merely over-reviews. ADR 0002 forbids
#      contradiction either way, so both are reported and the row says which.
#   4. SUBSET: every extension in the `source` arm exists in EXT_LANG. The
#      script's own header states exactly this list
#      (py/js/jsx/mjs/cjs/ts/tsx/rs/go/sh/bash/swift); assertion 4 makes that
#      claim testable rather than narrated.
#   5. DECLARED DOC: every extension in the `doc` arm that EXT_LANG does NOT
#      govern must be listed in UNGOVERNED_DOC below. This is what catches the
#      residual fail-open case assertion 3 structurally CANNOT see — adding
#      `.rb` to the doc arm contradicts nothing, because EXT_LANG has no opinion
#      about `.rb`, yet it routes Ruby source down the cheap path.
#      SCOPED to exactly that residual set: an extension EXT_LANG knows is
#      assertion 3's to report, with the direction named. One defect, one row.
#
# THE RESIDUAL LIMIT, recorded rather than papered over: EXT_LANG cannot
# adjudicate an extension it does not model, so assertion 3 is silent on every
# such extension by construction. Assertions 4 and 5 bound the two arms where
# that silence would be dangerous (source must be governed; doc must be governed
# or explicitly declared). The `config` arm is deliberately unbounded — R5 forces
# `full` for config regardless, so a wrong entry there costs review budget, never
# safety.
#
# Pure bash + coreutils + python3. No network. bash-3.2 clean and BSD-regex
# clean, per CLAUDE.md § Key conventions (runtime policy).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "review-route.sh extension-table consistency (#913)"

# Overridable so the negative fixtures can point the gate at a synthetic tree.
# Defaults to the real repo. Same mechanism, and same reason, as LANG_TABLE_ROOT
# in tests/lint-language-table-sync.sh.
REVIEW_ROUTE_LANG_ROOT="${REVIEW_ROUTE_LANG_ROOT:-$REPO_ROOT}"

# This gate parses a Python dict literal and a bash `case` block with python3
# (both grammars are beyond a portable grep). A missing runtime is an UNAVAILABLE
# LINTER, so it exits the reserved 77 sentinel rather than 0 — run-all.sh renders
# 77 as "[SKIP] ... did not run", because a silent skip is indistinguishable from
# a pass and is how a gate sits inert unnoticed (#538, #571).
if ! command -v python3 >/dev/null 2>&1; then
    skip_test "python3 not available (review-route extension table not checked)"
    generate_report
    exit 77
fi

# The analyzer prints one finding per line, each prefixed by a tag the tests
# below filter on. Run once; every assertion reads this one report.
#
#   NORMATIVE <count>        — size of the normative EXT_LANG
#   ARMS <class> <count>     — extensions found in one classify() arm
#   NOCLASSIFY               — assertion 2 violation (classify() unresolvable)
#   CONTRADICTION <detail>   — assertion 3 violation
#   UNGOVERNED <detail>      — assertion 4 violation
#   UNDECLARED <detail>      — assertion 5 violation
ROUTE_REPORT="$(
    command python3 - "$REVIEW_ROUTE_LANG_ROOT" <<'PY'
import os
import re
import sys

ROOT = sys.argv[1]
PLUGINS = os.path.join(ROOT, "plugins")

NORMATIVE_SRC = os.path.join(
    PLUGINS, "review-audit", "skills", "check-decomposition", "loc_engine.py"
)
SUBJECT_SRC = os.path.join(PLUGINS, "workflow", "scripts", "review-route.sh")

# Prose formats the normative table does not model, and legitimately need not:
# EXT_LANG exists to drive check-decomposition's SEGMENTERS, and nothing segments
# reStructuredText or AsciiDoc. They are genuine documentation formats, so
# classifying them `doc` is correct even though EXT_LANG cannot say so.
#
# EXPLICIT AND HAND-MAINTAINED, never a pattern — same discipline and same
# reason as GOVERNED and BINDINGS in tests/lint-language-table-sync.sh, and as
# the tests/lib/fragments.sh manifests. A regex like "anything ending in a known
# prose suffix" would silently absorb the next `.rb` someone adds to the doc arm,
# which is exactly the defect assertion 5 exists to catch. Adding an entry here
# is a deliberate edit that says "this is prose, and EXT_LANG has no opinion".
UNGOVERNED_DOC = ("rst", "adoc")


def read(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


# --- the normative table -----------------------------------------------------
# Parsed out of loc_engine.py's EXT_LANG literal rather than imported: this gate
# must not execute scanner code, and the literal is a flat str->str dict closed
# by a column-zero `}` — a shape tests/validate-shared-scanner-sync.sh already
# enforces. Same recipe as the sibling gate, deliberately, so the two read the
# normative table identically.
def parse_ext_lang(src):
    m = re.search(r"^EXT_LANG\s*=\s*\{(.*?)^\}", src, re.M | re.S)
    if not m:
        return {}
    return dict(re.findall(r'"([A-Za-z0-9]+)"\s*:\s*"([A-Za-z0-9]+)"', m.group(1)))


normative = {}
if os.path.exists(NORMATIVE_SRC):
    normative = parse_ext_lang(read(NORMATIVE_SRC))
print("NORMATIVE %d" % len(normative))

# --- the subject: classify()'s terminal arms --------------------------------
# The region is `classify() {` through the next COLUMN-ZERO `}`. Anchoring the
# close at column zero matters for the same reason it does in the sibling gate's
# sh_arms(): an indented `}` inside the body (a `${var}` expansion, a nested
# block) would otherwise end the region early and silently truncate the table —
# the gate would then compare against a SUBSET of the real arms and pass over
# whatever it dropped.
BRACKET = re.compile(r"\[([A-Za-z])[A-Za-z]\]")
ARM = re.compile(r"^\s*(\*\.[A-Za-z0-9\[\]]+(?:\s*\|\s*\*\.[A-Za-z0-9\[\]]+)*)\)")


def classify_region(src):
    """The body of classify(), or None when it does not resolve."""
    lines = src.splitlines()
    start = None
    for i, line in enumerate(lines):
        if re.match(r"^classify\s*\(\)\s*\{", line):
            start = i + 1
            break
    if start is None:
        return None
    for j in range(start, len(lines)):
        if re.match(r"^\}", lines[j]):
            return lines[start:j]
    return None


def pats_to_exts(patterns):
    """`*.[Jj][Ss] | *.ts` -> {'js', 'ts'}. Bracket classes collapsed."""
    out = set()
    for pat in patterns.split("|"):
        pat = pat.strip()
        if not pat.startswith("*."):
            continue
        out.add(BRACKET.sub(lambda m: m.group(1).lower(), pat[2:]).lower())
    return out


def arm_classes(body):
    """{class: {ext, ...}} for each `*.ext)` arm, keyed by the class its body
    prints.

    THE ARM -> CLASS BINDING IS READ FROM THE SOURCE, never assumed from the
    arm's position in the file. Reordering the arms (or adding one) must not
    change what this gate believes each arm means — an assumption about order
    would make the gate silently wrong the first time someone tidies the `case`,
    and wrong in the direction of reporting nothing.

    Arms with no `printf '<class>'` in their body — the path-anchored carve-outs
    that `return 0` early — are attributed to no class, which is correct: they
    dispatch on a PATH SHAPE, not an extension, and assertion 3 has nothing to
    say about them.
    """
    out = {}
    for i, line in enumerate(body):
        m = ARM.match(line)
        if not m:
            continue
        exts = pats_to_exts(m.group(1))
        if not exts:
            continue
        # The arm's body runs to `;;` — which may sit on the pattern line itself.
        # Same hazard, and same same-line-first ordering, as sh_arms() in
        # tests/lint-language-table-sync.sh: scanning forward unconditionally
        # runs past such an arm and absorbs its successor's class.
        rest = line[m.end():]
        if ";;" in rest:
            chunk = rest.split(";;")[0]
        else:
            collected = [rest]
            for nxt in body[i + 1:]:
                if ";;" in nxt:
                    collected.append(nxt.split(";;")[0])
                    break
                collected.append(nxt)
            chunk = "\n".join(collected)
        found = re.search(r"printf\s+'(source|doc|config|unknown)", chunk)
        if not found:
            continue
        out.setdefault(found.group(1), set()).update(exts)
    return out


arms = {}
if os.path.exists(SUBJECT_SRC):
    region = classify_region(read(SUBJECT_SRC))
    if region is None:
        print("NOCLASSIFY")
    else:
        arms = arm_classes(region)
else:
    print("NOCLASSIFY")

for cls in ("source", "doc", "config"):
    print("ARMS %s %d" % (cls, len(arms.get(cls, ()))))

# --- assertion 3: no contradiction with the normative table ------------------
# `unknown` is excluded from this walk on purpose — see the header. It is the
# fail-safe direction, and flagging it would push edits the wrong way.
IMPLIED = {"md": "doc"}

for cls in ("source", "doc", "config"):
    for ext in sorted(arms.get(cls, ())):
        lang = normative.get(ext)
        if lang is None:
            continue  # EXT_LANG has no opinion; assertions 4/5 bound this
        want = IMPLIED.get(lang, "source")
        if want == cls:
            continue
        # Name the DIRECTION. A source language routed doc/config is the
        # fail-open one: it reaches the cheap path and stays eligible for
        # clean: true. The inverse only costs review budget. A reader triaging
        # this row needs to know which they are looking at.
        # The label is DERIVED from the two classes, never hardcoded per branch.
        # An earlier spelling assumed the only non-fail-open case was "doc routed
        # as source" and said so literally — which mislabelled markdown routed as
        # `config`, the one cell no fixture drove at the time. The evidence string
        # is what a triaging reader acts on, so it must describe the actual pair.
        if want == "source":
            direction = "FAIL-OPEN (source routed %s, skips the expensive dimensions)" % cls
        else:
            direction = "over-review (%s routed %s)" % (want, cls)
        print(
            "CONTRADICTION .%s classified %r, normative lang %r implies %r — %s"
            % (ext, cls, lang, want, direction)
        )

# --- assertion 4: the source arm is a SUBSET of the normative table ----------
for ext in sorted(arms.get("source", ())):
    if ext not in normative:
        print(
            "UNGOVERNED .%s is in the source arm but absent from the normative "
            "EXT_LANG — the subset claim in review-route.sh's header is false"
            % ext
        )

# --- assertion 5: every doc-arm extension is governed or declared ------------
# SCOPED TO WHAT ASSERTION 3 CANNOT ADJUDICATE, and the narrowing is the point
# rather than tidiness. An extension EXT_LANG DOES know is assertion 3's to
# report: it fires with the direction named, which is strictly more informative
# than "undeclared". Without the skip below, `.rs` in the doc arm fired BOTH
# rows for one defect — and this file's own header described assertion 5 as
# covering only the residual case, so the comment claimed a narrower check than
# the code performed. That is the comment-asserts-intent-not-code shape, here in
# the gate written to enforce a different instance of it.
#
# It also makes "each fixture arms exactly one assertion" TRUE of this fixture
# set rather than merely intended — the self-tests below assert that exclusivity
# in both directions.
for ext in sorted(arms.get("doc", ())):
    lang = normative.get(ext)
    if lang is not None:
        # Governed by the normative table: `md` is correct here, and anything
        # else is assertion 3's CONTRADICTION to report.
        continue
    if ext in UNGOVERNED_DOC:
        continue
    print(
        "UNDECLARED .%s is in the doc arm, is absent from the normative "
        "EXT_LANG, and is not listed in UNGOVERNED_DOC — nothing can confirm "
        "it is prose, and a non-prose extension classified doc routes its "
        "diff cheap" % ext
    )
PY
)"

# report_lines TAG — echo the report rows carrying TAG, or nothing.
report_lines() {
    command printf '%s\n' "$ROUTE_REPORT" | command grep -E "^$1( |$)" || true
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

# --- Assertion 2: anti-vacuity, the subject ---------------------------------
# TWO halves. classify() must RESOLVE, and each of its three classified arms must
# be non-empty. Either failure leaves assertions 3-5 comparing against empty sets
# — green for the worst possible reason.
test_classify_resolves() {
    local bad
    bad="$(report_lines NOCLASSIFY)"
    assert_output_empty "$bad" \
        "review-route.sh's classify() resolves (anti-vacuity)"
}

test_classify_arms_non_empty() {
    local line cls count nonempty
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        cls="$(command printf '%s' "$line" | command awk '{print $2}')"
        count="$(command printf '%s' "$line" | command awk '{print $3}')"
        if [ "$count" -gt 0 ] 2>/dev/null; then
            nonempty="yes"
        else
            nonempty="no"
        fi
        assert_equals "yes" "$nonempty" \
            "classify()'s $cls arm dispatches on at least one extension (got $count)"
    done <<EOF
$(report_lines ARMS)
EOF
}

# --- Assertion 3: no contradiction with the normative table ------------------
# NOTE — these use assert_output_empty, NOT assert_true, and that is the same
# security property tests/lint-language-table-sync.sh records: assert_true EVALs
# its command string (tests/lib/harness.sh: `eval "$cmd"`). Every value here is
# analyzer-derived, and assert_output_empty takes it as a PARAMETER.
test_no_contradiction() {
    local bad
    bad="$(report_lines CONTRADICTION)"
    assert_output_empty "$bad" \
        "no classify() arm contradicts the normative EXT_LANG"
}

# --- Assertion 4: the source arm is a subset --------------------------------
test_source_arm_is_subset() {
    local bad
    bad="$(report_lines UNGOVERNED)"
    assert_output_empty "$bad" \
        "every source-arm extension exists in the normative EXT_LANG"
}

# --- Assertion 5: every doc-arm extension is governed or declared ------------
test_doc_arm_declared() {
    local bad
    bad="$(report_lines UNDECLARED)"
    assert_output_empty "$bad" \
        "every doc-arm extension is markdown in EXT_LANG or declared ungoverned"
}

run_test test_normative_table_populated "normative EXT_LANG is populated (anti-vacuity)"
run_test test_classify_resolves "classify() resolves (anti-vacuity)"
run_test test_classify_arms_non_empty "each classify() arm dispatches on something"
run_test test_no_contradiction "no classify() arm contradicts the normative table"
run_test test_source_arm_is_subset "the source arm is a subset of the normative table"
run_test test_doc_arm_declared "every doc-arm extension is governed or declared"

# --- Self-tests: each assertion actually fires -------------------------------
#
# The five assertions above are green on this tree, which is necessary and proves
# nothing on its own — a detector that never fires is green too, and that is this
# repo's most-recorded failure mode (#596, #599, #600). So each is re-run against
# a committed negative fixture that arms IT and only it.
#
# Committed trees under tests/fixtures/review-route-lang/, not transient
# mutations, for the reason tests/fixtures/language-table/ is committed: the
# proof has to re-run on every future invocation, not only on the day it was
# written.
FIXROOT="$SCRIPT_DIR/fixtures/review-route-lang"

# selftest_report FIXTURE — this gate's own output against one fixture tree, via
# a recursive call with REVIEW_ROUTE_LANG_ROOT redirected. Callers grep it for
# the specific failing assertion.
selftest_report() {
    REVIEW_ROUTE_LANG_ROOT="$FIXROOT/$1" \
        command bash "$SCRIPT_DIR/$(command basename "${BASH_SOURCE[0]}")" 2>&1 || true
}

test_selftest_fixtures() {
    if [ "$REVIEW_ROUTE_LANG_ROOT" != "$REPO_ROOT" ]; then
        skip_test "already under a fixture root — self-tests do not recurse"
        return 0
    fi

    local out

    out="$(selftest_report empty-normative)"
    assert_contains "$out" "normative EXT_LANG is populated (anti-vacuity) ... FAIL" \
        "empty-normative fixture must fail the normative-table assertion"

    out="$(selftest_report no-classify)"
    assert_contains "$out" "classify() resolves (anti-vacuity) ... FAIL" \
        "no-classify fixture must fail the classify-resolution assertion"

    # The fail-open direction, and the one AC1 names verbatim: a source language
    # classified `doc` routes its diff cheap and stays eligible for clean: true.
    out="$(selftest_report contradiction-doc)"
    assert_contains "$out" "no classify() arm contradicts the normative table ... FAIL" \
        "contradiction-doc fixture must fail the no-contradiction assertion"
    assert_contains "$out" "FAIL-OPEN (source routed doc" \
        "contradiction-doc fixture must name the direction as fail-open"
    # Exclusivity, and it pins a real narrowing rather than restating the row
    # above. `.rs` is in the DOC arm here, so assertion 5's predicate would match
    # it too — and did, until it was scoped to the extensions EXT_LANG cannot
    # adjudicate. One defect must produce ONE row, and it must be assertion 3's,
    # which names the direction; "undeclared" would be the strictly less
    # informative of the two.
    assert_contains "$out" "every doc-arm extension is governed or declared ... PASS" \
        "contradiction-doc fixture must arm ONLY assertion 3, not also the doc-declaration check"

    out="$(selftest_report contradiction-config)"
    assert_contains "$out" "no classify() arm contradicts the normative table ... FAIL" \
        "contradiction-config fixture must fail the no-contradiction assertion"
    assert_contains "$out" "the source arm is a subset of the normative table ... PASS" \
        "contradiction-config fixture must arm ONLY assertion 3"
    assert_contains "$out" "every doc-arm extension is governed or declared ... PASS" \
        "contradiction-config fixture must not also trip the doc-declaration check"

    # The SAFE direction is still a contradiction — ADR 0002 forbids it either
    # way. Asserting the direction label here is what keeps this fixture from
    # collapsing into a restatement of contradiction-doc: a gate that reported
    # every row as fail-open would satisfy that one and fail this.
    out="$(selftest_report contradiction-inverse)"
    assert_contains "$out" "no classify() arm contradicts the normative table ... FAIL" \
        "contradiction-inverse fixture must fail the no-contradiction assertion"
    assert_contains "$out" "over-review (doc routed source)" \
        "contradiction-inverse fixture must name the direction as over-review"
    # `.md` sits in the SOURCE arm here, so assertion 4's predicate is the one
    # that could plausibly also trip — and must not: `md` IS in EXT_LANG, so the
    # subset claim holds and only the class is wrong.
    assert_contains "$out" "the source arm is a subset of the normative table ... PASS" \
        "contradiction-inverse fixture must arm ONLY assertion 3"
    assert_contains "$out" "every doc-arm extension is governed or declared ... PASS" \
        "contradiction-inverse fixture must not also trip the doc-declaration check"

    # The remaining cell of the matrix: `want == "doc"` with `cls == "config"`.
    # The three fixtures above all drive `want == "source"`, so this branch —
    # and the direction label it computes — was reachable by nothing. It caught a
    # real bug on its first run: the label was hardcoded "doc routed as source"
    # and mislabelled exactly this case. Assert the FULL string, not the
    # "over-review" prefix, or the fixture cannot see a wrong pair.
    out="$(selftest_report contradiction-md-config)"
    assert_contains "$out" "no classify() arm contradicts the normative table ... FAIL" \
        "contradiction-md-config fixture must fail the no-contradiction assertion"
    assert_contains "$out" "over-review (doc routed config)" \
        "contradiction-md-config fixture must name the ACTUAL class pair, not a hardcoded one"
    assert_contains "$out" "the source arm is a subset of the normative table ... PASS" \
        "contradiction-md-config fixture must arm ONLY assertion 3"
    assert_contains "$out" "every doc-arm extension is governed or declared ... PASS" \
        "contradiction-md-config fixture must not also trip the doc-declaration check"

    out="$(selftest_report source-not-normative)"
    assert_contains "$out" "the source arm is a subset of the normative table ... FAIL" \
        "source-not-normative fixture must fail the subset assertion"
    # Narrowness: the extension is absent from EXT_LANG, so assertion 3 has
    # nothing to say about it. Without this the fixture passes just as well
    # against a gate that flags an ungoverned extension as a contradiction —
    # which would be the gate punishing `unknown`, the direction the header
    # forbids.
    assert_contains "$out" "no classify() arm contradicts the normative table ... PASS" \
        "source-not-normative fixture must arm ONLY the subset assertion"

    # The residual fail-open case assertion 3 structurally cannot see: `.rb` is
    # absent from EXT_LANG, so nothing contradicts, yet Ruby source would route
    # cheap. This is the fixture that justifies assertion 5 existing at all.
    out="$(selftest_report undeclared-doc)"
    assert_contains "$out" "every doc-arm extension is governed or declared ... FAIL" \
        "undeclared-doc fixture must fail the doc-declaration assertion"
    assert_contains "$out" "no classify() arm contradicts the normative table ... PASS" \
        "undeclared-doc fixture must arm ONLY the doc-declaration assertion"

    # The ONE POSITIVE fixture — it must PASS, where every other arms a failure.
    # That inversion is the point: it pins that a CORRECT table produces no
    # finding, so a gate that simply failed everything could not satisfy the
    # negatives above and this one at once. The reached-PASS line is what makes
    # it more than "did not crash".
    out="$(selftest_report clean)"
    assert_not_contains "$out" "FAIL" \
        "clean fixture must pass — a correct table must produce no finding"
    assert_contains "$out" "no classify() arm contradicts the normative table ... PASS" \
        "clean fixture must actually REACH the no-contradiction assertion"
}

run_test test_selftest_fixtures "self-test: each assertion fires on its fixture"

generate_report
