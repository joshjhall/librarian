# shellcheck shell=bash
# golem-status.sh — golem helper-script tests (issue #564 split).
#
# Covers empty-state rendering, the _gate_age_suffix silent no-op arms (#432), and the level-scaled --watch sweep (#304).
#
# Sourced by tests/validate-golem-scripts.sh, which defines the path consts
# (LAUNCH / WT_NEW / STATUS / ...) and sources tests/lib/golem-sandbox.sh for the
# shared sandbox plumbing (new_sandbox / run_in / ...) BEFORE this file. This
# fragment therefore only DEFINES test functions; the entry point dispatches them
# from its explicit ordered run_test list.

# --- golem-status.sh --------------------------------------------------------

# Empty status dir + no sessions + no pool → "No active golems", exit 0. Uses a
# status dir guaranteed empty (the fresh sandbox's). jq-gated only because the
# script uses jq for the table; the empty-state branch exits before jq, but keep
# the guard for the planted-row sibling below.
test_status_empty_reports_no_golems() {
    local sb
    new_sandbox sb
    run_in "$sb" "$STATUS"
    assert_exit 0 "$RUN_RC" "golem-status with no golems exits 0"
    assert_contains "$RUN_OUT" "No active golems" "reports no active golems"
}

# A planted golem-N.json cache renders a status row (smoke test of the jq table).
test_status_renders_planted_row() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (golem-status table needs jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/golem-42.json" <<'EOF'
{ "golem": "golem-42", "issue": 42, "branch": "feature/issue-42",
  "state": "impl", "phase": "make-it-work", "blocking": false }
EOF
    run_in "$sb" "$STATUS"
    assert_exit 0 "$RUN_RC" "golem-status exits 0 with a planted cache row"
    assert_contains "$RUN_OUT" "golem-42" "renders the planted golem row"
    assert_contains "$RUN_OUT" "GOLEM" "prints the table header"
}

# Gate age (#422): a fresh dated `gate` renders the "(gated Nm ago)" suffix so a
# stale-vs-fresh gate is visually distinguishable even if a clearing line was
# missed. Plant a cache row (so the BLOCKED section renders) plus a feed gate
# whose `ts` is a recent-but-non-zero age; the render must carry a "(gated …
# ago)" suffix. jq-gated like the sibling BLOCKED tests.
test_status_blocked_shows_gate_age() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (feed snapshot + age derivation need jq)"
        return 0
    fi
    local sb sd ts
    new_sandbox sb
    sd="$sb/.worktrees/.status"
    command cat >"$sd/golem-3.json" <<'EOF'
{ "golem": "golem-3", "issue": 3, "branch": "feature/issue-3",
  "state": "impl", "phase": "make-it-work", "blocking": false }
EOF
    # A gate dated ~2 minutes ago: recent enough to stay inside the TTL, old
    # enough that _fmt_dur renders "2m" (a non-zero, human-visible age).
    ts="$(command date -u -d '130 seconds ago' +%FT%TZ 2>/dev/null ||
        command date -u -v-130S +%FT%TZ 2>/dev/null)"
    command cat >"$sd/feed.jsonl" <<EOF
{"golem":"golem-3","event":"gate","message":"push gate","ts":"$ts"}
EOF
    run_in "$sb" "$STATUS"
    assert_exit 0 "$RUN_RC" "golem-status exits 0 with a dated gate"
    assert_contains "$RUN_OUT" "(gated " \
        "the BLOCKED render carries a (gated Nm ago) age suffix (#422)"
}

# --- _gate_age_suffix silent no-op arms (#432 gap 2) ------------------------
#
# _gate_age_suffix has three fall-through arms that each `return 0` with NO
# output: no-jq, no/empty `.ts`, and unparsable `.ts`. The render carries the
# bare BLOCKED line (never an error, never a bogus "0s") on all three. The no-`ts`
# and unparsable-`ts` arms are BOTH reachable end-to-end through the full render
# — a no-`ts` gate bypasses golem-gate-watch.sh's TTL, and (since #432 wrapped the
# snapshot's `fromdateiso8601` in `try … catch`) a malformed-`ts` gate degrades to
# that same fresh fallback and surfaces BLOCKED too, where _gate_age_suffix's own
# `_iso_to_epoch` still cannot parse it → no suffix. The no-jq arm yields an empty
# BLOCKED section upstream, so it is covered by UNIT-testing the helper directly.
# golem-status.sh carries a source guard for exactly this (mirrors
# golem-resolve.sh / golem-gate-watch.sh).

