# shellcheck shell=bash
# golem-status.sh --checkpoint — golem helper-script tests (issue #564 split).
#
# Covers change-suppression (#488), the compact per-track status+burn table (#283), and its follow-up coverage (#415).
#
# Sourced by tests/validate-golem-scripts.sh, which defines the path consts
# (LAUNCH / WT_NEW / STATUS / ...) and sources tests/lib/golem-sandbox.sh for the
# shared sandbox plumbing (new_sandbox / run_in / ...) BEFORE this file. This
# fragment therefore only DEFINES test functions; the entry point dispatches them
# from its explicit ordered run_test list.

# --- golem-status.sh --checkpoint change-suppression (#488) ------------------

# A no-op --watch checkpoint sweep must not re-emit the whole table. With one
# stable cache row and GOLEM_SWEEP_INTERVAL=1 over a ~3s window, the full
# "STATUS CHECKPOINT" table renders exactly ONCE (first sweep) and every later
# unchanged sweep collapses to a single "no change since" heartbeat line. This is
# the primary AC: two consecutive no-change sweeps emit no repeated full table.
test_status_checkpoint_suppresses_noop_sweep() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status table needs jq)"
        return 0
    fi
    if ! command -v timeout >/dev/null 2>&1; then
        skip_test "timeout not available (cannot bound the --watch loop)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "impl", "phase": "make-it-work", "blocking": false }
EOF
    run_in_watch "$sb" 3 GOLEM_SWEEP_INTERVAL=1 -- --checkpoint --watch --level 3
    assert_exit 0 "$RUN_RC" "bounded --checkpoint --watch loop exits cleanly"
    local table_count
    table_count="$(command printf '%s\n' "$RUN_OUT" | command grep -c '^STATUS CHECKPOINT')"
    assert_true "[ '$table_count' = '1' ]" \
        "the full table renders exactly once across a no-change window (got $table_count)"
    assert_contains "$RUN_OUT" "no change since" \
        "later no-op sweeps collapse to a heartbeat line (proves >=2 sweeps, suppressed)"
}

# render_source_checkpoint <outvar> <sandbox> <interval> — source $STATUS in the
# sandbox (source guard, like gate_age_unit) and call render_checkpoint N times
# IN ONE PROCESS so the module-scope cp_prev_sig persists across calls (the same
# thing the --watch loop relies on). The sequence is fixed here: render once,
# render again unchanged, flip golem-42's .blocking to true, render a third time.
# Captures the combined stdout of all three renders so a single assertion set can
# check "printed → suppressed → re-emitted". Deterministic (no timing).
render_source_seq() {
    local __out="$1" dir="$2" interval="$3" _rss_out
    _rss_out="$(cd "$dir" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$dir" \
            TMUX= TMUX_TMPDIR="$dir/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees GOLEM_STATUS_DIR=.worktrees/.status \
            "$REAL_BASH" -c '
                source "$1"
                render_checkpoint "$2"
                render_checkpoint "$2"
                printf "%s" "{ \"golem\": \"golem-42\", \"issue\": 42, \"state\": \"impl\", \"blocking\": true }" \
                    >"$3/golem-42.json"
                render_checkpoint "$2"
            ' _ "$STATUS" "$interval" "$dir/.worktrees/.status" 2>/dev/null || true)"
    printf -v "$__out" '%s' "$_rss_out"
}

# A real row-state change re-emits promptly even after a suppressed sweep. Drive
# render_checkpoint three times in one process: (1) first render prints the table,
# (2) an identical sweep is suppressed to a heartbeat, (3) after flipping .blocking
# the table re-emits with the ⚠ BLOCKED marker. Anchors on the render-line/marker
# forms, never a bare feed echo (repo memory on feed-echo false-passes).
test_status_checkpoint_reemits_on_state_change() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status table needs jq)"
        return 0
    fi
    local sb out table_count
    new_sandbox sb
    command printf '%s' \
        '{ "golem": "golem-42", "issue": 42, "state": "impl", "blocking": false }' \
        >"$sb/.worktrees/.status/golem-42.json"
    render_source_seq out "$sb" 60
    # Two full tables total: the first render and the post-flip re-emit. The middle
    # (unchanged) sweep is suppressed, so the count is 2, not 3.
    table_count="$(command printf '%s\n' "$out" | command grep -c '^STATUS CHECKPOINT')"
    assert_true "[ '$table_count' = '2' ]" \
        "table prints on render 1 and re-emits on the state change, but not the unchanged sweep (got $table_count)"
    assert_contains "$out" "no change since" \
        "the unchanged middle sweep is suppressed to a heartbeat"
    assert_contains "$out" "⚠ BLOCKED" \
        "the post-flip re-emit carries the BLOCKED state marker"
}

# The verbose render must NOT dump raw feed JSON (#488) — that was pure
# token-dense duplication of the classified BLOCKED/LIVENESS blocks. Plant a feed
# line with a distinctive marker; the render shows the one-line "Recent feed:"
# count but never the raw JSON.
test_status_verbose_no_raw_feed_dump() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status table needs jq)"
        return 0
    fi
    local sb sd
    new_sandbox sb
    sd="$sb/.worktrees/.status"
    command cat >"$sd/golem-7.json" <<'EOF'
{ "golem": "golem-7", "issue": 7, "branch": "feature/issue-7",
  "state": "impl", "phase": "make-it-work", "blocking": false }
EOF
    command cat >"$sd/feed.jsonl" <<'EOF'
{"golem":"golem-7","event":"idle","message":"DISTINCTFEEDMARKER working","ts":"2026-07-21T00:00:00Z"}
EOF
    run_in "$sb" "$STATUS"
    assert_exit 0 "$RUN_RC" "verbose render exits 0 with a planted feed"
    assert_contains "$RUN_OUT" "Recent feed: 1 line(s)" \
        "the verbose render shows a one-line feed count, not the raw JSON tail"
    assert_not_contains "$RUN_OUT" "DISTINCTFEEDMARKER" \
        "the raw feed JSON is no longer echoed into the render (#488)"
}

# render_source_gap <outvar> <sandbox> <interval> — like render_source_seq but the
# MIDDLE sweep hits the empty-state early return (the golem cache file is removed),
# then the SAME golem at the SAME state reappears. Drives render_checkpoint three
# times in one process: (1) render full, (2) remove golem-42.json → "No active
# golems" early return, (3) restore the identical golem-42.json → render again.
render_source_gap() {
    local __out="$1" dir="$2" interval="$3" _rsg_out
    _rsg_out="$(cd "$dir" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$dir" \
            TMUX= TMUX_TMPDIR="$dir/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees GOLEM_STATUS_DIR=.worktrees/.status \
            "$REAL_BASH" -c '
                row="{ \"golem\": \"golem-42\", \"issue\": 42, \"state\": \"impl\", \"blocking\": false }"
                source "$1"
                render_checkpoint "$2"
                rm -f "$3/golem-42.json"
                render_checkpoint "$2"
                printf "%s" "$row" >"$3/golem-42.json"
                render_checkpoint "$2"
            ' _ "$STATUS" "$interval" "$dir/.worktrees/.status" 2>/dev/null || true)"
    printf -v "$__out" '%s' "$_rsg_out"
}

# Regression (#488, review Bug 1): a sweep that renders NO table (all golems
# vanished → empty-state early return) is a GAP; the prior signature must be
# cleared so the SAME golem set reappearing at the SAME state is NOT wrongly
# suppressed as "no change". Without the clear, sweep 3 would compare equal to
# sweep 1's signature and hide the vanish→reappear transition behind a heartbeat.
test_status_checkpoint_gap_clears_suppression() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status table needs jq)"
        return 0
    fi
    local sb out table_count
    new_sandbox sb
    command printf '%s' \
        '{ "golem": "golem-42", "issue": 42, "state": "impl", "blocking": false }' \
        >"$sb/.worktrees/.status/golem-42.json"
    render_source_gap out "$sb" 60
    # Two full tables: sweep 1 and the post-reappear sweep 3. Sweep 2 is the
    # empty-state early return (no table, no heartbeat). A stale-suppression bug
    # would make this count 1 (sweep 3 suppressed) — the discriminator.
    table_count="$(command printf '%s\n' "$out" | command grep -c '^STATUS CHECKPOINT')"
    assert_true "[ '$table_count' = '2' ]" \
        "the reappearing golem re-renders in full after an empty-state gap, not a heartbeat (got $table_count)"
    assert_contains "$out" "No active golems" \
        "the middle sweep hit the empty-state early return (the gap)"
    assert_not_contains "$out" "no change since" \
        "the reappear is never collapsed to a heartbeat — the gap cleared the prior signature (#488)"
}

