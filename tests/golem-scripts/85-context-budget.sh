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

# WHY THERE IS NO FORCED-NO-JQ CASE HERE. The cases below skip when jq is absent,
# which normally hides a branch (the self-skipping-test class). Reviewed twice and
# measured rather than assumed: with jq stubbed off PATH, golem-status still
# renders the block as
#
#     CONTEXT BUDGET (session-length signal — #784 handoff threshold):
#       golem-42 — context unknown (no transcript)
#
# — the honest degradation, not a silent omission. And deleting the block's own
# `command -v jq` gate produces BYTE-IDENTICAL output, because the row cannot be
# populated without jq either way. So no assertion can distinguish gated from
# ungated: a test here would pass with and without the code it claims to pin.
#
# The genuinely risky no-jq path is context-budget.sh's own exit 3, and THAT one
# is covered by a forced-absence case (test_missing_jq_exits_3 in
# tests/validate-context-budget.sh), where the two arms really do differ.

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
    # golem-status.sh sources its per-golem signal families from a sibling
    # fragment (#800), resolved from SCRIPT_DIR like config.sh above — so the
    # shadow dir needs it too, or the copied script loads neither reader and the
    # block under test never renders at all.
    command cp "$REPO_ROOT/plugins/workflow/scripts/golem-status-signals.sh" \
        "$shadow/golem-status-signals.sh"
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

# A MISSING context-budget.sh must degrade to `unknown`, not error the sweep.
# Every other `unknown` case gets there by RUNNING the script and having it fail
# or emit garbage; this one removes the script entirely.
#
# SCOPE NOTE, measured rather than assumed: this pins the DEGRADATION, not the
# `[ -x "$ctxbudget" ]` guard specifically. Deleting that guard leaves this test
# green, because invoking an unresolvable path yields empty stdout, which the
# empty-capture fallback already maps to `unknown` — so the -x check is an
# optimization (it avoids a doomed exec and its stderr), not the thing producing
# the observable behavior, and no assertion over output can distinguish the two.
# The degradation itself is what an operator depends on, and that IS pinned here.
test_status_handles_a_missing_context_budget_script() {
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
    # A transcript IS planted: with a working script this row would read 200100,
    # so the assertion below distinguishes "the guard held" from "there was
    # nothing to read anyway".
    plant_transcript "$sb" 42 "$TRANSCRIPT_CTX_HANDOFF"
    shadow="$sb/shadow"
    command mkdir -p "$shadow"
    command cp "$STATUS" "$shadow/golem-status.sh"
    command cp "$REPO_ROOT/plugins/workflow/scripts/config.sh" "$shadow/config.sh"
    # golem-status.sh sources its per-golem signal families from a sibling
    # fragment (#800), resolved from SCRIPT_DIR like config.sh above — so the
    # shadow dir needs it too, or the copied script loads neither reader and the
    # block under test never renders at all.
    command cp "$REPO_ROOT/plugins/workflow/scripts/golem-status-signals.sh" \
        "$shadow/golem-status-signals.sh"
    # Deliberately NO context-budget.sh beside it.
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" TMUX= TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD GOLEM_WORKTREE_LOCAL_FILES="" \
            CLAUDE_PROJECTS_DIR="$sb/projects" \
            "$REAL_BASH" "$shadow/golem-status.sh" 2>&1)" || true
    assert_contains "$RUN_OUT" "context unknown" \
        "a missing context-budget.sh degrades to unknown, not an error"
    assert_not_contains "$RUN_OUT" "200100 tokens" \
        "and certainly not a reading it had no way to obtain"
    assert_not_contains "$RUN_OUT" "No such file" \
        "no raw exec error leaks into the table"
}

# THREE golems, three different states, one sweep. Every other case plants a
# single cache row, so the render loop only ever ran one iteration — and the
# `_rcb_*` variables are function-scoped by prefix convention, not by `local`, so
# a value can survive into the next iteration. That is precisely the shape that
# stays invisible with one golem: a container row leaking its short-circuit into
# the next golem, or a stale reading being reprinted under another golem's name,
# needs a SECOND iteration to appear at all.
# context-budget.sh PRESENT but not executable. Pins the DEGRADATION and the
# absence of stderr leakage, both operator-visible.
#
# It does NOT pin the `-x` guard, and that was measured, not assumed: cycle 7's
# review proposed this case specifically to catch the guard, on the theory that a
# non-executable file (unlike a missing one) would reach an exec and leak
# "Permission denied". It does reach an exec — but that message goes to STDERR,
# which read_context_budget already redirects in the same expression, so stdout is
# empty either way and deleting the guard leaves this test green. Verified by
# mutation. The guard is a genuine no-op with respect to output in BOTH the
# missing and non-executable cases; it avoids a pointless exec, nothing more.
test_status_handles_a_non_executable_context_budget() {
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
    plant_transcript "$sb" 42 "$TRANSCRIPT_CTX_HANDOFF"
    shadow="$sb/shadow"
    command mkdir -p "$shadow"
    command cp "$STATUS" "$shadow/golem-status.sh"
    command cp "$REPO_ROOT/plugins/workflow/scripts/config.sh" "$shadow/config.sh"
    # golem-status.sh sources its per-golem signal families from a sibling
    # fragment (#800), resolved from SCRIPT_DIR like config.sh above — so the
    # shadow dir needs it too, or the copied script loads neither reader and the
    # block under test never renders at all.
    command cp "$REPO_ROOT/plugins/workflow/scripts/golem-status-signals.sh" \
        "$shadow/golem-status-signals.sh"
    command cp "$REPO_ROOT/plugins/workflow/scripts/context-budget.sh" \
        "$shadow/context-budget.sh"
    command chmod -x "$shadow/context-budget.sh"
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" TMUX= TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD GOLEM_WORKTREE_LOCAL_FILES="" \
            CLAUDE_PROJECTS_DIR="$sb/projects" \
            "$REAL_BASH" "$shadow/golem-status.sh" 2>&1)" || true
    assert_contains "$RUN_OUT" "context unknown" \
        "a non-executable context-budget.sh degrades to unknown"
    assert_not_contains "$RUN_OUT" "Permission denied" \
        "the -x guard short-circuits before an exec that would leak this"
    assert_not_contains "$RUN_OUT" "200100 tokens" \
        "no reading is rendered from a script that never ran"
}

