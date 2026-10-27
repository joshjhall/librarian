#!/usr/bin/env bash
# ci-wait — the bounded CI-wait POLL LOOP for ship-issue, as one plain command.
#
# Issue #1244. ci-monitor-protocol.md told the caller to "poll `gh pr checks`
# every 30 s, calling ci-wait-timeout.sh each poll" and left the loop to the
# reader. The natural loop reads the check state into a variable — `s=$(gh pr
# checks …)` — and a worktree-isolated session REFUSES a command substitution
# (next-issue/worktree-safe-recipes.md). Golems always run isolated, so they
# improvised `gh pr checks N --watch`, which is accepted but UNBOUNDED: it never
# calls ci-wait-timeout.sh, dropping the ceiling #588 mechanized after #327's
# three wedged golems. Moving the loop in here makes the recipe a single literal
# command the harness can verify, and puts the bound in code rather than in a
# loop every caller has to write correctly.
#
# Division of labour, deliberately unchanged from #588: ci-wait-timeout.sh stays
# the ONLY source of the continue/extend/checkpoint/stop verdict. This file owns
# the clock and the poll; it calls the sibling every poll and never re-derives
# the threshold arithmetic (tests/validate-ci-wait.sh pins that it calls it).
#
# Usage:
#   ci-wait.sh <pr> --level L [--elapsed-min N] [--extensions-used K]
#              [--interval S] [--repo OWNER/NAME]
#
#   --elapsed-min / --extensions-used resume an earlier wait (after an L1-L2
#   checkpoint "Extend", re-invoke with the values this script printed).
#   --interval defaults to 30 s.
#
# Stdout: `key=value` lines, read bare (worktree-safe-recipes.md Pattern 1):
#   result           pass | fail | pending
#   verdict          the last ci-wait-timeout.sh verdict (or `-` when CI
#                    resolved before any timing decision was needed)
#   elapsed_min      cumulative minutes, including any --elapsed-min carried in
#   extensions_used  K after any auto-granted (L3-L4) extensions
#   ceiling_min      the hard cap ci-wait-timeout.sh reported
#
# Exit codes — each one a distinct next action for the caller:
#   0  CI passed             -> proceed to the review loop
#   1  a check failed        -> triage (ci-monitor-protocol.md § c)
#   2  usage error
#   3  gh/timeout helper failed — fail loud; NEVER read as a pass
#   8  checkpoint (L1-L2)    -> ask the human: cut short, or extend by
#                               re-invoking with --extensions-used K+1
#                               (8 mirrors `gh pr checks`' own "pending" code)
#   9  stop: still pending at the ceiling -> completion summary, CI-pending note
#
# What counts as pending: any check in bucket `pending`, AND an EMPTY check list.
# A PR whose workflows have not registered yet reports zero checks; reading that
# as green would merge on CI that never ran — silence reading as a pass.
#
# Env: LIBRARIAN_CI_WAIT_POLL_TIMEOUT — seconds one `gh pr checks` call may
#   take (default 60); a call past it fails loud (exit 3).
#
# Runtime: bash-3.2 clean, no GNU-only flags, coreutils via `command`. `gh` is
# called by name so a test can stub it on PATH.
set -euo pipefail

SCRIPT_DIR="$(cd "$(command dirname "${BASH_SOURCE[0]}")" && pwd)"
TIMEOUT_HELPER="$SCRIPT_DIR/ci-wait-timeout.sh"
# shellcheck source=./bounded-run.sh
. "$SCRIPT_DIR/bounded-run.sh"

# Each `gh` call is bounded too. Bounding only the LOOP would leave one hung
# network call able to wedge the wait forever — the unbounded shape this script
# exists to remove, one level down. Override for a slow API host.
POLL_TIMEOUT_SECS="${LIBRARIAN_CI_WAIT_POLL_TIMEOUT:-60}"

USAGE="Usage: ci-wait.sh <pr> --level L [--elapsed-min N] [--extensions-used K]
                  [--interval S] [--repo OWNER/NAME]
env: LIBRARIAN_CI_WAIT_TIMEOUT, LIBRARIAN_CI_WAIT_MAX_EXTENSIONS
     (read by ci-wait-timeout.sh)"

die_usage() {
    command printf 'ci-wait: %s\n%s\n' "$1" "$USAGE" >&2
    exit 2
}

is_nonneg_int() {
    case "$1" in
        '' | *[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# --- Arguments -----------------------------------------------------------------
pr=""
level=""
carried_min="0"
ext_used="0"
interval="30"
repo=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --level | --elapsed-min | --extensions-used | --interval | --repo)
            [ "$#" -ge 2 ] || die_usage "$1 needs a value"
            case "$1" in
                --level) level="$2" ;;
                --elapsed-min) carried_min="$2" ;;
                --extensions-used) ext_used="$2" ;;
                --interval) interval="$2" ;;
                --repo) repo="$2" ;;
            esac
            shift 2
            ;;
        -h | --help)
            command printf '%s\n' "$USAGE"
            exit 0
            ;;
        -*) die_usage "unknown flag '$1'" ;;
        *)
            [ -z "$pr" ] || die_usage "unexpected argument '$1'"
            pr="$1"
            shift
            ;;
    esac
done

