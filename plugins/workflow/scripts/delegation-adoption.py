#!/usr/bin/env python3
"""delegation-adoption — did the investigation-delegation guidance actually fire?

Reads local Claude Code transcripts and answers the question #785's guidance
could not answer about itself: is read-only investigation being routed to
subagents, and when it is not, were there opportunities that should have been?

Filed for issue #797, which owns #785's AC5/AC6. See
docs/verification/delegation-recall-tally-785.md.

WHY A TOOL AND NOT A HAND COUNT. The headline result this instrument produced is
a ZERO -- no delegated fan-out investigations in the measured corpus. A zero is
the claim most in need of a reproducible method, because the boring explanation
for any zero is that the counter looked in the wrong place. Hand-counting
transcripts is also exactly the archaeology #781 was filed to end. So the count
ships as code a second reader can re-run.

THE CLASSIFICATION THAT CARRIES THE VERDICT. Not every subagent spawn is a
delegated investigation. Two kinds sit side by side on disk and they mean
opposite things for AC5:

  harness   spawned BY a workflow.js harness -- the ship-issue review fan-out.
            Path contains a `workflows/` segment. These are numerous and prove
            nothing about the guidance: they would happen with or without it.
  direct    spawned by a session calling the Agent tool itself. These are the
            only candidates for "someone delegated an investigation".

Counting all spawns together is the trap: it reports healthy triple-digit
"delegation" on a corpus where the guidance never fired once.

THE DENOMINATOR IS WHAT MAKES A ZERO MEAN ANYTHING. "Nobody delegated" is
consistent with "nobody had anything worth delegating". The `opportunities`
subcommand sizes the inline investigation results the main session actually
absorbed and counts those clearing the guidance's own break-even. Zero
delegations against zero opportunities is a quiet corpus; zero against many is a
finding about the guidance.

THE BREAK-EVEN IS A PRODUCT, NOT A SIZE (delegating-investigation/SKILL.md): a
result costs its token volume times how many turns it stays resident, because it
is re-sent with every later request. A 3k result living 40 turns outweighs a 20k
result three turns from the end.

Subcommands:
  adoption       harness-vs-direct spawn split, grouped by agentType
  opportunities  inline investigation results clearing the break-even
  ac5            per-direct-spawn return-value size + anchor presence

WHAT `ac5` DOES NOT MEASURE. #785's AC5 asks whether the PARENT's context growth
across a delegation is bounded by the conclusion rather than by the volume the
subagent read. That is a measurement over the PARENT transcript's per-turn cache
accounting. This subcommand does not take it: it sizes the SUBAGENT's return
value and checks whether it carries `path:line` anchors -- a proxy for
"conclusion, not transcript", on the sound reasoning that the parent can only
absorb what it was handed. Read its output as return-value shape, never as
measured parent-context growth. The growth recipe lives in
docs/verification/delegation-recall-tally-785.md § AC5 and is unimplemented here
because the corpus contains no fan-out delegation to run it against.

Exit codes: 0 = success; 2 = usage error; 3 = no transcripts found.

Runtime: Python 3.11+. Like its sibling measure-spawn-prefix.py this tool has NO
bash fallback -- it walks newline-delimited JSON, which bash 3.2 cannot do
correctly, and the sibling shim fails loud rather than degrade. See CLAUDE.md
§ Key conventions (runtime policy).
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys

MIN_PYTHON = (3, 11)

# The delegation break-even, in tokens, from delegating-investigation/SKILL.md.
# Billing-weighted median spawn prefix (#787, n=33) -- NOT the raw 29,298 median,
# which overstates the cost because the shared block is normally a cache hit at
# ~0.1x. Cite this figure; do not re-derive it here.
BREAK_EVEN_TOKENS = 24_650

# Rough chars-per-token divisor for sizing tool results. Deliberately crude: this
# decides whether a result is in the running for the break-even, and the products
# involved clear it by multiples, so a tighter tokenizer would not move a row.
CHARS_PER_TOKEN = 4

# Floor below which a tool result is not investigation worth sizing -- a status
# line, a short git output. Without it the opportunity count is dominated by
# hundreds of trivial results whose products are noise.
RESULT_FLOOR_TOKENS = 2_000

# A `path/to/file.ext:LINE` citation. Compiled once; see _has_anchor for what
# each part excludes and why this is one pattern rather than a chain of guards.
#
# `[^/\s:]+` -- one path segment containing no separator, space or colon -- is
# load-bearing for SPEED, not just meaning. The natural spelling `[\w.\-]*/[\w.\-]+`
# lets both sides match dots, so the engine retries every possible split of a
# dotted token: measured 8.5s on a single 40k-character token, versus 0.4ms here.
# This tool reads whatever text a transcript happens to contain, so a token that
# large is not hypothetical. Not catastrophic backtracking (no nested quantifier)
# but quadratic, which is slow enough to matter.
ANCHOR_RE = re.compile(r"/[^/\s:]+\.[A-Za-z]{1,4}:\d+")

# A token that begins `host.tld/` -- a URL wearing no scheme. `://` does not
# catch `example.com/repo/blob/main/src/app.py:42` or `www.example.com/a/b.py:9`,
# and both end in a real source extension, so ANCHOR_RE alone matches them. A
# link is not a citation however it is spelled.
DOMAIN_PREFIX_RE = re.compile(r"^[\w\-]+(?:\.[\w\-]+)+/")


def _require_python() -> None:
    """Fail loud on an unsupported interpreter rather than emit wrong numbers."""
    if sys.version_info < MIN_PYTHON:
        want = ".".join(str(p) for p in MIN_PYTHON)
        have = ".".join(str(p) for p in sys.version_info[:3])
        sys.exit(
            f"delegation-adoption: needs Python >= {want}, got {have}.\n"
            f"Install a newer python3 or run via the sibling "
            f"delegation-adoption.sh shim."
        )


def transcript_root() -> pathlib.Path:
    return pathlib.Path.home() / ".claude" / "projects"


def _agent_type(jsonl: pathlib.Path) -> str:
    """Read the spawn's declared agentType from its sidecar meta file.

    Guards the SHAPE as well as the parse, for the reason the sibling tool
    documents: `[1,2,3]` and `42` are valid JSON that sail past the except and
    then raise AttributeError on .get(), aborting a whole run over one malformed
    sidecar among dozens of good ones.
    """
    meta = jsonl.with_suffix(".meta.json")
    if not meta.exists():
        return "(unknown)"
    try:
        data = json.loads(meta.read_text())
    except (OSError, ValueError):
        return "(unknown)"
    if not isinstance(data, dict):
        return "(unknown)"
    return data.get("agentType") or data.get("subagent_type") or "(unknown)"


def _is_harness(jsonl: pathlib.Path) -> bool:
    """True when this spawn was fanned out by a workflow.js harness.

    Keyed on a `workflows/` PATH SEGMENT, not a substring: a session directory
    that merely contains the letters "workflows" (a worktree named for the
    workflow plugin, say) must not silently reclassify every direct spawn in it
    as harness traffic and manufacture the zero this tool exists to test.
    """
    return "workflows" in jsonl.parts


def iter_spawns(root: pathlib.Path):
    """Yield one record per subagent transcript found under `root`."""
    for jsonl in sorted(root.rglob("subagents/**/*.jsonl")):
        if jsonl.name == "journal.jsonl":
            continue
        yield {
            "file": str(jsonl.relative_to(root)),
            "agent_type": _agent_type(jsonl),
            "kind": "harness" if _is_harness(jsonl) else "direct",
            "path": jsonl,
        }


def _iter_records(jsonl: pathlib.Path):
    """Yield parsed records from a JSONL transcript, skipping unparseable lines."""
    try:
        lines = jsonl.read_text().splitlines()
    except OSError as exc:
        print(f"warning: unreadable {jsonl}: {exc}", file=sys.stderr)
        return
    for line in lines:
        if not line.strip():
            continue
        try:
            yield json.loads(line)
        except ValueError:
            continue


def _blocks(record: dict) -> list:
    """The content blocks of a record, normalized to a list.

    A message's `content` is a list of blocks OR a bare string -- the schema
    permits the latter for a simple text-only turn, and real transcripts contain
    both. Returning [] for the string shape would silently drop a spawn's final
    answer (changing what `ac5` scores) and skip a string-shaped tool_result
    (shrinking the opportunity denominator). Both are wrong-but-quiet outcomes,
    which is the failure mode this whole tool exists to avoid, so the string is
    lifted into the one-block form its callers already understand.
    """
    content = (record.get("message") or {}).get("content")
    if isinstance(content, list):
        return content
    if isinstance(content, str) and content:
        return [{"type": "text", "text": content}]
    return []


def _text_of(block: dict) -> str:
    """Flatten a tool_result's content to text for sizing and anchor-matching."""
    content = block.get("content")
    return content if isinstance(content, str) else json.dumps(content)