test_status_renders_each_golem_independently() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (context budget needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    # golem-1: a real handoff-due reading.
    command cat >"$sb/.worktrees/.status/golem-1.json" <<'EOF'
{ "golem": "golem-1", "issue": 1, "branch": "feature/issue-1",
  "state": "impl", "blocking": false }
EOF
    plant_transcript "$sb" 1 "$TRANSCRIPT_CTX_HANDOFF"
    # golem-2: a container row, which short-circuits before any scrape. Placed
    # BETWEEN the other two so a leak of its early return would swallow golem-3.
    command cat >"$sb/.worktrees/.status/golem-2.json" <<'EOF'
{ "golem": "golem-2", "issue": 2, "branch": "feature/issue-2",
  "state": "impl", "blocking": false, "container": "golem-2-ctr" }
EOF
    # golem-3: a small, ok-band reading — deliberately DIFFERENT from golem-1's,
    # so a stale-variable leak renders golem-1's 200100 here and fails.
    command cat >"$sb/.worktrees/.status/golem-3.json" <<'EOF'
{ "golem": "golem-3", "issue": 3, "branch": "feature/issue-3",
  "state": "impl", "blocking": false }
EOF
    plant_transcript "$sb" 3 "$TRANSCRIPT_CTX_OK"
    run_status_scrape "$sb"
    assert_contains "$RUN_OUT" "golem-1 — 200100 tokens" "golem-1 shows its own reading"
    assert_contains "$RUN_OUT" "golem-2 — context not readable (container golem)" \
        "the container row renders its own note"
    assert_contains "$RUN_OUT" "golem-3 — 20000 tokens" \
        "golem-3 shows ITS reading, not the one two rows up"
    assert_not_contains "$RUN_OUT" "golem-3 — 200100 tokens" \
        "no stale reading leaks across loop iterations"
    assert_not_contains "$RUN_OUT" "golem-3 — context not readable" \
        "nor does the container short-circuit leak into the next golem"
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

# --- the signals fragment is actually wired in (#800) -----------------------

# Both per-golem signal families live in the sourced fragment
# plugins/workflow/scripts/golem-status-signals.sh, and golem-status.sh reaches
# them through ONE `.` line. Every other case in this file and its siblings
# exercises them through a full render, which means a dropped source line fails
# only OBLIQUELY — with `set -u` and no `set -e`, an undefined render function is
# a per-call "command not found" on stderr and the rows simply go missing, so the
# failure reads as "the context budget stopped working" rather than "the fragment
# is not loaded". This case names the real cause.
#
# It is deliberately a SOURCE test, not a render test: sourcing golem-status.sh
# runs everything above its main-guard and nothing below, so what it proves is
# exactly the wiring — the fragment loads, before either render function needs
# it. `declare -F` (not a rendered string) is what makes the assertion about
# DEFINITION rather than output, which is why it still fails when a render
# happens to degrade gracefully.
#
# The five names cover both families — each reader, each render half, plus the
# renderer they share — so relocating any one of them out of the fragment
# without updating the caller is caught here too.
test_status_sources_the_signals_fragment() {
    local sb out
    new_sandbox sb
    out="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" \
            TMUX= TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees GOLEM_STATUS_DIR=.worktrees/.status \
            "$REAL_BASH" -c '
                source "$1"
                for fn in scrape_and_persist_tokens read_context_budget \
                    _frozen_phrase render_token_block render_context_budget_block; do
                    if declare -F "$fn" >/dev/null 2>&1; then
                        printf "have:%s\n" "$fn"
                    else
                        printf "MISSING:%s\n" "$fn"
                    fi
                done
            ' _ "$STATUS" 2>/dev/null || true)"
    assert_contains "$out" "have:scrape_and_persist_tokens" \
        "the token reader is loaded via the fragment"
    assert_contains "$out" "have:read_context_budget" \
        "the context reader is loaded via the fragment"
    assert_contains "$out" "have:_frozen_phrase" \
        "the shared frozen renderer is loaded via the fragment"
    assert_contains "$out" "have:render_token_block" \
        "the token render half is loaded via the fragment"
    assert_contains "$out" "have:render_context_budget_block" \
        "the context render half is loaded via the fragment"
    assert_not_contains "$out" "MISSING:" \
        "no signal unit is left behind by the source line"
}