# no-`ts` arm: the golem's last feed line carries no `.ts` → empty output, no
# error. (This is the arm the render CAN reach; the render-level counterpart is
# test_status_blocked_no_ts_omits_gate_age below.)
test_gate_age_suffix_no_ts_empty() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (_gate_age_suffix reads the feed with jq)"
        return 0
    fi
    local sb out
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/feed.jsonl" <<'EOF'
{"golem":"golem-3","event":"gate","message":"push gate"}
EOF
    gate_age_unit out "$sb" golem-3 "$sb/.worktrees/.status/feed.jsonl" jq
    assert_output_empty "$out" "_gate_age_suffix emits nothing for a no-ts line"
}

# unparsable-`ts` arm: `_iso_to_epoch` returns empty for a non-date `.ts`, so the
# `[ -n "$_gas_epoch" ]` guard trips → empty output, no error (never a bogus 0s).
test_gate_age_suffix_bad_ts_empty() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (_gate_age_suffix reads the feed with jq)"
        return 0
    fi
    local sb out
    new_sandbox sb
    command cat >"$sb/.worktrees/.status/feed.jsonl" <<'EOF'
{"golem":"golem-3","event":"gate","message":"push gate","ts":"not-a-date"}
EOF
    gate_age_unit out "$sb" golem-3 "$sb/.worktrees/.status/feed.jsonl" jq
    assert_output_empty "$out" "_gate_age_suffix emits nothing for an unparsable ts"
}

# no-jq arm: the `command -v jq` guard trips first → empty output, no error, even
# with a perfectly good dated line present (jq stubbed off PATH).
test_gate_age_suffix_no_jq_empty() {
    local sb out ts
    new_sandbox sb
    ts="$(command date -u -d '130 seconds ago' +%FT%TZ 2>/dev/null ||
        command date -u -v-130S +%FT%TZ 2>/dev/null)"
    command cat >"$sb/.worktrees/.status/feed.jsonl" <<EOF
{"golem":"golem-3","event":"gate","message":"push gate","ts":"$ts"}
EOF
    gate_age_unit out "$sb" golem-3 "$sb/.worktrees/.status/feed.jsonl" nojq
    assert_output_empty "$out" "_gate_age_suffix emits nothing when jq is absent"
}

# End-to-end: a no-`ts` gate surfaces in the BLOCKED list (it bypasses the TTL)
# but its render carries NO "(gated … ago)" suffix — the negative counterpart to
# test_status_blocked_shows_gate_age. Proves the fall-through is a clean omission
# at the render level, not just in isolation.
test_status_blocked_no_ts_omits_gate_age() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (feed snapshot needs jq)"
        return 0
    fi
    local sb sd
    new_sandbox sb
    sd="$sb/.worktrees/.status"
    command cat >"$sd/golem-3.json" <<'EOF'
{ "golem": "golem-3", "issue": 3, "branch": "feature/issue-3",
  "state": "impl", "phase": "make-it-work", "blocking": false }
EOF
    # No `ts` → gate-watch treats it as fresh (bypasses TTL) so it surfaces
    # BLOCKED, but _gate_age_suffix can derive no age → no suffix.
    command cat >"$sd/feed.jsonl" <<'EOF'
{"golem":"golem-3","event":"gate","message":"push gate"}
EOF
    run_in "$sb" "$STATUS"
    assert_exit 0 "$RUN_RC" "golem-status exits 0 with a no-ts gate"
    # Anchor on the BLOCKED-list render line ("  golem-N — <message>"), not the
    # bare message. (The raw "Recent feed" JSON echo that used to also carry this
    # substring was removed in #488 — the render now prints only a feed line count
    # — but the render-line anchor is the correct assertion regardless.)
    assert_contains "$RUN_OUT" "golem-3 — push gate" "the no-ts gate surfaces in the BLOCKED list"
    assert_not_contains "$RUN_OUT" "(gated " \
        "a no-ts BLOCKED line renders without a (gated Nm ago) suffix (#432)"
}

