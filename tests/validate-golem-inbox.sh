#!/usr/bin/env bash
# Coverage for the orchestrator-brokered gate reverse channel
# plugins/workflow/scripts/golem-inbox.sh (issue #227).
#
# golem-inbox.sh is the DOWN channel that mirrors the up-only push feed: the
# orchestrator writes an operator's escalation/dead-end decision into a
# per-golem inbox (inbox-<golem>.jsonl) with `answer`, and the golem reads it
# with a bounded-blocking `consume`. The behaviours whose silent regression
# would break the relay — or, worse, its safety invariants — are:
#   1. ROUND-TRIP — answer then consume returns "DECISION: <option>", marks the
#      gate consumed, and never re-returns it (idempotent consumption).
#   2. ATTRIBUTION — a decision for golem-N can NEVER be consumed by golem-M
#      (filename key) nor by a different gate (in-record `gate` filter). This is
#      acceptance criterion 2; a regression here mis-delivers a decision.
#   3. NEVER-DEFAULT — with no matching answer, consume prints exactly
#      "NO-DECISION" and never a fabricated option. This is what preserves the
#      never-time-out rule (the golem re-invokes on the sentinel); a regression
#      that returned a default would silently resolve a human gate.
#   4. NO-JQ JSON — when jq is absent, `answer` still writes valid JSON for an
#      adversarial option (quote+backslash) and `consume` reads it back exactly,
#      so a crafted decision can neither corrupt the inbox nor be mis-parsed.
#
# Test shape mirrors tests/validate-golem-notify.sh: each case runs the REAL
# script inside a fresh `git init` sandbox under a module-level `mktemp -d`, with
# git's hook-exported environment scrubbed (GIT_DIR/…) so a pre-push-hook run
# stays hermetic, and HOME repointed at the sandbox. GOLEM_STATUS_DIR is pinned
# to the sandbox's .worktrees/.status. Unlike golem-notify.sh, this script
# resolves the repo root through config.sh's repo_root() (which uses
# `command git`, PATH-resolved per #278), so the no-jq PATH stub must keep git
# AND env on PATH — stripping to bash-only would make repo_root() return empty
# and the script would abort "not inside a git repository" before ever reaching
# the escaper. The stub therefore drops ONLY jq.
#
# Pure bash + coreutils + git (+ jq for the JSON-validation cases, which skip
# cleanly when jq is absent), reached via absolute /usr/bin/* paths per project
# convention. Uses the shared harness assertions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INBOX="$REPO_ROOT/plugins/workflow/scripts/golem-inbox.sh"

# Resolve the real bash / git / env once so the no-jq case (which swaps PATH for
# a stub) still finds them.
REAL_BASH="$(command -v bash)"
REAL_GIT="$(command -v git 2>/dev/null || true)"
REAL_ENV="$(command -v env)"

# Git's hook-exported environment — scrub per invocation so each sandbox is
# hermetic even under a pre-push hook (see validate-golem-notify.sh).
GIT_SCRUB=(GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR
    GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES)

# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"

test_suite "golem-inbox.sh brokered gate reverse channel (#227)"

# --- Sandbox plumbing -------------------------------------------------------

# Module-level scratch dir, cleaned up once when the suite exits.
WORKDIR="$(command mktemp -d)"
trap 'command rm -rf "$WORKDIR"' EXIT

# new_sandbox <varname>
# A fresh `git init` repo with a `.worktrees/.status/` dir. golem-inbox.sh
# resolves the inbox under <repo-root>/<GOLEM_STATUS_DIR>/inbox-<golem>.jsonl via
# repo_root() (git-common-dir), so a bare init (no commit needed) is enough.
new_sandbox() {
    local __out="$1" dir
    dir="$(command mktemp -d "$WORKDIR/sandbox.XXXXXX")" || return 1
    /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
        git -C "$dir" init -q 2>/dev/null || return 1
    command mkdir -p "$dir/.worktrees/.status"
    printf -v "$__out" '%s' "$dir"
}

# Results of the most recent invocation.
INBOX_RC=0
INBOX_OUT=""

