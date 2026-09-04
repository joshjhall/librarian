#!/usr/bin/env bash
# Pre-scan input-shape guard gate (#816).
#
# Every pre-scan tool takes a FILE LIST -- paths, one per line -- as its first
# argument. Handed a DIFF instead, the scan loop reads each diff line as a path,
# matches nothing, emits nothing, and exits 0. That output is byte-identical to
# a genuinely clean scan, and it is a pre-SHIP gate, so the cost is a PR opened
# on a diff nobody scanned. It happened for real in #809.
#
# #816 added a guard (assert_file_list_shape) to every entry point. This gate is
# what keeps it there. Three properties make a structural gate the right shape,
# rather than per-file behavioral fixtures:
#
#   - The defect is SILENT. A removed guard emits no error and changes no exit
#     code on a correct invocation; the tool simply goes back to reporting a
#     clean scan of nothing. Nothing fails until someone ships an unscanned PR.
#   - It is PER-FILE and there are 39 of them, across two runtimes and three
#     independently-installed plugins. Pinning each with its own diff fixture is
#     39x2 fixtures that all assert the same one sentence.
#   - It SPREADS BY COPY. A new scanner is written by copying a neighbour. Copy a
#     pre-#816 neighbour -- or a post-#816 one whose guard someone dropped in a
#     refactor -- and the gap is reintroduced in a file no fixture scans.
#
# The BEHAVIOR (a diff exits 1, a stale list warns and exits 0, an empty list
# stays silent) is pinned separately and deliberately: tests/validate-prescans.sh
# for the empty/missing-arg contract across every tool, and
# tests/validate-pre-review-gates.sh for the diff/stale/control cases on the
# canonical implementation. This gate asserts only that the guard is PRESENT and
# WIRED in each file -- it is the backstop those fixtures cannot be, not a
# replacement for them.
#
# DISCOVERY IS BY CONTRACT, NOT BY FILENAME. `sizing.{sh,py}` and
# `plan-lens.{sh,py}` take file lists and are not named `patterns.*`; a
# `-name patterns.sh` glob would let four exposed files escape this gate in
# silence, which is the same class of false-clean the gate exists to prevent. So
# a file is in scope when its SOURCE declares a file-list argument, and the
# resulting count is asserted against a floor -- a discovery bug that finds two
# files must fail loudly rather than pass vacuously.
#
# Pure bash + coreutils. No network, no python (the checks are literal greps).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PLUGINS_DIR="$REPO_ROOT/plugins"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "Pre-scan input-shape guard (#816)"

# The floor is a VACUITY GUARD, not a census. It is deliberately below the real
# count (39 at the time of writing) so that adding a scanner does not fail this
# gate, while a discovery regression that collapses the set to a handful does.
# Without it, a glob typo yields "0 files checked, 0 failures" -- a green run
# that proves nothing, which is precisely the shape of bug being gated.
MIN_EXPECTED_SH=18
MIN_EXPECTED_PY=18

# list_bash_prescans — every bash pre-scan entry point, found by CONTRACT: the
# source documents `$1 = file containing paths to scan`. Matching the DOCUMENTED
# CONTRACT rather than the filename is what pulls in sizing.sh, plan-lens.sh and
# agnix-normalize.sh, and what makes a newly added scanner covered on the day it
# lands. (agnix-normalize.{sh,py} is not hypothetical: it was missed by the
# hand-written #816 survey and found by this discovery rule.)
#
# Keying on the contract COMMENT rather than on `="${1:` is deliberate. The
# latter also matches golem-attach.sh / worktree-new.sh / worktree-rm.sh, whose
# `$1` is an ISSUE NUMBER -- they take no file list, so a guard there would be
# meaningless and its absence is not a defect. Every real pre-scan already
# carries this line as a house convention, so the comment is the more precise
# discriminator, not merely the more convenient one.
#
# Executability is NOT the discriminator: test-discovery.sh and other sourced
# fragments are not entry points and take no arguments.
#
# KNOWN EXEMPTION: drift-detect/patterns.{sh,py} is the two-arg outlier and its
# header reads `$1 = file containing actual changed file paths`, so neither grep
# below matches it -- it is NOT in these sets and is NOT counted toward the
# floors. It is covered instead by test_two_arg_outlier_guards_both_lists, which
# hardcodes its path. That is deliberate (its contract genuinely differs), but it
# means a NEW scanner written by copying drift-detect would inherit a header
# generic discovery cannot see, and would be silently uncovered until someone
# wrote it a hardcoded test too. If a second two-arg scanner ever appears, give
# these functions a matching alternation rather than adding another bespoke test.
list_bash_prescans() {
    command grep -rl '\$1 = file containing paths to scan' "$PLUGINS_DIR" \
        --include='*.sh' 2>/dev/null | command sort
}

