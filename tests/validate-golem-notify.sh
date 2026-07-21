#!/usr/bin/env bash
# Coverage for the golem Notification-hook producer
# plugins/workflow/hooks/golem-notify.sh (issue #221), which had ZERO tests.
#
# golem-notify.sh is the TTY-free channel that turns a Claude Code `Notification`
# hook firing into one JSON line on the orchestrator's feed. Two behaviours carry
# the risk a silent regression would ship unnoticed:
#   1. the event CLASSIFIER — a message is bucketed into gate|idle|escalation|
#      dead-end (dead-end before escalation before the gate default), so the
#      orchestrator can tell a real permission gate from a transient idle or a
#      judgement call. An inverted/reordered case arm would mislabel a block.
#   2. the no-jq JSON-ESCAPER — when jq is absent the hook hand-rolls the feed
#      line. It MUST still emit valid JSON for an adversarial identifier, or a
#      crafted value could break out of the string literal and corrupt the feed.
#
# Reachability note for the no-jq escaper: on the jq-less path the hook never
# parses `.message` from stdin (it stays the literal default "awaiting permission
# decision"), so the only attacker-influenceable field reaching the hand-rolled
# encoder is `$GOLEM_ID` (interpolated verbatim when it matches `golem-*`). This
# suite therefore drives the escaper through a GOLEM_ID carrying an embedded
# double-quote and backslash, and asserts the line is still valid JSON with the
# backslash dropped and the quote escaped — exactly what the encoder promises.
#
# Test shape mirrors tests/validate-golem-scripts.sh: each case runs the REAL
# hook inside a fresh `git init` sandbox under a module-level `mktemp -d`, with
# git's hook-exported environment scrubbed (GIT_DIR/…): unscrubbed, they pin the
# hook's git-common-dir to the OUTER repo when the suite runs from a `git push`
# pre-push hook, so the feed would land in the librarian checkout, not the
# sandbox (the failure mode root-caused in golem-gate-watch, PR #62). HOME is
# repointed at the sandbox defensively; the hook writes only under the sandbox.
#
# Pure bash + coreutils + git (+ jq for the classifier/validation cases, which
# skip cleanly when jq is absent), reached via absolute /usr/bin/* paths per
# project convention. Uses the shared harness assertions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NOTIFY="$REPO_ROOT/plugins/workflow/hooks/golem-notify.sh"

# config.sh is the SINGLE SOURCE the hook's inlined GOLEM_WORKTREE_DIR /
# GOLEM_STATUS_DIR default chain is copied from (deliberately not sourced — see
# the hook header). The drift guard below pins the two together (#424).
CONFIG_SH="$REPO_ROOT/plugins/workflow/scripts/config.sh"

# Resolve the real bash once so the no-jq case (which strips PATH) still finds an
# interpreter.
REAL_BASH="$(command -v bash)"

# Git's hook-exported environment — scrub per invocation so each sandbox is
# hermetic even under a pre-push hook (see validate-golem-scripts.sh).
GIT_SCRUB=(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
    GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES)

# The hook now resolves its feed under GOLEM_STATUS_DIR / GOLEM_WORKTREE_DIR
# (#405). Every default-path helper below expects the unset default
# (.worktrees/.status), so scrub both from the child env — otherwise an operator
# (or this worktree, which exports GOLEM_STATUS_DIR) running the suite with an
# override set would redirect the feed out from under the fixed read-back path
# and fail the whole suite. The override test sets GOLEM_STATUS_DIR explicitly
# after this scrub, so it is unaffected.
#
# GOLEM_EVENT_SINKS / GOLEM_EVENT_SINK_TIMEOUT (#406) are scrubbed for the same
# reason: an operator (or this worktree) running the suite with a sink configured
# would fire real network POSTs from every default-path case and could fail the
# no-network assertion. The sink-fan-out tests set GOLEM_EVENT_SINKS explicitly
# after this scrub, so they are unaffected.
GOLEM_SCRUB=(GOLEM_STATUS_DIR GOLEM_WORKTREE_DIR GOLEM_EVENT_SINKS GOLEM_EVENT_SINK_TIMEOUT)

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "golem-notify.sh Notification hook (#221)"

# --- Sandbox plumbing -------------------------------------------------------

# Module-level scratch dir, cleaned up once when the suite exits.
WORKDIR="$(/usr/bin/mktemp -d)"
trap '/usr/bin/rm -rf "$WORKDIR"' EXIT

# new_sandbox <varname>
# A fresh `git init` repo with a `.worktrees/.status/` dir. golem-notify.sh
# resolves its feed under <repo-root>/.worktrees/.status/feed.jsonl via
# git-common-dir, so a bare init (no commit needed) is enough. Assigns the
# sandbox path to the caller's named variable.
new_sandbox() {
    local __out="$1" dir
    dir="$(/usr/bin/mktemp -d "$WORKDIR/sandbox.XXXXXX")" || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$dir" init -q 2>/dev/null || return 1
    /usr/bin/mkdir -p "$dir/.worktrees/.status"
    printf -v "$__out" '%s' "$dir"
}