# run_inbox <sandbox> <arg...>
# Run the script from inside the sandbox with GIT_* scrubbed, HOME + the status
# dir pinned. Captures the exit code in INBOX_RC and combined stdout+stderr in
# INBOX_OUT. jq is left on PATH (the default runtime).
run_inbox() {
    local dir="$1"
    shift
    INBOX_RC=0
    INBOX_OUT="$(
        cd "$dir" &&
            /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
                HOME="$dir" \
                GOLEM_WORKTREE_DIR=.worktrees \
                GOLEM_STATUS_DIR=.worktrees/.status \
                GOLEM_INBOX_WAIT=0 GOLEM_INBOX_POLL=1 \
                "$REAL_BASH" "$INBOX" "$@" 2>&1
    )" || INBOX_RC=$?
}

# run_inbox_nojq <sandbox> <arg...>
# Like run_inbox but with a hermetic PATH holding only bash, git, and env — so
# `command -v jq` fails and the hand-rolled JSON escaper / grep reader are taken.
# git + env MUST stay on PATH (config.sh repo_root uses `git`). BASH_ENV
# is unset for the child: this devcontainer's /etc/bash_env resets $PATH there,
# which would silently undo the stub PATH.
run_inbox_nojq() {
    local dir="$1"
    shift
    local stub="$dir/stub-bin"
    command mkdir -p "$stub"
    command ln -sf "$REAL_BASH" "$stub/bash"
    command ln -sf "$REAL_GIT" "$stub/git"
    command ln -sf "$REAL_ENV" "$stub/env"
    INBOX_RC=0
    INBOX_OUT="$(
        cd "$dir" &&
            /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" --unset=BASH_ENV \
                PATH="$stub" HOME="$dir" \
                GOLEM_WORKTREE_DIR=.worktrees \
                GOLEM_STATUS_DIR=.worktrees/.status \
                GOLEM_INBOX_WAIT=0 GOLEM_INBOX_POLL=1 \
                "$REAL_BASH" "$INBOX" "$@" 2>&1
    )" || INBOX_RC=$?
}

# A fixed valid gate id for round-trip cases (mirrors the minted shape).
GATE="gate-1784398516-abcd"
GATE2="gate-1784398517-ef01"

# --- gateid -----------------------------------------------------------------

# gateid prints gate-<digits>-<alnum> and two calls differ (the id must be
# unique enough to correlate one escalation to one answer).
test_gateid_format_and_uniqueness() {
    local sb a b
    new_sandbox sb
    run_inbox "$sb" gateid
    assert_exit 0 "$INBOX_RC" "gateid exits 0"
    a="$INBOX_OUT"
    case "$a" in
        gate-[0-9]*-[0-9a-f]*) assert_true "true" "gateid matches gate-<digits>-<hex> ($a)" ;;
        *) _fail "gateid format unexpected: $a" ;;
    esac
    # RANDOM differs between two invocations of a fresh shell; assert distinct.
    run_inbox "$sb" gateid
    b="$INBOX_OUT"
    if [ "$a" = "$b" ]; then
        _fail "two gateid calls returned the same id ($a)"
    else
        assert_true "true" "two gateid calls differ ($a vs $b)"
    fi
}

# --- round-trip -------------------------------------------------------------

# answer then consume returns the option, writes a valid-JSON answer line + a
# `consumed` marker, and exits 0.
test_roundtrip_answer_then_consume() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (validates the inbox line as JSON)"
        return 0
    fi
    local sb inbox
    new_sandbox sb
    run_inbox "$sb" answer golem-3 "$GATE" B --note "go with sidecar"
    assert_exit 0 "$INBOX_RC" "answer exits 0"
    inbox="$sb/.worktrees/.status/inbox-golem-3.jsonl"
    assert_file_exists "$inbox" "answer created inbox-golem-3.jsonl"
    assert_valid_json "$(command tail -n 1 "$inbox")" "answer line is valid JSON"

    run_inbox "$sb" consume golem-3 "$GATE"
    assert_exit 0 "$INBOX_RC" "consume exits 0"
    assert_contains "$INBOX_OUT" "DECISION: B" "consume returns DECISION: B"
    assert_contains "$INBOX_OUT" "NOTE: go with sidecar" "consume returns the note"
    assert_file_contains "$inbox" '"event":"consumed"' "consume appended a consumed marker"
}

