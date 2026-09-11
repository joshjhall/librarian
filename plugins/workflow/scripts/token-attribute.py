#!/usr/bin/env python3
"""token-attribute -- where did the tokens go? The transcript side of #781.

The Bifrost gateway (#781, token-report.sh) gives authoritative fleet totals but
cannot say WHICH tool, skill or session shape spent them: it sees requests, not
the tool_use blocks inside them. This reads the local Claude Code transcripts
under ~/.claude/projects and answers the "where" half, emitting the same joinable
TSV contract so the two numbers can be put side by side.

Filed for issue #788. The analyses below are the ones that produced the
2026-08-23 fleet-burn findings; that analysis was hand-written and thrown away,
which is the whole reason this exists as code.

FOUR TRAPS, ENCODED AS ASSERTIONS RATHER THAN COMMENTS. Each makes a
measurement CONFIDENTLY WRONG rather than loudly broken -- the reading looks
plausible, so nobody re-checks it. The rule for each is below; the fixture that
fails when it is broken, and the reasoning behind each fixture's shape, live in
tests/validate-token-attribute.sh (every one mutation-verified).

  1. DEDUP BY message.id. Claude Code writes one JSONL line per assistant
     CONTENT BLOCK, not one per turn, and every line of a turn repeats that
     turn's SAME usage. A naive per-line sum runs ~2x high (2.7x measured;
     .claude/memory/token-scrape-transcript-dedup.md). Read usage ONCE per id.

  2. UNION THE BLOCKS ACROSS THOSE LINES. The obvious dedup -- group by id, take
     .[0] -- is a worse bug, because the lines carry DIFFERENT blocks: an early
     pass in this analysis reported 4 Bash calls where there were 176, and 0
     thinking tokens where there were 62,233. iter_turns() below is the single
     place blocks are reached, so .[0] has nowhere to be reintroduced.

  3. THINKING TOKENS ARE IN usage.output_tokens_details.thinking_tokens. The
     `thinking` content blocks are empty strings, so a character count over
     content returns 0 and hides 55-86% of subagent output. No fallback to
     measuring the blocks exists, deliberately.

  4. NAIVE TIMESTAMPS ARE LOCAL; GATEWAY FIGURES ARE UTC. Mixing them misfiles a
     5-hour band of runs (.claude/memory/review-cost-after-2026-07-28.md). --tz
     names the zone a naive stamp is read in; everything emitted is UTC.

Subcommands (one per analysis the findings needed):
  debt         per-tool re-read debt -- result size x turns remaining
  floor        context-floor decomposition: prompt vs listings vs instructions
  growth       per-decile cost growth within a session
  prefix       subagent prefix distribution across spawns
  bash-class   Bash command read-vs-mutate classification
  attachments  attachment-type volume

OUTPUT is the #781 TSV contract: `#`-prefixed comment lines (header + the column
names) followed by rows whose first two fields are always window_start and model,
so a consumer strips /^#/ and joins positionally against token-report.sh's
window output. Transcripts carry message.model, so that join key is read, not
synthesized.

Exit codes: 0 = success; 2 = usage error; 3 = no transcripts found.

Runtime: Python 3.11+, with NO bash fallback -- a deliberate decision, recorded
here because #788 asked for the reason rather than a default either way. The
patterns.sh pre-scan family keeps a bash body because it scans source with grep,
which bash 3.2 can do. This tool walks newline-delimited JSON and sums per-turn
usage accounting, which bash 3.2 cannot do correctly, and it is an OPERATOR
ANALYSIS TOOL rather than a member of that family, so the dual-runtime
convention does not reach it. Per CLAUDE.md § Key conventions (runtime policy) a
tool must FAIL LOUD rather than silently emit wrong or empty findings when its
runtime is missing: the sibling token-attribute.sh shim exits 77 (the reserved
"did not run" sentinel), never 0.
"""

from __future__ import annotations

import argparse
import os
import pathlib
import sys

# sys.path seeding rather than a package: this file is executed directly
# (`python3 token-attribute.py`, which is how the sibling token-attribute.sh
# shim exec's it), so there is no package context and a relative import would
# fail. Its own name carries a hyphen and is therefore not importable either,
# which is why the shared code lives in the two underscore-named siblings rather
# than here. Same idiom as check-decomposition/patterns.py and
# ship-issue/split-verify.py.
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

from token_attribute_engine import (  # noqa: E402
    Window,
    _require_python,
    parse_ts,
    resolve_tz,
    transcript_root,
)
from token_attribute_reports import (  # noqa: E402
    cmd_attachments,
    cmd_bash_class,
    cmd_debt,
    cmd_floor,
    cmd_growth,
    cmd_prefix,
)

SUBCOMMANDS = {
    "debt": cmd_debt,
    "floor": cmd_floor,
    "growth": cmd_growth,
    "prefix": cmd_prefix,
    "bash-class": cmd_bash_class,
    "attachments": cmd_attachments,
}


def main(argv: list[str] | None = None) -> int:
    _require_python()

    parser = argparse.ArgumentParser(
        prog="token-attribute",
        description="Transcript-side token attribution: where did the tokens go?",
    )
    parser.add_argument(
        "subcommand",
        nargs="?",
        default="debt",
        choices=tuple(SUBCOMMANDS),
        help="which analysis to emit (default: debt)",
    )
    parser.add_argument(
        "--root",
        type=pathlib.Path,
        default=None,
        help="transcript root (default: ~/.claude/projects)",
    )
    parser.add_argument(
        "--tz",
        default="UTC",
        help=(
            "IANA zone that NAIVE timestamps are interpreted in before "
            "normalizing to UTC (default: UTC). Every emitted stamp is UTC "
            "regardless, so it joins against gateway figures"
        ),
    )
    parser.add_argument(
        "--since",
        default=None,
        help=(
            "window start, ISO-8601 (inclusive). Pass the SAME boundary given "
            "to `token-report.sh window --start` -- it becomes the emitted "
            "window_start, which is what makes the two joinable. Without it the "
            "scan covers every transcript under --root and says so"
        ),
    )
    parser.add_argument(
        "--until",
        default=None,
        help="window end, ISO-8601 (exclusive); pairs with --since",
    )
    args = parser.parse_args(argv)

    tz = resolve_tz(args.tz)
    # A window boundary is parsed with the SAME function transcript stamps go
    # through, so a naive --since is interpreted in --tz exactly as a naive
    # transcript stamp is. Two different parsers here would reintroduce trap 4
    # at the boundary rather than in the data.
    since = parse_ts(args.since, tz) if args.since else None
    until = parse_ts(args.until, tz) if args.until else None
    if args.since and since is None:
        print(
            f"token-attribute: unparseable --since {args.since!r}; "
            f"expected ISO-8601 (e.g. 2026-08-23T00:00:00Z).",
            file=sys.stderr,
        )
        return 2
    if args.until and until is None:
        print(
            f"token-attribute: unparseable --until {args.until!r}; "
            f"expected ISO-8601 (e.g. 2026-08-24T00:00:00Z).",
            file=sys.stderr,
        )
        return 2
    if since is not None and until is not None and until <= since:
        print(
            f"token-attribute: --until ({args.until}) is not after "
            f"--since ({args.since}); that window selects nothing.",
            file=sys.stderr,
        )
        return 2
    window = Window(since, until)

    root = args.root or transcript_root()
    if not root.is_dir():
        print(f"token-attribute: no transcript root at {root}", file=sys.stderr)
        return 3

    return SUBCOMMANDS[args.subcommand](root, tz, window)


if __name__ == "__main__":
    sys.exit(main())
