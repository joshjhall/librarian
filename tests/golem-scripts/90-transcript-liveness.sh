# shellcheck shell=bash
# golem-transcript-liveness.sh — golem helper-script tests (issue #564 split).
#
# Covers stop_reason / isApiErrorMessage classification and the mtime gate (#248).
#
# Sourced by tests/validate-golem-scripts.sh, which defines the path consts
# (LAUNCH / WT_NEW / STATUS / ...) and sources tests/lib/golem-sandbox.sh for the
# shared sandbox plumbing (new_sandbox / run_in / ...) BEFORE this file. This
# fragment therefore only DEFINES test functions; the entry point dispatches them
# from its explicit ordered run_test list.

# --- golem-transcript-liveness.sh (#248) ------------------------------------
# Direct unit coverage of the transcript classifier — the working/idle/errored
# read and its fail-loud exit codes. It resolves the SAME <projects>/<slug>/
# transcript as golem-token-scrape.sh (reusing plant_transcript/slug_for above),
# so the fixtures land where the script looks. The gate-watch suite exercises this
# script through liveness_snapshot's wiring; these pin its own contract in
# isolation.

# run_liveness <sandbox> <worktree-arg> — invoke golem-transcript-liveness.sh with
# the projects base pointed at the sandbox's fake $sb/projects. Captures
# RUN_RC/RUN_OUT.
run_liveness() {
    local sb="$1" arg="$2"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" \
            CLAUDE_PROJECTS_DIR="$sb/projects" \
            "$REAL_BASH" "$TRANSCRIPT_LIVENESS" "$arg" 2>&1)" || RUN_RC=$?
}

# A last top-level assistant turn still in flight (stop_reason "tool_use") → working.
test_liveness_working() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript-liveness needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 \
        '{"type":"assistant","isSidechain":false,"message":{"stop_reason":"tool_use"}}'
    run_liveness "$sb" "$sb/.worktrees/issue-42"
    assert_exit 0 "$RUN_RC" "a turn-in-flight transcript exits 0"
    assert_true "[ '$RUN_OUT' = 'working' ]" "classifies working (got '$RUN_OUT')"
}

# A last top-level assistant turn that ENDED (stop_reason "end_turn") → idle.
test_liveness_idle() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript-liveness needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 \
        '{"type":"assistant","isSidechain":false,"message":{"stop_reason":"end_turn"}}'
    run_liveness "$sb" "$sb/.worktrees/issue-42"
    assert_exit 0 "$RUN_RC" "a turn-ended transcript exits 0"
    assert_true "[ '$RUN_OUT' = 'idle' ]" "classifies idle (got '$RUN_OUT')"
}

# isApiErrorMessage on the last top-level assistant record → errored.
test_liveness_errored_api() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript-liveness needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 \
        '{"type":"assistant","isSidechain":false,"isApiErrorMessage":true,"message":{"stop_reason":"stop_sequence"}}'
    run_liveness "$sb" "$sb/.worktrees/issue-42"
    assert_exit 0 "$RUN_RC" "an API-error transcript exits 0"
    assert_true "[ '$RUN_OUT' = 'errored' ]" "classifies errored (got '$RUN_OUT')"
}

# A trailing "Unknown command" system record with NO top-level turn yet is the
# literal #229 first-command failure → errored (not indeterminate).
test_liveness_errored_unknown_command() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript-liveness needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 \
        '{"type":"system","subtype":"informational","content":"Unknown command: /workflow:next-issue"}'
    run_liveness "$sb" "$sb/.worktrees/issue-42"
    assert_exit 0 "$RUN_RC" "an unknown-command transcript exits 0"
    assert_true "[ '$RUN_OUT' = 'errored' ]" "classifies errored (got '$RUN_OUT')"
}

# The OTHER errored-via-Unknown-command path (#248 review): an assistant turn that
# already ENDED (end_turn) followed by a trailing "Unknown command" system record
# promotes idle → errored via the `.key > $last.key` ordering branch. The sibling
# test above exercises the no-top-level-turn branch; this pins the ordering branch,
# which would silently degrade to a plain 'idle' on an off-by-one.
test_liveness_errored_unknown_command_after_idle_turn() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript-liveness needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 \
        "$(command printf '%s\n%s' \
            '{"type":"assistant","isSidechain":false,"message":{"stop_reason":"end_turn"}}' \
            '{"type":"system","content":"Unknown command: /workflow:next-issue"}')"
    run_liveness "$sb" "$sb/.worktrees/issue-42"
    assert_exit 0 "$RUN_RC" "an idle-turn+trailing-unknown-command transcript exits 0"
    assert_true "[ '$RUN_OUT' = 'errored' ]" "idle turn + trailing Unknown command promotes to errored (got '$RUN_OUT')"
}

