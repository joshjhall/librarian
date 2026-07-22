#!/usr/bin/env bash
# golem-inbox.sh — the orchestrator-brokered gate reverse channel (issue #227).
#
# The push feed (hooks/golem-notify.sh -> .worktrees/.status/feed.jsonl, read by
# golem-status.sh / golem-gate-watch.sh) surfaces a golem's parked HUMAN gate
# up to the orchestrator. It is a one-way, golem -> orchestrator channel. This
# script is the missing REVERSE channel: it lets the orchestrator collect the
# operator's decision ONCE at the top-most session and relay it back DOWN into
# the originating golem, which polls and consumes it to unblock — so an operator
# supervising N golems answers each escalation/dead-end from one interface
# instead of golem-attach.sh'ing into every golem's TTY.
#
# It is DATA-ONLY by design. The inbox carries a golem's escalation/dead-end
# DECISION and never itself resolves an auto-mode gate. Plan-approval is NOT
# brokered here: it stays on the compliant directed `tmux send-keys` broker
# (orchestrate/SKILL.md, #281) so a genuine human action still commits the
# auto-mode transition — the #29 `[Create Unsafe Agents]` invariant. See
# orchestrate/mode-protocol.md § "Reverse channel (the inbox)".
#
# One file per golem — <status_dir>/inbox-<golem>.jsonl, a sibling of feed.jsonl.
# Attribution is two-layer so a decision for golem-N can NEVER be consumed by
# golem-M: (1) the FILENAME is keyed by golem-id (golem-N only ever reads
# inbox-golem-N.jsonl); (2) `consume` additionally filters on the in-record
# `golem` + `gate` fields (defense-in-depth + audit trail).
#
# Subcommands:
#   gateid
#       Print a fresh correlation id: gate-<epoch>-<rand4>. Called golem-side
#       once, at escalation time; the golem interpolates the SAME id into its
#       synthesized ESCALATION:/DEAD-END: feed message, its issue comment, and
#       its own later `consume` call — one id, three carriers, guaranteed
#       consistent, no feed-schema change.
#   answer <golem> <gate-id> <option> [--note "text"]
#       Orchestrator-side WRITE. Append one answer line to inbox-<golem>.jsonl.
#       <option> is the chosen option label/index (opaque data).
#   consume <golem> <gate-id>
#       Golem-side bounded-blocking READ. Poll for a matching un-consumed answer
#       up to GOLEM_INBOX_WAIT seconds (default 300, under the Bash tool's 600s
#       ceiling), every GOLEM_INBOX_POLL seconds (default 3). On a match: print
#       "DECISION: <option>" (and "NOTE: <note>" when present), append a
#       `consumed` marker, exit 0. On no match within the window: print
#       "NO-DECISION" and exit 0 — it NEVER invents a default. The golem-side
#       skill re-invokes `consume` on NO-DECISION, forever, so "wait
#       indefinitely" holds as an agent-level loop with no single call near the
#       ceiling and no lapse-and-default path.
#   state <golem> <gate-id>
#       Read-only tri-state snapshot for a gate: prints `awaiting` (no answer
#       yet), `answered` (an unconsumed answer is waiting), or `consumed`. Used
#       by golem-status.sh to annotate a BLOCKED escalation/dead-end line so the
#       operator can see which gates still need an answer. Writes nothing.
#   peek <golem> [gate-id]
#       Non-blocking read (orchestrator / debugging). Print matching answer
#       lines (all, or those for <gate-id>) and exit 0; print nothing if none.
#
# Runtime policy: bash-3.2 clean (no declare -A / mapfile / namerefs / ${v,,} /
# ;;&), coreutils via the `command` builtin (PATH-resolved, not hardcoded
# /usr/bin — #443), `set -uo pipefail`
# (errors handled per-call, never `-e`). The write path mirrors golem-notify.sh:
# prefer `jq -cn` for correct escaping, fall back to a sanitizing hand-rolled
# printf when jq is absent, so every inbox line stays valid JSON.
set -uo pipefail

