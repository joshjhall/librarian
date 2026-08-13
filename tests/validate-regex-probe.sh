#!/usr/bin/env bash
# Regex-probe reporting integrity (#684).
#
# tests/probe-bsd-regex.sh is the instrument that decides the `\b` question for
# the 38 sites #679 left alone. Its whole value is telling SUPPORTED from
# UNSUPPORTED from ERROR on a host nobody here can run — so if its classification
# or its exit status is wrong, the macOS verdict it produces is wrong, and wrong
# in the silent direction #679 is about.
#
# THE COVERAGE GAP THIS CLOSES. Running the probe on a GNU host exercises only
# the SUPPORTED branch and only the require-PASS path. The two branches that
# carry the actual signal — UNSUPPORTED (a construct read as a literal: the
# #679 failure mode) and ERROR (a tool REJECTING the pattern, e.g. GNU on
# `[[:<:]]`) — plus the require-FAIL path that must exit 1, are reachable on
# this host only by FORCING them. That is what this file does.
#
# It follows the #543 lesson recorded in validate-lint-gates.sh: a test that
# skips itself when the interesting condition is absent leaves the risky arm
# uncovered everywhere. So rather than waiting for a BSD runner, each case
# fabricates the tool behaviour it needs via a stub PATH.
#
# BASH_ENV is unset for every child for the same reason validate-lint-gates.sh
# does it: in the devcontainer it points at /etc/bash_env, whose scripts
# hard-RESET $PATH and would let the REAL grep outrank the stub, silently
# invalidating the case.
#
# Pure bash + coreutils. Uses the shared harness assertions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE="$SCRIPT_DIR/probe-bsd-regex.sh"

REAL_BASH="$(command -v bash)"

# Git's hook-exported environment, scrubbed so a pre-push run stays hermetic.
GIT_SCRUB=(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
    GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES)

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "Regex-probe reporting integrity (#684)"

# --- helpers ----------------------------------------------------------------

# eval_probe_helpers — source ONLY the helper functions out of the probe, so a
# case can call probe_grep/probe_sed/require directly without running the whole
# script (which would execute every check and print a report).
#
# Extracted from the file on disk rather than copied here: a copy would drift,
# and a drifted copy would keep passing while the real helpers broke — the
# tautology the repo's own conventions warn about. Mirrors
# validate-pre-review-gates.sh's eval_read_yaml_list.
eval_probe_helpers() {
    eval "$(command awk '/^probe_grep\(\) \{$/,/^\}$/' "$PROBE")"
    eval "$(command awk '/^probe_grep_rejects\(\) \{$/,/^\}$/' "$PROBE")"
    eval "$(command awk '/^probe_sed\(\) \{$/,/^\}$/' "$PROBE")"
    eval "$(command awk '/^require\(\) \{$/,/^\}$/' "$PROBE")"
}

# stub_dir <varname> — a sandbox with a bin/ holding ONLY what a case plants.
# Nothing is symlinked in from the real PATH: a case that needs a working tool
# plants it explicitly, so no case can accidentally reach the host's grep.
stub_dir() {
    local __out="$1" dir=""
    dir="$(command mktemp -d)" || return 1
    command mkdir -p "$dir/bin"
    printf -v "$__out" '%s' "$dir"
}

# --- classification: the three verdicts --------------------------------------

# SUPPORTED vs UNSUPPORTED is the distinction the whole probe rests on, and on a
# GNU host only the first is ever produced. A `grep` that exits 1 means "ran
# fine, did not match" — a construct read as a LITERAL, which is exactly the
# #679 silent failure. It must never be reported as SUPPORTED, and must never be
# conflated with ERROR (a rejected pattern).
test_probe_grep_classifies_all_three_verdicts() {
    local V=""
    eval_probe_helpers

    probe_grep V 'a b' '[[:space:]]' -E
    assert_equals "SUPPORTED" "$V" "a matching pattern classifies SUPPORTED"

    # Exit 1 — ran cleanly, no match.
    probe_grep V 'aaa' 'zzz' -E
    assert_equals "UNSUPPORTED" "$V" "a clean non-match classifies UNSUPPORTED, not ERROR (#684)"

    # Exit >= 2 — the tool REJECTED the pattern. GNU does this on BSD's
    # `[[:<:]]` ("Invalid character class name"), which is why the distinction
    # is load-bearing rather than cosmetic.
    probe_grep V 'anything' '[[:<:]]x[[:>:]]' -E
    assert_equals "ERROR" "$V" "a rejected pattern classifies ERROR, not UNSUPPORTED (#684)"
}

