#!/usr/bin/env bash
# golem-auth.sh — auth-token delivery for golem-launch.sh: resolve the
# Anthropic token and hand it to the golem through a 0600 file, so the value is
# never printed and never appears in any argv. Sourced, never executed:
#
#     SCRIPT_DIR="$(cd "$(command dirname "${BASH_SOURCE[0]}")" && pwd)"
#     # shellcheck source=./bounded-run.sh
#     . "$SCRIPT_DIR/bounded-run.sh"
#     # shellcheck source=./golem-auth.sh
#     . "$SCRIPT_DIR/golem-auth.sh"
#
# Requires `bounded_run` (bounded-run.sh), which the SOURCING script loads
# first; this file does not source it again. Split out of golem-launch.sh
# (#1162) for cohesion — this is the whole token-handling surface — not for size.

# _bounded_op_read <ref> — print the op secret at <ref> on stdout, wall-clock
# bounded so a locked/absent op session can NEVER hang the dispatch (we have seen
# `op` block on "connecting to desktop app"). Any non-zero / empty result → prints
# nothing. Never prints diagnostics (would risk leaking).
#
# Bounded via bounded-run.sh (#543). This used to try `timeout`, then `gtimeout`,
# and SKIP the probe entirely when neither existed — safe, but it silently
# disabled op-based auth on exactly the base-macOS host the fallback was written
# for. The pure-shell watchdog needs only sleep/kill/mktemp, so the probe now both
# runs and stays bounded everywhere.
_bounded_op_read() {
    local ref="$1"
    [ -n "$ref" ] || return 0
    command -v op >/dev/null 2>&1 || return 0
    bounded_run 5 op read "$ref" 2>/dev/null || true
}

# resolve_auth_token — set RESOLVED_AUTH_TOKEN (and RESOLVED_BASE_URL when it
# came from the cache) WITHOUT ever printing the value. Resolution order, first
# hit wins:
#   1. the launcher's own inherited env ($ANTHROPIC_AUTH_TOKEN);
#   2. the container startup cache ($OP_SECRETS_CACHE, default
#      /dev/shm/op-secrets-cache) — sourced in a SUBSHELL so its other exports
#      never leak into the launcher, emitting just token<TAB>baseurl;
#   3. a last-resort time-bounded `op read` of $OP_ANTHROPIC_AUTH_TOKEN_REF.
# Every arm degrades to empty (→ no injection) when its source is absent, so on a
# bare host / macOS / OAuth setup this is a silent no-op.
RESOLVED_AUTH_TOKEN=""
RESOLVED_BASE_URL=""
resolve_auth_token() {
    RESOLVED_AUTH_TOKEN=""
    RESOLVED_BASE_URL=""

    # 1. Already in the launcher's env — nothing to resolve.
    if [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
        RESOLVED_AUTH_TOKEN="$ANTHROPIC_AUTH_TOKEN"
        RESOLVED_BASE_URL="${ANTHROPIC_BASE_URL:-}"
        return 0
    fi

    # 2. Container startup cache. Source in a subshell (its other secrets stay
    # out of the launcher env) and emit token<TAB>baseurl; the cache's own stdout
    # is muted so a chatty cache can't corrupt the capture.
    local cache="${OP_SECRETS_CACHE:-/dev/shm/op-secrets-cache}" line
    if [ -r "$cache" ]; then
        line="$(
            # shellcheck disable=SC1090  # dynamic, host-provided cache path
            . "$cache" >/dev/null 2>&1
            command printf '%s\t%s' "${ANTHROPIC_AUTH_TOKEN:-}" "${ANTHROPIC_BASE_URL:-}"
        )"
        RESOLVED_AUTH_TOKEN="${line%%$'\t'*}"
        RESOLVED_BASE_URL="${line#*$'\t'}"
        [ -n "$RESOLVED_AUTH_TOKEN" ] && return 0
        RESOLVED_BASE_URL=""
    fi

    # 3. Last resort: a time-bounded `op read` of the configured ref.
    if [ -n "${OP_ANTHROPIC_AUTH_TOKEN_REF:-}" ]; then
        RESOLVED_AUTH_TOKEN="$(_bounded_op_read "$OP_ANTHROPIC_AUTH_TOKEN_REF")"
    fi
    return 0
}

# _sh_quote <value> — print <value> as ONE single-quoted POSIX sh word, so a
# token or path carrying `'`, `$`, or spaces survives `sh -c` / `.` verbatim.
# Splits on `'` with ${v%%…}/${v#…} rather than a ${v//…/…} replacement string:
# how a replacement treats backslashes and quotes changed across bash 3.2, 4.3
# and 5.2 (patsub_replacement), and macOS ships 3.2. Each `'` becomes `'\''`.
_sh_quote() {
    local rest="$1" out=""
    while :; do
        case "$rest" in
            *"'"*)
                out="$out${rest%%"'"*}'\\''"
                rest="${rest#*"'"}"
                ;;
            *)
                out="$out$rest"
                break
                ;;
        esac
    done
    command printf "'%s'" "$out"
}

# write_auth_file — write the resolved token (and the base URL, whenever one is
# known) as `export` lines into a fresh owner-only (0600) file under
# ${TMPDIR:-/tmp}, and print its path. The base URL is the launcher's own when
# set (it wins over the cache's, #244), else the cache's. It is written even
# when the launcher has one: an already-running tmux server hands a new session
# its GLOBAL env, not this client's, so the golem would otherwise run with no
# base URL or a stale one and send a proxy-issued token to the wrong endpoint
# (#1163). With no resolved token no file is written at all, so that launch's
# URL still rides the server env (#1170). The golem's session command sources
# then deletes it
# (#1153), so the token never appears in any argv. Fails (non-zero, no path)
# when the file cannot be created or written; a partial file is removed. A
# session killed before its first command runs leaves the file behind — still
# 0600, readable only by this uid.
write_auth_file() {
    local f url="${ANTHROPIC_BASE_URL:-$RESOLVED_BASE_URL}"
    f="$(umask 077 && command mktemp "${TMPDIR:-/tmp}/golem-auth.XXXXXX" 2>/dev/null)" || return 1
    [ -n "$f" ] || return 1
    # The session `.`-sources this path AFTER tmux -c has moved it into the
    # worktree, so a relative TMPDIR would resolve against the wrong directory
    # and the golem would start tokenless. Anchor it to the launcher's cwd.
    case "$f" in
        /*) ;;
        *) f="$(command pwd)/$f" ;;
    esac
    command chmod 600 "$f" 2>/dev/null || {
        command rm -f "$f"
        return 1
    }
    {
        command printf 'export ANTHROPIC_AUTH_TOKEN=%s\n' "$(_sh_quote "$RESOLVED_AUTH_TOKEN")"
        if [ -n "$url" ]; then
            command printf 'export ANTHROPIC_BASE_URL=%s\n' "$(_sh_quote "$url")"
        fi
    } >"$f" 2>/dev/null || {
        command rm -f "$f"
        return 1
    }
    command printf '%s' "$f"
}
