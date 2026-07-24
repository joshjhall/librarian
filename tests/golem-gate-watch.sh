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

test_suite "golem-gate-watch feed snapshot + liveness + helpers (#24, #28, #38, #82, #229, #248, #446, #447, #489)"

# _pane_rc <function-name> <text> — source the script (the main-guard makes it
# sourceable without running the drive block) in a subshell and call one of its
# prompt-overlay matchers, echoing the function's exit code. The subshell
# isolates the script's `set -uo pipefail` from the harness's `set -euo
# pipefail`, and `|| rc=$?` keeps a rc-1 (non-match) from aborting under set -e.
_pane_rc() {
    local fn="$1" text="$2" rc=0
    (
        source "$GATE_WATCH"
        "$fn" "$text"
    ) >/dev/null 2>&1 || rc=$?
    command echo "$rc"
}

# _stamp_feed_traces <status-dir> <feed-line>... — for every distinct `golem`
# value appearing in the given feed lines, drop a `<golem>.json` status-cache file
# in <status-dir>. This gives each fixture golem a live TRACE so the #446 ghost
# filter (feed_snapshot_live -> golem_has_live_trace) keeps it: these feed-
# semantics tests assert TTL / event-kind / orphan-drop behavior, NOT the ghost
# filter, so their golems must look live (as a real gated golem does — its cache
# file exists) or the ghost filter would drop every one of them and mask the
# semantics under test. The `golem-?` orphan sentinel is intentionally NOT stamped
# (it is dropped by feed_snapshot before the trace check, and #323's orphan test
# asserts exactly that). Parses the id with grep/sed (jq may be stubbed off in the
# no-jq helper), tolerant of absent/misshaped lines.
_stamp_feed_traces() {
    local status_dir="$1" line g
    shift
    for line in "$@"; do
        g="$(command printf '%s\n' "$line" |
            command grep -oE '"golem"[[:space:]]*:[[:space:]]*"[^"]*"' |
            command sed -E 's/.*"([^"]*)"$/\1/' | command head -n1)"
        case "$g" in
            '' | 'golem-?') continue ;;
        esac
        command printf '{"golem":"%s"}\n' "$g" >"$status_dir/$g.json"
    done
}

# Run the real script `--once` against a throwaway git repo whose
# .worktrees/.status/feed.jsonl holds the given lines. Args: $1 = TTL seconds,
# remaining args = feed.jsonl lines. Sets two globals — SNAP_RC (exit code) and
# SNAP_OUT (stdout) — rather than echoing them, so the exit code and output are
# never multiplexed on one stream and the caller need not subshell the helper.
# GOLEM_WORKTREE_DIR/GOLEM_STATUS_DIR are pinned so an inherited value cannot
# redirect the feed path away from the temp repo. Each fixture golem is given a
# status-cache trace (see _stamp_feed_traces) so the #446 ghost filter keeps it.
SNAP_RC=0
SNAP_OUT=""
_run_once_snapshot() {
    local ttl="$1"
    shift
    local tmp
    tmp="$(command mktemp -d)" || return 1
    # shellcheck disable=SC2064  # expand $tmp now, at trap-registration time
    trap "command rm -rf '$tmp'" RETURN

    # Scrub git's hook-exported environment: when this suite runs from a
    # `git push` pre-push hook, git exports GIT_DIR / GIT_INDEX_FILE / etc. into
    # the environment. Inherited, they pin every `git` call (and the gate-watch
    # script's repo_root) to the OUTER repo, so `git init`/repo_root ignore $tmp
    # and the snapshot reads an empty feed — the assertions then fail only under
    # a real push (not standalone). Unset them so the temp repo is hermetic.
    local git_scrub=(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
        GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES)

    /usr/bin/env "${git_scrub[@]/#/--unset=}" \
        git -C "$tmp" init -q 2>/dev/null || return 1
    command mkdir -p "$tmp/.worktrees/.status"
    local line
    for line in "$@"; do
        command printf '%s\n' "$line"
    done >"$tmp/.worktrees/.status/feed.jsonl"
    _stamp_feed_traces "$tmp/.worktrees/.status" "$@"

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
    SNAP_OUT="$(command cat "$tmp/out")"
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
    tmp="$(command mktemp -d)" || return 1
    # shellcheck disable=SC2064  # expand $tmp now, at trap-registration time
    trap "command rm -rf '$tmp'" RETURN

    local git_scrub=(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
        GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES)

    /usr/bin/env "${git_scrub[@]/#/--unset=}" \
        git -C "$tmp" init -q 2>/dev/null || return 1
    command mkdir -p "$tmp/.worktrees/.status"
    local line
    for line in "$@"; do
        command printf '%s\n' "$line"
    done >"$tmp/.worktrees/.status/feed.jsonl"
    _stamp_feed_traces "$tmp/.worktrees/.status" "$@"

    # A PATH dir holding only `bash` (the script's interpreter, also re-invoked
    # via `bash "$GATE_WATCH"`), deliberately WITHOUT a `jq` symlink, so
    # `command -v jq` fails inside the script. Resolve the real bash so the stub
    # works even if the harness was launched via an absolute path.
    local stub_bin real_bash
    stub_bin="$tmp/stub-bin"
    command mkdir -p "$stub_bin"
    real_bash="$(command -v bash)"
    command ln -s "$real_bash" "$stub_bin/bash"

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
    SNAP_OUT="$(command cat "$tmp/out")"
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
    tmp="$(command mktemp -d)" || return 1
    # shellcheck disable=SC2064
    trap "command rm -rf '$tmp'" RETURN

    local git_scrub=(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
        GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES)

    /usr/bin/env "${git_scrub[@]/#/--unset=}" \
        git -C "$tmp" init -q 2>/dev/null || return 1
    command mkdir -p "$tmp/.worktrees/.status"
    # A single golem-7 status-cache file is the activity proxy. Backdate its
    # mtime so age = $age_secs deterministically.
    command printf '%s\n' '{"golem":"golem-7","issue":7,"phase":"impl"}' \
        >"$tmp/.worktrees/.status/golem-7.json"
    command touch -d "@$(($(command date +%s) - age_secs))" \
        "$tmp/.worktrees/.status/golem-7.json"
    if [ "$#" -gt 0 ]; then
        local line
        for line in "$@"; do
            command printf '%s\n' "$line"
        done >"$tmp/.worktrees/.status/feed.jsonl"
    fi

    # Hermetic PATH with a fake tmux whose `ls` prints nothing, so ONLY the
    # planted golem-7 status file seeds the sweep and a real host `golem-*` tmux
    # session cannot leak in (#436). Without this, running the suite during
    # active orchestration lets a live golem's pane be scraped as `working`,
    # overriding the mtime "process up" heartbeat these tests assert on and
    # failing the pre-push hook. Mirrors the stub in _run_liveness_snapshot_tmux;
    # the mtime-path tests want NO session (so `has-session` fails, `capture-pane`
    # is empty) — the sweep then falls through to the reworded mtime heartbeat.
    local stub_bin real_bash real_git real_jq
    stub_bin="$tmp/stub-bin"
    command mkdir -p "$stub_bin"
    real_bash="$(command -v bash)"
    real_git="$(command -v git)"
    command ln -s "$real_bash" "$stub_bin/bash"
    command ln -s "$real_git" "$stub_bin/git"
    # jq symlinked through when present: the gate-detection path (feed parsing)
    # needs it, and these tests skip themselves when jq is absent. Unlike the
    # _tmux sibling (whose tests never touch the feed), this helper's callers do.
    real_jq="$(command -v jq || true)"
    [ -n "$real_jq" ] && command ln -s "$real_jq" "$stub_bin/jq"
    command cat >"$stub_bin/tmux" <<'TMUX_STUB'
#!/usr/bin/env bash
case "$1" in
    ls) exit 0 ;;
    has-session) exit 1 ;;
    capture-pane) exit 0 ;;
    *) exit 0 ;;
esac
TMUX_STUB
    command chmod +x "$stub_bin/tmux"

    # --unset=BASH_ENV: the devcontainer's /etc/bash_env resets $PATH for every
    # non-interactive bash, which would undo the hermetic PATH (same guard as the
    # jq / tmux-pane stubs).
    LIVE_RC=0
    (
        cd "$tmp" &&
            /usr/bin/env "${git_scrub[@]/#/--unset=}" --unset=BASH_ENV \
                PATH="$stub_bin" \
                GOLEM_STALL_THRESHOLD="$stall" GOLEM_BLOCK_TTL=3600 \
                GOLEM_WORKTREE_DIR=.worktrees \
                GOLEM_STATUS_DIR=.worktrees/.status \
                "$real_bash" "$GATE_WATCH" --once-liveness
    ) >"$tmp/out" 2>/dev/null && LIVE_RC=0 || LIVE_RC=$?
    LIVE_OUT="$(command cat "$tmp/out")"
}

# Liveness pane wiring (#229/#247): as _run_liveness_snapshot, but stubs `tmux`
# ON $PATH with a fake that answers `has-session` (success) and `capture-pane`
# (canned pane text) so the real `--once-liveness` drives the tmux-pane branch of
# liveness_snapshot() end-to-end — the `case "$pclass" in working) … idle) …`
# dispatch, its emitted strings, and the pane-read-vs-mtime precedence. The
# sibling helpers only reach the mtime heartbeat (no tmux session under test);
# test_pane_liveness_class exercises the classifier in isolation but never the
# wiring. Args: $1 = stall threshold (sec), $2 = status-file age (sec ago),
# $3 = the pane text the fake `tmux capture-pane` prints. Sets LIVE_RC/LIVE_OUT.
#
# PATH-stub precedent is _run_once_snapshot_no_jq above (it stubs jq OFF PATH).
# Here the stub PATH must carry the tools the liveness path resolves via PATH:
# `bash` (the script's interpreter, re-invoked as `bash "$GATE_WATCH"`), `git`
# (repo_root() in config.sh calls `command git rev-parse` — an unreachable git
# makes repo_root empty and liveness_snapshot returns early with no output), and
# our fake `tmux`. Everything else is reached via absolute /usr/bin/* in the
# script, so this hermetic trio is sufficient. The fake `tmux ls` prints nothing,
# so only the planted golem-7 status file seeds the sweep — a real host golem
# session cannot leak in (guards the host-leak failure mode of the mtime path).
_run_liveness_snapshot_tmux() {
    local stall="$1" age_secs="$2" pane_text="$3"
    local tmp
    tmp="$(command mktemp -d)" || return 1
    # shellcheck disable=SC2064
    trap "command rm -rf '$tmp'" RETURN

    local git_scrub=(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
        GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES)

    /usr/bin/env "${git_scrub[@]/#/--unset=}" \
        git -C "$tmp" init -q 2>/dev/null || return 1
    command mkdir -p "$tmp/.worktrees/.status"
    # golem-7 status cache is the activity proxy that discovers golem-7 into the
    # sweep; backdate its mtime so age = $age_secs deterministically.
    command printf '%s\n' '{"golem":"golem-7","issue":7,"phase":"impl"}' \
        >"$tmp/.worktrees/.status/golem-7.json"
    command touch -d "@$(($(command date +%s) - age_secs))" \
        "$tmp/.worktrees/.status/golem-7.json"

    # Hermetic PATH: real bash + real git symlinks, plus a fake tmux script.
    local stub_bin real_bash real_git
    stub_bin="$tmp/stub-bin"
    command mkdir -p "$stub_bin"
    real_bash="$(command -v bash)"
    real_git="$(command -v git)"
    command ln -s "$real_bash" "$stub_bin/bash"
    command ln -s "$real_git" "$stub_bin/git"

    # Fake tmux: `ls` -> nothing (only the status file seeds the sweep);
    # `has-session` -> success; `capture-pane` -> the canned pane text from
    # $FAKE_PANE_TEXT; anything else -> success no-op. Kept bash-3.2 clean.
    command cat >"$stub_bin/tmux" <<'TMUX_STUB'
#!/usr/bin/env bash
case "$1" in
    ls) exit 0 ;;
    has-session) exit 0 ;;
    capture-pane) command printf '%s\n' "${FAKE_PANE_TEXT:-}" ;;
    *) exit 0 ;;
