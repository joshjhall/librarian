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
