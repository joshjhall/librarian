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
# It appends one JSON line to a central feed under the MAIN checkout's status
# dir (GOLEM_STATUS_DIR, default .worktrees/.status — resolved the same
# env-overridable way the reader scripts do, so an override moves emitter and
# readers together; the MAIN root is found via the shared git common dir so it
# works from inside a worktree), which the bundled scripts/golem-status.sh
# reads. It must NEVER block the golem: any error is swallowed and it always
# exits 0.
#
# Input  (stdin):  Notification hook JSON, e.g. {"message":"...", ...}
# Output (feed):   {"ts","golem","event":"gate|idle|escalation|dead-end|resolved|reaped","message"}
#
# The `event` kind separates a real permission gate (a human decision the
# orchestrator must surface) from a transient between-turn idle: Claude Code
# also fires Notification for momentary main-loop idles (e.g. while a review
# sub-agent runs), which are noise, not a block. scripts/golem-status.sh lists a
# golem as BLOCKED only when its most-recent feed line is a fresh `gate`, so an `idle`
# emitted once the golem moves on implicitly clears that golem's stale block —
# no separate resolution hook needed.
#
# That implicit-clear assumption has ONE hole: a plan gate resolved by the
# orchestrator's `tmux send-keys 1 Enter` (the compliant broker path) fires NO
# Notification, so no superseding `idle`/`gate` is ever written and the stale
# `gate` stays fresh for the whole GOLEM_BLOCK_TTL window (issue #422). The
# `resolved` kind closes it: `scripts/golem-resolve.sh` synthesizes a
# `RESOLVED:`-prefixed Notification after the send-keys so an EXPLICIT clearing
# line supersedes the stale gate on the next sweep. Like `idle`, `resolved` is
# not in the BLOCKED set, so being a golem's most-recent line is what clears it
# (no reader change needed).
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

# Resolve the status dir the same single way the reader scripts do
# (golem-status.sh / golem-gate-watch.sh / golem-inbox.sh all use config.sh's
# GOLEM_WORKTREE_DIR / GOLEM_STATUS_DIR), so an override moves the emitter and
# its readers together instead of silently splitting the feed path (#405). The
# two defaults are inlined verbatim from config.sh (lines 66,70) rather than
# sourced: this hook is deliberately minimal and always-exit-0, and sourcing
# config.sh would also pull in its repo_root()/superproject probe, changing the
# git-common-dir root resolution above that must stay preserved. With both unset
# this yields .worktrees/.status — byte-for-byte the old hardcoded path. The
# `:=` assign-default form is safe under the `set -u` active here.
: "${GOLEM_WORKTREE_DIR:=.worktrees}"
: "${GOLEM_STATUS_DIR:=${GOLEM_WORKTREE_DIR}/.status}"
status_dir="$root/$GOLEM_STATUS_DIR"
feed="$status_dir/feed.jsonl"