esac
TMUX_STUB
    command chmod +x "$stub_bin/tmux"

    # --unset=BASH_ENV: the devcontainer's /etc/bash_env resets $PATH for every
    # non-interactive bash, which would undo the hermetic PATH (same guard as the
    # jq stub). FAKE_PANE_TEXT is read by the fake tmux above.
    LIVE_RC=0
    (
        cd "$tmp" &&
            /usr/bin/env "${git_scrub[@]/#/--unset=}" --unset=BASH_ENV \
                PATH="$stub_bin" \
                FAKE_PANE_TEXT="$pane_text" \
                GOLEM_STALL_THRESHOLD="$stall" GOLEM_BLOCK_TTL=3600 \
                GOLEM_WORKTREE_DIR=.worktrees \
                GOLEM_STATUS_DIR=.worktrees/.status \
                "$real_bash" "$GATE_WATCH" --once-liveness
    ) >"$tmp/out" 2>/dev/null && LIVE_RC=0 || LIVE_RC=$?
    LIVE_OUT="$(command cat "$tmp/out")"
}

# Liveness transcript wiring (#248): drive the TRANSCRIPT tier of
# liveness_snapshot() end to end. Like _run_liveness_snapshot (the mtime helper),
# the fake `tmux` answers `has-session` -> FAIL, so the pane branch is skipped
# entirely (this is exactly the headless golem the transcript tier targets) and
# the sweep reaches golem-transcript-liveness.sh. A transcript is planted under a
# fake CLAUDE_PROJECTS_DIR keyed to golem-7's worktree slug — the same
# `<abs-worktree>` with `/`+`.` -> `-` mapping golem-transcript-liveness.sh (and
# golem-token-scrape.sh) resolve — so the real subprocess reads it. The golem-7
# status file is still planted, so a MISSING transcript naturally falls through to
# the mtime heartbeat (the fall-through case). Args: $1 = stall threshold (sec),
# $2 = status-file age (sec ago), $3 = transcript body (newline-joined *.jsonl
# lines; EMPTY plants no transcript so the tier misses and mtime wins). Sets
# LIVE_RC / LIVE_OUT.
_run_liveness_snapshot_transcript() {
    local stall="$1" age_secs="$2" transcript="$3"
    local tmp
    tmp="$(command mktemp -d)" || return 1
    # shellcheck disable=SC2064
    trap "command rm -rf '$tmp'" RETURN

    local git_scrub=(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
        GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES)

    /usr/bin/env "${git_scrub[@]/#/--unset=}" \
        git -C "$tmp" init -q 2>/dev/null || return 1
    command mkdir -p "$tmp/.worktrees/.status"
    # golem-7 status cache is the mtime activity proxy (the fall-through target);
    # backdate its mtime so age = $age_secs deterministically.
    command printf '%s\n' '{"golem":"golem-7","issue":7,"phase":"impl"}' \
        >"$tmp/.worktrees/.status/golem-7.json"
    command touch -d "@$(($(command date +%s) - age_secs))" \
        "$tmp/.worktrees/.status/golem-7.json"

    # Plant the transcript under a fake CLAUDE_PROJECTS_DIR at the slug the real
    # subprocess will compute for golem-7's worktree ($tmp/.worktrees/issue-7,
    # already absolute → abs == worktree). Slug maps `/` and `.` to `-`, exactly as
    # the script does. An empty body plants nothing (missing-transcript case).
    local fake_projects wt slug
    fake_projects="$tmp/claude-projects"
    wt="$tmp/.worktrees/issue-7"
    slug="${wt//[\/.]/-}"
    if [ -n "$transcript" ]; then
        command mkdir -p "$fake_projects/$slug"
        command printf '%s\n' "$transcript" >"$fake_projects/$slug/session.jsonl"
    fi

    # Hermetic PATH: real bash + git + jq symlinks (the transcript script needs
    # jq), plus a fake tmux whose `ls` prints nothing and `has-session` FAILS so
    # the pane branch is skipped and the sweep reaches the transcript tier.
    local stub_bin real_bash real_git real_jq
    stub_bin="$tmp/stub-bin"
    command mkdir -p "$stub_bin"
    real_bash="$(command -v bash)"
    real_git="$(command -v git)"
    command ln -s "$real_bash" "$stub_bin/bash"
    command ln -s "$real_git" "$stub_bin/git"
    real_jq="$(command -v jq || true)"
    [ -n "$real_jq" ] && command ln -s "$real_jq" "$stub_bin/jq"
    command cat >"$stub_bin/tmux" <<'TMUX_STUB'
#!/usr/bin/env bash
case "$1" in
    ls) exit 0 ;;
    has-session) exit 1 ;;
    capture-pane) exit 0 ;;
    *) exit 0 ;;
esac
TMUX_STUB
    command chmod +x "$stub_bin/tmux"

    # --unset=BASH_ENV as in the sibling helpers. CLAUDE_PROJECTS_DIR points the
    # transcript script at the planted fixture.
    LIVE_RC=0
    (
        cd "$tmp" &&
            /usr/bin/env "${git_scrub[@]/#/--unset=}" --unset=BASH_ENV \
                PATH="$stub_bin" \
                CLAUDE_PROJECTS_DIR="$fake_projects" \
                GOLEM_STALL_THRESHOLD="$stall" GOLEM_BLOCK_TTL=3600 \
                GOLEM_WORKTREE_DIR=.worktrees \
                GOLEM_STATUS_DIR=.worktrees/.status \
                "$real_bash" "$GATE_WATCH" --once-liveness
    ) >"$tmp/out" 2>/dev/null && LIVE_RC=0 || LIVE_RC=$?
    LIVE_OUT="$(command cat "$tmp/out")"
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
    # assert_not_contains is glob-based (no eval), so attacker-influenceable
    # $SNAP_OUT never reaches an eval'd command.
    assert_not_contains "$SNAP_OUT" "golem-old" "Stale dated gate ages out of the TTL window"
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

# Escalation (#176): a mid-flight `escalation` event surfaces in the BLOCKED feed
# set alongside `gate`/`blocked`, is labelled distinctly ("escalation — …") so a
# judgement call is not lost among routine permission gates, while an `idle` in
# the same feed is still excluded. Guards the three-way select and the jq label
# branch together.
test_escalation_surfaces_labelled() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (feed_snapshot no-ops without jq)"
        return 0
    fi

    _run_once_snapshot 999999999999 \
        '{"golem":"golem-esc","event":"escalation","message":"ESCALATION: reuse state file or sidecar?","ts":"2026-06-27T10:00:00Z"}' \
        '{"golem":"golem-gate","event":"gate","message":"push gate","ts":"2026-06-27T10:00:00Z"}' \
        '{"golem":"golem-idle","event":"idle","message":"Claude is waiting for your input","ts":"2026-06-27T10:00:00Z"}'

    assert_equals "0" "$SNAP_RC" "Snapshot exits 0 with an escalation line"
    assert_contains "$SNAP_OUT" "golem-esc" "Escalation golem surfaces in the BLOCKED set"
    assert_contains "$SNAP_OUT" "escalation — ESCALATION: reuse state file or sidecar?" \
        "Escalation is labelled distinctly (escalation — …)"
    assert_contains "$SNAP_OUT" "golem-gate" "A routine gate still surfaces alongside the escalation"
    # The gate line must NOT carry the escalation label.
    assert_not_contains "$SNAP_OUT" "escalation — push gate" \
        "A routine gate is not mislabelled as an escalation"
    assert_not_contains "$SNAP_OUT" "golem-idle" "An idle in the same feed is still excluded"
}

# Resolve-then-sweep (#422): the compliant plan-approval broker resolves a plan
# gate with `tmux send-keys 1 Enter`, which fires no Notification — so without an
# explicit clearing line the golem's `gate` stays the most-recent feed line and
# renders BLOCKED for the whole TTL. golem-resolve.sh closes this by emitting a
# `resolved` line; like `idle`, `resolved` is NOT in the BLOCKED set, so once it
# is the golem's most-recent line `group_by | map(.[-1])` drops the golem from
# the snapshot. This pins acceptance criterion 3: gate followed by a later
# `resolved` for the same golem ⇒ not BLOCKED, while a still-gated golem in the
# same feed still surfaces (so the clearing is targeted, not a blanket drop).
test_resolved_supersedes_gate() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (feed_snapshot no-ops without jq)"
        return 0
    fi

    _run_once_snapshot 999999999999 \
        '{"golem":"golem-5","event":"gate","message":"plan gate","ts":"2026-06-27T10:00:00Z"}' \
        '{"golem":"golem-5","event":"resolved","message":"RESOLVED: plan gate approved via send-keys","ts":"2026-06-27T10:01:00Z"}' \
        '{"golem":"golem-6","event":"gate","message":"push gate","ts":"2026-06-27T10:00:00Z"}'

    assert_equals "0" "$SNAP_RC" "Snapshot exits 0 with a resolved line"
    assert_not_contains "$SNAP_OUT" "golem-5" \
        "A gate superseded by a later resolved line drops out of BLOCKED (#422)"
    assert_contains "$SNAP_OUT" "golem-6" \
        "A still-gated golem in the same feed still surfaces (resolve is targeted)"
}

