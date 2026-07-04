#!/usr/bin/env bash
# autonomy-resolve — deterministic autonomy-level gate-disposition resolver.
#
# Single source of truth for the L1-L4 autonomy decision table (issue #190):
# level selection, the severity/critical cap, per-gate disposition, the dead-end
# override, and the derived autonomous/plan_gated mirrors. The skills CALL this
# instead of re-deriving the table in prose, so /next-issue, /ship-issue, and
# /orchestrate all read the same verdict (and cannot drift).
#
# Authoritative contract: skills/orchestrate/autonomy-levels.md (#174).
#
# Subcommands (each emits `key=value` lines to stdout):
#   level [--from-args STR] [--chosen-level N] [--severity LABEL]
#         -> autonomy_level, autonomous, plan_gated, capped, perm_mode
#   gate  <routine|escalation> --level N [--dead-end]  -> disposition (auto|human)
#   read  [--state-level N]  -> autonomy_level
#
# --level {1,2,3,4} is the sole autonomy input; the old alias flags
# (--autonomous/--auto/--force-auto/--skip-plan/--plan-gate) and the
# NEXT_ISSUE_AUTONOMOUS env var were removed in #215.
#
# Exit codes: 0 = success; 2 = usage error (bad subcommand / flag / level).
#
# Runtime: Python 3.11+ primary (autonomy-resolve.py) with this bash script as
# the portable fallback. The shim below exec's the .py when a python3>=3.11 is
# present (identical key=value contract); PATTERNS_FORCE_BASH=1 forces this bash
# body. Parity is pinned by tests/validate-autonomy-resolve.sh. Uses full paths
# for commands per project shell-scripting conventions. bash-3.2 clean (no
# associative arrays / namerefs / case-conversion). See CLAUDE.md § Key
# conventions (runtime policy).
set -euo pipefail

# --- runtime selection: prefer python3>=3.11, else this bash fallback --------
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${PATTERNS_FORCE_BASH:-0}" != "1" ] && [ -f "$_here/autonomy-resolve.py" ] &&
    command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    exec python3 "$_here/autonomy-resolve.py" "$@"
fi

USAGE="Usage: autonomy-resolve <level|gate|read> [options]
  level [--from-args STR] [--chosen-level N] [--severity LABEL]
  gate <routine|escalation> --level N [--dead-end]
  read [--state-level N]"

# die <message> — fail loud: actionable message + usage on stderr, exit 2.
die() {
    command printf '%s\n%s\n' "$1" "$USAGE" >&2
    exit 2
}

# opt <name> <allow_flag_value> -- <args...>
# Echo the token following <name> in the args after `--`. With allow_flag_value=0
# a value that itself starts with `--` is treated as absent (empty). Returns
# whether the flag was found (0) or not (1) via exit status; the value is echoed.
opt() {
    _opt_name="$1"
    _opt_allow="$2"
    shift 2
    shift # consume the literal `--` separator
    _opt_prev=""
    _opt_found=1
    _opt_val=""
    for _opt_tok in "$@"; do
        if [ "$_opt_prev" = "$_opt_name" ]; then
            _opt_found=0
            case "$_opt_tok" in
                --*) [ "$_opt_allow" = "1" ] && _opt_val="$_opt_tok" ;;
                *) _opt_val="$_opt_tok" ;;
            esac
            break
        fi
        _opt_prev="$_opt_tok"
    done
    # A trailing bare `--name` (name is the last token) still counts as found.
    if [ "$_opt_found" = "1" ] && [ "$_opt_prev" = "$_opt_name" ]; then
        _opt_found=0
    fi
    command printf '%s' "$_opt_val"
    return "$_opt_found"
}

# valid_level <value> — 0 if value is 1-4, else 1.
valid_level() {
    case "$1" in
        1 | 2 | 3 | 4) return 0 ;;
        *) return 1 ;;
    esac
}

# is_critical <severity-label> — 0 for `critical` or `.../critical`.
is_critical() {
    case "$1" in
        critical | */critical) return 0 ;;
        *) return 1 ;;
    esac
}

