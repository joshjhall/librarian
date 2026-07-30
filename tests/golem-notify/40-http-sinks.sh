# shellcheck shell=bash
# Multi-sink HTTP fan-out — golem-notify hook tests (issue #564 split).
#
# Covers the GOLEM_EVENT_SINKS fan-out (#406) — per-sink POSTs, failure isolation, and the feed write that must survive a dead sink.
#
# Sourced by tests/validate-golem-notify.sh, which defines NOTIFY / CONFIG_SH /
# REAL_BASH and sources tests/lib/golem-notify-sandbox.sh for the shared drivers
# BEFORE this file. This fragment only DEFINES test functions; the entry point
# dispatches them from its explicit ordered run_test list.

# Local to this area: the sink fan-out is the only consumer of this poller.
# poll_capture_count <capture_dir> <want> — bounded wait (~3s) for <want> stub
# request files to appear. The hook backgrounds each POST, so the capture files
# land asynchronously; this replaces a fixed sleep with a bounded poll.
poll_capture_count() {
    local capdir="$1" want="$2" tries=0 n
    while [ "$tries" -lt 30 ]; do
        n="$(command ls -1 "$capdir" 2>/dev/null | command wc -l | command tr -d ' ')"
        [ "$n" -ge "$want" ] && return 0
        sleep 0.1
        tries=$((tries + 1))
    done
    return 0
}

# --- Multi-sink HTTP fan-out (GOLEM_EVENT_SINKS, #406) -----------------------

# One emission fans to feed.jsonl ALWAYS plus each http(s) URL in
# GOLEM_EVENT_SINKS, from one code path (AC1). Empty/unset ⇒ feed only, no
# network (AC2). Each POST is bounded + backgrounded so a hung endpoint never
# blocks (AC3). The SAME classified payload goes to every sink (AC4). The stub
# curl below stands in for the network; jq validates the captured payloads.

# AC2 — with GOLEM_EVENT_SINKS unset, NO curl is invoked (feed only). The stub
# would capture a request file if the hook called curl; asserting zero captures
# proves the empty-list path spawns no network process — byte-for-byte the
# pre-#406 behavior.
test_sinks_empty_no_network() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (needed to validate the feed line)"
        return 0
    fi
    local sb capdir n
    new_sandbox sb
    capdir="$sb/cap"
    command mkdir -p "$capdir"
    # Empty sinks list: the hook must not reach curl at all.
    run_notify_sinks "$sb" \
        '{"message":"Claude needs your permission to run git push"}' \
        "golem-1" "" "$capdir"
    assert_exit 0 "$NOTIFY_RC" "hook exits 0 (empty GOLEM_EVENT_SINKS)"
    assert_valid_json "$NOTIFY_FEED" "feed line still written (empty sinks)"
    poll_capture_count "$capdir" 1 # give any erroneous POST a chance to land
    n="$(command ls -1 "$capdir" 2>/dev/null | command wc -l | command tr -d ' ')"
    assert_equals "0" "$n" "empty GOLEM_EVENT_SINKS makes NO curl call (feed only, AC2)"
}

# AC1 + AC4 — two sinks each receive one POST carrying a payload byte-equal to
# the feed line (same classified event to every sink), and both URLs are hit.
test_sinks_fanout_same_payload() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (needed to validate the captured payloads)"
        return 0
    fi
    local sb capdir n p1 p2 u1 u2
    new_sandbox sb
    capdir="$sb/cap"
    command mkdir -p "$capdir"
    run_notify_sinks "$sb" \
        '{"message":"Claude needs your permission to run git push"}' \
        "golem-1" "http://127.0.0.1:9/a http://127.0.0.1:9/b" "$capdir"
    assert_exit 0 "$NOTIFY_RC" "hook exits 0 (two sinks)"
    assert_valid_json "$NOTIFY_FEED" "feed line written (two sinks, AC1)"
    poll_capture_count "$capdir" 2
    n="$(command ls -1 "$capdir" 2>/dev/null | command wc -l | command tr -d ' ')"
    assert_equals "2" "$n" "both sinks received one POST each (AC1)"
    # Each capture file: line 1 = URL, line 2 = payload. Collect and compare.
    u1=""
    u2=""
    p1=""
    p2=""
    for f in "$capdir"/req.*; do
        [ -e "$f" ] || continue
        if [ -z "$u1" ]; then
            u1="$(command sed -n 1p "$f")"
            p1="$(command sed -n 2p "$f")"
        else
            u2="$(command sed -n 1p "$f")"
            p2="$(command sed -n 2p "$f")"
        fi
    done
    assert_valid_json "$p1" "sink 1 payload is valid JSON (AC4)"
    assert_valid_json "$p2" "sink 2 payload is valid JSON (AC4)"
    assert_equals "$NOTIFY_FEED" "$p1" "sink 1 payload byte-equals the feed line (AC4)"
    assert_equals "$NOTIFY_FEED" "$p2" "sink 2 payload byte-equals the feed line (AC4)"
    # Both distinct URLs were hit (order-independent).
    assert_true "[ '$u1' != '$u2' ] && [ -n '$u1' ] && [ -n '$u2' ]" \
        "both distinct sink URLs were POSTed (AC1)"
}