# Monitoring-integrity regression (#432): a single golem whose most-recent feed
# line carries a NON-EMPTY but malformed `.ts` must NOT blank the whole BLOCKED
# list. golem-gate-watch.sh's snapshot runs ONE `jq -rs` over the entire feed, so
# before the `try … catch` wrap an unparsable `ts` aborted the program (exit 5,
# swallowed by 2>/dev/null) and EVERY golem — even ones with a perfectly good
# `ts` — dropped out of BLOCKED (the #24 blast radius, re-entered through a
# strict-parse failure the null/empty guard doesn't cover). Plant two golems, one
# bad-`ts` and one good-`ts`, and assert BOTH surface: the good one proves the
# abort no longer nukes the list, the bad one proves it degrades to the fresh
# fallback rather than vanishing.
test_status_bad_ts_does_not_blank_blocked_list() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (feed snapshot needs jq)"
        return 0
    fi
    local sb sd good_ts
    new_sandbox sb
    sd="$sb/.worktrees/.status"
    command cat >"$sd/golem-3.json" <<'EOF'
{ "golem": "golem-3", "issue": 3, "branch": "feature/issue-3",
  "state": "impl", "phase": "make-it-work", "blocking": false }
EOF
    command cat >"$sd/golem-5.json" <<'EOF'
{ "golem": "golem-5", "issue": 5, "branch": "feature/issue-5",
  "state": "impl", "phase": "make-it-work", "blocking": false }
EOF
    good_ts="$(command date -u -d '60 seconds ago' +%FT%TZ 2>/dev/null ||
        command date -u -v-60S +%FT%TZ 2>/dev/null)"
    # golem-3's most-recent line has a non-empty but unparsable `ts`; golem-5's
    # is well-formed and recent. Pre-fix, golem-3's line aborted the snapshot jq
    # and BOTH vanished.
    command cat >"$sd/feed.jsonl" <<EOF
{"golem":"golem-3","event":"gate","message":"bad-ts gate","ts":"not-a-date"}
{"golem":"golem-5","event":"gate","message":"good-ts gate","ts":"$good_ts"}
EOF
    run_in "$sb" "$STATUS"
    assert_exit 0 "$RUN_RC" "golem-status exits 0 with a mixed good/bad ts feed"
    # Anchor on the BLOCKED-LIST line form ("  golem-N — <message>"), NOT a bare
    # substring. The em-dash-separated render line appears ONLY when the golem
    # actually surfaces BLOCKED — a bare `good-ts gate` substring would be a weaker
    # assertion (before #488 the raw "Recent feed" JSON echo also carried it, a
    # classic false pass; that echo is now a one-line count, but the render-line
    # anchor remains the correct discriminator). Verified: reverting the try/catch
    # fails both asserts here.
    assert_contains "$RUN_OUT" "golem-5 — good-ts gate" \
        "the good-ts golem still renders in the BLOCKED list — a sibling's bad ts doesn't blank it (#432)"
    assert_contains "$RUN_OUT" "golem-3 — bad-ts gate" \
        "the bad-ts golem degrades to the fresh fallback and renders BLOCKED, rather than aborting the snapshot (#432)"
}

