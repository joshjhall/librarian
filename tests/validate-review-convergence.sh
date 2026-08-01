#!/usr/bin/env bash
# Coverage for plugins/workflow/scripts/review-convergence.sh (issue #596).
#
# The script owns the "keep reviewing or stop?" DECISION for the ship-issue
# multi-cycle review loop — the mechanized replacement for the fixed
# `REVIEW_MAX_CYCLES` counter, which #567's 26-cycle batch showed is both too low
# (#533's only blocking finding of the batch arrived in cycle 4) and too high
# (#564 was verifiably clean at cycle 1). A silent regression here re-opens
# exactly that: a wrong verdict either ships a defect the next cycle would have
# caught, or burns cycles on a converged review.
#
# This gate pins the deterministic decision table:
#   - the ordered first-match rule list C1..C8 (each rule reachable, order
#     load-bearing where the plan says it is),
#   - the hard cap always terminating (#596 AC#3),
#   - a partial cycle never reading as converged,
#   - the NARROW-DELTA-ZERO non-stop (#596 AC#2) — the refinement the issue turns
#     on, and the one assertion that makes this gate meaningful,
#   - env overrides moving the surface-comparability boundary,
#   - the fail-loud exit-2 paths (bad flags, bad env, unreadable/malformed JSON).
#
# ANTI-TAUTOLOGY NOTE (#599/#600). Two traps this suite is built to avoid:
#   1. A fixture that passes with AND without the predicate. Every convergence
#      case therefore asserts the exact deciding `rule`, not just `verdict` —
#      `stop` alone is satisfied by the old counter at the cap, so asserting it
#      bare would pass against code that never looked at a finding.
#   2. A pair whose two halves differ in more than the property under test. The
#      C3/C4 pair below is byte-identical apart from `--delta-lines`: SAME result
#      file, same cycle, same cap. A detector that ignores surface returns the
#      same verdict for both, so the pair cannot both pass unless the surface
#      comparison genuinely exists.
#
# Pure bash + coreutils, reached via the `command` builtin. Uses the shared
# harness assertions. bash-3.2 clean.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RC="$REPO_ROOT/plugins/workflow/scripts/review-convergence.sh"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "review-convergence.sh (#596)"

# --- Sandbox ---------------------------------------------------------------
# One temp dir holds the result-JSON fixtures. Every fixture is written once,
# here, so a case can only differ from its sibling in the flags it passes —
# which is what makes the C3/C4 pair a real differential (see the header note).

FIXTURES="$(command mktemp -d)"
trap 'command rm -rf "$FIXTURES"' EXIT

# finding <file> <line> <category> <disposition_rule> — one finding object.
finding() {
    command printf '{"file":"%s","line_start":%s,"category":"%s","disposition_rule":"%s","title":"t"}' \
        "$1" "$2" "$3" "$4"
}

# ZERO — a cycle that found nothing. The C3/C4 pair's shared input.
command printf '{"blocking":[],"deferrable":[],"clean":true}\n' >"$FIXTURES/zero.json"

# NOVEL — one real defect in new code.
command printf '{"blocking":[%s],"deferrable":[]}\n' \
    "$(finding "src/a.js" 10 correctness R8-defect-in-new-code)" >"$FIXTURES/novel.json"

# SECOND — a DIFFERENT real defect (distinct fingerprint from novel.json).
command printf '{"blocking":[%s],"deferrable":[]}\n' \
    "$(finding "src/b.js" 20 correctness R8-defect-in-new-code)" >"$FIXTURES/second.json"

# REFUTED — every finding was re-scored LOW by the fresh judge (#555 cycle 3).
command printf '{"blocking":[],"deferrable":[%s,%s]}\n' \
    "$(finding "src/c.js" 30 correctness R2-low-certainty)" \
    "$(finding "src/d.js" 40 tests R2-low-certainty)" >"$FIXTURES/refuted.json"

# MIXED-REFUTED — one refuted finding plus one live one. Must NOT stop: C5
# requires ALL findings refuted, and this pins that it is not "any".
command printf '{"blocking":[%s],"deferrable":[%s]}\n' \
    "$(finding "src/e.js" 50 correctness R8-defect-in-new-code)" \
    "$(finding "src/c.js" 30 correctness R2-low-certainty)" >"$FIXTURES/mixed-refuted.json"

# RECURSIVE — findings about test machinery the previous fix added (#498 cycle 4).
command printf '{"blocking":[%s],"deferrable":[]}\n' \
    "$(finding "tests/foo_test.sh" 5 tests R8-defect-in-new-code)" >"$FIXTURES/recursive.json"

# MIXED-DUPLICATE — a repeat of novel.json's finding PLUS a genuinely new one.
# Must NOT stop: C6 requires ALL findings duplicated. Without this fixture a C6
# of "any duplicate" survives the suite (caught by mutation testing), and that
# mutant stops the loop on the exact cycle that just surfaced a new defect.
command printf '{"blocking":[%s,%s],"deferrable":[]}\n' \
    "$(finding "src/a.js" 10 correctness R8-defect-in-new-code)" \
    "$(finding "src/b.js" 20 correctness R8-defect-in-new-code)" >"$FIXTURES/mixed-duplicate.json"

# MIXED-RECURSIVE — test machinery plus a live source defect. Must NOT stop.
command printf '{"blocking":[%s,%s],"deferrable":[]}\n' \
    "$(finding "tests/foo_test.sh" 5 tests R8-defect-in-new-code)" \
    "$(finding "src/a.js" 10 correctness R8-defect-in-new-code)" >"$FIXTURES/mixed-recursive.json"

# The delta the previous cycle's own fix produced.
command printf 'tests/foo_test.sh\nsrc/fix.js\n' >"$FIXTURES/delta-files.txt"

# A delta that does NOT contain the test file — the same recursive finding must
# then read as novel, proving C7 keys off delta membership and not merely "the
# path looks like a test".
command printf 'src/fix.js\n' >"$FIXTURES/delta-files-nontest.txt"

# val <key> <output> — echo the value of a `key=value` line from the script's
# stdout. Keeps assertions terse and independent of line order.
val() {
    command printf '%s\n' "$2" | command grep "^$1=" | command sed "s/^$1=//"
}

# --- C1: the hard cap always terminates (AC#3) ------------------------------

test_cap_stops_even_with_novel_findings() {
    local out
    out="$("$RC" check --cycle 5 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "stop" "$(val verdict "$out")" "cycle == max-cycles -> stop"
    assert_equals "C1-cap" "$(val rule "$out")" "the cap is the deciding rule, not a convergence signal"
}