# Multi-sink fan-out config (#406, ADR-0001 Decision 2). One classified event
# fans to feed.jsonl ALWAYS plus zero-or-more HTTP sinks listed in
# GOLEM_EVENT_SINKS (a space/comma list of http(s):// URLs). Empty/unset ⇒ pure
# no-op beyond the feed, so default behavior is byte-for-byte unchanged. Each
# POST is bounded by GOLEM_EVENT_SINK_TIMEOUT (connect+total seconds) and
# best-effort — a hung/refused endpoint must never wedge the golem, so failures
# are swallowed and the hook still exits 0. Defaults are inlined here rather than
# sourced (same rationale as GOLEM_STATUS_DIR above: sourcing config.sh would
# pull in its repo_root()/superproject probe and change the git-common-dir root
# resolution). config.sh documents/exports the same two knobs as their home, and
# tests/validate-golem-notify.sh's test_event_sink_defaults_match_config_sh
# pins these inlined defaults equivalent to config.sh's (the #424 drift guard,
# now covering the sink vars too). GOLEM_EVENT_SINKS is trusted operator input —
# see the TRUST BOUNDARY note in config.sh and next to the scheme guard below.
: "${GOLEM_EVENT_SINKS:=}"
: "${GOLEM_EVENT_SINK_TIMEOUT:=2}"

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
#   resolved   — an EXPLICIT clearing signal that a prior gate for this golem is
#                now resolved (issue #422). Synthesized by scripts/golem-resolve.sh
#                after the orchestrator's `tmux send-keys 1 Enter` plan-approval,
#                which otherwise fires no Notification. Emitted with a message
#                beginning `RESOLVED:`. Like `idle` it is not in the BLOCKED set,
#                so as a golem's most-recent line it supersedes the stale gate.
#   reaped     — a TERMINAL signal that this golem's worktree/session was torn
#                down (issue #446). Emitted by scripts/worktree-rm.sh after a
#                successful teardown, which otherwise leaves the golem's last
#                `gate` line as its most-recent feed entry — so golem-status.sh
#                lists a golem whose PR merged hours ago as BLOCKED for the whole
#                GOLEM_BLOCK_TTL window (the `golem-743` ghost in #446). Emitted
#                with a message beginning `REAPED:`. Like `idle`/`resolved` it is
#                NOT in the BLOCKED set, so as the golem's most-recent line it
#                supersedes the stale gate on the next sweep (no reader change
#                needed). A reader-side liveness cross-check in
#                golem-gate-watch.sh's feed_snapshot is the defense-in-depth for a
#                golem torn down WITHOUT worktree-rm.sh (which emits no line).
# Match case-insensitively on the message; default to `gate` so an unrecognized
# notification surfaces (fail loud) rather than being silently dropped as idle.
# The `dead-end`/`escalation`/`resolved` branches precede the `gate` default so
# their markers win; `dead-end` is matched before `escalation` because it is the
# more specific kind (a dead-end IS an escalation that also blocks L4).
#
# `resolved:` and `reaped:` are anchored to the START of the (lower-cased)
# message — a PREFIX match — while `dead-end:`/`escalation:` stay unanchored
# substrings. The asymmetry is deliberate and load-bearing (#422 pre-PR review):
# a misclassified `resolved`/`reaped` REMOVES a golem from the BLOCKED set (both
# mirror `idle`, the non-blocked kinds), so misclassifying a REAL gate as one of
# them silently hides a pending human decision — the exact failure #422 exists to
# prevent, inverted. And both words are ordinary English that legitimately appear
# mid-message in a real permission ask (e.g. a `git commit -m '… mark resolved:
# …'` / `merge conflicts unresolved: …` prompt, or a `… files reaped: …` message),
# so an unanchored match would drop that genuine gate. The producers
# (`scripts/golem-resolve.sh`, `scripts/worktree-rm.sh`) always emit
# `RESOLVED:`/`REAPED:` as a true LEADING marker, so a prefix match loses nothing
# and closes the masking gap. A misclassified `dead-end`/`escalation`, by
# contrast, only makes a gate MORE visible (both ARE surfaced in BLOCKED) — the
# safe direction — so those keep their existing unanchored match. Do NOT
# "normalize" `resolved:`/`reaped:` back to an unanchored substring.
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
    "resolved:"*) event="resolved" ;;
    "reaped:"*) event="reaped" ;;
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

# Build the classified {ts, golem, event, message} JSON line ONCE, then fan the
# SAME line to every sink (feed always; HTTP sinks best-effort). Prefer jq for
# correct escaping; fall back to a best-effort literal if jq is unavailable. The
# message (and, defensively, the golem id) are attacker-influenceable, so both
# paths escape/sanitize them identically before this one string reaches any sink
# (#406 AC4 — same escaped payload to every sink).
if command -v jq >/dev/null 2>&1; then
    line="$(jq -cn --arg ts "$ts" --arg golem "$golem" --arg event "$event" --arg message "$message" \
        '{ts: $ts, golem: $golem, event: $event, message: $message}' 2>/dev/null || true)"
