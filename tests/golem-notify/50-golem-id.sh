# shellcheck shell=bash
# Golem-id derivation — golem-notify hook tests (issue #564 split).
#
# Covers the fallback branches used when the id is not directly available.
#
# Sourced by tests/validate-golem-notify.sh, which defines NOTIFY / CONFIG_SH /
# REAL_BASH and sources tests/lib/golem-notify-sandbox.sh for the shared drivers
# BEFORE this file. This fragment only DEFINES test functions; the entry point
# dispatches them from its explicit ordered run_test list.

# Local to this area: the golem-id fallback branches are the only tests that
# need a NAMED sandbox dir (the id is derived from the directory name).
# new_named_sandbox <varname> <name>
# Like new_sandbox, but the sandbox dir gets a CHOSEN basename ($WORKDIR/<name>)
# instead of a random `sandbox.XXXXXX`. The golem-id fallback (branch 2) keys off
# the worktree-root basename (`git rev-parse --show-toplevel`), so a deterministic
# name is what lets a test assert the derived `issue-N -> golem-N` / `golem-*`
# pass-through / `golem-?` placeholder outcome. Assigns the path to the caller's
# named variable.
new_named_sandbox() {
    local __out="$1" name="$2" dir="$WORKDIR/$2"
    command mkdir -p "$dir" || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$dir" init -q 2>/dev/null || return 1
    command mkdir -p "$dir/.worktrees/.status"
    printf -v "$__out" '%s' "$dir"
}

# Local to this area: drives the hook with no golem id in the payload, which is
# precisely what these fallback-branch tests exist to exercise.
# run_notify_no_gid <sandbox> <payload> [subdir]
# Like run_notify's jq path but with GOLEM_ID UNSET (via `env --unset=GOLEM_ID`),
# so branch 1 of the golem-id derivation cannot resolve and the hook falls back to
# the worktree-basename branch (or the placeholder). Everything else mirrors
# run_notify: GIT_* scrubbed, HOME pinned at the sandbox, results captured in
# NOTIFY_RC / NOTIFY_LINE.
#
# When [subdir] is given, the hook is run from <sandbox>/<subdir> (created here)
# instead of the worktree root — the ONLY setup that distinguishes branch 2's
# `git rev-parse --show-toplevel` derivation from a `pwd` regression (issue #312):
# from a nested subdir, pwd's basename is the leaf dir while the worktree-root
# basename stays `issue-N`. The feed is still resolved (and read back) at the
# worktree root via git-common-dir regardless of the invocation cwd.
run_notify_no_gid() {
    local dir="$1" payload="$2" sub="${3:-}"
    local feed="$dir/.worktrees/.status/feed.jsonl"
    local rundir="$dir"
    command rm -f "$feed"
    if [ -n "$sub" ]; then
        command mkdir -p "$dir/$sub"
        rundir="$dir/$sub"
    fi
    NOTIFY_RC=0
    (
        cd "$rundir" &&
            command printf '%s' "$payload" |
            /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
                "${GOLEM_SCRUB[@]/#/--unset=}" --unset=GOLEM_ID \
                HOME="$dir" \
                "$REAL_BASH" "$NOTIFY"
    ) >/dev/null 2>&1 || NOTIFY_RC=$?
    NOTIFY_LINE="$(command tail -n 1 "$feed" 2>/dev/null || true)"
}

# --- Golem-id derivation fallback (branches 2 & 3) --------------------------

# With GOLEM_ID unset, the hook derives the golem id from the worktree-root
# basename: `issue-N` -> `golem-N`, an already-`golem-*` basename passes through,
# and anything else yields the `golem-?` placeholder. These three cases are the
# only coverage of that fallback — every other case pins GOLEM_ID and so only
# exercises branch 1 (issue #250). jq is used to read `.golem` back out, so they
# skip cleanly when it is absent.