# AC3 — a sink whose curl hangs well past the timeout must NOT block the hook.
# The stub sleeps 30s; the hook backgrounds the POST, so it must return in well
# under that. Assert both exit 0 AND a wall-clock bound, plus the feed line still
# landed (feed is written before the fan, so a hung sink never costs the feed).
test_sinks_never_block() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (needed to validate the feed line)"
        return 0
    fi
    local sb capdir start elapsed
    new_sandbox sb
    capdir="$sb/cap"
    command mkdir -p "$capdir"
    start="$(command date +%s)"
    # 30s stub sleep, 2s configured timeout: a blocking hook would wait ≥2s (or
    # 30s if it also awaited the child); a non-blocking one returns near-instantly.
    run_notify_sinks "$sb" \
        '{"message":"Claude needs your permission to run git push"}' \
        "golem-1" "http://127.0.0.1:9/slow" "$capdir" "30" "2"
    elapsed="$(($(command date +%s) - start))"
    assert_exit 0 "$NOTIFY_RC" "hook exits 0 despite a hung sink (AC3)"
    assert_valid_json "$NOTIFY_FEED" "feed line written before the hung POST (AC3)"
    assert_true "[ '$elapsed' -lt 10 ]" \
        "hook returned promptly (${elapsed}s) — a hung sink never blocks the golem (AC3)"
}

# Scheme guard — a non-http(s) entry in the list is skipped (no curl call for
# it), while a sibling https entry in the SAME list is still POSTed. Guards
# against handing a stray `file://`/`ftp://` token to curl.
test_sinks_scheme_guard() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (needed to validate the feed line)"
        return 0
    fi
    local sb capdir n u
    new_sandbox sb
    capdir="$sb/cap"
    command mkdir -p "$capdir"
    # A file:// entry (must be skipped) beside a valid https entry (must be hit).
    run_notify_sinks "$sb" \
        '{"message":"Claude needs your permission to run git push"}' \
        "golem-1" "file:///etc/passwd https://127.0.0.1:9/ok" "$capdir"
    assert_exit 0 "$NOTIFY_RC" "hook exits 0 (scheme guard)"
    poll_capture_count "$capdir" 1
    n="$(command ls -1 "$capdir" 2>/dev/null | command wc -l | command tr -d ' ')"
    assert_equals "1" "$n" "only the https sink was POSTed; file:// entry skipped"
    u="$(command sed -n 1p "$capdir"/req.* 2>/dev/null || true)"
    assert_equals "https://127.0.0.1:9/ok" "$u" \
        "the POSTed URL is the https sink, not the file:// entry"
}

# comma-separated list — GOLEM_EVENT_SINKS accepts commas as well as spaces (the
# `tr ',' ' '` normalization). Two comma-separated sinks each get one POST.
test_sinks_comma_separated() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (needed to validate the feed line)"
        return 0
    fi
    local sb capdir n
    new_sandbox sb
    capdir="$sb/cap"
    command mkdir -p "$capdir"
    run_notify_sinks "$sb" \
        '{"message":"Claude needs your permission to run git push"}' \
        "golem-1" "http://127.0.0.1:9/a,http://127.0.0.1:9/b" "$capdir"
    assert_exit 0 "$NOTIFY_RC" "hook exits 0 (comma-separated sinks)"
    poll_capture_count "$capdir" 2
    n="$(command ls -1 "$capdir" 2>/dev/null | command wc -l | command tr -d ' ')"
    assert_equals "2" "$n" "comma-separated list fans to both sinks"
}

