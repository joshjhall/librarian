# shellcheck shell=bash
# Shared sandbox plumbing for the golem-notify hook test fragments
# (issue #564 — extracted from tests/validate-golem-notify.sh).
#
# Sourced by tests/validate-golem-notify.sh BEFORE its area fragments under
# tests/golem-notify/. Only drivers used by two or more fragments live here; a
# single-area helper (assert_event, poll_capture_count, ...) stays in its
# fragment so this library does not accrete single-use code.
#
# run_notify feeds a Notification-hook JSON payload to the REAL hook in a fresh
# sandbox and reports through NOTIFY_RC / NOTIFY_LINE, so the exit code and the
# emitted feed line are never multiplexed on one stream. GOLEM_* are scrubbed per
# invocation (GOLEM_SCRUB) so a live golem session's exported config cannot
# redirect the hook at a real feed.
#
# NOTIFY / CONFIG_SH / REAL_BASH / GIT_SCRUB / GOLEM_SCRUB are defined by the
# entry point before it sources this file.

# shellcheck disable=SC2034  # WORKDIR / NOTIFY_* are read by the area fragments

# Module-level scratch dir, cleaned up once when the suite exits.
WORKDIR="$(command mktemp -d)"
trap 'command rm -rf "$WORKDIR"' EXIT

# new_sandbox <varname>
# A fresh `git init` repo with a `.worktrees/.status/` dir. golem-notify.sh
# resolves its feed under <repo-root>/.worktrees/.status/feed.jsonl via
# git-common-dir, so a bare init (no commit needed) is enough. Assigns the
# sandbox path to the caller's named variable.
new_sandbox() {
    local __out="$1" dir
    dir="$(command mktemp -d "$WORKDIR/sandbox.XXXXXX")" || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$dir" init -q 2>/dev/null || return 1
    command mkdir -p "$dir/.worktrees/.status"
    printf -v "$__out" '%s' "$dir"
}

# Results of the most recent invocation.
NOTIFY_RC=0
NOTIFY_LINE=""

# run_notify <sandbox> <payload> <golem_id> [nojq]
# Pipes <payload> (a Notification JSON body) to the hook on stdin, from inside the
# sandbox repo, with GIT_* scrubbed, HOME + GOLEM_ID pinned. Captures the exit
# code in NOTIFY_RC and the last feed line in NOTIFY_LINE. Passing "nojq" as the
# 4th arg runs the hook with a hermetic PATH holding only bash, so `command -v
# jq` fails and the hand-rolled escaper path is taken — the hook reaches all
# other tools via absolute /usr/bin/* paths, so bash-only PATH is sufficient.
# BASH_ENV is unset for the child: some environments (this devcontainer's
# /etc/bash_env) RESET $PATH there, which would silently undo the jq-free PATH.
run_notify() {
    local dir="$1" payload="$2" gid="$3" mode="${4:-}"
    local feed="$dir/.worktrees/.status/feed.jsonl"
    command rm -f "$feed"
    NOTIFY_RC=0
    if [ "$mode" = "nojq" ]; then
        local stub="$dir/stub-bin"
        command mkdir -p "$stub"
        command ln -sf "$REAL_BASH" "$stub/bash"
        (
            cd "$dir" &&
                command printf '%s' "$payload" |
                /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
                    "${GOLEM_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
                    PATH="$stub" HOME="$dir" GOLEM_ID="$gid" \
                    "$REAL_BASH" "$NOTIFY"
        ) >/dev/null 2>&1 || NOTIFY_RC=$?
    else
        (
            cd "$dir" &&
                command printf '%s' "$payload" |
                /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
                    "${GOLEM_SCRUB[@]/#/--unset=}" \
                    HOME="$dir" GOLEM_ID="$gid" \
                    "$REAL_BASH" "$NOTIFY"
        ) >/dev/null 2>&1 || NOTIFY_RC=$?
    fi
    NOTIFY_LINE="$(command tail -n 1 "$feed" 2>/dev/null || true)"
}