# The BLOCKED feed pass annotates an escalation/dead-end line that carries a
# brokered-gate id with the inbox state (#395): `[inbox: awaiting|answered|
# consumed]`. A routine permission gate (no gate-id token) stays un-annotated.
# Plant a feed with BOTH a token-carrying escalation and a token-less gate, plus
# a cache row (so render_status proceeds past the "no active golems" guard), and
# an inbox `answer` for the escalation's gate → the escalation line shows
# `[inbox: answered]` while the routine line is untouched. jq-guarded like the
# row test (golem-gate-watch's feed snapshot + golem-inbox's state both need jq).
test_status_annotates_blocked_inbox_state() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (feed snapshot + inbox state need jq)"
        return 0
    fi
    local sb sd gid
    new_sandbox sb
    sd="$sb/.worktrees/.status"
    gid="gate-1784398516-abcd"
    # A cache row so render_status renders the BLOCKED section at all.
    command cat >"$sd/golem-7.json" <<'EOF'
{ "golem": "golem-7", "issue": 7, "branch": "feature/issue-7",
  "state": "impl", "phase": "make-it-work", "blocking": false }
EOF
    # Feed: a token-carrying escalation (golem-7) + a token-less ROUTINE gate
    # (golem-4) whose command text embeds a gate-SHAPED substring (`fix/gate-…`)
    # that is NOT a bracketed correlation token. Omit `ts` — golem-gate-watch's
    # TTL treats a missing ts as fresh, so the lines surface without clock
    # coupling. The routine line pins the anchored-regex fix: an unanchored scan
    # would falsely annotate it from that substring (the #395 review's Bug 2).
    command cat >"$sd/feed.jsonl" <<EOF
{"golem":"golem-7","event":"escalation","message":"ESCALATION: [$gid] pick sidecar"}
{"golem":"golem-4","event":"gate","message":"Claude needs permission to run: git branch -D fix/gate-1111111111-aaaa"}
EOF
    # An unconsumed answer for the escalation's gate → state should be `answered`.
    inbox_in "$sb" answer golem-7 "$gid" B

    run_in "$sb" "$STATUS"
    assert_exit 0 "$RUN_RC" "golem-status exits 0 with a planted feed + inbox"
    assert_contains "$RUN_OUT" "[inbox: answered]" \
        "annotates the escalation BLOCKED line with the inbox state"
    # The routine gate carries a gate-SHAPED substring but no bracketed token, so
    # it must stay un-annotated — the anchored `[gate-…]` match ignores it.
    assert_not_contains "$RUN_OUT" "fix/gate-1111111111-aaaa  [inbox:" \
        "a routine gate with a gate-shaped substring stays un-annotated (anchored to [gate-…])"
}

# The gate-id is extracted from the BRACKETED [gate-…] token, not the first
# gate-shaped substring: an escalation message that mentions an older bare
# gate-id before its own bracketed correlation id must query the BRACKETED one
# (the #395 review's Bug 2, wrong-gate variant). Answer the real bracketed gate;
# the annotation must read `answered`, proving it didn't query the stray mention.
test_status_inbox_annotation_uses_bracketed_gate() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (feed snapshot + inbox state need jq)"
        return 0
    fi
    local sb sd real
    new_sandbox sb
    sd="$sb/.worktrees/.status"
    real="gate-2222222222-real"
    command cat >"$sd/golem-7.json" <<'EOF'
{ "golem": "golem-7", "issue": 7, "branch": "b", "state": "impl", "phase": "p", "blocking": false }
EOF
    command printf '{"golem":"golem-7","event":"escalation","message":"ESCALATION: after gate-1000000000-old, now [%s] pick sidecar"}\n' \
        "$real" >"$sd/feed.jsonl"
    inbox_in "$sb" answer golem-7 "$real" B
    run_in "$sb" "$STATUS"
    assert_contains "$RUN_OUT" "[inbox: answered]" \
        "queries the bracketed gate-id, not the stray earlier gate-shaped mention"
}

