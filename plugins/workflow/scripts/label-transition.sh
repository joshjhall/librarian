#!/usr/bin/env bash
# label-transition.sh — perform a status-label transition in a SAFE ORDER.
#
# Context (issues #636, #921). The workflow skills move an issue between
# `status/*` labels at every pipeline boundary: in-progress -> pr-pending when a
# PR opens, in-progress -> commit-pending on the commit-only path. Every one of
# those transitions was spelled in PROSE as a single combined call:
#
#     gh issue edit N --add-label status/pr-pending --remove-label status/in-progress
#
# That call is NOT ATOMIC, AND ITS PARTIAL EFFECT IS THE DANGEROUS HALF.
# MEASURED against real `gh` on issue #921 (2026-09-06), not inferred:
#
#     $ gh issue edit 921 --add-label status/definitely-not-real \
#                         --remove-label status/in-progress
#     failed to update …: 'status/definitely-not-real' not found
#     $ gh issue view 921 --json labels     # -> no status label at all
#
# The REMOVE is applied first and PERSISTS; the add then fails validation and
# the call reports failure. So the outcome is not "nothing happened" — it is
# precisely the worst case: the old label is gone, the new one never arrived.
# An earlier draft of this header said gh "validates every label up front and
# fails the whole call", which sounds reassuring and is FALSE; the measurement
# above is what replaced it.
#
# WHAT ACTUALLY HAPPENED ON #636. `/workflow:ship-issue` Option 3 set
# `status/commit-pending`, a label that did not exist in the repo. The call
# failed; the issue was left with NO status label at all — the add did not land
# and the pre-existing `status/in-progress` was gone. An issue with no status
# label is re-selectable by the next-issue priority walk, so for as long as that
# window stayed open another golem could pick up an issue whose work was still
# in flight. In a four-lane orchestration run that is a double-dispatch window,
# not a cosmetic labeling glitch.
#
# WHY CREATING THE MISSING LABEL IS NOT THE FIX. #921 created
# `status/commit-pending` and `status/blocked`, which removes today's trigger.
# It does not remove the SHAPE: any future label failure — a typo in a recipe, a
# label renamed out from under the docs, a rate-limited or auth-expired call —
# reproduces #636 exactly. The ordering is the defect; the missing label was
# only the first thing to expose it.
#
# THE ORDER: ADD FIRST, AND ONLY REMOVE IF THE ADD SUCCEEDED.
#
#   * add fails -> STOP. The issue keeps its existing status label, so it stays
#     un-selectable and no double-dispatch window opens. The operator sees a
#     non-zero exit and an actionable message.
#   * add succeeds -> remove. Both labels are briefly present, which is
#     harmless: every consumer (the next-issue priority walk, golem-status.sh,
#     tracks-runbook.sh) treats ANY status label as "do not select".
#
# The failure mode is therefore a STUCK label, never an ABSENT one. That
# asymmetry is the whole point — a stuck label is visible and costs one manual
# edit, while an absent one is invisible and costs a collision.
#
# WHY THIS IS A SCRIPT AND NOT A PROSE RULE. Precedent: threshold-check.sh,
# which exists because bounded-wait arithmetic "left in PROSE for the model to
# do by hand" wedged three golems (#327). Ordering left in prose is the same
# class of defect and #636 is its first casualty. A prose rule also cannot be
# TESTED: with the ordering in a script, tests/validate-label-transition.sh can
# point a real invocation at a label that does not exist and assert the
# pre-existing status survives. That assertion is what AC3 asks for, and it is
# unavailable as long as every transition is a sentence in a markdown file.
#
# Usage:
#   label-transition.sh set <issue> --add <label> --remove <label>
#                                   [--platform gh|glab]
#
#   --add / --remove may each be given at most once. Either may be omitted:
#   an add-only call is a plain add, a remove-only call is a plain remove.
#   Omitting both is a usage error (nothing to do is never intended).
#
#   --platform defaults to autodetection from `git remote -v` (github -> gh,
#   gitlab -> glab), falling back to gh.
#
# Exit codes:
#   0 = the transition completed (or the add-only / remove-only op succeeded)
#   1 = the ADD failed; nothing was removed, the old label is intact
#   2 = usage error (bad subcommand / flag / missing value)
#   3 = the add succeeded but the REMOVE failed (stuck label — see above)
#  77 = required CLI absent (fail loud; never a silent no-op)
#
# Runtime: bash-only. bash-3.2 clean (no associative arrays / mapfile /
# namerefs / case-conversion), BSD-regex clean, clean under shellcheck, all
# coreutils reached via the `command` builtin, and fails loud on bad input
# rather than performing a partial transition. See CLAUDE.md § Key conventions.

set -euo pipefail

USAGE='Usage: label-transition.sh set <issue> --add <label> --remove <label> [--platform gh|glab]'

# lt_die <message> — fail loud: actionable message + usage on stderr, exit 2.
lt_die() {
    command printf '%s\n%s\n' "$1" "$USAGE" >&2
    exit 2
}

# lt_is_issue_number <value> — 0 if a positive base-10 integer, else 1.
# Leading zeros are rejected for the same reason threshold-check.sh rejects
# them: the value is interpolated into a CLI call, and `007` naming a different
# issue than `7` is a silent wrong-target bug.
lt_is_issue_number() {
    case "$1" in
        '' | *[!0-9]*) return 1 ;;
        0) return 1 ;;
        0*) return 1 ;;
        *) return 0 ;;
    esac
}