# A sub-workflow (isSidechain true) tool_use record must NOT mask a top-level idle.
test_liveness_sidechain_not_masking() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript-liveness needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 \
        "$(command printf '%s\n%s' \
            '{"type":"assistant","isSidechain":false,"message":{"stop_reason":"end_turn"}}' \
            '{"type":"assistant","isSidechain":true,"message":{"stop_reason":"tool_use"}}')"
    run_liveness "$sb" "$sb/.worktrees/issue-42"
    assert_exit 0 "$RUN_RC" "a mixed sidechain transcript exits 0"
    assert_true "[ '$RUN_OUT' = 'idle' ]" "top-level idle not masked by sidechain tool_use (got '$RUN_OUT')"
}

# No transcript dir → fail-loud (exit 2 + message), never a silent class. This is
# the Mode-3-container / no-host-transcript path the caller falls back from.
test_liveness_missing_transcript_fails_loud() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript-liveness needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    run_liveness "$sb" "$sb/.worktrees/issue-42"
    assert_exit 2 "$RUN_RC" "no transcript dir exits 2 (fail-loud)"
    assert_contains "$RUN_OUT" "no transcript dir" "names the missing transcript dir"
}

# A transcript with records but no top-level turn and no command error is
# indeterminate → exit 2 (the caller falls back to the mtime heartbeat).
test_liveness_indeterminate_exits_2() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript-liveness needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 '{"type":"user","message":{"role":"user"}}'
    run_liveness "$sb" "$sb/.worktrees/issue-42"
    assert_exit 2 "$RUN_RC" "an indeterminate transcript exits 2"
    assert_contains "$RUN_OUT" "indeterminate" "names the indeterminate condition"
}

# No worktree argument → usage error (exit 1).
test_liveness_no_arg_exits_1() {
    local sb
    new_sandbox sb
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" "$REAL_BASH" "$TRANSCRIPT_LIVENESS" 2>&1)" || RUN_RC=$?
    assert_exit 1 "$RUN_RC" "no worktree arg exits 1 (usage)"
    assert_contains "$RUN_OUT" "usage:" "prints usage on the no-arg path"
}

# Missing jq on PATH → exit 3 fail-loud (mirrors test_scrape_no_jq_exits_3).
test_liveness_no_jq_exits_3() {
    local sb
    new_sandbox sb
    command mkdir -p "$sb/nojq-bin"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            --unset=BASH_ENV \
            HOME="$sb" CLAUDE_PROJECTS_DIR="$sb/projects" \
            PATH="$sb/nojq-bin" \
            "$REAL_BASH" "$TRANSCRIPT_LIVENESS" "$sb/.worktrees/issue-42" 2>&1)" || RUN_RC=$?
    assert_exit 3 "$RUN_RC" "transcript-liveness with no jq on PATH exits 3 (fail-loud)"
    assert_contains "$RUN_OUT" "jq not found" "names jq as the missing dependency"
}

# A relative worktree arg resolves to the same slug as its absolute form (mirrors
# test_scrape_relative_worktree_path — the pwd-prefix branch of the slug logic).
test_liveness_relative_worktree_path() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript-liveness needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 \
        '{"type":"assistant","isSidechain":false,"message":{"stop_reason":"tool_use"}}'
    # cd into the sandbox and pass the RELATIVE path — pwd-prefixing must land on
    # the same slug the absolute-path plant used.
    run_liveness "$sb" ".worktrees/issue-42"
    assert_exit 0 "$RUN_RC" "a relative worktree arg resolves (exit 0)"
    assert_true "[ '$RUN_OUT' = 'working' ]" "relative arg classifies working like the absolute one (got '$RUN_OUT')"
}

