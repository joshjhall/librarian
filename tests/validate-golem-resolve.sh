#!/usr/bin/env bash
# Coverage for plugins/workflow/scripts/golem-resolve.sh (issue #422).
#
# golem-resolve.sh is the explicit-clearing helper the orchestrator runs right
# after the plan-approval `tmux send-keys -t golem-{N} 1 Enter`. That send fires
# NO Notification, so nothing supersedes the golem's stale `gate` feed line and
# golem-status.sh keeps rendering it BLOCKED for the whole GOLEM_BLOCK_TTL
# window. The helper synthesizes a `RESOLVED:`-prefixed Notification and pipes it
# to golem-notify.sh so a `resolved` feed line supersedes the stale gate on the
# next sweep.
#
# Two behaviours carry regression risk:
#   1. id NORMALIZATION/VALIDATION — a bare `7` or a prefixed `golem-7` must both
#      resolve to `golem-7`, and a malformed id (path/shell metacharacters) must
#      be rejected non-zero without touching the feed. The id becomes $GOLEM_ID
#      for the hook, so a bad value must never slip through.
#   2. FEED EMISSION with the RIGHT id — because resolution runs from the
#      ORCHESTRATOR's cwd (the main checkout, whose worktree basename is NOT
#      `issue-N`), the helper must force GOLEM_ID so the hook stamps `golem-N`,
#      not the `golem-?` placeholder it would otherwise derive. This is the whole
#      point of the helper; a regression here silently re-breaks #422.
#
# Test shape mirrors validate-golem-notify.sh: each case runs the REAL helper in
# a fresh `git init` sandbox under a module-level `mktemp -d`, with git's
# hook-exported environment scrubbed (GIT_DIR/…) so the sandbox stays hermetic
# under a pre-push hook, and GOLEM_STATUS_DIR/GOLEM_WORKTREE_DIR scrubbed so an
# operator override cannot redirect the feed out from under the read-back path.
# HOME is repointed at the sandbox defensively.
#
# Pure bash + coreutils + git (+ jq for the feed-line assertions, which skip
# cleanly when jq is absent), reached via absolute /usr/bin/* paths. Uses the
# shared harness assertions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESOLVE="$REPO_ROOT/plugins/workflow/scripts/golem-resolve.sh"

REAL_BASH="$(command -v bash)"

GIT_SCRUB=(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
    GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES)
GOLEM_SCRUB=(GOLEM_STATUS_DIR GOLEM_WORKTREE_DIR GOLEM_ID)

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "golem-resolve.sh clearing-signal helper (#422)"

# --- Sandbox plumbing -------------------------------------------------------

WORKDIR="$(/usr/bin/mktemp -d)"
trap '/usr/bin/rm -rf "$WORKDIR"' EXIT

# new_sandbox <varname> — a fresh `git init` repo with a `.worktrees/.status/`
# dir. The hook resolves its feed under <repo-root>/.worktrees/.status via
# git-common-dir, so a bare init (no commit) is enough. Assigns the path to the
# caller's named variable.
new_sandbox() {
    local __out="$1" dir
    dir="$(/usr/bin/mktemp -d "$WORKDIR/sandbox.XXXXXX")" || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$dir" init -q 2>/dev/null || return 1
    /usr/bin/mkdir -p "$dir/.worktrees/.status"
    printf -v "$__out" '%s' "$dir"
}

# Results of the most recent invocation.
RESOLVE_RC=0
RESOLVE_LINE=""

# run_resolve <sandbox> <arg...> — run the REAL helper from inside the sandbox
# (so the hook resolves its feed there), with GIT_*/GOLEM_* scrubbed and HOME
# pinned. Note: GOLEM_ID is scrubbed from the CHILD env on purpose — the helper
# is responsible for setting it for the hook, so leaving it unset here proves the
# helper (not an inherited env) supplies the id. Captures the exit code in
# RESOLVE_RC and the last feed line in RESOLVE_LINE.
run_resolve() {
    local dir="$1"
    shift
    local feed="$dir/.worktrees/.status/feed.jsonl"
    /usr/bin/rm -f "$feed"
    RESOLVE_RC=0
    (
        cd "$dir" &&
            /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
                "${GOLEM_SCRUB[@]/#/--unset=}" \
                HOME="$dir" \
                "$REAL_BASH" "$RESOLVE" "$@"
    ) >/dev/null 2>&1 || RESOLVE_RC=$?
    RESOLVE_LINE="$(/usr/bin/tail -n 1 "$feed" 2>/dev/null || true)"
}

