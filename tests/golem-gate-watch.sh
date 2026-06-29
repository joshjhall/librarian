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

test_suite "golem-gate-watch feed snapshot + liveness (#24, #28, #38)"

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

    # Scrub git's hook-exported environment: when this suite runs from a
    # `git push` pre-push hook, git exports GIT_DIR / GIT_INDEX_FILE / etc. into
    # the environment. Inherited, they pin every `git` call (and the gate-watch
    # script's repo_root) to the OUTER repo, so `git init`/repo_root ignore $tmp
    # and the snapshot reads an empty feed — the assertions then fail only under
    # a real push (not standalone). Unset them so the temp repo is hermetic.
    local git_scrub=(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
        GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES)

    /usr/bin/env "${git_scrub[@]/#/--unset=}" \
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
            /usr/bin/env "${git_scrub[@]/#/--unset=}" \
                GOLEM_BLOCK_TTL="$ttl" GOLEM_WORKTREE_DIR=.worktrees \
                GOLEM_STATUS_DIR=.worktrees/.status \
                bash "$GATE_WATCH" --once
    ) >"$tmp/out" 2>/dev/null && SNAP_RC=0 || SNAP_RC=$?
    SNAP_OUT="$(/usr/bin/cat "$tmp/out")"
}

# As _run_once_snapshot, but runs the script with `jq` stubbed OFF $PATH so the
# `command -v jq >/dev/null 2>&1 || return 0` guard in feed_snapshot() fires.
# The script reaches coreutils via absolute /usr/bin/* paths, so a hermetic PATH
# (bash itself, plus the script's `bash` invoker) is enough — only `jq` and
# `command -v jq` resolve through PATH in the feed-snapshot path. Sets SNAP_RC
# and SNAP_OUT like its sibling.
_run_once_snapshot_no_jq() {
    local ttl="$1"
    shift
    local tmp
    tmp="$(/usr/bin/mktemp -d)" || return 1
    # shellcheck disable=SC2064  # expand $tmp now, at trap-registration time
    trap "/usr/bin/rm -rf '$tmp'" RETURN

    local git_scrub=(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
        GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES)

    /usr/bin/env "${git_scrub[@]/#/--unset=}" \
        /usr/bin/git -C "$tmp" init -q 2>/dev/null || return 1
    /usr/bin/mkdir -p "$tmp/.worktrees/.status"
    local line
    for line in "$@"; do
        /usr/bin/printf '%s\n' "$line"
    done >"$tmp/.worktrees/.status/feed.jsonl"

    # A PATH dir holding only `bash` (the script's interpreter, also re-invoked
    # via `bash "$GATE_WATCH"`), deliberately WITHOUT a `jq` symlink, so
    # `command -v jq` fails inside the script. Resolve the real bash so the stub
    # works even if the harness was launched via an absolute path.
    local stub_bin real_bash
    stub_bin="$tmp/stub-bin"
    /usr/bin/mkdir -p "$stub_bin"
    real_bash="$(command -v bash)"
    /usr/bin/ln -s "$real_bash" "$stub_bin/bash"

    # BASH_ENV is sourced by every non-interactive bash before it runs; some
    # environments (e.g. this devcontainer's /etc/bash_env) RESET $PATH there,
    # which would silently undo the jq-free PATH and defeat the stub. Unset it
    # for the child so the pinned PATH actually reaches feed_snapshot().
    SNAP_RC=0
    (
        cd "$tmp" &&
            /usr/bin/env "${git_scrub[@]/#/--unset=}" --unset=BASH_ENV \
                PATH="$stub_bin" \
                GOLEM_BLOCK_TTL="$ttl" GOLEM_WORKTREE_DIR=.worktrees \
                GOLEM_STATUS_DIR=.worktrees/.status \
                "$real_bash" "$GATE_WATCH" --once
    ) >"$tmp/out" 2>/dev/null && SNAP_RC=0 || SNAP_RC=$?
    SNAP_OUT="$(/usr/bin/cat "$tmp/out")"
}