# Staleness bound (#248 review): a `working` verdict whose transcript has sat
# unmodified past GOLEM_STALL_THRESHOLD is DEMOTED to indeterminate (exit 2) — a
# crashed process frozen at stop_reason:"tool_use" must NOT read `working`
# forever, or the caller's mtime stall check is permanently short-circuited.
test_liveness_stale_working_demoted() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript-liveness needs jq)"
        return 0
    fi
    local sb tfile
    new_sandbox sb
    plant_transcript "$sb" 42 \
        '{"type":"assistant","isSidechain":false,"message":{"stop_reason":"tool_use"}}'
    # Backdate the planted session transcript well past the default 1200s window.
    tfile="$sb/projects/$(slug_for "$sb/.worktrees/issue-42")/session.jsonl"
    command touch -d "@$(($(command date +%s) - 3600))" "$tfile"
    run_liveness "$sb" "$sb/.worktrees/issue-42"
    assert_exit 2 "$RUN_RC" "a stale 'working' transcript is demoted to indeterminate (exit 2)"
    assert_contains "$RUN_OUT" "stale 'working'" "names the staleness demotion"
}

# The staleness window is GOLEM_STALL_THRESHOLD-overridable: the same stale
# transcript above still reads `working` when the threshold is widened past its
# age (guards the env plumbing, symmetric to test_liveness_stale_working_demoted).
test_liveness_stale_working_threshold_overridable() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript-liveness needs jq)"
        return 0
    fi
    local sb tfile
    new_sandbox sb
    plant_transcript "$sb" 42 \
        '{"type":"assistant","isSidechain":false,"message":{"stop_reason":"tool_use"}}'
    tfile="$sb/projects/$(slug_for "$sb/.worktrees/issue-42")/session.jsonl"
    command touch -d "@$(($(command date +%s) - 3600))" "$tfile"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" \
            CLAUDE_PROJECTS_DIR="$sb/projects" \
            GOLEM_STALL_THRESHOLD=7200 \
            "$REAL_BASH" "$TRANSCRIPT_LIVENESS" "$sb/.worktrees/issue-42" 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "a widened threshold keeps the 3600s-old transcript 'working' (exit 0)"
    assert_true "[ '$RUN_OUT' = 'working' ]" "GOLEM_STALL_THRESHOLD widens the staleness window (got '$RUN_OUT')"
}

# A stale IDLE transcript is NOT demoted — only `working` is mtime-gated. A golem
# parked/errored at its prompt for a long time is still correctly idle, and that
# is the actionable signal (guards against over-broad staleness gating).
test_liveness_stale_idle_not_demoted() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript-liveness needs jq)"
        return 0
    fi
    local sb tfile
    new_sandbox sb
    plant_transcript "$sb" 42 \
        '{"type":"assistant","isSidechain":false,"message":{"stop_reason":"end_turn"}}'
    tfile="$sb/projects/$(slug_for "$sb/.worktrees/issue-42")/session.jsonl"
    command touch -d "@$(($(command date +%s) - 3600))" "$tfile"
    run_liveness "$sb" "$sb/.worktrees/issue-42"
    assert_exit 0 "$RUN_RC" "a long-idle transcript still classifies (exit 0)"
    assert_true "[ '$RUN_OUT' = 'idle' ]" "a stale idle transcript is not demoted (got '$RUN_OUT')"
}

# Fail-open on the staleness guard (#248 review): when the transcript's mtime is
# UNREADABLE (stat fails / returns non-numeric), the guard is skipped and the raw
# `working` class is trusted, rather than a stat quirk demoting a possibly-live
# golem. Force it by stubbing `stat` to emit garbage on a PATH that still carries
# real bash/git/jq — the script reaches stat via `command stat`, so the stub wins.
test_liveness_stale_working_stat_failure_fails_open() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript-liveness needs jq)"
        return 0
    fi
    local sb stub real_bash real_git real_jq
    new_sandbox sb
    plant_transcript "$sb" 42 \
        '{"type":"assistant","isSidechain":false,"message":{"stop_reason":"tool_use"}}'
    stub="$sb/stub-bin"
    command mkdir -p "$stub"
    real_bash="$(command -v bash)"
    real_git="$(command -v git)"
    real_jq="$(command -v jq)"
    command ln -s "$real_bash" "$stub/bash"
    command ln -s "$real_git" "$stub/git"
    command ln -s "$real_jq" "$stub/jq"
    # A `stat` that always emits non-numeric garbage and exits 0 — the script's
    # `command stat` resolves this stub, so _newest_mtime is non-numeric and the
    # guard's `'' | *[!0-9]*)` fail-open arm must fire (trust the class).
    command printf '%s\n' '#!/usr/bin/env bash' 'echo not-a-number' >"$stub/stat"
    command chmod +x "$stub/stat"
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
            HOME="$sb" \
            CLAUDE_PROJECTS_DIR="$sb/projects" \
            PATH="$stub:/usr/bin:/bin" \
            "$real_bash" "$TRANSCRIPT_LIVENESS" "$sb/.worktrees/issue-42" 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "an unreadable mtime fails open on the guard (exit 0)"
    assert_true "[ '$RUN_OUT' = 'working' ]" "a non-numeric stat result trusts the class, not a demotion (got '$RUN_OUT')"
}