# Orphan sentinel (#323): golem-notify.sh stamps a feed line `golem-?` when the
# Notification fires from a session with no GOLEM_ID that is not in a worktree
# root. No real golem carries that id, so no future `idle` ever supersedes it and
# (being no-`ts`) it bypasses the TTL — a permanent phantom BLOCKED entry. It is
# never actionable (`golem-?` has no golem-attach target), so feed_snapshot()
# must drop it while a REAL gate in the same feed still surfaces. Both branches
# asserted together so a refactor dropping the sentinel filter is caught.
test_golem_question_sentinel_excluded() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (feed_snapshot no-ops without jq)"
        return 0
    fi

    _run_once_snapshot 999999999999 \
        '{"golem":"golem-?","event":"gate","message":"Claude needs your permission"}' \
        '{"golem":"golem-1","event":"gate","message":"push gate","ts":"2026-06-27T10:00:00Z"}'

    assert_equals "0" "$SNAP_RC" "Snapshot exits 0 with an orphan golem-? line"
    assert_not_empty "$SNAP_OUT" "Snapshot is non-empty (the real gate must still surface)"
    assert_contains "$SNAP_OUT" "golem-1" "A real gate still surfaces alongside the orphan sentinel"
    # assert_not_contains is glob-based (no eval), so attacker-influenceable
    # $SNAP_OUT never reaches an eval'd command.
    assert_not_contains "$SNAP_OUT" "golem-?" "The orphan golem-? sentinel is filtered out"
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
# positive heartbeat — "alive (process up ...)", exit 0, never a stall. The
# wording is "process up", not "advancing" (#229): with no live tmux pane the
# sweep falls through to the mtime heartbeat, which proves only that the process
# is up, not that work is happening.
test_liveness_fresh_is_alive() {
    # age 0 (now), generous threshold -> alive.
    _run_liveness_snapshot 1200 0

    assert_equals "0" "$LIVE_RC" "Liveness snapshot exits 0 for a fresh golem"
    assert_contains "$LIVE_OUT" "golem-7" "Fresh golem appears in the liveness sweep"
    assert_contains "$LIVE_OUT" "alive" "Fresh golem is reported alive"
    # #229: the mtime heartbeat must NOT be worded "advancing" (reads as progress
    # when it only proves the process is up); it is "process up" instead. The
    # test env has no golem-7 tmux session, so the pane check falls through to
    # this reworded mtime heartbeat.
    assert_contains "$LIVE_OUT" "process up" "Fresh golem heartbeat is worded 'process up', not 'advancing'"
    assert_not_contains "$LIVE_OUT" "advancing" "The misleading 'advancing' wording is gone (#229)"
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
        "{\"golem\":\"golem-7\",\"event\":\"gate\",\"message\":\"push gate\",\"ts\":\"$(command date -u +%Y-%m-%dT%H:%M:%SZ)\"}"

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

# --- Liveness pane wiring (#229/#247) ---------------------------------------
# The three tests below drive the tmux-pane branch of liveness_snapshot() END TO
# END via the real `--once-liveness`, with `tmux` stubbed on PATH answering
# has-session + capture-pane. They cover the `case "$pclass"` dispatch added in
# PR #245, its exact emitted strings, and the pane-read-vs-mtime precedence —
# the wiring test_pane_liveness_class (classifier-only, sourced in isolation)
# never reaches. `last activity` is the precedence discriminator: it appears
# ONLY in the mtime-fallback string `alive (process up, last activity … ago)`,
# so its presence/absence proves whether the pane branch or the mtime heartbeat
# produced the line (both share the weaker substring `process up`).

# A scrapeable pane showing the run-spinner classifies `working`: the wiring must
# emit `alive, working` (not the mtime heartbeat). Its absence of `last activity`
# proves the pane read won over the mtime fallback — even though the golem-7
# status file is fresh and would ALSO produce an "alive" mtime line.
test_liveness_pane_working_wiring() {
    _run_liveness_snapshot_tmux 1200 0 "... some output ... ⏵⏵ esc to interrupt"

    assert_equals "0" "$LIVE_RC" "Liveness snapshot exits 0 for a working pane"
    assert_contains "$LIVE_OUT" "golem-7" "The golem appears in the liveness sweep"
    assert_contains "$LIVE_OUT" "alive, working" \
        "A run-spinner pane emits the 'alive, working' wiring string, not the mtime heartbeat"
    assert_not_contains "$LIVE_OUT" "last activity" \
        "The pane read wins over the mtime fallback (no 'last activity' heartbeat wording)"
}

# A scrapeable pane showing the #229 error signature classifies `idle`: the
# wiring must emit the `idle at prompt` warning. Again `last activity` must be
# absent — the pane branch short-circuits before the mtime heartbeat.
test_liveness_pane_idle_wiring() {
    _run_liveness_snapshot_tmux 1200 0 "⏺ Unknown command: /next-issue"

    assert_equals "0" "$LIVE_RC" "Liveness snapshot exits 0 for an idle pane"
    assert_contains "$LIVE_OUT" "golem-7" "The golem appears in the liveness sweep"
    assert_contains "$LIVE_OUT" "idle at prompt" \
        "An idle-at-prompt pane (#229 signature) emits the 'idle at prompt' warning"
    assert_not_contains "$LIVE_OUT" "last activity" \
        "The pane read wins over the mtime fallback (no 'last activity' heartbeat wording)"
}

# A scrapeable pane showing the #446 API-error death signature classifies `died`:
# the liveness wiring must emit the DIED label (with its retriable/terminal class),
# NOT the plain `idle at prompt` — and `last activity` must be absent (the pane
# branch short-circuits before the mtime heartbeat). Pins the `died)` dispatch arm
# in liveness_snapshot() end-to-end (the pull `--once-liveness` surface, distinct
# from the push panes_snapshot path).
test_liveness_pane_died_wiring() {
    _run_liveness_snapshot_tmux 1200 0 "API Error: Request rejected (429)"$'\n'"  ⏵⏵ auto mode on"

    assert_equals "0" "$LIVE_RC" "Liveness snapshot exits 0 for a died pane"
    assert_contains "$LIVE_OUT" "golem-7" "The golem appears in the liveness sweep"
    assert_contains "$LIVE_OUT" "died — API error: retriable (429)" \
        "A died-on-429 pane emits the DIED label with its class through --once-liveness (#446)"
    assert_not_contains "$LIVE_OUT" "idle at prompt" \
        "A died pane is NOT downgraded to the plain idle-at-prompt liveness wording"
    assert_not_contains "$LIVE_OUT" "last activity" \
        "The pane read wins over the mtime fallback (no 'last activity' heartbeat wording)"
}

# Precedence: when the pane is scrapeable but classifies indeterminate (empty
# class), the wiring must FALL THROUGH to the mtime heartbeat. With a fresh
# status file that yields `alive (process up, last activity … ago)` — the
# `last activity` wording proves the fallback ran (the pane case emitted nothing
# and did not short-circuit).
test_liveness_pane_indeterminate_falls_through() {
    _run_liveness_snapshot_tmux 1200 0 "just some scrolling build output"

    assert_equals "0" "$LIVE_RC" "Liveness snapshot exits 0 for an indeterminate pane"
    assert_contains "$LIVE_OUT" "golem-7" "The golem appears in the liveness sweep"
    assert_contains "$LIVE_OUT" "last activity" \
        "An indeterminate pane falls through to the mtime heartbeat (pane-read -> mtime precedence)"
    assert_not_contains "$LIVE_OUT" "alive, working" \
        "An indeterminate pane does not fabricate a 'working' verdict"
}

# Distinct precedence path from the indeterminate case above: a session that
# EXISTS (has-session succeeds) but whose capture-pane comes back EMPTY. The
# script's own header flags this ("capture-pane is blank until the pane paints")
# — the `[ -n "$pane" ]` guard is false, so pane_liveness_class() is never called
# at all and the sweep falls straight through to the mtime heartbeat. The
# indeterminate test DOES reach the classifier (non-empty pane, empty class); this
# one exercises the guard itself. An empty $pane_text makes the fake tmux
# capture-pane print a lone newline, which command substitution strips to "".
test_liveness_pane_blank_capture_falls_through() {
    _run_liveness_snapshot_tmux 1200 0 ""

    assert_equals "0" "$LIVE_RC" "Liveness snapshot exits 0 for a blank capture-pane"
    assert_contains "$LIVE_OUT" "golem-7" "The golem appears in the liveness sweep"
    assert_contains "$LIVE_OUT" "last activity" \
        "A blank capture-pane (guard false) falls through to the mtime heartbeat"
    assert_not_contains "$LIVE_OUT" "alive, working" \
        "A blank capture-pane does not fabricate a 'working' verdict"
    assert_not_contains "$LIVE_OUT" "idle at prompt" \
        "A blank capture-pane does not fabricate an 'idle' verdict"
}

# --- Transcript tier wiring (#248) ------------------------------------------
# The tests below drive the TRANSCRIPT tier of liveness_snapshot() end to end via
# the real `--once-liveness`: no host-visible pane (fake tmux has-session FAILS),
# so the sweep skips the pane branch — exactly the headless golem this tier
# targets — and reads the golem's on-disk transcript instead. They cover the
# `case "$tclass"` dispatch, its emitted strings, and the transcript-vs-mtime
# precedence (the `last activity` wording marks the mtime fallback, absent when
# the transcript tier classifies). All skip when jq is absent — the transcript
# script (and thus the tier) is a no-op without it, exactly like the feed tests.

# A transcript whose last top-level assistant turn is still in flight
# (stop_reason "tool_use") classifies `working`: the wiring emits `alive, working`
# from the transcript, winning over the fresh-status-file mtime heartbeat.
test_liveness_transcript_working_wiring() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript tier no-ops without jq)"
        return 0
    fi
    _run_liveness_snapshot_transcript 1200 0 \
        '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use"}]}}'

    assert_equals "0" "$LIVE_RC" "Liveness snapshot exits 0 for a working transcript"
    assert_contains "$LIVE_OUT" "golem-7" "The golem appears in the liveness sweep"
    assert_contains "$LIVE_OUT" "alive, working" \
        "A turn-in-flight transcript emits the 'alive, working' wiring string"
    assert_contains "$LIVE_OUT" "transcript" \
        "The working line attributes the transcript source"
    assert_not_contains "$LIVE_OUT" "last activity" \
        "The transcript read wins over the mtime fallback (no 'last activity' wording)"
}

# A transcript whose last top-level assistant turn has ENDED (stop_reason
# "end_turn") classifies `idle`: the wiring emits the `idle at prompt` warning.
# This is the headless analog of the #229 pane idle signal — the whole point of
# #248. `last activity` must be absent (transcript short-circuits before mtime).
test_liveness_transcript_idle_wiring() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript tier no-ops without jq)"
        return 0
    fi
    _run_liveness_snapshot_transcript 1200 0 \
        '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"done"}]}}'

    assert_equals "0" "$LIVE_RC" "Liveness snapshot exits 0 for an idle transcript"
    assert_contains "$LIVE_OUT" "golem-7" "The golem appears in the liveness sweep"
    assert_contains "$LIVE_OUT" "idle at prompt" \
        "A turn-ended transcript emits the 'idle at prompt' warning (headless #229 analog)"
    assert_not_contains "$LIVE_OUT" "last activity" \
        "The transcript read wins over the mtime fallback (no 'last activity' wording)"
}

# The errored subclass: the last top-level assistant record carries
# isApiErrorMessage. The wiring emits an idle-at-prompt warning that names the
# error ("errored and idle") — the literal #229 first-command-failure case, now
# caught for a headless golem.
test_liveness_transcript_errored_wiring() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript tier no-ops without jq)"
        return 0
    fi
    _run_liveness_snapshot_transcript 1200 0 \
        '{"type":"assistant","isSidechain":false,"isApiErrorMessage":true,"message":{"role":"assistant","stop_reason":"stop_sequence","content":[{"type":"text","text":"API Error: 429"}]}}'

    assert_equals "0" "$LIVE_RC" "Liveness snapshot exits 0 for an errored transcript"
    assert_contains "$LIVE_OUT" "golem-7" "The golem appears in the liveness sweep"
    assert_contains "$LIVE_OUT" "idle at prompt" \
        "An errored transcript still surfaces as idle at prompt"
    assert_contains "$LIVE_OUT" "errored and idle" \
        "The errored subclass is named distinctly in the liveness line"
}

# A sub-workflow (isSidechain true) churning tool_use records must NOT mask a
# top-level idle: the classifier keys off top-level records only, so a golem whose
# background review harness is active while the TOP level ended still reads idle.
# Guards the isSidechain filter through the full wiring, not just the unit script.
test_liveness_transcript_sidechain_not_masking() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript tier no-ops without jq)"
        return 0
    fi
    _run_liveness_snapshot_transcript 1200 0 \
        "$(command printf '%s\n%s' \
            '{"type":"assistant","isSidechain":false,"message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"done"}]}}' \
            '{"type":"assistant","isSidechain":true,"message":{"role":"assistant","stop_reason":"tool_use","content":[{"type":"tool_use"}]}}')"

    assert_equals "0" "$LIVE_RC" "Liveness snapshot exits 0 with sidechain churn"
    assert_contains "$LIVE_OUT" "idle at prompt" \
        "A top-level idle is not masked by an active sub-workflow (isSidechain filter)"
    assert_not_contains "$LIVE_OUT" "alive, working" \
        "Sidechain tool_use does not fabricate a top-level 'working' verdict"
}

# Precedence / fall-through: with NO transcript planted (empty body), the
# transcript tier exits non-zero (no transcript dir) and the sweep falls through
# to the mtime heartbeat — the `last activity` wording proves the fallback ran.
# This is the Mode-3-container / no-host-transcript path.
test_liveness_transcript_missing_falls_through() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript tier no-ops without jq)"
        return 0
    fi
    _run_liveness_snapshot_transcript 1200 0 ""

    assert_equals "0" "$LIVE_RC" "Liveness snapshot exits 0 with no transcript"
    assert_contains "$LIVE_OUT" "golem-7" "The golem appears in the liveness sweep"
    assert_contains "$LIVE_OUT" "last activity" \
        "A missing transcript falls through to the mtime heartbeat (transcript -> mtime precedence)"
    assert_not_contains "$LIVE_OUT" "alive, working" \
        "A missing transcript does not fabricate a 'working' verdict"
}

# An indeterminate transcript (records present but no top-level assistant turn and
# no command error) must also fall through to the mtime heartbeat, not fabricate a
# verdict — the script exits 2 (indeterminate) and the caller falls back.
test_liveness_transcript_indeterminate_falls_through() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (transcript tier no-ops without jq)"
        return 0
    fi
    _run_liveness_snapshot_transcript 1200 0 \
        '{"type":"user","message":{"role":"user","content":"hi"}}'

    assert_equals "0" "$LIVE_RC" "Liveness snapshot exits 0 for an indeterminate transcript"
    assert_contains "$LIVE_OUT" "last activity" \
        "An indeterminate transcript falls through to the mtime heartbeat"
    assert_not_contains "$LIVE_OUT" "idle at prompt" \
        "An indeterminate transcript does not fabricate an idle verdict"
}

# --- Helper / mode coverage (#82) -------------------------------------------
# The tests below exercise the previously-untested surface: the unknown-mode
# error path, the _fmt_age formatter, the two pane-overlay matchers, and the
# emit_transitions dedup logic. The pure functions are reached by SOURCING the
# script (its bottom main-guard means a source defines functions without running
# the drive block) in a subshell, so the script's `set -uo pipefail` never leaks
# into the harness.

# Unknown mode: an unrecognized argument must exit 2 with a usage message naming
# the valid modes — the only non-zero exit the script makes (snapshots always
# exit 0). Run as a SUBPROCESS (not sourced) so the `exit 2` is observed as a
# real exit code.
test_unknown_mode_exits_2() {
    local out rc=0
    out="$(bash "$GATE_WATCH" --bogus-mode 2>&1)" && rc=0 || rc=$?
    assert_equals "2" "$rc" "Unknown mode exits 2"
    assert_contains "$out" "unknown mode" "Usage message names the unknown mode"
    assert_contains "$out" "--once" "Usage message lists the valid modes"
}

# An empty/no argument defaults to --once (mode="--once") and must NOT hit the
# unknown-mode arm — exit 0, and no "unknown mode" complaint.
test_no_arg_defaults_to_once() {
    local out rc=0
    # Run from a tmpdir with no git repo context; --once resolves no feed and
    # exits 0 cleanly (status_dir empty -> the [ -n "$feed" ] guard skips).
    out="$(cd "$(command mktemp -d)" && bash "$GATE_WATCH" 2>&1)" && rc=0 || rc=$?
    assert_equals "0" "$rc" "No argument defaults to --once and exits 0"
    assert_not_contains "$out" "unknown mode" "Default mode does not hit the error path"
}

