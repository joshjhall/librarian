#!/usr/bin/env bash
# workflow-wall-timeout — deterministic wall-time stop DECISION for a bounded
# `Workflow` tool invocation (the ship-issue review / ci-fixer fan-out).
#
# Single source of truth for the "should I keep waiting on this Workflow run?"
# arithmetic (issue #327). #307 added LIBRARIAN_WORKFLOW_WALL_TIMEOUT to bound a
# hung review harness (#224), but wired it in as skill-instruction PROSE: the
# ship-issue *model* had to track cumulative wait, compare it to the threshold,
# count extensions, and TaskStop at the ceiling by hand. A model deep in a review
# cycle does not reliably do that arithmetic — three golems wedged unbounded
# (golem-266/252/263), same class as the pre-0.6 MAX_CYCLES-in-prose cap-drift.
# The skills now CALL this instead, so the threshold logic cannot drift.
#
# What this does NOT do: it does not (and cannot) forcibly stop the run. The
# `Workflow` / `TaskOutput` / `TaskStop` tools live in the model runtime; a
# bundled script runs in the sandboxed shell runtime and has no handle on a
# Workflow task. So this owns the DECISION (mirroring how autonomy-resolve.sh
# owns the L1-L4 disposition table); the caller still issues the actual TaskStop
# tool call — but on this script's verdict, not on its own reading of prose.
#
# Subcommand (emits `key=value` lines to stdout):
#   check --elapsed-min N --level L [--extensions-used K]
#         -> verdict           continue | extend | stop | checkpoint
#            ceiling_min        TIMEOUT * (MAX_EXTENSIONS + 1)   (the hard cap)
#            next_deadline_min  the wall-time of the next checkpoint to poll to
#            extensions_used    K, or K+1 when the verdict is `extend`
#
#   verdicts:
#     continue   — still under the current checkpoint; keep polling.
#     extend     — crossed the checkpoint, extensions remain, L3-L4: auto-grant
#                  one more interval (extensions_used echoes K+1).
#     checkpoint — crossed the checkpoint, extensions remain, L1-L2: a human
#                  chooses cut-short vs extend (never auto-extend interactively).
#     stop       — the ceiling is reached (extensions exhausted, or elapsed is
#                  already past ceiling): TaskStop the run and recover partials.
#
# Env overrides (same vars #307 defined; defaults match ship-protocol.md):
#   LIBRARIAN_WORKFLOW_WALL_TIMEOUT         integer minutes, default 20
#   LIBRARIAN_WORKFLOW_WALL_MAX_EXTENSIONS  integer >= 0,     default 1
#
# Exit codes: 0 = success; 2 = usage error (bad subcommand / flag / value).
#
# Runtime: bash-only (no python port — precedent: recover-journal-partials.sh).
# bash-3.2 clean (no associative arrays / mapfile / namerefs / case-conversion),
# clean under shellcheck, all coreutils reached via the `command` builtin, and
# fails loud on any bad input rather than emitting a wrong verdict. See CLAUDE.md
# § Key conventions (runtime policy).
set -euo pipefail

USAGE="Usage: workflow-wall-timeout check --elapsed-min N --level L [--extensions-used K]
  N = cumulative wall-minutes waited so far (non-negative integer)
  L = autonomy level 1-4
  K = extensions already granted (non-negative integer, default 0)
env: LIBRARIAN_WORKFLOW_WALL_TIMEOUT (default 20),
     LIBRARIAN_WORKFLOW_WALL_MAX_EXTENSIONS (default 1)"

# die <message> — fail loud: actionable message + usage on stderr, exit 2.
die() {
    command printf '%s\n%s\n' "$1" "$USAGE" >&2
    exit 2
}

# opt <name> -- <args...>
# Echo the token following <name> in the args after `--`. A value that itself
# starts with `--` is treated as absent. Exit status: 0 found, 1 not found.
opt() {
    _opt_name="$1"
    shift
    shift # consume the literal `--` separator
    _opt_prev=""
    _opt_found=1
    _opt_val=""
    for _opt_tok in "$@"; do
        if [ "$_opt_prev" = "$_opt_name" ]; then
            _opt_found=0
            case "$_opt_tok" in
                --*) ;;
                *) _opt_val="$_opt_tok" ;;
            esac
            break
        fi
        _opt_prev="$_opt_tok"
    done
    command printf '%s' "$_opt_val"
    return "$_opt_found"
}