def main_sessions(root: pathlib.Path) -> list[pathlib.Path]:
    """Top-level session transcripts -- `<project>/<uuid>.jsonl`, not subagents.

    Subagent transcripts live one level deeper under `subagents/`, and their
    reading is precisely what a delegation keeps OUT of the main context. Sizing
    them here would count the delegated volume as if the parent had absorbed it.
    """
    return sorted(p for p in root.glob("*/*.jsonl") if "subagents" not in p.parts)


def iter_opportunities(root: pathlib.Path):
    """Yield each sizeable inline tool result with its residency and product.

    `turns_resident` is the number of records that follow the result in its own
    transcript -- an upper bound on how long it stayed in context, and the right
    shape for the break-even, which is about re-send debt rather than one-off
    size.
    """
    for jsonl in main_sessions(root):
        records = list(_iter_records(jsonl))
        for index, record in enumerate(records):
            for block in _blocks(record):
                if block.get("type") != "tool_result":
                    continue
                tokens = len(_text_of(block)) // CHARS_PER_TOKEN
                if tokens < RESULT_FLOOR_TOKENS:
                    continue
                resident = len(records) - index
                yield {
                    "session": jsonl.parent.name,
                    "tokens": tokens,
                    "turns_resident": resident,
                    "product": tokens * resident,
                }


