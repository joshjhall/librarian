# shellcheck shell=bash
# golem-status.sh CONTEXT BUDGET block — golem helper-script tests (#784).
#
# The context-budget.sh script itself is covered end-to-end by
# tests/validate-context-budget.sh (point-reading contract, verdict boundaries,
# fail-loud paths, knobs). What THAT suite cannot reach is the golem-status
# RENDER: whether the verdict actually reaches an operator's screen, and whether
# an unreadable budget degrades to a visible "unknown" instead of a blank row
# that reads as healthy.
#
# Sourced by tests/validate-golem-scripts.sh, which defines the path consts
# (LAUNCH / WT_NEW / STATUS / CTX_BUDGET / ...) and sources
# tests/lib/golem-sandbox.sh for the shared sandbox plumbing (new_sandbox /
# run_status_scrape / plant_transcript / ...) BEFORE this file. This fragment
# therefore only DEFINES test functions; the entry point dispatches them from its
# explicit ordered run_test list.

# --- golem-status CONTEXT BUDGET block (#784) -------------------------------

# The block renders at all, with the golem's context size and percent.
test_status_renders_context_budget_block() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (context budget needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "impl", "phase": "make-it-work", "blocking": false }
EOF
    plant_transcript "$sb" 42 "$TRANSCRIPT_CTX_ADVISE"
    run_status_scrape "$sb"
    assert_contains "$RUN_OUT" "CONTEXT BUDGET" "the block is rendered"
    assert_contains "$RUN_OUT" "160000 tokens" "renders the context size"
}

# The `handoff` verdict must be VISIBLY distinct — this is the row an operator
# acts on, and the whole point of the block. Asserting the marker (not just the
# number) is what stops a regression that renders every verdict identically.
test_status_marks_a_handoff_due_golem() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (context budget needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "impl", "phase": "make-it-work", "blocking": false }
EOF
    plant_transcript "$sb" 42 "$TRANSCRIPT_CTX_HANDOFF"
    run_status_scrape "$sb"
    assert_contains "$RUN_OUT" "HANDOFF DUE" "a golem past the threshold is marked"
}

# A golem in the advisory band is marked as approaching, NOT as handoff-due —
# the two must not collapse, or the advisory (which exists to give a session room
# to finish its step) becomes indistinguishable from the stop signal.
test_status_marks_an_advisory_golem_distinctly() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (context budget needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "impl", "phase": "make-it-work", "blocking": false }
EOF
    plant_transcript "$sb" 42 "$TRANSCRIPT_CTX_ADVISE"
    run_status_scrape "$sb"
    assert_contains "$RUN_OUT" "approaching handoff" "the advisory band is marked"
    assert_not_contains "$RUN_OUT" "HANDOFF DUE" "advise does not render as handoff"
}

# A golem well under budget renders plainly, with no attention marker at all.
test_status_renders_an_ok_golem_without_a_marker() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (context budget needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "impl", "phase": "make-it-work", "blocking": false }
EOF
    plant_transcript "$sb" 42 "$TRANSCRIPT_CTX_OK"
    run_status_scrape "$sb"
    assert_contains "$RUN_OUT" "20000 tokens" "renders the reading"
    assert_not_contains "$RUN_OUT" "approaching handoff" "an ok golem carries no advisory marker"
    assert_not_contains "$RUN_OUT" "HANDOFF DUE" "an ok golem carries no handoff marker"
}

# The fail-loud path, seen from the render side: no transcript must produce a
# VISIBLE "context unknown", never a blank or a zero. A blank row reads as
# healthy, which is exactly the silent failure the script's fail-loud contract
# exists to prevent — and the render is where that contract is either honored or
# quietly discarded.
test_status_renders_unknown_when_no_transcript() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (context budget needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "impl", "phase": "make-it-work", "blocking": false }
EOF
    # Deliberately plant NO transcript.
    run_status_scrape "$sb"
    assert_contains "$RUN_OUT" "context unknown" "an unreadable budget is visibly unknown"
    assert_not_contains "$RUN_OUT" "0 tokens (0% of threshold)" \
        "never renders a zero reading for an absent transcript"
}

# A Mode-3 (container) golem's transcript lives inside its container and is not
# host-readable, so read_context_budget must short-circuit on the cache row's
# `container` field and render a plain not-available note. Two things are pinned:
# the note is VISIBLE (a blank row would read as healthy, the same silent-failure
# the unknown case guards), and the scrape is never attempted — a container row
# must not fall through to the Mode-2 path and report another golem's reading.
test_status_renders_container_golem_as_not_readable() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (context budget needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "impl", "phase": "make-it-work", "blocking": false,
  "container": "golem-42-ctr" }
EOF
    # Plant a transcript the HOST could read. A correct container branch ignores
    # it; a regression that falls through to the Mode-2 scrape would report
    # 200100 here — so this fixture is what makes the assertion discriminating
    # rather than trivially true.
    plant_transcript "$sb" 42 "$TRANSCRIPT_CTX_HANDOFF"
    run_status_scrape "$sb"
    assert_contains "$RUN_OUT" "context not readable (container golem)" \
        "a Mode-3 golem renders the not-available note"
    assert_not_contains "$RUN_OUT" "200100 tokens" \
        "the host-side transcript is NOT scraped for a container golem"
    assert_not_contains "$RUN_OUT" "HANDOFF DUE" \
        "a container row never renders a verdict it cannot have measured"
}

# The script's stderr must not leak into the rendered table. golem-status
# redirects it in the same breath as absorbing the exit status; dropping that
# redirect prints a raw diagnostic mid-table (the
# redirect-order-leaks-the-diagnostic class).
test_status_does_not_leak_the_scripts_stderr() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (context budget needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "impl", "phase": "make-it-work", "blocking": false }
EOF
    run_status_scrape "$sb"
    assert_not_contains "$RUN_OUT" "context-budget: no transcript dir" \
        "the script's own diagnostic does not leak into the table"
}