# _fmt_age: < 60 seconds renders "Ns"; >= 60 renders whole "Nm" (integer minutes,
# truncating). Covers the boundary (59/60), a multi-minute value, and zero.
test_fmt_age_formats() {
    local r
    r="$( (
        source "$GATE_WATCH"
        _fmt_age 0
    ))"
    assert_equals "0s" "$r" "_fmt_age 0 -> 0s"
    r="$( (
        source "$GATE_WATCH"
        _fmt_age 59
    ))"
    assert_equals "59s" "$r" "_fmt_age 59 -> 59s (just under the minute)"
    r="$( (
        source "$GATE_WATCH"
        _fmt_age 60
    ))"
    assert_equals "1m" "$r" "_fmt_age 60 -> 1m (the boundary)"
    r="$( (
        source "$GATE_WATCH"
        _fmt_age 125
    ))"
    assert_equals "2m" "$r" "_fmt_age 125 -> 2m (integer-minute truncation)"
}

# pane_is_plan_gate: each plan-overlay phrase matches (rc 0); unrelated text does
# not (rc 1). The phrases come straight from the matcher's case arms.
test_pane_is_plan_gate() {
    assert_equals "0" "$(_pane_rc pane_is_plan_gate "... Ready to code? ...")" \
        "'Ready to code' is a plan gate"
    assert_equals "0" "$(_pane_rc pane_is_plan_gate "Here is Claude's plan:")" \
        "'Here is Claude's plan' is a plan gate"
    assert_equals "0" "$(_pane_rc pane_is_plan_gate "Would you like to proceed?")" \
        "'Would you like to proceed' is a plan gate"
    assert_equals "0" "$(_pane_rc pane_is_plan_gate "1. Yes, and use auto mode")" \
        "'Yes, and use auto mode' is a plan gate"
    assert_equals "1" "$(_pane_rc pane_is_plan_gate "just some scrolling build output")" \
        "Unrelated work output is NOT a plan gate"

    # Footer anchoring (#452, mirroring test_pane_is_fork_footer_anchored / the
    # #246 pane_liveness_class fix): the matcher scans only the last GOLEM_PANE_
    # FOOTER_LINES lines (default 8), NOT the whole scrollback. A golem
    # editing/`cat`-ing a file whose text carries a plan phrase — this script's
    # own comments and tests do — must not self-trip a false plan gate. `filler`
    # pushes the scrolled phrase out of the footer window.
    local filler
    filler=$'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10'
    assert_equals "1" \
        "$(_pane_rc pane_is_plan_gate "grep 'Here is Claude'\''s plan' golem-gate-watch.sh"$'\n'"$filler"$'\n'"  ⏵⏵ esc to interrupt")" \
        "A scrolled plan phrase above a working footer does not fake a plan gate"
    assert_equals "0" \
        "$(_pane_rc pane_is_plan_gate "$filler"$'\n'"Here is Claude's plan:")" \
        "A plan phrase inside the footer window still matches"

    # Tail-window boundary (#459): pin the exact inclusive/exclusive edge of the
    # default 8-line footer window, where `tail -n 8 <<<` over a here-string
    # (trailing newline) makes an off-by-one easy to regress silently. Phrase +
    # 7 filler = 8 lines -> phrase sits at the Nth-from-last line, inside the
    # window (rc 0); phrase + 8 filler = 9 lines -> (N+1)th-from-last, outside
    # (rc 1).
    local edge_in edge_out
    edge_in=$'f1\nf2\nf3\nf4\nf5\nf6\nf7'
    edge_out=$'f1\nf2\nf3\nf4\nf5\nf6\nf7\nf8'
    assert_equals "0" \
        "$(_pane_rc pane_is_plan_gate "Here is Claude's plan:"$'\n'"$edge_in")" \
        "A plan phrase at the Nth-from-last line is inside the footer window"
    assert_equals "1" \
        "$(_pane_rc pane_is_plan_gate "Here is Claude's plan:"$'\n'"$edge_out")" \
        "A plan phrase at the (N+1)th-from-last line is outside the footer window"
}

# pane_liveness_class (#229): source the script (main-guard makes it sourceable)
# in a subshell and echo the class the classifier prints for a pane sample.
_pane_class() {
    local text="$1"
    (
        source "$GATE_WATCH"
        pane_liveness_class "$text"
    ) 2>/dev/null
}

# pane_liveness_class (#229): the run-spinner marks "working"; the #229 error
# signature and a bare auto-mode footer mark "idle"; the spinner WINS over the
# footer (a working golem still paints the footer); unrelated text is "".
test_pane_liveness_class() {
    assert_equals "working" "$(_pane_class "... ⏵⏵ esc to interrupt")" \
        "'esc to interrupt' spinner marks the pane working"
    assert_equals "idle" "$(_pane_class "⏺ Unknown command: /next-issue")" \
        "The #229 'Unknown command' failure marks the pane idle"
    assert_equals "idle" "$(_pane_class "❯"$'\n'"  ⏵⏵ auto mode on")" \
        "A bare 'auto mode on' footer (no spinner) marks the pane idle"
    # Spinner precedence: both the working spinner AND the auto-mode footer on
    # screen must resolve to working, not idle (a working auto-mode golem shows
    # both). Guards the check order in the classifier.
    assert_equals "working" "$(_pane_class "esc to interrupt"$'\n'"  ⏵⏵ auto mode on")" \
        "The spinner wins over the auto-mode footer -> working"
    assert_equals "" "$(_pane_class "just some scrolling build output")" \
        "Unrelated pane text is indeterminate (empty class)"
    # #446 death read: an API-error scrollback with a bare footer classifies as
    # `died` (checked before the plain idle arms so it is not masked as idle); the
    # same error under an active spinner is `working` (spinner wins).
    assert_equals "died" "$(_pane_class "API Error: Request rejected (429)"$'\n'"  ⏵⏵ auto mode on")" \
        "An API-error scrollback with no spinner classifies as died, not idle (#446)"
    assert_equals "working" "$(_pane_class "API Error: 429"$'\n'"  ⏵⏵ esc to interrupt")" \
        "The same API-error under an active spinner is working (spinner wins over death)"

    # Footer anchoring (#246): the match is scoped to the last GOLEM_PANE_FOOTER_
    # LINES lines (default 8), NOT the whole scrollback. A golem cat-ing/grepping
    # a file whose text carries a trigger phrase (this very script does) must not
    # self-trip the classifier. `filler` pushes the scrolled phrase out of the
    # footer window.
    local filler
    filler=$'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10'
    # (a) Fail-loud collision: `esc to interrupt` in SCROLLBACK above a real idle
    # footer -> idle (not a false working). The spinner phrase is > 8 lines up.
    assert_equals "idle" \
        "$(_pane_class "grep esc to interrupt golem-gate-watch.sh"$'\n'"$filler"$'\n'"  ⏵⏵ auto mode on")" \
        "A scrolled 'esc to interrupt' above an idle footer does not fake 'working'"
    # (b) Fail-open collision: `auto mode on` / `Unknown command` in SCROLLBACK
    # above a real run-spinner footer -> working (not a false idle that would
    # suppress #229 detection).
    assert_equals "working" \
        "$(_pane_class "cat golem-launch.sh # auto mode on / Unknown command"$'\n'"$filler"$'\n'"  ⏵⏵ esc to interrupt")" \
        "Scrolled idle phrases above a live spinner do not fake 'idle'"
    # (c) The idle footer requires its `⏵⏵` chrome glyph: a bare-words 'auto mode
    # on' line with no glyph, even inside the footer window, stays indeterminate.
    assert_equals "" "$(_pane_class "the docs mention auto mode on here")" \
        "A bare-words 'auto mode on' with no chrome glyph is indeterminate"
}

# pane_is_gate: the generic permission-decision overlay matches (rc 0); other
# text does not (rc 1). Distinct from the plan-gate matcher.
test_pane_is_gate() {
    assert_equals "0" "$(_pane_rc pane_is_gate "Do you want to proceed?")" \
        "'Do you want to proceed' is a permission gate"
    assert_equals "1" "$(_pane_rc pane_is_gate "Here is Claude's plan:")" \
        "A plan overlay is NOT matched by the generic-gate matcher"
    assert_equals "1" "$(_pane_rc pane_is_gate "nothing to see")" \
        "Unrelated text is NOT a permission gate"

    # Footer anchoring (#452): scoped to the last GOLEM_PANE_FOOTER_LINES lines,
    # NOT the whole scrollback — a golem editing/`cat`-ing a file that mentions
    # `Do you want to proceed` must not self-trip a false permission gate.
    local filler
    filler=$'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10'
    assert_equals "1" \
        "$(_pane_rc pane_is_gate "echo 'Do you want to proceed' >> fixtures.txt"$'\n'"$filler"$'\n'"  ⏵⏵ esc to interrupt")" \
        "A scrolled 'Do you want to proceed' above a working footer does not fake a gate"
    assert_equals "0" \
        "$(_pane_rc pane_is_gate "$filler"$'\n'"Do you want to proceed?")" \
        "A 'Do you want to proceed' inside the footer window still matches"

    # Tail-window boundary (#459): pin the exact inclusive/exclusive edge of the
    # default 8-line footer window (see test_pane_is_plan_gate for the rationale).
    # Phrase + 7 filler = 8 lines -> Nth-from-last, inside (rc 0); phrase + 8
    # filler = 9 lines -> (N+1)th-from-last, outside (rc 1).
    local edge_in edge_out
    edge_in=$'f1\nf2\nf3\nf4\nf5\nf6\nf7'
    edge_out=$'f1\nf2\nf3\nf4\nf5\nf6\nf7\nf8'
    assert_equals "0" \
        "$(_pane_rc pane_is_gate "Do you want to proceed?"$'\n'"$edge_in")" \
        "A permission phrase at the Nth-from-last line is inside the footer window"
    assert_equals "1" \
        "$(_pane_rc pane_is_gate "Do you want to proceed?"$'\n'"$edge_out")" \
        "A permission phrase at the (N+1)th-from-last line is outside the footer window"
}

# pane_is_fork (#257): the AskUserQuestion escalation-fork overlay matches on its
# `Enter to select` footer (rc 0); a plan overlay, the generic-gate phrase, and
# unrelated work output do NOT (rc 1). This is the whole gate category the pane
# channel silently dropped before #257.
test_pane_is_fork() {
    assert_equals "0" "$(_pane_rc pane_is_fork "Enter to select · ↑/↓ to navigate · Esc to cancel")" \
        "The 'Enter to select' fork footer is an escalation fork"
    assert_equals "1" "$(_pane_rc pane_is_fork "Do you want to proceed?")" \
        "A generic permission gate footer alone is NOT a fork"
    assert_equals "1" "$(_pane_rc pane_is_fork "Here is Claude's plan:")" \
        "A plan overlay is NOT a fork"
    assert_equals "1" "$(_pane_rc pane_is_fork "just some scrolling build output")" \
        "Unrelated work output is NOT a fork"
}

# Footer anchoring (#257, mirroring the #246 pane_liveness_class fix): pane_is_fork
# scans only the last GOLEM_PANE_FOOTER_LINES lines, NOT the whole scrollback. A
# golem cat-ing/grepping a file whose text carries `Enter to select` — this very
# test file and golem-gate-watch.sh's own comments do — must not self-trip the
# matcher into a false escalation. `filler` pushes the scrolled phrase out of the
# footer window (default 8 lines).
test_pane_is_fork_footer_anchored() {
    local filler
    filler=$'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10'
    assert_equals "1" \
        "$(_pane_rc pane_is_fork "grep 'Enter to select' golem-gate-watch.sh"$'\n'"$filler"$'\n'"  ⏵⏵ esc to interrupt")" \
        "A scrolled 'Enter to select' above a non-fork footer does not fake a fork"
    assert_equals "0" \
        "$(_pane_rc pane_is_fork "$filler"$'\n'"Enter to select · ↑/↓ to navigate")" \
        "An 'Enter to select' footer inside the window still matches"
}

# Precedence (#257): a pane carrying BOTH a plan signature (`Yes, and use auto
# mode`) AND the fork footer (`Enter to select`) must still be a plan gate —
# panes_snapshot checks pane_is_plan_gate FIRST, so a real plan overlay is never
# downgraded to a fork. Pins that branch order at the matcher level. (The
# end-to-end dispatch order is pinned by test_panes_snapshot_dispatch below.)
test_pane_fork_plan_precedence() {
    local both="1. Yes, and use auto mode"$'\n'"Enter to select · ↑/↓ to navigate"
    assert_equals "0" "$(_pane_rc pane_is_plan_gate "$both")" \
        "A plan+fork pane is matched by pane_is_plan_gate (plan gate wins)"
    assert_equals "0" "$(_pane_rc pane_is_fork "$both")" \
        "pane_is_fork also matches it, but panes_snapshot checks plan-gate first"
}