test_cap_outranks_partial() {
    # C2 would say `continue` forever on a run that keeps truncating. The cap
    # must outrank it or termination is not guaranteed — this is the assertion
    # that makes AC#3 hold in the presence of the C2 safety rule.
    local out
    out="$("$RC" check --cycle 5 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --delta-lines 400 --partial true)"
    assert_equals "stop" "$(val verdict "$out")" "the cap stops a partial cycle too"
    assert_equals "C1-cap" "$(val rule "$out")" "C1 outranks C2 (termination is guaranteed)"
}

test_below_cap_does_not_stop_on_the_counter() {
    # The complement of the cap test, and the core of the issue: at cycle 4 of 5
    # — past the OLD default of 3 — novel material keeps the loop running.
    local out
    out="$("$RC" check --cycle 4 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "continue" "$(val verdict "$out")" "cycle 4 with novel findings continues (#533 shipped a defect here)"
    assert_equals "C8-novel" "$(val rule "$out")" "novel material is the deciding rule"
}

# --- C2: a partial cycle is never a convergence stop ------------------------

test_partial_zero_does_not_converge() {
    # Identical to the C4 stop case except --partial. A budget-exhausted cycle's
    # zero describes the dimensions that RAN, not the review.
    local out
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/zero.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial true)"
    assert_equals "continue" "$(val verdict "$out")" "a partial zero-finding cycle must not terminate the loop"
    assert_equals "C2-partial" "$(val rule "$out")" "C2 outranks the zero rules"
}

test_partial_refuted_does_not_converge() {
    local out
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/refuted.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial true)"
    assert_equals "continue" "$(val verdict "$out")" "a partial refuted-only cycle must not terminate the loop"
    assert_equals "C2-partial" "$(val rule "$out")" "C2 outranks C5"
}

# --- C3 vs C4: the narrow-delta-zero pair (AC#2) ----------------------------
# THE differential. Both halves pass the SAME result file (zero.json), the same
# cycle, the same cap, the same prev-delta-lines. The ONLY difference is
# --delta-lines. A predicate that ignores surface comparability cannot pass both.

test_narrow_delta_zero_does_not_stop() {
    local out
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/zero.json" \
        --delta-lines 40 --prev-delta-lines 400 --partial false)"
    assert_equals "continue" "$(val verdict "$out")" "AC#2: a zero on a 10%-of-previous surface must NOT terminate"
    assert_equals "C3-narrow-zero" "$(val rule "$out")" "the narrow-surface rule decides (#568 cycle 2)"
}

test_comparable_delta_zero_stops() {
    local out
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/zero.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "stop" "$(val verdict "$out")" "a zero on a comparable surface IS convergence"
    assert_equals "C4-zero" "$(val rule "$out")" "the comparable-surface rule decides"
}

test_narrow_and_comparable_zero_differ_only_in_surface() {
    # Guards the pair itself against drift: if a future edit made these two
    # invocations differ in anything but --delta-lines, the differential above
    # would silently stop testing the surface comparison. Assert the two verdicts
    # are OPPOSITE from otherwise-identical inputs.
    local narrow comparable
    narrow="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/zero.json" \
        --delta-lines 40 --prev-delta-lines 400 --partial false)"
    comparable="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/zero.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_true "[ \"$(val verdict "$narrow")\" != \"$(val verdict "$comparable")\" ]" \
        "the same zero-finding cycle yields opposite verdicts on narrow vs comparable surface"
}

test_zero_at_boundary_ratio_stops() {
    # Exactly at the 50% default ratio the surface is comparable (>= ratio), so a
    # zero stops. One line under it is narrow. Pins the boundary direction —
    # an off-by-one here silently converts every borderline cycle.
    local at under
    at="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/zero.json" \
        --delta-lines 200 --prev-delta-lines 400 --partial false)"
    under="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/zero.json" \
        --delta-lines 199 --prev-delta-lines 400 --partial false)"
    assert_equals "C4-zero" "$(val rule "$at")" "delta == 50% of previous is comparable -> stop"
    assert_equals "C3-narrow-zero" "$(val rule "$under")" "one line under the ratio is narrow -> continue"
}

test_cycle_one_zero_stops() {
    # #564: clean at cycle 1 on a move-only refactor. There is no predecessor, so
    # the surface is the whole diff — maximal, and a zero is real convergence.
    # Under the old counter this burned two more cycles.
    local out
    out="$("$RC" check --cycle 1 --max-cycles 5 --result "$FIXTURES/zero.json" \
        --delta-lines 400 --partial false)"
    assert_equals "stop" "$(val verdict "$out")" "a cycle-1 zero on the full diff terminates immediately (#564)"
    assert_equals "C4-zero" "$(val rule "$out")" "no predecessor -> the surface is comparable by construction"
}

test_surface_ratio_env_override_moves_the_boundary() {
    # Same 40-vs-400 inputs as the AC#2 case; a 10% ratio makes that surface
    # comparable and flips the verdict.
    local out
    out="$(REVIEW_CONVERGENCE_SURFACE_RATIO=10 "$RC" check --cycle 2 --max-cycles 5 \
        --result "$FIXTURES/zero.json" --delta-lines 40 --prev-delta-lines 400 --partial false)"
    assert_equals "stop" "$(val verdict "$out")" "RATIO=10 makes a 10% surface comparable"
    assert_equals "C4-zero" "$(val rule "$out")" "the override moves the C3/C4 boundary"
}

# --- C5: refuted-only -------------------------------------------------------

test_refuted_only_stops() {
    local out
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/refuted.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "stop" "$(val verdict "$out")" "a cycle whose findings all failed verification is converged (#555)"
    assert_equals "C5-refuted-only" "$(val rule "$out")" "the refuted-only rule decides"
    assert_equals "2" "$(val refuted "$out")" "both refuted findings are counted"
}

test_partially_refuted_continues() {
    # C5 is ALL, not ANY. One live finding alongside a refuted one is still
    # material — this is the assertion that keeps C5 from swallowing real defects.
    local out
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/mixed-refuted.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "continue" "$(val verdict "$out")" "one refuted finding among live ones is not convergence"
    assert_equals "C8-novel" "$(val rule "$out")" "novel material outlives the refuted one"
}

# --- C6: duplicate findings -------------------------------------------------

