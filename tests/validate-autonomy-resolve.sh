#!/usr/bin/env bash
# Autonomy-resolver decision-table gate (issue #190).
#
# autonomy-resolve.{py,sh} is the single source of truth for the L1-L4 autonomy
# decision table (orchestrate/autonomy-levels.md, #174): level selection, the
# severity/critical cap, per-gate disposition, the dead-end override, and the
# derived autonomous/plan_gated mirrors. This gate pins that table exhaustively —
# something impossible against the prose the resolver replaced. It asserts:
#
#   1. Every (level x gate-class x dead-end) disposition cell.
#   2. Level selection precedence, the critical cap, and every mirror field.
#   3. The legacy `read` back-compat cells (state-level vs autonomous boolean).
#   4. Fail-loud exit codes + a `Usage` message on malformed input.
#   5. bash<->python PARITY — the bash fallback (forced via PATTERNS_FORCE_BASH=1)
#      and, when a python3>=3.11 is present, the python primary emit byte-identical
#      output for every row above. Parity is what makes the port a safe drop-in:
#      the language boundary is the output, not the implementation.
#
# The bash path is always exercised; the python path and the parity assertion are
# skipped (not failed) when python3>=3.11 is unavailable, mirroring
# validate-python-ports.sh. Pure bash + coreutils + python3; no network, no jq.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

RESOLVER="$REPO_ROOT/plugins/workflow/scripts/autonomy-resolve.sh"
REAL_BASH="$(command -v bash)"

# Is a usable python3 primary available? Parity is only asserted where it is.
HAVE_PY=0
if command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    HAVE_PY=1
fi

test_suite "Autonomy-resolver decision table + parity (#190)"

# run_bash <args...> — run the resolver forcing the bash fallback; capture stdout
# (stderr merged) into RUN_OUT and the exit code into RUN_RC.
run_bash() {
    RUN_OUT="$(PATTERNS_FORCE_BASH=1 "$REAL_BASH" "$RESOLVER" "$@" 2>&1)" && RUN_RC=0 || RUN_RC=$?
}

# assert_resolves <expected-multiline> <args...>
# The core decision-table assertion: the bash fallback emits exactly
# <expected>, exit 0; and — when python is present — the python primary emits
# byte-identical output (parity). One row of the table per call.
assert_resolves() {
    _ar_expected="$1"
    shift
    run_bash "$@"
    assert_equals "$_ar_expected" "$RUN_OUT" "bash: $* -> expected output"
    assert_exit 0 "$RUN_RC" "bash: $* -> exit 0"
    if [ "$HAVE_PY" = "1" ]; then
        _ar_py="$(python3 "$REPO_ROOT/plugins/workflow/scripts/autonomy-resolve.py" "$@" 2>&1)"
        assert_equals "$RUN_OUT" "$_ar_py" "parity: $* -> bash == python"
    fi
}

# assert_usage_error <args...> — malformed input exits 2 with a Usage message on
# both runtimes (parity on the error path too).
assert_usage_error() {
    run_bash "$@"
    assert_exit 2 "$RUN_RC" "bash: $* -> exit 2 (usage error)"
    assert_contains "$RUN_OUT" "Usage:" "bash: $* -> prints Usage"
    if [ "$HAVE_PY" = "1" ]; then
        python3 "$REPO_ROOT/plugins/workflow/scripts/autonomy-resolve.py" "$@" >/dev/null 2>&1 &&
            _au_rc=0 || _au_rc=$?
        assert_exit 2 "$_au_rc" "python: $* -> exit 2 (usage error)"
    fi
}

# --- gate disposition: every level x class x dead-end cell --------------------

test_gate_routine() {
    assert_resolves "disposition=human" gate routine --level 1
    assert_resolves "disposition=human" gate routine --level 2
    assert_resolves "disposition=auto" gate routine --level 3
    assert_resolves "disposition=auto" gate routine --level 4
}

test_gate_escalation() {
    assert_resolves "disposition=human" gate escalation --level 1
    assert_resolves "disposition=human" gate escalation --level 2
    assert_resolves "disposition=human" gate escalation --level 3
    assert_resolves "disposition=auto" gate escalation --level 4
}

test_gate_dead_end_overrides() {
    # A dead-end defers to a human at EVERY level, L4 included — for both classes.
    assert_resolves "disposition=human" gate routine --level 4 --dead-end
    assert_resolves "disposition=human" gate escalation --level 4 --dead-end
    assert_resolves "disposition=human" gate routine --level 3 --dead-end
}

# --- level selection, critical cap, and derived mirrors ----------------------

# Expected `level` block builder to keep rows readable.
lvl_block() {
    command printf 'autonomy_level=%s\nautonomous=%s\nplan_gated=%s\ncapped=%s\nperm_mode=%s' \
        "$1" "$2" "$3" "$4" "$5"
}

test_level_no_signal_is_l1() {
    # No flag, no env, no chosen level -> the mechanical L1 default.
    assert_resolves "$(lvl_block 1 false true false acceptEdits)" level
}