# Newest-mtime session wins (#248 review, mirrors test_scrape_newest_session_wins):
# two sessions in the same project dir with different classes — the newer one's
# class is reported.
test_liveness_newest_session_wins() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript-liveness needs jq)"
        return 0
    fi
    local sb dir
    new_sandbox sb
    dir="$sb/projects/$(slug_for "$sb/.worktrees/issue-42")"
    command mkdir -p "$dir"
    # Older session: idle. Newer session: working. The newer must win.
    command printf '%s\n' '{"type":"assistant","isSidechain":false,"message":{"stop_reason":"end_turn"}}' \
        >"$dir/old.jsonl"
    command touch -d "@$(($(command date +%s) - 600))" "$dir/old.jsonl"
    command printf '%s\n' '{"type":"assistant","isSidechain":false,"message":{"stop_reason":"tool_use"}}' \
        >"$dir/new.jsonl"
    run_liveness "$sb" "$sb/.worktrees/issue-42"
    assert_exit 0 "$RUN_RC" "a two-session dir resolves (exit 0)"
    assert_true "[ '$RUN_OUT' = 'working' ]" "the newest-mtime session's class wins (got '$RUN_OUT')"
}

# A truncated/malformed trailing JSONL line is tolerated (#248 review, mirrors
# test_scrape_tolerates_truncated_trailing_line): `fromjson? // empty` skips it and
# the valid record above still classifies.
test_liveness_tolerates_truncated_trailing_line() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript-liveness needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 \
        "$(command printf '%s\n%s' \
            '{"type":"assistant","isSidechain":false,"message":{"stop_reason":"tool_use"}}' \
            '{"type":"assistant","isSid')"
    run_liveness "$sb" "$sb/.worktrees/issue-42"
    assert_exit 0 "$RUN_RC" "a truncated trailing line does not abort classification (exit 0)"
    assert_true "[ '$RUN_OUT' = 'working' ]" "the valid record classifies despite a truncated trailing line (got '$RUN_OUT')"
}

# golem-status renders the TOP-LEVEL TOKENS section: first read shows the count,
# a second read with an UNCHANGED transcript shows 'frozen', and the cache JSON
# gains top_level_tokens + top_level_tokens_at.
test_status_token_first_then_frozen() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status token block needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "review-cycle", "phase": "ship", "blocking": false }
EOF
    plant_transcript "$sb" 42 "$TRANSCRIPT_MIXED"
    run_status_scrape "$sb"
    assert_exit 0 "$RUN_RC" "golem-status with a token transcript exits 0"
    assert_contains "$RUN_OUT" "TOP-LEVEL TOKENS" "renders the token section"
    assert_contains "$RUN_OUT" "150 tokens (first reading)" "first read shows the count as a first reading"
    # The cache JSON now carries both persisted fields.
    local persisted
    persisted="$(jq -r '.top_level_tokens' "$sb/.worktrees/.status/golem-42.json" 2>/dev/null)"
    assert_true "[ '$persisted' = '150' ]" "top_level_tokens persisted to the cache (got $persisted)"
    local anchor1
    anchor1="$(jq -r '.top_level_tokens_at' "$sb/.worktrees/.status/golem-42.json" 2>/dev/null)"
    assert_true "[ -n '$anchor1' ] && [ '$anchor1' != 'null' ]" \
        "top_level_tokens_at anchor persisted to the cache (got $anchor1)"
    # Second render, transcript unchanged → frozen. The anchor MUST be carried
    # forward byte-identically, not reset to now() each sweep — a reset-every-sweep
    # regression would still render "150 tokens, frozen 0s" and pass a substring
    # check, but it defeats the whole freeze-duration signal, so assert the
    # persisted anchor is unchanged across the two sweeps.
    command sleep 1
    run_status_scrape "$sb"
    assert_contains "$RUN_OUT" "150 tokens, frozen" "second read with an unchanged count shows frozen"
    local anchor2
    anchor2="$(jq -r '.top_level_tokens_at' "$sb/.worktrees/.status/golem-42.json" 2>/dev/null)"
    assert_true "[ '$anchor2' = '$anchor1' ]" \
        "the frozen-since anchor is carried forward unchanged, not reset each sweep ($anchor1 -> $anchor2)"
}

