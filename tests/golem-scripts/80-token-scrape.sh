# shellcheck shell=bash
# golem-token-scrape.sh — golem helper-script tests (issue #564 split).
#
# Covers the golem-status token signal (#371) — message.id dedup and the frozen/advancing render.
#
# Sourced by tests/validate-golem-scripts.sh, which defines the path consts
# (LAUNCH / WT_NEW / STATUS / ...) and sources tests/lib/golem-sandbox.sh for the
# shared sandbox plumbing (new_sandbox / run_in / ...) BEFORE this file. This
# fragment therefore only DEFINES test functions; the entry point dispatches them
# from its explicit ordered run_test list.

# --- golem-token-scrape.sh + golem-status token signal (#371) ---------------

# scrape sums TOP-LEVEL output_tokens only, deduped by message.id (150),
# excluding the sidechain 999 and never multi-counting the 3-block turn m1.
test_scrape_sums_top_level_only() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (scrape needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 "$TRANSCRIPT_MIXED"
    run_scrape "$sb" "$sb/.worktrees/issue-42"
    assert_exit 0 "$RUN_RC" "scrape of a planted transcript exits 0"
    # Exact match (not a substring) so the naive per-line sum 350 can't slip past
    # a loose "contains 150" — the whole point of the #371 dedup fix.
    assert_true "[ '$RUN_OUT' = '150' ]" "sums top-level output_tokens deduped by message.id (150, got '$RUN_OUT')"
    assert_not_contains "$RUN_OUT" "350" "the 3-block turn m1 is counted once, not per-line (naive sum 350 is the regression)"
    assert_not_contains "$RUN_OUT" "999" "the sub-workflow token count is excluded"
}

# No transcript directory → fail-loud (exit 2 + message), never a silent 0.
test_scrape_missing_transcript_fails_loud() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (scrape needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    run_scrape "$sb" "$sb/.worktrees/issue-42"
    assert_exit 2 "$RUN_RC" "scrape with no transcript dir exits 2 (fail-loud)"
    assert_contains "$RUN_OUT" "no transcript dir" "names the missing transcript"
}

# TRULY no worktree arg (argc 0) → usage error, exit 1. `run_scrape` passes an
# empty-STRING positional (argc 1), which reaches the transcript-missing path
# (exit 2), so invoke the script directly with no positional at all here.
test_scrape_no_arg_exits_1() {
    local sb
    new_sandbox sb
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" CLAUDE_PROJECTS_DIR="$sb/projects" \
            "$REAL_BASH" "$SCRAPE" 2>&1)" || RUN_RC=$?
    assert_exit 1 "$RUN_RC" "scrape with no argument exits 1 (usage)"
    assert_contains "$RUN_OUT" "usage:" "prints the usage message on the no-arg path"
}

# Newest-mtime *.jsonl wins when multiple sessions exist (post-/clear fresh file).
test_scrape_newest_session_wins() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (scrape needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    local slug dir
    slug="$(slug_for "$sb/.worktrees/issue-42")"
    dir="$sb/projects/$slug"
    command mkdir -p "$dir"
    command printf '%s\n' '{"isSidechain":false,"message":{"usage":{"output_tokens":10}}}' >"$dir/old.jsonl"
    # Ensure a distinct, newer mtime on the second file.
    command sleep 1
    command printf '%s\n' '{"isSidechain":false,"message":{"usage":{"output_tokens":77}}}' >"$dir/new.jsonl"
    run_scrape "$sb" "$sb/.worktrees/issue-42"
    assert_exit 0 "$RUN_RC" "scrape with two sessions exits 0"
    assert_contains "$RUN_OUT" "77" "the newest-mtime session (77) is the one summed"
}

# A truncated/malformed trailing line (expected when a session is captured
# mid-write) is skipped, and the valid records before it still sum correctly.
test_scrape_tolerates_truncated_trailing_line() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (scrape needs jq)"
        return 0
    fi
    local sb slug dir
    new_sandbox sb
    slug="$(slug_for "$sb/.worktrees/issue-42")"
    dir="$sb/projects/$slug"
    command mkdir -p "$dir"
    # Two valid top-level records (60) then a truncated final line (no newline,
    # unterminated JSON) — the fromjson? guard must drop it without aborting.
    {
        command printf '%s\n' '{"isSidechain":false,"message":{"id":"a","usage":{"output_tokens":40}}}'
        command printf '%s\n' '{"isSidechain":false,"message":{"id":"b","usage":{"output_tokens":20}}}'
        command printf '%s' '{"isSidechain":false,"message":{"usage":{'
    } >"$dir/session.jsonl"
    run_scrape "$sb" "$sb/.worktrees/issue-42"
    assert_exit 0 "$RUN_RC" "scrape tolerates a truncated trailing line (exit 0)"
    assert_true "[ '$RUN_OUT' = '60' ]" "sums the valid records (60), dropping the truncated line (got '$RUN_OUT')"
}

# jq missing on PATH → fail-loud exit 3, independent of whether the host has jq.
# A stub bin dir with a shadowing non-jq PATH exercises the version-gate arm.
test_scrape_no_jq_exits_3() {
    local sb
    new_sandbox sb
    command mkdir -p "$sb/nojq-bin"
    # A PATH holding only coreutils the script needs (via /usr/bin) but NO jq. We
    # point PATH at an empty stub dir plus /usr/bin sans jq is hard to guarantee,
    # so instead prepend a stub dir and drop /usr/bin's jq by pointing PATH at a
    # curated dir. Simplest portable approach: PATH= the stub dir only, and the
    # script's `command -v jq` fails. bash builtins still work; /usr/bin/* calls in
    # the script use absolute paths so they survive the stripped PATH.
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            --unset=BASH_ENV \
            HOME="$sb" CLAUDE_PROJECTS_DIR="$sb/projects" \
            PATH="$sb/nojq-bin" \
            "$REAL_BASH" "$SCRAPE" "$sb/.worktrees/issue-42" 2>&1)" || RUN_RC=$?
    assert_exit 3 "$RUN_RC" "scrape with no jq on PATH exits 3 (fail-loud)"
    assert_contains "$RUN_OUT" "jq not found" "names jq as the missing dependency"
}