def _has_anchor(text: str) -> bool:
    r"""True when the text cites at least one `path/to/file.ext:LINE` anchor.

    AC5 asks whether a delegation returned a CONCLUSION -- an answer plus the
    anchors to verify it -- rather than a transcript of what it read. Anchors are
    the cheap, checkable half of that; the size column beside it carries the
    other half. This yes/no IS that verdict, so both error directions corrupt the
    measurement: a false positive scores a return value that merely MENTIONED
    something as having cited its sources, and a false negative under-reports the
    behavior the guidance is trying to produce.

    ONE PATTERN RATHER THAN A CHAIN OF GUARDS. This started as incremental string
    surgery -- reject a scheme, require a separator, require an alphabetic
    extension -- and each addition fixed one shape while breaking another. Three
    false positives and two false negatives were measured across three review
    cycles; the version-string test even stopped discriminating when a later
    guard rejected its fixture one condition earlier. Stating the shape once is
    what makes the whole set checkable at a glance.

    What ANCHOR_RE requires, and what each part excludes:

      `/`                a path separator, so a bare `config.sh:41` and a
                         scheme-less `database.io:5432` (a TLD is
                         indistinguishable from a short extension) are both out.
      `[^/\s:]+`         one path segment, no colons -- and the spelling that
                         keeps the match linear (see ANCHOR_RE).
      `.[A-Za-z]{1,4}`   an ALPHABETIC extension, so `build/app.v2:8080` is out.
                         No source extension is a number.
      `:\d+`             a line number.

    `search`, not `match`, so surrounding punctuation and a trailing `:col` come
    free -- `src/app.py:42:` (pytest/mypy) and `pkg/mod.py:42:5` (ripgrep
    --vimgrep) both hit, and those two shapes are why this is a regex.

    A NOTE ON HOW MUCH THIS MATTERS. Four review cycles found seven errors here,
    which is out of proportion to the function's reach: on the corpus this tool
    was written for, the anchor column feeds exactly ONE row -- a docs lookup the
    tally already discounts as not a sample of the behavior AC5 asks about.
    Forcing this function to return True unconditionally changes no conclusion in
    that document. It is written to this standard because the column becomes
    load-bearing the moment adoption is non-zero (#978), not because it is
    load-bearing today. Weigh further hardening against that.

    A URL is rejected however it is spelled, because a link is not a citation
    even when it ends in a real source extension. Three spellings, all measured:
    `https://host/src/app.py:42` (the `://` guard), `//cdn.example.com/a.js:12`
    (protocol-relative), and `example.com/repo/src/app.py:42` (a bare domain --
    DOMAIN_PREFIX_RE, since nothing in the token says "not local").
    """
    for token in text.replace("\n", " ").split():
        if "://" in token:
            continue
        # Strip wrapping punctuation so a citation inside quotes, parens or a
        # markdown link still reaches the domain checks below with its real
        # first character.
        token = token.lstrip("([\"'")
        if token.startswith("//"):
            continue
        if DOMAIN_PREFIX_RE.match(token):
            continue
        if ANCHOR_RE.search(token):
            return True
    return False


def _return_value(jsonl: pathlib.Path) -> str | None:
    """The spawn's last assistant text -- what the parent actually received."""
    last = None
    for record in _iter_records(jsonl):
        if (record.get("message") or {}).get("role") != "assistant":
            continue
        for block in _blocks(record):
            if block.get("type") == "text" and block.get("text", "").strip():
                last = block["text"]
    return last


def cmd_adoption(spawns: list[dict]) -> None:
    direct = [s for s in spawns if s["kind"] == "direct"]
    harness = [s for s in spawns if s["kind"] == "harness"]

    print(f"spawns total           {len(spawns):,}")
    print(f"  harness (workflow.js) {len(harness):,}")
    print(f"  direct  (Agent tool)  {len(direct):,}")

    by_type: dict[str, dict[str, int]] = {}
    for spawn in spawns:
        row = by_type.setdefault(spawn["agent_type"], {"harness": 0, "direct": 0})
        row[spawn["kind"]] += 1

    print("\nper-agent-type (harness / direct):")
    for name, row in sorted(by_type.items(), key=lambda kv: -sum(kv[1].values())):
        print(f"  {name:<40} {row['harness']:>5} / {row['direct']:<5}")

    print(f"\ndelegated investigations (direct spawns): {len(direct):,}")
    if not direct:
        # State the negative explicitly. A silent absence of rows is how a "did
        # not run" gets read as a measured zero (#538/#571) -- the same reason
        # this tool exits 3 rather than 0 on an empty corpus.
        print(
            "NONE. No session in this corpus delegated an investigation.\n"
            "Run `opportunities` to see whether any qualified -- a zero against\n"
            "zero opportunities is a quiet corpus, not a finding."
        )