# new_named_sandbox <varname> <name>
# Like new_sandbox, but the sandbox dir gets a CHOSEN basename ($WORKDIR/<name>)
# instead of a random `sandbox.XXXXXX`. The golem-id fallback (branch 2) keys off
# the worktree-root basename (`git rev-parse --show-toplevel`), so a deterministic
# name is what lets a test assert the derived `issue-N -> golem-N` / `golem-*`
# pass-through / `golem-?` placeholder outcome. Assigns the path to the caller's
# named variable.
new_named_sandbox() {
    local __out="$1" name="$2" dir="$WORKDIR/$2"
    /usr/bin/mkdir -p "$dir" || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        /usr/bin/git -C "$dir" init -q 2>/dev/null || return 1
    /usr/bin/mkdir -p "$dir/.worktrees/.status"
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
    /usr/bin/rm -f "$feed"
    NOTIFY_RC=0
    if [ "$mode" = "nojq" ]; then
        local stub="$dir/stub-bin"
        /usr/bin/mkdir -p "$stub"
        /usr/bin/ln -sf "$REAL_BASH" "$stub/bash"
        (
            cd "$dir" &&
                /usr/bin/printf '%s' "$payload" |
                /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
                    "${GOLEM_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
                    PATH="$stub" HOME="$dir" GOLEM_ID="$gid" \
                    "$REAL_BASH" "$NOTIFY"
        ) >/dev/null 2>&1 || NOTIFY_RC=$?
    else
        (
            cd "$dir" &&
                /usr/bin/printf '%s' "$payload" |
                /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
                    "${GOLEM_SCRUB[@]/#/--unset=}" \
                    HOME="$dir" GOLEM_ID="$gid" \
                    "$REAL_BASH" "$NOTIFY"
        ) >/dev/null 2>&1 || NOTIFY_RC=$?
    fi
    NOTIFY_LINE="$(/usr/bin/tail -n 1 "$feed" 2>/dev/null || true)"
}

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
    /usr/bin/rm -f "$feed"
    if [ -n "$sub" ]; then
        /usr/bin/mkdir -p "$dir/$sub"
        rundir="$dir/$sub"
    fi
    NOTIFY_RC=0
    (
        cd "$rundir" &&
            /usr/bin/printf '%s' "$payload" |
            /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
                "${GOLEM_SCRUB[@]/#/--unset=}" --unset=GOLEM_ID \
                HOME="$dir" \
                "$REAL_BASH" "$NOTIFY"
    ) >/dev/null 2>&1 || NOTIFY_RC=$?
    NOTIFY_LINE="$(/usr/bin/tail -n 1 "$feed" 2>/dev/null || true)"
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
    /usr/bin/rm -f "$feed"
    NOTIFY_RC=0
    (
        cd "$dir" &&
            /usr/bin/printf '%s' "$payload" |
            /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
                "${GOLEM_SCRUB[@]/#/--unset=}" \
                HOME="$dir" GOLEM_ID="$gid" GOLEM_STATUS_DIR="$override" \
                "$REAL_BASH" "$NOTIFY"
    ) >/dev/null 2>&1 || NOTIFY_RC=$?
    NOTIFY_LINE="$(/usr/bin/tail -n 1 "$feed" 2>/dev/null || true)"
}

# run_notify_worktree_dir <sandbox> <payload> <golem_id> <worktree_override>
# Like run_notify_status_dir, but exports ONLY GOLEM_WORKTREE_DIR (leaving
# GOLEM_STATUS_DIR unset after the GOLEM_SCRUB) so the hook's SECOND `:=` composes
# the status dir from the worktree dir: `${GOLEM_WORKTREE_DIR}/.status`. Reads the
# feed back at the COMPOSED path <sandbox>/<worktree_override>/.status/feed.jsonl,
# exercising the branch neither the both-unset default nor the
# GOLEM_STATUS_DIR-set-directly override reaches (#424).
run_notify_worktree_dir() {
    local dir="$1" payload="$2" gid="$3" wt="$4"
    local feed="$dir/$wt/.status/feed.jsonl"
    /usr/bin/rm -f "$feed"
    NOTIFY_RC=0
    (
        cd "$dir" &&
            /usr/bin/printf '%s' "$payload" |
            /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
                "${GOLEM_SCRUB[@]/#/--unset=}" \
                HOME="$dir" GOLEM_ID="$gid" GOLEM_WORKTREE_DIR="$wt" \
                "$REAL_BASH" "$NOTIFY"
    ) >/dev/null 2>&1 || NOTIFY_RC=$?
    NOTIFY_LINE="$(/usr/bin/tail -n 1 "$feed" 2>/dev/null || true)"
}