# assert_golemid <sandbox-name> <expected-golem> <desc>
# Runs the hook with GOLEM_ID unset inside a sandbox named <sandbox-name>, asserts
# exit 0, a valid-JSON feed line, and the derived `.golem`.
assert_golemid() {
    local name="$1" want="$2" desc="$3" sb got
    new_named_sandbox sb "$name" || {
        _fail "sandbox setup failed ($desc)"
        return 0
    }
    run_notify_no_gid "$sb" '{"message":"awaiting a decision"}'
    assert_exit 0 "$NOTIFY_RC" "hook exits 0 ($desc)"
    assert_valid_json "$NOTIFY_LINE" \
        "feed line is valid JSON ($desc)"
    got="$(printf '%s' "$NOTIFY_LINE" | jq -r '.golem' 2>/dev/null || true)"
    assert_equals "$want" "$got" "derived golem id is $want ($desc)"
}

# issue-N worktree basename maps to golem-N (the `${base#issue-}` stripping).
test_golemid_issue_basename() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (reads .golem back with jq)"
        return 0
    fi
    assert_golemid "issue-42" "golem-42" "issue-42 basename → golem-42"
}

# An already-golem-* worktree basename passes through unchanged.
test_golemid_golem_passthrough() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (reads .golem back with jq)"
        return 0
    fi
    assert_golemid "golem-7" "golem-7" "golem-7 basename passes through"
}

# A basename matching neither `issue-*` nor `golem-*` yields the placeholder.
test_golemid_placeholder() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (reads .golem back with jq)"
        return 0
    fi
    assert_golemid "plain-checkout" "golem-?" "non-worktree basename → golem-? placeholder"
}

# cwd-independence (issue #312). Branch 2 derives the golem id from the WORKTREE
# ROOT via `git rev-parse --show-toplevel`, NOT `pwd`, so a Notification firing
# from a subdirectory (or a review-harness subagent with its own nested cwd)
# still resolves `issue-N -> golem-N`. The three tests above run from the sandbox
# root, where pwd and show-toplevel are indistinguishable — a regression swapping
# show-toplevel for pwd would pass all of them. This case runs the hook from a
# NESTED subdir (`nested/work/dir`) whose leaf basename would derive `golem-?`
# under a pwd read, and asserts the derivation is still `golem-77` — directly
# pinning the cwd-independence property branch 2 provides. Its own sandbox name
# (issue-77, not the issue-42 the root case uses) keeps the two tests isolated.
test_golemid_issue_basename_from_subdir() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (reads .golem back with jq)"
        return 0
    fi
    local sb got
    new_named_sandbox sb "issue-77" || {
        _fail "sandbox setup failed (issue-77 from subdir)"
        return 0
    }
    run_notify_no_gid "$sb" '{"message":"awaiting a decision"}' "nested/work/dir"
    assert_exit 0 "$NOTIFY_RC" "hook exits 0 (issue-77 from subdir)"
    assert_valid_json "$NOTIFY_LINE" \
        "feed line is valid JSON (issue-77 from subdir)"
    got="$(printf '%s' "$NOTIFY_LINE" | jq -r '.golem' 2>/dev/null || true)"
    assert_equals "golem-77" "$got" \
        "cwd-independent: issue-77 root derives golem-77 even from a nested subdir"
}

# --- Golem-id derivation: the AGENT_ID rung (branch 3, #744) ----------------

