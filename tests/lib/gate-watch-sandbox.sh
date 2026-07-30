# shellcheck shell=bash
# Shared fixtures + drivers for the golem-gate-watch test fragments
# (issue #564 — extracted from the 2,077-line tests/golem-gate-watch.sh).
#
# Sourced by tests/golem-gate-watch.sh BEFORE its area fragments under
# tests/gate-watch/. Every driver here is used by two or more fragments.
#
# Each driver runs the REAL script against a throwaway `git init` repo whose
# .worktrees/.status/ holds the fixture feed / status-cache / transcript, and
# reports through a pair of globals (SNAP_RC/SNAP_OUT, LIVE_RC/LIVE_OUT,
# PANES_RC/PANES_OUT) rather than echoing — so the exit code and the output are
# never multiplexed on one stream and the caller need not subshell the helper.
#
# Two invariants to preserve when editing:
#
#   * GOLEM_WORKTREE_DIR / GOLEM_STATUS_DIR are pinned at every invocation site,
#     so an exported value from a live golem session or a project `.envrc` cannot
#     redirect a driver at a REAL feed.
#   * git's hook-exported environment is scrubbed per invocation; inherited, it
#     pins repo_root to the OUTER repo and the fixture is silently ignored (the
#     failure mode root-caused in PR #62).
#
# GATE_WATCH is defined by the entry point before it sources this file.

# shellcheck disable=SC2034  # SNAP_*/LIVE_*/PANES_* are read by the area fragments

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

# pane_liveness_class (#229): source the script (main-guard makes it sourceable)
# in a subshell and echo the class the classifier prints for a pane sample.
_pane_class() {
    local text="$1"
    (
        source "$GATE_WATCH"
        pane_liveness_class "$text"
    ) 2>/dev/null
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