# Regression (#488, review Bug 2): the blank separator line between the pool
# header and the STATUS CHECKPOINT title (present in the pre-#488 render) must
# survive the buffer restructure — a byte-layout parity check.
test_status_checkpoint_pool_header_blank_line() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status table needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-9.json" <<'EOF'
{ "golem": "golem-9", "issue": 9, "state": "impl", "blocking": false }
EOF
    command cat >"$sb/.worktrees/.status/pool.json" <<'EOF'
{ "size": 3, "slots": [1, 2], "backlog_depth": 5, "accepting": "open" }
EOF
    run_in "$sb" "$STATUS" --checkpoint
    assert_exit 0 "$RUN_RC" "one-shot --checkpoint with a pool exits 0"
    # The pool line, a blank line, then the title — the exact three-line sequence.
    assert_contains "$RUN_OUT" "queue=open"$'\n'$'\n'"STATUS CHECKPOINT" \
        "a blank line separates the pool header from the checkpoint title (#488)"
}

# Regression (#488, review Bug 3): a one-shot --checkpoint (no --watch) must still
# surface the cache-mirror caveat (on stderr) — the relocation from per-sweep to
# once-at-startup must not drop it from the one-shot snapshot path.
test_status_checkpoint_oneshot_shows_cache_mirror_note() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status table needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-9.json" <<'EOF'
{ "golem": "golem-9", "issue": 9, "state": "impl", "blocking": false }
EOF
    run_in "$sb" "$STATUS" --checkpoint
    assert_exit 0 "$RUN_RC" "one-shot --checkpoint exits 0"
    # run_in merges stdout+stderr; the caveat lands on stderr but is captured here.
    assert_contains "$RUN_OUT" "PR/CI/Review are cache mirrors" \
        "the one-shot --checkpoint still prints the cache-mirror caveat (#488)"
}

# Regression (#488, review follow-up): the heartbeat's golem count uses a
# `grep -o '|' | wc -l` count, NOT `grep -c '|'` — GNU grep -c exits 1 on a zero
# count, which with a `|| echo 0` fallback double-appends and splits the heartbeat
# across two lines. The bug ONLY surfaces when cp_sig has zero `|` rows: a
# pool.json present (so the empty-state early return is skipped) but no golem
# cache rows and no live sessions. Drive render_checkpoint twice in-process; the
# suppressed 2nd sweep must be a SINGLE line reading "(0 golem(s))".
test_status_checkpoint_zero_golem_heartbeat_single_line() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status table needs jq)"
        return 0
    fi
    local sb out hb_lines
    new_sandbox sb
    # pool.json only — no golem-*.json, no tmux sessions (TMUX_TMPDIR is empty).
    command cat >"$sb/.worktrees/.status/pool.json" <<'EOF'
{ "size": 3, "slots": [], "backlog_depth": 0, "accepting": "open" }
EOF
    out="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" TMUX= TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees GOLEM_STATUS_DIR=.worktrees/.status \
            "$REAL_BASH" -c 'source "$1"; render_checkpoint "$2"; render_checkpoint "$2"' \
            _ "$STATUS" 60 2>/dev/null || true)"
    # The suppressed sweep's heartbeat must be exactly one line with (0 golem(s)) —
    # a split count renders "(0" and "0 golem(s))" on two lines.
    assert_contains "$out" "no change since" \
        "the zero-golem sweep is suppressed to a heartbeat"
    assert_contains "$out" "(0 golem(s))" \
        "the zero-golem heartbeat count is a clean single-line 0, not a split grep -c count (#488)"
    hb_lines="$(command printf '%s\n' "$out" | command grep -c 'golem(s))')"
    assert_true "[ '$hb_lines' = '1' ]" \
        "the heartbeat 'golem(s)' phrase renders on exactly one line (got $hb_lines)"
}

# render_source_multi <outvar> <sandbox> <interval> — three in-process renders
# over a MULTI-golem batch (the real use case, not the single-row fixtures the
# other #488 tests use): render full, render again unchanged (all suppressed),
# then flip ONLY golem-2's .blocking and render again — the whole table must
# re-emit (coarse-grained) with golem-2 ⚠ BLOCKED and the others still present.
render_source_multi() {
    local __out="$1" dir="$2" interval="$3" _rsm_out
    _rsm_out="$(cd "$dir" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$dir" \
            TMUX= TMUX_TMPDIR="$dir/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees GOLEM_STATUS_DIR=.worktrees/.status \
            "$REAL_BASH" -c '
                source "$1"
                render_checkpoint "$2"
                render_checkpoint "$2"
                printf "%s" "{ \"golem\": \"golem-2\", \"issue\": 2, \"state\": \"impl\", \"blocking\": true }" \
                    >"$3/golem-2.json"
                render_checkpoint "$2"
            ' _ "$STATUS" "$interval" "$dir/.worktrees/.status" 2>/dev/null || true)"
    printf -v "$__out" '%s' "$_rsm_out"
}

# Regression (#488, review test-coverage finding): the suppression signature is
# built by concatenating EVERY row's golem|statecol across a batch. With 3 golems,
# an unchanged sweep must suppress the whole table, and flipping ONE golem's state
# must re-emit the whole table (all three rows) — the coarse-grained guarantee the
# feature exists for. Asserts the exact 3-count heartbeat too.
test_status_checkpoint_multi_golem_batch_suppression() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status table needs jq)"
        return 0
    fi
    local sb out table_count
    new_sandbox sb
    command printf '%s' '{ "golem": "golem-1", "issue": 1, "state": "impl", "blocking": false }' \
        >"$sb/.worktrees/.status/golem-1.json"
    command printf '%s' '{ "golem": "golem-2", "issue": 2, "state": "impl", "blocking": false }' \
        >"$sb/.worktrees/.status/golem-2.json"
    command printf '%s' '{ "golem": "golem-3", "issue": 3, "state": "impl", "blocking": false }' \
        >"$sb/.worktrees/.status/golem-3.json"
    render_source_multi out "$sb" 60
    # Full table on sweep 1 and the post-flip sweep 3; sweep 2 suppressed.
    table_count="$(command printf '%s\n' "$out" | command grep -c '^STATUS CHECKPOINT')"
    assert_true "[ '$table_count' = '2' ]" \
        "the 3-golem batch renders once, suppresses the unchanged sweep, and re-emits the whole table on a single-row flip (got $table_count)"
    assert_contains "$out" "(3 golem(s))" \
        "the heartbeat counts all three batch rows"
    assert_contains "$out" "⚠ BLOCKED" \
        "the re-emitted table carries golem-2's flipped BLOCKED state"
    # All three rows are present in the re-emitted table (coarse-grained re-emit,
    # not just the changed row) — golem-1 and golem-3 render alongside golem-2.
    assert_contains "$out" "golem-1" "golem-1 is still rendered in the re-emitted table"
    assert_contains "$out" "golem-3" "golem-3 is still rendered in the re-emitted table"
}

# --- --checkpoint compact per-track status+burn table (#283) -----------------

# write_two_golem_tracks_sandbox <sandbox-var> — shared fixture for the checkpoint
# tests: two Mode-2 golem cache rows (42 in review-cycle with a PR + started;
# 89 ci-failing + blocking), a tracks.json placing 42 in lane 0 and 89 in lane 1,
# and a planted 150-token transcript for issue 42. new_sandbox does NOT write a
# tracks.json, so the grouping tests author it by hand.
# Internal sandbox var is uniquely named (`_wtgs_sb`) so it collides with neither
# the caller's out-var nor new_sandbox's own internal `dir` local — otherwise
# new_sandbox's `printf -v` would write a shadowed local and the path would never
# propagate (the dynamic-scope pitfall new_sandbox itself sidesteps).
write_two_golem_tracks_sandbox() {
    local __out="$1" _wtgs_sb
    new_sandbox _wtgs_sb
    command cat >"$_wtgs_sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "review-cycle", "phase": "ship", "pr": 310, "blocking": false,
  "started": "2026-07-19T00:00:00Z" }
