#!/usr/bin/env bash
# Notification hook for the orchestrate golem flow.
#
# Claude Code fires the `Notification` hook when a session is awaiting a
# permission decision or other input. For a golem (an interactive
# `/next-issue --level 4` session running in tmux under `auto` permission mode)
# that is exactly the "BLOCKED — needs a human" signal the orchestrator must
# surface. The golem's TUI paints an alternate screen buffer, so it cannot be
# scraped live; this hook is the TTY-free channel instead.
#
# It appends one JSON line to a central feed under the MAIN checkout's
# .worktrees/.status/feed.jsonl (resolved via the shared git common dir so it
# works from inside a worktree), which the bundled scripts/golem-status.sh
# reads. It must NEVER block the golem: any error is swallowed and it always
# exits 0.
#
# Input  (stdin):  Notification hook JSON, e.g. {"message":"...", ...}
# Output (feed):   {"ts","golem","event":"gate|idle|escalation|dead-end","message"}
#
# The `event` kind separates a real permission gate (a human decision the
# orchestrator must surface) from a transient between-turn idle: Claude Code
# also fires Notification for momentary main-loop idles (e.g. while a review
# sub-agent runs), which are noise, not a block. scripts/golem-status.sh lists a
# golem as BLOCKED only when its most-recent feed line is a fresh `gate`, so an `idle`
# emitted once the golem moves on implicitly clears that golem's stale block —
# no separate resolution hook needed.
#
# A third kind, `escalation`, marks a genuine judgement call carrying options —
# a mid-flight architectural/directional fork, or a wall with more than one
# viable path forward (issue #176). Unlike a `gate` (a mechanical permission
# decision), an escalation is a human choice at L1–L3 and auto-resolved at L4;
# it is surfaced distinctly so the orchestrator does not lose it among routine
# permission gates. The next-issue escalation protocol emits one by piping a
# payload whose message begins `ESCALATION:` to this hook (the git-common-dir
# resolution, golem-id derivation, and JSON escaping below are reused verbatim).
set -uo pipefail

# Resolve the main repo root even when invoked from a worktree:
# git-common-dir points at <main>/.git, whose parent is the main checkout.
common_dir="$(/usr/bin/git rev-parse --git-common-dir 2>/dev/null || true)"
if [ -z "$common_dir" ]; then
    exit 0 # not in a git repo — nothing to record, never block the golem