# list_python_prescans — the Python primaries, by the same contract: a main()
# that reads argv[1] as a list path and reports "file list not found".
list_python_prescans() {
    command grep -rl 'argv\[1\] = file containing paths to scan' "$PLUGINS_DIR" \
        --include='*.py' 2>/dev/null | command sort
}

# --- The guard is DEFINED in every bash entry point -------------------------

test_bash_guard_defined() {
    local script count=0
    while IFS= read -r script; do
        [ -n "$script" ] || continue
        count=$((count + 1))
        assert_file_contains "$script" 'assert_file_list_shape()' \
            "${script#"$PLUGINS_DIR"/}: defines assert_file_list_shape"
    done < <(list_bash_prescans)

    assert_true "[ $count -ge $MIN_EXPECTED_SH ]" \
        "discovery found $count bash pre-scans (floor $MIN_EXPECTED_SH) — a lower count means discovery broke, not that the repo shrank"
}

# --- ...and CALLED, not merely defined --------------------------------------
#
# A definition with no call site is exactly the inert-gate failure this whole
# family of bugs is made of (#538/#571): the code is present, reads as covered,
# and never runs. The call is matched WITHOUT the `()` so it cannot be satisfied
# by the definition line itself.

test_bash_guard_called() {
    local script count=0
    while IFS= read -r script; do
        [ -n "$script" ] || continue
        count=$((count + 1))
        assert_true \
            "command grep -qE '^assert_file_list_shape \"\\\$' '$script'" \
            "${script#"$PLUGINS_DIR"/}: calls assert_file_list_shape at top level"
    done < <(list_bash_prescans)

    assert_true "[ $count -ge $MIN_EXPECTED_SH ]" \
        "call-site sweep covered $count bash pre-scans (floor $MIN_EXPECTED_SH)"
}

# --- Both halves of the guard are present -----------------------------------
#
# The diff sniff and the unresolvable-path warning are independent rules with
# different severities, and a refactor can plausibly drop one while keeping the
# other. Asserting the pair separately is what makes each removable-and-caught.

test_bash_guard_has_both_rules() {
    local script
    while IFS= read -r script; do
        [ -n "$script" ] || continue
        assert_file_contains "$script" "'diff --git '\*" \
            "${script#"$PLUGINS_DIR"/}: diff-shape arm present"
        assert_file_contains "$script" 'resolved" -eq 0' \
            "${script#"$PLUGINS_DIR"/}: unresolvable-path warning present"
    done < <(list_bash_prescans)
}

# --- The diff arm is a hard failure, the warning is not ----------------------
#
# The severities are the operator decision behind #816 and the reason the two
# rules exist separately: a diff is an unambiguous wrong shape, while a list of
# deleted paths is legitimate and an empty list must stay silent
# (tests/validate-prescans.sh pins that). A refactor that "unified" them by
# making the warning fatal would break real invocations; one that made the diff
# arm a warning would restore the original false-clean. Pin both directions.

test_bash_severities_are_asymmetric() {
    local script
    while IFS= read -r script; do
        [ -n "$script" ] || continue
        local rel="${script#"$PLUGINS_DIR"/}"

        # The diff arm exits; the warning arm must not.
        assert_true \
            "command awk '/looks like a DIFF/,/;;/' '$script' | command grep -q 'exit 1'" \
            "$rel: the diff arm exits 1"
        assert_true \
            "! command awk '/no path listed in/,/^    fi/' '$script' | command grep -qE '(exit|return) 1'" \
            "$rel: the unresolvable-path arm does NOT exit non-zero"

        # The warning is guarded on a NON-EMPTY list, or every empty-list
        # invocation warns and validate-prescans.sh breaks.
        assert_file_contains "$script" 'total" -gt 0' \
            "$rel: the warning is guarded on a non-empty list"
    done < <(list_bash_prescans)
}

# --- The guard sits BELOW the python-exec shim, not above it -----------------
#
# A ported scanner's bash body is the FALLBACK: when a python3>=3.11 is present
# the shim `exec`s patterns.py, which carries its own copy of the guard. So the
# bash guard must be positioned AFTER that shim. Above it, the bash guard runs on
# every invocation and then exec's into python, which re-reads the same list and
# emits the identical warning a second time -- one invocation, two diagnostics --
# while the python arm's own diff-refusal becomes unreachable in the common path.
#
# Found by review on the #816 delta: 2 of 21 files had it inverted, because those
# two declare FILE_LIST above the shim and a mechanical "insert after the last
# [ -f ] check" sweep anchored in the wrong place. Reproduced as 2 warnings vs 1
# before the fix. Structural, because the symptom is a duplicated stderr line
# that no stdout-comparing gate can see.
test_bash_guard_sits_below_the_python_shim() {
    local script
    while IFS= read -r script; do
        [ -n "$script" ] || continue
        local rel="${script#"$PLUGINS_DIR"/}"

        # Only meaningful for a ported scanner (one that has a shim at all).
        command grep -q 'exec python3' "$script" || continue

        local guard_line exec_line
        guard_line="$(command grep -n '^assert_file_list_shape "\$' "$script" | command head -1 | command cut -d: -f1)"
        exec_line="$(command grep -n 'exec python3' "$script" | command head -1 | command cut -d: -f1)"

        assert_not_empty "$guard_line" "$rel: has a top-level guard call"
        assert_not_empty "$exec_line" "$rel: has a python-exec shim"
        assert_true "[ \"${guard_line:-0}\" -gt \"${exec_line:-0}\" ]" \
            "$rel: the guard call (line ${guard_line:-?}) sits BELOW the exec shim (line ${exec_line:-?}) — above it, one invocation warns twice"
    done < <(list_bash_prescans)
}