# The note is optional: with none, consume prints DECISION but no NOTE line.
test_roundtrip_no_note() {
    local sb
    new_sandbox sb
    run_inbox "$sb" answer golem-3 "$GATE" A
    assert_exit 0 "$INBOX_RC" "answer (no note) exits 0"
    run_inbox "$sb" consume golem-3 "$GATE"
    assert_contains "$INBOX_OUT" "DECISION: A" "consume returns DECISION: A"
    assert_not_contains "$INBOX_OUT" "NOTE:" "no NOTE line when note is empty"
}

# --- attribution (acceptance criterion 2) -----------------------------------

# A decision written to golem-3 is NEVER returned by consume golem-4 (different
# inbox file — the filesystem layer of the two-layer attribution).
test_wrong_golem_isolation() {
    local sb
    new_sandbox sb
    run_inbox "$sb" answer golem-3 "$GATE" B
    assert_exit 0 "$INBOX_RC" "answer to golem-3 exits 0"
    run_inbox "$sb" consume golem-4 "$GATE"
    assert_exit 0 "$INBOX_RC" "consume golem-4 exits 0"
    assert_equals "NO-DECISION" "$INBOX_OUT" \
        "golem-4 never sees golem-3's decision (cross-golem isolation)"
}

# A decision for GATE is NEVER returned by consume for a different gate (the
# in-record `gate` filter — the second attribution layer, so a stale answer in
# the right file for the wrong gate is still rejected).
test_wrong_gate_rejection() {
    local sb
    new_sandbox sb
    run_inbox "$sb" answer golem-3 "$GATE" B
    run_inbox "$sb" consume golem-3 "$GATE2"
    assert_equals "NO-DECISION" "$INBOX_OUT" \
        "a decision for one gate is not consumed for another gate"
}

# --- latest-wins + idempotent consumption -----------------------------------

# Two answers for the same gate: consume returns the most recent option (the
# operator corrected their choice before the golem read it).
test_latest_answer_wins() {
    local sb
    new_sandbox sb
    run_inbox "$sb" answer golem-6 "$GATE" FIRST
    run_inbox "$sb" answer golem-6 "$GATE" SECOND
    run_inbox "$sb" consume golem-6 "$GATE"
    assert_contains "$INBOX_OUT" "DECISION: SECOND" "consume returns the latest answer"
    assert_not_contains "$INBOX_OUT" "DECISION: FIRST" "the superseded answer is not returned"
}

# After a successful consume, a second consume of the SAME gate does not
# re-return the stale decision — the `consumed` marker supersedes the answer.
test_consumed_not_replayed() {
    local sb
    new_sandbox sb
    run_inbox "$sb" answer golem-6 "$GATE" B
    run_inbox "$sb" consume golem-6 "$GATE"
    assert_contains "$INBOX_OUT" "DECISION: B" "first consume returns the decision"
    run_inbox "$sb" consume golem-6 "$GATE"
    assert_equals "NO-DECISION" "$INBOX_OUT" \
        "a second consume of a consumed gate returns NO-DECISION (idempotent)"
}

# --- never-default (preserves the never-time-out rule) ----------------------

# With no answer present and a 0s wait, consume prints EXACTLY "NO-DECISION" and
# never a fabricated option. This is the property the golem-side re-invoke loop
# relies on to wait indefinitely without ever lapse-and-defaulting.
test_no_default_guarantee() {
    local sb
    new_sandbox sb
    # Pin the wait to 0 so the case is fast and deterministic (no answer exists).
    INBOX_RC=0
    INBOX_OUT="$(
        cd "$sb" &&
            /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
                HOME="$sb" GOLEM_STATUS_DIR=.worktrees/.status GOLEM_INBOX_WAIT=0 \
                "$REAL_BASH" "$INBOX" consume golem-9 "$GATE" 2>&1
    )" || INBOX_RC=$?
    assert_exit 0 "$INBOX_RC" "consume with no answer exits 0"
    assert_equals "NO-DECISION" "$INBOX_OUT" \
        "no answer → exactly NO-DECISION, never a fabricated option"
}

# --- late answer caught on re-invoke (the wait-indefinitely loop) -----------