# Liveness sweep (#38): run the real script `--once-liveness` against a throwaway
# repo. Args: $1 = stall threshold (sec), $2 = age of the planted status file in
# seconds ago (0 = now), remaining args = optional feed.jsonl lines. The age is
# applied as the status file's mtime via `touch -d` so the liveness proxy reads
# a deterministic last-activity regardless of wall-clock. Sets LIVE_RC/LIVE_OUT.
LIVE_RC=0
LIVE_OUT=""
_run_liveness_snapshot() {
    local stall="$1" age_secs="$2"
    shift 2
    local tmp
    tmp="$(/usr/bin/mktemp -d)" || return 1
    # shellcheck disable=SC2064
    trap "/usr/bin/rm -rf '$tmp'" RETURN

    local git_scrub=(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
        GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES)

    /usr/bin/env "${git_scrub[@]/#/--unset=}" \
        /usr/bin/git -C "$tmp" init -q 2>/dev/null || return 1
    /usr/bin/mkdir -p "$tmp/.worktrees/.status"
    # A single golem-7 status-cache file is the activity proxy. Backdate its
    # mtime so age = $age_secs deterministically.
    /usr/bin/printf '%s\n' '{"golem":"golem-7","issue":7,"phase":"impl"}' \
        >"$tmp/.worktrees/.status/golem-7.json"
    /usr/bin/touch -d "@$(($(/usr/bin/date +%s) - age_secs))" \
        "$tmp/.worktrees/.status/golem-7.json"
    if [ "$#" -gt 0 ]; then
        local line
        for line in "$@"; do
            /usr/bin/printf '%s\n' "$line"
        done >"$tmp/.worktrees/.status/feed.jsonl"
    fi

    LIVE_RC=0
    (
        cd "$tmp" &&
            /usr/bin/env "${git_scrub[@]/#/--unset=}" \
                GOLEM_STALL_THRESHOLD="$stall" GOLEM_BLOCK_TTL=3600 \
                GOLEM_WORKTREE_DIR=.worktrees \
                GOLEM_STATUS_DIR=.worktrees/.status \
                bash "$GATE_WATCH" --once-liveness
    ) >"$tmp/out" 2>/dev/null && LIVE_RC=0 || LIVE_RC=$?
    LIVE_OUT="$(/usr/bin/cat "$tmp/out")"
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

# jq-absent contract (#28): feed_snapshot() guards on `command -v jq ... ||
# return 0`, so with jq off $PATH the `--once` snapshot is a silent no-op —
# exit 0, EMPTY output — EVEN with a fresh gated entry in the feed. This pins
# that documented behavior (a runtime missing jq must not crash the watcher, and
# its silence is indistinguishable from a clean empty feed by design). Unlike
# the sibling tests it does NOT skip when jq is present: it stubs jq OFF the
# script's PATH so the guard fires regardless of the host. Skips only when the
# host bash cannot be resolved (the stub needs a real bash to symlink).
test_jq_absent_is_silent_noop() {
    if ! command -v bash >/dev/null 2>&1; then
        skip_test "bash not resolvable on PATH (cannot build a jq-free stub PATH)"
        return 0
    fi

    # A fresh, valid, dated gate that WOULD appear if jq were present.
    _run_once_snapshot_no_jq 999999999999 \
        '{"golem":"golem-7","event":"gate","message":"push gate","ts":"2026-06-27T10:00:00Z"}'

    assert_equals "0" "$SNAP_RC" "Snapshot exits 0 when jq is absent"
    assert_output_empty "$SNAP_OUT" "Snapshot emits nothing when jq is absent, even with a fresh gate"
}

# Liveness (#38): a golem whose activity proxy is INSIDE the stall window is a
# positive heartbeat — "alive, advancing", exit 0, never a stall.
test_liveness_fresh_is_alive() {
    # age 0 (now), generous threshold -> alive.
    _run_liveness_snapshot 1200 0

    assert_equals "0" "$LIVE_RC" "Liveness snapshot exits 0 for a fresh golem"
    assert_contains "$LIVE_OUT" "golem-7" "Fresh golem appears in the liveness sweep"
    assert_contains "$LIVE_OUT" "alive" "Fresh golem is reported alive/advancing"
    local stall_present=0
    case "$LIVE_OUT" in
        *stall*) stall_present=1 ;;
    esac
    assert_equals "0" "$stall_present" "A fresh golem is NOT flagged as a possible stall"
}