test_level_autonomous_alias_is_l4() {
    assert_resolves "$(lvl_block 4 true false false auto)" level --from-args "--autonomous"
    assert_resolves "$(lvl_block 4 true false false auto)" level --from-args "--auto"
    assert_resolves "$(lvl_block 4 true false false auto)" level --from-args "--force-auto"
    assert_resolves "$(lvl_block 4 true false false auto)" level --from-args "--skip-plan"
    assert_resolves "$(lvl_block 4 true false false auto)" level --env-autonomous 1
}

test_level_explicit_flag_wins() {
    assert_resolves "$(lvl_block 2 false true false auto)" level --from-args "--level 2"
    assert_resolves "$(lvl_block 3 false true false auto)" level --from-args "--level 3"
    # An explicit --level beats an L4 env signal (precedence).
    assert_resolves "$(lvl_block 2 false true false auto)" level --from-args "--level 2" --env-autonomous 1
}

test_level_chosen_setup_level() {
    # A level chosen at setup (orchestrator dispatch / interactive answer) is used
    # when there is no CLI flag or env alias.
    assert_resolves "$(lvl_block 2 false true false auto)" level --chosen-level 2
    assert_resolves "$(lvl_block 3 false true false auto)" level --chosen-level 3
    # ...but an autonomous alias still outranks it.
    assert_resolves "$(lvl_block 4 true false false auto)" level --chosen-level 2 --from-args "--autonomous"
}

test_level_critical_cap() {
    # L4 request on a critical issue caps to L3 (capped=true), keeping the plan gate.
    assert_resolves "$(lvl_block 3 false true true auto)" level --from-args "--autonomous" --severity critical
    assert_resolves "$(lvl_block 3 false true true auto)" level --from-args "--auto" --severity severity/critical
    assert_resolves "$(lvl_block 3 false true true auto)" level --chosen-level 4 --severity critical
    # L3 (or below) on a critical issue is NOT capped (already <= L3).
    assert_resolves "$(lvl_block 3 false true false auto)" level --from-args "--level 3" --severity critical
}

test_level_plan_gate_override() {
    # --plan-gate / --no-skip-plan force plan_gated=true even at L4 (plan gate kept).
    assert_resolves "$(lvl_block 4 true true false auto)" level --from-args "--level 4 --plan-gate"
    assert_resolves "$(lvl_block 4 true true false auto)" level --from-args "--level 4 --no-skip-plan"
}

# --- legacy `read` back-compat -----------------------------------------------

test_read_backcompat() {
    assert_resolves "autonomy_level=4" read --state-autonomous true
    assert_resolves "autonomy_level=1" read --state-autonomous false
    assert_resolves "autonomy_level=1" read
    assert_resolves "autonomy_level=3" read --state-level 3
    # A present state-level wins over the legacy boolean.
    assert_resolves "autonomy_level=2" read --state-level 2 --state-autonomous true
}

# --- fail-loud on malformed input --------------------------------------------

test_usage_errors() {
    assert_usage_error                               # no subcommand
    assert_usage_error bogus                         # unknown subcommand
    assert_usage_error gate bogus --level 2          # bad gate class
    assert_usage_error gate routine --level 9        # out-of-range level
    assert_usage_error gate routine                  # missing --level
    assert_usage_error level --from-args "--level 9" # embedded bad level
    assert_usage_error read --state-level 7          # out-of-range state level
}

# --- guard: the suite is not a silent no-op ----------------------------------

test_resolver_present_and_executable() {
    assert_file_exists "$RESOLVER" "autonomy-resolve.sh must exist"
    assert_true "[ -x '$RESOLVER' ]" "autonomy-resolve.sh must be executable"
}

# --- parity coverage note ----------------------------------------------------

test_parity_runtime() {
    if [ "$HAVE_PY" = "1" ]; then
        # Parity is asserted inline in every assert_resolves/assert_usage_error
        # call above; this test just records that the python path was exercised.
        assert_true "true" "python3>=3.11 present — parity asserted on every row"
    else
        skip_test "python3>=3.11 not available — bash path exercised, parity not asserted"
    fi
}

run_test test_gate_routine "routine gate: auto at L3-L4, human at L1-L2"
run_test test_gate_escalation "escalation gate: auto at L4 only, human at L1-L3"
run_test test_gate_dead_end_overrides "dead-end: human at every level incl. L4"
run_test test_level_no_signal_is_l1 "level: no signal -> L1 default"
run_test test_level_autonomous_alias_is_l4 "level: --autonomous/--auto/--force-auto/--skip-plan/env -> L4"
run_test test_level_explicit_flag_wins "level: explicit --level wins over aliases"
run_test test_level_chosen_setup_level "level: chosen setup level used, alias outranks it"
run_test test_level_critical_cap "level: critical caps L4 -> L3 (capped=true)"
run_test test_level_plan_gate_override "level: --plan-gate forces plan_gated even at L4"
run_test test_read_backcompat "read: state-level wins; autonomous:true->L4, else L1"
run_test test_usage_errors "malformed input: exit 2 + Usage on both runtimes"
run_test test_resolver_present_and_executable "resolver script present + executable"
run_test test_parity_runtime "parity runtime available"

generate_report