# --- HTTP sink fan-out plumbing (GOLEM_EVENT_SINKS, #406) --------------------

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
    /usr/bin/mkdir -p "$stub"
    /usr/bin/cat >"$stub/curl" <<'EOF'
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
    /usr/bin/chmod +x "$stub/curl"
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
    /usr/bin/rm -f "$feed"
    write_curl_stub "$stub"
    NOTIFY_RC=0
    (
        cd "$dir" &&
            /usr/bin/printf '%s' "$payload" |
            /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
                "${GOLEM_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
                PATH="$stub:$PATH" HOME="$dir" GOLEM_ID="$gid" \
                GOLEM_EVENT_SINKS="$sinks" GOLEM_EVENT_SINK_TIMEOUT="$timeout" \
                STUB_CAPTURE_DIR="$capdir" STUB_SLEEP="$sleep_s" \
                "$REAL_BASH" "$NOTIFY"
    ) >/dev/null 2>&1 || NOTIFY_RC=$?
    NOTIFY_FEED="$(/usr/bin/tail -n 1 "$feed" 2>/dev/null || true)"
}

# poll_capture_count <capture_dir> <want> — bounded wait (~3s) for <want> stub
# request files to appear. The hook backgrounds each POST, so the capture files
# land asynchronously; this replaces a fixed sleep with a bounded poll.
poll_capture_count() {
    local capdir="$1" want="$2" tries=0 n
    while [ "$tries" -lt 30 ]; do
        n="$(/usr/bin/ls -1 "$capdir" 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
        [ "$n" -ge "$want" ] && return 0
        sleep 0.1
        tries=$((tries + 1))
    done
    return 0
}

# --- Classifier (jq path) ---------------------------------------------------

# assert_event <payload> <expected-event> <desc>
# Runs the hook (jq present), asserts exit 0, a valid-JSON feed line, and the
# classified `.event`.
assert_event() {
    local payload="$1" want="$2" desc="$3" sb got
    new_sandbox sb
    run_notify "$sb" "$payload" "golem-1"
    assert_exit 0 "$NOTIFY_RC" "hook exits 0 ($desc)"
    assert_valid_json "$NOTIFY_LINE" \
        "feed line is valid JSON ($desc)"
    got="$(printf '%s' "$NOTIFY_LINE" | jq -r '.event' 2>/dev/null || true)"
    assert_equals "$want" "$got" "classified as $want ($desc)"
}

test_classifier_idle() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (classifier + JSON validation need jq)"
        return 0
    fi
    assert_event '{"message":"Claude is waiting for your input"}' "idle" \
        "waiting-for-input"
}

# The second idle arm — "waiting for input" WITHOUT "your" — matches only
# golem-notify.sh's line-85 case, never line 84. Pins it distinctly so a
# dropped/reordered/typo'd arm 2 (which would fall through to the gate default
# and falsely report a golem as BLOCKED) fails here. (#251)
test_classifier_idle_no_your() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (classifier + JSON validation need jq)"
        return 0
    fi
    assert_event '{"message":"Claude is waiting for input"}' "idle" \
        "waiting-for-input (no \"your\") → arm 2"
}

test_classifier_escalation() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (classifier + JSON validation need jq)"
        return 0
    fi
    assert_event '{"message":"ESCALATION: reuse the state file or a sidecar?"}' \
        "escalation" "ESCALATION: prefix"
}

test_classifier_dead_end() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (classifier + JSON validation need jq)"
        return 0
    fi
    assert_event '{"message":"DEAD-END: CI still red after ci-fixer exhausted"}' \
        "dead-end" "DEAD-END: prefix"
}

# A RESOLVED:-prefixed message (synthesized by golem-resolve.sh after the
# orchestrator's send-keys plan-approval) classifies as `resolved` — the
# explicit clearing kind that supersedes a stale gate on the next sweep (#422).
test_classifier_resolved() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (classifier + JSON validation need jq)"
        return 0
    fi
    assert_event '{"message":"RESOLVED: plan gate approved via send-keys"}' \
        "resolved" "RESOLVED: prefix → resolved (#422)"
}

# CRITICAL (#422 pre-PR review): `resolved:` is anchored to the message START, so
# a GENUINE permission gate whose message merely CONTAINS "resolved:" mid-string
# — ordinary command/commit text like `git commit -m '… mark resolved: …'` — must
# stay `gate`, NOT be misclassified as `resolved`. A `resolved` misclassification
# would drop a real pending gate from the BLOCKED set (resolved, like idle, is
# excluded), silently hiding a human decision — the exact failure #422 prevents,
# inverted. `unresolved:` (which contains the substring `resolved:`) is the
# adversarial case an unanchored match would also wrongly catch. This pins the
# prefix anchor: an unanchored `*"resolved:"*` regresses both assertions.
test_classifier_resolved_midmessage_stays_gate() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (classifier + JSON validation need jq)"
        return 0
    fi
    assert_event '{"message":"Claude needs your permission to run: git commit -m \"fix: mark issue as resolved: closes #99\""}' \
        "gate" "a real gate with mid-message 'resolved:' stays gate, not masked (#422)"
    assert_event '{"message":"Claude needs permission: merge conflicts unresolved: check file.py"}' \
        "gate" "'unresolved:' substring does not mask a real gate (#422)"
}

