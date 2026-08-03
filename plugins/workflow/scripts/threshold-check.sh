#!/usr/bin/env bash
# threshold-check — shared implementation of the bounded-wait stop DECISION.
#
# Two skill-driven poll loops in this plugin wait on something that may never
# finish, and both need the same question answered each poll: "keep waiting,
# grant another interval, ask the human, or give up?"
#
#   ship-issue CI-wait loop        -> ci-wait-timeout.sh        (#588)
#   ship-issue Workflow fan-out    -> workflow-wall-timeout.sh  (#327)
#
# They differ ONLY in which env vars they read and what those default to. The
# arithmetic, the input validation, and the fail-loud plumbing are identical, so
# they live here once. That is the point: #327 exists because this arithmetic was
# left in PROSE for the model to do by hand and three golems (266/252/263) wedged
# unbounded. Duplicating the mechanized version per-loop would re-open the same
# drift in a new form — one copy could gain a fix the other never got.
#
# Sourced, never executed. A caller supplies its identity and thresholds, then
# hands over its argv:
#
#     SCRIPT_DIR="$(cd "$(command dirname "${BASH_SOURCE[0]}")" && pwd)"
#     # shellcheck source=./threshold-check.sh
#     . "$SCRIPT_DIR/threshold-check.sh"
#     threshold_check_main <tool> <timeout_var> <timeout_default> \
#                          <ext_var> <ext_default> <usage> "$@"
#
# What this does NOT do: it does not (and cannot) forcibly stop anything. The
# `Workflow` / `TaskOutput` / `TaskStop` tools and the `gh pr checks` poll live in
# the model runtime; a bundled script runs in the sandboxed shell runtime and has
# no handle on them. So this owns the DECISION (mirroring how autonomy-resolve.sh
# owns the L1-L4 disposition table); the caller still issues the actual stop — but
# on this script's verdict, not on its own reading of prose.
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
#                  already past ceiling): give up and recover what partials exist.
#
# Exit codes: 0 = success; 2 = usage error (bad subcommand / flag / value).
#
# Runtime: bash-only (no python port — precedent: recover-journal-partials.sh).
# bash-3.2 clean (no associative arrays / mapfile / namerefs / case-conversion),
# clean under shellcheck, all coreutils reached via the `command` builtin, and
# fails loud on any bad input rather than emitting a wrong verdict. See CLAUDE.md
# § Key conventions (runtime policy).

# Set by threshold_check_main; read by the helpers below. Every message names the
# CALLER's tool and env vars, so a failure is actionable without the operator
# knowing this shared file exists.
TC_TOOL=""
TC_USAGE=""
TC_TIMEOUT_VAR=""
TC_EXT_VAR=""

# tc_die <message> — fail loud: actionable message + usage on stderr, exit 2.
tc_die() {
    command printf '%s\n%s\n' "$1" "$TC_USAGE" >&2
    exit 2
}

# tc_opt <name> -- <args...>
# Echo the token following <name> in the args after `--`. A value that itself
# starts with `--` is treated as absent. Exit status: 0 found, 1 not found.
tc_opt() {
    _tc_opt_name="$1"
    shift
    shift # consume the literal `--` separator
    _tc_opt_prev=""
    _tc_opt_found=1
    _tc_opt_val=""
    for _tc_opt_tok in "$@"; do
        if [ "$_tc_opt_prev" = "$_tc_opt_name" ]; then
            _tc_opt_found=0
            case "$_tc_opt_tok" in
                --*) ;;
                *) _tc_opt_val="$_tc_opt_tok" ;;
            esac
            break
        fi
        _tc_opt_prev="$_tc_opt_tok"
    done
    command printf '%s' "$_tc_opt_val"
    return "$_tc_opt_found"
}

# tc_is_nonneg_int <value> — 0 if value is a non-negative integer in canonical
# base-10 form, else 1. Empty, any non-digit (a leading `-` or stray whitespace),
# AND a leading-zero numeral all fail. Rejecting leading zeros is deliberate: the
# accepted values feed bash arithmetic (`$(( ))`, `[ -lt ]`), where `030` is read
# as OCTAL — that silently applies a wrong threshold (ceiling 48, not 60) and `08`
# crashes with "value too great for base", both bypassing this script's fail-loud
# exit-2 contract (the silent-wrong-verdict class #327 exists to kill). `0` itself
# is the sole valid zero.
tc_is_nonneg_int() {
    case "$1" in
        '' | *[!0-9]*) return 1 ;;
        0) return 0 ;;
        0*) return 1 ;;
        *) return 0 ;;
    esac
}