# End-to-end pane dispatch (#257): drive the REAL panes_snapshot() through a
# `--once-panes` invocation with a stubbed tmux on PATH, so the actual if/elif
# ORDER (plan-gate -> generic gate -> fork) and the exact emitted label strings
# are pinned — not just the isolated matcher functions (the tests above). Mirrors
# _run_liveness_snapshot_tmux. The fake tmux reports one live golem-9 session and
# returns $FAKE_PANE_TEXT for capture-pane. Sets PANES_OUT / PANES_RC.
_run_panes_snapshot_tmux() {
    local pane_text="$1"
    local tmp stub_bin real_bash
    tmp="$(command mktemp -d)" || return 1
    # shellcheck disable=SC2064
    trap "command rm -rf '$tmp'" RETURN
    stub_bin="$tmp/stub-bin"
    command mkdir -p "$stub_bin"
    real_bash="$(command -v bash)"
    command ln -s "$real_bash" "$stub_bin/bash"
    # Fake tmux: `ls` -> one live golem session; `capture-pane` -> the canned
    # pane text; anything else -> success no-op. Kept bash-3.2 clean.
    command cat >"$stub_bin/tmux" <<'TMUX_STUB'
#!/usr/bin/env bash
case "$1" in
    ls) command printf '%s\n' "golem-9: 1 windows" ;;
    capture-pane) command printf '%s\n' "${FAKE_PANE_TEXT:-}" ;;
    *) exit 0 ;;
esac
TMUX_STUB
    command chmod +x "$stub_bin/tmux"
    # --unset=BASH_ENV: the devcontainer's /etc/bash_env resets $PATH for every
    # non-interactive bash, which would undo the hermetic PATH.
    PANES_RC=0
    (
        cd "$tmp" &&
            /usr/bin/env --unset=BASH_ENV PATH="$stub_bin" \
                FAKE_PANE_TEXT="$pane_text" \
                "$real_bash" "$GATE_WATCH" --once-panes
    ) >"$tmp/out" 2>/dev/null && PANES_RC=0 || PANES_RC=$?
    PANES_OUT="$(command cat "$tmp/out")"
}

PANES_OUT=""
PANES_RC=""

# panes_snapshot dispatch (#257): a fork-only pane emits the escalation label; a
# plan+fork pane still emits the plan label (plan-gate wins); a gate+fork pane
# emits the permission-gate label (generic gate wins over fork). Pins the whole
# if/elif chain and the exact output strings end-to-end.
test_panes_snapshot_dispatch() {
    _run_panes_snapshot_tmux "What scope? "$'\n'"Enter to select · ↑/↓ to navigate · Esc to cancel"
    assert_equals "0" "$PANES_RC" "panes_snapshot exits 0 for a fork pane"
    assert_contains "$PANES_OUT" "golem-9"$'\t'"escalation — awaiting decision (carries options)" \
        "A fork-only pane emits the escalation label end-to-end"

    _run_panes_snapshot_tmux "1. Yes, and use auto mode"$'\n'"Enter to select · ↑/↓ to navigate"
    assert_contains "$PANES_OUT" "golem-9"$'\t'"plan gate — ExitPlanMode awaiting approval" \
        "A plan+fork pane emits the plan-gate label (plan wins over fork)"
    assert_not_contains "$PANES_OUT" "escalation —" \
        "A plan+fork pane is NOT labelled an escalation"

    _run_panes_snapshot_tmux "Do you want to proceed?"$'\n'"Enter to select · ↑/↓ to navigate"
    assert_contains "$PANES_OUT" "golem-9"$'\t'"permission gate — awaiting decision" \
        "A gate+fork pane emits the permission-gate label (generic gate wins over fork)"
    assert_not_contains "$PANES_OUT" "escalation —" \
        "A routine permission gate is NOT downgraded to an escalation"

    # No-match pane: ordinary work output matches none of the four matchers ->
    # panes_snapshot emits NOTHING (no golem line). Pins the silent fall-through
    # end-to-end so an errant unconditional emit branch would be caught. The
    # footer here is a bare-words 'auto mode on' WITHOUT the ⏵⏵ glyph, so it also
    # pins that pane_is_turn_end's glyph guard holds in the dispatch chain.
    _run_panes_snapshot_tmux "just some scrolling build output"$'\n'"auto mode on but no glyph"
    assert_not_contains "$PANES_OUT" "golem-9" \
        "A pane matching no overlay emits no line (silent fall-through)"
}

# pane_is_turn_end (#447): a turn-ended/idle-at-prompt golem paints the bare
# `⏵⏵ auto mode on` footer with NO `esc to interrupt` run-spinner (rc 0). A pane
# still running (spinner present) is NOT idle even with the same footer (rc 1,
# spinner checked first); a bare-words `auto mode on` lacking the ⏵⏵ glyph is NOT
# idle (rc 1); unrelated output is NOT idle (rc 1). Mirrors the `idle` arm of
# pane_liveness_class — this is the stall class the pane push channel dropped
# before #447.
test_pane_is_turn_end() {
    assert_equals "0" "$(_pane_rc pane_is_turn_end "  ⏵⏵ auto mode on")" \
        "A '⏵⏵ auto mode on' footer with no spinner is turn-ended/idle"
    assert_equals "1" "$(_pane_rc pane_is_turn_end "  ⏵⏵ auto mode on · esc to interrupt")" \
        "The same footer WITH the run-spinner is working, not idle (spinner wins)"
    assert_equals "1" "$(_pane_rc pane_is_turn_end "auto mode on")" \
        "A bare-words 'auto mode on' without the ⏵⏵ glyph is NOT turn-ended"
    assert_equals "1" "$(_pane_rc pane_is_turn_end "just some scrolling build output")" \
        "Unrelated work output is NOT turn-ended"
}

# Footer anchoring (#447, mirroring test_pane_is_fork_footer_anchored / the #246
# pane_liveness_class fix): pane_is_turn_end scans only the last
# GOLEM_PANE_FOOTER_LINES lines. This very test file and golem-gate-watch.sh's own
# comments carry `⏵⏵ auto mode on`, so a golem cat-ing/grepping them must not
# self-trip a false idle. `filler` pushes the scrolled footer glyph out of the
# window; the real footer below it (an active spinner) must win.
test_pane_is_turn_end_footer_anchored() {
    local filler
    filler=$'l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10'
    assert_equals "1" \
        "$(_pane_rc pane_is_turn_end "grep '⏵⏵ auto mode on' golem-gate-watch.sh"$'\n'"$filler"$'\n'"  ⏵⏵ esc to interrupt")" \
        "A scrolled '⏵⏵ auto mode on' above an active-spinner footer does not fake an idle"
    assert_equals "0" \
        "$(_pane_rc pane_is_turn_end "$filler"$'\n'"  ⏵⏵ auto mode on")" \
        "A '⏵⏵ auto mode on' footer inside the window (no spinner) still matches"
}

# End-to-end turn-end dispatch (#447): drive the REAL panes_snapshot() via
# `--once-panes` (reusing _run_panes_snapshot_tmux) to pin that a turn-ended pane
# emits the idle-at-prompt label AND that it is the LAST-RESORT branch — a pane
# that is BOTH a modal overlay and shows the idle footer is classified as the
# overlay, never downgraded to idle.
test_panes_snapshot_turn_end_dispatch() {
    _run_panes_snapshot_tmux "⏺ done for now"$'\n'"  ⏵⏵ auto mode on"
    assert_equals "0" "$PANES_RC" "panes_snapshot exits 0 for a turn-ended pane"
    assert_contains "$PANES_OUT" "golem-9"$'\t'"⚠ idle at prompt — turn ended, awaiting input (check pane)" \
        "A turn-ended pane emits the idle-at-prompt label end-to-end"

    # Plan overlay + idle footer: plan-gate is checked first, so it wins.
    _run_panes_snapshot_tmux "1. Yes, and use auto mode"$'\n'"  ⏵⏵ auto mode on"
    assert_contains "$PANES_OUT" "golem-9"$'\t'"plan gate — ExitPlanMode awaiting approval" \
        "A plan+idle pane emits the plan-gate label (plan wins over turn-end)"
    assert_not_contains "$PANES_OUT" "idle at prompt" \
        "A plan+idle pane is NOT downgraded to idle-at-prompt"

    # Permission-gate + idle footer: the generic gate is checked before turn-end,
    # so it wins (turn-end is the 4th-tier last resort, must lose to ANY modal).
    _run_panes_snapshot_tmux "Do you want to proceed?"$'\n'"  ⏵⏵ auto mode on"
    assert_contains "$PANES_OUT" "golem-9"$'\t'"permission gate — awaiting decision" \
        "A gate+idle pane emits the permission-gate label (gate wins over turn-end)"
    assert_not_contains "$PANES_OUT" "idle at prompt" \
        "A gate+idle pane is NOT downgraded to idle-at-prompt"

    # Fork + idle footer: the escalation fork is checked before turn-end, so it wins.
    _run_panes_snapshot_tmux "What scope? "$'\n'"Enter to select · ↑/↓ to navigate"$'\n'"  ⏵⏵ auto mode on"
    assert_contains "$PANES_OUT" "golem-9"$'\t'"escalation — awaiting decision (carries options)" \
        "A fork+idle pane emits the escalation label (fork wins over turn-end)"
    assert_not_contains "$PANES_OUT" "idle at prompt" \
        "A fork+idle pane is NOT downgraded to idle-at-prompt"
}