# run_notify_status_dir <sandbox> <payload> <golem_id> <status_dir_override>
# Like run_notify's jq path, but exports GOLEM_STATUS_DIR=<override> into the
# child so the hook resolves its feed under <sandbox>/<override>/feed.jsonl
# instead of the hardcoded .worktrees/.status. Reads the feed back at the
# OVERRIDE path (not the fixed one) and captures the last line in NOTIFY_LINE.
# GIT_* scrubbed, HOME + GOLEM_ID pinned, mirroring run_notify (#405).
run_notify_status_dir() {
    local dir="$1" payload="$2" gid="$3" override="$4"
    local feed="$dir/$override/feed.jsonl"
    command rm -f "$feed"
    NOTIFY_RC=0
    (
        cd "$dir" &&
            command printf '%s' "$payload" |
            /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
                "${GOLEM_SCRUB[@]/#/--unset=}" \
                HOME="$dir" GOLEM_ID="$gid" GOLEM_STATUS_DIR="$override" \
                "$REAL_BASH" "$NOTIFY"
    ) >/dev/null 2>&1 || NOTIFY_RC=$?
    NOTIFY_LINE="$(command tail -n 1 "$feed" 2>/dev/null || true)"
}

# write_curl_stub <stub-dir>
# Drops a `curl` stub into <stub-dir> that the sink-fan-out tests prepend to PATH
# (so real jq/coreutils stay reachable while `command curl` in the hook resolves
# to this stub — no network). The stub parses the hook's exact invocation
#   curl -s -o /dev/null --connect-timeout T -m T -X POST -H '...' --data-raw L URL
# pulling out the `--data-raw` payload and the trailing http(s) URL. It optionally
# sleeps $STUB_SLEEP seconds (the never-block case simulates a hung endpoint) and,
# when $STUB_CAPTURE_DIR is set, records ONE file per request (line 1 = URL, line
# 2 = payload) via mktemp so concurrent backgrounded POSTs never collide.
write_curl_stub() {
    local stub="$1"
    command mkdir -p "$stub"
    command cat >"$stub/curl" <<'EOF'
#!/bin/sh
data=""
url=""
while [ $# -gt 0 ]; do
    case "$1" in
        --data-raw) data="$2"; shift 2 ;;
        -H | -X | --connect-timeout | -m | -o) shift 2 ;;
        http://* | https://*) url="$1"; shift ;;
        *) shift ;;
    esac
done
if [ -n "${STUB_SLEEP:-}" ] && [ "${STUB_SLEEP}" != "0" ]; then
    sleep "$STUB_SLEEP"
fi
if [ -n "${STUB_CAPTURE_DIR:-}" ]; then
    f="$(mktemp "$STUB_CAPTURE_DIR/req.XXXXXX")"
    printf '%s\n%s\n' "$url" "$data" >"$f"
fi
exit 0
EOF
    command chmod +x "$stub/curl"
}

# Feed line captured by run_notify_sinks (separate from NOTIFY_LINE so a test can
# read both if needed).
NOTIFY_FEED=""

# run_notify_sinks <sandbox> <payload> <golem_id> <sinks> <capture_dir> [sleep_s] [timeout]
# Runs the hook with GOLEM_EVENT_SINKS=<sinks> and the curl stub on PATH, so the
# HTTP fan-out fires against the stub instead of the network. <capture_dir> and
# <sleep_s> are handed to the stub via STUB_CAPTURE_DIR / STUB_SLEEP; [timeout]
# overrides GOLEM_EVENT_SINK_TIMEOUT (default left to the hook's inline 2s). GIT_*
# and GOLEM_* scrubbed exactly like run_notify, then GOLEM_EVENT_SINKS set after
# the scrub. Feed line captured in NOTIFY_FEED, exit code in NOTIFY_RC.
run_notify_sinks() {
    local dir="$1" payload="$2" gid="$3" sinks="$4" capdir="$5"
    local sleep_s="${6:-0}" timeout="${7:-2}"
    local feed="$dir/.worktrees/.status/feed.jsonl"
    local stub="$dir/stub-bin"
    command rm -f "$feed"
    write_curl_stub "$stub"
    NOTIFY_RC=0
    (
        cd "$dir" &&
            command printf '%s' "$payload" |
            /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
                "${GOLEM_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
                PATH="$stub:$PATH" HOME="$dir" GOLEM_ID="$gid" \
                GOLEM_EVENT_SINKS="$sinks" GOLEM_EVENT_SINK_TIMEOUT="$timeout" \
                STUB_CAPTURE_DIR="$capdir" STUB_SLEEP="$sleep_s" \
                "$REAL_BASH" "$NOTIFY"
    ) >/dev/null 2>&1 || NOTIFY_RC=$?
    NOTIFY_FEED="$(command tail -n 1 "$feed" 2>/dev/null || true)"
}