# `awaiting` (no inbox file) and `consumed` (answer + consume) render too — the
# two annotation states the answered case above doesn't cover.
test_status_inbox_state_awaiting_and_consumed() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (feed snapshot + inbox state need jq)"
        return 0
    fi
    local sb sd gid
    # awaiting: token in the feed, no inbox file written.
    new_sandbox sb
    sd="$sb/.worktrees/.status"
    gid="gate-1784398600-aaaa"
    command cat >"$sd/golem-7.json" <<'EOF'
{ "golem": "golem-7", "issue": 7, "branch": "b", "state": "impl", "phase": "p", "blocking": false }
EOF
    command printf '{"golem":"golem-7","event":"escalation","message":"ESCALATION: [%s] x"}\n' \
        "$gid" >"$sd/feed.jsonl"
    run_in "$sb" "$STATUS"
    assert_contains "$RUN_OUT" "[inbox: awaiting]" "no inbox answer yet → awaiting"

    # consumed: answer then consume the gate.
    local sb2 sd2 gid2
    new_sandbox sb2
    sd2="$sb2/.worktrees/.status"
    gid2="gate-1784398700-bbbb"
    command cat >"$sd2/golem-7.json" <<'EOF'
{ "golem": "golem-7", "issue": 7, "branch": "b", "state": "impl", "phase": "p", "blocking": false }
EOF
    command printf '{"golem":"golem-7","event":"escalation","message":"ESCALATION: [%s] x"}\n' \
        "$gid2" >"$sd2/feed.jsonl"
    inbox_in "$sb2" answer golem-7 "$gid2" B
    inbox_in "$sb2" consume golem-7 "$gid2"
    run_in "$sb2" "$STATUS"
    assert_contains "$RUN_OUT" "[inbox: consumed]" "answer + consume → consumed"
}

# --- golem-status.sh --watch (level-scaled status sweep, #304) ---------------

# An unknown argument is a fail-loud usage error (exit 2), not a silent no-op.
test_status_unknown_arg_exits_2() {
    local sb
    new_sandbox sb
    run_in "$sb" "$STATUS" --bogus
    assert_exit 2 "$RUN_RC" "golem-status --bogus exits 2"
    assert_contains "$RUN_OUT" "unknown argument" "names the bad argument"
}

# --level out of 1-4 range is rejected before any loop starts.
test_status_watch_bad_level_exits_2() {
    local sb
    new_sandbox sb
    run_in "$sb" "$STATUS" --watch --level 9
    assert_exit 2 "$RUN_RC" "golem-status --watch --level 9 exits 2"
    assert_contains "$RUN_OUT" "level must be 1-4" "reports the out-of-range level"
}

# A non-integer --interval is rejected up front.
test_status_watch_bad_interval_exits_2() {
    local sb
    new_sandbox sb
    run_in "$sb" "$STATUS" --watch --interval abc
    assert_exit 2 "$RUN_RC" "golem-status --watch --interval abc exits 2"
    assert_contains "$RUN_OUT" "positive integer" "reports the bad interval"
}

# --watch re-renders on the interval: a planted row appears more than once within
# the bounded window. GOLEM_SWEEP_INTERVAL=1 keeps the test fast and proves the
# env override beats the level default (L3 would otherwise wait 480s).
test_status_watch_loops_with_env_override() {
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
    run_in_watch "$sb" 3 GOLEM_SWEEP_INTERVAL=1 -- --watch --level 3
    assert_exit 0 "$RUN_RC" "bounded --watch loop exits cleanly (killed by timeout)"
    assert_contains "$RUN_OUT" "Status sweep every 1s (level 3)" \
        "header shows the env-override interval, not the L3 default"
    # The planted header line should render at least twice across ~3 one-second
    # sweeps — proof the loop re-polls rather than rendering once.
    local count
    count="$(command printf '%s\n' "$RUN_OUT" | command grep -c '^GOLEM ')"
    assert_true "[ '$count' -ge 2 ]" "renders repeatedly (>=2 sweeps in 3s, got $count)"
}

# With no --interval and no env override, the cadence comes from the resolver's
# level-scaled default (L4 -> 900s). We can't wait 900s, so assert only that the
# header reports the resolved default and the first render happened.
test_status_watch_uses_resolver_default() {
    if ! command -v timeout >/dev/null 2>&1; then
        skip_test "timeout not available (cannot bound the --watch loop)"
        return 0
    fi
    local sb
    new_sandbox sb
    run_in_watch "$sb" 2 -- --watch --level 4
    assert_exit 0 "$RUN_RC" "bounded --watch loop exits cleanly"
    assert_contains "$RUN_OUT" "Status sweep every 900s (level 4)" \
        "header shows the L4 resolver default (900s)"
}
