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

# Resolve the real bash once so the no-jq case (which strips PATH) still finds an
# interpreter.
REAL_BASH="$(command -v bash)"

# Git's hook-exported environment — scrub per invocation so each sandbox is
# hermetic even under a pre-push hook (see validate-golem-scripts.sh).
GIT_SCRUB=(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
    GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES)

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
                /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
                    PATH="$stub" HOME="$dir" GOLEM_ID="$gid" \
                    "$REAL_BASH" "$NOTIFY"
        ) >/dev/null 2>&1 || NOTIFY_RC=$?
    else
        (
            cd "$dir" &&
                /usr/bin/printf '%s' "$payload" |
                /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
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
            /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" --unset=GOLEM_ID \
                HOME="$dir" \
                "$REAL_BASH" "$NOTIFY"
    ) >/dev/null 2>&1 || NOTIFY_RC=$?
    NOTIFY_LINE="$(/usr/bin/tail -n 1 "$feed" 2>/dev/null || true)"
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
    assert_true "printf '%s' '$NOTIFY_LINE' | jq -e . >/dev/null 2>&1" \
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
    assert_true "printf '%s' '$NOTIFY_LINE' | jq -e . >/dev/null 2>&1" \
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
    assert_true "printf '%s' '$NOTIFY_LINE' | jq -e . >/dev/null 2>&1" \
        "no-jq feed line is valid JSON"
    event="$(printf '%s' "$NOTIFY_LINE" | jq -r '.event' 2>/dev/null || true)"
    assert_equals "gate" "$event" "no-jq default message classifies as gate"
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
    assert_true "printf '%s' '$NOTIFY_LINE' | jq -e . >/dev/null 2>&1" \
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
    assert_true "printf '%s' '$NOTIFY_LINE' | jq -e . >/dev/null 2>&1" \
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
run_test test_classifier_gate_default "classifier: unrecognized message → gate default"
run_test test_classifier_askuserquestion_stays_gate "classifier: AskUserQuestion permission message → gate default (#321)"
run_test test_classifier_dead_end_beats_escalation "classifier: dead-end wins over escalation"
run_test test_no_jq_escaper_emits_valid_json "no-jq escaper: quote+backslash GOLEM_ID stays valid JSON"
run_test test_no_jq_still_writes_gate_line "no-jq: still writes a valid gate feed line, exits 0"
run_test test_golemid_issue_basename "golem-id: issue-N basename → golem-N"
run_test test_golemid_golem_passthrough "golem-id: golem-* basename passes through"
run_test test_golemid_placeholder "golem-id: unmatched basename → golem-? placeholder"
run_test test_golemid_issue_basename_from_subdir "golem-id: issue-N from a subdir → golem-N (cwd-independent)"

generate_report