# The "wait indefinitely" contract is an agent-level re-invoke loop: a consume
# that returned NO-DECISION, re-invoked after the operator answers, catches the
# late decision. Simulate the second invocation after the answer lands.
test_late_answer_caught_on_reinvoke() {
    local sb
    new_sandbox sb
    # First consume: no answer yet → NO-DECISION (the loop would re-invoke).
    INBOX_OUT="$(
        cd "$sb" &&
            /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
                HOME="$sb" GOLEM_STATUS_DIR=.worktrees/.status GOLEM_INBOX_WAIT=0 \
                "$REAL_BASH" "$INBOX" consume golem-2 "$GATE" 2>&1
    )" || true
    assert_equals "NO-DECISION" "$INBOX_OUT" "first consume: NO-DECISION (nothing yet)"
    # Operator answers, then the golem re-invokes consume → catches it.
    run_inbox "$sb" answer golem-2 "$GATE" C
    run_inbox "$sb" consume golem-2 "$GATE"
    assert_contains "$INBOX_OUT" "DECISION: C" \
        "re-invoked consume catches the late answer (wait-indefinitely loop)"
}

# A non-integer GOLEM_INBOX_POLL/WAIT must FAIL SAFE (fall back to a numeric
# default), not turn the bounded poll into an infinite hot spin. Here an ANSWER
# is present, so a correctly-sanitized consume returns it immediately regardless
# of the garbage tunables; a regression that let the arithmetic error out would
# never break the loop and this case would hang (caught by the suite timeout).
test_non_integer_tunables_fail_safe() {
    local sb
    new_sandbox sb
    run_inbox "$sb" answer golem-8 "$GATE" B
    INBOX_RC=0
    INBOX_OUT="$(
        cd "$sb" &&
            /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
                HOME="$sb" GOLEM_STATUS_DIR=.worktrees/.status \
                GOLEM_INBOX_WAIT=abc GOLEM_INBOX_POLL=xyz \
                "$REAL_BASH" "$INBOX" consume golem-8 "$GATE" 2>&1
    )" || INBOX_RC=$?
    assert_exit 0 "$INBOX_RC" "consume with garbage tunables exits 0"
    assert_contains "$INBOX_OUT" "DECISION: B" \
        "garbage tunables fall back to a numeric default (no infinite spin, no arithmetic error)"
}

# A LEADING-ZERO tunable (e.g. GOLEM_INBOX_POLL=08) is all-digits, so the
# non-integer guard above lets it through — but bash arithmetic `$(( ))` parses a
# leading 0 as OCTAL, where 8/9 are invalid digits, so `elapsed` would never
# advance and `consume` would hang past its ceiling forever. The `10#` base-10
# normalization must neutralize this. An ANSWER is present, so a correct consume
# returns it immediately; a regression (octal parse) hangs, tripping the suite
# timeout. Uses POLL=08 (invalid octal) with a matching WAIT=08 to pin both.
test_leading_zero_tunables_base10() {
    local sb
    new_sandbox sb
    run_inbox "$sb" answer golem-8 "$GATE" C
    INBOX_RC=0
    INBOX_OUT="$(
        cd "$sb" &&
            /usr/bin/env "${GIT_SCRUB[@]/#/--unset=}" \
                HOME="$sb" GOLEM_STATUS_DIR=.worktrees/.status \
                GOLEM_INBOX_WAIT=08 GOLEM_INBOX_POLL=08 \
                "$REAL_BASH" "$INBOX" consume golem-8 "$GATE" 2>&1
    )" || INBOX_RC=$?
    assert_exit 0 "$INBOX_RC" "consume with leading-zero tunables exits 0"
    assert_contains "$INBOX_OUT" "DECISION: C" \
        "leading-zero tunables are read base-10, not octal (no hang on the 8/9 digit)"
}

