#!/usr/bin/env bash
# Behavioral regression test for plugins/workflow/scripts/golem-gate-watch.sh.
#
# Guards issue #24: the feed_snapshot() jq filter called `.ts | fromdateiso8601`
# on every entry. A legacy feed line written before the timestamp convention has
# no `.ts` field, so jq threw `strptime/1 requires string inputs and arguments`
# and exited non-zero. The script's `2>/dev/null` swallowed the error and the
# `--once` snapshot returned EMPTY — silently dropping ALL feed-blocked golems
# from the BLOCKED display, including golems carrying valid `gate` events. The
# fix guards the timestamp (`if (.ts|type)=="string" and .ts!="" then ... else
# true end`) so a missing or empty `.ts` line is treated as fresh rather than
# aborting the whole pipeline, while a present-and-stale `.ts` still ages out.
#
# This is the first BEHAVIORAL gate in the suite (the others are structural):
# it builds a throwaway git repo, plants a feed.jsonl, runs the REAL script
# `--once`, and asserts the snapshot. Two cases cover both branches of the fix:
#   1. legacy no-`ts` + valid dated gate -> both survive (the regression)
#   2. a present-but-stale `.ts` outside the TTL window -> excluded (the
#      symmetrical half, so a future refactor dropping the TTL check is caught)
#
# Pure bash + coreutils + git + jq; skips cleanly when jq is absent
# (feed_snapshot itself no-ops without jq). GOLEM_WORKTREE_DIR/GOLEM_STATUS_DIR
# are pinned at the invocation site so an exported value from a live golem
# session or a project `.envrc` cannot redirect the script to a real feed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

GATE_WATCH="$REPO_ROOT/plugins/workflow/scripts/golem-gate-watch.sh"

test_suite "golem-gate-watch feed snapshot (#24)"

# Run the real script `--once` against a throwaway git repo whose
# .worktrees/.status/feed.jsonl holds the given lines. Args: $1 = TTL seconds,
# remaining args = feed.jsonl lines. Sets two globals — SNAP_RC (exit code) and
# SNAP_OUT (stdout) — rather than echoing them, so the exit code and output are
# never multiplexed on one stream and the caller need not subshell the helper.
# GOLEM_WORKTREE_DIR/GOLEM_STATUS_DIR are pinned so an inherited value cannot
# redirect the feed path away from the temp repo.
SNAP_RC=0
SNAP_OUT=""
_run_once_snapshot() {
    local ttl="$1"
    shift
    local tmp
    tmp="$(/usr/bin/mktemp -d)" || return 1
    # shellcheck disable=SC2064  # expand $tmp now, at trap-registration time
    trap "/usr/bin/rm -rf '$tmp'" RETURN

    /usr/bin/git -C "$tmp" init -q 2>/dev/null || return 1
    /usr/bin/mkdir -p "$tmp/.worktrees/.status"
    local line
    for line in "$@"; do
        /usr/bin/printf '%s\n' "$line"
    done >"$tmp/.worktrees/.status/feed.jsonl"

    # Run with cwd inside the temp repo (the script resolves its status dir from
    # the repo root). `&& SNAP_RC=0 || SNAP_RC=$?` records the real exit code
    # without tripping `set -e`; stdout goes to a file so it is read back
    # verbatim rather than mixed with the exit code.
    SNAP_RC=0
    (
        cd "$tmp" &&
            GOLEM_BLOCK_TTL="$ttl" GOLEM_WORKTREE_DIR=.worktrees \
                GOLEM_STATUS_DIR=.worktrees/.status \
                bash "$GATE_WATCH" --once
    ) >"$tmp/out" 2>/dev/null && SNAP_RC=0 || SNAP_RC=$?
    SNAP_OUT="$(/usr/bin/cat "$tmp/out")"
}

# Regression: a legacy line with no `.ts` field must NOT abort the pipeline and
# drop every blocked golem. Both the legacy line and a valid dated gate survive.
# A high TTL keeps the dated gate inside the freshness window regardless of when
# the test runs.
test_legacy_line_does_not_drop_golems() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (feed_snapshot no-ops without jq)"
        return 0
    fi

    _run_once_snapshot 999999999999 \
        '{"golem":"golem-1","event":"blocked","message":"legacy block"}' \
        '{"golem":"golem-2","event":"gate","message":"push gate","ts":"2026-06-27T10:00:00Z"}'

    assert_equals "0" "$SNAP_RC" "Snapshot exits 0 even with a no-ts legacy line"
    assert_not_empty "$SNAP_OUT" "Snapshot is non-empty (legacy line must not abort the pipeline)"
    assert_contains "$SNAP_OUT" "golem-1" "Legacy no-ts blocked golem is honored as a gate"
    assert_contains "$SNAP_OUT" "golem-2" "Valid dated gate golem still appears"
}

# Symmetry: the positive TTL branch still works. A gate whose `.ts` IS present
# but is far older than the TTL window must age out (be excluded), while a fresh
# gate in the same feed survives — guarding against a refactor that drops the
# TTL comparison and shows stale gates forever.
test_stale_ts_gate_ages_out() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (feed_snapshot no-ops without jq)"
        return 0
    fi

    _run_once_snapshot 60 \
        '{"golem":"golem-old","event":"gate","message":"ancient","ts":"1970-01-01T00:00:00Z"}' \
        '{"golem":"golem-new","event":"blocked","message":"legacy still fresh"}'

    assert_equals "0" "$SNAP_RC" "Snapshot exits 0 with a stale-ts gate"
    assert_not_empty "$SNAP_OUT" "Snapshot is non-empty (the no-ts golem is still fresh)"
    assert_contains "$SNAP_OUT" "golem-new" "No-ts golem is honored as fresh"
    # Negative check via a pure-bash glob (no assert_not_contains in the harness,
    # and no eval — keep attacker-influenceable $SNAP_OUT out of any eval'd cmd).
    local stale_present=0
    case "$SNAP_OUT" in
        *golem-old*) stale_present=1 ;;
    esac
    assert_equals "0" "$stale_present" "Stale dated gate ages out of the TTL window"
}

# Distinct from the no-`ts` case: a present-but-empty `.ts` ("") is a string, so
# it passes the `(.ts|type)=="string"` guard and is caught only by the `.ts!=""`
# half. Feeding "" to fromdateiso8601 aborts jq exactly like the original bug —
# so this guards against a refactor that collapses the two conditions into one.
test_empty_ts_treated_as_fresh() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (feed_snapshot no-ops without jq)"
        return 0
    fi

    _run_once_snapshot 60 \
        '{"golem":"golem-empty","event":"gate","message":"empty ts","ts":""}'

    assert_equals "0" "$SNAP_RC" "Snapshot exits 0 with an empty-string ts"
    assert_not_empty "$SNAP_OUT" "Snapshot is non-empty (empty ts must not abort the pipeline)"
    assert_contains "$SNAP_OUT" "golem-empty" "Empty-ts golem is honored as fresh"
}

run_test test_legacy_line_does_not_drop_golems "Legacy no-ts feed line does not drop all BLOCKED golems"
run_test test_stale_ts_gate_ages_out "Stale dated gate ages out while no-ts golem stays fresh"
run_test test_empty_ts_treated_as_fresh "Empty-string ts is treated as fresh, not a crash"

generate_report