# The same three-way split for sed. probe_sed is stricter than a bare exit
# check: BSD sed reading `\b` as a literal SUCCEEDS (exit 0) while changing
# nothing, so an exit-status-only probe would call that SUPPORTED. Only
# comparing the OUTPUT catches it — this pins that.
test_probe_sed_requires_the_substitution_to_take_effect() {
    local V=""
    eval_probe_helpers

    probe_sed V 'a  b' 's/[[:space:]]+/_/' 'a_b'
    assert_equals "SUPPORTED" "$V" "a substitution that produces the expected output is SUPPORTED"

    # Exit 0, but the expression matched nothing — the input passes through
    # unchanged. This is the shape of a BSD sed reading a GNU escape literally.
    probe_sed V 'a  b' 's/zzz/_/' 'a_b'
    assert_equals "UNSUPPORTED" "$V" \
        "a no-op substitution is UNSUPPORTED even though sed exited 0 (#684)"
}

# The inverse probe, where a NON-match is the pass. Its BROKEN arm is the one
# piece of the probe no real grep can reach — GNU and BSD `grep -w` both reject
# partial words correctly — so without a stub it would ship permanently
# unexecuted. That arm exists precisely to catch a `-w` that silently matches
# substrings, which would make `grep -w` an unsafe replacement for `\b` at the
# six BRE sites; shipping it unexercised would leave the safety check itself
# unchecked.
test_probe_grep_rejects_handles_all_three_outcomes() {
    local V="" sb=""
    eval_probe_helpers

    # Real grep: correctly does NOT match a partial word -> SUPPORTED.
    probe_grep_rejects V 'def my_func_extra():' 'my_func' -w
    assert_equals "SUPPORTED" "$V" "a correct -w rejecting a partial word is SUPPORTED"

    # A rejected pattern must stay ERROR, not be laundered into a pass by the
    # inversion — a tool that could not answer has not demonstrated anything.
    probe_grep_rejects V 'anything' '[[:<:]]x[[:>:]]' -E
    assert_equals "ERROR" "$V" "an ERROR is not inverted into a pass (#684)"

    # THE UNREACHABLE ARM: a grep that matches everything, i.e. a broken `-w`
    # that happily matches a substring. exit 0 -> SUPPORTED -> inverted to BROKEN.
    stub_dir sb || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064  # expand $sb now, at trap-registration time
    trap "command rm -rf '$sb'" RETURN

    command printf '#!/usr/bin/env bash\nexit 0\n' >"$sb/bin/grep"
    command chmod +x "$sb/bin/grep"

    # The stub bin is PREPENDED to the real PATH rather than replacing it: it
    # holds only `grep`, and probe_grep's own pipeline plus this file's trap
    # still need the real coreutils. Replacing PATH outright makes the probe
    # report ERROR (its grep ran, but the rest of the pipeline could not),
    # which is a fixture artifact indistinguishable from a real finding.
    #
    # No subshell: probe_grep_rejects returns its verdict through a named
    # variable, which a `$( )` capture would strand in the child.
    local saved_path="$PATH"
    PATH="$sb/bin:$PATH"
    probe_grep_rejects V 'def my_func_extra():' 'my_func' -w
    PATH="$saved_path"

    assert_equals "BROKEN (matched a substring)" "$V" \
        "a -w that matches a substring is reported BROKEN, not SUPPORTED (#684)"
}

# --- the fail-loud contract --------------------------------------------------