else
    # No jq: hand-roll the JSON. The message / golem id originate from the
    # Notification payload / environment, so sanitize before interpolating: drop
    # control chars and backslashes — which can't be escaped correctly without a
    # real JSON encoder and would otherwise let a crafted payload break out of
    # the string literal — then escape any remaining double quotes. Keeps the
    # line valid JSON on this path.
    golem_safe="$(printf '%s' "${golem//\\/}" | /usr/bin/tr -d '[:cntrl:]')"
    message_safe="$(printf '%s' "${message//\\/}" | /usr/bin/tr -d '[:cntrl:]')"
    # $event is a fixed literal (gate|idle|escalation|dead-end|resolved|reaped)
    # set by the case above, never attacker-derived, so it needs no sanitizing —
    # interpolate it directly.
    line="$(printf '{"ts":"%s","golem":"%s","event":"%s","message":"%s"}' \
        "$ts" "${golem_safe//\"/\\\"}" "$event" "${message_safe//\"/\\\"}")"
fi

# If the line failed to build (jq present but errored — essentially never for
# well-formed string args), skip BOTH sinks: an empty `line` would append a bare
# blank line to the feed (readers tolerate it, but it is noise) and POST an empty
# body to every sink. Preserve the pre-#406 "write nothing on failure" behavior.
if [ -z "$line" ]; then
    exit 0
fi

# Sink 1 — feed.jsonl, ALWAYS. mkdir is non-fatal (was `|| exit 0`): a feed dir
# that can't be created must NOT skip the HTTP fan below — one emission is feed
# AND sinks (#406 AC1). Every failure is swallowed; the hook still exits 0.
/usr/bin/mkdir -p "$status_dir" 2>/dev/null || true
printf '%s\n' "$line" >>"$feed" 2>/dev/null || true

# Sink 2..N — HTTP endpoints in GOLEM_EVENT_SINKS, best-effort. Skipped entirely
# (no process spawned) when the list is empty or curl is absent, so an unset
# GOLEM_EVENT_SINKS is byte-for-byte the pre-#406 behavior (AC2). Each POST is
# bounded (--connect-timeout / -m) AND backgrounded, so a slow or dead endpoint
# can never wedge the golem (AC3); the same `$line` goes to every sink (AC4).
if [ -n "$GOLEM_EVENT_SINKS" ] && command -v curl >/dev/null 2>&1; then
    # Normalize the comma/space-separated list to whitespace, then word-split it
    # in the `for` (bash-3.2 clean: no arrays / mapfile). Scheme-guard each entry
    # so only real http(s) URLs are POSTed — a stray non-URL token is skipped,
    # not handed to curl. The guard is a scheme filter ONLY, not a security
    # control: it does not restrict the host, so loopback/link-local/RFC1918/
    # cloud-metadata targets are all reachable, and http:// is accepted. This is
    # the accepted trust model — GOLEM_EVENT_SINKS is trusted operator input, as
    # sensitive as PATH (see the TRUST BOUNDARY note in config.sh); host
    # allow-listing / https-only / request signing are NON-goals of this
    # best-effort emitter and belong to the receiver follow-up (#407).
    sinks="$(printf '%s' "$GOLEM_EVENT_SINKS" | /usr/bin/tr ',' ' ')"
    # shellcheck disable=SC2086  # intentional word-split of the sink URL list
    for url in $sinks; do
        case "$url" in
            http://* | https://*) ;;
            *) continue ;;
        esac
        # Fire-and-forget: bounded, all fds to /dev/null, backgrounded. The
        # redirections detach the child so it never holds the caller's stdout
        # pipe open, and `&` means the hook returns without awaiting the POST.
        command curl -s -o /dev/null \
            --connect-timeout "$GOLEM_EVENT_SINK_TIMEOUT" \
            -m "$GOLEM_EVENT_SINK_TIMEOUT" \
            -X POST -H 'Content-Type: application/json' \
            --data-raw "$line" "$url" >/dev/null 2>&1 &
    done
fi

exit 0