EOF
    command cat >"$_wtgs_sb/.worktrees/.status/golem-89.json" <<'EOF'
{ "golem": "golem-89", "issue": 89, "branch": "feature/issue-89",
  "state": "ci-failing", "phase": "implement", "blocking": true }
EOF
    command cat >"$_wtgs_sb/.worktrees/.status/tracks.json" <<'EOF'
{ "tracks": [ { "lane": 0, "issues": [42], "autonomy_level": 2 },
              { "lane": 1, "issues": [89], "autonomy_level": 3 } ] }
EOF
    plant_transcript "$_wtgs_sb" 42 "$TRANSCRIPT_MIXED"
    printf -v "$__out" '%s' "$_wtgs_sb"
}

# --checkpoint renders the compact per-track table header, groups rows by lane,
# and prints the batch-totals footer.
test_status_checkpoint_renders_table_and_footer() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb
    write_two_golem_tracks_sandbox sb
    run_status_scrape "$sb" --checkpoint
    assert_exit 0 "$RUN_RC" "golem-status --checkpoint exits 0"
    assert_contains "$RUN_OUT" "STATUS CHECKPOINT" "renders the checkpoint section header"
    assert_contains "$RUN_OUT" "TOKENS(Δ)" "renders the burn column header"
    # tracks.json puts 42 in lane 0 and 89 in lane 1 → both lane labels appear.
    assert_contains "$RUN_OUT" "L0" "golem-42 is grouped under its lane (L0)"
    assert_contains "$RUN_OUT" "L1" "golem-89 is grouped under its lane (L1)"
    assert_contains "$RUN_OUT" "150 (first)" "the 150-token transcript shows as a first reading"
    assert_contains "$RUN_OUT" "BATCH:" "prints the batch-totals footer"
    assert_contains "$RUN_OUT" "tokens=150" "footer sums the top-level tokens"
    # One-shot (no --watch) has no prior sweep → rate must be — , never fabricated.
    assert_contains "$RUN_OUT" "rate=—" "a one-shot checkpoint prints rate=— (no prior sweep to diff)"
    # The verbose render is REPLACED, not stacked, so its section header is absent.
    assert_not_contains "$RUN_OUT" "TOP-LEVEL TOKENS" "checkpoint replaces the verbose render, not stacks it"
}

# The burn Δ is computed across two sweeps: first reading has no delta, a grown
# transcript on the second sweep reports the (+N) delta and folds it into Δ.
test_status_checkpoint_delta_across_sweeps() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "working", "phase": "implement", "blocking": false }
EOF
    plant_transcript "$sb" 42 '{"isSidechain":false,"message":{"id":"m1","usage":{"output_tokens":100}}}'
    run_status_scrape "$sb" --checkpoint
    assert_contains "$RUN_OUT" "100 (first)" "first sweep shows the count as a first reading"
    # Grow the top-level tokens by 25 → 125, then re-render: advancing (+25).
    local slug dir
    slug="$(slug_for "$sb/.worktrees/issue-42")"
    dir="$sb/projects/$slug"
    command printf '%s\n' \
        '{"isSidechain":false,"message":{"id":"m1","usage":{"output_tokens":100}}}' \
        '{"isSidechain":false,"message":{"id":"m2","usage":{"output_tokens":25}}}' >"$dir/session.jsonl"
    run_status_scrape "$sb" --checkpoint
    assert_contains "$RUN_OUT" "125 (+25)" "the second sweep shows the +25 burn delta"
    assert_contains "$RUN_OUT" "Δ=25" "the footer folds the per-golem delta into the batch Δ"
}

# With no tracks.json, every golem falls into the single untracked (—) group —
# the standalone/pool behavior (nlanes=0 → lane loop skipped).
test_status_checkpoint_no_tracks_untracked_group() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "working", "phase": "implement", "blocking": false }
EOF
    plant_transcript "$sb" 42 "$TRANSCRIPT_MIXED"
    # No tracks.json written → the golem must still render, in the — group.
    run_status_scrape "$sb" --checkpoint
    assert_exit 0 "$RUN_RC" "checkpoint with no tracks.json exits 0"
    assert_contains "$RUN_OUT" "golem-42" "the golem renders even with no tracks.json"
    assert_contains "$RUN_OUT" "STATUS CHECKPOINT" "still renders the checkpoint table"
}

# A tracks.json (a status-dir sibling, not a golem-status file) must NOT be
# rendered as a bogus golem row — the latent glob bug fixed alongside #283.
test_status_checkpoint_excludes_tracks_json() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb
    write_two_golem_tracks_sandbox sb
    # The VERBOSE render must also skip tracks.json (the glob is shared).
    run_status_scrape "$sb"
    assert_exit 0 "$RUN_RC" "verbose render with a tracks.json exits 0"
    assert_not_contains "$RUN_OUT" "tracks.json" "tracks.json is not rendered as a golem row"
}

# BLOCKED / CI-failing attention markers ride the STATE column as plain text (⚠),
# distinct from a normal state — never ANSI colour.
test_status_checkpoint_attention_markers() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb
    write_two_golem_tracks_sandbox sb
    run_status_scrape "$sb" --checkpoint
    # golem-89 is blocking → ⚠ BLOCKED; the blocked count is tallied in the footer.
    assert_contains "$RUN_OUT" "⚠ BLOCKED" "a blocking golem shows the ⚠ BLOCKED marker"
    assert_contains "$RUN_OUT" "blocked=1" "the footer tallies the blocked golem"
    # No ANSI escape sequences leak into the table (stays legible in a log/pipe).
    assert_not_contains "$RUN_OUT" "$(command printf '\033')" "the checkpoint table emits no ANSI colour"
}

# --checkpoint composes with --watch/--level: a bounded watch renders the compact
# table and the level-scaled cadence banner, exiting cleanly when timed out.
test_status_checkpoint_watch_composes() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb
    write_two_golem_tracks_sandbox sb
    # run_in_watch bounds the loop; --level 2 resolves the ~5-min cadence banner.
    run_in_watch "$sb" 2 \
        GOLEM_STATUS_DIR=.worktrees/.status \
        CLAUDE_PROJECTS_DIR="$sb/projects" \
        -- --checkpoint --watch --level 2 --interval 1
    assert_exit 0 "$RUN_RC" "--checkpoint --watch is a valid, bounded sweep (exit 0)"
    assert_contains "$RUN_OUT" "STATUS CHECKPOINT" "the watch loop renders the compact table"
    assert_contains "$RUN_OUT" "Status sweep every 1s" "the sweep banner reports the resolved cadence"
}

# A DROP in the cumulative top-level count across sweeps (a fresh session after
# /clear, per golem-token-scrape.sh's documented shape) renders as `(reset)` — a
# new baseline — and is EXCLUDED from the burn Δ, never a nonsensical negative
# delta or a fabricated negative aggregate rate. Regression guard for the
# signed-delta bug the pre-PR review reproduced.
test_status_checkpoint_reset_on_count_drop() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb slug dir
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-5.json" <<'EOF'
{ "golem": "golem-5", "issue": 5, "branch": "feature/issue-5",
  "state": "working", "phase": "implement", "blocking": false }