fi
case "$common_dir" in
    /*) ;; # already absolute
    *) common_dir="$(/usr/bin/pwd)/$common_dir" ;;
esac
root="$(/usr/bin/dirname "$common_dir")"
status_dir="$root/.worktrees/.status"
feed="$status_dir/feed.jsonl"

# Read the Notification payload; tolerate missing jq or a non-JSON body.
payload="$(/bin/cat 2>/dev/null || true)"
message=""
if command -v jq >/dev/null 2>&1; then
    message="$(printf '%s' "$payload" | jq -r '.message // empty' 2>/dev/null || true)"
fi
[ -z "$message" ] && message="awaiting permission decision"

# Classify the notification into an event kind so the reader can tell a real
# permission gate (an actionable human decision) from a transient idle (noise)
# or a mid-flight escalation (a judgement call carrying options):
#   gate       — a permission decision is pending, e.g. the `git push` / `gh pr
#                create` `ask` rule firing ("Claude needs your permission to ...").
#   idle       — a momentary between-turn idle ("Claude is waiting for your
#                input"), which also fires while a sub-agent runs mid-work and
#                is NOT a block.
#   escalation — a genuine architectural/directional fork or a wall with >1
#                viable path (issue #176). The next-issue escalation protocol
#                emits it with a message beginning `ESCALATION:`; surfaced
#                distinctly from a routine permission gate.
#   dead-end   — an escalation whose only auto-resolution would violate the merge
#                invariant (CI still red after ci-fixer exhausts, a contradictory
#                conflict rebase-agent can't union, an unclean review that can't
#                be mechanically fixed — issue #180). It blocks at EVERY level,
#                L4 included, and carries a structured why/attempted/remaining
#                summary. Emitted with a message beginning `DEAD-END:`.
# Match case-insensitively on the message; default to `gate` so an unrecognized
# notification surfaces (fail loud) rather than being silently dropped as idle.
# The `dead-end` and `escalation` branches precede the `gate` default so their
# markers win; `dead-end` is matched before `escalation` because it is the more
# specific kind (a dead-end IS an escalation that also blocks L4).
#
# Why only the `ESCALATION:`-prefixed path is classified as `escalation` here,
# and an in-turn `AskUserQuestion` fork is NOT (issue #321, deferred out of
# #257/PR #320): an in-turn `AskUserQuestion` fork does not reach this hook as an
# escalation. Claude Code surfaces such a fork through the SDK `canUseTool`
# callback, not the async `Notification` event — which is exactly why the
# escalation protocol has to SYNTHESIZE an `ESCALATION:`-prefixed Notification
# and pipe it here by hand (`next-issue/escalation-protocol.md`). When a plain
# permission `Notification` does fire, its `message` is not a stable,
# machine-parseable string and carries no multi-option / tool-name field, so
# there is no fork-specific signature to key on. A heuristic would therefore risk
# FALSE POSITIVES on the fail-loud `gate` default (mislabelling routine
# permission gates as escalations) — the precise risk #257 named when deferring
# this. So the feed channel classifies only the deterministic `ESCALATION:` path;
# a live in-turn fork stays the `gate` default here BY DESIGN. The pane channel
# (`golem-gate-watch.sh` `pane_is_fork`, PR #320) is the best-effort surface that
# observes a live in-turn fork's modal overlay; the two channels agreeing is only
# expected for the `ESCALATION:`-prefixed path, not for an in-turn fork.
case "$(printf '%s' "$message" | /usr/bin/tr '[:upper:]' '[:lower:]')" in
    *"waiting for your input"*) event="idle" ;;
    *"waiting for input"*) event="idle" ;;
    *"dead-end:"*) event="dead-end" ;;
    *"escalation:"*) event="escalation" ;;
    *) event="gate" ;;
esac

# Derive the golem id. In order of reliability:
#   1. $GOLEM_ID — stamped into the environment at launch (orchestrate /
#      scripts/worktree-new.sh). The only fully deterministic source: cwd- and
#      tmux-independent, so it survives subdirectory and subagent invocations.
#   2. The git WORKTREE-ROOT basename (issue-N -> golem-N). Unlike `pwd`, the
#      worktree root is cwd-independent: `git rev-parse --show-toplevel`
#      returns `.../issue-N` even when the Notification fires from a
#      subdirectory or a review-harness subagent with its own cwd.
#   3. A placeholder, only when neither source resolves (e.g. not in a
#      worktree at all).
# The old `$TMUX` path was dead — the golem's `claude` process has no TMUX in
# its environment even though tmux launched it — so it is gone.
golem=""
case "${GOLEM_ID:-}" in
    golem-*) golem="$GOLEM_ID" ;;
esac
if [ -z "$golem" ]; then
    base="$(/usr/bin/basename "$(/usr/bin/git rev-parse --show-toplevel 2>/dev/null || /usr/bin/pwd)")"
    case "$base" in
        issue-*) golem="golem-${base#issue-}" ;;
        golem-*) golem="$base" ;;
        *) golem="golem-?" ;;
    esac
fi

ts="$(/usr/bin/date -u +%FT%TZ)"

# Append one feed line. Prefer jq for correct escaping; fall back to a
# best-effort literal if jq is unavailable.
/usr/bin/mkdir -p "$status_dir" 2>/dev/null || exit 0
if command -v jq >/dev/null 2>&1; then
    jq -cn --arg ts "$ts" --arg golem "$golem" --arg event "$event" --arg message "$message" \
        '{ts: $ts, golem: $golem, event: $event, message: $message}' \
        >>"$feed" 2>/dev/null || true
else
    # No jq: hand-roll the JSON. The message (and, defensively, the golem id)
    # originate from the Notification payload / environment, so sanitize before
    # interpolating: drop control chars and backslashes — which can't be
    # escaped correctly without a real JSON encoder and would otherwise let a
    # crafted payload break out of the string literal — then escape any
    # remaining double quotes. Keeps every feed line valid JSON on this path.
    golem_safe="$(printf '%s' "${golem//\\/}" | /usr/bin/tr -d '[:cntrl:]')"
    message_safe="$(printf '%s' "${message//\\/}" | /usr/bin/tr -d '[:cntrl:]')"
    # $event is a fixed literal (gate|idle|escalation|dead-end) set by the case
    # above, never attacker-derived, so it needs no sanitizing — interpolate it
    # directly.
    printf '{"ts":"%s","golem":"%s","event":"%s","message":"%s"}\n' \
        "$ts" "${golem_safe//\"/\\\"}" "$event" "${message_safe//\"/\\\"}" \
        >>"$feed" 2>/dev/null || true
fi

exit 0