# A REAPED:-prefixed message (emitted by worktree-rm.sh after teardown) classifies
# as `reaped` — the terminal kind that supersedes a torn-down golem's stale gate on
# the next sweep so it does not ghost on the BLOCKED list (#446).
test_classifier_reaped() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (classifier + JSON validation need jq)"
        return 0
    fi
    assert_event '{"message":"REAPED: worktree/session for golem-7 torn down"}' \
        "reaped" "REAPED: prefix → reaped (#446)"
}

# CRITICAL (#446, mirrors the #422 resolved-anchoring test): `reaped:` is anchored
# to the message START, so a GENUINE permission gate whose message merely CONTAINS
# "reaped:" mid-string must stay `gate`, NOT be misclassified as `reaped`. A
# `reaped` misclassification would drop a real pending gate from the BLOCKED set
# (reaped, like idle/resolved, is excluded), silently hiding a human decision. This
# pins the prefix anchor: an unanchored `*"reaped:"*` regresses the assertion.
test_classifier_reaped_midmessage_stays_gate() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (classifier + JSON validation need jq)"
        return 0
    fi
    assert_event '{"message":"Claude needs your permission to run: echo \"files reaped: 3\""}' \
        "gate" "a real gate with mid-message 'reaped:' stays gate, not masked (#446)"
}

test_classifier_gate_default() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (classifier + JSON validation need jq)"
        return 0
    fi
    # An unrecognized permission-decision message falls through to the `gate`
    # default (fail loud: surface it rather than silently drop it as idle).
    assert_event '{"message":"Claude needs your permission to run git push"}' \
        "gate" "unrecognized permission message → gate default"
}

# An in-turn AskUserQuestion escalation fork carries NO stable, fork-specific
# signature this hook can key on (issue #321, deferred out of #257/PR #320):
# Claude Code surfaces such a fork via the SDK `canUseTool` callback, not a
# `Notification`, and a plain permission Notification's message is not
# machine-parseable and has no multi-option field. So an AskUserQuestion-style
# permission message MUST stay the fail-loud `gate` default here (only the
# deterministic `ESCALATION:` path is classified as escalation) — a future
# well-meaning heuristic that regressed this would mislabel routine permission
# gates as escalations. This pins that boundary (acceptance criterion 3).
test_classifier_askuserquestion_stays_gate() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (classifier + JSON validation need jq)"
        return 0
    fi
    assert_event '{"message":"Claude needs your permission to use AskUserQuestion"}' \
        "gate" "AskUserQuestion-style permission message → gate default (#321)"
}

# dead-end must win over escalation when BOTH markers are present (a dead-end IS
# an escalation that also blocks L4), because its case arm precedes escalation's.
test_classifier_dead_end_beats_escalation() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (classifier + JSON validation need jq)"
        return 0
    fi
    assert_event '{"message":"DEAD-END: ESCALATION: both markers present"}' \
        "dead-end" "dead-end precedence over escalation"
}

# --- No-jq JSON escaper -----------------------------------------------------

# On the jq-less path the escaper is the only thing standing between an
# adversarial GOLEM_ID and a corrupted feed. Feed a GOLEM_ID with an embedded
# double-quote AND backslash; the line must remain valid JSON, with the
# backslash dropped and the quote preserved as string DATA (not a delimiter).
# jq is required here only to VALIDATE the output — the hook itself runs with jq
# stubbed off its PATH.
test_no_jq_escaper_emits_valid_json() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (needed to validate the escaped JSON)"
        return 0
    fi
    local sb golem
    new_sandbox sb
    # GOLEM_ID matches golem-* so it is interpolated verbatim by the encoder.
    run_notify "$sb" '{"message":"unused on the no-jq path"}' 'golem-x"a\b' nojq
    assert_exit 0 "$NOTIFY_RC" "hook exits 0 on the no-jq path"
    assert_valid_json "$NOTIFY_LINE" \
        "the hand-rolled feed line is valid JSON despite a quote+backslash GOLEM_ID"
    golem="$(printf '%s' "$NOTIFY_LINE" | jq -r '.golem' 2>/dev/null || true)"
    # Backslash removed, embedded double-quote preserved as data.
    assert_equals 'golem-x"ab' "$golem" \
        "backslash dropped, embedded quote preserved as string data"
}

# The no-jq path still classifies via the message default and always exits 0 (the
# hook must NEVER block the golem). With no jq the message is the literal default,
# which is an unrecognized string → the `gate` default. Assert a valid gate line.
test_no_jq_still_writes_gate_line() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (needed to validate the escaped JSON)"
        return 0
    fi
    local sb event
    new_sandbox sb
    run_notify "$sb" '{"message":"ignored without jq"}' "golem-9" nojq
    assert_exit 0 "$NOTIFY_RC" "no-jq hook exits 0"
    assert_valid_json "$NOTIFY_LINE" \
        "no-jq feed line is valid JSON"
    event="$(printf '%s' "$NOTIFY_LINE" | jq -r '.event' 2>/dev/null || true)"
    assert_equals "gate" "$event" "no-jq default message classifies as gate"
}