EOF
    slug="$(slug_for "$sb/.worktrees/issue-5")"
    dir="$sb/projects/$slug"
    command mkdir -p "$dir"
    # Sweep 1: a 500-token session establishes the baseline.
    command printf '%s\n' '{"isSidechain":false,"message":{"id":"a","usage":{"output_tokens":500}}}' >"$dir/session.jsonl"
    run_status_scrape "$sb" --checkpoint
    assert_contains "$RUN_OUT" "500 (first)" "first sweep establishes the 500-token baseline"
    # Sweep 2: a fresh, SMALLER session (count drops 500 -> 50) — a new baseline.
    command sleep 1
    command printf '%s\n' '{"isSidechain":false,"message":{"id":"b","usage":{"output_tokens":50}}}' >"$dir/session2.jsonl"
    run_status_scrape "$sb" --checkpoint
    assert_contains "$RUN_OUT" "50 (reset)" "a count drop renders as (reset), a new baseline"
    assert_not_contains "$RUN_OUT" "(+-" "a drop never renders a negative signed delta"
    assert_contains "$RUN_OUT" "Δ=0" "a reset is excluded from the batch burn Δ (no negative)"
    assert_not_contains "$RUN_OUT" "Δ=-" "the batch Δ never goes negative on a reset"
}

# The ⚠ gone marker fires for a cache golem whose tmux session vanished while a
# SIBLING golem session is still up (the wedged/dead-golem signal). Uses a tmux
# stub reporting only golem-42's session, so golem-99 (no session) reads ⚠ gone
# and golem-42 does not. Both golems are NON-blocking, so ⚠ gone is not masked by
# the higher-priority ⚠ BLOCKED marker (the shared fixture's golem-89 IS blocking,
# which is why this test builds its own non-blocking rows).
test_status_checkpoint_session_gone_marker() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "review-cycle", "phase": "ship", "blocking": false }
EOF
    command cat >"$sb/.worktrees/.status/golem-99.json" <<'EOF'
{ "golem": "golem-99", "issue": 99, "branch": "feature/issue-99",
  "state": "working", "phase": "implement", "blocking": false }
EOF
    # A tmux stub that lists ONLY golem-42 alive (golem-99's session is gone).
    # golem-status.sh scans `tmux ls | grep -oE '^golem-[0-9]+'`, so the stub
    # prints one matching line for `ls` and nothing for other subcommands.
    command mkdir -p "$sb/bin"
    command cat >"$sb/bin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    ls) printf 'golem-42: 1 windows\n' ;;
esac
exit 0
EOF
    command chmod +x "$sb/bin/tmux"
    # --unset=BASH_ENV: in the devcontainer BASH_ENV points at /etc/bash_env,
    # which resets $PATH on non-interactive bash and would shadow the stub tmux
    # with the real one (see the devcontainer-bash-env-path-reset note).
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            --unset=BASH_ENV \
            HOME="$sb" \
            PATH="$sb/bin:$PATH" \
            TMUX= TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            CLAUDE_PROJECTS_DIR="$sb/projects" \
            "$REAL_BASH" "$STATUS" --checkpoint 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "checkpoint with a partial tmux session set exits 0"
    assert_contains "$RUN_OUT" "⚠ gone" "golem-99 (session vanished, sibling up) shows ⚠ gone"
    # golem-42's session IS present → it must NOT be flagged gone; it keeps its
    # real state (review-cycle), proving the marker is per-golem, not global.
    assert_contains "$RUN_OUT" "review-cycle" "golem-42 (session present) keeps its real state, not ⚠ gone"
}

# A corrupted persisted top_level_tokens value (the cache is co-written by the
# orchestrator model, so a non-canonical field is possible) must NOT throw a bash
# arithmetic error and drop the golem's row — the persisted prior is numeric-
# guarded the same way the freshly-scraped value is. Regression guard for the
# monitoring-integrity finding: `"089"` (a quoted leading-zero string) is invalid
# octal in `$(( ))` and previously vanished the row.
test_status_checkpoint_corrupt_prev_tokens_no_drop() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    # Seed a cache row whose persisted count is a corrupt string ("089").
    command cat >"$sb/.worktrees/.status/golem-8.json" <<'EOF'
{ "golem": "golem-8", "issue": 8, "branch": "feature/issue-8",
  "state": "working", "phase": "implement", "blocking": false,
  "top_level_tokens": "089", "top_level_tokens_at": "2026-07-19T00:00:00Z" }
EOF
    plant_transcript "$sb" 8 "$TRANSCRIPT_MIXED"
    run_status_scrape "$sb" --checkpoint
    assert_exit 0 "$RUN_RC" "a corrupt persisted token value does not crash --checkpoint"
    assert_contains "$RUN_OUT" "golem-8" "the golem's row is still rendered (not dropped by an arithmetic error)"
    # The corrupt prior is treated as no-prior → a fresh 'first' reading, never a
    # bash 'value too great for base' error leaking into the table.
    assert_contains "$RUN_OUT" "150 (first)" "a corrupt (leading-zero) prior reads as a fresh first reading"
    assert_not_contains "$RUN_OUT" "value too great" "no bash octal error leaks into the output"

    # An OVERFLOW-sized persisted value (>18 digits, past bash's signed 64-bit
    # range) must also degrade to a safe 'first' reading — NOT throw "integer
    # expression expected" and misclassify as frozen (a false #369 takeover signal).
    command cat >"$sb/.worktrees/.status/golem-8.json" <<'EOF'
{ "golem": "golem-8", "issue": 8, "branch": "feature/issue-8",
  "state": "working", "phase": "implement", "blocking": false,
  "top_level_tokens": 99999999999999999999999999999, "top_level_tokens_at": "2026-07-19T00:00:00Z" }
EOF
    run_status_scrape "$sb" --checkpoint
    assert_exit 0 "$RUN_RC" "an overflow-sized persisted token value does not crash --checkpoint"
    assert_contains "$RUN_OUT" "150 (first)" "an overflow prior reads as a fresh first reading, not frozen"
    assert_not_contains "$RUN_OUT" "integer expression" "no bash overflow error leaks into the output"
}

# derive_stage prefers .phase_detail over .phase/.state — assert the highest-
# priority Stage source actually wins (guards the jq `//` precedence).
test_status_checkpoint_stage_prefers_phase_detail() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-7.json" <<'EOF'
{ "golem": "golem-7", "issue": 7, "branch": "feature/issue-7",
  "state": "working", "phase": "implement", "phase_detail": "loop:make-it-tested",
  "blocking": false }
EOF
    plant_transcript "$sb" 7 "$TRANSCRIPT_MIXED"
    run_status_scrape "$sb" --checkpoint
    assert_contains "$RUN_OUT" "loop:make-it-tested" "STAGE shows .phase_detail, its highest-priority source"
}

# The ⚠ CI marker fires independently of BLOCKED: a ci-failing golem that is NOT
# blocking reaches the ci-failing branch (the shared fixture's golem-89 sets both,
# so BLOCKED masks it there). Also exercises the 'merged' → shipped tally.
test_status_checkpoint_ci_and_shipped_markers() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-11.json" <<'EOF'
{ "golem": "golem-11", "issue": 11, "branch": "feature/issue-11",
  "state": "ci-failing", "phase": "implement", "blocking": false }
EOF
    command cat >"$sb/.worktrees/.status/golem-12.json" <<'EOF'
{ "golem": "golem-12", "issue": 12, "branch": "feature/issue-12",
  "state": "merged", "phase": "ship", "blocking": false }
EOF
    run_status_scrape "$sb" --checkpoint
    assert_contains "$RUN_OUT" "⚠ CI" "a ci-failing, non-blocking golem shows ⚠ CI (not masked by BLOCKED)"
    assert_contains "$RUN_OUT" "shipped=1" "a merged golem is tallied as shipped in the footer"
    assert_contains "$RUN_OUT" "blocked=1" "the ci-failing golem is tallied as blocked"
}

# The checkpoint Tokens(Δ) column renders an UNPOSTED container ('n/a', excluded
# from totals) and a transcript-less ('—') golem distinctly — checkpoint-specific
# formatting the verbose token tests do not cover.
test_status_checkpoint_container_and_unknown_tokens() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/agent01.json" <<'EOF'
{ "golem": "agent01", "issue": 300, "container": "proj-agent01-1",
  "branch": "agent01", "state": "working", "blocking": false }
EOF
    command cat >"$sb/.worktrees/.status/golem-77.json" <<'EOF'
{ "golem": "golem-77", "issue": 77, "branch": "feature/issue-77",
  "state": "working", "blocking": false }
