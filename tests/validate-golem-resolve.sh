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

# --- Isolated-tree helpers (no-jq escaper + missing-hook arms) ---------------
#
# The two deferred gaps (#432) drive golem-resolve.sh from a COPY placed in an
# isolated <tree>/scripts/ dir, because the helper resolves its Notification hook
# RELATIVE to its own location ("$SCRIPT_DIR/../hooks/golem-notify.sh"). Copying
# it lets a case control what sits at that sibling path: a payload-capturing SINK
# (to observe the no-jq escaper's output) or NOTHING / a non-exec stub (to drive
# the missing-hook exit-1 arm).
#
# The REAL hook is deliberately NOT used for the no-jq case: on that path the hook
# also lacks jq, so it cannot parse the piped payload and re-defaults the message
# — the helper's escaped message never reaches the feed. The payload golem-resolve
# EMITS is therefore the only surface on which its message escaping is observable,
# which is exactly what the sink captures.

# resolve_tree <outvar> <hook_kind>
#   Builds an isolated tree: <tree>/scripts/golem-resolve.sh is a copy of the real
#   helper; <tree>/hooks/golem-notify.sh depends on <hook_kind>:
#     sink   -> an executable stub that writes its stdin (the payload the helper
#               produced) verbatim to <tree>/payload.txt.
#     none   -> not created — the missing-hook (`! -x`, nonexistent) exit-1 arm.
#     noexec -> created but NOT chmod +x — the missing-hook (`! -x`, non-exec) arm.
#   Assigns the tree path to the caller's named variable.
resolve_tree() {
    local __out="$1" hook_kind="$2" dir
    dir="$(/usr/bin/mktemp -d "$WORKDIR/tree.XXXXXX")" || return 1
    /usr/bin/mkdir -p "$dir/scripts" "$dir/hooks"
    /usr/bin/cp "$RESOLVE" "$dir/scripts/golem-resolve.sh"
    /usr/bin/chmod +x "$dir/scripts/golem-resolve.sh"
    case "$hook_kind" in
        sink)
            # The sink uses /bin/cat by absolute path: the no-jq run strips PATH
            # down to bash only, so a bare `cat` would not resolve.
            /usr/bin/cat >"$dir/hooks/golem-notify.sh" <<EOF
#!/usr/bin/env bash
/bin/cat >"$dir/payload.txt" 2>/dev/null || true
exit 0
EOF
            /usr/bin/chmod +x "$dir/hooks/golem-notify.sh"
            ;;
        noexec)
            /usr/bin/printf '#!/usr/bin/env bash\nexit 0\n' >"$dir/hooks/golem-notify.sh"
            # deliberately NOT chmod +x — exercises the non-exec `! -x` trigger.
            ;;
        none)
            /usr/bin/rmdir "$dir/hooks" 2>/dev/null || true
            ;;
    esac
    printf -v "$__out" '%s' "$dir"
}