# is_nonneg_int <value> — 0 if value is a non-negative integer, else 1. Empty and
# any non-digit (including a leading `-` or stray whitespace) fail.
is_nonneg_int() {
    case "$1" in
        '' | *[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# valid_level <value> — 0 if value is 1-4, else 1.
valid_level() {
    case "$1" in
        1 | 2 | 3 | 4) return 0 ;;
        *) return 1 ;;
    esac
}

cmd_check() {
    elapsed="$(opt --elapsed-min -- "$@" || true)"
    level="$(opt --level -- "$@" || true)"
    ext_used="$(opt --extensions-used -- "$@" || true)"

    # --extensions-used defaults to 0 (no extension granted yet).
    if [ -z "$ext_used" ]; then
        ext_used="0"
    fi

    if [ -z "$elapsed" ]; then
        die "workflow-wall-timeout: check needs --elapsed-min N"
    fi
    if ! is_nonneg_int "$elapsed"; then
        die "workflow-wall-timeout: --elapsed-min must be a non-negative integer, got '$elapsed'"
    fi
    if [ -z "$level" ]; then
        die "workflow-wall-timeout: check needs --level L"
    fi
    if ! valid_level "$level"; then
        die "workflow-wall-timeout: --level must be 1-4, got '$level'"
    fi
    if ! is_nonneg_int "$ext_used"; then
        die "workflow-wall-timeout: --extensions-used must be a non-negative integer, got '$ext_used'"
    fi

    # Thresholds from the env (same vars #307 defined). Validate — a bad
    # override must fail loud, never silently pick a wrong ceiling.
    timeout="${LIBRARIAN_WORKFLOW_WALL_TIMEOUT:-20}"
    max_ext="${LIBRARIAN_WORKFLOW_WALL_MAX_EXTENSIONS:-1}"
    if ! is_nonneg_int "$timeout" || [ "$timeout" -lt 1 ]; then
        die "workflow-wall-timeout: LIBRARIAN_WORKFLOW_WALL_TIMEOUT must be an integer >= 1, got '$timeout'"
    fi
    if ! is_nonneg_int "$max_ext"; then
        die "workflow-wall-timeout: LIBRARIAN_WORKFLOW_WALL_MAX_EXTENSIONS must be a non-negative integer, got '$max_ext'"
    fi

    # next_deadline: the checkpoint the current (K-extension) budget polls to.
    # ceiling: the hard cap once every extension is spent.
    next_deadline=$((timeout * (ext_used + 1)))
    ceiling=$((timeout * (max_ext + 1)))

    if [ "$elapsed" -lt "$next_deadline" ]; then
        # Still inside the current budget window — keep polling.
        verdict="continue"
        out_ext="$ext_used"
        out_deadline="$next_deadline"
    elif [ "$elapsed" -ge "$ceiling" ] || [ "$ext_used" -ge "$max_ext" ]; then
        # Ceiling reached (extensions exhausted, or elapsed already blew past the
        # hard cap) — stop and recover partials. This is the same STOP at every
        # level; the merge invariant is unaffected (a stopped review is partial).
        verdict="stop"
        out_ext="$ext_used"
        out_deadline="$ceiling"
    elif [ "$level" -ge 3 ]; then
        # Crossed the checkpoint with extensions left, L3-L4: auto-grant one more.
        verdict="extend"
        out_ext=$((ext_used + 1))
        out_deadline=$((timeout * (out_ext + 1)))
    else
        # Crossed the checkpoint with extensions left, L1-L2: a human decides.
        verdict="checkpoint"
        out_ext="$ext_used"
        out_deadline="$next_deadline"
    fi

    command printf 'verdict=%s\n' "$verdict"
    command printf 'ceiling_min=%s\n' "$ceiling"
    command printf 'next_deadline_min=%s\n' "$out_deadline"
    command printf 'extensions_used=%s\n' "$out_ext"
}

if [ "$#" -eq 0 ]; then
    die "workflow-wall-timeout: missing subcommand"
fi
sub="$1"
shift
case "$sub" in
    check) cmd_check "$@" ;;
    *) die "workflow-wall-timeout: unknown subcommand '$sub'" ;;
esac