# A changed transcript between sweeps shows 'advancing', not 'frozen'.
test_status_token_advancing_on_change() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status token block needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "review-cycle", "phase": "ship", "blocking": false }
EOF
    plant_transcript "$sb" 42 '{"isSidechain":false,"message":{"usage":{"output_tokens":100}}}'
    run_status_scrape "$sb"
    assert_contains "$RUN_OUT" "100 tokens (first reading)" "first read shows 100"
    # Grow the transcript's top-level tokens, then re-render.
    local slug dir
    slug="$(slug_for "$sb/.worktrees/issue-42")"
    dir="$sb/projects/$slug"
    command printf '%s\n' \
        '{"isSidechain":false,"message":{"usage":{"output_tokens":100}}}' \
        '{"isSidechain":false,"message":{"usage":{"output_tokens":25}}}' >"$dir/session.jsonl"
    run_status_scrape "$sb"
    assert_contains "$RUN_OUT" "125 tokens (advancing)" "a grown count reads as advancing, not frozen"
}

# A Mode-3 container golem whose host-POST has NOT landed yet (no token fields, or
# a non-numeric one) shows the graceful "awaiting token push" note and is NEVER
# scraped (no bogus frozen reading). (#390)
test_status_token_container_pending() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status token block needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/agent01.json" <<'EOF'
{ "golem": "agent01", "issue": 300, "container": "proj-agent01-1",
  "branch": "agent01", "state": "working", "blocking": false }
EOF
    run_status_scrape "$sb"
    assert_exit 0 "$RUN_RC" "golem-status with an unposted container row exits 0"
    assert_contains "$RUN_OUT" "awaiting token push (container golem, see #390)" \
        "a Mode-3 container golem with no posted usage shows the awaiting-push note (#390)"
    assert_not_contains "$RUN_OUT" "agent01 — 0 tokens" "a container golem is never scraped to a bogus 0"
}

# A Mode-3 container golem whose host-POST HAS landed (top_level_tokens + a stale
# top_level_tokens_at written by the container producer) renders the SAME mechanical
# "frozen Xm" phrase as a Mode-2 golem, and golem-status READS those fields WITHOUT
# rewriting them (the producer owns the fields; a host rewrite would race the POST).
# (#390)
test_status_token_container_populated() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status token block needs jq)"
        return 0
    fi
    local sb anchor
    new_sandbox sb
    # A stale anchor ~130s in the past → _fmt_dur's minutes arm ("frozen Nm").
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
    run_status_scrape "$sb"
    assert_exit 0 "$RUN_RC" "golem-status with a populated container row exits 0"
    assert_contains "$RUN_OUT" "4242 tokens, frozen" \
        "a posted container golem renders the mechanical frozen phrase, same as Mode 2 (#390)"
    assert_true "printf '%s' \"\$RUN_OUT\" | command grep -Eq '4242 tokens, frozen [0-9]+m'" \
        "the seeded ~130s anchor renders _fmt_dur's minutes arm ('frozen Nm')"
    assert_not_contains "$RUN_OUT" "awaiting token push" "a posted container is not shown as pending"
    # READ-ONLY: golem-status must not rewrite the producer-owned fields.
    local tok_after at_after
    tok_after="$(jq -r '.top_level_tokens' "$sb/.worktrees/.status/agent01.json" 2>/dev/null)"
    at_after="$(jq -r '.top_level_tokens_at' "$sb/.worktrees/.status/agent01.json" 2>/dev/null)"
    assert_true "[ '$tok_after' = '4242' ]" "top_level_tokens is not rewritten by golem-status (got $tok_after)"
    assert_true "[ '$at_after' = '$anchor' ]" \
        "top_level_tokens_at anchor is read as-is, never reset to now() (got $at_after)"
}