# --- Status-dir resolution (GOLEM_STATUS_DIR override, #405) -----------------

# The emitter must resolve its feed path the same env-overridable way the reader
# scripts (golem-status.sh / golem-gate-watch.sh / golem-inbox.sh) do, so a
# GOLEM_STATUS_DIR override moves BOTH together. Before #405 the hook hardcoded
# .worktrees/.status, so an override silently split the feed path — gates written
# by the emitter would never surface to readers watching the override path.

# An override moves the emitter: the feed lands under the override dir, is valid
# JSON, and the legacy .worktrees/.status path is NOT written (proving the
# override MOVED the sink, not merely added a second one).
test_status_dir_override_honored() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (needed to validate the feed line)"
        return 0
    fi
    local sb
    new_sandbox sb
    run_notify_status_dir "$sb" \
        '{"message":"Claude needs your permission to run git push"}' \
        "golem-1" "custom-status"
    assert_exit 0 "$NOTIFY_RC" "hook exits 0 (GOLEM_STATUS_DIR override)"
    assert_valid_json "$NOTIFY_LINE" \
        "feed line under override dir is valid JSON"
    assert_true "[ -f '$sb/custom-status/feed.jsonl' ]" \
        "feed written under GOLEM_STATUS_DIR override (custom-status/feed.jsonl)"
    assert_true "[ ! -e '$sb/.worktrees/.status/feed.jsonl' ]" \
        "legacy .worktrees/.status/feed.jsonl NOT written — override moved the sink"
}

# With GOLEM_STATUS_DIR unset, the resolution is byte-for-byte unchanged: the
# feed still lands at .worktrees/.status. new_sandbox + run_notify (which do NOT
# set GOLEM_STATUS_DIR) already exercise the default path; this pins the
# acceptance criterion explicitly, guarding against a future default drift.
test_status_dir_default_unchanged() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (needed to validate the feed line)"
        return 0
    fi
    local sb
    new_sandbox sb
    run_notify "$sb" \
        '{"message":"Claude needs your permission to run git push"}' "golem-1"
    assert_exit 0 "$NOTIFY_RC" "hook exits 0 (GOLEM_STATUS_DIR unset)"
    assert_valid_json "$NOTIFY_LINE" "default-path feed line is valid JSON"
    assert_true "[ -f '$sb/.worktrees/.status/feed.jsonl' ]" \
        "GOLEM_STATUS_DIR unset still lands at .worktrees/.status (unchanged)"
}

# The COMPOSED-default branch: GOLEM_WORKTREE_DIR overridden while GOLEM_STATUS_DIR
# stays unset, so the hook's second `:=` expands `${GOLEM_WORKTREE_DIR}/.status`.
# Neither the both-unset default (test_status_dir_default_unchanged) nor the
# GOLEM_STATUS_DIR-set-directly override (test_status_dir_override_honored)
# exercises this composition. A regression that hardcoded `.status` under the repo
# root, or reordered the two `:=` lines, would pass the whole rest of the suite
# but fail here — the feed would NOT land at <override>/.status (#424, finding 2).
test_status_dir_composed_from_worktree_dir() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (needed to validate the feed line)"
        return 0
    fi
    local sb
    new_sandbox sb
    run_notify_worktree_dir "$sb" \
        '{"message":"Claude needs your permission to run git push"}' \
        "golem-1" "custom-wt"
    assert_exit 0 "$NOTIFY_RC" "hook exits 0 (GOLEM_WORKTREE_DIR-only override)"
    assert_valid_json "$NOTIFY_LINE" "composed-default feed line is valid JSON"
    assert_true "[ -f '$sb/custom-wt/.status/feed.jsonl' ]" \
        "GOLEM_STATUS_DIR unset composes feed under <GOLEM_WORKTREE_DIR>/.status"
    assert_true "[ ! -e '$sb/.worktrees/.status/feed.jsonl' ]" \
        "legacy .worktrees/.status NOT written — composition moved the sink"
}

# --- Drift guard: hook inlined defaults vs config.sh (#424, finding 1) -------