# confirm_turn_end two-consecutive-poll debounce (#447): the turn-end/idle line is
# suppressed on the FIRST poll a golem looks idle and passed only once it is STILL
# idle on the NEXT poll — so a momentary between-turns render never fires a false
# idle. Real gates pass through immediately (they do not flicker). A golem that
# clears re-confirms from scratch. Also covers a multi-golem single call (shared
# accumulators don't cross-clobber) and the chained confirm_turn_end ->
# emit_transitions drive-arm sequence (a fresh idle surfaces once, on its 2nd
# poll). Like test_emit_transitions_dedup, all cases run in ONE subshell because
# PENDING_TURN_END / LAST_EMIT are module state mutated across calls.
test_confirm_turn_end_debounce() {
    local out
    # The literal turn-end message (the sourced $TURN_END_MSG is only in scope
    # inside the subshell below; assertions in this outer scope use the literal).
    local te="⚠ idle at prompt — turn ended, awaiting input (check pane)"
    out="$(
        source "$GATE_WATCH"
        local idle="golem-3"$'\t'"$TURN_END_MSG"
        # 1. First idle poll -> suppressed (CONFIRMED_SNAPSHOT empty).
        command printf '[p1]'
        confirm_turn_end "$idle"
        command printf '%s' "$CONFIRMED_SNAPSHOT"
        # 2. Second consecutive idle poll -> confirmed (passes through).
        command printf '[p2]'
        confirm_turn_end "$idle"
        command printf '%s' "$CONFIRMED_SNAPSHOT"
        # 3. A real gate passes through on its FIRST poll (no debounce). NOTE this
        #    snapshot omits golem-3, so golem-3 also DROPS from PENDING_TURN_END here
        #    (nextpending is rebuilt from scratch each call from only the lines in
        #    this snapshot) — the clear happens at this step, not case 4.
        command printf '[gate]'
        confirm_turn_end "golem-4"$'\t'"permission gate — awaiting decision"
        command printf '%s' "$CONFIRMED_SNAPSHOT"
        # 4. A genuinely empty snapshot after the clear is a no-op; the FIRST idle
        #    poll for golem-3 after it dropped is suppressed again (re-confirms from
        #    scratch, not remembered across the clear).
        command printf '[clear]'
        confirm_turn_end ""
        command printf '[reidle1]'
        confirm_turn_end "$idle"
        command printf '%s' "$CONFIRMED_SNAPSHOT"
        # 5. Multi-golem SINGLE call: two idle golems + one real gate in ONE snapshot.
        #    Pins that the per-line loop's shared accumulators do not let one golem's
        #    line clobber another's pending flag / passthrough within a single call.
        #    golem-3 was left pending by case 4's reidle1; golem-7 is fresh. So this
        #    one call must: confirm golem-3 (its 2nd consecutive idle), suppress
        #    golem-7 (its 1st idle), and pass golem-8's gate straight through.
        command printf '[multi]'
        confirm_turn_end "golem-3"$'\t'"$TURN_END_MSG"$'\n'"golem-7"$'\t'"$TURN_END_MSG"$'\n'"golem-8"$'\t'"permission gate — awaiting decision"
        command printf '%s' "$CONFIRMED_SNAPSHOT"
        # 6. Chained drive-arm sequence: confirm_turn_end -> emit_transitions in the
        #    SAME shell, exactly as the --stream-panes arm wires it, across two polls.
        #    Pins that emit_transitions reads the CONFIRMED (post-debounce) snapshot,
        #    so a fresh idle golem surfaces on its SECOND poll and only ONCE (dedup).
        #    golem-5 is a fresh id (never in PENDING_TURN_END above) and LAST_EMIT is
        #    still empty here (earlier cases call only confirm_turn_end), so no state
        #    reset is needed.
        command printf '[chain1]'
        confirm_turn_end "golem-5"$'\t'"$TURN_END_MSG"
        emit_transitions "$CONFIRMED_SNAPSHOT" 0
        command printf '[chain2]'
        confirm_turn_end "golem-5"$'\t'"$TURN_END_MSG"
        emit_transitions "$CONFIRMED_SNAPSHOT" 0
        command printf '[chain3]'
        confirm_turn_end "golem-5"$'\t'"$TURN_END_MSG"
        emit_transitions "$CONFIRMED_SNAPSHOT" 0
    )"
    assert_contains "$out" "[p1][p2]" \
        "The first idle poll emits nothing (suppressed pending confirmation)"
    assert_contains "$out" "[p2]golem-3"$'\t'"$te" \
        "The second consecutive idle poll confirms and passes the turn-end line"
    assert_contains "$out" "[gate]golem-4"$'\t'"permission gate — awaiting decision" \
        "A real gate passes through on its first poll (not debounced)"
    assert_not_contains "$out" "[reidle1]golem-3" \
        "After a clear, a single idle poll is suppressed again (re-confirms from scratch)"
    # Multi-golem single call: golem-3 confirmed, golem-7 suppressed, golem-8 gate through.
    assert_contains "$out" "[multi]golem-3"$'\t'"$te" \
        "In a multi-golem call, a golem on its 2nd consecutive idle is confirmed"
    assert_contains "$out" "golem-8"$'\t'"permission gate — awaiting decision" \
        "In the same multi-golem call, a real gate still passes straight through"
    assert_not_contains "$out" "[multi]golem-7" \
        "In the same multi-golem call, a golem on its 1st idle is still suppressed"
    # Chained sequence: golem-5 surfaces once, on chain2 (its 2nd poll), not chain1/3.
    assert_not_contains "$out" "[chain1]golem-5" \
        "Chained drive-arm: a fresh idle golem does not surface on its first poll"
    assert_contains "$out" "[chain2]golem-5"$'\t'"$te" \
        "Chained drive-arm: the idle golem surfaces on its second poll (post-debounce)"
    assert_not_contains "$out" "[chain3]golem-5" \
        "Chained drive-arm: the standing idle line is deduped by emit_transitions (not re-emitted)"
}

# emit_transitions: the transition-dedup contract that backs --stream/--stream-
# panes. All cases run inside ONE subshell because LAST_EMIT is module state the
# function mutates across calls; the subshell isolates that from the harness.
#   1. prime=1 records state WITHOUT emitting (startup must not replay standing gates)
#   2. a NEW golem (or changed message) emits exactly its line
#   3. a STANDING gate (same golem+message) is suppressed on the next tick
#   4. a changed message for the same golem re-emits
#   5. a golem that CLEARS then re-gates is a fresh transition (emits again)
test_emit_transitions_dedup() {
    local out
    out="$(
        source "$GATE_WATCH"
        # 1. Prime with one standing gate -> no output.
        command printf '[prime]'
        emit_transitions "$(command printf 'golem-1\tpush gate\n')" 1
        # 2. Same gate on the next tick -> suppressed (already primed).
        command printf '[standing]'
        emit_transitions "$(command printf 'golem-1\tpush gate\n')" 0
        # 3. A genuinely new golem -> emits.
        command printf '[new]'
        emit_transitions "$(command printf 'golem-1\tpush gate\ngolem-2\tPR gate\n')" 0
        # 4. golem-1's message changes -> re-emits; golem-2 unchanged -> silent.
        command printf '[changed]'
        emit_transitions "$(command printf 'golem-1\tmerge gate\ngolem-2\tPR gate\n')" 0
        # 5. golem-2 clears (empty snapshot for it) then re-gates -> fresh emit.
        command printf '[clear]'
        emit_transitions "$(command printf 'golem-1\tmerge gate\n')" 0
        command printf '[regate]'
        emit_transitions "$(command printf 'golem-1\tmerge gate\ngolem-2\tPR gate\n')" 0
    )"
    # Prime + standing emit nothing between their markers.
    assert_contains "$out" "[prime][standing][new]" \
        "Prime and standing gate emit nothing (no replay on startup or steady state)"
    assert_contains "$out" "[new]golem-2"$'\t'"PR gate" \
        "A newly-gated golem emits its line"
    assert_contains "$out" "[changed]golem-1"$'\t'"merge gate" \
        "A changed message re-emits for the same golem"
    assert_not_contains "$out" "[changed]golem-1"$'\t'"merge gate"$'\n'"golem-2" \
        "An unchanged golem is not re-emitted alongside a changed one"
    assert_contains "$out" "[regate]golem-2"$'\t'"PR gate" \
        "A cleared-then-re-gated golem is a fresh transition"
}

# --- Liveness stream dedup (#489) -------------------------------------------
# The --stream-liveness heartbeat used to re-emit every golem's line every poll,
# unconditionally, flooding live context. #489 routes it through liveness_stabilize
# -> emit_transitions (the gate channels' dedup) plus a slow aggregate summary. The
# four tests below cover the pure functions in isolation (never the infinite
# --stream-liveness loop — the setsid-free liveness-testing discipline).

# liveness_stabilize: the two mtime-heartbeat lines carry a volatile _fmt_age that
# ticks every poll and would defeat emit_transitions' per-golem message dedup.
# Stabilize drops the age to a stable class, so the SAME golem at the SAME class
# with a DIFFERENT age produces a byte-identical line. Every other liveness line
# (working / idle / died / gated) is already age-free and passes through verbatim.
test_liveness_stabilize_strips_age() {
    local out1 out2
    out1="$(
        source "$GATE_WATCH"
        liveness_stabilize "$(command printf 'golem-7\talive (process up, last activity 3m ago)\n')"
    )"
    out2="$(
        source "$GATE_WATCH"
        liveness_stabilize "$(command printf 'golem-7\talive (process up, last activity 12m ago)\n')"
    )"
    assert_equals "$out1" "$out2" \
        "Two different mtime ages stabilize to an identical line (the dedup key)"
    assert_contains "$out1" "golem-7"$'\t'"alive (process up)" \
        "The mtime heartbeat is canonicalized to the age-free class"
    assert_not_contains "$out1" "last activity" \
        "The volatile age substring is stripped"

    # The 'possible stall' mtime line strips its age too.
    local stall
    stall="$(
        source "$GATE_WATCH"
        liveness_stabilize "$(command printf 'golem-7\tpossible stall — no progress for 40m\n')"
    )"
    assert_contains "$stall" "golem-7"$'\t'"possible stall" "Stall line is canonicalized to age-free class"
    assert_not_contains "$stall" "40m" "The stall age is stripped"

    # A non-mtime line (already age-free) passes through unchanged.
    local passthru
    passthru="$(
        source "$GATE_WATCH"
        liveness_stabilize "$(command printf 'golem-7\talive, working (esc-to-interrupt active)\n')"
    )"
    assert_contains "$passthru" "golem-7"$'\t'"alive, working (esc-to-interrupt active)" \
        "An already-stable working line passes through verbatim"
}

# The transition-only contract the issue asks for (AC1, AC2, AC4): drive the real
# chained liveness_stabilize -> emit_transitions across ticks, exactly as the
# --stream-liveness arm wires it. One subshell because LAST_EMIT is module state.
#   1. prime (silent)
#   2. same class, DIFFERENT age -> suppressed (AC1: steady state emits nothing)
#   3. alive -> possible stall -> emits (AC2: a transition surfaces promptly)
#   4. -> alive, working -> emits (another class change)
#   5. -> idle at prompt -> emits (AC2 names working→idle explicitly)
#   6. -> gated -> emits (AC2 names →gated explicitly)
#   7. steady on gated -> suppressed
test_liveness_stream_dedup() {
    local out
    out="$(
        source "$GATE_WATCH"
        # 1. Prime a fresh, alive golem -> no output.
        command printf '[prime]'
        emit_transitions "$(liveness_stabilize "$(command printf 'golem-7\talive (process up, last activity 1m ago)\n')")" 1
        # 2. Same class, the age has ticked on -> stabilized identical -> suppressed.
        command printf '[steady]'
        emit_transitions "$(liveness_stabilize "$(command printf 'golem-7\talive (process up, last activity 9m ago)\n')")" 0
        # 3. Class flips to a stall -> emits.
        command printf '[stall]'
        emit_transitions "$(liveness_stabilize "$(command printf 'golem-7\tpossible stall — no progress for 40m\n')")" 0
        # 4. Class flips to working -> emits.
        command printf '[working]'
        emit_transitions "$(liveness_stabilize "$(command printf 'golem-7\talive, working (esc-to-interrupt active)\n')")" 0
        # 5. working -> idle at prompt -> emits (AC2 names this transition).
        command printf '[idle]'
        emit_transitions "$(liveness_stabilize "$(command printf 'golem-7\t⚠ idle at prompt — process up, not advancing (check pane)\n')")" 0
        # 6. -> gated -> emits (AC2 names →gated).
        command printf '[gated]'
        emit_transitions "$(liveness_stabilize "$(command printf 'golem-7\tgated — awaiting decision (not a stall)\n')")" 0
        # 7. Steady on gated -> suppressed.
        command printf '[steady2]'
        emit_transitions "$(liveness_stabilize "$(command printf 'golem-7\tgated — awaiting decision (not a stall)\n')")" 0
    )"
    # AC1: prime + both steady ticks emit nothing between their markers.
    assert_contains "$out" "[prime][steady][stall]" \
        "Steady state (same class, different age) emits nothing (#489 AC1)"
    assert_contains "$out" "[stall]golem-7"$'\t'"possible stall" \
        "A class change to possible stall emits promptly (#489 AC2)"
    assert_contains "$out" "[working]golem-7"$'\t'"alive, working (esc-to-interrupt active)" \
        "A class change to working emits"
    # AC2 names working→idle and →gated explicitly — each must surface promptly.
    assert_contains "$out" "[idle]golem-7"$'\t'"⚠ idle at prompt" \
        "A working→idle transition emits promptly (#489 AC2)"
    assert_contains "$out" "[gated]golem-7"$'\t'"gated — awaiting decision (not a stall)" \
        "A →gated transition emits promptly (#489 AC2)"
    # emit_transitions prints a trailing newline after each emitted line, so a
    # suppressed [steady2] tick leaves the gated line immediately followed by
    # newline + the [steady2] marker (nothing emitted between them).
    assert_contains "$out" "gated — awaiting decision (not a stall)"$'\n'"[steady2]" \
        "A steady gated class is suppressed on the next tick (no re-emit)"
}

# liveness_summary: the slow aggregate line that keeps the deduped stream from
# looking dead. Counts each class over a mixed snapshot; 'alive, working' and the
# mtime 'process up' heartbeat both count as alive. Empty snapshot -> no output.
test_liveness_summary_counts() {
    local out
    out="$(
        source "$GATE_WATCH"
        liveness_summary "$(command printf '%s\n' \
            'golem-1'$'\t''alive, working (esc-to-interrupt active)' \
            'golem-2'$'\t''alive (process up, last activity 2m ago)' \
            'golem-3'$'\t''⚠ idle at prompt — process up, not advancing (check pane)' \
            'golem-4'$'\t''possible stall — no progress for 40m' \
            'golem-5'$'\t''gated — awaiting decision (not a stall)' \
            'golem-6'$'\t''⚠ died — API error: terminal (401) (check pane)')"
    )"
    assert_contains "$out" "liveness-summary" "Summary line carries the aggregate id"
    assert_contains "$out" "2 alive, 1 idle, 1 stalled, 1 gated, 1 died (6 golems)" \
        "Class counts aggregate correctly (working+process-up both count as alive)"

    local empty
    empty="$(
        source "$GATE_WATCH"
        liveness_summary ""
    )"
    assert_output_empty "$empty" "An empty snapshot produces no summary line"
}