# tc_valid_level <value> — 0 if value is 1-4, else 1.
tc_valid_level() {
    case "$1" in
        1 | 2 | 3 | 4) return 0 ;;
        *) return 1 ;;
    esac
}

# tc_cmd_check <timeout_default> <ext_default> <args...>
tc_cmd_check() {
    _tc_timeout_default="$1"
    _tc_ext_default="$2"
    shift 2

    elapsed="$(tc_opt --elapsed-min -- "$@" || true)"
    level="$(tc_opt --level -- "$@" || true)"
    ext_used="$(tc_opt --extensions-used -- "$@" || true)"

    # --extensions-used defaults to 0 (no extension granted yet).
    if [ -z "$ext_used" ]; then
        ext_used="0"
    fi

    if [ -z "$elapsed" ]; then
        tc_die "$TC_TOOL: check needs --elapsed-min N"
    fi
    if ! tc_is_nonneg_int "$elapsed"; then
        tc_die "$TC_TOOL: --elapsed-min must be a non-negative integer, got '$elapsed'"
    fi
    if [ -z "$level" ]; then
        tc_die "$TC_TOOL: check needs --level L"
    fi
    if ! tc_valid_level "$level"; then
        tc_die "$TC_TOOL: --level must be 1-4, got '$level'"
    fi
    if ! tc_is_nonneg_int "$ext_used"; then
        tc_die "$TC_TOOL: --extensions-used must be a non-negative integer, got '$ext_used'"
    fi

    # Thresholds from the env. Validate — a bad override must fail loud, never
    # silently pick a wrong ceiling. Indirect expansion (`${!var}`) reads the
    # caller's var by name; it is bash-3.2-supported and, unlike `eval`, cannot
    # execute the value.
    timeout="${!TC_TIMEOUT_VAR:-$_tc_timeout_default}"
    max_ext="${!TC_EXT_VAR:-$_tc_ext_default}"
    if ! tc_is_nonneg_int "$timeout" || [ "$timeout" -lt 1 ]; then
        tc_die "$TC_TOOL: $TC_TIMEOUT_VAR must be an integer >= 1, got '$timeout'"
    fi
    if ! tc_is_nonneg_int "$max_ext"; then
        tc_die "$TC_TOOL: $TC_EXT_VAR must be a non-negative integer, got '$max_ext'"
    fi
    # --extensions-used can never exceed the ceiling's extension count: a K past
    # max_ext is a caller bookkeeping bug (or MAX_EXTENSIONS lowered mid-run), and
    # left unchecked it inflates next_deadline (timeout*(K+1)) past the ceiling and
    # keeps returning `continue` — a silently-extended budget, the very drift this
    # helper removes. Fail loud instead of computing a verdict from invalid state.
    if [ "$ext_used" -gt "$max_ext" ]; then
        tc_die "$TC_TOOL: --extensions-used ($ext_used) exceeds $TC_EXT_VAR ($max_ext)"
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
        # level; the merge invariant is unaffected (a stopped wait is partial).
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

# threshold_check_main <tool> <timeout_var> <timeout_default> <ext_var>
#                      <ext_default> <usage> [argv...]
#
# The whole CLI: argv dispatch plus the check subcommand. A wrapper supplies its
# identity and thresholds and forwards "$@" — so a wrapper carries only what
# genuinely differs between the two loops, and cannot drift on what does not.
threshold_check_main() {
    TC_TOOL="$1"
    TC_TIMEOUT_VAR="$2"
    _tc_main_timeout_default="$3"
    TC_EXT_VAR="$4"
    _tc_main_ext_default="$5"
    TC_USAGE="$6"
    shift 6

    if [ "$#" -eq 0 ]; then
        tc_die "$TC_TOOL: missing subcommand"
    fi
    _tc_main_sub="$1"
    shift
    case "$_tc_main_sub" in
        check)
            tc_cmd_check "$_tc_main_timeout_default" "$_tc_main_ext_default" "$@"
            ;;
        *) tc_die "$TC_TOOL: unknown subcommand '$_tc_main_sub'" ;;
    esac
}