# The hook INLINES config.sh's GOLEM_WORKTREE_DIR / GOLEM_STATUS_DIR default chain
# verbatim (deliberately not sourced — sourcing config.sh would pull in its
# repo_root()/superproject probe and change the hook's own git-common-dir root
# resolution). Nothing else pins the two together: if config.sh's defaults change
# without a matching hook edit, emitter and readers silently split the feed path
# again — exactly the class #405 fixed, CI green throughout. This gate converts the
# hook's "lines 66,70" prose comment into an enforced invariant.
#
# It is an EQUIVALENCE assertion — the path the hook actually lands its feed at
# (both vars unset) must equal config.sh's own resolved GOLEM_STATUS_DIR default —
# so a drift introduced on EITHER side fails it, not just a config.sh change. The
# config.sh defaults are read in a GOLEM_SCRUB'd subshell so this worktree's own
# exported GOLEM_STATUS_DIR cannot leak in and mask a real divergence.
test_defaults_match_config_sh() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (needed to validate the feed line)"
        return 0
    fi
    local cfg_wt cfg_status
    cfg_wt="$(/usr/bin/env "${GOLEM_SCRUB[@]/#/--unset=}" "$REAL_BASH" -c \
        '. "$1"; printf "%s" "$GOLEM_WORKTREE_DIR"' _ "$CONFIG_SH" 2>/dev/null || true)"
    cfg_status="$(/usr/bin/env "${GOLEM_SCRUB[@]/#/--unset=}" "$REAL_BASH" -c \
        '. "$1"; printf "%s" "$GOLEM_STATUS_DIR"' _ "$CONFIG_SH" 2>/dev/null || true)"
    assert_equals ".worktrees" "$cfg_wt" \
        "config.sh resolves GOLEM_WORKTREE_DIR default to .worktrees"
    assert_equals ".worktrees/.status" "$cfg_status" \
        "config.sh resolves GOLEM_STATUS_DIR default to .worktrees/.status"

    # The hook, both vars unset, must land its feed at exactly config.sh's
    # resolved GOLEM_STATUS_DIR default (relative to the repo root).
    local sb
    new_sandbox sb
    run_notify "$sb" \
        '{"message":"Claude needs your permission to run git push"}' "golem-1"
    assert_exit 0 "$NOTIFY_RC" "hook exits 0 (drift-guard default path)"
    assert_true "[ -f '$sb/$cfg_status/feed.jsonl' ]" \
        "hook feed lands at config.sh's resolved GOLEM_STATUS_DIR default — no drift"
}