# --- Portable tool resolution (#443) ----------------------------------------
# This script runs under a potentially stripped PATH (its no-jq path is tested
# with PATH reduced to bash+git), so `command <tool>` would fail to find an
# external coreutil there — yet a hardcoded /usr/bin/<tool> is wrong on macOS.
# `_bin <tool>` honors PATH first (the `command -v` builtin needs no external
# binary), then falls back to scanning the standard bin dirs so it still resolves
# under a stripped PATH, then yields the bare name. Candidates are bare
# DIRECTORIES, not /usr/bin/<tool> literals, so the #443 lint does not flag them.
# Defined before SCRIPT_DIR so even that resolution is portable.
_BIN_CANDIDATE_DIRS="/usr/bin /bin /usr/local/bin /opt/homebrew/bin /sbin /usr/sbin"
_bin() {
    _br="$(command -v "$1" 2>/dev/null || true)"
    if [ -z "$_br" ]; then
        for _bd in $_BIN_CANDIDATE_DIRS; do
            [ -x "$_bd/$1" ] && {
                _br="$_bd/$1"
                break
            }
        done
    fi
    printf '%s' "${_br:-$1}"
}
DIRNAME="$(_bin dirname)"
TR="$(_bin tr)"
DATE="$(_bin date)"
MKDIR="$(_bin mkdir)"
SLEEP="$(_bin sleep)"

SCRIPT_DIR="$(cd "$("$DIRNAME" "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./config.sh
. "$SCRIPT_DIR/config.sh"

# Resolve the MAIN checkout's status dir (the inbox lives there even when a
# subcommand runs from inside a worktree, exactly like the feed). repo_root
# (from config.sh) is bare-repo- and submodule-safe.
inbox_resolve_status_dir() {
    local root
    root="$(repo_root 2>/dev/null || true)"
    [ -z "$root" ] && return 1
    command echo "$root/$GOLEM_STATUS_DIR"
}

# Print the inbox path for a golem, or return 1 if not inside a repo.
inbox_path_for() {
    local golem="$1" status_dir
    status_dir="$(inbox_resolve_status_dir)" || return 1
    command echo "$status_dir/inbox-$golem.jsonl"
}

# A golem id must be a golem-<...> token — the same shape golem-notify.sh stamps
# on the feed. Reject anything else (and, critically, path metacharacters) so the
# id can't traverse out of the status dir when it becomes a filename segment.
inbox_valid_golem() {
    case "$1" in
        golem-*)
            case "$1" in
                *[!A-Za-z0-9_.-]*) return 1 ;;
                *) return 0 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

# A gate id must look like the minted gate-<digits>-<alnum> token. Same rationale
# as the golem check: it is matched against record fields, never a path, but
# validating it keeps a malformed correlation key from silently matching nothing.
inbox_valid_gate() {
    case "$1" in
        gate-*)
            case "$1" in
                *[!A-Za-z0-9_.-]*) return 1 ;;
                *) return 0 ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

usage() {
    command cat >&2 <<'EOF'
usage: golem-inbox.sh <subcommand> [args]

  gateid
      Print a fresh correlation id (gate-<epoch>-<rand4>).
  answer  <golem> <gate-id> <option> [--note "text"]
      Write the operator's decision into the golem's inbox.
  consume <golem> <gate-id>
      Bounded-blocking read; print "DECISION: <option>" or "NO-DECISION".
  state   <golem> <gate-id>
      Read-only; print the gate's inbox state: awaiting | answered | consumed.
  peek    <golem> [gate-id]
      Non-blocking read of matching answer lines (debugging).
EOF
    return 0
}

# --- gateid -----------------------------------------------------------------

# Mint gate-<epoch>-<rand4>. RANDOM/date are fine in bash (unlike the workflow.js
# engine). The 4-hex suffix disambiguates two gates minted in the same second by
# one golem; correlation is still primarily by (golem, gate) so a rare collision
# across DIFFERENT golems is harmless (separate inbox files).
cmd_gateid() {
    local epoch rand
    epoch="$("$DATE" -u +%s 2>/dev/null || command echo 0)"
    rand="$(command printf '%04x' $((RANDOM & 0xffff)))"
    command echo "gate-${epoch}-${rand}"
}

# --- answer -----------------------------------------------------------------