cmd_level() {
    from_args="$(opt --from-args 1 -- "$@" || true)"
    severity="$(opt --severity 0 -- "$@" || true)"

    # args_level: an embedded --level inside --from-args.
    args_level=""
    if opt --level 0 -- $from_args >/dev/null 2>&1; then
        args_level="$(opt --level 0 -- $from_args || true)"
        if [ -n "$args_level" ] && ! valid_level "$args_level"; then
            die "autonomy-resolve: level must be 1-4, got '$args_level'"
        fi
    fi
    chosen_level=""
    if opt --chosen-level 0 -- "$@" >/dev/null 2>&1; then
        chosen_level="$(opt --chosen-level 0 -- "$@" || true)"
        if [ -n "$chosen_level" ] && ! valid_level "$chosen_level"; then
            die "autonomy-resolve: level must be 1-4, got '$chosen_level'"
        fi
    fi

    # Level selection precedence: explicit --level, then a level chosen at setup
    # (orchestrator / interactive answer), then L1. --level {1,2,3,4} is the sole
    # autonomy input (#215).
    if [ -n "$args_level" ]; then
        level="$args_level"
    elif [ -n "$chosen_level" ]; then
        level="$chosen_level"
    else
        level="1"
    fi

    # Critical cap: a critical issue never exceeds L3, so it always keeps its
    # escalation gates (plan approval) in front of a human.
    capped="false"
    if [ "$level" = "4" ] && is_critical "$severity"; then
        level="3"
        capped="true"
    fi

    if [ "$level" = "4" ]; then
        autonomous="true"
    else
        autonomous="false"
    fi
    # plan_gated: the plan gate (escalation) is kept for a human at L1-L3 (incl.
    # a capped critical) and auto-passed only at L4.
    if [ "$level" != "4" ]; then
        plan_gated="true"
    else
        plan_gated="false"
    fi
    if [ "$level" = "1" ]; then
        perm_mode="acceptEdits"
    else
        perm_mode="auto"
    fi

    command printf 'autonomy_level=%s\n' "$level"
    command printf 'autonomous=%s\n' "$autonomous"
    command printf 'plan_gated=%s\n' "$plan_gated"
    command printf 'capped=%s\n' "$capped"
    command printf 'perm_mode=%s\n' "$perm_mode"
}

cmd_gate() {
    if [ "$#" -eq 0 ]; then
        die "autonomy-resolve: gate needs a class (routine|escalation)"
    fi
    gate_class="$1"
    case "$gate_class" in
        --*) die "autonomy-resolve: gate needs a class (routine|escalation)" ;;
        routine | escalation) ;;
        *) die "autonomy-resolve: gate class must be routine|escalation, got '$gate_class'" ;;
    esac

    level=""
    if opt --level 0 -- "$@" >/dev/null 2>&1; then
        level="$(opt --level 0 -- "$@" || true)"
    fi
    if [ -z "$level" ]; then
        die "autonomy-resolve: gate needs --level N"
    fi
    if ! valid_level "$level"; then
        die "autonomy-resolve: level must be 1-4, got '$level'"
    fi

    dead_end=1
    case " $* " in
        *" --dead-end "*) dead_end=0 ;;
    esac

    # A dead-end has no safe auto-resolution (it would cross the merge
    # invariant), so it defers to a human at every level, L4 included.
    if [ "$dead_end" = "0" ]; then
        disposition="human"
    elif [ "$gate_class" = "routine" ]; then
        if [ "$level" -ge 3 ]; then disposition="auto"; else disposition="human"; fi
    else
        if [ "$level" -ge 4 ]; then disposition="auto"; else disposition="human"; fi
    fi

    command printf 'disposition=%s\n' "$disposition"
}

cmd_read() {
    state_level="$(opt --state-level 0 -- "$@" || true)"

    if [ -n "$state_level" ]; then
        if ! valid_level "$state_level"; then
            die "autonomy-resolve: state-level must be 1-4, got '$state_level'"
        fi
        level="$state_level"
    else
        level="1"
    fi

    command printf 'autonomy_level=%s\n' "$level"
}

if [ "$#" -eq 0 ]; then
    die "autonomy-resolve: missing subcommand"
fi
sub="$1"
shift
case "$sub" in
    level) cmd_level "$@" ;;
    gate) cmd_gate "$@" ;;
    read) cmd_read "$@" ;;
    *) die "autonomy-resolve: unknown subcommand '$sub'" ;;
esac