# A Mode-3 container row whose externally-POSTed fields are MALFORMED degrades to
# the graceful container-pending note, never a bogus frozen render — the cache is
# co-written / the POST is untrusted, so each field is guarded: a corrupt count
# (leading-zero "089", overflow, non-numeric) and a non-ISO anchor ("now", which
# GNU `date -d` would otherwise parse into a plausible-but-wrong duration) must
# both blank out. Mirrors test_status_checkpoint_corrupt_prev_tokens_no_drop for
# the Mode-2 persisted prior. (#390)
test_status_token_container_malformed_degrades() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status token block needs jq)"
        return 0
    fi
    local sb good_anchor
    new_sandbox sb
    good_anchor="$(iso_ago 130)"
    if [ -z "$good_anchor" ]; then
        skip_test "date toolchain cannot seed an ISO anchor"
        return 0
    fi
    # (a) A leading-zero count ("089" — the octal hazard) with a VALID anchor →
    # the count blanks → container-pending, never a bash arithmetic error.
    command cat >"$sb/.worktrees/.status/agent01.json" <<EOF
{ "golem": "agent01", "issue": 300, "container": "proj-agent01-1",
  "branch": "agent01", "state": "working", "blocking": false,
  "top_level_tokens": "089", "top_level_tokens_at": "$good_anchor" }
EOF
    run_status_scrape "$sb"
    assert_exit 0 "$RUN_RC" "a container row with a corrupt count still exits 0"
    assert_contains "$RUN_OUT" "awaiting token push (container golem, see #390)" \
        "a leading-zero posted count degrades to container-pending, not a bogus frozen (#390)"
    assert_not_contains "$RUN_OUT" "089 tokens" "the octal-hazard count is never rendered as a frozen reading"
    # (b) A VALID count with a NON-ISO anchor ("now") → the anchor blanks →
    # container-pending, never a plausible-but-wrong `date -d "now"` duration.
    command cat >"$sb/.worktrees/.status/agent01.json" <<'EOF'
{ "golem": "agent01", "issue": 300, "container": "proj-agent01-1",
  "branch": "agent01", "state": "working", "blocking": false,
  "top_level_tokens": 4242, "top_level_tokens_at": "now" }
EOF
    run_status_scrape "$sb"
    assert_contains "$RUN_OUT" "awaiting token push (container golem, see #390)" \
        "a non-ISO anchor degrades to container-pending, never a date -d-parsed bogus duration (#390)"
    assert_not_contains "$RUN_OUT" "4242 tokens, frozen" "a malformed anchor never renders a frozen duration"
}

# A Mode-3 container row with only ONE of the two fields posted (an asymmetric /
# racing partial POST) degrades to container-pending — the branch requires BOTH
# count AND anchor. Guards against a `&&`→`||` regression that would render a
# frozen phrase with a missing anchor or crash _frozen_phrase on an empty $2. (#390)
test_status_token_container_partial_post() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status token block needs jq)"
        return 0
    fi
    local sb anchor
    new_sandbox sb
    anchor="$(iso_ago 130)"
    if [ -z "$anchor" ]; then
        skip_test "date toolchain cannot seed an ISO anchor"
        return 0
    fi
    # Count present, anchor absent.
    command cat >"$sb/.worktrees/.status/agent01.json" <<'EOF'
{ "golem": "agent01", "issue": 300, "container": "proj-agent01-1",
  "branch": "agent01", "state": "working", "blocking": false,
  "top_level_tokens": 4242 }
EOF
    run_status_scrape "$sb"
    assert_contains "$RUN_OUT" "awaiting token push (container golem, see #390)" \
        "count present but anchor absent degrades to container-pending (#390)"
    assert_not_contains "$RUN_OUT" "4242 tokens, frozen" "a count-only partial POST never renders a frozen phrase"
    # Anchor present, count absent.
    command cat >"$sb/.worktrees/.status/agent01.json" <<EOF
{ "golem": "agent01", "issue": 300, "container": "proj-agent01-1",
  "branch": "agent01", "state": "working", "blocking": false,
  "top_level_tokens_at": "$anchor" }
EOF
    run_status_scrape "$sb"
    assert_contains "$RUN_OUT" "awaiting token push (container golem, see #390)" \
        "anchor present but count absent degrades to container-pending (#390)"
}

# A Mode-2 golem with no transcript shows 'tokens unknown', never a bogus frozen.
test_status_token_unknown_no_transcript() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status token block needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-77.json" <<'EOF'
{ "golem": "golem-77", "issue": 77, "branch": "feature/issue-77",
  "state": "working", "blocking": false }
EOF
    run_status_scrape "$sb"
    assert_exit 0 "$RUN_RC" "golem-status with a transcript-less golem exits 0"
    assert_contains "$RUN_OUT" "tokens unknown (no transcript)" \
        "a Mode-2 golem with no transcript shows tokens unknown"
    # "frozen" alone would match the section header ("frozen-counter signal"); pin
    # the render form instead — an unknown-token golem must never show "frozen Xm".
    assert_not_contains "$RUN_OUT" "tokens, frozen" "an unknown-token golem never reports a frozen duration"
}