test_all_duplicate_stops() {
    local out
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --prev-result "$FIXTURES/novel.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "stop" "$(val verdict "$out")" "a cycle restating an earlier finding is converged (#533 cycle 5)"
    assert_equals "C6-duplicate" "$(val rule "$out")" "the duplicate rule decides"
    assert_equals "0" "$(val novel "$out")" "nothing novel remains"
}

test_novel_finding_against_prior_continues() {
    # Same shape as the duplicate case but a DIFFERENT fingerprint — the pair
    # proves duplication is matched on the finding, not merely on "a prior result
    # file was supplied".
    local out
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/second.json" \
        --prev-result "$FIXTURES/novel.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "continue" "$(val verdict "$out")" "a finding absent from the prior cycle is novel"
    assert_equals "C8-novel" "$(val rule "$out")" "novel material continues"
    assert_equals "1" "$(val novel "$out")" "the new finding counts as novel"
    assert_equals "0" "$(val duplicate "$out")" "and not as a duplicate"
}

test_partially_duplicate_continues() {
    # C6 is ALL, not ANY — the same discipline C5 and C7 get, and the one this
    # suite originally missed. A cycle that restates one earlier finding AND
    # surfaces a new one is still producing material; stopping there would
    # discard the new defect on the very cycle it appeared.
    local out
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/mixed-duplicate.json" \
        --prev-result "$FIXTURES/novel.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "continue" "$(val verdict "$out")" "one duplicate among novel findings is not convergence"
    assert_equals "C8-novel" "$(val rule "$out")" "novel material outlives the duplicate"
    assert_equals "1" "$(val duplicate "$out")" "the repeat is counted as a duplicate"
    assert_equals "1" "$(val novel "$out")" "and the new finding as novel"
}

test_duplicate_matches_across_all_earlier_cycles() {
    # --prev-result is repeatable: a finding that reappears after skipping a
    # cycle is still a duplicate. Matching only the immediately-preceding cycle
    # would call this novel and loop.
    local out
    out="$("$RC" check --cycle 3 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --prev-result "$FIXTURES/novel.json" --prev-result "$FIXTURES/second.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "C6-duplicate" "$(val rule "$out")" "a finding from cycle 1 is a duplicate in cycle 3"
}

# --- C7: recursive test machinery ------------------------------------------

test_recursive_test_machinery_stops() {
    local out
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/recursive.json" \
        --delta-files "$FIXTURES/delta-files.txt" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "stop" "$(val verdict "$out")" "findings about the last fix's own test machinery are converged (#498)"
    assert_equals "C7-recursive" "$(val rule "$out")" "the recursive rule decides"
}

test_test_file_outside_the_fix_delta_is_not_recursive() {
    # The differential for C7: the SAME finding in the SAME test file, but that
    # file is not in the previous fix's delta. It is then ordinary material, not
    # the no-fixed-point class — proving C7 keys off delta membership rather than
    # just a test-looking path.
    local out
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/recursive.json" \
        --delta-files "$FIXTURES/delta-files-nontest.txt" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "continue" "$(val verdict "$out")" "a test file the last fix did not touch is real material"
    assert_equals "C8-novel" "$(val rule "$out")" "not the recursive rule"
    assert_equals "0" "$(val recursive "$out")" "and not counted as recursive"
}

test_mixed_recursive_continues() {
    # C7 is ALL, not ANY — a source defect alongside the test-machinery finding
    # keeps the loop alive.
    local out
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/mixed-recursive.json" \
        --delta-files "$FIXTURES/delta-files.txt" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "continue" "$(val verdict "$out")" "a live source defect outlives a recursive test finding"
    assert_equals "C8-novel" "$(val rule "$out")" "novel material decides"
}

# --- Injection: untrusted finding text cannot forge a convergence stop ------
# Finding text originates from an LLM reviewer describing a diff, so `.file` and
# `.category` are untrusted and may carry content influenced by prompt injection
# in that diff. `jq -r` decodes JSON escapes, so an embedded `\n` would become a
# real newline and inject an extra record into the line-oriented `grep -F -x`
# layer — forging a C6 duplicate or C7 delta match, BOTH of which STOP the loop.
# The payoff of the attack is ending a review early, so these are convergence
# tests, not just parsing tests: each asserts the loop keeps going.

test_newline_in_file_cannot_forge_a_duplicate() {
    # The forged fingerprint goes FIRST, with the newline after it, so the real
    # `:line_start:category` suffix lands harmlessly on the second emitted line
    # and the first line is a byte-exact match for novel.json's fingerprint.
    # (Putting the newline before the payload does not work — the suffix would be
    # appended to the forged line and `grep -x` would miss. The distinction
    # matters: a fixture crafted the wrong way round passes with AND without the
    # sanitization, which is exactly the tautology class #599/#600 names.)
    # If the newline survives into $cur, this one finding emits two records, the
    # forged one matches $seen, duplicate reaches total, and C6 stops the loop.
    command printf '{"blocking":[{"file":"src/a.js:10:correctness\\nsrc/evil.js","line_start":99,"category":"x","disposition_rule":"R8-defect-in-new-code","title":"t"}],"deferrable":[]}\n' \
        >"$FIXTURES/inject-dup.json"
    local out
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/inject-dup.json" \
        --prev-result "$FIXTURES/novel.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "continue" "$(val verdict "$out")" "a newline-injected fingerprint must not forge a C6 stop"
    assert_equals "C8-novel" "$(val rule "$out")" "the finding is novel, not a duplicate"
    # `duplicate`, NOT `findings`: the findings counter is `jq length` over the
    # input array, so it reads 1 with and without the sanitization — asserting it
    # would be the very tautology this file's header warns about. `duplicate` is
    # what the injected record actually moves.
    assert_equals "0" "$(val duplicate "$out")" "the injected record does not register as a duplicate"
}

test_newline_in_file_cannot_forge_a_recursive_match() {
    # Same trick against C7: the injected second line is a path present in the
    # fix delta. Without sanitization the crafted record matches delta-files and
    # the loop stops as recursive-test-machinery.
    command printf '{"blocking":[{"file":"src/evil.js\\ntests/foo_test.sh","line_start":7,"category":"tests","disposition_rule":"R8-defect-in-new-code","title":"t"}],"deferrable":[]}\n' \
        >"$FIXTURES/inject-rec.json"
    local out
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/inject-rec.json" \
        --delta-files "$FIXTURES/delta-files.txt" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "continue" "$(val verdict "$out")" "a newline-injected path must not forge a C7 stop"
    assert_equals "0" "$(val recursive "$out")" "the injected test path is not counted as recursive"
}

test_newline_in_category_cannot_forge_a_duplicate() {
    # `.category` is interpolated into the same fingerprint and is equally
    # attacker-shaped; sanitizing only `.file` would leave this path open.
    command printf '{"blocking":[{"file":"src/evil.js","line_start":99,"category":"x\\nsrc/a.js:10:correctness","disposition_rule":"R8-defect-in-new-code","title":"t"}],"deferrable":[]}\n' \
        >"$FIXTURES/inject-cat.json"
    local out
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/inject-cat.json" \
        --prev-result "$FIXTURES/novel.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "continue" "$(val verdict "$out")" "a newline in .category must not forge a C6 stop"
    assert_equals "C8-novel" "$(val rule "$out")" "the finding is novel"
}

test_colon_in_file_cannot_forge_a_duplicate() {
    # The delimiter vector, distinct from the newline one: no newline is involved.
    # These two findings are structurally DIFFERENT (different file, line, and
    # category) yet colon-join to the same string when the delimiter is not
    # neutralized:
    #     A: file="src/a.js:10" line=0  cat="correctness"   -> src/a.js:10:0:correctness
    #     B: file="src/a.js"    line=10 cat="0:correctness" -> src/a.js:10:0:correctness
    # So B looks like a repeat of A, C6 fires, and the loop stops on a cycle that
    # actually surfaced new material. Note the fixture must be a genuine COLLIDING
    # PAIR — an arbitrary colon-bearing path does not collide with anything and
    # would pass with and without the fix (verified by mutation).
    command printf '{"blocking":[{"file":"src/a.js:10","line_start":0,"category":"correctness","disposition_rule":"R8-defect-in-new-code","title":"t"}],"deferrable":[]}\n' \
        >"$FIXTURES/colon-a.json"
    command printf '{"blocking":[{"file":"src/a.js","line_start":10,"category":"0:correctness","disposition_rule":"R8-defect-in-new-code","title":"t"}],"deferrable":[]}\n' \
        >"$FIXTURES/colon-b.json"
    local out
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/colon-b.json" \
        --prev-result "$FIXTURES/colon-a.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "continue" "$(val verdict "$out")" "a colon-crafted collision must not forge a C6 stop"
    assert_equals "C8-novel" "$(val rule "$out")" "the finding is novel, not a duplicate"
    assert_equals "0" "$(val duplicate "$out")" "the colliding fingerprints stay distinct"
}

test_colon_in_path_still_matches_for_recursive() {
    # The complement, and why there are TWO filters: the C7 check matches a whole
    # path line, where `:` is not a delimiter. Substituting it there would break a
    # legitimate colon-bearing path — a MISSED recursive signal. `flat` (records
    # only) must apply there, `field` (records + colons) only to the fingerprint.
    command printf 'tests/we:ird_test.sh\nsrc/fix.js\n' >"$FIXTURES/delta-colon.txt"
    command printf '{"blocking":[{"file":"tests/we:ird_test.sh","line_start":5,"category":"tests","disposition_rule":"R8-defect-in-new-code","title":"t"}],"deferrable":[]}\n' \
        >"$FIXTURES/recursive-colon.json"
    local out
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/recursive-colon.json" \
        --delta-files "$FIXTURES/delta-colon.txt" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "C7-recursive" "$(val rule "$out")" "a colon-bearing test path still matches the fix delta"
    assert_equals "1" "$(val recursive "$out")" "colon substitution must not break real path matching"
}

test_underscore_and_colon_paths_do_not_collide() {
    # #618: the ACCIDENTAL half of the collision class, distinct from the crafted
    # collision above. These two findings differ only in one character of `.file`
    # and are structurally different, yet the old `gsub(":";"_")` sanitizer — a
    # many-to-one map — sent both to the SAME fingerprint:
    #     A: file="a:b"  line=10 cat="correctness" -> a_b:10:correctness
    #     B: file="a_b"  line=10 cat="correctness" -> a_b:10:correctness
    # So B reads as a repeat of A, C6 fires, and the loop stops on a cycle that
    # surfaced new material. Underscores are far more common in real paths than
    # colons, so this needs no attacker at all. The fix is an INJECTIVE encoding;
    # this pins that the pair stays distinct.
    command printf '{"blocking":[{"file":"a:b","line_start":10,"category":"correctness","disposition_rule":"R8-defect-in-new-code","title":"t"}],"deferrable":[]}\n' \
        >"$FIXTURES/collide-colon.json"
    command printf '{"blocking":[{"file":"a_b","line_start":10,"category":"correctness","disposition_rule":"R8-defect-in-new-code","title":"t"}],"deferrable":[]}\n' \
        >"$FIXTURES/collide-underscore.json"
    local out
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/collide-underscore.json" \
        --prev-result "$FIXTURES/collide-colon.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "continue" "$(val verdict "$out")" "a:b and a_b must not collide into a C6 stop"
    assert_equals "C8-novel" "$(val rule "$out")" "the finding is novel, not a duplicate"
    assert_equals "0" "$(val duplicate "$out")" "distinct inputs keep distinct fingerprints"
}

test_percent_in_path_does_not_collide_with_an_encoded_colon() {
    # The escape alphabet must itself be injective, or the fix just relocates the
    # collision. With `%` encoded FIRST, a literal `a%3Ab` becomes `a%253Ab` while
    # `a:b` becomes `a%3Ab` — distinct. Encode `:` first and BOTH become `a%3Ab`,
    # re-forging the C6 match through the encoding that was meant to prevent it.
    # This case is what makes the substitution ORDER load-bearing rather than
    # incidental; it fails against an otherwise-correct percent-encoder.
    command printf '{"blocking":[{"file":"a%%3Ab","line_start":10,"category":"correctness","disposition_rule":"R8-defect-in-new-code","title":"t"}],"deferrable":[]}\n' \
        >"$FIXTURES/collide-percent.json"
    local out
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/collide-percent.json" \
        --prev-result "$FIXTURES/collide-colon.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "continue" "$(val verdict "$out")" "a literal %3A must not collide with an encoded colon"
    assert_equals "C8-novel" "$(val rule "$out")" "the finding is novel, not a duplicate"
    assert_equals "0" "$(val duplicate "$out")" "the escape alphabet is itself injective"
}

test_sanitization_preserves_ordinary_matching() {
    # The complement: sanitizing must not break real duplicate detection. Without
    # this, a mutation that emptied every fingerprint would pass the three
    # injection tests above by making nothing ever match.
    local out
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --prev-result "$FIXTURES/novel.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "C6-duplicate" "$(val rule "$out")" "ordinary fingerprints still match after sanitization"
}

# --- Rule-list integrity ----------------------------------------------------

test_every_rule_is_reachable() {
    # Totality + reachability: each of the eight rules must actually fire for
    # some input. A rule that can never fire is dead policy — and a rule list
    # with an unreachable branch usually means an earlier condition is too broad.
    local rules="" out
    out="$("$RC" check --cycle 5 --max-cycles 5 --result "$FIXTURES/novel.json" --delta-lines 400 --partial false)"
    rules="$rules $(val rule "$out")"
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/zero.json" --delta-lines 400 --prev-delta-lines 400 --partial true)"
    rules="$rules $(val rule "$out")"
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/zero.json" --delta-lines 40 --prev-delta-lines 400 --partial false)"
    rules="$rules $(val rule "$out")"
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/zero.json" --delta-lines 400 --prev-delta-lines 400 --partial false)"
    rules="$rules $(val rule "$out")"
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/refuted.json" --delta-lines 400 --prev-delta-lines 400 --partial false)"
    rules="$rules $(val rule "$out")"
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/novel.json" --prev-result "$FIXTURES/novel.json" --delta-lines 400 --prev-delta-lines 400 --partial false)"
    rules="$rules $(val rule "$out")"
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/recursive.json" --delta-files "$FIXTURES/delta-files.txt" --delta-lines 400 --prev-delta-lines 400 --partial false)"
    rules="$rules $(val rule "$out")"
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/novel.json" --delta-lines 400 --prev-delta-lines 400 --partial false)"
    rules="$rules $(val rule "$out")"

    assert_contains "$rules" "C1-cap" "C1 is reachable"
    assert_contains "$rules" "C2-partial" "C2 is reachable"
    assert_contains "$rules" "C3-narrow-zero" "C3 is reachable"
    assert_contains "$rules" "C4-zero" "C4 is reachable"
    assert_contains "$rules" "C5-refuted-only" "C5 is reachable"
    assert_contains "$rules" "C6-duplicate" "C6 is reachable"
    assert_contains "$rules" "C7-recursive" "C7 is reachable"
    assert_contains "$rules" "C8-novel" "C8 is reachable"
}

test_every_verdict_is_continue_or_stop() {
    # The caller branches on exactly two values; a third would fall through its
    # case and silently continue.
    local out v
    for args in \
        "--cycle 5 --max-cycles 5 --result $FIXTURES/novel.json --delta-lines 400 --partial false" \
        "--cycle 2 --max-cycles 5 --result $FIXTURES/zero.json --delta-lines 40 --prev-delta-lines 400 --partial false" \
        "--cycle 2 --max-cycles 5 --result $FIXTURES/novel.json --delta-lines 400 --partial false"; do
        # shellcheck disable=SC2086  # deliberate word-splitting of the arg string
        out="$("$RC" check $args)"
        v="$(val verdict "$out")"
        assert_true "[ \"$v\" = continue ] || [ \"$v\" = stop ]" "verdict is continue|stop, got '$v'"
    done
}

test_counts_are_reported_on_every_verdict() {
    # The counts are the audit trail for a stop; a rule that returned early
    # without them would leave a terminated review unexplainable.
    local out
    out="$("$RC" check --cycle 5 --max-cycles 5 --result "$FIXTURES/novel.json" --delta-lines 400 --partial false)"
    assert_not_empty "$(val findings "$out")" "findings count reported on a C1 stop"
    assert_not_empty "$(val novel "$out")" "novel count reported on a C1 stop"
    assert_not_empty "$(val duplicate "$out")" "duplicate count reported on a C1 stop"
    assert_not_empty "$(val refuted "$out")" "refuted count reported on a C1 stop"
    assert_not_empty "$(val recursive "$out")" "recursive count reported on a C1 stop"
}

test_deferrable_findings_count_as_material() {
    # Convergence is about whether reviewers still have MATERIAL. A deferrable
    # finding is material just as much as a blocking one — counting only
    # `blocking` would read the #580 all-deferrable cycles as converged, which is
    # the bucket that twice held a real defect.
    local out
    command printf '{"blocking":[],"deferrable":[%s]}\n' \
        "$(finding "src/z.js" 60 correctness R7-large-effort)" >"$FIXTURES/deferrable-only.json"
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/deferrable-only.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "1" "$(val findings "$out")" "a deferrable-only cycle has findings, not zero"
    assert_equals "C8-novel" "$(val rule "$out")" "and is therefore not a zero-convergence"
}

# --- Integration: the loop always terminates --------------------------------

test_loop_terminates_on_a_never_converging_review() {
    # The honest form of AC#3. A pathological review that returns novel findings
    # forever must still terminate — driven by the oracle, at the cap, in bounded
    # time. The safety bound (20 iterations) is far above the cap so a runaway is
    # caught by the assertion rather than by hanging the suite.
    local cycle=1 verdict="" out iterations=0
    while [ "$iterations" -lt 20 ]; do
        iterations=$((iterations + 1))
        out="$("$RC" check --cycle "$cycle" --max-cycles 5 --result "$FIXTURES/novel.json" \
            --delta-lines 400 --prev-delta-lines 400 --partial false)"
        verdict="$(val verdict "$out")"
        [ "$verdict" = "stop" ] && break
        cycle=$((cycle + 1))
    done
    assert_equals "stop" "$verdict" "a never-converging review is driven to stop"
    assert_equals "5" "$cycle" "it stops exactly at the cap, not before and not after"
}

test_loop_terminates_early_on_a_converged_review() {
    # The other half of the issue: the same loop, against a review that converges,
    # stops well before the cap. Without this the cap test alone would pass on
    # code that ignored every convergence signal.
    local cycle=1 verdict="" out iterations=0
    while [ "$iterations" -lt 20 ]; do
        iterations=$((iterations + 1))
        out="$("$RC" check --cycle "$cycle" --max-cycles 5 --result "$FIXTURES/zero.json" \
            --delta-lines 400 --prev-delta-lines 400 --partial false)"
        verdict="$(val verdict "$out")"
        [ "$verdict" = "stop" ] && break
        cycle=$((cycle + 1))
    done
    assert_equals "stop" "$verdict" "a converged review stops"
    assert_equals "1" "$cycle" "it stops at cycle 1, saving the remaining 4 (#564)"
}

# --- Fail-loud exits (exit 2 + message on stderr) ---------------------------

test_missing_cycle_fails_loud() {
    local rc=0 err
    err="$("$RC" check --max-cycles 5 --result "$FIXTURES/zero.json" --delta-lines 4 2>&1 >/dev/null || true)"
    "$RC" check --max-cycles 5 --result "$FIXTURES/zero.json" --delta-lines 4 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "missing --cycle exits 2"
    assert_contains "$err" "needs --cycle" "missing --cycle fails loud on stderr"
}

test_missing_delta_lines_fails_loud() {
    # The most consequential omission: defaulted to 0 it would make every zero
    # look maximally narrow and silently route to C3, granting a free extra cycle
    # every time with no signal. It must fail, not default.
    local rc=0 err
    err="$("$RC" check --cycle 1 --max-cycles 5 --result "$FIXTURES/zero.json" 2>&1 >/dev/null || true)"
    "$RC" check --cycle 1 --max-cycles 5 --result "$FIXTURES/zero.json" >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "missing --delta-lines exits 2 rather than defaulting"
    assert_contains "$err" "needs --delta-lines" "the message names the missing flag"
}

test_missing_max_cycles_fails_loud() {
    local rc=0
    "$RC" check --cycle 1 --result "$FIXTURES/zero.json" --delta-lines 4 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "missing --max-cycles exits 2 (no implicit ceiling)"
}

test_missing_result_fails_loud() {
    local rc=0
    "$RC" check --cycle 1 --max-cycles 5 --delta-lines 4 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "missing --result exits 2"
}

test_zero_cycle_fails_loud() {
    local rc=0
    "$RC" check --cycle 0 --max-cycles 5 --result "$FIXTURES/zero.json" --delta-lines 4 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "--cycle 0 exits 2 (cycles are 1-based)"
}

test_zero_max_cycles_fails_loud() {
    local rc=0
    "$RC" check --cycle 1 --max-cycles 0 --result "$FIXTURES/zero.json" --delta-lines 4 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "--max-cycles 0 exits 2 (a cap of zero reviews nothing)"
}

test_negative_delta_lines_fails_loud() {
    local rc=0
    "$RC" check --cycle 1 --max-cycles 5 --result "$FIXTURES/zero.json" --delta-lines -5 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "negative --delta-lines exits 2"
}

test_bad_partial_fails_loud() {
    local rc=0
    "$RC" check --cycle 1 --max-cycles 5 --result "$FIXTURES/zero.json" --delta-lines 4 --partial yes >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "--partial must be true|false, anything else exits 2"
}

test_unreadable_result_fails_loud() {
    local rc=0 err
    err="$("$RC" check --cycle 1 --max-cycles 5 --result "$FIXTURES/nope.json" --delta-lines 4 2>&1 >/dev/null || true)"
    "$RC" check --cycle 1 --max-cycles 5 --result "$FIXTURES/nope.json" --delta-lines 4 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "an unreadable result file exits 2, never a verdict"
    assert_contains "$err" "cannot read result file" "the message names the unreadable file"
}

test_malformed_result_fails_loud() {
    local rc=0
    command printf 'not json at all' >"$FIXTURES/bad.json"
    "$RC" check --cycle 1 --max-cycles 5 --result "$FIXTURES/bad.json" --delta-lines 4 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "malformed result JSON exits 2 rather than reading as zero findings"
}

test_valid_json_scalar_is_not_misread_as_malformed() {
    # `jq empty` is the validity probe precisely because `jq -e .` reports a valid
    # `false`/`null` document as invalid — which would fail-loud a legitimate
    # cycle result.
    local out
    command printf '{"blocking":null,"deferrable":[],"clean":false}' >"$FIXTURES/scalar.json"
    out="$("$RC" check --cycle 1 --max-cycles 5 --result "$FIXTURES/scalar.json" \
        --delta-lines 400 --partial false)"
    assert_equals "C4-zero" "$(val rule "$out")" "a null bucket is a valid empty cycle, not malformed JSON"
}

test_noninteger_line_start_fails_loud() {
    # #619: `.line_start` is interpolated into the fingerprint as a number, so it
    # never passes through the `field` encoder that guards `.file`/`.category`.
    # That asymmetry assumed FINDING_SCHEMA's integer constraint had already run —
    # but `read_findings` only checked that the document PARSES, and a result file
    # can reach this script without passing that gate. A string `line_start`
    # carrying a newline injects a second record and forges a C6 match through a
    # third field. The payload here is exactly that: the injected line is a
    # byte-exact copy of novel.json's fingerprint.
    command printf '{"blocking":[{"file":"src/evil.js","line_start":"0:x\\nsrc/a.js:10:correctness","category":"x","disposition_rule":"R8-defect-in-new-code","title":"t"}],"deferrable":[]}\n' \
        >"$FIXTURES/bad-line-start.json"
    local rc=0 err
    err="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/bad-line-start.json" \
        --prev-result "$FIXTURES/novel.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false 2>&1 >/dev/null || true)"
    "$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/bad-line-start.json" \
        --prev-result "$FIXTURES/novel.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "a non-integer line_start exits 2 rather than injecting a record"
    assert_contains "$err" "line_start" "the message names the offending field"
}

test_null_line_start_is_valid() {
    # The complement, and the anti-tautology guard for the case above: a mutation
    # that rejected EVERY document would pass that test while breaking the script
    # entirely. `line_start` is legitimately omittable — `fingerprints` defaults it
    # via `// 0` — so an absent field must still produce a verdict, not an exit 2.
    command printf '{"blocking":[{"file":"src/z.js","category":"correctness","disposition_rule":"R8-defect-in-new-code","title":"t"}],"deferrable":[]}\n' \
        >"$FIXTURES/null-line-start.json"
    local out
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/null-line-start.json" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "C8-novel" "$(val rule "$out")" "an omitted line_start still yields a verdict"
    assert_equals "1" "$(val findings "$out")" "the finding is counted, not rejected"
}

test_unreadable_prev_result_fails_loud() {
    # --prev-result goes through the same read_findings fail-loud path as
    # --result, but from inside a `while read` loop. Pin that the exit-2
    # propagates rather than being swallowed by the loop or its here-doc.
    local rc=0 err
    err="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --prev-result "$FIXTURES/gone.json" --delta-lines 400 2>&1 >/dev/null || true)"
    "$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --prev-result "$FIXTURES/gone.json" --delta-lines 400 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "an unreadable --prev-result exits 2, not a verdict computed from partial history"
    assert_contains "$err" "cannot read result file" "the message names the unreadable prior-cycle file"
}

test_malformed_prev_result_fails_loud() {
    # The parent-shell guard has TWO branches (readable, then valid JSON). The
    # unreadable one is covered above; without this the jq-empty branch could be
    # dropped in a refactor and the suite would stay green.
    local rc=0 err
    command printf 'not json at all' >"$FIXTURES/bad-prev.json"
    err="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --prev-result "$FIXTURES/bad-prev.json" --delta-lines 400 2>&1 >/dev/null || true)"
    "$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --prev-result "$FIXTURES/bad-prev.json" --delta-lines 400 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "a malformed --prev-result exits 2"
    assert_contains "$err" "not valid JSON" "the message names the malformed prior-cycle file"
}

test_unreadable_delta_files_is_silently_skipped() {
    # Deliberate asymmetry with --result/--prev-result: --delta-files is an
    # OPTIONAL enrichment for C7 only, so an absent one means "no recursive
    # signal available" and the other rules still decide. Failing loud here would
    # break cycle 1, which legitimately has no fix delta. Pinned so the asymmetry
    # is a documented decision rather than an unnoticed inconsistency.
    local out
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/recursive.json" \
        --delta-files "$FIXTURES/gone.txt" \
        --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "continue" "$(val verdict "$out")" "a missing --delta-files degrades to no recursive signal"
    assert_equals "0" "$(val recursive "$out")" "recursive stays 0 rather than failing the run"
}

test_bad_ratio_env_fails_loud() {
    local rc=0
    REVIEW_CONVERGENCE_SURFACE_RATIO=0 "$RC" check --cycle 1 --max-cycles 5 \
        --result "$FIXTURES/zero.json" --delta-lines 4 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "RATIO out of 1-100 exits 2 (a bad override never picks a wrong boundary)"
}

test_leading_zero_numerics_fail_loud() {
    # Leading-zero digit strings feed bash arithmetic as OCTAL: 030 silently
    # applies a wrong threshold, 08/09 crash past the exit-2 contract. Same guard
    # class as workflow-wall-timeout.sh.
    local rc=0
    "$RC" check --cycle 1 --max-cycles 5 --result "$FIXTURES/zero.json" --delta-lines 030 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "leading-zero --delta-lines (030) exits 2, not an octal comparison"
    rc=0
    "$RC" check --cycle 1 --max-cycles 5 --result "$FIXTURES/zero.json" --delta-lines 09 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "leading-zero --delta-lines with a 9 digit exits 2, does not crash"
    rc=0
    REVIEW_CONVERGENCE_SURFACE_RATIO=050 "$RC" check --cycle 1 --max-cycles 5 \
        --result "$FIXTURES/zero.json" --delta-lines 4 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "leading-zero RATIO (050) exits 2"
}

test_plain_zero_delta_lines_is_valid() {
    # `0` is the sole legitimate zero — an empty delta is a real state (a cycle
    # whose fix changed nothing), and the leading-zero rejection must not eat it.
    local out
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/zero.json" \
        --delta-lines 0 --prev-delta-lines 400 --partial false)"
    assert_equals "C3-narrow-zero" "$(val rule "$out")" "an empty delta is maximally narrow, and valid input"
}

test_prev_result_missing_its_value_fails_loud() {
    # `--prev-result --delta-lines 400` means the value was omitted. It must FAIL,
    # not be silently dropped: unlike the required single-value flags (whose
    # absence trips an explicit -z check), a dropped prior-cycle file is invisible
    # — the run would just see less history and drift toward novel/continue, a
    # verdict computed from silently-incomplete input.
    local rc=0 err
    err="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --prev-result --delta-lines 400 2>&1 >/dev/null || true)"
    "$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --prev-result --delta-lines 400 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "--prev-result with no value exits 2 rather than dropping the entry"
    assert_contains "$err" "needs a value" "the message says the flag needs a value"
}

test_prev_result_as_trailing_token_fails_loud() {
    # The BOUNDARY the mid-list test above misses. The `--*` guard only fires on
    # the iteration AFTER the flag, so it needs a following token to exist; a flag
    # that is the LAST argument falls off the end of the loop with an empty value
    # and no error. Same invisible drop, different route in.
    local rc=0 err
    err="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --delta-lines 400 --prev-result 2>&1 >/dev/null || true)"
    "$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --delta-lines 400 --prev-result >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "--prev-result as the last argument exits 2, not a silent empty"
    assert_contains "$err" "last argument" "the message names the trailing-flag case"
}

test_optional_flag_as_trailing_token_fails_loud() {
    # Same boundary in `opt`, and it matters MORE for the optional flags: an empty
    # --delta-files is indistinguishable from "not passed", so it silently
    # disables the C7 recursive signal rather than erroring.
    local rc=0
    "$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --delta-lines 400 --delta-files >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "--delta-files as the last argument exits 2"
}

test_optional_flag_missing_its_value_fails_loud() {
    # The mid-list half of the same guard for `opt`.
    local rc=0
    "$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --delta-files --delta-lines 400 >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "--delta-files followed by a flag exits 2"
}

test_trailing_value_is_not_mistaken_for_a_missing_one() {
    # The complement, and the reason `opt` clears `_opt_prev` on its match: a
    # perfectly ordinary call whose FINAL token is a matched flag's own value must
    # still work. Without the reset, the trailing-flag check fires on every such
    # call — which is how this guard first broke every normal invocation.
    local out
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --partial false --prev-delta-lines 400 --delta-lines 400)"
    assert_equals "continue" "$(val verdict "$out")" "a value in final position is a value, not a missing one"
    assert_equals "C8-novel" "$(val rule "$out")" "and the run proceeds normally"
}