cmd_answer() {
    local golem="" gate="" option="" note=""
    # Positional golem/gate/option, then an optional --note "text". Parse
    # positionally so an option string that starts with '-' still works when it
    # is the 3rd positional (only --note is a recognized flag).
    local seen=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --note)
                shift
                note="${1:-}"
                ;;
            *)
                case "$seen" in
                    0) golem="$1" ;;
                    1) gate="$1" ;;
                    2) option="$1" ;;
                    *)
                        command echo "golem-inbox answer: too many arguments" >&2
                        return 2
                        ;;
                esac
                seen=$((seen + 1))
                ;;
        esac
        shift
    done

    if [ "$seen" -lt 3 ]; then
        command echo "golem-inbox answer: need <golem> <gate-id> <option>" >&2
        return 2
    fi
    if ! inbox_valid_golem "$golem"; then
        command echo "golem-inbox answer: invalid golem id '$golem'" >&2
        return 2
    fi
    if ! inbox_valid_gate "$gate"; then
        command echo "golem-inbox answer: invalid gate id '$gate'" >&2
        return 2
    fi

    local inbox status_dir ts
    inbox="$(inbox_path_for "$golem")" || {
        command echo "golem-inbox answer: not inside a git repository" >&2
        return 1
    }
    status_dir="$("$DIRNAME" "$inbox")"
    ts="$("$DATE" -u +%FT%TZ)"
    "$MKDIR" -p "$status_dir" 2>/dev/null || {
        command echo "golem-inbox answer: cannot create $status_dir" >&2
        return 1
    }

    if command -v jq >/dev/null 2>&1; then
        jq -cn --arg ts "$ts" --arg golem "$golem" --arg gate "$gate" \
            --arg event "answer" --arg option "$option" --arg note "$note" \
            '{ts: $ts, golem: $golem, gate: $gate, event: $event, option: $option, note: $note}' \
            >>"$inbox" 2>/dev/null || {
            command echo "golem-inbox answer: write failed" >&2
            return 1
        }
    else
        # No jq: hand-roll the JSON. option/note are operator-supplied, so
        # sanitize before interpolating — drop control chars and backslashes
        # (which cannot be escaped correctly without a real encoder and would let
        # a crafted value break out of the string literal), then escape any
        # remaining double quotes. golem/gate are already validated to a safe
        # charset above; event is a fixed literal. Mirrors golem-notify.sh's
        # no-jq escaper so every inbox line stays valid JSON on this path too.
        local option_safe note_safe
        option_safe="$(command printf '%s' "${option//\\/}" | "$TR" -d '[:cntrl:]')"
        note_safe="$(command printf '%s' "${note//\\/}" | "$TR" -d '[:cntrl:]')"
        command printf '{"ts":"%s","golem":"%s","gate":"%s","event":"answer","option":"%s","note":"%s"}\n' \
            "$ts" "$golem" "$gate" "${option_safe//\"/\\\"}" "${note_safe//\"/\\\"}" \
            >>"$inbox" 2>/dev/null || {
            command echo "golem-inbox answer: write failed" >&2
            return 1
        }
    fi
    return 0
}

# --- read helpers (shared by consume + peek) --------------------------------

# Print the latest un-consumed answer for (golem, gate) as a single JSONL line,
# or nothing. "Un-consumed" = there is no later `consumed` marker line for the
# same gate after the answer. jq path; the no-jq fallback follows.
inbox_latest_answer_jq() {
    local inbox="$1" golem="$2" gate="$3"
    # Walk the file in order, tracking the most-recent answer for this
    # (golem,gate) and clearing it when a matching `consumed` marker supersedes
    # it. Emits at most one line (the live answer), or nothing.
    #
    # Read each line as RAW (`-R`) and parse it with `fromjson?` so ONE malformed
    # line (a torn append from a crash/disk-full/concurrent write — the inbox is
    # an append-only file grown by potentially-interrupted writers) is SKIPPED,
    # not fatal. Plain `jq '…' file` parses the file as a JSON *document* and
    # aborts the whole read on the first bad line, silently truncating every
    # record after it (with `2>/dev/null || true` swallowing the error) — which
    # would replay a stale decision past its `consumed` marker or hide a
    # corrected answer. The `select(type == "object")` is REQUIRED alongside
    # `fromjson?`: `fromjson?` only swallows an *unparsable* line, but a line that
    # parses to a valid NON-OBJECT scalar (a bare `42`, `true`, `[]`) would then
    # abort the pipeline when `.golem`/`.gate` index it ("cannot index number"),
    # which `fromjson?` does NOT catch — so filter to objects first. Together they
    # match the per-line, any-garbage resilience of the no-jq scanner below.
    jq -rc -Rn --arg golem "$golem" --arg gate "$gate" '
        [ inputs | (fromjson? // empty) | select(type == "object")
          | select(.golem == $golem and .gate == $gate) ]
        | reduce .[] as $r (null;
            if   $r.event == "answer"   then $r
            elif $r.event == "consumed" then null
            else . end)
        | select(. != null)
    ' "$inbox" 2>/dev/null || true
}

# No-jq fallback: the inbox line has a stable, self-written shape
# (…,"option":"<opt>","note":"<note>"}), so pure-bash parameter expansion can
# extract the fields. Track the live answer with a last-wins scan: an `answer`
# line sets the current option/note; a `consumed` line clears it. Emits
# "option<TAB>note" for the live answer, or nothing.
#
# option/note are split on the FIXED `","note":"` delimiter (not the first
# quote), because the no-jq writer keeps embedded double-quotes as the escaped
# `\"` — a naive first-quote split would truncate an option at its own escaped
# quote. After extraction, un-escape `\"` back to `"` (the writer already dropped
# backslashes, so `\"` is the only escape sequence that can appear).
inbox_latest_answer_nojq() {
    local inbox="$1" golem="$2" gate="$3"
    local line ev rest opt note out=""
    while IFS= read -r line; do
        case "$line" in
            *"\"golem\":\"$golem\""*) ;;
            *) continue ;;
        esac
        case "$line" in
            *"\"gate\":\"$gate\""*) ;;
            *) continue ;;
        esac
        case "$line" in
            *'"event":"answer"'*) ev="answer" ;;
            *'"event":"consumed"'*) ev="consumed" ;;
            *) ev="" ;;
        esac
        if [ "$ev" = "consumed" ]; then
            out=""
            continue
        fi
        [ "$ev" = "answer" ] || continue
        rest="${line#*\"option\":\"}"  # <opt>","note":"<note>"}
        opt="${rest%%\",\"note\":\"*}" # <opt> (up to the fixed delimiter)
        note="${rest#*\",\"note\":\"}" # <note>"}
        note="${note%\"\}}"            # <note> (strip trailing "})
        opt="${opt//\\\"/\"}"          # un-escape \" -> "
        note="${note//\\\"/\"}"
        out="$opt	$note"
    done <"$inbox"
    [ -n "$out" ] && command printf '%s\n' "$out"
    return 0
}