# curl-absent branch — GOLEM_EVENT_SINKS is non-empty but curl is not on PATH, so
# the `&& command -v curl` half of the fan-out guard fails. The hook must degrade
# gracefully: still exit 0 and still write the feed line, spawning no POST. Every
# other sink test has curl present, so this is the only coverage of that half of
# the `&&`. PATH holds only the bash stub (no curl), reached the same jq-free way
# run_notify's nojq mode builds its hermetic PATH — but here jq IS needed to
# validate the feed line, so it is gated on jq like the rest.
test_sinks_curl_absent_degrades() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (needed to validate the feed line)"
        return 0
    fi
    local sb feed stub
    new_sandbox sb
    feed="$sb/.worktrees/.status/feed.jsonl"
    command rm -f "$feed"
    # Hermetic PATH with bash only — no curl resolvable. The hook reaches its
    # other tools via absolute /usr/bin/* paths, so bash-only PATH is sufficient
    # (matching run_notify's nojq mode). jq is off this PATH too, but the hook's
    # jq branch uses `command -v jq` and falls back to the hand-rolled encoder, so
    # the feed line is still written; we read it back with the outer jq.
    stub="$sb/stub-nocurl"
    command mkdir -p "$stub"
    command ln -sf "$REAL_BASH" "$stub/bash"
    NOTIFY_RC=0
    (
        cd "$sb" &&
            command printf '%s' '{"message":"Claude needs your permission to run git push"}' |
            /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
                "${GOLEM_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
                PATH="$stub" HOME="$sb" GOLEM_ID="golem-1" \
                GOLEM_EVENT_SINKS="http://127.0.0.1:9/x" \
                "$REAL_BASH" "$NOTIFY"
    ) >/dev/null 2>&1 || NOTIFY_RC=$?
    assert_exit 0 "$NOTIFY_RC" "hook exits 0 when curl is absent but sinks are set"
    assert_true "[ -f '$feed' ]" \
        "feed line still written when curl absent — fan-out degrades gracefully (#406)"
}

# unwritable-feed branch — the mkdir non-fatal change (`|| exit 0` -> `|| true`)
# exists so a feed dir that can't be created does NOT skip the HTTP fan (one
# emission = feed AND sinks). Simulate an unwritable status dir by pointing
# GOLEM_STATUS_DIR under a read-only parent, and assert the sink STILL receives
# its POST even though feed.jsonl could not be written — the behavior the diff's
# comment promises.
test_sinks_fire_when_feed_unwritable() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (needed to validate the capture)"
        return 0
    fi
    local sb capdir stub ro
    new_sandbox sb
    capdir="$sb/cap"
    command mkdir -p "$capdir"
    write_curl_stub "$sb/stub-bin"
    stub="$sb/stub-bin"
    # A read-only parent dir: mkdir of <ro>/nope/.status must fail, so the feed
    # write is impossible, but the HTTP fan must still run.
    ro="$sb/readonly"
    command mkdir -p "$ro"
    command chmod 555 "$ro"
    NOTIFY_RC=0
    (
        cd "$sb" &&
            command printf '%s' '{"message":"Claude needs your permission to run git push"}' |
            /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
                "${GOLEM_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
                PATH="$stub:$PATH" HOME="$sb" GOLEM_ID="golem-1" \
                GOLEM_STATUS_DIR="readonly/nope/.status" \
                GOLEM_EVENT_SINKS="http://127.0.0.1:9/x" \
                STUB_CAPTURE_DIR="$capdir" STUB_SLEEP="0" \
                "$REAL_BASH" "$NOTIFY"
    ) >/dev/null 2>&1 || NOTIFY_RC=$?
    # Restore perms so the sandbox cleanup (rm -rf) can remove it.
    command chmod 755 "$ro" 2>/dev/null || true
    assert_exit 0 "$NOTIFY_RC" "hook exits 0 when the feed dir is unwritable"
    poll_capture_count "$capdir" 1
    local n
    n="$(command ls -1 "$capdir" 2>/dev/null | command wc -l | command tr -d ' ')"
    assert_equals "1" "$n" \
        "HTTP sink still POSTed even though feed.jsonl was unwritable (#406 AC1)"
    assert_true "[ ! -f '$sb/readonly/nope/.status/feed.jsonl' ]" \
        "feed.jsonl indeed not written under the read-only parent"
}