# --- Emission (feed line carries golem-N + event resolved) ------------------

test_git_available() {
    if ! command -v git >/dev/null 2>&1; then
        skip_test "git not available (suite prerequisite)"
        return 0
    fi
    assert_true "true" "git is available"
}

# A bare number resolves to golem-N, and the feed line is a valid-JSON `resolved`
# event carrying that id — the core contract that clears the stale gate (#422).
test_bare_number_emits_resolved() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (feed-line assertions need jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    run_resolve "$sb" 7
    assert_equals "0" "$RESOLVE_RC" "Helper exits 0 on a bare number"
    assert_not_empty "$RESOLVE_LINE" "A feed line is written"
    assert_valid_json "$RESOLVE_LINE" "Feed line is valid JSON"
    assert_equals "golem-7" "$(printf '%s' "$RESOLVE_LINE" | jq -r '.golem')" \
        "Feed line carries golem-7 (not the golem-? placeholder) — the #422 fix"
    assert_equals "resolved" "$(printf '%s' "$RESOLVE_LINE" | jq -r '.event')" \
        "Feed line is classified as the resolved event kind"
}

# A prefixed `golem-7` is accepted and normalizes identically (no double prefix).
test_prefixed_id_accepted() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (feed-line assertions need jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    run_resolve "$sb" golem-7
    assert_equals "0" "$RESOLVE_RC" "Helper exits 0 on a prefixed id"
    assert_equals "golem-7" "$(printf '%s' "$RESOLVE_LINE" | jq -r '.golem')" \
        "Prefixed golem-7 normalizes to golem-7 (no double prefix)"
}

# The optional message rides through into the RESOLVED:-prefixed feed message.
test_custom_message_rides_through() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (feed-line assertions need jq)"
        return 0
    fi
    local sb
    new_sandbox sb
    run_resolve "$sb" 7 "approved in batch review"
    assert_equals "0" "$RESOLVE_RC" "Helper exits 0 with a custom message"
    assert_contains "$(printf '%s' "$RESOLVE_LINE" | jq -r '.message')" \
        "RESOLVED: approved in batch review" \
        "Custom message is carried under the RESOLVED: marker"
}

# --- Validation (malformed id rejected, feed untouched) ---------------------

# A malformed id (path/shell metacharacters) must be rejected non-zero and write
# NOTHING to the feed — the id becomes $GOLEM_ID for the hook, so a bad value
# must never reach it.
test_invalid_id_rejected_no_feed() {
    local sb
    new_sandbox sb
    run_resolve "$sb" 'foo;rm -rf'
    assert_equals "2" "$RESOLVE_RC" "Malformed id is rejected with exit 2"
    assert_output_empty "$RESOLVE_LINE" "No feed line is written for a rejected id"
}

# No argument at all prints usage and exits non-zero (2), touching nothing.
test_missing_arg_usage() {
    local sb
    new_sandbox sb
    run_resolve "$sb"
    assert_equals "2" "$RESOLVE_RC" "Missing golem id exits 2 (usage)"
    assert_output_empty "$RESOLVE_LINE" "No feed line is written when no id is given"
}

# --- Run --------------------------------------------------------------------

run_test test_git_available "git is available (suite prerequisite)"
run_test test_bare_number_emits_resolved "bare N → golem-N resolved feed line (#422)"
run_test test_prefixed_id_accepted "prefixed golem-N normalizes to golem-N"
run_test test_custom_message_rides_through "custom message rides through under RESOLVED:"
run_test test_invalid_id_rejected_no_feed "malformed id rejected (exit 2), feed untouched"
run_test test_missing_arg_usage "missing id → usage, exit 2, feed untouched"

generate_report