# Append a `consumed` marker so a later `consume` of the same gate does not
# re-return the stale decision (idempotent consumption + audit trail).
inbox_mark_consumed() {
    local inbox="$1" golem="$2" gate="$3" ts
    ts="$("$DATE" -u +%FT%TZ)"
    if command -v jq >/dev/null 2>&1; then
        jq -cn --arg ts "$ts" --arg golem "$golem" --arg gate "$gate" \
            --arg event "consumed" \
            '{ts: $ts, golem: $golem, gate: $gate, event: $event}' \
            >>"$inbox" 2>/dev/null || true
    else
        command printf '{"ts":"%s","golem":"%s","gate":"%s","event":"consumed"}\n' \
            "$ts" "$golem" "$gate" >>"$inbox" 2>/dev/null || true
    fi
    return 0
}

# --- state (read-only tri-state) --------------------------------------------

# Print the inbox state for a (golem, gate): awaiting | answered | consumed.
# A last-wins FOLD over the gate's event stream seeded at `awaiting`: each
# `answer` -> answered, each `consumed` -> consumed. This reproduces
# inbox_latest_answer_*'s "answer superseded by a later consumed" semantics in
# one pass (answer->consumed ends `consumed`; a re-answer after consume ends
# `answered`) — and, unlike those helpers (which emit nothing for BOTH awaiting
# and consumed), it distinguishes all three states. Read-only: no marker written.
#
# jq path — same -Rn + `inputs | (fromjson? // empty)` per-line resilience as
# inbox_latest_answer_jq, so one torn append can't abort the read.
inbox_gate_state_jq() {
    local inbox="$1" golem="$2" gate="$3"
    jq -rn -R --arg golem "$golem" --arg gate "$gate" '
        reduce (inputs | (fromjson? // empty) | select(type == "object")
                | select(.golem == $golem and .gate == $gate)) as $r
          ("awaiting";
             if   $r.event == "answer"   then "answered"
             elif $r.event == "consumed" then "consumed"
             else . end)
    ' "$inbox" 2>/dev/null || true
}

# No-jq path — the same case-match line scan as inbox_latest_answer_nojq, folding
# the state instead of extracting the option. bash-3.2 clean.
inbox_gate_state_nojq() {
    local inbox="$1" golem="$2" gate="$3"
    local line st="awaiting"
    while IFS= read -r line; do
        case "$line" in
            *"\"golem\":\"$golem\""*) ;;
            *) continue ;;
        esac
        case "$line" in
            *"\"gate\":\"$gate\""*) ;;
            *) continue ;;
        esac
        case "$line" in
            *'"event":"answer"'*) st="answered" ;;
            *'"event":"consumed"'*) st="consumed" ;;
        esac
    done <"$inbox"
    command printf '%s\n' "$st"
}