# An UNPARSABLE stored anchor (top_level_tokens_at that `date` cannot read) →
# _iso_to_epoch returns empty → the render falls back to the raw "frozen since
# <iso>" branch, never a bogus "frozen 0s". Deterministic (no timing).
test_status_frozen_iso_parse_failure_raw_render() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status token block needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    # Seed a matching prior count (150 = what TRANSCRIPT_MIXED scrapes to) so the
    # sweep reads UNCHANGED → frozen, plus a garbage anchor `date` cannot parse.
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "review-cycle", "phase": "ship", "blocking": false,
  "top_level_tokens": 150, "top_level_tokens_at": "not-a-date" }
EOF
    plant_transcript "$sb" 42 "$TRANSCRIPT_MIXED"
    run_status_scrape "$sb"
    assert_exit 0 "$RUN_RC" "golem-status with an unparsable anchor exits 0"
    assert_contains "$RUN_OUT" "frozen since not-a-date" \
        "an unparsable anchor renders the raw 'frozen since <iso>' fallback"
    # A parse failure must NOT masquerade as a computed duration.
    assert_not_contains "$RUN_OUT" "150 tokens, frozen 0" \
        "the parse-failure branch never emits a bogus computed 'frozen 0s'"
}

# _fmt_dur's SECONDS arm (<60): an anchor ~20s in the past renders "frozen Ns".
test_status_fmt_dur_seconds_arm() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status token block needs jq)"
        return 0
    fi
    local sb anchor
    new_sandbox sb
    anchor="$(iso_ago 20)"
    if [ -z "$anchor" ]; then
        skip_test "date could not compute a past anchor"
        return 0
    fi
    command cat >"$sb/.worktrees/.status/golem-42.json" <<EOF
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "review-cycle", "phase": "ship", "blocking": false,
  "top_level_tokens": 150, "top_level_tokens_at": "$anchor" }
EOF
    plant_transcript "$sb" 42 "$TRANSCRIPT_MIXED"
    run_status_scrape "$sb"
    assert_exit 0 "$RUN_RC" "golem-status with a ~20s anchor exits 0"
    # ~20s is well below the 60s boundary, so a few seconds of test latency can't
    # flip the arm. Match the render form, not an exact second count.
    assert_true "printf '%s' \"\$RUN_OUT\" | command grep -Eq 'frozen [0-9]+s'" \
        "an anchor under 60s renders _fmt_dur's seconds arm ('frozen Ns')"
    assert_not_contains "$RUN_OUT" "frozen 0m" "a sub-minute freeze never rounds to minutes"
}

# _fmt_dur's MINUTES arm (>=60): an anchor ~130s in the past renders "frozen Nm".
test_status_fmt_dur_minute_arm() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status token block needs jq)"
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
  "top_level_tokens": 150, "top_level_tokens_at": "$anchor" }
EOF
    plant_transcript "$sb" 42 "$TRANSCRIPT_MIXED"
    run_status_scrape "$sb"
    assert_exit 0 "$RUN_RC" "golem-status with a ~130s anchor exits 0"
    # ~130s is well above the 60s boundary (renders "2m"), clear of test latency.
    assert_true "printf '%s' \"\$RUN_OUT\" | command grep -Eq 'frozen [0-9]+m'" \
        "an anchor at/above 60s renders _fmt_dur's minutes arm ('frozen Nm')"
    # And NO token line renders the seconds form — a bogus dual-render (minute +
    # second line for the same golem) must fail. `grep -q` matches any line, so
    # `!` is true only when zero lines carry a 'tokens, frozen Ns' form. (An
    # earlier `grep -Evq` was tautological: header/other lines always fail the
    # match, so per-line inversion was unconditionally true — #392 pre-PR review.)
    assert_true "! printf '%s' \"\$RUN_OUT\" | command grep -Eq 'tokens, frozen [0-9]+s'" \
        "the minutes arm never also emits a seconds-form freeze line"
}

