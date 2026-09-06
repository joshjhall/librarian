#!/usr/bin/env bash
# Coverage for plugins/workflow/scripts/label-transition.sh (issues #636, #921).
#
# THE ONE PROPERTY THIS SUITE EXISTS FOR: a FAILED add must not remove the
# existing status label. On #636 the add and the remove rode in one
# `gh issue edit` call, the add failed on a label that did not exist, and the
# whole call failed — leaving the issue with NO status label and briefly
# re-selectable by another golem while its work was still in flight.
#
# WHY THE FIXTURE USES A LABEL THAT DOES NOT EXIST, AND WHY THAT IS THE WHOLE
# POINT. #921 also CREATED the two missing labels, so a test that exercised a
# real label would now pass whether or not the ordering is correct — it would
# assert nothing about the defect, because the add would simply succeed. The
# discriminating input is a label the stub REFUSES. Every failure-path case
# below therefore targets `status/does-not-exist`, a name deliberately chosen so
# that no future `gh label create` can heal it into a tautology.
#
# HOW THE STUB WORKS. `plant_label_stub` writes a fake `gh`/`glab` onto a
# sandbox PATH. It mimics the real CLI's contract in the one respect that
# matters — a label outside its known vocabulary fails the call — and APPENDS
# every invocation to a call log. The log is what the assertions read, so the
# suite can distinguish "the remove was never issued" from "the remove was
# issued and happened to no-op", which an exit code alone cannot.
#
# THE SUCCESS PATH IS ASSERTED TOO. Without it the suite would pass against a
# script that never removes anything at all — a trivially "safe" implementation
# that breaks every real transition. Pinning both directions is what makes the
# failure-path assertion meaningful rather than vacuous.
#
# Pure bash + coreutils via the `command` builtin. bash-3.2 clean, BSD-regex
# clean. Uses the shared harness assertions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LT="$REPO_ROOT/plugins/workflow/scripts/label-transition.sh"

# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_DIR/lib/harness.sh"

REAL_BASH="$(command -v bash)"

# --- Fixtures ---------------------------------------------------------------

# plant_label_stub <sandbox> <cli-name> <known-labels...>
# Write a fake gh/glab that fails any label outside <known-labels> and logs every
# call to $sandbox/calls.log (one line per invocation, verbatim argv).
#
# FIDELITY BOUNDARY, stated so nobody mistakes this for a gh emulator. The stub
# models ONE property: a call naming an unknown label exits non-zero. That is
# sufficient here because label-transition.sh only ever issues SINGLE-label
# calls, so the stub is never handed the combined form. Real `gh`'s behavior on
# a COMBINED call is worse than a clean failure — measured on #921, it applies
# the remove and then fails the add, leaving no status label — which is the
# defect being fixed, and it is verified against the live API rather than here
# (a stub asserting it would only be re-checking the stub).
plant_label_stub() {
    _sb="$1"
    _cli="$2"
    shift 2
    _known="$*"

    command mkdir -p "$_sb/bin"
    {
        command echo '#!/usr/bin/env bash'
        command echo '# Test stub: mimic gh/glab label validation + log every call.'
        command echo "KNOWN='$_known'"
        command echo "LOG='$_sb/calls.log'"
        command cat <<'STUB'
printf '%s\n' "$*" >>"$LOG"

# Find the label argument: the token after --add-label/--remove-label/--label/--unlabel.
label=""
prev=""
for tok in "$@"; do
    case "$prev" in
        --add-label | --remove-label | --label | --unlabel) label="$tok"; break ;;
    esac
    prev="$tok"
done

[ -n "$label" ] || exit 0

for k in $KNOWN; do
    [ "$k" = "$label" ] && exit 0
done

printf "could not add label: '%s' not found\n" "$label" >&2
exit 1
STUB
    } >"$_sb/bin/$_cli"
    command chmod +x "$_sb/bin/$_cli"
}

# run_lt <sandbox> <args...> — invoke label-transition.sh with the stub on PATH.
# --unset=BASH_ENV for the reason tests/golem-scripts/110-tracks-runbook.sh
# documents: in the devcontainer BASH_ENV points at /etc/bash_env, whose
# /etc/bashrc.d/ scripts hard-RESET $PATH — which would shadow the stub and let
# a real `gh` answer instead. Without this the suite would silently test nothing.
run_lt() {
    _sb="$1"
    shift
    RUN_OUT="$(command env --unset=BASH_ENV "PATH=$_sb/bin:$PATH" \
        "$REAL_BASH" "$LT" "$@" 2>&1)" && RUN_RC=0 || RUN_RC=$?
}

new_sandbox() {
    command mktemp -d "${TMPDIR:-/tmp}/lt-test.XXXXXX"
}

calls_log() {
    command cat "$1/calls.log" 2>/dev/null || true
}

# --- Cases: the failure path (the #636 defect) ------------------------------