# The jq-path reader must be RESILIENT to a single malformed line: the inbox is
# an append-only file grown by potentially-interrupted writers, so a torn line
# can appear anywhere. A whole-file `jq '…' file` aborts on the first bad line
# and silently truncates every record after it — replaying a stale decision past
# its `consumed` marker, or hiding a corrected answer. The per-line
# `fromjson?`/inputs read must skip the bad line instead.
test_corrupt_line_does_not_truncate_reader() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (this pins the jq-path resilience specifically)"
        return 0
    fi
    local sb inbox
    new_sandbox sb
    inbox="$sb/.worktrees/.status/inbox-golem-3.jsonl"
    # (a) latest-wins survives a corrupt line between two answers.
    run_inbox "$sb" answer golem-3 "$GATE" FIRST
    printf 'CORRUPT{not valid json\n' >>"$inbox"
    run_inbox "$sb" answer golem-3 "$GATE" SECOND
    run_inbox "$sb" consume golem-3 "$GATE"
    assert_contains "$INBOX_OUT" "DECISION: SECOND" \
        "a corrupt line before the latest answer does not hide it (jq-path resilience)"
    # (b) idempotent consumption survives a corrupt line after the consumed marker.
    run_inbox "$sb" answer golem-3 "$GATE2" B
    run_inbox "$sb" consume golem-3 "$GATE2" # marks consumed
    printf 'TORN{\n' >>"$inbox"
    run_inbox "$sb" consume golem-3 "$GATE2"
    assert_equals "NO-DECISION" "$INBOX_OUT" \
        "a corrupt line does not resurrect a consumed decision (idempotency preserved)"
}

# A line that is VALID JSON but a non-object scalar (a bare `42`, `true`, `[]`)
# is a distinct corruption class from unparsable garbage: `fromjson?` parses it
# fine, but indexing it with `.golem` aborts the whole jq pipeline unless it is
# filtered by `select(type == "object")`. Without that guard, `state`/`consume`
# silently degrade (a live answer reads `awaiting`, a real decision becomes
# unreachable) — and the jq path diverges from the always-resilient no-jq scanner.
# This pins consume + state across all three scalar shapes.
test_non_object_scalar_line_resilience() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (this pins the jq-path type guard specifically)"
        return 0
    fi
    local sb inbox
    new_sandbox sb
    inbox="$sb/.worktrees/.status/inbox-golem-3.jsonl"
    run_inbox "$sb" answer golem-3 "$GATE" YES
    # Inject each non-object scalar shape as its own raw line.
    printf '42\ntrue\n[]\n"a string"\n' >>"$inbox"
    run_inbox "$sb" state golem-3 "$GATE"
    assert_equals "answered" "$INBOX_OUT" \
        "state folds correctly past non-object scalar lines (jq type guard)"
    run_inbox "$sb" consume golem-3 "$GATE"
    assert_contains "$INBOX_OUT" "DECISION: YES" \
        "consume still reaches the live answer past non-object scalar lines"
    # After consume, state reports consumed even with the scalars still present.
    run_inbox "$sb" state golem-3 "$GATE"
    assert_equals "consumed" "$INBOX_OUT" \
        "state folds to consumed past non-object scalar lines"
}

# --- state (read-only tri-state, #395) --------------------------------------

# `state` is the read-only snapshot golem-status.sh uses to annotate a BLOCKED
# escalation/dead-end line. It folds the gate's event stream to one word:
# awaiting (no answer) → answered (unconsumed answer) → consumed. Read-only: it
# must never write a marker (a following consume still returns the decision).
test_state_tristate_transitions() {
    local sb inbox
    new_sandbox sb
    inbox="$sb/.worktrees/.status/inbox-golem-3.jsonl"
    run_inbox "$sb" state golem-3 "$GATE"
    assert_exit 0 "$INBOX_RC" "state (no inbox file) exits 0"
    assert_equals "awaiting" "$INBOX_OUT" "no answer yet → awaiting"
    run_inbox "$sb" answer golem-3 "$GATE" B
    run_inbox "$sb" state golem-3 "$GATE"
    assert_equals "answered" "$INBOX_OUT" "an unconsumed answer → answered"
    # state must NOT consume: the answer is still live after a state read.
    assert_file_not_contains "$inbox" '"event":"consumed"' "state wrote no consumed marker"
    run_inbox "$sb" consume golem-3 "$GATE"
    run_inbox "$sb" state golem-3 "$GATE"
    assert_equals "consumed" "$INBOX_OUT" "after consume → consumed"
}

# A re-answer after consume must fold back to `answered` (the operator sent a new
# decision the golem hasn't consumed yet), not stick at consumed.
test_state_reanswer_after_consume() {
    local sb
    new_sandbox sb
    run_inbox "$sb" answer golem-3 "$GATE" B
    run_inbox "$sb" consume golem-3 "$GATE"
    run_inbox "$sb" answer golem-3 "$GATE" C
    run_inbox "$sb" state golem-3 "$GATE"
    assert_equals "answered" "$INBOX_OUT" "re-answer after consume folds back to answered"
}