test_duplicate_flag_is_first_match_wins() {
    # `opt` breaks on its first match, so a repeated flag's later occurrences are
    # never visited — including a dangling valueless one. The resolved value is
    # still correct (the first occurrence's), so this is deliberate, not a bug:
    # `opt_all` has no `break` because it must collect every occurrence, which is
    # why only IT needs the trailing guard to catch a dangling repeat. Pinned so
    # the asymmetry between the two parsers is a documented decision.
    local out
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/novel.json" \
        --delta-lines 400 --delta-lines --partial false)"
    assert_equals "continue" "$(val verdict "$out")" "a duplicate flag resolves from the first occurrence"
    assert_equals "C8-novel" "$(val rule "$out")" "and the run proceeds on that value"
}

test_empty_string_value_behaves_as_absent() {
    # An explicit `--delta-files ''` is indistinguishable downstream from omitting
    # the flag (`-z` is true either way), so the C7 recursive signal degrades
    # silently. That is acceptable for an OPTIONAL enrichment — cycle 1 has no fix
    # delta at all — but the comments discussed it without pinning it. Now pinned.
    local out
    out="$("$RC" check --cycle 2 --max-cycles 5 --result "$FIXTURES/recursive.json" \
        --delta-files "" --delta-lines 400 --prev-delta-lines 400 --partial false)"
    assert_equals "continue" "$(val verdict "$out")" "an empty --delta-files degrades like an absent one"
    assert_equals "0" "$(val recursive "$out")" "no recursive signal, and no hard failure"
}