# Local to this area: the only driver that pins AGENT_ID. Every other case in
# this suite runs with AGENT_ID scrubbed (it is in GOLEM_SCRUB), which is what
# keeps the placeholder cases above honest inside a container golem.
# run_notify_agent_id <sandbox> <agent_id> [golem_id] [nojq]
# Runs the hook with AGENT_ID=<agent_id> exported. GOLEM_ID is UNSET unless
# [golem_id] is given non-empty — the rung-1-outranks-rung-3 case is the only
# one that sets both. Passing "nojq" as the 4th arg strips PATH to a bash-only
# stub dir so `command -v jq` fails and the hand-rolled escaper runs, mirroring
# run_notify's nojq mode (incl. the BASH_ENV unset, without which this
# devcontainer's /etc/bash_env would restore PATH and silently re-enable jq).
#
# The `--unset=` options precede the NAME=VALUE assignments deliberately: env
# applies options first, so AGENT_ID is scrubbed by GOLEM_SCRUB and then set
# back to exactly the value under test, never inherited from the ambient
# environment.
run_notify_agent_id() {
    local dir="$1" aid="$2" gid="${3:-}" mode="${4:-}"
    local feed="$dir/.worktrees/.status/feed.jsonl"
    local stub="$dir/stub-bin"
    command rm -f "$feed"
    NOTIFY_RC=0
    if [ "$mode" = "nojq" ]; then
        command mkdir -p "$stub"
        command ln -sf "$REAL_BASH" "$stub/bash"
        (
            cd "$dir" &&
                command printf '%s' '{"message":"awaiting a decision"}' |
                /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
                    "${GOLEM_SCRUB[@]/#/--unset=}" --unset=GOLEM_ID --unset=BASH_ENV \
                    PATH="$stub" HOME="$dir" AGENT_ID="$aid" \
                    "$REAL_BASH" "$NOTIFY"
        ) >/dev/null 2>&1 || NOTIFY_RC=$?
    elif [ -n "$gid" ]; then
        (
            cd "$dir" &&
                command printf '%s' '{"message":"awaiting a decision"}' |
                /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
                    "${GOLEM_SCRUB[@]/#/--unset=}" \
                    HOME="$dir" AGENT_ID="$aid" GOLEM_ID="$gid" \
                    "$REAL_BASH" "$NOTIFY"
        ) >/dev/null 2>&1 || NOTIFY_RC=$?
    else
        (
            cd "$dir" &&
                command printf '%s' '{"message":"awaiting a decision"}' |
                /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
                    "${GOLEM_SCRUB[@]/#/--unset=}" --unset=GOLEM_ID \
                    HOME="$dir" AGENT_ID="$aid" \
                    "$REAL_BASH" "$NOTIFY"
        ) >/dev/null 2>&1 || NOTIFY_RC=$?
    fi
    NOTIFY_LINE="$(command tail -n 1 "$feed" 2>/dev/null || true)"
}

# assert_agentid <sandbox-name> <agent-id> <golem-id-or-empty> <expected> <desc>
# Runs the hook with AGENT_ID (and optionally GOLEM_ID) pinned inside a sandbox
# named <sandbox-name>, asserts exit 0, valid JSON, and the derived `.golem`.
assert_agentid() {
    local name="$1" aid="$2" gid="$3" want="$4" desc="$5" sb got
    new_named_sandbox sb "$name" || {
        _fail "sandbox setup failed ($desc)"
        return 0
    }
    run_notify_agent_id "$sb" "$aid" "$gid"
    assert_exit 0 "$NOTIFY_RC" "hook exits 0 ($desc)"
    assert_valid_json "$NOTIFY_LINE" "feed line is valid JSON ($desc)"
    got="$(printf '%s' "$NOTIFY_LINE" | jq -r '.golem' 2>/dev/null || true)"
    assert_equals "$want" "$got" "derived golem id is $want ($desc)"
}

# Rung 3 resolves ahead of the placeholder, and is keyed BARE.
#
# The sandbox basename matches neither `issue-*` nor `golem-*`, so before #744
# this derived the `golem-?` placeholder — that is what makes this case fail
# without the fix. The expected value is the bare `agent07` with NO suffix: the
# cross-hook agreement identity `host_session_id == "<project>-" + feed_golem`
# holds only while both hooks key AGENT_ID bare, so a suffix added here would
# silently split the two feeds for exactly the sessions this arm exists to name.
test_golemid_agent_id_resolves() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (reads .golem back with jq)"
        return 0
    fi
    assert_agentid "container-checkout" "agent07" "" "agent07" \
        "AGENT_ID → bare agent07, not the golem-? placeholder"
}