# Sibling drift guard for the #406 sink vars. golem-notify.sh INLINES config.sh's
# GOLEM_EVENT_SINKS / GOLEM_EVENT_SINK_TIMEOUT defaults (not sourced, same reason
# as above), and both files' comments claim this test pins the two equivalent.
# That claim must be TRUE: assert the value each side resolves with both vars
# unset is identical. config.sh is read in a GOLEM_SCRUB'd subshell (so this
# worktree's own exported values can't leak in); the hook's inlined defaults are
# read by sourcing ONLY its two `: "${GOLEM_EVENT_SINK*:=...}"` assignment lines
# in a scrubbed subshell — the same isolation the config.sh side uses, and enough
# to catch a one-sided default edit (e.g. bumping the timeout in config.sh but
# not the hook) that would otherwise stay green.
test_event_sink_defaults_match_config_sh() {
    local cfg_sinks cfg_timeout hook_sinks hook_timeout
    # config.sh side.
    cfg_sinks="$(/usr/bin/env "${GOLEM_SCRUB[@]/#/--unset=}" "$REAL_BASH" -c \
        '. "$1"; printf "%s" "$GOLEM_EVENT_SINKS"' _ "$CONFIG_SH" 2>/dev/null || true)"
    cfg_timeout="$(/usr/bin/env "${GOLEM_SCRUB[@]/#/--unset=}" "$REAL_BASH" -c \
        '. "$1"; printf "%s" "$GOLEM_EVENT_SINK_TIMEOUT"' _ "$CONFIG_SH" 2>/dev/null || true)"
    # Hook side: eval ONLY the two inlined sink-default lines (grep them out so we
    # do not run the whole hook), then print what they resolve to.
    local hook_defaults
    hook_defaults="$(/usr/bin/grep -E '^: "\$\{GOLEM_EVENT_SINK(S|_TIMEOUT):=' "$NOTIFY" || true)"
    hook_sinks="$(/usr/bin/env "${GOLEM_SCRUB[@]/#/--unset=}" "$REAL_BASH" -c \
        "$hook_defaults"'; printf "%s" "$GOLEM_EVENT_SINKS"' 2>/dev/null || true)"
    hook_timeout="$(/usr/bin/env "${GOLEM_SCRUB[@]/#/--unset=}" "$REAL_BASH" -c \
        "$hook_defaults"'; printf "%s" "$GOLEM_EVENT_SINK_TIMEOUT"' 2>/dev/null || true)"
    # Known defaults (guards against BOTH sides drifting together to a new value).
    assert_equals "" "$cfg_sinks" "config.sh GOLEM_EVENT_SINKS default is empty"
    assert_equals "2" "$cfg_timeout" "config.sh GOLEM_EVENT_SINK_TIMEOUT default is 2"
    # Equivalence: hook inlined defaults must match config.sh's (the drift guard).
    assert_equals "$cfg_sinks" "$hook_sinks" \
        "hook GOLEM_EVENT_SINKS default matches config.sh — no drift (#406)"
    assert_equals "$cfg_timeout" "$hook_timeout" \
        "hook GOLEM_EVENT_SINK_TIMEOUT default matches config.sh — no drift (#406)"
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
    /usr/bin/mkdir -p "$capdir"
    # Empty sinks list: the hook must not reach curl at all.
    run_notify_sinks "$sb" \
        '{"message":"Claude needs your permission to run git push"}' \
        "golem-1" "" "$capdir"
    assert_exit 0 "$NOTIFY_RC" "hook exits 0 (empty GOLEM_EVENT_SINKS)"
    assert_valid_json "$NOTIFY_FEED" "feed line still written (empty sinks)"
    poll_capture_count "$capdir" 1 # give any erroneous POST a chance to land
    n="$(/usr/bin/ls -1 "$capdir" 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
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
    /usr/bin/mkdir -p "$capdir"
    run_notify_sinks "$sb" \
        '{"message":"Claude needs your permission to run git push"}' \
        "golem-1" "http://127.0.0.1:9/a http://127.0.0.1:9/b" "$capdir"
    assert_exit 0 "$NOTIFY_RC" "hook exits 0 (two sinks)"
    assert_valid_json "$NOTIFY_FEED" "feed line written (two sinks, AC1)"
    poll_capture_count "$capdir" 2
    n="$(/usr/bin/ls -1 "$capdir" 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
    assert_equals "2" "$n" "both sinks received one POST each (AC1)"
    # Each capture file: line 1 = URL, line 2 = payload. Collect and compare.
    u1=""
    u2=""
    p1=""
    p2=""
    for f in "$capdir"/req.*; do
        [ -e "$f" ] || continue
        if [ -z "$u1" ]; then
            u1="$(/usr/bin/sed -n 1p "$f")"
            p1="$(/usr/bin/sed -n 2p "$f")"
        else
            u2="$(/usr/bin/sed -n 1p "$f")"
            p2="$(/usr/bin/sed -n 2p "$f")"
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
    /usr/bin/mkdir -p "$capdir"
    start="$(/usr/bin/date +%s)"
    # 30s stub sleep, 2s configured timeout: a blocking hook would wait ≥2s (or
    # 30s if it also awaited the child); a non-blocking one returns near-instantly.
    run_notify_sinks "$sb" \
        '{"message":"Claude needs your permission to run git push"}' \
        "golem-1" "http://127.0.0.1:9/slow" "$capdir" "30" "2"
    elapsed="$(($(/usr/bin/date +%s) - start))"
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
    /usr/bin/mkdir -p "$capdir"
    # A file:// entry (must be skipped) beside a valid https entry (must be hit).
    run_notify_sinks "$sb" \
        '{"message":"Claude needs your permission to run git push"}' \
        "golem-1" "file:///etc/passwd https://127.0.0.1:9/ok" "$capdir"
    assert_exit 0 "$NOTIFY_RC" "hook exits 0 (scheme guard)"
    poll_capture_count "$capdir" 1
    n="$(/usr/bin/ls -1 "$capdir" 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
    assert_equals "1" "$n" "only the https sink was POSTed; file:// entry skipped"
    u="$(/usr/bin/sed -n 1p "$capdir"/req.* 2>/dev/null || true)"
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
    /usr/bin/mkdir -p "$capdir"
    run_notify_sinks "$sb" \
        '{"message":"Claude needs your permission to run git push"}' \
        "golem-1" "http://127.0.0.1:9/a,http://127.0.0.1:9/b" "$capdir"
    assert_exit 0 "$NOTIFY_RC" "hook exits 0 (comma-separated sinks)"
    poll_capture_count "$capdir" 2
    n="$(/usr/bin/ls -1 "$capdir" 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
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
    /usr/bin/rm -f "$feed"
    # Hermetic PATH with bash only — no curl resolvable. The hook reaches its
    # other tools via absolute /usr/bin/* paths, so bash-only PATH is sufficient
    # (matching run_notify's nojq mode). jq is off this PATH too, but the hook's
    # jq branch uses `command -v jq` and falls back to the hand-rolled encoder, so
    # the feed line is still written; we read it back with the outer jq.
    stub="$sb/stub-nocurl"
    /usr/bin/mkdir -p "$stub"
    /usr/bin/ln -sf "$REAL_BASH" "$stub/bash"
    NOTIFY_RC=0
    (
        cd "$sb" &&
            /usr/bin/printf '%s' '{"message":"Claude needs your permission to run git push"}' |
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
    /usr/bin/mkdir -p "$capdir"
    write_curl_stub "$sb/stub-bin"
    stub="$sb/stub-bin"
    # A read-only parent dir: mkdir of <ro>/nope/.status must fail, so the feed
    # write is impossible, but the HTTP fan must still run.
    ro="$sb/readonly"
    /usr/bin/mkdir -p "$ro"
    /usr/bin/chmod 555 "$ro"
    NOTIFY_RC=0
    (
        cd "$sb" &&
            /usr/bin/printf '%s' '{"message":"Claude needs your permission to run git push"}' |
            /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
                "${GOLEM_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
                PATH="$stub:$PATH" HOME="$sb" GOLEM_ID="golem-1" \
                GOLEM_STATUS_DIR="readonly/nope/.status" \
                GOLEM_EVENT_SINKS="http://127.0.0.1:9/x" \
                STUB_CAPTURE_DIR="$capdir" STUB_SLEEP="0" \
                "$REAL_BASH" "$NOTIFY"
    ) >/dev/null 2>&1 || NOTIFY_RC=$?
    # Restore perms so the sandbox cleanup (rm -rf) can remove it.
    /usr/bin/chmod 755 "$ro" 2>/dev/null || true
    assert_exit 0 "$NOTIFY_RC" "hook exits 0 when the feed dir is unwritable"
    poll_capture_count "$capdir" 1
    local n
    n="$(/usr/bin/ls -1 "$capdir" 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
    assert_equals "1" "$n" \
        "HTTP sink still POSTed even though feed.jsonl was unwritable (#406 AC1)"
    assert_true "[ ! -f '$sb/readonly/nope/.status/feed.jsonl' ]" \
        "feed.jsonl indeed not written under the read-only parent"
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

# --- Run all tests ----------------------------------------------------------

# Every sandbox needs git. Gate it from inside a run_test-dispatched body so the
# counters stay consistent (skip_test is designed for within-test use).
git_unavailable() { ! command -v git >/dev/null 2>&1; }

test_git_available() {
    if git_unavailable; then
        skip_test "git not available — cannot build sandbox repos"
        return
    fi
    assert_true "command -v git" "git is available for sandbox construction"
}

run_test test_git_available "git is available (suite prerequisite)"

if git_unavailable; then
    generate_report
    exit $?
fi

run_test test_classifier_idle "classifier: waiting-for-input → idle"
run_test test_classifier_idle_no_your "classifier: waiting-for-input (no \"your\") → idle arm 2"
run_test test_classifier_escalation "classifier: ESCALATION: → escalation"
run_test test_classifier_dead_end "classifier: DEAD-END: → dead-end"
run_test test_classifier_resolved "classifier: RESOLVED: → resolved (#422)"
run_test test_classifier_resolved_midmessage_stays_gate "classifier: mid-message 'resolved:'/'unresolved:' stays gate, not masked (#422)"
run_test test_classifier_reaped "classifier: REAPED: → reaped (#446)"
run_test test_classifier_reaped_midmessage_stays_gate "classifier: mid-message 'reaped:' stays gate, not masked (#446)"
run_test test_classifier_gate_default "classifier: unrecognized message → gate default"
run_test test_classifier_askuserquestion_stays_gate "classifier: AskUserQuestion permission message → gate default (#321)"
run_test test_classifier_dead_end_beats_escalation "classifier: dead-end wins over escalation"
run_test test_no_jq_escaper_emits_valid_json "no-jq escaper: quote+backslash GOLEM_ID stays valid JSON"
run_test test_no_jq_still_writes_gate_line "no-jq: still writes a valid gate feed line, exits 0"
run_test test_status_dir_override_honored "status-dir: GOLEM_STATUS_DIR override moves the feed path (#405)"
run_test test_status_dir_default_unchanged "status-dir: GOLEM_STATUS_DIR unset still lands at .worktrees/.status (#405)"
run_test test_status_dir_composed_from_worktree_dir "status-dir: GOLEM_WORKTREE_DIR-only override composes <dir>/.status (#424)"
run_test test_defaults_match_config_sh "drift-guard: hook inlined defaults match config.sh (#424)"
run_test test_event_sink_defaults_match_config_sh "drift-guard: sink-var inlined defaults match config.sh (#406)"
run_test test_sinks_empty_no_network "sinks: empty GOLEM_EVENT_SINKS makes no curl call (#406 AC2)"
run_test test_sinks_fanout_same_payload "sinks: fan same payload to two sinks + feed (#406 AC1/AC4)"
run_test test_sinks_never_block "sinks: a hung sink never blocks the hook (#406 AC3)"
run_test test_sinks_scheme_guard "sinks: non-http(s) entry skipped, https sibling POSTed (#406)"
run_test test_sinks_comma_separated "sinks: comma-separated list fans to both sinks (#406)"
run_test test_sinks_curl_absent_degrades "sinks: curl absent + sinks set degrades gracefully (#406)"
run_test test_sinks_fire_when_feed_unwritable "sinks: HTTP fan fires even when feed dir unwritable (#406 AC1)"
run_test test_golemid_issue_basename "golem-id: issue-N basename → golem-N"
run_test test_golemid_golem_passthrough "golem-id: golem-* basename passes through"
run_test test_golemid_placeholder "golem-id: unmatched basename → golem-? placeholder"
run_test test_golemid_issue_basename_from_subdir "golem-id: issue-N from a subdir → golem-N (cwd-independent)"

generate_report