test_unknown_subcommand_fails_loud() {
    local rc=0
    "$RC" bogus >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "unknown subcommand exits 2"
}

test_no_subcommand_fails_loud() {
    local rc=0
    "$RC" >/dev/null 2>&1 || rc=$?
    assert_exit "2" "$rc" "no subcommand exits 2"
}

run_test test_cap_stops_even_with_novel_findings "C1: the cap stops a still-productive review"
run_test test_cap_outranks_partial "C1 outranks C2 (termination guaranteed)"
run_test test_below_cap_does_not_stop_on_the_counter "cycle 4 with novel findings continues (#533)"
run_test test_partial_zero_does_not_converge "C2: a partial zero never converges"
run_test test_partial_refuted_does_not_converge "C2 outranks C5"
run_test test_narrow_delta_zero_does_not_stop "C3: AC#2 narrow-delta zero does NOT stop"
run_test test_comparable_delta_zero_stops "C4: comparable-surface zero stops"
run_test test_narrow_and_comparable_zero_differ_only_in_surface "C3/C4 differ only in surface (anti-tautology)"
run_test test_zero_at_boundary_ratio_stops "C3/C4 boundary is at the ratio exactly"
run_test test_cycle_one_zero_stops "cycle-1 zero stops immediately (#564)"
run_test test_surface_ratio_env_override_moves_the_boundary "RATIO override moves the C3/C4 boundary"
run_test test_refuted_only_stops "C5: refuted-only stops (#555)"
run_test test_partially_refuted_continues "C5 is ALL, not ANY"
run_test test_all_duplicate_stops "C6: all-duplicate stops (#533 cycle 5)"
run_test test_novel_finding_against_prior_continues "C6 matches the finding, not the flag"
run_test test_partially_duplicate_continues "C6 is ALL, not ANY"
run_test test_duplicate_matches_across_all_earlier_cycles "C6 matches across all earlier cycles"
run_test test_recursive_test_machinery_stops "C7: recursive test machinery stops (#498)"
run_test test_test_file_outside_the_fix_delta_is_not_recursive "C7 keys off delta membership"
run_test test_mixed_recursive_continues "C7 is ALL, not ANY"
run_test test_every_rule_is_reachable "every rule C1-C8 is reachable"
run_test test_every_verdict_is_continue_or_stop "verdict is always continue|stop"
run_test test_counts_are_reported_on_every_verdict "counts reported on every verdict"
run_test test_deferrable_findings_count_as_material "deferrables count as material (#580)"
run_test test_loop_terminates_on_a_never_converging_review "a never-converging loop stops at the cap (AC#3)"
run_test test_loop_terminates_early_on_a_converged_review "a converged loop stops early (AC#1)"
run_test test_missing_cycle_fails_loud "missing --cycle -> exit 2"
run_test test_missing_delta_lines_fails_loud "missing --delta-lines -> exit 2, never defaulted"
run_test test_missing_max_cycles_fails_loud "missing --max-cycles -> exit 2"
run_test test_missing_result_fails_loud "missing --result -> exit 2"
run_test test_zero_cycle_fails_loud "--cycle 0 -> exit 2"
run_test test_zero_max_cycles_fails_loud "--max-cycles 0 -> exit 2"
run_test test_negative_delta_lines_fails_loud "negative --delta-lines -> exit 2"
run_test test_bad_partial_fails_loud "bad --partial -> exit 2"
run_test test_unreadable_result_fails_loud "unreadable --result -> exit 2"
run_test test_malformed_result_fails_loud "malformed result JSON -> exit 2"
run_test test_valid_json_scalar_is_not_misread_as_malformed "jq empty, not jq -e, is the validity probe"
run_test test_newline_in_file_cannot_forge_a_duplicate "injection: newline in .file cannot forge a C6 stop"
run_test test_newline_in_file_cannot_forge_a_recursive_match "injection: newline in .file cannot forge a C7 stop"
run_test test_newline_in_category_cannot_forge_a_duplicate "injection: newline in .category cannot forge a C6 stop"
run_test test_colon_in_file_cannot_forge_a_duplicate "injection: colon in .file cannot forge a C6 stop"
run_test test_colon_in_path_still_matches_for_recursive "colon substitution does not break C7 path matching"
run_test test_underscore_and_colon_paths_do_not_collide "injective: a:b and a_b do not collide (#618)"
run_test test_percent_in_path_does_not_collide_with_an_encoded_colon "injective: the escape alphabet is itself injective (#618)"
run_test test_sanitization_preserves_ordinary_matching "sanitization preserves real duplicate matching"
run_test test_noninteger_line_start_fails_loud "non-integer line_start -> exit 2 (#619)"
run_test test_null_line_start_is_valid "an omitted line_start is still valid (#619)"
run_test test_unreadable_prev_result_fails_loud "unreadable --prev-result -> exit 2"
run_test test_malformed_prev_result_fails_loud "malformed --prev-result -> exit 2"
run_test test_unreadable_delta_files_is_silently_skipped "missing --delta-files degrades, by design"
run_test test_bad_ratio_env_fails_loud "bad RATIO env -> exit 2"
run_test test_leading_zero_numerics_fail_loud "leading-zero numerics -> exit 2 (octal guard)"
run_test test_plain_zero_delta_lines_is_valid "plain 0 --delta-lines is valid"
run_test test_prev_result_missing_its_value_fails_loud "--prev-result with no value -> exit 2"
run_test test_prev_result_as_trailing_token_fails_loud "--prev-result as the LAST argument -> exit 2"
run_test test_optional_flag_as_trailing_token_fails_loud "--delta-files as the LAST argument -> exit 2"
run_test test_optional_flag_missing_its_value_fails_loud "--delta-files with no value -> exit 2"
run_test test_trailing_value_is_not_mistaken_for_a_missing_one "a value in final position still parses"
run_test test_duplicate_flag_is_first_match_wins "a duplicate flag is first-match-wins (documented)"
run_test test_empty_string_value_behaves_as_absent "an empty optional value degrades, by design"
run_test test_unknown_subcommand_fails_loud "unknown subcommand -> exit 2"
run_test test_no_subcommand_fails_loud "no subcommand -> exit 2"

