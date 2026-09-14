# shellcheck shell=bash
# The COMPARISON LOGIC — the reconciler's reason to exist (issue #938).
#
# Sourced, not executed; see tests/validate-label-vocab-reconcile.sh.
#
# The control plus both drift directions plus the status/ filter. Every case here
# is built on the arm that DISAGREES when the logic it targets is removed: a
# suite asserting only that the live repo is currently clean would pass just as
# happily with both comparisons deleted.

# --- the control: both directions agree --------------------------------------

test_agreeing_vocabularies_pass() {
    local box
    box="$(make_sandbox status/in-progress status/blocked)"
    stub_gh "$box" ok status/in-progress status/blocked

    run_reconcile "$box"
    assert_exit 0 "$RC_CODE" "agreeing declared + live vocabularies exit 0"
    assert_contains "$RC_OUT" "No drift" "the clean run says so explicitly"
    # Non-vacuity: the control must have actually compared a real vocabulary. A
    # parser returning nothing would exit 2, but a comparison over one label
    # would still pass this case while proving much less.
    assert_contains "$RC_OUT" "declared in \`plugins/**/metadata.yml\`: **2**" \
        "the control compared both declared labels, not an empty set"
}

# --- direction 1: declared but deleted from the repo -------------------------
# THE #938 DIRECTION. This is the drift the offline gate is structurally blind
# to, and this suite is the only thing that proves the reconciler sees it.

test_declared_label_absent_from_repo_fails() {
    local box
    box="$(make_sandbox status/in-progress status/blocked)"
    stub_gh "$box" ok status/in-progress

    run_reconcile "$box"
    assert_exit 1 "$RC_CODE" "a declared label absent from the repo exits 1"
    assert_contains "$RC_OUT" "Declared but absent" "the report names the direction"
    assert_contains "$RC_OUT" "status/blocked" "the report names the missing label"
    assert_not_contains "$RC_OUT" "No drift" "a failing run never claims no drift"
}

test_every_missing_label_is_named() {
    local box
    box="$(make_sandbox status/in-progress status/blocked status/on-hold)"
    stub_gh "$box" ok status/in-progress

    run_reconcile "$box"
    assert_exit 1 "$RC_CODE" "two missing labels still exit 1"
    # The SECOND hit is the assertion that matters: a report collapsing N
    # findings to the first one re-creates the suppression bug, and the label
    # nobody notices is exactly the one that takes the pipeline down.
    assert_contains "$RC_OUT" "status/blocked" "the first missing label is named"
    assert_contains "$RC_OUT" "status/on-hold" "the SECOND missing label is named too"
    assert_contains "$RC_OUT" "absent from the repo (2)" "the count reflects both"
}

# --- direction 2: present in the repo but undeclared -------------------------

test_undeclared_live_label_fails() {
    local box
    box="$(make_sandbox status/in-progress)"
    stub_gh "$box" ok status/in-progress status/mystery

    run_reconcile "$box"
    assert_exit 1 "$RC_CODE" "an undeclared live status/* label exits 1"
    assert_contains "$RC_OUT" "but undeclared" "the report names the direction"
    assert_contains "$RC_OUT" "status/mystery" "the report names the undeclared label"
}

test_all_status_labels_deleted_is_a_finding_not_a_runtime_error() {
    local box
    box="$(make_sandbox status/in-progress status/blocked)"
    # gh SUCCEEDS and returns labels — just no status/* ones. This is the extreme
    # of the #938 direction (somebody deleted the whole family), and it must read
    # as a FINDING (1), not as the runtime failure an empty gh response is (2).
    # The boundary is easy to collapse: a guard on "LIVE is empty" placed after
    # the filter instead of before it would turn the worst real drift event this
    # job exists to catch into a fail-loud exit that names no label at all.
    stub_gh "$box" ok severity/high bug

    run_reconcile "$box"
    assert_exit 1 "$RC_CODE" "every status/* label deleted is drift (1), not a runtime error (2)"
    assert_contains "$RC_OUT" "status/in-progress" "the first deleted label is named"
    assert_contains "$RC_OUT" "status/blocked" "the second deleted label is named"
    assert_not_contains "$RC_OUT" "FATAL" "a real finding is never dressed as a runtime failure"
}

# --- both directions at once -------------------------------------------------
# A report that stopped at the first direction would pass every case above while
# hiding half of any real drift event.

test_both_directions_reported_together() {
    local box
    box="$(make_sandbox status/in-progress status/blocked)"
    stub_gh "$box" ok status/in-progress status/mystery

    run_reconcile "$box"
    assert_exit 1 "$RC_CODE" "drift in both directions exits 1"
    assert_contains "$RC_OUT" "status/blocked" "the missing label is named"
    assert_contains "$RC_OUT" "status/mystery" "the undeclared label is named"
    assert_contains "$RC_OUT" "Declared but absent" "the missing-direction section is present"
    assert_contains "$RC_OUT" "but undeclared" "the undeclared-direction section is present"
}

# --- the status/ filter ------------------------------------------------------
# Load-bearing: `gh label list` returns severity/*, effort/*, type/* and
# component/* too. Unfiltered, the job is red on its first run and gets muted,
# which is the same end state as never having written it.

test_non_status_live_labels_are_ignored() {
    local box
    box="$(make_sandbox status/in-progress)"
    stub_gh "$box" ok status/in-progress severity/critical effort/small \
        type/bug component/workflow bug enhancement

    run_reconcile "$box"
    assert_exit 0 "$RC_CODE" "non-status live labels do not count as undeclared"
    assert_contains "$RC_OUT" "No drift" "the run is clean"
    assert_not_contains "$RC_OUT" "severity/critical" "a severity label is never reported"
    assert_contains "$RC_OUT" "live \`status/*\` labels in the repo: **1**" \
        "only the status/* label counted"
}

test_non_status_declared_labels_are_ignored() {
    local box
    # make_sandbox always plants `type/fixture` in the same labels: block.
    box="$(make_sandbox status/in-progress)"
    stub_gh "$box" ok status/in-progress

    run_reconcile "$box"
    assert_exit 0 "$RC_CODE" "a non-status DECLARED label is not demanded of the repo"
    assert_not_contains "$RC_OUT" "type/fixture" "the non-status declaration is never reported"
}