# The scrape resolves a RELATIVE worktree arg against the cwd (the
# `*) abs="$(command pwd)/$worktree"` branch) to the same slug/count an absolute
# path yields. Every other scrape test passes an absolute path.
test_scrape_relative_worktree_path() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (scrape needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 "$TRANSCRIPT_MIXED"
    # Invoke with cwd = $sb and a RELATIVE worktree arg, so the script prepends
    # $(command pwd) and must land on the same $sb/.worktrees/issue-42 slug.
    RUN_RC=0
    RUN_OUT="$(cd "$sb" &&
        /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
            HOME="$sb" \
            CLAUDE_PROJECTS_DIR="$sb/projects" \
            "$REAL_BASH" "$SCRAPE" ".worktrees/issue-42" 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "scrape of a relative worktree path exits 0"
    assert_true "[ '$RUN_OUT' = '150' ]" \
        "a relative worktree arg resolves to the same slug/count as absolute (150, got '$RUN_OUT')"
}

# Zero-token end-to-end: an all-sidechain transcript scrapes to `0` (exit 0), and
# golem-status renders "0 tokens (first reading)", NOT "tokens unknown".
test_scrape_and_status_zero_tokens() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (scrape + status token block need jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    plant_transcript "$sb" 42 "$TRANSCRIPT_ALL_SIDECHAIN"
    # (a) the scrape itself prints a literal 0, exit 0 — never fails loud on an
    #     all-sidechain transcript (no top-level output *yet* is a valid 0).
    run_scrape "$sb" "$sb/.worktrees/issue-42"
    assert_exit 0 "$RUN_RC" "scrape of an all-sidechain transcript exits 0"
    assert_true "[ '$RUN_OUT' = '0' ]" "an all-sidechain transcript scrapes to 0 (got '$RUN_OUT')"
    # (b) golem-status renders the 0 as a first reading, distinct from unknown.
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "working", "blocking": false }
EOF
    run_status_scrape "$sb"
    assert_exit 0 "$RUN_RC" "golem-status with a zero-token transcript exits 0"
    assert_contains "$RUN_OUT" "0 tokens (first reading)" \
        "a scraped 0 renders as a first reading, not tokens unknown"
    assert_not_contains "$RUN_OUT" "tokens unknown" \
        "a genuine 0 is never conflated with an empty/failed scrape"
}

# golem-status's OWN jq gate for the TOP-LEVEL TOKENS block: with jq absent from
# PATH the script still exits 0 and renders the main table, but emits NO token
# section. PATH is a curated shim of every tool the script tree needs EXCEPT jq
# (golem-status sources config.sh → needs git/dirname; plus date/mktemp/mv/rm/
# tmux), symlinked so no interpreter is required (mirrors the repo_root shim).
test_status_no_jq_skips_token_block() {
    local sb shim tp
    new_sandbox sb
    shim="$sb/shim"
    command mkdir -p "$shim"
    for t in git dirname env date mktemp mv rm tmux bash sh; do
        tp="$(command -v "$t" 2>/dev/null)" && command ln -s "$tp" "$shim/$t"
    done
    # A cache row makes the cache array non-empty, so the ONLY reason the token
    # block is skipped is the jq gate itself (not the empty-cache short-circuit).
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
            "$REAL_BASH" "$STATUS" 2>&1)" || RUN_RC=$?
    assert_exit 0 "$RUN_RC" "golem-status without jq still exits 0 (degrades, not aborts)"
    assert_not_contains "$RUN_OUT" "TOP-LEVEL TOKENS" \
        "the token block is skipped when jq is absent"
}

# A cache row MISSING the `issue` field → issue_n empty → the scrape is skipped →
# cur empty → the shared "tokens unknown (no transcript)" arm (there is no
# issue-specific message; missing-issue funnels into the same empty-cur branch).
test_status_cache_row_missing_issue_tokens_unknown() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status token block needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    # No `issue` key at all — a valid golem row (renders in the table) but the
    # token loop cannot resolve a worktree to scrape.
    command cat >"$sb/.worktrees/.status/golem-88.json" <<'EOF'
{ "golem": "golem-88", "branch": "feature/issue-88",
  "state": "working", "blocking": false }
EOF
    # A transcript is planted for 88, yet the row still reads 'tokens unknown':
    # the missing `issue` collapses the scrape to an empty count regardless of a
    # present transcript (the observable contract this test pins).
    plant_transcript "$sb" 88 "$TRANSCRIPT_MIXED"
    run_status_scrape "$sb"
    assert_exit 0 "$RUN_RC" "golem-status with an issue-less cache row exits 0"
    assert_contains "$RUN_OUT" "tokens unknown (no transcript)" \
        "a cache row missing 'issue' funnels into the shared tokens-unknown arm"
    assert_not_contains "$RUN_OUT" "150 tokens" \
        "a missing 'issue' is never scraped to a real count"
}