[ -n "$pr" ] || die_usage "needs a PR number"
is_nonneg_int "$pr" || die_usage "PR must be a number, got '$pr'"
[ -n "$level" ] || die_usage "needs --level L"
is_nonneg_int "$carried_min" || die_usage "--elapsed-min must be a non-negative integer, got '$carried_min'"
is_nonneg_int "$ext_used" || die_usage "--extensions-used must be a non-negative integer, got '$ext_used'"
is_nonneg_int "$interval" || die_usage "--interval must be a non-negative integer, got '$interval'"
is_nonneg_int "$POLL_TIMEOUT_SECS" && [ "$POLL_TIMEOUT_SECS" -ge 1 ] ||
    die_usage "LIBRARIAN_CI_WAIT_POLL_TIMEOUT must be an integer >= 1, got '$POLL_TIMEOUT_SECS'"
bounded_run_available || {
    command printf 'ci-wait: cannot bound gh calls on this host (bounded_run unavailable)\n' >&2
    exit 3
}
# --level is validated by ci-wait-timeout.sh, the one owner of that rule; its
# exit 2 surfaces below as ours on the first poll.

# --- One poll --------------------------------------------------------------------
# Reduce every check to one word with gh's own --jq, so no jq binary is needed.
# Order matters: a failure wins over pending (a red check is final regardless of
# what is still running), and the empty list is pending, never pass.
JQ_REDUCE='map(.bucket) | if length == 0 then "pending"
  elif any(.[]; . == "fail" or . == "cancel") then "fail"
  elif any(.[]; . == "pending") then "pending"
  else "pass" end'

poll_state() {
    local rc=0 out
    if [ -n "$repo" ]; then
        out="$(bounded_run "$POLL_TIMEOUT_SECS" gh pr checks "$pr" --repo "$repo" \
            --json bucket --jq "$JQ_REDUCE")" || rc=$?
    else
        out="$(bounded_run "$POLL_TIMEOUT_SECS" gh pr checks "$pr" \
            --json bucket --jq "$JQ_REDUCE")" || rc=$?
    fi
    # gh signals the check state in its exit code too (8 = pending, 1 = a check
    # failed), so 0/1/8 are all readable answers — provided the output is one of
    # the three words below. A real gh error also exits 1, but then the output is
    # gh's diagnostic, which the word check rejects: the WORD is authoritative.
    case "$rc" in
        0 | 1 | 8) ;;
        124)
            command printf 'ci-wait: gh pr checks %s did not answer within %ss\n' "$pr" "$POLL_TIMEOUT_SECS" >&2
            return 3
            ;;
        *)
            command printf 'ci-wait: gh pr checks %s failed (exit %s): %s\n' "$pr" "$rc" "$out" >&2
            return 3
            ;;
    esac
    case "$out" in
        pass | fail | pending) command printf '%s' "$out" ;;
        # A PR whose workflows have not registered yet makes gh exit 1 with this
        # diagnostic instead of printing `[]`. It is the same race the empty-list
        # rule covers, so it is pending, never a hard failure on poll 1.
        "no checks reported on the "*)
            [ "$rc" -eq 1 ] && command printf 'pending' && return 0
            command printf 'ci-wait: unexpected gh output (exit %s): %s\n' "$rc" "$out" >&2
            return 3
            ;;
        *)
            command printf 'ci-wait: unreadable check state from gh: %s\n' "$out" >&2
            return 3
            ;;
    esac
}

# val <key> <text> — the value of a `key=value` line. Pure bash: no sed/grep.
val() {
    local line
    while IFS= read -r line; do
        case "$line" in
            "$1="*)
                command printf '%s' "${line#"$1"=}"
                return 0
                ;;
        esac
    done <<EOF
$2
EOF
    return 1
}

emit() {
    command printf 'result=%s\nverdict=%s\nelapsed_min=%s\nextensions_used=%s\nceiling_min=%s\n' \
        "$1" "$verdict" "$elapsed" "$ext_used" "$ceiling"
}

# --- Loop -----------------------------------------------------------------------
start="$(command date +%s)"
verdict="-"
elapsed="$carried_min"
ceiling="-"

while :; do
    state="$(poll_state)" || exit 3
    now="$(command date +%s)"
    elapsed=$((carried_min + (now - start) / 60))

    case "$state" in
        pass)
            emit pass
            exit 0
            ;;
        fail)
            emit fail
            exit 1
            ;;
    esac

    # Still pending: ask the one owner of the bound what to do.
    hrc=0
    decision="$("$TIMEOUT_HELPER" check --elapsed-min "$elapsed" \
        --level "$level" --extensions-used "$ext_used" 2>&1)" || hrc=$?
    if [ "$hrc" -ne 0 ]; then
        command printf 'ci-wait: ci-wait-timeout.sh refused (exit %s):\n%s\n' "$hrc" "$decision" >&2
        # A usage error there is a usage error here (bad --level, bad env).
        [ "$hrc" -eq 2 ] && exit 2
        exit 3
    fi
    verdict="$(val verdict "$decision" || true)"
    ceiling="$(val ceiling_min "$decision" || true)"
    new_ext="$(val extensions_used "$decision" || true)"

    case "$verdict" in
        continue) ;;
        extend)
            # Never carry an unparsed value forward: an empty K would make the
            # next helper call a usage error mid-wait.
            is_nonneg_int "$new_ext" || {
                command printf 'ci-wait: extend without a numeric extensions_used: %s\n' "$decision" >&2
                exit 3
            }
            ext_used="$new_ext"
            ;;
        checkpoint)
            emit pending
            exit 8
            ;;
        stop)
            emit pending
            exit 9
            ;;
        *)
            command printf 'ci-wait: unknown verdict from ci-wait-timeout.sh: %s\n' "$decision" >&2
            exit 3
            ;;
    esac

    command sleep "$interval"
done
