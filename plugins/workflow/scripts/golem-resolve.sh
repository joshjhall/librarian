#!/usr/bin/env bash
# golem-resolve.sh — emit an EXPLICIT clearing signal for a resolved gate.
#
# The orchestrate BLOCKED list (golem-status.sh, and the golem-gate-watch.sh
# --once snapshot it delegates to) drops a golem only when its MOST-RECENT feed
# line stops being a fresh `gate`/`escalation`/`dead-end` — normally an `idle`
# emitted once the golem moves on supersedes the stale gate. But the compliant
# plan-approval broker resolves a plan gate with `tmux send-keys -t golem-{N} 1
# Enter`, which fires NO Notification, so golem-notify.sh writes no superseding
# line and the stale `gate` keeps rendering BLOCKED for the whole
# GOLEM_BLOCK_TTL window (default 3600s). That trains the operator to treat the
# BLOCKED list as noise and risks dismissing a genuine fresh gate (issue #422).
#
# This helper closes the hole: after the send-keys, the orchestrator runs
#   ${CLAUDE_PLUGIN_ROOT}/scripts/golem-resolve.sh {N}
# to synthesize a `RESOLVED:`-prefixed Notification and pipe it to the hook. The
# hook classifies it as the `resolved` event kind, which — like `idle` — is NOT
# in the BLOCKED set, so as the golem's most-recent line it supersedes the stale
# gate on the very next sweep (no reader change needed).
#
# Usage:  golem-resolve.sh <N|golem-N> [message]
#   <N|golem-N>  the golem/issue number, bare (7) or prefixed (golem-7).
#   [message]    optional human-readable reason; defaults to
#                "plan gate approved via send-keys".
#
# Why this is a script and not a one-liner in the broker prose: the resolution
# runs in the ORCHESTRATOR's session and cwd (the main checkout), NOT inside the
# golem's worktree. golem-notify.sh derives the golem id from $GOLEM_ID first,
# else the git worktree-root basename — from the orchestrator's cwd that
# basename is the main repo, not `issue-N`, so the hook would stamp `golem-?`
# and the clearing line would never correlate to the blocked golem. This helper
# forces GOLEM_ID=golem-<N> so the synthesized line carries the right id. It
# never blocks and swallows hook errors (the hook itself always exits 0).
set -uo pipefail

# --- Portable tool resolution (#443) ----------------------------------------
# This helper runs under a potentially stripped PATH (its no-jq escaper path is
# tested with PATH reduced to bash only), so `command <tool>` would fail to find
# an external core utility there — yet a hardcoded /usr/bin/<tool> is wrong on macOS.
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

SCRIPT_DIR="$(cd "$("$DIRNAME" "${BASH_SOURCE[0]}")" && pwd)"

# The Notification hook lives one level up under hooks/. Resolve it relative to
# this script so golem-resolve.sh works whether invoked via CLAUDE_PLUGIN_ROOT
# or a direct path.
NOTIFY_HOOK="$SCRIPT_DIR/../hooks/golem-notify.sh"

usage() {
    command cat >&2 <<'EOF'
usage: golem-resolve.sh <N|golem-N> [message]

  Emit a `resolved` feed line for a golem so its stale plan gate is cleared from
  the BLOCKED list on the next sweep. Call it right after the plan-approval
  `tmux send-keys -t golem-{N} 1 Enter`.
EOF
    return 0
}

# Normalize a bare number or a `golem-N` token to `golem-N`, validating that the
# result is a well-formed golem id (mirrors golem-inbox.sh's inbox_valid_golem:
# `golem-` prefix, then only [A-Za-z0-9_.-] so the id can't carry path/shell
# metacharacters). Prints the normalized id on success; returns 1 on a malformed
# argument.
resolve_normalize_golem() {
    local arg="$1" golem
    case "$arg" in
        golem-*) golem="$arg" ;;
        *) golem="golem-$arg" ;;
    esac
    case "$golem" in
        golem-*)
            case "$golem" in
                *[!A-Za-z0-9_.-]*) return 1 ;;
                *) command printf '%s' "$golem" ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

resolve_main() {
    case "${1:-}" in
        "" | -h | --help | help)
            usage
            [ -z "${1:-}" ] && return 2
            return 0
            ;;
    esac

    local golem
    if ! golem="$(resolve_normalize_golem "$1")"; then
        command echo "golem-resolve: invalid golem id '$1' (want N or golem-N)" >&2
        return 2
    fi
    shift

    local message="${1:-plan gate approved via send-keys}"

    if [ ! -x "$NOTIFY_HOOK" ]; then
        command echo "golem-resolve: notify hook not found/executable at $NOTIFY_HOOK" >&2
        return 1
    fi

    # Build the Notification payload. Prefer jq for correct escaping of the
    # (possibly free-text) message; fall back to a hand-rolled literal that
    # sanitizes control chars/backslashes and escapes quotes, mirroring the
    # no-jq path in golem-notify.sh so a crafted message can't break the JSON.
    local payload
    if command -v jq >/dev/null 2>&1; then
        payload="$(jq -cn --arg m "RESOLVED: $message" '{message: $m}')"
    else
        local msg_safe
        msg_safe="$(command printf '%s' "RESOLVED: ${message//\\/}" | "$TR" -d '[:cntrl:]')"
        payload="$(command printf '{"message":"%s"}' "${msg_safe//\"/\\\"}")"
    fi

    # Force GOLEM_ID so the hook stamps the correct golem id from the
    # orchestrator's cwd (see header). The hook always exits 0; swallow anyway.
    command printf '%s' "$payload" | GOLEM_ID="$golem" "$NOTIFY_HOOK" || true
    return 0
}

# Main-guard so the tests can source this file to unit-test resolve_normalize_golem
# without driving the emit path (mirrors golem-inbox.sh / golem-gate-watch.sh).
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    resolve_main "$@"
    exit $?
fi