# summary_due: the cadence gate. Due at/above the interval; not due below; a 0 or
# non-numeric interval disables the summary (never crashes the watch on garbage
# GOLEM_LIVENESS_SUMMARY_INTERVAL).
test_summary_due() {
    # Two-arg calls via a sourced subshell; map exit status to 0(due)/1(not due).
    assert_equals "0" "$(
        source "$GATE_WATCH"
        summary_due 900 900 && echo 0 || echo 1
    )" \
        "Due when elapsed == interval"
    assert_equals "0" "$(
        source "$GATE_WATCH"
        summary_due 1200 900 && echo 0 || echo 1
    )" \
        "Due when elapsed > interval"
    assert_equals "1" "$(
        source "$GATE_WATCH"
        summary_due 300 900 && echo 0 || echo 1
    )" \
        "Not due when elapsed < interval"
    assert_equals "1" "$(
        source "$GATE_WATCH"
        summary_due 5000 0 && echo 0 || echo 1
    )" \
        "Interval 0 disables the summary (never due)"
    assert_equals "1" "$(
        source "$GATE_WATCH"
        summary_due 5000 abc && echo 0 || echo 1
    )" \
        "Non-numeric interval never crashes / is never due"
}

# summary_enabled (#489 review): gates even the ONE-TIME startup summary so
# "0 disables it" holds literally. Enabled for a positive numeric interval;
# disabled for 0, empty, or non-numeric.
test_summary_enabled() {
    assert_equals "0" "$(
        source "$GATE_WATCH"
        summary_enabled 900 && echo 0 || echo 1
    )" \
        "A positive interval enables the summary (startup line fires)"
    assert_equals "1" "$(
        source "$GATE_WATCH"
        summary_enabled 0 && echo 0 || echo 1
    )" \
        "Interval 0 disables the summary entirely, incl. the startup line"
    assert_equals "1" "$(
        source "$GATE_WATCH"
        summary_enabled "" && echo 0 || echo 1
    )" \
        "Empty interval disables the summary"
    assert_equals "1" "$(
        source "$GATE_WATCH"
        summary_enabled 15m && echo 0 || echo 1
    )" \
        "Non-numeric interval disables the summary (never crashes)"
}

# GOLEM_LIVENESS_SUMMARY_INTERVAL env-overridability (#489 review), mirroring
# test_liveness_threshold_env_overridable / test_pane_footer_lines_env_overridable:
# set the env var before sourcing and confirm it reaches the summary_interval
# tunable, catching a typo'd var name or broken `${VAR:-default}` wiring. The
# script assigns `summary_interval` at top level whether sourced or executed.
test_summary_interval_env_overridable() {
    # summary_interval is assigned at the sourced script's top level; shellcheck
    # cannot see across the `source`, so silence its not-assigned warning.
    # shellcheck disable=SC2154
    # Unset -> default 900.
    assert_equals "900" "$(
        unset GOLEM_LIVENESS_SUMMARY_INTERVAL
        source "$GATE_WATCH"
        command printf '%s' "$summary_interval"
    )" \
        "summary_interval defaults to 900 when the env var is unset"
    # Set -> honored. `export` so the sourced script reads it from the environment
    # (and so shellcheck sees the assignment as consumed, not dead — SC2034).
    assert_equals "120" "$(
        export GOLEM_LIVENESS_SUMMARY_INTERVAL=120
        source "$GATE_WATCH"
        command printf '%s' "$summary_interval"
    )" \
        "GOLEM_LIVENESS_SUMMARY_INTERVAL is env-overridable (reaches summary_interval)"
}

# heartbeat_interval numeric coercion (#489 review): a non-numeric
# GOLEM_HEARTBEAT_INTERVAL (a plausible typo like "15m") would abort the whole
# --stream-liveness watch on the `$((since_summary + heartbeat_interval))`
# arithmetic under `set -u`. The top-level guard coerces it back to 60 so the
# watch survives; a valid numeric value is honored unchanged.
test_heartbeat_interval_numeric_coercion() {
    # heartbeat_interval is assigned at the sourced script's top level (across the
    # `source` shellcheck cannot follow), so silence the not-assigned warning.
    # shellcheck disable=SC2154
    assert_equals "60" "$(
        export GOLEM_HEARTBEAT_INTERVAL=15m
        source "$GATE_WATCH"
        command printf '%s' "$heartbeat_interval"
    )" \
        "A non-numeric GOLEM_HEARTBEAT_INTERVAL is coerced to 60 (no watch crash)"
    assert_equals "30" "$(
        export GOLEM_HEARTBEAT_INTERVAL=30
        source "$GATE_WATCH"
        command printf '%s' "$heartbeat_interval"
    )" \
        "A valid numeric GOLEM_HEARTBEAT_INTERVAL is honored unchanged"
    # The arithmetic that would crash must be safe now: exercise it directly.
    assert_equals "60" "$(
        export GOLEM_HEARTBEAT_INTERVAL=notanumber
        source "$GATE_WATCH"
        since=0
        since=$((since + heartbeat_interval))
        command printf '%s' "$since"
    )" \
        "The cadence arithmetic no longer aborts under set -u on garbage input"
}

# Ghost filter (#446, Bug #2 Layer B): a golem torn down WITHOUT worktree-rm.sh
# leaves its `gate` line as its most-recent feed entry with no `reaped` line to
# supersede it — so feed_snapshot_live cross-checks golem_has_live_trace and drops
# a gated golem with NO on-disk/tmux trace left (no session, no worktree dir, no
# cache file). A golem WITH a cache-file trace (a live headless/container golem)
# is kept — its gate is real. The shared _run_once_snapshot helper stamps a cache
# trace per feed golem, so here we craft the ghost by hand: run `--once` directly
# against a repo where golem-1 has a feed gate but NO trace, and golem-2 has both.
test_ghost_gate_dropped_when_no_trace() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (feed_snapshot no-ops without jq)"
        return 0
    fi
    local tmp
    tmp="$(command mktemp -d)" || return 1
    # shellcheck disable=SC2064
    trap "command rm -rf '$tmp'" RETURN
    local git_scrub=(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
        GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES)
    /usr/bin/env "${git_scrub[@]/#/--unset=}" \
        git -C "$tmp" init -q 2>/dev/null || return 1
    command mkdir -p "$tmp/.worktrees/.status"
    local ts
    ts="$(command date -u +%FT%TZ)"
    {
        command printf '{"ts":"%s","golem":"golem-1","event":"gate","message":"needs permission"}\n' "$ts"
        command printf '{"ts":"%s","golem":"golem-2","event":"gate","message":"needs permission"}\n' "$ts"
    } >"$tmp/.worktrees/.status/feed.jsonl"
    # Only golem-2 gets a cache-file trace; golem-1 is a ghost (torn down, no trace).
    command printf '{"golem":"golem-2","issue":2}\n' >"$tmp/.worktrees/.status/golem-2.json"

    # A fake tmux whose `ls`/`has-session` report NO sessions, so a real host golem
    # cannot leak a trace in (mirrors the #436 hermetic-tmux guard elsewhere).
    local stub_bin real_bash real_jq real_git
    stub_bin="$tmp/stub-bin"
    command mkdir -p "$stub_bin"
    real_bash="$(command -v bash)"
    command ln -s "$real_bash" "$stub_bin/bash"
    real_git="$(command -v git)"
    command ln -s "$real_git" "$stub_bin/git"
    real_jq="$(command -v jq || true)"
    [ -n "$real_jq" ] && command ln -s "$real_jq" "$stub_bin/jq"
    command cat >"$stub_bin/tmux" <<'TMUX_STUB'
#!/usr/bin/env bash
case "$1" in
    ls) exit 0 ;;
    has-session) exit 1 ;;
    *) exit 0 ;;
esac
TMUX_STUB
    command chmod +x "$stub_bin/tmux"

    # Two more gated golems exercise the OTHER two KEEP probes of
    # golem_has_live_trace: golem-3 kept via an `issue-N.json` cache alias,
    # golem-4 kept via an on-disk worktree dir (no cache file of its own).
    {
        command printf '{"ts":"%s","golem":"golem-3","event":"gate","message":"needs permission"}\n' "$ts"
        command printf '{"ts":"%s","golem":"golem-4","event":"gate","message":"needs permission"}\n' "$ts"
    } >>"$tmp/.worktrees/.status/feed.jsonl"
    command printf '{"golem":"golem-3","issue":3}\n' >"$tmp/.worktrees/.status/issue-3.json"
    command mkdir -p "$tmp/.worktrees/issue-4"

    local out rc=0
    out="$(
        cd "$tmp" &&
            /usr/bin/env "${git_scrub[@]/#/--unset=}" --unset=BASH_ENV \
                PATH="$stub_bin" \
                GOLEM_BLOCK_TTL=999999999999 GOLEM_WORKTREE_DIR=.worktrees \
                GOLEM_STATUS_DIR=.worktrees/.status \
                "$real_bash" "$GATE_WATCH" --once 2>/dev/null
    )" || rc=$?
    assert_equals "0" "$rc" "Ghost-filtered --once still exits 0"
    assert_not_contains "$out" "golem-1" \
        "A gated golem with no live trace (ghost) is dropped from BLOCKED (#446)"
    assert_contains "$out" "golem-2" \
        "A gated golem with a golem-N.json cache-file trace is kept (its gate is real)"
    assert_contains "$out" "golem-3" \
        "A gated golem kept via an issue-N.json cache alias trace is not dropped"
    assert_contains "$out" "golem-4" \
        "A gated golem kept via an on-disk worktree dir trace is not dropped"
}

# API-error death matcher (#446, Bug #4): pane_is_api_error matches the Claude Code
# `API Error <4xx/5xx>` signature in the wider scrollback window, while an ACTIVE
# run-spinner in the footer vetoes it (a working golem reading an old error is not
# dead), and prose mentioning "api error" without a code does not match. The
# classifier splits retriable (429/5xx) from terminal (auth/quota 4xx).
test_pane_is_api_error() {
    local died term_pane working prose
    died=$'work output\nAPI Error: Request rejected (429)\n\n  Try again\n⏵⏵ auto mode on'
    term_pane=$'API Error: 403 Forbidden\n\n⏵⏵ auto mode on'
    working=$'API Error: Request rejected (429)\n· Doing work (esc to interrupt)'
    prose=$'we discussed an api error earlier\n\n⏵⏵ auto mode on'

    assert_equals "0" "$(_pane_rc pane_is_api_error "$died")" \
        "A 429 API-error scrollback with a bare footer matches (died)"
    assert_equals "0" "$(_pane_rc pane_is_api_error "$term_pane")" \
        "A 403 API-error scrollback matches (terminal death)"
    assert_equals "1" "$(_pane_rc pane_is_api_error "$working")" \
        "The same error WITH an active run-spinner is NOT a death (spinner vetoes)"
    assert_equals "1" "$(_pane_rc pane_is_api_error "$prose")" \
        "Prose mentioning 'api error' without a status code is NOT a death"

    # A 5xx (overloaded/server) is transient too — the `5??` glob arm, distinct
    # from the literal 429. Pins that a 529/500 is retriable, not terminal.
    local overloaded
    overloaded=$'API Error: 529 Overloaded\n\n⏵⏵ auto mode on'
    assert_equals "0" "$(_pane_rc pane_is_api_error "$overloaded")" \
        "A 529 API-error scrollback matches (transient overload death)"

    # Classification: retriable (429 + 5xx) vs terminal (other 4xx).
    local rc_class fivexx_class term_class
    rc_class="$(
        source "$GATE_WATCH"
        pane_api_error_class "$died"
    )"
    fivexx_class="$(
        source "$GATE_WATCH"
        pane_api_error_class "$overloaded"
    )"
    term_class="$(
        source "$GATE_WATCH"
        pane_api_error_class "$term_pane"
    )"
    assert_equals "retriable (429)" "$rc_class" "429 classifies as retriable"
    assert_equals "retriable (529)" "$fivexx_class" "a 5xx code classifies as retriable (the 5?? arm, not just 429)"
    assert_equals "terminal (403)" "$term_class" "403 classifies as terminal"
}