# state is gate-scoped: an answer for one gate does not make a DIFFERENT gate
# report answered (the two-layer attribution the inbox enforces).
test_state_gate_scoped() {
    local sb
    new_sandbox sb
    run_inbox "$sb" answer golem-3 "$GATE" B
    run_inbox "$sb" state golem-3 "$GATE2"
    assert_equals "awaiting" "$INBOX_OUT" "a decision for one gate leaves another gate awaiting"
}

# The no-jq path folds the same tri-state via the pure-bash scanner (no skip
# guard — it is jq-independent, matching the other no-jq cases).
test_state_nojq_tristate() {
    if [ -z "$REAL_GIT" ]; then
        skip_test "git not available (no-jq path still needs git on the stub PATH)"
        return 0
    fi
    local sb
    new_sandbox sb
    run_inbox_nojq "$sb" state golem-5 "$GATE"
    assert_equals "awaiting" "$INBOX_OUT" "no-jq: no answer → awaiting"
    run_inbox_nojq "$sb" answer golem-5 "$GATE" X
    run_inbox_nojq "$sb" state golem-5 "$GATE"
    assert_equals "answered" "$INBOX_OUT" "no-jq: unconsumed answer → answered"
    run_inbox_nojq "$sb" consume golem-5 "$GATE"
    run_inbox_nojq "$sb" state golem-5 "$GATE"
    assert_equals "consumed" "$INBOX_OUT" "no-jq: after consume → consumed"
}

# Bad/missing args are rejected with exit 2 (mirrors consume/peek validation).
test_state_rejects_bad_args() {
    local sb
    new_sandbox sb
    run_inbox "$sb" state "golem-../evil" "$GATE"
    assert_exit 2 "$INBOX_RC" "traversal-shaped golem id → exit 2"
    assert_contains "$INBOX_OUT" "invalid golem id" "reports the invalid golem id"
    run_inbox "$sb" state golem-3 "not-a-gate"
    assert_exit 2 "$INBOX_RC" "non-gate id → exit 2"
    run_inbox "$sb" state golem-3
    assert_exit 2 "$INBOX_RC" "missing gate-id → exit 2"
    assert_contains "$INBOX_OUT" "need <golem> <gate-id>" "reports the missing arg"
}

# --- peek -------------------------------------------------------------------

# peek is a non-blocking read: it lists matching answer lines and never blocks
# or writes a consumed marker.
test_peek_lists_answers() {
    if ! command -v jq >/dev/null 2>&1; then
        skip_test "jq not available (peek asserts on JSON lines)"
        return 0
    fi
    local sb
    new_sandbox sb
    run_inbox "$sb" answer golem-3 "$GATE" B
    run_inbox "$sb" peek golem-3 "$GATE"
    assert_exit 0 "$INBOX_RC" "peek exits 0"
    assert_contains "$INBOX_OUT" '"option":"B"' "peek shows the answer line"
    # peek must NOT consume: a following consume still returns the decision.
    run_inbox "$sb" consume golem-3 "$GATE"
    assert_contains "$INBOX_OUT" "DECISION: B" "peek did not consume the answer"
}

# --- usage / validation -----------------------------------------------------

# An unknown subcommand prints usage on stderr and exits 2.
test_unknown_subcommand() {
    local sb
    new_sandbox sb
    run_inbox "$sb" bogus
    assert_exit 2 "$INBOX_RC" "unknown subcommand exits 2"
    assert_contains "$INBOX_OUT" "usage:" "unknown subcommand prints usage"
}

# A path-traversal-shaped golem id is rejected (the id becomes a filename
# segment; a `..`/slash must never escape the status dir).
test_rejects_bad_golem_id() {
    local sb
    new_sandbox sb
    run_inbox "$sb" answer "golem-../evil" "$GATE" B
    assert_exit 2 "$INBOX_RC" "traversal-shaped golem id is rejected (exit 2)"
    assert_contains "$INBOX_OUT" "invalid golem id" "reports the invalid golem id"
}