EOF
    run_status_scrape "$sb" --checkpoint
    assert_contains "$RUN_OUT" "n/a" "an unposted container golem's Tokens(Δ) shows n/a (Mode-3, #390)"
    assert_contains "$RUN_OUT" "tokens=0" "unposted container + transcript-less golems contribute 0 tokens to the total"
}

# A container golem whose host-POST HAS landed folds its posted count into the
# checkpoint Σtokens total (rendered with a (frozen) tag), but a one-shot
# --checkpoint still shows rate=— (per-sweep Δ / rate need golem-status's own
# prior sample, which the read-only container path deliberately doesn't keep). (#390)
test_status_checkpoint_container_populated_tokens() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb anchor
    new_sandbox sb
    anchor="$(iso_ago 130)"
    if [ -z "$anchor" ]; then
        skip_test "date toolchain cannot seed an ISO anchor"
        return 0
    fi
    command cat >"$sb/.worktrees/.status/agent01.json" <<EOF
{ "golem": "agent01", "issue": 300, "container": "proj-agent01-1",
  "branch": "agent01", "state": "working", "blocking": false,
  "top_level_tokens": 4242, "top_level_tokens_at": "$anchor" }
EOF
    run_status_scrape "$sb" --checkpoint
    assert_contains "$RUN_OUT" "4242 (frozen)" \
        "a posted container's Tokens(Δ) shows the count with a (frozen) tag (#390)"
    assert_contains "$RUN_OUT" "tokens=4242" "a posted container folds its count into Σtokens"
    assert_contains "$RUN_OUT" "rate=—" \
        "a one-shot --checkpoint shows rate=— — a container has no per-sweep Δ baseline"
}

# --- --checkpoint follow-up coverage (#415, deferred from #283/PR #414) -------

# The ELAPSED column renders a REAL duration derived from .started (not just that
# the row renders). A .started ~130s in the past must show _fmt_dur's minutes arm
# ("2m"), never the "—" empty sentinel a missing .started would leave. Mirrors
# test_status_fmt_dur_minute_arm's iso_ago anchoring, but asserts the checkpoint
# ELAPSED cell specifically (the #283 tests only assert the row is present).
test_status_checkpoint_elapsed_from_started() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb anchor
    new_sandbox sb
    anchor="$(iso_ago 130)"
    if [ -z "$anchor" ]; then
        skip_test "date could not compute a past anchor"
        return 0
    fi
    command cat >"$sb/.worktrees/.status/golem-42.json" <<EOF
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "review-cycle", "phase": "ship", "blocking": false,
  "started": "$anchor" }
EOF
    plant_transcript "$sb" 42 "$TRANSCRIPT_MIXED"
    run_status_scrape "$sb" --checkpoint
    assert_exit 0 "$RUN_RC" "golem-status --checkpoint with a .started anchor exits 0"
    # ~130s → 2m (well past the 60s boundary, so a few seconds of test latency
    # can't flip the arm). Match the render form, not an exact minute count.
    assert_true "printf '%s' \"\$RUN_OUT\" | command grep -Eq '[0-9]+m'" \
        "ELAPSED renders a real minutes duration derived from .started"
    assert_not_contains "$RUN_OUT" "frozen 0m" "a >60s elapsed never rounds to 0m"
}

# When .started is ABSENT (a Mode-2 golem whose dispatch wrote no cache stamp),
# ELAPSED must NOT collapse to the bare "—" that pushes the operator onto manual
# cross-clock arithmetic. Instead it falls back to the golem worktree dir's
# creation/index mtime — a TZ-agnostic epoch — rendered with a "~" prefix to mark
# it approximate (issue #515). The worktree dir must exist for _mtime_epoch to
# resolve; new_sandbox creates .worktrees/.status but not the per-issue dir.
test_status_checkpoint_elapsed_fallback_no_started() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    # No "started" field at all — the exact Mode-2 no-cache-writer gap.
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "review-cycle", "phase": "ship", "blocking": false }
EOF
    # A real worktree dir + a `.git` gitlink file (the stable launch anchor a
    # linked worktree carries) so the primary mtime fallback resolves.
    command mkdir -p "$sb/.worktrees/issue-42"
    command printf 'gitdir: /somewhere/.git/worktrees/issue-42\n' >"$sb/.worktrees/issue-42/.git"
    plant_transcript "$sb" 42 "$TRANSCRIPT_MIXED"
    run_status_scrape "$sb" --checkpoint
    assert_exit 0 "$RUN_RC" "golem-status --checkpoint with no .started exits 0"
    # The ELAPSED cell shows a "~"-prefixed approximate age (e.g. "~0s"/"~1m"),
    # never a bare "—". Match the "~<digits><unit>" render form.
    assert_true "printf '%s' \"\$RUN_OUT\" | command grep -Eq '~[0-9]+[sm]'" \
        "ELAPSED falls back to a ~-marked worktree-mtime age when .started is absent (#515)"
}

# The fallback triggers on a present-but-UNPARSABLE .started too, not just an
# absent one: _iso_to_epoch returns empty for a garbage timestamp, ELAPSED stays
# "—" after the .started branch, and the worktree-mtime fallback takes over
# (#515). Mirrors test_status_frozen_iso_parse_failure_raw_render (#392) for the
# ELAPSED path.
test_status_checkpoint_elapsed_fallback_malformed_started() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "review-cycle", "phase": "ship", "blocking": false,
  "started": "not-a-valid-timestamp" }
EOF
    command mkdir -p "$sb/.worktrees/issue-42"
    command printf 'gitdir: /somewhere/.git/worktrees/issue-42\n' >"$sb/.worktrees/issue-42/.git"
    plant_transcript "$sb" 42 "$TRANSCRIPT_MIXED"
    run_status_scrape "$sb" --checkpoint
    assert_exit 0 "$RUN_RC" "golem-status --checkpoint with a malformed .started exits 0"
    assert_true "printf '%s' \"\$RUN_OUT\" | command grep -Eq '~[0-9]+[sm]'" \
        "an unparsable .started still falls through to the ~-marked mtime fallback (#515)"
}

# The fallback is a fallback, not a fabrication: a started-less row whose
# worktree dir does NOT exist (container/reaped, or a genuinely anchorless row)
# keeps the bare "—" rather than inventing an age. new_sandbox does not create
# .worktrees/issue-42, so the anchor cannot resolve.
test_status_checkpoint_elapsed_no_anchor_stays_dash() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "review-cycle", "phase": "ship", "blocking": false }
EOF
    # Deliberately NO .worktrees/issue-42 dir → _mtime_epoch returns empty.
    plant_transcript "$sb" 42 "$TRANSCRIPT_MIXED"
    run_status_scrape "$sb" --checkpoint
    assert_exit 0 "$RUN_RC" "golem-status --checkpoint with no anchor exits 0"
    assert_true "! printf '%s' \"\$RUN_OUT\" | command grep -Eq '~[0-9]+[sm]'" \
        "no worktree anchor → ELAPSED stays — , never a fabricated ~age (#515)"
}

# render_checkpoint's TWO early returns: (a) empty status dir + no sessions + no
# pool → "No active golems", exit 0 (the shared empty-state guard, before jq);
# (b) jq absent from PATH → the "cannot render checkpoint table" guard on stderr,
# exit 0 (degrade, not abort). The jq case plants a cache row so the empty-state
# guard is NOT the reason the table is skipped — isolating the jq gate. PATH is a
# curated shim of every tool the script tree needs EXCEPT jq (mirrors
# test_status_no_jq_skips_token_block).
test_status_checkpoint_empty_and_no_jq_guards() {
    local sb shim tp
    new_sandbox sb
    # (a) Empty-state early return (jq-independent: the guard precedes the jq
    # check, so run it unconditionally).
    run_status_scrape "$sb" --checkpoint
    assert_exit 0 "$RUN_RC" "--checkpoint with no golems exits 0"
    assert_contains "$RUN_OUT" "No active golems" "--checkpoint empty state reports no active golems"
    assert_not_contains "$RUN_OUT" "STATUS CHECKPOINT" "the empty-state guard returns before the table header"

    # (b) jq-missing early return: a curated PATH shim without jq + a planted
    # cache row (so the empty-state guard is passed and the jq gate is the sole
    # reason the table is skipped).
    shim="$sb/shim"
    command mkdir -p "$shim"
    for t in git dirname env date mktemp mv rm tmux bash sh; do
        tp="$(command -v "$t" 2>/dev/null)" && command ln -s "$tp" "$shim/$t"
    done
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "working", "blocking": false }
EOF
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            --unset=BASH_ENV \
            HOME="$sb" \
            TMUX= TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            CLAUDE_PROJECTS_DIR="$sb/projects" \
            PATH="$shim" \
            "$REAL_BASH" "$STATUS" --checkpoint 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "--checkpoint without jq still exits 0 (degrades, not aborts)"
    assert_contains "$RUN_OUT" "cannot render checkpoint table" \
        "--checkpoint without jq emits the fail-soft guard message"
    assert_not_contains "$RUN_OUT" "STATUS CHECKPOINT" "no table header is printed without jq"
}