# --- Python primaries carry the mirrored guard ------------------------------
#
# The .py half is not optional coverage: validate-python-ports.sh invokes each
# primary DIRECTLY, and in normal operation the patterns.sh shim exec's into it,
# so the Python copy is what actually runs whenever a python3>=3.11 is present
# -- which is nearly always.

test_python_guard_defined_and_called() {
    local script count=0
    while IFS= read -r script; do
        [ -n "$script" ] || continue
        count=$((count + 1))
        local rel="${script#"$PLUGINS_DIR"/}"

        assert_file_contains "$script" 'def assert_file_list_shape' \
            "$rel: defines assert_file_list_shape"
        assert_true \
            "command grep -qE '^ +if assert_file_list_shape\(' '$script'" \
            "$rel: calls assert_file_list_shape in main()"
        assert_file_contains "$script" '_DIFF_PREFIXES' \
            "$rel: diff-shape arm present"
        assert_file_contains "$script" 'resolved == 0' \
            "$rel: unresolvable-path warning present"
        assert_file_contains "$script" 'total > 0' \
            "$rel: the warning is guarded on a non-empty list"

        # The diff arm must RETURN 1 (the caller turns that into exit 1). A
        # mutation to `return 0` leaves stdout empty in both runtimes, so the
        # bash<->python parity gate cannot see it -- it compares findings, and a
        # refused scan has none either way. Only the exit code diverges, and
        # only this assertion and the behavioral case in
        # validate-pre-review-gates.sh look at it. Scoped to the lines between
        # the diff-arm write and the `if os.path.exists` that follows it, so a
        # `return 0` elsewhere in the function cannot satisfy it.
        assert_true \
            "command awk '/input looks like a DIFF/,/os.path.exists/' '$script' | command grep -q 'return 1'" \
            "$rel: the diff arm returns 1, not 0"
    done < <(list_python_prescans)

    assert_true "[ $count -ge $MIN_EXPECTED_PY ]" \
        "discovery found $count python pre-scans (floor $MIN_EXPECTED_PY) — a lower count means discovery broke"
}

# --- The two-arg outlier guards BOTH of its lists ---------------------------
#
# drift-detect takes $1=actual and $2=planned. A guard on only the first leaves
# the second silently exposed, which is the exact per-site asymmetry that makes
# "fix one, miss the sibling" a recurring shape in this repo.

test_two_arg_outlier_guards_both_lists() {
    local sh="$PLUGINS_DIR/dev-core/skills/drift-detect/patterns.sh"
    local py="$PLUGINS_DIR/dev-core/skills/drift-detect/patterns.py"

    assert_file_exists "$sh" "drift-detect/patterns.sh exists"
    assert_file_exists "$py" "drift-detect/patterns.py exists"

    local n
    n="$(command grep -cE '^assert_file_list_shape "\$' "$sh" || true)"
    assert_equals "2" "$n" "drift-detect/patterns.sh guards BOTH list arguments"

    n="$(command grep -cE '^ +if assert_file_list_shape\(' "$py" || true)"
    assert_equals "2" "$n" "drift-detect/patterns.py guards BOTH list arguments"
}

# --- Run All Tests ----------------------------------------------------------

run_test test_bash_guard_defined "Every bash pre-scan defines the input-shape guard"
run_test test_bash_guard_called "Every bash pre-scan CALLS the guard (a definition alone is an inert gate)"
run_test test_bash_guard_has_both_rules "Every bash pre-scan carries both the diff arm and the unresolvable-path warning"
run_test test_bash_severities_are_asymmetric "The diff arm exits 1; the warning does not, and is non-empty-guarded"
run_test test_bash_guard_sits_below_the_python_shim "The bash guard sits BELOW the python-exec shim (one invocation, one diagnostic)"
run_test test_python_guard_defined_and_called "Every python primary carries and calls the mirrored guard"
run_test test_two_arg_outlier_guards_both_lists "drift-detect guards both of its list arguments (#816 AC4)"

generate_report