# Every `test_*` function defined above must actually be dispatched by a
# `run_test` line. A test that is written but never registered passes silently by
# not running at all — which is strictly worse than a missing test, because the
# suite's green summary asserts coverage that does not exist. (This gate was added
# after exactly that happened here: test_malformed_prev_result_fails_loud sat
# defined-but-unregistered and the total stayed put at 48.)
check_every_test_is_registered() {
    # Compare NAME SETS, not counts. A bare count is satisfied by two errors that
    # cancel — registering one test twice while another is never registered keeps
    # the totals equal and the guard green, which is precisely the failure it
    # exists to catch. `comm` on the sorted name lists cannot be fooled that way.
    # This guard itself is dispatched by a `run_test check_every_...` line,
    # deliberately outside the `test_*` namespace so it need not count itself.
    local defined registered unregistered undefined
    defined="$(command grep -o '^test_[a-z_]*() {' "$0" | command sed 's/() {$//' | command sort -u)"
    registered="$(command grep -o '^run_test test_[a-z_]*' "$0" | command sed 's/^run_test //' | command sort -u)"
    unregistered="$(command comm -23 <(command printf '%s\n' "$defined") <(command printf '%s\n' "$registered") | command tr '\n' ' ')"
    undefined="$(command comm -13 <(command printf '%s\n' "$defined") <(command printf '%s\n' "$registered") | command tr '\n' ' ')"
    assert_equals "" "$(command printf '%s' "$unregistered")" \
        "no test_* function is defined but never dispatched (unregistered: $unregistered)"
    assert_equals "" "$(command printf '%s' "$undefined")" \
        "no run_test dispatches a name that does not exist (undefined: $undefined)"
}
run_test check_every_test_is_registered "no test is defined-but-unregistered"

generate_report