def cmd_opportunities(root: pathlib.Path) -> None:
    rows = list(iter_opportunities(root))
    if not rows:
        print(
            f"no inline tool results at or above {RESULT_FLOOR_TOKENS:,} tokens "
            f"in the main-session transcripts under {root}"
        )
        return

    clearing = [r for r in rows if r["product"] > BREAK_EVEN_TOKENS]
    sessions = {r["session"] for r in clearing}

    print(f"break-even             {BREAK_EVEN_TOKENS:,} tokens (tok x turns)")
    print(f"results >= {RESULT_FLOOR_TOKENS:,} tok     {len(rows):,}")
    print(
        f"  clearing break-even  {len(clearing):,} "
        f"({100 * len(clearing) / len(rows):.0f}%)"
    )
    print(f"  across sessions      {len(sessions):,}")
    if clearing:
        biggest = max(clearing, key=lambda r: r["product"])
        print(
            f"\nlargest: {biggest['tokens']:,} tok resident "
            f"{biggest['turns_resident']:,} turns = {biggest['product']:,}"
        )


def cmd_ac5(spawns: list[dict]) -> None:
    direct = [s for s in spawns if s["kind"] == "direct"]
    if not direct:
        print(
            "no direct spawns in this corpus -- AC5 is UNTESTED here.\n"
            "AC5 asks whether a delegation returned a conclusion rather than a\n"
            "transcript. With nothing delegated there is no return value to score,\n"
            "which is a different state from 'returned a dump'."
        )
        return

    print(f"{'agent_type':<34}{'ret~tok':>9}{'anchors':>9}")
    for spawn in direct:
        text = _return_value(spawn["path"])
        if text is None:
            print(f"{spawn['agent_type']:<34}{'n/a':>9}{'n/a':>9}")
            continue
        tokens = len(text) // CHARS_PER_TOKEN
        print(
            f"{spawn['agent_type']:<34}{tokens:>9,}"
            f"{('yes' if _has_anchor(text) else 'no'):>9}"
        )

    print(
        f"\nn={len(direct)}. A conclusion is small and anchored; a transcript is "
        f"large and\nunanchored. At small n this shows direction, not a rate."
    )
    print(
        "NOTE: this is return-value shape, NOT the parent-context growth AC5\n"
        "names. See the module docstring and the tally's § AC5."
    )


def main(argv: list[str] | None = None) -> int:
    _require_python()

    parser = argparse.ArgumentParser(
        prog="delegation-adoption",
        description="Measure whether investigation delegation is actually happening.",
    )
    parser.add_argument(
        "subcommand",
        nargs="?",
        default="adoption",
        choices=("adoption", "opportunities", "ac5"),
        help="which report to emit (default: adoption)",
    )
    parser.add_argument(
        "--root",
        type=pathlib.Path,
        default=None,
        help="transcript root (default: ~/.claude/projects)",
    )
    args = parser.parse_args(argv)

    root = args.root or transcript_root()
    if not root.is_dir():
        print(f"delegation-adoption: no transcript root at {root}", file=sys.stderr)
        return 3

    if args.subcommand == "opportunities":
        # Keyed on main-session transcripts, which exist independently of whether
        # anything was ever spawned -- so this arm must NOT require spawns. On a
        # corpus with zero delegations (the case this tool was written for) an
        # exit 3 here would suppress the very denominator that makes the zero
        # meaningful.
        if not main_sessions(root):
            print(
                f"delegation-adoption: no session transcripts under {root}.",
                file=sys.stderr,
            )
            return 3
        cmd_opportunities(root)
        return 0

    spawns = list(iter_spawns(root))
    if not spawns:
        # Exit 3, never a 0 reporting "0 delegations". An empty corpus and a
        # corpus that genuinely delegated nothing are different claims, and only
        # the second one is evidence about the guidance.
        print(
            f"delegation-adoption: no subagent transcripts under {root}.\n"
            f"This is an ABSENT measurement, not a measured zero.",
            file=sys.stderr,
        )
        return 3

    if args.subcommand == "adoption":
        cmd_adoption(spawns)
    else:
        cmd_ac5(spawns)
    return 0


if __name__ == "__main__":
    sys.exit(main())