# The pool.json header (the `Pool:` line) renders ahead of the checkpoint table
# when a pool.json sibling is present — the same header render_status prints. No
# other checkpoint test writes a pool.json, so this is the first fixture for it;
# fields (size/slots/backlog/queue) mirror the jq in render_checkpoint.
test_status_checkpoint_pool_header() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "working", "phase": "implement", "blocking": false }
EOF
    command cat >"$sb/.worktrees/.status/pool.json" <<'EOF'
{ "size": 3, "slots": [42, 89], "backlog_depth": 5, "queue": "open" }
EOF
    run_status_scrape "$sb" --checkpoint
    assert_exit 0 "$RUN_RC" "--checkpoint with a pool.json exits 0"
    assert_contains "$RUN_OUT" "Pool: size=3" "renders the pool header size"
    assert_contains "$RUN_OUT" "slots=2/3" "renders slots-in-use / size"
    assert_contains "$RUN_OUT" "backlog=5" "renders the backlog depth"
    assert_contains "$RUN_OUT" "queue=open" "renders the queue state"
    assert_contains "$RUN_OUT" "STATUS CHECKPOINT" "the table still renders after the pool header"
    # pool.json must NOT be rendered as a bogus golem row (the shared glob exclusion).
    assert_not_contains "$RUN_OUT" "pool.json" "pool.json is not rendered as a golem row"
}

# A live golem-N tmux session with NO cache file yet renders a "(live)" tail row
# (mirrors render_status's tail rows). A tmux stub reports golem-77 alive while
# no .status/golem-77.json exists → the tail-row branch must emit it.
test_status_checkpoint_live_tail_row() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    # A cache row for a DIFFERENT golem so the table renders; golem-77 has none.
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "working", "phase": "implement", "blocking": false }
EOF
    # A tmux stub listing golem-77 alive (no cache file for it → a (live) row).
    command mkdir -p "$sb/bin"
    command cat >"$sb/bin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    ls) printf 'golem-77: 1 windows\n' ;;
esac
exit 0
EOF
    command chmod +x "$sb/bin/tmux"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            --unset=BASH_ENV \
            HOME="$sb" \
            PATH="$sb/bin:$PATH" \
            TMUX= TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            CLAUDE_PROJECTS_DIR="$sb/projects" \
            "$REAL_BASH" "$STATUS" --checkpoint 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "--checkpoint with a session-only golem exits 0"
    assert_contains "$RUN_OUT" "golem-77" "the session-only golem renders a tail row"
    assert_contains "$RUN_OUT" "(live)" "a cache-less session renders the (live) marker"
}

# Lane-boundary padding: a lane listing issue 42 must NOT capture the shorter
# issue 4 (the `" $iss "` exact-pad glob at the lane-membership check). The
# guarded bug is a PREFIX match — an unpadded " 4" is a substring of the lane
# string " 42 ", so without the exact trailing-space pad, issue 4 would wrongly
# land in issue 42's lane. Cache rows for 4 and 42, tracks.json lane 0 = [42]
# only → 4 falls to the untracked (—) group, not lane 0. Regression fixture for
# the in-code "so 4 does not match 42" comment.
test_status_checkpoint_lane_boundary_padding() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-4.json" <<'EOF'
{ "golem": "golem-4", "issue": 4, "branch": "feature/issue-4",
  "state": "working", "phase": "implement", "blocking": false }
EOF
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "working", "phase": "implement", "blocking": false }
EOF
    command cat >"$sb/.worktrees/.status/tracks.json" <<'EOF'
{ "tracks": [ { "lane": 0, "issues": [42], "autonomy_level": 2 } ] }
EOF
    run_status_scrape "$sb" --checkpoint
    assert_exit 0 "$RUN_RC" "--checkpoint with a single-issue lane exits 0"
    # golem-4's row must carry the untracked track label (—), not L0: issue 4 is
    # NOT in lane [42], and only a prefix (unpadded) match would pull it in. The
    # golem-4 row (its trailing space disambiguates it from golem-42) must render
    # and its first (TRACK) cell must not be L0.
    assert_true "command printf '%s\n' \"\$RUN_OUT\" | command grep -q 'golem-4 '" "golem-4 renders a row"
    assert_true "! command printf '%s\n' \"\$RUN_OUT\" | command grep 'golem-4 ' | command grep -q '^L0'" \
        "golem-4 is NOT pulled into lane 0 (issue 42's lane) by a prefix match"
    # golem-42 IS in lane 0 → its row starts with L0 (proves the lane join works).
    assert_true "command printf '%s\n' \"\$RUN_OUT\" | command grep 'golem-42' | command grep -q '^L0'" \
        "golem-42 IS grouped under its lane (L0)"
}

# derive_stage's fallback chain below .phase_detail: .phase wins when no
# .phase_detail; .state wins when neither .phase_detail nor .phase; "—" when none
# present. The #283 suite only asserts the .phase_detail win — these pin each
# lower rung of the jq `//` precedence individually.
test_status_checkpoint_derive_stage_fallbacks() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    # (a) .phase win — no .phase_detail.
    command cat >"$sb/.worktrees/.status/golem-1.json" <<'EOF'
{ "golem": "golem-1", "issue": 1, "branch": "feature/issue-1",
  "state": "working", "phase": "implement-phase", "blocking": false }
EOF
    # (b) .state win — neither .phase_detail nor .phase.
    command cat >"$sb/.worktrees/.status/golem-2.json" <<'EOF'
{ "golem": "golem-2", "issue": 2, "branch": "feature/issue-2",
  "state": "state-token", "blocking": false }
EOF
    # (c) "—" — none of the three Stage sources present.
    command cat >"$sb/.worktrees/.status/golem-3.json" <<'EOF'
{ "golem": "golem-3", "issue": 3, "branch": "feature/issue-3",
  "blocking": false }
EOF
    run_status_scrape "$sb" --checkpoint
    assert_exit 0 "$RUN_RC" "--checkpoint with the fallback-chain fixtures exits 0"
    assert_contains "$RUN_OUT" "implement-phase" "STAGE falls back to .phase when .phase_detail is absent"
    assert_contains "$RUN_OUT" "state-token" "STAGE falls back to .state when .phase_detail and .phase are absent"
    # golem-3 has no Stage source at all → its STAGE cell is the "—" sentinel. Its
    # STATE is also "—" (no .state), so assert the golem-3 row carries a "—" cell.
    assert_true "command printf '%s\n' \"\$RUN_OUT\" | command grep 'golem-3 ' | command grep -q '—'" \
        "STAGE degrades to — when no .phase_detail/.phase/.state is present"
}

# A container (Mode-3) golem is EXEMPT from the ⚠ gone marker even when a sibling
# golem-* session is visible (a container has no host tmux session by design, so
# session_gone would otherwise false-positive). The widened prefix-strip guard
# (`${_ecr_tstate#container}`) must keep BOTH container token-states exempt — the
# unposted `container-pending` AND the populated `container` (a regression that
# broke the strip for the 9-char populated string alone would slip past a
# pending-only fixture), so this test drives both.
test_status_checkpoint_container_never_gone() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb anchor
    new_sandbox sb
    anchor="$(iso_ago 130)"
    if [ -z "$anchor" ]; then
        skip_test "date toolchain cannot seed an ISO anchor"
        return 0
    fi
    # A tmux stub showing a SIBLING golem-42 alive (proving the server is
    # reachable) — the condition under which session_gone would fire for a row
    # with no matching session. The container must be exempt regardless.
    command mkdir -p "$sb/bin"
    command cat >"$sb/bin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    ls) printf 'golem-42: 1 windows\n' ;;