# Rung 1 (GOLEM_ID) outranks rung 3 (AGENT_ID). Both are set; the sandbox
# basename matches neither shape, so the ladder cannot reach rung 2 and the
# assertion isolates 1-vs-3. This is a POSITION pin rather than an
# arm-existence pin — it passes without the #744 arm too — and its mutant is a
# reordering that hoists the AGENT_ID case above the GOLEM_ID one, which is the
# regression it exists to catch (a container golem on the pipeline path has
# BOTH set, so an inverted order would rename every such golem).
test_golemid_golem_id_outranks_agent_id() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (reads .golem back with jq)"
        return 0
    fi
    assert_agentid "container-checkout-2" "agent07" "golem-5" "golem-5" \
        "GOLEM_ID (rung 1) outranks AGENT_ID (rung 3)"
}

# Rung 2 (worktree-root basename) outranks rung 3 (AGENT_ID). GOLEM_ID is unset,
# so the ladder reaches rung 2, whose `issue-*` match must win before the
# AGENT_ID case nested in the fallback is ever consulted. Also a position pin;
# its mutant lifts the AGENT_ID case out of the `*)` fallback to sit ahead of
# the `issue-*` arm.
test_golemid_worktree_outranks_agent_id() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (reads .golem back with jq)"
        return 0
    fi
    assert_agentid "issue-88" "agent07" "" "golem-88" \
        "worktree root (rung 2) outranks AGENT_ID (rung 3)"
}

# An already-`golem-*` worktree basename also outranks AGENT_ID — the other
# rung-2 arm. Without this the passthrough arm's position is untested.
test_golemid_golem_basename_outranks_agent_id() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (reads .golem back with jq)"
        return 0
    fi
    assert_agentid "golem-9" "agent07" "" "golem-9" \
        "golem-* basename (rung 2) outranks AGENT_ID (rung 3)"
}

# An EMPTY AGENT_ID falls through to the placeholder. This pins the `?*` guard
# specifically: mutating it to a bare `*` keys the feed on the empty string, so
# `.golem` comes back "" and this fails. Without that guard a container that
# exports AGENT_ID= (set but empty) would emit nameless feed lines, which
# golem-gate-watch.sh's `golem-?` orphan drop would no longer recognize — the
# gate would then sit BLOCKED forever, bypassing the TTL (#323).
test_golemid_empty_agent_id_falls_through() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (reads .golem back with jq)"
        return 0
    fi
    assert_agentid "container-checkout-3" "" "" "golem-?" \
        "empty AGENT_ID falls through to the golem-? placeholder"
}

# The no-jq hand-rolled escaper sanitizes an injection-laden AGENT_ID.
#
# Rung 3 interpolates AGENT_ID with NO shape check (unlike rung 1's `golem-*`
# and rung 2's `issue-*` guards), so it is the second attacker-influenceable
# value — alongside GOLEM_ID — that can reach the hand-rolled encoder. The
# payload carries a double-quote and a backslash: the encoder must drop the
# backslash and escape the quote, leaving a line that still parses as JSON.
# Without the #744 arm the id derives `golem-?` and the sanitizer never sees the
# hostile value, so the `.golem` assertion below fails.
test_golemid_agent_id_nojq_sanitized() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (needed to validate the escaped JSON)"
        return 0
    fi
    local sb got
    new_named_sandbox sb "container-checkout-4" || {
        _fail "sandbox setup failed (nojq AGENT_ID sanitize)"
        return 0
    }
    run_notify_agent_id "$sb" 'agent"07\bad' "" "nojq"
    assert_exit 0 "$NOTIFY_RC" "hook exits 0 (nojq AGENT_ID sanitize)"
    assert_valid_json "$NOTIFY_LINE" \
        "no-jq feed line stays valid JSON for a quote+backslash AGENT_ID"
    got="$(printf '%s' "$NOTIFY_LINE" | jq -r '.golem' 2>/dev/null || true)"
    assert_equals 'agent"07bad' "$got" \
        "no-jq escaper: AGENT_ID backslash dropped, quote escaped and round-trips"
}