# A non-golem-shaped id is rejected too (defends the golem-* contract).
test_rejects_non_golem_id() {
    local sb
    new_sandbox sb
    run_inbox "$sb" consume "notagolem" "$GATE"
    assert_exit 2 "$INBOX_RC" "non-golem id is rejected (exit 2)"
}

# --- no-jq degraded path ----------------------------------------------------

# With jq stubbed off PATH, `answer` still writes valid JSON for an adversarial
# option (embedded quote + backslash) and `consume` reads it back EXACTLY —
# neither corrupting the inbox nor mis-parsing the value. jq is used only to
# VALIDATE the written line; the script itself runs jq-free.
test_no_jq_roundtrip_adversarial() {
    if [ -z "$REAL_GIT" ]; then
        skip_test "git not available (no-jq path still needs git on the stub PATH)"
        return 0
    fi
    local sb inbox
    new_sandbox sb
    run_inbox_nojq "$sb" answer golem-5 "$GATE" 'opt"x\y' --note 'n"o\te'
    assert_exit 0 "$INBOX_RC" "no-jq answer exits 0"
    inbox="$sb/.worktrees/.status/inbox-golem-5.jsonl"
    assert_file_exists "$inbox" "no-jq answer created the inbox"
    if command -v jq >/dev/null 2>&1; then
        assert_valid_json "$(command tail -n 1 "$inbox")" \
            "no-jq answer line is valid JSON despite quote+backslash option"
    fi
    # The backslash is dropped and the quote preserved as data (mirrors the
    # golem-notify escaper contract): option "opt\"x\y" -> opt"xy.
    run_inbox_nojq "$sb" consume golem-5 "$GATE"
    assert_exit 0 "$INBOX_RC" "no-jq consume exits 0"
    assert_contains "$INBOX_OUT" 'DECISION: opt"xy' \
        "no-jq consume reads the adversarial option back exactly (quote as data)"
    assert_contains "$INBOX_OUT" 'NOTE: n"ote' "no-jq consume reads the note back exactly"
}

# --- Run all tests ----------------------------------------------------------

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

run_test test_gateid_format_and_uniqueness "gateid: gate-<digits>-<hex>, two calls differ"
run_test test_roundtrip_answer_then_consume "round-trip: answer → consume returns DECISION + marks consumed"
run_test test_roundtrip_no_note "round-trip: no note → DECISION without a NOTE line"
run_test test_wrong_golem_isolation "attribution: golem-4 never consumes golem-3's decision"
run_test test_wrong_gate_rejection "attribution: a decision for one gate is not consumed for another"
run_test test_latest_answer_wins "latest-wins: consume returns the most recent answer"
run_test test_consumed_not_replayed "idempotent: a consumed gate is not replayed"
run_test test_no_default_guarantee "never-default: no answer → exactly NO-DECISION"
run_test test_non_integer_tunables_fail_safe "robustness: garbage tunables fall back to numeric, no infinite spin"
run_test test_leading_zero_tunables_base10 "robustness: leading-zero tunables read base-10, not octal (no hang)"
run_test test_corrupt_line_does_not_truncate_reader "resilience: a torn inbox line does not truncate the jq reader"
run_test test_non_object_scalar_line_resilience "resilience: a valid non-object scalar line does not break the jq fold"
run_test test_late_answer_caught_on_reinvoke "wait-indefinitely: re-invoked consume catches a late answer"
run_test test_state_tristate_transitions "state: awaiting → answered → consumed (read-only)"
run_test test_state_reanswer_after_consume "state: re-answer after consume folds back to answered"
run_test test_state_gate_scoped "state: gate-scoped (a decision for one gate leaves another awaiting)"
run_test test_state_nojq_tristate "state: no-jq path folds the same tri-state"
run_test test_state_rejects_bad_args "state: bad/missing args → exit 2"
run_test test_peek_lists_answers "peek: lists answers without consuming"
run_test test_unknown_subcommand "usage: unknown subcommand → stderr usage + exit 2"
run_test test_rejects_bad_golem_id "validation: traversal-shaped golem id rejected"
run_test test_rejects_non_golem_id "validation: non-golem id rejected"
run_test test_no_jq_roundtrip_adversarial "no-jq: adversarial option round-trips as valid JSON"

generate_report
