#!/usr/bin/env python3
"""autonomy-resolve — deterministic autonomy-level gate-disposition resolver.

Single source of truth for the L1-L4 autonomy decision table (issue #190). The
business rules — level selection, the severity/critical cap, per-gate
disposition, the dead-end override, and the derived autonomous/plan_gated
mirrors — used to live as prose re-derived by every skill on every run. This
script computes them once so /next-issue, /ship-issue, and /orchestrate all read
the same verdict instead of re-interpreting the table (and drifting).

Authoritative contract: plugins/workflow/skills/orchestrate/autonomy-levels.md
(#174). This file encodes that contract; the prose now *describes* this resolver.

Python 3.11+ primary implementation behind a language-agnostic key=value stdout
contract; the sibling autonomy-resolve.sh is the portable bash fallback (it
exec's this file when a python3>=3.11 is present). Both emit byte-identical
output — the parity is pinned by tests/validate-autonomy-resolve.sh. See
CLAUDE.md § Key conventions (runtime policy).

Subcommands (each emits `key=value` lines to stdout, one per line):

  level  [--from-args STR] [--chosen-level N] [--severity LABEL]
         -> autonomy_level, autonomous, plan_gated, capped, perm_mode
     Resolve the run's level from the --level flag / setup answer, apply the
     critical cap, and emit the derived dispositions. --from-args is the raw
     invocation argument string, scanned for --level N. --chosen-level is a
     level resolved from a non-CLI source (an orchestrator dispatch or the
     operator's interactive L1-L4 answer). --severity accepts `critical` or
     `severity/critical`. --level {1,2,3,4} is the sole autonomy input; the old
     alias flags (--autonomous/--auto/--force-auto/--skip-plan/--plan-gate) and
     the NEXT_ISSUE_AUTONOMOUS env var were removed in #215.

  gate <routine|escalation> --level N [--dead-end]
         -> disposition (auto|human)
     Dispatch one gate: routine gates auto-pass at L3-L4 (human at L1-L2);
     escalation gates auto-pass at L4 only (human at L1-L3); a --dead-end defers
     to a human at every level, L4 included.

  read [--state-level N]
         -> autonomy_level
     Resolve the level a persisted state file records: a present state-level
     wins (validated 1-4); absent -> L1.

Exit codes:
  0 = success
  2 = usage error (unknown subcommand, missing/invalid flag, out-of-range level)
"""

from __future__ import annotations

import sys

USAGE = (
    "Usage: autonomy-resolve <level|gate|read> [options]\n"
    "  level [--from-args STR] [--chosen-level N] [--severity LABEL]\n"
    "  gate <routine|escalation> --level N [--dead-end]\n"
    "  read [--state-level N]"
)


def die(message: str) -> int:
    """Fail loud: actionable message on stderr, usage-error exit code."""
    sys.stderr.write(message + "\n")
    sys.stderr.write(USAGE + "\n")
    return 2


def opt(args: list[str], name: str, allow_flag_value: bool = False) -> str | None:
    """Return the value following `--name` in args, or None if absent.

    A bare `--name` with no following token (or a following token that looks
    like another flag) yields an empty string, which the numeric validators
    below reject — so a malformed `--level` fails loud rather than silently.
    `allow_flag_value=True` lifts the flag-like guard for options whose value is
    itself a flag string — notably `--from-args "--level 4"`.
    """
    for i, tok in enumerate(args):
        if tok == name:
            if i + 1 < len(args) and (
                allow_flag_value or not args[i + 1].startswith("--")
            ):
                return args[i + 1]
            return ""
    return None


def parse_level(value: str | None) -> int | None:
    """Coerce a level string to an int 1-4; raise ValueError otherwise."""
    if value is None:
        return None
    if value not in ("1", "2", "3", "4"):
        raise ValueError(value)
    return int(value)


def is_critical(severity: str) -> bool:
    """True for `critical` or a `severity/critical` label form."""
    return severity.rsplit("/", 1)[-1] == "critical"


def cmd_level(args: list[str]) -> int:
    from_args = opt(args, "--from-args", allow_flag_value=True) or ""
    severity = opt(args, "--severity") or ""

    tokens = from_args.split()

    try:
        args_level = parse_level(opt(tokens, "--level"))
        chosen_level = parse_level(opt(args, "--chosen-level"))
    except ValueError as exc:
        return die("autonomy-resolve: level must be 1-4, got '" + str(exc) + "'")

    # Level selection precedence: an explicit --level flag, then a level chosen
    # at setup (orchestrator dispatch / interactive answer), then the L1 default.
    # --level {1,2,3,4} is the sole autonomy input (#215). (See
    # orchestrate/autonomy-levels.md § Level selection.)
    if args_level is not None:
        level = args_level
    elif chosen_level is not None:
        level = chosen_level
    else:
        level = 1

    # Critical cap: a critical issue never exceeds L3, so it always keeps its
    # escalation gates (plan approval) in front of a human. No override lifts it.
    capped = False
    if level == 4 and is_critical(severity):
        level = 3
        capped = True

    autonomous = level == 4
    # plan_gated: the plan gate (escalation) is kept for a human at L1-L3 (incl.
    # a capped critical) and auto-passed only at L4.
    plan_gated = level <= 3
    perm_mode = "acceptEdits" if level == 1 else "auto"

    sys.stdout.write("autonomy_level=" + str(level) + "\n")
    sys.stdout.write("autonomous=" + ("true" if autonomous else "false") + "\n")
    sys.stdout.write("plan_gated=" + ("true" if plan_gated else "false") + "\n")
    sys.stdout.write("capped=" + ("true" if capped else "false") + "\n")
    sys.stdout.write("perm_mode=" + perm_mode + "\n")
    return 0


def cmd_gate(args: list[str]) -> int:
    if not args or args[0].startswith("--"):
        return die("autonomy-resolve: gate needs a class (routine|escalation)")
    gate_class = args[0]
    if gate_class not in ("routine", "escalation"):
        return die(
            "autonomy-resolve: gate class must be routine|escalation, got "
            "'" + gate_class + "'"
        )

    try:
        level = parse_level(opt(args, "--level"))
    except ValueError as exc:
        return die("autonomy-resolve: level must be 1-4, got '" + str(exc) + "'")
    if level is None:
        return die("autonomy-resolve: gate needs --level N")

    dead_end = "--dead-end" in args

    # A dead-end has no safe auto-resolution (it would cross the merge
    # invariant), so it defers to a human at every level, L4 included.
    if dead_end:
        disposition = "human"
    elif gate_class == "routine":
        disposition = "auto" if level >= 3 else "human"
    else:  # escalation
        disposition = "auto" if level >= 4 else "human"

    sys.stdout.write("disposition=" + disposition + "\n")
    return 0


def cmd_read(args: list[str]) -> int:
    state_level = opt(args, "--state-level")

    if state_level:
        try:
            level = parse_level(state_level)
        except ValueError as exc:
            return die(
                "autonomy-resolve: state-level must be 1-4, got '" + str(exc) + "'"
            )
    else:
        level = 1

    sys.stdout.write("autonomy_level=" + str(level) + "\n")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        return die("autonomy-resolve: missing subcommand")
    sub = argv[1]
    rest = argv[2:]
    if sub == "level":
        return cmd_level(rest)
    if sub == "gate":
        return cmd_gate(rest)
    if sub == "read":
        return cmd_read(rest)
    return die("autonomy-resolve: unknown subcommand '" + sub + "'")


if __name__ == "__main__":
    sys.exit(main(sys.argv))