# lt_detect_platform — echo gh or glab, derived from the origin remote.
# Mirrors the table in next-issue/SKILL.md § Platform Detection. Falls back to
# gh when the remote matches neither, which is what the skills already do.
lt_detect_platform() {
    _lt_remote="$(command git remote -v 2>/dev/null | command head -n1 || true)"
    case "$_lt_remote" in
        *gitlab.com* | *gitlab.*) command printf 'glab' ;;
        *) command printf 'gh' ;;
    esac
}

lt_set() {
    _lt_issue="${1:-}"
    [ -n "$_lt_issue" ] || lt_die 'missing <issue> argument'
    lt_is_issue_number "$_lt_issue" ||
        lt_die "issue must be a positive integer, got '$_lt_issue'"
    shift

    _lt_add=""
    _lt_remove=""
    _lt_platform=""
    _lt_saw_add=1
    _lt_saw_remove=1

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --add)
                [ "$_lt_saw_add" -eq 1 ] || lt_die '--add given more than once'
                _lt_saw_add=0
                shift
                [ "$#" -gt 0 ] || lt_die '--add requires a label'
                _lt_add="$1"
                ;;
            --remove)
                [ "$_lt_saw_remove" -eq 1 ] || lt_die '--remove given more than once'
                _lt_saw_remove=0
                shift
                [ "$#" -gt 0 ] || lt_die '--remove requires a label'
                _lt_remove="$1"
                ;;
            --platform)
                shift
                [ "$#" -gt 0 ] || lt_die '--platform requires a value'
                _lt_platform="$1"
                ;;
            *) lt_die "unknown argument: $1" ;;
        esac
        shift
    done

    # A label that starts with `--` is almost certainly a swallowed flag (the
    # caller wrote `--add --remove x`), not a label named `--remove`. Reject it
    # rather than sending a malformed call to the CLI.
    case "$_lt_add" in --*) lt_die "--add value looks like a flag: $_lt_add" ;; esac
    case "$_lt_remove" in --*) lt_die "--remove value looks like a flag: $_lt_remove" ;; esac

    if [ -z "$_lt_add" ] && [ -z "$_lt_remove" ]; then
        lt_die 'nothing to do: give --add, --remove, or both'
    fi

    if [ -z "$_lt_platform" ]; then
        _lt_platform="$(lt_detect_platform)"
    fi
    case "$_lt_platform" in
        gh | glab) ;;
        *) lt_die "--platform must be gh or glab, got '$_lt_platform'" ;;
    esac

    # Fail loud on an absent CLI. A missing `gh` must never read as a completed
    # transition — that is the silent-skip class the 77 sentinel exists for.
    if ! command -v "$_lt_platform" >/dev/null 2>&1; then
        command printf '%s not found on PATH — cannot perform label transition for #%s\n' \
            "$_lt_platform" "$_lt_issue" >&2
        exit 77
    fi

    # --- THE ORDERING. Add first; remove ONLY if the add succeeded. ----------
    if [ -n "$_lt_add" ]; then
        if ! lt_apply "$_lt_platform" add "$_lt_issue" "$_lt_add"; then
            command printf \
                'FAILED to add %s to #%s — leaving existing labels untouched.\n' \
                "$_lt_add" "$_lt_issue" >&2
            if [ -n "$_lt_remove" ]; then
                command printf \
                    '  %s was NOT removed: the issue keeps its current status and stays un-selectable (#636/#921).\n' \
                    "$_lt_remove" >&2
            fi
            command printf \
                '  Check the label exists: %s\n' \
                "$(lt_list_hint "$_lt_platform")" >&2
            exit 1
        fi
    fi

    if [ -n "$_lt_remove" ]; then
        if ! lt_apply "$_lt_platform" remove "$_lt_issue" "$_lt_remove"; then
            command printf \
                'Added %s but FAILED to remove %s from #%s.\n' \
                "${_lt_add:-<nothing>}" "$_lt_remove" "$_lt_issue" >&2
            command printf \
                '  The issue now carries BOTH labels. That is the safe direction — it stays un-selectable — but remove %s by hand.\n' \
                "$_lt_remove" >&2
            exit 3
        fi
    fi

    exit 0
}

# lt_apply <platform> <add|remove> <issue> <label>
# The single place a label CLI is invoked. Exit status is the CLI's.
lt_apply() {
    _lt_p="$1"
    _lt_op="$2"
    _lt_n="$3"
    _lt_l="$4"

    if [ "$_lt_p" = "gh" ]; then
        if [ "$_lt_op" = "add" ]; then
            command gh issue edit "$_lt_n" --add-label "$_lt_l"
        else
            command gh issue edit "$_lt_n" --remove-label "$_lt_l"
        fi
    else
        if [ "$_lt_op" = "add" ]; then
            command glab issue update "$_lt_n" --label "$_lt_l"
        else
            command glab issue update "$_lt_n" --unlabel "$_lt_l"
        fi
    fi
}

# lt_list_hint <platform> — the command an operator runs to check the vocabulary.
lt_list_hint() {
    if [ "$1" = "gh" ]; then
        command printf 'gh label list'
    else
        command printf 'glab label list'
    fi
}

_lt_cmd="${1:-}"
[ -n "$_lt_cmd" ] || lt_die 'missing subcommand'
shift || true

case "$_lt_cmd" in
    set) lt_set "$@" ;;
    *) lt_die "unknown subcommand: $_lt_cmd" ;;
esac