# run_resolve_tree <tree> <jq_mode> <arg...>
#   Runs the COPIED helper at <tree>/scripts/ with GIT_*/GOLEM_* scrubbed and HOME
#   pinned. <jq_mode> "nojq" stubs jq off PATH (bash-only PATH from a symlink dir,
#   BASH_ENV unset so /etc/bash_env cannot restore PATH — mirrors
#   validate-golem-notify.sh's run_notify nojq); "jq" leaves PATH intact. Captures
#   the exit code in RESOLVE_RC. These trees carry no feed, so RESOLVE_LINE is
#   cleared — read <tree>/payload.txt for the sink capture instead.
run_resolve_tree() {
    local dir="$1" jq_mode="$2"
    shift 2
    local script="$dir/scripts/golem-resolve.sh"
    RESOLVE_RC=0
    RESOLVE_LINE=""
    if [ "$jq_mode" = "nojq" ]; then
        local stub="$dir/stub-bin"
        /usr/bin/mkdir -p "$stub"
        /usr/bin/ln -sf "$REAL_BASH" "$stub/bash"
        (
            cd "$dir" &&
                /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
                    "${GOLEM_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
                    PATH="$stub" HOME="$dir" \
                    "$REAL_BASH" "$script" "$@"
        ) >/dev/null 2>&1 || RESOLVE_RC=$?
    else
        (
            cd "$dir" &&
                /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
                    "${GOLEM_SCRUB[@]/#/--unset=}" \
                    HOME="$dir" \
                    "$REAL_BASH" "$script" "$@"
        ) >/dev/null 2>&1 || RESOLVE_RC=$?
    fi
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

# --- No-jq JSON escaper (#432 gap 1) ----------------------------------------

# On the jq-less path golem-resolve.sh hand-rolls the Notification payload with
# the same sanitizer as golem-notify.sh (strip backslashes + control chars,
# escape quotes). That escaper is the only thing standing between an adversarial
# free-text message and a corrupted `{"message":"…"}` payload. Feed a message
# carrying an embedded double-quote AND backslash and assert the emitted payload
# stays valid JSON with the backslash dropped and the quote preserved as string
# data. A payload-capturing sink hook makes the helper's output observable (the
# real hook, itself jq-less here, would re-default the message). jq validates the
# capture, so the case skips cleanly when jq is absent.
test_no_jq_escaper_emits_valid_json() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (needed to validate the escaped payload)"
        return 0
    fi
    local tree cap msg
    resolve_tree tree sink
    run_resolve_tree "$tree" nojq 7 'a"b\c'
    assert_equals "0" "$RESOLVE_RC" "Helper exits 0 on the no-jq path"
    cap="$(/usr/bin/cat "$tree/payload.txt" 2>/dev/null || true)"
    assert_not_empty "$cap" "The helper piped a payload to the hook"
    assert_valid_json "$cap" \
        "The hand-rolled payload is valid JSON despite a quote+backslash message"
    msg="$(printf '%s' "$cap" | jq -r '.message' 2>/dev/null || true)"
    # Backslash dropped, embedded double-quote preserved as string DATA, under
    # the RESOLVED: leading marker the producer always emits.
    assert_equals 'RESOLVED: a"bc' "$msg" \
        "backslash dropped, embedded quote preserved as string data under RESOLVED:"
}

# --- Missing/non-exec hook → exit 1 (#432 gap 3) ----------------------------

# When the sibling Notification hook is absent, golem-resolve.sh prints an error
# and returns 1 WITHOUT touching the feed. Drive it from an isolated tree whose
# hooks/ dir is empty, with a VALID id (so the failure is the `! -x` hook check,
# not the exit-2 id validation). No jq dependency — assert exit 1 and no payload.
test_missing_hook_exits_1() {
    local tree
    resolve_tree tree none
    run_resolve_tree "$tree" jq 7
    assert_equals "1" "$RESOLVE_RC" "Absent notify hook → exit 1"
    assert_output_empty "$(/usr/bin/cat "$tree/payload.txt" 2>/dev/null || true)" \
        "No payload is emitted when the hook is missing"
}

# A hook that EXISTS but is not executable trips the same `! -x` arm (exit 1):
# the check is `-x`, not `-e`. Pin it distinctly so a future `-e` regression is
# caught. Valid id again, so the exit is the hook check, not id validation.
test_non_exec_hook_exits_1() {
    local tree
    resolve_tree tree noexec
    run_resolve_tree "$tree" jq 7
    assert_equals "1" "$RESOLVE_RC" "Non-executable notify hook → exit 1 (-x, not -e)"
    assert_output_empty "$(/usr/bin/cat "$tree/payload.txt" 2>/dev/null || true)" \
        "No payload is emitted when the hook is non-executable"
}

# --- Run --------------------------------------------------------------------

run_test test_git_available "git is available (suite prerequisite)"
run_test test_bare_number_emits_resolved "bare N → golem-N resolved feed line (#422)"
run_test test_prefixed_id_accepted "prefixed golem-N normalizes to golem-N"
run_test test_custom_message_rides_through "custom message rides through under RESOLVED:"
run_test test_invalid_id_rejected_no_feed "malformed id rejected (exit 2), feed untouched"
run_test test_missing_arg_usage "missing id → usage, exit 2, feed untouched"
run_test test_no_jq_escaper_emits_valid_json "no-jq escaper emits valid JSON for a quote+backslash message (#432)"
run_test test_missing_hook_exits_1 "absent notify hook → exit 1, no payload (#432)"
run_test test_non_exec_hook_exits_1 "non-exec notify hook → exit 1 (-x not -e), no payload (#432)"

generate_report