esac
exit 0
EOF
    command chmod +x "$sb/bin/tmux"
    # Two passes over the SAME scenario: (1) an unposted container (→
    # container-pending token-state) and (2) a populated container (posted
    # top_level_tokens + a valid anchor → the `container` token-state). Both must
    # stay exempt from ⚠ gone.
    local _label _cache
    for _label in pending populated; do
        if [ "$_label" = populated ]; then
            command cat >"$sb/.worktrees/.status/agent01.json" <<EOF
{ "golem": "agent01", "issue": 300, "container": "proj-agent01-1",
  "branch": "agent01", "state": "working", "blocking": false,
  "top_level_tokens": 4242, "top_level_tokens_at": "$anchor" }
EOF
        else
            command cat >"$sb/.worktrees/.status/agent01.json" <<'EOF'
{ "golem": "agent01", "issue": 300, "container": "proj-agent01-1",
  "branch": "agent01", "state": "working", "blocking": false }
EOF
        fi
        RUN_RC=0
        RUN_OUT="$(cd "$sb" &&
            /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
                --unset=BASH_ENV \
                HOME="$sb" \
                PATH="$sb/bin:$PATH" \
                TMUX= TMUX_TMPDIR="$sb/.tmux" \
                GOLEM_WORKTREE_DIR=.worktrees \
                GOLEM_STATUS_DIR=.worktrees/.status \
                GOLEM_BASE_REF=HEAD \
                GOLEM_WORKTREE_LOCAL_FILES="" \
                CLAUDE_PROJECTS_DIR="$sb/projects" \
                "$REAL_BASH" "$STATUS" --checkpoint 2>&1)" || RUN_RC=$?
        assert_exit 0 "$RUN_RC" "--checkpoint with a $_label container + sibling session exits 0"
        assert_contains "$RUN_OUT" "agent01" "the $_label container golem renders its row"
        # The container row keeps its plain state and is never flagged gone. Assert on
        # the agent01 row(s) EXACTLY: zero of them may carry ⚠ gone (a `grep | grep -qv`
        # would pass as soon as ONE line lacked the marker — vacuous with a footer line).
        assert_true "[ \"\$(command printf '%s\n' \"\$RUN_OUT\" | command grep 'agent01' | command grep -c '⚠ gone')\" -eq 0 ]" \
            "no $_label-container agent01 row is flagged ⚠ gone (both token-states exempt from session_gone)"
    done
}

# An issue-less cache row (no .issue → the literal "?") must NOT be spuriously
# flagged ⚠ gone: session_gone's `*" golem-? "*` glob would treat "?" as a
# single-char wildcard and match any live golem-N. The `"$_ecr_issue" != "?"`
# guard keeps the row on its plain state. Regression fixture for the #414 fix.
test_status_checkpoint_issueless_row_not_gone() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    # A cache row with NO issue field → .issue falls back to "?".
    command cat >"$sb/.worktrees/.status/golem-mystery.json" <<'EOF'
{ "golem": "golem-mystery", "branch": "feature/mystery",
  "state": "working", "phase": "implement", "blocking": false }
EOF
    # A tmux stub with a live sibling golem-42 — the exact condition under which
    # the "?"-as-wildcard glob would false-match and flag the issue-less row gone.
    command mkdir -p "$sb/bin"
    command cat >"$sb/bin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    ls) printf 'golem-42: 1 windows\n' ;;
esac
exit 0
EOF
    command chmod +x "$sb/bin/tmux"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            --unset=BASH_ENV \
            HOME="$sb" \
            PATH="$sb/bin:$PATH" \
            TMUX= TMUX_TMPDIR="$sb/.tmux" \
            GOLEM_WORKTREE_DIR=.worktrees \
            GOLEM_STATUS_DIR=.worktrees/.status \
            GOLEM_BASE_REF=HEAD \
            GOLEM_WORKTREE_LOCAL_FILES="" \
            CLAUDE_PROJECTS_DIR="$sb/projects" \
            "$REAL_BASH" "$STATUS" --checkpoint 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "--checkpoint with an issue-less row + sibling session exits 0"
    assert_contains "$RUN_OUT" "golem-mystery" "the issue-less golem still renders its row"
    # Zero golem-mystery rows may carry ⚠ gone — an exact count, not a `grep -qv`
    # that would pass on the first non-matching line (vacuous with a footer line).
    assert_true "[ \"\$(command printf '%s\n' \"\$RUN_OUT\" | command grep 'golem-mystery' | command grep -c '⚠ gone')\" -eq 0 ]" \
        "no issue-less (?) row is spuriously flagged ⚠ gone by the wildcard glob"
}

# A malformed tracks.json listing the SAME issue under two lanes must render the
# golem row (and count its tokens) exactly ONCE — the `claimed` set dedups it
# across the lane passes. Without the guard the row (and its token total) would
# double. Regression fixture for the #414 double-lane-claim dedup.
test_status_checkpoint_double_lane_claim_dedup() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status --checkpoint needs jq)"
        return 0
    fi
    local sb count
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "working", "phase": "implement", "blocking": false }
EOF
    # Issue 42 listed under BOTH lane 0 and lane 1 (malformed) — the dedup guard
    # must emit the row once, under the FIRST lane that claims it (L0).
    command cat >"$sb/.worktrees/.status/tracks.json" <<'EOF'
{ "tracks": [ { "lane": 0, "issues": [42], "autonomy_level": 2 },
              { "lane": 1, "issues": [42], "autonomy_level": 3 } ] }
EOF
    plant_transcript "$sb" 42 "$TRANSCRIPT_MIXED"
    run_status_scrape "$sb" --checkpoint
    assert_exit 0 "$RUN_RC" "--checkpoint with a double-claimed issue exits 0"
    # The golem-42 row appears exactly once, not once per claiming lane.
    count="$(command printf '%s\n' "$RUN_OUT" | command grep -c 'golem-42')"
    assert_true "[ '$count' -eq 1 ]" "golem-42 renders exactly once despite two lane claims (got $count)"
    # Its 150 tokens are counted once, not doubled to 300 in the batch total.
    assert_contains "$RUN_OUT" "tokens=150" "the double-claimed golem's tokens are summed once, not doubled"
    assert_not_contains "$RUN_OUT" "tokens=300" "no double-count of the twice-claimed golem's tokens"
}

# extract_write_status_py — pull the write_status() Python heredoc body out of
# provision-protocol.md (the Mode-3 container entrypoint lives as a bash code
# block in the doc, not a bundled script). Anchors on the exact write_status
# `command python3 - "$STATUS_FILE" <<'PY'` line — NOT the sibling status_poller
# block, which uses a different pre-heredoc line — and strips the 3-space
# markdown-fence indent so the body runs as standalone Python. Mirrors
# validate-template-sync.sh's inline-extraction approach.
extract_write_status_py() {
    command awk '
        /LA="\$\(now\)" command python3 - "\$STATUS_FILE" <<'"'"'PY'"'"'/ { grab = 1; next }
        grab && /^   PY$/ { exit }
        grab { sub(/^   /, ""); print }
    ' "$PROVISION_PROTOCOL"
}