# A failed ADD must leave the existing label alone. This is AC3.
test_failed_add_does_not_remove() {
    local sb
    sb="$(new_sandbox)"
    plant_label_stub "$sb" gh status/in-progress status/pr-pending

    run_lt "$sb" set 636 --add status/does-not-exist \
        --remove status/in-progress --platform gh

    assert_equals "1" "$RUN_RC" "A failed add exits 1"

    local log
    log="$(calls_log "$sb")"
    assert_contains "$log" "--add-label status/does-not-exist" \
        "The add was attempted"
    # THE assertion: the remove must never have been issued.
    assert_not_contains "$log" "--remove-label" \
        "A failed add must NOT issue the remove (#636 double-dispatch window)"
    assert_contains "$RUN_OUT" "was NOT removed" \
        "The operator is told the old label survived"

    command rm -rf "$sb"
}

# The GitLab arm carries the identical defect and the identical fix.
test_failed_add_does_not_unlabel_gitlab() {
    local sb
    sb="$(new_sandbox)"
    plant_label_stub "$sb" glab status/in-progress status/pr-pending

    run_lt "$sb" set 636 --add status/does-not-exist \
        --remove status/in-progress --platform glab

    assert_equals "1" "$RUN_RC" "A failed glab add exits 1"
    assert_not_contains "$(calls_log "$sb")" "--unlabel" \
        "A failed glab add must NOT issue the unlabel"

    command rm -rf "$sb"
}

# --- Cases: the success path (keeps the above from being vacuous) -----------

test_successful_add_then_removes() {
    local sb
    sb="$(new_sandbox)"
    plant_label_stub "$sb" gh status/in-progress status/pr-pending

    run_lt "$sb" set 921 --add status/pr-pending \
        --remove status/in-progress --platform gh

    assert_equals "0" "$RUN_RC" "A valid transition exits 0"

    local log
    log="$(calls_log "$sb")"
    assert_contains "$log" "--add-label status/pr-pending" "The add landed"
    assert_contains "$log" "--remove-label status/in-progress" \
        "The remove followed a successful add"

    command rm -rf "$sb"
}

# Order matters, not just presence: add must be the FIRST call.
test_add_precedes_remove() {
    local sb first
    sb="$(new_sandbox)"
    plant_label_stub "$sb" gh status/in-progress status/pr-pending

    run_lt "$sb" set 921 --add status/pr-pending \
        --remove status/in-progress --platform gh

    first="$(command head -n1 "$sb/calls.log" 2>/dev/null || true)"
    assert_contains "$first" "--add-label" \
        "The ADD is the first call issued, not the remove"

    command rm -rf "$sb"
}

# --- Cases: the stuck-label direction ---------------------------------------

# A failed REMOVE after a successful add is the SAFE failure: both labels
# present, issue still un-selectable. It must be reported (exit 3), not silent.
test_failed_remove_reports_stuck_label() {
    local sb
    sb="$(new_sandbox)"
    # pr-pending is addable; the remove target is not in the vocabulary.
    plant_label_stub "$sb" gh status/pr-pending

    run_lt "$sb" set 921 --add status/pr-pending \
        --remove status/gone-from-repo --platform gh

    assert_equals "3" "$RUN_RC" "A failed remove after a good add exits 3"
    assert_contains "$RUN_OUT" "BOTH labels" \
        "The operator is told the issue carries both labels"

    command rm -rf "$sb"
}

# --- Cases: fail-loud on an absent CLI --------------------------------------

# An absent gh must never read as a completed transition.
test_absent_cli_exits_77() {
    local sb
    sb="$(new_sandbox)"
    command mkdir -p "$sb/bin" # empty: no gh anywhere on PATH

    RUN_OUT="$(command env --unset=BASH_ENV "PATH=$sb/bin" \
        "$REAL_BASH" "$LT" set 921 --add status/pr-pending \
        --remove status/in-progress --platform gh 2>&1)" && RUN_RC=0 || RUN_RC=$?

    assert_equals "77" "$RUN_RC" "An absent CLI exits the 77 sentinel, not 0"
    assert_contains "$RUN_OUT" "not found on PATH" "The absence is reported"

    command rm -rf "$sb"
}

# --- Cases: usage errors fail loud ------------------------------------------

test_usage_errors_exit_2() {
    local sb
    sb="$(new_sandbox)"
    plant_label_stub "$sb" gh status/in-progress

    run_lt "$sb" set 921 --platform gh
    assert_equals "2" "$RUN_RC" "Neither --add nor --remove is a usage error"

    run_lt "$sb" set 007 --add status/in-progress --platform gh
    assert_equals "2" "$RUN_RC" "A leading-zero issue number is rejected"

    run_lt "$sb" set 921 --add --remove --platform gh
    assert_equals "2" "$RUN_RC" "A swallowed flag value is rejected"

    command rm -rf "$sb"
}

# --- Dispatch ---------------------------------------------------------------

test_suite "label-transition.sh (#636/#921)"

run_test test_failed_add_does_not_remove "Failed add does NOT remove the existing label"
run_test test_failed_add_does_not_unlabel_gitlab "Failed glab add does NOT unlabel"
run_test test_successful_add_then_removes "Successful add is followed by the remove"
run_test test_add_precedes_remove "The add is issued before the remove"
run_test test_failed_remove_reports_stuck_label "Failed remove reports a stuck label (exit 3)"
run_test test_absent_cli_exits_77 "Absent CLI exits the 77 sentinel"
run_test test_usage_errors_exit_2 "Usage errors exit 2"

generate_report
