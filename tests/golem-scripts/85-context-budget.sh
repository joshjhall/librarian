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
# (LAUNCH / WT_NEW / STATUS / ...) and sources tests/lib/golem-sandbox.sh for the
# shared sandbox plumbing (new_sandbox / run_status_scrape / plant_transcript /
# ...) BEFORE this file. Note there is deliberately NO CTX_BUDGET const here:
# this fragment never invokes context-budget.sh directly, only through
# golem-status.sh ($STATUS), which resolves it from its own SCRIPT_DIR. The
# direct-invocation const lives in the separate tests/validate-context-budget.sh.
# This fragment
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

# The cache is a co-written JSON file, so `.issue` is untrusted input. A
# traversal-bearing or non-numeric value must never reach the worktree path this
# helper builds — it degrades to `unknown` instead. Without the numeric guard the
# path escapes .worktrees/ and context-budget.sh probes wherever it resolves.
test_status_rejects_a_traversal_issue_field() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (context budget needs jq)"
        return 0
    fi
    local sb dir slug
    new_sandbox sb
    # THE TRAVERSAL MUST REACH A REAL TRANSCRIPT, or this test is a tautology:
    # an unguarded `../` path resolves to a nonexistent directory, context-budget
    # exits 2, and the row renders `unknown` — the same output the guard produces,
    # so the case would pass with AND without the fix (verified: it did).
    #
    # So plant a transcript at exactly the slug the ESCAPED path computes. With
    # the guard the row is `unknown`; without it, golem-status renders a real
    # reading from outside .worktrees/ — the two arms now differ.
    plant_transcript "$sb" 42 "$TRANSCRIPT_CTX_HANDOFF"
    slug="$(slug_for "$sb/.worktrees/issue-42/../escaped")"
    dir="$sb/projects/$slug"
    command mkdir -p "$dir"
    command printf '%s\n' "$TRANSCRIPT_CTX_HANDOFF" >"$dir/session.jsonl"
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": "42/../escaped",
  "branch": "feature/issue-42", "state": "impl", "blocking": false }
EOF
    run_status_scrape "$sb"
    assert_contains "$RUN_OUT" "context unknown" \
        "a non-numeric/traversal .issue degrades to unknown"
    assert_not_contains "$RUN_OUT" "200100 tokens" \
        "the escaped path's transcript is NOT read — the guard blocked the path"
    assert_not_contains "$RUN_OUT" "HANDOFF DUE" \
        "no verdict is rendered from an out-of-bounds reading"
}

# read_context_budget defends against a truncated/partial capture with three
# guards (non-numeric context_tokens, non-numeric pct, unrecognized verdict), each
# falling back to `unknown`. The other cases only reach the EARLIER short-circuits
# (container / missing issue / script failure), so these parse guards were
# unexercised. Drive them by shadowing context-budget.sh with a stub that exits 0
# while emitting a well-formed-looking but malformed row — the shape a truncated
# read produces, and the one that must not render as a real measurement.
test_status_rejects_malformed_budget_output() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (context budget needs jq)"
        return 0
    fi
    local sb shadow
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "impl", "blocking": false }
EOF
    # golem-status resolves both scripts from its own SCRIPT_DIR, so shadow the
    # pair into a temp dir: a copy of the real status script beside a stub
    # context-budget.sh. Exits 0 (so the `|| true` path is not what is being
    # tested) but emits a verdict outside {ok,advise,handoff} and a non-numeric
    # count — exactly what a half-written capture looks like.
    shadow="$sb/shadow"
    command mkdir -p "$shadow"
    command cp "$STATUS" "$shadow/golem-status.sh"
    command cp "$REPO_ROOT/plugins/workflow/scripts/config.sh" "$shadow/config.sh"
    # THE GUARDS ARE ORDERED, so each needs a stub that SATISFIES the preceding
    # ones and trips only its own — a single all-garbage stub trips the first
    # guard and leaves the later two unexercised (they survived mutation that
    # way). Each row below is malformed in exactly one field.
    # No RUN_RC here: golem-status exits 0 in every case below (the malformed
    # output is the subject, not the exit status), so only RUN_OUT is asserted.
    _cb_case() {
        command cat >"$shadow/context-budget.sh"
        command chmod +x "$shadow/context-budget.sh"
        RUN_OUT="$(cd "$sb" &&
            /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
                HOME="$sb" TMUX= TMUX_TMPDIR="$sb/.tmux" \
                GOLEM_WORKTREE_DIR=.worktrees GOLEM_STATUS_DIR=.worktrees/.status \
                GOLEM_BASE_REF=HEAD GOLEM_WORKTREE_LOCAL_FILES="" \
                CLAUDE_PROJECTS_DIR="$sb/projects" \
                "$REAL_BASH" "$shadow/golem-status.sh" 2>&1)" || true
    }

    # (a) non-numeric COUNT — pct and verdict are well-formed.
    _cb_case <<'EOF'
#!/usr/bin/env bash
echo "context_tokens=TRUNCA"
echo "pct_of_threshold=50"
echo "verdict=ok"
exit 0
EOF
    assert_contains "$RUN_OUT" "context unknown" "a non-numeric count degrades to unknown"
    assert_not_contains "$RUN_OUT" "TRUNCA" "the garbage count never reaches the table"

    # (b) non-numeric PCT — count and verdict are well-formed, so guard (a) passes
    # and only the pct guard can catch this.
    _cb_case <<'EOF'
#!/usr/bin/env bash
echo "context_tokens=160000"
echo "pct_of_threshold=NN"
echo "verdict=ok"
exit 0
EOF
    assert_contains "$RUN_OUT" "context unknown" "a non-numeric pct degrades to unknown"
    assert_not_contains "$RUN_OUT" "160000 tokens" \
        "a valid-looking count is NOT rendered beside an unparsable percent"

    # (c) unrecognized VERDICT — count and pct are well-formed, so both earlier
    # guards pass and only the allowlist can catch this.
    _cb_case <<'EOF'
#!/usr/bin/env bash
echo "context_tokens=160000"
echo "pct_of_threshold=91"
echo "verdict=partial"
exit 0
EOF
    assert_contains "$RUN_OUT" "context unknown" "an unrecognized verdict degrades to unknown"
    assert_not_contains "$RUN_OUT" "partial" \
        "an unrecognized verdict is never rendered as if it were real"
    assert_not_contains "$RUN_OUT" "160000 tokens" \
        "nor is its reading rendered under some other verdict's wording"
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