# Liveness (#38): a golem whose newest activity is OLDER than the stall window
# is flagged a *possible stall* — still exit 0 (advisory, never a hard-fail).
test_liveness_stale_is_possible_stall() {
    # Activity 3600s ago, threshold 1200s -> stall.
    _run_liveness_snapshot 1200 3600

    assert_equals "0" "$LIVE_RC" "Liveness snapshot exits 0 even when flagging a stall"
    assert_contains "$LIVE_OUT" "golem-7" "Stalled golem appears in the liveness sweep"
    assert_contains "$LIVE_OUT" "possible stall" "Old-activity golem is flagged a possible stall"
}

# Liveness (#38): a golem currently at a FRESH feed gate is reported as gated,
# NOT as a stall — even when its activity proxy is old (a parked golem stops
# touching its worktree). The gate is expected supervision, distinct from a hang.
test_liveness_gated_not_stalled() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (gate detection no-ops without jq)"
        return 0
    fi
    # Old activity (would otherwise be a stall) + a fresh gate for the SAME golem.
    _run_liveness_snapshot 1200 3600 \
        "{\"golem\":\"golem-7\",\"event\":\"gate\",\"message\":\"push gate\",\"ts\":\"$(/usr/bin/date -u +%Y-%m-%dT%H:%M:%SZ)\"}"

    assert_equals "0" "$LIVE_RC" "Liveness snapshot exits 0 for a gated golem"
    assert_contains "$LIVE_OUT" "gated" "Gated golem is reported gated, not stalled"
    local stall_present=0
    case "$LIVE_OUT" in
        *"possible stall"*) stall_present=1 ;;
    esac
    assert_equals "0" "$stall_present" "A gated golem is NOT double-reported as a stall"
}

# Liveness (#38): env overridability per config.sh precedent. With
# GOLEM_STALL_THRESHOLD lowered BELOW the activity age, the same golem that is
# "alive" under the default flips to "possible stall" — proving the threshold is
# honored from the environment via ${VAR:-default}.
test_liveness_threshold_env_overridable() {
    # Activity 120s ago. Threshold 60s -> stall (120 > 60).
    _run_liveness_snapshot 60 120

    assert_equals "0" "$LIVE_RC" "Liveness snapshot exits 0 with a low env threshold"
    assert_contains "$LIVE_OUT" "possible stall" \
        "GOLEM_STALL_THRESHOLD is env-overridable (low threshold flips alive->stall)"
}

run_test test_legacy_line_does_not_drop_golems "Legacy no-ts feed line does not drop all BLOCKED golems"
run_test test_stale_ts_gate_ages_out "Stale dated gate ages out while no-ts golem stays fresh"
run_test test_empty_ts_treated_as_fresh "Empty-string ts is treated as fresh, not a crash"
run_test test_jq_absent_is_silent_noop "jq absent from PATH: --once is a silent no-op despite a fresh gate"
run_test test_liveness_fresh_is_alive "Liveness: fresh-activity golem reports alive/advancing"
run_test test_liveness_stale_is_possible_stall "Liveness: old-activity golem flagged a possible stall (exit 0)"
run_test test_liveness_gated_not_stalled "Liveness: gated golem reported gated, not stalled"
run_test test_liveness_threshold_env_overridable "Liveness: GOLEM_STALL_THRESHOLD is env-overridable"

generate_report