# `require` is what makes an unmet POSIX baseline fail the probe instead of
# being printed and forgotten. On this host every requirement passes, so the
# FAILURES-incrementing branch never runs — force it.
# NOTE ON CAPTURE. `require` writes to stdout AND mutates FAILURES, so its two
# effects cannot be observed in one call: `$(require ...)` runs a SUBSHELL, whose
# increment dies with it. (Asserting on FAILURES after a captured call was this
# file's own first bug — it read 0 every time and would have "passed" a require()
# that never counted anything.) So each effect is checked in the mode that can
# actually see it: rendering via capture, counting via an uncaptured call with
# stdout redirected away.
test_require_failure_increments_failures() {
    local FAILURES=0 out=""
    eval_probe_helpers

    # --- rendering (captured) ---
    out="$(require "a passing baseline" "SUPPORTED")"
    assert_contains "$out" "[ ok ]" "a passing requirement renders [ ok ]"

    out="$(require "a failing baseline" "UNSUPPORTED")"
    assert_contains "$out" "[FAIL]" "a failing requirement renders [FAIL], not [ ok ]"

    # --- counting (uncaptured, so the increment lands in THIS shell) ---
    FAILURES=0
    require "a passing baseline" "SUPPORTED" >/dev/null
    assert_equals "0" "$FAILURES" "a SUPPORTED requirement leaves FAILURES at 0"

    require "a failing baseline" "UNSUPPORTED" >/dev/null
    assert_equals "1" "$FAILURES" "a non-SUPPORTED requirement increments FAILURES (#684)"

    # ERROR is not SUPPORTED either — it must fail the requirement, not slip
    # through as a third accepted state.
    require "an erroring baseline" "ERROR" >/dev/null
    assert_equals "2" "$FAILURES" "an ERROR requirement also increments FAILURES (#684)"
}

# END-TO-END, and the case that matters most: with a sabotaged grep on PATH the
# POSIX baseline cannot hold, and the probe must EXIT NON-ZERO rather than print
# a tidy report of nothing. A probe that exits 0 while its baseline is broken
# would let a genuinely unportable macOS host read as clean — the #679 failure
# mode reproduced in the instrument built to detect it.
#
# The stub exits 1 for every invocation: a grep that never matches, which is
# precisely how BSD grep behaves toward a GNU-only construct.
test_probe_exits_nonzero_when_baseline_cannot_hold() {
    local sb="" rc=0 out=""
    stub_dir sb || {
        skip_test "mktemp unavailable"
        return 0
    }
    # shellcheck disable=SC2064  # expand $sb now, at trap-registration time
    trap "command rm -rf '$sb'" RETURN

    command printf '#!/usr/bin/env bash\nexit 1\n' >"$sb/bin/grep"
    command chmod +x "$sb/bin/grep"
    # A working sed is deliberately NOT planted: the probe must fail on the grep
    # baseline alone, without depending on which tool breaks first.

    out="$(command env "${GIT_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
        PATH="$sb/bin" "$REAL_BASH" "$PROBE" 2>&1)" || rc=$?

    assert_true "[ \"$rc\" -ne 0 ]" \
        "a broken POSIX baseline exits NON-ZERO — never a clean report of nothing (#684)"
    assert_contains "$out" "FAILED" "the failure is named in the output, not silent"
}

# The positive control for the case above. Without it, a probe that exited
# non-zero unconditionally would satisfy the sabotage case and look correct —
# the "gate and evidence converge" tautology. On the real (GNU) PATH the
# baseline holds and the probe must exit 0.
test_probe_exits_zero_on_a_healthy_host() {
    local rc=0
    command env "${GIT_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
        "$REAL_BASH" "$PROBE" >/dev/null 2>&1 || rc=$?

    assert_equals "0" "$rc" "control: on a host whose POSIX baseline holds, the probe exits 0"
}

# --- registration ------------------------------------------------------------

run_test test_probe_grep_classifies_all_three_verdicts "probe_grep separates SUPPORTED / UNSUPPORTED / ERROR (#684)"
run_test test_probe_grep_rejects_handles_all_three_outcomes "probe_grep_rejects reports a substring-matching -w as BROKEN (#684)"
run_test test_probe_sed_requires_the_substitution_to_take_effect "probe_sed rejects a no-op substitution that exited 0 (#684)"
run_test test_require_failure_increments_failures "require() fails loudly on a non-SUPPORTED baseline (#684)"
run_test test_probe_exits_nonzero_when_baseline_cannot_hold "a sabotaged grep makes the probe exit non-zero (#684)"
run_test test_probe_exits_zero_on_a_healthy_host "control: a healthy host exits 0 (#684)"

generate_report