cmd_state() {
    local golem="${1:-}" gate="${2:-}"
    if [ -z "$golem" ] || [ -z "$gate" ]; then
        command echo "golem-inbox state: need <golem> <gate-id>" >&2
        return 2
    fi
    if ! inbox_valid_golem "$golem"; then
        command echo "golem-inbox state: invalid golem id '$golem'" >&2
        return 2
    fi
    if ! inbox_valid_gate "$gate"; then
        command echo "golem-inbox state: invalid gate id '$gate'" >&2
        return 2
    fi

    local inbox
    inbox="$(inbox_path_for "$golem")" || {
        command echo "golem-inbox state: not inside a git repository" >&2
        return 1
    }
    # No inbox file yet = nothing has been written for this golem = awaiting.
    if [ ! -f "$inbox" ]; then
        command echo "awaiting"
        return 0
    fi

    local st
    if command -v jq >/dev/null 2>&1; then
        st="$(inbox_gate_state_jq "$inbox" "$golem" "$gate")"
    else
        st="$(inbox_gate_state_nojq "$inbox" "$golem" "$gate")"
    fi
    # Defend the jq empty-output edge: a torn/unreadable file swallowed by the
    # `|| true` above must degrade to `awaiting`, never print a blank line.
    case "$st" in
        answered | consumed) command echo "$st" ;;
        *) command echo "awaiting" ;;
    esac
    return 0
}

# --- consume ----------------------------------------------------------------