# End-to-end death dispatch (#446, Bug #4): drive the REAL panes_snapshot() via
# `--once-panes` to pin that a died-on-API-error pane emits the DIED label with its
# retriable/terminal class, AND that the death read is dispatched BEFORE
# pane_is_turn_end — a died pane also paints the bare `auto mode on` footer, so the
# more-specific death must win, never downgraded to turn-end.
test_panes_snapshot_died_dispatch() {
    _run_panes_snapshot_tmux "API Error: Request rejected (429)"$'\n'"⏺ stopped"$'\n'"  ⏵⏵ auto mode on"
    assert_equals "0" "$PANES_RC" "panes_snapshot exits 0 for a died pane"
    assert_contains "$PANES_OUT" "golem-9"$'\t'"⚠ died — API error: retriable (429) (check pane)" \
        "A died-on-429 pane emits the DIED label with a retriable class end-to-end"
    assert_not_contains "$PANES_OUT" "idle at prompt" \
        "A died pane is NOT downgraded to turn-end/idle (death wins)"

    # A terminal (auth) death classifies distinctly.
    _run_panes_snapshot_tmux "API Error: 401 Unauthorized"$'\n'"  ⏵⏵ auto mode on"
    assert_contains "$PANES_OUT" "golem-9"$'\t'"⚠ died — API error: terminal (401) (check pane)" \
        "A died-on-401 pane emits the DIED label with a terminal class"

    # A plan-gate + a stale error in scrollback: the modal gate still wins (death
    # is dispatched after the three modal matchers, before turn-end only).
    _run_panes_snapshot_tmux "API Error: 429"$'\n'"1. Yes, and use auto mode"$'\n'"  ⏵⏵ auto mode on"
    assert_contains "$PANES_OUT" "golem-9"$'\t'"plan gate — ExitPlanMode awaiting approval" \
        "A plan overlay wins over a scrollback error (modal gates precede the death read)"
    assert_not_contains "$PANES_OUT" "died — API error" \
        "A plan+error pane is NOT labelled a death (modal wins)"
}

# GOLEM_PANE_FOOTER_LINES env-override (#458, mirroring
# test_liveness_threshold_env_overridable for GOLEM_STALL_THRESHOLD): every pane
# matcher #458 names scopes its match to the last $pane_footer_lines lines, where
# `pane_footer_lines="${GOLEM_PANE_FOOTER_LINES:-8}"` is read once at source time.
# No prior test set the env var to a non-default value, so a regression that
# silently ignored it (typo'd var name, value never reaching the sourced context)
# would go uncaught. This pins the ${VAR:-default} wiring in BOTH directions
# (shrink hides an in-default-window trigger; enlarge reveals an
# out-of-default-window one) across ALL FIVE footer-keyed matchers named in the
# issue — pane_is_gate, pane_is_fork, pane_is_plan_gate, pane_is_turn_end, and
# pane_liveness_class — so a per-matcher hardcoded 8 (not reading the shared var)
# is caught in any one of them, not just a single wiring point. _pane_rc sources
# the script in a subshell, so the GOLEM_PANE_FOOTER_LINES= prefix reaches that
# source-time read. (pane_is_api_error, added in #446, keys its PRIMARY match off
# $pane_error_lines and uses $pane_footer_lines only for its spinner-veto guard,
# so it is out of #458's footer-window scope.)
test_pane_footer_lines_env_overridable() {
    local four nine

    # Shrink direction: a trigger 5 lines from the bottom is INSIDE the default
    # 8-line window (match) but OUTSIDE a shrunk 3-line window (no match).
    # Flipping match->no-match as the window shrinks proves the smaller value
    # took effect. Exercised on the two rc-returning gate matchers.
    four=$'f1\nf2\nf3\nf4'
    assert_equals "0" "$(_pane_rc pane_is_gate "Do you want to proceed?"$'\n'"$four")" \
        "pane_is_gate: a gate 5 lines up matches under the default 8-line window"
    assert_equals "1" \
        "$(GOLEM_PANE_FOOTER_LINES=3 _pane_rc pane_is_gate "Do you want to proceed?"$'\n'"$four")" \
        "pane_is_gate: GOLEM_PANE_FOOTER_LINES=3 shrinks the window so the same gate falls outside it"
    assert_equals "0" "$(_pane_rc pane_is_plan_gate "Here is Claude's plan:"$'\n'"$four")" \
        "pane_is_plan_gate: a plan overlay 5 lines up matches under the default 8-line window"
    assert_equals "1" \
        "$(GOLEM_PANE_FOOTER_LINES=3 _pane_rc pane_is_plan_gate "Here is Claude's plan:"$'\n'"$four")" \
        "pane_is_plan_gate: GOLEM_PANE_FOOTER_LINES=3 shrinks the window so the same plan overlay falls outside it"

    # Enlarge direction: a trigger 10 lines from the bottom is OUTSIDE the
    # default 8-line window (no match) but INSIDE an enlarged 12-line window
    # (match). Exercised on the remaining rc matchers (fork, turn_end) plus the
    # string-returning classifier (liveness_class emits "" vs "idle").
    nine=$'g1\ng2\ng3\ng4\ng5\ng6\ng7\ng8\ng9'
    assert_equals "1" "$(_pane_rc pane_is_fork "Enter to select · ↑/↓ to navigate"$'\n'"$nine")" \
        "pane_is_fork: a fork footer 10 lines up falls outside the default 8-line window"
    assert_equals "0" \
        "$(GOLEM_PANE_FOOTER_LINES=12 _pane_rc pane_is_fork "Enter to select · ↑/↓ to navigate"$'\n'"$nine")" \
        "pane_is_fork: GOLEM_PANE_FOOTER_LINES=12 enlarges the window so the same fork falls inside it"
    assert_equals "1" "$(_pane_rc pane_is_turn_end "  ⏵⏵ auto mode on"$'\n'"$nine")" \
        "pane_is_turn_end: an idle footer 10 lines up falls outside the default 8-line window"
    assert_equals "0" \
        "$(GOLEM_PANE_FOOTER_LINES=12 _pane_rc pane_is_turn_end "  ⏵⏵ auto mode on"$'\n'"$nine")" \
        "pane_is_turn_end: GOLEM_PANE_FOOTER_LINES=12 enlarges the window so the same idle footer falls inside it"

    # pane_liveness_class returns a CLASS STRING, not an rc — capture stdout via a
    # sourced subshell. The env var is set BEFORE `source` (as _pane_rc does it)
    # so the source-time `pane_footer_lines="${GOLEM_PANE_FOOTER_LINES:-8}"` read
    # picks it up — NOT assigned to pane_footer_lines directly, which would bypass
    # the very ${VAR:-default} wiring under test. Same enlarge direction: the idle
    # footer 10 lines up is unclassified ("") under the default window, "idle"
    # once the enlarged window covers it.
    assert_equals "" \
        "$( (
            source "$GATE_WATCH"
            pane_liveness_class "  ⏵⏵ auto mode on"$'\n'"$nine"
        ) 2>/dev/null)" \
        "pane_liveness_class: an idle footer 10 lines up is unclassified under the default 8-line window"
    assert_equals "idle" \
        "$( (
            export GOLEM_PANE_FOOTER_LINES=12
            source "$GATE_WATCH"
            pane_liveness_class "  ⏵⏵ auto mode on"$'\n'"$nine"
        ) 2>/dev/null)" \
        "pane_liveness_class: GOLEM_PANE_FOOTER_LINES=12 enlarges the window so the same idle footer classifies idle"
}

run_test test_legacy_line_does_not_drop_golems "Legacy no-ts feed line does not drop all BLOCKED golems"
run_test test_stale_ts_gate_ages_out "Stale dated gate ages out while no-ts golem stays fresh"
run_test test_empty_ts_treated_as_fresh "Empty-string ts is treated as fresh, not a crash"
run_test test_escalation_surfaces_labelled "Escalation surfaces in BLOCKED, labelled distinctly; idle excluded"
run_test test_resolved_supersedes_gate "Resolved line supersedes a stale gate; still-gated golem surfaces (#422)"
run_test test_golem_question_sentinel_excluded "Orphan golem-? sentinel is filtered while a real gate still surfaces (#323)"
run_test test_jq_absent_is_silent_noop "jq absent from PATH: --once is a silent no-op despite a fresh gate"
run_test test_liveness_fresh_is_alive "Liveness: fresh-activity golem reports alive (process up), not 'advancing'"
run_test test_liveness_stale_is_possible_stall "Liveness: old-activity golem flagged a possible stall (exit 0)"
run_test test_liveness_gated_not_stalled "Liveness: gated golem reported gated, not stalled"
run_test test_liveness_threshold_env_overridable "Liveness: GOLEM_STALL_THRESHOLD is env-overridable"
run_test test_liveness_pane_working_wiring "Liveness wiring: working pane -> 'alive, working' (pane wins over mtime)"
run_test test_liveness_pane_idle_wiring "Liveness wiring: idle pane (#229) -> 'idle at prompt' (pane wins over mtime)"
run_test test_liveness_pane_died_wiring "Liveness wiring: died pane (#446) -> DIED label with class (pane wins over mtime)"
run_test test_liveness_pane_indeterminate_falls_through "Liveness wiring: indeterminate pane falls through to mtime heartbeat"
run_test test_liveness_pane_blank_capture_falls_through "Liveness wiring: blank capture-pane (guard false) falls through to mtime heartbeat"
run_test test_liveness_transcript_working_wiring "Liveness transcript (#248): turn-in-flight -> 'alive, working' (transcript wins over mtime)"
run_test test_liveness_transcript_idle_wiring "Liveness transcript (#248): turn-ended -> 'idle at prompt' (headless #229 analog)"
run_test test_liveness_transcript_errored_wiring "Liveness transcript (#248): isApiErrorMessage -> 'errored and idle'"
run_test test_liveness_transcript_sidechain_not_masking "Liveness transcript (#248): sidechain churn does not mask a top-level idle"
run_test test_liveness_transcript_missing_falls_through "Liveness transcript (#248): missing transcript falls through to mtime heartbeat"
run_test test_liveness_transcript_indeterminate_falls_through "Liveness transcript (#248): indeterminate transcript falls through to mtime heartbeat"
run_test test_unknown_mode_exits_2 "Unknown mode exits 2 with a usage message"
run_test test_no_arg_defaults_to_once "No argument defaults to --once (not the error path)"
run_test test_fmt_age_formats "_fmt_age: seconds vs whole-minute formatting"
run_test test_pane_is_plan_gate "pane_is_plan_gate matches plan overlays, not work output"
run_test test_pane_is_gate "pane_is_gate matches the generic permission overlay only"
run_test test_pane_is_fork "pane_is_fork matches the AskUserQuestion escalation fork overlay"
run_test test_pane_is_fork_footer_anchored "pane_is_fork is footer-anchored (no self-trip on scrolled text)"
run_test test_pane_fork_plan_precedence "pane_is_plan_gate wins over pane_is_fork on a plan+fork pane"
run_test test_panes_snapshot_dispatch "panes_snapshot dispatch order + labels (plan/gate/fork) end-to-end"
run_test test_pane_is_turn_end "pane_is_turn_end matches the turn-ended/idle-at-prompt footer only (#447)"
run_test test_pane_is_turn_end_footer_anchored "pane_is_turn_end is footer-anchored (no self-trip on scrolled text)"
run_test test_panes_snapshot_turn_end_dispatch "panes_snapshot emits idle-at-prompt as last-resort; overlay wins (#447)"
run_test test_pane_footer_lines_env_overridable "pane matchers: GOLEM_PANE_FOOTER_LINES is env-overridable both directions (#458)"
run_test test_confirm_turn_end_debounce "confirm_turn_end: two-consecutive-poll debounce on the idle line; gates immediate (#447)"
run_test test_pane_liveness_class "pane_liveness_class: spinner=working, error/idle footer=idle, spinner wins"
run_test test_emit_transitions_dedup "emit_transitions: prime/standing/new/changed/re-gate dedup"
run_test test_liveness_stabilize_strips_age "liveness_stabilize: mtime age stripped to a stable class; other lines verbatim (#489)"
run_test test_liveness_stream_dedup "liveness stream: steady state silent, class change emits (#489 AC1/AC2/AC4)"
run_test test_liveness_summary_counts "liveness_summary: aggregate class counts; empty snapshot silent (#489)"
run_test test_summary_due "summary_due: cadence gate; 0/non-numeric interval disables (#489)"
run_test test_summary_enabled "summary_enabled: 0/empty/non-numeric disables the startup summary too (#489)"
run_test test_summary_interval_env_overridable "GOLEM_LIVENESS_SUMMARY_INTERVAL is env-overridable (#489)"
run_test test_heartbeat_interval_numeric_coercion "GOLEM_HEARTBEAT_INTERVAL non-numeric coerced to 60, no watch crash (#489)"
run_test test_ghost_gate_dropped_when_no_trace "Ghost filter: gated golem with no live trace dropped from BLOCKED (#446)"
run_test test_pane_is_api_error "pane_is_api_error: matches API-error death, spinner vetoes, classifies retriable/terminal (#446)"
run_test test_panes_snapshot_died_dispatch "panes_snapshot: died-on-API-error emits DIED before turn-end; modal gates still win (#446)"

generate_report