# The WRITE side of the #415 fix: the extracted write_status() Python stamps
# `started` on the FIRST call and PRESERVES it (idempotent) on later calls — the
# `doc.get("started") or ...` behavior, distinct from a re-stamp-every-write bug
# that would perpetually reset --checkpoint ELAPSED to ~0. The checkpoint render
# tests above only exercise the READ side (a fixture with `started` already
# present), so this closes the write-side coverage gap the pre-PR review flagged.
test_provision_write_status_started_idempotent() {
    if ! command -v python3 >/dev/null 2>&1; then
        skip_test "python3 not available (write_status is a python heredoc)"
        return 0
    fi
    local sb body status_file first second
    new_sandbox sb
    body="$(extract_write_status_py)"
    # Guard the extraction itself: an empty body (anchor drift) must fail loudly,
    # never pass vacuously — the exact line the fix touches must be present.
    assert_not_empty "$body" "the write_status() Python body was extracted"
    assert_contains "$body" 'doc["started"] = doc.get("started") or os.environ["LA"]' \
        "the extracted body carries the idempotent started-stamp line (#415)"

    status_file="$sb/.worktrees/.status/agent01.json"
    # First call: no prior cache file → started is stamped with LA=T1.
    AGENT_ID=agent01 ISSUE=300 STATE=working ERR="" LA="2026-01-01T00:00:00Z" \
        python3 -c "$body" "$status_file"
    first="$(jq -r '.started' "$status_file" 2>/dev/null)"
    assert_true "[ '$first' = '2026-01-01T00:00:00Z' ]" \
        "the first write stamps started with the launch time (got '$first')"
    # Second call with a DIFFERENT LA=T2 (a later poller write): started must be
    # PRESERVED at T1, not overwritten — the idempotency the fix guarantees.
    AGENT_ID=agent01 ISSUE=300 STATE=pr-open ERR="" LA="2026-06-15T12:00:00Z" \
        python3 -c "$body" "$status_file"
    second="$(jq -r '.started' "$status_file" 2>/dev/null)"
    assert_true "[ '$second' = '2026-01-01T00:00:00Z' ]" \
        "a later write preserves the original started (not re-stamped to T2, got '$second')"
    # The state DID advance (proving the second write ran, not a no-op).
    assert_true "[ \"\$(jq -r '.state' '$status_file' 2>/dev/null)\" = 'pr-open' ]" \
        "the second write still updated the mutable state field"

    # #428 same-issue guarantee: a later write for the SAME issue must NOT wipe
    # the sibling monitor fields a prior status_poller write left (pr/ci/review/
    # blocking) — the reassignment reset below is mismatch-only. Seed them, write
    # again for issue 300, and confirm they survive (else the fleet monitor's
    # CI/PR columns would blank on every in-flight poll).
    jq '. + {pr:321, ci:"passing", review:"approved", blocking:false}' \
        "$status_file" >"$status_file.tmp" && command mv "$status_file.tmp" "$status_file"
    AGENT_ID=agent01 ISSUE=300 STATE=pr-open ERR="" LA="2026-06-16T12:00:00Z" \
        python3 -c "$body" "$status_file"
    assert_true "[ \"\$(jq -r '.pr // \"null\"' '$status_file' 2>/dev/null)\" = '321' ]" \
        "a same-issue write preserves the poller-written pr field (#428 mismatch-only reset)"
    assert_true "[ \"\$(jq -r '.ci // \"null\"' '$status_file' 2>/dev/null)\" = 'passing' ]" \
        "a same-issue write preserves the poller-written ci field"
}

# #428: the SAME agent slot reassigned to a DIFFERENT issue without the
# documented teardown ("Remove status file") → the bind-mounted host cache still
# holds the PREVIOUS issue's fields. A write for the new issue must clear every
# ISSUE-SCOPED field — not only `started` (ELAPSED, #415), but the sibling
# monitor fields status_poller writes (pr/ci/review/blocking) and `errors` — so
# --checkpoint and the fleet monitor never render the new issue with the old
# issue's CI/PR/blocking signal or a stale error. It must, however, PRESERVE the
# agent-slot IDENTITY fields (container/branch), which golem-status.sh keys
# Mode-3 detection off and golem-attach.sh uses to find the container. Its own
# sandbox — independent of the #415 idempotency test above.
test_provision_write_status_issue_reassignment_resets_stale_fields() {
    if ! command -v python3 >/dev/null 2>&1; then
        skip_test "python3 not available (write_status is a python heredoc)"
        return 0
    fi
    local sb body status_file
    new_sandbox sb
    body="$(extract_write_status_py)"
    assert_not_empty "$body" "the write_status() Python body was extracted"
    assert_contains "$body" \
        'doc = {k: doc[k] for k in ("golem", "kind", "container", "branch") if k in doc}' \
        "the extracted body carries the issue-mismatch reset (keep-identity whitelist) (#428)"

    status_file="$sb/.worktrees/.status/agent01.json"
    # First write establishes an issue-300 row with a launch time.
    AGENT_ID=agent01 ISSUE=300 STATE=working ERR="" LA="2026-01-01T00:00:00Z" \
        python3 -c "$body" "$status_file"
    # Seed the sibling poller fields + an error (a prior run that opened a failing
    # PR) so the reset has stale issue-scoped state to clear, PLUS the agent-slot
    # identity fields (container/branch) that must SURVIVE.
    jq '. + {pr:555, ci:"failing", review:"changes-requested", blocking:true,
             errors:["boom: previous issue failure"],
             container:"proj-agent01-1", branch:"agent01"}' \
        "$status_file" >"$status_file.tmp" && command mv "$status_file.tmp" "$status_file"
    # Reassign the SAME slot to issue 999 (no teardown between).
    AGENT_ID=agent01 ISSUE=999 STATE=working ERR="" LA="2026-09-01T09:00:00Z" \
        python3 -c "$body" "$status_file"

    assert_true "[ \"\$(jq -r '.started' '$status_file' 2>/dev/null)\" = '2026-09-01T09:00:00Z' ]" \
        "reassigning the slot to a new issue re-stamps started to now"
    assert_true "[ \"\$(jq -r '.issue' '$status_file' 2>/dev/null)\" = '999' ]" \
        "the row rebound to the new issue number"
    # The stale issue-scoped fields from issue 300 must be GONE — a reassigned
    # golem that has not opened a PR must not render as ci-failing/blocking/errored.
    assert_true "[ \"\$(jq -r '.pr // \"null\"' '$status_file' 2>/dev/null)\" = 'null' ]" \
        "reassignment clears the previous issue's stale pr number"
    assert_true "[ \"\$(jq -r '.ci // \"null\"' '$status_file' 2>/dev/null)\" = 'null' ]" \
        "reassignment clears the previous issue's stale ci status"
    assert_true "[ \"\$(jq -r '.review // \"null\"' '$status_file' 2>/dev/null)\" = 'null' ]" \
        "reassignment clears the previous issue's stale review decision"
    assert_true "[ \"\$(jq -r '.blocking // \"null\"' '$status_file' 2>/dev/null)\" = 'null' ]" \
        "reassignment clears the previous issue's stale blocking flag"
    assert_true "[ \"\$(jq -r '.errors | length' '$status_file' 2>/dev/null)\" = '0' ]" \
        "reassignment clears the previous issue's stale error message"
    # But the agent-slot IDENTITY fields must PERSIST — the container is still
    # live; wiping these would break golem-status Mode-3 detection + golem-attach.
    assert_true "[ \"\$(jq -r '.container // \"null\"' '$status_file' 2>/dev/null)\" = 'proj-agent01-1' ]" \
        "reassignment PRESERVES the agent-slot container identity field"
    assert_true "[ \"\$(jq -r '.branch // \"null\"' '$status_file' 2>/dev/null)\" = 'agent01' ]" \
        "reassignment PRESERVES the agent-slot branch identity field"

    # A malformed cache (issue as a numeric STRING, schema violation) must not be
    # coerced into a spurious mismatch: a same-issue write with prev issue "300"
    # (string) and ISSUE=300 must PRESERVE started, not wipe it (#428 defensive
    # int() coercion). Seed a string issue + a started, write same issue.
    printf '%s\n' '{"golem":"agent01","kind":"container","issue":"300","started":"2026-01-01T00:00:00Z"}' \
        >"$status_file"
    AGENT_ID=agent01 ISSUE=300 STATE=working ERR="" LA="2026-10-01T00:00:00Z" \
        python3 -c "$body" "$status_file"
    assert_true "[ \"\$(jq -r '.started' '$status_file' 2>/dev/null)\" = '2026-01-01T00:00:00Z' ]" \
        "a numeric-string cached issue is coerced, not treated as a mismatch (started preserved)"
}