cmd_consume() {
    local golem="${1:-}" gate="${2:-}"
    if [ -z "$golem" ] || [ -z "$gate" ]; then
        command echo "golem-inbox consume: need <golem> <gate-id>" >&2
        return 2
    fi
    if ! inbox_valid_golem "$golem"; then
        command echo "golem-inbox consume: invalid golem id '$golem'" >&2
        return 2
    fi
    if ! inbox_valid_gate "$gate"; then
        command echo "golem-inbox consume: invalid gate id '$gate'" >&2
        return 2
    fi

    local inbox
    inbox="$(inbox_path_for "$golem")" || {
        command echo "golem-inbox consume: not inside a git repository" >&2
        return 1
    }

    # Sanitize the tunables to non-negative integers. A non-integer value would
    # make every `[ "$elapsed" -ge "$wait_s" ]` test below error and NEVER break
    # the loop — turning a bounded read into an infinite hang (a misconfigured
    # env var must fail safe). Fall back to the documented defaults on anything
    # non-numeric; clamp poll to a 1s floor so the loop always makes progress.
    #
    # NORMALIZE THROUGH BASE-10 (`10#…`) after the digit check. A pure `[0-9]`
    # string can still be a leading-zero form like `08`/`09`/`010`, which the
    # `[ -ge ]`/`[ -lt ]` tests read as decimal but the `$(( ))` arithmetic
    # advance below reads as OCTAL — where `8`/`9` are invalid octal digits and
    # even `010` diverges from the test's decimal `10`. That split makes `elapsed`
    # never advance and hangs the loop past the ceiling. Forcing base-10 here
    # gives every later consumer (arithmetic, tests, `sleep`) one consistent
    # decimal value. `10#` needs a digits-only operand, guaranteed by the `case`.
    local wait_s poll_s have_jq
    wait_s="${GOLEM_INBOX_WAIT:-300}"
    poll_s="${GOLEM_INBOX_POLL:-3}"
    case "$wait_s" in
        "" | *[!0-9]*) wait_s=300 ;;
        *) wait_s=$((10#$wait_s)) ;;
    esac
    case "$poll_s" in
        "" | *[!0-9]*) poll_s=3 ;;
        *) poll_s=$((10#$poll_s)) ;;
    esac
    [ "$poll_s" -lt 1 ] && poll_s=1
    have_jq=0
    command -v jq >/dev/null 2>&1 && have_jq=1

    # Bounded-blocking poll. Each iteration re-reads the inbox (the orchestrator
    # may append mid-wait); we only READ here and append our own single
    # `consumed` marker on success, and answers are last-wins, so there is no
    # destructive race with a concurrent `answer`.
    local elapsed=0 hit note
    while :; do
        hit=""
        note=""
        if [ -f "$inbox" ]; then
            if [ "$have_jq" -eq 1 ]; then
                local rec
                rec="$(inbox_latest_answer_jq "$inbox" "$golem" "$gate")"
                if [ -n "$rec" ]; then
                    hit="$(command printf '%s' "$rec" | jq -r '.option' 2>/dev/null || true)"
                    note="$(command printf '%s' "$rec" | jq -r '.note // ""' 2>/dev/null || true)"
                fi
            else
                local pair
                pair="$(inbox_latest_answer_nojq "$inbox" "$golem" "$gate")"
                if [ -n "$pair" ]; then
                    hit="${pair%%	*}"
                    note="${pair#*	}"
                    [ "$note" = "$pair" ] && note=""
                fi
            fi
        fi

        if [ -n "$hit" ]; then
            inbox_mark_consumed "$inbox" "$golem" "$gate"
            command echo "DECISION: $hit"
            [ -n "$note" ] && command echo "NOTE: $note"
            return 0
        fi

        [ "$elapsed" -ge "$wait_s" ] && break
        "$SLEEP" "$poll_s" 2>/dev/null || "$SLEEP" "$poll_s" 2>/dev/null || true
        elapsed=$((elapsed + poll_s))
    done

    # No matching decision within this call's window. NEVER fabricate one — emit
    # the sentinel the golem-side skill re-invokes `consume` on, forever, so the
    # never-time-out rule is preserved as an agent-level loop.
    command echo "NO-DECISION"
    return 0
}

# --- peek -------------------------------------------------------------------

cmd_peek() {
    local golem="${1:-}" gate="${2:-}"
    if [ -z "$golem" ]; then
        command echo "golem-inbox peek: need <golem> [gate-id]" >&2
        return 2
    fi
    if ! inbox_valid_golem "$golem"; then
        command echo "golem-inbox peek: invalid golem id '$golem'" >&2
        return 2
    fi
    if [ -n "$gate" ] && ! inbox_valid_gate "$gate"; then
        command echo "golem-inbox peek: invalid gate id '$gate'" >&2
        return 2
    fi

    local inbox
    inbox="$(inbox_path_for "$golem")" || {
        command echo "golem-inbox peek: not inside a git repository" >&2
        return 1
    }
    [ -f "$inbox" ] || return 0

    if command -v jq >/dev/null 2>&1; then
        # Per-line `fromjson?` + `select(type == "object")` (via -Rn+inputs) so
        # one torn line — unparsable OR a valid non-object scalar — doesn't abort
        # the whole read; same resilience as inbox_latest_answer_jq above.
        if [ -n "$gate" ]; then
            jq -rc -Rn --arg golem "$golem" --arg gate "$gate" \
                'inputs | (fromjson? // empty) | select(type == "object") | select(.event == "answer" and .golem == $golem and .gate == $gate)' \
                "$inbox" 2>/dev/null || true
        else
            jq -rc -Rn --arg golem "$golem" \
                'inputs | (fromjson? // empty) | select(type == "object") | select(.event == "answer" and .golem == $golem)' \
                "$inbox" 2>/dev/null || true
        fi
    else
        # No jq: grep the answer lines, narrowing to the gate when given.
        local line
        while IFS= read -r line; do
            case "$line" in
                *'"event":"answer"'*) ;;
                *) continue ;;
            esac
            case "$line" in
                *"\"golem\":\"$golem\""*) ;;
                *) continue ;;
            esac
            if [ -n "$gate" ]; then
                case "$line" in
                    *"\"gate\":\"$gate\""*) ;;
                    *) continue ;;
                esac
            fi
            command printf '%s\n' "$line"
        done <"$inbox"
    fi
    return 0
}

# --- dispatch ---------------------------------------------------------------

inbox_main() {
    local sub="${1:-}"
    [ "$#" -gt 0 ] && shift
    case "$sub" in
        gateid) cmd_gateid "$@" ;;
        answer) cmd_answer "$@" ;;
        consume) cmd_consume "$@" ;;
        state) cmd_state "$@" ;;
        peek) cmd_peek "$@" ;;
        "" | -h | --help | help)
            usage
            [ "$sub" = "" ] && return 2
            return 0
            ;;
        *)
            command echo "golem-inbox: unknown subcommand '$sub'" >&2
            usage
            return 2
            ;;
    esac
}

# Main-guard so the tests can source this file to unit-test the helper functions
# without driving a subcommand (mirrors golem-gate-watch.sh).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    inbox_main "$@"
    exit $?
fi
